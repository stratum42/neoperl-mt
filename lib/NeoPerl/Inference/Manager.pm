package NeoPerl::Inference::Manager;

use strict;
use warnings;
use Carp qw(croak);
use POSIX ();
use File::Spec ();
use File::Temp qw(tempfile);
use Time::HiRes qw(time sleep);
use IO::Socket::INET ();
use NeoPerl::Inference::Config;

our $VERSION = '0.01';

my ($HAS_MOJO_UA, $HAS_MOJO_JSON, $HAS_MOJO_ACCEL);
BEGIN {
    $HAS_MOJO_UA    = eval { require Mojo::UserAgent; 1 } ? 1 : 0;
    $HAS_MOJO_JSON  = eval { require Mojo::JSON; 1 }      ? 1 : 0;
    $HAS_MOJO_ACCEL = eval { require Mojo::MT::Accel; 1 } ? 1 : 0;
    require JSON::PP   unless $HAS_MOJO_JSON;
    require HTTP::Tiny unless $HAS_MOJO_UA;
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

sub has_mojo_ua    { $HAS_MOJO_UA }
sub has_mojo_accel { $HAS_MOJO_ACCEL }

sub mojo_accel_info {
    return {
        available => $HAS_MOJO_ACCEL,
        simd_tier => ($HAS_MOJO_ACCEL && defined(&Mojo::MT::Accel::simd_tier))
            ? eval { Mojo::MT::Accel::simd_tier() } : 'none',
        reactor_backend => ($HAS_MOJO_ACCEL && defined(&Mojo::MT::Accel::reactor_backend))
            ? eval { Mojo::MT::Accel::reactor_backend() } : 'pure_perl',
    };
}

sub new {
    my ($class, %args) = @_;
    my $config = $args{config} || NeoPerl::Inference::Config->new(%args);

    my $ua;
    if ($HAS_MOJO_UA) {
        $ua = Mojo::UserAgent->new;
        $ua->inactivity_timeout($config->http_timeout);
        $ua->request_timeout($config->http_timeout);
    }
    else {
        $ua = HTTP::Tiny->new(timeout => $config->http_timeout);
    }

    my %slots;
    for my $role ($config->role_names) {
        my $rc = $config->role_config($role);
        $slots{$role} = {
            role           => $role,
            display_name   => $rc->{display_name},
            model_id       => $rc->{model_id},
            backend_fork   => $rc->{backend_fork},
            transport      => $rc->{transport},
            ram_gb         => ($rc->{transport} eq 'remote_http') ? 0.0 : ($rc->{estimated_ram_gb} + 0.0),
            pinned         => $rc->{pinned} ? 1 : 0,
            loaded         => 0,
            status         => 'idle',
            pid            => undef,
            port           => undef,
            url            => $rc->{remote_url} || '',
            stderr_log     => undef,
            load_ms        => 0,
            last_tok_per_s => 0.0,
            last_error     => '',
            inproc_handle  => undef,
            last_used      => 0,
            load_count     => 0,
            evict_count    => 0,
            request_count  => 0,
            tokens_in      => 0,
            tokens_out     => 0,
        };
    }

    my $self = bless {
        config                     => $config,
        ua                         => $ua,
        slots                      => \%slots,
        lru_tick                   => 0,
        eviction_log               => [],
        tokens_generated_local     => 0,
        estimated_cloud_tokens_saved => 0,
        custom_http_transport      => $args{http_transport},
        server_spawner             => $args{server_spawner},
    }, $class;

    return $self;
}

sub config       { $_[0]{config} }
sub ua           { $_[0]{ua} }
sub eviction_log { [ @{ $_[0]{eviction_log} } ] }

sub resident_gb {
    my ($self) = @_;
    my $total = 0.0;
    for my $s (values %{ $self->{slots} }) {
        next unless $s->{loaded};
        next if $s->{transport} eq 'remote_http';
        $total += $s->{ram_gb};
    }
    return sprintf('%.2f', $total) + 0.0;
}

sub record_cloud_tokens_saved {
    my ($self, $tokens) = @_;
    $tokens = int($tokens || 0);
    $self->{estimated_cloud_tokens_saved} += $tokens if $tokens > 0;
    return $self->{estimated_cloud_tokens_saved};
}

sub _pick_ephemeral_port {
    my $sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or croak "Unable to allocate localhost port: $!";
    my $port = $sock->sockport();
    close $sock;
    return $port;
}

sub _llama_bridge_available {
    return eval { require NeoPerl::Core; 1 }
        && defined(&NeoPerl::Core::LlamaBridge::available)
        && NeoPerl::Core::LlamaBridge::available();
}

sub ensure_loaded {
    my ($self, $role) = @_;
    my $rc   = $self->{config}->role_config($role);
    my $slot = $self->{slots}{$role};

    $self->{lru_tick}++;

    # Remote endpoints consume zero local RAM and are never evicted.
    if ($rc->{transport} eq 'remote_http') {
        $slot->{transport} = 'remote_http';
        $slot->{url}       = $rc->{remote_url};
        $slot->{ram_gb}    = 0.0;
        $slot->{loaded}    = 1;
        $slot->{status}    = 'remote';
        $slot->{last_used} = $self->{lru_tick};
        return $slot;
    }

    if ($slot->{loaded}) {
        $slot->{last_used} = $self->{lru_tick};
        return $slot;
    }

    my $needed = $rc->{estimated_ram_gb} + 0.0;
    my $budget = $self->{config}->ram_budget_gb;

    # Evict least-recently-used unpinned local loaded slots until within budget
    while (($self->resident_gb() + $needed) > ($budget + 1e-6)) {
        my @candidates = sort {
            ($a->{last_used} <=> $b->{last_used})
                || ($b->{ram_gb} <=> $a->{ram_gb})
                || ($a->{role} cmp $b->{role})
        } grep {
            $_->{loaded}
                && !$_->{pinned}
                && $_->{transport} ne 'remote_http'
                && $_->{role} ne $role
        } values %{ $self->{slots} };

        last unless @candidates;
        my $victim = $candidates[0];
        $self->evict_slot($victim->{role}, reason => "ram_budget_exceeded_for_$role");
    }

    # Activate transport
    my $t = $rc->{transport};
    if ($t eq 'inproc_libllama') {
        if (_llama_bridge_available() && defined $rc->{model_path} && -f $rc->{model_path}) {
            my $t0  = time();
            my $res = eval {
                NeoPerl::Core::LlamaBridge::load_model(
                    $rc->{model_path},
                    {
                        n_gpu_layers => $rc->{ngl} // 99,
                        n_ctx        => $rc->{ctx_size} // 2048,
                        embeddings   => ($role eq 'embedder' ? 1 : 0),
                    },
                );
            };
            my $err = $@;
            if (ref($res) eq 'HASH' && $res->{ok}) {
                $slot->{inproc_handle} = 1;
                $slot->{transport}     = 'inproc_libllama';
                $slot->{status}        = 'resident_inproc';
                $slot->{load_ms}       = int((time() - $t0) * 1000);
                $slot->{last_error}    = '';
            }
            else {
                $slot->{last_error} = (ref($res) eq 'HASH' && defined $res->{error} && length $res->{error})
                    ? $res->{error}
                    : ($err || 'inproc_libllama load_model failed');
                $slot->{transport}  = 'loopback';
                $slot->{status}     = 'loopback_fallback';
            }
        }
        else {
            $slot->{transport} = 'loopback';
            $slot->{status}    = 'loopback_fallback';
        }
    }
    elsif ($t eq 'managed_server') {
        my $port = _pick_ephemeral_port();
        my $cmd  = $self->{config}->build_server_command($role, $port);
        if (ref($self->{server_spawner}) eq 'CODE') {
            my $info = $self->{server_spawner}->($role, $cmd, $port);
            $slot->{pid}        = $info->{pid};
            $slot->{port}       = $info->{port} // $port;
            $slot->{url}        = $info->{url}  // "http://127.0.0.1:$slot->{port}";
            $slot->{load_ms}    = int($info->{load_ms} || 0);
            $slot->{stderr_log} = $info->{stderr_log};
            $slot->{transport}  = 'managed_server';
            $slot->{status}     = 'resident_server';
        }
        else {
            my ($pid, $stderr_log, $load_ms) = $self->_spawn_managed_server($role, $cmd, $port);
            $slot->{pid}        = $pid;
            $slot->{port}       = $port;
            $slot->{url}        = "http://127.0.0.1:$port";
            $slot->{stderr_log} = $stderr_log;
            $slot->{load_ms}    = $load_ms;
            $slot->{last_error} = '';
            $slot->{transport}  = 'managed_server';
            $slot->{status}     = 'resident_server';
        }
    }
    else {
        $slot->{transport} = 'loopback';
        $slot->{status}    = 'resident_loopback';
    }

    $slot->{ram_gb}    = $needed;
    $slot->{loaded}    = 1;
    $slot->{last_used} = $self->{lru_tick};
    $slot->{load_count}++;

    return $slot;
}

sub _tail_file {
    my ($path, $max_lines) = @_;
    $max_lines ||= 15;
    return '' unless defined $path && -f $path;
    open my $fh, '<', $path or return '';
    my @lines = <$fh>;
    close $fh;
    if (@lines > $max_lines) {
        @lines = @lines[ ($#lines - $max_lines + 1) .. $#lines ];
    }
    my $txt = join('', @lines);
    $txt =~ s/\s+\z//;
    return $txt;
}

sub _terminate_child {
    my ($pid) = @_;
    return unless defined $pid && $pid > 0;
    eval {
        kill('TERM', $pid);
        my $reaped = waitpid($pid, POSIX::WNOHANG());
        for (1 .. 20) {
            last if $reaped == $pid || $reaped < 0;
            sleep(0.05);
            $reaped = waitpid($pid, POSIX::WNOHANG());
        }
        if (!$reaped) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
    };
    return;
}

sub _spawn_managed_server {
    my ($self, $role, $cmd, $port) = @_;
    # Backwards-compatible 3-arg call: _spawn_managed_server($cmd, $port)
    if (ref($role) eq 'ARRAY') {
        $port = $cmd;
        $cmd  = $role;
        $role = 'server';
    }

    my $safe_role = $role // 'server';
    $safe_role =~ s/[^A-Za-z0-9_-]/_/g;

    my ($log_fh, $stderr_log) = tempfile(
        "neoperl-llama-${safe_role}-XXXX",
        TMPDIR => 1,
        SUFFIX => '.log',
        UNLINK => 0,
    );
    close $log_fh;

    my $t0  = time();
    my $pid = fork();
    if (!defined $pid) {
        unlink $stderr_log if defined $stderr_log;
        croak "fork failed spawning llama-server ($role): $!";
    }
    if ($pid == 0) {
        open STDIN,  '<', File::Spec->devnull();
        open STDOUT, '>', File::Spec->devnull();
        if (!open(STDERR, '>', $stderr_log)) {
            open STDERR, '>', File::Spec->devnull();
        }
        { no warnings 'exec'; exec { $cmd->[0] } @$cmd; }
        print STDERR "exec failed for $cmd->[0]: $!\n";
        POSIX::_exit(127);
    }

    my $timeout  = $self->{config}->startup_timeout || 120;
    my $deadline = $t0 + $timeout;
    my $ready    = 0;
    while (time() < $deadline) {
        my $w = waitpid($pid, POSIX::WNOHANG());
        if ($w == $pid || $w < 0) {
            my $status = $?;
            my $exit   = ($status >> 8);
            my $sig    = ($status & 127);
            my $tail   = _tail_file($stderr_log, 15);
            unlink $stderr_log if defined $stderr_log;
            my $msg = "Managed server '$role' ($cmd->[0]) exited prematurely during startup (exit=$exit, sig=$sig)";
            $msg .= "\n--- stderr (last 15 lines) ---\n$tail" if length $tail;
            croak $msg;
        }

        my $res = $self->_http_request('GET', "http://127.0.0.1:$port/health", undef, undef, 2);
        if ($res->{ok} && ($res->{status} // 0) == 200) {
            my $st = (ref($res->{json}) eq 'HASH' && defined $res->{json}{status})
                ? $res->{json}{status}
                : '';
            if ($st !~ /loading/i) {
                $ready = 1;
                last;
            }
        }
        # HTTP 503 ("Loading model") or transient connection-refused: keep polling
        sleep(0.15);
    }

    if (!$ready) {
        _terminate_child($pid);
        my $tail = _tail_file($stderr_log, 15);
        unlink $stderr_log if defined $stderr_log;
        my $msg = "Managed server '$role' ($cmd->[0]) timed out after ${timeout}s waiting for /health on 127.0.0.1:$port";
        $msg .= "\n--- stderr (last 15 lines) ---\n$tail" if length $tail;
        croak $msg;
    }

    my $load_ms = int((time() - $t0) * 1000);
    return wantarray ? ($pid, $stderr_log, $load_ms) : $pid;
}

sub evict_slot {
    my ($self, $role, %opts) = @_;
    my $slot = $self->{slots}{$role} or croak "Unknown role: $role";
    return 0 unless $slot->{loaded};
    return 0 if $slot->{transport} eq 'remote_http';
    return 0 if $slot->{pinned} && !$opts{force};

    if (defined $slot->{pid}) {
        _terminate_child($slot->{pid});
        $slot->{pid}  = undef;
        $slot->{port} = undef;
    }

    if (defined $slot->{stderr_log}) {
        unlink $slot->{stderr_log} if -f $slot->{stderr_log};
        $slot->{stderr_log} = undef;
    }

    if (defined $slot->{inproc_handle}) {
        eval { NeoPerl::Core::LlamaBridge::unload() };
        $slot->{inproc_handle} = undef;
    }

    $slot->{loaded} = 0;
    $slot->{status} = 'evicted';
    $slot->{evict_count}++;

    push @{ $self->{eviction_log} }, {
        role      => $role,
        ram_gb    => $slot->{ram_gb},
        reason    => $opts{reason} // 'manual',
        timestamp => time(),
    };
    return 1;
}

sub shutdown_all {
    my ($self) = @_;
    for my $role ($self->{config}->role_names) {
        $self->evict_slot($role, force => 1, reason => 'shutdown');
    }
    return 1;
}

# --- Unified HTTP Helper (Mojo::UserAgent primary, HTTP::Tiny fallback) ---

sub _http_request {
    my ($self, $method, $url, $body_hash, $headers, $timeout) = @_;
    $headers ||= {};

    if (ref($self->{custom_http_transport}) eq 'CODE') {
        return $self->{custom_http_transport}->($method, $url, $body_hash, $headers);
    }

    if ($HAS_MOJO_UA) {
        my $ua = $self->{ua};
        if (defined $timeout && $timeout > 0) {
            $ua = Mojo::UserAgent->new;
            $ua->inactivity_timeout($timeout);
            $ua->request_timeout($timeout);
            $ua->connect_timeout($timeout);
        }
        my $tx;
        if (uc($method) eq 'GET') {
            $tx = $ua->get($url => $headers);
        }
        else {
            my %hdr = ('Content-Type' => 'application/json', %$headers);
            $tx = $ua->post($url => \%hdr => _encode_json($body_hash || {}));
        }
        my $err = $tx->error;
        my $res = $tx->res;
        if (!$err && $res && $res->is_success) {
            my $data = eval { $res->json };
            return {
                ok      => 1,
                status  => $res->code,
                json    => $data,
                body    => $res->body,
                engine  => 'Mojo::UserAgent',
            };
        }
        return {
            ok     => 0,
            status => ($res && $res->code) ? $res->code : (($err && $err->{code}) ? $err->{code} : 599),
            error  => ($err && $err->{message}) ? $err->{message} : (($res && $res->message) ? $res->message : 'HTTP request failed'),
            body   => ($res ? (eval { $res->body } // '') : ''),
            engine => 'Mojo::UserAgent',
        };
    }

    # HTTP::Tiny fallback
    my $ua = (defined $timeout && $timeout > 0)
        ? HTTP::Tiny->new(timeout => $timeout)
        : $self->{ua};
    my %req_opts = (headers => { %$headers });
    if (uc($method) ne 'GET') {
        $req_opts{headers}{'Content-Type'} = 'application/json';
        $req_opts{content} = _encode_json($body_hash || {});
    }
    my $resp = $ua->request(uc($method), $url, \%req_opts);
    if ($resp->{success}) {
        my $data = eval { _decode_json($resp->{content}) };
        return {
            ok     => 1,
            status => $resp->{status},
            json   => $data,
            body   => $resp->{content},
            engine => 'HTTP::Tiny',
        };
    }
    return {
        ok     => 0,
        status => $resp->{status} || 599,
        error  => $resp->{reason} || 'HTTP request failed',
        body   => $resp->{content} // '',
        engine => 'HTTP::Tiny',
    };
}

# --- Public Inference Entrypoints ---

sub embed {
    my ($self, $text, %opts) = @_;
    my $role = $opts{role} // 'embedder';
    my $rc   = $self->{config}->role_config($role);
    my $slot = $self->ensure_loaded($role);
    $slot->{request_count}++;

    my $est_in = int((length($text // '') + 3) / 4);
    $slot->{tokens_in} += $est_in;

    if ($slot->{transport} eq 'inproc_libllama' && defined $slot->{inproc_handle}) {
        my $res = eval { NeoPerl::Core::LlamaBridge::embed($text) };
        if (ref($res) eq 'HASH' && $res->{ok} && ref($res->{vector}) eq 'ARRAY' && @{ $res->{vector} }) {
            return $res->{vector};
        }
    }

    if ($slot->{transport} eq 'managed_server' || $slot->{transport} eq 'remote_http') {
        my $base = $slot->{url};
        $base =~ s{/$}{};
        my %hdr;
        $hdr{Authorization} = "Bearer $rc->{api_key}" if defined $rc->{api_key} && length $rc->{api_key};
        my $res = $self->_http_request(
            'POST',
            "$base/v1/embeddings",
            { model => $rc->{model_id}, input => $text },
            \%hdr,
        );
        if ($res->{ok} && ref($res->{json}) eq 'HASH') {
            my $emb = $res->{json}{data}[0]{embedding} // $res->{json}{embedding};
            return $emb if ref($emb) eq 'ARRAY' && @$emb;
        }
        croak "Embedder HTTP error ($base): " . ($res->{error} // 'invalid response');
    }

    return $self->_loopback_embed($text, $rc->{dim} || 768);
}

sub complete {
    my ($self, %args) = @_;
    my $role = $args{role} // 'worker_small';
    my $rc   = $self->{config}->role_config($role);
    my $slot = $self->ensure_loaded($role);
    $slot->{request_count}++;

    my $t0 = time();

    my $messages = $args{messages} || [
        { role => 'user', content => ($args{prompt} // '') }
    ];
    my $temp = defined($args{temperature})
        ? $args{temperature}
        : ($rc->{defaults}{temperature} // 0.0);
    my $reasoning_effort = defined($args{reasoning_effort})
        ? $args{reasoning_effort}
        : $rc->{defaults}{reasoning_effort};

    if ($slot->{transport} eq 'inproc_libllama' && defined $slot->{inproc_handle}) {
        my $prompt_txt = join("\n", map { $_->{content} // '' } @$messages);
        my $res = eval {
            NeoPerl::Core::LlamaBridge::complete(
                $prompt_txt,
                { max_tokens => $args{max_tokens} || 512, temperature => $temp + 0.0 },
            );
        };
        if (ref($res) eq 'HASH' && $res->{ok} && defined $res->{text} && length $res->{text}) {
            my $out        = $res->{text};
            my $in_tok     = int((length($prompt_txt) + 3) / 4);
            my $out_tok    = int($res->{tokens} || ((length($out) + 3) / 4));
            my $elapsed_ms = int((time() - $t0) * 1000);
            my $tok_per_s  = ($elapsed_ms > 0 && $out_tok > 0)
                ? sprintf('%.2f', $out_tok / ($elapsed_ms / 1000.0)) + 0.0
                : 0.0;
            $slot->{tokens_in}      += $in_tok;
            $slot->{tokens_out}     += $out_tok;
            $slot->{last_tok_per_s}  = $tok_per_s;
            $self->{tokens_generated_local} += $out_tok;
            return {
                text              => $out,
                role              => $role,
                model_id          => $rc->{model_id},
                transport         => 'inproc_libllama',
                prompt_tokens     => $in_tok,
                completion_tokens => $out_tok,
                tok_per_s         => $tok_per_s,
                elapsed_ms        => $elapsed_ms,
            };
        }
    }

    if ($slot->{transport} eq 'managed_server' || $slot->{transport} eq 'remote_http') {
        my $base = $slot->{url};
        $base =~ s{/$}{};
        my %hdr;
        $hdr{Authorization} = "Bearer $rc->{api_key}" if defined $rc->{api_key} && length $rc->{api_key};

        my %body = (
            model       => $rc->{model_id},
            messages    => $messages,
            temperature => $temp + 0.0,
            max_tokens  => int($args{max_tokens} || 1024),
        );
        if (defined $reasoning_effort && length $reasoning_effort) {
            $body{reasoning_effort} = $reasoning_effort;
            if ($reasoning_effort eq 'no_think') {
                $body{chat_template_kwargs} = {
                    reasoning_effort => 'no_think',
                    enable_thinking  => ($HAS_MOJO_JSON ? Mojo::JSON::false() : JSON::PP::false),
                };
            }
        }

        my $res = $self->_http_request('POST', "$base/v1/chat/completions", \%body, \%hdr);
        my $elapsed_ms = int((time() - $t0) * 1000);
        if ($res->{ok} && ref($res->{json}) eq 'HASH') {
            my $choice = (ref($res->{json}{choices}) eq 'ARRAY' && ref($res->{json}{choices}[0]) eq 'HASH')
                ? $res->{json}{choices}[0]
                : {};
            my $msg = ref($choice->{message}) eq 'HASH' ? $choice->{message} : {};
            my $text = $msg->{content};
            if (!defined($text) || $text !~ /\S/) {
                if (defined $msg->{reasoning_content} && $msg->{reasoning_content} =~ /\S/) {
                    $text = $msg->{reasoning_content};
                }
            }
            $text //= '';

            my $usage   = ref($res->{json}{usage})   eq 'HASH' ? $res->{json}{usage}   : {};
            my $timings = ref($res->{json}{timings}) eq 'HASH' ? $res->{json}{timings} : {};

            my $in_tok  = int($usage->{prompt_tokens}     || $timings->{prompt_n}    || 0);
            my $out_tok = int($usage->{completion_tokens} || $timings->{predicted_n} || ((length($text) + 3) / 4));

            my $tok_per_s = (defined $timings->{predicted_per_second} && $timings->{predicted_per_second} > 0)
                ? sprintf('%.2f', $timings->{predicted_per_second}) + 0.0
                : (($elapsed_ms > 0 && $out_tok > 0)
                    ? sprintf('%.2f', $out_tok / ($elapsed_ms / 1000.0)) + 0.0
                    : 0.0);
            my $prompt_tok_per_s = (defined $timings->{prompt_per_second} && $timings->{prompt_per_second} > 0)
                ? sprintf('%.2f', $timings->{prompt_per_second}) + 0.0
                : undef;

            $slot->{tokens_in}      += $in_tok;
            $slot->{tokens_out}     += $out_tok;
            $slot->{last_tok_per_s}  = $tok_per_s;
            $self->{tokens_generated_local} += $out_tok;
            return {
                text              => $text,
                role              => $role,
                model_id          => $rc->{model_id},
                transport         => $slot->{transport},
                http_engine       => $res->{engine},
                prompt_tokens     => $in_tok,
                completion_tokens => $out_tok,
                tok_per_s         => $tok_per_s,
                (defined $prompt_tok_per_s ? (prompt_tok_per_s => $prompt_tok_per_s) : ()),
                elapsed_ms        => $elapsed_ms,
                (keys %$timings ? (timings => $timings) : ()),
            };
        }
        my $body_hint = (defined $res->{body} && length $res->{body})
            ? ' [' . substr($res->{body}, 0, 240) . ']'
            : '';
        croak "Inference HTTP error ($role at $base, status=" . ($res->{status} // 0) . "): "
            . ($res->{error} // 'invalid response') . $body_hint;
    }

    # Deterministic offline loopback implementation per specialist role
    my $result = $self->_loopback_complete($role, \%args, $messages);
    $result->{elapsed_ms} = int((time() - $t0) * 1000);
    $slot->{tokens_in}  += $result->{prompt_tokens};
    $slot->{tokens_out} += $result->{completion_tokens};
    $self->{tokens_generated_local} += $result->{completion_tokens};
    return $result;
}

# --- Deterministic Offline Loopback Specialist Providers ---

my %SEMANTIC_GROUPS = (
    db2        => [qw(db2 ibm odbc sql database table vector cosine query pool)],
    database   => [qw(db2 ibm odbc sql database table vector cosine query pool)],
    vector     => [qw(vector embedding cosine similarity distance simd neon avx2 vsx)],
    memory     => [qw(memory memories remember recall supersede lineage scope)],
    perl       => [qw(perl ppi critic tidy module sub package xs)],
    xs         => [qw(xs c11 buffer piece table memory leak valgrind cachegrind)],
    power      => [qw(power power8 ppc64le vsx altivec smt page 64k)],
    bonsai     => [qw(bonsai ternary offload job queue prism diff hunk)],
    vision     => [qw(vision granite image screenshot pdf ocr markdown table chart)],
    antigravity => [qw(antigravity agy acp mcp tool chat inline ghost)],
);

sub _loopback_embed {
    my ($self, $text, $dim) = @_;
    $dim ||= 768;
    my @v = (0.0) x $dim;

    my $lc = lc($text // '');
    my @tokens = ($lc =~ /[a-z0-9_]{2,}/g);

    # Expand domain concept weights so semantically related queries cluster strongly
    my @weighted;
    for my $tok (@tokens) {
        push @weighted, [ $tok, 1.0 ];
        if (length($tok) >= 5 && $tok =~ /s$/) {
            (my $stem = $tok) =~ s/s$//;
            push @weighted, [ $stem, 0.7 ];
        }
        for my $grp (keys %SEMANTIC_GROUPS) {
            if (grep { $_ eq $tok } @{ $SEMANTIC_GROUPS{$grp} }) {
                push @weighted, [ "concept:$grp", 0.55 ];
            }
        }
    }

    for my $item (@weighted) {
        my ($tok, $w) = @$item;
        my $h = 2166136261;
        for my $b (unpack('C*', $tok)) {
            $h = (($h ^ $b) * 16777619) & 0xFFFFFFFF;
        }
        my $idx  = $h % $dim;
        my $sign = (($h >> 15) & 1) ? 1.0 : -1.0;
        $v[$idx] += $sign * $w;

        # Second hash projection for lower collision variance
        my $h2 = (($h >> 16) ^ ($h * 2654435761)) & 0xFFFFFFFF;
        $v[ $h2 % $dim ] += ((($h2 >> 7) & 1) ? 0.5 : -0.5) * $w;

        # Character 3-grams for lexical fuzziness
        if (index($tok, 'concept:') != 0 && length($tok) >= 4) {
            for my $i (0 .. length($tok) - 3) {
                my $tri = substr($tok, $i, 3);
                my $th = 5381;
                for my $b (unpack('C*', $tri)) {
                    $th = (($th * 33) ^ $b) & 0xFFFFFFFF;
                }
                $v[ $th % $dim ] += ((($th >> 11) & 1) ? 0.25 : -0.25) * $w;
            }
        }
    }

    my $norm = 0.0;
    $norm += $_ * $_ for @v;
    if ($norm > 0.0) {
        my $inv = 1.0 / sqrt($norm);
        $_ *= $inv for @v;
    }
    return \@v;
}

sub _loopback_complete {
    my ($self, $role, $args, $messages) = @_;
    my $rc   = $self->{config}->role_config($role);
    my $meta = $args->{metadata} || {};
    my $user_text = '';
    for my $m (@$messages) {
        if (($m->{role} // '') eq 'user') {
            $user_text = ref($m->{content}) eq 'ARRAY'
                ? join("\n", map { ref($_) eq 'HASH' ? ($_->{text} // '') : "$_" } @{ $m->{content} })
                : ($m->{content} // '');
        }
    }

    my $out_text = '';
    if ($role eq 'memory_writer') {
        $out_text = $self->_loopback_hymemory($meta, $user_text);
    }
    elsif ($role eq 'vision_doc') {
        $out_text = $self->_loopback_vision($meta, $user_text);
    }
    elsif ($role eq 'worker_small') {
        $out_text = $self->_loopback_bonsai($meta, $user_text);
    }
    else {
        $out_text = "OK";
    }

    my $in_tok  = int((length($user_text) + 3) / 4) || 16;
    my $out_tok = int((length($out_text) + 3) / 4) || 16;

    return {
        text              => $out_text,
        role              => $role,
        model_id          => $rc->{model_id},
        transport         => 'loopback',
        prompt_tokens     => $in_tok,
        completion_tokens => $out_tok,
        reasoning_effort  => $args->{reasoning_effort} // $rc->{defaults}{reasoning_effort},
    };
}

sub _loopback_hymemory {
    my ($self, $meta, $user_text) = @_;
    my $payload = (ref($meta) eq 'HASH' && defined $meta->{text})
        ? $meta
        : (eval { _decode_json($user_text) } || { text => $user_text, candidates => [] });

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
            return _encode_json([ { op => 'NOOP', target_id => $c->{id}, reason => 'exact match' } ]);
        }
    }

    if (@$cands) {
        my $best = $cands->[0];
        my $sim  = $best->{cosine_score} // 0;
        if ($text =~ /\b(?:replaced|switched\s+from|instead\s+of|migrated\s+to|now\s+uses?|superseded|deprecated|changed\s+from|moved\s+from)\b/i
            && $sim >= 0.20)
        {
            return _encode_json([
                {
                    op          => 'SUPERSEDE',
                    target_id   => $best->{id},
                    scope_level => $payload->{scope_level} // $best->{scope_level} // 'repo',
                    category    => $payload->{category}    // $best->{category}    // 'decision',
                    content     => $text,
                    confidence  => 0.93,
                }
            ]);
        }
        if ($text =~ /\b(?:also|additionally|note\s+that|update:|clarification:|extended\s+with|added\s+support)\b/i
            && $sim >= 0.25)
        {
            my $merged = $best->{content};
            $merged .= '; ' . $text unless index(lc($merged), lc($text)) >= 0;
            return _encode_json([
                {
                    op          => 'UPDATE',
                    target_id   => $best->{id},
                    scope_level => $best->{scope_level} // 'repo',
                    category    => $best->{category}    // 'fact',
                    content     => $merged,
                    confidence  => 0.91,
                }
            ]);
        }
        if ($sim >= 0.92) {
            return _encode_json([ { op => 'NOOP', target_id => $best->{id}, reason => 'semantically duplicate' } ]);
        }
    }

    return _encode_json([
        {
            op          => 'ADD',
            target_id   => undef,
            scope_level => $payload->{scope_level} // 'repo',
            category    => $payload->{category}    // 'fact',
            content     => $text,
            confidence  => 0.89,
        }
    ]);
}

sub _loopback_vision {
    my ($self, $meta, $user_text) = @_;
    my $fmt      = $meta->{format}      // 'markdown';
    my $filename = $meta->{filename}    // 'document.png';
    my $pages    = $meta->{page_count}  || 1;
    my $w        = $meta->{width}       || 0;
    my $h        = $meta->{height}      || 0;
    my $mime     = $meta->{mime_type}   // 'image/png';
    my $hint     = $meta->{text_hint}   // '';

    if ($fmt eq 'table_json') {
        return _encode_json({
            source   => $filename,
            mime     => $mime,
            pages    => $pages,
            columns  => [ 'Field', 'Value' ],
            rows     => [
                [ 'Document',   $filename ],
                [ 'Dimensions', ($w && $h) ? "${w}x${h}" : 'vector/pdf' ],
                [ 'Pages',      "$pages" ],
                (length($hint) ? [ 'Extracted', $hint ] : ()),
            ],
        });
    }
    if ($fmt eq 'chart_csv') {
        my @lines = (
            'metric,value',
            "pages,$pages",
            "width,$w",
            "height,$h",
        );
        return join("\n", @lines) . "\n";
    }
    if ($fmt eq 'ocr_code') {
        my $body = length($hint) ? $hint : "# OCR extracted from $filename ($mime, ${w}x${h})\n";
        return "```text\n$body\n```\n";
    }

    # Default structured markdown
    my @md = (
        "# Extracted Document: $filename",
        "",
        "- **Format**: `$mime`",
        ($w && $h ? "- **Resolution**: ${w}x${h} px" : ()),
        "- **Pages**: $pages",
        "",
    );
    if (length $hint) {
        push @md, "## Content", "", $hint, "";
    }
    else {
        for my $p (1 .. $pages) {
            push @md, "## Page $p", "", "Structured content extracted locally from `$filename` page $p via Granite-Vision-4.1-4B.", "";
        }
    }
    return join("\n", @md);
}

sub _loopback_bonsai {
    my ($self, $meta, $user_text) = @_;
    my $kind        = $meta->{kind}        // 'doc';
    my $source_code = $meta->{source_code} // '';
    my $target_path = $meta->{target_path} // 'module.pm';
    my $instruction = $meta->{instruction} // '';

    if ($kind eq 'commit_msg') {
        my $subject = $instruction || "Update $target_path";
        $subject =~ s/\s+/ /g;
        $subject = substr($subject, 0, 68);
        return "$subject\n\n- Refined implementation in $target_path\n- Preserved existing interface compatibility\n";
    }
    if ($kind eq 'summarize') {
        my @lines = split /\n/, $source_code;
        my @subs  = ($source_code =~ /^\s*sub\s+([A-Za-z_]\w*)/mg);
        my $sub_str = @subs ? ('Subroutines: ' . join(', ', @subs)) : 'No subroutines detected';
        return "Summary of $target_path (" . scalar(@lines) . " lines): $sub_str.\n";
    }
    if ($kind eq 'test_scaffold') {
        my ($pkg) = ($source_code =~ /^\s*package\s+([A-Za-z0-9_:]+)\s*;/m);
        $pkg ||= 'Local::Module';
        my @subs = ($source_code =~ /^\s*sub\s+([a-zA-Z][a-zA-Z0-9_]*)/mg);
        @subs = grep { $_ !~ /^_/ } @subs;
        @subs = ('new') unless @subs;
        my $checks = join("\n", map { "can_ok('$pkg', '$_');" } @subs);
        return join("\n",
            "use strict;",
            "use warnings;",
            "use Test::More;",
            "",
            "use_ok('$pkg');",
            $checks,
            "",
            "done_testing();",
            "",
        );
    }
    if ($kind eq 'comments') {
        my @out;
        for my $line (split /\n/, $source_code, -1) {
            if ($line =~ /^(\s*)sub\s+([A-Za-z_]\w*)\b/) {
                push @out, "$1# $2: handles routine logic cleanly";
            }
            push @out, $line;
        }
        return join("\n", @out);
    }
    if ($kind eq 'refactor_local') {
        my $out = $source_code;
        # Clean mechanical Perl::Critic / style fixes
        $out =~ s/\breturn\s+undef\s*;/return;/g;
        $out =~ s/\bopen\s+([A-Z_][A-Z0-9_]*)\s*,\s*"([^"]+)"/open my \$fh, '<', "$2"/g;
        if ($out eq $source_code && $source_code =~ /\S/) {
            # Add strict/warnings if missing on Perl files
            if ($target_path =~ /\.(?:pm|pl|t)$/i && $out !~ /use strict;/) {
                $out = "use strict;\nuse warnings;\n" . $out;
            }
            elsif ($out !~ /# refactored/) {
                $out =~ s/\n?\z/\n# refactored locally\n/;
            }
        }
        return $out;
    }

    # Default 'doc': append POD block before final 1; or at EOF (syntactically valid Perl)
    if ($target_path =~ /\.pm$/i || $source_code =~ /^\s*package\s+/m) {
        my ($pkg) = ($source_code =~ /^\s*package\s+([A-Za-z0-9_:]+)\s*;/m);
        $pkg ||= 'Local::Module';
        my @subs = ($source_code =~ /^\s*sub\s+([a-zA-Z][a-zA-Z0-9_]*)/mg);
        my $sub_pod = join("\n", map { "=item * C<$_>\n" } grep { $_ !~ /^_/ } @subs);
        $sub_pod ||= "=item * Module entrypoints\n";

        my $pod = join("\n",
            "",
            "__END__",
            "",
            "=head1 NAME",
            "",
            "$pkg - Module documentation",
            "",
            "=head1 FUNCTIONS",
            "",
            "=over 4",
            "",
            $sub_pod,
            "=back",
            "",
            "=cut",
            "",
        );

        if ($source_code =~ /__END__/) {
            return $source_code;
        }
        my $out = $source_code;
        $out =~ s/\s*\z/\n/;
        $out .= "1;\n" unless $out =~ /^1;\s*$/m;
        return $out . $pod;
    }

    # Generic source doc comment header
    return "/* Documentation for $target_path */\n" . $source_code;
}

# --- Live Telemetry for Command Center & Statusline ---

sub slot_status {
    my ($self) = @_;
    my @out;
    for my $role ($self->{config}->role_names) {
        my $s = $self->{slots}{$role};
        push @out, {
            role           => $s->{role},
            display_name   => $s->{display_name},
            model_id       => $s->{model_id},
            backend_fork   => $s->{backend_fork},
            transport      => $s->{transport},
            ram_gb         => $s->{ram_gb},
            pinned         => $s->{pinned},
            loaded         => $s->{loaded},
            status         => $s->{status},
            pid            => $s->{pid},
            port           => $s->{port},
            url            => $s->{url},
            load_ms        => $s->{load_ms},
            last_tok_per_s => $s->{last_tok_per_s},
            last_used      => $s->{last_used},
            load_count     => $s->{load_count},
            evict_count    => $s->{evict_count},
            request_count  => $s->{request_count},
            tokens_in      => $s->{tokens_in},
            tokens_out     => $s->{tokens_out},
        };
    }
    return \@out;
}

sub _llama_bridge_info {
    if (eval { require NeoPerl::Core; 1 } && defined(&NeoPerl::Core::LlamaBridge::status)) {
        my $st = eval { NeoPerl::Core::LlamaBridge::status() };
        return $st if ref($st) eq 'HASH';
    }
    return {
        available    => 0,
        model_loaded => 0,
        n_embd       => 0,
        library_path => '',
        model_path   => '',
    };
}

sub telemetry {
    my ($self) = @_;
    return {
        slots                        => $self->slot_status(),
        resident_gb                  => $self->resident_gb(),
        ram_budget_gb                => $self->{config}->ram_budget_gb,
        accelerator                  => $self->{config}->accelerator,
        local_ai_skipped_reason      => $self->{config}->local_ai_skipped_reason,
        tokens_generated_local       => $self->{tokens_generated_local},
        estimated_cloud_tokens_saved => $self->{estimated_cloud_tokens_saved},
        evictions                    => scalar(@{ $self->{eviction_log} }),
        http_engine                  => $HAS_MOJO_UA ? 'Mojo::UserAgent' : 'HTTP::Tiny',
        mojo_accel                   => mojo_accel_info(),
        llama_bridge                 => _llama_bridge_info(),
    };
}

sub DESTROY {
    my ($self) = @_;
    local ($@, $!, $?);
    if (!(${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT')) {
        eval { $self->shutdown_all() };
        return;
    }
    return unless ref($self) && defined $self->{slots} && ref($self->{slots}) eq 'HASH';
    my $had_inproc = 0;
    for my $slot (values %{ $self->{slots} }) {
        next unless ref($slot) eq 'HASH';
        if (defined $slot->{pid} && $slot->{pid} > 0) {
            my $pid = delete $slot->{pid};
            _terminate_child($pid);
        }
        if (defined $slot->{stderr_log} && length $slot->{stderr_log}) {
            my $log = delete $slot->{stderr_log};
            eval { unlink $log if -f $log };
        }
        if (defined $slot->{inproc_handle}) {
            $slot->{inproc_handle} = undef;
            $had_inproc = 1;
        }
        $slot->{loaded} = 0;
    }
    if ($had_inproc && defined(&NeoPerl::Core::LlamaBridge::unload)) {
        eval { NeoPerl::Core::LlamaBridge::unload() };
    }
    return;
}

1;

__END__

=head1 NAME

NeoPerl::Inference::Manager - Hybrid llama.cpp residency manager and local specialist router

=head1 SYNOPSIS

    use NeoPerl::Inference::Manager;

    my $mgr = NeoPerl::Inference::Manager->new(ram_budget_gb => 20);
    my $vec = $mgr->embed('IBM Db2 VECTOR_DISTANCE cosine similarity');
    my $res = $mgr->complete(
        role   => 'worker_small',
        prompt => 'Write POD for Foo::Bar',
    );

=head1 DESCRIPTION

C<NeoPerl::Inference::Manager> manages the four specialist inference roles
(C<embedder>, C<memory_writer>, C<vision_doc>, and C<worker_small>) across
four transports (C<inproc_libllama>, C<managed_server>, C<remote_http>, and
C<loopback>). It uses L<Mojo::UserAgent> (from C<mojolicious-mt>, with
L<HTTP::Tiny> fallback) for OpenAI-compatible HTTP calls and enforces an LRU
local RAM budget that keeps pinned slots such as C<embedder> resident and
never evicts remote endpoints.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
