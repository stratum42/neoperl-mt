package NeoPerl::Memory::Writer;

use strict;
use warnings;
use Carp qw(croak);
use NeoPerl::Memory::MemIgnore;

our $VERSION = '0.01';

my $HAS_MOJO_JSON;
BEGIN {
    $HAS_MOJO_JSON = eval { require Mojo::JSON; 1 } ? 1 : 0;
    require JSON::PP unless $HAS_MOJO_JSON;
}

sub _encode_json {
    my ($data) = @_;
    return $HAS_MOJO_JSON
        ? Mojo::JSON::encode_json($data)
        : JSON::PP->new->utf8->encode($data);
}

sub _decode_json {
    my ($str) = @_;
    return $HAS_MOJO_JSON
        ? Mojo::JSON::decode_json($str)
        : JSON::PP->new->utf8->decode($str);
}

sub new {
    my ($class, %args) = @_;
    croak "NeoPerl::Memory::Writer->new requires 'store'" unless $args{store};

    my $memignore = $args{memignore}
        || NeoPerl::Memory::MemIgnore->new(repo_root => $args{repo_root});

    return bless {
        store      => $args{store},
        inference  => $args{inference},
        memignore  => $memignore,
        repo_key   => $args{repo_key} // 'default',
        top_k      => $args{top_k} || 6,
        queue      => [],
        stats      => {
            events_processed => 0,
            ignored          => 0,
            redactions       => 0,
            added            => 0,
            updated          => 0,
            superseded       => 0,
            noop             => 0,
        },
        attached   => 0,
    }, $class;
}

sub store     { $_[0]{store} }
sub memignore { $_[0]{memignore} }
sub stats     { +{ %{ $_[0]{stats} } } }
sub pending   { scalar @{ $_[0]{queue} } }

sub _event_hash {
    return ($_[0] && ref($_[0]) eq 'HASH' && @_ == 1) ? $_[0] : { @_ };
}

sub attach_editor {
    my ($self, $editor) = @_;
    return 0 unless $editor && $editor->can('on');
    return 1 if $self->{attached};

    $editor->on('AgyTurnComplete', sub {
        my $data = _event_hash(@_);
        $self->enqueue_event({
            event_type  => 'AgyTurnComplete',
            repo_key    => $data->{repo_key}  // $self->{repo_key},
            file_path   => $data->{file_path} // $data->{file},
            text        => $data->{summary}   // $data->{response} // $data->{text} // '',
            category    => $data->{category},
            scope_level => $data->{scope_level} // 'repo',
        });
    });

    $editor->on('GitCommitPost', sub {
        my $data = _event_hash(@_);
        $self->enqueue_event({
            event_type  => 'GitCommitPost',
            repo_key    => $data->{repo_key}  // $self->{repo_key},
            file_path   => $data->{file_path} // $data->{file},
            text        => $data->{message}   // $data->{summary} // '',
            category    => 'decision',
            scope_level => 'repo',
        });
    });

    $editor->on('DiagnosticResolved', sub {
        my $data = _event_hash(@_);
        my $fpath = $data->{file_path} // $data->{file}
            // ($data->{buf} && $data->{buf}->can('path') ? $data->{buf}->path : undef);
        my $summary = $data->{summary} // $data->{message};
        if (!defined $summary && ref($data->{resolved}) eq 'ARRAY' && @{ $data->{resolved} }) {
            $summary = 'Resolved diagnostics: ' . join('; ', map { $_->{message} // $_->{code} // '' } @{ $data->{resolved} });
        }
        $self->enqueue_event({
            event_type  => 'DiagnosticResolved',
            repo_key    => $data->{repo_key}  // $self->{repo_key},
            file_path   => $fpath,
            symbol_name => $data->{symbol_name},
            text        => $summary // '',
            category    => 'gotcha',
            scope_level => defined($fpath) ? 'file' : 'repo',
        });
    });

    $self->{attached} = 1;
    return 1;
}

sub enqueue_event {
    my ($self, $event) = @_;
    return 0 unless ref($event) eq 'HASH';
    push @{ $self->{queue} }, { %$event };
    return scalar @{ $self->{queue} };
}

sub pump {
    my ($self, $max) = @_;
    $max ||= 4;
    my @results;
    while ($max-- > 0 && @{ $self->{queue} }) {
        my $ev = shift @{ $self->{queue} };
        push @results, $self->reconcile_event($ev);
    }
    return \@results;
}

sub save_explicit {
    my ($self, %args) = @_;
    return $self->reconcile_event({
        event_type  => 'MemSave',
        repo_key    => $args{repo_key} // $args{repo} // $self->{repo_key},
        file_path   => $args{file_path} // $args{file},
        symbol_name => $args{symbol_name} // $args{symbol},
        scope_level => $args{scope_level} // $args{scope} // 'repo',
        category    => $args{category} // 'fact',
        tags        => $args{tags} // '',
        pinned      => $args{pinned} ? 1 : 0,
        text        => $args{content} // $args{text} // '',
        explicit    => 1,
    });
}

sub reconcile_event {
    my ($self, $raw_event) = @_;
    croak "reconcile_event requires an event hashref" unless ref($raw_event) eq 'HASH';

    my $event_type = $raw_event->{event_type} // 'AgyTurnComplete';
    my $repo_key   = $raw_event->{repo_key} // $raw_event->{repo} // $self->{repo_key};
    my $file_path  = $raw_event->{file_path} // $raw_event->{file};

    # 1. Redact secrets and enforce .memignore path blocks before inference or storage
    my $clean_event = $self->{memignore}->sanitize_event($raw_event);
    if (!defined $clean_event) {
        $self->{stats}{ignored}++;
        $self->{store}->log_event({
            event_type      => $event_type,
            repo_key        => $repo_key,
            file_path       => $file_path,
            payload_summary => '[IGNORED BY .memignore]',
            action_taken    => 'IGNORED',
        });
        return {
            action     => 'IGNORED',
            operations => [],
            reason     => 'path matched .memignore',
        };
    }

    $self->{stats}{redactions} += ($clean_event->{_redactions} || 0);
    my $text = $clean_event->{text} // $clean_event->{content} // $clean_event->{summary} // '';
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;

    if (!length $text) {
        $self->{stats}{noop}++;
        return { action => 'NOOP', operations => [], reason => 'empty event text' };
    }

    # 2. Retrieve Top-K existing Db2 neighbor memories for reconciliation
    my $neighbors = $self->{store}->search(
        query              => $text,
        repo_key           => $repo_key,
        file_path          => $file_path,
        include_superseded => 0,
        limit              => $self->{top_k},
        update_access      => 0,
    );

    # 3. Reconcile via Hy-Memory-30B-A3B (temperature=0.0, reasoning_effort='no_think')
    my ($ops, $inf_meta) = $self->_invoke_hymemory($clean_event, $text, $neighbors);

    # 4. Execute ADD / UPDATE / SUPERSEDE / NOOP atomically in Store
    my @applied;
    my $model_id = 'tencent/Hy-Memory-30B-A3B-GGUF';

    for my $op (@$ops) {
        next unless ref($op) eq 'HASH';
        my $kind = uc($op->{op} // 'NOOP');
        my $content = (defined $op->{content} && length $op->{content}) ? $op->{content} : $text;

        # Second defense-in-depth redaction pass on model output
        my ($safe_content, $n_red) = $self->{memignore}->redact_text($content);
        $self->{stats}{redactions} += $n_red;
        $safe_content =~ s/^\s+//;
        $safe_content =~ s/\s+$//;

        my $scope = $op->{scope_level} // $clean_event->{scope_level} // 'repo';
        $scope = 'repo' unless defined($scope) && $scope =~ /^(?:global|repo|file|symbol)$/;

        my $cat = $op->{category} // $clean_event->{category} // 'fact';
        $cat = 'fact' unless defined($cat) && $cat =~ /^(?:preference|architecture|gotcha|convention|decision|fact)$/;

        my $raw_tags = $op->{tags} // $clean_event->{tags} // '';
        my $tags = ref($raw_tags) eq 'ARRAY'
            ? join(',', grep { defined $_ && length $_ } @$raw_tags)
            : "$raw_tags";
        my $conf = (defined $op->{confidence} && $op->{confidence} =~ /^-?\d+(?:\.\d+)?$/)
            ? ($op->{confidence} + 0.0)
            : 0.88;
        my $pin  = ($op->{pinned} || $clean_event->{pinned}) ? 1 : 0;

        # Normalize missing/non-numeric target_id on UPDATE/SUPERSEDE cleanly
        my $target_id = $op->{target_id};
        if ($kind eq 'UPDATE' || $kind eq 'SUPERSEDE') {
            if (!defined($target_id) || $target_id !~ /^\d+$/ || int($target_id) <= 0) {
                if (@$neighbors && defined $neighbors->[0]{id}) {
                    $target_id = int($neighbors->[0]{id});
                }
                else {
                    $kind      = 'ADD';
                    $target_id = undef;
                }
            }
            else {
                $target_id = int($target_id);
            }
        }

        # Defense-in-depth: downgrade redundant UPDATE (identical content & category) to NOOP
        if ($kind eq 'UPDATE' && defined $target_id && length $safe_content) {
            my $existing = eval { $self->{store}->get_memory($target_id) };
            if (!$existing && @$neighbors && defined($neighbors->[0]{id}) && int($neighbors->[0]{id}) != $target_id) {
                $target_id = int($neighbors->[0]{id});
                $existing  = eval { $self->{store}->get_memory($target_id) };
            }
            if (ref($existing) eq 'HASH') {
                (my $norm_new = lc($safe_content)) =~ s/\s+/ /g;
                $norm_new =~ s/^\s+|\s+$//g;
                (my $norm_old = lc($existing->{content} // '')) =~ s/\s+/ /g;
                $norm_old =~ s/^\s+|\s+$//g;
                if ($norm_new eq $norm_old && $cat eq ($existing->{category} // '')) {
                    $kind = 'NOOP';
                    $op   = { %$op, reason => 'unchanged content' };
                }
            }
        }

        if ($kind eq 'UPDATE' && defined $target_id && length $safe_content) {
            my $emb = $self->_embed($safe_content);
            my $updated = eval {
                $self->{store}->update_memory($target_id, {
                    content    => $safe_content,
                    category   => $cat,
                    tags       => $tags,
                    confidence => $conf,
                    embedding  => $emb,
                });
            };
            if (!$updated && @$neighbors && defined($neighbors->[0]{id}) && int($neighbors->[0]{id}) != $target_id) {
                $target_id = int($neighbors->[0]{id});
                $updated = eval {
                    $self->{store}->update_memory($target_id, {
                        content    => $safe_content,
                        category   => $cat,
                        tags       => $tags,
                        confidence => $conf,
                        embedding  => $emb,
                    });
                };
            }
            if ($updated) {
                $self->{store}->log_event({
                    event_type       => $event_type,
                    repo_key         => $repo_key,
                    file_path        => $file_path,
                    payload_summary  => substr($safe_content, 0, 240),
                    action_taken     => 'UPDATE',
                    target_memory_id => $target_id,
                    model_id         => $model_id,
                });
                $self->{stats}{updated}++;
                push @applied, { op => 'UPDATE', id => $target_id, content => $safe_content };
                next;
            }
            # Fallback to ADD if target row did not exist
            $kind = 'ADD';
        }
        elsif ($kind eq 'SUPERSEDE' && defined $target_id && length $safe_content) {
            my $emb = $self->_embed($safe_content);
            my $new_id = eval {
                $self->{store}->supersede($target_id, {
                    scope_level  => $scope,
                    repo_key     => $scope eq 'global' ? undef : $repo_key,
                    file_path    => ($scope eq 'file' || $scope eq 'symbol') ? $file_path : undef,
                    symbol_name  => ($scope eq 'symbol') ? $clean_event->{symbol_name} : undef,
                    category     => $cat,
                    content      => $safe_content,
                    tags         => $tags,
                    confidence   => $conf,
                    pinned       => $pin,
                    embedding    => $emb,
                    source_event => $event_type,
                });
            };
            if (!$new_id && @$neighbors && defined($neighbors->[0]{id}) && int($neighbors->[0]{id}) != $target_id) {
                $target_id = int($neighbors->[0]{id});
                $new_id = eval {
                    $self->{store}->supersede($target_id, {
                        scope_level  => $scope,
                        repo_key     => $scope eq 'global' ? undef : $repo_key,
                        file_path    => ($scope eq 'file' || $scope eq 'symbol') ? $file_path : undef,
                        symbol_name  => ($scope eq 'symbol') ? $clean_event->{symbol_name} : undef,
                        category     => $cat,
                        content      => $safe_content,
                        tags         => $tags,
                        confidence   => $conf,
                        pinned       => $pin,
                        embedding    => $emb,
                        source_event => $event_type,
                    });
                };
            }
            if ($new_id) {
                $self->{store}->log_event({
                    event_type       => $event_type,
                    repo_key         => $repo_key,
                    file_path        => $file_path,
                    payload_summary  => substr($safe_content, 0, 240),
                    action_taken     => 'SUPERSEDE',
                    target_memory_id => $new_id,
                    model_id         => $model_id,
                });
                $self->{stats}{superseded}++;
                push @applied, { op => 'SUPERSEDE', old_id => $target_id, id => $new_id, content => $safe_content };
                next;
            }
            # Fallback to ADD if target row did not exist
            $kind = 'ADD';
        }

        if ($kind eq 'ADD' && length $safe_content) {
            my $emb = $self->_embed($safe_content);
            my $new_id = $self->{store}->add_memory({
                scope_level  => $scope,
                repo_key     => $scope eq 'global' ? undef : $repo_key,
                file_path    => ($scope eq 'file' || $scope eq 'symbol') ? $file_path : undef,
                symbol_name  => ($scope eq 'symbol') ? $clean_event->{symbol_name} : undef,
                category     => $cat,
                content      => $safe_content,
                tags         => $tags,
                confidence   => $conf,
                pinned       => $pin,
                embedding    => $emb,
                source_event => $event_type,
            });
            if (defined $op->{related_to} && $op->{related_to} =~ /^\d+$/) {
                eval { $self->{store}->add_edge($new_id, int($op->{related_to}), $op->{relation} // 'relates_to') };
            }
            $self->{store}->log_event({
                event_type       => $event_type,
                repo_key         => $repo_key,
                file_path        => $file_path,
                payload_summary  => substr($safe_content, 0, 240),
                action_taken     => 'ADD',
                target_memory_id => $new_id,
                model_id         => $model_id,
            });
            $self->{stats}{added}++;
            push @applied, { op => 'ADD', id => $new_id, content => $safe_content, category => $cat, scope_level => $scope };
        }
        else {
            my $noop_tid = (defined $target_id && $target_id =~ /^\d+$/) ? int($target_id) : undef;
            $self->{store}->log_event({
                event_type       => $event_type,
                repo_key         => $repo_key,
                file_path        => $file_path,
                payload_summary  => substr($text, 0, 240),
                action_taken     => 'NOOP',
                target_memory_id => $noop_tid,
                model_id         => $model_id,
            });
            $self->{stats}{noop}++;
            push @applied, { op => 'NOOP', target_id => $noop_tid, reason => $op->{reason} // 'already known' };
        }
    }

    $self->{stats}{events_processed}++;
    my $primary = @applied ? $applied[0]{op} : 'NOOP';
    return {
        action     => $primary,
        operations => \@applied,
        redactions => $clean_event->{_redactions} || 0,
        neighbors  => scalar(@$neighbors),
        (ref($inf_meta) eq 'HASH' ? (
            (defined $inf_meta->{tok_per_s}  ? (tok_per_s  => $inf_meta->{tok_per_s})  : ()),
            (defined $inf_meta->{elapsed_ms} ? (elapsed_ms => $inf_meta->{elapsed_ms}) : ()),
            (defined $inf_meta->{transport}  ? (transport  => $inf_meta->{transport})  : ()),
        ) : ()),
    };
}

sub _embed {
    my ($self, $text) = @_;
    if ($self->{inference} && $self->{inference}->can('embed')) {
        return $self->{inference}->embed($text);
    }
    return undef;    # Store will embed using its configured embedder/fallback
}

sub _invoke_hymemory {
    my ($self, $event, $text, $neighbors) = @_;

    my @cand_summary = map {
        {
            id           => $_->{id},
            scope_level  => $_->{scope_level},
            category     => $_->{category},
            content      => $_->{content},
            cosine_score => sprintf('%.4f', $_->{cosine_score} // 0) + 0.0,
        }
    } @$neighbors;

    my $payload = {
        event_type  => $event->{event_type} // 'AgyTurnComplete',
        scope_level => $event->{scope_level} // 'repo',
        category    => $event->{category} // 'fact',
        file_path   => $event->{file_path},
        text        => $text,
        candidates  => \@cand_summary,
    };

    if ($self->{inference} && $self->{inference}->can('complete')) {
        my $res = $self->{inference}->complete(
            role             => 'memory_writer',
            temperature      => 0.0,
            reasoning_effort => 'no_think',
            metadata         => $payload,
            messages         => [
                {
                    role    => 'system',
                    content => 'You are Hy-Memory reconciler. Compare the new engineering event against existing memory candidates and return ONLY a raw JSON array of operations (no markdown fences, no commentary): [{"op":"ADD|UPDATE|SUPERSEDE|NOOP","target_id":null|int,"scope_level":"global|repo|file|symbol","category":"preference|architecture|gotcha|convention|decision|fact","content":"...","tags":"...","confidence":0.9}]. Rules in priority order: (1) If the event is already stated by an existing candidate (exact duplicate or restatement adding no new factual details), you MUST return [{"op":"NOOP","target_id":<candidate_id>}] and NEVER UPDATE or ADD. (2) Use ADD only for genuinely novel facts. (3) Use UPDATE only when adding meaningful new details to an existing candidate without contradicting it. (4) Use SUPERSEDE when the event replaces, deprecates, or contradicts an existing candidate.',
                },
                {
                    role    => 'user',
                    content => _encode_json($payload),
                },
            ],
        );

        my $raw = ref($res) eq 'HASH' ? ($res->{text} // $res->{content} // '') : "$res";
        my $parsed = $self->_parse_ops_json($raw);
        if (ref($parsed) eq 'ARRAY' && @$parsed) {
            my $meta = ref($res) eq 'HASH'
                ? {
                    tok_per_s  => $res->{tok_per_s},
                    elapsed_ms => $res->{elapsed_ms},
                    transport  => $res->{transport},
                }
                : {};
            return wantarray ? ($parsed, $meta) : $parsed;
        }
    }

    # Built-in deterministic reconciliation fallback if no inference manager attached
    my $fallback = $self->_heuristic_reconcile($payload);
    return wantarray ? ($fallback, {}) : $fallback;
}

sub _extract_balanced_json_candidates {
    my ($str) = @_;
    my @cands;
    my $len = length($str);
    my $pos = 0;

    while ($pos < $len) {
        my $ch = substr($str, $pos, 1);
        if ($ch ne '[' && $ch ne '{') {
            $pos++;
            next;
        }
        my $open  = $ch;
        my $close = ($open eq '[') ? ']' : '}';
        my $depth = 0;
        my $in_str = 0;
        my $esc    = 0;
        my $end    = -1;

        for (my $i = $pos; $i < $len; $i++) {
            my $c = substr($str, $i, 1);
            if ($in_str) {
                if ($esc) {
                    $esc = 0;
                }
                elsif ($c eq '\\') {
                    $esc = 1;
                }
                elsif ($c eq '"') {
                    $in_str = 0;
                }
            }
            else {
                if ($c eq '"') {
                    $in_str = 1;
                }
                elsif ($c eq $open) {
                    $depth++;
                }
                elsif ($c eq $close) {
                    $depth--;
                    if ($depth == 0) {
                        $end = $i;
                        last;
                    }
                }
            }
        }

        if ($end > $pos) {
            push @cands, substr($str, $pos, $end - $pos + 1);
            $pos = $end + 1;
        }
        else {
            $pos++;
        }
    }
    return @cands;
}

sub _normalize_op_hash {
    my ($h) = @_;
    return undef unless ref($h) eq 'HASH';

    my $raw_op = $h->{op} // $h->{action} // $h->{operation};
    return undef unless defined $raw_op && length $raw_op;

    my $op = uc($raw_op);
    $op =~ s/^\s+|\s+$//g;
    if    ($op =~ /\A(?:NONE|SKIP|IGNORE|NO_OP|NO-OP)\z/) { $op = 'NOOP' }
    elsif ($op =~ /\A(?:INSERT|CREATE|NEW)\z/)            { $op = 'ADD' }
    elsif ($op =~ /\A(?:REPLACE|DEPRECATE|OVERWRITE)\z/)  { $op = 'SUPERSEDE' }
    elsif ($op =~ /\A(?:MODIFY|EDIT|MERGE|ENRICH)\z/)     { $op = 'UPDATE' }

    my %norm = %$h;
    $norm{op}          = $op;
    $norm{target_id}   = $h->{target_id} // $h->{id} // $h->{memory_id};
    $norm{content}     = $h->{content}   // $h->{memory} // $h->{text};
    $norm{scope_level} = $h->{scope_level} // $h->{scope};
    return \%norm;
}

sub _coerce_decoded_ops {
    my ($decoded) = @_;
    my @raw_list;
    if (ref($decoded) eq 'ARRAY') {
        @raw_list = @$decoded;
    }
    elsif (ref($decoded) eq 'HASH') {
        for my $k (qw(operations ops actions memories)) {
            if (ref($decoded->{$k}) eq 'ARRAY') {
                @raw_list = @{ $decoded->{$k} };
                last;
            }
        }
        if (!@raw_list && defined($decoded->{op} // $decoded->{action} // $decoded->{operation})) {
            @raw_list = ($decoded);
        }
    }
    my @norm = grep { defined $_ } map { _normalize_op_hash($_) } @raw_list;
    return @norm ? \@norm : undef;
}

sub _parse_ops_json {
    my ($self, $raw) = @_;
    return undef unless defined $raw && length $raw;

    my $s = $raw;
    # Strip <think>...</think>, prompt-prefixed ...</think>, and unclosed trailing <think>
    $s =~ s{<think\b[^>]*>.*?</think>}{}gis;
    $s =~ s{\A.*?</think>}{}is;
    $s =~ s{<think\b[^>]*>.*\z}{}is;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return undef unless length $s;

    my @attempts;
    # Unwrap markdown code fences if present
    if ($s =~ /```(?:json)?\s*\n?(.*?)\n?\s*```/is) {
        push @attempts, $1;
    }
    (my $unwrapped = $s) =~ s/\A\s*```(?:json)?\s*//i;
    $unwrapped =~ s/\s*```\s*\z//;
    push @attempts, $unwrapped;

    for my $cand (@attempts) {
        my $decoded = eval { _decode_json($cand) };
        if (defined $decoded) {
            my $ops = _coerce_decoded_ops($decoded);
            return $ops if $ops;
        }
    }

    # Fall back to scanning for balanced JSON [...] or {...} substrings
    for my $frag (_extract_balanced_json_candidates($unwrapped)) {
        my $decoded = eval { _decode_json($frag) };
        if (defined $decoded) {
            my $ops = _coerce_decoded_ops($decoded);
            return $ops if $ops;
        }
    }

    return undef;
}

sub _heuristic_reconcile {
    my ($self, $payload) = @_;
    my $text  = $payload->{text} // '';
    my $cands = $payload->{candidates} || [];

    my $norm_new = lc($text);
    $norm_new =~ s/\s+/ /g;
    $norm_new =~ s/^\s+|\s+$//g;

    for my $c (@$cands) {
        my $norm_old = lc($c->{content} // '');
        $norm_old =~ s/\s+/ /g;
        $norm_old =~ s/^\s+|\s+$//g;

        if ($norm_new eq $norm_old) {
            return [ { op => 'NOOP', target_id => $c->{id}, reason => 'duplicate fact' } ];
        }
    }

    if (@$cands) {
        my $best = $cands->[0];
        my $sim  = $best->{cosine_score} // 0;
        if ($text =~ /\b(?:replaced|switched\s+from|instead\s+of|migrated\s+to|now\s+uses?|superseded|deprecated|changed\s+from|moved\s+from)\b/i
            && $sim >= 0.25)
        {
            return [
                {
                    op          => 'SUPERSEDE',
                    target_id   => $best->{id},
                    scope_level => $payload->{scope_level} // $best->{scope_level} // 'repo',
                    category    => $payload->{category}    // $best->{category}    // 'decision',
                    content     => $text,
                    confidence  => 0.92,
                }
            ];
        }
        if ($text =~ /\b(?:also|additionally|note\s+that|update:|clarification:|extended\s+with)\b/i
            && $sim >= 0.35)
        {
            my $combined = $best->{content};
            $combined .= '; ' . $text unless index(lc($combined), lc($text)) >= 0;
            return [
                {
                    op          => 'UPDATE',
                    target_id   => $best->{id},
                    scope_level => $best->{scope_level} // 'repo',
                    category    => $best->{category}    // 'fact',
                    content     => $combined,
                    confidence  => 0.90,
                }
            ];
        }
        if ($sim >= 0.92) {
            return [ { op => 'NOOP', target_id => $best->{id}, reason => 'semantically identical' } ];
        }
    }

    return [
        {
            op          => 'ADD',
            target_id   => undef,
            scope_level => $payload->{scope_level} // 'repo',
            category    => $payload->{category}    // 'fact',
            content     => $text,
            confidence  => 0.88,
        }
    ];
}

1;

__END__

=head1 NAME

NeoPerl::Memory::Writer - Event-driven Hy-Memory-30B-A3B memory reconciliation pipeline

=head1 SYNOPSIS

    use NeoPerl::Memory::Writer;

    my $writer = NeoPerl::Memory::Writer->new(
        store     => $store,
        inference => $inference_manager,
        repo_root => '/path/to/repo',
        repo_key  => 'my-repo',
    );
    $writer->attach_editor($editor);
    my $res = $writer->save_explicit(
        category => 'decision',
        content  => 'Switched connection pool from ad-hoc handles to DBI::MT::Pool.',
    );

=head1 DESCRIPTION

C<NeoPerl::Memory::Writer> listens for editor lifecycle events
(C<AgyTurnComplete>, C<GitCommitPost>, C<DiagnosticResolved>) and explicit
C<:MemSave> calls. It filters paths and redacts secrets through
L<NeoPerl::Memory::MemIgnore>, retrieves Top-K neighbor memories from
L<NeoPerl::Memory::Store>, invokes the C<memory_writer> role
(C<Hy-Memory-30B-A3B> at C<temperature=0.0>, C<reasoning_effort='no_think'>),
and applies C<ADD>, C<UPDATE>, C<SUPERSEDE>, or C<NOOP> transitions while
recording provenance in C<NPL_MEMORY_EVENTS>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
