package NeoPerl::UI::GPU;

use strict;
use warnings;

use Compress::Zlib ();
use Scalar::Util qw(weaken);
use Time::HiRes qw(time);
use NeoPerl::Plugin::Themes ();

our $VERSION = '0.01';

my %TK_KEYSYM_MAP = (
    Return      => '<CR>',
    KP_Enter    => '<CR>',
    Escape      => '<Esc>',
    BackSpace   => '<BS>',
    Tab         => '<Tab>',
    ISO_Left_Tab => '<S-Tab>',
    Up          => '<Up>',
    Down        => '<Down>',
    Left        => '<Left>',
    Right       => '<Right>',
    Home        => '<Home>',
    End         => '<End>',
    Prior       => '<PageUp>',
    Next        => '<PageDown>',
    Delete      => '<Del>',
    Insert      => '<Insert>',
    space       => ' ',
    F1          => '<F1>',
    F2          => '<F2>',
    F3          => '<F3>',
    F4          => '<F4>',
    F5          => '<F5>',
    F6          => '<F6>',
    F7          => '<F7>',
    F8          => '<F8>',
    F9          => '<F9>',
    F10         => '<F10>',
    F11         => '<F11>',
    F12         => '<F12>',
);

my %TOK_TYPE_TO_GROUP = (
    0  => 'normal',
    1  => 'keyword',
    2  => 'string',
    3  => 'comment',
    4  => 'number',
    5  => 'variable',
    6  => 'function',
    7  => 'type',
    8  => 'operator',
    9  => 'preprocessor',
    10 => 'constant',
    11 => 'tag',
);

sub _sanitize {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\r//g;
    $str =~ s/\t/    /g;
    $str =~ s/[\x00-\x1f\x7f]/ /g;
    return $str;
}

sub _clip_chars {
    my ($str, $max_chars) = @_;
    $str = _sanitize($str);
    return '' if !defined($max_chars) || $max_chars <= 0;
    return $str if length($str) <= $max_chars;
    return substr($str, 0, $max_chars) if $max_chars <= 2;
    return substr($str, 0, $max_chars - 1) . '~';
}

sub _wrap_lines {
    my ($text, $max_chars, $max_lines) = @_;
    $max_chars = 12 if !$max_chars || $max_chars < 12;
    $max_lines ||= 6;
    $text = '' unless defined $text;
    my @out;
    for my $para (split /\n/, $text) {
        $para = _sanitize($para);
        if (!length $para) {
            push @out, '';
            last if @out >= $max_lines;
            next;
        }
        while (length($para) > $max_chars && @out < $max_lines) {
            my $cut = rindex($para, ' ', $max_chars);
            $cut = $max_chars if $cut <= 0;
            push @out, substr($para, 0, $cut);
            $para = substr($para, $cut);
            $para =~ s/\A +//;
        }
        if (length($para) && @out < $max_lines) {
            push @out, $para;
        }
        last if @out >= $max_lines;
    }
    splice(@out, $max_lines) if @out > $max_lines;
    return \@out;
}

sub _fmt_tokens {
    my ($n) = @_;
    $n = int($n || 0);
    return sprintf('%.1fk', $n / 1000.0) if $n >= 1000;
    return "$n";
}

sub _with_alpha {
    my ($hex, $alpha_hex) = @_;
    return '#000000' . ($alpha_hex || 'ff') unless defined $hex && length $hex;
    my $h = $hex;
    $h =~ s/\A#//;
    $h = substr($h, 0, 6);
    return '#' . $h . ($alpha_hex || 'ff');
}

sub _snap {
    my ($v) = @_;
    return 0 unless defined $v;
    return int($v >= 0 ? ($v + 0.5) : ($v - 0.5));
}

sub _snap_px {
    my ($self, $v) = @_;
    return 0 unless defined $v;
    my $sc = $self->{scale} || 1.0;
    return int($v * $sc + ($v >= 0 ? 0.5 : -0.5)) / $sc;
}

# ---------------------------------------------------------------------------
# Pure-Perl RGBA8888 -> PNG Encoder (via Compress::Zlib)
# ---------------------------------------------------------------------------

sub _png_chunk {
    my ($type, $data) = @_;
    my $crc = Compress::Zlib::crc32($type . $data);
    return pack('N', length($data)) . $type . $data . pack('N', $crc);
}

sub rgba_to_png {
    my ($rgba, $w, $h) = @_;
    die "rgba_to_png: invalid dimensions ${w}x${h}" unless $w && $h && $w > 0 && $h > 0;
    my $stride   = $w * 4;
    my $expected = $stride * $h;
    die "rgba_to_png: expected $expected RGBA bytes, got " . length($rgba // '')
        unless defined($rgba) && length($rgba) == $expected;

    my @scanlines;
    for my $y (0 .. $h - 1) {
        push @scanlines, "\x00" . substr($rgba, $y * $stride, $stride);
    }
    my $raw  = join('', @scanlines);
    my $zdat = Compress::Zlib::compress($raw, 6);

    my $ihdr = pack('N N C C C C C', $w, $h, 8, 6, 0, 0, 0); # 8-bit RGBA
    return "\x89PNG\r\n\x1a\n"
         . _png_chunk('IHDR', $ihdr)
         . _png_chunk('IDAT', $zdat)
         . _png_chunk('IEND', '');
}

# ---------------------------------------------------------------------------
# Constructor & Window Setup
# ---------------------------------------------------------------------------

sub new {
    my ($class, %opts) = @_;

    require Tcl::Tk::MT;
    require Tcl::Tk::MT::Canvas;

    my $headless = $opts{headless} ? 1 : 0;
    my $backend  = $opts{backend};
    my $backend_arg = (defined $backend && length $backend && lc($backend) ne 'auto')
        ? lc($backend)
        : undef;

    my $w = int($opts{width}  || 1280);
    my $h = int($opts{height} || 720);
    $w = 480 if $w < 480;
    $h = 300 if $h < 300;

    my $mono_family = $opts{font_family}    // 'IBM Plex Mono';
    my $sans_family = $opts{ui_font_family} // 'IBM Plex Sans';

    my $font_size   = int($opts{font_size} || 12);
    my $small_size  = $font_size > 10 ? ($font_size - 1) : 10;
    my $line_h      = int($opts{line_height} || ($font_size + 6));
    my $char_w      = $opts{char_width} || ($font_size * 0.60);
    my $req_scale   = (defined $opts{scale} && $opts{scale} > 0) ? ($opts{scale} + 0.0) : undef;

    my $ed    = $opts{editor};
    my $theme = ($ed && $ed->theme) ? $ed->theme : NeoPerl::Plugin::Themes->get('aix_amber');

    my $self = bless {
        editor          => $ed,
        app             => $opts{app},
        headless        => $headless,
        backend_opt     => $backend_arg,
        width           => $w,
        height          => $h,
        scale           => $req_scale || 1.0,
        req_scale       => $req_scale,
        mono_font       => [ $mono_family, $font_size ],
        small_font      => [ $mono_family, $small_size ],
        ui_font         => [ $sans_family, $font_size ],
        ui_small_font   => [ $sans_family, $small_size ],
        font_size       => $font_size,
        line_h          => $line_h,
        char_w          => $char_w,
        small_char_w    => $small_size * 0.61,
        ui_char_w       => $font_size  * 0.58,
        ui_small_char_w => $small_size * 0.58,
        tabline_h      => 30,
        statusline_h   => 24,
        cmdline_h      => 24,
        explorer_px    => 224,
        cc_width_px    => 420,
        cc_height_px   => 230,
        auto_exit_ms   => int($opts{auto_exit_ms} || 0),
        mw             => undef,
        interp         => undef,
        canvas         => undef,
        tick_id        => undef,
        exit_id        => undef,
        last_render_ms => 0.0,
        fps            => 120.0,
        frame_count    => 0,
        dirty          => 1,
        hit_regions    => [],
        _destroyed     => 0,
    }, $class;

    if (!$headless) {
        $self->_build_window($theme);
    }
    else {
        $self->{canvas} = Tcl::Tk::MT::Canvas->new(
            undef,
            '-width'    => $w,
            '-height'   => $h,
            '-bg'       => $theme->{bg},
            '-backend'  => $backend_arg,
            '-headless' => 1,
            (defined $req_scale ? ('-scale' => $req_scale) : ()),
        );
    }

    # Query actual backing scale from canvas/surface if supported
    if ($self->{canvas}) {
        my $detected;
        if ($self->{canvas}->can('scale')) {
            $detected = eval { $self->{canvas}->scale() };
        }
        elsif ($self->{canvas}->can('surface') && $self->{canvas}->surface && $self->{canvas}->surface->can('scale')) {
            $detected = eval { $self->{canvas}->surface->scale() };
        }
        $self->{scale} = $detected + 0.0 if defined $detected && $detected > 0;
    }

    $self->_calibrate_fonts() unless $opts{char_width};
    return $self;
}

sub mw             { $_[0]{mw} }
sub canvas         { $_[0]{canvas} }
sub width          { $_[0]{width} }
sub height         { $_[0]{height} }
sub scale          { $_[0]{scale} || 1.0 }
sub headless       { $_[0]{headless} }
sub last_render_ms { $_[0]{last_render_ms} }
sub fps            { $_[0]{fps} }
sub frame_count    { $_[0]{frame_count} }
sub char_w         { $_[0]{char_w} }
sub line_h         { $_[0]{line_h} }
sub font_family    { $_[0]{mono_font}[0] }
sub ui_font_family { $_[0]{ui_font}[0] }
sub mono_font      { $_[0]{mono_font} }
sub ui_font        { $_[0]{ui_font} }
sub demo_scenes    { return [qw(chat_diff aix_nvim_embed aix_mainframe_db aix_gpu_asm memory models memory_bonsai xs_cachegrind)] }

sub physical_size {
    my ($self) = @_;
    if ($self->{canvas}) {
        if ($self->{canvas}->can('physical_size')) {
            my ($pw, $ph) = eval { $self->{canvas}->physical_size() };
            return ($pw, $ph) if $pw && $ph;
        }
        my $surf = $self->{canvas}->can('surface') ? $self->{canvas}->surface : undef;
        if ($surf && $surf->can('physical_size')) {
            my ($pw, $ph) = eval { $surf->physical_size() };
            return ($pw, $ph) if $pw && $ph;
        }
    }
    my $sc = $self->{scale} || 1.0;
    return (_snap($self->{width} * $sc), _snap($self->{height} * $sc));
}

sub _active_mcp_packs {
    my ($self, $ed) = @_;
    my $reg = ($ed && $ed->plugin('mcp_registry'))
           || ($self->{app} && ref($self->{app}) && $self->{app}{mcp_registry});
    return () unless $reg && $reg->can('active_packs');
    my $list = eval { $reg->active_packs };
    return ref($list) eq 'ARRAY' ? @$list : ();
}

sub _agy_pill_spec {
    my ($self, $ed, $theme) = @_;
    my $mod  = $ed ? ($ed->plugin('modalities') || $ed->{modalities}) : undef;
    my $pill = ($mod && $mod->can('acp_status_pill')) ? eval { $mod->acp_status_pill } : undef;
    if (!$pill) {
        my $acp = $ed ? ($ed->plugin('acp') || $ed->{acp}) : undef;
        my $ok  = ($acp && $acp->can('is_ready') && $acp->is_ready) ? 1 : 0;
        my $mk  = ($acp && $acp->can('is_mock')  && $acp->is_mock)  ? 1 : 0;
        $pill = $ok
            ? { label => ($mk ? 'AGY:MOCK' : 'AGY:LIVE'), kind => ($mk ? 'mock' : 'live') }
            : { label => 'AGY:OFF', kind => 'off' };
    }
    my $lbl  = $pill->{label} || 'AGY:OFF';
    my $kind = $pill->{kind}  || 'off';
    my $fg   = $kind eq 'live'  ? $theme->{diff_add_fg}
             : $kind eq 'mock'  ? $theme->{accent2}
             : $kind eq 'sync'  ? $theme->{mode_command}
             : $kind eq 'login' ? $theme->{diag_warn}
             : $kind eq 'setup' ? $theme->{diag_info}
             : $kind eq 'error' ? $theme->{diag_error}
             : $theme->{fg_dim};
    my $out  = $kind eq 'live'  ? $theme->{diff_add_fg}
             : $kind eq 'sync'  ? $theme->{mode_command}
             : $kind eq 'login' ? $theme->{diag_warn}
             : $kind eq 'error' ? $theme->{diag_error}
             : $theme->{border};
    return [ $lbl, $fg, $theme->{bg_highlight}, $out ];
}

sub backend_name {
    my ($self) = @_;
    return defined($self->{canvas}) ? $self->{canvas}->backend_name() : 'software';
}

sub _build_window {
    my ($self, $theme) = @_;
    my ($w, $h) = ($self->{width}, $self->{height});

    my $mw = Tcl::Tk::MT::MainWindow->new('-title' => 'NeoPerl::MT');
    $self->{mw}     = $mw;
    $self->{interp} = $mw->interp;

    $mw->configure('-background' => $theme->{bg});
    $mw->geometry("${w}x${h}");
    $mw->minsize(640, 420);
    # Lock top-level propagation so internal updates cause zero window-size jitter
    eval { $self->{interp}->icall('pack', 'propagate', '.', 0) };
    eval { $self->{interp}->icall('option', 'add', '*Font', 'TkFixedFont') };

    my $weak = $self;
    weaken($weak);
    $mw->protocol('WM_DELETE_WINDOW', sub {
        $weak->quit() if $weak;
    });

    my $canvas = Tcl::Tk::MT::Canvas->new(
        $mw,
        '-width'    => $w,
        '-height'   => $h,
        '-bg'       => $theme->{bg},
        '-backend'  => $self->{backend_opt},
        '-headless' => 0,
    );
    $canvas->pack('-fill' => 'both', '-expand' => 1);
    $self->{canvas} = $canvas;

    $self->_bind_events($mw, $canvas);
    return;
}

sub _measure_font_text {
    my ($self, $text, $family, $size) = @_;
    my $c = $self->{canvas} or return undef;
    if ($c->can('measure_text')) {
        my ($w) = eval { $c->measure_text($text, $family, $size) };
        $w = $w->{width} if ref($w) eq 'HASH';
        return $w if defined($w) && $w > 0;
    }
    my $scn = $c->can('scene') ? $c->scene : undef;
    if ($scn && $scn->can('measure_text')) {
        my ($w) = eval { $scn->measure_text($text, $family, $size) };
        $w = $w->{width} if ref($w) eq 'HASH';
        return $w if defined($w) && $w > 0;
    }
    return undef;
}

sub _calibrate_fonts {
    my ($self) = @_;
    my $c = $self->{canvas} or return;
    my $scale = $self->{scale} || 1.0;

    for my $spec (
        [ 'mono_font',     'char_w',          $self->{font_size},     'MMMMMMMMMM',       1 ],
        [ 'small_font',    'small_char_w',    $self->{font_size} - 1, 'MMMMMMMMMM',       1 ],
        [ 'ui_font',       'ui_char_w',       $self->{font_size},     'AbCdEfGh01234567', 0 ],
        [ 'ui_small_font', 'ui_small_char_w', $self->{font_size} - 1, 'AbCdEfGh01234567', 0 ],
    ) {
        my ($fkey, $ckey, $sz, $probe, $snap_grid) = @$spec;
        my ($fam, $fsz) = @{ $self->{$fkey} };
        my $tw = $self->_measure_font_text($probe, $fam, $fsz);

        if (!defined($tw) || $tw <= 0) {
            my $id = eval {
                $c->createText(0, 0, '-text' => $probe, '-font' => $self->{$fkey}, '-anchor' => 'nw');
            };
            if (defined $id) {
                my $bb = eval { $c->bbox($id) };
                eval { $c->delete($id) };
                if (ref($bb) eq 'ARRAY' && @$bb >= 4) {
                    $tw = $bb->[2] - $bb->[0];
                }
            }
        }

        if (defined($tw) && $tw > 0) {
            my $m = $tw / length($probe);
            if ($m >= 4.0 && $m <= $sz * 1.4) {
                $m = int($m * $scale + 0.5) / $scale if $snap_grid;
                $self->{$ckey} = $m;
            }
        }
    }
    return;
}

sub _bind_events {
    my ($self, $mw, $canvas) = @_;
    my $weak = $self;
    weaken($weak);

    $canvas->bind('<Configure>', [ sub {
        my ($wid, $nw, $nh) = @_;
        return unless $weak && !$weak->{_destroyed};
        $weak->_on_resize($nw, $nh);
    }, Tcl::Tk::MT::Ev('w', 'h') ]);

    $mw->bind('<KeyPress>', [ sub {
        my ($wid, $keysym, $unicode, $state) = @_;
        return unless $weak && !$weak->{_destroyed};
        $weak->_on_keypress($keysym, $unicode, $state);
    }, Tcl::Tk::MT::Ev('K', 'A', 's') ]);

    $canvas->bind('<Button-1>', [ sub {
        my ($wid, $x, $y) = @_;
        return unless $weak && !$weak->{_destroyed};
        $weak->_on_click($x, $y);
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $canvas->bind('<MouseWheel>', [ sub {
        my ($wid, $delta) = @_;
        return unless $weak && !$weak->{_destroyed};
        $weak->_on_wheel($delta);
    }, Tcl::Tk::MT::Ev('D') ]);

    $canvas->bind('<Button-4>', sub {
        return unless $weak && !$weak->{_destroyed};
        $weak->_scroll_active(-3);
    });
    $canvas->bind('<Button-5>', sub {
        return unless $weak && !$weak->{_destroyed};
        $weak->_scroll_active(3);
    });
    return;
}

sub _on_resize {
    my ($self, $nw, $nh) = @_;
    $nw = int($nw || 0);
    $nh = int($nh || 0);
    return if $nw < 200 || $nh < 150;
    return if $nw == $self->{width} && $nh == $self->{height};
    $self->{width}  = $nw;
    $self->{height} = $nh;
    $self->{canvas}->configure('-width' => $nw, '-height' => $nh);
    $self->render_frame();
    return;
}

sub _on_keypress {
    my ($self, $keysym, $unicode, $state) = @_;
    my $ed = $self->{editor} or return;
    $keysym  //= '';
    $unicode //= '';
    $state   = int($state || 0);

    # Ignore bare modifier presses
    return if $keysym =~ /\A(?:Shift|Control|Alt|Meta|Super|Hyper|Caps_Lock|Mode_switch)/;

    my $ctrl = ($state & 0x04) ? 1 : 0;
    my $meta = ($state & (0x08 | 0x10)) ? 1 : 0;

    my $key;
    if (exists $TK_KEYSYM_MAP{$keysym}) {
        $key = $TK_KEYSYM_MAP{$keysym};
    }
    elsif ($ctrl && length($keysym) == 1) {
        $key = '<C-' . lc($keysym) . '>';
    }
    elsif ($meta && length($keysym) == 1) {
        $key = '<M-' . lc($keysym) . '>';
    }
    elsif (length($unicode) && ord($unicode) >= 32 && ord($unicode) != 127) {
        $key = $unicode;
    }
    elsif (length($keysym) == 1) {
        $key = $keysym;
    }
    else {
        return;
    }

    # Route active permission keys or chat composer input when CHAT tab is open
    my $mod = $ed->plugin('modalities') || $ed->{modalities};
    if ($mod && $ed->layout->command_center_open && $ed->layout->command_center_tab eq 'chat') {
        my $cs = eval { $mod->chat_state };
        if ($cs && $cs->{pending_perm} && ($key eq 'a' || $key eq 'A' || $key eq 'r')) {
            $mod->handle_permission_key($key);
            $self->render_frame();
            return;
        }
        if ($mod->can('is_chat_input_active') && $mod->is_chat_input_active) {
            if ($mod->handle_chat_input_key($key)) {
                $self->render_frame();
                return;
            }
        }
    }

    $ed->handle_key($key);
    $self->render_frame();
    if (!$ed->running) {
        $self->quit();
    }
    return;
}

sub _on_click {
    my ($self, $x, $y) = @_;
    my $ed = $self->{editor} or return;
    for my $hr (reverse @{ $self->{hit_regions} }) {
        if ($x >= $hr->{x0} && $x <= $hr->{x1} && $y >= $hr->{y0} && $y <= $hr->{y1}) {
            if (ref($hr->{cb}) eq 'CODE') {
                $hr->{cb}->($x, $y);
                $self->render_frame();
                return;
            }
        }
    }
    return;
}

sub _on_wheel {
    my ($self, $delta) = @_;
    $delta = int($delta || 0);
    return if $delta == 0;
    my $step = (abs($delta) >= 120) ? int(-$delta / 40) : int(-$delta * 3);
    $step = ($delta > 0 ? -3 : 3) if $step == 0;
    $self->_scroll_active($step);
    return;
}

sub _scroll_active {
    my ($self, $delta) = @_;
    my $ed  = $self->{editor} or return;
    my $win = $ed->current_window or return;
    my $buf = $ed->current_buffer or return;
    my $max = $buf->line_count > 1 ? $buf->line_count - 1 : 0;
    my $nt  = ($win->scroll_top || 0) + $delta;
    $nt = 0    if $nt < 0;
    $nt = $max if $nt > $max;
    $win->scroll_top($nt);
    $self->render_frame();
    return;
}

sub _add_hit {
    my ($self, $x0, $y0, $x1, $y1, $cb) = @_;
    push @{ $self->{hit_regions} }, { x0 => $x0, y0 => $y0, x1 => $x1, y1 => $y1, cb => $cb };
    return;
}

# ---------------------------------------------------------------------------
# Drawing Helpers on Tcl::Tk::MT::Canvas
# ---------------------------------------------------------------------------

sub _rect {
    my ($self, $x0, $y0, $x1, $y1, $fill, $outline, $width, $radius) = @_;
    $x0 = _snap($x0);
    $y0 = _snap($y0);
    $x1 = _snap($x1);
    $y1 = _snap($y1);
    my @opts = (
        '-fill'    => ($fill    // ''),
        '-outline' => ($outline // ''),
    );
    if (defined $outline && length $outline) {
        push @opts, '-width' => (defined($width) ? $width : 1);
        push @opts, '-inset_stroke' => 1;
    }
    elsif (defined $width) {
        push @opts, '-width' => $width;
    }
    push @opts, '-radius' => $radius if defined $radius && $radius > 0;
    return $self->{canvas}->createRectangle($x0, $y0, $x1, $y1, @opts);
}

sub _hline {
    my ($self, $x, $y, $w, $color) = @_;
    return if !defined($w) || $w <= 0;
    my $ix = _snap($x);
    my $iy = _snap($y);
    my $iw = _snap($w);
    return $self->{canvas}->createRectangle($ix, $iy, $ix + $iw, $iy + 1, '-fill' => $color, '-outline' => '');
}

sub _vline {
    my ($self, $x, $y, $h, $color) = @_;
    return if !defined($h) || $h <= 0;
    my $ix = _snap($x);
    my $iy = _snap($y);
    my $ih = _snap($h);
    return $self->{canvas}->createRectangle($ix, $iy, $ix + 1, $iy + $ih, '-fill' => $color, '-outline' => '');
}

sub _pill {
    my ($self, $x, $y, $h, $text, $fg, $bg, $font, $cw, $outline) = @_;
    $font ||= $self->{ui_small_font};
    $cw   ||= $self->{ui_small_char_w};
    $text = _sanitize($text);
    $x    = _snap($x);
    $y    = _snap($y);
    $h    = _snap($h);
    my $pad_x = 8;
    my $pw    = _snap(length($text) * $cw) + $pad_x * 2 + 2;
    $self->_rect($x, $y, $x + $pw, $y + $h, $bg, ($outline // ''), ($outline ? 1 : undef), 5);
    $self->{canvas}->createText(
        _snap($x + $pad_x), _snap($y + int(($h - ($self->{font_size} - 1)) / 2) - 1),
        '-text'   => $text,
        '-fill'   => $fg,
        '-font'   => $font,
        '-anchor' => 'nw',
    );
    return $pw;
}

sub _extmark_color {
    my ($theme, $hl) = @_;
    return $theme->{virt_text} unless defined $hl;
    return $theme->{diag_error}   if $hl eq 'DiagError';
    return $theme->{diag_warn}    if $hl eq 'DiagWarn';
    return $theme->{diag_info}    if $hl eq 'DiagInfo';
    return $theme->{diag_hint}    if $hl eq 'DiagHint';
    return $theme->{diff_add_fg}  if $hl eq 'DiffAdd';
    return $theme->{diff_del_fg}  if $hl eq 'DiffDelete';
    return $theme->{ghost_text}   if $hl eq 'GhostText';
    return $theme->{heat_crit}    if $hl eq 'XSPerfHot';
    return $theme->{heat_hot}     if $hl eq 'XSPerfWarm';
    return $theme->{heat_warm}    if $hl eq 'XSPerfMild';
    return $theme->{heat_cold}    if $hl eq 'XSPerfCool';
    return $theme->{breakpoint}   if $hl eq 'XSDebugBreakpoint';
    return $theme->{mode_command} if $hl eq 'XSDebugPC';
    return $theme->{git_add}      if $hl eq 'GitAdd';
    return $theme->{git_change}   if $hl eq 'GitChange';
    return $theme->{git_delete}   if $hl eq 'GitDelete';
    return $theme->{diff_add_fg}  if $hl eq 'XSVecOpt';
    return $theme->{diag_warn}    if $hl eq 'XSVecMissed';
    return $theme->{accent2}      if $hl =~ /VSX|MMA/i;
    return $theme->{mode_command} if $hl =~ /TOC|Barrier|SMT/i;
    return $theme->{virt_text};
}

# ---------------------------------------------------------------------------
# Pixel Layout Calculation (Synced with Editor->layout)
# ---------------------------------------------------------------------------

sub _compute_pixel_layout {
    my ($self, $ed) = @_;
    my ($W, $H) = ($self->{width}, $self->{height});
    my $tab_h  = $self->{tabline_h};
    my $stat_h = $self->{statusline_h};
    my $cmd_h  = $self->{cmdline_h};

    my $body_y = $tab_h;
    my $body_h = $H - $tab_h - $stat_h - $cmd_h;
    $body_h = 80 if $body_h < 80;

    my $layout = $ed->layout;
    my $grid_w = int($W / ($self->{char_w} || 7.2));
    my $grid_h = int($H / ($self->{line_h} || 18));
    $grid_w = 80 if $grid_w < 80;
    $grid_h = 24 if $grid_h < 24;
    my $crects = $layout->compute_rects($grid_w, $grid_h);

    my $ed_x = 0;
    my $ed_y = $body_y;
    my $ed_w = $W;
    my $ed_h = $body_h;

    my $exp_px;
    if ($layout->explorer_open) {
        my $ew = $self->{explorer_px};
        $ew = int($W * 0.24) if $ew > int($W * 0.24);
        $exp_px = { x => 0, y => $body_y, w => $ew, h => $body_h };
        $ed_x += $ew;
        $ed_w -= $ew;
    }

    my $cc_px;
    if ($layout->command_center_open) {
        if ($layout->command_center_position eq 'bottom') {
            my $ch = $self->{cc_height_px};
            $ch = int($ed_h * 0.44) if $ch > int($ed_h * 0.44);
            $ed_h -= $ch;
            $cc_px = { x => $ed_x, y => $ed_y + $ed_h, w => $ed_w, h => $ch };
        }
        else {
            my $cw = $self->{cc_width_px};
            $cw = int($ed_w * 0.42) if $cw > int($ed_w * 0.42);
            $cw = 320 if $cw < 320 && $ed_w >= 660;
            $ed_w -= $cw;
            $cc_px = { x => $ed_x + $ed_w, y => $ed_y, w => $cw, h => $ed_h };
        }
    }

    # Map BSP window cell rects proportionally onto exact editor pixel area
    my $ea = $crects->{editor_area} || { x => 0, y => 1, width => $grid_w, height => $grid_h - 3 };
    my $ea_w = $ea->{width}  || 1;
    my $ea_h = $ea->{height} || 1;
    my @win_px;
    for my $wr (@{ $crects->{windows} || [] }) {
        my $rx0 = int($ed_x + (($wr->{x} - $ea->{x}) / $ea_w) * $ed_w);
        my $ry0 = int($ed_y + (($wr->{y} - $ea->{y}) / $ea_h) * $ed_h);
        my $rx1 = int($ed_x + (($wr->{x} + $wr->{width}  - $ea->{x}) / $ea_w) * $ed_w);
        my $ry1 = int($ed_y + (($wr->{y} + $wr->{height} - $ea->{y}) / $ea_h) * $ed_h);
        push @win_px, {
            win_id => $wr->{win_id},
            buf_id => $wr->{buf_id},
            window => $wr->{window},
            x      => $rx0,
            y      => $ry0,
            w      => ($rx1 - $rx0 > 40 ? $rx1 - $rx0 : 40),
            h      => ($ry1 - $ry0 > 40 ? $ry1 - $ry0 : 40),
        };
    }

    return {
        tabline        => { x => 0, y => 0, w => $W, h => $tab_h },
        explorer       => $exp_px,
        command_center => $cc_px,
        editor_area    => { x => $ed_x, y => $ed_y, w => $ed_w, h => $ed_h },
        windows        => \@win_px,
        floats         => $crects->{floats} || [],
        grid_w         => $grid_w,
        grid_h         => $grid_h,
        statusline     => { x => 0, y => $H - $stat_h - $cmd_h, w => $W, h => $stat_h },
        cmdline        => { x => 0, y => $H - $cmd_h,           w => $W, h => $cmd_h  },
    };
}

# ---------------------------------------------------------------------------
# Master Frame Renderer (Single Batched Scene Submission)
# ---------------------------------------------------------------------------

sub render_frame {
    my ($self) = @_;
    return 0 if $self->{_destroyed} || !defined($self->{canvas}) || !defined($self->{editor});

    my $t0     = time();
    my $ed     = $self->{editor};
    my $canvas = $self->{canvas};
    my $theme  = $ed->theme || NeoPerl::Plugin::Themes->get('aix_amber');
    my $px     = $self->_compute_pixel_layout($ed);

    $self->{hit_regions} = [];

    $canvas->batch(sub {
        $canvas->delete('all');

        # Full canvas backdrop
        $self->_rect(0, 0, $self->{width}, $self->{height}, $theme->{bg}, '');

        # 1. Top Tabline
        $self->_draw_tabline($ed, $theme, $px->{tabline});

        # 2. Left File Explorer (if toggled)
        $self->_draw_explorer($ed, $theme, $px->{explorer}) if $px->{explorer};

        # 3. Recursive BSP Editor Splits (or live embedded Neovim ext_linegrid)
        my $nb = ($ed->can('nvim_bridge') && $ed->nvim_bridge && eval { $ed->nvim_bridge->is_connected })
            ? $ed->nvim_bridge : undef;
        if ($nb && $px->{editor_area}) {
            $self->_draw_nvim_viewport($ed, $theme, $px->{editor_area}, $nb);
        }
        else {
            my $wins       = $px->{windows} || [];
            my $active_win = $ed->layout->active_window;
            my $multi      = scalar(@$wins) > 1 ? 1 : 0;
            for my $wpx (@$wins) {
                my $is_active = ($active_win && $wpx->{win_id} == $active_win->id) ? 1 : 0;
                $self->_draw_editor_split($ed, $theme, $wpx, $is_active, $multi);
            }
        }

        # 4. Docked 4-Tab Command Center (hidden when closed)
        $self->_draw_command_center($ed, $theme, $px->{command_center}) if $px->{command_center};

        # 5. Bottom Powerline Statusline & Command Line
        $self->_draw_statusline($ed, $theme, $px->{statusline});
        $self->_draw_cmdline($ed, $theme, $px->{cmdline});

        # 6. Z-Ordered Rounded Floating Windows with Drop Shadows
        for my $frect (@{ $px->{floats} || [] }) {
            $self->_draw_float($ed, $theme, $frect, $px);
        }
    });

    $canvas->render();
    my $dt_ms = (time() - $t0) * 1000.0;
    $self->{last_render_ms} = $dt_ms;
    $self->{fps} = $dt_ms > 0.01 ? (1000.0 / $dt_ms) : 999.0;
    $self->{frame_count}++;
    $self->{dirty} = 0;
    return $dt_ms;
}

# ---------------------------------------------------------------------------
# 1. Top Tabline
# ---------------------------------------------------------------------------

sub _draw_tabline {
    my ($self, $ed, $theme, $r) = @_;
    my $c = $self->{canvas};
    my ($x, $y, $w, $h) = ($r->{x}, $r->{y}, $r->{w}, $r->{h});

    $self->_rect($x, $y, $x + $w, $y + $h, $theme->{bg_tabline}, '');
    $self->_hline($x, $y + $h - 1, $w, $theme->{border});

    # Brand pill on far left (IBM Plex Sans UI chrome)
    my $usf  = $self->{ui_small_font};
    my $uscw = $self->{ui_small_char_w};
    my $cx = $x + 8;
    $cx += $self->_pill($cx, $y + 5, 20, 'npl', $theme->{cursor_fg}, $theme->{accent}, $usf, $uscw);
    $cx += 10;

    # Right-side status pills: NVIM (when active), PACKS (when mounted), AGY, Db2, LOCAL, MOJO
    my @pills;
    my $nb = ($ed->can('nvim_bridge') && $ed->nvim_bridge && eval { $ed->nvim_bridge->is_connected })
        ? $ed->nvim_bridge : undef;
    if ($nb) {
        push @pills, [ 'NVIM ' . $nb->version_string, $theme->{accent}, $theme->{bg_highlight}, $theme->{border_focus} ];
    }
    my @active_packs = $self->_active_mcp_packs($ed);
    if (@active_packs) {
        my $plbl = 'MCP:' . join(',', @active_packs);
        $plbl = sprintf('MCP:%d packs', scalar(@active_packs)) if length($plbl) > 22;
        push @pills, [ $plbl, $theme->{accent}, $theme->{bg_highlight}, $theme->{border_focus} ];
    }

    push @pills, $self->_agy_pill_spec($ed, $theme);

    my $mem = $ed->plugin('memory') || $ed->{memory_store};
    if ($mem) {
        my $d = eval { $mem->dialect } || 'db2';
        my $st = eval { $mem->stats } || {};
        my $cnt = $st->{active_memories} // $st->{memories} // 0;
        my $lbl = ($d =~ /db2/i ? 'Db2:VEC' : 'Db2:SIMD') . ($cnt ? " ($cnt)" : '');
        push @pills, [ $lbl, $theme->{diag_info}, $theme->{bg_highlight}, $theme->{border} ];
    }

    my $inf = $ed->plugin('inference') || $ed->{inference};
    if ($inf) {
        my $tel = eval { $inf->telemetry } || {};
        my $lbl = sprintf('LOCAL %.1f/%.0fG', $tel->{resident_gb} || 0, $tel->{ram_budget_gb} || 20);
        push @pills, [ $lbl, $theme->{accent2}, $theme->{bg_highlight}, $theme->{border} ];
        if ($tel->{mojo_accel} && $tel->{mojo_accel}{available}) {
            push @pills, [ 'MOJO', $theme->{mode_terminal}, $theme->{bg_highlight}, $theme->{border} ];
        }
    }

    my $pills_total_w = 10;
    for my $p (@pills) {
        $pills_total_w += int(length($p->[0]) * $uscw + 0.5) + 18 + 6;
    }

    my $tabs_right_limit = $x + $w - $pills_total_w - 8;
    my $cur_buf = $ed->current_buffer;
    my $cur_id  = $cur_buf ? $cur_buf->id : -1;

    for my $b ($ed->list_buffers) {
        last if $cx + 60 > $tabs_right_limit;
        my $active = ($b->id == $cur_id);
        my $name   = _clip_chars($b->name, 22);
        my $dirty  = $b->modified ? 1 : 0;
        my $tw     = int(length($name) * $uscw + 0.5) + ($dirty ? 32 : 24);
        $tw = $tabs_right_limit - $cx if $cx + $tw > $tabs_right_limit;
        last if $tw < 40;

        if ($active) {
            $self->_rect($cx, $y + 2, $cx + $tw, $y + $h - 1, $theme->{bg}, '');
            $self->_rect($cx, $y, $cx + $tw, $y + 2, $theme->{accent}, '');
        }
        else {
            $self->_rect($cx, $y + 3, $cx + $tw, $y + $h - 1, $theme->{bg_dark}, '');
        }
        $self->_vline($cx + $tw, $y + 4, $h - 8, $theme->{border});

        my $max_c = int(($tw - ($dirty ? 24 : 14)) / ($uscw || 6.4));
        $c->createText(
            $cx + 8, $y + 8,
            '-text'   => _clip_chars($name, $max_c),
            '-fill'   => $active ? $theme->{fg} : $theme->{fg_dim},
            '-font'   => $usf,
            '-anchor' => 'nw',
        );
        if ($dirty) {
            $c->createOval(
                $cx + $tw - 13, $y + 12, $cx + $tw - 7, $y + 18,
                '-fill'    => $theme->{mode_command},
                '-outline' => '',
            );
        }

        my $bid = $b->id;
        $self->_add_hit($cx, $y, $cx + $tw, $y + $h, sub { $ed->switch_buffer($bid) });
        $cx += $tw + 2;
    }

    # Draw right-aligned pills
    my $px = $x + $w - $pills_total_w + 4;
    for my $p (@pills) {
        my $pw = $self->_pill($px, $y + 5, 20, $p->[0], $p->[1], $p->[2], $usf, $uscw, $p->[3]);
        $px += $pw + 6;
    }
    return;
}

# ---------------------------------------------------------------------------
# 2. Left File Explorer
# ---------------------------------------------------------------------------

sub _draw_explorer {
    my ($self, $ed, $theme, $r) = @_;
    my $c = $self->{canvas};
    my ($x, $y, $w, $h) = ($r->{x}, $r->{y}, $r->{w}, $r->{h});

    $self->_rect($x, $y, $x + $w, $y + $h, $theme->{bg_sidebar}, '');
    $self->_vline($x + $w - 1, $y, $h, $theme->{border});

    # Header
    $self->_rect($x, $y, $x + $w - 1, $y + 24, $theme->{bg_dark}, '');
    $c->createText(
        $x + 10, $y + 5,
        '-text'   => 'EXPLORER',
        '-fill'   => $theme->{accent},
        '-font'   => $self->{ui_small_font},
        '-anchor' => 'nw',
    );

    my $exp   = $ed->plugin('explorer') or return;
    my $nodes = $exp->visible_nodes || [];
    my $cur   = $exp->cursor || 0;
    my $row_h = $self->{line_h};
    my $vis   = int(($h - 28) / $row_h);
    $vis = 1 if $vis < 1;
    my $start = ($cur >= $vis) ? ($cur - $vis + 1) : 0;

    for my $i (0 .. $vis - 1) {
        my $idx = $start + $i;
        last if $idx >= @$nodes;
        my $n   = $nodes->[$idx];
        my $ry  = $y + 26 + $i * $row_h;
        my $sel = ($idx == $cur);

        if ($sel) {
            $self->_rect($x + 2, $ry, $x + $w - 3, $ry + $row_h - 1, $theme->{bg_highlight}, '', undef, 4);
        }

        my $indent_px = 8 + ($n->{depth} || 0) * 12;
        my $prefix    = $n->{is_dir} ? ($n->{expanded} ? 'v ' : '> ') : '  ';
        my $fg        = $n->{is_dir} ? $theme->{accent} : $theme->{fg};
        my $badge     = $n->{git_badge} || '';
        my $avail_px  = $w - $indent_px - (length($badge) ? 24 : 10);
        my $max_c     = int($avail_px / ($self->{small_char_w} || 6.6));
        $max_c = 4 if $max_c < 4;

        $c->createText(
            $x + $indent_px, $ry + 2,
            '-text'   => _clip_chars($prefix . ($n->{name} // ''), $max_c),
            '-fill'   => $fg,
            '-font'   => $self->{small_font},
            '-anchor' => 'nw',
        );

        if (length $badge) {
            my $bfg = $badge eq 'A' ? $theme->{git_add}
                    : $badge eq 'D' ? $theme->{git_delete}
                    : $theme->{git_change};
            $c->createText(
                $x + $w - 16, $ry + 2,
                '-text'   => $badge,
                '-fill'   => $bfg,
                '-font'   => $self->{small_font},
                '-anchor' => 'nw',
            );
        }

        my $node_idx = $idx;
        $self->_add_hit($x, $ry, $x + $w - 1, $ry + $row_h, sub { $exp->select_node($node_idx) });
    }
    return;
}

# ---------------------------------------------------------------------------
# 3. Recursive BSP Editor Split
# ---------------------------------------------------------------------------

sub _draw_editor_split {
    my ($self, $ed, $theme, $r, $is_active, $multi_split) = @_;
    my $c   = $self->{canvas};
    my $win = $r->{window};
    my $buf = $ed->get_buffer($r->{buf_id});
    my ($x, $y, $w, $h) = ($r->{x}, $r->{y}, $r->{w}, $r->{h});

    $self->_rect($x, $y, $x + $w, $y + $h, $theme->{bg}, '');

    # Split border lines (1 px filled rects)
    if ($multi_split) {
        $self->_vline($x + $w - 1, $y, $h, $theme->{border});
        $self->_hline($x, $y + $h - 1, $w, $theme->{border});
    }

    my $cy = $y;
    my $ch = $h;
    if ($multi_split && $h > 44) {
        my $wb_h  = 22;
        my $wb_bg = $is_active ? $theme->{bg_highlight} : $theme->{bg_dark};
        $self->_rect($x, $y, $x + $w - 1, $y + $wb_h, $wb_bg, '');
        if ($is_active) {
            $self->_rect($x, $y, $x + $w - 1, $y + 2, $theme->{border_focus}, '');
        }
        my $bname = $buf ? $buf->name : '[No Name]';
        my $bft   = $buf ? ($buf->filetype || 'text') : 'text';
        my $dirty = ($buf && $buf->modified) ? ' [+]' : '';
        my $maxc  = int(($w - 16) / ($self->{ui_small_char_w} || 6.4));
        $c->createText(
            $x + 10, $y + 4,
            '-text'   => _clip_chars("$bname$dirty  [$bft]", $maxc),
            '-fill'   => $is_active ? $theme->{fg} : $theme->{fg_dim},
            '-font'   => $self->{ui_small_font},
            '-anchor' => 'nw',
        );
        $cy += $wb_h;
        $ch -= $wb_h;
    }

    my $wid = $r->{win_id};
    $self->_add_hit($x, $y, $x + $w, $y + $h, sub { $ed->layout->focus_window($wid) });

    return unless $buf && $ch > 10 && $w > 40;

    my $line_h = $self->{line_h};
    my $char_w = $self->{char_w};
    my $font   = $self->{mono_font};
    my $sfont  = $self->{small_font};
    my $scharw = $self->{small_char_w};

    # Terminal buffer mode
    if ($buf->buftype eq 'terminal' && $buf->term) {
        my $scr = $buf->terminal_screen;
        if ($scr && ref($scr->{runs}) eq 'ARRAY') {
            my $vis_rows = int($ch / $line_h);
            my $runs = $scr->{runs};
            for my $row (0 .. $vis_rows - 1) {
                last if $row >= @$runs;
                my $ry = $cy + 4 + $row * $line_h;
                my $cx = $x + 8;
                for my $seg (@{ $runs->[$row] }) {
                    my $txt = _sanitize($seg->{text} // '');
                    next unless length $txt;
                    my $sfg = (defined($seg->{fg}) && $seg->{fg} >= 0) ? sprintf('#%06x', $seg->{fg} & 0xFFFFFF) : $theme->{fg};
                    my $sbg = (defined($seg->{bg}) && $seg->{bg} >= 0) ? sprintf('#%06x', $seg->{bg} & 0xFFFFFF) : undef;
                    my $sw  = length($txt) * $char_w;
                    $self->_rect($cx, $ry, $cx + $sw, $ry + $line_h, $sbg, '') if $sbg;
                    $c->createText($self->_snap_px($cx), _snap($ry + 2), '-text' => $txt, '-fill' => $sfg, '-font' => $font, '-anchor' => 'nw');
                    $cx += $sw;
                    last if $cx >= $x + $w - 4;
                }
            }
            return;
        }
    }

    my $total    = $buf->line_count || 1;
    my $top      = $win->scroll_top  || 0;
    my $left_col = $win->scroll_left || 0;
    my $cur_line = $win->cursor_line || 0;
    my $cur_col  = $win->cursor_col  || 0;
    my $rel_num  = $ed->get_option('relativenumber');

    my $digits   = length("$total");
    $digits = 4 if $digits < 4;
    # Gutter layout: [4px heatbar][18px sign][digits*char_w][6px pad][4px git bar]
    my $gutter_w = 4 + 18 + int($digits * $char_w + 0.5) + 12;
    my $text_x0  = $x + $gutter_w + 8;
    my $text_px  = ($x + $w - 6) - $text_x0;
    return if $text_px < 24;
    my $vis_cols = int($text_px / $char_w);
    $vis_cols = 8 if $vis_cols < 8;
    my $vis_rows = int(($ch - 6) / $line_h);
    $vis_rows = 1 if $vis_rows < 1;

    # Gutter background and 1 px hairline
    $self->_rect($x, $cy, $x + $gutter_w, $cy + $ch, $theme->{bg_dark}, '');
    $self->_vline($x + $gutter_w, $cy, $ch, $theme->{border});

    my $lines  = $buf->get_lines($top, $top + $vis_rows + 2);
    my $spans  = $buf->highlight_range($top, scalar(@$lines));
    my $extmks = $buf->get_all_extmarks($top, $top + scalar(@$lines) + 1) || [];

    my %em_by_line;
    for my $em (@$extmks) {
        push @{ $em_by_line{ $em->{line} } }, $em;
    }

    my $modal = $ed->modal;
    my $mode  = $modal->mode;
    my $vis   = $is_active ? $modal->visual_range($ed) : undef;

    my $srow = 0;
    for my $i (0 .. $#$lines) {
        last if $srow >= $vis_rows;
        my $line_no = $top + $i;
        my $text    = $lines->[$i] // '';
        my $ems     = $em_by_line{$line_no} || [];

        # 1. Virtual lines ABOVE (red deleted diff lines & code lenses)
        for my $em (@$ems) {
            next unless $em->{virt_lines_above} && ref($em->{virt_lines}) eq 'ARRAY';
            my $vhl = ref($em->{virt_lines_hl}) eq 'ARRAY' ? $em->{virt_lines_hl}[0] : ($em->{virt_lines_hl} // 'DiffDelete');
            my $is_del = ($vhl eq 'DiffDelete');
            my $vfg = _extmark_color($theme, $vhl);
            my $vbg = $is_del ? $theme->{diff_del_bg} : $theme->{bg_dark};

            for my $vl (@{ $em->{virt_lines} }) {
                last if $srow >= $vis_rows;
                my $ry = $cy + 4 + $srow * $line_h;
                $self->_rect($x + $gutter_w + 1, $ry, $x + $w - 2, $ry + $line_h, $vbg, '');
                if ($is_del) {
                    $self->_rect($x + $gutter_w - 4, $ry + 1, $x + $gutter_w - 1, $ry + $line_h - 1, $theme->{diff_del_fg}, '');
                    $c->createText($x + 8, $ry + 2, '-text' => '-', '-fill' => $theme->{diff_del_fg}, '-font' => $font, '-anchor' => 'nw');
                }
                $c->createText(
                    $text_x0, $ry + 2,
                    '-text'   => _clip_chars($vl, $vis_cols),
                    '-fill'   => $vfg,
                    '-font'   => $is_del ? $font : $sfont,
                    '-anchor' => 'nw',
                );
                $srow++;
            }
        }
        last if $srow >= $vis_rows;

        my $ry  = $cy + 4 + $srow * $line_h;
        my $ry2 = $ry + $line_h;

        # Classify extmarks on this line
        my ($heat_hl, $sign_txt, $sign_hl, $git_hl, $has_bp, $has_pc, $line_bg_hl);
        my (@eol_virts, @inline_virts);

        for my $em (sort { ($b->{priority} || 0) <=> ($a->{priority} || 0) } @$ems) {
            my $ns = $em->{ns} // '';
            if ($ns eq 'xs_perf') {
                $heat_hl ||= $em->{sign_hl} || $em->{virt_hl};
            }
            elsif ($ns eq 'git_gutter') {
                $git_hl ||= $em->{sign_hl};
            }
            elsif ($ns eq 'xs_debug') {
                $has_bp = 1 if ($em->{sign_hl} // '') eq 'XSDebugBreakpoint';
                $has_pc = 1 if ($em->{sign_hl} // '') eq 'XSDebugPC';
            }
            elsif (defined $em->{sign_text} && length($em->{sign_text}) && !defined($sign_txt)) {
                $sign_txt = substr($em->{sign_text}, 0, 1);
                $sign_hl  = $em->{sign_hl};
            }

            if (defined $em->{hl_group}) {
                if ($em->{hl_group} eq 'DiffAdd' || $em->{hl_group} eq 'XSDebugPCLine') {
                    $line_bg_hl ||= $em->{hl_group};
                }
            }

            if (defined $em->{virt_text} && length $em->{virt_text}) {
                if (($em->{virt_pos} // 'eol') eq 'inline' || $ns eq 'agy_ghost') {
                    push @inline_virts, $em;
                }
                else {
                    push @eol_virts, $em;
                }
            }
        }

        # Line background highlight
        my $line_bg;
        if (($line_bg_hl // '') eq 'DiffAdd') {
            $line_bg = $theme->{diff_add_bg};
        }
        elsif ($has_pc || ($line_bg_hl // '') eq 'XSDebugPCLine') {
            $line_bg = $theme->{pc_line};
        }
        elsif ($is_active && $line_no == $cur_line) {
            $line_bg = $theme->{bg_highlight};
        }
        if ($line_bg) {
            $self->_rect($x + $gutter_w + 1, $ry, $x + $w - 2, $ry2, $line_bg, '');
        }

        # Cachegrind color-coded 4px gutter heatbar strip
        if ($heat_hl) {
            my $hcol = _extmark_color($theme, $heat_hl);
            $self->_rect($x + 1, $ry + 1, $x + 5, $ry2 - 1, $hcol, '', undef, 1);
        }

        # GDB Breakpoint dot / PC arrow / Diag or Diff sign
        if ($has_bp) {
            my $cy_mid = $ry + int($line_h / 2);
            $c->createOval($x + 8, $cy_mid - 4, $x + 16, $cy_mid + 4, '-fill' => $theme->{breakpoint}, '-outline' => '');
        }
        elsif ($has_pc) {
            $c->createText($x + 8, $ry + 2, '-text' => '>', '-fill' => $theme->{mode_command}, '-font' => $font, '-anchor' => 'nw');
        }
        elsif (defined $sign_txt) {
            $c->createText($x + 8, $ry + 2, '-text' => $sign_txt, '-fill' => _extmark_color($theme, $sign_hl), '-font' => $font, '-anchor' => 'nw');
        }

        # Line number
        my $num_val = ($rel_num && $line_no != $cur_line) ? abs($line_no - $cur_line) : ($line_no + 1);
        my $lnum_s  = sprintf('%*d', $digits, $num_val);
        $c->createText(
            $x + 22, $ry + 2,
            '-text'   => $lnum_s,
            '-fill'   => ($is_active && $line_no == $cur_line) ? $theme->{fg} : $theme->{fg_gutter},
            '-font'   => $font,
            '-anchor' => 'nw',
        );

        # Git / Diff add vertical gutter bar
        if ($git_hl) {
            $self->_rect($x + $gutter_w - 4, $ry + 1, $x + $gutter_w - 1, $ry2 - 1, _extmark_color($theme, $git_hl), '');
        }
        elsif (($line_bg_hl // '') eq 'DiffAdd') {
            $self->_rect($x + $gutter_w - 4, $ry + 1, $x + $gutter_w - 1, $ry2 - 1, $theme->{diff_add_fg}, '');
        }

        # Visual selection highlight
        my $tlen = length($text);
        if ($vis && $line_no >= $vis->{start_line} && $line_no <= $vis->{end_line}) {
            my ($vs0, $vs1);
            if ($vis->{mode} eq 'VLINE') {
                ($vs0, $vs1) = ($left_col, $left_col + $vis_cols);
            }
            elsif ($vis->{mode} eq 'VBLOCK') {
                ($vs0, $vs1) = ($vis->{start_col}, $vis->{end_col} + 1);
            }
            else {
                $vs0 = ($line_no == $vis->{start_line}) ? $vis->{start_col} : 0;
                $vs1 = ($line_no == $vis->{end_line})   ? ($vis->{end_col} + 1) : ($tlen + 1);
            }
            $vs0 = $left_col if $vs0 < $left_col;
            $vs1 = $left_col + $vis_cols if $vs1 > $left_col + $vis_cols;
            if ($vs1 > $vs0) {
                $self->_rect(
                    $text_x0 + ($vs0 - $left_col) * $char_w, $ry,
                    $text_x0 + ($vs1 - $left_col) * $char_w, $ry2,
                    $theme->{bg_visual}, '',
                );
            }
        }

        # Syntax-highlighted text spans (filling normal-text gaps and coalescing same-color runs)
        my $row_spans = $spans->[$i] || [];
        my $max_col   = $left_col + $vis_cols;
        if ($tlen > $left_col) {
            my $vis_end = $tlen < $max_col ? $tlen : $max_col;
            my $clean_line = substr($text, $left_col, $vis_end - $left_col);
            $clean_line =~ tr/\t\r/  /;
            if (@$row_spans) {
                my $syn_map  = $theme->{syntax};
                my $fg_def   = $theme->{fg};
                my $run_c0   = -1;
                my $run_c1   = -1;
                my $run_col  = '';
                my $cursor_c = $left_col;

                my $emit_seg = sub {
                    my ($c0, $c1, $col) = @_;
                    return if $c1 <= $c0;
                    if ($run_c0 >= 0 && $col eq $run_col && $c0 == $run_c1) {
                        $run_c1 = $c1;
                        return;
                    }
                    if ($run_c0 >= 0) {
                        my $seg = substr($clean_line, $run_c0 - $left_col, $run_c1 - $run_c0);
                        $c->createText(
                            $self->_snap_px($text_x0 + ($run_c0 - $left_col) * $char_w), _snap($ry + 2),
                            '-text'   => $seg,
                            '-fill'   => $run_col,
                            '-font'   => $font,
                            '-anchor' => 'nw',
                        ) if $seg =~ /\S/;
                    }
                    ($run_c0, $run_c1, $run_col) = ($c0, $c1, $col);
                };

                for my $sp (@$row_spans) {
                    my $sc = $sp->{col};
                    my $se = $sc + $sp->{len};
                    next if $se <= $left_col;
                    last if $sc >= $vis_end;

                    my $vc0 = $sc > $left_col ? $sc : $left_col;
                    $emit_seg->($cursor_c, $vc0, $fg_def) if $vc0 > $cursor_c;

                    my $vc1 = $se < $vis_end ? $se : $vis_end;
                    if ($vc1 > $vc0) {
                        my $sfg = $syn_map->{ $sp->{group} } // $fg_def;
                        $emit_seg->($vc0, $vc1, $sfg);
                        $cursor_c = $vc1 if $vc1 > $cursor_c;
                    }
                }
                $emit_seg->($cursor_c, $vis_end, $fg_def) if $cursor_c < $vis_end;
                if ($run_c0 >= 0) {
                    my $seg = substr($clean_line, $run_c0 - $left_col, $run_c1 - $run_c0);
                    $c->createText(
                        $self->_snap_px($text_x0 + ($run_c0 - $left_col) * $char_w), _snap($ry + 2),
                        '-text'   => $seg,
                        '-fill'   => $run_col,
                        '-font'   => $font,
                        '-anchor' => 'nw',
                    ) if $seg =~ /\S/;
                }
            }
            else {
                $c->createText(_snap($text_x0), _snap($ry + 2), '-text' => $clean_line, '-fill' => $theme->{fg}, '-font' => $font, '-anchor' => 'nw')
                    if $clean_line =~ /\S/;
            }
        }

        # Track end pixel of line text for ghost/EOL virtual text
        my $after_px = _snap($text_x0 + (($tlen > $left_col ? ($tlen - $left_col) : 0) * $char_w));
        my $pane_right = _snap($x + $w - 8);

        # Antigravity inline ghost text
        for my $em (@inline_virts) {
            my $gx = _snap($text_x0 + (($em->{col} // $tlen) - $left_col) * $char_w);
            $gx = $after_px if $gx < $after_px;
            my $rem_c = int(($pane_right - $gx) / $char_w);
            if ($rem_c > 2) {
                my $gstr = _clip_chars($em->{virt_text}, $rem_c);
                $c->createText($gx, _snap($ry + 2), '-text' => $gstr, '-fill' => $theme->{ghost_text}, '-font' => $font, '-anchor' => 'nw');
                $after_px = _snap($gx + length($gstr) * $char_w);
            }
        }

        # Inline EOL virtual text (LSP/Critic diag, Cachegrind heat metric, diff hunk hint)
        for my $em (@eol_virts) {
            my $vx = _snap($after_px + 10);
            my $rem_c = int(($pane_right - $vx) / $scharw);
            last if $rem_c < 4;
            my $vstr = _clip_chars($em->{virt_text}, $rem_c);
            my $vfg  = _extmark_color($theme, $em->{virt_hl});
            $c->createText($vx, _snap($ry + 3), '-text' => $vstr, '-fill' => $vfg, '-font' => $sfont, '-anchor' => 'nw');
            $after_px = _snap($vx + length($vstr) * $scharw);
        }

        # Mode-shaped Cursor (active split only)
        if ($is_active && $line_no == $cur_line) {
            my $cx = $self->_snap_px($text_x0 + ($cur_col - $left_col) * $char_w);
            if ($cx >= $text_x0 - 2 && $cx + $char_w <= $x + $w) {
                if ($mode eq 'INSERT') {
                    $self->_rect($cx, $ry + 1, $cx + 2, $ry2 - 1, $theme->{mode_insert}, '');
                }
                elsif ($mode eq 'REPLACE') {
                    $self->_rect($cx, $ry2 - 3, $cx + $char_w, $ry2 - 1, $theme->{mode_replace}, '');
                }
                else {
                    $self->_rect($cx, $ry + 1, $cx + $char_w, $ry2 - 1, $theme->{cursor}, '');
                    my $ch_under = ($cur_col < $tlen) ? substr($text, $cur_col, 1) : ' ';
                    if ($ch_under ne ' ' && $ch_under ne "\t") {
                        $c->createText($cx, _snap($ry + 2), '-text' => $ch_under, '-fill' => $theme->{cursor_fg}, '-font' => $font, '-anchor' => 'nw');
                    }
                }
            }
        }

        $srow++;

        # Virtual lines BELOW
        for my $em (@$ems) {
            next if $em->{virt_lines_above} || ref($em->{virt_lines}) ne 'ARRAY';
            my $vhl = ref($em->{virt_lines_hl}) eq 'ARRAY' ? $em->{virt_lines_hl}[0] : ($em->{virt_lines_hl} // 'Comment');
            my $vfg = _extmark_color($theme, $vhl);
            for my $vl (@{ $em->{virt_lines} }) {
                last if $srow >= $vis_rows;
                my $vry = $cy + 4 + $srow * $line_h;
                $c->createText(_snap($text_x0), _snap($vry + 2), '-text' => _clip_chars($vl, $vis_cols), '-fill' => $vfg, '-font' => $sfont, '-anchor' => 'nw');
                $srow++;
            }
        }
    }
    return;
}

# ---------------------------------------------------------------------------
# 3b. Live Embedded Neovim Viewport (ext_linegrid over Msgpack-RPC)
# ---------------------------------------------------------------------------

sub _draw_nvim_viewport {
    my ($self, $ed, $theme, $r, $nb) = @_;
    my $c = $self->{canvas};
    my ($x, $y, $w, $h) = (_snap($r->{x}), _snap($r->{y}), _snap($r->{w}), _snap($r->{h}));
    return if $w < 60 || $h < 40;

    $self->_rect($x, $y, $x + $w, $y + $h, $theme->{bg}, '');

    my $char_w = $self->{char_w} || 7.0;
    my $line_h = $self->{line_h} || 18;
    my $font   = $self->{mono_font};

    my $pad_x = 6;
    my $pad_y = 4;
    my $cols  = int(($w - $pad_x * 2) / $char_w);
    my $rows  = int(($h - $pad_y * 2) / $line_h);
    $cols = 20 if $cols < 20;
    $rows = 6  if $rows < 6;

    if ($nb->cols != $cols || $nb->rows != $rows) {
        eval { $nb->resize($cols, $rows) };
    }
    eval { $nb->pump(0) };

    my $g = $nb->grid(1) or return;
    my $grows = $g->{rows} || [];
    my $max_r = ($rows < $g->{height}) ? $rows : $g->{height};
    my $max_c = ($cols < $g->{width})  ? $cols : $g->{width};
    my $x0    = $x + $pad_x;
    my $y0    = $y + $pad_y;

    for my $ri (0 .. $max_r - 1) {
        my $grow = $grows->[$ri] or next;
        my $ry   = _snap($y0 + $ri * $line_h);

        my $run_c0   = -1;
        my $run_c1   = -1;
        my $run_hl   = -1;
        my $run_txt  = '';

        my $flush_run = sub {
            return if $run_c0 < 0 || $run_c1 <= $run_c0;
            my ($fg, $bg, $ha) = $nb->resolve_hl($run_hl, $theme);
            my $rx0 = $self->_snap_px($x0 + $run_c0 * $char_w);
            my $rx1 = $self->_snap_px($x0 + $run_c1 * $char_w);
            if (defined($bg) && lc($bg) ne lc($theme->{bg})) {
                $self->_rect($rx0, $ry, $rx1, $ry + $line_h, $bg, '');
            }
            if ($run_txt =~ /\S/) {
                $c->createText(
                    $rx0, _snap($ry + 2),
                    '-text'   => $run_txt,
                    '-fill'   => $fg,
                    '-font'   => $font,
                    '-anchor' => 'nw',
                );
            }
            if ($ha->{underline}) {
                $self->_hline($rx0, $ry + $line_h - 2, $rx1 - $rx0, $ha->{sp} || $fg);
            }
            if ($ha->{strikethrough}) {
                $self->_hline($rx0, $ry + int($line_h / 2), $rx1 - $rx0, $fg);
            }
            $run_c0  = -1;
            $run_c1  = -1;
            $run_hl  = -1;
            $run_txt = '';
        };

        for my $ci (0 .. $max_c - 1) {
            my $cell = $grow->[$ci] or next;
            my $ch   = defined($cell->[0]) ? $cell->[0] : ' ';
            my $hl   = $cell->[1] || 0;

            # Double-width continuation cell: flush current run and advance column
            if ($ch eq '') {
                $flush_run->();
                next;
            }
            $ch = ' ' if ord($ch) < 32;

            if ($run_c0 >= 0 && $hl == $run_hl && $ci == $run_c1) {
                $run_txt .= $ch;
                $run_c1 = $ci + 1;
            }
            else {
                $flush_run->();
                $run_c0  = $ci;
                $run_c1  = $ci + 1;
                $run_hl  = $hl;
                $run_txt = $ch;
            }
        }
        $flush_run->();
    }

    # Mode-shaped cursor from live grid_cursor_goto
    my ($crow, $ccol) = $nb->cursor();
    if ($crow >= 0 && $crow < $max_r && $ccol >= 0 && $ccol < $max_c) {
        my $cx    = $self->_snap_px($x0 + $ccol * $char_w);
        my $ry    = _snap($y0 + $crow * $line_h);
        my $ry2   = $ry + $line_h;
        my $shape = $nb->cursor_shape();
        if ($shape eq 'bar') {
            $self->_rect($cx, $ry + 1, $cx + 2, $ry2 - 1, $theme->{mode_insert}, '');
        }
        elsif ($shape eq 'underline') {
            $self->_rect($cx, $ry2 - 3, $cx + $char_w, $ry2 - 1, $theme->{mode_replace}, '');
        }
        else {
            $self->_rect($cx, $ry + 1, $cx + $char_w, $ry2 - 1, $theme->{cursor}, '');
            my $under = ($grows->[$crow] && $grows->[$crow][$ccol]) ? ($grows->[$crow][$ccol][0] // ' ') : ' ';
            if (length($under) && $under ne ' ' && $under ne "\t") {
                $c->createText(
                    $cx, _snap($ry + 2),
                    '-text'   => $under,
                    '-fill'   => $theme->{cursor_fg},
                    '-font'   => $font,
                    '-anchor' => 'nw',
                );
            }
        }
    }
    return;
}

# ---------------------------------------------------------------------------
# 4. Docked 4-Tab Command Center (CHAT | MEMORY | MODELS | XSDEV)
# ---------------------------------------------------------------------------

sub _draw_command_center {
    my ($self, $ed, $theme, $r) = @_;
    my $c = $self->{canvas};
    my ($x, $y, $w, $h) = ($r->{x}, $r->{y}, $r->{w}, $r->{h});
    return if $w < 140 || $h < 80;

    $self->_rect($x, $y, $x + $w, $y + $h, $theme->{bg_sidebar}, '');
    $self->_vline($x, $y, $h, $theme->{border});
    $self->_hline($x, $y, $w, $theme->{border});

    # 4-Tab Bar (height 28px)
    my $tab_h = 28;
    $self->_rect($x + 1, $y + 1, $x + $w, $y + $tab_h, $theme->{bg_dark}, '');
    $self->_hline($x + 1, $y + $tab_h, $w - 1, $theme->{border});

    my $active_tab = $ed->layout->command_center_tab || 'chat';
    my @tabs = (
        [ 'chat',   'CHAT'   ],
        [ 'memory', 'MEMORY' ],
        [ 'jobs',   'MODELS' ],
        [ 'xsdev',  'XSDEV'  ],
    );
    my $tw = int(($w - 2) / 4);
    for my $i (0 .. $#tabs) {
        my ($key, $lbl) = @{ $tabs[$i] };
        my $tx0 = $x + 1 + $i * $tw;
        my $tx1 = ($i == $#tabs) ? ($x + $w) : ($tx0 + $tw);
        my $sel = ($key eq $active_tab);

        if ($sel) {
            $self->_rect($tx0, $y + 1, $tx1, $y + $tab_h, $theme->{bg_sidebar}, '');
            $self->_rect($tx0 + 4, $y + $tab_h - 2, $tx1 - 4, $y + $tab_h, $theme->{accent}, '');
        }
        $c->createText(
            int(($tx0 + $tx1) / 2), $y + 14,
            '-text'   => $lbl,
            '-fill'   => $sel ? $theme->{accent} : $theme->{fg_dim},
            '-font'   => $self->{ui_small_font},
            '-anchor' => 'center',
        );
        my $tab_key = $key;
        $self->_add_hit($tx0, $y, $tx1, $y + $tab_h, sub { $ed->layout->open_command_center($tab_key) });
    }

    my $bx = $x + 10;
    my $by = $y + $tab_h + 8;
    my $bw = $w - 20;
    my $bh = $h - $tab_h - 14;
    return if $bw < 80 || $bh < 40;

    my $data = $ed->get_command_center_data($active_tab) || {};
    if ($active_tab eq 'chat') {
        $self->_draw_cc_chat($ed, $theme, $bx, $by, $bw, $bh, $data);
    }
    elsif ($active_tab eq 'memory') {
        $self->_draw_cc_memory($ed, $theme, $bx, $by, $bw, $bh, $data);
    }
    elsif ($active_tab eq 'jobs') {
        $self->_draw_cc_models($ed, $theme, $bx, $by, $bw, $bh, $data);
    }
    else {
        $self->_draw_cc_xsdev($ed, $theme, $bx, $by, $bw, $bh, $data);
    }
    return;
}

sub _draw_cc_chat {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $c   = $self->{canvas};
    my $mod = $ed->plugin('modalities') || $ed->{modalities};
    my $st  = (%$data) ? $data : ($mod ? eval { $mod->chat_state } : {}) || {};
    my $sf  = $self->{ui_small_font};
    my $scw = $self->{ui_small_char_w};
    my $mc  = int(($w - 18) / $scw);
    $mc = 16 if $mc < 16;

    my $cy = $y;

    # Top status pills
    my $pill_spec = $self->_agy_pill_spec($ed, $theme);
    my $px = $x;
    $px += $self->_pill($px, $cy, 19, $pill_spec->[0],
        $pill_spec->[1], $theme->{bg_dark}, $sf, $scw, $pill_spec->[3]) + 6;
    $px += $self->_pill($px, $cy, 19, sprintf('MCP: %d tools', $st->{mcp_tools} || 0),
        $theme->{diag_info}, $theme->{bg_dark}, $sf, $scw, $theme->{border}) + 6;
    $self->_pill($px, $cy, 19, 'AutoCtx: ' . ($st->{auto_context} ? 'ON' : 'OFF'),
        $st->{auto_context} ? $theme->{accent2} : $theme->{fg_dim}, $theme->{bg_dark}, $sf, $scw, $theme->{border});
    $cy += 24;

    # Active model banner when a model is selected
    if (defined $st->{current_model} && length $st->{current_model}) {
        my $mlbl = _clip_chars("Model: $st->{current_model}  [:AgyModel]", $mc);
        $c->createText($x + 2, $cy + 1, '-text' => $mlbl, '-fill' => $theme->{accent2}, '-font' => $sf, '-anchor' => 'nw');
        $self->_add_hit($x, $cy, $x + $w, $cy + 16, sub { $mod->agy_model() if $mod && $mod->can('agy_model') });
        $cy += 18;
    }

    # Reserve space at bottom for Prompt Box (36px) and optional Permission Bar (62px)
    my $perm     = $st->{pending_perm};
    my $prompt_h = 34;
    my $perm_h   = $perm ? 62 : 0;
    my $feed_max = $y + $h - $prompt_h - $perm_h - ($perm ? 10 : 6);

    # Two-line status banner for auth_required / offline / connecting / error
    my $acp_state = $st->{acp_state} // ($st->{acp_connected} ? 'ready' : 'offline');
    if ($acp_state ne 'ready' && $cy + 44 < $feed_max) {
        my ($hdr_txt, $sub_txt, $bcol, $on_click);
        if ($acp_state eq 'auth_required') {
            $hdr_txt  = 'Antigravity sign-in required (AGY:LOGIN)';
            $sub_txt  = 'Run :AgyLogin or <leader>aL to sign in';
            $bcol     = $theme->{diag_warn};
            $on_click = sub { $mod->agy_login() if $mod && $mod->can('agy_login') };
        }
        elsif ($acp_state eq 'connecting') {
            $hdr_txt = 'Connecting to agy acp... (AGY:SYNC)';
            $sub_txt = 'Attaching EditorMCP & workspace in background';
            $bcol    = $theme->{mode_command};
        }
        elsif ($acp_state eq 'error') {
            my $err = $st->{acp_error} || ($st->{acp_stderr_tail} && @{ $st->{acp_stderr_tail} } ? $st->{acp_stderr_tail}[-1] : 'ACP exited');
            $hdr_txt  = "ACP Error: $err";
            $sub_txt  = 'Run :AgyDoctor or :AgyReconnect';
            $bcol     = $theme->{diag_error};
            $on_click = sub { $mod->agy_reconnect() if $mod && $mod->can('agy_reconnect') };
        }
        else {
            $hdr_txt  = 'Antigravity offline (' . $pill_spec->[0] . ')';
            $sub_txt  = 'Run :AgyInstall or npl --agy-mock';
            $bcol     = $theme->{diag_info};
            $on_click = sub { $mod->agy_doctor() if $mod && $mod->can('agy_doctor') };
        }
        my $ch = 40;
        $self->_rect($x, $cy, $x + $w, $cy + $ch, $theme->{bg_dark}, $bcol, 1, 6);
        $c->createText($x + 10, $cy + 5,
            '-text'   => _clip_chars($hdr_txt, $mc),
            '-fill'   => $bcol,
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $c->createText($x + 10, $cy + 21,
            '-text'   => _clip_chars($sub_txt, $mc),
            '-fill'   => $theme->{fg},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $self->_add_hit($x, $cy, $x + $w, $cy + $ch, $on_click) if $on_click;
        $cy += $ch + 6;
    }

    # Collapsible Thought Card
    if (@{ $st->{thoughts} || [] } && $cy + 30 < $feed_max) {
        my $th = $st->{thoughts}[-1];
        my $ch = 28;
        $self->_rect($x, $cy, $x + $w, $cy + $ch, $theme->{bg_dark}, $theme->{border}, 1, 6);
        $self->_rect($x + 1, $cy + 3, $x + 4, $cy + $ch - 3, $theme->{accent2}, '', undef, 2);
        $c->createText($x + 12, $cy + 7,
            '-text'   => _clip_chars('> Thought: ' . ($th->{text} // ''), $mc - 1),
            '-fill'   => $theme->{accent2},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $cy += $ch + 6;
    }

    # Tool Call Cards
    for my $tc (@{ $st->{tool_cards} || [] }) {
        last if $cy + 26 >= $feed_max;
        my $done = ($tc->{status} // '') eq 'completed';
        my $dotc = $done ? $theme->{diff_add_fg} : $theme->{mode_command};
        my $ch   = 24;
        $self->_rect($x, $cy, $x + $w, $cy + $ch, $theme->{bg_dark}, $theme->{border}, 1, 5);
        $c->createOval($x + 8, $cy + 8, $x + 15, $cy + 15, '-fill' => $dotc, '-outline' => '');
        my $st_lbl = $done ? 'done' : ($tc->{status} // 'run');
        $c->createText($x + 22, $cy + 5,
            '-text'   => _clip_chars($tc->{title} // 'tool', $mc - 9),
            '-fill'   => $theme->{fg},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $c->createText($x + $w - 8, $cy + 5,
            '-text'   => $st_lbl,
            '-fill'   => $dotc,
            '-font'   => $sf,
            '-anchor' => 'ne',
        );
        $cy += $ch + 4;
    }

    # Live Plan Checklist Card
    my $plan = $st->{plan} || [];
    if (@$plan && $cy + 42 < $feed_max) {
        my $shown = @$plan > 3 ? 3 : scalar(@$plan);
        my $ph = 22 + $shown * 16 + 4;
        if ($cy + $ph < $feed_max) {
            $self->_rect($x, $cy, $x + $w, $cy + $ph, $theme->{bg_dark}, $theme->{border}, 1, 6);
            $c->createText($x + 10, $cy + 5, '-text' => 'PLAN', '-fill' => $theme->{accent}, '-font' => $sf, '-anchor' => 'nw');
            my $py = $cy + 21;
            for my $i (0 .. $shown - 1) {
                my $pe = $plan->[$i];
                my $ps = $pe->{status} // 'pending';
                my $mk = $ps eq 'completed' ? '[x]' : $ps eq 'in_progress' ? '[~]' : '[ ]';
                my $fg = $ps eq 'completed' ? $theme->{diff_add_fg} : $ps eq 'in_progress' ? $theme->{mode_command} : $theme->{fg_dim};
                $c->createText($x + 10, $py,
                    '-text'   => _clip_chars("$mk " . ($pe->{content} // $pe->{title} // ''), $mc),
                    '-fill'   => $fg,
                    '-font'   => $sf,
                    '-anchor' => 'nw',
                );
                $py += 16;
            }
            $cy += $ph + 6;
        }
    }

    # Streaming Markdown Chat Messages
    for my $msg (@{ $st->{messages} || [] }) {
        last if $cy + 34 >= $feed_max;
        my $is_user = ($msg->{role} // '') eq 'user';
        my $wrapped = _wrap_lines($msg->{text} // '', $mc - 1, 5);
        my $rem_lines = int(($feed_max - $cy - 24) / 16);
        last if $rem_lines < 1;
        splice(@$wrapped, $rem_lines) if @$wrapped > $rem_lines;

        my $mh  = 22 + scalar(@$wrapped) * 16 + 4;
        my $mbg = $is_user ? $theme->{bg_highlight} : $theme->{bg_dark};
        $self->_rect($x, $cy, $x + $w, $cy + $mh, $mbg, $theme->{border}, 1, 6);
        $c->createText($x + 10, $cy + 5,
            '-text'   => $is_user ? 'You' : 'Antigravity',
            '-fill'   => $is_user ? $theme->{accent} : $theme->{diff_add_fg},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        my $my = $cy + 21;
        for my $wl (@$wrapped) {
            my $lfg = ($wl =~ /\A#/) ? $theme->{accent}
                    : ($wl =~ /\A```/) ? $theme->{accent2}
                    : $theme->{fg};
            $c->createText($x + 10, $my, '-text' => $wl, '-fill' => $lfg, '-font' => $sf, '-anchor' => 'nw');
            $my += 16;
        }
        $cy += $mh + 6;
    }

    # Interactive Vim-Keybound Permission Bar
    if ($perm) {
        my $py = $y + $h - $prompt_h - $perm_h - 6;
        $self->_rect($x, $py, $x + $w, $py + $perm_h, $theme->{bg_dark}, $theme->{mode_command}, 1, 6);
        my $pt = $perm->{title} || $perm->{tool} || 'Approve proposed edit?';
        $c->createText($x + 10, $py + 7,
            '-text'   => _clip_chars("Permission: $pt", $mc),
            '-fill'   => $theme->{mode_command},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        my $bx = $x + 10;
        my $by = $py + 31;
        my $w1 = $self->_pill($bx, $by, 22, '[a] Allow',  $theme->{cursor_fg}, $theme->{diff_add_fg}, $sf, $scw);
        $self->_add_hit($bx, $by, $bx + $w1, $by + 22, sub { $mod->handle_permission_key('a') if $mod });
        $bx += $w1 + 8;
        my $w2 = $self->_pill($bx, $by, 22, '[A] Always', $theme->{cursor_fg}, $theme->{accent}, $sf, $scw);
        $self->_add_hit($bx, $by, $bx + $w2, $by + 22, sub { $mod->handle_permission_key('A') if $mod });
        $bx += $w2 + 8;
        my $w3 = $self->_pill($bx, $by, 22, '[r] Reject', $theme->{cursor_fg}, $theme->{diag_error}, $sf, $scw);
        $self->_add_hit($bx, $by, $bx + $w3, $by + 22, sub { $mod->handle_permission_key('r') if $mod });
    }

    # Prompt Input Box
    my $iy     = $y + $h - $prompt_h;
    my $cinp   = $st->{chat_input} // '';
    my $active = $st->{chat_input_active} ? 1 : 0;
    my $border = $active ? $theme->{accent} : $theme->{border_focus};
    $self->_rect($x, $iy, $x + $w, $iy + $prompt_h, $theme->{bg_dark}, $border, 1, 6);
    my $shown = ($active || length $cinp)
        ? _clip_chars("> $cinp", $mc)
        : _clip_chars('> Ask Antigravity (@file, @memory, /plan)...', $mc);
    $c->createText($x + 10, $iy + 9,
        '-text'   => $shown,
        '-fill'   => ($active || length $cinp) ? $theme->{fg} : $theme->{fg_dim},
        '-font'   => $sf,
        '-anchor' => 'nw',
    );
    if ($active) {
        my $cur_x = _snap($x + 10 + length($shown) * $scw + 1);
        $self->_rect($cur_x, $iy + 8, $cur_x + 2, $iy + $prompt_h - 8, $theme->{mode_insert}, '')
            if $cur_x < $x + $w - 8;
    }
    $self->_add_hit($x, $iy, $x + $w, $iy + $prompt_h, sub {
        $mod->focus_chat_input(1) if $mod && $mod->can('focus_chat_input');
    });
    return;
}

sub _draw_cc_memory {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $c   = $self->{canvas};
    my $mem = $ed->plugin('memory') || $ed->{memory_store};
    my $sf  = $self->{ui_small_font};
    my $scw = $self->{ui_small_char_w};
    my $mf  = $self->{small_font};
    my $mc  = int(($w - 20) / $scw);
    $mc = 16 if $mc < 16;

    my $dialect = $data->{dialect} || ($mem ? eval { $mem->dialect } : 'db2') || 'db2';
    my $query   = $data->{query}   // '';
    my $items   = $data->{items}   || $data->{memories};
    if (!ref($items) && $mem) {
        $items = eval { $mem->search(query => $query, limit => 8, include_superseded => 1, update_access => 0) } || [];
    }
    $items ||= [];

    my $cy = $y;
    my $dlbl = $dialect =~ /db2/i ? 'IBM Db2 12.1.2 VECTOR' : 'Db2 SQLite+SIMD (NEON/VSX)';
    my $pw = $self->_pill($x, $cy, 20, $dlbl, $theme->{diag_info}, $theme->{bg_dark}, $sf, $scw, $theme->{border});
    $self->_pill($x + $pw + 6, $cy, 20, sprintf('%d memories', scalar(@$items)), $theme->{accent}, $theme->{bg_dark}, $sf, $scw, $theme->{border});
    $cy += 26;

    my @packs = $self->_active_mcp_packs($ed);
    if (@packs) {
        my $pk_str = 'MCP Packs (' . scalar(@packs) . '/12): ' . join(', ', @packs);
        $self->_rect($x, $cy, $x + $w, $cy + 22, $theme->{bg_highlight}, $theme->{border}, 1, 5);
        $c->createText($x + 8, $cy + 4,
            '-text'   => _clip_chars($pk_str, $mc),
            '-fill'   => $theme->{accent},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $cy += 28;
    }

    # Live Query Box
    $self->_rect($x, $cy, $x + $w, $cy + 28, $theme->{bg_dark}, $theme->{border_focus}, 1, 6);
    $c->createText($x + 10, $cy + 7,
        '-text'   => _clip_chars('Search: ' . (length($query) ? $query : 'VECTOR_DISTANCE cosine semantic query'), $mc),
        '-fill'   => length($query) ? $theme->{fg} : $theme->{fg_dim},
        '-font'   => $mf,
        '-anchor' => 'nw',
    );
    $cy += 36;

    my $max_y = $y + $h - 24;
    for my $m (@$items) {
        my $wrapped = _wrap_lines($m->{content} // '', $mc, 2);
        my $has_lin = defined($m->{superseded_by_id}) || defined($m->{supersedes_id});
        my $card_h  = 46 + scalar(@$wrapped) * 15 + ($has_lin ? 15 : 0);
        last if $cy + $card_h > $max_y;

        $self->_rect($x, $cy, $x + $w, $cy + $card_h, $theme->{bg_dark}, $theme->{border}, 1, 6);

        # Scope + Category + Pin pills
        my $scope = $m->{scope_level} // 'repo';
        my $cat   = $m->{category}    // 'fact';
        my $scol  = $scope eq 'global' ? $theme->{accent2}
                  : $scope eq 'file'   ? $theme->{diag_info}
                  : $scope eq 'symbol' ? $theme->{mode_command}
                  : $theme->{accent};
        my $px = $x + 8;
        $px += $self->_pill($px, $cy + 6, 17, $scope, $theme->{cursor_fg}, $scol, $sf, $scw) + 5;
        $px += $self->_pill($px, $cy + 6, 17, $cat, $theme->{fg}, $theme->{bg_highlight}, $sf, $scw) + 5;
        if ($m->{pinned}) {
            $self->_pill($px, $cy + 6, 17, 'PIN', $theme->{cursor_fg}, $theme->{mode_command}, $sf, $scw);
        }

        # Cosine Similarity Progress Bar
        my $raw_sim = defined($m->{cosine_score}) && $m->{cosine_score} > 0 ? $m->{cosine_score}
                    : defined($m->{score})        && $m->{score} > 0        ? $m->{score}
                    : ($m->{confidence} // 0.88);
        my $sim = $raw_sim + 0.0;
        $sim = 1.0 if $sim > 1.0;
        $sim = 0.0 if $sim < 0.0;
        my $bar_x = $x + 8;
        my $bar_y = $cy + 28;
        my $bar_w = $w - 64;
        $self->_rect($bar_x, $bar_y, $bar_x + $bar_w, $bar_y + 8, $theme->{bg_highlight}, '', undef, 4);
        my $fw = int($bar_w * $sim);
        $fw = 4 if $fw < 4 && $sim > 0;
        my $bcol = $sim >= 0.85 ? $theme->{diff_add_fg} : $sim >= 0.65 ? $theme->{accent} : $theme->{mode_command};
        $self->_rect($bar_x, $bar_y, $bar_x + $fw, $bar_y + 8, $bcol, '', undef, 4);
        $c->createText($x + $w - 8, $bar_y - 3, '-text' => sprintf('%.2f', $sim), '-fill' => $bcol, '-font' => $sf, '-anchor' => 'ne');

        # Content lines
        my $ty = $cy + 42;
        for my $wl (@$wrapped) {
            $c->createText($x + 8, $ty, '-text' => $wl, '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
            $ty += 15;
        }

        if ($has_lin) {
            my $ltxt = defined($m->{superseded_by_id})
                ? "Superseded by #$m->{superseded_by_id}"
                : "Supersedes #$m->{supersedes_id}";
            $c->createText($x + 8, $ty, '-text' => $ltxt, '-fill' => $theme->{diag_warn}, '-font' => $sf, '-anchor' => 'nw');
        }

        $cy += $card_h + 6;
    }

    # Footer controls
    $c->createText($x + 4, $y + $h - 18,
        '-text'   => _clip_chars('[p] Pin  [x] Forget  [:MemSave]  [:MemSearch]', $mc + 2),
        '-fill'   => $theme->{fg_dim},
        '-font'   => $sf,
        '-anchor' => 'nw',
    );
    return;
}

sub _draw_cc_models {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $c   = $self->{canvas};
    my $inf = $ed->plugin('inference')     || $ed->{inference};
    my $oq  = $ed->plugin('offload_queue') || $ed->{offload_queue};
    my $vis = $ed->plugin('vision')        || $ed->{vision};
    my $sf  = $self->{small_font};
    my $scw = $self->{small_char_w};
    my $mc  = int(($w - 20) / $scw);
    $mc = 16 if $mc < 16;

    my $tel   = $data->{telemetry}   || ($inf ? eval { $inf->telemetry }    : {}) || {};
    my $jobs  = $data->{jobs}        || ($oq  ? eval { $oq->list_jobs }     : []) || [];
    my $vdocs = $data->{vision_docs} || $data->{recent_docs} || ($vis ? eval { $vis->recent_docs }  : []) || [];

    my $cy    = $y;
    my $max_y = $y + $h - 4;

    # RAM Residency Meter + Cloud Tokens Saved Card
    my $used   = $tel->{resident_gb}   || 0;
    my $budget = $tel->{ram_budget_gb} || 20;
    my $ratio  = $budget > 0 ? ($used / $budget) : 0;
    $ratio = 1.0 if $ratio > 1.0;
    my $saved  = $tel->{estimated_cloud_tokens_saved} || 0;

    $self->_rect($x, $cy, $x + $w, $cy + 58, $theme->{bg_dark}, $theme->{border}, 1, 6);
    $c->createText($x + 10, $cy + 7,
        '-text'   => sprintf('RAM Residency: %.1f / %.0f GB', $used, $budget),
        '-fill'   => $theme->{fg},
        '-font'   => $self->{ui_small_font},
        '-anchor' => 'nw',
    );
    $self->_pill($x + $w - 152, $cy + 4, 19, 'Saved: ' . _fmt_tokens($saved) . ' tok',
        $theme->{cursor_fg}, $theme->{diff_add_fg}, $self->{ui_small_font}, $self->{ui_small_char_w});

    my $bar_x = $x + 10;
    my $bar_y = $cy + 34;
    my $bar_w = $w - 20;
    $self->_rect($bar_x, $bar_y, $bar_x + $bar_w, $bar_y + 12, $theme->{bg_highlight}, '', undef, 5);
    my $fw = int($bar_w * $ratio);
    $fw = 6 if $fw < 6 && $ratio > 0;
    my $rcol = $ratio > 0.85 ? $theme->{diag_error} : $ratio > 0.65 ? $theme->{mode_command} : $theme->{accent};
    $self->_rect($bar_x, $bar_y, $bar_x + $fw, $bar_y + 12, $rcol, '', undef, 5);
    $cy += 66;

    # 4 Specialist Model Slots
    $c->createText($x + 2, $cy, '-text' => 'LOCAL MODEL SLOTS (llama.cpp)', '-fill' => $theme->{accent}, '-font' => $self->{ui_small_font}, '-anchor' => 'nw');
    $cy += 18;
    for my $s (@{ $tel->{slots} || [] }) {
        last if $cy + 34 > $max_y;
        my $loaded = $s->{loaded} ? 1 : 0;
        my $dotc   = ($s->{transport} // '') eq 'remote_http' ? $theme->{diag_info}
                   : $loaded                                  ? $theme->{diff_add_fg}
                   : $theme->{fg_gutter};
        $self->_rect($x, $cy, $x + $w, $cy + 32, $theme->{bg_dark}, $theme->{border}, 1, 5);
        $c->createOval($x + 8, $cy + 12, $x + 15, $cy + 19, '-fill' => $dotc, '-outline' => '');
        $c->createText($x + 22, $cy + 4,
            '-text'   => _clip_chars($s->{display_name} || $s->{role}, $mc - 12),
            '-fill'   => $loaded ? $theme->{fg} : $theme->{fg_dim},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        my $sub_line = sprintf('%s | %s%s', $s->{backend_fork} || 'upstream', $s->{transport} || 'loopback', $s->{pinned} ? ' | PIN' : '');
        $c->createText($x + 22, $cy + 17,
            '-text'   => _clip_chars($sub_line, $mc - 12),
            '-fill'   => $theme->{fg_dim},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $c->createText($x + $w - 8, $cy + 9,
            '-text'   => sprintf('%.1fG', $s->{ram_gb} || 0),
            '-fill'   => $loaded ? $theme->{accent2} : $theme->{fg_dim},
            '-font'   => $sf,
            '-anchor' => 'ne',
        );
        $cy += 36;
    }

    # Live Out-of-Band Bonsai Job Queue
    if ($cy + 24 < $max_y) {
        $cy += 4;
        $c->createText($x + 2, $cy,
            '-text'   => sprintf('BONSAI OFFLOAD QUEUE (%d)', scalar(@$jobs)),
            '-fill'   => $theme->{accent2},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $cy += 18;
        for my $j (@$jobs) {
            last if $cy + 36 > $max_y;
            $self->_rect($x, $cy, $x + $w, $cy + 34, $theme->{bg_dark}, $theme->{border}, 1, 5);
            my $syn_ok  = $j->{syntax_ok};
            my $syn_lbl = defined($syn_ok) ? ($syn_ok ? 'perl -c OK' : 'SYNTAX ERR') : 'pending';
            my $syn_col = defined($syn_ok) ? ($syn_ok ? $theme->{diff_add_fg} : $theme->{diag_error}) : $theme->{mode_command};
            my $st_col  = ($j->{status} // '') =~ /staged|applied/ ? $theme->{diff_add_fg} : $theme->{mode_command};

            my $tname = $j->{target_path} || $j->{job_id} || '';
            $tname =~ s{\A.*/}{};
            $c->createText($x + 8, $cy + 4,
                '-text'   => _clip_chars(sprintf('[%s] %s (%s)', $j->{kind} // 'doc', $tname, $j->{status} // 'queued'), $mc - 12),
                '-fill'   => $st_col,
                '-font'   => $sf,
                '-anchor' => 'nw',
            );
            $c->createText($x + $w - 8, $cy + 4,
                '-text'   => $syn_lbl,
                '-fill'   => $syn_col,
                '-font'   => $sf,
                '-anchor' => 'ne',
            );
            my $prev = $j->{diff_summary} || sprintf('+%d cloud tokens saved', $j->{cloud_tokens_saved} || 0);
            $c->createText($x + 8, $cy + 18,
                '-text'   => _clip_chars($prev, $mc),
                '-fill'   => $theme->{fg_dim},
                '-font'   => $sf,
                '-anchor' => 'nw',
            );
            $cy += 38;
        }
    }

    # Granite-Vision Doc Cache
    if ($cy + 26 < $max_y && @$vdocs) {
        $cy += 2;
        $c->createText($x + 2, $cy,
            '-text'   => sprintf('GRANITE-VISION DOC CACHE (%d)', scalar(@$vdocs)),
            '-fill'   => $theme->{diag_info},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );
        $cy += 18;
        for my $d (@$vdocs) {
            last if $cy + 18 > $max_y;
            my $dl = sprintf('%s -> %s%s', $d->{filename} // 'doc', $d->{format} // 'markdown', $d->{cached} ? ' [SHA-256 hit]' : '');
            $c->createText($x + 8, $cy, '-text' => _clip_chars($dl, $mc), '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
            $cy += 16;
        }
    }
    return;
}

sub _draw_cc_xsdev {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $c   = $self->{canvas};
    my $xs  = $ed->plugin('xsdev');
    my $st  = (%$data) ? $data : ($xs ? eval { $xs->panel_state } : {}) || {};
    my $sf  = $self->{small_font};
    my $scw = $self->{small_char_w};
    my $mc  = int(($w - 20) / $scw);
    $mc = 16 if $mc < 16;

    my $dbg = $st->{debugger}  || {};
    my $pr  = $st->{profiler}  || {};
    my $san = $st->{sanitizer} || {};
    my $pgo = $st->{pgo};

    my $cy    = $y;
    my $max_y = $y + $h - 4;

    # Top status pills (IBM Plex Sans headers/pills, IBM Plex Mono tabular metrics)
    my $usf  = $self->{ui_small_font};
    my $uscw = $self->{ui_small_char_w};
    my $be = uc($dbg->{backend} || 'STANDBY');
    my $px = $x;
    $px += $self->_pill($px, $cy, 19, "DBG: $be", $theme->{cursor_fg}, $theme->{accent}, $usf, $uscw) + 6;
    $px += $self->_pill($px, $cy, 19, 'BP: ' . scalar(@{ $dbg->{breakpoints} || [] }), $theme->{breakpoint}, $theme->{bg_dark}, $usf, $uscw, $theme->{border}) + 6;
    my $sfind = scalar(@{ $san->{findings} || [] });
    $self->_pill($px, $cy, 19, 'SAN: ' . ($sfind ? "$sfind issues" : 'clean'),
        $sfind ? $theme->{diag_error} : $theme->{diff_add_fg}, $theme->{bg_dark}, $usf, $uscw, $theme->{border});
    $cy += 26;

    # Backtrace Card
    my $bt = $dbg->{backtrace} || [];
    if (@$bt && $cy + 40 < $max_y) {
        my $n = @$bt > 3 ? 3 : scalar(@$bt);
        my $ch = 20 + $n * 15 + 4;
        $self->_rect($x, $cy, $x + $w, $cy + $ch, $theme->{bg_dark}, $theme->{border}, 1, 5);
        $c->createText($x + 8, $cy + 4, '-text' => 'BACKTRACE', '-fill' => $theme->{accent}, '-font' => $usf, '-anchor' => 'nw');
        my $fy = $cy + 20;
        for my $i (0 .. $n - 1) {
            my $f = $bt->[$i];
            my $fl = sprintf('#%s %s  %s:%s', $f->{level} // $i, $f->{func} // '?', $f->{file} // '?', $f->{line} // 0);
            $c->createText($x + 8, $fy, '-text' => _clip_chars($fl, $mc), '-fill' => ($i == 0 ? $theme->{mode_command} : $theme->{fg}), '-font' => $sf, '-anchor' => 'nw');
            $fy += 15;
        }
        $cy += $ch + 6;
    }

    # Locals + my_perl Threads + SV* Inspector
    my $locs = $dbg->{locals} || [];
    my $svs  = $dbg->{sv_inspector} || [];
    my $thrs = $dbg->{threads} || [];
    if ((@$locs || @$svs || @$thrs) && $cy + 40 < $max_y) {
        my @rows;
        for my $l (@$locs[0 .. ($#$locs > 2 ? 2 : $#$locs)]) {
            push @rows, [ sprintf('%s = %s', $l->{name} // '?', $l->{value} // ''), $theme->{fg} ];
        }
        for my $t (@$thrs[0 .. ($#$thrs > 1 ? 1 : $#$thrs)]) {
            push @rows, [ sprintf('my_perl T%s: %s', $t->{id} // '1', $t->{name} // $t->{state} // 'active'), $theme->{diag_info} ];
        }
        for my $sv (@$svs[0 .. ($#$svs > 1 ? 1 : $#$svs)]) {
            push @rows, [ sprintf('SV* %s: %s [%s] %s', $sv->{expr} // 'sv', $sv->{sv_type} // 'PVNV', $sv->{flags} // 'POK', $sv->{pv} // $sv->{iv} // ''), $theme->{diff_add_fg} ];
        }
        my $avail = int(($max_y - $cy - 26) / 15);
        splice(@rows, $avail) if @rows > $avail && $avail > 0;
        if (@rows) {
            my $ch = 20 + scalar(@rows) * 15 + 4;
            $self->_rect($x, $cy, $x + $w, $cy + $ch, $theme->{bg_dark}, $theme->{border}, 1, 5);
            $c->createText($x + 8, $cy + 4, '-text' => 'LOCALS / my_perl THREADS / SV* INSPECTOR', '-fill' => $theme->{diag_info}, '-font' => $usf, '-anchor' => 'nw');
            my $ry = $cy + 20;
            for my $row (@rows) {
                $c->createText($x + 8, $ry, '-text' => _clip_chars($row->[0], $mc), '-fill' => $row->[1], '-font' => $sf, '-anchor' => 'nw');
                $ry += 15;
            }
            $cy += $ch + 6;
        }
    }

    # IBM POWER Registers (r0-r31 / vs0-vs63)
    my $pregs = $dbg->{power_registers} || {};
    my @gprs  = sort keys %{ $pregs->{gpr} || {} };
    my @vsxs  = sort keys %{ $pregs->{vsx} || {} };
    if ((@gprs || @vsxs) && $cy + 42 < $max_y) {
        my @rlines;
        for (my $i = 0; $i < @gprs && @rlines < 2; $i += 2) {
            my $k1 = $gprs[$i];
            my $k2 = $gprs[$i + 1];
            my $s  = "$k1=$pregs->{gpr}{$k1}";
            $s    .= "  $k2=$pregs->{gpr}{$k2}" if defined $k2;
            push @rlines, [ $s, $theme->{fg_dim} ];
        }
        for my $k (@vsxs[0 .. ($#vsxs > 1 ? 1 : $#vsxs)]) {
            push @rlines, [ "$k = $pregs->{vsx}{$k}", $theme->{accent2} ];
        }
        my $ch = 20 + scalar(@rlines) * 15 + 4;
        if ($cy + $ch < $max_y) {
            $self->_rect($x, $cy, $x + $w, $cy + $ch, $theme->{bg_dark}, $theme->{border}, 1, 5);
            $c->createText($x + 8, $cy + 4, '-text' => 'POWER REGISTERS (r0-r31 / vs0-vs63)', '-fill' => $theme->{accent2}, '-font' => $usf, '-anchor' => 'nw');
            my $ry = $cy + 20;
            for my $rl (@rlines) {
                $c->createText($x + 8, $ry, '-text' => _clip_chars($rl->[0], $mc), '-fill' => $rl->[1], '-font' => $sf, '-anchor' => 'nw');
                $ry += 15;
            }
            $cy += $ch + 6;
        }
    }

    # Cachegrind Hotspots Table with Heatbars
    my $hs = $pr->{hotspots} || [];
    if (@$hs && $cy + 44 < $max_y) {
        my $n  = @$hs > 4 ? 4 : scalar(@$hs);
        my $ch = 22 + $n * 17 + 4;
        if ($cy + $ch <= $max_y) {
            $self->_rect($x, $cy, $x + $w, $cy + $ch, $theme->{bg_dark}, $theme->{border}, 1, 5);
            $c->createText($x + 8, $cy + 4, '-text' => 'CACHEGRIND / PMU HOTSPOTS', '-fill' => $theme->{heat_hot}, '-font' => $usf, '-anchor' => 'nw');
            my $hy = $cy + 22;
            for my $i (0 .. $n - 1) {
                my $row = $hs->[$i];
                my $pct = $row->{ir_pct} || 0;
                my $hcol = $pct >= 10 ? $theme->{heat_crit} : $pct >= 3 ? $theme->{heat_hot} : $theme->{heat_warm};
                my $bw = int(($pct > 100 ? 100 : $pct) * 0.56);
                $bw = 4 if $bw < 4;
                $self->_rect($x + 8, $hy + 3, $x + 8 + $bw, $hy + 11, $hcol, '', undef, 2);
                my $lbl = sprintf('%5.1f%% Ir  %s:%d', $pct, $row->{func} || $row->{file} || '?', $row->{line} || 0);
                $c->createText($x + 70, $hy, '-text' => _clip_chars($lbl, $mc - 10), '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
                $hy += 17;
            }
            $cy += $ch + 6;
        }
    }

    # PGO Speedup Summary Card
    if (ref($pgo) eq 'HASH' && $pgo->{ok} && $cy + 34 <= $max_y) {
        $self->_rect($x, $cy, $x + $w, $cy + 32, $theme->{bg_dark}, $theme->{diff_add_fg}, 1, 5);
        my $pl = sprintf('PGO (%s): %.2fms -> %.2fms  (+%.1f%% speedup)',
            $pgo->{family} || 'clang', $pgo->{baseline_ms} || 0, $pgo->{pgo_ms} || 0, $pgo->{speedup_pct} || 0);
        $c->createText($x + 10, $cy + 9, '-text' => _clip_chars($pl, $mc), '-fill' => $theme->{diff_add_fg}, '-font' => $sf, '-anchor' => 'nw');
    }
    return;
}

# ---------------------------------------------------------------------------
# 5. Bottom Powerline Statusline & Command Bar
# ---------------------------------------------------------------------------

sub _draw_statusline {
    my ($self, $ed, $theme, $r) = @_;
    my $c = $self->{canvas};
    my ($x, $y, $w, $h) = ($r->{x}, $r->{y}, $r->{w}, $r->{h});

    $self->_rect($x, $y, $x + $w, $y + $h, $theme->{bg_statusline}, '');
    $self->_hline($x, $y, $w, $theme->{border});

    my $sf   = $self->{small_font};
    my $scw  = $self->{small_char_w};
    my $nb   = ($ed->can('nvim_bridge') && $ed->nvim_bridge && eval { $ed->nvim_bridge->is_connected })
             ? $ed->nvim_bridge : undef;
    my $mode = $nb ? $nb->display_mode() : ($ed->modal->mode || 'NORMAL');
    my $mcol = $mode eq 'INSERT'               ? $theme->{mode_insert}
             : $mode =~ /\AV/                  ? $theme->{mode_visual}
             : $mode eq 'REPLACE'              ? $theme->{mode_replace}
             : $mode =~ /\A(?:COMMAND|SEARCH)/ ? $theme->{mode_command}
             : $mode eq 'TERMINAL'             ? $theme->{mode_terminal}
             : $theme->{mode_normal};

    my $cx = $x + 6;
    $cx += $self->_pill($cx, $y + 3, 18, $mode, $theme->{cursor_fg}, $mcol, $sf, $scw) + 8;

    if ($nb) {
        $cx += $self->_pill($cx, $y + 3, 18, 'NVIM ' . $nb->version_string, $theme->{accent}, $theme->{bg_highlight}, $sf, $scw, $theme->{border_focus}) + 8;
    }

    my $segs = $ed->get_statusline_segments || {};
    if (ref($segs->{git}) eq 'HASH' && length($segs->{git}{branch} // '')) {
        $cx += $self->_pill($cx, $y + 3, 18, 'git:' . $segs->{git}{branch}, $theme->{accent2}, $theme->{bg_highlight}, $sf, $scw) + 8;
    }

    my $buf = $ed->current_buffer;
    if ($nb) {
        my $nname = eval { $nb->buf_get_name(0) } || '[No Name]';
        $nname =~ s{\A.*/}{};
        my $fn = _clip_chars($nname, 28);
        $c->createText(_snap($cx), _snap($y + 5), '-text' => $fn, '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
        $cx += _snap(length($fn) * $scw) + 12;
    }
    elsif ($buf) {
        my $fn = _clip_chars($buf->name . ($buf->modified ? ' [+]' : ''), 28);
        $c->createText(_snap($cx), _snap($y + 5), '-text' => $fn, '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
        $cx += _snap(length($fn) * $scw) + 12;
    }

    my $dc = $ed->diagnostic_counts;
    if ($dc && $dc->{total}) {
        my $dt = sprintf('E:%d W:%d', $dc->{error}, $dc->{warn});
        $cx += $self->_pill($cx, $y + 3, 18, $dt, $dc->{error} ? $theme->{diag_error} : $theme->{diag_warn}, $theme->{bg_dark}, $sf, $scw) + 8;
    }

    if (defined $segs->{perldev} && length $segs->{perldev}) {
        $cx += $self->_pill($cx, $y + 3, 18, $segs->{perldev}, $theme->{diag_info}, $theme->{bg_dark}, $sf, $scw) + 8;
    }

    # Right segments: Cloud Tokens Saved | Ln:Col | Backend/FPS
    my @right;
    my $inf = $ed->plugin('inference') || $ed->{inference};
    if ($inf) {
        my $tel   = eval { $inf->telemetry } || {};
        my $saved = $tel->{estimated_cloud_tokens_saved} || 0;
        push @right, [ 'Saved: ' . _fmt_tokens($saved) . ' tok', $theme->{diff_add_fg}, $theme->{bg_highlight} ];
    }
    my ($ln, $cc);
    if ($nb) {
        my $bc = $nb->buf_cursor();
        ($ln, $cc) = (int($bc->[0] || 1), int($bc->[1] || 0) + 1);
    }
    else {
        my $win = $ed->current_window;
        ($ln, $cc) = $win ? ($win->cursor_line + 1, $win->cursor_col + 1) : (1, 1);
    }
    push @right, [ sprintf('Ln %d, Col %d', $ln, $cc), $theme->{fg}, $theme->{bg_highlight} ];
    my $sc_tag = ($self->scale > 1.01) ? sprintf(' %.0fx', $self->scale) : '';
    my $be_lbl = ucfirst($self->backend_name) . $sc_tag . sprintf(' %.0f FPS', $self->{fps} > 999 ? 999 : $self->{fps});
    push @right, [ $be_lbl, $theme->{cursor_fg}, $mcol ];

    my $rw = 8;
    for my $seg (@right) {
        $rw += int(length($seg->[0]) * $scw + 0.5) + 18 + 6;
    }
    my $rx = $x + $w - $rw;
    if ($rx > $cx) {
        for my $seg (@right) {
            my $pw = $self->_pill($rx, $y + 3, 18, $seg->[0], $seg->[1], $seg->[2], $sf, $scw);
            $rx += $pw + 6;
        }
    }
    return;
}

sub _draw_cmdline {
    my ($self, $ed, $theme, $r) = @_;
    my $c = $self->{canvas};
    my ($x, $y, $w, $h) = ($r->{x}, $r->{y}, $r->{w}, $r->{h});

    $self->_rect($x, $y, $x + $w, $y + $h, $theme->{bg_dark}, '');
    my $modal = $ed->modal;
    my $mode  = $modal->mode;
    my $maxc  = int(($w - 24) / ($self->{small_char_w} || 6.6));

    if ($mode eq 'COMMAND' || $mode eq 'SEARCH_FWD' || $mode eq 'SEARCH_BWD') {
        my $prompt = $modal->cmdline_prompt // ':';
        my $text   = $modal->cmdline // '';
        $c->createText($x + 10, $y + 5,
            '-text'   => _clip_chars($prompt . $text, $maxc),
            '-fill'   => $theme->{fg},
            '-font'   => $self->{mono_font},
            '-anchor' => 'nw',
        );
        my $cx = _snap($x + 10 + (1 + ($modal->cmdline_pos || length($text))) * $self->{char_w});
        $self->_rect($cx, $y + 4, $cx + 2, $y + $h - 4, $theme->{mode_command}, '');
    }
    else {
        my $msg = $ed->status_message || {};
        my $fg  = ($msg->{level} // '') eq 'error' ? $theme->{diag_error}
                : ($msg->{level} // '') eq 'warn'  ? $theme->{diag_warn}
                : $theme->{fg_dim};
        my $txt = $msg->{text} // '';
        $c->createText($x + 10, $y + 5,
            '-text'   => _clip_chars($txt, $maxc),
            '-fill'   => $fg,
            '-font'   => $self->{small_font},
            '-anchor' => 'nw',
        ) if length $txt;
    }
    return;
}

# ---------------------------------------------------------------------------
# 6. Z-Ordered Rounded Floating Windows with Drop Shadows
# ---------------------------------------------------------------------------

sub _draw_float {
    my ($self, $ed, $theme, $frect, $px) = @_;
    my $c    = $self->{canvas};
    my $fw   = $frect->{window};
    my $kind = $frect->{kind} || 'generic';
    my $meta = ($fw && ref($fw->meta) eq 'HASH') ? $fw->meta : {};

    my ($W, $H) = ($self->{width}, $self->{height});
    my ($fx, $fy, $fw_px, $fh_px);

    if ($kind eq 'telescope') {
        $fw_px = int($W * 0.64);
        $fh_px = int($H * 0.48);
        $fw_px = 620 if $fw_px < 620 && $W >= 680;
        $fh_px = 310 if $fh_px < 310 && $H >= 420;
        # Position cleanly over lower half of editor area so gutter heatbars & code above remain legible
        my $avail_w = $px->{command_center} ? $px->{editor_area}{w} : $W;
        if ($avail_w >= 620) {
            $fw_px = int($avail_w * 0.92) if $fw_px > int($avail_w * 0.92);
            $fx    = $px->{editor_area}{x} + int(($avail_w - $fw_px) / 2);
        }
        else {
            $fx = int(($W - $fw_px) / 2);
        }
        $fy = $px->{command_center}
            ? ($H - $fh_px - 68)
            : int(($H - $fh_px) / 2);
    }
    elsif ($kind eq 'inline_prompt' || $kind eq 'agy_inline') {
        my $ea = $px->{editor_area};
        $fw_px = int($ea->{w} * 0.82);
        $fw_px = 520 if $fw_px > 520;
        $fw_px = 320 if $fw_px < 320 && $ea->{w} >= 340;
        $fh_px = 104;
        $fx    = $ea->{x} + int(($ea->{w} - $fw_px) / 2);
        $fy    = $ea->{y} + int($ea->{h} * 0.22);
    }
    else {
        my $gw = $px->{grid_w} || 120;
        my $gh = $px->{grid_h} || 40;
        $fx    = int(($frect->{x} / $gw) * $W);
        $fy    = int(($frect->{y} / $gh) * $H);
        $fw_px = int(($frect->{width}  / $gw) * $W);
        $fh_px = int(($frect->{height} / $gh) * $H);
        $fw_px = 260 if $fw_px < 260;
        $fh_px = 90  if $fh_px < 90;
    }

    $fx = 12 if $fx < 12;
    $fy = 36 if $fy < 36;
    $fx = $W - $fw_px - 12 if $fx + $fw_px > $W - 12;
    $fy = $H - $fh_px - 52 if $fy + $fh_px > $H - 52;

    # Two-layer soft drop shadow
    $self->_rect($fx + 6, $fy + 8, $fx + $fw_px + 6, $fy + $fh_px + 8, '#00000038', '', undef, 10);
    $self->_rect($fx + 3, $fy + 4, $fx + $fw_px + 3, $fy + $fh_px + 4, '#00000058', '', undef, 9);

    # Main rounded floating card (1 px inset border)
    $self->_rect($fx, $fy, $fx + $fw_px, $fy + $fh_px, $theme->{bg_float}, $theme->{border_focus}, 1, 8);

    # Title header bar
    my $hdr_h = 26;
    $self->_rect($fx + 1, $fy + 1, $fx + $fw_px - 1, $fy + $hdr_h, $theme->{bg_dark}, '', undef, 7);
    $self->_hline($fx + 1, $fy + $hdr_h, $fw_px - 2, $theme->{border});
    my $title = $frect->{title} || ucfirst($kind);
    $title =~ s/\A\s+|\s+\z//g;
    $c->createText($fx + 12, $fy + 6,
        '-text'   => _clip_chars($title, int(($fw_px - 24) / ($self->{ui_small_char_w} || 6.4))),
        '-fill'   => $theme->{accent},
        '-font'   => $self->{ui_small_font},
        '-anchor' => 'nw',
    );

    my $ix  = $fx + 10;
    my $iy  = $fy + $hdr_h + 8;
    my $iw  = $fw_px - 20;
    my $ih  = $fh_px - $hdr_h - 30;
    my $sf  = $self->{small_font};
    my $scw = $self->{small_char_w};

    if ($kind eq 'telescope') {
        $self->_draw_telescope_body($theme, $ix, $iy, $iw, $ih, $meta);
    }
    elsif ($kind eq 'inline_prompt' || $kind eq 'agy_inline') {
        my $prompt = $meta->{text} // $meta->{instruction} // '';
        $self->_rect($ix, $iy, $ix + $iw, $iy + 28, $theme->{bg_dark}, $theme->{accent}, 1, 5);
        my $mc = int(($iw - 20) / $scw);
        $c->createText($ix + 10, $iy + 7, '-text' => _clip_chars("> $prompt", $mc), '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
        my $cx = _snap($ix + 10 + (length(_clip_chars("> $prompt", $mc)) * $scw) + 2);
        $self->_rect($cx, $iy + 6, $cx + 2, $iy + 22, $theme->{mode_insert}, '') if $cx < $ix + $iw - 8;
        my $hint = $meta->{context_hint} || 'Scope: PPI enclosing sub + Db2 repo conventions';
        $c->createText($ix + 2, $iy + 36, '-text' => _clip_chars($hint, $mc), '-fill' => $theme->{accent2}, '-font' => $sf, '-anchor' => 'nw');
    }
    else {
        my $lines = ($fw && ref($fw->lines) eq 'ARRAY') ? $fw->lines : [];
        my $mc    = int(($iw - 8) / $scw);
        my $max_r = int($ih / 17);
        for my $i (0 .. $max_r - 1) {
            last if $i >= @$lines;
            $c->createText($ix + 4, $iy + $i * 17, '-text' => _clip_chars($lines->[$i], $mc), '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
        }
    }

    # Footer bar
    if (defined $frect->{footer} && length $frect->{footer}) {
        my $foot = $frect->{footer};
        $foot =~ s/\A\s+|\s+\z//g;
        $c->createText($fx + $fw_px - 12, $fy + $fh_px - 17,
            '-text'   => _clip_chars($foot, int(($fw_px - 24) / ($self->{ui_small_char_w} || 6.4))),
            '-fill'   => $theme->{fg_dim},
            '-font'   => $self->{ui_small_font},
            '-anchor' => 'ne',
        );
    }
    return;
}

sub _draw_telescope_body {
    my ($self, $theme, $x, $y, $w, $h, $meta) = @_;
    my $c   = $self->{canvas};
    my $sf  = $self->{small_font};
    my $scw = $self->{small_char_w};

    my $left_w  = int($w * 0.46);
    my $right_x = $x + $left_w + 10;
    my $right_w = $w - $left_w - 10;

    # Vertical divider (1 px filled rect)
    $self->_vline($x + $left_w + 4, $y, $h, $theme->{border});

    # Prompt input box on left
    $self->_rect($x, $y, $x + $left_w, $y + 26, $theme->{bg_dark}, $theme->{border_focus}, 1, 5);
    my $q   = $meta->{query} // '';
    my $res = $meta->{results} || [];
    my $cnt = sprintf('%d/%d', scalar(@$res), $meta->{total_items} || scalar(@$res));
    my $lmc = int(($left_w - 16) / $scw);
    $c->createText($x + 8, $y + 6, '-text' => _clip_chars("> $q", $lmc - length($cnt) - 2), '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
    $c->createText($x + $left_w - 8, $y + 6, '-text' => $cnt, '-fill' => $theme->{fg_dim}, '-font' => $sf, '-anchor' => 'ne');

    # Results list with orange matched-character highlights
    my $sel    = $meta->{selected} || 0;
    my $row_h  = 20;
    my $list_y = $y + 32;
    my $max_r  = int(($h - 32) / $row_h);
    $max_r = 1 if $max_r < 1;
    my $start  = ($sel >= $max_r) ? ($sel - $max_r + 1) : 0;

    for my $i (0 .. $max_r - 1) {
        my $idx = $start + $i;
        last if $idx >= @$res;
        my $e      = $res->[$idx];
        my $ry     = $list_y + $i * $row_h;
        my $is_sel = ($idx == $sel);

        if ($is_sel) {
            $self->_rect($x, $ry, $x + $left_w, $ry + $row_h - 1, $theme->{bg_visual}, '', undef, 4);
        }

        my $lbl = _clip_chars($e->{item}{label} // '', $lmc - 2);
        my $tx0 = $x + 16;
        $c->createText($x + 6, $ry + 3, '-text' => '>', '-fill' => $theme->{accent}, '-font' => $sf, '-anchor' => 'nw')
            if $is_sel;
        $c->createText($tx0, $ry + 3,
            '-text'   => $lbl,
            '-fill'   => $is_sel ? $theme->{fg} : $theme->{fg_dim},
            '-font'   => $sf,
            '-anchor' => 'nw',
        );

        # Highlight matched fuzzy characters in match_char orange
        for my $mp (@{ $e->{positions} || [] }) {
            next if $mp < 0 || $mp >= length($lbl);
            my $mch = substr($lbl, $mp, 1);
            next if $mch eq ' ';
            $c->createText($self->_snap_px($tx0 + $mp * $scw), _snap($ry + 3),
                '-text'   => $mch,
                '-fill'   => $theme->{match_char},
                '-font'   => $sf,
                '-anchor' => 'nw',
            );
        }
    }

    # Right pane: Syntax-highlighted Preview
    return if $right_w < 80;
    my $rmc = int(($right_w - 14) / $scw);
    my $ptitle = $meta->{preview_title} // 'Preview';
    # Display workspace-relative path when possible for clean headers
    if ($self->{editor} && defined $self->{editor}->cwd && index($ptitle, $self->{editor}->cwd) == 0) {
        my $cwd = $self->{editor}->cwd;
        $ptitle = substr($ptitle, length($cwd));
        $ptitle =~ s{\A/+}{};
    }
    $self->_rect($right_x, $y, $right_x + $right_w, $y + 24, $theme->{bg_dark}, $theme->{border}, 1, 5);
    $c->createText(_snap($right_x + 8), _snap($y + 5), '-text' => _clip_chars($ptitle, $rmc), '-fill' => $theme->{accent2}, '-font' => $sf, '-anchor' => 'nw');

    my $lang = eval { require NeoPerl::Core; NeoPerl::Core::detect_language($ptitle) } || 'text';
    my $plines = $meta->{preview_lines} || [];
    my $py0    = $y + 30;
    my $prows  = int(($h - 30) / 16);
    my $state  = 0;

    for my $i (0 .. $prows - 1) {
        last if $i >= @$plines;
        my $pline = _clip_chars($plines->[$i], $rmc);
        my $plen  = length($pline);
        my $py    = _snap($py0 + $i * 16);
        my ($toks, $next_state);
        if (defined(&NeoPerl::Core::Syntax::tokenize_line)) {
            ($toks, $next_state) = eval { NeoPerl::Core::Syntax::tokenize_line($lang, $pline, $state) };
            $state = $next_state // 0;
        }
        if (ref($toks) eq 'ARRAY' && @$toks) {
            my $cur_c = 0;
            for (my $ti = 0; $ti + 2 < @$toks; $ti += 3) {
                my ($tc, $tl, $tt) = @{$toks}[$ti .. $ti + 2];
                last if $tc >= $plen;
                if ($tc > $cur_c) {
                    my $gap = substr($pline, $cur_c, $tc - $cur_c);
                    $c->createText($self->_snap_px($right_x + 6 + $cur_c * $scw), $py, '-text' => $gap, '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw')
                        if length($gap) && $gap !~ /\A +\z/;
                }
                my $te = $tc + $tl;
                $te = $plen if $te > $plen;
                my $seg = substr($pline, $tc, $te - $tc);
                if (length($seg) && $seg !~ /\A +\z/) {
                    my $grp = $TOK_TYPE_TO_GROUP{$tt} || 'normal';
                    my $sfg = NeoPerl::Plugin::Themes->syntax_color($theme, $grp);
                    $c->createText($self->_snap_px($right_x + 6 + $tc * $scw), $py, '-text' => $seg, '-fill' => $sfg, '-font' => $sf, '-anchor' => 'nw');
                }
                $cur_c = $te if $te > $cur_c;
            }
            if ($cur_c < $plen) {
                my $tail = substr($pline, $cur_c, $plen - $cur_c);
                $c->createText($self->_snap_px($right_x + 6 + $cur_c * $scw), $py, '-text' => $tail, '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw')
                    if length($tail) && $tail !~ /\A +\z/;
            }
        }
        else {
            $c->createText(_snap($right_x + 6), $py, '-text' => $pline, '-fill' => $theme->{fg}, '-font' => $sf, '-anchor' => 'nw');
        }
    }
    return;
}

# ---------------------------------------------------------------------------
# PNG Screenshot Export & Mainloop
# ---------------------------------------------------------------------------

sub export_png {
    my ($self, $path) = @_;
    die "export_png requires an output path" unless defined $path && length $path;
    $self->render_frame();
    my $rgba = $self->{canvas}->readback_rgba();
    my ($pw, $ph) = $self->physical_size();
    if (length($rgba) == $self->{width} * $self->{height} * 4
        && ($pw != $self->{width} || $ph != $self->{height}))
    {
        ($pw, $ph) = ($self->{width}, $self->{height});
    }
    my $png = rgba_to_png($rgba, $pw, $ph);
    open my $fh, '>:raw', $path or die "export_png: cannot open '$path': $!";
    print {$fh} $png;
    close $fh or die "export_png: close '$path': $!";
    return {
        ok        => 1,
        path      => $path,
        width     => $pw,
        height    => $ph,
        logical_w => $self->{width},
        logical_h => $self->{height},
        scale     => $self->scale,
        bytes     => length($png),
        backend   => $self->backend_name,
    };
}

sub run {
    my ($self) = @_;
    $self->render_frame();
    return 1 if $self->{headless} || !$self->{mw};

    my $weak = $self;
    weaken($weak);

    if ($self->{auto_exit_ms} > 0) {
        $self->{exit_id} = $self->{mw}->after($self->{auto_exit_ms}, sub {
            $weak->quit() if $weak;
        });
    }

    my $pump_tick;
    $pump_tick = sub {
        return unless $weak && !$weak->{_destroyed} && $weak->{mw};
        my $ed = $weak->{editor};
        if ($ed) {
            my $n = eval { $ed->pump() } || 0;
            $weak->render_frame() if $n || $weak->{dirty};
            if (!$ed->running) {
                $weak->quit();
                return;
            }
        }
        $weak->{tick_id} = $weak->{mw}->after(25, $pump_tick);
    };
    $self->{tick_id} = $self->{mw}->after(25, $pump_tick);

    Tcl::Tk::MT::MainLoop();
    $self->shutdown();
    return 1;
}

sub quit {
    my ($self) = @_;
    $self->{editor}->running(0) if $self->{editor};
    if ($self->{mw} && !$self->{_destroyed}) {
        eval { $self->{mw}->afterCancel($self->{tick_id}) } if defined $self->{tick_id};
        eval { $self->{mw}->afterCancel($self->{exit_id}) } if defined $self->{exit_id};
        $self->{tick_id} = undef;
        $self->{exit_id} = undef;
        eval { $self->{mw}->destroy() };
        $self->{mw} = undef;
    }
    return 1;
}

sub shutdown {
    my ($self) = @_;
    return if $self->{_destroyed};
    $self->{_destroyed} = 1;
    $self->quit();
    if (defined $self->{canvas}) {
        eval { $self->{canvas}->destroy() };
        $self->{canvas} = undef;
    }
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT';
    eval { $self->shutdown() };
    return;
}

1;

__END__

=head1 NAME

NeoPerl::UI::GPU - Retina GPU-accelerated Tcl::Tk::MT::Canvas frontend for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::UI::GPU;

    my $ui = NeoPerl::UI::GPU->new(
        editor   => $editor,
        width    => 1280,
        height   => 720,
        backend  => 'auto',
        headless => 1,
    );
    $ui->render_frame();
    $ui->export_png('/tmp/neoperl.png');

=head1 DESCRIPTION

Composites the complete L<NeoPerl::Editor> workspace onto a single
L<Tcl::Tk::MT::Canvas> (Metal on macOS, Vulkan on Linux/Windows, Software
fallback): top tabline with status pills, optional File Explorer, recursive BSP
editor splits with Cachegrind gutter heatbars, Git/LSP/Perl::Critic/GDB signs,
inline red/green Antigravity/Bonsai diff hunks, ghost text, mode-shaped cursor,
toggleable 4-tab Command Center (C<CHAT>, C<MEMORY>, C<MODELS>,
C<XSDEV>), z-ordered rounded floating windows with drop shadows (2-pane
Telescope, C<Ctrl-I> inline prompt, WhichKey), Powerline statusline, and
pure-Perl PNG framebuffer export via L<Compress::Zlib>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
