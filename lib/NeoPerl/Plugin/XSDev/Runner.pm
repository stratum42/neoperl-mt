package NeoPerl::Plugin::XSDev::Runner;

use strict;
use warnings;

use Config ();
use Cwd ();
use File::Basename ();
use File::Path ();
use File::Spec ();
use IPC::Open3 ();
use POSIX ();
use Symbol ();
use Time::HiRes ();

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $workdir = defined $opts{workdir} ? $opts{workdir} : Cwd::getcwd();
    return bless {
        workdir            => $workdir,
        xs_remote_host     => $opts{xs_remote_host},
        xs_remote_workdir  => $opts{xs_remote_workdir},
        xs_remote_ssh_opts => $opts{xs_remote_ssh_opts} || [ '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5' ],
        build_root         => $opts{build_root} || File::Spec->catdir($workdir, '.neoperl-build'),
        _tools_cache       => undef,
        _linemap_cache     => {},
    }, $class;
}

sub workdir           { $_[0]{workdir} }
sub build_root        { $_[0]{build_root} }
sub remote_host       { $_[0]{xs_remote_host} }
sub remote_workdir    { $_[0]{xs_remote_workdir} }
sub is_remote_enabled { defined($_[0]{xs_remote_host}) && length($_[0]{xs_remote_host}) ? 1 : 0 }

sub configure_remote {
    my ($self, %opts) = @_;
    $self->{xs_remote_host}     = $opts{xs_remote_host}     if exists $opts{xs_remote_host};
    $self->{xs_remote_workdir}  = $opts{xs_remote_workdir}  if exists $opts{xs_remote_workdir};
    $self->{xs_remote_ssh_opts} = $opts{xs_remote_ssh_opts} if exists $opts{xs_remote_ssh_opts};
    $self->{_tools_cache}       = undef;
    return $self;
}

sub _which {
    my ($bin) = @_;
    return undef unless defined $bin && length $bin;
    my $sep = $Config::Config{path_sep} || ':';
    for my $dir (split /\Q$sep\E/, ($ENV{PATH} || '')) {
        next unless length $dir;
        my $p = File::Spec->catfile($dir, $bin);
        return $p if -x $p && !-d $p;
    }
    return undef;
}

sub _shell_quote {
    my ($s) = @_;
    $s = '' unless defined $s;
    return "''" if $s eq '';
    return $s if $s =~ m{\A[A-Za-z0-9_./:=+-]+\z};
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub ensure_build_dir {
    my ($self, $subdir) = @_;
    my $dir = defined $subdir
        ? File::Spec->catdir($self->{build_root}, $subdir)
        : $self->{build_root};
    File::Path::make_path($dir) unless -d $dir;
    return $dir;
}

sub detect_tools {
    my ($self, %opts) = @_;
    return $self->{_tools_cache} if $self->{_tools_cache} && !$opts{refresh} && !$opts{remote};

    if ($opts{remote} && $self->is_remote_enabled) {
        return $self->_detect_remote_tools();
    }

    my $os   = $^O;
    my $arch = _detect_local_arch();

    my %tools = (
        os                 => $os,
        arch               => $arch,
        is_power           => ($arch =~ /^(?:ppc64|powerpc64)/i ? 1 : 0),
        is_macos           => ($os eq 'darwin' ? 1 : 0),
        is_linux           => ($os eq 'linux'  ? 1 : 0),
        clang              => _which('clang'),
        gcc                => _which('gcc'),
        cc                 => _which('cc') || _which('clang') || _which('gcc'),
        valgrind           => _which('valgrind'),
        cg_annotate        => _which('cg_annotate'),
        callgrind_annotate => _which('callgrind_annotate'),
        gdb                => _which('gdb'),
        lldb               => _which('lldb'),
        perf               => _which('perf'),
        objdump            => _which('objdump'),
        otool              => _which('otool'),
        llvm_profdata      => _find_llvm_profdata(),
        xsubpp             => _which('xsubpp'),
        prove              => _which('prove'),
        make               => _which('make'),
        rsync              => _which('rsync'),
        ssh                => _which('ssh'),
    );

    # Prefer clang on macOS, gcc or clang on Linux
    if ($tools{is_macos}) {
        $tools{preferred_cc}       = $tools{clang} || $tools{cc};
        $tools{preferred_debugger} = $tools{lldb}  || $tools{gdb};
        $tools{pgo_family}         = $tools{clang} ? 'clang' : ($tools{gcc} ? 'gcc' : undef);
    }
    else {
        $tools{preferred_cc}       = $tools{gcc}   || $tools{clang} || $tools{cc};
        $tools{preferred_debugger} = $tools{gdb}   || $tools{lldb};
        $tools{pgo_family}         = $tools{gcc}   ? 'gcc' : ($tools{clang} ? 'clang' : undef);
    }

    $tools{asan_rt} = $self->_find_sanitizer_rt('asan', \%tools);
    $tools{tsan_rt} = $self->_find_sanitizer_rt('tsan', \%tools);

    $self->{_tools_cache} = \%tools;
    return \%tools;
}

sub _detect_local_arch {
    my $m = '';
    if (eval { my @u = POSIX::uname(); $m = $u[4] || ''; 1 } && length $m) {
        return $m;
    }
    return $Config::Config{archname} || 'unknown';
}

sub _find_llvm_profdata {
    my $p = _which('llvm-profdata');
    return $p if defined $p;
    if ($^O eq 'darwin' && _which('xcrun')) {
        my $out = `xcrun --find llvm-profdata 2>/dev/null`;
        if (defined $out) {
            chomp $out;
            return $out if length($out) && -x $out;
        }
    }
    return undef;
}

sub _find_sanitizer_rt {
    my ($self, $kind, $tools) = @_;
    if ($tools->{is_macos} && $tools->{clang}) {
        my $name = $kind eq 'tsan'
            ? 'libclang_rt.tsan_osx_dynamic.dylib'
            : 'libclang_rt.asan_osx_dynamic.dylib';
        my $res = $self->run_cmd([ $tools->{clang}, "--print-file-name=$name" ]);
        if ($res->{ok}) {
            my $p = $res->{stdout};
            $p =~ s/\s+\z//;
            return $p if length($p) && -f $p;
        }
        # Probe standard Apple clang resource dir
        my $rdir = $self->run_cmd([ $tools->{clang}, '-print-resource-dir' ]);
        if ($rdir->{ok}) {
            my $base = $rdir->{stdout};
            $base =~ s/\s+\z//;
            my $cand = File::Spec->catfile($base, 'lib', 'darwin', $name);
            return $cand if -f $cand;
        }
    }
    elsif ($tools->{is_linux} && ($tools->{gcc} || $tools->{clang})) {
        my $cc   = $tools->{gcc} || $tools->{clang};
        my $name = $kind eq 'tsan' ? 'libtsan.so' : 'libasan.so';
        my $res  = $self->run_cmd([ $cc, "--print-file-name=$name" ]);
        if ($res->{ok}) {
            my $p = $res->{stdout};
            $p =~ s/\s+\z//;
            return $p if length($p) && $p ne $name && -f $p;
        }
    }
    return undef;
}

sub _detect_remote_tools {
    my ($self) = @_;
    my $probe = join('; ',
        'echo "os=$(uname -s | tr A-Z a-z)"',
        'echo "arch=$(uname -m)"',
        map { qq{echo "$_=\$(command -v $_ 2>/dev/null || true)"} }
            qw(clang gcc cc valgrind cg_annotate callgrind_annotate gdb lldb perf objdump llvm-profdata prove make)
    );
    my $res = $self->run_remote_shell($probe);
    my %tools = (remote => 1, host => $self->{xs_remote_host});
    if ($res->{ok}) {
        for my $line (split /\n/, $res->{stdout}) {
            if ($line =~ /^([a-zA-Z0-9_-]+)=(.*)$/) {
                my ($k, $v) = ($1, $2);
                $k =~ tr/-/_/;
                $tools{$k} = length($v) ? $v : undef;
            }
        }
    }
    $tools{is_power} = (($tools{arch} || '') =~ /^(?:ppc64|powerpc64)/i) ? 1 : 0;
    $tools{is_linux} = (($tools{os}   || '') eq 'linux') ? 1 : 0;
    $tools{is_macos} = (($tools{os}   || '') eq 'darwin') ? 1 : 0;
    return \%tools;
}

sub run_cmd {
    my ($self, $argv, %opts) = @_;
    return { ok => 0, exit_code => -1, stdout => '', stderr => 'empty argv' }
        unless ref($argv) eq 'ARRAY' && @$argv;

    if ($opts{remote} && $self->is_remote_enabled) {
        return $self->_run_cmd_remote($argv, %opts);
    }

    my $t0   = Time::HiRes::time();
    my $cwd  = $opts{cwd};
    my $orig = Cwd::getcwd();

    local %ENV = %ENV;
    if (ref($opts{env}) eq 'HASH') {
        for my $k (keys %{ $opts{env} }) {
            if (defined $opts{env}{$k}) {
                $ENV{$k} = $opts{env}{$k};
            }
            else {
                delete $ENV{$k};
            }
        }
    }

    if (defined $cwd && length $cwd && -d $cwd) {
        chdir $cwd or return {
            ok => 0, exit_code => -1, stdout => '', stderr => "chdir($cwd): $!", elapsed_ms => 0,
        };
    }

    my ($in, $out, $err);
    $err = Symbol::gensym();
    my $pid = eval { IPC::Open3::open3($in, $out, $err, @$argv) };
    if (!$pid) {
        my $e = $@ || "$!";
        chdir $orig if defined $cwd;
        return {
            ok         => 0,
            exit_code  => -1,
            stdout     => '',
            stderr     => "$e",
            elapsed_ms => (Time::HiRes::time() - $t0) * 1000.0,
            cmd        => [ @$argv ],
        };
    }

    if (defined $opts{stdin}) {
        print {$in} $opts{stdin};
    }
    close $in;

    # Non-blocking interleaved drain of stdout + stderr to prevent pipe deadlocks
    my ($stdout, $stderr) = ('', '');
    my $timeout = $opts{timeout};
    my $rin = '';
    vec($rin, fileno($out), 1) = 1;
    vec($rin, fileno($err), 1) = 1;
    my $open_out = 1;
    my $open_err = 1;
    my $timed_out = 0;

    while ($open_out || $open_err) {
        my $rem;
        if (defined $timeout) {
            $rem = $timeout - (Time::HiRes::time() - $t0);
            if ($rem <= 0) {
                $timed_out = 1;
                kill 'TERM', $pid;
                last;
            }
        }
        my $rset = '';
        vec($rset, fileno($out), 1) = 1 if $open_out;
        vec($rset, fileno($err), 1) = 1 if $open_err;
        my $nfound = select(my $rout = $rset, undef, undef, (defined $rem ? $rem : 0.25));
        next if $nfound <= 0;

        if ($open_out && vec($rout, fileno($out), 1)) {
            my $buf = '';
            my $n = sysread($out, $buf, 16384);
            if ($n) { $stdout .= $buf; }
            else    { $open_out = 0; }
        }
        if ($open_err && vec($rout, fileno($err), 1)) {
            my $buf = '';
            my $n = sysread($err, $buf, 16384);
            if ($n) { $stderr .= $buf; }
            else    { $open_err = 0; }
        }
    }

    close $out;
    close $err;
    waitpid($pid, 0);
    my $status    = $?;
    my $exit_code = $timed_out ? 124 : ($status == -1 ? -1 : ($status >> 8));
    my $signal    = $status & 127;

    chdir $orig if defined $cwd;

    return {
        ok         => (!$timed_out && $exit_code == 0 && $signal == 0) ? 1 : 0,
        exit_code  => $exit_code,
        signal     => $signal,
        timed_out  => $timed_out,
        stdout     => $stdout,
        stderr     => $stderr,
        elapsed_ms => (Time::HiRes::time() - $t0) * 1000.0,
        cmd        => [ @$argv ],
    };
}

sub sync_to_remote {
    my ($self, %opts) = @_;
    return { ok => 0, error => 'xs_remote_host and xs_remote_workdir must be configured' }
        unless $self->is_remote_enabled && defined $self->{xs_remote_workdir} && length $self->{xs_remote_workdir};

    my $host = $self->{xs_remote_host};
    my $rdir = $self->{xs_remote_workdir};
    my $ldir = $opts{local_dir} || $self->{workdir};
    $ldir =~ s{/*\z}{/};

    # Ensure remote scratch workdir exists
    my $mk = $self->run_remote_shell('mkdir -p ' . _shell_quote($rdir));
    return $mk unless $mk->{ok};

    my @rsync = (
        'rsync', '-az', '--delete',
        '--exclude', '.git/',
        '--exclude', 'blib/',
        '--exclude', '.neoperl-build/',
        '--exclude', '*.o',
        '--exclude', '*.bundle',
        '--exclude', '*.so',
        '-e', join(' ', 'ssh', @{ $self->{xs_remote_ssh_opts} }),
        $ldir,
        "${host}:${rdir}/",
    );
    return $self->run_cmd(\@rsync, timeout => $opts{timeout} || 60);
}

sub run_remote_shell {
    my ($self, $shell_cmd, %opts) = @_;
    return { ok => 0, exit_code => -1, stdout => '', stderr => 'xs_remote_host not configured' }
        unless $self->is_remote_enabled;

    my @ssh = ('ssh', @{ $self->{xs_remote_ssh_opts} }, $self->{xs_remote_host}, $shell_cmd);
    return $self->run_cmd(\@ssh, timeout => $opts{timeout} || 120);
}

sub _run_cmd_remote {
    my ($self, $argv, %opts) = @_;
    if ($opts{sync}) {
        my $sr = $self->sync_to_remote();
        return $sr unless $sr->{ok};
    }

    my @parts;
    if (defined $self->{xs_remote_workdir} && length $self->{xs_remote_workdir}) {
        push @parts, 'cd ' . _shell_quote($self->{xs_remote_workdir});
    }
    my @env_assigns;
    if (ref($opts{env}) eq 'HASH') {
        for my $k (sort keys %{ $opts{env} }) {
            next unless defined $opts{env}{$k};
            push @env_assigns, "$k=" . _shell_quote($opts{env}{$k});
        }
    }
    my $cmd_str = join(' ', @env_assigns, map { _shell_quote($_) } @$argv);
    push @parts, $cmd_str;

    return $self->run_remote_shell(join(' && ', @parts), timeout => $opts{timeout} || 120);
}

# -------------------------------------------------------------------------
# xsubpp #line directive parser & remote-to-local path remapping
# -------------------------------------------------------------------------

sub parse_xsubpp_linemap {
    my ($self, $c_file) = @_;
    return [] unless defined $c_file && -f $c_file;

    my $mtime = (stat($c_file))[9] || 0;
    if (exists $self->{_linemap_cache}{$c_file}
        && $self->{_linemap_cache}{$c_file}{mtime} == $mtime)
    {
        return $self->{_linemap_cache}{$c_file}{entries};
    }

    my @entries;
    if (open my $fh, '<', $c_file) {
        my $c_line = 0;
        while (my $line = <$fh>) {
            $c_line++;
            if ($line =~ /^\s*#\s*line\s+(\d+)\s+"([^"]+)"/) {
                push @entries, {
                    c_line    => $c_line,
                    orig_line => $1 + 0,
                    orig_file => $2,
                };
            }
        }
        close $fh;
    }

    $self->{_linemap_cache}{$c_file} = {
        mtime   => $mtime,
        entries => \@entries,
    };
    return \@entries;
}

sub map_remote_path {
    my ($self, $path) = @_;
    return $path unless defined $path && length $path;

    if (defined $self->{xs_remote_workdir} && length $self->{xs_remote_workdir}) {
        my $rdir = $self->{xs_remote_workdir};
        $rdir =~ s{/*\z}{};
        if ($path =~ s/^\Q$rdir\E(?:\/|$)//) {
            return File::Spec->catfile($self->{workdir}, $path);
        }
    }
    return $path;
}

sub map_location {
    my ($self, $file, $line, %opts) = @_;
    $line = ($line || 1) + 0;
    my $local_file = $self->map_remote_path($file // '');

    # Resolve relative paths against workdir
    my $resolved = $local_file;
    if (length($local_file) && !File::Spec->file_name_is_absolute($local_file)) {
        my $cand = File::Spec->catfile($self->{workdir}, $local_file);
        $resolved = $cand if -f $cand;
    }

    my $base_result = {
        file      => $resolved,
        line      => $line,
        orig_file => $local_file,
        orig_line => $line,
        mapped    => 0,
    };

    # Only map generated .c files containing #line directives back to .xs/.h
    return $base_result unless $resolved =~ /\.c\z/i && -f $resolved;

    my $entries = $self->parse_xsubpp_linemap($resolved);
    return $base_result unless $entries && @$entries;

    # Find last #line directive strictly before $line
    my $active;
    for my $e (@$entries) {
        last if $e->{c_line} >= $line;
        $active = $e;
    }
    return $base_result unless $active;

    my $delta       = $line - $active->{c_line} - 1;
    my $mapped_line = $active->{orig_line} + $delta;
    $mapped_line    = 1 if $mapped_line < 1;

    my $target_file = $active->{orig_file};
    my $c_base      = File::Basename::basename($resolved);
    my $t_base      = File::Basename::basename($target_file);

    # If #line points back to the generated .c file itself, keep original
    return $base_result if $t_base eq $c_base;

    # Resolve mapped file relative to the .c file's directory or workdir
    if (!File::Spec->file_name_is_absolute($target_file)) {
        my $in_c_dir = File::Spec->catfile(File::Basename::dirname($resolved), $target_file);
        my $in_wd    = File::Spec->catfile($self->{workdir}, $target_file);
        if (-f $in_c_dir) {
            $target_file = $in_c_dir;
        }
        elsif (-f $in_wd) {
            $target_file = $in_wd;
        }
    }

    return {
        file      => $target_file,
        line      => $mapped_line,
        orig_file => $resolved,
        orig_line => $line,
        mapped    => 1,
    };
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::XSDev::Runner - Unified local and remote SSH XS tool runner

=head1 SYNOPSIS

    use NeoPerl::Plugin::XSDev::Runner;

    my $runner = NeoPerl::Plugin::XSDev::Runner->new(workdir => '.');
    my $tools  = $runner->detect_tools;
    my $loc    = $runner->map_location('Core.c', 120);

=head1 DESCRIPTION

Detects local or optional SSH-configured remote C/XS engineering tools
(Clang, GCC, Valgrind, Cachegrind, GDB, LLDB, Linux C<perf>, C<objdump>,
C<llvm-profdata>), runs commands cleanly without shell interpolation, manages
isolated C<.neoperl-build/> directories, and maps remote paths and C<xsubpp>
C<#line> directives back onto local C<.xs> and C<.c> source buffers.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
