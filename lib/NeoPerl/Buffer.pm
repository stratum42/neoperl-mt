package NeoPerl::Buffer;

use strict;
use warnings;
use File::Basename qw(basename);
use NeoPerl::Core;

our $VERSION = '0.01';

my %TOK_TYPE_TO_GROUP = (
    0  => 'normal',
    1  => 'keyword',
    2  => 'string',
    3  => 'comment',
    4  => 'number',
    5  => 'variable',
    6  => 'function',
    7  => 'type',
    8  => 'operator',
    9  => 'preprocessor',
    10 => 'constant',
    11 => 'tag',
);

sub new {
    my ($class, %opts) = @_;
    my $core;
    my $path = $opts{path};

    if (defined $path && $opts{load} && -f $path) {
        $core = NeoPerl::Core::Buffer->open_file($path);
    }
    elsif (defined $opts{text}) {
        $core = NeoPerl::Core::Buffer->from_string($opts{text});
    }
    else {
        $core = NeoPerl::Core::Buffer->new;
    }

    my $name = $opts{name};
    if (!defined $name) {
        $name = defined($path) ? basename($path) : '[No Name]';
    }

    my $self = bless {
        id            => $opts{id} // 1,
        editor        => $opts{editor},
        core          => $core,
        path          => $path,
        name          => $name,
        filetype      => $opts{filetype},
        modified      => 0,
        readonly      => $opts{readonly} ? 1 : 0,
        modifiable    => exists($opts{modifiable}) ? ($opts{modifiable} ? 1 : 0) : 1,
        buftype       => $opts{buftype} // '',
        lsp_version   => 1,
        git_baseline  => undef,
        marks         => {},
        ghost_text    => undef,
        diff_proposal => undef,
        term          => undef,
        options       => { %{ $opts{options} || {} } },
        syntax        => undef,
    }, $class;

    if (!defined $self->{filetype} || !length $self->{filetype}) {
        $self->{filetype} = $self->detect_filetype;
    }
    $self->{syntax} = NeoPerl::Core::Syntax->new($self->{filetype});

    return $self;
}

# --- Accessors ---

sub id           { return $_[0]->{id} }
sub core         { return $_[0]->{core} }
sub path         { return $_[0]->{path} }
sub name         { my $s = shift; $s->{name} = $_[0] if @_; return $s->{name} }
sub filetype     {
    my ($self, $ft) = @_;
    if (defined $ft) {
        $self->{filetype} = $ft;
        $self->{syntax}->set_language($ft) if $self->{syntax};
    }
    return $self->{filetype};
}
sub modified     { my $s = shift; $s->{modified} = $_[0] ? 1 : 0 if @_; return $s->{modified} }
sub is_dirty     { return $_[0]->{modified} ? 1 : 0 }
sub readonly     { my $s = shift; $s->{readonly} = $_[0] ? 1 : 0 if @_; return $s->{readonly} }
sub modifiable   { my $s = shift; $s->{modifiable} = $_[0] ? 1 : 0 if @_; return $s->{modifiable} }
sub buftype      { my $s = shift; $s->{buftype} = $_[0] if @_; return $s->{buftype} }
sub lsp_version  { return $_[0]->{lsp_version} }
sub rev          { return $_[0]->{core}->revision }
sub changedtick  { return $_[0]->{core}->revision }
sub git_baseline { my $s = shift; $s->{git_baseline} = $_[0] if @_; return $s->{git_baseline} }
sub syntax       { return $_[0]->{syntax} }
sub term         { return $_[0]->{term} }
sub ghost_text   { return $_[0]->{ghost_text} }
sub diff_proposal { return $_[0]->{diff_proposal} }

sub set_path {
    my ($self, $path) = @_;
    $self->{path} = $path;
    $self->{name} = defined($path) ? basename($path) : '[No Name]';
    my $ft = $self->detect_filetype;
    $self->filetype($ft);
    return $path;
}

sub set_option {
    my ($self, $key, $val) = @_;
    $self->{options}{$key} = $val;
}

sub get_option {
    my ($self, $key) = @_;
    return $self->{options}{$key};
}

sub detect_filetype {
    my ($self) = @_;
    if (defined $self->{path} && length $self->{path}) {
        my $lang = NeoPerl::Core::detect_language($self->{path});
        return $lang if defined $lang && $lang ne 'text';
    }
    my $first = $self->get_line(0) // '';
    if ($first =~ /^#!.*\bperl\b/i)      { return 'perl' }
    if ($first =~ /^#!.*\bpython\d*\b/i) { return 'python' }
    if ($first =~ /^#!.*\b(?:ba|z|k)?sh\b/i) { return 'sh' }
    if ($first =~ /^#!.*\bnode\b/i)      { return 'js' }
    if ($first =~ /^#!.*\blua\b/i)       { return 'lua' }
    if ($first =~ /^#!.*\btclsh\b/i)     { return 'tcl' }
    return 'text';
}

# --- File I/O ---

sub load_file {
    my ($self, $path) = @_;
    $path //= $self->{path};
    die "No file path specified" unless defined $path && length $path;
    $self->{core}        = NeoPerl::Core::Buffer->open_file($path);
    $self->{path}        = $path;
    $self->{name}        = basename($path);
    $self->{modified}    = 0;
    $self->{lsp_version}++;
    $self->{diff_proposal} = undef;
    $self->{ghost_text}    = undef;
    $self->filetype($self->detect_filetype);
    $self->{syntax}->invalidate(0, 0) if $self->{syntax};
    return 1;
}

sub reload {
    my ($self) = @_;
    return 0 unless defined $self->{path} && -f $self->{path};
    return $self->load_file($self->{path});
}

sub save {
    my ($self, $path) = @_;
    $path //= $self->{path};
    return 0 unless defined $path && length $path;
    my $ok = eval { $self->{core}->save_file($path) };
    return 0 unless $ok;
    $self->{path}     = $path;
    $self->{name}     = basename($path);
    $self->{modified} = 0;
    return 1;
}

# --- Text / Line Queries ---

sub line_count {
    my ($self) = @_;
    return $self->{core}->line_count;
}

sub byte_length {
    my ($self) = @_;
    return $self->{core}->byte_length;
}

sub get_line {
    my ($self, $row) = @_;
    return undef if !defined($row) || $row < 0 || $row >= $self->line_count;
    return $self->{core}->get_line($row);
}

sub get_lines {
    my ($self, $start, $end) = @_;
    my $total = $self->line_count;
    $start = 0 unless defined $start;
    $start = 0 if $start < 0;
    if (!defined $end || $end < 0 || $end > $total) {
        $end = $total;
    }
    return [] if $start >= $end;
    return $self->{core}->get_lines($start, $end - $start);
}

sub get_text {
    my ($self) = @_;
    return $self->{core}->to_string;
}

sub get_range {
    my ($self, $offset, $len) = @_;
    return $self->{core}->get_range($offset, $len);
}

sub line_bounds {
    my ($self, $row) = @_;
    return $self->{core}->line_bounds($row);
}

sub line_col_to_byte {
    my ($self, $row, $col) = @_;
    return $self->{core}->line_col_to_offset($row // 0, $col // 0);
}

sub byte_to_line_col {
    my ($self, $offset) = @_;
    return $self->{core}->offset_to_line_col($offset // 0);
}

# --- Text Mutations ---

sub _touch {
    my ($self, $from_line, $delta) = @_;
    $self->{modified} = 1;
    $self->{lsp_version}++;
    if ($self->{syntax}) {
        $self->{syntax}->invalidate($from_line // 0, $delta // 0);
    }
}

sub insert {
    my ($self, $offset, $text) = @_;
    return 0 unless $self->{modifiable} && defined $text && length $text;
    my ($line, undef) = $self->byte_to_line_col($offset);
    my $nl = ($text =~ tr/\n//);
    my $ok = $self->{core}->insert($offset, $text);
    $self->_touch($line, $nl) if $ok;
    return $ok;
}

sub insert_at {
    my ($self, $row, $col, $text) = @_;
    my $off = $self->line_col_to_byte($row, $col);
    return $self->insert($off, $text);
}

sub delete {
    my ($self, $offset, $len) = @_;
    return 0 unless $self->{modifiable} && defined $len && $len > 0;
    my ($line, undef) = $self->byte_to_line_col($offset);
    my $removed = $self->{core}->get_range($offset, $len);
    my $nl = ($removed =~ tr/\n//);
    my $ok = $self->{core}->delete($offset, $len);
    $self->_touch($line, -$nl) if $ok;
    return $ok;
}

sub delete_range {
    my ($self, $r1, $c1, $r2, $c2) = @_;
    my $o1 = $self->line_col_to_byte($r1, $c1);
    my $o2 = $self->line_col_to_byte($r2, $c2);
    return 0 if $o2 <= $o1;
    return $self->delete($o1, $o2 - $o1);
}

sub replace_range {
    my ($self, $r1, $c1, $r2, $c2, $text) = @_;
    my $o1 = $self->line_col_to_byte($r1, $c1);
    my $o2 = $self->line_col_to_byte($r2, $c2);
    $self->begin_undo_group;
    $self->delete($o1, $o2 - $o1) if $o2 > $o1;
    $self->insert($o1, $text) if defined $text && length $text;
    $self->end_undo_group;
    return 1;
}

sub set_text {
    my ($self, $text) = @_;
    $text //= '';
    my $blen = $self->byte_length;
    $self->begin_undo_group;
    $self->delete(0, $blen) if $blen > 0;
    $self->insert(0, $text) if length $text;
    $self->end_undo_group;
    return 1;
}

sub set_lines {
    my ($self, $start, $end, $new_lines) = @_;
    return 0 unless $self->{modifiable};
    $new_lines ||= [];
    my $total = $self->line_count;
    $start = 0      if !defined($start) || $start < 0;
    $start = $total if $start > $total;
    $end   = $total if !defined($end)   || $end < 0 || $end > $total;
    $end   = $start if $end < $start;

    my $n_new = scalar @{$new_lines};
    my $n_del = $end - $start;

    # Case 1: Pure insertion ($start == $end)
    if ($n_del == 0) {
        return 1 if $n_new == 0;
        my $joined = join("\n", @{$new_lines});
        my $blen = $self->byte_length;

        if ($blen == 0) {
            $self->insert(0, $joined);
            return 1;
        }
        if ($start < $total) {
            my ($off, undef) = $self->line_bounds($start);
            $self->insert($off, $joined . "\n");
        }
        else {
            # Appending after the very last line
            my $last_ch = $self->get_range($blen - 1, 1);
            if ($last_ch eq "\n") {
                $self->insert($blen, $joined . "\n");
            }
            else {
                $self->insert($blen, "\n" . $joined);
            }
        }
        return 1;
    }

    # Case 2: Pure deletion ($n_new == 0)
    if ($n_new == 0) {
        my ($s_off, undef) = $self->line_bounds($start);
        my $blen = $self->byte_length;
        if ($end < $total) {
            my ($e_off, undef) = $self->line_bounds($end);
            $self->delete($s_off, $e_off - $s_off) if $e_off > $s_off;
        }
        elsif ($start > 0) {
            # Deleting up to EOF: also remove the '\n' preceding line $start
            my $del_from = $s_off > 0 ? $s_off - 1 : 0;
            $self->delete($del_from, $blen - $del_from) if $blen > $del_from;
        }
        else {
            $self->delete(0, $blen) if $blen > 0;
        }
        return 1;
    }

    # Case 3: Replace lines [$start .. $end-1] with @$new_lines
    my ($s_off, undef)     = $self->line_bounds($start);
    my ($last_off, $last_l) = $self->line_bounds($end - 1);
    my $span_end = $last_off + $last_l;
    my $joined   = join("\n", @{$new_lines});

    $self->begin_undo_group;
    $self->delete($s_off, $span_end - $s_off) if $span_end > $s_off;
    $self->insert($s_off, $joined) if length $joined;
    $self->end_undo_group;
    return 1;
}

# --- Branching Undo Tree ---

sub begin_undo_group { $_[0]->{core}->begin_group }
sub end_undo_group   { $_[0]->{core}->end_group }
sub can_undo         { return $_[0]->{core}->can_undo }
sub can_redo         { return $_[0]->{core}->can_redo }
sub undo_seq         { return $_[0]->{core}->undo_seq }
sub undo_list        { return $_[0]->{core}->undo_list }

sub undo {
    my ($self) = @_;
    my $ok = $self->{core}->undo;
    $self->_touch(0, 0) if $ok;
    return $ok;
}

sub redo {
    my ($self) = @_;
    my $ok = $self->{core}->redo;
    $self->_touch(0, 0) if $ok;
    return $ok;
}

sub undo_older {
    my ($self) = @_;
    my $ok = $self->{core}->undo_older;
    $self->_touch(0, 0) if $ok;
    return $ok;
}

sub undo_newer {
    my ($self) = @_;
    my $ok = $self->{core}->undo_newer;
    $self->_touch(0, 0) if $ok;
    return $ok;
}

sub undo_goto {
    my ($self, $seq) = @_;
    my $ok = $self->{core}->undo_goto($seq);
    $self->_touch(0, 0) if $ok;
    return $ok;
}

# --- Extmarks ---

sub set_extmark {
    my ($self, $ns, $line, $col, $opts) = @_;
    return $self->{core}->set_extmark($ns, $line // 0, $col // 0, $opts || {});
}

sub del_extmark {
    my ($self, $ns, $id) = @_;
    return $self->{core}->del_extmark($ns, $id);
}

sub clear_namespace {
    my ($self, $ns, $start_line, $end_line) = @_;
    $self->{core}->clear_namespace(
        $ns,
        defined($start_line) ? $start_line : -1,
        defined($end_line)   ? $end_line   : -1,
    );
    return 1;
}

sub get_extmarks {
    my ($self, $ns, $start_line, $end_line) = @_;
    return $self->{core}->get_extmarks(
        $ns,
        defined($start_line) ? $start_line : -1,
        defined($end_line)   ? $end_line   : -1,
    );
}

sub get_all_extmarks {
    my ($self, $start_line, $end_line) = @_;
    return $self->get_extmarks(undef, $start_line, $end_line);
}

sub extmark_count {
    my ($self, $ns) = @_;
    return $self->{core}->extmark_count($ns);
}

# --- Marks ---

sub set_mark {
    my ($self, $name, $line, $col) = @_;
    $self->{marks}{$name} = { line => $line // 0, col => $col // 0 };
    return 1;
}

sub get_mark {
    my ($self, $name) = @_;
    return $self->{marks}{$name};
}

# --- Ghost Text (Tab Autocomplete) ---

sub set_ghost_text {
    my ($self, $line, $col, $text) = @_;
    $self->clear_ghost_text;
    return 0 unless defined $text && length $text;
    $self->{ghost_text} = { line => $line, col => $col, text => $text };
    my @parts = split /\n/, $text, -1;
    my $first = shift @parts;
    my %opts = (
        virt_text => $first,
        virt_hl   => 'GhostText',
        virt_pos  => 'inline',
        priority  => 150,
    );
    if (@parts) {
        $opts{virt_lines}       = \@parts;
        $opts{virt_lines_hl}    = 'GhostText';
        $opts{virt_lines_above} = 0;
    }
    $self->set_extmark('agy_ghost', $line, $col, \%opts);
    return 1;
}

sub clear_ghost_text {
    my ($self) = @_;
    $self->{ghost_text} = undef;
    $self->clear_namespace('agy_ghost');
    return 1;
}

# --- Incremental Syntax Highlighting & Symbols ---

sub highlight_range {
    my ($self, $first_line, $count) = @_;
    $first_line //= 0;
    $count      //= 40;
    my $raw = $self->{syntax}->tokenize_range($self->{core}, $first_line, $count);
    my @out;
    for my $flat (@{$raw}) {
        my @spans;
        for (my $i = 0; $i + 2 < @{$flat}; $i += 3) {
            push @spans, {
                col   => $flat->[$i],
                len   => $flat->[$i + 1],
                type  => $flat->[$i + 2],
                group => $TOK_TYPE_TO_GROUP{ $flat->[$i + 2] } || 'normal',
            };
        }
        push @out, \@spans;
    }
    return \@out;
}

sub highlight_line {
    my ($self, $row) = @_;
    my $res = $self->highlight_range($row, 1);
    return $res->[0] || [];
}

sub get_symbols {
    my ($self) = @_;
    return $self->{syntax}->extract_symbols($self->{core});
}

# --- Myers Line Diff Helper ---

sub _split_logical_lines {
    my ($text) = @_;
    return ([], 0) unless defined $text && length $text;
    my $has_trailing_nl = (substr($text, -1) eq "\n") ? 1 : 0;
    my $body = $text;
    $body =~ s/\n\z// if $has_trailing_nl;
    my @lines = map { my $x = $_; $x =~ s/\r\z//; $x } split(/\n/, $body, -1);
    return (\@lines, $has_trailing_nl);
}

sub _compute_myers_hunks {
    my ($old_text, $new_text) = @_;
    my ($ol) = _split_logical_lines($old_text);
    my ($nl) = _split_logical_lines($new_text);
    return NeoPerl::Core::Diff::myers_lines($ol, $nl);
}

# --- Staged Inline Diff Proposal State Machine ---

sub stage_diff_proposal {
    my ($self, $new_text, %meta) = @_;
    $new_text //= '';

    # Allow registered pre-staging hooks (e.g. PerlDev automatic post-tidy gate)
    if ($self->{editor} && !$meta{skip_hooks}) {
        $new_text = $self->{editor}->run_before_stage_diff_hooks($self, $new_text, \%meta);
    }

    # Clear any prior diff overlay cleanly
    $self->clear_namespace('agy_diff');

    my $orig_text = $self->get_text;
    my ($old_lines, $old_eol) = _split_logical_lines($orig_text);
    my ($new_lines, $new_eol) = _split_logical_lines($new_text);

    my $raw_hunks = NeoPerl::Core::Diff::myers_lines($old_lines, $new_lines);
    if (!@{$raw_hunks}) {
        $self->{diff_proposal} = undef;
        return { hunks => [], count => 0, meta => \%meta };
    }

    my @hunks;
    for my $i (0 .. $#{$raw_hunks}) {
        my $h  = $raw_hunks->[$i];
        my $os = $h->{old_start};
        my $oc = $h->{old_count};
        my $ns = $h->{new_start};
        my $nc = $h->{new_count};
        my @ol = $oc > 0 ? @{$old_lines}[ $os .. $os + $oc - 1 ] : ();
        my @nl = $nc > 0 ? @{$new_lines}[ $ns .. $ns + $nc - 1 ] : ();
        push @hunks, {
            index     => $i,
            kind      => $h->{kind},
            old_start => $os,
            old_count => $oc,
            new_start => $ns,
            new_count => $nc,
            cur_start => $ns,
            cur_count => $nc,
            old_lines => \@ol,
            new_lines => \@nl,
            status    => 'pending',
        };
    }

    # Apply proposed text to buffer in one undo group so added lines live in buffer
    # and deleted lines paint as red virtual lines above each hunk in namespace agy_diff.
    $self->set_text($new_text);

    $self->{diff_proposal} = {
        orig_text => $orig_text,
        new_text  => $new_text,
        old_eol   => $old_eol,
        new_eol   => $new_eol,
        hunks     => \@hunks,
        meta      => \%meta,
    };

    $self->_paint_diff_extmarks;

    if ($self->{editor}) {
        $self->{editor}->emit('AgyProposal',
            buf      => $self,
            proposal => $self->{diff_proposal},
            hunks    => $self->list_diff_hunks,
            meta     => \%meta,
        );
    }

    return {
        hunks => $self->list_diff_hunks,
        count => scalar(@hunks),
        meta  => \%meta,
    };
}

sub _paint_diff_extmarks {
    my ($self) = @_;
    $self->clear_namespace('agy_diff');
    my $prop = $self->{diff_proposal} or return;
    my $max_line = $self->line_count > 0 ? $self->line_count - 1 : 0;
    my $source = $prop->{meta}{source} || 'proposal';

    my @pending = grep { $_->{status} eq 'pending' } @{ $prop->{hunks} };
    my $total_p = scalar @pending;
    my $pnum    = 0;

    for my $h (@pending) {
        $pnum++;
        my $cs = $h->{cur_start};
        my $cc = $h->{cur_count};
        my $anchor = $cs > $max_line ? $max_line : $cs;
        my $above  = ($cs > $max_line) ? 0 : 1;

        # 1. Red virtual deleted lines
        if (@{ $h->{old_lines} }) {
            my @vlines = map { "- $_" } @{ $h->{old_lines} };
            $self->set_extmark('agy_diff', $anchor, 0, {
                virt_lines       => \@vlines,
                virt_lines_hl    => 'DiffDelete',
                virt_lines_above => $above,
                ($cc == 0 ? (
                    sign_text => '-',
                    sign_hl   => 'DiffDelete',
                    virt_text => sprintf('  [%s hunk %d/%d: del | <leader>ay accept | <leader>an reject]', $source, $pnum, $total_p),
                    virt_hl   => 'DiffDelete',
                    virt_pos  => 'eol',
                ) : ()),
                priority => 220,
            });
        }

        # 2. Green added / changed line highlights
        for my $off (0 .. $cc - 1) {
            my $l = $cs + $off;
            last if $l > $max_line;
            my $llen = length($self->get_line($l) // '');
            my %opts = (
                end_line  => $l,
                end_col   => $llen,
                hl_group  => 'DiffAdd',
                sign_text => '+',
                sign_hl   => 'DiffAdd',
                priority  => 210,
            );
            if ($off == 0) {
                $opts{virt_text} = sprintf('  [%s hunk %d/%d: %s | <leader>ay accept | <leader>an reject]',
                    $source, $pnum, $total_p, $h->{kind});
                $opts{virt_hl}   = 'DiffAdd';
                $opts{virt_pos}  = 'eol';
            }
            $self->set_extmark('agy_diff', $l, 0, \%opts);
        }
    }
}

sub has_diff_proposal {
    my ($self) = @_;
    my $prop = $self->{diff_proposal} or return 0;
    return (grep { $_->{status} eq 'pending' } @{ $prop->{hunks} }) ? 1 : 0;
}

sub list_diff_hunks {
    my ($self, $include_all) = @_;
    my $prop = $self->{diff_proposal} or return [];
    if ($include_all) {
        return [ @{ $prop->{hunks} } ];
    }
    return [ grep { $_->{status} eq 'pending' } @{ $prop->{hunks} } ];
}

sub next_hunk {
    my ($self, $cur_line) = @_;
    $cur_line //= -1;
    my $pending = $self->list_diff_hunks;
    return undef unless @{$pending};
    for my $h (@{$pending}) {
        return $h if $h->{cur_start} > $cur_line;
    }
    return $pending->[0];
}

sub prev_hunk {
    my ($self, $cur_line) = @_;
    $cur_line //= $self->line_count + 1;
    my $pending = $self->list_diff_hunks;
    return undef unless @{$pending};
    for my $h (reverse @{$pending}) {
        return $h if $h->{cur_start} < $cur_line;
    }
    return $pending->[-1];
}

sub _find_hunk_by_index {
    my ($self, $idx) = @_;
    my $prop = $self->{diff_proposal} or return undef;
    return undef unless defined $idx && $idx >= 0 && $idx <= $#{ $prop->{hunks} };
    return $prop->{hunks}[$idx];
}

sub _find_pending_hunk_at_line {
    my ($self, $line) = @_;
    my $pending = $self->list_diff_hunks;
    for my $h (@{$pending}) {
        my $s = $h->{cur_start};
        my $e = $h->{cur_count} > 0 ? $s + $h->{cur_count} - 1 : $s;
        return $h if $line >= $s && $line <= $e;
    }
    return undef;
}

sub _check_proposal_resolved {
    my ($self) = @_;
    my $prop = $self->{diff_proposal} or return;
    if (!$self->has_diff_proposal) {
        my $finished = $self->{diff_proposal};
        $self->{diff_proposal} = undef;
        $self->clear_namespace('agy_diff');
        if ($self->{editor}) {
            $self->{editor}->emit('AgyProposalResolved',
                buf      => $self,
                proposal => $finished,
            );
        }
    }
}

sub accept_hunk {
    my ($self, $idx) = @_;
    my $h = $self->_find_hunk_by_index($idx) or return 0;
    return 0 unless $h->{status} eq 'pending';
    $h->{status} = 'accepted';
    $self->_paint_diff_extmarks;
    $self->_check_proposal_resolved;
    return 1;
}

sub reject_hunk {
    my ($self, $idx) = @_;
    my $prop = $self->{diff_proposal} or return 0;
    my $h    = $self->_find_hunk_by_index($idx) or return 0;
    return 0 unless $h->{status} eq 'pending';

    # Rebuild logical lines cleanly so single-hunk revert is exact even at EOF
    my ($cur_lines, $has_eol) = _split_logical_lines($self->get_text);
    my $cs = $h->{cur_start};
    my $cc = $h->{cur_count};
    splice(@{$cur_lines}, $cs, $cc, @{ $h->{old_lines} });

    my $rebuilt = join("\n", @{$cur_lines});
    my $want_eol = @{$cur_lines} ? ($prop->{old_eol} || $has_eol) : 0;
    $rebuilt .= "\n" if $want_eol;
    $self->set_text($rebuilt);

    my $delta = scalar(@{ $h->{old_lines} }) - $cc;
    $h->{status} = 'rejected';
    for my $other (@{ $prop->{hunks} }) {
        if ($other->{index} > $h->{index}) {
            $other->{cur_start} += $delta;
        }
    }

    $self->_paint_diff_extmarks;
    $self->_check_proposal_resolved;
    $self->{editor}->emit('TextChanged', buf => $self) if $self->{editor};
    return 1;
}

sub accept_hunk_at_line {
    my ($self, $line) = @_;
    my $h = $self->_find_pending_hunk_at_line($line) or return 0;
    return $self->accept_hunk($h->{index});
}

sub reject_hunk_at_line {
    my ($self, $line) = @_;
    my $h = $self->_find_pending_hunk_at_line($line) or return 0;
    return $self->reject_hunk($h->{index});
}

sub accept_all_hunks {
    my ($self) = @_;
    my $prop = $self->{diff_proposal} or return 0;
    my $cnt = 0;
    for my $h (@{ $prop->{hunks} }) {
        if ($h->{status} eq 'pending') {
            $h->{status} = 'accepted';
            $cnt++;
        }
    }
    $self->_paint_diff_extmarks;
    $self->_check_proposal_resolved;
    return $cnt;
}

sub reject_all_hunks {
    my ($self) = @_;
    my $prop = $self->{diff_proposal} or return 0;
    my @pending = grep { $_->{status} eq 'pending' } @{ $prop->{hunks} };
    my $cnt = scalar @pending;
    return 0 unless $cnt;

    # If none were accepted yet, restore exact original text directly
    my $any_accepted = grep { $_->{status} eq 'accepted' } @{ $prop->{hunks} };
    if (!$any_accepted) {
        my $orig = $prop->{orig_text};
        $_->{status} = 'rejected' for @pending;
        $self->set_text($orig);
        $self->_paint_diff_extmarks;
        $self->_check_proposal_resolved;
        $self->{editor}->emit('TextChanged', buf => $self) if $self->{editor};
        return $cnt;
    }

    # Otherwise revert each remaining pending hunk from bottom to top
    for my $h (reverse @pending) {
        $self->reject_hunk($h->{index});
    }
    return $cnt;
}

# --- POSIX PTY Terminal Backing ---

sub spawn_terminal {
    my ($self, $cmd, $cols, $rows, $args) = @_;
    $cmd  ||= $ENV{SHELL} || '/bin/sh';
    $cols ||= 80;
    $rows ||= 24;
    my $cwd = $self->{editor} ? $self->{editor}->cwd : '';

    my @argv;
    if (ref($args) eq 'ARRAY') {
        @argv = @{$args};
    }
    elsif ($cmd =~ /\s/) {
        @argv = ('-c', $cmd);
        $cmd  = '/bin/sh';
    }

    my $term = eval {
        NeoPerl::Core::Term->spawn($rows, $cols, $cmd, (@argv ? \@argv : undef), $cwd);
    };
    return 0 unless $term;
    $self->{term}    = $term;
    $self->{buftype} = 'terminal';
    return 1;
}

sub write_terminal {
    my ($self, $bytes) = @_;
    return 0 unless $self->{term};
    return $self->{term}->write($bytes);
}

sub poll_terminal {
    my ($self, $timeout_ms) = @_;
    return 0 unless $self->{term};
    my $n = $self->{term}->poll($timeout_ms // 0);
    if ($n > 0) {
        my $scr = $self->{term}->get_screen;
        if ($scr && ref($scr->{lines}) eq 'ARRAY') {
            my $txt = join("\n", @{ $scr->{lines} });
            my $blen = $self->byte_length;
            $self->{core}->delete(0, $blen) if $blen > 0;
            $self->{core}->insert(0, $txt) if length $txt;
        }
    }
    return $n;
}

sub resize_terminal {
    my ($self, $rows, $cols) = @_;
    return 0 unless $self->{term};
    return $self->{term}->resize($rows, $cols);
}

sub terminal_screen {
    my ($self) = @_;
    return undef unless $self->{term};
    return $self->{term}->get_screen;
}

1;

__END__

=head1 NAME

NeoPerl::Buffer - High-level Neovim buffer wrapper over NeoPerl::Core::Buffer

=head1 SYNOPSIS

    use NeoPerl::Buffer;
    my $buf = NeoPerl::Buffer->new(text => "sub foo {\n    return 1;\n}\n", filetype => 'perl');
    $buf->stage_diff_proposal("sub foo {\n    return 2;\n}\n", source => 'antigravity');
    $buf->accept_hunk(0);

=head1 DESCRIPTION

Wraps L<NeoPerl::Core::Buffer> with automatic filetype detection, dirty flag,
LSP document versioning, Git baseline tracking, incremental syntax spans,
inline ghost-text extmarks, POSIX PTY terminal backing, and a staged inline
diff proposal state machine painting red virtual deleted lines and green added
line highlights in extmark namespace C<agy_diff>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
