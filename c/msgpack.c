/*
 * c/msgpack.c - Zero-dependency pure-C11 reentrant MessagePack codec
 *               Unsigned-char safe for ppc64le, no global state
 */
#include "msgpack.h"

#include <stdlib.h>
#include <string.h>

/* --- Growable byte buffer --- */

void
npl_mp_buf_init(npl_mp_buf_t *b)
{
    if (!b) return;
    b->data = NULL;
    b->len  = 0;
    b->cap  = 0;
}

void
npl_mp_buf_free(npl_mp_buf_t *b)
{
    if (!b) return;
    free(b->data);
    b->data = NULL;
    b->len  = 0;
    b->cap  = 0;
}

int
npl_mp_buf_reserve(npl_mp_buf_t *b, size_t extra)
{
    if (!b) return 0;
    if (extra > SIZE_MAX - b->len) return 0;
    size_t need = b->len + extra;
    if (need <= b->cap) return 1;
    size_t ncap = b->cap ? b->cap * 2 : 128;
    while (ncap < need) {
        if (ncap > SIZE_MAX / 2) {
            ncap = need;
            break;
        }
        ncap *= 2;
    }
    uint8_t *nd = (uint8_t *)realloc(b->data, ncap);
    if (!nd) return 0;
    b->data = nd;
    b->cap  = ncap;
    return 1;
}

static inline int
mp_push_u8(npl_mp_buf_t *b, uint8_t v)
{
    if (!npl_mp_buf_reserve(b, 1)) return 0;
    b->data[b->len++] = v;
    return 1;
}

static inline int
mp_push_bytes(npl_mp_buf_t *b, const uint8_t *src, size_t n)
{
    if (n == 0) return 1;
    if (!src) return 0;
    if (!npl_mp_buf_reserve(b, n)) return 0;
    memcpy(b->data + b->len, src, n);
    b->len += n;
    return 1;
}

static inline int
mp_push_be16(npl_mp_buf_t *b, uint16_t v)
{
    uint8_t tmp[2];
    tmp[0] = (uint8_t)((v >> 8) & 0xFFu);
    tmp[1] = (uint8_t)(v & 0xFFu);
    return mp_push_bytes(b, tmp, 2);
}

static inline int
mp_push_be32(npl_mp_buf_t *b, uint32_t v)
{
    uint8_t tmp[4];
    tmp[0] = (uint8_t)((v >> 24) & 0xFFu);
    tmp[1] = (uint8_t)((v >> 16) & 0xFFu);
    tmp[2] = (uint8_t)((v >>  8) & 0xFFu);
    tmp[3] = (uint8_t)(v & 0xFFu);
    return mp_push_bytes(b, tmp, 4);
}

static inline int
mp_push_be64(npl_mp_buf_t *b, uint64_t v)
{
    uint8_t tmp[8];
    tmp[0] = (uint8_t)((v >> 56) & 0xFFu);
    tmp[1] = (uint8_t)((v >> 48) & 0xFFu);
    tmp[2] = (uint8_t)((v >> 40) & 0xFFu);
    tmp[3] = (uint8_t)((v >> 32) & 0xFFu);
    tmp[4] = (uint8_t)((v >> 24) & 0xFFu);
    tmp[5] = (uint8_t)((v >> 16) & 0xFFu);
    tmp[6] = (uint8_t)((v >>  8) & 0xFFu);
    tmp[7] = (uint8_t)(v & 0xFFu);
    return mp_push_bytes(b, tmp, 8);
}

static inline uint16_t
mp_read_be16(const uint8_t *p)
{
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static inline uint32_t
mp_read_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) |
           ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] <<  8) |
           ((uint32_t)p[3]);
}

static inline uint64_t
mp_read_be64(const uint8_t *p)
{
    return ((uint64_t)p[0] << 56) |
           ((uint64_t)p[1] << 48) |
           ((uint64_t)p[2] << 40) |
           ((uint64_t)p[3] << 32) |
           ((uint64_t)p[4] << 24) |
           ((uint64_t)p[5] << 16) |
           ((uint64_t)p[6] <<  8) |
           ((uint64_t)p[7]);
}

static inline int8_t
u8_to_i8(uint8_t b)
{
    int8_t v;
    memcpy(&v, &b, sizeof(v));
    return v;
}

static inline int16_t
u16_to_i16(uint16_t u)
{
    int16_t v;
    memcpy(&v, &u, sizeof(v));
    return v;
}

static inline int32_t
u32_to_i32(uint32_t u)
{
    int32_t v;
    memcpy(&v, &u, sizeof(v));
    return v;
}

static inline int64_t
u64_to_i64(uint64_t u)
{
    int64_t v;
    memcpy(&v, &u, sizeof(v));
    return v;
}

/* --- Encoders --- */

int
npl_mp_write_nil(npl_mp_buf_t *b)
{
    return mp_push_u8(b, 0xC0u);
}

int
npl_mp_write_bool(npl_mp_buf_t *b, int val)
{
    return mp_push_u8(b, val ? 0xC3u : 0xC2u);
}

int
npl_mp_write_uint(npl_mp_buf_t *b, uint64_t val)
{
    if (val <= 0x7Fu) {
        return mp_push_u8(b, (uint8_t)val);
    }
    if (val <= 0xFFu) {
        if (!mp_push_u8(b, 0xCCu)) return 0;
        return mp_push_u8(b, (uint8_t)val);
    }
    if (val <= 0xFFFFu) {
        if (!mp_push_u8(b, 0xCDu)) return 0;
        return mp_push_be16(b, (uint16_t)val);
    }
    if (val <= 0xFFFFFFFFu) {
        if (!mp_push_u8(b, 0xCEu)) return 0;
        return mp_push_be32(b, (uint32_t)val);
    }
    if (!mp_push_u8(b, 0xCFu)) return 0;
    return mp_push_be64(b, val);
}

int
npl_mp_write_int(npl_mp_buf_t *b, int64_t val)
{
    if (val >= 0) {
        return npl_mp_write_uint(b, (uint64_t)val);
    }
    if (val >= -32) {
        uint8_t u = (uint8_t)(256 + (int)val);
        return mp_push_u8(b, u);
    }
    if (val >= -128) {
        uint8_t u = (uint8_t)(256 + (int)val);
        if (!mp_push_u8(b, 0xD0u)) return 0;
        return mp_push_u8(b, u);
    }
    if (val >= -32768) {
        uint16_t u = (uint16_t)(65536 + (int32_t)val);
        if (!mp_push_u8(b, 0xD1u)) return 0;
        return mp_push_be16(b, u);
    }
    if (val >= (-2147483647LL - 1LL)) {
        int32_t i32 = (int32_t)val;
        uint32_t u32;
        memcpy(&u32, &i32, sizeof(u32));
        if (!mp_push_u8(b, 0xD2u)) return 0;
        return mp_push_be32(b, u32);
    }
    uint64_t u64;
    memcpy(&u64, &val, sizeof(u64));
    if (!mp_push_u8(b, 0xD3u)) return 0;
    return mp_push_be64(b, u64);
}

int
npl_mp_write_f32(npl_mp_buf_t *b, float val)
{
    uint32_t u32;
    memcpy(&u32, &val, sizeof(u32));
    if (!mp_push_u8(b, 0xCAu)) return 0;
    return mp_push_be32(b, u32);
}

int
npl_mp_write_f64(npl_mp_buf_t *b, double val)
{
    uint64_t u64;
    memcpy(&u64, &val, sizeof(u64));
    if (!mp_push_u8(b, 0xCBu)) return 0;
    return mp_push_be64(b, u64);
}

int
npl_mp_write_str(npl_mp_buf_t *b, const uint8_t *data, size_t len)
{
    if (len <= 31u) {
        if (!mp_push_u8(b, (uint8_t)(0xA0u | (uint8_t)len))) return 0;
    } else if (len <= 0xFFu) {
        if (!mp_push_u8(b, 0xD9u)) return 0;
        if (!mp_push_u8(b, (uint8_t)len)) return 0;
    } else if (len <= 0xFFFFu) {
        if (!mp_push_u8(b, 0xDAu)) return 0;
        if (!mp_push_be16(b, (uint16_t)len)) return 0;
    } else if (len <= 0xFFFFFFFFu) {
        if (!mp_push_u8(b, 0xDBu)) return 0;
        if (!mp_push_be32(b, (uint32_t)len)) return 0;
    } else {
        return 0;
    }
    return mp_push_bytes(b, data, len);
}

int
npl_mp_write_bin(npl_mp_buf_t *b, const uint8_t *data, size_t len)
{
    if (len <= 0xFFu) {
        if (!mp_push_u8(b, 0xC4u)) return 0;
        if (!mp_push_u8(b, (uint8_t)len)) return 0;
    } else if (len <= 0xFFFFu) {
        if (!mp_push_u8(b, 0xC5u)) return 0;
        if (!mp_push_be16(b, (uint16_t)len)) return 0;
    } else if (len <= 0xFFFFFFFFu) {
        if (!mp_push_u8(b, 0xC6u)) return 0;
        if (!mp_push_be32(b, (uint32_t)len)) return 0;
    } else {
        return 0;
    }
    return mp_push_bytes(b, data, len);
}

int
npl_mp_write_array_hdr(npl_mp_buf_t *b, uint32_t count)
{
    if (count <= 15u) {
        return mp_push_u8(b, (uint8_t)(0x90u | (uint8_t)count));
    }
    if (count <= 0xFFFFu) {
        if (!mp_push_u8(b, 0xDCu)) return 0;
        return mp_push_be16(b, (uint16_t)count);
    }
    if (!mp_push_u8(b, 0xDDu)) return 0;
    return mp_push_be32(b, count);
}

int
npl_mp_write_map_hdr(npl_mp_buf_t *b, uint32_t count)
{
    if (count <= 15u) {
        return mp_push_u8(b, (uint8_t)(0x80u | (uint8_t)count));
    }
    if (count <= 0xFFFFu) {
        if (!mp_push_u8(b, 0xDEu)) return 0;
        return mp_push_be16(b, (uint16_t)count);
    }
    if (!mp_push_u8(b, 0xDFu)) return 0;
    return mp_push_be32(b, count);
}

int
npl_mp_write_ext(npl_mp_buf_t *b, int8_t ext_type, const uint8_t *data, size_t len)
{
    uint8_t tb;
    memcpy(&tb, &ext_type, 1);

    if (len == 1u) {
        if (!mp_push_u8(b, 0xD4u)) return 0;
    } else if (len == 2u) {
        if (!mp_push_u8(b, 0xD5u)) return 0;
    } else if (len == 4u) {
        if (!mp_push_u8(b, 0xD6u)) return 0;
    } else if (len == 8u) {
        if (!mp_push_u8(b, 0xD7u)) return 0;
    } else if (len == 16u) {
        if (!mp_push_u8(b, 0xD8u)) return 0;
    } else if (len <= 0xFFu) {
        if (!mp_push_u8(b, 0xC7u)) return 0;
        if (!mp_push_u8(b, (uint8_t)len)) return 0;
    } else if (len <= 0xFFFFu) {
        if (!mp_push_u8(b, 0xC8u)) return 0;
        if (!mp_push_be16(b, (uint16_t)len)) return 0;
    } else if (len <= 0xFFFFFFFFu) {
        if (!mp_push_u8(b, 0xC9u)) return 0;
        if (!mp_push_be32(b, (uint32_t)len)) return 0;
    } else {
        return 0;
    }
    if (!mp_push_u8(b, tb)) return 0;
    return mp_push_bytes(b, data, len);
}

int
npl_mp_write_nvim_ext(npl_mp_buf_t *b, int8_t ext_type, int64_t id)
{
    npl_mp_buf_t inner;
    npl_mp_buf_init(&inner);
    if (!npl_mp_write_int(&inner, id)) {
        npl_mp_buf_free(&inner);
        return 0;
    }
    int ok = npl_mp_write_ext(b, ext_type, inner.data, inner.len);
    npl_mp_buf_free(&inner);
    return ok;
}

/* --- Decoder --- */

void
npl_mp_val_free(npl_mp_val_t *v)
{
    if (!v) return;
    switch (v->type) {
    case NPL_MP_STR:
    case NPL_MP_BIN:
        free(v->u.bytes.ptr);
        break;
    case NPL_MP_EXT:
        free(v->u.ext.ptr);
        break;
    case NPL_MP_ARRAY:
        if (v->u.arr.items) {
            for (size_t i = 0; i < v->u.arr.len; i++) {
                npl_mp_val_free(v->u.arr.items[i]);
            }
            free(v->u.arr.items);
        }
        break;
    case NPL_MP_MAP:
        if (v->u.map.pairs) {
            for (size_t i = 0; i < v->u.map.len; i++) {
                npl_mp_val_free(v->u.map.pairs[i].key);
                npl_mp_val_free(v->u.map.pairs[i].val);
            }
            free(v->u.map.pairs);
        }
        break;
    default:
        break;
    }
    free(v);
}

int
npl_mp_decode_nvim_ext_id(const uint8_t *data, size_t len, int64_t *out_id)
{
    if (!data || len == 0 || !out_id) return 0;
    uint8_t b = data[0];
    if (b <= 0x7Fu) {
        if (len != 1) return 0;
        *out_id = (int64_t)b;
        return 1;
    }
    if (b >= 0xE0u) {
        if (len != 1) return 0;
        *out_id = (int64_t)u8_to_i8(b);
        return 1;
    }
    switch (b) {
    case 0xCCu:
        if (len != 2) return 0;
        *out_id = (int64_t)data[1];
        return 1;
    case 0xCDu:
        if (len != 3) return 0;
        *out_id = (int64_t)mp_read_be16(data + 1);
        return 1;
    case 0xCEu:
        if (len != 5) return 0;
        *out_id = (int64_t)mp_read_be32(data + 1);
        return 1;
    case 0xCFu: {
        if (len != 9) return 0;
        uint64_t u = mp_read_be64(data + 1);
        if (u > (uint64_t)INT64_MAX) return 0;
        *out_id = (int64_t)u;
        return 1;
    }
    case 0xD0u:
        if (len != 2) return 0;
        *out_id = (int64_t)u8_to_i8(data[1]);
        return 1;
    case 0xD1u:
        if (len != 3) return 0;
        *out_id = (int64_t)u16_to_i16(mp_read_be16(data + 1));
        return 1;
    case 0xD2u:
        if (len != 5) return 0;
        *out_id = (int64_t)u32_to_i32(mp_read_be32(data + 1));
        return 1;
    case 0xD3u:
        if (len != 9) return 0;
        *out_id = u64_to_i64(mp_read_be64(data + 1));
        return 1;
    default:
        return 0;
    }
}

static npl_mp_val_t *
mp_val_alloc(npl_mp_type_t t)
{
    npl_mp_val_t *v = (npl_mp_val_t *)calloc(1, sizeof(npl_mp_val_t));
    if (v) v->type = t;
    return v;
}

static npl_mp_status_t
mp_decode_rec(const uint8_t *buf, size_t len, size_t *pos, int depth, npl_mp_val_t **out)
{
    if (depth > NPL_MP_MAX_DEPTH) return NPL_MP_ERR_DEPTH;
    if (*pos >= len) return NPL_MP_INCOMPLETE;

    uint8_t b = buf[*pos];
    size_t rem = len - *pos;

    /* Positive fixint: 0x00..0x7f */
    if (b <= 0x7Fu) {
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_UINT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.u64 = (uint64_t)b;
        (*pos)++;
        *out = v;
        return NPL_MP_OK;
    }

    /* Negative fixint: 0xe0..0xff */
    if (b >= 0xE0u) {
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_INT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.i64 = (int64_t)u8_to_i8(b);
        (*pos)++;
        *out = v;
        return NPL_MP_OK;
    }

    /* Fixmap: 0x80..0x8f */
    if ((b & 0xF0u) == 0x80u) {
        size_t count = (size_t)(b & 0x0Fu);
        (*pos)++;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_MAP);
        if (!v) return NPL_MP_ERR_OOM;
        if (count > 0) {
            v->u.map.pairs = (npl_mp_kv_t *)calloc(count, sizeof(npl_mp_kv_t));
            if (!v->u.map.pairs) { free(v); return NPL_MP_ERR_OOM; }
            v->u.map.len = count;
            for (size_t i = 0; i < count; i++) {
                npl_mp_status_t st = mp_decode_rec(buf, len, pos, depth + 1, &v->u.map.pairs[i].key);
                if (st != NPL_MP_OK) { npl_mp_val_free(v); return st; }
                st = mp_decode_rec(buf, len, pos, depth + 1, &v->u.map.pairs[i].val);
                if (st != NPL_MP_OK) { npl_mp_val_free(v); return st; }
            }
        }
        *out = v;
        return NPL_MP_OK;
    }

    /* Fixarray: 0x90..0x9f */
    if ((b & 0xF0u) == 0x90u) {
        size_t count = (size_t)(b & 0x0Fu);
        (*pos)++;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_ARRAY);
        if (!v) return NPL_MP_ERR_OOM;
        if (count > 0) {
            v->u.arr.items = (npl_mp_val_t **)calloc(count, sizeof(npl_mp_val_t *));
            if (!v->u.arr.items) { free(v); return NPL_MP_ERR_OOM; }
            v->u.arr.len = count;
            for (size_t i = 0; i < count; i++) {
                npl_mp_status_t st = mp_decode_rec(buf, len, pos, depth + 1, &v->u.arr.items[i]);
                if (st != NPL_MP_OK) { npl_mp_val_free(v); return st; }
            }
        }
        *out = v;
        return NPL_MP_OK;
    }

    /* Fixstr: 0xa0..0xbf */
    if ((b & 0xE0u) == 0xA0u) {
        size_t slen = (size_t)(b & 0x1Fu);
        if (rem - 1 < slen) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_STR);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.bytes.ptr = (uint8_t *)malloc(slen + 1);
        if (!v->u.bytes.ptr) { free(v); return NPL_MP_ERR_OOM; }
        if (slen > 0) memcpy(v->u.bytes.ptr, buf + *pos + 1, slen);
        v->u.bytes.ptr[slen] = 0;
        v->u.bytes.len = slen;
        *pos += 1 + slen;
        *out = v;
        return NPL_MP_OK;
    }

    switch (b) {
    case 0xC0u: { /* nil */
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_NIL);
        if (!v) return NPL_MP_ERR_OOM;
        (*pos)++;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xC1u: /* never used */
        return NPL_MP_ERR_INVALID;
    case 0xC2u:
    case 0xC3u: { /* false / true */
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_BOOL);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.b = (b == 0xC3u) ? 1 : 0;
        (*pos)++;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xC4u:
    case 0xC5u:
    case 0xC6u:
    case 0xD9u:
    case 0xDAu:
    case 0xDBu: { /* bin 8/16/32 and str 8/16/32 */
        int is_bin = (b == 0xC4u || b == 0xC5u || b == 0xC6u);
        size_t hdr = (b == 0xC4u || b == 0xD9u) ? 2u
                   : (b == 0xC5u || b == 0xDAu) ? 3u : 5u;
        if (rem < hdr) return NPL_MP_INCOMPLETE;
        size_t blen = (hdr == 2u) ? (size_t)buf[*pos + 1]
                    : (hdr == 3u) ? (size_t)mp_read_be16(buf + *pos + 1)
                    : (size_t)mp_read_be32(buf + *pos + 1);
        if (rem - hdr < blen) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(is_bin ? NPL_MP_BIN : NPL_MP_STR);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.bytes.ptr = (uint8_t *)malloc(blen + 1);
        if (!v->u.bytes.ptr) { free(v); return NPL_MP_ERR_OOM; }
        if (blen > 0) memcpy(v->u.bytes.ptr, buf + *pos + hdr, blen);
        v->u.bytes.ptr[blen] = 0;
        v->u.bytes.len = blen;
        *pos += hdr + blen;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xC7u:
    case 0xC8u:
    case 0xC9u:
    case 0xD4u:
    case 0xD5u:
    case 0xD6u:
    case 0xD7u:
    case 0xD8u: { /* ext 8/16/32 and fixext 1/2/4/8/16 */
        size_t hdr = 0;
        size_t elen = 0;
        if (b == 0xD4u)      { hdr = 2u; elen = 1u; }
        else if (b == 0xD5u) { hdr = 2u; elen = 2u; }
        else if (b == 0xD6u) { hdr = 2u; elen = 4u; }
        else if (b == 0xD7u) { hdr = 2u; elen = 8u; }
        else if (b == 0xD8u) { hdr = 2u; elen = 16u; }
        else if (b == 0xC7u) {
            hdr = 3u;
            if (rem < hdr) return NPL_MP_INCOMPLETE;
            elen = (size_t)buf[*pos + 1];
        } else if (b == 0xC8u) {
            hdr = 4u;
            if (rem < hdr) return NPL_MP_INCOMPLETE;
            elen = (size_t)mp_read_be16(buf + *pos + 1);
        } else {
            hdr = 6u;
            if (rem < hdr) return NPL_MP_INCOMPLETE;
            elen = (size_t)mp_read_be32(buf + *pos + 1);
        }
        if (rem < hdr || rem - hdr < elen) return NPL_MP_INCOMPLETE;
        int8_t etype = u8_to_i8(buf[*pos + hdr - 1]);
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_EXT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.ext.ext_type = etype;
        v->u.ext.ptr = (uint8_t *)malloc(elen + 1);
        if (!v->u.ext.ptr) { free(v); return NPL_MP_ERR_OOM; }
        if (elen > 0) memcpy(v->u.ext.ptr, buf + *pos + hdr, elen);
        v->u.ext.ptr[elen] = 0;
        v->u.ext.len = elen;
        int64_t nid = 0;
        if (npl_mp_decode_nvim_ext_id(v->u.ext.ptr, elen, &nid)) {
            v->u.ext.has_int_id = 1;
            v->u.ext.int_id = nid;
        }
        *pos += hdr + elen;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xCAu: { /* float 32 */
        if (rem < 5u) return NPL_MP_INCOMPLETE;
        uint32_t u32 = mp_read_be32(buf + *pos + 1);
        float f;
        memcpy(&f, &u32, sizeof(f));
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_F32);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.f32 = f;
        *pos += 5u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xCBu: { /* float 64 */
        if (rem < 9u) return NPL_MP_INCOMPLETE;
        uint64_t u64 = mp_read_be64(buf + *pos + 1);
        double d;
        memcpy(&d, &u64, sizeof(d));
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_F64);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.f64 = d;
        *pos += 9u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xCCu: { /* uint 8 */
        if (rem < 2u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_UINT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.u64 = (uint64_t)buf[*pos + 1];
        *pos += 2u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xCDu: { /* uint 16 */
        if (rem < 3u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_UINT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.u64 = (uint64_t)mp_read_be16(buf + *pos + 1);
        *pos += 3u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xCEu: { /* uint 32 */
        if (rem < 5u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_UINT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.u64 = (uint64_t)mp_read_be32(buf + *pos + 1);
        *pos += 5u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xCFu: { /* uint 64 */
        if (rem < 9u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_UINT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.u64 = mp_read_be64(buf + *pos + 1);
        *pos += 9u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xD0u: { /* int 8 */
        if (rem < 2u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_INT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.i64 = (int64_t)u8_to_i8(buf[*pos + 1]);
        *pos += 2u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xD1u: { /* int 16 */
        if (rem < 3u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_INT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.i64 = (int64_t)u16_to_i16(mp_read_be16(buf + *pos + 1));
        *pos += 3u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xD2u: { /* int 32 */
        if (rem < 5u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_INT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.i64 = (int64_t)u32_to_i32(mp_read_be32(buf + *pos + 1));
        *pos += 5u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xD3u: { /* int 64 */
        if (rem < 9u) return NPL_MP_INCOMPLETE;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_INT);
        if (!v) return NPL_MP_ERR_OOM;
        v->u.i64 = u64_to_i64(mp_read_be64(buf + *pos + 1));
        *pos += 9u;
        *out = v;
        return NPL_MP_OK;
    }
    case 0xDCu:
    case 0xDDu: { /* array 16 / 32 */
        size_t hdr = (b == 0xDCu) ? 3u : 5u;
        if (rem < hdr) return NPL_MP_INCOMPLETE;
        size_t count = (b == 0xDCu)
            ? (size_t)mp_read_be16(buf + *pos + 1)
            : (size_t)mp_read_be32(buf + *pos + 1);
        /* Each element takes at least 1 byte on wire */
        if (count > rem - hdr) return NPL_MP_INCOMPLETE;
        *pos += hdr;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_ARRAY);
        if (!v) return NPL_MP_ERR_OOM;
        if (count > 0) {
            v->u.arr.items = (npl_mp_val_t **)calloc(count, sizeof(npl_mp_val_t *));
            if (!v->u.arr.items) { free(v); return NPL_MP_ERR_OOM; }
            v->u.arr.len = count;
            for (size_t i = 0; i < count; i++) {
                npl_mp_status_t st = mp_decode_rec(buf, len, pos, depth + 1, &v->u.arr.items[i]);
                if (st != NPL_MP_OK) { npl_mp_val_free(v); return st; }
            }
        }
        *out = v;
        return NPL_MP_OK;
    }
    case 0xDEu:
    case 0xDFu: { /* map 16 / 32 */
        size_t hdr = (b == 0xDEu) ? 3u : 5u;
        if (rem < hdr) return NPL_MP_INCOMPLETE;
        size_t count = (b == 0xDEu)
            ? (size_t)mp_read_be16(buf + *pos + 1)
            : (size_t)mp_read_be32(buf + *pos + 1);
        /* Each pair takes at least 2 bytes on wire */
        if (count > (rem - hdr) / 2u) return NPL_MP_INCOMPLETE;
        *pos += hdr;
        npl_mp_val_t *v = mp_val_alloc(NPL_MP_MAP);
        if (!v) return NPL_MP_ERR_OOM;
        if (count > 0) {
            v->u.map.pairs = (npl_mp_kv_t *)calloc(count, sizeof(npl_mp_kv_t));
            if (!v->u.map.pairs) { free(v); return NPL_MP_ERR_OOM; }
            v->u.map.len = count;
            for (size_t i = 0; i < count; i++) {
                npl_mp_status_t st = mp_decode_rec(buf, len, pos, depth + 1, &v->u.map.pairs[i].key);
                if (st != NPL_MP_OK) { npl_mp_val_free(v); return st; }
                st = mp_decode_rec(buf, len, pos, depth + 1, &v->u.map.pairs[i].val);
                if (st != NPL_MP_OK) { npl_mp_val_free(v); return st; }
            }
        }
        *out = v;
        return NPL_MP_OK;
    }
    default:
        return NPL_MP_ERR_INVALID;
    }
}

npl_mp_status_t
npl_mp_decode_one(const uint8_t *buf, size_t len,
                  size_t *out_consumed,
                  npl_mp_val_t **out_val)
{
    if (out_consumed) *out_consumed = 0;
    if (out_val)      *out_val      = NULL;
    if (!buf || len == 0) return NPL_MP_INCOMPLETE;

    size_t pos = 0;
    npl_mp_val_t *v = NULL;
    npl_mp_status_t st = mp_decode_rec(buf, len, &pos, 0, &v);
    if (st != NPL_MP_OK) {
        npl_mp_val_free(v);
        return st;
    }
    if (out_consumed) *out_consumed = pos;
    if (out_val)      *out_val      = v;
    else              npl_mp_val_free(v);
    return NPL_MP_OK;
}
