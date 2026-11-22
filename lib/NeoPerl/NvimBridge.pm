package NeoPerl::NvimBridge;

use strict;
use warnings;

use Carp qw(croak);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Spec ();
use IO::Handle ();
use IO::Select ();
use POSIX ();
use Time::HiRes qw(time sleep);

use NeoPerl::Core ();

our $VERSION = '0.01';

my %NVIM_MODE_MAP = (
    'n'      => 'NORMAL',
    'no'     => 'OPERATOR',
    'nov'    => 'OPERATOR',
    'noV'    => 'OPERATOR',
    'niI'    => 'NORMAL',
    'niR'    => 'NORMAL',
    'niV'    => 'NORMAL',
    'nt'     => 'NORMAL',
    'v'      => 'VISUAL',
    'vs'     => 'VISUAL',
    'V'      => 'VLINE',
    'Vs'     => 'VLINE',
    "\x16"   => 'VBLOCK',
    "\x16s"  => 'VBLOCK',
    's'      => 'SELECT',
    'S'      => 'SLINE',
    'i'      => 'INSERT',
    'ic'     => 'INSERT',
    'ix'     => 'INSERT',
    'R'      => 'REPLACE',
    'Rc'     => 'REPLACE',
    'Rx'     => 'REPLACE',
    'Rv'     => 'REPLACE',
    'c'      => 'COMMAND',
    'cv'     => 'COMMAND',
    'r'      => 'NORMAL',
    'rm'     => 'NORMAL',
    'r?'     => 'NORMAL',
    '!'      => 'COMMAND',
    't'      => 'TERMINAL',
    'normal'         => 'NORMAL',
    'insert'         => 'INSERT',
    'replace'        => 'REPLACE',
    'visual'         => 'VISUAL',
    'visual_select'  => 'VISUAL',
    'cmdline_normal' => 'COMMAND',
    'cmdline_insert' => 'COMMAND',
    'cmdline_replace'=> 'COMMAND',
    'operator'       => 'OPERATOR',
    'terminal'       => 'TERMINAL',
    'showmatch'      => 'INSERT',
);

sub _mp_bool {
    return { _msgpack_bool => ($_[0] ? 1 : 0) };
}

sub _rgb_to_hex {
    my ($v) = @_;
    return undef unless defined $v && $v >= 0;
    return sprintf('#%06x', $v & 0xFFFFFF);
}

sub _normalize_hex {
    my ($hex, $fallback) = @_;
    return $fallback unless defined $hex && length $hex;
    my $h = $hex;
    $h =~ s/\A#//;
    $h = substr($h, 0, 6);
    return ($h =~ /\A[0-9a-fA-F]{6}\z/) ? "#$h" : $fallback;
}

sub find_nvim_bin {
    my ($class, $explicit) = @_;
    if (defined $explicit && length $explicit) {
        return (-x $explicit && !-d $explicit) ? $explicit : undef;
    }
    my @dirs = grep { defined && length } split(/:/, $ENV{PATH} // '');
    for my $extra ('/opt/homebrew/bin', '/usr/local/bin', '/usr/bin') {
        push @dirs, $extra unless grep { $_ eq $extra } @dirs;
    }
    for my $d (@dirs) {
        my $cand = File::Spec->catfile($d, 'nvim');
        return $cand if -x $cand && !-d $cand;
    }
    return undef;
}

sub new {
    my ($class, %opts) = @_;
    my $cols = int($opts{cols} || 100);
    my $rows = int($opts{rows} || 36);
    $cols = 20 if $cols < 20;
    $rows = 6  if $rows < 6;

    my $self = bless {
        nvim_bin             => $opts{nvim_bin},
        args                 => $opts{args},
        clean                => exists($opts{clean}) ? ($opts{clean} ? 1 : 0) : 1,
        mock                 => $opts{mock} // 0,   # 0 | 1 | 'auto'
        cwd                  => $opts{cwd},
        editor               => $opts{editor},
        timeout              => $opts{timeout} || 5.0,
        cols                 => $cols,
        rows                 => $rows,
        pid                  => undef,
        in_fh                => undef,
        out_fh               => undef,
        sel                  => undef,
        rx_buf               => '',
        next_msgid           => 1,
        responses            => {},
        notifications        => [],
        connected            => 0,
        is_mock              => 0,
        channel_id           => undef,
        api_info             => undef,
        version              => {},
        version_str          => '',
        grids                => {},
        default_fg           => '#ffb000',
        default_bg           => '#000000',
        default_sp           => '#ff8800',
        hl_attrs             => {},
        mode_info            => [],
        cursor_style_enabled => 1,
        mode_name            => 'normal',
        mode_idx             => 0,
        cursor_grid          => 1,
        cursor_row           => 0,
        cursor_col           => 0,
        buf_cursor           => undef,
        flush_count          => 0,
        dirty                => 0,
        staged_proposal      => undef,
        _proposal_ns         => undef,
        _last_file_path      => '',
        _closed              => 0,
    }, $class;

    $self->_init_grid(1, $cols, $rows);
    return $self;
}

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------

sub is_connected   { $_[0]{connected} ? 1 : 0 }
sub is_mock        { $_[0]{is_mock}   ? 1 : 0 }
sub pid            { $_[0]{pid} }
sub channel_id     { $_[0]{channel_id} }
sub api_info       { $_[0]{api_info} }
sub version        { $_[0]{version} }
sub version_string { $_[0]{version_str} || ($_[0]{is_mock} ? 'mock-0.12' : 'unknown') }
sub cols           { $_[0]{cols} }
sub rows           { $_[0]{rows} }
sub flush_count    { $_[0]{flush_count} }
sub dirty          { my $s = shift; $s->{dirty} = $_[0] ? 1 : 0 if @_; return $s->{dirty} }
sub hl_attrs       { $_[0]{hl_attrs} }
sub mode_info      { $_[0]{mode_info} }
sub mode_name      { $_[0]{mode_name} }
sub staged_proposal { $_[0]{staged_proposal} }

sub default_colors {
    my ($self) = @_;
    return {
        fg => $self->{default_fg},
        bg => $self->{default_bg},
        sp => $self->{default_sp},
    };
}

sub display_mode {
    my ($self) = @_;
    my $m = $self->{mode_name} // 'normal';
    return $NVIM_MODE_MAP{$m} if exists $NVIM_MODE_MAP{$m};
    my $low = lc($m);
    return 'INSERT'  if $low =~ /insert/;
    return 'REPLACE' if $low =~ /replace/;
    return 'VISUAL'  if $low =~ /visual/;
    return 'COMMAND' if $low =~ /cmdline/;
    return 'OPERATOR' if $low =~ /operator/;
    return 'TERMINAL' if $low =~ /terminal/;
    return 'NORMAL';
}

sub cursor_shape {
    my ($self) = @_;
    my $info = $self->{mode_info};
    my $idx  = $self->{mode_idx} // 0;
    if (ref($info) eq 'ARRAY' && $idx >= 0 && $idx < @$info && ref($info->[$idx]) eq 'HASH') {
        my $sh = $info->[$idx]{cursor_shape} // '';
        return 'bar'       if $sh eq 'vertical';
        return 'underline' if $sh eq 'horizontal';
        return 'block'     if $sh eq 'block';
    }
    my $dm = $self->display_mode();
    return 'bar'       if $dm eq 'INSERT' || $dm eq 'COMMAND';
    return 'underline' if $dm eq 'REPLACE';
    return 'block';
}

sub cursor {
    my ($self) = @_;
    if (wantarray) {
        return ($self->{cursor_row}, $self->{cursor_col});
    }
    return {
        grid => $self->{cursor_grid},
        row  => $self->{cursor_row},
        col  => $self->{cursor_col},
    };
}

sub buf_cursor {
    my ($self) = @_;
    return $self->{buf_cursor} if ref($self->{buf_cursor}) eq 'ARRAY' && @{ $self->{buf_cursor} } >= 2;
    return [ ($self->{cursor_row} // 0) + 1, ($self->{cursor_col} // 0) ];
}

sub grid {
    my ($self, $grid_id) = @_;
    $grid_id ||= 1;
    return $self->{grids}{$grid_id};
}

sub grid_lines {
    my ($self, $grid_id) = @_;
    my $g = $self->grid($grid_id) or return [];
    my @out;
    for my $row (@{ $g->{rows} }) {
        my $s = join('', map { defined($_->[0]) ? $_->[0] : ' ' } @$row);
        push @out, $s;
    }
    return \@out;
}

sub grid_text {
    my ($self, $grid_id) = @_;
    return join("\n", @{ $self->grid_lines($grid_id) });
}

sub resolve_hl {
    my ($self, $hl_id, $theme) = @_;
    my $def_fg = $self->{default_fg} || ($theme ? $theme->{fg} : '#ffb000');
    my $def_bg = $self->{default_bg} || ($theme ? $theme->{bg} : '#000000');
    my $attr = ($hl_id && exists $self->{hl_attrs}{$hl_id}) ? $self->{hl_attrs}{$hl_id} : undef;
    return ($def_fg, $def_bg, {}) unless ref($attr) eq 'HASH';

    my $fg = defined($attr->{fg}) ? $attr->{fg} : $def_fg;
    my $bg = defined($attr->{bg}) ? $attr->{bg} : $def_bg;
    if ($attr->{reverse}) {
        ($fg, $bg) = ($bg, $fg);
    }
    return ($fg, $bg, $attr);
}

# ---------------------------------------------------------------------------
# Process Spawn & Msgpack-RPC Handshake
# ---------------------------------------------------------------------------

sub connect {
    my ($self, %opts) = @_;
    return 1 if $self->{connected};

    $self->{cols} = int($opts{cols}) if defined $opts{cols} && $opts{cols} >= 20;
    $self->{rows} = int($opts{rows}) if defined $opts{rows} && $opts{rows} >= 6;
    $self->_init_grid(1, $self->{cols}, $self->{rows});

    my $use_mock = 0;
    my $nvim_bin;
    if ($self->{mock} && $self->{mock} ne 'auto') {
        $use_mock = 1;
    }
    else {
        $nvim_bin = ref($self)->find_nvim_bin($self->{nvim_bin});
        if (!$nvim_bin) {
            if (($self->{mock} // '') eq 'auto') {
                $use_mock = 1;
            }
            else {
                croak "NvimBridge: 'nvim' binary not found (install Neovim or pass mock => 1)";
            }
        }
    }

    croak "NvimBridge: pipe/fork transport requires POSIX fork" if $^O eq 'MSWin32';

    pipe(my $child_rd,  my $parent_wr) or croak "NvimBridge: pipe(stdin) failed: $!";
    pipe(my $parent_rd, my $child_wr)  or croak "NvimBridge: pipe(stdout) failed: $!";

    for my $fh ($child_rd, $parent_wr, $parent_rd, $child_wr) {
        binmode($fh, ':raw');
        $fh->autoflush(1);
    }

    my @cmd_args;
    if (!$use_mock) {
        if (ref($self->{args}) eq 'ARRAY') {
            @cmd_args = @{ $self->{args} };
        }
        else {
            @cmd_args = ('--embed', '--headless', '-n');
            push @cmd_args, '--clean' if $self->{clean};
        }
    }

    my $pid = fork();
    croak "NvimBridge: fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        CORE::close($parent_wr);
        CORE::close($parent_rd);
        if ($use_mock) {
            eval { _run_mock_server($child_rd, $child_wr, $self->{cwd}) };
            POSIX::_exit(0);
        }
        open(STDIN,  '<&', $child_rd) or POSIX::_exit(126);
        open(STDOUT, '>&', $child_wr) or POSIX::_exit(126);
        open(STDERR, '>', File::Spec->devnull());
        CORE::close($child_rd);
        CORE::close($child_wr);
        if (defined $self->{cwd} && -d $self->{cwd}) {
            chdir($self->{cwd});
        }
        exec { $nvim_bin } $nvim_bin, @cmd_args or POSIX::_exit(127);
    }

    CORE::close($child_rd);
    CORE::close($child_wr);

    $parent_rd->blocking(0);
    my $flags = fcntl($parent_rd, F_GETFL, 0);
    fcntl($parent_rd, F_SETFL, $flags | O_NONBLOCK) if defined $flags;

    $self->{pid}       = $pid;
    $self->{in_fh}     = $parent_wr;
    $self->{out_fh}    = $parent_rd;
    $self->{sel}       = IO::Select->new($parent_rd);
    $self->{rx_buf}    = '';
    $self->{responses} = {};
    $self->{is_mock}   = $use_mock ? 1 : 0;
    $self->{connected} = 1;
    $self->{_closed}   = 0;

    # 1. nvim_get_api_info
    my $info = $self->request('nvim_get_api_info');
    if (ref($info) eq 'ARRAY' && @$info >= 2) {
        $self->{channel_id} = $info->[0];
        $self->{api_info}   = $info->[1];
        if (ref($info->[1]) eq 'HASH' && ref($info->[1]{version}) eq 'HASH') {
            my $v = $info->[1]{version};
            $self->{version} = $v;
            my $vs = sprintf('%d.%d.%d', $v->{major} // 0, $v->{minor} // 0, $v->{patch} // 0);
            $self->{version_str} = $use_mock ? "mock-$vs" : $vs;
        }
    }

    # 2. nvim_ui_attach with ext_linegrid + rgb
    my $ui_opts = {
        ext_linegrid => _mp_bool(1),
        rgb          => _mp_bool(1),
    };
    $self->request('nvim_ui_attach', $self->{cols}, $self->{rows}, $ui_opts);

    # Pump until initial redraw flush arrives (short bounded wait)
    my $deadline = time() + 1.0;
    while ($self->{flush_count} == 0 && time() < $deadline) {
        $self->pump(0.02);
    }

    return 1;
}

# ---------------------------------------------------------------------------
# Msgpack-RPC Wire Layer
# ---------------------------------------------------------------------------

sub _write_all {
    my ($self, $bytes) = @_;
    croak "NvimBridge: not connected" unless $self->{connected} && $self->{in_fh};
    local $SIG{PIPE} = 'IGNORE';
    my $len = length($bytes);
    my $off = 0;
    while ($off < $len) {
        my $n = syswrite($self->{in_fh}, $bytes, $len - $off, $off);
        if (!defined $n) {
            next if $!{EINTR};
            if ($!{EAGAIN} || $!{EWOULDBLOCK}) {
                sleep(0.002);
                next;
            }
            croak "NvimBridge: write failed: $!";
        }
        croak "NvimBridge: short write EOF" if $n == 0;
        $off += $n;
    }
    return $len;
}

sub _decode_rx_buf {
    my ($self) = @_;
    return [] unless length $self->{rx_buf};
    my ($items, $rem) = NeoPerl::Core::Msgpack::decode_stream(\$self->{rx_buf});
    if (defined $rem && !ref($rem)) {
        $self->{rx_buf} = $rem;
    }
    return ref($items) eq 'ARRAY' ? $items : [];
}

sub _dispatch_message {
    my ($self, $msg) = @_;
    return 0 unless ref($msg) eq 'ARRAY' && @$msg >= 3;
    my $type = int($msg->[0] // -1);

    if ($type == 1 && @$msg >= 4) {
        # Response: [1, msgid, error, result]
        my ($msgid, $err, $res) = @{$msg}[1, 2, 3];
        $self->{responses}{$msgid} = [ $err, $res ];
        return 1;
    }
    elsif ($type == 2) {
        # Notification: [2, method, params]
        my ($method, $params) = @{$msg}[1, 2];
        if (defined $method && $method eq 'redraw') {
            $self->_handle_redraw($params);
        }
        else {
            push @{ $self->{notifications} }, [ $method, $params ];
            shift @{ $self->{notifications} } if @{ $self->{notifications} } > 64;
        }
        return 1;
    }
    elsif ($type == 0 && @$msg >= 4) {
        # Inbound request from Neovim: [0, msgid, method, params] -> reply cleanly
        my $msgid = $msg->[1];
        my $reply = NeoPerl::Core::Msgpack::encode([ 1, $msgid, undef, undef ]);
        eval { $self->_write_all($reply) };
        return 1;
    }
    return 0;
}

sub pump {
    my ($self, $timeout) = @_;
    return 0 unless $self->{connected} && $self->{out_fh} && $self->{sel};
    $timeout = 0 unless defined $timeout;

    my $count = 0;
    my $wait  = $timeout;
    while (1) {
        my @ready = $self->{sel}->can_read($wait);
        last unless @ready;
        $wait = 0; # drain all immediately available bytes

        my $eof = 0;
        while (1) {
            my $chunk = '';
            my $n = sysread($self->{out_fh}, $chunk, 65536);
            if (!defined $n) {
                next if $!{EINTR};
                last if $!{EAGAIN} || $!{EWOULDBLOCK};
                $eof = 1;
                last;
            }
            if ($n == 0) {
                $eof = 1;
                last;
            }
            $self->{rx_buf} .= $chunk;
        }

        my $items = $self->_decode_rx_buf();
        for my $msg (@$items) {
            $count += $self->_dispatch_message($msg);
        }

        if ($eof) {
            $self->{connected} = 0;
            last;
        }
        last unless $self->{sel}->can_read(0);
    }

    return $count;
}

sub request {
    my ($self, $method, @params) = @_;
    croak "NvimBridge: not connected" unless $self->{connected};

    my $msgid = $self->{next_msgid}++;
    my $frame = NeoPerl::Core::Msgpack::encode([ 0, $msgid, $method, \@params ]);
    $self->_write_all($frame);

    my $deadline = time() + ($self->{timeout} || 5.0);
    while (!exists $self->{responses}{$msgid}) {
        my $rem = $deadline - time();
        croak "NvimBridge: timeout waiting for RPC '$method' (msgid=$msgid)" if $rem <= 0;
        my $slice = $rem > 0.05 ? 0.05 : $rem;
        $self->pump($slice);
        if (!$self->{connected} && !exists $self->{responses}{$msgid}) {
            croak "NvimBridge: connection closed waiting for RPC '$method'";
        }
    }

    my $pair = delete $self->{responses}{$msgid};
    my ($err, $res) = @$pair;
    if (defined $err) {
        my $emsg = ref($err) eq 'ARRAY' ? join(': ', grep { defined } @$err) : "$err";
        croak "NvimBridge RPC error ($method): $emsg";
    }
    return $res;
}

sub notify {
    my ($self, $method, @params) = @_;
    croak "NvimBridge: not connected" unless $self->{connected};
    my $frame = NeoPerl::Core::Msgpack::encode([ 2, $method, \@params ]);
    $self->_write_all($frame);
    return 1;
}

# ---------------------------------------------------------------------------
# High-Level Neovim API Wrappers
# ---------------------------------------------------------------------------

sub sync {
    my ($self, $pump_s) = @_;
    return 0 unless $self->{connected};
    $self->request('nvim_eval', '1');
    $self->pump(defined($pump_s) ? $pump_s : 0.02);
    return 1;
}

sub resize {
    my ($self, $cols, $rows) = @_;
    $cols = int($cols || $self->{cols});
    $rows = int($rows || $self->{rows});
    $cols = 20 if $cols < 20;
    $rows = 6  if $rows < 6;
    return 1 if $cols == $self->{cols} && $rows == $self->{rows} && $self->{flush_count} > 0;
    $self->{cols} = $cols;
    $self->{rows} = $rows;
    $self->request('nvim_ui_try_resize', $cols, $rows);
    $self->pump(0.03);
    return 1;
}

sub input {
    my ($self, $keys) = @_;
    return 0 unless defined $keys && length $keys;
    my $n = $self->request('nvim_input', $keys);
    # Round-trip sync ensures Neovim finishes processing keystrokes & emits redraw
    $self->request('nvim_eval', '1');
    $self->pump(0.03);
    return $n;
}

sub command {
    my ($self, $ex) = @_;
    return undef unless defined $ex && length $ex;
    my $res = $self->request('nvim_command', $ex);
    $self->pump(0.02);
    return $res;
}

sub eval {
    my ($self, $expr) = @_;
    return $self->request('nvim_eval', $expr);
}

sub buf_get_lines {
    my ($self, $buf, $start, $end, $strict) = @_;
    $buf   //= 0;
    $start //= 0;
    $end   //= -1;
    return $self->request('nvim_buf_get_lines', $buf, int($start), int($end), _mp_bool($strict ? 1 : 0));
}

sub buf_set_lines {
    my ($self, $buf, $start, $end, $lines, $strict) = @_;
    $buf   //= 0;
    $start //= 0;
    $end   //= -1;
    $lines ||= [];
    my $res = $self->request('nvim_buf_set_lines', $buf, int($start), int($end), _mp_bool($strict ? 1 : 0), $lines);
    $self->pump(0.02);
    return $res;
}

sub buf_get_name {
    my ($self, $buf) = @_;
    $buf //= 0;
    return $self->request('nvim_buf_get_name', $buf);
}

sub get_option_value {
    my ($self, $name, $opts) = @_;
    my $res = eval { $self->request('nvim_get_option_value', $name, $opts || {}) };
    return $res unless $@;
    return eval { $self->request('nvim_buf_get_option', 0, $name) };
}

sub create_namespace {
    my ($self, $name) = @_;
    return $self->request('nvim_create_namespace', $name // '');
}

sub buf_set_extmark {
    my ($self, $buf, $ns, $line, $col, $opts) = @_;
    $buf //= 0;
    my $id = $self->request('nvim_buf_set_extmark', $buf, int($ns), int($line), int($col), $opts || {});
    $self->pump(0.02);
    return $id;
}

sub buf_get_extmarks {
    my ($self, $buf, $ns, $start, $end, $opts) = @_;
    $buf   //= 0;
    $start //= 0;
    $end   //= -1;
    return $self->request('nvim_buf_get_extmarks', $buf, int($ns), $start, $end, $opts || {});
}

sub buf_clear_namespace {
    my ($self, $buf, $ns, $start, $end) = @_;
    $buf   //= 0;
    $start //= 0;
    $end   //= -1;
    return $self->request('nvim_buf_clear_namespace', $buf, int($ns), int($start), int($end));
}

sub win_get_cursor {
    my ($self, $win) = @_;
    $win //= 0;
    my $pos = $self->request('nvim_win_get_cursor', $win);
    $self->{buf_cursor} = [ @$pos ] if ref($pos) eq 'ARRAY' && @$pos >= 2;
    return $pos;
}

sub win_set_cursor {
    my ($self, $win, $row_1based, $col_0based) = @_;
    $win //= 0;
    my $r = int($row_1based || 1);
    my $c = int($col_0based || 0);
    my $res = $self->request('nvim_win_set_cursor', $win, [ $r, $c ]);
    $self->{buf_cursor} = [ $r, $c ];
    $self->pump(0.02);
    return $res;
}

sub get_mode {
    my ($self) = @_;
    return $self->request('nvim_get_mode');
}

sub list_bufs {
    my ($self) = @_;
    return $self->request('nvim_list_bufs');
}

sub get_current_buf {
    my ($self) = @_;
    return $self->request('nvim_get_current_buf');
}

# Stage / accept / reject reviewable Antigravity diff proposal against embedded Neovim buffer
sub stage_proposal {
    my ($self, $new_text, %meta) = @_;
    my $old_lines = $self->buf_get_lines(0, 0, -1) || [];
    my @new_lines = split /\n/, ($new_text // ''), -1;
    pop @new_lines if @new_lines > 1 && $new_lines[-1] eq '';

    my $old_joined = join("\n", @$old_lines);
    my $new_joined = join("\n", @new_lines);
    my @hunks;
    if (defined(&NeoPerl::Core::Diff::diff_lines)) {
        my $dh = eval { NeoPerl::Core::Diff::diff_lines($old_joined, $new_joined) };
        @hunks = @$dh if ref($dh) eq 'ARRAY';
    }
    if (!@hunks && $old_joined ne $new_joined) {
        push @hunks, {
            kind      => 'change',
            old_start => 1,
            old_count => scalar(@$old_lines),
            new_start => 1,
            new_count => scalar(@new_lines),
        };
    }

    $self->{staged_proposal} = {
        new_lines => \@new_lines,
        new_text  => $new_text // '',
        hunks     => \@hunks,
        title     => $meta{title}  // 'Antigravity Proposed Edit',
        source    => $meta{source} // 'antigravity',
    };

    # Annotate proposed hunk in Neovim via an extmark virtual text hint
    if (@hunks) {
        $self->{_proposal_ns} //= $self->create_namespace('neoperl_proposal');
        eval { $self->buf_clear_namespace(0, $self->{_proposal_ns}, 0, -1) };
        my $hline = ($hunks[0]{old_start} // 1) - 1;
        $hline = 0 if $hline < 0;
        my $max_l = @$old_lines ? $#$old_lines : 0;
        $hline = $max_l if $hline > $max_l;
        my $vtxt = sprintf('  [Antigravity: %d staged hunk(s) - :AgyAccept / :AgyReject]', scalar(@hunks));
        eval {
            $self->buf_set_extmark(0, $self->{_proposal_ns}, $hline, 0, {
                virt_text     => [ [ $vtxt, 'DiagnosticInfo' ] ],
                virt_text_pos => 'eol',
            });
        };
    }

    return {
        hunks => \@hunks,
        count => scalar(@hunks),
    };
}

sub accept_staged_proposal {
    my ($self) = @_;
    my $prop = delete $self->{staged_proposal} or return 0;
    if (defined $self->{_proposal_ns}) {
        eval { $self->buf_clear_namespace(0, $self->{_proposal_ns}, 0, -1) };
    }
    $self->buf_set_lines(0, 0, -1, $prop->{new_lines});
    return 1;
}

sub reject_staged_proposal {
    my ($self) = @_;
    return 0 unless delete $self->{staged_proposal};
    if (defined $self->{_proposal_ns}) {
        eval { $self->buf_clear_namespace(0, $self->{_proposal_ns}, 0, -1) };
    }
    return 1;
}

# Configure Neovim highlight groups to match NeoPerl's active theme (AIX Amber default)
sub apply_theme {
    my ($self, $theme) = @_;
    return 0 unless $self->{connected} && ref($theme) eq 'HASH';

    my $fg   = _normalize_hex($theme->{fg},           '#ffb000');
    my $bg   = _normalize_hex($theme->{bg},           '#000000');
    my $bgd  = _normalize_hex($theme->{bg_dark},      '#080500');
    my $bgh  = _normalize_hex($theme->{bg_highlight}, '#1c1200');
    my $bgv  = _normalize_hex($theme->{bg_visual},    '#3b2600');
    my $fgg  = _normalize_hex($theme->{fg_gutter},    '#6b4700');
    my $syn  = $theme->{syntax} || {};
    my $kw   = _normalize_hex($syn->{keyword},        '#ffd873');
    my $str  = _normalize_hex($syn->{string},         '#e6a84c');
    my $cmt  = _normalize_hex($syn->{comment},        '#7a4f00');
    my $num  = _normalize_hex($syn->{number},         '#ff9500');
    my $fn   = _normalize_hex($syn->{function},       '#ffe49e');
    my $typ  = _normalize_hex($syn->{type},           '#ffcc66');
    my $var  = _normalize_hex($syn->{variable},       '#ffb000');
    my $pp   = _normalize_hex($syn->{preprocessor},   '#ff8800');
    my $derr = _normalize_hex($theme->{diag_error},   '#ff4d4d');
    my $dwrn = _normalize_hex($theme->{diag_warn},    '#ffd166');
    my $dinf = _normalize_hex($theme->{diag_info},    '#ff9f1c');
    my $addb = _normalize_hex($theme->{diff_add_bg},  '#0f240f');
    my $delb = _normalize_hex($theme->{diff_del_bg},  '#2b0d0d');

    $self->{default_fg} = $fg;
    $self->{default_bg} = $bg;

    my @cmds = (
        'syntax enable',
        'set termguicolors number cursorline signcolumn=yes laststatus=0 noshowmode noruler shortmess+=I',
        "hi Normal guifg=$fg guibg=$bg",
        "hi NormalNC guifg=$fg guibg=$bg",
        "hi LineNr guifg=$fgg guibg=$bgd",
        "hi CursorLineNr guifg=$kw guibg=$bgh gui=bold",
        "hi CursorLine guibg=$bgh gui=NONE",
        "hi SignColumn guifg=$fgg guibg=$bgd",
        "hi Visual guibg=$bgv",
        "hi Comment guifg=$cmt gui=italic",
        "hi Statement guifg=$kw gui=bold",
        "hi Keyword guifg=$kw gui=bold",
        "hi Conditional guifg=$kw gui=bold",
        "hi Repeat guifg=$kw gui=bold",
        "hi String guifg=$str",
        "hi Number guifg=$num",
        "hi Constant guifg=$num",
        "hi Function guifg=$fn",
        "hi Identifier guifg=$var",
        "hi Type guifg=$typ",
        "hi PreProc guifg=$pp",
        "hi Special guifg=$fn",
        "hi Operator guifg=$kw",
        "hi NonText guifg=$fgg guibg=$bg",
        "hi EndOfBuffer guifg=$fgg guibg=$bg",
        "hi MsgArea guifg=$fg guibg=$bg",
        "hi DiagnosticError guifg=$derr",
        "hi DiagnosticWarn guifg=$dwrn",
        "hi DiagnosticInfo guifg=$dinf",
        "hi DiffAdd guibg=$addb",
        "hi DiffDelete guibg=$delb",
    );

    eval { $self->command(join(' | ', @cmds)) };
    $self->pump(0.03);
    return 1;
}

# ---------------------------------------------------------------------------
# ext_linegrid Redraw Notification Parser
# ---------------------------------------------------------------------------

sub _init_grid {
    my ($self, $grid_id, $w, $h) = @_;
    $w = 1 if !$w || $w < 1;
    $h = 1 if !$h || $h < 1;
    my @rows;
    for my $r (0 .. $h - 1) {
        my @row;
        for my $c (0 .. $w - 1) {
            push @row, [ ' ', 0 ];
        }
        push @rows, \@row;
    }
    $self->{grids}{$grid_id} = {
        id     => $grid_id,
        width  => $w,
        height => $h,
        rows   => \@rows,
    };
    return $self->{grids}{$grid_id};
}

sub _handle_redraw {
    my ($self, $events) = @_;
    return unless ref($events) eq 'ARRAY';

    for my $ev (@$events) {
        next unless ref($ev) eq 'ARRAY' && @$ev >= 1;
        my $name = $ev->[0];
        next unless defined $name;

        for my $ti (1 .. $#$ev) {
            my $t = $ev->[$ti];
            next unless ref($t) eq 'ARRAY';

            if ($name eq 'default_colors_set') {
                my ($rgb_fg, $rgb_bg, $rgb_sp) = @{$t}[0, 1, 2];
                my $fg = _rgb_to_hex($rgb_fg);
                my $bg = _rgb_to_hex($rgb_bg);
                my $sp = _rgb_to_hex($rgb_sp);
                $self->{default_fg} = $fg if defined $fg;
                $self->{default_bg} = $bg if defined $bg;
                $self->{default_sp} = $sp if defined $sp;
            }
            elsif ($name eq 'hl_attr_define') {
                my ($id, $rgb_attrs) = @{$t}[0, 1];
                next unless defined $id;
                my %entry;
                if (ref($rgb_attrs) eq 'HASH') {
                    $entry{fg}            = _rgb_to_hex($rgb_attrs->{foreground}) if defined $rgb_attrs->{foreground};
                    $entry{bg}            = _rgb_to_hex($rgb_attrs->{background}) if defined $rgb_attrs->{background};
                    $entry{sp}            = _rgb_to_hex($rgb_attrs->{special})    if defined $rgb_attrs->{special};
                    $entry{reverse}       = $rgb_attrs->{reverse}       ? 1 : 0;
                    $entry{bold}          = $rgb_attrs->{bold}          ? 1 : 0;
                    $entry{italic}        = $rgb_attrs->{italic}        ? 1 : 0;
                    $entry{underline}     = ($rgb_attrs->{underline} || $rgb_attrs->{undercurl}) ? 1 : 0;
                    $entry{strikethrough} = $rgb_attrs->{strikethrough} ? 1 : 0;
                }
                $self->{hl_attrs}{$id} = \%entry;
            }
            elsif ($name eq 'grid_resize') {
                my ($gid, $w, $h) = @{$t}[0, 1, 2];
                $gid ||= 1;
                $self->_init_grid($gid, int($w || 1), int($h || 1));
                if ($gid == 1) {
                    $self->{cols} = int($w || $self->{cols});
                    $self->{rows} = int($h || $self->{rows});
                }
            }
            elsif ($name eq 'grid_clear') {
                my ($gid) = @{$t}[0];
                $gid ||= 1;
                my $g = $self->{grids}{$gid} || $self->_init_grid($gid, $self->{cols}, $self->{rows});
                for my $row (@{ $g->{rows} }) {
                    for my $cell (@$row) {
                        $cell->[0] = ' ';
                        $cell->[1] = 0;
                    }
                }
            }
            elsif ($name eq 'grid_line') {
                my ($gid, $row_idx, $col_start, $cells) = @{$t}[0, 1, 2, 3];
                $gid ||= 1;
                my $g = $self->{grids}{$gid} || $self->_init_grid($gid, $self->{cols}, $self->{rows});
                next if !defined($row_idx) || $row_idx < 0 || $row_idx >= $g->{height};
                next unless ref($cells) eq 'ARRAY';

                my $row = $g->{rows}[$row_idx];
                my $w   = $g->{width};
                my $col = int($col_start || 0);
                my $cur_hl = 0;

                for my $ct (@$cells) {
                    next unless ref($ct) eq 'ARRAY' && @$ct >= 1;
                    my $text = defined($ct->[0]) ? $ct->[0] : ' ';
                    if (@$ct >= 2 && defined $ct->[1]) {
                        $cur_hl = int($ct->[1]);
                    }
                    my $rep = (@$ct >= 3 && defined $ct->[2]) ? int($ct->[2]) : 1;
                    $rep = 0 if $rep < 0;
                    for (my $k = 0; $k < $rep && $col < $w; $k++, $col++) {
                        next if $col < 0;
                        $row->[$col][0] = $text;
                        $row->[$col][1] = $cur_hl;
                    }
                }
            }
            elsif ($name eq 'grid_scroll') {
                my ($gid, $top, $bot, $left, $right, $rows, $cols) = @{$t}[0 .. 6];
                $gid ||= 1;
                my $g = $self->{grids}{$gid} or next;
                $top   = 0             if !defined($top)   || $top < 0;
                $bot   = $g->{height}  if !defined($bot)   || $bot > $g->{height};
                $left  = 0             if !defined($left)  || $left < 0;
                $right = $g->{width}   if !defined($right) || $right > $g->{width};
                $rows  = int($rows || 0);
                next if $rows == 0 || $top >= $bot || $left >= $right;

                my $grows = $g->{rows};
                if ($rows > 0) {
                    # Scroll up: src = dst + rows
                    for my $r ($top .. $bot - 1) {
                        my $src = $r + $rows;
                        if ($src < $bot) {
                            for my $c ($left .. $right - 1) {
                                $grows->[$r][$c][0] = $grows->[$src][$c][0];
                                $grows->[$r][$c][1] = $grows->[$src][$c][1];
                            }
                        }
                        else {
                            for my $c ($left .. $right - 1) {
                                $grows->[$r][$c][0] = ' ';
                                $grows->[$r][$c][1] = 0;
                            }
                        }
                    }
                }
                else {
                    # Scroll down: rows < 0, src = dst + rows (smaller index)
                    my $shift = -$rows;
                    for (my $r = $bot - 1; $r >= $top; $r--) {
                        my $src = $r - $shift;
                        if ($src >= $top) {
                            for my $c ($left .. $right - 1) {
                                $grows->[$r][$c][0] = $grows->[$src][$c][0];
                                $grows->[$r][$c][1] = $grows->[$src][$c][1];
                            }
                        }
                        else {
                            for my $c ($left .. $right - 1) {
                                $grows->[$r][$c][0] = ' ';
                                $grows->[$r][$c][1] = 0;
                            }
                        }
                    }
                }
            }
            elsif ($name eq 'grid_cursor_goto') {
                my ($gid, $r, $c) = @{$t}[0, 1, 2];
                $self->{cursor_grid} = $gid || 1;
                $self->{cursor_row}  = int($r || 0);
                $self->{cursor_col}  = int($c || 0);
            }
            elsif ($name eq 'mode_info_set') {
                my ($enabled, $info) = @{$t}[0, 1];
                $self->{cursor_style_enabled} = $enabled ? 1 : 0;
                $self->{mode_info} = ref($info) eq 'ARRAY' ? $info : [];
            }
            elsif ($name eq 'mode_change') {
                my ($mname, $midx) = @{$t}[0, 1];
                $self->{mode_name} = $mname // 'normal';
                $self->{mode_idx}  = int($midx || 0);
            }
            elsif ($name eq 'flush') {
                $self->{flush_count}++;
                $self->{dirty} = 1;
            }
            elsif ($name eq 'grid_destroy') {
                my ($gid) = @{$t}[0];
                delete $self->{grids}{$gid} if defined $gid && $gid != 1;
            }
        }
    }
    return;
}

# ---------------------------------------------------------------------------
# Clean Shutdown
# ---------------------------------------------------------------------------

sub close {
    my ($self) = @_;
    return 1 if $self->{_closed};
    $self->{_closed} = 1;

    if ($self->{connected}) {
        eval { $self->notify('nvim_ui_detach') };
        eval { $self->notify('nvim_command', 'qa!') };
        $self->{connected} = 0;
    }

    if ($self->{in_fh}) {
        eval { CORE::close($self->{in_fh}) };
        $self->{in_fh} = undef;
    }
    if ($self->{out_fh}) {
        eval { CORE::close($self->{out_fh}) };
        $self->{out_fh} = undef;
    }
    $self->{sel} = undef;

    if (defined $self->{pid} && $self->{pid} > 0) {
        my $pid = $self->{pid};
        my $reaped = 0;
        for (1 .. 25) {
            my $r = waitpid($pid, POSIX::WNOHANG());
            if ($r == $pid || $r == -1) {
                $reaped = 1;
                last;
            }
            sleep(0.01);
        }
        if (!$reaped) {
            kill('TERM', $pid);
            for (1 .. 15) {
                my $r = waitpid($pid, POSIX::WNOHANG());
                if ($r == $pid || $r == -1) {
                    $reaped = 1;
                    last;
                }
                sleep(0.01);
            }
        }
        if (!$reaped) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
        $self->{pid} = undef;
    }
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT';
    eval { $self->close() };
    return;
}

# ---------------------------------------------------------------------------
# Protocol-Identical Offline Msgpack-RPC Mock Neovim Server (for CI / no-nvim)
# ---------------------------------------------------------------------------

sub _mock_write_all {
    my ($fh, $bytes) = @_;
    my $len = length($bytes);
    my $off = 0;
    while ($off < $len) {
        my $n = syswrite($fh, $bytes, $len - $off, $off);
        return 0 unless defined $n && $n > 0;
        $off += $n;
    }
    return 1;
}

sub _mock_tokenize_keys {
    my ($keys) = @_;
    my @toks;
    my $pos = 0;
    my $len = length($keys // '');
    while ($pos < $len) {
        my $ch = substr($keys, $pos, 1);
        if ($ch eq '<') {
            my $end = index($keys, '>', $pos + 1);
            if ($end > $pos) {
                push @toks, substr($keys, $pos, $end - $pos + 1);
                $pos = $end + 1;
                next;
            }
        }
        push @toks, $ch;
        $pos++;
    }
    return @toks;
}

sub _run_mock_server {
    my ($rd, $wr, $cwd) = @_;
    local $SIG{PIPE} = 'IGNORE';

    my %st = (
        cols       => 80,
        rows       => 24,
        attached   => 0,
        lines      => [''],
        buf_name   => '',
        filetype   => '',
        modified   => 0,
        mode       => 'n',     # n | i | c
        cur_row    => 0,
        cur_col    => 0,
        pending    => '',
        cmdline    => '',
        next_ns    => 1,
        next_em    => 1,
        extmarks   => {},      # ns => [ { id, line, col, opts } ]
        hl_normal  => 0,
        hl_kw      => 1,
        hl_gutter  => 2,
        hl_virt    => 3,
        hl_tildes  => 4,
    );

    my $send_frame = sub {
        my ($payload) = @_;
        my $bin = NeoPerl::Core::Msgpack::encode($payload);
        _mock_write_all($wr, $bin);
    };

    my $emit_redraw = sub {
        my ($full) = @_;
        return unless $st{attached};
        my @evs;
        if ($full) {
            push @evs, [ 'default_colors_set', [ 0xffb000, 0x000000, 0xff8800, -1, -1 ] ];
            push @evs, [ 'hl_attr_define',
                [ 1, { foreground => 0xffd873, bold => _mp_bool(1) }, {}, [] ],
                [ 2, { foreground => 0x6b4700, background => 0x080500 }, {}, [] ],
                [ 3, { foreground => 0xff9f1c }, {}, [] ],
                [ 4, { foreground => 0x4a3000 }, {}, [] ],
            ];
            push @evs, [ 'mode_info_set', [
                _mp_bool(1),
                [
                    { name => 'normal',         short_name => 'n', cursor_shape => 'block' },
                    { name => 'insert',         short_name => 'i', cursor_shape => 'vertical' },
                    { name => 'replace',        short_name => 'r', cursor_shape => 'horizontal' },
                    { name => 'cmdline_normal', short_name => 'c', cursor_shape => 'vertical' },
                ],
            ] ];
            push @evs, [ 'grid_resize', [ 1, $st{cols}, $st{rows} ] ];
        }
        push @evs, [ 'grid_clear', [1] ];

        # Collect EOL extmark virtual texts by line
        my %virt_by_line;
        for my $ns (keys %{ $st{extmarks} }) {
            for my $em (@{ $st{extmarks}{$ns} }) {
                if (ref($em->{opts}{virt_text}) eq 'ARRAY') {
                    my $txt = join('', map { ref($_) eq 'ARRAY' ? ($_->[0] // '') : '' } @{ $em->{opts}{virt_text} });
                    $virt_by_line{ $em->{line} } .= $txt if length $txt;
                }
            }
        }

        my @grid_line_tuples;
        my $lines = $st{lines};
        my $max_r = $st{rows};
        my $w     = $st{cols};
        for my $r (0 .. $max_r - 1) {
            my @cells;
            if ($r < @$lines) {
                my $ltxt = $lines->[$r] // '';
                my $vtxt = $virt_by_line{$r} // '';
                my $col  = 0;
                my $len  = length($ltxt);
                for my $i (0 .. $len - 1) {
                    last if $col >= $w;
                    my $ch = substr($ltxt, $i, 1);
                    if ($i == 0) {
                        push @cells, [ $ch, 0 ];
                    }
                    else {
                        # Omitting hl_id exercises hl carry-forward in grid_line parser
                        push @cells, [ $ch ];
                    }
                    $col++;
                }
                if (length($vtxt) && $col < $w) {
                    for my $i (0 .. length($vtxt) - 1) {
                        last if $col >= $w;
                        my $ch = substr($vtxt, $i, 1);
                        push @cells, ($i == 0 ? [ $ch, 3 ] : [ $ch ]);
                        $col++;
                    }
                }
                if ($col < $w) {
                    # Use Neovim ext_linegrid repeat count cell
                    push @cells, [ ' ', 0, $w - $col ];
                }
            }
            else {
                push @cells, [ '~', 4 ];
                push @cells, [ ' ', 0, $w - 1 ] if $w > 1;
            }
            push @grid_line_tuples, [ 1, $r, 0, \@cells, _mp_bool(0) ];
        }
        push @evs, [ 'grid_line', @grid_line_tuples ] if @grid_line_tuples;

        my ($mname, $midx) = $st{mode} eq 'i' ? ('insert', 1)
                           : $st{mode} eq 'R' ? ('replace', 2)
                           : $st{mode} eq 'c' ? ('cmdline_normal', 3)
                           : ('normal', 0);
        push @evs, [ 'mode_change', [ $mname, $midx ] ];
        push @evs, [ 'grid_cursor_goto', [ 1, $st{cur_row}, $st{cur_col} ] ];
        push @evs, [ 'flush', [] ];

        $send_frame->([ 2, 'redraw', \@evs ]);
    };

    my $clamp_cursor = sub {
        my $lines = $st{lines};
        @$lines = ('') unless @$lines;
        $st{cur_row} = 0 if $st{cur_row} < 0;
        $st{cur_row} = $#$lines if $st{cur_row} > $#$lines;
        my $llen = length($lines->[ $st{cur_row} ] // '');
        my $max_c = ($st{mode} eq 'i') ? $llen : ($llen > 0 ? $llen - 1 : 0);
        $st{cur_col} = 0      if $st{cur_col} < 0;
        $st{cur_col} = $max_c if $st{cur_col} > $max_c;
    };

    my $exec_cmd = sub {
        my ($cmd) = @_;
        $cmd //= '';
        $cmd =~ s/\A\s*:?\s*|\s+\z//g;
        if ($cmd =~ /\A(?:qa!?|q!?)\z/) {
            return 'quit';
        }
        elsif ($cmd =~ /\Aenew!?\z/) {
            $st{lines}    = [''];
            $st{cur_row}  = 0;
            $st{cur_col}  = 0;
            $st{buf_name} = '';
            $st{modified} = 0;
        }
        elsif ($cmd =~ /\A(?:e|edit)!?\s+(.+)\z/) {
            my $p = $1;
            $p =~ s/\A['"]|['"]\z//g;
            $st{buf_name} = $p;
            if (-f $p && open my $fh, '<', $p) {
                my @ls = map { s/\r?\n\z//; $_ } <$fh>;
                CORE::close($fh);
                $st{lines} = @ls ? \@ls : [''];
                $st{cur_row} = 0;
                $st{cur_col} = 0;
                $st{modified} = 0;
            }
        }
        elsif ($cmd =~ /\bset\b.*\b(?:ft|filetype)=([A-Za-z0-9_+-]+)/) {
            $st{filetype} = $1;
        }
        return 'ok';
    };

    my $feed_input = sub {
        my ($keys) = @_;
        my @toks = _mock_tokenize_keys($keys);
        my $lines = $st{lines};

        for my $tok (@toks) {
            if ($st{mode} eq 'i') {
                if ($tok eq '<Esc>' || $tok eq "\e") {
                    $st{mode} = 'n';
                    $st{cur_col}-- if $st{cur_col} > 0;
                    $clamp_cursor->();
                }
                elsif ($tok eq '<CR>' || $tok eq "\r" || $tok eq "\n") {
                    my $ln = $lines->[ $st{cur_row} ] // '';
                    my $left  = substr($ln, 0, $st{cur_col});
                    my $right = substr($ln, $st{cur_col});
                    $lines->[ $st{cur_row} ] = $left;
                    splice(@$lines, $st{cur_row} + 1, 0, $right);
                    $st{cur_row}++;
                    $st{cur_col} = 0;
                    $st{modified} = 1;
                }
                elsif ($tok eq '<BS>' || $tok eq "\x7f") {
                    if ($st{cur_col} > 0) {
                        my $ln = $lines->[ $st{cur_row} ];
                        substr($ln, $st{cur_col} - 1, 1, '');
                        $lines->[ $st{cur_row} ] = $ln;
                        $st{cur_col}--;
                        $st{modified} = 1;
                    }
                    elsif ($st{cur_row} > 0) {
                        my $prev = $lines->[ $st{cur_row} - 1 ];
                        my $cur  = splice(@$lines, $st{cur_row}, 1);
                        $st{cur_row}--;
                        $st{cur_col} = length($prev);
                        $lines->[ $st{cur_row} ] = $prev . $cur;
                        $st{modified} = 1;
                    }
                }
                elsif (length($tok) == 1) {
                    my $ln = $lines->[ $st{cur_row} ] // '';
                    substr($ln, $st{cur_col}, 0, $tok);
                    $lines->[ $st{cur_row} ] = $ln;
                    $st{cur_col}++;
                    $st{modified} = 1;
                }
                next;
            }

            if ($st{mode} eq 'c') {
                if ($tok eq '<Esc>' || $tok eq "\e") {
                    $st{mode} = 'n';
                    $st{cmdline} = '';
                }
                elsif ($tok eq '<CR>' || $tok eq "\r" || $tok eq "\n") {
                    $exec_cmd->($st{cmdline});
                    $st{cmdline} = '';
                    $st{mode} = 'n';
                }
                elsif (length($tok) == 1) {
                    $st{cmdline} .= $tok;
                }
                next;
            }

            # Normal mode
            if ($tok eq '<Esc>' || $tok eq "\e") {
                $st{pending} = '';
                next;
            }
            my $seq = $st{pending} . $tok;
            $st{pending} = '';

            if ($seq eq 'c' || $seq eq 'd' || $seq eq 'ci' || $seq eq 'di' || $seq eq 'g') {
                $st{pending} = $seq;
                next;
            }
            elsif ($seq eq 'i') {
                $st{mode} = 'i';
            }
            elsif ($seq eq 'I') {
                $st{cur_col} = 0;
                $st{mode} = 'i';
            }
            elsif ($seq eq 'a') {
                my $llen = length($lines->[ $st{cur_row} ] // '');
                $st{cur_col}++ if $st{cur_col} < $llen;
                $st{mode} = 'i';
            }
            elsif ($seq eq 'A') {
                $st{cur_col} = length($lines->[ $st{cur_row} ] // '');
                $st{mode} = 'i';
            }
            elsif ($seq eq 'o') {
                splice(@$lines, $st{cur_row} + 1, 0, '');
                $st{cur_row}++;
                $st{cur_col} = 0;
                $st{mode} = 'i';
                $st{modified} = 1;
            }
            elsif ($seq eq 'O') {
                splice(@$lines, $st{cur_row}, 0, '');
                $st{cur_col} = 0;
                $st{mode} = 'i';
                $st{modified} = 1;
            }
            elsif ($seq eq '0') {
                $st{cur_col} = 0;
            }
            elsif ($seq eq '$') {
                my $llen = length($lines->[ $st{cur_row} ] // '');
                $st{cur_col} = $llen > 0 ? $llen - 1 : 0;
            }
            elsif ($seq eq 'h') {
                $st{cur_col}-- if $st{cur_col} > 0;
            }
            elsif ($seq eq 'l') {
                $st{cur_col}++;
                $clamp_cursor->();
            }
            elsif ($seq eq 'j') {
                $st{cur_row}++ if $st{cur_row} < $#$lines;
                $clamp_cursor->();
            }
            elsif ($seq eq 'k') {
                $st{cur_row}-- if $st{cur_row} > 0;
                $clamp_cursor->();
            }
            elsif ($seq eq 'gg') {
                $st{cur_row} = 0;
                $st{cur_col} = 0;
            }
            elsif ($seq eq 'G') {
                $st{cur_row} = $#$lines;
                $clamp_cursor->();
            }
            elsif ($seq eq 'x') {
                my $ln = $lines->[ $st{cur_row} ] // '';
                if ($st{cur_col} < length($ln)) {
                    substr($ln, $st{cur_col}, 1, '');
                    $lines->[ $st{cur_row} ] = $ln;
                    $st{modified} = 1;
                    $clamp_cursor->();
                }
            }
            elsif ($seq eq 'dd') {
                if (@$lines > 1) {
                    splice(@$lines, $st{cur_row}, 1);
                }
                else {
                    $lines->[0] = '';
                }
                $st{modified} = 1;
                $clamp_cursor->();
            }
            elsif ($seq eq 'ciw' || $seq eq 'diw' || $seq eq 'cw' || $seq eq 'dw') {
                my $ln   = $lines->[ $st{cur_row} ] // '';
                my $llen = length($ln);
                if ($llen > 0 && $st{cur_col} < $llen) {
                    my $s = $st{cur_col};
                    my $e = $st{cur_col};
                    if ($seq eq 'ciw' || $seq eq 'diw') {
                        $s-- while $s > 0 && substr($ln, $s - 1, 1) =~ /\w/;
                        $e++ while $e < $llen && substr($ln, $e, 1) =~ /\w/;
                    }
                    else {
                        $e++ while $e < $llen && substr($ln, $e, 1) =~ /\w/;
                        if ($seq eq 'dw') {
                            $e++ while $e < $llen && substr($ln, $e, 1) eq ' ';
                        }
                    }
                    substr($ln, $s, $e - $s, '');
                    $lines->[ $st{cur_row} ] = $ln;
                    $st{cur_col} = $s;
                    $st{modified} = 1;
                    if (substr($seq, 0, 1) eq 'c') {
                        $st{mode} = 'i';
                    }
                    else {
                        $clamp_cursor->();
                    }
                }
            }
            elsif ($seq eq ':') {
                $st{mode} = 'c';
                $st{cmdline} = '';
            }
        }
        $clamp_cursor->();
        return length($keys // '');
    };

    my $rx = '';
    my $quit = 0;
    while (!$quit) {
        my $chunk = '';
        my $n = sysread($rd, $chunk, 65536);
        last if !defined($n) || $n == 0;
        $rx .= $chunk;

        my ($items, $rem) = NeoPerl::Core::Msgpack::decode_stream(\$rx);
        $rx = $rem if defined $rem && !ref($rem);

        for my $msg (@{ $items || [] }) {
            next unless ref($msg) eq 'ARRAY' && @$msg >= 3;
            my $type = int($msg->[0] // -1);
            my ($msgid, $method, $params);
            if ($type == 0) {
                ($msgid, $method, $params) = @{$msg}[1, 2, 3];
            }
            elsif ($type == 2) {
                ($method, $params) = @{$msg}[1, 2];
            }
            else {
                next;
            }
            $params = [] unless ref($params) eq 'ARRAY';

            my ($err, $res) = (undef, undef);
            my $do_redraw = 0;
            my $full_redraw = 0;

            if ($method eq 'nvim_get_api_info') {
                $res = [ 1, {
                    version => {
                        major          => 0,
                        minor          => 12,
                        patch          => 6,
                        api_level      => 14,
                        api_compatible => 0,
                        mock           => _mp_bool(1),
                    },
                } ];
            }
            elsif ($method eq 'nvim_ui_attach') {
                $st{cols}     = int($params->[0] || 80);
                $st{rows}     = int($params->[1] || 24);
                $st{attached} = 1;
                $do_redraw    = 1;
                $full_redraw  = 1;
            }
            elsif ($method eq 'nvim_ui_try_resize') {
                $st{cols}    = int($params->[0] || $st{cols});
                $st{rows}    = int($params->[1] || $st{rows});
                $do_redraw   = 1;
                $full_redraw = 1;
            }
            elsif ($method eq 'nvim_ui_detach') {
                $st{attached} = 0;
            }
            elsif ($method eq 'nvim_input') {
                $res = $feed_input->($params->[0] // '');
                $do_redraw = 1;
            }
            elsif ($method eq 'nvim_command') {
                my $r = $exec_cmd->($params->[0] // '');
                $quit = 1 if $r eq 'quit';
                $do_redraw = 1 unless $quit;
            }
            elsif ($method eq 'nvim_eval') {
                my $expr = $params->[0] // '';
                if    ($expr eq '1')              { $res = 1 }
                elsif ($expr eq "line('\$')")     { $res = scalar(@{ $st{lines} }) }
                elsif ($expr eq "bufname('%')")   { $res = $st{buf_name} }
                elsif ($expr eq 'mode()')         { $res = $st{mode} }
                elsif ($expr eq '&filetype')      { $res = $st{filetype} }
                else                              { $res = '' }
            }
            elsif ($method eq 'nvim_buf_get_lines') {
                my ($b, $s, $e) = @{$params}[0, 1, 2];
                my $ls  = $st{lines};
                my $tot = scalar(@$ls);
                $s = int($s // 0);
                $e = int($e // -1);
                $s = $tot + $s + 1 if $s < 0;
                $e = $tot + $e + 1 if $e < 0;
                $s = 0    if $s < 0;
                $e = $tot if $e > $tot;
                $res = ($s < $e) ? [ @{$ls}[ $s .. $e - 1 ] ] : [];
            }
            elsif ($method eq 'nvim_buf_set_lines') {
                my ($b, $s, $e, $strict, $rep) = @{$params}[0 .. 4];
                my $ls  = $st{lines};
                my $tot = scalar(@$ls);
                $s = int($s // 0);
                $e = int($e // -1);
                $s = $tot + $s + 1 if $s < 0;
                $e = $tot + $e + 1 if $e < 0;
                $s = 0    if $s < 0;
                $e = $tot if $e > $tot;
                $rep = [] unless ref($rep) eq 'ARRAY';
                splice(@$ls, $s, ($e > $s ? $e - $s : 0), @$rep);
                @$ls = ('') unless @$ls;
                $st{modified} = 1;
                $clamp_cursor->();
                $do_redraw = 1;
            }
            elsif ($method eq 'nvim_buf_get_name') {
                $res = $st{buf_name};
            }
            elsif ($method eq 'nvim_get_option_value' || $method eq 'nvim_buf_get_option') {
                my $opt = ($method eq 'nvim_get_option_value') ? $params->[0] : $params->[1];
                if    (($opt // '') eq 'filetype') { $res = $st{filetype} }
                elsif (($opt // '') eq 'modified') { $res = _mp_bool($st{modified}) }
                else                               { $res = '' }
            }
            elsif ($method eq 'nvim_create_namespace') {
                $res = $st{next_ns}++;
            }
            elsif ($method eq 'nvim_buf_set_extmark') {
                my ($b, $ns, $line, $col, $opts) = @{$params}[0 .. 4];
                my $id = $st{next_em}++;
                push @{ $st{extmarks}{$ns} }, {
                    id   => $id,
                    line => int($line || 0),
                    col  => int($col  || 0),
                    opts => ref($opts) eq 'HASH' ? $opts : {},
                };
                $res = $id;
                $do_redraw = 1;
            }
            elsif ($method eq 'nvim_buf_get_extmarks') {
                my ($b, $ns) = @{$params}[0, 1];
                my @out;
                for my $em (@{ $st{extmarks}{$ns} || [] }) {
                    push @out, [ $em->{id}, $em->{line}, $em->{col}, $em->{opts} ];
                }
                $res = \@out;
            }
            elsif ($method eq 'nvim_buf_clear_namespace') {
                my ($b, $ns) = @{$params}[0, 1];
                delete $st{extmarks}{$ns};
                $do_redraw = 1;
            }
            elsif ($method eq 'nvim_win_get_cursor') {
                $res = [ $st{cur_row} + 1, $st{cur_col} ];
            }
            elsif ($method eq 'nvim_win_set_cursor') {
                my $pos = $params->[1];
                if (ref($pos) eq 'ARRAY') {
                    $st{cur_row} = int(($pos->[0] // 1) - 1);
                    $st{cur_col} = int($pos->[1] // 0);
                    $clamp_cursor->();
                    $do_redraw = 1;
                }
            }
            elsif ($method eq 'nvim_get_mode') {
                $res = { mode => $st{mode}, blocking => _mp_bool(0) };
            }
            elsif ($method eq 'nvim_list_bufs') {
                $res = [ { _nvim_ext => 0, id => 1 } ];
            }
            elsif ($method eq 'nvim_get_current_buf') {
                $res = { _nvim_ext => 0, id => 1 };
            }
            elsif ($method eq 'nvim_get_current_win') {
                $res = { _nvim_ext => 1, id => 1000 };
            }
            elsif ($method eq 'nvim_get_current_tabpage') {
                $res = { _nvim_ext => 2, id => 1 };
            }
            else {
                $err = [ 0, "Mock unknown method: $method" ];
            }

            if ($type == 0) {
                $send_frame->([ 1, $msgid, $err, $res ]);
            }
            $emit_redraw->($full_redraw) if $do_redraw && !$quit;
        }
    }
    return;
}

1;

__END__

=head1 NAME

NeoPerl::NvimBridge - Non-blocking Msgpack-RPC bridge to embedded upstream Neovim (nvim --embed)

=head1 SYNOPSIS

    use NeoPerl::NvimBridge;

    my $nb = NeoPerl::NvimBridge->new(cols => 100, rows => 36);
    $nb->connect();
    $nb->input("ihello world<Esc>0ciwNeoPerl<Esc>");
    my $lines = $nb->buf_get_lines(0, 0, -1);
    my $grid  = $nb->grid(1);
    $nb->close();

=head1 DESCRIPTION

Spawns upstream C<nvim --embed --headless> (or a built-in protocol-identical
offline Msgpack-RPC loopback server when C<< mock => 1 >> or C<nvim> is
absent), communicates via C<NeoPerl::Core::Msgpack>, attaches with
C<ext_linegrid> and 24-bit C<rgb>, and maintains a live 2D cell grid with
resolved highlight attributes, mode info, and cursor coordinates ready for
L<NeoPerl::UI::GPU>, L<NeoPerl::UI::TUI>, and L<NeoPerl::Antigravity::EditorMCP>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
