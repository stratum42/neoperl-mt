package NeoPerl::Plugin::Telescope;

use strict;
use warnings;
use File::Spec;
use File::Find qw(find);

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor    => $opts{editor},
        float_id  => undef,
        active    => 0,
        mode      => undef,       # files, grep, buffers, symbols, diagnostics, custom
        title     => '',
        query     => '',
        dir       => undef,
        items     => [],          # raw candidate items
        results   => [],          # filtered [ { item => ..., score => N, positions => [...] }, ... ]
        selected  => 0,
        on_select => undef,
        preview_cb => undef,
        preview_lines => [],
        preview_title => '',
    }, $class;

    if ($opts{editor}) {
        $self->attach($opts{editor});
    }
    return $self;
}

sub attach {
    my ($self, $editor) = @_;
    $self->{editor} = $editor;
    $editor->register_plugin('telescope', $self);

    $editor->modal->map('n', '<leader>ff', sub { $self->files },       desc => 'Find files');
    $editor->modal->map('n', '<leader>fg', sub { $self->grep },        desc => 'Live grep workspace');
    $editor->modal->map('n', '<leader>fb', sub { $self->buffers },     desc => 'Switch buffers');
    $editor->modal->map('n', '<leader>fs', sub { $self->symbols },     desc => 'Buffer symbols');
    $editor->modal->map('n', '<leader>fd', sub { $self->diagnostics }, desc => 'Workspace diagnostics');

    $editor->excmd->register_command('Telescope', sub {
        my ($ed, $a) = @_;
        my $which = $a->{argv}[0] || 'files';
        my $arg   = $a->{argv}[1];
        if    ($which eq 'files')       { $self->files($arg) }
        elsif ($which eq 'grep')        { $self->grep($arg) }
        elsif ($which eq 'buffers')     { $self->buffers }
        elsif ($which eq 'symbols')     { $self->symbols }
        elsif ($which eq 'diagnostics') { $self->diagnostics }
        else                            { return { ok => 0, message => "Unknown Telescope picker: $which" } }
        return { ok => 1, picker => $which, count => scalar(@{ $self->{results} }) };
    }, desc => 'Open Telescope 2-pane fuzzy finder');

    $editor->register_float_key_handler('telescope', sub {
        my ($ed, $key, $fw) = @_;
        return $self->handle_key($key);
    });

    return $self;
}

sub is_open       { return $_[0]->{active} ? 1 : 0 }
sub query         { return $_[0]->{query} }
sub results       { return $_[0]->{results} }
sub selected      { return $_[0]->{selected} }
sub preview_lines { return $_[0]->{preview_lines} }
sub preview_title { return $_[0]->{preview_title} }

# --- Core Fuzzy / Walk / Grep Adapters ---

sub _walk_files {
    my ($dir, $limit) = @_;
    $limit ||= 5000;
    if (eval { require NeoPerl::Core; 1 } && NeoPerl::Core::Fuzzy->can('walk_files')) {
        my $res = NeoPerl::Core::Fuzzy::walk_files($dir, $limit);
        return $res if ref($res) eq 'ARRAY';
    }
    my @files;
    find({
        no_chdir => 1,
        wanted   => sub {
            return if @files >= $limit;
            if (-d $_ && m{(?:^|/)(?:\.git|blib|node_modules|\.neoperl-build)$}) {
                $File::Find::prune = 1;
                return;
            }
            push @files, File::Spec->abs2rel($_, $dir) if -f $_;
        },
    }, $dir);
    return [ sort @files ];
}

sub _fuzzy_filter_items {
    my ($query, $items, $limit) = @_;
    $limit ||= 200;
    if (!defined $query || !length $query) {
        my $max = scalar(@{$items}) < $limit ? scalar(@{$items}) : $limit;
        return [
            map { { item => $items->[$_], score => 0, positions => [] } } (0 .. $max - 1)
        ];
    }

    my @labels = map { $_->{label} // '' } @{$items};
    if (eval { require NeoPerl::Core; 1 } && NeoPerl::Core::Fuzzy->can('filter')) {
        my $hits = NeoPerl::Core::Fuzzy::filter($query, \@labels, $limit);
        if (ref($hits) eq 'ARRAY') {
            my @out;
            for my $h (@{$hits}) {
                my $idx = $h->{index} // $h->{orig_index};
                next unless defined $idx && $idx >= 0 && $idx <= $#{$items};
                push @out, {
                    item      => $items->[$idx],
                    score     => $h->{score}     // 0,
                    positions => $h->{positions} || [],
                };
            }
            return \@out;
        }
    }

    # Pure-Perl subsequence fuzzy fallback
    my $qlc = lc $query;
    my @qchars = split //, $qlc;
    my @scored;
    for my $item (@{$items}) {
        my $lbl = $item->{label} // '';
        my $llc = lc $lbl;
        my @pos;
        my $cur = 0;
        my $ok  = 1;
        my $score = 0;
        for my $qc (@qchars) {
            my $idx = index($llc, $qc, $cur);
            if ($idx < 0) {
                $ok = 0;
                last;
            }
            $score += (@pos && $idx == $pos[-1] + 1) ? 15 : 5;
            $score += 10 if $idx == 0 || substr($lbl, $idx - 1, 1) =~ m{[/_\-. ]};
            push @pos, $idx;
            $cur = $idx + 1;
        }
        next unless $ok;
        $score -= int(length($lbl) / 4);
        push @scored, { item => $item, score => $score, positions => \@pos };
    }
    @scored = sort { $b->{score} <=> $a->{score} || ($a->{item}{label} cmp $b->{item}{label}) } @scored;
    splice(@scored, $limit) if @scored > $limit;
    return \@scored;
}

sub _grep_dir {
    my ($dir, $query, $limit) = @_;
    $limit ||= 300;
    return [] unless defined $query && length $query;
    if (eval { require NeoPerl::Core; 1 } && NeoPerl::Core::Fuzzy->can('grep_dir')) {
        my $res = NeoPerl::Core::Fuzzy::grep_dir($dir, $query, 1, $limit);
        return $res if ref($res) eq 'ARRAY';
    }
    my @hits;
    my $rx = eval { qr/$query/i } || qr/\Q$query\E/i;
    find({
        no_chdir => 1,
        wanted   => sub {
            return if @hits >= $limit;
            if (-d $_ && m{(?:^|/)(?:\.git|blib|node_modules|\.neoperl-build)$}) {
                $File::Find::prune = 1;
                return;
            }
            return unless -f $_ && -T $_;
            open my $fh, '<', $_ or return;
            my $lnum = 0;
            while (my $line = <$fh>) {
                if ($line =~ $rx) {
                    chomp $line;
                    push @hits, {
                        path    => $_,
                        line    => $lnum,
                        col     => $-[0] || 0,
                        len     => ($+[0] - $-[0]),
                        preview => $line,
                    };
                    last if @hits >= $limit;
                }
                $lnum++;
            }
            close $fh;
        },
    }, $dir);
    return \@hits;
}

# --- Built-in Pickers ---

sub files {
    my ($self, $dir) = @_;
    $dir ||= ($self->{editor} ? $self->{editor}->cwd : '.');
    my $list = _walk_files($dir, 5000);
    my @items;
    for my $rel (@{$list}) {
        my $full = File::Spec->file_name_is_absolute($rel) ? $rel : File::Spec->catfile($dir, $rel);
        push @items, {
            label => $rel,
            path  => $full,
            line  => 0,
            col   => 0,
        };
    }
    return $self->open_custom('Find Files', \@items, sub {
        my ($item, $ed) = @_;
        $ed->open_file($item->{path}) if $ed && $item->{path};
    }, mode => 'files', dir => $dir);
}

sub grep {
    my ($self, $initial_query, $dir) = @_;
    $dir ||= ($self->{editor} ? $self->{editor}->cwd : '.');
    my $win = $self->open_custom('Live Grep', [], sub {
        my ($item, $ed) = @_;
        $ed->jump_to($item->{path}, $item->{line} // 0, $item->{col} // 0)
            if $ed && $item->{path};
    }, mode => 'grep', dir => $dir, query => ($initial_query // ''));
    $self->set_query($initial_query) if defined $initial_query && length $initial_query;
    return $win;
}

sub buffers {
    my ($self) = @_;
    my $ed = $self->{editor} or return undef;
    my @items;
    for my $b ($ed->list_buffers) {
        my $mod = $b->modified ? '[+] ' : '';
        push @items, {
            label  => sprintf('%d: %s%s', $b->id, $mod, $b->name),
            detail => $b->path // '',
            buf_id => $b->id,
            path   => $b->path,
            line   => 0,
            col    => 0,
            badge  => $b->filetype,
            data   => $b,
        };
    }
    return $self->open_custom('Buffers', \@items, sub {
        my ($item, $e) = @_;
        $e->switch_buffer($item->{buf_id}) if $e && defined $item->{buf_id};
    }, mode => 'buffers');
}

sub symbols {
    my ($self) = @_;
    my $ed  = $self->{editor} or return undef;
    my $buf = $ed->current_buffer or return undef;
    my $syms = $ed->get_symbols($buf);
    my @items;
    for my $s (@{$syms || []}) {
        push @items, {
            label  => sprintf('%-10s %s', '[' . ($s->{kind} || 'sym') . ']', $s->{name} // ''),
            detail => sprintf('L%d', ($s->{line} // 0) + 1),
            buf_id => $buf->id,
            path   => $buf->path,
            line   => $s->{line} // 0,
            col    => $s->{col}  // 0,
            badge  => $s->{kind} || 'sym',
            data   => $s,
        };
    }
    return $self->open_custom('Document Symbols', \@items, sub {
        my ($item, $e) = @_;
        $e->jump_to($item->{buf_id} // $item->{path}, $item->{line} // 0, $item->{col} // 0) if $e;
    }, mode => 'symbols');
}

sub diagnostics {
    my ($self) = @_;
    my $ed = $self->{editor} or return undef;
    my $diags = $ed->get_diagnostics;
    my @items;
    for my $d (@{$diags || []}) {
        my $sev = uc(substr($d->{severity} || 'e', 0, 1));
        push @items, {
            label  => sprintf('[%s] %s:%d %s', $sev, ($d->{path} // "buf#$d->{buf_id}"), ($d->{line} + 1), $d->{message}),
            detail => $d->{source} // '',
            buf_id => $d->{buf_id},
            path   => $d->{path},
            line   => $d->{line} // 0,
            col    => $d->{col}  // 0,
            badge  => $d->{severity},
            data   => $d,
        };
    }
    return $self->open_custom('Diagnostics', \@items, sub {
        my ($item, $e) = @_;
        $e->jump_to($item->{buf_id} // $item->{path}, $item->{line} // 0, $item->{col} // 0) if $e;
    }, mode => 'diagnostics');
}

# --- Generic Extensible Picker (used by Memory, Skills, Cachegrind Hotspots, etc.) ---

sub open_custom {
    my ($self, $title, $items, $on_select, %opts) = @_;
    $self->close if $self->{active};

    my @norm;
    for my $raw (@{$items || []}) {
        if (ref($raw) eq 'HASH') {
            push @norm, {
                label   => $raw->{label}   // $raw->{title} // $raw->{name} // '',
                detail  => $raw->{detail}  // '',
                path    => $raw->{path},
                buf_id  => $raw->{buf_id},
                line    => $raw->{line},
                col     => $raw->{col}     // 0,
                badge   => $raw->{badge}   // '',
                preview => $raw->{preview},
                data    => exists($raw->{data}) ? $raw->{data} : $raw,
            };
        }
        else {
            push @norm, { label => "$raw", data => $raw };
        }
    }

    $self->{active}     = 1;
    $self->{title}      = $title || 'Telescope';
    $self->{mode}       = $opts{mode} || 'custom';
    $self->{dir}        = $opts{dir}  || ($self->{editor} ? $self->{editor}->cwd : '.');
    $self->{items}      = \@norm;
    $self->{query}      = $opts{query} // '';
    $self->{selected}   = 0;
    $self->{on_select}  = $on_select;
    $self->{preview_cb} = $opts{preview_cb};

    $self->_recompute_results;
    $self->_update_preview;

    if ($self->{editor}) {
        my $rects = $self->{editor}->layout->last_rects;
        my $w = $opts{width}  || int(($rects->{width}  || 120) * 0.80);
        my $h = $opts{height} || int(($rects->{height} || 40)  * 0.72);
        $w = 60 if $w < 60;
        $h = 16 if $h < 16;

        my $win = $self->{editor}->layout->open_float(
            kind      => 'telescope',
            title     => " Telescope: $self->{title} ",
            footer    => ' <CR> select | <C-j/k> move | <Esc> close ',
            border    => 'rounded',
            relative  => 'center',
            width     => $w,
            height    => $h,
            zindex    => 85,
            focusable => 1,
            meta      => $self->_build_meta,
        );
        $self->{float_id} = $win->id;
        return $win;
    }
    return $self;
}

sub _recompute_results {
    my ($self) = @_;
    if ($self->{mode} eq 'grep') {
        if (length $self->{query}) {
            my $hits = _grep_dir($self->{dir}, $self->{query}, 300);
            my @res;
            for my $h (@{$hits}) {
                my $rel = File::Spec->abs2rel($h->{path}, $self->{dir});
                my $lbl = sprintf('%s:%d: %s', $rel, ($h->{line} // 0) + 1, $h->{preview} // $h->{text} // '');
                push @res, {
                    item => {
                        label   => $lbl,
                        path    => $h->{path},
                        line    => $h->{line} // 0,
                        col     => $h->{col}  // 0,
                        preview => undef,
                        data    => $h,
                    },
                    score     => 100,
                    positions => [],
                };
            }
            $self->{results} = \@res;
        }
        else {
            $self->{results} = [];
        }
    }
    else {
        $self->{results} = _fuzzy_filter_items($self->{query}, $self->{items}, 200);
    }

    if ($self->{selected} >= scalar(@{ $self->{results} })) {
        $self->{selected} = @{ $self->{results} } ? $#{ $self->{results} } : 0;
    }
}

sub _update_preview {
    my ($self) = @_;
    my $entry = $self->{results}[ $self->{selected} ];
    if (!$entry) {
        $self->{preview_lines} = [];
        $self->{preview_title} = '';
        return;
    }
    my $item = $entry->{item};
    $self->{preview_title} = $item->{path} // $item->{label} // '';

    if (ref($item->{preview}) eq 'ARRAY') {
        $self->{preview_lines} = [ @{ $item->{preview} } ];
        return;
    }
    if (ref($item->{preview}) eq 'CODE') {
        my $lines = eval { $item->{preview}->($item, $self->{editor}) };
        $self->{preview_lines} = ref($lines) eq 'ARRAY' ? $lines : [];
        return;
    }
    if ($self->{preview_cb}) {
        my $lines = eval { $self->{preview_cb}->($item, $self->{editor}) };
        $self->{preview_lines} = ref($lines) eq 'ARRAY' ? $lines : [];
        return;
    }

    # Preview from open buffer or disk file centered around item->{line}
    my $target_line = $item->{line} // 0;
    my $start = $target_line > 6 ? $target_line - 6 : 0;
    my $end   = $start + 40;

    if ($self->{editor} && defined $item->{buf_id}) {
        my $buf = $self->{editor}->get_buffer($item->{buf_id});
        if ($buf) {
            $self->{preview_lines} = $buf->get_lines($start, $end);
            return;
        }
    }
    if (defined $item->{path} && -f $item->{path}) {
        if (open my $fh, '<', $item->{path}) {
            my @lines;
            my $idx = 0;
            while (my $l = <$fh>) {
                if ($idx >= $start && $idx < $end) {
                    chomp $l;
                    push @lines, $l;
                }
                last if $idx >= $end;
                $idx++;
            }
            close $fh;
            $self->{preview_lines} = \@lines;
            return;
        }
    }
    $self->{preview_lines} = [ $item->{detail} || $item->{label} || '' ];
}

sub _build_meta {
    my ($self) = @_;
    return {
        title         => $self->{title},
        mode          => $self->{mode},
        query         => $self->{query},
        results       => $self->{results},
        selected      => $self->{selected},
        preview_lines => $self->{preview_lines},
        preview_title => $self->{preview_title},
        total_items   => scalar(@{ $self->{items} }),
    };
}

sub _sync_float {
    my ($self) = @_;
    return unless defined $self->{float_id} && $self->{editor};
    my $win = $self->{editor}->layout->get_window($self->{float_id});
    $win->meta($self->_build_meta) if $win;
}

sub set_query {
    my ($self, $q) = @_;
    $self->{query}    = $q // '';
    $self->{selected} = 0;
    $self->_recompute_results;
    $self->_update_preview;
    $self->_sync_float;
    return $self->{results};
}

sub move_selection {
    my ($self, $delta) = @_;
    return 0 unless @{ $self->{results} };
    my $n = scalar @{ $self->{results} };
    $self->{selected} = ($self->{selected} + $delta) % $n;
    $self->_update_preview;
    $self->_sync_float;
    return $self->{selected};
}

sub select_current {
    my ($self) = @_;
    my $entry = $self->{results}[ $self->{selected} ];
    my $cb    = $self->{on_select};
    my $ed    = $self->{editor};
    $self->close;
    if ($entry && $cb) {
        $cb->($entry->{item}, $ed);
    }
    return $entry ? $entry->{item} : undef;
}

sub close {
    my ($self) = @_;
    if (defined $self->{float_id} && $self->{editor}) {
        $self->{editor}->layout->close_float($self->{float_id});
    }
    $self->{float_id} = undef;
    $self->{active}   = 0;
    return 1;
}

sub handle_key {
    my ($self, $raw_key) = @_;
    return 0 unless $self->{active};
    my $key = NeoPerl::Modal::_normalize_key($raw_key);

    if ($key eq '<Esc>' || $key eq '<C-c>') {
        $self->close;
        return 1;
    }
    if ($key eq '<CR>') {
        $self->select_current;
        return 1;
    }
    if ($key eq '<Down>' || $key eq '<C-n>' || $key eq '<C-j>') {
        $self->move_selection(1);
        return 1;
    }
    if ($key eq '<Up>' || $key eq '<C-p>' || $key eq '<C-k>') {
        $self->move_selection(-1);
        return 1;
    }
    if ($key eq '<BS>') {
        if (length $self->{query}) {
            substr($self->{query}, -1, 1, '');
            $self->set_query($self->{query});
        }
        return 1;
    }
    if (length($key) == 1 && ord($key) >= 32) {
        $self->set_query($self->{query} . $key);
        return 1;
    }
    return 1;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::Telescope - 2-pane floating fuzzy finder backed by NeoPerl::Core::Fuzzy

=head1 SYNOPSIS

    use NeoPerl::Plugin::Telescope;
    my $tel = NeoPerl::Plugin::Telescope->new(editor => $editor);
    $tel->files;
    $tel->open_custom('Hotspots', \@items, sub { my ($item, $ed) = @_; ... });

=head1 DESCRIPTION

Provides a 2-pane floating fuzzy picker with live preview and matched-character
positions for files, parallel project grep, open buffers, document symbols,
diagnostics, and custom plugin data sources via C<open_custom>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
