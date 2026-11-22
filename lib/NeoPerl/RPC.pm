package NeoPerl::RPC;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Select;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use JSON::PP ();

our $VERSION = '0.01';

my $HAS_MOJO_JSON = eval { require Mojo::JSON; 1 } ? 1 : 0;
my $HAS_MOJO_HTTP = eval {
    require Mojolicious;
    require Mojo::Server::Daemon;
    require Mojo::IOLoop;
    1;
} ? 1 : 0;

sub has_mojo { return $HAS_MOJO_HTTP }
sub has_mojo_json { return $HAS_MOJO_JSON }

sub _json_encode {
    my ($data) = @_;
    return $HAS_MOJO_JSON
        ? Mojo::JSON::encode_json($data)
        : JSON::PP::encode_json($data);
}

sub _json_decode {
    my ($raw) = @_;
    return $HAS_MOJO_JSON
        ? Mojo::JSON::decode_json($raw)
        : JSON::PP::decode_json($raw);
}

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor    => $opts{editor},
        address   => $opts{address},
        transport => undef,     # 'unix', 'tcp', 'mojo_http', 'http_fallback'
        listener  => undef,
        daemon    => undef,
        select    => IO::Select->new,
        clients   => {},        # fileno => { sock, inbuf, outbuf, framing, is_http }
        methods   => {},
        bound     => undef,
        port      => undef,
        sock_path => undef,
        running   => 0,
    }, $class;

    $self->_register_builtin_methods;
    if (defined $opts{address} && length $opts{address}) {
        $self->listen($opts{address});
    }
    return $self;
}

sub editor    { return $_[0]->{editor} }
sub address   { return $_[0]->{bound} // $_[0]->{address} }
sub transport { return $_[0]->{transport} }
sub port      { return $_[0]->{port} }
sub is_running { return $_[0]->{running} ? 1 : 0 }

sub register_method {
    my ($self, $name, $cb) = @_;
    $self->{methods}{$name} = $cb;
    return 1;
}

sub _register_builtin_methods {
    my ($self) = @_;

    my $reg = sub {
        my ($short, $cb) = @_;
        $self->{methods}{$short} = $cb;
        $self->{methods}{"neoperl.$short"} = $cb;
    };

    $reg->('ping', sub {
        my ($ed, $params) = @_;
        return {
            ok        => 1,
            pid       => $$,
            version   => $VERSION,
            transport => $self->{transport},
            mojo_json => $HAS_MOJO_JSON,
            mojo_http => $HAS_MOJO_HTTP,
        };
    });

    $reg->('get_state', sub {
        my ($ed) = @_;
        return $ed ? $ed->get_state_snapshot : {};
    });

    $reg->('command', sub {
        my ($ed, $params) = @_;
        my $cmd = ref($params) eq 'HASH'  ? $params->{cmd}
                : ref($params) eq 'ARRAY' ? $params->[0]
                : $params;
        die "Missing command parameter\n" unless defined $cmd;
        return $ed->exec_command($cmd);
    });

    $reg->('feed_keys', sub {
        my ($ed, $params) = @_;
        my $keys = ref($params) eq 'HASH'  ? $params->{keys}
                 : ref($params) eq 'ARRAY' ? $params->[0]
                 : $params;
        die "Missing keys parameter\n" unless defined $keys;
        $ed->feed_keys($keys);
        return { ok => 1, mode => $ed->modal->mode };
    });

    $reg->('open_file', sub {
        my ($ed, $params) = @_;
        my $path = ref($params) eq 'HASH'  ? $params->{path}
                 : ref($params) eq 'ARRAY' ? $params->[0]
                 : $params;
        die "Missing path parameter\n" unless defined $path;
        my $buf = $ed->open_file($path);
        return { ok => 1, buf_id => $buf->id, path => $buf->path, lines => $buf->line_count };
    });

    $reg->('list_buffers', sub {
        my ($ed) = @_;
        return [
            map {
                {
                    id       => $_->id,
                    name     => $_->name,
                    path     => $_->path,
                    filetype => $_->filetype,
                    modified => $_->modified ? 1 : 0,
                    lines    => $_->line_count,
                }
            } $ed->list_buffers
        ];
    });

    $reg->('get_lines', sub {
        my ($ed, $params) = @_;
        $params ||= {};
        my $buf = defined($params->{buf_id})
            ? $ed->get_buffer($params->{buf_id})
            : $ed->current_buffer;
        die "Buffer not found\n" unless $buf;
        my $start = $params->{start} // 0;
        my $end   = $params->{end}   // -1;
        return {
            buf_id => $buf->id,
            lines  => $buf->get_lines($start, $end),
        };
    });

    $reg->('set_lines', sub {
        my ($ed, $params) = @_;
        $params ||= {};
        my $buf = defined($params->{buf_id})
            ? $ed->get_buffer($params->{buf_id})
            : $ed->current_buffer;
        die "Buffer not found\n" unless $buf;
        my $start = $params->{start} // 0;
        my $end   = $params->{end}   // -1;
        my $lines = $params->{lines} || [];
        $buf->set_lines($start, $end, $lines);
        $ed->emit('TextChanged', buf => $buf);
        return { ok => 1, buf_id => $buf->id, line_count => $buf->line_count };
    });

    $reg->('get_diagnostics', sub {
        my ($ed, $params) = @_;
        $params ||= {};
        my $buf = defined($params->{buf_id}) ? $ed->get_buffer($params->{buf_id}) : undef;
        return $ed->get_diagnostics($buf);
    });

    $reg->('notify', sub {
        my ($ed, $params) = @_;
        my $msg = ref($params) eq 'HASH' ? $params->{message} : $params;
        my $lvl = ref($params) eq 'HASH' ? ($params->{level} || 'info') : 'info';
        $ed->notify($msg // '', $lvl);
        return { ok => 1 };
    });
}

sub _set_nonblock {
    my ($sock) = @_;
    return unless $sock;
    if ($^O ne 'MSWin32') {
        my $flags = fcntl($sock, F_GETFL, 0);
        fcntl($sock, F_SETFL, $flags | O_NONBLOCK) if defined $flags;
    }
    else {
        $sock->blocking(0);
    }
}

sub listen {
    my ($self, $addr) = @_;
    $self->stop if $self->{running};
    $self->{address} = $addr;

    if ($addr =~ m{^https?://([^:/]+):(\d+)(/.*)?$}i) {
        my ($host, $port) = ($1, $2);
        if ($HAS_MOJO_HTTP) {
            return $self->_listen_mojo_http($addr, $host, $port);
        }
        return $self->_listen_http_fallback($host, $port);
    }
    elsif ($addr =~ m{^([^:/]+):(\d+)$}) {
        my ($host, $port) = ($1, $2);
        return $self->_listen_tcp($host, $port);
    }
    else {
        return $self->_listen_unix($addr);
    }
}

sub _listen_mojo_http {
    my ($self, $addr, $host, $port) = @_;
    my $app = Mojolicious->new;
    $app->log->level('fatal');

    my $rpc_handler = sub {
        my ($c) = @_;
        my $raw = $c->req->body;
        my $resp = $self->_handle_raw_json($raw);
        if (!defined $resp) {
            $c->render(status => 204, text => '');
            return;
        }
        $c->render(data => _json_encode($resp), format => 'json');
    };

    $app->routes->post('/')->to(cb => $rpc_handler);
    $app->routes->post('/rpc')->to(cb => $rpc_handler);
    $app->routes->get('/health')->to(cb => sub {
        my ($c) = @_;
        $c->render(data => _json_encode({ ok => 1, transport => 'mojo_http' }), format => 'json');
    });
    $app->routes->websocket('/ws')->to(cb => sub {
        my ($c) = @_;
        $c->inactivity_timeout(300);
        $c->on(message => sub {
            my ($ws, $msg) = @_;
            my $resp = $self->_handle_raw_json($msg);
            $ws->send(_json_encode($resp)) if defined $resp;
        });
    });

    my $listen_url = "http://$host:$port";
    my $daemon = Mojo::Server::Daemon->new(
        app    => $app,
        listen => [$listen_url],
        silent => 1,
    );
    $daemon->start;
    my $actual_port = $daemon->ports->[0];

    $self->{daemon}    = $daemon;
    $self->{transport} = 'mojo_http';
    $self->{port}      = $actual_port;
    $self->{bound}     = "http://$host:$actual_port";
    $self->{running}   = 1;
    $self->_attach_editor_pump;
    return $self->{bound};
}

sub _listen_http_fallback {
    my ($self, $host, $port) = @_;
    my $sock = IO::Socket::INET->new(
        LocalAddr => $host,
        LocalPort => $port,
        Proto     => 'tcp',
        Listen    => 16,
        ReuseAddr => 1,
    ) or die "NeoPerl::RPC HTTP bind failed on $host:$port: $!";
    _set_nonblock($sock);
    $self->{listener}  = $sock;
    $self->{select}->add($sock);
    $self->{transport} = 'http_fallback';
    $self->{port}      = $sock->sockport;
    $self->{bound}     = "http://$host:" . $self->{port};
    $self->{running}   = 1;
    $self->_attach_editor_pump;
    return $self->{bound};
}

sub _listen_tcp {
    my ($self, $host, $port) = @_;
    my $sock = IO::Socket::INET->new(
        LocalAddr => $host,
        LocalPort => $port,
        Proto     => 'tcp',
        Listen    => 16,
        ReuseAddr => 1,
    ) or die "NeoPerl::RPC TCP bind failed on $host:$port: $!";
    _set_nonblock($sock);
    $self->{listener}  = $sock;
    $self->{select}->add($sock);
    $self->{transport} = 'tcp';
    $self->{port}      = $sock->sockport;
    $self->{bound}     = "$host:" . $self->{port};
    $self->{running}   = 1;
    $self->_attach_editor_pump;
    return $self->{bound};
}

sub _listen_unix {
    my ($self, $path) = @_;
    unlink $path if -S $path || -e $path;
    my $sock = IO::Socket::UNIX->new(
        Type   => SOCK_STREAM,
        Local  => $path,
        Listen => 16,
    ) or die "NeoPerl::RPC Unix socket bind failed on $path: $!";
    _set_nonblock($sock);
    $self->{listener}  = $sock;
    $self->{select}->add($sock);
    $self->{transport} = 'unix';
    $self->{sock_path} = $path;
    $self->{bound}     = $path;
    $self->{running}   = 1;
    $self->_attach_editor_pump;
    return $self->{bound};
}

sub _attach_editor_pump {
    my ($self) = @_;
    if ($self->{editor}) {
        $self->{editor}->add_tick_callback('rpc_server', sub { $self->pump });
    }
}

sub dispatch_message {
    my ($self, $msg) = @_;
    if (ref($msg) eq 'ARRAY') {
        my @res;
        for my $item (@{$msg}) {
            my $r = $self->dispatch_message($item);
            push @res, $r if defined $r;
        }
        return @res ? \@res : undef;
    }
    if (ref($msg) ne 'HASH') {
        return {
            jsonrpc => '2.0',
            id      => undef,
            error   => { code => -32600, message => 'Invalid Request' },
        };
    }

    my $id     = $msg->{id};
    my $method = $msg->{method};
    my $params = $msg->{params};
    my $is_notification = !exists $msg->{id};

    if (!defined $method || ref($method)) {
        return undef if $is_notification;
        return {
            jsonrpc => '2.0',
            id      => $id,
            error   => { code => -32600, message => 'Invalid Request: missing method' },
        };
    }

    my $handler = $self->{methods}{$method};
    if (!$handler) {
        return undef if $is_notification;
        return {
            jsonrpc => '2.0',
            id      => $id,
            error   => { code => -32601, message => "Method not found: $method" },
        };
    }

    my $result;
    my $ok = eval {
        $result = $handler->($self->{editor}, $params);
        1;
    };
    if (!$ok) {
        my $err = $@ || 'Internal error';
        chomp $err;
        return undef if $is_notification;
        return {
            jsonrpc => '2.0',
            id      => $id,
            error   => { code => -32603, message => $err },
        };
    }

    return undef if $is_notification;
    return {
        jsonrpc => '2.0',
        id      => $id,
        result  => $result,
    };
}

sub _handle_raw_json {
    my ($self, $raw) = @_;
    my $msg;
    my $ok = eval {
        $msg = _json_decode($raw);
        1;
    };
    if (!$ok) {
        return {
            jsonrpc => '2.0',
            id      => undef,
            error   => { code => -32700, message => 'Parse error' },
        };
    }
    return $self->dispatch_message($msg);
}

sub pump {
    my ($self) = @_;
    return 0 unless $self->{running};

    if ($self->{transport} eq 'mojo_http' && $self->{daemon}) {
        my $r = Mojo::IOLoop->singleton->reactor;
        my $tid = $r->timer(0 => sub {});
        $r->one_tick;
        $r->remove($tid);
        return 1;
    }

    my $processed = 0;
    my @readable = $self->{select}->can_read(0);
    for my $fh (@readable) {
        if ($self->{listener} && $fh == $self->{listener}) {
            while (my $client = $self->{listener}->accept) {
                _set_nonblock($client);
                my $fno = fileno($client);
                $self->{clients}{$fno} = {
                    sock    => $client,
                    inbuf   => '',
                    outbuf  => '',
                    framing => ($self->{transport} eq 'http_fallback' ? 'http' : 'auto'),
                };
                $self->{select}->add($client);
                $processed++;
            }
            next;
        }

        my $fno = fileno($fh);
        my $cli = $self->{clients}{$fno} or next;
        my $chunk = '';
        my $n = sysread($fh, $chunk, 65536);
        if (!defined $n) {
            next if $!{EAGAIN} || $!{EWOULDBLOCK};
            $self->_drop_client($fno);
            next;
        }
        elsif ($n == 0) {
            $self->_drop_client($fno);
            next;
        }

        $cli->{inbuf} .= $chunk;
        $processed += $self->_process_client_buffer($fno, $cli);
    }

    for my $fno (keys %{ $self->{clients} }) {
        my $cli = $self->{clients}{$fno} or next;
        next unless length $cli->{outbuf};
        my $written = syswrite($cli->{sock}, $cli->{outbuf});
        if (defined $written && $written > 0) {
            substr($cli->{outbuf}, 0, $written, '');
        }
        elsif (!defined $written && !$!{EAGAIN} && !$!{EWOULDBLOCK}) {
            $self->_drop_client($fno);
            next;
        }
        if ($cli->{close_after_write} && !length $cli->{outbuf}) {
            $self->_drop_client($fno);
        }
    }

    return $processed;
}

sub _process_client_buffer {
    my ($self, $fno, $cli) = @_;
    my $count = 0;

    if ($cli->{framing} eq 'http') {
        if ($cli->{inbuf} =~ /\A(.*?\r?\n\r?\n)(.*)\z/s) {
            my ($hdr, $body) = ($1, $2);
            my $clen = 0;
            if ($hdr =~ /^Content-Length:\s*(\d+)/mi) {
                $clen = $1;
            }
            if (length($body) >= $clen) {
                my $payload = substr($body, 0, $clen);
                $cli->{inbuf} = substr($body, $clen);
                if ($hdr =~ m{\AGET\s+/health\b}i) {
                    my $j = _json_encode({ ok => 1, transport => 'http_fallback' });
                    $cli->{outbuf} .= "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                        . length($j) . "\r\nConnection: close\r\n\r\n$j";
                }
                else {
                    my $resp = $self->_handle_raw_json($payload);
                    my $j = defined($resp) ? _json_encode($resp) : '';
                    my $status = defined($resp) ? '200 OK' : '204 No Content';
                    $cli->{outbuf} .= "HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: "
                        . length($j) . "\r\nConnection: close\r\n\r\n$j";
                }
                $cli->{close_after_write} = 1;
                $count++;
            }
        }
        return $count;
    }

    while (length $cli->{inbuf}) {
        if ($cli->{inbuf} =~ /\AContent-Length:\s*(\d+)\r?\n(?:[^\r\n]+\r?\n)*\r?\n/i) {
            my $len     = $1;
            my $hdr_len = $+[0];
            last if length($cli->{inbuf}) < $hdr_len + $len;
            my $payload = substr($cli->{inbuf}, $hdr_len, $len);
            substr($cli->{inbuf}, 0, $hdr_len + $len, '');
            my $resp = $self->_handle_raw_json($payload);
            if (defined $resp) {
                my $out = _json_encode($resp);
                $cli->{outbuf} .= "Content-Length: " . length($out) . "\r\n\r\n" . $out;
            }
            $count++;
        }
        elsif ($cli->{inbuf} =~ /\A([^\n]+)\n/) {
            my $line = $1;
            substr($cli->{inbuf}, 0, length($line) + 1, '');
            $line =~ s/\r$//;
            next unless length $line;
            my $resp = $self->_handle_raw_json($line);
            if (defined $resp) {
                $cli->{outbuf} .= _json_encode($resp) . "\n";
            }
            $count++;
        }
        else {
            last;
        }
    }

    return $count;
}

sub _drop_client {
    my ($self, $fno) = @_;
    my $cli = delete $self->{clients}{$fno} or return;
    $self->{select}->remove($cli->{sock}) if $cli->{sock};
    close $cli->{sock} if $cli->{sock};
}

sub stop {
    my ($self) = @_;
    return unless $self->{running};
    $self->{running} = 0;

    if ($self->{editor}) {
        $self->{editor}->remove_tick_callback('rpc_server');
    }
    if ($self->{daemon}) {
        eval { $self->{daemon}->stop };
        $self->{daemon} = undef;
    }
    for my $fno (keys %{ $self->{clients} }) {
        $self->_drop_client($fno);
    }
    if ($self->{listener}) {
        $self->{select}->remove($self->{listener});
        close $self->{listener};
        $self->{listener} = undef;
    }
    if (defined $self->{sock_path} && -S $self->{sock_path}) {
        unlink $self->{sock_path};
        $self->{sock_path} = undef;
    }
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    $self->stop if $self->{running};
}

# --- Lightweight synchronous RPC client helper (Unix / TCP) ---

sub call_socket {
    my ($class, $addr, $method, $params, %opts) = @_;
    my $timeout = $opts{timeout} || 5;
    my $sock;
    if ($addr =~ m{^([^:/]+):(\d+)$}) {
        $sock = IO::Socket::INET->new(
            PeerAddr => $1,
            PeerPort => $2,
            Proto    => 'tcp',
            Timeout  => $timeout,
        ) or die "RPC connect failed ($addr): $!";
    }
    else {
        $sock = IO::Socket::UNIX->new(
            Type    => SOCK_STREAM,
            Peer    => $addr,
            Timeout => $timeout,
        ) or die "RPC Unix connect failed ($addr): $!";
    }
    my $req = {
        jsonrpc => '2.0',
        id      => $opts{id} // 1,
        method  => $method,
        params  => $params,
    };
    my $wire = _json_encode($req) . "\n";
    print {$sock} $wire;
    $sock->flush;

    my $line = <$sock>;
    close $sock;
    die "RPC server closed connection without reply" unless defined $line;
    return _json_decode($line);
}

1;

__END__

=head1 NAME

NeoPerl::RPC - JSON-RPC 2.0 remote control server (--listen) for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::RPC;
    my $rpc = NeoPerl::RPC->new(editor => $editor, address => '/tmp/npl.sock');
    # Or TCP: '127.0.0.1:0'
    # Or HTTP + WebSocket (via Mojolicious when installed): 'http://127.0.0.1:0'

=head1 DESCRIPTION

Implements a non-blocking JSON-RPC 2.0 server supporting Unix domain sockets,
raw TCP sockets (both NDJSON and C<Content-Length> framing), and HTTP POST +
WebSocket endpoints backed by L<Mojo::Server::Daemon> when Mojolicious is
available (with an L<IO::Socket::INET> HTTP fallback).

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
