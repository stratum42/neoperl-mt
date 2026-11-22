/*
 * c/pty_term.h - POSIX PTY subprocess + C11 VT100/256-color/24-bit RGB screen
 */
#ifndef NPL_PTY_TERM_H
#define NPL_PTY_TERM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NPL_TERM_FLAG_BOLD      0x01u
#define NPL_TERM_FLAG_DIM       0x02u
#define NPL_TERM_FLAG_ITALIC    0x04u
#define NPL_TERM_FLAG_UNDERLINE 0x08u
#define NPL_TERM_FLAG_INVERSE   0x10u

typedef struct npl_term_cell {
    uint32_t cp;    /* Unicode codepoint (ASCII / UTF-8) */
    int32_t  fg;    /* 0xRRGGBB or -1 for default */
    int32_t  bg;    /* 0xRRGGBB or -1 for default */
    uint8_t  flags; /* NPL_TERM_FLAG_* */
} npl_term_cell_t;

typedef struct npl_term npl_term_t;

npl_term_t *npl_term_spawn(int rows, int cols, const char *cmd,
                           const char *const *args, const char *cwd,
                           char *errbuf, size_t errsz);
void        npl_term_free(npl_term_t *t);

int  npl_term_write(npl_term_t *t, const char *data, size_t len);
int  npl_term_poll(npl_term_t *t, int timeout_ms);
int  npl_term_resize(npl_term_t *t, int rows, int cols);
int  npl_term_is_alive(npl_term_t *t);
int  npl_term_exit_code(const npl_term_t *t, int *out_exited);
int  npl_term_pid(const npl_term_t *t);
int  npl_term_kill(npl_term_t *t, int sig);

/* Screen state accessors */
int         npl_term_rows(const npl_term_t *t);
int         npl_term_cols(const npl_term_t *t);
int         npl_term_cursor_row(const npl_term_t *t);
int         npl_term_cursor_col(const npl_term_t *t);
int         npl_term_cursor_visible(const npl_term_t *t);
const char *npl_term_title(const npl_term_t *t);
const npl_term_cell_t *npl_term_row_cells(const npl_term_t *t, int row);
size_t      npl_term_scrollback_count(const npl_term_t *t);
const char *npl_term_scrollback_line(const npl_term_t *t, size_t idx);

/* Feed raw bytes directly into the VT100 emulator (for testing / replay) */
void npl_term_feed(npl_term_t *t, const char *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* NPL_PTY_TERM_H */
