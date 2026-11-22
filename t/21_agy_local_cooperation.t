use strict;
use warnings;
use utf8;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempdir tempfile);
use Cwd qw(abs_path);
use Time::HiRes qw(time sleep);
use Compress::Zlib ();
use JSON::PP ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
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

    # Auto-detect optional sibling MT repositories without hardcoded user paths
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
        [ $ENV{NEOPERL_DBD_SQLITE_DIR}, 'dbd-sqlite-mt',  [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBI_DIR},        'dbi-mt',         [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_MOJO_DIR},       'mojolicious-mt', [ 'xs/blib/arch', 'xs/blib/lib', 'lib' ] ],
        [ $ENV{TCL_TK_MT_DIR} || $ENV{NEOPERL_TK_DIR}, 'tcl-tk-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
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

use_ok('NeoPerl::MT');
use_ok('NeoPerl::Antigravity::ACP');
use_ok('NeoPerl::Antigravity::EditorMCP');
use_ok('NeoPerl::Antigravity::Modalities');
use_ok('NeoPerl::Inference::Config');
use_ok('NeoPerl::Inference::ModelHub');

# Ensure any booted apps & child llama-server/ACP PIDs are ALWAYS torn down cleanly
my @ACTIVE_APPS;
END {
    for my $app (@ACTIVE_APPS) {
        eval { $app->shutdown() } if defined $app;
    }
}

sub _track_app {
    my ($app) = @_;
    push @ACTIVE_APPS, $app;
    return $app;
}

sub _wait_until {
    my ($cond, $timeout_s) = @_;
    $timeout_s ||= 8.0;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $cond->();
        sleep(0.02);
    }
    return $cond->() ? 1 : 0;
}

sub _check_perl_syntax {
    my ($code) = @_;
    my ($fh, $tmp) = tempfile(SUFFIX => '.pl', UNLINK => 1);
    print {$fh} $code;
    close $fh;

    my @inc_args = map { "-I$_" } grep { defined $_ && !ref($_) && length $_ } @INC;
    my ($in_fh, $out_fh);
    my $err_fh = gensym();
    my $pid = open3($in_fh, $out_fh, $err_fh, $^X, @inc_args, '-c', $tmp);
    close $in_fh  if $in_fh;
    close $out_fh if $out_fh;
    local $/;
    my $err = <$err_fh> // '';
    close $err_fh;
    waitpid($pid, 0);
    my $ok = ($? == 0) ? 1 : 0;
    $err =~ s/\A\s+|\s+\z//g;
    return ($ok, $err);
}

sub _png_chunk {
    my ($type, $data) = @_;
    my $crc = Compress::Zlib::crc32($type . $data);
    return pack('N', length($data)) . $type . $data . pack('N', $crc);
}

sub _rgba_to_png {
    my ($rgba, $w, $h) = @_;
    my $stride = $w * 4;
    my @scans;
    for my $y (0 .. $h - 1) {
        push @scans, "\x00" . substr($rgba, $y * $stride, $stride);
    }
    my $zdat = Compress::Zlib::compress(join('', @scans), 6);
    my $ihdr = pack('N N C C C C C', $w, $h, 8, 6, 0, 0, 0);
    return "\x89PNG\r\n\x1a\n"
         . _png_chunk('IHDR', $ihdr)
         . _png_chunk('IDAT', $zdat)
         . _png_chunk('IEND', '');
}

# Render a Retina high-contrast PNG via headless Tcl::Tk::MT::Canvas
# with a deterministic pure-Perl bitmap fallback when Canvas is unavailable.
sub _render_readable_png {
    my ($out_path, $text_specs) = @_;
    $text_specs ||= [
        { text => 'NeoPerl MT Local Cooperation',          font => ['Helvetica', 24], y => 28  },
        { text => 'Database: IBM Db2 12.1.2 VECTOR_DISTANCE', font => ['Helvetica', 18], y => 78 },
        { text => 'sub compute_sum {',                     font => ['Courier', 18],   y => 128 },
        { text => '    my ($a, $b) = @_;',                 font => ['Courier', 18],   y => 160 },
        { text => '    return $a + $b;',                   font => ['Courier', 18],   y => 192 },
        { text => '}',                                     font => ['Courier', 18],   y => 224 },
    ];

    my $rendered = eval {
        require Tcl::Tk::MT::Canvas;
        my ($w, $h) = (780, 320);
        my $c = Tcl::Tk::MT::Canvas->new(
            undef,
            '-width'    => $w,
            '-height'   => $h,
            '-bg'       => '#ffffff',
            '-headless' => 1,
            '-scale'    => 2.0,
        );
        $c->createRectangle(0, 0, $w, $h, '-fill' => '#ffffff', '-outline' => '#ffffff');
        for my $sp (@$text_specs) {
            $c->createText(
                32, $sp->{y},
                '-text'   => $sp->{text},
                '-fill'   => '#000000',
                '-font'   => $sp->{font},
                '-anchor' => 'nw',
            );
        }
        $c->render();
        my $rgba   = $c->readback_rgba();
        my $pixels = int(length($rgba) / 4);
        my $pw     = int(sqrt($pixels * $w / $h) + 0.5);
        my $ph     = int($pixels / $pw);
        my $png    = _rgba_to_png($rgba, $pw, $ph);
        open my $fh, '>:raw', $out_path or die "write $out_path: $!";
        print {$fh} $png;
        close $fh;
        1;
    };
    return 'Tcl::Tk::MT::Canvas' if $rendered && -f $out_path && (-s $out_path) > 1000;

    # Pure-Perl bold 5x7 fallback
    my %FONT = (
        ' ' => [qw(00000 00000 00000 00000 00000 00000 00000)],
        'A' => [qw(01110 10001 10001 11111 10001 10001 10001)],
        'B' => [qw(11110 10001 10001 11110 10001 10001 11110)],
        'C' => [qw(01110 10001 10000 10000 10000 10001 01110)],
        'D' => [qw(11110 10001 10001 10001 10001 10001 11110)],
        'E' => [qw(11111 10000 10000 11110 10000 10000 11111)],
        'F' => [qw(11111 10000 10000 11110 10000 10000 10000)],
        'H' => [qw(10001 10001 10001 11111 10001 10001 10001)],
        'I' => [qw(11111 00100 00100 00100 00100 00100 11111)],
        'K' => [qw(10001 10010 10100 11000 10100 10010 10001)],
        'L' => [qw(10000 10000 10000 10000 10000 10000 11111)],
        'M' => [qw(10001 11011 10101 10101 10001 10001 10001)],
        'N' => [qw(10001 11001 10101 10011 10001 10001 10001)],
        'O' => [qw(01110 10001 10001 10001 10001 10001 01110)],
        'P' => [qw(11110 10001 10001 11110 10000 10000 10000)],
        'R' => [qw(11110 10001 10001 11110 10100 10010 10001)],
        'S' => [qw(01111 10000 10000 01110 00001 00001 11110)],
        'T' => [qw(11111 00100 00100 00100 00100 00100 00100)],
        'U' => [qw(10001 10001 10001 10001 10001 10001 01110)],
        'V' => [qw(10001 10001 10001 10001 10001 01010 00100)],
        'W' => [qw(10001 10001 10001 10101 10101 11011 10001)],
        'X' => [qw(10001 10001 01010 00100 01010 10001 10001)],
        '2' => [qw(01110 10001 00001 00110 01000 10000 11111)],
        '4' => [qw(00010 00110 01010 10010 11111 00010 00010)],
        '7' => [qw(11111 00001 00010 00100 01000 01000 01000)],
        '8' => [qw(01110 10001 10001 01110 10001 10001 01110)],
        '_' => [qw(00000 00000 00000 00000 00000 00000 11111)],
    );
    my @lines = map { substr(uc($_->{text}), 0, 18) } @$text_specs[ 0 .. ($#$text_specs > 2 ? 2 : $#$text_specs) ];
    my ($scale, $w, $h) = (6, 720, 240);
    my $rgba  = ("\xff\xff\xff\xff") x ($w * $h);
    my $black = "\x00\x00\x00\xff";
    for my $li (0 .. $#lines) {
        my $y0 = 30 + $li * 64;
        my $x0 = 24;
        for my $ch (split //, $lines[$li]) {
            my $glyph = $FONT{$ch} || $FONT{' '};
            for my $gy (0 .. 6) {
                for my $gx (0 .. 4) {
                    next unless substr($glyph->[$gy], $gx, 1) eq '1';
                    for my $sy (0 .. $scale - 1) {
                        for my $sx (0 .. $scale - 1) {
                            my $px = $x0 + $gx * $scale + $sx;
                            my $py = $y0 + $gy * $scale + $sy;
                            next if $px < 0 || $px >= $w || $py < 0 || $py >= $h;
                            substr($rgba, ($py * $w + $px) * 4, 4, $black);
                        }
                    }
                }
            }
            $x0 += 6 * $scale;
        }
    }
    my $png = _rgba_to_png($rgba, $w, $h);
    open my $fh, '>:raw', $out_path or die "write $out_path: $!";
    print {$fh} $png;
    close $fh;
    return 'pure_perl_bitmap';
}

# Build an executable ACP 1.0 protocol peer script that speaks real JSON-RPC 2.0
# NDJSON over stdin/stdout AND issues real HTTP/1.1 MCP Streamable HTTP (2025-03-26)
# requests to EditorMCP during synchronous session/prompt turns.
sub _build_acp_peer_script {
    my ($dir) = @_;
    my $impl_file = File::Spec->catfile($dir, 'acp_coop_peer_impl.pl');
    my $wrapper   = File::Spec->catfile($dir, 'acp_coop_peer');

    my $impl = <<'END_ACP_PEER';
use strict;
use warnings;
use IO::Handle ();
use IO::Socket::INET ();
use JSON::PP ();

STDOUT->autoflush(1);
STDERR->autoflush(1);
binmode(STDIN,  ':utf8');
binmode(STDOUT, ':utf8');

my $json     = JSON::PP->new->utf8;
my $log_path = $ENV{COOP_ACP_LOG} // '';

sub record {
    my ($entry) = @_;
    return unless length $log_path;
    if (open my $fh, '>>:raw', $log_path) {
        print {$fh} $json->encode($entry) . "\n";
        close $fh;
    }
}

record({ event => 'spawn', pid => $$, argv => [@ARGV] });

my $mcp_port = 0;
for (my $i = 0; $i < @ARGV; $i++) {
    if ($ARGV[$i] eq '--ide-mcp-port' && defined $ARGV[$i + 1]) {
        $mcp_port = int($ARGV[$i + 1]);
        $i++;
    }
}

sub send_msg {
    my ($obj) = @_;
    my $line = $json->encode($obj);
    utf8::decode($line);
    print STDOUT $line . "\n";
}

sub mcp_http_request {
    my ($port, $method, $path, $body_obj, $session_id) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    );
    return { ok => 0, status => 0, error => "connect failed: $!" } unless $sock;
    $sock->timeout(240);
    binmode($sock, ':raw');

    my $body_bytes = defined($body_obj) ? $json->encode($body_obj) : '';
    my $clen       = do { use bytes; length($body_bytes) };

    my @hdrs = (
        "$method $path HTTP/1.1",
        "Host: 127.0.0.1:$port",
        'Accept: application/json, text/event-stream',
        'Connection: close',
    );
    push @hdrs, 'Content-Type: application/json' if defined $body_obj;
    push @hdrs, "Content-Length: $clen"          if defined $body_obj;
    push @hdrs, "Mcp-Session-Id: $session_id"    if defined $session_id && length $session_id;

    my $wire = join("\r\n", @hdrs, '', '') . $body_bytes;
    print {$sock} $wire;
    $sock->flush();

    my $raw = '';
    while (1) {
        my $chunk = '';
        my $n = sysread($sock, $chunk, 65536);
        last if !defined($n) || $n == 0;
        $raw .= $chunk;
    }
    close $sock;

    my ($hdr_blk, $resp_body) = split /\r\n\r\n/, $raw, 2;
    $hdr_blk   //= '';
    $resp_body //= '';
    my ($status) = ($hdr_blk =~ m{\AHTTP/\S+\s+(\d+)});
    $status = int($status || 0);

    my %rh;
    for my $hline (split /\r\n/, $hdr_blk) {
        if ($hline =~ /^([^:]+):\s*(.*)$/) {
            $rh{ lc($1) } = $2;
        }
    }

    if (($rh{'transfer-encoding'} // '') =~ /chunked/i) {
        my $dec = '';
        my $p   = 0;
        while ($p < length($resp_body)) {
            my $crlf = index($resp_body, "\r\n", $p);
            last if $crlf < 0;
            my $hex = substr($resp_body, $p, $crlf - $p);
            $hex =~ s/;.*$//;
            my $len = hex($hex);
            last if $len == 0;
            $dec .= substr($resp_body, $crlf + 2, $len);
            $p = $crlf + 2 + $len + 2;
        }
        $resp_body = $dec;
    }

    my $parsed = length($resp_body) ? eval { $json->decode($resp_body) } : undef;
    return {
        ok         => ($status >= 200 && $status < 300) ? 1 : 0,
        status     => $status,
        headers    => \%rh,
        session_id => $rh{'mcp-session-id'},
        json       => $parsed,
        body       => $resp_body,
    };
}

sub mcp_call_tool {
    my ($port, $req_id, $sid, $tool, $args) = @_;
    my $resp = mcp_http_request($port, 'POST', '/mcp', {
        jsonrpc => '2.0',
        id      => $req_id,
        method  => 'tools/call',
        params  => {
            name      => $tool,
            arguments => $args || {},
        },
    }, $sid);
    my $structured;
    if ($resp->{ok} && ref($resp->{json}) eq 'HASH' && ref($resp->{json}{result}) eq 'HASH') {
        $structured = $resp->{json}{result}{structuredContent};
        if (!defined $structured && ref($resp->{json}{result}{content}) eq 'ARRAY'
            && ref($resp->{json}{result}{content}[0]) eq 'HASH'
            && defined $resp->{json}{result}{content}[0]{text})
        {
            my $txt = $resp->{json}{result}{content}[0]{text};
            utf8::encode($txt) if utf8::is_utf8($txt);
            $structured = eval { $json->decode($txt) } // $txt;
        }
    }
    return {
        ok          => ($resp->{ok} && ref($resp->{json}) eq 'HASH' && !$resp->{json}{error} && !($resp->{json}{result}{isError})) ? 1 : 0,
        status      => $resp->{status},
        session_id  => $resp->{session_id},
        rpc_error   => (ref($resp->{json}) eq 'HASH' ? $resp->{json}{error} : undef),
        is_error    => (ref($resp->{json}) eq 'HASH' && ref($resp->{json}{result}) eq 'HASH' && $resp->{json}{result}{isError}) ? 1 : 0,
        data        => $structured,
        raw_text    => (ref($resp->{json}) eq 'HASH' && ref($resp->{json}{result}) eq 'HASH' && ref($resp->{json}{result}{content}) eq 'ARRAY' && ref($resp->{json}{result}{content}[0]) eq 'HASH')
                        ? $resp->{json}{result}{content}[0]{text} : undef,
        http_body   => substr($resp->{body} // '', 0, 300),
    };
}

my $sess_seq = 0;
my $mcp_id   = 1;
my $rev_id   = 4000;
my $cur_model = 'gemini-2.5-pro';

sub call_client {
    my ($method, $params) = @_;
    my $rid = $rev_id++;
    send_msg({ jsonrpc => '2.0', id => $rid, method => $method, params => $params || {} });
    while (defined(my $line = <STDIN>)) {
        $line =~ s/[\r\n]+$//;
        next unless length $line;
        my $raw = $line;
        utf8::encode($raw) if utf8::is_utf8($raw);
        my $m = eval { $json->decode($raw) };
        next unless ref($m) eq 'HASH';
        return ($m->{result}, $m->{error}) if defined $m->{id} && $m->{id} == $rid;
    }
    return (undef, { code => -32099, message => 'EOF' });
}

while (defined(my $line = <STDIN>)) {
    $line =~ s/[\r\n]+$//;
    next unless length $line;
    my $raw = $line;
    utf8::encode($raw) if utf8::is_utf8($raw);
    my $req = eval { $json->decode($raw) };
    next unless ref($req) eq 'HASH';

    my $method = $req->{method} // '';
    my $id     = $req->{id};
    my $params = ref($req->{params}) eq 'HASH' ? $req->{params} : {};
    record({ event => 'rpc', method => $method, params => $params });

    if ($method eq 'initialize') {
        send_msg({
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                protocolVersion   => 1,
                agentInfo         => { name => 'antigravity-coop-peer', version => '1.0.0' },
                agentCapabilities => {
                    loadSession     => JSON::PP::true,
                    streaming       => JSON::PP::true,
                    mcpCapabilities => { http => JSON::PP::true },
                },
                authMethods       => [],
            },
        });
        next;
    }

    if ($method eq 'session/new') {
        if (!$mcp_port && ref($params->{mcpServers}) eq 'ARRAY') {
            for my $srv (@{ $params->{mcpServers} }) {
                if (ref($srv) eq 'HASH' && defined $srv->{url} && $srv->{url} =~ m{^https?://[^:/]+:(\d+)/}) {
                    $mcp_port = int($1);
                    last;
                }
            }
        }
        my $sid = 'coop-sess-' . (++$sess_seq);
        send_msg({
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                sessionId => $sid,
                models    => {
                    currentModelId  => $cur_model,
                    availableModels => [
                        { modelId => 'gemini-2.5-pro', name => 'Gemini 2.5 Pro', description => 'Live coop peer' },
                    ],
                },
            },
        });
        next;
    }

    if ($method eq 'session/prompt') {
        my $sid  = $params->{sessionId} // 'coop-sess-1';
        my $text = join("\n", map { $_->{text} // '' } @{ $params->{prompt} || [] });
        record({ event => 'prompt_received', sessionId => $sid, text => $text });

        # Mode A: Full 4-model live bidirectional MCP cooperation probe
        if ($text =~ /\[COOP_ALL_4:(\{.*\})\]/s) {
            my $cfg_str = $1;
            utf8::encode($cfg_str) if utf8::is_utf8($cfg_str);
            my $cfg = eval { $json->decode($cfg_str) } || {};
            my %report;

            # 0a. MCP Streamable HTTP initialize
            my $init_r = mcp_http_request($mcp_port, 'POST', '/mcp', {
                jsonrpc => '2.0',
                id      => $mcp_id++,
                method  => 'initialize',
                params  => {
                    protocolVersion => '2025-03-26',
                    clientInfo      => { name => 'antigravity-coop-peer', version => '1.0.0' },
                    capabilities    => {},
                },
            });
            my $mcp_sid = $init_r->{session_id} // '';
            $report{initialize} = {
                ok               => $init_r->{ok},
                status           => $init_r->{status},
                session_id       => $mcp_sid,
                protocol_version => (ref($init_r->{json}) eq 'HASH' ? $init_r->{json}{result}{protocolVersion} : undef),
                engine           => (ref($init_r->{json}) eq 'HASH' ? $init_r->{json}{result}{serverInfo}{engine} : undef),
            };

            # 0b. notifications/initialized -> must return HTTP 202
            my $notif_r = mcp_http_request($mcp_port, 'POST', '/mcp', {
                jsonrpc => '2.0',
                method  => 'notifications/initialized',
                params  => {},
            }, $mcp_sid);
            $report{initialized_notif} = {
                ok         => $notif_r->{ok},
                status     => $notif_r->{status},
                session_id => $notif_r->{session_id},
            };

            # 0c. tools/list
            my $list_r = mcp_http_request($mcp_port, 'POST', '/mcp', {
                jsonrpc => '2.0',
                id      => $mcp_id++,
                method  => 'tools/list',
                params  => {},
            }, $mcp_sid);
            my @tool_names = map { $_->{name} } @{ (ref($list_r->{json}) eq 'HASH' && ref($list_r->{json}{result}{tools}) eq 'ARRAY') ? $list_r->{json}{result}{tools} : [] };
            $report{tools_list} = {
                ok         => $list_r->{ok},
                status     => $list_r->{status},
                session_id => $list_r->{session_id},
                count      => scalar(@tool_names),
                names      => \@tool_names,
            };

            # Step 1: neoperl_memory_write -> LIVE inproc_libllama embedder + LIVE Hy-Memory-30B-A3B
            send_msg({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'tool_call',
                        toolCallId    => 'tc-coop-mem-write',
                        title         => 'neoperl_memory_write',
                        status        => 'in_progress',
                    },
                },
            });
            $report{memory_write} = mcp_call_tool($mcp_port, $mcp_id++, $mcp_sid, 'neoperl_memory_write', {
                content     => 'IBM Db2 12.1.2 VECTOR_DISTANCE cosine similarity index stores 768-dim nomic-embed-text-v1.5 vectors.',
                scope_level => 'repo',
                repo_key    => $cfg->{repo_key} // 'coop-ws',
                category    => 'architecture',
                tags        => 'db2,vector,cosine',
            });
            send_msg({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'tool_call_update',
                        toolCallId    => 'tc-coop-mem-write',
                        title         => 'neoperl_memory_write',
                        status        => $report{memory_write}{ok} ? 'completed' : 'failed',
                    },
                },
            });

            # Step 2: neoperl_memory_search -> LIVE inproc_libllama embedder + VecSIMD RRF
            $report{memory_search} = mcp_call_tool($mcp_port, $mcp_id++, $mcp_sid, 'neoperl_memory_search', {
                query => 'Db2 VECTOR_DISTANCE cosine similarity',
                repo  => $cfg->{repo_key} // 'coop-ws',
                limit => 5,
            });

            # Step 3: neoperl_preprocess_doc -> LIVE Granite-Vision-4.1-4B (--mmproj --jinja)
            send_msg({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'tool_call',
                        toolCallId    => 'tc-coop-vision',
                        title         => 'neoperl_preprocess_doc',
                        status        => 'in_progress',
                    },
                },
            });
            $report{preprocess_doc} = mcp_call_tool($mcp_port, $mcp_id++, $mcp_sid, 'neoperl_preprocess_doc', {
                path   => $cfg->{png_path},
                format => 'markdown',
            });
            send_msg({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'tool_call_update',
                        toolCallId    => 'tc-coop-vision',
                        title         => 'neoperl_preprocess_doc',
                        status        => $report{preprocess_doc}{ok} ? 'completed' : 'failed',
                    },
                },
            });

            # Step 4: neoperl_delegate_local (kind => doc, wait => true) -> LIVE Ternary-Bonsai-2-27B
            # Under 14.0 GB budget (0.4 + 9.1 + 3.5 = 13.0 GB; +6.0 GB Bonsai => 19.0 > 14.0 GB),
            # this triggers live LRU PID eviction of Hy-Memory (9.1 GB) while keeping embedder pinned
            send_msg({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'tool_call',
                        toolCallId    => 'tc-coop-bonsai',
                        title         => 'neoperl_delegate_local',
                        status        => 'in_progress',
                    },
                },
            });
            $report{delegate_local} = mcp_call_tool($mcp_port, $mcp_id++, $mcp_sid, 'neoperl_delegate_local', {
                kind        => 'doc',
                target_path => $cfg->{doc_buf_path},
                wait        => JSON::PP::true,
                timeout     => 180,
            });
            my $deleg_jid = (ref($report{delegate_local}{data}) eq 'HASH') ? $report{delegate_local}{data}{job_id} : undef;
            $report{local_job_status} = mcp_call_tool($mcp_port, $mcp_id++, $mcp_sid, 'neoperl_local_job_status', {
                (defined $deleg_jid ? (job_id => $deleg_jid) : ()),
                action => 'status',
            });
            send_msg({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'tool_call_update',
                        toolCallId    => 'tc-coop-bonsai',
                        title         => 'neoperl_delegate_local',
                        status        => $report{delegate_local}{ok} ? 'completed' : 'failed',
                    },
                },
            });

            # Step 5: neoperl_read_buffer + neoperl_propose_edit on live unsaved buffer
            $report{read_buffer} = mcp_call_tool($mcp_port, $mcp_id++, $mcp_sid, 'neoperl_read_buffer', {
                path => $cfg->{edit_buf_path},
            });
            my $orig_txt = (ref($report{read_buffer}{data}) eq 'HASH') ? ($report{read_buffer}{data}{content} // '') : '';
            my $proposed = $orig_txt . "\n# Proposed via EditorMCP over live HTTP\n";
            $report{propose_edit} = mcp_call_tool($mcp_port, $mcp_id++, $mcp_sid, 'neoperl_propose_edit', {
                path     => $cfg->{edit_buf_path},
                new_text => $proposed,
                source   => 'antigravity_mcp',
                title    => 'Coop live edit proposal',
            });

            # Step 6: DELETE /mcp -> 204 No Content
            my $del_r = mcp_http_request($mcp_port, 'DELETE', '/mcp', undef, $mcp_sid);
            $report{delete_session} = {
                ok     => ($del_r->{status} == 204) ? 1 : 0,
                status => $del_r->{status},
            };

            send_msg({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'agent_message_chunk',
                        content       => { type => 'text', text => 'Completed live 4-model bidirectional MCP cooperation turn.' },
                    },
                },
            });
            send_msg({
                jsonrpc => '2.0',
                id      => $id,
                result  => {
                    stopReason => 'end_turn',
                    sessionId  => $sid,
                    coopReport => \%report,
                },
            });
            next;
        }

        # Mode B: ACP 1.0 streaming turn (no finalText or summary in response)
        if ($text =~ /\[STREAM_ONLY:(\{.*\})\]/s) {
            my $spec_str = $1;
            utf8::encode($spec_str) if utf8::is_utf8($spec_str);
            my $spec   = eval { $json->decode($spec_str) } || {};
            my $chunks = ref($spec->{chunks}) eq 'ARRAY' ? $spec->{chunks} : [ 'Streaming reply.' ];
            for my $ch (@$chunks) {
                send_msg({
                    jsonrpc => '2.0',
                    method  => 'session/update',
                    params  => {
                        sessionId => $sid,
                        update    => {
                            sessionUpdate => 'agent_message_chunk',
                            content       => { type => 'text', text => $ch },
                        },
                    },
                });
            }
            # Return only stopReason (strict ACP 1.0, no finalText or summary)
            send_msg({
                jsonrpc => '2.0',
                id      => $id,
                result  => { stopReason => 'end_turn' },
            });
            next;
        }

        # Mode C: Tier 2 inline escalation via ACP ([read:...] / general prompt)
        my $read_ok = 0;
        if ($text =~ /\[read:([^\]]+)\]/) {
            my $target = $1;
            my ($rres, $rerr) = call_client('fs/read_text_file', { path => $target });
            $read_ok = ($rres && defined $rres->{content}) ? 1 : 0;
        }

        send_msg({
            jsonrpc => '2.0',
            method  => 'session/update',
            params  => {
                sessionId => $sid,
                update    => {
                    sessionUpdate => 'agent_message_chunk',
                    content       => { type => 'text', text => "Escalated to Antigravity ACP cloud peer (read_ok=$read_ok)." },
                },
            },
        });
        send_msg({
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                stopReason => 'end_turn',
                readOk     => $read_ok,
            },
        });
        next;
    }

    if (defined $id) {
        send_msg({ jsonrpc => '2.0', id => $id, error => { code => -32601, message => "Unknown method: $method" } });
    }
}
exit 0;
END_ACP_PEER

    open my $ifh, '>', $impl_file or die "write $impl_file: $!";
    print {$ifh} $impl;
    close $ifh;

    my @inc_flags = map { my $q = $_; $q =~ s/'/'\\''/g; "-I'$q'" } grep { defined $_ && !ref($_) && -d $_ } @INC;
    my $perl_q    = $^X;
    $perl_q =~ s/'/'\\''/g;
    my $impl_q    = $impl_file;
    $impl_q =~ s/'/'\\''/g;

    open my $wfh, '>', $wrapper or die "write $wrapper: $!";
    print {$wfh} "#!/bin/sh\n";
    print {$wfh} "exec '$perl_q' " . join(' ', @inc_flags) . " '$impl_q' \"\$@\"\n";
    close $wfh;
    chmod 0755, $wrapper or die "chmod $wrapper: $!";
    return $wrapper;
}

sub _read_acp_log {
    my ($log_file) = @_;
    return [] unless defined $log_file && -f $log_file;
    open my $fh, '<:raw', $log_file or return [];
    my @entries;
    while (my $line = <$fh>) {
        $line =~ s/[\r\n]+$//;
        next unless length $line;
        my $obj = eval { JSON::PP->new->utf8->decode($line) };
        push @entries, $obj if ref($obj) eq 'HASH';
    }
    close $fh;
    return \@entries;
}

# Probe local inference environment
my $MOCK_FORCED   = $ENV{NEOPERL_INFERENCE_MOCK} ? 1 : 0;
my $HAS_SQLITE    = eval { require DBI; require DBD::SQLite; 1 } ? 1 : 0;
my $PROBE_CFG     = NeoPerl::Inference::Config->new(auto_discover => 1);
my $PROBE_HUB     = NeoPerl::Inference::ModelHub->new(config => $PROBE_CFG);
my $DOCTOR        = $PROBE_HUB->doctor_report();
my %ROLE_READY    = map { $_->{role} => $_->{ready} } @{ $DOCTOR->{roles} };
my $HAS_LIBLLAMA  = ($DOCTOR->{llama_bridge} && $DOCTOR->{llama_bridge}{available}) ? 1 : 0;
my $IS_POWER      = NeoPerl::Inference::Config::is_power_arch() ? 1 : 0;
my $LOCAL_AI_SKIP = $PROBE_CFG->local_ai_skipped_reason() // '';
my $ALL_LIVE      = (!$MOCK_FORCED && !$IS_POWER && !length($LOCAL_AI_SKIP) && $HAS_SQLITE && $DOCTOR->{all_ready}) ? 1 : 0;

note(sprintf(
    'Cooperation probe: mock=%d accel=%s power=%d skip=%s sqlite=%d libllama=%d ready=%d/%d (%s) mojo_mcp=%d',
    $MOCK_FORCED, $PROBE_CFG->accelerator(), $IS_POWER,
    (length($LOCAL_AI_SKIP) ? $LOCAL_AI_SKIP : 'none'),
    $HAS_SQLITE, $HAS_LIBLLAMA,
    $DOCTOR->{ready_count}, $DOCTOR->{total_roles},
    join(', ', map { "$_->{role}=" . ($_->{ready} ? $_->{transport} : 'missing') } @{ $DOCTOR->{roles} }),
    NeoPerl::Antigravity::EditorMCP::has_mojo(),
));

# ---------------------------------------------------------------------------
# Subtest 0: Hardware Accelerator & POWER/AIX Local-AI Gate (runs on all hosts)
# ---------------------------------------------------------------------------
subtest '0. Hardware Accelerator & POWER/AIX Local-AI Gate (remote_http preserved)' => sub {
    # 0A. POWER ppc64le skips local inproc_libllama / managed_server auto-promotion
    my $ppc_cfg = NeoPerl::Inference::Config->new(
        auto_discover => 1,
        os            => 'linux',
        arch          => 'ppc64le',
    );
    is($ppc_cfg->is_power_arch(), 1, 'ppc64le detected as POWER architecture');
    is($ppc_cfg->accelerator(), 'none', 'ppc64le accelerator is none');
    like($ppc_cfg->local_ai_skipped_reason(), qr/POWER|AIX/i,
        'ppc64le sets descriptive POWER/AIX skip reason');
    for my $r ($ppc_cfg->role_names) {
        is($ppc_cfg->role_config($r)->{transport}, 'loopback',
            "ppc64le skips local AI auto-promotion for $r");
    }

    # 0B. POWER ppc64le STILL honors explicit remote_url -> remote_http
    my $ppc_rem = NeoPerl::Inference::Config->new(
        auto_discover => 1,
        os            => 'linux',
        arch          => 'ppc64le',
        roles         => {
            embedder => { remote_url => 'http://gpu-host.example.test:8080' },
        },
    );
    is($ppc_rem->role_config('embedder')->{transport}, 'remote_http',
        'ppc64le still honors explicit remote_url -> remote_http');
    is($ppc_rem->role_config('worker_small')->{transport}, 'loopback',
        'ppc64le keeps unconfigured local roles on loopback');

    # 0C. CPU/iGPU-only Linux x86_64 (accelerator => none) skips local AI auto-promotion
    my $cpu_cfg = NeoPerl::Inference::Config->new(
        auto_discover => 1,
        os            => 'linux',
        arch          => 'x86_64',
        accelerator   => 'none',
        roles         => {
            memory_writer => { remote_url => 'http://gpu-host.example.test:8081' },
        },
    );
    is($cpu_cfg->is_power_arch(), 0, 'linux x86_64 is not POWER');
    is($cpu_cfg->accelerator(), 'none', 'CPU-only linux x86_64 accelerator is none');
    ok(length($cpu_cfg->local_ai_skipped_reason()) > 0,
        'CPU-only linux x86_64 reports non-empty local_ai_skipped_reason');
    is($cpu_cfg->role_config('embedder')->{transport}, 'loopback',
        'CPU-only linux x86_64 skips local embedder auto-promotion');
    is($cpu_cfg->role_config('vision_doc')->{transport}, 'loopback',
        'CPU-only linux x86_64 skips local vision_doc auto-promotion');
    is($cpu_cfg->role_config('worker_small')->{transport}, 'loopback',
        'CPU-only linux x86_64 skips local worker_small auto-promotion');
    is($cpu_cfg->role_config('memory_writer')->{transport}, 'remote_http',
        'CPU-only linux x86_64 still honors explicit remote_url -> remote_http');

    # 0D. macOS Apple Silicon arm64 detects Metal and auto-promotes when weights exist
    my $mac_cfg = NeoPerl::Inference::Config->new(
        auto_discover => 1,
        os            => 'darwin',
        arch          => 'arm64',
    );
    is($mac_cfg->is_power_arch(), 0, 'darwin arm64 is not POWER');
    is($mac_cfg->accelerator(), 'metal', 'darwin arm64 detects metal accelerator');
    is($mac_cfg->local_ai_skipped_reason(), '', 'darwin arm64 has empty local_ai_skipped_reason');
    if ($ALL_LIVE) {
        is($mac_cfg->role_config('embedder')->{transport},
            ($HAS_LIBLLAMA ? 'inproc_libllama' : 'managed_server'),
            'darwin arm64 auto-promotes live embedder cleanly');
        is($mac_cfg->role_config('memory_writer')->{transport}, 'managed_server',
            'darwin arm64 auto-promotes live memory_writer cleanly');
        is($mac_cfg->role_config('vision_doc')->{transport}, 'managed_server',
            'darwin arm64 auto-promotes live vision_doc cleanly');
        is($mac_cfg->role_config('worker_small')->{transport}, 'managed_server',
            'darwin arm64 auto-promotes live worker_small cleanly');
    }

    # 0E. ModelHub doctor_report surfaces accelerator and local_ai_skipped_reason
    my $ppc_doc = NeoPerl::Inference::ModelHub->new(config => $ppc_cfg)->doctor_report();
    is($ppc_doc->{accelerator}, 'none', 'ModelHub doctor_report exposes accelerator');
    like($ppc_doc->{local_ai_skipped_reason} // '', qr/POWER|AIX/i,
        'ModelHub doctor_report exposes local_ai_skipped_reason on POWER');
};

my $TMP      = tempdir(CLEANUP => 1);
my $ACP_PEER = _build_acp_peer_script($TMP);

# ---------------------------------------------------------------------------
# Subtest 1 + Subtest 2 share App A (unified NeoPerl::MT, 14.0 GB budget)
# so Subtest 2 naturally verifies SHA-256 cache hit on PNG #1 AND cache miss
# on fresh PNG #2 plus live nomic-embed auto-context and @memory recall.
# ---------------------------------------------------------------------------
my ($APP_A, $LOG_A, $WS_A, $PNG1_PATH);

subtest '1. Live Bidirectional ACP <-> EditorMCP (Mojolicious HTTP) <-> ALL 4 Metal Models + Live LRU Eviction' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'DBI + DBD::SQLite required' unless $HAS_SQLITE;
    plan skip_all => 'All 4 live local GGUF models + binaries required' unless $DOCTOR->{all_ready};

    $WS_A = File::Spec->catdir($TMP, 'ws_coop_1');
    mkdir $WS_A or die "mkdir $WS_A: $!";
    $WS_A  = abs_path($WS_A) || $WS_A;
    $LOG_A = File::Spec->catfile($TMP, 'acp_coop_1.log');
    unlink $LOG_A if -f $LOG_A;

    local $ENV{COOP_ACP_LOG} = $LOG_A;

    my $t_boot = time();
    my $app = _track_app(NeoPerl::MT->new(
        cwd           => $WS_A,
        ui            => 'tui',
        headless      => 1,
        cols          => 132,
        rows          => 40,
        auto_discover => 1,
        ram_budget_gb => 14.0,
        agy_bin       => $ACP_PEER,
        start_mcp     => 1,
        load_config   => 0,
    ));
    $APP_A = $app;
    my $boot_ms = int((time() - $t_boot) * 1000);

    ok($app->editor_mcp->is_running, "EditorMCP running on port " . ($app->editor_mcp->port // 0));
    if (NeoPerl::Antigravity::EditorMCP::has_mojo()) {
        is($app->editor_mcp->engine, 'Mojolicious', 'EditorMCP uses live Mojolicious Mojo::Server::Daemon');
    }

    # Wait for async ACP connect_async() handshake
    ok(_wait_until(sub { $app->editor->pump(); $app->acp->state eq 'ready' }, 10.0),
        "ACP connect_async() reached state=ready (boot=${boot_ms}ms)");
    is($app->acp->is_mock, 0, 'ACP launched executable peer script (non-mock)');

    # Verify launch flags and session/new mcpServers
    my $entries = _read_acp_log($LOG_A);
    my ($spawn) = grep { ($_->{event} // '') eq 'spawn' } @$entries;
    ok($spawn, 'ACP peer recorded spawn');
    my $argv_str = join(' ', @{ $spawn->{argv} || [] });
    my $mcp_port = $app->editor_mcp->port;
    like($argv_str, qr/\bacp\b/,                       'ACP launched with acp subcommand');
    like($argv_str, qr/--process-per-session\b/,       'ACP launched with --process-per-session');
    like($argv_str, qr/--ide-mcp-port \Q$mcp_port\E\b/,'ACP launched with --ide-mcp-port <port>');
    like($argv_str, qr/--add-dir \Q$WS_A\E/,           'ACP launched with --add-dir <ws>');

    my ($snew) = grep { ($_->{event} // '') eq 'rpc' && ($_->{method} // '') eq 'session/new' } @$entries;
    ok($snew, 'ACP peer received session/new');
    my $mcps = $snew->{params}{mcpServers} || [];
    is(scalar(@$mcps), 1, 'session/new includes 1 mcpServers entry');
    is($mcps->[0]{type}, 'http', 'session/new mcpServers type => http');
    is($mcps->[0]{url}, "http://127.0.0.1:$mcp_port/mcp", 'session/new mcpServers url matches EditorMCP');

    # Prepare two live open NeoPerl buffers and a freshly rendered Retina PNG
    my $doc_path  = File::Spec->catfile($WS_A, 'CoopMath.pm');
    my $edit_path = File::Spec->catfile($WS_A, 'CoopUnsaved.pm');
    my $doc_src = <<'END_DOC_PM';
package CoopMath;
use strict;
use warnings;

sub add_values {
    my ($a, $b) = @_;
    return $a + $b;
}

sub multiply_values {
    my ($a, $b) = @_;
    return $a * $b;
}

1;
END_DOC_PM
    my $unsaved_src = <<'END_UNSAVED_PM';
package CoopUnsaved;
use strict;
use warnings;

# UNSAVED_IN_MEMORY_MARKER_42
sub greet {
    my ($name) = @_;
    return "Hello, $name";
}

1;
END_UNSAVED_PM

    my $doc_buf = $app->editor->create_buffer(
        name     => 'CoopMath.pm',
        path     => $doc_path,
        filetype => 'perl',
        text     => $doc_src,
    );
    my $edit_buf = $app->editor->create_buffer(
        name     => 'CoopUnsaved.pm',
        path     => $edit_path,
        filetype => 'perl',
        text     => $unsaved_src,
    );
    $app->editor->switch_buffer($doc_buf->id);

    $PNG1_PATH = File::Spec->catfile($WS_A, 'coop_spec_1.png');
    my $renderer = _render_readable_png($PNG1_PATH);
    ok(-f $PNG1_PATH && (-s $PNG1_PATH) > 500,
        "rendered Retina PNG #1 via $renderer (" . (-s $PNG1_PATH) . " bytes)");

    # Observe live OS PIDs mid-conversation via ACP session/update streaming callbacks
    my ($hymem_pid_mid, $vision_pid_mid, $ram_after_vision);
    my $orig_on_update = $app->acp->{callbacks}{on_update};
    $app->acp->set_callback('on_update', sub {
        my ($norm) = @_;
        $orig_on_update->($norm) if $orig_on_update;
        my $upd = $norm->{update} || {};
        if (($upd->{sessionUpdate} // '') eq 'tool_call_update' && ($upd->{status} // '') eq 'completed') {
            my %slots = map { $_->{role} => $_ } @{ $app->inference->slot_status };
            if (($upd->{toolCallId} // '') eq 'tc-coop-mem-write') {
                $hymem_pid_mid = $slots{memory_writer}{pid};
            }
            elsif (($upd->{toolCallId} // '') eq 'tc-coop-vision') {
                $vision_pid_mid   = $slots{vision_doc}{pid};
                $ram_after_vision = $app->inference->resident_gb;
            }
        }
    });

    # Synchronous send_chat() while external ACP child calls all 4 Metal models via EditorMCP HTTP
    my $cfg_json = JSON::PP->new->utf8->encode({
        repo_key      => $app->modalities->{repo_key},
        png_path      => $PNG1_PATH,
        doc_buf_path  => $doc_path,
        edit_buf_path => $edit_path,
    });
    my $t_turn = time();
    my $chat_res = $app->modalities->send_chat(
        "Run full live 4-model cooperation [COOP_ALL_4:$cfg_json]",
        timeout => 240,
    );
    my $turn_s = time() - $t_turn;

    ok($chat_res->{ok}, sprintf('synchronous send_chat() completed with ZERO deadlock/re-entrancy crash (%.2fs)', $turn_s));
    my $rep = $chat_res->{acp_result}{coopReport};
    is(ref($rep), 'HASH', 'ACP peer returned full coopReport from live HTTP MCP round-trips');

    # 0. MCP Streamable HTTP 2025-03-26 handshake assertions
    ok($rep->{initialize}{ok} && $rep->{initialize}{status} == 200, 'MCP initialize returned HTTP 200');
    is($rep->{initialize}{protocol_version}, '2025-03-26', 'MCP initialize negotiated 2025-03-26');
    ok(defined($rep->{initialize}{session_id}) && length($rep->{initialize}{session_id}) > 8,
        "MCP initialize issued Mcp-Session-Id ($rep->{initialize}{session_id})");
    is($rep->{initialized_notif}{status}, 202, 'MCP notifications/initialized returned HTTP 202');
    ok($rep->{tools_list}{ok} && $rep->{tools_list}{count} >= 23,
        "MCP tools/list returned $rep->{tools_list}{count} tools (>= 23)");
    is($rep->{tools_list}{session_id}, $rep->{initialize}{session_id}, 'EditorMCP echoed Mcp-Session-Id header');

    # 1. neoperl_memory_write -> LIVE inproc_libllama embedder + LIVE Hy-Memory-30B-A3B
    my $mw = $rep->{memory_write};
    ok($mw->{ok}, '1) neoperl_memory_write succeeded over live HTTP from inside EditorMCP')
        or diag(JSON::PP->new->encode($mw));
    is($mw->{data}{action}, 'ADD', '1) LIVE Hy-Memory-30B-A3B reconciled ADD');
    is($mw->{data}{transport}, 'managed_server', '1) Hy-Memory executed via live managed_server (not loopback)');
    ok(($mw->{data}{tok_per_s} // 0) > 0, "1) Hy-Memory tok/s=" . ($mw->{data}{tok_per_s} // 0));
    ok(defined($hymem_pid_mid) && $hymem_pid_mid > 0, "1) captured live Hy-Memory OS PID=$hymem_pid_mid mid-turn");

    # 2. neoperl_memory_search -> LIVE inproc_libllama embedder + VecSIMD RRF
    my $ms = $rep->{memory_search};
    ok($ms->{ok}, '2) neoperl_memory_search succeeded over live HTTP');
    ok(($ms->{data}{count} // 0) >= 1, "2) neoperl_memory_search returned $ms->{data}{count} hit(s)");
    like($ms->{data}{results}[0]{content} // '', qr/Db2|VECTOR_DISTANCE/i,
        '2) freshly written Db2 memory recalled via live nomic-embed + VecSIMD RRF');

    # 3. neoperl_preprocess_doc -> LIVE Granite-Vision-4.1-4B (--mmproj --jinja)
    my $vd = $rep->{preprocess_doc};
    ok($vd->{ok}, '3) neoperl_preprocess_doc succeeded over live HTTP from inside EditorMCP')
        or diag(JSON::PP->new->encode($vd));
    is($vd->{data}{cached}, 0, '3) first PNG preprocess is a live Granite-Vision cache miss');
    ok(defined($vd->{data}{doc_id}) && $vd->{data}{doc_id} > 0, "3) SHA-256 cached doc_id=$vd->{data}{doc_id}");
    like($vd->{data}{content} // '', qr/NeoPerl/i,         '3) Granite-Vision OCR read "NeoPerl"');
    like($vd->{data}{content} // '', qr/Db2/i,             '3) Granite-Vision OCR read "Db2"');
    like($vd->{data}{content} // '', qr/VECTOR_DISTANCE/i, '3) Granite-Vision OCR read "VECTOR_DISTANCE"');
    ok(($vd->{data}{tok_per_s} // 0) > 0, "3) Granite-Vision tok/s=" . ($vd->{data}{tok_per_s} // 0));
    ok(defined($vision_pid_mid) && $vision_pid_mid > 0, "3) captured live Granite-Vision OS PID=$vision_pid_mid mid-turn");

    # 4. neoperl_delegate_local (kind => doc, wait => true) -> LIVE Ternary-Bonsai-2-27B
    my $dl = $rep->{delegate_local};
    ok($dl->{ok}, '4) neoperl_delegate_local(wait => true) succeeded over live HTTP from inside EditorMCP')
        or diag(JSON::PP->new->encode($dl));
    is($dl->{data}{status}, 'staged', '4) Bonsai doc job reached status=staged');
    is($dl->{data}{syntax_ok}, 1, "4) Bonsai doc output passed real perl -c ($dl->{data}{syntax_output})");
    ok(($dl->{data}{tok_per_s} // 0) > 0, "4) Ternary-Bonsai tok/s=" . ($dl->{data}{tok_per_s} // 0));
    my $doc_hunks = $doc_buf->list_diff_hunks;
    ok(ref($doc_hunks) eq 'ARRAY' && @$doc_hunks >= 1,
        '4) Myers inline diff hunks staged onto live NeoPerl buffer (' . scalar(@{$doc_hunks || []}) . ' hunk(s))');
    my $js = $rep->{local_job_status};
    ok($js->{ok} && ($js->{data}{summary}{cloud_tokens_saved} // 0) > 0,
        '4) neoperl_local_job_status confirmed cloud_tokens_saved=' . ($js->{data}{summary}{cloud_tokens_saved} // 0));

    # 5. neoperl_read_buffer + neoperl_propose_edit -> live unsaved buffer round-trip
    my $rb = $rep->{read_buffer};
    ok($rb->{ok}, '5) neoperl_read_buffer succeeded over live HTTP');
    is($rb->{data}{source}, 'buffer', '5) neoperl_read_buffer read live in-memory buffer (not disk)');
    like($rb->{data}{content} // '', qr/UNSAVED_IN_MEMORY_MARKER_42/, '5) unsaved buffer marker round-tripped');

    my $pe = $rep->{propose_edit};
    ok($pe->{ok} && $pe->{data}{staged}, '5) neoperl_propose_edit staged inline diff over live HTTP');
    ok(($pe->{data}{hunk_count} // 0) >= 1, "5) neoperl_propose_edit produced $pe->{data}{hunk_count} hunk(s)");
    ok(scalar(@{ $edit_buf->list_diff_hunks || [] }) >= 1, '5) live unsaved buffer carries staged edit hunks');

    # DELETE /mcp -> 204
    is($rep->{delete_session}{status}, 204, 'MCP DELETE /mcp returned HTTP 204 No Content');

    # Assert live LRU RAM eviction occurred mid-conversation under 14.0 GB budget
    my $ev_log = $app->inference->eviction_log;
    ok(@$ev_log >= 1, 'LIVE LRU RAM eviction triggered mid-conversation under 14.0 GB budget (' . scalar(@$ev_log) . ' event(s))');
    my ($ev_hy) = grep { $_->{role} eq 'memory_writer' } @$ev_log;
    ok($ev_hy, 'LRU evicted unpinned memory_writer (9.1 GB) to make room for worker_small (6.0 GB)');
    ok(!kill(0, $hymem_pid_mid), "evicted Hy-Memory OS PID=$hymem_pid_mid was cleanly terminated & reaped");

    my %final_slots = map { $_->{role} => $_ } @{ $app->inference->slot_status };
    is($final_slots{embedder}{loaded}, 1, 'pinned embedder stayed resident throughout LRU eviction');
    is($final_slots{embedder}{transport}, ($HAS_LIBLLAMA ? 'inproc_libllama' : 'managed_server'),
        'embedder stayed on live inproc_libllama transport');
    is($final_slots{embedder}{evict_count}, 0, 'pinned embedder was NEVER evicted');
    is($final_slots{worker_small}{loaded}, 1, 'worker_small (Ternary-Bonsai) resident after eviction');
    ok($app->inference->resident_gb <= 14.0,
        sprintf('resident_gb (%.2f GB) strictly within 14.0 GB budget', $app->inference->resident_gb));
    is($app->acp->state, 'ready', 'ACP stayed healthy (state=ready) across all 4 live models + LRU eviction');
    ok($app->editor_mcp->is_running, 'EditorMCP stayed healthy (running) across all 4 live models + LRU eviction');

    note(sprintf(
        'METRICS[Subtest1/Bidirectional-4Model]: turn=%.2fs hymem=%.2f tok/s (%dms, evicted pid=%d) vision=%.2f tok/s (%dms) bonsai=%.2f tok/s (%dms) ram_peak=%.1fGB ram_final=%.1fGB',
        $turn_s,
        $mw->{data}{tok_per_s} // 0, $mw->{data}{elapsed_ms} // 0, $hymem_pid_mid,
        $vd->{data}{tok_per_s} // 0, $vd->{data}{elapsed_ms} // 0,
        $dl->{data}{tok_per_s} // 0, $dl->{data}{elapsed_ms} // 0,
        $ram_after_vision // 0, $app->inference->resident_gb,
    ));

    # Clear queued AgyTurnComplete from Subtest 1 so Subtest 2 starts cleanly
    $app->memory_writer->{queue} = [];
};

# ---------------------------------------------------------------------------
# Subtest 2: Prompt Enrichment BEFORE `agy` (@image + @memory + :MemAutoContext on)
# ---------------------------------------------------------------------------
subtest '2. Prompt Enrichment BEFORE agy (@image cache hit/miss + @memory + :MemAutoContext on)' => sub {
    plan skip_all => 'Subtest 1 live App A not available' unless $APP_A;

    local $ENV{COOP_ACP_LOG} = $LOG_A;
    my $app = $APP_A;

    my $mac = $app->editor->exec_command(':MemAutoContext on');
    ok($mac->{ok} && $mac->{auto_context} == 1, ':MemAutoContext on enabled');

    # 2A: Same PNG #1 (SHA-256 NPL_DOC_CACHE HIT) + @memory:db2_vector + auto-context hint
    my $r_hit = $app->modalities->send_chat(
        "Review \@image:$PNG1_PATH and \@memory:db2_vector for our Db2 vector cosine design",
        timeout => 120,
    );
    ok($r_hit->{ok}, '2A) enriched chat turn with @image (cache hit) + @memory + :MemAutoContext completed');

    my ($img_att1) = grep { ($_->{kind} // '') eq 'image' } @{ $r_hit->{expanded}{attachments} || [] };
    ok($img_att1, '2A) @image attachment expanded');
    is($img_att1->{cached}, 1, '2A) same PNG #1 hit SHA-256 NPL_DOC_CACHE (cached == 1)');

    my @prompts = grep { ($_->{event} // '') eq 'prompt_received' } @{ _read_acp_log($LOG_A) };
    my $sent1 = $prompts[-1]{text} // '';

    like($sent1, qr/\A\[Memory Context Hint\]\n/, '2A) exact session/prompt begins with [Memory Context Hint]');
    my ($hint_block) = ($sent1 =~ /\A(\[Memory Context Hint\]\n.*?)(?:\n\n|\z)/s);
    ok(defined($hint_block) && length($hint_block) <= 1000,
        sprintf('2A) [Memory Context Hint] strictly <= 1000 chars (len=%d)', length($hint_block // '')));
    like($hint_block // '', qr/Db2|VECTOR_DISTANCE/i,
        '2A) [Memory Context Hint] injected live nomic-embed recalled Db2 memory');
    like($sent1, qr/\[memory\]\s+db2 vector\n.*Db2/is, '2A) [memory] attachment populated from live memory search');
    like($sent1, qr/\[image\]\s+\Q$PNG1_PATH\E\n.*NeoPerl.*Db2/is,
        '2A) [image] attachment contains Granite-Vision verbatim OCR Markdown');
    unlike($sent1, qr/data:image\/png;base64|iVBORw0KGgo/i,
        '2A) ZERO raw base64 PNG bytes sent to agy');

    # 2B: Fresh PNG #2 -> SHA-256 cache miss -> live Granite-Vision-4.1-4B OCR before agy
    my $png2 = File::Spec->catfile($WS_A, 'coop_spec_2_fresh.png');
    my $ren2 = _render_readable_png($png2, [
        { text => 'NeoPerl POWER8 VSX Kernel',  font => ['Helvetica', 24], y => 36  },
        { text => 'SIMD Op: vec_madd 4-way',    font => ['Helvetica', 20], y => 96  },
        { text => 'sub dot_vsx { return 42; }', font => ['Courier', 18],   y => 156 },
    ]);
    ok(-f $png2 && (-s $png2) > 500, "2B) rendered fresh PNG #2 via $ren2 (" . (-s $png2) . " bytes)");

    my $t_miss = time();
    my $r_miss = $app->modalities->send_chat(
        "Explain \@image:$png2 kernel optimization",
        timeout => 180,
    );
    my $miss_s = time() - $t_miss;
    ok($r_miss->{ok}, sprintf('2B) enriched chat turn with fresh @image (cache miss) completed (%.2fs)', $miss_s));

    my ($img_att2) = grep { ($_->{kind} // '') eq 'image' } @{ $r_miss->{expanded}{attachments} || [] };
    ok($img_att2, '2B) fresh @image attachment expanded');
    is($img_att2->{cached}, 0, '2B) fresh PNG #2 triggered live Granite-Vision cache miss (cached == 0)');

    @prompts = grep { ($_->{event} // '') eq 'prompt_received' } @{ _read_acp_log($LOG_A) };
    my $sent2 = $prompts[-1]{text} // '';
    like($sent2, qr/\[image\]\s+\Q$png2\E\n.*(?:POWER8|VSX|NeoPerl)/is,
        '2B) fresh [image] attachment contains Granite-Vision verbatim OCR Markdown for PNG #2');
    unlike($sent2, qr/data:image\/png;base64|iVBORw0KGgo/i,
        '2B) ZERO raw base64 PNG bytes sent to agy on cache miss');

    note(sprintf(
        'METRICS[Subtest2/PromptEnrichment]: hint_len=%d png1_cached=%d png2_cached=%d png2_live_s=%.2f',
        length($hint_block // ''), $img_att1->{cached}, $img_att2->{cached}, $miss_s,
    ));

    # Cleanly shut down App A before isolated Subtest 3
    $app->shutdown();
    $APP_A = undef;
};

# ---------------------------------------------------------------------------
# Subtest 3: Closed-Loop Post-Turn Memory Reconciliation AFTER `agy`
#            AgyTurnComplete -> LIVE Hy-Memory-30B-A3B -> Next-Turn Recall + Redaction
# ---------------------------------------------------------------------------
subtest '3. Closed-Loop Post-Turn Memory Reconciliation AFTER agy (ADD -> SUPERSEDE/UPDATE -> Redact -> Recall)' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'DBI + DBD::SQLite required' unless $HAS_SQLITE;
    plan skip_all => 'memory_writer + embedder live GGUFs required'
        unless $ROLE_READY{memory_writer} && $ROLE_READY{embedder};

    my $ws3 = File::Spec->catdir($TMP, 'ws_coop_3');
    mkdir $ws3 or die "mkdir $ws3: $!";
    $ws3 = abs_path($ws3) || $ws3;
    my $log3 = File::Spec->catfile($TMP, 'acp_coop_3.log');
    unlink $log3 if -f $log3;

    local $ENV{COOP_ACP_LOG} = $log3;

    my $app = _track_app(NeoPerl::MT->new(
        cwd           => $ws3,
        ui            => 'tui',
        headless      => 1,
        auto_discover => 1,
        ram_budget_gb => 16.0,
        agy_bin       => $ACP_PEER,
        start_mcp     => 1,
        load_config   => 0,
    ));

    ok(_wait_until(sub { $app->editor->pump(); $app->acp->state eq 'ready' }, 10.0),
        'App B ACP connected ready');

    my @turn_events;
    $app->editor->on('AgyTurnComplete', sub {
        my %ev = (@_ == 1 && ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_;
        push @turn_events, \%ev;
    });

    # Turn 1: Stream ACP 1.0 nested agent_message_chunk (no finalText), pump -> live Hy-Memory ADD
    my $spec1 = JSON::PP->new->utf8->encode({
        chunks => [
            'Architectural decision: NeoPerl uses HTTP::Tiny ',
            'for all outbound inference transport calls.',
        ],
    });
    my $t1_res = $app->modalities->send_chat(
        "Record our transport decision [STREAM_ONLY:$spec1]",
        timeout => 60,
    );
    ok($t1_res->{ok}, 'Turn 1 streamed ACP 1.0 response (NO finalText)');
    ok(!exists $t1_res->{acp_result}{finalText}, 'Turn 1 ACP result intentionally omitted finalText');
    is(scalar(@turn_events), 1, 'Turn 1 emitted AgyTurnComplete');
    is($turn_events[0]{response},
        'Architectural decision: NeoPerl uses HTTP::Tiny for all outbound inference transport calls.',
        'AgyTurnComplete captured exact coalesced streamed agent_message_chunk text');
    unlike($turn_events[0]{summary}, qr/\[Memory Context Hint\]/, 'Turn 1 summary excludes [Memory Context Hint]');
    is($app->memory_writer->pending, 1, 'Memory::Writer queued 1 event from AgyTurnComplete');

    my $p1_t0 = time();
    $app->modalities->pump();
    my $p1_s = time() - $p1_t0;

    is($app->memory_writer->pending, 0, 'Turn 1 queue drained by modalities->pump()');
    my $st1 = $app->memory_writer->stats;
    is($st1->{added}, 1, sprintf('Turn 1 reconciled ADD via LIVE Hy-Memory-30B-A3B (%.2fs)', $p1_s));
    my $evs1 = $app->memory_store->list_events(repo => $app->modalities->{repo_key}, limit => 10);
    is($evs1->[0]{action_taken}, 'ADD', 'NPL_MEMORY_EVENTS logged ADD for Turn 1');
    my $id1 = $evs1->[0]{target_memory_id};
    ok(defined($id1) && $id1 > 0, "Turn 1 persisted memory id=$id1");

    # Verify live Hy-Memory managed_server was used (not loopback)
    my ($mslot) = grep { $_->{role} eq 'memory_writer' } @{ $app->inference->slot_status };
    is($mslot->{transport}, 'managed_server', 'Turn 1 ran on LIVE Hy-Memory-30B-A3B managed_server');

    # Turn 2: Stream replacement decision -> pump -> live Hy-Memory SUPERSEDE or UPDATE with lineage
    my $spec2 = JSON::PP->new->utf8->encode({
        chunks => [
            'Architectural replacement: We replaced HTTP::Tiny with Mojo::UserAgent from mojolicious-mt ',
            'for all outbound inference transport calls.',
        ],
    });
    my $t2_res = $app->modalities->send_chat(
        "Update our transport decision [STREAM_ONLY:$spec2]",
        timeout => 60,
    );
    ok($t2_res->{ok}, 'Turn 2 streamed replacement decision (NO finalText)');

    my $p2_t0 = time();
    $app->modalities->pump();
    my $p2_s = time() - $p2_t0;

    my $st2 = $app->memory_writer->stats;
    ok(($st2->{superseded} >= 1) || ($st2->{updated} >= 1),
        sprintf('Turn 2 reconciled SUPERSEDE/UPDATE via LIVE Hy-Memory (superseded=%d, updated=%d, %.2fs)',
            $st2->{superseded}, $st2->{updated}, $p2_s));

    my $evs2 = $app->memory_store->list_events(repo => $app->modalities->{repo_key}, limit => 10);
    my $act2 = $evs2->[0]{action_taken} // '';
    like($act2, qr/^(?:SUPERSEDE|UPDATE)$/, "NPL_MEMORY_EVENTS recorded $act2 for Turn 2");
    if ($act2 eq 'SUPERSEDE') {
        my $old_row = $app->memory_store->get_memory($id1);
        ok(defined $old_row->{superseded_by_id} && $old_row->{superseded_by_id} > 0,
            "Turn 2 SUPERSEDE linked old id=$id1 -> superseded_by_id=$old_row->{superseded_by_id}");
        ok(defined $old_row->{valid_until}, 'old memory marked with VALID_UNTIL timestamp');
    }
    else {
        my $upd_row = $app->memory_store->get_memory($id1);
        like($upd_row->{content} // '', qr/Mojo::UserAgent/i, 'Turn 2 UPDATE stored Mojo::UserAgent');
    }

    # Turn 3: Stream fake secret -> assert redacted before reaching Hy-Memory and not stored verbatim
    my $fake_secret = 'sk-test-secretkey1234567890abcdef';
    my $spec3 = JSON::PP->new->utf8->encode({
        chunks => [
            "Staging integration note: outbound telemetry uses key $fake_secret in lab environment.",
        ],
    });
    my $t3_res = $app->modalities->send_chat(
        "Note our telemetry setup [STREAM_ONLY:$spec3]",
        timeout => 60,
    );
    ok($t3_res->{ok}, 'Turn 3 streamed turn containing synthetic secret');

    # Inspect inference->complete payload to verify secret is redacted before reaching Hy-Memory
    my $payload_sent_to_hymem = '';
    my $orig_complete = \&NeoPerl::Inference::Manager::complete;
    {
        no warnings 'redefine';
        local *NeoPerl::Inference::Manager::complete = sub {
            my ($self_m, %a) = @_;
            if (($a{role} // '') eq 'memory_writer' && ref($a{messages}) eq 'ARRAY') {
                $payload_sent_to_hymem .= join("\n", map { $_->{content} // '' } @{ $a{messages} });
            }
            return $orig_complete->($self_m, %a);
        };
        $app->modalities->pump();
    }

    my $st3 = $app->memory_writer->stats;
    ok($st3->{redactions} >= 1, "Turn 3 MemIgnore recorded $st3->{redactions} secret redaction(s)");
    unlike($payload_sent_to_hymem, qr/\Q$fake_secret\E/,
        'synthetic secret was REDACTED BEFORE reaching LIVE Hy-Memory-30B-A3B');
    like($payload_sent_to_hymem, qr/\[REDACTED:SECRET_KEY\]/,
        'Hy-Memory received [REDACTED:SECRET_KEY] placeholder instead of raw secret');

    my $all_mems = $app->memory_store->search(
        query              => 'telemetry secret staging',
        repo_key           => $app->modalities->{repo_key},
        include_superseded => 1,
        limit              => 20,
        update_access      => 0,
    );
    my $all_evs = $app->memory_store->list_events(repo => $app->modalities->{repo_key}, limit => 20);
    my $joined_store = join("\n",
        (map { $_->{content} // '' } @$all_mems),
        (map { $_->{payload_summary} // '' } @$all_evs),
    );
    unlike($joined_store, qr/\Q$fake_secret\E/,
        'synthetic secret NEVER stored verbatim anywhere in Memory::Store or NPL_MEMORY_EVENTS');

    # Turn 4: Enable :MemAutoContext on -> assert replacement decision is auto-injected
    $app->editor->exec_command(':MemAutoContext on');
    my $spec4 = JSON::PP->new->utf8->encode({ chunks => ['Acknowledged transport choice.'] });
    my $t4_res = $app->modalities->send_chat(
        "Which HTTP client does NeoPerl use for outbound inference transport calls? [STREAM_ONLY:$spec4]",
        timeout => 60,
    );
    ok($t4_res->{ok}, 'Turn 4 completed with :MemAutoContext on');

    my @prompts3 = grep { ($_->{event} // '') eq 'prompt_received' } @{ _read_acp_log($log3) };
    my $sent4 = $prompts3[-1]{text} // '';
    like($sent4, qr/\A\[Memory Context Hint\]\n/, 'Turn 4 injected [Memory Context Hint] automatically');
    my ($hint4) = ($sent4 =~ /\A(\[Memory Context Hint\]\n.*?)(?:\n\n|\z)/s);
    ok(defined($hint4) && length($hint4) <= 1000,
        sprintf('Turn 4 [Memory Context Hint] <= 1000 chars (len=%d)', length($hint4 // '')));
    like($hint4 // '', qr/Mojo::UserAgent/i,
        'CLOSED LOOP VERIFIED: reconciled Mojo::UserAgent replacement decision auto-injected on next turn!');
    unlike($hint4 // '', qr/\Q$fake_secret\E/, 'Turn 4 hint contains zero leaked secret');
    unlike($turn_events[-1]{prompt} // '', qr/\[Memory Context Hint\]/,
        'Turn 4 AgyTurnComplete stripped [Memory Context Hint] from stored prompt');
    unlike($turn_events[-1]{summary} // '', qr/\[Memory Context Hint\]/,
        'Turn 4 AgyTurnComplete stripped [Memory Context Hint] from stored summary');

    note(sprintf(
        'METRICS[Subtest3/ClosedLoop-HyMemory]: load_ms=%d turn1_add=%.2fs turn2_%s=%.2fs redactions=%d hint4_len=%d',
        $mslot->{load_ms} // 0, $p1_s, $act2, $p2_s, $st3->{redactions}, length($hint4 // ''),
    ));

    $app->shutdown();
};

# ---------------------------------------------------------------------------
# Subtest 4: Tiered Code Cooperation (<leader>af Tier 1 vs Tier 2, Ctrl-I Inline,
#            <Tab> Ghost Text) with LIVE Ternary-Bonsai-2-27B
# ---------------------------------------------------------------------------
subtest '4. Tiered Code Cooperation (<leader>af Tier 1/2, Ctrl-I Inline, <Tab> Ghost) with LIVE Ternary-Bonsai-2-27B' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'worker_small GGUF/prism-llama-server not installed' unless $ROLE_READY{worker_small};

    my $ws4 = File::Spec->catdir($TMP, 'ws_coop_4');
    mkdir $ws4 or die "mkdir $ws4: $!";
    $ws4 = abs_path($ws4) || $ws4;
    my $log4 = File::Spec->catfile($TMP, 'acp_coop_4.log');
    unlink $log4 if -f $log4;

    local $ENV{COOP_ACP_LOG} = $log4;

    my $app = _track_app(NeoPerl::MT->new(
        cwd           => $ws4,
        ui            => 'tui',
        headless      => 1,
        auto_discover => 1,
        ram_budget_gb => 16.0,
        agy_bin       => $ACP_PEER,
        start_mcp     => 1,
        load_config   => 0,
    ));

    ok(_wait_until(sub { $app->editor->pump(); $app->acp->state eq 'ready' }, 10.0),
        'App C ACP connected ready');

    # 4A: Tier 1 <leader>af on mechanical Perl::Critic diagnostic -> live Ternary-Bonsai-2-27B (0 cloud tokens)
    my $t1_path = File::Spec->catfile($ws4, 'TierOne.pm');
    my $t1_src  = <<'END_T1_PM';
package TierOne;
use strict;
use warnings;

sub lookup_item {
    my ($href, $key) = @_;
    return undef unless ref($href) eq 'HASH' && exists $href->{$key};
    return $href->{$key};
}

1;
END_T1_PM
    my $buf1 = $app->editor->create_buffer(
        name     => 'TierOne.pm',
        path     => $t1_path,
        filetype => 'perl',
        text     => $t1_src,
    );
    $app->editor->switch_buffer($buf1->id);

    my $prompts_before_t1 = scalar(grep { ($_->{event} // '') eq 'prompt_received' } @{ _read_acp_log($log4) });

    my $t1_t0 = time();
    my $fix1 = $app->modalities->auto_fix_diagnostic(
        buffer     => $buf1,
        sync       => 1,
        diagnostic => {
            path     => $t1_path,
            line     => 7,
            severity => 'warn',
            policy   => 'Subroutines::ProhibitExplicitReturnUndef',
            message  => 'Explicit return of undef; use bare return instead',
        },
    );
    my $t1_s = time() - $t1_t0;

    is($fix1->{ok}, 1, '4A) Tier 1 <leader>af succeeded');
    is($fix1->{tier}, 'bonsai_local', '4A) mechanical Perl::Critic diagnostic routed to bonsai_local (0 cloud tokens)');
    my $prompts_after_t1 = scalar(grep { ($_->{event} // '') eq 'prompt_received' } @{ _read_acp_log($log4) });
    is($prompts_after_t1, $prompts_before_t1, '4A) Tier 1 sent ZERO requests to Antigravity cloud ACP');

    my $j1 = $app->offload_queue->job_status($fix1->{job_id});
    is($j1->{status}, 'staged', sprintf('4A) Bonsai Tier 1 job staged cleanly (%.2fs)', $t1_s));
    is($j1->{syntax_ok}, 1, "4A) Bonsai Tier 1 fix passed real perl -c ($j1->{syntax_output})");
    unlike($j1->{output_text} // '', qr{</?think\b|```}i, '4A) zero <think> or markdown fence leaks in Tier 1 output');
    ok(@{ $j1->{hunks} || [] } >= 1, '4A) Bonsai Tier 1 produced Myers diff hunks');
    ok(scalar(@{ $buf1->list_diff_hunks || [] }) >= 1, '4A) Myers diff hunks staged onto live TierOne.pm buffer');
    my ($wslot) = grep { $_->{role} eq 'worker_small' } @{ $app->inference->slot_status };
    is($wslot->{transport}, 'managed_server', '4A) worker_small ran on LIVE prism-llama-server');

    # 4B: Tier 2 <leader>af on complex/structural diagnostic -> escalates to agy ACP (antigravity_cloud)
    my $t2_path = File::Spec->catfile($ws4, 'TierTwo.pm');
    my $buf2 = $app->editor->create_buffer(
        name     => 'TierTwo.pm',
        path     => $t2_path,
        filetype => 'perl',
        text     => "package TierTwo;\nuse strict;\nuse warnings;\nsub complex_dispatch { return 1; }\n1;\n",
    );
    $app->editor->switch_buffer($buf2->id);

    my $fix2 = $app->modalities->auto_fix_diagnostic(
        buffer     => $buf2,
        diagnostic => {
            path     => $t2_path,
            line     => 4,
            severity => 'error',
            policy   => 'Architecture::CrossModuleStateCoupling',
            message  => 'Redesign state machine across modules to decouple circular dependency',
        },
    );
    is($fix2->{ok}, 1, '4B) Tier 2 <leader>af succeeded');
    is($fix2->{tier}, 'antigravity_cloud', '4B) complex/structural diagnostic escalated to antigravity_cloud ACP');
    my $prompts_after_t2 = scalar(grep { ($_->{event} // '') eq 'prompt_received' } @{ _read_acp_log($log4) });
    is($prompts_after_t2, $prompts_before_t1 + 1, '4B) Tier 2 sent prompt to Antigravity ACP');
    is($fix2->{result}{result}{acp_result}{readOk}, 1, '4B) ACP peer reverse-read live buffer via fs/read_text_file');

    # 4C: Ctrl-I inline command (use_local => 1) -> LIVE Ternary-Bonsai-2-27B
    my $inl_path = File::Spec->catfile($ws4, 'InlineTarget.pm');
    my $inl_src  = <<'END_INLINE_PM';
package InlineTarget;
use strict;
use warnings;

sub divide_safe {
    my ($num, $den) = @_;
    return $num / $den;
}

1;
END_INLINE_PM
    my $buf_inl = $app->editor->create_buffer(
        name     => 'InlineTarget.pm',
        path     => $inl_path,
        filetype => 'perl',
        text     => $inl_src,
    );
    $app->editor->switch_buffer($buf_inl->id);

    my $inl_t0 = time();
    my $inl_res = $app->modalities->run_inline_command(
        'Guard against division by zero by returning 0 when $den is 0 or undefined',
        buffer    => $buf_inl,
        use_local => 1,
    );
    my $inl_s = time() - $inl_t0;

    is($inl_res->{ok}, 1, sprintf('4C) Ctrl-I inline command (use_local => 1) succeeded (%.2fs)', $inl_s));
    is($inl_res->{via}, 'bonsai_inline', '4C) Ctrl-I routed via bonsai_inline');
    unlike($inl_res->{new_text} // '', qr{</?think\b|```}i, '4C) ZERO <think> or markdown fence leaks in Ctrl-I output');
    my ($inl_syn_ok, $inl_syn_err) = _check_perl_syntax($inl_res->{new_text} // '');
    is($inl_syn_ok, 1, "4C) Ctrl-I output compiles cleanly under perl -c ($inl_syn_err)");
    ok(($inl_res->{hunk_count} // 0) >= 1, "4C) Ctrl-I staged $inl_res->{hunk_count} Myers diff hunk(s)");
    ok(scalar(@{ $buf_inl->list_diff_hunks || [] }) >= 1, '4C) InlineTarget.pm buffer carries staged diff hunks');

    # 4D: <Tab> Ghost Text on non-trivial Perl line -> LIVE Ternary-Bonsai-2-27B
    my $ghost_path = File::Spec->catfile($ws4, 'GhostTarget.pm');
    my $ghost_src  = join("\n",
        'package GhostTarget;',
        'use strict;',
        'use warnings;',
        'sub sum_pair {',
        '    my ($x, $y) = @_;',
        '    my $total = $x + ',
        '}',
        '1;',
        '',
    );
    my $buf_ghost = $app->editor->create_buffer(
        name     => 'GhostTarget.pm',
        path     => $ghost_path,
        filetype => 'perl',
        text     => $ghost_src,
    );
    $app->editor->switch_buffer($buf_ghost->id);

    my $req_before_ghost = (grep { $_->{role} eq 'worker_small' } @{ $app->inference->slot_status })[0]{request_count};
    my $gh_line = 5;    # 0-based NeoPerl::Buffer line: '    my $total = $x + '
    my $gh_col  = length('    my $total = $x + ');
    my $gh_t0   = time();
    my $sugg    = $app->modalities->request_ghost_text($buf_ghost, $gh_line, $gh_col);
    my $gh_s    = time() - $gh_t0;
    my $req_after_ghost = (grep { $_->{role} eq 'worker_small' } @{ $app->inference->slot_status })[0]{request_count};

    is($req_after_ghost, $req_before_ghost + 1, '4D) <Tab> ghost text genuinely invoked LIVE Ternary-Bonsai-2-27B');
    ok(defined($sugg) && length($sugg) > 0, sprintf('4D) <Tab> ghost text returned suggestion "%s" (%.2fs)', $sugg // '', $gh_s));
    unlike($sugg // '', qr{</?think\b|```|`|\n}i, '4D) ghost text is single-line with ZERO <think>/fence/backtick leaks');

    my $accepted = $app->modalities->accept_ghost_text($buf_ghost);
    is($accepted, $sugg, '4D) accept_ghost_text returned accepted suggestion');
    my $line_after = $buf_ghost->get_line($gh_line);
    like($line_after, qr/my \$total = \$x \+ \Q$sugg\E/, "4D) accept_ghost_text inserted cleanly: '$line_after'");
    is($app->modalities->ghost_state->{active}, 0, '4D) ghost state cleared after accept');

    note(sprintf(
        'METRICS[Subtest4/Tiered-Bonsai]: load_ms=%d tier1=%.2fs (%.2f tok/s) inline=%.2fs ghost=%.2fs sugg=%s',
        $wslot->{load_ms} // 0, $t1_s, $j1->{tok_per_s} // 0, $inl_s, $gh_s, $sugg // '',
    ));

    $app->shutdown();
};

# ---------------------------------------------------------------------------
# Subtest 5: Built-in --agy-mock Loopback [mcp:...] Live HTTP Round-Trip +
#            Clean Shutdown (0 Stray Processes) — runs on all hosts including CI
# ---------------------------------------------------------------------------
subtest '5. Built-in --agy-mock Loopback [mcp:...] Live HTTP Round-Trip + Clean Shutdown (0 Stray Processes)' => sub {
    my $ws5 = File::Spec->catdir($TMP, 'ws_coop_5');
    mkdir $ws5 or die "mkdir $ws5: $!";
    $ws5 = abs_path($ws5) || $ws5;

    my $app = _track_app(NeoPerl::MT->new(
        cwd            => $ws5,
        ui             => 'tui',
        headless       => 1,
        agy_mock       => 1,
        inference_mock => 1,
        start_mcp      => 1,
        load_config    => 0,
    ));

    is($app->acp->state, 'ready', 'agy_mock ACP ready');
    is($app->acp->is_mock, 1, 'ACP running built-in loopback server over real OS pipes');
    ok($app->editor_mcp->is_running && $app->editor_mcp->port > 0,
        "EditorMCP listening on 127.0.0.1:" . ($app->editor_mcp->port // 0) . " (" . $app->editor_mcp->engine . ")");

    my $buf_path = File::Spec->catfile($ws5, 'LoopbackDemo.pm');
    my $buf = $app->editor->create_buffer(
        name     => 'LoopbackDemo.pm',
        path     => $buf_path,
        filetype => 'perl',
        text     => "package LoopbackDemo;\nuse strict;\nuse warnings;\nsub ping { return 'pong'; }\n1;\n",
    );
    $app->editor->switch_buffer($buf->id);

    if ($app->memory_store) {
        $app->memory_store->add_memory({
            scope_level => 'repo',
            repo_key    => $app->modalities->{repo_key},
            category    => 'architecture',
            content     => 'IBM Db2 12.1.2 VECTOR column backs semantic search.',
            tags        => 'db2,vector',
        });
    }

    my $acp_pid = $app->acp->{pid};
    ok(defined($acp_pid) && $acp_pid > 0 && kill(0, $acp_pid), "loopback ACP OS child alive (pid=$acp_pid)");

    my $t0 = time();
    my $res = $app->modalities->send_chat(
        'Check state [mcp:neoperl_get_editor_state] and memory [mcp:neoperl_memory_search:{"query":"db2"}]',
        timeout => 30,
    );
    my $dt_ms = int((time() - $t0) * 1000);

    ok($res->{ok}, "loopback [mcp:...] bidirectional OS-pipe + HTTP round-trip succeeded (${dt_ms}ms)");
    my $mres = $res->{acp_result}{mcpResults};
    is(ref($mres), 'ARRAY', 'acp_result contains mcpResults array');
    is(scalar(@{ $mres || [] }), 2, 'loopback executed both [mcp:...] HTTP tool calls');

    is($mres->[0]{tool}, 'neoperl_get_editor_state', 'call #1 invoked neoperl_get_editor_state');
    is($mres->[0]{ok}, 1, 'call #1 HTTP tools/call returned ok=1');
    is($mres->[0]{result}{active_path}, $buf_path, 'call #1 returned live active buffer path');
    is($mres->[0]{result}{active_filetype}, 'perl', 'call #1 returned active filetype perl');

    is($mres->[1]{tool}, 'neoperl_memory_search', 'call #2 invoked neoperl_memory_search');
    if ($app->memory_store) {
        is($mres->[1]{ok}, 1, 'call #2 neoperl_memory_search returned ok=1');
        ok(($mres->[1]{result}{count} // 0) >= 1, 'call #2 found seeded db2 memory over live HTTP');
        like($mres->[1]{result}{results}[0]{content} // '', qr/Db2/i, 'call #2 returned matching Db2 content');
    }
    else {
        ok(defined $mres->[1]{result}, 'call #2 returned structured response without SQLite');
    }

    ok($app->editor_mcp->request_count >= 2, 'EditorMCP served >= 2 live HTTP requests from loopback ACP child');
    my $cards = $app->modalities->chat_state->{tool_cards};
    my @done_cards = grep { ($_->{status} // '') eq 'completed' } @$cards;
    ok(@done_cards >= 2, 'Modalities recorded completed tool_cards for both loopback MCP calls');

    # Clean shutdown verification: ACP + EditorMCP + all inference slots -> 0 stray processes
    $app->shutdown();
    is($app->acp->is_running, 0, 'ACP stopped cleanly on shutdown()');
    is($app->editor_mcp->is_running, 0, 'EditorMCP stopped cleanly on shutdown()');
    ok(!kill(0, $acp_pid), "loopback ACP OS child pid=$acp_pid terminated & reaped");

    my @stray_slots = grep { $_->{loaded} || (defined $_->{pid} && kill(0, $_->{pid})) }
        @{ $app->inference->slot_status };
    is(scalar(@stray_slots), 0, '0 loaded inference slots or live server PIDs remain after shutdown()');
};

# ---------------------------------------------------------------------------
# Subtest 6: Real Signed-In `agy` CLI + ALL 4 Real Local Metal Models E2E
#            Unified NeoPerl::MT session (ram_budget_gb => 14.0, external cwd)
# ---------------------------------------------------------------------------
subtest '6. Real Signed-In agy CLI + ALL 4 Real Local Metal Models End-to-End' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'DBI + DBD::SQLite required' unless $HAS_SQLITE;
    plan skip_all => 'All 4 live local GGUF models + binaries required' unless $DOCTOR->{all_ready};

    local $ENV{NEOPERL_AGY_BIN} = undef;
    my $real_agy = NeoPerl::Antigravity::ACP::discover_agy_binary();
    plan skip_all => 'Real agy CLI binary not installed on this host (skip cleanly)'
        unless defined $real_agy && -x $real_agy;

    # External workspace directory completely outside the repository tree
    my $ws6 = tempdir(CLEANUP => 1);
    $ws6 = abs_path($ws6) || $ws6;

    # Spy on Mojolicious EditorMCP JSON-RPC dispatch to verify real agy negotiation & tool calls
    my @mcp_log;
    my $orig_handle_rpc = \&NeoPerl::Antigravity::EditorMCP::handle_jsonrpc;
    no warnings 'redefine';
    local *NeoPerl::Antigravity::EditorMCP::handle_jsonrpc = sub {
        my ($self_m, $req) = @_;
        my $method = ref($req) eq 'HASH' ? ($req->{method} // '<undef>') : '<nonhash>';
        my $tool   = (ref($req) eq 'HASH' && ref($req->{params}) eq 'HASH') ? ($req->{params}{name} // '') : '';
        my $resp   = $orig_handle_rpc->($self_m, $req);
        my $http_status = !defined($resp) ? 202
                        : (ref($resp) eq 'HASH' && exists $resp->{error}) ? 'ERR'
                        : 200;
        my $is_err = (ref($resp) eq 'HASH' && ref($resp->{result}) eq 'HASH' && $resp->{result}{isError}) ? 1 : 0;
        push @mcp_log, {
            method   => $method,
            tool     => $tool,
            status   => $http_status,
            is_error => $is_err,
        };
        return $resp;
    };

    my $t_boot = time();
    my $app = _track_app(NeoPerl::MT->new(
        cwd           => $ws6,
        ui            => 'tui',
        headless      => 1,
        cols          => 132,
        rows          => 40,
        auto_discover => 1,
        ram_budget_gb => 14.0,
        start_mcp     => 1,
        load_config   => 0,
    ));
    $app->acp->{auto_approve} = 1;

    _wait_until(sub { $app->editor->pump(); $app->acp->state ne 'connecting' }, 20.0);
    if ($app->acp->state ne 'ready') {
        my $st = $app->acp->state;
        $app->shutdown();
        plan skip_all => "Real agy CLI ($real_agy) not signed in / ready (state=$st)";
    }
    my $boot_ms = int((time() - $t_boot) * 1000);

    # Allow any asynchronous post-session/new MCP negotiation packets to finish
    _wait_until(sub {
        $app->editor->pump();
        return scalar(grep { $_->{method} eq 'tools/list' } @mcp_log) > 0;
    }, 5.0);

    # 6A. Verify real agy auto-discovery, AGY:LIVE ready state, external-cwd Memory::Store, and EditorMCP negotiation
    is($app->acp->is_mock, 0, 'real agy CLI running in live non-mock mode');
    is($app->acp->agy_bin, $real_agy, "auto-discovered real agy CLI ($real_agy)");
    is($app->acp->state, 'ready', "real agy connected state=ready (boot=${boot_ms}ms)");
    is($app->modalities->acp_status_pill->{label}, 'AGY:LIVE', 'status pill reports AGY:LIVE');

    ok($app->memory_store, 'Memory::Store initialized cleanly from blib/lib with external cwd');
    ok(!defined($app->{_memory_store_error}), 'zero _memory_store_error on external cwd');
    ok($app->memory_writer, 'Memory::Writer initialized cleanly');

    ok($app->editor_mcp->is_running && $app->editor_mcp->port > 0,
        'EditorMCP running on port ' . ($app->editor_mcp->port // 0));
    if (NeoPerl::Antigravity::EditorMCP::has_mojo()) {
        is($app->editor_mcp->engine, 'Mojolicious', 'EditorMCP running live Mojolicious daemon');
    }

    my @tlist_hits = grep { $_->{method} eq 'tools/list' && $_->{status} eq '200' } @mcp_log;
    ok(@tlist_hits >= 1, 'real agy negotiated EditorMCP tools/list -> 200');
    my @notif_hits = grep { $_->{method} =~ m{^notifications/} && $_->{status} eq '202' } @mcp_log;
    ok(@notif_hits >= 1, 'real agy notifications/* handled cleanly -> HTTP 202 (' . scalar(@notif_hits) . ' notification(s))');
    my @disc_hits  = grep { $_->{method} eq 'server/discover' && $_->{status} eq '200' } @mcp_log;
    my @init_hits  = grep { $_->{method} eq 'initialize'      && $_->{status} eq '200' } @mcp_log;
    ok(@disc_hits >= 1 || @init_hits >= 1,
        sprintf('real agy negotiated server/discover (%d) / initialize (%d) -> 200', scalar(@disc_hits), scalar(@init_hits)));

    # Switch to gemini-3.8-flash when listed in available_models (otherwise keep active model)
    my @avail_ids = map { $_->{modelId} // $_->{id} // '' } @{ $app->acp->available_models || [] };
    if (grep { $_ eq 'gemini-3.8-flash' } @avail_ids) {
        my $sw_ok = eval { $app->acp->set_model('gemini-3.8-flash'); 1 };
        ok($sw_ok, 'switched live agy session to gemini-3.8-flash') or diag("set_model error: $@");
        is($app->acp->current_model, 'gemini-3.8-flash', 'current_model confirmed as gemini-3.8-flash');
    }
    else {
        ok(defined($app->acp->current_model) && length($app->acp->current_model),
            'using active agy model: ' . ($app->acp->current_model // '<none>'));
    }

    # 6B. Open Perl buffer (DemoMath.pm) and render 2x Retina PNG with codeword AMBER_PHOSPHOR_7742
    my $pm_path = File::Spec->catfile($ws6, 'DemoMath.pm');
    my $pm_src  = <<'END_DEMO_MATH';
package DemoMath;
use strict;
use warnings;

sub compute_sum {
    my ($a, $b) = @_;
    return $a + $b;
}

sub compute_product {
    my ($a, $b) = @_;
    return $a * $b;
}

1;
END_DEMO_MATH
    open my $pm_fh, '>:encoding(UTF-8)', $pm_path or die "write $pm_path: $!";
    print {$pm_fh} $pm_src;
    close $pm_fh;

    my $demo_buf = $app->editor->create_buffer(
        name     => 'DemoMath.pm',
        path     => $pm_path,
        filetype => 'perl',
        text     => $pm_src,
    );
    $app->editor->switch_buffer($demo_buf->id);

    my $codeword = 'AMBER_PHOSPHOR_7742';
    my $png_path = File::Spec->catfile($ws6, 'live_agy_codeword.png');
    my $renderer = _render_readable_png($png_path, [
        { text => 'NEOPERL VERIFICATION BADGE', font => ['Helvetica', 24], y => 36  },
        { text => "CODEWORD: $codeword",        font => ['Courier',   24], y => 108 },
        { text => 'Status: LIVE METAL GPU OK',  font => ['Helvetica', 20], y => 176 },
    ]);
    ok(-f $png_path && (-s $png_path) > 500,
        "rendered 2x Retina PNG via $renderer (" . (-s $png_path) . " bytes)");

    my $agy_pid = $app->acp->{pid};
    ok(defined($agy_pid) && $agy_pid > 0 && kill(0, $agy_pid), "real agy OS child alive (pid=$agy_pid)");

    # Track every local server PID observed during the live turn
    my %seen_server_pids;
    my $record_slot_pids = sub {
        for my $sl (@{ $app->inference->slot_status || [] }) {
            $seen_server_pids{ $sl->{pid} } = $sl->{role}
                if defined $sl->{pid} && $sl->{pid} > 0;
        }
    };

    # 6C. Send live prompt instructing real agy to invoke ALL 4 local-inference MCP tools directly (no shell)
    my $repo_key = $app->modalities->{repo_key};
    my $live_prompt = join("\n",
        'You are connected to NeoPerl::MT via the neoperl-editor MCP server.',
        'Do NOT run any shell or terminal commands. Call ONLY the neoperl-editor MCP tools directly in this exact order:',
        "1. Call neoperl_memory_write with content=\"DemoMath uses IEEE 754 scalar arithmetic verified under live Metal cooperation\", scope_level=\"repo\", repo_key=\"$repo_key\", category=\"architecture\", tags=\"demomath,metal\".",
        "2. Call neoperl_memory_search with query=\"DemoMath IEEE 754 scalar arithmetic\", repo=\"$repo_key\", limit=5.",
        "3. Call neoperl_preprocess_doc with path=\"$png_path\" and format=\"markdown\" to read the badge image.",
        "4. Call neoperl_delegate_local with kind=\"doc\", target_path=\"$pm_path\", wait=true, timeout=180 to generate Perl POD documentation for DemoMath.pm.",
        'After all 4 MCP tool calls finish, reply concisely including the exact verbatim CODEWORD string read from the image.',
    );

    my $t_turn = time();
    my $res    = $app->modalities->send_chat($live_prompt, timeout => 300);
    my $turn_s = time() - $t_turn;
    $record_slot_pids->();

    ok($res->{ok}, sprintf('real signed-in agy live 4-model cooperation turn succeeded (%.2fs)', $turn_s));

    # Extract full assistant reply text
    my @asst_msgs = grep { ($_->{role} // '') eq 'assistant' } @{ $res->{chat_state}{messages} || [] };
    my $reply_txt = join("\n", map { $_->{text} // '' } @asst_msgs);
    if (!length($reply_txt) && ref($res->{acp_result}) eq 'HASH' && defined $res->{acp_result}{finalText}) {
        $reply_txt = $res->{acp_result}{finalText};
    }

    # Verify all 4 MCP tools were genuinely invoked over live Mojolicious HTTP
    for my $req_tool (qw(neoperl_memory_write neoperl_memory_search neoperl_preprocess_doc neoperl_delegate_local)) {
        my @calls = grep {
            $_->{method} eq 'tools/call' && $_->{tool} eq $req_tool && $_->{status} eq '200' && !$_->{is_error}
        } @mcp_log;
        ok(@calls >= 1, "real agy called EditorMCP tool '$req_tool' -> HTTP 200 ok");
    }

    # Verify all 4 local Metal inference slots genuinely handled real requests
    my %slots_mid = map { $_->{role} => $_ } @{ $app->inference->slot_status };
    for my $role (qw(embedder memory_writer vision_doc worker_small)) {
        ok(($slots_mid{$role}{request_count} // 0) >= 1,
            sprintf('slot %-13s handled real live request(s) (count=%d, transport=%s, load_ms=%d, tok/s=%.2f)',
                $role,
                $slots_mid{$role}{request_count} // 0,
                $slots_mid{$role}{transport}     // '?',
                $slots_mid{$role}{load_ms}       // 0,
                $slots_mid{$role}{last_tok_per_s} // 0));
    }
    is($slots_mid{embedder}{transport}, ($HAS_LIBLLAMA ? 'inproc_libllama' : 'managed_server'),
        'embedder ran via live inproc_libllama');
    is($slots_mid{embedder}{loaded}, 1, 'pinned embedder stayed resident throughout turn');
    is($slots_mid{embedder}{evict_count}, 0, 'pinned embedder was NEVER evicted');
    is($slots_mid{memory_writer}{transport}, 'managed_server', 'memory_writer ran via live Hy-Memory-30B-A3B managed_server');
    is($slots_mid{vision_doc}{transport},    'managed_server', 'vision_doc ran via live Granite-Vision-4.1-4B managed_server');
    is($slots_mid{worker_small}{transport},  'managed_server', 'worker_small ran via live Ternary-Bonsai-2-27B prism-llama-server');

    # Verify verbatim codeword read via Granite-Vision-4.1-4B reached real agy's final reply
    like($reply_txt, qr/\Q$codeword\E/,
        "real agy reply contains verbatim codeword '$codeword' read via Granite-Vision-4.1-4B");

    # Verify DemoMath.pm buffer received staged Myers inline diff hunks from Ternary-Bonsai-2-27B with syntax_ok == 1
    my $demo_hunks = $demo_buf->list_diff_hunks;
    ok(ref($demo_hunks) eq 'ARRAY' && @$demo_hunks >= 1,
        'DemoMath.pm buffer received staged Myers inline diff hunks (' . scalar(@{ $demo_hunks || [] }) . ' hunk(s))');
    my ($doc_job) = grep { ($_->{kind} // '') eq 'doc' && ($_->{target_path} // '') eq $pm_path }
        @{ $app->offload_queue->list_jobs || [] };
    ok($doc_job, 'OffloadQueue recorded live Ternary-Bonsai doc job for DemoMath.pm');
    is($doc_job->{status}, 'staged', 'Ternary-Bonsai doc job reached status=staged');
    is($doc_job->{syntax_ok}, 1, 'Ternary-Bonsai doc output passed real perl -c (' . ($doc_job->{syntax_output} // '') . ')');

    # Verify LIVE 14.0 GB LRU eviction occurred mid-turn while real agy stayed connected
    my $ev_mid = $app->inference->eviction_log;
    ok(@$ev_mid >= 1, 'live 14.0 GB LRU eviction occurred mid-turn (' . scalar(@$ev_mid) . ' event(s))');
    my $ram_mid = $app->inference->resident_gb;
    ok($ram_mid <= 14.0, sprintf('mid-turn resident_gb (%.2f GB) strictly <= 14.0 GB budget', $ram_mid));
    is($app->acp->state, 'ready', 'real agy stayed connected (state=ready) across mid-turn LRU eviction');
    ok($app->editor_mcp->is_running, 'Mojolicious EditorMCP stayed healthy across mid-turn LRU eviction');

    # Verify pre-pump neoperl_memory_write reconciled ADD via live Hy-Memory-30B-A3B
    my $wstats_pre = $app->memory_writer->stats;
    ok(($wstats_pre->{added} // 0) >= 1,
        'neoperl_memory_write reconciled ADD via live Hy-Memory-30B-A3B (added=' . ($wstats_pre->{added} // 0) . ')');
    ok($app->memory_writer->pending >= 1,
        'AgyTurnComplete queued post-turn memory event (pending=' . $app->memory_writer->pending . ')');

    # 6D. Post-turn modalities->pump() -> live Hy-Memory-30B-A3B reconciliation
    my $t_pump = time();
    $app->modalities->pump();
    my $pump_s = time() - $t_pump;
    $record_slot_pids->();

    is($app->memory_writer->pending, 0, sprintf('post-turn AgyTurnComplete drained cleanly (%.2fs)', $pump_s));
    my $wstats_post = $app->memory_writer->stats;
    ok(($wstats_post->{events_processed} // 0) >= 2,
        'Memory::Writer processed >= 2 events including neoperl_memory_write + post-turn AgyTurnComplete (events_processed='
        . ($wstats_post->{events_processed} // 0) . ')');
    ok($app->inference->resident_gb <= 14.0,
        sprintf('post-pump resident_gb (%.2f GB) strictly <= 14.0 GB budget', $app->inference->resident_gb));

    my %slots_end = map { $_->{role} => $_ } @{ $app->inference->slot_status };
    my $ev_total  = scalar(@{ $app->inference->eviction_log || [] });
    note(sprintf(
        'METRICS[Subtest6/Real-Agy-Live-4Model]: model=%s boot=%dms turn=%.2fs pump=%.2fs embed_req=%d hymem=%.2f tok/s (req=%d) vision=%.2f tok/s (req=%d) bonsai=%.2f tok/s (req=%d, hunks=%d) evictions=%d ram_mid=%.1fGB ram_post=%.1fGB events_processed=%d',
        $app->acp->current_model // '?',
        $boot_ms, $turn_s, $pump_s,
        $slots_end{embedder}{request_count}      // 0,
        $slots_mid{memory_writer}{last_tok_per_s} // 0, $slots_end{memory_writer}{request_count} // 0,
        $slots_mid{vision_doc}{last_tok_per_s}    // 0, $slots_end{vision_doc}{request_count}    // 0,
        $slots_mid{worker_small}{last_tok_per_s}  // 0, $slots_end{worker_small}{request_count}  // 0,
        scalar(@{ $demo_hunks || [] }),
        $ev_total, $ram_mid, $app->inference->resident_gb,
        $wstats_post->{events_processed} // 0,
    ));

    # 6E. Clean shutdown: ZERO stray llama-server / prism-llama-server / agy processes
    $app->shutdown();
    is($app->acp->is_running, 0, 'real agy ACP stopped cleanly on shutdown()');
    is($app->editor_mcp->is_running, 0, 'Mojolicious EditorMCP stopped cleanly on shutdown()');
    ok(!kill(0, $agy_pid), "real agy OS PID=$agy_pid terminated & reaped");
    for my $spid (sort { $a <=> $b } keys %seen_server_pids) {
        ok(!kill(0, $spid), "local server ($seen_server_pids{$spid}) OS PID=$spid terminated & reaped");
    }
    my @stray_end = grep { $_->{loaded} || (defined $_->{pid} && kill(0, $_->{pid})) }
        @{ $app->inference->slot_status };
    is(scalar(@stray_end), 0, '0 loaded inference slots or live server PIDs remain after shutdown()');
};

# ---------------------------------------------------------------------------
# Subtest 7: Crash-Exit Safety (inproc_libllama Metal atexit + Manager::DESTROY)
#            Child loads nomic-embed-text-v1.5.Q8_0.gguf and calls die -> exit 255
#            (no SIGABRT 134 / GGML_ASSERT from ggml-metal static destructors)
# ---------------------------------------------------------------------------
subtest '7. Crash-Exit Safety: inproc_libllama Metal atexit + Manager::DESTROY (exit 255, zero SIGABRT 134)' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'inproc_libllama + embedder GGUF required' unless $HAS_LIBLLAMA && $ROLE_READY{embedder};

    my $emb_path = $PROBE_CFG->role_config('embedder')->{model_path};
    plan skip_all => 'embedder GGUF path unavailable' unless defined $emb_path && -f $emb_path;

    my @inc_args = map { "-I$_" } grep { defined $_ && !ref($_) && length $_ } @INC;

    my $run_crash_child = sub {
        my ($script_code, @extra_args) = @_;
        my ($sfh, $spath) = tempfile(DIR => $TMP, SUFFIX => '.pl', UNLINK => 1);
        print {$sfh} $script_code;
        close $sfh;

        my ($in_fh, $out_fh);
        my $err_fh = gensym();
        my $pid = open3($in_fh, $out_fh, $err_fh, $^X, @inc_args, $spath, @extra_args);
        close $in_fh if $in_fh;
        local $/;
        my $out = <$out_fh> // '';
        my $err = <$err_fh> // '';
        close $out_fh if $out_fh;
        close $err_fh;
        waitpid($pid, 0);
        my $status = $?;
        return (
            sig  => ($status & 127),
            code => ($status >> 8),
            out  => $out,
            err  => $err,
        );
    };

    # 7A: Direct LlamaBridge::load_model + embed without calling unload() -> proves c/llama_bridge.c atexit cleanup
    my %r_direct = $run_crash_child->(<<'END_DIRECT_CRASH', $emb_path);
use strict;
use warnings;
use NeoPerl::Core ();
my ($model_path) = @ARGV;
my $res = NeoPerl::Core::LlamaBridge::load_model($model_path, { n_gpu_layers => 99, n_ctx => 2048, embeddings => 1 });
die "load failed" unless ref($res) eq 'HASH' && $res->{ok};
my $eres = NeoPerl::Core::LlamaBridge::embed('direct crash exit check');
die "embed failed" unless ref($eres) eq 'HASH' && $eres->{ok} && ref($eres->{vector}) eq 'ARRAY' && @{ $eres->{vector} } == 768;
print "LOADED_DIRECT_768\n";
$! = 0;
die "intentional crash\n";
END_DIRECT_CRASH

    like($r_direct{out}, qr/LOADED_DIRECT_768/, '7A) child loaded real nomic-embed GGUF via direct LlamaBridge');
    is($r_direct{sig},  0,   '7A) direct crash child exited with signal 0 (NO SIGABRT 6 from ggml-metal)');
    is($r_direct{code}, 255, '7A) direct crash child exited cleanly with code 255 (NOT 134)');
    like($r_direct{err},   qr/intentional crash/, '7A) stderr contains intentional crash message');
    unlike($r_direct{err}, qr/GGML_ASSERT|SIGABRT|Abort trap/i, '7A) zero GGML_ASSERT/SIGABRT noise in stderr');

    # 7B: Manager inproc_libllama embed() + uncaught die without shutdown_all() -> proves Manager::DESTROY + atexit
    my %r_mgr = $run_crash_child->(<<'END_MGR_CRASH');
use strict;
use warnings;
use NeoPerl::Inference::Config;
use NeoPerl::Inference::Manager;
my $cfg = NeoPerl::Inference::Config->new(auto_discover => 1);
my $mgr = NeoPerl::Inference::Manager->new(config => $cfg);
my $vec = $mgr->embed('manager crash exit check');
die "embed failed" unless ref($vec) eq 'ARRAY' && @$vec == 768;
my ($sl) = grep { $_->{role} eq 'embedder' } @{ $mgr->slot_status };
die "not inproc" unless $sl && $sl->{transport} eq 'inproc_libllama';
print "LOADED_MGR_INPROC_768\n";
$! = 0;
die "intentional crash\n";
END_MGR_CRASH

    like($r_mgr{out}, qr/LOADED_MGR_INPROC_768/, '7B) child loaded real nomic-embed GGUF via Manager inproc_libllama');
    is($r_mgr{sig},  0,   '7B) Manager crash child exited with signal 0 (NO SIGABRT 6 from ggml-metal)');
    is($r_mgr{code}, 255, '7B) Manager crash child exited cleanly with code 255 (NOT 134)');
    like($r_mgr{err},   qr/intentional crash/, '7B) stderr contains intentional crash message');
    unlike($r_mgr{err}, qr/GGML_ASSERT|SIGABRT|Abort trap/i, '7B) zero GGML_ASSERT/SIGABRT noise in stderr');
};

done_testing();
