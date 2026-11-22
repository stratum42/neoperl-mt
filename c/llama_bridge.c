/*
 * c/llama_bridge.c - Runtime dlopen("libllama.{dylib,so,dll}") dynamic bridge
 *
 * Zero compile-time link dependency on libllama. Uses memcpy-clean dlsym for
 * strict C11 (-Wall -Wextra -Werror) compliance across macOS arm64, Linux
 * x86_64, IBM POWER8+ ppc64le, and Win64, degrading cleanly when libllama
 * is absent.
 *
 * Targets the llama.cpp v1.0.0 C ABI (dynamic ggml backend plugins,
 * llama_model_load_from_file, llama_init_from_model, llama_memory_clear,
 * llama_sampler_chain).
 */
#include "llama_bridge.h"
#include "tkmt_thread.h"
#include "vec_simd.h"

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(NPL_HAVE_LLAMA_H)
#  include <llama.h>
#endif

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
typedef HMODULE npl_ll_dl_t;
static npl_ll_dl_t ll_dl_open(const char *p) { return LoadLibraryA(p); }
static void *ll_dl_sym(npl_ll_dl_t h, const char *s) {
    FARPROC fp = GetProcAddress(h, s);
    void *ptr = NULL;
    memcpy(&ptr, &fp, sizeof(ptr));
    return ptr;
}
static void ll_dl_close(npl_ll_dl_t h) { if (h) FreeLibrary(h); }
#else
#  include <dlfcn.h>
typedef void *npl_ll_dl_t;
static npl_ll_dl_t ll_dl_open(const char *p) { return dlopen(p, RTLD_LAZY | RTLD_LOCAL); }
static void *ll_dl_sym(npl_ll_dl_t h, const char *s) { return dlsym(h, s); }
static void ll_dl_close(npl_ll_dl_t h) { if (h) dlclose(h); }
#endif

/* =========================================================================
 * Self-contained llama.cpp v1.0.0 C ABI types & structs
 * ========================================================================= */

typedef struct npl_llama_model_opaque    npl_llama_model_t;
typedef struct npl_llama_context_opaque  npl_llama_context_t;
typedef struct npl_llama_vocab_opaque    npl_llama_vocab_t;
typedef struct npl_llama_sampler_opaque  npl_llama_sampler_t;
typedef struct npl_llama_memory_opaque  *npl_llama_memory_t;

typedef int32_t npl_llama_token_t;
typedef int32_t npl_llama_pos_t;
typedef int32_t npl_llama_seq_id_t;

#define NPL_LLAMA_DEFAULT_SEED 0xFFFFFFFFu

enum npl_ggml_log_level {
    NPL_GGML_LOG_LEVEL_NONE  = 0,
    NPL_GGML_LOG_LEVEL_DEBUG = 1,
    NPL_GGML_LOG_LEVEL_INFO  = 2,
    NPL_GGML_LOG_LEVEL_WARN  = 3,
    NPL_GGML_LOG_LEVEL_ERROR = 4,
    NPL_GGML_LOG_LEVEL_CONT  = 5
};

enum npl_ggml_type {
    NPL_GGML_TYPE_F32     = 0,
    NPL_GGML_TYPE_F16     = 1,
    NPL_GGML_TYPE_Q8_0    = 8,
    NPL_GGML_TYPE_COUNT   = 46
};

enum npl_llama_split_mode {
    NPL_LLAMA_SPLIT_MODE_NONE   = 0,
    NPL_LLAMA_SPLIT_MODE_LAYER  = 1,
    NPL_LLAMA_SPLIT_MODE_ROW    = 2,
    NPL_LLAMA_SPLIT_MODE_TENSOR = 3
};

enum npl_llama_load_mode {
    NPL_LLAMA_LOAD_MODE_AUTO       = -1,
    NPL_LLAMA_LOAD_MODE_NONE       =  0,
    NPL_LLAMA_LOAD_MODE_MMAP       =  1,
    NPL_LLAMA_LOAD_MODE_MLOCK      =  2,
    NPL_LLAMA_LOAD_MODE_MMAP_MLOCK =  3,
    NPL_LLAMA_LOAD_MODE_DIRECT_IO  =  4
};

enum npl_llama_lazy_mode {
    NPL_LLAMA_LAZY_MODE_OFF  = 0,
    NPL_LLAMA_LAZY_MODE_AUTO = 1,
    NPL_LLAMA_LAZY_MODE_ON   = 2
};

enum npl_llama_context_type {
    NPL_LLAMA_CONTEXT_TYPE_DEFAULT = 0,
    NPL_LLAMA_CONTEXT_TYPE_MTP     = 1
};

enum npl_llama_rope_scaling_type {
    NPL_LLAMA_ROPE_SCALING_TYPE_UNSPECIFIED = -1,
    NPL_LLAMA_ROPE_SCALING_TYPE_NONE        =  0,
    NPL_LLAMA_ROPE_SCALING_TYPE_LINEAR      =  1,
    NPL_LLAMA_ROPE_SCALING_TYPE_YARN        =  2,
    NPL_LLAMA_ROPE_SCALING_TYPE_LONGROPE    =  3
};

enum npl_llama_pooling_type {
    NPL_LLAMA_POOLING_TYPE_UNSPECIFIED = -1,
    NPL_LLAMA_POOLING_TYPE_NONE        =  0,
    NPL_LLAMA_POOLING_TYPE_MEAN        =  1,
    NPL_LLAMA_POOLING_TYPE_CLS         =  2,
    NPL_LLAMA_POOLING_TYPE_LAST        =  3,
    NPL_LLAMA_POOLING_TYPE_RANK        =  4
};

enum npl_llama_attention_type {
    NPL_LLAMA_ATTENTION_TYPE_UNSPECIFIED = -1,
    NPL_LLAMA_ATTENTION_TYPE_CAUSAL      =  0,
    NPL_LLAMA_ATTENTION_TYPE_NON_CAUSAL  =  1
};

enum npl_llama_flash_attn_type {
    NPL_LLAMA_FLASH_ATTN_TYPE_AUTO     = -1,
    NPL_LLAMA_FLASH_ATTN_TYPE_DISABLED =  0,
    NPL_LLAMA_FLASH_ATTN_TYPE_ENABLED  =  1
};

typedef bool (*npl_llama_progress_cb_t)(float progress, void *user_data);
typedef bool (*npl_ggml_eval_cb_t)(void *tensor, bool ask, void *user_data);
typedef bool (*npl_ggml_abort_cb_t)(void *data);
typedef void (*npl_ggml_log_cb_t)(enum npl_ggml_log_level level, const char *text, void *user_data);

typedef struct npl_llama_batch {
    int32_t              n_tokens;
    npl_llama_token_t   *token;
    float               *embd;
    npl_llama_pos_t     *pos;
    int32_t             *n_seq_id;
    npl_llama_seq_id_t **seq_id;
    int8_t              *logits;
} npl_llama_batch_t;

typedef struct npl_llama_model_params {
    void                     **devices;
    const void                *tensor_buft_overrides;

    int32_t                    n_gpu_layers;
    enum npl_llama_split_mode  split_mode;
    enum npl_llama_load_mode   load_mode;
    enum npl_llama_lazy_mode   lazy_mode;

    int32_t                    main_gpu;
    const float               *tensor_split;

    npl_llama_progress_cb_t    progress_callback;
    void                      *progress_callback_user_data;

    const void                *kv_overrides;

    bool                       vocab_only;
    bool                       check_tensors;
    bool                       use_extra_bufts;
    bool                       no_host;
    bool                       no_alloc;
    bool                       load_mtp;
} npl_llama_model_params_t;

typedef struct npl_llama_context_params {
    uint32_t                         n_ctx;
    uint32_t                         n_batch;
    uint32_t                         n_ubatch;
    uint32_t                         n_seq_max;
    uint32_t                         n_rs_seq;
    uint32_t                         n_outputs_max;
    uint32_t                         n_outputs_max_per_seq;
    int32_t                          n_threads;
    int32_t                          n_threads_batch;

    enum npl_llama_context_type      ctx_type;
    enum npl_llama_rope_scaling_type rope_scaling_type;
    enum npl_llama_pooling_type      pooling_type;
    enum npl_llama_attention_type    attention_type;
    enum npl_llama_flash_attn_type   flash_attn_type;

    float                            rope_freq_base;
    float                            rope_freq_scale;
    float                            yarn_ext_factor;
    float                            yarn_attn_factor;
    float                            yarn_beta_fast;
    float                            yarn_beta_slow;
    uint32_t                         yarn_orig_ctx;

    npl_ggml_eval_cb_t               cb_eval;
    void                            *cb_eval_user_data;

    enum npl_ggml_type               type_k;
    enum npl_ggml_type               type_v;

    size_t                           moe_cache_size;
    float                            moe_cache_cpu_share;

    npl_ggml_abort_cb_t              abort_callback;
    void                            *abort_callback_data;

    bool                             embeddings;
    bool                             offload_kqv;
    bool                             no_perf;
    bool                             op_offload;
    bool                             swa_full;
    bool                             kv_unified;

    void                            *samplers;
    size_t                           n_samplers;
    void                            *ctx_other;
} npl_llama_context_params_t;

typedef struct npl_llama_sampler_chain_params {
    bool no_perf;
} npl_llama_sampler_chain_params_t;

#if defined(NPL_HAVE_LLAMA_H) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(npl_llama_batch_t) == sizeof(struct llama_batch),
               "llama_batch ABI size mismatch");
_Static_assert(sizeof(npl_llama_model_params_t) == sizeof(struct llama_model_params),
               "llama_model_params ABI size mismatch");
_Static_assert(offsetof(npl_llama_model_params_t, n_gpu_layers) == offsetof(struct llama_model_params, n_gpu_layers),
               "llama_model_params.n_gpu_layers offset mismatch");
_Static_assert(offsetof(npl_llama_model_params_t, load_mtp) == offsetof(struct llama_model_params, load_mtp),
               "llama_model_params.load_mtp offset mismatch");
_Static_assert(sizeof(npl_llama_context_params_t) == sizeof(struct llama_context_params),
               "llama_context_params ABI size mismatch");
_Static_assert(offsetof(npl_llama_context_params_t, pooling_type) == offsetof(struct llama_context_params, pooling_type),
               "llama_context_params.pooling_type offset mismatch");
_Static_assert(offsetof(npl_llama_context_params_t, embeddings) == offsetof(struct llama_context_params, embeddings),
               "llama_context_params.embeddings offset mismatch");
_Static_assert(offsetof(npl_llama_context_params_t, ctx_other) == offsetof(struct llama_context_params, ctx_other),
               "llama_context_params.ctx_other offset mismatch");
_Static_assert(sizeof(npl_llama_sampler_chain_params_t) == sizeof(struct llama_sampler_chain_params),
               "llama_sampler_chain_params ABI size mismatch");
#endif

/* =========================================================================
 * Resolved function pointer types
 * ========================================================================= */

typedef void (*fn_ggml_backend_load_all_t)(void);
typedef void (*fn_ggml_log_set_t)(npl_ggml_log_cb_t, void *);
typedef void (*fn_llama_log_set_t)(npl_ggml_log_cb_t, void *);
typedef void (*fn_backend_init_t)(void);
typedef const char *(*fn_llama_version_t)(void);

typedef npl_llama_model_params_t (*fn_model_default_params_t)(void);
typedef npl_llama_model_t *(*fn_model_load_from_file_t)(const char *, npl_llama_model_params_t);
typedef void (*fn_model_free_t)(npl_llama_model_t *);

typedef npl_llama_context_params_t (*fn_context_default_params_t)(void);
typedef npl_llama_context_t *(*fn_init_from_model_t)(npl_llama_model_t *, npl_llama_context_params_t);
typedef void (*fn_ctx_free_t)(npl_llama_context_t *);

typedef const npl_llama_vocab_t *(*fn_model_get_vocab_t)(const npl_llama_model_t *);
typedef int32_t (*fn_n_embd_t)(const npl_llama_model_t *);
typedef bool (*fn_model_has_encoder_t)(const npl_llama_model_t *);
typedef bool (*fn_model_has_decoder_t)(const npl_llama_model_t *);
typedef uint32_t (*fn_ctx_u32_t)(const npl_llama_context_t *);

typedef int32_t (*fn_tokenize_t)(const npl_llama_vocab_t *, const char *, int32_t,
                                 npl_llama_token_t *, int32_t, bool, bool);
typedef int32_t (*fn_token_to_piece_t)(const npl_llama_vocab_t *, npl_llama_token_t,
                                       char *, int32_t, int32_t, bool);
typedef bool (*fn_vocab_is_eog_t)(const npl_llama_vocab_t *, npl_llama_token_t);
typedef npl_llama_token_t (*fn_vocab_eos_t)(const npl_llama_vocab_t *);

typedef npl_llama_batch_t (*fn_batch_init_t)(int32_t, int32_t, int32_t);
typedef void (*fn_batch_free_t)(npl_llama_batch_t);
typedef npl_llama_batch_t (*fn_batch_get_one_t)(npl_llama_token_t *, int32_t);
typedef int32_t (*fn_encode_t)(npl_llama_context_t *, npl_llama_batch_t);
typedef int32_t (*fn_decode_t)(npl_llama_context_t *, npl_llama_batch_t);

typedef float *(*fn_get_embeddings_t)(npl_llama_context_t *);
typedef float *(*fn_get_embeddings_ith_t)(npl_llama_context_t *, int32_t);
typedef float *(*fn_get_embeddings_seq_t)(npl_llama_context_t *, npl_llama_seq_id_t);

typedef npl_llama_memory_t (*fn_get_memory_t)(const npl_llama_context_t *);
typedef void (*fn_memory_clear_t)(npl_llama_memory_t, bool);
typedef void (*fn_kv_self_clear_t)(npl_llama_context_t *);

typedef npl_llama_sampler_chain_params_t (*fn_sampler_chain_default_params_t)(void);
typedef npl_llama_sampler_t *(*fn_sampler_chain_init_t)(npl_llama_sampler_chain_params_t);
typedef void (*fn_sampler_chain_add_t)(npl_llama_sampler_t *, npl_llama_sampler_t *);
typedef npl_llama_sampler_t *(*fn_sampler_init_greedy_t)(void);
typedef npl_llama_sampler_t *(*fn_sampler_init_temp_t)(float);
typedef npl_llama_sampler_t *(*fn_sampler_init_dist_t)(uint32_t);
typedef npl_llama_token_t (*fn_sampler_sample_t)(npl_llama_sampler_t *, npl_llama_context_t *, int32_t);
typedef void (*fn_sampler_free_t)(npl_llama_sampler_t *);

/* =========================================================================
 * Bridge global state (serialized by g_ll_lock)
 * ========================================================================= */

typedef struct npl_llama_state {
    int         probed;
    int         available;
    int         backend_initialized;
    int         v1_abi_ok;
    npl_ll_dl_t handle;
    npl_ll_dl_t ggml_handle;
    npl_ll_dl_t ggml_base_handle;
    char        lib_path[512];
    char        model_path[512];
    char        last_error[256];

    fn_ggml_backend_load_all_t        ggml_backend_load_all;
    fn_ggml_log_set_t                 ggml_log_set;
    fn_llama_log_set_t                llama_log_set;
    fn_backend_init_t                 backend_init;
    fn_llama_version_t                llama_version;

    fn_model_default_params_t         model_default_params;
    fn_model_load_from_file_t         model_load_from_file;
    fn_model_free_t                   model_free;

    fn_context_default_params_t       context_default_params;
    fn_init_from_model_t              init_from_model;
    fn_ctx_free_t                     ctx_free;

    fn_model_get_vocab_t              model_get_vocab;
    fn_n_embd_t                       model_n_embd;
    fn_n_embd_t                       model_n_embd_out;
    fn_model_has_encoder_t            model_has_encoder;
    fn_model_has_decoder_t            model_has_decoder;
    fn_ctx_u32_t                      ctx_n_ctx;
    fn_ctx_u32_t                      ctx_n_batch;
    fn_ctx_u32_t                      ctx_n_ubatch;

    fn_tokenize_t                     tokenize;
    fn_token_to_piece_t               token_to_piece;
    fn_vocab_is_eog_t                 vocab_is_eog;
    fn_vocab_eos_t                    vocab_eos;

    fn_batch_init_t                   batch_init;
    fn_batch_free_t                   batch_free;
    fn_batch_get_one_t                batch_get_one;
    fn_encode_t                       encode;
    fn_decode_t                       decode;

    fn_get_embeddings_t               get_embeddings;
    fn_get_embeddings_ith_t           get_embeddings_ith;
    fn_get_embeddings_seq_t           get_embeddings_seq;

    fn_get_memory_t                   get_memory;
    fn_memory_clear_t                 memory_clear;
    fn_kv_self_clear_t                kv_self_clear;

    fn_sampler_chain_default_params_t sampler_chain_default_params;
    fn_sampler_chain_init_t           sampler_chain_init;
    fn_sampler_chain_add_t            sampler_chain_add;
    fn_sampler_init_greedy_t          sampler_init_greedy;
    fn_sampler_init_temp_t            sampler_init_temp;
    fn_sampler_init_dist_t            sampler_init_dist;
    fn_sampler_sample_t               sampler_sample;
    fn_sampler_free_t                 sampler_free;

    npl_llama_model_t                *model;
    npl_llama_context_t              *ctx;
    const npl_llama_vocab_t          *vocab;
    int                               n_embd;
    uint32_t                          n_ctx;
    uint32_t                          n_batch;
    uint32_t                          n_ubatch;
    int                               has_encoder;
    int                               has_decoder;
    int                               embeddings_mode;
} npl_llama_state_t;

static tkmt_static_mutex_t g_ll_lock = TKMT_STATIC_MUTEX_INIT;
static npl_llama_state_t   g_ll = {0};
static int                 g_atexit_registered = 0;

static void
npl_llama_atexit_cleanup(void)
{
    npl_llama_unload();
}

static int
ll_load_sym(npl_ll_dl_t h, const char *name, void *out, size_t sz)
{
    void *sym = ll_dl_sym(h, name);
    if (!sym) return 0;
    memcpy(out, &sym, sz);
    return 1;
}

static int
ll_join_path(char *dst, size_t dst_sz, const char *prefix, size_t prefix_len, const char *suffix)
{
    size_t slen = strlen(suffix);
    if (prefix_len + slen + 1 > dst_sz) return 0;
    if (prefix_len > 0) memcpy(dst, prefix, prefix_len);
    memcpy(dst + prefix_len, suffix, slen);
    dst[prefix_len + slen] = '\0';
    return 1;
}

static size_t
ll_dirname_len(const char *path)
{
    if (!path) return 0;
    const char *last_slash = strrchr(path, '/');
    const char *last_bslash = strrchr(path, '\\');
    const char *sep = last_slash;
    if (last_bslash && (!sep || last_bslash > sep)) sep = last_bslash;
    if (!sep) return 0;
    return (size_t)(sep - path + 1);
}

static void
set_err(char *errbuf, size_t errsz, const char *msg)
{
    size_t n = strlen(msg);
    if (n >= sizeof(g_ll.last_error)) n = sizeof(g_ll.last_error) - 1;
    memcpy(g_ll.last_error, msg, n);
    g_ll.last_error[n] = '\0';
    if (errbuf && errsz > 0) {
        size_t m = strlen(msg);
        if (m >= errsz) m = errsz - 1;
        memcpy(errbuf, msg, m);
        errbuf[m] = '\0';
    }
}

static void
ll_quiet_log_cb(enum npl_ggml_log_level level, const char *text, void *user_data)
{
    (void)level;
    (void)text;
    (void)user_data;
}

static void
ll_probe_ggml_aux(const char *llama_path)
{
    size_t dlen = ll_dirname_len(llama_path);
    char cand[768];

    if (!g_ll.ggml_backend_load_all) {
#if defined(_WIN32)
        static const char *const ggml_names[] = {
            "ggml.dll", "libggml.dll", NULL
        };
#elif defined(__APPLE__)
        static const char *const ggml_names[] = {
            "libggml.dylib", "libggml.1.dylib", NULL
        };
#else
        static const char *const ggml_names[] = {
            "libggml.so", "libggml.so.1", "libggml.so.0", NULL
        };
#endif
        for (size_t i = 0; ggml_names[i] != NULL && !g_ll.ggml_backend_load_all; i++) {
            const char *try_p = ggml_names[i];
            if (dlen > 0 && ll_join_path(cand, sizeof(cand), llama_path, dlen, ggml_names[i])) {
                npl_ll_dl_t gh = ll_dl_open(cand);
                if (gh) {
                    if (ll_load_sym(gh, "ggml_backend_load_all",
                                    &g_ll.ggml_backend_load_all, sizeof(g_ll.ggml_backend_load_all))) {
                        g_ll.ggml_handle = gh;
                        if (!g_ll.ggml_log_set) {
                            (void)ll_load_sym(gh, "ggml_log_set",
                                              &g_ll.ggml_log_set, sizeof(g_ll.ggml_log_set));
                        }
                        break;
                    }
                    ll_dl_close(gh);
                }
            }
            npl_ll_dl_t gh = ll_dl_open(try_p);
            if (gh) {
                if (ll_load_sym(gh, "ggml_backend_load_all",
                                &g_ll.ggml_backend_load_all, sizeof(g_ll.ggml_backend_load_all))) {
                    g_ll.ggml_handle = gh;
                    if (!g_ll.ggml_log_set) {
                        (void)ll_load_sym(gh, "ggml_log_set",
                                          &g_ll.ggml_log_set, sizeof(g_ll.ggml_log_set));
                    }
                    break;
                }
                ll_dl_close(gh);
            }
        }
#if defined(__APPLE__)
        if (!g_ll.ggml_backend_load_all) {
            static const char *const mac_ggml[] = {
                "/opt/homebrew/opt/ggml/lib/libggml.dylib",
                "/opt/homebrew/lib/libggml.dylib",
                "/usr/local/lib/libggml.dylib",
                NULL
            };
            for (size_t i = 0; mac_ggml[i] != NULL; i++) {
                npl_ll_dl_t gh = ll_dl_open(mac_ggml[i]);
                if (!gh) continue;
                if (ll_load_sym(gh, "ggml_backend_load_all",
                                &g_ll.ggml_backend_load_all, sizeof(g_ll.ggml_backend_load_all))) {
                    g_ll.ggml_handle = gh;
                    if (!g_ll.ggml_log_set) {
                        (void)ll_load_sym(gh, "ggml_log_set",
                                          &g_ll.ggml_log_set, sizeof(g_ll.ggml_log_set));
                    }
                    break;
                }
                ll_dl_close(gh);
            }
        }
#endif
    }

    if (!g_ll.ggml_log_set) {
#if defined(_WIN32)
        static const char *const base_names[] = {
            "ggml-base.dll", "libggml-base.dll", NULL
        };
#elif defined(__APPLE__)
        static const char *const base_names[] = {
            "libggml-base.dylib", "libggml-base.1.dylib", NULL
        };
#else
        static const char *const base_names[] = {
            "libggml-base.so", "libggml-base.so.1", "libggml-base.so.0", NULL
        };
#endif
        for (size_t i = 0; base_names[i] != NULL && !g_ll.ggml_log_set; i++) {
            if (dlen > 0 && ll_join_path(cand, sizeof(cand), llama_path, dlen, base_names[i])) {
                npl_ll_dl_t bh = ll_dl_open(cand);
                if (bh) {
                    if (ll_load_sym(bh, "ggml_log_set",
                                    &g_ll.ggml_log_set, sizeof(g_ll.ggml_log_set))) {
                        g_ll.ggml_base_handle = bh;
                        break;
                    }
                    ll_dl_close(bh);
                }
            }
            npl_ll_dl_t bh = ll_dl_open(base_names[i]);
            if (bh) {
                if (ll_load_sym(bh, "ggml_log_set",
                                &g_ll.ggml_log_set, sizeof(g_ll.ggml_log_set))) {
                    g_ll.ggml_base_handle = bh;
                    break;
                }
                ll_dl_close(bh);
            }
        }
#if defined(__APPLE__)
        if (!g_ll.ggml_log_set) {
            static const char *const mac_base[] = {
                "/opt/homebrew/opt/ggml/lib/libggml-base.dylib",
                "/opt/homebrew/lib/libggml-base.dylib",
                "/usr/local/lib/libggml-base.dylib",
                NULL
            };
            for (size_t i = 0; mac_base[i] != NULL; i++) {
                npl_ll_dl_t bh = ll_dl_open(mac_base[i]);
                if (!bh) continue;
                if (ll_load_sym(bh, "ggml_log_set",
                                &g_ll.ggml_log_set, sizeof(g_ll.ggml_log_set))) {
                    g_ll.ggml_base_handle = bh;
                    break;
                }
                ll_dl_close(bh);
            }
        }
#endif
    }
}

static int
try_load_llama(const char *path)
{
    if (!path || !path[0]) return 0;
    npl_ll_dl_t h = ll_dl_open(path);
    if (!h) return 0;

    fn_backend_init_t init_fn = NULL;
    fn_model_free_t mfree_fn = NULL;
    fn_ctx_free_t cfree_fn = NULL;
    fn_n_embd_t nembd_fn = NULL;

    int has_init  = ll_load_sym(h, "llama_backend_init", &init_fn, sizeof(init_fn));
    int has_mfree = ll_load_sym(h, "llama_model_free", &mfree_fn, sizeof(mfree_fn)) ||
                    ll_load_sym(h, "llama_free_model", &mfree_fn, sizeof(mfree_fn));
    int has_cfree = ll_load_sym(h, "llama_free", &cfree_fn, sizeof(cfree_fn));
    int has_embd  = ll_load_sym(h, "llama_model_n_embd", &nembd_fn, sizeof(nembd_fn)) ||
                    ll_load_sym(h, "llama_n_embd", &nembd_fn, sizeof(nembd_fn));

    if (!has_init || !has_mfree || !has_cfree || !has_embd) {
        ll_dl_close(h);
        return 0;
    }

    g_ll.handle       = h;
    g_ll.backend_init = init_fn;
    g_ll.model_free   = mfree_fn;
    g_ll.ctx_free     = cfree_fn;
    g_ll.model_n_embd = nembd_fn;

    (void)ll_load_sym(h, "ggml_backend_load_all", &g_ll.ggml_backend_load_all, sizeof(g_ll.ggml_backend_load_all));
    (void)ll_load_sym(h, "ggml_log_set",          &g_ll.ggml_log_set,          sizeof(g_ll.ggml_log_set));
    (void)ll_load_sym(h, "llama_log_set",         &g_ll.llama_log_set,         sizeof(g_ll.llama_log_set));
    (void)ll_load_sym(h, "llama_version",         &g_ll.llama_version,         sizeof(g_ll.llama_version));

    (void)ll_load_sym(h, "llama_model_default_params",   &g_ll.model_default_params,   sizeof(g_ll.model_default_params));
    (void)ll_load_sym(h, "llama_model_load_from_file",   &g_ll.model_load_from_file,   sizeof(g_ll.model_load_from_file));
    (void)ll_load_sym(h, "llama_context_default_params", &g_ll.context_default_params, sizeof(g_ll.context_default_params));
    (void)ll_load_sym(h, "llama_init_from_model",        &g_ll.init_from_model,        sizeof(g_ll.init_from_model));

    (void)ll_load_sym(h, "llama_model_get_vocab",   &g_ll.model_get_vocab,   sizeof(g_ll.model_get_vocab));
    (void)ll_load_sym(h, "llama_model_n_embd_out",  &g_ll.model_n_embd_out,  sizeof(g_ll.model_n_embd_out));
    (void)ll_load_sym(h, "llama_model_has_encoder", &g_ll.model_has_encoder, sizeof(g_ll.model_has_encoder));
    (void)ll_load_sym(h, "llama_model_has_decoder", &g_ll.model_has_decoder, sizeof(g_ll.model_has_decoder));
    (void)ll_load_sym(h, "llama_n_ctx",             &g_ll.ctx_n_ctx,         sizeof(g_ll.ctx_n_ctx));
    (void)ll_load_sym(h, "llama_n_batch",           &g_ll.ctx_n_batch,       sizeof(g_ll.ctx_n_batch));
    (void)ll_load_sym(h, "llama_n_ubatch",          &g_ll.ctx_n_ubatch,      sizeof(g_ll.ctx_n_ubatch));

    (void)ll_load_sym(h, "llama_tokenize",       &g_ll.tokenize,       sizeof(g_ll.tokenize));
    (void)ll_load_sym(h, "llama_token_to_piece", &g_ll.token_to_piece, sizeof(g_ll.token_to_piece));
    (void)ll_load_sym(h, "llama_vocab_is_eog",   &g_ll.vocab_is_eog,   sizeof(g_ll.vocab_is_eog));
    (void)ll_load_sym(h, "llama_vocab_eos",      &g_ll.vocab_eos,      sizeof(g_ll.vocab_eos));

    (void)ll_load_sym(h, "llama_batch_init",    &g_ll.batch_init,    sizeof(g_ll.batch_init));
    (void)ll_load_sym(h, "llama_batch_free",    &g_ll.batch_free,    sizeof(g_ll.batch_free));
    (void)ll_load_sym(h, "llama_batch_get_one", &g_ll.batch_get_one, sizeof(g_ll.batch_get_one));
    (void)ll_load_sym(h, "llama_encode",        &g_ll.encode,        sizeof(g_ll.encode));
    (void)ll_load_sym(h, "llama_decode",        &g_ll.decode,        sizeof(g_ll.decode));

    (void)ll_load_sym(h, "llama_get_embeddings",     &g_ll.get_embeddings,     sizeof(g_ll.get_embeddings));
    (void)ll_load_sym(h, "llama_get_embeddings_ith", &g_ll.get_embeddings_ith, sizeof(g_ll.get_embeddings_ith));
    (void)ll_load_sym(h, "llama_get_embeddings_seq", &g_ll.get_embeddings_seq, sizeof(g_ll.get_embeddings_seq));

    (void)ll_load_sym(h, "llama_get_memory",   &g_ll.get_memory,   sizeof(g_ll.get_memory));
    (void)ll_load_sym(h, "llama_memory_clear", &g_ll.memory_clear, sizeof(g_ll.memory_clear));
    if (!ll_load_sym(h, "llama_kv_self_clear", &g_ll.kv_self_clear, sizeof(g_ll.kv_self_clear))) {
        (void)ll_load_sym(h, "llama_kv_cache_clear", &g_ll.kv_self_clear, sizeof(g_ll.kv_self_clear));
    }

    (void)ll_load_sym(h, "llama_sampler_chain_default_params", &g_ll.sampler_chain_default_params, sizeof(g_ll.sampler_chain_default_params));
    (void)ll_load_sym(h, "llama_sampler_chain_init",           &g_ll.sampler_chain_init,           sizeof(g_ll.sampler_chain_init));
    (void)ll_load_sym(h, "llama_sampler_chain_add",            &g_ll.sampler_chain_add,            sizeof(g_ll.sampler_chain_add));
    (void)ll_load_sym(h, "llama_sampler_init_greedy",          &g_ll.sampler_init_greedy,          sizeof(g_ll.sampler_init_greedy));
    (void)ll_load_sym(h, "llama_sampler_init_temp",            &g_ll.sampler_init_temp,            sizeof(g_ll.sampler_init_temp));
    (void)ll_load_sym(h, "llama_sampler_init_dist",            &g_ll.sampler_init_dist,            sizeof(g_ll.sampler_init_dist));
    (void)ll_load_sym(h, "llama_sampler_sample",               &g_ll.sampler_sample,               sizeof(g_ll.sampler_sample));
    (void)ll_load_sym(h, "llama_sampler_free",                 &g_ll.sampler_free,                 sizeof(g_ll.sampler_free));

    /* Verify llama.cpp v1.0.0 ABI markers before calling struct-by-value loaders */
    g_ll.v1_abi_ok = (ll_dl_sym(h, "llama_load_mode_name") != NULL &&
                      ll_dl_sym(h, "llama_n_rs_seq") != NULL) ? 1 : 0;

    ll_probe_ggml_aux(path);

    size_t plen = strlen(path);
    if (plen >= sizeof(g_ll.lib_path)) plen = sizeof(g_ll.lib_path) - 1;
    memcpy(g_ll.lib_path, path, plen);
    g_ll.lib_path[plen] = '\0';
    g_ll.available = 1;
    g_ll.last_error[0] = '\0';
    return 1;
}

static void
ensure_llama_probed_locked(void)
{
#if defined(NPL_HAVE_LLAMA_H)
    (void)GGML_TENSOR_SIZE;
#endif
    if (g_ll.probed) return;
    g_ll.probed = 1;

    const char *env_path = getenv("NEOPERL_LLAMA_LIB");
    if (env_path && try_load_llama(env_path)) return;

#if !defined(_WIN32)
    const char *home = getenv("HOME");
    if (home && home[0]) {
        char local_lib[768];
#  if defined(__APPLE__)
        if (ll_join_path(local_lib, sizeof(local_lib), home, strlen(home), "/.local/lib/libllama.dylib") &&
            try_load_llama(local_lib)) {
            return;
        }
#  else
        if (ll_join_path(local_lib, sizeof(local_lib), home, strlen(home), "/.local/lib/libllama.so") &&
            try_load_llama(local_lib)) {
            return;
        }
#  endif
    }
#endif

#if defined(_WIN32)
    static const char *const candidates[] = {
        "llama.dll",
        "libllama.dll",
        NULL
    };
#elif defined(__APPLE__)
    static const char *const candidates[] = {
        "/opt/homebrew/opt/llama.cpp/lib/libllama.dylib",
        "/opt/homebrew/lib/libllama.dylib",
        "/usr/local/lib/libllama.dylib",
        "libllama.dylib",
        NULL
    };
#else
    static const char *const candidates[] = {
        "/usr/local/lib/libllama.so",
        "/usr/lib/libllama.so",
        "/usr/lib64/libllama.so",
        "libllama.so",
        "libllama.so.1",
        "libllama.so.0",
        NULL
    };
#endif

    for (size_t i = 0; candidates[i] != NULL; i++) {
        if (try_load_llama(candidates[i])) return;
    }

    set_err(NULL, 0, "libllama not found (install llama.cpp or use llama-server backend)");
}

static void
ensure_backend_init_locked(void)
{
    if (g_ll.backend_initialized) return;
    g_ll.backend_initialized = 1;

    const char *verbose = getenv("NEOPERL_LLAMA_VERBOSE");
    int want_verbose = (verbose && verbose[0] == '1' && verbose[1] == '\0') ? 1 : 0;
    if (!want_verbose) {
        if (g_ll.ggml_log_set)  g_ll.ggml_log_set(ll_quiet_log_cb, NULL);
        if (g_ll.llama_log_set) g_ll.llama_log_set(ll_quiet_log_cb, NULL);
    }

    if (g_ll.ggml_backend_load_all) {
        g_ll.ggml_backend_load_all();
    }
    if (g_ll.backend_init) {
        g_ll.backend_init();
    }
}

static void
unload_locked(void)
{
    if (g_ll.ctx && g_ll.ctx_free) {
        g_ll.ctx_free(g_ll.ctx);
        g_ll.ctx = NULL;
    }
    if (g_ll.model && g_ll.model_free) {
        g_ll.model_free(g_ll.model);
        g_ll.model = NULL;
    }
    g_ll.vocab           = NULL;
    g_ll.model_path[0]   = '\0';
    g_ll.n_embd          = 0;
    g_ll.n_ctx           = 0;
    g_ll.n_batch         = 0;
    g_ll.n_ubatch        = 0;
    g_ll.has_encoder     = 0;
    g_ll.has_decoder     = 0;
    g_ll.embeddings_mode = 0;
}

static void
clear_memory_locked(void)
{
    if (!g_ll.ctx) return;
    if (g_ll.get_memory && g_ll.memory_clear) {
        npl_llama_memory_t mem = g_ll.get_memory(g_ll.ctx);
        if (mem != NULL) {
            g_ll.memory_clear(mem, true);
        }
    } else if (g_ll.kv_self_clear) {
        g_ll.kv_self_clear(g_ll.ctx);
    }
}

static int
tokenize_alloc_locked(const char *text, size_t text_len, bool add_special, bool parse_special,
                      npl_llama_token_t **out_tokens, int32_t *out_count,
                      char *errbuf, size_t errsz)
{
    *out_tokens = NULL;
    *out_count  = 0;

    if (!g_ll.tokenize || !g_ll.vocab) {
        set_err(errbuf, errsz, "llama_tokenize or vocab unavailable");
        return 0;
    }
    if (text_len > (size_t)INT32_MAX) {
        set_err(errbuf, errsz, "input text exceeds maximum tokenization length");
        return 0;
    }

    const char *safe_text = text ? text : "";
    int32_t n_probe = g_ll.tokenize(g_ll.vocab, safe_text, (int32_t)text_len,
                                    NULL, 0, add_special, parse_special);
    if (n_probe == INT32_MIN) {
        set_err(errbuf, errsz, "llama_tokenize overflow");
        return 0;
    }

    int32_t cap = (n_probe < 0) ? -n_probe : (n_probe > 0 ? n_probe : 4);
    npl_llama_token_t *toks = (npl_llama_token_t *)malloc((size_t)cap * sizeof(npl_llama_token_t));
    if (!toks) {
        set_err(errbuf, errsz, "out of memory allocating token buffer");
        return 0;
    }

    int32_t n_tok = g_ll.tokenize(g_ll.vocab, safe_text, (int32_t)text_len,
                                  toks, cap, add_special, parse_special);
    if (n_tok < 0) {
        if (n_tok == INT32_MIN) {
            free(toks);
            set_err(errbuf, errsz, "llama_tokenize overflow");
            return 0;
        }
        int32_t cap2 = -n_tok;
        npl_llama_token_t *toks2 = (npl_llama_token_t *)realloc(toks, (size_t)cap2 * sizeof(npl_llama_token_t));
        if (!toks2) {
            free(toks);
            set_err(errbuf, errsz, "out of memory resizing token buffer");
            return 0;
        }
        toks = toks2;
        n_tok = g_ll.tokenize(g_ll.vocab, safe_text, (int32_t)text_len,
                              toks, cap2, add_special, parse_special);
    }

    if (n_tok <= 0) {
        free(toks);
        set_err(errbuf, errsz, "input text tokenized to zero tokens");
        return 0;
    }

    *out_tokens = toks;
    *out_count  = n_tok;
    return 1;
}

static int
buf_append(char **buf, size_t *len, size_t *cap, const char *src, size_t n)
{
    if (n == 0) return 1;
    if (*len + n + 1 > *cap) {
        size_t new_cap = (*cap > 0) ? *cap : 256;
        while (new_cap < *len + n + 1) {
            if (new_cap > SIZE_MAX / 2) return 0;
            new_cap *= 2;
        }
        char *nb = (char *)realloc(*buf, new_cap);
        if (!nb) return 0;
        *buf = nb;
        *cap = new_cap;
    }
    memcpy(*buf + *len, src, n);
    *len += n;
    (*buf)[*len] = '\0';
    return 1;
}

/* =========================================================================
 * Public API
 * ========================================================================= */

int
npl_llama_available(void)
{
    int saved_errno = errno;
    tkmt_static_mutex_lock(&g_ll_lock);
    ensure_llama_probed_locked();
    int a = g_ll.available;
    tkmt_static_mutex_unlock(&g_ll_lock);
    errno = saved_errno;
    return a;
}

const char *
npl_llama_library_path(void)
{
    int saved_errno = errno;
    tkmt_static_mutex_lock(&g_ll_lock);
    ensure_llama_probed_locked();
    const char *p = g_ll.available ? g_ll.lib_path : "";
    tkmt_static_mutex_unlock(&g_ll_lock);
    errno = saved_errno;
    return p;
}

void
npl_llama_status(npl_llama_status_t *out)
{
    if (!out) return;
    int saved_errno = errno;
    memset(out, 0, sizeof(*out));
    tkmt_static_mutex_lock(&g_ll_lock);
    ensure_llama_probed_locked();
    out->available = g_ll.available;
    out->model_loaded = (g_ll.model != NULL && g_ll.ctx != NULL) ? 1 : 0;
    out->n_embd = g_ll.n_embd;
    memcpy(out->library_path, g_ll.lib_path, sizeof(out->library_path));
    memcpy(out->model_path, g_ll.model_path, sizeof(out->model_path));
    memcpy(out->last_error, g_ll.last_error, sizeof(out->last_error));
    tkmt_static_mutex_unlock(&g_ll_lock);
    errno = saved_errno;
}

int
npl_llama_load_model(const char *gguf_path, int n_gpu_layers, int n_ctx,
                     int embeddings, char *errbuf, size_t errsz)
{
    int saved_errno = errno;
    tkmt_static_mutex_lock(&g_ll_lock);
    ensure_llama_probed_locked();
    if (!g_ll.available) {
        set_err(errbuf, errsz, "libllama is not available");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (!gguf_path || !gguf_path[0]) {
        set_err(errbuf, errsz, "empty GGUF model path");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    /* Validate GGUF magic header before calling into libllama */
    FILE *fp = fopen(gguf_path, "rb");
    if (!fp) {
        set_err(errbuf, errsz, "GGUF model file not found or unreadable");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    char magic[4] = {0, 0, 0, 0};
    size_t got = fread(magic, 1, 4, fp);
    fclose(fp);
    if (got != 4 || memcmp(magic, "GGUF", 4) != 0) {
        set_err(errbuf, errsz, "invalid GGUF file header");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    if (!g_ll.v1_abi_ok ||
        !g_ll.model_default_params || !g_ll.model_load_from_file ||
        !g_ll.context_default_params || !g_ll.init_from_model ||
        !g_ll.model_get_vocab || !g_ll.tokenize ||
        !g_ll.batch_init || !g_ll.batch_free || !g_ll.decode) {
        set_err(errbuf, errsz, "in-process GGUF loading requires llama.cpp v1.0.0+ ABI; use llama-server transport");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    ensure_backend_init_locked();
    unload_locked();

    npl_llama_model_params_t mparams = g_ll.model_default_params();
    mparams.n_gpu_layers = (int32_t)n_gpu_layers;

    npl_llama_model_t *model = g_ll.model_load_from_file(gguf_path, mparams);
    if (!model) {
        set_err(errbuf, errsz, "llama_model_load_from_file failed");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    const npl_llama_vocab_t *vocab = g_ll.model_get_vocab(model);
    if (!vocab) {
        g_ll.model_free(model);
        set_err(errbuf, errsz, "llama_model_get_vocab returned NULL");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    uint32_t ctx_sz = (n_ctx > 0) ? (uint32_t)n_ctx : 2048u;
    npl_llama_context_params_t cparams = g_ll.context_default_params();
    cparams.n_ctx = ctx_sz;
    if (embeddings) {
        cparams.n_batch      = ctx_sz;
        cparams.n_ubatch     = ctx_sz;
        cparams.embeddings   = true;
        cparams.pooling_type = NPL_LLAMA_POOLING_TYPE_MEAN;
    } else {
        cparams.n_batch    = (ctx_sz < 2048u) ? ctx_sz : 2048u;
        cparams.n_ubatch   = (cparams.n_batch < 512u) ? cparams.n_batch : 512u;
        cparams.embeddings = false;
    }
    cparams.no_perf = true;
    if (cparams.n_threads <= 0) {
        int ncpu = tkmt_cpu_count();
        if (ncpu > 8) ncpu = 8;
        cparams.n_threads = ncpu;
        cparams.n_threads_batch = ncpu;
    }

    npl_llama_context_t *ctx = g_ll.init_from_model(model, cparams);
    if (!ctx) {
        g_ll.model_free(model);
        set_err(errbuf, errsz, "llama_init_from_model failed");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    int32_t dim = 0;
    if (g_ll.model_n_embd_out) dim = g_ll.model_n_embd_out(model);
    if (dim <= 0 && g_ll.model_n_embd) dim = g_ll.model_n_embd(model);

    g_ll.model           = model;
    g_ll.ctx             = ctx;
    g_ll.vocab           = vocab;
    g_ll.n_embd          = (int)dim;
    g_ll.n_ctx           = g_ll.ctx_n_ctx    ? g_ll.ctx_n_ctx(ctx)    : ctx_sz;
    g_ll.n_batch         = g_ll.ctx_n_batch  ? g_ll.ctx_n_batch(ctx)  : cparams.n_batch;
    g_ll.n_ubatch        = g_ll.ctx_n_ubatch ? g_ll.ctx_n_ubatch(ctx) : cparams.n_ubatch;
    g_ll.has_encoder     = (g_ll.model_has_encoder && g_ll.model_has_encoder(model)) ? 1 : 0;
    g_ll.has_decoder     = (!g_ll.model_has_decoder || g_ll.model_has_decoder(model)) ? 1 : 0;
    g_ll.embeddings_mode = embeddings ? 1 : 0;

    size_t plen = strlen(gguf_path);
    if (plen >= sizeof(g_ll.model_path)) plen = sizeof(g_ll.model_path) - 1;
    memcpy(g_ll.model_path, gguf_path, plen);
    g_ll.model_path[plen] = '\0';
    g_ll.last_error[0] = '\0';

    /*
     * Register LIFO atexit cleanup AFTER ggml_backend_load_all() and
     * llama_model_load_from_file()/llama_init_from_model() have initialized
     * dynamic backend plugins (e.g. libggml-metal.so) so ctx/model are freed
     * BEFORE ggml-metal's C++ static destructors check Metal residency sets.
     */
    if (!g_atexit_registered) {
        if (atexit(npl_llama_atexit_cleanup) == 0) {
            g_atexit_registered = 1;
        }
    }

    tkmt_static_mutex_unlock(&g_ll_lock);
    errno = saved_errno;
    return 1;
}

int
npl_llama_embed(const char *text, size_t text_len,
                float **out_vec, size_t *out_dim,
                char *errbuf, size_t errsz)
{
    int saved_errno = errno;
    if (out_vec) *out_vec = NULL;
    if (out_dim) *out_dim = 0;

    tkmt_static_mutex_lock(&g_ll_lock);
    ensure_llama_probed_locked();
    if (!g_ll.available) {
        set_err(errbuf, errsz, "libllama is not available");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (!g_ll.model || !g_ll.ctx || !g_ll.vocab) {
        set_err(errbuf, errsz, "no GGUF model loaded");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (g_ll.n_embd <= 0) {
        set_err(errbuf, errsz, "model reports invalid embedding dimension");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (!text && text_len > 0) {
        set_err(errbuf, errsz, "NULL text with non-zero length");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    clear_memory_locked();

    npl_llama_token_t *tokens = NULL;
    int32_t n_tok = 0;
    if (!tokenize_alloc_locked(text, text_len, true, false, &tokens, &n_tok, errbuf, errsz)) {
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    /* Clamp to active context / batch / ubatch limits */
    uint32_t limit = g_ll.n_ctx;
    if (g_ll.n_batch > 0 && (limit == 0 || g_ll.n_batch < limit)) limit = g_ll.n_batch;
    if (g_ll.n_ubatch > 0 && (limit == 0 || g_ll.n_ubatch < limit)) limit = g_ll.n_ubatch;
    if (limit > 0 && (uint32_t)n_tok > limit) {
        npl_llama_token_t last_tok = tokens[n_tok - 1];
        n_tok = (int32_t)limit;
        if (n_tok >= 2) {
            tokens[n_tok - 1] = last_tok;
        }
    }

    npl_llama_batch_t batch = g_ll.batch_init(n_tok, 0, 1);
    if (!batch.token || !batch.pos || !batch.n_seq_id || !batch.seq_id || !batch.logits) {
        g_ll.batch_free(batch);
        free(tokens);
        set_err(errbuf, errsz, "llama_batch_init failed");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    batch.n_tokens = n_tok;
    for (int32_t i = 0; i < n_tok; i++) {
        batch.token[i]     = tokens[i];
        batch.pos[i]       = (npl_llama_pos_t)i;
        batch.n_seq_id[i]  = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i]    = 1;
    }

    int32_t rc = -1;
    if (g_ll.has_encoder && g_ll.encode) {
        rc = g_ll.encode(g_ll.ctx, batch);
    } else if (g_ll.decode) {
        rc = g_ll.decode(g_ll.ctx, batch);
    }

    g_ll.batch_free(batch);
    free(tokens);

    if (rc != 0) {
        set_err(errbuf, errsz, g_ll.has_encoder ? "llama_encode failed" : "llama_decode failed");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    const float *emb = NULL;
    if (g_ll.get_embeddings_seq) {
        emb = g_ll.get_embeddings_seq(g_ll.ctx, 0);
    }
    if (!emb && g_ll.get_embeddings_ith) {
        emb = g_ll.get_embeddings_ith(g_ll.ctx, -1);
    }
    if (!emb && g_ll.get_embeddings) {
        emb = g_ll.get_embeddings(g_ll.ctx);
    }
    if (!emb) {
        set_err(errbuf, errsz, "failed to retrieve embeddings from llama context");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    size_t dim = (size_t)g_ll.n_embd;
    float *vec = (float *)malloc(dim * sizeof(float));
    if (!vec) {
        set_err(errbuf, errsz, "out of memory allocating embedding vector");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    npl_vec_normalize_f32(emb, vec, dim);
    if (out_vec) {
        *out_vec = vec;
    } else {
        free(vec);
    }
    if (out_dim) *out_dim = dim;
    g_ll.last_error[0] = '\0';

    tkmt_static_mutex_unlock(&g_ll_lock);
    errno = saved_errno;
    return 1;
}

int
npl_llama_complete(const char *prompt, size_t prompt_len,
                   int max_tokens, float temperature,
                   char **out_text, size_t *out_tokens,
                   char *errbuf, size_t errsz)
{
    int saved_errno = errno;
    if (out_text) *out_text = NULL;
    if (out_tokens) *out_tokens = 0;

    tkmt_static_mutex_lock(&g_ll_lock);
    ensure_llama_probed_locked();
    if (!g_ll.available) {
        set_err(errbuf, errsz, "libllama is not available");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (!g_ll.model || !g_ll.ctx || !g_ll.vocab) {
        set_err(errbuf, errsz, "no GGUF model loaded");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (!g_ll.has_decoder) {
        set_err(errbuf, errsz, "loaded model is encoder-only and does not support completion");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (g_ll.embeddings_mode) {
        set_err(errbuf, errsz, "model loaded in embeddings mode; reload with embeddings=0 for completion");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (!g_ll.sampler_chain_default_params || !g_ll.sampler_chain_init ||
        !g_ll.sampler_chain_add || !g_ll.sampler_init_greedy ||
        !g_ll.sampler_sample || !g_ll.sampler_free || !g_ll.token_to_piece) {
        set_err(errbuf, errsz, "required llama sampler symbols unavailable");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    if (!prompt && prompt_len > 0) {
        set_err(errbuf, errsz, "NULL prompt with non-zero length");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    if (max_tokens <= 0) max_tokens = 128;

    clear_memory_locked();

    npl_llama_token_t *tokens = NULL;
    int32_t n_prompt = 0;
    if (!tokenize_alloc_locked(prompt, prompt_len, true, true, &tokens, &n_prompt, errbuf, errsz)) {
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    if (g_ll.n_ctx > 0 && (uint32_t)n_prompt >= g_ll.n_ctx) {
        free(tokens);
        set_err(errbuf, errsz, "prompt exceeds context window");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    int32_t batch_cap = (g_ll.n_batch > 0 && g_ll.n_batch < (uint32_t)n_prompt)
                        ? (int32_t)g_ll.n_batch : n_prompt;
    if (batch_cap < 1) batch_cap = 1;

    npl_llama_batch_t batch = g_ll.batch_init(batch_cap, 0, 1);
    if (!batch.token || !batch.pos || !batch.n_seq_id || !batch.seq_id || !batch.logits) {
        g_ll.batch_free(batch);
        free(tokens);
        set_err(errbuf, errsz, "llama_batch_init failed");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    /* Decode prompt in batch_cap chunks */
    for (int32_t off = 0; off < n_prompt; off += batch_cap) {
        int32_t chunk = n_prompt - off;
        if (chunk > batch_cap) chunk = batch_cap;
        batch.n_tokens = chunk;
        for (int32_t i = 0; i < chunk; i++) {
            batch.token[i]     = tokens[off + i];
            batch.pos[i]       = (npl_llama_pos_t)(off + i);
            batch.n_seq_id[i]  = 1;
            batch.seq_id[i][0] = 0;
            batch.logits[i]    = ((off + i) == (n_prompt - 1)) ? 1 : 0;
        }
        int32_t rc = g_ll.decode(g_ll.ctx, batch);
        if (rc != 0) {
            g_ll.batch_free(batch);
            free(tokens);
            set_err(errbuf, errsz, "llama_decode failed on prompt");
            tkmt_static_mutex_unlock(&g_ll_lock);
            return 0;
        }
    }
    free(tokens);

    npl_llama_sampler_chain_params_t sparams = g_ll.sampler_chain_default_params();
    sparams.no_perf = true;
    npl_llama_sampler_t *smpl = g_ll.sampler_chain_init(sparams);
    if (!smpl) {
        g_ll.batch_free(batch);
        set_err(errbuf, errsz, "llama_sampler_chain_init failed");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }

    if (temperature <= 0.0f) {
        npl_llama_sampler_t *s_greedy = g_ll.sampler_init_greedy();
        if (s_greedy) g_ll.sampler_chain_add(smpl, s_greedy);
    } else {
        if (g_ll.sampler_init_temp) {
            npl_llama_sampler_t *s_temp = g_ll.sampler_init_temp(temperature);
            if (s_temp) g_ll.sampler_chain_add(smpl, s_temp);
        }
        if (g_ll.sampler_init_dist) {
            npl_llama_sampler_t *s_dist = g_ll.sampler_init_dist(NPL_LLAMA_DEFAULT_SEED);
            if (s_dist) g_ll.sampler_chain_add(smpl, s_dist);
        } else {
            npl_llama_sampler_t *s_greedy = g_ll.sampler_init_greedy();
            if (s_greedy) g_ll.sampler_chain_add(smpl, s_greedy);
        }
    }

    char *out_buf = (char *)malloc(256);
    if (!out_buf) {
        g_ll.sampler_free(smpl);
        g_ll.batch_free(batch);
        set_err(errbuf, errsz, "out of memory allocating completion buffer");
        tkmt_static_mutex_unlock(&g_ll_lock);
        return 0;
    }
    out_buf[0] = '\0';
    size_t out_len = 0;
    size_t out_cap = 256;
    size_t gen_toks = 0;
    int32_t cur_pos = n_prompt;

    for (int step = 0; step < max_tokens; step++) {
        npl_llama_token_t next_tok = g_ll.sampler_sample(smpl, g_ll.ctx, -1);

        int is_eog = 0;
        if (g_ll.vocab_is_eog) {
            is_eog = g_ll.vocab_is_eog(g_ll.vocab, next_tok) ? 1 : 0;
        } else if (g_ll.vocab_eos) {
            is_eog = (next_tok == g_ll.vocab_eos(g_ll.vocab)) ? 1 : 0;
        }
        if (is_eog) break;

        char piece_stack[256];
        int32_t plen = g_ll.token_to_piece(g_ll.vocab, next_tok, piece_stack,
                                           (int32_t)sizeof(piece_stack), 0, false);
        if (plen > 0) {
            if (!buf_append(&out_buf, &out_len, &out_cap, piece_stack, (size_t)plen)) {
                free(out_buf);
                g_ll.sampler_free(smpl);
                g_ll.batch_free(batch);
                set_err(errbuf, errsz, "out of memory growing completion buffer");
                tkmt_static_mutex_unlock(&g_ll_lock);
                return 0;
            }
        } else if (plen < 0 && plen != INT32_MIN) {
            int32_t need = -plen;
            char *dyn = (char *)malloc((size_t)need);
            if (!dyn) {
                free(out_buf);
                g_ll.sampler_free(smpl);
                g_ll.batch_free(batch);
                set_err(errbuf, errsz, "out of memory allocating token piece");
                tkmt_static_mutex_unlock(&g_ll_lock);
                return 0;
            }
            int32_t plen2 = g_ll.token_to_piece(g_ll.vocab, next_tok, dyn, need, 0, false);
            int ok_app = (plen2 > 0) ? buf_append(&out_buf, &out_len, &out_cap, dyn, (size_t)plen2) : 1;
            free(dyn);
            if (!ok_app) {
                free(out_buf);
                g_ll.sampler_free(smpl);
                g_ll.batch_free(batch);
                set_err(errbuf, errsz, "out of memory growing completion buffer");
                tkmt_static_mutex_unlock(&g_ll_lock);
                return 0;
            }
        }

        gen_toks++;

        if (step + 1 >= max_tokens) break;
        if (g_ll.n_ctx > 0 && (uint32_t)cur_pos >= g_ll.n_ctx) break;

        batch.n_tokens     = 1;
        batch.token[0]     = next_tok;
        batch.pos[0]       = (npl_llama_pos_t)cur_pos++;
        batch.n_seq_id[0]  = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0]    = 1;

        if (g_ll.decode(g_ll.ctx, batch) != 0) {
            break;
        }
    }

    g_ll.sampler_free(smpl);
    g_ll.batch_free(batch);

    if (out_text) {
        *out_text = out_buf;
    } else {
        free(out_buf);
    }
    if (out_tokens) *out_tokens = gen_toks;
    g_ll.last_error[0] = '\0';

    tkmt_static_mutex_unlock(&g_ll_lock);
    errno = saved_errno;
    return 1;
}

void
npl_llama_unload(void)
{
    int saved_errno = errno;
    tkmt_static_mutex_lock(&g_ll_lock);
    unload_locked();
    tkmt_static_mutex_unlock(&g_ll_lock);
    errno = saved_errno;
}
