package NeoPerl::MCP::Pack::HLASM;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

our $VERSION = '0.01';

# z/Architecture Principles of Operation opcode catalog (Base z/Arch through z17 Telum II)
my %OPCODES = (
    # --- Loads & Stores (32-bit, 64-bit, Long Displacement, Relative) ---
    L => {
        name              => 'Load (32-bit)',
        opcode            => '58',
        format            => 'RX-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'load_store',
        notes             => 'Loads 32-bit fullword into bits 32-63 of GR R1; bits 0-31 unchanged. Unsigned 12-bit displacement (0..4095); use LY (E358) for 20-bit signed displacement.',
    },
    LY => {
        name              => 'Load (32-bit, Long Displacement)',
        opcode            => 'E358',
        format            => 'RXY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z990 (Long-Displacement Facility)',
        category          => 'load_store',
        notes             => 'Loads 32-bit fullword with 20-bit signed displacement (-524288..+524287). Drop-in replacement for L when displacement exceeds 4095 bytes.',
    },
    LG => {
        name              => 'Load (64-bit)',
        opcode            => 'E304',
        format            => 'RXY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Loads 64-bit doubleword into GR R1 using 20-bit signed displacement (-524288..+524287). Doubleword alignment recommended for performance.',
    },
    LGF => {
        name              => 'Load (64<-32 signed)',
        opcode            => 'E314',
        format            => 'RXY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Loads 32-bit signed integer and sign-extends into 64-bit GR R1.',
    },
    LA => {
        name              => 'Load Address',
        opcode            => '41',
        format            => 'RX-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'addressing',
        notes             => 'Computes effective address B2+X2+D2 without accessing storage. 12-bit unsigned displacement (0..4095); use LAY for 20-bit signed displacement.',
    },
    LAY => {
        name              => 'Load Address (Long Displacement)',
        opcode            => 'E371',
        format            => 'RXY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z990 (Long-Displacement Facility)',
        category          => 'addressing',
        notes             => 'Computes effective address with 20-bit signed displacement (-524288..+524287). Ideal for large DSECTs and negative stack offsets without extra base registers.',
    },
    LARL => {
        name              => 'Load Address Relative Long',
        opcode            => 'C000',
        format            => 'RIL-b',
        length_bytes      => 6,
        displacement_bits => 0,
        operands          => 'R1,RI2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'addressing',
        notes             => 'PC-relative address load (+/-4 GiB, halfword-aligned target). Eliminates code base register pressure for baseless z/Architecture programming.',
    },
    LR => {
        name              => 'Load (32-bit Register)',
        opcode            => '18',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'load_store',
        notes             => 'Copies low 32 bits of GR R2 into GR R1; high 32 bits of R1 unchanged.',
    },
    LGR => {
        name              => 'Load (64-bit Register)',
        opcode            => 'B904',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Copies all 64 bits of GR R2 into GR R1.',
    },
    LHI => {
        name              => 'Load Halfword Immediate (32-bit)',
        opcode            => 'A708',
        format            => 'RI-a',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,I2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'load_store',
        notes             => 'Sign-extends 16-bit immediate I2 into low 32 bits of GR R1.',
    },
    LGHI => {
        name              => 'Load Halfword Immediate (64-bit)',
        opcode            => 'A709',
        format            => 'RI-a',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,I2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Sign-extends 16-bit immediate I2 into all 64 bits of GR R1; no literal pool required.',
    },
    LTR => {
        name              => 'Load and Test (32-bit)',
        opcode            => '12',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: <0; 2: >0',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'load_store',
        notes             => 'Loads 32-bit R2 into R1 and sets CC based on signed value.',
    },
    LTGR => {
        name              => 'Load and Test (64-bit)',
        opcode            => 'B902',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: <0; 2: >0',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Loads 64-bit R2 into R1 and sets CC based on signed 64-bit value.',
    },
    ST => {
        name              => 'Store (32-bit)',
        opcode            => '50',
        format            => 'RX-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'load_store',
        notes             => 'Stores low 32 bits of GR R1 into storage. 12-bit unsigned displacement (0..4095); use STY (E350) for 20-bit signed displacement.',
    },
    STY => {
        name              => 'Store (32-bit, Long Displacement)',
        opcode            => 'E350',
        format            => 'RXY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z990 (Long-Displacement Facility)',
        category          => 'load_store',
        notes             => 'Stores low 32 bits of GR R1 using 20-bit signed displacement (-524288..+524287).',
    },
    STG => {
        name              => 'Store (64-bit)',
        opcode            => 'E324',
        format            => 'RXY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Stores all 64 bits of GR R1 using 20-bit signed displacement (-524288..+524287).',
    },
    LM => {
        name              => 'Load Multiple (32-bit)',
        opcode            => '98',
        format            => 'RS-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,R3,D2(B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'load_store',
        notes             => 'Restores low 32 bits of contiguous GR range R1..R3 (wrapping around R15->R0) from 12-bit displacement storage.',
    },
    STM => {
        name              => 'Store Multiple (32-bit)',
        opcode            => '90',
        format            => 'RS-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,R3,D2(B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'load_store',
        notes             => 'Classic 31-bit z/OS save-area prologue STM 14,12,12(13). 12-bit displacement.',
    },
    LMG => {
        name              => 'Load Multiple (64-bit)',
        opcode            => 'EB04',
        format            => 'RSY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,R3,D2(B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Restores 64-bit GRs R1..R3 from storage with 20-bit signed displacement. Standard 64-bit epilogue (e.g. F4SA / s390x ELF64).',
    },
    STMG => {
        name              => 'Store Multiple (64-bit)',
        opcode            => 'EB24',
        format            => 'RSY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,R3,D2(B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'load_store',
        notes             => 'Saves 64-bit GRs R1..R3 to storage with 20-bit signed displacement (e.g. STMG 14,12,8(13) for F4SA or STMG %r6,%r15,48(%r15) on Linux s390x).',
    },
    # --- Storage-to-Storage & Immediate Byte Ops ---
    MVC => {
        name              => 'Move (Character)',
        opcode            => 'D2',
        format            => 'SS-a',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L,B1),D2(B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Copies 1..256 bytes left-to-right (encoded length L-1). Overlapping destructive 1-byte ripple (MVC B+1(L-1),B) is a classic fill idiom.',
    },
    MVCL => {
        name              => 'Move Long',
        opcode            => '0E',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: len1==len2; 1: len1<len2; 2: len1>len2; 3: destructive overlap',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Moves up to 16 MiB-1 using even/odd register pairs (R1/R1+1 dest addr/len, R2/R2+1 src addr/len+pad byte in high byte). Interruptible; does not move if destructive overlap.',
    },
    CLC => {
        name              => 'Compare Logical (Character)',
        opcode            => 'D5',
        format            => 'SS-a',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L,B1),D2(B2)',
        cc                => '0: equal; 1: op1<op2; 2: op1>op2',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Compares 1..256 unsigned bytes left-to-right; 12-bit displacements on both operands.',
    },
    CLCL => {
        name              => 'Compare Logical Long',
        opcode            => '0F',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: equal; 1: op1<op2; 2: op1>op2',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Compares arbitrarily long byte strings (up to 16 MiB-1) using even/odd register pairs with pad byte in bits 32-39 of R2+1.',
    },
    MVI => {
        name              => 'Move (Immediate)',
        opcode            => '92',
        format            => 'SI',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'D1(B1),I2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Stores 1-byte immediate I2 at D1(B1). Use MVIY (EB52) for 20-bit signed displacement.',
    },
    MVIY => {
        name              => 'Move (Immediate, Long Displacement)',
        opcode            => 'EB52',
        format            => 'SIY',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'D1(B1),I2',
        cc                => 'Unchanged',
        arch_level        => 'z990 (Long-Displacement Facility)',
        category          => 'string_storage',
        notes             => 'Stores 1-byte immediate I2 with 20-bit signed displacement.',
    },
    CLI => {
        name              => 'Compare Logical (Immediate)',
        opcode            => '95',
        format            => 'SI',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'D1(B1),I2',
        cc                => '0: equal; 1: op1<I2; 2: op1>I2',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Compares storage byte at D1(B1) against immediate I2. Use CLIY (EB55) for 20-bit displacement.',
    },
    TM => {
        name              => 'Test Under Mask',
        opcode            => '91',
        format            => 'SI',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'D1(B1),I2',
        cc                => '0: all 0 or mask 0; 1: mixed; 3: all 1',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'bit_test',
        notes             => 'Tests bit flags in a storage byte against mask I2. Use TMY (EB51) for 20-bit displacement.',
    },
    EX => {
        name              => 'Execute',
        opcode            => '44',
        format            => 'RX-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Set by target instruction',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'control',
        notes             => 'Executes target instruction ORed in byte 1 with low byte of R1 (if R1!=0). Common idiom for variable-length MVC/CLC. Prefer EXRL (C600) in baseless code.',
    },
    EXRL => {
        name              => 'Execute Relative Long',
        opcode            => 'C600',
        format            => 'RIL-b',
        length_bytes      => 6,
        displacement_bits => 0,
        operands          => 'R1,RI2',
        cc                => 'Set by target instruction',
        arch_level        => 'z10 (General-Instructions-Extension)',
        category          => 'control',
        notes             => 'PC-relative Execute: runs target instruction without a code base register.',
    },
    TR => {
        name              => 'Translate',
        opcode            => 'DC',
        format            => 'SS-a',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L,B1),D2(B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Translates up to 256 bytes in place via a 256-byte lookup table at D2(B2) (e.g. EBCDIC/ASCII or hex conversion).',
    },
    TRT => {
        name              => 'Translate and Test',
        opcode            => 'DD',
        format            => 'SS-a',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L,B1),D2(B2)',
        cc                => '0: all function bytes 0; 1: non-zero before last byte; 2: non-zero at last byte',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'string_storage',
        notes             => 'Scans byte string via 256-byte table, placing stopping address in GR1 and non-zero table byte in low byte of GR2.',
    },
    # --- Branching & Linkage ---
    BASR => {
        name              => 'Branch and Save (Register)',
        opcode            => '0D',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'branch_linkage',
        notes             => 'Saves clean return address (no ILC/CC/PM in high byte unlike BALR in 24-bit mode) in R1; branches to R2 unless R2==0 (BASR R12,0 loads current PSW instruction address).',
    },
    BRASL => {
        name              => 'Branch Relative and Save Long',
        opcode            => 'C005',
        format            => 'RIL-b',
        length_bytes      => 6,
        displacement_bits => 0,
        operands          => 'R1,RI2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'branch_linkage',
        notes             => 'PC-relative call (+/-4 GiB) saving return address in R1 (typically R14). Preferred call instruction in modern baseless HLASM and s390x ELF64.',
    },
    BALR => {
        name              => 'Branch and Link (Register)',
        opcode            => '05',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (S/360 legacy)',
        category          => 'branch_linkage',
        notes             => 'Legacy linkage; in 24-bit AMODE puts ILC/CC/program-mask into bits 32-39 of R1. Prefer BASR or BRASL in 31/64-bit code.',
    },
    BCR => {
        name              => 'Branch on Condition (Register)',
        opcode            => '07',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'M1,R2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'branch_linkage',
        notes             => 'Branches to R2 if CC matches mask M1 (when R2!=0). Special forms: BCR 15,0 = full serialization; BCR 14,0 = fast-BCR serialization (z196+); BCR 0,R2 = NOPR.',
    },
    BR => {
        name              => 'Branch Unconditional (Register, Extended Mnemonic)',
        opcode            => '07F',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'branch_linkage',
        notes             => 'Extended mnemonic for BCR 15,R2. Standard subroutine return is BR 14 (07FE).',
    },
    BC => {
        name              => 'Branch on Condition',
        opcode            => '47',
        format            => 'RX-b',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'M1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'branch_linkage',
        notes             => 'Base-displacement conditional branch. Prefer relative branches BRC (J*) or BRCL (J*L) to avoid code base register requirements.',
    },
    BRC => {
        name              => 'Branch Relative on Condition',
        opcode            => 'A704',
        format            => 'RI-c',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'M1,RI2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'branch_linkage',
        notes             => 'PC-relative conditional branch (+/-64 KiB); extended mnemonics J, JE, JNE, JL, JH, JO.',
    },
    BRCL => {
        name              => 'Branch Relative on Condition Long',
        opcode            => 'C004',
        format            => 'RIL-c',
        length_bytes      => 6,
        displacement_bits => 0,
        operands          => 'M1,RI2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'branch_linkage',
        notes             => 'PC-relative conditional branch (+/-4 GiB); extended mnemonics JLU, JLE, JLH, JLO.',
    },
    # --- Arithmetic, Logical & Compare ---
    AR => {
        name              => 'Add (32-bit Register)',
        opcode            => '1A',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: <0; 2: >0; 3: overflow',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'arithmetic',
        notes             => 'Signed 32-bit addition R1 <- R1 + R2 (low 32 bits).',
    },
    AGR => {
        name              => 'Add (64-bit Register)',
        opcode            => 'B908',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: <0; 2: >0; 3: overflow',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'arithmetic',
        notes             => 'Signed 64-bit addition R1 <- R1 + R2.',
    },
    AGHI => {
        name              => 'Add Halfword Immediate (64-bit)',
        opcode            => 'A70B',
        format            => 'RI-a',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,I2',
        cc                => '0: zero; 1: <0; 2: >0; 3: overflow',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'arithmetic',
        notes             => 'Adds sign-extended 16-bit immediate to 64-bit GR R1 (commonly used for stack frame allocation AGHI 15,-160).',
    },
    SR => {
        name              => 'Subtract (32-bit Register)',
        opcode            => '1B',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: <0; 2: >0; 3: overflow',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'arithmetic',
        notes             => 'Signed 32-bit subtraction; SR R15,R15 zeroes low 32 bits (return code 0).',
    },
    SGR => {
        name              => 'Subtract (64-bit Register)',
        opcode            => 'B909',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: <0; 2: >0; 3: overflow',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'arithmetic',
        notes             => 'Signed 64-bit subtraction R1 <- R1 - R2.',
    },
    XR => {
        name              => 'Exclusive OR (32-bit Register)',
        opcode            => '17',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: non-zero',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'logical',
        notes             => 'Bitwise XOR on low 32 bits.',
    },
    XGR => {
        name              => 'Exclusive OR (64-bit Register)',
        opcode            => 'B982',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: zero; 1: non-zero',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'logical',
        notes             => 'Bitwise 64-bit XOR; XGR R15,R15 cleanly zeroes all 64 bits.',
    },
    CR => {
        name              => 'Compare (32-bit Register)',
        opcode            => '19',
        format            => 'RR',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: equal; 1: R1<R2; 2: R1>R2',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'compare',
        notes             => 'Signed 32-bit comparison of low halves.',
    },
    CGR => {
        name              => 'Compare (64-bit Register)',
        opcode            => 'B920',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => '0: equal; 1: R1<R2; 2: R1>R2',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'compare',
        notes             => 'Signed 64-bit comparison.',
    },
    # --- Atomics & Synchronization ---
    CS => {
        name              => 'Compare and Swap (32-bit)',
        opcode            => 'BA',
        format            => 'RS-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,R3,D2(B2)',
        cc                => '0: equal & swapped; 1: unequal & R1 updated with storage value',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'atomic',
        notes             => 'Atomic fullword CAS with full serialization. Storage operand must be fullword-aligned.',
    },
    CSG => {
        name              => 'Compare and Swap (64-bit)',
        opcode            => 'EB30',
        format            => 'RSY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,R3,D2(B2)',
        cc                => '0: equal & swapped; 1: unequal & R1 updated',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'atomic',
        notes             => 'Atomic 64-bit CAS with 20-bit signed displacement and full serialization. Storage operand must be doubleword-aligned.',
    },
    CDSG => {
        name              => 'Compare Double and Swap (128-bit)',
        opcode            => 'EB3E',
        format            => 'RSY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,R3,D2(B2)',
        cc                => '0: equal & swapped; 1: unequal & R1/R1+1 updated',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'atomic',
        notes             => 'Atomic 128-bit quadword CAS using even/odd register pairs (R1/R1+1 expected, R3/R3+1 desired). Requires 16-byte quadword alignment; ideal for lock-free ABA-tagged pointers.',
    },
    LAA => {
        name              => 'Load and Add (32-bit Atomic)',
        opcode            => 'EBF8',
        format            => 'RSY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,R3,D2(B2)',
        cc                => '0: zero; 1: <0; 2: >0; 3: overflow (of original storage value + R3)',
        arch_level        => 'z196 (Interlocked-Access Facility 1)',
        category          => 'atomic',
        notes             => 'Lock-free atomic fetch-and-add on 32-bit fullword (R1 receives old storage value; storage += R3). Faster than CS spin loops under contention.',
    },
    LAAG => {
        name              => 'Load and Add (64-bit Atomic)',
        opcode            => 'EBE8',
        format            => 'RSY-a',
        length_bytes      => 6,
        displacement_bits => 20,
        operands          => 'R1,R3,D2(B2)',
        cc                => '0: zero; 1: <0; 2: >0; 3: overflow',
        arch_level        => 'z196 (Interlocked-Access Facility 1)',
        category          => 'atomic',
        notes             => 'Lock-free atomic 64-bit fetch-and-add on doubleword-aligned storage.',
    },
    # --- Supervisor, System Linkage & Clocks ---
    SVC => {
        name              => 'Supervisor Call',
        opcode            => '0A',
        format            => 'I',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => 'I1',
        cc                => 'Set by SVC routine',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'system',
        notes             => 'Raises Supervisor Call interruption (code 0..255) to invoke z/OS system services (e.g. SVC 13 ABEND, SVC 120 GETMAIN/FREEMAIN) or Linux syscall.',
    },
    PC => {
        name              => 'Program Call',
        opcode            => 'B218',
        format            => 'S',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'D2(B2)',
        cc                => 'Unchanged (may be changed by called routine)',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'system',
        notes             => 'Cross-memory / authorized space-switching service call via Entry Table lookup; stacking PC pushes linkage-stack entry restored by PR.',
    },
    BAKR => {
        name              => 'Branch and Stack',
        opcode            => 'B240',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'system',
        notes             => 'Saves GRs 0-15, ARs 0-15, and PSW state onto the hardware linkage stack (BAKR 14,0 common z/OS prologue). Paired with PR.',
    },
    PR => {
        name              => 'Program Return',
        opcode            => '0101',
        format            => 'E',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => '(none)',
        cc                => 'Restored from linkage stack',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'system',
        notes             => 'Pops hardware linkage-stack entry created by BAKR or stacking PC, restoring GRs 2-14, ARs 2-14, AMODE, and PSW.',
    },
    SAM64 => {
        name              => 'Set Addressing Mode (64-bit)',
        opcode            => '010E',
        format            => 'E',
        length_bytes      => 2,
        displacement_bits => 0,
        operands          => '(none)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'system',
        notes             => 'Switches PSW addressing mode to AMODE 64 (above-the-bar 64-bit virtual storage).',
    },
    STCKF => {
        name              => 'Store Clock Fast',
        opcode            => 'B27C',
        format            => 'S',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'D2(B2)',
        cc                => '0: clock set; 1: not set; 2: error; 3: stopped/not operational',
        arch_level        => 'z9 (Store-Clock-Fast Facility)',
        category          => 'system',
        notes             => 'Stores 8-byte TOD clock without strict uniqueness serialization — far faster than STCK for profiling and latency measurement.',
    },
    STCKE => {
        name              => 'Store Clock Extended',
        opcode            => 'B278',
        format            => 'S',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'D2(B2)',
        cc                => '0: clock set; 1: not set; 2: error; 3: stopped/not operational',
        arch_level        => 'z/Arch (Arch5)',
        category          => 'system',
        notes             => 'Stores 16-byte extended TOD clock (avoids 2042 TOD wrap-around, includes programmable field).',
    },
    # --- Decimal & Conversion ---
    PACK => {
        name              => 'Pack',
        opcode            => 'F2',
        format            => 'SS-b',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L1,B1),D2(L2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'decimal',
        notes             => 'Converts zoned decimal (EBCDIC digits) to packed decimal (COMP-3 / PLn).',
    },
    UNPK => {
        name              => 'Unpack',
        opcode            => 'F3',
        format            => 'SS-b',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L1,B1),D2(L2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'decimal',
        notes             => 'Converts packed decimal to zoned decimal (last byte zone carries sign nibble; often followed by OI last_byte,X\'F0\').',
    },
    ZAP => {
        name              => 'Zero and Add (Packed Decimal)',
        opcode            => 'F8',
        format            => 'SS-b',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L1,B1),D2(L2,B2)',
        cc                => '0: zero; 1: <0; 2: >0; 3: decimal overflow',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'decimal',
        notes             => 'Copies/widens packed decimal operand 2 into operand 1; raises S0C7 Data Exception if source has invalid nibbles.',
    },
    AP => {
        name              => 'Add Decimal',
        opcode            => 'FA',
        format            => 'SS-b',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'D1(L1,B1),D2(L2,B2)',
        cc                => '0: zero; 1: <0; 2: >0; 3: decimal overflow',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'decimal',
        notes             => 'Adds packed decimal operand 2 into operand 1; S0C7 if malformed packed digits.',
    },
    CVD => {
        name              => 'Convert to Decimal',
        opcode            => '4E',
        format            => 'RX-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'decimal',
        notes             => 'Converts signed 32-bit binary integer in R1 to 8-byte packed decimal at D2(X2,B2). Use CVDG (E32E) for 64-bit -> 16-byte packed.',
    },
    CVB => {
        name              => 'Convert to Binary',
        opcode            => '4F',
        format            => 'RX-a',
        length_bytes      => 4,
        displacement_bits => 12,
        operands          => 'R1,D2(X2,B2)',
        cc                => 'Unchanged',
        arch_level        => 'z/Arch (ESA/390)',
        category          => 'decimal',
        notes             => 'Converts 8-byte packed decimal to signed 32-bit binary in R1 (S0C9 fixed-point divide if out of range; S0C7 if bad digits).',
    },
    # --- Vector Facility (z13 VX / z14 VXE / z15 VXE2) ---
    VL => {
        name              => 'Vector Load',
        opcode            => 'E706',
        format            => 'VRX',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'V1,D2(X2,B2)[,M3]',
        cc                => 'Unchanged',
        arch_level        => 'z13 (VX / Arch11)',
        category          => 'vector',
        notes             => 'Loads 128-bit vector register V1 (VR0-VR31; VR0-VR15 overlap FPR0-FPR15 in high 64 bits). Optional M3 alignment hint (3=8B, 4=16B).',
    },
    VST => {
        name              => 'Vector Store',
        opcode            => 'E70E',
        format            => 'VRX',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'V1,D2(X2,B2)[,M3]',
        cc                => 'Unchanged',
        arch_level        => 'z13 (VX / Arch11)',
        category          => 'vector',
        notes             => 'Stores 128-bit vector register V1 to storage with optional alignment hint M3.',
    },
    VLM => {
        name              => 'Vector Load Multiple',
        opcode            => 'E736',
        format            => 'VRS-a',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'V1,V3,D2(B2)[,M4]',
        cc                => 'Unchanged',
        arch_level        => 'z13 (VX / Arch11)',
        category          => 'vector',
        notes             => 'Loads consecutive 128-bit vector registers V1..V3 from storage in a single instruction.',
    },
    VSTM => {
        name              => 'Vector Store Multiple',
        opcode            => 'E73E',
        format            => 'VRS-a',
        length_bytes      => 6,
        displacement_bits => 12,
        operands          => 'V1,V3,D2(B2)[,M4]',
        cc                => 'Unchanged',
        arch_level        => 'z13 (VX / Arch11)',
        category          => 'vector',
        notes             => 'Stores consecutive 128-bit vector registers V1..V3 to storage.',
    },
    VFM => {
        name              => 'Vector FP Multiply',
        opcode            => 'E7E7',
        format            => 'VRR-c',
        length_bytes      => 6,
        displacement_bits => 0,
        operands          => 'V1,V2,V3,M4,M5',
        cc                => 'Unchanged',
        arch_level        => 'z13 (VX double) / z14 (VXE single)',
        category          => 'vector',
        notes             => 'Element-wise IEEE-754 floating-point multiply (M4=2 short 4xFP32 on z14+ VXE via VFMSB; M4=3 long 2xFP64 via VFMDB; M4=4 extended FP128).',
    },
    VFMA => {
        name              => 'Vector FP Multiply and Add (FMA)',
        opcode            => 'E78F',
        format            => 'VRR-e',
        length_bytes      => 6,
        displacement_bits => 0,
        operands          => 'V1,V2,V3,V4,M5,M6',
        cc                => 'Unchanged',
        arch_level        => 'z13 (VX FP64) / z14 (VXE FP32)',
        category          => 'vector',
        notes             => 'Fused multiply-add V1 <- (V2 * V3) + V4 with single rounding. Extended mnemonics: VFMASB (4xFP32, z14+ VXE) and VFMADB (2xFP64, z13+ VX).',
    },
    VPERM => {
        name              => 'Vector Permute',
        opcode            => 'E78C',
        format            => 'VRR-e',
        length_bytes      => 6,
        displacement_bits => 0,
        operands          => 'V1,V2,V3,V4',
        cc                => 'Unchanged',
        arch_level        => 'z13 (VX / Arch11)',
        category          => 'vector',
        notes             => 'Selects 16 bytes from the 32-byte concatenation V2||V3 indexed by low 5 bits of each byte in V4.',
    },
    # --- IBM z14/z15/z16 Telum & z17 Telum II Hardware Accelerators & CPACF ---
    NNPA => {
        name              => 'Neural Network Processing Assist',
        opcode            => 'B93B',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => '(implicit GR0=function code, GR1=parameter block)',
        cc                => '0: normal completion; 1: exception in PB; 2: reserved; 3: partial completion (must re-drive via JO/BRC 1)',
        arch_level        => 'z16 Telum (Arch14) & z17 Telum II (Arch15)',
        category          => 'ai_accelerator',
        notes             => 'Invokes the on-chip IBM Telum / Telum II AI matrix accelerator (and z17 Telum II / Spyre DPU extensions). GR0 bits 56-63 select function (QAF=0x00, ADD=0x10, MUL=0x12, RELU=0x31, TANH=0x32, SIGMOID=0x33, SOFTMAX=0x34, GELU/LAYERNORM, LSTMACT=0x60, GRUACT=0x61, CONVOLUTION=0x70, MATMUL_OP=0x71, INT8 quantization on Telum II). GR1 points to 4096-byte parameter block containing 4D stick-format DLFloat16/INT8 tensor descriptors. Always loop on CC=3.',
        function_codes    => {
            '0x00' => 'NNPA-QAF (Query Available Functions & supported formats/sizes)',
            '0x10' => 'NNPA-ADD (Element-wise tensor addition)',
            '0x11' => 'NNPA-SUB (Element-wise tensor subtraction)',
            '0x12' => 'NNPA-MUL (Element-wise tensor multiplication)',
            '0x13' => 'NNPA-DIV (Element-wise tensor division)',
            '0x20' => 'NNPA-LOG / 0x21 NNPA-EXP / 0x22 NNPA-SQRT',
            '0x31' => 'NNPA-RELU / 0x32 TANH / 0x33 SIGMOID / 0x34 SOFTMAX',
            '0x35' => 'NNPA-GELU / LAYERNORM (Telum II / Arch15 Transformer ops)',
            '0x40' => 'NNPA-BATCHNORM',
            '0x50' => 'NNPA-MAXPOOL2D / 0x51 AVGPOOL2D',
            '0x60' => 'NNPA-LSTMACT / 0x61 NNPA-GRUACT',
            '0x70' => 'NNPA-CONVOLUTION (2D Conv)',
            '0x71' => 'NNPA-MATMUL-OP / 0x72 MATMUL-OP-BCAST23 (General GEMM)',
        },
    },
    DFLTCC => {
        name              => 'Deflate Conversion Call',
        opcode            => 'B939',
        format            => 'RRF-a',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2,R3 (implicit GR0=func, GR1=param block)',
        cc                => '0: complete; 1: op1 full; 2: op2 empty; 3: partial (CPU-determined amount, re-drive)',
        arch_level        => 'z15 (Arch13) / z16 Telum / z17 Telum II',
        category          => 'accelerator',
        notes             => 'Hardware-accelerated RFC 1951 DEFLATE compression/decompression (on-chip zEDC successor). GR0 func: 0=QAF, 1=GDHT (Generate Dynamic Huffman Table), 2=CMPR, 4=XPND. R1/R1+1 dest, R2/R2+1 src, R3 history buffer.',
    },
    SORTL => {
        name              => 'Sort Lists',
        opcode            => 'B938',
        format            => 'RRF-a',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2 (implicit GR0=func, GR1=param block)',
        cc                => '0: complete; 1/2: buffer full/empty; 3: partial (re-drive)',
        arch_level        => 'z15 (Arch13) / z16 Telum / z17 Telum II',
        category          => 'accelerator',
        notes             => 'Integrated Accelerator for Z Sort: hardware-accelerated tournament tree / merge sort (DFSORT / Db2 Utility acceleration). GR0 func: 0=QAF, 1=SFLR, 2=SFLS, 3=SFLM.',
    },
    KMA => {
        name              => 'Cipher Message with Authentication',
        opcode            => 'B929',
        format            => 'RRF-b',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R3,R2 (implicit GR0=func, GR1=param block)',
        cc                => '0: complete; 3: partial (re-drive via JO)',
        arch_level        => 'z14 (MSA8 / CPACF)',
        category          => 'crypto',
        notes             => 'Single-instruction CPACF hardware AES-128/192/256-GCM authenticated encryption & decryption. R1 dest, R2 plaintext/ciphertext, R3 AAD. Must loop on CC=3.',
    },
    KIMD => {
        name              => 'Compute Intermediate Message Digest',
        opcode            => 'B93E',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2 (implicit GR0=func, GR1=param block)',
        cc                => '0: complete; 3: partial (re-drive via JO)',
        arch_level        => 'z990+ (MSA / MSA6 SHA-3 / CPACF)',
        category          => 'crypto',
        notes             => 'CPACF hardware streaming hash (SHA-1, SHA-256, SHA-512, SHA3-224/256/384/512, SHAKE, GHASH) for full block multiples. Must loop on CC=3.',
    },
    KLMD => {
        name              => 'Compute Last Message Digest',
        opcode            => 'B93F',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2 (implicit GR0=func, GR1=param block)',
        cc                => '0: complete; 3: partial (re-drive via JO)',
        arch_level        => 'z990+ (MSA / MSA6 SHA-3 / CPACF)',
        category          => 'crypto',
        notes             => 'Finalizes CPACF hardware message digest with automatic padding & length suffix (SHA-1/256/512/SHA-3/SHAKE). Must loop on CC=3.',
    },
    KM => {
        name              => 'Cipher Message',
        opcode            => 'B92E',
        format            => 'RRE',
        length_bytes      => 4,
        displacement_bits => 0,
        operands          => 'R1,R2 (implicit GR0=func, GR1=param block)',
        cc                => '0: complete; 3: partial (re-drive via JO)',
        arch_level        => 'z990+ (MSA / CPACF)',
        category          => 'crypto',
        notes             => 'CPACF hardware block cipher (AES-128/192/256, TDES ECB, XTS).',
    },
);

my %DIRECTIVES = (
    CSECT => 'Control Section — defines an executable or read/write relocatable control section.',
    DSECT => 'Dummy Section — defines a symbolic storage template (structure layout) without reserving object storage.',
    RSECT => 'Read-Only Control Section — like CSECT with assembler reentrancy checking enabled.',
    USING => 'Establishes one or more base registers and a base address/DSECT for implicit base-displacement resolution.',
    DROP  => 'Releases previously established USING base register(s); bare DROP releases all active USINGs.',
    DS    => 'Define Storage — reserves aligned/unaligned storage bytes without assembling object data.',
    DC    => 'Define Constant — reserves storage and assembles initialized constant data.',
    ORG   => 'Set Location Counter — repositions current section offset (or restores high-water mark when operand omitted).',
    EQU   => 'Equate Symbol — assigns a numeric value, length attribute, or section-relative offset (e.g. LEN EQU *-DSECT).',
    MACRO => 'Begins an HLASM macro definition; immediately followed by the prototype statement.',
    MEND  => 'Terminates an HLASM macro definition.',
    COPY  => 'Includes an external copybook member from SYSLIB inline at assembly time.',
    LTORG => 'Literal Pool Origin — forces assembly of accumulated literals (=F\'...\', =CL8\'...\') at current location.',
    AMODE => 'Specifies Addressing Mode (24, 31, 64, ANY, ANY31, ANY64).',
    RMODE => 'Specifies Residency Mode (24, 31, ANY, 64).',
    ENTRY => 'Exports an external entry-point symbol to the Binder/Linkage Editor.',
    EXTRN => 'Declares an external symbol resolved by the Binder/Linkage Editor.',
    PRINT => 'Controls listing output options (GEN, NOGEN, DATA, NODATA, ON, OFF).',
);

my %SYS_VARS = (
    '&SYSLIST' => 'Macro positional parameter array (&SYSLIST(n), &SYSLIST(n,m), N\'&SYSLIST).',
    '&SYSNDX'  => 'Unique 4-to-7 digit macro invocation sequence number used to synthesize unique labels.',
    '&SYSECT'  => 'Name of the control section (CSECT/DSECT/RSECT) active when the macro was invoked.',
    '&SYSLOC'  => 'Name of the current location counter (LOCTR) active when the macro was invoked.',
    '&SYSPARM' => 'Assembly-time parameter string supplied via PARM=\'SYSPARM(...)\'.',
    '&SYSNEST' => 'Current macro nesting depth (1 at top-level call).',
    '&SYSDATE' => 'Assembly date (MM/DD/YY; see &SYSDATC for YYYYMMDD).',
    '&SYSTIME' => 'Assembly time (HH.MM).',
);

# Natural alignment & default byte sizes for DS/DC type codes (when no explicit Ln)
my %TYPE_SPEC = (
    H  => { align => 2,  size => 2  },
    Y  => { align => 2,  size => 2  },
    S  => { align => 2,  size => 2  },
    F  => { align => 4,  size => 4  },
    A  => { align => 4,  size => 4  },
    V  => { align => 4,  size => 4  },
    R  => { align => 4,  size => 4  },
    E  => { align => 4,  size => 4  },
    D  => { align => 8,  size => 8  },
    FD => { align => 8,  size => 8  },
    AD => { align => 8,  size => 8  },
    VD => { align => 8,  size => 8  },
    Q  => { align => 16, size => 16 },
    LQ => { align => 16, size => 16 },
    L  => { align => 8,  size => 16 },
    C  => { align => 1,  size => 1  },
    X  => { align => 1,  size => 1  },
    B  => { align => 1,  size => 1  },
    P  => { align => 1,  size => 1  },
    Z  => { align => 1,  size => 1  },
    G  => { align => 2,  size => 2  },
);

sub meta {
    return {
        name             => 'hlasm',
        label            => 'IBM HLASM (z/Architecture through z17 Telum II)',
        category         => 'mainframe',
        version          => $VERSION,
        description      => 'IBM High Level Assembler (z/Architecture through z16 Telum & z17 Telum II): Principles of Operation opcode reference, DSECT/CSECT layout and alignment calculator, USING/DROP base-register auditor, macro/COPY analyzer, and LSP hooks.',
        filetypes        => [qw(hlasm hla mlc mac)],
        upstream_credits => [
            'Eclipse Che4z che-che4z-lsp-for-hlasm (EPL-2.0)',
            'IBM z/Architecture Principles of Operation (SA22-7832)',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'hlasm_opcode_lookup',
            description => 'Look up IBM z/Architecture HLASM instructions (base z/Arch through z16 Telum and z17 Telum II, including NNPA B93B, DFLTCC B939, KMA/KIMD/KLMD, SORTL, and Vector Facility).',
            inputSchema => {
                type       => 'object',
                properties => {
                    mnemonic => { type => 'string', description => 'Exact or prefix HLASM mnemonic (e.g. NNPA, LAY, STMG, VFMA, CSG).' },
                    query    => { type => 'string', description => 'Free-text keyword search across instruction names, opcodes, categories, and notes.' },
                    arch     => { type => 'string', description => 'Optional architecture filter (e.g. z17, telum, z16, z15, z14, z13, vx).' },
                    format   => { type => 'string', description => 'Optional PoO instruction format filter (e.g. RR, RX, RXY, RSY, RIL, VRR, VRS, RRE, E, RRF).' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->opcode_lookup($args || {});
            },
        },
        {
            name        => 'hlasm_dsect_layout',
            description => 'Parse HLASM DSECT/CSECT/RSECT + DS/DC/ORG/EQU statements and compute exact byte offsets, natural boundary alignment slack bytes, duplication lengths, and EQU *-DSECT total size.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'HLASM source text containing DSECT/CSECT/RSECT and DS/DC/ORG/EQU definitions.' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->dsect_layout($args->{code} // '');
            },
        },
        {
            name        => 'hlasm_using_check',
            description => 'Audit HLASM USING/DROP base registers, detect R0 base-register hazards, shadowed base registers, and >4095-byte displacements on 12-bit RX/RS/SS/SI instructions recommending 20-bit RXY/RSY alternatives (LAY/LG/STG).',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'HLASM source text to analyze for USING/DROP and displacement safety.' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->using_check($args->{code} // '');
            },
        },
        {
            name        => 'hlasm_macro_analyze',
            description => 'Analyze HLASM MACRO/MEND definitions, prototype parameters, &SYSLIST/&SYSNDX/&SYSECT system symbols, conditional assembly (GBLA/LCLA/SETA/SETC/AIF/AGO), COPY dependencies, and column-72 continuation / column-16 resume rules.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'HLASM macro or source text to analyze.' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->macro_analyze($args->{code} // '');
            },
        },
    ];
}

# --- Tool 1: PoO Opcode Lookup ---

sub opcode_lookup {
    my ($self, $args) = @_;
    $args ||= {};
    my $mnem   = defined $args->{mnemonic} ? uc($args->{mnemonic}) : '';
    my $query  = defined $args->{query}    ? lc($args->{query})    : '';
    my $arch   = defined $args->{arch}     ? lc($args->{arch})     : '';
    my $format = defined $args->{format}   ? uc($args->{format})   : '';

    $mnem =~ s/^\s+|\s+$//g;

    if (length $mnem && exists $OPCODES{$mnem}) {
        my $entry = { mnemonic => $mnem, %{ $OPCODES{$mnem} } };
        return {
            ok          => 1,
            exact_match => 1,
            count       => 1,
            instruction => $entry,
            matches     => [$entry],
            catalog_size => scalar(keys %OPCODES),
        };
    }

    my @matches;
    for my $k (sort keys %OPCODES) {
        my $e = $OPCODES{$k};
        if (length $mnem) {
            next unless index($k, $mnem) == 0 || index(lc($e->{opcode}), lc($mnem)) == 0;
        }
        if (length $arch) {
            my $hay = lc("$e->{arch_level} $e->{category} $e->{notes}");
            next unless index($hay, $arch) >= 0;
        }
        if (length $format) {
            next unless index(uc($e->{format}), $format) == 0;
        }
        if (length $query) {
            my $hay = lc("$k $e->{name} $e->{opcode} $e->{format} $e->{arch_level} $e->{category} $e->{notes}");
            next unless index($hay, $query) >= 0;
        }
        push @matches, { mnemonic => $k, %$e };
    }

    return {
        ok           => 1,
        exact_match  => 0,
        count        => scalar(@matches),
        instruction  => (@matches == 1 ? $matches[0] : undef),
        matches      => \@matches,
        catalog_size => scalar(keys %OPCODES),
    };
}

# --- Internal HLASM Statement Parser ---

sub _parse_hlasm_line {
    my ($raw) = @_;
    return undef if !defined $raw || $raw =~ /^\s*$/;
    return undef if $raw =~ /^\*/ || $raw =~ /^\.\*/;

    # Strip columns > 71 for statement parsing (cols 73-80 are sequence/id)
    my $code_area = length($raw) > 71 ? substr($raw, 0, 71) : $raw;
    return undef if $code_area =~ /^\s*$/;

    my ($label, $rest) = ('', $code_area);
    if ($code_area =~ /^([A-Za-z@#\$_.&][A-Za-z0-9@#\$_.]*)\s+(.*)$/) {
        ($label, $rest) = ($1, $2);
    }
    elsif ($code_area =~ /^\s+(.*)$/) {
        $rest = $1;
    }
    else {
        return undef;
    }

    $rest =~ s/^\s+//;
    return undef unless length $rest;

    my ($op, $after_op) = split(/\s+/, $rest, 2);
    $op = uc($op // '');
    my $operands = '';
    if (defined $after_op && length $after_op) {
        # Operands end at first unquoted space
        my $in_quote = 0;
        my $len = length($after_op);
        my $end = $len;
        for (my $i = 0; $i < $len; $i++) {
            my $ch = substr($after_op, $i, 1);
            if ($ch eq "'") {
                if ($in_quote && $i + 1 < $len && substr($after_op, $i + 1, 1) eq "'") {
                    $i++;
                    next;
                }
                $in_quote = !$in_quote;
            }
            elsif (!$in_quote && $ch =~ /\s/) {
                $end = $i;
                last;
            }
        }
        $operands = substr($after_op, 0, $end);
    }

    return {
        label    => $label,
        op       => $op,
        operands => $operands,
    };
}

sub _split_ds_operands {
    my ($ops) = @_;
    my @parts;
    my $cur = '';
    my $in_q = 0;
    my $paren = 0;
    my $len = length($ops // '');
    for (my $i = 0; $i < $len; $i++) {
        my $ch = substr($ops, $i, 1);
        if ($ch eq "'") {
            if ($in_q && $i + 1 < $len && substr($ops, $i + 1, 1) eq "'") {
                $cur .= "''";
                $i++;
                next;
            }
            $in_q = !$in_q;
            $cur .= $ch;
        }
        elsif (!$in_q && $ch eq '(') {
            $paren++;
            $cur .= $ch;
        }
        elsif (!$in_q && $ch eq ')') {
            $paren-- if $paren > 0;
            $cur .= $ch;
        }
        elsif (!$in_q && $paren == 0 && $ch eq ',') {
            push @parts, $cur if length $cur;
            $cur = '';
        }
        else {
            $cur .= $ch;
        }
    }
    push @parts, $cur if length $cur;
    return @parts;
}

sub _parse_ds_spec {
    my ($spec) = @_;
    $spec =~ s/^\s+|\s+$//g;

    # Match optional duplication factor, 1-2 char type code, optional L<len> modifier, optional nominal value
    if ($spec =~ /^(\d+)?(FD|AD|VD|LQ|[HYFSAVREDQGCXBPZL])(?:L(\d+))?(.*)$/i) {
        my $dup_str  = $1;
        my $type     = uc($2);
        my $expl_len = $3;
        my $nominal  = $4 // '';

        my $dup = defined($dup_str) ? int($dup_str) : 1;
        my $info = $TYPE_SPEC{$type} || { align => 1, size => 1 };

        # Explicit Ln suppresses natural boundary alignment in HLASM
        my $align = defined($expl_len) ? 1 : $info->{align};
        my $elem_len;

        if (defined $expl_len) {
            $elem_len = int($expl_len);
        }
        elsif ($nominal =~ /^'(.*)'$/) {
            my $lit = $1;
            if ($type eq 'C' || $type eq 'Z') {
                $lit =~ s/''/'/g;
                $elem_len = length($lit) || 1;
            }
            elsif ($type eq 'X') {
                (my $hex = $lit) =~ s/[^0-9A-Fa-f]//g;
                $elem_len = int((length($hex) + 1) / 2) || 1;
            }
            elsif ($type eq 'B') {
                (my $bits = $lit) =~ s/[^01]//g;
                $elem_len = int((length($bits) + 7) / 8) || 1;
            }
            elsif ($type eq 'P') {
                (my $digs = $lit) =~ s/[^0-9]//g;
                $elem_len = int(length($digs) / 2) + 1;
            }
            else {
                $elem_len = $info->{size};
            }
        }
        elsif ($nominal =~ /^\((.*)\)$/) {
            # Address constants like A(X,Y) -> count comma-separated entries
            my @items = split(/,/, $1);
            $elem_len = $info->{size} * (scalar(@items) || 1);
        }
        else {
            $elem_len = $info->{size};
        }

        return {
            dup           => $dup,
            type          => $type,
            explicit_len  => defined($expl_len) ? 1 : 0,
            alignment     => $align,
            element_bytes => $elem_len,
            total_bytes   => $dup * $elem_len,
            spec          => $spec,
        };
    }

    return {
        dup           => 1,
        type          => '?',
        explicit_len  => 0,
        alignment     => 1,
        element_bytes => 0,
        total_bytes   => 0,
        spec          => $spec,
        unparsed      => 1,
    };
}

# --- Tool 2: DSECT/CSECT Storage & Slack Layout ---

sub dsect_layout {
    my ($self, $code) = @_;
    my @lines = split(/\r?\n/, $code // '');

    my @sections;
    my $cur_sec;
    my %global_symbols;

    my $ensure_section = sub {
        my ($name, $kind, $line_no) = @_;
        $cur_sec = {
            name              => $name || 'UNNAMED',
            kind              => $kind || 'DSECT',
            start_line        => $line_no,
            loc               => 0,
            high_water        => 0,
            total_slack_bytes => 0,
            fields            => [],
            equates           => [],
            sym_offset        => {},
            sym_length        => {},
        };
        push @sections, $cur_sec;
        $cur_sec->{sym_offset}{ uc($cur_sec->{name}) } = 0;
        $global_symbols{ uc($cur_sec->{name}) } = { section => $cur_sec->{name}, offset => 0, length => 1 };
    };

    for (my $idx = 0; $idx < @lines; $idx++) {
        my $st = _parse_hlasm_line($lines[$idx]);
        next unless $st;

        my $op  = $st->{op};
        my $lbl = $st->{label};
        my $ops = $st->{operands};

        if ($op eq 'DSECT' || $op eq 'CSECT' || $op eq 'RSECT') {
            $ensure_section->($lbl || $op, $op, $idx + 1);
            next;
        }

        if ($op eq 'DS' || $op eq 'DC') {
            $ensure_section->('DEFAULT', 'CSECT', $idx + 1) unless $cur_sec;
            my @specs = _split_ds_operands($ops);
            my $first = 1;
            for my $sp (@specs) {
                my $p = _parse_ds_spec($sp);
                my $align = $p->{alignment} || 1;
                my $slack = 0;
                if ($align > 1 && ($cur_sec->{loc} % $align) != 0) {
                    $slack = $align - ($cur_sec->{loc} % $align);
                }
                my $offset = $cur_sec->{loc} + $slack;
                my $total  = $p->{total_bytes};
                $cur_sec->{total_slack_bytes} += $slack;
                $cur_sec->{loc} = $offset + $total;
                $cur_sec->{high_water} = $cur_sec->{loc} if $cur_sec->{loc} > $cur_sec->{high_water};

                my $fname = $first ? $lbl : '';
                $first = 0;
                if (length $fname) {
                    $cur_sec->{sym_offset}{ uc($fname) } = $offset;
                    $cur_sec->{sym_length}{ uc($fname) } = $p->{element_bytes} || 1;
                    $global_symbols{ uc($fname) } = {
                        section => $cur_sec->{name},
                        offset  => $offset,
                        length  => $p->{element_bytes} || 1,
                        total   => $total,
                    };
                }

                push @{ $cur_sec->{fields} }, {
                    name          => $fname,
                    op            => $op,
                    spec          => $sp,
                    type          => $p->{type},
                    dup           => $p->{dup},
                    offset        => $offset,
                    offset_hex    => sprintf('X\'%04X\'', $offset),
                    alignment     => $align,
                    slack_bytes   => $slack,
                    element_bytes => $p->{element_bytes},
                    total_bytes   => $total,
                    end_offset    => $offset + $total,
                    line          => $idx + 1,
                };
            }
            next;
        }

        if ($op eq 'ORG') {
            $ensure_section->('DEFAULT', 'CSECT', $idx + 1) unless $cur_sec;
            if (!length $ops) {
                $cur_sec->{loc} = $cur_sec->{high_water};
            }
            elsif ($ops =~ /^\*\s*([+-])\s*(\d+)$/) {
                my $delta = ($1 eq '+') ? int($2) : -int($2);
                $cur_sec->{loc} += $delta;
                $cur_sec->{loc} = 0 if $cur_sec->{loc} < 0;
            }
            elsif ($ops =~ /^([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)(?:\s*([+-])\s*(\d+))?$/) {
                my ($sym, $sign, $val) = (uc($1), $2, $3);
                if (exists $cur_sec->{sym_offset}{$sym}) {
                    my $base = $cur_sec->{sym_offset}{$sym};
                    my $delta = defined($sign) ? (($sign eq '+') ? int($val) : -int($val)) : 0;
                    $cur_sec->{loc} = $base + $delta;
                    $cur_sec->{loc} = 0 if $cur_sec->{loc} < 0;
                }
            }
            $cur_sec->{high_water} = $cur_sec->{loc} if $cur_sec->{loc} > $cur_sec->{high_water};
            next;
        }

        if ($op eq 'EQU' && length $lbl) {
            $ensure_section->('DEFAULT', 'CSECT', $idx + 1) unless $cur_sec;
            my $val = undef;
            my ($expr) = split(/,/, $ops, 2);
            $expr //= '';
            if ($expr eq '*') {
                $val = $cur_sec->{loc};
            }
            elsif ($expr =~ /^\*\s*-\s*([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)$/) {
                my $ref = uc($1);
                my $ref_off = exists($cur_sec->{sym_offset}{$ref}) ? $cur_sec->{sym_offset}{$ref} : 0;
                $val = $cur_sec->{loc} - $ref_off;
            }
            elsif ($expr =~ /^(\d+)$/) {
                $val = int($1);
            }
            elsif ($expr =~ /^X'([0-9A-Fa-f]+)'$/i) {
                $val = hex($1);
            }
            $cur_sec->{sym_offset}{ uc($lbl) } = $val if defined $val;
            push @{ $cur_sec->{equates} }, {
                name  => $lbl,
                expr  => $ops,
                value => $val,
                hex   => defined($val) ? sprintf('X\'%04X\'', $val) : undef,
                line  => $idx + 1,
            };
        }
    }

    my @result_sections;
    for my $s (@sections) {
        my $tot = $s->{high_water};
        push @result_sections, {
            name              => $s->{name},
            kind              => $s->{kind},
            start_line        => $s->{start_line},
            total_length      => $tot,
            total_length_hex  => sprintf('X\'%04X\'', $tot),
            total_slack_bytes => $s->{total_slack_bytes},
            field_count       => scalar(@{ $s->{fields} }),
            fields            => $s->{fields},
            equates           => $s->{equates},
            equ_length_stmt   => sprintf('%-8s EQU   *-%s  * %d (X\'%X\') bytes',
                substr($s->{name}, 0, 4) . 'LEN', $s->{name}, $tot, $tot),
        };
    }

    return {
        ok             => 1,
        section_count  => scalar(@result_sections),
        sections       => \@result_sections,
        symbols        => \%global_symbols,
        total_length   => (@result_sections ? $result_sections[0]{total_length} : 0),
        total_slack    => (@result_sections ? $result_sections[0]{total_slack_bytes} : 0),
    };
}

# --- Tool 3: USING/DROP & Displacement Auditor ---

sub _norm_reg {
    my ($tok) = @_;
    return undef unless defined $tok;
    $tok =~ s/^\s+|\s+$//g;
    if ($tok =~ /^(?:R|GR)?(\d+)$/i) {
        my $n = int($1);
        return ($n >= 0 && $n <= 15) ? $n : undef;
    }
    return undef;
}

my %DISP12_SUGGEST = (
    L   => 'LY (E358, 20-bit signed) or LG (E304, 64-bit)',
    ST  => 'STY (E350, 20-bit signed) or STG (E324, 64-bit)',
    LA  => 'LAY (E371, 20-bit signed)',
    LM  => 'LMY (EB98) or LMG (EB04, 64-bit)',
    STM => 'STMY (EB90) or STMG (EB24, 64-bit)',
    MVI => 'MVIY (EB52, 20-bit signed)',
    CLI => 'CLIY (EB55, 20-bit signed)',
    TM  => 'TMY (EB51, 20-bit signed)',
    CS  => 'CSY (EB14) or CSG (EB30, 64-bit)',
    MVC => 'LAY a temporary base register into offset before MVC, or establish a secondary USING base register',
    CLC => 'LAY a temporary base register into offset before CLC, or establish a secondary USING base register',
    BC  => 'BRC/BRCL (relative branch, no base register needed)',
    EX  => 'EXRL (C600, relative long execute)',
);

sub using_check {
    my ($self, $code) = @_;
    my @lines = split(/\r?\n/, $code // '');

    # Compute DSECT/CSECT symbol offsets first so symbolic references > 4095 are caught
    my $layout = $self->dsect_layout($code);
    my $syms   = $layout->{symbols} || {};

    my %active_using; # reg_num => { base => ..., range => ..., line => ..., label => ... }
    my @usings_log;
    my @drops_log;
    my @findings;

    for (my $idx = 0; $idx < @lines; $idx++) {
        my $st = _parse_hlasm_line($lines[$idx]);
        next unless $st;

        my $op  = $st->{op};
        my $ops = $st->{operands};
        my $ln  = $idx + 1;

        if ($op eq 'USING') {
            # Parse USING target,R1[,R2,...] (handle range syntax (start,end),R1)
            my ($base_expr, $reg_list) = ('', '');
            if ($ops =~ /^(\([^)]+\)),(.*)$/) {
                ($base_expr, $reg_list) = ($1, $2);
            }
            elsif ($ops =~ /^([^,]+),(.*)$/) {
                ($base_expr, $reg_list) = ($1, $2);
            }
            my @regs = split(/,/, $reg_list);
            my $span = 4096 * (scalar(@regs) || 1);
            my $reg_idx = 0;

            for my $rtok (@regs) {
                my $rnum = _norm_reg($rtok);
                if (!defined $rnum) {
                    push @findings, {
                        line     => $ln,
                        severity => 'warn',
                        code     => 'HLASM_USING_UNKNOWN_REG',
                        message  => "Unrecognized base register '$rtok' in USING $ops.",
                    };
                    next;
                }
                if ($rnum == 0) {
                    push @findings, {
                        line     => $ln,
                        severity => 'error',
                        code     => 'HLASM_USING_R0_HAZARD',
                        message  => "Register R0 specified in USING ($ops): in z/Architecture, B=0 means no base register (effective base 0). Only valid for low-core PSA (offset 0..4095) with explicit intent.",
                    };
                }
                if (exists $active_using{$rnum}) {
                    push @findings, {
                        line     => $ln,
                        severity => 'warn',
                        code     => 'HLASM_USING_SHADOW',
                        message  => "Base register R$rnum already active for '$active_using{$rnum}{base}' (line $active_using{$rnum}{line}); DROP R$rnum before reassigning to '$base_expr'.",
                    };
                }
                my $rec = {
                    register  => "R$rnum",
                    reg_num   => $rnum,
                    base      => $base_expr,
                    label     => $st->{label},
                    offset_lo => $reg_idx * 4096,
                    offset_hi => ($reg_idx + 1) * 4096 - 1,
                    total_span => $span,
                    line      => $ln,
                };
                $active_using{$rnum} = $rec;
                push @usings_log, $rec;
                $reg_idx++;
            }
            next;
        }

        if ($op eq 'DROP') {
            if (!length $ops) {
                push @drops_log, { line => $ln, registers => [ map { "R$_" } sort { $a <=> $b } keys %active_using ], all => 1 };
                %active_using = ();
            }
            else {
                my @dropped;
                for my $rtok (split(/,/, $ops)) {
                    my $rnum = _norm_reg($rtok);
                    if (defined $rnum) {
                        if (!exists $active_using{$rnum}) {
                            push @findings, {
                                line     => $ln,
                                severity => 'warn',
                                code     => 'HLASM_DROP_INACTIVE',
                                message  => "DROP R$rnum issued, but R$rnum has no active USING.",
                            };
                        }
                        else {
                            delete $active_using{$rnum};
                            push @dropped, "R$rnum";
                        }
                    }
                }
                push @drops_log, { line => $ln, registers => \@dropped, all => 0 };
            }
            next;
        }

        # Check instruction operands for:
        # 1) Explicit displacement D(X,B) or D(B) where B is R0 or D > 4095 on 12-bit instruction
        # 2) Symbolic field references whose DSECT offset > 4095 on a 12-bit instruction
        my $op_info = $OPCODES{$op};
        my $disp_bits = $op_info ? ($op_info->{displacement_bits} // 0) : 0;

        # Check explicit numeric displacements D(X,B) or D(L,B) or D(B)
        while ($ops =~ /(-?\d+)\(([^)]+)\)/g) {
            my ($disp, $inside) = (int($1), $2);
            my @sub = split(/,/, $inside);
            my $base_tok = $sub[-1];
            my $base_reg = _norm_reg($base_tok);

            if (defined $base_reg && $base_reg == 0 && $disp != 0 && $op ne 'LA' && $op ne 'LAY') {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'HLASM_R0_BASE_OPERAND',
                    message  => "Instruction $op uses R0 as base register in '$disp($inside)': R0 evaluates to 0 (absolute low-core storage access), not contents of GR0.",
                };
            }

            if ($disp_bits == 12 && ($disp > 4095 || $disp < 0)) {
                my $sugg = $DISP12_SUGGEST{$op} || '20-bit signed RXY/RSY/SIY instruction (e.g. LAY/LG/STG)';
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'HLASM_DISP12_OVERFLOW',
                    message  => "Displacement $disp exceeds 12-bit unsigned range (0..4095) on $op ($op_info->{format}); use $sugg.",
                };
            }
            elsif ($disp_bits == 20 && ($disp > 524287 || $disp < -524288)) {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'HLASM_DISP20_OVERFLOW',
                    message  => "Displacement $disp exceeds 20-bit signed range (-524288..+524287) on $op ($op_info->{format}).",
                };
            }
        }

        # Check symbolic DSECT field offset > 4095 on 12-bit instruction
        if ($disp_bits == 12) {
            my @op_parts = split(/,/, $ops);
            for my $part (@op_parts) {
                my $sym = uc($part);
                $sym =~ s/\(.*$//;
                next unless exists $syms->{$sym};
                my $off = $syms->{$sym}{offset};
                my $sec = uc($syms->{$sym}{section} // '');

                # Compute max covered range for this section among active USINGs
                my $max_covered = 4095;
                for my $u (values %active_using) {
                    if (uc($u->{base}) eq $sec && $u->{offset_hi} > $max_covered) {
                        $max_covered = $u->{offset_hi};
                    }
                }
                if ($off > $max_covered) {
                    my $sugg = $DISP12_SUGGEST{$op} || '20-bit signed RXY/RSY instruction (LAY/LG/STG)';
                    push @findings, {
                        line     => $ln,
                        severity => 'error',
                        code     => 'HLASM_DISP12_SYMBOL_OVERFLOW',
                        message  => "Symbol '$sym' in $syms->{$sym}{section} is at offset $off (X'"
                                  . sprintf('%X', $off) . "'), exceeding 12-bit addressability ($max_covered bytes) on $op ($op_info->{format}); switch to $sugg.",
                    };
                }
            }
        }

        # Check clobbering an active USING base register (dest is first operand R1)
        if ($op_info && $op_info->{category} =~ /^(?:load_store|addressing|arithmetic|logical)$/ && $op !~ /^ST/) {
            my ($r1_tok) = split(/,/, $ops, 2);
            my $r1 = _norm_reg($r1_tok);
            if (defined $r1 && exists $active_using{$r1} && $op ne 'USING') {
                push @findings, {
                    line     => $ln,
                    severity => 'warn',
                    code     => 'HLASM_BASE_REG_MODIFIED',
                    message  => "Instruction $op modifies R$r1 while R$r1 is an active USING base register for '$active_using{$r1}{base}' (established line $active_using{$r1}{line}).",
                };
            }
        }
    }

    return {
        ok             => (grep { $_->{severity} eq 'error' } @findings) ? 0 : 1,
        usings         => \@usings_log,
        drops          => \@drops_log,
        active_at_end  => [ map { $active_using{$_} } sort { $a <=> $b } keys %active_using ],
        finding_count  => scalar(@findings),
        findings       => \@findings,
    };
}

# --- Tool 4: Macro, Conditional Assembly, COPY & Col-72/16 Analyzer ---

sub macro_analyze {
    my ($self, $code) = @_;
    my @lines = split(/\r?\n/, $code // '');

    my @macros;
    my @copies;
    my %sys_vars_used;
    my %cond_asm = (
        gbl   => [],
        lcl   => [],
        set   => [],
        aif   => [],
        ago   => [],
        mnote => [],
    );
    my @findings;

    my $in_macro        = 0;
    my $expect_proto    = 0;
    my $cur_macro       = undef;
    my $expect_cont     = 0;
    my $cont_origin_ln  = 0;

    for (my $idx = 0; $idx < @lines; $idx++) {
        my $raw = $lines[$idx];
        my $ln  = $idx + 1;

        # Column-72 continuation & Column-16 resume validation
        if ($expect_cont) {
            if ($raw =~ /^\*/ || $raw =~ /^\.\*/) {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'HLASM_CONT_COMMENT_BREAK',
                    message  => "Line $cont_origin_ln had a continuation character in column 72, but line $ln is a comment instead of a continuation starting in column 16.",
                };
            }
            else {
                my $prefix15 = length($raw) >= 15 ? substr($raw, 0, 15) : $raw;
                if ($prefix15 =~ /\S/) {
                    push @findings, {
                        line     => $ln,
                        severity => 'error',
                        code     => 'HLASM_CONT_COL16',
                        message  => "Continuation line $ln (continuing line $cont_origin_ln) has non-blank text in columns 1-15; HLASM continuations must leave columns 1-15 blank and resume in column 16.",
                    };
                }
                elsif (length($raw) < 16 || substr($raw, 15, 1) eq ' ') {
                    push @findings, {
                        line     => $ln,
                        severity => 'warn',
                        code     => 'HLASM_CONT_RESUME_COL16',
                        message  => "Continuation line $ln does not resume at column 16 (col 16 is blank); operand tokens may be mis-parsed as comments unless continuing a quoted string.",
                    };
                }
            }
            $expect_cont = 0;
        }

        # Check if THIS non-comment line triggers continuation via column 72 (0-based index 71)
        if ($raw !~ /^\*/ && $raw !~ /^\.\*/ && length($raw) >= 72) {
            my $col72 = substr($raw, 71, 1);
            if ($col72 ne ' ') {
                $expect_cont    = 1;
                $cont_origin_ln = $ln;
                if ($idx == $#lines) {
                    push @findings, {
                        line     => $ln,
                        severity => 'error',
                        code     => 'HLASM_CONT_EOF',
                        message  => "Line $ln has non-blank continuation character '$col72' in column 72 at end of file with no following continuation line.",
                    };
                }
            }
        }

        next if $raw =~ /^\*/ || $raw =~ /^\.\*/;

        # Collect system variable symbols (&SYSLIST, &SYSNDX, &SYSECT, etc.)
        while ($raw =~ /(&SYS[A-Z0-9]+)/gi) {
            $sys_vars_used{ uc($1) }++;
        }

        my $st = _parse_hlasm_line($raw);
        next unless $st;

        my $op  = $st->{op};
        my $lbl = $st->{label};
        my $ops = $st->{operands};

        if ($op eq 'MACRO') {
            if ($in_macro) {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'HLASM_NESTED_MACRO',
                    message  => "MACRO at line $ln inside unclosed MACRO '$cur_macro->{name}' (started line $cur_macro->{start_line}).",
                };
            }
            $in_macro     = 1;
            $expect_proto = 1;
            $cur_macro    = {
                name            => '',
                label_param     => '',
                start_line      => $ln,
                end_line        => undef,
                positional_args => [],
                keyword_args    => [],
            };
            next;
        }

        if ($expect_proto) {
            $expect_proto = 0;
            $cur_macro->{name}        = $op;
            $cur_macro->{label_param} = $lbl if $lbl =~ /^&/;
            for my $p (split(/,/, $ops)) {
                $p =~ s/^\s+|\s+$//g;
                next unless length $p;
                if ($p =~ /^(&[A-Za-z@#\$_][A-Za-z0-9@#\$_]*)=(.*)$/) {
                    push @{ $cur_macro->{keyword_args} }, { name => uc($1), default => $2 };
                }
                elsif ($p =~ /^&[A-Za-z@#\$_][A-Za-z0-9@#\$_]*$/) {
                    push @{ $cur_macro->{positional_args} }, uc($p);
                }
            }
            next;
        }

        if ($op eq 'MEND') {
            if (!$in_macro) {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'HLASM_STRAY_MEND',
                    message  => "MEND at line $ln without a matching MACRO header.",
                };
            }
            else {
                $cur_macro->{end_line} = $ln;
                push @macros, $cur_macro;
                $cur_macro = undef;
                $in_macro  = 0;
            }
            next;
        }

        if ($op eq 'COPY') {
            push @copies, { member => uc($ops), line => $ln };
        }
        elsif ($op =~ /^GBL([ABC])$/) {
            push @{ $cond_asm{gbl} }, { type => $op, symbols => [ split(/,/, $ops) ], line => $ln };
        }
        elsif ($op =~ /^LCL([ABC])$/) {
            push @{ $cond_asm{lcl} }, { type => $op, symbols => [ split(/,/, $ops) ], line => $ln };
        }
        elsif ($op =~ /^SET([ABC])$/) {
            push @{ $cond_asm{set} }, { type => $op, target => $lbl, expr => $ops, line => $ln };
        }
        elsif ($op eq 'AIF') {
            push @{ $cond_asm{aif} }, { condition => $ops, line => $ln };
        }
        elsif ($op eq 'AGO') {
            push @{ $cond_asm{ago} }, { target => $ops, line => $ln };
        }
        elsif ($op eq 'MNOTE') {
            push @{ $cond_asm{mnote} }, { text => $ops, line => $ln };
        }
    }

    if ($in_macro && $cur_macro) {
        push @findings, {
            line     => $cur_macro->{start_line},
            severity => 'error',
            code     => 'HLASM_UNCLOSED_MACRO',
            message  => "MACRO '$cur_macro->{name}' opened at line $cur_macro->{start_line} is missing a closing MEND.",
        };
        push @macros, $cur_macro;
    }

    return {
        ok                 => (grep { $_->{severity} eq 'error' } @findings) ? 0 : 1,
        macros             => \@macros,
        copies             => \@copies,
        system_vars_used   => [ sort keys %sys_vars_used ],
        system_var_counts  => \%sys_vars_used,
        conditional_asm    => \%cond_asm,
        finding_count      => scalar(@findings),
        findings           => \@findings,
    };
}

# --- LSP Knowledge Hooks ---

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef unless defined $word && length $word;
    my $up = uc($word);

    if (exists $OPCODES{$up}) {
        my $e = $OPCODES{$up};
        my $md = "### HLASM `$up` — $e->{name}\n\n"
               . "- **Opcode:** `0x$e->{opcode}` (`$e->{format}`, $e->{length_bytes}B)\n"
               . "- **Operands:** `$e->{operands}`\n"
               . "- **Condition Code:** $e->{cc}\n"
               . "- **Arch Level:** $e->{arch_level}\n\n"
               . "$e->{notes}\n";
        if (ref($e->{function_codes}) eq 'HASH') {
            $md .= "\n**Function Codes (GR0):**\n";
            for my $fc (sort keys %{ $e->{function_codes} }) {
                $md .= "- `$fc`: $e->{function_codes}{$fc}\n";
            }
        }
        return { contents => $md, kind => 'markdown', title => "HLASM $up" };
    }

    if (exists $DIRECTIVES{$up}) {
        return {
            contents => "### HLASM Directive `$up`\n\n$DIRECTIVES{$up}\n",
            kind     => 'markdown',
            title    => "HLASM $up",
        };
    }

    my $sys_key = ($up =~ /^&/) ? $up : "&$up";
    if (exists $SYS_VARS{$sys_key}) {
        return {
            contents => "### HLASM System Variable `$sys_key`\n\n$SYS_VARS{$sys_key}\n",
            kind     => 'markdown',
            title    => "HLASM $sys_key",
        };
    }

    if ($up =~ /^(?:R|GR)(\d+)$/ && $1 <= 15) {
        my $n = int($1);
        my %role = (
            0  => 'Volatile / parameter / return value; CANNOT be used as base or index register (0 means no register).',
            1  => 'Parameter list pointer (z/OS standard linkage) / NNPA/DFLTCC/CPACF parameter block address.',
            12 => 'Common program base register (z/OS CAA pointer in LE).',
            13 => 'Save area pointer (72-byte F1SA or 144-byte F4SA in z/OS standard linkage).',
            14 => 'Return address register (BR 14).',
            15 => 'Entry point address on call; return code on exit (and stack pointer on Linux s390x ELF64).',
        );
        my $desc = $role{$n} || "General-purpose 64-bit register GR$n.";
        return {
            contents => "### z/Architecture General Register `GR$n`\n\n$desc\n",
            kind     => 'markdown',
            title    => "GR$n",
        };
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $pfx = uc($prefix // '');
    my @items;

    for my $k (sort keys %OPCODES) {
        next if length($pfx) && index($k, $pfx) != 0;
        my $e = $OPCODES{$k};
        push @items, {
            label         => $k,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{keyword},
            detail        => "[$e->{opcode} $e->{format}] $e->{name}",
            documentation => "$e->{operands} — $e->{arch_level}. $e->{notes}",
        };
    }

    for my $d (sort keys %DIRECTIVES) {
        next if length($pfx) && index($d, $pfx) != 0;
        push @items, {
            label         => $d,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{operator},
            detail        => 'HLASM Assembler Directive',
            documentation => $DIRECTIVES{$d},
        };
    }

    for my $sv (sort keys %SYS_VARS) {
        next if length($pfx) && index($sv, $pfx) != 0;
        push @items, {
            label         => $sv,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{variable},
            detail        => 'HLASM System Variable',
            documentation => $SYS_VARS{$sv},
        };
    }

    return \@items;
}

sub lsp_diagnostics {
    my ($self, $text, $lang) = @_;
    my @diags;

    my $u = $self->using_check($text);
    for my $f (@{ $u->{findings} || [] }) {
        push @diags, $self->make_diagnostic(
            line     => ($f->{line} || 1) - 1,
            col      => 0,
            end_col  => 71,
            severity => $f->{severity},
            code     => $f->{code},
            message  => $f->{message},
            source   => 'hlasm',
        );
    }

    my $m = $self->macro_analyze($text);
    for my $f (@{ $m->{findings} || [] }) {
        push @diags, $self->make_diagnostic(
            line     => ($f->{line} || 1) - 1,
            col      => 0,
            end_col  => 72,
            severity => $f->{severity},
            code     => $f->{code},
            message  => $f->{message},
            source   => 'hlasm',
        );
    }

    return \@diags;
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    my @syms;
    my $layout = $self->dsect_layout($text);
    for my $s (@{ $layout->{sections} || [] }) {
        next if $s->{name} eq 'DEFAULT';
        push @syms, $self->make_symbol(
            name   => $s->{name},
            kind   => ($s->{kind} eq 'DSECT' ? 'struct' : 'module'),
            line   => ($s->{start_line} || 1) - 1,
            detail => "$s->{kind} ($s->{total_length} bytes)",
        );
        for my $f (@{ $s->{fields} || [] }) {
            next unless length $f->{name};
            push @syms, $self->make_symbol(
                name   => $f->{name},
                kind   => 'field',
                line   => ($f->{line} || 1) - 1,
                detail => "$f->{op} $f->{spec} \@+$f->{offset} ($f->{offset_hex}, $f->{total_bytes}B)",
            );
        }
        for my $eq (@{ $s->{equates} || [] }) {
            push @syms, $self->make_symbol(
                name   => $eq->{name},
                kind   => 'constant',
                line   => ($eq->{line} || 1) - 1,
                detail => "EQU $eq->{expr}" . (defined $eq->{value} ? " (= $eq->{value})" : ''),
            );
        }
    }

    my $m = $self->macro_analyze($text);
    for my $mac (@{ $m->{macros} || [] }) {
        next unless length $mac->{name};
        push @syms, $self->make_symbol(
            name     => $mac->{name},
            kind     => 'function',
            line     => ($mac->{start_line} || 1) - 1,
            end_line => (($mac->{end_line} || $mac->{start_line}) - 1),
            detail   => 'HLASM MACRO',
        );
    }

    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::HLASM - IBM HLASM MCP domain pack (z/Architecture through z17 Telum II)

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::HLASM;
    my $pack = NeoPerl::MCP::Pack::HLASM->new;
    my $nnpa = $pack->call_tool('hlasm_opcode_lookup', { mnemonic => 'NNPA' });
    my $lay  = $pack->call_tool('hlasm_dsect_layout',  { code => $dsect_src });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::HLASM> provides an IBM High Level Assembler MCP domain
pack and built-in LSP knowledge provider inspired by Eclipse Che4z
(C<che-che4z-lsp-for-hlasm>) and the IBM z/Architecture Principles of
Operation through z16 Telum and z17 Telum II.

=head1 TOOLS

=over 4

=item * C<hlasm_opcode_lookup> - Principles of Operation instruction database
including base z/Architecture, Long-Displacement Facility, Vector Facility
(VX/VXE), CPACF crypto (C<KMA>/C<KIMD>/C<KLMD>), hardware compression and sort
(C<DFLTCC>/C<SORTL>), and C<NNPA> (C<B93B>) on Telum and Telum II.

=item * C<hlasm_dsect_layout> - Computes exact byte offsets, natural boundary
alignment slack bytes, duplication lengths, C<ORG> re-positioning, and
C<EQU *-DSECT> section sizes.

=item * C<hlasm_using_check> - Tracks C<USING>/C<DROP> base registers, detects
C<R0> base-register hazards, and flags 12-bit displacement overflows above
4095 bytes with 20-bit RXY/RSY upgrade recommendations.

=item * C<hlasm_macro_analyze> - Parses C<MACRO>/C<MEND>, prototype arguments,
C<&SYS*> variables, conditional assembly directives, C<COPY> dependencies, and
column-72 continuation / column-16 resume compliance.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
