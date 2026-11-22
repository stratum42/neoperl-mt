/*
 * c/llama_bridge.h - Runtime dlopen(libllama) bridge (zero build-time link dep)
 */
#ifndef NPL_LLAMA_BRIDGE_H
#define NPL_LLAMA_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct npl_llama_status {
    int  available;
    int  model_loaded;
    int  n_embd;
    char library_path[512];
    char model_path[512];
    char last_error[256];
} npl_llama_status_t;

int  npl_llama_available(void);
const char *npl_llama_library_path(void);
void npl_llama_status(npl_llama_status_t *out);

int  npl_llama_load_model(const char *gguf_path, int n_gpu_layers, int n_ctx,
                          int embeddings, char *errbuf, size_t errsz);
int  npl_llama_embed(const char *text, size_t text_len,
                     float **out_vec, size_t *out_dim,
                     char *errbuf, size_t errsz);
int  npl_llama_complete(const char *prompt, size_t prompt_len,
                        int max_tokens, float temperature,
                        char **out_text, size_t *out_tokens,
                        char *errbuf, size_t errsz);
void npl_llama_unload(void);

#ifdef __cplusplus
}
#endif

#endif /* NPL_LLAMA_BRIDGE_H */
