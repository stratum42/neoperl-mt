package NeoPerl::MCP::Pack::IntelGPU;

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
    xe_lp         => 'xe_lp',
    xelp          => 'xe_lp',
    gen12         => 'xe_lp',
    tgl           => 'xe_lp',
    dg1           => 'xe_lp',
    adl           => 'xe_lp',
    tigerlake     => 'xe_lp',
    alderlake     => 'xe_lp',

    xe_hpg        => 'xe_hpg',
    xehpg         => 'xe_hpg',
    alchemist     => 'xe_hpg',
    arc           => 'xe_hpg',
    acm           => 'xe_hpg',
    dg2           => 'xe_hpg',
    mtl           => 'xe_hpg',
    meteorlake    => 'xe_hpg',

    xe_hpc        => 'xe_hpc',
    xehpc         => 'xe_hpc',
    pvc           => 'xe_hpc',
    ponte_vecchio => 'xe_hpc',
    pontevecchio  => 'xe_hpc',
    max1550       => 'xe_hpc',
    max1100       => 'xe_hpc',

    xe2_lpg       => 'xe2_lpg',
    xe2lpg        => 'xe2_lpg',
    lunar_lake    => 'xe2_lpg',
    lunarlake     => 'xe2_lpg',
    lnl           => 'xe2_lpg',
    arrow_lake    => 'xe2_lpg',
    arrowlake     => 'xe2_lpg',
    arl           => 'xe2_lpg',

    xe2_hpg       => 'xe2_hpg',
    xe2hpg        => 'xe2_hpg',
    xe2           => 'xe2_hpg',
    battlemage    => 'xe2_hpg',
    bmg           => 'xe2_hpg',
    bmg_g21       => 'xe2_hpg',
);

my @ARCH_ORDER = qw(xe_lp xe_hpg xe_hpc xe2_lpg xe2_hpg);

my %ARCH_SPECS = (
    xe_lp => {
        arch                      => 'xe_lp',
        label                     => 'Intel Xe-LP (Gen12: Tiger Lake / Alder Lake / DG1)',
        generation                => 'Gen12 / Xe1',
        ocloc_device              => 'tgllp',
        exec_unit_name            => 'EU',
        xves_per_core             => 16,
        core_name                 => 'Subslice (DSS)',
        simd_widths               => [ 8, 16, 32 ],
        native_simd_width         => 8,
        preferred_subgroup        => 16,
        grf_modes                 => [ 128 ],
        large_grf_supported       => 0,
        grf_size_bytes            => 32,
        threads_per_xve_std       => 7,
        threads_per_xve_large_grf => 0,
        reg_bytes_per_thread_std  => 4096,
        reg_bytes_per_thread_lgrf => 0,
        max_wgs_per_core          => 16,
        max_workgroup_size        => 512,
        slm_bytes                 => 65536,
        slm_kib                   => 64,
        slm_banks                 => 32,
        slm_bank_stride_bytes     => 4,
        slm_alloc_granularity     => 1024,
        l1_slm_pool_kib           => 128,
        l1_cache_line_bytes       => 64,
        l3_cache_line_bytes       => 64,
        fp64_support              => 'none_emulated',
        fp64_ratio                => '0 (emulated via software FP32)',
        xmx_supported             => 0,
        xmx_engines_per_core      => 0,
        xmx_shapes                => {
            note => 'No XMX systolic hardware on Xe-LP; use DP4A (INT8 dot product) instead.',
            dp4a => '4x INT8 accumulate into INT32 per lane',
        },
        notes => [
            '7 hardware threads per EU with fixed 128 GRFs (32B each = 4 KiB/thread); no Large-GRF 256 mode.',
            'No native IEEE 754 FP64 ALU; avoid double in kernels to prevent severe software emulation stalls.',
            'No XMX systolic arrays; use DP4A for INT8 inner products.',
        ],
    },
    xe_hpg => {
        arch                      => 'xe_hpg',
        label                     => 'Intel Xe-HPG (Arc Alchemist ACM-G10/G11/G12 / Meteor Lake)',
        generation                => 'Xe1 HPG',
        ocloc_device              => 'dg2',
        exec_unit_name            => 'XVE',
        xves_per_core             => 16,
        core_name                 => 'Xe-Core',
        simd_widths               => [ 8, 16, 32 ],
        native_simd_width         => 8,
        preferred_subgroup        => 16,
        grf_modes                 => [ 128, 256 ],
        large_grf_supported       => 1,
        grf_size_bytes            => 32,
        threads_per_xve_std       => 8,
        threads_per_xve_large_grf => 4,
        reg_bytes_per_thread_std  => 4096,
        reg_bytes_per_thread_lgrf => 8192,
        max_wgs_per_core          => 16,
        max_workgroup_size        => 1024,
        slm_bytes                 => 65536,
        slm_kib                   => 64,
        slm_max_configurable_kib  => 128,
        slm_banks                 => 32,
        slm_bank_stride_bytes     => 4,
        slm_alloc_granularity     => 4096,
        l1_slm_pool_kib           => 192,
        l1_cache_line_bytes       => 64,
        l3_cache_line_bytes       => 64,
        fp64_support              => 'none_emulated',
        fp64_ratio                => '0 (emulated on consumer Alchemist)',
        xmx_supported             => 1,
        xmx_engines_per_core      => 16,
        xmx_shapes                => {
            exec_size => 8,
            dpas_bf16 => '8x16x16 (M=8, N=8 per XMX exec8, K=16 BF16 -> FP32; tile 8x16 with joint_matrix)',
            dpas_fp16 => '8x16x16 (M=8, N=8 per XMX exec8, K=16 FP16 -> FP32/FP16)',
            dpas_int8 => '8x16x32 (M=8, N=8 per XMX exec8, K=32 INT8 -> INT32)',
            dpas_tf32 => '8x16x8 (M=8, N=8 per XMX exec8, K=8 TF32 -> FP32)',
        },
        notes => [
            '16 XVEs + 16 XMX engines per Xe-Core; 192 KiB unified L1/SLM pool (64 KiB default SLM, up to 128 KiB).',
            'Supports 128-GRF (8 threads/XVE, 4 KiB/thread) and 256-GRF Large-GRF (4 threads/XVE, 8 KiB/thread) via -ze-opt-large-register-file.',
            'Consumer Xe-HPG lacks native FP64 hardware; double triggers slow software emulation.',
        ],
    },
    xe_hpc => {
        arch                      => 'xe_hpc',
        label                     => 'Intel Xe-HPC (Ponte Vecchio / Data Center GPU Max 1100/1550)',
        generation                => 'Xe-HPC',
        ocloc_device              => 'pvc',
        exec_unit_name            => 'XVE (512-bit)',
        xves_per_core             => 8,
        core_name                 => 'Xe-Core',
        simd_widths               => [ 16, 32 ],
        native_simd_width         => 16,
        preferred_subgroup        => 16,
        grf_modes                 => [ 128, 256 ],
        large_grf_supported       => 1,
        grf_size_bytes            => 64,
        threads_per_xve_std       => 8,
        threads_per_xve_large_grf => 4,
        reg_bytes_per_thread_std  => 8192,
        reg_bytes_per_thread_lgrf => 16384,
        max_wgs_per_core          => 16,
        max_workgroup_size        => 1024,
        slm_bytes                 => 131072,
        slm_kib                   => 128,
        slm_banks                 => 32,
        slm_bank_stride_bytes     => 4,
        slm_alloc_granularity     => 4096,
        l1_slm_pool_kib           => 512,
        l1_cache_line_bytes       => 64,
        l3_cache_line_bytes       => 64,
        fp64_support              => 'native_full_rate',
        fp64_ratio                => '1:1 full-rate 512-bit SIMD16 IEEE 754 FP64',
        xmx_supported             => 1,
        xmx_engines_per_core      => 8,
        xmx_shapes                => {
            exec_size => 16,
            dpas_bf16 => '8x16x16 (M=8, N=16, K=16 BF16 -> FP32)',
            dpas_fp16 => '8x16x16 (M=8, N=16, K=16 FP16 -> FP32/FP16)',
            dpas_int8 => '8x16x32 (M=8, N=16, K=32 INT8 -> INT32)',
            dpas_tf32 => '8x16x8 (M=8, N=16, K=8 TF32 -> FP32)',
        },
        notes => [
            'Native 512-bit SIMD16 XVE (SIMD8 not supported); 64 bytes per GRF (64 KiB register file per XVE).',
            '128-GRF gives 8 KiB/thread (8 threads/XVE); 256-GRF gives 16 KiB/thread (4 threads/XVE).',
            '512 KiB unified L1/SLM per Xe-Core (up to 128 KiB SLM); native 1:1 full-rate FP64 + 4096-bit XMX.',
        ],
    },
    xe2_lpg => {
        arch                      => 'xe2_lpg',
        label                     => 'Intel Xe2-LPG (Lunar Lake / Arrow Lake Integrated)',
        generation                => 'Xe2',
        ocloc_device              => 'lnl',
        exec_unit_name            => 'XVE (Native SIMD16)',
        xves_per_core             => 8,
        core_name                 => 'Xe2-Core',
        simd_widths               => [ 16, 32 ],
        native_simd_width         => 16,
        preferred_subgroup        => 16,
        grf_modes                 => [ 128, 256 ],
        large_grf_supported       => 1,
        grf_size_bytes            => 64,
        threads_per_xve_std       => 8,
        threads_per_xve_large_grf => 4,
        reg_bytes_per_thread_std  => 8192,
        reg_bytes_per_thread_lgrf => 16384,
        max_wgs_per_core          => 16,
        max_workgroup_size        => 1024,
        slm_bytes                 => 131072,
        slm_kib                   => 128,
        slm_banks                 => 32,
        slm_bank_stride_bytes     => 4,
        slm_alloc_granularity     => 4096,
        l1_slm_pool_kib           => 256,
        l1_cache_line_bytes       => 64,
        l3_cache_line_bytes       => 64,
        fp64_support              => 'reduced_rate',
        fp64_ratio                => 'Reduced-rate consumer FP64 (prefer FP32/FP16/BF16)',
        xmx_supported             => 1,
        xmx_engines_per_core      => 8,
        xmx_shapes                => {
            exec_size => 16,
            dpas_bf16 => '8x16x16 (M=8, N=16, K=16 BF16 -> FP32)',
            dpas_fp16 => '8x16x16 (M=8, N=16, K=16 FP16 -> FP32/FP16)',
            dpas_int8 => '8x16x32 (M=8, N=16, K=32 INT8 -> INT32)',
            dpas_tf32 => '8x16x8 (M=8, N=16, K=8 TF32 -> FP32)',
        },
        notes => [
            'Xe2 unifies on native SIMD16 XVEs (SIMD8 retired); pin [[intel::reqd_sub_group_size(16)]].',
            '256 KiB unified L1/SLM per Xe2-Core (up to 128 KiB SLM); 8 XMX engines per Xe2-Core.',
            '64B GRFs provide 8 KiB/thread in 128-GRF mode and 16 KiB/thread in 256-GRF Large-GRF mode.',
        ],
    },
    xe2_hpg => {
        arch                      => 'xe2_hpg',
        label                     => 'Intel Xe2-HPG (Arc Battlemage BMG-G21)',
        generation                => 'Xe2',
        ocloc_device              => 'bmg',
        exec_unit_name            => 'XVE (Native SIMD16)',
        xves_per_core             => 8,
        core_name                 => 'Xe2-Core',
        simd_widths               => [ 16, 32 ],
        native_simd_width         => 16,
        preferred_subgroup        => 16,
        grf_modes                 => [ 128, 256 ],
        large_grf_supported       => 1,
        grf_size_bytes            => 64,
        threads_per_xve_std       => 8,
        threads_per_xve_large_grf => 4,
        reg_bytes_per_thread_std  => 8192,
        reg_bytes_per_thread_lgrf => 16384,
        max_wgs_per_core          => 16,
        max_workgroup_size        => 1024,
        slm_bytes                 => 131072,
        slm_kib                   => 128,
        slm_banks                 => 32,
        slm_bank_stride_bytes     => 4,
        slm_alloc_granularity     => 4096,
        l1_slm_pool_kib           => 256,
        l1_cache_line_bytes       => 64,
        l3_cache_line_bytes       => 64,
        fp64_support              => 'reduced_rate',
        fp64_ratio                => 'Reduced-rate consumer FP64 (~1:16; avoid in hot loops)',
        xmx_supported             => 1,
        xmx_engines_per_core      => 8,
        xmx_shapes                => {
            exec_size => 16,
            dpas_bf16 => '8x16x16 (M=8, N=16, K=16 BF16 -> FP32)',
            dpas_fp16 => '8x16x16 (M=8, N=16, K=16 FP16 -> FP32/FP16)',
            dpas_int8 => '8x16x32 (M=8, N=16, K=32 INT8 -> INT32)',
            dpas_tf32 => '8x16x8 (M=8, N=16, K=8 TF32 -> FP32)',
        },
        notes => [
            'Discrete Battlemage Xe2-HPG: native SIMD16 XVEs (SIMD8 retired), 2048-bit XMX systolic engines per Xe2-Core.',
            '256 KiB L1/SLM pool per Xe2-Core (up to 128 KiB SLM); 64B L1/L3 cache lines; GDDR6 memory.',
            'Large-GRF 256 mode doubles per-thread register file to 16 KiB at 4 threads/XVE to eliminate GEMM/attention spilling.',
        ],
    },
);

my %API_DB = (
    'sycl::nd_item' => {
        symbol    => 'sycl::nd_item',
        api       => 'sycl',
        kind      => 'class',
        signature => 'template <int Dimensions = 1> class sycl::nd_item',
        summary   => 'Identifies a work-item within an ND-range kernel, exposing global/local/group indices, sub-group handle, and work-group barriers.',
        details   => 'Key methods: get_global_id(dim), get_local_id(dim), get_group(dim), get_local_linear_id(), get_sub_group(). Pass to sycl::group_barrier(item.get_group()) for work-group sync.',
        example   => 'h.parallel_for(sycl::nd_range<1>{N, 256}, [=](sycl::nd_item<1> it) [[sycl::reqd_sub_group_size(16)]] { auto sg = it.get_sub_group(); });',
    },
    'sycl::sub_group' => {
        symbol    => 'sycl::sub_group',
        api       => 'sycl',
        kind      => 'class',
        signature => 'class sycl::sub_group',
        summary   => 'Represents a hardware SIMD thread (8, 16, or 32 work-items executing in lockstep on an Intel EU/XVE).',
        details   => 'Methods: get_local_linear_id(), get_local_linear_range(), get_group_linear_id(), load/store (coalesced block ops), shuffle/permute/reduce collectives. Always pin width with [[sycl::reqd_sub_group_size(16)]] on Xe-HPC/Xe2.',
        example   => 'auto sg = it.get_sub_group(); float sum = sycl::reduce_over_group(sg, val, sycl::plus<float>{});',
    },
    'sycl::local_accessor' => {
        symbol    => 'sycl::local_accessor',
        api       => 'sycl',
        kind      => 'class',
        signature => 'template <typename DataT, int Dimensions = 1> class sycl::local_accessor',
        summary   => 'Allocates work-group Shared Local Memory (SLM: 64 KiB on Xe-LP/HPG, up to 128 KiB on Xe-HPC/Xe2).',
        details   => 'SLM is 32-bank x 4-byte interleaved. Pad 2D tiles by +1 column (e.g. [32][33]) to avoid 32-way bank conflicts during transposes. Always pair writes and cross-item reads with sycl::group_barrier(it.get_group()).',
        example   => 'sycl::local_accessor<float, 2> tile({32, 33}, h);',
    },
    'sycl::ext::oneapi::experimental::matrix::joint_matrix' => {
        symbol    => 'sycl::ext::oneapi::experimental::matrix::joint_matrix',
        api       => 'sycl',
        kind      => 'class',
        signature => 'joint_matrix<Group, T, Use, Rows, Cols, Layout>',
        summary   => 'Portable SYCL subgroup-cooperative matrix type lowered directly to Intel XMX DPAS instructions on Xe-HPG/Xe-HPC/Xe2.',
        details   => 'Use enum: use::a, use::b, use::accumulator. Native Xe-HPC/Xe2 BF16/FP16 tile: M=8, N=16, K=16 (INT8 K=32, TF32 K=8). Combine with joint_matrix_load, joint_matrix_mad, and joint_matrix_store.',
        example   => 'joint_matrix<sub_group, bfloat16, use::a, 8, 16, layout::row_major> tA; joint_matrix_mad(sg, tC, tA, tB, tC);',
    },
    'joint_matrix_mad' => {
        symbol    => 'joint_matrix_mad',
        api       => 'sycl',
        kind      => 'function',
        signature => 'joint_matrix_mad(sub_group sg, joint_matrix<..., accumulator>& D, const A&, const B&, const C&)',
        summary   => 'Executes hardware systolic multiply-accumulate D = A * B + C on Intel XMX DPAS units.',
        details   => 'All lanes in the sub-group must execute joint_matrix_mad uniformly (never inside a lane-divergent branch). Pair with [[sycl::reqd_sub_group_size(16)]] on Xe-HPC/Xe2 (or 8 on Xe-HPG).',
        example   => 'joint_matrix_mad(sg, sub_c, sub_a, sub_b, sub_c);',
    },
    'sycl::group_barrier' => {
        symbol    => 'sycl::group_barrier',
        api       => 'sycl',
        kind      => 'function',
        signature => 'void sycl::group_barrier(Group g, memory_scope fence_scope = Group::fence_scope)',
        summary   => 'Work-group or sub-group execution and memory barrier.',
        details   => 'Must be reached uniformly by EVERY work-item in the group; placing group_barrier inside thread-divergent control flow causes a GPU hang.',
        example   => 'sycl::group_barrier(it.get_group());',
    },
    'sycl::reduce_over_group' => {
        symbol    => 'sycl::reduce_over_group',
        api       => 'sycl',
        kind      => 'function',
        signature => 'T sycl::reduce_over_group(Group g, T x, BinaryOperation binary_op)',
        summary   => 'Collective reduction across a sub-group (via fast register shuffles) or work-group (via SLM).',
        details   => 'Must be executed in converged control flow by all work-items of group g.',
        example   => 'float total = sycl::reduce_over_group(it.get_sub_group(), partial, sycl::plus<>());',
    },
    'sycl::permute_group_by_xor' => {
        symbol    => 'sycl::permute_group_by_xor',
        api       => 'sycl',
        kind      => 'function',
        signature => 'T sycl::permute_group_by_xor(sub_group sg, T x, id<1> mask)',
        summary   => 'Butterfly XOR shuffle across Intel sub-group lanes directly in GRF registers without touching SLM.',
        details   => 'Ideal for warp/sub-group tree reductions and FFT butterflies. Requires converged subgroup execution.',
        example   => 'for (int m = sg.get_local_linear_range() / 2; m > 0; m >>= 1) v += sycl::permute_group_by_xor(sg, v, m);',
    },
    'sycl::shift_group_left' => {
        symbol    => 'sycl::shift_group_left',
        api       => 'sycl',
        kind      => 'function',
        signature => 'T sycl::shift_group_left(sub_group sg, T x, size_t delta = 1)',
        summary   => 'Shifts values across sub-group lanes downward in lane index inside GRF registers.',
        details   => 'Used for sliding stencils and reductions; upper delta lanes receive unspecified values.',
        example   => 'float next = sycl::shift_group_left(sg, cur, 1);',
    },
    'sycl::select_from_group' => {
        symbol    => 'sycl::select_from_group',
        api       => 'sycl',
        kind      => 'function',
        signature => 'T sycl::select_from_group(sub_group sg, T x, id<1> remote_local_id)',
        summary   => 'Arbitrary lane-to-lane sub-group shuffle in GRF registers.',
        details   => 'Maps to Intel sub-group shuffle instructions; faster than SLM round-trips for cross-lane exchanges.',
        example   => 'float pivot = sycl::select_from_group(sg, val, 0);',
    },
    'sycl::reqd_sub_group_size' => {
        symbol    => '[[sycl::reqd_sub_group_size(N)]]',
        api       => 'sycl',
        kind      => 'keyword',
        signature => '[[sycl::reqd_sub_group_size(16)]] / [[intel::reqd_sub_group_size(16)]]',
        summary   => 'Pins the compiled SIMD width of a SYCL kernel to N (16 or 32 on Xe-HPC/Xe2; 8/16/32 on Xe-LP/HPG).',
        details   => 'Prevents IGC multi-SIMD compilation overhead and guarantees exact subgroup lane counts for shuffles and XMX joint_matrix.',
        example   => '[=](sycl::nd_item<1> it) [[intel::reqd_sub_group_size(16)]] { ... }',
    },
    'sycl::ext::intel::experimental::grf_size' => {
        symbol    => 'sycl::ext::intel::experimental::grf_size',
        api       => 'sycl',
        kind      => 'property',
        signature => 'sycl::ext::oneapi::experimental::properties{sycl::ext::intel::experimental::grf_size<256>}',
        summary   => 'Kernel compile-time property selecting 128-GRF (8 threads/XVE) or 256-GRF Large-GRF (4 threads/XVE) mode.',
        details   => 'Use grf_size<256> (or -ze-opt-large-register-file) for register-heavy GEMM/XMX/attention kernels to prevent catastrophic scratch spilling.',
        example   => 'sycl::ext::oneapi::experimental::properties props{sycl::ext::intel::experimental::grf_size<256>};',
    },
    'sycl::malloc_device' => {
        symbol    => 'sycl::malloc_device',
        api       => 'sycl',
        kind      => 'function',
        signature => 'T* sycl::malloc_device<T>(size_t count, const sycl::queue& q)',
        summary   => 'Allocates Unified Shared Memory (USM) device-only memory for maximum HBM/GDDR6 bandwidth.',
        details   => 'Not directly host-accessible; transfer via q.memcpy(). Prefer over malloc_shared in hot GPU loops to avoid page migration faults.',
        example   => 'float* d_buf = sycl::malloc_device<float>(N, q);',
    },
    'sycl::malloc_shared' => {
        symbol    => 'sycl::malloc_shared',
        api       => 'sycl',
        kind      => 'function',
        signature => 'T* sycl::malloc_shared<T>(size_t count, const sycl::queue& q)',
        summary   => 'Allocates USM shared memory accessible from both host CPU and Intel GPU with automatic page migration.',
        details   => 'Great on integrated Xe-LP/Xe2-LPG UMA; on discrete Arc/PVC, use q.prefetch() before kernel launch to avoid PCIe page-fault stalls.',
        example   => 'float* s_buf = sycl::malloc_shared<float>(N, q); q.prefetch(s_buf, N * sizeof(float));',
    },
    'intel_sub_group_shuffle' => {
        symbol    => 'intel_sub_group_shuffle',
        api       => 'opencl',
        kind      => 'function',
        signature => 'gentype intel_sub_group_shuffle(gentype data, uint c)',
        summary   => 'OpenCL C cl_intel_subgroups arbitrary lane shuffle returning lane c\'s value directly via GRF.',
        details   => 'Zero SLM usage; also available as intel_sub_group_shuffle_xor, intel_sub_group_shuffle_down, and intel_sub_group_shuffle_up. Requires uniform subgroup execution.',
        example   => 'float b = intel_sub_group_shuffle(a, 0);',
    },
    'intel_sub_group_shuffle_xor' => {
        symbol    => 'intel_sub_group_shuffle_xor',
        api       => 'opencl',
        kind      => 'function',
        signature => 'gentype intel_sub_group_shuffle_xor(gentype data, uint value)',
        summary   => 'OpenCL C subgroup butterfly XOR exchange between lane id and lane (id ^ value).',
        details   => 'Use for register-only subgroup reductions across SIMD16/32 without SLM barriers.',
        example   => 'val += intel_sub_group_shuffle_xor(val, 8);',
    },
    'intel_sub_group_block_read4' => {
        symbol    => 'intel_sub_group_block_read4',
        api       => 'opencl',
        kind      => 'function',
        signature => 'uint4 intel_sub_group_block_read4(const __global uint* p)',
        summary   => 'Coalesced 2D/1D subgroup block load reading 4 contiguous uints per lane in a single cache-line-aligned SEND message.',
        details   => 'All lanes pass the same base pointer p (4-byte aligned, best at 16B/64B). Dramatically cuts L1/L3 load instructions compared to scattered per-lane reads. Variants: block_read, block_read2, block_read4, block_read8, block_write4.',
        example   => 'uint4 v = intel_sub_group_block_read4((const __global uint*)(src + row_off));',
    },
    'intel_sub_group_block_write4' => {
        symbol    => 'intel_sub_group_block_write4',
        api       => 'opencl',
        kind      => 'function',
        signature => 'void intel_sub_group_block_write4(__global uint* p, uint4 data)',
        summary   => 'Coalesced subgroup block store writing 4 uints per lane in one hardware SEND message.',
        details   => 'Base pointer p must be uniform across all lanes in the subgroup and 16-byte aligned for peak write combining.',
        example   => 'intel_sub_group_block_write4((__global uint*)(dst + row_off), out4);',
    },
    'intel_sub_group_bf16_bf16_matrix_mad_k16' => {
        symbol    => 'intel_sub_group_bf16_bf16_matrix_mad_k16',
        api       => 'opencl',
        kind      => 'function',
        signature => 'float8 intel_sub_group_bf16_bf16_matrix_mad_k16(short8 a, int8 b, float8 acc)',
        summary   => 'OpenCL C cl_intel_subgroup_matrix_multiply_accumulate intrinsic lowering directly to Intel XMX DPAS BF16 (8x16x16).',
        details   => 'Requires __attribute__((intel_reqd_sub_group_size(16))) on Xe-HPC/Xe2 (or 8 on Xe-HPG). Companion variants exist for f16_f16_matrix_mad_k16, i8_i8_matrix_mad_k32, and tf32_tf32_matrix_mad_k8.',
        example   => 'acc = intel_sub_group_bf16_bf16_matrix_mad_k16(tileA, tileB, acc);',
    },
    'intel_sub_group_f16_f16_matrix_mad_k16' => {
        symbol    => 'intel_sub_group_f16_f16_matrix_mad_k16',
        api       => 'opencl',
        kind      => 'function',
        signature => 'float8 intel_sub_group_f16_f16_matrix_mad_k16(short8 a, int8 b, float8 acc)',
        summary   => 'OpenCL C XMX DPAS FP16 systolic matrix multiply-accumulate (K=16, FP32 accumulation).',
        details   => 'Executes on Intel XMX engines in Xe-HPG, Xe-HPC, and Xe2.',
        example   => 'acc = intel_sub_group_f16_f16_matrix_mad_k16(tileA, tileB, acc);',
    },
    'intel_reqd_sub_group_size' => {
        symbol    => '__attribute__((intel_reqd_sub_group_size(N)))',
        api       => 'opencl',
        kind      => 'keyword',
        signature => '__kernel __attribute__((intel_reqd_sub_group_size(16))) void k(...)',
        summary   => 'OpenCL C attribute pinning Intel GPU hardware SIMD subgroup width to N.',
        details   => 'Use 16 on Xe-HPC and Xe2 (SIMD8 is retired on Xe-HPC/Xe2). Required for deterministic block reads, shuffles, and DPAS.',
        example   => '__kernel __attribute__((intel_reqd_sub_group_size(16))) void gemm(...) {}',
    },
    'work_group_barrier' => {
        symbol    => 'work_group_barrier',
        api       => 'opencl',
        kind      => 'function',
        signature => 'void work_group_barrier(cl_mem_fence_flags flags, memory_scope scope)',
        summary   => 'OpenCL 2.0+/3.0 work-group barrier synchronizing SLM (CLK_LOCAL_MEM_FENCE) and/or global memory.',
        details   => 'Must be called in uniform control flow by every work-item in the work-group.',
        example   => 'work_group_barrier(CLK_LOCAL_MEM_FENCE);',
    },
    'zeCommandListAppendLaunchKernel' => {
        symbol    => 'zeCommandListAppendLaunchKernel',
        api       => 'level_zero',
        kind      => 'function',
        signature => 'ze_result_t zeCommandListAppendLaunchKernel(ze_command_list_handle_t hCommandList, ze_kernel_handle_t hKernel, const ze_group_count_t* pLaunchFuncArgs, ze_event_handle_t hSignalEvent, uint32_t numWaitEvents, ze_event_handle_t* phWaitEvents)',
        summary   => 'Enqueues a compute kernel dispatch into a Level Zero regular or immediate command list.',
        details   => 'Set group size first via zeKernelSetGroupSize(). Prefer immediate command lists (zeCommandListCreateImmediate) for lowest submission latency.',
        example   => 'ze_group_count_t g = { gridX, 1, 1 }; zeCommandListAppendLaunchKernel(cmdList, kernel, &g, ev, 0, nullptr);',
    },
    'zeMemAllocDevice' => {
        symbol    => 'zeMemAllocDevice',
        api       => 'level_zero',
        kind      => 'function',
        signature => 'ze_result_t zeMemAllocDevice(ze_context_handle_t hContext, const ze_device_mem_alloc_desc_t* device_desc, size_t size, size_t alignment, ze_device_handle_t hDevice, void** pptr)',
        summary   => 'Allocates Level Zero device-resident USM memory directly in GPU VRAM/HBM.',
        details   => 'Pass alignment=64 (cache line) or 256 for optimal coalesced block transfers. Free with zeMemFree().',
        example   => 'zeMemAllocDevice(ctx, &devDesc, bytes, 64, dev, &dPtr);',
    },
    'zeMemAllocShared' => {
        symbol    => 'zeMemAllocShared',
        api       => 'level_zero',
        kind      => 'function',
        signature => 'ze_result_t zeMemAllocShared(ze_context_handle_t hContext, const ze_device_mem_alloc_desc_t* device_desc, const ze_host_mem_alloc_desc_t* host_desc, size_t size, size_t alignment, ze_device_handle_t hDevice, void** pptr)',
        summary   => 'Allocates Level Zero shared USM memory accessible by both host CPU and GPU.',
        details   => 'Use zeCommandListAppendMemoryPrefetch() on discrete GPUs before launch to avoid demand-paging overhead.',
        example   => 'zeMemAllocShared(ctx, &devDesc, &hostDesc, bytes, 64, dev, &sPtr);',
    },
    'zeCommandQueueSynchronize' => {
        symbol    => 'zeCommandQueueSynchronize',
        api       => 'level_zero',
        kind      => 'function',
        signature => 'ze_result_t zeCommandQueueSynchronize(ze_command_queue_handle_t hCommandQueue, uint64_t timeout)',
        summary   => 'Blocks host thread until all command lists submitted to the Level Zero command queue complete.',
        details   => 'Pass UINT64_MAX for blocking wait. For fine-grained overlap, prefer zeEventHostSynchronize() on individual kernel events.',
        example   => 'zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);',
    },
    'zeModuleCreate' => {
        symbol    => 'zeModuleCreate',
        api       => 'level_zero',
        kind      => 'function',
        signature => 'ze_result_t zeModuleCreate(ze_context_handle_t hContext, ze_device_handle_t hDevice, const ze_module_desc_t* desc, ze_module_handle_t* phModule, ze_module_build_log_handle_t* phBuildLog)',
        summary   => 'JIT-compiles SPIR-V (ZE_MODULE_FORMAT_IL_SPIRV) or loads AOT binary (ZE_MODULE_FORMAT_NATIVE) via IGC.',
        details   => 'Pass pBuildFlags = "-ze-opt-large-register-file" to enable 256-GRF mode, or "-ze-opt-greater-than-4GB-buffer-required" for >4 GiB single allocations.',
        example   => 'desc.format = ZE_MODULE_FORMAT_IL_SPIRV; desc.pBuildFlags = "-ze-opt-large-register-file"; zeModuleCreate(ctx, dev, &desc, &mod, &log);',
    },
    'zeCommandListAppendBarrier' => {
        symbol    => 'zeCommandListAppendBarrier',
        api       => 'level_zero',
        kind      => 'function',
        signature => 'ze_result_t zeCommandListAppendBarrier(ze_command_list_handle_t hCommandList, ze_event_handle_t hSignalEvent, uint32_t numWaitEvents, ze_event_handle_t* phWaitEvents)',
        summary   => 'Inserts an execution + global memory barrier between commands in a Level Zero command list.',
        details   => 'Ensures prior kernel global writes are flushed and visible to subsequent dispatches or copies.',
        example   => 'zeCommandListAppendBarrier(cmdList, nullptr, 0, nullptr);',
    },
);

sub meta {
    return {
        name             => 'intel_gpu',
        label            => 'Intel GPU Compute (oneAPI / SYCL / OpenCL / Level Zero)',
        category         => 'gpu',
        version          => $VERSION,
        description      => 'Intel GPU architecture database (Xe-LP, Xe-HPG, Xe-HPC PVC, Xe2 Lunar/Arrow Lake & Battlemage), GRF/SLM occupancy calculator, SYCL/OpenCL/Level Zero API reference, and kernel auditor.',
        filetypes        => [qw(sycl opencl cl)],
        upstream_credits => [
            'Intel oneAPI DPC++ / SYCL 2020 Specification',
            'Khronos OpenCL & cl_intel_subgroups Extensions',
            'oneAPI Level Zero Specification',
            'Intel Graphics Compiler (IGC / ocloc)',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'intel_gpu_arch_spec',
            description => 'Return hardware architecture specs for Intel GPUs (xe_lp Gen12, xe_hpg Alchemist, xe_hpc Ponte Vecchio, xe2_lpg Arrow/Lunar Lake, xe2_hpg Battlemage): SIMD/subgroup widths, EU/XVE counts, 128/256 Large-GRF modes, SLM banks/stride, XMX/DPAS shapes, and cache lines.',
            inputSchema => {
                type       => 'object',
                properties => {
                    arch => {
                        type        => 'string',
                        description => 'Target Intel GPU architecture (xe_lp, xe_hpg, xe_hpc, xe2_lpg, xe2_hpg, aliases like pvc/battlemage/alchemist, or "all").',
                    },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_arch_spec($args || {});
            },
        },
        {
            name        => 'intel_gpu_occupancy_calc',
            description => 'Calculate Intel GPU hardware occupancy, active threads/XVE, SLM-limited workgroups/Xe-Core, Large-GRF register spill risk, and actionable tuning advice.',
            inputSchema => {
                type       => 'object',
                properties => {
                    arch            => { type => 'string',  description => 'Target arch (xe_lp, xe_hpg, xe_hpc, xe2_lpg, xe2_hpg). Default: xe2_hpg.' },
                    subgroup_size   => { type => 'integer', description => 'Compiled SIMD/subgroup width (8, 16, or 32).' },
                    grf_mode        => { type => 'integer', description => 'GRF mode per thread: 128 (standard) or 256 (Large-GRF).' },
                    regs_per_thread => { type => 'integer', description => 'Estimated GRF registers used per hardware thread.' },
                    slm_bytes       => { type => 'integer', description => 'Shared Local Memory (SLM) bytes allocated per work-group.' },
                    workgroup_size  => { type => 'integer', description => 'Work-items per work-group (integer or [x,y,z] array).' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_occupancy_calc($args || {});
            },
        },
        {
            name        => 'intel_gpu_api_lookup',
            description => 'Look up Intel GPU compute API references across SYCL (nd_item, sub_group, local_accessor, joint_matrix, group_barrier), OpenCL C (intel_sub_group_*, DPAS matrix_mad), and Level Zero (zeCommandList*, zeMemAlloc*).',
            inputSchema => {
                type       => 'object',
                properties => {
                    query => { type => 'string', description => 'API symbol, intrinsic, or keyword to look up.' },
                    api   => { type => 'string', description => 'Optional API filter: sycl, opencl, level_zero, or all.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_api_lookup($args || {});
            },
        },
        {
            name        => 'intel_gpu_kernel_audit',
            description => 'Audit SYCL or OpenCL C kernel source for subgroup divergence, missing reqd_sub_group_size, uncoalesced strides, SLM 32-bank conflicts, FP64 emulation traps on consumer Xe-LP/HPG, divergent barriers, plus live ocloc compilation when installed.',
            inputSchema => {
                type       => 'object',
                properties => {
                    source       => { type => 'string',  description => 'SYCL or OpenCL C kernel source text.' },
                    arch         => { type => 'string',  description => 'Target Intel GPU arch (default: xe_hpg).' },
                    lang         => { type => 'string',  description => 'Source language: sycl, opencl, or auto.' },
                    run_compiler => { type => 'boolean', description => 'Invoke ocloc if installed (default: true).' },
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
    return 'xe2_hpg' unless defined $raw && length $raw;
    my $k = lc($raw);
    $k =~ s/[\s\-]+/_/g;
    $k =~ s/^intel_//;
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
            error     => "Unknown Intel GPU architecture '$raw'. Supported: " . join(', ', @ARCH_ORDER),
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
    my $arch_key = _normalize_arch($args->{arch} // 'xe2_hpg');
    if (!$arch_key || !$ARCH_SPECS{$arch_key}) {
        return {
            ok        => 0,
            error     => "Unknown Intel GPU architecture '" . ($args->{arch} // '') . "'",
            supported => \@ARCH_ORDER,
        };
    }
    my $spec = $ARCH_SPECS{$arch_key};

    my $sg_size  = int($args->{subgroup_size} // $spec->{preferred_subgroup});
    my $grf_raw  = $args->{grf_mode};
    my $grf_mode = 128;
    if (defined $grf_raw) {
        if (lc($grf_raw) eq 'large' || lc($grf_raw) eq '256') {
            $grf_mode = 256;
        }
        elsif (lc($grf_raw) eq 'auto') {
            my $r = int($args->{regs_per_thread} // $args->{grf_count} // 64);
            $grf_mode = ($r > 128 && $spec->{large_grf_supported}) ? 256 : 128;
        }
        else {
            $grf_mode = int($grf_raw) >= 200 ? 256 : 128;
        }
    }

    my $regs_per_thread = int($args->{regs_per_thread} // $args->{grf_count} // 64);
    $regs_per_thread = 1 if $regs_per_thread < 1;

    my $slm_bytes = int($args->{slm_bytes} // 0);
    $slm_bytes = 0 if $slm_bytes < 0;

    my $wg_size = _parse_wg_size($args->{workgroup_size}, 256);

    my (@warnings, @advice);

    # Validate subgroup width
    my %valid_simd = map { $_ => 1 } @{ $spec->{simd_widths} };
    if (!$valid_simd{$sg_size}) {
        push @warnings, sprintf(
            'Subgroup size %d is not supported on %s (supported: %s); clamping calculation to %d.',
            $sg_size, $arch_key, join('/', @{ $spec->{simd_widths} }), $spec->{preferred_subgroup}
        );
        push @advice, "Pin [[intel::reqd_sub_group_size($spec->{preferred_subgroup})]] for $arch_key (SIMD8 is not supported on Xe-HPC/Xe2).";
        $sg_size = $spec->{preferred_subgroup};
    }

    # Validate Large-GRF availability
    if ($grf_mode == 256 && !$spec->{large_grf_supported}) {
        push @warnings, "256-GRF Large-GRF mode is not supported on $arch_key; falling back to 128-GRF mode.";
        $grf_mode = 128;
    }

    if ($wg_size > $spec->{max_workgroup_size}) {
        push @warnings, "Work-group size $wg_size exceeds hardware maximum $spec->{max_workgroup_size} on $arch_key.";
    }
    if ($wg_size % $sg_size != 0) {
        push @warnings, "Work-group size $wg_size is not a multiple of subgroup size $sg_size (tail subgroup lanes wasted).";
        push @advice, "Choose workgroup_size as a multiple of $sg_size (e.g. " . (ceil($wg_size / $sg_size) * $sg_size) . ").";
    }

    my $grf_bytes             = $spec->{grf_size_bytes};
    my $reg_budget_bytes      = $grf_mode * $grf_bytes;
    my $reg_used_bytes        = $regs_per_thread * $grf_bytes;
    my $spill_grfs            = $regs_per_thread > $grf_mode ? ($regs_per_thread - $grf_mode) : 0;
    my $spill_bytes           = $spill_grfs * $grf_bytes;
    my $spill_risk            = 'LOW';
    if ($spill_grfs > 0) {
        $spill_risk = 'CRITICAL';
        if ($grf_mode == 128 && $spec->{large_grf_supported}) {
            push @advice, sprintf(
                'Kernel needs %d GRFs (>128), causing %d GRFs (%d B/thread) of scratch spill. Enable Large-GRF 256 mode (-ze-opt-large-register-file or grf_size<256>); halving thread slots (8->4/XVE) is typically faster than spilling.',
                $regs_per_thread, $spill_grfs, $spill_bytes
            );
        }
        else {
            push @advice, sprintf(
                'Kernel exceeds %d-GRF limit by %d GRFs (%d B/thread spill to scratch). Reduce live register tile dimensions, shrink unroll factors, or hoist invariants into SLM/uniform registers.',
                $grf_mode, $spill_grfs, $spill_bytes
            );
        }
    }
    elsif ($regs_per_thread > int($grf_mode * 0.85)) {
        $spill_risk = 'HIGH';
        push @advice, sprintf(
            'Register usage (%d/%d GRFs, %.0f%%) is close to spill threshold; monitor IGC spill reports (-ze-intel-enable-auto-large-GRF-mode).',
            $regs_per_thread, $grf_mode, 100.0 * $regs_per_thread / $grf_mode
        );
    }
    elsif ($regs_per_thread > int($grf_mode * 0.65)) {
        $spill_risk = 'MODERATE';
    }

    if ($grf_mode == 256 && $regs_per_thread <= 128) {
        push @advice, "Kernel uses only $regs_per_thread GRFs (<=128) while compiled in 256-GRF Large-GRF mode; switching to 128-GRF mode doubles available hardware threads/XVE from $spec->{threads_per_xve_large_grf} to $spec->{threads_per_xve_std}.";
    }

    my $max_threads_xve_hw   = $spec->{threads_per_xve_std};
    my $max_threads_xve_mode = ($grf_mode == 256) ? $spec->{threads_per_xve_large_grf} : $spec->{threads_per_xve_std};
    my $max_threads_core_hw  = $spec->{xves_per_core} * $max_threads_xve_hw;
    my $max_threads_core_mod = $spec->{xves_per_core} * $max_threads_xve_mode;

    my $hw_threads_per_wg = ceil($wg_size / $sg_size);
    my $wgs_by_threads    = $hw_threads_per_wg > 0 ? int($max_threads_core_mod / $hw_threads_per_wg) : 0;

    my $slm_gran    = $spec->{slm_alloc_granularity} || 1024;
    my $slm_aligned = $slm_bytes > 0 ? (ceil($slm_bytes / $slm_gran) * $slm_gran) : 0;
    my $wgs_by_slm  = $spec->{max_wgs_per_core};
    if ($slm_bytes > $spec->{slm_bytes}) {
        $wgs_by_slm = 0;
        push @warnings, "Requested SLM ($slm_bytes B) exceeds $arch_key per-$spec->{core_name} SLM limit ($spec->{slm_bytes} B).";
        push @advice, "Reduce per-workgroup SLM footprint to <= $spec->{slm_bytes} bytes (or <= " . int($spec->{slm_bytes} / 2) . " bytes to allow >= 2 concurrent work-groups per $spec->{core_name}).";
    }
    elsif ($slm_aligned > 0) {
        $wgs_by_slm = int($spec->{slm_bytes} / $slm_aligned);
    }

    my $active_wgs = $wgs_by_threads;
    $active_wgs = $wgs_by_slm if $wgs_by_slm < $active_wgs;
    $active_wgs = $spec->{max_wgs_per_core} if $spec->{max_wgs_per_core} < $active_wgs;
    $active_wgs = 0 if $active_wgs < 0;

    my $active_threads_core = $active_wgs * $hw_threads_per_wg;
    my $active_threads_xve  = sprintf('%.2f', $active_threads_core / $spec->{xves_per_core}) + 0;
    my $hw_occ_pct          = sprintf('%.1f', 100.0 * $active_threads_core / $max_threads_core_hw) + 0;
    my $mode_occ_pct        = $max_threads_core_mod > 0
        ? (sprintf('%.1f', 100.0 * $active_threads_core / $max_threads_core_mod) + 0)
        : 0;

    my $limiting = 'NONE';
    if ($slm_bytes > $spec->{slm_bytes}) {
        $limiting = 'SLM_OVERFLOW';
    }
    elsif ($spill_grfs > 0) {
        $limiting = 'REGISTER_SPILL';
    }
    elsif ($wgs_by_slm < $wgs_by_threads && $wgs_by_slm <= $spec->{max_wgs_per_core}) {
        $limiting = 'SLM';
        push @advice, sprintf(
            'SLM limits concurrency to %d work-groups/%s (%d B aligned out of %d B). Reducing SLM to <= %d B unlocks %d concurrent work-groups.',
            $wgs_by_slm, $spec->{core_name}, $slm_aligned, $spec->{slm_bytes},
            ($wgs_by_slm + 1 > 0 ? int($spec->{slm_bytes} / ($wgs_by_slm + 1)) : $spec->{slm_bytes}),
            $wgs_by_slm + 1
        );
    }
    elsif ($spec->{max_wgs_per_core} < $wgs_by_threads) {
        $limiting = 'MAX_WORKGROUPS_PER_CORE';
        push @advice, "Work-group size ($wg_size) hits the $spec->{max_wgs_per_core}-workgroups/$spec->{core_name} hardware cap; increase workgroup_size (e.g. to " . ($wg_size * 2) . ") to saturate all hardware thread slots.";
    }
    elsif ($grf_mode == 256) {
        $limiting = 'LARGE_GRF_MODE';
    }
    elsif ($active_threads_core < $max_threads_core_mod) {
        $limiting = 'WORKGROUP_GRANULARITY';
        push @advice, "Work-group thread count ($hw_threads_per_wg hw threads/WG) does not evenly divide $max_threads_core_mod slots/$spec->{core_name}; adjust workgroup_size to a power-of-2 multiple of $sg_size.";
    }

    if (!@advice) {
        push @advice, sprintf(
            'Configuration achieves %.1f%% hardware occupancy (%.2f active threads/%s) with %s spill risk on %s.',
            $hw_occ_pct, $active_threads_xve, $spec->{exec_unit_name}, $spill_risk, $arch_key
        );
    }

    return {
        ok                         => 1,
        arch                       => $arch_key,
        arch_label                 => $spec->{label},
        core_name                  => $spec->{core_name},
        exec_unit_name             => $spec->{exec_unit_name},
        subgroup_size              => $sg_size,
        grf_mode                   => $grf_mode,
        grf_size_bytes             => $grf_bytes,
        regs_per_thread            => $regs_per_thread,
        reg_used_bytes_per_thread  => $reg_used_bytes,
        reg_budget_bytes_per_thread => $reg_budget_bytes,
        workgroup_size             => $wg_size,
        hw_threads_per_workgroup   => $hw_threads_per_wg,
        slm_bytes_requested        => $slm_bytes,
        slm_bytes_aligned          => $slm_aligned,
        slm_capacity_bytes         => $spec->{slm_bytes},
        wgs_limited_by_threads     => $wgs_by_threads,
        wgs_limited_by_slm         => $wgs_by_slm,
        active_workgroups_per_core => $active_wgs,
        active_threads_per_core    => $active_threads_core,
        max_threads_per_core_hw    => $max_threads_core_hw,
        max_threads_per_core_mode  => $max_threads_core_mod,
        active_threads_per_xve     => $active_threads_xve,
        max_threads_per_xve_hw     => $max_threads_xve_hw,
        max_threads_per_xve_mode   => $max_threads_xve_mode,
        hardware_occupancy_pct     => $hw_occ_pct,
        mode_occupancy_pct         => $mode_occ_pct,
        spill_risk                 => $spill_risk,
        spill_grfs                 => $spill_grfs,
        spill_bytes_per_thread     => $spill_bytes,
        limiting_factor            => $limiting,
        warnings                   => \@warnings,
        tuning_advice              => \@advice,
    };
}

sub tool_api_lookup {
    my ($self, $args) = @_;
    my $q   = $args->{query} // '';
    my $api = lc($args->{api} // 'all');
    $q =~ s/^\s+|\s+$//g;

    my @pool = sort keys %API_DB;
    if ($api ne 'all' && length $api) {
        @pool = grep { $API_DB{$_}{api} eq $api } @pool;
    }

    if (!length $q) {
        return {
            ok      => 1,
            api     => $api,
            count   => scalar(@pool),
            entries => [ map { $API_DB{$_} } @pool ],
        };
    }

    my $ql = lc($q);
    my (@exact, @prefix, @substr);
    for my $k (@pool) {
        my $e  = $API_DB{$k};
        my $kl = lc($k);
        my $sl = lc($e->{symbol});
        (my $short = $kl) =~ s/^.*:://;
        if ($kl eq $ql || $sl eq $ql || $short eq $ql) {
            push @exact, $e;
        }
        elsif (index($kl, $ql) == 0 || index($short, $ql) == 0) {
            push @prefix, $e;
        }
        elsif (index($kl, $ql) >= 0 || index(lc($e->{summary}), $ql) >= 0 || index(lc($e->{details}), $ql) >= 0) {
            push @substr, $e;
        }
    }

    my @matches = (@exact, @prefix, @substr);
    return {
        ok      => 1,
        query   => $q,
        api     => $api,
        count   => scalar(@matches),
        matches => \@matches,
    };
}

sub _run_ocloc_check {
    my ($source, $ocloc_device) = @_;
    my $ocloc = _find_executable('ocloc');
    return {
        tool      => 'ocloc',
        available => 0,
        note      => 'Intel ocloc not found on PATH; returning static analysis only.',
    } unless $ocloc;

    my ($fh, $path) = File::Temp::tempfile('npl_intel_XXXXXX', SUFFIX => '.cl', UNLINK => 1);
    print {$fh} $source;
    close $fh;

    my $out_prefix = $path;
    $out_prefix =~ s/\.cl$//;
    my @cmd = (
        $ocloc, 'compile',
        '-file', $path,
        '-device', ($ocloc_device || 'dg2'),
        '-output', $out_prefix,
        '-output_no_suffix',
        '-options', '-cl-std=CL3.0',
    );

    my ($wtr, $rdr, $err);
    $err = gensym;
    my $pid = eval { open3($wtr, $rdr, $err, @cmd) };
    if (!$pid) {
        return {
            tool      => 'ocloc',
            available => 1,
            executed  => 0,
            error     => "Failed to launch ocloc: $@",
        };
    }
    close $wtr;
    my $stdout = do { local $/; <$rdr> } // '';
    my $stderr = do { local $/; <$err> } // '';
    close $rdr;
    close $err;
    waitpid($pid, 0);
    my $rc = $? >> 8;

    # Cleanup generated ocloc artifacts if any
    for my $ext ('', '.bin', '.gen', '.spv', '.bc') {
        unlink "${out_prefix}${ext}" if -e "${out_prefix}${ext}";
    }

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
                code     => 'OCLOC',
                message  => $4,
            };
        }
    }

    return {
        tool        => 'ocloc',
        path        => $ocloc,
        available   => 1,
        executed    => 1,
        exit_code   => $rc,
        device      => $ocloc_device || 'dg2',
        diagnostics => \@diags,
    };
}

sub tool_kernel_audit {
    my ($self, $args) = @_;
    my $src = $args->{source} // $args->{code};
    return { ok => 0, error => 'Missing required parameter: source' }
        unless defined $src && length $src;

    my $arch_key = _normalize_arch($args->{arch} // 'xe_hpg') || 'xe_hpg';
    my $spec     = $ARCH_SPECS{$arch_key};
    my $lang     = lc($args->{lang} // 'auto');
    if ($lang eq 'auto') {
        $lang = ($src =~ /\bsycl::|\bparallel_for\b|\bnd_item\b|\blocal_accessor\b/) ? 'sycl' : 'opencl';
    }
    my $run_compiler = exists($args->{run_compiler}) ? ($args->{run_compiler} ? 1 : 0) : 1;

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
            code       => $f{code}     || 'INTEL_AUDIT',
            message    => $f{message}  || '',
            suggestion => $f{suggestion} // '',
        };
    };

    my $has_reqd_sg     = ($src =~ /\b(?:intel|sycl)::reqd_sub_group_size\s*\(\s*(\d+)\s*\)|\bintel_reqd_sub_group_size\s*\(\s*(\d+)\s*\)/) ? 1 : 0;
    my $pinned_sg_width = defined($1) ? int($1) : (defined($2) ? int($2) : 0);

    my $uses_subgroup_ops = 0;
    my $first_sg_line     = 0;
    my $writes_slm        = 0;
    my $has_slm_barrier   = 0;
    my $first_slm_line    = 0;

    # Track naive brace depth of thread-divergent if/else blocks
    my $brace_depth    = 0;
    my @divergent_blks; # list of brace depths where a lane/thread-id branch started
    my $pending_div_if = 0;

    for (my $i = 0; $i < @lines; $i++) {
        my $raw = $lines[$i];
        (my $code = $raw) =~ s{//.*$}{};
        next if $code =~ /^\s*$/;

        # Check pinned SIMD8 on Xe-HPC / Xe2
        if ($code =~ /\b(?:(?:intel|sycl)::reqd_sub_group_size|intel_reqd_sub_group_size)\s*\(\s*(\d+)\s*\)/) {
            my $w = int($1);
            my %ok_w = map { $_ => 1 } @{ $spec->{simd_widths} };
            if (!$ok_w{$w}) {
                $add_finding->(
                    line       => $i,
                    col        => index($raw, $1),
                    end_col    => index($raw, $1) + length($1),
                    severity   => 'error',
                    code       => 'INTEL_SIMD_UNSUPPORTED',
                    message    => "reqd_sub_group_size($w) is unsupported on $arch_key (supported: " . join('/', @{ $spec->{simd_widths} }) . ').',
                    suggestion => "Change reqd_sub_group_size($w) to reqd_sub_group_size($spec->{preferred_subgroup}) for $arch_key.",
                );
            }
        }

        # Subgroup API usage
        if ($code =~ /\b(get_sub_group|intel_sub_group_\w+|joint_matrix(?:_\w+)?|permute_group_by_xor|shift_group_left|shift_group_right|select_from_group|reduce_over_group|sub_group_barrier|sub_group_broadcast)\b/) {
            if (!$uses_subgroup_ops) {
                $uses_subgroup_ops = 1;
                $first_sg_line     = $i;
            }
            if (@divergent_blks || $pending_div_if) {
                my $tok = $1;
                my $c   = index($raw, $tok);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($tok) : 1),
                    severity   => 'error',
                    code       => 'INTEL_SG_DIVERGENCE',
                    message    => "Sub-group operation '$tok' called inside thread/lane-divergent control flow.",
                    suggestion => 'Hoist subgroup shuffles, reductions, and DPAS/joint_matrix ops to uniform control flow and predicate only the final store.',
                );
            }
        }

        # Barriers inside divergent control flow
        if ($code =~ /\b(group_barrier|sub_group_barrier|work_group_barrier|barrier)\s*\(/) {
            $has_slm_barrier = 1;
            if (@divergent_blks || $pending_div_if) {
                my $tok = $1;
                my $c   = index($raw, $tok);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($tok) : 1),
                    severity   => 'error',
                    code       => 'INTEL_BARRIER_DIVERGENT',
                    message    => "Barrier '$tok()' executed inside thread-divergent branch; will deadlock Intel GPU hardware threads.",
                    suggestion => 'Move barrier outside per-thread conditionals so every work-item in the work-group reaches it uniformly.',
                );
            }
        }

        # FP64 / double trap on consumer Xe-LP / Xe-HPG / reduced-rate Xe2
        if ($spec->{fp64_support} ne 'native_full_rate'
            && $code =~ /\b(double(?:2|3|4|8|16)?)\b/
            && $code !~ /#pragma\s+OPENCL\s+EXTENSION/)
        {
            my $tok = $1;
            my $c   = index($raw, $tok);
            my $sev = ($spec->{fp64_support} eq 'none_emulated') ? 'error' : 'warn';
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + length($tok) : 1),
                severity   => $sev,
                code       => 'INTEL_FP64_TRAP',
                message    => "FP64 type '$tok' used on $arch_key ($spec->{fp64_ratio}).",
                suggestion => 'Use float, sycl::half, or bfloat16 on consumer Xe-LP/Xe-HPG/Xe2, or target Xe-HPC (Ponte Vecchio) for full-rate native FP64.',
            );
        }

        # SLM declarations & 32-bank conflicts
        if ($code =~ /\b(?:__local|local|local_accessor)\b/) {
            $first_slm_line = $i unless $writes_slm;
            $writes_slm = 1;
            if ($code =~ /\[\s*(?:32|64|128)\s*\]\s*\[\s*(32|64)\s*\]/
                || $code =~ /local_accessor<[^>]+,\s*2>\s*\w+\s*\(\s*\{\s*(?:32|64)\s*,\s*(32|64)\s*\}/)
            {
                my $dim = $1;
                $add_finding->(
                    line       => $i,
                    col        => 0,
                    end_col    => length($raw),
                    severity   => 'warn',
                    code       => 'INTEL_SLM_BANK_CONFLICT',
                    message    => "2D SLM array inner dimension $dim is a multiple of Intel's 32 SLM banks (4B stride), risking 32-way bank conflicts on column reads.",
                    suggestion => "Pad the inner SLM dimension by +1 (e.g., " . ($dim + 1) . ") or apply XOR bank swizzling.",
                );
            }
        }
        if ($code =~ /\b(?:slm|local_\w+|tile|shared_\w+)\s*\[\s*[^\]\n]*\*\s*(32|64|128)\b/) {
            my $stride = $1;
            $add_finding->(
                line       => $i,
                col        => 0,
                end_col    => length($raw),
                severity   => 'warn',
                code       => 'INTEL_SLM_BANK_CONFLICT',
                message    => "SLM indexing with stride $stride hits the same SLM bank across all lanes (32 banks x 4B stride).",
                suggestion => 'Pad stride to ' . ($stride + 1) . ' or transpose access pattern so adjacent subgroup lanes access consecutive 4-byte banks.',
            );
        }

        # Uncoalesced global memory strided access on contiguous lane/global ID
        if ($code =~ /\b(\w+)\s*\[\s*(?:get_global_id\s*\(\s*0\s*\)|get_local_id\s*\(\s*0\s*\)|gid|lid|tid|sg_id)\s*\*\s*(\d+|[A-Za-z_]\w*)\s*(?:\+|\])/) {
            my ($arr, $stride) = ($1, $2);
            if ($arr !~ /^(?:slm|local_|tile|shared_)/i && ($stride !~ /^\d+$/ || int($stride) >= 4)) {
                my $c = index($raw, $arr);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($arr) : 1),
                    severity   => 'warn',
                    code       => 'INTEL_UNCOALESCED_STRIDE',
                    message    => "Potentially uncoalesced memory access '${arr}[id * $stride]' breaks 64B cache-line coalescing across subgroup lanes.",
                    suggestion => 'Use unit-stride access on the innermost work-item ID (Structure-of-Arrays), stage via SLM transpose, or use intel_sub_group_block_read4().',
                );
            }
        }

        # Detect thread-divergent if condition
        my $is_div_cond = 0;
        if ($code =~ /\bif\s*\(([^)]+)\)/) {
            my $cond = $1;
            if ($cond =~ /\b(?:get_local_id|get_global_id|get_sub_group_local_id|get_local_linear_id|local_id|global_id|lane|lid|tid|gid|item\.get_)\b/) {
                $is_div_cond = 1;
            }
        }

        # Track braces
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
            else {
                # Single-line if (...) stmt; check inline barrier/sg op already happened above
                $pending_div_if = 0;
            }
        }
        elsif ($pending_div_if) {
            if ($opens > 0) {
                push @divergent_blks, $brace_depth + 1;
            }
            $pending_div_if = 0;
        }

        $brace_depth += ($opens - $closes);
        $brace_depth = 0 if $brace_depth < 0;
        while (@divergent_blks && $brace_depth < $divergent_blks[-1]) {
            pop @divergent_blks;
        }
    }

    if ($uses_subgroup_ops && !$has_reqd_sg) {
        $add_finding->(
            line       => $first_sg_line,
            col        => 0,
            end_col    => 1,
            severity   => 'warn',
            code       => 'INTEL_REQD_SG_MISSING',
            message    => "Kernel uses sub-group operations without pinning [[intel::reqd_sub_group_size($spec->{preferred_subgroup})]].",
            suggestion => $lang eq 'sycl'
                ? "Add [[intel::reqd_sub_group_size($spec->{preferred_subgroup})]] (or [[sycl::reqd_sub_group_size($spec->{preferred_subgroup})]]) to the kernel lambda/functor."
                : "Add __attribute__((intel_reqd_sub_group_size($spec->{preferred_subgroup}))) to the __kernel declaration.",
        );
    }

    if ($writes_slm && !$has_slm_barrier && $src =~ /\[\s*[^\]]+\s*\]\s*=/) {
        $add_finding->(
            line       => $first_slm_line,
            col        => 0,
            end_col    => 1,
            severity   => 'warn',
            code       => 'INTEL_SLM_BARRIER_MISSING',
            message    => 'SLM (__local / local_accessor) used without any work-group barrier (group_barrier / work_group_barrier / barrier).',
            suggestion => 'Synchronize SLM writes before cross-work-item reads using sycl::group_barrier(it.get_group()) or work_group_barrier(CLK_LOCAL_MEM_FENCE).',
        );
    }

    my $ext_compiler = {
        tool      => 'ocloc',
        available => 0,
        skipped   => 1,
    };
    if ($run_compiler && $lang eq 'opencl') {
        $ext_compiler = _run_ocloc_check($src, $spec->{ocloc_device});
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
        lang              => $lang,
        pinned_sg_width   => $pinned_sg_width,
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
    $line //= '';

    my @candidates = ($word);
    if ($line =~ /((?:sycl::(?:ext::(?:oneapi|intel)::experimental::(?:matrix::)?)?)\Q$word\E)/) {
        unshift @candidates, $1;
    }

    for my $cand (@candidates) {
        if (my $e = $API_DB{$cand}) {
            my $md = "### `$e->{symbol}` (*Intel GPU / " . uc($e->{api}) . "*)\n\n"
                   . "```cpp\n$e->{signature}\n```\n\n"
                   . "$e->{summary}\n\n"
                   . "$e->{details}\n\n"
                   . "**Example:**\n```cpp\n$e->{example}\n```";
            return { contents => $md, kind => 'markdown', title => $e->{symbol} };
        }
    }

    # Short suffix match (e.g. nd_item -> sycl::nd_item, reqd_sub_group_size)
    my $wl = lc($word);
    for my $k (sort keys %API_DB) {
        (my $short = lc($k)) =~ s/^.*:://;
        if ($short eq $wl || lc($k) eq $wl) {
            my $e = $API_DB{$k};
            my $md = "### `$e->{symbol}` (*Intel GPU / " . uc($e->{api}) . "*)\n\n"
                   . "```cpp\n$e->{signature}\n```\n\n"
                   . "$e->{summary}\n\n$e->{details}";
            return { contents => $md, kind => 'markdown', title => $e->{symbol} };
        }
    }

    # Architecture keyword hover
    if (my $ak = _normalize_arch($word)) {
        if (my $s = $ARCH_SPECS{$ak}) {
            my $md = "### $s->{label}\n\n"
                   . "- **SIMD/Subgroup widths:** " . join('/', @{ $s->{simd_widths} }) . " (preferred: $s->{preferred_subgroup})\n"
                   . "- **Core:** $s->{xves_per_core} $s->{exec_unit_name}s / $s->{core_name}\n"
                   . "- **GRF:** " . join('/', @{ $s->{grf_modes} }) . " × $s->{grf_size_bytes}B ($s->{reg_bytes_per_thread_std}B std)\n"
                   . "- **SLM:** $s->{slm_kib} KiB ($s->{slm_banks} banks × $s->{slm_bank_stride_bytes}B)\n"
                   . "- **FP64:** $s->{fp64_ratio}\n";
            return { contents => $md, kind => 'markdown', title => $s->{label} };
        }
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $p = lc($prefix // '');
    my @items;
    for my $k (sort keys %API_DB) {
        my $e = $API_DB{$k};
        (my $short = lc($k)) =~ s/^.*:://;
        next if length($p) && index(lc($k), $p) < 0 && index($short, $p) < 0;
        my $kind_num = $NeoPerl::MCP::Pack::COMPLETION_KIND{ $e->{kind} // 'function' } || 3;
        push @items, {
            label         => $e->{symbol},
            kind          => $kind_num,
            detail        => uc($e->{api}) . ' — ' . $e->{signature},
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
        lang         => ($lang && lc($lang) =~ /^(?:sycl|opencl)$/) ? lc($lang) : 'auto',
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
        if ($l =~ /\b(?:__kernel|kernel)\b.*?\bvoid\s+([A-Za-z_]\w*)\s*\(/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'function',
                line   => $i,
                col    => index($l, $1),
                detail => 'OpenCL kernel',
            );
        }
        elsif ($l =~ /\b(?:struct|class)\s+([A-Za-z_]\w*)/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'struct',
                line   => $i,
                col    => index($l, $1),
                detail => 'SYCL/C++ type',
            );
        }
        elsif ($l =~ /\bparallel_for\s*<\s*(?:class\s+|struct\s+)?([A-Za-z_]\w*)\s*>/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'function',
                line   => $i,
                col    => index($l, $1),
                detail => 'SYCL kernel dispatch',
            );
        }
        elsif ($l =~ /^\s*(?:static\s+|inline\s+)*(?:void|float\d*|int\d*|uint\d*|half\d*|bool)\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:\{|$)/) {
            my $name = $1;
            next if $name =~ /^(?:if|for|while|switch)$/;
            push @syms, $self->make_symbol(
                name   => $name,
                kind   => 'function',
                line   => $i,
                col    => index($l, $name),
                detail => 'device/host function',
            );
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::IntelGPU - Intel GPU compute MCP pack (oneAPI / SYCL / OpenCL / Level Zero)

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::IntelGPU;

    my $pack = NeoPerl::MCP::Pack::IntelGPU->new();
    my $spec = $pack->call_tool('intel_gpu_arch_spec', { arch => 'xe2_hpg' });
    my $occ  = $pack->call_tool('intel_gpu_occupancy_calc', {
        arch            => 'xe_hpc',
        subgroup_size   => 16,
        grf_mode        => 256,
        regs_per_thread => 192,
        slm_bytes       => 32768,
        workgroup_size  => 256,
    });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::IntelGPU> provides four MCP tools and matching LSP
knowledge hooks for Intel GPU kernel development across Xe-LP (Gen12), Xe-HPG
(Arc Alchemist), Xe-HPC (Ponte Vecchio), Xe2-LPG (Lunar/Arrow Lake), and
Xe2-HPG (Arc Battlemage):

=over 4

=item * C<intel_gpu_arch_spec> - Hardware architecture tables (SIMD/subgroup widths, EU/XVE counts, 128 vs 256 Large-GRF modes, SLM banks/stride, XMX DPAS shapes, and cache lines).

=item * C<intel_gpu_occupancy_calc> - Exact active threads/XVE, hardware occupancy percentage, SLM-limited work-group concurrency, and Large-GRF spill risk analysis.

=item * C<intel_gpu_api_lookup> - Reference database for SYCL, OpenCL C (C<cl_intel_subgroups>, DPAS), and Level Zero APIs.

=item * C<intel_gpu_kernel_audit> - Static kernel audit for subgroup divergence, missing C<reqd_sub_group_size>, SLM 32-bank conflicts, uncoalesced global strides, consumer FP64 emulation traps, divergent barriers, plus optional live C<ocloc> compilation.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
