package NeoPerl::MCP::Pack::VulkanDev;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

use File::Spec ();
use File::Temp ();
use IPC::Open3 qw(open3);
use POSIX qw(ceil);
use Symbol qw(gensym);

our $VERSION = '0.01';

# --- GLSL / Vulkan Scalar & Vector Type Primitives ---
my %SCALAR_TYPES = (
    bool      => { size => 4, align => 4, c_type => 'uint32_t' },
    int       => { size => 4, align => 4, c_type => 'int32_t'  },
    int32_t   => { size => 4, align => 4, c_type => 'int32_t'  },
    uint      => { size => 4, align => 4, c_type => 'uint32_t' },
    uint32_t  => { size => 4, align => 4, c_type => 'uint32_t' },
    float     => { size => 4, align => 4, c_type => 'float'    },
    float32_t => { size => 4, align => 4, c_type => 'float'    },
    double    => { size => 8, align => 8, c_type => 'double'   },
    float64_t => { size => 8, align => 8, c_type => 'double'   },
    int64_t   => { size => 8, align => 8, c_type => 'int64_t'  },
    uint64_t  => { size => 8, align => 8, c_type => 'uint64_t' },
    float16_t => { size => 2, align => 2, c_type => 'uint16_t' },
    int16_t   => { size => 2, align => 2, c_type => 'int16_t'  },
    uint16_t  => { size => 2, align => 2, c_type => 'uint16_t' },
    int8_t    => { size => 1, align => 1, c_type => 'int8_t'   },
    uint8_t   => { size => 1, align => 1, c_type => 'uint8_t'  },
);

my %VEC_PREFIX_SCALAR = (
    ''    => 'float',
    'f'   => 'float',
    'i'   => 'int',
    'u'   => 'uint',
    'b'   => 'bool',
    'd'   => 'double',
    'f16' => 'float16_t',
    'i16' => 'int16_t',
    'u16' => 'uint16_t',
    'i64' => 'int64_t',
    'u64' => 'uint64_t',
    'i8'  => 'int8_t',
    'u8'  => 'uint8_t',
);

# --- Vulkan Sync2 Stage <-> Access Compatibility Tables ---
my %WRITE_ACCESS = map { $_ => 1 } qw(
    SHADER_WRITE SHADER_STORAGE_WRITE
    COLOR_ATTACHMENT_WRITE DEPTH_STENCIL_ATTACHMENT_WRITE
    TRANSFER_WRITE HOST_WRITE MEMORY_WRITE
    ACCELERATION_STRUCTURE_WRITE COMMAND_PREPROCESS_WRITE
    TRANSFORM_FEEDBACK_WRITE TRANSFORM_FEEDBACK_COUNTER_WRITE
);

my %READ_ACCESS = map { $_ => 1 } qw(
    INDIRECT_COMMAND_READ INDEX_READ VERTEX_ATTRIBUTE_READ
    UNIFORM_READ INPUT_ATTACHMENT_READ
    SHADER_READ SHADER_SAMPLED_READ SHADER_STORAGE_READ
    COLOR_ATTACHMENT_READ DEPTH_STENCIL_ATTACHMENT_READ
    TRANSFER_READ HOST_READ MEMORY_READ
    ACCELERATION_STRUCTURE_READ COMMAND_PREPROCESS_READ
    FRAGMENT_SHADING_RATE_ATTACHMENT_READ
);

my @SHADER_STAGES = qw(
    VERTEX_SHADER TESSELLATION_CONTROL_SHADER TESSELLATION_EVALUATION_SHADER
    GEOMETRY_SHADER FRAGMENT_SHADER COMPUTE_SHADER
    TASK_SHADER MESH_SHADER RAY_TRACING_SHADER
    ALL_GRAPHICS ALL_COMMANDS
);

my %ACCESS_VALID_STAGES = (
    INDIRECT_COMMAND_READ           => [ qw(DRAW_INDIRECT ALL_GRAPHICS ALL_COMMANDS) ],
    INDEX_READ                      => [ qw(INDEX_INPUT VERTEX_INPUT ALL_GRAPHICS ALL_COMMANDS) ],
    VERTEX_ATTRIBUTE_READ           => [ qw(VERTEX_ATTRIBUTE_INPUT VERTEX_INPUT ALL_GRAPHICS ALL_COMMANDS) ],
    UNIFORM_READ                    => \@SHADER_STAGES,
    INPUT_ATTACHMENT_READ           => [ qw(FRAGMENT_SHADER ALL_GRAPHICS ALL_COMMANDS) ],
    SHADER_READ                     => \@SHADER_STAGES,
    SHADER_SAMPLED_READ             => \@SHADER_STAGES,
    SHADER_STORAGE_READ             => \@SHADER_STAGES,
    SHADER_WRITE                    => \@SHADER_STAGES,
    SHADER_STORAGE_WRITE            => \@SHADER_STAGES,
    COLOR_ATTACHMENT_READ           => [ qw(COLOR_ATTACHMENT_OUTPUT ALL_GRAPHICS ALL_COMMANDS) ],
    COLOR_ATTACHMENT_WRITE          => [ qw(COLOR_ATTACHMENT_OUTPUT ALL_GRAPHICS ALL_COMMANDS) ],
    DEPTH_STENCIL_ATTACHMENT_READ   => [ qw(EARLY_FRAGMENT_TESTS LATE_FRAGMENT_TESTS ALL_GRAPHICS ALL_COMMANDS) ],
    DEPTH_STENCIL_ATTACHMENT_WRITE  => [ qw(EARLY_FRAGMENT_TESTS LATE_FRAGMENT_TESTS ALL_GRAPHICS ALL_COMMANDS) ],
    TRANSFER_READ                   => [ qw(TRANSFER ALL_TRANSFER COPY BLIT RESOLVE CLEAR ALL_COMMANDS) ],
    TRANSFER_WRITE                  => [ qw(TRANSFER ALL_TRANSFER COPY BLIT RESOLVE CLEAR ALL_COMMANDS) ],
    HOST_READ                       => [ qw(HOST) ],
    HOST_WRITE                      => [ qw(HOST) ],
    MEMORY_READ                     => [ qw(ALL_COMMANDS ALL_GRAPHICS ALL_TRANSFER COMPUTE_SHADER FRAGMENT_SHADER VERTEX_SHADER TRANSFER COLOR_ATTACHMENT_OUTPUT EARLY_FRAGMENT_TESTS LATE_FRAGMENT_TESTS HOST) ],
    MEMORY_WRITE                    => [ qw(ALL_COMMANDS ALL_GRAPHICS ALL_TRANSFER COMPUTE_SHADER FRAGMENT_SHADER VERTEX_SHADER TRANSFER COLOR_ATTACHMENT_OUTPUT EARLY_FRAGMENT_TESTS LATE_FRAGMENT_TESTS HOST) ],
    ACCELERATION_STRUCTURE_READ     => [ qw(ACCELERATION_STRUCTURE_BUILD RAY_TRACING_SHADER COMPUTE_SHADER ALL_COMMANDS) ],
    ACCELERATION_STRUCTURE_WRITE    => [ qw(ACCELERATION_STRUCTURE_BUILD ALL_COMMANDS) ],
);

# --- Vulkan 1.0-1.4 / GLSL 450-460 / SPIR-V Lookup Database ---
my %VULKAN_DB = (
    'VK_KHR_synchronization2' => {
        symbol    => 'VK_KHR_synchronization2',
        category  => 'vulkan_ext',
        kind      => 'interface',
        version   => 'Core in Vulkan 1.3',
        signature => 'vkCmdPipelineBarrier2(cmd, const VkDependencyInfo* pDependencyInfo)',
        summary   => 'Replaces legacy 32-bit stage/access bitmasks with 64-bit VkPipelineStageFlags2 / VkAccessFlags2 and per-barrier stage scopes.',
        details   => 'Introduces VK_PIPELINE_STAGE_2_NONE, COPY/BLIT/CLEAR/RESOLVE sub-stages, SHADER_SAMPLED_READ vs SHADER_STORAGE_READ, and clean queue-submit2 semaphore synchronization.',
        example   => 'VkMemoryBarrier2 mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, .srcAccessMask = VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT, .dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT };',
    },
    'VK_KHR_dynamic_rendering' => {
        symbol    => 'VK_KHR_dynamic_rendering',
        category  => 'vulkan_ext',
        kind      => 'interface',
        version   => 'Core in Vulkan 1.3 (local_read in 1.4)',
        signature => 'vkCmdBeginRendering(cmd, const VkRenderingInfo* pRenderingInfo) ... vkCmdEndRendering(cmd)',
        summary   => 'Eliminates VkRenderPass and VkFramebuffer boilerplate by declaring color/depth/stencil attachments inline at draw time.',
        details   => 'Pipelines pass VkPipelineRenderingCreateInfo in pNext with renderPass = VK_NULL_HANDLE. Vulkan 1.4 promotes VK_KHR_dynamic_rendering_local_read for tile-local subpass reads.',
        example   => 'vkCmdBeginRendering(cmd, &renderInfo); vkCmdDraw(cmd, 3, 1, 0, 0); vkCmdEndRendering(cmd);',
    },
    'VK_KHR_buffer_device_address' => {
        symbol    => 'VK_KHR_buffer_device_address',
        category  => 'vulkan_ext',
        kind      => 'interface',
        version   => 'Core in Vulkan 1.2',
        signature => 'VkDeviceAddress vkGetBufferDeviceAddress(device, const VkBufferDeviceAddressInfo* pInfo)',
        summary   => 'Enables raw 64-bit GPU pointers (uint64_t) passed via push constants and dereferenced in GLSL with GL_EXT_buffer_reference.',
        details   => 'Requires VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT and VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT. Foundation for bindless rendering and ray tracing.',
        example   => 'layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer VertexBuf { vec4 pos[]; };',
    },
    'VK_KHR_shader_subgroup' => {
        symbol    => 'VK_KHR_shader_subgroup',
        category  => 'vulkan_ext',
        kind      => 'interface',
        version   => 'Core in Vulkan 1.1 (subgroupProperties)',
        signature => 'VkPhysicalDeviceSubgroupProperties { subgroupSize, supportedStages, supportedOperations }',
        summary   => 'Exposes hardware warp/wavefront/subgroup collective arithmetic, ballots, broadcasts, and shuffles in GLSL/SPIR-V.',
        details   => 'Enable #extension GL_KHR_shader_subgroup_arithmetic : require / GL_KHR_shader_subgroup_ballot : require. Vulkan 1.3 promotes VK_EXT_subgroup_size_control.',
        example   => 'float s = subgroupAdd(localVal); uvec4 mask = subgroupBallot(active);',
    },
    'VK_EXT_scalar_block_layout' => {
        symbol    => 'VK_EXT_scalar_block_layout',
        category  => 'vulkan_ext',
        kind      => 'interface',
        version   => 'Core in Vulkan 1.2',
        signature => 'layout(scalar, set = 0, binding = 0) buffer Data { vec3 positions[]; };',
        summary   => 'Allows C-compatible natural scalar alignment in UBO/SSBO/push-constant blocks (vec3 aligns to 4B, arrays have natural stride).',
        details   => 'Eliminates std140 vec3 16B padding and 16B scalar-array stride bloat when enabled via VkPhysicalDeviceVulkan12Features::scalarBlockLayout.',
        example   => '#extension GL_EXT_scalar_block_layout : require',
    },
    'VK_KHR_push_descriptor' => {
        symbol    => 'VK_KHR_push_descriptor',
        category  => 'vulkan_ext',
        kind      => 'interface',
        version   => 'Core in Vulkan 1.4',
        signature => 'vkCmdPushDescriptorSet(cmd, bindPoint, layout, set, writeCount, pDescriptorWrites)',
        summary   => 'Updates descriptor bindings inline in the command buffer without allocating VkDescriptorPool / VkDescriptorSet objects.',
        details   => 'Promoted to core in Vulkan 1.4 alongside maintenance5, maintenance6, and dynamic_rendering_local_read.',
        example   => 'vkCmdPushDescriptorSet(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeLayout, 0, 2, writes);',
    },
    'vkCmdPushConstants' => {
        symbol    => 'vkCmdPushConstants',
        category  => 'vulkan_api',
        kind      => 'function',
        signature => 'void vkCmdPushConstants(cmd, VkPipelineLayout layout, VkShaderStageFlags stageFlags, uint32_t offset, uint32_t size, const void* pValues)',
        summary   => 'Writes low-latency inline constant data directly into the command stream (minimum guaranteed maxPushConstantsSize = 128 bytes across Vulkan 1.0-1.4).',
        details   => 'offset and size must be multiples of 4. Keep push-constant structs <= 128 bytes for universal hardware portability; pass a 64-bit BDA pointer for larger payloads.',
        example   => 'vkCmdPushConstants(cmd, pipeLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushData), &pc);',
    },
    'subgroupAdd' => {
        symbol    => 'subgroupAdd',
        category  => 'glsl',
        kind      => 'function',
        signature => 'genType subgroupAdd(genType value)',
        summary   => 'GLSL GL_KHR_shader_subgroup_arithmetic reduction summing value across all active invocations in the subgroup.',
        details   => 'Lowers to SPIR-V OpGroupNonUniformFAdd / OpGroupNonUniformIAdd. Fast hardware register reduction without shared memory.',
        example   => 'float waveSum = subgroupAdd(val);',
    },
    'subgroupBallot' => {
        symbol    => 'subgroupBallot',
        category  => 'glsl',
        kind      => 'function',
        signature => 'uvec4 subgroupBallot(bool value)',
        summary   => 'GLSL GL_KHR_shader_subgroup_ballot returning a 128-bit bitmask (uvec4) of active lanes where value is true.',
        details   => 'Portable across wave32 (uses .x), wave64 (uses .xy), and hypothetical 128-wide subgroups. Use subgroupBallotBitCount(mask) to count set bits.',
        example   => 'uvec4 mask = subgroupBallot(cond); uint count = subgroupBallotBitCount(mask);',
    },
    'subgroupShuffleXor' => {
        symbol    => 'subgroupShuffleXor',
        category  => 'glsl',
        kind      => 'function',
        signature => 'genType subgroupShuffleXor(genType value, uint mask)',
        summary   => 'GLSL butterfly XOR exchange between gl_SubgroupInvocationID and (gl_SubgroupInvocationID ^ mask).',
        details   => 'Lowers to SPIR-V OpGroupNonUniformShuffleXor. Requires GL_KHR_shader_subgroup_shuffle.',
        example   => 'val += subgroupShuffleXor(val, 1u);',
    },
    'barrier' => {
        symbol    => 'barrier',
        category  => 'glsl',
        kind      => 'function',
        signature => 'void barrier()',
        summary   => 'GLSL compute / tessellation control execution barrier synchronizing all invocations in the workgroup.',
        details   => 'Pair with memoryBarrierShared() before barrier() if strict GLSL memory ordering is required; never place inside a non-uniform branch.',
        example   => 'sdata[gl_LocalInvocationIndex] = v; memoryBarrierShared(); barrier();',
    },
    'layout(std140)' => {
        symbol    => 'layout(std140)',
        category  => 'glsl',
        kind      => 'keyword',
        signature => 'layout(std140, set = S, binding = B) uniform BlockName { ... };',
        summary   => 'Standard GLSL/Vulkan uniform buffer layout with 16-byte vec3 alignment and 16-byte minimum array element stride.',
        details   => 'Note: vec3 aligns to 16 bytes (not 12), mat3 occupies 48 bytes (3x vec4), and scalar arrays float[N] pad each element to 16 bytes. Pack float after vec3, or use vec4 arrays / std430 SSBOs / scalar layout.',
        example   => 'layout(std140, set = 0, binding = 0) uniform CameraUBO { mat4 viewProj; vec3 eyePos; float exposure; };',
    },
    'layout(std430)' => {
        symbol    => 'layout(std430)',
        category  => 'glsl',
        kind      => 'keyword',
        signature => 'layout(std430, set = S, binding = B) buffer StorageName { ... };',
        summary   => 'Tighter SSBO and push-constant layout: scalar arrays have natural 4B stride, while vec3 still has 16B base alignment.',
        details   => 'Unlike std140, float[N] has 4B stride and struct/array base alignment is not forced up to 16B. However, vec3 still aligns to 16 bytes unless GL_EXT_scalar_block_layout is used.',
        example   => 'layout(std430, set = 0, binding = 1) readonly buffer Weights { float w[]; };',
    },
    'OpEntryPoint' => {
        symbol    => 'OpEntryPoint',
        category  => 'spirv',
        kind      => 'operator',
        signature => 'OpEntryPoint <ExecutionModel> %entry_fn "main" %interface_vars...',
        summary   => 'SPIR-V opcode declaring a shader entry point (Vertex, Fragment, GLCompute, TaskEXT, MeshEXT, RayGenerationKHR) and its module-scope interface variables.',
        details   => 'In SPIR-V 1.4+, OpEntryPoint must list ALL statically accessed module-scope variables (not just Input/Output).',
        example   => 'OpEntryPoint GLCompute %main "main" %gl_GlobalInvocationID',
    },
    'OpDecorate' => {
        symbol    => 'OpDecorate',
        category  => 'spirv',
        kind      => 'operator',
        signature => 'OpDecorate %target <Decoration> [literals...]',
        summary   => 'SPIR-V metadata decoration attaching DescriptorSet, Binding, Block, ArrayStride, BuiltIn, NonWritable, or RelaxedPrecision to an ID.',
        details   => 'Struct member offsets use OpMemberDecorate %StructType <memberIdx> Offset <byteOffset>.',
        example   => 'OpDecorate %ubo DescriptorSet 0 ; OpDecorate %ubo Binding 0',
    },
    'OpMatrixTimesVector' => {
        symbol    => 'OpMatrixTimesVector',
        category  => 'spirv',
        kind      => 'operator',
        signature => '%res = OpMatrixTimesVector %v4float %mat4_val %vec4_val',
        summary   => 'SPIR-V linear-algebra opcode multiplying a column-major matrix by a column vector.',
        details   => 'Result type must match the column vector type of the matrix operand. Companion opcodes: OpVectorTimesMatrix, OpMatrixTimesMatrix, OpDot.',
        example   => '%clip = OpMatrixTimesVector %v4float %mvp %world_pos',
    },
    'OpGroupNonUniformBallot' => {
        symbol    => 'OpGroupNonUniformBallot',
        category  => 'spirv',
        kind      => 'operator',
        signature => '%mask = OpGroupNonUniformBallot %v4uint %uint_3 %predicate',
        summary   => 'SPIR-V subgroup ballot opcode returning a uvec4 bitmask across Scope Subgroup (3).',
        details   => 'Requires OpCapability GroupNonUniformBallot. Part of the OpGroupNonUniform* family (FAdd, IAdd, Shuffle, ShuffleXor, Broadcast, Elect).',
        example   => '%ballot = OpGroupNonUniformBallot %v4uint %Subgroup %is_valid',
    },
    'OpGroupNonUniformFAdd' => {
        symbol    => 'OpGroupNonUniformFAdd',
        category  => 'spirv',
        kind      => 'operator',
        signature => '%sum = OpGroupNonUniformFAdd %float %uint_3 Reduce %val',
        summary   => 'SPIR-V subgroup floating-point arithmetic reduction (Reduce, InclusiveScan, ExclusiveScan, ClusteredReduce).',
        details   => 'Requires OpCapability GroupNonUniformArithmetic.',
        example   => '%sum = OpGroupNonUniformFAdd %float %Subgroup Reduce %lane_val',
    },
    'OpControlBarrier' => {
        symbol    => 'OpControlBarrier',
        category  => 'spirv',
        kind      => 'operator',
        signature => 'OpControlBarrier %ExecutionScope %MemoryScope %MemorySemantics',
        summary   => 'SPIR-V execution and optional memory barrier (e.g., Workgroup=2, Workgroup=2, AcquireRelease|WorkgroupMemory=0x108).',
        details   => 'All invocations in ExecutionScope must execute OpControlBarrier uniformly in Vulkan memory model.',
        example   => 'OpControlBarrier %Workgroup %Workgroup %AcquireReleaseWorkgroupMemory',
    },
);

sub meta {
    return {
        name             => 'vulkan',
        label            => 'Vulkan 1.0-1.4 / GLSL 450-460 / SPIR-V',
        category         => 'gpu',
        version          => $VERSION,
        description      => 'Exact std140/std430/scalar/push-constant struct layout calculator with C11 _Static_assert emitter, Vulkan Synchronization2 barrier validator, Vulkan/GLSL/SPIR-V lookup, and GLSL/SPIR-V shader auditor.',
        filetypes        => [qw(glsl vert frag comp geom tesc tese spvasm spirv vulkan)],
        upstream_credits => [
            'Khronos Vulkan 1.0-1.4 Specification',
            'Khronos GLSL 450/460 & SPIR-V Specifications',
            'glsl_analyzer',
            'Khronos glslangValidator & SPIRV-Tools (spirv-val)',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'vulkan_struct_layout',
            description => 'Exact std140 / std430 / scalar / push_constant struct layout calculator: parses GLSL/C structs (including vec3, mat3/mat4, arrays T[N], nested structs), computes exact base alignment, byte offsets, padding slack, flags std140 vec3 & 16B scalar-array traps, and emits C11 _Static_assert + GLSL declarations.',
            inputSchema => {
                type       => 'object',
                properties => {
                    struct      => { type => 'string', description => 'GLSL or C struct definition(s) (nested structs supported).' },
                    fields      => { type => 'array',  description => 'Optional structured list of { name, type, count } field objects.' },
                    layout      => { type => 'string', description => 'Layout rule: std140 (default), std430, scalar, or push_constant.' },
                    struct_name => { type => 'string', description => 'Optional override for struct name in emitted C11/GLSL.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_struct_layout($args || {});
            },
        },
        {
            name        => 'vulkan_sync_validate',
            description => 'Validate VkMemoryBarrier2 / VkImageMemoryBarrier2 (srcStageMask, srcAccessMask, dstStageMask, dstAccessMask, oldLayout, newLayout) for RAW/WAR/WAW hazards, stage-access mismatches, invalid UNDEFINED->PRESENT transitions, and over-broad ALL_COMMANDS stalls, returning minimal tight barrier recommendations.',
            inputSchema => {
                type       => 'object',
                properties => {
                    srcStageMask  => { type => 'string', description => 'Source VkPipelineStageFlags2 mask(s) (pipe-separated string or array).' },
                    srcAccessMask => { type => 'string', description => 'Source VkAccessFlags2 mask(s).' },
                    dstStageMask  => { type => 'string', description => 'Destination VkPipelineStageFlags2 mask(s).' },
                    dstAccessMask => { type => 'string', description => 'Destination VkAccessFlags2 mask(s).' },
                    oldLayout     => { type => 'string', description => 'Optional VkImageLayout oldLayout for VkImageMemoryBarrier2.' },
                    newLayout     => { type => 'string', description => 'Optional VkImageLayout newLayout for VkImageMemoryBarrier2.' },
                    hazard_intent => { type => 'string', description => 'Optional expected hazard class: RAW, WAR, WAW, or auto.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_sync_validate($args || {});
            },
        },
        {
            name        => 'vulkan_spirv_glsl_lookup',
            description => 'Look up Vulkan 1.0-1.4 extensions/APIs, GLSL 450/460 builtins (subgroups, barriers, layouts), and SPIR-V opcodes/capabilities (OpEntryPoint, OpDecorate, OpMatrixTimesVector, OpGroupNonUniform*, OpControlBarrier).',
            inputSchema => {
                type       => 'object',
                properties => {
                    query    => { type => 'string', description => 'Vulkan extension/API, GLSL builtin, or SPIR-V opcode to search.' },
                    category => { type => 'string', description => 'Optional filter: vulkan_ext, vulkan_api, glsl, spirv, or all.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->tool_spirv_glsl_lookup($args || {});
            },
        },
        {
            name        => 'vulkan_shader_audit',
            description => 'Audit GLSL or SPIR-V assembly for std140 vec3/array traps, push-constant >128B limit, missing layout(set=..., binding=...), suboptimal workgroup local_size, non-uniform texture()/dFdx() in divergent branches, plus live glslangValidator/spirv-val when installed.',
            inputSchema => {
                type       => 'object',
                properties => {
                    source       => { type => 'string',  description => 'GLSL or SPIR-V assembly (.spvasm) source.' },
                    stage        => { type => 'string',  description => 'Shader stage: comp, vert, frag, or auto.' },
                    run_compiler => { type => 'boolean', description => 'Invoke glslangValidator / spirv-val if installed (default: true).' },
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

sub _round_up {
    my ($val, $align) = @_;
    return $val if !$align || $align <= 1;
    my $rem = $val % $align;
    return $rem == 0 ? $val : ($val + $align - $rem);
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

# --- Exact Vulkan/GLSL Struct Layout Engine ---

sub _type_metrics {
    my ($type, $rule, $nested_structs) = @_;
    $type =~ s/^\s+|\s+$//g;

    # 1. Nested struct
    if ($nested_structs && exists $nested_structs->{$type}) {
        my $ns = $nested_structs->{$type};
        my $align = ($rule eq 'std140') ? _round_up($ns->{alignment}, 16) : $ns->{alignment};
        my $size  = _round_up($ns->{size}, $align);
        return {
            kind       => 'struct',
            type       => $type,
            size       => $size,
            align      => $align,
            c_type     => $type,
            nested     => $ns,
        };
    }

    # 2. Scalar
    if (exists $SCALAR_TYPES{$type}) {
        my $s = $SCALAR_TYPES{$type};
        return {
            kind   => 'scalar',
            type   => $type,
            size   => $s->{size},
            align  => $s->{align},
            c_type => $s->{c_type},
        };
    }

    # 3. Vector: [i|u|b|d|f16|...]vec[2|3|4]
    if ($type =~ /^(f16|i16|u16|i64|u64|i8|u8|[fiubd])?vec([234])$/) {
        my ($pfx, $n) = ($1 // '', int($2));
        my $sc_name = $VEC_PREFIX_SCALAR{$pfx} // 'float';
        my $sc      = $SCALAR_TYPES{$sc_name};
        my $size    = $sc->{size} * $n;
        my $align;
        if ($rule eq 'scalar') {
            $align = $sc->{align};
        }
        else {
            # std140 & std430: vec2 -> 2N, vec3 -> 4N, vec4 -> 4N
            $align = ($n == 2) ? (2 * $sc->{size}) : (4 * $sc->{size});
        }
        return {
            kind       => 'vector',
            type       => $type,
            components => $n,
            scalar     => $sc_name,
            c_scalar   => $sc->{c_type},
            size       => $size,
            align      => $align,
        };
    }

    # 4. Matrix: [d|f16]?mat([234])(?:x([234]))? (column-major array of C vecR)
    if ($type =~ /^(d|f16)?mat([234])(?:x([234]))?$/) {
        my ($pfx, $cols, $rows) = ($1 // '', int($2), int($3 // $2));
        my $col_vec = "${pfx}vec${rows}";
        my $col_m   = _type_metrics($col_vec, $rule, $nested_structs);
        my $col_align = ($rule eq 'std140') ? _round_up($col_m->{align}, 16) : $col_m->{align};
        my $col_stride = ($rule eq 'scalar') ? $col_m->{size} : _round_up($col_m->{size}, $col_align);
        my $size = $cols * $col_stride;
        return {
            kind       => 'matrix',
            type       => $type,
            cols       => $cols,
            rows       => $rows,
            col_vec    => $col_vec,
            col_stride => $col_stride,
            c_scalar   => $col_m->{c_scalar},
            size       => $size,
            align      => $col_align,
        };
    }

    # Fallback: treat unknown C-like scalar names (e.g. GLuint/VkDeviceAddress)
    if ($type eq 'VkDeviceAddress' || $type eq 'size_t') {
        return { kind => 'scalar', type => $type, size => 8, align => 8, c_type => 'uint64_t' };
    }
    return undef;
}

sub _parse_struct_source {
    my ($src) = @_;
    my $clean = $src;
    $clean =~ s{/\*.*?\*/}{}gs;
    $clean =~ s{//[^\n]*}{}g;

    my @defs;
    # Match explicit `struct Name { ... };` or interface block `layout(...) uniform/buffer Name { ... } [inst];`
    while ($clean =~ /\b(?:struct|(?:uniform|buffer))\s+([A-Za-z_]\w*)\s*\{([^{}]*)\}/gs) {
        my ($name, $body) = ($1, $2);
        push @defs, { name => $name, fields => _parse_field_body($body) };
    }

    # Anonymous push_constant / uniform block: `layout(...) uniform { ... } pc;`
    if (!@defs && $clean =~ /\{([^{}]*)\}/s) {
        my $body = $1;
        push @defs, { name => 'GpuBlock', fields => _parse_field_body($body) };
    }

    # Bare semicolon-separated field list without braces
    if (!@defs && $clean =~ /[A-Za-z_]\w*\s+[A-Za-z_]\w*/) {
        push @defs, { name => 'GpuBlock', fields => _parse_field_body($clean) };
    }

    return \@defs;
}

sub _parse_field_body {
    my ($body) = @_;
    my @fields;
    for my $stmt (split /;/, $body) {
        $stmt =~ s/^\s+|\s+$//g;
        next unless length $stmt;
        # Strip optional layout(...) or precision qualifiers (highp/mediump/lowp/readonly/etc.)
        $stmt =~ s/\blayout\s*\([^)]*\)\s*//g;
        $stmt =~ s/\b(?:highp|mediump|lowp|readonly|writeonly|coherent|volatile|restrict|flat|noperspective|smooth|const)\b\s*//g;
        $stmt =~ s/^\s+|\s+$//g;
        next unless length $stmt;

        if ($stmt =~ /^([A-Za-z_]\w*)\s+(.+)$/) {
            my ($type, $rest) = ($1, $2);
            for my $decl (split /,/, $rest) {
                $decl =~ s/^\s+|\s+$//g;
                if ($decl =~ /^([A-Za-z_]\w*)\s*(?:\[\s*(\d*)\s*\])?$/) {
                    my ($fname, $arr) = ($1, $2);
                    my %f = (name => $fname, type => $type);
                    if (defined $arr) {
                        $f{is_array} = 1;
                        $f{count}    = length($arr) ? int($arr) : 0; # 0 => runtime-sized SSBO array T[]
                    }
                    push @fields, \%f;
                }
            }
        }
    }
    return \@fields;
}

sub _compute_struct_layout {
    my ($name, $fields, $rule, $nested_structs) = @_;
    my $offset        = 0;
    my $max_align     = 1;
    my $total_pad     = 0;
    my @layout_fields;
    my @traps;

    for (my $idx = 0; $idx < @$fields; $idx++) {
        my $f = $fields->[$idx];
        my $fname = $f->{name} || "field_$idx";
        my $ftype = $f->{type} || 'float';
        my $m     = _type_metrics($ftype, $rule, $nested_structs);
        if (!$m) {
            return { ok => 0, error => "Unknown GLSL/Vulkan field type '$ftype' for member '$fname'" };
        }

        my $is_array = ($f->{is_array} || (defined($f->{count}) && $f->{count} != 1)) ? 1 : 0;
        my $count    = $is_array ? (defined($f->{count}) ? int($f->{count}) : 0) : 1;
        my $unsized  = ($is_array && $count == 0) ? 1 : 0;

        my ($align, $size, $array_stride);
        if ($is_array) {
            $align        = ($rule eq 'std140') ? _round_up($m->{align}, 16) : $m->{align};
            $array_stride = ($rule eq 'scalar') ? $m->{size} : _round_up($m->{size}, $align);
            $size         = $unsized ? 0 : ($count * $array_stride);

            # Flag classic std140 scalar/vec2 16B array stride bloat trap
            if ($rule eq 'std140' && $m->{size} < $array_stride) {
                my $waste_per = $array_stride - $m->{size};
                push @traps, {
                    code    => 'STD140_SCALAR_ARRAY_STRIDE',
                    field   => $fname,
                    type    => "$ftype\[" . ($unsized ? '' : $count) . "\]",
                    message => "In std140, array '$fname' of '$ftype' ($m->{size}B) is padded to a ${array_stride}B stride (${waste_per}B wasted per element; total " . ($unsized ? 'runtime' : "${size}B") . ").",
                    fix     => "Pack into vec4 arrays (e.g. vec4 $fname\[" . ($unsized ? '' : ceil($count / 4)) . "\]), switch to std430 SSBO, or enable VK_EXT_scalar_block_layout.",
                };
            }
            elsif ($m->{kind} eq 'vector' && $m->{components} == 3 && $rule ne 'scalar') {
                push @traps, {
                    code    => uc($rule) . '_VEC3_ARRAY_STRIDE',
                    field   => $fname,
                    type    => "$ftype\[" . ($unsized ? '' : $count) . "\]",
                    message => "In $rule, '$ftype' array '$fname' has 16B stride (4B pad per element) vs C float[3] 12B stride.",
                    fix     => 'Use vec4 on both host and shader, or enable VK_EXT_scalar_block_layout.',
                };
            }
        }
        else {
            $align = $m->{align};
            $size  = $m->{size};

            if ($m->{kind} eq 'vector' && $m->{components} == 3 && $rule ne 'scalar') {
                my $next_f = ($idx + 1 < @$fields) ? $fields->[$idx + 1] : undef;
                my $next_m = ($next_f && !$next_f->{is_array}) ? _type_metrics($next_f->{type}, $rule, $nested_structs) : undef;
                my $packed_4b = ($next_m && $next_m->{kind} eq 'scalar' && $next_m->{size} == 4) ? 1 : 0;
                push @traps, {
                    code    => uc($rule) . '_VEC3_ALIGNMENT',
                    field   => $fname,
                    type    => $ftype,
                    message => $packed_4b
                        ? "In $rule, '$ftype $fname' requires 16B base alignment (not 12B as in C float[3]), though following 4B scalar '$next_f->{name}' packs cleanly into bytes +12..+15."
                        : "In $rule, '$ftype $fname' requires 16B base alignment (size 12B + 4B trailing gap vs C float[3]).",
                    fix     => 'Pair with a trailing 4B scalar in bytes 12..15, upgrade to vec4, or align host C field with _Alignas(16).',
                };
            }
            elsif ($m->{kind} eq 'matrix' && $m->{rows} == 3 && $rule ne 'scalar') {
                push @traps, {
                    code    => uc($rule) . '_MAT3_COLUMN_PAD',
                    field   => $fname,
                    type    => $ftype,
                    message => "In $rule, '$ftype $fname' occupies ${size}B ($m->{cols} columns x $m->{col_stride}B stride), NOT " . ($m->{cols} * 12) . "B like C float[$m->{cols}*3]!",
                    fix     => "Store $m->{cols} x float[4] (padded columns) on the host CPU or enable VK_EXT_scalar_block_layout.",
                };
            }
        }

        my $aligned_offset = _round_up($offset, $align);
        my $pad_before     = $aligned_offset - $offset;
        $total_pad += $pad_before;
        $max_align = $align if $align > $max_align;

        push @layout_fields, {
            name           => $fname,
            type           => $ftype,
            is_array       => $is_array,
            count          => $count,
            unsized        => $unsized,
            base_alignment => $align,
            offset         => $aligned_offset,
            padding_before => $pad_before,
            size           => $size,
            (defined $array_stride ? (array_stride => $array_stride) : ()),
            (defined $m->{col_stride} ? (matrix_col_stride => $m->{col_stride}) : ()),
            kind           => $m->{kind},
            metrics        => $m,
        };

        $offset = $aligned_offset + $size;
    }

    my $struct_align = ($rule eq 'std140') ? _round_up($max_align, 16) : $max_align;
    my $total_size   = _round_up($offset, $struct_align);
    my $trailing_pad = $total_size - $offset;
    $total_pad += $trailing_pad;

    return {
        ok                  => 1,
        name                => $name,
        alignment           => $struct_align,
        size                => $total_size,
        unpadded_end        => $offset,
        trailing_padding    => $trailing_pad,
        total_padding_bytes => $total_pad,
        fields              => \@layout_fields,
        traps               => \@traps,
    };
}

sub _emit_c11_and_glsl {
    my ($res, $layout_name, $rule) = @_;
    my $sname = $res->{name};
    my @c_lines;
    my @c_asserts;
    my @glsl_lines;

    push @c_lines, "/* Generated C11 host struct matching Vulkan $layout_name ($rule) layout */";
    push @c_lines, "#include <stdalign.h>";
    push @c_lines, "#include <stddef.h>";
    push @c_lines, "#include <stdint.h>";
    push @c_lines, "";
    push @c_lines, "typedef struct $sname {";

    my $block_qual = ($layout_name eq 'push_constant')
        ? 'layout(push_constant) uniform'
        : ($rule eq 'std140' ? 'layout(std140) uniform' : "layout($rule) buffer");
    push @glsl_lines, "$block_qual $sname {";

    my $pad_idx           = 0;
    my $need_struct_align = ($res->{alignment} && $res->{alignment} > 1) ? 1 : 0;
    for my $f (@{ $res->{fields} }) {
        if ($f->{padding_before} > 0) {
            push @c_lines, sprintf("    uint8_t _pad_%d[%d]; /* +%dB alignment slack */", $pad_idx++, $f->{padding_before}, $f->{padding_before});
        }
        my $m     = $f->{metrics};
        my $fname = $f->{name};
        my $cdecl;
        if ($f->{is_array}) {
            if ($f->{unsized}) {
                $cdecl = "/* runtime-sized $f->{type} $fname\[] (stride $f->{array_stride}B) */";
            }
            elsif ($f->{array_stride} == $m->{size} && $m->{kind} eq 'scalar') {
                $cdecl = "$m->{c_type} $fname\[$f->{count}];";
            }
            elsif ($f->{array_stride} == 16 && $m->{kind} eq 'scalar' && $m->{size} == 4) {
                $cdecl = "struct { $m->{c_type} v; uint32_t _pad[3]; } $fname\[$f->{count}]; /* std140 16B stride */";
            }
            elsif ($m->{kind} eq 'vector') {
                my $elem_n = int($f->{array_stride} / $SCALAR_TYPES{ $m->{scalar} }{size});
                $cdecl = "$m->{c_scalar} $fname\[$f->{count}][$elem_n];";
            }
            else {
                $cdecl = "uint8_t $fname\[$f->{count}][$f->{array_stride}];";
            }
        }
        elsif ($m->{kind} eq 'scalar') {
            $cdecl = "$m->{c_type} $fname;";
        }
        elsif ($m->{kind} eq 'vector') {
            $cdecl = "$m->{c_scalar} $fname\[$m->{components}];";
        }
        elsif ($m->{kind} eq 'matrix') {
            my $col_elems = int($m->{col_stride} / $SCALAR_TYPES{ ($m->{c_scalar} eq 'double' ? 'double' : 'float') }{size});
            $cdecl = "$m->{c_scalar} $fname\[$m->{cols}][$col_elems];";
        }
        else {
            $cdecl = "$f->{type} $fname;";
        }

        if ($need_struct_align && !$f->{unsized}) {
            $cdecl = "alignas($res->{alignment}) $cdecl";
            $need_struct_align = 0;
        }

        push @c_lines, sprintf("    %-52s /* offset %d, size %d, align %d */", $cdecl, $f->{offset}, $f->{size}, $f->{base_alignment});
        if (!$f->{unsized}) {
            push @c_asserts, sprintf("_Static_assert(offsetof(%s, %s) == %d, \"%s.%s offset mismatch\");", $sname, $fname, $f->{offset}, $sname, $fname);
        }

        my $arr_sfx = $f->{is_array} ? ('[' . ($f->{unsized} ? '' : $f->{count}) . ']') : '';
        my $stride_note = defined($f->{array_stride}) ? ", stride $f->{array_stride}" : '';
        push @glsl_lines, sprintf("    %s %s%s; // offset %d, size %d, align %d%s", $f->{type}, $fname, $arr_sfx, $f->{offset}, $f->{size}, $f->{base_alignment}, $stride_note);
    }

    if ($res->{trailing_padding} > 0) {
        push @c_lines, sprintf("    uint8_t _pad_tail[%d]; /* +%dB trailing struct pad */", $res->{trailing_padding}, $res->{trailing_padding});
    }
    push @c_lines, "} $sname;";
    push @c_lines, "";
    push @c_lines, @c_asserts;
    push @c_lines, sprintf("_Static_assert(sizeof(%s) == %d, \"%s total size mismatch\");", $sname, $res->{size}, $sname);

    push @glsl_lines, "}; // total size $res->{size} bytes, align $res->{alignment} bytes";

    return (join("\n", @c_lines), join("\n", @glsl_lines));
}

sub tool_struct_layout {
    my ($self, $args) = @_;
    my $layout_in = lc($args->{layout} // 'std140');
    $layout_in =~ s/[\s\-]+/_/g;
    if ($layout_in !~ /^(?:std140|std430|scalar|push_constant)$/) {
        return { ok => 0, error => "Unsupported layout '$layout_in'. Use std140, std430, scalar, or push_constant." };
    }
    my $rule = ($layout_in eq 'push_constant') ? 'std430' : $layout_in;

    my %nested;
    my $target_def;

    if (ref($args->{fields}) eq 'ARRAY' && @{ $args->{fields} }) {
        $target_def = {
            name   => $args->{struct_name} || 'GpuBlock',
            fields => $args->{fields},
        };
    }
    else {
        my $src = $args->{struct} // $args->{source} // $args->{definition};
        return { ok => 0, error => 'Provide either "struct" (GLSL/C struct text) or "fields" (array of {name,type,count}).' }
            unless defined $src && length $src;
        my $defs = _parse_struct_source($src);
        return { ok => 0, error => 'Could not parse any struct fields from input.' }
            unless $defs && @$defs && @{ $defs->[-1]{fields} };

        # Compute preceding structs first so the last struct can nest them
        for (my $i = 0; $i < @$defs - 1; $i++) {
            my $sub_res = _compute_struct_layout($defs->[$i]{name}, $defs->[$i]{fields}, $rule, \%nested);
            return $sub_res unless $sub_res->{ok};
            $nested{ $defs->[$i]{name} } = $sub_res;
        }
        $target_def = $defs->[-1];
        $target_def->{name} = $args->{struct_name} if defined $args->{struct_name} && length $args->{struct_name};
    }

    my $res = _compute_struct_layout($target_def->{name}, $target_def->{fields}, $rule, \%nested);
    return $res unless $res->{ok};

    if ($layout_in eq 'push_constant' && $res->{size} > 128) {
        push @{ $res->{traps} }, {
            code    => 'PUSH_CONSTANT_OVER_128B',
            field   => $res->{name},
            type    => 'push_constant',
            message => "Push-constant block '$res->{name}' is $res->{size} bytes, exceeding the universal Vulkan 1.0-1.4 guaranteed minimum maxPushConstantsSize (128 bytes).",
            fix     => 'Shrink block to <= 128 bytes or pass a 64-bit VkDeviceAddress (VK_KHR_buffer_device_address) pointing to an SSBO.',
        };
    }

    my ($c11_code, $glsl_code) = _emit_c11_and_glsl($res, $layout_in, $rule);

    # Strip internal metrics key from JSON output
    my @clean_fields = map {
        my %copy = %$_;
        delete $copy{metrics};
        \%copy;
    } @{ $res->{fields} };

    return {
        ok                  => 1,
        struct_name         => $res->{name},
        layout              => $layout_in,
        effective_rule      => $rule,
        struct_alignment    => $res->{alignment},
        total_size          => $res->{size},
        total_stride        => $res->{size},
        trailing_padding    => $res->{trailing_padding},
        total_padding_bytes => $res->{total_padding_bytes},
        fields              => \@clean_fields,
        traps               => $res->{traps},
        c11_declaration     => $c11_code,
        glsl_declaration    => $glsl_code,
    };
}

# --- Vulkan Synchronization2 Validator ---

sub _parse_vk_flags {
    my ($raw, $prefix_re) = @_;
    return [] unless defined $raw;
    my @items = ref($raw) eq 'ARRAY' ? @$raw : split /[\|,;\s]+/, $raw;
    my @out;
    my %seen;
    for my $f (@items) {
        next unless defined $f && length $f;
        my $u = uc($f);
        $u =~ s/$prefix_re//;
        $u =~ s/_BIT$//;
        $u =~ s/_KHR$//;
        $u =~ s/_EXT$//;
        next if !length($u) || $u eq '0';
        push @out, $u unless $seen{$u}++;
    }
    return \@out;
}

sub _norm_layout {
    my ($raw) = @_;
    return '' unless defined $raw && length $raw;
    my $u = uc($raw);
    $u =~ s/^VK_IMAGE_LAYOUT_//;
    return $u;
}

sub tool_sync_validate {
    my ($self, $args) = @_;
    my $src_stages = _parse_vk_flags($args->{srcStageMask},  qr/^VK_PIPELINE_STAGE_(?:2_)?/);
    my $src_access = _parse_vk_flags($args->{srcAccessMask}, qr/^VK_ACCESS_(?:2_)?/);
    my $dst_stages = _parse_vk_flags($args->{dstStageMask},  qr/^VK_PIPELINE_STAGE_(?:2_)?/);
    my $dst_access = _parse_vk_flags($args->{dstAccessMask}, qr/^VK_ACCESS_(?:2_)?/);
    my $old_layout = _norm_layout($args->{oldLayout});
    my $new_layout = _norm_layout($args->{newLayout});
    my $is_image   = (length($old_layout) || length($new_layout)) ? 1 : 0;
    my $intent     = uc($args->{hazard_intent} // 'AUTO');

    my @issues;
    my $add_issue = sub {
        my ($sev, $code, $msg, $fix) = @_;
        push @issues, {
            severity => $sev,
            code     => $code,
            message  => $msg,
            fix      => $fix // '',
        };
    };

    my %src_st = map { $_ => 1 } @$src_stages;
    my %dst_st = map { $_ => 1 } @$dst_stages;
    my %src_ac = map { $_ => 1 } grep { $_ ne 'NONE' } @$src_access;
    my %dst_ac = map { $_ => 1 } grep { $_ ne 'NONE' } @$dst_access;

    my $src_has_write = scalar grep { $WRITE_ACCESS{$_} } keys %src_ac;
    my $src_has_read  = scalar grep { $READ_ACCESS{$_}  } keys %src_ac;
    my $dst_has_write = scalar grep { $WRITE_ACCESS{$_} } keys %dst_ac;
    my $dst_has_read  = scalar grep { $READ_ACCESS{$_}  } keys %dst_ac;

    # 1. Stage-Access Compatibility Checks (VUID-VkMemoryBarrier2-*-03900..03929)
    for my $side (
        [ 'src', $src_stages, \%src_st, [ sort keys %src_ac ] ],
        [ 'dst', $dst_stages, \%dst_st, [ sort keys %dst_ac ] ],
    ) {
        my ($lbl, $st_list, $st_set, $ac_list) = @$side;
        for my $ac (@$ac_list) {
            my $allowed = $ACCESS_VALID_STAGES{$ac} or next;
            my $ok = 0;
            for my $req_st (@$allowed) {
                if ($st_set->{$req_st}) {
                    $ok = 1;
                    last;
                }
            }
            if (!$ok) {
                $add_issue->(
                    'error',
                    'VK_SYNC_STAGE_ACCESS_MISMATCH',
                    "${lbl}AccessMask '$ac' is incompatible with ${lbl}StageMask [" . join('|', @$st_list) . '].',
                    "Pair $ac with a compatible stage (" . join(', ', @{$allowed}[0 .. ($#$allowed > 3 ? 3 : $#$allowed)]) . ').',
                );
            }
        }
    }

    # 2. RAW hazard check: producer stage writing -> consumer reading, but missing srcAccessMask write flush
    my $src_is_producer = ($src_st{COMPUTE_SHADER} || $src_st{FRAGMENT_SHADER} || $src_st{COLOR_ATTACHMENT_OUTPUT}
                        || $src_st{EARLY_FRAGMENT_TESTS} || $src_st{LATE_FRAGMENT_TESTS}
                        || $src_st{TRANSFER} || $src_st{COPY} || $src_st{BLIT} || $src_st{ALL_TRANSFER}) ? 1 : 0;

    if (($dst_has_read || $intent eq 'RAW') && $src_is_producer && !$src_has_write && !$src_has_read) {
        my $needed = $src_st{COLOR_ATTACHMENT_OUTPUT} ? 'VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT'
                   : ($src_st{TRANSFER} || $src_st{COPY} || $src_st{BLIT} || $src_st{ALL_TRANSFER}) ? 'VK_ACCESS_2_TRANSFER_WRITE_BIT'
                   : ($src_st{EARLY_FRAGMENT_TESTS} || $src_st{LATE_FRAGMENT_TESTS}) ? 'VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT'
                   : 'VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT';
        $add_issue->(
            'error',
            'VK_SYNC_MISSING_FLUSH_RAW',
            'RAW cache visibility hazard: producer srcStageMask has no write flag in srcAccessMask before dstAccessMask read; dirty L1/ROP writes may not be flushed.',
            "Add $needed to srcAccessMask so writes are made available before dstAccessMask reads them.",
        );
    }

    # 3. Missing visibility on dstAccessMask when src wrote (RAW/WAW)
    if ($src_has_write && !%dst_ac && !$is_image && !$dst_st{NONE} && !$dst_st{BOTTOM_OF_PIPE}) {
        $add_issue->(
            'warn',
            'VK_SYNC_MISSING_INVALIDATE',
            'srcAccessMask flushes writes (availability op), but dstAccessMask is NONE (no visibility/cache invalidation op for consumer).',
            'Specify the consumer dstAccessMask (e.g. VK_ACCESS_2_SHADER_SAMPLED_READ_BIT or VK_ACCESS_2_SHADER_STORAGE_READ_BIT).',
        );
    }

    # 4. WAR hazard check: read -> write only needs execution dependency (no srcAccessMask read needed)
    if ($src_has_read && !$src_has_write && $dst_has_write && !$dst_has_read) {
        $add_issue->(
            'info',
            'VK_SYNC_REDUNDANT_WAR_ACCESS',
            'Pure WAR (read-after-write inverted: read-then-write) hazard only requires an execution dependency; read flags in srcAccessMask perform unnecessary cache work.',
            'For pure WAR without layout transition, set srcAccessMask = VK_ACCESS_2_NONE and dstAccessMask = VK_ACCESS_2_NONE while keeping srcStageMask -> dstStageMask.',
        );
    }

    # 5. WAW intent missing write access flags
    if ($intent eq 'WAW' && (!$src_has_write || !$dst_has_write)) {
        $add_issue->(
            'error',
            'VK_SYNC_WAW_MISSING_WRITE_MASK',
            'WAW (write-after-write) barrier requires write flags in both srcAccessMask and dstAccessMask to order cache line writebacks.',
            'Include the producer write access bit in srcAccessMask and the subsequent writer access bit in dstAccessMask.',
        );
    }

    # 6. Over-broad pipeline stalls
    if ($src_st{ALL_COMMANDS} || $dst_st{ALL_COMMANDS}) {
        $add_issue->(
            'warn',
            'VK_SYNC_OVERBROAD_ALL_COMMANDS',
            'ALL_COMMANDS stage mask stalls the entire GPU pipeline and kills async compute / transfer overlap.',
            'Narrow srcStageMask and dstStageMask to the exact producing and consuming stages (e.g. COMPUTE_SHADER -> FRAGMENT_SHADER).',
        );
    }
    if ($src_ac{MEMORY_WRITE} || $src_ac{MEMORY_READ} || $dst_ac{MEMORY_WRITE} || $dst_ac{MEMORY_READ}) {
        $add_issue->(
            'warn',
            'VK_SYNC_OVERBROAD_MEMORY_ACCESS',
            'MEMORY_READ / MEMORY_WRITE flushes/invalidates ALL device caches globally.',
            'Replace with narrow access bits (SHADER_STORAGE_WRITE, SHADER_SAMPLED_READ, TRANSFER_WRITE, COLOR_ATTACHMENT_WRITE).',
        );
    }

    # 7. Image layout transition validation
    if ($is_image) {
        if ($new_layout eq 'UNDEFINED' || $new_layout eq 'PREINITIALIZED') {
            $add_issue->(
                'error',
                'VK_SYNC_ILLEGAL_NEW_LAYOUT',
                "VK_IMAGE_LAYOUT_$new_layout is illegal as newLayout in VkImageMemoryBarrier2 (VUID-VkImageMemoryBarrier2-newLayout-01198).",
                'Transition to a valid target layout such as GENERAL, COLOR_ATTACHMENT_OPTIMAL, TRANSFER_DST_OPTIMAL, or SHADER_READ_ONLY_OPTIMAL.',
            );
        }
        if ($old_layout eq 'UNDEFINED' && $new_layout =~ /^PRESENT_SRC/) {
            $add_issue->(
                'error',
                'VK_SYNC_INVALID_UNDEF_TO_PRESENT',
                'Invalid layout transition UNDEFINED -> PRESENT_SRC_KHR discards image contents immediately before presentation.',
                'Transition UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL (or TRANSFER_DST_OPTIMAL), render/blit into the swapchain image, then transition COLOR_ATTACHMENT_OPTIMAL -> PRESENT_SRC_KHR.',
            );
        }
        if ($new_layout eq 'COLOR_ATTACHMENT_OPTIMAL' && !$dst_st{COLOR_ATTACHMENT_OUTPUT} && !$dst_st{ALL_GRAPHICS} && !$dst_st{ALL_COMMANDS}) {
            $add_issue->(
                'warn',
                'VK_SYNC_LAYOUT_STAGE_MISMATCH',
                'Transitioning newLayout to COLOR_ATTACHMENT_OPTIMAL without COLOR_ATTACHMENT_OUTPUT in dstStageMask.',
                'Set dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT and dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT.',
            );
        }
        if ($new_layout eq 'SHADER_READ_ONLY_OPTIMAL' && !$dst_has_read) {
            $add_issue->(
                'warn',
                'VK_SYNC_LAYOUT_STAGE_MISMATCH',
                'Transitioning newLayout to SHADER_READ_ONLY_OPTIMAL without a shader read bit in dstAccessMask.',
                'Set dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT (or COMPUTE_SHADER_BIT) and dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT.',
            );
        }
        if ($new_layout eq 'TRANSFER_DST_OPTIMAL' && !$dst_st{TRANSFER} && !$dst_st{COPY} && !$dst_st{BLIT} && !$dst_st{CLEAR} && !$dst_st{ALL_TRANSFER} && !$dst_st{ALL_COMMANDS}) {
            $add_issue->(
                'warn',
                'VK_SYNC_LAYOUT_STAGE_MISMATCH',
                'Transitioning newLayout to TRANSFER_DST_OPTIMAL without a TRANSFER/COPY/BLIT/CLEAR stage in dstStageMask.',
                'Set dstStageMask = VK_PIPELINE_STAGE_2_COPY_BIT (or TRANSFER_BIT) and dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT.',
            );
        }
    }

    # Build tight recommended barrier
    my %rec = (
        struct        => $is_image ? 'VkImageMemoryBarrier2' : 'VkMemoryBarrier2',
        srcStageMask  => (@$src_stages ? join(' | ', map { "VK_PIPELINE_STAGE_2_${_}_BIT" } @$src_stages) : 'VK_PIPELINE_STAGE_2_NONE'),
        srcAccessMask => (%src_ac ? join(' | ', map { "VK_ACCESS_2_${_}_BIT" } sort keys %src_ac) : 'VK_ACCESS_2_NONE'),
        dstStageMask  => (@$dst_stages ? join(' | ', map { "VK_PIPELINE_STAGE_2_${_}_BIT" } @$dst_stages) : 'VK_PIPELINE_STAGE_2_NONE'),
        dstAccessMask => (%dst_ac ? join(' | ', map { "VK_ACCESS_2_${_}_BIT" } sort keys %dst_ac) : 'VK_ACCESS_2_NONE'),
    );
    if ($is_image) {
        $rec{oldLayout} = "VK_IMAGE_LAYOUT_$old_layout" if length $old_layout;
        $rec{newLayout} = "VK_IMAGE_LAYOUT_$new_layout" if length $new_layout;
    }

    # Improve recommendation for common broken patterns
    if ($src_is_producer && !$src_has_write && ($dst_has_read || $intent eq 'RAW')) {
        $rec{srcAccessMask} = $src_st{COLOR_ATTACHMENT_OUTPUT} ? 'VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT'
                            : ($src_st{TRANSFER} || $src_st{COPY} || $src_st{BLIT} || $src_st{ALL_TRANSFER}) ? 'VK_ACCESS_2_TRANSFER_WRITE_BIT'
                            : 'VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT';
    }
    if ($src_st{ALL_COMMANDS}) {
        $rec{srcStageMask} = $is_image && $old_layout eq 'COLOR_ATTACHMENT_OPTIMAL'
            ? 'VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT'
            : 'VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT';
    }
    if ($dst_st{ALL_COMMANDS}) {
        $rec{dstStageMask} = $is_image && $new_layout eq 'SHADER_READ_ONLY_OPTIMAL'
            ? 'VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT'
            : 'VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT';
    }
    if ($is_image && $old_layout eq 'UNDEFINED' && $new_layout =~ /^PRESENT_SRC/) {
        $rec{oldLayout}     = 'VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL';
        $rec{newLayout}     = 'VK_IMAGE_LAYOUT_PRESENT_SRC_KHR';
        $rec{srcStageMask}  = 'VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT';
        $rec{srcAccessMask} = 'VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT';
        $rec{dstStageMask}  = 'VK_PIPELINE_STAGE_2_NONE';
        $rec{dstAccessMask} = 'VK_ACCESS_2_NONE';
    }

    my $errors = scalar grep { $_->{severity} eq 'error' } @issues;
    my $warns  = scalar grep { $_->{severity} eq 'warn' }  @issues;

    return {
        ok                  => 1,
        barrier_type        => $is_image ? 'VkImageMemoryBarrier2' : 'VkMemoryBarrier2',
        valid               => ($errors == 0 ? 1 : 0),
        error_count         => $errors,
        warning_count       => $warns,
        issues              => \@issues,
        recommended_barrier => \%rec,
    };
}

sub tool_spirv_glsl_lookup {
    my ($self, $args) = @_;
    my $q   = $args->{query} // '';
    my $cat = lc($args->{category} // 'all');
    $q =~ s/^\s+|\s+$//g;

    my @pool = sort keys %VULKAN_DB;
    if ($cat ne 'all' && length $cat) {
        @pool = grep { $VULKAN_DB{$_}{category} eq $cat } @pool;
    }

    if (!length $q) {
        return {
            ok       => 1,
            category => $cat,
            count    => scalar(@pool),
            entries  => [ map { $VULKAN_DB{$_} } @pool ],
        };
    }

    my $ql = lc($q);
    my (@exact, @prefix, @substr);
    for my $k (@pool) {
        my $e  = $VULKAN_DB{$k};
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

sub _run_glslang_check {
    my ($source, $stage, $is_spvasm) = @_;
    if ($is_spvasm) {
        my $spv_as  = _find_executable('spirv-as');
        my $spv_val = _find_executable('spirv-val');
        return {
            tool      => 'spirv-val',
            available => 0,
            note      => 'spirv-as / spirv-val not found on PATH; returning static SPIR-V audit only.',
        } unless $spv_as && $spv_val;

        my ($fh, $asm_path) = File::Temp::tempfile('npl_spv_XXXXXX', SUFFIX => '.spvasm', UNLINK => 1);
        print {$fh} $source;
        close $fh;
        my $bin_path = "${asm_path}.spv";
        my ($wtr, $rdr, $err) = (undef, undef, gensym);
        my $pid = eval { open3($wtr, $rdr, $err, $spv_as, $asm_path, '-o', $bin_path) };
        return { tool => 'spirv-val', available => 1, executed => 0, error => "Failed to run spirv-as: $@" } unless $pid;
        close $wtr;
        my $out = (do { local $/; <$rdr> } // '') . (do { local $/; <$err> } // '');
        close $rdr; close $err;
        waitpid($pid, 0);
        my $rc = $? >> 8;
        if ($rc == 0 && -e $bin_path) {
            my ($w2, $r2, $e2) = (undef, undef, gensym);
            my $p2 = eval { open3($w2, $r2, $e2, $spv_val, $bin_path) };
            if ($p2) {
                close $w2;
                $out = (do { local $/; <$r2> } // '') . (do { local $/; <$e2> } // '');
                close $r2; close $e2;
                waitpid($p2, 0);
                $rc = $? >> 8;
            }
        }
        unlink $bin_path if -e $bin_path;
        return {
            tool      => 'spirv-val',
            available => 1,
            executed  => 1,
            exit_code => $rc,
            output    => $out,
        };
    }

    my $glslang = _find_executable('glslangValidator');
    return {
        tool      => 'glslangValidator',
        available => 0,
        note      => 'glslangValidator not found on PATH; returning static GLSL audit only.',
    } unless $glslang;

    my $ext = ($stage =~ /^(?:vert|frag|comp|geom|tesc|tese)$/) ? $stage : 'comp';
    my ($fh, $path) = File::Temp::tempfile('npl_vk_XXXXXX', SUFFIX => ".$ext", UNLINK => 1);
    print {$fh} $source;
    close $fh;

    my ($wtr, $rdr, $err) = (undef, undef, gensym);
    my $pid = eval { open3($wtr, $rdr, $err, $glslang, '-V', $path) };
    return { tool => 'glslangValidator', available => 1, executed => 0, error => "Failed to invoke glslangValidator: $@" } unless $pid;
    close $wtr;
    my $out = (do { local $/; <$rdr> } // '') . (do { local $/; <$err> } // '');
    close $rdr; close $err;
    waitpid($pid, 0);
    my $rc = $? >> 8;

    my @diags;
    for my $line (split /\r?\n/, $out) {
        if ($line =~ /^(ERROR|WARNING):\s*[^:]+:(\d+):\s*(.+)$/i) {
            my $sev = (uc($1) eq 'ERROR') ? 'error' : 'warn';
            push @diags, {
                line     => ($2 > 0 ? $2 - 1 : 0),
                col      => 0,
                severity => $sev,
                code     => 'GLSLANG',
                message  => $3,
            };
        }
    }

    return {
        tool        => 'glslangValidator',
        path        => $glslang,
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

    my $stage    = lc($args->{stage} // 'auto');
    my $run_comp = exists($args->{run_compiler}) ? ($args->{run_compiler} ? 1 : 0) : 1;
    my $is_spvasm = ($src =~ /^\s*Op(?:Capability|MemoryModel|EntryPoint)\b/m) ? 1 : 0;

    if ($stage eq 'auto' && !$is_spvasm) {
        if ($src =~ /\blocal_size_[xyz]\b|\bgl_GlobalInvocationID\b/) {
            $stage = 'comp';
        }
        elsif ($src =~ /\bgl_Position\b/) {
            $stage = 'vert';
        }
        elsif ($src =~ /\b(?:dFdx|dFdy|fwidth|gl_FragCoord|discard)\b|\blayout\s*\([^)]*location\s*=\s*0[^)]*\)\s*out\s+vec4\b/) {
            $stage = 'frag';
        }
        else {
            $stage = 'comp';
        }
    }

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
            code       => $f{code}     || 'VK_AUDIT',
            message    => $f{message}  || '',
            suggestion => $f{suggestion} // '',
        };
    };

    if ($is_spvasm) {
        # SPIR-V assembly static checks
        my $has_mem_model = ($src =~ /^\s*OpMemoryModel\b/m) ? 1 : 0;
        my $has_entry     = ($src =~ /^\s*OpEntryPoint\b/m)  ? 1 : 0;
        if (!$has_mem_model) {
            $add_finding->(
                line => 0, col => 0, severity => 'error', code => 'SPIRV_MISSING_MEMORY_MODEL',
                message => 'SPIR-V module missing OpMemoryModel (e.g., OpMemoryModel Logical GLSL450).',
                suggestion => 'Declare OpMemoryModel Logical GLSL450 (or PhysicalStorageBuffer64 Vulkan).',
            );
        }
        if (!$has_entry) {
            $add_finding->(
                line => 0, col => 0, severity => 'error', code => 'SPIRV_MISSING_ENTRY_POINT',
                message => 'SPIR-V module missing OpEntryPoint declaration.',
                suggestion => 'Add OpEntryPoint <Model> %main "main" ...',
            );
        }
        if ($src =~ /\bOpGroupNonUniform(?:FAdd|IAdd|FMul|FMin|FMax)\b/ && $src !~ /\bOpCapability\s+GroupNonUniformArithmetic\b/) {
            $add_finding->(
                line => 0, col => 0, severity => 'error', code => 'SPIRV_MISSING_CAPABILITY',
                message => 'Uses OpGroupNonUniform* arithmetic opcode without OpCapability GroupNonUniformArithmetic.',
                suggestion => 'Add OpCapability GroupNonUniformArithmetic at the top of the SPIR-V module.',
            );
        }
        if ($src =~ /\bOpGroupNonUniformBallot\b/ && $src !~ /\bOpCapability\s+GroupNonUniformBallot\b/) {
            $add_finding->(
                line => 0, col => 0, severity => 'error', code => 'SPIRV_MISSING_CAPABILITY',
                message => 'Uses OpGroupNonUniformBallot without OpCapability GroupNonUniformBallot.',
                suggestion => 'Add OpCapability GroupNonUniformBallot at the top of the SPIR-V module.',
            );
        }
    }
    else {
        # GLSL checks
        if ($src !~ /^\s*#version\s+(?:450|460)\b/m) {
            $add_finding->(
                line       => 0,
                col        => 0,
                severity   => 'info',
                code       => 'VK_GLSL_VERSION',
                message    => 'Vulkan GLSL shaders should specify #version 450 or #version 460.',
                suggestion => 'Add #version 460 at line 1.',
            );
        }

        # Check std140 blocks and push_constant blocks using the layout engine
        my $pos = 0;
        while ($src =~ /(layout\s*\(([^)]*)\)\s*(?:readonly\s+|writeonly\s+)?(?:uniform|buffer)\s+([A-Za-z_]\w*)?\s*\{([^{}]*)\})/gs) {
            my ($full, $largs, $bname, $body) = ($1, $2, $3 // 'Block', $4);
            my $match_start = $-[0];
            my $line_no     = () = substr($src, 0, $match_start) =~ /\n/g;

            my $is_pc = ($largs =~ /\bpush_constant\b/) ? 1 : 0;
            my $is_bda = ($largs =~ /\bbuffer_reference\b/) ? 1 : 0;

            if (!$is_pc && !$is_bda && ($largs !~ /\bset\s*=/ || $largs !~ /\bbinding\s*=/)) {
                $add_finding->(
                    line       => $line_no,
                    col        => 0,
                    severity   => 'error',
                    code       => 'VK_MISSING_SET_BINDING',
                    message    => "Vulkan interface block '$bname' is missing explicit layout(set = S, binding = B).",
                    suggestion => 'Specify both set and binding in layout(...) (Vulkan GLSL requires explicit descriptor bindings).',
                );
            }

            if ($is_pc) {
                my $lay = $self->tool_struct_layout({
                    struct      => "struct $bname { $body };",
                    layout      => 'push_constant',
                    struct_name => $bname,
                });
                if ($lay->{ok} && $lay->{total_size} > 128) {
                    $add_finding->(
                        line       => $line_no,
                        col        => 0,
                        severity   => 'error',
                        code       => 'VK_PUSH_CONSTANT_OVER_128B',
                        message    => "Push-constant block '$bname' is $lay->{total_size} bytes (>128B Vulkan 1.0 universal minimum guarantee).",
                        suggestion => 'Reduce push-constant size to <= 128 bytes or pass a 64-bit buffer_reference GPU pointer.',
                    );
                }
            }

            if ($largs =~ /\bstd140\b/) {
                my $lay = $self->tool_struct_layout({
                    struct      => "struct $bname { $body };",
                    layout      => 'std140',
                    struct_name => $bname,
                });
                if ($lay->{ok} && @{ $lay->{traps} || [] }) {
                    for my $t (@{ $lay->{traps} }) {
                        $add_finding->(
                            line       => $line_no,
                            col        => 0,
                            severity   => 'warn',
                            code       => 'VK_' . $t->{code},
                            message    => $t->{message},
                            suggestion => $t->{fix},
                        );
                    }
                }
            }
        }

        # Line-by-line GLSL checks
        my $brace_depth    = 0;
        my @divergent_blks;
        my $pending_div_if = 0;

        for (my $i = 0; $i < @lines; $i++) {
            my $raw = $lines[$i];
            (my $code = $raw) =~ s{//.*$}{};
            next if $code =~ /^\s*$/;

            # Opaque sampler/image uniforms missing set/binding
            if ($code =~ /^\s*(?:layout\s*\(([^)]*)\)\s*)?uniform\s+(?:[iu]?(?:sampler|texture|image)\w+|sampler)\s+([A-Za-z_]\w*)\s*;/) {
                my ($largs, $uname) = ($1 // '', $2);
                if ($largs !~ /\bset\s*=/ || $largs !~ /\bbinding\s*=/) {
                    my $c = index($raw, $uname);
                    $add_finding->(
                        line       => $i,
                        col        => ($c >= 0 ? $c : 0),
                        end_col    => ($c >= 0 ? $c + length($uname) : 1),
                        severity   => 'error',
                        code       => 'VK_MISSING_SET_BINDING',
                        message    => "Opaque resource uniform '$uname' missing explicit layout(set = S, binding = B).",
                        suggestion => "Add layout(set = 0, binding = N) before uniform $uname.",
                    );
                }
            }

            # Compute local_size check
            if ($code =~ /\blayout\s*\(([^)]*\blocal_size_x\s*=\s*\d+[^)]*)\)\s*in\s*;/) {
                my $l = $1;
                my ($lx) = ($l =~ /\blocal_size_x\s*=\s*(\d+)/);
                my ($ly) = ($l =~ /\blocal_size_y\s*=\s*(\d+)/);
                my ($lz) = ($l =~ /\blocal_size_z\s*=\s*(\d+)/);
                $lx = int($lx || 1);
                $ly = int($ly || 1);
                $lz = int($lz || 1);
                my $tot = $lx * $ly * $lz;
                if ($tot % 32 != 0) {
                    $add_finding->(
                        line       => $i,
                        col        => 0,
                        end_col    => length($raw),
                        severity   => 'warn',
                        code       => 'VK_WORKGROUP_NOT_SUBGROUP_MULTIPLE',
                        message    => "Compute workgroup size $lx*$ly*$lz = $tot is not a multiple of 32 (or 64 for AMD wave64), leaving subgroup lanes idle.",
                        suggestion => 'Use a total local_size multiple of 64 (e.g. 64, 128, 256, or 8x8 / 16x16) for peak NVIDIA/AMD/Intel/Apple occupancy.',
                    );
                }
                elsif ($tot % 64 != 0) {
                    $add_finding->(
                        line       => $i,
                        col        => 0,
                        end_col    => length($raw),
                        severity   => 'info',
                        code       => 'VK_WORKGROUP_WAVE64_HINT',
                        message    => "Compute workgroup size $tot is a multiple of 32 but not 64 (half-filled wavefront on AMD CDNA wave64 GPUs).",
                        suggestion => 'Consider a multiple of 64 (64/128/256) if targeting AMD GCN/CDNA wave64 devices.',
                    );
                }
                if ($tot > 1024) {
                    $add_finding->(
                        line       => $i,
                        col        => 0,
                        end_col    => length($raw),
                        severity   => 'error',
                        code       => 'VK_WORKGROUP_OVER_1024',
                        message    => "Compute workgroup size $tot exceeds 1024 invocations.",
                        suggestion => 'Reduce local_size product to <= 256 (universal) or <= 1024.',
                    );
                }
            }

            # Non-uniform derivatives / implicit-LOD texture() in divergent branch
            if ((@divergent_blks || $pending_div_if)
                && $code =~ /\b(texture|textureProj|dFdx|dFdy|dFdxFine|dFdyFine|fwidth|textureQueryLod)\s*\(/)
            {
                my $fn = $1;
                my $c  = index($raw, $fn);
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + length($fn) : 1),
                    severity   => 'warn',
                    code       => 'VK_NONUNIFORM_DERIVATIVE',
                    message    => "Implicit-derivative call '$fn()' inside potentially divergent control flow yields undefined 2x2 quad derivatives.",
                    suggestion => 'Compute derivatives outside the branch and call textureGrad() or explicit-LOD textureLod() inside the branch.',
                );
            }

            # barrier() inside divergent branch
            if ((@divergent_blks || $pending_div_if) && $code =~ /\bbarrier\s*\(\s*\)/) {
                my $c = index($raw, 'barrier');
                $add_finding->(
                    line       => $i,
                    col        => ($c >= 0 ? $c : 0),
                    end_col    => ($c >= 0 ? $c + 7 : 1),
                    severity   => 'error',
                    code       => 'VK_BARRIER_DIVERGENT',
                    message    => 'barrier() called inside non-uniform control flow; causes GPU deadlock.',
                    suggestion => 'Move barrier() outside conditional branches so all invocations in the workgroup execute it uniformly.',
                );
            }

            my $is_div = ($code =~ /\bif\s*\(([^)]+)\)/ && $1 !~ /\buniform\b/) ? 1 : 0;
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
            while (@divergent_blks && $brace_depth < $divergent_blks[-1]) {
                pop @divergent_blks;
            }
        }
    }

    my $ext_compiler = {
        tool      => ($is_spvasm ? 'spirv-val' : 'glslangValidator'),
        available => 0,
        skipped   => 1,
    };
    if ($run_comp) {
        $ext_compiler = _run_glslang_check($src, $stage, $is_spvasm);
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
        stage             => ($is_spvasm ? 'spvasm' : $stage),
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

    my @cands = ($word);
    if ($word =~ /^(?:std140|std430)$/) {
        unshift @cands, "layout($word)";
    }

    for my $c (@cands) {
        if (my $e = $VULKAN_DB{$c}) {
            my $md = "### `$e->{symbol}` (*Vulkan / " . uc($e->{category}) . "*)\n\n"
                   . "```glsl\n$e->{signature}\n```\n\n"
                   . "$e->{summary}\n\n"
                   . "$e->{details}\n\n"
                   . "**Example:**\n```glsl\n$e->{example}\n```";
            return { contents => $md, kind => 'markdown', title => $e->{symbol} };
        }
    }

    my $wl = lc($word);
    for my $k (sort keys %VULKAN_DB) {
        if (lc($k) eq $wl) {
            my $e = $VULKAN_DB{$k};
            my $md = "### `$e->{symbol}` (*Vulkan / " . uc($e->{category}) . "*)\n\n"
                   . "```glsl\n$e->{signature}\n```\n\n$e->{summary}\n\n$e->{details}";
            return { contents => $md, kind => 'markdown', title => $e->{symbol} };
        }
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $p = lc($prefix // '');
    my @items;
    for my $k (sort keys %VULKAN_DB) {
        my $e = $VULKAN_DB{$k};
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
        stage        => ($lang && lc($lang) =~ /^(?:vert|frag|comp|geom|tesc|tese)$/) ? lc($lang) : 'auto',
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
        if ($l =~ /^\s*(%[\w\.]+)\s*=\s*OpFunction\b/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'function',
                line   => $i,
                col    => index($l, $1),
                detail => 'SPIR-V OpFunction',
            );
        }
        elsif ($l =~ /\blayout\s*\([^)]*\)\s*(?:readonly\s+|writeonly\s+)?(uniform|buffer)\s+([A-Za-z_]\w*)\s*\{/) {
            push @syms, $self->make_symbol(
                name   => $2,
                kind   => 'struct',
                line   => $i,
                col    => index($l, $2),
                detail => "GLSL $1 block",
            );
        }
        elsif ($l =~ /\bstruct\s+([A-Za-z_]\w*)\s*\{?/) {
            push @syms, $self->make_symbol(
                name   => $1,
                kind   => 'struct',
                line   => $i,
                col    => index($l, $1),
                detail => 'GLSL struct',
            );
        }
        elsif ($l =~ /^\s*(?:void|float|double|int|uint|bool|[iubd]?vec[234]|d?mat[234](?:x[234])?)\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:\{|$)/) {
            my $name = $1;
            next if $name =~ /^(?:if|for|while|switch)$/;
            push @syms, $self->make_symbol(
                name   => $name,
                kind   => 'function',
                line   => $i,
                col    => index($l, $name),
                detail => 'GLSL function',
            );
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::VulkanDev - Vulkan 1.0-1.4, GLSL 450-460, and SPIR-V MCP pack

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::VulkanDev;

    my $pack = NeoPerl::MCP::Pack::VulkanDev->new();
    my $lay  = $pack->call_tool('vulkan_struct_layout', {
        layout => 'std140',
        struct => 'struct LightUBO { vec3 pos; float intensity; float weights[4]; };',
    });
    my $sync = $pack->call_tool('vulkan_sync_validate', {
        srcStageMask  => 'VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT',
        srcAccessMask => 'VK_ACCESS_2_NONE',
        dstStageMask  => 'VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT',
        dstAccessMask => 'VK_ACCESS_2_SHADER_SAMPLED_READ_BIT',
    });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::VulkanDev> provides four MCP tools and matching LSP
knowledge hooks for Vulkan 1.0-1.4, GLSL 450-460, and SPIR-V compute/graphics
development:

=over 4

=item * C<vulkan_struct_layout> - Exact C<std140>, C<std430>, C<scalar>, and C<push_constant> layout calculator (nested structs, C<vec3>, C<mat3>/C<mat4>, arrays) with C11 C<_Static_assert> and GLSL emitters.

=item * C<vulkan_sync_validate> - C<VkMemoryBarrier2> and C<VkImageMemoryBarrier2> RAW/WAR/WAW hazard validator with minimal barrier recommendations.

=item * C<vulkan_spirv_glsl_lookup> - Reference database for Vulkan 1.0-1.4 extensions/APIs, GLSL subgroup/barrier builtins, and SPIR-V opcodes.

=item * C<vulkan_shader_audit> - Static GLSL and SPIR-V assembly auditor (C<std140> traps, push-constant 128B cap, descriptor bindings, workgroup sizing, non-uniform derivatives) with optional live C<glslangValidator>/C<spirv-val>.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
