package NeoPerl::Antigravity::Modalities;

use strict;
use warnings;
use Carp qw(croak);
use File::Basename qw(basename);
use Time::HiRes qw(time);

our $VERSION = '0.01';

our $AUTO_CONTEXT_MAX_TOKENS = 250;
our $AUTO_CONTEXT_MAX_CHARS  = 1000;    # ~250 tokens at 4 chars/token

sub new {
    my ($class, %args) = @_;
    return bless {
        editor                => $args{editor},
        acp                   => $args{acp},
        editor_mcp            => $args{editor_mcp},
        mcp_registry          => $args{mcp_registry},
        telescope             => $args{telescope},
        memory_store          => $args{memory_store},
        memory_writer         => $args{memory_writer},
        inference             => $args{inference},
        vision                => $args{vision},
        offload_queue         => $args{offload_queue},
        model_hub             => $args{model_hub},
        customizations        => $args{customizations},
        perl_slice_hook       => $args{perl_slice_hook},
        auto_context          => $args{auto_context} ? 1 : 0,
        repo_key              => $args{repo_key} // 'default',
        chat_messages         => [],
        thought_cards         => [],
        tool_cards            => [],
        plan_entries          => [],
        active_perm           => undef,
        available_commands    => [],
        current_mode          => undef,
        chat_input            => '',
        chat_input_active     => 0,
        queued_prompts        => [],
        pending_term_watchers => [],
        inline_prompt         => { active => 0, text => '', line => 1 },
        ghost_state           => { active => 0, buf_id => undef, line => 0, col => 0, text => '', extmark_id => undef },
        attached              => 0,
    }, $class;
}

sub auto_context {
    my ($self, $val) = @_;
    if (defined $val) {
        $self->{auto_context} = $val ? 1 : 0;
    }
    return $self->{auto_context};
}

sub set_perl_slice_hook  { $_[0]{perl_slice_hook} = $_[1]; return $_[0] }
sub focus_chat_input     { my ($s, $v) = @_; $s->{chat_input_active} = (defined $v ? ($v ? 1 : 0) : 1); return $s->{chat_input_active} }
sub is_chat_input_active { $_[0]{chat_input_active} ? 1 : 0 }
sub chat_input           { $_[0]{chat_input} }

# --- Status Pill & Command Center UI State Accessors (consumed by UI::GPU and UI::TUI) ---

sub acp_status_pill {
    my ($self) = @_;
    my $acp = $self->{acp};
    if (!$acp) {
        my $bin = eval { NeoPerl::Antigravity::ACP::discover_agy_binary() };
        return defined($bin)
            ? { label => 'AGY:OFF',   state => 'offline', kind => 'off' }
            : { label => 'AGY:SETUP', state => 'offline', kind => 'setup' };
    }
    if ($acp->can('is_disabled') && $acp->is_disabled) {
        return { label => 'AGY:OFF', state => 'offline', kind => 'off' };
    }

    my $st = $acp->can('state') ? ($acp->state // 'offline') : ($acp->is_initialized ? 'ready' : 'offline');
    if ($st eq 'ready') {
        return ($acp->can('is_mock') && $acp->is_mock)
            ? { label => 'AGY:MOCK', state => 'ready', kind => 'mock' }
            : { label => 'AGY:LIVE', state => 'ready', kind => 'live' };
    }
    if ($st eq 'connecting') {
        return { label => 'AGY:SYNC', state => 'connecting', kind => 'sync' };
    }
    if ($st eq 'auth_required') {
        return { label => 'AGY:LOGIN', state => 'auth_required', kind => 'login' };
    }
    if ($st eq 'error') {
        return { label => 'AGY:OFF', state => 'error', kind => 'error' };
    }

    my $bin = ($acp->can('agy_bin') ? $acp->agy_bin : undef)
           || eval { NeoPerl::Antigravity::ACP::discover_agy_binary() };
    return defined($bin)
        ? { label => 'AGY:OFF',   state => 'offline', kind => 'off' }
        : { label => 'AGY:SETUP', state => 'offline', kind => 'setup' };
}

sub chat_state {
    my ($self) = @_;
    my $acp  = $self->{acp};
    my $st   = $acp && $acp->can('state') ? ($acp->state // 'offline') : 'offline';
    my $pill = $self->acp_status_pill();
    my $connected = ($acp && ($st eq 'ready' || ($acp->is_initialized && $st ne 'auth_required' && $st ne 'error'))) ? 1 : 0;

    return {
        messages           => [ @{ $self->{chat_messages} } ],
        thoughts           => [ @{ $self->{thought_cards} } ],
        tool_cards         => [ @{ $self->{tool_cards} } ],
        plan               => [ @{ $self->{plan_entries} } ],
        pending_perm       => $self->{active_perm},
        auto_context       => $self->{auto_context},
        acp_connected      => $connected,
        acp_state          => $st,
        acp_mock           => ($acp && $acp->can('is_mock') && $acp->is_mock) ? 1 : 0,
        acp_pill           => $pill,
        acp_binary         => ($acp && $acp->can('agy_bin') ? $acp->agy_bin : undef) || eval { NeoPerl::Antigravity::ACP::discover_agy_binary() },
        acp_error          => ($acp && $acp->can('last_error')) ? $acp->last_error : undef,
        acp_stderr_tail    => ($acp && $acp->can('stderr_lines')) ? $acp->stderr_lines : [],
        current_model      => ($acp && $acp->can('current_model')) ? $acp->current_model : undef,
        available_models   => ($acp && $acp->can('available_models')) ? $acp->available_models : [],
        session_id         => ($acp && $acp->can('session_id')) ? $acp->session_id : undef,
        available_commands => [ @{ $self->{available_commands} } ],
        current_mode       => $self->{current_mode} // (($acp && $acp->can('current_mode')) ? $acp->current_mode : undef),
        chat_input         => $self->{chat_input},
        chat_input_active  => $self->{chat_input_active} ? 1 : 0,
        mcp_port           => $self->{editor_mcp} ? $self->{editor_mcp}->port : undef,
        mcp_tools          => $self->{editor_mcp} ? scalar(@{ $self->{editor_mcp}->list_tool_names }) : 0,
    };
}

sub inline_state { +{ %{ $_[0]{inline_prompt} } } }
sub ghost_state  { +{ %{ $_[0]{ghost_state} } } }

# --- Compact <=250-Token Auto-Context Memory Hint ---

sub build_auto_context_hint {
    my ($self, %opts) = @_;
    return '' unless $self->{auto_context} && $self->{memory_store};

    my $ed   = $self->{editor};
    my $buf  = $opts{buffer} || ($ed && $ed->can('current_buffer') ? $ed->current_buffer() : undef);
    my $path = $opts{file_path} // ($buf ? eval { $buf->path } : undef);
    my $q    = $opts{query} // join(' ', grep { defined $_ && length $_ } (
        $path ? basename($path) : '',
        $buf ? eval { $buf->filetype } : '',
        'architecture gotcha convention decision',
    ));

    my $hits = eval {
        $self->{memory_store}->search(
            query         => $q,
            repo_key      => $opts{repo_key} // $self->{repo_key},
            file_path     => $path,
            limit         => 4,
            update_access => 0,
        );
    };
    return '' unless ref($hits) eq 'ARRAY' && @$hits;

    my @lines = ('[Memory Context Hint]');
    my $chars = length($lines[0]);
    for my $m (@$hits) {
        my $entry = sprintf('- (%s/%s) %s', $m->{scope_level}, $m->{category}, $m->{content});
        if ($chars + length($entry) + 1 > $AUTO_CONTEXT_MAX_CHARS) {
            my $rem = $AUTO_CONTEXT_MAX_CHARS - $chars - 4;
            if ($rem > 24) {
                push @lines, substr($entry, 0, $rem) . '...';
            }
            last;
        }
        push @lines, $entry;
        $chars += length($entry) + 1;
    }
    return join("\n", @lines);
}

# --- @ Mention & / Slash Command Expansion ---

sub _buf_text {
    my ($buf) = @_;
    return '' unless $buf;
    return $buf->get_text() if $buf->can('get_text');
    return $buf->text()     if $buf->can('text');
    return '';
}

sub _buf_is_zero_based {
    my ($buf) = @_;
    return ($buf && $buf->isa('NeoPerl::Buffer')) ? 1 : 0;
}

sub _editor_cursor_line1 {
    my ($ed) = @_;
    return 1 unless $ed;
    if ($ed->can('current_window')) {
        my $win = $ed->current_window;
        return ($win->cursor_line // 0) + 1 if $win && $win->can('cursor_line');
    }
    return ($ed->cursor()->{line} || 1) if $ed->can('cursor');
    return 1;
}

sub _notify {
    my ($self, $msg, $level) = @_;
    my $ed = $self->{editor};
    if ($ed && $ed->can('notify')) {
        $ed->notify($msg, $level || 'info');
    }
    return;
}

sub _active_mcp_packs {
    my ($self) = @_;
    my $reg = $self->{mcp_registry};
    if (!$reg && $self->{editor} && $self->{editor}->can('plugin')) {
        $reg = $self->{editor}->plugin('mcp_registry');
    }
    return [] unless $reg && $reg->can('active_packs');
    my $list = eval { $reg->active_packs };
    return ref($list) eq 'ARRAY' ? $list : [];
}

sub expand_prompt {
    my ($self, $raw_prompt, %opts) = @_;
    my $prompt = $raw_prompt // '';
    my @attachments;
    my $slash_cmd;

    # Slash commands at start of prompt
    if ($prompt =~ s{\A/(plan|fix|test|doc|remember|compact|clear)\b\s*}{}i) {
        $slash_cmd = lc($1);
        if ($slash_cmd eq 'clear') {
            $self->{chat_messages} = [];
            $self->{thought_cards} = [];
            $self->{tool_cards}    = [];
            $self->{plan_entries}  = [];
            return { prompt => '', slash => 'clear', attachments => [] };
        }
        elsif ($slash_cmd eq 'remember' && length $prompt && $self->{memory_writer}) {
            my $res = $self->{memory_writer}->save_explicit(
                repo_key => $self->{repo_key},
                content  => $prompt,
                category => 'fact',
            );
            return { prompt => $prompt, slash => 'remember', memory_result => $res, attachments => [] };
        }
        elsif ($slash_cmd eq 'plan') {
            $prompt = "Produce a concise step-by-step plan before making edits: $prompt";
        }
        elsif ($slash_cmd eq 'fix') {
            $prompt = "Diagnose and propose a minimal diff fix for: $prompt";
        }
        elsif ($slash_cmd eq 'test') {
            $prompt = "Generate focused unit tests covering: $prompt";
        }
        elsif ($slash_cmd eq 'doc') {
            $prompt = "Write clear, concise documentation for: $prompt";
        }
    }

    my $ed  = $self->{editor};
    my $buf = $opts{buffer} || ($ed && $ed->can('current_buffer') ? $ed->current_buffer() : undef);

    # @buffer mention
    if ($prompt =~ /\@buffer\b/ && $buf) {
        my $bpath = eval { $buf->path } // '<unnamed>';
        my $btext = _buf_text($buf);
        push @attachments, { kind => 'buffer', path => $bpath, content => substr($btext, 0, 4000) };
    }

    # @selection mention
    if ($prompt =~ /\@selection\b/ && defined $opts{selection}) {
        push @attachments, { kind => 'selection', content => $opts{selection} };
    }

    # @diag mention
    if ($prompt =~ /\@diag\b/ && $ed) {
        my $diags = $ed->can('get_diagnostics') ? $ed->get_diagnostics()
                  : $ed->can('all_diagnostics') ? $ed->all_diagnostics()
                  : [];
        my $txt = join("\n", map { sprintf('%s:%d [%s] %s', $_->{path} // '', $_->{line} // 0, $_->{severity} // 'W', $_->{message} // '') } @$diags);
        push @attachments, { kind => 'diag', content => $txt };
    }

    # @file:<path> mention
    while ($prompt =~ /\@file:([^\s]+)/g) {
        my $fpath = $1;
        my $content = '';
        if (-f $fpath && open my $fh, '<:encoding(UTF-8)', $fpath) {
            local $/;
            $content = substr(<$fh> // '', 0, 4000);
            close $fh;
        }
        push @attachments, { kind => 'file', path => $fpath, content => $content };
    }

    # @memory:<query> mention
    while ($prompt =~ /\@memory:([^\s]+)/g) {
        my $mq = $1;
        $mq =~ tr/_/ /;
        if ($self->{memory_store}) {
            my $hits = $self->{memory_store}->search(query => $mq, repo_key => $self->{repo_key}, limit => 4);
            my $txt = join("\n", map { "- [$_->{category}] $_->{content}" } @$hits);
            push @attachments, { kind => 'memory', query => $mq, content => $txt };
        }
    }

    # @image:<path> and @pdf:<path> mentions -> local Granite-Vision preprocessing
    while ($prompt =~ /\@(image|pdf):([^\s]+)/g) {
        my ($kind, $dpath) = ($1, $2);
        if ($self->{vision} && -f $dpath) {
            my $doc = eval { $self->{vision}->preprocess_file(path => $dpath, format => 'markdown') };
            if ($doc) {
                push @attachments, {
                    kind    => $kind,
                    path    => $dpath,
                    doc_id  => $doc->{doc_id},
                    cached  => $doc->{cached},
                    content => $doc->{content},
                };
            }
        }
    }

    # @skill:<name> mention -> Customizations lookup
    while ($prompt =~ /\@skill:([^\s]+)/g) {
        my $sname = $1;
        if ($self->{customizations}) {
            my $sk = $self->{customizations}->find_skill($sname);
            if ($sk) {
                push @attachments, { kind => 'skill', name => $sname, path => $sk->{path}, content => $sk->{body} };
            }
        }
    }

    my @parts;
    if ($self->{auto_context}) {
        my $hint = $self->build_auto_context_hint(query => $prompt, buffer => $buf);
        push @parts, $hint if length $hint;
    }
    for my $att (@attachments) {
        next unless defined $att->{content} && length $att->{content};
        push @parts, "[$att->{kind}] " . ($att->{path} // $att->{name} // $att->{query} // '') . "\n" . $att->{content};
    }
    push @parts, $prompt;

    return {
        prompt      => join("\n\n", @parts),
        raw_prompt  => $raw_prompt,
        slash       => $slash_cmd,
        attachments => \@attachments,
    };
}

# --- Modality 1: Sidebar Agent Chat & Interactive ACP Lifecycle ---

sub wire_acp_callbacks {
    my ($self, %opts) = @_;
    my $acp = $self->{acp} or return 0;
    return 1 if $self->{_acp_wired} && !$opts{force};
    $self->{_acp_wired} = 1;

    $acp->set_callback('on_update', sub {
        my ($params) = @_;
        my $upd  = (ref($params->{update}) eq 'HASH') ? $params->{update} : $params;
        my $kind = $upd->{sessionUpdate} // $params->{sessionUpdate} // '';
        my $txt  = (ref($upd->{content}) eq 'HASH' && defined $upd->{content}{text})
            ? $upd->{content}{text}
            : ($upd->{text} // $params->{text} // '');

        if ($kind eq 'agent_thought_chunk') {
            if (@{ $self->{thought_cards} } && $self->{thought_cards}[-1]{streaming}) {
                $self->{thought_cards}[-1]{text} .= $txt;
            }
            else {
                push @{ $self->{thought_cards} }, { text => $txt, collapsed => 1, streaming => 1 };
            }
        }
        elsif ($kind eq 'plan' && ref($upd->{entries}) eq 'ARRAY') {
            $self->{plan_entries} = [ @{ $upd->{entries} } ];
        }
        elsif ($kind eq 'tool_call') {
            push @{ $self->{tool_cards} }, {
                id     => $upd->{toolCallId} // '',
                title  => $upd->{title}      // 'tool',
                status => $upd->{status}     // 'running',
            };
        }
        elsif ($kind eq 'tool_call_update') {
            my $tcid = $upd->{toolCallId} // '';
            for my $card (@{ $self->{tool_cards} }) {
                if ($card->{id} eq $tcid) {
                    $card->{status} = $upd->{status} if defined $upd->{status};
                    $card->{title}  = $upd->{title}  if defined $upd->{title};
                }
            }
        }
        elsif ($kind eq 'agent_message_chunk') {
            if (@{ $self->{chat_messages} } && $self->{chat_messages}[-1]{role} eq 'assistant' && $self->{chat_messages}[-1]{streaming}) {
                $self->{chat_messages}[-1]{text} .= $txt;
            }
            else {
                push @{ $self->{chat_messages} }, { role => 'assistant', text => $txt, streaming => 1 };
            }
        }
        elsif ($kind eq 'available_commands_update' && ref($upd->{availableCommands}) eq 'ARRAY') {
            $self->{available_commands} = [ @{ $upd->{availableCommands} } ];
        }
        elsif ($kind eq 'current_mode_update' && defined $upd->{currentModeId}) {
            $self->{current_mode} = $upd->{currentModeId};
        }
    });

    $acp->set_callback('on_permission', sub {
        my ($perm) = @_;
        $self->{active_perm} = $perm;
    });

    $acp->set_callback('on_turn_complete', sub {
        if (@{ $self->{chat_messages} } && $self->{chat_messages}[-1]{role} eq 'assistant') {
            $self->{chat_messages}[-1]{streaming} = 0;
        }
        if (@{ $self->{thought_cards} }) {
            $self->{thought_cards}[-1]{streaming} = 0;
        }
    });

    $acp->set_callback('on_state_change', sub {
        my ($new_state, $old_state, $err_msg) = @_;
        if ($new_state eq 'ready') {
            $self->_flush_queued_prompts();
        }
        elsif ($new_state eq 'auth_required') {
            $self->_notify('Antigravity sign-in required — run :AgyLogin or <leader>aL', 'warn');
        }
    });

    return 1;
}

sub _flush_queued_prompts {
    my ($self) = @_;
    my $acp = $self->{acp} or return 0;
    return 0 unless $acp->is_running && defined $acp->session_id;
    my $sent = 0;
    while (@{ $self->{queued_prompts} }) {
        my $item = shift @{ $self->{queued_prompts} };
        if (ref($item) eq 'HASH') {
            eval {
                $acp->prompt(
                    $item->{prompt},
                    async => 1,
                    (defined $item->{raw_prompt} && length $item->{raw_prompt} ? (raw_prompt => $item->{raw_prompt}) : ()),
                    (defined $item->{file_path}  && length $item->{file_path}  ? (file_path  => $item->{file_path})  : ()),
                );
            };
        }
        else {
            eval { $acp->prompt($item, async => 1) };
        }
        $sent++;
    }
    return $sent;
}

sub _wait_acp_connecting {
    my ($self, $timeout_s) = @_;
    my $acp = $self->{acp} or return;
    $timeout_s ||= 10.0;
    my $deadline = time() + $timeout_s;
    while ($acp->is_running && $acp->state eq 'connecting' && time() < $deadline) {
        if ($self->{editor_mcp} && $self->{editor_mcp}->is_running) {
            $self->{editor_mcp}->poll(0);
        }
        $acp->poll(0.02);
        if ($acp->is_running && $acp->state eq 'connecting'
            && $self->{editor_mcp} && $self->{editor_mcp}->is_running)
        {
            $self->{editor_mcp}->poll(0);
        }
    }
    return $acp->state;
}

sub send_chat {
    my ($self, $raw_prompt, %opts) = @_;
    my $expanded = $self->expand_prompt($raw_prompt, %opts);
    return $expanded if ($expanded->{slash} // '') eq 'clear' || ($expanded->{slash} // '') eq 'remember';

    my $ed        = $self->{editor};
    my $buf       = $opts{buffer} || ($ed && $ed->can('current_buffer') ? $ed->current_buffer() : undef);
    my $file_path = $opts{file_path} // ($buf ? eval { $buf->path } : undef);
    $file_path    = undef unless defined $file_path && length $file_path;

    push @{ $self->{chat_messages} }, {
        role        => 'user',
        text        => $raw_prompt,
        attachments => $expanded->{attachments},
    };

    my $acp = $self->{acp};
    if ($acp) {
        $self->wire_acp_callbacks();

        if ($acp->state eq 'auth_required') {
            my $msg = 'Antigravity sign-in required. Run :AgyLogin or <leader>aL to sign in.';
            push @{ $self->{chat_messages} }, { role => 'assistant', text => $msg, streaming => 0 };
            return { ok => 0, auth_required => 1, state => 'auth_required', reply => $msg, chat_state => $self->chat_state() };
        }

        if (!$acp->is_running) {
            my $can_live = $acp->is_mock || defined($acp->agy_bin) || defined(NeoPerl::Antigravity::ACP::discover_agy_binary());
            if ($can_live) {
                my $cwd = $self->{editor} && $self->{editor}->can('cwd') ? $self->{editor}->cwd : undef;
                if ($opts{async}) {
                    push @{ $self->{queued_prompts} }, {
                        prompt     => $expanded->{prompt},
                        raw_prompt => $raw_prompt,
                        file_path  => $file_path,
                    };
                    $acp->connect_async(defined $cwd ? (cwd => $cwd) : ());
                    return {
                        ok         => 1,
                        queued     => 1,
                        connecting => 1,
                        expanded   => $expanded,
                        chat_state => $self->chat_state(),
                    };
                }
                else {
                    $acp->connect_async(defined $cwd ? (cwd => $cwd) : ());
                    $self->_wait_acp_connecting($opts{timeout} || 10);
                }
            }
        }
        elsif ($acp->state eq 'connecting') {
            if ($opts{async}) {
                push @{ $self->{queued_prompts} }, {
                    prompt     => $expanded->{prompt},
                    raw_prompt => $raw_prompt,
                    file_path  => $file_path,
                };
                return {
                    ok         => 1,
                    queued     => 1,
                    connecting => 1,
                    expanded   => $expanded,
                    chat_state => $self->chat_state(),
                };
            }
            $self->_wait_acp_connecting($opts{timeout} || 10);
        }

        if ($acp->state eq 'auth_required') {
            my $msg = 'Antigravity sign-in required. Run :AgyLogin or <leader>aL to sign in.';
            push @{ $self->{chat_messages} }, { role => 'assistant', text => $msg, streaming => 0 };
            return { ok => 0, auth_required => 1, state => 'auth_required', reply => $msg, chat_state => $self->chat_state() };
        }

        if ($acp->is_running) {
            my $ok_prep = eval {
                $acp->initialize()  unless $acp->is_initialized;
                $acp->new_session() unless defined $acp->session_id;
                1;
            };
            if (!$ok_prep) {
                my $err = $@ || 'ACP session initialization failed';
                chomp $err;
                my $is_auth = ($acp->state eq 'auth_required') ? 1 : 0;
                my $msg = $is_auth
                    ? 'Antigravity sign-in required. Run :AgyLogin or <leader>aL to sign in.'
                    : "ACP error: $err";
                push @{ $self->{chat_messages} }, { role => 'assistant', text => $msg, streaming => 0 };
                return {
                    ok            => 0,
                    auth_required => $is_auth,
                    error         => $err,
                    reply         => $msg,
                    chat_state    => $self->chat_state(),
                };
            }

            my $res = $acp->prompt(
                $expanded->{prompt},
                async      => $opts{async} ? 1 : 0,
                raw_prompt => $raw_prompt,
                (defined $file_path     ? (file_path => $file_path)     : ()),
                (defined $opts{timeout} ? (timeout   => $opts{timeout}) : ()),
            );
            return {
                ok         => 1,
                expanded   => $expanded,
                acp_result => $res,
                chat_state => $self->chat_state(),
            };
        }
    }

    # Offline local fallback reply when ACP is not started and agy is unavailable
    my $reply = "ACP offline. " . NeoPerl::Antigravity::ACP::install_instructions();
    push @{ $self->{chat_messages} }, { role => 'assistant', text => $reply, streaming => 0 };
    return { ok => 1, offline => 1, expanded => $expanded, reply => $reply };
}

sub handle_chat_input_key {
    my ($self, $key) = @_;
    return 0 unless defined $key && length $key;

    if ($key eq '<Esc>') {
        $self->{chat_input_active} = 0;
        return 1;
    }
    if ($key eq '<CR>') {
        my $prompt = $self->{chat_input} // '';
        $prompt =~ s/\A\s+|\s+\z//g;
        $self->{chat_input} = '';
        if (length $prompt) {
            $self->send_chat($prompt, async => 1);
        }
        return 1;
    }
    if ($key eq '<BS>') {
        chop($self->{chat_input}) if length($self->{chat_input});
        return 1;
    }
    if (length($key) == 1 && ord($key) >= 32 && ord($key) != 127) {
        $self->{chat_input} .= $key;
        return 1;
    }
    return 0;
}

sub handle_permission_key {
    my ($self, $key) = @_;
    my $perm = $self->{active_perm} or return 0;
    my $decision = ($key eq 'a') ? 'allow'
                 : ($key eq 'A') ? 'allow_always'
                 : 'reject';
    $self->{active_perm} = undef;
    return $self->{acp} ? $self->{acp}->respond_permission($perm->{id}, $decision) : 0;
}

# --- Antigravity ACP Lifecycle Operations (:AgyDoctor/:AgyLogin/:AgyInstall/:AgyModel/...) ---

sub _open_action_terminal {
    my ($self, $kind, $cmd, $argv) = @_;
    my $ed = $self->{editor};
    return undef unless $ed && $ed->can('create_buffer');

    my $label = ref($argv) eq 'ARRAY' && @$argv ? join(' ', $cmd, @$argv) : $cmd;
    my $buf = $ed->create_buffer(
        name     => "term://$label",
        buftype  => 'terminal',
        filetype => 'sh',
    );
    my $ok = $buf->spawn_terminal($cmd, 80, 20, $argv);
    return undef unless $ok;

    if ($ed->can('layout') && $ed->layout && $ed->layout->can('hsplit')) {
        $ed->layout->hsplit($buf->id);
    }
    elsif ($ed->can('switch_buffer')) {
        $ed->switch_buffer($buf->id);
    }
    if ($ed->can('modal') && $ed->modal && $ed->modal->can('set_mode')) {
        $ed->modal->set_mode($ed, 'TERMINAL');
    }

    push @{ $self->{pending_term_watchers} }, {
        buf  => $buf,
        kind => $kind,
    };
    return $buf;
}

sub agy_doctor {
    my ($self, %opts) = @_;
    my $acp   = $self->{acp};
    my $pill  = $self->acp_status_pill();
    my $packs = $self->_active_mcp_packs();

    my $doc = $acp
        ? $acp->doctor()
        : {
            binary           => NeoPerl::Antigravity::ACP::discover_agy_binary(),
            state            => 'offline',
            mock             => 0,
            session_id       => undef,
            current_model    => undef,
            available_models => [],
            auth_methods     => [],
            mcp_url          => ($self->{editor_mcp} ? eval { $self->{editor_mcp}->url } : undef),
            mcp_tools        => ($self->{editor_mcp} ? scalar(@{ $self->{editor_mcp}->list_tool_names }) : 0),
            stderr_tail      => [],
            next_action      => NeoPerl::Antigravity::ACP::install_instructions(),
        };

    $doc->{mounted_packs} = $packs;
    $doc->{pill}          = $pill->{label};
    $doc->{signed_in}     = ($doc->{state} eq 'ready' && !$doc->{mock}) ? 1 : 0;

    my $signed_lbl = $doc->{mock} ? 'mock (loopback)' : ($doc->{signed_in} ? 'yes' : 'no');
    my $models_lbl = @{ $doc->{available_models} || [] }
        ? join(', ', map { $_->{modelId} // $_->{name} // '' } @{ $doc->{available_models} })
        : '<none>';
    my $packs_lbl  = @$packs ? join(', ', @$packs) : 'none (core tools only)';

    my @lines = (
        'Antigravity ACP Doctor',
        sprintf('  Status:    %s (state=%s, signed_in=%s)', $pill->{label}, $doc->{state}, $signed_lbl),
        sprintf('  Binary:    %s', $doc->{binary} // '<not found>'),
        sprintf('  Session:   %s', $doc->{session_id} // '<none>'),
        sprintf('  Model:     %s (available: %s)', $doc->{current_model} // '<default>', $models_lbl),
        sprintf('  EditorMCP: %s (%d tools)', $doc->{mcp_url} // '<stopped>', $doc->{mcp_tools} || 0),
        sprintf('  MCP Packs: %s', $packs_lbl),
        sprintf('  Next Step: %s', $doc->{next_action} // ''),
    );
    if (@{ $doc->{stderr_tail} || [] }) {
        my @tail = @{ $doc->{stderr_tail} };
        @tail = @tail[-5 .. -1] if @tail > 5;
        push @lines, '  Stderr Tail:';
        push @lines, map { "    $_" } @tail;
    }

    my $report  = join("\n", @lines);
    my $summary = sprintf('%s | bin=%s | model=%s | MCP=%d tools | %s',
        $pill->{label},
        $doc->{binary} ? basename($doc->{binary}) : 'missing',
        $doc->{current_model} // 'default',
        $doc->{mcp_tools} || 0,
        $doc->{next_action} // '');

    $self->_notify($summary, ($doc->{state} eq 'error' || $doc->{state} eq 'auth_required') ? 'warn' : 'info');

    return {
        ok      => 1,
        message => $summary,
        report  => $report,
        lines   => \@lines,
        doctor  => $doc,
    };
}

sub agy_login {
    my ($self, %opts) = @_;
    my $acp = $self->{acp};

    # 1. Prefer ACP authenticate RPC when server advertised authMethods (unless forced to terminal)
    if ($acp && $acp->is_running && !$opts{bang} && !$opts{terminal}) {
        my $methods = $acp->auth_methods();
        if (@$methods || defined $opts{method_id}) {
            my $mid = $opts{method_id};
            my $ok  = eval {
                $acp->authenticate($mid, create_session => 1);
                1;
            };
            if ($ok && $acp->state eq 'ready') {
                $self->_notify('Signed in to Antigravity (AGY:LIVE)', 'info');
                return {
                    ok         => 1,
                    method     => 'authenticate_rpc',
                    state      => $acp->state,
                    session_id => $acp->session_id,
                    message    => 'Signed in to Antigravity (AGY:LIVE)',
                };
            }
        }
    }

    # 2. Fall back to embedded :terminal split running `agy acp --login`
    my $bin = ($acp && $acp->agy_bin) || NeoPerl::Antigravity::ACP::discover_agy_binary();
    if (!defined $bin) {
        my $msg = NeoPerl::Antigravity::ACP::install_instructions();
        $self->_notify('agy CLI not found — run :AgyInstall or :AgyInstall!', 'warn');
        return { ok => 0, message => $msg, next_action => NeoPerl::Antigravity::ACP::install_command() };
    }

    my $buf = $self->_open_action_terminal('login', $bin, [ 'acp', '--login' ]);
    if (!$buf) {
        my $msg = "Run `$bin acp --login` in your terminal, then run :AgyReconnect.";
        $self->_notify($msg, 'info');
        return { ok => 1, method => 'manual', command => "$bin acp --login", message => $msg };
    }

    my $msg = "Sign in via embedded terminal ($bin acp --login); ACP will reconnect on exit.";
    $self->_notify($msg, 'info');
    return {
        ok      => 1,
        method  => 'terminal',
        command => "$bin acp --login",
        buf_id  => $buf->id,
        message => $msg,
    };
}

sub agy_install {
    my ($self, %opts) = @_;
    my $cmd = NeoPerl::Antigravity::ACP::install_command();
    if ($opts{bang}) {
        my $buf = $self->_open_action_terminal('install', $cmd);
        if ($buf) {
            my $msg = "Installing agy CLI in terminal split: $cmd";
            $self->_notify($msg, 'info');
            return {
                ok      => 1,
                ran     => 1,
                command => $cmd,
                buf_id  => $buf->id,
                message => $msg,
            };
        }
    }
    my $txt = NeoPerl::Antigravity::ACP::install_instructions();
    $self->_notify("Install agy: $cmd (or run :AgyInstall!)", 'info');
    return {
        ok      => 1,
        ran     => 0,
        command => $cmd,
        message => $txt,
    };
}

sub agy_model {
    my ($self, $model_name, %opts) = @_;
    my $acp = $self->{acp};
    $model_name //= '';
    $model_name =~ s/\A\s+|\s+\z//g;

    if (length $model_name) {
        return { ok => 0, message => 'ACP unavailable' } unless $acp;
        if ($acp->state eq 'connecting') {
            $self->_wait_acp_connecting(5);
        }
        if (!$acp->is_running) {
            my $ok = eval { $acp->reconnect(sync => 1) };
            return { ok => 0, message => "ACP offline: $@" } unless $ok;
        }
        elsif (!defined $acp->session_id) {
            eval { $acp->initialize() unless $acp->is_initialized; $acp->new_session() };
        }
        my $res = eval { $acp->set_model($model_name) };
        if ($@) {
            my $err = $@;
            chomp $err;
            $self->_notify("Failed to switch model: $err", 'error');
            return { ok => 0, message => $err };
        }
        $self->_notify("Antigravity model: $model_name", 'info');
        return {
            ok            => 1,
            model         => $model_name,
            current_model => $acp->current_model,
            result        => $res,
            message       => "Antigravity model: $model_name",
        };
    }

    my $models = $acp ? $acp->available_models() : [];
    my $cur    = $acp ? $acp->current_model()    : undef;
    my $tel    = $self->{telescope} || ($self->{editor} && $self->{editor}->can('plugin') ? $self->{editor}->plugin('telescope') : undef);

    if ($tel && $tel->can('open_custom')) {
        my @items = map {
            my $mid  = $_->{modelId} // $_->{id} // '';
            my $name = $_->{name}    // $mid;
            my $desc = $_->{description} // '';
            my $mark = (defined($cur) && $cur eq $mid) ? '* ' : '  ';
            +{
                label    => "$mark$name ($mid)",
                detail   => $desc,
                model_id => $mid,
                preview  => [
                    "Model ID:    $mid",
                    "Name:        $name",
                    "Status:      " . ((defined($cur) && $cur eq $mid) ? 'active' : 'available'),
                    '',
                    $desc,
                ],
                data     => $_,
            }
        } @$models;
        $tel->open_custom('Antigravity Models', \@items, sub {
            my ($item) = @_;
            $self->agy_model($item->{model_id}) if $item && defined $item->{model_id} && length $item->{model_id};
        });
        return {
            ok            => 1,
            picker        => 'telescope',
            current_model => $cur,
            models        => $models,
            message       => sprintf('Antigravity models (%d available)', scalar(@$models)),
        };
    }

    my $msg = sprintf('Model: %s (%d available)', $cur // '<default>', scalar(@$models));
    $self->_notify($msg, 'info');
    return {
        ok            => 1,
        current_model => $cur,
        models        => $models,
        message       => $msg,
    };
}

sub agy_new_session {
    my ($self, %opts) = @_;
    my $acp = $self->{acp} or return { ok => 0, message => 'ACP unavailable' };
    $self->wire_acp_callbacks();

    $self->{chat_messages} = [];
    $self->{thought_cards} = [];
    $self->{tool_cards}    = [];
    $self->{plan_entries}  = [];
    $self->{active_perm}   = undef;

    my $cwd = $opts{cwd} // ($self->{editor} && $self->{editor}->can('cwd') ? $self->{editor}->cwd : '.');
    if (!$acp->is_running) {
        my $ok = eval { $acp->reconnect(sync => 1, cwd => $cwd) };
        if (!$ok) {
            my $err = $@ || 'ACP reconnect failed';
            chomp $err;
            return { ok => 0, state => $acp->state, message => $err };
        }
    }
    else {
        $self->_wait_acp_connecting(5) if $acp->state eq 'connecting';
        eval {
            $acp->initialize() unless $acp->is_initialized;
            $acp->new_session(cwd => $cwd);
        };
        if ($@) {
            my $err = $@;
            chomp $err;
            return { ok => 0, state => $acp->state, message => $err };
        }
    }

    my $sid = $acp->session_id // '';
    $self->_notify("New Antigravity session: $sid", 'info');
    return { ok => 1, session_id => $sid, state => $acp->state, message => "New Antigravity session: $sid" };
}

sub agy_resume {
    my ($self, $session_id, %opts) = @_;
    $session_id //= '';
    $session_id =~ s/\A\s+|\s+\z//g;
    return { ok => 0, message => 'Usage: :AgyResume <session_id>' } unless length $session_id;

    my $acp = $self->{acp} or return { ok => 0, message => 'ACP unavailable' };
    $self->wire_acp_callbacks();
    my $cwd = $opts{cwd} // ($self->{editor} && $self->{editor}->can('cwd') ? $self->{editor}->cwd : '.');

    if (!$acp->is_running) {
        eval {
            $acp->start(cwd => $cwd);
            $acp->initialize();
        };
        if ($@) {
            my $err = $@;
            chomp $err;
            return { ok => 0, state => $acp->state, message => $err };
        }
    }
    elsif ($acp->state eq 'connecting') {
        $self->_wait_acp_connecting(5);
    }

    my $res = eval { $acp->load_session($session_id, cwd => $cwd) };
    if ($@) {
        my $err = $@;
        chomp $err;
        $self->_notify("Failed to resume session $session_id: $err", 'error');
        return { ok => 0, state => $acp->state, message => $err };
    }

    my $sid = $acp->session_id // $session_id;
    $self->_notify("Resumed Antigravity session: $sid", 'info');
    return { ok => 1, session_id => $sid, state => $acp->state, result => $res, message => "Resumed Antigravity session: $sid" };
}

sub agy_reconnect {
    my ($self, %opts) = @_;
    my $acp = $self->{acp} or return { ok => 0, message => 'ACP unavailable' };
    $self->wire_acp_callbacks();
    my $cwd = $opts{cwd} // ($self->{editor} && $self->{editor}->can('cwd') ? $self->{editor}->cwd : undef);
    my $ok  = $acp->reconnect(
        (defined $cwd ? (cwd => $cwd) : ()),
        ($opts{sync}  ? (sync => 1)   : ()),
    );
    my $st  = $acp->state;
    my $msg = $ok ? "Antigravity ACP reconnecting (state=$st)" : "Antigravity ACP reconnect failed (state=$st)";
    $self->_notify($msg, $ok ? 'info' : 'warn');
    return { ok => $ok ? 1 : 0, state => $st, session_id => $acp->session_id, message => $msg };
}

# --- Modality 2: Ctrl-I / <leader>ai Inline Command + Per-Hunk Diff Overlays ---

sub run_inline_command {
    my ($self, $instruction, %opts) = @_;
    my $ed   = $self->{editor};
    my $buf  = $opts{buffer} || ($ed && $ed->can('current_buffer') ? $ed->current_buffer() : undef);
    croak "run_inline_command requires an active buffer" unless $buf;

    my $path = eval { $buf->path } // 'buffer.pl';
    my $line = $opts{line} || _editor_cursor_line1($ed);
    my $src  = _buf_text($buf);

    # Use PPI context slice when available on Perl buffers
    my $context_slice = $src;
    if ($self->{perl_slice_hook} && $path =~ /\.(?:pm|pl|t)$/i) {
        my $sl = eval { $self->{perl_slice_hook}->($buf, $line) };
        $context_slice = $sl if defined $sl && length $sl;
    }

    $self->{inline_prompt} = { active => 1, text => $instruction, line => $line, path => $path };

    my $new_text;
    my $source_tag = 'inline';

    if ($opts{use_local} || !$self->{acp} || !$self->{acp}->is_running) {
        if ($self->{inference}) {
            my $kind = ($instruction =~ /\b(?:pod|doc|document)\b/i) ? 'doc'
                     : ($instruction =~ /\bcomment/i)                ? 'comments'
                     : 'refactor_local';
            my $sys_prompt = join(' ',
                'You are Ternary-Bonsai-2-27B local code editor assistant.',
                'Return ONLY the complete updated source file verbatim with valid syntax.',
                'Do not include any commentary, explanations, thoughts, or markdown code fences.',
            );
            my $target_src = length($src) ? $src : $context_slice;
            my $user_msg   = join("\n",
                "Target file: $path (cursor line $line)",
                "Instruction: $instruction",
                "Source:",
                $target_src,
            );
            my $res = $self->{inference}->complete(
                role             => 'worker_small',
                reasoning_effort => 'no_think',
                max_tokens       => $opts{max_tokens} || 1536,
                messages         => [
                    { role => 'system', content => $sys_prompt },
                    { role => 'user',   content => $user_msg },
                ],
                metadata => {
                    kind        => $kind,
                    target_path => $path,
                    source_code => $src,
                    instruction => $instruction,
                },
            );
            if (defined $res->{text}) {
                require NeoPerl::Inference::OffloadQueue;
                my $cleaned = NeoPerl::Inference::OffloadQueue::clean_llm_output($res->{text}, $kind);
                $new_text = $cleaned if length $cleaned;
            }
            $source_tag = 'bonsai_inline';
        }
    }
    else {
        # Delegate through ACP with live read + edit proposal
        my $res = $self->send_chat("Inline edit ($instruction) [read:$path] [edit:$path]");
        $self->{inline_prompt}{active} = 0;
        return { ok => 1, via => 'acp', path => $path, result => $res };
    }

    $new_text //= $src . "\n# inline: $instruction\n";

    my $hunks = [];
    my $hcnt  = 0;
    if ($buf->can('stage_diff_proposal')) {
        my $staged = $buf->stage_diff_proposal(
            $new_text,
            source => $source_tag,
            title  => "Inline: $instruction",
        );
        if (ref($staged) eq 'HASH') {
            $hunks = $staged->{hunks} || [];
            $hcnt  = $staged->{count} // scalar(@$hunks);
        }
        elsif (ref($staged) eq 'ARRAY') {
            $hunks = $staged;
            $hcnt  = scalar(@$staged);
        }
    }

    $self->{inline_prompt}{active} = 0;
    return {
        ok         => 1,
        via        => $source_tag,
        path       => $path,
        new_text   => $new_text,
        hunk_count => $hcnt,
        hunks      => $hunks,
    };
}

# --- Modality 3: <leader>af Diagnostic Auto-Fix + Code Lenses ---

my %MECHANICAL_POLICIES = map { $_ => 1 } qw(
    TestingAndDebugging::RequireUseStrict
    TestingAndDebugging::RequireUseWarnings
    Subroutines::ProhibitExplicitReturnUndef
    Subroutines::RequireFinalReturn
    Subroutines::RequireArgUnpacking
    InputOutput::ProhibitBarewordFileHandles
    InputOutput::ProhibitTwoArgOpen
);

sub auto_fix_diagnostic {
    my ($self, %opts) = @_;
    my $ed   = $self->{editor};
    my $buf  = $opts{buffer} || ($ed && $ed->can('current_buffer') ? $ed->current_buffer() : undef);
    my $diag = $opts{diagnostic};

    if (!$diag && $ed && $ed->can('get_diagnostics')) {
        my $diags = $ed->get_diagnostics($buf);
        my $line  = $opts{line} || ($ed->can('cursor') ? ($ed->cursor()->{line} || 1) : 1);
        for my $d (@$diags) {
            if (($d->{line} // 0) == $line) {
                $diag = $d;
                last;
            }
        }
        $diag ||= $diags->[0] if @$diags;
    }

    return { ok => 0, error => 'No diagnostic found to auto-fix' } unless $diag;

    my $policy = $diag->{policy} // $diag->{code} // '';
    my $msg    = $diag->{message} // 'Fix diagnostic';
    my $path   = $diag->{path} // ($buf ? eval { $buf->path } : '');

    # Tier 1: Mechanical Perl::Critic fixes route out-of-band to Ternary-Bonsai at 0 cloud cost
    if ($self->{offload_queue} && ($MECHANICAL_POLICIES{$policy} || ($diag->{tier} // '') eq 'local')) {
        my $jid = $self->{offload_queue}->enqueue(
            kind        => 'refactor_local',
            target_path => $path,
            buffer      => $buf,
            instruction => "Fix $policy at line " . ($diag->{line} // 1) . ": $msg",
        );
        $self->{offload_queue}->pump(1) if $opts{sync};
        return {
            ok      => 1,
            tier    => 'bonsai_local',
            policy  => $policy,
            job_id  => $jid,
        };
    }

    # Tier 2: Complex/structural diagnostics escalate to inline/ACP
    my $res = $self->run_inline_command("Fix diagnostic ($policy): $msg", buffer => $buf, use_local => $opts{use_local});
    return {
        ok     => 1,
        tier   => ($res->{via} eq 'acp' ? 'antigravity_cloud' : 'local_fallback'),
        policy => $policy,
        result => $res,
    };
}

sub compute_code_lenses {
    my ($self, $buf) = @_;
    return [] unless $buf;
    my $text = _buf_text($buf);
    my $zb   = _buf_is_zero_based($buf);
    my @lenses;
    my $lno = 0;
    for my $line (split /\n/, $text) {
        $lno++;
        if ($line =~ /^\s*sub\s+([A-Za-z_]\w*)/) {
            push @lenses, {
                line   => $lno,
                label  => "Agy: [Doc] [Test] [Explain] sub $1",
                symbol => $1,
            };
        }
    }
    if ($buf->can('set_extmark') && $buf->can('clear_namespace')) {
        $buf->clear_namespace('agy_codelens');
        for my $lens (@lenses) {
            my $row = $zb ? ($lens->{line} - 1) : $lens->{line};
            eval {
                $buf->set_extmark('agy_codelens', $row, 0, {
                    virt_lines       => [ $lens->{label} ],
                    virt_lines_hl    => 'Comment',
                    virt_lines_above => 1,
                });
            };
        }
    }
    return \@lenses;
}

# --- Modality 4: <Tab> Ghost-Text Autocomplete ---

sub request_ghost_text {
    my ($self, $buf, $line, $col) = @_;
    return undef unless $buf;
    my $text  = _buf_text($buf);
    my $zb    = _buf_is_zero_based($buf);
    my @lines = split /\n/, $text, -1;
    my $idx   = $zb ? ($line // 0) : (($line || 1) - 1);
    $idx = 0 if $idx < 0;
    my $cur    = $lines[$idx] // '';
    my $prefix = substr($cur, 0, defined($col) ? $col : length($cur));

    my $suggestion = '';
    if ($prefix =~ /^\s*sub\s+([A-Za-z_]\w*)\s*\{?\s*$/) {
        $suggestion = " my (\$self, \@args) = \@_;";
    }
    elsif ($prefix =~ /^\s*my\s+\$(\w+)\s*=\s*$/) {
        $suggestion = "shift;";
    }
    elsif ($prefix =~ /^\s*use\s+strict;\s*$/) {
        $suggestion = "\nuse warnings;";
    }
    elsif ($self->{inference}) {
        my $start_ctx  = $idx > 12 ? $idx - 12 : 0;
        my $ctx_before = $idx > $start_ctx
            ? join("\n", @lines[ $start_ctx .. $idx - 1 ]) . "\n"
            : '';
        my $fpath = eval { $buf->path } // '';
        my $ft    = eval { $buf->filetype } // 'perl';
        my $res   = $self->{inference}->complete(
            role             => 'worker_small',
            reasoning_effort => 'no_think',
            max_tokens       => 64,
            temperature      => 0.0,
            messages         => [
                {
                    role    => 'system',
                    content => 'Return ONLY the single-line code continuation for the cursor position, no explanation, no markdown.',
                },
                {
                    role    => 'user',
                    content => "Language: $ft\nFile: $fpath\nContinue the last line from the cursor position:\n$ctx_before$prefix",
                },
            ],
            metadata => { kind => 'summarize', source_code => $prefix, target_path => $fpath },
        );
        require NeoPerl::Inference::OffloadQueue;
        my $cleaned = NeoPerl::Inference::OffloadQueue::clean_llm_output($res->{text} // '', '');
        $cleaned =~ s{</?think\b[^>]*>}{}gi;
        $cleaned =~ s/\A\s*```[A-Za-z0-9_+-]*[ \t]*\r?\n?//;
        $cleaned =~ s/\r?\n?[ \t]*```\s*\z//;
        my $first = '';
        for my $ln (split /\r?\n/, $cleaned) {
            $ln =~ s/`+//g;
            $ln =~ s/\s+\z//;
            if ($ln =~ /\S/) {
                $first = $ln;
                last;
            }
        }
        my $trim_prefix = $prefix;
        $trim_prefix =~ s/\A\s+//;
        if (length($prefix) && length($first) > length($prefix) && index($first, $prefix) == 0) {
            $first = substr($first, length($prefix));
        }
        elsif (length($trim_prefix) && length($first) > length($trim_prefix) && index($first, $trim_prefix) == 0) {
            $first = substr($first, length($trim_prefix));
        }
        $first =~ s/\r//g;
        if (length($first) && ($res->{transport} // '') eq 'loopback') {
            $suggestion = ' # ' . substr($first, 0, 64);
        }
        elsif (length($first)) {
            $suggestion = substr($first, 0, 120);
        }
    }

    return undef unless length $suggestion;

    my $ext_id;
    if ($buf->can('clear_namespace') && $buf->can('set_extmark')) {
        $buf->clear_namespace('agy_ghost');
        $ext_id = eval {
            $buf->set_extmark('agy_ghost', $line, $col, {
                virt_text => $suggestion,
                virt_hl   => 'Comment',
                virt_pos  => 'eol',
            });
        };
    }

    $self->{ghost_state} = {
        active     => 1,
        buf_id     => eval { $buf->id } // 0,
        line       => $line,
        col        => $col,
        text       => $suggestion,
        extmark_id => $ext_id,
    };
    return $suggestion;
}

sub accept_ghost_text {
    my ($self, $buf) = @_;
    return 0 unless $self->{ghost_state}{active} && $buf;
    my $txt  = $self->{ghost_state}{text};
    my $line = $self->{ghost_state}{line};
    my $col  = $self->{ghost_state}{col};

    $self->dismiss_ghost_text($buf);

    if ($buf->can('insert_at')) {
        $buf->insert_at($line, $col, $txt);
    }
    elsif ($buf->can('set_text')) {
        my @lines = split /\n/, _buf_text($buf), -1;
        my $idx = _buf_is_zero_based($buf) ? ($line // 0) : (($line || 1) - 1);
        $lines[$idx] //= '';
        substr($lines[$idx], $col, 0, $txt);
        $buf->set_text(join("\n", @lines));
    }
    return $txt;
}

sub dismiss_ghost_text {
    my ($self, $buf) = @_;
    if ($buf && $buf->can('clear_namespace')) {
        eval { $buf->clear_namespace('agy_ghost') };
    }
    $self->{ghost_state} = { active => 0, buf_id => undef, line => 0, col => 0, text => '', extmark_id => undef };
    return 1;
}

# --- Editor Integration Wiring ---

sub attach {
    my ($self, $editor) = @_;
    return 0 unless $editor;
    $self->{editor} = $editor;

    # Expose AI/DB subsystem handles on Editor for plugins (PerlDev/XSDev) and UI tabs
    $editor->{memory_store}   = $self->{memory_store}   if $self->{memory_store};
    $editor->{memory_writer}  = $self->{memory_writer}  if $self->{memory_writer};
    $editor->{inference}      = $self->{inference}      if $self->{inference};
    $editor->{vision}         = $self->{vision}         if $self->{vision};
    $editor->{offload_queue}  = $self->{offload_queue}  if $self->{offload_queue};
    $editor->{model_hub}      = $self->{model_hub}      if $self->{model_hub};
    $editor->{acp}            = $self->{acp}            if $self->{acp};
    $editor->{editor_mcp}     = $self->{editor_mcp}     if $self->{editor_mcp};
    $editor->{customizations} = $self->{customizations} if $self->{customizations};
    $editor->{modalities}     = $self;

    $self->{editor_mcp}->set_editor($editor)       if $self->{editor_mcp};
    $self->{acp}->set_editor($editor)              if $self->{acp};
    $self->{offload_queue}->set_editor($editor)    if $self->{offload_queue};
    $self->{memory_writer}->attach_editor($editor) if $self->{memory_writer};

    $self->wire_acp_callbacks() if $self->{acp};

    # Register Ex commands cleanly against NeoPerl::ExCmd or test harness
    my $reg_cmd = sub {
        my ($name, $fn, $desc, %extra) = @_;
        my $wrapped = sub {
            my ($ed, $ctx_or_args) = @_;
            my $args = ref($ctx_or_args) eq 'HASH' ? ($ctx_or_args->{args} // '') : ($ctx_or_args // '');
            my $bang = ref($ctx_or_args) eq 'HASH' ? ($ctx_or_args->{bang} ? 1 : 0) : 0;
            return $fn->($ed, $args, $bang, $ctx_or_args);
        };
        if ($editor->can('excmd') && $editor->excmd && $editor->excmd->can('register_command')) {
            $editor->excmd->register_command($name, $wrapped, desc => $desc // '', %extra);
        }
        elsif ($editor->can('register_command')) {
            $editor->register_command($name, $wrapped);
        }
        elsif ($editor->{ex} && $editor->{ex}->can('register_command')) {
            $editor->{ex}->register_command($name, $wrapped);
        }
    };

    $reg_cmd->('AgyChat', sub {
        my ($ed, $args) = @_;
        if ($ed->{layout} && $ed->{layout}->can('open_command_center')) {
            $ed->{layout}->open_command_center('chat');
        }
        elsif ($ed->{layout} && $ed->{layout}->can('toggle_command_center')) {
            $ed->{layout}->toggle_command_center('chat');
        }
        return $self->send_chat($args) if defined $args && length $args;
        return $self->chat_state();
    }, 'Open or send prompt to Antigravity chat');

    $reg_cmd->('AgyDoctor', sub {
        return $self->agy_doctor();
    }, 'Inspect Antigravity ACP binary, sign-in, model, MCP tools, and next step', aliases => ['AgyStatus']);

    $reg_cmd->('AgyStatus', sub {
        return $self->agy_doctor();
    }, 'Show Antigravity ACP connection and session status');

    $reg_cmd->('AgyLogin', sub {
        my ($ed, $args, $bang) = @_;
        return $self->agy_login(
            (defined $args && length $args ? (method_id => $args) : ()),
            bang => $bang,
        );
    }, 'Sign in to Antigravity via authenticate RPC or embedded :terminal split', bang => 1);

    $reg_cmd->('AgyInstall', sub {
        my ($ed, $args, $bang) = @_;
        return $self->agy_install(bang => $bang);
    }, 'Show official agy CLI install command (use :AgyInstall! to run in terminal split)', bang => 1);

    $reg_cmd->('AgyModel', sub {
        my ($ed, $args) = @_;
        return $self->agy_model($args);
    }, 'Switch Antigravity model or open Telescope model picker');

    $reg_cmd->('AgyNewSession', sub {
        return $self->agy_new_session();
    }, 'Start a fresh Antigravity ACP session');

    $reg_cmd->('AgyResume', sub {
        my ($ed, $args) = @_;
        return $self->agy_resume($args);
    }, 'Resume an existing Antigravity ACP session by ID');

    $reg_cmd->('AgyReconnect', sub {
        my ($ed, $args, $bang) = @_;
        return $self->agy_reconnect(sync => $bang ? 1 : 0);
    }, 'Reconnect Antigravity ACP subprocess', bang => 1);

    $reg_cmd->('AgyInline', sub {
        my ($ed, $args) = @_;
        return $self->run_inline_command($args || 'Improve code clarity');
    }, 'Run inline edit command and stage diff hunks');

    $reg_cmd->('AgyFix', sub {
        my ($ed, $args) = @_;
        return $self->auto_fix_diagnostic();
    }, 'Auto-fix diagnostic at cursor');

    $reg_cmd->('AgyJobs', sub {
        my ($ed, $args) = @_;
        if ($ed->{layout} && $ed->{layout}->can('toggle_command_center')) {
            $ed->{layout}->toggle_command_center('jobs');
        }
        return $self->{offload_queue} ? $self->{offload_queue}->list_jobs() : [];
    }, 'Inspect out-of-band Ternary-Bonsai local jobs');

    $reg_cmd->('ModelHub', sub {
        return $self->{model_hub} ? $self->{model_hub}->format_report_text() : 'ModelHub unavailable';
    }, 'Show local GGUF models, llama-server probes, and download recipes');

    $reg_cmd->('MemSave', sub {
        my ($ed, $args) = @_;
        return { ok => 0, error => 'Usage: :MemSave <fact>' } unless defined $args && length $args;
        my $buf = $ed->can('current_buffer') ? $ed->current_buffer() : undef;
        return $self->{memory_writer}->save_explicit(
            repo_key  => $self->{repo_key},
            file_path => $buf ? eval { $buf->path } : undef,
            content   => $args,
        );
    }, 'Save explicit memory via Hy-Memory into Db2');

    $reg_cmd->('MemSearch', sub {
        my ($ed, $args) = @_;
        return [] unless $self->{memory_store};
        return $self->{memory_store}->search(query => $args // '', repo_key => $self->{repo_key});
    }, 'Search Db2 semantic memory store');

    $reg_cmd->('MemBrowse', sub {
        my ($ed, $args) = @_;
        if ($ed->{layout} && $ed->{layout}->can('toggle_command_center')) {
            $ed->{layout}->toggle_command_center('memory');
        }
        return $self->{memory_store} ? $self->{memory_store}->search(query => $args // '', limit => 20) : [];
    }, 'Open Db2 Semantic Memory Inspector');

    $reg_cmd->('MemAutoContext', sub {
        my ($ed, $args) = @_;
        if (defined $args && $args =~ /^(on|1|true)$/i) {
            $self->auto_context(1);
        }
        elsif (defined $args && $args =~ /^(off|0|false)$/i) {
            $self->auto_context(0);
        }
        else {
            $self->auto_context(!$self->auto_context);
        }
        return $self->auto_context;
    }, 'Toggle compact <=250-token auto-context memory hint');

    $reg_cmd->('VisionParse', sub {
        my ($ed, $args) = @_;
        return { ok => 0, error => 'Vision unavailable' } unless $self->{vision};
        if (!defined $args || !length $args || $args eq 'clipboard') {
            return $self->{vision}->preprocess_clipboard();
        }
        my ($path, $fmt) = split /\s+/, $args, 2;
        return $self->{vision}->preprocess_file(path => $path, format => $fmt || 'markdown');
    }, 'Preprocess image, clipboard, or PDF with Granite-Vision-4.1-4B');

    # Register keymaps cleanly against NeoPerl::Modal or test harness
    my $reg_map = sub {
        my ($mode, $lhs, $cb, $desc) = @_;
        my $mchar = ($mode eq 'NORMAL') ? 'n' : ($mode eq 'INSERT' ? 'i' : ($mode eq 'VISUAL' ? 'v' : $mode));
        if ($editor->can('modal') && $editor->modal && $editor->modal->can('map')) {
            $editor->modal->map($mchar, $lhs, $cb, desc => $desc // '');
        }
        elsif ($editor->can('map_key')) {
            $editor->map_key($mode, $lhs, $cb, $desc);
        }
    };

    $reg_map->('NORMAL', '<leader>aa', sub { $editor->{layout}->toggle_command_center('chat')   if $editor->{layout} && $editor->{layout}->can('toggle_command_center') }, 'Toggle Antigravity Chat');
    $reg_map->('NORMAL', '<leader>am', sub { $editor->{layout}->toggle_command_center('memory') if $editor->{layout} && $editor->{layout}->can('toggle_command_center') }, 'Toggle Db2 Memory Inspector');
    $reg_map->('NORMAL', '<leader>aj', sub { $editor->{layout}->toggle_command_center('jobs')   if $editor->{layout} && $editor->{layout}->can('toggle_command_center') }, 'Toggle Local Models & Jobs');
    $reg_map->('NORMAL', '<leader>aL', sub { $self->agy_login() },  'Antigravity Sign-In (:AgyLogin)');
    $reg_map->('NORMAL', '<leader>aM', sub { $self->agy_model() },  'Antigravity Model Picker (:AgyModel)');
    $reg_map->('NORMAL', '<leader>ai', sub { $self->run_inline_command('Improve selection') }, 'Antigravity Inline Command');
    $reg_map->('NORMAL', '<C-i>',      sub { $self->run_inline_command('Improve selection') }, 'Antigravity Inline Command');
    $reg_map->('NORMAL', '<leader>af', sub { $self->auto_fix_diagnostic() }, 'Antigravity Auto-Fix Diagnostic');
    $reg_map->('NORMAL', '<leader>vp', sub { $self->{vision} ? $self->{vision}->preprocess_clipboard() : undef }, 'Vision Paste Clipboard');
    $reg_map->('NORMAL', '<leader>ay', sub { my $b = $editor->current_buffer; $b->accept_hunk(0) if $b && $b->can('accept_hunk') }, 'Accept Diff Hunk');
    $reg_map->('NORMAL', '<leader>an', sub { my $b = $editor->current_buffer; $b->reject_hunk(0) if $b && $b->can('reject_hunk') }, 'Reject Diff Hunk');

    # Register tick pump, Command Center tab providers, Statusline segment, and plugin handles
    if ($editor->can('add_tick_callback')) {
        $editor->add_tick_callback('ai_db', sub { $self->pump() });
    }
    if ($editor->can('register_command_center_provider')) {
        $editor->register_command_center_provider('chat', sub { $self->chat_state() });
        $editor->register_command_center_provider('memory', sub {
            return {} unless $self->{memory_store};
            return {
                stats    => $self->{memory_store}->stats(),
                memories => $self->{memory_store}->search(query => '', repo_key => $self->{repo_key}, limit => 25, update_access => 0),
                events   => $self->{memory_store}->list_events(repo => $self->{repo_key}, limit => 15),
            };
        });
        $editor->register_command_center_provider('jobs', sub {
            return {
                telemetry   => $self->{inference}     ? $self->{inference}->telemetry()     : {},
                jobs        => $self->{offload_queue} ? $self->{offload_queue}->list_jobs() : [],
                job_summary => $self->{offload_queue} ? $self->{offload_queue}->summary()   : {},
                recent_docs => $self->{vision}        ? $self->{vision}->recent_docs()      : [],
            };
        });
    }
    if ($editor->can('register_statusline_provider')) {
        $editor->register_statusline_provider('ai_db', sub {
            my $tel  = $self->{inference} ? $self->{inference}->telemetry() : {};
            my $pill = $self->acp_status_pill();
            return {
                acp_connected      => ($self->{acp} && $self->{acp}->is_ready) ? 1 : 0,
                acp_state          => $self->{acp} ? $self->{acp}->state : 'offline',
                acp_pill           => $pill->{label},
                current_model      => $self->{acp} ? $self->{acp}->current_model : undef,
                db_dialect         => $self->{memory_store} ? $self->{memory_store}->dialect : 'none',
                resident_gb        => $tel->{resident_gb}                  // 0,
                ram_budget_gb      => $tel->{ram_budget_gb}                // 20,
                cloud_tokens_saved => $tel->{estimated_cloud_tokens_saved} // 0,
                mcp_tools          => $self->{editor_mcp} ? scalar(@{ $self->{editor_mcp}->list_tool_names }) : 0,
            };
        });
    }
    if ($editor->can('register_plugin')) {
        $editor->register_plugin('ai_db',         $self);
        $editor->register_plugin('editor_mcp',    $self->{editor_mcp})    if $self->{editor_mcp};
        $editor->register_plugin('memory_store',  $self->{memory_store})  if $self->{memory_store};
        $editor->register_plugin('offload_queue', $self->{offload_queue}) if $self->{offload_queue};
    }

    $self->{attached} = 1;
    return 1;
}

sub _poll_term_watchers {
    my ($self) = @_;
    return unless @{ $self->{pending_term_watchers} };
    my @remaining;
    for my $w (@{ $self->{pending_term_watchers} }) {
        my $buf  = $w->{buf};
        my $term = ($buf && $buf->can('term')) ? $buf->term : undef;
        next unless $term;
        eval { $buf->poll_terminal(0) };
        if ($term->is_alive) {
            push @remaining, $w;
            next;
        }
        my $code = eval { $term->exit_code };
        my $kind = $w->{kind} || 'action';
        if (defined($code) && $code == 0) {
            $self->_notify("Antigravity $kind succeeded — reconnecting ACP...", 'info');
            eval { $self->agy_reconnect() };
        }
        else {
            $self->_notify("Antigravity $kind exited with code " . ($code // '?'), 'warn');
        }
    }
    $self->{pending_term_watchers} = \@remaining;
    return;
}

sub pump {
    my ($self) = @_;
    $self->{editor_mcp}->poll(0)    if $self->{editor_mcp} && $self->{editor_mcp}->is_running;
    $self->{acp}->poll(0)           if $self->{acp}        && $self->{acp}->is_running;
    $self->_flush_queued_prompts()  if $self->{acp}        && $self->{acp}->is_ready && @{ $self->{queued_prompts} };
    $self->_poll_term_watchers()    if @{ $self->{pending_term_watchers} };
    # Do not stall an active ACP connect handshake with synchronous local-model inference
    my $acp_connecting = ($self->{acp} && $self->{acp}->is_running && ($self->{acp}->state // '') eq 'connecting') ? 1 : 0;
    if (!$acp_connecting) {
        $self->{offload_queue}->pump(2) if $self->{offload_queue};
        $self->{memory_writer}->pump(2) if $self->{memory_writer};
        $self->{editor_mcp}->poll(0)    if $self->{editor_mcp} && $self->{editor_mcp}->is_running;
        $self->{acp}->poll(0)           if $self->{acp}        && $self->{acp}->is_running;
    }
    return 1;
}

1;

__END__

=head1 NAME

NeoPerl::Antigravity::Modalities - Sidebar Chat, Inline Diff, Auto-Fix, Ghost Text, and ACP lifecycle commands

=head1 SYNOPSIS

    use NeoPerl::Antigravity::Modalities;

    my $mod = NeoPerl::Antigravity::Modalities->new(
        acp            => $acp,
        editor_mcp     => $mcp,
        memory_store   => $store,
        memory_writer  => $writer,
        inference      => $mgr,
        vision         => $vision,
        offload_queue  => $queue,
        customizations => $cust,
    );
    $mod->attach($editor);

=head1 DESCRIPTION

C<NeoPerl::Antigravity::Modalities> coordinates the four Antigravity IDE
interaction surfaces (Sidebar Chat with C<@> mentions, C</> slash commands,
interactive composer input, permission bar, and optional C<=E<lt>250>-token
C<:MemAutoContext> hints; C<Ctrl-I> inline edits with red/green diff hunks;
tiered C<E<lt>leaderE<gt>af> diagnostic auto-fix and code lenses; and
C<E<lt>TabE<gt>> ghost-text completion) together with automatic ACP lifecycle
commands (C<:AgyDoctor>, C<:AgyStatus>, C<:AgyLogin>, C<:AgyInstall>,
C<:AgyInstall!>, C<:AgyModel>, C<:AgyNewSession>, C<:AgyResume>,
C<:AgyReconnect>) and keymaps (C<E<lt>leaderE<gt>aL>, C<E<lt>leaderE<gt>aM>).

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
