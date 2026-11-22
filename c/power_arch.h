/*
 * c/power_arch.h - Multi-architecture & IBM POWER8+ (ppc64le) runtime layer
 *
 * Provides:
 *  - Runtime POWER ISA feature detection via getauxval(AT_HWCAP2)
 *    (POWER8 VSX ARCH_2_07, POWER9 ARCH_3_00, POWER10 ARCH_3_1, MMA)
 *  - Clean <altivec.h> macro isolation (#undef vector/pixel/bool; use __vector)
 *  - Dynamic OS page size (npl_page_size() via sysconf(_SC_PAGESIZE), 64 KiB safe)
 *  - Weak-memory-model __atomic_* acquire/release helpers & POWER SMT yield
 *  - SMT-aware physical-core thread sizing (/sys/devices/system/cpu topology)
 *  - High-resolution mftb / platform timebase counter
 *  - /dev/crypto/nx-gzip hardware capability probe
 */
#ifndef NPL_POWER_ARCH_H
#define NPL_POWER_ARCH_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <unistd.h>
#  include <time.h>
#  if defined(__APPLE__)
#    include <sys/sysctl.h>
#  elif defined(__linux__)
#    if defined(__powerpc64__) || defined(__powerpc__)
#      include <sys/auxv.h>
#    endif
#  endif
#endif

/*
 * Clean <altivec.h> macro isolation on POWER8+ VSX translation units.
 * Pure C translation units that use VSX intrinsics define NPL_ENABLE_ALTIVEC
 * before including this header. Core.xs does not define it, keeping perl.h
 * completely isolated from Altivec preprocessor tokens.
 */
#if defined(NPL_ENABLE_ALTIVEC) && (defined(__powerpc64__) || defined(__powerpc__)) && defined(__VSX__)
#  include <stdbool.h>
#  include <altivec.h>
#  undef vector
#  undef pixel
#  undef bool
#  define bool _Bool
#  define NPL_HAVE_VSX_INTRINSICS 1
#else
#  define NPL_HAVE_VSX_INTRINSICS 0
#endif

/* IBM POWER AT_HWCAP2 feature bit definitions (ELFv2 Linux ABI) */
#ifndef NPL_PPC_FEATURE2_ARCH_2_07
#  define NPL_PPC_FEATURE2_ARCH_2_07 0x80000000UL
#endif
#ifndef NPL_PPC_FEATURE2_ARCH_3_00
#  define NPL_PPC_FEATURE2_ARCH_3_00 0x00800000UL
#endif
#ifndef NPL_PPC_FEATURE2_ARCH_3_1
#  define NPL_PPC_FEATURE2_ARCH_3_1  0x00040000UL
#endif
#ifndef NPL_PPC_FEATURE2_MMA
#  define NPL_PPC_FEATURE2_MMA       0x00020000UL
#endif
#ifndef NPL_PPC_FEATURE_HAS_VSX
#  define NPL_PPC_FEATURE_HAS_VSX    0x00000080UL
#endif

/*
 * Weak-memory-model atomic primitives (essential on POWER8/9/10 & ARM64).
 */
#if defined(_MSC_VER) && !defined(__clang__) && !defined(__GNUC__)
#  include <intrin.h>
#  define npl_atomic_load_acquire(ptr)          (*(volatile typeof(*(ptr)) *)(ptr))
#  define npl_atomic_store_release(ptr, val)    do { _ReadWriteBarrier(); *(volatile typeof(*(ptr)) *)(ptr) = (val); } while (0)
#  define npl_memory_fence_acq_rel()            MemoryBarrier()
#else
#  define npl_atomic_load_acquire(ptr)          __atomic_load_n((ptr), __ATOMIC_ACQUIRE)
#  define npl_atomic_store_release(ptr, val)    __atomic_store_n((ptr), (val), __ATOMIC_RELEASE)
#  define npl_atomic_fetch_add_acq_rel(ptr, v)  __atomic_fetch_add((ptr), (v), __ATOMIC_ACQ_REL)
#  define npl_memory_fence_acq_rel()            __atomic_thread_fence(__ATOMIC_ACQ_REL)
#endif

/*
 * Architecture spin-wait yield: lowers SMT thread priority on IBM POWER
 * (or 27,27,27) so spin-waiters never starve sibling hardware threads.
 */
static inline void
npl_smt_yield(void)
{
#if defined(__powerpc64__) || defined(__powerpc__)
    __asm__ __volatile__("or 27,27,27" ::: "memory");
#elif defined(__aarch64__) && !defined(_MSC_VER)
    __asm__ __volatile__("yield" ::: "memory");
#elif (defined(__x86_64__) || defined(__i386__)) && !defined(_MSC_VER)
    __asm__ __volatile__("pause" ::: "memory");
#elif defined(_WIN32)
    SwitchToThread();
#else
    npl_memory_fence_acq_rel();
#endif
}

/*
 * High-resolution hardware timebase ticks (mftb on POWER, monotonic fallback).
 */
static inline uint64_t
npl_timebase_ticks(void)
{
#if defined(__powerpc64__) || defined(__powerpc__)
    return (uint64_t)__builtin_ppc_get_timebase();
#elif defined(_WIN32)
    LARGE_INTEGER li;
    QueryPerformanceCounter(&li);
    return (uint64_t)li.QuadPart;
#elif defined(__aarch64__) && !defined(_MSC_VER)
    uint64_t v = 0;
    __asm__ __volatile__("mrs %0, cntvct_el0" : "=r"(v));
    return v;
#elif defined(__x86_64__) && !defined(_MSC_VER)
    uint32_t lo = 0, hi = 0;
    __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | (uint64_t)lo;
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
    }
    return 0;
#endif
}

/*
 * Dynamic PERL_FORCE_SCALAR=1 check so callers/tests can toggle parity live.
 */
static inline int
npl_arch_force_scalar(void)
{
    const char *v = getenv("PERL_FORCE_SCALAR");
    return (v && v[0] == '1' && v[1] == '\0') ? 1 : 0;
}

/*
 * Dynamic OS virtual memory page size (64 KiB on Linux ppc64le, 16 KiB on
 * Apple Silicon macOS, 4 KiB on x86_64). Never hardcodes 4096.
 */
static inline size_t
npl_page_size(void)
{
    static size_t cached_pg = 0;
    size_t pg = npl_atomic_load_acquire(&cached_pg);
    if (pg != 0) return pg;

#if defined(_WIN32)
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    pg = (si.dwPageSize > 0u) ? (size_t)si.dwPageSize : 65536u;
#else
    long v = sysconf(_SC_PAGESIZE);
    pg = (v > 0) ? (size_t)v : 65536u;
#endif
    npl_atomic_store_release(&cached_pg, pg);
    return pg;
}

typedef struct npl_arch_info {
    const char   *arch;
    size_t        page_size;
    int           logical_cpus;
    int           physical_cores;
    int           recommended_workers;
    const char   *simd_level;
    const char   *power_isa;
    unsigned long hwcap2;
    int           has_vsx;
    int           has_power8;
    int           has_power9;
    int           has_power10;
    int           has_mma;
    int           has_neon;
    int           has_sse2;
    int           has_avx2;
    int           has_nx_gzip;
} npl_arch_info_t;

#if !defined(_WIN32) && defined(__linux__)
static inline int
npl_read_sysfs_int(const char *path, int *out)
{
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    int val = -1;
    int ok = (fscanf(fp, "%d", &val) == 1);
    fclose(fp);
    if (ok && val >= 0) {
        *out = val;
        return 1;
    }
    return 0;
}

static inline int
npl_linux_physical_cores(int logical_cpus)
{
    if (logical_cpus <= 1) return 1;
    int limit = logical_cpus;
    if (limit > 512) limit = 512;

    uint64_t seen[512];
    int nseen = 0;

    for (int cpu = 0; cpu < limit; cpu++) {
        char path_core[128];
        char path_pkg[128];
        int core_id = -1;
        int pkg_id = 0;
        (void)snprintf(path_core, sizeof(path_core),
                       "/sys/devices/system/cpu/cpu%d/topology/core_id", cpu);
        if (!npl_read_sysfs_int(path_core, &core_id)) continue;

        (void)snprintf(path_pkg, sizeof(path_pkg),
                       "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", cpu);
        (void)npl_read_sysfs_int(path_pkg, &pkg_id);

        uint64_t key = ((uint64_t)(uint32_t)pkg_id << 32) | (uint64_t)(uint32_t)core_id;
        int dup = 0;
        for (int j = 0; j < nseen; j++) {
            if (seen[j] == key) {
                dup = 1;
                break;
            }
        }
        if (!dup && nseen < 512) {
            seen[nseen++] = key;
        }
    }
    if (nseen > 0) return nseen;
    return logical_cpus;
}
#endif

static inline void
npl_detect_arch_info(npl_arch_info_t *info)
{
    memset(info, 0, sizeof(*info));
    info->page_size = npl_page_size();
    info->power_isa = "none";

#if defined(__powerpc64__)
#  if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && \
      (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
    info->arch = "ppc64le";
#  else
    info->arch = "ppc64";
#  endif
#elif defined(__aarch64__) || defined(_M_ARM64)
    info->arch = "arm64";
#elif defined(__x86_64__) || defined(_M_X64)
    info->arch = "x86_64";
#elif defined(__i386__) || defined(_M_IX86)
    info->arch = "x86";
#else
    info->arch = "unknown";
#endif

    /* Logical & SMT-aware physical core detection */
#if defined(_WIN32)
    {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        info->logical_cpus = (si.dwNumberOfProcessors > 0u) ? (int)si.dwNumberOfProcessors : 1;
        info->physical_cores = info->logical_cpus;
    }
#elif defined(__APPLE__)
    {
        int nlog = 1, nphys = 1;
        size_t sz = sizeof(int);
        if (sysctlbyname("hw.logicalcpu", &nlog, &sz, NULL, 0) != 0 || nlog < 1) {
            long sc = sysconf(_SC_NPROCESSORS_ONLN);
            nlog = (sc > 0) ? (int)sc : 1;
        }
        sz = sizeof(int);
        if (sysctlbyname("hw.physicalcpu", &nphys, &sz, NULL, 0) != 0 || nphys < 1) {
            nphys = nlog;
        }
        info->logical_cpus = nlog;
        info->physical_cores = nphys;
    }
#elif defined(__linux__)
    {
        long sc = sysconf(_SC_NPROCESSORS_ONLN);
        info->logical_cpus = (sc > 0) ? (int)sc : 1;
        info->physical_cores = npl_linux_physical_cores(info->logical_cpus);
    }
#else
    {
        long sc = sysconf(_SC_NPROCESSORS_ONLN);
        info->logical_cpus = (sc > 0) ? (int)sc : 1;
        info->physical_cores = info->logical_cpus;
    }
#endif

    /* Hardware ISA capabilities */
#if !defined(_WIN32) && defined(__linux__) && (defined(__powerpc64__) || defined(__powerpc__))
    {
        unsigned long hwcap  = getauxval(AT_HWCAP);
        unsigned long hwcap2 = getauxval(AT_HWCAP2);
        info->hwcap2 = hwcap2;
        if ((hwcap & NPL_PPC_FEATURE_HAS_VSX) != 0UL) {
            info->has_vsx = 1;
        }
        if ((hwcap2 & NPL_PPC_FEATURE2_ARCH_2_07) != 0UL) {
            info->has_power8 = 1;
            info->has_vsx = 1;
            info->power_isa = "power8";
        }
        if ((hwcap2 & NPL_PPC_FEATURE2_ARCH_3_00) != 0UL) {
            info->has_power9 = 1;
            info->power_isa = "power9";
        }
        if ((hwcap2 & NPL_PPC_FEATURE2_ARCH_3_1) != 0UL) {
            info->has_power10 = 1;
            info->power_isa = "power10";
        }
        if ((hwcap2 & NPL_PPC_FEATURE2_MMA) != 0UL) {
            info->has_mma = 1;
        }
        if (access("/dev/crypto/nx-gzip", F_OK) == 0) {
            info->has_nx_gzip = 1;
        }
    }
#elif defined(__aarch64__) || defined(_M_ARM64)
    info->has_neon = 1;
#elif defined(__x86_64__) || defined(_M_X64)
    info->has_sse2 = 1;
#  if defined(__AVX2__)
    info->has_avx2 = 1;
#  endif
#endif

    /* Effective SIMD level (honors PERL_FORCE_SCALAR=1 live) */
    if (npl_arch_force_scalar()) {
        info->simd_level = "scalar";
        info->recommended_workers = 1;
    } else {
        int w = info->physical_cores;
        if (w < 1) w = 1;
        if (w > 16) w = 16;
        info->recommended_workers = w;

#if defined(__powerpc64__) || defined(__powerpc__)
        if (info->has_mma && info->has_power10) {
            info->simd_level = "power10-mma";
        } else if (info->has_power10 && info->has_vsx) {
            info->simd_level = "power10-vsx";
        } else if (info->has_power9 && info->has_vsx) {
            info->simd_level = "power9-vsx";
        } else if (info->has_vsx) {
            info->simd_level = "power8-vsx";
        } else {
            info->simd_level = "scalar";
        }
#elif defined(__aarch64__) || defined(_M_ARM64)
        info->simd_level = "neon";
#elif defined(__x86_64__) || defined(_M_X64)
#  if defined(__AVX2__)
        info->simd_level = "avx2";
#  else
        info->simd_level = "sse2";
#  endif
#else
        info->simd_level = "scalar";
#endif
    }
}

#endif /* NPL_POWER_ARCH_H */
