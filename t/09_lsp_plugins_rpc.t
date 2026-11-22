use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use IO::Socket::INET;
use IO::Socket::UNIX;
use Time::HiRes qw(time sleep);
use JSON::PP qw(encode_json decode_json);

use NeoPerl::Editor;
use NeoPerl::RPC;
use NeoPerl::Plugin::Telescope;
use NeoPerl::Plugin::Explorer;
use NeoPerl::Plugin::LSP;
use NeoPerl::Plugin::Git;
use NeoPerl::Plugin::WhichKey;
use NeoPerl::Plugin::Themes;

my $tmp = tempdir(CLEANUP => 1);

# --- Helper: Non-blocking socket RPC exchange while pumping $editor->pump ---
sub rpc_roundtrip_socket {
    my ($ed, $addr, $payload_str, $use_content_length) = @_;
    my $sock;
    if ($addr =~ /^([^:]+):(\d+)$/) {
        $sock = IO::Socket::INET->new(PeerAddr => $1, PeerPort => $2, Proto => 'tcp', Timeout => 3)
            or die "TCP connect failed: $!";
    }
    else {
        $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $addr, Timeout => 3)
            or die "Unix connect failed: $!";
    }
    $sock->blocking(0);
    my $wire = $use_content_length
        ? ("Content-Length: " . length($payload_str) . "\r\n\r\n" . $payload_str)
        : ($payload_str . "\n");
    syswrite($sock, $wire);

    my $buf = '';
    my $deadline = time() + 3.0;
    while (time() < $deadline) {
        $ed->pump;
        my $chunk = '';
        my $n = sysread($sock, $chunk, 65536);
        $buf .= $chunk if defined $n && $n > 0;
        if ($use_content_length) {
            if ($buf =~ /\AContent-Length:\s*(\d+)\r?\n\r?\n(.*)\z/s && length($2) >= $1) {
                close $sock;
                return decode_json(substr($2, 0, $1));
            }
        }
        elsif ($buf =~ /\A([^\n]+)\n/) {
            close $sock;
            return decode_json($1);
        }
        sleep(0.005);
    }
    close $sock;
    die "RPC roundtrip timed out (partial: $buf)";
}

sub http_post_json {
    my ($ed, $host, $port, $path, $payload_str) = @_;
    my $sock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 3)
        or die "HTTP connect failed: $!";
    $sock->blocking(0);
    my $req = "POST $path HTTP/1.1\r\n"
            . "Host: $host:$port\r\n"
            . "Content-Type: application/json\r\n"
            . "Content-Length: " . length($payload_str) . "\r\n"
            . "Connection: close\r\n\r\n"
            . $payload_str;
    syswrite($sock, $req);

    my $raw = '';
    my $deadline = time() + 3.0;
    while (time() < $deadline) {
        $ed->pump;
        my $chunk = '';
        my $n = sysread($sock, $chunk, 65536);
        if (defined $n) {
            last if $n == 0;
            $raw .= $chunk;
        }
        sleep(0.005);
    }
    close $sock;
    my ($hdr, $body) = split /\r?\n\r?\n/, $raw, 2;
    return ($hdr // '', $body // '');
}

# 1. LIVE /usr/bin/clangd LSP test + async perl -c syntax provider
{
    my $lsp_dir = File::Spec->catdir($tmp, 'lsp_proj');
    mkdir $lsp_dir or die $!;

    my $c_file = File::Spec->catfile($lsp_dir, 'sample.c');
    open my $cfh, '>', $c_file or die $!;
    print {$cfh} <<'C_CODE';
int add_numbers(int a, int b) {
    return a + b;
}

int main(void) {
    int sum = add_numbers(10, 20);
    int bad = nonexistent_symbol_xyz;
    return sum + bad;
}
C_CODE
    close $cfh;

    my $ed  = NeoPerl::Editor->new(cwd => $lsp_dir);
    my $lsp = NeoPerl::Plugin::LSP->new(editor => $ed);

    # Live clangd test
    SKIP: {
        my $has_clangd = (-x '/usr/bin/clangd' || grep { -x File::Spec->catfile($_, 'clangd') } File::Spec->path);
        skip 'clangd not installed', 8 unless $has_clangd;

        my $cbuf = $ed->open_file($c_file);
        is($cbuf->filetype, 'c', 'detected C filetype for sample.c');

        my $info_res = $ed->exec_command(':LspInfo');
        ok($info_res->{ok}, ':LspInfo executed cleanly');
        ok(exists $info_res->{data}{clients}{clangd}, 'clangd client started automatically on C file open');

        ok($lsp->wait_for_ready('clangd', 6.0), 'LIVE clangd completed initialize/initialized handshake');

        # Wait for publishDiagnostics from clangd
        my $diags = $lsp->wait_for_diagnostics($cbuf, 6.0);
        ok(scalar(@{$diags}) >= 1, 'LIVE clangd published real diagnostic for undeclared identifier');
        my $ed_diags = $ed->get_diagnostics($cbuf, source => 'lsp_clangd');
        ok(scalar(@{$ed_diags}) >= 1, 'Editor diagnostic store captured clangd diagnostics');
        my $dmarks = $cbuf->get_extmarks('diag_lsp_clangd');
        ok(scalar(@{$dmarks}) >= 1, 'clangd diagnostics painted into buffer extmarks');

        # Live hover on add_numbers (line 5, col 16: `    int sum = add_numbers(10, 20);`)
        my $hover_res;
        my $hid = $lsp->hover($cbuf, 5, 16, sub { $hover_res = $_[0] });
        $lsp->wait_for_request('clangd', $hid, 5.0);
        my $hover_str = ref($hover_res) eq 'HASH'
            ? (ref($hover_res->{contents}) eq 'HASH' ? ($hover_res->{contents}{value} // '') : ($hover_res->{contents} // ''))
            : '';
        like($hover_str, qr/add_numbers/, 'LIVE clangd textDocument/hover returned add_numbers signature');

        # Live definition on add_numbers call site -> jumps to line 0
        my $def_res;
        my $did = $lsp->definition($cbuf, 5, 16, sub { $def_res = $_[0] });
        $lsp->wait_for_request('clangd', $did, 5.0);
        my $first_loc = ref($def_res) eq 'ARRAY' ? $def_res->[0] : $def_res;
        ok(ref($first_loc) eq 'HASH' && defined($first_loc->{range}) && $first_loc->{range}{start}{line} == 0,
            'LIVE clangd textDocument/definition resolved add_numbers to line 0');

        # Live completion
        my $comp_res;
        my $cid = $lsp->completion($cbuf, 5, 16, sub { $comp_res = $_[0] });
        $lsp->wait_for_request('clangd', $cid, 5.0);
        ok(defined $comp_res, 'LIVE clangd textDocument/completion responded');

        $lsp->stop_all;
    }

    # Built-in async perl -c syntax provider
    my $pl_file = File::Spec->catfile($lsp_dir, 'broken.pl');
    open my $pfh, '>', $pl_file or die $!;
    print {$pfh} "use strict;\nuse warnings;\nmy \$x = ;\nprint \$x;\n";
    close $pfh;

    my $resolved_perl = 0;
    $ed->on('DiagnosticResolved', sub { my (%ev) = @_; $resolved_perl++ if $ev{source} eq 'perl_syntax' });

    my $pbuf = $ed->open_file($pl_file);
    my $pdiags = $lsp->wait_for_perl_check($pbuf, 5.0);
    ok(scalar(@{$pdiags}) >= 1, 'async perl -c detected syntax error');
    is($pdiags->[0]{line}, 2, 'perl -c mapped error to exact 0-based line 2');

    # Fix Perl syntax and re-check
    $pbuf->set_text("use strict;\nuse warnings;\nmy \$x = 42;\nprint \$x;\n");
    $ed->emit('TextChanged', buf => $pbuf);
    my $pdiags_after = $lsp->wait_for_perl_check($pbuf, 5.0);
    is(scalar(@{$pdiags_after}), 0, 'async perl -c cleared diagnostics after fix');
    ok($resolved_perl >= 1, 'DiagnosticResolved fired when perl -c error fixed');
    $lsp->stop_all;
}

# 2. Git + Explorer + Telescope + WhichKey + Themes
{
    my $repo = File::Spec->catdir($tmp, 'git_repo');
    mkdir $repo or die $!;
    my $sub_dir = File::Spec->catdir($repo, 'src');
    mkdir $sub_dir or die $!;

    my $app_pl = File::Spec->catfile($sub_dir, 'app.pl');
    open my $fh, '>', $app_pl or die $!;
    print {$fh} "sub greet {\n    return 'hello';\n}\nsub bye {\n    return 'bye';\n}\n";
    close $fh;

    my $untracked = File::Spec->catfile($repo, 'notes.txt');
    open my $nfh, '>', $untracked or die $!;
    print {$nfh} "project notes here\n";
    close $nfh;

    # Initialize real temporary git repo with clean local identity
    my $init_rc = system('git', '-C', $repo, 'init', '-q', '-b', 'main');
    if ($init_rc != 0) {
        system('git', '-C', $repo, 'init', '-q') == 0 or die "git init failed";
    }
    system('git', '-C', $repo, 'config', 'user.name', 'stratum42');
    system('git', '-C', $repo, 'config', 'user.email', 'stratum42@example.invalid');
    system('git', '-C', $repo, 'add', 'src/app.pl');
    system('git', '-C', $repo, 'commit', '-q', '-m', 'Initial commit');

    my $ed  = NeoPerl::Editor->new(cwd => $repo);
    my $git = NeoPerl::Plugin::Git->new(editor => $ed);
    my $exp = NeoPerl::Plugin::Explorer->new(editor => $ed);
    my $tel = NeoPerl::Plugin::Telescope->new(editor => $ed);
    my $wk  = NeoPerl::Plugin::WhichKey->new(editor => $ed);

    ok($git->is_git_repo, 'Git detected repository root');
    ok(length($git->branch) > 0, 'Git detected active branch');

    # Modify tracked file and verify C11 Myers gutter signs + preview_hunk + reset_hunk
    my $buf = $ed->open_file($app_pl);
    $buf->set_text("sub greet {\n    return 'hi there';\n}\nsub bye {\n    return 'bye';\n}\n");
    $ed->emit('TextChanged', buf => $buf);

    my $ghunks = $git->get_hunks($buf);
    is(scalar(@{$ghunks}), 1, 'Git computed 1 C11 Myers diff hunk');
    my $gmarks = $buf->get_extmarks('git_gutter');
    ok(scalar(@{$gmarks}) >= 1, 'Git painted gutter sign extmarks in git_gutter namespace');
    is($gmarks->[0]{sign_text}, '~', 'modified line painted with ~ sign');

    my $prev = $git->preview_hunk($buf, 1);
    ok($prev && scalar(@{ $prev->{lines} }) >= 3, 'Git preview_hunk generated diff lines and float');

    ok($git->reset_hunk($buf, 1), 'Git reset_hunk reverted hunk');
    like($buf->get_line(1), qr/return 'hello';/, 'reset_hunk restored exact HEAD line');

    # Test Git commit + GitCommitPost hook
    my $commit_event;
    $ed->on('GitCommitPost', sub { my (%ev) = @_; $commit_event = \%ev });
    $buf->set_text("sub greet {\n    return 'updated';\n}\nsub bye {\n    return 'bye';\n}\n");
    $buf->save;
    my $cres = $git->commit('Update greet return', paths => ['src/app.pl']);
    ok($cres->{ok} && length($cres->{sha}) >= 7, 'Git commit succeeded with real SHA');
    ok($commit_event && $commit_event->{sha} eq $cres->{sha}, 'GitCommitPost event emitted with SHA');

    # Explorer: tree nodes, Git untracked badge '?', dir expand, custom action hook
    $exp->refresh;
    my $nodes = $exp->visible_nodes;
    my ($notes_node) = grep { $_->{name} eq 'notes.txt' } @{$nodes};
    ok($notes_node, 'Explorer lists workspace files');
    is($notes_node->{git_badge}, '?', 'Explorer attached Git untracked badge ?');

    my $vision_target;
    $exp->register_action('v', 'Parse doc', sub {
        my ($e, $node) = @_;
        $vision_target = $node->{name};
    });
    $exp->handle_key('v');
    ok(defined $vision_target, 'Explorer custom action hook invoked on key');

    # Telescope: files, grep, buffers, symbols, open_custom
    $tel->files($repo);
    ok($tel->is_open, 'Telescope files picker opened float');
    $tel->set_query('app');
    ok(scalar(@{ $tel->results }) >= 1, 'Telescope C11 fuzzy filter matched app.pl');
    like($tel->results->[0]{item}{label}, qr/app\.pl/, 'top fuzzy hit is app.pl');
    ok(scalar(@{ $tel->results->[0]{positions} }) >= 3, 'Smith-Waterman returned matched character positions');
    ok(scalar(@{ $tel->preview_lines }) >= 1, 'Telescope populated live preview pane');
    $tel->close;

    $tel->grep('updated', $repo);
    ok(scalar(@{ $tel->results }) >= 1, 'Telescope C11 parallel grep matched updated');
    $tel->close;

    $tel->symbols;
    ok(scalar(@{ $tel->results }) >= 2, 'Telescope symbols listed buffer subs');
    $tel->close;

    my $picked;
    $tel->open_custom('Memory Search', [
        { label => 'Prefer strict C11', badge => 'repo',   preview => ['Detail A'] },
        { label => 'Use Db2 VECTOR',    badge => 'global', preview => ['Detail B'] },
    ], sub { my ($item) = @_; $picked = $item->{label} });
    $tel->set_query('Db2');
    is(scalar(@{ $tel->results }), 1, 'open_custom filtered items');
    is($tel->preview_lines->[0], 'Detail B', 'open_custom populated custom preview');
    $ed->handle_key('<CR>');
    is($picked, 'Use Db2 VECTOR', 'open_custom <CR> invoked callback and closed float');
    ok(!$tel->is_open, 'Telescope closed after selection');

    # WhichKey popup on pending <leader>
    $ed->handle_key(' ');
    ok($wk->is_visible, 'WhichKey float shown when <leader> prefix is pending');
    my $wk_float = $ed->layout->get_float_by_kind('whichkey');
    ok($wk_float && scalar(@{ $wk_float->lines }) >= 3, 'WhichKey populated candidate bindings');
    $ed->handle_key('<Esc>');
    ok(!$wk->is_visible, 'WhichKey float hides on <Esc>');

    # Themes
    my @tlist = NeoPerl::Plugin::Themes->list;
    is_deeply(\@tlist, [qw(aix_amber catppuccin gruvbox kanagawa tokyonight)], 'all 5 built-in themes available');
    my ($r, $g, $b) = NeoPerl::Plugin::Themes->hex_to_rgb('#7aa2f7');
    is_deeply([$r, $g, $b], [0x7a, 0xa2, 0xf7], 'hex_to_rgb converts hex cleanly');
}

# 3. LIVE --listen JSON-RPC 2.0 Server (Unix socket, TCP socket, and HTTP via Mojolicious)
{
    my $ed = NeoPerl::Editor->new(cwd => $tmp);
    $ed->current_buffer->set_text("hello rpc\nline two\n");

    # 3a. Unix domain socket (NDJSON)
    my $sock_path = File::Spec->catfile($tmp, 'npl.sock');
    my $rpc_unix = NeoPerl::RPC->new(editor => $ed, address => $sock_path);
    ok($rpc_unix->is_running && -S $sock_path, 'RPC listening on Unix socket');

    my $r_ping = rpc_roundtrip_socket($ed, $sock_path, encode_json({ jsonrpc => '2.0', id => 1, method => 'neoperl.ping' }), 0);
    is($r_ping->{result}{ok}, 1, 'Unix RPC neoperl.ping succeeded');

    my $r_keys = rpc_roundtrip_socket($ed, $sock_path, encode_json({
        jsonrpc => '2.0', id => 2, method => 'neoperl.feed_keys', params => { keys => 'ggA!<Esc>' },
    }), 0);
    is($r_keys->{result}{ok}, 1, 'Unix RPC neoperl.feed_keys succeeded');
    is($ed->current_buffer->get_line(0), 'hello rpc!', 'remote feed_keys mutated live buffer');
    $rpc_unix->stop;
    ok(!-e $sock_path, 'Unix socket cleaned up on stop');

    # 3b. TCP socket (Content-Length framing)
    my $rpc_tcp = NeoPerl::RPC->new(editor => $ed, address => '127.0.0.1:0');
    ok($rpc_tcp->is_running && $rpc_tcp->port > 0, 'RPC listening on ephemeral TCP port');
    my $tcp_addr = '127.0.0.1:' . $rpc_tcp->port;
    my $r_lines = rpc_roundtrip_socket($ed, $tcp_addr, encode_json({
        jsonrpc => '2.0', id => 3, method => 'neoperl.get_lines', params => { start => 0, end => 2 },
    }), 1);
    is_deeply($r_lines->{result}{lines}, [ 'hello rpc!', 'line two' ], 'TCP Content-Length RPC neoperl.get_lines exact');
    $rpc_tcp->stop;

    # 3c. HTTP JSON-RPC 2.0 (--listen http://127.0.0.1:0 via Mojolicious when installed, fallback otherwise)
    my $rpc_http = NeoPerl::RPC->new(editor => $ed, address => 'http://127.0.0.1:0');
    ok($rpc_http->is_running && $rpc_http->port > 0, 'RPC listening on HTTP ephemeral port');
    if (NeoPerl::RPC->has_mojo) {
        is($rpc_http->transport, 'mojo_http', 'RPC HTTP uses Mojo::Server::Daemon when Mojolicious is loaded');
    }
    else {
        is($rpc_http->transport, 'http_fallback', 'RPC HTTP gracefully uses socket fallback without Mojolicious');
    }

    my ($hdr, $body) = http_post_json(
        $ed, '127.0.0.1', $rpc_http->port, '/rpc',
        encode_json({ jsonrpc => '2.0', id => 4, method => 'neoperl.get_state' }),
    );
    like($hdr, qr/200 OK/, 'HTTP POST /rpc returned 200 OK');
    my $hjson = decode_json($body);
    is($hjson->{id}, 4, 'HTTP JSON-RPC 2.0 response id matched');
    is($hjson->{result}{mode}, 'NORMAL', 'HTTP JSON-RPC 2.0 get_state returned live editor state');

    if (NeoPerl::RPC->has_mojo && eval { require Mojo::UserAgent; require Mojo::IOLoop; 1 }) {
        my $ua = Mojo::UserAgent->new;
        my $ws_reply;
        my $ws_tid = Mojo::IOLoop->timer(3 => sub { Mojo::IOLoop->stop });
        $ua->websocket('ws://127.0.0.1:' . $rpc_http->port . '/ws' => sub {
            my ($u, $tx) = @_;
            if (!$tx->is_websocket) {
                Mojo::IOLoop->stop;
                return;
            }
            $tx->on(message => sub {
                my ($t, $msg) = @_;
                $ws_reply = decode_json($msg);
                $t->finish;
                Mojo::IOLoop->stop;
            });
            $tx->send(encode_json({ jsonrpc => '2.0', id => 7, method => 'neoperl.ping' }));
        });
        Mojo::IOLoop->start;
        Mojo::IOLoop->remove($ws_tid);
        ok($ws_reply && $ws_reply->{id} == 7 && $ws_reply->{result}{mojo_http},
            'LIVE Mojolicious WebSocket /ws JSON-RPC 2.0 roundtrip succeeded');
    }
    $rpc_http->stop;
}

done_testing();
