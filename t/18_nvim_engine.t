use strict;
use warnings;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempdir);
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

use_ok('NeoPerl::Core');
use_ok('NeoPerl::NvimBridge');
use_ok('NeoPerl::Editor');
use_ok('NeoPerl::Antigravity::EditorMCP');
use_ok('NeoPerl::UI::TUI');
use_ok('NeoPerl::MT');

# ---------------------------------------------------------------------------
# 1. C11 NeoPerl::Core::Msgpack Codec: All Types, Neovim ext & Partial Stream
# ---------------------------------------------------------------------------
subtest 'NeoPerl::Core::Msgpack types, Neovim ext & incremental stream chunking' => sub {
    # nil
    my $nil_bin = NeoPerl::Core::Msgpack::encode(undef);
    is($nil_bin, "\xc0", 'undef encodes to msgpack nil (0xc0)');
    is(NeoPerl::Core::Msgpack::decode($nil_bin), undef, 'nil decodes to undef');

    # booleans (multiple supported representations)
    my $t_bin = NeoPerl::Core::Msgpack::encode({ _msgpack_bool => 1 });
    my $f_bin = NeoPerl::Core::Msgpack::encode({ _msgpack_bool => 0 });
    is($t_bin, "\xc3", '{ _msgpack_bool => 1 } encodes to 0xc3 (true)');
    is($f_bin, "\xc2", '{ _msgpack_bool => 0 } encodes to 0xc2 (false)');
    is(NeoPerl::Core::Msgpack::decode($t_bin), 1, 'true decodes to 1');
    is(NeoPerl::Core::Msgpack::decode($f_bin), 0, 'false decodes to 0');

    if (defined(&NeoPerl::Core::Msgpack::true)) {
        is(NeoPerl::Core::Msgpack::encode(NeoPerl::Core::Msgpack::true()),  "\xc3", 'Msgpack::true() encodes to 0xc3');
        is(NeoPerl::Core::Msgpack::encode(NeoPerl::Core::Msgpack::false()), "\xc2", 'Msgpack::false() encodes to 0xc2');
    }

    # integers across fixint, int8/16/32/64, uint8/16/32/64
    for my $iv (0, 1, 127, -1, -32, -33, -128, -32768, -2147483648, 128, 255, 256, 65535, 65536, 1_000_000_000) {
        my $b = NeoPerl::Core::Msgpack::encode($iv);
        is(NeoPerl::Core::Msgpack::decode($b), $iv, "integer $iv round-trips cleanly");
    }

    # float64
    my $fval = 3.14159265358979;
    my $fdec = NeoPerl::Core::Msgpack::decode(NeoPerl::Core::Msgpack::encode($fval));
    ok(abs($fdec - $fval) < 1e-12, "float64 $fval round-trips cleanly");

    # strings (fixstr, str8, str16) and binary
    for my $s ('', 'nvim', 'x' x 40, 'A' x 300) {
        is(NeoPerl::Core::Msgpack::decode(NeoPerl::Core::Msgpack::encode($s)), $s,
            'string length ' . length($s) . ' round-trips');
    }
    my $raw_bin = "\x00\x01\xfe\xff\x80\x7f";
    is(NeoPerl::Core::Msgpack::decode(NeoPerl::Core::Msgpack::encode({ _msgpack_bin => $raw_bin })),
        $raw_bin, 'bin payload round-trips verbatim');

    # nested arrays & maps (Msgpack-RPC request envelope)
    my $rpc_req = [ 0, 42, 'nvim_ui_attach', [ 100, 36, { ext_linegrid => { _msgpack_bool => 1 }, rgb => { _msgpack_bool => 1 } } ] ];
    my $rpc_dec = NeoPerl::Core::Msgpack::decode(NeoPerl::Core::Msgpack::encode($rpc_req));
    is_deeply($rpc_dec, [ 0, 42, 'nvim_ui_attach', [ 100, 36, { ext_linegrid => 1, rgb => 1 } ] ],
        'nested Msgpack-RPC request envelope round-trips');

    # Neovim ext types (0=Buffer, 1=Window, 2=Tabpage)
    for my $pair ([0, 1], [1, 1000], [2, 3]) {
        my ($etype, $eid) = @$pair;
        my $enc = NeoPerl::Core::Msgpack::encode({ _nvim_ext => $etype, id => $eid });
        my $dec = NeoPerl::Core::Msgpack::decode($enc);
        is(ref($dec), 'HASH', "Neovim ext type $etype decodes to HASH");
        is($dec->{_nvim_ext}, $etype, "Neovim ext type $etype preserved");
        is($dec->{id}, $eid, "Neovim ext id $eid preserved");
    }

    # Incremental partial-stream chunking (byte-by-byte delivery across 3 concatenated frames)
    my @orig = (
        [ 1, 1, undef, 'ok' ],
        [ 2, 'redraw', [ [ 'grid_cursor_goto', [ 1, 5, 12 ] ], [ 'flush', [] ] ] ],
        { _nvim_ext => 0, id => 7 },
    );
    my $wire = join('', map { NeoPerl::Core::Msgpack::encode($_) } @orig);
    my $acc  = '';
    my @got;
    for my $i (0 .. length($wire) - 1) {
        $acc .= substr($wire, $i, 1);
        my ($items, $rem) = NeoPerl::Core::Msgpack::decode_stream(\$acc);
        push @got, @$items if ref($items) eq 'ARRAY';
        $acc = $rem if defined $rem;
    }
    is(length($acc), 0, 'byte-by-byte stream decode leaves 0 remaining bytes');
    is(scalar(@got), 3, 'decoded all 3 framed messages across 1-byte chunks');
    is_deeply($got[0], $orig[0], 'chunked frame 0 intact');
    is_deeply($got[1], $orig[1], 'chunked frame 1 intact');
    is($got[2]{_nvim_ext}, 0, 'chunked frame 2 ext type intact');
    is($got[2]{id},        7, 'chunked frame 2 ext id intact');

    # Invalid/truncated frame croaks cleanly on single-shot decode()
    eval { NeoPerl::Core::Msgpack::decode(substr($wire, 0, 2)) };
    ok($@, 'single-shot decode() croaks cleanly on truncated frame');
};

# ---------------------------------------------------------------------------
# 2. Direct ext_linegrid Redraw Parser Verification (repeat, carry-forward, scroll)
# ---------------------------------------------------------------------------
subtest 'ext_linegrid redraw parser (default_colors, hl_attr, repeat, hl carry, scroll)' => sub {
    my $nb = NeoPerl::NvimBridge->new(cols => 10, rows => 4, mock => 1);
    $nb->_handle_redraw([
        [ 'default_colors_set', [ 0xffb000, 0x000000, 0xff8800, -1, -1 ] ],
        [ 'hl_attr_define',
            [ 1, { foreground => 0xffd873, background => 0x1c1200, bold => 1 }, {}, [] ],
            [ 2, { foreground => 0x00ff00, reverse => 1 }, {}, [] ],
        ],
        [ 'grid_resize', [ 1, 10, 4 ] ],
        [ 'grid_clear',  [ 1 ] ],
        [ 'grid_line',
            # 'A' sets hl=1, 'B' carries hl=1 forward, '!' repeats 3 times with hl=2
            [ 1, 0, 0, [ ['A', 1], ['B'], ['!', 2, 3] ], 0 ],
            [ 1, 1, 0, [ ['1', 0], ['2'], ['3'] ], 0 ],
            [ 1, 2, 0, [ ['X', 0], ['Y'], ['Z'] ], 0 ],
            [ 1, 3, 0, [ ['.', 0, 4] ], 0 ],
        ],
        [ 'mode_info_set', [ 1, [
            { name => 'normal', cursor_shape => 'block' },
            { name => 'insert', cursor_shape => 'vertical' },
        ] ] ],
        [ 'mode_change',      [ 'insert', 1 ] ],
        [ 'grid_cursor_goto', [ 1, 2, 3 ] ],
        [ 'flush',            [] ],
    ]);

    is($nb->flush_count, 1, 'flush incremented');
    is($nb->display_mode, 'INSERT', 'mode_change parsed to INSERT');
    is($nb->cursor_shape, 'bar', 'mode_info_set vertical -> bar cursor shape');
    is_deeply([ $nb->cursor() ], [ 2, 3 ], 'grid_cursor_goto updated cursor');

    my $g = $nb->grid(1);
    is(substr($nb->grid_lines(1)->[0], 0, 5), 'AB!!!', 'grid_line text + repeat parsed');
    is($g->{rows}[0][0][1], 1, 'cell 0 hl_id == 1');
    is($g->{rows}[0][1][1], 1, 'cell 1 carried hl_id == 1 forward');
    is($g->{rows}[0][4][1], 2, 'repeated cell 4 hl_id == 2');

    my ($fg1, $bg1, $ha1) = $nb->resolve_hl(1);
    is($fg1, '#ffd873', 'hl 1 fg resolved');
    is($bg1, '#1c1200', 'hl 1 bg resolved');
    ok($ha1->{bold},    'hl 1 bold flag set');

    my ($fg2, $bg2) = $nb->resolve_hl(2);
    is($fg2, '#000000', 'hl 2 reverse swapped default bg into fg');
    is($bg2, '#00ff00', 'hl 2 reverse swapped fg into bg');

    # Scroll up by 1 row across rows [0..4), cols [0..10)
    $nb->_handle_redraw([ [ 'grid_scroll', [ 1, 0, 4, 0, 10, 1, 0 ] ] ]);
    is(substr($nb->grid_lines(1)->[0], 0, 3), '123',  'grid_scroll(+1) shifted row 1 to row 0');
    is(substr($nb->grid_lines(1)->[1], 0, 3), 'XYZ',  'grid_scroll(+1) shifted row 2 to row 1');
    is(substr($nb->grid_lines(1)->[2], 0, 4), '....', 'grid_scroll(+1) shifted row 3 to row 2');
    is($nb->grid_lines(1)->[3], '          ',         'grid_scroll(+1) cleared vacated bottom row');

    # Scroll down by 1 row
    $nb->_handle_redraw([ [ 'grid_scroll', [ 1, 0, 4, 0, 10, -1, 0 ] ] ]);
    is($nb->grid_lines(1)->[0], '          ',         'grid_scroll(-1) cleared vacated top row');
    is(substr($nb->grid_lines(1)->[1], 0, 3), '123',  'grid_scroll(-1) shifted row 0 down to row 1');
    is(substr($nb->grid_lines(1)->[2], 0, 3), 'XYZ',  'grid_scroll(-1) shifted row 1 down to row 2');
};

# ---------------------------------------------------------------------------
# 3. Shared Behavioral Suite for BOTH Offline Msgpack-RPC Mock & LIVE nvim
# ---------------------------------------------------------------------------
sub run_bridge_suite {
    my ($label, $use_mock) = @_;

    my $ed = NeoPerl::Editor->new(cwd => $ROOT, load_config => 0);
    my $nb = NeoPerl::NvimBridge->new(
        mock   => $use_mock,
        cols   => 80,
        rows   => 24,
        cwd    => $ROOT,
        editor => $ed,
    );

    ok($nb->connect(), "$label: connected and attached ext_linegrid");
    ok($nb->is_connected, "$label: is_connected true");
    is($nb->is_mock, $use_mock ? 1 : 0, "$label: is_mock flag matches");
    ok(length($nb->version_string) > 0, "$label: version reported (" . $nb->version_string . ')');
    cmp_ok($nb->flush_count, '>=', 1, "$label: initial redraw flush received");

    $ed->nvim_bridge($nb);

    # Send real Vim keystrokes via nvim_input
    $nb->input('ihello world<Esc>0ciwNeoPerl<Esc>oLine2<Esc>');
    my $lines = $nb->buf_get_lines(0, 0, -1);
    is_deeply($lines, [ 'NeoPerl world', 'Line2' ], "$label: nvim_input produced exact buffer lines");

    my $cur = $nb->win_get_cursor(0);
    is_deeply($cur, [ 2, 4 ], "$label: win_get_cursor matches [2, 4] after oLine2<Esc>");

    my $mode = $nb->get_mode();
    is($mode->{mode}, 'n', "$label: nvim_get_mode reports normal ('n')");
    is($nb->display_mode, 'NORMAL', "$label: display_mode is NORMAL");

    # Verify live redraw grid reflects edited text
    my $gtext = $nb->grid_text(1);
    like($gtext, qr/NeoPerl world/, "$label: ext_linegrid contains 'NeoPerl world'");
    like($gtext, qr/Line2/,         "$label: ext_linegrid contains 'Line2'");

    # Verify Neovim ext handles decode cleanly
    my $cur_buf_ext = $nb->get_current_buf();
    is(ref($cur_buf_ext), 'HASH', "$label: nvim_get_current_buf returns Neovim ext hash");
    is($cur_buf_ext->{_nvim_ext}, 0, "$label: Buffer ext type == 0");

    # Verify namespace + extmark placement via nvim_buf_set_extmark
    my $ns = $nb->create_namespace('neoperl_test_ns');
    cmp_ok($ns, '>', 0, "$label: created namespace ($ns)");
    my $em_id = $nb->buf_set_extmark(0, $ns, 0, 0, {
        virt_text     => [ [ '  [extmark-ok]', 'Comment' ] ],
        virt_text_pos => 'eol',
    });
    cmp_ok($em_id, '>', 0, "$label: placed extmark id=$em_id");
    my $ems = $nb->buf_get_extmarks(0, $ns, 0, -1, { details => NeoPerl::NvimBridge::_mp_bool(1) });
    is(scalar(@$ems), 1, "$label: extmark retrievable via nvim_buf_get_extmarks");
    like($nb->grid_text(1), qr/extmark-ok/, "$label: extmark virtual text rendered into ext_linegrid");

    # Verify resize + redraw
    ok($nb->resize(92, 28), "$label: nvim_ui_try_resize(92, 28)");
    is($nb->cols, 92, "$label: grid cols updated to 92");
    is($nb->rows, 28, "$label: grid rows updated to 28");

    # Verify EditorMCP delegation to embedded Neovim buffer
    my $mcp = NeoPerl::Antigravity::EditorMCP->new(editor => $ed);
    my $st  = $mcp->call_tool_local('neoperl_get_editor_state', {});
    is($st->{engine}, 'nvim', "$label: EditorMCP state reports engine=nvim");
    is($st->{mode},   'NORMAL', "$label: EditorMCP state reports NORMAL mode");
    is($st->{cursor}{line}, 2, "$label: EditorMCP cursor line == 2");
    is($st->{cursor}{col},  4, "$label: EditorMCP cursor col == 4");

    my $rb = $mcp->call_tool_local('neoperl_read_buffer', {});
    ok($rb->{ok}, "$label: EditorMCP neoperl_read_buffer ok");
    is($rb->{source}, 'nvim_buffer', "$label: read_buffer sourced from nvim_buffer");
    is($rb->{content}, "NeoPerl world\nLine2", "$label: read_buffer matches live embedded Neovim buffer");

    my $pe = $mcp->call_tool_local('neoperl_propose_edit', {
        new_text => "NeoPerl world\nLine2\nLine3 proposed\n",
        title    => 'Add Line3',
    });
    ok($pe->{ok} && $pe->{staged}, "$label: EditorMCP neoperl_propose_edit staged cleanly");
    is($pe->{engine}, 'nvim', "$label: propose_edit reports engine=nvim");
    cmp_ok($pe->{hunk_count}, '>=', 1, "$label: propose_edit computed >= 1 diff hunk");

    ok($nb->accept_staged_proposal(), "$label: accept_staged_proposal applies proposal to embedded Neovim");
    my $after = $nb->buf_get_lines(0, 0, -1);
    is_deeply($after, [ 'NeoPerl world', 'Line2', 'Line3 proposed' ],
        "$label: embedded Neovim buffer updated after accept_staged_proposal");

    # Verify TUI frontend renders live NvimBridge ext_linegrid + NVIM badge
    my $tui = NeoPerl::UI::TUI->new(editor => $ed, width => 100, height => 24, headless => 1);
    my $ansi = $tui->render_frame();
    ok(length($ansi) > 50, "$label: TUI rendered embedded Neovim frame");
    my $scr = $tui->screen_text();
    like($scr, qr/NVIM /,          "$label: TUI statusline shows NVIM version badge");
    like($scr, qr/NeoPerl world/,  "$label: TUI viewport renders live ext_linegrid text");
    like($scr, qr/Line3 proposed/, "$label: TUI viewport renders updated buffer line");
    $tui->shutdown();

    ok($nb->close(), "$label: closed cleanly");
    is($nb->is_connected, 0, "$label: disconnected after close");
}

# 3a. Deterministic offline Msgpack-RPC mock (runs on EVERY platform / CI host)
subtest 'NvimBridge + EditorMCP + TUI via offline Msgpack-RPC mock' => sub {
    run_bridge_suite('mock', 1);
};

# 3b. LIVE upstream Neovim (--embed --headless) when nvim is installed
my $nvim_bin = NeoPerl::NvimBridge->find_nvim_bin();
SKIP: {
    skip 'nvim binary not installed on this host', 2 unless defined $nvim_bin;

    subtest "LIVE Neovim ($nvim_bin --embed) full Msgpack-RPC + EditorMCP + TUI" => sub {
        run_bridge_suite('live-nvim', 0);
    };

    # 4. 2x Retina AIX Amber GPU PNG frame rendered from nvim --embed
    SKIP: {
        skip 'Tcl::Tk::MT::Canvas not available on this Perl build', 1
            unless eval { require Tcl::Tk::MT; require Tcl::Tk::MT::Canvas; 1 };

        subtest 'LIVE nvim --embed + 2x Retina AIX Amber IBM Plex GPU PNG capture' => sub {
            my $tmpdir = tempdir(CLEANUP => 1);
            my $app = NeoPerl::MT->new(
                cwd         => $ROOT,
                ui          => 'gpu',
                backend     => 'auto',
                scale       => 2.0,
                headless    => 1,
                width       => 1280,
                height      => 720,
                nvim_engine => 1,
                nvim_bin    => $nvim_bin,
                nvim_mock   => 0,
                agy_mock    => 1,
                load_config => 0,
            );

            ok($app->nvim_bridge && $app->nvim_bridge->is_connected, 'NeoPerl::MT attached live NvimBridge');
            is($app->nvim_bridge->is_mock, 0, 'running against real upstream nvim binary (not mock)');
            like($app->nvim_bridge->version_string, qr/\A\d+\.\d+\.\d+/,
                'live nvim version reported (' . $app->nvim_bridge->version_string . ')');
            my $cw = $app->ui->char_w;
            my $sc = $app->ui->scale;
            ok(abs($cw * $sc - int($cw * $sc + 0.5)) < 1e-6,
                sprintf('measured char_w=%.4f snapped to exact physical pixel grid at %.1fx', $cw, $sc));

            $app->setup_demo(scene => 'aix_nvim_embed');
            my $png_path = File::Spec->catfile($tmpdir, 'nvim_embed_2x.png');
            my $res = $app->export_screenshot($png_path);
            ok($res->{ok} && -f $png_path, 'exported PNG from live nvim --embed GPU viewport');

            open my $fh, '<:raw', $png_path or die "open $png_path: $!";
            local $/;
            my $png = <$fh>;
            close $fh;
            is(substr($png, 0, 8), "\x89PNG\r\n\x1a\n", 'valid PNG signature');
            my ($pw, $ph) = unpack('N N', substr($png, 16, 8));
            # Verify true 2x Retina 2560x1440 when Tcl::Tk::MT supports 2x headless scale
            my ($surf_w, $surf_h) = $app->ui->physical_size();
            is($pw, $surf_w, "PNG width matches physical surface width ($pw)");
            is($ph, $surf_h, "PNG height matches physical surface height ($ph)");
            if ($app->ui->canvas->can('surface') && $app->ui->canvas->surface->can('physical_size')) {
                is($pw, 2560, '2x Retina headless PNG width == 2560 physical px');
                is($ph, 1440, '2x Retina headless PNG height == 1440 physical px');
            }

            # Verify AIX Amber pixels (#000000 black + #ffb000 amber phosphor) present in live nvim frame
            my $rgba = $app->ui->canvas->readback_rgba();
            my ($black_px, $amber_px) = (0, 0);
            my $len = length($rgba);
            for (my $off = 0; $off + 3 < $len; $off += 32) {
                my ($r, $g, $b) = unpack('C3', substr($rgba, $off, 3));
                if ($r <= 12 && $g <= 10 && $b <= 6) {
                    $black_px++;
                }
                elsif ($r >= 160 && $g >= 80 && $b <= 120 && $r > $g && $g > $b) {
                    $amber_px++;
                }
            }
            cmp_ok($black_px, '>', 40000, "live nvim GPU frame has pure black background ($black_px sampled px)");
            cmp_ok($amber_px, '>', 1000,  "live nvim GPU frame has AIX Amber phosphor text ($amber_px sampled px)");

            $app->shutdown();

            # CLI smoke test: bin/npl --demo --nvim-engine --agy-mock --screenshot <tmp> (defaults to 2x Retina)
            my $cli_png = File::Spec->catfile($tmpdir, 'cli_nvim_2x.png');
            my $bin_npl = File::Spec->catfile($ROOT, 'bin', 'npl');
            my @inc_args = map { "-I$_" } grep { !ref($_) && -d $_ } @INC;
            my $pid = fork();
            die "fork failed: $!" unless defined $pid;
            if ($pid == 0) {
                open STDOUT, '>', File::Spec->devnull();
                open STDERR, '>', File::Spec->devnull();
                exec { $^X } $^X, @inc_args, $bin_npl,
                    '--demo', '--nvim-engine', '--nvim-bin', $nvim_bin,
                    '--agy-mock', '--screenshot', $cli_png or exit 127;
            }
            waitpid($pid, 0);
            is($?, 0, 'bin/npl --demo --nvim-engine --screenshot exited with status 0');
            ok(-f $cli_png && -s $cli_png > 10000, 'CLI --nvim-engine --screenshot wrote non-empty PNG');
            open my $cfh, '<:raw', $cli_png or die "open $cli_png: $!";
            local $/;
            my $cpng = <$cfh>;
            close $cfh;
            my ($cw_px, $ch_px) = unpack('N N', substr($cpng, 16, 8));
            is($cw_px, $surf_w, "CLI --screenshot width == $surf_w");
            is($ch_px, $surf_h, "CLI --screenshot height == $surf_h");
        };
    }
}

done_testing();
