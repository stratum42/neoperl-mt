use strict;
use warnings;
use utf8;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempfile);
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

use_ok('NeoPerl::MT');
use_ok('NeoPerl::UI::TUI');

# ---------------------------------------------------------------------------
# 1. ANSI Key Sequence, SGR Mouse, and Bracketed Paste Decoder
# ---------------------------------------------------------------------------
{
    my $evs = NeoPerl::UI::TUI->decode_input(
        "\e[A\e[B\e[C\e[D\e[H\e[F\e[5~\e[6~\e[3~\e[Z\eOP\e[15~\x09\x0d\x7f\x01\x1bx\e"
    );
    my @keys = map { $_->{key} } @$evs;
    is_deeply(
        \@keys,
        [ '<Up>', '<Down>', '<Right>', '<Left>', '<Home>', '<End>',
          '<PageUp>', '<PageDown>', '<Del>', '<S-Tab>', '<F1>', '<F5>',
          '<Tab>', '<CR>', '<BS>', '<C-a>', '<M-x>', '<Esc>' ],
        'decode_input decodes full ANSI arrow/nav/Fn/Ctrl/Alt/Esc sequences',
    );

    my $mouse = NeoPerl::UI::TUI->decode_input("\e[<0;15;8M\e[<0;15;8m\e[<64;10;5M\e[<65;10;5M");
    is(scalar(@$mouse), 4, 'decoded 4 SGR 1006 mouse events');
    is($mouse->[0]{type}, 'mouse', 'event 0 is mouse');
    is($mouse->[0]{kind}, 'press', 'SGR M decoded as press');
    is($mouse->[0]{col}, 14, 'SGR col converted to 0-based');
    is($mouse->[0]{row}, 7,  'SGR row converted to 0-based');
    is($mouse->[1]{kind}, 'release', 'SGR m decoded as release');
    is($mouse->[2]{kind}, 'wheel_up', 'SGR 64 decoded as wheel_up');
    is($mouse->[3]{kind}, 'wheel_down', 'SGR 65 decoded as wheel_down');

    my $paste = NeoPerl::UI::TUI->decode_input("\e[200~hello\nworld\e[201~");
    is(scalar(@$paste), 1, 'bracketed paste decoded as single event');
    is($paste->[0]{type}, 'paste', 'bracketed paste type');
    is($paste->[0]{text}, "hello\nworld", 'bracketed paste preserves payload verbatim');
}

# ---------------------------------------------------------------------------
# 2. Headless Virtual-Terminal Render: 24-bit ANSI, Diff Buffering, Splits,
#    Inline Diffs, Cachegrind Heatbars, :XSAsm Split, Floats, & All 4 CC Tabs
# ---------------------------------------------------------------------------
{
    my $app = NeoPerl::MT->new(
        cwd         => $ROOT,
        ui          => 'tui',
        headless    => 1,
        cols        => 132,
        rows        => 40,
        agy_mock    => 1,
        load_config => 0,
    );
    isa_ok($app->ui, 'NeoPerl::UI::TUI', 'TUI frontend initialized');
    is($app->ui->backend_name, 'tui-24bit', 'TUI reports 24-bit backend');

    # Scene 1: Multi-split + Inline Red/Green Diff + CHAT Tab + Permission Bar
    $app->setup_demo(scene => 'chat_diff');
    my $ansi1 = $app->ui->render_frame();
    like($ansi1, qr/\e\[38;2;\d+;\d+;\d+m/, 'emits 24-bit truecolor foreground ANSI codes');
    like($ansi1, qr/\e\[48;2;\d+;\d+;\d+m/, 'emits 24-bit truecolor background ANSI codes');

    my $txt1 = $app->ui->screen_text();
    like($txt1, qr/NORMAL/, 'statusline displays NORMAL mode badge');
    like($txt1, qr/Scheduler\.pm/, 'left split displays Scheduler.pm');
    like($txt1, qr/vec_simd\.c/, 'right split displays vec_simd.c');
    like($txt1, qr/return undef unless/, 'virtual deleted red diff line rendered in TUI');
    like($txt1, qr/CHAT.*MEMORY.*MODELS.*XSDEV/, '4-tab Command Center header rendered');
    like($txt1, qr/\[a\] Allow.*\[A\] Always.*\[r\] Reject/, 'CHAT permission bar rendered');
    like($txt1, qr/│/, 'Unicode vertical split/panel borders rendered');

    # Diff-buffering verification: identical second frame emits dramatically fewer bytes
    my $ansi2 = $app->ui->render_frame();
    cmp_ok(length($ansi2), '<', length($ansi1) / 5,
        sprintf('diff-buffered second frame tiny (%d vs %d bytes)', length($ansi2), length($ansi1)));

    # Scene 2: MEMORY tab + Ctrl-I Inline Float
    $app->setup_demo(scene => 'memory_bonsai', tab => 'memory', float => 'inline');
    $app->ui->render_frame();
    my $txt_mem = $app->ui->screen_text();
    like($txt_mem, qr/Antigravity Inline/, 'Ctrl-I inline float rendered with border');
    like($txt_mem, qr/╭.*╮/, 'Unicode rounded box-drawing corners rendered on float');
    like($txt_mem, qr/Db2|SQLite/, 'MEMORY tab shows Db2/SIMD store label');
    like($txt_mem, qr/\[repo\/architecture\]|\[global\/convention\]/, 'MEMORY tab shows scope/category badges');

    # Scene 3: MODELS tab + Explorer
    $app->editor->layout->close_floats_by_kind('inline_prompt');
    $app->editor->layout->open_command_center('jobs');
    $app->editor->layout->explorer_open(1);
    $app->ui->render_frame();
    my $txt_mod = $app->ui->screen_text();
    like($txt_mod, qr/EXPLORER/, 'left File Explorer rendered');
    like($txt_mod, qr/RAM\s+.*GB/, 'MODELS tab renders RAM residency meter');
    like($txt_mod, qr/Cloud Tokens Saved:/, 'MODELS tab renders Cloud Tokens Saved counter');
    like($txt_mod, qr/Bonsai Offload Jobs/, 'MODELS tab renders Bonsai Offload Queue');

    # Scene 4: XSDEV tab + Cachegrind Heatbars (then floating 2-pane Telescope)
    $app->editor->layout->explorer_open(0);
    $app->setup_demo(scene => 'xs_cachegrind', float => 'none');
    $app->ui->render_frame();
    my $txt_xs = $app->ui->screen_text();
    like($txt_xs, qr/Backtrace:/, 'XSDEV tab renders Backtrace');
    like($txt_xs, qr/SV\* Inspector:/, 'XSDEV tab renders Perl SV* Inspector');
    like($txt_xs, qr/POWER Regs:/, 'XSDEV tab renders POWER registers');
    like($txt_xs, qr/Cachegrind Hotspots:/, 'XSDEV tab renders Cachegrind hotspots');
    like($txt_xs, qr/PGO:/, 'XSDEV tab renders PGO speedup summary');
    like($txt_xs, qr/[█▓▒░]/, 'Cachegrind gutter heatbars rendered in TUI');

    $app->telescope->files($ROOT);
    $app->telescope->set_query('simd');
    $app->ui->render_frame();
    my $txt_tel = $app->ui->screen_text();
    like($txt_tel, qr/Telescope: Find Files/, 'floating 2-pane Telescope rendered');
    like($txt_tel, qr/vec_simd\.c/, 'Telescope results show vec_simd.c');

    # Scene 5: :XSAsm side-by-side disassembly split
    $app->telescope->close() if $app->telescope;
    $app->editor->layout->close_command_center();
    my $asm_buf = $app->editor->create_buffer(
        name     => '[XSAsm]',
        buftype  => 'nofile',
        filetype => 'asm',
        text     => "0000000000000040 <dot_f32_vsx>:\n  40:  lxvd2x  vs32,0,r3\n  44:  xvmaddasp vs34,vs32,vs33\n  48:  lwsync\n",
    );
    $app->editor->layout->vsplit($asm_buf->id);
    $app->ui->render_frame();
    my $txt_asm = $app->ui->screen_text();
    like($txt_asm, qr/\[XSAsm\]/, ':XSAsm split winbar rendered');
    like($txt_asm, qr/xvmaddasp/, ':XSAsm VSX instruction rendered in TUI split');

    # Resize check
    ok($app->ui->resize(100, 30), 'TUI resize(100, 30) succeeded');
    is($app->ui->width,  100, 'TUI width updated');
    is($app->ui->height, 30,  'TUI height updated');
    $app->ui->render_frame();
    is(scalar(@{ $app->ui->screen_lines }), 30, 'resized virtual screen has 30 rows');

    $app->shutdown();
}

# ---------------------------------------------------------------------------
# 3. CLI Smoke Test: bin/npl --tui --headless --demo --agy-mock
# ---------------------------------------------------------------------------
{
    my @inc_args = map { ("-I$_") } grep { !ref($_) && -d $_ } @INC;
    my $bin_npl  = File::Spec->catfile($ROOT, 'bin', 'npl');
    my ($efh, $efile) = tempfile(UNLINK => 1);
    close $efh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', File::Spec->devnull() or exit 126;
        open STDERR, '>', $efile or exit 126;
        exec $^X, @inc_args, $bin_npl, '--tui', '--headless', '--demo', '--agy-mock';
        exit 127;
    }
    waitpid($pid, 0);
    my $st  = $?;
    my $err = do { local $/; open my $f, '<', $efile; <$f> // '' };
    is($st, 0, 'bin/npl --tui --headless --demo --agy-mock exited cleanly');
    is($err, '', 'bin/npl --tui emitted zero stderr') or diag("stderr:\n$err");
}

done_testing();
