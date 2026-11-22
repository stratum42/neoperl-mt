package NeoPerl::Modal;

use strict;
use warnings;
use Scalar::Util qw(refaddr);
use NeoPerl::Core;

our $VERSION = '0.01';

my %MODE_TO_KEYMAP = (
    NORMAL     => 'n',
    INSERT     => 'i',
    REPLACE    => 'i',
    VISUAL     => 'v',
    VLINE      => 'v',
    VBLOCK     => 'v',
    OPERATOR   => 'o',
    COMMAND    => 'c',
    SEARCH_FWD => 'c',
    SEARCH_BWD => 'c',
    TERMINAL   => 't',
);

my %BRACKET_PAIRS = (
    '(' => [ ')',  1 ],
    ')' => [ '(', -1 ],
    '[' => [ ']',  1 ],
    ']' => [ '[', -1 ],
    '{' => [ '}',  1 ],
    '}' => [ '{', -1 ],
);

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor            => $opts{editor},
        mode              => 'NORMAL',
        leader            => ' ',
        # Composable grammar parser state
        count1            => '',
        count2            => '',
        reg               => undef,
        expect_reg        => 0,
        operator          => undef,      # d, c, y, >, <, =, g~, gu, gU, gq
        pending_prefix    => '',         # g, ], [, <C-w>, z, m, ', `, f, F, t, T, r, q, @, i, a
        # Keymap matching state
        keymaps           => { n => {}, i => {}, v => {}, o => {}, c => {}, t => {} },
        pending_map_keys  => [],
        in_map_rhs        => 0,
        # Visual selection
        visual_anchor     => undef,      # { line => L, col => C }
        last_visual       => undef,      # { mode, start_line, start_col, end_line, end_col }
        vblock_insert     => undef,      # { mode => 'I'|'A', start_line, end_line, col, text }
        # Registers & Marks
        registers         => {
            '"' => { text => '', type => 'char' },
            '0' => { text => '', type => 'char' },
        },
        global_marks      => {},         # A-Z => { buf_id, path, line, col }
        # Last char find (f/F/t/T)
        last_find         => undef,      # { kind => 'f'|'F'|'t'|'T', char => $c }
        # Dot-repeat recording
        dot_recording     => 0,
        dot_buffer        => [],
        last_change       => undef,      # { keys => [...], count => N }
        replaying_dot     => 0,
        # Macro recording
        macro_reg         => undef,
        macro_append      => 0,
        macro_buffer      => [],
        last_macro_reg    => undef,
        replaying_macro   => 0,
        # Command / search bar state
        cmdline           => '',
        cmdline_pos       => 0,
        cmdline_prompt    => ':',
        cmdline_hist_idx  => -1,
        search_history    => [],
        # Terminal escape tracking (<C-\><C-n>)
        term_esc_pending  => 0,
        # Plugin extension hooks
        text_object_hooks => {},         # 'if'/'af'/'ip'/'ap' => sub($ed, $buf, $line, $col) -> { start_line, start_col, end_line, end_col, linewise }
        motion_hooks      => {},         # ']]'/'[[' => sub($ed, $buf, $line, $col, $count) -> [$new_line, $new_col]
        formatters        => {},         # filetype or '*' => sub($ed, $buf, $start_line, $end_line) -> \@new_lines
        tab_accept_hooks  => [],         # sub($ed, $buf, $win) -> 1 if handled
        # Pure-C11 reentrant Vim 9.1 engine
        vim               => undef,
        _vim_buf_addr     => 0,
        _vim_last_l       => -1,
        _vim_last_c       => -1,
    }, $class;

    $self->_register_default_maps;
    return $self;
}

# --- Accessors & Hooks ---

sub mode             { return $_[0]->{mode} }
sub leader           { return $_[0]->{leader} }
sub set_leader       { $_[0]->{leader} = _normalize_key($_[1] // ' ') }
sub cmdline          { return $_[0]->{cmdline} }
sub cmdline_prompt   { return $_[0]->{cmdline_prompt} }
sub cmdline_pos      { return $_[0]->{cmdline_pos} }
sub is_recording {
    my ($self) = @_;
    if ($self->{vim}) {
        my $st = $self->{vim}->state_info;
        return $st->{recording} if defined $st->{recording};
    }
    return defined($self->{macro_reg}) ? $self->{macro_reg} : undef;
}

sub last_visual_range {
    my ($self) = @_;
    if ($self->{vim}) {
        my $lv = $self->{vim}->state_info->{last_visual};
        return $lv if $lv;
    }
    return $self->{last_visual};
}

sub vim_engine {
    my ($self, $ed) = @_;
    $ed ||= $self->{editor};
    return $self->_sync_vim_in($ed);
}

sub _sync_vim_in {
    my ($self, $ed) = @_;
    $ed ||= $self->{editor} or return undef;
    my $buf = $ed->current_buffer or return undef;
    my $win = $ed->current_window or return undef;
    my $core = $buf->core or return undef;
    my $addr = refaddr($core);

    if (!$self->{vim}) {
        $self->{vim}           = NeoPerl::Core::VimEngine->new($core);
        $self->{_vim_buf_addr} = $addr;
        $self->{_vim_last_l}   = -1;
        $self->{_vim_last_c}   = -1;
    }
    elsif ($self->{_vim_buf_addr} != $addr) {
        $self->{vim}->set_buffer($core);
        $self->{_vim_buf_addr} = $addr;
        $self->{_vim_last_l}   = -1;
        $self->{_vim_last_c}   = -1;
    }

    $self->{vim}->set_options({
        shiftwidth => $ed->get_option('shiftwidth') // 4,
        tabstop    => $ed->get_option('tabstop')    // 4,
        expandtab  => $ed->get_option('expandtab')  ? 1 : 0,
        win_height => $win->height || 23,
        scroll_top => $win->scroll_top || 0,
    });

    my ($wl, $wc) = $win->get_cursor;
    if ($wl != $self->{_vim_last_l} || $wc != $self->{_vim_last_c}) {
        $self->{vim}->set_cursor($wl, $wc);
        my ($vl, $vc) = $self->{vim}->cursor;
        $self->{_vim_last_l} = $vl;
        $self->{_vim_last_c} = $vc;
    }
    return $self->{vim};
}

sub _feed_vim {
    my ($self, $ed, $key) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my $vim = $self->_sync_vim_in($ed) or return 0;

    my $rev_before  = $buf->core->revision;
    my ($l0, $c0)   = $vim->cursor;
    my $mode_before = $vim->mode;

    $vim->feed_keys($key);

    my $mode_after = $vim->mode;
    my ($l1, $c1)  = $vim->cursor;
    $self->{_vim_last_l} = $l1;
    $self->{_vim_last_c} = $c1;

    $win->set_cursor($l1, $c1, 1);
    $ed->layout->ensure_cursor_visible($win);
    $self->set_mode($ed, $mode_after);

    my $st = $vim->state_info;
    if (length($st->{pending_prefix} // '') && $st->{pending_prefix} eq 'g') {
        $self->_whichkey_update($ed, 'g');
    }
    else {
        $self->_whichkey_update($ed, undef);
    }

    if ($buf->core->revision != $rev_before) {
        $buf->_touch(0, 0);
        if ($mode_after eq 'INSERT' || $mode_after eq 'REPLACE') {
            $ed->emit('TextChangedI', buf => $buf);
        }
        else {
            $ed->emit('TextChanged', buf => $buf);
        }
    }
    elsif ($l1 != $l0 || $c1 != $c0) {
        $ed->emit('CursorMoved', win => $win, buf => $buf, line => $l1, col => $c1);
    }
    return 1;
}

sub register_text_object {
    my ($self, $name, $cb) = @_;
    $self->{text_object_hooks}{$name} = $cb;
    return 1;
}

sub register_motion {
    my ($self, $name, $cb) = @_;
    $self->{motion_hooks}{$name} = $cb;
    return 1;
}

sub register_formatter {
    my ($self, $ft, $cb) = @_;
    $self->{formatters}{$ft || '*'} = $cb;
    return 1;
}

sub register_tab_accept_hook {
    my ($self, $cb) = @_;
    push @{ $self->{tab_accept_hooks} }, $cb;
    return 1;
}

sub set_mode {
    my ($self, $ed, $new_mode) = @_;
    my $old = $self->{mode};
    return $new_mode if $old eq $new_mode;
    $self->{mode} = $new_mode;
    if ($ed) {
        $ed->emit('ModeChanged', old => $old, new => $new_mode);
    }
    return $new_mode;
}

# --- Registers & Marks ---

sub set_register {
    my ($self, $name, $text, $type) = @_;
    $name = '"' unless defined $name && length $name;
    $type ||= 'char';
    return if $name eq '_';

    if ($name =~ /^[A-Z]$/) {
        my $lower = lc $name;
        my $cur = $self->{registers}{$lower} || { text => '', type => $type };
        $self->{registers}{$lower} = { text => $cur->{text} . $text, type => $type };
    }
    else {
        $self->{registers}{$name} = { text => $text, type => $type };
    }

    # Always update unnamed register unless writing to search/cmd registers
    if ($name ne '"' && $name ne '/' && $name ne ':') {
        $self->{registers}{'"'} = { text => $text, type => $type };
    }
    if ($self->{vim} && $name ne '/' && $name ne ':') {
        $self->{vim}->set_register($name, $text, $type);
        if ($name ne '"') {
            my $cur = $self->{vim}->get_register($name);
            $self->{vim}->set_register('"', $cur->{text}, $cur->{type});
        }
    }
    return 1;
}

sub _record_delete_register {
    my ($self, $reg, $text, $type) = @_;
    return if defined($reg) && $reg eq '_';
    if ($type eq 'line' || index($text, "\n") >= 0) {
        for my $i (reverse 2 .. 9) {
            $self->{registers}{$i} = $self->{registers}{ $i - 1 }
                if exists $self->{registers}{ $i - 1 };
        }
        $self->{registers}{'1'} = { text => $text, type => $type };
    }
    $self->set_register($reg || '"', $text, $type);
}

sub _record_yank_register {
    my ($self, $reg, $text, $type) = @_;
    return if defined($reg) && $reg eq '_';
    $self->{registers}{'0'} = { text => $text, type => $type };
    $self->{vim}->set_register('0', $text, $type) if $self->{vim};
    $self->set_register($reg || '"', $text, $type);
}

sub get_register {
    my ($self, $name) = @_;
    $name = '"' unless defined $name && length $name;
    if ($name ne '/' && $name ne ':' && $self->{vim}) {
        return $self->{vim}->get_register($name);
    }
    $name = lc $name if $name =~ /^[A-Z]$/;
    return $self->{registers}{$name} || { text => '', type => 'char' };
}

sub set_mark {
    my ($self, $ed, $name, $line, $col) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window;
    $line //= $win ? $win->cursor_line : 0;
    $col  //= $win ? $win->cursor_col  : 0;
    if ($name =~ /^[A-Z]$/) {
        $self->{global_marks}{$name} = {
            buf_id => $buf->id,
            path   => $buf->path,
            line   => $line,
            col    => $col,
        };
    }
    else {
        $buf->set_mark($name, $line, $col);
    }
    return 1;
}

sub get_mark {
    my ($self, $ed, $name) = @_;
    if ($name =~ /^[A-Z]$/) {
        return $self->{global_marks}{$name};
    }
    my $buf = $ed->current_buffer or return undef;
    return $buf->get_mark($name);
}

# --- Key Tokenization & Normalization ---

sub _normalize_key {
    my ($k) = @_;
    return '' unless defined $k && length $k;
    return '<CR>'  if $k eq "\r" || $k eq "\n" || lc($k) eq '<cr>' || lc($k) eq '<enter>' || lc($k) eq '<return>';
    return '<Esc>' if $k eq "\e" || lc($k) eq '<esc>' || lc($k) eq '<escape>';
    return '<BS>'  if $k eq "\x7f" || $k eq "\x08" || lc($k) eq '<bs>' || lc($k) eq '<backspace>';
    return '<Tab>' if $k eq "\t" || lc($k) eq '<tab>';
    return ' '     if lc($k) eq '<space>';

    if (length($k) == 1) {
        my $ord = ord($k);
        if ($ord >= 1 && $ord <= 26) {
            return '<C-' . chr($ord + 96) . '>';
        }
        return '<C-\\>' if $ord == 28;
        return $k;
    }
    if ($k =~ /^<c-([a-zA-Z\\\[\]])>$/i) {
        return '<C-' . lc($1) . '>';
    }
    if ($k =~ /^<s-tab>$/i)  { return '<S-Tab>' }
    if ($k =~ /^<up>$/i)     { return '<Up>' }
    if ($k =~ /^<down>$/i)   { return '<Down>' }
    if ($k =~ /^<left>$/i)   { return '<Left>' }
    if ($k =~ /^<right>$/i)  { return '<Right>' }
    if ($k =~ /^<home>$/i)   { return '<Home>' }
    if ($k =~ /^<end>$/i)    { return '<End>' }
    if ($k =~ /^<del>$/i)    { return '<Del>' }
    if ($k =~ /^<pageup>$/i) { return '<PageUp>' }
    if ($k =~ /^<pagedown>$/i) { return '<PageDown>' }
    return $k;
}

sub tokenize_keys {
    my ($self_or_str, $maybe_str) = @_;
    my ($self, $str) = ref($self_or_str) ? ($self_or_str, $maybe_str) : (undef, $self_or_str);
    my $leader = $self ? $self->{leader} : ' ';
    my @tokens;
    my $i   = 0;
    my $len = length($str // '');
    while ($i < $len) {
        if (substr($str, $i) =~ /\A(<[A-Za-z0-9_\\\[\]-]+>)/) {
            my $tok = $1;
            $i += length($tok);
            if (lc($tok) eq '<leader>') {
                push @tokens, $leader;
            }
            else {
                push @tokens, _normalize_key($tok);
            }
        }
        else {
            push @tokens, _normalize_key(substr($str, $i, 1));
            $i++;
        }
    }
    return @tokens;
}

# --- Keymap Table ---

sub _expand_lhs {
    my ($self, $lhs) = @_;
    return join('', $self->tokenize_keys($lhs));
}

sub map {
    my ($self, $mode, $lhs, $rhs, %opts) = @_;
    my @modes = (!defined($mode) || $mode eq '') ? ('n', 'v') : split(//, $mode);
    my @toks  = $self->tokenize_keys($lhs);
    my $key   = join("\x1f", @toks);
    for my $m (@modes) {
        $self->{keymaps}{$m} ||= {};
        $self->{keymaps}{$m}{$key} = {
            lhs     => $lhs,
            tokens  => \@toks,
            rhs     => $rhs,
            desc    => $opts{desc} // '',
            noremap => exists($opts{noremap}) ? ($opts{noremap} ? 1 : 0) : 1,
            silent  => $opts{silent} ? 1 : 0,
        };
    }
    return 1;
}

sub unmap {
    my ($self, $mode, $lhs) = @_;
    my @modes = (!defined($mode) || $mode eq '') ? ('n', 'v') : split(//, $mode);
    my $key   = join("\x1f", $self->tokenize_keys($lhs));
    for my $m (@modes) {
        delete $self->{keymaps}{$m}{$key} if exists $self->{keymaps}{$m};
    }
    return 1;
}

sub get_bindings_for_prefix {
    my ($self, $mode, $prefix) = @_;
    $mode ||= 'n';
    my @ptoks = $self->tokenize_keys($prefix // '');
    my $plen  = scalar(@ptoks);
    my $maps  = $self->{keymaps}{$mode} || {};

    my @out;
    for my $entry (values %{$maps}) {
        my $etoks = $entry->{tokens};
        next if scalar(@{$etoks}) <= $plen;
        my $match = 1;
        for my $i (0 .. $plen - 1) {
            if ($etoks->[$i] ne $ptoks[$i]) {
                $match = 0;
                last;
            }
        }
        next unless $match;
        my $rem = join('', @{$etoks}[ $plen .. $#{$etoks} ]);
        push @out, {
            lhs       => $entry->{lhs},
            desc      => $entry->{desc},
            remaining => $rem,
        };
    }
    return \@out;
}

sub _register_default_maps {
    my ($self) = @_;

    # Inline diff hunk acceptance / rejection
    $self->map('n', '<leader>ay', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return;
        my $win = $ed->current_window;
        my $h = $buf->accept_hunk_at_line($win ? $win->cursor_line : 0);
        $ed->notify($h ? 'Accepted diff hunk' : 'No pending diff hunk at cursor', 'info');
    }, desc => 'Accept diff hunk at cursor');

    $self->map('n', '<leader>an', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return;
        my $win = $ed->current_window;
        my $h = $buf->reject_hunk_at_line($win ? $win->cursor_line : 0);
        $ed->notify($h ? 'Rejected diff hunk' : 'No pending diff hunk at cursor', 'info');
    }, desc => 'Reject diff hunk at cursor');

    $self->map('n', '<leader>aY', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return;
        my $n = $buf->accept_all_hunks;
        $ed->notify("Accepted $n diff hunk(s)", 'info');
    }, desc => 'Accept all diff hunks');

    $self->map('n', '<leader>aN', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return;
        my $n = $buf->reject_all_hunks;
        $ed->notify("Rejected $n diff hunk(s)", 'info');
    }, desc => 'Reject all diff hunks');

    # 4-Tab Command Center toggles
    $self->map('n', '<leader>aa', sub {
        $_[0]->layout->toggle_command_center('chat');
    }, desc => 'Toggle Command Center: Chat');

    $self->map('n', '<leader>am', sub {
        $_[0]->layout->toggle_command_center('memory');
    }, desc => 'Toggle Command Center: Memory');

    $self->map('n', '<leader>aj', sub {
        $_[0]->layout->toggle_command_center('jobs');
    }, desc => 'Toggle Command Center: Models & Jobs');

    $self->map('n', '<leader>xd', sub {
        $_[0]->layout->toggle_command_center('xsdev');
    }, desc => 'Toggle Command Center: XSDev');
}

# --- Main Key Feed & Dispatch ---

sub feed_keys {
    my ($self, $ed, $seq) = @_;
    $ed ||= $self->{editor};
    for my $tok ($self->tokenize_keys($seq)) {
        $self->handle_key($ed, $tok);
    }
    return 1;
}

sub _whichkey_update {
    my ($self, $ed, $prefix) = @_;
    my $wk = $ed ? $ed->plugin('whichkey') : undef;
    return unless $wk;
    if (defined $prefix && length $prefix) {
        my $m = $MODE_TO_KEYMAP{ $self->{mode} } || 'n';
        my $disp = $prefix;
        $disp =~ s/^\Q$self->{leader}\E/<leader>/;
        $wk->show($disp, $m);
    }
    else {
        $wk->hide;
    }
}

sub handle_key {
    my ($self, $ed, $raw_key) = @_;
    $ed ||= $self->{editor};
    my $key = _normalize_key($raw_key);
    return 0 unless length $key;

    # Macro recording: capture raw keys except the terminating 'q' in NORMAL mode
    if (defined $self->{macro_reg} && !$self->{replaying_macro}) {
        if ($self->{mode} eq 'NORMAL' && $key eq 'q' && !$self->{pending_prefix} && !$self->{expect_reg}) {
            my $reg = $self->{macro_reg};
            my $seq = join('', @{ $self->{macro_buffer} });
            my $target_reg = $self->{macro_append} ? uc($reg) : $reg;
            $self->set_register($target_reg, $seq, 'char');
            $self->{macro_reg}    = undef;
            $self->{macro_buffer} = [];
            $ed->notify("Recorded macro \@$reg", 'info');
            return 1;
        }
        push @{ $self->{macro_buffer} }, $key;
    }

    my $vim_pending = 0;
    if ($self->{vim}) {
        my $vst = $self->{vim}->state_info;
        $vim_pending = 1 if length($vst->{pending_prefix} // '') || $vst->{expect_reg};
    }

    # Check custom keymaps (when not mid-grammar prefix/register and not inside noremap rhs)
    if (!$self->{in_map_rhs}
        && !$self->{pending_prefix}
        && !$self->{expect_reg}
        && !$vim_pending
        && ($self->{mode} eq 'NORMAL' || $self->{mode} eq 'VISUAL' || $self->{mode} eq 'VLINE' || $self->{mode} eq 'VBLOCK' || $self->{mode} eq 'INSERT'))
    {
        my $mkey = $MODE_TO_KEYMAP{ $self->{mode} };
        my $maps = $self->{keymaps}{$mkey} || {};
        my @cand = (@{ $self->{pending_map_keys} }, $key);
        my $joined = join("\x1f", @cand);

        if (exists $maps->{$joined}) {
            my $entry = $maps->{$joined};
            $self->{pending_map_keys} = [];
            $self->_whichkey_update($ed, undef);
            return $self->_invoke_keymap($ed, $entry);
        }

        # Check if @cand is a strict prefix of any mapping
        my $pref = $joined . "\x1f";
        my $is_prefix = 0;
        for my $k (keys %{$maps}) {
            if (index($k, $pref) == 0) {
                $is_prefix = 1;
                last;
            }
        }
        if ($is_prefix) {
            $self->{pending_map_keys} = \@cand;
            $self->_whichkey_update($ed, join('', @cand));
            return 1;
        }

        # No map matched — flush any previously buffered pending map keys
        if (@{ $self->{pending_map_keys} }) {
            my @flush = splice @{ $self->{pending_map_keys} };
            $self->_whichkey_update($ed, undef);
            local $self->{in_map_rhs} = 1;
            for my $fk (@flush) {
                $self->_dispatch_mode_key($ed, $fk);
            }
        }
    }

    return $self->_dispatch_mode_key($ed, $key);
}

sub _invoke_keymap {
    my ($self, $ed, $entry) = @_;
    my $rhs = $entry->{rhs};
    if (ref($rhs) eq 'CODE') {
        $rhs->($ed);
        return 1;
    }
    local $self->{in_map_rhs} = $entry->{noremap} ? 1 : 0;
    for my $tok ($self->tokenize_keys($rhs)) {
        $self->_dispatch_mode_key($ed, $tok);
    }
    return 1;
}

sub _dispatch_mode_key {
    my ($self, $ed, $key) = @_;
    my $mode = $self->{mode};

    return $self->_handle_cmdline($ed, $key)  if $mode eq 'COMMAND' || $mode eq 'SEARCH_FWD' || $mode eq 'SEARCH_BWD';
    return $self->_handle_terminal($ed, $key) if $mode eq 'TERMINAL';

    my $buf = $ed ? $ed->current_buffer : undef;
    my $win = $ed ? $ed->current_window : undef;
    if (!$buf || !$win || !$buf->modifiable) {
        return $self->_handle_insert($ed, $key)  if $mode eq 'INSERT';
        return $self->_handle_replace($ed, $key) if $mode eq 'REPLACE';
        return $self->_handle_normal_or_visual($ed, $key);
    }

    my $vim = $self->_sync_vim_in($ed);
    my $st  = $vim->state_info;
    my $vmode = $st->{mode};
    my $vpref = $st->{pending_prefix} // '';
    my $vop   = $st->{operator}       // '';
    my $vreg  = $st->{reg};
    my $vis   = ($vmode eq 'VISUAL' || $vmode eq 'VLINE' || $vmode eq 'VBLOCK');

    # If Perl side already owns a multi-key prefix/operator (e.g. <C-w>, z, ], [, gq, =), let Perl finish it
    if (length($self->{pending_prefix}) || defined($self->{operator}) || $self->{expect_reg}) {
        return $self->_handle_normal_or_visual($ed, $key);
    }

    # INSERT mode: keep <Tab> ghost-text & Antigravity completion hooks in Perl; delegate everything else to C11 VimEngine
    if ($vmode eq 'INSERT') {
        if ($key eq '<Tab>') {
            my $gt = $buf->ghost_text;
            if ($gt && defined $gt->{text} && length $gt->{text}) {
                my $text = $gt->{text};
                $buf->clear_ghost_text;
                my ($l, $c) = $win->get_cursor;
                $buf->insert_at($l, $c, $text);
                my @parts = split /\n/, $text, -1;
                my ($nl, $nc) = @parts > 1 ? ($l + $#parts, length($parts[-1])) : ($l, $c + length($text));
                $win->set_cursor($nl, $nc);
                $vim->set_cursor($nl, $nc);
                $self->{_vim_last_l} = $nl;
                $self->{_vim_last_c} = $nc;
                $ed->emit('TextChangedI', buf => $buf);
                return 1;
            }
            for my $hook (@{ $self->{tab_accept_hooks} }) {
                if (eval { $hook->($ed, $buf, $win) }) {
                    my ($nl, $nc) = $win->get_cursor;
                    $vim->set_cursor($nl, $nc);
                    $self->{_vim_last_l} = $nl;
                    $self->{_vim_last_c} = $nc;
                    return 1;
                }
            }
        }
        return $self->_feed_vim($ed, $key);
    }

    # REPLACE mode: pure-C11 VimEngine (with <BS> character restoration)
    if ($vmode eq 'REPLACE') {
        return $self->_feed_vim($ed, $key);
    }

    # Intercept registered custom text-object hooks (e.g. PPI/Tree-sitter if/af)
    if (($vpref eq 'i' || $vpref eq 'a') && (exists $self->{text_object_hooks}{ $vpref . $key } || $key eq 'f')) {
        my $vr = $vis ? $vim->visual_range : undef;
        $vim->feed_keys('<Esc>');
        $self->{operator}       = length($vop) ? $vop : undef;
        $self->{reg}            = $vreg;
        $self->{pending_prefix} = '';
        if ($vis && $vr) {
            $self->{visual_anchor} = { line => $vr->{start_line}, col => $vr->{start_col} };
            $self->set_mode($ed, $vr->{mode});
        }
        else {
            $self->set_mode($ed, length($vop) ? 'OPERATOR' : 'NORMAL');
        }
        return $self->_handle_prefix_second_key($ed, $vpref, $key);
    }

    # Intercept editor-only g-subcommands: gq (formatter), gt/gT (tabs), gd/gr (LSP)
    if ($vpref eq 'g' && ($key eq 'q' || $key eq 't' || $key eq 'T' || $key eq 'd' || $key eq 'r')) {
        my $vr = $vis ? $vim->visual_range : undef;
        $vim->feed_keys('<Esc>');
        $self->{_vim_last_l} = -1;
        $self->{_vim_last_c} = -1;
        if ($key eq 'q' && $vis && $vr) {
            $self->set_mode($ed, 'NORMAL');
            return $self->_apply_operator_range($ed, 'gq', {
                start_line => $vr->{start_line},
                start_col  => $vr->{start_col},
                end_line   => $vr->{end_line},
                end_col    => $vr->{end_col},
                linewise   => 1,
            }, $vreg);
        }
        $self->set_mode($ed, 'NORMAL');
        return $self->_handle_prefix_second_key($ed, 'g', $key);
    }

    # Intercept global marks A..Z (cross-buffer) while keeping local marks a..z in C11 VimEngine
    if (($vpref eq 'm' || $vpref eq "'" || $vpref eq '`') && $key =~ /^[A-Z]$/) {
        $vim->feed_keys('<Esc>');
        $self->{_vim_last_l} = -1;
        $self->{_vim_last_c} = -1;
        $self->set_mode($ed, 'NORMAL');
        return $self->_handle_prefix_second_key($ed, $vpref, $key);
    }

    # Intercept editor-level commands when C11 VimEngine is not awaiting a 2nd key or register
    if (!length($vpref) && !$st->{expect_reg}) {
        if ($key eq ':') {
            if ($vis) {
                $self->{last_visual} = $vim->visual_range;
                $vim->feed_keys('<Esc>');
                $self->set_mode($ed, 'COMMAND');
                $self->{cmdline_prompt}   = ':';
                $self->{cmdline}          = "'<,'>";
                $self->{cmdline_pos}      = length($self->{cmdline});
                $self->{cmdline_hist_idx} = -1;
                return 1;
            }
            if (!length($vop)) {
                return $self->_handle_normal_or_visual($ed, $key);
            }
        }
        if (!length($vop) && !$vis && ($key eq '/' || $key eq '?' || $key eq '*' || $key eq '#'
            || $key eq 'n' || $key eq 'N' || $key eq 'K'
            || $key eq '<C-w>' || $key eq 'z' || $key eq ']' || $key eq '['
            || $key eq '=' || $key eq '<C-d>' || $key eq '<C-u>' || $key eq '<C-f>' || $key eq '<C-b>'))
        {
            return $self->_handle_normal_or_visual($ed, $key);
        }
        if ($vis && ($key eq '=')) {
            my $vr = $vim->visual_range;
            $vim->feed_keys('<Esc>');
            $self->set_mode($ed, 'NORMAL');
            return $self->_apply_operator_range($ed, '=', {
                start_line => $vr->{start_line},
                start_col  => $vr->{start_col},
                end_line   => $vr->{end_line},
                end_col    => $vr->{end_col},
                linewise   => 1,
            }, $vreg);
        }
    }

    # Delegate core Vim 9.1 modal/motion/text-object/operator/visual/register/macro/dot/undo keys to C11 VimEngine
    return $self->_feed_vim($ed, $key);
}

# --- Dot-repeat Helpers ---

sub _start_dot {
    my ($self, @initial_keys) = @_;
    return if $self->{replaying_dot};
    $self->{dot_recording} = 1;
    $self->{dot_buffer}    = [ @initial_keys ];
}

sub _append_dot {
    my ($self, @keys) = @_;
    return if $self->{replaying_dot} || !$self->{dot_recording};
    push @{ $self->{dot_buffer} }, @keys;
}

sub _finish_dot {
    my ($self, $count) = @_;
    return if $self->{replaying_dot} || !$self->{dot_recording};
    $self->{dot_recording} = 0;
    if (@{ $self->{dot_buffer} }) {
        $self->{last_change} = {
            keys  => [ @{ $self->{dot_buffer} } ],
            count => $count,
        };
    }
    $self->{dot_buffer} = [];
}

sub _replay_dot {
    my ($self, $ed, $override_count) = @_;
    my $lc = $self->{last_change} or return 0;
    my @keys = @{ $lc->{keys} };
    return 0 unless @keys;

    if (defined $override_count && $override_count > 0) {
        # Strip leading digit keys from stored change and prepend override_count
        shift @keys while @keys && $keys[0] =~ /^[0-9]$/;
        unshift @keys, split(//, "$override_count");
    }

    local $self->{replaying_dot} = 1;
    for my $k (@keys) {
        $self->_dispatch_mode_key($ed, $k);
    }
    return 1;
}

# --- Buffer/Cursor Clamping Helpers ---

sub _clamp_cursor {
    my ($self, $ed, $insert_mode) = @_;
    my $buf = $ed->current_buffer or return (0, 0);
    my $win = $ed->current_window or return (0, 0);
    my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
    my $line = $win->cursor_line;
    $line = 0         if $line < 0;
    $line = $max_line if $line > $max_line;
    my $text = $buf->get_line($line) // '';
    my $llen = length($text);
    my $max_col = $insert_mode ? $llen : ($llen > 0 ? $llen - 1 : 0);
    my $col = $win->cursor_col;
    $col = 0        if $col < 0;
    $col = $max_col if $col > $max_col;
    $win->set_cursor($line, $col, 1);
    $ed->layout->ensure_cursor_visible($win);
    return ($line, $col);
}

sub _reset_grammar {
    my ($self, $ed) = @_;
    $self->{count1}         = '';
    $self->{count2}         = '';
    $self->{reg}            = undef;
    $self->{expect_reg}     = 0;
    $self->{operator}       = undef;
    $self->{pending_prefix} = '';
    if ($self->{mode} eq 'OPERATOR') {
        $self->set_mode($ed, 'NORMAL');
    }
    $self->_whichkey_update($ed, undef);
}

sub _effective_count {
    my ($self, $default) = @_;
    $default //= 1;
    my $c1 = length($self->{count1}) ? int($self->{count1}) : 0;
    my $c2 = length($self->{count2}) ? int($self->{count2}) : 0;
    return $c1 * $c2 if $c1 > 0 && $c2 > 0;
    return $c1       if $c1 > 0;
    return $c2       if $c2 > 0;
    return $default;
}

sub _has_explicit_count {
    my ($self) = @_;
    return (length($self->{count1}) || length($self->{count2})) ? 1 : 0;
}

# --- Visual Selection Helpers ---

sub visual_range {
    my ($self, $ed) = @_;
    my $m = $self->{mode};
    return undef unless $m eq 'VISUAL' || $m eq 'VLINE' || $m eq 'VBLOCK';
    if ($self->{vim}) {
        my $vr = $self->{vim}->visual_range;
        return $vr if $vr;
    }
    my $anchor = $self->{visual_anchor} or return undef;
    my $win    = $ed->current_window    or return undef;

    my ($l1, $c1) = ($anchor->{line}, $anchor->{col});
    my ($l2, $c2) = ($win->cursor_line, $win->cursor_col);

    if ($m eq 'VBLOCK') {
        my ($sl, $el) = $l1 <= $l2 ? ($l1, $l2) : ($l2, $l1);
        my ($sc, $ec) = $c1 <= $c2 ? ($c1, $c2) : ($c2, $c1);
        return {
            mode       => $m,
            start_line => $sl,
            start_col  => $sc,
            end_line   => $el,
            end_col    => $ec,
        };
    }

    if ($l1 > $l2 || ($l1 == $l2 && $c1 > $c2)) {
        ($l1, $c1, $l2, $c2) = ($l2, $c2, $l1, $c1);
    }
    return {
        mode       => $m,
        start_line => $l1,
        start_col  => $c1,
        end_line   => $l2,
        end_col    => $c2,
    };
}

# --- INSERT Mode ---

sub _handle_insert {
    my ($self, $ed, $key) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;

    if ($key eq '<Esc>' || $key eq '<C-[>' || $key eq '<C-c>') {
        $self->_append_dot('<Esc>');
        my $vbi = delete $self->{vblock_insert};
        if ($vbi && length($vbi->{text} // '')) {
            # Replicate inserted text across remaining lines in the visual block
            for my $l ($vbi->{start_line} + 1 .. $vbi->{end_line}) {
                my $lt = $buf->get_line($l) // '';
                my $col = $vbi->{mode} eq 'A'
                    ? (($vbi->{col} > length($lt)) ? length($lt) : $vbi->{col})
                    : (($vbi->{col} > length($lt)) ? length($lt) : $vbi->{col});
                $buf->insert_at($l, $col, $vbi->{text});
            }
        }
        $buf->end_undo_group;
        $self->_finish_dot;
        my ($l, $c) = $win->get_cursor;
        $win->set_cursor($l, $c > 0 ? $c - 1 : 0);
        $self->set_mode($ed, 'NORMAL');
        $self->_clamp_cursor($ed, 0);
        $ed->emit('TextChanged', buf => $buf);
        return 1;
    }

    if ($key eq '<Tab>') {
        # 1. Accept buffer ghost text if present
        my $gt = $buf->ghost_text;
        if ($gt && defined $gt->{text} && length $gt->{text}) {
            my $text = $gt->{text};
            $buf->clear_ghost_text;
            my ($l, $c) = $win->get_cursor;
            $buf->insert_at($l, $c, $text);
            my @parts = split /\n/, $text, -1;
            if (@parts > 1) {
                $win->set_cursor($l + $#parts, length($parts[-1]));
            }
            else {
                $win->set_cursor($l, $c + length($text));
            }
            $ed->emit('TextChangedI', buf => $buf);
            return 1;
        }
        # 2. Check registered tab-accept hooks (e.g. Antigravity completion)
        for my $hook (@{ $self->{tab_accept_hooks} }) {
            return 1 if eval { $hook->($ed, $buf, $win) };
        }
        # 3. Normal tab / spaces
        my $ins = $ed->get_option('expandtab')
            ? (' ' x ($ed->get_option('tabstop') || 4))
            : "\t";
        my ($l, $c) = $win->get_cursor;
        $buf->insert_at($l, $c, $ins);
        $win->set_cursor($l, $c + length($ins));
        $self->{vblock_insert}{text} .= $ins if $self->{vblock_insert};
        $self->_append_dot($key);
        $ed->emit('TextChangedI', buf => $buf);
        return 1;
    }

    if ($key eq '<CR>') {
        my ($l, $c) = $win->get_cursor;
        $buf->insert_at($l, $c, "\n");
        $win->set_cursor($l + 1, 0);
        $ed->layout->ensure_cursor_visible($win);
        $self->_append_dot('<CR>');
        $ed->emit('TextChangedI', buf => $buf);
        return 1;
    }

    if ($key eq '<BS>') {
        my ($l, $c) = $win->get_cursor;
        if ($c > 0) {
            my $off = $buf->line_col_to_byte($l, $c - 1);
            $buf->delete($off, 1);
            $win->set_cursor($l, $c - 1);
            if ($self->{vblock_insert} && length($self->{vblock_insert}{text})) {
                substr($self->{vblock_insert}{text}, -1, 1, '');
            }
        }
        elsif ($l > 0) {
            my $prev_len = length($buf->get_line($l - 1) // '');
            my $off = $buf->line_col_to_byte($l - 1, $prev_len);
            $buf->delete($off, 1);
            $win->set_cursor($l - 1, $prev_len);
        }
        $self->_append_dot('<BS>');
        $ed->emit('TextChangedI', buf => $buf);
        return 1;
    }

    if ($key eq '<Del>') {
        my ($l, $c) = $win->get_cursor;
        my $off = $buf->line_col_to_byte($l, $c);
        if ($off < $buf->byte_length) {
            $buf->delete($off, 1);
            $self->_append_dot('<Del>');
            $ed->emit('TextChangedI', buf => $buf);
        }
        return 1;
    }

    if ($key eq '<Left>')  { my ($l, $c) = $win->get_cursor; $win->set_cursor($l, $c - 1) if $c > 0; return 1 }
    if ($key eq '<Right>') { my ($l, $c) = $win->get_cursor; $win->set_cursor($l, $c + 1); $self->_clamp_cursor($ed, 1); return 1 }
    if ($key eq '<Up>')    { my ($l, $c) = $win->get_cursor; $win->set_cursor($l - 1, $c) if $l > 0; $self->_clamp_cursor($ed, 1); return 1 }
    if ($key eq '<Down>')  { my ($l, $c) = $win->get_cursor; $win->set_cursor($l + 1, $c); $self->_clamp_cursor($ed, 1); return 1 }

    # Printable character
    if (length($key) == 1 && ord($key) >= 32) {
        my ($l, $c) = $win->get_cursor;
        $buf->insert_at($l, $c, $key);
        $win->set_cursor($l, $c + 1);
        $ed->layout->ensure_cursor_visible($win);
        $self->{vblock_insert}{text} .= $key if $self->{vblock_insert};
        $self->_append_dot($key);
        $ed->emit('TextChangedI', buf => $buf);
        return 1;
    }
    return 0;
}

# --- REPLACE Mode ---

sub _handle_replace {
    my ($self, $ed, $key) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;

    if ($key eq '<Esc>' || $key eq '<C-[>') {
        $self->_append_dot('<Esc>');
        $buf->end_undo_group;
        $self->_finish_dot;
        my ($l, $c) = $win->get_cursor;
        $win->set_cursor($l, $c > 0 ? $c - 1 : 0);
        $self->set_mode($ed, 'NORMAL');
        $self->_clamp_cursor($ed, 0);
        $ed->emit('TextChanged', buf => $buf);
        return 1;
    }

    if ($key eq '<BS>') {
        my ($l, $c) = $win->get_cursor;
        $win->set_cursor($l, $c - 1) if $c > 0;
        $self->_append_dot('<BS>');
        return 1;
    }

    if (length($key) == 1 && ord($key) >= 32) {
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        my $off  = $buf->line_col_to_byte($l, $c);
        if ($c < length($line)) {
            $buf->delete($off, 1);
        }
        $buf->insert($off, $key);
        $win->set_cursor($l, $c + 1);
        $self->_append_dot($key);
        $ed->emit('TextChangedI', buf => $buf);
        return 1;
    }
    return 0;
}

# --- COMMAND / SEARCH Modes ---

sub _handle_cmdline {
    my ($self, $ed, $key) = @_;
    my $mode = $self->{mode};

    if ($key eq '<Esc>' || $key eq '<C-c>') {
        $self->{cmdline}     = '';
        $self->{cmdline_pos} = 0;
        $self->set_mode($ed, 'NORMAL');
        return 1;
    }

    if ($key eq '<CR>') {
        my $text = $self->{cmdline};
        $self->{cmdline}     = '';
        $self->{cmdline_pos} = 0;
        $self->set_mode($ed, 'NORMAL');

        if ($mode eq 'COMMAND') {
            $self->set_register(':', $text, 'char');
            $ed->exec_command($text);
        }
        else {
            my $dir = ($mode eq 'SEARCH_FWD') ? 1 : -1;
            $self->_execute_search($ed, $text, $dir);
        }
        return 1;
    }

    if ($key eq '<BS>') {
        if ($self->{cmdline_pos} > 0) {
            substr($self->{cmdline}, $self->{cmdline_pos} - 1, 1, '');
            $self->{cmdline_pos}--;
        }
        elsif (!length $self->{cmdline}) {
            $self->set_mode($ed, 'NORMAL');
        }
        return 1;
    }

    if ($key eq '<Left>') {
        $self->{cmdline_pos}-- if $self->{cmdline_pos} > 0;
        return 1;
    }
    if ($key eq '<Right>') {
        $self->{cmdline_pos}++ if $self->{cmdline_pos} < length($self->{cmdline});
        return 1;
    }
    if ($key eq '<Tab>' && $mode eq 'COMMAND') {
        my $cands = $ed->excmd->complete_command($self->{cmdline});
        if (@{$cands}) {
            $self->{cmdline}     = $cands->[0];
            $self->{cmdline_pos} = length($self->{cmdline});
        }
        return 1;
    }
    if ($key eq '<Up>' || $key eq '<Down>') {
        my $hist = ($mode eq 'COMMAND') ? $ed->excmd->history : $self->{search_history};
        if (@{$hist}) {
            if ($key eq '<Up>') {
                $self->{cmdline_hist_idx} = ($self->{cmdline_hist_idx} < 0)
                    ? $#{$hist}
                    : ($self->{cmdline_hist_idx} > 0 ? $self->{cmdline_hist_idx} - 1 : 0);
            }
            else {
                $self->{cmdline_hist_idx}++;
                if ($self->{cmdline_hist_idx} > $#{$hist}) {
                    $self->{cmdline_hist_idx} = -1;
                    $self->{cmdline}          = '';
                    $self->{cmdline_pos}      = 0;
                    return 1;
                }
            }
            $self->{cmdline}     = $hist->[ $self->{cmdline_hist_idx} ];
            $self->{cmdline_pos} = length($self->{cmdline});
        }
        return 1;
    }

    if (length($key) == 1 && ord($key) >= 32) {
        substr($self->{cmdline}, $self->{cmdline_pos}, 0, $key);
        $self->{cmdline_pos}++;
        return 1;
    }
    return 0;
}

# --- TERMINAL Mode ---

sub _handle_terminal {
    my ($self, $ed, $key) = @_;
    if ($self->{term_esc_pending}) {
        $self->{term_esc_pending} = 0;
        if ($key eq '<C-n>') {
            $self->set_mode($ed, 'NORMAL');
            return 1;
        }
    }
    if ($key eq '<C-\\>') {
        $self->{term_esc_pending} = 1;
        return 1;
    }

    my $buf = $ed->current_buffer or return 0;
    my $term = $buf->term;
    if (!$term) {
        $self->set_mode($ed, 'NORMAL') if $key eq '<Esc>';
        return 1;
    }
    my $bytes = $key eq '<CR>'  ? "\r"
              : $key eq '<BS>'  ? "\x7f"
              : $key eq '<Tab>' ? "\t"
              : $key eq '<Esc>' ? "\e"
              : ($key =~ /^<C-([a-z])>$/) ? chr(ord($1) - 96)
              : $key;
    $buf->write_terminal($bytes);
    return 1;
}

# --- Search Helpers ---

sub _execute_search {
    my ($self, $ed, $pat, $dir) = @_;
    my $st = $ed->search_state;
    if (!defined $pat || !length $pat) {
        $pat = $st->{pattern};
    }
    return 0 unless defined $pat && length $pat;
    push @{ $self->{search_history} }, $pat;
    $self->set_register('/', $pat, 'char');
    $st->{pattern}   = $pat;
    $st->{direction} = $dir;
    $st->{hl_active} = 1;
    return $self->_jump_search($ed, $dir);
}

sub _jump_search {
    my ($self, $ed, $dir) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my $st  = $ed->search_state;
    my $pat = $st->{pattern};
    return 0 unless defined $pat && length $pat;

    my $icase = $ed->get_option('ignorecase');
    $icase = 0 if $icase && $ed->get_option('smartcase') && $pat =~ /[A-Z]/;
    my $rx = eval { $icase ? qr/$pat/i : qr/$pat/ } or return 0;

    my $n = $buf->line_count;
    return 0 unless $n > 0;
    my ($cur_l, $cur_c) = $win->get_cursor;

    for my $step (0 .. $n) {
        my $l = ($cur_l + $dir * $step) % $n;
        my $text = $buf->get_line($l) // '';
        my @hits;
        while ($text =~ /$rx/g) {
            push @hits, $-[0];
            last if $+[0] == $-[0];
        }
        next unless @hits;
        if ($dir > 0) {
            for my $pos (@hits) {
                if ($step > 0 || $pos > $cur_c) {
                    $win->set_cursor($l, $pos);
                    $ed->layout->ensure_cursor_visible($win);
                    $ed->emit('CursorMoved', win => $win, buf => $buf);
                    return 1;
                }
            }
        }
        else {
            for my $pos (reverse @hits) {
                if ($step > 0 || $pos < $cur_c) {
                    $win->set_cursor($l, $pos);
                    $ed->layout->ensure_cursor_visible($win);
                    $ed->emit('CursorMoved', win => $win, buf => $buf);
                    return 1;
                }
            }
        }
    }
    $ed->notify("Pattern not found: $pat", 'warn');
    return 0;
}

# --- NORMAL / VISUAL / OPERATOR Mode ---

sub _handle_normal_or_visual {
    my ($self, $ed, $key) = @_;
    my $buf  = $ed->current_buffer or return 0;
    my $win  = $ed->current_window or return 0;
    my $mode = $self->{mode};
    my $is_visual = ($mode eq 'VISUAL' || $mode eq 'VLINE' || $mode eq 'VBLOCK');

    # Escape resets everything cleanly
    if ($key eq '<Esc>' || $key eq '<C-c>') {
        if ($is_visual) {
            $self->{last_visual}   = $self->visual_range($ed);
            $self->{visual_anchor} = undef;
            $self->set_mode($ed, 'NORMAL');
        }
        $self->_reset_grammar($ed);
        return 1;
    }

    # Register prefix: "{reg}
    if ($self->{expect_reg}) {
        $self->{expect_reg} = 0;
        $self->{reg}        = $key;
        return 1;
    }

    # Pending 2nd-key prefixes
    if (length $self->{pending_prefix}) {
        return $self->_handle_prefix_second_key($ed, $self->{pending_prefix}, $key);
    }

    # Register introducer
    if ($key eq '"' && !$self->{operator}) {
        $self->{expect_reg} = 1;
        return 1;
    }

    # Count digits ('0' starts motion unless already accumulating a count)
    if ($key =~ /^[1-9]$/ || ($key eq '0' && (length($self->{operator} ? $self->{count2} : $self->{count1}) > 0))) {
        if ($self->{operator}) {
            $self->{count2} .= $key;
        }
        else {
            $self->{count1} .= $key;
        }
        return 1;
    }

    # Text object introducers (i / a) in OPERATOR or VISUAL modes
    if (($key eq 'i' || $key eq 'a') && ($self->{operator} || $is_visual)) {
        $self->{pending_prefix} = $key;
        return 1;
    }

    # Multi-key prefix introducers
    if ($key eq 'g' || $key eq ']' || $key eq '[' || $key eq '<C-w>' || $key eq 'z'
        || $key eq 'f' || $key eq 'F' || $key eq 't' || $key eq 'T'
        || $key eq "'" || $key eq '`')
    {
        $self->{pending_prefix} = $key;
        $self->_whichkey_update($ed, $key) if $key eq 'g' || $key eq ']' || $key eq '[' || $key eq '<C-w>';
        return 1;
    }

    if (!$self->{operator}) {
        if ($key eq 'm' || $key eq 'r' || $key eq 'q' || $key eq '@') {
            $self->{pending_prefix} = $key;
            return 1;
        }
    }

    # Operators in NORMAL/OPERATOR/VISUAL modes
    if ($key eq 'd' || $key eq 'c' || $key eq 'y' || $key eq '>' || $key eq '<' || $key eq '=') {
        if ($is_visual) {
            return $self->_apply_operator_visual($ed, $key);
        }
        if (defined $self->{operator}) {
            if ($self->{operator} eq $key) {
                # Doubled operator (dd, cc, yy, >>, <<, ==) -> linewise count lines
                my $cnt = $self->_effective_count(1);
                my $reg = $self->{reg};
                my $op  = $self->{operator};
                $self->_reset_grammar($ed);
                return $self->_apply_linewise_operator($ed, $op, $cnt, $reg);
            }
            $self->_reset_grammar($ed);
            return 0;
        }
        $self->{operator} = $key;
        $self->set_mode($ed, 'OPERATOR');
        return 1;
    }

    # Visual-mode single-key operators
    if ($is_visual) {
        if ($key eq 'x' || $key eq 'X' || $key eq 'D') {
            return $self->_apply_operator_visual($ed, 'd');
        }
        if ($key eq 's' || $key eq 'S' || $key eq 'C') {
            return $self->_apply_operator_visual($ed, 'c');
        }
        if ($key eq 'Y') {
            return $self->_apply_operator_visual($ed, 'y');
        }
        if ($key eq '~' || $key eq 'u' || $key eq 'U') {
            my $op = $key eq '~' ? 'g~' : ($key eq 'u' ? 'gu' : 'gU');
            return $self->_apply_operator_visual($ed, $op);
        }
        if ($key eq 'o') {
            my ($l, $c) = $win->get_cursor;
            my $anc = $self->{visual_anchor};
            $self->{visual_anchor} = { line => $l, col => $c };
            $win->set_cursor($anc->{line}, $anc->{col});
            return 1;
        }
        if (($key eq 'I' || $key eq 'A') && $mode eq 'VBLOCK') {
            my $vr = $self->visual_range($ed);
            $self->{last_visual}   = $vr;
            $self->{visual_anchor} = undef;
            my $col = ($key eq 'A') ? $vr->{end_col} + 1 : $vr->{start_col};
            my $lt  = $buf->get_line($vr->{start_line}) // '';
            $col = length($lt) if $col > length($lt);
            $win->set_cursor($vr->{start_line}, $col);
            $buf->begin_undo_group;
            $self->{vblock_insert} = {
                mode       => $key,
                start_line => $vr->{start_line},
                end_line   => $vr->{end_line},
                col        => $col,
                text       => '',
            };
            $self->set_mode($ed, 'INSERT');
            return 1;
        }
        if ($key eq 'v' || $key eq 'V' || $key eq '<C-v>') {
            my $target = $key eq 'v' ? 'VISUAL' : ($key eq 'V' ? 'VLINE' : 'VBLOCK');
            if ($mode eq $target) {
                $self->{last_visual}   = $self->visual_range($ed);
                $self->{visual_anchor} = undef;
                $self->set_mode($ed, 'NORMAL');
            }
            else {
                $self->set_mode($ed, $target);
            }
            return 1;
        }
        if ($key eq ':') {
            $self->{last_visual}   = $self->visual_range($ed);
            $self->{visual_anchor} = undef;
            $self->set_mode($ed, 'COMMAND');
            $self->{cmdline_prompt} = ':';
            $self->{cmdline}        = "'<,'>";
            $self->{cmdline_pos}    = length($self->{cmdline});
            $self->{cmdline_hist_idx} = -1;
            return 1;
        }
    }

    # Motions (NORMAL, VISUAL, and OPERATOR modes)
    if ($self->_is_single_key_motion($key)) {
        return $self->_execute_motion($ed, $key);
    }

    # Remaining commands are NORMAL-mode only
    if ($self->{operator}) {
        $self->_reset_grammar($ed);
        return 0;
    }

    my $cnt = $self->_effective_count(1);
    my $has_cnt = $self->_has_explicit_count;
    my $reg = $self->{reg};
    $self->_reset_grammar($ed);

    # Visual mode entry
    if ($key eq 'v' || $key eq 'V' || $key eq '<C-v>') {
        my ($l, $c) = $win->get_cursor;
        $self->{visual_anchor} = { line => $l, col => $c };
        $self->set_mode($ed, $key eq 'v' ? 'VISUAL' : ($key eq 'V' ? 'VLINE' : 'VBLOCK'));
        return 1;
    }

    # Insert / Append / Open line
    if ($key eq 'i' || $key eq 'I' || $key eq 'a' || $key eq 'A' || $key eq 'o' || $key eq 'O') {
        $self->_start_dot($key);
        $buf->begin_undo_group;
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        if ($key eq 'I') {
            $line =~ /^(\s*)/;
            $win->set_cursor($l, length($1));
        }
        elsif ($key eq 'a') {
            $win->set_cursor($l, length($line) > 0 ? $c + 1 : 0);
        }
        elsif ($key eq 'A') {
            $win->set_cursor($l, length($line));
        }
        elsif ($key eq 'o') {
            my $off = $buf->line_col_to_byte($l, length($line));
            $buf->insert($off, "\n");
            $win->set_cursor($l + 1, 0);
        }
        elsif ($key eq 'O') {
            my $off = $buf->line_col_to_byte($l, 0);
            $buf->insert($off, "\n");
            $win->set_cursor($l, 0);
        }
        $ed->layout->ensure_cursor_visible($win);
        $self->set_mode($ed, 'INSERT');
        return 1;
    }

    # Replace mode
    if ($key eq 'R') {
        $self->_start_dot('R');
        $buf->begin_undo_group;
        $self->set_mode($ed, 'REPLACE');
        return 1;
    }

    # Single-char delete / substitute / change-to-EOL / delete-to-EOL / yank-line
    if ($key eq 'x' || $key eq 'X') {
        $self->_start_dot(($has_cnt ? split(//, "$cnt") : ()), $key);
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        my $llen = length($line);
        if ($llen > 0) {
            my ($start, $del_len);
            if ($key eq 'x') {
                $start   = $c;
                $del_len = ($c + $cnt <= $llen) ? $cnt : ($llen - $c);
            }
            else {
                $del_len = ($cnt <= $c) ? $cnt : $c;
                $start   = $c - $del_len;
            }
            if ($del_len > 0) {
                my $removed = substr($line, $start, $del_len);
                $self->_record_delete_register($reg, $removed, 'char');
                my $off = $buf->line_col_to_byte($l, $start);
                $buf->begin_undo_group;
                $buf->delete($off, $del_len);
                $buf->end_undo_group;
                $win->set_cursor($l, $start);
                $self->_clamp_cursor($ed, 0);
                $ed->emit('TextChanged', buf => $buf);
            }
        }
        $self->_finish_dot($has_cnt ? $cnt : undef);
        return 1;
    }

    if ($key eq 's') {
        $self->_start_dot(($has_cnt ? split(//, "$cnt") : ()), 's');
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        my $del_len = ($c + $cnt <= length($line)) ? $cnt : (length($line) - $c);
        $buf->begin_undo_group;
        if ($del_len > 0) {
            $self->_record_delete_register($reg, substr($line, $c, $del_len), 'char');
            $buf->delete($buf->line_col_to_byte($l, $c), $del_len);
        }
        $self->set_mode($ed, 'INSERT');
        return 1;
    }

    if ($key eq 'S') {
        return $self->_apply_linewise_operator($ed, 'c', $cnt, $reg);
    }

    if ($key eq 'D' || $key eq 'C') {
        $self->_start_dot($key);
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        my $del_len = length($line) - $c;
        $buf->begin_undo_group;
        if ($del_len > 0) {
            $self->_record_delete_register($reg, substr($line, $c, $del_len), 'char');
            $buf->delete($buf->line_col_to_byte($l, $c), $del_len);
        }
        if ($key eq 'C') {
            $self->set_mode($ed, 'INSERT');
        }
        else {
            $buf->end_undo_group;
            $self->_clamp_cursor($ed, 0);
            $self->_finish_dot;
            $ed->emit('TextChanged', buf => $buf);
        }
        return 1;
    }

    if ($key eq 'Y') {
        return $self->_apply_linewise_operator($ed, 'y', $cnt, $reg);
    }

    # Toggle case (~)
    if ($key eq '~') {
        $self->_start_dot(($has_cnt ? split(//, "$cnt") : ()), '~');
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        my $n = ($c + $cnt <= length($line)) ? $cnt : (length($line) - $c);
        if ($n > 0) {
            my $slice = substr($line, $c, $n);
            $slice =~ tr/a-zA-Z/A-Za-z/;
            my $off = $buf->line_col_to_byte($l, $c);
            $buf->begin_undo_group;
            $buf->delete($off, $n);
            $buf->insert($off, $slice);
            $buf->end_undo_group;
            $win->set_cursor($l, $c + $n);
            $self->_clamp_cursor($ed, 0);
            $ed->emit('TextChanged', buf => $buf);
        }
        $self->_finish_dot($has_cnt ? $cnt : undef);
        return 1;
    }

    # Join lines (J)
    if ($key eq 'J') {
        $self->_start_dot(($has_cnt ? split(//, "$cnt") : ()), 'J');
        my ($l, undef) = $win->get_cursor;
        my $joins = $cnt > 1 ? $cnt - 1 : 1;
        $buf->begin_undo_group;
        for (1 .. $joins) {
            last if $l + 1 >= $buf->line_count;
            my $a = $buf->get_line($l)     // '';
            my $b = $buf->get_line($l + 1) // '';
            $b =~ s/^\s+//;
            my $sep = (length($a) && length($b) && $a !~ /\s$/) ? ' ' : '';
            $buf->set_lines($l, $l + 2, [ $a . $sep . $b ]);
            $win->set_cursor($l, length($a));
        }
        $buf->end_undo_group;
        $self->_finish_dot($has_cnt ? $cnt : undef);
        $ed->emit('TextChanged', buf => $buf);
        return 1;
    }

    # Put / Paste (p / P)
    if ($key eq 'p' || $key eq 'P') {
        return $self->_put_register($ed, $reg || '"', $key eq 'p' ? 1 : 0, $cnt, $has_cnt);
    }

    # Undo / Redo
    if ($key eq 'u') {
        my $did = 0;
        for (1 .. $cnt) {
            last unless $buf->undo;
            $did++;
        }
        if ($did) {
            $self->_clamp_cursor($ed, 0);
            $ed->emit('TextChanged', buf => $buf);
        }
        return 1;
    }
    if ($key eq '<C-r>') {
        my $did = 0;
        for (1 .. $cnt) {
            last unless $buf->redo;
            $did++;
        }
        if ($did) {
            $self->_clamp_cursor($ed, 0);
            $ed->emit('TextChanged', buf => $buf);
        }
        return 1;
    }

    # Dot-repeat (.)
    if ($key eq '.') {
        return $self->_replay_dot($ed, $has_cnt ? $cnt : undef);
    }

    # Command / Search entry
    if ($key eq ':' || $key eq '/' || $key eq '?') {
        $self->{cmdline}          = '';
        $self->{cmdline_pos}      = 0;
        $self->{cmdline_prompt}   = $key;
        $self->{cmdline_hist_idx} = -1;
        $self->set_mode($ed, $key eq ':' ? 'COMMAND' : ($key eq '/' ? 'SEARCH_FWD' : 'SEARCH_BWD'));
        return 1;
    }

    # Word search (* / #)
    if ($key eq '*' || $key eq '#') {
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        my $word = _word_under_cursor($line, $c);
        if (defined $word && length $word) {
            $self->_execute_search($ed, "\\b\\Q$word\\E\\b", $key eq '*' ? 1 : -1);
        }
        return 1;
    }

    # Hover (K)
    if ($key eq 'K') {
        my ($l, $c) = $win->get_cursor;
        my $res = $ed->request_hover($buf, $l, $c);
        if (defined $res) {
            my $text = ref($res) eq 'HASH'
                ? (ref($res->{contents}) eq 'HASH' ? $res->{contents}{value} : ($res->{contents} // ''))
                : "$res";
            my @lines = split /\r?\n/, $text;
            $ed->layout->close_floats_by_kind('hover');
            $ed->layout->open_float(
                kind      => 'hover',
                title     => ' Hover ',
                relative  => 'cursor',
                width     => 60,
                height    => (@lines + 2 > 16 ? 16 : @lines + 2),
                zindex    => 70,
                focusable => 0,
                lines     => \@lines,
            );
        }
        return 1;
    }

    return 0;
}

# --- Multi-key Prefix Handling ---

sub _handle_prefix_second_key {
    my ($self, $ed, $pref, $key) = @_;
    $self->{pending_prefix} = '';
    $self->_whichkey_update($ed, undef);

    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my $mode = $self->{mode};
    my $is_visual = ($mode eq 'VISUAL' || $mode eq 'VLINE' || $mode eq 'VBLOCK');
    my $cnt  = $self->_effective_count(1);
    my $has_cnt = $self->_has_explicit_count;
    my $reg  = $self->{reg};

    # Text Objects (i{obj} / a{obj})
    if ($pref eq 'i' || $pref eq 'a') {
        my $obj_key = $pref . $key;
        my $range = $self->_resolve_text_object($ed, $buf, $win, $obj_key);
        if (!$range) {
            $self->_reset_grammar($ed);
            return 0;
        }
        if ($is_visual) {
            $self->{visual_anchor} = { line => $range->{start_line}, col => $range->{start_col} };
            $win->set_cursor($range->{end_line}, $range->{end_col});
            $self->set_mode($ed, 'VLINE') if $range->{linewise};
            $self->{count1} = '';
            $self->{count2} = '';
            return 1;
        }
        if ($self->{operator}) {
            my $op = $self->{operator};
            $self->_reset_grammar($ed);
            return $self->_apply_operator_range($ed, $op, $range, $reg, [ $op, $pref, $key ]);
        }
        return 0;
    }

    # Char find: f/F/t/T
    if ($pref eq 'f' || $pref eq 'F' || $pref eq 't' || $pref eq 'T') {
        $self->{last_find} = { kind => $pref, char => $key };
        return $self->_execute_char_find($ed, $pref, $key, $cnt);
    }

    # Single-char replace: r{c}
    if ($pref eq 'r') {
        $self->_reset_grammar($ed);
        return 0 unless length($key) == 1 || $key eq '<CR>';
        my $ch = $key eq '<CR>' ? "\n" : $key;
        $self->_start_dot(($has_cnt ? split(//, "$cnt") : ()), 'r', $key);
        my ($l, $c) = $win->get_cursor;
        my $line = $buf->get_line($l) // '';
        if ($c + $cnt <= length($line)) {
            my $off = $buf->line_col_to_byte($l, $c);
            $buf->begin_undo_group;
            $buf->delete($off, $cnt);
            $buf->insert($off, $ch x $cnt);
            $buf->end_undo_group;
            $win->set_cursor($l, $c + $cnt - 1);
            $ed->emit('TextChanged', buf => $buf);
        }
        $self->_finish_dot($has_cnt ? $cnt : undef);
        return 1;
    }

    # Set mark: m{reg}
    if ($pref eq 'm') {
        $self->_reset_grammar($ed);
        $self->set_mark($ed, $key);
        return 1;
    }

    # Jump to mark: '{m} or `{m}
    if ($pref eq "'" || $pref eq '`') {
        my $m = $self->get_mark($ed, $key);
        if (!$m) {
            $self->_reset_grammar($ed);
            $ed->notify("Mark not set: $key", 'warn');
            return 0;
        }
        if (defined $m->{buf_id} && $m->{buf_id} != $buf->id) {
            $ed->switch_buffer($m->{buf_id});
            $buf = $ed->current_buffer;
        }
        my $target_l = $m->{line};
        my $target_c = $pref eq '`' ? $m->{col} : _first_nonblank($buf->get_line($target_l) // '');
        return $self->_finish_motion_to($ed, $target_l, $target_c, ($pref eq "'" ? 1 : 0), 1);
    }

    # Start macro recording: q{a-zA-Z}
    if ($pref eq 'q') {
        $self->_reset_grammar($ed);
        if ($key =~ /^[a-zA-Z]$/) {
            $self->{macro_reg}    = lc $key;
            $self->{macro_append} = ($key =~ /^[A-Z]$/) ? 1 : 0;
            $self->{macro_buffer} = [];
            $ed->notify("Recording \@$self->{macro_reg}", 'info');
            return 1;
        }
        return 0;
    }

    # Play macro: @{a-z|@}
    if ($pref eq '@') {
        $self->_reset_grammar($ed);
        my $mreg = ($key eq '@') ? $self->{last_macro_reg} : lc($key);
        return 0 unless defined $mreg && $mreg =~ /^[a-z]$/;
        my $entry = $self->get_register($mreg);
        return 0 unless length($entry->{text} // '');
        $self->{last_macro_reg} = $mreg;
        local $self->{replaying_macro} = 1;
        for (1 .. $cnt) {
            $self->feed_keys($ed, $entry->{text});
        }
        return 1;
    }

    # Window commands: <C-w>{key}
    if ($pref eq '<C-w>') {
        $self->_reset_grammar($ed);
        my $lay = $ed->layout;
        if    ($key eq 's' || $key eq '<C-s>') { $lay->hsplit }
        elsif ($key eq 'v' || $key eq '<C-v>') { $lay->vsplit }
        elsif ($key eq 'q' || $key eq 'c')     { $lay->close_window }
        elsif ($key eq 'o')                    { $lay->only_window }
        elsif ($key eq '=')                    { $lay->equalize }
        elsif ($key eq 'h' || $key eq 'j' || $key eq 'k' || $key eq 'l') { $lay->focus_direction($key) }
        elsif ($key eq 'w' || $key eq '<C-w>') { $lay->focus_next }
        elsif ($key eq '>')                    { $lay->resize_window(undef,  $cnt, 0) }
        elsif ($key eq '<')                    { $lay->resize_window(undef, -$cnt, 0) }
        elsif ($key eq '+')                    { $lay->resize_window(undef, 0,  $cnt) }
        elsif ($key eq '-')                    { $lay->resize_window(undef, 0, -$cnt) }
        return 1;
    }

    # Scroll alignment: zz / zt / zb
    if ($pref eq 'z') {
        $self->_reset_grammar($ed);
        my $vh = $win->height || 24;
        my $l  = $win->cursor_line;
        if    ($key eq 'z') { $win->scroll_top($l - int($vh / 2) > 0 ? $l - int($vh / 2) : 0) }
        elsif ($key eq 't') { $win->scroll_top($l) }
        elsif ($key eq 'b') { $win->scroll_top($l - $vh + 1 > 0 ? $l - $vh + 1 : 0) }
        return 1;
    }

    # Bracket navigation: ]h [h ]d [d ]] [[
    if ($pref eq ']' || $pref eq '[') {
        my $dir = ($pref eq ']') ? 1 : -1;
        if ($key eq 'h' || $key eq 'c') {
            $self->_reset_grammar($ed);
            my $cur_l = $win->cursor_line;
            my $hunk = $dir > 0 ? $buf->next_hunk($cur_l) : $buf->prev_hunk($cur_l);
            if ($hunk) {
                $win->set_cursor($hunk->{cur_start}, 0);
                $ed->layout->ensure_cursor_visible($win);
                return 1;
            }
            if (my $git = $ed->plugin('git')) {
                my $gh = $dir > 0 ? $git->next_hunk($buf, $cur_l) : $git->prev_hunk($buf, $cur_l);
                if ($gh) {
                    $win->set_cursor($gh->{new_start}, 0);
                    $ed->layout->ensure_cursor_visible($win);
                    return 1;
                }
            }
            return 0;
        }
        if ($key eq 'd') {
            $self->_reset_grammar($ed);
            $dir > 0 ? $ed->next_diagnostic : $ed->prev_diagnostic;
            return 1;
        }
        if (($pref eq ']' && $key eq ']') || ($pref eq '[' && $key eq '[')) {
            my $mname = $pref . $key;
            my ($cur_l, $cur_c) = $win->get_cursor;
            if (my $hook = $self->{motion_hooks}{$mname}) {
                my $pos = eval { $hook->($ed, $buf, $cur_l, $cur_c, $cnt) };
                if (ref($pos) eq 'ARRAY') {
                    return $self->_finish_motion_to($ed, $pos->[0], $pos->[1] || 0, 1, 1);
                }
            }
            my $target_l = $self->_find_next_function($buf, $cur_l, $dir, $cnt);
            return $self->_finish_motion_to($ed, $target_l, 0, 1, 1);
        }
        $self->_reset_grammar($ed);
        return 0;
    }

    # g-prefix commands: gg, ge, gE, g-, g+, gt, gT, g~, gu, gU, gq, gv, gJ, gd, gr
    if ($pref eq 'g') {
        if ($key eq 'g') {
            my $target = $has_cnt ? ($cnt - 1) : 0;
            my $max = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
            $target = $max if $target > $max;
            return $self->_finish_motion_to($ed, $target, 0, 1, 1);
        }
        if ($key eq 'e' || $key eq 'E') {
            my ($nl, $nc) = $self->_motion_word_end_backward($buf, $win->cursor_line, $win->cursor_col, $cnt, $key eq 'E');
            return $self->_finish_motion_to($ed, $nl, $nc, 0, 1);
        }
        if ($key eq '~' || $key eq 'u' || $key eq 'U' || $key eq 'q') {
            my $op = "g$key";
            if ($is_visual) {
                return $self->_apply_operator_visual($ed, $op);
            }
            if (defined $self->{operator} && $self->{operator} eq $op) {
                $self->_reset_grammar($ed);
                return $self->_apply_linewise_operator($ed, $op, $cnt, $reg);
            }
            $self->{operator} = $op;
            $self->set_mode($ed, 'OPERATOR');
            return 1;
        }
        if ($key eq '-' || $key eq '+') {
            $self->_reset_grammar($ed);
            my $did = 0;
            for (1 .. $cnt) {
                my $ok = ($key eq '-') ? $buf->undo_older : $buf->undo_newer;
                last unless $ok;
                $did++;
            }
            if ($did) {
                $self->_clamp_cursor($ed, 0);
                $ed->emit('TextChanged', buf => $buf);
            }
            return 1;
        }
        if ($key eq 't' || $key eq 'T') {
            $self->_reset_grammar($ed);
            $key eq 't' ? $ed->layout->next_tab : $ed->layout->prev_tab;
            return 1;
        }
        if ($key eq 'v') {
            $self->_reset_grammar($ed);
            if (my $lv = $self->{last_visual}) {
                $self->{visual_anchor} = { line => $lv->{start_line}, col => $lv->{start_col} };
                $win->set_cursor($lv->{end_line}, $lv->{end_col});
                $self->set_mode($ed, $lv->{mode});
            }
            return 1;
        }
        if ($key eq 'J') {
            $self->_reset_grammar($ed);
            my ($l, undef) = $win->get_cursor;
            if ($l + 1 < $buf->line_count) {
                my $a = $buf->get_line($l)     // '';
                my $b = $buf->get_line($l + 1) // '';
                $buf->begin_undo_group;
                $buf->set_lines($l, $l + 2, [ $a . $b ]);
                $buf->end_undo_group;
                $ed->emit('TextChanged', buf => $buf);
            }
            return 1;
        }
        if ($key eq 'd') {
            $self->_reset_grammar($ed);
            my ($l, $c) = $win->get_cursor;
            my $loc = $ed->request_definition($buf, $l, $c);
            if ($loc) {
                my $first = ref($loc) eq 'ARRAY' ? $loc->[0] : $loc;
                if (ref($first) eq 'HASH') {
                    my $target = $first->{path};
                    if (!$target && defined $first->{uri}) {
                        $target = $first->{uri};
                        $target =~ s{^file://}{}i;
                    }
                    my $dl = defined($first->{line}) ? $first->{line}
                           : ($first->{range} ? $first->{range}{start}{line} : 0);
                    my $dc = defined($first->{col})  ? $first->{col}
                           : ($first->{range} ? $first->{range}{start}{character} : 0);
                    $ed->jump_to($target // $buf, $dl, $dc);
                }
            }
            return 1;
        }
        if ($key eq 'r') {
            $self->_reset_grammar($ed);
            my ($l, $c) = $win->get_cursor;
            my $refs = $ed->request_references($buf, $l, $c);
            if (ref($refs) eq 'ARRAY' && @{$refs}) {
                my @qf;
                for my $r (@{$refs}) {
                    my $p = $r->{path};
                    if (!$p && defined $r->{uri}) {
                        $p = $r->{uri};
                        $p =~ s{^file://}{}i;
                    }
                    my $rl = defined($r->{line}) ? $r->{line}
                           : ($r->{range} ? $r->{range}{start}{line} : 0);
                    my $rc = defined($r->{col})  ? $r->{col}
                           : ($r->{range} ? $r->{range}{start}{character} : 0);
                    push @qf, { path => $p, line => $rl, col => $rc, text => $r->{text} // 'reference', type => 'I' };
                }
                $ed->set_quickfix(\@qf, open => 1);
            }
            return 1;
        }
    }

    $self->_reset_grammar($ed);
    return 0;
}

# --- Motions ---

sub _is_single_key_motion {
    my ($self, $k) = @_;
    return 1 if $k =~ /^(?:h|j|k|l|0|\^|\$|_|-|\+|G|w|W|b|B|e|E|%|;|\,|n|N|\{|\}|H|M|L)$/;
    return 1 if $k eq '<Left>' || $k eq '<Right>' || $k eq '<Up>' || $k eq '<Down>'
             || $k eq '<Home>' || $k eq '<End>' || $k eq '<CR>'
             || $k eq '<C-d>'  || $k eq '<C-u>' || $k eq '<C-f>' || $k eq '<C-b>';
    return 0;
}

sub _first_nonblank {
    my ($line) = @_;
    return 0 unless defined $line;
    return $line =~ /^(\s*)/ ? length($1) : 0;
}

sub _word_under_cursor {
    my ($line, $col) = @_;
    return undef unless defined $line && length $line;
    $col = length($line) - 1 if $col >= length($line);
    return undef unless substr($line, $col, 1) =~ /\w/;
    my $s = $col;
    $s-- while $s > 0 && substr($line, $s - 1, 1) =~ /\w/;
    my $e = $col;
    $e++ while $e + 1 < length($line) && substr($line, $e + 1, 1) =~ /\w/;
    return substr($line, $s, $e - $s + 1);
}

sub _execute_motion {
    my ($self, $ed, $key) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my ($l, $c) = $win->get_cursor;
    my $nlines   = $buf->line_count;
    my $max_line = $nlines > 0 ? $nlines - 1 : 0;
    my $cnt      = $self->_effective_count(1);
    my $has_cnt  = $self->_has_explicit_count;
    my $line     = $buf->get_line($l) // '';
    my $llen     = length($line);

    my ($nl, $nc) = ($l, $c);
    my $linewise  = 0;
    my $inclusive = 0;

    if ($key eq 'h' || $key eq '<Left>') {
        $nc = $c - $cnt;
        $nc = 0 if $nc < 0;
    }
    elsif ($key eq 'l' || $key eq '<Right>') {
        $nc = $c + $cnt;
        my $max_c = $self->{operator} ? $llen : ($llen > 0 ? $llen - 1 : 0);
        $nc = $max_c if $nc > $max_c;
    }
    elsif ($key eq 'j' || $key eq '<Down>') {
        $nl = $l + $cnt;
        $nl = $max_line if $nl > $max_line;
        my $tlen = length($buf->get_line($nl) // '');
        $nc = $win->desired_col;
        $nc = $tlen > 0 ? $tlen - 1 : 0 if $nc >= $tlen;
        $linewise = 1;
        return $self->_finish_motion_to($ed, $nl, $nc, $linewise, 0, 1);
    }
    elsif ($key eq 'k' || $key eq '<Up>') {
        $nl = $l - $cnt;
        $nl = 0 if $nl < 0;
        my $tlen = length($buf->get_line($nl) // '');
        $nc = $win->desired_col;
        $nc = $tlen > 0 ? $tlen - 1 : 0 if $nc >= $tlen;
        $linewise = 1;
        return $self->_finish_motion_to($ed, $nl, $nc, $linewise, 0, 1);
    }
    elsif ($key eq '0' || $key eq '<Home>') {
        $nc = 0;
    }
    elsif ($key eq '^') {
        $nc = _first_nonblank($line);
    }
    elsif ($key eq '_') {
        $nl = $l + $cnt - 1;
        $nl = $max_line if $nl > $max_line;
        $nc = _first_nonblank($buf->get_line($nl) // '');
        $linewise = 1;
    }
    elsif ($key eq '$' || $key eq '<End>') {
        $nl = $l + $cnt - 1;
        $nl = $max_line if $nl > $max_line;
        my $tlen = length($buf->get_line($nl) // '');
        $nc = $tlen > 0 ? $tlen - 1 : 0;
        $inclusive = 1;
    }
    elsif ($key eq '+' || $key eq '<CR>') {
        $nl = $l + $cnt;
        $nl = $max_line if $nl > $max_line;
        $nc = _first_nonblank($buf->get_line($nl) // '');
        $linewise = 1;
    }
    elsif ($key eq '-') {
        $nl = $l - $cnt;
        $nl = 0 if $nl < 0;
        $nc = _first_nonblank($buf->get_line($nl) // '');
        $linewise = 1;
    }
    elsif ($key eq 'G') {
        $nl = $has_cnt ? ($cnt - 1) : $max_line;
        $nl = $max_line if $nl > $max_line;
        $nl = 0 if $nl < 0;
        $nc = _first_nonblank($buf->get_line($nl) // '');
        $linewise = 1;
    }
    elsif ($key eq 'w' || $key eq 'W') {
        my $for_change = (defined($self->{operator}) && $self->{operator} eq 'c') ? 1 : 0;
        if ($for_change) {
            ($nl, $nc) = $self->_motion_word_end_forward($buf, $l, $c, $cnt, $key eq 'W');
            $inclusive = 1;
        }
        else {
            ($nl, $nc) = $self->_motion_word_forward($buf, $l, $c, $cnt, $key eq 'W', defined($self->{operator}));
        }
    }
    elsif ($key eq 'b' || $key eq 'B') {
        ($nl, $nc) = $self->_motion_word_backward($buf, $l, $c, $cnt, $key eq 'B');
    }
    elsif ($key eq 'e' || $key eq 'E') {
        ($nl, $nc) = $self->_motion_word_end_forward($buf, $l, $c, $cnt, $key eq 'E');
        $inclusive = 1;
    }
    elsif ($key eq '%') {
        my ($bl, $bc) = $self->_find_matching_bracket($buf, $l, $c);
        if (defined $bl) {
            ($nl, $nc) = ($bl, $bc);
            $inclusive = 1;
        }
        else {
            $self->_reset_grammar($ed);
            return 0;
        }
    }
    elsif ($key eq ';' || $key eq ',') {
        my $lf = $self->{last_find};
        if (!$lf) {
            $self->_reset_grammar($ed);
            return 0;
        }
        my $kind = $lf->{kind};
        if ($key eq ',') {
            $kind =~ tr/fFtT/FfTt/;
        }
        return $self->_execute_char_find($ed, $kind, $lf->{char}, $cnt, 1);
    }
    elsif ($key eq 'n' || $key eq 'N') {
        my $st  = $ed->search_state;
        my $dir = ($st->{direction} || 1) * ($key eq 'n' ? 1 : -1);
        $self->_reset_grammar($ed);
        $self->_jump_search($ed, $dir);
        return 1;
    }
    elsif ($key eq '{' || $key eq '}') {
        $nl = $self->_motion_paragraph($buf, $l, $key eq '}' ? 1 : -1, $cnt);
        $nc = 0;
        $linewise = 1;
    }
    elsif ($key eq 'H' || $key eq 'M' || $key eq 'L') {
        my $top = $win->scroll_top;
        my $vh  = $win->height || 24;
        my $bot = $top + $vh - 1;
        $bot = $max_line if $bot > $max_line;
        $nl = $key eq 'H' ? $top : ($key eq 'L' ? $bot : int(($top + $bot) / 2));
        $nc = _first_nonblank($buf->get_line($nl) // '');
        $linewise = 1;
    }
    elsif ($key eq '<C-d>' || $key eq '<C-u>' || $key eq '<C-f>' || $key eq '<C-b>') {
        my $vh   = $win->height || 24;
        my $step = ($key eq '<C-d>' || $key eq '<C-u>') ? int($vh / 2) : $vh;
        $step = 1 if $step < 1;
        my $dir  = ($key eq '<C-d>' || $key eq '<C-f>') ? 1 : -1;
        $nl = $l + $dir * $step * $cnt;
        $nl = 0         if $nl < 0;
        $nl = $max_line if $nl > $max_line;
        $nc = _first_nonblank($buf->get_line($nl) // '');
        $linewise = 1;
    }

    return $self->_finish_motion_to($ed, $nl, $nc, $linewise, $inclusive, 0, $key);
}

sub _finish_motion_to {
    my ($self, $ed, $nl, $nc, $linewise, $inclusive, $keep_desired, $motion_key) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;

    if (defined $self->{operator}) {
        my $op  = $self->{operator};
        my $reg = $self->{reg};
        my ($sl, $sc) = $win->get_cursor;
        my ($el, $ec) = ($nl, $nc);

        my $backward = ($el < $sl || ($el == $sl && $ec < $sc));
        if ($backward) {
            ($sl, $sc, $el, $ec) = ($el, $ec, $sl, $sc);
        }

        my $range = {
            start_line => $sl,
            start_col  => $sc,
            end_line   => $el,
            end_col    => $ec,
            linewise   => $linewise ? 1 : 0,
            exclusive  => ($linewise || $inclusive) ? 0 : 1,
        };
        my @dot_keys;
        push @dot_keys, split(//, $self->{count1}) if length($self->{count1});
        push @dot_keys, $op;
        push @dot_keys, split(//, $self->{count2}) if length($self->{count2});
        push @dot_keys, $motion_key if defined $motion_key;
        $self->_reset_grammar($ed);
        return $self->_apply_operator_range($ed, $op, $range, $reg, \@dot_keys);
    }

    my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
    $nl = 0         if $nl < 0;
    $nl = $max_line if $nl > $max_line;
    my $tlen = length($buf->get_line($nl) // '');
    my $max_c = $tlen > 0 ? $tlen - 1 : 0;
    $nc = 0      if $nc < 0;
    $nc = $max_c if $nc > $max_c;

    $win->set_cursor($nl, $nc, $keep_desired);
    $ed->layout->ensure_cursor_visible($win);
    $self->_reset_grammar($ed);
    $ed->emit('CursorMoved', win => $win, buf => $buf, line => $nl, col => $nc);
    return 1;
}

sub _execute_char_find {
    my ($self, $ed, $kind, $ch, $cnt, $is_repeat) = @_;
    my $buf  = $ed->current_buffer or return 0;
    my $win  = $ed->current_window or return 0;
    my ($l, $c) = $win->get_cursor;
    my $line = $buf->get_line($l) // '';
    my $len  = length($line);

    my $dir = ($kind eq 'f' || $kind eq 't') ? 1 : -1;
    my $pos = $c;
    # Vim rule: repeating t/T skips past an immediately adjacent match
    if ($is_repeat && ($kind eq 't' || $kind eq 'T')) {
        my $adj = $pos + $dir;
        if ($adj >= 0 && $adj < $len && substr($line, $adj, 1) eq $ch) {
            $pos = $adj;
        }
    }
    my $found = 0;
    for (1 .. $cnt) {
        my $step = $pos + $dir;
        $found = 0;
        while ($step >= 0 && $step < $len) {
            if (substr($line, $step, 1) eq $ch) {
                $pos   = $step;
                $found = 1;
                last;
            }
            $step += $dir;
        }
        last unless $found;
    }

    if (!$found) {
        $self->_reset_grammar($ed);
        return 0;
    }

    my $target_c = $kind eq 't' ? ($pos - 1)
                 : $kind eq 'T' ? ($pos + 1)
                 : $pos;
    return $self->_finish_motion_to($ed, $l, $target_c, 0, ($dir > 0 ? 1 : 0), 0);
}

# --- Word, Bracket, Paragraph, Function Motions ---

sub _char_class {
    my ($ch, $big) = @_;
    return 0 if $ch =~ /\s/;
    return 1 if $big;
    return 1 if $ch =~ /\w/;
    return 2;
}

sub _motion_word_forward {
    my ($self, $buf, $l, $c, $cnt, $big, $for_op) = @_;
    my $nlines = $buf->line_count;
    for (1 .. $cnt) {
        my $line = $buf->get_line($l) // '';
        my $len  = length($line);
        if ($c < $len) {
            my $cls = _char_class(substr($line, $c, 1), $big);
            if ($cls > 0) {
                $c++ while $c < $len && _char_class(substr($line, $c, 1), $big) == $cls;
            }
            $c++ while $c < $len && substr($line, $c, 1) =~ /\s/;
        }
        if ($c >= $len) {
            if ($for_op && $_ == $cnt) {
                return ($l, $len);
            }
            if ($l + 1 < $nlines) {
                $l++;
                $line = $buf->get_line($l) // '';
                $len  = length($line);
                $c    = 0;
                $c++ while $c < $len && substr($line, $c, 1) =~ /\s/;
            }
            else {
                $c = $len > 0 ? $len - 1 : 0;
                last;
            }
        }
    }
    return ($l, $c);
}

sub _motion_word_backward {
    my ($self, $buf, $l, $c, $cnt, $big) = @_;
    for (1 .. $cnt) {
        my $line = $buf->get_line($l) // '';
        if ($c == 0) {
            last if $l == 0;
            $l--;
            $line = $buf->get_line($l) // '';
            $c    = length($line);
        }
        $c-- if $c > 0;
        $c-- while $c > 0 && substr($line, $c, 1) =~ /\s/;
        while ($c == 0 && substr($line, 0, 1) =~ /\s/ && $l > 0) {
            $l--;
            $line = $buf->get_line($l) // '';
            $c    = length($line) > 0 ? length($line) - 1 : 0;
            $c-- while $c > 0 && substr($line, $c, 1) =~ /\s/;
        }
        if ($c < length($line)) {
            my $cls = _char_class(substr($line, $c, 1), $big);
            $c-- while $c > 0 && _char_class(substr($line, $c - 1, 1), $big) == $cls;
        }
    }
    return ($l, $c);
}

sub _motion_word_end_forward {
    my ($self, $buf, $l, $c, $cnt, $big) = @_;
    my $nlines = $buf->line_count;
    for (1 .. $cnt) {
        my $line = $buf->get_line($l) // '';
        my $len  = length($line);
        $c++;
        while (1) {
            while ($c < $len && substr($line, $c, 1) =~ /\s/) { $c++ }
            last if $c < $len;
            if ($l + 1 < $nlines) {
                $l++;
                $line = $buf->get_line($l) // '';
                $len  = length($line);
                $c    = 0;
            }
            else {
                return ($l, $len > 0 ? $len - 1 : 0);
            }
        }
        my $cls = _char_class(substr($line, $c, 1), $big);
        $c++ while $c + 1 < $len && _char_class(substr($line, $c + 1, 1), $big) == $cls;
    }
    return ($l, $c);
}

sub _motion_word_end_backward {
    my ($self, $buf, $l, $c, $cnt, $big) = @_;
    for (1 .. $cnt) {
        my $line = $buf->get_line($l) // '';
        if ($c < length($line)) {
            my $cls = _char_class(substr($line, $c, 1), $big);
            $c-- while $c >= 0 && _char_class(substr($line, $c, 1), $big) == $cls;
        }
        else {
            $c--;
        }
        while (1) {
            while ($c >= 0 && substr($line, $c, 1) =~ /\s/) { $c-- }
            last if $c >= 0;
            last if $l == 0;
            $l--;
            $line = $buf->get_line($l) // '';
            $c    = length($line) - 1;
        }
        $c = 0 if $c < 0;
    }
    return ($l, $c);
}

sub _find_matching_bracket {
    my ($self, $buf, $l, $c) = @_;
    my $line = $buf->get_line($l) // '';
    my $open_col = $c;
    my $ch;
    while ($open_col < length($line)) {
        my $t = substr($line, $open_col, 1);
        if (exists $BRACKET_PAIRS{$t}) {
            $ch = $t;
            last;
        }
        $open_col++;
    }
    return () unless defined $ch;

    my ($target, $dir) = @{ $BRACKET_PAIRS{$ch} };
    my $depth  = 0;
    my $nlines = $buf->line_count;
    my $cur_l  = $l;
    my $cur_c  = $open_col;

    while ($cur_l >= 0 && $cur_l < $nlines) {
        my $lt  = $buf->get_line($cur_l) // '';
        my $len = length($lt);
        while ($cur_c >= 0 && $cur_c < $len) {
            my $x = substr($lt, $cur_c, 1);
            $depth++ if $x eq $ch;
            $depth-- if $x eq $target;
            return ($cur_l, $cur_c) if $depth == 0;
            $cur_c += $dir;
        }
        $cur_l += $dir;
        last if $cur_l < 0 || $cur_l >= $nlines;
        $lt    = $buf->get_line($cur_l) // '';
        $cur_c = $dir > 0 ? 0 : (length($lt) - 1);
    }
    return ();
}

sub _motion_paragraph {
    my ($self, $buf, $l, $dir, $cnt) = @_;
    my $n = $buf->line_count;
    return 0 unless $n > 0;
    for (1 .. $cnt) {
        $l += $dir;
        while ($l > 0 && $l < $n - 1 && ($buf->get_line($l) // '') =~ /^\s*$/) {
            $l += $dir;
        }
        while ($l > 0 && $l < $n - 1 && ($buf->get_line($l) // '') !~ /^\s*$/) {
            $l += $dir;
        }
        $l = 0      if $l < 0;
        $l = $n - 1 if $l >= $n;
    }
    return $l;
}

sub _find_next_function {
    my ($self, $buf, $l, $dir, $cnt) = @_;
    my $n = $buf->line_count;
    return 0 unless $n > 0;
    for (1 .. $cnt) {
        my $cur = $l + $dir;
        while ($cur >= 0 && $cur < $n) {
            my $line = $buf->get_line($cur) // '';
            if ($line =~ /^\s*(?:sub\s+\w+|def\s+\w+|func\s+\w+|fn\s+\w+|function\s+\w+)/
                || $line =~ /^\{/)
            {
                $l = $cur;
                last;
            }
            $cur += $dir;
        }
    }
    return $l;
}

# --- Text Objects ---

sub _resolve_text_object {
    my ($self, $ed, $buf, $win, $obj) = @_;
    my ($l, $c) = $win->get_cursor;

    # Check plugin-registered text object hooks first (e.g. PPI / Tree-sitter if/af/ip/ap)
    if (my $hook = $self->{text_object_hooks}{$obj}) {
        my $res = eval { $hook->($ed, $buf, $l, $c) };
        return $res if ref($res) eq 'HASH' && defined $res->{start_line};
    }

    my $inner = (substr($obj, 0, 1) eq 'i') ? 1 : 0;
    my $kind  = substr($obj, 1, 1);

    # iw / aw / iW / aW
    if ($kind eq 'w' || $kind eq 'W') {
        my $big  = ($kind eq 'W');
        my $line = $buf->get_line($l) // '';
        my $len  = length($line);
        return undef unless $len > 0;
        $c = $len - 1 if $c >= $len;
        my $cls = _char_class(substr($line, $c, 1), $big);
        my ($s, $e) = ($c, $c);
        $s-- while $s > 0        && _char_class(substr($line, $s - 1, 1), $big) == $cls;
        $e++ while $e + 1 < $len && _char_class(substr($line, $e + 1, 1), $big) == $cls;
        if (!$inner) {
            if ($e + 1 < $len && substr($line, $e + 1, 1) =~ /\s/) {
                $e++ while $e + 1 < $len && substr($line, $e + 1, 1) =~ /\s/;
            }
            elsif ($s > 0 && substr($line, $s - 1, 1) =~ /\s/) {
                $s-- while $s > 0 && substr($line, $s - 1, 1) =~ /\s/;
            }
        }
        return { start_line => $l, start_col => $s, end_line => $l, end_col => $e, linewise => 0 };
    }

    # Quotes: i"/a", i'/a', i`/a`
    if ($kind eq '"' || $kind eq "'" || $kind eq '`') {
        my $line = $buf->get_line($l) // '';
        my @qs;
        my $i = 0;
        while ($i < length($line)) {
            my $ch = substr($line, $i, 1);
            if ($ch eq '\\') { $i += 2; next }
            push @qs, $i if $ch eq $kind;
            $i++;
        }
        my ($open, $close);
        for (my $j = 0; $j + 1 < @qs; $j += 2) {
            if ($c >= $qs[$j] && $c <= $qs[$j + 1]) {
                ($open, $close) = ($qs[$j], $qs[$j + 1]);
                last;
            }
            if (!defined $open && $qs[$j] >= $c) {
                ($open, $close) = ($qs[$j], $qs[$j + 1]);
                last;
            }
        }
        return undef unless defined $open && defined $close;
        if ($inner) {
            return {
                start_line => $l, start_col => $open + 1,
                end_line   => $l, end_col   => $close - 1,
                empty      => ($close - $open <= 1 ? 1 : 0),
                linewise   => 0,
            };
        }
        return { start_line => $l, start_col => $open, end_line => $l, end_col => $close, linewise => 0 };
    }

    # Delimited pairs: (), [], {}, <>
    my %pair_map = (
        '(' => ['(', ')'], ')' => ['(', ')'], 'b' => ['(', ')'],
        '[' => ['[', ']'], ']' => ['[', ']'],
        '{' => ['{', '}'], '}' => ['{', '}'], 'B' => ['{', '}'],
        '<' => ['<', '>'], '>' => ['<', '>'],
    );
    if (exists $pair_map{$kind}) {
        my ($op_ch, $cl_ch) = @{ $pair_map{$kind} };
        return $self->_find_enclosing_pair($buf, $l, $c, $op_ch, $cl_ch, $inner);
    }

    # Paragraph: ip / ap
    if ($kind eq 'p') {
        my $n = $buf->line_count;
        return undef unless $n > 0;
        my $blank = (($buf->get_line($l) // '') =~ /^\s*$/) ? 1 : 0;
        my ($s, $e) = ($l, $l);
        if ($blank) {
            $s-- while $s > 0      && ($buf->get_line($s - 1) // '') =~ /^\s*$/;
            $e++ while $e + 1 < $n && ($buf->get_line($e + 1) // '') =~ /^\s*$/;
        }
        else {
            $s-- while $s > 0      && ($buf->get_line($s - 1) // '') !~ /^\s*$/;
            $e++ while $e + 1 < $n && ($buf->get_line($e + 1) // '') !~ /^\s*$/;
            if (!$inner) {
                if ($e + 1 < $n && ($buf->get_line($e + 1) // '') =~ /^\s*$/) {
                    $e++ while $e + 1 < $n && ($buf->get_line($e + 1) // '') =~ /^\s*$/;
                }
                elsif ($s > 0 && ($buf->get_line($s - 1) // '') =~ /^\s*$/) {
                    $s-- while $s > 0 && ($buf->get_line($s - 1) // '') =~ /^\s*$/;
                }
            }
        }
        return {
            start_line => $s, start_col => 0,
            end_line   => $e, end_col   => length($buf->get_line($e) // ''),
            linewise   => 1,
        };
    }

    # Function / subroutine fallback: if / af
    if ($kind eq 'f') {
        my $pair = $self->_find_enclosing_pair($buf, $l, $c, '{', '}', $inner);
        return undef unless $pair;
        if (!$inner) {
            # Walk back to include function header line (e.g. `sub foo {` or `int bar(...)`)
            my $sl = $pair->{start_line};
            if ($sl > 0 && ($buf->get_line($sl) // '') =~ /^\s*\{/) {
                $sl--;
            }
            return {
                start_line => $sl, start_col => 0,
                end_line   => $pair->{end_line},
                end_col    => length($buf->get_line($pair->{end_line}) // ''),
                linewise   => 1,
            };
        }
        return $pair;
    }

    return undef;
}

sub _find_enclosing_pair {
    my ($self, $buf, $l, $c, $op_ch, $cl_ch, $inner) = @_;
    my $text = $buf->get_text;
    my $pos  = $buf->line_col_to_byte($l, $c);
    my $len  = length($text);
    return undef unless $len > 0;
    $pos = $len - 1 if $pos >= $len;

    # Search backward for unmatched opener
    my $open_pos;
    my $depth = 0;
    for (my $i = $pos; $i >= 0; $i--) {
        my $ch = substr($text, $i, 1);
        if ($ch eq $cl_ch && $i < $pos) {
            $depth++;
        }
        elsif ($ch eq $op_ch) {
            if ($depth == 0) {
                $open_pos = $i;
                last;
            }
            $depth--;
        }
    }
    # If not inside, search forward on current line for opener
    if (!defined $open_pos) {
        my $line = $buf->get_line($l) // '';
        my $idx  = index($line, $op_ch, $c);
        $open_pos = $buf->line_col_to_byte($l, $idx) if $idx >= 0;
    }
    return undef unless defined $open_pos;

    # Search forward from open_pos for matching closer
    my $close_pos;
    $depth = 0;
    for (my $i = $open_pos; $i < $len; $i++) {
        my $ch = substr($text, $i, 1);
        $depth++ if $ch eq $op_ch;
        $depth-- if $ch eq $cl_ch;
        if ($depth == 0) {
            $close_pos = $i;
            last;
        }
    }
    return undef unless defined $close_pos;

    if ($inner) {
        if ($close_pos <= $open_pos + 1) {
            my ($sl, $sc) = $buf->byte_to_line_col($open_pos + 1);
            return { start_line => $sl, start_col => $sc, end_line => $sl, end_col => $sc, empty => 1, linewise => 0 };
        }
        my ($sl, $sc) = $buf->byte_to_line_col($open_pos + 1);
        my ($el, $ec) = $buf->byte_to_line_col($close_pos - 1);
        return { start_line => $sl, start_col => $sc, end_line => $el, end_col => $ec, linewise => 0 };
    }

    my ($sl, $sc) = $buf->byte_to_line_col($open_pos);
    my ($el, $ec) = $buf->byte_to_line_col($close_pos);
    return { start_line => $sl, start_col => $sc, end_line => $el, end_col => $ec, linewise => 0 };
}

# --- Operators Execution ---

sub _apply_linewise_operator {
    my ($self, $ed, $op, $cnt, $reg) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my $sl  = $win->cursor_line;
    my $el  = $sl + $cnt - 1;
    my $max = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
    $el = $max if $el > $max;

    my @dot = ($cnt > 1 ? split(//, "$cnt") : ());
    if (length($op) == 1) {
        push @dot, $op, $op;
    }
    else {
        push @dot, substr($op, 0, 1), substr($op, 1, 1), substr($op, 1, 1);
    }

    return $self->_apply_operator_range($ed, $op, {
        start_line => $sl,
        start_col  => 0,
        end_line   => $el,
        end_col    => length($buf->get_line($el) // ''),
        linewise   => 1,
    }, $reg, \@dot);
}

sub _apply_operator_visual {
    my ($self, $ed, $op) = @_;
    my $vr = $self->visual_range($ed) or return 0;
    my $reg = $self->{reg};
    $self->{last_visual}   = $vr;
    $self->{visual_anchor} = undef;
    $self->_reset_grammar($ed);

    if ($vr->{mode} eq 'VBLOCK') {
        return $self->_apply_operator_vblock($ed, $op, $vr, $reg);
    }

    my $range = {
        start_line => $vr->{start_line},
        start_col  => $vr->{start_col},
        end_line   => $vr->{end_line},
        end_col    => $vr->{end_col},
        linewise   => ($vr->{mode} eq 'VLINE') ? 1 : 0,
        exclusive  => 0,
    };
    $self->set_mode($ed, 'NORMAL');
    return $self->_apply_operator_range($ed, $op, $range, $reg);
}

sub _apply_operator_vblock {
    my ($self, $ed, $op, $vr, $reg) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my ($sl, $el, $sc, $ec) = ($vr->{start_line}, $vr->{end_line}, $vr->{start_col}, $vr->{end_col});

    my @yanked;
    for my $l ($sl .. $el) {
        my $line = $buf->get_line($l) // '';
        my $seg  = $sc < length($line) ? substr($line, $sc, $ec - $sc + 1) : '';
        push @yanked, $seg;
    }

    if ($op eq 'y') {
        $self->_record_yank_register($reg, join("\n", @yanked), 'block');
        $win->set_cursor($sl, $sc);
        $self->set_mode($ed, 'NORMAL');
        return 1;
    }

    if ($op eq 'd' || $op eq 'c') {
        $self->_record_delete_register($reg, join("\n", @yanked), 'block');
        $buf->begin_undo_group;
        for my $l (reverse $sl .. $el) {
            my $line = $buf->get_line($l) // '';
            next if $sc >= length($line);
            my $w = $ec - $sc + 1;
            $w = length($line) - $sc if $sc + $w > length($line);
            my $off = $buf->line_col_to_byte($l, $sc);
            $buf->delete($off, $w);
        }
        $win->set_cursor($sl, $sc);
        if ($op eq 'c') {
            $self->{vblock_insert} = {
                mode       => 'I',
                start_line => $sl,
                end_line   => $el,
                col        => $sc,
                text       => '',
            };
            $self->set_mode($ed, 'INSERT');
        }
        else {
            $buf->end_undo_group;
            $self->set_mode($ed, 'NORMAL');
            $self->_clamp_cursor($ed, 0);
            $ed->emit('TextChanged', buf => $buf);
        }
        return 1;
    }

    if ($op eq 'g~' || $op eq 'gu' || $op eq 'gU') {
        $buf->begin_undo_group;
        for my $l ($sl .. $el) {
            my $line = $buf->get_line($l) // '';
            next if $sc >= length($line);
            my $w = $ec - $sc + 1;
            $w = length($line) - $sc if $sc + $w > length($line);
            my $seg = substr($line, $sc, $w);
            if    ($op eq 'gu') { $seg = lc $seg }
            elsif ($op eq 'gU') { $seg = uc $seg }
            else                { $seg =~ tr/a-zA-Z/A-Za-z/ }
            my $off = $buf->line_col_to_byte($l, $sc);
            $buf->delete($off, $w);
            $buf->insert($off, $seg);
        }
        $buf->end_undo_group;
        $win->set_cursor($sl, $sc);
        $self->set_mode($ed, 'NORMAL');
        $ed->emit('TextChanged', buf => $buf);
        return 1;
    }

    $self->set_mode($ed, 'NORMAL');
    return 0;
}

sub _apply_operator_range {
    my ($self, $ed, $op, $range, $reg, $dot_keys) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my ($sl, $sc, $el, $ec) = ($range->{start_line}, $range->{start_col}, $range->{end_line}, $range->{end_col});
    my $linewise = $range->{linewise} ? 1 : 0;

    if ($dot_keys && @{$dot_keys} && $op ne 'y') {
        $self->_start_dot(@{$dot_keys});
    }

    # Indent / Dedent
    if ($op eq '>' || $op eq '<') {
        my $sw  = $ed->get_option('shiftwidth') || 4;
        my $pad = $ed->get_option('expandtab') ? (' ' x $sw) : "\t";
        $buf->begin_undo_group;
        my @updated;
        for my $l ($sl .. $el) {
            my $line = $buf->get_line($l) // '';
            if ($op eq '>') {
                $line = length($line) ? ($pad . $line) : $line;
            }
            else {
                if ($line =~ s/^\t//) {
                    # removed one tab
                }
                else {
                    $line =~ s/^ {1,$sw}//;
                }
            }
            push @updated, $line;
        }
        $buf->set_lines($sl, $el + 1, \@updated);
        $buf->end_undo_group;
        $win->set_cursor($sl, _first_nonblank($buf->get_line($sl) // ''));
        $self->_finish_dot;
        $ed->emit('TextChanged', buf => $buf);
        return 1;
    }

    # Format (gq / =)
    if ($op eq 'gq' || $op eq '=') {
        my $ft = $buf->filetype || '';
        my $fmt = $self->{formatters}{$ft} || $self->{formatters}{'*'};
        if ($fmt) {
            my $new_lines = eval { $fmt->($ed, $buf, $sl, $el) };
            if (ref($new_lines) eq 'ARRAY') {
                $buf->begin_undo_group;
                $buf->set_lines($sl, $el + 1, $new_lines);
                $buf->end_undo_group;
                $self->_finish_dot;
                $ed->emit('TextChanged', buf => $buf);
                return 1;
            }
        }
        # Clean built-in wrap fallback for gq (80-col word wrap)
        if ($op eq 'gq') {
            my $joined = join(' ', map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } @{ $buf->get_lines($sl, $el + 1) });
            my @wrapped;
            while (length($joined) > 80) {
                my $cut = rindex($joined, ' ', 80);
                $cut = 80 if $cut <= 0;
                push @wrapped, substr($joined, 0, $cut);
                $joined = substr($joined, $cut);
                $joined =~ s/^\s+//;
            }
            push @wrapped, $joined if length($joined) || !@wrapped;
            $buf->begin_undo_group;
            $buf->set_lines($sl, $el + 1, \@wrapped);
            $buf->end_undo_group;
            $self->_finish_dot;
            $ed->emit('TextChanged', buf => $buf);
            return 1;
        }
        $self->_finish_dot;
        return 1;
    }

    # Linewise y / d / c / case
    if ($linewise) {
        my $lines = $buf->get_lines($sl, $el + 1);
        my $text  = join("\n", @{$lines}) . "\n";

        if ($op eq 'y') {
            $self->_record_yank_register($reg, $text, 'line');
            return 1;
        }
        if ($op eq 'd') {
            $self->_record_delete_register($reg, $text, 'line');
            $buf->begin_undo_group;
            $buf->set_lines($sl, $el + 1, []);
            $buf->end_undo_group;
            my $max = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
            $win->set_cursor($sl > $max ? $max : $sl, 0);
            $self->_clamp_cursor($ed, 0);
            $self->_finish_dot;
            $ed->emit('TextChanged', buf => $buf);
            return 1;
        }
        if ($op eq 'c') {
            $self->_record_delete_register($reg, $text, 'line');
            $buf->begin_undo_group;
            $buf->set_lines($sl, $el + 1, ['']);
            $win->set_cursor($sl, 0);
            $self->set_mode($ed, 'INSERT');
            return 1;
        }
        if ($op eq 'g~' || $op eq 'gu' || $op eq 'gU') {
            my @upd = map {
                my $s = $_;
                if    ($op eq 'gu') { $s = lc $s }
                elsif ($op eq 'gU') { $s = uc $s }
                else                { $s =~ tr/a-zA-Z/A-Za-z/ }
                $s;
            } @{$lines};
            $buf->begin_undo_group;
            $buf->set_lines($sl, $el + 1, \@upd);
            $buf->end_undo_group;
            $self->_finish_dot;
            $ed->emit('TextChanged', buf => $buf);
            return 1;
        }
        return 0;
    }

    # Characterwise range
    if ($range->{empty}) {
        if ($op eq 'c') {
            $win->set_cursor($sl, $sc);
            $buf->begin_undo_group;
            $self->set_mode($ed, 'INSERT');
        }
        return 1;
    }

    my $start_off = $buf->line_col_to_byte($sl, $sc);
    my $end_off   = $buf->line_col_to_byte($el, $ec);
    if (!$range->{exclusive}) {
        my $eline = $buf->get_line($el) // '';
        $end_off++ if $ec < length($eline);
    }
    my $span = $end_off - $start_off;
    $span = 0 if $span < 0;

    my $full_text = $buf->get_text;
    my $selected  = $span > 0 ? substr($full_text, $start_off, $span) : '';

    if ($op eq 'y') {
        $self->_record_yank_register($reg, $selected, 'char');
        $win->set_cursor($sl, $sc);
        return 1;
    }

    if ($op eq 'd' || $op eq 'c') {
        $self->_record_delete_register($reg, $selected, 'char');
        $buf->begin_undo_group;
        $buf->delete($start_off, $span) if $span > 0;
        $win->set_cursor($sl, $sc);
        if ($op eq 'c') {
            $self->set_mode($ed, 'INSERT');
        }
        else {
            $buf->end_undo_group;
            $self->_clamp_cursor($ed, 0);
            $self->_finish_dot;
            $ed->emit('TextChanged', buf => $buf);
        }
        return 1;
    }

    if ($op eq 'g~' || $op eq 'gu' || $op eq 'gU') {
        if ($span > 0) {
            my $rep = $selected;
            if    ($op eq 'gu') { $rep = lc $rep }
            elsif ($op eq 'gU') { $rep = uc $rep }
            else                { $rep =~ tr/a-zA-Z/A-Za-z/ }
            $buf->begin_undo_group;
            $buf->delete($start_off, $span);
            $buf->insert($start_off, $rep);
            $buf->end_undo_group;
            $ed->emit('TextChanged', buf => $buf);
        }
        $self->_finish_dot;
        return 1;
    }

    return 0;
}

# --- Put / Paste ---

sub _put_register {
    my ($self, $ed, $reg_name, $after, $cnt, $has_cnt) = @_;
    my $buf = $ed->current_buffer or return 0;
    my $win = $ed->current_window or return 0;
    my $entry = $self->get_register($reg_name);
    my $text  = $entry->{text} // '';
    my $type  = $entry->{type} || 'char';
    return 0 unless length $text;

    $self->_start_dot(($has_cnt ? split(//, "$cnt") : ()), ($after ? 'p' : 'P'));
    my ($l, $c) = $win->get_cursor;
    $buf->begin_undo_group;

    if ($type eq 'line') {
        my $body = $text;
        $body =~ s/\n\z//;
        my @lines = split /\n/, $body, -1;
        my @rep;
        push @rep, @lines for 1 .. $cnt;
        my $insert_at = $after ? ($l + 1) : $l;
        $buf->set_lines($insert_at, $insert_at, \@rep);
        $win->set_cursor($insert_at, _first_nonblank($rep[0] // ''));
    }
    elsif ($type eq 'block') {
        my @rows = split /\n/, $text, -1;
        my $col  = $after ? $c + 1 : $c;
        for my $i (0 .. $#rows) {
            my $tl = $l + $i;
            while ($tl >= $buf->line_count) {
                $buf->set_lines($buf->line_count, $buf->line_count, ['']);
            }
            my $lt = $buf->get_line($tl) // '';
            my $ic = $col > length($lt) ? length($lt) : $col;
            $buf->insert_at($tl, $ic, $rows[$i] x $cnt);
        }
        $win->set_cursor($l, $col);
    }
    else {
        my $line = $buf->get_line($l) // '';
        my $ic   = ($after && length($line) > 0) ? $c + 1 : $c;
        $ic = length($line) if $ic > length($line);
        my $rep = $text x $cnt;
        $buf->insert_at($l, $ic, $rep);
        $win->set_cursor($l, $ic + length($rep) - 1);
    }

    $buf->end_undo_group;
    $self->_clamp_cursor($ed, 0);
    $self->_finish_dot($has_cnt ? $cnt : undef);
    $ed->emit('TextChanged', buf => $buf);
    return 1;
}

1;

__END__

=head1 NAME

NeoPerl::Modal - Vim modal state machine, composable grammar, text objects, and keymaps

=head1 SYNOPSIS

    use NeoPerl::Modal;
    $editor->modal->map('n', '<leader>w', ':w<CR>', desc => 'Save buffer');
    $editor->feed_keys('3dd');
    $editor->feed_keys('ciwreplacement<Esc>');

=head1 DESCRIPTION

Implements the complete Vim modal engine for NeoPerl::MT across C<NORMAL>,
C<INSERT>, C<VISUAL>, C<VLINE>, C<VBLOCK>, C<OPERATOR>, C<REPLACE>, C<COMMAND>,
C<SEARCH_FWD>, C<SEARCH_BWD>, and C<TERMINAL> modes, including composable
C<[count]["reg][op][count][motion|text-object]> parsing, dot-repeat, macros,
marks, registers, and extensible hooks for structural text objects, motions,
and formatters.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
