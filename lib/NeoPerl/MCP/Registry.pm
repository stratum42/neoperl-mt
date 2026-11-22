package NeoPerl::MCP::Registry;

use strict;
use warnings;
use Carp qw(croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();

our $VERSION = '0.01';

my @PACK_ORDER = qw(
    db2i
    db2luw
    db2z
    informix
    hlasm
    rpgile
    cobol
    asm
    intel_gpu
    amd_gpu
    vulkan
    metal
);

my %PACK_CLASS = (
    db2i      => 'NeoPerl::MCP::Pack::Db2i',
    db2luw    => 'NeoPerl::MCP::Pack::Db2LUW',
    db2z      => 'NeoPerl::MCP::Pack::Db2z',
    informix  => 'NeoPerl::MCP::Pack::Informix',
    hlasm     => 'NeoPerl::MCP::Pack::HLASM',
    rpgile    => 'NeoPerl::MCP::Pack::RPGILE',
    cobol     => 'NeoPerl::MCP::Pack::COBOL',
    asm       => 'NeoPerl::MCP::Pack::AsmMultiArch',
    intel_gpu => 'NeoPerl::MCP::Pack::IntelGPU',
    amd_gpu   => 'NeoPerl::MCP::Pack::AMDGPU',
    vulkan    => 'NeoPerl::MCP::Pack::VulkanDev',
    metal     => 'NeoPerl::MCP::Pack::MetalDev',
);

my %PACK_ALIASES = (
    db2_i         => 'db2i',
    ibmi          => 'db2i',
    as400         => 'db2i',
    db2_luw       => 'db2luw',
    luw           => 'db2luw',
    db2_z         => 'db2z',
    db2zos        => 'db2z',
    zos           => 'db2z',
    ids           => 'informix',
    spl           => 'informix',
    hlasm         => 'hlasm',
    zasm          => 'hlasm',
    rpg           => 'rpgile',
    rpgle         => 'rpgile',
    sqlrpgle      => 'rpgile',
    cbl           => 'cobol',
    cob           => 'cobol',
    asm_multiarch => 'asm',
    multiarch     => 'asm',
    power         => 'asm',
    ppc64le       => 'asm',
    s390x         => 'asm',
    amd64         => 'asm',
    arm64         => 'asm',
    sycl          => 'intel_gpu',
    oneapi        => 'intel_gpu',
    opencl        => 'intel_gpu',
    intel         => 'intel_gpu',
    rocm          => 'amd_gpu',
    hip           => 'amd_gpu',
    amd           => 'amd_gpu',
    glsl          => 'vulkan',
    spirv         => 'vulkan',
    vk            => 'vulkan',
    msl           => 'metal',
    apple_metal   => 'metal',
);

sub canonical_pack_names {
    return [ @PACK_ORDER ];
}

sub canonical_name {
    my ($class_or_self, $raw) = @_;
    return undef unless defined $raw && length $raw;
    my $k = lc($raw);
    $k =~ s/\A\s+|\s+\z//g;
    $k =~ s/-/_/g;
    return $k if exists $PACK_CLASS{$k};
    return $PACK_ALIASES{$k} if exists $PACK_ALIASES{$k};
    return undef;
}

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor     => $opts{editor},
        editor_mcp => $opts{editor_mcp},
        telescope  => $opts{telescope},
        pack_opts  => ref($opts{pack_opts}) eq 'HASH' ? { %{ $opts{pack_opts} } } : {},
        dsn        => $opts{dsn},
        user       => $opts{user},
        pass       => $opts{pass},
        read_only  => exists($opts{read_only}) ? ($opts{read_only} ? 1 : 0) : 1,
        packs      => {},
        load_err   => {},
        active     => {},
        pack_order => [ @PACK_ORDER ],
    }, $class;

    if ($self->{editor_mcp} && $self->{editor_mcp}->can('attach_pack_registry')) {
        $self->{editor_mcp}->attach_pack_registry($self);
    }

    if ($opts{editor}) {
        $self->attach($opts{editor}, telescope => $opts{telescope});
    }

    if (ref($opts{auto_enable}) eq 'ARRAY') {
        for my $p (@{ $opts{auto_enable} }) {
            $self->enable_pack($p);
        }
    }
    elsif (defined $opts{auto_enable} && $opts{auto_enable} eq 'all') {
        $self->enable_all();
    }

    return $self;
}

sub editor     { $_[0]{editor} }
sub editor_mcp { $_[0]{editor_mcp} }

sub set_editor_mcp {
    my ($self, $mcp) = @_;
    $self->{editor_mcp} = $mcp;
    $mcp->attach_pack_registry($self) if $mcp && $mcp->can('attach_pack_registry');
    return $self;
}

sub pack_names {
    my ($self) = @_;
    return [ @{ $self->{pack_order} } ];
}

sub _load_pack {
    my ($self, $name) = @_;
    my $canon = $self->canonical_name($name);
    return undef unless defined $canon;
    return $self->{packs}{$canon} if $self->{packs}{$canon};

    my $mod = $PACK_CLASS{$canon} or return undef;
    (my $file = "$mod.pm") =~ s{::}{/}g;
    my $ok = eval { require $file; 1 };
    if (!$ok) {
        $self->{load_err}{$canon} = "$@";
        return undef;
    }

    my %p_opts = (
        editor    => $self->{editor},
        read_only => $self->{read_only},
        (defined $self->{dsn}  ? (dsn  => $self->{dsn})  : ()),
        (defined $self->{user} ? (user => $self->{user}) : ()),
        (defined $self->{pass} ? (pass => $self->{pass}) : ()),
        %{ $self->{pack_opts}{$canon} || {} },
    );

    my $inst = eval { $mod->new(%p_opts) };
    if (!$inst) {
        $self->{load_err}{$canon} = "$@" || "Failed to construct $mod";
        return undef;
    }

    $self->{packs}{$canon} = $inst;
    delete $self->{load_err}{$canon};
    return $inst;
}

sub get_pack {
    my ($self, $name) = @_;
    return $self->_load_pack($name);
}

sub load_error {
    my ($self, $name) = @_;
    my $canon = $self->canonical_name($name) // $name;
    return $self->{load_err}{$canon};
}

sub is_active {
    my ($self, $name) = @_;
    my $canon = $self->canonical_name($name);
    return 0 unless defined $canon;
    return $self->{active}{$canon} ? 1 : 0;
}

sub active_packs {
    my ($self) = @_;
    return [ grep { $self->{active}{$_} } @{ $self->{pack_order} } ];
}

sub list_packs {
    my ($self) = @_;
    my @out;
    for my $name (@{ $self->{pack_order} }) {
        my $pack = $self->_load_pack($name);
        if ($pack) {
            my $m = $pack->meta || {};
            my $tnames = $pack->list_tool_names || [];
            push @out, {
                name             => $name,
                class            => $PACK_CLASS{$name},
                label            => $m->{label}            // $name,
                category         => $m->{category}         // 'general',
                version          => $m->{version}          // $VERSION,
                description      => $m->{description}      // '',
                filetypes        => $m->{filetypes}        || [],
                upstream_credits => $m->{upstream_credits} || [],
                tool_count       => scalar(@$tnames),
                tools            => $tnames,
                active           => $self->{active}{$name} ? 1 : 0,
                loaded           => 1,
            };
        }
        else {
            push @out, {
                name             => $name,
                class            => $PACK_CLASS{$name},
                label            => $name,
                category         => 'unavailable',
                version          => $VERSION,
                description      => 'Pack module unavailable',
                filetypes        => [],
                upstream_credits => [],
                tool_count       => 0,
                tools            => [],
                active           => 0,
                loaded           => 0,
                error            => $self->{load_err}{$name} // 'not loaded',
            };
        }
    }
    return \@out;
}

sub packs_for_filetype {
    my ($self, $ft) = @_;
    return [] unless defined $ft && length $ft;
    my $want = lc($ft);
    my @matched;
    for my $name (@{ $self->{pack_order} }) {
        my $pack = $self->_load_pack($name) or next;
        my $fts = $pack->filetypes || [];
        for my $f (@$fts) {
            if (lc($f) eq $want) {
                push @matched, $pack;
                last;
            }
        }
    }
    return \@matched;
}

sub enable_pack {
    my ($self, $spec) = @_;
    return { ok => 0, error => 'No pack name specified' }
        unless defined $spec;

    my @tokens;
    if (ref($spec) eq 'ARRAY') {
        @tokens = @$spec;
    }
    else {
        @tokens = grep { length } split /[\s,]+/, $spec;
    }
    return { ok => 0, error => 'No pack name specified' } unless @tokens;

    for my $t (@tokens) {
        return $self->enable_all() if lc($t) eq 'all';
    }

    my @enabled;
    my @errors;
    my $total_tools = 0;

    for my $tok (@tokens) {
        my $canon = $self->canonical_name($tok);
        if (!defined $canon) {
            push @errors, "Unknown MCP pack: $tok";
            next;
        }
        my $pack = $self->_load_pack($canon);
        if (!$pack) {
            push @errors, "Failed to load MCP pack '$canon': " . ($self->{load_err}{$canon} // 'unknown error');
            next;
        }

        my $count = scalar(@{ $pack->list_tool_names });
        if ($self->{editor_mcp}) {
            if ($self->{editor_mcp}->can('mount_pack')) {
                $count = $self->{editor_mcp}->mount_pack($pack);
            }
            else {
                $count = $pack->register_into($self->{editor_mcp});
            }
        }
        $self->{active}{$canon} = 1;
        push @enabled, $canon;
        $total_tools += $count;
    }

    if ($self->{editor} && @enabled) {
        $self->{editor}->notify(
            sprintf('MCP pack(s) enabled: %s (+%d tools)', join(', ', @enabled), $total_tools),
            'info',
        );
    }

    return {
        ok      => (@errors ? 0 : 1),
        enabled => \@enabled,
        tools   => $total_tools,
        active  => $self->active_packs(),
        (@errors ? (errors => \@errors, error => join('; ', @errors)) : ()),
    };
}

sub disable_pack {
    my ($self, $spec) = @_;
    return { ok => 0, error => 'No pack name specified' }
        unless defined $spec;

    my @tokens;
    if (ref($spec) eq 'ARRAY') {
        @tokens = @$spec;
    }
    else {
        @tokens = grep { length } split /[\s,]+/, $spec;
    }
    return { ok => 0, error => 'No pack name specified' } unless @tokens;

    for my $t (@tokens) {
        return $self->disable_all() if lc($t) eq 'all';
    }

    my @disabled;
    my @errors;
    my $removed = 0;

    for my $tok (@tokens) {
        my $canon = $self->canonical_name($tok);
        if (!defined $canon) {
            push @errors, "Unknown MCP pack: $tok";
            next;
        }
        if ($self->{editor_mcp}) {
            if ($self->{editor_mcp}->can('unmount_pack')) {
                $removed += $self->{editor_mcp}->unmount_pack($canon);
            }
            elsif (my $pack = $self->{packs}{$canon}) {
                $removed += $pack->unregister_from($self->{editor_mcp});
            }
        }
        $self->{active}{$canon} = 0;
        push @disabled, $canon;
    }

    if ($self->{editor} && @disabled) {
        $self->{editor}->notify(
            sprintf('MCP pack(s) disabled: %s (-%d tools)', join(', ', @disabled), $removed),
            'info',
        );
    }

    return {
        ok       => (@errors ? 0 : 1),
        disabled => \@disabled,
        removed  => $removed,
        active   => $self->active_packs(),
        (@errors ? (errors => \@errors, error => join('; ', @errors)) : ()),
    };
}

sub toggle_pack {
    my ($self, $name) = @_;
    my $canon = $self->canonical_name($name);
    return { ok => 0, error => "Unknown MCP pack: " . ($name // '<undef>') }
        unless defined $canon;
    return $self->is_active($canon)
        ? $self->disable_pack($canon)
        : $self->enable_pack($canon);
}

sub enable_all {
    my ($self) = @_;
    return $self->enable_pack([ @{ $self->{pack_order} } ]);
}

sub disable_all {
    my ($self) = @_;
    my $cur = $self->active_packs();
    return { ok => 1, disabled => [], removed => 0, active => [] } unless @$cur;
    return $self->disable_pack($cur);
}

sub summary {
    my ($self) = @_;
    my $packs = $self->list_packs();
    my $total_tools = 0;
    my $active_tools = 0;
    for my $p (@$packs) {
        $total_tools  += $p->{tool_count};
        $active_tools += $p->{tool_count} if $p->{active};
    }
    return {
        total_packs  => scalar(@$packs),
        active_packs => $self->active_packs(),
        active_count => scalar(@{ $self->active_packs() }),
        total_tools  => $total_tools,
        active_tools => $active_tools,
    };
}

sub emit_mcp_config {
    my ($self, %opts) = @_;
    my @selected;
    if (ref($opts{packs}) eq 'ARRAY' && @{ $opts{packs} }) {
        for my $p (@{ $opts{packs} }) {
            if (lc($p) eq 'all') {
                @selected = @{ $self->{pack_order} };
                last;
            }
            my $canon = $self->canonical_name($p);
            push @selected, $canon if defined $canon;
        }
    }
    elsif ($opts{include_all}) {
        @selected = @{ $self->{pack_order} };
    }
    else {
        my $act = $self->active_packs();
        @selected = @$act ? @$act : @{ $self->{pack_order} };
    }

    my $command   = $opts{command}   || 'perl';
    my $script    = $opts{script}    || 'bin/npl-mcp';
    my $transport = lc($opts{transport} || 'stdio');
    my $base_port = int($opts{http_base_port} || 8810);

    my %servers;
    my $idx = 0;
    for my $pname (@selected) {
        my $key = "neoperl-$pname";
        if ($transport eq 'http') {
            my $port = $base_port + $idx;
            $servers{$key} = {
                command => $command,
                args    => [ $script, "--pack=$pname", "--http=127.0.0.1:$port" ],
                url     => "http://127.0.0.1:$port/mcp",
            };
        }
        else {
            $servers{$key} = {
                command => $command,
                args    => [ $script, "--pack=$pname", '--stdio' ],
            };
        }
        $idx++;
    }

    my $config = { mcpServers => \%servers };
    my $json   = JSON::PP->new->utf8->canonical(1)->pretty(1)->encode($config);

    my $written_path;
    if (defined $opts{path} && length $opts{path}) {
        my $out_path = $opts{path};
        my $dir = dirname($out_path);
        make_path($dir) if defined $dir && length $dir && !-d $dir;
        open my $fh, '>:raw', $out_path
            or croak "Cannot write MCP config to $out_path: $!";
        print {$fh} $json;
        close $fh;
        $written_path = $out_path;
    }

    return {
        ok           => 1,
        server_count => scalar(keys %servers),
        packs        => \@selected,
        config       => $config,
        json         => $json,
        (defined $written_path ? (path => $written_path) : ()),
    };
}

sub open_picker {
    my ($self, $editor) = @_;
    $editor ||= $self->{editor};
    my $tel = $self->{telescope} || ($editor && $editor->can('plugin') ? $editor->plugin('telescope') : undef);
    my $packs = $self->list_packs();

    if (!$tel || !$tel->can('open_custom')) {
        return {
            ok     => 1,
            packs  => $packs,
            active => $self->active_packs(),
        };
    }

    my @items;
    for my $p (@$packs) {
        my $state = $p->{active} ? 'ON ' : 'OFF';
        my $credits = @{ $p->{upstream_credits} || [] }
            ? 'Credits: ' . join(', ', @{ $p->{upstream_credits} })
            : 'Built-in NeoPerl::MT domain pack';
        my @preview = (
            sprintf('%s (%s) [%s]', $p->{label}, $p->{name}, $p->{active} ? 'ENABLED' : 'DISABLED'),
            sprintf('Category: %s  |  Tools: %d  |  Filetypes: %s',
                $p->{category}, $p->{tool_count}, join(', ', @{ $p->{filetypes} || [] })),
            '',
            $p->{description},
            '',
            'Tools:',
            (map { "  - $_" } @{ $p->{tools} || [] }),
            '',
            $credits,
        );
        push @items, {
            label   => sprintf('[%s] %-10s %-26s (%d tools)', $state, $p->{name}, $p->{label}, $p->{tool_count}),
            detail  => $p->{category},
            badge   => $p->{active} ? 'ON' : 'OFF',
            preview => \@preview,
            data    => $p,
        };
    }

    $tel->open_custom('MCP Domain Packs (Enter to Toggle)', \@items, sub {
        my ($item) = @_;
        my $pname = $item && $item->{data} ? $item->{data}{name} : undef;
        return unless defined $pname;
        $self->toggle_pack($pname);
    }, mode => 'mcp_packs');

    return {
        ok     => 1,
        opened => 1,
        packs  => $packs,
        active => $self->active_packs(),
    };
}

sub attach {
    my ($self, $editor, %opts) = @_;
    return $self unless $editor;
    $self->{editor}    = $editor;
    $self->{telescope} = $opts{telescope} if $opts{telescope};

    $editor->register_plugin('mcp_registry', $self)
        if $editor->can('register_plugin');

    my $ex = $editor->can('excmd') ? $editor->excmd : undef;
    if ($ex && $ex->can('register_command')) {
        $ex->register_command('McpPacks', sub {
            my ($ed) = @_;
            return $self->open_picker($ed);
        }, desc => 'Open Telescope picker to toggle MCP domain packs');

        $ex->register_command('McpPackEnable', sub {
            my ($ed, $ctx) = @_;
            my $arg = $ctx->{args} // '';
            return { ok => 0, message => 'Usage: :McpPackEnable <pack|all>' }
                unless length $arg;
            my $res = $self->enable_pack($arg);
            $res->{message} = $res->{ok}
                ? 'Enabled MCP pack(s): ' . join(', ', @{ $res->{enabled} || [] })
                : ($res->{error} || 'Enable failed');
            return $res;
        }, desc => 'Mount one or more MCP domain packs into EditorMCP');

        $ex->register_command('McpPackDisable', sub {
            my ($ed, $ctx) = @_;
            my $arg = $ctx->{args} // '';
            return { ok => 0, message => 'Usage: :McpPackDisable <pack|all>' }
                unless length $arg;
            my $res = $self->disable_pack($arg);
            $res->{message} = $res->{ok}
                ? 'Disabled MCP pack(s): ' . join(', ', @{ $res->{disabled} || [] })
                : ($res->{error} || 'Disable failed');
            return $res;
        }, desc => 'Unmount one or more MCP domain packs from EditorMCP');

        $ex->register_command('McpConfigEmit', sub {
            my ($ed, $ctx) = @_;
            my $arg = $ctx->{args} // '';
            $arg =~ s/\A\s+|\s+\z//g;
            my $out_path = length($arg)
                ? $arg
                : File::Spec->catfile($ed->cwd, '.agents', 'mcp_config.json');
            my $res = $self->emit_mcp_config(path => $out_path);
            $ed->notify("Wrote MCP config ($res->{server_count} servers) to $out_path", 'info');
            $res->{message} = "Wrote $out_path";
            return $res;
        }, desc => 'Write .agents/mcp_config.json for standalone bin/npl-mcp packs');
    }

    my $modal = $editor->can('modal') ? $editor->modal : undef;
    if ($modal && $modal->can('map')) {
        $modal->map('n', '<leader>mp', sub { $self->open_picker($editor) },
            desc => 'Toggle MCP domain packs');
    }

    return $self;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Registry - Selective registry and Ex-command manager for all 12 MCP domain packs

=head1 SYNOPSIS

    use NeoPerl::MCP::Registry;
    use NeoPerl::Antigravity::EditorMCP;

    my $mcp = NeoPerl::Antigravity::EditorMCP->new(editor => $editor);
    my $reg = NeoPerl::MCP::Registry->new(
        editor     => $editor,
        editor_mcp => $mcp,
    );

    $reg->enable_pack('db2z');
    $reg->enable_pack('cobol');
    my $cfg = $reg->emit_mcp_config(path => '.agents/mcp_config.json');
    $reg->disable_pack('db2z');

=head1 DESCRIPTION

C<NeoPerl::MCP::Registry> catalogs and selectively mounts the twelve
database, mainframe, multi-ISA assembly, and GPU compute MCP domain packs
(C<db2i>, C<db2luw>, C<db2z>, C<informix>, C<hlasm>, C<rpgile>, C<cobol>,
C<asm>, C<intel_gpu>, C<amd_gpu>, C<vulkan>, C<metal>) into
L<NeoPerl::Antigravity::EditorMCP> or standalone C<bin/npl-mcp> processes.

Selective mounting keeps LLM tool context concise by exposing only the active
domain packs alongside the 23 core editor tools, while exposing C<:McpPacks>,
C<:McpPackEnable>, C<:McpPackDisable>, and C<:McpConfigEmit> inside the editor.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
