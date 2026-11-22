/*
 * c/diff.c - Pure C11 Myers O(ND) shortest-edit-script line diff engine
 */
#include "diff.h"

#include <stdlib.h>
#include <string.h>

uint64_t
npl_diff_hash_line(const char *s, size_t len)
{
    /* FNV-1a 64-bit */
    uint64_t h = 14695981039346656037ULL;
    const unsigned char *p = (const unsigned char *)s;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint64_t)p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static inline int
lines_equal(const npl_diff_line_t *a, const npl_diff_line_t *b)
{
    if (a->len != b->len || a->hash != b->hash) return 0;
    if (a->len == 0) return 1;
    return memcmp(a->ptr, b->ptr, a->len) == 0;
}

static int
push_hunk(npl_diff_result_t *res, size_t old_start, size_t old_count,
          size_t new_start, size_t new_count)
{
    if (old_count == 0 && new_count == 0) return 1;
    if (res->count >= res->cap) {
        size_t ncap = res->cap ? res->cap * 2 : 16;
        npl_diff_hunk_t *nh = (npl_diff_hunk_t *)realloc(
            res->hunks, ncap * sizeof(npl_diff_hunk_t));
        if (!nh) return 0;
        res->hunks = nh;
        res->cap = ncap;
    }
    npl_diff_hunk_t *h = &res->hunks[res->count++];
    h->old_start = old_start;
    h->old_count = old_count;
    h->new_start = new_start;
    h->new_count = new_count;
    if (old_count == 0) {
        h->kind = NPL_DIFF_ADD;
    } else if (new_count == 0) {
        h->kind = NPL_DIFF_DEL;
    } else {
        h->kind = NPL_DIFF_CHANGE;
    }
    return 1;
}

/* Edit step tags for backtracking */
enum {
    EDIT_KEEP = 0,
    EDIT_DEL  = 1,
    EDIT_INS  = 2
};

int
npl_diff_myers(const npl_diff_line_t *old_lines, size_t old_count,
               const npl_diff_line_t *new_lines, size_t new_count,
               npl_diff_result_t *out)
{
    memset(out, 0, sizeof(*out));

    /* Trim common prefix */
    size_t prefix = 0;
    while (prefix < old_count && prefix < new_count &&
           lines_equal(&old_lines[prefix], &new_lines[prefix])) {
        prefix++;
    }

    /* Trim common suffix */
    size_t suffix = 0;
    while (suffix + prefix < old_count && suffix + prefix < new_count &&
           lines_equal(&old_lines[old_count - 1 - suffix],
                       &new_lines[new_count - 1 - suffix])) {
        suffix++;
    }

    size_t n = old_count - prefix - suffix;
    size_t m = new_count - prefix - suffix;

    if (n == 0 && m == 0) return 1;
    if (n == 0) {
        return push_hunk(out, prefix, 0, prefix, m);
    }
    if (m == 0) {
        return push_hunk(out, prefix, n, prefix, 0);
    }

    const npl_diff_line_t *A = old_lines + prefix;
    const npl_diff_line_t *B = new_lines + prefix;

    size_t max_d = n + m;
    /* Guard memory on giant disjoint diffs (> 8192 edit distance -> single change hunk) */
    const size_t MYERS_CAP = 8192;
    if (max_d > MYERS_CAP) {
        max_d = MYERS_CAP;
    }

    size_t v_len = 2 * max_d + 1;
    int offset = (int)max_d;

    int *v = (int *)malloc(v_len * sizeof(int));
    if (!v) return 0;
    for (size_t i = 0; i < v_len; i++) v[i] = 0;

    /* Store trace snapshots: trace[d] has length (2*d + 1) covering k in [-d, +d] */
    int **trace = (int **)calloc(max_d + 1, sizeof(int *));
    if (!trace) {
        free(v);
        return 0;
    }

    int found_d = -1;
    for (int d = 0; d <= (int)max_d; d++) {
        size_t snap_len = (size_t)(2 * d + 1);
        int *snap = (int *)malloc(snap_len * sizeof(int));
        if (!snap) {
            for (int j = 0; j < d; j++) free(trace[j]);
            free(trace);
            free(v);
            return 0;
        }
        trace[d] = snap;

        for (int k = -d; k <= d; k += 2) {
            int x;
            if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
                x = v[offset + k + 1]; /* down: insert */
            } else {
                x = v[offset + k - 1] + 1; /* right: delete */
            }
            int y = x - k;
            while (x < (int)n && y < (int)m && lines_equal(&A[x], &B[y])) {
                x++;
                y++;
            }
            v[offset + k] = x;
            snap[k + d] = x;

            if (x >= (int)n && y >= (int)m) {
                found_d = d;
                break;
            }
        }
        if (found_d >= 0) break;
    }

    free(v);

    if (found_d < 0) {
        for (size_t j = 0; j <= max_d; j++) free(trace[j]);
        free(trace);
        return push_hunk(out, prefix, n, prefix, m);
    }

    /* Backtrack from (n, m) at d = found_d down to (0, 0) */
    size_t ops_cap = n + m + 4;
    uint8_t *ops = (uint8_t *)malloc(ops_cap);
    size_t ops_len = 0;
    if (!ops) {
        for (int j = 0; j <= found_d; j++) free(trace[j]);
        free(trace);
        return 0;
    }

    int x = (int)n;
    int y = (int)m;
    for (int d = found_d; d > 0; d--) {
        int *prev = trace[d - 1];
        int k = x - y;
        int prev_k;
        if (k == -d || (k != d && prev[(k - 1) + (d - 1)] < prev[(k + 1) + (d - 1)])) {
            prev_k = k + 1;
        } else {
            prev_k = k - 1;
        }
        int prev_x = prev[prev_k + (d - 1)];
        int prev_y = prev_x - prev_k;

        while (x > prev_x && y > prev_y) {
            ops[ops_len++] = EDIT_KEEP;
            x--;
            y--;
        }
        if (x == prev_x) {
            ops[ops_len++] = EDIT_INS;
            y--;
        } else {
            ops[ops_len++] = EDIT_DEL;
            x--;
        }
    }
    while (x > 0 && y > 0) {
        ops[ops_len++] = EDIT_KEEP;
        x--;
        y--;
    }

    for (int j = 0; j <= found_d; j++) free(trace[j]);
    free(trace);

    /* Walk forward (reverse of ops) and coalesce contiguous edits into hunks */
    size_t oi = prefix;
    size_t ni = prefix;
    size_t h_old_start = 0, h_old_cnt = 0;
    size_t h_new_start = 0, h_new_cnt = 0;
    int in_hunk = 0;

    for (size_t i = ops_len; i > 0; i--) {
        uint8_t op = ops[i - 1];
        if (op == EDIT_KEEP) {
            if (in_hunk) {
                if (!push_hunk(out, h_old_start, h_old_cnt, h_new_start, h_new_cnt)) {
                    free(ops);
                    return 0;
                }
                in_hunk = 0;
                h_old_cnt = 0;
                h_new_cnt = 0;
            }
            oi++;
            ni++;
        } else {
            if (!in_hunk) {
                in_hunk = 1;
                h_old_start = oi;
                h_new_start = ni;
                h_old_cnt = 0;
                h_new_cnt = 0;
            }
            if (op == EDIT_DEL) {
                h_old_cnt++;
                oi++;
            } else {
                h_new_cnt++;
                ni++;
            }
        }
    }
    if (in_hunk) {
        if (!push_hunk(out, h_old_start, h_old_cnt, h_new_start, h_new_cnt)) {
            free(ops);
            return 0;
        }
    }

    free(ops);
    return 1;
}

static size_t
split_text_lines(const char *text, size_t len, npl_diff_line_t **out_lines)
{
    *out_lines = NULL;
    if (!text || len == 0) return 0;

    size_t cap = 32;
    size_t count = 0;
    npl_diff_line_t *arr = (npl_diff_line_t *)malloc(cap * sizeof(npl_diff_line_t));
    if (!arr) return 0;

    size_t pos = 0;
    while (pos <= len) {
        const char *nl = (pos < len) ? (const char *)memchr(text + pos, '\n', len - pos) : NULL;
        size_t end = nl ? (size_t)(nl - text) : len;
        size_t llen = end - pos;
        if (llen > 0 && text[pos + llen - 1] == '\r') llen--;

        if (count >= cap) {
            cap *= 2;
            npl_diff_line_t *na = (npl_diff_line_t *)realloc(arr, cap * sizeof(npl_diff_line_t));
            if (!na) {
                free(arr);
                return 0;
            }
            arr = na;
        }
        arr[count].ptr = text + pos;
        arr[count].len = llen;
        arr[count].hash = npl_diff_hash_line(text + pos, llen);
        count++;

        if (!nl) break;
        pos = end + 1;
        if (pos == len) break; /* Trailing newline ends last line */
    }

    *out_lines = arr;
    return count;
}

int
npl_diff_myers_text(const char *old_text, size_t old_len,
                    const char *new_text, size_t new_len,
                    npl_diff_result_t *out)
{
    npl_diff_line_t *old_l = NULL;
    npl_diff_line_t *new_l = NULL;
    size_t old_n = split_text_lines(old_text, old_len, &old_l);
    size_t new_n = split_text_lines(new_text, new_len, &new_l);
    int ok = npl_diff_myers(old_l, old_n, new_l, new_n, out);
    free(old_l);
    free(new_l);
    return ok;
}

void
npl_diff_result_free(npl_diff_result_t *res)
{
    if (!res) return;
    free(res->hunks);
    res->hunks = NULL;
    res->count = 0;
    res->cap = 0;
}

const char *
npl_diff_kind_name(npl_diff_kind_t kind)
{
    switch (kind) {
        case NPL_DIFF_ADD:    return "add";
        case NPL_DIFF_DEL:    return "del";
        case NPL_DIFF_CHANGE: return "change";
        default:              return "unknown";
    }
}
