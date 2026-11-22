#!/usr/bin/env perl
use strict;
use warnings;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempdir tempfile);
use Cwd qw(abs_path);
use Time::HiRes qw(time);
use Getopt::Long qw(:config no_ignore_case bundling);

my $ROOT;

BEGIN {
    $ROOT = abs_path(File::Spec->catdir($FindBin::RealBin, File::Spec->updir));
    for my $rel (
        File::Spec->catdir('blib', 'arch'),
        File::Spec->catdir('blib', 'lib'),
        'lib',
    ) {
        my $dir = File::Spec->catdir($ROOT, $rel);
        unshift @INC, $dir if -d $dir;
    }

    my $parent = File::Spec->catdir($ROOT, File::Spec->updir);
    my %have = map { $_ => 1 } grep { !ref($_) } @INC;
    my $prepend = sub {
        my ($d) = @_;
        return unless defined $d && -d $d;
        my $abs = eval { abs_path($d) } || $d;
        return if $have{$abs};
        unshift @INC, $abs;
        $have{$abs} = 1;
    };

    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    $prepend->(File::Spec->catdir($home, 'perl5', 'lib', 'perl5')) if length $home;

    for my $spec (
        [ $ENV{NEOPERL_DBD_SQLITE_DIR}, 'dbd-sqlite-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBD_ODBC_DIR},   'dbd-odbc-mt',   [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBI_DIR},        'dbi-mt',        [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_MOJO_DIR},       'mojolicious-mt',[ 'xs/blib/arch', 'xs/blib/lib', 'lib' ] ],
        [ $ENV{TCL_TK_MT_DIR} || $ENV{NEOPERL_TK_DIR}, 'tcl-tk-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
    ) {
        my ($env_dir, $repo, $subs) = @$spec;
        my $base = (defined $env_dir && length $env_dir && -d $env_dir)
            ? $env_dir
            : File::Spec->catdir($parent, $repo);
        next unless -d $base;
        for my $rel (reverse @$subs) {
            $prepend->(File::Spec->catdir($base, split('/', $rel)));
        }
    }
}

use NeoPerl::Core ();
use NeoPerl::MT;
use NeoPerl::UI::TUI;

my $num_lines     = 500_000;
my $scroll_frames = 120;
my $edit_steps    = 60;
my $vec_count     = 4000;
my $vec_dim       = 768;
my $json_out      = 0;
my $quick         = 0;

GetOptions(
    'lines=i'  => \$num_lines,
    'frames=i' => \$scroll_frames,
    'edits=i'  => \$edit_steps,
    'vecs=i'   => \$vec_count,
    'json!'    => \$json_out,
    'quick!'   => \$quick,
) or die "Usage: $0 [--lines=500000] [--frames=120] [--vecs=4000] [--quick] [--json]\n";

if ($quick) {
    $num_lines     = 50_000 if $num_lines == 500_000;
    $scroll_frames = 30     if $scroll_frames == 120;
    $edit_steps    = 20     if $edit_steps == 60;
    $vec_count     = 1000   if $vec_count == 4000;
}

sub _percentile {
    my ($sorted, $p) = @_;
    return 0.0 unless @$sorted;
    my $idx = int(($p / 100.0) * (@$sorted - 1) + 0.5);
    $idx = 0 if $idx < 0;
    $idx = $#$sorted if $idx > $#$sorted;
    return $sorted->[$idx];
}

sub _run_perl_child {
    my ($env_ref, @args) = @_;
    my ($fh, $out_file) = tempfile(UNLINK => 1);
    close $fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        if ($env_ref) {
            for my $k (keys %$env_ref) {
                if (defined $env_ref->{$k}) {
                    $ENV{$k} = $env_ref->{$k};
                }
                else {
                    delete $ENV{$k};
                }
            }
        }
        open STDOUT, '>', $out_file or exit 126;
        open STDERR, '>', File::Spec->devnull() or exit 126;
        exec($^X, @args);
        exit 127;
    }
    waitpid($pid, 0);
    my $st  = $?;
    my $out = do { local $/; open my $f, '<', $out_file; <$f> // '' };
    return ($st, $out);
}

sub _generate_perl_file {
    my ($path, $lines) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    my @block = (
        "package Bench::Sample;\n",
        "sub compute_batch {\n",
        "    my (\$self, \$acc) = \@_;\n",
    );
    for my $i (3 .. 98) {
        if ($i % 10 == 0) {
            push @block, "    # comment line $i for incremental syntax lexing benchmark 12345\n";
        }
        else {
            push @block, "    my \$v_$i = 'val_$i'; \$acc += $i * length(\$v_$i);\n";
        }
    }
    push @block, "    return \$acc;\n";
    my $chunk = join('', @block); # 100 lines
    my $reps  = int($lines / 100);
    $reps = 1 if $reps < 1;
    print {$fh} $chunk for 1 .. $reps;
    close $fh or die "close $path: $!";
    return (-s $path) || 0;
}

my $arch    = NeoPerl::Core::arch_info();
my $tmpdir  = tempdir(CLEANUP => 1);
my $bigfile = File::Spec->catfile($tmpdir, "bench_${num_lines}.pl");
my $bytes   = _generate_perl_file($bigfile, $num_lines);
my $mb      = $bytes / (1024.0 * 1024.0);
my @inc_args = map { ("-I$_") } grep { !ref($_) && -d $_ } @INC;

my %R = (
    perl_version => sprintf('%vd', $^V),
    is_perl5_mt  => NeoPerl::Core::is_perl5_mt() ? 1 : 0,
    arch         => $arch->{arch},
    page_size    => $arch->{page_size},
    simd_level   => $arch->{simd_level},
    file_lines   => $num_lines,
    file_mb      => sprintf('%.2f', $mb) + 0,
);

# ---------------------------------------------------------------------------
# 1. Cold Startup (ms) & RSS (MB)
# ---------------------------------------------------------------------------
{
    my $probe = <<'END_PROBE';
use strict;
use warnings;
use NeoPerl::MT;
my ($cwd) = @ARGV;
my $app = NeoPerl::MT->new(cwd => $cwd, ui => 'tui', headless => 1, start_mcp => 0, load_config => 0);
my $rss_kb = `ps -o rss= -p $$`;
$rss_kb =~ s/\s+//g if defined $rss_kb;
$app->shutdown();
print "RSS_KB=", ($rss_kb || 0), "\n";
END_PROBE

    my @ms;
    my $rss_mb = 0.0;
    for (1 .. 3) {
        my $t0 = time();
        my ($st, $out) = _run_perl_child(undef, @inc_args, '-e', $probe, $ROOT);
        my $dt = (time() - $t0) * 1000.0;
        die "Startup probe failed (status=$st)" if $st != 0;
        push @ms, $dt;
        $rss_mb = $1 / 1024.0 if $out =~ /RSS_KB=(\d+)/;
    }
    @ms = sort { $a <=> $b } @ms;
    $R{startup_ms} = sprintf('%.2f', _percentile(\@ms, 50)) + 0;
    $R{rss_mb}     = sprintf('%.2f', $rss_mb) + 0;
}

# ---------------------------------------------------------------------------
# 2. 500k-Line Open (mmap piece-table + line index)
# ---------------------------------------------------------------------------
my $ed = NeoPerl::Editor->new(cwd => $ROOT, width => 120, height => 40);
{
    my $t0  = time();
    my $buf = $ed->open_file($bigfile);
    my $dt  = (time() - $t0) * 1000.0;
    $R{open_500k_ms}    = sprintf('%.2f', $dt) + 0;
    $R{opened_lines}    = $buf->line_count;
}

# ---------------------------------------------------------------------------
# 3. 500k-Line GPU Scroll FPS (Metal / Auto & Software)
# ---------------------------------------------------------------------------
if (eval { require Tcl::Tk::MT; require Tcl::Tk::MT::Canvas; require NeoPerl::UI::GPU; 1 }) {
    for my $be (qw(auto software)) {
        my $ui = eval {
            NeoPerl::UI::GPU->new(
                editor   => $ed,
                width    => 1280,
                height   => 720,
                backend  => $be,
                headless => 1,
            );
        };
        next unless $ui;
        my $win = $ed->current_window;
        my $step = int($num_lines / ($scroll_frames + 2));
        $step = 1 if $step < 1;

        # Warmup
        $ui->render_frame() for 1 .. 5;

        my @ft;
        my $t_all = time();
        for my $i (0 .. $scroll_frames - 1) {
            my $ln = $i * $step;
            $win->scroll_top($ln);
            $win->set_cursor($ln, 4);
            my $t0 = time();
            $ui->render_frame();
            push @ft, (time() - $t0) * 1000.0;
        }
        my $tot = time() - $t_all;
        @ft = sort { $a <=> $b } @ft;
        my $bname = $ui->backend_name;
        my $key   = ($be eq 'auto') ? 'gpu_auto' : 'gpu_software';
        $R{$key} = {
            backend => $bname,
            fps     => sprintf('%.1f', $scroll_frames / ($tot || 1e-6)) + 0,
            p50_ms  => sprintf('%.3f', _percentile(\@ft, 50)) + 0,
            p95_ms  => sprintf('%.3f', _percentile(\@ft, 95)) + 0,
        };
        $ui->shutdown();
    }
}

# ---------------------------------------------------------------------------
# 4. 500k-Line TUI (24-bit ANSI) Scroll FPS
# ---------------------------------------------------------------------------
{
    my $tui = NeoPerl::UI::TUI->new(
        editor   => $ed,
        width    => 120,
        height   => 40,
        headless => 1,
    );
    my $win = $ed->current_window;
    my $step = int($num_lines / ($scroll_frames + 2));
    $step = 1 if $step < 1;
    $tui->render_frame() for 1 .. 3;

    my @ft;
    my $t_all = time();
    for my $i (0 .. $scroll_frames - 1) {
        my $ln = $i * $step;
        $win->scroll_top($ln);
        $win->set_cursor($ln, 4);
        my $t0 = time();
        $tui->render_frame();
        push @ft, (time() - $t0) * 1000.0;
    }
    my $tot = time() - $t_all;
    @ft = sort { $a <=> $b } @ft;
    $R{tui_scroll} = {
        fps    => sprintf('%.1f', $scroll_frames / ($tot || 1e-6)) + 0,
        p50_ms => sprintf('%.3f', _percentile(\@ft, 50)) + 0,
        p95_ms => sprintf('%.3f', _percentile(\@ft, 95)) + 0,
    };
}

# ---------------------------------------------------------------------------
# 5. Incremental Edit + Incremental C11 Re-Lex at Mid-File
# ---------------------------------------------------------------------------
{
    my $buf = $ed->current_buffer;
    my $mid = int($buf->line_count / 2);
    $buf->highlight_range($mid, 40);
    my @et;
    for my $i (1 .. $edit_steps) {
        my $t0 = time();
        $buf->insert_at($mid, 4, "my \$k$i = $i; ");
        $buf->highlight_range($mid, 40);
        push @et, (time() - $t0) * 1000.0;
    }
    @et = sort { $a <=> $b } @et;
    $R{edit_relex} = {
        p50_ms => sprintf('%.3f', _percentile(\@et, 50)) + 0,
        p95_ms => sprintf('%.3f', _percentile(\@et, 95)) + 0,
    };
}

# ---------------------------------------------------------------------------
# 6. Parallel C11 Telescope Fuzzy/Grep & vec_simd (MT/SIMD vs PERL_FORCE_SCALAR=1)
# ---------------------------------------------------------------------------
{
    my $probe = <<'END_CORE_BENCH';
use strict;
use warnings;
use Time::HiRes qw(time);
use NeoPerl::Core ();

my ($root, $nvecs, $dim) = @ARGV;

my $t0 = time();
my $files = NeoPerl::Core::Fuzzy::walk_files($root, 5000);
my $filtered = NeoPerl::Core::Fuzzy::filter('simd', $files, 50);
my $fuzzy_ms = (time() - $t0) * 1000.0;

my $tg = time();
my $hits = NeoPerl::Core::Fuzzy::grep_dir($root, 'NeoPerl', 0, 2000);
my $grep_ms = (time() - $tg) * 1000.0;

my @q = map { sin($_ * 0.13) } (0 .. $dim - 1);
my $qblob = NeoPerl::Core::VecSIMD::pack_f32(\@q);
my @cands;
for my $i (0 .. $nvecs - 1) {
    my @v = map { sin(($_ + $i) * 0.07) } (0 .. $dim - 1);
    push @cands, [ $i, NeoPerl::Core::VecSIMD::pack_f32(\@v) ];
}
my $tv = time();
my $top = NeoPerl::Core::VecSIMD::topk_cosine($qblob, \@cands, 10);
my $vec_ms = (time() - $tv) * 1000.0;

printf "FUZZY=%.3f GREP=%.3f VEC=%.3f FILES=%d HITS=%d TOP0=%.6f SIMD=%s\n",
    $fuzzy_ms, $grep_ms, $vec_ms, scalar(@$files), scalar(@$hits),
    ($top && @$top ? $top->[0]{score} : 0), NeoPerl::Core::VecSIMD::simd_backend();
END_CORE_BENCH

    my ($st_mt, $out_mt) = _run_perl_child({ PERL_FORCE_SCALAR => undef }, @inc_args, '-e', $probe, $ROOT, $vec_count, $vec_dim);
    my ($st_sc, $out_sc) = _run_perl_child({ PERL_FORCE_SCALAR => '1'   }, @inc_args, '-e', $probe, $ROOT, $vec_count, $vec_dim);
    my %kv_mt = ($out_mt =~ /(\w+)=([^\s]+)/g);
    my %kv_sc = ($out_sc =~ /(\w+)=([^\s]+)/g);

    $R{fuzzy_grep_vec} = {
        mt_fuzzy_ms     => ($kv_mt{FUZZY} // 0) + 0,
        scalar_fuzzy_ms => ($kv_sc{FUZZY} // 0) + 0,
        mt_grep_ms      => ($kv_mt{GREP}  // 0) + 0,
        scalar_grep_ms  => ($kv_sc{GREP}  // 0) + 0,
        simd_vec_ms     => ($kv_mt{VEC}   // 0) + 0,
        scalar_vec_ms   => ($kv_sc{VEC}   // 0) + 0,
        simd_backend    => $kv_mt{SIMD} // 'scalar',
        vec_count       => $vec_count,
        vec_dim         => $vec_dim,
        parity_match    => (($kv_mt{TOP0} // '') eq ($kv_sc{TOP0} // '')) ? 1 : 0,
    };
}

# ---------------------------------------------------------------------------
# 7. Warm-Worker PPI / Perl::Critic / Perl::Tidy Latency
# ---------------------------------------------------------------------------
{
    require NeoPerl::Plugin::PerlDev;
    my $pd = NeoPerl::Plugin::PerlDev->new();
    my $sample = <<'END_SAMPLE';
package Bench::Lint;
use strict;
use warnings;
sub calc {
    my ($x, $y) = @_;
    return $x + $y;
}
sub helper {
    my ($v) = @_;
    return undef unless defined $v;
    return $v * 2;
}
1;
END_SAMPLE
    my $buf = $ed->create_buffer(name => 'Lint.pm', filetype => 'perl', text => $sample);

    # Warm worker once
    $pd->outline_buffer($buf);
    $pd->critic_buffer($buf);
    $pd->post_tidy_text($sample);

    my (@ot, @ct, @tt);
    for (1 .. 10) {
        my $t0 = time();
        $pd->outline_buffer($buf);
        push @ot, (time() - $t0) * 1000.0;

        my $t1 = time();
        $pd->critic_buffer($buf);
        push @ct, (time() - $t1) * 1000.0;

        my $t2 = time();
        $pd->post_tidy_text($sample);
        push @tt, (time() - $t2) * 1000.0;
    }
    @ot = sort { $a <=> $b } @ot;
    @ct = sort { $a <=> $b } @ct;
    @tt = sort { $a <=> $b } @tt;
    my $caps = $pd->capabilities();
    $R{perldev} = {
        live_ppi        => $caps->{ppi}    ? 1 : 0,
        live_critic     => $caps->{critic} ? 1 : 0,
        live_tidy       => $caps->{tidy}   ? 1 : 0,
        outline_p50_ms  => sprintf('%.3f', _percentile(\@ot, 50)) + 0,
        critic_p50_ms   => sprintf('%.3f', _percentile(\@ct, 50)) + 0,
        tidy_p50_ms     => sprintf('%.3f', _percentile(\@tt, 50)) + 0,
    };
    $pd->worker->shutdown() if $pd->worker && $pd->worker->can('shutdown');
}

# ---------------------------------------------------------------------------
# 8. Antigravity ACP Loopback + EditorMCP Round-Trip Latency
# ---------------------------------------------------------------------------
{
    my $app = NeoPerl::MT->new(
        cwd         => $ROOT,
        ui          => 'none',
        headless    => 1,
        agy_mock    => 1,
        start_mcp   => 1,
        load_config => 0,
    );
    my $mcp_info = $app->editor_mcp ? $app->editor_mcp->info() : {};

    my @mcp_rt;
    if ($app->editor_mcp) {
        for (1 .. 20) {
            my $t0 = time();
            $app->editor_mcp->call_tool_local('neoperl_get_editor_state', {});
            push @mcp_rt, (time() - $t0) * 1000.0;
        }
    }
    @mcp_rt = sort { $a <=> $b } @mcp_rt;

    my $acp_ms = 0.0;
    if ($app->acp && $app->acp->is_running) {
        $app->acp->new_session();
        my $t0 = time();
        $app->acp->prompt('Benchmark ACP round-trip ping');
        $acp_ms = (time() - $t0) * 1000.0;
    }

    $R{acp_mcp} = {
        mcp_engine      => $mcp_info->{engine}     // 'none',
        mcp_tools       => $mcp_info->{tool_count} // 0,
        mojo_accel      => $mcp_info->{mojo_accel} ? 1 : 0,
        mcp_call_p50_ms => sprintf('%.3f', _percentile(\@mcp_rt, 50)) + 0,
        acp_turn_ms     => sprintf('%.2f', $acp_ms) + 0,
    };
    $app->shutdown();
}

# ---------------------------------------------------------------------------
# Output Results
# ---------------------------------------------------------------------------
if ($json_out) {
    require JSON::PP;
    print JSON::PP->new->canonical->pretty->encode(\%R);
    exit 0;
}

printf "NeoPerl::MT Benchmark Suite (Perl %s, perl5-mt=%d, arch=%s, page=%dB, simd=%s)\n",
    $R{perl_version}, $R{is_perl5_mt}, $R{arch}, $R{page_size}, $R{simd_level};
printf "%s\n", ('-' x 78);
printf "%-44s : %.2f ms (RSS %.2f MB)\n", 'Cold startup (headless)', $R{startup_ms}, $R{rss_mb};
printf "%-44s : %.2f ms (%d lines, %.2f MB)\n", 'File open (mmap piece-table)', $R{open_500k_ms}, $R{opened_lines}, $R{file_mb};
if ($R{gpu_auto}) {
    printf "%-44s : %.1f FPS (p50 %.3f ms, p95 %.3f ms) [%s]\n",
        'GPU scroll (1280x720, auto)', $R{gpu_auto}{fps}, $R{gpu_auto}{p50_ms}, $R{gpu_auto}{p95_ms}, $R{gpu_auto}{backend};
}
if ($R{gpu_software}) {
    printf "%-44s : %.1f FPS (p50 %.3f ms, p95 %.3f ms) [%s]\n",
        'GPU scroll (1280x720, software)', $R{gpu_software}{fps}, $R{gpu_software}{p50_ms}, $R{gpu_software}{p95_ms}, $R{gpu_software}{backend};
}
printf "%-44s : %.1f FPS (p50 %.3f ms, p95 %.3f ms)\n",
    'TUI scroll (120x40, 24-bit ANSI)', $R{tui_scroll}{fps}, $R{tui_scroll}{p50_ms}, $R{tui_scroll}{p95_ms};
printf "%-44s : p50 %.3f ms, p95 %.3f ms\n",
    'Incremental edit + C11 re-lex (mid-file)', $R{edit_relex}{p50_ms}, $R{edit_relex}{p95_ms};
printf "%-44s : MT %.2f ms vs scalar %.2f ms\n",
    'Telescope C11 walk + fuzzy filter', $R{fuzzy_grep_vec}{mt_fuzzy_ms}, $R{fuzzy_grep_vec}{scalar_fuzzy_ms};
printf "%-44s : MT %.2f ms vs scalar %.2f ms\n",
    'Telescope C11 parallel grep', $R{fuzzy_grep_vec}{mt_grep_ms}, $R{fuzzy_grep_vec}{scalar_grep_ms};
printf "%-44s : %s %.2f ms vs scalar %.2f ms (parity=%d)\n",
    sprintf('VecSIMD topk_cosine (%dx%dd)', $vec_count, $vec_dim),
    $R{fuzzy_grep_vec}{simd_backend}, $R{fuzzy_grep_vec}{simd_vec_ms}, $R{fuzzy_grep_vec}{scalar_vec_ms}, $R{fuzzy_grep_vec}{parity_match};
printf "%-44s : outline %.3f ms | critic %.3f ms | tidy %.3f ms\n",
    sprintf('PerlDev warm worker (PPI=%d C=%d T=%d)', $R{perldev}{live_ppi}, $R{perldev}{live_critic}, $R{perldev}{live_tidy}),
    $R{perldev}{outline_p50_ms}, $R{perldev}{critic_p50_ms}, $R{perldev}{tidy_p50_ms};
printf "%-44s : MCP %.3f ms (%d tools, %s) | ACP %.2f ms\n",
    'Antigravity ACP + EditorMCP round-trip',
    $R{acp_mcp}{mcp_call_p50_ms}, $R{acp_mcp}{mcp_tools}, $R{acp_mcp}{mcp_engine}, $R{acp_mcp}{acp_turn_ms};
exit 0;
