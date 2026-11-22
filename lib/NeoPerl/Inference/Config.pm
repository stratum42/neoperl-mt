package NeoPerl::Inference::Config;

use strict;
use warnings;
use Carp qw(croak);
use Config ();
use File::Spec ();

our $VERSION = '0.01';

our @ROLES      = qw(embedder memory_writer vision_doc worker_small);
our @TRANSPORTS = qw(inproc_libllama managed_server remote_http loopback);

my %VALID_ROLE      = map { $_ => 1 } @ROLES;
my %VALID_TRANSPORT = map { $_ => 1 } @TRANSPORTS;

sub _default_model_dir {
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '.';
    return $ENV{NEOPERL_MODEL_DIR}
        || File::Spec->catdir($home, '.cache', 'neoperl', 'models');
}

sub resolve_binary {
    my $bin = (@_ >= 2 && (ref($_[0]) || (defined($_[0]) && $_[0] eq __PACKAGE__)))
        ? $_[1]
        : $_[0];
    return undef unless defined $bin && length $bin;

    if ($bin =~ m{[/\\]}) {
        return $bin       if -x $bin && !-d $bin;
        return "$bin.exe" if $^O eq 'MSWin32' && -x "$bin.exe" && !-d "$bin.exe";
        return undef;
    }

    my $sep  = ($^O eq 'MSWin32') ? ';' : ':';
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    my @dirs = grep { defined $_ && length $_ } split /\Q$sep\E/, ($ENV{PATH} // '');
    push @dirs, File::Spec->catdir($home, '.local', 'bin') if length $home;
    push @dirs, '/opt/homebrew/bin', '/usr/local/bin' unless $^O eq 'MSWin32';

    my %seen;
    for my $dir (@dirs) {
        next if $seen{$dir}++;
        my $cand = File::Spec->catfile($dir, $bin);
        return $cand if -x $cand && !-d $cand;
        if ($^O eq 'MSWin32' && -x "$cand.exe" && !-d "$cand.exe") {
            return "$cand.exe";
        }
    }
    return undef;
}

sub _is_valid_gguf {
    my ($path) = @_;
    return 0 unless defined $path && length $path && -f $path && (-s $path) >= 4;
    open my $fh, '<:raw', $path or return 0;
    my $magic = '';
    my $n = read($fh, $magic, 4);
    close $fh;
    return (defined $n && $n == 4 && $magic eq 'GGUF') ? 1 : 0;
}

sub _is_q2_0_model {
    my ($path) = @_;
    return (defined $path && $path =~ /(?<![A-Za-z])Q2_0(?![A-Za-z0-9])/i) ? 1 : 0;
}

sub _llama_bridge_available {
    return eval { require NeoPerl::Core; 1 }
        && defined(&NeoPerl::Core::LlamaBridge::available)
        && NeoPerl::Core::LlamaBridge::available()
        ? 1 : 0;
}

sub _detect_host_arch {
    if (eval { require NeoPerl::Core; 1 } && defined(&NeoPerl::Core::arch_info)) {
        my $ai = eval { NeoPerl::Core::arch_info() };
        if (ref($ai) eq 'HASH' && defined($ai->{arch}) && length($ai->{arch})) {
            return $ai->{arch};
        }
    }
    return $Config::Config{archname} // '';
}

sub is_power_arch {
    my @args = @_;
    my ($explicit_arch, $explicit_os);

    if (@args) {
        if (ref($args[0]) && eval { $args[0]->isa(__PACKAGE__) }) {
            my $self = shift @args;
            $explicit_arch = $self->{arch} if defined $self->{arch} && length $self->{arch};
            $explicit_os   = $self->{os}   if defined $self->{os}   && length $self->{os};
        }
        elsif (defined $args[0] && $args[0] eq __PACKAGE__) {
            shift @args;
        }
    }

    if (@args == 1 && !ref($args[0])) {
        $explicit_arch = $args[0];
    }
    elsif (@args == 1 && ref($args[0]) eq 'HASH') {
        $explicit_arch = $args[0]{arch} if defined $args[0]{arch};
        $explicit_os   = $args[0]{os}   if defined $args[0]{os};
    }
    elsif (@args >= 2 && @args % 2 == 0) {
        my %opts = @args;
        $explicit_arch = $opts{arch} if defined $opts{arch};
        $explicit_os   = $opts{os}   if defined $opts{os};
    }

    if (defined $explicit_arch || defined $explicit_os) {
        return 1 if defined($explicit_os)   && lc($explicit_os) eq 'aix';
        return 1 if defined($explicit_arch) && $explicit_arch =~ /(?:power|ppc|aix)/i;
        return 0;
    }

    return 1 if $^O eq 'aix';
    return 1 if ($Config::Config{archname} // '') =~ /(?:power|ppc)/i;
    if (eval { require NeoPerl::Core; 1 } && defined(&NeoPerl::Core::arch_info)) {
        my $ai = eval { NeoPerl::Core::arch_info() };
        return 1 if ref($ai) eq 'HASH' && ($ai->{arch} // '') =~ /(?:ppc|power)/i;
    }
    return 0;
}

sub _detect_cuda {
    return 1 if $^O eq 'linux' && -e '/dev/nvidia0';
    my $smi = resolve_binary('nvidia-smi');
    return 0 unless defined $smi;
    my $pid = fork();
    return 0 unless defined $pid;
    if ($pid == 0) {
        open STDIN,  '<', File::Spec->devnull();
        open STDOUT, '>', File::Spec->devnull();
        open STDERR, '>', File::Spec->devnull();
        { no warnings 'exec'; exec { $smi } ($smi, '-L'); }
        exit 127;
    }
    waitpid($pid, 0);
    return ($? == 0) ? 1 : 0;
}

sub _detect_discrete_rocm {
    return 0 unless $^O eq 'linux' && -e '/dev/kfd';
    my $nodes_dir = '/sys/class/kfd/kfd/topology/nodes';
    return 0 unless -d $nodes_dir;
    opendir(my $dh, $nodes_dir) or return 0;
    my @entries = grep { /^\d+$/ } readdir($dh);
    closedir $dh;

    for my $e (@entries) {
        my $ndir  = File::Spec->catdir($nodes_dir, $e);
        my $pfile = File::Spec->catfile($ndir, 'properties');
        next unless -f $pfile;
        open my $fh, '<', $pfile or next;
        my ($simd_count, $cpu_cores) = (0, 0);
        while (my $line = <$fh>) {
            $simd_count = int($1) if $line =~ /^simd_count\s+(\d+)/;
            $cpu_cores  = int($1) if $line =~ /^cpu_cores_count\s+(\d+)/;
        }
        close $fh;
        next unless $simd_count > 0 && $cpu_cores == 0;

        # Distinguish discrete ROCm VRAM GPUs from small integrated APUs
        my $banks_dir = File::Spec->catdir($ndir, 'mem_banks');
        if (-d $banks_dir && opendir(my $bdh, $banks_dir)) {
            my @banks = grep { /^\d+$/ } readdir($bdh);
            closedir $bdh;
            my $has_discrete_vram = 0;
            for my $b (@banks) {
                my $bp = File::Spec->catfile($banks_dir, $b, 'properties');
                next unless -f $bp;
                open my $bfh, '<', $bp or next;
                my ($htype, $bytes) = (0, 0);
                while (my $bl = <$bfh>) {
                    $htype = int($1) if $bl =~ /^heap_type\s+(\d+)/;
                    $bytes = $1 + 0  if $bl =~ /^size_in_bytes\s+(\d+)/;
                }
                close $bfh;
                # heap_type 1 = HSA_HEAPTYPE_FRAME_BUFFER_PUBLIC (discrete VRAM)
                if ($htype == 1 && $bytes >= 4_294_967_296) {
                    $has_discrete_vram = 1;
                    last;
                }
            }
            return 1 if $has_discrete_vram;
        }
        elsif ($simd_count >= 32) {
            return 1;
        }
    }
    return 0;
}

sub detect_local_accelerator {
    my @args = @_;
    my %opts;

    if (@args) {
        if (ref($args[0]) && eval { $args[0]->isa(__PACKAGE__) }) {
            my $self = shift @args;
            $opts{os}          = $self->{os}          if defined $self->{os};
            $opts{arch}        = $self->{arch}        if defined $self->{arch};
            $opts{accelerator} = $self->{accelerator_override} if defined $self->{accelerator_override};
        }
        elsif (defined $args[0] && $args[0] eq __PACKAGE__) {
            shift @args;
        }
    }
    if (@args == 1 && ref($args[0]) eq 'HASH') {
        %opts = (%opts, %{ $args[0] });
    }
    elsif (@args >= 2 && @args % 2 == 0) {
        %opts = (%opts, @args);
    }

    my $os   = defined($opts{os})   && length($opts{os})   ? lc($opts{os}) : lc($^O);
    my $arch = defined($opts{arch}) && length($opts{arch}) ? $opts{arch}   : _detect_host_arch();

    my $power_reason = 'POWER/AIX host; use remote_http or NEOPERL_*_URL';
    my $cpu_reason   = 'no supported discrete GPU / Apple Silicon Metal accelerator detected; use remote_http / NEOPERL_*_URL or set NEOPERL_ALLOW_CPU_LOCAL_AI=1';

    if (defined $opts{accelerator} && length $opts{accelerator}) {
        my $acc = lc($opts{accelerator});
        if ($acc eq 'none') {
            my $reason = ($os eq 'aix' || $arch =~ /(?:power|ppc)/i) ? $power_reason : $cpu_reason;
            return wantarray ? ('none', $reason) : 'none';
        }
        return wantarray ? ($acc, '') : $acc;
    }

    # 1. POWER / AIX hosts: skip local GGUF inference by default
    if ($os eq 'aix' || $arch =~ /(?:power|ppc)/i) {
        return wantarray ? ('none', $power_reason) : 'none';
    }

    # 2. macOS Apple Silicon (unified memory Metal GPU)
    if ($os eq 'darwin') {
        if ($arch =~ /(?:arm64|aarch64)/i) {
            return wantarray ? ('metal', '') : 'metal';
        }
        return wantarray ? ('none', $cpu_reason) : 'none';
    }

    # 3. Linux / Windows: probe live host discrete GPU only when matching host OS
    if ($os eq lc($^O)) {
        return wantarray ? ('cuda', '') : 'cuda' if _detect_cuda();
        return wantarray ? ('rocm', '') : 'rocm' if $os eq 'linux' && _detect_discrete_rocm();
    }

    return wantarray ? ('none', $cpu_reason) : 'none';
}

sub default_roles {
    my ($model_dir) = @_;
    $model_dir = _default_model_dir() unless defined $model_dir && length $model_dir;
    my $up_bin     = $ENV{NEOPERL_LLAMA_SERVER}       || 'llama-server';
    my $prism_bin  = $ENV{NEOPERL_PRISM_LLAMA_SERVER} || 'prism-llama-server';

    return {
        embedder => {
            role              => 'embedder',
            display_name      => 'Embedder (768d)',
            model_id          => 'nomic-ai/nomic-embed-text-v1.5-GGUF',
            recommended_quant => 'Q8_0',
            model_path        => $ENV{NEOPERL_EMBED_MODEL} || File::Spec->catfile($model_dir, 'nomic-embed-text-v1.5.Q8_0.gguf'),
            dim               => 768,
            estimated_ram_gb  => 0.4,
            backend_fork      => 'upstream',
            server_bin        => $up_bin,
            transport         => 'loopback',
            pinned            => 1,
            ngl               => 99,
            ctx_size          => 2048,
            extra_args        => [ '--embedding', '--pooling', 'mean' ],
            remote_url        => $ENV{NEOPERL_EMBED_URL} || '',
            api_key           => '',
            defaults          => {},
        },
        memory_writer => {
            role              => 'memory_writer',
            display_name      => 'Hy-Memory-30B-A3B',
            model_id          => 'tencent/Hy-Memory-30B-A3B-GGUF',
            recommended_quant => 'Q8_0-expsIQ2_XXS',
            alt_quants        => [ 'Q4_K_M' ],
            model_path        => $ENV{NEOPERL_HYMEM_MODEL} || File::Spec->catfile($model_dir, 'Hy-Memory-30B-A3B-Q8_0-expsIQ2_XXS.gguf'),
            estimated_ram_gb  => 9.1,
            backend_fork      => 'upstream',
            server_bin        => $up_bin,
            transport         => 'loopback',
            pinned            => 0,
            ngl               => 99,
            ctx_size          => 8192,
            kv_cache_k        => 'q8_0',
            kv_cache_v        => 'q8_0',
            extra_args        => [
                '--flash-attn', 'on',
                '--parallel', '1',
                '--jinja',
                '--chat-template-kwargs', '{"reasoning_effort":"no_think"}',
                '--temp', '0.0',
            ],
            remote_url        => $ENV{NEOPERL_HYMEM_URL} || '',
            api_key           => '',
            defaults          => {
                temperature      => 0.0,
                reasoning_effort => 'no_think',
            },
        },
        vision_doc => {
            role              => 'vision_doc',
            display_name      => 'Granite-Vision-4.1-4B',
            model_id          => 'ibm-granite/granite-vision-4.1-4b-GGUF',
            recommended_quant => 'Q4_K_M',
            model_path        => $ENV{NEOPERL_VISION_MODEL} || File::Spec->catfile($model_dir, 'granite-vision-4.1-4b-Q4_K_M.gguf'),
            mmproj_path       => $ENV{NEOPERL_VISION_MMPROJ} || File::Spec->catfile($model_dir, 'mmproj-model-f16.gguf'),
            min_llama_build   => 9704,
            estimated_ram_gb  => 3.5,
            backend_fork      => 'upstream',
            server_bin        => $up_bin,
            transport         => 'loopback',
            pinned            => 0,
            ngl               => 99,
            ctx_size          => 8192,
            extra_args        => [ '--jinja', '--parallel', '1', '--temp', '0.0' ],
            remote_url        => $ENV{NEOPERL_VISION_URL} || '',
            api_key           => '',
            defaults          => {
                temperature => 0.0,
            },
        },
        worker_small => {
            role              => 'worker_small',
            display_name      => 'Ternary-Bonsai-2-27B',
            model_id          => 'prism-ml/Ternary-Bonsai-2-27B-gguf',
            recommended_quant => 'PTQ1_0',
            alt_quants        => [ 'PQ2_0', 'Q2_0' ],
            model_path        => $ENV{NEOPERL_BONSAI_MODEL} || File::Spec->catfile($model_dir, 'Ternary-Bonsai-2-27B-PTQ1_0.gguf'),
            estimated_ram_gb  => 6.0,
            backend_fork      => 'prism-ml',
            server_bin        => $prism_bin,
            transport         => 'loopback',
            pinned            => 0,
            ngl               => 99,
            ctx_size          => 8192,
            extra_args        => [ '--jinja', '--parallel', '1' ],
            remote_url        => $ENV{NEOPERL_BONSAI_URL} || '',
            api_key           => '',
            defaults          => {
                temperature => 0.1,
            },
        },
    };
}

sub new {
    my ($class, %args) = @_;
    my $model_dir = defined($args{model_dir}) && length($args{model_dir})
        ? $args{model_dir}
        : _default_model_dir();
    my $roles = default_roles($model_dir);

    my $want_auto = ($args{auto_discover} && !$ENV{NEOPERL_INFERENCE_MOCK}) ? 1 : 0;

    my ($accel, $detect_skip_reason) = detect_local_accelerator(
        (defined $args{os}          ? (os          => $args{os})          : ()),
        (defined $args{arch}        ? (arch        => $args{arch})        : ()),
        (defined $args{accelerator} ? (accelerator => $args{accelerator}) : ()),
    );
    my $allow_local_override = (
        $args{allow_local_on_power}
        || $ENV{NEOPERL_ALLOW_POWER_LOCAL_AI}
        || $args{allow_cpu_local_ai}
        || $ENV{NEOPERL_ALLOW_CPU_LOCAL_AI}
    ) ? 1 : 0;
    my $skip_local_ai = ($accel eq 'none' && !$allow_local_override) ? 1 : 0;
    my $skip_reason   = $skip_local_ai ? $detect_skip_reason : '';

    my $self = bless {
        ram_budget_gb                => defined($args{ram_budget_gb}) ? ($args{ram_budget_gb} + 0.0) : 20.0,
        model_dir                    => $model_dir,
        auto_apply_docs_if_syntax_ok => $args{auto_apply_docs_if_syntax_ok} ? 1 : 0,
        http_timeout                 => $args{http_timeout}    || 180,
        startup_timeout              => $args{startup_timeout} || 120,
        auto_discover                => $want_auto,
        os                           => $args{os},
        arch                         => $args{arch},
        accelerator_override         => $args{accelerator},
        accelerator                  => $accel,
        allow_local_on_power         => $args{allow_local_on_power} ? 1 : 0,
        allow_cpu_local_ai           => $args{allow_cpu_local_ai}   ? 1 : 0,
        local_ai_skipped_reason      => $skip_reason,
        roles                        => $roles,
    }, $class;

    if (ref($args{roles}) eq 'HASH') {
        $self->merge_overrides($args{roles});
    }

    # Auto-promote transport to remote_http if remote_url provided and transport untouched
    for my $r (@ROLES) {
        my $rc = $self->{roles}{$r};
        if (defined $rc->{remote_url} && length $rc->{remote_url}
            && (!exists($args{roles}{$r}{transport}) || !$args{roles}{$r}{transport}))
        {
            $rc->{transport} = 'remote_http';
        }
    }

    if ($want_auto && !$skip_local_ai) {
        $self->_auto_discover($args{roles});
    }

    return $self;
}

sub _auto_discover {
    my ($self, $explicit_roles) = @_;
    $explicit_roles = {} unless ref($explicit_roles) eq 'HASH';

    my $model_dir = $self->{model_dir};
    my $up_default    = $ENV{NEOPERL_LLAMA_SERVER}       || 'llama-server';
    my $prism_default = $ENV{NEOPERL_PRISM_LLAMA_SERVER} || 'prism-llama-server';

    for my $role (@ROLES) {
        my $rc = $self->{roles}{$role};
        my $ex = ref($explicit_roles->{$role}) eq 'HASH' ? $explicit_roles->{$role} : {};

        # Never override roles that already have an explicit transport or remote_url
        next if defined($ex->{transport}) && length($ex->{transport});
        next if defined($rc->{remote_url}) && length($rc->{remote_url});

        if ($role eq 'embedder') {
            next unless _is_valid_gguf($rc->{model_path});
            if (_llama_bridge_available()) {
                $rc->{transport} = 'inproc_libllama';
            }
            elsif (my $up = resolve_binary($rc->{server_bin}) // resolve_binary($up_default)) {
                $rc->{transport}  = 'managed_server';
                $rc->{server_bin} = $up;
            }
        }
        elsif ($role eq 'memory_writer') {
            my $mpath = $rc->{model_path};
            if (!_is_valid_gguf($mpath) && !defined($ex->{model_path})) {
                my $alt = File::Spec->catfile($model_dir, 'Hy-Memory-30B-A3B-Q4_K_M.gguf');
                $mpath = $alt if _is_valid_gguf($alt);
            }
            next unless _is_valid_gguf($mpath);
            if (my $up = resolve_binary($rc->{server_bin}) // resolve_binary($up_default)) {
                $rc->{model_path} = $mpath;
                $rc->{transport}  = 'managed_server';
                $rc->{server_bin} = $up;
            }
        }
        elsif ($role eq 'vision_doc') {
            next unless _is_valid_gguf($rc->{model_path});
            my $mmproj = $rc->{mmproj_path};
            if (!_is_valid_gguf($mmproj)) {
                for my $fname (
                    'mmproj-model-f16.gguf',
                    'mmproj-model-bf16.gguf',
                    'mmproj-granite-vision-4.1-4b-f16.gguf',
                ) {
                    my $cand = File::Spec->catfile($model_dir, $fname);
                    if (_is_valid_gguf($cand)) {
                        $mmproj = $cand;
                        last;
                    }
                }
            }
            next unless _is_valid_gguf($mmproj);
            if (my $up = resolve_binary($rc->{server_bin}) // resolve_binary($up_default)) {
                $rc->{mmproj_path} = $mmproj;
                $rc->{transport}   = 'managed_server';
                $rc->{server_bin}  = $up;
            }
        }
        elsif ($role eq 'worker_small') {
            my $mpath = $rc->{model_path};
            my $prism_bin = resolve_binary($rc->{server_bin});
            if (!$prism_bin && $rc->{server_bin} ne $prism_default) {
                $prism_bin = resolve_binary($prism_default);
            }
            if (!$prism_bin && ($rc->{backend_fork} // '') eq 'prism-ml') {
                $prism_bin = resolve_binary('prism-llama-server');
            }

            if (defined $prism_bin && _is_valid_gguf($mpath)) {
                $rc->{transport}    = 'managed_server';
                $rc->{backend_fork} = 'prism-ml';
                $rc->{server_bin}   = $prism_bin;
            }
            elsif (defined $prism_bin && !defined($ex->{model_path})
                && _is_valid_gguf(File::Spec->catfile($model_dir, 'Ternary-Bonsai-2-27B-PQ2_0.gguf')))
            {
                $rc->{model_path}   = File::Spec->catfile($model_dir, 'Ternary-Bonsai-2-27B-PQ2_0.gguf');
                $rc->{transport}    = 'managed_server';
                $rc->{backend_fork} = 'prism-ml';
                $rc->{server_bin}   = $prism_bin;
            }
            else {
                # Upstream llama.cpp >= b11556 can run Q2_0 quant directly
                my $q2_path;
                if (_is_q2_0_model($mpath) && _is_valid_gguf($mpath)) {
                    $q2_path = $mpath;
                }
                elsif (!defined($ex->{model_path})) {
                    my $cand = File::Spec->catfile($model_dir, 'Ternary-Bonsai-2-27B-Q2_0.gguf');
                    $q2_path = $cand if _is_valid_gguf($cand);
                }
                if (defined $q2_path) {
                    if (my $up = resolve_binary($up_default)) {
                        $rc->{model_path}   = $q2_path;
                        $rc->{transport}    = 'managed_server';
                        $rc->{backend_fork} = 'upstream';
                        $rc->{server_bin}   = $up;
                    }
                }
            }
        }
    }
    return $self;
}

sub ram_budget_gb {
    my ($self, $val) = @_;
    if (defined $val) {
        croak "ram_budget_gb must be positive" unless $val > 0;
        $self->{ram_budget_gb} = $val + 0.0;
    }
    return $self->{ram_budget_gb};
}

sub model_dir                    { $_[0]{model_dir} }
sub http_timeout                 { $_[0]{http_timeout} }
sub startup_timeout              { $_[0]{startup_timeout} }
sub auto_discover                { $_[0]{auto_discover} }
sub auto_apply_docs_if_syntax_ok { $_[0]{auto_apply_docs_if_syntax_ok} }
sub accelerator                  { $_[0]{accelerator} // 'none' }
sub local_ai_skipped_reason      { $_[0]{local_ai_skipped_reason} // '' }

sub role_names { return @ROLES }

sub role_config {
    my ($self, $role) = @_;
    croak "Unknown inference role: " . ($role // '<undef>')
        unless defined $role && $VALID_ROLE{$role};
    return $self->{roles}{$role};
}

sub merge_overrides {
    my ($self, $overrides) = @_;
    return $self unless ref($overrides) eq 'HASH';
    for my $role (keys %$overrides) {
        next unless $VALID_ROLE{$role} && ref($overrides->{$role}) eq 'HASH';
        my $dst = $self->{roles}{$role};
        my $src = $overrides->{$role};
        for my $k (keys %$src) {
            if ($k eq 'defaults' && ref($src->{$k}) eq 'HASH') {
                $dst->{defaults} = { %{ $dst->{defaults} || {} }, %{ $src->{$k} } };
            }
            elsif ($k eq 'extra_args' && ref($src->{$k}) eq 'ARRAY') {
                $dst->{extra_args} = [ @{ $src->{$k} } ];
            }
            else {
                $dst->{$k} = $src->{$k};
            }
        }
    }
    return $self;
}

sub validate {
    my ($self) = @_;
    my @errors;
    push @errors, "ram_budget_gb must be > 0" unless $self->{ram_budget_gb} > 0;

    for my $role (@ROLES) {
        my $rc = $self->{roles}{$role};
        my $t  = $rc->{transport} // '';
        if (!$VALID_TRANSPORT{$t}) {
            push @errors, "$role: invalid transport '$t'";
        }
        if ($t eq 'remote_http' && (!defined $rc->{remote_url} || $rc->{remote_url} !~ m{^https?://}i)) {
            push @errors, "$role: remote_http transport requires http(s):// remote_url";
        }
        if ($role eq 'worker_small' && $t eq 'managed_server') {
            my $fork = $rc->{backend_fork} // '';
            if ($fork eq 'prism-ml') {
                # Isolated Prism ML fork supports PTQ1_0 and PQ2_0 quants
            }
            elsif ($fork eq 'upstream' && _is_q2_0_model($rc->{model_path})) {
                # Mainline llama.cpp >= b11556 runs Q2_0 directly
            }
            else {
                push @errors, "worker_small (Ternary-Bonsai) must target backend_fork 'prism-ml' (upstream allowed only for Q2_0)";
            }
        }
        if ($role eq 'vision_doc' && $t eq 'managed_server' && (!defined $rc->{mmproj_path} || !length $rc->{mmproj_path})) {
            push @errors, "vision_doc (Granite-Vision) requires mmproj_path for managed_server";
        }
    }

    return wantarray ? (scalar(@errors) == 0, \@errors) : (scalar(@errors) == 0);
}

sub build_server_command {
    my ($self, $role, $port) = @_;
    my $rc = $self->role_config($role);
    $port ||= 0;

    my $bin = resolve_binary($rc->{server_bin}) // $rc->{server_bin};

    my @cmd = (
        $bin,
        '--model', $rc->{model_path},
        '--host',  '127.0.0.1',
        '--port',  "$port",
    );

    if (defined $rc->{ctx_size} && $rc->{ctx_size} > 0) {
        push @cmd, '--ctx-size', "$rc->{ctx_size}";
    }
    if (defined $rc->{ngl} && $rc->{ngl} >= 0) {
        push @cmd, '-ngl', "$rc->{ngl}";
    }
    if (defined $rc->{kv_cache_k} && length $rc->{kv_cache_k}) {
        push @cmd, '-ctk', $rc->{kv_cache_k};
    }
    if (defined $rc->{kv_cache_v} && length $rc->{kv_cache_v}) {
        push @cmd, '-ctv', $rc->{kv_cache_v};
    }
    if (defined $rc->{mmproj_path} && length $rc->{mmproj_path}) {
        push @cmd, '--mmproj', $rc->{mmproj_path};
    }
    if (ref($rc->{extra_args}) eq 'ARRAY' && @{ $rc->{extra_args} }) {
        push @cmd, @{ $rc->{extra_args} };
    }

    return \@cmd;
}

sub summary {
    my ($self) = @_;
    my %roles_out;
    for my $r (@ROLES) {
        my $rc = $self->{roles}{$r};
        $roles_out{$r} = {
            model_id         => $rc->{model_id},
            display_name     => $rc->{display_name},
            transport        => $rc->{transport},
            backend_fork     => $rc->{backend_fork},
            server_bin       => $rc->{server_bin},
            estimated_ram_gb => $rc->{estimated_ram_gb},
            pinned           => $rc->{pinned} ? 1 : 0,
            remote_url       => $rc->{remote_url},
        };
    }
    return {
        ram_budget_gb           => $self->{ram_budget_gb},
        model_dir               => $self->{model_dir},
        accelerator             => $self->accelerator,
        local_ai_skipped_reason => $self->local_ai_skipped_reason,
        roles                   => \%roles_out,
    };
}

1;

__END__

=head1 NAME

NeoPerl::Inference::Config - Role and transport configuration for the hybrid llama.cpp pool

=head1 SYNOPSIS

    use NeoPerl::Inference::Config;

    my $cfg = NeoPerl::Inference::Config->new(
        ram_budget_gb => 20,
        roles => {
            worker_small => {
                transport  => 'managed_server',
                server_bin => '/opt/prism-llama/bin/llama-server',
                model_path => '/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf',
            },
            memory_writer => {
                transport  => 'remote_http',
                remote_url => 'http://192.0.2.10:8081',
            },
        },
    );

=head1 DESCRIPTION

C<NeoPerl::Inference::Config> defines the four local specialist inference roles
used by C<NeoPerl::MT> (C<embedder>, C<memory_writer>, C<vision_doc>, and
C<worker_small>), isolates upstream C<llama.cpp> binaries from the Prism ML
C<llama.cpp> fork required by C<Ternary-Bonsai-2-27B>, and builds per-role
C<llama-server> command lines.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
