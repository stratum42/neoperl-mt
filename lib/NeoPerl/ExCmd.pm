package NeoPerl::ExCmd;

use strict;
use warnings;
use File::Spec;
use File::Find qw(find);

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor   => $opts{editor},
        commands => {},   # name => { cb => ..., desc => ..., aliases => [...] }
        aliases  => {},   # alias => canonical_name
        history  => [],
    }, $class;
    $self->_register_builtins;
    return $self;
}

sub history { return $_[0]->{history} }

sub register_command {
    my ($self, $name, $cb, %opts) = @_;
    die "Command name and coderef required"
        unless defined $name && length $name && ref($cb) eq 'CODE';
    $self->{commands}{$name} = {
        name     => $name,
        cb       => $cb,
        desc     => $opts{desc} // '',
        nargs    => $opts{nargs},
        range    => $opts{range},
        bang     => $opts{bang},
        complete => $opts{complete},
    };
    if (ref($opts{aliases}) eq 'ARRAY') {
        for my $al (@{ $opts{aliases} }) {
            $self->{aliases}{$al} = $name;
        }
    }
    return 1;
}

sub unregister_command {
    my ($self, $name) = @_;
    my $removed = delete $self->{commands}{$name};
    for my $al (keys %{ $self->{aliases} }) {
        delete $self->{aliases}{$al} if $self->{aliases}{$al} eq $name;
    }
    return $removed ? 1 : 0;
}

sub has_command {
    my ($self, $name) = @_;
    return 0 unless defined $name;
    return (exists $self->{commands}{$name} || exists $self->{aliases}{$name}) ? 1 : 0;
}

sub list_commands {
    my ($self) = @_;
    return sort keys %{ $self->{commands} };
}

sub complete_command {
    my ($self, $prefix) = @_;
    $prefix //= '';
    $prefix =~ s/^:+//;
    my @all = sort keys %{ $self->{commands} };
    return [ grep { index($_, $prefix) == 0 } @all ];
}

sub _resolve_command {
    my ($self, $name) = @_;
    return $self->{commands}{$name} if exists $self->{commands}{$name};
    if (exists $self->{aliases}{$name}) {
        return $self->{commands}{ $self->{aliases}{$name} };
    }
    # Case-sensitive exact prefix match if unambiguous for user commands
    my @matches = grep { index($_, $name) == 0 } sort keys %{ $self->{commands} };
    return $self->{commands}{ $matches[0] } if @matches == 1;
    return undef;
}

# --- Range Parsing ---

sub _parse_single_addr {
    my ($self, $ed, $str_ref, $base_line) = @_;
    my $buf = $ed->current_buffer;
    my $win = $ed->current_window;
    my $max_line = ($buf && $buf->line_count > 0) ? $buf->line_count - 1 : 0;
    my $cur = defined($base_line) ? $base_line : ($win ? $win->cursor_line : 0);

    $$str_ref =~ s/^\s+//;
    my $line;

    if ($$str_ref =~ s/^\.//) {
        $line = $cur;
    }
    elsif ($$str_ref =~ s/^\$//) {
        $line = $max_line;
    }
    elsif ($$str_ref =~ s/^(\d+)//) {
        $line = $1 > 0 ? $1 - 1 : 0;
    }
    elsif ($$str_ref =~ s/^'([a-zA-Z<>'.])//) {
        my $mark = $1;
        if ($mark eq '<' || $mark eq '>') {
            my $vr = $ed->modal->last_visual_range;
            if ($vr) {
                $line = ($mark eq '<') ? $vr->{start_line} : $vr->{end_line};
            }
            else {
                $line = $cur;
            }
        }
        else {
            my $m = $ed->modal->get_mark($ed, $mark);
            $line = $m ? $m->{line} : $cur;
        }
    }
    elsif ($$str_ref =~ s{^/((?:\\/|[^/])*)/?}{}) {
        my $pat = $1;
        $line = $self->_search_line($buf, $pat, $cur + 1, 1) // $cur;
    }
    elsif ($$str_ref =~ s{^\?((?:\\\?|[^?])*)\??}{}) {
        my $pat = $1;
        $line = $self->_search_line($buf, $pat, $cur - 1, -1) // $cur;
    }
    elsif ($$str_ref =~ /^[+-]/) {
        $line = $cur;
    }
    else {
        return undef;
    }

    while ($$str_ref =~ s/^([+-])(\d*)//) {
        my $sign = $1 eq '+' ? 1 : -1;
        my $off  = length($2) ? int($2) : 1;
        $line += $sign * $off;
    }

    $line = 0         if $line < 0;
    $line = $max_line if $line > $max_line;
    return $line;
}

sub _search_line {
    my ($self, $buf, $pat, $start, $dir) = @_;
    return undef unless $buf && defined $pat && length $pat;
    my $n = $buf->line_count;
    return undef unless $n > 0;
    my $rx = eval { qr/$pat/ } or return undef;
    for my $step (0 .. $n - 1) {
        my $idx = ($start + $dir * $step) % $n;
        my $text = $buf->get_line($idx) // '';
        return $idx if $text =~ $rx;
    }
    return undef;
}

sub _parse_range {
    my ($self, $ed, $str) = @_;
    my $buf = $ed->current_buffer;
    my $max_line = ($buf && $buf->line_count > 0) ? $buf->line_count - 1 : 0;

    $str =~ s/^\s+//;
    if ($str =~ s/^%//) {
        return ({ start => 0, end => $max_line, explicit => 1 }, $str);
    }

    my $copy = $str;
    my $first = $self->_parse_single_addr($ed, \$copy);
    return (undef, $str) unless defined $first;

    my $start = $first;
    my $end   = $first;

    while ($copy =~ s/^\s*([,;])\s*//) {
        my $sep = $1;
        my $base = ($sep eq ';') ? $end : undef;
        my $next = $self->_parse_single_addr($ed, \$copy, $base);
        last unless defined $next;
        $start = $end;
        $end   = $next;
    }

    if ($start > $end) {
        ($start, $end) = ($end, $start);
    }
    return ({ start => $start, end => $end, explicit => 1 }, $copy);
}

# --- Substitute (:s/pat/rep/flags) & Global (:g/pat/cmd) ---

sub _parse_delimited_parts {
    my ($str, $max_parts) = @_;
    return () unless defined $str && length $str;
    my $delim = substr($str, 0, 1);
    return () if $delim =~ /[A-Za-z0-9\s\\]/;

    my @parts;
    my $cur = '';
    my $i = 1;
    my $len = length($str);
    while ($i < $len) {
        my $ch = substr($str, $i, 1);
        if ($ch eq '\\' && $i + 1 < $len) {
            my $next = substr($str, $i + 1, 1);
            if ($next eq $delim) {
                $cur .= $delim;
            }
            else {
                $cur .= '\\' . $next;
            }
            $i += 2;
            next;
        }
        if ($ch eq $delim) {
            push @parts, $cur;
            $cur = '';
            $i++;
            if (defined $max_parts && scalar(@parts) >= $max_parts) {
                push @parts, substr($str, $i);
                return ($delim, @parts);
            }
            next;
        }
        $cur .= $ch;
        $i++;
    }
    push @parts, $cur;
    return ($delim, @parts);
}

sub _apply_replacement {
    my ($rep_template, $match_str, $captures) = @_;
    my $out = '';
    my $i = 0;
    my $len = length($rep_template);
    while ($i < $len) {
        my $ch = substr($rep_template, $i, 1);
        if ($ch eq '&') {
            $out .= $match_str;
            $i++;
            next;
        }
        if ($ch eq '\\' && $i + 1 < $len) {
            my $next = substr($rep_template, $i + 1, 1);
            if ($next eq '0') {
                $out .= $match_str;
            }
            elsif ($next =~ /^[1-9]$/) {
                $out .= $captures->[$next - 1] // '';
            }
            elsif ($next eq 'n') {
                $out .= "\n";
            }
            elsif ($next eq 't') {
                $out .= "\t";
            }
            elsif ($next eq '&' || $next eq '\\') {
                $out .= $next;
            }
            else {
                $out .= $next;
            }
            $i += 2;
            next;
        }
        $out .= $ch;
        $i++;
    }
    return $out;
}

sub _substitute_line {
    my ($line, $rx, $rep, $global) = @_;
    my $count = 0;
    my $result = '';
    my $pos = 0;
    my $len = length($line);

    while ($pos <= $len) {
        pos($line) = $pos;
        if ($line =~ /$rx/g) {
            my $m_start = $-[0];
            my $m_end   = $+[0];
            my $matched = substr($line, $m_start, $m_end - $m_start);
            my @caps;
            for my $idx (1 .. $#+ ) {
                if (defined $-[$idx] && defined $+[$idx]) {
                    push @caps, substr($line, $-[$idx], $+[$idx] - $-[$idx]);
                }
                else {
                    push @caps, '';
                }
            }
            $result .= substr($line, $pos, $m_start - $pos);
            $result .= _apply_replacement($rep, $matched, \@caps);
            $count++;
            if ($m_end == $m_start) {
                if ($m_end < $len) {
                    $result .= substr($line, $m_end, 1);
                    $pos = $m_end + 1;
                }
                else {
                    $pos = $len + 1;
                }
            }
            else {
                $pos = $m_end;
            }
            last unless $global;
        }
        else {
            $result .= substr($line, $pos);
            last;
        }
    }
    return ($result, $count);
}

sub _run_substitute {
    my ($self, $ed, $range, $rest, $dry_run) = @_;
    my $buf = $ed->current_buffer or return { ok => 0, message => 'No active buffer' };
    my $win = $ed->current_window;
    my $cur = $win ? $win->cursor_line : 0;

    my $start = $range ? $range->{start} : $cur;
    my $end   = $range ? $range->{end}   : $cur;

    my ($delim, $pat, $rep, $flags) = _parse_delimited_parts($rest, 2);
    if (!defined $delim) {
        return { ok => 0, message => 'Invalid :substitute syntax' };
    }
    $pat   //= '';
    $rep   //= '';
    $flags //= '';

    if (!length $pat) {
        $pat = $ed->search_state->{pattern} || '';
    }
    return { ok => 0, message => 'Empty search pattern' } unless length $pat;

    my $global = ($flags =~ /g/) ? 1 : 0;
    my $icase  = ($flags =~ /i/) ? 1 : ($flags =~ /I/) ? 0 : 0;
    my $count_only = ($flags =~ /n/) || $dry_run ? 1 : 0;

    my $rx = eval { $icase ? qr/$pat/i : qr/$pat/ };
    if (!$rx) {
        my $err = $@ || 'Invalid regex';
        chomp $err;
        return { ok => 0, message => "Pattern error: $err" };
    }

    my $total_subs = 0;
    my $lines_hit  = 0;
    my @changes;
    my @previews;

    for my $l ($start .. $end) {
        my $orig = $buf->get_line($l);
        next unless defined $orig;
        my ($new_line, $cnt) = _substitute_line($orig, $rx, $rep, $global);
        if ($cnt > 0) {
            $total_subs += $cnt;
            $lines_hit++;
            push @changes, [ $l, $new_line ];
            push @previews, { line => $l, before => $orig, after => $new_line, count => $cnt };
        }
    }

    if (!$count_only && @changes) {
        $buf->begin_undo_group;
        # Apply from bottom to top so multi-line replacements (\n) don't shift earlier line indices
        for my $chg (reverse @changes) {
            my ($l, $new_text) = @{$chg};
            my @rep_lines = split /\n/, $new_text, -1;
            $buf->set_lines($l, $l + 1, \@rep_lines);
        }
        $buf->end_undo_group;
        $ed->emit('TextChanged', buf => $buf);
    }

    $ed->search_state->{pattern} = $pat;
    my $msg = $total_subs
        ? sprintf('%d substitution%s on %d line%s',
            $total_subs, ($total_subs == 1 ? '' : 's'),
            $lines_hit,  ($lines_hit  == 1 ? '' : 's'))
        : "Pattern not found: $pat";

    $ed->notify($msg, $total_subs ? 'info' : 'warn') unless $dry_run;
    return {
        ok            => $total_subs ? 1 : 0,
        message       => $msg,
        count         => $total_subs,
        lines_matched => $lines_hit,
        previews      => \@previews,
    };
}

sub preview_substitute {
    my ($self, $ed, $cmdline) = @_;
    my $raw = $cmdline // '';
    $raw =~ s/^:+//;
    my ($range, $rest) = $self->_parse_range($ed, $raw);
    if ($rest =~ s/^(?:substitute|subst|sub|s)(?=[^A-Za-z0-9\s\\])//) {
        return $self->_run_substitute($ed, $range, $rest, 1);
    }
    return { ok => 0, count => 0, lines_matched => 0, previews => [] };
}

sub _run_global {
    my ($self, $ed, $range, $invert, $rest) = @_;
    my $buf = $ed->current_buffer or return { ok => 0, message => 'No active buffer' };
    my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
    my $start = $range ? $range->{start} : 0;
    my $end   = $range ? $range->{end}   : $max_line;

    my ($delim, $pat, $cmd) = _parse_delimited_parts($rest, 1);
    return { ok => 0, message => 'Invalid :global syntax' } unless defined $delim && length $pat;
    $cmd = 'p' if !defined($cmd) || !length($cmd);

    my $rx = eval { qr/$pat/ };
    return { ok => 0, message => "Invalid regex: $pat" } unless $rx;

    my @matched_lines;
    for my $l ($start .. $end) {
        my $text = $buf->get_line($l);
        next unless defined $text;
        my $hit = ($text =~ $rx) ? 1 : 0;
        $hit = !$hit if $invert;
        push @matched_lines, $l if $hit;
    }

    return { ok => 1, message => 'No matches', matched => 0, lines => [] } unless @matched_lines;

    my $trim_cmd = $cmd;
    $trim_cmd =~ s/^\s+//;

    if ($trim_cmd eq 'p' || $trim_cmd eq 'print') {
        my @out = map { $buf->get_line($_) } @matched_lines;
        my $msg = sprintf('%d matching line(s)', scalar(@matched_lines));
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, matched => scalar(@matched_lines), lines => \@out };
    }

    my $win = $ed->current_window;
    $buf->begin_undo_group;
    # Process bottom-up for deletions so indices stay valid
    my @order = ($trim_cmd =~ /^(?:d|del|delete)\b/) ? reverse(@matched_lines) : @matched_lines;
    for my $l (@order) {
        next if $l >= $buf->line_count;
        $win->set_cursor($l, 0) if $win;
        $self->execute($ed, $trim_cmd, _nested => 1);
    }
    $buf->end_undo_group;
    $ed->emit('TextChanged', buf => $buf);

    my $msg = sprintf(':global executed on %d line(s)', scalar(@matched_lines));
    $ed->notify($msg, 'info');
    return { ok => 1, message => $msg, matched => scalar(@matched_lines) };
}

# --- Main Execution Entry ---

sub execute {
    my ($self, $ed, $cmdline, %opts) = @_;
    $ed ||= $self->{editor};
    my $raw = $cmdline // '';
    $raw =~ s/^\s*:?\s*//;
    $raw =~ s/\s+$//;
    return { ok => 1, message => '' } unless length $raw;

    push @{ $self->{history} }, $raw unless $opts{_nested};

    my ($range, $rest) = $self->_parse_range($ed, $raw);
    $rest =~ s/^\s+//;

    # Pure line-number / address jump (:42, :$, etc.)
    if (!length $rest && $range) {
        my $win = $ed->current_window;
        if ($win) {
            $win->set_cursor($range->{end}, 0);
            $ed->layout->ensure_cursor_visible($win);
            $ed->emit('CursorMoved', win => $win, buf => $ed->current_buffer);
        }
        return { ok => 1, message => "Line " . ($range->{end} + 1), line => $range->{end} };
    }

    # Special form: :[range]s/pat/rep/flags
    if ($rest =~ s/^(?:substitute|subst|sub|s)(?=[^A-Za-z0-9\s\\])//) {
        return $self->_run_substitute($ed, $range, $rest, 0);
    }

    # Special form: :[range]g[!]/pat/cmd or :[range]v/pat/cmd
    if ($rest =~ s/^(?:global|g)(!)?(?=[^A-Za-z0-9\s\\])//) {
        my $inv = $1 ? 1 : 0;
        return $self->_run_global($ed, $range, $inv, $rest);
    }
    if ($rest =~ s/^(?:vglobal|v)(?=[^A-Za-z0-9\s\\])//) {
        return $self->_run_global($ed, $range, 1, $rest);
    }

    # General Ex command: <name>[!] [args]
    if ($rest =~ /^([A-Za-z_][A-Za-z0-9_-]*)(!)?(?:\s+(.*))?$/s) {
        my ($name, $bang, $args_str) = ($1, $2 ? 1 : 0, $3 // '');
        my $spec = $self->_resolve_command($name);
        if (!$spec) {
            my $msg = "Not an editor command: $name";
            $ed->notify($msg, 'error');
            return { ok => 0, message => $msg };
        }
        my @argv = length($args_str) ? split(/\s+/, $args_str) : ();
        my $res = eval {
            $spec->{cb}->($ed, {
                name  => $spec->{name},
                alias => $name,
                args  => $args_str,
                argv  => \@argv,
                bang  => $bang,
                range => $range,
                raw   => $raw,
            });
        };
        if ($@) {
            my $err = $@;
            chomp $err;
            $ed->notify("Command :$name failed: $err", 'error');
            return { ok => 0, message => $err };
        }
        return ref($res) eq 'HASH' ? $res : { ok => 1, message => '', data => $res };
    }

    my $msg = "Invalid command: $raw";
    $ed->notify($msg, 'error');
    return { ok => 0, message => $msg };
}

# --- Built-in Commands ---

sub _register_builtins {
    my ($self) = @_;

    # :w / :write
    $self->register_command('write', sub {
        my ($ed, $a) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $target = $a->{args} || $buf->path;
        if (!defined $target || !length $target) {
            $ed->notify('No file name', 'error');
            return { ok => 0, message => 'No file name' };
        }
        $ed->emit('BufWritePre', buf => $buf, path => $target);
        my $ok = $buf->save($target);
        if (!$ok) {
            my $msg = "Failed to write $target";
            $ed->notify($msg, 'error');
            return { ok => 0, message => $msg };
        }
        $ed->emit('BufWritePost', buf => $buf, path => $buf->path);
        my $msg = sprintf('"%s" %dL written', $buf->name, $buf->line_count);
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, path => $buf->path };
    }, aliases => ['w'], desc => 'Write current buffer to disk');

    # :q / :quit
    $self->register_command('quit', sub {
        my ($ed, $a) = @_;
        my @wins = $ed->layout->list_windows;
        if (@wins > 1 || $ed->layout->tab_count > 1) {
            $ed->layout->close_window;
            return { ok => 1, message => 'Window closed' };
        }
        my $ok = $ed->quit($a->{bang});
        return { ok => $ok, message => $ok ? 'Quit' : 'Unsaved changes' };
    }, aliases => ['q'], desc => 'Close window or quit editor');

    # :wq / :x
    $self->register_command('wq', sub {
        my ($ed, $a) = @_;
        my $wres = $self->execute($ed, 'write' . ($a->{bang} ? '!' : '') . (length($a->{args}) ? " $a->{args}" : ''), _nested => 1);
        return $wres unless $wres->{ok};
        return $self->execute($ed, 'quit' . ($a->{bang} ? '!' : ''), _nested => 1);
    }, aliases => ['x', 'xit'], desc => 'Write buffer and quit');

    # :e / :edit
    $self->register_command('edit', sub {
        my ($ed, $a) = @_;
        if (!length $a->{args}) {
            my $buf = $ed->current_buffer;
            if ($buf && $buf->path && -f $buf->path) {
                $buf->reload;
                $ed->emit('BufReadPost', buf => $buf, path => $buf->path);
                return { ok => 1, message => "Reloaded " . $buf->name };
            }
            return { ok => 0, message => 'No file to reload' };
        }
        my $buf = $ed->open_file($a->{args});
        return { ok => 1, message => "Opened " . $buf->name, buf_id => $buf->id };
    }, aliases => ['e'], desc => 'Open or reload file');

    # :enew
    $self->register_command('enew', sub {
        my ($ed) = @_;
        my $buf = $ed->create_buffer(name => '[No Name]');
        $ed->switch_buffer($buf->id);
        return { ok => 1, message => 'New buffer', buf_id => $buf->id };
    }, desc => 'Create and edit new empty buffer');

    # :sp / :split
    $self->register_command('split', sub {
        my ($ed, $a) = @_;
        my $buf = length($a->{args}) ? $ed->open_file($a->{args}, no_switch => 1) : $ed->current_buffer;
        my $win = $ed->layout->hsplit($buf ? $buf->id : undef);
        return { ok => 1, message => 'Horizontal split', win_id => $win->id };
    }, aliases => ['sp'], desc => 'Horizontal window split');

    # :vsp / :vsplit
    $self->register_command('vsplit', sub {
        my ($ed, $a) = @_;
        my $buf = length($a->{args}) ? $ed->open_file($a->{args}, no_switch => 1) : $ed->current_buffer;
        my $win = $ed->layout->vsplit($buf ? $buf->id : undef);
        return { ok => 1, message => 'Vertical split', win_id => $win->id };
    }, aliases => ['vsp'], desc => 'Vertical window split');

    # :close / :only
    $self->register_command('close', sub {
        my ($ed) = @_;
        my $ok = $ed->layout->close_window;
        return { ok => $ok, message => $ok ? 'Closed window' : 'Cannot close last window' };
    }, aliases => ['clo'], desc => 'Close current window');

    $self->register_command('only', sub {
        my ($ed) = @_;
        $ed->layout->only_window;
        return { ok => 1, message => 'Kept only current window' };
    }, aliases => ['on'], desc => 'Close all other windows in current tab');

    # :tabnew / :tabclose / :tabnext / :tabprev
    $self->register_command('tabnew', sub {
        my ($ed, $a) = @_;
        my $buf = length($a->{args})
            ? $ed->open_file($a->{args}, no_switch => 1)
            : $ed->create_buffer(name => '[No Name]');
        my ($tab, $win) = $ed->layout->new_tab($buf->id);
        return { ok => 1, message => "Tab $tab->{id}", tab_id => $tab->{id}, win_id => $win->id };
    }, desc => 'Open new tabpage');

    $self->register_command('tabclose', sub {
        my ($ed) = @_;
        my $ok = $ed->layout->close_tab;
        return { ok => $ok, message => $ok ? 'Closed tab' : 'Cannot close last tab' };
    }, aliases => ['tabc'], desc => 'Close current tabpage');

    $self->register_command('tabnext', sub {
        my ($ed) = @_;
        my $tab = $ed->layout->next_tab;
        return { ok => 1, tab_id => $tab ? $tab->{id} : undef };
    }, aliases => ['tabn'], desc => 'Next tabpage');

    $self->register_command('tabprev', sub {
        my ($ed) = @_;
        my $tab = $ed->layout->prev_tab;
        return { ok => 1, tab_id => $tab ? $tab->{id} : undef };
    }, aliases => ['tabp'], desc => 'Previous tabpage');

    # Buffer navigation: :bn :bp :b :bd :ls
    $self->register_command('bnext', sub {
        my ($ed) = @_;
        my $buf = $ed->next_buffer;
        return { ok => 1, buf_id => $buf ? $buf->id : undef };
    }, aliases => ['bn'], desc => 'Next buffer');

    $self->register_command('bprev', sub {
        my ($ed) = @_;
        my $buf = $ed->prev_buffer;
        return { ok => 1, buf_id => $buf ? $buf->id : undef };
    }, aliases => ['bp'], desc => 'Previous buffer');

    $self->register_command('buffer', sub {
        my ($ed, $a) = @_;
        my $arg = $a->{args};
        return { ok => 0, message => 'Buffer id or name required' } unless length $arg;
        my $buf;
        if ($arg =~ /^\d+$/) {
            $buf = $ed->switch_buffer(int($arg));
        }
        else {
            for my $b ($ed->list_buffers) {
                if (($b->path // '') =~ /\Q$arg\E/ || ($b->name // '') =~ /\Q$arg\E/) {
                    $buf = $ed->switch_buffer($b->id);
                    last;
                }
            }
        }
        return $buf
            ? { ok => 1, buf_id => $buf->id, message => "Buffer " . $buf->id }
            : { ok => 0, message => "No matching buffer: $arg" };
    }, aliases => ['b'], desc => 'Switch to buffer by ID or name');

    $self->register_command('bdelete', sub {
        my ($ed, $a) = @_;
        my $id = length($a->{args}) && $a->{args} =~ /^\d+$/ ? int($a->{args}) : undef;
        my $ok = $ed->delete_buffer($id, force => $a->{bang});
        return { ok => $ok, message => $ok ? 'Buffer deleted' : 'Cannot delete modified buffer' };
    }, aliases => ['bd'], desc => 'Delete buffer');

    $self->register_command('ls', sub {
        my ($ed) = @_;
        my $cur = $ed->current_buffer;
        my @lines;
        my @data;
        for my $b ($ed->list_buffers) {
            my $mark = ($cur && $b->id == $cur->id) ? '%' : ' ';
            my $mod  = $b->modified ? '+' : ' ';
            push @lines, sprintf('%3d %s%s "%s" (%dL)', $b->id, $mark, $mod, $b->name, $b->line_count);
            push @data, { id => $b->id, name => $b->name, path => $b->path, modified => $b->modified };
        }
        my $msg = join(' | ', @lines);
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, data => \@data };
    }, aliases => ['buffers'], desc => 'List open buffers');

    # :d / :y range commands
    $self->register_command('delete', sub {
        my ($ed, $a) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $win = $ed->current_window;
        my $cur = $win ? $win->cursor_line : 0;
        my $s   = $a->{range} ? $a->{range}{start} : $cur;
        my $e   = $a->{range} ? $a->{range}{end}   : $cur;
        my $lines = $buf->get_lines($s, $e + 1);
        $ed->modal->set_register('"', join("\n", @{$lines}) . "\n", 'line');
        $buf->set_lines($s, $e + 1, []);
        my $max = $buf->line_count > 0 ? $buf->line_count - 1 : 0;
        $win->set_cursor($s > $max ? $max : $s, 0) if $win;
        $ed->emit('TextChanged', buf => $buf);
        return { ok => 1, deleted => scalar(@{$lines}) };
    }, aliases => ['d', 'del'], desc => 'Delete range of lines');

    $self->register_command('yank', sub {
        my ($ed, $a) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $win = $ed->current_window;
        my $cur = $win ? $win->cursor_line : 0;
        my $s   = $a->{range} ? $a->{range}{start} : $cur;
        my $e   = $a->{range} ? $a->{range}{end}   : $cur;
        my $lines = $buf->get_lines($s, $e + 1);
        $ed->modal->set_register('"', join("\n", @{$lines}) . "\n", 'line');
        return { ok => 1, yanked => scalar(@{$lines}) };
    }, aliases => ['y'], desc => 'Yank range of lines');

    # :set
    $self->register_command('set', sub {
        my ($ed, $a) = @_;
        if (!length $a->{args} || $a->{args} eq 'all') {
            my $opts = $ed->options;
            my $msg  = join(' ', map { "$_=$opts->{$_}" } sort keys %{$opts});
            $ed->notify($msg, 'info');
            return { ok => 1, message => $msg, data => $opts };
        }
        my @msgs;
        for my $tok (@{ $a->{argv} }) {
            if ($tok =~ /^([A-Za-z_][A-Za-z0-9_]*)\?$/) {
                my $val = $ed->get_option($1);
                push @msgs, "$1=" . (defined $val ? $val : 'undef');
            }
            elsif ($tok =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/) {
                my ($k, $v) = ($1, $2);
                $v = int($v) if $v =~ /^-?\d+$/;
                $ed->set_option($k, $v);
                push @msgs, "$k=$v";
            }
            elsif ($tok =~ /^no([A-Za-z_][A-Za-z0-9_]*)$/) {
                $ed->set_option($1, 0);
                push @msgs, "no$1";
            }
            elsif ($tok =~ /^([A-Za-z_][A-Za-z0-9_]*)!$/) {
                my $cur = $ed->get_option($1) ? 0 : 1;
                $ed->set_option($1, $cur);
                push @msgs, "$1=$cur";
            }
            else {
                $ed->set_option($tok, 1);
                push @msgs, "$tok=1";
            }
        }
        my $msg = join(' ', @msgs);
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg };
    }, desc => 'Get or set editor options');

    # :map / :nmap / :imap / :vmap / :unmap
    for my $spec (
        [ 'map',    ''  ],
        [ 'nmap',   'n' ],
        [ 'imap',   'i' ],
        [ 'vmap',   'v' ],
        [ 'nnoremap', 'n' ],
        [ 'inoremap', 'i' ],
        [ 'vnoremap', 'v' ],
    ) {
        my ($cname, $mode) = @{$spec};
        $self->register_command($cname, sub {
            my ($ed, $a) = @_;
            if ($a->{args} =~ /^(\S+)\s+(.+)$/) {
                $ed->modal->map($mode, $1, $2);
                return { ok => 1, message => "Mapped $1 -> $2" };
            }
            return { ok => 0, message => "Usage: :$cname <lhs> <rhs>" };
        }, desc => "Define key mapping for mode '$mode'");
    }

    $self->register_command('unmap', sub {
        my ($ed, $a) = @_;
        $ed->modal->unmap('', $a->{args});
        return { ok => 1, message => "Unmapped $a->{args}" };
    }, desc => 'Remove key mapping');

    $self->register_command('nunmap', sub {
        my ($ed, $a) = @_;
        $ed->modal->unmap('n', $a->{args});
        return { ok => 1, message => "Unmapped $a->{args}" };
    }, desc => 'Remove normal-mode key mapping');

    # :noh / :nohlsearch
    $self->register_command('nohlsearch', sub {
        my ($ed) = @_;
        $ed->search_state->{hl_active} = 0;
        return { ok => 1, message => '' };
    }, aliases => ['noh'], desc => 'Clear active search highlighting');

    # :earlier / :later / :undolist
    $self->register_command('earlier', sub {
        my ($ed, $a) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $n = ($a->{args} =~ /^(\d+)/) ? int($1) : 1;
        my $steps = 0;
        for (1 .. $n) {
            last unless $buf->undo_older;
            $steps++;
        }
        $ed->emit('TextChanged', buf => $buf) if $steps;
        return { ok => 1, steps => $steps, message => "Moved earlier $steps state(s)" };
    }, desc => 'Step backward in undo history');

    $self->register_command('later', sub {
        my ($ed, $a) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $n = ($a->{args} =~ /^(\d+)/) ? int($1) : 1;
        my $steps = 0;
        for (1 .. $n) {
            last unless $buf->undo_newer;
            $steps++;
        }
        $ed->emit('TextChanged', buf => $buf) if $steps;
        return { ok => 1, steps => $steps, message => "Moved later $steps state(s)" };
    }, desc => 'Step forward in undo history');

    $self->register_command('undolist', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $list = $buf->undo_list;
        my $msg  = sprintf('Undo states: %d', scalar(@{$list}));
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, data => $list };
    }, desc => 'List undo tree states');

    # :grep + quickfix (:copen / :cclose / :cn / :cp / :clist)
    $self->register_command('grep', sub {
        my ($ed, $a) = @_;
        my $pat = $a->{argv}[0];
        return { ok => 0, message => 'Usage: :grep <pattern> [dir]' } unless defined $pat && length $pat;
        my $dir = $a->{argv}[1] || $ed->cwd;

        my @hits;
        if (eval { require NeoPerl::Core; 1 } && NeoPerl::Core::Fuzzy->can('grep_dir')) {
            my $res = NeoPerl::Core::Fuzzy::grep_dir($dir, $pat, 0, 500);
            for my $h (@{$res || []}) {
                push @hits, {
                    path => $h->{path},
                    line => $h->{line}    // 0,
                    col  => $h->{col}     // 0,
                    text => $h->{preview} // $h->{text} // '',
                    type => 'I',
                };
            }
        }
        else {
            my $rx = eval { qr/$pat/ } || qr/\Q$pat\E/;
            find({
                no_chdir => 1,
                wanted   => sub {
                    return if @hits >= 500;
                    if (-d $_ && m{(?:^|/)(?:\.git|blib|node_modules)$}) {
                        $File::Find::prune = 1;
                        return;
                    }
                    return unless -f $_ && -T $_;
                    open my $fh, '<', $_ or return;
                    my $lnum = 0;
                    while (my $line = <$fh>) {
                        if ($line =~ $rx) {
                            chomp $line;
                            push @hits, { path => $_, line => $lnum, col => $-[0] || 0, text => $line, type => 'I' };
                            last if @hits >= 500;
                        }
                        $lnum++;
                    }
                    close $fh;
                },
            }, $dir);
        }

        $ed->set_quickfix(\@hits, open => (@hits ? 1 : 0));
        my $msg = sprintf('grep "%s": %d match(es)', $pat, scalar(@hits));
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, count => scalar(@hits), items => \@hits };
    }, desc => 'Parallel workspace grep populating quickfix list');

    $self->register_command('copen', sub {
        my ($ed) = @_;
        $ed->quickfix_open(1);
        return { ok => 1, message => 'Quickfix opened', count => scalar(@{ $ed->get_quickfix }) };
    }, desc => 'Open quickfix list');

    $self->register_command('cclose', sub {
        my ($ed) = @_;
        $ed->quickfix_open(0);
        return { ok => 1, message => 'Quickfix closed' };
    }, desc => 'Close quickfix list');

    $self->register_command('cnext', sub {
        my ($ed) = @_;
        my $item = $ed->quickfix_next;
        return $item ? { ok => 1, item => $item } : { ok => 0, message => 'Quickfix list is empty' };
    }, aliases => ['cn'], desc => 'Jump to next quickfix entry');

    $self->register_command('cprev', sub {
        my ($ed) = @_;
        my $item = $ed->quickfix_prev;
        return $item ? { ok => 1, item => $item } : { ok => 0, message => 'Quickfix list is empty' };
    }, aliases => ['cp'], desc => 'Jump to previous quickfix entry');

    $self->register_command('clist', sub {
        my ($ed) = @_;
        my $qf = $ed->get_quickfix;
        return { ok => 1, count => scalar(@{$qf}), items => $qf };
    }, aliases => ['cl'], desc => 'List quickfix entries');

    # :terminal / :term
    $self->register_command('terminal', sub {
        my ($ed, $a) = @_;
        my $cmd = length($a->{args}) ? $a->{args} : ($ENV{SHELL} || '/bin/sh');
        my $buf = $ed->create_buffer(
            name     => "term://$cmd",
            buftype  => 'terminal',
            filetype => 'sh',
        );
        my $ok = $buf->spawn_terminal($cmd, 80, 24);
        if (!$ok) {
            return { ok => 0, message => 'Failed to spawn PTY terminal' };
        }
        $ed->switch_buffer($buf->id);
        $ed->modal->set_mode($ed, 'TERMINAL');
        return { ok => 1, buf_id => $buf->id, message => "Terminal: $cmd" };
    }, aliases => ['term'], desc => 'Open interactive POSIX PTY terminal buffer');

    # :colorscheme / :colo
    $self->register_command('colorscheme', sub {
        my ($ed, $a) = @_;
        if (!length $a->{args}) {
            my $cur = $ed->get_option('colorscheme');
            $ed->notify($cur, 'info');
            return { ok => 1, message => $cur, colorscheme => $cur };
        }
        my $ok = $ed->set_colorscheme($a->{args});
        if (!$ok) {
            my $avail = join(', ', NeoPerl::Plugin::Themes->list);
            my $msg = "Unknown colorscheme '$a->{args}' (available: $avail)";
            $ed->notify($msg, 'error');
            return { ok => 0, message => $msg };
        }
        $ed->notify("Colorscheme: $a->{args}", 'info');
        return { ok => 1, message => "Colorscheme: $a->{args}", colorscheme => lc $a->{args} };
    }, aliases => ['colo'], desc => 'Switch active colorscheme');

    # :perl <code>
    $self->register_command('perl', sub {
        my ($ed, $a) = @_;
        return { ok => 0, message => 'Usage: :perl <code>' } unless length $a->{args};
        my $ok = $ed->config->eval_config($a->{args}, ':perl');
        return { ok => $ok, message => $ok ? 'OK' : 'Perl eval error' };
    }, desc => 'Evaluate Perl expression with $vim and $editor');

    # :source / :so <file>
    $self->register_command('source', sub {
        my ($ed, $a) = @_;
        return { ok => 0, message => 'Usage: :source <file>' } unless length $a->{args};
        my $ok = $ed->config->load_file($a->{args});
        return { ok => $ok, message => $ok ? "Sourced $a->{args}" : "Failed to source $a->{args}" };
    }, aliases => ['so'], desc => 'Source a Perl configuration file');

    # Default :LspInfo (replaced by NeoPerl::Plugin::LSP when attached)
    $self->register_command('LspInfo', sub {
        my ($ed) = @_;
        my $msg = 'LSP plugin not attached';
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, data => { clients => {} } };
    }, desc => 'Show LSP server status');
}

1;

__END__

=head1 NAME

NeoPerl::ExCmd - Range-aware Ex command engine for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::ExCmd;
    $editor->excmd->register_command('MyCmd', sub {
        my ($ed, $args) = @_;
        return { ok => 1, message => "Ran $args->{args}" };
    });
    $editor->exec_command(':%s/foo/bar/g');

=head1 DESCRIPTION

Parses Vim Ex command ranges (C<%>, C<.>, C<$>, line numbers, marks, search
addresses, offsets) and dispatches built-in commands (file/buffer/window/tab
management, C<:set>, C<:map>, C<:s>, C<:g>, C<:grep>, quickfix, C<:terminal>,
C<:colorscheme>, C<:perl>, C<:source>) alongside dynamically registered plugin
commands.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
