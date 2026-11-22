/*
 * c/treesitter_bridge.h - Runtime dlopen(libtree-sitter) bridge (zero link dep)
 */
#ifndef NPL_TREESITTER_BRIDGE_H
#define NPL_TREESITTER_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct npl_ts_node_info {
    char    *type;
    uint32_t start_byte;
    uint32_t end_byte;
    uint32_t start_row;
    uint32_t start_col;
    uint32_t end_row;
    uint32_t end_col;
    int      is_named;
} npl_ts_node_info_t;

typedef struct npl_ts_node_list {
    npl_ts_node_info_t *items;
    size_t              count;
    size_t              cap;
} npl_ts_node_list_t;

int         npl_ts_available(void);
const char *npl_ts_library_path(void);

int npl_ts_load_grammar(const char *lang_name, const char *lib_path, const char *symbol_name);
int npl_ts_has_grammar(const char *lang_name);

int  npl_ts_parse_nodes(const char *lang_name, const char *src, size_t len,
                        size_t max_nodes, npl_ts_node_list_t *out);
int  npl_ts_node_at(const char *lang_name, const char *src, size_t len,
                    uint32_t byte_offset, npl_ts_node_list_t *out_chain);
void npl_ts_node_list_free(npl_ts_node_list_t *list);

#ifdef __cplusplus
}
#endif

#endif /* NPL_TREESITTER_BRIDGE_H */
