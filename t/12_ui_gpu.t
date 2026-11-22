use strict;
use warnings;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempdir tempfile);
use Cwd qw(abs_path);
use Test::More;

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

if (!eval { require Tcl::Tk::MT; require Tcl::Tk::MT::Canvas; 1 }) {
    plan skip_all => 'Tcl::Tk::MT not available on this Perl build';
}

use_ok('NeoPerl::MT');
use_ok('NeoPerl::UI::GPU');

my $tmpdir = tempdir(CLEANUP => 1);

sub _check_png {
    my ($path, $exp_w, $exp_h, $label) = @_;
    ok(-f $path, "$label: PNG file exists");
    open my $fh, '<:raw', $path or die "open $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    cmp_ok(length($data), '>', 5000, "$label: PNG size > 5 KB (" . length($data) . ' bytes)');
    is(substr($data, 0, 8), "\x89PNG\r\n\x1a\n", "$label: valid PNG signature");
    is(substr($data, 12, 4), 'IHDR', "$label: IHDR chunk present");
    my ($w, $h, $depth, $ctype) = unpack('N N C C', substr($data, 16, 10));
    is($w, $exp_w, "$label: PNG width == $exp_w");
    is($h, $exp_h, "$label: PNG height == $exp_h");
    is($depth, 8, "$label: 8-bit channel depth");
    is($ctype, 6, "$label: RGBA color type");
    return $data;
}

# ---------------------------------------------------------------------------
# 1. Headless GPU Metal/Auto & Software Rendering + PNG Export across all views
# ---------------------------------------------------------------------------
{
    my $app = NeoPerl::MT->new(
        cwd         => $ROOT,
        ui          => 'gpu',
        backend     => 'auto',
        headless    => 1,
        width       => 1280,
        height      => 720,
        agy_mock    => 1,
        load_config => 0,
    );
    isa_ok($app->ui, 'NeoPerl::UI::GPU', 'GPU UI initialized');
    my $be = $app->ui->backend_name;
    ok(length($be) > 0, "active GPU backend reported ($be)");
    if ($^O eq 'darwin') {
        is($be, 'metal', 'macOS auto backend resolves to Metal');
    }

    # Minimalist pure-Neovim view (Command Center closed)
    $app->setup_demo(scene => 'chat_diff', tab => 'none', float => 'none');
    is($app->editor->layout->command_center_open, 0, 'Command Center closed for minimalist view');
    my $png_min = File::Spec->catfile($tmpdir, 'minimal.png');
    my $r_min   = $app->export_screenshot($png_min);
    ok($r_min->{ok}, 'minimalist pure-Neovim PNG exported');
    my $d_min = _check_png($png_min, 1280, 720, 'minimalist Neovim');

    # Scene 1: Multi-split + Inline Diff + CHAT tab + Permission Bar
    $app->editor->layout->open_command_center('chat');
    my $png_chat = File::Spec->catfile($tmpdir, 'chat_diff.png');
    $app->export_screenshot($png_chat);
    my $d_chat = _check_png($png_chat, 1280, 720, 'CHAT + inline diff');
    isnt($d_chat, $d_min, 'CHAT Command Center visually distinct from minimalist frame');

    # Scene 2: MEMORY tab + Ctrl-I inline float
    $app->setup_demo(scene => 'memory_bonsai', tab => 'memory', float => 'inline');
    my $png_mem = File::Spec->catfile($tmpdir, 'memory.png');
    $app->export_screenshot($png_mem);
    my $d_mem = _check_png($png_mem, 1280, 720, 'MEMORY + Ctrl-I float');
    isnt($d_mem, $d_chat, 'MEMORY tab visually distinct from CHAT tab');

    # Scene 3: MODELS tab + RAM meter + Bonsai jobs + Explorer toggled open
    $app->editor->layout->open_command_center('jobs');
    $app->editor->layout->explorer_open(1);
    my $png_mod = File::Spec->catfile($tmpdir, 'models.png');
    $app->export_screenshot($png_mod);
    my $d_mod = _check_png($png_mod, 1280, 720, 'MODELS + Explorer');
    isnt($d_mod, $d_mem, 'MODELS tab + Explorer visually distinct');

    # Scene 4: XSDEV tab + Cachegrind gutter heatbars + 2-pane Telescope float
    $app->editor->layout->explorer_open(0);
    $app->setup_demo(scene => 'xs_cachegrind', float => 'telescope');
    my $png_xs = File::Spec->catfile($tmpdir, 'xs_cachegrind.png');
    $app->export_screenshot($png_xs);
    my $d_xs = _check_png($png_xs, 1280, 720, 'XSDEV + Cachegrind + Telescope');
    isnt($d_xs, $d_mod, 'XSDEV + Telescope visually distinct');

    # Theme switching renders cleanly across all 5 themes
    for my $th (qw(catppuccin gruvbox kanagawa tokyonight aix_amber)) {
        ok($app->editor->set_colorscheme($th), "switched theme to $th");
        my $ms = $app->ui->render_frame();
        cmp_ok($ms, '>=', 0, "rendered frame cleanly in $th theme");
    }

    $app->shutdown();
}

# ---------------------------------------------------------------------------
# 2. Explicit Software GPU Fallback Parity
# ---------------------------------------------------------------------------
{
    my $app_sw = NeoPerl::MT->new(
        cwd         => $ROOT,
        ui          => 'gpu',
        backend     => 'software',
        headless    => 1,
        width       => 960,
        height      => 600,
        start_mcp   => 0,
        load_config => 0,
    );
    is($app_sw->ui->backend_name, 'software', 'explicit software backend active');
    $app_sw->setup_demo(scene => 'chat_diff');
    my $png_sw = File::Spec->catfile($tmpdir, 'software.png');
    $app_sw->export_screenshot($png_sw);
    _check_png($png_sw, 960, 600, 'Software fallback');
    $app_sw->shutdown();
}

# ---------------------------------------------------------------------------
# 3. Live Interactive GUI Smoke & Zero-Jitter Geometry Probe
# ---------------------------------------------------------------------------
sub _run_cmd {
    my (@cmd) = @_;
    my ($ofh, $ofile) = tempfile(UNLINK => 1);
    my ($efh, $efile) = tempfile(UNLINK => 1);
    close $ofh;
    close $efh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', $ofile or exit 126;
        open STDERR, '>', $efile or exit 126;
        exec @cmd;
        exit 127;
    }
    waitpid($pid, 0);
    my $st  = $?;
    my $out = do { local $/; open my $f, '<', $ofile; <$f> // '' };
    my $err = do { local $/; open my $f, '<', $efile; <$f> // '' };
    return ($st, $out, $err);
}

SKIP: {
    skip 'No interactive GUI display available', 9
        if $^O ne 'darwin' && $^O ne 'MSWin32' && !($ENV{DISPLAY} || $ENV{WAYLAND_DISPLAY});

    my @inc_args = map { ("-I$_") } grep { !ref($_) && -d $_ } @INC;
    my $bin_npl  = File::Spec->catfile($ROOT, 'bin', 'npl');

    # 3a. CLI live GUI smoke: bin/npl --demo --agy-mock --auto-exit-ms=900
    my ($st1, $out1, $err1) = _run_cmd(
        $^X, @inc_args, $bin_npl,
        '--gpu', '--demo', '--agy-mock', '--auto-exit-ms=900',
    );
    is($st1, 0, 'bin/npl --demo --agy-mock --auto-exit-ms=900 exited cleanly (status 0)');
    is($err1, '', 'bin/npl live GUI smoke emitted zero stderr')
        or diag("stderr:\n$err1");

    # 3b. Live GUI jitter_px == 0 probe across tab switching & scrolling
    my $probe = <<'END_JITTER';
use strict;
use warnings;
use NeoPerl::MT;

my ($root) = @ARGV;
my $app = NeoPerl::MT->new(
    cwd          => $root,
    ui           => 'gpu',
    backend      => 'auto',
    headless     => 0,
    width        => 1280,
    height       => 720,
    auto_exit_ms => 950,
    agy_mock     => 1,
    load_config  => 0,
);
$app->setup_demo(scene => 'chat_diff');

my @samples;
my $step = 0;
my $mw   = $app->ui->mw;
my $be   = $app->ui ? $app->ui->backend_name : 'none';
my @tabs = qw(chat memory jobs xsdev);

my $sampler;
$sampler = sub {
    return unless $mw && $app->ui && !$app->ui->{_destroyed};
    $be = $app->ui->backend_name if $app->ui->canvas;
    my $w = int($mw->winfo('width')  || 0);
    my $h = int($mw->winfo('height') || 0);
    push @samples, [$w, $h] if $w > 1 && $h > 1;

    $step++;
    $app->editor->layout->open_command_center($tabs[$step % @tabs]);
    $app->editor->notify("Dynamic status update #$step with varying text length " . ('x' x ($step * 3)), 'info');
    if (my $win = $app->editor->current_window) {
        $win->scroll_top($step);
    }
    $app->ui->render_frame();
    $mw->after(60, $sampler);
};

$mw->after(220, $sampler);
$app->run();
$app->shutdown();

my ($min_w, $max_w, $min_h, $max_h) = (999999, 0, 999999, 0);
for my $s (@samples) {
    $min_w = $s->[0] if $s->[0] < $min_w;
    $max_w = $s->[0] if $s->[0] > $max_w;
    $min_h = $s->[1] if $s->[1] < $min_h;
    $max_h = $s->[1] if $s->[1] > $max_h;
}
printf "SAMPLES=%d MIN_W=%d MAX_W=%d MIN_H=%d MAX_H=%d BACKEND=%s\n",
    scalar(@samples), $min_w, $max_w, $min_h, $max_h, $be;
END_JITTER

    my ($st2, $out2, $err2) = _run_cmd($^X, @inc_args, '-e', $probe, $ROOT);
    is($st2, 0, 'GUI jitter probe exited cleanly (status 0)');
    is($err2, '', 'GUI jitter probe emitted zero stderr')
        or diag("stderr:\n$err2");

    my %kv = ($out2 =~ /(\w+)=([^\s]+)/g);
    note("GUI jitter probe: $out2");
    cmp_ok($kv{SAMPLES} // 0, '>=', 5, 'collected >= 5 live window geometry samples');
    cmp_ok($kv{MIN_W}   // 0, '>=', 640, 'live window width >= 640 px');
    cmp_ok($kv{MIN_H}   // 0, '>=', 420, 'live window height >= 420 px');
    is(($kv{MAX_W} // 0) - ($kv{MIN_W} // 0), 0, 'horizontal window jitter_px == 0');
    is(($kv{MAX_H} // 0) - ($kv{MIN_H} // 0), 0, 'vertical window jitter_px == 0');
}

done_testing();
