package NeoPerl::MCP::Pack::MetalDev;

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
    apple7   => 'apple7',
    m1       => 'apple7',
    m1_pro   => 'apple7',
    m1pro    => 'apple7',
    m1_max   => 'apple7',
    m1max    => 'apple7',
    m1_ultra => 'apple7',
    m1ultra  => 'apple7',
    a14      => 'apple7',

    apple8   => 'apple8',
    m2       => 'apple8',
    m2_pro   => 'apple8',
    m2pro    => 'apple8',
    m2_max   => 'apple8',
    m2max    => 'apple8',
    m2_ultra => 'apple8',
    m2ultra  => 'apple8',
    a15      => 'apple8',
    a16      => 'apple8',

    apple9   => 'apple9',
    m3       => 'apple9',
    m3_pro   => 'apple9',
    m3pro    => 'apple9',
    m3_max   => 'apple9',
    m3max    => 'apple9',
    m4       => 'apple9',
    m4_pro   => 'apple9',
    m4pro    => 'apple9',
    m4_max   => 'apple9',
    m4max    => 'apple9',
    a17      => 'apple9',
    a17_pro  => 'apple9',
    a18      => 'apple9',
);

my @ARCH_ORDER = qw(apple7 apple8 apple9);

my %ARCH_SPECS = (
    apple7 => {
        arch                        => 'apple7',
        gpu_family                  => 'MTLGPUFamilyApple7',
        label                       => 'Apple Silicon Apple7 (M1 / M1 Pro / M1 Max / M1 Ultra / A14)',
        metal_version               => 'Metal 3.0+',
        architecture                => 'Apple Silicon TBDR (Tile-Based Deferred Renderer)',
        simd_width                  => 32,
        max_threads_per_threadgroup => 1024,
        threadgroup_mem_bytes       => 32768,
        threadgroup_mem_kib         => 32,
        threadgroup_mem_align_bytes => 16,
        threadgroup_mem_banks       => 32,
        threadgroup_mem_stride      => 4,
        tile_memory_kib             => 32,
        tile_dimensions             => '32x32 or 16x16 pixels (depends on per-pixel imageblock byte size)',
        dynamic_caching             => 0,
        half_alu_multiplier         => 2,
        half_alu_note               => '2x FP16 (half) ALU throughput vs FP32 (float), and half the register footprint',
        simdgroup_matrix_shape      => '8x8',
        simdgroup_matrix_types      => [ qw(half float) ],
        hardware_ray_tracing        => 0,
        mesh_shaders                => 0,
        non_uniform_threadgroups    => 1,
        max_simdgroups_per_core_est => 64,
        core_tg_sram_pool_bytes     => 65536,
        float3_size_bytes           => 16,
        float3_align_bytes          => 16,
        packed_float3_size_bytes    => 12,
        packed_float3_align_bytes   => 4,
        uma_storage_modes           => {
            MTLStorageModeShared     => 'Zero-copy CPU+GPU coherent Unified Memory (ideal for dynamic vertex/uniform buffers).',
            MTLStorageModePrivate    => 'GPU-only optimal tiled/lossless-compressed layout (best for textures, render targets, static geometry).',
            MTLStorageModeMemoryless => 'Lives exclusively in on-chip TBDR tile memory (0 DRAM allocated, 0 DRAM bandwidth; ideal for transient depth/MSAA/G-buffer).',
        },
        notes => [
            '32-thread SIMD-group (threadExecutionWidth == 32), 32 KiB threadgroup memory, 32 KiB TBDR tile imageblock.',
            'FP16 (half) executes at 2x FP32 throughput with half the register pressure; prefer half in fragment/ML shaders.',
            'ABI TRAP: float3 is 16 bytes (16B aligned) in MSL vs 12 bytes in C — use packed_float3 or explicit 16B padding.',
        ],
    },
    apple8 => {
        arch                        => 'apple8',
        gpu_family                  => 'MTLGPUFamilyApple8',
        label                       => 'Apple Silicon Apple8 (M2 / M2 Pro / M2 Max / M2 Ultra / A15 / A16)',
        metal_version               => 'Metal 3.1+',
        architecture                => 'Apple Silicon TBDR (Tile-Based Deferred Renderer)',
        simd_width                  => 32,
        max_threads_per_threadgroup => 1024,
        threadgroup_mem_bytes       => 32768,
        threadgroup_mem_kib         => 32,
        threadgroup_mem_align_bytes => 16,
        threadgroup_mem_banks       => 32,
        threadgroup_mem_stride      => 4,
        tile_memory_kib             => 32,
        tile_dimensions             => '32x32 or 16x16 pixels',
        dynamic_caching             => 0,
        half_alu_multiplier         => 2,
        half_alu_note               => '2x FP16 (half) ALU throughput vs FP32 (float), enhanced L2/SLC bandwidth',
        simdgroup_matrix_shape      => '8x8',
        simdgroup_matrix_types      => [ qw(half bfloat float) ],
        hardware_ray_tracing        => 0,
        mesh_shaders                => 1,
        non_uniform_threadgroups    => 1,
        max_simdgroups_per_core_est => 64,
        core_tg_sram_pool_bytes     => 65536,
        float3_size_bytes           => 16,
        float3_align_bytes          => 16,
        packed_float3_size_bytes    => 12,
        packed_float3_align_bytes   => 4,
        uma_storage_modes           => {
            MTLStorageModeShared     => 'Zero-copy CPU+GPU coherent Unified Memory.',
            MTLStorageModePrivate    => 'GPU-only optimal tiled/compressed layout.',
            MTLStorageModeMemoryless => 'On-chip TBDR tile memory only — zero DRAM footprint/bandwidth for transient depth/MSAA.',
        },
        notes => [
            '32-thread SIMD-group, 32 KiB threadgroup memory, 2x half ALU throughput, simdgroup_matrix 8x8 (FP16/BF16/FP32).',
            'Supports Metal 3.1+ mesh/object shaders and bfloat16 matrix ops alongside larger L2/SLC caches.',
            'Use dispatchThreads:threadsPerThreadgroup: for clean hardware-native non-uniform grid bounds.',
        ],
    },
    apple9 => {
        arch                        => 'apple9',
        gpu_family                  => 'MTLGPUFamilyApple9',
        label                       => 'Apple Silicon Apple9 (M3 / M3 Pro / M3 Max / M4 / M4 Pro / M4 Max / A17 Pro / A18)',
        metal_version               => 'Metal 3.2+',
        architecture                => 'Apple Silicon TBDR with Hardware Dynamic Caching',
        simd_width                  => 32,
        max_threads_per_threadgroup => 1024,
        threadgroup_mem_bytes       => 32768,
        threadgroup_mem_kib         => 32,
        threadgroup_mem_align_bytes => 16,
        threadgroup_mem_banks       => 32,
        threadgroup_mem_stride      => 4,
        tile_memory_kib             => 32,
        tile_dimensions             => '32x32 or 16x16 pixels (backed by Dynamic Caching unified SRAM)',
        dynamic_caching             => 1,
        half_alu_multiplier         => 2,
        half_alu_note               => '2x FP16 (half) ALU throughput vs FP32 (float), with 16-bit Dynamic Caching register packing',
        simdgroup_matrix_shape      => '8x8',
        simdgroup_matrix_types      => [ qw(half bfloat float) ],
        hardware_ray_tracing        => 1,
        mesh_shaders                => 1,
        non_uniform_threadgroups    => 1,
        max_simdgroups_per_core_est => 72,
        core_tg_sram_pool_bytes     => 98304,
        float3_size_bytes           => 16,
        float3_align_bytes          => 16,
        packed_float3_size_bytes    => 12,
        packed_float3_align_bytes   => 4,
        uma_storage_modes           => {
            MTLStorageModeShared     => 'Zero-copy CPU+GPU coherent Unified Memory.',
            MTLStorageModePrivate    => 'GPU-only optimal tiled/compressed layout.',
            MTLStorageModeMemoryless => 'On-chip TBDR tile memory only — zero DRAM footprint/bandwidth for transient depth/MSAA.',
        },
        notes => [
            'Dynamic Caching dynamically allocates unified on-chip SRAM across registers, threadgroup memory, tile imageblocks, and L1 cache in real time.',
            'Hardware-accelerated ray tracing + mesh/object shaders + 2x FP16 ALU + 8x8 simdgroup_matrix (FP16/BF16/FP32).',
            'Keep threadgroup memory minimal even under Dynamic Caching so extra on-chip SRAM flows to registers and L1 cache.',
        ],
    },
);

my %MSL_DB = (
    'device' => {
        symbol    => 'device',
        category  => 'address_space',
        kind      => 'keyword',
        signature => 'device [const] T* ptr [[buffer(n)]]',
        summary   => 'MSL address space for read/write GPU device memory buffers (no size limit, cached via L1/L2).',
        details   => 'Use for large arrays, output buffers, and storage buffers. For small read-only uniform structs (<64 KiB) accessed uniformly across lanes, prefer the constant address space.',
        example   => 'kernel void saxpy(device const float* x [[buffer(0)]], device float* y [[buffer(1)]], uint id [[thread_position_in_grid]])',
    },
    'constant' => {
        symbol    => 'constant',
        category  => 'address_space',
        kind      => 'keyword',
        signature => 'constant T& uniforms [[buffer(n)]]',
        summary   => 'MSL read-only address space backed by Apple Silicon\'s dedicated constant cache and hardware preloading.',
        details   => 'Ideal for camera matrices, draw parameters, kernel dimensions, and small lookup tables shared uniformly across SIMD-group lanes.',
        example   => 'constant FrameUniforms& u [[buffer(0)]]',
    },
    'threadgroup' => {
        symbol    => 'threadgroup',
        category  => 'address_space',
        kind      => 'keyword',
        signature => 'threadgroup T tile[N];  // or threadgroup T* smem [[threadgroup(0)]]',
        summary   => 'Fast on-chip per-threadgroup shared SRAM (max 32 KiB per threadgroup, 16-byte aligned, 32 banks x 4B).',
        details   => 'Shared across all SIMD-groups in a threadgroup. Always synchronize cross-thread writes/reads with threadgroup_barrier(mem_flags::mem_threadgroup).',
        example   => 'threadgroup half tileA[32][33]; // +1 pad avoids 32-bank conflict',
    },
    'thread' => {
        symbol    => 'thread',
        category  => 'address_space',
        kind      => 'keyword',
        signature => 'thread T local_var;',
        summary   => 'Per-thread private address space (kept in GPU registers unless spilled to device stack).',
        details   => 'Default address space for local variables inside Metal functions. Avoid large dynamically indexed thread arrays to prevent register spilling.',
        example   => 'thread float acc[4] = {0, 0, 0, 0};',
    },
    '[[thread_position_in_grid]]' => {
        symbol    => '[[thread_position_in_grid]]',
        category  => 'attributes',
        kind      => 'keyword',
        signature => 'uint / uint2 / uint3 gid [[thread_position_in_grid]]',
        summary   => 'Global thread index within the compute dispatch grid (analogous to gl_GlobalInvocationID / blockIdx*blockDim+threadIdx).',
        details   => 'When using dispatchThreads:threadsPerThreadgroup: (Apple4+), hardware automatically trims grid bounds to threadsPerGrid; with dispatchThreadgroups, explicitly check gid < N.',
        example   => 'kernel void add(device float* out [[buffer(0)]], uint gid [[thread_position_in_grid]])',
    },
    '[[buffer(n)]]' => {
        symbol    => '[[buffer(n)]]',
        category  => 'attributes',
        kind      => 'keyword',
        signature => 'device/constant T* arg [[buffer(n)]]',
        summary   => 'Binds a Metal MTLBuffer (or setBytes inline uniform <= 4 KiB) to argument table index n (0..30).',
        details   => 'For small structs <= 4096 bytes, setBytes:length:atIndex: avoids MTLBuffer allocation overhead.',
        example   => 'constant Params& p [[buffer(0)]]',
    },
    'simd_sum' => {
        symbol    => 'simd_sum',
        category  => 'simd',
        kind      => 'function',
        signature => 'T simd_sum(T data)',
        summary   => 'Hardware 32-lane SIMD-group parallel sum reduction directly in registers without threadgroup memory.',
        details   => 'Part of the <metal_simdgroup> collective suite (simd_min, simd_max, simd_prefix_exclusive_sum, simd_broadcast_first). Must run in converged SIMD-group control flow.',
        example   => 'float warpTotal = simd_sum(val);',
    },
    'simd_shuffle_xor' => {
        symbol    => 'simd_shuffle_xor',
        category  => 'simd',
        kind      => 'function',
        signature => 'T simd_shuffle_xor(T data, ushort mask)',
        summary   => 'Exchanges register values between SIMD lane i and lane (i ^ mask) in 1 cycle with zero threadgroup memory.',
        details   => 'Ideal for 32-lane butterfly reductions (mask = 16, 8, 4, 2, 1), bitonic sorts, and radix passes.',
        example   => 'for (ushort m = 16; m > 0; m >>= 1) v += simd_shuffle_xor(v, m);',
    },
    'simd_ballot' => {
        symbol    => 'simd_ballot',
        category  => 'simd',
        kind      => 'function',
        signature => 'simd_vote simd_ballot(bool expr)',
        summary   => 'Returns a 32-bit bitmask (simd_vote) of active lanes in the 32-thread Apple Silicon SIMD-group where expr is true.',
        details   => 'Convert to integer bits with uint64_t(simd_ballot(expr)) or static_cast<simd_vote::vote_t>(...).',
        example   => 'simd_vote::vote_t bits = static_cast<simd_vote::vote_t>(simd_ballot(hit));',
    },
    'simdgroup_float8x8' => {
        symbol    => 'simdgroup_float8x8',
        category  => 'matrix',
        kind      => 'struct',
        signature => 'simdgroup_float8x8 / simdgroup_half8x8 / simdgroup_bfloat8x8 (<metal_simdgroup_matrix>)',
        summary   => 'Opaque 8x8 matrix tile distributed cooperatively across all 32 lanes of an Apple Silicon SIMD-group.',
        details   => 'Provides hardware-accelerated GEMM/attention via simdgroup_load, simdgroup_multiply_accumulate, and simdgroup_store on Apple7+ (M1-M4).',
        example   => 'simdgroup_half8x8 A, B; simdgroup_float8x8 C = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);',
    },
    'simdgroup_multiply_accumulate' => {
        symbol    => 'simdgroup_multiply_accumulate',
        category  => 'matrix',
        kind      => 'function',
        signature => 'void simdgroup_multiply_accumulate(simdgroup_matrix<D,8,8>& d, const simdgroup_matrix<A,8,8>& a, const simdgroup_matrix<B,8,8>& b, const simdgroup_matrix<C,8,8>& c)',
        summary   => 'Computes D = A * B + C across a 32-thread SIMD-group using Apple Silicon hardware matrix multiply units.',
        details   => 'All 32 lanes in the SIMD-group must execute uniformly (never inside a lane-divergent branch). Tile larger blocks (e.g. 32x32 per SIMD-group) in registers to maximize arithmetic intensity.',
        example   => 'simdgroup_multiply_accumulate(acc, fragA, fragB, acc);',
    },
    'threadgroup_barrier' => {
        symbol    => 'threadgroup_barrier',
        category  => 'sync',
        kind      => 'function',
        signature => 'void threadgroup_barrier(mem_flags flags)',
        summary   => 'Synchronizes all threads in a threadgroup and ensures memory visibility for the requested address spaces.',
        details   => 'Pass mem_flags::mem_threadgroup for shared SRAM tiles, mem_flags::mem_device for device buffers, or mem_flags::mem_none for execution-only sync. Must be reached uniformly by all threads in the threadgroup.',
        example   => 'tile[lid] = x[gid]; threadgroup_barrier(mem_flags::mem_threadgroup);',
    },
    'packed_float3' => {
        symbol    => 'packed_float3',
        category  => 'types',
        kind      => 'struct',
        signature => 'packed_float3 (sizeof == 12, alignof == 4) vs float3 (sizeof == 16, alignof == 16)',
        summary   => 'Tightly packed 12-byte 3-float vector matching C/C++ float[3] struct layout with zero trailing padding.',
        details   => 'Metal ABI rule: standard MSL float3 is 16 bytes (16B aligned). Using float3 in a Metal struct shared with C float[3] silently shifts every subsequent field/vertex by 4 bytes. Use packed_float3 in buffer structs (then load into float3 registers for ALU math) or align C host structs to 16B with simd_float3.',
        example   => 'struct Vertex { packed_float3 position; packed_float3 normal; float2 uv; };',
    },
    'float3' => {
        symbol    => 'float3',
        category  => 'types',
        kind      => 'struct',
        signature => 'float3 (sizeof == 16 bytes, alignof == 16 bytes in MSL)',
        summary   => '16-byte aligned 3-component vector in MSL — WARNING: differs from 12-byte C float[3]!',
        details   => 'In device/constant structs shared with C/C++/Rust, prefer packed_float3 (12B) or float4 / simd_float3 (16B explicit) to prevent silent stride corruption.',
        example   => 'float3 p = float3(v.position); // promote packed_float3 -> register float3 for math',
    },
    'half' => {
        symbol    => 'half',
        category  => 'types',
        kind      => 'struct',
        signature => 'half / half2 / half3 / half4 (IEEE 754 binary16 FP16)',
        summary   => '16-bit floating-point type executing at 2x FP32 ALU throughput and half register storage on Apple Silicon (M1-M4).',
        details   => 'Use half/half4 for PBR shading colors, normals, post-processing, and ML activations while keeping world positions and depth in float.',
        example   => 'half3 N = normalize(half3(in.normal)); half ndotl = saturate(dot(N, L));',
    },
    'MTLRenderPassDescriptor' => {
        symbol    => 'MTLRenderPassDescriptor',
        category  => 'tbdr_api',
        kind      => 'class',
        signature => 'MTLRenderPassDescriptor (loadAction / storeAction TBDR tile memory rules)',
        summary   => 'Configures render pass color/depth/stencil attachments and controls Apple Silicon TBDR on-chip tile memory traffic.',
        details   => 'TBDR guidelines: (1) Use MTLLoadActionDontCare or MTLLoadActionClear instead of MTLLoadActionLoad whenever old contents are overwritten. (2) Use MTLStoreActionDontCare on transient depth/stencil and MTLStoreActionMultisampleResolve on MSAA color so raw depth/MSAA samples are not written out to DRAM.',
        example   => 'rpd.depthAttachment.loadAction = MTLLoadActionClear; rpd.depthAttachment.storeAction = MTLStoreActionDontCare;',
    },
    'MTLStorageModeMemoryless' => {
        symbol    => 'MTLStorageModeMemoryless',
        category  => 'tbdr_api',
        kind      => 'constant',
        signature => 'texDesc.storageMode = MTLStorageModeMemoryless',
        summary   => 'Allocates a render target exclusively in Apple Silicon on-chip TBDR tile memory with ZERO system DRAM allocation or bandwidth.',
        details   => 'Must be paired with loadAction != Load (Clear or DontCare) and storeAction == DontCare (or MultisampleResolve). Reduces memory footprint and DRAM bandwidth for depth buffers, MSAA buffers, and deferred G-buffers.',
        example   => 'depthDesc.storageMode = MTLStorageModeMemoryless;',
    },
    'MTLLoadActionDontCare' => {
        symbol    => 'MTLLoadActionDontCare',
        category  => 'tbdr_api',
        kind      => 'constant',
        signature => 'attachment.loadAction = MTLLoadActionDontCare',
        summary   => 'Skips loading previous attachment contents from DRAM into Apple Silicon TBDR tile memory at pass start.',
        details   => 'Use whenever a fullscreen pass overwrites every pixel; eliminates an entire framebuffer DRAM read pass.',
        example   => 'pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;',
    },
    'MTLStoreActionDontCare' => {
        symbol    => 'MTLStoreActionDontCare',
        category  => 'tbdr_api',
        kind      => 'constant',
        signature => 'attachment.storeAction = MTLStoreActionDontCare',
        summary   => 'Discards TBDR tile contents at pass end without flushing them to DRAM.',
        details   => 'Essential for transient depth, stencil, and MSAA attachments; pair with MTLStorageModeMemoryless.',
        example   => 'pass.depthAttachment.storeAction = MTLStoreActionDontCare;',
    },
    'dispatchThreads' => {
        symbol    => 'dispatchThreads',
        category  => 'tbdr_api',
        kind      => 'method',
        signature => '[encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerTG]',
        summary   => 'Hardware-native non-uniform compute dispatch (Apple4+ / all Apple Silicon M1-M4) supporting arbitrary grid sizes.',
        details   => 'Unlike dispatchThreadgroups, you pass the exact element count in threadsPerGrid without manually rounding up; Metal hardware handles partial edge threadgroups cleanly.',
        example   => '[enc dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];',
    },
    'dispatchThreadgroups' => {
        symbol    => 'dispatchThreadgroups',
        category  => 'tbdr_api',
        kind      => 'method',
        signature => '[encoder dispatchThreadgroups:threadgroupsPerGrid threadsPerThreadgroup:threadsPerTG]',
        summary   => 'Uniform compute dispatch launching an integer grid of full threadgroups.',
        details   => 'Requires explicit bounds guards inside the kernel (`if (gid.x >= width) return;`) when problem size is not divisible by threadsPerThreadgroup.',
        example   => '[enc dispatchThreadgroups:MTLSizeMake((N+255)/256, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];',
    },
);

sub meta {
    return {
        name             => 'metal',
        label            => 'Apple Metal 3.x / MSL / Apple Silicon',
        category         => 'gpu',
        version          => $VERSION,
        description      => 'Apple Silicon Metal 3.x architecture database (Apple7 M1, Apple8 M2, Apple9 M3/M4 with Dynamic Caching), SIMD-group & TBDR occupancy/dispatch calculator, MSL/Metal API reference, and packed_float3 ABI / half ALU / TBDR shader auditor.',
        filetypes        => [qw(metal msl)],
        upstream_credits => [
            'Apple Metal Shading Language (MSL) Specification 3.x',
            'Apple Metal Feature Set Tables (MTLGPUFamilyApple7-9)',
            'metal-mcp (community inspiration)',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'metal_arch_spec',
            description => 'Return Apple Silicon GPU specs (apple7 M1, apple8 M2, apple9 M3/M4): 32-thread SIMD-group, 32 KiB threadgroup memory, TBDR tile memory & Dynamic Caching (Apple9), 2x half ALU throughput, simdgroup_matrix 8x8, UMA storage modes, and 16B float3 alignment.',
            inputSchema => {
                type       => 'object',
                properties => {
                    arch => {
                        type        => 'string',
                        description => 'Target Apple GPU family (apple7, apple8, apple9, aliases m1/m2/m3/m4, or "all").',
                    },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_arch_spec($args || {});
            },
        },
        {
            name        => 'metal_occupancy_calc',
            description => 'Calculate Apple Silicon SIMD-groups per threadgroup, 16B-aligned threadgroup memory footprint, bank alignment, Dynamic Caching occupancy heuristics, and dispatchThreads (non-uniform Apple4+) vs dispatchThreadgroups sizing.',
            inputSchema => {
                type       => 'object',
                properties => {
                    arch                    => { type => 'string',  description => 'Target Apple family (apple7, apple8, apple9, m1..m4). Default: apple9.' },
                    threads_per_threadgroup => { type => 'integer', description => 'Threads per threadgroup (integer or [tx,ty,tz], default: 256).' },
                    threadgroup_mem_bytes   => { type => 'integer', description => 'Threadgroup SRAM bytes per threadgroup (max 32768, default: 0).' },
                    grid_size               => { type => 'array',   description => 'Optional dispatch problem grid [gx, gy, gz] or integer for dispatchThreads vs dispatchThreadgroups sizing.' },
                    est_regs_per_thread     => { type => 'integer', description => 'Optional estimated 32-bit registers per thread (default: 48).' },
                    uses_half               => { type => 'boolean', description => 'Whether inner math uses half (FP16) for 2x ALU and lower register footprint.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_occupancy_calc($args || {});
            },
        },
        {
            name        => 'metal_msl_lookup',
            description => 'Look up Apple Metal 3.x & MSL reference entries: address spaces (device/constant/threadgroup/thread), attributes, simd_* collectives, simdgroup_float8x8/simdgroup_multiply_accumulate, threadgroup_barrier, packed_float3 ABI, and TBDR load/store/memoryless rules.',
            inputSchema => {
                type       => 'object',
                properties => {
                    query    => { type => 'string', description => 'MSL keyword, attribute, intrinsic, or Metal API to search.' },
                    category => { type => 'string', description => 'Optional filter: address_space, attributes, simd, matrix, sync, types, tbdr_api, or all.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_msl_lookup($args || {});
            },
        },
        {
            name        => 'metal_shader_audit',
            description => 'Audit .metal MSL shaders (and Metal render-pass setup) for the float3 ABI mismatch (16B float3 vs 12B packed_float3), half vs float 2x ALU opportunities, missing threadgroup_barrier, divergent simd_*/barrier calls, TBDR StoreActionStore bandwidth waste, plus live xcrun metal when Xcode toolchain is installed.',
            inputSchema => {
                type       => 'object',
                properties => {
                    source       => { type => 'string',  description => 'Metal Shading Language (.metal) or Metal host setup source.' },
                    arch         => { type => 'string',  description => 'Target Apple GPU family (default: apple9).' },
                    run_compiler => { type => 'boolean', description => 'Invoke xcrun metal if Xcode Metal compiler is installed (default: true).' },
                },
                required => ['source'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_shader_audit($args || {});
            },
        },
    ];
}

sub _normalize_arch {
    my ($raw) = @_;
    return 'apple9' unless defined $raw && length $raw;
    my $k = lc($raw);
    $k =~ s/[\s\-]+/_/g;
    $k =~ s/^mtlgpufamily//;
    return $ARCH_ALIASES{$k};
}

sub _parse_dims {
    my ($v, $default_arr) = @_;
    return $default_arr unless defined $v;
    if (ref($v) eq 'ARRAY') {
        my @d = map { my $n = int($_ || 1); $n < 1 ? 1 : $n } @$v;
        push @d, 1 while @d < 3;
        return [ @d[0..2] ];
    }
    my $n = int($v || 0);
    return $n > 0 ? [ $n, 1, 1 ] : $default_arr;
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
            error     => "Unknown Apple Metal GPU family '$raw'. Supported: " . join(', ', @ARCH_ORDER),
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
    my $arch_key = _normalize_arch($args->{arch} // 'apple9');
    if (!$arch_key || !$ARCH_SPECS{$arch_key}) {
        return {
            ok        => 0,
            error     => "Unknown Apple Metal GPU family '" . ($args->{arch} // '') . "'",
            supported => \@ARCH_ORDER,
        };
    }
    my $spec = $ARCH_SPECS{$arch_key};

    my $tg_raw  = $args->{threads_per_threadgroup} // $args->{threadgroup_size} // $args->{workgroup_size} // 256;
    my $tg_dims = _parse_dims($tg_raw, [ 256, 1, 1 ]);
    my $tg_size = $tg_dims->[0] * $tg_dims->[1] * $tg_dims->[2];

    my $tg_mem = int($args->{threadgroup_mem_bytes} // 0);
    $tg_mem = 0 if $tg_mem < 0;

    my $regs = int($args->{est_regs_per_thread} // 48);
    $regs = 8 if $regs < 8;
    my $uses_half = $args->{uses_half} ? 1 : 0;
    my $eff_regs  = $uses_half ? int(ceil($regs * 0.6)) : $regs;

    my (@warnings, @advice);

    my $simd_w            = $spec->{simd_width}; # 32
    my $simdgroups_per_tg = ceil($tg_size / $simd_w);
    my $inactive_lanes    = ($simdgroups_per_tg * $simd_w) - $tg_size;
    my $simd_eff_pct      = sprintf('%.1f', 100.0 * $tg_size / ($simdgroups_per_tg * $simd_w)) + 0;

    if ($tg_size > $spec->{max_threads_per_threadgroup}) {
        push @warnings, "Threadgroup size $tg_size exceeds Apple Silicon maximum ($spec->{max_threads_per_threadgroup}).";
    }
    if ($inactive_lanes > 0) {
        push @warnings, "Threadgroup size $tg_size is not a multiple of 32 (SIMD-group width); $inactive_lanes lanes wasted in the final SIMD-group ($simd_eff_pct% lane efficiency).";
        push @advice, "Round threads_per_threadgroup to a multiple of 32 (e.g. " . ($simdgroups_per_tg * 32) . ").";
    }

    my $tg_mem_aligned = $tg_mem > 0 ? (ceil($tg_mem / 16) * 16) : 0;
    if ($tg_mem != $tg_mem_aligned) {
        push @advice, "Metal setThreadgroupMemoryLength:atIndex: requires 16-byte alignment ($tg_mem B rounds up to $tg_mem_aligned B).";
    }

    my $max_sgs = $spec->{max_simdgroups_per_core_est};
    my $sgs_by_tg_mem = $max_sgs;
    if ($tg_mem_aligned > $spec->{threadgroup_mem_bytes}) {
        $sgs_by_tg_mem = 0;
        push @warnings, "Threadgroup memory ($tg_mem_aligned B) exceeds 32 KiB (32768 B) Metal per-threadgroup hardware limit.";
        push @advice, "Shrink threadgroup memory to <= 32768 B (ideally <= 16384 B so multiple threadgroups overlap concurrently per GPU core).";
    }
    elsif ($tg_mem_aligned > 0) {
        my $tgs_fit = int($spec->{core_tg_sram_pool_bytes} / $tg_mem_aligned);
        $sgs_by_tg_mem = $tgs_fit * $simdgroups_per_tg;
        $sgs_by_tg_mem = $max_sgs if $sgs_by_tg_mem > $max_sgs;
    }

    # Register occupancy heuristic (Apple9 Dynamic Caching avoids coarse register-tier cliffs)
    my $sgs_by_regs;
    if ($spec->{dynamic_caching}) {
        # Dynamic Caching allocates exact SRAM proportional to live registers (~3072 reg-slots/core heuristic)
        $sgs_by_regs = int(3072 / $eff_regs);
        $sgs_by_regs = $max_sgs if $sgs_by_regs > $max_sgs;
    }
    else {
        # Static register bucket tiers on Apple7/Apple8
        my $bucket = ($eff_regs <= 32) ? 32 : ($eff_regs <= 64) ? 64 : ($eff_regs <= 96) ? 96 : 128;
        $sgs_by_regs = int(2048 / $bucket);
        $sgs_by_regs = $max_sgs if $sgs_by_regs > $max_sgs;
    }

    my $active_sgs = $sgs_by_regs < $sgs_by_tg_mem ? $sgs_by_regs : $sgs_by_tg_mem;
    # Quantize to whole threadgroups per core
    my $active_tgs = $simdgroups_per_tg > 0 ? int($active_sgs / $simdgroups_per_tg) : 0;
    $active_sgs    = $active_tgs * $simdgroups_per_tg;
    my $occ_pct    = sprintf('%.1f', 100.0 * $active_sgs / $max_sgs) + 0;

    my $limiting = 'OPTIMAL';
    if ($tg_mem_aligned > $spec->{threadgroup_mem_bytes}) {
        $limiting = 'THREADGROUP_MEMORY_OVERFLOW';
    }
    elsif ($sgs_by_tg_mem < $sgs_by_regs && $active_sgs < $max_sgs) {
        $limiting = 'THREADGROUP_MEMORY';
        push @advice, "Threadgroup memory ($tg_mem_aligned B) constrains concurrent threadgroups/core to $active_tgs; halve tile size or switch tile elements to half (FP16) to double concurrency.";
    }
    elsif ($sgs_by_regs < $max_sgs) {
        $limiting = 'REGISTER_PRESSURE';
        push @advice, $uses_half
            ? "Estimated register pressure (~$eff_regs regs/thread) limits heuristic occupancy to $occ_pct%; reduce live register accumulators or loop unrolling."
            : "Estimated register pressure ($regs FP32 regs/thread) limits heuristic occupancy to $occ_pct%; converting eligible math to half (FP16) delivers 2x ALU throughput and slashes register pressure.";
    }
    elsif ($inactive_lanes > 0) {
        $limiting = 'SIMD_UNDERFILL';
    }

    if ($spec->{dynamic_caching}) {
        push @advice, "Apple9 Dynamic Caching dynamically shares on-chip SRAM between registers, threadgroup memory, and L1 — keeping threadgroup_mem_bytes lean boosts L1/register capacity automatically.";
    }

    # Optional dispatchThreads vs dispatchThreadgroups sizing
    my $dispatch;
    if (defined $args->{grid_size}) {
        my $g = _parse_dims($args->{grid_size}, [ $tg_size, 1, 1 ]);
        my @tgs_grid = (
            ceil($g->[0] / $tg_dims->[0]),
            ceil($g->[1] / $tg_dims->[1]),
            ceil($g->[2] / $tg_dims->[2]),
        );
        my $uniform_threads = ($tgs_grid[0] * $tg_dims->[0]) * ($tgs_grid[1] * $tg_dims->[1]) * ($tgs_grid[2] * $tg_dims->[2]);
        my $exact_threads   = $g->[0] * $g->[1] * $g->[2];
        my $non_uniform     = ($uniform_threads != $exact_threads) ? 1 : 0;

        $dispatch = {
            grid_size           => $g,
            threads_per_tg      => $tg_dims,
            recommended_api     => 'dispatchThreads:threadsPerThreadgroup:',
            dispatchThreads     => {
                threadsPerGrid        => $g,
                threadsPerThreadgroup => $tg_dims,
                hardware_native       => 1,
                note                  => 'Apple4+ (all Apple Silicon M1-M4) natively supports non-uniform threadgroups; no manual grid rounding needed.',
            },
            dispatchThreadgroups => {
                threadgroupsPerGrid   => \@tgs_grid,
                threadsPerThreadgroup => $tg_dims,
                launched_threads      => $uniform_threads,
                overshoot_threads     => $uniform_threads - $exact_threads,
                requires_bounds_check => $non_uniform,
            },
        };
    }

    return {
        ok                            => 1,
        arch                          => $arch_key,
        gpu_family                    => $spec->{gpu_family},
        dynamic_caching               => $spec->{dynamic_caching},
        simd_width                    => $simd_w,
        threads_per_threadgroup       => $tg_size,
        threadgroup_dims              => $tg_dims,
        simdgroups_per_threadgroup    => $simdgroups_per_tg,
        inactive_simd_lanes           => $inactive_lanes,
        simd_lane_efficiency_pct      => $simd_eff_pct,
        threadgroup_mem_requested     => $tg_mem,
        threadgroup_mem_aligned       => $tg_mem_aligned,
        threadgroup_mem_limit_bytes   => $spec->{threadgroup_mem_bytes},
        threadgroup_mem_banks         => $spec->{threadgroup_mem_banks},
        bank_alignment_bytes          => 16,
        est_regs_per_thread           => $regs,
        effective_regs_after_fp16     => $eff_regs,
        active_threadgroups_per_core  => $active_tgs,
        active_simdgroups_per_core    => $active_sgs,
        max_simdgroups_per_core_est   => $max_sgs,
        estimated_occupancy_pct       => $occ_pct,
        limiting_factor               => $limiting,
        (defined $dispatch ? (dispatch_sizing => $dispatch) : ()),
        warnings                      => \@warnings,
        tuning_advice                 => \@advice,
    };
}

sub tool_msl_lookup {
    my ($self, $args) = @_;
    my $q   = $args->{query} // '';
    my $cat = lc($args->{category} // 'all');
    $q =~ s/^\s+|\s+$//g;

    my @pool = sort keys %MSL_DB;
    if ($cat ne 'all' && length $cat) {
        @pool = grep { $MSL_DB{$_}{category} eq $cat } @pool;
    }

    if (!length $q) {
        return {
            ok       => 1,
            category => $cat,
            count    => scalar(@pool),
            entries  => [ map { $MSL_DB{$_} } @pool ],
        };
    }

    my $ql = lc($q);
    my (@exact, @prefix, @substr);
    for my $k (@pool) {
        my $e  = $MSL_DB{$k};
        my $kl = lc($k);
        (my $bare = $kl) =~ s/^\[+|\]+$//g;
        $bare =~ s/\(.*\)$//;
        if ($kl eq $ql || $bare eq $ql || lc($e->{symbol}) eq $ql) {
            push @exact, $e;
        }
        elsif (index($kl, $ql) == 0 || index($bare, $ql) == 0) {
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

sub _run_xcrun_metal_check {
    my ($source) = @_;
    return {
        tool      => 'xcrun metal',
        available => 0,
        note      => 'xcrun metal is only available on macOS with full Xcode Metal toolchain installed.',
    } unless $^O eq 'darwin' && -x '/usr/bin/xcrun';

    # Silently verify Metal compiler exists (Command Line Tools alone lacks `metal`)
    my ($fw, $fr, $fe) = (undef, undef, gensym);
    my $fpid = eval { open3($fw, $fr, $fe, '/usr/bin/xcrun', '--find', 'metal') };
    return { tool => 'xcrun metal', available => 0, note => 'Could not probe xcrun.' } unless $fpid;
    close $fw;
    my $metal_path = do { local $/; <$fr> } // '';
    my $find_err   = do { local $/; <$fe> } // '';
    close $fr;
    close $fe;
    waitpid($fpid, 0);
    my $frc = $? >> 8;
    $metal_path =~ s/^\s+|\s+$//g;

    if ($frc != 0 || !length($metal_path) || !-x $metal_path) {
        return {
            tool      => 'xcrun metal',
            available => 0,
            note      => 'Xcode Metal shader compiler not installed (xcrun --find metal unavailable); returning static MSL audit only.',
        };
    }

    my ($fh, $src_path) = File::Temp::tempfile('npl_metal_XXXXXX', SUFFIX => '.metal', UNLINK => 1);
    print {$fh} $source;
    close $fh;
    my $air_path = "${src_path}.air";

    my ($wtr, $rdr, $err) = (undef, undef, gensym);
    my $pid = eval { open3($wtr, $rdr, $err, '/usr/bin/xcrun', '-sdk', 'macosx', 'metal', '-c', $src_path, '-o', $air_path) };
    return { tool => 'xcrun metal', available => 1, executed => 0, error => "Failed to launch xcrun metal: $@" } unless $pid;
    close $wtr;
    my $stdout = do { local $/; <$rdr> } // '';
    my $stderr = do { local $/; <$err> } // '';
    close $rdr;
    close $err;
    waitpid($pid, 0);
    my $rc = $? >> 8;
    unlink $air_path if -e $air_path;

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
                code     => 'METAL_COMPILER',
                message  => $4,
            };
        }
    }

    return {
        tool        => 'xcrun metal',
        path        => $metal_path,
        available   => 1,
        executed    => 1,
        exit_code   => $rc,
        diagnostics => \@diags,
    };
}

sub tool_shader_audit {
    my ($self, $args) = @_;
    my $src = $args->{source} // $args->{code};
    return { ok => 0, error => 'Missing required parameter: source' }
        unless defined $src && length $src;

    my $arch_key = _normalize_arch($args->{arch} // 'apple9') || 'apple9';
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
            code       => $f{code}     || 'METAL_AUDIT',
            message    => $f{message}  || '',
            suggestion => $f{suggestion} // '',
        };
    };

    my $in_struct          = 0;
    my $struct_depth       = 0;
    my $brace_depth        = 0;
    my @divergent_blks;
    my $pending_div_if     = 0;

    my $uses_tg_mem        = 0;
    my $first_tg_line      = 0;
    my $has_tg_barrier     = 0;
    my $float_alu_count    = 0;
    my $uses_half          = ($src =~ /\b(?:half[234]?|packed_half[234]|simdgroup_half8x8)\b/) ? 1 : 0;
    my $is_msl_shader      = ($src =~ /\b(?:kernel|vertex|fragment)\b/) ? 1 : 0;

    for (my $i = 0; $i < @lines; $i++) {
        my $raw = $lines[$i];
        (my $code = $raw) =~ s{//.*$}{};
        next if $code =~ /^\s*$/;

        # Track struct blocks for the Metal float3 ABI mismatch (float3 = 16B)
        if ($code =~ /\bstruct\s+[A-Za-z_]\w*/) {
            $in_struct    = 1;
            $struct_depth = $brace_depth + 1;
        }

        # 1. Metal ABI check: float3 / int3 / uint3 / half3 inside buffer structs or device/constant pointers
        if (($in_struct || $code =~ /\b(?:device|constant)\s+(?:const\s+)?(?:float3|int3|uint3|half3)\b/)
            && $code =~ /\b(float3|int3|uint3|half3)\b/
            && $code !~ /\bpacked_(?:float3|int3|uint3|half3)\b/
            && $code !~ /\[\[attribute\s*\(/
            && $code !~ /\[\[stage_in\]\]/)
        {
            my $ty = $1;
            my $c  = index($raw, $ty);
            my $msl_sz = ($ty eq 'half3') ? 8 : 16;
            my $c_sz   = ($ty eq 'half3') ? 6 : 12;
            my $packed = "packed_$ty";
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + length($ty) : 1),
                severity   => 'error',
                code       => 'METAL_FLOAT3_ABI_TRAP',
                message    => "Metal ABI mismatch: '$ty' is $msl_sz bytes ($msl_sz-byte aligned) in MSL vs $c_sz bytes in C/C++ arrays, causing stride/offset corruption across CPU/GPU buffers.",
                suggestion => "Replace '$ty' in buffer structs with '$packed' ($c_sz B, natural scalar alignment) and convert to '$ty' in registers, OR pad C/ObjC host structs explicitly to $msl_sz B (simd_$ty).",
            );
        }

        # 2. Threadgroup memory usage & missing barrier
        if ($code =~ /\bthreadgroup\b/ && $code !~ /\bthreadgroup_barrier\b/) {
            $first_tg_line = $i unless $uses_tg_mem;
            $uses_tg_mem   = 1;
            if ($code =~ /\[\s*(?:32|64)\s*\]\s*\[\s*(32|64)\s*\]/) {
                my $dim = $1;
                $add_finding->(
                    line       => $i,
                    col        => 0,
                    end_col    => length($raw),
                    severity   => 'warn',
                    code       => 'METAL_TG_BANK_CONFLICT',
                    message    => "2D threadgroup array inner stride $dim matches Apple Silicon's 32-bank x 4B threadgroup SRAM.",
                    suggestion => 'Pad inner dimension by +1 (e.g., [' . ($dim + 1) . ']) to eliminate bank conflicts on transpose reads.',
                );
            }
        }

        # 3. Barriers inside divergent branches
        if ($code =~ /\b(threadgroup_barrier|simdgroup_barrier)\s*\(/) {
            my $tok = $1;
            $has_tg_barrier = 1 if $tok eq 'threadgroup_barrier';
            if (@divergent_blks || $pending_div_if) {
                my $c = index($raw, $tok);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($tok) : 1),
                    severity   => 'error',
                    code       => 'METAL_BARRIER_DIVERGENT',
                    message    => "$tok() inside thread-divergent branch deadlocks Apple Silicon SIMD-groups.",
                    suggestion => 'Hoist threadgroup_barrier(mem_flags::mem_threadgroup) outside thread-dependent conditionals.',
                );
            }
        }

        # 4. Divergent simd_* / simdgroup_* calls
        if ($code =~ /\b(simd_(?:sum|min|max|shuffle(?:_xor|_down|_up)?|broadcast(?:_first)?|prefix_\w+|ballot)|simdgroup_(?:multiply_accumulate|multiply|load|store))\s*\(/) {
            if (@divergent_blks || $pending_div_if) {
                my $tok = $1;
                my $c   = index($raw, $tok);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($tok) : 1),
                    severity   => 'error',
                    code       => 'METAL_SIMD_DIVERGENT',
                    message    => "SIMD-group collective/matrix op '$tok()' called inside divergent control flow; inactive lanes yield undefined values.",
                    suggestion => 'Execute simd_* / simdgroup_* uniformly across all 32 lanes and mask/predicate only the final store.',
                );
            }
        }

        # 5. TBDR StoreActionStore / Shared bandwidth waste (in ObjC/Swift/C++ Metal host code or comments/snippets)
        if ($code =~ /\b(?:depthAttachment|stencilAttachment|multisample|msaa)\b[^\n;]*\bMTLStoreActionStore\b/i
            || ($code =~ /\bstoreAction\s*=\s*MTLStoreActionStore\b/ && $src =~ /\b(?:depthAttachment|stencilAttachment|msaa|sampleCount\s*=\s*[248])\b/i))
        {
            my $c = index($raw, 'MTLStoreActionStore');
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + 19 : 1),
                severity   => 'warn',
                code       => 'METAL_TBDR_STORE_WASTE',
                message    => 'MTLStoreActionStore on depth/stencil or MSAA attachment flushes transient TBDR tile memory to DRAM every frame.',
                suggestion => 'Use MTLStoreActionDontCare (for depth/stencil) or MTLStoreActionMultisampleResolve (for MSAA color) paired with MTLStorageModeMemoryless.',
            );
        }
        if ($code =~ /\bMTLStorageModeShared\b/ && $code =~ /\b(?:depth|stencil|msaa|gbuffer|transient)\w*\b/i) {
            my $c = index($raw, 'MTLStorageModeShared');
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + 20 : 1),
                severity   => 'warn',
                code       => 'METAL_TBDR_MEMORYLESS_OPPORTUNITY',
                message    => 'Transient depth/MSAA/G-buffer render target uses MTLStorageModeShared instead of MTLStorageModeMemoryless (or Private).',
                suggestion => 'Use MTLStorageModeMemoryless for single-pass transient attachments to keep them 100% inside Apple Silicon on-chip TBDR tile SRAM.',
            );
        }

        # 6. device const small uniform -> constant address space hint
        if ($code =~ /\bdevice\s+const\s+([A-Za-z_]\w*)\s*&\s*\w+\s*\[\[buffer\s*\(\d+\)\]\]/) {
            my $utype = $1;
            my $c     = index($raw, 'device');
            $add_finding->(
                line       => $i,
                col        => ($c >= 0 ? $c : 0),
                end_col    => ($c >= 0 ? $c + 6 : 1),
                severity   => 'hint',
                code       => 'METAL_USE_CONSTANT_SPACE',
                message    => "Read-only uniform reference 'device const $utype&' bypasses Apple Silicon's dedicated constant cache.",
                suggestion => "Change 'device const $utype&' to 'constant $utype&' for hardware constant preloading.",
            );
        }

        # Track FP32 ALU usage for 2x half recommendation
        if ($code =~ /\b(?:float|float2|float3|float4)\b/ && $code =~ /\b(?:normalize|dot|cross|mix|clamp|saturate|fma|sin|cos|exp|pow|sqrt)\b|\*|\+/) {
            $float_alu_count++;
        }

        # Track divergent if blocks & braces
        my $is_div = 0;
        if ($code =~ /\bif\s*\(([^)]+)\)/) {
            my $cond = $1;
            if ($cond =~ /\b(?:gid|tid|lid|lane|simd_lane|thread_pos|index|id)\b/) {
                $is_div = 1;
            }
        }
        my $opens  = () = $code =~ /\{/g;
        my $closes = () = $code =~ /\}/g;

        if ($is_div) {
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
        if ($in_struct && $brace_depth < $struct_depth && $closes > 0) {
            $in_struct = 0;
        }
        while (@divergent_blks && $brace_depth < $divergent_blks[-1]) {
            pop @divergent_blks;
        }
    }

    if ($uses_tg_mem && !$has_tg_barrier) {
        $add_finding->(
            line       => $first_tg_line,
            col        => 0,
            end_col    => 1,
            severity   => 'warn',
            code       => 'METAL_MISSING_TG_BARRIER',
            message    => 'threadgroup shared memory is used without any threadgroup_barrier(mem_flags::mem_threadgroup).',
            suggestion => 'Insert threadgroup_barrier(mem_flags::mem_threadgroup) between threadgroup writes and cross-thread reads.',
        );
    }

    if ($is_msl_shader && !$uses_half && $float_alu_count >= 2) {
        $add_finding->(
            line       => 0,
            col        => 0,
            end_col    => 1,
            severity   => 'info',
            code       => 'METAL_HALF_ALU_OPPORTUNITY',
            message    => "Shader executes FP32-only math ($float_alu_count float ALU lines) with no half (FP16) types; Apple Silicon GPUs provide 2x ALU throughput and lower register pressure with half/half4.",
            suggestion => 'Use half/half4 for lighting, colors, normals, and activations where 16-bit precision suffices.',
        );
    }

    my $ext_compiler = {
        tool      => 'xcrun metal',
        available => 0,
        skipped   => 1,
    };
    if ($run_comp && $is_msl_shader) {
        $ext_compiler = _run_xcrun_metal_check($src);
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

    my @cands = ($word, "[[$word]]", "[[$word(n)]]");
    for my $c (@cands) {
        if (my $e = $MSL_DB{$c}) {
            my $md = "### `$e->{symbol}` (*Apple Metal / " . uc($e->{category}) . "*)\n\n"
                   . "```cpp\n$e->{signature}\n```\n\n"
                   . "$e->{summary}\n\n"
                   . "$e->{details}\n\n"
                   . "**Example:**\n```cpp\n$e->{example}\n```";
            return { contents => $md, kind => 'markdown', title => $e->{symbol} };
        }
    }

    my $wl = lc($word);
    for my $k (sort keys %MSL_DB) {
        (my $bare = lc($k)) =~ s/^\[+|\]+$//g;
        $bare =~ s/\(.*\)$//;
        if (lc($k) eq $wl || $bare eq $wl) {
            my $e = $MSL_DB{$k};
            my $md = "### `$e->{symbol}` (*Apple Metal / " . uc($e->{category}) . "*)\n\n"
                   . "```cpp\n$e->{signature}\n```\n\n$e->{summary}\n\n$e->{details}";
            return { contents => $md, kind => 'markdown', title => $e->{symbol} };
        }
    }

    if (my $ak = _normalize_arch($word)) {
        if (my $s = $ARCH_SPECS{$ak}) {
            my $md = "### $s->{label} (`$s->{gpu_family}`)\n\n"
                   . "- **SIMD-group width:** $s->{simd_width} threads\n"
                   . "- **Threadgroup memory:** $s->{threadgroup_mem_kib} KiB (16B aligned)\n"
                   . "- **Dynamic Caching:** " . ($s->{dynamic_caching} ? 'Yes (unified on-chip SRAM)' : 'No (static partition)') . "\n"
                   . "- **FP16 ALU:** $s->{half_alu_note}\n"
                   . "- **Matrix:** `simdgroup_matrix` $s->{simdgroup_matrix_shape} (" . join('/', @{ $s->{simdgroup_matrix_types} }) . ")\n";
            return { contents => $md, kind => 'markdown', title => $s->{label} };
        }
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $p = lc($prefix // '');
    my @items;
    for my $k (sort keys %MSL_DB) {
        my $e = $MSL_DB{$k};
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
    my $res = $self->tool_shader_audit({
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
        if ($l =~ /\b(kernel|vertex|fragment)\b\s+[A-Za-z_][\w:<>\s\*]*\b([A-Za-z_]\w*)\s*\(/) {
            push @syms, $self->make_symbol(
                name   => $2,
                kind   => 'function',
                line   => $i,
                col    => index($l, $2),
                detail => "Metal $1 entry point",
            );
        }
        elsif ($l =~ /\bstruct\s+([A-Za-z_]\w*)/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'struct',
                line   => $i,
                col    => index($l, $1),
                detail => 'MSL struct',
            );
        }
        elsif ($l =~ /^\s*(?:static\s+|inline\s+)*(?:void|float\d*|half\d*|int\d*|uint\d*|bool)\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:\{|$)/) {
            my $name = $1;
            next if $name =~ /^(?:if|for|while|switch)$/;
            push @syms, $self->make_symbol(
                name   => $name,
                kind   => 'function',
                line   => $i,
                col    => index($l, $name),
                detail => 'MSL helper function',
            );
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::MetalDev - Apple Metal 3.x, MSL, and Apple Silicon GPU MCP pack

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::MetalDev;

    my $pack = NeoPerl::MCP::Pack::MetalDev->new();
    my $spec = $pack->call_tool('metal_arch_spec', { arch => 'apple9' });
    my $occ  = $pack->call_tool('metal_occupancy_calc', {
        arch                    => 'apple9',
        threads_per_threadgroup => [ 16, 16, 1 ],
        threadgroup_mem_bytes   => 16384,
        grid_size               => [ 1920, 1080, 1 ],
        uses_half               => 1,
    });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::MetalDev> provides four MCP tools and matching LSP
knowledge hooks for Apple Metal 3.x and Metal Shading Language (MSL) on Apple
Silicon GPUs (Apple7 M1, Apple8 M2, Apple9 M3/M4), inspired by C<metal-mcp>:

=over 4

=item * C<metal_arch_spec> - Apple7-Apple9 architecture specs (32-thread SIMD-group, 32 KiB threadgroup memory, TBDR tile memory & Apple9 Dynamic Caching, 2x C<half> ALU throughput, 8x8 C<simdgroup_matrix>, UMA storage modes, and 16B C<float3> alignment).

=item * C<metal_occupancy_calc> - SIMD-groups per threadgroup, 16B-aligned threadgroup SRAM, occupancy heuristics, and C<dispatchThreads> vs C<dispatchThreadgroups> sizing.

=item * C<metal_msl_lookup> - MSL 3.x address spaces, attributes, C<simd_*> collectives, C<simdgroup_matrix>, C<packed_float3> ABI rules, and C<MTLRenderPassDescriptor> TBDR actions.

=item * C<metal_shader_audit> - Static MSL & Metal host auditor catching 16B C<float3> vs 12B C<packed_float3> ABI traps, 2x C<half> ALU opportunities, missing C<threadgroup_barrier>, divergent C<simd_*> calls, TBDR C<MTLStoreActionStore> bandwidth waste, plus live C<xcrun metal> when Xcode's Metal compiler is installed.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
