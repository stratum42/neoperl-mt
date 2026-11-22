package NeoPerl::API;

use strict;
use warnings;

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $editor = $opts{editor} or die "NeoPerl::API requires editor";
    my $self = bless {
        editor => $editor,
        g      => {},
    }, $class;
    $self->{api_ns} = NeoPerl::API::Namespace->new(editor => $editor);
    return $self;
}

sub editor { return $_[0]->{editor} }
sub api    { return $_[0]->{api_ns} }
sub g      { return $_[0]->{g} }

sub cmd {
    my ($self, $cmdline) = @_;
    return $self->{editor}->exec_command($cmdline);
}

sub opt {
    my ($self, $key, @rest) = @_;
    if (@rest) {
        return $self->{editor}->set_option($key, $rest[0]);
    }
    return $self->{editor}->get_option($key);
}

sub keymap_set {
    my ($self, $mode, $lhs, $rhs, $opts) = @_;
    $opts ||= {};
    return $self->{editor}->modal->map($mode, $lhs, $rhs, %{$opts});
}

sub on {
    my ($self, $event, $cb, %opts) = @_;
    return $self->{editor}->on($event, $cb, %opts);
}

sub notify {
    my ($self, $msg, $level) = @_;
    return $self->{editor}->notify($msg, $level || 'info');
}

package NeoPerl::API::Namespace;

use strict;
use warnings;

sub new {
    my ($class, %opts) = @_;
    return bless { editor => $opts{editor} }, $class;
}

sub _resolve_buf {
    my ($self, $buf) = @_;
    return $self->{editor}->current_buffer if !defined($buf) || $buf == 0;
    return $buf if ref($buf) && $buf->isa('NeoPerl::Buffer');
    return $self->{editor}->get_buffer($buf);
}

sub _resolve_win {
    my ($self, $win) = @_;
    return $self->{editor}->current_window if !defined($win) || $win == 0;
    return $win if ref($win) && $win->isa('NeoPerl::Layout::Window');
    return $self->{editor}->layout->get_window($win);
}

# --- Buffer API ---

sub get_current_buf {
    my ($self) = @_;
    my $buf = $self->{editor}->current_buffer;
    return $buf ? $buf->id : undef;
}

sub set_current_buf {
    my ($self, $buf_id) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return 0;
    my $win = $self->{editor}->current_window or return 0;
    $win->buf_id($buf->id);
    $self->{editor}->emit('BufEnter', buf => $buf);
    return 1;
}

sub list_bufs {
    my ($self) = @_;
    return [ map { $_->id } $self->{editor}->list_buffers ];
}

sub create_buf {
    my ($self, $listed, $scratch) = @_;
    my $buf = $self->{editor}->create_buffer(
        buftype => ($scratch ? 'nofile' : ''),
    );
    return $buf->id;
}

sub buf_get_lines {
    my ($self, $buf_id, $start, $end, $strict) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return [];
    return $buf->get_lines($start, $end);
}

sub buf_set_lines {
    my ($self, $buf_id, $start, $end, $lines) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return 0;
    $buf->set_lines($start, $end, $lines);
    $self->{editor}->emit('TextChanged', buf => $buf);
    return 1;
}

sub buf_get_name {
    my ($self, $buf_id) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return '';
    return $buf->path // $buf->name // '';
}

sub buf_line_count {
    my ($self, $buf_id) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return 0;
    return $buf->line_count;
}

sub buf_set_extmark {
    my ($self, $buf_id, $ns, $line, $col, $opts) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return undef;
    return $buf->set_extmark($ns, $line, $col, $opts || {});
}

sub buf_del_extmark {
    my ($self, $buf_id, $ns, $mark_id) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return 0;
    return $buf->del_extmark($ns, $mark_id);
}

sub buf_clear_namespace {
    my ($self, $buf_id, $ns, $start, $end) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return 0;
    return $buf->clear_namespace($ns, $start, $end);
}

sub buf_get_extmarks {
    my ($self, $buf_id, $ns, $start, $end) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return [];
    return $buf->get_extmarks($ns, $start, $end);
}

# --- Window API ---

sub get_current_win {
    my ($self) = @_;
    my $win = $self->{editor}->current_window;
    return $win ? $win->id : undef;
}

sub set_current_win {
    my ($self, $win_id) = @_;
    return $self->{editor}->layout->focus_window($win_id);
}

sub list_wins {
    my ($self) = @_;
    return [ map { $_->id } $self->{editor}->layout->list_windows ];
}

sub win_get_buf {
    my ($self, $win_id) = @_;
    my $win = $self->_resolve_win($win_id) or return undef;
    return $win->buf_id;
}

sub win_set_buf {
    my ($self, $win_id, $buf_id) = @_;
    my $win = $self->_resolve_win($win_id) or return 0;
    my $buf = $self->_resolve_buf($buf_id) or return 0;
    $win->buf_id($buf->id);
    return 1;
}

sub win_get_cursor {
    my ($self, $win_id) = @_;
    my $win = $self->_resolve_win($win_id) or return [ 1, 0 ];
    # Neovim convention: 1-based row, 0-based col
    return [ $win->cursor_line + 1, $win->cursor_col ];
}

sub win_set_cursor {
    my ($self, $win_id, $pos) = @_;
    my $win = $self->_resolve_win($win_id) or return 0;
    my $row = ($pos->[0] || 1) - 1;
    my $col = $pos->[1] || 0;
    my $buf = $self->_resolve_buf($win->buf_id);
    if ($buf) {
        my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
        $row = 0         if $row < 0;
        $row = $max_line if $row > $max_line;
        my $line_len = length($buf->get_line($row) // '');
        $col = 0         if $col < 0;
        $col = $line_len if $col > $line_len;
    }
    $win->set_cursor($row, $col);
    $self->{editor}->layout->ensure_cursor_visible($win);
    $self->{editor}->emit('CursorMoved', win => $win, buf => $buf);
    return 1;
}

sub open_win {
    my ($self, $buf_id, $enter, $config) = @_;
    $config ||= {};
    my $buf = $self->_resolve_buf($buf_id);
    my $win = $self->{editor}->layout->open_float(
        %{$config},
        buf_id => $buf ? $buf->id : undef,
    );
    return $win->id;
}

sub win_close {
    my ($self, $win_id, $force) = @_;
    return $self->{editor}->layout->close_window($win_id);
}

# --- Commands, Options, Keymaps, Events ---

sub command {
    my ($self, $cmdline) = @_;
    return $self->{editor}->exec_command($cmdline);
}

sub feedkeys {
    my ($self, $keys) = @_;
    return $self->{editor}->feed_keys($keys);
}

sub notify {
    my ($self, $msg, $level) = @_;
    return $self->{editor}->notify($msg, $level || 'info');
}

sub create_user_command {
    my ($self, $name, $cb, $opts) = @_;
    $opts ||= {};
    return $self->{editor}->excmd->register_command($name, $cb, %{$opts});
}

sub create_autocmd {
    my ($self, $event, $opts) = @_;
    $opts ||= {};
    my $cb = $opts->{callback} or die "create_autocmd requires callback";
    my @events = ref($event) eq 'ARRAY' ? @{$event} : ($event);
    my @ids;
    for my $ev (@events) {
        push @ids, $self->{editor}->on($ev, $cb, pattern => $opts->{pattern});
    }
    return wantarray ? @ids : $ids[0];
}

sub set_keymap {
    my ($self, $mode, $lhs, $rhs, $opts) = @_;
    $opts ||= {};
    return $self->{editor}->modal->map($mode, $lhs, $rhs, %{$opts});
}

sub set_option {
    my ($self, $name, $val) = @_;
    return $self->{editor}->set_option($name, $val);
}

sub get_option {
    my ($self, $name) = @_;
    return $self->{editor}->get_option($name);
}

sub get_mode {
    my ($self) = @_;
    return { mode => $self->{editor}->modal->mode };
}

sub get_diagnostics {
    my ($self, $buf_id) = @_;
    my $buf = defined($buf_id) ? $self->_resolve_buf($buf_id) : undef;
    return $self->{editor}->get_diagnostics($buf);
}

sub set_diagnostics {
    my ($self, $buf_id, $source, $diags) = @_;
    my $buf = $self->_resolve_buf($buf_id) or return 0;
    return $self->{editor}->set_diagnostics($buf, $source, $diags);
}

1;

__END__

=head1 NAME

NeoPerl::API - Neovim-style Perl scripting API ($vim->api->*) for NeoPerl::MT

=head1 SYNOPSIS

    # Inside init.pl or .neoperl.pl:
    $vim->opt(tabstop => 4);
    $vim->keymap_set('n', '<leader>w', ':w<CR>', { desc => 'Write buffer' });
    $vim->api->create_user_command('Hello', sub {
        my ($ed) = @_;
        $ed->notify('Hello from Perl');
    });

=head1 DESCRIPTION

Exposes a structured Perl 5 API mirroring Neovim's C<vim.api> namespace for
user C<init.pl> scripts, project C<.neoperl.pl> files, and plugins.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
