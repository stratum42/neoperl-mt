package NeoPerl::Plugin::XSDev::PGO;

use strict;
use warnings;

use File::Basename ();
use File::Copy ();
use File::Spec ();
use Time::HiRes ();

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    return bless {
        runner      => $opts{runner},
        last_report => undef,
    }, $class;
}

sub last_report { $_[0]{last_report} }

sub _median {
    my @vals = sort { $a <=> $b } @_;
    return 0 unless @vals;
    my $mid = int(@vals / 2);
    return (@vals % 2) ? $vals[$mid] : (($vals[$mid - 1] + $vals[$mid]) / 2.0);
}

sub _time_binary {
    my ($self, $binary, $args, $runs, %opts) = @_;
    $runs ||= 3;
    my @samples;
    my $last_stdout = '';
    for (1 .. $runs) {
        my $t0 = Time::HiRes::time();
        my $r  = $self->{runner}->run_cmd([ $binary, @{ $args || [] } ],
            env     => $opts{env},
            timeout => $opts{timeout} || 60,
        );
        my $dt = (Time::HiRes::time() - $t0) * 1000.0;
        return { ok => 0, error => "binary failed: $r->{stderr}", exit_code => $r->{exit_code} }
            unless $r->{ok};
        push @samples, $dt;
        $last_stdout = $r->{stdout};
    }
    return {
        ok        => 1,
        median_ms => _median(@samples),
        samples   => \@samples,
        stdout    => $last_stdout,
    };
}

sub power_cpu_flags {
    my ($self, $power_cpu) = @_;
    return () unless defined $power_cpu && length $power_cpu;
    my %allowed = map { $_ => 1 } qw(power8 power9 power10 native);
    return () unless $allowed{ lc($power_cpu) };
    my @flags = ('-mcpu=' . lc($power_cpu));
    push @flags, '-mvsx' if lc($power_cpu) ne 'native';
    return @flags;
}

# -------------------------------------------------------------------------
# Two-stage isolated Clang / GCC PGO pipeline in .neoperl-build/{pgo-base,pgo-gen,pgo-use}/
# -------------------------------------------------------------------------

sub run_c_pgo {
    my ($self, $c_source_or_file, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});

    my $family = $opts{family} || $tools->{pgo_family};
    my $cc     = $opts{cc} || ($family && $family eq 'gcc' ? $tools->{gcc} : $tools->{clang}) || $tools->{preferred_cc};
    return { ok => 0, error => 'no suitable Clang or GCC compiler found' } unless $cc;

    if (!$family) {
        my $v = $runner->run_cmd([ $cc, '--version' ]);
        $family = (($v->{stdout} // '') =~ /clang/i) ? 'clang' : 'gcc';
    }

    if ($family eq 'clang' && !$tools->{llvm_profdata}) {
        return { ok => 0, error => 'llvm-profdata not found (required for Clang 2-stage PGO)' };
    }

    my $base_dir = $runner->ensure_build_dir('pgo-base');
    my $gen_dir  = $runner->ensure_build_dir('pgo-gen');
    my $use_dir  = $runner->ensure_build_dir('pgo-use');

    my $name = $opts{name} || 'pgo_bench';
    my $src_file;
    if (defined $c_source_or_file && $c_source_or_file !~ /[\r\n]/ && -f $c_source_or_file) {
        $src_file = $c_source_or_file;
    }
    else {
        $src_file = File::Spec->catfile($base_dir, "${name}.c");
        open my $fh, '>', $src_file or return { ok => 0, error => "cannot write $src_file: $!" };
        print {$fh} $c_source_or_file;
        close $fh;
    }

    my @common_flags = ('-std=c11', '-O3');
    my $power_cpu = $opts{power_cpu};
    if ($tools->{is_power} && !defined $power_cpu) {
        $power_cpu = 'power8';
    }
    push @common_flags, $self->power_cpu_flags($power_cpu) if $tools->{is_power} && defined $power_cpu;
    push @common_flags, @{ $opts{extra_cflags} } if ref($opts{extra_cflags}) eq 'ARRAY';
    my @extra_srcs = ref($opts{extra_sources}) eq 'ARRAY' ? @{ $opts{extra_sources} } : ();
    my @ldflags    = ref($opts{ldflags}) eq 'ARRAY'       ? @{ $opts{ldflags} }       : ();

    my $train_args = $opts{train_args} || [];
    my $bench_args = $opts{bench_args} || $train_args;
    my $runs       = $opts{runs}       || 3;
    my @stages;

    # Stage 0: Baseline -O3 build & timing
    my $base_bin = File::Spec->catfile($base_dir, $name);
    my $b0 = $runner->run_cmd([ $cc, @common_flags, $src_file, @extra_srcs, '-o', $base_bin, @ldflags ]);
    return { ok => 0, stage => 'baseline_build', error => $b0->{stderr} } unless $b0->{ok};

    my $t_base = $self->_time_binary($base_bin, $bench_args, $runs);
    return { ok => 0, stage => 'baseline_run', error => $t_base->{error} } unless $t_base->{ok};
    push @stages, { stage => 'baseline', ok => 1, median_ms => $t_base->{median_ms}, binary => $base_bin };

    # Stage 1: Instrumented profile-generate build + training workload
    my $gen_bin       = File::Spec->catfile($gen_dir, $name);
    my $profdata_path = '';
    my $gen_cflags    = [];
    my $use_cflags    = [];

    if ($family eq 'clang') {
        $gen_cflags = [ '-fprofile-instr-generate' ];
        my $profraw = File::Spec->catfile($gen_dir, "${name}.profraw");
        unlink $profraw if -f $profraw;
        $profdata_path = File::Spec->catfile($gen_dir, "${name}.profdata");
        unlink $profdata_path if -f $profdata_path;

        my $b1 = $runner->run_cmd([ $cc, @common_flags, @$gen_cflags, $src_file, @extra_srcs, '-o', $gen_bin, @ldflags ]);
        return { ok => 0, stage => 'pgo_gen_build', error => $b1->{stderr} } unless $b1->{ok};

        my $train = $runner->run_cmd(
            [ $gen_bin, @$train_args ],
            env     => { LLVM_PROFILE_FILE => $profraw },
            timeout => $opts{timeout} || 60,
        );
        return { ok => 0, stage => 'pgo_train', error => $train->{stderr} } unless $train->{ok};
        return { ok => 0, stage => 'pgo_train', error => "missing profraw at $profraw" } unless -f $profraw;

        my $merge = $runner->run_cmd([ $tools->{llvm_profdata}, 'merge', '-output=' . $profdata_path, $profraw ]);
        return { ok => 0, stage => 'llvm_profdata_merge', error => $merge->{stderr} } unless $merge->{ok};

        push @stages, {
            stage         => 'pgo_gen',
            ok            => 1,
            profraw_path  => $profraw,
            profdata_path => $profdata_path,
            profdata_size => (-s $profdata_path) || 0,
        };
        $use_cflags = [ "-fprofile-instr-use=$profdata_path" ];
    }
    else {
        # GCC 2-stage PGO (-fprofile-generate / -fprofile-use)
        my $gcda_dir = File::Spec->catdir($gen_dir, 'gcda');
        $runner->ensure_build_dir(File::Spec->catdir('pgo-gen', 'gcda'));
        $gen_cflags = [ "-fprofile-generate=$gcda_dir" ];

        my $b1 = $runner->run_cmd([ $cc, @common_flags, @$gen_cflags, $src_file, @extra_srcs, '-o', $gen_bin, @ldflags ]);
        return { ok => 0, stage => 'pgo_gen_build', error => $b1->{stderr} } unless $b1->{ok};

        my $train = $runner->run_cmd([ $gen_bin, @$train_args ], timeout => $opts{timeout} || 60);
        return { ok => 0, stage => 'pgo_train', error => $train->{stderr} } unless $train->{ok};

        $profdata_path = $gcda_dir;
        push @stages, {
            stage         => 'pgo_gen',
            ok            => 1,
            profdata_path => $gcda_dir,
        };
        $use_cflags = [ "-fprofile-use=$gcda_dir", '-fprofile-correction' ];
    }

    # Stage 2: Profile-guided optimized build & timing
    my $use_bin = File::Spec->catfile($use_dir, $name);
    my $b2 = $runner->run_cmd([ $cc, @common_flags, @$use_cflags, $src_file, @extra_srcs, '-o', $use_bin, @ldflags ]);
    return { ok => 0, stage => 'pgo_use_build', error => $b2->{stderr} } unless $b2->{ok};

    my $t_pgo = $self->_time_binary($use_bin, $bench_args, $runs);
    return { ok => 0, stage => 'pgo_use_run', error => $t_pgo->{error} } unless $t_pgo->{ok};

    # Verify functional output parity between baseline and PGO binary
    my $output_match = ($t_base->{stdout} eq $t_pgo->{stdout}) ? 1 : 0;

    push @stages, {
        stage        => 'pgo_use',
        ok           => 1,
        median_ms    => $t_pgo->{median_ms},
        binary       => $use_bin,
        output_match => $output_match,
    };

    my $base_ms = $t_base->{median_ms} || 0.001;
    my $pgo_ms  = $t_pgo->{median_ms}  || 0.001;
    my $ratio   = $base_ms / $pgo_ms;
    my $pct     = (($base_ms - $pgo_ms) / $base_ms) * 100.0;

    my $report = {
        ok              => 1,
        family          => $family,
        compiler        => $cc,
        arch            => $tools->{arch},
        power_cpu       => $power_cpu,
        baseline_ms     => sprintf('%.3f', $base_ms) + 0,
        pgo_ms          => sprintf('%.3f', $pgo_ms)  + 0,
        speedup_ratio   => sprintf('%.3f', $ratio)   + 0,
        speedup_pct     => sprintf('%.1f', $pct)     + 0,
        output_match    => $output_match,
        profdata_path   => $profdata_path,
        baseline_binary => $base_bin,
        pgo_binary      => $use_bin,
        promote_cflags  => $use_cflags,
        stages          => \@stages,
        promote_ready   => $output_match ? 1 : 0,
    };
    $self->{last_report} = $report;
    return $report;
}

sub promote {
    my ($self, %opts) = @_;
    my $rep = $self->{last_report};
    return { ok => 0, error => 'no completed PGO run to promote' }
        unless $rep && $rep->{ok} && $rep->{promote_ready};

    my $runner = $self->{runner};
    my $out_dir = $runner ? $runner->ensure_build_dir('pgo-promoted') : '.neoperl-build/pgo-promoted';
    my $flag_file = File::Spec->catfile($out_dir, 'pgo_flags.mk');

    my $flags_str = join(' ', @{ $rep->{promote_cflags} || [] });
    if (open my $fh, '>', $flag_file) {
        print {$fh} "# Generated by NeoPerl::Plugin::XSDev::PGO\n";
        print {$fh} "PGO_FAMILY := $rep->{family}\n";
        print {$fh} "PGO_FLAGS  := $flags_str\n";
        print {$fh} "PGO_DATA   := $rep->{profdata_path}\n";
        close $fh;
    }

    my $promoted_bin;
    if (defined $opts{dest_binary} && -f ($rep->{pgo_binary} || '')) {
        File::Copy::copy($rep->{pgo_binary}, $opts{dest_binary})
            or return { ok => 0, error => "copy failed: $!" };
        chmod 0755, $opts{dest_binary};
        $promoted_bin = $opts{dest_binary};
    }

    return {
        ok            => 1,
        flag_file     => $flag_file,
        pgo_flags     => $flags_str,
        profdata_path => $rep->{profdata_path},
        promoted_bin  => $promoted_bin,
        baseline_ms   => $rep->{baseline_ms},
        pgo_ms        => $rep->{pgo_ms},
        speedup_pct   => $rep->{speedup_pct},
    };
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::XSDev::PGO - Isolated two-stage Clang and GCC PGO pipeline

=head1 SYNOPSIS

    use NeoPerl::Plugin::XSDev::PGO;

    my $pgo = NeoPerl::Plugin::XSDev::PGO->new(runner => $runner);
    my $rep = $pgo->run_c_pgo($c_file, runs => 3);
    $pgo->promote;

=head1 DESCRIPTION

Automates isolated two-stage Profile-Guided Optimization inside
C<.neoperl-build/{pgo-base,pgo-gen,pgo-use}/> without disturbing main C<blib/>
builds. Supports Clang (C<-fprofile-instr-generate>, C<llvm-profdata merge>,
C<-fprofile-instr-use>) and GCC (C<-fprofile-generate>, C<-fprofile-use>, plus
C<-mcpu=power8|power9|power10|native> on C<ppc64le>), compares baseline and PGO
timings with functional output parity checks, and supports C<:XSPgoPromote>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
