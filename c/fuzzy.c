/*
 * c/fuzzy.c - Multi-threaded C11 parallel file walker, Smith-Waterman fuzzy
 *             scorer, and SIMD-accelerated parallel grep
 *
 * Honors PERL_FORCE_SCALAR=1 for deterministic bit-identical parity.
 * Strictly unsigned-char clean (safe on ppc64le).
 */
#if !defined(_WIN32) && !defined(__APPLE__)
#  if !defined(_GNU_SOURCE)
#    define _GNU_SOURCE
#  endif
#endif

#define NPL_ENABLE_ALTIVEC 1
#include "power_arch.h"
#include "tkmt_thread.h"
#include "fuzzy.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <dirent.h>
#  include <sys/stat.h>
#endif

#if !defined(_WIN32) && !NPL_HAVE_VSX_INTRINSICS
#  if defined(__aarch64__)
#    include <arm_neon.h>
#  elif defined(__SSE2__)
#    include <emmintrin.h>
#  endif
#endif

#define NPL_GREP_PREVIEW_MAX     200
#define NPL_GREP_MAX_FILE_BYTES  (32u * 1024u * 1024u)
#define NPL_FUZZY_MAX_QUERY      128
#define NPL_FUZZY_MAX_CAND       512

static inline unsigned char
ascii_lower(unsigned char c)
{
    return (c >= 'A' && c <= 'Z') ? (unsigned char)(c + ('a' - 'A')) : c;
}

static inline unsigned char
ascii_upper(unsigned char c)
{
    return (c >= 'a' && c <= 'z') ? (unsigned char)(c - ('a' - 'A')) : c;
}

static inline int
is_upper_ascii(unsigned char c)
{
    return c >= 'A' && c <= 'Z';
}

static inline int
is_lower_ascii(unsigned char c)
{
    return c >= 'a' && c <= 'z';
}

static inline int
is_sep_char(unsigned char c)
{
    return c == '/' || c == '\\' || c == '_' || c == '-' || c == '.' || c == ' ' || c == ':';
}

static char *
xstrdup_n(const char *s, size_t n)
{
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    if (n > 0) memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

/* Simple glob matcher supporting '*' and '?' for .gitignore rules */
static int
glob_match(const char *pat, const char *str)
{
    const char *p = pat;
    const char *s = str;
    const char *star_p = NULL;
    const char *star_s = NULL;

    while (*s) {
        if (*p == '*') {
            star_p = p++;
            star_s = s;
        } else if (*p == '?' || *p == *s) {
            p++;
            s++;
        } else if (star_p) {
            p = star_p + 1;
            s = ++star_s;
        } else {
            return 0;
        }
    }
    while (*p == '*') p++;
    return *p == '\0';
}

typedef struct npl_ignore_rules {
    char **pats;
    uint8_t *dir_only;
    size_t count;
    size_t cap;
} npl_ignore_rules_t;

static void
ignore_rules_free(npl_ignore_rules_t *ig)
{
    for (size_t i = 0; i < ig->count; i++) free(ig->pats[i]);
    free(ig->pats);
    free(ig->dir_only);
    memset(ig, 0, sizeof(*ig));
}

static void
ignore_rules_add(npl_ignore_rules_t *ig, const char *pat, int dir_only)
{
    if (!pat || !pat[0]) return;
    if (ig->count >= ig->cap) {
        size_t ncap = ig->cap ? ig->cap * 2 : 32;
        char **np = (char **)realloc(ig->pats, ncap * sizeof(char *));
        uint8_t *nd = (uint8_t *)realloc(ig->dir_only, ncap);
        if (!np || !nd) return;
        ig->pats = np;
        ig->dir_only = nd;
        ig->cap = ncap;
    }
    ig->pats[ig->count] = xstrdup_n(pat, strlen(pat));
    ig->dir_only[ig->count] = (uint8_t)(dir_only ? 1 : 0);
    if (ig->pats[ig->count]) ig->count++;
}

static void
load_gitignore(const char *root_dir, npl_ignore_rules_t *ig)
{
    memset(ig, 0, sizeof(*ig));
    /* Built-in ignores */
    ignore_rules_add(ig, ".git", 1);
    ignore_rules_add(ig, "blib", 1);
    ignore_rules_add(ig, "node_modules", 1);
    ignore_rules_add(ig, ".neoperl-build", 1);
    ignore_rules_add(ig, "__pycache__", 1);
    ignore_rules_add(ig, ".DS_Store", 0);

    size_t rlen = strlen(root_dir);
    char *gpath = (char *)malloc(rlen + 16);
    if (!gpath) return;
    memcpy(gpath, root_dir, rlen);
    memcpy(gpath + rlen, "/.gitignore", 12);

    FILE *fp = fopen(gpath, "r");
    free(gpath);
    if (!fp) return;

    char line[512];
    while (fgets(line, (int)sizeof(line), fp)) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r' ||
                           line[len - 1] == ' ' || line[len - 1] == '\t')) {
            len--;
        }
        size_t start = 0;
        while (start < len && (line[start] == ' ' || line[start] == '\t')) start++;
        if (start >= len || line[start] == '#' || line[start] == '!') continue;
        if (line[start] == '/') start++;
        int dir_only = 0;
        if (len > start && line[len - 1] == '/') {
            dir_only = 1;
            len--;
        }
        if (len > start) {
            line[len] = '\0';
            ignore_rules_add(ig, line + start, dir_only);
        }
    }
    fclose(fp);
}

static int
is_ignored(const npl_ignore_rules_t *ig, const char *name, const char *rel_path, int is_dir)
{
    for (size_t i = 0; i < ig->count; i++) {
        if (ig->dir_only[i] && !is_dir) continue;
        const char *pat = ig->pats[i];
        if (strchr(pat, '/') != NULL) {
            if (glob_match(pat, rel_path)) return 1;
        } else {
            if (glob_match(pat, name)) return 1;
        }
    }
    return 0;
}

/* Multi-threaded directory walker */
typedef struct walk_dir_item {
    char *rel; /* "" for root, else "sub/dir" */
} walk_dir_item_t;

typedef struct walk_ctx {
    const char              *root_dir;
    const npl_ignore_rules_t *ig;
    tkmt_mutex_t             lock;
    tkmt_cond_t              cond;
    walk_dir_item_t         *queue;
    size_t                   q_head;
    size_t                   q_tail;
    size_t                   q_cap;
    int                      active_workers;
    int                      done;
    npl_file_list_t          files;
    size_t                   soft_cap;
} walk_ctx_t;

static void
walk_push_dir_locked(walk_ctx_t *ctx, char *rel)
{
    if (ctx->q_tail >= ctx->q_cap) {
        size_t live = ctx->q_tail - ctx->q_head;
        if (ctx->q_head > 0 && live < ctx->q_cap / 2) {
            memmove(ctx->queue, ctx->queue + ctx->q_head, live * sizeof(walk_dir_item_t));
            ctx->q_head = 0;
            ctx->q_tail = live;
        } else {
            size_t ncap = ctx->q_cap ? ctx->q_cap * 2 : 64;
            walk_dir_item_t *nq = (walk_dir_item_t *)realloc(
                ctx->queue, ncap * sizeof(walk_dir_item_t));
            if (!nq) {
                free(rel);
                return;
            }
            ctx->queue = nq;
            ctx->q_cap = ncap;
        }
    }
    ctx->queue[ctx->q_tail++].rel = rel;
    tkmt_cond_signal(&ctx->cond);
}

static void
walk_push_file_locked(walk_ctx_t *ctx, char *rel)
{
    if (ctx->files.count >= ctx->files.cap) {
        size_t ncap = ctx->files.cap ? ctx->files.cap * 2 : 128;
        char **np = (char **)realloc(ctx->files.paths, ncap * sizeof(char *));
        if (!np) {
            free(rel);
            return;
        }
        ctx->files.paths = np;
        ctx->files.cap = ncap;
    }
    ctx->files.paths[ctx->files.count++] = rel;
}

static void
walk_scan_one_dir(walk_ctx_t *ctx, const char *rel)
{
    size_t rlen = strlen(ctx->root_dir);
    size_t dlen = strlen(rel);
    char *full = (char *)malloc(rlen + dlen + 4);
    if (!full) return;
    memcpy(full, ctx->root_dir, rlen);
    if (dlen > 0) {
        full[rlen] = '/';
        memcpy(full + rlen + 1, rel, dlen + 1);
    } else {
        full[rlen] = '\0';
    }

#if defined(_WIN32)
    size_t flen = strlen(full);
    char *pat = (char *)malloc(flen + 4);
    if (!pat) { free(full); return; }
    memcpy(pat, full, flen);
    memcpy(pat + flen, "\\*", 3);

    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pat, &fd);
    free(pat);
    if (h == INVALID_HANDLE_VALUE) {
        free(full);
        return;
    }
    do {
        const char *name = fd.cFileName;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        int is_dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
        size_t nlen = strlen(name);
        char *child_rel = (char *)malloc(dlen + nlen + 3);
        if (!child_rel) continue;
        if (dlen > 0) {
            memcpy(child_rel, rel, dlen);
            child_rel[dlen] = '/';
            memcpy(child_rel + dlen + 1, name, nlen + 1);
        } else {
            memcpy(child_rel, name, nlen + 1);
        }
        if (is_ignored(ctx->ig, name, child_rel, is_dir)) {
            free(child_rel);
            continue;
        }
        tkmt_mutex_lock(&ctx->lock);
        if (is_dir) {
            walk_push_dir_locked(ctx, child_rel);
        } else {
            walk_push_file_locked(ctx, child_rel);
        }
        tkmt_mutex_unlock(&ctx->lock);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    free(full);
#else
    DIR *dp = opendir(full);
    if (!dp) {
        free(full);
        return;
    }
    size_t flen = strlen(full);
    struct dirent *ent;
    while ((ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        size_t nlen = strlen(name);
        char *child_full = (char *)malloc(flen + nlen + 3);
        if (!child_full) continue;
        memcpy(child_full, full, flen);
        child_full[flen] = '/';
        memcpy(child_full + flen + 1, name, nlen + 1);

        struct stat st;
        int ok = (lstat(child_full, &st) == 0);
        free(child_full);
        if (!ok || S_ISLNK(st.st_mode)) continue;

        int is_dir = S_ISDIR(st.st_mode) ? 1 : 0;
        int is_reg = S_ISREG(st.st_mode) ? 1 : 0;
        if (!is_dir && !is_reg) continue;

        char *child_rel = (char *)malloc(dlen + nlen + 3);
        if (!child_rel) continue;
        if (dlen > 0) {
            memcpy(child_rel, rel, dlen);
            child_rel[dlen] = '/';
            memcpy(child_rel + dlen + 1, name, nlen + 1);
        } else {
            memcpy(child_rel, name, nlen + 1);
        }

        if (is_ignored(ctx->ig, name, child_rel, is_dir)) {
            free(child_rel);
            continue;
        }

        tkmt_mutex_lock(&ctx->lock);
        if (is_dir) {
            walk_push_dir_locked(ctx, child_rel);
        } else {
            walk_push_file_locked(ctx, child_rel);
        }
        tkmt_mutex_unlock(&ctx->lock);
    }
    closedir(dp);
    free(full);
#endif
}

static tkmt_thread_ret_t TKMT_THREAD_CALL
walk_worker_fn(void *arg)
{
    walk_ctx_t *ctx = (walk_ctx_t *)arg;
    for (;;) {
        tkmt_mutex_lock(&ctx->lock);
        while (ctx->q_head == ctx->q_tail && !ctx->done) {
            if (ctx->active_workers == 0) {
                ctx->done = 1;
                tkmt_cond_broadcast(&ctx->cond);
                break;
            }
            tkmt_cond_wait(&ctx->cond, &ctx->lock);
        }
        if (ctx->done) {
            tkmt_mutex_unlock(&ctx->lock);
            break;
        }
        char *rel = ctx->queue[ctx->q_head++].rel;
        ctx->active_workers++;
        tkmt_mutex_unlock(&ctx->lock);

        walk_scan_one_dir(ctx, rel);
        free(rel);

        tkmt_mutex_lock(&ctx->lock);
        ctx->active_workers--;
        if (ctx->q_head == ctx->q_tail && ctx->active_workers == 0) {
            ctx->done = 1;
            tkmt_cond_broadcast(&ctx->cond);
        }
        tkmt_mutex_unlock(&ctx->lock);
    }
    TKMT_THREAD_RETURN_ZERO;
}

static int
cmp_str_ptr(const void *a, const void *b)
{
    const char *sa = *(const char *const *)a;
    const char *sb = *(const char *const *)b;
    return strcmp(sa, sb);
}

int
npl_walk_files(const char *root_dir, size_t max_files, npl_file_list_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!root_dir || !root_dir[0]) return 0;

    npl_ignore_rules_t ig;
    load_gitignore(root_dir, &ig);

    walk_ctx_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.root_dir = root_dir;
    ctx.ig = &ig;
    ctx.soft_cap = max_files;
    tkmt_mutex_init(&ctx.lock);
    tkmt_cond_init(&ctx.cond);

    char *init_rel = xstrdup_n("", 0);
    if (!init_rel) {
        tkmt_cond_destroy(&ctx.cond);
        tkmt_mutex_destroy(&ctx.lock);
        ignore_rules_free(&ig);
        return 0;
    }
    walk_push_dir_locked(&ctx, init_rel);

    npl_arch_info_t ai;
    npl_detect_arch_info(&ai);
    int nworkers = ai.recommended_workers;
    if (nworkers > 8) nworkers = 8;
    if (nworkers < 1) nworkers = 1;

    if (nworkers == 1) {
        walk_worker_fn(&ctx);
    } else {
        tkmt_thread_t threads[8];
        int launched = 0;
        for (int i = 0; i < nworkers; i++) {
            if (tkmt_thread_create(&threads[launched], walk_worker_fn, &ctx) == 0) {
                launched++;
            }
        }
        if (launched == 0) {
            walk_worker_fn(&ctx);
        } else {
            for (int i = 0; i < launched; i++) {
                tkmt_thread_join(threads[i]);
            }
        }
    }

    free(ctx.queue);
    tkmt_cond_destroy(&ctx.cond);
    tkmt_mutex_destroy(&ctx.lock);
    ignore_rules_free(&ig);

    /* Sort deterministically before applying max_files truncation */
    if (ctx.files.count > 1) {
        qsort(ctx.files.paths, ctx.files.count, sizeof(char *), cmp_str_ptr);
    }
    if (max_files > 0 && ctx.files.count > max_files) {
        for (size_t i = max_files; i < ctx.files.count; i++) {
            free(ctx.files.paths[i]);
        }
        ctx.files.count = max_files;
    }
    *out = ctx.files;
    return 1;
}

void
npl_file_list_free(npl_file_list_t *list)
{
    if (!list) return;
    for (size_t i = 0; i < list->count; i++) free(list->paths[i]);
    free(list->paths);
    list->paths = NULL;
    list->count = 0;
    list->cap = 0;
}

/* Smith-Waterman fuzzy scorer returning exact matched indices */
int
npl_fuzzy_score(const char *query, size_t qlen,
                const char *cand, size_t clen,
                npl_fuzzy_match_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!cand) return 0;
    if (!query || qlen == 0) {
        out->score = 1;
        return 1;
    }
    if (qlen > clen) return 0;

    /* Fast case-insensitive subsequence pre-filter */
    size_t qi = 0;
    for (size_t ci = 0; ci < clen && qi < qlen; ci++) {
        if (ascii_lower((unsigned char)cand[ci]) == ascii_lower((unsigned char)query[qi])) {
            qi++;
        }
    }
    if (qi < qlen) return 0;

    size_t qn = (qlen > NPL_FUZZY_MAX_QUERY) ? NPL_FUZZY_MAX_QUERY : qlen;
    size_t cn = (clen > NPL_FUZZY_MAX_CAND) ? NPL_FUZZY_MAX_CAND : clen;

    /* Find basename offset for path-aware bonus */
    size_t base_off = 0;
    for (size_t j = 0; j < cn; j++) {
        if (cand[j] == '/' || cand[j] == '\\') base_off = j + 1;
    }

    int32_t bonus[NPL_FUZZY_MAX_CAND];
    for (size_t j = 0; j < cn; j++) {
        unsigned char c = (unsigned char)cand[j];
        int32_t b = 0;
        if (j == 0 || j == base_off) {
            b += 16;
        } else {
            unsigned char prev = (unsigned char)cand[j - 1];
            if (is_sep_char(prev)) {
                b += 14;
            } else if (is_lower_ascii(prev) && is_upper_ascii(c)) {
                b += 12;
            }
        }
        if (j >= base_off) b += 4;
        bonus[j] = b;
    }

    size_t stride = cn + 1;
    int32_t *M = (int32_t *)malloc((qn + 1) * stride * sizeof(int32_t));
    int32_t *D = (int32_t *)malloc((qn + 1) * stride * sizeof(int32_t));
    if (!M || !D) {
        free(M);
        free(D);
        return 0;
    }

    const int32_t NEG_INF = -1000000;
    for (size_t i = 0; i <= qn; i++) {
        for (size_t j = 0; j <= cn; j++) {
            M[i * stride + j] = NEG_INF;
            D[i * stride + j] = NEG_INF;
        }
    }
    for (size_t j = 0; j <= cn; j++) {
        M[j] = 0;
    }

    for (size_t i = 1; i <= qn; i++) {
        unsigned char qc = (unsigned char)query[i - 1];
        unsigned char qlo = ascii_lower(qc);
        for (size_t j = i; j <= cn; j++) {
            unsigned char cc = (unsigned char)cand[j - 1];
            unsigned char clo = ascii_lower(cc);

            /* Best skipping candidate j-1 */
            int32_t best_skip = M[i * stride + (j - 1)];
            if (best_skip > NEG_INF / 2) {
                best_skip -= 1; /* gap extend penalty */
            }
            int32_t best_m = best_skip;

            if (clo == qlo) {
                int32_t match_sc = 16 + bonus[j - 1] + ((qc == cc) ? 2 : 0);
                int32_t from_prev_m = M[(i - 1) * stride + (j - 1)];
                int32_t from_prev_d = D[(i - 1) * stride + (j - 1)];

                int32_t diag = NEG_INF;
                if (from_prev_m > NEG_INF / 2) {
                    int32_t cand_m = from_prev_m + match_sc;
                    if (i > 1) cand_m -= 3; /* gap open */
                    if (cand_m > diag) diag = cand_m;
                }
                if (from_prev_d > NEG_INF / 2) {
                    int32_t cand_d = from_prev_d + match_sc + 10; /* consecutive bonus */
                    if (cand_d > diag) diag = cand_d;
                }
                D[i * stride + j] = diag;
                if (diag > best_m) best_m = diag;
            }
            M[i * stride + j] = best_m;
        }
    }

    /* Find best ending column for row qn */
    int32_t best_score = NEG_INF;
    size_t best_j = 0;
    for (size_t j = qn; j <= cn; j++) {
        int32_t v = D[qn * stride + j];
        if (v > best_score) {
            best_score = v;
            best_j = j;
        }
    }

    if (best_score <= NEG_INF / 2) {
        free(M);
        free(D);
        return 0;
    }

    /* Backtrack matched positions */
    uint32_t *pos = (uint32_t *)malloc(qn * sizeof(uint32_t));
    if (!pos) {
        free(M);
        free(D);
        return 0;
    }

    size_t i = qn;
    size_t j = best_j;
    int in_diag = 1;
    while (i > 0 && j > 0) {
        if (in_diag) {
            pos[i - 1] = (uint32_t)(j - 1);
            int32_t cur = D[i * stride + j];
            unsigned char qc = (unsigned char)query[i - 1];
            unsigned char cc = (unsigned char)cand[j - 1];
            int32_t match_sc = 16 + bonus[j - 1] + ((qc == cc) ? 2 : 0);
            int32_t prev_d = D[(i - 1) * stride + (j - 1)];
            if (prev_d > NEG_INF / 2 && prev_d + match_sc + 10 == cur) {
                i--;
                j--;
                in_diag = 1;
            } else {
                i--;
                j--;
                in_diag = 0;
            }
        } else {
            if (D[i * stride + j] == M[i * stride + j]) {
                in_diag = 1;
            } else {
                j--;
            }
        }
    }

    free(M);
    free(D);

    /* Slight length penalty to prefer tighter matches */
    int32_t final_score = best_score - (int32_t)(clen / 8);
    if (final_score < 1) final_score = 1;

    out->score = final_score;
    out->positions = pos;
    out->pos_count = qn;
    return 1;
}

void
npl_fuzzy_match_free(npl_fuzzy_match_t *m)
{
    if (!m) return;
    free(m->positions);
    m->positions = NULL;
    m->pos_count = 0;
    m->score = 0;
}

typedef struct sort_fuzzy_entry {
    npl_fuzzy_item_t item;
    const char      *text;
    size_t           len;
} sort_fuzzy_entry_t;

static int
cmp_fuzzy_entry(const void *a, const void *b)
{
    const sort_fuzzy_entry_t *ea = (const sort_fuzzy_entry_t *)a;
    const sort_fuzzy_entry_t *eb = (const sort_fuzzy_entry_t *)b;
    if (ea->item.score != eb->item.score) {
        return (ea->item.score > eb->item.score) ? -1 : 1;
    }
    if (ea->len != eb->len) {
        return (ea->len < eb->len) ? -1 : 1;
    }
    int c = strcmp(ea->text, eb->text);
    if (c != 0) return c;
    return (ea->item.orig_index < eb->item.orig_index) ? -1 : 1;
}

int
npl_fuzzy_filter(const char *query, size_t qlen,
                 const char *const *cands, const size_t *clens, size_t n_cands,
                 size_t limit, npl_fuzzy_results_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!cands || n_cands == 0) return 1;

    sort_fuzzy_entry_t *buf = (sort_fuzzy_entry_t *)malloc(n_cands * sizeof(sort_fuzzy_entry_t));
    if (!buf) return 0;
    size_t matched = 0;

    for (size_t i = 0; i < n_cands; i++) {
        const char *s = cands[i] ? cands[i] : "";
        size_t sl = clens ? clens[i] : strlen(s);
        npl_fuzzy_match_t m;
        if (npl_fuzzy_score(query, qlen, s, sl, &m)) {
            buf[matched].item.orig_index = i;
            buf[matched].item.score = m.score;
            buf[matched].item.positions = m.positions;
            buf[matched].item.pos_count = m.pos_count;
            buf[matched].text = s;
            buf[matched].len = sl;
            matched++;
        }
    }

    if (matched > 1) {
        qsort(buf, matched, sizeof(sort_fuzzy_entry_t), cmp_fuzzy_entry);
    }

    size_t keep = (limit > 0 && matched > limit) ? limit : matched;
    if (keep > 0) {
        out->items = (npl_fuzzy_item_t *)malloc(keep * sizeof(npl_fuzzy_item_t));
        if (!out->items) {
            for (size_t i = 0; i < matched; i++) free(buf[i].item.positions);
            free(buf);
            return 0;
        }
        for (size_t i = 0; i < keep; i++) {
            out->items[i] = buf[i].item;
        }
        for (size_t i = keep; i < matched; i++) {
            free(buf[i].item.positions);
        }
        out->count = keep;
    }
    free(buf);
    return 1;
}

void
npl_fuzzy_results_free(npl_fuzzy_results_t *res)
{
    if (!res) return;
    for (size_t i = 0; i < res->count; i++) {
        free(res->items[i].positions);
    }
    free(res->items);
    res->items = NULL;
    res->count = 0;
}

/* SIMD-accelerated first-byte substring search (VSX / NEON / SSE2 / scalar) */
static const char *
find_substr_simd(const char *hay, size_t hlen, const char *needle, size_t nlen,
                 int icase, int force_scalar)
{
    if (nlen == 0 || nlen > hlen) return NULL;
    const uint8_t *h = (const uint8_t *)hay;
    size_t max_start = hlen - nlen;

    if (!icase) {
        uint8_t first = (uint8_t)needle[0];
        size_t i = 0;

        if (!force_scalar && max_start + 1 >= 16) {
#if NPL_HAVE_VSX_INTRINSICS
            const __vector unsigned char fv = vec_splats((unsigned char)first);
            while (i + 16 <= max_start + 1) {
                __vector unsigned char chunk = vec_xl(0, h + i);
                if (vec_any_eq(chunk, fv)) {
                    for (size_t k = 0; k < 16; k++) {
                        if (h[i + k] == first &&
                            (nlen == 1 || memcmp(h + i + k + 1, needle + 1, nlen - 1) == 0)) {
                            return hay + i + k;
                        }
                    }
                }
                i += 16;
            }
#elif !defined(_WIN32) && defined(__aarch64__)
            const uint8x16_t fv = vdupq_n_u8(first);
            while (i + 16 <= max_start + 1) {
                uint8x16_t chunk = vld1q_u8(h + i);
                if (vmaxvq_u8(vceqq_u8(chunk, fv)) != 0) {
                    for (size_t k = 0; k < 16; k++) {
                        if (h[i + k] == first &&
                            (nlen == 1 || memcmp(h + i + k + 1, needle + 1, nlen - 1) == 0)) {
                            return hay + i + k;
                        }
                    }
                }
                i += 16;
            }
#elif !defined(_WIN32) && defined(__SSE2__)
            const __m128i fv = _mm_set1_epi8((char)first);
            while (i + 16 <= max_start + 1) {
                __m128i chunk = _mm_loadu_si128((const __m128i *)(const void *)(h + i));
                unsigned mask = (unsigned)_mm_movemask_epi8(_mm_cmpeq_epi8(chunk, fv));
                while (mask != 0u) {
                    unsigned k = (unsigned)__builtin_ctz(mask);
                    if (nlen == 1 || memcmp(h + i + k + 1, needle + 1, nlen - 1) == 0) {
                        return hay + i + k;
                    }
                    mask &= mask - 1u;
                }
                i += 16;
            }
#endif
        }

        while (i <= max_start) {
            const char *hit = (const char *)memchr(hay + i, (int)first, max_start - i + 1);
            if (!hit) return NULL;
            if (nlen == 1 || memcmp(hit + 1, needle + 1, nlen - 1) == 0) {
                return hit;
            }
            i = (size_t)(hit - hay) + 1;
        }
        return NULL;
    } else {
        uint8_t f_lo = ascii_lower((unsigned char)needle[0]);
        uint8_t f_hi = ascii_upper((unsigned char)needle[0]);
        size_t i = 0;

        if (!force_scalar && max_start + 1 >= 16) {
#if NPL_HAVE_VSX_INTRINSICS
            const __vector unsigned char vlo = vec_splats((unsigned char)f_lo);
            const __vector unsigned char vhi = vec_splats((unsigned char)f_hi);
            while (i + 16 <= max_start + 1) {
                __vector unsigned char chunk = vec_xl(0, h + i);
                if (vec_any_eq(chunk, vlo) || vec_any_eq(chunk, vhi)) {
                    for (size_t k = 0; k < 16; k++) {
                        uint8_t c = h[i + k];
                        if (c == f_lo || c == f_hi) {
                            size_t j = 1;
                            while (j < nlen &&
                                   ascii_lower(h[i + k + j]) == ascii_lower((unsigned char)needle[j])) {
                                j++;
                            }
                            if (j == nlen) return hay + i + k;
                        }
                    }
                }
                i += 16;
            }
#elif !defined(_WIN32) && defined(__aarch64__)
            const uint8x16_t vlo = vdupq_n_u8(f_lo);
            const uint8x16_t vhi = vdupq_n_u8(f_hi);
            while (i + 16 <= max_start + 1) {
                uint8x16_t chunk = vld1q_u8(h + i);
                uint8x16_t eq = vorrq_u8(vceqq_u8(chunk, vlo), vceqq_u8(chunk, vhi));
                if (vmaxvq_u8(eq) != 0) {
                    for (size_t k = 0; k < 16; k++) {
                        uint8_t c = h[i + k];
                        if (c == f_lo || c == f_hi) {
                            size_t j = 1;
                            while (j < nlen &&
                                   ascii_lower(h[i + k + j]) == ascii_lower((unsigned char)needle[j])) {
                                j++;
                            }
                            if (j == nlen) return hay + i + k;
                        }
                    }
                }
                i += 16;
            }
#elif !defined(_WIN32) && defined(__SSE2__)
            const __m128i vlo = _mm_set1_epi8((char)f_lo);
            const __m128i vhi = _mm_set1_epi8((char)f_hi);
            while (i + 16 <= max_start + 1) {
                __m128i chunk = _mm_loadu_si128((const __m128i *)(const void *)(h + i));
                __m128i eq = _mm_or_si128(_mm_cmpeq_epi8(chunk, vlo), _mm_cmpeq_epi8(chunk, vhi));
                unsigned mask = (unsigned)_mm_movemask_epi8(eq);
                while (mask != 0u) {
                    unsigned k = (unsigned)__builtin_ctz(mask);
                    size_t j = 1;
                    while (j < nlen &&
                           ascii_lower(h[i + k + j]) == ascii_lower((unsigned char)needle[j])) {
                        j++;
                    }
                    if (j == nlen) return hay + i + k;
                    mask &= mask - 1u;
                }
                i += 16;
            }
#endif
        }

        for (; i <= max_start; i++) {
            uint8_t c = h[i];
            if (c != f_lo && c != f_hi) continue;
            size_t j = 1;
            while (j < nlen &&
                   ascii_lower(h[i + j]) == ascii_lower((unsigned char)needle[j])) {
                j++;
            }
            if (j == nlen) return hay + i;
        }
        return NULL;
    }
}

static char *
make_preview(const char *line, size_t len)
{
    size_t s = 0;
    while (s < len && (line[s] == ' ' || line[s] == '\t')) s++;
    size_t e = len;
    while (e > s && (line[e - 1] == ' ' || line[e - 1] == '\t' ||
                     line[e - 1] == '\r' || line[e - 1] == '\n')) {
        e--;
    }
    size_t plen = e - s;
    if (plen > NPL_GREP_PREVIEW_MAX) plen = NPL_GREP_PREVIEW_MAX;
    return xstrdup_n(line + s, plen);
}

static int
grep_push_hit(npl_grep_results_t *res, const char *path,
              size_t line, size_t col, size_t len,
              const char *line_text, size_t line_len)
{
    if (res->count >= res->cap) {
        size_t ncap = res->cap ? res->cap * 2 : 32;
        npl_grep_hit_t *ni = (npl_grep_hit_t *)realloc(
            res->items, ncap * sizeof(npl_grep_hit_t));
        if (!ni) return 0;
        res->items = ni;
        res->cap = ncap;
    }
    npl_grep_hit_t *hit = &res->items[res->count++];
    hit->path = path ? xstrdup_n(path, strlen(path)) : NULL;
    hit->line = line;
    hit->col = col;
    hit->len = len;
    hit->preview = make_preview(line_text, line_len);
    return 1;
}

static void
grep_file_into(const char *full_path, const char *rel_path,
               const char *pattern, size_t pat_len, int icase,
               int force_scalar, size_t per_file_cap, npl_grep_results_t *out)
{
    FILE *fp = fopen(full_path, "rb");
    if (!fp) return;
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return; }
    long fsz = ftell(fp);
    if (fsz <= 0 || (size_t)fsz > NPL_GREP_MAX_FILE_BYTES) { fclose(fp); return; }
    if (fseek(fp, 0, SEEK_SET) != 0) { fclose(fp); return; }

    size_t sz = (size_t)fsz;
    char *buf = (char *)malloc(sz);
    if (!buf) { fclose(fp); return; }
    size_t got = fread(buf, 1, sz, fp);
    fclose(fp);

    /* Skip binary files (NUL byte in first 4 KiB) */
    size_t check_n = (got < 4096) ? got : 4096;
    if (memchr(buf, '\0', check_n) != NULL) {
        free(buf);
        return;
    }

    size_t pos = 0;
    size_t line_idx = 0;
    while (pos < got && out->count < per_file_cap) {
        const char *nl = (const char *)memchr(buf + pos, '\n', got - pos);
        size_t end = nl ? (size_t)(nl - buf) : got;
        size_t llen = end - pos;
        if (llen > 0 && buf[pos + llen - 1] == '\r') llen--;

        size_t scan = 0;
        while (scan < llen && out->count < per_file_cap) {
            const char *hit = find_substr_simd(buf + pos + scan, llen - scan,
                                               pattern, pat_len, icase, force_scalar);
            if (!hit) break;
            size_t col = (size_t)(hit - (buf + pos));
            grep_push_hit(out, rel_path, line_idx, col, pat_len, buf + pos, llen);
            scan = col + pat_len;
        }
        line_idx++;
        if (!nl) break;
        pos = end + 1;
    }

    free(buf);
}

typedef struct grep_job_ctx {
    const char         *root_dir;
    const char *const  *rel_paths;
    size_t              file_count;
    const char         *pattern;
    size_t              pat_len;
    int                 icase;
    int                 force_scalar;
    size_t              max_results;
    npl_grep_results_t *slots;
    size_t              next_idx;
} grep_job_ctx_t;

static tkmt_thread_ret_t TKMT_THREAD_CALL
grep_worker_fn(void *arg)
{
    grep_job_ctx_t *ctx = (grep_job_ctx_t *)arg;
    size_t rlen = strlen(ctx->root_dir);
    for (;;) {
        size_t idx = npl_atomic_fetch_add_acq_rel(&ctx->next_idx, 1);
        if (idx >= ctx->file_count) break;
        const char *rel = ctx->rel_paths[idx];
        size_t dlen = strlen(rel);
        char *full = (char *)malloc(rlen + dlen + 3);
        if (!full) continue;
        memcpy(full, ctx->root_dir, rlen);
        full[rlen] = '/';
        memcpy(full + rlen + 1, rel, dlen + 1);

        grep_file_into(full, rel, ctx->pattern, ctx->pat_len,
                       ctx->icase, ctx->force_scalar, ctx->max_results, &ctx->slots[idx]);
        free(full);
    }
    TKMT_THREAD_RETURN_ZERO;
}

int
npl_grep_dir(const char *root_dir, const char *pattern, size_t pat_len,
             int icase, size_t max_results, npl_grep_results_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!root_dir || !pattern || pat_len == 0) return 1;
    if (max_results == 0) max_results = 2000;

    npl_file_list_t flist;
    if (!npl_walk_files(root_dir, 0, &flist)) return 0;
    if (flist.count == 0) {
        npl_file_list_free(&flist);
        return 1;
    }

    npl_grep_results_t *slots = (npl_grep_results_t *)calloc(
        flist.count, sizeof(npl_grep_results_t));
    if (!slots) {
        npl_file_list_free(&flist);
        return 0;
    }

    npl_arch_info_t ai;
    npl_detect_arch_info(&ai);
    int force_scalar = npl_arch_force_scalar();
    int nworkers = force_scalar ? 1 : ai.recommended_workers;
    if (nworkers > 8) nworkers = 8;
    if ((size_t)nworkers > flist.count) nworkers = (int)flist.count;
    if (nworkers < 1) nworkers = 1;

    grep_job_ctx_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.root_dir = root_dir;
    ctx.rel_paths = (const char *const *)flist.paths;
    ctx.file_count = flist.count;
    ctx.pattern = pattern;
    ctx.pat_len = pat_len;
    ctx.icase = icase;
    ctx.force_scalar = force_scalar;
    ctx.max_results = max_results;
    ctx.slots = slots;
    ctx.next_idx = 0;

    if (nworkers == 1) {
        grep_worker_fn(&ctx);
    } else {
        tkmt_thread_t threads[8];
        int launched = 0;
        for (int i = 0; i < nworkers; i++) {
            if (tkmt_thread_create(&threads[launched], grep_worker_fn, &ctx) == 0) {
                launched++;
            }
        }
        if (launched == 0) {
            grep_worker_fn(&ctx);
        } else {
            for (int i = 0; i < launched; i++) {
                tkmt_thread_join(threads[i]);
            }
        }
    }

    /* Merge per-file slots in strict deterministic file order */
    for (size_t i = 0; i < flist.count; i++) {
        for (size_t j = 0; j < slots[i].count; j++) {
            if (out->count < max_results) {
                if (out->count >= out->cap) {
                    size_t ncap = out->cap ? out->cap * 2 : 64;
                    npl_grep_hit_t *ni = (npl_grep_hit_t *)realloc(
                        out->items, ncap * sizeof(npl_grep_hit_t));
                    if (!ni) {
                        free(slots[i].items[j].path);
                        free(slots[i].items[j].preview);
                        continue;
                    }
                    out->items = ni;
                    out->cap = ncap;
                }
                out->items[out->count++] = slots[i].items[j];
            } else {
                free(slots[i].items[j].path);
                free(slots[i].items[j].preview);
            }
        }
        free(slots[i].items);
    }

    free(slots);
    npl_file_list_free(&flist);
    return 1;
}

int
npl_grep_buffer(npl_buf_t *buf, const char *pattern, size_t pat_len,
                int icase, size_t max_results, npl_grep_results_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!buf || !pattern || pat_len == 0) return 1;
    if (max_results == 0) max_results = 2000;

    int force_scalar = npl_arch_force_scalar();
    size_t total = npl_buf_line_count(buf);
    char stack_buf[4096];

    for (size_t line = 0; line < total && out->count < max_results; line++) {
        size_t llen = npl_buf_get_line_buf(buf, line, stack_buf, sizeof(stack_buf));
        char *heap_buf = NULL;
        const char *lptr = stack_buf;
        if (llen >= sizeof(stack_buf)) {
            heap_buf = npl_buf_get_line_alloc(buf, line, &llen);
            if (heap_buf) lptr = heap_buf;
        }
        size_t scan = 0;
        while (scan < llen && out->count < max_results) {
            const char *hit = find_substr_simd(lptr + scan, llen - scan,
                                               pattern, pat_len, icase, force_scalar);
            if (!hit) break;
            size_t col = (size_t)(hit - lptr);
            grep_push_hit(out, NULL, line, col, pat_len, lptr, llen);
            scan = col + pat_len;
        }
        free(heap_buf);
    }
    return 1;
}

void
npl_grep_results_free(npl_grep_results_t *res)
{
    if (!res) return;
    for (size_t i = 0; i < res->count; i++) {
        free(res->items[i].path);
        free(res->items[i].preview);
    }
    free(res->items);
    res->items = NULL;
    res->count = 0;
    res->cap = 0;
}
