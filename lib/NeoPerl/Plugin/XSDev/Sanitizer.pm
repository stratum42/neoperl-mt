package NeoPerl::Plugin::XSDev::Sanitizer;

use strict;
use warnings;

use File::Basename ();
use File::Spec ();

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    return bless {
        runner        => $opts{runner},
        last_findings => [],
        last_tool     => undef,
    }, $class;
}

sub last_findings { $_[0]{last_findings} }
sub last_tool     { $_[0]{last_tool} }

# -------------------------------------------------------------------------
# 1. Suppression files & sanitizer environment for XS prove runs
# -------------------------------------------------------------------------

sub generate_perl_suppressions {
    my ($self) = @_;
    my $runner = $self->{runner};
    my $dir    = $runner ? $runner->ensure_build_dir('suppressions') : '.neoperl-build/suppressions';

    my $vg_supp = File::Spec->catfile($dir, 'perl_valgrind.supp');
    if (open my $fh, '>', $vg_supp) {
        print {$fh} <<'EOF';
{
   perl_global_init_leak
   Memcheck:Leak
   match-leak-kinds: reachable,possible
   ...
   fun:perl_parse
}
{
   perl_dyld_loader_cond
   Memcheck:Cond
   ...
   fun:dlopen*
}
{
   perl_xs_boot_reachable
   Memcheck:Leak
   match-leak-kinds: reachable
   ...
   fun:Perl_newXS*
}
EOF
        close $fh;
    }

    my $lsan_supp = File::Spec->catfile($dir, 'perl_lsan.supp');
    if (open my $fh, '>', $lsan_supp) {
        print {$fh} "leak:perl_parse\nleak:Perl_newXS\nleak:S_init_main_stash\n";
        close $fh;
    }

    my $tsan_supp = File::Spec->catfile($dir, 'perl_tsan.supp');
    if (open my $fh, '>', $tsan_supp) {
        print {$fh} "race:Perl_sv_clear\n";
        close $fh;
    }

    return {
        valgrind => $vg_supp,
        lsan     => $lsan_supp,
        tsan     => $tsan_supp,
    };
}

sub sanitizer_env {
    my ($self, $profile, %opts) = @_;
    my $runner = $self->{runner};
    my $tools  = $runner ? $runner->detect_tools(remote => $opts{remote}) : {};
    my $supps  = $self->generate_perl_suppressions();
    my %env;

    if ($profile eq 'asan') {
        $env{ASAN_OPTIONS}  = 'detect_leaks=0:halt_on_error=0:print_stacktrace=1:symbolize=1';
        $env{UBSAN_OPTIONS} = 'print_stacktrace=1:halt_on_error=0';
        $env{LSAN_OPTIONS}  = "suppressions=$supps->{lsan}" if -f $supps->{lsan};
        if ($opts{preload} && $tools->{asan_rt}) {
            if ($tools->{is_macos}) {
                $env{DYLD_INSERT_LIBRARIES} = $tools->{asan_rt};
            }
            else {
                $env{LD_PRELOAD} = $tools->{asan_rt};
            }
        }
    }
    elsif ($profile eq 'tsan') {
        my $ts_opt = 'halt_on_error=0:second_deadlock_stack=1:history_size=4';
        $ts_opt .= ":suppressions=$supps->{tsan}" if $opts{use_perl_suppressions} && -f $supps->{tsan};
        $env{TSAN_OPTIONS} = $ts_opt;
        if ($opts{preload} && $tools->{tsan_rt}) {
            if ($tools->{is_macos}) {
                $env{DYLD_INSERT_LIBRARIES} = $tools->{tsan_rt};
            }
            else {
                $env{LD_PRELOAD} = $tools->{tsan_rt};
            }
        }
    }
    return \%env;
}

# -------------------------------------------------------------------------
# 2. Isolated .neoperl-build/{debug,asan,tsan}/ C11 harness & XS builders
# -------------------------------------------------------------------------

sub profile_cflags {
    my ($self, $profile) = @_;
    return [ '-g', '-O1', '-fno-omit-frame-pointer', '-fsanitize=address,undefined' ] if $profile eq 'asan';
    return [ '-g', '-O1', '-fno-omit-frame-pointer', '-fsanitize=thread' ]            if $profile eq 'tsan';
    return [ '-g', '-O0', '-fno-omit-frame-pointer' ];
}

sub build_c_harness {
    my ($self, $profile, $c_source_or_file, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});
    my $cc     = $opts{cc} || $tools->{preferred_cc} || $tools->{cc};
    return { ok => 0, error => 'no C compiler found' } unless $cc;

    my $build_dir = $runner->ensure_build_dir($profile);
    my $name      = $opts{name} || "harness_${profile}";
    my $src_file;

    if (defined $c_source_or_file && $c_source_or_file !~ /[\r\n]/ && -f $c_source_or_file) {
        $src_file = $c_source_or_file;
    }
    else {
        $src_file = File::Spec->catfile($build_dir, "${name}.c");
        open my $fh, '>', $src_file or return { ok => 0, error => "cannot write $src_file: $!" };
        print {$fh} $c_source_or_file;
        close $fh;
    }

    my $bin_file = File::Spec->catfile($build_dir, $name);
    my @cflags   = ('-std=c11', @{ $self->profile_cflags($profile) });
    push @cflags, @{ $opts{extra_cflags} } if ref($opts{extra_cflags}) eq 'ARRAY';
    my @extra_srcs = ref($opts{extra_sources}) eq 'ARRAY' ? @{ $opts{extra_sources} } : ();
    my @ldflags    = ref($opts{ldflags}) eq 'ARRAY'       ? @{ $opts{ldflags} }       : ();
    push @ldflags, '-lpthread' if $profile eq 'tsan' && !$tools->{is_macos};

    my @cmd = ($cc, @cflags, $src_file, @extra_srcs, '-o', $bin_file, @ldflags);
    my $res = $runner->run_cmd(\@cmd, timeout => $opts{timeout} || 60);

    return {
        ok        => $res->{ok},
        profile   => $profile,
        build_dir => $build_dir,
        src_file  => $src_file,
        binary    => $bin_file,
        compiler  => $cc,
        stdout    => $res->{stdout},
        stderr    => $res->{stderr},
        exit_code => $res->{exit_code},
    };
}

sub run_asan_harness {
    my ($self, $c_source_or_file, %opts) = @_;
    my $build = $self->build_c_harness('asan', $c_source_or_file, %opts);
    return $build unless $build->{ok};

    my $env = $self->sanitizer_env('asan');
    my $run = $self->{runner}->run_cmd(
        [ $build->{binary}, @{ $opts{args} || [] } ],
        env     => $env,
        timeout => $opts{timeout} || 30,
    );
    my $combined = ($run->{stderr} // '') . "\n" . ($run->{stdout} // '');
    my $findings = $self->parse_asan_ubsan($combined);

    $self->{last_findings} = $findings;
    $self->{last_tool}     = 'asan';

    return {
        ok         => 1,
        tool       => 'asan',
        clean      => (@$findings == 0 && $run->{ok}) ? 1 : 0,
        build_dir  => $build->{build_dir},
        binary     => $build->{binary},
        exit_code  => $run->{exit_code},
        elapsed_ms => $run->{elapsed_ms},
        findings   => $findings,
        raw_output => $combined,
    };
}

sub run_tsan_harness {
    my ($self, $c_source_or_file, %opts) = @_;
    my $build = $self->build_c_harness('tsan', $c_source_or_file, %opts);
    return $build unless $build->{ok};

    my $env = $self->sanitizer_env('tsan');
    my $run = $self->{runner}->run_cmd(
        [ $build->{binary}, @{ $opts{args} || [] } ],
        env     => $env,
        timeout => $opts{timeout} || 30,
    );
    my $combined = ($run->{stderr} // '') . "\n" . ($run->{stdout} // '');
    my $findings = $self->parse_tsan($combined);

    $self->{last_findings} = $findings;
    $self->{last_tool}     = 'tsan';

    return {
        ok         => 1,
        tool       => 'tsan',
        clean      => (@$findings == 0 && $run->{ok}) ? 1 : 0,
        build_dir  => $build->{build_dir},
        binary     => $build->{binary},
        exit_code  => $run->{exit_code},
        elapsed_ms => $run->{elapsed_ms},
        findings   => $findings,
        raw_output => $combined,
    };
}

sub run_valgrind {
    my ($self, $target_argv, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});
    if (!$tools->{valgrind}) {
        return {
            ok    => 0,
            error => 'valgrind not found on target host',
        };
    }

    my $supps = $self->generate_perl_suppressions();
    my @cmd = (
        $tools->{valgrind},
        '--tool=memcheck',
        '--leak-check=full',
        '--track-origins=yes',
        '--show-leak-kinds=definite,indirect',
    );
    if (!$opts{remote} && $opts{use_perl_suppressions} && -f $supps->{valgrind}) {
        push @cmd, "--suppressions=$supps->{valgrind}";
    }
    push @cmd, @$target_argv;

    my $run = $runner->run_cmd(\@cmd, remote => $opts{remote}, timeout => $opts{timeout} || 180);
    my $combined = ($run->{stderr} // '') . "\n" . ($run->{stdout} // '');
    my $findings = $self->parse_valgrind($combined);

    $self->{last_findings} = $findings;
    $self->{last_tool}     = 'valgrind';

    return {
        ok         => 1,
        tool       => 'valgrind',
        clean      => (@$findings == 0 && $run->{ok}) ? 1 : 0,
        exit_code  => $run->{exit_code},
        elapsed_ms => $run->{elapsed_ms},
        findings   => $findings,
        raw_output => $combined,
    };
}

# -------------------------------------------------------------------------
# 3. Parsers: ASan/UBSan, TSan, Valgrind Memcheck (with #line -> .xs mapping)
# -------------------------------------------------------------------------

sub _map_loc {
    my ($self, $file, $line) = @_;
    if ($self->{runner}) {
        return $self->{runner}->map_location($file, $line);
    }
    return { file => $file, line => $line + 0, orig_file => $file, orig_line => $line + 0, mapped => 0 };
}

sub parse_asan_ubsan {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my @findings;
    my @lines = split /\n/, $text;

    my $cur;
    for my $raw (@lines) {
        $raw =~ s/\r\z//;

        # UBSan single-line runtime error: file.c:5:5: runtime error: ...
        if ($raw =~ /^([^:\s][^:]*):(\d+):(\d+):\s+runtime error:\s+(.+)$/) {
            my ($f, $ln, $col, $msg) = ($1, $2 + 0, $3 + 0, $4);
            my $loc = $self->_map_loc($f, $ln);
            push @findings, {
                tool      => 'ubsan',
                kind      => 'undefined-behavior',
                severity  => 'error',
                file      => $loc->{file},
                line      => $loc->{line},
                col       => $col,
                orig_file => $loc->{orig_file},
                orig_line => $loc->{orig_line},
                mapped_xs => $loc->{mapped},
                message   => "UBSan: $msg",
                frames    => [],
            };
            next;
        }

        # ASan header: ==1234==ERROR: AddressSanitizer: heap-buffer-overflow on address ...
        if ($raw =~ /ERROR:\s+AddressSanitizer:\s+(\S+)(.*)$/) {
            push @findings, $cur if $cur;
            my ($kind, $detail) = ($1, $2 // '');
            $detail =~ s/^\s+//;
            $cur = {
                tool     => 'asan',
                kind     => $kind,
                severity => 'error',
                file     => undef,
                line     => undef,
                col      => 1,
                message  => "ASan $kind" . (length($detail) ? " $detail" : ''),
                frames   => [],
            };
            next;
        }

        # ASan summary resets current block
        if ($cur && $raw =~ /^SUMMARY:\s+AddressSanitizer:/) {
            push @findings, $cur;
            $cur = undef;
            next;
        }

        # ASan stack frame:
        #   #0 0x104fc4920 in main asan_t.c:5
        #   #0 0x55... in func /path/to/file.c:42:10
        if ($cur && $raw =~ /^\s*#(\d+)\s+(0x[0-9a-fA-F]+)\s+in\s+(\S+)\s+([^:\s()]+):(\d+)(?::(\d+))?/) {
            my ($idx, $addr, $fn, $f, $ln, $col) = ($1 + 0, $2, $3, $4, $5 + 0, ($6 || 1) + 0);
            my $loc = $self->_map_loc($f, $ln);
            my $frame = {
                index     => $idx,
                addr      => $addr,
                func      => $fn,
                file      => $loc->{file},
                line      => $loc->{line},
                col       => $col,
                orig_file => $loc->{orig_file},
                orig_line => $loc->{orig_line},
                mapped_xs => $loc->{mapped},
            };
            push @{ $cur->{frames} }, $frame;
            if (!defined $cur->{file}) {
                $cur->{file}      = $loc->{file};
                $cur->{line}      = $loc->{line};
                $cur->{col}       = $col;
                $cur->{func}      = $fn;
                $cur->{orig_file} = $loc->{orig_file};
                $cur->{orig_line} = $loc->{orig_line};
                $cur->{mapped_xs} = $loc->{mapped};
            }
            next;
        }

        # Access description: WRITE of size 1 at 0x... thread T0
        if ($cur && !$cur->{access} && $raw =~ /^\s*(READ|WRITE)\s+of\s+size\s+(\d+)\s+at\s+(0x[0-9a-fA-F]+)/) {
            $cur->{access}  = "$1 of size $2 at $3";
            $cur->{message} = "ASan $cur->{kind}: $1 of size $2";
        }
    }
    push @findings, $cur if $cur;
    return \@findings;
}

sub parse_tsan {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my @findings;
    my $cur;
    my $cur_thread_group;

    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;

        if ($raw =~ /^WARNING:\s+ThreadSanitizer:\s+([^(]+?)(?:\s*\(pid=\d+\))?\s*$/) {
            push @findings, $cur if $cur;
            my $kind = $1;
            $kind =~ s/\s+\z//;
            $cur = {
                tool     => 'tsan',
                kind     => $kind,
                severity => 'error',
                file     => undef,
                line     => undef,
                col      => 1,
                message  => "TSan: $kind",
                threads  => [],
                frames   => [],
            };
            $cur_thread_group = undef;
            next;
        }

        if ($cur && $raw =~ /^SUMMARY:\s+ThreadSanitizer:\s*(.+)$/) {
            $cur->{summary} = $1;
            push @findings, $cur;
            $cur = undef;
            $cur_thread_group = undef;
            next;
        }

        # Thread access header:
        #   Write of size 4 at 0x... by thread T2:
        #   Previous write of size 4 at 0x... by thread T1:
        if ($cur && $raw =~ /^\s*((?:Previous\s+)?(?:Write|Read|Atomic\s+write|Atomic\s+read)\s+of\s+size\s+\d+\s+at\s+\S+\s+by\s+(?:main\s+)?thread\s*\S*):/i) {
            $cur_thread_group = {
                access => $1,
                frames => [],
            };
            push @{ $cur->{threads} }, $cur_thread_group;
            next;
        }

        # TSan stack frame:
        #   #0 worker tsan_t.c:4 (tsan_t:arm64+0x100000724)
        #   #0 worker /path/file.c:4:12 (tsan_t+0x1234)
        if ($cur && $raw =~ /^\s*#(\d+)\s+(\S+)\s+([^:\s()]+):(\d+)(?::(\d+))?/) {
            my ($idx, $fn, $f, $ln, $col) = ($1 + 0, $2, $3, $4 + 0, ($5 || 1) + 0);
            next if $f eq '<null>';
            my $loc = $self->_map_loc($f, $ln);
            my $frame = {
                index     => $idx,
                func      => $fn,
                file      => $loc->{file},
                line      => $loc->{line},
                col       => $col,
                orig_file => $loc->{orig_file},
                orig_line => $loc->{orig_line},
                mapped_xs => $loc->{mapped},
            };
            push @{ $cur->{frames} }, $frame;
            push @{ $cur_thread_group->{frames} }, $frame if $cur_thread_group;
            if (!defined $cur->{file}) {
                $cur->{file}      = $loc->{file};
                $cur->{line}      = $loc->{line};
                $cur->{col}       = $col;
                $cur->{func}      = $fn;
                $cur->{orig_file} = $loc->{orig_file};
                $cur->{orig_line} = $loc->{orig_line};
                $cur->{mapped_xs} = $loc->{mapped};
            }
            next;
        }
    }
    push @findings, $cur if $cur;
    return \@findings;
}

sub parse_valgrind {
    my ($self, $text) = @_;
    $text = '' unless defined $text;
    my @findings;
    my $cur;

    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;
        # Strip Valgrind ==PID== prefix
        next unless $raw =~ /^==\d+==\s?(.*)$/;
        my $body = $1;

        if ($body eq '') {
            if ($cur && (defined $cur->{file} || @{ $cur->{frames} })) {
                push @findings, $cur;
            }
            $cur = undef;
            next;
        }

        if ($body =~ /^(Invalid\s+(?:read|write)\s+of\s+size\s+\d+|Use\s+of\s+uninitialised\s+value.*|Conditional\s+jump\s+or\s+move\s+depends\s+on\s+uninitialised.*|[\d,]+\s+bytes\s+in\s+[\d,]+\s+blocks\s+are\s+(?:definitely|indirectly)\s+lost.*|Invalid\s+free\(\).*|Mismatched\s+free\(\).*)/) {
            push @findings, $cur if $cur && (defined $cur->{file} || @{ $cur->{frames} });
            my $msg = $1;
            my $kind = 'memcheck';
            $kind = 'invalid-access' if $msg =~ /^Invalid\s+(?:read|write)/;
            $kind = 'uninit-value'   if $msg =~ /uninitialised/;
            $kind = 'memory-leak'    if $msg =~ /lost/;
            $kind = 'invalid-free'   if $msg =~ /free/;
            $cur = {
                tool     => 'valgrind',
                kind     => $kind,
                severity => ($kind eq 'memory-leak' ? 'warning' : 'error'),
                file     => undef,
                line     => undef,
                col      => 1,
                message  => "Valgrind: $msg",
                frames   => [],
            };
            next;
        }

        # Stack frame: at 0x401234: func_name (file.c:42)  OR  by 0x...: func (Core.c:120)
        if ($cur && $body =~ /^\s*(?:at|by)\s+(0x[0-9a-fA-F]+):\s+([^(]+?)\s+\(([^:()]+):(\d+)\)/) {
            my ($addr, $fn, $f, $ln) = ($1, $2, $3, $4 + 0);
            $fn =~ s/\s+\z//;
            my $loc = $self->_map_loc($f, $ln);
            my $frame = {
                addr      => $addr,
                func      => $fn,
                file      => $loc->{file},
                line      => $loc->{line},
                orig_file => $loc->{orig_file},
                orig_line => $loc->{orig_line},
                mapped_xs => $loc->{mapped},
            };
            push @{ $cur->{frames} }, $frame;
            if (!defined $cur->{file}) {
                $cur->{file}      = $loc->{file};
                $cur->{line}      = $loc->{line};
                $cur->{func}      = $fn;
                $cur->{orig_file} = $loc->{orig_file};
                $cur->{orig_line} = $loc->{orig_line};
                $cur->{mapped_xs} = $loc->{mapped};
            }
        }
    }
    push @findings, $cur if $cur && (defined $cur->{file} || @{ $cur->{frames} });
    return \@findings;
}

sub to_diagnostics {
    my ($self, $findings, %opts) = @_;
    $findings ||= $self->{last_findings} || [];
    my $filter_file = $opts{file_path};
    my $filter_base = defined $filter_file ? File::Basename::basename($filter_file) : undef;

    my @diags;
    for my $f (@$findings) {
        next unless defined $f->{line};
        if (defined $filter_base && defined $f->{file}) {
            next unless File::Basename::basename($f->{file}) eq $filter_base;
        }
        push @diags, {
            file     => $f->{file},
            line     => $f->{line},
            col      => $f->{col} || 1,
            severity => $f->{severity} || 'error',
            source   => 'xs_' . ($f->{tool} || 'sanitizer'),
            message  => $f->{message} . ($f->{mapped_xs} ? " (from $f->{orig_file}:$f->{orig_line})" : ''),
            kind     => $f->{kind},
        };
    }
    return \@diags;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::XSDev::Sanitizer - Isolated ASan, UBSan, TSan, and Valgrind Memcheck engine

=head1 SYNOPSIS

    use NeoPerl::Plugin::XSDev::Sanitizer;

    my $san = NeoPerl::Plugin::XSDev::Sanitizer->new(runner => $runner);
    my $res = $san->run_asan_harness($c_source);

=head1 DESCRIPTION

Builds and executes standalone C11 harnesses or XS test suites inside isolated
C<.neoperl-build/{debug,asan,tsan}/> directories without disturbing main
C<blib/> artifacts. Generates Perl suppression files and C<DYLD_INSERT_LIBRARIES>
/ C<LD_PRELOAD> environments, parses Valgrind Memcheck, ASan/UBSan, and
two-thread TSan data races, maps C<xsubpp> C<#line> directives back to C<.xs>
lines, and exports structured diagnostics.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
