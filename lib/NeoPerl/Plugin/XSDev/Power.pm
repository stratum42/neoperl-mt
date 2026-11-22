package NeoPerl::Plugin::XSDev::Power;

use strict;
use warnings;

use File::Basename ();
use File::Spec ();

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    return bless {
        runner           => $opts{runner},
        last_asm         => undef,
        last_vec_report  => undef,
        last_audit       => undef,
    }, $class;
}

sub last_asm        { $_[0]{last_asm} }
sub last_vec_report { $_[0]{last_vec_report} }
sub last_audit      { $_[0]{last_audit} }

# -------------------------------------------------------------------------
# 1. :XSAsm — ELFv2 objdump -d -S -M power8,power9,power10 disassembly & highlighter
# -------------------------------------------------------------------------

sub disassemble {
    my ($self, $target_obj, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});

    my @cmd;
    if ($tools->{objdump}) {
        @cmd = ($tools->{objdump}, '-d', '-S');
        if ($tools->{is_power} || ($opts{arch} || '') =~ /^ppc64/i) {
            push @cmd, '-M', 'power8,power9,power10';
        }
        push @cmd, $target_obj;
    }
    elsif ($tools->{is_macos} && $tools->{otool}) {
        @cmd = ($tools->{otool}, '-tV', $target_obj);
    }
    else {
        return { ok => 0, error => 'neither objdump nor otool found' };
    }

    my $res = $runner->run_cmd(\@cmd, remote => $opts{remote}, timeout => $opts{timeout} || 60);
    # Fallback without -M if objdump version does not recognize combined power8,power9,power10
    if (!$res->{ok} && $tools->{objdump} && grep { $_ eq '-M' } @cmd) {
        $res = $runner->run_cmd([ $tools->{objdump}, '-d', '-S', $target_obj ],
            remote => $opts{remote}, timeout => $opts{timeout} || 60);
    }

    return { ok => 0, error => $res->{stderr} || 'disassembly failed', exit_code => $res->{exit_code} }
        unless $res->{ok};

    my $ann = $self->annotate_asm($res->{stdout}, target => $target_obj, arch => $opts{arch} || $tools->{arch});
    $self->{last_asm} = $ann;
    return $ann;
}

sub annotate_asm {
    my ($self, $asm_text, %opts) = @_;
    $asm_text = '' unless defined $asm_text;

    my @lines;
    my @functions;
    my %summary = (
        total_insns     => 0,
        vsx_count       => 0,
        mma_count       => 0,
        toc_count       => 0,
        barrier_count   => 0,
        smt_yield_count => 0,
        branch_count    => 0,
    );

    my $cur_fn = '';
    for my $raw (split /\n/, $asm_text) {
        $raw =~ s/\r\z//;

        # Function label: 0000000000000100 <npl_vec_cosine>:
        if ($raw =~ /^[0-9a-fA-F]+\s+<([^>]+)>:/) {
            $cur_fn = $1;
            push @functions, $cur_fn;
            push @lines, { text => $raw, kind => 'label', func => $cur_fn, hl => 'XSAsmLabel', tags => [] };
            next;
        }

        # Instruction line (objdump ELF/Mach-O):
        #   104:  40 00 4c 3c   addis   r2,r12,2
        #   1000004bc:  f90007e0  str x0, [sp, #8]
        my ($addr, $mnemonic, $operands);
        if ($raw =~ /^\s*([0-9a-fA-F]+):\s+(?:(?:[0-9a-fA-F]{2}\s+){2,8}|[0-9a-fA-F]{8}\s+)([A-Za-z][A-Za-z0-9_.]*)\s*(.*)$/) {
            ($addr, $mnemonic, $operands) = ($1, $2, $3 // '');
        }

        if (defined $mnemonic) {
            $summary{total_insns}++;
            my $mlc = lc($mnemonic);
            my @tags;
            my $hl = 'Normal';

            # POWER10 MMA instructions
            if ($mlc =~ /^(?:xvf(?:16|32|64)ger|xvi(?:4|8|16)ger|xvbf16ger|xxmfacc|xxmtacc|xxsetaccz|pmxvf|pmxvi)/) {
                push @tags, 'mma';
                $summary{mma_count}++;
                $hl = 'XSAsmMMA';
            }
            # POWER8/9/10 VSX / VMX vector instructions
            elsif ($mlc =~ /^(?:xv[a-z0-9]+|lxv[a-z0-9]*|stxv[a-z0-9]*|xx[a-z0-9]+|xs[a-z0-9]+|vmadd[a-z0-9]*|vadd[a-z0-9]*|vsub[a-z0-9]*|vmul[a-z0-9]*|vperm[a-z0-9]*|vsplt[a-z0-9]*|mtvsr[a-z0-9]*|mfvsr[a-z0-9]*|lvx|stvx)$/) {
                push @tags, 'vsx';
                $summary{vsx_count}++;
                $hl = 'XSAsmVSX';
            }

            # ELFv2 TOC / r2 setup & save/restore
            if (($mlc =~ /^(?:addis|addi|ld|std)$/ && $operands =~ /\br2\b/)
                || $raw =~ /\.localentry|\.toc/i)
            {
                push @tags, 'toc';
                $summary{toc_count}++;
                $hl = 'XSAsmTOC' if $hl eq 'Normal';
            }

            # Weak-memory barriers & LL/SC atomic primitives
            if ($mlc =~ /^(?:lwsync|sync|hwsync|isync|eieio|lwarx|stwcx\.|ldarx|stdcx\.|lbarx|stbcx\.|lharx|sthcx\.)$/) {
                push @tags, 'barrier';
                $summary{barrier_count}++;
                $hl = 'XSAsmBarrier';
            }

            # POWER SMT priority yield hints (or 27,27,27 / yield / mdoio)
            if (($mlc eq 'or' && $operands =~ /^\s*(?:r?27\s*,\s*r?27\s*,\s*r?27|r?1\s*,\s*r?1\s*,\s*r?1|r?2\s*,\s*r?2\s*,\s*r?2)\b/)
                || $mlc eq 'yield')
            {
                push @tags, 'smt_yield';
                $summary{smt_yield_count}++;
                $hl = 'XSAsmSMT';
            }

            # Branches
            if ($mlc =~ /^(?:b|bl|blr|bctr|bctrl|bcl|bdnz|bdz|bne|beq|blt|bgt|ble|bge)[+-]?$/) {
                push @tags, 'branch';
                $summary{branch_count}++;
            }

            push @lines, {
                text     => $raw,
                kind     => 'insn',
                addr     => $addr,
                func     => $cur_fn,
                mnemonic => $mnemonic,
                operands => $operands,
                tags     => \@tags,
                hl       => $hl,
            };
        }
        else {
            my $is_toc_dir = ($raw =~ /\.localentry|\.toc/i) ? 1 : 0;
            $summary{toc_count}++ if $is_toc_dir;
            push @lines, {
                text => $raw,
                kind => 'source',
                func => $cur_fn,
                tags => ($is_toc_dir ? ['toc'] : []),
                hl   => ($is_toc_dir ? 'XSAsmTOC' : 'Comment'),
            };
        }
    }

    $summary{functions} = \@functions;
    return {
        ok      => 1,
        target  => $opts{target},
        arch    => $opts{arch},
        lines   => \@lines,
        summary => \%summary,
        text    => $asm_text,
    };
}

# -------------------------------------------------------------------------
# 2. :XSVecReport — GCC -fopt-info-vec & Clang -Rpass=loop-vectorize
# -------------------------------------------------------------------------

sub parse_vec_report {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my @entries;

    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;

        # GCC format:
        #   c/vec_simd.c:142:5: optimized: loop vectorized using 16 byte vectors
        #   c/fuzzy.c:88:9: missed: couldn't vectorize loop
        #   c/fuzzy.c:89:9: note: vectorized 1 loops in function.
        if ($raw =~ /^([^:\s][^:]*):(\d+):(\d+):\s+(optimized|missed):\s+(.+)$/) {
            my ($file, $line, $col, $status, $msg) = ($1, $2 + 0, $3 + 0, $4, $5);
            my $width = ($msg =~ /(\d+)\s+byte\s+vectors/i) ? "${1}B" : '';
            my $badge = $status eq 'optimized'
                ? ($width ? "[VSX vectorized $width]" : '[vectorized]')
                : "[missed: $msg]";
            $badge = substr($badge, 0, 56) . '...]' if length($badge) > 60;
            push @entries, {
                file     => $file,
                line     => $line,
                col      => $col,
                status   => $status,
                width    => $width,
                message  => $msg,
                badge    => $badge,
                hl       => ($status eq 'optimized' ? 'XSVecOpt' : 'XSVecMissed'),
            };
            next;
        }

        # Clang format:
        #   file.c:42:5: remark: vectorized loop (vectorization width: 4, interleaved count: 2) [-Rpass=loop-vectorize]
        #   file.c:60:5: remark: loop not vectorized: ... [-Rpass-missed=loop-vectorize]
        if ($raw =~ /^([^:\s][^:]*):(\d+):(\d+):\s+remark:\s+(.+?)\s+\[-Rpass(-missed)?=loop-vectorize\]/) {
            my ($file, $line, $col, $msg, $is_missed) = ($1, $2 + 0, $3 + 0, $4, $5);
            my $status = $is_missed ? 'missed' : 'optimized';
            my $width  = ($msg =~ /vectorization width:\s*(\d+)/i) ? "${1}x" : '';
            my $badge  = $status eq 'optimized'
                ? ($width ? "[vectorized $width]" : '[vectorized]')
                : "[missed: $msg]";
            $badge = substr($badge, 0, 56) . '...]' if length($badge) > 60;
            push @entries, {
                file    => $file,
                line    => $line,
                col     => $col,
                status  => $status,
                width   => $width,
                message => $msg,
                badge   => $badge,
                hl      => ($status eq 'optimized' ? 'XSVecOpt' : 'XSVecMissed'),
            };
        }
    }

    my $opt_cnt  = scalar grep { $_->{status} eq 'optimized' } @entries;
    my $miss_cnt = scalar grep { $_->{status} eq 'missed' }    @entries;
    my $rep = {
        ok        => 1,
        entries   => \@entries,
        optimized => $opt_cnt,
        missed    => $miss_cnt,
    };
    $self->{last_vec_report} = $rep;
    return $rep;
}

sub run_vec_report {
    my ($self, $c_file, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});
    my $cc     = $opts{cc} || $tools->{preferred_cc} || $tools->{cc};
    return { ok => 0, error => 'no C compiler found' } unless $cc;

    my $out_dir = $runner->ensure_build_dir('vec-report');
    my $obj_out = File::Spec->catfile($out_dir, File::Basename::basename($c_file) . '.o');

    my $ver = $runner->run_cmd([ $cc, '--version' ]);
    my $is_clang = (($ver->{stdout} // '') =~ /clang/i) ? 1 : 0;

    my @flags = ('-std=c11', '-O3', '-c');
    if ($is_clang) {
        push @flags, '-Rpass=loop-vectorize', '-Rpass-missed=loop-vectorize';
    }
    else {
        push @flags, '-fopt-info-vec-optimized', '-fopt-info-vec-missed';
        push @flags, '-mcpu=power8', '-mvsx' if $tools->{is_power};
    }
    push @flags, @{ $opts{extra_cflags} } if ref($opts{extra_cflags}) eq 'ARRAY';

    my $res = $runner->run_cmd([ $cc, @flags, $c_file, '-o', $obj_out ],
        remote => $opts{remote}, timeout => $opts{timeout} || 60);
    my $parsed = $self->parse_vec_report(($res->{stderr} // '') . "\n" . ($res->{stdout} // ''));
    $parsed->{compiler} = $cc;
    $parsed->{compile_ok} = $res->{ok};
    return $parsed;
}

sub paint_vec_annotations {
    my ($self, $buf, $report, %opts) = @_;
    return 0 unless $buf && $report && ref($report->{entries}) eq 'ARRAY';
    my $ns = 'xs_vec';
    my $core_buf = ($buf->can('core') && $buf->core) ? $buf->core : $buf;
    if ($buf->can('clear_namespace')) {
        $buf->clear_namespace($ns);
    }
    elsif ($core_buf->can('clear_namespace')) {
        $core_buf->clear_namespace($ns);
    }

    my $buf_path = $opts{file_path};
    $buf_path = $buf->path     if !defined($buf_path) && $buf->can('path');
    $buf_path = $buf->name     if !defined($buf_path) && $buf->can('name');
    $buf_path = $buf->filename if !defined($buf_path) && $buf->can('filename');
    $buf_path //= '';
    my $buf_base = length($buf_path) ? File::Basename::basename($buf_path) : '';
    my $count = 0;

    for my $e (@{ $report->{entries} }) {
        if (length($buf_base) && defined $e->{file}) {
            next unless File::Basename::basename($e->{file}) eq $buf_base;
        }
        my $mark = {
            namespace => $ns,
            line      => $e->{line} - 1,
            col       => 0,
            virt_text => "  $e->{badge}",
            virt_hl   => $e->{hl},
            virt_pos  => 'eol',
            priority  => 35,
        };
        if ($buf->can('set_extmark')) {
            eval { $buf->set_extmark($ns, $e->{line} - 1, 0, $mark) };
        }
        elsif ($core_buf->can('set_extmark')) {
            eval { $core_buf->set_extmark($ns, $e->{line} - 1, 0, $mark) };
        }
        $count++;
    }
    return $count;
}

# -------------------------------------------------------------------------
# 3. :XSPowerAudit (neoperl_xs_arch_audit) — IBM POWER8+ ppc64le Trap Auditor
# -------------------------------------------------------------------------

sub _strip_c_comments_and_strings {
    my ($text) = @_;
    # Preserve line count strictly while blanking comment/string interiors
    my $out = '';
    my $len = length($text);
    my $i   = 0;
    while ($i < $len) {
        my $c  = substr($text, $i, 1);
        my $c2 = ($i + 1 < $len) ? substr($text, $i, 2) : '';

        if ($c2 eq '/*') {
            $out .= '  ';
            $i += 2;
            while ($i < $len) {
                if (substr($text, $i, 2) eq '*/') {
                    $out .= '  ';
                    $i += 2;
                    last;
                }
                my $ch = substr($text, $i, 1);
                $out .= ($ch eq "\n") ? "\n" : ' ';
                $i++;
            }
        }
        elsif ($c2 eq '//') {
            while ($i < $len && substr($text, $i, 1) ne "\n") {
                $out .= ' ';
                $i++;
            }
        }
        elsif ($c eq '"' || $c eq "'") {
            my $q = $c;
            $out .= $q;
            $i++;
            while ($i < $len) {
                my $ch = substr($text, $i, 1);
                if ($ch eq '\\' && $i + 1 < $len) {
                    $out .= '  ';
                    $i += 2;
                    next;
                }
                $i++;
                if ($ch eq $q) {
                    $out .= $q;
                    last;
                }
                $out .= ($ch eq "\n") ? "\n" : ' ';
            }
        }
        else {
            $out .= $c;
            $i++;
        }
    }
    return $out;
}

sub audit_source {
    my ($self, $text, $file) = @_;
    $text = '' unless defined $text;
    $file = '<buffer>' unless defined $file;

    my $clean_src = _strip_c_comments_and_strings($text);
    my @raw_lines = split /\n/, $text, -1;
    my @lines     = split /\n/, $clean_src, -1;
    my @findings;

    # Track plain `char` variables (neither signed char nor unsigned char nor char *)
    my %plain_char_vars;
    my $has_altivec_inc    = 0;
    my $altivec_inc_line   = 0;
    my $has_undef_vector   = ($clean_src =~ /^\s*#\s*undef\s+vector\b/m) ? 1 : 0;
    my $has_power_smt_hint = ($text =~ /or\s+27\s*,\s*27\s*,\s*27|npl_cpu_relax|__ppc_yield/i) ? 1 : 0;

    for my $i (0 .. $#lines) {
        my $ln   = $i + 1;
        my $line = $lines[$i];
        my $raw  = $raw_lines[$i] // '';

        # Skip preprocessor comments/macros defining npl_page_size helper itself
        if ($raw =~ /^\s*#\s*include\s*<altivec\.h>/) {
            $has_altivec_inc  = 1;
            $altivec_inc_line = $ln;
        }

        # Collect plain `char` scalar variable declarations
        if ($line !~ /\b(?:signed|unsigned)\s+char\b/
            && $line =~ /\bchar\s+([A-Za-z_]\w*)(?:\s*=\s*([^;]+))?/)
        {
            my ($var, $init) = ($1, $2 // '');
            # Exclude pointer declarations (`char *p`) and arrays (`char buf[...]`)
            if ($line !~ /\bchar\s*\*/ && $line !~ /\bchar\s+\Q$var\E\s*\[/) {
                $plain_char_vars{$var} = $ln;

                # Trap 1a: char c = getchar()/fgetc()/getc()/getopt()
                if ($init =~ /\b(?:getchar|fgetc|getc|getopt)\s*\(/) {
                    push @findings, {
                        file       => $file,
                        line       => $ln,
                        col        => 1,
                        rule       => 'unsigned_char_trap',
                        severity   => 'error',
                        message    => "plain 'char $var' assigned int return of getchar/fgetc/getopt (unsigned char on ppc64le breaks EOF == -1)",
                        suggestion => "Change 'char $var' to 'int $var'",
                    };
                }
                # Trap 1b: char c = -1;
                elsif ($init =~ /^\s*-\s*\d+/) {
                    push @findings, {
                        file       => $file,
                        line       => $ln,
                        col        => 1,
                        rule       => 'unsigned_char_trap',
                        severity   => 'error',
                        message    => "plain 'char $var' initialized with negative literal (char is unsigned by default on ppc64le)",
                        suggestion => "Use 'signed char $var' or 'int8_t $var'",
                    };
                }
            }
        }

        # Trap 1c: plain char variable compared < 0, >= 0, == -1, == EOF
        for my $var (keys %plain_char_vars) {
            if ($line =~ /\b\Q$var\E\s*(?:<\s*0\b|>=\s*0\b|==\s*-\s*1\b|!=\s*-\s*1\b|==\s*EOF\b|!=\s*EOF\b)/) {
                push @findings, {
                    file       => $file,
                    line       => $ln,
                    col        => 1,
                    rule       => 'unsigned_char_trap',
                    severity   => 'error',
                    message    => "signed comparison on plain 'char $var' (always false/true on ppc64le where char is unsigned)",
                    suggestion => "Declare '$var' as 'signed char' or 'int'",
                };
                last;
            }
        }

        # Trap 2: Hardcoded 4 KiB page size assumptions (ppc64le Linux uses 64 KiB pages)
        if ($line !~ /sysconf\s*\(\s*_SC_PAGESIZE\s*\)|npl_page_size/
            && (
                $line =~ /\b(?:PAGE_SIZE|PAGESIZE)\b.*(?:4096|0x1000)/i
                || $line =~ /#\s*define\s+\w*PAGE\w*\s+(?:4096|0x1000)\b/i
                || ($line =~ /\b(?:mmap|mprotect|munmap|posix_memalign|aligned_alloc|page_size|page_align|pagesize)\b/i
                    && $line =~ /\b(?:4096|4095|0x1000|0xfff)\b/i)
                || $line =~ /&\s*~\s*(?:4095|0xfff)\b/i
            ))
        {
            push @findings, {
                file       => $file,
                line       => $ln,
                col        => 1,
                rule       => 'hardcoded_4k_page',
                severity   => 'warning',
                message    => 'hardcoded 4 KiB page constant (ppc64le Linux uses 64 KiB OS pages)',
                suggestion => 'Query page size dynamically via sysconf(_SC_PAGESIZE) / npl_page_size()',
            };
        }

        # Trap 3: Weak-memory-model synchronization traps (volatile flags or RELAXED publish/spin)
        if ($line =~ /\bvolatile\s+(?:int|unsigned|long|bool|_Bool|uint\d+_t|int\d+_t|sig_atomic_t)\s+\w*(?:flag|ready|done|lock|head|tail|state|stop|running)\w*/i) {
            push @findings, {
                file       => $file,
                line       => $ln,
                col        => 1,
                rule       => 'weak_memory_barrier',
                severity   => 'error',
                message    => 'volatile flag used for thread synchronization lacks acquire/release barriers on POWER weak memory model',
                suggestion => 'Use _Atomic / __atomic_load_n(..., __ATOMIC_ACQUIRE) and __atomic_store_n(..., __ATOMIC_RELEASE)',
            };
        }
        elsif ($line =~ /\b__atomic_(?:load|store)(?:_n)?\s*\([^)]*__ATOMIC_RELAXED\b/
               && $line =~ /\b(?:ready|done|flag|lock|tail|head|published|valid|state)\b/i)
        {
            push @findings, {
                file       => $file,
                line       => $ln,
                col        => 1,
                rule       => 'weak_memory_barrier',
                severity   => 'warning',
                message    => '__ATOMIC_RELAXED on synchronization variable without acquire/release barrier (unsafe on POWER weak ordering)',
                suggestion => 'Promote to __ATOMIC_ACQUIRE / __ATOMIC_RELEASE or emit __atomic_thread_fence(__ATOMIC_ACQ_REL)',
            };
        }

        # Trap 4: Spin-wait loops missing POWER SMT yield (`or 27,27,27`)
        if ($line =~ /\b_mm_pause\s*\(\s*\)/ && !$has_power_smt_hint) {
            push @findings, {
                file       => $file,
                line       => $ln,
                col        => 1,
                rule       => 'missing_smt_yield',
                severity   => 'warning',
                message    => 'x86 _mm_pause() spin-wait without POWER SMT yield fallback (starves sibling SMT-4/SMT-8 threads)',
                suggestion => 'Add #elif defined(__powerpc__) __asm__ __volatile__("or 27,27,27" ::: "memory")',
            };
        }
        elsif ($line =~ /\bwhile\s*\([^)]*(?:__atomic_load|atomic_load|lock|ready|flag|busy)[^)]*\)\s*(?:;|\{\s*\})/i) {
            push @findings, {
                file       => $file,
                line       => $ln,
                col        => 1,
                rule       => 'missing_smt_yield',
                severity   => 'warning',
                message    => 'tight spin-wait loop without POWER SMT priority yield hint',
                suggestion => 'Call npl_cpu_relax() / __asm__ __volatile__("or 27,27,27" ::: "memory") inside spin loop',
            };
        }

        # Trap 5: Unaligned pointer cast / strict aliasing risk
        if ($line =~ /\*\s*\(\s*(?:const\s+)?(?:u?int(?:16|32|64)_t|float|double)\s*\*\s*\)\s*\(?\s*[A-Za-z_]\w*\s*\+/) {
            push @findings, {
                file       => $file,
                line       => $ln,
                col        => 1,
                rule       => 'unaligned_endian_cast',
                severity   => 'warning',
                message    => 'unaligned pointer cast from byte offset (undefined behavior and endian/alignment trap)',
                suggestion => 'Copy bytes with memcpy() into a local typed variable',
            };
        }
    }

    # Trap 6: <altivec.h> without macro undef isolation
    if ($has_altivec_inc && !$has_undef_vector) {
        push @findings, {
            file       => $file,
            line       => $altivec_inc_line,
            col        => 1,
            rule       => 'altivec_macro_collision',
            severity   => 'error',
            message    => '<altivec.h> included without #undef vector/pixel/bool (collides with perl.h and <stdbool.h>)',
            suggestion => 'Add #undef vector / #undef pixel / #undef bool immediately after #include <altivec.h> and use __vector',
        };
    }

    my %by_rule;
    my ($errors, $warnings, $infos) = (0, 0, 0);
    for my $f (@findings) {
        $by_rule{ $f->{rule} }++;
        if    ($f->{severity} eq 'error')   { $errors++ }
        elsif ($f->{severity} eq 'warning') { $warnings++ }
        else                                { $infos++ }
    }

    my $result = {
        ok       => 1,
        file     => $file,
        clean    => (@findings == 0 ? 1 : 0),
        findings => \@findings,
        summary  => {
            total    => scalar(@findings),
            errors   => $errors,
            warnings => $warnings,
            infos    => $infos,
            by_rule  => \%by_rule,
        },
    };
    $self->{last_audit} = $result;
    return $result;
}

sub audit_file {
    my ($self, $path) = @_;
    return { ok => 0, error => "file not found: $path" } unless defined $path && -f $path;
    open my $fh, '<', $path or return { ok => 0, error => "cannot open $path: $!" };
    local $/;
    my $text = <$fh> // '';
    close $fh;
    return $self->audit_source($text, $path);
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::XSDev::Power - IBM POWER8+ ELFv2 disassembly, vectorization, and portability auditor

=head1 SYNOPSIS

    use NeoPerl::Plugin::XSDev::Power;

    my $pwr   = NeoPerl::Plugin::XSDev::Power->new(runner => $runner);
    my $audit = $pwr->audit_file('c/vec_simd.c');
    my $asm   = $pwr->annotate_asm($objdump_output);

=head1 DESCRIPTION

Implements IBM POWER8+ (C<ppc64le>) systems analysis tools for C<XSDev>:
C<:XSAsm> ELFv2 disassembly highlighting VSX, POWER10 MMA, TOC/C<r2>,
C<lwsync>/C<sync> barriers, and SMT yield hints; C<:XSVecReport> parsing
GCC C<-fopt-info-vec> and Clang C<-Rpass=loop-vectorize> remarks; and
C<:XSPowerAudit> (C<neoperl_xs_arch_audit>) static auditing for unsigned-C<char>
bugs, hardcoded 4 KiB page assumptions, weak memory ordering traps, missing SMT
yields, C<altivec.h> macro collisions, and unaligned pointer casts.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
