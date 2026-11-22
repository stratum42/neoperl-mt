package NeoPerl::MCP::Pack::AMDGPU;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

use File::Spec ();
use File::Temp ();
use IPC::Open3 qw(open3);
use POSIX qw(ceil);
use Symbol qw(gensym);

our $VERSION = '0.01';

my %ARCH_ALIASES = (
    gfx90a   => 'gfx90a',
    cdna2    => 'gfx90a',
    mi250x   => 'gfx90a',
    mi250    => 'gfx90a',
    mi210    => 'gfx90a',
    aldebaran => 'gfx90a',

    gfx942   => 'gfx942',
    cdna3    => 'gfx942',
    mi300x   => 'gfx942',
    mi300a   => 'gfx942',
    mi300    => 'gfx942',
    mi325x   => 'gfx942',

    gfx1100  => 'gfx1100',
    rdna3    => 'gfx1100',
    navi31   => 'gfx1100',
    rx7900   => 'gfx1100',
    rx7900xtx => 'gfx1100',
    rx7900xt => 'gfx1100',
    w7900    => 'gfx1100',

    gfx1200  => 'gfx1200',
    gfx1201  => 'gfx1200',
    rdna4    => 'gfx1200',
    navi48   => 'gfx1200',
    rx9070   => 'gfx1200',
    rx9070xt => 'gfx1200',
);

my @ARCH_ORDER = qw(gfx90a gfx942 gfx1100 gfx1200);

my %ARCH_SPECS = (
    gfx90a => {
        arch                   => 'gfx90a',
        label                  => 'AMD CDNA2 (Instinct MI210 / MI250 / MI250X)',
        family                 => 'CDNA2',
        default_wave_size      => 64,
        supported_wave_sizes   => [ 64 ],
        unit_name              => 'CU',
        simds_per_cu           => 4,
        max_waves_per_simd     => 8,
        max_waves_per_cu       => 32,
        max_wgs_per_cu         => 16,
        max_workgroup_size     => 1024,
        unified_vgpr_agpr_pool => 1,
        vgpr_pool_per_simd     => 512,
        max_vgprs_per_thread   => 256,
        max_agprs_per_thread   => 256,
        vgpr_alloc_granularity => 8,
        agpr_offset_granularity => 4,
        sgpr_pool_per_simd     => 800,
        max_sgprs_per_wave     => 102,
        sgpr_alloc_granularity => 8,
        sgpr_limits_occupancy  => 1,
        lds_bytes_per_cu       => 65536,
        lds_kib_per_cu         => 64,
        lds_banks              => 32,
        lds_bank_stride_bytes  => 4,
        lds_alloc_granularity  => 512,
        l1_cache_kib_per_cu    => 16,
        cache_line_bytes       => 64,
        memory_type            => 'HBM2e',
        memory_bandwidth_gbps  => 1638,
        memory_bandwidth_note  => '1.6 TB/s per GCD (3.2 TB/s dual-GCD MI250X), 64 GiB/GCD (128 GiB total)',
        matrix_engine          => 'MFMA (Matrix Core Gen 2)',
        fp8_supported          => 0,
        matrix_instructions    => [
            'v_mfma_f32_16x16x16_bf16 (BF16 -> FP32)',
            'v_mfma_f32_16x16x16_f16 (FP16 -> FP32)',
            'v_mfma_f32_32x32x8_f16 (FP16 -> FP32)',
            'v_mfma_f32_32x32x8_bf16 (BF16 -> FP32)',
            'v_mfma_f64_16x16x4_f64 (Native FP64 Matrix Core)',
            'v_mfma_i32_16x16x16_i8 (INT8 -> INT32)',
        ],
        notes => [
            'Strictly wave64 (warpSize == 64); 32-bit ballot masks (0xffffffff) drop the upper 32 lanes.',
            'Unified 512-register VGPR+AGPR pool per SIMD (128 KiB/SIMD, 512 KiB/CU), allocated in blocks of 8.',
            '64 KiB LDS per CU across 32 banks x 4B stride; native FP64 MFMA support (no FP8 on CDNA2).',
        ],
    },
    gfx942 => {
        arch                   => 'gfx942',
        label                  => 'AMD CDNA3 (Instinct MI300X / MI300A)',
        family                 => 'CDNA3',
        default_wave_size      => 64,
        supported_wave_sizes   => [ 64 ],
        unit_name              => 'CU',
        simds_per_cu           => 4,
        max_waves_per_simd     => 8,
        max_waves_per_cu       => 32,
        max_wgs_per_cu         => 16,
        max_workgroup_size     => 1024,
        unified_vgpr_agpr_pool => 1,
        vgpr_pool_per_simd     => 512,
        max_vgprs_per_thread   => 256,
        max_agprs_per_thread   => 256,
        vgpr_alloc_granularity => 8,
        agpr_offset_granularity => 4,
        sgpr_pool_per_simd     => 800,
        max_sgprs_per_wave     => 102,
        sgpr_alloc_granularity => 8,
        sgpr_limits_occupancy  => 1,
        lds_bytes_per_cu       => 65536,
        lds_kib_per_cu         => 64,
        lds_banks              => 32,
        lds_bank_stride_bytes  => 4,
        lds_alloc_granularity  => 512,
        l1_cache_kib_per_cu    => 32,
        cache_line_bytes       => 128,
        memory_type            => 'HBM3',
        memory_bandwidth_gbps  => 5300,
        memory_bandwidth_note  => '5.3 TB/s HBM3, 192 GiB capacity, 304 CUs across 8 XCDs + 256 MiB Infinity Cache (MI300X)',
        matrix_engine          => 'MFMA (Matrix Core Gen 3: FP8/BF8/XF32/Sparsity)',
        fp8_supported          => 1,
        matrix_instructions    => [
            'v_mfma_f32_16x16x16_bf16 (BF16 -> FP32)',
            'v_mfma_f32_16x16x16_f16 (FP16 -> FP32)',
            'v_mfma_f32_32x32x8_f16 (FP16 -> FP32)',
            'v_mfma_f32_16x16x32_fp8_fp8 (E4M3 FNUZ FP8 -> FP32)',
            'v_mfma_f32_16x16x32_bf8_bf8 (E5M2 FNUZ BF8 -> FP32)',
            'v_mfma_f32_32x32x16_fp8_fp8 (FP8 -> FP32)',
            'v_mfma_f32_16x16x8_xf32 (TF32/XF32 -> FP32)',
            'v_mfma_f64_16x16x4_f64 (Native FP64 Matrix Core)',
            'v_mfma_i32_16x16x32_i8 (INT8 -> INT32)',
        ],
        notes => [
            'Strictly wave64 (warpSize == 64); always use uint64_t for __ballot() masks and warpSize-parameterized reductions.',
            'Unified 512-register VGPR+AGPR pool per SIMD (alloc granularity 8); keep VGPR+AGPR <= 128 for 4 waves/SIMD (50%) or <= 64 for 8 waves/SIMD (100%).',
            'Adds native FP8/BF8 MFMA (v_mfma_f32_16x16x32_fp8_fp8), XF32, 2:4 structured sparsity, 32 KiB L1/CU, and 5.3 TB/s HBM3.',
        ],
    },
    gfx1100 => {
        arch                   => 'gfx1100',
        label                  => 'AMD RDNA3 (Radeon RX 7900 XTX / W7900 / Navi 31)',
        family                 => 'RDNA3',
        default_wave_size      => 32,
        supported_wave_sizes   => [ 32, 64 ],
        unit_name              => 'WGP (2 CUs)',
        simds_per_cu           => 2,
        simds_per_wgp          => 4,
        max_waves_per_simd     => 16,
        max_waves_per_cu       => 32,
        max_waves_per_wgp      => 64,
        max_wgs_per_cu         => 16,
        max_wgs_per_wgp        => 32,
        max_workgroup_size     => 1024,
        unified_vgpr_agpr_pool => 0,
        vgpr_pool_per_simd_w32 => 1536,
        vgpr_pool_per_simd_w64 => 768,
        vgpr_pool_per_simd     => 1536,
        max_vgprs_per_thread   => 256,
        max_agprs_per_thread   => 0,
        vgpr_alloc_granularity_w32 => 24,
        vgpr_alloc_granularity_w64 => 12,
        vgpr_alloc_granularity => 24,
        sgpr_pool_per_simd     => 2048,
        max_sgprs_per_wave     => 106,
        sgpr_alloc_granularity => 128,
        sgpr_limits_occupancy  => 0,
        lds_bytes_per_cu       => 65536,
        lds_bytes_per_wgp      => 131072,
        lds_kib_per_cu         => 64,
        lds_banks              => 32,
        lds_bank_stride_bytes  => 4,
        lds_alloc_granularity  => 512,
        l1_cache_kib_per_cu    => 32,
        cache_line_bytes       => 128,
        memory_type            => 'GDDR6 + Infinity Cache',
        memory_bandwidth_gbps  => 960,
        memory_bandwidth_note  => '960 GB/s 384-bit GDDR6 + 96 MiB Infinity Cache (RX 7900 XTX)',
        matrix_engine          => 'WMMA (Wave Matrix Multiply-Accumulate)',
        fp8_supported          => 0,
        matrix_instructions    => [
            'v_wmma_f32_16x16x16_f16 (FP16 -> FP32)',
            'v_wmma_f32_16x16x16_bf16 (BF16 -> FP32)',
            'v_wmma_f16_16x16x16_f16 (FP16 -> FP16)',
            'v_wmma_i32_16x16x16_iu8 (INT8 -> INT32)',
            'v_wmma_i32_16x16x16_iu4 (INT4 -> INT32)',
        ],
        notes => [
            'Native wave32 dual-issue SIMD32 (2 SIMD32/CU, 4 SIMD32/WGP); optional wave64 mode.',
            '1536 VGPRs per SIMD32 (24-VGPR granularity in wave32); no separate AGPR file; dedicated per-wave SGPRs do not limit occupancy.',
            '64 KiB LDS per CU (128 KiB per WGP, max 64 KiB per workgroup), 32 banks x 4B stride.',
        ],
    },
    gfx1200 => {
        arch                   => 'gfx1200',
        label                  => 'AMD RDNA4 (Radeon RX 9070 / Navi 48)',
        family                 => 'RDNA4',
        default_wave_size      => 32,
        supported_wave_sizes   => [ 32, 64 ],
        unit_name              => 'WGP (2 CUs)',
        simds_per_cu           => 2,
        simds_per_wgp          => 4,
        max_waves_per_simd     => 16,
        max_waves_per_cu       => 32,
        max_waves_per_wgp      => 64,
        max_wgs_per_cu         => 16,
        max_wgs_per_wgp        => 32,
        max_workgroup_size     => 1024,
        unified_vgpr_agpr_pool => 0,
        vgpr_pool_per_simd_w32 => 1536,
        vgpr_pool_per_simd_w64 => 768,
        vgpr_pool_per_simd     => 1536,
        max_vgprs_per_thread   => 256,
        max_agprs_per_thread   => 0,
        vgpr_alloc_granularity_w32 => 24,
        vgpr_alloc_granularity_w64 => 12,
        vgpr_alloc_granularity => 24,
        sgpr_pool_per_simd     => 2048,
        max_sgprs_per_wave     => 106,
        sgpr_alloc_granularity => 128,
        sgpr_limits_occupancy  => 0,
        lds_bytes_per_cu       => 65536,
        lds_bytes_per_wgp      => 131072,
        lds_kib_per_cu         => 64,
        lds_banks              => 32,
        lds_bank_stride_bytes  => 4,
        lds_alloc_granularity  => 512,
        l1_cache_kib_per_cu    => 32,
        cache_line_bytes       => 128,
        memory_type            => 'GDDR6 + Infinity Cache',
        memory_bandwidth_gbps  => 640,
        memory_bandwidth_note  => '640 GB/s 256-bit GDDR6 + 64 MiB Infinity Cache (Navi 48)',
        matrix_engine          => 'WMMA v2 (FP8/BF8 + Structured Sparsity)',
        fp8_supported          => 1,
        matrix_instructions    => [
            'v_wmma_f32_16x16x16_f16 (FP16 -> FP32)',
            'v_wmma_f32_16x16x16_bf16 (BF16 -> FP32)',
            'v_wmma_f32_16x16x16_fp8_fp8 (FP8 -> FP32)',
            'v_wmma_f32_16x16x16_bf8_bf8 (BF8 -> FP32)',
            'v_wmma_i32_16x16x16_iu8 (INT8 -> INT32)',
            'v_swmmac_f32_16x16x32_f16 (2:4 Sparse WMMA)',
        ],
        notes => [
            'Native wave32 dual-issue SIMD32 with dynamic VGPR allocation support and out-of-order memory subsystem.',
            'WMMA v2 doubles matrix throughput and adds native FP8/BF8 and 2:4 structured sparsity.',
            '64 KiB LDS per CU (128 KiB per WGP), 32 banks x 4B stride; per-wave SGPRs do not limit occupancy.',
        ],
    },
);

my %HIP_ISA_DB = (
    'hipLaunchKernelGGL' => {
        symbol    => 'hipLaunchKernelGGL',
        category  => 'hip_runtime',
        kind      => 'function',
        signature => 'hipLaunchKernelGGL(kernelName, dim3 numBlocks, dim3 dimBlocks, size_t sharedMemBytes, hipStream_t stream, args...)',
        summary   => 'Portable HIP macro for launching a __global__ kernel onto an AMD GPU stream (also supports <<<grid, block, shmem, stream>>> syntax).',
        details   => 'Always follow with hipGetLastError() in debug builds. Pass dynamic LDS size in sharedMemBytes aligned to 16 bytes.',
        example   => 'hipLaunchKernelGGL(gemm_kernel, grid, block, 16384, stream, dA, dB, dC, M, N, K);',
    },
    'hipMalloc' => {
        symbol    => 'hipMalloc',
        category  => 'hip_runtime',
        kind      => 'function',
        signature => 'hipError_t hipMalloc(void** ptr, size_t size)',
        summary   => 'Allocates device-resident memory in AMD GPU HBM/GDDR6.',
        details   => 'Allocations are at least 256-byte aligned (ideal for global_load_dwordx4 coalescing). Pair with hipFree().',
        example   => 'float* d_x = nullptr; hipMalloc(&d_x, N * sizeof(float));',
    },
    'hipMemcpyAsync' => {
        symbol    => 'hipMemcpyAsync',
        category  => 'hip_runtime',
        kind      => 'function',
        signature => 'hipError_t hipMemcpyAsync(void* dst, const void* src, size_t sizeBytes, hipMemcpyKind kind, hipStream_t stream)',
        summary   => 'Enqueues an asynchronous host<->device or device<->device DMA copy on a HIP stream.',
        details   => 'Requires pinned host memory (hipHostMalloc) for true non-blocking SDMA overlap with compute kernels.',
        example   => 'hipMemcpyAsync(d_x, h_pinned, bytes, hipMemcpyHostToDevice, stream);',
    },
    'hipStreamCreateWithFlags' => {
        symbol    => 'hipStreamCreateWithFlags',
        category  => 'hip_runtime',
        kind      => 'function',
        signature => 'hipError_t hipStreamCreateWithFlags(hipStream_t* stream, unsigned int flags)',
        summary   => 'Creates an asynchronous HIP execution stream; pass hipStreamNonBlocking to avoid implicit synchronization with the legacy default stream.',
        details   => 'Critical for multi-stream overlap of SDMA copies, RCCL collectives, and compute kernels on MI250X/MI300X.',
        example   => 'hipStream_t s; hipStreamCreateWithFlags(&s, hipStreamNonBlocking);',
    },
    '__shfl_xor' => {
        symbol    => '__shfl_xor',
        category  => 'hip_device',
        kind      => 'function',
        signature => 'T __shfl_xor(T var, int laneMask, int width = warpSize)',
        summary   => 'Wavefront butterfly XOR lane exchange directly in VGPRs via ds_bpermute / v_permlane / dpp.',
        details   => 'Unlike CUDA __shfl_xor_sync(mask, ...), HIP __shfl_xor takes no mask parameter. Always start butterfly reductions at offset = warpSize / 2 (32 on CDNA wave64, 16 on RDNA wave32).',
        example   => 'for (int off = warpSize / 2; off > 0; off >>= 1) val += __shfl_xor(val, off);',
    },
    '__shfl_down' => {
        symbol    => '__shfl_down',
        category  => 'hip_device',
        kind      => 'function',
        signature => 'T __shfl_down(T var, unsigned int delta, int width = warpSize)',
        summary   => 'Shifts values down by delta lanes within a wavefront (or sub-wavefront width).',
        details   => 'Loop from delta = warpSize / 2 down to 1 so the code works identically on CDNA wave64 and RDNA wave32.',
        example   => 'for (int d = warpSize >> 1; d > 0; d >>= 1) sum += __shfl_down(sum, d);',
    },
    '__ballot' => {
        symbol    => '__ballot',
        category  => 'hip_device',
        kind      => 'function',
        signature => 'uint64_t __ballot(int predicate)',
        summary   => 'Evaluates predicate across all active lanes in the wavefront and returns a 64-bit bitmask (uint64_t).',
        details   => 'CDNA note: __ballot() returns a 64-bit mask (uint64_t / unsigned long long) because CDNA wavefronts have 64 lanes. Storing it in uint32_t or masking with 0xffffffff silently drops lanes 32..63.',
        example   => 'uint64_t mask = __ballot(val > 0.0f); int cnt = __popcll(mask);',
    },
    '__syncthreads' => {
        symbol    => '__syncthreads',
        category  => 'hip_device',
        kind      => 'function',
        signature => 'void __syncthreads()',
        summary   => 'Work-group barrier emitting s_waitcnt lgkmcnt(0) + s_barrier so all LDS writes are visible to every wavefront in the block.',
        details   => 'Must be reached uniformly by EVERY thread in the block; calling __syncthreads() inside a thread-divergent branch hangs the GPU.',
        example   => 'lds[tid] = val; __syncthreads(); float neighbor = lds[tid ^ 1];',
    },
    '__launch_bounds__' => {
        symbol    => '__launch_bounds__',
        category  => 'hip_device',
        kind      => 'keyword',
        signature => '__global__ __launch_bounds__(maxThreadsPerBlock, minBlocksPerMultiprocessor) void kernel(...)',
        summary   => 'Guides the LLVM AMDGPU register allocator on target workgroup size and minimum wave occupancy per CU.',
        details   => 'Without __launch_bounds__, clang/hipcc defaults to conservative 1024-thread assumptions, potentially over-restricting or spilling VGPRs. On CDNA, minBlocks = 2 with 256 threads targets 4 waves/CU (1 wave/SIMD) or set explicitly to match your occupancy target.',
        example   => '__global__ __launch_bounds__(256, 2) void sgemm_kernel(const float* A, const float* B, float* C) { ... }',
    },
    'warpSize' => {
        symbol    => 'warpSize',
        category  => 'hip_device',
        kind      => 'constant',
        signature => 'constexpr int warpSize (64 on CDNA gfx90a/gfx942; 32 on RDNA gfx1100/gfx1200)',
        summary   => 'Compile-time/architecture wavefront lane width: 64 on CDNA2/CDNA3, 32 on RDNA3/RDNA4.',
        details   => 'Do not hardcode 32, & 31, >> 5, or 0xffffffff. Always compute lane = threadIdx.x & (warpSize - 1) and use uint64_t masks.',
        example   => 'const int lane = threadIdx.x & (warpSize - 1); const int wid = threadIdx.x / warpSize;',
    },
    '__builtin_amdgcn_mfma_f32_16x16x16bf16_1k' => {
        symbol    => '__builtin_amdgcn_mfma_f32_16x16x16bf16_1k',
        category  => 'mfma',
        kind      => 'function',
        signature => 'float4 __builtin_amdgcn_mfma_f32_16x16x16bf16_1k(short4 a, short4 b, float4 c, int cbsz, int abid, int blgp)',
        summary   => 'CDNA2/CDNA3 intrinsic emitting v_mfma_f32_16x16x16_bf16 (16x16x16 BF16 multiply-accumulate into 4 FP32 accumulator registers per lane).',
        details   => 'Operates across a full wave64; places accumulator tile in AGPRs (CDNA2/CDNA3) to free VGPRs for global/LDS prefetching.',
        example   => 'acc = __builtin_amdgcn_mfma_f32_16x16x16bf16_1k(a_vec, b_vec, acc, 0, 0, 0);',
    },
    '__builtin_amdgcn_mfma_f32_32x32x8f16' => {
        symbol    => '__builtin_amdgcn_mfma_f32_32x32x8f16',
        category  => 'mfma',
        kind      => 'function',
        signature => 'float16 __builtin_amdgcn_mfma_f32_32x32x8f16(half4 a, half4 b, float16 c, int cbsz, int abid, int blgp)',
        summary   => 'CDNA2/CDNA3 32x32x8 FP16 MFMA accumulating into 16 FP32 elements per lane.',
        details   => 'Maximizes arithmetic intensity per operand load (32x32 output tile per wave64) when AGPR budget permits.',
        example   => 'acc16 = __builtin_amdgcn_mfma_f32_32x32x8f16(a4, b4, acc16, 0, 0, 0);',
    },
    '__builtin_amdgcn_mfma_f32_16x16x32_fp8_fp8' => {
        symbol    => '__builtin_amdgcn_mfma_f32_16x16x32_fp8_fp8',
        category  => 'mfma',
        kind      => 'function',
        signature => 'float4 __builtin_amdgcn_mfma_f32_16x16x32_fp8_fp8(long a, long b, float4 c, int cbsz, int abid, int blgp)',
        summary   => 'CDNA3 (gfx942 MI300X) native FP8 (E4M3 FNUZ) 16x16x32 MFMA intrinsic accumulating into FP32.',
        details   => 'Doubles K-dimension throughput over FP16/BF16 on gfx942. Not available on CDNA2 (gfx90a).',
        example   => 'acc = __builtin_amdgcn_mfma_f32_16x16x32_fp8_fp8(a_fp8x8, b_fp8x8, acc, 0, 0, 0);',
    },
    '__builtin_amdgcn_wmma_f32_16x16x16_f16_w32' => {
        symbol    => '__builtin_amdgcn_wmma_f32_16x16x16_f16_w32',
        category  => 'wmma',
        kind      => 'function',
        signature => 'float8 __builtin_amdgcn_wmma_f32_16x16x16_f16_w32(half16 a, half16 b, float8 c)',
        summary   => 'RDNA3/RDNA4 (gfx1100/gfx1200) wave32 WMMA 16x16x16 FP16 -> FP32 matrix intrinsic.',
        details   => 'Executes across a 32-lane RDNA wavefront using VGPRs (RDNA has no AGPR file).',
        example   => 'c_frag = __builtin_amdgcn_wmma_f32_16x16x16_f16_w32(a_frag, b_frag, c_frag);',
    },
    '__builtin_amdgcn_sched_barrier' => {
        symbol    => '__builtin_amdgcn_sched_barrier',
        category  => 'mfma',
        kind      => 'function',
        signature => 'void __builtin_amdgcn_sched_barrier(int mask)',
        summary   => 'Constrains LLVM AMDGPU machine instruction scheduling across software-pipelined GEMM/MFMA stages.',
        details   => 'Mask 0 blocks all movement across the barrier; combine with __builtin_amdgcn_sched_group_barrier to interleave global_load, ds_read, and v_mfma cleanly.',
        example   => '__builtin_amdgcn_sched_barrier(0);',
    },
    'global_load_dwordx4' => {
        symbol    => 'global_load_dwordx4',
        category  => 'isa',
        kind      => 'operator',
        signature => 'global_load_dwordx4 v[dst:dst+3], v[addr:addr+1], s[saddr:saddr+1] offset:N',
        summary   => 'AMDGPU ISA 128-bit (16-byte / float4) coalesced vector load from global memory.',
        details   => 'Maximizes HBM3/GDDR6 bus efficiency and cuts VMEM instruction issue pressure by 4x vs scalar global_load_dword. Requires 16-byte aligned pointers (`reinterpret_cast<const float4*>`).',
        example   => 'global_load_dwordx4 v[4:7], v[0:1], off offset:0',
    },
    'ds_read_b128' => {
        symbol    => 'ds_read_b128',
        category  => 'isa',
        kind      => 'operator',
        signature => 'ds_read_b128 v[dst:dst+3], vaddr offset:N',
        summary   => 'AMDGPU ISA 128-bit (4-dword) load from Local Data Share (LDS).',
        details   => 'Issues 4 dwords per lane from 32-bank LDS; keep adjacent lanes bank-conflict-free via padded or XOR-swizzled LDS tiles. Tracked by lgkmcnt.',
        example   => 'ds_read_b128 v[16:19], v2 offset:256',
    },
    'ds_write_b128' => {
        symbol    => 'ds_write_b128',
        category  => 'isa',
        kind      => 'operator',
        signature => 'ds_write_b128 vaddr, v[src:src+3] offset:N',
        summary   => 'AMDGPU ISA 128-bit (4-dword) store into Local Data Share (LDS).',
        details   => 'Pair with global_load_dwordx4 (or direct global_load_lds on CDNA) for high-bandwidth tile staging.',
        example   => 'ds_write_b128 v2, v[4:7] offset:0',
    },
    's_waitcnt' => {
        symbol    => 's_waitcnt',
        category  => 'isa',
        kind      => 'operator',
        signature => 's_waitcnt vmcnt(N) lgkmcnt(M) expcnt(K)',
        summary   => 'AMDGPU scalar wait-counter instruction stalling until outstanding VMEM (vmcnt) and LDS/SMEM (lgkmcnt) operations drain to <= N/M.',
        details   => 'vmcnt tracks global/buffer vector loads (and stores on CDNA; RDNA3/4 uses s_waitcnt_vscnt for vector stores). lgkmcnt tracks LDS (ds_read/ds_write) and scalar memory (s_load). Software pipelining uses non-zero vmcnt(k) to overlap loads with MFMA.',
        example   => 's_waitcnt vmcnt(1) lgkmcnt(0)',
    },
    'v_mfma_f32_16x16x16_bf16' => {
        symbol    => 'v_mfma_f32_16x16x16_bf16',
        category  => 'isa',
        kind      => 'operator',
        signature => 'v_mfma_f32_16x16x16_bf16 a[0:3], v[4:5], v[6:7], a[0:3]',
        summary   => 'CDNA2/CDNA3 hardware Matrix Core instruction performing 16x16x16 BF16 GEMM directly into AGPR accumulators.',
        details   => 'On gfx942 (MI300X), executes in 16 cycles per wave64 (peak matrix throughput).',
        example   => 'v_mfma_f32_16x16x16_bf16 a[0:3], v[8:9], v[10:11], a[0:3]',
    },
    'v_mfma_f32_32x32x8_f16' => {
        symbol    => 'v_mfma_f32_32x32x8_f16',
        category  => 'isa',
        kind      => 'operator',
        signature => 'v_mfma_f32_32x32x8_f16 a[0:15], v[4:5], v[6:7], a[0:15]',
        summary   => 'CDNA2/CDNA3 hardware Matrix Core instruction computing a 32x32x8 FP16 outer-product tile into 16 AGPRs/lane.',
        details   => 'High compute-to-operand ratio; requires 16 AGPRs per accumulator tile.',
        example   => 'v_mfma_f32_32x32x8_f16 a[0:15], v[4:5], v[6:7], a[0:15]',
    },
    'v_wmma_f32_16x16x16_f16' => {
        symbol    => 'v_wmma_f32_16x16x16_f16',
        category  => 'isa',
        kind      => 'operator',
        signature => 'v_wmma_f32_16x16x16_f16 v[0:7], v[8:15], v[16:23], v[0:7]',
        summary   => 'RDNA3/RDNA4 hardware Wave Matrix Multiply-Accumulate instruction (16x16x16 FP16 -> FP32 across wave32).',
        details   => 'Stores fragments and accumulators in VGPRs.',
        example   => 'v_wmma_f32_16x16x16_f16 v[0:7], v[8:15], v[16:23], v[0:7]',
    },
);

sub meta {
    return {
        name             => 'amd_gpu',
        label            => 'AMD GPU Compute (ROCm / HIP / CDNA & RDNA)',
        category         => 'gpu',
        version          => $VERSION,
        description      => 'AMD GPU compute architecture specs (CDNA2 gfx90a, CDNA3 gfx942 MI300X, RDNA3 gfx1100, RDNA4 gfx1200), exact VGPR/SGPR/AGPR/LDS wave occupancy calculator, HIP & AMDGPU ISA reference, and wave64/LDS kernel auditor.',
        filetypes        => [qw(hip rocm cu cuh amdgcn)],
        upstream_credits => [
            'AMD ROCm / HIP Programming Guide',
            'AMD CDNA2/CDNA3 & RDNA3/RDNA4 ISA Reference Manuals',
            'LLVM AMDGPU Backend',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'amd_gpu_arch_spec',
            description => 'Return AMD GPU hardware architecture specs for CDNA2 (gfx90a MI250X), CDNA3 (gfx942 MI300X), RDNA3 (gfx1100 RX 7900), and RDNA4 (gfx1200): wave64 vs wave32, CU/WGP geometry, 64 KiB 32-bank LDS, VGPR/SGPR/AGPR budgets, MFMA/WMMA shapes, and HBM3/GDDR6 bandwidth.',
            inputSchema => {
                type       => 'object',
                properties => {
                    arch => {
                        type        => 'string',
                        description => 'Target AMD GPU arch (gfx90a, gfx942, gfx1100, gfx1200, aliases like mi300x/cdna3/rdna3/rdna4, or "all").',
                    },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_arch_spec($args || {});
            },
        },
        {
            name        => 'amd_gpu_occupancy_calc',
            description => 'Calculate exact AMD GPU wave occupancy (waves/SIMD, theoretical occupancy %, limiting factor: VGPR/AGPR/SGPR/LDS/WORKGROUP) from VGPR, SGPR, AGPR, LDS bytes, and workgroup size across CDNA2/CDNA3/RDNA3/RDNA4.',
            inputSchema => {
                type       => 'object',
                properties => {
                    arch           => { type => 'string',  description => 'Target arch (gfx90a, gfx942, gfx1100, gfx1200). Default: gfx942.' },
                    vgprs          => { type => 'integer', description => 'VGPRs per thread (default: 64).' },
                    sgprs          => { type => 'integer', description => 'SGPRs per wave (default: 32).' },
                    agprs          => { type => 'integer', description => 'AGPRs per thread (CDNA2/CDNA3 Matrix Core accumulators, default: 0).' },
                    lds_bytes      => { type => 'integer', description => 'LDS bytes allocated per work-group (default: 0).' },
                    workgroup_size => { type => 'integer', description => 'Threads per work-group/block (integer or [x,y,z] array, default: 256).' },
                    wave_size      => { type => 'integer', description => 'Optional wave size (64 on CDNA; 32 or 64 on RDNA).' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_occupancy_calc($args || {});
            },
        },
        {
            name        => 'amd_gpu_hip_lookup',
            description => 'Look up HIP host/device APIs, CDNA MFMA / RDNA WMMA builtins, and AMDGPU ISA instructions (hipLaunchKernelGGL, __shfl_xor, __ballot, __launch_bounds__, __builtin_amdgcn_mfma_*, global_load_dwordx4, ds_read_b128, s_waitcnt).',
            inputSchema => {
                type       => 'object',
                properties => {
                    query    => { type => 'string', description => 'HIP API, builtin, or AMDGPU ISA instruction to search.' },
                    category => { type => 'string', description => 'Optional filter: hip_runtime, hip_device, mfma, wmma, isa, or all.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_hip_lookup($args || {});
            },
        },
        {
            name        => 'amd_gpu_kernel_audit',
            description => 'Audit HIP/ROCm kernels catching hardcoded warpSize==32 bugs on wave64 CDNA (0xffffffff ballot masks, & 31, >> 5, offset=16 reductions), LDS 32-bank conflicts, missing __launch_bounds__, VGPR spill risks, divergent __syncthreads(), plus live hipcc when installed.',
            inputSchema => {
                type       => 'object',
                properties => {
                    source       => { type => 'string',  description => 'HIP / ROCm kernel source code.' },
                    arch         => { type => 'string',  description => 'Target AMD GPU arch (default: gfx942).' },
                    run_compiler => { type => 'boolean', description => 'Invoke hipcc -fsyntax-only if installed (default: true).' },
                },
                required => ['source'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_kernel_audit($args || {});
            },
        },
    ];
}

sub _normalize_arch {
    my ($raw) = @_;
    return 'gfx942' unless defined $raw && length $raw;
    my $k = lc($raw);
    $k =~ s/[\s\-]+//g;
    $k =~ s/^amd_?//;
    return $ARCH_ALIASES{$k};
}

sub _parse_wg_size {
    my ($v, $default) = @_;
    return $default unless defined $v;
    if (ref($v) eq 'ARRAY') {
        my $prod = 1;
        for my $d (@$v) {
            my $n = int($d || 1);
            $n = 1 if $n < 1;
            $prod *= $n;
        }
        return $prod;
    }
    my $n = int($v || 0);
    return $n > 0 ? $n : $default;
}

sub _find_executable {
    my (@names) = @_;
    for my $name (@names) {
        if ($name =~ m{/}) {
            return $name if -x $name;
        }
        else {
            for my $dir (File::Spec->path) {
                my $p = File::Spec->catfile($dir, $name);
                return $p if -x $p && !-d $p;
            }
        }
    }
    return undef;
}

sub tool_arch_spec {
    my ($self, $args) = @_;
    my $raw = $args->{arch};
    if (!defined $raw || !length($raw) || lc($raw) eq 'all') {
        return {
            ok            => 1,
            architectures => [ map { $ARCH_SPECS{$_} } @ARCH_ORDER ],
            supported     => \@ARCH_ORDER,
        };
    }

    my $key = _normalize_arch($raw);
    if (!$key || !$ARCH_SPECS{$key}) {
        return {
            ok        => 0,
            error     => "Unknown AMD GPU architecture '$raw'. Supported: " . join(', ', @ARCH_ORDER),
            supported => \@ARCH_ORDER,
        };
    }
    return {
        ok   => 1,
        arch => $key,
        spec => $ARCH_SPECS{$key},
    };
}

sub tool_occupancy_calc {
    my ($self, $args) = @_;
    my $arch_key = _normalize_arch($args->{arch} // 'gfx942');
    if (!$arch_key || !$ARCH_SPECS{$arch_key}) {
        return {
            ok        => 0,
            error     => "Unknown AMD GPU architecture '" . ($args->{arch} // '') . "'",
            supported => \@ARCH_ORDER,
        };
    }
    my $spec = $ARCH_SPECS{$arch_key};

    my $vgprs     = int($args->{vgprs} // 64);
    my $sgprs     = int($args->{sgprs} // 32);
    my $agprs     = int($args->{agprs} // 0);
    my $lds_bytes = int($args->{lds_bytes} // 0);
    my $wg_size   = _parse_wg_size($args->{workgroup_size}, 256);
    my $wave_size = int($args->{wave_size} // $spec->{default_wave_size});

    $vgprs     = 1 if $vgprs < 1;
    $sgprs     = 1 if $sgprs < 1;
    $agprs     = 0 if $agprs < 0;
    $lds_bytes = 0 if $lds_bytes < 0;

    my (@warnings, @advice);

    my %ok_wave = map { $_ => 1 } @{ $spec->{supported_wave_sizes} };
    if (!$ok_wave{$wave_size}) {
        push @warnings, "Wave size $wave_size is unsupported on $arch_key ($spec->{family} uses wave$spec->{default_wave_size}); using $spec->{default_wave_size}.";
        $wave_size = $spec->{default_wave_size};
    }

    if ($wg_size > $spec->{max_workgroup_size}) {
        push @warnings, "Work-group size $wg_size exceeds $arch_key hardware maximum ($spec->{max_workgroup_size}).";
    }
    if ($wg_size % $wave_size != 0) {
        push @warnings, "Work-group size $wg_size is not a multiple of wave$wave_size (tail wavefront lanes wasted).";
        push @advice, "Set block size to a multiple of $wave_size (e.g. " . (ceil($wg_size / $wave_size) * $wave_size) . ").";
    }

    my $waves_per_wg      = ceil($wg_size / $wave_size);
    my $simds_per_cu      = $spec->{simds_per_cu};
    my $max_waves_simd    = $spec->{max_waves_per_simd};
    my $max_waves_cu      = $spec->{max_waves_per_cu};

    my ($vgpr_pool, $vgpr_gran, $vgpr_aligned, $total_vec_regs, $waves_by_vgpr_only, $waves_by_vec_regs, $waves_by_sgpr);
    my $reg_overflow = 0;

    if ($spec->{unified_vgpr_agpr_pool}) {
        # CDNA2 (gfx90a) & CDNA3 (gfx942): unified 512 arch VGPR+AGPR pool/SIMD, 8-reg allocation granularity
        $vgpr_pool = $spec->{vgpr_pool_per_simd};     # 512
        $vgpr_gran = $spec->{vgpr_alloc_granularity}; # 8
        my $agpr_off_gran = $spec->{agpr_offset_granularity} || 4;
        my $vgpr_for_accum = ($agprs > 0) ? (ceil($vgprs / $agpr_off_gran) * $agpr_off_gran) : $vgprs;

        $vgpr_aligned   = ceil($vgprs / $vgpr_gran) * $vgpr_gran;
        $total_vec_regs = ceil(($vgpr_for_accum + $agprs) / $vgpr_gran) * $vgpr_gran;

        if ($vgprs > $spec->{max_vgprs_per_thread} || $agprs > $spec->{max_agprs_per_thread} || $total_vec_regs > $vgpr_pool) {
            $reg_overflow = 1;
            push @warnings, "Register usage (VGPR=$vgprs, AGPR=$agprs, total aligned=$total_vec_regs) exceeds $arch_key hardware limits (max 256 VGPR, 256 AGPR, 512 unified/SIMD) -> scratch spill.";
        }

        $waves_by_vgpr_only = ($vgprs > $spec->{max_vgprs_per_thread}) ? 0 : int($vgpr_pool / $vgpr_aligned);
        $waves_by_vgpr_only = $max_waves_simd if $waves_by_vgpr_only > $max_waves_simd;

        $waves_by_vec_regs  = $reg_overflow ? 0 : int($vgpr_pool / $total_vec_regs);
        $waves_by_vec_regs  = $max_waves_simd if $waves_by_vec_regs > $max_waves_simd;

        my $sgpr_aligned = ceil($sgprs / $spec->{sgpr_alloc_granularity}) * $spec->{sgpr_alloc_granularity};
        if ($sgprs > $spec->{max_sgprs_per_wave}) {
            push @warnings, "SGPR count $sgprs exceeds max architectural SGPRs/wave ($spec->{max_sgprs_per_wave}).";
            $waves_by_sgpr = 0;
        }
        else {
            $waves_by_sgpr = int($spec->{sgpr_pool_per_simd} / $sgpr_aligned);
            $waves_by_sgpr = $max_waves_simd if $waves_by_sgpr > $max_waves_simd;
        }
    }
    else {
        # RDNA3 (gfx1100) & RDNA4 (gfx1200)
        if ($agprs > 0) {
            push @warnings, "$arch_key ($spec->{family}) has no separate AGPR file (WMMA uses VGPRs); ignoring agprs=$agprs.";
            $agprs = 0;
        }
        $vgpr_pool = ($wave_size == 64) ? $spec->{vgpr_pool_per_simd_w64} : $spec->{vgpr_pool_per_simd_w32};
        $vgpr_gran = ($wave_size == 64) ? $spec->{vgpr_alloc_granularity_w64} : $spec->{vgpr_alloc_granularity_w32};
        $vgpr_aligned   = ceil($vgprs / $vgpr_gran) * $vgpr_gran;
        $total_vec_regs = $vgpr_aligned;

        if ($vgprs > $spec->{max_vgprs_per_thread}) {
            $reg_overflow = 1;
            push @warnings, "VGPR count $vgprs exceeds max 256 VGPRs/thread on $arch_key -> scratch spill.";
        }
        $waves_by_vgpr_only = $reg_overflow ? 0 : int($vgpr_pool / $vgpr_aligned);
        $waves_by_vgpr_only = $max_waves_simd if $waves_by_vgpr_only > $max_waves_simd;
        $waves_by_vec_regs  = $waves_by_vgpr_only;

        if ($sgprs > $spec->{max_sgprs_per_wave}) {
            push @warnings, "SGPR count $sgprs exceeds max usable SGPRs/wave ($spec->{max_sgprs_per_wave}).";
            $waves_by_sgpr = 0;
        }
        else {
            $waves_by_sgpr = $max_waves_simd; # Dedicated per-wave SGPRs on RDNA3/4
        }
    }

    my $lds_gran    = $spec->{lds_alloc_granularity} || 512;
    my $lds_aligned = $lds_bytes > 0 ? (ceil($lds_bytes / $lds_gran) * $lds_gran) : 0;
    my $wgs_by_lds  = $spec->{max_wgs_per_cu};
    if ($lds_bytes > $spec->{lds_bytes_per_cu}) {
        $wgs_by_lds = 0;
        push @warnings, "LDS requirement ($lds_bytes B) exceeds $arch_key 64 KiB (65536 B) per-CU limit.";
    }
    elsif ($lds_aligned > 0) {
        $wgs_by_lds = int($spec->{lds_bytes_per_cu} / $lds_aligned);
    }

    my $reg_waves_per_simd = $waves_by_vec_regs < $waves_by_sgpr ? $waves_by_vec_regs : $waves_by_sgpr;
    my $reg_waves_per_cu   = $reg_waves_per_simd * $simds_per_cu;
    my $wgs_by_regs        = $waves_per_wg > 0 ? int($reg_waves_per_cu / $waves_per_wg) : 0;

    my $active_wgs_cu = $wgs_by_regs;
    $active_wgs_cu = $wgs_by_lds if $wgs_by_lds < $active_wgs_cu;
    $active_wgs_cu = $spec->{max_wgs_per_cu} if $spec->{max_wgs_per_cu} < $active_wgs_cu;
    $active_wgs_cu = 0 if $active_wgs_cu < 0;

    my $active_waves_cu   = $active_wgs_cu * $waves_per_wg;
    my $active_waves_simd = sprintf('%.2f', $active_waves_cu / $simds_per_cu) + 0;
    my $occ_pct           = sprintf('%.1f', 100.0 * $active_waves_cu / $max_waves_cu) + 0;

    # Determine primary limiting factor
    my $limiting = 'NONE';
    if ($lds_bytes > $spec->{lds_bytes_per_cu}) {
        $limiting = 'LDS';
    }
    elsif ($reg_overflow) {
        $limiting = ($agprs > 0 && $waves_by_vec_regs < $waves_by_vgpr_only) ? 'AGPR' : 'VGPR';
    }
    elsif ($active_waves_cu < $max_waves_cu) {
        my $lds_waves_cu = $wgs_by_lds * $waves_per_wg;
        my $wg_cap_waves = $spec->{max_wgs_per_cu} * $waves_per_wg;

        if ($lds_waves_cu <= $reg_waves_per_cu && $lds_waves_cu <= $wg_cap_waves && $wgs_by_lds < $wgs_by_regs) {
            $limiting = 'LDS';
        }
        elsif ($wg_cap_waves < $reg_waves_per_cu && $wg_cap_waves <= $lds_waves_cu) {
            $limiting = 'WORKGROUP';
        }
        elsif ($waves_by_sgpr < $waves_by_vec_regs) {
            $limiting = 'SGPR';
        }
        elsif ($waves_by_vec_regs < $max_waves_simd) {
            $limiting = ($agprs > 0 && $waves_by_vec_regs < $waves_by_vgpr_only) ? 'AGPR' : 'VGPR';
        }
        else {
            $limiting = 'WORKGROUP';
        }
    }

    # Actionable next-cliff tuning advice
    if ($limiting eq 'VGPR' || $limiting eq 'AGPR') {
        my $next_waves = $waves_by_vec_regs + 1;
        if ($next_waves <= $max_waves_simd && $next_waves > 0) {
            my $target_regs = int($vgpr_pool / $next_waves);
            $target_regs = int($target_regs / $vgpr_gran) * $vgpr_gran;
            push @advice, sprintf(
                '%s limits occupancy to %d waves/SIMD (%.1f%%). Reducing aligned %s from %d to <= %d unlocks %d waves/SIMD (%.1f%%).',
                $limiting, $waves_by_vec_regs, $occ_pct,
                ($spec->{unified_vgpr_agpr_pool} ? 'VGPR+AGPR' : 'VGPR'),
                $total_vec_regs, $target_regs, $next_waves,
                100.0 * $next_waves / $max_waves_simd
            );
        }
        push @advice, "Use __launch_bounds__($wg_size, " . ($active_wgs_cu > 0 ? $active_wgs_cu : 1) . ") so LLVM AMDGPU targets the exact register cliff cleanly.";
    }
    elsif ($limiting eq 'LDS') {
        my $next_wgs   = $wgs_by_lds + 1;
        my $target_lds = $next_wgs > 0 ? int($spec->{lds_bytes_per_cu} / $next_wgs) : $spec->{lds_bytes_per_cu};
        push @advice, sprintf(
            'LDS (%d B aligned / 65536 B) caps concurrency at %d workgroups/CU (%.1f%% occupancy). Shrinking LDS to <= %d B allows %d concurrent workgroups/CU.',
            $lds_aligned, $wgs_by_lds, $occ_pct, $target_lds, $next_wgs
        );
    }
    elsif ($limiting eq 'WORKGROUP') {
        push @advice, "Work-group size ($wg_size threads = $waves_per_wg waves/WG) under-fills CU wave slots ($active_waves_cu/$max_waves_cu); increase block size to " . ($wg_size * 2 <= $spec->{max_workgroup_size} ? $wg_size * 2 : 256) . " (a multiple of " . ($wave_size * $simds_per_cu) . ").";
    }
    elsif ($limiting eq 'SGPR') {
        push @advice, "SGPR usage ($sgprs) limits occupancy to $waves_by_sgpr waves/SIMD; keep SGPRs <= 96 on $arch_key for full 8 waves/SIMD.";
    }
    else {
        push @advice, "Achieves 100.0% theoretical wave occupancy ($active_waves_simd waves/SIMD, $active_waves_cu waves/CU) on $arch_key.";
    }

    return {
        ok                        => 1,
        arch                      => $arch_key,
        family                    => $spec->{family},
        arch_label                => $spec->{label},
        wave_size                 => $wave_size,
        workgroup_size            => $wg_size,
        waves_per_workgroup       => $waves_per_wg,
        vgprs_requested           => $vgprs,
        vgprs_aligned             => $vgpr_aligned,
        agprs_requested           => $agprs,
        total_vec_regs_aligned    => $total_vec_regs,
        vgpr_pool_per_simd        => $vgpr_pool,
        vgpr_alloc_granularity    => $vgpr_gran,
        sgprs_requested           => $sgprs,
        lds_bytes_requested       => $lds_bytes,
        lds_bytes_aligned         => $lds_aligned,
        lds_capacity_bytes        => $spec->{lds_bytes_per_cu},
        waves_per_simd_by_vgpr    => $waves_by_vgpr_only,
        waves_per_simd_by_vec     => $waves_by_vec_regs,
        waves_per_simd_by_sgpr    => $waves_by_sgpr,
        wgs_per_cu_by_regs        => $wgs_by_regs,
        wgs_per_cu_by_lds         => $wgs_by_lds,
        active_workgroups_per_cu  => $active_wgs_cu,
        active_waves_per_cu       => $active_waves_cu,
        max_waves_per_cu          => $max_waves_cu,
        waves_per_simd            => $active_waves_simd,
        max_waves_per_simd        => $max_waves_simd,
        theoretical_occupancy_pct => $occ_pct,
        limiting_factor           => $limiting,
        warnings                  => \@warnings,
        tuning_advice             => \@advice,
    };
}

sub tool_hip_lookup {
    my ($self, $args) = @_;
    my $q   = $args->{query} // '';
    my $cat = lc($args->{category} // 'all');
    $q =~ s/^\s+|\s+$//g;

    my @pool = sort keys %HIP_ISA_DB;
    if ($cat ne 'all' && length $cat) {
        @pool = grep { $HIP_ISA_DB{$_}{category} eq $cat } @pool;
    }

    if (!length $q) {
        return {
            ok       => 1,
            category => $cat,
            count    => scalar(@pool),
            entries  => [ map { $HIP_ISA_DB{$_} } @pool ],
        };
    }

    my $ql = lc($q);
    my (@exact, @prefix, @substr);
    for my $k (@pool) {
        my $e  = $HIP_ISA_DB{$k};
        my $kl = lc($k);
        if ($kl eq $ql || lc($e->{symbol}) eq $ql) {
            push @exact, $e;
        }
        elsif (index($kl, $ql) == 0) {
            push @prefix, $e;
        }
        elsif (index($kl, $ql) >= 0 || index(lc($e->{summary}), $ql) >= 0 || index(lc($e->{details}), $ql) >= 0) {
            push @substr, $e;
        }
    }

    my @matches = (@exact, @prefix, @substr);
    return {
        ok       => 1,
        query    => $q,
        category => $cat,
        count    => scalar(@matches),
        matches  => \@matches,
    };
}

sub _run_hipcc_check {
    my ($source, $arch_key) = @_;
    my $hipcc = _find_executable('hipcc', '/opt/rocm/bin/hipcc');
    return {
        tool      => 'hipcc',
        available => 0,
        note      => 'ROCm hipcc not found on PATH; returning static analysis only.',
    } unless $hipcc;

    my ($fh, $path) = File::Temp::tempfile('npl_hip_XXXXXX', SUFFIX => '.hip', UNLINK => 1);
    print {$fh} $source;
    close $fh;

    my @cmd = (
        $hipcc,
        '-fsyntax-only',
        "-offload-arch=$arch_key",
        '-x', 'hip',
        $path,
    );

    my ($wtr, $rdr, $err);
    $err = gensym;
    my $pid = eval { open3($wtr, $rdr, $err, @cmd) };
    if (!$pid) {
        return {
            tool      => 'hipcc',
            available => 1,
            executed  => 0,
            error     => "Failed to invoke hipcc: $@",
        };
    }
    close $wtr;
    my $stdout = do { local $/; <$rdr> } // '';
    my $stderr = do { local $/; <$err> } // '';
    close $rdr;
    close $err;
    waitpid($pid, 0);
    my $rc = $? >> 8;

    my @diags;
    for my $line (split /\r?\n/, "$stdout\n$stderr") {
        if ($line =~ /:(\d+):(\d+):\s*(error|warning|note):\s*(.+)$/i) {
            my $sev = lc($3);
            $sev = 'warn' if $sev eq 'warning';
            $sev = 'info' if $sev eq 'note';
            push @diags, {
                line     => ($1 > 0 ? $1 - 1 : 0),
                col      => ($2 > 0 ? $2 - 1 : 0),
                severity => $sev,
                code     => 'HIPCC',
                message  => $4,
            };
        }
    }

    return {
        tool        => 'hipcc',
        path        => $hipcc,
        available   => 1,
        executed    => 1,
        exit_code   => $rc,
        arch        => $arch_key,
        diagnostics => \@diags,
    };
}

sub tool_kernel_audit {
    my ($self, $args) = @_;
    my $src = $args->{source} // $args->{code};
    return { ok => 0, error => 'Missing required parameter: source' }
        unless defined $src && length $src;

    my $arch_key = _normalize_arch($args->{arch} // 'gfx942') || 'gfx942';
    my $spec     = $ARCH_SPECS{$arch_key};
    my $is_cdna  = ($spec->{default_wave_size} == 64) ? 1 : 0;
    my $run_comp = exists($args->{run_compiler}) ? ($args->{run_compiler} ? 1 : 0) : 1;

    my @lines = split /\r?\n/, $src, -1;
    my @findings;

    my $add_finding = sub {
        my (%f) = @_;
        push @findings, {
            line       => int($f{line} // 0),
            col        => int($f{col}  // 0),
            end_line   => int($f{end_line} // $f{line} // 0),
            end_col    => int($f{end_col}  // ($f{col} // 0) + 1),
            severity   => $f{severity} || 'warn',
            code       => $f{code}     || 'AMD_AUDIT',
            message    => $f{message}  || '',
            suggestion => $f{suggestion} // '',
        };
    };

    my $brace_depth    = 0;
    my @divergent_blks;
    my $pending_div_if = 0;

    for (my $i = 0; $i < @lines; $i++) {
        my $raw = $lines[$i];
        (my $code = $raw) =~ s{//.*$}{};
        next if $code =~ /^\s*$/;

        # 1. Hardcoded 32-bit ballot masks & CUDA-style *_sync masks on wave64 CDNA
        if ($code =~ /\b(0x[fF]{8}[uU]?|~0[uU]?)\b/) {
            my $tok = $1;
            if ($code =~ /\b(?:__ballot|__shfl|__any|__all|__syncwarp|mask|ballot|warp|lane|active)\b/i
                || ($i > 0 && $lines[$i - 1] =~ /\b(?:__ballot|__shfl|warp)\b/i))
            {
                my $c = index($raw, $tok);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($tok) : 1),
                    severity   => $is_cdna ? 'error' : 'warn',
                    code       => 'AMD_WARPSIZE_32_MASK_BUG',
                    message    => "Hardcoded 32-bit wavefront mask '$tok' truncates upper 32 lanes on $arch_key wave64 (warpSize == 64).",
                    suggestion => 'Use uint64_t / unsigned long long masks (~0ULL or (warpSize == 64 ? ~0ULL : 0xffffffffULL)) and unmasked HIP __ballot() / __shfl_xor().',
                );
            }
        }

        if ($code =~ /\b(?:unsigned\s+int|uint32_t|int)\s+\w+\s*=\s*__ballot\s*\(/) {
            my $c = index($raw, '__ballot');
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + 8 : 1),
                severity   => $is_cdna ? 'error' : 'warn',
                code       => 'AMD_BALLOT_32BIT_TRUNC',
                message    => '__ballot() return value truncated into 32-bit integer; on CDNA wave64 __ballot() returns a 64-bit mask.',
                suggestion => 'Store __ballot() in uint64_t (or unsigned long long) and count bits with __popcll().',
            );
        }

        # Hardcoded warpSize == 32 math: & 31, % 32, >> 5, / 32, or reduction starting at 16
        if ($code =~ /\b(?:threadIdx\.[xyz]|tid|lid)\s*(?:&\s*31|%\s*32|>>\s*5|\/\s*32)\b/
            || $code =~ /\bfor\s*\([^;]*=\s*16\s*;[^;]*>\s*0\s*;[^)]*(?:>>=\s*1|\/=\s*2)\)/)
        {
            $add_finding->(
                line       => $i,
                col        => 0,
                end_col    => length($raw),
                severity   => $is_cdna ? 'error' : 'warn',
                code       => 'AMD_WARPSIZE_32_ASSUMPTION',
                message    => "Hardcoded warpSize=32 arithmetic/reduction detected; fails on $arch_key wave64 (warpSize == 64).",
                suggestion => 'Parameterize with warpSize: lane = threadIdx.x & (warpSize - 1), warp_id = threadIdx.x / warpSize, and reduction offset = warpSize / 2.',
            );
        }

        # CUDA *_sync intrinsics ported verbatim
        if ($code =~ /\b(__shfl_(?:xor|down|up)_sync|__ballot_sync|__syncwarp)\s*\(/) {
            my $tok = $1;
            my $c   = index($raw, $tok);
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + length($tok) : 1),
                severity   => 'warn',
                code       => 'AMD_CUDA_SYNC_INTRINSIC',
                message    => "CUDA masked warp intrinsic '$tok' used; HIP wave64 uses unmasked __shfl_xor/__shfl_down/__ballot with 64-bit masks.",
                suggestion => 'Replace with HIP __shfl_xor(val, laneMask) / __ballot(pred) (or guard with #if defined(__HIP_PLATFORM_AMD__)).',
            );
        }

        # 2. Missing __launch_bounds__ on __global__ kernels
        if ($code =~ /\b__global__\b/ && $code !~ /\b__launch_bounds__\b/) {
            my $prev_has_lb = ($i > 0 && $lines[$i - 1] =~ /\b__launch_bounds__\b/) ? 1 : 0;
            my $next_has_lb = ($i + 1 < @lines && $lines[$i + 1] =~ /\b__launch_bounds__\b/) ? 1 : 0;
            if (!$prev_has_lb && !$next_has_lb) {
                my $c = index($raw, '__global__');
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + 10 : 1),
                    severity   => 'warn',
                    code       => 'AMD_MISSING_LAUNCH_BOUNDS',
                    message    => '__global__ kernel omits __launch_bounds__(maxThreadsPerBlock, minBlocksPerCU).',
                    suggestion => 'Add __launch_bounds__(256, 2) (tuned to your block size and target occupancy) so LLVM AMDGPU allocates VGPRs without unexpected spilling or conservative caps.',
                );
            }
        }

        # 3. LDS 32-bank stride conflicts
        if ($code =~ /\b__shared__\b.*\[\s*(?:32|64|128)\s*\]\s*\[\s*(32|64)\s*\]/) {
            my $dim = $1;
            $add_finding->(
                line       => $i,
                col        => 0,
                end_col    => length($raw),
                severity   => 'warn',
                code       => 'AMD_LDS_BANK_CONFLICT',
                message    => "__shared__ 2D LDS array inner stride $dim is a multiple of AMD's 32 LDS banks (4B stride), causing 32-way bank conflicts on column access.",
                suggestion => 'Pad inner dimension by +1 (e.g., [' . ($dim + 1) . ']) or XOR-swizzle bank indices (col ^ row).',
            );
        }
        elsif ($code =~ /\b(?:lds|sdata|smem|shared_\w+|tile)\s*\[\s*[^\]\n]*\*\s*(32|64)\b/) {
            my $stride = $1;
            $add_finding->(
                line       => $i,
                col        => 0,
                end_col    => length($raw),
                severity   => 'warn',
                code       => 'AMD_LDS_BANK_CONFLICT',
                message    => "LDS indexing with stride $stride hits identical LDS banks across lanes (32 banks x 4B).",
                suggestion => 'Add +1 dword padding or swizzle LDS addresses to distribute accesses across all 32 banks.',
            );
        }

        # 4. Divergent __syncthreads()
        if ($code =~ /\b(__syncthreads|__builtin_amdgcn_s_barrier)\s*\(/) {
            if (@divergent_blks || $pending_div_if) {
                my $tok = $1;
                my $c   = index($raw, $tok);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($tok) : 1),
                    severity   => 'error',
                    code       => 'AMD_SYNCTHREADS_DIVERGENT',
                    message    => "$tok() inside thread-divergent branch causes wave barrier deadlock on AMD GPU.",
                    suggestion => 'Ensure every thread in the work-group reaches __syncthreads() uniformly outside per-thread conditionals.',
                );
            }
        }

        # 5. Excessive private array -> VGPR scratch spill risk
        if ($code !~ /\b__shared__\b/
            && $code =~ /\b(float|double|int|uint32_t|int32_t|half)\s+([A-Za-z_]\w*)\s*\[\s*(\d+)\s*\]/)
        {
            my ($ty, $vname, $cnt) = ($1, $2, int($3));
            my $regs_est = ($ty eq 'double') ? ($cnt * 2) : ($ty eq 'half' ? ceil($cnt / 2) : $cnt);
            if ($regs_est >= 64) {
                my $c = index($raw, $vname);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($vname) : 1),
                    severity   => 'warn',
                    code       => 'AMD_VGPR_SPILL_RISK',
                    message    => "Large private thread array '$ty $vname\[$cnt\]' (~$regs_est VGPRs) risks VGPR spilling to scratch memory if dynamically indexed or exceeding register cliffs.",
                    suggestion => 'Use #pragma unroll for constant indexing, move shared tiles to __shared__ LDS, or pack into FP16/BF16 / MFMA AGPR accumulators.',
                );
            }
        }

        # 6. FP8 MFMA on CDNA2 (gfx90a) or RDNA3 (gfx1100)
        if (!$spec->{fp8_supported} && $code =~ /\b(__builtin_amdgcn_(?:mfma|wmma)_\w*fp8\w*|v_(?:mfma|wmma)_\w*fp8\w*)\b/) {
            my $tok = $1;
            my $c   = index($raw, $tok);
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + length($tok) : 1),
                severity   => 'error',
                code       => 'AMD_FP8_UNSUPPORTED_ARCH',
                message    => "FP8 matrix instruction '$tok' is not supported on $arch_key ($spec->{family}).",
                suggestion => 'Target gfx942 (CDNA3 MI300X) for FP8 MFMA or gfx1200 (RDNA4) for FP8 WMMA.',
            );
        }

        # Track thread-divergent if blocks
        my $is_div_cond = 0;
        if ($code =~ /\bif\s*\(([^)]+)\)/) {
            my $cond = $1;
            if ($cond =~ /\b(?:threadIdx|blockIdx|lane|tid|lid|gid|hipThreadIdx)\b/) {
                $is_div_cond = 1;
            }
        }
        my $opens  = () = $code =~ /\{/g;
        my $closes = () = $code =~ /\}/g;
        if ($is_div_cond) {
            if ($opens > 0) {
                push @divergent_blks, $brace_depth + 1;
                $pending_div_if = 0;
            }
            elsif ($code !~ /;/) {
                $pending_div_if = 1;
            }
        }
        elsif ($pending_div_if) {
            push @divergent_blks, $brace_depth + 1 if $opens > 0;
            $pending_div_if = 0;
        }
        $brace_depth += ($opens - $closes);
        $brace_depth = 0 if $brace_depth < 0;
        while (@divergent_blks && $brace_depth < $divergent_blks[-1]) {
            pop @divergent_blks;
        }
    }

    my $ext_compiler = {
        tool      => 'hipcc',
        available => 0,
        skipped   => 1,
    };
    if ($run_comp) {
        $ext_compiler = _run_hipcc_check($src, $arch_key);
        if ($ext_compiler->{diagnostics} && @{ $ext_compiler->{diagnostics} }) {
            for my $d (@{ $ext_compiler->{diagnostics} }) {
                $add_finding->(%$d);
            }
        }
    }

    my $errors = scalar grep { $_->{severity} eq 'error' } @findings;
    my $warns  = scalar grep { $_->{severity} eq 'warn' }  @findings;

    return {
        ok                => 1,
        arch              => $arch_key,
        family            => $spec->{family},
        wave_size         => $spec->{default_wave_size},
        finding_count     => scalar(@findings),
        error_count       => $errors,
        warning_count     => $warns,
        findings          => \@findings,
        external_compiler => $ext_compiler,
    };
}

# --- LSP Knowledge Hooks ---

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef unless defined $word && length $word;

    if (my $e = $HIP_ISA_DB{$word}) {
        my $md = "### `$e->{symbol}` (*AMD ROCm / " . uc($e->{category}) . "*)\n\n"
               . "```cpp\n$e->{signature}\n```\n\n"
               . "$e->{summary}\n\n"
               . "$e->{details}\n\n"
               . "**Example:**\n```cpp\n$e->{example}\n```";
        return { contents => $md, kind => 'markdown', title => $e->{symbol} };
    }

    my $wl = lc($word);
    for my $k (sort keys %HIP_ISA_DB) {
        if (lc($k) eq $wl) {
            my $e = $HIP_ISA_DB{$k};
            my $md = "### `$e->{symbol}` (*AMD ROCm / " . uc($e->{category}) . "*)\n\n"
                   . "```cpp\n$e->{signature}\n```\n\n$e->{summary}\n\n$e->{details}";
            return { contents => $md, kind => 'markdown', title => $e->{symbol} };
        }
    }

    if (my $ak = _normalize_arch($word)) {
        if (my $s = $ARCH_SPECS{$ak}) {
            my $md = "### $s->{label} (`$s->{arch}`)\n\n"
                   . "- **Wavefront:** wave$s->{default_wave_size} (" . join('/', @{ $s->{supported_wave_sizes} }) . ")\n"
                   . "- **Geometry:** $s->{simds_per_cu} SIMDs/CU, max $s->{max_waves_per_simd} waves/SIMD ($s->{max_waves_per_cu} waves/CU)\n"
                   . "- **LDS:** $s->{lds_kib_per_cu} KiB/CU ($s->{lds_banks} banks × $s->{lds_bank_stride_bytes}B)\n"
                   . "- **Matrix:** $s->{matrix_engine}\n"
                   . "- **Memory:** $s->{memory_bandwidth_note}\n";
            return { contents => $md, kind => 'markdown', title => $s->{label} };
        }
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $p = lc($prefix // '');
    my @items;
    for my $k (sort keys %HIP_ISA_DB) {
        my $e = $HIP_ISA_DB{$k};
        next if length($p) && index(lc($k), $p) < 0;
        my $kind_num = $NeoPerl::MCP::Pack::COMPLETION_KIND{ $e->{kind} // 'function' } || 3;
        push @items, {
            label         => $e->{symbol},
            kind          => $kind_num,
            detail        => uc($e->{category}) . ' — ' . $e->{signature},
            documentation => $e->{summary} . ' ' . $e->{details},
        };
    }
    return \@items;
}

sub lsp_diagnostics {
    my ($self, $text, $lang) = @_;
    return [] unless defined $text && length $text;
    my $res = $self->tool_kernel_audit({
        source       => $text,
        run_compiler => 0,
    });
    return [] unless $res && $res->{ok};
    return [
        map {
            $self->make_diagnostic(
                line     => $_->{line},
                col      => $_->{col},
                end_line => $_->{end_line},
                end_col  => $_->{end_col},
                severity => $_->{severity},
                code     => $_->{code},
                message  => $_->{message} . ($_->{suggestion} ? " Suggestion: $_->{suggestion}" : ''),
                source   => $self->name,
            )
        } @{ $res->{findings} || [] }
    ];
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    return [] unless defined $text && length $text;
    my @lines = split /\r?\n/, $text, -1;
    my @syms;
    for (my $i = 0; $i < @lines; $i++) {
        my $l = $lines[$i];
        if ($l =~ /\b__global__\b.*?\bvoid\s+([A-Za-z_]\w*)\s*\(/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'function',
                line   => $i,
                col    => index($l, $1),
                detail => 'HIP __global__ kernel',
            );
        }
        elsif ($l =~ /\b__device__\b.*?\b(?:void|float\d*|double\d*|int\d*|uint\d*|half\d*|bool|auto|T)\s+([A-Za-z_]\w*)\s*\(/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'function',
                line   => $i,
                col    => index($l, $1),
                detail => 'HIP __device__ function',
            );
        }
        elsif ($l =~ /\b__shared__\s+[A-Za-z_][\w:<>\s\*]*\b([A-Za-z_]\w*)\s*\[/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'variable',
                line   => $i,
                col    => index($l, $1),
                detail => 'LDS __shared__ array',
            );
        }
        elsif ($l =~ /\b(?:struct|class)\s+([A-Za-z_]\w*)/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'struct',
                line   => $i,
                col    => index($l, $1),
                detail => 'HIP/C++ struct',
            );
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::AMDGPU - AMD GPU compute MCP pack (ROCm / HIP / CDNA & RDNA)

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::AMDGPU;

    my $pack = NeoPerl::MCP::Pack::AMDGPU->new();
    my $spec = $pack->call_tool('amd_gpu_arch_spec', { arch => 'gfx942' });
    my $occ  = $pack->call_tool('amd_gpu_occupancy_calc', {
        arch           => 'gfx942',
        vgprs          => 64,
        agprs          => 64,
        sgprs          => 48,
        lds_bytes      => 32768,
        workgroup_size => 256,
    });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::AMDGPU> provides four MCP tools and matching LSP
knowledge hooks for AMD ROCm / HIP compute kernel engineering across CDNA2
(C<gfx90a> MI250X), CDNA3 (C<gfx942> MI300X), RDNA3 (C<gfx1100> RX 7900), and
RDNA4 (C<gfx1200>):

=over 4

=item * C<amd_gpu_arch_spec> - Architecture tables covering wave64 vs wave32, CU/WGP geometry, 64 KiB 32-bank LDS, VGPR/SGPR/AGPR register pools, MFMA/WMMA shapes, and HBM3/GDDR6 bandwidth.

=item * C<amd_gpu_occupancy_calc> - Exact wave occupancy calculator reporting waves/SIMD, theoretical occupancy percentage, and limiting factor (C<VGPR>, C<AGPR>, C<SGPR>, C<LDS>, or C<WORKGROUP>).

=item * C<amd_gpu_hip_lookup> - HIP runtime/device intrinsics, CDNA MFMA / RDNA WMMA builtins, and AMDGPU ISA reference.

=item * C<amd_gpu_kernel_audit> - Static kernel audit detecting hardcoded C<warpSize == 32> bugs on wave64 CDNA (C<0xffffffff> ballot masks, C<& 31>, C<<< >> 5 >>>), LDS 32-bank conflicts, missing C<__launch_bounds__>, VGPR spilling risks, divergent C<__syncthreads()>, plus optional live C<hipcc>.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
