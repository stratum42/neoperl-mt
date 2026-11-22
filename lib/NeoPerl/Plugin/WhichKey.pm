package NeoPerl::Plugin::WhichKey;

use strict;
use warnings;

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor    => $opts{editor},
        float_id  => undef,
        groups    => {
            '<leader>f' => '+Find',
            '<leader>a' => '+Antigravity',
            '<leader>m' => '+Memory',
            '<leader>p' => '+Perl',
            '<leader>x' => '+XSDev',
            '<leader>d' => '+Debug',
            '<leader>v' => '+Vision',
            '<leader>g' => '+Git',
            'g'         => '+Goto / Extra',
            '<C-w>'     => '+Window',
            ']'         => '+Next',
            '['         => '+Prev',
        },
        enabled   => 1,
    }, $class;

    if ($opts{editor}) {
        $self->attach($opts{editor});
    }
    return $self;
}

sub attach {
    my ($self, $editor) = @_;
    $self->{editor} = $editor;
    $editor->register_plugin('whichkey', $self);
    return $self;
}

sub register_group {
    my ($self, $prefix, $label) = @_;
    $self->{groups}{$prefix} = $label;
    return 1;
}

sub groups {
    my ($self) = @_;
    return { %{ $self->{groups} } };
}

sub get_candidates {
    my ($self, $prefix, $mode) = @_;
    $mode ||= 'n';
    my $ed = $self->{editor} or return [];
    my $modal = $ed->modal;
    my $bindings = $modal->get_bindings_for_prefix($mode, $prefix);

    my %seen;
    my @entries;
    for my $b (@{$bindings}) {
        my $rem = $b->{remaining};
        next unless defined $rem && length $rem;
        my ($next_key, $is_leaf) = _split_first_key($rem);
        next unless defined $next_key;

        if ($is_leaf) {
            $seen{$next_key} = {
                key   => $next_key,
                label => $b->{desc} || $b->{lhs},
                group => 0,
            };
        }
        else {
            next if exists $seen{$next_key} && !$seen{$next_key}{group};
            my $sub_prefix = $prefix . $next_key;
            $seen{$next_key} = {
                key   => $next_key,
                label => $self->{groups}{$sub_prefix} || "+$next_key",
                group => 1,
            };
        }
    }

    # Built-in prefix hints for standard Vim prefixes
    if ($prefix eq '<C-w>') {
        my %w_hints = (
            s => 'Horizontal split',
            v => 'Vertical split',
            q => 'Close window',
            o => 'Only window',
            '=' => 'Equalize splits',
            h => 'Focus left',
            j => 'Focus down',
            k => 'Focus up',
            l => 'Focus right',
            w => 'Focus next',
        );
        for my $k (keys %w_hints) {
            $seen{$k} ||= { key => $k, label => $w_hints{$k}, group => 0 };
        }
    }
    elsif ($prefix eq ']') {
        $seen{h} ||= { key => 'h', label => 'Next diff hunk', group => 0 };
        $seen{d} ||= { key => 'd', label => 'Next diagnostic', group => 0 };
        $seen{']'} ||= { key => ']', label => 'Next function/sub', group => 0 };
    }
    elsif ($prefix eq '[') {
        $seen{h} ||= { key => 'h', label => 'Prev diff hunk', group => 0 };
        $seen{d} ||= { key => 'd', label => 'Prev diagnostic', group => 0 };
        $seen{'['} ||= { key => '[', label => 'Prev function/sub', group => 0 };
    }
    elsif ($prefix eq 'g') {
        $seen{g} ||= { key => 'g', label => 'Top of file', group => 0 };
        $seen{d} ||= { key => 'd', label => 'Go to definition', group => 0 };
        $seen{r} ||= { key => 'r', label => 'References', group => 0 };
        $seen{t} ||= { key => 't', label => 'Next tab', group => 0 };
        $seen{T} ||= { key => 'T', label => 'Prev tab', group => 0 };
        $seen{q} ||= { key => 'q', label => 'Format operator', group => 0 };
        $seen{'-'} ||= { key => '-', label => 'Undo older state', group => 0 };
        $seen{'+'} ||= { key => '+', label => 'Undo newer state', group => 0 };
    }

    @entries = sort { $a->{key} cmp $b->{key} } values %seen;
    return \@entries;
}

sub _split_first_key {
    my ($seq) = @_;
    if ($seq =~ /\A(<[^>]+>)(.*)\z/s) {
        return ($1, length($2) == 0 ? 1 : 0);
    }
    my $first = substr($seq, 0, 1);
    my $rest  = substr($seq, 1);
    return ($first, length($rest) == 0 ? 1 : 0);
}

sub show {
    my ($self, $prefix, $mode) = @_;
    return undef unless $self->{enabled} && $self->{editor};
    my $candidates = $self->get_candidates($prefix, $mode);
    if (!@{$candidates}) {
        $self->hide;
        return undef;
    }

    $self->hide;
    my @lines = map {
        sprintf(' %-8s -> %s', $_->{key}, $_->{label})
    } @{$candidates};

    my $height = scalar(@lines) + 2;
    $height = 14 if $height > 14;
    my $rects = $self->{editor}->layout->last_rects;
    my $width = ($rects->{width} || 100) - 4;
    $width = 64 if $width < 30;
    my $y = ($rects->{height} || 30) - $height - 2;
    $y = 1 if $y < 1;

    my $win = $self->{editor}->layout->open_float(
        kind      => 'whichkey',
        title     => " WhichKey: $prefix ",
        border    => 'rounded',
        relative  => 'editor',
        x         => 2,
        y         => $y,
        width     => $width,
        height    => $height,
        zindex    => 90,
        focusable => 0,
        lines     => \@lines,
        meta      => {
            prefix     => $prefix,
            candidates => $candidates,
        },
    );
    $self->{float_id} = $win->id;
    return $win;
}

sub hide {
    my ($self) = @_;
    return 0 unless defined $self->{float_id} && $self->{editor};
    $self->{editor}->layout->close_float($self->{float_id});
    $self->{float_id} = undef;
    return 1;
}

sub is_visible {
    my ($self) = @_;
    return defined($self->{float_id}) ? 1 : 0;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::WhichKey - Context keybinding popup for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::Plugin::WhichKey;
    my $wk = NeoPerl::Plugin::WhichKey->new(editor => $editor);
    $wk->register_group('<leader>a', '+Antigravity');
    $wk->show('<leader>');

=head1 DESCRIPTION

Displays a z-ordered floating window listing available continuation keys and
group labels whenever a multi-key prefix such as C<< <leader> >>, C<g>,
C<< <C-w> >>, C<]>, or C<[> is pending in L<NeoPerl::Modal>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
