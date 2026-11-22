/*
 * c/pty_term.c - POSIX openpty/forkpty non-blocking subprocess + C11 VT100/
 *                256-color/24-bit RGB terminal cell screen & scrollback ring
 *
 * No-op POSIX PTY fallback on _WIN32 (compiles with -Wall -Wextra -Werror).
 */
#if !defined(_WIN32) && !defined(__APPLE__)
#  if !defined(_GNU_SOURCE)
#    define _GNU_SOURCE
#  endif
#endif

#include "pty_term.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
/* No-op POSIX PTY fallback definitions on Win32 */
#else
#  include <fcntl.h>
#  include <poll.h>
#  include <signal.h>
#  include <sys/ioctl.h>
#  include <sys/wait.h>
#  include <unistd.h>
#  if defined(__APPLE__)
#    include <util.h>
#  elif defined(__linux__)
#    include <pty.h>
#  else
#    include <libutil.h>
#  endif
#endif

#define NPL_TERM_SCROLLBACK_MAX 1000
#define NPL_TERM_CSI_MAX_PARAMS 16

typedef enum vt_state {
    VT_GROUND = 0,
    VT_ESC    = 1,
    VT_CSI    = 2,
    VT_OSC    = 3
} vt_state_t;

struct npl_term {
    int rows;
    int cols;
    int cur_row;
    int cur_col;
    int saved_row;
    int saved_col;
    int scroll_top;
    int scroll_bottom;
    int cursor_visible;

    int32_t cur_fg;
    int32_t cur_bg;
    uint8_t cur_flags;

    npl_term_cell_t *cells;

    char  *scrollback[NPL_TERM_SCROLLBACK_MAX];
    size_t sb_head;
    size_t sb_count;

    char title[256];

    vt_state_t vt;
    int        csi_priv;
    int        csi_params[NPL_TERM_CSI_MAX_PARAMS];
    int        csi_nparam;
    int        csi_has_digit;
    char       osc_buf[256];
    size_t     osc_len;
    int        osc_esc;

    /* UTF-8 decoder */
    uint32_t utf8_cp;
    int      utf8_rem;

    int master_fd;
    int child_pid;
    int alive;
    int exited;
    int exit_code;
};

static const int32_t ANSI16_PALETTE[16] = {
    0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68,
    0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
    0x414868, 0xf7768e, 0x9ece6a, 0xe0af68,
    0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5
};

static int32_t
color256_to_rgb(int idx)
{
    if (idx < 0) return -1;
    if (idx < 16) return ANSI16_PALETTE[idx];
    if (idx < 232) {
        int n = idx - 16;
        int r = n / 36;
        int g = (n / 6) % 6;
        int b = n % 6;
        int rv = r ? (r * 40 + 55) : 0;
        int gv = g ? (g * 40 + 55) : 0;
        int bv = b ? (b * 40 + 55) : 0;
        return (rv << 16) | (gv << 8) | bv;
    }
    if (idx < 256) {
        int v = (idx - 232) * 10 + 8;
        return (v << 16) | (v << 8) | v;
    }
    return -1;
}

static inline npl_term_cell_t
blank_cell(const npl_term_t *t)
{
    npl_term_cell_t c;
    c.cp = ' ';
    c.fg = t ? t->cur_fg : -1;
    c.bg = t ? t->cur_bg : -1;
    c.flags = 0;
    return c;
}

static void
clear_cells(npl_term_t *t, int r0, int c0, int r1, int c1)
{
    npl_term_cell_t blank = blank_cell(t);
    for (int r = r0; r <= r1; r++) {
        if (r < 0 || r >= t->rows) continue;
        int sc = (r == r0) ? c0 : 0;
        int ec = (r == r1) ? c1 : (t->cols - 1);
        if (sc < 0) sc = 0;
        if (ec >= t->cols) ec = t->cols - 1;
        for (int c = sc; c <= ec; c++) {
            t->cells[(size_t)r * (size_t)t->cols + (size_t)c] = blank;
        }
    }
}

static char *
row_to_trimmed_string(const npl_term_t *t, int row)
{
    if (row < 0 || row >= t->rows) return NULL;
    const npl_term_cell_t *rc = &t->cells[(size_t)row * (size_t)t->cols];
    int last = t->cols;
    while (last > 0 && rc[last - 1].cp == ' ') last--;
    char *buf = (char *)malloc((size_t)last * 4 + 1);
    if (!buf) return NULL;
    size_t pos = 0;
    for (int c = 0; c < last; c++) {
        uint32_t cp = rc[c].cp;
        if (cp < 0x80u) {
            buf[pos++] = (char)(cp ? cp : ' ');
        } else if (cp < 0x800u) {
            buf[pos++] = (char)(0xC0u | (cp >> 6));
            buf[pos++] = (char)(0x80u | (cp & 0x3Fu));
        } else if (cp < 0x10000u) {
            buf[pos++] = (char)(0xE0u | (cp >> 12));
            buf[pos++] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
            buf[pos++] = (char)(0x80u | (cp & 0x3Fu));
        } else {
            buf[pos++] = (char)(0xF0u | (cp >> 18));
            buf[pos++] = (char)(0x80u | ((cp >> 12) & 0x3Fu));
            buf[pos++] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
            buf[pos++] = (char)(0x80u | (cp & 0x3Fu));
        }
    }
    buf[pos] = '\0';
    return buf;
}

static void
push_scrollback_row(npl_term_t *t, int row)
{
    char *s = row_to_trimmed_string(t, row);
    if (!s) return;
    if (t->sb_count < NPL_TERM_SCROLLBACK_MAX) {
        size_t idx = (t->sb_head + t->sb_count) % NPL_TERM_SCROLLBACK_MAX;
        t->scrollback[idx] = s;
        t->sb_count++;
    } else {
        free(t->scrollback[t->sb_head]);
        t->scrollback[t->sb_head] = s;
        t->sb_head = (t->sb_head + 1) % NPL_TERM_SCROLLBACK_MAX;
    }
}

static void
scroll_up(npl_term_t *t, int top, int bottom, int n)
{
    if (top < 0) top = 0;
    if (bottom >= t->rows) bottom = t->rows - 1;
    if (top > bottom || n <= 0) return;
    int height = bottom - top + 1;
    if (n > height) n = height;

    if (top == 0) {
        for (int i = 0; i < n; i++) push_scrollback_row(t, i);
    }
    if (n < height) {
        memmove(&t->cells[(size_t)top * (size_t)t->cols],
                &t->cells[(size_t)(top + n) * (size_t)t->cols],
                (size_t)(height - n) * (size_t)t->cols * sizeof(npl_term_cell_t));
    }
    clear_cells(t, bottom - n + 1, 0, bottom, t->cols - 1);
}

static void
scroll_down(npl_term_t *t, int top, int bottom, int n)
{
    if (top < 0) top = 0;
    if (bottom >= t->rows) bottom = t->rows - 1;
    if (top > bottom || n <= 0) return;
    int height = bottom - top + 1;
    if (n > height) n = height;

    if (n < height) {
        memmove(&t->cells[(size_t)(top + n) * (size_t)t->cols],
                &t->cells[(size_t)top * (size_t)t->cols],
                (size_t)(height - n) * (size_t)t->cols * sizeof(npl_term_cell_t));
    }
    clear_cells(t, top, 0, top + n - 1, t->cols - 1);
}

static void
put_codepoint(npl_term_t *t, uint32_t cp)
{
    if (t->cur_col >= t->cols) {
        t->cur_col = 0;
        if (t->cur_row >= t->scroll_bottom) {
            scroll_up(t, t->scroll_top, t->scroll_bottom, 1);
        } else if (t->cur_row + 1 < t->rows) {
            t->cur_row++;
        }
    }
    if (t->cur_row >= 0 && t->cur_row < t->rows && t->cur_col >= 0 && t->cur_col < t->cols) {
        npl_term_cell_t *cell = &t->cells[(size_t)t->cur_row * (size_t)t->cols + (size_t)t->cur_col];
        cell->cp = cp;
        cell->fg = t->cur_fg;
        cell->bg = t->cur_bg;
        cell->flags = t->cur_flags;
    }
    t->cur_col++;
}

static void
handle_sgr(npl_term_t *t)
{
    int count = t->csi_nparam;
    if (count == 0) {
        t->cur_fg = -1;
        t->cur_bg = -1;
        t->cur_flags = 0;
        return;
    }
    for (int i = 0; i < count; i++) {
        int p = t->csi_params[i];
        if (p == 0) {
            t->cur_fg = -1;
            t->cur_bg = -1;
            t->cur_flags = 0;
        } else if (p == 1) {
            t->cur_flags |= NPL_TERM_FLAG_BOLD;
        } else if (p == 2) {
            t->cur_flags |= NPL_TERM_FLAG_DIM;
        } else if (p == 3) {
            t->cur_flags |= NPL_TERM_FLAG_ITALIC;
        } else if (p == 4) {
            t->cur_flags |= NPL_TERM_FLAG_UNDERLINE;
        } else if (p == 7) {
            t->cur_flags |= NPL_TERM_FLAG_INVERSE;
        } else if (p == 22) {
            t->cur_flags &= (uint8_t)~(NPL_TERM_FLAG_BOLD | NPL_TERM_FLAG_DIM);
        } else if (p == 23) {
            t->cur_flags &= (uint8_t)~NPL_TERM_FLAG_ITALIC;
        } else if (p == 24) {
            t->cur_flags &= (uint8_t)~NPL_TERM_FLAG_UNDERLINE;
        } else if (p == 27) {
            t->cur_flags &= (uint8_t)~NPL_TERM_FLAG_INVERSE;
        } else if (p >= 30 && p <= 37) {
            t->cur_fg = ANSI16_PALETTE[p - 30];
        } else if (p == 39) {
            t->cur_fg = -1;
        } else if (p >= 40 && p <= 47) {
            t->cur_bg = ANSI16_PALETTE[p - 40];
        } else if (p == 49) {
            t->cur_bg = -1;
        } else if (p >= 90 && p <= 97) {
            t->cur_fg = ANSI16_PALETTE[8 + (p - 90)];
        } else if (p >= 100 && p <= 107) {
            t->cur_bg = ANSI16_PALETTE[8 + (p - 100)];
        } else if ((p == 38 || p == 48) && i + 1 < count) {
            int mode = t->csi_params[i + 1];
            if (mode == 5 && i + 2 < count) {
                int32_t rgb = color256_to_rgb(t->csi_params[i + 2]);
                if (p == 38) t->cur_fg = rgb; else t->cur_bg = rgb;
                i += 2;
            } else if (mode == 2 && i + 4 < count) {
                int r = t->csi_params[i + 2] & 0xFF;
                int g = t->csi_params[i + 3] & 0xFF;
                int b = t->csi_params[i + 4] & 0xFF;
                int32_t rgb = (r << 16) | (g << 8) | b;
                if (p == 38) t->cur_fg = rgb; else t->cur_bg = rgb;
                i += 4;
            }
        }
    }
}

static int
csi_param(const npl_term_t *t, int idx, int def)
{
    if (idx < t->csi_nparam && t->csi_params[idx] > 0) return t->csi_params[idx];
    return def;
}

static void
handle_csi(npl_term_t *t, unsigned char cmd)
{
    if (t->csi_priv == '?') {
        int p0 = (t->csi_nparam > 0) ? t->csi_params[0] : 0;
        if (p0 == 25) {
            if (cmd == 'h') t->cursor_visible = 1;
            else if (cmd == 'l') t->cursor_visible = 0;
        }
        return;
    }

    switch (cmd) {
        case 'A': {
            int n = csi_param(t, 0, 1);
            t->cur_row -= n;
            if (t->cur_row < 0) t->cur_row = 0;
            break;
        }
        case 'B': {
            int n = csi_param(t, 0, 1);
            t->cur_row += n;
            if (t->cur_row >= t->rows) t->cur_row = t->rows - 1;
            break;
        }
        case 'C': {
            int n = csi_param(t, 0, 1);
            t->cur_col += n;
            if (t->cur_col >= t->cols) t->cur_col = t->cols - 1;
            break;
        }
        case 'D': {
            int n = csi_param(t, 0, 1);
            t->cur_col -= n;
            if (t->cur_col < 0) t->cur_col = 0;
            break;
        }
        case 'G': {
            int col = csi_param(t, 0, 1) - 1;
            if (col < 0) col = 0;
            if (col >= t->cols) col = t->cols - 1;
            t->cur_col = col;
            break;
        }
        case 'H':
        case 'f': {
            int row = csi_param(t, 0, 1) - 1;
            int col = csi_param(t, 1, 1) - 1;
            if (row < 0) row = 0;
            if (row >= t->rows) row = t->rows - 1;
            if (col < 0) col = 0;
            if (col >= t->cols) col = t->cols - 1;
            t->cur_row = row;
            t->cur_col = col;
            break;
        }
        case 'J': {
            int mode = (t->csi_nparam > 0) ? t->csi_params[0] : 0;
            if (mode == 0) {
                clear_cells(t, t->cur_row, t->cur_col, t->rows - 1, t->cols - 1);
            } else if (mode == 1) {
                clear_cells(t, 0, 0, t->cur_row, t->cur_col);
            } else if (mode == 2 || mode == 3) {
                clear_cells(t, 0, 0, t->rows - 1, t->cols - 1);
            }
            break;
        }
        case 'K': {
            int mode = (t->csi_nparam > 0) ? t->csi_params[0] : 0;
            if (mode == 0) {
                clear_cells(t, t->cur_row, t->cur_col, t->cur_row, t->cols - 1);
            } else if (mode == 1) {
                clear_cells(t, t->cur_row, 0, t->cur_row, t->cur_col);
            } else if (mode == 2) {
                clear_cells(t, t->cur_row, 0, t->cur_row, t->cols - 1);
            }
            break;
        }
        case 'S':
            scroll_up(t, t->scroll_top, t->scroll_bottom, csi_param(t, 0, 1));
            break;
        case 'T':
            scroll_down(t, t->scroll_top, t->scroll_bottom, csi_param(t, 0, 1));
            break;
        case 'r': {
            int top = csi_param(t, 0, 1) - 1;
            int bot = csi_param(t, 1, t->rows) - 1;
            if (top < 0) top = 0;
            if (bot >= t->rows) bot = t->rows - 1;
            if (top < bot) {
                t->scroll_top = top;
                t->scroll_bottom = bot;
            }
            t->cur_row = 0;
            t->cur_col = 0;
            break;
        }
        case 's':
            t->saved_row = t->cur_row;
            t->saved_col = t->cur_col;
            break;
        case 'u':
            t->cur_row = t->saved_row;
            t->cur_col = t->saved_col;
            break;
        case 'm':
            handle_sgr(t);
            break;
        default:
            break;
    }
}

void
npl_term_feed(npl_term_t *t, const char *data, size_t len)
{
    if (!t || !data || len == 0) return;

    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)data[i];

        if (t->vt == VT_OSC) {
            if (c == 0x07u || (t->osc_esc && c == '\\')) {
                if (t->osc_esc && t->osc_len > 0) t->osc_len--;
                t->osc_buf[t->osc_len] = '\0';
                /* Extract title from "0;title" or "2;title" */
                const char *semi = strchr(t->osc_buf, ';');
                if (semi && semi[1] != '\0') {
                    size_t tl = strlen(semi + 1);
                    if (tl >= sizeof(t->title)) tl = sizeof(t->title) - 1;
                    memcpy(t->title, semi + 1, tl);
                    t->title[tl] = '\0';
                }
                t->vt = VT_GROUND;
                t->osc_len = 0;
                t->osc_esc = 0;
            } else {
                t->osc_esc = (c == 0x1Bu);
                if (t->osc_len + 1 < sizeof(t->osc_buf)) {
                    t->osc_buf[t->osc_len++] = (char)c;
                }
            }
            continue;
        }

        if (t->vt == VT_ESC) {
            if (c == '[') {
                t->vt = VT_CSI;
                t->csi_priv = 0;
                t->csi_nparam = 0;
                t->csi_has_digit = 0;
                memset(t->csi_params, 0, sizeof(t->csi_params));
            } else if (c == ']') {
                t->vt = VT_OSC;
                t->osc_len = 0;
                t->osc_esc = 0;
            } else if (c == '7') {
                t->saved_row = t->cur_row;
                t->saved_col = t->cur_col;
                t->vt = VT_GROUND;
            } else if (c == '8') {
                t->cur_row = t->saved_row;
                t->cur_col = t->saved_col;
                t->vt = VT_GROUND;
            } else {
                t->vt = VT_GROUND;
            }
            continue;
        }

        if (t->vt == VT_CSI) {
            if (c >= '0' && c <= '9') {
                if (!t->csi_has_digit && t->csi_nparam < NPL_TERM_CSI_MAX_PARAMS) {
                    t->csi_params[t->csi_nparam] = 0;
                    t->csi_has_digit = 1;
                }
                if (t->csi_nparam < NPL_TERM_CSI_MAX_PARAMS) {
                    t->csi_params[t->csi_nparam] = t->csi_params[t->csi_nparam] * 10 + (int)(c - '0');
                }
            } else if (c == ';') {
                if (t->csi_nparam < NPL_TERM_CSI_MAX_PARAMS) {
                    if (!t->csi_has_digit) t->csi_params[t->csi_nparam] = 0;
                    t->csi_nparam++;
                    t->csi_has_digit = 0;
                }
            } else if (c == '?' || c == '>' || c == '!') {
                t->csi_priv = (int)c;
            } else if (c >= 0x40u && c <= 0x7Eu) {
                if (t->csi_has_digit && t->csi_nparam < NPL_TERM_CSI_MAX_PARAMS) {
                    t->csi_nparam++;
                }
                handle_csi(t, c);
                t->vt = VT_GROUND;
            }
            continue;
        }

        /* VT_GROUND */
        if (c == 0x1Bu) {
            t->vt = VT_ESC;
            t->utf8_rem = 0;
            continue;
        }
        if (c == '\r') {
            t->cur_col = 0;
            continue;
        }
        if (c == '\n') {
            if (t->cur_row >= t->scroll_bottom) {
                scroll_up(t, t->scroll_top, t->scroll_bottom, 1);
            } else if (t->cur_row + 1 < t->rows) {
                t->cur_row++;
            }
            continue;
        }
        if (c == '\b') {
            if (t->cur_col > 0) t->cur_col--;
            continue;
        }
        if (c == '\t') {
            int next_tab = (t->cur_col + 8) & ~7;
            if (next_tab >= t->cols) next_tab = t->cols - 1;
            t->cur_col = next_tab;
            continue;
        }
        if (c == '\a' || c < 0x20u) {
            continue;
        }

        /* UTF-8 decoding */
        if (c < 0x80u) {
            t->utf8_rem = 0;
            put_codepoint(t, (uint32_t)c);
        } else if ((c & 0xE0u) == 0xC0u) {
            t->utf8_cp = (uint32_t)(c & 0x1Fu);
            t->utf8_rem = 1;
        } else if ((c & 0xF0u) == 0xE0u) {
            t->utf8_cp = (uint32_t)(c & 0x0Fu);
            t->utf8_rem = 2;
        } else if ((c & 0xF8u) == 0xF0u) {
            t->utf8_cp = (uint32_t)(c & 0x07u);
            t->utf8_rem = 3;
        } else if ((c & 0xC0u) == 0x80u && t->utf8_rem > 0) {
            t->utf8_cp = (t->utf8_cp << 6) | (uint32_t)(c & 0x3Fu);
            t->utf8_rem--;
            if (t->utf8_rem == 0) {
                put_codepoint(t, t->utf8_cp);
            }
        }
    }
}

static npl_term_t *
alloc_term(int rows, int cols)
{
    if (rows < 1) rows = 24;
    if (cols < 1) cols = 80;
    if (rows > 512) rows = 512;
    if (cols > 512) cols = 512;

    npl_term_t *t = (npl_term_t *)calloc(1, sizeof(npl_term_t));
    if (!t) return NULL;
    t->cells = (npl_term_cell_t *)malloc((size_t)rows * (size_t)cols * sizeof(npl_term_cell_t));
    if (!t->cells) {
        free(t);
        return NULL;
    }
    t->rows = rows;
    t->cols = cols;
    t->scroll_top = 0;
    t->scroll_bottom = rows - 1;
    t->cursor_visible = 1;
    t->cur_fg = -1;
    t->cur_bg = -1;
    t->master_fd = -1;
    t->child_pid = -1;
    clear_cells(t, 0, 0, rows - 1, cols - 1);
    return t;
}

npl_term_t *
npl_term_spawn(int rows, int cols, const char *cmd,
               const char *const *args, const char *cwd,
               char *errbuf, size_t errsz)
{
#if defined(_WIN32)
    (void)args;
    (void)cwd;
    (void)cmd;
    if (errbuf && errsz) {
        (void)snprintf(errbuf, errsz, "POSIX PTY is unavailable on Windows");
    }
    npl_term_t *t = alloc_term(rows, cols);
    if (t) {
        t->alive = 0;
        t->exited = 1;
        t->exit_code = -1;
    }
    return t;
#else
    npl_term_t *t = alloc_term(rows, cols);
    if (!t) {
        if (errbuf && errsz) (void)snprintf(errbuf, errsz, "Out of memory");
        return NULL;
    }

    const char *prog = (cmd && cmd[0]) ? cmd : "/bin/sh";
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)t->rows;
    ws.ws_col = (unsigned short)t->cols;

    int master_fd = -1;
    pid_t pid = forkpty(&master_fd, NULL, NULL, &ws);
    if (pid < 0) {
        if (errbuf && errsz) {
            (void)snprintf(errbuf, errsz, "forkpty failed: %s", strerror(errno));
        }
        npl_term_free(t);
        return NULL;
    }

    if (pid == 0) {
        /* Child process */
        (void)setenv("TERM", "xterm-256color", 1);
        (void)setenv("COLORTERM", "truecolor", 1);
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0) _exit(126);
        }

        size_t argc = 0;
        if (args) {
            while (args[argc] != NULL) argc++;
        }
        char **argv = (char **)calloc(argc + 2, sizeof(char *));
        if (!argv) _exit(127);
        argv[0] = (char *)(uintptr_t)prog;
        for (size_t i = 0; i < argc; i++) {
            argv[i + 1] = (char *)(uintptr_t)args[i];
        }
        argv[argc + 1] = NULL;
        execvp(prog, argv);
        _exit(127);
    }

    /* Parent */
    int fl = fcntl(master_fd, F_GETFL, 0);
    if (fl >= 0) (void)fcntl(master_fd, F_SETFL, fl | O_NONBLOCK);
    int fdfl = fcntl(master_fd, F_GETFD, 0);
    if (fdfl >= 0) (void)fcntl(master_fd, F_SETFD, fdfl | FD_CLOEXEC);

    t->master_fd = master_fd;
    t->child_pid = (int)pid;
    t->alive = 1;
    t->exited = 0;
    t->exit_code = 0;
    return t;
#endif
}

static void
check_child_status(npl_term_t *t)
{
#if defined(_WIN32)
    (void)t;
#else
    if (!t || !t->alive || t->child_pid <= 0) return;
    int status = 0;
    pid_t r = waitpid((pid_t)t->child_pid, &status, WNOHANG);
    if (r == (pid_t)t->child_pid) {
        t->alive = 0;
        t->exited = 1;
        if (WIFEXITED(status)) {
            t->exit_code = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            t->exit_code = 128 + WTERMSIG(status);
        } else {
            t->exit_code = -1;
        }
    }
#endif
}

void
npl_term_free(npl_term_t *t)
{
    if (!t) return;
#if !defined(_WIN32)
    if (t->alive && t->child_pid > 0) {
        (void)kill((pid_t)t->child_pid, SIGHUP);
        (void)kill((pid_t)t->child_pid, SIGKILL);
        int st = 0;
        (void)waitpid((pid_t)t->child_pid, &st, 0);
        t->alive = 0;
    }
    if (t->master_fd >= 0) {
        close(t->master_fd);
        t->master_fd = -1;
    }
#endif
    for (size_t i = 0; i < t->sb_count; i++) {
        size_t idx = (t->sb_head + i) % NPL_TERM_SCROLLBACK_MAX;
        free(t->scrollback[idx]);
    }
    free(t->cells);
    free(t);
}

int
npl_term_write(npl_term_t *t, const char *data, size_t len)
{
#if defined(_WIN32)
    (void)t; (void)data; (void)len;
    return -1;
#else
    if (!t || t->master_fd < 0 || !data) return -1;
    if (len == 0) return 0;
    ssize_t n = write(t->master_fd, data, len);
    return (n < 0) ? -1 : (int)n;
#endif
}

int
npl_term_poll(npl_term_t *t, int timeout_ms)
{
#if defined(_WIN32)
    (void)t; (void)timeout_ms;
    return 0;
#else
    if (!t || t->master_fd < 0) return 0;
    struct pollfd pfd;
    pfd.fd = t->master_fd;
    pfd.events = POLLIN;
    pfd.revents = 0;

    int rc = poll(&pfd, 1, timeout_ms);
    int total = 0;
    if (rc > 0 && (pfd.revents & (POLLIN | POLLHUP))) {
        char buf[8192];
        for (int iter = 0; iter < 32; iter++) {
            ssize_t n = read(t->master_fd, buf, sizeof(buf));
            if (n > 0) {
                npl_term_feed(t, buf, (size_t)n);
                total += (int)n;
            } else {
                break;
            }
        }
    }
    check_child_status(t);
    return total;
#endif
}

int
npl_term_resize(npl_term_t *t, int rows, int cols)
{
    if (!t) return 0;
    if (rows < 1) rows = 1;
    if (cols < 1) cols = 1;
    if (rows > 512) rows = 512;
    if (cols > 512) cols = 512;

    npl_term_cell_t *nc = (npl_term_cell_t *)malloc(
        (size_t)rows * (size_t)cols * sizeof(npl_term_cell_t));
    if (!nc) return 0;

    npl_term_cell_t blank = blank_cell(t);
    for (int i = 0; i < rows * cols; i++) nc[i] = blank;

    int copy_r = (rows < t->rows) ? rows : t->rows;
    int copy_c = (cols < t->cols) ? cols : t->cols;
    for (int r = 0; r < copy_r; r++) {
        memcpy(&nc[(size_t)r * (size_t)cols],
               &t->cells[(size_t)r * (size_t)t->cols],
               (size_t)copy_c * sizeof(npl_term_cell_t));
    }

    free(t->cells);
    t->cells = nc;
    t->rows = rows;
    t->cols = cols;
    t->scroll_top = 0;
    t->scroll_bottom = rows - 1;
    if (t->cur_row >= rows) t->cur_row = rows - 1;
    if (t->cur_col >= cols) t->cur_col = cols - 1;

#if !defined(_WIN32)
    if (t->master_fd >= 0) {
        struct winsize ws;
        memset(&ws, 0, sizeof(ws));
        ws.ws_row = (unsigned short)rows;
        ws.ws_col = (unsigned short)cols;
        (void)ioctl(t->master_fd, TIOCSWINSZ, &ws);
    }
#endif
    return 1;
}

int
npl_term_is_alive(npl_term_t *t)
{
    if (!t) return 0;
    check_child_status(t);
    return t->alive;
}

int
npl_term_exit_code(const npl_term_t *t, int *out_exited)
{
    if (!t) {
        if (out_exited) *out_exited = 0;
        return 0;
    }
    if (out_exited) *out_exited = t->exited;
    return t->exit_code;
}

int
npl_term_pid(const npl_term_t *t)
{
    return t ? t->child_pid : -1;
}

int
npl_term_kill(npl_term_t *t, int sig)
{
#if defined(_WIN32)
    (void)t; (void)sig;
    return 0;
#else
    if (!t || !t->alive || t->child_pid <= 0) return 0;
    if (sig <= 0) sig = SIGTERM;
    int rc = (kill((pid_t)t->child_pid, sig) == 0) ? 1 : 0;
    check_child_status(t);
    return rc;
#endif
}

int npl_term_rows(const npl_term_t *t) { return t ? t->rows : 0; }
int npl_term_cols(const npl_term_t *t) { return t ? t->cols : 0; }
int npl_term_cursor_row(const npl_term_t *t) { return t ? t->cur_row : 0; }
int npl_term_cursor_col(const npl_term_t *t) { return t ? t->cur_col : 0; }
int npl_term_cursor_visible(const npl_term_t *t) { return t ? t->cursor_visible : 0; }
const char *npl_term_title(const npl_term_t *t) { return t ? t->title : ""; }

const npl_term_cell_t *
npl_term_row_cells(const npl_term_t *t, int row)
{
    if (!t || row < 0 || row >= t->rows) return NULL;
    return &t->cells[(size_t)row * (size_t)t->cols];
}

size_t
npl_term_scrollback_count(const npl_term_t *t)
{
    return t ? t->sb_count : 0;
}

const char *
npl_term_scrollback_line(const npl_term_t *t, size_t idx)
{
    if (!t || idx >= t->sb_count) return NULL;
    return t->scrollback[(t->sb_head + idx) % NPL_TERM_SCROLLBACK_MAX];
}
