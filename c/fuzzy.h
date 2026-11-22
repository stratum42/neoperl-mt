/*
 * c/fuzzy.h - Multi-threaded C11 file walker, Smith-Waterman fuzzy scorer,
 *             and parallel SIMD-accelerated grep (PERL_FORCE_SCALAR=1 parity)
 */
#ifndef NPL_FUZZY_H
#define NPL_FUZZY_H

#include "buffer.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct npl_file_list {
    char **paths;
    size_t count;
    size_t cap;
} npl_file_list_t;

typedef struct npl_fuzzy_match {
    int32_t  score;
    uint32_t *positions;
    size_t    pos_count;
} npl_fuzzy_match_t;

typedef struct npl_fuzzy_item {
    size_t    orig_index;
    int32_t   score;
    uint32_t *positions;
    size_t    pos_count;
} npl_fuzzy_item_t;

typedef struct npl_fuzzy_results {
    npl_fuzzy_item_t *items;
    size_t            count;
} npl_fuzzy_results_t;

typedef struct npl_grep_hit {
    char  *path;
    size_t line;
    size_t col;
    size_t len;
    char  *preview;
} npl_grep_hit_t;

typedef struct npl_grep_results {
    npl_grep_hit_t *items;
    size_t          count;
    size_t          cap;
} npl_grep_results_t;

/* Parallel file walker (respects .gitignore, .git, blib, node_modules) */
int  npl_walk_files(const char *root_dir, size_t max_files, npl_file_list_t *out);
void npl_file_list_free(npl_file_list_t *list);

/* Smith-Waterman fuzzy scoring & filtering */
int  npl_fuzzy_score(const char *query, size_t qlen,
                     const char *cand, size_t clen,
                     npl_fuzzy_match_t *out);
void npl_fuzzy_match_free(npl_fuzzy_match_t *m);

int  npl_fuzzy_filter(const char *query, size_t qlen,
                      const char *const *cands, const size_t *clens, size_t n_cands,
                      size_t limit, npl_fuzzy_results_t *out);
void npl_fuzzy_results_free(npl_fuzzy_results_t *res);

/* Parallel project grep & buffer grep */
int  npl_grep_dir(const char *root_dir, const char *pattern, size_t pat_len,
                  int icase, size_t max_results, npl_grep_results_t *out);
int  npl_grep_buffer(npl_buf_t *buf, const char *pattern, size_t pat_len,
                     int icase, size_t max_results, npl_grep_results_t *out);
void npl_grep_results_free(npl_grep_results_t *res);

#ifdef __cplusplus
}
#endif

#endif /* NPL_FUZZY_H */
