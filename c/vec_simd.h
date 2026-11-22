/*
 * c/vec_simd.h - Multi-arch SIMD float32 vector kernels
 *                (POWER8+ VSX + POWER10 MMA hook, ARM64 NEON, x86_64 SSE2/AVX2)
 *
 * Bit-identical under PERL_FORCE_SCALAR=1 across all supported architectures.
 */
#ifndef NPL_VEC_SIMD_H
#define NPL_VEC_SIMD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct npl_topk_hit {
    size_t index;
    double score;
} npl_topk_hit_t;

const char *npl_vec_simd_backend(void);

/* Little-endian IEEE-754 float32 BLOB pack / unpack */
void npl_vec_pack_f32(const float *src, size_t dim, uint8_t *dst_le);
void npl_vec_unpack_f32(const uint8_t *src_le, size_t dim, float *dst);

/* Core float32 vector operations */
double npl_vec_dot_f32(const float *a, const float *b, size_t dim);
double npl_vec_l2_norm_f32(const float *a, size_t dim);
double npl_vec_cosine_f32(const float *a, const float *b, size_t dim);
void   npl_vec_normalize_f32(const float *src, float *dst, size_t dim);

/* Direct LE BLOB convenience operations (byte_len must be multiple of 4) */
double npl_vec_dot_blob(const uint8_t *a_le, const uint8_t *b_le, size_t dim);
double npl_vec_l2_norm_blob(const uint8_t *a_le, size_t dim);
double npl_vec_cosine_blob(const uint8_t *a_le, const uint8_t *b_le, size_t dim);
void   npl_vec_normalize_blob(const uint8_t *src_le, uint8_t *dst_le, size_t dim);

/*
 * Batch top-K cosine similarity scan against candidate LE float32 BLOBs.
 * Returns number of hits written to out_hits (up to k), sorted by
 * (score DESC, index ASC).
 */
size_t npl_vec_topk_cosine(const uint8_t *query_le, size_t dim,
                           const uint8_t *const *cand_blobs, const size_t *cand_bytes,
                           size_t n_cands, size_t k, npl_topk_hit_t *out_hits);

#ifdef __cplusplus
}
#endif

#endif /* NPL_VEC_SIMD_H */
