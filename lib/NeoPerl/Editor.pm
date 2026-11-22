package NeoPerl::Editor;

use strict;
use warnings;
use Cwd qw(getcwd abs_path);
use File::Spec;

use NeoPerl::Buffer;
use NeoPerl::Layout;
use NeoPerl::Modal;
use NeoPerl::ExCmd;
use NeoPerl::Config;
use NeoPerl::API;
use NeoPerl::Plugin::Themes;

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $cwd = $opts{cwd} || getcwd();
    $cwd = eval { abs_path($cwd) } || $cwd;

    my $self = bless {
        cwd                => $cwd,
        next_buf_id        => 1,
        next_listener_id   => 1,
        buffers            => {},
        buffer_order       => [],
        options            => {
            number                    => 1,
            relativenumber            => 0,
            tabstop                   => 4,
            shiftwidth                => 4,
            expandtab                 => 1,
            wrap                      => 0,
            ignorecase                => 1,
            smartcase                 => 1,
            hlsearch                  => 1,
            incsearch                 => 1,
            colorscheme               => $opts{theme} || 'aix_amber',
            mapleader                 => ' ',
            perltidy_on_save          => 0,
            auto_apply_docs_if_syntax_ok => 0,
            xs_remote_host            => '',
            xs_remote_workdir         => '',
            %{ $opts{options} || {} },
        },
        theme              => undef,
        diagnostics        => {},      # buf_id => { source => [ ... ] }
        quickfix           => [],
        qf_index           => 0,
        qf_open            => 0,
        status_message     => { text => '', level => 'info' },
        notifications      => [],
        search             => {
            pattern   => '',
            direction => 1,
            hl_active => 0,
            matches   => [],
        },
        plugins            => {},
        events             => {},      # event => [ { id, cb, pattern }, ... ]
        tick_callbacks     => {},      # name => cb
        float_key_handlers => {},      # float_kind => cb($editor, $key, $float_win)
        symbol_providers   => [],
        hover_providers    => [],
        def_providers      => [],
        ref_providers      => [],
        before_diff_hooks  => [],
        cc_providers       => {},      # tab => cb($editor)
        status_providers   => {},      # name => cb($editor)
        nvim_bridge        => $opts{nvim_bridge},
        running            => 1,
        _destroyed         => 0,
    }, $class;

    $self->{theme}  = NeoPerl::Plugin::Themes->get($self->{options}{colorscheme});
    $self->{layout} = NeoPerl::Layout->new(
        width  => $opts{width}  || 120,
        height => $opts{height} || 40,
    );
    $self->{modal}  = NeoPerl::Modal->new(editor => $self);
    $self->{excmd}  = NeoPerl::ExCmd->new(editor => $self);
    $self->{config} = NeoPerl::Config->new(editor => $self);
    $self->{api}    = NeoPerl::API->new(editor => $self);

    # Create initial empty scratch buffer and first tab/window
    my $init_buf = $self->create_buffer(name => '[No Name]');
    $self->{layout}->new_tab($init_buf->id);

    if ($opts{load_config}) {
        $self->{config}->load_all(cwd => $cwd);
    }

    return $self;
}

# --- Accessors ---

sub cwd    { my $s = shift; $s->{cwd} = $_[0] if @_; return $s->{cwd} }
sub layout { return $_[0]->{layout} }
sub modal  { return $_[0]->{modal} }
sub excmd  { return $_[0]->{excmd} }
sub config { return $_[0]->{config} }
sub api    { return $_[0]->{api} }
sub theme  { return $_[0]->{theme} }
sub search_state { return $_[0]->{search} }
sub running { my $s = shift; $s->{running} = $_[0] ? 1 : 0 if @_; return $s->{running} }
sub nvim_bridge {
    my $s = shift;
    $s->{nvim_bridge} = $_[0] if @_;
    return $s->{nvim_bridge};
}

sub current_window {
    my ($self) = @_;
    return $self->{layout}->active_window;
}

sub current_buffer {
    my ($self) = @_;
    my $win = $self->current_window;
    if ($win && defined $win->buf_id && exists $self->{buffers}{ $win->buf_id }) {
        return $self->{buffers}{ $win->buf_id };
    }
    if (@{ $self->{buffer_order} }) {
        return $self->{buffers}{ $self->{buffer_order}[0] };
    }
    return undef;
}

# --- Plugins ---

sub register_plugin {
    my ($self, $name, $obj) = @_;
    $self->{plugins}{$name} = $obj;
    return $obj;
}

sub plugin {
    my ($self, $name) = @_;
    return $self->{plugins}{$name};
}

sub plugins {
    my ($self) = @_;
    return { %{ $self->{plugins} } };
}

# --- Options & Themes ---

sub set_option {
    my ($self, $key, $val) = @_;
    my $old = $self->{options}{$key};
    $self->{options}{$key} = $val;
    if ($key eq 'colorscheme') {
        $self->set_colorscheme($val);
    }
    elsif ($key eq 'mapleader' && $self->{modal}) {
        $self->{modal}->set_leader($val);
    }
    $self->emit('OptionSet', name => $key, old => $old, value => $val);
    return $val;
}

sub get_option {
    my ($self, $key) = @_;
    return $self->{options}{$key};
}

sub options {
    my ($self) = @_;
    return { %{ $self->{options} } };
}

sub set_colorscheme {
    my ($self, $name) = @_;
    return 0 unless NeoPerl::Plugin::Themes->exists_theme($name);
    $self->{options}{colorscheme} = lc $name;
    $self->{theme} = NeoPerl::Plugin::Themes->get($name);
    if ($self->{nvim_bridge} && eval { $self->{nvim_bridge}->is_connected }) {
        eval { $self->{nvim_bridge}->apply_theme($self->{theme}) };
    }
    $self->emit('ColorScheme', name => lc $name, theme => $self->{theme});
    return 1;
}

# --- Buffers ---

sub create_buffer {
    my ($self, %opts) = @_;
    my $id = $self->{next_buf_id}++;
    my $buf = NeoPerl::Buffer->new(
        %opts,
        id     => $id,
        editor => $self,
    );
    $self->{buffers}{$id} = $buf;
    push @{ $self->{buffer_order} }, $id;
    $self->emit('BufNew', buf => $buf);
    return $buf;
}

sub get_buffer {
    my ($self, $id) = @_;
    return undef unless defined $id;
    return $self->{buffers}{$id};
}

sub list_buffers {
    my ($self) = @_;
    return map { $self->{buffers}{$_} } grep { exists $self->{buffers}{$_} } @{ $self->{buffer_order} };
}

sub find_buffer_by_path {
    my ($self, $path) = @_;
    return undef unless defined $path && length $path;
    my $abs = eval { abs_path($path) } || File::Spec->rel2abs($path, $self->{cwd});
    for my $buf ($self->list_buffers) {
        next unless defined $buf->path;
        my $babs = eval { abs_path($buf->path) } || File::Spec->rel2abs($buf->path, $self->{cwd});
        return $buf if $babs eq $abs || $buf->path eq $path;
    }
    return undef;
}

sub open_file {
    my ($self, $path, %opts) = @_;
    my $resolved = File::Spec->file_name_is_absolute($path)
        ? $path
        : File::Spec->catfile($self->{cwd}, $path);
    my $abs = eval { abs_path($resolved) } || $resolved;

    my $buf = $self->find_buffer_by_path($abs);
    my $is_new = 0;
    if (!$buf) {
        # Reuse initial untouched unnamed scratch buffer if it is the only buffer
        my $cur = $self->current_buffer;
        if ($cur && !defined($cur->path) && !$cur->modified
            && $cur->line_count <= 1 && length($cur->get_line(0) // '') == 0
            && scalar($self->list_buffers) == 1 && !$opts{new_buffer})
        {
            $buf = $cur;
            if (-f $abs) {
                $buf->load_file($abs);
            }
            else {
                $buf->set_path($abs);
            }
        }
        else {
            $buf = $self->create_buffer(
                path => $abs,
                (-f $abs ? (load => 1) : ()),
            );
        }
        $is_new = 1;
    }

    if (!$opts{no_switch}) {
        my $win = $self->current_window;
        if ($win) {
            $win->buf_id($buf->id);
            $win->set_cursor(0, 0) if $is_new;
            $self->{layout}->ensure_cursor_visible($win);
        }
        $self->emit('BufEnter', buf => $buf);
    }

    if ($is_new) {
        $self->emit('BufReadPost', buf => $buf, path => $abs);
    }
    return $buf;
}

sub switch_buffer {
    my ($self, $id) = @_;
    my $buf = $self->get_buffer($id) or return undef;
    my $win = $self->current_window or return undef;
    $win->buf_id($buf->id);
    my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
    if ($win->cursor_line > $max_line) {
        $win->set_cursor($max_line, 0);
    }
    $self->{layout}->ensure_cursor_visible($win);
    $self->emit('BufEnter', buf => $buf);
    return $buf;
}

sub next_buffer {
    my ($self) = @_;
    my @ids = @{ $self->{buffer_order} };
    return undef if @ids <= 1;
    my $cur = $self->current_buffer;
    my $idx = 0;
    for my $i (0 .. $#ids) {
        if ($cur && $ids[$i] == $cur->id) {
            $idx = ($i + 1) % scalar(@ids);
            last;
        }
    }
    return $self->switch_buffer($ids[$idx]);
}

sub prev_buffer {
    my ($self) = @_;
    my @ids = @{ $self->{buffer_order} };
    return undef if @ids <= 1;
    my $cur = $self->current_buffer;
    my $idx = 0;
    for my $i (0 .. $#ids) {
        if ($cur && $ids[$i] == $cur->id) {
            $idx = ($i - 1) % scalar(@ids);
            last;
        }
    }
    return $self->switch_buffer($ids[$idx]);
}

sub delete_buffer {
    my ($self, $id, %opts) = @_;
    my $buf = defined($id) ? $self->get_buffer($id) : $self->current_buffer;
    return 0 unless $buf;
    if ($buf->modified && !$opts{force}) {
        $self->notify("No write since last change for buffer " . $buf->id . " (add ! to override)", 'error');
        return 0;
    }

    my $bid = $buf->id;
    $self->emit('BufDelete', buf => $buf);
    delete $self->{buffers}{$bid};
    delete $self->{diagnostics}{$bid};
    $self->{buffer_order} = [ grep { $_ != $bid } @{ $self->{buffer_order} } ];

    # Ensure at least one buffer exists
    my $fallback;
    if (!@{ $self->{buffer_order} }) {
        $fallback = $self->create_buffer(name => '[No Name]');
    }
    else {
        $fallback = $self->{buffers}{ $self->{buffer_order}[0] };
    }

    for my $win ($self->{layout}->list_all_windows) {
        if (defined $win->buf_id && $win->buf_id == $bid) {
            $win->buf_id($fallback->id);
            $win->set_cursor(0, 0);
        }
    }
    return 1;
}

sub jump_to {
    my ($self, $target, $line, $col) = @_;
    $line //= 0;
    $col  //= 0;
    my $buf;
    if (ref($target) && $target->isa('NeoPerl::Buffer')) {
        $buf = $target;
        $self->switch_buffer($buf->id);
    }
    elsif (defined $target && $target =~ /^\d+$/ && $self->get_buffer($target)) {
        $buf = $self->switch_buffer($target);
    }
    elsif (defined $target && length $target) {
        $buf = $self->open_file($target);
    }
    else {
        $buf = $self->current_buffer;
    }
    return undef unless $buf;

    my $win = $self->current_window or return $buf;
    my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
    $line = 0         if $line < 0;
    $line = $max_line if $line > $max_line;
    my $llen = length($buf->get_line($line) // '');
    $col = 0     if $col < 0;
    $col = $llen if $col > $llen;

    $win->set_cursor($line, $col);
    $self->{layout}->ensure_cursor_visible($win);
    $self->emit('CursorMoved', win => $win, buf => $buf, line => $line, col => $col);
    return $buf;
}

# --- Event Bus ---

sub on {
    my ($self, $event, $cb, %opts) = @_;
    my $id = $self->{next_listener_id}++;
    push @{ $self->{events}{$event} }, {
        id      => $id,
        cb      => $cb,
        pattern => $opts{pattern},
    };
    return $id;
}

sub off {
    my ($self, $event, $id) = @_;
    return 0 unless exists $self->{events}{$event};
    my $before = scalar @{ $self->{events}{$event} };
    $self->{events}{$event} = [ grep { $_->{id} != $id } @{ $self->{events}{$event} } ];
    return scalar(@{ $self->{events}{$event} }) < $before ? 1 : 0;
}

sub emit {
    my ($self, $event, %data) = @_;
    my $list = $self->{events}{$event} or return 0;
    my $fired = 0;
    for my $entry (@{$list}) {
        if (defined $entry->{pattern} && $data{buf}) {
            my $target = $data{buf}->path // $data{buf}->name // '';
            my $ft     = $data{buf}->filetype // '';
            my $pat    = $entry->{pattern};
            if ($pat ne '*') {
                my $rx = $pat;
                $rx =~ s/\./\\./g;
                $rx =~ s/\*/.*/g;
                next unless ($target =~ /$rx$/ || $ft eq $pat);
            }
        }
        eval { $entry->{cb}->(%data, editor => $self, event => $event) };
        if ($@) {
            my $err = $@;
            chomp $err;
            $self->{status_message} = { text => "Event $event handler error: $err", level => 'error' };
        }
        $fired++;
    }
    return $fired;
}

# --- Diagnostics Store ---

my %SEV_META = (
    error => { sign => 'E', hl => 'DiagError', priority => 200, rank => 1 },
    warn  => { sign => 'W', hl => 'DiagWarn',  priority => 180, rank => 2 },
    info  => { sign => 'I', hl => 'DiagInfo',  priority => 160, rank => 3 },
    hint  => { sign => 'H', hl => 'DiagHint',  priority => 140, rank => 4 },
);

sub set_diagnostics {
    my ($self, $buf_or_id, $source, $diags) = @_;
    my $buf = ref($buf_or_id) ? $buf_or_id : $self->get_buffer($buf_or_id);
    return 0 unless $buf;
    $source ||= 'default';
    $diags  ||= [];

    my $bid  = $buf->id;
    my $prev = $self->{diagnostics}{$bid}{$source} || [];

    # Normalize diagnostics
    my @norm;
    for my $d (@{$diags}) {
        my $sev = lc($d->{severity} || 'error');
        $sev = 'warn' if $sev eq 'warning';
        $sev = 'error' unless exists $SEV_META{$sev};
        push @norm, {
            buf_id   => $bid,
            path     => $buf->path,
            line     => int($d->{line}     // 0),
            col      => int($d->{col}      // 0),
            end_line => int($d->{end_line} // ($d->{line} // 0)),
            end_col  => int($d->{end_col}  // ($d->{col}  // 0)),
            severity => $sev,
            code     => $d->{code}    // '',
            message  => $d->{message} // '',
            source   => $d->{source}  || $source,
            data     => $d->{data},
        };
    }

    # Detect resolved diagnostics (present before, gone now)
    my %now_keys = map { join('|', $_->{line}, $_->{code}, $_->{message}) => 1 } @norm;
    my @resolved;
    for my $old (@{$prev}) {
        my $k = join('|', $old->{line}, $old->{code}, $old->{message});
        push @resolved, $old unless $now_keys{$k};
    }

    $self->{diagnostics}{$bid}{$source} = \@norm;

    # Repaint extmarks in namespace diag_<source>
    my $ns = "diag_$source";
    $buf->clear_namespace($ns);
    my %by_line;
    for my $d (@norm) {
        push @{ $by_line{ $d->{line} } }, $d;
    }
    my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
    for my $line (sort { $a <=> $b } keys %by_line) {
        my $clamped = $line > $max_line ? $max_line : ($line < 0 ? 0 : $line);
        my @sorted = sort { $SEV_META{$a->{severity}}{rank} <=> $SEV_META{$b->{severity}}{rank} }
                     @{ $by_line{$line} };
        my $top  = $sorted[0];
        my $meta = $SEV_META{ $top->{severity} };
        my $virt = sprintf('  [%s] %s', $top->{source}, $top->{message});
        $virt .= sprintf(' (+%d)', scalar(@sorted) - 1) if @sorted > 1;
        $buf->set_extmark($ns, $clamped, $top->{col}, {
            sign_text => $meta->{sign},
            sign_hl   => $meta->{hl},
            virt_text => $virt,
            virt_hl   => $meta->{hl},
            virt_pos  => 'eol',
            hl_group  => $meta->{hl},
            priority  => $meta->{priority},
        });
    }

    $self->emit('DiagnosticChanged', buf => $buf, source => $source, diagnostics => \@norm);
    if (@resolved) {
        $self->emit('DiagnosticResolved', buf => $buf, source => $source, resolved => \@resolved);
    }
    return scalar(@norm);
}

sub clear_diagnostics {
    my ($self, $buf_or_id, $source) = @_;
    my $buf = ref($buf_or_id) ? $buf_or_id : $self->get_buffer($buf_or_id);
    return 0 unless $buf;
    my $bid = $buf->id;
    if (defined $source) {
        $self->set_diagnostics($buf, $source, []);
        delete $self->{diagnostics}{$bid}{$source};
    }
    else {
        for my $src (keys %{ $self->{diagnostics}{$bid} || {} }) {
            $self->set_diagnostics($buf, $src, []);
        }
        delete $self->{diagnostics}{$bid};
    }
    return 1;
}

sub get_diagnostics {
    my ($self, $buf_or_id, %filter) = @_;
    my @out;
    my @bids;
    if (defined $buf_or_id) {
        my $bid = ref($buf_or_id) ? $buf_or_id->id : $buf_or_id;
        @bids = ($bid);
    }
    else {
        @bids = @{ $self->{buffer_order} };
    }

    for my $bid (@bids) {
        my $srcs = $self->{diagnostics}{$bid} or next;
        for my $src (sort keys %{$srcs}) {
            next if defined $filter{source} && $src ne $filter{source};
            for my $d (@{ $srcs->{$src} }) {
                next if defined $filter{severity} && $d->{severity} ne $filter{severity};
                push @out, $d;
            }
        }
    }
    @out = sort {
        ($a->{buf_id} <=> $b->{buf_id})
            || ($a->{line} <=> $b->{line})
            || ($a->{col} <=> $b->{col})
            || ($SEV_META{$a->{severity}}{rank} <=> $SEV_META{$b->{severity}}{rank})
    } @out;
    return \@out;
}

sub diagnostic_counts {
    my ($self, $buf_or_id) = @_;
    my $diags = $self->get_diagnostics($buf_or_id);
    my %counts = (error => 0, warn => 0, info => 0, hint => 0, total => 0);
    for my $d (@{$diags}) {
        $counts{ $d->{severity} }++;
        $counts{total}++;
    }
    return \%counts;
}

sub next_diagnostic {
    my ($self) = @_;
    my $buf = $self->current_buffer or return undef;
    my $win = $self->current_window or return undef;
    my $diags = $self->get_diagnostics($buf);
    return undef unless @{$diags};
    my ($cur_l, $cur_c) = $win->get_cursor;
    for my $d (@{$diags}) {
        if ($d->{line} > $cur_l || ($d->{line} == $cur_l && $d->{col} > $cur_c)) {
            $self->jump_to($buf, $d->{line}, $d->{col});
            return $d;
        }
    }
    # Wrap around to first diagnostic
    $self->jump_to($buf, $diags->[0]{line}, $diags->[0]{col});
    return $diags->[0];
}

sub prev_diagnostic {
    my ($self) = @_;
    my $buf = $self->current_buffer or return undef;
    my $win = $self->current_window or return undef;
    my $diags = $self->get_diagnostics($buf);
    return undef unless @{$diags};
    my ($cur_l, $cur_c) = $win->get_cursor;
    for my $d (reverse @{$diags}) {
        if ($d->{line} < $cur_l || ($d->{line} == $cur_l && $d->{col} < $cur_c)) {
            $self->jump_to($buf, $d->{line}, $d->{col});
            return $d;
        }
    }
    $self->jump_to($buf, $diags->[-1]{line}, $diags->[-1]{col});
    return $diags->[-1];
}

# --- Quickfix List ---

sub set_quickfix {
    my ($self, $items, %opts) = @_;
    $self->{quickfix} = [ @{$items || []} ];
    $self->{qf_index} = 0;
    $self->{qf_open}  = 1 if $opts{open};
    return scalar @{ $self->{quickfix} };
}

sub get_quickfix { return $_[0]->{quickfix} }
sub quickfix_open { my $s = shift; $s->{qf_open} = $_[0] ? 1 : 0 if @_; return $s->{qf_open} }
sub quickfix_index { return $_[0]->{qf_index} }

sub quickfix_jump {
    my ($self, $idx) = @_;
    return undef unless @{ $self->{quickfix} };
    $idx = 0 if $idx < 0;
    $idx = $#{ $self->{quickfix} } if $idx > $#{ $self->{quickfix} };
    $self->{qf_index} = $idx;
    my $item = $self->{quickfix}[$idx];
    $self->jump_to($item->{path} // $item->{buf_id}, $item->{line} // 0, $item->{col} // 0);
    return $item;
}

sub quickfix_next {
    my ($self) = @_;
    return undef unless @{ $self->{quickfix} };
    my $next = ($self->{qf_index} + 1) % scalar(@{ $self->{quickfix} });
    return $self->quickfix_jump($next);
}

sub quickfix_prev {
    my ($self) = @_;
    return undef unless @{ $self->{quickfix} };
    my $prev = ($self->{qf_index} - 1) % scalar(@{ $self->{quickfix} });
    return $self->quickfix_jump($prev);
}

# --- Provider Extension Hooks ---

sub register_symbol_provider     { push @{ $_[0]->{symbol_providers}  }, $_[1]; return 1 }
sub register_hover_provider      { push @{ $_[0]->{hover_providers}   }, $_[1]; return 1 }
sub register_definition_provider { push @{ $_[0]->{def_providers}     }, $_[1]; return 1 }
sub register_reference_provider  { push @{ $_[0]->{ref_providers}     }, $_[1]; return 1 }
sub register_before_stage_diff_hook { push @{ $_[0]->{before_diff_hooks} }, $_[1]; return 1 }
sub register_command_center_provider { $_[0]->{cc_providers}{ $_[1] } = $_[2]; return 1 }
sub register_statusline_provider { $_[0]->{status_providers}{ $_[1] } = $_[2]; return 1 }
sub register_float_key_handler   { $_[0]->{float_key_handlers}{ $_[1] } = $_[2]; return 1 }

sub get_symbols {
    my ($self, $buf) = @_;
    $buf ||= $self->current_buffer or return [];
    for my $prov (@{ $self->{symbol_providers} }) {
        my $res = eval { $prov->($self, $buf) };
        return $res if ref($res) eq 'ARRAY' && @{$res};
    }
    return $buf->get_symbols;
}

sub request_hover {
    my ($self, $buf, $line, $col) = @_;
    $buf ||= $self->current_buffer or return undef;
    my $win = $self->current_window;
    $line //= $win ? $win->cursor_line : 0;
    $col  //= $win ? $win->cursor_col  : 0;
    for my $prov (@{ $self->{hover_providers} }) {
        my $res = eval { $prov->($self, $buf, $line, $col) };
        return $res if defined $res;
    }
    return undef;
}

sub request_definition {
    my ($self, $buf, $line, $col) = @_;
    $buf ||= $self->current_buffer or return undef;
    my $win = $self->current_window;
    $line //= $win ? $win->cursor_line : 0;
    $col  //= $win ? $win->cursor_col  : 0;
    for my $prov (@{ $self->{def_providers} }) {
        my $res = eval { $prov->($self, $buf, $line, $col) };
        return $res if defined $res;
    }
    return undef;
}

sub request_references {
    my ($self, $buf, $line, $col) = @_;
    $buf ||= $self->current_buffer or return undef;
    my $win = $self->current_window;
    $line //= $win ? $win->cursor_line : 0;
    $col  //= $win ? $win->cursor_col  : 0;
    for my $prov (@{ $self->{ref_providers} }) {
        my $res = eval { $prov->($self, $buf, $line, $col) };
        return $res if defined $res;
    }
    return undef;
}

sub run_before_stage_diff_hooks {
    my ($self, $buf, $new_text, $meta) = @_;
    my $text = $new_text;
    for my $hook (@{ $self->{before_diff_hooks} }) {
        my $res = eval { $hook->($self, $buf, $text, $meta) };
        $text = $res if defined $res && !ref($res);
    }
    return $text;
}

sub get_command_center_data {
    my ($self, $tab) = @_;
    $tab ||= $self->{layout}->command_center_tab;
    my $cb = $self->{cc_providers}{$tab};
    return $cb ? (eval { $cb->($self) } || {}) : {};
}

sub get_statusline_segments {
    my ($self) = @_;
    my %segs;
    for my $name (keys %{ $self->{status_providers} }) {
        my $val = eval { $self->{status_providers}{$name}->($self) };
        $segs{$name} = $val if defined $val;
    }
    return \%segs;
}

# --- Tick / Event Pump ---

sub add_tick_callback {
    my ($self, $name, $cb) = @_;
    $self->{tick_callbacks}{$name} = $cb;
    return 1;
}

sub remove_tick_callback {
    my ($self, $name) = @_;
    return delete($self->{tick_callbacks}{$name}) ? 1 : 0;
}

sub pump {
    my ($self) = @_;
    my $ticks = 0;

    # Poll embedded Neovim Msgpack-RPC bridge if attached
    if ($self->{nvim_bridge} && eval { $self->{nvim_bridge}->is_connected }) {
        my $n = eval { $self->{nvim_bridge}->pump(0) };
        $ticks++ if $n;
    }

    # Poll PTY terminal buffers
    for my $buf ($self->list_buffers) {
        if ($buf->buftype eq 'terminal' && $buf->term) {
            my $n = eval { $buf->poll_terminal };
            $ticks++ if $n;
        }
    }

    for my $name (sort keys %{ $self->{tick_callbacks} }) {
        my $cb = $self->{tick_callbacks}{$name} or next;
        eval { $cb->($self) };
        $ticks++;
    }
    return $ticks;
}

# --- Input & Command Dispatch ---

sub handle_key {
    my ($self, $key) = @_;
    my @floats = reverse $self->{layout}->list_floats;
    for my $fw (@floats) {
        next unless $fw->{focusable};
        my $handler = $self->{float_key_handlers}{ $fw->{kind} };
        if ($handler) {
            my $handled = $handler->($self, $key, $fw);
            return 1 if $handled;
        }
    }
    if ($self->{nvim_bridge} && eval { $self->{nvim_bridge}->is_connected }) {
        $self->{nvim_bridge}->input($key);
        return 1;
    }
    return $self->{modal}->handle_key($self, $key);
}

sub feed_keys {
    my ($self, $seq) = @_;
    if ($self->{nvim_bridge} && eval { $self->{nvim_bridge}->is_connected }) {
        $self->{nvim_bridge}->input($seq);
        return 1;
    }
    return $self->{modal}->feed_keys($self, $seq);
}

sub exec_command {
    my ($self, $cmdline) = @_;
    return $self->{excmd}->execute($self, $cmdline);
}

# --- Notifications & Quit ---

sub notify {
    my ($self, $msg, $level) = @_;
    $level ||= 'info';
    my $entry = { text => $msg // '', level => $level, time => time() };
    $self->{status_message} = $entry;
    push @{ $self->{notifications} }, $entry;
    shift @{ $self->{notifications} } if @{ $self->{notifications} } > 100;
    return $entry;
}

sub status_message { return $_[0]->{status_message} }
sub notifications  { return $_[0]->{notifications} }

sub quit {
    my ($self, $force) = @_;
    if (!$force) {
        for my $buf ($self->list_buffers) {
            if ($buf->modified && $buf->buftype eq '') {
                $self->notify("No write since last change (add ! to override)", 'error');
                return 0;
            }
        }
    }
    $self->emit('QuitPre', force => ($force ? 1 : 0));
    $self->{running} = 0;
    return 1;
}

sub get_state_snapshot {
    my ($self) = @_;
    my $buf = $self->current_buffer;
    my $win = $self->current_window;
    my $sel = $self->{modal}->visual_range($self);
    my $nb  = ($self->{nvim_bridge} && eval { $self->{nvim_bridge}->is_connected }) ? $self->{nvim_bridge} : undef;
    my $mode = $nb ? $nb->display_mode() : $self->{modal}->mode;
    my $cursor = $win ? [ $win->cursor_line, $win->cursor_col ] : [ 0, 0 ];
    if ($nb) {
        my $nc = eval { $nb->win_get_cursor(0) };
        if (ref($nc) eq 'ARRAY' && @$nc >= 2) {
            $cursor = [ ($nc->[0] > 0 ? $nc->[0] - 1 : 0), $nc->[1] ];
        }
    }
    return {
        cwd            => $self->{cwd},
        mode           => $mode,
        running        => $self->{running},
        theme          => $self->{options}{colorscheme},
        nvim_engine    => $nb ? 1 : 0,
        nvim_version   => $nb ? $nb->version_string : undef,
        current_buf_id => $buf ? $buf->id : undef,
        current_path   => $nb ? (eval { $nb->buf_get_name(0) } || ($buf ? $buf->path : undef)) : ($buf ? $buf->path : undef),
        current_name   => $buf ? $buf->name : undef,
        filetype       => $buf ? $buf->filetype : undef,
        modified       => $buf ? ($buf->modified ? 1 : 0) : 0,
        line_count     => $buf ? $buf->line_count : 0,
        cursor         => $cursor,
        selection      => $sel,
        buffers        => [
            map {
                {
                    id       => $_->id,
                    name     => $_->name,
                    path     => $_->path,
                    filetype => $_->filetype,
                    modified => $_->modified ? 1 : 0,
                    lines    => $_->line_count,
                }
            } $self->list_buffers
        ],
        diagnostics    => $self->diagnostic_counts,
        command_center => $self->{layout}->command_center_state,
        explorer_open  => $self->{layout}->explorer_open,
        status_message => $self->{status_message},
    };
}

1;

__END__

=head1 NAME

NeoPerl::Editor - Headless Neovim editor runtime and event bus for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::Editor;
    my $ed = NeoPerl::Editor->new(cwd => '.');
    $ed->open_file('example.pl');
    $ed->feed_keys('ggdd');
    $ed->exec_command(':vsp');
    $ed->pump;

=head1 DESCRIPTION

Coordinates buffers, BSP window layout, Vim modal editing, Ex commands,
diagnostics, quickfix, plugin registration, non-blocking tick pumping, and
event hooks shared across both the GPU and terminal frontends.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
