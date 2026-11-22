package NeoPerl::Layout;

use strict;
use warnings;

our $VERSION = '0.01';

my %CC_TAB_ALIASES = (
    chat   => 'chat',
    memory => 'memory',
    jobs   => 'jobs',
    models => 'jobs',
    xsdev  => 'xsdev',
    debug  => 'xsdev',
);

my @CC_TABS = qw(chat memory jobs xsdev);

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        next_win_id       => 1000,
        next_tab_id       => 1,
        windows           => {},
        tabs              => [],
        active_tab_idx    => 0,
        floats            => {},
        explorer_open     => $opts{explorer_open} ? 1 : 0,
        explorer_width    => $opts{explorer_width} || 28,
        explorer_focused  => 0,
        cc_open           => $opts{cc_open} ? 1 : 0,
        cc_tab            => 'chat',
        cc_position       => $opts{cc_position} || 'right',
        cc_width          => $opts{cc_width} || 46,
        cc_height         => $opts{cc_height} || 16,
        cc_focused        => 0,
        last_width        => $opts{width} || 120,
        last_height       => $opts{height} || 40,
        last_rects        => undef,
    }, $class;

    if (defined $opts{initial_buf_id}) {
        $self->new_tab($opts{initial_buf_id});
    }
    return $self;
}

sub _make_window {
    my ($self, %opts) = @_;
    my $id = $self->{next_win_id}++;
    my $win = bless {
        id          => $id,
        buf_id      => $opts{buf_id},
        cursor_line => $opts{cursor_line} || 0,
        cursor_col  => $opts{cursor_col}  || 0,
        desired_col => $opts{cursor_col}  || 0,
        scroll_top  => $opts{scroll_top}  || 0,
        scroll_left => $opts{scroll_left} || 0,
        x           => $opts{x}      || 0,
        y           => $opts{y}      || 0,
        width       => $opts{width}  || 80,
        height      => $opts{height} || 24,
        is_float    => $opts{is_float} ? 1 : 0,
        zindex      => defined($opts{zindex}) ? $opts{zindex} : 50,
        relative    => $opts{relative} || 'editor',
        border      => $opts{border}   || 'rounded',
        title       => $opts{title}    // '',
        footer      => $opts{footer}   // '',
        focusable   => exists($opts{focusable}) ? ($opts{focusable} ? 1 : 0) : 1,
        kind        => $opts{kind}     || 'generic',
        lines       => $opts{lines},
        meta        => $opts{meta}     || {},
        options     => {
            number         => 1,
            relativenumber => 0,
            signcolumn     => 'yes',
            cursorline     => 1,
            wrap           => 0,
            %{ $opts{options} || {} },
        },
    }, 'NeoPerl::Layout::Window';
    $self->{windows}{$id} = $win;
    return $win;
}

sub new_tab {
    my ($self, $buf_id, %opts) = @_;
    my $win = $self->_make_window(buf_id => $buf_id);
    my $tab = {
        id            => $self->{next_tab_id}++,
        name          => $opts{name} // '',
        root          => { type => 'leaf', win_id => $win->{id} },
        active_win_id => $win->{id},
    };
    push @{ $self->{tabs} }, $tab;
    $self->{active_tab_idx} = $#{ $self->{tabs} };
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return wantarray ? ($tab, $win) : $tab;
}

sub active_tab {
    my ($self) = @_;
    return undef unless @{ $self->{tabs} };
    return $self->{tabs}[ $self->{active_tab_idx} ];
}

sub list_tabs {
    my ($self) = @_;
    return @{ $self->{tabs} };
}

sub tab_count {
    my ($self) = @_;
    return scalar @{ $self->{tabs} };
}

sub next_tab {
    my ($self) = @_;
    return undef unless @{ $self->{tabs} };
    $self->{active_tab_idx} = ($self->{active_tab_idx} + 1) % scalar(@{ $self->{tabs} });
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $self->active_tab;
}

sub prev_tab {
    my ($self) = @_;
    return undef unless @{ $self->{tabs} };
    $self->{active_tab_idx} = ($self->{active_tab_idx} - 1) % scalar(@{ $self->{tabs} });
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $self->active_tab;
}

sub goto_tab {
    my ($self, $idx) = @_;
    return undef unless @{ $self->{tabs} };
    $idx = 0 if $idx < 0;
    $idx = $#{ $self->{tabs} } if $idx > $#{ $self->{tabs} };
    $self->{active_tab_idx} = $idx;
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $self->active_tab;
}

sub close_tab {
    my ($self, $tab_idx) = @_;
    return 0 if @{ $self->{tabs} } <= 1;
    $tab_idx = $self->{active_tab_idx} unless defined $tab_idx;
    return 0 if $tab_idx < 0 || $tab_idx > $#{ $self->{tabs} };

    my $tab = splice @{ $self->{tabs} }, $tab_idx, 1;
    for my $wid ($self->_collect_leaves($tab->{root})) {
        delete $self->{windows}{$wid};
    }
    if ($self->{active_tab_idx} > $#{ $self->{tabs} }) {
        $self->{active_tab_idx} = $#{ $self->{tabs} };
    }
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return 1;
}

sub get_window {
    my ($self, $win_id) = @_;
    return undef unless defined $win_id;
    return $self->{windows}{$win_id};
}

sub active_window {
    my ($self) = @_;
    my $tab = $self->active_tab or return undef;
    return $self->{windows}{ $tab->{active_win_id} };
}

sub list_windows {
    my ($self, $tab_opt) = @_;
    my $tab = $tab_opt || $self->active_tab or return ();
    my @ids = $self->_collect_leaves($tab->{root});
    return map { $self->{windows}{$_} } grep { exists $self->{windows}{$_} } @ids;
}

sub list_all_windows {
    my ($self) = @_;
    my @wins;
    for my $tab (@{ $self->{tabs} }) {
        for my $wid ($self->_collect_leaves($tab->{root})) {
            push @wins, $self->{windows}{$wid} if exists $self->{windows}{$wid};
        }
    }
    push @wins, $self->list_floats;
    return @wins;
}

sub _collect_leaves {
    my ($self, $node) = @_;
    return () unless $node;
    if ($node->{type} eq 'leaf') {
        return ($node->{win_id});
    }
    return (
        $self->_collect_leaves($node->{first}),
        $self->_collect_leaves($node->{second}),
    );
}

sub _split_node {
    my ($self, $node, $target_win_id, $dir, $new_win_id, $ratio, $before) = @_;
    if ($node->{type} eq 'leaf') {
        if ($node->{win_id} == $target_win_id) {
            my $old_leaf = { type => 'leaf', win_id => $target_win_id };
            my $new_leaf = { type => 'leaf', win_id => $new_win_id };
            return {
                type   => 'split',
                dir    => $dir,
                ratio  => $ratio,
                first  => $before ? $new_leaf : $old_leaf,
                second => $before ? $old_leaf : $new_leaf,
            };
        }
        return $node;
    }
    $node->{first}  = $self->_split_node($node->{first},  $target_win_id, $dir, $new_win_id, $ratio, $before);
    $node->{second} = $self->_split_node($node->{second}, $target_win_id, $dir, $new_win_id, $ratio, $before);
    return $node;
}

sub hsplit {
    my ($self, $buf_id, %opts) = @_;
    return $self->_do_split('h', $buf_id, %opts);
}

sub vsplit {
    my ($self, $buf_id, %opts) = @_;
    return $self->_do_split('v', $buf_id, %opts);
}

sub _do_split {
    my ($self, $dir, $buf_id, %opts) = @_;
    my $tab = $self->active_tab;
    if (!$tab) {
        my (undef, $w) = $self->new_tab($buf_id);
        return $w;
    }
    my $cur = $self->active_window;
    $buf_id = $cur->{buf_id} unless defined $buf_id;
    my $new_win = $self->_make_window(
        buf_id      => $buf_id,
        cursor_line => defined($opts{cursor_line}) ? $opts{cursor_line} : ($cur ? $cur->{cursor_line} : 0),
        cursor_col  => defined($opts{cursor_col})  ? $opts{cursor_col}  : ($cur ? $cur->{cursor_col}  : 0),
    );
    my $ratio  = $opts{ratio}  || 0.5;
    my $before = $opts{before} ? 1 : 0;
    $tab->{root} = $self->_split_node($tab->{root}, $tab->{active_win_id}, $dir, $new_win->{id}, $ratio, $before);
    $tab->{active_win_id} = $new_win->{id} unless defined($opts{focus}) && !$opts{focus};
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $new_win;
}

sub _remove_leaf {
    my ($self, $node, $target_win_id) = @_;
    return (undef, 0) unless $node;
    if ($node->{type} eq 'leaf') {
        if ($node->{win_id} == $target_win_id) {
            return (undef, 1);
        }
        return ($node, 0);
    }
    my ($new_first, $found_first) = $self->_remove_leaf($node->{first}, $target_win_id);
    if ($found_first) {
        return ($node->{second}, 1) unless defined $new_first;
        $node->{first} = $new_first;
        return ($node, 1);
    }
    my ($new_second, $found_second) = $self->_remove_leaf($node->{second}, $target_win_id);
    if ($found_second) {
        return ($node->{first}, 1) unless defined $new_second;
        $node->{second} = $new_second;
        return ($node, 1);
    }
    return ($node, 0);
}

sub close_window {
    my ($self, $win_id) = @_;
    if (defined $win_id && exists $self->{floats}{$win_id}) {
        return $self->close_float($win_id);
    }
    my $tab = $self->active_tab or return 0;
    $win_id = $tab->{active_win_id} unless defined $win_id;
    my @leaves = $self->_collect_leaves($tab->{root});
    if (@leaves <= 1) {
        if (@{ $self->{tabs} } > 1) {
            return $self->close_tab($self->{active_tab_idx});
        }
        return 0;
    }
    my ($new_root, $removed) = $self->_remove_leaf($tab->{root}, $win_id);
    return 0 unless $removed && $new_root;
    $tab->{root} = $new_root;
    delete $self->{windows}{$win_id};
    if ($tab->{active_win_id} == $win_id) {
        my @remaining = $self->_collect_leaves($tab->{root});
        $tab->{active_win_id} = $remaining[0];
    }
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return 1;
}

sub only_window {
    my ($self, $win_id) = @_;
    my $tab = $self->active_tab or return 0;
    $win_id = $tab->{active_win_id} unless defined $win_id;
    return 0 unless exists $self->{windows}{$win_id};

    for my $wid ($self->_collect_leaves($tab->{root})) {
        next if $wid == $win_id;
        delete $self->{windows}{$wid};
    }
    $tab->{root}          = { type => 'leaf', win_id => $win_id };
    $tab->{active_win_id} = $win_id;
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return 1;
}

sub _equalize_node {
    my ($self, $node) = @_;
    return unless $node && $node->{type} eq 'split';
    $node->{ratio} = 0.5;
    $self->_equalize_node($node->{first});
    $self->_equalize_node($node->{second});
}

sub equalize {
    my ($self) = @_;
    my $tab = $self->active_tab or return 0;
    $self->_equalize_node($tab->{root});
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return 1;
}

sub _adjust_split_ratio {
    my ($self, $node, $target_win_id, $dir, $delta) = @_;
    return 0 unless $node && $node->{type} eq 'split';

    if ($self->_adjust_split_ratio($node->{first}, $target_win_id, $dir, $delta)) {
        return 1;
    }
    if ($self->_adjust_split_ratio($node->{second}, $target_win_id, $dir, $delta)) {
        return 1;
    }
    if ($node->{dir} eq $dir) {
        my %in_first  = map { $_ => 1 } $self->_collect_leaves($node->{first});
        my %in_second = map { $_ => 1 } $self->_collect_leaves($node->{second});
        if ($in_first{$target_win_id}) {
            $node->{ratio} += $delta;
            $node->{ratio} = 0.15 if $node->{ratio} < 0.15;
            $node->{ratio} = 0.85 if $node->{ratio} > 0.85;
            return 1;
        }
        elsif ($in_second{$target_win_id}) {
            $node->{ratio} -= $delta;
            $node->{ratio} = 0.15 if $node->{ratio} < 0.15;
            $node->{ratio} = 0.85 if $node->{ratio} > 0.85;
            return 1;
        }
    }
    return 0;
}

sub resize_window {
    my ($self, $win_id, $dw, $dh) = @_;
    my $tab = $self->active_tab or return 0;
    $win_id = $tab->{active_win_id} unless defined $win_id;
    $dw //= 0;
    $dh //= 0;
    my $changed = 0;
    if ($dw != 0) {
        $changed |= $self->_adjust_split_ratio($tab->{root}, $win_id, 'v', $dw * 0.05);
    }
    if ($dh != 0) {
        $changed |= $self->_adjust_split_ratio($tab->{root}, $win_id, 'h', $dh * 0.05);
    }
    $self->compute_rects($self->{last_width}, $self->{last_height}) if $changed;
    return $changed;
}

sub focus_window {
    my ($self, $win_id) = @_;
    return 0 unless defined $win_id && exists $self->{windows}{$win_id};
    my $tab = $self->active_tab or return 0;
    my %in_tab = map { $_ => 1 } $self->_collect_leaves($tab->{root});
    if ($in_tab{$win_id}) {
        $tab->{active_win_id} = $win_id;
        $self->{explorer_focused} = 0;
        $self->{cc_focused}       = 0;
        return 1;
    }
    return 0;
}

sub focus_next {
    my ($self) = @_;
    my $tab = $self->active_tab or return undef;
    my @leaves = $self->_collect_leaves($tab->{root});
    return $self->active_window if @leaves <= 1;
    my $idx = 0;
    for my $i (0 .. $#leaves) {
        if ($leaves[$i] == $tab->{active_win_id}) {
            $idx = ($i + 1) % scalar(@leaves);
            last;
        }
    }
    $tab->{active_win_id} = $leaves[$idx];
    return $self->active_window;
}

sub focus_direction {
    my ($self, $dir) = @_;
    my $tab = $self->active_tab or return undef;
    $self->compute_rects($self->{last_width}, $self->{last_height});
    my $cur = $self->active_window or return undef;

    my $cx = $cur->{x} + $cur->{width}  / 2.0;
    my $cy = $cur->{y} + $cur->{height} / 2.0;

    my ($best, $best_score);
    for my $w ($self->list_windows($tab)) {
        next if $w->{id} == $cur->{id};
        my $wx = $w->{x} + $w->{width}  / 2.0;
        my $wy = $w->{y} + $w->{height} / 2.0;
        my $dx = $wx - $cx;
        my $dy = $wy - $cy;

        my $ok = 0;
        my ($primary, $secondary);
        if ($dir eq 'h') {
            $ok = ($w->{x} + $w->{width} <= $cur->{x} + 1) || ($dx < -0.5 && abs($dx) >= abs($dy) * 0.5);
            ($primary, $secondary) = (-$dx, abs($dy));
        }
        elsif ($dir eq 'l') {
            $ok = ($w->{x} >= $cur->{x} + $cur->{width} - 1) || ($dx > 0.5 && abs($dx) >= abs($dy) * 0.5);
            ($primary, $secondary) = ($dx, abs($dy));
        }
        elsif ($dir eq 'k') {
            $ok = ($w->{y} + $w->{height} <= $cur->{y} + 1) || ($dy < -0.5 && abs($dy) >= abs($dx) * 0.5);
            ($primary, $secondary) = (-$dy, abs($dx));
        }
        elsif ($dir eq 'j') {
            $ok = ($w->{y} >= $cur->{y} + $cur->{height} - 1) || ($dy > 0.5 && abs($dy) >= abs($dx) * 0.5);
            ($primary, $secondary) = ($dy, abs($dx));
        }
        next unless $ok && $primary > 0;

        my $score = $primary + $secondary * 2.5;
        if (!defined($best_score) || $score < $best_score) {
            $best_score = $score;
            $best       = $w;
        }
    }

    if ($best) {
        $tab->{active_win_id} = $best->{id};
        $self->{explorer_focused} = 0;
        $self->{cc_focused}       = 0;
        return $best;
    }
    return $cur;
}

# --- Docked Explorer ---

sub explorer_open {
    my ($self, $val) = @_;
    if (@_ > 1) {
        $self->{explorer_open} = $val ? 1 : 0;
        $self->compute_rects($self->{last_width}, $self->{last_height});
    }
    return $self->{explorer_open};
}

sub toggle_explorer {
    my ($self) = @_;
    $self->{explorer_open} = $self->{explorer_open} ? 0 : 1;
    $self->{explorer_focused} = 0 unless $self->{explorer_open};
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $self->{explorer_open};
}

sub explorer_width {
    my ($self, $w) = @_;
    if (defined $w && $w >= 14) {
        $self->{explorer_width} = int($w);
        $self->compute_rects($self->{last_width}, $self->{last_height});
    }
    return $self->{explorer_width};
}

# --- Docked 4-Tab Command Center (chat, memory, jobs, xsdev) ---

sub command_center_tabs {
    return @CC_TABS;
}

sub _normalize_cc_tab {
    my ($tab) = @_;
    return 'chat' unless defined $tab;
    return $CC_TAB_ALIASES{ lc $tab } || 'chat';
}

sub command_center_open {
    my ($self) = @_;
    return $self->{cc_open};
}

sub command_center_tab {
    my ($self, $tab) = @_;
    if (defined $tab) {
        $self->{cc_tab} = _normalize_cc_tab($tab);
    }
    return $self->{cc_tab};
}

sub command_center_position {
    my ($self, $pos) = @_;
    if (defined $pos && ($pos eq 'right' || $pos eq 'bottom')) {
        $self->{cc_position} = $pos;
        $self->compute_rects($self->{last_width}, $self->{last_height});
    }
    return $self->{cc_position};
}

sub open_command_center {
    my ($self, $tab) = @_;
    $self->{cc_tab}  = _normalize_cc_tab($tab) if defined $tab;
    $self->{cc_open} = 1;
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $self->command_center_state;
}

sub close_command_center {
    my ($self) = @_;
    $self->{cc_open}    = 0;
    $self->{cc_focused} = 0;
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $self->command_center_state;
}

sub toggle_command_center {
    my ($self, $tab) = @_;
    if (defined $tab) {
        my $norm = _normalize_cc_tab($tab);
        if ($self->{cc_open} && $self->{cc_tab} eq $norm) {
            $self->{cc_open} = 0;
        }
        else {
            $self->{cc_tab}  = $norm;
            $self->{cc_open} = 1;
        }
    }
    else {
        $self->{cc_open} = $self->{cc_open} ? 0 : 1;
    }
    $self->{cc_focused} = 0 unless $self->{cc_open};
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $self->command_center_state;
}

sub command_center_state {
    my ($self) = @_;
    return {
        open     => $self->{cc_open},
        tab      => $self->{cc_tab},
        tabs     => [ @CC_TABS ],
        position => $self->{cc_position},
        width    => $self->{cc_width},
        height   => $self->{cc_height},
        focused  => $self->{cc_focused},
    };
}

# --- Z-ordered Floating Windows ---

sub open_float {
    my ($self, $opts_or_key, @rest) = @_;
    my %opts = ref($opts_or_key) eq 'HASH' ? %{$opts_or_key} : ($opts_or_key, @rest);
    my $win = $self->_make_window(
        %opts,
        is_float => 1,
        zindex   => defined($opts{zindex}) ? $opts{zindex} : 50,
    );
    $self->{floats}{ $win->{id} } = $win;
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return $win;
}

sub close_float {
    my ($self, $win_id) = @_;
    return 0 unless defined $win_id && exists $self->{floats}{$win_id};
    delete $self->{floats}{$win_id};
    delete $self->{windows}{$win_id};
    $self->compute_rects($self->{last_width}, $self->{last_height});
    return 1;
}

sub close_floats_by_kind {
    my ($self, $kind) = @_;
    my $count = 0;
    for my $id (keys %{ $self->{floats} }) {
        if ($self->{floats}{$id}{kind} eq $kind) {
            delete $self->{floats}{$id};
            delete $self->{windows}{$id};
            $count++;
        }
    }
    $self->compute_rects($self->{last_width}, $self->{last_height}) if $count;
    return $count;
}

sub list_floats {
    my ($self) = @_;
    my @sorted = sort {
        ($a->{zindex} <=> $b->{zindex}) || ($a->{id} <=> $b->{id})
    } values %{ $self->{floats} };
    return @sorted;
}

sub get_float_by_kind {
    my ($self, $kind) = @_;
    my @matching = grep { $_->{kind} eq $kind } $self->list_floats;
    return $matching[-1];
}

# --- Geometry Calculation ---

sub _layout_bsp {
    my ($self, $node, $x, $y, $w, $h, $out) = @_;
    return unless $node;
    $w = 1 if $w < 1;
    $h = 1 if $h < 1;
    if ($node->{type} eq 'leaf') {
        my $win = $self->{windows}{ $node->{win_id} };
        if ($win) {
            $win->{x}      = $x;
            $win->{y}      = $y;
            $win->{width}  = $w;
            $win->{height} = $h;
            push @{$out}, {
                win_id => $win->{id},
                buf_id => $win->{buf_id},
                x      => $x,
                y      => $y,
                width  => $w,
                height => $h,
                window => $win,
            };
        }
        return;
    }

    my $ratio = $node->{ratio} || 0.5;
    if ($node->{dir} eq 'v') {
        # Vertical split: left and right
        my $w1 = int($w * $ratio);
        $w1 = 1 if $w1 < 1;
        $w1 = $w - 1 if $w1 >= $w && $w > 1;
        my $w2 = $w - $w1;
        $self->_layout_bsp($node->{first},  $x,       $y, $w1, $h, $out);
        $self->_layout_bsp($node->{second}, $x + $w1, $y, $w2, $h, $out);
    }
    else {
        # Horizontal split: top and bottom
        my $h1 = int($h * $ratio);
        $h1 = 1 if $h1 < 1;
        $h1 = $h - 1 if $h1 >= $h && $h > 1;
        my $h2 = $h - $h1;
        $self->_layout_bsp($node->{first},  $x, $y,       $w, $h1, $out);
        $self->_layout_bsp($node->{second}, $x, $y + $h1, $w, $h2, $out);
    }
}

sub compute_rects {
    my ($self, $total_w, $total_h, %opts) = @_;
    $total_w = $self->{last_width}  unless defined $total_w && $total_w > 0;
    $total_h = $self->{last_height} unless defined $total_h && $total_h > 0;
    $self->{last_width}  = int($total_w);
    $self->{last_height} = int($total_h);

    my $tabline_h    = exists($opts{tabline_h})    ? $opts{tabline_h}    : 1;
    my $statusline_h = exists($opts{statusline_h}) ? $opts{statusline_h} : 1;
    my $cmdline_h    = exists($opts{cmdline_h})    ? $opts{cmdline_h}    : 1;

    my $body_y = $tabline_h;
    my $body_h = $total_h - $tabline_h - $statusline_h - $cmdline_h;
    $body_h = 1 if $body_h < 1;

    my $ed_x = 0;
    my $ed_y = $body_y;
    my $ed_w = $total_w;
    my $ed_h = $body_h;

    my $explorer_rect;
    if ($self->{explorer_open}) {
        my $ew = $self->{explorer_width};
        $ew = int($total_w * 0.35) if $ew > int($total_w * 0.35);
        $ew = 10 if $ew < 10 && $total_w >= 30;
        $explorer_rect = { x => 0, y => $body_y, width => $ew, height => $body_h };
        $ed_x += $ew;
        $ed_w -= $ew;
    }

    my $cc_rect;
    if ($self->{cc_open}) {
        if ($self->{cc_position} eq 'bottom') {
            my $ch = $self->{cc_height};
            $ch = int($ed_h * 0.45) if $ch > int($ed_h * 0.45);
            $ch = 6 if $ch < 6 && $ed_h >= 12;
            $ed_h -= $ch;
            $cc_rect = { x => $ed_x, y => $ed_y + $ed_h, width => $ed_w, height => $ch };
        }
        else {
            my $cw = $self->{cc_width};
            $cw = int($ed_w * 0.45) if $cw > int($ed_w * 0.45);
            $cw = 20 if $cw < 20 && $ed_w >= 50;
            $ed_w -= $cw;
            $cc_rect = { x => $ed_x + $ed_w, y => $ed_y, width => $cw, height => $ed_h };
        }
    }

    my @win_rects;
    my $tab = $self->active_tab;
    if ($tab) {
        $self->_layout_bsp($tab->{root}, $ed_x, $ed_y, $ed_w, $ed_h, \@win_rects);
    }

    my @float_rects;
    my $active_win = $self->active_window;
    for my $fw ($self->list_floats) {
        my ($fx, $fy, $fwidth, $fheight) = ($fw->{x}, $fw->{y}, $fw->{width}, $fw->{height});
        $fwidth  = $total_w - 2 if $fwidth  > $total_w - 2 && $total_w > 4;
        $fheight = $total_h - 2 if $fheight > $total_h - 2 && $total_h > 4;
        if ($fw->{relative} eq 'center') {
            $fx = int(($total_w - $fwidth)  / 2);
            $fy = int(($total_h - $fheight) / 2);
        }
        elsif ($fw->{relative} eq 'cursor' && $active_win) {
            $fx = $active_win->{x} + ($active_win->{cursor_col} - $active_win->{scroll_left}) + 6;
            $fy = $active_win->{y} + ($active_win->{cursor_line} - $active_win->{scroll_top}) + 1;
            if ($fy + $fheight > $total_h - 2) {
                $fy = $active_win->{y} + ($active_win->{cursor_line} - $active_win->{scroll_top}) - $fheight;
            }
        }
        $fx = 0 if $fx < 0;
        $fy = 0 if $fy < 0;
        $fx = $total_w - $fwidth  if $fx + $fwidth  > $total_w && $total_w >= $fwidth;
        $fy = $total_h - $fheight if $fy + $fheight > $total_h && $total_h >= $fheight;

        push @float_rects, {
            win_id => $fw->{id},
            buf_id => $fw->{buf_id},
            x      => $fx,
            y      => $fy,
            width  => $fwidth,
            height => $fheight,
            zindex => $fw->{zindex},
            kind   => $fw->{kind},
            border => $fw->{border},
            title  => $fw->{title},
            footer => $fw->{footer},
            window => $fw,
        };
    }

    my $rects = {
        width          => $total_w,
        height         => $total_h,
        tabline        => { x => 0, y => 0, width => $total_w, height => $tabline_h },
        explorer       => $explorer_rect,
        command_center => $cc_rect,
        editor_area    => { x => $ed_x, y => $ed_y, width => $ed_w, height => $ed_h },
        windows        => \@win_rects,
        floats         => \@float_rects,
        statusline     => { x => 0, y => $total_h - $statusline_h - $cmdline_h, width => $total_w, height => $statusline_h },
        cmdline        => { x => 0, y => $total_h - $cmdline_h, width => $total_w, height => $cmdline_h },
    };
    $self->{last_rects} = $rects;
    return $rects;
}

sub last_rects {
    my ($self) = @_;
    return $self->{last_rects} || $self->compute_rects($self->{last_width}, $self->{last_height});
}

sub ensure_cursor_visible {
    my ($self, $win) = @_;
    $win ||= $self->active_window or return;
    my $vh = $win->{height} || 24;
    $vh = 1 if $vh < 1;
    if ($win->{cursor_line} < $win->{scroll_top}) {
        $win->{scroll_top} = $win->{cursor_line};
    }
    elsif ($win->{cursor_line} >= $win->{scroll_top} + $vh) {
        $win->{scroll_top} = $win->{cursor_line} - $vh + 1;
    }
    $win->{scroll_top} = 0 if $win->{scroll_top} < 0;

    my $vw = ($win->{width} || 80) - 8;
    $vw = 10 if $vw < 10;
    if ($win->{cursor_col} < $win->{scroll_left}) {
        $win->{scroll_left} = $win->{cursor_col};
    }
    elsif ($win->{cursor_col} >= $win->{scroll_left} + $vw) {
        $win->{scroll_left} = $win->{cursor_col} - $vw + 1;
    }
    $win->{scroll_left} = 0 if $win->{scroll_left} < 0;
}

package NeoPerl::Layout::Window;

use strict;
use warnings;

sub id          { return $_[0]->{id} }
sub buf_id      { my $s = shift; $s->{buf_id}      = $_[0] if @_; return $s->{buf_id} }
sub cursor_line { my $s = shift; $s->{cursor_line} = $_[0] if @_; return $s->{cursor_line} }
sub cursor_col  { my $s = shift; $s->{cursor_col}  = $_[0] if @_; return $s->{cursor_col} }
sub desired_col { my $s = shift; $s->{desired_col} = $_[0] if @_; return $s->{desired_col} }
sub scroll_top  { my $s = shift; $s->{scroll_top}  = $_[0] if @_; return $s->{scroll_top} }
sub scroll_left { my $s = shift; $s->{scroll_left} = $_[0] if @_; return $s->{scroll_left} }
sub x           { return $_[0]->{x} }
sub y           { return $_[0]->{y} }
sub width       { return $_[0]->{width} }
sub height      { return $_[0]->{height} }
sub is_float    { return $_[0]->{is_float} }
sub zindex      { return $_[0]->{zindex} }
sub kind        { return $_[0]->{kind} }
sub title       { my $s = shift; $s->{title}  = $_[0] if @_; return $s->{title} }
sub footer      { my $s = shift; $s->{footer} = $_[0] if @_; return $s->{footer} }
sub lines       { my $s = shift; $s->{lines}  = $_[0] if @_; return $s->{lines} }
sub meta        { my $s = shift; $s->{meta}   = $_[0] if @_; return $s->{meta} }

sub set_cursor {
    my ($self, $line, $col, $keep_desired) = @_;
    $self->{cursor_line} = $line < 0 ? 0 : int($line);
    $self->{cursor_col}  = $col  < 0 ? 0 : int($col);
    $self->{desired_col} = $self->{cursor_col} unless $keep_desired;
    return ($self->{cursor_line}, $self->{cursor_col});
}

sub get_cursor {
    my ($self) = @_;
    return ($self->{cursor_line}, $self->{cursor_col});
}

sub set_option {
    my ($self, $key, $val) = @_;
    $self->{options}{$key} = $val;
}

sub get_option {
    my ($self, $key) = @_;
    return $self->{options}{$key};
}

1;

__END__

=head1 NAME

NeoPerl::Layout - BSP split layout, tabpages, docked panels, and z-ordered floats

=head1 SYNOPSIS

    use NeoPerl::Layout;
    my $layout = NeoPerl::Layout->new(initial_buf_id => 1);
    my $right  = $layout->vsplit(2);
    $layout->focus_direction('h');
    $layout->toggle_command_center('chat');
    my $float  = $layout->open_float(relative => 'center', width => 60, height => 20, zindex => 80);

=head1 DESCRIPTION

Implements a recursive binary space partitioning (BSP) split tree per tabpage,
docked left File Explorer, docked right/bottom 4-tab Command Center
(C<chat>, C<memory>, C<jobs>, C<xsdev>), and z-ordered floating windows.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
