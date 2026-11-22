/*
 * c/diff.h - Pure C11 Myers O(ND) line diff engine
 */
#ifndef NPL_DIFF_H
#define NPL_DIFF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum npl_diff_kind {
    NPL_DIFF_ADD    = 1,
    NPL_DIFF_DEL    = 2,
    NPL_DIFF_CHANGE = 3
} npl_diff_kind_t;

typedef struct npl_diff_line {
    const char *ptr;
    size_t      len;
    uint64_t    hash;
} npl_diff_line_t;

typedef struct npl_diff_hunk {
    size_t          old_start;
    size_t          old_count;
    size_t          new_start;
    size_t          new_count;
    npl_diff_kind_t kind;
} npl_diff_hunk_t;

typedef struct npl_diff_result {
    npl_diff_hunk_t *hunks;
    size_t           count;
    size_t           cap;
} npl_diff_result_t;

uint64_t npl_diff_hash_line(const char *s, size_t len);

/* Compute structured Myers O(ND) hunks from pre-split line arrays */
int npl_diff_myers(const npl_diff_line_t *old_lines, size_t old_count,
                   const npl_diff_line_t *new_lines, size_t new_count,
                   npl_diff_result_t *out);

/* Convenience wrapper splitting two raw text buffers on '\n' */
int npl_diff_myers_text(const char *old_text, size_t old_len,
                        const char *new_text, size_t new_len,
                        npl_diff_result_t *out);

void npl_diff_result_free(npl_diff_result_t *res);

const char *npl_diff_kind_name(npl_diff_kind_t kind);

#ifdef __cplusplus
}
#endif

#endif /* NPL_DIFF_H */
