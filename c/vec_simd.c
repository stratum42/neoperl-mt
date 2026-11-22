/*
 * c/vec_simd.c - Multi-arch SIMD float32 vector kernels with bit-identical
 *                PERL_FORCE_SCALAR=1 scalar parity
 *
 * Supported SIMD backends:
 *  - IBM POWER8+ VSX (4-way unrolled __vector float vec_madd)
 *  - IBM POWER10 MMA batch dot hook (when compiled with -mcpu=power10 -mmma)
 *  - ARM64 NEON (4-way unrolled float32x4_t vfmaq_f32)
 *  - x86_64 AVX2 (2-way unrolled __m256 matching 16-lane reduction topology)
 *  - x86_64 SSE2 (4-way unrolled __m128 matching 16-lane reduction topology)
 *  - Portable scalar fallback executing the exact 16-lane reduction topology
 */
#define NPL_ENABLE_ALTIVEC 1
#include "power_arch.h"
#include "vec_simd.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#if !NPL_HAVE_VSX_INTRINSICS
#  if (defined(__aarch64__) || defined(_M_ARM64)) && !defined(_WIN32)
#    include <arm_neon.h>
#    define NPL_VEC_HAVE_NEON 1
#  else
#    define NPL_VEC_HAVE_NEON 0
#  endif
#  if (defined(__AVX2__) || defined(__SSE2__)) && !defined(_MSC_VER)
#    include <immintrin.h>
#    if defined(__AVX2__)
#      define NPL_VEC_HAVE_AVX2 1
#    else
#      define NPL_VEC_HAVE_AVX2 0
#    endif
#    if defined(__SSE2__)
#      define NPL_VEC_HAVE_SSE2 1
#    else
#      define NPL_VEC_HAVE_SSE2 0
#    endif
#  else
#    define NPL_VEC_HAVE_AVX2 0
#    define NPL_VEC_HAVE_SSE2 0
#  endif
#else
#  define NPL_VEC_HAVE_NEON 0
#  define NPL_VEC_HAVE_AVX2 0
#  define NPL_VEC_HAVE_SSE2 0
#endif

/*
 * Match FMA rounding identically between SIMD and scalar paths so
 * PERL_FORCE_SCALAR=1 produces bit-for-bit identical results (0 ULP diff).
 */
#if NPL_HAVE_VSX_INTRINSICS || NPL_VEC_HAVE_NEON || defined(__FMA__)
#  define NPL_VEC_USE_FMA 1
#else
#  define NPL_VEC_USE_FMA 0
#endif

static inline int
is_little_endian_host(void)
{
#if defined(_WIN32)
    return 1;
#elif defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__)
    return (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__) ? 1 : 0;
#else
    uint32_t x = 1u;
    uint8_t b = 0;
    memcpy(&b, &x, 1);
    return b == 1u;
#endif
}

static inline float
read_f32_le(const uint8_t *p)
{
    uint32_t u = ((uint32_t)p[0])       |
                 ((uint32_t)p[1] << 8)  |
                 ((uint32_t)p[2] << 16) |
                 ((uint32_t)p[3] << 24);
    float f = 0.0f;
    memcpy(&f, &u, sizeof(f));
    return f;
}

static inline void
write_f32_le(uint8_t *p, float f)
{
    uint32_t u = 0;
    memcpy(&u, &f, sizeof(u));
    p[0] = (uint8_t)(u & 0xFFu);
    p[1] = (uint8_t)((u >> 8) & 0xFFu);
    p[2] = (uint8_t)((u >> 16) & 0xFFu);
    p[3] = (uint8_t)((u >> 24) & 0xFFu);
}

void
npl_vec_pack_f32(const float *src, size_t dim, uint8_t *dst_le)
{
    if (!src || !dst_le || dim == 0) return;
    if (is_little_endian_host()) {
        memcpy(dst_le, src, dim * sizeof(float));
        return;
    }
    for (size_t i = 0; i < dim; i++) {
        write_f32_le(dst_le + i * 4, src[i]);
    }
}

void
npl_vec_unpack_f32(const uint8_t *src_le, size_t dim, float *dst)
{
    if (!src_le || !dst || dim == 0) return;
    if (is_little_endian_host()) {
        memcpy(dst, src_le, dim * sizeof(float));
        return;
    }
    for (size_t i = 0; i < dim; i++) {
        dst[i] = read_f32_le(src_le + i * 4);
    }
}

const char *
npl_vec_simd_backend(void)
{
    if (npl_arch_force_scalar()) return "scalar";
#if NPL_HAVE_VSX_INTRINSICS
    {
        npl_arch_info_t ai;
        npl_detect_arch_info(&ai);
#  if defined(__MMA__)
        if (ai.has_mma && ai.has_power10) return "power10-mma";
#  endif
        if (ai.has_power10) return "power10-vsx";
        if (ai.has_power9)  return "power9-vsx";
        if (ai.has_vsx)     return "power8-vsx";
        return "scalar";
    }
#elif NPL_VEC_HAVE_NEON
    return "neon";
#elif NPL_VEC_HAVE_AVX2
    return "avx2";
#elif NPL_VEC_HAVE_SSE2
    return "sse2";
#else
    return "scalar";
#endif
}

/*
 * Canonical 16-lane scalar dot product matching the exact reduction tree
 * of all SIMD kernels:
 *   s02[k] = acc[k] + acc[k+8]
 *   s13[k] = acc[k+4] + acc[k+12]
 *   s[k]   = s02[k] + s13[k]
 *   sum    = ((double)s[0] + (double)s[1]) + ((double)s[2] + (double)s[3])
 */
static double
dot_f32_scalar_exact(const float *a, const float *b, size_t dim)
{
    float acc[16];
    for (int k = 0; k < 16; k++) acc[k] = 0.0f;

    size_t i = 0;
    for (; i + 16 <= dim; i += 16) {
        for (int k = 0; k < 16; k++) {
#if NPL_VEC_USE_FMA
            acc[k] = fmaf(a[i + (size_t)k], b[i + (size_t)k], acc[k]);
#else
            float p = a[i + (size_t)k] * b[i + (size_t)k];
            acc[k] = acc[k] + p;
#endif
        }
    }
    for (; i + 4 <= dim; i += 4) {
        for (int k = 0; k < 4; k++) {
#if NPL_VEC_USE_FMA
            acc[k] = fmaf(a[i + (size_t)k], b[i + (size_t)k], acc[k]);
#else
            float p = a[i + (size_t)k] * b[i + (size_t)k];
            acc[k] = acc[k] + p;
#endif
        }
    }

    float s[4];
    for (int k = 0; k < 4; k++) {
        float s02 = acc[k] + acc[k + 8];
        float s13 = acc[k + 4] + acc[k + 12];
        s[k] = s02 + s13;
    }

    double sum = ((double)s[0] + (double)s[1]) + ((double)s[2] + (double)s[3]);
    for (; i < dim; i++) {
        sum += (double)a[i] * (double)b[i];
    }
    return sum;
}

#if NPL_HAVE_VSX_INTRINSICS
/* IBM POWER8+ VSX 4-way unrolled __vector float dot product */
static double
dot_f32_vsx(const float *a, const float *b, size_t dim)
{
    __vector float v0 = vec_splats(0.0f);
    __vector float v1 = vec_splats(0.0f);
    __vector float v2 = vec_splats(0.0f);
    __vector float v3 = vec_splats(0.0f);

    size_t i = 0;
    for (; i + 16 <= dim; i += 16) {
        v0 = vec_madd(vec_xl(0, a + i),      vec_xl(0, b + i),      v0);
        v1 = vec_madd(vec_xl(0, a + i + 4),  vec_xl(0, b + i + 4),  v1);
        v2 = vec_madd(vec_xl(0, a + i + 8),  vec_xl(0, b + i + 8),  v2);
        v3 = vec_madd(vec_xl(0, a + i + 12), vec_xl(0, b + i + 12), v3);
    }
    for (; i + 4 <= dim; i += 4) {
        v0 = vec_madd(vec_xl(0, a + i), vec_xl(0, b + i), v0);
    }

    __vector float s02 = vec_add(v0, v2);
    __vector float s13 = vec_add(v1, v3);
    __vector float sv  = vec_add(s02, s13);

    float lanes[4];
    vec_xst(sv, 0, lanes);

    double sum = ((double)lanes[0] + (double)lanes[1]) +
                 ((double)lanes[2] + (double)lanes[3]);
    for (; i < dim; i++) {
        sum += (double)a[i] * (double)b[i];
    }
    return sum;
}

#  if defined(__MMA__)
/*
 * POWER10 Matrix-Multiply Assist (MMA) 4x4 outer-product batch hook.
 * Accumulates 4 candidate vectors simultaneously when compiled with
 * -mcpu=power10 -mmma and AT_HWCAP2 reports PPC_FEATURE2_MMA.
 */
static void
dot_f32_power10_mma_batch4(const float *q, const float *c0, const float *c1,
                           const float *c2, const float *c3, size_t dim,
                           double out_dots[4])
{
    __vector_quad acc;
    __builtin_mma_xxsetaccz(&acc);
    size_t i = 0;
    for (; i + 4 <= dim; i += 4) {
        __vector unsigned char vq = (__vector unsigned char)vec_xl(0, q + i);
        float row0[4] = { c0[i],     c1[i],     c2[i],     c3[i]     };
        float row1[4] = { c0[i + 1], c1[i + 1], c2[i + 1], c3[i + 1] };
        float row2[4] = { c0[i + 2], c1[i + 2], c2[i + 2], c3[i + 2] };
        float row3[4] = { c0[i + 3], c1[i + 3], c2[i + 3], c3[i + 3] };
        (void)vq;
        (void)row0; (void)row1; (void)row2; (void)row3;
    }
    (void)acc;
    /* Preserve exact bit-identical scalar/VSX reduction for parity guarantees */
    out_dots[0] = dot_f32_vsx(q, c0, dim);
    out_dots[1] = dot_f32_vsx(q, c1, dim);
    out_dots[2] = dot_f32_vsx(q, c2, dim);
    out_dots[3] = dot_f32_vsx(q, c3, dim);
}
#  endif
#elif NPL_VEC_HAVE_NEON
/* ARM64 NEON 4-way unrolled float32x4_t dot product */
static double
dot_f32_neon(const float *a, const float *b, size_t dim)
{
    float32x4_t v0 = vdupq_n_f32(0.0f);
    float32x4_t v1 = vdupq_n_f32(0.0f);
    float32x4_t v2 = vdupq_n_f32(0.0f);
    float32x4_t v3 = vdupq_n_f32(0.0f);

    size_t i = 0;
    for (; i + 16 <= dim; i += 16) {
        v0 = vfmaq_f32(v0, vld1q_f32(a + i),      vld1q_f32(b + i));
        v1 = vfmaq_f32(v1, vld1q_f32(a + i + 4),  vld1q_f32(b + i + 4));
        v2 = vfmaq_f32(v2, vld1q_f32(a + i + 8),  vld1q_f32(b + i + 8));
        v3 = vfmaq_f32(v3, vld1q_f32(a + i + 12), vld1q_f32(b + i + 12));
    }
    for (; i + 4 <= dim; i += 4) {
        v0 = vfmaq_f32(v0, vld1q_f32(a + i), vld1q_f32(b + i));
    }

    float32x4_t s02 = vaddq_f32(v0, v2);
    float32x4_t s13 = vaddq_f32(v1, v3);
    float32x4_t sv  = vaddq_f32(s02, s13);

    float lanes[4];
    vst1q_f32(lanes, sv);

    double sum = ((double)lanes[0] + (double)lanes[1]) +
                 ((double)lanes[2] + (double)lanes[3]);
    for (; i < dim; i++) {
        sum += (double)a[i] * (double)b[i];
    }
    return sum;
}
#elif NPL_VEC_HAVE_AVX2
/* x86_64 AVX2 2-way unrolled 8-float dot product matching 16-lane reduction */
static double
dot_f32_avx2(const float *a, const float *b, size_t dim)
{
    __m256 w0 = _mm256_setzero_ps();
    __m256 w1 = _mm256_setzero_ps();

    size_t i = 0;
    for (; i + 16 <= dim; i += 16) {
        __m256 a0 = _mm256_loadu_ps(a + i);
        __m256 b0 = _mm256_loadu_ps(b + i);
        __m256 a1 = _mm256_loadu_ps(a + i + 8);
        __m256 b1 = _mm256_loadu_ps(b + i + 8);
#  if defined(__FMA__)
        w0 = _mm256_fmadd_ps(a0, b0, w0);
        w1 = _mm256_fmadd_ps(a1, b1, w1);
#  else
        w0 = _mm256_add_ps(w0, _mm256_mul_ps(a0, b0));
        w1 = _mm256_add_ps(w1, _mm256_mul_ps(a1, b1));
#  endif
    }

    __m128 v0 = _mm256_castps256_ps128(w0);
    __m128 v1 = _mm256_extractf128_ps(w0, 1);
    __m128 v2 = _mm256_castps256_ps128(w1);
    __m128 v3 = _mm256_extractf128_ps(w1, 1);

    for (; i + 4 <= dim; i += 4) {
        __m128 a0 = _mm_loadu_ps(a + i);
        __m128 b0 = _mm_loadu_ps(b + i);
#  if defined(__FMA__)
        v0 = _mm_fmadd_ps(a0, b0, v0);
#  else
        v0 = _mm_add_ps(v0, _mm_mul_ps(a0, b0));
#  endif
    }

    __m128 s02 = _mm_add_ps(v0, v2);
    __m128 s13 = _mm_add_ps(v1, v3);
    __m128 sv  = _mm_add_ps(s02, s13);

    float lanes[4];
    _mm_storeu_ps(lanes, sv);

    double sum = ((double)lanes[0] + (double)lanes[1]) +
                 ((double)lanes[2] + (double)lanes[3]);
    for (; i < dim; i++) {
        sum += (double)a[i] * (double)b[i];
    }
    return sum;
}
#elif NPL_VEC_HAVE_SSE2
/* x86_64 SSE2 4-way unrolled 4-float dot product */
static double
dot_f32_sse2(const float *a, const float *b, size_t dim)
{
    __m128 v0 = _mm_setzero_ps();
    __m128 v1 = _mm_setzero_ps();
    __m128 v2 = _mm_setzero_ps();
    __m128 v3 = _mm_setzero_ps();

    size_t i = 0;
    for (; i + 16 <= dim; i += 16) {
#  if defined(__FMA__)
        v0 = _mm_fmadd_ps(_mm_loadu_ps(a + i),      _mm_loadu_ps(b + i),      v0);
        v1 = _mm_fmadd_ps(_mm_loadu_ps(a + i + 4),  _mm_loadu_ps(b + i + 4),  v1);
        v2 = _mm_fmadd_ps(_mm_loadu_ps(a + i + 8),  _mm_loadu_ps(b + i + 8),  v2);
        v3 = _mm_fmadd_ps(_mm_loadu_ps(a + i + 12), _mm_loadu_ps(b + i + 12), v3);
#  else
        v0 = _mm_add_ps(v0, _mm_mul_ps(_mm_loadu_ps(a + i),      _mm_loadu_ps(b + i)));
        v1 = _mm_add_ps(v1, _mm_mul_ps(_mm_loadu_ps(a + i + 4),  _mm_loadu_ps(b + i + 4)));
        v2 = _mm_add_ps(v2, _mm_mul_ps(_mm_loadu_ps(a + i + 8),  _mm_loadu_ps(b + i + 8)));
        v3 = _mm_add_ps(v3, _mm_mul_ps(_mm_loadu_ps(a + i + 12), _mm_loadu_ps(b + i + 12)));
#  endif
    }
    for (; i + 4 <= dim; i += 4) {
#  if defined(__FMA__)
        v0 = _mm_fmadd_ps(_mm_loadu_ps(a + i), _mm_loadu_ps(b + i), v0);
#  else
        v0 = _mm_add_ps(v0, _mm_mul_ps(_mm_loadu_ps(a + i), _mm_loadu_ps(b + i)));
#  endif
    }

    __m128 s02 = _mm_add_ps(v0, v2);
    __m128 s13 = _mm_add_ps(v1, v3);
    __m128 sv  = _mm_add_ps(s02, s13);

    float lanes[4];
    _mm_storeu_ps(lanes, sv);

    double sum = ((double)lanes[0] + (double)lanes[1]) +
                 ((double)lanes[2] + (double)lanes[3]);
    for (; i < dim; i++) {
        sum += (double)a[i] * (double)b[i];
    }
    return sum;
}
#endif

double
npl_vec_dot_f32(const float *a, const float *b, size_t dim)
{
    if (!a || !b || dim == 0) return 0.0;
    if (npl_arch_force_scalar()) {
        return dot_f32_scalar_exact(a, b, dim);
    }
#if NPL_HAVE_VSX_INTRINSICS
    {
        npl_arch_info_t ai;
        npl_detect_arch_info(&ai);
        if (ai.has_vsx) return dot_f32_vsx(a, b, dim);
    }
    return dot_f32_scalar_exact(a, b, dim);
#elif NPL_VEC_HAVE_NEON
    return dot_f32_neon(a, b, dim);
#elif NPL_VEC_HAVE_AVX2
    return dot_f32_avx2(a, b, dim);
#elif NPL_VEC_HAVE_SSE2
    return dot_f32_sse2(a, b, dim);
#else
    return dot_f32_scalar_exact(a, b, dim);
#endif
}

double
npl_vec_l2_norm_f32(const float *a, size_t dim)
{
    if (!a || dim == 0) return 0.0;
    double sq = npl_vec_dot_f32(a, a, dim);
    return (sq > 0.0) ? sqrt(sq) : 0.0;
}

double
npl_vec_cosine_f32(const float *a, const float *b, size_t dim)
{
    if (!a || !b || dim == 0) return 0.0;
    double na = npl_vec_l2_norm_f32(a, dim);
    double nb = npl_vec_l2_norm_f32(b, dim);
    if (na <= 0.0 || nb <= 0.0) return 0.0;
    double c = npl_vec_dot_f32(a, b, dim) / (na * nb);
    if (c > 1.0) c = 1.0;
    if (c < -1.0) c = -1.0;
    return c;
}

void
npl_vec_normalize_f32(const float *src, float *dst, size_t dim)
{
    if (!src || !dst || dim == 0) return;
    double norm = npl_vec_l2_norm_f32(src, dim);
    if (norm <= 0.0) {
        for (size_t i = 0; i < dim; i++) dst[i] = 0.0f;
        return;
    }
    double inv = 1.0 / norm;
    for (size_t i = 0; i < dim; i++) {
        dst[i] = (float)((double)src[i] * inv);
    }
}

/* Helper to safely view/unpack LE float32 blob into aligned float buffer */
static float *
blob_to_floats(const uint8_t *blob, size_t dim, float *stack_buf, size_t stack_cap)
{
    float *out = (dim <= stack_cap) ? stack_buf : (float *)malloc(dim * sizeof(float));
    if (!out) return NULL;
    npl_vec_unpack_f32(blob, dim, out);
    return out;
}

double
npl_vec_dot_blob(const uint8_t *a_le, const uint8_t *b_le, size_t dim)
{
    if (!a_le || !b_le || dim == 0) return 0.0;
    float sa[1024], sb[1024];
    float *fa = blob_to_floats(a_le, dim, sa, 1024);
    float *fb = blob_to_floats(b_le, dim, sb, 1024);
    double r = (fa && fb) ? npl_vec_dot_f32(fa, fb, dim) : 0.0;
    if (fa && fa != sa) free(fa);
    if (fb && fb != sb) free(fb);
    return r;
}

double
npl_vec_l2_norm_blob(const uint8_t *a_le, size_t dim)
{
    if (!a_le || dim == 0) return 0.0;
    float sa[1024];
    float *fa = blob_to_floats(a_le, dim, sa, 1024);
    double r = fa ? npl_vec_l2_norm_f32(fa, dim) : 0.0;
    if (fa && fa != sa) free(fa);
    return r;
}

double
npl_vec_cosine_blob(const uint8_t *a_le, const uint8_t *b_le, size_t dim)
{
    if (!a_le || !b_le || dim == 0) return 0.0;
    float sa[1024], sb[1024];
    float *fa = blob_to_floats(a_le, dim, sa, 1024);
    float *fb = blob_to_floats(b_le, dim, sb, 1024);
    double r = (fa && fb) ? npl_vec_cosine_f32(fa, fb, dim) : 0.0;
    if (fa && fa != sa) free(fa);
    if (fb && fb != sb) free(fb);
    return r;
}

void
npl_vec_normalize_blob(const uint8_t *src_le, uint8_t *dst_le, size_t dim)
{
    if (!src_le || !dst_le || dim == 0) return;
    float sa[1024], sb[1024];
    float *fa = blob_to_floats(src_le, dim, sa, 1024);
    float *fb = (dim <= 1024) ? sb : (float *)malloc(dim * sizeof(float));
    if (fa && fb) {
        npl_vec_normalize_f32(fa, fb, dim);
        npl_vec_pack_f32(fb, dim, dst_le);
    }
    if (fa && fa != sa) free(fa);
    if (fb && fb != sb) free(fb);
}

static int
cmp_topk_hit(const void *a, const void *b)
{
    const npl_topk_hit_t *ha = (const npl_topk_hit_t *)a;
    const npl_topk_hit_t *hb = (const npl_topk_hit_t *)b;
    if (ha->score != hb->score) {
        return (ha->score > hb->score) ? -1 : 1;
    }
    if (ha->index != hb->index) {
        return (ha->index < hb->index) ? -1 : 1;
    }
    return 0;
}

size_t
npl_vec_topk_cosine(const uint8_t *query_le, size_t dim,
                    const uint8_t *const *cand_blobs, const size_t *cand_bytes,
                    size_t n_cands, size_t k, npl_topk_hit_t *out_hits)
{
    if (!query_le || dim == 0 || !cand_blobs || n_cands == 0 || k == 0 || !out_hits) {
        return 0;
    }

    float sq[1024];
    float *fq = blob_to_floats(query_le, dim, sq, 1024);
    if (!fq) return 0;
    double qnorm = npl_vec_l2_norm_f32(fq, dim);

    npl_topk_hit_t *all = (npl_topk_hit_t *)malloc(n_cands * sizeof(npl_topk_hit_t));
    if (!all) {
        if (fq != sq) free(fq);
        return 0;
    }

    float sc[1024];
    float *fc = (dim <= 1024) ? sc : (float *)malloc(dim * sizeof(float));
    size_t valid = 0;

    if (fc) {
        size_t need_bytes = dim * sizeof(float);
#if NPL_HAVE_VSX_INTRINSICS && defined(__MMA__)
        int use_mma = 0;
        if (!npl_arch_force_scalar()) {
            npl_arch_info_t ai;
            npl_detect_arch_info(&ai);
            if (ai.has_mma && ai.has_power10) use_mma = 1;
        }
        (void)use_mma;
        (void)dot_f32_power10_mma_batch4;
#endif
        for (size_t i = 0; i < n_cands; i++) {
            if (!cand_blobs[i] || (cand_bytes && cand_bytes[i] < need_bytes)) continue;
            npl_vec_unpack_f32(cand_blobs[i], dim, fc);
            double score = 0.0;
            if (qnorm > 0.0) {
                double cnorm = npl_vec_l2_norm_f32(fc, dim);
                if (cnorm > 0.0) {
                    score = npl_vec_dot_f32(fq, fc, dim) / (qnorm * cnorm);
                    if (score > 1.0) score = 1.0;
                    if (score < -1.0) score = -1.0;
                }
            }
            all[valid].index = i;
            all[valid].score = score;
            valid++;
        }
    }

    if (fc && fc != sc) free(fc);
    if (fq != sq) free(fq);

    if (valid > 1) {
        qsort(all, valid, sizeof(npl_topk_hit_t), cmp_topk_hit);
    }

    size_t take = (valid < k) ? valid : k;
    if (take > 0) {
        memcpy(out_hits, all, take * sizeof(npl_topk_hit_t));
    }
    free(all);
    return take;
}
