package NeoPerl::MT;

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Basename qw(basename dirname);
use File::Spec ();
use Time::HiRes qw(time);

use NeoPerl::Core ();
use NeoPerl::Editor;
use NeoPerl::Plugin::Telescope;
use NeoPerl::Plugin::Explorer;
use NeoPerl::Plugin::LSP;
use NeoPerl::Plugin::Git;
use NeoPerl::Plugin::WhichKey;
use NeoPerl::Plugin::Themes;
use NeoPerl::Plugin::PerlDev;
use NeoPerl::Plugin::XSDev;
use NeoPerl::RPC;

our $VERSION = '0.01';

sub add_sibling_inc {
    my ($class_or_root, $maybe_root) = @_;
    my $root = defined($maybe_root) ? $maybe_root : $class_or_root;
    if (!defined $root || !-d $root) {
        $root = abs_path(File::Spec->catdir(dirname(__FILE__), '..', '..'));
    }
    my $parent = File::Spec->catdir($root, File::Spec->updir);

    my %have = map { $_ => 1 } grep { !ref($_) } @INC;
    my $prepend = sub {
        my ($dir) = @_;
        return unless defined $dir && -d $dir;
        my $abs = eval { abs_path($dir) } || $dir;
        return if $have{$abs};
        unshift @INC, $abs;
        $have{$abs} = 1;
    };

    # Local CPAN prefix ($HOME/perl5/lib/perl5) for PPI / Perl::Critic / Perl::Tidy
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    if (length $home) {
        my $p5 = File::Spec->catdir($home, 'perl5', 'lib', 'perl5');
        $prepend->($p5) if -d $p5;
    }

    # Optional sibling MT repositories (via env override or ../<repo>)
    my @siblings = (
        [ $ENV{NEOPERL_DBD_SQLITE_DIR}, 'dbd-sqlite-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBD_ODBC_DIR},   'dbd-odbc-mt',   [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBI_DIR},        'dbi-mt',        [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_MOJO_DIR},       'mojolicious-mt',[ 'xs/blib/arch', 'xs/blib/lib', 'lib' ] ],
        [ $ENV{TCL_TK_MT_DIR} || $ENV{NEOPERL_TK_DIR}, 'tcl-tk-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
    );

    for my $spec (@siblings) {
        my ($env_dir, $repo_name, $subpaths) = @$spec;
        my $base = (defined $env_dir && length $env_dir && -d $env_dir)
            ? $env_dir
            : File::Spec->catdir($parent, $repo_name);
        next unless -d $base;
        for my $rel (reverse @$subpaths) {
            my $d = File::Spec->catdir($base, split('/', $rel));
            $prepend->($d) if -d $d;
        }
    }
    return 1;
}

sub new {
    my ($class, %opts) = @_;

    my $cwd = $opts{cwd} || getcwd();
    $cwd = eval { abs_path($cwd) } || $cwd;

    my $ui_req   = lc($opts{ui}      // 'auto');
    my $backend  = lc($opts{backend} // 'auto');
    my $headless = $opts{headless} ? 1 : 0;
    my $theme    = $opts{theme} || 'aix_amber';

    my $ed = NeoPerl::Editor->new(
        cwd         => $cwd,
        theme       => $theme,
        width       => $opts{cols} || 120,
        height      => $opts{rows} || 40,
        load_config => $opts{load_config} ? 1 : 0,
    );

    my $self = bless {
        editor         => $ed,
        cwd            => $cwd,
        ui_mode        => $ui_req,
        backend        => $backend,
        headless       => $headless,
        width          => int($opts{width}  || ($ui_req eq 'tui' ? 120 : 1280)),
        height         => int($opts{height} || ($ui_req eq 'tui' ? 40  : 720)),
        scale            => $opts{scale},
        auto_exit_ms     => int($opts{auto_exit_ms} || 0),
        demo             => $opts{demo} ? 1 : 0,
        inference_mock   => $opts{inference_mock} ? 1 : 0,
        agy_mock         => $opts{agy_mock} ? 1 : 0,
        no_agy           => ($opts{no_agy} || (defined($opts{agy}) && !$opts{agy})) ? 1 : 0,
        agy_force        => (defined($opts{agy}) && $opts{agy}) ? 1 : 0,
        agy_bin          => $opts{agy_bin},
        agy_model        => $opts{agy_model},
        agy_sandbox      => $opts{agy_sandbox} ? 1 : 0,
        agy_auto_connect => exists($opts{agy_auto_connect}) ? ($opts{agy_auto_connect} ? 1 : 0) : 1,
        nvim_engine      => $opts{nvim_engine} ? 1 : 0,
        nvim_bin       => $opts{nvim_bin},
        nvim_mock      => exists($opts{nvim_mock}) ? $opts{nvim_mock} : 'auto',
        nvim_bridge    => undef,
        db2_dsn        => $opts{db2_dsn},
        sqlite_path    => $opts{sqlite_path} // ':memory:',
        listen_addr    => $opts{listen},
        memory_query   => '',
        ui             => undef,
        rpc            => undef,
        telescope      => undef,
        explorer       => undef,
        lsp            => undef,
        git            => undef,
        whichkey       => undef,
        inference      => undef,
        memory_store         => undef,
        _memory_store_error  => undef,
        memory_writer        => undef,
        model_hub      => undef,
        vision         => undef,
        offload_queue  => undef,
        customizations => undef,
        editor_mcp     => undef,
        mcp_registry   => undef,
        acp            => undef,
        modalities     => undef,
        perldev        => undef,
        xsdev          => undef,
        _shutting_down => 0,
    }, $class;

    $self->_init_core_plugins(%opts);
    $self->_init_ai_memory_stack(%opts);
    $self->_init_dev_tools(%opts);
    $self->_wire_command_center_and_commands();
    $self->_init_nvim_engine(%opts) if $self->{nvim_engine};
    $self->_init_rpc() if defined $self->{listen_addr} && length $self->{listen_addr};
    $self->_init_ui(%opts) unless $ui_req eq 'none';

    return $self;
}

# --- Accessors ---

sub editor         { $_[0]{editor} }
sub ui             { $_[0]{ui} }
sub ui_mode        { $_[0]{ui_mode} }
sub nvim_bridge    { $_[0]{nvim_bridge} }
sub rpc            { $_[0]{rpc} }
sub telescope      { $_[0]{telescope} }
sub explorer       { $_[0]{explorer} }
sub lsp            { $_[0]{lsp} }
sub git            { $_[0]{git} }
sub whichkey       { $_[0]{whichkey} }
sub inference      { $_[0]{inference} }
sub memory_store   { $_[0]{memory_store} }
sub memory_writer  { $_[0]{memory_writer} }
sub model_hub      { $_[0]{model_hub} }
sub vision         { $_[0]{vision} }
sub offload_queue  { $_[0]{offload_queue} }
sub customizations { $_[0]{customizations} }
sub editor_mcp     { $_[0]{editor_mcp} }
sub mcp_registry   { $_[0]{mcp_registry} }
sub acp            { $_[0]{acp} }
sub modalities     { $_[0]{modalities} }
sub perldev        { $_[0]{perldev} }
sub xsdev          { $_[0]{xsdev} }

sub _init_core_plugins {
    my ($self, %opts) = @_;
    my $ed = $self->{editor};

    $self->{telescope} = NeoPerl::Plugin::Telescope->new(editor => $ed);
    $self->{explorer}  = NeoPerl::Plugin::Explorer->new(editor => $ed, root => $self->{cwd});
    $self->{git}       = NeoPerl::Plugin::Git->new(editor => $ed, cwd => $self->{cwd});
    $self->{whichkey}  = NeoPerl::Plugin::WhichKey->new(editor => $ed);
    $self->{lsp}       = NeoPerl::Plugin::LSP->new(
        editor     => $ed,
        auto_start => exists($opts{start_lsp}) ? ($opts{start_lsp} ? 1 : 0) : 0,
    );
    return;
}

sub _init_ai_memory_stack {
    my ($self, %opts) = @_;
    my $ed = $self->{editor};
    my $repo_key = basename($self->{cwd}) || 'workspace';

    # 1. Inference Config & Manager (4 specialist local roles + LRU RAM budget)
    if (eval { require NeoPerl::Inference::Config; require NeoPerl::Inference::Manager; 1 }) {
        my $auto_discover = ($self->{demo} || $opts{inference_mock} || $ENV{NEOPERL_INFERENCE_MOCK}) ? 0 : 1;
        if (exists $opts{auto_discover}) {
            $auto_discover = ($opts{auto_discover} && !$ENV{NEOPERL_INFERENCE_MOCK}) ? 1 : 0;
        }
        my $icfg = NeoPerl::Inference::Config->new(
            ram_budget_gb => $opts{ram_budget_gb} || 20,
            (defined $opts{model_dir} && length $opts{model_dir} ? (model_dir => $opts{model_dir}) : ()),
            auto_discover => $auto_discover,
        );
        $self->{inference} = NeoPerl::Inference::Manager->new(config => $icfg);
        $ed->register_plugin('inference', $self->{inference});
    }

    # 2. Relational Semantic Memory Store (IBM Db2 12.1.2+ VECTOR or SQLite+SIMD)
    if (eval { require NeoPerl::Memory::Store; 1 }) {
        my %store_opts = (
            embedder => $self->{inference},
        );
        if (defined $self->{db2_dsn} && length $self->{db2_dsn}) {
            $store_opts{dsn}  = $self->{db2_dsn};
            $store_opts{user} = $opts{db2_user} // $ENV{NEOPERL_DB2_USER} // '';
            $store_opts{pass} = $opts{db2_pass} // $ENV{NEOPERL_DB2_PASS} // '';
        }
        else {
            $store_opts{sqlite_path} = $self->{sqlite_path};
        }
        $self->{memory_store} = eval { NeoPerl::Memory::Store->new(%store_opts) };
        if ($self->{memory_store}) {
            $self->{_memory_store_error} = undef;
            $ed->register_plugin('memory', $self->{memory_store});
        }
        else {
            $self->{_memory_store_error} = $@;
        }
    }
    else {
        $self->{_memory_store_error} = $@;
    }

    # 3. Hy-Memory Writer + ModelHub + Granite-Vision + Ternary-Bonsai OffloadQueue
    if ($self->{memory_store} && eval { require NeoPerl::Memory::Writer; 1 }) {
        $self->{memory_writer} = eval {
            NeoPerl::Memory::Writer->new(
                store     => $self->{memory_store},
                inference => $self->{inference},
                repo_key  => $repo_key,
                repo_root => $self->{cwd},
            );
        };
        $ed->register_plugin('memory_writer', $self->{memory_writer}) if $self->{memory_writer};
    }

    if ($self->{inference} && eval { require NeoPerl::Inference::ModelHub; 1 }) {
        $self->{model_hub} = eval { NeoPerl::Inference::ModelHub->new(config => $self->{inference}->config) };
        $ed->register_plugin('model_hub', $self->{model_hub}) if $self->{model_hub};
    }

    if ($self->{inference} && eval { require NeoPerl::Inference::Vision; 1 }) {
        $self->{vision} = eval {
            NeoPerl::Inference::Vision->new(
                inference => $self->{inference},
                store     => $self->{memory_store},
            );
        };
        $ed->register_plugin('vision', $self->{vision}) if $self->{vision};
    }

    if ($self->{inference} && eval { require NeoPerl::Inference::OffloadQueue; 1 }) {
        $self->{offload_queue} = eval {
            NeoPerl::Inference::OffloadQueue->new(
                inference  => $self->{inference},
                store      => $self->{memory_store},
                editor     => $ed,
                async_mode => $opts{offload_async_mode} || 'tick',
            );
        };
        $ed->register_plugin('offload_queue', $self->{offload_queue}) if $self->{offload_queue};
    }

    # 4. Antigravity Control Plane (Customizations + EditorMCP + ACP + Modalities)
    if (eval { require NeoPerl::Antigravity::Customizations; 1 }) {
        $self->{customizations} = eval { NeoPerl::Antigravity::Customizations->new(workspace_root => $self->{cwd}) };
        eval { $self->{customizations}->discover() } if $self->{customizations};
        $ed->register_plugin('customizations', $self->{customizations}) if $self->{customizations};
    }

    if (eval { require NeoPerl::Antigravity::EditorMCP; 1 }) {
        $self->{editor_mcp} = eval {
            NeoPerl::Antigravity::EditorMCP->new(
                editor         => $ed,
                memory_store   => $self->{memory_store},
                memory_writer  => $self->{memory_writer},
                vision         => $self->{vision},
                offload_queue  => $self->{offload_queue},
                customizations => $self->{customizations},
            );
        };
        if ($self->{editor_mcp}) {
            $ed->register_plugin('mcp', $self->{editor_mcp});
            my $want_mcp = exists($opts{start_mcp}) ? ($opts{start_mcp} ? 1 : 0) : 1;
            eval { $self->{editor_mcp}->start() } if $want_mcp;
        }
    }

    if (eval { require NeoPerl::MCP::Registry; 1 }) {
        $self->{mcp_registry} = eval {
            NeoPerl::MCP::Registry->new(
                editor      => $ed,
                editor_mcp  => $self->{editor_mcp},
                telescope   => $self->{telescope},
                auto_enable => $opts{mcp_packs},
            );
        };
        if ($self->{mcp_registry} && $self->{lsp} && $self->{lsp}->can('builtin') && $self->{lsp}->builtin) {
            $self->{lsp}->builtin->set_registry($self->{mcp_registry});
        }
    }

    if (eval { require NeoPerl::Antigravity::ACP; 1 }) {
        $self->{acp} = eval {
            NeoPerl::Antigravity::ACP->new(
                editor     => $ed,
                editor_mcp => $self->{editor_mcp},
                cwd        => $self->{cwd},
                mock       => $self->{agy_mock},
                disabled   => $self->{no_agy},
                agy_bin    => $self->{agy_bin},
                sandbox    => $self->{agy_sandbox},
                model      => $self->{agy_model},
            );
        };
        $ed->register_plugin('acp', $self->{acp}) if $self->{acp};
    }

    if (eval { require NeoPerl::Antigravity::Modalities; 1 }) {
        $self->{modalities} = eval {
            NeoPerl::Antigravity::Modalities->new(
                editor         => $ed,
                acp            => $self->{acp},
                editor_mcp     => $self->{editor_mcp},
                mcp_registry   => $self->{mcp_registry},
                telescope      => $self->{telescope},
                memory_store   => $self->{memory_store},
                memory_writer  => $self->{memory_writer},
                inference      => $self->{inference},
                vision         => $self->{vision},
                offload_queue  => $self->{offload_queue},
                model_hub      => $self->{model_hub},
                customizations => $self->{customizations},
                repo_key       => $repo_key,
            );
        };
        if ($self->{modalities}) {
            $ed->register_plugin('modalities', $self->{modalities});
            eval { $self->{modalities}->attach($ed) };
            $ed->add_tick_callback('antigravity_pump', sub {
                eval { $self->{modalities}->pump() };
            });
        }
    }

    # Automatic Antigravity ACP startup (offline mock or non-blocking live connect)
    if ($self->{acp}) {
        my $mp = ($self->{editor_mcp} && defined $self->{editor_mcp}->port) ? $self->{editor_mcp}->port : 0;
        if ($self->{agy_mock}) {
            eval {
                $self->{acp}->start(mock => 1, mcp_port => $mp, cwd => $self->{cwd}, sandbox => $self->{agy_sandbox});
                $self->{acp}->initialize();
                $self->{acp}->new_session(cwd => $self->{cwd}, mcp_port => $mp);
                if (defined $self->{agy_model} && length $self->{agy_model}) {
                    eval { $self->{acp}->set_model($self->{agy_model}) };
                }
            };
        }
        elsif (!$self->{no_agy} && $self->{agy_auto_connect}) {
            my $bin = $self->{agy_bin} || NeoPerl::Antigravity::ACP::discover_agy_binary();
            if (defined $bin) {
                eval {
                    $self->{acp}->connect_async(
                        agy_bin  => $bin,
                        cwd      => $self->{cwd},
                        mcp_port => $mp,
                        sandbox  => $self->{agy_sandbox},
                        (defined $self->{agy_model} ? (model => $self->{agy_model}) : ()),
                    );
                };
            }
            elsif ($self->{agy_force}) {
                $ed->notify("Antigravity CLI ('agy') not found — run :AgyInstall or npl --agy-mock", 'warn');
            }
        }
    }
    return;
}

sub _init_dev_tools {
    my ($self, %opts) = @_;
    my $ed = $self->{editor};

    $self->{perldev} = eval {
        NeoPerl::Plugin::PerlDev->new(
            editor        => $ed,
            mcp           => $self->{editor_mcp},
            offload_queue => $self->{offload_queue},
            modalities    => $self->{modalities},
            memory_store  => $self->{memory_store},
            telescope     => $self->{telescope},
            auto_critic   => exists($opts{auto_critic}) ? $opts{auto_critic} : 1,
        );
    };

    $self->{xsdev} = eval {
        NeoPerl::Plugin::XSDev->new(
            editor       => $ed,
            mcp          => $self->{editor_mcp},
            memory_store => $self->{memory_store},
            telescope    => $self->{telescope},
            workdir      => $self->{cwd},
        );
    };
    return;
}

sub _wire_command_center_and_commands {
    my ($self) = @_;
    my $ed = $self->{editor};

    # Register Command Center tab data providers for CHAT, MEMORY, MODELS (XSDEV already registered by XSDev)
    $ed->register_command_center_provider('chat', sub {
        return $self->{modalities} ? $self->{modalities}->chat_state() : {};
    });

    $ed->register_command_center_provider('memory', sub {
        my $store = $self->{memory_store};
        my $q = $self->{memory_query} // '';
        if (!$store) {
            my $demo = $self->{_demo_memories} || [];
            return {
                dialect => 'db2_demo',
                query   => $q,
                items   => $demo,
                stats   => { active_memories => scalar(@$demo) },
            };
        }
        my $items = eval {
            $store->search(
                query              => $q,
                limit              => 10,
                include_superseded => 1,
                update_access      => 0,
            );
        } || [];
        return {
            dialect => $store->dialect,
            query   => $q,
            items   => $items,
            stats   => eval { $store->stats } || {},
        };
    });

    $ed->register_command_center_provider('jobs', sub {
        return {
            telemetry   => $self->{inference}     ? $self->{inference}->telemetry()     : {},
            jobs        => $self->{offload_queue} ? $self->{offload_queue}->list_jobs() : [],
            vision_docs => $self->{vision}        ? $self->{vision}->recent_docs()      : [],
        };
    });

    # Bind Command Center, Memory, Vision, and Antigravity Ex commands + keymaps cleanly on Editor
    my $ex    = $ed->excmd;
    my $modal = $ed->modal;
    my $mod   = $self->{modalities};

    $ex->register_command('AgyChat', sub {
        my ($e, $ctx) = @_;
        $e->layout->open_command_center('chat');
        my $arg = $ctx->{args} // '';
        return ($mod && length $arg) ? $mod->send_chat($arg) : { ok => 1, tab => 'chat' };
    }, desc => 'Open Antigravity Chat tab or send a prompt');

    $ex->register_command('AgyDoctor', sub {
        return $mod ? $mod->agy_doctor() : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Inspect Antigravity ACP binary, sign-in, model, MCP tools, and next step', aliases => ['AgyStatus']);

    $ex->register_command('AgyStatus', sub {
        return $mod ? $mod->agy_doctor() : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Show Antigravity ACP status and diagnostics');

    $ex->register_command('AgyLogin', sub {
        my ($e, $ctx) = @_;
        return { ok => 0, message => 'Modalities unavailable' } unless $mod;
        my $arg = $ctx->{args} // '';
        return $mod->agy_login(
            (length $arg ? (method_id => $arg) : ()),
            bang => $ctx->{bang} ? 1 : 0,
        );
    }, desc => 'Sign in to Antigravity via authenticate RPC or embedded :terminal split', bang => 1);

    $ex->register_command('AgyInstall', sub {
        my ($e, $ctx) = @_;
        return { ok => 0, message => 'Modalities unavailable' } unless $mod;
        return $mod->agy_install(bang => $ctx->{bang} ? 1 : 0);
    }, desc => 'Show official agy CLI install command (:AgyInstall! runs in terminal split)', bang => 1);

    $ex->register_command('AgyModel', sub {
        my ($e, $ctx) = @_;
        return $mod ? $mod->agy_model($ctx->{args}) : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Switch Antigravity model or open Telescope model picker');

    $ex->register_command('AgyNewSession', sub {
        return $mod ? $mod->agy_new_session() : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Start a fresh Antigravity ACP session');

    $ex->register_command('AgyResume', sub {
        my ($e, $ctx) = @_;
        return $mod ? $mod->agy_resume($ctx->{args}) : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Resume an existing Antigravity ACP session');

    $ex->register_command('AgyReconnect', sub {
        my ($e, $ctx) = @_;
        return $mod ? $mod->agy_reconnect(sync => $ctx->{bang} ? 1 : 0) : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Reconnect Antigravity ACP subprocess', bang => 1);

    $ex->register_command('AgyInline', sub {
        my ($e, $ctx) = @_;
        my $inst = $ctx->{args} || 'Improve code clarity';
        return $mod ? $mod->run_inline_command($inst) : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Run Antigravity inline command and stage diff hunks');

    $ex->register_command('AgyFix', sub {
        my ($e, $ctx) = @_;
        return $mod ? $mod->auto_fix_diagnostic() : { ok => 0, message => 'Modalities unavailable' };
    }, desc => 'Auto-fix diagnostic at cursor');

    $ex->register_command('AgyJobs', sub {
        my ($e, $ctx) = @_;
        $e->layout->open_command_center('jobs');
        return { ok => 1, jobs => ($self->{offload_queue} ? $self->{offload_queue}->list_jobs() : []) };
    }, desc => 'Open Local Models & Bonsai Jobs Command Center tab');

    $ex->register_command('ModelHub', sub {
        my ($e, $ctx) = @_;
        $e->layout->open_command_center('jobs');
        my $txt = $self->{model_hub} ? $self->{model_hub}->format_report_text() : 'ModelHub unavailable';
        $e->notify('ModelHub status refreshed', 'info');
        return { ok => 1, report => $txt };
    }, desc => 'Inspect local GGUF models and llama-server binaries');

    $ex->register_command('InferenceDoctor', sub {
        my ($e, $ctx) = @_;
        return { ok => 0, message => 'ModelHub unavailable' } unless $self->{model_hub};
        $e->layout->open_command_center('jobs');
        my $rep = $self->{model_hub}->doctor_report();
        my $txt = $self->{model_hub}->format_doctor_text();
        $e->notify(
            sprintf('InferenceDoctor: %d/%d roles ready (libllama=%s)',
                $rep->{ready_count}, $rep->{total_roles},
                $rep->{llama_bridge}{available} ? 'yes' : 'no'),
            $rep->{all_ready} ? 'info' : 'warn',
        );
        return { ok => 1, report => $rep, text => $txt };
    }, desc => 'Diagnose local llama.cpp binaries, libllama dlopen bridge, and GGUF model readiness');

    $ex->register_command('ModelPull', sub {
        my ($e, $ctx) = @_;
        return { ok => 0, message => 'ModelHub unavailable' } unless $self->{model_hub};
        my $role = $ctx->{args} // '';
        $role =~ s/^\s+|\s+$//g;
        if (!length $role) {
            my $msg = 'Usage: :ModelPull <embedder|memory_writer|vision_doc|worker_small|all>';
            $e->notify($msg, 'info');
            return { ok => 1, usage => $msg, recipes => $self->{model_hub}->download_recipes() };
        }
        my $res = $self->{model_hub}->download_role($role, force => $ctx->{bang} ? 1 : 0);
        if ($res->{ok}) {
            $e->notify("ModelPull $role: ready", 'info');
        }
        else {
            $e->notify("ModelPull $role failed: " . ($res->{error} // 'unknown error'), 'error');
        }
        return $res;
    }, desc => 'Download GGUF weights for a local inference role (:ModelPull! forces re-download)', bang => 1);

    $ex->register_command('MemSave', sub {
        my ($e, $ctx) = @_;
        my $arg = $ctx->{args} // '';
        return { ok => 0, message => 'Usage: :MemSave <fact>' } unless length $arg;
        return $self->{memory_writer}
            ? $self->{memory_writer}->save_explicit(content => $arg)
            : { ok => 0, message => 'Memory writer unavailable' };
    }, desc => 'Save semantic memory into Db2 store');

    $ex->register_command('MemSearch', sub {
        my ($e, $ctx) = @_;
        $self->{memory_query} = $ctx->{args} // '';
        $e->layout->open_command_center('memory');
        my $hits = $self->{memory_store}
            ? $self->{memory_store}->search(query => $self->{memory_query}, limit => 12)
            : [];
        return { ok => 1, hits => $hits };
    }, desc => 'Semantic search Db2 memory store');

    $ex->register_command('MemBrowse', sub {
        my ($e, $ctx) = @_;
        $self->{memory_query} = $ctx->{args} // '';
        $e->layout->open_command_center('memory');
        return { ok => 1, tab => 'memory' };
    }, desc => 'Open Db2 Semantic Memory Inspector tab');

    $ex->register_command('MemAutoContext', sub {
        my ($e, $ctx) = @_;
        return { ok => 0 } unless $mod;
        my $arg = $ctx->{args} // '';
        if    ($arg =~ /\A(?:on|1|true)\z/i)  { $mod->auto_context(1) }
        elsif ($arg =~ /\A(?:off|0|false)\z/i){ $mod->auto_context(0) }
        else                                  { $mod->auto_context(!$mod->auto_context) }
        my $st = $mod->auto_context ? 'ON' : 'OFF';
        $e->notify("MemAutoContext: $st", 'info');
        return { ok => 1, auto_context => $mod->auto_context };
    }, desc => 'Toggle <=250-token auto-context memory hint');

    $ex->register_command('VisionParse', sub {
        my ($e, $ctx) = @_;
        return { ok => 0, message => 'Vision unavailable' } unless $self->{vision};
        my $arg = $ctx->{args} // '';
        return (!length($arg) || $arg eq 'clipboard')
            ? $self->{vision}->preprocess_clipboard()
            : $self->{vision}->preprocess_file(path => $arg);
    }, desc => 'Preprocess image or PDF locally with Granite-Vision-4.1-4B');

    # Keymaps
    $modal->map('n', '<leader>aa', sub { $ed->layout->toggle_command_center('chat') },   desc => 'Toggle Antigravity Chat');
    $modal->map('n', '<leader>am', sub { $ed->layout->toggle_command_center('memory') }, desc => 'Toggle Db2 Memory Inspector');
    $modal->map('n', '<leader>aj', sub { $ed->layout->toggle_command_center('jobs') },   desc => 'Toggle Local Models & Jobs');
    $modal->map('n', '<leader>aL', sub { $mod->agy_login() if $mod },                    desc => 'Antigravity Sign-In (:AgyLogin)');
    $modal->map('n', '<leader>aM', sub { $mod->agy_model() if $mod },                    desc => 'Antigravity Model Picker (:AgyModel)');
    $modal->map('n', '<leader>ai', sub { $mod->run_inline_command('Improve code') if $mod }, desc => 'Antigravity Inline Command');
    $modal->map('n', '<C-i>',      sub { $mod->run_inline_command('Improve code') if $mod }, desc => 'Antigravity Inline Command');
    $modal->map('n', '<leader>af', sub { $mod->auto_fix_diagnostic() if $mod },              desc => 'Antigravity Auto-Fix Diagnostic');
    $modal->map('n', '<leader>ay', sub {
        my $b = $ed->current_buffer;
        my $w = $ed->current_window;
        $b->accept_hunk_at_line($w ? $w->cursor_line : 0) || $b->accept_hunk(0) if $b;
    }, desc => 'Accept diff hunk');
    $modal->map('n', '<leader>an', sub {
        my $b = $ed->current_buffer;
        my $w = $ed->current_window;
        $b->reject_hunk_at_line($w ? $w->cursor_line : 0) || $b->reject_hunk(0) if $b;
    }, desc => 'Reject diff hunk');
    $modal->map('n', '<leader>vp', sub { $self->{vision}->preprocess_clipboard() if $self->{vision} }, desc => 'Vision parse clipboard');

    $modal->map('n', '<leader>fm', sub {
        return unless $self->{memory_store} && $self->{telescope};
        my $hits = $self->{memory_store}->search(query => '', limit => 30, update_access => 0) || [];
        my @items = map {
            +{
                label   => sprintf('[%s/%s] %s', $_->{scope_level} // 'repo', $_->{category} // 'fact', $_->{content} // ''),
                detail  => sprintf('score %.2f', $_->{cosine_score} // $_->{confidence} // 0.85),
                preview => [ "Scope: $_->{scope_level}", "Category: $_->{category}", '', $_->{content} // '' ],
                data    => $_,
            }
        } @$hits;
        $self->{telescope}->open_custom('Db2 Semantic Memories', \@items, sub {
            $ed->layout->open_command_center('memory');
        });
    }, desc => 'Search Db2 semantic memories');

    $modal->map('n', '<leader>fa', sub {
        return unless $self->{customizations} && $self->{telescope};
        my $items = $self->{customizations}->as_telescope_items() || [];
        $self->{telescope}->open_custom('Antigravity Customizations', $items, sub {
            my ($item) = @_;
            $ed->open_file($item->{path}) if $item && $item->{path} && -f $item->{path};
        });
    }, desc => 'Search Antigravity skills, rules & MCP');

    # Explorer 'v' action for Granite-Vision parsing of images/PDFs
    if ($self->{explorer} && $self->{vision}) {
        $self->{explorer}->register_action('v', 'Parse image/PDF via Granite-Vision', sub {
            my ($exp, $node, $e) = @_;
            return unless $node && !$node->{is_dir} && $node->{path};
            my $res = eval { $self->{vision}->preprocess_file(path => $node->{path}) };
            $e->notify($res ? "Vision parsed: $node->{name}" : 'Vision parse failed', $res ? 'info' : 'error');
        });
    }
    return;
}

sub _init_nvim_engine {
    my ($self, %opts) = @_;
    return $self->{nvim_bridge} if $self->{nvim_bridge} && eval { $self->{nvim_bridge}->is_connected };
    require NeoPerl::NvimBridge;
    my $nb = NeoPerl::NvimBridge->new(
        nvim_bin => $opts{nvim_bin} // $self->{nvim_bin},
        mock     => exists($opts{nvim_mock}) ? $opts{nvim_mock} : $self->{nvim_mock},
        cwd      => $self->{cwd},
        editor   => $self->{editor},
        cols     => $opts{nvim_cols} || 96,
        rows     => $opts{nvim_rows} || 34,
    );
    $nb->connect();
    $nb->apply_theme($self->{editor}->theme) if $self->{editor} && $self->{editor}->theme;
    $self->{nvim_bridge} = $nb;
    $self->{nvim_engine} = 1;
    $self->{editor}->nvim_bridge($nb);
    $self->{editor}->register_plugin('nvim_bridge', $nb);
    return $nb;
}

sub _init_rpc {
    my ($self) = @_;
    $self->{rpc} = NeoPerl::RPC->new(
        editor  => $self->{editor},
        address => $self->{listen_addr},
    );
    $self->{editor}->register_plugin('rpc', $self->{rpc});
    $self->{editor}->add_tick_callback('rpc_poll', sub {
        eval { $self->{rpc}->poll(0) };
    });
    return;
}

sub _can_use_gpu {
    my ($self) = @_;
    return 0 unless eval { require Tcl::Tk::MT; require Tcl::Tk::MT::Canvas; 1 };
    return 1 if $self->{headless};
    return 1 if $^O eq 'darwin' || $^O eq 'MSWin32';
    return 1 if ($ENV{DISPLAY} && length $ENV{DISPLAY}) || ($ENV{WAYLAND_DISPLAY} && length $ENV{WAYLAND_DISPLAY});
    return 0;
}

sub _init_ui {
    my ($self, %opts) = @_;
    my $mode = $self->{ui_mode};
    if ($mode eq 'auto') {
        $mode = $self->_can_use_gpu() ? 'gpu' : 'tui';
    }
    $self->{ui_mode} = $mode;

    if ($mode eq 'gpu') {
        require NeoPerl::UI::GPU;
        $self->{ui} = NeoPerl::UI::GPU->new(
            editor       => $self->{editor},
            app          => $self,
            width        => $self->{width},
            height       => $self->{height},
            (defined $self->{scale} ? (scale => $self->{scale}) : ()),
            backend      => $self->{backend},
            headless     => $self->{headless},
            auto_exit_ms => $self->{auto_exit_ms},
        );
    }
    else {
        require NeoPerl::UI::TUI;
        $self->{ui} = NeoPerl::UI::TUI->new(
            editor       => $self->{editor},
            app          => $self,
            width        => $opts{cols} || ($self->{width} <= 300 ? $self->{width} : 120),
            height       => $opts{rows} || ($self->{height} <= 120 ? $self->{height} : 40),
            headless     => $self->{headless},
            auto_exit_ms => $self->{auto_exit_ms},
        );
    }
    return;
}

# ---------------------------------------------------------------------------
# Public Operations & Telemetry
# ---------------------------------------------------------------------------

sub open_files {
    my ($self, @files) = @_;
    my @opened;
    for my $f (@files) {
        next unless defined $f && length $f;
        push @opened, $self->{editor}->open_file($f);
    }
    if (@files && $self->{nvim_bridge} && eval { $self->{nvim_bridge}->is_connected }) {
        my $first = $files[0];
        $first =~ s/([ \\])/\\$1/g;
        eval { $self->{nvim_bridge}->command("edit $first") };
    }
    return \@opened;
}

sub telemetry {
    my ($self) = @_;
    my $arch = eval { NeoPerl::Core::arch_info() } || {};
    my $mojo_accel = eval { require Mojo::MT::Accel; 1 } ? 1 : 0;
    my $mojo_simd  = ($mojo_accel && defined(&Mojo::MT::Accel::simd_tier))
        ? eval { Mojo::MT::Accel::simd_tier() }
        : 'none';
    my $nb = $self->{nvim_bridge};
    return {
        version        => $VERSION,
        perl_version   => sprintf('%vd', $^V),
        is_perl5_mt    => eval { NeoPerl::Core::is_perl5_mt() } ? 1 : 0,
        arch           => $arch,
        ui_mode        => $self->{ui_mode},
        ui_backend     => $self->{ui} ? $self->{ui}->backend_name : 'none',
        nvim_engine    => {
            active  => ($nb && eval { $nb->is_connected }) ? 1 : 0,
            version => ($nb && eval { $nb->is_connected }) ? $nb->version_string : '',
            mock    => ($nb && eval { $nb->is_mock })      ? 1 : 0,
        },
        mojo_accel     => { available => $mojo_accel, simd_tier => $mojo_simd },
        memory_dialect => $self->{memory_store} ? $self->{memory_store}->dialect : 'none',
        acp            => $self->{acp} ? {
            state         => $self->{acp}->state,
            mock          => $self->{acp}->is_mock,
            binary        => ($self->{acp}->agy_bin || eval { NeoPerl::Antigravity::ACP::discover_agy_binary() }),
            session_id    => $self->{acp}->session_id,
            current_model => $self->{acp}->current_model,
            pill          => ($self->{modalities} ? $self->{modalities}->acp_status_pill->{label} : 'AGY:OFF'),
        } : {},
        mcp            => $self->{editor_mcp}   ? $self->{editor_mcp}->info() : {},
        mcp_packs      => $self->{mcp_registry} ? $self->{mcp_registry}->summary() : {},
        inference      => $self->{inference}    ? $self->{inference}->telemetry() : {},
        perldev        => $self->{perldev}    ? $self->{perldev}->capabilities() : {},
        rpc            => $self->{rpc}        ? { running => $self->{rpc}->is_running, address => $self->{rpc}->address, transport => $self->{rpc}->transport } : {},
    };
}

# ---------------------------------------------------------------------------
# Interactive & Screenshot Demo Workspace Builder (--demo)
# ---------------------------------------------------------------------------

sub setup_demo {
    my ($self, %opts) = @_;
    my $scene  = lc($opts{scene} || 'chat_diff');
    my $ed     = $self->{editor};
    my $layout = $ed->layout;

    # Keep synthetic demo seeding fast and deterministic on loopback (never spawn live GGUF servers)
    $self->{demo} = 1;
    if ($self->{inference}) {
        for my $r ($self->{inference}->config->role_names) {
            my $rc = $self->{inference}->config->role_config($r);
            my $s  = $self->{inference}{slots}{$r};
            if ($s && !$s->{loaded} && ($rc->{transport} // '') ne 'loopback') {
                $rc->{transport} = 'loopback';
                $s->{transport}  = 'loopback';
            }
        }
    }

    # Seed realistic semantic memories (including pinned + superseding lineage)
    if ($self->{memory_store}) {
        my $st = $self->{memory_store};
        my $m1 = eval {
            $st->add_memory({
                scope_level  => 'global',
                category     => 'convention',
                content      => 'Keep C11 XS units strictly unsigned-char safe and dynamic page-size aware for ppc64le.',
                tags         => [ 'c11', 'ppc64le', 'xs' ],
                confidence   => 0.96,
                pinned       => 1,
                source_event => 'explicit',
            });
        };
        my $m2 = eval {
            $st->add_memory({
                scope_level  => 'repo',
                repo_key     => 'neoperl-mt',
                category     => 'architecture',
                content      => 'Initial embedding table stored float32 vectors in plain BLOB columns.',
                tags         => [ 'db2', 'vector' ],
                confidence   => 0.82,
                source_event => 'git_commit',
            });
        };
        my $m2_id = ref($m2) eq 'HASH' ? $m2->{id} : $m2;
        if (defined $m2_id && $m2_id) {
            eval {
                $st->supersede($m2_id, {
                    scope_level  => 'repo',
                    repo_key     => 'neoperl-mt',
                    category     => 'architecture',
                    content      => 'Primary Db2 12.1.2+ store uses native VECTOR(768, REAL) with VECTOR_DISTANCE(..., COSINE).',
                    tags         => [ 'db2', 'vector', 'cosine' ],
                    confidence   => 0.95,
                    pinned       => 1,
                    source_event => 'agy_turn',
                });
            };
        }
        eval {
            $st->add_memory({
                scope_level  => 'file',
                repo_key     => 'neoperl-mt',
                file_path    => 'c/vec_simd.c',
                category     => 'gotcha',
                content      => 'Unroll VSX vec_madd 4-way and honor PERL_FORCE_SCALAR=1 for bit-identical parity.',
                tags         => [ 'vsx', 'simd', 'power8' ],
                confidence   => 0.93,
                source_event => 'diagnostic_resolved',
            });
        };
        eval {
            $st->add_memory({
                scope_level  => 'symbol',
                repo_key     => 'neoperl-mt',
                file_path    => 'lib/NeoPerl/Plugin/PerlDev.pm',
                symbol_name  => 'post_tidy_proposal',
                category     => 'decision',
                content      => 'Reuse cached PPI::Document across outline and Perl::Critic to avoid double parsing.',
                tags         => [ 'ppi', 'perlcritic' ],
                confidence   => 0.91,
                source_event => 'agy_turn',
            });
        };
    }
    else {
        # Fallback in-memory demo items when DBI/DBD::SQLite is unavailable
        $self->{_demo_memories} = [
            {
                id           => 3,
                scope_level  => 'repo',
                category     => 'architecture',
                content      => 'Primary Db2 12.1.2+ store uses native VECTOR(768, REAL) with VECTOR_DISTANCE(..., COSINE).',
                confidence   => 0.95,
                cosine_score => 0.91,
                pinned       => 1,
            },
            {
                id           => 1,
                scope_level  => 'global',
                category     => 'convention',
                content      => 'Keep C11 XS units strictly unsigned-char safe and dynamic page-size aware for ppc64le.',
                confidence   => 0.96,
                cosine_score => 0.84,
                pinned       => 1,
            },
            {
                id           => 4,
                scope_level  => 'file',
                category     => 'gotcha',
                content      => 'Unroll VSX vec_madd 4-way and honor PERL_FORCE_SCALAR=1 for bit-identical parity.',
                confidence   => 0.93,
                cosine_score => 0.79,
                pinned       => 0,
            },
            {
                id           => 5,
                scope_level  => 'symbol',
                category     => 'decision',
                content      => 'Reuse cached PPI::Document across outline and Perl::Critic to avoid double parsing.',
                confidence   => 0.91,
                cosine_score => 0.72,
                pinned       => 0,
            },
            {
                id               => 2,
                scope_level      => 'repo',
                category         => 'architecture',
                content          => 'Initial embedding table stored float32 vectors in plain BLOB columns.',
                confidence       => 0.82,
                cosine_score     => 0.64,
                pinned           => 0,
                superseded_by_id => 3,
            },
        ];
    }

    # Build demo workspace buffers first (removing untouched [No Name] scratch buffer)
    my $perl_src = <<'END_PERL';
package NeoPerl::Demo::Scheduler;

use strict;
use warnings;

use NeoPerl::Core qw(:tokens);

sub new {
    my ($class, %opts) = @_;
    return bless {
        workers => $opts{workers} || 4,
        budget  => $opts{ram_budget_gb} || 20,
        queue   => [],
    }, $class;
}

sub dispatch_task {
    my ($self, $job) = @_;
    return undef unless ref($job) eq 'HASH';
    push @{ $self->{queue} }, $job;
    return scalar @{ $self->{queue} };
}

sub flush_ready {
    my ($self) = @_;
    my $n = 0;
    while (my $job = shift @{ $self->{queue} }) {
        $n++ if $job->{ready};
    }
    return $n;
}

1;
END_PERL

    my $perl_proposed = <<'END_PERL';
package NeoPerl::Demo::Scheduler;

use strict;
use warnings;

use NeoPerl::Core qw(:tokens);

sub new {
    my ($class, %opts) = @_;
    return bless {
        workers => $opts{workers} || 4,
        budget  => $opts{ram_budget_gb} || 20,
        queue   => [],
    }, $class;
}

sub dispatch_task {
    my ($self, $job) = @_;
    return unless ref($job) eq 'HASH';
    $job->{queued_at} //= time();
    push @{ $self->{queue} }, $job;
    return scalar @{ $self->{queue} };
}

sub flush_ready {
    my ($self) = @_;
    my $n = 0;
    while (my $job = shift @{ $self->{queue} }) {
        $n++ if $job->{ready};
    }
    return $n;
}

1;
END_PERL

    my $c_path = File::Spec->catfile($self->{cwd}, 'c', 'vec_simd.c');
    my $c_buf;
    if (-f $c_path) {
        $c_buf = $ed->open_file($c_path, no_switch => 1);
    }
    else {
        $c_buf = $ed->create_buffer(
            name     => 'vec_simd.c',
            path     => 'c/vec_simd.c',
            filetype => 'c',
            text     => <<'END_C',
#include "vec_simd.h"
#include "power_arch.h"
#include <math.h>

float npl_vec_dot_f32(const float *a, const float *b, size_t n) {
    float acc0 = 0.0f, acc1 = 0.0f, acc2 = 0.0f, acc3 = 0.0f;
    size_t i = 0;
#if defined(__VSX__) && !defined(NPL_SCALAR_ONLY)
    __vector float v0 = {0.0f, 0.0f, 0.0f, 0.0f};
    for (; i + 4 <= n; i += 4) {
        __vector float va = vec_xl(0, a + i);
        __vector float vb = vec_xl(0, b + i);
        v0 = vec_madd(va, vb, v0);
    }
    acc0 = v0[0] + v0[1] + v0[2] + v0[3];
#else
    for (; i + 4 <= n; i += 4) {
        acc0 += a[i]     * b[i];
        acc1 += a[i + 1] * b[i + 1];
        acc2 += a[i + 2] * b[i + 2];
        acc3 += a[i + 3] * b[i + 3];
    }
#endif
    float sum = (acc0 + acc1) + (acc2 + acc3);
    for (; i < n; i++) sum += a[i] * b[i];
    return sum;
}
END_C
        );
    }

    my $perl_buf = $ed->create_buffer(
        name     => 'Scheduler.pm',
        path     => 'lib/NeoPerl/Demo/Scheduler.pm',
        filetype => 'perl',
        text     => $perl_src,
    );

    # Remove initial empty [No Name] scratch buffer so tabline shows only real demo files
    for my $b ($ed->list_buffers) {
        if (($b->name // '') eq '[No Name]' && !defined($b->path)) {
            $ed->switch_buffer($perl_buf->id);
            $ed->delete_buffer($b->id, force => 1);
            last;
        }
    }

    # Seed realistic inference slots, Bonsai jobs (targeting standalone source snippets), Vision cache
    if ($self->{inference}) {
        eval { $self->{inference}->ensure_loaded('embedder') };
        eval { $self->{inference}->ensure_loaded('worker_small') };
        eval { $self->{inference}->record_cloud_tokens_saved(4820) };
    }
    if ($self->{offload_queue}) {
        my $saved_ed = $self->{offload_queue}{editor};
        $self->{offload_queue}{editor} = undef; # keep demo jobs detached from scratch buffer
        eval {
            $self->{offload_queue}->enqueue(
                kind          => 'doc',
                target_path   => 'lib/NeoPerl/Buffer.pm',
                source_code   => "package NeoPerl::Demo;\nuse strict;\nuse warnings;\nsub apply_hunk { return 1; }\n1;\n",
                instruction   => 'Add concise POD documentation for apply_hunk',
                verify_syntax => 1,
            );
            $self->{offload_queue}->enqueue(
                kind          => 'refactor_local',
                target_path   => 'lib/NeoPerl/Plugin/PerlDev.pm',
                source_code   => "sub check_value {\n    return undef;\n}\n1;\n",
                instruction   => 'Fix Subroutines::ProhibitExplicitReturnUndef',
                verify_syntax => 1,
            );
            $self->{offload_queue}->pump(4);
        };
        $self->{offload_queue}{editor} = $saved_ed;
    }
    if ($self->{vision}) {
        push @{ $self->{vision}{recent_docs} }, {
            filename => 'arch_diagram.png',
            format   => 'markdown',
            cached   => 1,
            pages    => 1,
        }, {
            filename => 'power8_pmu_spec.pdf',
            format   => 'table_json',
            cached   => 1,
            pages    => 3,
        };
    }

    if ($scene eq 'aix_nvim_embed') {
        my $nb = $self->_init_nvim_engine();
        my @nvim_lines = (
            'package NeoPerl::Demo::Scheduler;',
            '',
            'use strict;',
            'use warnings;',
            '',
            'use NeoPerl::Core qw(:tokens);',
            '',
            '# Live embedded upstream Neovim (--embed ext_linegrid over C11 Msgpack-RPC)',
            'sub new {',
            '    my ($class, %opts) = @_;',
            '    return bless {',
            '        workers => $opts{workers} || 4,',
            '        budget  => $opts{ram_budget_gb} || 20,',
            '        queue   => [],',
            '    }, $class;',
            '}',
            '',
            'sub dispatch_task {',
            '    my ($self, $job) = @_;',
            '    return unless ref($job) eq "HASH";',
            '    $job->{queued_at} //= time();',
            '    push @{ $self->{queue} }, $job;',
            '    return scalar @{ $self->{queue} };',
            '}',
            '',
            'sub flush_ready {',
            '    my ($self) = @_;',
            '    my $n = 0;',
            '    while (my $job = shift @{ $self->{queue} }) {',
            '        $n++ if $job->{ready};',
            '    }',
            '    return $n;',
            '}',
            '1;',
        );
        $nb->buf_set_lines(0, 0, -1, \@nvim_lines);
        eval { $nb->command('setlocal noswapfile buftype=nofile | silent! file Scheduler.pm | setlocal filetype=perl number cursorline') };
        $nb->apply_theme($ed->theme);
        my $ns = eval { $nb->create_namespace('neoperl_demo') };
        if (defined $ns) {
            eval {
                $nb->buf_set_extmark(0, $ns, 20, 4, {
                    virt_text     => [ [ '  [EditorMCP: synced via nvim_buf_set_extmark]', 'DiagnosticInfo' ] ],
                    virt_text_pos => 'eol',
                });
            };
        }
        eval { $nb->win_set_cursor(0, 21, 4) };
        $nb->sync(0.05);

        my $nver = $nb->version_string;
        if ($self->{modalities}) {
            my $m = $self->{modalities};
            $m->{thought_cards} = [
                { text => "Connected to live Neovim $nver over C11 Msgpack-RPC ext_linegrid...", collapsed => 1 },
            ];
            $m->{tool_cards} = [
                { id => 'tc-1', title => "neoperl_get_editor_state (NVIM $nver)", status => 'completed' },
                { id => 'tc-2', title => 'neoperl_read_buffer (nvim_buf_get_lines)', status => 'completed' },
                { id => 'tc-3', title => 'neoperl_propose_edit (extmark staged)',   status => 'completed' },
            ];
            $m->{plan_entries} = [
                { content => 'Attach Neovim ext_linegrid over C11 Msgpack-RPC', status => 'completed' },
                { content => 'Apply AIX Amber RGB highlights + IBM Plex Mono',  status => 'completed' },
                { content => 'Bridge EditorMCP tools to live embedded buffer',  status => 'in_progress' },
            ];
            $m->{chat_messages} = [
                { role => 'user', text => '/inspect Verify dispatch_task in embedded Neovim buffer' },
                { role => 'assistant', streaming => 0, text => sprintf("Read %d live lines directly from embedded Neovim (%s) via Msgpack-RPC. Placed an inline DiagnosticInfo extmark on line 21 and synced EditorMCP state alongside the AIX Amber Command Center.", scalar(@nvim_lines), $nver) },
            ];
            $m->{active_perm} = {
                id    => 'perm-nvim-1',
                tool  => 'neoperl_propose_edit',
                title => 'Apply staged diff to embedded Neovim buffer?',
            };
        }
        $layout->open_command_center('chat');
    }
    elsif ($scene eq 'aix_mainframe_db') {
        my $hlasm_buf = $ed->create_buffer(
            name     => 'NNPASVC.hlasm',
            path     => 'z/NNPASVC.hlasm',
            filetype => 'hlasm',
            text     => <<'END_HLASM',
* IBM z17 Telum II NNPA + DSECT Control Block Service
NNPASVC  CSECT
NNPASVC  AMODE 64
NNPASVC  RMODE ANY
         STMG  R14,R12,8(R13)        Save caller 64-bit registers
         LARL  R12,NNPASVC           Establish relative base
         USING TNSRBLK,R2            Map tensor parameter block
         LG    R4,TNSRADDR           Load tensor descriptor address
         LA    R0,X'01'              NNPA function code: QAF / MATMUL
         NNPA                        Invoke Telum II AI Accelerator
         BRC   1,NNPABUSY            Retry if CC=1 partial completion
         LMG   R14,R12,8(R13)        Restore caller registers
         BR    R14                   Return to caller
NNPABUSY DS    0H
         LAY   R5,4096(,R2)          20-bit long-displacement access
         BR    R14
TNSRBLK  DSECT
TNSREYE  DC    CL8'TNSRBLK '         Eyecatcher
TNSRFLG  DS    H                     Flags
TNSRADDR DS    AD                    64-bit aligned tensor ptr
TNSRLEN  EQU   *-TNSRBLK             Total DSECT length
         END   NNPASVC
END_HLASM
        );

        my $cobol_buf = $ed->create_buffer(
            name     => 'ACCTPOST.cbl',
            path     => 'cobol/ACCTPOST.cbl',
            filetype => 'cobol',
            text     => <<'END_COBOL',
       IDENTIFICATION DIVISION.
       PROGRAM-ID. ACCTPOST.
      * Db2 for z/OS DCLGEN Ledger Posting Program
       DATA DIVISION.
       WORKING-STORAGE SECTION.
           EXEC SQL INCLUDE SQLCA END-EXEC.
           EXEC SQL DECLARE ACCT_LEDGER TABLE
             ( ACCT_ID     INTEGER NOT NULL,
               BALANCE_AMT DECIMAL(11,2) NOT NULL,
               STATUS_CD   CHAR(2) NOT NULL )
           END-EXEC.
       01  DCL-ACCT-LEDGER.
           10 ACCT-ID              PIC S9(9) COMP.
           10 BALANCE-AMT          PIC S9(9)V99 COMP-3.
           10 STATUS-CD            PIC X(2).
       PROCEDURE DIVISION.
       MAIN-PARA.
           EXEC SQL
               SELECT BALANCE_AMT INTO :BALANCE-AMT
                 FROM ACCT_LEDGER
                WHERE ACCT_ID = :ACCT-ID
                 WITH UR
           END-EXEC.
           IF SQLCODE = 0
               DISPLAY 'POSTED: ' BALANCE-AMT
           END-IF.
           STOP RUN.
END_COBOL
        );

        $ed->switch_buffer($hlasm_buf->id);
        $layout->vsplit($cobol_buf->id, ratio => 0.50, focus => 0);

        if ($self->{mcp_registry}) {
            eval { $self->{mcp_registry}->enable_pack([qw(db2z hlasm cobol)]) };
        }
        $ed->set_diagnostics($hlasm_buf, 'lsp_builtin', [
            { line => 9, col => 9, severity => 'info', code => 'HLASM-NNPA', message => 'NNPA (B93B) requires Arch14/z16 Telum or z17 Telum II; CC=1 retry branch verified' },
        ]);
        $ed->set_diagnostics($cobol_buf, 'compiler_cobc', [
            { line => 12, col => 11, severity => 'info', code => 'COMP-3', message => 'PIC S9(9)V99 COMP-3 packed decimal occupies 6 bytes (offset +4)' },
        ]);

        $self->{memory_query} = 'Db2 z/OS DCLGEN PLAN_TABLE NNPA';
        $layout->open_command_center('memory');
        if ($ed->current_window) {
            $ed->current_window->set_cursor(9, 9);
        }
    }
    elsif ($scene eq 'aix_gpu_asm') {
        my $asm_buf = $ed->create_buffer(
            name     => 'telum_power_simd.s',
            path     => 'asm/telum_power_simd.s',
            filetype => 'asm',
            text     => <<'END_ASM',
# Multi-ISA Hot Kernel: IBM POWER8+/10 VSX/MMA & s390x Telum II NNPA
.text
.globl vec_dot_power10_mma
vec_dot_power10_mma:
    xxsetaccz  0                 # Zero 512-bit MMA accumulator acc0
    lxv        32, 0(3)          # Load 4x f32 vector A (r3)
    lxv        33, 0(4)          # Load 4x f32 vector B (r4)
    xvf32gerpp 0, 32, 33         # Outer-product rank-1 FP32 accumulate
    xvmaddasp  34, 32, 33        # POWER8+ VSX 4-way fused multiply-add
    lwsync                       # Acquire/release barrier for ppc64le
    blr

.globl telum2_nnpa_matmul
telum2_nnpa_matmul:
    lmg        %r6, %r15, 48(%r15)
    vlm        %v0, %v3, 0(%r2)  # Load s390x 128-bit VXE2 vectors
    vfmasb     %v4, %v0, %v1, %v2
    nnpa                         # z16/z17 Telum II B93B AI MatMul
    bcr        14, 0             # Fast serialization fence
    br         %r14
END_ASM
        );

        my $metal_buf = $ed->create_buffer(
            name     => 'gemm_tile.metal',
            path     => 'shaders/gemm_tile.metal',
            filetype => 'metal',
            text     => <<'END_METAL',
#include <metal_stdlib>
using namespace metal;

struct VertexABI {
    packed_float3 pos;   // 12-byte tight C ABI (avoids 16B float3 trap)
    half2         uv;    // 2x Apple Silicon FP16 ALU throughput
};

kernel void gemm_simd8x8(
    device const half *A [[buffer(0)]],
    device const half *B [[buffer(1)]],
    device float      *C [[buffer(2)]],
    uint2 gid            [[thread_position_in_grid]])
{
    simdgroup_half8x8  ma;
    simdgroup_half8x8  mb;
    simdgroup_float8x8 acc = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
    simdgroup_load(ma, A, 64);
    simdgroup_load(mb, B, 64);
    simdgroup_multiply_accumulate(acc, ma, mb, acc);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    simdgroup_store(acc, C, 64);
}
END_METAL
        );

        $ed->switch_buffer($asm_buf->id);
        $layout->vsplit($metal_buf->id, ratio => 0.50, focus => 0);

        if ($self->{mcp_registry}) {
            eval { $self->{mcp_registry}->enable_pack([qw(asm metal)]) };
        }
        if ($self->{xsdev}) {
            my $fname = $asm_buf->path;
            my $cg_raw = join("\n",
                'events: Ir D1mr DLmr Bcm',
                "fl=$fname",
                'fn=vec_dot_power10_mma',
                '5 42000 110 20 5',
                '6 185000 4100 1200 40',
                '7 210000 4800 1600 55',
                '8 620000 14200 5900 180',
                '9 490000 9400 3100 95',
                '18 540000 8100 2200 60',
                'summary: 2087000 40710 14020 435',
                '',
            );
            my $prof = $self->{xsdev}->profiler->parse_cachegrind_raw($cg_raw, no_map => 1);
            $self->{xsdev}->profiler->paint_heatbars($asm_buf, $prof, file_path => $fname);
        }

        $layout->open_command_center('xsdev');
        if (($opts{float} // 'telescope') eq 'telescope' && $self->{telescope}) {
            $self->{telescope}->files($self->{cwd});
            $self->{telescope}->set_query('metal');
        }
    }
    elsif ($scene eq 'xs_cachegrind' || $scene eq 'xsdev') {
        $ed->switch_buffer($c_buf->id);
        my $win = $ed->current_window;

        # Locate the VSX/NEON SIMD kernel function line so heatbars sit on real C11 SIMD loops
        my $base_ln = 5;
        my $total_l = $c_buf->line_count || 1;
        for my $ln (0 .. ($total_l > 300 ? 300 : $total_l - 1)) {
            my $txt = $c_buf->get_line($ln) // '';
            if ($txt =~ /\b(?:dot_f32_vsx|dot_f32_neon|npl_vec_dot_f32|dot_f32_scalar_exact)\s*\(/) {
                $base_ln = $ln + 1; # 1-based
                last if $txt =~ /dot_f32_vsx|dot_f32_neon/;
            }
        }
        if ($win) {
            $win->scroll_top($base_ln > 3 ? $base_ln - 3 : 0);
            $win->set_cursor($base_ln + 9, 8);
        }

        # Paint realistic Cachegrind gutter heatbars onto c_buf (on the hot vec_madd SIMD loop)
        if ($self->{xsdev}) {
            my $fname = $c_buf->path || 'c/vec_simd.c';
            my $l1 = $base_ln + 7;  # size_t i = 0;
            my $l2 = $base_ln + 8;  # for (; i + 16 <= dim; i += 16)
            my $l3 = $base_ln + 9;  # v0 = vec_madd(...)
            my $l4 = $base_ln + 10; # v1 = vec_madd(...)
            my $l5 = $base_ln + 11; # v2 = vec_madd(...)
            my $l6 = $base_ln + 12; # v3 = vec_madd(...)
            my $cg_raw = join("\n",
                'events: Ir D1mr DLmr Bcm',
                "fl=$fname",
                'fn=dot_f32_vsx',
                "$l1 42000 110 20 8",
                "$l2 185000 4200 1840 120",
                "$l3 584000 12400 5420 290",
                "$l4 312000 7800 3210 185",
                "$l5 240000 4800 1900 110",
                "$l6 95000 1100 340 42",
                'summary: 1458000 30410 12730 755',
                '',
            );
            my $prof = $self->{xsdev}->profiler->parse_cachegrind_raw($cg_raw, no_map => 1);
            $self->{xsdev}->profiler->paint_heatbars($c_buf, $prof, file_path => $fname);

            my $dbg = $self->{xsdev}->debugger;
            $dbg->set_breakpoint($fname, $l2);
            $dbg->set_breakpoint($fname, $l6);
            $dbg->{state}{active}      = 1;
            $dbg->{state}{backend}     = ($^O eq 'darwin') ? 'lldb' : 'gdb';
            $dbg->{state}{pc_file}     = $fname;
            $dbg->{state}{pc_line}     = $l3;
            $dbg->{state}{backtrace}   = [
                { level => 0, func => 'dot_f32_vsx',           file => 'c/vec_simd.c', line => $l3 },
                { level => 1, func => 'npl_vec_topk_cosine',   file => 'c/vec_simd.c', line => 198 },
                { level => 2, func => 'XS_NeoPerl__Core_topk', file => 'Core.xs',      line => 842 },
            ];
            $dbg->{state}{locals} = [
                { name => 'n',    value => '768' },
                { name => 'acc0', value => '0.9418f' },
                { name => 'simd', value => '"VSX/NEON"' },
            ];
            $dbg->{state}{threads} = [
                { id => 1, name => 'main_perl', state => 'stopped' },
                { id => 2, name => 'MT::Worker-1', state => 'running' },
            ];
            $dbg->{state}{sv_inspector} = [
                { expr => 'query_sv', sv_type => 'PV', flags => 'POK,pPOK', pv => 'f32[768] (3072B)' },
            ];
            $dbg->{state}{power_registers} = {
                gpr => { r3 => '0x00007fff94a01000', r4 => '0x00007fff94a02000', r5 => '0x0000000000000300', lr => '0x0000000100048b20' },
                vsx => { vs32 => '{0.241, 0.238, 0.232, 0.231}', vs33 => '{0.985, 0.112, 0.044, 0.091}' },
            };
            $dbg->paint_debug_marks($c_buf, file_path => $fname);

            $self->{xsdev}->pgo->{last_report} = {
                ok          => 1,
                family      => ($^O eq 'darwin') ? 'clang' : 'gcc',
                baseline_ms => 44.60,
                pgo_ms      => 36.25,
                speedup_pct => 18.7,
            };
        }

        $layout->open_command_center('xsdev');
        if (($opts{float} // 'telescope') eq 'telescope' && $self->{telescope}) {
            $self->{telescope}->files($self->{cwd});
            $self->{telescope}->set_query('simd');
        }
    }
    elsif ($scene eq 'memory' || $scene eq 'models' || $scene eq 'memory_bonsai') {
        $self->{memory_query} = 'Db2 VECTOR cosine VSX SIMD';
        $ed->switch_buffer($perl_buf->id);
        $ed->set_diagnostics($perl_buf, 'perlcritic', [
            { line => 18, col => 4, severity => 'warn', code => 'Subroutines::ProhibitExplicitReturnUndef', message => 'Explicit return of undef; use bare return' },
        ]);
        $perl_buf->set_ghost_text(20, 4, '    # staged locally by Ternary-Bonsai-2-27B');

        my $want_tab = $opts{tab} || ($scene eq 'models' ? 'jobs' : 'memory');
        $layout->open_command_center($want_tab);

        if (($opts{float} // ($scene eq 'memory_bonsai' ? 'inline' : 'none')) eq 'inline') {
            $layout->open_float(
                kind     => 'inline_prompt',
                title    => ' Antigravity Inline (Ctrl-I) ',
                footer   => ' <CR> Stage Diff | <Tab> Local Bonsai | <Esc> Cancel ',
                border   => 'rounded',
                relative => 'center',
                width    => 62,
                height   => 6,
                zindex   => 88,
                meta     => {
                    text         => 'Fix ProhibitExplicitReturnUndef and add queued_at timestamp',
                    context_hint => 'PPI slice: sub dispatch_task (L16-L22) + Db2 repo conventions',
                },
            );
        }
    }
    else {
        # Default demo scene: chat_diff (multi-split Perl + C, LSP/Critic diags, inline red/green diff hunks, CHAT tab + Permission Bar)
        $ed->switch_buffer($perl_buf->id);
        $layout->vsplit($c_buf->id, ratio => 0.56, focus => 0);

        $ed->set_diagnostics($perl_buf, 'perlcritic', [
            { line => 10, col => 8, severity => 'info', code => 'ValuesAndExpressions::ProhibitMagicNumbers', message => 'Prefer named constant for default RAM budget' },
            { line => 26, col => 4, severity => 'warn', code => 'Subroutines::RequireArgUnpacking', message => 'Consider validating queue state before flush' },
        ]);

        # Stage interactive red/green inline diff hunk on Perl buffer
        $perl_buf->stage_diff_proposal($perl_proposed, source => 'antigravity', skip_hooks => 1);
        $ed->current_window->set_cursor(18, 4) if $ed->current_window;

        # Populate Antigravity Chat state and Permission Bar
        if ($self->{modalities}) {
            my $m = $self->{modalities};
            $m->{thought_cards} = [
                { text => 'Checking Perl::Critic diagnostics and Db2 repo conventions for dispatch_task...', collapsed => 1 },
            ];
            $m->{tool_cards} = [
                { id => 'tc-1', title => 'neoperl_memory_search ("Db2 VECTOR")', status => 'completed' },
                { id => 'tc-2', title => 'neoperl_perl_critic (Scheduler.pm)',    status => 'completed' },
                { id => 'tc-3', title => 'neoperl_delegate_local (Bonsai POD)',   status => 'completed' },
            ];
            $m->{plan_entries} = [
                { content => 'Replace explicit return undef in dispatch_task', status => 'completed' },
                { content => 'Stamp queued_at timestamp on enqueued jobs',      status => 'in_progress' },
                { content => 'Run perl -c and Perl::Critic verification',       status => 'pending' },
            ];
            $m->{chat_messages} = [
                { role => 'user', text => '/fix Resolve Perl::Critic warning in @buffer and stamp queued_at' },
                { role => 'assistant', streaming => 0, text => "Staged a 1-hunk inline diff in Scheduler.pm replacing `return undef` with bare `return` and adding `queued_at`. Offloaded POD generation to local Ternary-Bonsai (+4.8k cloud tokens saved)." },
            ];
            $m->{active_perm} = {
                id    => 'perm-demo-1',
                tool  => 'fs/write_text_file',
                title => 'Apply staged diff to Scheduler.pm?',
            };
        }
        $layout->open_command_center('chat');
    }

    # Apply explicit overrides if passed on CLI
    if (defined $opts{explorer}) {
        $layout->explorer_open($opts{explorer} ? 1 : 0);
    }
    if (defined $opts{tab} && length $opts{tab}) {
        if (lc($opts{tab}) eq 'none') {
            $layout->close_command_center();
        }
        else {
            $layout->open_command_center($opts{tab});
        }
    }
    if (defined $opts{float} && $opts{float} eq 'whichkey' && $self->{whichkey}) {
        $self->{whichkey}->show('<leader>');
    }
    elsif (defined $opts{float} && $opts{float} eq 'telescope' && $self->{telescope} && !$self->{telescope}->is_open) {
        $self->{telescope}->files($self->{cwd});
        $self->{telescope}->set_query('simd');
    }
    elsif (defined $opts{float} && $opts{float} eq 'inline' && !$layout->get_float_by_kind('inline_prompt')) {
        $layout->open_float(
            kind     => 'inline_prompt',
            title    => ' Antigravity Inline (Ctrl-I) ',
            footer   => ' <CR> Stage Diff | <Tab> Local Bonsai | <Esc> Cancel ',
            border   => 'rounded',
            relative => 'center',
            width    => 62,
            height   => 6,
            zindex   => 88,
            meta     => {
                text         => 'Refactor loop to honor PERL_FORCE_SCALAR=1 parity',
                context_hint => 'Scope: current function + Db2 repo conventions',
            },
        );
    }

    $ed->notify("NeoPerl::MT demo scene '$scene' ready", 'info');
    return 1;
}

sub run {
    my ($self) = @_;
    return 0 unless $self->{ui};
    return $self->{ui}->run();
}

sub export_screenshot {
    my ($self, $path) = @_;
    die "export_screenshot requires GPU UI mode" unless $self->{ui} && $self->{ui}->can('export_png');
    return $self->{ui}->export_png($path);
}

sub shutdown {
    my ($self) = @_;
    return 1 if $self->{_shutting_down};
    $self->{_shutting_down} = 1;

    eval { $self->{ui}->shutdown() }            if $self->{ui}            && $self->{ui}->can('shutdown');
    eval { $self->{nvim_bridge}->close() }      if $self->{nvim_bridge}   && $self->{nvim_bridge}->can('close');
    eval { $self->{rpc}->stop() }               if $self->{rpc}           && $self->{rpc}->can('stop');
    eval { $self->{acp}->stop() }               if $self->{acp}           && $self->{acp}->can('stop');
    eval { $self->{editor_mcp}->stop() }        if $self->{editor_mcp}    && $self->{editor_mcp}->can('stop');
    eval { $self->{lsp}->stop_all() }           if $self->{lsp}           && $self->{lsp}->can('stop_all');
    eval { $self->{offload_queue}->shutdown() } if $self->{offload_queue} && $self->{offload_queue}->can('shutdown');
    eval { $self->{inference}->shutdown_all() } if $self->{inference}     && $self->{inference}->can('shutdown_all');
    eval { $self->{xsdev}->shutdown() }         if $self->{xsdev}         && $self->{xsdev}->can('shutdown');
    eval { $self->{perldev}->worker->shutdown() } if $self->{perldev} && $self->{perldev}->worker && $self->{perldev}->worker->can('shutdown');
    eval { $self->{memory_store}->close() }     if $self->{memory_store}  && $self->{memory_store}->can('close');
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    local ($@, $!, $?);
    return if ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT';
    eval { $self->shutdown() };
    return;
}

1;

__END__

=head1 NAME

NeoPerl::MT - Top-level runtime wiring Neovim core, AI/Db2/PerlDev/XSDev plugins, and dual UIs

=head1 SYNOPSIS

    use NeoPerl::MT;

    my $app = NeoPerl::MT->new(
        cwd      => '.',
        ui       => 'auto',
        backend  => 'auto',
        agy_mock => 1,
    );
    $app->open_files('lib/NeoPerl/MT.pm');
    $app->run();

=head1 DESCRIPTION

Assembles L<NeoPerl::Editor>, built-in Neovim plugins (Telescope, Explorer,
LSP, Git, WhichKey, Themes), the IBM Db2 12.1.2+ semantic memory store and
C<Hy-Memory> writer, the hybrid C<llama.cpp> inference manager, Granite-Vision
document preprocessor, out-of-band Ternary-Bonsai offload queue, bidirectional
Antigravity ACP client and 23-tool Editor MCP server, live C<PerlDev> and
C<XSDev> workbenches, optional C<--listen> JSON-RPC server, and either
L<NeoPerl::UI::GPU> or L<NeoPerl::UI::TUI>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
