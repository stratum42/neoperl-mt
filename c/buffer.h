/*
 * c/buffer.h - Zero-copy mmap piece-table buffer with branching undo tree
 *              and byte-anchored extmarks
 */
#ifndef NPL_BUFFER_H
#define NPL_BUFFER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct npl_buf npl_buf_t;

typedef struct npl_undo_info {
    uint64_t seq;
    uint64_t parent_seq;
    int64_t  timestamp;
    size_t   edit_count;
    int      is_current;
    uint64_t *child_seqs;
    size_t    child_count;
} npl_undo_info_t;

typedef struct npl_extmark_spec {
    uint64_t     id; /* 0 = auto-assign */
    size_t       start_byte;
    size_t       end_byte;
    int          has_end;
    int          right_gravity;     /* default 1 */
    int          end_right_gravity; /* default 0 */
    int32_t      priority;          /* default 100 */
    const char  *hl_group;
    const char  *sign_text;
    const char  *sign_hl;
    const char  *virt_text;
    const char  *virt_hl;
    const char  *virt_pos;          /* "eol", "inline", "overlay", "right_align" */
    const char *const *virt_lines;
    size_t       virt_line_count;
    const char *const *virt_lines_hl;
    size_t       virt_line_hl_count;
    int          virt_lines_above;
} npl_extmark_spec_t;

typedef struct npl_extmark_view {
    uint64_t  id;
    char     *ns;
    size_t    start_byte;
    size_t    start_line;
    size_t    start_col;
    size_t    end_byte;
    size_t    end_line;
    size_t    end_col;
    int       has_end;
    int       right_gravity;
    int       end_right_gravity;
    int32_t   priority;
    char     *hl_group;
    char     *sign_text;
    char     *sign_hl;
    char     *virt_text;
    char     *virt_hl;
    char     *virt_pos;
    char    **virt_lines;
    size_t    virt_line_count;
    char    **virt_lines_hl;
    size_t    virt_line_hl_count;
    int       virt_lines_above;
} npl_extmark_view_t;

/* Lifecycle */
npl_buf_t *npl_buf_new(void);
npl_buf_t *npl_buf_open_file(const char *path, char *errbuf, size_t errsz);
npl_buf_t *npl_buf_from_string(const char *data, size_t len);
void       npl_buf_free(npl_buf_t *b);

/* Mutations (0-based byte offsets) */
int npl_buf_insert(npl_buf_t *b, size_t offset, const char *data, size_t len);
int npl_buf_delete(npl_buf_t *b, size_t offset, size_t len);

/* Branching Undo Tree */
void     npl_buf_begin_group(npl_buf_t *b);
void     npl_buf_end_group(npl_buf_t *b);
int      npl_buf_undo(npl_buf_t *b);
int      npl_buf_redo(npl_buf_t *b);
int      npl_buf_undo_older(npl_buf_t *b); /* Vim g- */
int      npl_buf_undo_newer(npl_buf_t *b); /* Vim g+ */
int      npl_buf_undo_goto(npl_buf_t *b, uint64_t seq);
int      npl_buf_can_undo(const npl_buf_t *b);
int      npl_buf_can_redo(const npl_buf_t *b);
uint64_t npl_buf_undo_seq(const npl_buf_t *b);
size_t   npl_buf_undo_list(const npl_buf_t *b, npl_undo_info_t **out_list);
void     npl_buf_undo_list_free(npl_undo_info_t *list, size_t count);

/* Queries (0-based line indices and byte offsets) */
size_t   npl_buf_line_count(npl_buf_t *b);
size_t   npl_buf_byte_length(const npl_buf_t *b);
uint64_t npl_buf_revision(const npl_buf_t *b);
size_t   npl_buf_copy_range(const npl_buf_t *b, size_t offset, size_t len, char *dst);
int      npl_buf_line_bounds(npl_buf_t *b, size_t line, size_t *out_start, size_t *out_len);
char    *npl_buf_get_line_alloc(npl_buf_t *b, size_t line, size_t *out_len);
size_t   npl_buf_get_line_buf(npl_buf_t *b, size_t line, char *buf, size_t buf_cap);
size_t   npl_buf_line_col_to_offset(npl_buf_t *b, size_t line, size_t col);
void     npl_buf_offset_to_line_col(npl_buf_t *b, size_t offset, size_t *out_line, size_t *out_col);

/* Serialization */
int   npl_buf_save_file(const npl_buf_t *b, const char *path, char *errbuf, size_t errsz);
char *npl_buf_to_string(const npl_buf_t *b, size_t *out_len);

/* Byte-anchored extmarks */
uint64_t npl_buf_set_extmark(npl_buf_t *b, const char *ns, const npl_extmark_spec_t *spec);
int      npl_buf_del_extmark(npl_buf_t *b, const char *ns, uint64_t id);
void     npl_buf_clear_namespace(npl_buf_t *b, const char *ns, int64_t start_line, int64_t end_line);
size_t   npl_buf_get_extmarks(npl_buf_t *b, const char *ns,
                              int64_t start_line, int64_t end_line,
                              npl_extmark_view_t **out_views);
void     npl_buf_extmarks_free(npl_extmark_view_t *views, size_t count);
size_t   npl_buf_extmark_count(const npl_buf_t *b, const char *ns);

#ifdef __cplusplus
}
#endif

#endif /* NPL_BUFFER_H */
