package NeoPerl::MCP::Pack::AsmMultiArch;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

our $VERSION = '0.01';

# Telum / Telum II NNPA (B93B) AI Accelerator Reference Data
my %NNPA_SPEC = (
    opcode         => 'B93B',
    format         => 'RRE (implicit GR0=function_code, GR1=parameter_block_addr)',
    arch_levels    => 'IBM z16 Telum (Arch14) & IBM z17 Telum II (Arch15 + Spyre AI DPU offload)',
    parameter_block_bytes => 4096,
    cc_behavior    => 'CC=0 complete; CC=1 exception code in PB; CC=3 partial completion (MUST re-drive via JO / BRC 1)',
    operations     => {
        QAF        => { code => '0x00', desc => 'Query Available Functions, supported tensor formats (DLFloat16, INT8 on Telum II), and max dimension limits' },
        ADD        => { code => '0x10', desc => 'Element-wise tensor addition (Z = X + Y)' },
        SUB        => { code => '0x11', desc => 'Element-wise tensor subtraction (Z = X - Y)' },
        MUL        => { code => '0x12', desc => 'Element-wise tensor multiplication (Z = X * Y)' },
        DIV        => { code => '0x13', desc => 'Element-wise tensor division' },
        MIN        => { code => '0x14', desc => 'Element-wise minimum' },
        MAX        => { code => '0x15', desc => 'Element-wise maximum' },
        LOG        => { code => '0x20', desc => 'Element-wise natural logarithm' },
        EXP        => { code => '0x21', desc => 'Element-wise exponential' },
        SQRT       => { code => '0x22', desc => 'Element-wise square root' },
        RELU       => { code => '0x31', desc => 'Rectified Linear Unit (with optional clipping)' },
        TANH       => { code => '0x32', desc => 'Hyperbolic tangent activation' },
        SIGMOID    => { code => '0x33', desc => 'Logistic sigmoid activation' },
        SOFTMAX    => { code => '0x34', desc => 'Numerically stable Softmax over E1 stick dimension' },
        GELU       => { code => '0x35', desc => 'Gaussian Error Linear Unit (Telum II / Arch15 Transformer acceleration)' },
        LAYERNORM  => { code => '0x41', desc => 'Layer Normalization (Telum II / Arch15 Transformer/LLM inference)' },
        BATCHNORM  => { code => '0x40', desc => 'Batch Normalization' },
        LSTM       => { code => '0x60', desc => 'NNPA-LSTMACT: fused LSTM gate activation & cell state update' },
        GRU        => { code => '0x61', desc => 'NNPA-GRUACT: fused GRU gate activation & hidden state update' },
        CONV       => { code => '0x70', desc => 'NNPA-CONVOLUTION: 2D spatial convolution with bias & activation' },
        MATMUL     => { code => '0x71', desc => 'NNPA-MATMUL-OP (and 0x72 MATMUL-OP-BCAST23): systolic matrix multiply-accumulate' },
    },
    tensor_descriptor_layout => {
        total_bytes  => 32,
        data_formats => 'Format 0 = 4D Feature Tensor (stickified 64-element sticks along E1, 32-stick pages along E2); Format 1 = 4D Kernel Tensor; Data types: DLFloat16 (1 sign, 6 exp, 9 mantissa = 2B) and Telum II INT8 quantized (1B)',
        fields       => [
            { offset => 0,  bytes => 1, name => 'data_layout_format', desc => '0=4D Feature, 1=4D Kernel (64-element E1 sticks)' },
            { offset => 1,  bytes => 1, name => 'data_type',          desc => '0=DLFloat16 (2B), 1=INT8 quantized (Telum II)' },
            { offset => 2,  bytes => 6, name => 'reserved',           desc => 'Must be zero' },
            { offset => 8,  bytes => 4, name => 'dim4_size (E4)',     desc => 'Batch / N dimension' },
            { offset => 12, bytes => 4, name => 'dim3_size (E3)',     desc => 'Height / sequence dimension' },
            { offset => 16, bytes => 4, name => 'dim2_size (E2)',     desc => 'Width / rows dimension (padded to 32-row page)' },
            { offset => 20, bytes => 4, name => 'dim1_size (E1)',     desc => 'Channels / cols dimension (padded to 64-element stick = 128B in DLFloat16)' },
            { offset => 24, bytes => 8, name => 'tensor_data_addr',   desc => '64-bit virtual address (4 KiB page-aligned strongly recommended)' },
        ],
    },
);

# Comprehensive 4-ISA Instruction Catalog (140+ instructions across ppc64le, amd64, arm64, s390x)
my %ISA_DB = (
    ppc64le => {
        lxv => {
            name => 'Load VSX Vector (D-Form)', isa_level => 'POWER9 (ISA 3.0B+)', feature => 'VSX',
            encoding => 'DQ-form (op 61, xo 1)', operands => 'XT,DQ(RA)',
            semantics => 'Loads 16-byte VSX vector from EA = (RA|0) + DQ (16-byte multiple displacement) into VSR[XT] in native endian order.',
            notes => 'Preferred over POWER8 lxvd2x+xxswapd on POWER9/POWER10; DQ displacement must be a multiple of 16.',
        },
        stxv => {
            name => 'Store VSX Vector (D-Form)', isa_level => 'POWER9 (ISA 3.0B+)', feature => 'VSX',
            encoding => 'DQ-form (op 61, xo 5)', operands => 'XS,DQ(RA)',
            semantics => 'Stores 16-byte VSX vector VSR[XS] to EA = (RA|0) + DQ in native endian order.',
            notes => 'No endian swap required on ppc64le (unlike POWER8 stxvd2x).',
        },
        lxvd2x => {
            name => 'Load VSX Vector Doubleword*2 Indexed', isa_level => 'POWER7/POWER8 (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX1-form (op 31, xo 844)', operands => 'XT,RA,RB',
            semantics => 'Loads two 64-bit doublewords from EA=(RA|0)+RB into VSR[XT].',
            notes => 'On POWER8 ppc64le, doublewords are loaded in swapped lane order — pair with xxswapd (xxpermdi XT,XT,XT,2) or use lxv/lxvx on POWER9+.',
        },
        stxvd2x => {
            name => 'Store VSX Vector Doubleword*2 Indexed', isa_level => 'POWER7/POWER8 (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX1-form (op 31, xo 972)', operands => 'XS,RA,RB',
            semantics => 'Stores two 64-bit doublewords from VSR[XS] to EA=(RA|0)+RB.',
            notes => 'On POWER8 ppc64le, precede with xxswapd if lanes are in LE order.',
        },
        lxvw4x => {
            name => 'Load VSX Vector Word*4 Indexed', isa_level => 'POWER7/POWER8 (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX1-form (op 31, xo 780)', operands => 'XT,RA,RB',
            semantics => 'Loads four 32-bit words into VSR[XT]; handles unaligned addresses in hardware on POWER8+.',
            notes => 'On ppc64le, element order is big-endian lane-indexed unless permuted; POWER9+ lxvx loads in LE lane order directly.',
        },
        xvmaddasp => {
            name => 'VSX Vector Multiply-Add Type-A Single-Precision', isa_level => 'POWER7/POWER8+ (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX3-form (op 60, xo 65)', operands => 'XT,XA,XB',
            semantics => '4x FP32 fused multiply-add: VSR[XT] <- (VSR[XA] * VSR[XB]) + VSR[XT] (single rounding).',
            notes => 'Destructive accumulator XT; 2-per-cycle throughput on POWER8/9/10 VSX pipelines.',
        },
        xvmaddadp => {
            name => 'VSX Vector Multiply-Add Type-A Double-Precision', isa_level => 'POWER7/POWER8+ (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX3-form (op 60, xo 97)', operands => 'XT,XA,XB',
            semantics => '2x FP64 fused multiply-add: VSR[XT] <- (VSR[XA] * VSR[XB]) + VSR[XT].',
            notes => 'Core HPC DGEMM workhorse on POWER8/POWER9.',
        },
        xvaddsp => {
            name => 'VSX Vector Add Single-Precision', isa_level => 'POWER7/POWER8+ (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX3-form (op 60, xo 64)', operands => 'XT,XA,XB',
            semantics => '4x FP32 lane-wise IEEE-754 addition: VSR[XT] <- VSR[XA] + VSR[XB].',
            notes => 'Can address all 64 VSRs (FPR0-31 + VR0-31).',
        },
        xvadddp => {
            name => 'VSX Vector Add Double-Precision', isa_level => 'POWER7/POWER8+ (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX3-form (op 60, xo 96)', operands => 'XT,XA,XB',
            semantics => '2x FP64 lane-wise IEEE-754 addition: VSR[XT] <- VSR[XA] + VSR[XB].',
            notes => 'Full 64-VSR register space.',
        },
        xxsldwi => {
            name => 'VSX Vector Shift Left Double by Word Immediate', isa_level => 'POWER7/POWER8+ (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX3-form (op 60, xo 2)', operands => 'XT,XA,XB,SHW',
            semantics => 'Concatenates VSR[XA]||VSR[XB], shifts left by SHW*32 bits, places top 128 bits in VSR[XT].',
            notes => 'Fast 2-cycle word-granular vector rotation/splice.',
        },
        xxperm => {
            name => 'VSX Vector Permute', isa_level => 'POWER9 (ISA 3.0B+)', feature => 'VSX',
            encoding => 'XX3-form (op 60, xo 26)', operands => 'XT,XA,XB',
            semantics => 'Selects 16 bytes from VSR[XT]||VSR[XA] indexed by byte indices in VSR[XB] (3-operand VSR permute across all 64 VSRs).',
            notes => 'POWER9+ generalization of VMX vperm to full 64-VSR file.',
        },
        xxspltd => {
            name => 'VSX Vector Splat Doubleword (Extended Mnemonic)', isa_level => 'POWER7/POWER8+ (ISA 2.06+)', feature => 'VSX',
            encoding => 'XX3-form (xxpermdi XT,XA,XA,DM)', operands => 'XT,XA,DM',
            semantics => 'Replicates doubleword lane DM (0 or 1) of VSR[XA] across both 64-bit lanes of VSR[XT].',
            notes => 'Extended mnemonic for xxpermdi; xxswapd is xxpermdi XT,XA,XA,2.',
        },
        xxsetaccz => {
            name => 'VSX Set 512-Bit MMA Accumulator to Zero', isa_level => 'POWER10 (ISA 3.1)', feature => 'MMA',
            encoding => 'X-form (op 31, xo 177, BF=AT)', operands => 'AT',
            semantics => 'Zeroes 512-bit (4x4 FP32/INT32) Matrix-Multiply Assist accumulator ACC[AT] (AT=0..7) and primes it for rank-k outer products.',
            notes => 'Each MMA accumulator aliases 4 consecutive VSRs (VSR[4*AT..4*AT+3]); do not read aliased VSRs until xxmfacc.',
        },
        xvf32ger => {
            name => 'VSX Vector 32-bit FP Rank-1 Outer Product (Overwrite)', isa_level => 'POWER10 (ISA 3.1)', feature => 'MMA',
            encoding => 'XX3-form (op 59, xo 27)', operands => 'AT,XA,XB',
            semantics => 'Computes 4x4 outer product ACC[AT][i,j] <- XA[i] * XB[j] in FP32 (16 FMAs / 32 FLOPs per instruction).',
            notes => 'Initializes accumulator without prior xxsetaccz.',
        },
        xvf32gerpp => {
            name => 'VSX Vector 32-bit FP Rank-1 Outer Product (Positive-Accumulate)', isa_level => 'POWER10 (ISA 3.1)', feature => 'MMA',
            encoding => 'XX3-form (op 59, xo 19)', operands => 'AT,XA,XB',
            semantics => 'Computes ACC[AT][i,j] += XA[i] * XB[j] for 4x4 FP32 tile (16 FMAs per cycle per MMA engine).',
            notes => 'Core POWER10 SGEMM kernel instruction; unroll across 4-8 accumulators to hide 4-cycle latency.',
        },
        xvf16ger2pp => {
            name => 'VSX Vector 16-bit FP Rank-2 Outer Product (Accumulate FP32)', isa_level => 'POWER10 (ISA 3.1)', feature => 'MMA',
            encoding => 'XX3-form (op 59, xo 51)', operands => 'AT,XA,XB',
            semantics => 'Rank-2 outer product of 4x2 FP16 by 2x4 FP16 accumulated into 4x4 FP32 ACC[AT] (64 FLOPs/inst).',
            notes => 'See also xvbf16ger2pp for BFloat16 AI inference on POWER10.',
        },
        xvi8ger4pp => {
            name => 'VSX Vector 8-bit Signed/Unsigned Rank-4 Outer Product', isa_level => 'POWER10 (ISA 3.1)', feature => 'MMA',
            encoding => 'XX3-form (op 59, xo 3)', operands => 'AT,XA,XB',
            semantics => 'Rank-4 outer product of 4x4 uint8 by 4x4 int8 accumulated into 4x4 INT32 ACC[AT] (128 ops/inst).',
            notes => 'Quantized INT8 AI inference workhorse on POWER10 MMA.',
        },
        xxmfacc => {
            name => 'VSX Move From MMA Accumulator', isa_level => 'POWER10 (ISA 3.1)', feature => 'MMA',
            encoding => 'X-form (op 31, xo 177)', operands => 'AS',
            semantics => 'De-primes MMA accumulator ACC[AS] and transfers its 4x128-bit rows back to VSR[4*AS..4*AS+3] for stxv stores.',
            notes => 'Required before reading the backing VSRs after MMA GER instructions.',
        },
        xxmtacc => {
            name => 'VSX Move To MMA Accumulator', isa_level => 'POWER10 (ISA 3.1)', feature => 'MMA',
            encoding => 'X-form (op 31, xo 177)', operands => 'AT',
            semantics => 'Loads 4x128-bit rows from VSR[4*AT..4*AT+3] into MMA accumulator ACC[AT] and primes it.',
            notes => 'Use when resuming accumulation from existing matrix C values in memory.',
        },
        plxv => {
            name => 'Prefixed Load VSX Vector (34-bit Displacement / PC-Relative)', isa_level => 'POWER10 (ISA 3.1)', feature => 'Prefixed',
            encoding => '8-byte MLS/8LS prefixed (op 1 + op 50)', operands => 'XT,D(RA),R',
            semantics => '8-byte prefixed instruction loading 16-byte VSR[XT] with 34-bit signed displacement or PC-relative addressing (R=1, RA=0).',
            notes => 'Eliminates TOC indirection on POWER10 ELFv2 PC-relative ABI.',
        },
        paddi => {
            name => 'Prefixed Add Immediate (34-bit Immediate / PC-Relative)', isa_level => 'POWER10 (ISA 3.1)', feature => 'Prefixed',
            encoding => '8-byte MLS:D prefixed (op 1 + op 14)', operands => 'RT,RA,SI,R',
            semantics => 'Adds 34-bit signed immediate to RA (or CIA when R=1, RA=0) -> +/-8 GiB PC-relative address calculation in one instruction.',
            notes => 'Replaces addis+addi TOC sequences in POWER10 PC-relative code.',
        },
        lwsync => {
            name => 'Lightweight Synchronize (Acquire/Release Fence)', isa_level => 'POWER4..POWER10 (ISA 2.01+)', feature => 'Memory Ordering',
            encoding => 'X-form (sync 1: op 31, xo 598, L=1)', operands => '(none)',
            semantics => 'Orders Load-Load, Load-Store, and Store-Store (everything except Store-Load) across CPUs with cumulative visibility.',
            notes => 'POWER is weakly ordered: pair atomic release stores with leading lwsync and acquire loads with trailing lwsync/isync.',
        },
        hwsync => {
            name => 'Heavyweight Synchronize (Full Memory Barrier)', isa_level => 'POWER4..POWER10', feature => 'Memory Ordering',
            encoding => 'X-form (sync 0: op 31, xo 598, L=0)', operands => '(none)',
            semantics => 'Full sequential-consistency memory barrier ordering all loads and stores (including Store-Load) across all processors.',
            notes => 'Higher latency than lwsync; required for seq_cst or MMIO ordering.',
        },
        isync => {
            name => 'Instruction Synchronize', isa_level => 'POWER4..POWER10', feature => 'Memory Ordering',
            encoding => 'XL-form (op 19, xo 150)', operands => '(none)',
            semantics => 'Discards prefetched instructions and ensures prior control dependencies (e.g. bne after ldarx/stdcx.) complete before subsequent loads issue.',
            notes => 'Standard acquire barrier after branch-dependent lock acquisition on POWER.',
        },
        lwarx => {
            name => 'Load Word and Reserve Indexed', isa_level => 'POWER4..POWER10', feature => 'Atomic LL/SC',
            encoding => 'X-form (op 31, xo 20)', operands => 'RT,RA,RB[,EH]',
            semantics => 'Loads 32-bit word and sets cache-line reservation for subsequent stwcx. (EH=1 hints exclusive lock acquisition on POWER8+).',
            notes => 'POWER weakly ordered LL/SC primitive; pair with lwsync/isync.',
        },
        ldarx => {
            name => 'Load Doubleword and Reserve Indexed', isa_level => 'POWER4..POWER10', feature => 'Atomic LL/SC',
            encoding => 'X-form (op 31, xo 84)', operands => 'RT,RA,RB[,EH]',
            semantics => 'Loads 64-bit doubleword and sets cache-line reservation for subsequent stdcx. (EH=1 for spinlock hint).',
            notes => 'Address must be 8-byte aligned; avoid memory accesses inside ldarx..stdcx. loop to prevent livelock.',
        },
        'stwcx.' => {
            name => 'Store Word Conditional Indexed', isa_level => 'POWER4..POWER10', feature => 'Atomic LL/SC',
            encoding => 'X-form (op 31, xo 150, Rc=1)', operands => 'RS,RA,RB',
            semantics => 'Stores 32-bit word only if reservation from lwarx still holds; sets CR0[EQ]=1 on success, 0 on failure.',
            notes => 'Must branch back on bne- if reservation lost.',
        },
        'stdcx.' => {
            name => 'Store Doubleword Conditional Indexed', isa_level => 'POWER4..POWER10', feature => 'Atomic LL/SC',
            encoding => 'X-form (op 31, xo 214, Rc=1)', operands => 'RS,RA,RB',
            semantics => 'Stores 64-bit doubleword only if reservation from ldarx holds; sets CR0[EQ]=1 on success.',
            notes => 'Always follow with bne- retry loop and appropriate lwsync/isync fence.',
        },
        'or 27,27,27' => {
            name => 'SMT Thread Priority Yield (yield / low-priority hint)', isa_level => 'POWER7/POWER8/POWER9/POWER10', feature => 'SMT Hint',
            encoding => 'X-form (0x7F7BDB78)', operands => '(yield extended mnemonic)',
            semantics => 'Signals POWER SMT-8/SMT-4 core to yield decode/dispatch slots to sibling hardware threads during spin-wait.',
            notes => 'Essential inside spinlock wait loops on SMT-8 POWER8+ cores; also or 1,1,1 (low) and or 2,2,2 (medium).',
        },
        mftb => {
            name => 'Move From Time Base', isa_level => 'POWER4..POWER10', feature => 'Timer',
            encoding => 'XFX-form (mfspr RT,268)', operands => 'RT',
            semantics => 'Reads 64-bit monotonic Time Base counter (typically 512 MHz on IBM POWER8/9/10) into RT.',
            notes => 'User-space accessible, zero-syscall high-resolution monotonic timer.',
        },
        addis => {
            name => 'Add Immediate Shifted', isa_level => 'POWER4..POWER10', feature => 'Scalar',
            encoding => 'D-form (op 15)', operands => 'RT,RA,SI',
            semantics => 'RT <- (RA|0) + (SI << 16). Classic ELFv2 global entry point prologue: addis 2,12,.TOC.-func@ha.',
            notes => 'Paired with addi/ori for 32-bit constants and TOC calculation.',
        },
        ori => {
            name => 'OR Immediate', isa_level => 'POWER4..POWER10', feature => 'Scalar',
            encoding => 'D-form (op 24)', operands => 'RA,RS,UI',
            semantics => 'RA <- RS | zero_ext(UI). ori 0,0,0 is canonical POWER NOP; ori 2,2,0 is group-ending NOP.',
            notes => 'Used with addis/rldicr to materialize 64-bit constants.',
        },
        mtctr => {
            name => 'Move To Count Register', isa_level => 'POWER4..POWER10', feature => 'Branch',
            encoding => 'XFX-form (mtspr 9,RS)', operands => 'RS',
            semantics => 'Loads Count Register (CTR) for zero-overhead bdnz loops or indirect bctrl calls.',
            notes => 'ELFv2 indirect calls load target address into both r12 AND CTR before bctrl.',
        },
        bdnz => {
            name => 'Branch Decrement Not Zero', isa_level => 'POWER4..POWER10', feature => 'Branch',
            encoding => 'B-form (bc 16,0,target)', operands => 'target',
            semantics => 'Decrements CTR and branches to target if CTR != 0 — zero-overhead hardware counted loop.',
            notes => 'Predicted with near-100% accuracy on POWER pipelines.',
        },
        bctrl => {
            name => 'Branch to Count Register and Link', isa_level => 'POWER4..POWER10', feature => 'Branch',
            encoding => 'XL-form (bcctrl 20,0,0)', operands => '(none)',
            semantics => 'Indirect function call to address in CTR, saving return address in LR.',
            notes => 'ELFv2 ABI requires caller to load callee global entry into r12, save r2 at 24(r1), and restore ld r2,24(r1) immediately after bctrl.',
        },
        blr => {
            name => 'Branch to Link Register', isa_level => 'POWER4..POWER10', feature => 'Branch',
            encoding => 'XL-form (bclr 20,0,0)', operands => '(none)',
            semantics => 'Returns from subroutine to address in Link Register (LR).',
            notes => 'Maintains hardware return-address stack balance.',
        },
        popcntd => {
            name => 'Population Count Doubleword', isa_level => 'POWER7..POWER10 (ISA 2.06+)', feature => 'Bitmanip',
            encoding => 'X-form (op 31, xo 506)', operands => 'RA,RS',
            semantics => 'Counts total set bits (0..64) in 64-bit RS and stores result in RA.',
            notes => 'Single-instruction 64-bit hardware popcount.',
        },
        dcbt => {
            name => 'Data Cache Block Touch', isa_level => 'POWER4..POWER10', feature => 'Cache',
            encoding => 'X-form (op 31, xo 278)', operands => 'RA,RB[,TH]',
            semantics => 'Prefetches 128-byte cache line at EA=(RA|0)+RB into L1 data cache (TH=8..15 configures hardware prefetch streams).',
            notes => 'POWER cache lines are 128 bytes (twice x86 64-byte lines).',
        },
    },

    amd64 => {
        movdqu => {
            name => 'Move Unaligned Double Quadword', isa_level => 'SSE2', feature => 'SSE2',
            encoding => 'F3 0F 6F / 7F', operands => 'xmm1, xmm2/m128',
            semantics => 'Loads or stores 128-bit integer vector without 16-byte alignment requirement.',
            notes => 'Zero penalty when aligned on modern x86_64 microarchitectures; prefer vmovdqu in AVX code to avoid SSE/AVX transition penalties.',
        },
        vmovaps => {
            name => 'Move Aligned Packed Single-Precision FP Values', isa_level => 'AVX / AVX-512', feature => 'AVX/AVX-512',
            encoding => 'VEX/EVEX 0F 28 / 29', operands => 'xmm/ymm/zmm1, m128/m256/m512',
            semantics => 'Loads or stores 16/32/64-byte aligned FP vector; raises #GP fault if memory operand is misaligned.',
            notes => 'Use vmovups unless 16/32/64-byte alignment is guaranteed (check stack offsets).',
        },
        vfmadd231ps => {
            name => 'Fused Multiply-Add Packed Single-Precision (dst = src1*src2 + dst)', isa_level => 'FMA3 / AVX2 / AVX-512', feature => 'FMA/AVX-512',
            encoding => 'VEX/EVEX 66 0F 38 B8', operands => 'ymm/zmm1 [{k1}{z}], ymm/zmm2, ymm/zmm3/m',
            semantics => '8x (YMM) or 16x (ZMM) FP32 fused multiply-add: dst <- (src1 * src2) + dst with optional AVX-512 writemask {k1}.',
            notes => '2-per-cycle throughput on dual-FMA cores; issue vzeroupper before calling legacy SSE code when using YMM/ZMM.',
        },
        vfmadd231pd => {
            name => 'Fused Multiply-Add Packed Double-Precision', isa_level => 'FMA3 / AVX2 / AVX-512', feature => 'FMA/AVX-512',
            encoding => 'VEX/EVEX 66 0F 38 B8 (W=1)', operands => 'ymm/zmm1 [{k1}{z}], ymm/zmm2, ymm/zmm3/m',
            semantics => '4x (YMM) or 8x (ZMM) FP64 fused multiply-add: dst <- (src1 * src2) + dst.',
            notes => 'Primary DGEMM instruction on x86_64.',
        },
        vpmaddubsw => {
            name => 'Multiply and Add Packed Signed and Unsigned Bytes', isa_level => 'SSSE3 / AVX2 / AVX-512BW', feature => 'AVX2',
            encoding => 'VEX/EVEX 66 0F 38 04', operands => 'ymm1, ymm2, ymm3/m256',
            semantics => 'Multiplies unsigned bytes in src1 by signed bytes in src2 and horizontally adds adjacent pairs with signed 16-bit saturation.',
            notes => 'Classic INT8 dot-product building block paired with vpmaddwd (superseded by AVX-512 VNNI vpdpbusd).',
        },
        vpshufb => {
            name => 'Packed Shuffle Bytes', isa_level => 'SSSE3 / AVX2 / AVX-512BW', feature => 'AVX2',
            encoding => 'VEX/EVEX 66 0F 38 00', operands => 'ymm1, ymm2, ymm3/m256',
            semantics => 'In-lane 16-byte lookup table permute (sets output byte to 0 if control byte bit 7 is 1).',
            notes => 'Operates independently within each 128-bit lane; ideal for SIMD nibble lookup tables, base64, and UTF-8 parsing.',
        },
        vpermps => {
            name => 'Permute Single-Precision FP Elements Across Lanes', isa_level => 'AVX2 / AVX-512F', feature => 'AVX2/AVX-512',
            encoding => 'VEX/EVEX 66 0F 38 16', operands => 'ymm/zmm1, ymm/zmm2, ymm/zmm3/m',
            semantics => 'Full cross-lane 32-bit element shuffle indexed by ymm2/zmm2.',
            notes => '3-cycle latency on port 5; crosses 128-bit lane boundaries unlike vpshufb.',
        },
        kmovw => {
            name => 'Move 16-Bit AVX-512 Opmask Register', isa_level => 'AVX-512F', feature => 'AVX-512',
            encoding => 'VEX.L0.0F 90/91/92/93', operands => 'k1, r32/m16/k2',
            semantics => 'Loads, stores, or copies a 16-bit predicate mask register k0..k7 (1 bit per 32-bit lane in a 512-bit ZMM register).',
            notes => 'k0 cannot be used as a merge/zeroing writemask (always means unmasked); use k1..k7.',
        },
        zmm => {
            name => 'AVX-512 512-Bit Vector Register File (zmm0..zmm31)', isa_level => 'AVX-512F', feature => 'AVX-512',
            encoding => 'EVEX 4-byte prefix', operands => 'zmm0..zmm31 {k1}{z}',
            semantics => '32 architectural 512-bit SIMD registers (16x FP32 / 8x FP64 / 64x INT8) supporting per-lane predication {k1}{z}, embedded broadcast {1to16}, and rounding {rn-sae}.',
            notes => 'All 32 ZMM registers are caller-saved on SysV amd64; issue vzeroupper on exit if mixing with legacy SSE.',
        },
        ldtilecfg => {
            name => 'Load Intel AMX Tile Configuration', isa_level => 'Intel AMX (Sapphire Rapids+)', feature => 'AMX',
            encoding => 'VEX.128.NP.0F38.W0 49', operands => 'm512',
            semantics => 'Loads 64-byte TILECFG structure configuring row counts (up to 16) and bytes-per-row (up to 64) for 8 1-KiB tile registers TMM0..TMM7.',
            notes => 'Must be followed by tilerelease before leaving AMX region so XSAVE/context switches do not pay 8 KiB tile save overhead.',
        },
        tileloadd => {
            name => 'Load 2D Matrix Tile From Memory With Stride', isa_level => 'Intel AMX', feature => 'AMX',
            encoding => 'VEX.128.F2.0F38.W0 4B', operands => 'tmm1, [base + stride*1]',
            semantics => 'Loads 2D tile (up to 16x64B = 1 KiB) from strided memory into TMM register using SIB index register as row byte stride.',
            notes => 'Requires SIB addressing with stride in index register; see tileloaddt1 for L2 non-temporal hint.',
        },
        tdpbf16ps => {
            name => 'AMX Tile Matrix Multiply BF16 -> FP32 Accumulate', isa_level => 'Intel AMX-BF16', feature => 'AMX',
            encoding => 'VEX.128.F3.0F38.W0 5C', operands => 'tmm1, tmm2, tmm3',
            semantics => 'Computes 16x32 BF16 x 32x16 BF16 matrix multiply-accumulate into 16x16 FP32 tile tmm1 (1024 BF16 FMAs = 2048 FLOPs/inst).',
            notes => 'All three tile operands must be distinct TMM registers.',
        },
        tdpbssd => {
            name => 'AMX Tile Matrix Multiply Signed INT8 -> INT32 Accumulate', isa_level => 'Intel AMX-INT8', feature => 'AMX',
            encoding => 'VEX.128.F2.0F38.W0 5E', operands => 'tmm1, tmm2, tmm3',
            semantics => 'Computes 16x64 INT8 x 64x16 INT8 matrix multiply-accumulate into 16x16 INT32 tile tmm1 (2048 MACs/inst).',
            notes => 'Highest-throughput CPU INT8 GEMM instruction on x86_64.',
        },
        tilestored => {
            name => 'Store 2D Matrix Tile To Strided Memory', isa_level => 'Intel AMX', feature => 'AMX',
            encoding => 'VEX.128.F3.0F38.W0 4B', operands => '[base + stride*1], tmm1',
            semantics => 'Stores 2D tile register TMM1 back to memory with byte stride in SIB index register.',
            notes => 'Follow final tilestored with tilerelease.',
        },
        tilerelease => {
            name => 'Release Intel AMX Tile State', isa_level => 'Intel AMX', feature => 'AMX',
            encoding => 'VEX.128.NP.0F38.W0 49 C0', operands => '(none)',
            semantics => 'Resets TILECFG and marks TMM0..TMM7 as INIT state for fast XSAVE/XRSTOR.',
            notes => 'Mandatory at end of AMX kernel; omitting causes severe context-switch and function-call penalties.',
        },
        pext => {
            name => 'Parallel Bits Extract', isa_level => 'BMI2', feature => 'BMI2',
            encoding => 'VEX.LZ.F3.0F38 F5', operands => 'r64, r64, r/m64',
            semantics => 'Extracts bits from src1 at positions where mask src2 has 1-bits and packs them contiguously into low bits of dst.',
            notes => '3-cycle latency on Intel/AMD Zen3+ (slower microcode on Zen1/Zen2).',
        },
        pdep => {
            name => 'Parallel Bits Deposit', isa_level => 'BMI2', feature => 'BMI2',
            encoding => 'VEX.LZ.F2.0F38 F5', operands => 'r64, r64, r/m64',
            semantics => 'Scatters contiguous low bits of src1 into bit positions set in mask src2.',
            notes => '3-cycle hardware latency on Intel Haswell+ and AMD Zen3+ (slow on Zen1/2).',
        },
        mulx => {
            name => 'Unsigned Multiply Without Affecting Flags', isa_level => 'BMI2', feature => 'BMI2',
            encoding => 'VEX.LZ.F2.0F38 F6', operands => 'r64_hi, r64_lo, r/m64 (implicit RDX)',
            semantics => 'Computes 128-bit unsigned product RDX * src into (r64_hi:r64_lo) without clobbering CF/OF flags.',
            notes => 'Pairs with adcx/adox for dual-carry-chain big-integer / RSA / ECC multiplication.',
        },
        tzcnt => {
            name => 'Count Trailing Zero Bits', isa_level => 'BMI1', feature => 'BMI1/BMI2',
            encoding => 'F3 0F BC', operands => 'r64, r/m64',
            semantics => 'Counts trailing 0 bits from LSB; returns 64 cleanly if source is 0 (unlike legacy bsf).',
            notes => 'Safe on zero input; decodes as bsf on pre-BMI1 CPUs.',
        },
        lzcnt => {
            name => 'Count Leading Zero Bits', isa_level => 'ABM / LZCNT', feature => 'BMI1/BMI2',
            encoding => 'F3 0F BD', operands => 'r64, r/m64',
            semantics => 'Counts leading 0 bits from MSB; returns 64 cleanly if source is 0.',
            notes => 'Check CPUID LZCNT bit before executing on legacy CPUs where F3 0F BD executes as bsr.',
        },
        mfence => {
            name => 'Memory Fence (Full Barrier)', isa_level => 'SSE2', feature => 'Memory Ordering',
            encoding => '0F AE F0', operands => '(none)',
            semantics => 'Serializes all load and store memory operations (including non-temporal stores and Store-Load reordering under x86-TSO).',
            notes => 'Under x86-TSO, lock add qword ptr [rsp], 0 is often faster than mfence for pure Store-Load fencing when NT stores are not used.',
        },
        lfence => {
            name => 'Load Fence (Dispatch-Serializing)', isa_level => 'SSE2', feature => 'Memory Ordering',
            encoding => '0F AE E8', operands => '(none)',
            semantics => 'Serializes instruction execution and loads; blocks speculative execution (Spectre v1 mitigation) and brackets rdtsc.',
            notes => 'Place before rdtsc for accurate cycle timing.',
        },
        sfence => {
            name => 'Store Fence', isa_level => 'SSE', feature => 'Memory Ordering',
            encoding => '0F AE F8', operands => '(none)',
            semantics => 'Orders weakly-ordered non-temporal streaming stores (movntdq/vmovntps) and clflushopt before subsequent stores.',
            notes => 'Not needed for ordinary write-back TSO stores.',
        },
        'lock cmpxchg' => {
            name => 'Atomic Compare and Exchange', isa_level => 'x86_64', feature => 'Atomic',
            encoding => 'F0 REX.W 0F B1', operands => 'm64, r64 (implicit RAX=expected)',
            semantics => 'Atomically compares [mem] with RAX; if equal, writes r64 to [mem] and sets ZF=1; else loads [mem] into RAX and clears ZF. Implicit full memory barrier.',
            notes => 'See also lock cmpxchg16b for 128-bit CAS.',
        },
        pause => {
            name => 'Spin-Loop Hint', isa_level => 'SSE2', feature => 'Sync Hint',
            encoding => 'F3 90', operands => '(none)',
            semantics => 'De-pipelines spin-wait loops to prevent memory-order violation pipeline flushes and yields SMT execution resources (~10-140 cycles).',
            notes => 'Mandatory in every x86_64 spinlock loop.',
        },
        rdtsc => {
            name => 'Read Time-Stamp Counter', isa_level => 'x86_64', feature => 'Timer',
            encoding => '0F 31', operands => '(implicit EDX:EAX)',
            semantics => 'Reads 64-bit invariant TSC into EDX (high 32) and EAX (low 32). Non-serializing; precede with lfence.',
            notes => 'Combine EDX:EAX via shl rdx,32; or rax,rdx.',
        },
        rdtscp => {
            name => 'Read Time-Stamp Counter and Processor ID', isa_level => 'x86_64 (RDTSCP)', feature => 'Timer',
            encoding => '0F 01 F9', operands => '(implicit EDX:EAX, ECX=IA32_TSC_AUX)',
            semantics => 'Waits for prior instructions to retire, reads 64-bit TSC into EDX:EAX and core/NUMA ID into ECX; follow with lfence to prevent subsequent instructions hoisting.',
            notes => 'Standard end-of-benchmark timer pair (lfence; rdtsc ... rdtscp; lfence).',
        },
        vzeroupper => {
            name => 'Zero Upper Bits of YMM/ZMM Registers', isa_level => 'AVX', feature => 'AVX',
            encoding => 'VEX.128.0F 77', operands => '(none)',
            semantics => 'Zeroes bits 128..511 of YMM0..YMM15 (and ZMM0..ZMM15), returning AVX state to clean SSE-compatible mode.',
            notes => 'Critical before returning or calling functions that may execute legacy non-VEX SSE instructions (avoids ~70-cycle AVX-SSE transition stalls on Intel cores).',
        },
        popcnt => {
            name => 'Population Count', isa_level => 'SSE4.2 / POPCNT', feature => 'Bitmanip',
            encoding => 'F3 REX.W 0F B8', operands => 'r64, r/m64',
            semantics => 'Counts set 1-bits in source operand.',
            notes => 'Watch false output dependency on older Intel CPUs (xor dst,dst before popcnt dst,src).',
        },
        bswap => {
            name => 'Byte Swap', isa_level => 'x86_64', feature => 'Bitmanip',
            encoding => 'REX.W 0F C8+rd', operands => 'r64',
            semantics => 'Reverses byte order of 32-bit or 64-bit register (big-endian <-> little-endian).',
            notes => 'Single-cycle latency; pair with movbe for memory byte-swap.',
        },
        prefetcht0 => {
            name => 'Prefetch Data Into All Cache Levels (L1/L2/L3)', isa_level => 'SSE', feature => 'Cache',
            encoding => '0F 18 /1', operands => 'm8',
            semantics => 'Brings 64-byte cache line containing m8 into L1d and outer caches without faulting on invalid addresses.',
            notes => 'Use prefetchnta for streaming data to avoid polluting L2/L3.',
        },
    },

    arm64 => {
        ldr => {
            name => 'Load Register', isa_level => 'ARMv8.0-A', feature => 'Core',
            encoding => '32-bit fixed', operands => 'Xt/Wt, [Xn|SP, #imm]',
            semantics => 'Loads 64-bit (Xt) or 32-bit zero-extended (Wt) value from memory (supports pre-index, post-index, and scaled unsigned offsets).',
            notes => 'Prefer ldp for paired loads to double memory-bandwidth utilization.',
        },
        stp => {
            name => 'Store Pair of Registers', isa_level => 'ARMv8.0-A', feature => 'Core',
            encoding => '32-bit fixed', operands => 'Xt1, Xt2, [Xn|SP, #imm]!',
            semantics => 'Stores two 64-bit registers atomically in a single instruction (canonical prologue: stp x29, x30, [sp, #-32]!).',
            notes => 'SP must remain 16-byte aligned whenever dereferenced in AArch64.',
        },
        ldp => {
            name => 'Load Pair of Registers', isa_level => 'ARMv8.0-A', feature => 'Core',
            encoding => '32-bit fixed', operands => 'Xt1, Xt2, [Xn|SP], #imm',
            semantics => 'Loads two 64-bit registers (canonical epilogue: ldp x29, x30, [sp], #32).',
            notes => 'Also supports 128-bit NEON vector pairs (ldp q0, q1, [x0], #32).',
        },
        fmla => {
            name => 'Floating-Point Fused Multiply-Add (NEON & SVE)', isa_level => 'ARMv8.0-A NEON / ARMv8.2-A SVE', feature => 'NEON/SVE',
            encoding => 'AdvSIMD / SVE 32-bit', operands => 'Vd.4S, Vn.4S, Vm.4S  |  SVE: Zd.S, Pg/M, Zn.S, Zm.S',
            semantics => 'Fused multiply-add: dst += src1 * src2 (4x FP32 or 2x FP64 in NEON; scalable VL/32 lanes predicated by Pg/M in SVE).',
            notes => 'Supports indexed-lane form fmla v0.4s, v1.4s, v2.s[0] ideal for register-blocked GEMM without explicit broadcasts.',
        },
        ld1 => {
            name => 'Load Multiple Single-Element Structures (NEON)', isa_level => 'ARMv8.0-A', feature => 'NEON',
            encoding => 'AdvSIMD load/store', operands => '{Vt.4S, Vt2.4S}, [Xn], #32',
            semantics => 'Loads 1 to 4 contiguous 128-bit NEON vectors with optional post-increment.',
            notes => 'Supports interleaved ld2/ld3/ld4 for AoS-to-SoA RGB/RGBA deinterleaving.',
        },
        st1 => {
            name => 'Store Multiple Single-Element Structures (NEON)', isa_level => 'ARMv8.0-A', feature => 'NEON',
            encoding => 'AdvSIMD load/store', operands => '{Vt.4S}, [Xn], #16',
            semantics => 'Stores 1 to 4 contiguous 128-bit NEON vectors with optional post-increment.',
            notes => 'Interleaving st2/st3/st4 packs SoA back to AoS in hardware.',
        },
        tbl => {
            name => 'Table Vector Lookup (NEON Byte Permute)', isa_level => 'ARMv8.0-A', feature => 'NEON',
            encoding => 'AdvSIMD TBL', operands => 'Vd.16B, {Vn.16B .. Vn+3.16B}, Vm.16B',
            semantics => 'Permutes 16 bytes using up to 4 consecutive source vectors (64-byte table); out-of-range indices produce 0.',
            notes => 'AArch64 counterpart to x86 vpshufb and POWER vperm, supporting up to 64-byte tables in a single instruction.',
        },
        udot => {
            name => 'Unsigned Dot Product (4x UINT8 -> UINT32)', isa_level => 'ARMv8.2-A DotProd', feature => 'NEON/DotProd',
            encoding => 'AdvSIMD DotProd', operands => 'Vd.4S, Vn.16B, Vm.16B',
            semantics => 'Computes 4 parallel 4-element unsigned byte dot products accumulated into 4x UINT32 lanes (16 MACs/inst).',
            notes => 'Present on Apple Silicon M1-M4, AWS Graviton2/3/4, Neoverse N1/V1/V2.',
        },
        sdot => {
            name => 'Signed Dot Product (4x INT8 -> INT32)', isa_level => 'ARMv8.2-A DotProd', feature => 'NEON/DotProd',
            encoding => 'AdvSIMD DotProd', operands => 'Vd.4S, Vn.16B, Vm.16B',
            semantics => 'Computes 4 parallel 4-element signed INT8 dot products accumulated into 4x INT32 lanes (16 MACs/inst).',
            notes => 'Core quantized LLM/CNN SIMD primitive on ARM64.',
        },
        bfmmla => {
            name => 'BFloat16 2x4 by 4x2 Matrix Multiply-Accumulate', isa_level => 'ARMv8.6-A BF16', feature => 'BF16/Matrix',
            encoding => 'AdvSIMD/SVE BFMMLA', operands => 'Vd.4S, Vn.8H, Vm.8H',
            semantics => 'Multiplies 2x4 BF16 tile by 4x2 BF16 tile and accumulates into 2x2 FP32 tile (16 BF16 FMAs/inst).',
            notes => 'Supported on Neoverse V1/V2, Graviton3/4, and Apple M2+.',
        },
        faddp => {
            name => 'Floating-Point Add Pairwise', isa_level => 'ARMv8.0-A', feature => 'NEON',
            encoding => 'AdvSIMD FADDP', operands => 'Vd.4S, Vn.4S, Vm.4S  (or Sd, Vn.2S)',
            semantics => 'Adds adjacent pairs of floating-point lanes horizontally (two faddp calls reduce a 4-lane vector to scalar).',
            notes => 'Fast horizontal reduction without crossing scalar/vector domain prematurely.',
        },
        whilelt => {
            name => 'SVE Generate Predicate While Less Than', isa_level => 'ARMv8.2-A SVE / ARMv9 SVE2', feature => 'SVE/SVE2',
            encoding => 'SVE predicate', operands => 'Pd.S, Xn, Xm',
            semantics => 'Generates active lane predicate Pd for vector-length-agnostic loops while (Xn + lane) < Xm; sets NZCV flags for b.first.',
            notes => 'Eliminates scalar tail cleanup loops completely across 128b/256b/512b SVE implementations.',
        },
        ld1w => {
            name => 'SVE Predicated Contiguous Load 32-Bit Words', isa_level => 'ARMv8.2-A SVE / SVE2', feature => 'SVE/SVE2',
            encoding => 'SVE load', operands => 'Zt.S, Pg/Z, [Xn, Xm, LSL #2]',
            semantics => 'Loads active 32-bit lanes under predicate Pg/Z (inactive lanes are zeroed and do not fault).',
            notes => 'Safe at page boundaries for partial tail vectors.',
        },
        cntw => {
            name => 'SVE Count 32-Bit Vector Elements', isa_level => 'ARMv8.2-A SVE / SVE2', feature => 'SVE/SVE2',
            encoding => 'SVE scalar', operands => 'Xd[, pattern, MUL #imm]',
            semantics => 'Returns the hardware SVE vector length in 32-bit elements (4 for 128b, 8 for 256b, 16 for 512b) for loop stride increments.',
            notes => 'Enables single binary to scale transparently from 128-bit to 2048-bit SVE hardware.',
        },
        ldaddal => {
            name => 'LSE Atomic Add on Word/Doubleword (Acquire-Release)', isa_level => 'ARMv8.1-A LSE', feature => 'LSE Atomic',
            encoding => 'LSE atomic', operands => 'Xs, Xt, [Xn|SP]',
            semantics => 'Single-instruction atomic fetch-and-add with acquire-release memory ordering (Xt receives old value).',
            notes => 'Far faster under multi-core contention than LL/SC ldxr/stxr loops (compile with -moutline-atomics or -march=armv8.2-a).',
        },
        casal => {
            name => 'LSE Atomic Compare-and-Swap (Acquire-Release)', isa_level => 'ARMv8.1-A LSE', feature => 'LSE Atomic',
            encoding => 'LSE atomic', operands => 'Xs, Xt, [Xn|SP]',
            semantics => 'Atomically compares [Xn] against Xs; if equal writes Xt, else returns old [Xn] in Xs, with acquire-release ordering.',
            notes => 'LSE counterpart to x86 lock cmpxchg and s390x csg.',
        },
        swpal => {
            name => 'LSE Atomic Swap (Acquire-Release)', isa_level => 'ARMv8.1-A LSE', feature => 'LSE Atomic',
            encoding => 'LSE atomic', operands => 'Xs, Xt, [Xn|SP]',
            semantics => 'Atomically exchanges [Xn] with Xs, returning previous value in Xt with acquire-release semantics.',
            notes => 'Ideal for lock-free queue tail exchange and spinlock acquisition.',
        },
        ldxr => {
            name => 'Load Exclusive Register (LL)', isa_level => 'ARMv8.0-A', feature => 'LL/SC Atomic',
            encoding => '32-bit exclusive', operands => 'Xt, [Xn|SP]',
            semantics => 'Loads value and marks local/global exclusive monitor; pair with stxr. Relaxed ordering; use ldaxr or dmb ish when ordering is required.',
            notes => 'Avoid bare ldxr/stxr without acquire/release (ldaxr/stlxr) or dmb ish on weakly-ordered ARM64.',
        },
        stxr => {
            name => 'Store Exclusive Register (SC)', isa_level => 'ARMv8.0-A', feature => 'LL/SC Atomic',
            encoding => '32-bit exclusive', operands => 'Ws, Xt, [Xn|SP]',
            semantics => 'Conditionally stores Xt if exclusive monitor still set; sets Ws=0 on success, 1 on failure.',
            notes => 'Ws must not overlap Xt or Xn. Prefer LSE atomics (casal/ldaddal) on ARMv8.1+.',
        },
        'dmb ish' => {
            name => 'Data Memory Barrier (Inner Shareable Full Fence)', isa_level => 'ARMv8.0-A', feature => 'Memory Ordering',
            encoding => 'D5033BBF', operands => 'ish | ishld | ishst',
            semantics => 'Orders all memory accesses (or loads-only with ishld, stores-only with ishst) across all CPU cores in the inner-shareable domain.',
            notes => 'Standard C11/C++11 atomic_thread_fence(memory_order_acq_rel / seq_cst) barrier on ARM64.',
        },
        dsb => {
            name => 'Data Synchronization Barrier', isa_level => 'ARMv8.0-A', feature => 'Memory Ordering',
            encoding => 'D5033F9F', operands => 'sy | ish | ishst',
            semantics => 'Stalls execution until all prior memory accesses, cache/TLB maintenance, and page table updates fully complete.',
            notes => 'Heavier than dmb; required for DMA/MMIO/cache maintenance (not ordinary thread sync).',
        },
        isb => {
            name => 'Instruction Synchronization Barrier', isa_level => 'ARMv8.0-A', feature => 'Memory Ordering',
            encoding => 'D5033FDF', operands => '[sy]',
            semantics => 'Flushes CPU pipeline so subsequent instructions are fetched under updated system register / JIT icache state.',
            notes => 'Also used as a brief spin-wait backoff on Apple Silicon where yield is a 1-cycle NOP.',
        },
        yield => {
            name => 'Thread Yield Hint', isa_level => 'ARMv8.0-A', feature => 'Sync Hint',
            encoding => 'D503203F', operands => '(none)',
            semantics => 'Signals spin-wait loop to yield SMT/pipeline resources (on Apple Silicon, consider isb or wfe/sevl for power-efficient backoff).',
            notes => 'Canonical ARM64 spinlock hint.',
        },
        'mrs cntvct_el0' => {
            name => 'Read Virtual Counter Timer (CNTVCT_EL0)', isa_level => 'ARMv8.0-A', feature => 'Timer',
            encoding => 'mrs Xt, cntvct_el0 (D53BE040+Rt)', operands => 'Xt, cntvct_el0',
            semantics => 'Reads 64-bit monotonic generic virtual timer count (24 MHz on Apple Silicon; query cntfrq_el0 for Hz).',
            notes => 'Precede with isb to prevent out-of-order speculative read during microbenchmarking.',
        },
        pacibsp => {
            name => 'Pointer Authentication Sign LR With SP (Key IB)', isa_level => 'ARMv8.3-A PAUTH', feature => 'Security/PAC',
            encoding => 'D503237F (NOP-space)', operands => '(none)',
            semantics => 'Signs return address X30 (LR) using SP as context modifier and Key IB to defend against ROP attacks.',
            notes => 'Standard prologue on Apple Silicon arm64e and Linux PAC-enabled binaries; pair with autibsp / retab.',
        },
        autibsp => {
            name => 'Pointer Authentication Verify LR With SP (Key IB)', isa_level => 'ARMv8.3-A PAUTH', feature => 'Security/PAC',
            encoding => 'D50323FF (NOP-space)', operands => '(none)',
            semantics => 'Authenticates signed X30 (LR) before ret; corrupts pointer into faulting address if tampered.',
            notes => 'Pair with pacibsp (or combined retab).',
        },
        rev => {
            name => 'Reverse Bytes', isa_level => 'ARMv8.0-A', feature => 'Bitmanip',
            encoding => '5AC00C00 (64-bit)', operands => 'Xd, Xn',
            semantics => 'Reverses byte order of 64-bit register (big-endian <-> little-endian).',
            notes => 'Single-cycle endianness conversion.',
        },
        prfm => {
            name => 'Prefetch Memory', isa_level => 'ARMv8.0-A', feature => 'Cache',
            encoding => '32-bit prefetch', operands => 'pldl1keep|pldl1strm|pstl1keep, [Xn, #imm]',
            semantics => 'Prefetches cache line (64B on Neoverse, 128B on Apple Silicon) into L1/L2 cache.',
            notes => 'Use pldl1strm for non-temporal streaming reads.',
        },
    },

    s390x => {
        lg => {
            name => 'Load (64-bit, Long Displacement)', isa_level => 'z/Arch (Arch5+)', feature => 'Core',
            encoding => 'E304 (RXY-a)', operands => '%r1, D2(%x2,%b2)',
            semantics => 'Loads 64-bit big-endian doubleword into %r1 using 20-bit signed displacement (-524288..+524287).',
            notes => 's390x is strictly big-endian with strong TSO-like memory ordering.',
        },
        stg => {
            name => 'Store (64-bit, Long Displacement)', isa_level => 'z/Arch (Arch5+)', feature => 'Core',
            encoding => 'E324 (RXY-a)', operands => '%r1, D2(%x2,%b2)',
            semantics => 'Stores 64-bit %r1 to storage with 20-bit signed displacement.',
            notes => 'Doubleword alignment recommended.',
        },
        lay => {
            name => 'Load Address (Long Displacement)', isa_level => 'z990+ (Arch6+)', feature => 'Core',
            encoding => 'E371 (RXY-a)', operands => '%r1, D2(%x2,%b2)',
            semantics => 'Computes 64-bit effective address with 20-bit signed displacement (frequently used for stack allocation lay %r15,-160(%r15)).',
            notes => 'Does not set condition code.',
        },
        larl => {
            name => 'Load Address Relative Long', isa_level => 'z/Arch (Arch5+)', feature => 'Core',
            encoding => 'C000 (RIL-b)', operands => '%r1, symbol',
            semantics => 'PC-relative +/-4 GiB address load to halfword-aligned symbol/GOT/literal pool.',
            notes => 'Core of PIC/baseless s390x ELF64 code.',
        },
        lmg => {
            name => 'Load Multiple (64-bit)', isa_level => 'z/Arch (Arch5+)', feature => 'Core',
            encoding => 'EB04 (RSY-a)', operands => '%r6, %r15, D2(%r15)',
            semantics => 'Restores contiguous 64-bit callee-saved register range in one instruction.',
            notes => 'Standard s390x ELF64 epilogue paired with br %r14.',
        },
        stmg => {
            name => 'Store Multiple (64-bit)', isa_level => 'z/Arch (Arch5+)', feature => 'Core',
            encoding => 'EB24 (RSY-a)', operands => '%r6, %r15, 48(%r15)',
            semantics => 'Saves contiguous 64-bit registers into caller-allocated 160-byte register save area.',
            notes => 'Standard s390x ELF64 prologue.',
        },
        brasl => {
            name => 'Branch Relative and Save Long', isa_level => 'z/Arch (Arch5+)', feature => 'Branch',
            encoding => 'C005 (RIL-b)', operands => '%r14, target',
            semantics => 'PC-relative subroutine call (+/-4 GiB) saving return address in %r14.',
            notes => 'Standard Linux s390x direct function call.',
        },
        csg => {
            name => 'Compare and Swap (64-bit Atomic)', isa_level => 'z/Arch (Arch5+)', feature => 'Atomic',
            encoding => 'EB30 (RSY-a)', operands => '%r1, %r3, D2(%b2)',
            semantics => 'Atomically compares 64-bit storage against %r1; if equal stores %r3 (CC=0), else loads storage into %r1 (CC=1). Full serialization.',
            notes => 'Storage must be 8-byte aligned; single-instruction CAS with full barrier.',
        },
        cdsg => {
            name => 'Compare Double and Swap (128-bit Atomic)', isa_level => 'z/Arch (Arch5+)', feature => 'Atomic',
            encoding => 'EB3E (RSY-a)', operands => '%r1, %r3, D2(%b2)',
            semantics => 'Atomic 128-bit quadword CAS on even/odd register pairs (%r1/%r1+1 expected, %r3/%r3+1 desired). Requires 16-byte alignment.',
            notes => 'Used for ABA-safe lock-free stacks/queues on IBM Z.',
        },
        laa => {
            name => 'Load and Add (32-bit Atomic Fetch-Add)', isa_level => 'z196+ (Arch9+)', feature => 'Atomic',
            encoding => 'EBF8 (RSY-a)', operands => '%r1, %r3, D2(%b2)',
            semantics => 'Lock-free atomic 32-bit fetch-and-add (%r1 <- old, mem += %r3); see laag (EBE8) for 64-bit.',
            notes => 'Outperforms CS spin loops under high multi-drawer contention on IBM Z.',
        },
        laag => {
            name => 'Load and Add (64-bit Atomic Fetch-Add)', isa_level => 'z196+ (Arch9+)', feature => 'Atomic',
            encoding => 'EBE8 (RSY-a)', operands => '%r1, %r3, D2(%b2)',
            semantics => 'Lock-free atomic 64-bit fetch-and-add on doubleword-aligned storage.',
            notes => 'Interlocked-Access Facility 1.',
        },
        vlm => {
            name => 'Vector Load Multiple', isa_level => 'z13+ (VX / Arch11)', feature => 'VX/VXE2',
            encoding => 'E736 (VRS-a)', operands => '%v1, %v3, D2(%b2)[, M4]',
            semantics => 'Loads consecutive 128-bit vector registers %v1..%v3 from storage.',
            notes => '32 vector registers %v0..%v31; %v0..%v15 high 64 bits alias FPRs %f0..%f15.',
        },
        vstm => {
            name => 'Vector Store Multiple', isa_level => 'z13+ (VX / Arch11)', feature => 'VX/VXE2',
            encoding => 'E73E (VRS-a)', operands => '%v1, %v3, D2(%b2)[, M4]',
            semantics => 'Stores consecutive 128-bit vector registers %v1..%v3 to storage.',
            notes => 'Specify alignment hint M4=4 for 16-byte aligned blocks.',
        },
        vfmasb => {
            name => 'Vector FP Multiply-Add Short (4x FP32 FMA)', isa_level => 'z14+ (VXE / Arch12)', feature => 'VXE/VXE2',
            encoding => 'E78F (VRR-e, M5=2)', operands => '%v1, %v2, %v3, %v4',
            semantics => '4x IEEE-754 FP32 fused multiply-add: %v1 <- (%v2 * %v3) + %v4.',
            notes => 'Extended mnemonic of VFMA; z14+ Vector Enhancements Facility 1.',
        },
        vfmadb => {
            name => 'Vector FP Multiply-Add Double (2x FP64 FMA)', isa_level => 'z13+ (VX / Arch11)', feature => 'VX/VXE2',
            encoding => 'E78F (VRR-e, M5=3)', operands => '%v1, %v2, %v3, %v4',
            semantics => '2x IEEE-754 FP64 fused multiply-add: %v1 <- (%v2 * %v3) + %v4.',
            notes => 'Extended mnemonic of VFMA; non-destructive 4-operand encoding.',
        },
        vperm => {
            name => 'Vector Permute', isa_level => 'z13+ (VX / Arch11)', feature => 'VX/VXE2',
            encoding => 'E78C (VRR-e)', operands => '%v1, %v2, %v3, %v4',
            semantics => 'Selects 16 bytes from 32-byte %v2||%v3 indexed by %v4.',
            notes => 'Non-destructive 4-operand byte shuffle.',
        },
        vsumgf => {
            name => 'Vector Sum Across Doubleword (from 32-bit Words)', isa_level => 'z13+ (VX / Arch11)', feature => 'VX/VXE2',
            encoding => 'E765 (VRR-c, M4=2)', operands => '%v1, %v2, %v3',
            semantics => 'Sums adjacent 32-bit unsigned words in %v2 with 64-bit accumulator elements in %v3 into two 64-bit lanes of %v1.',
            notes => 'Fast SIMD integer horizontal reduction on IBM Z.',
        },
        vrepf => {
            name => 'Vector Replicate Word (32-bit Broadcast)', isa_level => 'z13+ (VX / Arch11)', feature => 'VX/VXE2',
            encoding => 'E74D (VRI-c, M4=2)', operands => '%v1, %v3, I2',
            semantics => 'Replicates 32-bit lane I2 (0..3) of %v3 across all four 32-bit lanes of %v1.',
            notes => 'Broadcast helper for vector FMA loops.',
        },
        nnpa => {
            name => 'Neural Network Processing Assist (IBM Telum & Telum II On-Chip AI / Spyre DPU)', isa_level => 'z16 Telum (Arch14) & z17 Telum II (Arch15)', feature => 'NNPA/AI',
            encoding => 'B93B (RRE)', operands => '(implicit %r0=function_code, %r1=4096B parameter_block)',
            semantics => 'Executes on-chip Telum / Telum II AI matrix & activation ops (QAF, ADD, MUL, GELU, SOFTMAX, MATMUL, CONV, LSTM, GRU, LAYERNORM) on 4D stickified DLFloat16 / INT8 tensors; sets CC=3 on partial completion requiring JO re-drive loop.',
            notes => 'z16 Telum delivers 6+ TFLOPS/chip DLFloat16; z17 Telum II increases on-chip AI compute, adds INT8/GELU/LAYERNORM and pairs with PCIe Spyre AI DPU offload. Always verify feature via NNPA-QAF (GR0=0) and loop on CC=3 (jo).',
            nnpa_detail => \%NNPA_SPEC,
        },
        dfltcc => {
            name => 'Deflate Conversion Call (Hardware DEFLATE)', isa_level => 'z15+ (Arch13) / Telum / Telum II', feature => 'DFLTCC',
            encoding => 'B939 (RRF-a)', operands => '%r1, %r2, %r3 (implicit %r0=func, %r1=param_block)',
            semantics => 'On-chip RFC 1951 DEFLATE compression/decompression (QAF=0, GDHT=1, CMPR=2, XPND=4). Sets CC=3 on partial progress.',
            notes => 'Accelerates zlib/gzip/Db2/z/OS DFSMS compression up to 10-20x with minimal CPU cost; must re-drive on CC=3.',
        },
        kma => {
            name => 'Cipher Message with Authentication (CPACF AES-GCM)', isa_level => 'z14+ (MSA8 / CPACF)', feature => 'CPACF',
            encoding => 'B929 (RRF-b)', operands => '%r1, %r3, %r2 (implicit %r0=func, %r1=param_block)',
            semantics => 'Single-instruction CPACF hardware AES-128/192/256-GCM authenticated encryption/decryption; re-drive on CC=3.',
            notes => 'Zero kernel-mode transition; wire-speed TLS 1.3 and pervasive encryption on IBM Z.',
        },
        kimd => {
            name => 'Compute Intermediate Message Digest (CPACF SHA/SHA-3)', isa_level => 'z990+ (MSA/MSA6 CPACF)', feature => 'CPACF',
            encoding => 'B93E (RRE)', operands => '%r1, %r2 (implicit %r0=func, %r1=param_block)',
            semantics => 'CPACF hardware streaming SHA-1/256/512/SHA-3/GHASH over full block multiples; re-drive on CC=3.',
            notes => 'Follow with klmd for final padded block.',
        },
        klmd => {
            name => 'Compute Last Message Digest (CPACF SHA/SHA-3)', isa_level => 'z990+ (MSA/MSA6 CPACF)', feature => 'CPACF',
            encoding => 'B93F (RRE)', operands => '%r1, %r2 (implicit %r0=func, %r1=param_block)',
            semantics => 'Finalizes CPACF hardware digest with length/padding in hardware; re-drive on CC=3.',
            notes => 'Supports SHA-256, SHA-512, SHA3-256/512, SHAKE128/256.',
        },
        km => {
            name => 'Cipher Message (CPACF AES/TDES)', isa_level => 'z990+ (MSA CPACF)', feature => 'CPACF',
            encoding => 'B92E (RRE)', operands => '%r1, %r2 (implicit %r0=func, %r1=param_block)',
            semantics => 'CPACF hardware symmetric block cipher (AES-ECB/XTS, TDES); re-drive on CC=3.',
            notes => 'Paired with protected-key (EP11/CCA) wrapped keys so raw key material never enters clear RAM.',
        },
        'bcr 14,0' => {
            name => 'Fast-BCR Serialization (Acquire/Release Fence)', isa_level => 'z196+ (Arch9+)', feature => 'Memory Ordering',
            encoding => '07E0 (RR)', operands => '14, 0',
            semantics => 'Lightweight Store-Load serialization (orders prior stores before subsequent loads without full pipeline flush of bcr 15,0).',
            notes => 's390x has strong TSO-like memory ordering; bcr 14,0 is the canonical fast seq_cst fence on z196 through z17 Telum II.',
        },
        'bcr 15,0' => {
            name => 'Full-BCR Serialization', isa_level => 'z/Arch (all)', feature => 'Memory Ordering',
            encoding => '07F0 (RR)', operands => '15, 0',
            semantics => 'Full CPU checkpoint synchronization and storage serialization.',
            notes => 'Prefer bcr 14,0 (fast-BCR) on z196+ when full checkpoint sync is unnecessary.',
        },
        stckf => {
            name => 'Store Clock Fast', isa_level => 'z9+ (Arch7+)', feature => 'Timer',
            encoding => 'B27C (S)', operands => 'D2(%b2)',
            semantics => 'Stores 64-bit TOD clock (bit 51 = 1 microsecond, ~244 ps resolution) without global uniqueness serialization.',
            notes => 'Low-overhead monotonic user-space timing instruction on IBM Z.',
        },
        lrvg => {
            name => 'Load Reversed (64-bit Byte Swap)', isa_level => 'z/Arch (Arch5+)', feature => 'Bitmanip',
            encoding => 'E30F (RXY-a)', operands => '%r1, D2(%x2,%b2)',
            semantics => 'Loads 64-bit little-endian value from storage and byte-swaps into big-endian %r1 (lrvgr %r1,%r2 for register-to-register swap).',
            notes => 'Zero-overhead endian conversion when reading x86/PCIe/network structures on s390x.',
        },
        popcnt => {
            name => 'Population Count (s390x)', isa_level => 'z196 (per-byte) / z15 (M3=8 full 64-bit)', feature => 'Bitmanip',
            encoding => 'B9E1 (RRF-c)', operands => '%r1, %r2[, M3]',
            semantics => 'With M3=8 (z15+ Misc-Inst-Ext 3), counts total 1-bits across all 64 bits of %r2 into %r1; M3=0 counts per byte.',
            notes => 'On pre-z15 hardware (M3=0), follow with horizontal byte sum.',
        },
        pfd => {
            name => 'Prefetch Data', isa_level => 'z10+ (Arch8+)', feature => 'Cache',
            encoding => 'E336 (RXY-b)', operands => 'M1, D2(%x2,%b2)',
            semantics => 'Prefetches 256-byte IBM Z cache line (M1=1 read, M1=2 write intent).',
            notes => 'IBM Z cache lines are 256 bytes (4x x86 64-byte lines).',
        },
    },
);

# Exact ABI Calling Conventions (8 ABIs across all 4 ISAs + z/OS)
my %ABIS = (
    power_elfv2 => {
        abi               => 'power_elfv2',
        arch              => 'ppc64le',
        platform          => 'Linux POWER8/9/10 Little-Endian (OpenPOWER 64-Bit ELFv2 ABI)',
        int_arg_regs      => [qw(r3 r4 r5 r6 r7 r8 r9 r10)],
        fp_vec_arg_regs   => [qw(f1..f13 v2..v13)],
        return_regs       => 'r3:r4 (up to 128-bit int/struct), f1..f4 (FP/HFA), v2 (vector)',
        callee_saved      => [qw(r14..r31 cr2..cr4 f14..f31 v20..v31)],
        caller_saved      => [qw(r0 r3..r12 lr ctr xer cr0..cr1 cr5..cr7 f0..f13 v0..v19 acc0..acc7)],
        reserved_regs     => { r1 => 'Stack pointer (16B aligned)', r2 => 'TOC pointer (must save at 24(r1) across external calls)', r13 => 'Thread-local storage (TLS) pointer (do not modify)' },
        stack_pointer     => 'r1',
        frame_pointer     => 'r31 (optional)',
        link_reg          => 'lr (saved at caller +16(r1))',
        stack_align_bytes => 16,
        red_zone_bytes    => 288,
        save_area_bytes   => '32-byte minimum frame header (0:back-chain, 8:CR, 16:LR, 24:TOC save slot)',
        pic_toc           => 'Dual entry points: Global Entry (+0) computes r2 = r12 + (.TOC.-fn) via addis/addi (caller must place target addr in r12); Local Entry (+8) assumes caller shares TOC. POWER10 @notoc uses PC-relative paddi/plxv without r2.',
        critical_hazards  => [
            'Clobbering r2 without restoring ld r2,24(r1) after indirect/external calls (bctrl / bl fn; nop) crashes on next TOC access.',
            'Modifying r13 corrupts glibc TLS.',
            'Weak memory model: LL/SC atomics require lwsync/isync barriers.',
        ],
    },
    sysv_amd64 => {
        abi               => 'sysv_amd64',
        arch              => 'amd64',
        platform          => 'Linux / BSD / macOS x86_64 (System V AMD64 ABI)',
        int_arg_regs      => [qw(rdi rsi rdx rcx r8 r9)],
        fp_vec_arg_regs   => [qw(xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7)],
        return_regs       => 'rax:rdx (int/128-bit), xmm0:xmm1 (FP/SSE)',
        callee_saved      => [qw(rbx rbp r12 r13 r14 r15 rsp)],
        caller_saved      => [qw(rax rcx rdx rsi rdi r8..r11 xmm0..xmm15 ymm0..ymm15 zmm0..zmm31 k0..k7 tmm0..tmm7)],
        reserved_regs     => { rsp => 'Stack pointer (16B aligned before call, 16n+8 on callee entry)', fs_gs => 'TLS segment base (fs on Linux, gs on macOS)' },
        stack_pointer     => 'rsp',
        frame_pointer     => 'rbp (optional, recommended for perf/unwinding)',
        link_reg          => 'return address pushed on stack by call',
        stack_align_bytes => 16,
        red_zone_bytes    => 128,
        save_area_bytes   => '0 bytes (leaf functions may use 128B below rsp without adjusting rsp)',
        pic_toc           => 'RIP-relative addressing ([rip + sym@GOTPCREL]); AL holds count of XMM vector args (0..8) on variadic calls.',
        critical_hazards  => [
            'Forgetting vzeroupper after YMM/ZMM AVX instructions before calling SSE code causes severe AVX-SSE transition stalls.',
            'Forgetting tilerelease after Intel AMX instructions leaves 8 KiB tile state dirty.',
            'Stack must be 16-byte aligned before call (aligned vmovaps on rsp will #GP fault otherwise).',
        ],
    },
    win64 => {
        abi               => 'win64',
        arch              => 'amd64',
        platform          => 'Windows x64 (Microsoft x64 Calling Convention)',
        int_arg_regs      => [qw(rcx rdx r8 r9)],
        fp_vec_arg_regs   => [qw(xmm0 xmm1 xmm2 xmm3)],
        return_regs       => 'rax (int/ptr), xmm0 (FP/vec)',
        callee_saved      => [qw(rbx rbp rdi rsi r12 r13 r14 r15 rsp xmm6..xmm15)],
        caller_saved      => [qw(rax rcx rdx r8..r11 xmm0..xmm5 ymm_upper zmm_upper)],
        reserved_regs     => { rsp => 'Stack pointer (16B aligned)', gs => 'TEB (Thread Environment Block)' },
        stack_pointer     => 'rsp',
        frame_pointer     => 'rbp (optional; SEH unwind metadata required in .pdata/.xdata)',
        link_reg          => 'return address on stack',
        stack_align_bytes => 16,
        red_zone_bytes    => 0,
        save_area_bytes   => '32-byte mandatory caller-allocated shadow space (home space) even for 0-arg calls.',
        pic_toc           => 'RIP-relative addressing; integer and FP arg slots share positions 1..4 (e.g. arg1 int in rcx, arg2 double in xmm1).',
        critical_hazards  => [
            'xmm6..xmm15 (lower 128 bits) are callee-saved on Win64 unlike SysV amd64.',
            '0-byte red zone (asynchronous interrupts/SEH clobber below rsp).',
            'Caller must always allocate 32 bytes of shadow space before call.',
        ],
    },
    aapcs64 => {
        abi               => 'aapcs64',
        arch              => 'arm64',
        platform          => 'Linux / BSD AArch64 (ARM Procedure Call Standard AAPCS64)',
        int_arg_regs      => [qw(x0 x1 x2 x3 x4 x5 x6 x7)],
        fp_vec_arg_regs   => [qw(v0 v1 v2 v3 v4 v5 v6 v7)],
        return_regs       => 'x0:x1 (int, x8 indirect result ptr), v0..v3 (FP/HFA)',
        callee_saved      => [qw(x19..x28 x29 x30 d8..d15)],
        caller_saved      => [qw(x0..x17 v0..v7 v16..v31 z0..z31 p0..p15)],
        reserved_regs     => { sp => 'Stack pointer (hardware-enforced 16B alignment)', x18 => 'Platform register (reserved on Darwin/Windows/Android SCS; scratch on generic Linux)', x29 => 'Frame pointer', x30 => 'Link register' },
        stack_pointer     => 'sp',
        frame_pointer     => 'x29',
        link_reg          => 'x30 (lr)',
        stack_align_bytes => 16,
        red_zone_bytes    => 0,
        save_area_bytes   => '0 bytes (callee saves x29/x30 via stp x29,x30,[sp,#-16]!)',
        pic_toc           => 'PC-relative adrp + add/ldr :got:sym (+/-4 GiB); only lower 64 bits (d8..d15) of v8..v15 are callee-saved.',
        critical_hazards  => [
            'Only lower 64 bits (d8..d15) of v8..v15 are callee-saved; upper 64 bits of v8..v15 and all of SVE z8..z15 above bit 63 are caller-saved.',
            'Dereferencing a non-16-byte-aligned sp triggers an immediate hardware SP alignment fault.',
            'Weak memory model: pair lock-free code with LSE acquire/release (casal/ldaddal) or dmb ish.',
        ],
    },
    darwin_arm64 => {
        abi               => 'darwin_arm64',
        arch              => 'arm64',
        platform          => 'macOS / iOS Apple Silicon (Apple Darwin ARM64 ABI)',
        int_arg_regs      => [qw(x0 x1 x2 x3 x4 x5 x6 x7)],
        fp_vec_arg_regs   => [qw(v0 v1 v2 v3 v4 v5 v6 v7)],
        return_regs       => 'x0:x1 (int, x8 indirect result), v0..v3 (FP/HFA)',
        callee_saved      => [qw(x19..x28 x29 x30 d8..d15)],
        caller_saved      => [qw(x0..x17 v0..v7 v16..v31)],
        reserved_regs     => { sp => '16B aligned SP', x18 => 'Reserved by Apple Darwin kernel/platform; do not read or write x18/w18', x29 => 'Mandatory valid frame pointer chain for Instruments/crash unwind' },
        stack_pointer     => 'sp',
        frame_pointer     => 'x29 (required)',
        link_reg          => 'x30 (PAC-signed on arm64e via pacibsp/autibsp)',
        stack_align_bytes => 16,
        red_zone_bytes    => 128,
        save_area_bytes   => '0 bytes (128-byte leaf red zone permitted on Darwin arm64)',
        pic_toc           => 'PC-relative adrp + add @PAGE/@PAGEOFF; variadic arguments are passed on the stack (not in x0..x7).',
        critical_hazards  => [
            'x18 is reserved by Darwin; clobbering x18/w18 causes silent corruption or crashes.',
            'Variadic arguments go on the stack (unlike Linux AAPCS64 where they go in registers); C prototype mismatches break variadic calls.',
            'Small stack-passed arguments (<8B) are tightly packed on stack rather than padded to 8B.',
        ],
    },
    s390x_elf64 => {
        abi               => 's390x_elf64',
        arch              => 's390x',
        platform          => 'Linux on IBM Z (s390x ELF64 ABI, z13..z17 Telum II)',
        int_arg_regs      => [qw(r2 r3 r4 r5 r6)],
        fp_vec_arg_regs   => [qw(f0 f2 f4 f6 v24..v31)],
        return_regs       => 'r2 (int/ptr), f0 (FP), v24 (vector)',
        callee_saved      => [qw(r6..r13 r15 f8..f15)],
        caller_saved      => [qw(r0..r5 r14 f0..f7 v0..v31_note)],
        reserved_regs     => { r15 => 'Stack pointer (points to 160-byte caller-allocated register save area)', r14 => 'Return address', r12 => 'GOT pointer (legacy PIC)', a0_a1 => 'Access registers AR0:AR1 hold 64-bit TLS thread pointer' },
        stack_pointer     => 'r15',
        frame_pointer     => 'r11 (optional)',
        link_reg          => 'r14 (saved at 112(r15))',
        stack_align_bytes => 8,
        red_zone_bytes    => 0,
        save_area_bytes   => '160-byte mandatory caller-allocated register save area at 0(r15) (r6..r15 saved at 48..120(r15))',
        pic_toc           => 'Baseless PC-relative larl / brasl; note r6 is both an integer arg register and callee-saved. Only high 64 bits of v8..v15 (aliasing f8..f15) are callee-saved.',
        critical_hazards  => [
            'r6 is both the 5th integer parameter and callee-saved; functions modifying r6 must save/restore it.',
            'v0..v15 alias f0..f15 in their upper 64 bits; clobbering v8..v15 without saving f8..f15 breaks ABI.',
            'Always loop on CC=3 (jo) after NNPA, DFLTCC, KMA, KIMD, or KLMD.',
        ],
    },
    zos_standard => {
        abi               => 'zos_standard',
        arch              => 's390x',
        platform          => 'IBM z/OS Standard Linkage (OS / 31-bit F1SA & 64-bit F4SA)',
        int_arg_regs      => [qw(r1_plist_ptr)],
        fp_vec_arg_regs   => [qw(f0 f2 f4 f6)],
        return_regs       => 'r15 (return code), r0 (reason/value)',
        callee_saved      => [qw(r2..r13)],
        caller_saved      => [qw(r0 r1 r14 r15)],
        reserved_regs     => { r1 => 'Address of parameter list (high bit X\'80\' flags last 31-bit parm)', r12 => 'LE Common Anchor Area (CAA) / code base', r13 => 'Caller save area pointer (72B F1SA or 144B F4SA)', r14 => 'Return address', r15 => 'Entry point on call / RC on exit' },
        stack_pointer     => 'r13 (linked chain of save areas; not a contiguous stack)',
        frame_pointer     => 'r13',
        link_reg          => 'r14 (BR 14 return)',
        stack_align_bytes => 8,
        red_zone_bytes    => 0,
        save_area_bytes   => '72-byte F1SA (31-bit: STM 14,12,12(13)) or 144-byte F4SA (64-bit: STMG 14,12,8(13), eyecatcher "F4SA" at +4)',
        pic_toc           => 'Baseless relative instructions (LARL/BRASL/BRC) preferred; caller provides save area in R13, callee chains forward/backward pointers.',
        critical_hazards  => [
            'Must not clobber R13 without chaining caller/callee save areas (abends S0C4 on return).',
            'R0 cannot serve as a base or index register.',
            'Mixing 31-bit STM 14,12,12(13) into a 64-bit caller without preserving high halves corrupts AMODE 64 callers.',
        ],
    },
    zos_xplink => {
        abi               => 'zos_xplink',
        arch              => 's390x',
        platform          => 'IBM z/OS XPLINK / XPLINK-64 (High-Performance C/C++/LE Linkage)',
        int_arg_regs      => [qw(r1 r2 r3)],
        fp_vec_arg_regs   => [qw(f0 f2 f4 f6 v24..v31)],
        return_regs       => 'r3 (int/ptr; r1..r3 for struct), f0 (FP)',
        callee_saved      => [qw(r4 r8..r15)],
        caller_saved      => [qw(r0 r1 r2 r3 r5 r6 r7)],
        reserved_regs     => { r4 => 'Downward-growing stack pointer (with 2048-byte bias)', r5 => 'Environment / WSA pointer', r6 => 'Entry point address', r7 => 'Return address (branch back to 2(r7) or 4(r7))' },
        stack_pointer     => 'r4 (downward-growing with +2048B bias)',
        frame_pointer     => 'r4 (or r8 for alloca)',
        link_reg          => 'r7',
        stack_align_bytes => 16,
        red_zone_bytes    => 0,
        save_area_bytes   => 'Caller-provided downward stack frame biased by 2048 bytes (guard page triggers LE stack extension)',
        pic_toc           => 'Writable Static Area (WSA) pointer passed in r5; lower call overhead than standard OS linkage for fine-grained C/C++/Metal-C calls.',
        critical_hazards  => [
            'Stack pointer is R4 (not R15 or R13) and carries a +2048-byte bias.',
            'Return register is R7 (not R14) and integer return value is in R3 (not R15).',
            'Calling standard OS linkage from XPLINK requires an explicit OS_UPSTACK / __osplist transition.',
        ],
    },
);

# Cross-Architecture Idiom Translation Matrix (10 idioms x 4 ISAs)
my %IDIOMS = (
    fence_acq_rel => {
        description => 'Acquire-Release / Full Memory Ordering Fence across threads',
        ppc64le => {
            code  => "lwsync                 # Acquire/Release (Load-Load, Load-Store, Store-Store)\n# hwsync               # Full seq_cst (also orders Store-Load)",
            notes => 'POWER is weakly ordered; lwsync is cumulative acq/rel, hwsync (sync 0) is full seq_cst.',
        },
        amd64 => {
            code  => "# compiler barrier only for acq/rel under x86-TSO\nmfence                 # Full seq_cst (or: lock add qword ptr [rsp], 0)",
            notes => 'x86-TSO gives acquire/release on ordinary loads/stores; only Store-Load requires mfence or a locked RMW.',
        },
        arm64 => {
            code  => "dmb ish                // Full inner-shareable fence (acq/rel + seq_cst)\n// dmb ishld           // Load-Load / Load-Store only",
            notes => 'ARM64 is weakly ordered; prefer acquire/release instructions (ldar/stlr) or dmb ish.',
        },
        s390x => {
            code  => "bcr 14, 0              # Fast-BCR serialization (z196..z17 Telum II)\n# bcr 15, 0            # Full serialization",
            notes => 'IBM Z is strongly ordered (TSO-like); bcr 14,0 orders prior stores before subsequent loads with minimal overhead.',
        },
    },
    atomic_cas => {
        description => '64-bit Atomic Compare-And-Swap (Acquire-Release)',
        ppc64le => {
            code  => "lwsync\n1: ldarx  r6, 0, r3    # load & reserve *ptr\n   cmpd   r6, r4       # compare with expected\n   bne-   2f\n   stdcx. r5, 0, r3    # conditional store desired\n   bne-   1b\n   isync\n2:",
            notes => 'LL/SC loop with leading lwsync (release) and trailing isync (acquire).',
        },
        amd64 => {
            code  => "mov rax, rsi           ; expected in RAX\nlock cmpxchg [rdi], rdx ; *ptr == RAX ? *ptr = desired : RAX = *ptr",
            notes => 'Single-instruction CAS with implicit full sequential-consistency barrier.',
        },
        arm64 => {
            code  => "// ARMv8.1+ LSE:\ncasal x1, x2, [x0]     // *x0 == x1 ? *x0 = x2 : x1 = *x0\n// ARMv8.0 LL/SC fallback:\n// 1: ldaxr x3,[x0]; cmp x3,x1; b.ne 2f; stlxr w4,x2,[x0]; cbnz w4,1b; 2:",
            notes => 'LSE casal scales dramatically better on high-core ARM64 servers than LL/SC.',
        },
        s390x => {
            code  => "csg %r3, %r4, 0(%r2)   # *r2 == r3 ? *r2 = r4 (CC=0) : r3 = *r2 (CC=1)",
            notes => 'Single-instruction atomic 64-bit CAS with full serialization (use cdsg for 128-bit).',
        },
    },
    spin_yield => {
        description => 'Spinlock Backoff / SMT Hardware Thread Yield Hint',
        ppc64le => {
            code  => "or 27, 27, 27          # yield (extended mnemonic) — lowers SMT-8 dispatch priority\n# or 1, 1, 1           # low priority; restore with or 2, 2, 2",
            notes => 'Critical on POWER8/9/10 SMT cores so spinning thread yields pipelines to sibling threads.',
        },
        amd64 => {
            code  => "pause                  ; F3 90 — prevents memory-order pipeline nuke & yields HT",
            notes => 'Mandatory in x86_64 spin loops (~10-140 cycles depending on microarchitecture).',
        },
        arm64 => {
            code  => "yield                  // Standard ARM64 spin hint\n// isb                 // Preferred ~30-cycle backoff on Apple Silicon",
            notes => 'On Apple M1-M4, yield is a 1-cycle NOP; isb or sevl/wfe provides genuine backoff.',
        },
        s390x => {
            code  => "bcr 14, 0              # Fast-BCR pause/serialize inside spin loop (or DIAG x'44' in supervisor)",
            notes => 'Keep user-space spins brief; z/Architecture hypervisor (PR/SM) handles vCPU timeslicing.',
        },
    },
    cycle_timer => {
        description => 'Low-Overhead User-Space Monotonic High-Resolution Timer',
        ppc64le => {
            code  => "mftb r3                # mfspr r3, 268 (64-bit 512 MHz Time Base)",
            notes => 'Single instruction, synchronized across sockets, zero syscall.',
        },
        amd64 => {
            code  => "lfence\nrdtsc                  ; EDX:EAX = 64-bit invariant TSC\nshl rdx, 32\nor  rax, rdx\n; End window with: rdtscp; lfence",
            notes => 'Bracket with lfence / rdtscp to prevent out-of-order hoisting.',
        },
        arm64 => {
            code  => "isb\nmrs x0, cntvct_el0     // 64-bit virtual counter (query cntfrq_el0 for Hz)",
            notes => '24 MHz on Apple Silicon (~41.67 ns tick); isb prevents speculative hoisting.',
        },
        s390x => {
            code  => "stckf 0(%r2)           # Store Clock Fast (8B TOD; bit 51 = 1 us, ~244 ps/tick)",
            notes => 'Non-serializing fast TOD clock store (use stcke for 16B extended TOD).',
        },
    },
    fma_4x_f32 => {
        description => '4-Lane FP32 Fused Multiply-Add (acc = a * b + acc)',
        ppc64le => {
            code  => "xvmaddasp vs0, vs1, vs2  # vs0[0..3] = vs1 * vs2 + vs0 (VSX)",
            notes => '2-per-cycle 128-bit FMA on POWER8/9/10; POWER10 MMA xvf32gerpp does 16 FMAs/inst.',
        },
        amd64 => {
            code  => "vfmadd231ps xmm0, xmm1, xmm2  ; 4x FP32 (use ymm0 for 8x, zmm0 for 16x)",
            notes => 'Single-rounding FMA3; scale up to 8x (AVX2 YMM) or 16x (AVX-512 ZMM).',
        },
        arm64 => {
            code  => "fmla v0.4s, v1.4s, v2.4s      // NEON 4x FP32\n// SVE: fmla z0.s, p0/m, z1.s, z2.s",
            notes => 'Non-destructive lane-indexed form fmla v0.4s, v1.4s, v2.s[0] avoids splats.',
        },
        s390x => {
            code  => "vfmasb %v0, %v1, %v2, %v0     # VXE 4x FP32 FMA (z14..z17 Telum II)",
            notes => '4-operand non-destructive encoding (VFMA E78F with M5=2); z13 supports FP64 vfmadb.',
        },
    },
    bswap64 => {
        description => '64-Bit Byte Swap (Endianness Reversal)',
        ppc64le => {
            code  => "ldbrx r3, 0, r4        # Load 64-bit byte-reversed (POWER7+)\n# brd r3, r4           # Register-to-register 64-bit byte-reverse (POWER10 ISA 3.1)",
            notes => 'POWER8/9 use ldbrx/stdbrx on memory or xxbrd on VSR; POWER10 adds GPR brd.',
        },
        amd64 => {
            code  => "bswap rax              ; Single-cycle 64-bit byte swap (or movbe for memory)",
            notes => 'In-place register swap.',
        },
        arm64 => {
            code  => "rev x0, x0             // Single-cycle 64-bit byte swap (rev32 for 32-bit lanes)",
            notes => 'Also NEON rev64 v0.16b, v0.16b for vectorized byte swaps.',
        },
        s390x => {
            code  => "lrvgr %r2, %r2         # Register 64-bit byte swap (lrvg for memory load-reversed)",
            notes => 'Essential on big-endian s390x for little-endian wire/PCIe/file formats.',
        },
    },
    popcnt64 => {
        description => '64-Bit Population Count (Hamming Weight)',
        ppc64le => {
            code  => "popcntd r3, r3         # Single-instruction 64-bit popcount (POWER7+)",
            notes => 'Available on all POWER8/9/10 processors.',
        },
        amd64 => {
            code  => "xor eax, eax           ; Break false dependency on older Intel cores\npopcnt rax, rdi",
            notes => 'Requires POPCNT CPUID flag (universal on modern amd64).',
        },
        arm64 => {
            code  => "fmov d0, x0\ncnt  v0.8b, v0.8b      // Per-byte popcount in NEON\naddv b0, v0.8b         // Horizontal sum across 8 bytes\numov w0, v0.b[0]       // (ARMv8.9 CSSC adds scalar cnt x0, x0)",
            notes => 'Vectorized cnt works on 16 bytes at once for bitset scans.',
        },
        s390x => {
            code  => "popcnt %r2, %r2, 8     # z15+ (M3=8 full 64-bit popcount; pre-z15 M3=0 is per-byte)",
            notes => 'On z15 / z16 Telum / z17 Telum II, M3=8 computes the total 64-bit popcount directly.',
        },
    },
    prefetch_read => {
        description => 'Software Read Prefetch into L1 Data Cache',
        ppc64le => {
            code  => "dcbt 0, r3             # Prefetch 128-byte cache line into L1d",
            notes => 'POWER cache line = 128B; TH field enables hardware stream prefetch hints.',
        },
        amd64 => {
            code  => "prefetcht0 [rdi]       ; Prefetch 64-byte cache line into L1/L2/L3",
            notes => 'Use prefetchnta for streaming data to avoid cache pollution.',
        },
        arm64 => {
            code  => "prfm pldl1keep, [x0]   // Prefetch cache line (64B Neoverse / 128B Apple Silicon)",
            notes => 'Use pldl1strm for non-temporal streams.',
        },
        s390x => {
            code  => "pfd 1, 0(%r2)          # Prefetch 256-byte IBM Z cache line for read (M1=2 write)",
            notes => 'IBM Z cache line = 256B.',
        },
    },
    matrix_gemm_tile => {
        description => 'Hardware Matrix Tile Multiply-Accumulate (AI / HPC GEMM Accelerator)',
        ppc64le => {
            code  => "xxsetaccz 0            # Zero 512-bit MMA accumulator ACC0 (POWER10)\nxvf32gerpp 0, vs32, vs33 # 4x4 FP32 outer product (or xvf16ger2pp / xvi8ger4pp)\nxxmfacc   0            # Move ACC0 back to vs0..vs3",
            notes => 'POWER10 on-core MMA engine: 8 accumulators x 4x4 FP32 tiles.',
        },
        amd64 => {
            code  => "ldtilecfg [rdi]        ; Configure TMM0..TMM7 (Intel AMX)\ntileloadd tmm1, [rsi + rdx*1]\ntileloadd tmm2, [rcx + r8*1]\ntdpbf16ps tmm0, tmm1, tmm2 ; 16x32 BF16 x 32x16 BF16 -> 16x16 FP32\ntilestored [r9 + r10*1], tmm0\ntilerelease",
            notes => 'Intel AMX (Sapphire Rapids+): 1 KiB tiles, 1024 BF16 FMAs per instruction.',
        },
        arm64 => {
            code  => "bfmmla v0.4s, v1.8h, v2.8h // ARMv8.6 2x4 x 4x2 BF16 -> 2x2 FP32\n// ARMv9 SME: fmopa za0.s, p0/m, p1/m, z0.s, z1.s",
            notes => 'Apple M4 adds ARMv9 SME ZA matrix tiles; Neoverse V1/V2 provide bfmmla/smmla.',
        },
        s390x => {
            code  => "lghi %r0, 0x71         # NNPA-MATMUL-OP (IBM z16 Telum & z17 Telum II)\nlarl %r1, nnpa_pb      # 4096B parameter block w/ DLFloat16 or INT8 4D stick tensors\n1: nnpa                # B93B on-chip AI accelerator (or Spyre DPU on z17)\n   jo   1b             # Mandatory CC=3 partial-completion re-drive loop",
            notes => 'On-chip Telum / Telum II AI matrix accelerator with direct L2/virtual-cache coherence.',
        },
    },
    atomic_fetch_add => {
        description => '64-Bit Atomic Fetch-And-Add (Acquire-Release)',
        ppc64le => {
            code  => "lwsync\n1: ldarx  r5, 0, r3\n   add    r6, r5, r4\n   stdcx. r6, 0, r3\n   bne-   1b\n   isync",
            notes => 'Returns old value in r5; POWER9+ also adds AMO ldat/stdat for select operations.',
        },
        amd64 => {
            code  => "mov rax, rsi\nlock xadd [rdi], rax   ; *ptr += rsi; RAX = old value",
            notes => 'Single-instruction atomic fetch-add with full barrier.',
        },
        arm64 => {
            code  => "ldaddal x1, x0, [x2]   // LSE atomic fetch-add: x0 = old, *x2 += x1 (acq-rel)",
            notes => 'ARMv8.1+ LSE single-instruction atomic.',
        },
        s390x => {
            code  => "laag %r2, %r3, 0(%r4)  # EBE8 atomic 64-bit fetch-add: r2 = old, *r4 += r3",
            notes => 'z196+ Interlocked-Access Facility 1.',
        },
    },
);

sub meta {
    return {
        name             => 'asm',
        label            => 'Multi-ISA Assembly (POWER8+/9/10, amd64, arm64, s390x Telum II)',
        category         => 'assembly',
        version          => $VERSION,
        description      => 'Unified 4-ISA assembly reference, ABI guide, static hazard analyzer, cross-arch idiom translator, and LSP provider for POWER8+/9/10 (ppc64le VSX/MMA), amd64 (AVX-512/AMX/BMI2), arm64 (NEON/SVE2/LSE/Darwin), and s390x (z16 Telum & z17 Telum II NNPA/DFLTCC/CPACF).',
        filetypes        => [qw(asm s S ppc64le amd64 x86_64 arm64 aarch64 s390x)],
        upstream_credits => [
            'bergercookie/asm-lsp (BSD-2-Clause)',
            'IBM Power ISA 2.07B / 3.0B / 3.1',
            'IBM z/Architecture Principles of Operation (z16 Telum / z17 Telum II)',
            'Intel 64 and IA-32 Software Developer Manual',
            'ARMv8/v9 AArch64 Architecture Reference Manual',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'asm_isa_lookup',
            description => 'Look up assembly instructions across all 4 architectures: POWER8/9/10 ppc64le (VSX/MMA/prefixed), amd64 (SSE2/AVX2/AVX-512/Intel AMX/BMI2), arm64 (NEON/SVE2/LSE/PAC), and s390x (IBM Z through z16 Telum & z17 Telum II NNPA B93B, DFLTCC B939, CPACF KMA/KIMD/KLMD).',
            inputSchema => {
                type       => 'object',
                properties => {
                    mnemonic => { type => 'string', description => 'Instruction mnemonic (e.g. xvf32gerpp, tdpbf16ps, ldaddal, nnpa, dfltcc, lwsync, vfmadd231ps).' },
                    arch     => { type => 'string', description => 'Target ISA: ppc64le, amd64, arm64, s390x, or all (default all).' },
                    query    => { type => 'string', description => 'Keyword search across names, features, and semantics.' },
                    feature  => { type => 'string', description => 'Optional feature filter (e.g. MMA, VSX, AMX, AVX-512, SVE, LSE, NNPA, CPACF).' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->isa_lookup($args || {});
            },
        },
        {
            name        => 'asm_abi_calling_conv',
            description => 'Return exact register tables, arg/return regs, callee/caller-saved sets, stack/red-zone/save-area rules, PIC/TOC conventions, and ABI hazards for POWER ELFv2, SysV amd64, Win64, AAPCS64, Apple Darwin arm64 (x18 reserved), s390x ELF64 Linux, and z/OS Standard & XPLINK.',
            inputSchema => {
                type       => 'object',
                properties => {
                    abi => { type => 'string', description => 'ABI identifier: power_elfv2, sysv_amd64, win64, aapcs64, darwin_arm64, s390x_elf64, zos_standard, zos_xplink, or all.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->abi_calling_conv($args->{abi} // 'all');
            },
        },
        {
            name        => 'asm_analyze_snippet',
            description => 'Statically analyze an assembly or objdump snippet across POWER8+, amd64, arm64, or s390x: count scalar/vector/matrix/barrier instructions, measure register usage, and detect ABI & memory-barrier traps (missing lwsync/dmb ish, missing vzeroupper, Darwin x18 clobber, POWER r2 TOC clobber, s390x r13/r14/r15 linkage & NNPA CC=3 loop).',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'Assembly or objdump snippet to analyze.' },
                    arch => { type => 'string', description => 'Optional ISA hint (ppc64le, amd64, arm64, s390x); auto-detected if omitted.' },
                    abi  => { type => 'string', description => 'Optional ABI context (e.g. darwin_arm64, power_elfv2, s390x_elf64, zos_standard).' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->analyze_snippet(
                    code => $args->{code} // '',
                    arch => $args->{arch},
                    abi  => $args->{abi},
                );
            },
        },
        {
            name        => 'asm_cross_arch_translate',
            description => 'Translate low-level systems/SIMD/AI idioms (fence_acq_rel, atomic_cas, spin_yield, cycle_timer, fma_4x_f32, bswap64, popcnt64, prefetch_read, matrix_gemm_tile, atomic_fetch_add) side-by-side across POWER8+ <-> amd64 <-> arm64 <-> s390x (Telum II).',
            inputSchema => {
                type       => 'object',
                properties => {
                    idiom => { type => 'string', description => 'Idiom name (e.g. fence_acq_rel, atomic_cas, spin_yield, cycle_timer, fma_4x_f32, bswap64, popcnt64, prefetch_read, matrix_gemm_tile, atomic_fetch_add) or "all".' },
                    arches => { type => 'array', items => { type => 'string' }, description => 'Optional subset of architectures to include.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->cross_arch_translate($args || {});
            },
        },
    ];
}

# --- Architecture Name Normalizer ---

sub _norm_arch {
    my ($raw) = @_;
    return '' unless defined $raw && length $raw;
    my $a = lc($raw);
    $a =~ s/^\s+|\s+$//g;
    return 'ppc64le' if $a =~ /^(?:ppc|ppc64|ppc64le|power|power8|power9|power10)$/;
    return 'amd64'   if $a =~ /^(?:amd64|x86_64|x64|x86|intel)$/;
    return 'arm64'   if $a =~ /^(?:arm64|aarch64|arm|apple_silicon|darwin_arm64)$/;
    return 's390x'   if $a =~ /^(?:s390x|s390|zarch|z16|z17|telum|telum2|ibmz)$/;
    return 'all'     if $a eq 'all';
    return $a;
}

# --- Tool 1: 4-ISA Instruction Lookup ---

sub isa_lookup {
    my ($self, $args) = @_;
    $args ||= {};
    my $mnem    = defined $args->{mnemonic} ? lc($args->{mnemonic}) : '';
    my $arch    = _norm_arch($args->{arch} // 'all');
    my $query   = defined $args->{query}   ? lc($args->{query})   : '';
    my $feature = defined $args->{feature} ? lc($args->{feature}) : '';

    $mnem =~ s/^\s+|\s+$//g;
    my @arches = ($arch && $arch ne 'all' && exists $ISA_DB{$arch})
        ? ($arch)
        : qw(ppc64le amd64 arm64 s390x);

    my @exact;
    my @matches;
    my $total_catalog = 0;
    $total_catalog += scalar(keys %{ $ISA_DB{$_} }) for keys %ISA_DB;

    for my $a (@arches) {
        my $tbl = $ISA_DB{$a};
        if (length $mnem && exists $tbl->{$mnem}) {
            push @exact, { arch => $a, mnemonic => $mnem, %{ $tbl->{$mnem} } };
        }
        for my $k (sort keys %$tbl) {
            my $e = $tbl->{$k};
            if (length $mnem) {
                next unless index($k, $mnem) == 0 || index($k, $mnem) >= 0;
            }
            if (length $feature) {
                my $fhay = lc("$e->{feature} $e->{isa_level} $e->{name}");
                next unless index($fhay, $feature) >= 0;
            }
            if (length $query) {
                my $hay = lc("$a $k $e->{name} $e->{isa_level} $e->{feature} $e->{encoding} $e->{operands} $e->{semantics} $e->{notes}");
                next unless index($hay, $query) >= 0;
            }
            push @matches, { arch => $a, mnemonic => $k, %$e };
        }
    }

    my $out_list = @exact ? \@exact : \@matches;
    return {
        ok           => 1,
        exact_match  => @exact ? 1 : 0,
        count        => scalar(@$out_list),
        instruction  => (@$out_list == 1 ? $out_list->[0] : undef),
        matches      => $out_list,
        catalog_size => $total_catalog,
        per_arch     => { map { $_ => scalar(keys %{ $ISA_DB{$_} }) } qw(ppc64le amd64 arm64 s390x) },
    };
}

# --- Tool 2: ABI Calling Conventions ---

sub abi_calling_conv {
    my ($self, $abi_req) = @_;
    my $key = lc($abi_req // 'all');
    $key =~ s/^\s+|\s+$//g;

    my %aliases = (
        ppc64le     => 'power_elfv2',
        power       => 'power_elfv2',
        elfv2       => 'power_elfv2',
        amd64       => 'sysv_amd64',
        x86_64      => 'sysv_amd64',
        sysv        => 'sysv_amd64',
        windows     => 'win64',
        arm64       => 'aapcs64',
        aarch64     => 'aapcs64',
        darwin      => 'darwin_arm64',
        macos       => 'darwin_arm64',
        apple_arm64 => 'darwin_arm64',
        s390x       => 's390x_elf64',
        zos         => 'zos_standard',
        xplink      => 'zos_xplink',
    );
    $key = $aliases{$key} if exists $aliases{$key};

    if (exists $ABIS{$key}) {
        return {
            ok   => 1,
            abi  => $ABIS{$key},
            abis => [ $ABIS{$key} ],
        };
    }

    return {
        ok        => 1,
        abi_count => scalar(keys %ABIS),
        abi_names => [ sort keys %ABIS ],
        abis      => [ map { $ABIS{$_} } sort keys %ABIS ],
    };
}

# --- Tool 3: Multi-ISA Assembly & Objdump Static Analyzer ---

sub _detect_arch {
    my ($code) = @_;
    return 's390x'   if $code =~ /\b(?:nnpa|dfltcc|vfmasb|vfmadb|stmg|lmg|brasl|larl|csg|cdsg|laag|stckf|kma|kimd|klmd)\b/i
                     || $code =~ /%r1[0-5]\b|%v[0-3]?\d\b/;
    return 'ppc64le' if $code =~ /\b(?:xvf32ger|xxsetaccz|xxmfacc|xvmaddasp|xvmaddadp|lxvd2x|lxv|stxv|lwsync|hwsync|ldarx|stdcx\.|lwarx|stwcx\.|mftb|bctrl|bdnz|mtctr|plxv|paddi|addis)\b/i;
    return 'arm64'   if $code =~ /\b(?:ldaddal|casal|swpal|ldxr|stxr|ldaxr|stlxr|dmb\s+ish|whilelt|ld1w|cntw|pacibsp|autibsp|cntvct_el0|bfmmla|udot|sdot|stp|ldp)\b/i
                     || $code =~ /\b(?:x[12]?\d|w[12]?\d|v\d+\.(?:4s|2d|16b|8h)|z\d+\.s)\b/i;
    return 'amd64'   if $code =~ /\b(?:vfmadd231ps|vfmadd231pd|vmovaps|vzeroupper|ldtilecfg|tdpbf16ps|tdpbssd|tilerelease|vpshufb|pext|pdep|mfence|lfence|rdtscp?|cmpxchg)\b/i
                     || $code =~ /\b(?:rax|rbx|rcx|rdx|rsi|rdi|rsp|rbp|r[89]|r1[0-5]|xmm\d+|ymm\d+|zmm\d+|tmm\d+)\b/i;
    return 'amd64';
}

sub analyze_snippet {
    my ($self, %req) = @_;
    my $code = $req{code} // '';
    my $arch = _norm_arch($req{arch});
    $arch = _detect_arch($code) if !$arch || $arch eq 'all';
    my $abi  = lc($req{abi} // '');

    my @lines = split(/\r?\n/, $code);
    my %counts = (
        total_instructions => 0,
        scalar             => 0,
        vector             => 0,
        matrix_ai          => 0,
        atomic             => 0,
        barrier            => 0,
        branch             => 0,
        memory             => 0,
    );
    my (%gprs, %vecs, %accs);
    my @findings;

    # Track per-ISA structural signals
    my $saw_power_llsc    = 0;
    my $saw_power_barrier = 0;
    my $saw_power_mma     = 0;
    my $saw_power_xxmfacc = 0;
    my $saw_power_r2_save = 0;
    my $saw_power_r2_mod  = 0;
    my $power_r2_mod_line = 0;

    my $saw_avx_wide       = 0;
    my $saw_vzeroupper     = 0;
    my $saw_amd64_ret_call = 0;
    my $avx_line           = 0;
    my $saw_amx            = 0;
    my $saw_tilerelease    = 0;
    my $amx_line           = 0;

    my $saw_arm_llsc       = 0;
    my $saw_arm_barrier    = 0;
    my $arm_llsc_line      = 0;

    my $saw_s390_stmg      = 0;
    my $saw_s390_lmg       = 0;
    my $saw_s390_cc3_op    = '';
    my $s390_cc3_line      = 0;
    my $saw_s390_cc3_loop  = 0;

    for (my $idx = 0; $idx < @lines; $idx++) {
        my $raw = $lines[$idx];
        my $ln  = $idx + 1;

        # Strip objdump address + hex bytes prefix if present (e.g. "  401000: c5 f8 77   vzeroupper")
        my $line = $raw;
        $line =~ s/^\s*[0-9a-f]+:\s+(?:[0-9a-f]{2}\s+)+//i;
        $line =~ s/^\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+//i; # 32-bit hex word objdump (arm64/ppc64le)

        # Strip comments (on arm64, '#' prefixes immediates like #0x8, so only strip //, ;, /* */, or leading #)
        $line =~ s{/\*.*?\*/}{}g;
        if ($arch eq 'arm64') {
            $line =~ s{^\s*#.*$}{};
            $line =~ s{(?://|;).*$}{};
        }
        else {
            $line =~ s{(?://|;|#).*$}{};
        }
        $line =~ s/^\s+|\s+$//g;
        next if !length($line) || $line =~ /^\./ || $line =~ /^[A-Za-z0-9_.\$]+:$/;

        # Strip inline label before instruction (e.g. "1: ldarx ...")
        $line =~ s/^[A-Za-z0-9_.\$]+:\s*//;
        next unless length $line;

        my ($op, $ops) = split(/\s+/, $line, 2);
        $op  = lc($op // '');
        $ops //= '';
        if ($op eq 'lock' && $ops =~ /^(\S+)\s*(.*)$/) {
            $op  = "lock " . lc($1);
            $ops = $2 // '';
        }

        $counts{total_instructions}++;

        # Collect registers used
        if ($arch eq 'ppc64le') {
            while ($ops =~ /\b(r(?:[0-9]|[12][0-9]|3[01]))\b/gi) { $gprs{ lc $1 } = 1; }
            while ($ops =~ /\b((?:vs|v|f)\d+)\b/gi)              { $vecs{ lc $1 } = 1; }
            if ($op =~ /^(?:xxsetaccz|xvf\d+ger|xvi\d+ger|xvbf\d+ger|xxmfacc|xxmtacc)/) {
                $accs{"acc$1"} = 1 if $ops =~ /^(\d+)/;
            }
        }
        elsif ($arch eq 'amd64') {
            while ($ops =~ /\b([re]?(?:ax|bx|cx|dx|si|di|sp|bp)|r(?:[89]|1[0-5])[dwb]?)\b/gi) { $gprs{ lc $1 } = 1; }
            while ($ops =~ /\b([xyz]mm\d+|k[0-7])\b/gi)                                       { $vecs{ lc $1 } = 1; }
            while ($ops =~ /\b(tmm[0-7])\b/gi)                                                { $accs{ lc $1 } = 1; }
        }
        elsif ($arch eq 'arm64') {
            while ($ops =~ /\b([xw](?:[0-9]|[12][0-9]|30)|sp)\b/gi) { $gprs{ lc $1 } = 1; }
            while ($ops =~ /\b([vzqd]\d+|p(?:[0-9]|1[0-5]))\b/gi)   { $vecs{ lc $1 } = 1; }
        }
        elsif ($arch eq 's390x') {
            while ($ops =~ /%?(r(?:[0-9]|1[0-5]))\b/gi) { $gprs{ lc $1 } = 1; }
            while ($ops =~ /%?([vf](?:[0-9]|[12][0-9]|3[01]))\b/gi) { $vecs{ lc $1 } = 1; }
        }

        # Categorize instruction
        if ($op =~ /^(?:xxsetaccz|xvf\d+ger|xvbf\d+ger|xvi\d+ger|xxmfacc|xxmtacc|ldtilecfg|tileloadd|tdpbf16ps|tdpbssd|tdpbuud|tdpfp16ps|tilestored|tilerelease|tilezero|bfmmla|smmla|ummla|fmopa|nnpa)$/) {
            $counts{matrix_ai}++;
        }
        elsif ($op =~ /^(?:lxv|stxv|lxvd2x|stxvd2x|lxvw4x|plxv|pstxv|xv|xx|v[a-z]|movdqu|movaps|movups|fmla|fmls|ld1|st1|tbl|udot|sdot|faddp|whilelt|ld1w|st1w|cntw|ptrue)/) {
            $counts{vector}++;
        }
        elsif ($op =~ /^(?:lwsync|hwsync|sync|isync|eieio|mfence|lfence|sfence|dmb|dsb|isb)$/ || ($op eq 'bcr' && $ops =~ /^(?:14|15)\s*,\s*0$/)) {
            $counts{barrier}++;
        }
        elsif ($op =~ /^(?:lwarx|ldarx|stwcx\.|stdcx\.|lock\s+\S+|cmpxchg|xadd|ldaddal|ldadd|casal|cas|swpal|ldxr|stxr|ldaxr|stlxr|cs|csg|cdsg|laa|laag)$/) {
            $counts{atomic}++;
        }
        elsif ($op =~ /^(?:b|bl|blr|bctrl|bdnz|bc|bne|beq|ret|call|jmp|je|jne|jg|jl|jo|jnz|jz|cbz|cbnz|brasl|br|brc|brcl|bcr)$/) {
            $counts{branch}++;
        }
        else {
            $counts{scalar}++;
        }

        if ($op =~ /^(?:ld|std|lwz|stw|lxv|stxv|lxvd2x|plxv|mov|vmov|ldr|str|ldp|stp|ld1|st1|ld1w|lg|stg|lmg|stmg|vl|vst|vlm|vstm|tileloadd|tilestored)/) {
            $counts{memory}++;
        }

        # --- Per-ISA Trap & Hazard Detection ---
        if ($arch eq 'ppc64le') {
            $saw_power_llsc    = $ln if $op =~ /^(?:lwarx|ldarx|stwcx\.|stdcx\.)$/;
            $saw_power_barrier = 1   if $op =~ /^(?:lwsync|hwsync|sync|isync)$/;
            $saw_power_mma     = $ln if $op =~ /^xv(?:f32|f16|bf16|i8|i4)ger/;
            $saw_power_xxmfacc = 1   if $op eq 'xxmfacc';
            $saw_power_r2_save = 1   if $op eq 'std' && $ops =~ /^(?:r?2)\s*,\s*24\s*\(\s*r?1\s*\)/i;
            if ($op =~ /^(?:li|lis|mr|ld|add|addi|addis|or|xor|subf)$/ && $ops =~ /^(?:r?2)\s*,/i
                && $ops !~ /\.TOC\.|24\s*\(\s*r?1\s*\)/i)
            {
                $saw_power_r2_mod  = 1;
                $power_r2_mod_line = $ln;
            }
            if ($op =~ /^(?:li|lis|mr|ld|add|addi|subf|xor)$/ && $ops =~ /^(?:r?13)\s*,/i) {
                push @findings, {
                    line => $ln, severity => 'error', code => 'ASM_POWER_R13_TLS_CLOBBER',
                    message => 'Instruction modifies r13, which is the reserved ELFv2 TLS thread pointer on ppc64le.',
                };
            }
            if ($op eq 'lxvd2x') {
                push @findings, {
                    line => $ln, severity => 'info', code => 'ASM_POWER_LXVD2X_ENDIAN',
                    message => 'lxvd2x loads doublewords in swapped lane order on ppc64le (pair with xxswapd on POWER8, or use lxv/lxvx on POWER9+).',
                };
            }
        }
        elsif ($arch eq 'amd64') {
            if ($ops =~ /\b[yz]mm\d+\b/i) {
                $saw_avx_wide = 1;
                $avx_line ||= $ln;
            }
            $saw_vzeroupper     = 1 if $op eq 'vzeroupper';
            $saw_amd64_ret_call = 1 if $op =~ /^(?:ret|call)$/;
            if ($op =~ /^(?:ldtilecfg|tileloadd|tdpbf16ps|tdpbssd|tdpbuud|tdpfp16ps|tilestored)$/) {
                $saw_amx = 1;
                $amx_line ||= $ln;
            }
            $saw_tilerelease = 1 if $op eq 'tilerelease';

            # Unaligned aligned-vector load/store check (offset not multiple of 16/32)
            if ($op =~ /^(?:v?movaps|v?movapd|v?movdqa)$/ && $ops =~ /\[\s*\w+\s*[+-]\s*(0x[0-9a-f]+|\d+)\s*\]/i) {
                my $raw_off = $1;
                my $off = ($raw_off =~ /^0x/i) ? hex($raw_off) : int($raw_off);
                my $req_align = ($ops =~ /\bzmm/i) ? 64 : ($ops =~ /\bymm/i) ? 32 : 16;
                if (($off % $req_align) != 0) {
                    push @findings, {
                        line => $ln, severity => 'error', code => 'ASM_AMD64_UNALIGNED_VEC_LOAD',
                        message => "Aligned vector op $op uses offset $off which is not $req_align-byte aligned (will raise #GP fault; use vmovups/vmovdqu).",
                    };
                }
            }
        }
        elsif ($arch eq 'arm64') {
            # Apple Darwin / Win64 reserved x18 check
            if ($ops =~ /\b[xw]18\b/i) {
                my $sev = ($abi eq 'darwin_arm64' || $abi eq '' || $abi eq 'win64') ? 'error' : 'warn';
                push @findings, {
                    line => $ln, severity => $sev, code => 'ASM_ARM64_X18_CLOBBER',
                    message => "Register x18/w18 referenced on line $ln: x18 is reserved by Apple Darwin arm64 and Windows ARM64 ABIs.",
                };
            }
            if ($op =~ /^(?:ldxr|stxr)$/) {
                $saw_arm_llsc = 1;
                $arm_llsc_line ||= $ln;
            }
            if ($op =~ /^(?:dmb|dsb|ldaxr|stlxr|ldar|stlr|casal|ldaddal|swpal)$/) {
                $saw_arm_barrier = 1;
            }
            # Non-16-byte SP adjustment check
            if ($op =~ /^(?:sub|add)$/ && $ops =~ /^sp\s*,\s*sp\s*,\s*#(0x[0-9a-f]+|\d+)/i) {
                my $raw_imm = $1;
                my $imm = ($raw_imm =~ /^0x/i) ? hex($raw_imm) : int($raw_imm);
                if (($imm % 16) != 0) {
                    push @findings, {
                        line => $ln, severity => 'error', code => 'ASM_ARM64_SP_MISALIGN',
                        message => "SP adjusted by $imm bytes (not a multiple of 16): AArch64 hardware enforces 16-byte SP alignment on memory access.",
                    };
                }
            }
        }
        elsif ($arch eq 's390x') {
            $saw_s390_stmg = 1 if $op eq 'stmg' || $op eq 'stm';
            $saw_s390_lmg  = 1 if $op eq 'lmg'  || $op eq 'lm';
            if ($op =~ /^(?:nnpa|dfltcc|kma|kimd|klmd|km|kmc)$/) {
                $saw_s390_cc3_op = uc($op);
                $s390_cc3_line   = $ln;
            }
            if ($op =~ /^(?:jo|jno|brc|brcl|bc|bcr)$/ && ($op eq 'jo' || $ops =~ /^1\s*,/)) {
                $saw_s390_cc3_loop = 1;
            }
            # Direct clobber of r13/r14/r15 without stmg/lmg save/restore
            if (!$saw_s390_stmg && $op =~ /^(?:lg|l|lgr|lr|lghi|lhi|la|larl|aghi|agr|xr|xgr)$/
                && $ops =~ /^%?r(13|14|15)\s*,/i)
            {
                my $rnum = $1;
                next if $rnum == 15 && ($op eq 'aghi' || $op eq 'lay'); # normal stack frame adjustment
                push @findings, {
                    line => $ln, severity => 'warn', code => 'ASM_S390X_LINKAGE_HAZARD',
                    message => "Instruction $op modifies linkage register %r$rnum without a prior STMG/STM save-area prologue (r13=save-area/base, r14=return addr, r15=stack pointer).",
                };
            }
        }
    }

    # Post-pass summary hazard checks
    if ($arch eq 'ppc64le') {
        if ($saw_power_llsc && !$saw_power_barrier) {
            push @findings, {
                line => $saw_power_llsc, severity => 'error', code => 'ASM_POWER_MISSING_BARRIER',
                message => 'POWER LL/SC atomic (lwarx/ldarx/stwcx./stdcx.) detected without lwsync/hwsync/isync memory barrier on weakly-ordered ppc64le.',
            };
        }
        if ($saw_power_r2_mod && !$saw_power_r2_save) {
            push @findings, {
                line => $power_r2_mod_line, severity => 'error', code => 'ASM_POWER_R2_TOC_CLOBBER',
                message => 'Register r2 (ELFv2 TOC pointer) modified without saving caller TOC to 24(r1).',
            };
        }
        if ($saw_power_mma && !$saw_power_xxmfacc) {
            push @findings, {
                line => $saw_power_mma, severity => 'warn', code => 'ASM_POWER_MMA_NO_XXMFACC',
                message => 'POWER10 MMA outer-product instruction used without xxmfacc to de-prime accumulator back into VSRs.',
            };
        }
    }
    elsif ($arch eq 'amd64') {
        if ($saw_avx_wide && $saw_amd64_ret_call && !$saw_vzeroupper) {
            push @findings, {
                line => $avx_line, severity => 'warn', code => 'ASM_AMD64_MISSING_VZEROUPPER',
                message => '256/512-bit AVX (YMM/ZMM) instructions used before ret/call without vzeroupper (risks AVX-SSE transition stall).',
            };
        }
        if ($saw_amx && !$saw_tilerelease) {
            push @findings, {
                line => $amx_line, severity => 'error', code => 'ASM_AMD64_MISSING_TILERELEASE',
                message => 'Intel AMX tile instructions used without tilerelease (leaves 8 KiB tile state active across context switches/calls).',
            };
        }
    }
    elsif ($arch eq 'arm64') {
        if ($saw_arm_llsc && !$saw_arm_barrier) {
            push @findings, {
                line => $arm_llsc_line, severity => 'error', code => 'ASM_ARM64_MISSING_DMB',
                message => 'Relaxed ARM64 LL/SC (ldxr/stxr) used without dmb ish barrier or acquire-release variants (ldaxr/stlxr or LSE casal/ldaddal).',
            };
        }
    }
    elsif ($arch eq 's390x') {
        if ($saw_s390_cc3_op && !$saw_s390_cc3_loop) {
            push @findings, {
                line => $s390_cc3_line, severity => 'error', code => 'ASM_S390X_NO_CC3_LOOP',
                message => "IBM Z accelerator/CPACF instruction $saw_s390_cc3_op invoked without a CC=3 partial-completion re-drive branch (jo / brc 1,loop).",
            };
        }
        if ($saw_s390_stmg && !$saw_s390_lmg) {
            push @findings, {
                line => 1, severity => 'warn', code => 'ASM_S390X_UNBALANCED_STMG',
                message => 'STMG prologue found without matching LMG epilogue in snippet.',
            };
        }
    }

    return {
        ok            => (grep { $_->{severity} eq 'error' } @findings) ? 0 : 1,
        arch          => $arch,
        abi           => $abi || undef,
        counts        => \%counts,
        registers     => {
            gpr         => [ sort keys %gprs ],
            vector      => [ sort keys %vecs ],
            matrix_tile => [ sort keys %accs ],
            gpr_count   => scalar(keys %gprs),
            vec_count   => scalar(keys %vecs),
        },
        finding_count => scalar(@findings),
        findings      => \@findings,
    };
}

# --- Tool 4: Cross-Arch Idiom Translator ---

sub cross_arch_translate {
    my ($self, $args) = @_;
    $args ||= {};
    my $idiom = lc($args->{idiom} // 'all');
    $idiom =~ s/^\s+|\s+$//g;

    my @target_arches = (ref($args->{arches}) eq 'ARRAY' && @{ $args->{arches} })
        ? (map { _norm_arch($_) } @{ $args->{arches} })
        : qw(ppc64le amd64 arm64 s390x);

    if (exists $IDIOMS{$idiom}) {
        my $entry = $IDIOMS{$idiom};
        my %trans = map { $_ => $entry->{$_} } grep { exists $entry->{$_} } @target_arches;
        return {
            ok           => 1,
            idiom        => $idiom,
            description  => $entry->{description},
            translations => \%trans,
        };
    }

    my @all;
    for my $k (sort keys %IDIOMS) {
        my $e = $IDIOMS{$k};
        my %trans = map { $_ => $e->{$_} } grep { exists $e->{$_} } @target_arches;
        push @all, {
            idiom        => $k,
            description  => $e->{description},
            translations => \%trans,
        };
    }

    return {
        ok          => 1,
        idiom_count => scalar(@all),
        idiom_names => [ sort keys %IDIOMS ],
        idioms      => \@all,
    };
}

# --- LSP Knowledge Hooks ---

sub _arch_from_context {
    my ($line, $lang) = @_;
    my $a = _norm_arch($lang // '');
    return $a if $a && exists $ISA_DB{$a};
    return _detect_arch($line // '') if defined $line && length $line;
    return 'all';
}

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef unless defined $word && length $word;
    my $w = lc($word);
    my $pref_arch = _arch_from_context($line, $lang);

    # Search preferred arch first, then fall back across all 4 ISAs
    my @order = ($pref_arch ne 'all' && exists $ISA_DB{$pref_arch})
        ? ($pref_arch, grep { $_ ne $pref_arch } qw(ppc64le amd64 arm64 s390x))
        : qw(ppc64le amd64 arm64 s390x);

    my @hits;
    for my $a (@order) {
        if (exists $ISA_DB{$a}{$w}) {
            push @hits, { arch => $a, %{ $ISA_DB{$a}{$w} } };
        }
    }

    if (@hits) {
        my $md = '';
        for my $h (@hits) {
            $md .= "### `$w` ($h->{arch} — $h->{name})\n\n"
                 . "- **ISA / Feature:** $h->{isa_level} (`$h->{feature}`)\n"
                 . "- **Encoding:** `$h->{encoding}`\n"
                 . "- **Operands:** `$h->{operands}`\n"
                 . "- **Semantics:** $h->{semantics}\n"
                 . "- **Notes:** $h->{notes}\n\n";
        }
        return { contents => $md, kind => 'markdown', title => "ASM $w" };
    }

    # Special ABI register hover (x18, r2, r13, r15, etc.)
    if ($w eq 'x18' || $w eq 'w18') {
        return {
            contents => "### ARM64 `$w` — Platform Register\n\nStrictly **RESERVED** on Apple Darwin (`darwin_arm64`) and Windows ARM64. Never clobber in portable arm64 assembly.\n",
            kind     => 'markdown',
            title    => "ARM64 $w",
        };
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $pfx = lc($prefix // '');
    my $a = _norm_arch($lang // '');
    my @arches = ($a && exists $ISA_DB{$a}) ? ($a) : qw(ppc64le amd64 arm64 s390x);

    my @items;
    for my $arch (@arches) {
        for my $k (sort keys %{ $ISA_DB{$arch} }) {
            next if length($pfx) && index($k, $pfx) != 0;
            my $e = $ISA_DB{$arch}{$k};
            push @items, {
                label         => $k,
                kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{keyword},
                detail        => "[$arch/$e->{feature}] $e->{name}",
                documentation => "$e->{operands} — $e->{semantics}",
            };
        }
    }
    return \@items;
}

sub lsp_diagnostics {
    my ($self, $text, $lang) = @_;
    my $arch = _norm_arch($lang // '');
    $arch = undef if !$arch || $arch eq 'all';
    my $res = $self->analyze_snippet(code => $text, arch => $arch);
    my @diags;
    for my $f (@{ $res->{findings} || [] }) {
        push @diags, $self->make_diagnostic(
            line     => ($f->{line} || 1) - 1,
            col      => 0,
            end_col  => 80,
            severity => $f->{severity},
            code     => $f->{code},
            message  => $f->{message},
            source   => 'asm',
        );
    }
    return \@diags;
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    my @lines = split(/\r?\n/, $text // '');
    my @syms;
    my %globals;

    for (my $i = 0; $i < @lines; $i++) {
        my $ln = $lines[$i];
        if ($ln =~ /^\s*\.(?:globl|global)\s+([A-Za-z_.\$][A-Za-z0-9_.\$]*)/) {
            $globals{$1} = 1;
        }
        elsif ($ln =~ /^\s*\.(?:section|text|data|rodata|bss)\b(.*)$/) {
            my $sec = $1;
            $sec =~ s/^\s+|\s+$//g;
            push @syms, $self->make_symbol(
                name   => length($sec) ? $sec : ($ln =~ /(\.\w+)/ ? $1 : '.section'),
                kind   => 'namespace',
                line   => $i,
                detail => 'ASM section',
            );
        }
        elsif ($ln =~ /^\s*([A-Za-z_][A-Za-z0-9_.\$]*):(?:\s|$)/) {
            my $lbl = $1;
            push @syms, $self->make_symbol(
                name   => $lbl,
                kind   => ($globals{$lbl} ? 'function' : 'constant'),
                line   => $i,
                detail => ($globals{$lbl} ? 'global function label' : 'label'),
            );
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::AsmMultiArch - Unified 4-ISA Assembly MCP domain pack (POWER8+/9/10, amd64, arm64, s390x Telum II)

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::AsmMultiArch;
    my $pack = NeoPerl::MCP::Pack::AsmMultiArch->new;
    my $nnpa = $pack->call_tool('asm_isa_lookup', { mnemonic => 'nnpa', arch => 's390x' });
    my $xlat = $pack->call_tool('asm_cross_arch_translate', { idiom => 'atomic_cas' });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::AsmMultiArch> provides a unified four-architecture
assembly MCP domain pack and built-in LSP knowledge engine inspired by
C<bergercookie/asm-lsp>, spanning IBM POWER8+/9/10 (C<ppc64le> VSX and
POWER10 MMA), C<amd64> (SSE2/AVX2/AVX-512/Intel AMX/BMI2), C<arm64>
(NEON/SVE2/LSE/PAC and Apple Darwin), and IBM Z C<s390x> through z16 Telum
and z17 Telum II (C<NNPA> C<B93B>, C<DFLTCC> C<B939>, and CPACF crypto).

=head1 TOOLS

=over 4

=item * C<asm_isa_lookup> - 120+ instruction catalog across C<ppc64le>,
C<amd64>, C<arm64>, and C<s390x>, including Telum / Telum II C<NNPA>
function codes and 4D DLFloat16/INT8 stick-tensor descriptor layout.

=item * C<asm_abi_calling_conv> - Exact register, stack, red-zone, save-area,
and PIC/TOC conventions for POWER ELFv2, SysV amd64, Win64, AAPCS64, Apple
Darwin arm64 (C<x18> reserved), s390x ELF64 Linux, and z/OS Standard/XPLINK.

=item * C<asm_analyze_snippet> - Counts scalar, vector, matrix/AI, atomic, and
barrier instructions and flags ABI and memory-ordering hazards across all four
architectures.

=item * C<asm_cross_arch_translate> - Side-by-side low-level idiom translator
across POWER8+, amd64, arm64, and s390x Telum II.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
