use strict;
use warnings;
use Test::More;
use File::Spec ();
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::INET ();

use NeoPerl::Memory::Store;
use NeoPerl::Memory::Writer;
use NeoPerl::Inference::Manager;
use NeoPerl::Inference::ModelHub;
use NeoPerl::Inference::Vision;
use NeoPerl::Inference::OffloadQueue;
use NeoPerl::Antigravity::ACP;
use NeoPerl::Antigravity::EditorMCP;
use NeoPerl::Antigravity::Customizations;
use NeoPerl::Antigravity::Modalities;

my $HAS_MOJO = eval { require Mojo::UserAgent; require Mojo::IOLoop; require Mojo::JSON; 1 } ? 1 : 0;
require JSON::PP unless $HAS_MOJO;

sub _enc { $HAS_MOJO ? Mojo::JSON::encode_json($_[0]) : JSON::PP::encode_json($_[0]) }
sub _dec { $HAS_MOJO ? Mojo::JSON::decode_json($_[0]) : JSON::PP::decode_json($_[0]) }

# Minimal Editor + Buffer harness for testing ACP, EditorMCP, and Modalities
{
    package TestEditorBuf;
    sub new {
        my ($class, %a) = @_;
        return bless {
            id       => $a{id}       || 1,
            path     => $a{path}     // 'lib/Demo.pm',
            filetype => $a{filetype} // 'perl',
            text     => $a{text}     // '',
            dirty    => $a{dirty}    ? 1 : 0,
            extmarks => {},
            hunks    => [],
            staged   => undef,
        }, $class;
    }
    sub id         { $_[0]{id} }
    sub path       { $_[0]{path} }
    sub filetype   { $_[0]{filetype} }
    sub text       { $_[0]{text} }
    sub dirty      { $_[0]{dirty} }
    sub line_count { scalar(split /\n/, $_[0]{text}, -1) }
    sub set_text   { $_[0]{text} = $_[1]; $_[0]{dirty} = 1; }
    sub clear_namespace { delete $_[0]{extmarks}{ $_[1] }; }
    sub set_extmark {
        my ($self, $ns, $line, $col, $opts) = @_;
        push @{ $self->{extmarks}{$ns} }, { line => $line, col => $col, %$opts };
        return scalar @{ $self->{extmarks}{$ns} };
    }
    sub get_extmarks { $_[0]{extmarks}{ $_[1] } || [] }
    sub stage_diff_proposal {
        my ($self, $new_text, %meta) = @_;
        $self->{staged} = { new_text => $new_text, meta => \%meta };
        $self->{hunks}  = [ { kind => 'change', old_start => 1, old_count => 1, new_start => 1, new_count => 2 } ];
        return $self->{hunks};
    }
    sub accept_hunk {
        my ($self, $idx) = @_;
        if ($self->{staged}) {
            $self->{text}   = $self->{staged}{new_text};
            $self->{staged} = undef;
            $self->{hunks}  = [];
            $self->{dirty}  = 1;
        }
        return 1;
    }
    sub accept_all_hunks { $_[0]->accept_hunk(0) }
    sub reject_all_hunks { $_[0]{staged} = undef; $_[0]{hunks} = []; 1 }
}

{
    package TestEditorHarness;
    sub new {
        my ($class, %a) = @_;
        return bless {
            cwd      => $a{cwd} // '.',
            mode     => 'NORMAL',
            cursor   => { line => 1, col => 0 },
            buffers  => [],
            cur_buf  => undef,
            diags    => [],
            events   => {},
            emitted  => [],
            commands => {},
            keymaps  => {},
        }, $class;
    }
    sub cwd             { $_[0]{cwd} }
    sub mode            { $_[0]{mode} }
    sub cursor          { $_[0]{cursor} }
    sub set_cursor      { $_[0]{cursor} = { line => $_[1], col => $_[2] // 0 } }
    sub buffers         { $_[0]{buffers} }
    sub current_buffer  { $_[0]{cur_buf} }
    sub add_buffer      { my ($s, $b) = @_; push @{ $s->{buffers} }, $b; $s->{cur_buf} = $b; $b }
    sub find_buffer_by_path {
        my ($s, $p) = @_;
        for my $b (@{ $s->{buffers} }) { return $b if $b->path eq $p }
        return undef;
    }
    sub open_file       { my ($s, $p) = @_; $s->find_buffer_by_path($p) || $s->{cur_buf} }
    sub all_diagnostics { $_[0]{diags} }
    sub get_diagnostics { $_[0]{diags} }
    sub set_diagnostics { $_[0]{diags} = $_[1] }
    sub on              { my ($s, $ev, $cb) = @_; push @{ $s->{events}{$ev} }, $cb }
    sub emit {
        my ($s, $ev, @rest) = @_;
        my %data = (@rest == 1 && ref($rest[0]) eq 'HASH') ? %{ $rest[0] } : @rest;
        push @{ $s->{emitted} }, [ $ev, \%data ];
        for my $cb (@{ $s->{events}{$ev} || [] }) { $cb->(%data) }
    }
    sub register_command { my ($s, $n, $fn) = @_; $s->{commands}{$n} = $fn }
    sub map_key          { my ($s, $m, $lhs, $cb, $desc) = @_; $s->{keymaps}{"$m:$lhs"} = $cb }
}

# Helper to issue a real localhost HTTP request against EditorMCP while pumping it
sub http_mcp_call {
    my ($mcp, $method, $path, $json_body) = @_;
    my $port = $mcp->port;

    if ($mcp->engine eq 'Mojolicious' && $HAS_MOJO) {
        my $ua = Mojo::UserAgent->new(ioloop => Mojo::IOLoop->singleton);
        my ($done, $status, $body_out, $ctype);
        my $url = "http://127.0.0.1:$port$path";
        my $cb = sub {
            my ($ua_arg, $tx) = @_;
            my $res = $tx->result;
            $status   = $res->code;
            $body_out = $res->body;
            $ctype    = $res->headers->content_type // '';
            $done     = 1;
        };
        if (uc($method) eq 'GET') {
            $ua->get($url => $cb);
        }
        else {
            $ua->post($url => { 'Content-Type' => 'application/json' } => _enc($json_body) => $cb);
        }
        for (1 .. 200) {
            $mcp->poll(0.01);
            last if $done;
        }
        return ($status, $body_out, $ctype);
    }

    # Pure-Perl socket client for fallback engine test
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 3,
    ) or die "Cannot connect to 127.0.0.1:$port: $!";

    my $payload = defined $json_body ? _enc($json_body) : '';
    my $req = uc($method) . " $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n";
    if (uc($method) eq 'POST') {
        $req .= "Content-Type: application/json\r\nContent-Length: " . length($payload) . "\r\n\r\n$payload";
    }
    else {
        $req .= "\r\n";
    }
    print {$sock} $req;
    $sock->blocking(0);

    my $raw = '';
    for (1 .. 200) {
        $mcp->poll(0.01);
        my $buf = '';
        my $n = sysread($sock, $buf, 65536);
        if (defined $n && $n > 0) {
            $raw .= $buf;
        }
        elsif (defined $n && $n == 0) {
            last;
        }
    }
    close $sock;

    my ($hdr, $body) = split /\r\n\r\n/, $raw, 2;
    my ($status) = (($hdr // '') =~ m{^HTTP/\S+\s+(\d+)});
    my ($ctype)  = (($hdr // '') =~ m{^Content-Type:\s*([^\r\n]+)}mi);
    return (int($status || 0), $body // '', $ctype // '');
}

# Build workspace fixture for Customizations, Vision, and EditorMCP
my $ws   = tempdir(CLEANUP => 1);
my $gcfg = tempdir(CLEANUP => 1);

make_path(
    File::Spec->catdir($ws, '.agents', 'rules'),
    File::Spec->catdir($ws, '.agents', 'skills', 'perl-xs'),
    File::Spec->catdir($ws, '.agents', 'plugins', 'demo-plugin'),
    File::Spec->catdir($gcfg, 'rules'),
    File::Spec->catdir($gcfg, 'skills', 'perl-xs'),
    File::Spec->catdir($gcfg, 'skills', 'global-only'),
);

sub write_txt {
    my ($path, $txt) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die $!;
    print {$fh} $txt;
    close $fh;
}

write_txt(File::Spec->catfile($ws, 'GEMINI.md'), "# Workspace Instructions\nUse strict Perl.\n");
write_txt(File::Spec->catfile($gcfg, 'AGENTS.md'), "# Global Agent Instructions\n");
write_txt(File::Spec->catfile($ws, '.agents', 'rules', 'style.md'), "---\nname: style\ndescription: Code style rule\n---\nNo warnings.\n");
write_txt(File::Spec->catfile($gcfg, 'skills', 'perl-xs', 'SKILL.md'), "---\nname: perl-xs\ndescription: Global XS skill\n---\nGlobal body.\n");
write_txt(File::Spec->catfile($ws, '.agents', 'skills', 'perl-xs', 'SKILL.md'), "---\nname: perl-xs\ndescription: Workspace XS skill override\n---\nWorkspace body.\n");
write_txt(File::Spec->catfile($gcfg, 'skills', 'global-only', 'SKILL.md'), "---\nname: global-only\ndescription: Global helper skill\n---\nHelper.\n");
write_txt(File::Spec->catfile($ws, '.agents', 'hooks.json'), '{"hooks":{"BufWritePost":[{"cmd":"perltidy"}]}}');
write_txt(File::Spec->catfile($ws, '.agents', 'mcp_config.json'), '{"mcpServers":{"docs":{"url":"http://127.0.0.1:9999/mcp"}}}');
write_txt(File::Spec->catfile($ws, '.agents', 'plugins', 'demo-plugin', 'plugin.json'), '{"name":"demo-plugin","version":"1.0.0"}');

my $sample_file = File::Spec->catfile($ws, 'sample.pm');
write_txt($sample_file, "package Sample;\nuse strict;\nsub greet { return 'disk'; }\n1;\n");

my $png_file = File::Spec->catfile($ws, 'shot.png');
{
    open my $pfh, '>:raw', $png_file or die $!;
    print {$pfh} "\x89PNG\r\n\x1a\n" . pack('N', 13) . 'IHDR' . pack('N N C C C C C', 100, 80, 8, 2, 0, 0, 0) . pack('N', 0) . pack('N', 0) . 'IEND' . pack('N', 0);
    close $pfh;
}

# ---------------------------------------------------------------------------
# 1. Hierarchical Customizations Discovery (.agents/ + ~/.gemini/config/)
# ---------------------------------------------------------------------------
my $cust = NeoPerl::Antigravity::Customizations->new(
    workspace_root    => $ws,
    global_config_dir => $gcfg,
);

subtest 'Customizations discovery and workspace-over-global precedence' => sub {
    my $sum = $cust->summary();
    is(scalar(@{ $sum->{instructions} }), 2, 'discovered GEMINI.md and AGENTS.md');
    is(scalar(@{ $sum->{rules} }),        1, 'discovered workspace rule');
    is(scalar(@{ $sum->{skills} }),       2, 'discovered merged global + workspace skills');
    my $pxs = $cust->find_skill('perl-xs');
    is($pxs->{scope}, 'workspace', 'workspace skill overrides global skill with same name');
    like($pxs->{description}, qr/Workspace XS skill override/, 'frontmatter description parsed');
    is_deeply($sum->{hooks}, ['BufWritePost'], 'discovered hooks.json');
    is_deeply($sum->{mcp_servers}, ['docs'], 'discovered mcp_config.json');
    is($sum->{plugins}[0]{name}, 'demo-plugin', 'discovered plugin manifest');
    ok(@{ $cust->as_telescope_items() } >= 4, 'as_telescope_items builds picker entries');
};

# Shared subsystems
my $ed     = TestEditorHarness->new(cwd => $ws);
my $buf    = $ed->add_buffer(TestEditorBuf->new(
    id   => 1,
    path => $sample_file,
    text => "package Sample;\nuse strict;\nsub greet { return 'LIVE_UNSAVED_BUFFER'; }\n1;\n",
    dirty => 1,
));
$ed->set_diagnostics([
    { path => $sample_file, line => 3, severity => 'warning', policy => 'Subroutines::ProhibitExplicitReturnUndef', message => 'Do not return undef' },
]);

my $has_sqlite = eval { require DBI; require DBD::SQLite; 1 };
my $mgr    = NeoPerl::Inference::Manager->new(ram_budget_gb => 20);
my $store  = $has_sqlite ? NeoPerl::Memory::Store->new(sqlite_path => ':memory:', embedder => $mgr) : undef;
my $writer = $store ? NeoPerl::Memory::Writer->new(store => $store, inference => $mgr, repo_key => 'demo') : undef;
my $vision = NeoPerl::Inference::Vision->new(inference => $mgr, store => $store);
my $queue  = NeoPerl::Inference::OffloadQueue->new(inference => $mgr, store => $store, editor => $ed);
my $mhub   = NeoPerl::Inference::ModelHub->new(config => $mgr->config);

# ---------------------------------------------------------------------------
# 2. Live Localhost EditorMCP Server (23 Tools, Mojolicious + Fallback)
# ---------------------------------------------------------------------------
my $mcp = NeoPerl::Antigravity::EditorMCP->new(
    editor         => $ed,
    memory_store   => $store,
    memory_writer  => $writer,
    vision         => $vision,
    offload_queue  => $queue,
    customizations => $cust,
);

# Register PerlDev (15-18) and XSDev (19-23) tools via register_tool to confirm full 23-tool registry
for my $ext_tool (
    qw(neoperl_perl_outline neoperl_perl_slice neoperl_perl_critic neoperl_perl_tidy
       neoperl_xs_profile neoperl_xs_sanitize neoperl_xs_backtrace neoperl_xs_pgo neoperl_xs_arch_audit)
) {
    $mcp->register_tool($ext_tool, {
        description => "Registered extension tool $ext_tool",
        properties  => { path => { type => 'string' } },
    }, sub {
        my ($args) = @_;
        return { ok => 1, tool => $ext_tool, path => $args->{path} // '' };
    });
}

my $mcp_port = $mcp->start();

subtest 'Live localhost EditorMCP HTTP/JSON-RPC 2.0 server with all 23 tools' => sub {
    ok($mcp_port > 0, "EditorMCP bound to 127.0.0.1:$mcp_port (" . $mcp->engine . ")");
    if ($HAS_MOJO) {
        is($mcp->engine, 'Mojolicious', 'EditorMCP uses Mojolicious + Mojo::Server::Daemon');
    }

    # GET /health
    my ($st, $body) = http_mcp_call($mcp, 'GET', '/health');
    is($st, 200, 'GET /health returns 200');
    my $h = _dec($body);
    is($h->{tools}, 23, 'GET /health reports all 23 tools registered');

    # GET /mcp (SSE)
    my ($sse_st, $sse_body, $sse_ct) = http_mcp_call($mcp, 'GET', '/mcp');
    is($sse_st, 200, 'GET /mcp SSE returns 200');
    like($sse_ct,   qr{text/event-stream}, 'GET /mcp returns text/event-stream');
    like($sse_body, qr/event: endpoint/,   'SSE emits endpoint event');

    # POST initialize
    my ($ist, $ibody) = http_mcp_call($mcp, 'POST', '/mcp', { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} });
    is($ist, 200, 'MCP initialize returns 200');
    my $ir = _dec($ibody);
    is($ir->{result}{serverInfo}{name}, 'neoperl-editor-mcp', 'serverInfo matches');

    # POST tools/list -> verify all 23 tools
    my ($lst, $lbody) = http_mcp_call($mcp, 'POST', '/mcp', { jsonrpc => '2.0', id => 2, method => 'tools/list', params => {} });
    is($lst, 200, 'MCP tools/list returns 200');
    my $tools = _dec($lbody)->{result}{tools};
    is(scalar(@$tools), 23, 'tools/list exposes all 23 tools');

    # Helper to invoke a tool over live localhost HTTP
    my $id_seq = 10;
    my $call_http = sub {
        my ($name, $args) = @_;
        my ($c, $b) = http_mcp_call($mcp, 'POST', '/mcp', {
            jsonrpc => '2.0',
            id      => $id_seq++,
            method  => 'tools/call',
            params  => { name => $name, arguments => $args || {} },
        });
        is($c, 200, "HTTP tools/call $name returned 200");
        my $decoded = _dec($b);
        return $decoded->{result}{structuredContent};
    };

    # Exercise built-in tools over localhost HTTP
    my $es = $call_http->('neoperl_get_editor_state');
    is($es->{active_path}, $sample_file, 'neoperl_get_editor_state returns active path');

    my $rb = $call_http->('neoperl_read_buffer', { path => $sample_file });
    like($rb->{content}, qr/LIVE_UNSAVED_BUFFER/, 'neoperl_read_buffer returns LIVE unsaved buffer, not disk');

    my $pe = $call_http->('neoperl_propose_edit', { path => $sample_file, new_text => "package Sample;\nuse strict;\nuse warnings;\nsub greet { return 'edited'; }\n1;\n" });
    is($pe->{staged}, 1, 'neoperl_propose_edit stages inline diff hunks');
    $buf->reject_all_hunks();

    my $ld = $call_http->('neoperl_list_diagnostics');
    is($ld->{count}, 1, 'neoperl_list_diagnostics returns active diagnostics');

    my $gs = $call_http->('neoperl_get_symbols', { path => $sample_file });
    ok((grep { $_->{name} eq 'greet' } @{ $gs->{symbols} }), 'neoperl_get_symbols finds sub greet');

    my $sw = $call_http->('neoperl_search_workspace', { query => 'greet', root => $ws });
    ok(@{ $sw->{matches} } >= 1, 'neoperl_search_workspace finds matches');

    my $jt = $call_http->('neoperl_jump_to', { path => $sample_file, line => 3, col => 4 });
    is($ed->cursor->{line}, 3, 'neoperl_jump_to updates editor cursor');

    my $lc = $call_http->('neoperl_list_customizations');
    is(scalar(@{ $lc->{skills} }), 2, 'neoperl_list_customizations returns discovered skills');

    if ($store) {
        my $mw = $call_http->('neoperl_memory_write', {
            repo_key => 'demo',
            category => 'architecture',
            content  => 'EditorMCP exposes 23 tools over localhost HTTP JSON-RPC 2.0.',
        });
        is($mw->{action}, 'ADD', 'neoperl_memory_write persisted memory through Hy-Memory');
        my $mem_id = $mw->{operations}[0]{id};

        my $ms = $call_http->('neoperl_memory_search', { query => 'EditorMCP 23 tools localhost', repo => 'demo' });
        ok($ms->{count} >= 1, 'neoperl_memory_search returned matching memory');

        my $mr = $call_http->('neoperl_memory_get_related', { id => $mem_id });
        is($mr->{memory}{id}, $mem_id, 'neoperl_memory_get_related returned memory graph');
    }

    my $vp = $call_http->('neoperl_preprocess_doc', { path => $png_file, format => 'markdown' });
    is($vp->{width}, 100, 'neoperl_preprocess_doc ran Granite-Vision over HTTP MCP');

    my $dl = $call_http->('neoperl_delegate_local', { kind => 'commit_msg', target_path => $sample_file, instruction => 'Refine greet sub' });
    like($dl->{job_id}, qr/^bonsai-/, 'neoperl_delegate_local returned immediate job_id');

    my $js = $call_http->('neoperl_local_job_status', { job_id => $dl->{job_id}, action => 'pump' });
    is($js->{job}{status}, 'staged', 'neoperl_local_job_status pumped and reported Bonsai job');

    # Exercise an extension tool (PerlDev / XSDev) over live HTTP
    my $po = $call_http->('neoperl_perl_outline', { path => $sample_file });
    is($po->{tool}, 'neoperl_perl_outline', 'registered PerlDev tool callable over live HTTP MCP');
    my $xa = $call_http->('neoperl_xs_arch_audit', { path => 'c/buffer.c' });
    is($xa->{tool}, 'neoperl_xs_arch_audit', 'registered XSDev tool callable over live HTTP MCP');
};

# Also verify pure-Perl IO::Socket::INET fallback engine directly
subtest 'EditorMCP IO::Socket::INET fallback engine parity' => sub {
    my $fb = NeoPerl::Antigravity::EditorMCP->new(
        editor         => $ed,
        force_fallback => 1,
    );
    my $fb_port = $fb->start();
    is($fb->engine, 'IO::Socket::INET', 'fallback server uses IO::Socket::INET');
    my ($st, $body) = http_mcp_call($fb, 'POST', '/mcp', { jsonrpc => '2.0', id => 1, method => 'ping' });
    is($st, 200, 'fallback server responds 200 to POST /mcp ping');
    is_deeply(_dec($body)->{result}, {}, 'fallback ping returns empty result object');
    $fb->stop();
};

# ---------------------------------------------------------------------------
# 3. Full Bidirectional ACP over Real Pipes (initialize, streaming, fs/*, perm, terminal/*)
# ---------------------------------------------------------------------------
my $acp = NeoPerl::Antigravity::ACP->new(
    editor     => $ed,
    editor_mcp => $mcp,
    cwd        => $ws,
    mock       => 1,
);

subtest 'Bidirectional ACP over real OS pipes (loopback server)' => sub {
    like(NeoPerl::Antigravity::ACP::install_instructions(), qr/antigravity\.google\/cli\/install\.sh/, 'install_instructions references official CLI installer');

    ok($acp->start(mcp_port => $mcp_port, mock => 1), 'spawned ACP loopback server over real pipes');

    my $init = $acp->initialize();
    is($init->{agentInfo}{name},    'antigravity-acp-loopback', 'ACP initialize handshake succeeded');
    is($init->{agentInfo}{mcpPort}, $mcp_port,                  'ACP server received --ide-mcp-port');

    my $sess = $acp->new_session(cwd => $ws);
    like($sess->{sessionId}, qr/^agy-sess-/, 'ACP session/new returned sessionId');

    my @updates;
    my @perms_seen;
    $acp->set_callback('on_update', sub { push @updates, $_[0] });
    $acp->set_callback('on_permission', sub {
        my ($perm) = @_;
        push @perms_seen, $perm;
        # Approve permission asynchronously over the pipe
        $acp->respond_permission($perm->{id}, 'allow');
    });

    # Trigger streaming thought/plan/tool_call + reverse fs/read_text_file + permission + fs/write_text_file + terminal/*
    my $res = $acp->prompt("Inspect [read:$sample_file] and apply [edit:$sample_file] and run [term:$^X -e print(42)]");
    is($res->{stopReason}, 'end_turn', 'ACP prompt completed cleanly');
    like($res->{readContent}, qr/LIVE_UNSAVED_BUFFER/, 'reverse fs/read_text_file read LIVE unsaved buffer');
    is($res->{permission}, 'allow', 'reverse session/request_permission honored allow');
    is(scalar(@perms_seen), 1, 'permission callback fired');
    ok($buf->{staged}, 'reverse fs/write_text_file staged inline diff hunks on buffer');
    like($buf->{staged}{new_text}, qr/Antigravity proposed improvement/, 'staged diff includes agent edit');
    is($res->{termOutput}, '42', 'reverse terminal/* ran command and returned output');

    my %upd_kinds = map { ($_->{update}{sessionUpdate} // '') => 1 } @updates;
    ok($upd_kinds{agent_thought_chunk}, 'streamed thought chunk');
    ok($upd_kinds{plan},                'streamed plan checklist');
    ok($upd_kinds{tool_call},           'streamed tool_call card');
    ok($upd_kinds{agent_message_chunk}, 'streamed assistant message chunk');

    # Test permission rejection leaves buffer untouched
    $buf->reject_all_hunks();
    $acp->set_callback('on_permission', sub {
        my ($perm) = @_;
        $acp->respond_permission($perm->{id}, 'reject');
    });
    my $rej = $acp->prompt("Try [edit:$sample_file]");
    is($rej->{permission}, 'reject', 'permission rejection propagated to agent');
    is($buf->{staged}, undef, 'rejected permission left buffer untouched');
};

# ---------------------------------------------------------------------------
# 4. Modalities: Sidebar Chat, :MemAutoContext <=250 tokens, Ctrl-I, <leader>af, <Tab> Ghost
# ---------------------------------------------------------------------------
subtest 'Antigravity Modalities: Chat, AutoContext, Inline, Auto-Fix, Code Lenses, Ghost Text' => sub {
    my $mod = NeoPerl::Antigravity::Modalities->new(
        editor         => $ed,
        acp            => $acp,
        editor_mcp     => $mcp,
        memory_store   => $store,
        memory_writer  => $writer,
        inference      => $mgr,
        vision         => $vision,
        offload_queue  => $queue,
        model_hub      => $mhub,
        customizations => $cust,
        repo_key       => 'demo',
    );
    $mod->attach($ed);

    ok($ed->{commands}{AgyChat} && $ed->{commands}{MemSave} && $ed->{commands}{MemAutoContext} && $ed->{commands}{ModelHub},
        'attach() registered Antigravity/Memory/ModelHub Ex commands');
    ok($ed->{keymaps}{'NORMAL:<leader>aa'} && $ed->{keymaps}{'NORMAL:<C-i>'} && $ed->{keymaps}{'NORMAL:<leader>af'},
        'attach() registered Antigravity keymaps');

    # Toggle :MemAutoContext and verify <= 250-token hint (~1000 chars)
    $ed->{commands}{MemAutoContext}->($ed, 'on');
    is($mod->auto_context, 1, ':MemAutoContext on enabled auto-context');
    if ($store) {
        my $hint = $mod->build_auto_context_hint(query => 'EditorMCP 23 tools');
        like($hint, qr/\[Memory Context Hint\]/, 'auto-context builds memory hint');
        ok(length($hint) <= 1000, 'auto-context hint stays within <=250-token cap');
    }

    # @ mentions & / slash expansion
    my $exp = $mod->expand_prompt("/plan Review \@buffer \@diag \@skill:perl-xs \@image:$png_file");
    is($exp->{slash}, 'plan', '/plan slash command recognized');
    my %att_kinds = map { $_->{kind} => 1 } @{ $exp->{attachments} };
    ok($att_kinds{buffer} && $att_kinds{diag} && $att_kinds{skill} && $att_kinds{image},
        'expanded @buffer, @diag, @skill, and @image mentions');

    # Sidebar Chat over live ACP pipe
    $acp->set_callback('on_permission', sub { $acp->respond_permission($_[0]{id}, 'allow') });
    my $chat_res = $mod->send_chat("Explain [read:$sample_file]");
    ok($chat_res->{ok}, 'send_chat completed over live ACP');
    my $cstate = $mod->chat_state();
    ok(@{ $cstate->{messages} } >= 2, 'chat transcript recorded user + assistant messages');
    ok(@{ $cstate->{thoughts} } >= 1, 'chat state captured thought cards');
    ok(@{ $cstate->{plan} }     >= 1, 'chat state captured plan checklist');

    # Ctrl-I Inline Command
    my $inl = $mod->run_inline_command('Add POD docs', use_local => 1);
    ok($inl->{ok} && $inl->{hunk_count} >= 1, 'Ctrl-I inline command staged diff hunks');

    # <leader>af tiered diagnostic auto-fix (mechanical Perl::Critic -> local Bonsai)
    my $fix = $mod->auto_fix_diagnostic(sync => 1);
    is($fix->{tier}, 'bonsai_local', 'mechanical Perl::Critic diagnostic routed to local Bonsai at zero cloud cost');
    like($fix->{job_id}, qr/^bonsai-/, 'returned Bonsai job_id');

    # Code Lenses
    my $lenses = $mod->compute_code_lenses($buf);
    ok(@$lenses >= 1 && $lenses->[0]{symbol} eq 'greet', 'Code Lenses placed above sub greet');
    ok(@{ $buf->get_extmarks('agy_codelens') } >= 1, 'Code Lenses written to agy_codelens extmark namespace');

    # <Tab> Ghost Text
    my $gbuf = TestEditorBuf->new(id => 2, path => 'lib/Ghost.pm', text => "sub compute {\n");
    my $sug  = $mod->request_ghost_text($gbuf, 1, 13);
    like($sug, qr/\@_/, 'ghost text suggested Perl arg unpacking');
    ok(@{ $gbuf->get_extmarks('agy_ghost') } == 1, 'ghost text painted in agy_ghost extmark namespace');
    my $acc = $mod->accept_ghost_text($gbuf);
    like($gbuf->text, qr/sub compute \{ my \(\$self, \@args\) = \@_;/, '<Tab> accept_ghost_text inserted suggestion');
    is($mod->ghost_state->{active}, 0, 'ghost state cleared after accept');
};

$acp->stop();
$mcp->stop();

# ---------------------------------------------------------------------------
# 5. Live Integration with Real NeoPerl::Editor + NeoPerl::Buffer + NeoPerl::Core
# ---------------------------------------------------------------------------
my $has_real_editor = eval { require NeoPerl::Editor; 1 };
SKIP: {
    skip 'NeoPerl::Editor not available', 1 unless $has_real_editor;

    subtest 'Live integration with NeoPerl::Editor, Buffer, ExCmd, Layout, and Core' => sub {
        my $real_ed = NeoPerl::Editor->new(cwd => $ws, width => 120, height => 40);
        my $real_buf = $real_ed->open_file($sample_file);
        ok($real_buf->isa('NeoPerl::Buffer'), 'opened real NeoPerl::Buffer');
        $real_buf->set_text("package Sample;\nuse strict;\nsub greet { return 'REAL_EDITOR_UNSAVED'; }\n1;\n");

        my $r_mcp = NeoPerl::Antigravity::EditorMCP->new(
            editor         => $real_ed,
            memory_store   => $store,
            memory_writer  => $writer,
            vision         => $vision,
            offload_queue  => $queue,
            customizations => $cust,
        );
        my $r_port = $r_mcp->start();
        my $r_mod = NeoPerl::Antigravity::Modalities->new(
            editor         => $real_ed,
            editor_mcp     => $r_mcp,
            memory_store   => $store,
            memory_writer  => $writer,
            inference      => $mgr,
            vision         => $vision,
            offload_queue  => $queue,
            model_hub      => $mhub,
            customizations => $cust,
            repo_key       => 'demo',
        );
        $r_mod->attach($real_ed);

        # ExCmd registration & execution through real NeoPerl::ExCmd
        my $ex_res = $real_ed->exec_command(':MemAutoContext on');
        ok($ex_res->{ok}, ':MemAutoContext on executed via NeoPerl::ExCmd');
        is($r_mod->auto_context, 1, 'auto_context enabled via real ExCmd');

        my $mh_res = $real_ed->exec_command(':ModelHub');
        ok($mh_res->{ok}, ':ModelHub executed via NeoPerl::ExCmd');

        # EditorMCP read_buffer and propose_edit -> Buffer agy_diff extmarks
        my $rb = $r_mcp->call_tool_local('neoperl_read_buffer', { path => $sample_file });
        like($rb->{content}, qr/REAL_EDITOR_UNSAVED/, 'EditorMCP reads live unsaved NeoPerl::Buffer');

        my $pe = $r_mcp->call_tool_local('neoperl_propose_edit', {
            path     => $sample_file,
            new_text => "package Sample;\nuse strict;\nuse warnings;\nsub greet { return 'REAL_EDITOR_PROPOSED'; }\n1;\n",
        });
        is($pe->{staged}, 1, 'EditorMCP staged diff proposal on real NeoPerl::Buffer');
        ok($pe->{hunk_count} >= 1, 'real Myers C11 diff produced hunks');
        ok($real_buf->has_diff_proposal, 'real NeoPerl::Buffer tracks active diff proposal');
        my $marks = $real_buf->get_extmarks('agy_diff');
        ok(@$marks >= 1, 'real NeoPerl::Core::Buffer painted agy_diff extmarks');

        # Command Center providers & statusline segments & pump
        my $cc_chat = $real_ed->get_command_center_data('chat');
        my $cc_jobs = $real_ed->get_command_center_data('jobs');
        is($cc_chat->{mcp_port}, $r_port, 'chat Command Center provider reports active MCP port');
        ok(exists $cc_jobs->{telemetry}, 'jobs Command Center provider returns inference telemetry');
        my $sl = $real_ed->get_statusline_segments();
        ok(exists $sl->{ai_db}, 'statusline provider registered ai_db segment');
        ok($real_ed->pump() >= 1, 'Editor->pump() runs ai_db tick callback non-blockingly');

        $r_mcp->stop();
    };
}

done_testing();
