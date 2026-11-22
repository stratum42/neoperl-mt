package NeoPerl::UI::TUI;

use strict;
use warnings;
use utf8;

use POSIX ();
use IO::Select ();
use Time::HiRes qw(time sleep);
use NeoPerl::Plugin::Themes ();

our $VERSION = '0.01';

use constant {
    ATTR_NONE      => 0x00,
    ATTR_BOLD      => 0x01,
    ATTR_DIM       => 0x02,
    ATTR_ITALIC    => 0x04,
    ATTR_UNDERLINE => 0x08,
    ATTR_INVERSE   => 0x10,
};

my %HEX_RGB_CACHE;

sub _hex_to_rgb {
    my ($hex) = @_;
    return (255, 176, 0) unless defined $hex && length $hex;
    return @{ $HEX_RGB_CACHE{$hex} } if exists $HEX_RGB_CACHE{$hex};
    my $h = $hex;
    $h =~ s/\A#//;
    my @rgb = (255, 176, 0);
    if ($h =~ /\A([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})/) {
        @rgb = (hex($1), hex($2), hex($3));
    }
    $HEX_RGB_CACHE{$hex} = \@rgb;
    return @rgb;
}

sub _rgb_int_to_hex {
    my ($val) = @_;
    return undef unless defined $val && $val >= 0;
    return sprintf('#%06x', $val & 0xFFFFFF);
}

sub _decode_utf8_safe {
    my ($str) = @_;
    return '' unless defined $str;
    my $copy = "$str";
    if (!utf8::is_utf8($copy) && $copy =~ /[\x80-\xFF]/) {
        utf8::decode($copy);
    }
    return $copy;
}

sub _sanitize_line {
    my ($str) = @_;
    return '' unless defined $str;
    $str = _decode_utf8_safe($str);
    $str =~ s/\r//g;
    $str =~ s/\t/    /g;
    $str =~ s/[\x00-\x1f\x7f]/ /g;
    return $str;
}

sub _truncate {
    my ($str, $max) = @_;
    $str = _sanitize_line($str);
    return '' if !defined($max) || $max <= 0;
    return $str if length($str) <= $max;
    return substr($str, 0, $max) if $max <= 2;
    return substr($str, 0, $max - 1) . '~';
}

sub _wrap_text {
    my ($text, $width, $max_lines) = @_;
    $width     = 10 if !$width || $width < 10;
    $max_lines ||= 6;
    $text = '' unless defined $text;
    my @out;
    for my $para (split /\n/, $text) {
        $para = _sanitize_line($para);
        if (!length $para) {
            push @out, '';
            last if @out >= $max_lines;
            next;
        }
        while (length($para) > $width && @out < $max_lines) {
            my $cut = rindex($para, ' ', $width);
            $cut = $width if $cut <= 0;
            push @out, substr($para, 0, $cut);
            $para = substr($para, $cut);
            $para =~ s/\A +//;
        }
        if (length($para) && @out < $max_lines) {
            push @out, $para;
        }
        last if @out >= $max_lines;
    }
    if (@out > $max_lines) {
        splice(@out, $max_lines);
    }
    return \@out;
}

sub _format_tokens {
    my ($n) = @_;
    $n = int($n || 0);
    return sprintf('%.1fk', $n / 1000.0) if $n >= 1000;
    return "$n";
}

sub new {
    my ($class, %opts) = @_;
    my $headless = $opts{headless} ? 1 : 0;
    my ($w, $h)  = ($opts{width}, $opts{height});
    if (!$w || !$h) {
        my ($tw, $th) = $headless ? (120, 40) : _query_terminal_size();
        $w ||= $tw;
        $h ||= $th;
    }
    $w = 40 if $w < 40;
    $h = 12 if $h < 12;

    my $self = bless {
        editor         => $opts{editor},
        app            => $opts{app},
        headless       => $headless,
        width          => int($w),
        height         => int($h),
        in_fh          => $opts{in_fh}  || \*STDIN,
        out_fh         => $opts{out_fh} || \*STDOUT,
        orig_termios   => undef,
        raw_active     => 0,
        alt_screen     => 0,
        prev_grid      => undef,
        back_grid      => undef,
        last_ansi      => '',
        last_render_ms => 0.0,
        fps            => 0.0,
        cursor_row     => 0,
        cursor_col     => 0,
        cursor_style   => 'block',
        cursor_visible => 1,
        resized_flag   => 0,
        auto_exit_ms   => int($opts{auto_exit_ms} || 0),
        frame_count    => 0,
        _destroyed     => 0,
    }, $class;

    $self->_alloc_grids();
    return $self;
}

sub width          { $_[0]{width} }
sub height         { $_[0]{height} }
sub headless       { $_[0]{headless} }
sub last_ansi      { $_[0]{last_ansi} }
sub last_render_ms { $_[0]{last_render_ms} }
sub frame_count    { $_[0]{frame_count} }
sub backend_name   { 'tui-24bit' }

sub _query_terminal_size {
    my $cols = int($ENV{COLUMNS} || 0);
    my $rows = int($ENV{LINES}   || 0);

    if ((!$cols || !$rows) && $^O ne 'MSWin32') {
        my $TIOCGWINSZ = ($^O eq 'darwin' || $^O =~ /bsd/i) ? 0x40087468 : 0x5413;
        my $winsize = pack('S4', 0, 0, 0, 0);
        if (eval { ioctl(\*STDOUT, $TIOCGWINSZ, $winsize) }) {
            my ($r, $c) = unpack('S2', $winsize);
            $rows = $r if $r && $r > 0;
            $cols = $c if $c && $c > 0;
        }
    }
    $cols = 120 if !$cols || $cols < 40;
    $rows = 40  if !$rows || $rows < 12;
    return ($cols, $rows);
}

sub _alloc_grids {
    my ($self) = @_;
    my ($w, $h) = ($self->{width}, $self->{height});
    my @back;
    for my $r (0 .. $h - 1) {
        my @row;
        for my $c (0 .. $w - 1) {
            push @row, [ ' ', '#ffb000', '#000000', ATTR_NONE ];
        }
        push @back, \@row;
    }
    $self->{back_grid} = \@back;
    $self->{prev_grid} = undef;
    return;
}

sub resize {
    my ($self, $w, $h) = @_;
    $w = int($w || 0);
    $h = int($h || 0);
    $w = 40 if $w < 40;
    $h = 12 if $h < 12;
    return if $w == $self->{width} && $h == $self->{height};
    $self->{width}  = $w;
    $self->{height} = $h;
    $self->_alloc_grids();
    if ($self->{editor} && $self->{editor}->layout) {
        $self->{editor}->layout->compute_rects($w, $h);
    }
    return 1;
}

# ---------------------------------------------------------------------------
# POSIX Raw Mode, Alternate Screen, SGR Mouse, Bracketed Paste, SIGWINCH
# ---------------------------------------------------------------------------

sub enter_raw_mode {
    my ($self) = @_;
    return 1 if $self->{headless} || $self->{raw_active};
    return 0 if $^O eq 'MSWin32';

    my $fd = fileno($self->{in_fh});
    return 0 unless defined $fd && POSIX::isatty($fd);

    my $termios = POSIX::Termios->new();
    $termios->getattr($fd) or return 0;

    my $orig = POSIX::Termios->new();
    $orig->getattr($fd);
    $self->{orig_termios} = $orig;

    my $iflag = $termios->getiflag();
    my $oflag = $termios->getoflag();
    my $lflag = $termios->getlflag();
    my $cflag = $termios->getcflag();

    $iflag &= ~(POSIX::BRKINT | POSIX::ICRNL | POSIX::INPCK | POSIX::ISTRIP | POSIX::IXON);
    $oflag &= ~(POSIX::OPOST);
    $cflag |= POSIX::CS8;
    $lflag &= ~(POSIX::ECHO | POSIX::ICANON | POSIX::IEXTEN | POSIX::ISIG);

    $termios->setiflag($iflag);
    $termios->setoflag($oflag);
    $termios->setcflag($cflag);
    $termios->setlflag($lflag);
    $termios->setcc(POSIX::VMIN,  0);
    $termios->setcc(POSIX::VTIME, 0);
    $termios->setattr($fd, POSIX::TCSAFLUSH);

    $self->{raw_active} = 1;
    $self->_write_out(
        "\e[?1049h"    # Alternate screen
      . "\e[?1000h"    # Basic mouse tracking
      . "\e[?1006h"    # SGR extended mouse coordinates
      . "\e[?2004h"    # Bracketed paste
      . "\e[2J\e[H"    # Clear & home
    );
    $self->{alt_screen} = 1;

    $SIG{WINCH} = sub { $self->{resized_flag} = 1 };
    return 1;
}

sub leave_raw_mode {
    my ($self) = @_;
    return 1 if $self->{headless};
    if ($self->{alt_screen}) {
        $self->_write_out(
            "\e[0m"
          . "\e[0 q"
          . "\e[?25h"
          . "\e[?2004l"
          . "\e[?1006l"
          . "\e[?1000l"
          . "\e[?1049l"
        );
        $self->{alt_screen} = 0;
    }
    if ($self->{raw_active} && $self->{orig_termios}) {
        my $fd = fileno($self->{in_fh});
        if (defined $fd) {
            eval { $self->{orig_termios}->setattr($fd, POSIX::TCSAFLUSH) };
        }
        $self->{raw_active} = 0;
    }
    return 1;
}

sub _write_out {
    my ($self, $bytes) = @_;
    return unless defined $bytes && length $bytes;
    my $fh = $self->{out_fh} or return;
    my $raw = "$bytes";
    utf8::encode($raw) if utf8::is_utf8($raw);
    print {$fh} $raw;
    $fh->flush if $fh->can('flush');
    return;
}

# ---------------------------------------------------------------------------
# Full ANSI / SGR Mouse / Bracketed Paste Input Decoder
# ---------------------------------------------------------------------------

my %CSI_TILDE_MAP = (
    1  => '<Home>',
    2  => '<Insert>',
    3  => '<Del>',
    4  => '<End>',
    5  => '<PageUp>',
    6  => '<PageDown>',
    7  => '<Home>',
    8  => '<End>',
    11 => '<F1>',
    12 => '<F2>',
    13 => '<F3>',
    14 => '<F4>',
    15 => '<F5>',
    17 => '<F6>',
    18 => '<F7>',
    19 => '<F8>',
    20 => '<F9>',
    21 => '<F10>',
    23 => '<F11>',
    24 => '<F12>',
);

my %CSI_FINAL_MAP = (
    A => '<Up>',
    B => '<Down>',
    C => '<Right>',
    D => '<Left>',
    H => '<Home>',
    F => '<End>',
    Z => '<S-Tab>',
    P => '<F1>',
    Q => '<F2>',
    R => '<F3>',
    S => '<F4>',
);

sub decode_input {
    my ($class_or_self, $raw) = @_;
    return [] unless defined $raw && length $raw;

    my @events;
    my $pos = 0;
    my $len = length($raw);

    while ($pos < $len) {
        my $ch  = substr($raw, $pos, 1);
        my $ord = ord($ch);

        # ESC sequences
        if ($ord == 0x1b) {
            my $rest = substr($raw, $pos);

            # Bracketed paste: ESC[200~ ... ESC[201~
            if ($rest =~ /\A\e\[200~(.*?)\e\[201~/s) {
                push @events, { type => 'paste', text => $1 };
                $pos += length($&);
                next;
            }

            # SGR 1006 Mouse: ESC[<btn;col;rowM or m
            if ($rest =~ /\A\e\[<(\d+);(\d+);(\d+)([Mm])/) {
                my ($btn, $col, $row, $act) = ($1 + 0, $2 - 1, $3 - 1, $4);
                my $kind = ($btn >= 64 && $btn <= 67)
                    ? ($btn == 64 ? 'wheel_up' : $btn == 65 ? 'wheel_down' : 'wheel')
                    : (($btn & 32) ? 'drag' : ($act eq 'M' ? 'press' : 'release'));
                push @events, {
                    type   => 'mouse',
                    kind   => $kind,
                    button => ($btn & 3),
                    raw_btn => $btn,
                    col    => $col < 0 ? 0 : $col,
                    row    => $row < 0 ? 0 : $row,
                    press  => ($act eq 'M' ? 1 : 0),
                };
                $pos += length($&);
                next;
            }

            # CSI: ESC[ params final
            if ($rest =~ /\A\e\[([0-9;?]*)([A-Za-z~])/) {
                my ($params, $final) = ($1, $2);
                $pos += length($&);
                if ($final eq '~') {
                    my ($num, $mod) = split /;/, $params, 2;
                    my $key = $CSI_TILDE_MAP{ int($num || 0) } || '<Esc>';
                    $key = _apply_csi_mod($key, $mod) if defined $mod;
                    push @events, { type => 'key', key => $key };
                }
                elsif (exists $CSI_FINAL_MAP{$final}) {
                    my (undef, $mod) = split /;/, $params, 2;
                    my $key = $CSI_FINAL_MAP{$final};
                    $key = _apply_csi_mod($key, $mod) if defined $mod;
                    push @events, { type => 'key', key => $key };
                }
                next;
            }

            # SS3: ESC O final (F1-F4, application arrows)
            if ($rest =~ /\A\eO([A-Za-z])/) {
                my $final = $1;
                $pos += 3;
                my $key = $CSI_FINAL_MAP{$final} || "<M-O>";
                push @events, { type => 'key', key => $key };
                next;
            }

            # Alt / Meta + printable char
            if ($pos + 1 < $len) {
                my $next_ch = substr($raw, $pos + 1, 1);
                my $next_o  = ord($next_ch);
                if ($next_o >= 32 && $next_o <= 126) {
                    push @events, { type => 'key', key => "<M-$next_ch>" };
                    $pos += 2;
                    next;
                }
            }

            push @events, { type => 'key', key => '<Esc>' };
            $pos++;
            next;
        }

        # Control characters
        if ($ord == 0x0d || $ord == 0x0a) {
            push @events, { type => 'key', key => '<CR>' };
            $pos++;
            next;
        }
        if ($ord == 0x09) {
            push @events, { type => 'key', key => '<Tab>' };
            $pos++;
            next;
        }
        if ($ord == 0x7f || $ord == 0x08) {
            push @events, { type => 'key', key => '<BS>' };
            $pos++;
            next;
        }
        if ($ord >= 0x01 && $ord <= 0x1a) {
            my $letter = chr($ord + ord('a') - 1);
            push @events, { type => 'key', key => "<C-$letter>" };
            $pos++;
            next;
        }
        if ($ord == 0x1c) {
            push @events, { type => 'key', key => '<C-\\>' };
            $pos++;
            next;
        }
        if ($ord == 0x1d) {
            push @events, { type => 'key', key => '<C-]>' };
            $pos++;
            next;
        }
        if ($ord == 0x00) {
            push @events, { type => 'key', key => '<C-Space>' };
            $pos++;
            next;
        }

        # UTF-8 multi-byte character
        if ($ord >= 0x80) {
            my $seq_len = ($ord & 0xE0) == 0xC0 ? 2
                        : ($ord & 0xF0) == 0xE0 ? 3
                        : ($ord & 0xF8) == 0xF0 ? 4
                        : 1;
            my $utf = substr($raw, $pos, $seq_len);
            push @events, { type => 'key', key => $utf };
            $pos += length($utf);
            next;
        }

        push @events, { type => 'key', key => $ch };
        $pos++;
    }

    return \@events;
}

sub _apply_csi_mod {
    my ($key, $mod) = @_;
    return $key unless defined $mod && $mod =~ /\A\d+\z/;
    my $m = int($mod) - 1;
    return $key if $m <= 0;
    my $inner = $key;
    $inner =~ s/\A<|>\z//g;
    my @pref;
    push @pref, 'C' if $m & 4;
    push @pref, 'M' if $m & 2;
    push @pref, 'S' if $m & 1;
    return @pref ? '<' . join('-', @pref, $inner) . '>' : $key;
}

# ---------------------------------------------------------------------------
# Cell Grid Drawing Primitives
# ---------------------------------------------------------------------------

sub _clear_back {
    my ($self, $fg, $bg) = @_;
    $fg //= '#ffb000';
    $bg //= '#000000';
    my $grid = $self->{back_grid};
    for my $r (0 .. $self->{height} - 1) {
        my $row = $grid->[$r];
        for my $c (0 .. $self->{width} - 1) {
            $row->[$c] = [ ' ', $fg, $bg, ATTR_NONE ];
        }
    }
    return;
}

sub _put_cell {
    my ($self, $r, $c, $ch, $fg, $bg, $attr) = @_;
    return if $r < 0 || $r >= $self->{height} || $c < 0 || $c >= $self->{width};
    my $cell = $self->{back_grid}[$r][$c];
    $cell->[0] = defined($ch) && length($ch) ? $ch : ' ';
    $cell->[1] = $fg   if defined $fg;
    $cell->[2] = $bg   if defined $bg;
    $cell->[3] = $attr if defined $attr;
    return;
}

sub _fill_rect {
    my ($self, $x, $y, $w, $h, $fg, $bg, $ch, $attr) = @_;
    $ch   //= ' ';
    $attr //= ATTR_NONE;
    my $x1 = $x + $w - 1;
    my $y1 = $y + $h - 1;
    $x  = 0 if $x < 0;
    $y  = 0 if $y < 0;
    $x1 = $self->{width} - 1  if $x1 >= $self->{width};
    $y1 = $self->{height} - 1 if $y1 >= $self->{height};
    for my $r ($y .. $y1) {
        my $row = $self->{back_grid}[$r];
        for my $c ($x .. $x1) {
            $row->[$c] = [ $ch, $fg, $bg, $attr ];
        }
    }
    return;
}

sub _put_str {
    my ($self, $r, $c, $str, $fg, $bg, $attr, $max_w) = @_;
    return 0 if $r < 0 || $r >= $self->{height};
    return 0 unless defined $str && length $str;
    $str = _sanitize_line($str);
    $attr //= ATTR_NONE;
    my $limit = defined($max_w) ? $c + $max_w : $self->{width};
    $limit = $self->{width} if $limit > $self->{width};

    my $row = $self->{back_grid}[$r];
    my $col = $c;
    my @chars = split //, $str;
    for my $ch (@chars) {
        last if $col >= $limit;
        if ($col >= 0) {
            my $cell = $row->[$col];
            $cell->[0] = $ch;
            $cell->[1] = $fg if defined $fg;
            $cell->[2] = $bg if defined $bg;
            $cell->[3] = $attr;
        }
        $col++;
    }
    return $col - $c;
}

sub _draw_box {
    my ($self, $x, $y, $w, $h, %opts) = @_;
    return if $w < 2 || $h < 2;
    my $fg     = $opts{border_fg} || '#ffb000';
    my $bg     = $opts{bg}        || '#080500';
    my $t_fg   = $opts{title_fg}  || $fg;
    my $f_fg   = $opts{footer_fg} || '#a86e00';
    my $style  = $opts{border}    || 'rounded';

    my ($tl, $tr, $bl, $br, $hz, $vt) = ($style eq 'single')
        ? ('┌', '┐', '└', '┘', '─', '│')
        : ('╭', '╮', '╰', '╯', '─', '│');

    $self->_fill_rect($x, $y, $w, $h, $t_fg, $bg, ' ', ATTR_NONE);

    $self->_put_cell($y, $x, $tl, $fg, $bg, ATTR_NONE);
    $self->_put_cell($y, $x + $w - 1, $tr, $fg, $bg, ATTR_NONE);
    $self->_put_cell($y + $h - 1, $x, $bl, $fg, $bg, ATTR_NONE);
    $self->_put_cell($y + $h - 1, $x + $w - 1, $br, $fg, $bg, ATTR_NONE);

    for my $c ($x + 1 .. $x + $w - 2) {
        $self->_put_cell($y, $c, $hz, $fg, $bg, ATTR_NONE);
        $self->_put_cell($y + $h - 1, $c, $hz, $fg, $bg, ATTR_NONE);
    }
    for my $r ($y + 1 .. $y + $h - 2) {
        $self->_put_cell($r, $x, $vt, $fg, $bg, ATTR_NONE);
        $self->_put_cell($r, $x + $w - 1, $vt, $fg, $bg, ATTR_NONE);
    }

    if (defined $opts{title} && length $opts{title} && $w > 4) {
        my $t = _truncate($opts{title}, $w - 4);
        $self->_put_str($y, $x + 2, $t, $t_fg, $bg, ATTR_BOLD, $w - 4);
    }
    if (defined $opts{footer} && length $opts{footer} && $w > 4) {
        my $f = _truncate($opts{footer}, $w - 4);
        my $fx = $x + $w - 2 - length($f);
        $fx = $x + 2 if $fx < $x + 2;
        $self->_put_str($y + $h - 1, $fx, $f, $f_fg, $bg, ATTR_DIM, $w - 4);
    }
    return;
}

# ---------------------------------------------------------------------------
# Diff-Buffered 24-bit Truecolor ANSI Encoder
# ---------------------------------------------------------------------------

sub flush {
    my ($self) = @_;
    my $back = $self->{back_grid};
    my $prev = $self->{prev_grid};
    my ($w, $h) = ($self->{width}, $self->{height});

    my @buf = ("\e[?25l");
    my ($cur_fg, $cur_bg, $cur_attr) = ('', '', -1);
    my ($last_r, $last_c) = (-1, -1);

    for my $r (0 .. $h - 1) {
        my $brow = $back->[$r];
        my $prow = $prev ? $prev->[$r] : undef;
        for my $c (0 .. $w - 1) {
            my $cell = $brow->[$c];
            if ($prow) {
                my $pc = $prow->[$c];
                next if $pc->[0] eq $cell->[0]
                     && $pc->[1] eq $cell->[1]
                     && $pc->[2] eq $cell->[2]
                     && $pc->[3] == $cell->[3];
            }

            if ($r != $last_r || $c != $last_c + 1) {
                push @buf, sprintf("\e[%d;%dH", $r + 1, $c + 1);
            }

            my ($ch, $fg, $bg, $attr) = @$cell;
            if ($attr != $cur_attr) {
                my @sgr = (0);
                push @sgr, 1 if $attr & ATTR_BOLD;
                push @sgr, 2 if $attr & ATTR_DIM;
                push @sgr, 3 if $attr & ATTR_ITALIC;
                push @sgr, 4 if $attr & ATTR_UNDERLINE;
                push @sgr, 7 if $attr & ATTR_INVERSE;
                push @buf, "\e[" . join(';', @sgr) . 'm';
                $cur_attr = $attr;
                $cur_fg   = '';
                $cur_bg   = '';
            }
            if ($fg ne $cur_fg) {
                my ($rr, $gg, $bb) = _hex_to_rgb($fg);
                push @buf, sprintf("\e[38;2;%d;%d;%dm", $rr, $gg, $bb);
                $cur_fg = $fg;
            }
            if ($bg ne $cur_bg) {
                my ($rr, $gg, $bb) = _hex_to_rgb($bg);
                push @buf, sprintf("\e[48;2;%d;%d;%dm", $rr, $gg, $bb);
                $cur_bg = $bg;
            }
            push @buf, $ch;
            $last_r = $r;
            $last_c = $c;
        }
    }

    # Mode-shaped cursor placement
    my $cshape = $self->{cursor_style} eq 'bar'       ? 6
               : $self->{cursor_style} eq 'underline' ? 4
               : 2;
    push @buf, sprintf("\e[%d q\e[%d;%dH", $cshape, $self->{cursor_row} + 1, $self->{cursor_col} + 1);
    push @buf, "\e[?25h" if $self->{cursor_visible};
    push @buf, "\e[0m";

    # Snapshot back -> prev for next diff
    my @snap;
    for my $r (0 .. $h - 1) {
        my $brow = $back->[$r];
        push @snap, [ map { [ @$_ ] } @$brow ];
    }
    $self->{prev_grid} = \@snap;

    my $ansi = join('', @buf);
    $self->{last_ansi} = $ansi;

    if (!$self->{headless}) {
        $self->_write_out($ansi);
    }
    return $ansi;
}

# ---------------------------------------------------------------------------
# Virtual Terminal Inspection Helpers (for deterministic testing)
# ---------------------------------------------------------------------------

sub screen_lines {
    my ($self) = @_;
    my @lines;
    for my $r (0 .. $self->{height} - 1) {
        push @lines, join('', map { $_->[0] } @{ $self->{back_grid}[$r] });
    }
    return \@lines;
}

sub screen_text {
    my ($self) = @_;
    return join("\n", @{ $self->screen_lines() });
}

sub cell_at {
    my ($self, $r, $c) = @_;
    return undef if $r < 0 || $r >= $self->{height} || $c < 0 || $c >= $self->{width};
    my $cell = $self->{back_grid}[$r][$c];
    return {
        char => $cell->[0],
        fg   => $cell->[1],
        bg   => $cell->[2],
        attr => $cell->[3],
    };
}

# ---------------------------------------------------------------------------
# Full Frame Compositor
# ---------------------------------------------------------------------------

sub render_frame {
    my ($self) = @_;
    my $ed = $self->{editor} or return '';
    my $t0 = time();

    my $theme  = $ed->theme || NeoPerl::Plugin::Themes->get('aix_amber');
    my $layout = $ed->layout;
    my $rects  = $layout->compute_rects($self->{width}, $self->{height});

    $self->_clear_back($theme->{fg}, $theme->{bg});

    $self->_render_tabline($ed, $theme, $rects->{tabline});
    $self->_render_explorer($ed, $theme, $rects->{explorer}) if $rects->{explorer};

    my $wins = $rects->{windows} || [];
    my $active_win = $layout->active_window;
    my $nb = ($ed->can('nvim_bridge') && $ed->nvim_bridge && eval { $ed->nvim_bridge->is_connected })
        ? $ed->nvim_bridge : undef;
    if ($nb && $rects->{editor_area}) {
        $self->_render_nvim_grid($ed, $theme, $rects->{editor_area}, $nb);
    }
    else {
        for my $wrect (@$wins) {
            my $is_active = ($active_win && $wrect->{win_id} == $active_win->id) ? 1 : 0;
            $self->_render_editor_window($ed, $theme, $wrect, $is_active, scalar(@$wins) > 1);
        }
    }

    if ($rects->{command_center}) {
        $self->_render_command_center($ed, $theme, $rects->{command_center});
    }

    for my $frect (@{ $rects->{floats} || [] }) {
        $self->_render_float($ed, $theme, $frect);
    }

    $self->_render_statusline($ed, $theme, $rects->{statusline});
    $self->_render_cmdline($ed, $theme, $rects->{cmdline});

    my $ansi = $self->flush();
    my $dt_ms = (time() - $t0) * 1000.0;
    $self->{last_render_ms} = $dt_ms;
    $self->{fps} = $dt_ms > 0.001 ? (1000.0 / $dt_ms) : 999.0;
    $self->{frame_count}++;
    return $ansi;
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
    return [ $lbl, $fg, $theme->{bg_highlight} ];
}

sub _render_tabline {
    my ($self, $ed, $theme, $rect) = @_;
    my ($x, $y, $w) = ($rect->{x}, $rect->{y}, $rect->{width});
    $self->_fill_rect($x, $y, $w, 1, $theme->{fg_dim}, $theme->{bg_tabline});

    my $col = $x;
    $col += $self->_put_str($y, $col, ' npl ', $theme->{cursor_fg}, $theme->{accent}, ATTR_BOLD, $w);
    $col += 1;

    my $cur_buf = $ed->current_buffer;
    my $cur_id  = $cur_buf ? $cur_buf->id : -1;

    # Right-side status pills
    my @pills;
    my $ap = $self->_agy_pill_spec($ed, $theme);
    push @pills, [ " $ap->[0] ", $ap->[1], $ap->[2] ];

    my $mem = $ed->plugin('memory') || $ed->{memory_store};
    if ($mem) {
        my $d = eval { $mem->dialect } || 'db2';
        my $lbl = $d =~ /db2/i ? ' Db2:VEC ' : ' Db2:SIMD ';
        push @pills, [ $lbl, $theme->{diag_info}, $theme->{bg_highlight} ];
    }

    my $inf = $ed->plugin('inference') || $ed->{inference};
    if ($inf) {
        my $tel = eval { $inf->telemetry } || {};
        my $lbl = sprintf(' %.1f/%.0fG ', $tel->{resident_gb} || 0, $tel->{ram_budget_gb} || 20);
        push @pills, [ $lbl, $theme->{accent2}, $theme->{bg_highlight} ];
    }

    my $pills_w = 0;
    $pills_w += length($_->[0]) + 1 for @pills;
    my $tab_max_x = $x + $w - $pills_w - 1;

    for my $b ($ed->list_buffers) {
        last if $col >= $tab_max_x;
        my $active = ($b->id == $cur_id);
        my $dirty  = $b->modified ? ' ●' : '';
        my $lbl    = ' ' . _truncate($b->name, 20) . $dirty . ' ';
        my $fg     = $active ? $theme->{fg} : $theme->{fg_dim};
        my $bg     = $active ? $theme->{bg} : $theme->{bg_tabline};
        my $attr   = $active ? ATTR_BOLD : ATTR_NONE;
        my $rem    = $tab_max_x - $col;
        last if $rem < 4;
        $col += $self->_put_str($y, $col, $lbl, $fg, $bg, $attr, $rem);
        $col += $self->_put_str($y, $col, '│', $theme->{border}, $theme->{bg_tabline}, ATTR_NONE, $tab_max_x - $col)
            if $col < $tab_max_x;
    }

    my $px = $x + $w - $pills_w;
    for my $p (@pills) {
        $px += $self->_put_str($y, $px, $p->[0], $p->[1], $p->[2], ATTR_BOLD, $x + $w - $px);
        $px += 1;
    }
    return;
}

sub _render_explorer {
    my ($self, $ed, $theme, $rect) = @_;
    my ($x, $y, $w, $h) = ($rect->{x}, $rect->{y}, $rect->{width}, $rect->{height});
    $self->_fill_rect($x, $y, $w, $h, $theme->{fg}, $theme->{bg_sidebar});
    for my $r ($y .. $y + $h - 1) {
        $self->_put_cell($r, $x + $w - 1, '│', $theme->{border}, $theme->{bg_sidebar}, ATTR_NONE);
    }

    my $inner_w = $w - 1;
    $self->_put_str($y, $x + 1, _truncate('EXPLORER', $inner_w - 2), $theme->{accent}, $theme->{bg_sidebar}, ATTR_BOLD, $inner_w - 1);

    my $exp = $ed->plugin('explorer') or return;
    my $nodes = $exp->visible_nodes || [];
    my $cur   = $exp->cursor || 0;
    my $max_rows = $h - 1;
    my $start = ($cur >= $max_rows) ? ($cur - $max_rows + 1) : 0;

    for my $i (0 .. $max_rows - 1) {
        my $idx = $start + $i;
        last if $idx >= @$nodes;
        my $n   = $nodes->[$idx];
        my $row = $y + 1 + $i;
        my $sel = ($idx == $cur);
        my $bg  = $sel ? $theme->{bg_highlight} : $theme->{bg_sidebar};
        $self->_fill_rect($x, $row, $inner_w, 1, $theme->{fg}, $bg);

        my $indent = '  ' x ($n->{depth} || 0);
        my $icon   = $n->{is_dir} ? ($n->{expanded} ? '▾ ' : '▸ ') : '  ';
        my $fg     = $n->{is_dir} ? $theme->{accent} : $theme->{fg};
        my $badge  = $n->{git_badge} || '';
        my $bw     = length($badge) ? length($badge) + 1 : 0;
        my $label  = _truncate($indent . $icon . ($n->{name} // ''), $inner_w - 1 - $bw);
        $self->_put_str($row, $x + 1, $label, $fg, $bg, $sel ? ATTR_BOLD : ATTR_NONE, $inner_w - 1 - $bw);
        if (length $badge) {
            my $bfg = $badge eq 'A' ? $theme->{git_add}
                    : $badge eq 'D' ? $theme->{git_delete}
                    : $theme->{git_change};
            $self->_put_str($row, $x + $inner_w - length($badge) - 1, $badge, $bfg, $bg, ATTR_BOLD, length($badge));
        }
    }
    return;
}

sub _extmark_hl_color {
    my ($theme, $hl) = @_;
    return $theme->{fg_dim} unless defined $hl;
    return $theme->{diag_error}  if $hl eq 'DiagError';
    return $theme->{diag_warn}   if $hl eq 'DiagWarn';
    return $theme->{diag_info}   if $hl eq 'DiagInfo';
    return $theme->{diag_hint}   if $hl eq 'DiagHint';
    return $theme->{diff_add_fg} if $hl eq 'DiffAdd';
    return $theme->{diff_del_fg} if $hl eq 'DiffDelete';
    return $theme->{ghost_text}  if $hl eq 'GhostText';
    return $theme->{heat_crit}   if $hl eq 'XSPerfHot';
    return $theme->{heat_hot}    if $hl eq 'XSPerfWarm';
    return $theme->{heat_warm}   if $hl eq 'XSPerfMild';
    return $theme->{heat_cold}   if $hl eq 'XSPerfCool';
    return $theme->{breakpoint}  if $hl eq 'XSDebugBreakpoint';
    return $theme->{mode_command} if $hl eq 'XSDebugPC';
    return $theme->{git_add}     if $hl eq 'GitAdd';
    return $theme->{git_change}  if $hl eq 'GitChange';
    return $theme->{git_delete}  if $hl eq 'GitDelete';
    return $theme->{diff_add_fg} if $hl eq 'XSVecOpt';
    return $theme->{diag_warn}   if $hl eq 'XSVecMissed';
    return $theme->{accent2}     if $hl =~ /VSX|MMA|Vec/i;
    return $theme->{mode_command} if $hl =~ /TOC|Barrier|SMT/i;
    return $theme->{virt_text};
}

sub _render_editor_window {
    my ($self, $ed, $theme, $wrect, $is_active, $multi_split) = @_;
    my $win = $wrect->{window};
    my $buf = $ed->get_buffer($wrect->{buf_id});
    my ($x, $y, $w, $h) = ($wrect->{x}, $wrect->{y}, $wrect->{width}, $wrect->{height});

    $self->_fill_rect($x, $y, $w, $h, $theme->{fg}, $theme->{bg});

    # Draw vertical right separator between splits
    my $body_w = $w;
    my $ed_area = $ed->layout->last_rects->{editor_area};
    if ($multi_split && $ed_area && ($x + $w) < ($ed_area->{x} + $ed_area->{width})) {
        for my $r ($y .. $y + $h - 1) {
            $self->_put_cell($r, $x + $w - 1, '│', $theme->{border}, $theme->{bg}, ATTR_NONE);
        }
        $body_w--;
    }

    # Optional split winbar header
    my $content_y = $y;
    my $content_h = $h;
    if ($multi_split && $h >= 3) {
        my $wb_bg = $is_active ? $theme->{bg_highlight} : $theme->{bg_dark};
        my $wb_fg = $is_active ? $theme->{border_focus} : $theme->{fg_dim};
        $self->_fill_rect($x, $y, $body_w, 1, $wb_fg, $wb_bg);
        my $bname = $buf ? $buf->name : '[No Name]';
        my $bft   = $buf ? ($buf->filetype // '') : '';
        my $dirty = ($buf && $buf->modified) ? ' [+]' : '';
        my $hdr   = sprintf(' %s%s (%s) ', $bname, $dirty, $bft);
        $self->_put_str($y, $x, _truncate($hdr, $body_w), $wb_fg, $wb_bg, $is_active ? ATTR_BOLD : ATTR_NONE, $body_w);
        $content_y++;
        $content_h--;
    }

    return unless $buf && $content_h > 0 && $body_w > 0;

    # Live terminal buffer rendering
    if ($buf->buftype eq 'terminal' && $buf->term) {
        my $scr = $buf->terminal_screen;
        if ($scr && ref($scr->{runs}) eq 'ARRAY') {
            my $runs = $scr->{runs};
            for my $r (0 .. $content_h - 1) {
                last if $r >= @$runs;
                my $c = 0;
                for my $seg (@{ $runs->[$r] }) {
                    last if $c >= $body_w;
                    my $sfg = _rgb_int_to_hex($seg->{fg}) || $theme->{fg};
                    my $sbg = _rgb_int_to_hex($seg->{bg}) || $theme->{bg};
                    my $fl  = $seg->{flags} || 0;
                    $c += $self->_put_str($content_y + $r, $x + $c, $seg->{text} // '', $sfg, $sbg, $fl, $body_w - $c);
                }
            }
            if ($is_active) {
                $self->{cursor_row} = $content_y + ($scr->{cursor_row} || 0);
                $self->{cursor_col} = $x + ($scr->{cursor_col} || 0);
            }
            return;
        }
    }

    my $total      = $buf->line_count || 1;
    my $top        = $win->scroll_top  || 0;
    my $left_col   = $win->scroll_left || 0;
    my $cur_line   = $win->cursor_line || 0;
    my $cur_col    = $win->cursor_col  || 0;
    my $rel_num    = $ed->get_option('relativenumber');
    my $show_num   = $ed->get_option('number');

    my $digits   = length("$total");
    $digits = 3 if $digits < 3;
    my $sign_w   = 3; # [heatbar][sign][git]
    my $gutter_w = $show_num ? ($sign_w + $digits + 1) : $sign_w;
    $gutter_w = 0 if $body_w < 16;
    my $text_x   = $x + $gutter_w;
    my $text_w   = $body_w - $gutter_w;
    return if $text_w <= 0;

    my $lines  = $buf->get_lines($top, $top + $content_h + 2);
    my $spans  = $buf->highlight_range($top, scalar(@$lines));
    my $extmks = $buf->get_all_extmarks($top, $top + scalar(@$lines) + 1) || [];

    # Index extmarks by line
    my %em_by_line;
    for my $em (@$extmks) {
        push @{ $em_by_line{ $em->{line} } }, $em;
    }

    my $modal = $ed->modal;
    my $mode  = $modal->mode;
    my $vis   = $is_active ? $modal->visual_range($ed) : undef;

    my $srow = 0;
    for my $i (0 .. $#$lines) {
        last if $srow >= $content_h;
        my $line_no = $top + $i;
        my $text    = $lines->[$i] // '';
        my $ems     = $em_by_line{$line_no} || [];

        # 1. Virtual lines ABOVE (e.g. red deleted diff lines, code lenses)
        for my $em (@$ems) {
            next unless $em->{virt_lines_above} && ref($em->{virt_lines}) eq 'ARRAY';
            my $vhl = ref($em->{virt_lines_hl}) eq 'ARRAY' ? $em->{virt_lines_hl}[0] : ($em->{virt_lines_hl} // 'DiffDelete');
            my $vfg = _extmark_hl_color($theme, $vhl);
            my $vbg = ($vhl eq 'DiffDelete') ? $theme->{diff_del_bg} : $theme->{bg_dark};
            for my $vl (@{ $em->{virt_lines} }) {
                last if $srow >= $content_h;
                my $r = $content_y + $srow;
                $self->_fill_rect($x, $r, $gutter_w, 1, $theme->{diff_del_fg}, $theme->{bg_dark}) if $gutter_w > 0;
                $self->_put_cell($r, $x + 1, '-', $theme->{diff_del_fg}, $theme->{bg_dark}, ATTR_BOLD) if $gutter_w >= 2 && $vhl eq 'DiffDelete';
                $self->_fill_rect($text_x, $r, $text_w, 1, $vfg, $vbg);
                $self->_put_str($r, $text_x, _truncate($vl, $text_w), $vfg, $vbg, ATTR_NONE, $text_w);
                $srow++;
            }
        }
        last if $srow >= $content_h;

        my $r = $content_y + $srow;

        # Classify line-level extmarks (heatbar, signs, line bg, inline/eol virt)
        my ($heat_ch, $heat_fg, $sign_ch, $sign_fg, $git_ch, $git_fg);
        my $line_bg = ($is_active && $line_no == $cur_line) ? $theme->{bg_highlight} : $theme->{bg};
        my (@eol_virts, @inline_virts);

        for my $em (sort { ($b->{priority} || 0) <=> ($a->{priority} || 0) } @$ems) {
            my $ns = $em->{ns} // '';
            if ($ns eq 'xs_perf') {
                $heat_ch = _decode_utf8_safe($em->{sign_text}) if defined $em->{sign_text} && !$heat_ch;
                $heat_fg = _extmark_hl_color($theme, $em->{sign_hl}) if !$heat_fg;
            }
            elsif ($ns eq 'git_gutter') {
                $git_ch = _decode_utf8_safe($em->{sign_text}) if defined $em->{sign_text} && !$git_ch;
                $git_fg = _extmark_hl_color($theme, $em->{sign_hl}) if !$git_fg;
            }
            elsif (defined $em->{sign_text} && length($em->{sign_text}) && !defined($sign_ch)) {
                $sign_ch = substr(_decode_utf8_safe($em->{sign_text}), 0, 1);
                $sign_fg = _extmark_hl_color($theme, $em->{sign_hl});
            }

            if (defined $em->{hl_group}) {
                if ($em->{hl_group} eq 'DiffAdd') {
                    $line_bg = $theme->{diff_add_bg};
                }
                elsif ($em->{hl_group} eq 'XSDebugPCLine') {
                    $line_bg = $theme->{pc_line};
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

        # Gutter
        if ($gutter_w > 0) {
            $self->_fill_rect($x, $r, $gutter_w, 1, $theme->{fg_gutter}, $theme->{bg_dark});
            if ($heat_ch) {
                $self->_put_cell($r, $x, substr($heat_ch, 0, 1), $heat_fg, $theme->{bg_dark}, ATTR_BOLD);
            }
            if ($sign_ch) {
                $self->_put_cell($r, $x + 1, $sign_ch, $sign_fg, $theme->{bg_dark}, ATTR_BOLD);
            }
            if ($git_ch) {
                $self->_put_cell($r, $x + 2, substr($git_ch, 0, 1), $git_fg, $theme->{bg_dark}, ATTR_BOLD);
            }
            if ($show_num) {
                my $num = ($rel_num && $line_no != $cur_line) ? abs($line_no - $cur_line) : ($line_no + 1);
                my $lstr = sprintf('%*d ', $digits, $num);
                my $lfg  = ($is_active && $line_no == $cur_line) ? $theme->{mode_command} : $theme->{fg_gutter};
                $self->_put_str($r, $x + $sign_w, $lstr, $lfg, $theme->{bg_dark}, $line_no == $cur_line ? ATTR_BOLD : ATTR_NONE, $digits + 1);
            }
        }

        # Text background
        $self->_fill_rect($text_x, $r, $text_w, 1, $theme->{fg}, $line_bg);

        # Syntax spans (draw full base line first so normal gaps are preserved)
        my $row_spans = $spans->[$i] || [];
        my $tlen = length($text);
        if ($tlen > $left_col) {
            my $vis_end = ($left_col + $text_w) < $tlen ? ($left_col + $text_w) : $tlen;
            my $base_slice = substr($text, $left_col, $vis_end - $left_col);
            $self->_put_str($r, $text_x, $base_slice, $theme->{fg}, $line_bg, ATTR_NONE, $text_w);
            for my $sp (@$row_spans) {
                my $sc = $sp->{col};
                my $se = $sc + $sp->{len};
                next if $se <= $left_col;
                last if $sc >= $vis_end;
                my $vc0 = $sc > $left_col ? $sc : $left_col;
                my $vc1 = $se < $vis_end  ? $se : $vis_end;
                next if $vc1 <= $vc0;
                my $slice = substr($text, $vc0, $vc1 - $vc0);
                my $sfg   = NeoPerl::Plugin::Themes->syntax_color($theme, $sp->{group});
                my $sattr = ($sp->{group} eq 'keyword') ? ATTR_BOLD
                          : ($sp->{group} eq 'comment') ? ATTR_ITALIC
                          : ATTR_NONE;
                $self->_put_str($r, $text_x + ($vc0 - $left_col), $slice, $sfg, $line_bg, $sattr, $vc1 - $vc0);
            }
        }

        # Visual selection overlay
        if ($vis && $line_no >= $vis->{start_line} && $line_no <= $vis->{end_line}) {
            my ($vs0, $vs1);
            if ($vis->{mode} eq 'VLINE') {
                ($vs0, $vs1) = ($left_col, $left_col + $text_w);
            }
            elsif ($vis->{mode} eq 'VBLOCK') {
                ($vs0, $vs1) = ($vis->{start_col}, $vis->{end_col} + 1);
            }
            else {
                $vs0 = ($line_no == $vis->{start_line}) ? $vis->{start_col} : 0;
                $vs1 = ($line_no == $vis->{end_line})   ? ($vis->{end_col} + 1) : ($tlen + 1);
            }
            $vs0 = $left_col if $vs0 < $left_col;
            $vs1 = $left_col + $text_w if $vs1 > $left_col + $text_w;
            for my $vc ($vs0 .. $vs1 - 1) {
                my $sc = $text_x + ($vc - $left_col);
                if ($sc >= $text_x && $sc < $text_x + $text_w) {
                    $self->{back_grid}[$r][$sc][2] = $theme->{bg_visual};
                }
            }
        }

        # Inline ghost text
        my $after_col = ($tlen > $left_col) ? ($tlen - $left_col) : 0;
        for my $em (@inline_virts) {
            my $gcol = ($em->{col} // $tlen) - $left_col;
            $gcol = $after_col if $gcol < $after_col;
            if ($gcol >= 0 && $gcol < $text_w) {
                my $gstr = _truncate($em->{virt_text}, $text_w - $gcol);
                $self->_put_str($r, $text_x + $gcol, $gstr, $theme->{ghost_text}, $line_bg, ATTR_ITALIC, $text_w - $gcol);
                $after_col = $gcol + length($gstr);
            }
        }

        # EOL virtual text (diagnostics, Cachegrind metrics, diff hunk hints)
        for my $em (@eol_virts) {
            my $vx = $after_col + 1;
            last if $vx >= $text_w;
            my $vfg = _extmark_hl_color($theme, $em->{virt_hl});
            my $vstr = _truncate($em->{virt_text}, $text_w - $vx);
            $self->_put_str($r, $text_x + $vx, $vstr, $vfg, $line_bg, ATTR_DIM, $text_w - $vx);
            $after_col = $vx + length($vstr);
        }

        # Cursor position tracking & visual block highlight
        if ($is_active && $line_no == $cur_line) {
            my $cc = $cur_col - $left_col;
            $cc = 0 if $cc < 0;
            $cc = $text_w - 1 if $cc >= $text_w;
            $self->{cursor_row} = $r;
            $self->{cursor_col} = $text_x + $cc;
            $self->{cursor_style} = ($mode eq 'INSERT') ? 'bar'
                                  : ($mode eq 'REPLACE') ? 'underline'
                                  : 'block';
            if ($self->{cursor_style} eq 'block') {
                my $cell = $self->{back_grid}[$r][$text_x + $cc];
                $cell->[1] = $theme->{cursor_fg};
                $cell->[2] = $theme->{cursor};
            }
        }

        $srow++;

        # Virtual lines BELOW
        for my $em (@$ems) {
            next if $em->{virt_lines_above} || ref($em->{virt_lines}) ne 'ARRAY';
            my $vhl = ref($em->{virt_lines_hl}) eq 'ARRAY' ? $em->{virt_lines_hl}[0] : ($em->{virt_lines_hl} // 'Comment');
            my $vfg = _extmark_hl_color($theme, $vhl);
            for my $vl (@{ $em->{virt_lines} }) {
                last if $srow >= $content_h;
                $self->_put_str($content_y + $srow, $text_x, _truncate($vl, $text_w), $vfg, $theme->{bg}, ATTR_ITALIC, $text_w);
                $srow++;
            }
        }
    }

    # Empty lines tilde indicator
    while ($srow < $content_h) {
        $self->_put_cell($content_y + $srow, $x, '~', $theme->{fg_gutter}, $theme->{bg}, ATTR_NONE);
        $srow++;
    }
    return;
}

sub _render_nvim_grid {
    my ($self, $ed, $theme, $rect, $nb) = @_;
    my ($x, $y, $w, $h) = ($rect->{x}, $rect->{y}, $rect->{width}, $rect->{height});
    return if $w < 10 || $h < 4;

    $self->_fill_rect($x, $y, $w, $h, $theme->{fg}, $theme->{bg});
    if ($nb->cols != $w || $nb->rows != $h) {
        eval { $nb->resize($w, $h) };
    }
    eval { $nb->pump(0) };

    my $g = $nb->grid(1) or return;
    my $grows = $g->{rows} || [];
    my $max_r = ($h < $g->{height}) ? $h : $g->{height};
    my $max_c = ($w < $g->{width})  ? $w : $g->{width};

    for my $r (0 .. $max_r - 1) {
        my $grow = $grows->[$r] or next;
        for my $c (0 .. $max_c - 1) {
            my $cell = $grow->[$c] or next;
            my $ch   = defined($cell->[0]) && length($cell->[0]) ? _decode_utf8_safe($cell->[0]) : ' ';
            my ($fg, $bg, $ha) = $nb->resolve_hl($cell->[1], $theme);
            my $attr = ATTR_NONE;
            $attr |= ATTR_BOLD      if $ha->{bold};
            $attr |= ATTR_ITALIC    if $ha->{italic};
            $attr |= ATTR_UNDERLINE if $ha->{underline};
            $self->_put_cell($y + $r, $x + $c, $ch, $fg, $bg, $attr);
        }
    }

    my ($crow, $ccol) = $nb->cursor();
    if ($crow >= 0 && $crow < $h && $ccol >= 0 && $ccol < $w) {
        $self->{cursor_row}   = $y + $crow;
        $self->{cursor_col}   = $x + $ccol;
        $self->{cursor_style} = $nb->cursor_shape();
        if ($self->{cursor_style} eq 'block') {
            my $ccell = $self->{back_grid}[ $y + $crow ][ $x + $ccol ];
            $ccell->[1] = $theme->{cursor_fg};
            $ccell->[2] = $theme->{cursor};
        }
    }
    return;
}

# ---------------------------------------------------------------------------
# 4-Tab Command Center (CHAT | MEMORY | MODELS | XSDEV)
# ---------------------------------------------------------------------------

sub _render_command_center {
    my ($self, $ed, $theme, $rect) = @_;
    my ($x, $y, $w, $h) = ($rect->{x}, $rect->{y}, $rect->{width}, $rect->{height});
    return if $w < 12 || $h < 4;

    $self->_fill_rect($x, $y, $w, $h, $theme->{fg}, $theme->{bg_sidebar});
    for my $r ($y .. $y + $h - 1) {
        $self->_put_cell($r, $x, '│', $theme->{border}, $theme->{bg_sidebar}, ATTR_NONE);
    }

    my $ix = $x + 1;
    my $iw = $w - 1;
    my $active_tab = $ed->layout->command_center_tab || 'chat';

    # 4-Tab Header Row
    $self->_fill_rect($ix, $y, $iw, 1, $theme->{fg_dim}, $theme->{bg_dark});
    my @tabs = (
        [ 'chat',   'CHAT'   ],
        [ 'memory', 'MEMORY' ],
        [ 'jobs',   'MODELS' ],
        [ 'xsdev',  'XSDEV'  ],
    );
    my $tx = $ix;
    for my $t (@tabs) {
        my ($key, $lbl) = @$t;
        my $sel = ($key eq $active_tab);
        my $fg  = $sel ? $theme->{accent} : $theme->{fg_dim};
        my $bg  = $sel ? $theme->{bg_sidebar} : $theme->{bg_dark};
        $tx += $self->_put_str($y, $tx, " $lbl ", $fg, $bg, $sel ? ATTR_BOLD : ATTR_NONE, $ix + $iw - $tx);
        $tx += $self->_put_str($y, $tx, '│', $theme->{border}, $theme->{bg_dark}, ATTR_NONE, $ix + $iw - $tx);
    }

    # Divider line
    for my $c ($ix .. $ix + $iw - 1) {
        $self->_put_cell($y + 1, $c, '─', $theme->{border}, $theme->{bg_sidebar}, ATTR_NONE);
    }

    my $body_y = $y + 2;
    my $body_h = $h - 2;
    return if $body_h <= 0;

    my $data = $ed->get_command_center_data($active_tab) || {};
    if ($active_tab eq 'chat') {
        $self->_render_cc_chat($ed, $theme, $ix, $body_y, $iw, $body_h, $data);
    }
    elsif ($active_tab eq 'memory') {
        $self->_render_cc_memory($ed, $theme, $ix, $body_y, $iw, $body_h, $data);
    }
    elsif ($active_tab eq 'jobs') {
        $self->_render_cc_models($ed, $theme, $ix, $body_y, $iw, $body_h, $data);
    }
    else {
        $self->_render_cc_xsdev($ed, $theme, $ix, $body_y, $iw, $body_h, $data);
    }
    return;
}

sub _render_cc_chat {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $mod = $ed->plugin('modalities') || $ed->{modalities};
    my $st  = (%$data) ? $data : ($mod ? eval { $mod->chat_state } : {}) || {};

    my $r = $y;
    my $max_r = $y + $h;

    my $ap  = $self->_agy_pill_spec($ed, $theme);
    my $hdr = sprintf('%s | MCP:%d | AutoCtx:%s',
        $ap->[0], $st->{mcp_tools} || 0, $st->{auto_context} ? 'ON' : 'OFF');
    $self->_put_str($r++, $x + 1, _truncate($hdr, $w - 2), $ap->[1], $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);

    if (defined $st->{current_model} && length $st->{current_model} && $r < $max_r - 2) {
        $self->_put_str($r++, $x + 1, _truncate("Model: $st->{current_model} (:AgyModel)", $w - 2), $theme->{accent2}, $theme->{bg_sidebar}, ATTR_NONE, $w - 2);
    }

    # Reserve bottom lines for permission bar + prompt
    my $perm   = $st->{pending_perm};
    my $perm_h = $perm ? 3 : 0;
    my $foot_h = 2 + $perm_h;
    my $feed_end = $max_r - $foot_h;

    # Two-line status card for onboarding / login / error states
    my $acp_state = $st->{acp_state} // ($st->{acp_connected} ? 'ready' : 'offline');
    if ($acp_state ne 'ready' && $r + 2 <= $feed_end) {
        my ($l1, $l2, $fg);
        if ($acp_state eq 'auth_required') {
            $l1 = 'Antigravity sign-in required (AGY:LOGIN)';
            $l2 = 'Run :AgyLogin or <leader>aL to sign in';
            $fg = $theme->{diag_warn};
        }
        elsif ($acp_state eq 'connecting') {
            $l1 = 'Connecting to agy acp... (AGY:SYNC)';
            $l2 = 'Attaching EditorMCP & workspace...';
            $fg = $theme->{mode_command};
        }
        elsif ($acp_state eq 'error') {
            my $err = $st->{acp_error} || ($st->{acp_stderr_tail} && @{ $st->{acp_stderr_tail} } ? $st->{acp_stderr_tail}[-1] : 'ACP exited');
            $l1 = "ACP Error: $err";
            $l2 = 'Run :AgyDoctor or :AgyReconnect';
            $fg = $theme->{diag_error};
        }
        else {
            $l1 = "Antigravity offline ($ap->[0])";
            $l2 = 'Run :AgyInstall or npl --agy-mock';
            $fg = $theme->{diag_info};
        }
        $self->_put_str($r++, $x + 1, _truncate($l1, $w - 2), $fg, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
        $self->_put_str($r++, $x + 1, _truncate($l2, $w - 2), $theme->{fg}, $theme->{bg_dark}, ATTR_NONE, $w - 2);
    }

    # Thought cards
    for my $th (@{ $st->{thoughts} || [] }) {
        last if $r >= $feed_end;
        my $t = _truncate('> Thought: ' . ($th->{text} // ''), $w - 2);
        $self->_put_str($r++, $x + 1, $t, $theme->{accent2}, $theme->{bg_dark}, ATTR_ITALIC, $w - 2);
    }

    # Tool cards
    for my $tc (@{ $st->{tool_cards} || [] }) {
        last if $r >= $feed_end;
        my $dot = ($tc->{status} // '') eq 'completed' ? '✓' : '●';
        my $fg  = ($tc->{status} // '') eq 'completed' ? $theme->{diff_add_fg} : $theme->{mode_command};
        my $t   = _truncate("$dot Tool: " . ($tc->{title} // 'tool') . ' [' . ($tc->{status} // 'run') . ']', $w - 2);
        $self->_put_str($r++, $x + 1, $t, $fg, $theme->{bg_dark}, ATTR_NONE, $w - 2);
    }

    # Plan checklist
    if (@{ $st->{plan} || [] } && $r < $feed_end) {
        $self->_put_str($r++, $x + 1, 'Plan:', $theme->{accent}, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
        for my $pe (@{ $st->{plan} }) {
            last if $r >= $feed_end;
            my $ps = $pe->{status} // 'pending';
            my $mk = $ps eq 'completed' ? '[x]' : $ps eq 'in_progress' ? '[~]' : '[ ]';
            my $fg = $ps eq 'completed' ? $theme->{diff_add_fg} : $ps eq 'in_progress' ? $theme->{mode_command} : $theme->{fg_dim};
            $self->_put_str($r++, $x + 1, _truncate(" $mk " . ($pe->{content} // $pe->{title} // ''), $w - 2), $fg, $theme->{bg_sidebar}, ATTR_NONE, $w - 2);
        }
    }

    # Chat messages
    for my $msg (@{ $st->{messages} || [] }) {
        last if $r >= $feed_end;
        my $is_user = ($msg->{role} // '') eq 'user';
        my $who = $is_user ? 'You:' : 'Antigravity:';
        my $wfg = $is_user ? $theme->{accent} : $theme->{diff_add_fg};
        $self->_put_str($r++, $x + 1, $who, $wfg, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
        my $wrapped = _wrap_text($msg->{text} // '', $w - 3, 4);
        for my $wl (@$wrapped) {
            last if $r >= $feed_end;
            $self->_put_str($r++, $x + 2, $wl, $theme->{fg}, $theme->{bg_sidebar}, ATTR_NONE, $w - 3);
        }
    }

    # Interactive Permission Bar
    if ($perm && $max_r - $foot_h >= $y + 1) {
        my $py = $max_r - $foot_h;
        $self->_fill_rect($x, $py, $w, 3, $theme->{mode_command}, $theme->{bg_dark});
        my $ptitle = $perm->{title} || $perm->{tool} || 'Approve agent action?';
        $self->_put_str($py,     $x + 1, _truncate("PERM: $ptitle", $w - 2), $theme->{mode_command}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
        $self->_put_str($py + 1, $x + 1, _truncate('[a] Allow  [A] Always  [r] Reject', $w - 2), $theme->{diff_add_fg}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
    }

    # Prompt box at bottom
    my $inp_y = $max_r - 2;
    if ($inp_y >= $y) {
        for my $c ($x .. $x + $w - 1) {
            $self->_put_cell($inp_y, $c, '─', $theme->{border}, $theme->{bg_sidebar}, ATTR_NONE);
        }
        $self->_fill_rect($x, $inp_y + 1, $w, 1, $theme->{fg}, $theme->{bg_dark});
        my $cinp   = $st->{chat_input} // '';
        my $active = $st->{chat_input_active} ? 1 : 0;
        my $ptext  = ($active || length $cinp) ? "> $cinp" : '> Ask Antigravity (@file @memory /plan)';
        my $pfg    = ($active || length $cinp) ? $theme->{fg} : $theme->{fg_dim};
        $self->_put_str($inp_y + 1, $x + 1, _truncate($ptext, $w - 2), $pfg, $theme->{bg_dark}, ATTR_NONE, $w - 2);
    }
    return;
}

sub _render_cc_memory {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $mem = $ed->plugin('memory') || $ed->{memory_store};
    my $dialect = $data->{dialect} || ($mem ? eval { $mem->dialect } : 'db2') || 'db2';
    my $query   = $data->{query}   // '';
    my $items   = $data->{items}   || $data->{memories};
    if (!ref($items) && $mem) {
        $items = eval { $mem->search(query => $query, limit => 8, include_superseded => 1, update_access => 0) } || [];
    }
    $items ||= [];

    my $r = $y;
    my $max_r = $y + $h;
    my $dlbl = $dialect =~ /db2/i ? 'IBM Db2 12.1.2 VECTOR' : 'SQLite + C11 SIMD';
    $self->_put_str($r++, $x + 1, _truncate("Store: $dlbl", $w - 2), $theme->{diag_info}, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
    if ($r < $max_r) {
        $self->_fill_rect($x + 1, $r, $w - 2, 1, $theme->{fg}, $theme->{bg_dark});
        $self->_put_str($r++, $x + 1, _truncate("Query: " . (length($query) ? $query : '<all active memories>'), $w - 2), $theme->{accent}, $theme->{bg_dark}, ATTR_NONE, $w - 2);
    }

    for my $m (@$items) {
        last if $r + 2 > $max_r;
        my $scope = $m->{scope_level} // 'repo';
        my $cat   = $m->{category}    // 'fact';
        my $sim   = defined($m->{cosine_score}) && $m->{cosine_score} > 0 ? $m->{cosine_score}
                  : defined($m->{score})        && $m->{score} > 0        ? $m->{score}
                  : ($m->{confidence} // 0.85);
        $sim = 1.0 if $sim > 1.0;
        $sim = 0.0 if $sim < 0.0;
        my $filled = int($sim * 8 + 0.5);
        my $bar = ('█' x $filled) . ('░' x (8 - $filled));
        my $pin = $m->{pinned} ? ' [PIN]' : '';
        my $sup = defined($m->{superseded_by_id}) ? " -> #$m->{superseded_by_id}" : '';

        my $meta = sprintf('[%s/%s] %s %.2f%s%s', $scope, $cat, $bar, $sim, $pin, $sup);
        my $mfg  = $m->{superseded_by_id} ? $theme->{diag_warn}
                 : $scope eq 'global'     ? $theme->{accent2}
                 : $scope eq 'file'       ? $theme->{diag_info}
                 : $theme->{accent};
        $self->_put_str($r++, $x + 1, _truncate($meta, $w - 2), $mfg, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
        $self->_put_str($r++, $x + 2, _truncate($m->{content} // '', $w - 3), $theme->{fg}, $theme->{bg_sidebar}, ATTR_NONE, $w - 3);
    }

    if ($max_r - 1 >= $r) {
        $self->_put_str($max_r - 1, $x + 1, _truncate('[p] Pin  [x] Forget  [/] Search', $w - 2), $theme->{fg_dim}, $theme->{bg_sidebar}, ATTR_DIM, $w - 2);
    }
    return;
}

sub _render_cc_models {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $inf   = $ed->plugin('inference')     || $ed->{inference};
    my $oq    = $ed->plugin('offload_queue') || $ed->{offload_queue};
    my $vis   = $ed->plugin('vision')        || $ed->{vision};
    my $tel   = $data->{telemetry} || ($inf ? eval { $inf->telemetry } : {}) || {};
    my $jobs  = $data->{jobs}      || ($oq  ? eval { $oq->list_jobs }  : []) || [];
    my $vdocs = $data->{vision_docs} || $data->{recent_docs} || ($vis ? eval { $vis->recent_docs } : []) || [];

    my $r = $y;
    my $max_r = $y + $h;

    my $used   = $tel->{resident_gb}   || 0;
    my $budget = $tel->{ram_budget_gb} || 20;
    my $ratio  = $budget > 0 ? ($used / $budget) : 0;
    $ratio = 1.0 if $ratio > 1.0;
    my $bw = 12;
    my $bf = int($ratio * $bw + 0.5);
    my $ram_bar = ('█' x $bf) . ('░' x ($bw - $bf));
    $self->_put_str($r++, $x + 1, _truncate(sprintf('RAM %s %.1f/%.0f GB', $ram_bar, $used, $budget), $w - 2), $theme->{accent}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);

    my $saved = $tel->{estimated_cloud_tokens_saved} || 0;
    if ($r < $max_r) {
        $self->_put_str($r++, $x + 1, _truncate('Cloud Tokens Saved: ' . _format_tokens($saved), $w - 2), $theme->{diff_add_fg}, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
    }

    # 4 Local Specialist Model Slots
    for my $s (@{ $tel->{slots} || [] }) {
        last if $r >= $max_r;
        my $dot = $s->{loaded} ? '●' : '○';
        my $fg  = $s->{loaded} ? $theme->{diff_add_fg} : $theme->{fg_dim};
        my $pin = $s->{pinned} ? '*' : '';
        my $line = sprintf('%s %-18s %4.1fG%s [%s]',
            $dot, _truncate($s->{display_name} || $s->{role}, 18), $s->{ram_gb} || 0, $pin, $s->{status} || 'idle');
        $self->_put_str($r++, $x + 1, _truncate($line, $w - 2), $fg, $theme->{bg_sidebar}, ATTR_NONE, $w - 2);
    }

    # Bonsai Out-of-Band Job Queue
    if ($r < $max_r) {
        $self->_put_str($r++, $x + 1, _truncate('Bonsai Offload Jobs (' . scalar(@$jobs) . '):', $w - 2), $theme->{accent2}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
    }
    for my $j (@$jobs) {
        last if $r >= $max_r;
        my $syn = defined($j->{syntax_ok}) ? ($j->{syntax_ok} ? 'OK' : 'ERR') : '..';
        my $jfg = ($j->{status} // '') =~ /staged|applied/ ? $theme->{diff_add_fg} : $theme->{mode_command};
        my $jl  = sprintf('[%s] %s (%s) +%dtok', $j->{kind} // 'doc', $j->{status} // 'queued', $syn, $j->{cloud_tokens_saved} || 0);
        $self->_put_str($r++, $x + 1, _truncate($jl, $w - 2), $jfg, $theme->{bg_sidebar}, ATTR_NONE, $w - 2);
    }

    # Granite-Vision Doc Cache
    if ($r < $max_r && @$vdocs) {
        $self->_put_str($r++, $x + 1, _truncate('Vision Doc Cache (' . scalar(@$vdocs) . '):', $w - 2), $theme->{diag_info}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
        for my $d (@$vdocs) {
            last if $r >= $max_r;
            my $dl = sprintf('%s -> %s%s', $d->{filename} // 'doc', $d->{format} // 'md', $d->{cached} ? ' [hit]' : '');
            $self->_put_str($r++, $x + 1, _truncate($dl, $w - 2), $theme->{fg}, $theme->{bg_sidebar}, ATTR_NONE, $w - 2);
        }
    }
    return;
}

sub _render_cc_xsdev {
    my ($self, $ed, $theme, $x, $y, $w, $h, $data) = @_;
    my $xs  = $ed->plugin('xsdev');
    my $st  = (%$data) ? $data : ($xs ? eval { $xs->panel_state } : {}) || {};
    my $dbg = $st->{debugger}  || {};
    my $pr  = $st->{profiler}  || {};
    my $san = $st->{sanitizer} || {};
    my $pgo = $st->{pgo};

    my $r = $y;
    my $max_r = $y + $h;

    my $be = $dbg->{backend} || 'standby';
    $self->_put_str($r++, $x + 1, _truncate("XSDev [$be] BP:" . scalar(@{ $dbg->{breakpoints} || [] }), $w - 2), $theme->{accent}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);

    # Backtrace
    if ($r < $max_r && @{ $dbg->{backtrace} || [] }) {
        $self->_put_str($r++, $x + 1, 'Backtrace:', $theme->{accent2}, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
        for my $f (@{ $dbg->{backtrace} }) {
            last if $r >= $max_r;
            my $fl = sprintf('#%s %s (%s:%s)', $f->{level} // 0, $f->{func} // '?', $f->{file} // '?', $f->{line} // 0);
            $self->_put_str($r++, $x + 2, _truncate($fl, $w - 3), $theme->{fg}, $theme->{bg_sidebar}, ATTR_NONE, $w - 3);
        }
    }

    # Locals & SV* Inspector
    if ($r < $max_r && @{ $dbg->{locals} || [] }) {
        $self->_put_str($r++, $x + 1, 'Locals:', $theme->{diag_info}, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
        for my $loc (@{ $dbg->{locals} }) {
            last if $r >= $max_r;
            my $ll = sprintf('%s = %s', $loc->{name} // '?', $loc->{value} // '');
            $self->_put_str($r++, $x + 2, _truncate($ll, $w - 3), $theme->{fg}, $theme->{bg_sidebar}, ATTR_NONE, $w - 3);
        }
    }

    if ($r < $max_r && @{ $dbg->{sv_inspector} || [] }) {
        $self->_put_str($r++, $x + 1, 'SV* Inspector:', $theme->{mode_command}, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
        for my $sv (@{ $dbg->{sv_inspector} }) {
            last if $r >= $max_r;
            my $sl = sprintf('%s: %s (%s)', $sv->{expr} // 'sv', $sv->{sv_type} // 'SV', $sv->{pv} // $sv->{iv} // '');
            $self->_put_str($r++, $x + 2, _truncate($sl, $w - 3), $theme->{diff_add_fg}, $theme->{bg_sidebar}, ATTR_NONE, $w - 3);
        }
    }

    # POWER registers
    my $pregs = $dbg->{power_registers} || {};
    my @gprs = sort keys %{ $pregs->{gpr} || {} };
    my @vsxs = sort keys %{ $pregs->{vsx} || {} };
    if ($r < $max_r && (@gprs || @vsxs)) {
        $self->_put_str($r++, $x + 1, 'POWER Regs:', $theme->{accent2}, $theme->{bg_sidebar}, ATTR_BOLD, $w - 2);
        for my $k (@gprs[0 .. ($#gprs > 2 ? 2 : $#gprs)]) {
            last if $r >= $max_r;
            $self->_put_str($r++, $x + 2, _truncate("$k = $pregs->{gpr}{$k}", $w - 3), $theme->{fg_dim}, $theme->{bg_sidebar}, ATTR_NONE, $w - 3);
        }
        for my $k (@vsxs[0 .. ($#vsxs > 1 ? 1 : $#vsxs)]) {
            last if $r >= $max_r;
            $self->_put_str($r++, $x + 2, _truncate("$k = $pregs->{vsx}{$k}", $w - 3), $theme->{diag_info}, $theme->{bg_sidebar}, ATTR_NONE, $w - 3);
        }
    }

    # Cachegrind Hotspots
    if ($r < $max_r && @{ $pr->{hotspots} || [] }) {
        $self->_put_str($r++, $x + 1, 'Cachegrind Hotspots:', $theme->{heat_hot}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
        for my $hs (@{ $pr->{hotspots} }) {
            last if $r >= $max_r;
            my $pct = $hs->{ir_pct} || 0;
            my $hfg = $pct >= 10 ? $theme->{heat_crit} : $pct >= 3 ? $theme->{heat_hot} : $theme->{heat_warm};
            my $hl  = sprintf('%5.1f%% Ir  %s:%d', $pct, $hs->{func} || $hs->{file} || '?', $hs->{line} || 0);
            $self->_put_str($r++, $x + 1, _truncate($hl, $w - 2), $hfg, $theme->{bg_sidebar}, ATTR_NONE, $w - 2);
        }
    }

    # PGO summary
    if ($r < $max_r && ref($pgo) eq 'HASH' && $pgo->{ok}) {
        my $pl = sprintf('PGO: %.1fms->%.1fms (+%.1f%%)', $pgo->{baseline_ms} || 0, $pgo->{pgo_ms} || 0, $pgo->{speedup_pct} || 0);
        $self->_put_str($r++, $x + 1, _truncate($pl, $w - 2), $theme->{diff_add_fg}, $theme->{bg_dark}, ATTR_BOLD, $w - 2);
    }
    return;
}

# ---------------------------------------------------------------------------
# Z-Ordered Floating Windows (Telescope 2-Pane, Ctrl-I Inline, WhichKey, Generic)
# ---------------------------------------------------------------------------

sub _render_float {
    my ($self, $ed, $theme, $frect) = @_;
    my ($x, $y, $w, $h) = ($frect->{x}, $frect->{y}, $frect->{width}, $frect->{height});
    return if $w < 6 || $h < 3;

    my $fw   = $frect->{window};
    my $kind = $frect->{kind} || 'generic';
    my $meta = ($fw && ref($fw->meta) eq 'HASH') ? $fw->meta : {};

    $self->_draw_box($x, $y, $w, $h,
        border_fg => $theme->{border_focus},
        bg        => $theme->{bg_float},
        title     => $frect->{title},
        footer    => $frect->{footer},
        title_fg  => $theme->{accent},
        footer_fg => $theme->{fg_dim},
        border    => $frect->{border} || 'rounded',
    );

    my $ix = $x + 1;
    my $iy = $y + 1;
    my $iw = $w - 2;
    my $ih = $h - 2;
    return if $iw <= 0 || $ih <= 0;

    if ($kind eq 'telescope') {
        my $left_w  = int($iw * 0.48);
        $left_w = 16 if $left_w < 16 && $iw >= 32;
        my $right_x = $ix + $left_w + 1;
        my $right_w = $iw - $left_w - 1;

        # Vertical divider inside Telescope
        if ($right_w > 4) {
            for my $r ($iy .. $iy + $ih - 1) {
                $self->_put_cell($r, $ix + $left_w, '│', $theme->{border}, $theme->{bg_float}, ATTR_NONE);
            }
        }

        # Prompt row
        my $q = $meta->{query} // '';
        my $res = $meta->{results} || [];
        my $cnt = sprintf('%d/%d', scalar(@$res), $meta->{total_items} || scalar(@$res));
        $self->_fill_rect($ix, $iy, $left_w, 1, $theme->{fg}, $theme->{bg_dark});
        $self->_put_str($iy, $ix + 1, _truncate("> $q", $left_w - length($cnt) - 3), $theme->{accent}, $theme->{bg_dark}, ATTR_BOLD, $left_w - 2);
        $self->_put_str($iy, $ix + $left_w - length($cnt) - 1, $cnt, $theme->{fg_dim}, $theme->{bg_dark}, ATTR_NONE, length($cnt));

        # Results list with matched-character highlights
        my $sel = $meta->{selected} || 0;
        my $list_h = $ih - 2;
        my $start  = ($sel >= $list_h && $list_h > 0) ? ($sel - $list_h + 1) : 0;
        for my $i (0 .. $list_h - 1) {
            my $idx = $start + $i;
            last if $idx >= @$res;
            my $e   = $res->[$idx];
            my $row = $iy + 2 + $i;
            my $is_sel = ($idx == $sel);
            my $rbg = $is_sel ? $theme->{bg_visual} : $theme->{bg_float};
            $self->_fill_rect($ix, $row, $left_w, 1, $theme->{fg}, $rbg);

            my $pfx = $is_sel ? '> ' : '  ';
            my $lbl = _truncate($e->{item}{label} // '', $left_w - 3);
            $self->_put_str($row, $ix, $pfx . $lbl, $is_sel ? $theme->{fg} : $theme->{fg_dim}, $rbg, $is_sel ? ATTR_BOLD : ATTR_NONE, $left_w);

            for my $mp (@{ $e->{positions} || [] }) {
                next if $mp < 0 || $mp >= length($lbl);
                my $mc = $ix + 2 + $mp;
                if ($mc < $ix + $left_w) {
                    $self->{back_grid}[$row][$mc][1] = $theme->{match_char};
                    $self->{back_grid}[$row][$mc][3] |= ATTR_BOLD;
                }
            }
        }

        # Right pane preview
        if ($right_w > 4) {
            my $ptitle = $meta->{preview_title} // 'Preview';
            $self->_put_str($iy, $right_x + 1, _truncate($ptitle, $right_w - 2), $theme->{accent2}, $theme->{bg_float}, ATTR_BOLD, $right_w - 2);
            my $plines = $meta->{preview_lines} || [];
            for my $i (0 .. $ih - 3) {
                last if $i >= @$plines;
                $self->_put_str($iy + 2 + $i, $right_x + 1, _truncate($plines->[$i], $right_w - 2), $theme->{fg}, $theme->{bg_float}, ATTR_NONE, $right_w - 2);
            }
        }
        return;
    }

    if ($kind eq 'inline_prompt' || $kind eq 'agy_inline') {
        my $prompt = $meta->{text} // $meta->{instruction} // '';
        $self->_put_str($iy, $ix + 1, _truncate("Prompt: $prompt", $iw - 2), $theme->{accent}, $theme->{bg_float}, ATTR_BOLD, $iw - 2);
        if ($ih >= 2 && $meta->{context_hint}) {
            $self->_put_str($iy + 1, $ix + 1, _truncate($meta->{context_hint}, $iw - 2), $theme->{fg_dim}, $theme->{bg_float}, ATTR_DIM, $iw - 2);
        }
        return;
    }

    # Generic / WhichKey / Hover lines
    my $lines = ($fw && ref($fw->lines) eq 'ARRAY') ? $fw->lines : [];
    for my $i (0 .. $ih - 1) {
        last if $i >= @$lines;
        $self->_put_str($iy + $i, $ix + 1, _truncate($lines->[$i], $iw - 2), $theme->{fg}, $theme->{bg_float}, ATTR_NONE, $iw - 2);
    }
    return;
}

# ---------------------------------------------------------------------------
# Bottom Powerline Statusline & Command Line
# ---------------------------------------------------------------------------

sub _render_statusline {
    my ($self, $ed, $theme, $rect) = @_;
    my ($x, $y, $w) = ($rect->{x}, $rect->{y}, $rect->{width});
    $self->_fill_rect($x, $y, $w, 1, $theme->{fg}, $theme->{bg_statusline});

    my $nb   = ($ed->can('nvim_bridge') && $ed->nvim_bridge && eval { $ed->nvim_bridge->is_connected })
             ? $ed->nvim_bridge : undef;
    my $mode = $nb ? $nb->display_mode() : ($ed->modal->mode || 'NORMAL');
    my $mcol = $mode eq 'INSERT'                     ? $theme->{mode_insert}
             : $mode =~ /\AV/                        ? $theme->{mode_visual}
             : $mode eq 'REPLACE'                    ? $theme->{mode_replace}
             : $mode =~ /\A(?:COMMAND|SEARCH)/       ? $theme->{mode_command}
             : $mode eq 'TERMINAL'                   ? $theme->{mode_terminal}
             : $theme->{mode_normal};

    my $col = $x;
    $col += $self->_put_str($y, $col, " $mode ", $theme->{cursor_fg}, $mcol, ATTR_BOLD, $w);
    if ($nb) {
        my $nver = ' NVIM ' . $nb->version_string . ' ';
        $col += $self->_put_str($y, $col, $nver, $theme->{accent}, $theme->{bg_highlight}, ATTR_BOLD, $w - $col);
    }

    my $segs = $ed->get_statusline_segments || {};
    if (ref($segs->{git}) eq 'HASH' && length($segs->{git}{branch} // '')) {
        $col += $self->_put_str($y, $col, " git:$segs->{git}{branch} ", $theme->{accent2}, $theme->{bg_highlight}, ATTR_NONE, $w - $col);
    }

    my $buf = $ed->current_buffer;
    if ($buf) {
        my $fname = $buf->name . ($buf->modified ? ' [+]' : '');
        $col += $self->_put_str($y, $col, " $fname ", $theme->{fg}, $theme->{bg_statusline}, ATTR_BOLD, $w - $col);
    }

    my $dc = $ed->diagnostic_counts;
    if ($dc && $dc->{total}) {
        $col += $self->_put_str($y, $col, sprintf(' E:%d W:%d ', $dc->{error}, $dc->{warn}), $dc->{error} ? $theme->{diag_error} : $theme->{diag_warn}, $theme->{bg_statusline}, ATTR_BOLD, $w - $col);
    }

    # Right side: Cloud Tokens Saved + Ln:Col + backend
    my @right;
    my $inf = $ed->plugin('inference') || $ed->{inference};
    if ($inf) {
        my $tel = eval { $inf->telemetry } || {};
        my $saved = $tel->{estimated_cloud_tokens_saved} || 0;
        push @right, [ ' Saved:' . _format_tokens($saved) . ' ', $theme->{diff_add_fg}, $theme->{bg_highlight} ];
    }
    my $win = $ed->current_window;
    my ($ln, $cc) = $win ? ($win->cursor_line + 1, $win->cursor_col + 1) : (1, 1);
    push @right, [ sprintf(' %d:%d ', $ln, $cc), $theme->{fg}, $theme->{bg_highlight} ];
    push @right, [ ' TUI-24b ', $theme->{cursor_fg}, $mcol ];

    my $rw = 0;
    $rw += length($_->[0]) for @right;
    my $rx = $x + $w - $rw;
    $rx = $col + 1 if $rx < $col + 1;
    for my $seg (@right) {
        last if $rx >= $x + $w;
        $rx += $self->_put_str($y, $rx, $seg->[0], $seg->[1], $seg->[2], ATTR_BOLD, $x + $w - $rx);
    }
    return;
}

sub _render_cmdline {
    my ($self, $ed, $theme, $rect) = @_;
    my ($x, $y, $w) = ($rect->{x}, $rect->{y}, $rect->{width});
    $self->_fill_rect($x, $y, $w, 1, $theme->{fg}, $theme->{bg_dark});

    my $modal = $ed->modal;
    my $mode  = $modal->mode;
    if ($mode eq 'COMMAND' || $mode eq 'SEARCH_FWD' || $mode eq 'SEARCH_BWD') {
        my $prompt = $modal->cmdline_prompt // ':';
        my $text   = $modal->cmdline // '';
        $self->_put_str($y, $x, _truncate($prompt . $text, $w), $theme->{fg}, $theme->{bg_dark}, ATTR_NONE, $w);
        $self->{cursor_row}   = $y;
        $self->{cursor_col}   = $x + 1 + ($modal->cmdline_pos || length($text));
        $self->{cursor_style} = 'bar';
    }
    else {
        my $msg = $ed->status_message || {};
        my $fg  = ($msg->{level} // '') eq 'error' ? $theme->{diag_error}
                : ($msg->{level} // '') eq 'warn'  ? $theme->{diag_warn}
                : $theme->{fg_dim};
        $self->_put_str($y, $x + 1, _truncate($msg->{text} // '', $w - 2), $fg, $theme->{bg_dark}, ATTR_NONE, $w - 2);
    }
    return;
}

# ---------------------------------------------------------------------------
# Interactive Main Loop
# ---------------------------------------------------------------------------

sub dispatch_event {
    my ($self, $ev) = @_;
    my $ed = $self->{editor} or return 0;
    return 0 unless ref($ev) eq 'HASH';

    if ($ev->{type} eq 'key') {
        # Handle active permission bar keys or chat composer input when CHAT tab is open
        my $mod = $ed->plugin('modalities') || $ed->{modalities};
        if ($mod && $ed->layout->command_center_open && $ed->layout->command_center_tab eq 'chat') {
            my $cs = eval { $mod->chat_state };
            if ($cs && $cs->{pending_perm} && ($ev->{key} eq 'a' || $ev->{key} eq 'A' || $ev->{key} eq 'r')) {
                $mod->handle_permission_key($ev->{key});
                return 1;
            }
            if ($mod->can('is_chat_input_active') && $mod->is_chat_input_active) {
                return 1 if $mod->handle_chat_input_key($ev->{key});
            }
        }
        return $ed->handle_key($ev->{key});
    }
    elsif ($ev->{type} eq 'paste') {
        my $buf = $ed->current_buffer or return 0;
        my $win = $ed->current_window or return 0;
        $buf->insert_at($win->cursor_line, $win->cursor_col, $ev->{text});
        return 1;
    }
    elsif ($ev->{type} eq 'mouse') {
        if ($ev->{kind} eq 'wheel_up') {
            my $win = $ed->current_window;
            $win->scroll_top($win->scroll_top > 3 ? $win->scroll_top - 3 : 0) if $win;
            return 1;
        }
        elsif ($ev->{kind} eq 'wheel_down') {
            my $win = $ed->current_window;
            my $buf = $ed->current_buffer;
            if ($win && $buf) {
                my $max = $buf->line_count > 1 ? $buf->line_count - 1 : 0;
                my $nt  = $win->scroll_top + 3;
                $win->scroll_top($nt > $max ? $max : $nt);
            }
            return 1;
        }
    }
    return 0;
}

sub run {
    my ($self) = @_;
    my $ed = $self->{editor} or return 0;
    $self->enter_raw_mode() unless $self->{headless};

    my $start_t = time();
    my $sel = !$self->{headless} ? IO::Select->new($self->{in_fh}) : undef;

    eval {
        $self->render_frame();
        while ($ed->running) {
            if ($self->{resized_flag}) {
                $self->{resized_flag} = 0;
                my ($nw, $nh) = _query_terminal_size();
                $self->resize($nw, $nh);
                $self->render_frame();
            }

            if ($self->{auto_exit_ms} > 0 && ((time() - $start_t) * 1000.0) >= $self->{auto_exit_ms}) {
                $ed->running(0);
                last;
            }

            my $dirty = 0;
            if ($sel && $sel->can_read(0.02)) {
                my $buf = '';
                my $n = sysread($self->{in_fh}, $buf, 4096);
                if (defined $n && $n > 0) {
                    my $events = $self->decode_input($buf);
                    for my $ev (@$events) {
                        $self->dispatch_event($ev);
                        $dirty = 1;
                    }
                }
            }
            else {
                sleep(0.01) if $self->{headless};
            }

            my $ticks = $ed->pump();
            $dirty = 1 if $ticks;

            $self->render_frame() if $dirty;
            last if $self->{headless} && $self->{auto_exit_ms} <= 0;
        }
    };
    my $err = $@;
    $self->shutdown();
    die $err if $err;
    return 1;
}

sub shutdown {
    my ($self) = @_;
    return if $self->{_destroyed};
    $self->{_destroyed} = 1;
    $self->leave_raw_mode();
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

NeoPerl::UI::TUI - 24-bit ANSI truecolor terminal frontend for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::UI::TUI;

    my $tui = NeoPerl::UI::TUI->new(
        editor   => $editor,
        width    => 120,
        height   => 40,
        headless => 1,
    );
    my $ansi = $tui->render_frame();
    my $text = $tui->screen_text();

=head1 DESCRIPTION

Renders a L<NeoPerl::Editor> instance onto a 24-bit truecolor POSIX terminal
using a diff-buffered 2D cell grid, Unicode box-drawing borders, POSIX raw
termios, SGR mouse, bracketed paste, and C<SIGWINCH> resize handling. Mirrors
BSP splits, Cachegrind gutter heatbars, inline red/green diff hunks, the 4-tab
Command Center (C<CHAT>, C<MEMORY>, C<MODELS>, C<XSDEV>), and z-ordered
floating windows. Set C<< headless => 1 >> for deterministic virtual-terminal
rendering without opening a TTY.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
