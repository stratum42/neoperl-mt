/*
 * c/buffer.c - Zero-copy mmap piece-table with SIMD line indexing,
 *              branching undo tree, and byte-anchored extmarks
 */
#if !defined(_WIN32) && !defined(__APPLE__)
#  if !defined(_GNU_SOURCE)
#    define _GNU_SOURCE
#  endif
#endif

#define NPL_ENABLE_ALTIVEC 1
#include "power_arch.h"
#include "buffer.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <fcntl.h>
#  include <sys/mman.h>
#  include <sys/stat.h>
#  include <unistd.h>
#endif

#if !defined(_WIN32) && !NPL_HAVE_VSX_INTRINSICS
#  if defined(__aarch64__)
#    include <arm_neon.h>
#  elif defined(__SSE2__)
#    include <emmintrin.h>
#  endif
#endif

typedef struct npl_piece {
    uint8_t is_add;
    size_t  start;
    size_t  len;
} npl_piece_t;

typedef struct npl_edit_op {
    uint8_t is_insert;
    size_t  offset;
    char   *data;
    size_t  len;
} npl_edit_op_t;

typedef struct npl_undo_node {
    uint64_t       seq;
    int64_t        timestamp;
    int            parent;
    int           *children;
    size_t         child_count;
    size_t         child_cap;
    int            last_child;
    npl_edit_op_t *ops;
    size_t         op_count;
    size_t         op_cap;
} npl_undo_node_t;

typedef struct npl_extmark {
    uint64_t  id;
    char     *ns;
    size_t    start_byte;
    size_t    end_byte;
    uint8_t   has_end;
    uint8_t   right_gravity;
    uint8_t   end_right_gravity;
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
    uint8_t   virt_lines_above;
} npl_extmark_t;

struct npl_buf {
    char   *orig_data;
    size_t  orig_len;
    int     orig_is_mmap;

    char   *add_data;
    size_t  add_len;
    size_t  add_cap;

    npl_piece_t *pieces;
    size_t       piece_count;
    size_t       piece_cap;
    size_t       total_bytes;

    size_t *line_starts;
    size_t  line_count;
    size_t  line_cap;
    int     lines_dirty;

    /* Branching undo tree */
    npl_undo_node_t *undo_nodes;
    size_t           undo_count;
    size_t           undo_cap;
    int              undo_cur;
    uint64_t         next_undo_seq;
    int              group_depth;
    int              group_node;

    /* Byte-anchored extmarks */
    npl_extmark_t *marks;
    size_t         mark_count;
    size_t         mark_cap;
    uint64_t       next_mark_id;

    uint64_t revision;
};

static char *
xstrdup_opt(const char *s)
{
    if (!s) return NULL;
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

static char **
xstrdup_arr(const char *const *arr, size_t count)
{
    if (!arr || count == 0) return NULL;
    char **out = (char **)calloc(count, sizeof(char *));
    if (!out) return NULL;
    for (size_t i = 0; i < count; i++) {
        out[i] = xstrdup_opt(arr[i] ? arr[i] : "");
        if (!out[i]) {
            for (size_t j = 0; j < i; j++) free(out[j]);
            free(out);
            return NULL;
        }
    }
    return out;
}

static void
free_str_arr(char **arr, size_t count)
{
    if (!arr) return;
    for (size_t i = 0; i < count; i++) free(arr[i]);
    free(arr);
}

static void
extmark_clear_fields(npl_extmark_t *m)
{
    free(m->ns);
    free(m->hl_group);
    free(m->sign_text);
    free(m->sign_hl);
    free(m->virt_text);
    free(m->virt_hl);
    free(m->virt_pos);
    free_str_arr(m->virt_lines, m->virt_line_count);
    free_str_arr(m->virt_lines_hl, m->virt_line_hl_count);
    memset(m, 0, sizeof(*m));
}

static int
pieces_reserve(npl_buf_t *b, size_t need)
{
    if (need <= b->piece_cap) return 1;
    size_t ncap = b->piece_cap ? b->piece_cap * 2 : 16;
    while (ncap < need) ncap *= 2;
    npl_piece_t *np = (npl_piece_t *)realloc(b->pieces, ncap * sizeof(npl_piece_t));
    if (!np) return 0;
    b->pieces = np;
    b->piece_cap = ncap;
    return 1;
}

static int
add_buf_append(npl_buf_t *b, const char *data, size_t len, size_t *out_start)
{
    if (b->add_len + len > b->add_cap) {
        size_t ncap = b->add_cap ? b->add_cap * 2 : 4096;
        while (ncap < b->add_len + len) ncap *= 2;
        char *na = (char *)realloc(b->add_data, ncap);
        if (!na) return 0;
        b->add_data = na;
        b->add_cap = ncap;
    }
    *out_start = b->add_len;
    if (len > 0) {
        memcpy(b->add_data + b->add_len, data, len);
        b->add_len += len;
    }
    return 1;
}

static inline int
line_starts_push(npl_buf_t *b, size_t off)
{
    if (b->line_count >= b->line_cap) {
        size_t ncap = b->line_cap ? b->line_cap * 2 : 64;
        size_t *nl = (size_t *)realloc(b->line_starts, ncap * sizeof(size_t));
        if (!nl) return 0;
        b->line_starts = nl;
        b->line_cap = ncap;
    }
    b->line_starts[b->line_count++] = off;
    return 1;
}

/*
 * Scan a piece slice for '\n' bytes using POWER8+ VSX, ARM64 NEON, x86_64 SSE2,
 * or scalar memchr (bit-identical under PERL_FORCE_SCALAR=1).
 */
static int
scan_newlines_slice(npl_buf_t *b, const uint8_t *data, size_t len,
                    size_t base_offset, int force_scalar)
{
    size_t i = 0;

    if (!force_scalar && len >= 16) {
#if NPL_HAVE_VSX_INTRINSICS
        const __vector unsigned char nl_vec = vec_splats((unsigned char)'\n');
        while (i + 16 <= len) {
            __vector unsigned char chunk = vec_xl(0, data + i);
            if (vec_any_eq(chunk, nl_vec)) {
                for (size_t k = 0; k < 16; k++) {
                    if (data[i + k] == (uint8_t)'\n') {
                        if (!line_starts_push(b, base_offset + i + k + 1)) return 0;
                    }
                }
            }
            i += 16;
        }
#elif !defined(_WIN32) && defined(__aarch64__)
        const uint8x16_t nl_vec = vdupq_n_u8((uint8_t)'\n');
        while (i + 16 <= len) {
            uint8x16_t chunk = vld1q_u8(data + i);
            uint8x16_t eq = vceqq_u8(chunk, nl_vec);
            if (vmaxvq_u8(eq) != 0) {
                for (size_t k = 0; k < 16; k++) {
                    if (data[i + k] == (uint8_t)'\n') {
                        if (!line_starts_push(b, base_offset + i + k + 1)) return 0;
                    }
                }
            }
            i += 16;
        }
#elif !defined(_WIN32) && defined(__SSE2__)
        const __m128i nl_vec = _mm_set1_epi8('\n');
        while (i + 16 <= len) {
            __m128i chunk = _mm_loadu_si128((const __m128i *)(const void *)(data + i));
            unsigned mask = (unsigned)_mm_movemask_epi8(_mm_cmpeq_epi8(chunk, nl_vec));
            while (mask != 0u) {
                unsigned bit = (unsigned)__builtin_ctz(mask);
                if (!line_starts_push(b, base_offset + i + (size_t)bit + 1)) return 0;
                mask &= mask - 1u;
            }
            i += 16;
        }
#endif
    }

    while (i < len) {
        const uint8_t *hit = (const uint8_t *)memchr(data + i, '\n', len - i);
        if (!hit) break;
        size_t pos = (size_t)(hit - data);
        if (!line_starts_push(b, base_offset + pos + 1)) return 0;
        i = pos + 1;
    }
    return 1;
}

static void
ensure_lines(npl_buf_t *b)
{
    if (!b->lines_dirty) return;
    b->line_count = 0;
    if (!line_starts_push(b, 0)) return;

    int force_scalar = npl_arch_force_scalar();
    size_t base = 0;
    for (size_t pi = 0; pi < b->piece_count; pi++) {
        const npl_piece_t *p = &b->pieces[pi];
        const uint8_t *src = (const uint8_t *)(p->is_add ? b->add_data : b->orig_data) + p->start;
        if (!scan_newlines_slice(b, src, p->len, base, force_scalar)) {
            break;
        }
        base += p->len;
    }
    b->lines_dirty = 0;
}

static int
init_undo_root(npl_buf_t *b)
{
    b->undo_cap = 16;
    b->undo_nodes = (npl_undo_node_t *)calloc(b->undo_cap, sizeof(npl_undo_node_t));
    if (!b->undo_nodes) return 0;
    b->undo_count = 1;
    b->undo_nodes[0].seq = 0;
    b->undo_nodes[0].timestamp = (int64_t)time(NULL);
    b->undo_nodes[0].parent = -1;
    b->undo_nodes[0].last_child = -1;
    b->undo_cur = 0;
    b->next_undo_seq = 1;
    b->group_depth = 0;
    b->group_node = -1;
    return 1;
}

static npl_buf_t *
alloc_buf_base(void)
{
    npl_buf_t *b = (npl_buf_t *)calloc(1, sizeof(npl_buf_t));
    if (!b) return NULL;
    b->lines_dirty = 1;
    b->next_mark_id = 1;
    if (!init_undo_root(b)) {
        free(b);
        return NULL;
    }
    return b;
}

npl_buf_t *
npl_buf_new(void)
{
    return alloc_buf_base();
}

npl_buf_t *
npl_buf_from_string(const char *data, size_t len)
{
    npl_buf_t *b = alloc_buf_base();
    if (!b) return NULL;
    if (len > 0 && data) {
        b->orig_data = (char *)malloc(len);
        if (!b->orig_data) {
            npl_buf_free(b);
            return NULL;
        }
        memcpy(b->orig_data, data, len);
        b->orig_len = len;
        b->orig_is_mmap = 0;
        if (!pieces_reserve(b, 1)) {
            npl_buf_free(b);
            return NULL;
        }
        b->pieces[0].is_add = 0;
        b->pieces[0].start = 0;
        b->pieces[0].len = len;
        b->piece_count = 1;
        b->total_bytes = len;
    }
    b->lines_dirty = 1;
    return b;
}

npl_buf_t *
npl_buf_open_file(const char *path, char *errbuf, size_t errsz)
{
    if (!path) {
        if (errbuf && errsz) (void)snprintf(errbuf, errsz, "NULL path");
        return NULL;
    }

#if defined(_WIN32)
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        if (errbuf && errsz) (void)snprintf(errbuf, errsz, "Cannot open file: %s", strerror(errno));
        return NULL;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        if (errbuf && errsz) (void)snprintf(errbuf, errsz, "Seek failed");
        return NULL;
    }
    long fsz = ftell(fp);
    if (fsz < 0) fsz = 0;
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return NULL;
    }
    npl_buf_t *b = alloc_buf_base();
    if (!b) {
        fclose(fp);
        return NULL;
    }
    if (fsz > 0) {
        b->orig_data = (char *)malloc((size_t)fsz);
        if (!b->orig_data) {
            fclose(fp);
            npl_buf_free(b);
            return NULL;
        }
        size_t got = fread(b->orig_data, 1, (size_t)fsz, fp);
        b->orig_len = got;
        b->orig_is_mmap = 0;
        if (got > 0) {
            if (!pieces_reserve(b, 1)) {
                fclose(fp);
                npl_buf_free(b);
                return NULL;
            }
            b->pieces[0].is_add = 0;
            b->pieces[0].start = 0;
            b->pieces[0].len = got;
            b->piece_count = 1;
            b->total_bytes = got;
        }
    }
    fclose(fp);
    b->lines_dirty = 1;
    return b;
#else
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        if (errbuf && errsz) {
            (void)snprintf(errbuf, errsz, "open failed: %s", strerror(errno));
        }
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int saved = errno;
        close(fd);
        if (errbuf && errsz) {
            (void)snprintf(errbuf, errsz, "fstat failed: %s", strerror(saved));
        }
        return NULL;
    }
    npl_buf_t *b = alloc_buf_base();
    if (!b) {
        close(fd);
        return NULL;
    }
    if (st.st_size > 0) {
        size_t fsz = (size_t)st.st_size;
        /* Respect dynamic OS page size (e.g. 64 KiB on Linux ppc64le) */
        size_t pg = npl_page_size();
        (void)pg;
        void *map = mmap(NULL, fsz, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map != MAP_FAILED) {
#  ifdef MADV_SEQUENTIAL
            if (fsz >= pg) {
                (void)madvise(map, fsz, MADV_SEQUENTIAL);
            }
#  endif
            b->orig_data = (char *)map;
            b->orig_len = fsz;
            b->orig_is_mmap = 1;
        } else {
            /* Fallback for non-mmapable files (pipes, procfs, etc.) */
            char *heap = (char *)malloc(fsz);
            if (!heap) {
                close(fd);
                npl_buf_free(b);
                return NULL;
            }
            size_t total = 0;
            while (total < fsz) {
                ssize_t r = read(fd, heap + total, fsz - total);
                if (r <= 0) break;
                total += (size_t)r;
            }
            b->orig_data = heap;
            b->orig_len = total;
            b->orig_is_mmap = 0;
        }
        if (b->orig_len > 0) {
            if (!pieces_reserve(b, 1)) {
                close(fd);
                npl_buf_free(b);
                return NULL;
            }
            b->pieces[0].is_add = 0;
            b->pieces[0].start = 0;
            b->pieces[0].len = b->orig_len;
            b->piece_count = 1;
            b->total_bytes = b->orig_len;
        }
    }
    close(fd);
    b->lines_dirty = 1;
    return b;
#endif
}

void
npl_buf_free(npl_buf_t *b)
{
    if (!b) return;
    if (b->orig_data) {
#if !defined(_WIN32)
        if (b->orig_is_mmap) {
            munmap(b->orig_data, b->orig_len);
        } else {
            free(b->orig_data);
        }
#else
        free(b->orig_data);
#endif
    }
    free(b->add_data);
    free(b->pieces);
    free(b->line_starts);

    if (b->undo_nodes) {
        for (size_t i = 0; i < b->undo_count; i++) {
            npl_undo_node_t *n = &b->undo_nodes[i];
            free(n->children);
            for (size_t j = 0; j < n->op_count; j++) {
                free(n->ops[j].data);
            }
            free(n->ops);
        }
        free(b->undo_nodes);
    }

    if (b->marks) {
        for (size_t i = 0; i < b->mark_count; i++) {
            extmark_clear_fields(&b->marks[i]);
        }
        free(b->marks);
    }
    free(b);
}

/* Extmark gravity shifts */
static void
extmarks_on_insert(npl_buf_t *b, size_t offset, size_t len)
{
    if (len == 0 || b->mark_count == 0) return;
    for (size_t i = 0; i < b->mark_count; i++) {
        npl_extmark_t *m = &b->marks[i];
        if (m->start_byte > offset || (m->start_byte == offset && m->right_gravity)) {
            m->start_byte += len;
        }
        if (m->has_end) {
            if (m->end_byte > offset || (m->end_byte == offset && m->end_right_gravity)) {
                m->end_byte += len;
            }
            if (m->end_byte < m->start_byte) {
                m->end_byte = m->start_byte;
            }
        }
    }
}

static void
extmarks_on_delete(npl_buf_t *b, size_t offset, size_t len)
{
    if (len == 0 || b->mark_count == 0) return;
    size_t end = offset + len;
    for (size_t i = 0; i < b->mark_count; i++) {
        npl_extmark_t *m = &b->marks[i];
        if (m->start_byte >= end) {
            m->start_byte -= len;
        } else if (m->start_byte > offset) {
            m->start_byte = offset;
        }
        if (m->has_end) {
            if (m->end_byte >= end) {
                m->end_byte -= len;
            } else if (m->end_byte > offset) {
                m->end_byte = offset;
            }
            if (m->end_byte < m->start_byte) {
                m->end_byte = m->start_byte;
            }
        }
    }
}

/* Raw piece-table insert (no undo recording) */
static int
raw_insert(npl_buf_t *b, size_t offset, const char *data, size_t len)
{
    if (len == 0) return 1;
    if (offset > b->total_bytes) offset = b->total_bytes;

    size_t add_start = 0;
    if (!add_buf_append(b, data, len, &add_start)) return 0;

    /* Find target piece */
    size_t acc = 0;
    size_t pi = 0;
    while (pi < b->piece_count && acc + b->pieces[pi].len < offset) {
        acc += b->pieces[pi].len;
        pi++;
    }

    if (pi == b->piece_count) {
        /* Append at end; try coalescing with last add piece */
        if (b->piece_count > 0) {
            npl_piece_t *last = &b->pieces[b->piece_count - 1];
            if (last->is_add && last->start + last->len == add_start) {
                last->len += len;
                b->total_bytes += len;
                b->lines_dirty = 1;
                b->revision++;
                extmarks_on_insert(b, offset, len);
                return 1;
            }
        }
        if (!pieces_reserve(b, b->piece_count + 1)) return 0;
        b->pieces[b->piece_count].is_add = 1;
        b->pieces[b->piece_count].start = add_start;
        b->pieces[b->piece_count].len = len;
        b->piece_count++;
    } else {
        size_t inner = offset - acc;
        if (inner == 0) {
            if (!pieces_reserve(b, b->piece_count + 1)) return 0;
            memmove(&b->pieces[pi + 1], &b->pieces[pi],
                    (b->piece_count - pi) * sizeof(npl_piece_t));
            b->pieces[pi].is_add = 1;
            b->pieces[pi].start = add_start;
            b->pieces[pi].len = len;
            b->piece_count++;
        } else if (inner == b->pieces[pi].len) {
            if (b->pieces[pi].is_add && b->pieces[pi].start + b->pieces[pi].len == add_start) {
                b->pieces[pi].len += len;
            } else {
                if (!pieces_reserve(b, b->piece_count + 1)) return 0;
                memmove(&b->pieces[pi + 2], &b->pieces[pi + 1],
                        (b->piece_count - pi - 1) * sizeof(npl_piece_t));
                b->pieces[pi + 1].is_add = 1;
                b->pieces[pi + 1].start = add_start;
                b->pieces[pi + 1].len = len;
                b->piece_count++;
            }
        } else {
            /* Split piece pi into [left, inserted, right] */
            if (!pieces_reserve(b, b->piece_count + 2)) return 0;
            npl_piece_t orig = b->pieces[pi];
            memmove(&b->pieces[pi + 3], &b->pieces[pi + 1],
                    (b->piece_count - pi - 1) * sizeof(npl_piece_t));
            b->pieces[pi].is_add = orig.is_add;
            b->pieces[pi].start = orig.start;
            b->pieces[pi].len = inner;

            b->pieces[pi + 1].is_add = 1;
            b->pieces[pi + 1].start = add_start;
            b->pieces[pi + 1].len = len;

            b->pieces[pi + 2].is_add = orig.is_add;
            b->pieces[pi + 2].start = orig.start + inner;
            b->pieces[pi + 2].len = orig.len - inner;

            b->piece_count += 2;
        }
    }

    b->total_bytes += len;
    b->lines_dirty = 1;
    b->revision++;
    extmarks_on_insert(b, offset, len);
    return 1;
}

/* Raw piece-table delete (no undo recording) */
static int
raw_delete(npl_buf_t *b, size_t offset, size_t len)
{
    if (len == 0 || offset >= b->total_bytes) return 1;
    if (offset + len > b->total_bytes) len = b->total_bytes - offset;

    size_t del_end = offset + len;
    size_t acc = 0;
    size_t out_i = 0;

    /* Worst case: deletion lies strictly inside a single piece -> +1 piece */
    if (!pieces_reserve(b, b->piece_count + 1)) return 0;

    npl_piece_t *tmp = (npl_piece_t *)malloc((b->piece_count + 1) * sizeof(npl_piece_t));
    if (!tmp) return 0;

    for (size_t i = 0; i < b->piece_count; i++) {
        npl_piece_t p = b->pieces[i];
        size_t p_start = acc;
        size_t p_end = acc + p.len;
        acc = p_end;

        if (p_end <= offset || p_start >= del_end) {
            tmp[out_i++] = p;
        } else {
            if (p_start < offset) {
                npl_piece_t left = p;
                left.len = offset - p_start;
                tmp[out_i++] = left;
            }
            if (p_end > del_end) {
                npl_piece_t right = p;
                size_t cut = del_end - p_start;
                right.start += cut;
                right.len = p_end - del_end;
                tmp[out_i++] = right;
            }
        }
    }

    memcpy(b->pieces, tmp, out_i * sizeof(npl_piece_t));
    free(tmp);
    b->piece_count = out_i;
    b->total_bytes -= len;
    b->lines_dirty = 1;
    b->revision++;
    extmarks_on_delete(b, offset, len);
    return 1;
}

/* Undo tree helpers */
static int
undo_create_child(npl_buf_t *b, int parent_idx)
{
    if (b->undo_count >= b->undo_cap) {
        size_t ncap = b->undo_cap * 2;
        npl_undo_node_t *nn = (npl_undo_node_t *)realloc(
            b->undo_nodes, ncap * sizeof(npl_undo_node_t));
        if (!nn) return -1;
        b->undo_nodes = nn;
        b->undo_cap = ncap;
    }
    int idx = (int)b->undo_count++;
    npl_undo_node_t *node = &b->undo_nodes[idx];
    memset(node, 0, sizeof(*node));
    node->seq = b->next_undo_seq++;
    node->timestamp = (int64_t)time(NULL);
    node->parent = parent_idx;
    node->last_child = -1;

    npl_undo_node_t *parent = &b->undo_nodes[parent_idx];
    if (parent->child_count >= parent->child_cap) {
        size_t ncap = parent->child_cap ? parent->child_cap * 2 : 4;
        int *nc = (int *)realloc(parent->children, ncap * sizeof(int));
        if (!nc) return -1;
        parent->children = nc;
        parent->child_cap = ncap;
    }
    parent->children[parent->child_count++] = idx;
    parent->last_child = idx;
    b->undo_cur = idx;
    return idx;
}

static int
undo_record_op(npl_buf_t *b, uint8_t is_insert, size_t offset, const char *data, size_t len)
{
    int target = -1;
    if (b->group_depth > 0 && b->group_node >= 0) {
        target = b->group_node;
    } else {
        target = undo_create_child(b, b->undo_cur);
        if (target < 0) return 0;
        if (b->group_depth > 0) {
            b->group_node = target;
        }
    }

    npl_undo_node_t *node = &b->undo_nodes[target];
    if (node->op_count >= node->op_cap) {
        size_t ncap = node->op_cap ? node->op_cap * 2 : 4;
        npl_edit_op_t *no = (npl_edit_op_t *)realloc(node->ops, ncap * sizeof(npl_edit_op_t));
        if (!no) return 0;
        node->ops = no;
        node->op_cap = ncap;
    }
    char *copy = (char *)malloc(len > 0 ? len : 1);
    if (!copy) return 0;
    if (len > 0 && data) memcpy(copy, data, len);

    npl_edit_op_t *op = &node->ops[node->op_count++];
    op->is_insert = is_insert;
    op->offset = offset;
    op->data = copy;
    op->len = len;
    return 1;
}

static int
apply_node_forward(npl_buf_t *b, int idx)
{
    npl_undo_node_t *node = &b->undo_nodes[idx];
    for (size_t i = 0; i < node->op_count; i++) {
        const npl_edit_op_t *op = &node->ops[i];
        if (op->is_insert) {
            if (!raw_insert(b, op->offset, op->data, op->len)) return 0;
        } else {
            if (!raw_delete(b, op->offset, op->len)) return 0;
        }
    }
    return 1;
}

static int
apply_node_inverse(npl_buf_t *b, int idx)
{
    npl_undo_node_t *node = &b->undo_nodes[idx];
    for (size_t i = node->op_count; i > 0; i--) {
        const npl_edit_op_t *op = &node->ops[i - 1];
        if (op->is_insert) {
            if (!raw_delete(b, op->offset, op->len)) return 0;
        } else {
            if (!raw_insert(b, op->offset, op->data, op->len)) return 0;
        }
    }
    return 1;
}

int
npl_buf_insert(npl_buf_t *b, size_t offset, const char *data, size_t len)
{
    if (!b) return 0;
    if (len == 0) return 1;
    if (offset > b->total_bytes) offset = b->total_bytes;
    if (!raw_insert(b, offset, data, len)) return 0;
    return undo_record_op(b, 1, offset, data, len);
}

int
npl_buf_delete(npl_buf_t *b, size_t offset, size_t len)
{
    if (!b) return 0;
    if (len == 0 || offset >= b->total_bytes) return 1;
    if (offset + len > b->total_bytes) len = b->total_bytes - offset;

    char *saved = (char *)malloc(len);
    if (!saved) return 0;
    size_t copied = npl_buf_copy_range(b, offset, len, saved);
    int ok = raw_delete(b, offset, copied);
    if (ok) {
        ok = undo_record_op(b, 0, offset, saved, copied);
    }
    free(saved);
    return ok;
}

void
npl_buf_begin_group(npl_buf_t *b)
{
    if (!b) return;
    b->group_depth++;
}

void
npl_buf_end_group(npl_buf_t *b)
{
    if (!b) return;
    if (b->group_depth > 0) {
        b->group_depth--;
        if (b->group_depth == 0) {
            b->group_node = -1;
        }
    }
}

int
npl_buf_undo(npl_buf_t *b)
{
    if (!b || b->undo_cur <= 0) return 0;
    b->group_node = -1;
    int cur = b->undo_cur;
    if (!apply_node_inverse(b, cur)) return -1;
    b->undo_cur = b->undo_nodes[cur].parent;
    return 1;
}

int
npl_buf_redo(npl_buf_t *b)
{
    if (!b) return 0;
    int child = b->undo_nodes[b->undo_cur].last_child;
    if (child < 0) return 0;
    b->group_node = -1;
    if (!apply_node_forward(b, child)) return -1;
    b->undo_cur = child;
    return 1;
}

static int
navigate_to_node(npl_buf_t *b, int target_idx)
{
    if (!b || target_idx < 0 || (size_t)target_idx >= b->undo_count) return 0;
    if (target_idx == b->undo_cur) return 0;
    b->group_node = -1;

    /* Mark ancestors of undo_cur */
    uint8_t *anc = (uint8_t *)calloc(b->undo_count, 1);
    if (!anc) return -1;
    for (int x = b->undo_cur; x >= 0; x = b->undo_nodes[x].parent) {
        anc[x] = 1;
    }

    /* Collect path from target up to LCA */
    size_t down_cap = 16;
    size_t down_len = 0;
    int *down = (int *)malloc(down_cap * sizeof(int));
    if (!down) {
        free(anc);
        return -1;
    }
    int lca = target_idx;
    while (lca >= 0 && !anc[lca]) {
        if (down_len >= down_cap) {
            down_cap *= 2;
            int *nd = (int *)realloc(down, down_cap * sizeof(int));
            if (!nd) {
                free(down);
                free(anc);
                return -1;
            }
            down = nd;
        }
        down[down_len++] = lca;
        lca = b->undo_nodes[lca].parent;
    }
    free(anc);

    /* Undo from undo_cur up to lca */
    while (b->undo_cur != lca && b->undo_cur > 0) {
        if (!apply_node_inverse(b, b->undo_cur)) {
            free(down);
            return -1;
        }
        b->undo_cur = b->undo_nodes[b->undo_cur].parent;
    }

    /* Redo from lca down to target_idx */
    for (size_t i = down_len; i > 0; i--) {
        int next_idx = down[i - 1];
        b->undo_nodes[b->undo_cur].last_child = next_idx;
        if (!apply_node_forward(b, next_idx)) {
            free(down);
            return -1;
        }
        b->undo_cur = next_idx;
    }

    free(down);
    return 1;
}

int
npl_buf_undo_older(npl_buf_t *b)
{
    if (!b) return 0;
    uint64_t cur_seq = b->undo_nodes[b->undo_cur].seq;
    int best = -1;
    uint64_t best_seq = 0;
    for (size_t i = 0; i < b->undo_count; i++) {
        uint64_t s = b->undo_nodes[i].seq;
        if (s < cur_seq && (best < 0 || s > best_seq)) {
            best = (int)i;
            best_seq = s;
        }
    }
    if (best < 0) return 0;
    return navigate_to_node(b, best);
}

int
npl_buf_undo_newer(npl_buf_t *b)
{
    if (!b) return 0;
    uint64_t cur_seq = b->undo_nodes[b->undo_cur].seq;
    int best = -1;
    uint64_t best_seq = 0;
    for (size_t i = 0; i < b->undo_count; i++) {
        uint64_t s = b->undo_nodes[i].seq;
        if (s > cur_seq && (best < 0 || s < best_seq)) {
            best = (int)i;
            best_seq = s;
        }
    }
    if (best < 0) return 0;
    return navigate_to_node(b, best);
}

int
npl_buf_undo_goto(npl_buf_t *b, uint64_t seq)
{
    if (!b) return 0;
    for (size_t i = 0; i < b->undo_count; i++) {
        if (b->undo_nodes[i].seq == seq) {
            return navigate_to_node(b, (int)i);
        }
    }
    return 0;
}

int
npl_buf_can_undo(const npl_buf_t *b)
{
    return (b && b->undo_cur > 0) ? 1 : 0;
}

int
npl_buf_can_redo(const npl_buf_t *b)
{
    return (b && b->undo_nodes[b->undo_cur].last_child >= 0) ? 1 : 0;
}

uint64_t
npl_buf_undo_seq(const npl_buf_t *b)
{
    return b ? b->undo_nodes[b->undo_cur].seq : 0;
}

size_t
npl_buf_undo_list(const npl_buf_t *b, npl_undo_info_t **out_list)
{
    if (!b || !out_list) return 0;
    npl_undo_info_t *list = (npl_undo_info_t *)calloc(b->undo_count, sizeof(npl_undo_info_t));
    if (!list) return 0;
    for (size_t i = 0; i < b->undo_count; i++) {
        const npl_undo_node_t *n = &b->undo_nodes[i];
        list[i].seq = n->seq;
        list[i].parent_seq = (n->parent >= 0) ? b->undo_nodes[n->parent].seq : 0;
        list[i].timestamp = n->timestamp;
        list[i].edit_count = n->op_count;
        list[i].is_current = ((int)i == b->undo_cur) ? 1 : 0;
        if (n->child_count > 0) {
            list[i].child_seqs = (uint64_t *)malloc(n->child_count * sizeof(uint64_t));
            if (list[i].child_seqs) {
                for (size_t c = 0; c < n->child_count; c++) {
                    list[i].child_seqs[c] = b->undo_nodes[n->children[c]].seq;
                }
                list[i].child_count = n->child_count;
            }
        }
    }
    *out_list = list;
    return b->undo_count;
}

void
npl_buf_undo_list_free(npl_undo_info_t *list, size_t count)
{
    if (!list) return;
    for (size_t i = 0; i < count; i++) {
        free(list[i].child_seqs);
    }
    free(list);
}

/* Queries */
size_t
npl_buf_line_count(npl_buf_t *b)
{
    if (!b) return 0;
    ensure_lines(b);
    return b->line_count;
}

size_t
npl_buf_byte_length(const npl_buf_t *b)
{
    return b ? b->total_bytes : 0;
}

uint64_t
npl_buf_revision(const npl_buf_t *b)
{
    return b ? b->revision : 0;
}

size_t
npl_buf_copy_range(const npl_buf_t *b, size_t offset, size_t len, char *dst)
{
    if (!b || !dst || len == 0 || offset >= b->total_bytes) return 0;
    if (offset + len > b->total_bytes) len = b->total_bytes - offset;

    size_t acc = 0;
    size_t copied = 0;
    for (size_t i = 0; i < b->piece_count && copied < len; i++) {
        const npl_piece_t *p = &b->pieces[i];
        size_t p_end = acc + p->len;
        if (p_end <= offset) {
            acc = p_end;
            continue;
        }
        size_t p_off = (offset > acc) ? (offset - acc) : 0;
        size_t avail = p->len - p_off;
        size_t take = len - copied;
        if (take > avail) take = avail;
        const char *src = (p->is_add ? b->add_data : b->orig_data) + p->start + p_off;
        memcpy(dst + copied, src, take);
        copied += take;
        acc = p_end;
    }
    return copied;
}

int
npl_buf_line_bounds(npl_buf_t *b, size_t line, size_t *out_start, size_t *out_len)
{
    if (!b) return 0;
    ensure_lines(b);
    if (line >= b->line_count) return 0;
    size_t start = b->line_starts[line];
    size_t end = (line + 1 < b->line_count) ? b->line_starts[line + 1] : b->total_bytes;
    size_t len = (end >= start) ? (end - start) : 0;
    if (len > 0) {
        char tail[2];
        size_t check = (len >= 2) ? 2 : 1;
        npl_buf_copy_range(b, start + len - check, check, tail);
        if (tail[check - 1] == '\n') {
            len--;
            if (len > 0 && check == 2 && tail[0] == '\r') {
                len--;
            }
        }
    }
    if (out_start) *out_start = start;
    if (out_len) *out_len = len;
    return 1;
}

char *
npl_buf_get_line_alloc(npl_buf_t *b, size_t line, size_t *out_len)
{
    size_t start = 0, len = 0;
    if (!npl_buf_line_bounds(b, line, &start, &len)) return NULL;
    char *buf = (char *)malloc(len + 1);
    if (!buf) return NULL;
    if (len > 0) npl_buf_copy_range(b, start, len, buf);
    buf[len] = '\0';
    if (out_len) *out_len = len;
    return buf;
}

size_t
npl_buf_get_line_buf(npl_buf_t *b, size_t line, char *buf, size_t buf_cap)
{
    size_t start = 0, len = 0;
    if (!npl_buf_line_bounds(b, line, &start, &len)) {
        if (buf && buf_cap > 0) buf[0] = '\0';
        return 0;
    }
    if (buf && buf_cap > 0) {
        size_t take = (len < buf_cap - 1) ? len : (buf_cap - 1);
        if (take > 0) npl_buf_copy_range(b, start, take, buf);
        buf[take] = '\0';
    }
    return len;
}

size_t
npl_buf_line_col_to_offset(npl_buf_t *b, size_t line, size_t col)
{
    if (!b) return 0;
    ensure_lines(b);
    if (b->line_count == 0) return 0;
    if (line >= b->line_count) line = b->line_count - 1;
    size_t start = 0, len = 0;
    if (!npl_buf_line_bounds(b, line, &start, &len)) return b->total_bytes;
    if (col > len) col = len;
    return start + col;
}

void
npl_buf_offset_to_line_col(npl_buf_t *b, size_t offset, size_t *out_line, size_t *out_col)
{
    if (!b) {
        if (out_line) *out_line = 0;
        if (out_col) *out_col = 0;
        return;
    }
    ensure_lines(b);
    if (offset > b->total_bytes) offset = b->total_bytes;
    size_t lo = 0, hi = b->line_count;
    while (lo + 1 < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (b->line_starts[mid] <= offset) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    if (out_line) *out_line = lo;
    if (out_col) *out_col = offset - b->line_starts[lo];
}

int
npl_buf_save_file(const npl_buf_t *b, const char *path, char *errbuf, size_t errsz)
{
    if (!b || !path) {
        if (errbuf && errsz) (void)snprintf(errbuf, errsz, "Invalid argument");
        return 0;
    }
    FILE *fp = fopen(path, "wb");
    if (!fp) {
        if (errbuf && errsz) {
            (void)snprintf(errbuf, errsz, "Cannot write file: %s", strerror(errno));
        }
        return 0;
    }
    for (size_t i = 0; i < b->piece_count; i++) {
        const npl_piece_t *p = &b->pieces[i];
        const char *src = (p->is_add ? b->add_data : b->orig_data) + p->start;
        if (p->len > 0 && fwrite(src, 1, p->len, fp) != p->len) {
            int saved = errno;
            fclose(fp);
            if (errbuf && errsz) {
                (void)snprintf(errbuf, errsz, "Write error: %s", strerror(saved));
            }
            return 0;
        }
    }
    if (fclose(fp) != 0) {
        if (errbuf && errsz) {
            (void)snprintf(errbuf, errsz, "Close error: %s", strerror(errno));
        }
        return 0;
    }
    return 1;
}

char *
npl_buf_to_string(const npl_buf_t *b, size_t *out_len)
{
    if (!b) return NULL;
    char *s = (char *)malloc(b->total_bytes + 1);
    if (!s) return NULL;
    if (b->total_bytes > 0) {
        npl_buf_copy_range(b, 0, b->total_bytes, s);
    }
    s[b->total_bytes] = '\0';
    if (out_len) *out_len = b->total_bytes;
    return s;
}

/* Byte-anchored extmarks */
uint64_t
npl_buf_set_extmark(npl_buf_t *b, const char *ns, const npl_extmark_spec_t *spec)
{
    if (!b || !spec) return 0;
    const char *ns_name = (ns && ns[0]) ? ns : "default";

    size_t idx = b->mark_count;
    uint64_t id = spec->id;
    if (id != 0) {
        for (size_t i = 0; i < b->mark_count; i++) {
            if (b->marks[i].id == id && strcmp(b->marks[i].ns, ns_name) == 0) {
                idx = i;
                break;
            }
        }
    } else {
        id = b->next_mark_id++;
    }
    if (id >= b->next_mark_id) {
        b->next_mark_id = id + 1;
    }

    if (idx == b->mark_count) {
        if (b->mark_count >= b->mark_cap) {
            size_t ncap = b->mark_cap ? b->mark_cap * 2 : 16;
            npl_extmark_t *nm = (npl_extmark_t *)realloc(b->marks, ncap * sizeof(npl_extmark_t));
            if (!nm) return 0;
            b->marks = nm;
            b->mark_cap = ncap;
        }
        memset(&b->marks[idx], 0, sizeof(npl_extmark_t));
        b->mark_count++;
    } else {
        extmark_clear_fields(&b->marks[idx]);
    }

    npl_extmark_t *m = &b->marks[idx];
    m->id = id;
    m->ns = xstrdup_opt(ns_name);
    m->start_byte = (spec->start_byte <= b->total_bytes) ? spec->start_byte : b->total_bytes;
    m->has_end = spec->has_end ? 1 : 0;
    if (m->has_end) {
        m->end_byte = (spec->end_byte <= b->total_bytes) ? spec->end_byte : b->total_bytes;
        if (m->end_byte < m->start_byte) m->end_byte = m->start_byte;
    } else {
        m->end_byte = m->start_byte;
    }
    m->right_gravity = spec->right_gravity ? 1 : 0;
    m->end_right_gravity = spec->end_right_gravity ? 1 : 0;
    m->priority = spec->priority;
    m->hl_group = xstrdup_opt(spec->hl_group);
    m->sign_text = xstrdup_opt(spec->sign_text);
    m->sign_hl = xstrdup_opt(spec->sign_hl);
    m->virt_text = xstrdup_opt(spec->virt_text);
    m->virt_hl = xstrdup_opt(spec->virt_hl);
    m->virt_pos = xstrdup_opt(spec->virt_pos ? spec->virt_pos : "eol");
    m->virt_lines = xstrdup_arr(spec->virt_lines, spec->virt_line_count);
    m->virt_line_count = m->virt_lines ? spec->virt_line_count : 0;
    m->virt_lines_hl = xstrdup_arr(spec->virt_lines_hl, spec->virt_line_hl_count);
    m->virt_line_hl_count = m->virt_lines_hl ? spec->virt_line_hl_count : 0;
    m->virt_lines_above = spec->virt_lines_above ? 1 : 0;
    return id;
}

int
npl_buf_del_extmark(npl_buf_t *b, const char *ns, uint64_t id)
{
    if (!b || id == 0) return 0;
    int all_ns = (!ns || !ns[0] || (ns[0] == '*' && ns[1] == '\0'));
    for (size_t i = 0; i < b->mark_count; i++) {
        if (b->marks[i].id == id && (all_ns || strcmp(b->marks[i].ns, ns) == 0)) {
            extmark_clear_fields(&b->marks[i]);
            if (i + 1 < b->mark_count) {
                memmove(&b->marks[i], &b->marks[i + 1],
                        (b->mark_count - i - 1) * sizeof(npl_extmark_t));
            }
            b->mark_count--;
            return 1;
        }
    }
    return 0;
}

void
npl_buf_clear_namespace(npl_buf_t *b, const char *ns, int64_t start_line, int64_t end_line)
{
    if (!b || b->mark_count == 0) return;
    int all_ns = (!ns || !ns[0] || (ns[0] == '*' && ns[1] == '\0'));
    int filter_range = (start_line >= 0 || end_line >= 0);

    size_t write_i = 0;
    for (size_t i = 0; i < b->mark_count; i++) {
        npl_extmark_t *m = &b->marks[i];
        int match = all_ns || (strcmp(m->ns, ns) == 0);
        if (match && filter_range) {
            size_t ml = 0, mc = 0;
            npl_buf_offset_to_line_col(b, m->start_byte, &ml, &mc);
            if (start_line >= 0 && (int64_t)ml < start_line) match = 0;
            if (end_line >= 0 && (int64_t)ml > end_line) match = 0;
        }
        if (match) {
            extmark_clear_fields(m);
        } else {
            if (write_i != i) b->marks[write_i] = b->marks[i];
            write_i++;
        }
    }
    b->mark_count = write_i;
}

static int
cmp_extmark_view(const void *a, const void *b)
{
    const npl_extmark_view_t *ma = (const npl_extmark_view_t *)a;
    const npl_extmark_view_t *mb = (const npl_extmark_view_t *)b;
    if (ma->start_byte != mb->start_byte) {
        return (ma->start_byte < mb->start_byte) ? -1 : 1;
    }
    if (ma->priority != mb->priority) {
        return (ma->priority < mb->priority) ? -1 : 1;
    }
    if (ma->id != mb->id) {
        return (ma->id < mb->id) ? -1 : 1;
    }
    return 0;
}

size_t
npl_buf_get_extmarks(npl_buf_t *b, const char *ns,
                     int64_t start_line, int64_t end_line,
                     npl_extmark_view_t **out_views)
{
    if (!b || !out_views) return 0;
    *out_views = NULL;
    if (b->mark_count == 0) return 0;

    int all_ns = (!ns || !ns[0] || (ns[0] == '*' && ns[1] == '\0'));
    npl_extmark_view_t *views = (npl_extmark_view_t *)calloc(
        b->mark_count, sizeof(npl_extmark_view_t));
    if (!views) return 0;

    size_t count = 0;
    for (size_t i = 0; i < b->mark_count; i++) {
        const npl_extmark_t *m = &b->marks[i];
        if (!all_ns && strcmp(m->ns, ns) != 0) continue;

        size_t sl = 0, sc = 0, el = 0, ec = 0;
        npl_buf_offset_to_line_col(b, m->start_byte, &sl, &sc);
        if (m->has_end) {
            npl_buf_offset_to_line_col(b, m->end_byte, &el, &ec);
        } else {
            el = sl;
            ec = sc;
        }
        if (start_line >= 0 && (int64_t)el < start_line) continue;
        if (end_line >= 0 && (int64_t)sl > end_line) continue;

        npl_extmark_view_t *v = &views[count++];
        v->id = m->id;
        v->ns = xstrdup_opt(m->ns);
        v->start_byte = m->start_byte;
        v->start_line = sl;
        v->start_col = sc;
        v->end_byte = m->end_byte;
        v->end_line = el;
        v->end_col = ec;
        v->has_end = m->has_end;
        v->right_gravity = m->right_gravity;
        v->end_right_gravity = m->end_right_gravity;
        v->priority = m->priority;
        v->hl_group = xstrdup_opt(m->hl_group);
        v->sign_text = xstrdup_opt(m->sign_text);
        v->sign_hl = xstrdup_opt(m->sign_hl);
        v->virt_text = xstrdup_opt(m->virt_text);
        v->virt_hl = xstrdup_opt(m->virt_hl);
        v->virt_pos = xstrdup_opt(m->virt_pos);
        v->virt_lines = xstrdup_arr((const char *const *)m->virt_lines, m->virt_line_count);
        v->virt_line_count = v->virt_lines ? m->virt_line_count : 0;
        v->virt_lines_hl = xstrdup_arr((const char *const *)m->virt_lines_hl, m->virt_line_hl_count);
        v->virt_line_hl_count = v->virt_lines_hl ? m->virt_line_hl_count : 0;
        v->virt_lines_above = m->virt_lines_above;
    }

    if (count > 1) {
        qsort(views, count, sizeof(npl_extmark_view_t), cmp_extmark_view);
    }
    *out_views = views;
    return count;
}

void
npl_buf_extmarks_free(npl_extmark_view_t *views, size_t count)
{
    if (!views) return;
    for (size_t i = 0; i < count; i++) {
        free(views[i].ns);
        free(views[i].hl_group);
        free(views[i].sign_text);
        free(views[i].sign_hl);
        free(views[i].virt_text);
        free(views[i].virt_hl);
        free(views[i].virt_pos);
        free_str_arr(views[i].virt_lines, views[i].virt_line_count);
        free_str_arr(views[i].virt_lines_hl, views[i].virt_line_hl_count);
    }
    free(views);
}

size_t
npl_buf_extmark_count(const npl_buf_t *b, const char *ns)
{
    if (!b) return 0;
    if (!ns || !ns[0] || (ns[0] == '*' && ns[1] == '\0')) return b->mark_count;
    size_t c = 0;
    for (size_t i = 0; i < b->mark_count; i++) {
        if (strcmp(b->marks[i].ns, ns) == 0) c++;
    }
    return c;
}
