package NeoPerl::Plugin::Explorer;

use strict;
use warnings;
use File::Spec;
use File::Basename qw(basename dirname);
use Cwd qw(abs_path);

our $VERSION = '0.01';

my %DEFAULT_IGNORE = map { $_ => 1 } qw(
    . .. .git blib node_modules .DS_Store __pycache__ .neoperl-build
);

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor      => $opts{editor},
        root        => $opts{root} || ($opts{editor} ? $opts{editor}->cwd : '.'),
        expanded    => {},
        show_hidden => $opts{show_hidden} ? 1 : 0,
        cursor      => 0,
        nodes       => [],
        actions     => {},   # key => { desc => ..., cb => sub($explorer, $node, $editor) }
        child_hooks => [],   # sub($explorer, $node) -> \@virtual_subnodes
    }, $class;

    $self->{root} = eval { abs_path($self->{root}) } || $self->{root};
    $self->{expanded}{ $self->{root} } = 1;

    if ($opts{editor}) {
        $self->attach($opts{editor});
    }
    $self->refresh;
    return $self;
}

sub attach {
    my ($self, $editor) = @_;
    $self->{editor} = $editor;
    $self->{root}   = eval { abs_path($editor->cwd) } || $editor->cwd;
    $self->{expanded}{ $self->{root} } = 1;
    $editor->register_plugin('explorer', $self);

    $editor->modal->map('n', '<leader>e', sub {
        $self->toggle;
    }, desc => 'Toggle File Explorer');

    $editor->excmd->register_command('Explorer', sub {
        my ($ed, $args) = @_;
        my $sub = $args->{args} || 'toggle';
        if ($sub eq 'open')    { $self->open }
        elsif ($sub eq 'close'){ $self->close }
        elsif ($sub eq 'refresh') { $self->refresh }
        else                   { $self->toggle }
        return { ok => 1, open => $ed->layout->explorer_open };
    }, desc => 'Toggle or control file explorer');

    $self->refresh;
    return $self;
}

sub root        { return $_[0]->{root} }
sub cursor      { return $_[0]->{cursor} }
sub show_hidden { return $_[0]->{show_hidden} }

sub register_action {
    my ($self, $key, $desc, $cb) = @_;
    $self->{actions}{$key} = { key => $key, desc => $desc, cb => $cb };
    return 1;
}

sub list_actions {
    my ($self) = @_;
    return [ map { $self->{actions}{$_} } sort keys %{ $self->{actions} } ];
}

sub register_child_provider {
    my ($self, $cb) = @_;
    push @{ $self->{child_hooks} }, $cb;
    return 1;
}

sub toggle {
    my ($self) = @_;
    $self->refresh;
    return $self->{editor} ? $self->{editor}->layout->toggle_explorer : 0;
}

sub open {
    my ($self) = @_;
    $self->refresh;
    return $self->{editor} ? $self->{editor}->layout->explorer_open(1) : 1;
}

sub close {
    my ($self) = @_;
    return $self->{editor} ? $self->{editor}->layout->explorer_open(0) : 0;
}

sub toggle_hidden {
    my ($self) = @_;
    $self->{show_hidden} = $self->{show_hidden} ? 0 : 1;
    $self->refresh;
    return $self->{show_hidden};
}

sub set_root {
    my ($self, $dir) = @_;
    return 0 unless defined $dir && -d $dir;
    $self->{root} = eval { abs_path($dir) } || $dir;
    $self->{expanded}{ $self->{root} } = 1;
    $self->{cursor} = 0;
    $self->refresh;
    return 1;
}

sub refresh {
    my ($self) = @_;
    my %git_status;
    if ($self->{editor} && (my $git = $self->{editor}->plugin('git'))) {
        my $st = eval { $git->status_map } || {};
        %git_status = %{$st};
    }

    my @nodes;
    $self->_scan_dir($self->{root}, 0, \@nodes, \%git_status);
    $self->{nodes} = \@nodes;
    if ($self->{cursor} >= scalar(@nodes)) {
        $self->{cursor} = @nodes ? $#nodes : 0;
    }
    return $self->{nodes};
}

sub _scan_dir {
    my ($self, $dir, $depth, $out, $git_status) = @_;
    opendir my $dh, $dir or return;
    my @entries = readdir $dh;
    closedir $dh;

    my (@dirs, @files);
    for my $name (@entries) {
        next if $DEFAULT_IGNORE{$name};
        next if !$self->{show_hidden} && $name =~ /^\./;
        my $full = File::Spec->catfile($dir, $name);
        if (-d $full) {
            push @dirs, [ $name, $full ];
        }
        else {
            push @files, [ $name, $full ];
        }
    }

    @dirs  = sort { lc($a->[0]) cmp lc($b->[0]) || $a->[0] cmp $b->[0] } @dirs;
    @files = sort { lc($a->[0]) cmp lc($b->[0]) || $a->[0] cmp $b->[0] } @files;

    for my $d (@dirs) {
        my ($name, $full) = @{$d};
        my $rel = File::Spec->abs2rel($full, $self->{root});
        my $is_exp = $self->{expanded}{$full} ? 1 : 0;
        my $badge = $git_status->{$rel} // $git_status->{$full} // '';
        push @{$out}, {
            name      => $name,
            path      => $full,
            rel_path  => $rel,
            depth     => $depth,
            is_dir    => 1,
            expanded  => $is_exp,
            git_badge => $badge,
            kind      => 'dir',
        };
        if ($is_exp && $depth < 12) {
            $self->_scan_dir($full, $depth + 1, $out, $git_status);
        }
    }

    for my $f (@files) {
        my ($name, $full) = @{$f};
        my $rel = File::Spec->abs2rel($full, $self->{root});
        my $badge = $git_status->{$rel} // $git_status->{$full} // '';
        my $node = {
            name      => $name,
            path      => $full,
            rel_path  => $rel,
            depth     => $depth,
            is_dir    => 0,
            expanded  => ($self->{expanded}{$full} ? 1 : 0),
            git_badge => $badge,
            kind      => 'file',
        };
        push @{$out}, $node;

        if ($node->{expanded} && @{ $self->{child_hooks} }) {
            for my $hook (@{ $self->{child_hooks} }) {
                my $kids = eval { $hook->($self, $node) };
                next unless ref($kids) eq 'ARRAY';
                for my $kid (@{$kids}) {
                    push @{$out}, {
                        name      => $kid->{name} // '',
                        path      => $full,
                        rel_path  => $rel,
                        depth     => $depth + 1,
                        is_dir    => 0,
                        expanded  => 0,
                        git_badge => '',
                        kind      => $kid->{kind} || 'symbol',
                        line      => $kid->{line},
                        col       => $kid->{col} || 0,
                    };
                }
            }
        }
    }
}

sub visible_nodes {
    my ($self) = @_;
    return $self->{nodes};
}

sub current_node {
    my ($self) = @_;
    return undef unless @{ $self->{nodes} };
    return $self->{nodes}[ $self->{cursor} ];
}

sub move_cursor {
    my ($self, $delta) = @_;
    return 0 unless @{ $self->{nodes} };
    my $next = $self->{cursor} + $delta;
    $next = 0 if $next < 0;
    $next = $#{ $self->{nodes} } if $next > $#{ $self->{nodes} };
    $self->{cursor} = $next;
    return $self->{cursor};
}

sub select_node {
    my ($self, $idx) = @_;
    $self->{cursor} = $idx if defined $idx && $idx >= 0 && $idx <= $#{ $self->{nodes} };
    my $node = $self->current_node or return undef;
    if ($node->{is_dir}) {
        $self->{expanded}{ $node->{path} } = $self->{expanded}{ $node->{path} } ? 0 : 1;
        $self->refresh;
        return $node;
    }
    if ($self->{editor}) {
        my $buf = $self->{editor}->open_file($node->{path});
        if (defined $node->{line}) {
            my $win = $self->{editor}->current_window;
            $win->set_cursor($node->{line}, $node->{col} || 0) if $win;
            $self->{editor}->layout->ensure_cursor_visible($win);
        }
        return $buf;
    }
    return $node;
}

sub handle_key {
    my ($self, $key) = @_;
    if ($key eq 'j' || $key eq '<Down>') {
        $self->move_cursor(1);
        return 1;
    }
    elsif ($key eq 'k' || $key eq '<Up>') {
        $self->move_cursor(-1);
        return 1;
    }
    elsif ($key eq '<CR>' || $key eq 'l' || $key eq 'o') {
        $self->select_node;
        return 1;
    }
    elsif ($key eq 'h') {
        my $node = $self->current_node or return 1;
        if ($node->{is_dir} && $node->{expanded}) {
            delete $self->{expanded}{ $node->{path} };
            $self->refresh;
        }
        else {
            my $parent = dirname($node->{path});
            if ($self->{expanded}{$parent}) {
                delete $self->{expanded}{$parent};
                $self->refresh;
            }
        }
        return 1;
    }
    elsif ($key eq 'R') {
        $self->refresh;
        return 1;
    }
    elsif ($key eq 'H') {
        $self->toggle_hidden;
        return 1;
    }
    elsif ($key eq 'q' || $key eq '<Esc>') {
        $self->close;
        return 1;
    }
    elsif (exists $self->{actions}{$key}) {
        my $node = $self->current_node;
        $self->{actions}{$key}{cb}->($self, $node, $self->{editor}) if $node;
        return 1;
    }
    return 0;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::Explorer - Docked file tree explorer with Git badges and action hooks

=head1 SYNOPSIS

    use NeoPerl::Plugin::Explorer;
    my $exp = NeoPerl::Plugin::Explorer->new(editor => $editor);
    $exp->register_action('v', 'Parse image/PDF', sub { ... });

=head1 DESCRIPTION

Implements a docked left-hand workspace file tree showing Git status badges
from L<NeoPerl::Plugin::Git> and supporting extensible per-item action hooks
and optional file sub-node providers.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
