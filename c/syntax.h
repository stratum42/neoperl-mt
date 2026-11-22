/*
 * c/syntax.h - Incremental 27-language line-state lexer & symbol extractor
 */
#ifndef NPL_SYNTAX_H
#define NPL_SYNTAX_H

#include "buffer.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum npl_lang {
    NPL_LANG_TEXT     = 0,
    NPL_LANG_PERL     = 1,
    NPL_LANG_C        = 2,
    NPL_LANG_CPP      = 3,
    NPL_LANG_XS       = 4,
    NPL_LANG_RUST     = 5,
    NPL_LANG_GO       = 6,
    NPL_LANG_PYTHON   = 7,
    NPL_LANG_JS       = 8,
    NPL_LANG_TS       = 9,
    NPL_LANG_LUA      = 10,
    NPL_LANG_JSON     = 11,
    NPL_LANG_YAML     = 12,
    NPL_LANG_SH       = 13,
    NPL_LANG_MARKDOWN = 14,
    NPL_LANG_DIFF     = 15,
    NPL_LANG_TCL      = 16,
    NPL_LANG_MAKE     = 17,
    NPL_LANG_SQL      = 18,
    NPL_LANG_HLASM    = 19,
    NPL_LANG_ASM      = 20,
    NPL_LANG_RPGILE   = 21,
    NPL_LANG_COBOL    = 22,
    NPL_LANG_SYCL     = 23,
    NPL_LANG_HIP      = 24,
    NPL_LANG_GLSL     = 25,
    NPL_LANG_METAL    = 26
} npl_lang_t;

#define NPL_LANG_COUNT 27

typedef enum npl_tok_type {
    NPL_TOK_NORMAL   = 0,
    NPL_TOK_KEYWORD  = 1,
    NPL_TOK_STRING   = 2,
    NPL_TOK_COMMENT  = 3,
    NPL_TOK_NUMBER   = 4,
    NPL_TOK_VAR      = 5,
    NPL_TOK_FUNC     = 6,
    NPL_TOK_TYPE     = 7,
    NPL_TOK_OPERATOR = 8,
    NPL_TOK_PREPROC  = 9,
    NPL_TOK_CONSTANT = 10,
    NPL_TOK_TAG      = 11
} npl_tok_type_t;

typedef enum npl_lex_state {
    NPL_STATE_NORMAL    = 0,
    NPL_STATE_BLOCK_CMT = 1, /* C/C++/XS/Rust/Go/JS/TS block comment */
    NPL_STATE_PERL_POD  = 2, /* Perl POD =head .. =cut */
    NPL_STATE_PY_DQUOTE = 3, /* Python triple double quote */
    NPL_STATE_PY_SQUOTE = 4, /* Python triple single quote */
    NPL_STATE_LUA_CMT   = 5, /* Lua --[[ ... ]] */
    NPL_STATE_MD_FENCE  = 6, /* Markdown fenced code block */
    NPL_STATE_BACKTICK  = 7  /* Go/JS/TS multiline template/raw string */
} npl_lex_state_t;

typedef struct npl_token {
    uint32_t col;
    uint32_t len;
    uint8_t  type;
} npl_token_t;

typedef struct npl_symbol {
    char  *name;
    char  *kind;
    size_t line;
    size_t col;
} npl_symbol_t;

typedef struct npl_symbol_list {
    npl_symbol_t *items;
    size_t        count;
    size_t        cap;
} npl_symbol_list_t;

typedef struct npl_syntax npl_syntax_t;

npl_lang_t  npl_lang_from_name(const char *name);
npl_lang_t  npl_lang_from_filename(const char *filename);
const char *npl_lang_name(npl_lang_t lang);
size_t      npl_lang_count(void);
const char *npl_tok_name(npl_tok_type_t tok);

npl_syntax_t *npl_syntax_new(npl_lang_t lang);
void          npl_syntax_free(npl_syntax_t *syn);
npl_lang_t    npl_syntax_get_lang(const npl_syntax_t *syn);
void          npl_syntax_set_lang(npl_syntax_t *syn, npl_lang_t lang);

void   npl_syntax_invalidate(npl_syntax_t *syn, size_t from_line, int64_t line_delta);
void   npl_syntax_sync(npl_buf_t *buf, npl_syntax_t *syn, size_t upto_line);
uint8_t npl_syntax_end_state(const npl_syntax_t *syn, size_t line);
size_t npl_syntax_last_relex_lines(const npl_syntax_t *syn);

uint8_t npl_syntax_lex_line(npl_lang_t lang, const char *line, size_t len,
                            uint8_t start_state, npl_token_t *out_toks,
                            size_t max_toks, size_t *out_count);

int  npl_syntax_extract_symbols_buf(npl_buf_t *buf, npl_lang_t lang, npl_symbol_list_t *out);
int  npl_syntax_extract_symbols_text(const char *text, size_t len, npl_lang_t lang, npl_symbol_list_t *out);
void npl_symbol_list_free(npl_symbol_list_t *list);

#ifdef __cplusplus
}
#endif

#endif /* NPL_SYNTAX_H */
