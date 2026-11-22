use strict;
use warnings;
use utf8;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempdir tempfile);
use Cwd qw(abs_path);
use Time::HiRes qw(time sleep);
use JSON::PP ();
use Test::More;

my $ROOT;

BEGIN {
    $ROOT = abs_path(File::Spec->catdir($FindBin::RealBin, File::Spec->updir));
    for my $rel (
        File::Spec->catdir('blib', 'arch'),
        File::Spec->catdir('blib', 'lib'),
        'lib',
    ) {
        my $dir = File::Spec->catdir($ROOT, $rel);
        unshift @INC, $dir if -d $dir;
    }

    my $parent = File::Spec->catdir($ROOT, File::Spec->updir);
    my %have = map { $_ => 1 } grep { !ref($_) } @INC;
    my $prepend = sub {
        my ($d) = @_;
        return unless defined $d && -d $d;
        my $abs = eval { abs_path($d) } || $d;
        return if $have{$abs};
        unshift @INC, $abs;
        $have{$abs} = 1;
    };

    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    $prepend->(File::Spec->catdir($home, 'perl5', 'lib', 'perl5')) if length $home;

    for my $spec (
        [ $ENV{NEOPERL_DBD_SQLITE_DIR}, 'dbd-sqlite-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBI_DIR},        'dbi-mt',        [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_MOJO_DIR},       'mojolicious-mt',[ 'xs/blib/arch', 'xs/blib/lib', 'lib' ] ],
    ) {
        my ($env_dir, $repo, $subs) = @$spec;
        my $base = (defined $env_dir && length $env_dir && -d $env_dir)
            ? $env_dir
            : File::Spec->catdir($parent, $repo);
        next unless -d $base;
        for my $rel (reverse @$subs) {
            $prepend->(File::Spec->catdir($base, split('/', $rel)));
        }
    }
}

use_ok('NeoPerl::Antigravity::ACP');
use_ok('NeoPerl::Antigravity::Modalities');
use_ok('NeoPerl::MT');

my $tmp = tempdir(CLEANUP => 1);
my $ws  = File::Spec->catdir($tmp, 'workspace');
mkdir $ws or die "mkdir $ws: $!";
$ws = abs_path($ws) || $ws;

my $log_file   = File::Spec->catfile($tmp, 'fake_agy.log');
my $auth_flag  = File::Spec->catfile($tmp, 'signed_in.flag');
my $impl_file  = File::Spec->catfile($tmp, 'fake_agy_impl.pl');
my $fake_agy   = File::Spec->catfile($tmp, 'agy');

# Write a realistic, executable ACP 1.0 fake `agy` script
{
    my $impl = <<'END_FAKE_AGY';
use strict;
use warnings;
use IO::Handle ();
use JSON::PP ();

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $json = JSON::PP->new->utf8;
my $log_path  = $ENV{FAKE_AGY_LOG}       // '';
my $auth_file = $ENV{FAKE_AGY_AUTH_FILE} // '';

sub record {
    my ($entry) = @_;
    return unless length $log_path;
    if (open my $fh, '>>', $log_path) {
        print {$fh} $json->encode($entry) . "\n";
        close $fh;
    }
}

record({ event => 'spawn', argv => [@ARGV] });

# Handle `agy acp --login`
if (@ARGV >= 2 && $ARGV[0] eq 'acp' && $ARGV[1] eq '--login') {
    if (length $auth_file) {
        open my $fh, '>', $auth_file or die $!;
        print {$fh} "signed-in\n";
        close $fh;
    }
    record({ event => 'cli_login', ok => 1 });
    print STDOUT "Signed in to Antigravity (fake-agy)\n";
    exit 0;
}

print STDERR "fake-agy: acp server started pid=$$\n";

my $need_auth = ($ENV{FAKE_AGY_REQUIRE_AUTH} && (!length($auth_file) || !-f $auth_file)) ? 1 : 0;
my $authed    = $need_auth ? 0 : 1;
my $sess_seq  = 0;
my $rev_id    = 5000;
my $cur_model = 'gemini-2.5-pro';
my @models    = (
    { modelId => 'gemini-2.5-pro',   name => 'Gemini 2.5 Pro',   description => 'Deep reasoning & refactoring' },
    { modelId => 'gemini-2.5-flash', name => 'Gemini 2.5 Flash', description => 'Fast interactive edits' },
    { modelId => 'gemini-2.5-ultra', name => 'Gemini 2.5 Ultra', description => 'Large-context architecture' },
);

sub send_msg {
    my ($obj) = @_;
    print STDOUT $json->encode($obj) . "\n";
}

sub call_client {
    my ($method, $params) = @_;
    my $rid = $rev_id++;
    send_msg({ jsonrpc => '2.0', id => $rid, method => $method, params => $params || {} });
    while (defined(my $line = <STDIN>)) {
        $line =~ s/[\r\n]+$//;
        next unless length $line;
        my $m = eval { $json->decode($line) };
        next unless ref($m) eq 'HASH';
        if (defined $m->{id} && $m->{id} == $rid) {
            return ($m->{result}, $m->{error});
        }
    }
    return (undef, { code => -32099, message => 'EOF' });
}

while (defined(my $line = <STDIN>)) {
    $line =~ s/[\r\n]+$//;
    next unless length $line;
    my $req = eval { $json->decode($line) };
    next unless ref($req) eq 'HASH';

    my $method = $req->{method} // '';
    my $id     = $req->{id};
    my $params = ref($req->{params}) eq 'HASH' ? $req->{params} : {};
    record({ event => 'rpc', method => $method, params => $params });

    if ($method eq 'initialize') {
        print STDERR "fake-agy: initialize negotiated protocolVersion=1\n";
        send_msg({
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                protocolVersion   => 1,
                agentInfo         => { name => 'antigravity-fake-live', version => '1.0.0' },
                agentCapabilities => {
                    loadSession => JSON::PP::true,
                    streaming   => JSON::PP::true,
                    mcpCapabilities => { http => JSON::PP::true },
                },
                authMethods       => [
                    { id => 'google-oauth', name => 'Google Account', description => 'Sign in with Google' },
                ],
            },
        });
        next;
    }

    if ($method eq 'authenticate') {
        my $mid = $params->{methodId} // '';
        record({ event => 'authenticated', methodId => $mid });
        $authed = 1;
        send_msg({ jsonrpc => '2.0', id => $id, result => { authenticated => JSON::PP::true, methodId => $mid } });
        next;
    }

    if ($method eq 'session/new') {
        if (!$authed) {
            print STDERR "fake-agy: auth_required before session/new\n";
            send_msg({
                jsonrpc => '2.0',
                id      => $id,
                error   => { code => -32000, message => 'Authentication required: please sign in' },
            });
            next;
        }
        my $sid = 'live-sess-' . (++$sess_seq);
        send_msg({
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                sessionId => $sid,
                models    => {
                    currentModelId  => $cur_model,
                    availableModels => \@models,
                },
            },
        });
        next;
    }

    if ($method eq 'session/load') {
        my $sid = $params->{sessionId} // 'loaded-sess';
        send_msg({
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                sessionId => $sid,
                models    => {
                    currentModelId  => $cur_model,
                    availableModels => \@models,
                },
            },
        });
        next;
    }

    if ($method eq 'session/set_model') {
        $cur_model = $params->{modelId} if defined $params->{modelId};
        send_msg({ jsonrpc => '2.0', id => $id, result => { currentModelId => $cur_model } });
        next;
    }

    if ($method eq 'session/prompt') {
        my $sid = $params->{sessionId} // 'live-sess-1';
        my $text = join("\n", map { $_->{text} // '' } @{ $params->{prompt} || [] });

        # Emit full ACP 1.0 nested session/update suite
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'available_commands_update',
                    availableCommands => [
                        { name => 'review', description => 'Review staged changes' },
                    ],
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'current_mode_update',
                    currentModeId => 'architect',
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'agent_thought_chunk',
                    content       => { type => 'text', text => 'Inspecting workspace context... ' },
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'agent_thought_chunk',
                    content       => { type => 'text', text => 'ready to respond.' },
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'plan',
                    entries       => [
                        { content => 'Inspect active buffer', status => 'completed', priority => 'high' },
                        { content => 'Stream live response',  status => 'in_progress', priority => 'medium' },
                    ],
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'tool_call',
                    toolCallId    => 'tc-live-1',
                    title         => 'neoperl_get_editor_state',
                    status        => 'in_progress',
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'tool_call_update',
                    toolCallId    => 'tc-live-1',
                    status        => 'completed',
                },
            },
        });

        my $perm_opt_seen = 'none';
        if ($text =~ /\[perm_custom\]/) {
            my ($pres, $perr) = call_client('session/request_permission', {
                sessionId   => $sid,
                toolCall    => { toolCallId => 'tc-perm-1', title => 'edit_file', kind => 'edit' },
                description => 'Apply custom-optionId edit',
                options     => [
                    { optionId => 'allow_once_custom_id',   name => 'Allow once',   kind => 'allow_once' },
                    { optionId => 'allow_always_custom_id', name => 'Always allow', kind => 'allow_always' },
                    { optionId => 'reject_once_custom_id',  name => 'Reject',       kind => 'reject_once' },
                ],
            });
            $perm_opt_seen = ($pres && ref($pres->{outcome}) eq 'HASH')
                ? ($pres->{outcome}{optionId} // 'missing')
                : 'missing';
            record({ event => 'perm_response', outcome => ($pres ? $pres->{outcome} : undef) });
        }

        my $reply = "Live response on $cur_model (perm=$perm_opt_seen): $text";
        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'agent_message_chunk',
                    content       => { type => 'text', text => $reply },
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                stopReason => 'end_turn',
                sessionId  => $sid,
                finalText  => $reply,
                permOption => $perm_opt_seen,
            },
        });
        next;
    }

    if (defined $id) {
        send_msg({ jsonrpc => '2.0', id => $id, error => { code => -32601, message => "Unknown method: $method" } });
    }
}
exit 0;
END_FAKE_AGY

    open my $ifh, '>', $impl_file or die "write $impl_file: $!";
    print {$ifh} $impl;
    close $ifh;

    my @inc_flags = map { my $q = $_; $q =~ s/'/'\\''/g; "-I'$q'" } grep { defined $_ && !ref($_) && -d $_ } @INC;
    my $perl_q = $^X;
    $perl_q =~ s/'/'\\''/g;
    my $impl_q = $impl_file;
    $impl_q =~ s/'/'\\''/g;

    open my $wfh, '>', $fake_agy or die "write $fake_agy: $!";
    print {$wfh} "#!/bin/sh\n";
    print {$wfh} "exec '$perl_q' " . join(' ', @inc_flags) . " '$impl_q' \"\$@\"\n";
    close $wfh;
    chmod 0755, $fake_agy or die "chmod $fake_agy: $!";
}

sub read_log_entries {
    return [] unless -f $log_file;
    open my $fh, '<', $log_file or return [];
    my @entries;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $obj = eval { JSON::PP->new->utf8->decode($line) };
        push @entries, $obj if ref($obj) eq 'HASH';
    }
    close $fh;
    return \@entries;
}

sub clear_log {
    unlink $log_file if -f $log_file;
}

sub wait_until {
    my ($cond, $timeout_s) = @_;
    $timeout_s ||= 5.0;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $cond->();
        sleep(0.02);
    }
    return $cond->() ? 1 : 0;
}

# ---------------------------------------------------------------------------
# 1. Binary Discovery & Zero-Flag Auto-Connect -> AGY:LIVE
# ---------------------------------------------------------------------------
subtest 'Zero-flag NeoPerl::MT->new() auto-connects signed-in agy -> AGY:LIVE' => sub {
    clear_log();
    local $ENV{NEOPERL_AGY_BIN}   = $fake_agy;
    local $ENV{FAKE_AGY_LOG}      = $log_file;
    local $ENV{FAKE_AGY_AUTH_FILE}= $auth_flag;
    local $ENV{FAKE_AGY_REQUIRE_AUTH} = 0;

    is(NeoPerl::Antigravity::ACP::discover_agy_binary(), $fake_agy, 'discover_agy_binary finds NEOPERL_AGY_BIN');

    my $t0  = time();
    my $app = NeoPerl::MT->new(
        cwd         => $ws,
        ui          => 'tui',
        headless    => 1,
        cols        => 132,
        rows        => 40,
        load_config => 0,
    );
    my $startup_ms = (time() - $t0) * 1000.0;
    ok($startup_ms < 5000, sprintf('zero-flag startup non-blocking (%.1f ms)', $startup_ms));

    my $init_state = $app->acp->state;
    ok($init_state eq 'connecting' || $init_state eq 'ready',
        "initial ACP state is connecting/ready ($init_state)");

    # Pump editor event loop non-blockingly until ACP reaches ready
    ok(wait_until(sub { $app->editor->pump(); $app->acp->state eq 'ready' }, 6.0),
        'async initialize -> session/new reaches state=ready via editor pump');

    is($app->acp->is_mock, 0, 'connected to live executable agy (not mock)');
    like($app->acp->session_id // '', qr/^live-sess-/, 'live sessionId populated');
    is($app->acp->current_model, 'gemini-2.5-pro', 'currentModelId parsed from session/new');
    is(scalar(@{ $app->acp->available_models }), 3, 'availableModels parsed from session/new');
    is($app->acp->auth_methods->[0]{id}, 'google-oauth', 'authMethods stored from initialize');
    ok($app->acp->agent_capabilities->{loadSession}, 'agentCapabilities stored from initialize');

    # Check top status pill & TUI rendering
    my $pill = $app->modalities->acp_status_pill();
    is($pill->{label}, 'AGY:LIVE', 'status pill reports AGY:LIVE');
    $app->editor->layout->open_command_center('chat');
    $app->ui->render_frame();
    my $scr = $app->ui->screen_text();
    like($scr, qr/AGY:LIVE/, 'TUI top bar and CHAT tab display AGY:LIVE');
    like($scr, qr/Model: gemini-2\.5-pro/, 'CHAT tab displays active model banner');

    # Verify CLI args & spec-compliant mcpServers in session/new
    my $entries = read_log_entries();
    my ($spawn) = grep { ($_->{event} // '') eq 'spawn' } @$entries;
    ok($spawn, 'fake-agy recorded spawn');
    my $argv_str = join(' ', @{ $spawn->{argv} || [] });
    like($argv_str, qr/\bacp\b/, 'spawned with acp subcommand');
    like($argv_str, qr/--ide-mcp-port \d+/, 'spawned with --ide-mcp-port');
    like($argv_str, qr/--add-dir \Q$ws\E/, 'spawned with --add-dir <cwd>');

    my ($snew) = grep { ($_->{event} // '') eq 'rpc' && ($_->{method} // '') eq 'session/new' } @$entries;
    ok($snew, 'fake-agy received session/new RPC');
    my $mcps = $snew->{params}{mcpServers} || [];
    is(scalar(@$mcps), 1, 'session/new sent 1 mcpServer entry');
    is($mcps->[0]{type}, 'http', 'mcpServers entry specifies type => http');
    is($mcps->[0]{name}, 'neoperl-editor', 'mcpServers entry specifies name => neoperl-editor');
    like($mcps->[0]{url}, qr{^http://127\.0\.0\.1:\d+/mcp$}, 'mcpServers url matches EditorMCP');
    is_deeply($mcps->[0]{headers}, [], 'mcpServers entry specifies headers => []');

    # Verify non-blocking stderr capture
    like($app->acp->last_stderr(), qr/fake-agy: initialize negotiated/, 'last_stderr captured non-blocking stderr lines');
    my $doc_res = $app->editor->exec_command(':AgyDoctor');
    ok($doc_res->{ok}, ':AgyDoctor executed cleanly');
    my $doc = $doc_res->{doctor};
    is($doc->{binary}, $fake_agy, 'doctor reports discovered binary');
    is($doc->{state}, 'ready', 'doctor reports state=ready');
    is($doc->{mock}, 0, 'doctor reports mock=0');
    is($doc->{current_model}, 'gemini-2.5-pro', 'doctor reports current_model');
    ok(@{ $doc->{stderr_tail} } >= 1, 'doctor exposes stderr_tail');
    like($doc->{mcp_url} // '', qr{^http://127\.0\.0\.1:\d+/mcp$}, 'doctor reports mcp_url');
    ok($doc->{mcp_tools} >= 14, 'doctor reports mcp_tools count');
    ok(length($doc->{next_action} // '') > 0, 'doctor provides actionable next_action');

    # Also verify :AgyStatus alias
    my $st_res = $app->editor->exec_command(':AgyStatus');
    ok($st_res->{ok} && $st_res->{doctor}{state} eq 'ready', ':AgyStatus returns diagnostic report');

    # Verify :AgyModel direct switch + Telescope picker
    my $m_res = $app->editor->exec_command(':AgyModel gemini-2.5-flash');
    ok($m_res->{ok}, ':AgyModel gemini-2.5-flash succeeded');
    is($app->acp->current_model, 'gemini-2.5-flash', 'session/set_model updated current_model');

    my $pick_res = $app->editor->exec_command(':AgyModel');
    ok($pick_res->{ok}, ':AgyModel without args opened picker');
    is($pick_res->{picker}, 'telescope', ':AgyModel opened Telescope model picker');
    ok($app->telescope->is_open, 'Telescope picker is open for models');
    $app->telescope->close();

    # Verify :AgyResume (session/load)
    my $load_res = $app->editor->exec_command(':AgyResume resumed-sess-99');
    ok($load_res->{ok}, ':AgyResume succeeded');
    is($app->acp->session_id, 'resumed-sess-99', 'session/load updated active session_id');

    # Verify :AgyNewSession
    my $ns_res = $app->editor->exec_command(':AgyNewSession');
    ok($ns_res->{ok}, ':AgyNewSession succeeded');
    like($app->acp->session_id, qr/^live-sess-/, ':AgyNewSession created fresh session');

    # Verify nested ACP 1.0 session/update + dynamic optionId permission resolution
    my @perms_received;
    my $allow_mode = 'a';
    $app->acp->set_callback('on_permission', sub {
        my ($perm) = @_;
        push @perms_received, $perm;
        $app->modalities->{active_perm} = $perm;
        $app->modalities->handle_permission_key($allow_mode);
    });

    my $chat_res = $app->editor->exec_command(':AgyChat Review buffer [perm_custom]');
    ok($chat_res->{ok}, ':AgyChat with custom permission completed');
    is($chat_res->{acp_result}{permOption}, 'allow_once_custom_id',
        'respond_permission resolved dynamic optionId (allow_once_custom_id) by kind=allow_once');
    is(scalar(@perms_received), 1, 'permission callback fired once');

    my $cs = $app->modalities->chat_state();
    ok(@{ $cs->{thoughts} } >= 1, 'nested agent_thought_chunk captured');
    like($cs->{thoughts}[-1]{text}, qr/Inspecting workspace context.*ready to respond/,
        'coalesced streaming thought chunks cleanly');
    ok(@{ $cs->{tool_cards} } >= 1 && $cs->{tool_cards}[-1]{status} eq 'completed',
        'nested tool_call + tool_call_update updated card status to completed');
    ok(@{ $cs->{plan} } == 2, 'nested plan entries captured');
    is($app->acp->current_mode, 'architect', 'nested current_mode_update tracked');
    is($app->acp->available_commands->[0]{name}, 'review', 'nested available_commands_update tracked');
    like($cs->{messages}[-1]{text}, qr/Live response on gemini-2\.5-flash/,
        'nested agent_message_chunk streamed into chat transcript');

    # Test reject dynamic optionId matching (reject_once_custom_id)
    $allow_mode = 'r';
    my $rej_res = $app->editor->exec_command(':AgyChat Reject test [perm_custom]');
    ok($rej_res->{ok}, ':AgyChat reject turn completed');
    is($rej_res->{acp_result}{permOption}, 'reject_once_custom_id',
        'respond_permission resolved dynamic optionId (reject_once_custom_id) by kind=reject_once');

    # Verify flat session/update backward compatibility
    my $norm_flat = $app->acp->normalize_session_update({
        sessionId     => 's1',
        sessionUpdate => 'agent_message_chunk',
        text          => 'Flat payload text',
    });
    is($norm_flat->{update}{sessionUpdate}, 'agent_message_chunk', 'flat update normalized into update.sessionUpdate');
    is($norm_flat->{update}{content}{text}, 'Flat payload text', 'flat update normalized into update.content.text');

    # Verify :AgyReconnect
    my $rec_res = $app->editor->exec_command(':AgyReconnect');
    ok($rec_res->{ok}, ':AgyReconnect started cleanly');
    ok(wait_until(sub { $app->editor->pump(); $app->acp->state eq 'ready' }, 6.0),
        ':AgyReconnect re-established live ready session');

    # Verify interactive chat composer input submission auto-streams response
    $app->modalities->focus_chat_input(1);
    for my $ch (split //, 'Hello live composer') {
        $app->ui->dispatch_event({ type => 'key', key => $ch });
    }
    is($app->modalities->chat_input, 'Hello live composer', 'typing in CHAT tab fills composer input');
    $app->ui->dispatch_event({ type => 'key', key => '<CR>' });
    is($app->modalities->chat_input, '', 'pressing <CR> clears composer and submits prompt');
    ok(wait_until(sub {
        $app->editor->pump();
        my $msgs = $app->modalities->chat_state->{messages};
        return @$msgs && ($msgs->[-1]{role} // '') eq 'assistant' && ($msgs->[-1]{text} // '') =~ /Hello live composer/;
    }, 6.0), 'composer prompt streamed live assistant reply asynchronously');

    $app->shutdown();
};

# ---------------------------------------------------------------------------
# 2. Auth-Required Lifecycle: auth_required -> AGY:LOGIN -> authenticate -> AGY:LIVE
# ---------------------------------------------------------------------------
subtest 'Auth-required lifecycle (AGY:LOGIN -> authenticate RPC & :AgyLogin! terminal)' => sub {
    clear_log();
    unlink $auth_flag if -f $auth_flag;
    local $ENV{NEOPERL_AGY_BIN}       = $fake_agy;
    local $ENV{FAKE_AGY_LOG}          = $log_file;
    local $ENV{FAKE_AGY_AUTH_FILE}    = $auth_flag;
    local $ENV{FAKE_AGY_REQUIRE_AUTH} = 1;

    my $app = NeoPerl::MT->new(
        cwd         => $ws,
        ui          => 'tui',
        headless    => 1,
        cols        => 132,
        rows        => 40,
        load_config => 0,
    );

    ok(wait_until(sub { $app->editor->pump(); $app->acp->state eq 'auth_required' }, 6.0),
        'unauthenticated session/new (-32000) transitions cleanly to state=auth_required without crashing');

    is($app->modalities->acp_status_pill->{label}, 'AGY:LOGIN', 'pill switches to AGY:LOGIN');
    $app->editor->layout->open_command_center('chat');
    $app->ui->render_frame();
    my $scr = $app->ui->screen_text();
    like($scr, qr/AGY:LOGIN/, 'TUI renders AGY:LOGIN pill');
    like($scr, qr/Run :AgyLogin or <leader>aL to sign in/, 'CHAT tab renders actionable 2-line login card');

    # :AgyLogin uses authenticate RPC when authMethods advertised -> creates session -> AGY:LIVE
    my $login_res = $app->editor->exec_command(':AgyLogin');
    ok($login_res->{ok}, ':AgyLogin succeeded via authenticate RPC');
    is($login_res->{method}, 'authenticate_rpc', ':AgyLogin used ACP authenticate RPC');
    is($app->acp->state, 'ready', 'state transitioned from auth_required -> ready');
    is($app->modalities->acp_status_pill->{label}, 'AGY:LIVE', 'pill transitioned from AGY:LOGIN -> AGY:LIVE');

    my $entries = read_log_entries();
    my ($auth_ev) = grep { ($_->{event} // '') eq 'authenticated' } @$entries;
    ok($auth_ev && $auth_ev->{methodId} eq 'google-oauth', 'fake-agy received authenticate(methodId => google-oauth)');

    # Test :AgyLogin! embedded PTY terminal split running `agy acp --login` -> auto-reconnect
    unlink $auth_flag if -f $auth_flag;
    my $tlogin = $app->editor->exec_command(':AgyLogin!');
    ok($tlogin->{ok}, ':AgyLogin! launched embedded terminal split');
    is($tlogin->{method}, 'terminal', ':AgyLogin! opened terminal method');
    ok(wait_until(sub { $app->editor->pump(); -f $auth_flag && $app->acp->state eq 'ready' }, 6.0),
        ':AgyLogin! terminal completed `agy acp --login` and auto-reconnected ACP -> ready');

    $app->shutdown();
};

# ---------------------------------------------------------------------------
# 3. Offline / Setup / Mock / Sandbox / Model / CLI Flags Coverage
# ---------------------------------------------------------------------------
subtest 'AGY:SETUP, AGY:OFF, AGY:MOCK, --agy-sandbox, --agy-model, :AgyInstall, and bin/npl CLI flags' => sub {
    # 3a. Not installed -> AGY:SETUP + CHAT offline onboarding card + :AgyInstall
    {
        local $ENV{NEOPERL_AGY_NO_DISCOVER} = 1;
        local $ENV{NEOPERL_AGY_BIN}         = '';
        is(NeoPerl::Antigravity::ACP::discover_agy_binary(), undef, 'discover_agy_binary returns undef when unavailable');

        my $app = NeoPerl::MT->new(
            cwd         => $ws,
            ui          => 'tui',
            headless    => 1,
            cols        => 132,
            rows        => 40,
            start_mcp   => 0,
            load_config => 0,
        );
        is($app->acp->state, 'offline', 'missing agy leaves ACP cleanly offline');
        is($app->modalities->acp_status_pill->{label}, 'AGY:SETUP', 'pill displays AGY:SETUP when agy not installed');

        $app->editor->layout->open_command_center('chat');
        $app->ui->render_frame();
        my $scr = $app->ui->screen_text();
        like($scr, qr/AGY:SETUP/, 'TUI renders AGY:SETUP pill');
        like($scr, qr/Run :AgyInstall or npl --agy-mock/, 'CHAT tab renders actionable offline card');

        my $ins = $app->editor->exec_command(':AgyInstall');
        ok($ins->{ok}, ':AgyInstall succeeded');
        like($ins->{command}, qr{curl -fsSL https://antigravity\.google/cli/install\.sh \| bash},
            ':AgyInstall exposes official install command');
        $app->shutdown();
    }

    # 3b. --no-agy -> AGY:OFF even when binary exists
    {
        clear_log();
        local $ENV{NEOPERL_AGY_BIN} = $fake_agy;
        local $ENV{FAKE_AGY_LOG}    = $log_file;
        my $app = NeoPerl::MT->new(
            cwd         => $ws,
            ui          => 'tui',
            headless    => 1,
            no_agy      => 1,
            start_mcp   => 0,
            load_config => 0,
        );
        is($app->acp->state, 'offline', 'no_agy keeps ACP offline');
        is($app->modalities->acp_status_pill->{label}, 'AGY:OFF', 'no_agy pill displays AGY:OFF');
        is(scalar(@{ read_log_entries() }), 0, 'no_agy never spawns agy');
        $app->shutdown();
    }

    # 3c. --agy-mock -> AGY:MOCK
    {
        my $app = NeoPerl::MT->new(
            cwd         => $ws,
            ui          => 'tui',
            headless    => 1,
            agy_mock    => 1,
            start_mcp   => 0,
            load_config => 0,
        );
        is($app->acp->state, 'ready', 'agy_mock reaches state=ready');
        is($app->modalities->acp_status_pill->{label}, 'AGY:MOCK', 'agy_mock pill displays AGY:MOCK');
        $app->shutdown();
    }

    # 3d. --agy-sandbox + --agy-model passed through on live auto-connect
    {
        clear_log();
        local $ENV{NEOPERL_AGY_BIN}       = $fake_agy;
        local $ENV{FAKE_AGY_LOG}          = $log_file;
        local $ENV{FAKE_AGY_REQUIRE_AUTH} = 0;
        my $app = NeoPerl::MT->new(
            cwd         => $ws,
            ui          => 'none',
            agy_sandbox => 1,
            agy_model   => 'gemini-2.5-ultra',
            start_mcp   => 0,
            load_config => 0,
        );
        ok(wait_until(sub { $app->editor->pump(); $app->acp->state eq 'ready' }, 6.0),
            'sandbox + preferred model auto-connect reached ready');
        is($app->acp->current_model, 'gemini-2.5-ultra', 'agy_model automatically selected on connect');
        my ($spawn) = grep { ($_->{event} // '') eq 'spawn' } @{ read_log_entries() };
        like(join(' ', @{ $spawn->{argv} || [] }), qr/--sandbox/, 'agy_sandbox passed --sandbox to agy acp');
        $app->shutdown();
    }

    # 3e. bin/npl CLI flags: --agy-login and --no-agy --info
    {
        my @inc_args = map { ("-I$_") } grep { defined $_ && !ref($_) && -d $_ } @INC;
        my $bin_npl  = File::Spec->catfile($ROOT, 'bin', 'npl');

        my $run_cli = sub {
            my (@args) = @_;
            my ($ofh, $ofile) = tempfile(UNLINK => 1);
            my ($efh, $efile) = tempfile(UNLINK => 1);
            close $ofh;
            close $efh;
            my $pid = fork();
            die "fork failed: $!" unless defined $pid;
            if ($pid == 0) {
                open STDOUT, '>', $ofile or exit 126;
                open STDERR, '>', $efile or exit 126;
                exec $^X, @inc_args, $bin_npl, @args;
                exit 127;
            }
            waitpid($pid, 0);
            my $st  = $?;
            my $out = do { local $/; open my $f, '<', $ofile; <$f> // '' };
            my $err = do { local $/; open my $f, '<', $efile; <$f> // '' };
            return ($st, $out, $err);
        };

        unlink $auth_flag if -f $auth_flag;
        local $ENV{NEOPERL_AGY_BIN}    = $fake_agy;
        local $ENV{FAKE_AGY_LOG}       = $log_file;
        local $ENV{FAKE_AGY_AUTH_FILE} = $auth_flag;

        my ($st1, $out1, $err1) = $run_cli->('--agy-login');
        is($st1, 0, 'bin/npl --agy-login exited 0');
        is($err1, '', 'bin/npl --agy-login emitted zero stderr') or diag($err1);
        like($out1, qr/Signed in to Antigravity/, 'bin/npl --agy-login ran agy acp --login');
        ok(-f $auth_flag, 'bin/npl --agy-login executed fake-agy acp --login');

        my ($st2, $out2, $err2) = $run_cli->('--no-agy', '--info');
        is($st2, 0, 'bin/npl --no-agy --info exited 0');
        is($err2, '', 'bin/npl --no-agy --info emitted zero stderr') or diag($err2);
        like($out2, qr/Antigravity:\s+AGY:OFF/, 'bin/npl --no-agy --info reports AGY:OFF');
    }
};

done_testing();
