/*
 * c/vim_engine.c - Pure-C11 reentrant PERL_XS_THREADSAFE Vim 9.1 modal engine
 *                  No mutable global state; unsigned-char safe for ppc64le
 */
#include "vim_engine.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* --- Key Constants --- */

enum {
    NPL_K_NONE      = 0,
    NPL_K_ESC       = 0x100,
    NPL_K_CR        = 0x101,
    NPL_K_BS        = 0x102,
    NPL_K_TAB       = 0x103,
    NPL_K_DEL       = 0x104,
    NPL_K_LEFT      = 0x105,
    NPL_K_RIGHT     = 0x106,
    NPL_K_UP        = 0x107,
    NPL_K_DOWN      = 0x108,
    NPL_K_HOME      = 0x109,
    NPL_K_END       = 0x10A,
    NPL_K_CTRL_BASE = 0x200
};

#define NPL_K_CTRL(ch) ((uint32_t)(NPL_K_CTRL_BASE + ((int)(ch) - 'a')))
#define NPL_K_CTRL_LBRACKET ((uint32_t)(NPL_K_CTRL_BASE + 26))
#define NPL_K_CTRL_BSLASH   ((uint32_t)(NPL_K_CTRL_BASE + 27))
#define NPL_K_CTRL_RBRACKET ((uint32_t)(NPL_K_CTRL_BASE + 28))

#define NPL_CURSWANT_MAX ((size_t)-1)
#define NPL_MAX_MACRO_DEPTH 64

/* --- Internal Data Structures --- */

typedef struct {
    char          *text;
    size_t         len;
    size_t         cap;
    npl_reg_type_t type;
} npl_vim_reg_t;

typedef struct {
    int    set;
    size_t line;
    size_t col;
} npl_vim_mark_t;

typedef struct {
    uint64_t seq;
    size_t   edit_line;
    size_t   edit_col;
    int      linewise;
} npl_undo_cur_t;

typedef struct {
    int  had_orig;
    char orig_ch;
} npl_rep_entry_t;

typedef struct {
    int    active;
    int    is_append;   /* 1 for VBLOCK A */
    int    is_change;   /* 1 for VBLOCK c */
    int    dollar;      /* 1 when $ was pressed in VBLOCK */
    size_t start_line;
    size_t end_line;
    size_t start_col;
    size_t end_col;
    char  *text;
    size_t text_len;
    size_t text_cap;
} npl_vblock_ins_t;

typedef struct {
    size_t start_line;
    size_t start_col;
    size_t end_line;
    size_t end_col;
    int    linewise;
    int    exclusive;
    int    empty;
    int    blockwise;
} npl_range_t;

struct npl_vim {
    npl_buf_t     *buf;
    npl_vim_mode_t mode;
    size_t         line;
    size_t         col;
    size_t         curswant;

    /* Options */
    int    shiftwidth;
    int    tabstop;
    int    expandtab;
    int    win_height;
    size_t scroll_top;

    /* Grammar parser */
    int  count1;
    int  has_count1;
    int  count2;
    int  has_count2;
    char op[4];          /* "", "d", "c", "y", ">", "<", "gu", "gU", "g~" */
    char reg;            /* '\0' = default */
    int  expect_reg;
    char pending_prefix; /* '\0', 'g', 'f','F','t','T','r','m','\'','`','q','@','i','a' */

    /* Visual state */
    size_t                 vis_anchor_line;
    size_t                 vis_anchor_col;
    int                    vblock_dollar;
    npl_vim_visual_range_t last_visual;
    npl_vblock_ins_t       vbi;

    /* Last char find */
    char last_find_kind; /* '\0', 'f', 'F', 't', 'T' */
    char last_find_char;

    /* Registers */
    npl_vim_reg_t reg_unnamed;
    npl_vim_reg_t reg_small;
    npl_vim_reg_t reg_num[10];   /* 0=yank, 1..9=delete ring */
    npl_vim_reg_t reg_alpha[26]; /* a..z */

    /* Marks */
    npl_vim_mark_t marks[26];
    npl_vim_mark_t mark_prev;

    /* Replace-mode backspace restoration stack */
    npl_rep_entry_t *rep_stack;
    size_t           rep_len;
    size_t           rep_cap;

    /* Undo cursor map */
    npl_undo_cur_t *undo_curs;
    size_t          undo_cur_len;
    size_t          undo_cur_cap;
    int             in_insert_group;
    size_t          ins_start_line;
    size_t          ins_start_col;
    int             ins_linewise;
    uint64_t        ins_before_seq;

    /* Dot-repeat */
    int       dot_recording;
    int       dot_replaying;
    uint32_t *dot_cur;
    size_t    dot_cur_len;
    size_t    dot_cur_cap;
    uint32_t *dot_saved;
    size_t    dot_saved_len;
    int       dot_saved_visual;
    npl_vim_mode_t dot_vis_mode;
    size_t    dot_vis_dlines;
    size_t    dot_vis_dcols;
    char      dot_vis_op[4];

    /* Macro recording / replay */
    int       recording;
    int       rec_reg;      /* 0..25 */
    int       rec_append;
    char     *rec_buf;
    size_t    rec_len;
    size_t    rec_cap;
    int       last_macro_reg; /* -1 if none */
    int       macro_depth;
};

/* --- Pure C11 Unsigned-Char Safe ASCII Helpers --- */

static inline int
ch_is_space(uint8_t c)
{
    return (c == ' ' || c == '\t');
}

static inline int
ch_is_digit(uint8_t c)
{
    return (c >= '0' && c <= '9');
}

static inline int
ch_is_lower(uint8_t c)
{
    return (c >= 'a' && c <= 'z');
}

static inline int
ch_is_upper(uint8_t c)
{
    return (c >= 'A' && c <= 'Z');
}

static inline int
ch_is_alpha(uint8_t c)
{
    return ch_is_lower(c) || ch_is_upper(c);
}

static inline uint8_t
ch_to_lower(uint8_t c)
{
    return ch_is_upper(c) ? (uint8_t)(c + ('a' - 'A')) : c;
}

static inline uint8_t
ch_to_upper(uint8_t c)
{
    return ch_is_lower(c) ? (uint8_t)(c - ('a' - 'A')) : c;
}

/* Vim default iskeyword: @,48-57,_,192-255 */
static inline int
ch_is_keyword(uint8_t c)
{
    return ch_is_alpha(c) || ch_is_digit(c) || c == '_' || c >= 192u;
}

static inline int
ch_class(uint8_t c, int big)
{
    if (ch_is_space(c)) return 0;
    if (big) return 1;
    if (ch_is_keyword(c)) return 1;
    return 2;
}

/* --- Dynamic Buffer Helpers --- */

static int
str_reserve(char **buf, size_t *cap, size_t need)
{
    if (need <= *cap) return 1;
    size_t ncap = *cap ? *cap * 2 : 64;
    while (ncap < need) ncap *= 2;
    char *nb = (char *)realloc(*buf, ncap);
    if (!nb) return 0;
    *buf = nb;
    *cap = ncap;
    return 1;
}

static int
u32_push(uint32_t **arr, size_t *len, size_t *cap, uint32_t val)
{
    if (*len >= *cap) {
        size_t ncap = *cap ? *cap * 2 : 32;
        uint32_t *na = (uint32_t *)realloc(*arr, ncap * sizeof(uint32_t));
        if (!na) return 0;
        *arr = na;
        *cap = ncap;
    }
    (*arr)[(*len)++] = val;
    return 1;
}

static void
reg_clear(npl_vim_reg_t *r)
{
    if (!r) return;
    r->len = 0;
    if (r->text) r->text[0] = '\0';
    r->type = NPL_REG_CHAR;
}

static void
reg_free(npl_vim_reg_t *r)
{
    if (!r) return;
    free(r->text);
    r->text = NULL;
    r->len = 0;
    r->cap = 0;
    r->type = NPL_REG_CHAR;
}

static int
reg_set(npl_vim_reg_t *r, const char *s, size_t len, npl_reg_type_t t)
{
    if (!str_reserve(&r->text, &r->cap, len + 1)) return 0;
    if (len > 0 && s) memcpy(r->text, s, len);
    r->text[len] = '\0';
    r->len = len;
    r->type = t;
    return 1;
}

static int
reg_append(npl_vim_reg_t *r, const char *s, size_t len, npl_reg_type_t t)
{
    npl_reg_type_t out_type = r->type;
    if (r->len == 0) {
        return reg_set(r, s, len, t);
    }
    if (t == NPL_REG_LINE || r->type == NPL_REG_LINE) {
        out_type = NPL_REG_LINE;
    }
    int need_nl = (out_type == NPL_REG_LINE && r->len > 0 && r->text[r->len - 1] != '\n');
    size_t extra = len + (need_nl ? 1u : 0u);
    if (!str_reserve(&r->text, &r->cap, r->len + extra + 1)) return 0;
    if (need_nl) {
        r->text[r->len++] = '\n';
    }
    if (len > 0 && s) {
        memcpy(r->text + r->len, s, len);
        r->len += len;
    }
    r->text[r->len] = '\0';
    r->type = out_type;
    return 1;
}

/* --- Buffer Line Helpers --- */

static inline size_t
buf_nlines(npl_vim_t *v)
{
    size_t n = npl_buf_line_count(v->buf);
    return n > 0 ? n : 1;
}

static inline size_t
buf_line_len(npl_vim_t *v, size_t l)
{
    size_t st = 0, ln = 0;
    if (!npl_buf_line_bounds(v->buf, l, &st, &ln)) return 0;
    return ln;
}

static size_t
first_nonblank_str(const char *s, size_t len)
{
    if (!s || len == 0) return 0;
    size_t i = 0;
    while (i < len && ch_is_space((uint8_t)s[i])) i++;
    if (i >= len) return len > 0 ? len - 1 : 0;
    return i;
}

static size_t
first_nonblank_line(npl_vim_t *v, size_t l)
{
    size_t len = 0;
    char *s = npl_buf_get_line_alloc(v->buf, l, &len);
    if (!s) return 0;
    size_t col = first_nonblank_str(s, len);
    free(s);
    return col;
}

static size_t
first_nonblank_insert(npl_vim_t *v, size_t l)
{
    size_t len = 0;
    char *s = npl_buf_get_line_alloc(v->buf, l, &len);
    if (!s) return 0;
    size_t i = 0;
    while (i < len && ch_is_space((uint8_t)s[i])) i++;
    free(s);
    return i;
}

static int
line_is_empty(npl_vim_t *v, size_t l)
{
    return buf_line_len(v, l) == 0;
}

static void
clamp_cursor_normal(npl_vim_t *v, int update_want)
{
    size_t n = buf_nlines(v);
    if (v->line >= n) v->line = n - 1;
    size_t ln = buf_line_len(v, v->line);
    size_t max_c = (ln > 0) ? (ln - 1) : 0;
    if (v->col > max_c) v->col = max_c;
    if (update_want) v->curswant = v->col;
}

static void
clamp_cursor_visual(npl_vim_t *v, int update_want)
{
    size_t n = buf_nlines(v);
    if (v->line >= n) v->line = n - 1;
    size_t ln = buf_line_len(v, v->line);
    size_t max_c = (v->mode == NPL_VIM_VISUAL && v->line + 1 < n) ? ln : (ln > 0 ? ln - 1 : 0);
    if (v->col > max_c) v->col = max_c;
    if (update_want) v->curswant = v->col;
}

static void
clamp_cursor_insert(npl_vim_t *v)
{
    size_t n = buf_nlines(v);
    if (v->line >= n) v->line = n - 1;
    size_t ln = buf_line_len(v, v->line);
    if (v->col > ln) v->col = ln;
    v->curswant = v->col;
}

static void
apply_curswant(npl_vim_t *v)
{
    size_t ln = buf_line_len(v, v->line);
    size_t max_c = (ln > 0) ? (ln - 1) : 0;
    if (v->curswant == NPL_CURSWANT_MAX || v->curswant > max_c) {
        v->col = max_c;
    } else {
        v->col = v->curswant;
    }
}

static void
buf_delete_lines(npl_vim_t *v, size_t sl, size_t el)
{
    size_t n = buf_nlines(v);
    if (sl >= n) return;
    if (el >= n) el = n - 1;
    if (sl > el) return;

    size_t total = npl_buf_byte_length(v->buf);
    if (sl == 0 && el == n - 1) {
        if (total > 0) (void)npl_buf_delete(v->buf, 0, total);
        return;
    }
    size_t s_off = 0, s_len = 0;
    (void)npl_buf_line_bounds(v->buf, sl, &s_off, &s_len);
    if (el + 1 < n) {
        size_t next_off = 0, next_len = 0;
        (void)npl_buf_line_bounds(v->buf, el + 1, &next_off, &next_len);
        if (next_off > s_off) {
            (void)npl_buf_delete(v->buf, s_off, next_off - s_off);
        }
    } else {
        /* Deleting through EOF with sl > 0: also remove preceding '\n' */
        size_t del_from = (s_off > 0) ? (s_off - 1) : 0;
        if (total > del_from) {
            (void)npl_buf_delete(v->buf, del_from, total - del_from);
        }
    }
}

static void
buf_replace_lines_with_empty(npl_vim_t *v, size_t sl, size_t el)
{
    size_t n = buf_nlines(v);
    if (sl >= n) return;
    if (el >= n) el = n - 1;
    if (sl > el) return;

    size_t s_off = 0, s_len = 0;
    size_t e_off = 0, e_len = 0;
    (void)npl_buf_line_bounds(v->buf, sl, &s_off, &s_len);
    (void)npl_buf_line_bounds(v->buf, el, &e_off, &e_len);
    size_t span_end = e_off + e_len;
    if (span_end > s_off) {
        (void)npl_buf_delete(v->buf, s_off, span_end - s_off);
    }
}

static char *
buf_extract_lines_alloc(npl_vim_t *v, size_t sl, size_t el, size_t *out_len)
{
    size_t n = buf_nlines(v);
    if (sl >= n) sl = n - 1;
    if (el >= n) el = n - 1;
    if (sl > el) el = sl;

    size_t s_off = 0, s_len = 0;
    size_t e_off = 0, e_len = 0;
    (void)npl_buf_line_bounds(v->buf, sl, &s_off, &s_len);
    (void)npl_buf_line_bounds(v->buf, el, &e_off, &e_len);
    size_t span = (e_off + e_len) - s_off;

    char *out = (char *)malloc(span + 2);
    if (!out) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    if (span > 0) {
        (void)npl_buf_copy_range(v->buf, s_off, span, out);
    }
    out[span] = '\n';
    out[span + 1] = '\0';
    if (out_len) *out_len = span + 1;
    return out;
}

/* --- Undo Cursor History --- */

static void
record_undo_cursor(npl_vim_t *v, uint64_t seq, size_t edit_line, size_t edit_col, int linewise)
{
    for (size_t i = 0; i < v->undo_cur_len; i++) {
        if (v->undo_curs[i].seq == seq) {
            v->undo_curs[i].edit_line = edit_line;
            v->undo_curs[i].edit_col  = edit_col;
            v->undo_curs[i].linewise  = linewise;
            return;
        }
    }
    if (v->undo_cur_len >= v->undo_cur_cap) {
        size_t ncap = v->undo_cur_cap ? v->undo_cur_cap * 2 : 32;
        npl_undo_cur_t *nu = (npl_undo_cur_t *)realloc(v->undo_curs, ncap * sizeof(npl_undo_cur_t));
        if (!nu) return;
        v->undo_curs = nu;
        v->undo_cur_cap = ncap;
    }
    v->undo_curs[v->undo_cur_len].seq       = seq;
    v->undo_curs[v->undo_cur_len].edit_line = edit_line;
    v->undo_curs[v->undo_cur_len].edit_col  = edit_col;
    v->undo_curs[v->undo_cur_len].linewise  = linewise;
    v->undo_cur_len++;
}

static const npl_undo_cur_t *
find_undo_cursor(const npl_vim_t *v, uint64_t seq)
{
    for (size_t i = 0; i < v->undo_cur_len; i++) {
        if (v->undo_curs[i].seq == seq) {
            return &v->undo_curs[i];
        }
    }
    return NULL;
}

/* --- Register Helpers --- */

static void
store_register_yank(npl_vim_t *v, char reg, const char *text, size_t len, npl_reg_type_t type)
{
    if (reg == '_') return;
    if (reg == '\0' || reg == '"') {
        (void)reg_set(&v->reg_num[0], text, len, type);
        (void)reg_set(&v->reg_unnamed, text, len, type);
    } else if (ch_is_lower((uint8_t)reg)) {
        (void)reg_set(&v->reg_alpha[reg - 'a'], text, len, type);
        (void)reg_set(&v->reg_unnamed, text, len, type);
    } else if (ch_is_upper((uint8_t)reg)) {
        npl_vim_reg_t *dst = &v->reg_alpha[reg - 'A'];
        (void)reg_append(dst, text, len, type);
        (void)reg_set(&v->reg_unnamed, dst->text, dst->len, dst->type);
    } else if (reg == '0') {
        (void)reg_set(&v->reg_num[0], text, len, type);
        (void)reg_set(&v->reg_unnamed, text, len, type);
    } else {
        (void)reg_set(&v->reg_unnamed, text, len, type);
    }
}

static void
store_register_delete(npl_vim_t *v, char reg, const char *text, size_t len, npl_reg_type_t type)
{
    if (reg == '_') return;

    int has_nl = (type == NPL_REG_LINE) || (len > 0 && memchr(text, '\n', len) != NULL);
    if (has_nl && (reg == '\0' || reg == '"')) {
        /* Shift numbered delete ring 1..9 */
        for (int i = 9; i >= 2; i--) {
            (void)reg_set(&v->reg_num[i], v->reg_num[i - 1].text ? v->reg_num[i - 1].text : "",
                          v->reg_num[i - 1].len, v->reg_num[i - 1].type);
        }
        (void)reg_set(&v->reg_num[1], text, len, type);
    } else if (!has_nl && (reg == '\0' || reg == '"')) {
        (void)reg_set(&v->reg_small, text, len, type);
    }

    if (reg == '\0' || reg == '"') {
        (void)reg_set(&v->reg_unnamed, text, len, type);
    } else if (ch_is_lower((uint8_t)reg)) {
        (void)reg_set(&v->reg_alpha[reg - 'a'], text, len, type);
        (void)reg_set(&v->reg_unnamed, text, len, type);
    } else if (ch_is_upper((uint8_t)reg)) {
        npl_vim_reg_t *dst = &v->reg_alpha[reg - 'A'];
        (void)reg_append(dst, text, len, type);
        (void)reg_set(&v->reg_unnamed, dst->text, dst->len, dst->type);
    } else {
        (void)reg_set(&v->reg_unnamed, text, len, type);
    }
}

static const npl_vim_reg_t *
lookup_register(const npl_vim_t *v, char name)
{
    if (name == '\0' || name == '"') return &v->reg_unnamed;
    if (name == '-') return &v->reg_small;
    if (name == '_') return NULL;
    if (ch_is_digit((uint8_t)name)) return &v->reg_num[name - '0'];
    if (ch_is_lower((uint8_t)name)) return &v->reg_alpha[name - 'a'];
    if (ch_is_upper((uint8_t)name)) return &v->reg_alpha[name - 'A'];
    return &v->reg_unnamed;
}

/* --- Dot-Repeat Helpers --- */

static void
dot_start(npl_vim_t *v)
{
    if (v->dot_replaying) return;
    v->dot_recording = 1;
    v->dot_cur_len = 0;
}

static void
dot_push(npl_vim_t *v, uint32_t key)
{
    if (v->dot_replaying || !v->dot_recording) return;
    (void)u32_push(&v->dot_cur, &v->dot_cur_len, &v->dot_cur_cap, key);
}

static void
dot_push_count(npl_vim_t *v, int cnt)
{
    if (cnt <= 0 || v->dot_replaying || !v->dot_recording) return;
    char tmp[32];
    int n = 0;
    int x = cnt;
    while (x > 0 && n < 30) {
        tmp[n++] = (char)('0' + (x % 10));
        x /= 10;
    }
    for (int i = n - 1; i >= 0; i--) {
        dot_push(v, (uint32_t)(uint8_t)tmp[i]);
    }
}

static void
dot_finish(npl_vim_t *v)
{
    if (v->dot_replaying || !v->dot_recording) return;
    v->dot_recording = 0;
    if (v->dot_cur_len > 0) {
        uint32_t *copy = (uint32_t *)malloc(v->dot_cur_len * sizeof(uint32_t));
        if (copy) {
            memcpy(copy, v->dot_cur, v->dot_cur_len * sizeof(uint32_t));
            free(v->dot_saved);
            v->dot_saved = copy;
            v->dot_saved_len = v->dot_cur_len;
            v->dot_saved_visual = 0;
        }
    }
    v->dot_cur_len = 0;
}

static void
dot_save_visual(npl_vim_t *v, npl_vim_mode_t vmode, size_t dlines, size_t dcols, const char *op)
{
    if (v->dot_replaying) return;
    v->dot_recording = 0;
    v->dot_cur_len = 0;
    v->dot_saved_visual = 1;
    v->dot_vis_mode = vmode;
    v->dot_vis_dlines = dlines;
    v->dot_vis_dcols = dcols;
    memset(v->dot_vis_op, 0, sizeof(v->dot_vis_op));
    if (op) {
        size_t ol = strlen(op);
        if (ol > 3) ol = 3;
        memcpy(v->dot_vis_op, op, ol);
    }
}

/* --- Grammar Helpers --- */

static void
reset_grammar(npl_vim_t *v)
{
    v->count1 = 0;
    v->has_count1 = 0;
    v->count2 = 0;
    v->has_count2 = 0;
    v->op[0] = '\0';
    v->reg = '\0';
    v->expect_reg = 0;
    v->pending_prefix = '\0';
    if (v->mode == NPL_VIM_OPERATOR) {
        v->mode = NPL_VIM_NORMAL;
    }
}

static int
effective_count(const npl_vim_t *v, int def)
{
    int c1 = v->has_count1 ? v->count1 : 0;
    int c2 = v->has_count2 ? v->count2 : 0;
    if (c1 > 0 && c2 > 0) return c1 * c2;
    if (c1 > 0) return c1;
    if (c2 > 0) return c2;
    return def;
}

static int
has_any_count(const npl_vim_t *v)
{
    return (v->has_count1 || v->has_count2) ? 1 : 0;
}

static int
is_visual_mode(npl_vim_mode_t m)
{
    return (m == NPL_VIM_VISUAL || m == NPL_VIM_VLINE || m == NPL_VIM_VBLOCK);
}

static void
compute_visual_range(const npl_vim_t *v, npl_vim_visual_range_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!is_visual_mode(v->mode)) return;
    out->active = 1;
    out->mode = v->mode;
    size_t l1 = v->vis_anchor_line, c1 = v->vis_anchor_col;
    size_t l2 = v->line, c2 = v->col;
    if (v->mode == NPL_VIM_VBLOCK) {
        out->start_line = (l1 <= l2) ? l1 : l2;
        out->end_line   = (l1 <= l2) ? l2 : l1;
        out->start_col  = (c1 <= c2) ? c1 : c2;
        out->end_col    = (c1 <= c2) ? c2 : c1;
    } else {
        if (l1 > l2 || (l1 == l2 && c1 > c2)) {
            out->start_line = l2; out->start_col = c2;
            out->end_line   = l1; out->end_col   = c1;
        } else {
            out->start_line = l1; out->start_col = c1;
            out->end_line   = l2; out->end_col   = c2;
        }
    }
}

/* --- Key Serialization (for Macro Recording into Registers) --- */

static int
encode_key_to_buf(char **buf, size_t *len, size_t *cap, uint32_t key)
{
    char tmp[8];
    size_t n = 0;
    if (key < 0x100u) {
        tmp[0] = (char)(uint8_t)key;
        n = 1;
    } else if (key == NPL_K_ESC) {
        tmp[0] = 0x1B; n = 1;
    } else if (key == NPL_K_CR) {
        tmp[0] = '\r'; n = 1;
    } else if (key == NPL_K_BS) {
        tmp[0] = 0x08; n = 1;
    } else if (key == NPL_K_TAB) {
        tmp[0] = '\t'; n = 1;
    } else if (key == NPL_K_DEL) {
        memcpy(tmp, "<Del>", 5); n = 5;
    } else if (key == NPL_K_LEFT) {
        memcpy(tmp, "<Left>", 6); n = 6;
    } else if (key == NPL_K_RIGHT) {
        memcpy(tmp, "<Right>", 7); n = 7;
    } else if (key == NPL_K_UP) {
        memcpy(tmp, "<Up>", 4); n = 4;
    } else if (key == NPL_K_DOWN) {
        memcpy(tmp, "<Down>", 6); n = 6;
    } else if (key == NPL_K_HOME) {
        memcpy(tmp, "<Home>", 6); n = 6;
    } else if (key == NPL_K_END) {
        memcpy(tmp, "<End>", 5); n = 5;
    } else if (key >= NPL_K_CTRL_BASE && key < NPL_K_CTRL_BASE + 26) {
        tmp[0] = (char)(uint8_t)(key - NPL_K_CTRL_BASE + 1);
        n = 1;
    } else if (key == NPL_K_CTRL_LBRACKET) {
        tmp[0] = 0x1B; n = 1;
    } else if (key == NPL_K_CTRL_BSLASH) {
        tmp[0] = 0x1C; n = 1;
    } else if (key == NPL_K_CTRL_RBRACKET) {
        tmp[0] = 0x1D; n = 1;
    }
    if (n == 0) return 1;
    if (!str_reserve(buf, cap, *len + n + 1)) return 0;
    memcpy(*buf + *len, tmp, n);
    *len += n;
    (*buf)[*len] = '\0';
    return 1;
}

/* --- Motions --- */

static void
motion_word_forward(npl_vim_t *v, size_t l, size_t c, int cnt, int big,
                    int for_change, int for_op,
                    size_t *out_l, size_t *out_c, int *out_inclusive)
{
    size_t nlines = buf_nlines(v);
    *out_inclusive = 0;

    for (int step = 0; step < cnt; step++) {
        int is_last = (step == cnt - 1);
        size_t len = 0;
        char *line = npl_buf_get_line_alloc(v->buf, l, &len);
        if (!line) break;

        /* Special case: cw / cW on the last step */
        if (for_change && is_last) {
            if (len == 0) {
                free(line);
                if (l + 1 < nlines) {
                    l++;
                    c = 0;
                }
                break;
            }
            if (c >= len) c = len - 1;
            int cls = ch_class((uint8_t)line[c], big);
            if (cls != 0) {
                /* On non-whitespace: move to end of this word (inclusive) */
                while (c + 1 < len && ch_class((uint8_t)line[c + 1], big) == cls) {
                    c++;
                }
                *out_inclusive = 1;
                free(line);
                break;
            } else {
                /* On whitespace: advance through whitespace (exclusive) */
                while (c < len && ch_is_space((uint8_t)line[c])) {
                    c++;
                }
                free(line);
                break;
            }
        }

        if (len == 0) {
            free(line);
            if (l + 1 < nlines) {
                l++;
                c = 0;
                /* Skip leading whitespace on next line; stop on empty line */
                for (;;) {
                    size_t nlen = 0;
                    char *nline = npl_buf_get_line_alloc(v->buf, l, &nlen);
                    if (!nline) break;
                    if (nlen == 0) {
                        free(nline);
                        c = 0;
                        break;
                    }
                    c = 0;
                    while (c < nlen && ch_is_space((uint8_t)nline[c])) c++;
                    free(nline);
                    if (c < nlen) break;
                    if (l + 1 < nlines) {
                        l++;
                        c = 0;
                    } else {
                        c = nlen > 0 ? nlen - 1 : 0;
                        break;
                    }
                }
            } else {
                c = 0;
                break;
            }
            continue;
        }

        if (c < len) {
            int cls = ch_class((uint8_t)line[c], big);
            if (cls != 0) {
                while (c < len && ch_class((uint8_t)line[c], big) == cls) c++;
            }
            while (c < len && ch_is_space((uint8_t)line[c])) c++;
        }
        free(line);

        if (c >= len) {
            if (l + 1 < nlines) {
                l++;
                c = 0;
                for (;;) {
                    size_t nlen = 0;
                    char *nline = npl_buf_get_line_alloc(v->buf, l, &nlen);
                    if (!nline) break;
                    if (nlen == 0) {
                        free(nline);
                        c = 0;
                        break;
                    }
                    c = 0;
                    while (c < nlen && ch_is_space((uint8_t)nline[c])) c++;
                    free(nline);
                    if (c < nlen) break;
                    if (l + 1 < nlines) {
                        l++;
                        c = 0;
                    } else {
                        c = for_op ? nlen : (nlen > 0 ? nlen - 1 : 0);
                        break;
                    }
                }
            } else {
                c = for_op ? len : (len > 0 ? len - 1 : 0);
                break;
            }
        }
    }

    *out_l = l;
    *out_c = c;
}

static void
motion_word_backward(npl_vim_t *v, size_t l, size_t c, int cnt, int big,
                     size_t *out_l, size_t *out_c)
{
    for (int step = 0; step < cnt; step++) {
        size_t len = 0;
        char *line = npl_buf_get_line_alloc(v->buf, l, &len);
        if (!line) break;

        if (c == 0) {
            free(line);
            if (l == 0) break;
            l--;
            for (;;) {
                size_t plen = 0;
                char *pline = npl_buf_get_line_alloc(v->buf, l, &plen);
                if (!pline) { c = 0; break; }
                if (plen == 0) {
                    /* Empty line stops b/B */
                    free(pline);
                    c = 0;
                    break;
                }
                size_t p = plen;
                while (p > 0 && ch_is_space((uint8_t)pline[p - 1])) p--;
                if (p == 0) {
                    free(pline);
                    if (l == 0) { c = 0; break; }
                    l--;
                    continue;
                }
                c = p - 1;
                int cls = ch_class((uint8_t)pline[c], big);
                while (c > 0 && ch_class((uint8_t)pline[c - 1], big) == cls) c--;
                free(pline);
                break;
            }
            continue;
        }

        if (c > len) c = len;
        size_t p = c - 1;
        while (p > 0 && ch_is_space((uint8_t)line[p])) p--;
        if (p == 0 && ch_is_space((uint8_t)line[0])) {
            free(line);
            if (l == 0) { c = 0; break; }
            l--;
            for (;;) {
                size_t plen = 0;
                char *pline = npl_buf_get_line_alloc(v->buf, l, &plen);
                if (!pline) { c = 0; break; }
                if (plen == 0) {
                    free(pline);
                    c = 0;
                    break;
                }
                size_t q = plen;
                while (q > 0 && ch_is_space((uint8_t)pline[q - 1])) q--;
                if (q == 0) {
                    free(pline);
                    if (l == 0) { c = 0; break; }
                    l--;
                    continue;
                }
                c = q - 1;
                int cls = ch_class((uint8_t)pline[c], big);
                while (c > 0 && ch_class((uint8_t)pline[c - 1], big) == cls) c--;
                free(pline);
                break;
            }
            continue;
        }

        c = p;
        int cls = ch_class((uint8_t)line[c], big);
        while (c > 0 && ch_class((uint8_t)line[c - 1], big) == cls) c--;
        free(line);
    }

    *out_l = l;
    *out_c = c;
}

static void
motion_word_end_forward(npl_vim_t *v, size_t l, size_t c, int cnt, int big,
                        size_t *out_l, size_t *out_c)
{
    size_t nlines = buf_nlines(v);
    for (int step = 0; step < cnt; step++) {
        size_t len = 0;
        char *line = npl_buf_get_line_alloc(v->buf, l, &len);
        if (!line) break;

        size_t p = (len > 0) ? (c + 1) : 0;
        for (;;) {
            while (p < len && ch_is_space((uint8_t)line[p])) p++;
            if (p < len) break;
            free(line);
            if (l + 1 < nlines) {
                l++;
                line = npl_buf_get_line_alloc(v->buf, l, &len);
                if (!line) { *out_l = l; *out_c = 0; return; }
                p = 0;
            } else {
                *out_l = l;
                *out_c = (len > 0) ? (len - 1) : 0;
                return;
            }
        }
        int cls = ch_class((uint8_t)line[p], big);
        while (p + 1 < len && ch_class((uint8_t)line[p + 1], big) == cls) p++;
        c = p;
        free(line);
    }
    *out_l = l;
    *out_c = c;
}

static void
motion_word_end_backward(npl_vim_t *v, size_t l, size_t c, int cnt, int big,
                         size_t *out_l, size_t *out_c)
{
    for (int step = 0; step < cnt; step++) {
        size_t len = 0;
        char *line = npl_buf_get_line_alloc(v->buf, l, &len);
        if (!line) break;

        int found = 0;
        if (len > 0 && c < len) {
            int cls = ch_class((uint8_t)line[c], big);
            if (cls != 0) {
                /* Skip backward to start of current word, then one more */
                while (c > 0 && ch_class((uint8_t)line[c - 1], big) == cls) c--;
            }
            if (c > 0) {
                size_t p = c - 1;
                while (p > 0 && ch_is_space((uint8_t)line[p])) p--;
                if (!ch_is_space((uint8_t)line[p])) {
                    c = p;
                    found = 1;
                }
            }
        }
        free(line);

        if (!found) {
            while (l > 0) {
                l--;
                size_t plen = 0;
                char *pline = npl_buf_get_line_alloc(v->buf, l, &plen);
                if (!pline) break;
                if (plen > 0) {
                    size_t p = plen;
                    while (p > 0 && ch_is_space((uint8_t)pline[p - 1])) p--;
                    if (p > 0) {
                        c = p - 1;
                        found = 1;
                        free(pline);
                        break;
                    }
                }
                free(pline);
            }
            if (!found) {
                l = 0;
                c = 0;
                break;
            }
        }
    }
    *out_l = l;
    *out_c = c;
}

static int
motion_matching_bracket(npl_vim_t *v, size_t l, size_t c, size_t *out_l, size_t *out_c)
{
    size_t len = 0;
    char *line = npl_buf_get_line_alloc(v->buf, l, &len);
    if (!line) return 0;

    char ch = '\0';
    size_t open_col = c;
    while (open_col < len) {
        char t = line[open_col];
        if (t == '(' || t == ')' || t == '[' || t == ']' || t == '{' || t == '}') {
            ch = t;
            break;
        }
        open_col++;
    }
    free(line);
    if (ch == '\0') return 0;

    char target = '\0';
    int dir = 1;
    switch (ch) {
    case '(': target = ')'; dir =  1; break;
    case ')': target = '('; dir = -1; break;
    case '[': target = ']'; dir =  1; break;
    case ']': target = '['; dir = -1; break;
    case '{': target = '}'; dir =  1; break;
    case '}': target = '{'; dir = -1; break;
    default: return 0;
    }

    size_t blen = 0;
    char *text = npl_buf_to_string(v->buf, &blen);
    if (!text || blen == 0) {
        free(text);
        return 0;
    }
    size_t pos = npl_buf_line_col_to_offset(v->buf, l, open_col);
    int depth = 0;
    int ok = 0;
    if (dir > 0) {
        for (size_t i = pos; i < blen; i++) {
            if (text[i] == ch) depth++;
            else if (text[i] == target) depth--;
            if (depth == 0) {
                npl_buf_offset_to_line_col(v->buf, i, out_l, out_c);
                ok = 1;
                break;
            }
        }
    } else {
        for (size_t i = pos + 1; i > 0; i--) {
            size_t idx = i - 1;
            if (text[idx] == ch) depth++;
            else if (text[idx] == target) depth--;
            if (depth == 0) {
                npl_buf_offset_to_line_col(v->buf, idx, out_l, out_c);
                ok = 1;
                break;
            }
        }
    }
    free(text);
    return ok;
}

static size_t
motion_paragraph(npl_vim_t *v, size_t l, int dir, int cnt)
{
    size_t n = buf_nlines(v);
    if (n <= 1) return 0;
    for (int step = 0; step < cnt; step++) {
        if (dir > 0) {
            while (l + 1 < n && line_is_empty(v, l)) l++;
            while (l + 1 < n && !line_is_empty(v, l)) l++;
        } else {
            while (l > 0 && line_is_empty(v, l)) l--;
            while (l > 0 && !line_is_empty(v, l)) l--;
        }
    }
    return l;
}

static int
motion_char_find(npl_vim_t *v, size_t l, size_t c, char kind, char ch, int cnt, int is_repeat,
                 size_t *out_col)
{
    size_t len = 0;
    char *line = npl_buf_get_line_alloc(v->buf, l, &len);
    if (!line || len == 0) {
        free(line);
        return 0;
    }
    int dir = (kind == 'f' || kind == 't') ? 1 : -1;
    size_t pos = (c < len) ? c : (len - 1);

    if (is_repeat && cnt == 1 && (kind == 't' || kind == 'T')) {
        if (dir > 0 && pos + 1 < len && line[pos + 1] == ch) {
            pos++;
        } else if (dir < 0 && pos > 0 && line[pos - 1] == ch) {
            pos--;
        }
    }

    int found = 0;
    for (int step = 0; step < cnt; step++) {
        found = 0;
        if (dir > 0) {
            for (size_t i = pos + 1; i < len; i++) {
                if (line[i] == ch) {
                    pos = i;
                    found = 1;
                    break;
                }
            }
        } else {
            for (size_t i = pos; i > 0; i--) {
                if (line[i - 1] == ch) {
                    pos = i - 1;
                    found = 1;
                    break;
                }
            }
        }
        if (!found) break;
    }
    free(line);
    if (!found) return 0;

    if (kind == 't') {
        *out_col = (pos > 0) ? (pos - 1) : 0;
    } else if (kind == 'T') {
        *out_col = pos + 1;
    } else {
        *out_col = pos;
    }
    return 1;
}

/* --- Text Objects --- */

static int
resolve_text_object(npl_vim_t *v, int inner, char kind, int cnt, npl_range_t *out)
{
    memset(out, 0, sizeof(*out));
    size_t l = v->line;
    size_t c = v->col;
    if (cnt < 1) cnt = 1;

    /* iw / aw / iW / aW */
    if (kind == 'w' || kind == 'W') {
        int big = (kind == 'W');
        size_t len = 0;
        char *line = npl_buf_get_line_alloc(v->buf, l, &len);
        if (!line) return 0;
        if (len == 0) {
            free(line);
            if (inner) return 0;
            /* aw / aW on an empty line consumes through the first word on a subsequent line */
            size_t nlines = buf_nlines(v);
            for (size_t nl = l + 1; nl < nlines; nl++) {
                size_t nlen = 0;
                char *nline = npl_buf_get_line_alloc(v->buf, nl, &nlen);
                if (!nline) break;
                size_t p = 0;
                while (p < nlen && ch_is_space((uint8_t)nline[p])) p++;
                if (p < nlen) {
                    int wcls = ch_class((uint8_t)nline[p], big);
                    size_t we = p;
                    while (we + 1 < nlen && ch_class((uint8_t)nline[we + 1], big) == wcls) we++;
                    free(nline);
                    out->start_line = l;  out->start_col = 0;
                    out->end_line   = nl; out->end_col   = we;
                    return 1;
                }
                free(nline);
            }
            return 0;
        }
        if (c >= len) c = len - 1;
        int cls = ch_class((uint8_t)line[c], big);
        size_t s = c, e = c;
        while (s > 0 && ch_class((uint8_t)line[s - 1], big) == cls) s--;
        while (e + 1 < len && ch_class((uint8_t)line[e + 1], big) == cls) e++;

        if (inner) {
            for (int k = 1; k < cnt && e + 1 < len; k++) {
                e++;
                int ncls = ch_class((uint8_t)line[e], big);
                while (e + 1 < len && ch_class((uint8_t)line[e + 1], big) == ncls) e++;
            }
        } else {
            if (cls == 0) {
                /* Cursor on whitespace: include following word (or preceding if none) */
                if (e + 1 < len) {
                    e++;
                    int wcls = ch_class((uint8_t)line[e], big);
                    while (e + 1 < len && ch_class((uint8_t)line[e + 1], big) == wcls) e++;
                } else if (s > 0) {
                    s--;
                    int wcls = ch_class((uint8_t)line[s], big);
                    while (s > 0 && ch_class((uint8_t)line[s - 1], big) == wcls) s--;
                }
            } else {
                /* Cursor on word: prefer trailing whitespace, else leading whitespace */
                if (e + 1 < len && ch_is_space((uint8_t)line[e + 1])) {
                    while (e + 1 < len && ch_is_space((uint8_t)line[e + 1])) e++;
                } else if (s > 0 && ch_is_space((uint8_t)line[s - 1])) {
                    while (s > 0 && ch_is_space((uint8_t)line[s - 1])) s--;
                }
            }
            for (int k = 1; k < cnt && e + 1 < len; k++) {
                e++;
                int wcls = ch_class((uint8_t)line[e], big);
                while (e + 1 < len && ch_class((uint8_t)line[e + 1], big) == wcls) e++;
                if (wcls != 0) {
                    while (e + 1 < len && ch_is_space((uint8_t)line[e + 1])) e++;
                }
            }
        }
        free(line);
        out->start_line = l; out->start_col = s;
        out->end_line   = l; out->end_col   = e;
        return 1;
    }

    /* Quotes: " ' ` */
    if (kind == '"' || kind == '\'' || kind == '`') {
        size_t len = 0;
        char *line = npl_buf_get_line_alloc(v->buf, l, &len);
        if (!line || len == 0) {
            free(line);
            return 0;
        }
        size_t *qs = (size_t *)malloc((len + 1) * sizeof(size_t));
        if (!qs) { free(line); return 0; }
        size_t qcnt = 0;
        for (size_t i = 0; i < len; i++) {
            if (line[i] == '\\' && i + 1 < len && kind != '`') {
                i++;
                continue;
            }
            if (line[i] == kind) {
                qs[qcnt++] = i;
            }
        }

        int found = 0;
        size_t qopen = 0, qclose = 0;
        /* Pair quotes: (0,1), (2,3), ...; match enclosing or forward-search on current line */
        for (size_t j = 0; j + 1 < qcnt; j += 2) {
            if (c >= qs[j] && c <= qs[j + 1]) {
                qopen = qs[j];
                qclose = qs[j + 1];
                found = 1;
                break;
            }
            if (!found && qs[j] > c) {
                qopen = qs[j];
                qclose = qs[j + 1];
                found = 1;
                break;
            }
        }
        free(qs);
        if (!found) {
            free(line);
            return 0;
        }

        if (inner) {
            free(line);
            if (qclose <= qopen + 1) {
                out->start_line = l; out->start_col = qopen + 1;
                out->end_line   = l; out->end_col   = qopen + 1;
                out->empty = 1;
            } else {
                out->start_line = l; out->start_col = qopen + 1;
                out->end_line   = l; out->end_col   = qclose - 1;
            }
            return 1;
        }

        /* a" / a' / a`: include trailing whitespace if present, else leading whitespace */
        size_t s = qopen, e = qclose;
        if (e + 1 < len && ch_is_space((uint8_t)line[e + 1])) {
            while (e + 1 < len && ch_is_space((uint8_t)line[e + 1])) e++;
        } else if (s > 0 && ch_is_space((uint8_t)line[s - 1])) {
            while (s > 0 && ch_is_space((uint8_t)line[s - 1])) s--;
        }
        free(line);
        out->start_line = l; out->start_col = s;
        out->end_line   = l; out->end_col   = e;
        return 1;
    }

    /* Delimited pairs: (), [], {}, <> */
    char op_ch = '\0', cl_ch = '\0';
    switch (kind) {
    case '(': case ')': case 'b': op_ch = '('; cl_ch = ')'; break;
    case '[': case ']':           op_ch = '['; cl_ch = ']'; break;
    case '{': case '}': case 'B': op_ch = '{'; cl_ch = '}'; break;
    case '<': case '>':           op_ch = '<'; cl_ch = '>'; break;
    default: break;
    }
    if (op_ch != '\0') {
        size_t blen = 0;
        char *text = npl_buf_to_string(v->buf, &blen);
        if (!text || blen == 0) {
            free(text);
            return 0;
        }
        size_t pos = npl_buf_line_col_to_offset(v->buf, l, c);
        if (pos >= blen) pos = blen - 1;

        size_t cur_pos = pos;
        size_t open_pos = 0, close_pos = 0;
        int ok = 0;

        for (int level = 0; level < cnt; level++) {
            int found_open = 0;
            int depth = 0;
            size_t search_from = (level == 0) ? cur_pos : (open_pos > 0 ? open_pos - 1 : 0);
            if (level > 0 && open_pos == 0) {
                ok = 0;
                break;
            }
            for (size_t i = search_from + 1; i > 0; i--) {
                size_t idx = i - 1;
                if (text[idx] == cl_ch && idx < search_from) {
                    depth++;
                } else if (text[idx] == op_ch) {
                    if (depth == 0) {
                        open_pos = idx;
                        found_open = 1;
                        break;
                    }
                    depth--;
                }
            }
            if (!found_open && level == 0) {
                /* Vim 9.1: search forward across lines for opener when not inside a pair */
                for (size_t j = pos; j < blen; j++) {
                    if (text[j] == op_ch) {
                        open_pos = j;
                        found_open = 1;
                        break;
                    }
                }
            }
            if (!found_open) { ok = 0; break; }

            int found_close = 0;
            depth = 0;
            for (size_t i = open_pos; i < blen; i++) {
                if (text[i] == op_ch) depth++;
                else if (text[i] == cl_ch) depth--;
                if (depth == 0) {
                    close_pos = i;
                    found_close = 1;
                    break;
                }
            }
            if (!found_close) { ok = 0; break; }
            ok = 1;
        }

        if (!ok) {
            free(text);
            return 0;
        }

        if (inner) {
            size_t ol = 0, oc = 0, cl = 0, cc = 0;
            npl_buf_offset_to_line_col(v->buf, open_pos, &ol, &oc);
            npl_buf_offset_to_line_col(v->buf, close_pos, &cl, &cc);

            /* Vim multiline inner-block rule: if open is at EOL and only ws before close on its line */
            if (cl > ol && open_pos + 1 < blen && text[open_pos + 1] == '\n') {
                size_t c_lst = 0, c_llen = 0;
                int only_ws_before_close = 1;
                if (npl_buf_line_bounds(v->buf, cl, &c_lst, &c_llen)) {
                    for (size_t k = 0; k < cc; k++) {
                        if (!ch_is_space((uint8_t)text[c_lst + k])) {
                            only_ws_before_close = 0;
                            break;
                        }
                    }
                }
                if (only_ws_before_close) {
                    free(text);
                    if (cl <= ol + 1) {
                        out->start_line = ol + 1; out->start_col = 0;
                        out->end_line   = ol + 1; out->end_col   = 0;
                        out->empty = 1;
                    } else {
                        out->start_line = ol + 1; out->start_col = 0;
                        out->end_line   = cl - 1; out->end_col   = buf_line_len(v, cl - 1);
                        out->linewise   = 1;
                    }
                    return 1;
                }
            }

            free(text);
            if (close_pos <= open_pos + 1) {
                npl_buf_offset_to_line_col(v->buf, open_pos + 1, &out->start_line, &out->start_col);
                out->end_line = out->start_line;
                out->end_col  = out->start_col;
                out->empty    = 1;
            } else {
                npl_buf_offset_to_line_col(v->buf, open_pos + 1, &out->start_line, &out->start_col);
                npl_buf_offset_to_line_col(v->buf, close_pos - 1, &out->end_line, &out->end_col);
            }
            return 1;
        }

        free(text);
        npl_buf_offset_to_line_col(v->buf, open_pos, &out->start_line, &out->start_col);
        npl_buf_offset_to_line_col(v->buf, close_pos, &out->end_line, &out->end_col);
        return 1;
    }

    /* Paragraph: ip / ap */
    if (kind == 'p') {
        size_t n = buf_nlines(v);
        int blank = line_is_empty(v, l);
        size_t s = l, e = l;
        if (blank) {
            while (s > 0 && line_is_empty(v, s - 1)) s--;
            while (e + 1 < n && line_is_empty(v, e + 1)) e++;
            if (!inner && e + 1 < n) {
                while (e + 1 < n && !line_is_empty(v, e + 1)) e++;
            }
        } else {
            while (s > 0 && !line_is_empty(v, s - 1)) s--;
            while (e + 1 < n && !line_is_empty(v, e + 1)) e++;
            if (!inner) {
                if (e + 1 < n && line_is_empty(v, e + 1)) {
                    while (e + 1 < n && line_is_empty(v, e + 1)) e++;
                } else if (s > 0 && line_is_empty(v, s - 1)) {
                    while (s > 0 && line_is_empty(v, s - 1)) s--;
                }
            }
        }
        for (int k = 1; k < cnt && e + 1 < n; k++) {
            int cur_b = line_is_empty(v, e + 1);
            e++;
            while (e + 1 < n && line_is_empty(v, e + 1) == cur_b) e++;
            if (!inner && !cur_b && e + 1 < n && line_is_empty(v, e + 1)) {
                while (e + 1 < n && line_is_empty(v, e + 1)) e++;
            }
        }
        out->start_line = s; out->start_col = 0;
        out->end_line   = e; out->end_col   = buf_line_len(v, e);
        out->linewise   = 1;
        return 1;
    }

    return 0;
}

/* --- Operator Execution --- */

static void
apply_indent_lines(npl_vim_t *v, size_t sl, size_t el, int dedent, int repeat_cnt)
{
    size_t n = buf_nlines(v);
    if (sl >= n) return;
    if (el >= n) el = n - 1;
    int sw = (v->shiftwidth > 0) ? v->shiftwidth : 4;
    if (repeat_cnt < 1) repeat_cnt = 1;

    uint64_t bseq = npl_buf_undo_seq(v->buf);
    npl_buf_begin_group(v->buf);
    for (int rep = 0; rep < repeat_cnt; rep++) {
        for (size_t l = sl; l <= el; l++) {
            size_t st = 0, ln = 0;
            if (!npl_buf_line_bounds(v->buf, l, &st, &ln)) continue;
            if (ln == 0) continue; /* Vim does not indent empty lines */
            if (!dedent) {
                if (v->expandtab) {
                    char pad[64];
                    int left = sw;
                    while (left > 0) {
                        int chunk = (left > 64) ? 64 : left;
                        memset(pad, ' ', (size_t)chunk);
                        (void)npl_buf_insert(v->buf, st, pad, (size_t)chunk);
                        left -= chunk;
                    }
                } else {
                    (void)npl_buf_insert(v->buf, st, "\t", 1);
                }
            } else {
                char *line = npl_buf_get_line_alloc(v->buf, l, &ln);
                if (!line) continue;
                size_t rm = 0;
                if (ln > 0 && line[0] == '\t') {
                    rm = 1;
                } else {
                    while (rm < ln && rm < (size_t)sw && line[rm] == ' ') rm++;
                }
                free(line);
                if (rm > 0) (void)npl_buf_delete(v->buf, st, rm);
            }
        }
    }
    npl_buf_end_group(v->buf);
    if (npl_buf_undo_seq(v->buf) == bseq) {
        /* Vim records an undo point for >/< even when 0 bytes changed */
        size_t st = 0, ln = 0;
        (void)npl_buf_line_bounds(v->buf, sl, &st, &ln);
        npl_buf_begin_group(v->buf);
        (void)npl_buf_insert(v->buf, st, " ", 1);
        (void)npl_buf_delete(v->buf, st, 1);
        npl_buf_end_group(v->buf);
    }
    if (npl_buf_undo_seq(v->buf) != bseq) {
        record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, first_nonblank_line(v, sl), 1);
    }
    v->line = sl;
    v->col = first_nonblank_line(v, sl);
    v->curswant = v->col;
}

static void
apply_case_str(char *s, size_t len, const char *op)
{
    if (op[1] == 'u') {
        for (size_t i = 0; i < len; i++) s[i] = (char)ch_to_lower((uint8_t)s[i]);
    } else if (op[1] == 'U') {
        for (size_t i = 0; i < len; i++) s[i] = (char)ch_to_upper((uint8_t)s[i]);
    } else {
        for (size_t i = 0; i < len; i++) {
            uint8_t c = (uint8_t)s[i];
            if (ch_is_lower(c))      s[i] = (char)ch_to_upper(c);
            else if (ch_is_upper(c)) s[i] = (char)ch_to_lower(c);
        }
    }
}

static void
enter_insert_mode(npl_vim_t *v, size_t l, size_t c, int linewise)
{
    v->line = l;
    v->col = c;
    clamp_cursor_insert(v);
    v->ins_start_line = v->line;
    v->ins_start_col  = v->col;
    v->ins_linewise   = linewise;
    if (!v->in_insert_group) {
        v->ins_before_seq = npl_buf_undo_seq(v->buf);
        npl_buf_begin_group(v->buf);
        v->in_insert_group = 1;
    }
    v->mode = NPL_VIM_INSERT;
}

static void
apply_operator_range(npl_vim_t *v, const char *op, const npl_range_t *r, char reg)
{
    size_t sl = r->start_line, sc = r->start_col;
    size_t el = r->end_line,   ec = r->end_col;

    if (op[0] == '>' || op[0] == '<') {
        apply_indent_lines(v, sl, el, op[0] == '<', 1);
        return;
    }

    if (r->linewise) {
        size_t text_len = 0;
        char *text = buf_extract_lines_alloc(v, sl, el, &text_len);
        if (!text) return;

        if (op[0] == 'y') {
            store_register_yank(v, reg, text, text_len, NPL_REG_LINE);
            free(text);
            v->line = sl;
            clamp_cursor_normal(v, 1);
            return;
        }
        if (op[0] == 'd') {
            store_register_delete(v, reg, text, text_len, NPL_REG_LINE);
            free(text);
            uint64_t bseq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            buf_delete_lines(v, sl, el);
            npl_buf_end_group(v->buf);
            size_t n = buf_nlines(v);
            v->line = (sl >= n) ? (n - 1) : sl;
            v->col = first_nonblank_line(v, v->line);
            v->curswant = v->col;
            if (npl_buf_undo_seq(v->buf) != bseq) {
                record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, 0, 1);
            }
            return;
        }
        if (op[0] == 'c') {
            store_register_delete(v, reg, text, text_len, NPL_REG_LINE);
            free(text);
            v->ins_before_seq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            v->in_insert_group = 1;
            buf_replace_lines_with_empty(v, sl, el);
            enter_insert_mode(v, sl, 0, 1);
            return;
        }
        if (op[0] == 'g' && (op[1] == 'u' || op[1] == 'U' || op[1] == '~')) {
            size_t s_off = 0, s_len = 0, e_off = 0, e_len = 0;
            (void)npl_buf_line_bounds(v->buf, sl, &s_off, &s_len);
            (void)npl_buf_line_bounds(v->buf, el, &e_off, &e_len);
            size_t span = (e_off + e_len) - s_off;
            if (span > 0) {
                char *copy = (char *)malloc(span);
                if (copy) {
                    (void)npl_buf_copy_range(v->buf, s_off, span, copy);
                    apply_case_str(copy, span, op);
                    uint64_t bseq = npl_buf_undo_seq(v->buf);
                    npl_buf_begin_group(v->buf);
                    (void)npl_buf_delete(v->buf, s_off, span);
                    (void)npl_buf_insert(v->buf, s_off, copy, span);
                    npl_buf_end_group(v->buf);
                    if (npl_buf_undo_seq(v->buf) != bseq) {
                        record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, first_nonblank_line(v, sl), 1);
                    }
                    free(copy);
                }
            }
            free(text);
            v->line = sl;
            v->col = first_nonblank_line(v, sl);
            v->curswant = v->col;
            return;
        }
        free(text);
        return;
    }

    /* Characterwise range */
    if (r->empty) {
        if (op[0] == 'c') {
            enter_insert_mode(v, sl, sc, 0);
        }
        return;
    }

    size_t start_off = npl_buf_line_col_to_offset(v->buf, sl, sc);
    size_t end_off   = npl_buf_line_col_to_offset(v->buf, el, ec);
    if (!r->exclusive) {
        size_t total = npl_buf_byte_length(v->buf);
        size_t elen = buf_line_len(v, el);
        if (ec < elen) {
            end_off++;
        } else if (ec == elen && end_off < total) {
            /* Visual mode selection extending onto '\n' */
            end_off++;
        }
    }
    size_t span = (end_off > start_off) ? (end_off - start_off) : 0;

    char *selected = (char *)malloc(span + 1);
    if (!selected) return;
    if (span > 0) {
        (void)npl_buf_copy_range(v->buf, start_off, span, selected);
    }
    selected[span] = '\0';

    if (op[0] == 'y') {
        store_register_yank(v, reg, selected, span, NPL_REG_CHAR);
        free(selected);
        v->line = sl;
        v->col = sc;
        clamp_cursor_normal(v, 1);
        return;
    }

    if (op[0] == 'd' || op[0] == 'c') {
        store_register_delete(v, reg, selected, span, NPL_REG_CHAR);
        free(selected);
        if (op[0] == 'c') {
            v->ins_before_seq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            v->in_insert_group = 1;
            if (span > 0) (void)npl_buf_delete(v->buf, start_off, span);
            enter_insert_mode(v, sl, sc, 0);
        } else {
            uint64_t bseq = npl_buf_undo_seq(v->buf);
            if (span > 0) {
                npl_buf_begin_group(v->buf);
                (void)npl_buf_delete(v->buf, start_off, span);
                npl_buf_end_group(v->buf);
            }
            v->line = sl;
            v->col = sc;
            clamp_cursor_normal(v, 1);
            if (npl_buf_undo_seq(v->buf) != bseq) {
                record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, sc, 0);
            }
        }
        return;
    }

    if (op[0] == 'g' && (op[1] == 'u' || op[1] == 'U' || op[1] == '~')) {
        if (span > 0) {
            apply_case_str(selected, span, op);
            uint64_t bseq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            (void)npl_buf_delete(v->buf, start_off, span);
            (void)npl_buf_insert(v->buf, start_off, selected, span);
            npl_buf_end_group(v->buf);
            if (npl_buf_undo_seq(v->buf) != bseq) {
                record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, sc, 0);
            }
        }
        free(selected);
        v->line = sl;
        v->col = sc;
        clamp_cursor_normal(v, 1);
        return;
    }

    free(selected);
}

static void
apply_operator_vblock(npl_vim_t *v, const char *op, const npl_vim_visual_range_t *vr, char reg)
{
    size_t sl = vr->start_line, el = vr->end_line;
    size_t sc = vr->start_col,  ec = vr->end_col;
    int dollar = v->vblock_dollar;

    if (op[0] == '>' || op[0] == '<') {
        apply_indent_lines(v, sl, el, op[0] == '<', 1);
        v->mode = NPL_VIM_NORMAL;
        return;
    }

    /* Extract block text for yank/delete */
    char *ybuf = NULL;
    size_t ylen = 0, ycap = 0;
    for (size_t l = sl; l <= el; l++) {
        if (l > sl) {
            (void)str_reserve(&ybuf, &ycap, ylen + 2);
            ybuf[ylen++] = '\n';
            ybuf[ylen] = '\0';
        }
        size_t ln = 0;
        char *line = npl_buf_get_line_alloc(v->buf, l, &ln);
        if (line) {
            if (sc < ln) {
                size_t endc = dollar ? (ln - 1) : ((ec < ln) ? ec : (ln - 1));
                if (endc >= sc) {
                    size_t w = endc - sc + 1;
                    if (str_reserve(&ybuf, &ycap, ylen + w + 1)) {
                        memcpy(ybuf + ylen, line + sc, w);
                        ylen += w;
                        ybuf[ylen] = '\0';
                    }
                }
            }
            free(line);
        }
    }
    if (!ybuf) {
        ybuf = (char *)calloc(1, 1);
        ylen = 0;
    }

    if (op[0] == 'y') {
        store_register_yank(v, reg, ybuf, ylen, NPL_REG_BLOCK);
        free(ybuf);
        v->line = sl;
        v->col = sc;
        v->mode = NPL_VIM_NORMAL;
        clamp_cursor_normal(v, 1);
        return;
    }

    if (op[0] == 'd' || op[0] == 'c') {
        store_register_delete(v, reg, ybuf, ylen, NPL_REG_BLOCK);
        free(ybuf);
        if (op[0] == 'c') {
            v->ins_before_seq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            v->in_insert_group = 1;
            /* Delete block on first line now; remaining lines applied on <Esc> */
            size_t ln0 = buf_line_len(v, sl);
            if (sc < ln0) {
                size_t endc = dollar ? (ln0 - 1) : ((ec < ln0) ? ec : (ln0 - 1));
                size_t w = (endc >= sc) ? (endc - sc + 1) : 0;
                if (w > 0) {
                    size_t off = npl_buf_line_col_to_offset(v->buf, sl, sc);
                    (void)npl_buf_delete(v->buf, off, w);
                }
            }
            v->vbi.active     = 1;
            v->vbi.is_append  = 0;
            v->vbi.is_change  = 1;
            v->vbi.dollar     = dollar;
            v->vbi.start_line = sl;
            v->vbi.end_line   = el;
            v->vbi.start_col  = sc;
            v->vbi.end_col    = ec;
            v->vbi.text_len   = 0;
            if (v->vbi.text) v->vbi.text[0] = '\0';
            enter_insert_mode(v, sl, sc, 0);
            return;
        }
        uint64_t bseq = npl_buf_undo_seq(v->buf);
        npl_buf_begin_group(v->buf);
        for (size_t i = el + 1; i > sl; i--) {
            size_t l = i - 1;
            size_t ln = buf_line_len(v, l);
            if (sc >= ln) continue;
            size_t endc = dollar ? (ln - 1) : ((ec < ln) ? ec : (ln - 1));
            if (endc >= sc) {
                size_t w = endc - sc + 1;
                size_t off = npl_buf_line_col_to_offset(v->buf, l, sc);
                (void)npl_buf_delete(v->buf, off, w);
            }
        }
        npl_buf_end_group(v->buf);
        if (npl_buf_undo_seq(v->buf) != bseq) {
            record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, sc, 0);
        }
        v->line = sl;
        v->col = sc;
        v->mode = NPL_VIM_NORMAL;
        clamp_cursor_normal(v, 1);
        return;
    }

    if (op[0] == 'g' && (op[1] == 'u' || op[1] == 'U' || op[1] == '~')) {
        free(ybuf);
        uint64_t bseq = npl_buf_undo_seq(v->buf);
        npl_buf_begin_group(v->buf);
        for (size_t l = sl; l <= el; l++) {
            size_t ln = 0;
            char *line = npl_buf_get_line_alloc(v->buf, l, &ln);
            if (!line) continue;
            if (sc < ln) {
                size_t endc = dollar ? (ln - 1) : ((ec < ln) ? ec : (ln - 1));
                if (endc >= sc) {
                    size_t w = endc - sc + 1;
                    apply_case_str(line + sc, w, op);
                    size_t off = npl_buf_line_col_to_offset(v->buf, l, sc);
                    (void)npl_buf_delete(v->buf, off, w);
                    (void)npl_buf_insert(v->buf, off, line + sc, w);
                }
            }
            free(line);
        }
        npl_buf_end_group(v->buf);
        if (npl_buf_undo_seq(v->buf) != bseq) {
            record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, sc, 0);
        }
        v->line = sl;
        v->col = sc;
        v->mode = NPL_VIM_NORMAL;
        clamp_cursor_normal(v, 1);
        return;
    }

    free(ybuf);
    v->mode = NPL_VIM_NORMAL;
}

static void
apply_operator_visual(npl_vim_t *v, const char *op)
{
    npl_vim_visual_range_t vr;
    compute_visual_range(v, &vr);
    if (!vr.active) return;

    char reg = v->reg;
    v->last_visual = vr;
    size_t dlines = vr.end_line - vr.start_line;
    size_t dcols  = (vr.end_col >= vr.start_col) ? (vr.end_col - vr.start_col) : 0;

    if (op[0] != 'y') {
        dot_save_visual(v, vr.mode, dlines, dcols, op);
    }

    reset_grammar(v);

    if (vr.mode == NPL_VIM_VBLOCK) {
        apply_operator_vblock(v, op, &vr, reg);
        v->vblock_dollar = 0;
        return;
    }

    npl_range_t range;
    memset(&range, 0, sizeof(range));
    range.start_line = vr.start_line;
    range.start_col  = vr.start_col;
    range.end_line   = vr.end_line;
    range.end_col    = vr.end_col;
    range.linewise   = (vr.mode == NPL_VIM_VLINE) ? 1 : 0;
    range.exclusive  = 0;

    v->mode = NPL_VIM_NORMAL;
    apply_operator_range(v, op, &range, reg);
}

/* --- Put / Paste --- */

static void
put_register(npl_vim_t *v, char reg_name, int after, int cnt)
{
    const npl_vim_reg_t *r = lookup_register(v, reg_name);
    if (!r || r->len == 0 || !r->text) return;

    /* Copy register text because mutations or self-referential ops shouldn't alias */
    size_t tlen = r->len;
    npl_reg_type_t rtype = r->type;
    char *text = (char *)malloc(tlen + 1);
    if (!text) return;
    memcpy(text, r->text, tlen);
    text[tlen] = '\0';

    if (cnt < 1) cnt = 1;
    uint64_t bseq = npl_buf_undo_seq(v->buf);
    npl_buf_begin_group(v->buf);

    if (rtype == NPL_REG_LINE) {
        size_t body_len = tlen;
        if (body_len > 0 && text[body_len - 1] == '\n') body_len--;

        /* Repeat body cnt times joined by '\n' */
        size_t total_rep = body_len * (size_t)cnt + (size_t)(cnt - 1);
        char *rep = (char *)malloc(total_rep + 2);
        if (rep) {
            size_t pos = 0;
            for (int i = 0; i < cnt; i++) {
                if (i > 0) rep[pos++] = '\n';
                if (body_len > 0) {
                    memcpy(rep + pos, text, body_len);
                    pos += body_len;
                }
            }
            rep[pos] = '\0';

            if (after) {
                size_t lst = 0, llen = 0;
                (void)npl_buf_line_bounds(v->buf, v->line, &lst, &llen);
                size_t ins_off = lst + llen;
                (void)npl_buf_insert(v->buf, ins_off, "\n", 1);
                if (pos > 0) (void)npl_buf_insert(v->buf, ins_off + 1, rep, pos);
                v->line = v->line + 1;
            } else {
                size_t lst = 0, llen = 0;
                (void)npl_buf_line_bounds(v->buf, v->line, &lst, &llen);
                if (pos > 0) (void)npl_buf_insert(v->buf, lst, rep, pos);
                (void)npl_buf_insert(v->buf, lst + pos, "\n", 1);
            }
            v->col = first_nonblank_line(v, v->line);
            v->curswant = v->col;
            free(rep);
        }
        npl_buf_end_group(v->buf);
        if (npl_buf_undo_seq(v->buf) != bseq) {
            record_undo_cursor(v, npl_buf_undo_seq(v->buf), v->line, v->col, 1);
        }
        free(text);
        return;
    }

    if (rtype == NPL_REG_BLOCK) {
        size_t ln0 = buf_line_len(v, v->line);
        size_t tc = (after && ln0 > 0) ? (v->col + 1) : v->col;
        size_t cur_l = v->line;
        size_t idx = 0;
        for (;;) {
            const char *seg = text + idx;
            const char *nl = (const char *)memchr(seg, '\n', tlen - idx);
            size_t slen = nl ? (size_t)(nl - seg) : (tlen - idx);

            while (cur_l >= buf_nlines(v)) {
                size_t end_off = npl_buf_byte_length(v->buf);
                (void)npl_buf_insert(v->buf, end_off, "\n", 1);
            }
            size_t ln = buf_line_len(v, cur_l);
            if (ln < tc) {
                size_t pad_n = tc - ln;
                char *pad = (char *)malloc(pad_n);
                if (pad) {
                    memset(pad, ' ', pad_n);
                    size_t off = npl_buf_line_col_to_offset(v->buf, cur_l, ln);
                    (void)npl_buf_insert(v->buf, off, pad, pad_n);
                    free(pad);
                }
            }
            size_t ins_off = npl_buf_line_col_to_offset(v->buf, cur_l, tc);
            for (int k = 0; k < cnt; k++) {
                if (slen > 0) {
                    (void)npl_buf_insert(v->buf, ins_off + (size_t)k * slen, seg, slen);
                }
            }

            if (!nl) break;
            idx = (size_t)((nl - text) + 1);
            cur_l++;
        }
        npl_buf_end_group(v->buf);
        v->col = tc;
        clamp_cursor_normal(v, 1);
        if (npl_buf_undo_seq(v->buf) != bseq) {
            record_undo_cursor(v, npl_buf_undo_seq(v->buf), v->line, v->col, 0);
        }
        free(text);
        return;
    }

    /* Characterwise put */
    size_t ln = buf_line_len(v, v->line);
    size_t ic = (after && ln > 0) ? (v->col + 1) : v->col;
    if (ic > ln) ic = ln;

    size_t rlen = tlen * (size_t)cnt;
    char *rep = (char *)malloc(rlen + 1);
    if (rep) {
        for (int i = 0; i < cnt; i++) {
            memcpy(rep + (size_t)i * tlen, text, tlen);
        }
        rep[rlen] = '\0';
        size_t off = npl_buf_line_col_to_offset(v->buf, v->line, ic);
        (void)npl_buf_insert(v->buf, off, rep, rlen);

        if (memchr(rep, '\n', rlen) != NULL) {
            /* Multiline charwise paste: Vim lands cursor on FIRST pasted char */
            v->col = ic;
        } else {
            /* Single-line charwise paste: Vim lands cursor on LAST pasted char */
            v->col = (rlen > 0) ? (ic + rlen - 1) : ic;
        }
        free(rep);
    }
    npl_buf_end_group(v->buf);
    clamp_cursor_normal(v, 1);
    if (npl_buf_undo_seq(v->buf) != bseq) {
        record_undo_cursor(v, npl_buf_undo_seq(v->buf), v->line, ic, 0);
    }
    free(text);
}

/* --- Join Lines (J / gJ) --- */

static void
join_lines(npl_vim_t *v, int cnt, int add_space)
{
    /* Vim: J / 1J / 2J join 2 lines (1 join); 3J joins 3 lines (2 joins) */
    int joins = (cnt > 2) ? (cnt - 1) : 1;
    size_t l = v->line;
    if (l + 1 >= buf_nlines(v)) return;

    uint64_t bseq = npl_buf_undo_seq(v->buf);
    size_t land_col = v->col;
    npl_buf_begin_group(v->buf);
    for (int j = 0; j < joins; j++) {
        if (l + 1 >= buf_nlines(v)) break;
        size_t la = 0, lb = 0;
        char *a = npl_buf_get_line_alloc(v->buf, l, &la);
        char *b = npl_buf_get_line_alloc(v->buf, l + 1, &lb);
        if (!a || !b) { free(a); free(b); break; }

        size_t b_skip = 0;
        int need_sp = 0;
        if (add_space) {
            while (b_skip < lb && ch_is_space((uint8_t)b[b_skip])) b_skip++;
            size_t b_rem = lb - b_skip;
            if (la > 0 && b_rem > 0 && !ch_is_space((uint8_t)a[la - 1]) && b[b_skip] != ')') {
                need_sp = 1;
            }
        }
        size_t a_off = 0, a_len = 0;
        (void)npl_buf_line_bounds(v->buf, l, &a_off, &a_len);
        size_t b_off = 0, b_len = 0;
        (void)npl_buf_line_bounds(v->buf, l + 1, &b_off, &b_len);

        /* Delete from end of line l through b_skip on line l+1 (includes '\n') */
        size_t del_start = a_off + a_len;
        size_t del_end   = b_off + b_skip;
        if (del_end > del_start) {
            (void)npl_buf_delete(v->buf, del_start, del_end - del_start);
        }
        if (need_sp) {
            int two_sp = (la > 0 && (a[la - 1] == '.' || a[la - 1] == '?' || a[la - 1] == '!'));
            (void)npl_buf_insert(v->buf, del_start, two_sp ? "  " : " ", two_sp ? 2u : 1u);
            land_col = la;
        } else {
            size_t b_rem = lb - b_skip;
            if (b_rem == 0) {
                land_col = (la > 0) ? (la - 1) : 0;
            } else {
                land_col = la;
            }
        }
        free(a);
        free(b);
    }
    npl_buf_end_group(v->buf);
    v->line = l;
    v->col = land_col;
    clamp_cursor_normal(v, 1);
    if (npl_buf_undo_seq(v->buf) != bseq) {
        record_undo_cursor(v, npl_buf_undo_seq(v->buf), l, land_col, 0);
    }
}

/* --- Key Dispatch Forward Declaration --- */

static void dispatch_key(npl_vim_t *v, uint32_t key);

/* --- Insert & Replace Mode Handlers --- */

static void
finish_insert_or_replace(npl_vim_t *v)
{
    dot_push(v, NPL_K_ESC);

    if (v->vbi.active) {
        int was_append = v->vbi.is_append;
        int was_change = v->vbi.is_change;
        int dollar     = v->vbi.dollar;
        size_t sl      = v->vbi.start_line;
        size_t el      = v->vbi.end_line;
        size_t sc      = v->vbi.start_col;
        size_t ec      = v->vbi.end_col;
        size_t tlen    = v->vbi.text_len;
        const char *tx = v->vbi.text ? v->vbi.text : "";

        for (size_t l = sl + 1; l <= el && l < buf_nlines(v); l++) {
            size_t ln = buf_line_len(v, l);
            if (was_change) {
                if (sc < ln) {
                    size_t endc = dollar ? (ln - 1) : ((ec < ln) ? ec : (ln - 1));
                    size_t w = (endc >= sc) ? (endc - sc + 1) : 0;
                    size_t off = npl_buf_line_col_to_offset(v->buf, l, sc);
                    if (w > 0) (void)npl_buf_delete(v->buf, off, w);
                    if (tlen > 0) (void)npl_buf_insert(v->buf, off, tx, tlen);
                }
            } else if (was_append) {
                if (dollar) {
                    if (tlen > 0) {
                        size_t off = npl_buf_line_col_to_offset(v->buf, l, ln);
                        (void)npl_buf_insert(v->buf, off, tx, tlen);
                    }
                } else {
                    size_t target = ec + 1;
                    if (tlen > 0) {
                        if (ln < target) {
                            size_t pad_n = target - ln;
                            char *pad = (char *)malloc(pad_n);
                            if (pad) {
                                memset(pad, ' ', pad_n);
                                size_t off = npl_buf_line_col_to_offset(v->buf, l, ln);
                                (void)npl_buf_insert(v->buf, off, pad, pad_n);
                                free(pad);
                            }
                        }
                        size_t off = npl_buf_line_col_to_offset(v->buf, l, target);
                        (void)npl_buf_insert(v->buf, off, tx, tlen);
                    }
                }
            } else {
                /* VBLOCK I: skip lines shorter than sc */
                if (ln >= sc && tlen > 0) {
                    size_t off = npl_buf_line_col_to_offset(v->buf, l, sc);
                    (void)npl_buf_insert(v->buf, off, tx, tlen);
                }
            }
        }

        v->vbi.active = 0;
        v->vbi.text_len = 0;

        if (v->in_insert_group) {
            npl_buf_end_group(v->buf);
            v->in_insert_group = 0;
            if (npl_buf_undo_seq(v->buf) != v->ins_before_seq) {
                record_undo_cursor(v, npl_buf_undo_seq(v->buf), sl, sc, 0);
            }
        }
        dot_finish(v);
        v->mode = NPL_VIM_NORMAL;
        if (was_change) {
            v->line = sl;
            v->col = (v->col > 0) ? (v->col - 1) : 0;
        } else {
            /* Vim VBLOCK I / A lands cursor at (start_line, start_col) */
            v->line = sl;
            v->col = sc;
        }
        clamp_cursor_normal(v, 1);
        return;
    }

    if (v->in_insert_group) {
        npl_buf_end_group(v->buf);
        v->in_insert_group = 0;
        if (npl_buf_undo_seq(v->buf) != v->ins_before_seq) {
            record_undo_cursor(v, npl_buf_undo_seq(v->buf),
                               v->ins_start_line, v->ins_start_col, v->ins_linewise);
        }
    }
    dot_finish(v);
    v->rep_len = 0;
    v->mode = NPL_VIM_NORMAL;
    if (v->col > 0) v->col--;
    clamp_cursor_normal(v, 1);
}

static void
handle_insert_key(npl_vim_t *v, uint32_t key)
{
    if (key == NPL_K_ESC || key == NPL_K_CTRL_LBRACKET || key == NPL_K_CTRL('c')) {
        finish_insert_or_replace(v);
        return;
    }

    if (key == NPL_K_CR) {
        size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
        (void)npl_buf_insert(v->buf, off, "\n", 1);
        v->line++;
        v->col = 0;
        v->curswant = 0;
        dot_push(v, NPL_K_CR);
        return;
    }

    if (key == NPL_K_TAB) {
        if (v->expandtab) {
            int ts = (v->tabstop > 0) ? v->tabstop : 4;
            int spaces = ts - (int)(v->col % (size_t)ts);
            char pad[64];
            if (spaces > 64) spaces = 64;
            memset(pad, ' ', (size_t)spaces);
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
            (void)npl_buf_insert(v->buf, off, pad, (size_t)spaces);
            v->col += (size_t)spaces;
            if (v->vbi.active && str_reserve(&v->vbi.text, &v->vbi.text_cap, v->vbi.text_len + (size_t)spaces + 1)) {
                memcpy(v->vbi.text + v->vbi.text_len, pad, (size_t)spaces);
                v->vbi.text_len += (size_t)spaces;
                v->vbi.text[v->vbi.text_len] = '\0';
            }
        } else {
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
            (void)npl_buf_insert(v->buf, off, "\t", 1);
            v->col++;
            if (v->vbi.active && str_reserve(&v->vbi.text, &v->vbi.text_cap, v->vbi.text_len + 2)) {
                v->vbi.text[v->vbi.text_len++] = '\t';
                v->vbi.text[v->vbi.text_len] = '\0';
            }
        }
        v->curswant = v->col;
        dot_push(v, NPL_K_TAB);
        return;
    }

    if (key == NPL_K_BS) {
        if (v->col > 0) {
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col - 1);
            (void)npl_buf_delete(v->buf, off, 1);
            v->col--;
            if (v->vbi.active && v->vbi.text_len > 0) {
                v->vbi.text[--v->vbi.text_len] = '\0';
            }
        } else if (v->line > 0) {
            size_t prev_len = buf_line_len(v, v->line - 1);
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line - 1, prev_len);
            (void)npl_buf_delete(v->buf, off, 1);
            v->line--;
            v->col = prev_len;
        }
        v->curswant = v->col;
        dot_push(v, NPL_K_BS);
        return;
    }

    if (key == NPL_K_DEL) {
        size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
        if (off < npl_buf_byte_length(v->buf)) {
            (void)npl_buf_delete(v->buf, off, 1);
            dot_push(v, NPL_K_DEL);
        }
        return;
    }

    if (key == NPL_K_LEFT)  { if (v->col > 0) v->col--; v->curswant = v->col; return; }
    if (key == NPL_K_RIGHT) { size_t ln = buf_line_len(v, v->line); if (v->col < ln) v->col++; v->curswant = v->col; return; }
    if (key == NPL_K_UP)    { if (v->line > 0) v->line--; clamp_cursor_insert(v); return; }
    if (key == NPL_K_DOWN)  { if (v->line + 1 < buf_nlines(v)) v->line++; clamp_cursor_insert(v); return; }

    if (key >= 0x20u && key < 0x100u && key != 0x7Fu) {
        char ch = (char)(uint8_t)key;
        size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
        (void)npl_buf_insert(v->buf, off, &ch, 1);
        v->col++;
        v->curswant = v->col;
        if (v->vbi.active && str_reserve(&v->vbi.text, &v->vbi.text_cap, v->vbi.text_len + 2)) {
            v->vbi.text[v->vbi.text_len++] = ch;
            v->vbi.text[v->vbi.text_len] = '\0';
        }
        dot_push(v, key);
    }
}

static void
handle_replace_key(npl_vim_t *v, uint32_t key)
{
    if (key == NPL_K_ESC || key == NPL_K_CTRL_LBRACKET || key == NPL_K_CTRL('c')) {
        finish_insert_or_replace(v);
        return;
    }

    if (key == NPL_K_BS) {
        if (v->rep_len > 0 && v->col > 0) {
            npl_rep_entry_t ent = v->rep_stack[--v->rep_len];
            v->col--;
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
            (void)npl_buf_delete(v->buf, off, 1);
            if (ent.had_orig) {
                (void)npl_buf_insert(v->buf, off, &ent.orig_ch, 1);
            }
            v->curswant = v->col;
        } else if (v->col > 0) {
            v->col--;
            v->curswant = v->col;
        }
        dot_push(v, NPL_K_BS);
        return;
    }

    if (key == NPL_K_CR) {
        size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
        (void)npl_buf_insert(v->buf, off, "\n", 1);
        v->line++;
        v->col = 0;
        v->curswant = 0;
        v->rep_len = 0;
        dot_push(v, NPL_K_CR);
        return;
    }

    if (key >= 0x20u && key < 0x100u && key != 0x7Fu) {
        char ch = (char)(uint8_t)key;
        size_t ln = 0;
        char *line = npl_buf_get_line_alloc(v->buf, v->line, &ln);
        npl_rep_entry_t ent;
        ent.had_orig = 0;
        ent.orig_ch = '\0';
        size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
        if (line && v->col < ln) {
            ent.had_orig = 1;
            ent.orig_ch = line[v->col];
            (void)npl_buf_delete(v->buf, off, 1);
        }
        free(line);
        (void)npl_buf_insert(v->buf, off, &ch, 1);
        if (v->rep_len >= v->rep_cap) {
            size_t ncap = v->rep_cap ? v->rep_cap * 2 : 32;
            npl_rep_entry_t *nr = (npl_rep_entry_t *)realloc(v->rep_stack, ncap * sizeof(npl_rep_entry_t));
            if (nr) {
                v->rep_stack = nr;
                v->rep_cap = ncap;
            }
        }
        if (v->rep_len < v->rep_cap) {
            v->rep_stack[v->rep_len++] = ent;
        }
        v->col++;
        v->curswant = v->col;
        dot_push(v, key);
    }
}

/* --- Motion Completion (Normal / Visual / Operator) --- */

static void
finish_motion_to(npl_vim_t *v, size_t nl, size_t nc,
                 int linewise, int inclusive, int keep_want,
                 int is_word_motion, int is_para_motion,
                 const uint32_t *dot_motion_keys, size_t dot_motion_n)
{
    if (v->op[0] != '\0') {
        char op[4];
        memcpy(op, v->op, sizeof(op));
        char reg = v->reg;
        int c1 = v->has_count1 ? v->count1 : 0;
        int c2 = v->has_count2 ? v->count2 : 0;

        size_t sl = v->line, sc = v->col;
        size_t el = nl,      ec = nc;
        int backward = (el < sl || (el == sl && ec < sc));
        if (backward) {
            size_t tl = sl, tc = sc;
            sl = el; sc = ec;
            el = tl; ec = tc;
        }

        int eff_linewise = linewise;
        int eff_exclusive = (linewise || inclusive) ? 0 : 1;

        /* Vim inclusive-linewise promotion for multiline % spanning full lines */
        if (!eff_linewise && inclusive && el > sl && sc == 0 &&
            dot_motion_keys && dot_motion_n == 1 && dot_motion_keys[0] == '%')
        {
            size_t el_ln = buf_line_len(v, el);
            if (el_ln == 0 || ec + 1 >= el_ln) {
                eff_linewise = 1;
                eff_exclusive = 0;
            }
        }

        /* Vim exclusive motion line-boundary rules (:help exclusive, :help exclusive-linewise) */
        if (eff_exclusive && el > sl && !backward) {
            size_t el_ln = 0;
            char *el_txt = npl_buf_get_line_alloc(v->buf, el, &el_ln);
            int only_ws_before = 1;
            if (el_txt) {
                for (size_t k = 0; k < ec && k < el_ln; k++) {
                    if (!ch_is_space((uint8_t)el_txt[k])) {
                        only_ws_before = 0;
                        break;
                    }
                }
                free(el_txt);
            }

            if (is_para_motion && sc == 0 && ec == 0) {
                /* d} from col 0 to blank line col 0 -> linewise sl..el-1 */
                eff_linewise = 1;
                eff_exclusive = 0;
                el = el - 1;
                ec = buf_line_len(v, el);
            } else if (only_ws_before && (is_word_motion || ec == 0)) {
                /* If start line was empty and we stepped onto next line col 0, delete the '\n'.
                 * Otherwise back up exclusive end to EOL of el-1 so lines are not joined. */
                if (!(sl + 1 == el && sc == 0 && ec == 0 && buf_line_len(v, sl) == 0)) {
                    el = el - 1;
                    ec = buf_line_len(v, el);
                }
            }
        } else if (eff_exclusive && el > sl && backward) {
            /* Backward exclusive motion (e.g. d{): if starting at col 0 and ending at col 0 */
            if (is_para_motion && sc == 0 && ec == 0) {
                eff_linewise = 1;
                eff_exclusive = 0;
                el = el - 1;
                ec = buf_line_len(v, el);
            }
        }

        if (op[0] != 'y' && dot_motion_keys && dot_motion_n > 0) {
            dot_start(v);
            if (c1 > 0) dot_push_count(v, c1);
            for (size_t i = 0; op[i] != '\0'; i++) dot_push(v, (uint32_t)(uint8_t)op[i]);
            if (c2 > 0) dot_push_count(v, c2);
            for (size_t i = 0; i < dot_motion_n; i++) dot_push(v, dot_motion_keys[i]);
        }

        reset_grammar(v);

        npl_range_t range;
        memset(&range, 0, sizeof(range));
        range.start_line = sl;
        range.start_col  = sc;
        range.end_line   = el;
        range.end_col    = ec;
        range.linewise   = eff_linewise;
        range.exclusive  = eff_exclusive;

        apply_operator_range(v, op, &range, reg);
        if (op[0] != 'c' && op[0] != 'y') {
            dot_finish(v);
        }
        return;
    }

    size_t n = buf_nlines(v);
    if (nl >= n) nl = n - 1;
    v->line = nl;
    v->col = nc;

    if (is_visual_mode(v->mode)) {
        if (keep_want) {
            apply_curswant(v);
        } else {
            clamp_cursor_visual(v, 1);
            if (v->mode == NPL_VIM_VBLOCK) v->vblock_dollar = 0;
        }
    } else {
        if (keep_want) {
            apply_curswant(v);
        } else {
            clamp_cursor_normal(v, 1);
        }
    }
    reset_grammar(v);
}

/* --- Dot-Repeat Replay --- */

static void
replay_dot(npl_vim_t *v, int has_override, int override_cnt)
{
    if (v->dot_saved_visual) {
        npl_vim_visual_range_t vr;
        size_t n = buf_nlines(v);
        vr.active = 1;
        vr.mode = v->dot_vis_mode;
        vr.start_line = v->line;
        vr.start_col  = v->col;
        size_t dlines = has_override ? (size_t)(override_cnt > 0 ? override_cnt - 1 : 0) : v->dot_vis_dlines;
        vr.end_line = (vr.start_line + dlines < n) ? (vr.start_line + dlines) : (n - 1);
        vr.end_col  = vr.start_col + v->dot_vis_dcols;

        v->dot_replaying = 1;
        if (vr.mode == NPL_VIM_VBLOCK) {
            apply_operator_vblock(v, v->dot_vis_op, &vr, v->reg);
        } else {
            npl_range_t r;
            memset(&r, 0, sizeof(r));
            r.start_line = vr.start_line;
            r.start_col  = vr.start_col;
            r.end_line   = vr.end_line;
            r.end_col    = vr.end_col;
            r.linewise   = (vr.mode == NPL_VIM_VLINE) ? 1 : 0;
            apply_operator_range(v, v->dot_vis_op, &r, v->reg);
        }
        v->dot_replaying = 0;
        return;
    }

    if (!v->dot_saved || v->dot_saved_len == 0) return;

    /* Copy saved sequence in case replay touches anything */
    size_t slen = v->dot_saved_len;
    uint32_t *seq = (uint32_t *)malloc(slen * sizeof(uint32_t));
    if (!seq) return;
    memcpy(seq, v->dot_saved, slen * sizeof(uint32_t));

    size_t start_idx = 0;
    if (has_override && override_cnt > 0) {
        while (start_idx < slen && seq[start_idx] >= '0' && seq[start_idx] <= '9') {
            start_idx++;
        }
    }

    v->dot_replaying = 1;
    if (has_override && override_cnt > 0) {
        char tmp[32];
        int n = 0;
        int x = override_cnt;
        while (x > 0 && n < 30) {
            tmp[n++] = (char)('0' + (x % 10));
            x /= 10;
        }
        for (int i = n - 1; i >= 0; i--) {
            dispatch_key(v, (uint32_t)(uint8_t)tmp[i]);
        }
    }
    for (size_t i = start_idx; i < slen; i++) {
        dispatch_key(v, seq[i]);
    }
    v->dot_replaying = 0;
    free(seq);
}

/* --- Prefix Second-Key Handler --- */

static void
handle_prefix_key(npl_vim_t *v, char pref, uint32_t key)
{
    v->pending_prefix = '\0';

    if (key == NPL_K_ESC || key == NPL_K_CTRL_LBRACKET || key == NPL_K_CTRL('c')) {
        reset_grammar(v);
        return;
    }

    int is_vis = is_visual_mode(v->mode);
    int cnt = effective_count(v, 1);
    int has_cnt = has_any_count(v);
    char reg = v->reg;

    /* Text objects: i{obj} / a{obj} */
    if (pref == 'i' || pref == 'a') {
        if (key >= 0x100u) { reset_grammar(v); return; }
        char kind = (char)(uint8_t)key;
        npl_range_t range;
        if (!resolve_text_object(v, pref == 'i', kind, cnt, &range)) {
            reset_grammar(v);
            return;
        }
        if (is_vis) {
            v->vis_anchor_line = range.start_line;
            v->vis_anchor_col  = range.start_col;
            v->line = range.end_line;
            v->col  = range.end_col;
            if (range.linewise) v->mode = NPL_VIM_VLINE;
            clamp_cursor_visual(v, 1);
            v->count1 = 0; v->has_count1 = 0;
            v->count2 = 0; v->has_count2 = 0;
            return;
        }
        if (v->op[0] != '\0') {
            char op[4];
            memcpy(op, v->op, sizeof(op));
            int c1 = v->has_count1 ? v->count1 : 0;
            int c2 = v->has_count2 ? v->count2 : 0;
            if (op[0] != 'y') {
                dot_start(v);
                if (c1 > 0) dot_push_count(v, c1);
                for (size_t i = 0; op[i] != '\0'; i++) dot_push(v, (uint32_t)(uint8_t)op[i]);
                if (c2 > 0) dot_push_count(v, c2);
                dot_push(v, (uint32_t)(uint8_t)pref);
                dot_push(v, key);
            }
            reset_grammar(v);
            apply_operator_range(v, op, &range, reg);
            if (op[0] != 'c' && op[0] != 'y') {
                dot_finish(v);
            }
            return;
        }
        reset_grammar(v);
        return;
    }

    /* Char find: f / F / t / T */
    if (pref == 'f' || pref == 'F' || pref == 't' || pref == 'T') {
        if (key >= 0x100u) { reset_grammar(v); return; }
        char ch = (char)(uint8_t)key;
        v->last_find_kind = pref;
        v->last_find_char = ch;
        size_t target_col = 0;
        if (!motion_char_find(v, v->line, v->col, pref, ch, cnt, 0, &target_col)) {
            reset_grammar(v);
            return;
        }
        int incl = (pref == 'f' || pref == 't') ? 1 : 0;
        uint32_t dkeys[2] = { (uint32_t)(uint8_t)pref, key };
        finish_motion_to(v, v->line, target_col, 0, incl, 0, 0, 0, dkeys, 2);
        return;
    }

    /* Single-char replace: r{ch} */
    if (pref == 'r') {
        reset_grammar(v);
        char ch = '\0';
        if (key == NPL_K_CR) ch = '\n';
        else if (key >= 0x20u && key < 0x100u && key != 0x7Fu) ch = (char)(uint8_t)key;
        else return;

        size_t ln = buf_line_len(v, v->line);
        if (ln == 0 || v->col + (size_t)cnt > ln) return;

        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, 'r');
        dot_push(v, key);

        size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
        uint64_t bseq = npl_buf_undo_seq(v->buf);
        npl_buf_begin_group(v->buf);
        (void)npl_buf_delete(v->buf, off, (size_t)cnt);
        if (ch == '\n') {
            (void)npl_buf_insert(v->buf, off, "\n", 1);
            v->line++;
            v->col = first_nonblank_line(v, v->line);
        } else {
            char *rep = (char *)malloc((size_t)cnt);
            if (rep) {
                memset(rep, ch, (size_t)cnt);
                (void)npl_buf_insert(v->buf, off, rep, (size_t)cnt);
                free(rep);
            }
            v->col = v->col + (size_t)cnt - 1;
        }
        npl_buf_end_group(v->buf);
        clamp_cursor_normal(v, 1);
        if (npl_buf_undo_seq(v->buf) != bseq) {
            record_undo_cursor(v, npl_buf_undo_seq(v->buf), v->line, v->col, 0);
        }
        dot_finish(v);
        return;
    }

    /* Set mark: m{a-z} */
    if (pref == 'm') {
        reset_grammar(v);
        if (key < 0x100u) {
            (void)npl_vim_set_mark(v, (char)(uint8_t)key, v->line, v->col);
        }
        return;
    }

    /* Jump to mark: '{m} or `{m} */
    if (pref == '\'' || pref == '`') {
        if (key >= 0x100u) { reset_grammar(v); return; }
        size_t ml = 0, mc = 0;
        if (!npl_vim_get_mark(v, (char)(uint8_t)key, &ml, &mc)) {
            reset_grammar(v);
            return;
        }
        v->mark_prev.set = 1;
        v->mark_prev.line = v->line;
        v->mark_prev.col = v->col;
        size_t n = buf_nlines(v);
        if (ml >= n) ml = n - 1;
        size_t tc = (pref == '`') ? mc : first_nonblank_line(v, ml);
        uint32_t dkeys[2] = { (uint32_t)(uint8_t)pref, key };
        finish_motion_to(v, ml, tc, pref == '\'', 0, 0, 0, 0, dkeys, 2);
        return;
    }

    /* Start macro recording: q{a-zA-Z} */
    if (pref == 'q') {
        reset_grammar(v);
        if (key < 0x100u) {
            uint8_t c = (uint8_t)key;
            if (ch_is_lower(c) || ch_is_upper(c)) {
                v->recording  = 1;
                v->rec_reg    = ch_is_upper(c) ? (int)(c - 'A') : (int)(c - 'a');
                v->rec_append = ch_is_upper(c) ? 1 : 0;
                v->rec_len    = 0;
                if (v->rec_buf) v->rec_buf[0] = '\0';
            }
        }
        return;
    }

    /* Execute macro: @{a-z|@} */
    if (pref == '@') {
        reset_grammar(v);
        if (v->macro_depth >= NPL_MAX_MACRO_DEPTH) return;
        int mreg = -1;
        if (key == '@') {
            mreg = v->last_macro_reg;
        } else if (key < 0x100u && (ch_is_lower((uint8_t)key) || ch_is_upper((uint8_t)key))) {
            mreg = (int)(ch_to_lower((uint8_t)key) - 'a');
        }
        if (mreg < 0 || mreg >= 26) return;
        const npl_vim_reg_t *r = &v->reg_alpha[mreg];
        if (!r->text || r->len == 0) return;

        v->last_macro_reg = mreg;
        char *copy = (char *)malloc(r->len + 1);
        if (!copy) return;
        memcpy(copy, r->text, r->len);
        copy[r->len] = '\0';
        size_t clen = r->len;

        v->macro_depth++;
        for (int i = 0; i < cnt; i++) {
            (void)npl_vim_feed_keys(v, copy, clen);
        }
        v->macro_depth--;
        free(copy);
        return;
    }

    /* g-prefix commands: gg, g_, ge, gE, gu, gU, g~, gJ, gv, g-, g+ */
    if (pref == 'g') {
        if (key == 'g') {
            size_t n = buf_nlines(v);
            size_t target = has_cnt ? (size_t)(cnt - 1) : 0;
            if (target >= n) target = n - 1;
            size_t tc = first_nonblank_line(v, target);
            uint32_t dkeys[2] = { 'g', 'g' };
            finish_motion_to(v, target, tc, 1, 1, 0, 0, 0, dkeys, 2);
            return;
        }
        if (key == '_') {
            size_t n = buf_nlines(v);
            size_t nl = v->line + (size_t)(cnt - 1);
            if (nl >= n) nl = n - 1;
            size_t ln = 0;
            char *line = npl_buf_get_line_alloc(v->buf, nl, &ln);
            size_t nc = 0;
            if (line && ln > 0) {
                size_t p = ln;
                while (p > 0 && ch_is_space((uint8_t)line[p - 1])) p--;
                nc = (p > 0) ? (p - 1) : 0;
            }
            free(line);
            uint32_t dkeys[2] = { 'g', '_' };
            finish_motion_to(v, nl, nc, 0, 1, 0, 0, 0, dkeys, 2);
            return;
        }
        if (key == 'e' || key == 'E') {
            size_t nl = v->line, nc = v->col;
            motion_word_end_backward(v, v->line, v->col, cnt, key == 'E', &nl, &nc);
            uint32_t dkeys[2] = { 'g', key };
            finish_motion_to(v, nl, nc, 0, 1, 0, 0, 0, dkeys, 2);
            return;
        }
        if (key == 'u' || key == 'U' || key == '~') {
            char gop[4] = { 'g', (char)(uint8_t)key, '\0', '\0' };
            if (is_vis) {
                apply_operator_visual(v, gop);
                return;
            }
            if (v->op[0] == 'g' && v->op[1] == (char)(uint8_t)key) {
                /* gugu / gUgU / g~g~ -> linewise */
                int c = effective_count(v, 1);
                int hc = has_any_count(v);
                size_t n = buf_nlines(v);
                size_t el = v->line + (size_t)(c - 1);
                if (el >= n) el = n - 1;
                dot_start(v);
                if (hc) dot_push_count(v, c);
                dot_push(v, 'g'); dot_push(v, key); dot_push(v, key);
                reset_grammar(v);
                npl_range_t r;
                memset(&r, 0, sizeof(r));
                r.start_line = v->line; r.start_col = 0;
                r.end_line   = el;      r.end_col   = buf_line_len(v, el);
                r.linewise   = 1;
                apply_operator_range(v, gop, &r, reg);
                dot_finish(v);
                return;
            }
            if (v->op[0] != '\0') {
                reset_grammar(v);
                return;
            }
            memcpy(v->op, gop, sizeof(gop));
            v->mode = NPL_VIM_OPERATOR;
            return;
        }
        if (key == 'J') {
            dot_start(v);
            if (has_cnt) dot_push_count(v, cnt);
            dot_push(v, 'g'); dot_push(v, 'J');
            reset_grammar(v);
            join_lines(v, cnt, 0);
            dot_finish(v);
            return;
        }
        if (key == 'v') {
            reset_grammar(v);
            if (v->last_visual.active) {
                v->vis_anchor_line = v->last_visual.start_line;
                v->vis_anchor_col  = v->last_visual.start_col;
                v->line = v->last_visual.end_line;
                v->col  = v->last_visual.end_col;
                v->mode = v->last_visual.mode;
                clamp_cursor_visual(v, 1);
            }
            return;
        }
        if (key == '-' || key == '+') {
            reset_grammar(v);
            int did = 0;
            for (int i = 0; i < cnt; i++) {
                int ok = (key == '-') ? npl_buf_undo_older(v->buf) : npl_buf_undo_newer(v->buf);
                if (ok <= 0) break;
                did++;
            }
            if (did) {
                uint64_t seq = npl_buf_undo_seq(v->buf);
                const npl_undo_cur_t *uc = find_undo_cursor(v, seq);
                if (uc) {
                    v->line = uc->edit_line;
                    v->col = uc->linewise ? first_nonblank_line(v, uc->edit_line) : uc->edit_col;
                }
                clamp_cursor_normal(v, 1);
            }
            return;
        }
    }

    reset_grammar(v);
}

/* --- Normal / Visual / Operator Mode Handler --- */

static int
is_single_motion(uint32_t k)
{
    switch (k) {
    case 'h': case 'j': case 'k': case 'l':
    case '0': case '^': case '$': case '_':
    case '+': case '-': case 'G':
    case 'w': case 'W': case 'b': case 'B':
    case 'e': case 'E': case '%':
    case ';': case ',':
    case '{': case '}':
    case 'H': case 'M': case 'L':
    case NPL_K_LEFT: case NPL_K_RIGHT: case NPL_K_UP: case NPL_K_DOWN:
    case NPL_K_HOME: case NPL_K_END:   case NPL_K_CR:
        return 1;
    default:
        return 0;
    }
}

static void
execute_single_motion(npl_vim_t *v, uint32_t key)
{
    size_t n = buf_nlines(v);
    size_t l = v->line, c = v->col;
    int cnt = effective_count(v, 1);
    int has_cnt = has_any_count(v);

    size_t nl = l, nc = c;
    int linewise = 0, inclusive = 0, keep_want = 0;
    int is_word = 0, is_para = 0;

    if (key == 'h' || key == NPL_K_LEFT) {
        nc = (c > (size_t)cnt) ? (c - (size_t)cnt) : 0;
    } else if (key == 'l' || key == NPL_K_RIGHT) {
        size_t ln = buf_line_len(v, l);
        size_t max_c;
        if (v->op[0] != '\0') {
            max_c = ln;
        } else if (v->mode == NPL_VIM_VISUAL && l + 1 < n) {
            max_c = ln;
        } else {
            max_c = (ln > 0) ? (ln - 1) : 0;
        }
        nc = c + (size_t)cnt;
        if (nc > max_c) nc = max_c;
    } else if (key == 'j' || key == NPL_K_DOWN) {
        nl = l + (size_t)cnt;
        if (nl >= n) nl = n - 1;
        linewise = 1;
        keep_want = 1;
    } else if (key == 'k' || key == NPL_K_UP) {
        nl = (l > (size_t)cnt) ? (l - (size_t)cnt) : 0;
        linewise = 1;
        keep_want = 1;
    } else if (key == '0' || key == NPL_K_HOME) {
        nc = 0;
    } else if (key == '^') {
        nc = first_nonblank_line(v, l);
    } else if (key == '_') {
        nl = l + (size_t)(cnt - 1);
        if (nl >= n) nl = n - 1;
        nc = first_nonblank_line(v, nl);
        linewise = 1;
    } else if (key == '$' || key == NPL_K_END) {
        nl = l + (size_t)(cnt - 1);
        if (nl >= n) nl = n - 1;
        size_t ln = buf_line_len(v, nl);
        nc = (ln > 0) ? (ln - 1) : 0;
        inclusive = 1;
        if (v->op[0] == '\0') {
            v->line = nl;
            v->col = nc;
            v->curswant = NPL_CURSWANT_MAX;
            if (v->mode == NPL_VIM_VBLOCK) v->vblock_dollar = 1;
            reset_grammar(v);
            return;
        }
    } else if (key == '+' || key == NPL_K_CR) {
        nl = l + (size_t)cnt;
        if (nl >= n) nl = n - 1;
        nc = first_nonblank_line(v, nl);
        linewise = 1;
    } else if (key == '-') {
        nl = (l > (size_t)cnt) ? (l - (size_t)cnt) : 0;
        nc = first_nonblank_line(v, nl);
        linewise = 1;
    } else if (key == 'G') {
        nl = has_cnt ? (size_t)(cnt - 1) : (n - 1);
        if (nl >= n) nl = n - 1;
        nc = first_nonblank_line(v, nl);
        linewise = 1;
    } else if (key == 'w' || key == 'W') {
        int for_change = (v->op[0] == 'c' && v->op[1] == '\0');
        int for_op = (v->op[0] != '\0');
        motion_word_forward(v, l, c, cnt, key == 'W', for_change, for_op, &nl, &nc, &inclusive);
        is_word = 1;
    } else if (key == 'b' || key == 'B') {
        motion_word_backward(v, l, c, cnt, key == 'B', &nl, &nc);
        is_word = 1;
    } else if (key == 'e' || key == 'E') {
        motion_word_end_forward(v, l, c, cnt, key == 'E', &nl, &nc);
        inclusive = 1;
    } else if (key == '%') {
        if (has_cnt && cnt >= 1 && cnt <= 100) {
            nl = ((size_t)cnt * n + 99u) / 100u;
            if (nl > 0) nl--;
            if (nl >= n) nl = n - 1;
            nc = first_nonblank_line(v, nl);
            linewise = 1;
        } else {
            if (!motion_matching_bracket(v, l, c, &nl, &nc)) {
                reset_grammar(v);
                return;
            }
            inclusive = 1;
        }
    } else if (key == ';' || key == ',') {
        if (v->last_find_kind == '\0') {
            reset_grammar(v);
            return;
        }
        char kind = v->last_find_kind;
        if (key == ',') {
            switch (kind) {
            case 'f': kind = 'F'; break;
            case 'F': kind = 'f'; break;
            case 't': kind = 'T'; break;
            case 'T': kind = 't'; break;
            default: break;
            }
        }
        size_t tc = 0;
        if (!motion_char_find(v, l, c, kind, v->last_find_char, cnt, 1, &tc)) {
            reset_grammar(v);
            return;
        }
        nc = tc;
        inclusive = (kind == 'f' || kind == 't') ? 1 : 0;
    } else if (key == '{' || key == '}') {
        nl = motion_paragraph(v, l, key == '}' ? 1 : -1, cnt);
        if (key == '}' && nl == n - 1 && !line_is_empty(v, nl)) {
            size_t ln = buf_line_len(v, nl);
            nc = (ln > 0) ? (ln - 1) : 0;
            inclusive = 1;
        } else {
            nc = 0;
        }
        is_para = 1;
    } else if (key == 'H' || key == 'M' || key == 'L') {
        size_t vh = (v->win_height > 0) ? (size_t)v->win_height : 23u;
        size_t top = v->scroll_top;
        if (top >= n) top = 0;
        size_t bot = top + vh - 1;
        if (bot >= n) bot = n - 1;
        if (key == 'H') {
            nl = top + (size_t)(cnt - 1);
            if (nl > bot) nl = bot;
        } else if (key == 'L') {
            size_t off = (size_t)(cnt - 1);
            nl = (bot > off && bot - off >= top) ? (bot - off) : top;
        } else {
            nl = top + (bot - top) / 2;
        }
        nc = first_nonblank_line(v, nl);
        linewise = 1;
    }

    uint32_t dkeys[1] = { key };
    finish_motion_to(v, nl, nc, linewise, inclusive, keep_want, is_word, is_para, dkeys, 1);
}

static void
handle_normal_or_visual(npl_vim_t *v, uint32_t key)
{
    int is_vis = is_visual_mode(v->mode);

    /* Escape clears visual & grammar */
    if (key == NPL_K_ESC || key == NPL_K_CTRL_LBRACKET || key == NPL_K_CTRL('c')) {
        if (is_vis) {
            compute_visual_range(v, &v->last_visual);
            v->mode = NPL_VIM_NORMAL;
            v->vblock_dollar = 0;
            clamp_cursor_normal(v, 1);
        }
        reset_grammar(v);
        return;
    }

    /* Register name after '"' */
    if (v->expect_reg) {
        v->expect_reg = 0;
        if (key < 0x100u) {
            v->reg = (char)(uint8_t)key;
        }
        return;
    }

    /* Pending 2nd key of a prefix */
    if (v->pending_prefix != '\0') {
        handle_prefix_key(v, v->pending_prefix, key);
        return;
    }

    /* Register introducer '"' */
    if (key == '"' && v->op[0] == '\0') {
        v->expect_reg = 1;
        return;
    }

    /* Count digits */
    if ((key >= '1' && key <= '9') ||
        (key == '0' && ((v->op[0] != '\0') ? v->has_count2 : v->has_count1)))
    {
        int d = (int)(key - '0');
        if (v->op[0] != '\0') {
            v->has_count2 = 1;
            if (v->count2 < 1000000) v->count2 = v->count2 * 10 + d;
        } else {
            v->has_count1 = 1;
            if (v->count1 < 1000000) v->count1 = v->count1 * 10 + d;
        }
        return;
    }

    /* Doubled g-operator shorthand: guu / gUU / g~~ */
    if (v->op[0] == 'g' && (v->op[1] == 'u' || v->op[1] == 'U' || v->op[1] == '~') &&
        key == (uint32_t)(uint8_t)v->op[1])
    {
        char gop[4];
        memcpy(gop, v->op, sizeof(gop));
        char reg = v->reg;
        int cnt = effective_count(v, 1);
        int has_cnt = has_any_count(v);
        size_t n = buf_nlines(v);
        size_t el = v->line + (size_t)(cnt - 1);
        if (el >= n) el = n - 1;

        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, 'g'); dot_push(v, key); dot_push(v, key);
        reset_grammar(v);

        npl_range_t r;
        memset(&r, 0, sizeof(r));
        r.start_line = v->line; r.start_col = 0;
        r.end_line   = el;      r.end_col   = buf_line_len(v, el);
        r.linewise   = 1;
        apply_operator_range(v, gop, &r, reg);
        dot_finish(v);
        return;
    }

    /* Text object introducers i / a in OPERATOR or VISUAL */
    if ((key == 'i' || key == 'a') && (v->op[0] != '\0' || is_vis)) {
        v->pending_prefix = (char)(uint8_t)key;
        return;
    }

    /* Multi-key prefixes */
    if (key == 'g' || key == 'f' || key == 'F' || key == 't' || key == 'T' ||
        key == '\'' || key == '`')
    {
        v->pending_prefix = (char)(uint8_t)key;
        return;
    }

    if (v->op[0] == '\0' && !is_vis) {
        if (key == 'm' || key == 'r' || key == 'q' || key == '@') {
            v->pending_prefix = (char)(uint8_t)key;
            return;
        }
    }

    /* Operators: d, c, y, >, < */
    if (key == 'd' || key == 'c' || key == 'y' || key == '>' || key == '<') {
        char op[4] = { (char)(uint8_t)key, '\0', '\0', '\0' };
        if (is_vis) {
            apply_operator_visual(v, op);
            return;
        }
        if (v->op[0] != '\0') {
            if (v->op[0] == op[0] && v->op[1] == '\0') {
                /* Doubled operator: dd, cc, yy, >>, << */
                int cnt = effective_count(v, 1);
                int has_cnt = has_any_count(v);
                char reg = v->reg;
                size_t n = buf_nlines(v);
                size_t el = v->line + (size_t)(cnt - 1);
                if (el >= n) el = n - 1;

                if (op[0] != 'y') {
                    dot_start(v);
                    if (has_cnt) dot_push_count(v, cnt);
                    dot_push(v, key); dot_push(v, key);
                }
                reset_grammar(v);

                npl_range_t r;
                memset(&r, 0, sizeof(r));
                r.start_line = v->line; r.start_col = 0;
                r.end_line   = el;      r.end_col   = buf_line_len(v, el);
                r.linewise   = 1;
                apply_operator_range(v, op, &r, reg);
                if (op[0] != 'c' && op[0] != 'y') {
                    dot_finish(v);
                }
                return;
            }
            reset_grammar(v);
            return;
        }
        memcpy(v->op, op, sizeof(op));
        v->mode = NPL_VIM_OPERATOR;
        return;
    }

    /* Visual-mode single-key operators & helpers */
    if (is_vis) {
        if (key == 'x' || key == 'X' || key == 'D') {
            apply_operator_visual(v, "d");
            return;
        }
        if (key == 's' || key == 'S' || key == 'C') {
            apply_operator_visual(v, "c");
            return;
        }
        if (key == 'Y') {
            apply_operator_visual(v, "y");
            return;
        }
        if (key == '~' || key == 'u' || key == 'U') {
            char gop[4] = { 'g', (char)(uint8_t)key, '\0', '\0' };
            apply_operator_visual(v, gop);
            return;
        }
        if (key == 'o') {
            size_t tl = v->line, tc = v->col;
            v->line = v->vis_anchor_line;
            v->col  = v->vis_anchor_col;
            v->vis_anchor_line = tl;
            v->vis_anchor_col  = tc;
            v->curswant = v->col;
            return;
        }
        if ((key == 'I' || key == 'A') && v->mode == NPL_VIM_VBLOCK) {
            npl_vim_visual_range_t vr;
            compute_visual_range(v, &vr);
            v->last_visual = vr;
            int dollar = v->vblock_dollar;
            v->vblock_dollar = 0;
            reset_grammar(v);

            size_t sl = vr.start_line, el = vr.end_line;
            size_t sc = vr.start_col,  ec = vr.end_col;
            size_t ln0 = buf_line_len(v, sl);
            size_t ins_col;
            if (key == 'A') {
                if (dollar) {
                    ins_col = ln0;
                } else {
                    ins_col = ec + 1;
                    if (ln0 < ins_col) {
                        size_t pad_n = ins_col - ln0;
                        char *pad = (char *)malloc(pad_n);
                        if (pad) {
                            memset(pad, ' ', pad_n);
                            size_t off = npl_buf_line_col_to_offset(v->buf, sl, ln0);
                            (void)npl_buf_insert(v->buf, off, pad, pad_n);
                            free(pad);
                        }
                    }
                }
            } else {
                ins_col = (sc <= ln0) ? sc : ln0;
            }

            v->vbi.active     = 1;
            v->vbi.is_append  = (key == 'A') ? 1 : 0;
            v->vbi.is_change  = 0;
            v->vbi.dollar     = dollar;
            v->vbi.start_line = sl;
            v->vbi.end_line   = el;
            v->vbi.start_col  = sc;
            v->vbi.end_col    = ec;
            v->vbi.text_len   = 0;
            if (v->vbi.text) v->vbi.text[0] = '\0';

            enter_insert_mode(v, sl, ins_col, 0);
            return;
        }
        if (key == 'v' || key == 'V' || key == NPL_K_CTRL('v')) {
            npl_vim_mode_t target = (key == 'v') ? NPL_VIM_VISUAL
                                  : (key == 'V') ? NPL_VIM_VLINE : NPL_VIM_VBLOCK;
            if (v->mode == target) {
                compute_visual_range(v, &v->last_visual);
                v->mode = NPL_VIM_NORMAL;
                v->vblock_dollar = 0;
                clamp_cursor_normal(v, 1);
            } else {
                v->mode = target;
                v->vblock_dollar = 0;
            }
            reset_grammar(v);
            return;
        }
        if (key == 'r') {
            /* Visual single-char replace is not handled here */
            return;
        }
    }

    /* Single-key motions (NORMAL, VISUAL, OPERATOR) */
    if (is_single_motion(key)) {
        execute_single_motion(v, key);
        return;
    }

    /* In OPERATOR mode, unrecognized key cancels operator */
    if (v->op[0] != '\0') {
        reset_grammar(v);
        return;
    }

    /* In VISUAL mode, ignore remaining normal-only commands (like '.') */
    if (is_vis) {
        reset_grammar(v);
        return;
    }

    /* NORMAL-only commands */
    int cnt = effective_count(v, 1);
    int has_cnt = has_any_count(v);
    char reg = v->reg;
    reset_grammar(v);

    /* Visual entry */
    if (key == 'v' || key == 'V' || key == NPL_K_CTRL('v')) {
        v->vis_anchor_line = v->line;
        v->vis_anchor_col  = v->col;
        v->vblock_dollar   = 0;
        v->mode = (key == 'v') ? NPL_VIM_VISUAL
                : (key == 'V') ? NPL_VIM_VLINE : NPL_VIM_VBLOCK;
        return;
    }

    /* Insert / Append / Open line: i, I, a, A, o, O */
    if (key == 'i' || key == 'I' || key == 'a' || key == 'A' || key == 'o' || key == 'O') {
        dot_start(v);
        dot_push(v, key);
        size_t ln = buf_line_len(v, v->line);
        if (key == 'i') {
            enter_insert_mode(v, v->line, v->col, 0);
        } else if (key == 'I') {
            enter_insert_mode(v, v->line, first_nonblank_insert(v, v->line), 0);
        } else if (key == 'a') {
            enter_insert_mode(v, v->line, (ln > 0) ? (v->col + 1) : 0, 0);
        } else if (key == 'A') {
            enter_insert_mode(v, v->line, ln, 0);
        } else if (key == 'o') {
            v->ins_before_seq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            v->in_insert_group = 1;
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line, ln);
            (void)npl_buf_insert(v->buf, off, "\n", 1);
            enter_insert_mode(v, v->line + 1, 0, 1);
        } else { /* O */
            v->ins_before_seq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            v->in_insert_group = 1;
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line, 0);
            (void)npl_buf_insert(v->buf, off, "\n", 1);
            enter_insert_mode(v, v->line, 0, 1);
        }
        return;
    }

    /* Replace mode: R */
    if (key == 'R') {
        dot_start(v);
        dot_push(v, 'R');
        v->rep_len = 0;
        v->ins_start_line = v->line;
        v->ins_start_col  = v->col;
        v->ins_linewise   = 0;
        v->ins_before_seq = npl_buf_undo_seq(v->buf);
        npl_buf_begin_group(v->buf);
        v->in_insert_group = 1;
        v->mode = NPL_VIM_REPLACE;
        return;
    }

    /* Single-char delete: x, X */
    if (key == 'x' || key == 'X') {
        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, key);
        size_t ln = 0;
        char *line = npl_buf_get_line_alloc(v->buf, v->line, &ln);
        if (line && ln > 0) {
            size_t start = 0, del_len = 0;
            if (key == 'x') {
                start = v->col;
                del_len = (v->col + (size_t)cnt <= ln) ? (size_t)cnt : (ln - v->col);
            } else {
                del_len = ((size_t)cnt <= v->col) ? (size_t)cnt : v->col;
                start = v->col - del_len;
            }
            if (del_len > 0) {
                store_register_delete(v, reg, line + start, del_len, NPL_REG_CHAR);
                size_t off = npl_buf_line_col_to_offset(v->buf, v->line, start);
                uint64_t bseq = npl_buf_undo_seq(v->buf);
                npl_buf_begin_group(v->buf);
                (void)npl_buf_delete(v->buf, off, del_len);
                npl_buf_end_group(v->buf);
                v->col = start;
                clamp_cursor_normal(v, 1);
                if (npl_buf_undo_seq(v->buf) != bseq) {
                    record_undo_cursor(v, npl_buf_undo_seq(v->buf), v->line, start, 0);
                }
            }
        }
        free(line);
        dot_finish(v);
        return;
    }

    /* Substitute char(s): s */
    if (key == 's') {
        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, 's');
        size_t ln = 0;
        char *line = npl_buf_get_line_alloc(v->buf, v->line, &ln);
        v->ins_before_seq = npl_buf_undo_seq(v->buf);
        npl_buf_begin_group(v->buf);
        v->in_insert_group = 1;
        if (line && ln > 0) {
            size_t del_len = (v->col + (size_t)cnt <= ln) ? (size_t)cnt : (ln - v->col);
            if (del_len > 0) {
                store_register_delete(v, reg, line + v->col, del_len, NPL_REG_CHAR);
                size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
                (void)npl_buf_delete(v->buf, off, del_len);
            }
        }
        free(line);
        enter_insert_mode(v, v->line, v->col, 0);
        return;
    }

    /* Substitute line(s): S (same as cc) */
    if (key == 'S') {
        size_t n = buf_nlines(v);
        size_t el = v->line + (size_t)(cnt - 1);
        if (el >= n) el = n - 1;
        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, 'S');
        npl_range_t r;
        memset(&r, 0, sizeof(r));
        r.start_line = v->line; r.start_col = 0;
        r.end_line   = el;      r.end_col   = buf_line_len(v, el);
        r.linewise   = 1;
        apply_operator_range(v, "c", &r, reg);
        return;
    }

    /* Delete/Change to EOL: D, C */
    if (key == 'D' || key == 'C') {
        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, key);
        size_t n = buf_nlines(v);
        size_t el = v->line + (size_t)(cnt - 1);
        if (el >= n) el = n - 1;
        size_t el_ln = buf_line_len(v, el);
        npl_range_t r;
        memset(&r, 0, sizeof(r));
        r.start_line = v->line; r.start_col = v->col;
        r.end_line   = el;      r.end_col   = el_ln;
        r.exclusive  = 1;
        char op[4] = { (key == 'D') ? 'd' : 'c', '\0', '\0', '\0' };
        apply_operator_range(v, op, &r, reg);
        if (key == 'D') dot_finish(v);
        return;
    }

    /* Yank line(s): Y (same as yy in Vim) */
    if (key == 'Y') {
        size_t n = buf_nlines(v);
        size_t el = v->line + (size_t)(cnt - 1);
        if (el >= n) el = n - 1;
        npl_range_t r;
        memset(&r, 0, sizeof(r));
        r.start_line = v->line; r.start_col = 0;
        r.end_line   = el;      r.end_col   = buf_line_len(v, el);
        r.linewise   = 1;
        apply_operator_range(v, "y", &r, reg);
        return;
    }

    /* Toggle case: ~ */
    if (key == '~') {
        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, '~');
        size_t ln = 0;
        char *line = npl_buf_get_line_alloc(v->buf, v->line, &ln);
        if (line && ln > 0 && v->col < ln) {
            size_t take = (v->col + (size_t)cnt <= ln) ? (size_t)cnt : (ln - v->col);
            apply_case_str(line + v->col, take, "g~");
            size_t off = npl_buf_line_col_to_offset(v->buf, v->line, v->col);
            uint64_t bseq = npl_buf_undo_seq(v->buf);
            npl_buf_begin_group(v->buf);
            (void)npl_buf_delete(v->buf, off, take);
            (void)npl_buf_insert(v->buf, off, line + v->col, take);
            npl_buf_end_group(v->buf);
            if (npl_buf_undo_seq(v->buf) != bseq) {
                record_undo_cursor(v, npl_buf_undo_seq(v->buf), v->line, v->col, 0);
            }
            v->col += take;
            clamp_cursor_normal(v, 1);
        }
        free(line);
        dot_finish(v);
        return;
    }

    /* Join lines: J */
    if (key == 'J') {
        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, 'J');
        join_lines(v, cnt, 1);
        dot_finish(v);
        return;
    }

    /* Put: p / P */
    if (key == 'p' || key == 'P') {
        dot_start(v);
        if (has_cnt) dot_push_count(v, cnt);
        dot_push(v, key);
        put_register(v, reg, key == 'p', cnt);
        dot_finish(v);
        return;
    }

    /* Undo: u */
    if (key == 'u') {
        int did = 0;
        uint64_t undone_seq = 0;
        for (int i = 0; i < cnt; i++) {
            uint64_t cur_seq = npl_buf_undo_seq(v->buf);
            if (npl_buf_undo(v->buf) <= 0) break;
            undone_seq = cur_seq;
            did++;
        }
        if (did) {
            const npl_undo_cur_t *uc = find_undo_cursor(v, undone_seq);
            if (uc) {
                v->line = uc->edit_line;
                size_t n = buf_nlines(v);
                if (v->line >= n) v->line = n - 1;
                v->col = uc->linewise ? first_nonblank_line(v, v->line) : uc->edit_col;
            }
            clamp_cursor_normal(v, 1);
        }
        return;
    }

    /* Redo: <C-r> */
    if (key == NPL_K_CTRL('r')) {
        int did = 0;
        for (int i = 0; i < cnt; i++) {
            if (npl_buf_redo(v->buf) <= 0) break;
            did++;
        }
        if (did) {
            uint64_t seq = npl_buf_undo_seq(v->buf);
            const npl_undo_cur_t *uc = find_undo_cursor(v, seq);
            if (uc) {
                v->line = uc->edit_line;
                size_t n = buf_nlines(v);
                if (v->line >= n) v->line = n - 1;
                v->col = uc->linewise ? first_nonblank_line(v, v->line) : uc->edit_col;
            }
            clamp_cursor_normal(v, 1);
        }
        return;
    }

    /* Dot-repeat: . */
    if (key == '.') {
        replay_dot(v, has_cnt, cnt);
        return;
    }
}

static void
dispatch_key(npl_vim_t *v, uint32_t key)
{
    /* Macro recording intercept (only at top level, not while replaying macros) */
    if (v->recording && v->macro_depth == 0) {
        if (v->mode == NPL_VIM_NORMAL && key == 'q' &&
            v->pending_prefix == '\0' && !v->expect_reg && v->op[0] == '\0')
        {
            v->recording = 0;
            npl_vim_reg_t *dst = &v->reg_alpha[v->rec_reg];
            if (v->rec_append) {
                (void)reg_append(dst, v->rec_buf ? v->rec_buf : "", v->rec_len, NPL_REG_CHAR);
            } else {
                (void)reg_set(dst, v->rec_buf ? v->rec_buf : "", v->rec_len, NPL_REG_CHAR);
            }
            v->rec_len = 0;
            return;
        }
        (void)encode_key_to_buf(&v->rec_buf, &v->rec_len, &v->rec_cap, key);
    }

    if (v->mode == NPL_VIM_INSERT) {
        handle_insert_key(v, key);
    } else if (v->mode == NPL_VIM_REPLACE) {
        handle_replace_key(v, key);
    } else {
        handle_normal_or_visual(v, key);
    }
}

/* --- Key Tokenizer --- */

static int
ieq_n(const char *a, size_t n, const char *lit)
{
    size_t i = 0;
    while (i < n && lit[i] != '\0') {
        if (ch_to_lower((uint8_t)a[i]) != ch_to_lower((uint8_t)lit[i])) return 0;
        i++;
    }
    return (i == n && lit[i] == '\0');
}

static int
parse_angle_key(const char *s, size_t rem, uint32_t *out_key, size_t *out_used)
{
    if (rem < 3 || s[0] != '<') return 0;
    size_t close = 0;
    for (size_t i = 1; i < rem && i <= 16; i++) {
        if (s[i] == '>') { close = i; break; }
        if (s[i] == '<' || s[i] == ' ') return 0;
    }
    if (close < 2) return 0;

    const char *body = s + 1;
    size_t blen = close - 1;
    uint32_t k = NPL_K_NONE;

    if (ieq_n(body, blen, "esc") || ieq_n(body, blen, "escape")) {
        k = NPL_K_ESC;
    } else if (ieq_n(body, blen, "cr") || ieq_n(body, blen, "enter") || ieq_n(body, blen, "return")) {
        k = NPL_K_CR;
    } else if (ieq_n(body, blen, "bs") || ieq_n(body, blen, "backspace")) {
        k = NPL_K_BS;
    } else if (ieq_n(body, blen, "tab")) {
        k = NPL_K_TAB;
    } else if (ieq_n(body, blen, "space")) {
        k = ' ';
    } else if (ieq_n(body, blen, "del")) {
        k = NPL_K_DEL;
    } else if (ieq_n(body, blen, "left")) {
        k = NPL_K_LEFT;
    } else if (ieq_n(body, blen, "right")) {
        k = NPL_K_RIGHT;
    } else if (ieq_n(body, blen, "up")) {
        k = NPL_K_UP;
    } else if (ieq_n(body, blen, "down")) {
        k = NPL_K_DOWN;
    } else if (ieq_n(body, blen, "home")) {
        k = NPL_K_HOME;
    } else if (ieq_n(body, blen, "end")) {
        k = NPL_K_END;
    } else if (ieq_n(body, blen, "lt")) {
        k = '<';
    } else if (ieq_n(body, blen, "bar")) {
        k = '|';
    } else if (ieq_n(body, blen, "bslash")) {
        k = '\\';
    } else if (blen == 3 && (body[0] == 'c' || body[0] == 'C') && body[1] == '-') {
        uint8_t ch = ch_to_lower((uint8_t)body[2]);
        if (ch_is_lower(ch)) {
            k = NPL_K_CTRL(ch);
        } else if (body[2] == '[') {
            k = NPL_K_CTRL_LBRACKET;
        } else if (body[2] == '\\') {
            k = NPL_K_CTRL_BSLASH;
        } else if (body[2] == ']') {
            k = NPL_K_CTRL_RBRACKET;
        }
    }

    if (k == NPL_K_NONE) return 0;
    *out_key = k;
    *out_used = close + 1;
    return 1;
}

/* --- Public API --- */

npl_vim_t *
npl_vim_new(npl_buf_t *buf)
{
    if (!buf) return NULL;
    npl_vim_t *v = (npl_vim_t *)calloc(1, sizeof(npl_vim_t));
    if (!v) return NULL;
    v->buf = buf;
    v->shiftwidth = 4;
    v->tabstop    = 4;
    v->expandtab  = 1;
    v->win_height = 23;
    v->scroll_top = 0;
    v->last_macro_reg = -1;
    return v;
}

void
npl_vim_free(npl_vim_t *v)
{
    if (!v) return;
    reg_free(&v->reg_unnamed);
    reg_free(&v->reg_small);
    for (int i = 0; i < 10; i++) reg_free(&v->reg_num[i]);
    for (int i = 0; i < 26; i++) reg_free(&v->reg_alpha[i]);
    free(v->vbi.text);
    free(v->rep_stack);
    free(v->undo_curs);
    free(v->dot_cur);
    free(v->dot_saved);
    free(v->rec_buf);
    free(v);
}

void
npl_vim_reset(npl_vim_t *v)
{
    if (!v) return;
    if (v->in_insert_group && v->buf) {
        npl_buf_end_group(v->buf);
        v->in_insert_group = 0;
    }
    v->mode = NPL_VIM_NORMAL;
    v->line = 0;
    v->col = 0;
    v->curswant = 0;
    reset_grammar(v);
    v->vis_anchor_line = 0;
    v->vis_anchor_col  = 0;
    v->vblock_dollar   = 0;
    memset(&v->last_visual, 0, sizeof(v->last_visual));
    v->vbi.active   = 0;
    v->vbi.text_len = 0;
    v->last_find_kind = '\0';
    v->last_find_char = '\0';

    reg_clear(&v->reg_unnamed);
    reg_clear(&v->reg_small);
    for (int i = 0; i < 10; i++) reg_clear(&v->reg_num[i]);
    for (int i = 0; i < 26; i++) reg_clear(&v->reg_alpha[i]);
    memset(v->marks, 0, sizeof(v->marks));
    memset(&v->mark_prev, 0, sizeof(v->mark_prev));

    v->rep_len = 0;
    v->undo_cur_len = 0;
    v->dot_recording = 0;
    v->dot_replaying = 0;
    v->dot_cur_len = 0;
    free(v->dot_saved);
    v->dot_saved = NULL;
    v->dot_saved_len = 0;
    v->dot_saved_visual = 0;
    v->recording = 0;
    v->rec_len = 0;
    v->last_macro_reg = -1;
    v->macro_depth = 0;
}

void
npl_vim_set_buffer(npl_vim_t *v, npl_buf_t *buf)
{
    if (!v || !buf) return;
    if (v->in_insert_group && v->buf) {
        npl_buf_end_group(v->buf);
        v->in_insert_group = 0;
    }
    v->buf = buf;
    v->undo_cur_len = 0;
    clamp_cursor_normal(v, 1);
}

void
npl_vim_set_options(npl_vim_t *v, int shiftwidth, int tabstop,
                    int expandtab, int win_height, size_t scroll_top)
{
    if (!v) return;
    if (shiftwidth > 0) v->shiftwidth = shiftwidth;
    if (tabstop > 0)    v->tabstop    = tabstop;
    if (expandtab >= 0) v->expandtab  = expandtab ? 1 : 0;
    if (win_height > 0) v->win_height = win_height;
    v->scroll_top = scroll_top;
}

size_t
npl_vim_feed_keys(npl_vim_t *v, const char *keys, size_t len)
{
    if (!v || !v->buf || !keys || len == 0) return 0;

    size_t i = 0;
    size_t count = 0;
    while (i < len) {
        uint32_t k = NPL_K_NONE;
        size_t used = 1;
        uint8_t b = (uint8_t)keys[i];

        if (b == '<' && parse_angle_key(keys + i, len - i, &k, &used)) {
            /* parsed symbolic key */
        } else if (b == 0x1Bu) {
            k = NPL_K_ESC;
        } else if (b == '\r' || b == '\n') {
            k = NPL_K_CR;
        } else if (b == 0x08u || b == 0x7Fu) {
            k = NPL_K_BS;
        } else if (b == '\t') {
            k = NPL_K_TAB;
        } else if (b >= 1u && b <= 26u) {
            k = NPL_K_CTRL((char)('a' + (b - 1u)));
        } else if (b == 28u) {
            k = NPL_K_CTRL_BSLASH;
        } else if (b == 29u) {
            k = NPL_K_CTRL_RBRACKET;
        } else {
            k = (uint32_t)b;
        }

        i += used;
        dispatch_key(v, k);
        count++;
    }
    return count;
}

npl_vim_mode_t
npl_vim_mode(const npl_vim_t *v)
{
    return v ? v->mode : NPL_VIM_NORMAL;
}

const char *
npl_vim_mode_name(npl_vim_mode_t mode)
{
    switch (mode) {
    case NPL_VIM_NORMAL:   return "NORMAL";
    case NPL_VIM_INSERT:   return "INSERT";
    case NPL_VIM_REPLACE:  return "REPLACE";
    case NPL_VIM_VISUAL:   return "VISUAL";
    case NPL_VIM_VLINE:    return "VLINE";
    case NPL_VIM_VBLOCK:   return "VBLOCK";
    case NPL_VIM_OPERATOR: return "OPERATOR";
    default:               return "NORMAL";
    }
}

void
npl_vim_cursor(const npl_vim_t *v, size_t *out_line, size_t *out_col)
{
    if (out_line) *out_line = v ? v->line : 0;
    if (out_col)  *out_col  = v ? v->col  : 0;
}

void
npl_vim_set_cursor(npl_vim_t *v, size_t line, size_t col)
{
    if (!v || !v->buf) return;
    v->line = line;
    v->col  = col;
    if (v->mode == NPL_VIM_INSERT || v->mode == NPL_VIM_REPLACE) {
        clamp_cursor_insert(v);
    } else if (is_visual_mode(v->mode)) {
        clamp_cursor_visual(v, 1);
    } else {
        clamp_cursor_normal(v, 1);
    }
}

const char *
npl_vim_get_register(const npl_vim_t *v, char name,
                     size_t *out_len, npl_reg_type_t *out_type)
{
    if (!v) {
        if (out_len)  *out_len  = 0;
        if (out_type) *out_type = NPL_REG_CHAR;
        return "";
    }
    const npl_vim_reg_t *r = lookup_register(v, name);
    if (!r || !r->text) {
        if (out_len)  *out_len  = 0;
        if (out_type) *out_type = NPL_REG_CHAR;
        return "";
    }
    if (out_len)  *out_len  = r->len;
    if (out_type) *out_type = r->type;
    return r->text;
}

int
npl_vim_set_register(npl_vim_t *v, char name,
                     const char *text, size_t len, npl_reg_type_t type)
{
    if (!v || name == '_') return 0;
    if (!text) len = 0;
    if (name == '\0' || name == '"') {
        return reg_set(&v->reg_unnamed, text, len, type);
    }
    if (name == '-') {
        return reg_set(&v->reg_small, text, len, type);
    }
    if (ch_is_digit((uint8_t)name)) {
        return reg_set(&v->reg_num[name - '0'], text, len, type);
    }
    if (ch_is_lower((uint8_t)name)) {
        return reg_set(&v->reg_alpha[name - 'a'], text, len, type);
    }
    if (ch_is_upper((uint8_t)name)) {
        return reg_append(&v->reg_alpha[name - 'A'], text, len, type);
    }
    return 0;
}

const char *
npl_reg_type_name(npl_reg_type_t t)
{
    switch (t) {
    case NPL_REG_CHAR:  return "char";
    case NPL_REG_LINE:  return "line";
    case NPL_REG_BLOCK: return "block";
    default:            return "char";
    }
}

int
npl_vim_set_mark(npl_vim_t *v, char name, size_t line, size_t col)
{
    if (!v) return 0;
    if (ch_is_lower((uint8_t)name)) {
        v->marks[name - 'a'].set  = 1;
        v->marks[name - 'a'].line = line;
        v->marks[name - 'a'].col  = col;
        return 1;
    }
    return 0;
}

int
npl_vim_get_mark(const npl_vim_t *v, char name, size_t *out_line, size_t *out_col)
{
    if (!v) return 0;
    if (name == '\'' || name == '`') {
        if (!v->mark_prev.set) return 0;
        if (out_line) *out_line = v->mark_prev.line;
        if (out_col)  *out_col  = v->mark_prev.col;
        return 1;
    }
    if (ch_is_lower((uint8_t)name)) {
        const npl_vim_mark_t *m = &v->marks[name - 'a'];
        if (!m->set) return 0;
        if (out_line) *out_line = m->line;
        if (out_col)  *out_col  = m->col;
        return 1;
    }
    return 0;
}

int
npl_vim_visual_range(const npl_vim_t *v, npl_vim_visual_range_t *out)
{
    if (!v || !out) return 0;
    compute_visual_range(v, out);
    return out->active;
}

void
npl_vim_state_info(const npl_vim_t *v, npl_vim_state_info_t *out)
{
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!v) return;
    out->mode           = v->mode;
    out->line           = v->line;
    out->col            = v->col;
    out->curswant       = v->curswant;
    out->count1         = v->has_count1 ? v->count1 : 0;
    out->count2         = v->has_count2 ? v->count2 : 0;
    memcpy(out->op, v->op, sizeof(out->op));
    out->reg            = v->reg;
    out->expect_reg     = v->expect_reg;
    out->pending_prefix = v->pending_prefix;
    out->recording_reg  = v->recording ? (char)('a' + v->rec_reg) : '\0';
    out->shiftwidth     = v->shiftwidth;
    out->tabstop        = v->tabstop;
    out->expandtab      = v->expandtab;
    out->win_height     = v->win_height;
    out->scroll_top     = v->scroll_top;
    if (v->buf) {
        out->undo_seq = npl_buf_undo_seq(v->buf);
        out->can_undo = npl_buf_can_undo(v->buf);
        out->can_redo = npl_buf_can_redo(v->buf);
    }
    compute_visual_range(v, &out->visual);
    out->last_visual = v->last_visual;
}
