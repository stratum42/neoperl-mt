package NeoPerl::Antigravity::ACP;

use strict;
use warnings;
use Carp qw(croak);
use File::Spec ();
use IPC::Open3 qw(open3);
use IO::Select ();
use IO::Handle ();
use Symbol qw(gensym);
use POSIX ();
use Time::HiRes qw(time sleep);

our $VERSION = '0.01';

our $INSTALL_COMMAND   = 'curl -fsSL https://antigravity.google/cli/install.sh | bash';
our $MAX_STDERR_LINES  = 40;

my $HAS_MOJO_JSON;
BEGIN {
    $HAS_MOJO_JSON = eval { require Mojo::JSON; 1 } ? 1 : 0;
    require JSON::PP unless $HAS_MOJO_JSON;
}

sub _encode_json {
    my $s = $HAS_MOJO_JSON ? Mojo::JSON::encode_json($_[0]) : JSON::PP->new->utf8->encode($_[0]);
    $s =~ s/[\r\n]+//g;
    return $s;
}

sub _decode_json {
    return $HAS_MOJO_JSON ? Mojo::JSON::decode_json($_[0]) : JSON::PP->new->utf8->decode($_[0]);
}

sub _jtrue  { $HAS_MOJO_JSON ? Mojo::JSON::true()  : JSON::PP::true }
sub _jfalse { $HAS_MOJO_JSON ? Mojo::JSON::false() : JSON::PP::false }

sub install_command {
    return $INSTALL_COMMAND;
}

sub discover_agy_binary {
    return undef if $ENV{NEOPERL_AGY_NO_DISCOVER};

    if (defined $ENV{NEOPERL_AGY_BIN} && length $ENV{NEOPERL_AGY_BIN}) {
        return undef if $ENV{NEOPERL_AGY_BIN} eq 'none';
        if (-x $ENV{NEOPERL_AGY_BIN} && !-d $ENV{NEOPERL_AGY_BIN}) {
            return $ENV{NEOPERL_AGY_BIN};
        }
    }

    my $sep = ($^O eq 'MSWin32') ? ';' : ':';
    for my $dir (split /\Q$sep\E/, ($ENV{PATH} // '')) {
        next unless length $dir;
        my $cand = File::Spec->catfile($dir, 'agy');
        return $cand if -x $cand && !-d $cand;
        return "$cand.exe" if $^O eq 'MSWin32' && -x "$cand.exe" && !-d "$cand.exe";
    }

    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    my @candidates;
    push @candidates, File::Spec->catfile($home, '.local', 'bin', 'agy') if length $home;
    push @candidates, '/opt/homebrew/bin/agy';
    push @candidates, '/usr/local/bin/agy';
    push @candidates, File::Spec->catfile($home, '.antigravity', 'bin', 'agy') if length $home;
    push @candidates, File::Spec->catfile($home, '.npm-global', 'bin', 'agy')  if length $home;
    push @candidates, '/Applications/Antigravity.app/Contents/Resources/app/bin/agy';

    for my $cand (@candidates) {
        return $cand if defined $cand && -x $cand && !-d $cand;
    }

    return undef;
}

sub install_instructions {
    return join("\n",
        "Antigravity CLI ('agy') was not found on PATH or in standard install locations.",
        "Install using the official CLI installer:",
        "  $INSTALL_COMMAND",
        "",
        "Then sign in once:",
        "  agy acp --login",
        "",
        "Or run NeoPerl::MT offline with the built-in ACP loopback server:",
        "  npl --agy-mock",
    );
}

sub _is_auth_error {
    my ($err) = @_;
    return 0 unless defined $err;
    if (ref($err) eq 'HASH') {
        my $code = defined($err->{code}) ? int($err->{code}) : 0;
        return 1 if $code == -32000 || $code == -32001;
        my $msg  = $err->{message} // '';
        my $data = ref($err->{data}) eq 'HASH'
            ? join(' ', grep { defined } values %{ $err->{data} })
            : ($err->{data} // '');
        return ("$msg $data" =~ /auth|login|sign.?in|credential|unauthenticated/i) ? 1 : 0;
    }
    return ("$err" =~ /auth|login|sign.?in|credential|unauthenticated/i) ? 1 : 0;
}

sub new {
    my ($class, %args) = @_;
    return bless {
        editor             => $args{editor},
        editor_mcp         => $args{editor_mcp},
        cwd                => $args{cwd} // '.',
        mock               => $args{mock} ? 1 : 0,
        disabled           => $args{disabled} ? 1 : 0,
        agy_bin             => $args{agy_bin},
        sandbox             => $args{sandbox} ? 1 : 0,
        process_per_session => exists($args{process_per_session}) ? ($args{process_per_session} ? 1 : 0) : undef,
        add_dirs            => ref($args{add_dirs}) eq 'ARRAY' ? [ @{ $args{add_dirs} } ] : [],
        preferred_model     => $args{model} // $args{agy_model},
        post_tidy_hook      => $args{post_tidy_hook},
        auto_approve        => $args{auto_approve} ? 1 : 0,
        allow_always_tools  => {},
        callbacks           => {
            on_update        => $args{on_update},
            on_permission    => $args{on_permission},
            on_turn_complete => $args{on_turn_complete},
            on_error         => $args{on_error},
            on_state_change  => $args{on_state_change},
        },
        state               => 'offline',
        last_error          => undef,
        last_cmd            => [],
        _connect_stage      => undef,
        _connect_opts       => {},
        _turn_response_buf  => '',
        pid                => undef,
        in_fh              => undef,
        out_fh             => undef,
        err_fh             => undef,
        sel                => undef,
        read_buf           => '',
        stderr_buf         => '',
        stderr_lines       => [],
        next_id            => 1,
        pending            => {},
        pending_perms      => {},
        terminals          => {},
        term_seq           => 0,
        session_id         => undef,
        initialized        => 0,
        agent_info         => {},
        agent_capabilities => {},
        auth_methods       => [],
        available_models   => [],
        current_model      => undef,
        config_options     => [],
        available_commands => [],
        current_mode       => undef,
        running            => 0,
        history            => [],
    }, $class;
}

sub state               { $_[0]{state} }
sub is_running          { $_[0]{running} ? 1 : 0 }
sub is_initialized      { $_[0]{initialized} ? 1 : 0 }
sub is_ready            { ($_[0]{state} // '') eq 'ready' ? 1 : 0 }
sub is_mock             { $_[0]{mock} ? 1 : 0 }
sub is_disabled         { $_[0]{disabled} ? 1 : 0 }
sub agy_bin             { $_[0]{agy_bin} }
sub last_error          { $_[0]{last_error} }
sub last_cmd            { [ @{ $_[0]{last_cmd} || [] } ] }
sub session_id          { $_[0]{session_id} }
sub agent_info          { $_[0]{agent_info} }
sub agent_capabilities  { $_[0]{agent_capabilities} }
sub auth_methods        { [ @{ $_[0]{auth_methods} || [] } ] }
sub available_models    { [ map { { %$_ } } @{ $_[0]{available_models} || [] } ] }
sub current_model       { $_[0]{current_model} }
sub config_options      { [ @{ $_[0]{config_options} || [] } ] }
sub available_commands  { [ @{ $_[0]{available_commands} || [] } ] }
sub current_mode        { $_[0]{current_mode} }
sub pending_permissions { [ values %{ $_[0]{pending_perms} } ] }
sub set_callback        { my ($self, $k, $cb) = @_; $self->{callbacks}{$k} = $cb; return $self }
sub set_editor          { $_[0]{editor} = $_[1]; return $_[0] }
sub set_editor_mcp      { $_[0]{editor_mcp} = $_[1]; return $_[0] }
sub set_post_tidy       { $_[0]{post_tidy_hook} = $_[1]; return $_[0] }

sub stderr_lines {
    my ($self) = @_;
    return [ @{ $self->{stderr_lines} || [] } ];
}

sub last_stderr {
    my ($self, $limit) = @_;
    my $lines = $self->{stderr_lines} || [];
    return '' unless @$lines;
    if (defined $limit && $limit > 0 && @$lines > $limit) {
        return join("\n", @{$lines}[ -$limit .. -1 ]);
    }
    return join("\n", @$lines);
}

sub _set_state {
    my ($self, $new_state, $err_msg) = @_;
    my $old = $self->{state} // 'offline';
    $self->{state} = $new_state;
    if (defined $err_msg) {
        $self->{last_error} = $err_msg;
    }
    elsif ($new_state eq 'ready' || $new_state eq 'connecting') {
        $self->{last_error} = undef;
    }
    if ($old ne $new_state && $self->{callbacks}{on_state_change}) {
        eval { $self->{callbacks}{on_state_change}->($new_state, $old, $self->{last_error}) };
    }
    return $new_state;
}

sub _record_stderr_chunk {
    my ($self, $chunk, $flush) = @_;
    $self->{stderr_buf} .= $chunk if defined $chunk && length $chunk;
    while ((my $nl = index($self->{stderr_buf}, "\n")) >= 0) {
        my $line = substr($self->{stderr_buf}, 0, $nl);
        substr($self->{stderr_buf}, 0, $nl + 1, '');
        $line =~ s/\r$//;
        push @{ $self->{stderr_lines} }, $line if length $line;
    }
    if ($flush && length $self->{stderr_buf}) {
        my $rem = $self->{stderr_buf};
        $self->{stderr_buf} = '';
        $rem =~ s/[\r\n]+$//;
        push @{ $self->{stderr_lines} }, $rem if length $rem;
    }
    if (@{ $self->{stderr_lines} } > $MAX_STDERR_LINES) {
        splice(@{ $self->{stderr_lines} }, 0, @{ $self->{stderr_lines} } - $MAX_STDERR_LINES);
    }
    return;
}

sub _build_mcp_servers {
    my ($self, %opts) = @_;
    my $port = $opts{mcp_port} || ($self->{editor_mcp} ? $self->{editor_mcp}->port : 0);
    return [] unless $port;
    return [
        {
            type    => 'http',
            name    => 'neoperl-editor',
            url     => "http://127.0.0.1:$port/mcp",
            headers => [],
        },
    ];
}

sub start {
    my ($self, %opts) = @_;
    return 1 if $self->{running};

    my $mock    = exists($opts{mock}) ? ($opts{mock} ? 1 : 0) : $self->{mock};
    my $port    = ($opts{mcp_port} || ($self->{editor_mcp} ? ($self->{editor_mcp}->port // 0) : 0)) || 0;
    my $cwd     = $opts{cwd} // $self->{cwd};
    my $sandbox = exists($opts{sandbox}) ? ($opts{sandbox} ? 1 : 0) : $self->{sandbox};
    my $process_per_session = exists($opts{process_per_session})
        ? ($opts{process_per_session} ? 1 : 0)
        : (defined($self->{process_per_session})
            ? $self->{process_per_session}
            : ($port > 0 ? 1 : 0));

    my @dirs;
    my %seen_dir;
    for my $d ($cwd, @{ $opts{add_dirs} || $self->{add_dirs} || [] }) {
        next unless defined $d && length $d;
        next if $seen_dir{$d}++;
        push @dirs, $d;
    }

    my @cmd;
    if ($mock) {
        my @inc_args = map { "-I$_" } grep { defined $_ && !ref($_) && length $_ } @INC;
        @cmd = (
            $^X, @inc_args,
            '-MNeoPerl::Antigravity::ACP',
            '-e', 'NeoPerl::Antigravity::ACP::run_loopback_server(@ARGV)',
            '--',
            '--ide-mcp-port', "$port",
        );
        for my $d (@dirs) {
            push @cmd, '--add-dir', $d;
        }
        push @cmd, '--sandbox' if $sandbox;
        $self->{mock} = 1;
    }
    else {
        my $bin = $opts{agy_bin} || $self->{agy_bin} || discover_agy_binary();
        if (!defined $bin) {
            $self->_set_state('offline', 'Antigravity CLI (agy) not found');
            croak install_instructions();
        }
        @cmd = ($bin, 'acp');
        if ($port) {
            push @cmd, '--process-per-session' if $process_per_session;
            push @cmd, '--ide-mcp-port', "$port";
        }
        elsif ($process_per_session) {
            push @cmd, '--process-per-session';
        }
        for my $d (@dirs) {
            push @cmd, '--add-dir', $d;
        }
        push @cmd, '--sandbox' if $sandbox;
        $self->{agy_bin} = $bin;
        $self->{mock}    = 0;
    }

    my ($in_fh, $out_fh);
    my $err_fh = gensym();
    my $pid = open3($in_fh, $out_fh, $err_fh, @cmd);
    croak "Failed to launch ACP process: $!" unless $pid;

    $in_fh->autoflush(1);
    $out_fh->blocking(0);
    $err_fh->blocking(0);

    $self->{pid}                = $pid;
    $self->{in_fh}              = $in_fh;
    $self->{out_fh}             = $out_fh;
    $self->{err_fh}             = $err_fh;
    $self->{sel}                = IO::Select->new($out_fh, $err_fh);
    $self->{running}            = 1;
    $self->{disabled}           = 0;
    $self->{initialized}        = 0;
    $self->{session_id}         = undef;
    $self->{read_buf}           = '';
    $self->{stderr_buf}         = '';
    $self->{stderr_lines}       = [];
    $self->{_turn_response_buf} = '';
    $self->{pending}            = {};
    $self->{pending_perms}      = {};
    $self->{last_cmd}           = \@cmd;
    $self->_set_state('connecting');

    return 1;
}

sub connect_async {
    my ($self, %opts) = @_;
    return 1 if $self->{running} && $self->{state} eq 'ready' && defined $self->{session_id};
    return 1 if $self->{running} && $self->{state} eq 'connecting' && defined $self->{_connect_stage};

    $self->{_connect_opts} = \%opts;
    $self->{preferred_model} = $opts{model} if defined $opts{model} && length $opts{model};

    my $ok = eval { $self->start(%opts) };
    if (!$ok) {
        my $err = $@ || 'Failed to start ACP process';
        chomp $err;
        my $mock = exists($opts{mock}) ? ($opts{mock} ? 1 : 0) : $self->{mock};
        if (!$mock && !defined($opts{agy_bin} || $self->{agy_bin} || discover_agy_binary())) {
            $self->_set_state('offline', 'Antigravity CLI (agy) not found');
        }
        else {
            $self->_set_state('error', $err);
            $self->{callbacks}{on_error}->({ code => -32098, message => $err })
                if $self->{callbacks}{on_error};
        }
        return 0;
    }

    $self->{_connect_stage} = 'initializing';
    $self->initialize(
        async    => 1,
        callback => sub {
            my ($res, $err) = @_;
            if ($err) {
                $self->_handle_handshake_error('initialize', $err);
                return;
            }
            $self->_after_initialize_async();
        },
    );
    return 1;
}

sub _after_initialize_async {
    my ($self) = @_;
    return unless $self->{running};
    my $opts = $self->{_connect_opts} || {};
    $self->{_connect_stage} = 'creating_session';
    $self->new_session(
        async    => 1,
        cwd      => $opts->{cwd} // $self->{cwd},
        (defined $opts->{mcp_port} ? (mcp_port => $opts->{mcp_port}) : ()),
        callback => sub {
            my ($res, $err) = @_;
            if ($err) {
                $self->_handle_handshake_error('session/new', $err);
                return;
            }
            $self->_after_session_new_async();
        },
    );
    return;
}

sub _after_session_new_async {
    my ($self) = @_;
    my $want = $self->{preferred_model};
    if (defined $want && length $want && (!defined($self->{current_model}) || $self->{current_model} ne $want)) {
        $self->{_connect_stage} = 'setting_model';
        $self->set_model(
            $want,
            async    => 1,
            callback => sub {
                my ($res, $err) = @_;
                $self->{_connect_stage} = undef;
                # Stay ready even if preferred model switch is rejected by server
                $self->_set_state('ready') if $self->{running};
            },
        );
        return;
    }
    $self->{_connect_stage} = undef;
    $self->_set_state('ready') if $self->{running};
    return;
}

sub _handle_handshake_error {
    my ($self, $stage, $err) = @_;
    $self->{_connect_stage} = undef;
    my $msg = ref($err) eq 'HASH' ? ($err->{message} // "$stage failed") : "$err";
    if (_is_auth_error($err)) {
        $self->_set_state('auth_required', $msg);
        return;
    }
    $self->_set_state('error', $msg);
    $self->{callbacks}{on_error}->($err) if $self->{callbacks}{on_error};
    return;
}

sub reconnect {
    my ($self, %opts) = @_;
    my $sync = delete $opts{sync};
    $self->stop();
    if ($sync) {
        $self->start(%opts);
        $self->initialize(%opts);
        $self->new_session(%opts);
        if (defined $self->{preferred_model} && length $self->{preferred_model}
            && (!defined($self->{current_model}) || $self->{current_model} ne $self->{preferred_model}))
        {
            eval { $self->set_model($self->{preferred_model}) };
        }
        return 1;
    }
    return $self->connect_async(%opts);
}

sub _send_message {
    my ($self, $msg) = @_;
    croak "ACP process is not running" unless $self->{running} && $self->{in_fh};
    my $line = _encode_json($msg) . "\n";
    my $ok = print { $self->{in_fh} } $line;
    croak "Failed writing to ACP stdin pipe: $!" unless $ok;
    return 1;
}

sub send_request {
    my ($self, $method, $params, $cb) = @_;
    my $id = $self->{next_id}++;
    $self->{pending}{$id} = {
        id       => $id,
        method   => $method,
        callback => $cb,
        done     => 0,
        result   => undef,
        error    => undef,
    };
    $self->_send_message({
        jsonrpc => '2.0',
        id      => $id,
        method  => $method,
        params  => $params || {},
    });
    return $id;
}

sub _send_response {
    my ($self, $id, $result, $error) = @_;
    my %msg = (jsonrpc => '2.0', id => $id);
    if (defined $error) {
        $msg{error} = ref($error) eq 'HASH' ? $error : { code => -32000, message => "$error" };
    }
    else {
        $msg{result} = defined($result) ? $result : {};
    }
    return $self->_send_message(\%msg);
}

sub wait_response {
    my ($self, $req_id, $timeout) = @_;
    $timeout ||= 10.0;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        if ($self->{editor_mcp} && $self->{editor_mcp}->is_running) {
            $self->{editor_mcp}->poll(0);
        }
        $self->poll(0.02);
        my $p = $self->{pending}{$req_id};
        if ($p && $p->{done}) {
            delete $self->{pending}{$req_id};
            if ($p->{error}) {
                my $msg = ref($p->{error}) eq 'HASH'
                    ? ($p->{error}{message} // 'unknown error')
                    : "$p->{error}";
                if (_is_auth_error($p->{error})) {
                    $self->_set_state('auth_required', $msg);
                }
                croak "ACP error ($p->{method}): $msg";
            }
            return $p->{result};
        }
        last unless $self->{running};
        if ($self->{editor_mcp} && $self->{editor_mcp}->is_running) {
            $self->{editor_mcp}->poll(0);
        }
    }
    my $p = delete $self->{pending}{$req_id};
    if ($p && $p->{done}) {
        if ($p->{error}) {
            my $msg = ref($p->{error}) eq 'HASH' ? ($p->{error}{message} // 'unknown error') : "$p->{error}";
            croak "ACP error ($p->{method}): $msg";
        }
        return $p->{result};
    }
    croak "Timed out waiting for ACP response to request #$req_id";
}

sub _process_initialize_result {
    my ($self, $res) = @_;
    return unless ref($res) eq 'HASH';
    $self->{initialized}        = 1;
    $self->{agent_info}         = ref($res->{agentInfo}) eq 'HASH' ? $res->{agentInfo} : {};
    $self->{agent_capabilities} = ref($res->{agentCapabilities}) eq 'HASH' ? $res->{agentCapabilities} : {};
    $self->{auth_methods}       = ref($res->{authMethods}) eq 'ARRAY' ? [ @{ $res->{authMethods} } ] : [];
    return;
}

sub _extract_models_from_config_options {
    my ($self, $opts) = @_;
    return unless ref($opts) eq 'ARRAY';
    $self->{config_options} = [ @$opts ];
    for my $opt (@$opts) {
        next unless ref($opt) eq 'HASH';
        my $cat = $opt->{category} // '';
        my $oid = $opt->{id}       // '';
        next unless $cat eq 'model' || $oid eq 'model';
        $self->{current_model} = $opt->{currentValue} if defined $opt->{currentValue};
        if (ref($opt->{options}) eq 'ARRAY') {
            my @models;
            for my $o (@{ $opt->{options} }) {
                if (ref($o) eq 'HASH' && defined $o->{value}) {
                    push @models, {
                        modelId     => $o->{value},
                        id          => $o->{value},
                        name        => $o->{name} // $o->{value},
                        description => $o->{description} // '',
                    };
                }
                elsif (ref($o) eq 'HASH' && ref($o->{options}) eq 'ARRAY') {
                    for my $sub (@{ $o->{options} }) {
                        next unless ref($sub) eq 'HASH' && defined $sub->{value};
                        push @models, {
                            modelId     => $sub->{value},
                            id          => $sub->{value},
                            name        => $sub->{name} // $sub->{value},
                            description => $sub->{description} // '',
                        };
                    }
                }
            }
            $self->{available_models} = \@models if @models;
        }
        last;
    }
    return;
}

sub _process_session_result {
    my ($self, $res, $fallback_sid) = @_;
    return unless ref($res) eq 'HASH';
    $self->{session_id} = $res->{sessionId} // $fallback_sid;

    if (ref($res->{models}) eq 'HASH') {
        my $m = $res->{models};
        $self->{current_model} = $m->{currentModelId} if defined $m->{currentModelId};
        if (ref($m->{availableModels}) eq 'ARRAY') {
            $self->{available_models} = [
                map {
                    my $mid = $_->{modelId} // $_->{id} // '';
                    +{
                        modelId     => $mid,
                        id          => $mid,
                        name        => $_->{name} // $mid,
                        description => $_->{description} // '',
                    }
                } grep { ref($_) eq 'HASH' } @{ $m->{availableModels} }
            ];
        }
    }
    if (defined $res->{currentModelId}) {
        $self->{current_model} = $res->{currentModelId};
    }
    if (ref($res->{availableModels}) eq 'ARRAY' && !@{ $self->{available_models} }) {
        $self->{available_models} = [
            map {
                my $mid = $_->{modelId} // $_->{id} // '';
                +{
                    modelId     => $mid,
                    id          => $mid,
                    name        => $_->{name} // $mid,
                    description => $_->{description} // '',
                }
            } grep { ref($_) eq 'HASH' } @{ $res->{availableModels} }
        ];
    }
    if (ref($res->{configOptions}) eq 'ARRAY') {
        $self->_extract_models_from_config_options($res->{configOptions});
    }
    if (ref($res->{modes}) eq 'HASH' && defined $res->{modes}{currentModeId}) {
        $self->{current_mode} = $res->{modes}{currentModeId};
    }
    return;
}

sub initialize {
    my ($self, %opts) = @_;
    my $id = $self->send_request('initialize', {
        protocolVersion => 1,
        clientInfo      => {
            name    => 'NeoPerl::MT',
            version => $VERSION,
        },
        clientCapabilities => {
            fs => {
                readTextFile  => _jtrue(),
                writeTextFile => _jtrue(),
            },
            terminal    => _jtrue(),
            permissions => _jtrue(),
        },
    }, $opts{callback});
    return $id if $opts{async};
    my $res = $self->wait_response($id, $opts{timeout} || 10);
    $self->_process_initialize_result($res);
    return $res;
}

sub authenticate {
    my ($self, $method_id, %opts) = @_;
    if (!defined $method_id || !length $method_id) {
        if (@{ $self->{auth_methods} } && ref($self->{auth_methods}[0]) eq 'HASH') {
            $method_id = $self->{auth_methods}[0]{id} // $self->{auth_methods}[0]{methodId};
        }
        $method_id //= 'google';
    }
    my $cb = $opts{callback};
    my $id = $self->send_request('authenticate', {
        methodId => $method_id,
    }, sub {
        my ($res, $err) = @_;
        if ($err) {
            my $msg = ref($err) eq 'HASH' ? ($err->{message} // 'Authentication failed') : "$err";
            $self->_set_state('auth_required', $msg);
        }
        else {
            $self->{last_error} = undef;
            if (defined $self->{session_id}) {
                $self->_set_state('ready');
            }
            else {
                $self->_set_state('connecting');
            }
        }
        $cb->($res, $err) if $cb;
    });
    return $id if $opts{async};
    my $res = $self->wait_response($id, $opts{timeout} || 15);
    if ($opts{create_session} && !defined $self->{session_id}) {
        $self->new_session(cwd => $opts{cwd} // $self->{cwd});
    }
    return $res;
}

sub new_session {
    my ($self, %opts) = @_;
    my $id = $self->send_request('session/new', {
        cwd        => $opts{cwd} // $self->{cwd},
        mcpServers => $self->_build_mcp_servers(%opts),
    }, $opts{callback});
    return $id if $opts{async};
    my $res = $self->wait_response($id, $opts{timeout} || 10);
    $self->_process_session_result($res);
    $self->_set_state('ready') if defined $self->{session_id};
    return $res;
}

sub load_session {
    my ($self, $session_id, %opts) = @_;
    croak "load_session requires a sessionId" unless defined $session_id && length $session_id;
    my $cb = $opts{callback};
    my $id = $self->send_request('session/load', {
        sessionId  => $session_id,
        cwd        => $opts{cwd} // $self->{cwd},
        mcpServers => $self->_build_mcp_servers(%opts),
    }, sub {
        my ($res, $err) = @_;
        if (!$err) {
            $self->_process_session_result(ref($res) eq 'HASH' ? $res : {}, $session_id);
            $self->_set_state('ready') if defined $self->{session_id};
        }
        elsif (_is_auth_error($err)) {
            $self->_set_state('auth_required', $err->{message} // 'Authentication required');
        }
        $cb->($res, $err) if $cb;
    });
    return $id if $opts{async};
    my $res = $self->wait_response($id, $opts{timeout} || 10);
    $self->_process_session_result(ref($res) eq 'HASH' ? $res : {}, $session_id);
    $self->_set_state('ready') if defined $self->{session_id};
    return $res;
}

sub _find_model_config_id {
    my ($self) = @_;
    for my $opt (@{ $self->{config_options} || [] }) {
        next unless ref($opt) eq 'HASH';
        if (($opt->{category} // '') eq 'model' || ($opt->{id} // '') eq 'model') {
            return $opt->{id};
        }
    }
    return undef;
}

sub set_model {
    my ($self, $model_id, %opts) = @_;
    croak "set_model requires a modelId" unless defined $model_id && length $model_id;
    croak "ACP session not started; call new_session first" unless defined $self->{session_id};

    my $cb = $opts{callback};
    if ($opts{async}) {
        return $self->send_request('session/set_model', {
            sessionId => $self->{session_id},
            modelId   => $model_id,
        }, sub {
            my ($res, $err) = @_;
            if (!$err) {
                $self->{current_model}   = $model_id;
                $self->{preferred_model} = $model_id;
                $cb->($res, undef) if $cb;
                return;
            }
            my $code = ref($err) eq 'HASH' ? int($err->{code} // 0) : 0;
            my $cfg_id = ($code == -32601 || $code == -32002) ? $self->_find_model_config_id() : undef;
            if (defined $cfg_id) {
                $self->send_request('session/set_config_option', {
                    sessionId => $self->{session_id},
                    configId  => $cfg_id,
                    value     => $model_id,
                }, sub {
                    my ($r2, $e2) = @_;
                    if (!$e2) {
                        $self->{current_model}   = $model_id;
                        $self->{preferred_model} = $model_id;
                        $self->_extract_models_from_config_options($r2->{configOptions})
                            if ref($r2) eq 'HASH' && ref($r2->{configOptions}) eq 'ARRAY';
                    }
                    $cb->($r2, $e2) if $cb;
                });
                return;
            }
            $cb->($res, $err) if $cb;
        });
    }

    my $id  = $self->send_request('session/set_model', {
        sessionId => $self->{session_id},
        modelId   => $model_id,
    });
    my $res = eval { $self->wait_response($id, $opts{timeout} || 10) };
    if ($@) {
        my $err_str = $@;
        my $cfg_id  = ($err_str =~ /Method not found|Unknown.*method/i) ? $self->_find_model_config_id() : undef;
        if (defined $cfg_id) {
            my $id2 = $self->send_request('session/set_config_option', {
                sessionId => $self->{session_id},
                configId  => $cfg_id,
                value     => $model_id,
            });
            $res = $self->wait_response($id2, $opts{timeout} || 10);
            $self->_extract_models_from_config_options($res->{configOptions})
                if ref($res) eq 'HASH' && ref($res->{configOptions}) eq 'ARRAY';
        }
        else {
            die $err_str;
        }
    }
    $self->{current_model}   = $model_id;
    $self->{preferred_model} = $model_id;
    return $res;
}

sub doctor {
    my ($self) = @_;
    my $bin = $self->{agy_bin} || discover_agy_binary();
    my $mcp_url   = $self->{editor_mcp} ? eval { $self->{editor_mcp}->url } : undef;
    my $tool_list = $self->{editor_mcp} ? (eval { $self->{editor_mcp}->list_tool_names } || []) : [];
    my $mcp_tools = ref($tool_list) eq 'ARRAY' ? scalar(@$tool_list) : 0;
    my $state     = $self->{state} // 'offline';

    my $next_action;
    if ($state eq 'ready') {
        $next_action = $self->{mock}
            ? 'Connected to offline ACP loopback server (run plain npl without --agy-mock for live agy).'
            : 'Ready — open chat with <leader>aa or run :AgyChat <prompt>.';
    }
    elsif ($state eq 'connecting') {
        $next_action = 'Connecting to agy acp in background...';
    }
    elsif ($state eq 'auth_required') {
        $next_action = 'Sign in required — run :AgyLogin (<leader>aL) or `agy acp --login`.';
    }
    elsif ($state eq 'error') {
        my $err = $self->{last_error} // 'unknown error';
        $next_action = "ACP error ($err) — inspect stderr_tail and run :AgyReconnect or :AgyLogin.";
    }
    elsif (!defined $bin) {
        $next_action = "Install agy CLI: $INSTALL_COMMAND (or run :AgyInstall! or `npl --agy-mock`).";
    }
    elsif ($self->{disabled}) {
        $next_action = 'Antigravity disabled (--no-agy). Run :AgyReconnect to connect.';
    }
    else {
        $next_action = "Run :AgyReconnect to start $bin acp.";
    }

    return {
        binary           => $bin,
        state            => $state,
        mock             => $self->{mock} ? 1 : 0,
        session_id       => $self->{session_id},
        current_model    => $self->{current_model},
        available_models => $self->available_models(),
        auth_methods     => $self->auth_methods(),
        mcp_url          => $mcp_url,
        mcp_tools        => $mcp_tools,
        stderr_tail      => $self->stderr_lines(),
        next_action      => $next_action,
    };
}

sub _strip_memory_context_hint {
    my ($str) = @_;
    return '' unless defined $str;
    my $clean = $str;
    $clean =~ s/\A\s*\[Memory Context Hint\]\r?\n.*?(?:\r?\n\r?\n+|\z)//s;
    $clean =~ s/\A\s+|\s+\z//g;
    return $clean;
}

sub prompt {
    my ($self, $text, %opts) = @_;
    croak "ACP session not started; call new_session first" unless defined $self->{session_id};

    $self->{_turn_response_buf} = '';

    my $user_cb    = $opts{callback};
    my $raw_prompt = $opts{raw_prompt};
    my $file_path  = $opts{file_path};
    my $blocks     = [ { type => 'text', text => $text } ];
    my $id         = $self->send_request('session/prompt', {
        sessionId => $self->{session_id},
        prompt    => $blocks,
        (ref($opts{context}) eq 'HASH' ? (context => $opts{context}) : ()),
    }, sub {
        my ($res, $err) = @_;
        my $streamed = $self->{_turn_response_buf} // '';
        $self->{_turn_response_buf} = '';

        if ($err && _is_auth_error($err)) {
            my $msg = ref($err) eq 'HASH' ? ($err->{message} // 'Authentication required') : "$err";
            $self->_set_state('auth_required', $msg);
        }
        if (!$err && $self->{callbacks}{on_turn_complete}) {
            $self->{callbacks}{on_turn_complete}->($res, $text);
        }
        if (!$err && $self->{editor} && $self->{editor}->can('emit')) {
            my $assistant_text = length($streamed)
                ? $streamed
                : (ref($res) eq 'HASH' ? ($res->{finalText} // '') : '');

            my $prompt_src   = (defined $raw_prompt && length $raw_prompt) ? $raw_prompt : $text;
            my $clean_prompt = _strip_memory_context_hint($prompt_src);

            my $summary;
            if (ref($res) eq 'HASH' && defined $res->{summary} && length $res->{summary}) {
                $summary = $res->{summary};
            }
            elsif (length($clean_prompt) && length($assistant_text)) {
                my $p_part = $clean_prompt;
                my $a_part = $assistant_text;
                if (length($p_part) + length($a_part) + 18 > 1600) {
                    if (length($p_part) > 500) {
                        $p_part = substr($p_part, 0, 497) . '...';
                    }
                    my $max_a = 1600 - length($p_part) - 18;
                    if ($max_a > 20 && length($a_part) > $max_a) {
                        $a_part = substr($a_part, 0, $max_a - 3) . '...';
                    }
                }
                $summary = "User: $p_part\nAssistant: $a_part";
            }
            elsif (length($assistant_text)) {
                $summary = $assistant_text;
            }
            else {
                $summary = $clean_prompt;
            }
            if (defined($summary) && length($summary) > 1600) {
                $summary = substr($summary, 0, 1597) . '...';
            }

            $self->{editor}->emit('AgyTurnComplete',
                session_id => $self->{session_id},
                prompt     => $clean_prompt,
                response   => $assistant_text,
                summary    => $summary,
                (defined $file_path && length $file_path ? (file_path => $file_path) : ()),
            );
        }
        $user_cb->($res, $err) if $user_cb;
    });

    return $id if $opts{async};
    return $self->wait_response($id, $opts{timeout} || 180);
}

sub cancel {
    my ($self) = @_;
    return 0 unless $self->{running} && defined $self->{session_id};
    $self->_send_message({
        jsonrpc => '2.0',
        method  => 'session/cancel',
        params  => { sessionId => $self->{session_id} },
    });
    return 1;
}

sub _resolve_permission_option {
    my ($options, $decision) = @_;
    return (undef, undef) unless ref($options) eq 'ARRAY' && @$options;

    # 1. Direct match against exact optionId
    for my $opt (@$options) {
        next unless ref($opt) eq 'HASH' && defined $opt->{optionId};
        return ($opt->{optionId}, $opt->{kind}) if $opt->{optionId} eq $decision;
    }

    # 2. Match by ACP kind priority
    my @want_kinds;
    if ($decision eq 'allow' || $decision eq 'allow_once') {
        @want_kinds = qw(allow_once allow_always);
    }
    elsif ($decision eq 'allow_always') {
        @want_kinds = qw(allow_always allow_once);
    }
    elsif ($decision eq 'reject' || $decision eq 'reject_once') {
        @want_kinds = qw(reject_once reject_always);
    }
    elsif ($decision eq 'reject_always') {
        @want_kinds = qw(reject_always reject_once);
    }

    for my $kind (@want_kinds) {
        for my $opt (@$options) {
            next unless ref($opt) eq 'HASH' && defined $opt->{optionId};
            return ($opt->{optionId}, $opt->{kind}) if ($opt->{kind} // '') eq $kind;
        }
    }

    return (undef, undef);
}

sub respond_permission {
    my ($self, $req_id, $decision) = @_;
    my $perm = delete $self->{pending_perms}{$req_id};
    return 0 unless $perm;

    $decision ||= 'reject';
    if ($decision eq 'allow_always' && defined $perm->{tool}) {
        $self->{allow_always_tools}{ $perm->{tool} } = 1;
    }

    my $outcome;
    if ($decision eq 'cancel' || $decision eq 'cancelled') {
        $outcome = { outcome => 'cancelled' };
    }
    else {
        my ($resolved_id, $resolved_kind) = _resolve_permission_option($perm->{options}, $decision);
        if (defined $resolved_id) {
            $outcome = { outcome => 'selected', optionId => $resolved_id };
        }
        elsif ($decision eq 'allow' || $decision eq 'allow_once' || $decision eq 'allow_always') {
            $outcome = { outcome => 'selected', optionId => $decision };
        }
        else {
            $outcome = { outcome => 'cancelled', optionId => 'reject' };
        }
    }

    $self->_send_response($req_id, { outcome => $outcome });
    return 1;
}

sub normalize_session_update {
    my ($self, $params) = @_;
    $params = ref($params) eq 'HASH' ? $params : {};

    my $upd  = (ref($params->{update}) eq 'HASH') ? $params->{update} : $params;
    my $kind = $upd->{sessionUpdate} // $upd->{type} // $upd->{kind} // '';

    my $text;
    if (ref($upd->{content}) eq 'HASH') {
        if (defined $upd->{content}{text}) {
            $text = $upd->{content}{text};
        }
        elsif (ref($upd->{content}{content}) eq 'HASH' && defined $upd->{content}{content}{text}) {
            $text = $upd->{content}{content}{text};
        }
    }
    elsif (ref($upd->{content}) eq 'ARRAY') {
        my @parts = grep { length } map {
            ref($_) eq 'HASH' ? ($_->{text} // '') : (defined $_ ? "$_" : '')
        } @{ $upd->{content} };
        $text = join('', @parts) if @parts;
    }
    elsif (defined $upd->{content}) {
        $text = "$upd->{content}";
    }
    elsif (defined $upd->{text}) {
        $text = "$upd->{text}";
    }
    elsif (defined $params->{text}) {
        $text = "$params->{text}";
    }

    my %norm_upd = %$upd;
    $norm_upd{sessionUpdate} = $kind;
    if (defined $text) {
        $norm_upd{text} = $text;
        if (!ref($norm_upd{content})) {
            $norm_upd{content} = { type => 'text', text => $text };
        }
        elsif (ref($norm_upd{content}) eq 'HASH' && !defined $norm_upd{content}{text}) {
            $norm_upd{content} = {
                %{ $norm_upd{content} },
                type => ($norm_upd{content}{type} // 'text'),
                text => $text,
            };
        }
    }

    return {
        %$params,
        sessionId     => ($params->{sessionId} // $self->{session_id}),
        sessionUpdate => $kind,
        update        => \%norm_upd,
        (defined $text ? (text => $text) : ()),
    };
}

sub _drain_stderr_now {
    my ($self) = @_;
    my $efh = $self->{err_fh} or return;
    while (1) {
        my $chunk = '';
        my $n = sysread($efh, $chunk, 65536);
        if (!defined $n) {
            last if $!{EAGAIN} || $!{EWOULDBLOCK};
            $self->{sel}->remove($efh) if $self->{sel};
            $self->_record_stderr_chunk('', 1);
            last;
        }
        if ($n == 0) {
            $self->{sel}->remove($efh) if $self->{sel};
            $self->_record_stderr_chunk('', 1);
            last;
        }
        $self->_record_stderr_chunk($chunk, 0);
    }
    return;
}

sub _handle_process_eof {
    my ($self) = @_;
    $self->_drain_stderr_now();
    if ($self->{sel} && $self->{out_fh}) {
        eval { $self->{sel}->remove($self->{out_fh}) };
    }
    $self->{running} = 0;
    $self->{_connect_stage} = undef;

    my $stderr_str = $self->last_stderr();
    my $last_line  = @{ $self->{stderr_lines} } ? $self->{stderr_lines}[-1] : '';
    my $err_msg    = length($last_line) ? $last_line : 'ACP process exited unexpectedly';

    if (_is_auth_error($stderr_str)) {
        $self->_set_state('auth_required', $err_msg);
    }
    elsif ($self->{state} eq 'connecting' || $self->{state} eq 'ready') {
        $self->_set_state('error', $err_msg);
        $self->{callbacks}{on_error}->({ code => -32099, message => $err_msg })
            if $self->{callbacks}{on_error};
    }

    # Unblock any pending outgoing requests cleanly
    for my $id (keys %{ $self->{pending} }) {
        my $p = $self->{pending}{$id};
        next if $p->{done};
        $p->{done}  = 1;
        $p->{error} = { code => -32099, message => $err_msg };
        if ($p->{callback}) {
            eval { $p->{callback}->(undef, $p->{error}) };
        }
    }
    return;
}

sub poll {
    my ($self, $timeout_s) = @_;
    return 0 unless $self->{running} && $self->{sel};
    $timeout_s = 0 unless defined $timeout_s;

    my $processed = 0;
    my $eof_hit   = 0;
    my @ready = $self->{sel}->can_read($timeout_s);
    for my $fh (@ready) {
        if ($self->{err_fh} && $fh == $self->{err_fh}) {
            $self->_drain_stderr_now();
            next;
        }
        while (1) {
            my $chunk = '';
            my $n = sysread($fh, $chunk, 65536);
            if (!defined $n) {
                last if $!{EAGAIN} || $!{EWOULDBLOCK};
                $eof_hit = 1;
                last;
            }
            if ($n == 0) {
                $eof_hit = 1;
                last;
            }
            $self->{read_buf} .= $chunk;
        }
    }

    while ((my $nl = index($self->{read_buf}, "\n")) >= 0) {
        my $line = substr($self->{read_buf}, 0, $nl);
        substr($self->{read_buf}, 0, $nl + 1, '');
        $line =~ s/\r$//;
        next unless length $line;
        my $msg = eval { _decode_json($line) };
        next unless ref($msg) eq 'HASH';
        $self->_dispatch_incoming($msg);
        $processed++;
    }

    if ($eof_hit) {
        $self->_handle_process_eof();
    }

    return $processed;
}

sub _dispatch_incoming {
    my ($self, $msg) = @_;
    push @{ $self->{history} }, $msg;
    shift @{ $self->{history} } if @{ $self->{history} } > 200;

    # 1. Response to one of our outgoing requests
    if (!defined $msg->{method} && defined $msg->{id}) {
        my $p = $self->{pending}{ $msg->{id} };
        return unless $p;
        $p->{done}   = 1;
        $p->{result} = $msg->{result};
        $p->{error}  = $msg->{error};

        if ($msg->{error}) {
            if (_is_auth_error($msg->{error})) {
                my $emsg = ref($msg->{error}) eq 'HASH'
                    ? ($msg->{error}{message} // 'Authentication required')
                    : "$msg->{error}";
                $self->_set_state('auth_required', $emsg);
            }
        }
        elsif ($p->{method} eq 'initialize') {
            $self->_process_initialize_result($msg->{result});
        }
        elsif ($p->{method} eq 'session/new') {
            $self->_process_session_result($msg->{result});
            $self->_set_state('ready') if defined $self->{session_id} && !defined $self->{_connect_stage};
        }
        elsif ($p->{method} eq 'session/load') {
            $self->_process_session_result($msg->{result}, $self->{session_id});
            $self->_set_state('ready') if defined $self->{session_id};
        }

        if ($p->{callback}) {
            $p->{callback}->($p->{result}, $p->{error});
        }
        return;
    }

    my $method = $msg->{method} // '';
    my $params = ref($msg->{params}) eq 'HASH' ? $msg->{params} : {};
    my $id     = $msg->{id};

    # 2. Streaming notifications (no id)
    if ($method eq 'session/update') {
        my $norm = $self->normalize_session_update($params);
        my $kind = $norm->{sessionUpdate} // '';
        my $upd  = $norm->{update} || {};

        if ($kind eq 'agent_message_chunk' && defined $norm->{text} && length $norm->{text}) {
            $self->{_turn_response_buf} .= $norm->{text};
        }

        if ($kind eq 'available_commands_update' && ref($upd->{availableCommands}) eq 'ARRAY') {
            $self->{available_commands} = [ @{ $upd->{availableCommands} } ];
        }
        elsif ($kind eq 'current_mode_update' && defined $upd->{currentModeId}) {
            $self->{current_mode} = $upd->{currentModeId};
        }
        elsif ($kind eq 'config_option_update' && ref($upd->{configOptions}) eq 'ARRAY') {
            $self->_extract_models_from_config_options($upd->{configOptions});
        }

        $self->{callbacks}{on_update}->($norm) if $self->{callbacks}{on_update};
        return;
    }

    # 3. Reverse JSON-RPC requests from Antigravity back to Editor
    if (defined $id) {
        if ($method eq 'session/request_permission') {
            $self->_handle_request_permission($id, $params);
            return;
        }
        if ($method eq 'fs/read_text_file') {
            $self->_handle_fs_read($id, $params);
            return;
        }
        if ($method eq 'fs/write_text_file') {
            $self->_handle_fs_write($id, $params);
            return;
        }
        if ($method =~ m{^terminal/}) {
            $self->_handle_terminal($id, $method, $params);
            return;
        }
        $self->_send_response($id, undef, { code => -32601, message => "Unsupported client method: $method" });
    }
    return;
}

sub _handle_request_permission {
    my ($self, $id, $params) = @_;
    my $tool  = $params->{toolCall}{title} // $params->{tool} // 'action';
    my $desc  = $params->{description} // $params->{toolCall}{title} // $params->{toolCall}{kind} // $tool;
    my $entry = {
        id          => $id,
        tool        => $tool,
        title       => $desc,
        description => $desc,
        options     => (ref($params->{options}) eq 'ARRAY' && @{ $params->{options} }) ? $params->{options} : [
            { optionId => 'allow',        name => 'Allow once',   kind => 'allow_once' },
            { optionId => 'allow_always', name => 'Always allow', kind => 'allow_always' },
            { optionId => 'reject',       name => 'Reject',       kind => 'reject_once' },
        ],
        raw => $params,
    };

    if ($self->{auto_approve} || $self->{allow_always_tools}{$tool}) {
        $self->{pending_perms}{$id} = $entry;
        $self->respond_permission($id, 'allow');
        return;
    }

    $self->{pending_perms}{$id} = $entry;
    if ($self->{callbacks}{on_permission}) {
        $self->{callbacks}{on_permission}->($entry);
    }
    return;
}

sub _resolve_editor_buffer {
    my ($self, $path) = @_;
    my $ed = $self->{editor};
    return undef unless $ed;
    if (defined $path && length $path) {
        if ($ed->can('find_buffer_by_path')) {
            my $b = $ed->find_buffer_by_path($path);
            return $b if $b;
        }
        my @bufs = $ed->can('list_buffers') ? $ed->list_buffers
                 : ($ed->can('buffers') && ref($ed->buffers) eq 'ARRAY') ? @{ $ed->buffers }
                 : ();
        for my $b (@bufs) {
            return $b if (eval { $b->path } // '') eq $path;
        }
    }
    return undef;
}

sub _handle_fs_read {
    my ($self, $id, $params) = @_;
    my $path = $params->{path} // '';
    my $buf  = $self->_resolve_editor_buffer($path);

    if ($buf) {
        my $text  = $buf->can('get_text') ? $buf->get_text() : ($buf->can('text') ? $buf->text() : '');
        my $dirty = $buf->can('is_dirty') ? $buf->is_dirty
                  : $buf->can('modified') ? $buf->modified
                  : $buf->can('dirty')    ? $buf->dirty
                  : 0;
        $self->_send_response($id, {
            content => $text,
            source  => 'unsaved_buffer',
            dirty   => $dirty ? _jtrue() : _jfalse(),
        });
        return;
    }

    if (length($path) && -f $path) {
        if (open my $fh, '<:encoding(UTF-8)', $path) {
            local $/;
            my $text = <$fh>;
            close $fh;
            $self->_send_response($id, { content => $text, source => 'disk', dirty => _jfalse() });
            return;
        }
    }

    $self->_send_response($id, undef, { code => -32004, message => "File not found: $path" });
    return;
}

sub _handle_fs_write {
    my ($self, $id, $params) = @_;
    my $path     = $params->{path}    // '';
    my $new_text = $params->{content} // '';
    my $buf      = $self->_resolve_editor_buffer($path);

    if ($self->{post_tidy_hook} && $path =~ /\.(?:pm|pl|t)$/i) {
        my $tidied = eval { $self->{post_tidy_hook}->($new_text, $path) };
        $new_text = $tidied if defined $tidied && length $tidied;
    }

    if ($buf && $buf->can('stage_diff_proposal')) {
        my $staged = $buf->stage_diff_proposal(
            $new_text,
            source => 'antigravity_acp',
            title  => "ACP edit: $path",
        );
        my $hcnt = ref($staged) eq 'HASH'  ? ($staged->{count} // scalar(@{ $staged->{hunks} || [] }))
                 : ref($staged) eq 'ARRAY' ? scalar(@$staged)
                 : 0;
        $self->_send_response($id, {
            staged     => _jtrue(),
            hunk_count => $hcnt,
            path       => $path,
        });
        return;
    }

    if ($buf && $buf->can('set_text')) {
        $buf->set_text($new_text);
        $self->_send_response($id, { staged => _jfalse(), applied => _jtrue(), path => $path });
        return;
    }

    $self->_send_response($id, undef, { code => -32005, message => "No open buffer for fs/write_text_file: $path" });
    return;
}

sub _handle_terminal {
    my ($self, $id, $method, $params) = @_;

    if ($method eq 'terminal/create') {
        my $tid  = 'term-' . (++$self->{term_seq});
        my $cmd  = $params->{command} // '';
        my $args = ref($params->{args}) eq 'ARRAY' ? $params->{args} : [];
        my $cwd  = $params->{cwd} // $self->{cwd};

        my ($output, $exit_code) = ('', 0);
        if (length $cmd) {
            my ($in, $out);
            my $err_fh = gensym();
            my $pid = eval { open3($in, $out, $err_fh, $cmd, @$args) };
            if ($pid) {
                close $in if $in;
                local $/;
                my $so = <$out>    // '';
                my $se = <$err_fh> // '';
                close $out if $out;
                close $err_fh;
                waitpid($pid, 0);
                $exit_code = $? >> 8;
                $output    = $so . $se;
            }
            else {
                $exit_code = 127;
                $output    = "Failed to run $cmd: $@";
            }
        }

        $self->{terminals}{$tid} = {
            id        => $tid,
            command   => $cmd,
            cwd       => $cwd,
            output    => $output,
            exit_code => $exit_code,
            exited    => 1,
        };
        $self->_send_response($id, { terminalId => $tid });
        return;
    }

    my $tid = $params->{terminalId} // '';
    my $t   = $self->{terminals}{$tid};
    if (!$t) {
        $self->_send_response($id, undef, { code => -32004, message => "Unknown terminalId: $tid" });
        return;
    }

    if ($method eq 'terminal/output') {
        $self->_send_response($id, {
            output     => $t->{output},
            truncated  => _jfalse(),
            exitStatus => { exitCode => $t->{exit_code} },
        });
        return;
    }
    if ($method eq 'terminal/wait_for_exit') {
        $self->_send_response($id, { exitCode => $t->{exit_code} });
        return;
    }
    if ($method eq 'terminal/release' || $method eq 'terminal/kill') {
        delete $self->{terminals}{$tid};
        $self->_send_response($id, { released => _jtrue() });
        return;
    }

    $self->_send_response($id, undef, { code => -32601, message => "Unknown terminal method: $method" });
    return;
}

sub stop {
    my ($self) = @_;
    $self->{running}            = 0;
    $self->{_connect_stage}     = undef;
    $self->{_turn_response_buf} = '';
    $self->{initialized}        = 0;
    $self->{session_id}         = undef;
    for my $k (qw(in_fh out_fh err_fh)) {
        if ($self->{$k}) {
            eval { close $self->{$k} };
            $self->{$k} = undef;
        }
    }
    $self->{sel} = undef;
    if (defined $self->{pid}) {
        my $pid = delete $self->{pid};
        eval {
            kill('TERM', $pid);
            my $w = waitpid($pid, POSIX::WNOHANG());
            if (!$w) {
                sleep(0.05);
                $w = waitpid($pid, POSIX::WNOHANG());
                if (!$w) {
                    kill('KILL', $pid);
                    waitpid($pid, 0);
                }
            }
        };
    }
    $self->_set_state('offline');
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    local ($@, $!, $?);
    if (!(${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT')) {
        eval { $self->stop() };
        return;
    }
    return unless ref($self) && defined $self->{pid} && $self->{pid} > 0;
    my $pid = delete $self->{pid};
    eval {
        kill('TERM', $pid);
        my $w = waitpid($pid, POSIX::WNOHANG());
        for (1 .. 10) {
            last if $w == $pid || $w < 0;
            sleep(0.05);
            $w = waitpid($pid, POSIX::WNOHANG());
        }
        if (!$w) {
            kill('KILL', $pid);
            waitpid($pid, 0);
        }
    };
    return;
}

# =============================================================================
# Built-in Protocol-Identical ACP Loopback Server (runs over real STDIN/STDOUT)
# =============================================================================

sub _extract_mcp_triggers {
    my ($text) = @_;
    return () unless defined $text && index($text, '[mcp:') >= 0;

    my @triggers;
    my $len = length($text);
    my $pos = 0;

    while ((my $start = index($text, '[mcp:', $pos)) >= 0) {
        my $i = $start + 5;
        my $name_start = $i;
        while ($i < $len && substr($text, $i, 1) =~ /[A-Za-z0-9_.-]/) {
            $i++;
        }
        my $tool = substr($text, $name_start, $i - $name_start);
        if (!length $tool || $i >= $len) {
            $pos = $start + 5;
            next;
        }

        my $ch = substr($text, $i, 1);
        if ($ch eq ']') {
            push @triggers, { tool => $tool, args => {} };
            $pos = $i + 1;
            next;
        }
        if ($ch ne ':') {
            $pos = $i;
            next;
        }

        # Parse JSON arguments up to matching closing ']' at depth 0 (quote/escape aware)
        $i++;    # skip ':'
        my $args_start = $i;
        my $depth      = 0;
        my $in_str     = 0;
        my $esc        = 0;
        my $end_idx    = -1;

        while ($i < $len) {
            my $c = substr($text, $i, 1);
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
                elsif ($c eq '{' || $c eq '[') {
                    $depth++;
                }
                elsif ($c eq '}') {
                    $depth-- if $depth > 0;
                }
                elsif ($c eq ']') {
                    if ($depth == 0) {
                        $end_idx = $i;
                        last;
                    }
                    $depth--;
                }
            }
            $i++;
        }

        last if $end_idx < 0;
        my $raw_args = substr($text, $args_start, $end_idx - $args_start);
        my $decoded  = {};
        if (length $raw_args) {
            my $raw_bytes = $raw_args;
            utf8::encode($raw_bytes) if utf8::is_utf8($raw_bytes);
            $decoded = eval { _decode_json($raw_bytes) };
        }
        push @triggers, {
            tool => $tool,
            args => (ref($decoded) eq 'HASH' ? $decoded : {}),
        };
        $pos = $end_idx + 1;
    }

    return @triggers;
}

sub _loopback_http_mcp_call {
    my ($port, $req_id, $tool_name, $tool_args) = @_;
    require IO::Socket::INET;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    );
    return {
        ok    => 0,
        tool  => $tool_name,
        error => "TCP connect to 127.0.0.1:$port failed: $!",
    } unless $sock;

    $sock->timeout(180);
    binmode($sock, ':raw');

    my $payload = _encode_json({
        jsonrpc => '2.0',
        id      => $req_id,
        method  => 'tools/call',
        params  => {
            name      => $tool_name,
            arguments => (ref($tool_args) eq 'HASH' ? $tool_args : {}),
        },
    });
    my $byte_len = do { use bytes; length($payload) };
    my $http_req = join("\r\n",
        'POST /mcp HTTP/1.1',
        "Host: 127.0.0.1:$port",
        'Content-Type: application/json',
        'Accept: application/json, text/event-stream',
        "Content-Length: $byte_len",
        'Connection: close',
        '',
        '',
    ) . $payload;

    print {$sock} $http_req;
    $sock->flush();

    my $raw = '';
    while (1) {
        my $chunk = '';
        my $n = sysread($sock, $chunk, 65536);
        last if !defined($n) || $n == 0;
        $raw .= $chunk;
    }
    close $sock;

    my ($hdr, $body) = split /\r\n\r\n/, $raw, 2;
    $hdr  //= '';
    $body //= '';
    my ($status) = ($hdr =~ m{\AHTTP/\S+\s+(\d+)});
    $status = int($status || 0);

    if ($hdr =~ /^Transfer-Encoding:\s*chunked/mi) {
        my $decoded_body = '';
        my $p = 0;
        while ($p < length($body)) {
            my $crlf = index($body, "\r\n", $p);
            last if $crlf < 0;
            my $hex = substr($body, $p, $crlf - $p);
            $hex =~ s/;.*$//;
            my $clen = hex($hex);
            last if $clen == 0;
            $decoded_body .= substr($body, $crlf + 2, $clen);
            $p = $crlf + 2 + $clen + 2;
        }
        $body = $decoded_body;
    }

    my $rpc = eval { _decode_json($body) };
    if ($status >= 200 && $status < 300 && ref($rpc) eq 'HASH') {
        if ($rpc->{error}) {
            return {
                ok     => 0,
                tool   => $tool_name,
                status => $status,
                error  => $rpc->{error},
            };
        }
        my $r = ref($rpc->{result}) eq 'HASH' ? $rpc->{result} : {};
        my $data = $r->{structuredContent};
        if (!defined $data && ref($r->{content}) eq 'ARRAY'
            && ref($r->{content}[0]) eq 'HASH' && defined $r->{content}[0]{text})
        {
            $data = eval { _decode_json($r->{content}[0]{text}) } // $r->{content}[0]{text};
        }
        return {
            ok     => $r->{isError} ? 0 : 1,
            tool   => $tool_name,
            status => $status,
            result => $data,
        };
    }

    return {
        ok     => 0,
        tool   => $tool_name,
        status => $status,
        error  => "HTTP $status from EditorMCP",
        body   => substr($body, 0, 240),
    };
}

sub run_loopback_server {
    my (@argv) = @_;
    STDOUT->autoflush(1);
    binmode(STDIN,  ':utf8');
    binmode(STDOUT, ':utf8');

    my $mcp_port = 0;
    my @add_dirs;
    my $sandbox  = 0;
    for (my $i = 0; $i < @argv; $i++) {
        if ($argv[$i] eq '--ide-mcp-port' && defined $argv[$i + 1]) {
            $mcp_port = int($argv[$i + 1]);
            $i++;
        }
        elsif ($argv[$i] eq '--add-dir' && defined $argv[$i + 1]) {
            push @add_dirs, $argv[$i + 1];
            $i++;
        }
        elsif ($argv[$i] eq '--sandbox') {
            $sandbox = 1;
        }
    }

    my $rev_id        = 1000;
    my $mcp_req_seq   = 1;
    my $session_seq   = 0;
    my $current_model = 'antigravity-loopback-1';
    my @avail_models  = (
        { modelId => 'antigravity-loopback-1', name => 'Antigravity Loopback', description => 'Offline deterministic ACP loopback' },
        { modelId => 'gemini-2.5-pro',         name => 'Gemini 2.5 Pro (Mock)', description => 'Mock model selector entry' },
    );

    my $send = sub {
        my ($obj) = @_;
        print STDOUT _encode_json($obj) . "\n";
    };

    my $call_client = sub {
        my ($method, $params) = @_;
        my $rid = $rev_id++;
        $send->({
            jsonrpc => '2.0',
            id      => $rid,
            method  => $method,
            params  => $params || {},
        });
        while (defined(my $line = <STDIN>)) {
            $line =~ s/[\r\n]+$//;
            next unless length $line;
            my $m = eval { _decode_json($line) };
            next unless ref($m) eq 'HASH';
            if (defined $m->{id} && $m->{id} == $rid) {
                return ($m->{result}, $m->{error});
            }
            if (($m->{method} // '') eq 'session/cancel') {
                return (undef, { code => -32800, message => 'cancelled' });
            }
        }
        return (undef, { code => -32099, message => 'EOF waiting for client response' });
    };

    while (defined(my $line = <STDIN>)) {
        $line =~ s/[\r\n]+$//;
        next unless length $line;
        my $req = eval { _decode_json($line) };
        next unless ref($req) eq 'HASH';

        my $method = $req->{method} // '';
        my $id     = $req->{id};
        my $params = ref($req->{params}) eq 'HASH' ? $req->{params} : {};

        if ($method eq 'initialize') {
            $send->({
                jsonrpc => '2.0',
                id      => $id,
                result  => {
                    protocolVersion   => 1,
                    agentInfo         => {
                        name    => 'antigravity-acp-loopback',
                        version => $VERSION,
                        mcpPort => $mcp_port,
                        sandbox => $sandbox ? _jtrue() : _jfalse(),
                        addDirs => \@add_dirs,
                    },
                    agentCapabilities => {
                        loadSession => _jtrue(),
                        streaming   => _jtrue(),
                        fs          => _jtrue(),
                        terminal    => _jtrue(),
                        permissions => _jtrue(),
                    },
                    authMethods       => [],
                },
            });
            next;
        }

        if ($method eq 'authenticate') {
            $send->({
                jsonrpc => '2.0',
                id      => $id,
                result  => { authenticated => _jtrue() },
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
            my $sid = 'agy-sess-' . (++$session_seq);
            $send->({
                jsonrpc => '2.0',
                id      => $id,
                result  => {
                    sessionId => $sid,
                    models    => {
                        currentModelId  => $current_model,
                        availableModels => \@avail_models,
                    },
                },
            });
            next;
        }

        if ($method eq 'session/load') {
            my $sid = $params->{sessionId} // ('agy-sess-' . (++$session_seq));
            $send->({
                jsonrpc => '2.0',
                id      => $id,
                result  => {
                    sessionId => $sid,
                    models    => {
                        currentModelId  => $current_model,
                        availableModels => \@avail_models,
                    },
                },
            });
            next;
        }

        if ($method eq 'session/set_model') {
            $current_model = $params->{modelId} if defined $params->{modelId} && length $params->{modelId};
            $send->({
                jsonrpc => '2.0',
                id      => $id,
                result  => { currentModelId => $current_model },
            });
            next;
        }

        if ($method eq 'session/set_config_option') {
            if (($params->{configId} // '') eq 'model' && defined $params->{value}) {
                $current_model = $params->{value};
            }
            $send->({
                jsonrpc => '2.0',
                id      => $id,
                result  => { configOptions => [] },
            });
            next;
        }

        if ($method eq 'session/cancel') {
            next;
        }

        if ($method eq 'session/prompt') {
            my $sid = $params->{sessionId} // 'agy-sess-1';
            my $prompt_text = '';
            if (ref($params->{prompt}) eq 'ARRAY') {
                $prompt_text = join("\n", map { $_->{text} // '' } @{ $params->{prompt} });
            }

            # Stream thought chunk
            $send->({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'agent_thought_chunk',
                        content       => { type => 'text', text => "Analyzing request against live editor state." },
                    },
                },
            });

            # Stream plan checklist
            $send->({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'plan',
                        entries       => [
                            { content => 'Inspect live editor context', status => 'completed', priority => 'high' },
                            { content => 'Prepare proposed change or response', status => 'in_progress', priority => 'medium' },
                        ],
                    },
                },
            });

            my $read_content;
            my $perm_outcome = 'not_needed';
            my $write_result;
            my $term_output;
            my @mcp_results;

            # Reverse HTTP MCP tool_call trigger: [mcp:<tool_name>] or [mcp:<tool_name>:<json_args>]
            if ($mcp_port > 0 && index($prompt_text, '[mcp:') >= 0) {
                my @triggers = _extract_mcp_triggers($prompt_text);
                for my $trig (@triggers) {
                    my $tc_id = 'tc-mcp-' . $mcp_req_seq;
                    $send->({
                        jsonrpc => '2.0',
                        method  => 'session/update',
                        params  => {
                            sessionId => $sid,
                            update    => {
                                sessionUpdate => 'tool_call',
                                toolCallId    => $tc_id,
                                title         => $trig->{tool},
                                status        => 'in_progress',
                            },
                        },
                    });
                    my $mres = _loopback_http_mcp_call(
                        $mcp_port,
                        $mcp_req_seq++,
                        $trig->{tool},
                        $trig->{args},
                    );
                    push @mcp_results, $mres;
                    $send->({
                        jsonrpc => '2.0',
                        method  => 'session/update',
                        params  => {
                            sessionId => $sid,
                            update    => {
                                sessionUpdate => 'tool_call_update',
                                toolCallId    => $tc_id,
                                status        => $mres->{ok} ? 'completed' : 'failed',
                            },
                        },
                    });
                }
            }

            # Reverse fs/read_text_file trigger: [read:path/to/file]
            if ($prompt_text =~ /\[read:([^\]]+)\]/) {
                my $target = $1;
                $send->({
                    jsonrpc => '2.0',
                    method  => 'session/update',
                    params  => {
                        sessionId => $sid,
                        update    => {
                            sessionUpdate => 'tool_call',
                            toolCallId    => 'tc-read-1',
                            title         => "fs/read_text_file $target",
                            status        => 'in_progress',
                        },
                    },
                });
                my ($res, $err) = $call_client->('fs/read_text_file', { path => $target });
                if ($res && defined $res->{content}) {
                    $read_content = $res->{content};
                }
                $send->({
                    jsonrpc => '2.0',
                    method  => 'session/update',
                    params  => {
                        sessionId => $sid,
                        update    => {
                            sessionUpdate => 'tool_call_update',
                            toolCallId    => 'tc-read-1',
                            status        => $err ? 'failed' : 'completed',
                        },
                    },
                });
            }

            # Reverse permission + fs/write_text_file trigger: [edit:path/to/file]
            if ($prompt_text =~ /\[edit:([^\]]+)\]/) {
                my $target = $1;
                my ($pres, $perr) = $call_client->('session/request_permission', {
                    sessionId   => $sid,
                    toolCall    => { toolCallId => 'tc-write-1', title => 'fs/write_text_file', kind => 'edit' },
                    description => "Stage inline diff edit to $target",
                    options     => [
                        { optionId => 'allow',        name => 'Allow once',   kind => 'allow_once' },
                        { optionId => 'allow_always', name => 'Always allow', kind => 'allow_always' },
                        { optionId => 'reject',       name => 'Reject',       kind => 'reject_once' },
                    ],
                });
                my $opt_id = ($pres && ref($pres->{outcome}) eq 'HASH')
                    ? ($pres->{outcome}{optionId} // 'reject')
                    : 'reject';
                $perm_outcome = $opt_id;

                if ($opt_id eq 'allow' || $opt_id eq 'allow_always') {
                    my $base = defined($read_content) ? $read_content : "package Demo;\n1;\n";
                    my $updated = $base;
                    $updated .= "\n# Antigravity proposed improvement\n"
                        unless $updated =~ /Antigravity proposed improvement/;
                    ($write_result) = $call_client->('fs/write_text_file', {
                        path    => $target,
                        content => $updated,
                    });
                }
            }

            # Reverse terminal/* trigger: [term:cmd arg1 ...]
            if ($prompt_text =~ /\[term:([^\]]+)\]/) {
                my @parts = split /\s+/, $1;
                my $tcmd  = shift @parts;
                my ($cres) = $call_client->('terminal/create', { command => $tcmd, args => \@parts });
                if ($cres && $cres->{terminalId}) {
                    my $tid = $cres->{terminalId};
                    $call_client->('terminal/wait_for_exit', { terminalId => $tid });
                    my ($ores) = $call_client->('terminal/output', { terminalId => $tid });
                    $term_output = $ores->{output} if $ores;
                    $call_client->('terminal/release', { terminalId => $tid });
                }
            }

            my $reply_text = "Completed ACP turn.";
            $reply_text .= " Read live buffer (" . length($read_content) . " bytes)." if defined $read_content;
            $reply_text .= " Permission: $perm_outcome." if $perm_outcome ne 'not_needed';
            $reply_text .= " Terminal output: $term_output" if defined $term_output;
            if (@mcp_results) {
                my @parts;
                for my $mr (@mcp_results) {
                    my $val = $mr->{ok}
                        ? (ref($mr->{result}) ? _encode_json($mr->{result}) : ($mr->{result} // 'ok'))
                        : ('error: ' . (ref($mr->{error}) ? _encode_json($mr->{error}) : ($mr->{error} // 'failed')));
                    utf8::decode($val);
                    push @parts, "$mr->{tool}=" . substr($val, 0, 200);
                }
                $reply_text .= " MCP: " . join('; ', @parts) . ".";
            }

            # Stream message chunk
            $send->({
                jsonrpc => '2.0',
                method  => 'session/update',
                params  => {
                    sessionId => $sid,
                    update    => {
                        sessionUpdate => 'agent_message_chunk',
                        content       => { type => 'text', text => $reply_text },
                    },
                },
            });

            $send->({
                jsonrpc => '2.0',
                id      => $id,
                result  => {
                    stopReason  => 'end_turn',
                    sessionId   => $sid,
                    finalText   => $reply_text,
                    readContent => $read_content,
                    permission  => $perm_outcome,
                    writeResult => $write_result,
                    termOutput  => $term_output,
                    (@mcp_results ? (mcpResults => \@mcp_results) : ()),
                },
            });
            next;
        }

        if (defined $id) {
            $send->({
                jsonrpc => '2.0',
                id      => $id,
                error   => { code => -32601, message => "Unknown ACP method: $method" },
            });
        }
    }
    return 0;
}

1;

__END__

=head1 NAME

NeoPerl::Antigravity::ACP - Antigravity ACP 1.0 JSON-RPC 2.0 client and loopback server

=head1 SYNOPSIS

    use NeoPerl::Antigravity::ACP;

    my $acp = NeoPerl::Antigravity::ACP->new(
        editor     => $editor,
        editor_mcp => $mcp,
        cwd        => '.',
    );
    $acp->connect_async();
    $acp->poll(0.05) while $acp->state eq 'connecting';

=head1 DESCRIPTION

C<NeoPerl::Antigravity::ACP> discovers the official C<agy> CLI across
C<$ENV{NEOPERL_AGY_BIN}>, C<PATH>, and standard install locations
(C<~/.local/bin/agy>, C</opt/homebrew/bin/agy>, C</usr/local/bin/agy>,
C<~/.antigravity/bin/agy>, C<~/.npm-global/bin/agy>, and the macOS Antigravity
app bundle) and speaks the documented Antigravity Agent Client Protocol 1.0
(JSON-RPC 2.0 NDJSON over stdio via C<agy acp --process-per-session
--ide-mcp-port E<lt>portE<gt> --add-dir E<lt>cwdE<gt>>).

It provides a non-blocking connection state machine (C<offline>, C<connecting>,
C<auth_required>, C<ready>, C<error>), non-blocking C<stderr> draining,
C<authenticate>, C<session/new> with spec-compliant C<type =E<gt> 'http'>
C<mcpServers>, C<session/load>, C<session/set_model>, C<session/prompt>,
C<session/cancel>, normalized nested and flat C<session/update> streams,
dynamic C<optionId> permission matching, C<doctor()> diagnostics, reverse
client handlers for C<fs/*> and C<terminal/*>, and a protocol-identical
loopback server over real OS pipes for offline testing.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
