/*
 * c/vim_engine.h - Pure-C11 reentrant PERL_XS_THREADSAFE Vim 9.1 modal engine
 *                  operating directly on npl_buf_t piece-table & undo tree
 */
#ifndef NPL_VIM_ENGINE_H
#define NPL_VIM_ENGINE_H

#include "buffer.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum npl_vim_mode {
    NPL_VIM_NORMAL   = 0,
    NPL_VIM_INSERT   = 1,
    NPL_VIM_REPLACE  = 2,
    NPL_VIM_VISUAL   = 3,
    NPL_VIM_VLINE    = 4,
    NPL_VIM_VBLOCK   = 5,
    NPL_VIM_OPERATOR = 6
} npl_vim_mode_t;

typedef enum npl_reg_type {
    NPL_REG_CHAR  = 0,
    NPL_REG_LINE  = 1,
    NPL_REG_BLOCK = 2
} npl_reg_type_t;

typedef struct npl_vim_visual_range {
    int            active;
    npl_vim_mode_t mode;
    size_t         start_line;
    size_t         start_col;
    size_t         end_line;
    size_t         end_col;
} npl_vim_visual_range_t;

typedef struct npl_vim_state_info {
    npl_vim_mode_t         mode;
    size_t                 line;
    size_t                 col;
    size_t                 curswant;
    int                    count1;
    int                    count2;
    char                   op[4];
    char                   reg;
    int                    expect_reg;
    char                   pending_prefix;
    char                   recording_reg; /* '\0' if not recording */
    int                    shiftwidth;
    int                    tabstop;
    int                    expandtab;
    int                    win_height;
    size_t                 scroll_top;
    uint64_t               undo_seq;
    int                    can_undo;
    int                    can_redo;
    npl_vim_visual_range_t visual;
    npl_vim_visual_range_t last_visual;
} npl_vim_state_info_t;

typedef struct npl_vim npl_vim_t;

/* Lifecycle (no mutable global state; reentrant) */
npl_vim_t *npl_vim_new(npl_buf_t *buf);
void       npl_vim_free(npl_vim_t *v);
void       npl_vim_reset(npl_vim_t *v);
void       npl_vim_set_buffer(npl_vim_t *v, npl_buf_t *buf);

/* Options */
void npl_vim_set_options(npl_vim_t *v, int shiftwidth, int tabstop,
                         int expandtab, int win_height, size_t scroll_top);

/* Key feed (supports both raw control bytes and Vim <Esc>/<CR>/<C-v>/<BS>/... tokens) */
size_t npl_vim_feed_keys(npl_vim_t *v, const char *keys, size_t len);

/* Mode & cursor */
npl_vim_mode_t npl_vim_mode(const npl_vim_t *v);
const char    *npl_vim_mode_name(npl_vim_mode_t mode);
void           npl_vim_cursor(const npl_vim_t *v, size_t *out_line, size_t *out_col);
void           npl_vim_set_cursor(npl_vim_t *v, size_t line, size_t col);

/* Registers */
const char *npl_vim_get_register(const npl_vim_t *v, char name,
                                 size_t *out_len, npl_reg_type_t *out_type);
int         npl_vim_set_register(npl_vim_t *v, char name,
                                 const char *text, size_t len, npl_reg_type_t type);
const char *npl_reg_type_name(npl_reg_type_t t);

/* Marks */
int npl_vim_set_mark(npl_vim_t *v, char name, size_t line, size_t col);
int npl_vim_get_mark(const npl_vim_t *v, char name, size_t *out_line, size_t *out_col);

/* Visual range & full state snapshot */
int  npl_vim_visual_range(const npl_vim_t *v, npl_vim_visual_range_t *out);
void npl_vim_state_info(const npl_vim_t *v, npl_vim_state_info_t *out);

#ifdef __cplusplus
}
#endif

#endif /* NPL_VIM_ENGINE_H */
