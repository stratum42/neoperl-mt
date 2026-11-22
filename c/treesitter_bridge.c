/*
 * c/treesitter_bridge.c - Runtime dlopen(libtree-sitter) dynamic AST bridge
 *
 * Zero compile-time link dependency on libtree-sitter. Uses memcpy-clean
 * dynamic symbol resolution for strict C11 / -Wall -Wextra -Werror compliance.
 */
#include "treesitter_bridge.h"
#include "tkmt_thread.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
typedef HMODULE npl_dl_handle_t;
static npl_dl_handle_t npl_dl_open(const char *p) { return LoadLibraryA(p); }
static void *npl_dl_sym(npl_dl_handle_t h, const char *s) {
    FARPROC fp = GetProcAddress(h, s);
    void *ptr = NULL;
    memcpy(&ptr, &fp, sizeof(ptr));
    return ptr;
}
static void npl_dl_close(npl_dl_handle_t h) { if (h) FreeLibrary(h); }
#else
#  include <dlfcn.h>
typedef void *npl_dl_handle_t;
static npl_dl_handle_t npl_dl_open(const char *p) { return dlopen(p, RTLD_LAZY | RTLD_LOCAL); }
static void *npl_dl_sym(npl_dl_handle_t h, const char *s) { return dlsym(h, s); }
static void npl_dl_close(npl_dl_handle_t h) { if (h) dlclose(h); }
#endif

/* Binary-compatible minimal Tree-sitter ABI structs */
typedef struct npl_ts_parser   npl_ts_parser_t;
typedef struct npl_ts_tree     npl_ts_tree_t;
typedef struct npl_ts_language npl_ts_language_t;

typedef struct npl_ts_point {
    uint32_t row;
    uint32_t column;
} npl_ts_point_t;

typedef struct npl_ts_node {
    uint32_t             context[4];
    const void          *id;
    const npl_ts_tree_t *tree;
} npl_ts_node_t;

typedef npl_ts_parser_t *(*fn_ts_parser_new_t)(void);
typedef void (*fn_ts_parser_delete_t)(npl_ts_parser_t *);
typedef bool (*fn_ts_parser_set_language_t)(npl_ts_parser_t *, const npl_ts_language_t *);
typedef npl_ts_tree_t *(*fn_ts_parser_parse_string_t)(npl_ts_parser_t *, const npl_ts_tree_t *, const char *, uint32_t);
typedef void (*fn_ts_tree_delete_t)(npl_ts_tree_t *);
typedef npl_ts_node_t (*fn_ts_tree_root_node_t)(const npl_ts_tree_t *);
typedef const char *(*fn_ts_node_type_t)(npl_ts_node_t);
typedef uint32_t (*fn_ts_node_start_byte_t)(npl_ts_node_t);
typedef uint32_t (*fn_ts_node_end_byte_t)(npl_ts_node_t);
typedef npl_ts_point_t (*fn_ts_node_start_point_t)(npl_ts_node_t);
typedef npl_ts_point_t (*fn_ts_node_end_point_t)(npl_ts_node_t);
typedef uint32_t (*fn_ts_node_child_count_t)(npl_ts_node_t);
typedef npl_ts_node_t (*fn_ts_node_child_t)(npl_ts_node_t, uint32_t);
typedef bool (*fn_ts_node_is_named_t)(npl_ts_node_t);
typedef bool (*fn_ts_node_is_null_t)(npl_ts_node_t);
typedef npl_ts_node_t (*fn_ts_node_parent_t)(npl_ts_node_t);
typedef npl_ts_node_t (*fn_ts_node_descendant_t)(npl_ts_node_t, uint32_t, uint32_t);
typedef const npl_ts_language_t *(*fn_ts_grammar_t)(void);

typedef struct npl_ts_grammar_entry {
    char                    *name;
    npl_dl_handle_t          handle;
    const npl_ts_language_t *lang;
} npl_ts_grammar_entry_t;

typedef struct npl_ts_runtime {
    int             probed;
    int             available;
    npl_dl_handle_t handle;
    char            lib_path[512];

    fn_ts_parser_new_t          parser_new;
    fn_ts_parser_delete_t       parser_delete;
    fn_ts_parser_set_language_t parser_set_language;
    fn_ts_parser_parse_string_t parser_parse_string;
    fn_ts_tree_delete_t         tree_delete;
    fn_ts_tree_root_node_t      tree_root_node;
    fn_ts_node_type_t           node_type;
    fn_ts_node_start_byte_t     node_start_byte;
    fn_ts_node_end_byte_t       node_end_byte;
    fn_ts_node_start_point_t    node_start_point;
    fn_ts_node_end_point_t      node_end_point;
    fn_ts_node_child_count_t    node_child_count;
    fn_ts_node_child_t          node_child;
    fn_ts_node_is_named_t       node_is_named;
    fn_ts_node_is_null_t        node_is_null;
    fn_ts_node_parent_t         node_parent;
    fn_ts_node_descendant_t     node_descendant;

    npl_ts_grammar_entry_t *grammars;
    size_t                  grammar_count;
    size_t                  grammar_cap;
} npl_ts_runtime_t;

static tkmt_static_mutex_t g_ts_lock = TKMT_STATIC_MUTEX_INIT;
static npl_ts_runtime_t    g_ts = {0};

static int
load_sym(npl_dl_handle_t h, const char *name, void *fn_out, size_t fn_sz)
{
    void *sym = npl_dl_sym(h, name);
    if (!sym) return 0;
    memcpy(fn_out, &sym, fn_sz);
    return 1;
}

static int
try_load_lib(const char *path)
{
    if (!path || !path[0]) return 0;
    npl_dl_handle_t h = npl_dl_open(path);
    if (!h) return 0;

    npl_ts_runtime_t tmp;
    memset(&tmp, 0, sizeof(tmp));
    int ok = 1;
    ok &= load_sym(h, "ts_parser_new", &tmp.parser_new, sizeof(tmp.parser_new));
    ok &= load_sym(h, "ts_parser_delete", &tmp.parser_delete, sizeof(tmp.parser_delete));
    ok &= load_sym(h, "ts_parser_set_language", &tmp.parser_set_language, sizeof(tmp.parser_set_language));
    ok &= load_sym(h, "ts_parser_parse_string", &tmp.parser_parse_string, sizeof(tmp.parser_parse_string));
    ok &= load_sym(h, "ts_tree_delete", &tmp.tree_delete, sizeof(tmp.tree_delete));
    ok &= load_sym(h, "ts_tree_root_node", &tmp.tree_root_node, sizeof(tmp.tree_root_node));
    ok &= load_sym(h, "ts_node_type", &tmp.node_type, sizeof(tmp.node_type));
    ok &= load_sym(h, "ts_node_start_byte", &tmp.node_start_byte, sizeof(tmp.node_start_byte));
    ok &= load_sym(h, "ts_node_end_byte", &tmp.node_end_byte, sizeof(tmp.node_end_byte));
    ok &= load_sym(h, "ts_node_start_point", &tmp.node_start_point, sizeof(tmp.node_start_point));
    ok &= load_sym(h, "ts_node_end_point", &tmp.node_end_point, sizeof(tmp.node_end_point));
    ok &= load_sym(h, "ts_node_child_count", &tmp.node_child_count, sizeof(tmp.node_child_count));
    ok &= load_sym(h, "ts_node_child", &tmp.node_child, sizeof(tmp.node_child));
    ok &= load_sym(h, "ts_node_is_named", &tmp.node_is_named, sizeof(tmp.node_is_named));
    ok &= load_sym(h, "ts_node_is_null", &tmp.node_is_null, sizeof(tmp.node_is_null));
    ok &= load_sym(h, "ts_node_parent", &tmp.node_parent, sizeof(tmp.node_parent));
    ok &= load_sym(h, "ts_node_descendant_for_byte_range", &tmp.node_descendant, sizeof(tmp.node_descendant));

    if (!ok) {
        npl_dl_close(h);
        return 0;
    }

    /* Smoke-verify parser allocation & teardown */
    npl_ts_parser_t *p = tmp.parser_new();
    if (!p) {
        npl_dl_close(h);
        return 0;
    }
    tmp.parser_delete(p);

    g_ts.handle              = h;
    g_ts.parser_new          = tmp.parser_new;
    g_ts.parser_delete       = tmp.parser_delete;
    g_ts.parser_set_language = tmp.parser_set_language;
    g_ts.parser_parse_string = tmp.parser_parse_string;
    g_ts.tree_delete         = tmp.tree_delete;
    g_ts.tree_root_node      = tmp.tree_root_node;
    g_ts.node_type           = tmp.node_type;
    g_ts.node_start_byte     = tmp.node_start_byte;
    g_ts.node_end_byte       = tmp.node_end_byte;
    g_ts.node_start_point    = tmp.node_start_point;
    g_ts.node_end_point      = tmp.node_end_point;
    g_ts.node_child_count    = tmp.node_child_count;
    g_ts.node_child          = tmp.node_child;
    g_ts.node_is_named       = tmp.node_is_named;
    g_ts.node_is_null        = tmp.node_is_null;
    g_ts.node_parent         = tmp.node_parent;
    g_ts.node_descendant     = tmp.node_descendant;

    size_t plen = strlen(path);
    if (plen >= sizeof(g_ts.lib_path)) plen = sizeof(g_ts.lib_path) - 1;
    memcpy(g_ts.lib_path, path, plen);
    g_ts.lib_path[plen] = '\0';
    g_ts.available = 1;
    return 1;
}

static void
ensure_probed_locked(void)
{
    if (g_ts.probed) return;
    g_ts.probed = 1;

    const char *env_path = getenv("NEOPERL_TREESITTER_LIB");
    if (env_path && try_load_lib(env_path)) return;

#if defined(_WIN32)
    static const char *const candidates[] = {
        "libtree-sitter.dll",
        "tree-sitter.dll",
        NULL
    };
#elif defined(__APPLE__)
    static const char *const candidates[] = {
        "/opt/homebrew/opt/tree-sitter/lib/libtree-sitter.dylib",
        "/opt/homebrew/lib/libtree-sitter.dylib",
        "/usr/local/lib/libtree-sitter.dylib",
        "libtree-sitter.dylib",
        "libtree-sitter.0.dylib",
        NULL
    };
#else
    static const char *const candidates[] = {
        "libtree-sitter.so.0",
        "libtree-sitter.so",
        "/usr/lib/libtree-sitter.so.0",
        "/usr/lib/libtree-sitter.so",
        "/usr/lib64/libtree-sitter.so.0",
        "/usr/lib64/libtree-sitter.so",
        "/usr/lib/x86_64-linux-gnu/libtree-sitter.so.0",
        "/usr/lib/powerpc64le-linux-gnu/libtree-sitter.so.0",
        "/usr/lib/aarch64-linux-gnu/libtree-sitter.so.0",
        NULL
    };
#endif

    for (size_t i = 0; candidates[i] != NULL; i++) {
        if (try_load_lib(candidates[i])) return;
    }
}

int
npl_ts_available(void)
{
    tkmt_static_mutex_lock(&g_ts_lock);
    ensure_probed_locked();
    int avail = g_ts.available;
    tkmt_static_mutex_unlock(&g_ts_lock);
    return avail;
}

const char *
npl_ts_library_path(void)
{
    tkmt_static_mutex_lock(&g_ts_lock);
    ensure_probed_locked();
    const char *p = g_ts.available ? g_ts.lib_path : "";
    tkmt_static_mutex_unlock(&g_ts_lock);
    return p;
}

static const npl_ts_language_t *
find_grammar_locked(const char *lang_name)
{
    if (!lang_name) return NULL;
    for (size_t i = 0; i < g_ts.grammar_count; i++) {
        if (strcmp(g_ts.grammars[i].name, lang_name) == 0) {
            return g_ts.grammars[i].lang;
        }
    }
    return NULL;
}

int
npl_ts_load_grammar(const char *lang_name, const char *lib_path, const char *symbol_name)
{
    if (!lang_name || !lang_name[0] || !lib_path || !lib_path[0]) return 0;

    tkmt_static_mutex_lock(&g_ts_lock);
    ensure_probed_locked();
    if (!g_ts.available) {
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }
    if (find_grammar_locked(lang_name) != NULL) {
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 1;
    }

    npl_dl_handle_t h = npl_dl_open(lib_path);
    if (!h) {
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }

    char sym_buf[128];
    const char *sym = symbol_name;
    if (!sym || !sym[0]) {
        (void)snprintf(sym_buf, sizeof(sym_buf), "tree_sitter_%s", lang_name);
        sym = sym_buf;
    }

    fn_ts_grammar_t fn = NULL;
    if (!load_sym(h, sym, &fn, sizeof(fn)) || !fn) {
        npl_dl_close(h);
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }

    const npl_ts_language_t *lang = fn();
    if (!lang) {
        npl_dl_close(h);
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }

    if (g_ts.grammar_count >= g_ts.grammar_cap) {
        size_t ncap = g_ts.grammar_cap ? g_ts.grammar_cap * 2 : 8;
        npl_ts_grammar_entry_t *ng = (npl_ts_grammar_entry_t *)realloc(
            g_ts.grammars, ncap * sizeof(npl_ts_grammar_entry_t));
        if (!ng) {
            npl_dl_close(h);
            tkmt_static_mutex_unlock(&g_ts_lock);
            return 0;
        }
        g_ts.grammars = ng;
        g_ts.grammar_cap = ncap;
    }

    size_t nlen = strlen(lang_name);
    char *nc = (char *)malloc(nlen + 1);
    if (!nc) {
        npl_dl_close(h);
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }
    memcpy(nc, lang_name, nlen + 1);

    npl_ts_grammar_entry_t *e = &g_ts.grammars[g_ts.grammar_count++];
    e->name = nc;
    e->handle = h;
    e->lang = lang;

    tkmt_static_mutex_unlock(&g_ts_lock);
    return 1;
}

int
npl_ts_has_grammar(const char *lang_name)
{
    tkmt_static_mutex_lock(&g_ts_lock);
    ensure_probed_locked();
    int has = (g_ts.available && find_grammar_locked(lang_name) != NULL) ? 1 : 0;
    tkmt_static_mutex_unlock(&g_ts_lock);
    return has;
}

static int
node_list_push(npl_ts_node_list_t *list, npl_ts_node_t node)
{
    if (list->count >= list->cap) {
        size_t ncap = list->cap ? list->cap * 2 : 32;
        npl_ts_node_info_t *ni = (npl_ts_node_info_t *)realloc(
            list->items, ncap * sizeof(npl_ts_node_info_t));
        if (!ni) return 0;
        list->items = ni;
        list->cap = ncap;
    }
    const char *t = g_ts.node_type(node);
    size_t tlen = t ? strlen(t) : 0;
    char *tc = (char *)malloc(tlen + 1);
    if (!tc) return 0;
    if (tlen > 0) memcpy(tc, t, tlen);
    tc[tlen] = '\0';

    npl_ts_point_t sp = g_ts.node_start_point(node);
    npl_ts_point_t ep = g_ts.node_end_point(node);

    npl_ts_node_info_t *info = &list->items[list->count++];
    info->type = tc;
    info->start_byte = g_ts.node_start_byte(node);
    info->end_byte = g_ts.node_end_byte(node);
    info->start_row = sp.row;
    info->start_col = sp.column;
    info->end_row = ep.row;
    info->end_col = ep.column;
    info->is_named = g_ts.node_is_named(node) ? 1 : 0;
    return 1;
}

static void
walk_preorder(npl_ts_node_t node, npl_ts_node_list_t *out, size_t max_nodes, int depth)
{
    if (depth > 128 || out->count >= max_nodes) return;
    if (g_ts.node_is_null(node)) return;
    if (!node_list_push(out, node)) return;

    uint32_t nch = g_ts.node_child_count(node);
    for (uint32_t i = 0; i < nch && out->count < max_nodes; i++) {
        npl_ts_node_t ch = g_ts.node_child(node, i);
        walk_preorder(ch, out, max_nodes, depth + 1);
    }
}

int
npl_ts_parse_nodes(const char *lang_name, const char *src, size_t len,
                   size_t max_nodes, npl_ts_node_list_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!lang_name || !src) return 0;
    if (max_nodes == 0) max_nodes = 4096;

    tkmt_static_mutex_lock(&g_ts_lock);
    ensure_probed_locked();
    const npl_ts_language_t *lang = g_ts.available ? find_grammar_locked(lang_name) : NULL;
    if (!lang) {
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }

    npl_ts_parser_t *parser = g_ts.parser_new();
    if (!parser || !g_ts.parser_set_language(parser, lang)) {
        if (parser) g_ts.parser_delete(parser);
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }

    npl_ts_tree_t *tree = g_ts.parser_parse_string(parser, NULL, src, (uint32_t)len);
    if (tree) {
        npl_ts_node_t root = g_ts.tree_root_node(tree);
        walk_preorder(root, out, max_nodes, 0);
        g_ts.tree_delete(tree);
    }
    g_ts.parser_delete(parser);
    tkmt_static_mutex_unlock(&g_ts_lock);
    return tree ? 1 : 0;
}

int
npl_ts_node_at(const char *lang_name, const char *src, size_t len,
               uint32_t byte_offset, npl_ts_node_list_t *out_chain)
{
    memset(out_chain, 0, sizeof(*out_chain));
    if (!lang_name || !src) return 0;

    tkmt_static_mutex_lock(&g_ts_lock);
    ensure_probed_locked();
    const npl_ts_language_t *lang = g_ts.available ? find_grammar_locked(lang_name) : NULL;
    if (!lang) {
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }

    npl_ts_parser_t *parser = g_ts.parser_new();
    if (!parser || !g_ts.parser_set_language(parser, lang)) {
        if (parser) g_ts.parser_delete(parser);
        tkmt_static_mutex_unlock(&g_ts_lock);
        return 0;
    }

    npl_ts_tree_t *tree = g_ts.parser_parse_string(parser, NULL, src, (uint32_t)len);
    if (tree) {
        npl_ts_node_t root = g_ts.tree_root_node(tree);
        npl_ts_node_t cur = g_ts.node_descendant(root, byte_offset, byte_offset);
        int guard = 0;
        while (!g_ts.node_is_null(cur) && guard++ < 64) {
            if (g_ts.node_is_named(cur)) {
                (void)node_list_push(out_chain, cur);
            }
            cur = g_ts.node_parent(cur);
        }
        g_ts.tree_delete(tree);
    }
    g_ts.parser_delete(parser);
    tkmt_static_mutex_unlock(&g_ts_lock);
    return tree ? 1 : 0;
}

void
npl_ts_node_list_free(npl_ts_node_list_t *list)
{
    if (!list) return;
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i].type);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->cap = 0;
}
