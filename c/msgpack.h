/*
 * c/msgpack.h - Zero-dependency pure-C11 reentrant MessagePack codec
 *               with streaming partial-frame decoding and Neovim ext (0/1/2) support
 */
#ifndef NPL_MSGPACK_H
#define NPL_MSGPACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NPL_MP_MAX_DEPTH 128

typedef enum npl_mp_status {
    NPL_MP_OK           =  0,
    NPL_MP_INCOMPLETE   =  1,
    NPL_MP_ERR_INVALID  = -1,
    NPL_MP_ERR_DEPTH    = -2,
    NPL_MP_ERR_OOM      = -3
} npl_mp_status_t;

typedef enum npl_mp_type {
    NPL_MP_NIL   = 0,
    NPL_MP_BOOL  = 1,
    NPL_MP_INT   = 2,
    NPL_MP_UINT  = 3,
    NPL_MP_F32   = 4,
    NPL_MP_F64   = 5,
    NPL_MP_STR   = 6,
    NPL_MP_BIN   = 7,
    NPL_MP_ARRAY = 8,
    NPL_MP_MAP   = 9,
    NPL_MP_EXT   = 10
} npl_mp_type_t;

/* Growable byte buffer for encoding */
typedef struct npl_mp_buf {
    uint8_t *data;
    size_t   len;
    size_t   cap;
} npl_mp_buf_t;

typedef struct npl_mp_val npl_mp_val_t;

typedef struct npl_mp_kv {
    npl_mp_val_t *key;
    npl_mp_val_t *val;
} npl_mp_kv_t;

struct npl_mp_val {
    npl_mp_type_t type;
    union {
        int      b;
        int64_t  i64;
        uint64_t u64;
        float    f32;
        double   f64;
        struct {
            uint8_t *ptr;
            size_t   len;
        } bytes;
        struct {
            npl_mp_val_t **items;
            size_t         len;
        } arr;
        struct {
            npl_mp_kv_t *pairs;
            size_t       len;
        } map;
        struct {
            int8_t   ext_type;
            uint8_t *ptr;
            size_t   len;
            int      has_int_id;
            int64_t  int_id;
        } ext;
    } u;
};

/* Encoder buffer lifecycle */
void npl_mp_buf_init(npl_mp_buf_t *b);
void npl_mp_buf_free(npl_mp_buf_t *b);
int  npl_mp_buf_reserve(npl_mp_buf_t *b, size_t extra);

/* Primitive & container encoders (return 1 on success, 0 on OOM/error) */
int npl_mp_write_nil(npl_mp_buf_t *b);
int npl_mp_write_bool(npl_mp_buf_t *b, int val);
int npl_mp_write_int(npl_mp_buf_t *b, int64_t val);
int npl_mp_write_uint(npl_mp_buf_t *b, uint64_t val);
int npl_mp_write_f32(npl_mp_buf_t *b, float val);
int npl_mp_write_f64(npl_mp_buf_t *b, double val);
int npl_mp_write_str(npl_mp_buf_t *b, const uint8_t *data, size_t len);
int npl_mp_write_bin(npl_mp_buf_t *b, const uint8_t *data, size_t len);
int npl_mp_write_array_hdr(npl_mp_buf_t *b, uint32_t count);
int npl_mp_write_map_hdr(npl_mp_buf_t *b, uint32_t count);
int npl_mp_write_ext(npl_mp_buf_t *b, int8_t ext_type, const uint8_t *data, size_t len);
int npl_mp_write_nvim_ext(npl_mp_buf_t *b, int8_t ext_type, int64_t id);

/* Decode one MessagePack object from [buf, buf+len).
 * On NPL_MP_OK: *out_val is populated, *out_consumed is byte count consumed.
 * On NPL_MP_INCOMPLETE: *out_val is NULL, *out_consumed is 0 (no partial mutation).
 */
npl_mp_status_t npl_mp_decode_one(const uint8_t *buf, size_t len,
                                  size_t *out_consumed,
                                  npl_mp_val_t **out_val);

/* Decode a Neovim ext payload (single MessagePack integer) into *out_id.
 * Returns 1 if payload was a valid single msgpack integer, 0 otherwise.
 */
int npl_mp_decode_nvim_ext_id(const uint8_t *data, size_t len, int64_t *out_id);

/* Free a decoded value tree */
void npl_mp_val_free(npl_mp_val_t *v);

#ifdef __cplusplus
}
#endif

#endif /* NPL_MSGPACK_H */
