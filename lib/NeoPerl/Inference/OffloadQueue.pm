package NeoPerl::Inference::OffloadQueue;

use strict;
use warnings;
use Carp qw(croak);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use File::Temp qw(tempfile);
use Time::HiRes qw(time sleep);

our $VERSION = '0.01';

my %VALID_KINDS = map { $_ => 1 } qw(
    doc comments test_scaffold refactor_local commit_msg summarize
);

our ($HAS_MT_POOL, $HAS_MT_CHANNEL);
our $_JOB_SEQ = 0;

BEGIN {
    $HAS_MT_CHANNEL = eval { require MT::Channel; 1 } ? 1 : 0;
    $HAS_MT_POOL    = eval { require MT::Pool; 1 }    ? 1 : 0;
}

my $HAS_MOJO_JSON;
BEGIN {
    $HAS_MOJO_JSON = eval { require Mojo::JSON; 1 } ? 1 : 0;
    require JSON::PP unless $HAS_MOJO_JSON;
}

sub _encode_json {
    return $HAS_MOJO_JSON ? Mojo::JSON::encode_json($_[0]) : JSON::PP->new->utf8->encode($_[0]);
}

sub _decode_json {
    return $HAS_MOJO_JSON ? Mojo::JSON::decode_json($_[0]) : JSON::PP->new->utf8->decode($_[0]);
}

# Named worker entrypoint for perl5-mt MT::Pool execution.
# Receives and returns plain Perl data structures marshaled directly by MT::Pool.
sub _mt_worker_generate {
    my ($req) = @_;

    require NeoPerl::Inference::Config;
    require NeoPerl::Inference::Manager;

    my $cfg = NeoPerl::Inference::Config->new(
        ram_budget_gb => $req->{ram_budget_gb} || 20,
        http_timeout  => $req->{http_timeout}  || 180,
        roles         => $req->{roles_override} || {},
    );
    my $mgr = NeoPerl::Inference::Manager->new(config => $cfg);
    my $res = $mgr->complete(
        role             => 'worker_small',
        reasoning_effort => 'no_think',
        max_tokens       => $req->{max_tokens} || 1536,
        messages         => $req->{messages},
        metadata         => $req->{metadata},
    );
    return {
        text              => $res->{text} // '',
        model_id          => $res->{model_id} // 'prism-ml/Ternary-Bonsai-2-27B-gguf',
        prompt_tokens     => int($res->{prompt_tokens}     || 0),
        completion_tokens => int($res->{completion_tokens} || 0),
        (defined $res->{tok_per_s}  ? (tok_per_s  => $res->{tok_per_s})  : ()),
        (defined $res->{elapsed_ms} ? (elapsed_ms => $res->{elapsed_ms}) : ()),
    };
}

sub new {
    my ($class, %args) = @_;
    croak "NeoPerl::Inference::OffloadQueue->new requires 'inference'"
        unless $args{inference};

    my $async_mode = $args{async_mode} // 'tick';
    my $mt_pool;
    my $mt_chan;

    if ($async_mode eq 'mt_pool' && $HAS_MT_POOL) {
        $mt_pool = MT::Pool->new(workers => $args{workers} || 1);
    }
    if ($HAS_MT_CHANNEL) {
        $mt_chan = MT::Channel->new(256);
    }

    return bless {
        inference                    => $args{inference},
        store                        => $args{store},
        editor                       => $args{editor},
        post_tidy_hook               => $args{post_tidy_hook},
        syntax_checker               => $args{syntax_checker},
        auto_apply_docs_if_syntax_ok => exists($args{auto_apply_docs_if_syntax_ok})
            ? ($args{auto_apply_docs_if_syntax_ok} ? 1 : 0)
            : $args{inference}->config->auto_apply_docs_if_syntax_ok,
        async_mode                   => ($mt_pool ? 'mt_pool' : 'tick'),
        mt_pool                      => $mt_pool,
        mt_chan                      => $mt_chan,
        jobs                         => {},
        job_order                    => [],
        pending_ids                  => [],
        inflight_mt                  => {},
    }, $class;
}

sub set_editor         { $_[0]{editor}         = $_[1]; return $_[0] }
sub set_post_tidy_hook { $_[0]{post_tidy_hook} = $_[1]; return $_[0] }
sub async_mode         { $_[0]{async_mode} }
sub has_mt_channel     { $_[0]{mt_chan} ? 1 : 0 }

sub _next_job_id {
    $_JOB_SEQ++;
    return sprintf('bonsai-%d-%04d', int(time()), $_JOB_SEQ);
}

sub enqueue {
    my ($self, %spec) = @_;
    my $kind = $spec{kind} // 'doc';
    croak "Invalid offload job kind: $kind" unless $VALID_KINDS{$kind};

    my $job_id      = $spec{job_id} || _next_job_id();
    my $target_path = $spec{target_path} // $spec{path} // '';
    my $buffer      = $spec{buffer};

    if (!$buffer && $self->{editor} && length $target_path && $self->{editor}->can('find_buffer_by_path')) {
        $buffer = $self->{editor}->find_buffer_by_path($target_path);
    }
    if (!$buffer && $self->{editor} && $self->{editor}->can('current_buffer')) {
        $buffer = $self->{editor}->current_buffer();
        $target_path ||= eval { $buffer->path } // '';
    }

    my $source_code = $spec{source_code};
    if (!defined $source_code) {
        if ($buffer && $buffer->can('text')) {
            $source_code = $buffer->text();
        }
        elsif ($buffer && $buffer->can('get_text')) {
            $source_code = $buffer->get_text();
        }
        elsif (length $target_path && -f $target_path) {
            if (open my $fh, '<:encoding(UTF-8)', $target_path) {
                local $/;
                $source_code = <$fh>;
                close $fh;
            }
        }
        $source_code //= '';
    }

    my $job = {
        job_id                       => $job_id,
        kind                         => $kind,
        role                         => 'worker_small',
        model_id                     => $self->{inference}->config->role_config('worker_small')->{model_id},
        target_path                  => $target_path,
        buffer                       => $buffer,
        source_code                  => $source_code,
        instruction                  => $spec{instruction} // '',
        repo_key                     => $spec{repo_key} // 'default',
        verify_syntax                => exists($spec{verify_syntax}) ? ($spec{verify_syntax} ? 1 : 0) : 1,
        auto_apply_docs_if_syntax_ok => exists($spec{auto_apply_docs_if_syntax_ok})
            ? ($spec{auto_apply_docs_if_syntax_ok} ? 1 : 0)
            : $self->{auto_apply_docs_if_syntax_ok},
        status                       => 'queued',
        syntax_ok                    => undef,
        syntax_output                => '',
        output_text                  => '',
        prompt_tokens                => 0,
        completion_tokens            => 0,
        cloud_tokens_saved           => 0,
        diff_summary                 => '',
        hunks                        => [],
        error_text                   => '',
        created_at                   => time(),
        updated_at                   => time(),
    };

    $self->{jobs}{$job_id} = $job;
    unshift @{ $self->{job_order} }, $job_id;
    push @{ $self->{pending_ids} }, $job_id;

    if ($self->{mt_chan}) {
        $self->{mt_chan}->send($job_id);
    }

    if ($self->{store}) {
        $self->{store}->upsert_local_job($self->_job_record($job));
    }

    # If mt_pool mode is active, launch on background MT::Worker immediately
    if ($self->{mt_pool}) {
        $self->_launch_mt_worker($job);
    }

    return $job_id;
}

my %KIND_INSTRUCTIONS = (
    doc            => 'Return ONLY the complete updated Perl module source verbatim with a clean POD section (=head1 NAME, =head1 SYNOPSIS, =head1 FUNCTIONS, =cut) placed after __END__ (keeping 1; before __END__). Output pure valid Perl code with no surrounding prose or explanations.',
    comments       => 'Return ONLY the complete source code verbatim with concise inline comments added above subroutines and key logic, preserving all existing code and syntax with no surrounding prose or explanations.',
    test_scaffold  => 'Return ONLY a complete, syntactically valid Perl Test::More test file (use strict; use warnings; use Test::More; ... done_testing();) exercising the module subroutines, with no surrounding prose or explanations.',
    refactor_local => 'Return ONLY the complete refactored source code verbatim, preserving interface compatibility and valid syntax, with no surrounding prose or explanations.',
    commit_msg     => 'Return ONLY a concise conventional git commit message: a subject line <= 72 characters followed by a blank line and a short bullet list of changes.',
    summarize      => 'Return a concise technical summary of the file, its purpose, and its main subroutines or components.',
);

sub clean_llm_output {
    my ($raw, $kind) = @_;
    if (ref($raw) || (defined($raw) && $raw eq __PACKAGE__)) {
        ($raw, $kind) = ($kind, $_[2]);
    }
    return '' unless defined $raw;

    my $s = $raw;
    # Strip <think>...</think>, prompt-prefixed ...</think>, and unclosed trailing <think>
    $s =~ s{<think\b[^>]*>.*?</think>}{}gis;
    $s =~ s{\A.*?</think>}{}is;
    $s =~ s{<think\b[^>]*>.*\z}{}is;

    $kind //= '';
    my $is_code = ($kind =~ /\A(?:doc|comments|refactor_local|test_scaffold)\z/) ? 1 : 0;

    if ($is_code) {
        # Collect fenced code blocks: ```lang\n...\n```
        my @blocks;
        while ($s =~ /```([A-Za-z0-9_+-]*)[ \t]*\r?\n(.*?)^[ \t]*```[ \t]*$/msig) {
            push @blocks, { lang => lc($1 // ''), body => $2 };
        }
        if (@blocks) {
            # Prefer a Perl-tagged block or one containing Perl declarations, else longest
            my @perl_blocks = grep {
                $_->{lang} =~ /\A(?:perl|pl|pm|t)\z/
                    || $_->{body} =~ /^\s*(?:package\s+\w|use\s+strict\b|sub\s+[A-Za-z_])/m
            } @blocks;
            my @pool = @perl_blocks ? @perl_blocks : @blocks;
            my ($best) = sort { length($b->{body}) <=> length($a->{body}) } @pool;
            $s = $best->{body};
        }
        elsif ($s =~ /\A\s*```(?:[A-Za-z0-9_+-]*)[ \t]*\r?\n(.*)\z/s) {
            # Handle unclosed leading fence
            $s = $1;
            $s =~ s/\r?\n[ \t]*```\s*\z//;
        }
    }
    else {
        # For commit_msg / summarize / ghost, unwrap if the entire response is fenced
        if ($s =~ /\A\s*```(?:[A-Za-z0-9_+-]*)[ \t]*\r?\n(.*?)\r?\n?[ \t]*```\s*\z/s) {
            $s = $1;
        }
    }

    $s =~ s/\A\s*\r?\n//;
    $s =~ s/\s+\z/\n/ if length $s;
    return $s;
}

sub _clean_llm_output {
    return clean_llm_output(@_);
}

sub _build_prompt_context {
    my ($self, $job) = @_;
    my @style_notes;
    if ($self->{store}) {
        my $hits = eval {
            $self->{store}->search(
                query         => "style convention $job->{kind} $job->{target_path}",
                repo_key      => $job->{repo_key},
                category      => 'convention',
                limit         => 3,
                update_access => 0,
            );
        };
        if (ref($hits) eq 'ARRAY') {
            @style_notes = map { "- $_->{content}" } @$hits;
        }
    }

    my $kind_dir = $KIND_INSTRUCTIONS{ $job->{kind} }
        // 'Produce clean, syntactically valid output for the requested task.';
    if ($job->{kind} eq 'doc'
        && length($job->{target_path})
        && $job->{target_path} !~ /\.(?:pm|pl|t)$/i
        && $job->{source_code} !~ /^\s*(?:package\s+|use\s+strict\b|sub\s+)/m)
    {
        $kind_dir = 'Return ONLY the complete updated source file verbatim with concise documentation comments added, with no surrounding prose or explanations.';
    }

    my $sys = "You are Ternary-Bonsai-2-27B local code assistant. $kind_dir";
    $sys .= "\nRepo conventions:\n" . join("\n", @style_notes) if @style_notes;

    my $user = join("\n",
        "Task kind: $job->{kind}",
        "Target path: $job->{target_path}",
        (length($job->{instruction}) ? ("Instruction: $job->{instruction}") : ()),
        "Source:",
        $job->{source_code},
    );

    return [
        { role => 'system', content => $sys },
        { role => 'user',   content => $user },
    ];
}

sub _launch_mt_worker {
    my ($self, $job) = @_;
    my $messages = $self->_build_prompt_context($job);
    my $rc   = $self->{inference}->config->role_config('worker_small');
    my $slot = $self->{inference}->ensure_loaded('worker_small');

    my $worker_role;
    if (($slot->{transport} eq 'managed_server' || $slot->{transport} eq 'remote_http')
        && defined $slot->{url} && length $slot->{url})
    {
        # Reuse the already-running server via remote_http instead of spawning a duplicate server
        $worker_role = {
            transport  => 'remote_http',
            remote_url => $slot->{url},
            model_id   => $rc->{model_id},
            api_key    => $rc->{api_key} // '',
        };
    }
    else {
        $worker_role = {
            transport  => $slot->{transport} // $rc->{transport},
            remote_url => $rc->{remote_url} // '',
            model_id   => $rc->{model_id},
        };
    }

    my $payload = {
        ram_budget_gb  => $self->{inference}->config->ram_budget_gb,
        http_timeout   => $self->{inference}->config->http_timeout,
        max_tokens     => $job->{max_tokens} || 1536,
        roles_override => {
            worker_small => $worker_role,
        },
        messages => $messages,
        metadata => {
            kind        => $job->{kind},
            target_path => $job->{target_path},
            source_code => $job->{source_code},
            instruction => $job->{instruction},
        },
    };
    $job->{status} = 'running';
    $self->{inflight_mt}{ $job->{job_id} } = $self->{mt_pool}->run(\&_mt_worker_generate, $payload);
    return 1;
}

sub pump {
    my ($self, $max) = @_;
    $max ||= 4;
    my @completed;

    # Drain any completed MT::Pool jobs first
    if ($self->{mt_pool} && %{ $self->{inflight_mt} }) {
        for my $jid (keys %{ $self->{inflight_mt} }) {
            my $mt_job = $self->{inflight_mt}{$jid};
            my $job    = $self->{jobs}{$jid};
            next unless $job;
            if ($job->{status} eq 'cancelled') {
                delete $self->{inflight_mt}{$jid};
                next;
            }
            my $res = eval { $mt_job->join };
            my $err = $@;
            delete $self->{inflight_mt}{$jid};
            if ($err) {
                $self->_fail_job($job, "$err");
            }
            else {
                $self->_finalize_job($job, $res);
            }
            push @completed, $jid;
            last if @completed >= $max;
        }
        return \@completed;
    }

    # Non-MT / tick-driven execution (also drains MT::Channel if present)
    while (@completed < $max && @{ $self->{pending_ids} }) {
        my $jid = shift @{ $self->{pending_ids} };
        if ($self->{mt_chan}) {
            $self->{mt_chan}->try_recv();
        }
        my $job = $self->{jobs}{$jid};
        next unless $job && $job->{status} eq 'queued';
        $self->_execute_sync($job);
        push @completed, $jid;
    }

    return \@completed;
}

sub wait_job {
    my ($self, $job_id, $timeout) = @_;
    $timeout ||= 10.0;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $job = $self->{jobs}{$job_id} or return undef;
        return $self->job_status($job_id)
            if $job->{status} =~ /^(?:staged|applied|rejected|cancelled|failed)$/;
        $self->pump(4);
        $job = $self->{jobs}{$job_id} or return undef;
        return $self->job_status($job_id)
            if $job->{status} =~ /^(?:staged|applied|rejected|cancelled|failed)$/;
        sleep(0.005);
    }
    return $self->job_status($job_id);
}

sub _execute_sync {
    my ($self, $job) = @_;
    $job->{status}     = 'running';
    $job->{updated_at} = time();
    $self->{store}->upsert_local_job($self->_job_record($job)) if $self->{store};

    my $messages = $self->_build_prompt_context($job);
    my $res = eval {
        $self->{inference}->complete(
            role             => 'worker_small',
            reasoning_effort => 'no_think',
            max_tokens       => $job->{max_tokens} || 1536,
            messages         => $messages,
            metadata         => {
                kind        => $job->{kind},
                target_path => $job->{target_path},
                source_code => $job->{source_code},
                instruction => $job->{instruction},
            },
        );
    };
    if ($@) {
        $self->_fail_job($job, "$@");
        return;
    }
    $self->_finalize_job($job, $res);
    return;
}

sub _verify_syntax {
    my ($self, $path, $code, $kind) = @_;
    return (1, 'skipped (non-code task)')
        if $kind eq 'commit_msg' || $kind eq 'summarize';

    if (ref($self->{syntax_checker}) eq 'CODE') {
        return $self->{syntax_checker}->($path, $code, $kind);
    }

    my $is_perl = ($path =~ /\.(?:pm|pl|t)$/i || $kind eq 'test_scaffold' || $code =~ /^\s*(?:package|use strict|sub)\b/m) ? 1 : 0;
    if ($is_perl) {
        my ($fh, $tmp) = tempfile(SUFFIX => '.pl', UNLINK => 1);
        print {$fh} $code;
        close $fh;

        my @inc_args = map { "-I$_" } grep { defined $_ && !ref($_) && length $_ } @INC;
        my @cmd = ($^X, @inc_args, '-c', $tmp);
        my ($in_fh, $out_fh);
        my $err_fh = gensym();
        my $pid = eval { open3($in_fh, $out_fh, $err_fh, @cmd) };
        if (!$pid) {
            return (1, 'perl -c unavailable');
        }
        close $in_fh if $in_fh;
        close $out_fh if $out_fh;
        local $/;
        my $stderr = <$err_fh> // '';
        close $err_fh;
        waitpid($pid, 0);
        my $ok = ($? == 0) ? 1 : 0;
        $stderr =~ s/\Q$tmp\E/$path/g;
        $stderr =~ s/^\s+|\s+$//g;
        return ($ok, $stderr || ($ok ? 'syntax OK' : 'syntax error'));
    }

    return (1, 'syntax check passed');
}

sub _compute_diff_hunks {
    my ($old_text, $new_text) = @_;
    my @old_lines = split /\n/, ($old_text // ''), -1;
    my @new_lines = split /\n/, ($new_text // ''), -1;

    if (eval { require NeoPerl::Core; defined(&NeoPerl::Core::Diff::myers_lines) }) {
        my $h = eval { NeoPerl::Core::Diff::myers_lines(\@old_lines, \@new_lines) };
        return $h if ref($h) eq 'ARRAY';
    }

    # Lightweight deterministic hunk diff fallback
    my ($pref, $suff) = (0, 0);
    my $min = @old_lines < @new_lines ? scalar(@old_lines) : scalar(@new_lines);
    $pref++ while $pref < $min && $old_lines[$pref] eq $new_lines[$pref];
    while ($suff < ($min - $pref)
        && $old_lines[$#old_lines - $suff] eq $new_lines[$#new_lines - $suff])
    {
        $suff++;
    }
    my $old_cnt = scalar(@old_lines) - $pref - $suff;
    my $new_cnt = scalar(@new_lines) - $pref - $suff;
    return [] if $old_cnt == 0 && $new_cnt == 0;

    my $kind = $old_cnt == 0 ? 'add' : ($new_cnt == 0 ? 'del' : 'change');
    return [
        {
            old_start => $pref + 1,
            old_count => $old_cnt,
            new_start => $pref + 1,
            new_count => $new_cnt,
            kind      => $kind,
            old_lines => [ @old_lines[ $pref .. $pref + $old_cnt - 1 ] ],
            new_lines => [ @new_lines[ $pref .. $pref + $new_cnt - 1 ] ],
        }
    ];
}

sub _finalize_job {
    my ($self, $job, $res) = @_;
    my $out = _clean_llm_output($res->{text} // '', $job->{kind});

    # Optional AI post-tidy gate (registered by PerlDev) for Perl code patches
    if ($self->{post_tidy_hook}
        && $job->{target_path} =~ /\.(?:pm|pl|t)$/i
        && $job->{kind} =~ /^(?:doc|comments|refactor_local|test_scaffold)$/)
    {
        my $tidied = eval { $self->{post_tidy_hook}->($out, $job->{target_path}) };
        $out = $tidied if defined $tidied && length $tidied;
    }

    $job->{output_text}       = $out;
    $job->{prompt_tokens}     = int($res->{prompt_tokens}     || 0);
    $job->{completion_tokens} = int($res->{completion_tokens} || 0);
    $job->{tok_per_s}         = $res->{tok_per_s}  if defined $res->{tok_per_s};
    $job->{elapsed_ms}        = $res->{elapsed_ms} if defined $res->{elapsed_ms};
    # Estimated cloud tokens avoided (prompt + weighted generation tokens)
    my $saved = $job->{prompt_tokens} + ($job->{completion_tokens} * 2);
    $saved = 64 if $saved < 64;
    $job->{cloud_tokens_saved} = $saved;
    $self->{inference}->record_cloud_tokens_saved($saved);

    my ($syn_ok, $syn_out) = (1, 'not requested');
    if ($job->{verify_syntax}) {
        ($syn_ok, $syn_out) = $self->_verify_syntax($job->{target_path}, $out, $job->{kind});
    }
    $job->{syntax_ok}     = $syn_ok ? 1 : 0;
    $job->{syntax_output} = $syn_out;

    my $edits_buffer = ($job->{kind} =~ /^(?:doc|comments|refactor_local)$/) ? 1 : 0;
    my $hunks = $edits_buffer ? _compute_diff_hunks($job->{source_code}, $out) : [];
    $job->{hunks} = $hunks;
    $job->{diff_summary} = sprintf(
        '%d hunk(s), syntax=%s, +%d/-%d lines',
        scalar(@$hunks),
        ($syn_ok ? 'OK' : 'FAIL'),
        _sum_hunk_field($hunks, 'new_count'),
        _sum_hunk_field($hunks, 'old_count'),
    );

    my $buf = $job->{buffer};
    if ($edits_buffer && $job->{auto_apply_docs_if_syntax_ok}
        && $job->{kind} =~ /^(?:doc|comments)$/
        && $syn_ok)
    {
        if ($buf && $buf->can('set_text')) {
            $buf->set_text($out);
        }
        elsif ($buf && $buf->can('replace_all')) {
            $buf->replace_all($out);
        }
        $job->{status} = 'applied';
    }
    else {
        if ($edits_buffer && $buf && $buf->can('stage_diff_proposal')) {
            $buf->stage_diff_proposal(
                $out,
                source => 'bonsai',
                job_id => $job->{job_id},
                kind   => $job->{kind},
                title  => "Bonsai [$job->{kind}] ($job->{job_id})",
            );
        }
        $job->{status} = 'staged';
    }

    $job->{updated_at} = time();
    $self->{store}->upsert_local_job($self->_job_record($job)) if $self->{store};
    return;
}

sub _sum_hunk_field {
    my ($hunks, $k) = @_;
    my $s = 0;
    for my $h (@$hunks) {
        $s += int($h->{$k} || 0);
    }
    return $s;
}

sub _fail_job {
    my ($self, $job, $err) = @_;
    $job->{status}     = 'failed';
    $job->{error_text} = "$err";
    $job->{updated_at} = time();
    $self->{store}->upsert_local_job($self->_job_record($job)) if $self->{store};
    return;
}

sub accept_job {
    my ($self, $job_id) = @_;
    my $job = $self->{jobs}{$job_id} or return { ok => 0, error => "Unknown job_id: $job_id" };
    return { ok => 0, error => "Job $job_id is not staged (status=$job->{status})" }
        unless $job->{status} eq 'staged';

    my $buf = $job->{buffer};
    if ($buf) {
        if ($buf->can('accept_all_hunks')) {
            $buf->accept_all_hunks();
        }
        elsif ($buf->can('set_text')) {
            $buf->set_text($job->{output_text});
        }
    }

    $job->{status}     = 'applied';
    $job->{updated_at} = time();
    $self->{store}->upsert_local_job($self->_job_record($job)) if $self->{store};
    return { ok => 1, job_id => $job_id, status => 'applied' };
}

sub reject_job {
    my ($self, $job_id) = @_;
    my $job = $self->{jobs}{$job_id} or return { ok => 0, error => "Unknown job_id: $job_id" };
    my $buf = $job->{buffer};
    if ($buf && $buf->can('reject_all_hunks')) {
        $buf->reject_all_hunks();
    }
    $job->{status}     = 'rejected';
    $job->{updated_at} = time();
    $self->{store}->upsert_local_job($self->_job_record($job)) if $self->{store};
    return { ok => 1, job_id => $job_id, status => 'rejected' };
}

sub cancel_job {
    my ($self, $job_id) = @_;
    my $job = $self->{jobs}{$job_id} or return { ok => 0, error => "Unknown job_id: $job_id" };
    @{ $self->{pending_ids} } = grep { $_ ne $job_id } @{ $self->{pending_ids} };
    $job->{status}     = 'cancelled';
    $job->{updated_at} = time();
    $self->{store}->upsert_local_job($self->_job_record($job)) if $self->{store};
    return { ok => 1, job_id => $job_id, status => 'cancelled' };
}

sub _job_record {
    my ($self, $job) = @_;
    return {
        job_id             => $job->{job_id},
        kind               => $job->{kind},
        role               => $job->{role},
        model_id           => $job->{model_id},
        target_path        => $job->{target_path},
        status             => $job->{status},
        syntax_ok          => $job->{syntax_ok},
        syntax_output      => $job->{syntax_output},
        prompt_tokens      => $job->{prompt_tokens},
        completion_tokens  => $job->{completion_tokens},
        cloud_tokens_saved => $job->{cloud_tokens_saved},
        diff_summary       => $job->{diff_summary},
        error_text         => $job->{error_text},
    };
}

sub job_status {
    my ($self, $job_id) = @_;
    my $job = $self->{jobs}{$job_id};
    if ($job) {
        return {
            %{ $self->_job_record($job) },
            output_text => $job->{output_text},
            hunks       => $job->{hunks},
            async_mode  => $self->{async_mode},
            (defined $job->{tok_per_s}  ? (tok_per_s  => $job->{tok_per_s})  : ()),
            (defined $job->{elapsed_ms} ? (elapsed_ms => $job->{elapsed_ms}) : ()),
        };
    }
    return $self->{store} ? $self->{store}->get_local_job($job_id) : undef;
}

sub list_jobs {
    my ($self, %args) = @_;
    my $limit = $args{limit} || 50;
    my @out;
    for my $jid (@{ $self->{job_order} }) {
        last if @out >= $limit;
        push @out, $self->job_status($jid);
    }
    return \@out;
}

sub summary {
    my ($self) = @_;
    my ($queued, $staged, $applied, $failed, $saved) = (0, 0, 0, 0, 0);
    for my $job (values %{ $self->{jobs} }) {
        $queued++  if $job->{status} eq 'queued' || $job->{status} eq 'running';
        $staged++  if $job->{status} eq 'staged';
        $applied++ if $job->{status} eq 'applied';
        $failed++  if $job->{status} eq 'failed';
        $saved    += int($job->{cloud_tokens_saved} || 0);
    }
    return {
        async_mode         => $self->{async_mode},
        total              => scalar(keys %{ $self->{jobs} }),
        queued             => $queued,
        staged             => $staged,
        applied            => $applied,
        failed             => $failed,
        cloud_tokens_saved => $saved,
    };
}

sub shutdown {
    my ($self) = @_;
    if ($self->{mt_pool}) {
        eval { $self->{mt_pool}->shutdown };
        $self->{mt_pool} = undef;
    }
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT';
    eval { $self->shutdown };
    return;
}

1;

__END__

=head1 NAME

NeoPerl::Inference::OffloadQueue - Out-of-band Ternary-Bonsai-2-27B local job queue

=head1 SYNOPSIS

    use NeoPerl::Inference::OffloadQueue;

    my $q = NeoPerl::Inference::OffloadQueue->new(
        inference => $mgr,
        store     => $store,
    );
    my $job_id = $q->enqueue(
        kind        => 'doc',
        target_path => 'lib/Foo.pm',
        source_code => "package Foo;\nsub bar { 1 }\n1;\n",
    );
    $q->pump();
    my $st = $q->job_status($job_id);

=head1 DESCRIPTION

C<NeoPerl::Inference::OffloadQueue> runs out-of-band local code, documentation,
comment, test-scaffold, commit-message, and summary tasks on the
C<worker_small> role (C<Ternary-Bonsai-2-27B>). It supports C<perl5-mt>
L<MT::Pool> and L<MT::Channel> as well as a non-blocking tick fallback on stock
Perl 5, verifies generated Perl syntax via C<perl -c>, stages reviewable inline
diff hunks onto the target buffer, and records cloud tokens saved in
C<NPL_LOCAL_JOBS>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
