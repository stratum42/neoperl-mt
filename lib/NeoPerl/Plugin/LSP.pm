package NeoPerl::Plugin::LSP;

use strict;
use warnings;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use IO::Select;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Temp qw(tempfile);
use File::Spec;
use Cwd qw(abs_path);
use Time::HiRes qw(time sleep);
use JSON::PP ();

our $VERSION = '0.01';

my $HAS_MOJO_JSON = eval { require Mojo::JSON; 1 } ? 1 : 0;

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

sub _set_nonblock {
    my ($fh) = @_;
    return unless $fh;
    if ($^O ne 'MSWin32') {
        my $flags = fcntl($fh, F_GETFL, 0);
        fcntl($fh, F_SETFL, $flags | O_NONBLOCK) if defined $flags;
    }
}

sub _path_to_uri {
    my ($path) = @_;
    my $abs = eval { abs_path($path) } || File::Spec->rel2abs($path);
    $abs =~ s{\\}{/}g;
    $abs =~ s{([^A-Za-z0-9\-_.~/:])}{sprintf('%%%02X', ord($1))}ge;
    return $abs =~ m{^/} ? "file://$abs" : "file:///$abs";
}

sub _uri_to_path {
    my ($uri) = @_;
    return undef unless defined $uri;
    my $p = $uri;
    $p =~ s{^file://}{}i;
    $p =~ s{%([0-9A-Fa-f]{2})}{chr(hex($1))}ge;
    return $p;
}

sub _find_executable {
    my (@candidates) = @_;
    for my $c (@candidates) {
        if ($c =~ m{/}) {
            return $c if -x $c;
        }
        else {
            for my $dir (File::Spec->path) {
                my $full = File::Spec->catfile($dir, $c);
                return $full if -x $full;
            }
        }
    }
    return undef;
}

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor                    => $opts{editor},
        configs                   => {},       # name => { filetypes => [...], cmd => [...], language_id => ... }
        clients                   => {},       # name => client hashref
        perl_jobs                 => {},       # buf_id => { pid, fh, errbuf, tmpfile, buf }
        compiler_jobs             => {},       # buf_id => { pid, fh, outbuf, tmpfile, buf, tool, source }
        compilers                 => {},       # tool => executable_path
        builtin                   => $opts{builtin},
        next_req_id               => 1,
        auto_start                => exists($opts{auto_start}) ? $opts{auto_start} : 1,
        enable_external_compilers => exists($opts{enable_external_compilers})
            ? ($opts{enable_external_compilers} ? 1 : 0) : 1,
    }, $class;

    if (!$self->{builtin}) {
        if (eval { require NeoPerl::LSP::Builtin; 1 }) {
            $self->{builtin} = eval {
                NeoPerl::LSP::Builtin->new(
                    editor   => $opts{editor},
                    registry => $opts{registry},
                );
            };
        }
    }

    # Auto-wire installed external upstream LSP servers
    my $clangd = _find_executable('/usr/bin/clangd', 'clangd');
    if ($clangd) {
        $self->register_server('clangd', {
            filetypes => [qw(c cpp xs hip sycl metal)],
            cmd       => [ $clangd, '--background-index=false', '--log=error' ],
        });
    }

    my @external_lsps = (
        [ 'che4z-hlasm',   [qw(hlasm)],  [ 'che-che4z-lsp-for-hlasm', 'hlasm-language-server' ], [] ],
        [ 'che4z-cobol',   [qw(cobol)],  [ 'che-che4z-lsp-for-cobol', 'cobol-language-server' ], [] ],
        [ 'rpgle-ls',      [qw(rpgile)], [ 'rpgle-language-server' ],                            ['--stdio'] ],
        [ 'asm-lsp',       [qw(asm)],    [ 'asm-lsp' ],                                          [] ],
        [ 'glsl_analyzer', [qw(glsl)],   [ 'glsl_analyzer' ],                                    [] ],
    );
    for my $spec (@external_lsps) {
        my ($name, $fts, $bins, $args) = @$spec;
        my $exe = _find_executable(@$bins);
        if ($exe) {
            $self->register_server($name, {
                filetypes => $fts,
                cmd       => [ $exe, @$args ],
            });
        }
    }

    # Auto-detect installed external compilers / shader validators
    my @compiler_probes = (
        [ 'cobc',             '/opt/homebrew/bin/cobc', '/usr/local/bin/cobc', 'cobc' ],
        [ 'glslangValidator', '/opt/homebrew/bin/glslangValidator', 'glslangValidator' ],
        [ 'spirv-val',        '/opt/homebrew/bin/spirv-val', 'spirv-val' ],
        [ 'ocloc',            'ocloc' ],
        [ 'hipcc',            '/opt/rocm/bin/hipcc', 'hipcc' ],
    );
    for my $cp (@compiler_probes) {
        my ($tool, @cands) = @$cp;
        my $exe = _find_executable(@cands);
        $self->{compilers}{$tool} = $exe if $exe;
    }
    if ($^O eq 'darwin') {
        my $xcrun = _find_executable('/usr/bin/xcrun', 'xcrun');
        $self->{compilers}{xcrun_metal} = $xcrun if $xcrun;
    }

    if ($opts{editor}) {
        $self->attach($opts{editor});
    }
    return $self;
}

sub builtin            { $_[0]{builtin} }
sub external_compilers { return { %{ $_[0]{compilers} } } }

sub handles_builtin {
    my ($self, $buf_or_ft) = @_;
    return 0 unless $self->{builtin} && defined $buf_or_ft;
    my $ft = ref($buf_or_ft) ? eval { $buf_or_ft->filetype } : $buf_or_ft;
    return $self->{builtin}->handles_filetype($ft);
}

sub _buf_to_doc {
    my ($self, $buf) = @_;
    return undef unless $buf;
    my $path = eval { $buf->path } // eval { $buf->name } // 'untitled';
    return {
        uri        => _path_to_uri($path),
        path       => $path,
        languageId => eval { $buf->filetype } // 'plaintext',
        filetype   => eval { $buf->filetype } // 'plaintext',
        version    => eval { $buf->lsp_version } // 1,
        text       => eval { $buf->get_text } // '',
    };
}

sub attach {
    my ($self, $editor) = @_;
    $self->{editor} = $editor;
    $editor->register_plugin('lsp', $self);

    $editor->add_tick_callback('lsp_pump', sub { $self->pump });

    $editor->on('BufReadPost', sub {
        my (%ev) = @_;
        $self->on_buffer_open($ev{buf}) if $ev{buf};
    });

    $editor->on('BufWritePost', sub {
        my (%ev) = @_;
        $self->on_buffer_save($ev{buf}) if $ev{buf};
    });

    $editor->on('TextChanged', sub {
        my (%ev) = @_;
        $self->on_buffer_change($ev{buf}) if $ev{buf};
    });

    $editor->on('TextChangedI', sub {
        my (%ev) = @_;
        $self->on_buffer_change($ev{buf}) if $ev{buf};
    });

    $editor->excmd->register_command('LspInfo', sub {
        my ($ed) = @_;
        my $info = $self->info;
        my @parts;
        for my $name (sort keys %{ $info->{clients} }) {
            my $c = $info->{clients}{$name};
            push @parts, sprintf('%s(%s, pid=%s)', $name, $c->{state}, $c->{pid} // '-');
        }
        my @comp = sort keys %{ $info->{compilers} || {} };
        my $msg = @parts
            ? 'LSP active: ' . join(', ', @parts)
            : 'LSP: built-in 12-domain + perl -c providers ready';
        $msg .= ' [compilers: ' . join(', ', @comp) . ']' if @comp;
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, data => $info };
    }, desc => 'Show active LSP client status');

    $editor->excmd->register_command('LspStart', sub {
        my ($ed, $args) = @_;
        my $buf = $ed->current_buffer;
        my $name = $args->{args};
        my $c = $name ? $self->start_server($name) : $self->ensure_server_for_buffer($buf);
        if ($c) {
            $self->did_open($c, $buf) if $buf && $buf->path;
            return { ok => 1, message => "LSP started: $c->{name}", data => $c->{name} };
        }
        if ($buf && $self->handles_builtin($buf)) {
            $self->check_builtin_diagnostics($buf);
            return { ok => 1, message => 'Built-in LSP active for ' . $buf->filetype, data => 'builtin' };
        }
        return { ok => 0, message => 'No LSP server configured for buffer' };
    }, desc => 'Start language server for current buffer');

    $editor->excmd->register_command('LspStop', sub {
        my ($ed, $args) = @_;
        my $name = $args->{args};
        if ($name) {
            $self->stop_server($name);
        }
        else {
            $self->stop_all;
        }
        return { ok => 1, message => 'LSP stopped' };
    }, desc => 'Stop language server(s)');

    # Wire K (hover), gd (definition), gr (references), and document symbols hooks cleanly
    $editor->register_hover_provider(sub {
        my ($ed, $buf, $line, $col) = @_;
        return undef unless $buf;
        if ($self->handles_builtin($buf)) {
            my $bres = $self->builtin_hover($buf, $line, $col);
            return $bres if defined $bres;
        }
        return undef unless $buf->path;
        my $client = $self->client_for_buffer($buf) or return undef;
        my $res;
        my $id = $self->hover($buf, $line, $col, sub { $res = $_[0] });
        $self->wait_for_request($client->{name}, $id, 2.0) if defined $id && !ref($id);
        return $res;
    });

    $editor->register_definition_provider(sub {
        my ($ed, $buf, $line, $col) = @_;
        return undef unless $buf;
        if ($self->handles_builtin($buf)) {
            my $bres = $self->builtin_definition($buf, $line, $col);
            return $bres if defined $bres;
        }
        return undef unless $buf->path;
        my $client = $self->client_for_buffer($buf) or return undef;
        my $res;
        my $id = $self->definition($buf, $line, $col, sub { $res = $_[0] });
        $self->wait_for_request($client->{name}, $id, 2.0) if defined $id && !ref($id);
        return $res;
    });

    $editor->register_reference_provider(sub {
        my ($ed, $buf, $line, $col) = @_;
        return undef unless $buf && $buf->path;
        my $client = $self->client_for_buffer($buf) or return undef;
        my $res;
        my $id = $self->references($buf, $line, $col, sub { $res = $_[0] });
        $self->wait_for_request($client->{name}, $id, 2.0) if defined $id && !ref($id);
        return $res;
    });

    if ($editor->can('register_symbol_provider')) {
        $editor->register_symbol_provider(sub {
            my ($ed, $buf) = @_;
            return undef unless $buf && $self->handles_builtin($buf);
            my $syms = $self->builtin_symbols($buf);
            return ($syms && @$syms) ? $syms : undef;
        });
    }

    return $self;
}

sub register_server {
    my ($self, $name, $cfg) = @_;
    $self->{configs}{$name} = {
        name      => $name,
        filetypes => $cfg->{filetypes} || [],
        cmd       => $cfg->{cmd}       || [],
    };
    return 1;
}

sub configured_servers {
    my ($self) = @_;
    return sort keys %{ $self->{configs} };
}

sub server_name_for_filetype {
    my ($self, $ft) = @_;
    return undef unless defined $ft;
    for my $name (sort keys %{ $self->{configs} }) {
        my $fts = $self->{configs}{$name}{filetypes} || [];
        for my $f (@{$fts}) {
            return $name if $f eq $ft;
        }
    }
    return undef;
}

sub client_for_buffer {
    my ($self, $buf) = @_;
    return undef unless $buf;
    my $name = $self->server_name_for_filetype($buf->filetype) or return undef;
    return $self->{clients}{$name};
}

sub ensure_server_for_buffer {
    my ($self, $buf) = @_;
    return undef unless $buf;
    my $name = $self->server_name_for_filetype($buf->filetype) or return undef;
    return $self->{clients}{$name} if $self->{clients}{$name} && $self->{clients}{$name}{state} ne 'stopped';
    return $self->start_server($name);
}

sub start_server {
    my ($self, $name, %opts) = @_;
    my $cfg = $self->{configs}{$name} or return undef;
    return $self->{clients}{$name} if $self->{clients}{$name} && $self->{clients}{$name}{state} ne 'stopped';

    my @cmd = @{ $cfg->{cmd} };
    return undef unless @cmd && -x $cmd[0];

    my ($wtr, $rdr);
    my $err = gensym;
    my $pid = eval { open3($wtr, $rdr, $err, @cmd) };
    return undef unless $pid;

    binmode($wtr);
    binmode($rdr);
    binmode($err);
    _set_nonblock($rdr);
    _set_nonblock($err);

    my $root = $opts{root} || ($self->{editor} ? $self->{editor}->cwd : '.');
    my $client = {
        name           => $name,
        cmd            => \@cmd,
        pid            => $pid,
        wtr            => $wtr,
        rdr            => $rdr,
        err            => $err,
        inbuf          => '',
        errbuf         => '',
        state          => 'initializing',
        root           => $root,
        pending        => {},      # req_id => { cb => ..., done => 0, result => ..., error => ... }
        opened_uris    => {},      # uri => version
        queued_opens   => [],
        capabilities   => {},
        diagnostics    => {},      # uri => \@diags
        last_diag_time => {},      # uri => timestamp
    };
    $self->{clients}{$name} = $client;

    my $init_id = $self->_send_request($client, 'initialize', {
        processId    => $$,
        rootUri      => _path_to_uri($root),
        rootPath     => eval { abs_path($root) } || $root,
        capabilities => {
            textDocument => {
                hover => {
                    contentFormat => [ 'markdown', 'plaintext' ],
                },
                completion => {
                    completionItem => { snippetSupport => JSON::PP::false },
                },
                publishDiagnostics => {
                    relatedInformation => JSON::PP::true,
                },
                definition => {},
                references => {},
            },
        },
        clientInfo => {
            name    => 'NeoPerl::MT',
            version => $VERSION,
        },
    }, sub {
        my ($res, $err_obj) = @_;
        if ($err_obj) {
            $client->{state} = 'error';
            return;
        }
        $client->{capabilities} = $res->{capabilities} || {};
        $client->{state}        = 'ready';
        $self->_send_notification($client, 'initialized', {});
        my @q = splice @{ $client->{queued_opens} };
        for my $buf (@q) {
            $self->did_open($client, $buf);
        }
    });
    $client->{init_req_id} = $init_id;

    return $client;
}

sub _write_rpc {
    my ($self, $client, $payload) = @_;
    return 0 unless $client && $client->{wtr};
    my $json = _json_encode($payload);
    my $frame = "Content-Length: " . length($json) . "\r\n\r\n" . $json;
    local $SIG{PIPE} = 'IGNORE';
    my $ok = eval {
        print { $client->{wtr} } $frame;
        $client->{wtr}->flush;
        1;
    };
    return $ok ? 1 : 0;
}

sub _send_request {
    my ($self, $client, $method, $params, $cb) = @_;
    my $id = $self->{next_req_id}++;
    $client->{pending}{$id} = {
        method => $method,
        cb     => $cb,
        done   => 0,
        result => undef,
        error  => undef,
    };
    $self->_write_rpc($client, {
        jsonrpc => '2.0',
        id      => $id,
        method  => $method,
        params  => $params,
    });
    return $id;
}

sub _send_notification {
    my ($self, $client, $method, $params) = @_;
    return $self->_write_rpc($client, {
        jsonrpc => '2.0',
        method  => $method,
        params  => $params,
    });
}

sub _language_id {
    my ($ft) = @_;
    return 'c'    if $ft eq 'c' || $ft eq 'xs';
    return 'cpp'  if $ft eq 'cpp' || $ft eq 'hip' || $ft eq 'sycl' || $ft eq 'metal';
    return 'perl' if $ft eq 'perl';
    return $ft || 'plaintext';
}

sub did_open {
    my ($self, $client, $buf) = @_;
    return 0 unless $client && $buf && $buf->path;
    if ($client->{state} eq 'initializing') {
        push @{ $client->{queued_opens} }, $buf;
        return 1;
    }
    return 0 unless $client->{state} eq 'ready';
    my $uri = _path_to_uri($buf->path);
    return 1 if exists $client->{opened_uris}{$uri};

    $client->{opened_uris}{$uri} = $buf->lsp_version;
    return $self->_send_notification($client, 'textDocument/didOpen', {
        textDocument => {
            uri        => $uri,
            languageId => _language_id($buf->filetype),
            version    => $buf->lsp_version,
            text       => $buf->get_text,
        },
    });
}

sub did_change {
    my ($self, $client, $buf) = @_;
    return 0 unless $client && $buf && $buf->path;
    return $self->did_open($client, $buf) if $client->{state} eq 'initializing';
    return 0 unless $client->{state} eq 'ready';
    my $uri = _path_to_uri($buf->path);
    if (!exists $client->{opened_uris}{$uri}) {
        return $self->did_open($client, $buf);
    }
    $client->{opened_uris}{$uri} = $buf->lsp_version;
    return $self->_send_notification($client, 'textDocument/didChange', {
        textDocument => {
            uri     => $uri,
            version => $buf->lsp_version,
        },
        contentChanges => [
            { text => $buf->get_text },
        ],
    });
}

sub did_save {
    my ($self, $client, $buf) = @_;
    return 0 unless $client && $client->{state} eq 'ready' && $buf && $buf->path;
    my $uri = _path_to_uri($buf->path);
    return $self->_send_notification($client, 'textDocument/didSave', {
        textDocument => { uri => $uri },
        text         => $buf->get_text,
    });
}

sub on_buffer_open {
    my ($self, $buf) = @_;
    return unless $buf;
    if ($buf->filetype eq 'perl') {
        $self->check_perl_syntax($buf);
        return;
    }
    if ($self->handles_builtin($buf)) {
        $self->check_builtin_diagnostics($buf);
        $self->check_external_compiler($buf) if $self->{enable_external_compilers};
    }
    return unless $self->{auto_start} && $buf->path;
    my $client = $self->ensure_server_for_buffer($buf);
    $self->did_open($client, $buf) if $client;
}

sub on_buffer_change {
    my ($self, $buf) = @_;
    return unless $buf;
    if ($buf->filetype eq 'perl') {
        # Triggered asynchronously when buffer changes
        $self->check_perl_syntax($buf);
        return;
    }
    if ($self->handles_builtin($buf)) {
        $self->check_builtin_diagnostics($buf);
    }
    my $client = $self->client_for_buffer($buf) or return;
    $self->did_change($client, $buf);
}

sub on_buffer_save {
    my ($self, $buf) = @_;
    return unless $buf;
    if ($buf->filetype eq 'perl') {
        $self->check_perl_syntax($buf);
        return;
    }
    if ($self->handles_builtin($buf)) {
        $self->check_builtin_diagnostics($buf);
        $self->check_external_compiler($buf) if $self->{enable_external_compilers};
    }
    my $client = $self->client_for_buffer($buf) or return;
    $self->did_save($client, $buf);
}

# --- Built-In Zero-Fork Domain LSP Operations ---

sub builtin_diagnostics {
    my ($self, $buf) = @_;
    return [] unless $buf && $self->handles_builtin($buf);
    my $doc = $self->_buf_to_doc($buf) or return [];
    return $self->{builtin}->diagnostics($doc);
}

sub check_builtin_diagnostics {
    my ($self, $buf) = @_;
    my $diags = $self->builtin_diagnostics($buf);
    if ($self->{editor} && $buf) {
        $self->{editor}->set_diagnostics($buf, 'lsp_builtin', $diags);
    }
    return $diags;
}

sub builtin_hover {
    my ($self, $buf, $line, $col) = @_;
    return undef unless $buf && $self->handles_builtin($buf);
    my $doc = $self->_buf_to_doc($buf) or return undef;
    return $self->{builtin}->hover($doc, $line, $col);
}

sub builtin_completion {
    my ($self, $buf, $line, $col) = @_;
    return [] unless $buf && $self->handles_builtin($buf);
    my $doc = $self->_buf_to_doc($buf) or return [];
    return $self->{builtin}->completion($doc, $line, $col);
}

sub builtin_definition {
    my ($self, $buf, $line, $col) = @_;
    return undef unless $buf && $self->handles_builtin($buf);
    my $doc = $self->_buf_to_doc($buf) or return undef;
    return $self->{builtin}->definition($doc, $line, $col);
}

sub builtin_symbols {
    my ($self, $buf) = @_;
    return [] unless $buf && $self->handles_builtin($buf);
    my $doc = $self->_buf_to_doc($buf) or return [];
    return $self->{builtin}->editor_symbols($doc);
}

# --- LSP Requests (Dual-Mode: Built-in Zero-Fork + External LSP) ---

sub hover {
    my ($self, $buf, $line, $col, $cb) = @_;
    if ($self->handles_builtin($buf)) {
        my $bres = $self->builtin_hover($buf, $line, $col);
        if (defined $bres) {
            $cb->($bres) if ref($cb) eq 'CODE';
            return $bres;
        }
    }
    my $client = $self->ensure_server_for_buffer($buf) or return undef;
    $self->wait_for_ready($client->{name}, 3.0) if $client->{state} eq 'initializing';
    $self->did_open($client, $buf);
    return $self->_send_request($client, 'textDocument/hover', {
        textDocument => { uri => _path_to_uri($buf->path) },
        position     => { line => int($line), character => int($col) },
    }, $cb);
}

sub definition {
    my ($self, $buf, $line, $col, $cb) = @_;
    if ($self->handles_builtin($buf)) {
        my $bres = $self->builtin_definition($buf, $line, $col);
        if (defined $bres) {
            $cb->($bres) if ref($cb) eq 'CODE';
            return $bres;
        }
    }
    my $client = $self->ensure_server_for_buffer($buf) or return undef;
    $self->wait_for_ready($client->{name}, 3.0) if $client->{state} eq 'initializing';
    $self->did_open($client, $buf);
    return $self->_send_request($client, 'textDocument/definition', {
        textDocument => { uri => _path_to_uri($buf->path) },
        position     => { line => int($line), character => int($col) },
    }, $cb);
}

sub references {
    my ($self, $buf, $line, $col, $cb) = @_;
    my $client = $self->ensure_server_for_buffer($buf) or return undef;
    $self->wait_for_ready($client->{name}, 3.0) if $client->{state} eq 'initializing';
    $self->did_open($client, $buf);
    return $self->_send_request($client, 'textDocument/references', {
        textDocument => { uri => _path_to_uri($buf->path) },
        position     => { line => int($line), character => int($col) },
        context      => { includeDeclaration => JSON::PP::true },
    }, $cb);
}

sub completion {
    my ($self, $buf, $line, $col, $cb) = @_;
    if ($self->handles_builtin($buf)) {
        my $bres = $self->builtin_completion($buf, $line, $col);
        if (ref($bres) eq 'ARRAY' && @$bres) {
            $cb->($bres) if ref($cb) eq 'CODE';
            return $bres;
        }
    }
    my $client = $self->ensure_server_for_buffer($buf) or return undef;
    $self->wait_for_ready($client->{name}, 3.0) if $client->{state} eq 'initializing';
    $self->did_open($client, $buf);
    return $self->_send_request($client, 'textDocument/completion', {
        textDocument => { uri => _path_to_uri($buf->path) },
        position     => { line => int($line), character => int($col) },
    }, $cb);
}

sub document_symbols {
    my ($self, $buf) = @_;
    return $self->builtin_symbols($buf) if $self->handles_builtin($buf);
    return [];
}

# --- Non-blocking Pump & Parsing ---

sub pump {
    my ($self) = @_;
    my $activity = 0;

    for my $name (keys %{ $self->{clients} }) {
        my $client = $self->{clients}{$name};
        next unless $client && $client->{state} ne 'stopped';
        $activity += $self->_pump_client($client);
    }

    $activity += $self->_pump_perl_jobs;
    $activity += $self->_pump_compiler_jobs;
    return $activity;
}

sub _pump_client {
    my ($self, $client) = @_;
    my $count = 0;
    my $sel = IO::Select->new;
    $sel->add($client->{rdr}) if $client->{rdr};
    $sel->add($client->{err}) if $client->{err};

    for my $fh ($sel->can_read(0)) {
        my $buf = '';
        my $n = sysread($fh, $buf, 65536);
        if (!defined $n) {
            next if $!{EAGAIN} || $!{EWOULDBLOCK};
            next;
        }
        if ($n == 0) {
            if ($fh == $client->{rdr}) {
                $client->{state} = 'stopped';
            }
            next;
        }
        if ($fh == $client->{rdr}) {
            $client->{inbuf} .= $buf;
        }
        else {
            $client->{errbuf} .= $buf;
            $client->{errbuf} = substr($client->{errbuf}, -4096)
                if length($client->{errbuf}) > 8192;
        }
    }

    while (length $client->{inbuf}) {
        if ($client->{inbuf} =~ /\AContent-Length:\s*(\d+)\r?\n(?:[^\r\n]+\r?\n)*\r?\n/i) {
            my $len     = $1;
            my $hdr_len = $+[0];
            last if length($client->{inbuf}) < $hdr_len + $len;
            my $payload = substr($client->{inbuf}, $hdr_len, $len);
            substr($client->{inbuf}, 0, $hdr_len + $len, '');
            my $msg = eval { _json_decode($payload) };
            $self->_handle_message($client, $msg) if ref($msg) eq 'HASH';
            $count++;
        }
        else {
            # Discard leading stray whitespace if any
            if ($client->{inbuf} =~ s/\A[\r\n]+//) {
                next;
            }
            last;
        }
    }

    return $count;
}

sub _handle_message {
    my ($self, $client, $msg) = @_;

    # Server -> client request (has both id and method)
    if (exists $msg->{id} && exists $msg->{method}) {
        $self->_write_rpc($client, {
            jsonrpc => '2.0',
            id      => $msg->{id},
            result  => undef,
        });
        return;
    }

    # Response to our request
    if (exists $msg->{id} && !exists $msg->{method}) {
        my $id  = $msg->{id};
        my $req = $client->{pending}{$id};
        if ($req) {
            $req->{done}   = 1;
            $req->{result} = $msg->{result};
            $req->{error}  = $msg->{error};
            if ($req->{cb}) {
                eval { $req->{cb}->($msg->{result}, $msg->{error}) };
            }
        }
        return;
    }

    # Server notification
    my $method = $msg->{method} || '';
    if ($method eq 'textDocument/publishDiagnostics') {
        $self->_handle_publish_diagnostics($client, $msg->{params} || {});
    }
}

sub _handle_publish_diagnostics {
    my ($self, $client, $params) = @_;
    my $uri = $params->{uri} or return;
    my $raw = $params->{diagnostics} || [];

    my %sev_map = (1 => 'error', 2 => 'warn', 3 => 'info', 4 => 'hint');
    my @diags;
    for my $d (@{$raw}) {
        my $range = $d->{range} || {};
        my $start = $range->{start} || {};
        my $end   = $range->{end}   || {};
        push @diags, {
            line     => $start->{line}      // 0,
            col      => $start->{character} // 0,
            end_line => $end->{line}        // ($start->{line} // 0),
            end_col  => $end->{character}   // ($start->{character} // 0),
            severity => $sev_map{ $d->{severity} || 1 } || 'error',
            code     => defined($d->{code}) ? "$d->{code}" : '',
            message  => $d->{message} // '',
            source   => $d->{source}  || $client->{name},
        };
    }

    $client->{diagnostics}{$uri}    = \@diags;
    $client->{last_diag_time}{$uri} = time();

    if ($self->{editor}) {
        my $path = _uri_to_path($uri);
        my $buf  = $self->{editor}->find_buffer_by_path($path);
        if ($buf) {
            $self->{editor}->set_diagnostics($buf, "lsp_$client->{name}", \@diags);
        }
    }
}

sub wait_for_ready {
    my ($self, $name, $timeout) = @_;
    $timeout ||= 5.0;
    my $client = $self->{clients}{$name} or return 0;
    my $deadline = time() + $timeout;
    while ($client->{state} eq 'initializing' && time() < $deadline) {
        $self->pump;
        last if $client->{state} ne 'initializing';
        sleep(0.01);
    }
    return $client->{state} eq 'ready' ? 1 : 0;
}

sub wait_for_request {
    my ($self, $name, $req_id, $timeout) = @_;
    return undef if !defined $req_id || ref($req_id);
    $timeout ||= 5.0;
    my $client = $self->{clients}{$name} or return undef;
    my $req    = $client->{pending}{$req_id} or return undef;
    my $deadline = time() + $timeout;
    while (!$req->{done} && time() < $deadline) {
        $self->pump;
        last if $req->{done};
        sleep(0.01);
    }
    return $req->{done} ? $req->{result} : undef;
}

sub wait_for_diagnostics {
    my ($self, $buf, $timeout) = @_;
    $timeout ||= 5.0;
    return [] unless $buf && $buf->path;
    my $client = $self->client_for_buffer($buf) or return [];
    my $uri = _path_to_uri($buf->path);
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        $self->pump;
        if (exists $client->{diagnostics}{$uri} && @{ $client->{diagnostics}{$uri} }) {
            return $client->{diagnostics}{$uri};
        }
        sleep(0.01);
    }
    return $client->{diagnostics}{$uri} || [];
}

# --- Built-in Async perl -c Syntax Provider ---

sub check_perl_syntax {
    my ($self, $buf) = @_;
    return 0 unless $buf && $buf->filetype eq 'perl';
    my $buf_id = $buf->id;

    # Cancel any stale in-flight check for this buffer
    if (my $old = delete $self->{perl_jobs}{$buf_id}) {
        eval { kill 'TERM', $old->{pid} if $old->{pid} };
        eval { close $old->{fh} if $old->{fh} };
        eval { waitpid($old->{pid}, 1) if $old->{pid} };
        unlink $old->{tmpfile} if $old->{tmpfile} && -f $old->{tmpfile};
    }

    my ($tfh, $tpath) = tempfile('neoperl_chk_XXXXXX', SUFFIX => '.pl', TMPDIR => 1, UNLINK => 0);
    binmode($tfh, ':encoding(UTF-8)');
    print {$tfh} $buf->get_text;
    close $tfh;

    my @inc = ();
    if ($self->{editor}) {
        my $lib_dir = File::Spec->catdir($self->{editor}->cwd, 'lib');
        push @inc, "-I$lib_dir" if -d $lib_dir;
    }

    my ($wtr, $rdr);
    my $err = gensym;
    my $pid = eval { open3($wtr, $rdr, $err, $^X, @inc, '-c', $tpath) };
    if (!$pid) {
        unlink $tpath;
        return 0;
    }
    close $wtr;
    close $rdr;
    _set_nonblock($err);

    $self->{perl_jobs}{$buf_id} = {
        pid     => $pid,
        fh      => $err,
        errbuf  => '',
        tmpfile => $tpath,
        buf     => $buf,
        done    => 0,
    };
    return 1;
}

sub _pump_perl_jobs {
    my ($self) = @_;
    my $activity = 0;
    for my $buf_id (keys %{ $self->{perl_jobs} }) {
        my $job = $self->{perl_jobs}{$buf_id};
        my $fh  = $job->{fh};
        my $eof = 0;
        if ($fh) {
            while (1) {
                my $chunk = '';
                my $n = sysread($fh, $chunk, 8192);
                if (!defined $n) {
                    last if $!{EAGAIN} || $!{EWOULDBLOCK};
                    $eof = 1;
                    last;
                }
                elsif ($n == 0) {
                    $eof = 1;
                    last;
                }
                else {
                    $job->{errbuf} .= $chunk;
                    $activity++;
                }
            }
        }
        else {
            $eof = 1;
        }

        if ($eof) {
            close $fh if $fh;
            waitpid($job->{pid}, 0) if $job->{pid};
            my $status = $? >> 8;
            unlink $job->{tmpfile} if $job->{tmpfile} && -f $job->{tmpfile};
            delete $self->{perl_jobs}{$buf_id};

            my $diags = _parse_perl_c_output($job->{errbuf}, $job->{tmpfile}, $status);
            if ($self->{editor} && $job->{buf}) {
                $self->{editor}->set_diagnostics($job->{buf}, 'perl_syntax', $diags);
            }
            $activity++;
        }
    }
    return $activity;
}

sub _parse_perl_c_output {
    my ($output, $tmpfile, $exit_code) = @_;
    my @diags;
    return \@diags if !defined($output) || !length($output);
    my $base = $tmpfile;
    $base =~ s{.*/}{};

    for my $line (split /\r?\n/, $output) {
        next if $line =~ /syntax OK\s*$/;
        next if $line =~ /^BEGIN failed--compilation aborted/;
        next if $line =~ /had compilation errors\.\s*$/;

        if ($line =~ /^(.*?)\s+at\s+\Q$tmpfile\E\s+line\s+(\d+)(?:,\s*(.*))?$/
            || $line =~ /^(.*?)\s+at\s+.*\Q$base\E\s+line\s+(\d+)(?:,\s*(.*))?$/)
        {
            my ($msg, $lnum, $extra) = ($1, $2, $3);
            $msg .= " ($extra)" if defined $extra && length $extra;
            my $sev = ($exit_code == 0) ? 'warn' : 'error';
            push @diags, {
                line     => ($lnum > 0 ? $lnum - 1 : 0),
                col      => 0,
                end_line => ($lnum > 0 ? $lnum - 1 : 0),
                end_col  => 0,
                severity => $sev,
                code     => 'perl-c',
                message  => $msg,
                source   => 'perl_syntax',
            };
        }
    }
    return \@diags;
}

sub wait_for_perl_check {
    my ($self, $buf, $timeout) = @_;
    $timeout ||= 5.0;
    return [] unless $buf;
    my $buf_id = $buf->id;
    my $deadline = time() + $timeout;
    while (exists $self->{perl_jobs}{$buf_id} && time() < $deadline) {
        $self->pump;
        last unless exists $self->{perl_jobs}{$buf_id};
        sleep(0.01);
    }
    return $self->{editor} ? $self->{editor}->get_diagnostics($buf, source => 'perl_syntax') : [];
}

# --- External Compiler Diagnostic Providers (cobc, glslangValidator, ocloc, hipcc, xcrun metal) ---

sub check_cobc_syntax {
    my ($self, $buf, %opts) = @_;
    return $self->check_external_compiler($buf, tool => 'cobc', %opts);
}

sub check_external_compiler {
    my ($self, $buf, %opts) = @_;
    return $opts{sync} ? [] : 0 unless $buf;
    my $ft = lc($buf->filetype // '');

    my $tool = $opts{tool};
    if (!$tool) {
        $tool = 'cobc'             if $ft eq 'cobol' && $self->{compilers}{cobc};
        $tool = 'glslangValidator' if $ft eq 'glsl'  && $self->{compilers}{glslangValidator};
        $tool = 'ocloc'            if $ft eq 'sycl'  && $self->{compilers}{ocloc};
        $tool = 'hipcc'            if $ft eq 'hip'   && $self->{compilers}{hipcc};
        $tool = 'xcrun_metal'      if $ft eq 'metal' && $self->{compilers}{xcrun_metal} && $opts{allow_xcrun};
    }
    return $opts{sync} ? [] : 0 unless defined $tool && $self->{compilers}{$tool};

    my $exe = $self->{compilers}{$tool};
    my $buf_id = $buf->id;

    # Cancel any stale in-flight compiler check for this buffer
    if (my $old = delete $self->{compiler_jobs}{$buf_id}) {
        eval { kill 'TERM', $old->{pid} if $old->{pid} };
        eval { close $old->{out} if $old->{out} };
        eval { close $old->{err} if $old->{err} };
        eval { waitpid($old->{pid}, 1) if $old->{pid} };
        unlink $old->{tmpfile} if $old->{tmpfile} && -f $old->{tmpfile};
    }

    my %suffix_for = (
        cobc             => '.cbl',
        glslangValidator => ($buf->path && $buf->path =~ /(\.(?:vert|frag|comp|geom|tesc|tese))\z/i ? lc($1) : '.comp'),
        ocloc            => '.cl',
        hipcc            => '.hip',
        xcrun_metal      => '.metal',
    );
    my $suffix = $suffix_for{$tool} || '.txt';
    my ($tfh, $tpath) = tempfile('neoperl_cmp_XXXXXX', SUFFIX => $suffix, TMPDIR => 1, UNLINK => 0);
    binmode($tfh, ':encoding(UTF-8)');
    print {$tfh} $buf->get_text;
    close $tfh;

    my @cmd;
    if ($tool eq 'cobc') {
        @cmd = ($exe, '-fsyntax-only', '-Wall', $tpath);
    }
    elsif ($tool eq 'glslangValidator') {
        @cmd = ($exe, $tpath);
    }
    elsif ($tool eq 'ocloc') {
        @cmd = ($exe, 'compile', '-file', $tpath);
    }
    elsif ($tool eq 'hipcc') {
        @cmd = ($exe, '-fsyntax-only', $tpath);
    }
    elsif ($tool eq 'xcrun_metal') {
        @cmd = ($exe, 'metal', '-fsyntax-only', $tpath);
    }
    else {
        unlink $tpath;
        return $opts{sync} ? [] : 0;
    }

    my ($wtr, $rdr);
    my $err = gensym;
    my $pid = eval { open3($wtr, $rdr, $err, @cmd) };
    if (!$pid) {
        unlink $tpath;
        return $opts{sync} ? [] : 0;
    }
    close $wtr;
    _set_nonblock($rdr);
    _set_nonblock($err);

    my $source = "compiler_$tool";
    $self->{compiler_jobs}{$buf_id} = {
        pid     => $pid,
        out     => $rdr,
        err     => $err,
        out_eof => 0,
        err_eof => 0,
        buf_txt => '',
        tmpfile => $tpath,
        buf     => $buf,
        tool    => $tool,
        source  => $source,
    };

    if ($opts{sync}) {
        return $self->wait_for_compiler_check($buf, $opts{timeout} || 5.0, $source);
    }
    return 1;
}

sub _pump_compiler_jobs {
    my ($self) = @_;
    my $activity = 0;

    for my $buf_id (keys %{ $self->{compiler_jobs} }) {
        my $job = $self->{compiler_jobs}{$buf_id};
        for my $slot (['out', 'out_eof'], ['err', 'err_eof']) {
            my ($fh_k, $eof_k) = @$slot;
            next if $job->{$eof_k};
            my $fh = $job->{$fh_k};
            if (!$fh) {
                $job->{$eof_k} = 1;
                next;
            }
            while (1) {
                my $chunk = '';
                my $n = sysread($fh, $chunk, 8192);
                if (!defined $n) {
                    last if $!{EAGAIN} || $!{EWOULDBLOCK};
                    $job->{$eof_k} = 1;
                    last;
                }
                elsif ($n == 0) {
                    $job->{$eof_k} = 1;
                    last;
                }
                else {
                    $job->{buf_txt} .= $chunk;
                    $activity++;
                }
            }
        }

        if ($job->{out_eof} && $job->{err_eof}) {
            close $job->{out} if $job->{out};
            close $job->{err} if $job->{err};
            waitpid($job->{pid}, 0) if $job->{pid};
            my $status = $? >> 8;
            unlink $job->{tmpfile} if $job->{tmpfile} && -f $job->{tmpfile};
            delete $self->{compiler_jobs}{$buf_id};

            my $diags = _parse_external_compiler_output(
                $job->{tool}, $job->{buf_txt}, $job->{tmpfile}, $status, $job->{source}
            );
            $self->{last_compiler_diags}{$buf_id}{ $job->{source} } = $diags;
            if ($self->{editor} && $job->{buf}) {
                $self->{editor}->set_diagnostics($job->{buf}, $job->{source}, $diags);
            }
            $activity++;
        }
    }
    return $activity;
}

sub _parse_external_compiler_output {
    my ($tool, $output, $tmpfile, $exit_code, $source) = @_;
    my @diags;
    return \@diags if !defined($output) || !length($output);
    my $base = $tmpfile;
    $base =~ s{.*/}{};

    for my $line (split /\r?\n/, $output) {
        if ($tool eq 'cobc') {
            # Example: /tmp/foo.cbl:7: error: 'UNDEFINED-VAR' is not defined
            # or:      /tmp/foo.cbl:7:12: warning: ...
            if ($line =~ /(?:\Q$tmpfile\E|\Q$base\E):(\d+)(?::(\d+))?:\s*(error|warning|note):\s*(.+)$/i) {
                my ($lnum, $cnum, $sev_raw, $msg) = ($1, $2 // 1, lc($3), $4);
                my $sev = $sev_raw eq 'error' ? 'error'
                        : $sev_raw eq 'note'  ? 'info'
                        : 'warn';
                push @diags, {
                    line     => ($lnum > 0 ? $lnum - 1 : 0),
                    col      => ($cnum > 0 ? $cnum - 1 : 0),
                    end_line => ($lnum > 0 ? $lnum - 1 : 0),
                    end_col  => ($cnum > 0 ? $cnum : 1),
                    severity => $sev,
                    code     => 'cobc',
                    message  => $msg,
                    source   => $source || 'compiler_cobc',
                };
            }
        }
        elsif ($tool eq 'glslangValidator') {
            # Example: ERROR: /tmp/foo.comp:12: 'x' : undeclared identifier
            if ($line =~ /\A(ERROR|WARNING):\s+.*?:(\d+):\s*(.+)$/i) {
                my ($sev_raw, $lnum, $msg) = (lc($1), $2, $3);
                push @diags, {
                    line     => ($lnum > 0 ? $lnum - 1 : 0),
                    col      => 0,
                    end_line => ($lnum > 0 ? $lnum - 1 : 0),
                    end_col  => 1,
                    severity => ($sev_raw eq 'error' ? 'error' : 'warn'),
                    code     => 'glslang',
                    message  => $msg,
                    source   => $source || 'compiler_glslangValidator',
                };
            }
        }
        else {
            # Clang/HIP/Metal/ocloc standard file:line:col: severity: message
            if ($line =~ /(?:\Q$tmpfile\E|\Q$base\E):(\d+):(\d+):\s*(fatal error|error|warning|note):\s*(.+)$/i) {
                my ($lnum, $cnum, $sev_raw, $msg) = ($1, $2, lc($3), $4);
                my $sev = ($sev_raw =~ /error/) ? 'error'
                        : ($sev_raw eq 'note')  ? 'info'
                        : 'warn';
                push @diags, {
                    line     => ($lnum > 0 ? $lnum - 1 : 0),
                    col      => ($cnum > 0 ? $cnum - 1 : 0),
                    end_line => ($lnum > 0 ? $lnum - 1 : 0),
                    end_col  => ($cnum > 0 ? $cnum : 1),
                    severity => $sev,
                    code     => $tool,
                    message  => $msg,
                    source   => $source || "compiler_$tool",
                };
            }
        }
    }
    return \@diags;
}

sub wait_for_compiler_check {
    my ($self, $buf, $timeout, $source) = @_;
    $timeout ||= 5.0;
    return [] unless $buf;
    my $buf_id = $buf->id;
    my $job = $self->{compiler_jobs}{$buf_id};
    $source ||= ($job ? $job->{source} : undef);
    my $deadline = time() + $timeout;
    while (exists $self->{compiler_jobs}{$buf_id} && time() < $deadline) {
        $self->pump;
        last unless exists $self->{compiler_jobs}{$buf_id};
        sleep(0.01);
    }
    if ($self->{editor} && defined $source) {
        return $self->{editor}->get_diagnostics($buf, source => $source);
    }
    return defined($source)
        ? ($self->{last_compiler_diags}{$buf_id}{$source} || [])
        : [];
}

# --- Info & Shutdown ---

sub info {
    my ($self) = @_;
    my %clients;
    for my $name (keys %{ $self->{clients} }) {
        my $c = $self->{clients}{$name};
        $clients{$name} = {
            name         => $name,
            state        => $c->{state},
            pid          => $c->{pid},
            cmd          => $c->{cmd},
            opened_count => scalar(keys %{ $c->{opened_uris} }),
        };
    }
    return {
        configured    => [ $self->configured_servers ],
        clients       => \%clients,
        builtin_langs => $self->{builtin} ? $self->{builtin}->supported_langs() : [],
        compilers     => $self->external_compilers(),
        perl_jobs     => scalar(keys %{ $self->{perl_jobs} }),
        compiler_jobs => scalar(keys %{ $self->{compiler_jobs} }),
    };
}

sub stop_server {
    my ($self, $name) = @_;
    my $client = delete $self->{clients}{$name} or return 0;
    if ($client->{state} ne 'stopped') {
        eval {
            $self->_send_request($client, 'shutdown', undef);
            $self->_send_notification($client, 'exit', undef);
        };
        $client->{state} = 'stopped';
    }
    close $client->{wtr} if $client->{wtr};
    close $client->{rdr} if $client->{rdr};
    close $client->{err} if $client->{err};
    if ($client->{pid}) {
        my $deadline = time() + 0.4;
        my $reaped = 0;
        while (time() < $deadline) {
            my $r = waitpid($client->{pid}, 1);
            if ($r > 0 || $r == -1) {
                $reaped = 1;
                last;
            }
            sleep(0.02);
        }
        if (!$reaped) {
            kill 'TERM', $client->{pid};
            waitpid($client->{pid}, 0);
        }
    }
    return 1;
}

sub stop_all {
    my ($self) = @_;
    for my $name (keys %{ $self->{clients} }) {
        $self->stop_server($name);
    }
    for my $buf_id (keys %{ $self->{perl_jobs} }) {
        my $job = delete $self->{perl_jobs}{$buf_id};
        kill 'TERM', $job->{pid} if $job->{pid};
        close $job->{fh} if $job->{fh};
        waitpid($job->{pid}, 0) if $job->{pid};
        unlink $job->{tmpfile} if $job->{tmpfile} && -f $job->{tmpfile};
    }
    for my $buf_id (keys %{ $self->{compiler_jobs} }) {
        my $job = delete $self->{compiler_jobs}{$buf_id};
        kill 'TERM', $job->{pid} if $job->{pid};
        close $job->{out} if $job->{out};
        close $job->{err} if $job->{err};
        waitpid($job->{pid}, 0) if $job->{pid};
        unlink $job->{tmpfile} if $job->{tmpfile} && -f $job->{tmpfile};
    }
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    $self->stop_all;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::LSP - Asynchronous JSON-RPC 2.0 LSP client and perl -c provider

=head1 SYNOPSIS

    use NeoPerl::Plugin::LSP;
    my $lsp = NeoPerl::Plugin::LSP->new(editor => $editor);
    $lsp->hover($buf, 10, 4, sub { my ($res) = @_; ... });

=head1 DESCRIPTION

Implements a non-blocking C<Content-Length> framed JSON-RPC 2.0 Language Server
Protocol client (auto-configured for C<clangd> on C/C++/XS files) alongside a
built-in asynchronous C<perl -c> syntax diagnostics provider for Perl buffers.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
