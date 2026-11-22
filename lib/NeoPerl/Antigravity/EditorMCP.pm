package NeoPerl::Antigravity::EditorMCP;

use strict;
use warnings;
use Carp qw(croak);
use IO::Socket::INET ();
use IO::Select ();
use File::Spec ();

our $VERSION = '0.01';

my ($HAS_MOJO, $HAS_MOJO_ACCEL);
BEGIN {
    $HAS_MOJO = eval {
        require Mojolicious;
        require Mojo::Server::Daemon;
        require Mojo::IOLoop;
        require Mojo::JSON;
        1;
    } ? 1 : 0;
    $HAS_MOJO_ACCEL = $HAS_MOJO && eval { require Mojo::MT::Accel; 1 } ? 1 : 0;
    require JSON::PP unless $HAS_MOJO;
}

sub _encode_json {
    return $HAS_MOJO ? Mojo::JSON::encode_json($_[0]) : JSON::PP->new->utf8->encode($_[0]);
}

sub _decode_json {
    return $HAS_MOJO ? Mojo::JSON::decode_json($_[0]) : JSON::PP->new->utf8->decode($_[0]);
}

sub _jtrue  { $HAS_MOJO ? Mojo::JSON::true()  : JSON::PP::true }
sub _jfalse { $HAS_MOJO ? Mojo::JSON::false() : JSON::PP::false }

sub has_mojo       { $HAS_MOJO }
sub has_mojo_accel { $HAS_MOJO_ACCEL }

sub new {
    my ($class, %args) = @_;
    my $force_fallback = $args{force_fallback} ? 1 : 0;
    my $use_mojo       = ($HAS_MOJO && !$force_fallback) ? 1 : 0;

    my $self = bless {
        editor          => $args{editor},
        memory_store    => $args{memory_store},
        memory_writer   => $args{memory_writer},
        vision          => $args{vision},
        offload_queue   => $args{offload_queue},
        customizations  => $args{customizations},
        post_tidy_hook  => $args{post_tidy_hook},
        symbol_provider => $args{symbol_provider},
        pack_registry   => $args{pack_registry},
        server_name     => $args{server_name} || 'neoperl-editor-mcp',
        host            => $args{host} || '127.0.0.1',
        use_mojo        => $use_mojo,
        port            => $args{port} || 0,
        bound_port      => undef,
        daemon          => undef,
        app             => undef,
        listen_sock     => undef,
        sel             => undef,
        clients         => {},
        tools           => {},
        tool_order      => [],
        mounted_packs   => {},
        sessions        => {},
        session_seq     => 0,
        request_count   => 0,
        running         => 0,
    }, $class;

    $self->_register_builtin_tools() unless $args{no_builtins};
    return $self;
}

sub port            { $_[0]{bound_port} }
sub host            { $_[0]{host} }
sub is_running      { $_[0]{running} ? 1 : 0 }
sub engine          { $_[0]{use_mojo} ? 'Mojolicious' : 'IO::Socket::INET' }
sub request_count   { $_[0]{request_count} }
sub set_editor      { $_[0]{editor}          = $_[1]; return $_[0] }
sub set_post_tidy   { $_[0]{post_tidy_hook}  = $_[1]; return $_[0] }
sub set_symbol_hook { $_[0]{symbol_provider} = $_[1]; return $_[0] }
sub pack_registry   { $_[0]{pack_registry} }

sub attach_pack_registry {
    my ($self, $registry) = @_;
    $self->{pack_registry} = $registry;
    return $self;
}

sub url {
    my ($self) = @_;
    return undef unless defined $self->{bound_port};
    return "http://$self->{host}:$self->{bound_port}/mcp";
}

sub mounted_packs {
    my ($self) = @_;
    return [ sort keys %{ $self->{mounted_packs} } ];
}

sub info {
    my ($self) = @_;
    return {
        running        => $self->is_running,
        host           => $self->{host},
        port           => $self->{bound_port},
        url            => $self->url,
        engine         => $self->engine,
        server_name    => $self->{server_name},
        tool_count     => scalar(@{ $self->{tool_order} }),
        mounted_packs  => $self->mounted_packs(),
        request_count  => $self->{request_count},
        mojo_accel     => $HAS_MOJO_ACCEL ? 1 : 0,
        simd_tier      => ($HAS_MOJO_ACCEL && defined(&Mojo::MT::Accel::simd_tier))
            ? eval { Mojo::MT::Accel::simd_tier() } : 'none',
    };
}

# --- Extensible Tool Registry (14 built-in + PerlDev 15-18 + XSDev 19-23 + Domain Packs) ---

sub register_tool {
    my ($self, $name, $schema, $handler) = @_;
    croak "register_tool requires name, schema hashref, and handler coderef"
        unless defined $name && length $name
        && ref($schema) eq 'HASH'
        && ref($handler) eq 'CODE';

    my $input_schema = $schema->{inputSchema} || {
        type       => 'object',
        properties => $schema->{properties} || {},
        (ref($schema->{required}) eq 'ARRAY' ? (required => $schema->{required}) : ()),
    };

    if (!exists $self->{tools}{$name}) {
        push @{ $self->{tool_order} }, $name;
    }

    $self->{tools}{$name} = {
        name        => $name,
        description => $schema->{description} // "NeoPerl tool $name",
        inputSchema => $input_schema,
        handler     => $handler,
        pack        => $schema->{pack},
    };
    return 1;
}

sub unregister_tool {
    my ($self, $name) = @_;
    return 0 unless defined $name && exists $self->{tools}{$name};
    delete $self->{tools}{$name};
    $self->{tool_order} = [ grep { $_ ne $name } @{ $self->{tool_order} } ];
    return 1;
}

sub mount_pack {
    my ($self, $pack) = @_;
    croak "mount_pack requires a NeoPerl::MCP::Pack instance"
        unless defined $pack && ref($pack) && $pack->can('meta') && $pack->can('tools');

    my $meta = $pack->meta || {};
    my $pname = $meta->{name} or croak "Pack meta missing 'name'";
    $self->unmount_pack($pname) if exists $self->{mounted_packs}{$pname};

    my @registered;
    my $tools = $pack->tools || [];
    for my $t (@$tools) {
        next unless ref($t) eq 'HASH' && defined $t->{name} && ref($t->{handler}) eq 'CODE';
        my $ctx = {
            editor     => $self->{editor},
            editor_mcp => $self,
            pack       => $pack,
        };
        my $handler = $t->{handler};
        $self->register_tool($t->{name}, {
            description => $t->{description} // "MCP pack tool $t->{name}",
            inputSchema => $t->{inputSchema} || { type => 'object', properties => {} },
            pack        => $pname,
        }, sub {
            my ($args) = @_;
            return $handler->($args || {}, $ctx);
        });
        push @registered, $t->{name};
    }

    $self->{mounted_packs}{$pname} = \@registered;
    return scalar(@registered);
}

sub unmount_pack {
    my ($self, $pname) = @_;
    return 0 unless defined $pname && exists $self->{mounted_packs}{$pname};
    my $names = delete $self->{mounted_packs}{$pname};
    my $removed = 0;
    for my $tname (@{ $names || [] }) {
        $removed += $self->unregister_tool($tname);
    }
    return $removed;
}

sub has_tool {
    my ($self, $name) = @_;
    return exists $self->{tools}{$name} ? 1 : 0;
}

sub list_tool_names {
    my ($self) = @_;
    return [ @{ $self->{tool_order} } ];
}

sub list_tools_schema {
    my ($self) = @_;
    return [
        map {
            my $t = $self->{tools}{$_};
            +{
                name        => $t->{name},
                description => $t->{description},
                inputSchema => $t->{inputSchema},
            }
        } @{ $self->{tool_order} }
    ];
}

sub call_tool_local {
    my ($self, $name, $args) = @_;
    my $tool = $self->{tools}{$name};
    croak "Unknown MCP tool: $name" unless $tool;
    return $tool->{handler}->($args || {});
}

# --- Built-in 14 Core + Memory + Vision + Bonsai MCP Tools ---

sub _editor_buffers {
    my ($self) = @_;
    my $ed = $self->{editor} or return ();
    return $ed->list_buffers if $ed->can('list_buffers');
    if ($ed->can('buffers')) {
        my $b = $ed->buffers;
        return ref($b) eq 'ARRAY' ? @$b : (ref($b) eq 'HASH' ? values(%$b) : ());
    }
    return ();
}

sub _resolve_buffer {
    my ($self, $path) = @_;
    my $ed = $self->{editor};
    return undef unless $ed;
    if (defined $path && length $path) {
        if ($ed->can('find_buffer_by_path')) {
            my $b = $ed->find_buffer_by_path($path);
            return $b if $b;
        }
        for my $b ($self->_editor_buffers) {
            my $bp = eval { $b->path } // '';
            return $b if $bp eq $path;
        }
    }
    return $ed->can('current_buffer') ? $ed->current_buffer() : undef;
}

sub _buf_text {
    my ($buf) = @_;
    return '' unless $buf;
    return $buf->get_text() if $buf->can('get_text');
    return $buf->text()     if $buf->can('text');
    return '';
}

sub _buf_dirty {
    my ($buf) = @_;
    return 0 unless $buf;
    return $buf->is_dirty ? 1 : 0 if $buf->can('is_dirty');
    return $buf->modified ? 1 : 0 if $buf->can('modified');
    return $buf->dirty    ? 1 : 0 if $buf->can('dirty');
    return 0;
}

sub _active_nvim_bridge {
    my ($self) = @_;
    my $ed = $self->{editor} or return undef;
    return undef unless $ed->can('nvim_bridge');
    my $nb = $ed->nvim_bridge or return undef;
    return ($nb->can('is_connected') && eval { $nb->is_connected }) ? $nb : undef;
}

sub _editor_cursor {
    my ($self) = @_;
    if (my $nb = $self->_active_nvim_bridge()) {
        my $nc = eval { $nb->win_get_cursor(0) };
        if (ref($nc) eq 'ARRAY' && @$nc >= 2) {
            return { line => int($nc->[0] || 1), col => int($nc->[1] || 0) };
        }
    }
    my $ed = $self->{editor} or return { line => 1, col => 0 };
    if ($ed->can('current_window')) {
        my $win = $ed->current_window;
        if ($win && $win->can('get_cursor')) {
            my ($l, $c) = $win->get_cursor;
            return { line => ($l // 0) + 1, col => ($c // 0) };
        }
    }
    return $ed->cursor() if $ed->can('cursor');
    return { line => 1, col => 0 };
}

sub _editor_mode {
    my ($self) = @_;
    if (my $nb = $self->_active_nvim_bridge()) {
        return $nb->display_mode();
    }
    my $ed = $self->{editor} or return 'NORMAL';
    if ($ed->can('modal') && $ed->modal && $ed->modal->can('mode')) {
        return $ed->modal->mode;
    }
    return $ed->mode() if $ed->can('mode');
    return 'NORMAL';
}

sub _register_builtin_tools {
    my ($self) = @_;

    # 1. neoperl_get_editor_state
    $self->register_tool('neoperl_get_editor_state', {
        description => 'Return active buffer path, filetype, cursor position, mode, open buffers, and diagnostic summary.',
        properties  => {},
    }, sub {
        my $ed     = $self->{editor};
        my $diags  = ($ed && $ed->can('get_diagnostics')) ? $ed->get_diagnostics()
                   : ($ed && $ed->can('all_diagnostics')) ? $ed->all_diagnostics()
                   : [];

        if (my $nb = $self->_active_nvim_bridge()) {
            my $npath  = eval { $nb->buf_get_name(0) } // '';
            my $nlines = eval { $nb->buf_get_lines(0, 0, -1) } || [];
            my $nft    = eval { $nb->get_option_value('filetype') } || '';
            if (!$nft && length $npath && eval { require NeoPerl::Core; 1 }) {
                $nft = eval { NeoPerl::Core::detect_language($npath) } || 'text';
            }
            $nft ||= 'text';
            my $ndirty = eval { $nb->get_option_value('modified') } ? 1 : 0;
            my $cursor = $self->_editor_cursor();
            my $mode   = $self->_editor_mode();
            return {
                engine           => 'nvim',
                nvim_version     => $nb->version_string,
                mode             => $mode,
                active_path      => $npath,
                active_filetype  => $nft,
                active_dirty     => $ndirty,
                cursor           => $cursor,
                open_buffers     => [
                    {
                        id       => 1,
                        path     => $npath,
                        filetype => $nft,
                        dirty    => $ndirty,
                        lines    => scalar(@$nlines),
                    }
                ],
                diagnostic_count => scalar(@$diags),
            };
        }

        my $buf    = $self->_resolve_buffer();
        my $cursor = $self->_editor_cursor();
        my $mode   = $self->_editor_mode();
        my @open;
        for my $b ($self->_editor_buffers) {
            push @open, {
                id       => eval { $b->id }         // 0,
                path     => eval { $b->path }       // '',
                filetype => eval { $b->filetype }   // 'text',
                dirty    => _buf_dirty($b),
                lines    => eval { $b->line_count } // 0,
            };
        }
        return {
            mode             => $mode,
            active_path      => $buf ? (eval { $buf->path }     // '')     : '',
            active_filetype  => $buf ? (eval { $buf->filetype } // 'text') : 'text',
            active_dirty     => _buf_dirty($buf),
            cursor           => $cursor,
            open_buffers     => \@open,
            diagnostic_count => scalar(@$diags),
        };
    });

    # 2. neoperl_read_buffer
    $self->register_tool('neoperl_read_buffer', {
        description => 'Read live unsaved buffer contents (optional path, 1-based start_line and end_line).',
        properties  => {
            path       => { type => 'string' },
            start_line => { type => 'integer' },
            end_line   => { type => 'integer' },
        },
    }, sub {
        my ($args) = @_;
        if (my $nb = $self->_active_nvim_bridge()) {
            my $npath = eval { $nb->buf_get_name(0) } // '';
            my $req_p = $args->{path};
            my $use_nvim = (!defined($req_p) || !length($req_p) || $req_p eq $npath);
            if ($use_nvim) {
                my $lines  = eval { $nb->buf_get_lines(0, 0, -1) } || [];
                my $dirty  = eval { $nb->get_option_value('modified') } ? 1 : 0;
                my $total  = scalar(@$lines);
                my $s      = int($args->{start_line} || 1);
                my $e      = int($args->{end_line}   || $total);
                $s = 1 if $s < 1;
                $e = $total if $e > $total;
                my $slice = ($s <= $e && $total > 0) ? join("\n", @{$lines}[ ($s - 1) .. ($e - 1) ]) : '';
                return {
                    ok          => 1,
                    path        => $npath,
                    source      => 'nvim_buffer',
                    engine      => 'nvim',
                    dirty       => $dirty,
                    total_lines => $total,
                    start_line  => $s,
                    end_line    => $e,
                    content     => $slice,
                };
            }
        }

        my $buf = $self->_resolve_buffer($args->{path});
        my ($text, $source, $dirty) = ('', 'buffer', 0);

        if ($buf) {
            $text  = _buf_text($buf);
            $dirty = _buf_dirty($buf);
        }
        elsif (defined $args->{path} && -f $args->{path}) {
            open my $fh, '<:encoding(UTF-8)', $args->{path} or croak "Cannot read $args->{path}: $!";
            local $/;
            $text   = <$fh>;
            close $fh;
            $source = 'disk';
        }
        else {
            return { ok => 0, error => 'No matching buffer or readable file' };
        }

        my @lines = split /\n/, $text, -1;
        my $total = scalar(@lines);
        my $s = int($args->{start_line} || 1);
        my $e = int($args->{end_line}   || $total);
        $s = 1 if $s < 1;
        $e = $total if $e > $total;
        my $slice = ($s <= $e && $total > 0) ? join("\n", @lines[ ($s - 1) .. ($e - 1) ]) : '';

        return {
            ok          => 1,
            path        => $buf ? (eval { $buf->path } // ($args->{path} // '')) : ($args->{path} // ''),
            source      => $source,
            dirty       => $dirty,
            total_lines => $total,
            start_line  => $s,
            end_line    => $e,
            content     => $slice,
        };
    });

    # 3. neoperl_propose_edit
    $self->register_tool('neoperl_propose_edit', {
        description => 'Stage a reviewable inline red/green diff proposal against an open buffer (runs optional Perl post-tidy gate).',
        properties  => {
            path        => { type => 'string' },
            new_text    => { type => 'string' },
            title       => { type => 'string' },
            source      => { type => 'string' },
        },
        required => [ 'new_text' ],
    }, sub {
        my ($args) = @_;
        if (my $nb = $self->_active_nvim_bridge()) {
            my $new_text = $args->{new_text} // '';
            my $path     = eval { $nb->buf_get_name(0) } // ($args->{path} // '');
            my $tidied   = 0;
            if ($self->{post_tidy_hook} && $path =~ /\.(?:pm|pl|t)$/i) {
                my $res = eval { $self->{post_tidy_hook}->($new_text, $path) };
                if (defined $res && length $res) {
                    $new_text = $res;
                    $tidied   = 1;
                }
            }
            my $staged = $nb->stage_proposal(
                $new_text,
                source => $args->{source} // 'antigravity',
                title  => $args->{title}  // 'Antigravity Proposed Edit',
            );
            my $hunks = $staged->{hunks} || [];
            my $hcnt  = $staged->{count} // scalar(@$hunks);
            if ($self->{editor} && $self->{editor}->can('emit')) {
                $self->{editor}->emit('AgyProposal',
                    path   => $path,
                    source => $args->{source} // 'antigravity',
                    hunks  => $hcnt,
                    engine => 'nvim',
                );
            }
            return {
                ok          => 1,
                path        => $path,
                engine      => 'nvim',
                staged      => 1,
                post_tidied => $tidied,
                hunk_count  => $hcnt,
                hunks       => $hunks,
            };
        }

        my $buf = $self->_resolve_buffer($args->{path});
        return { ok => 0, error => 'Target buffer not found' } unless $buf;

        my $new_text = $args->{new_text} // '';
        my $path     = eval { $buf->path } // ($args->{path} // '');
        my $tidied   = 0;

        if ($self->{post_tidy_hook} && $path =~ /\.(?:pm|pl|t)$/i) {
            my $res = eval { $self->{post_tidy_hook}->($new_text, $path) };
            if (defined $res && length $res) {
                $new_text = $res;
                $tidied   = 1;
            }
        }

        my $hunks = [];
        my $hcnt  = 0;
        if ($buf->can('stage_diff_proposal')) {
            my $staged = $buf->stage_diff_proposal(
                $new_text,
                source => $args->{source} // 'antigravity',
                title  => $args->{title}  // 'Antigravity Proposed Edit',
            );
            if (ref($staged) eq 'HASH') {
                $hunks = $staged->{hunks} || [];
                $hcnt  = $staged->{count} // scalar(@$hunks);
            }
            elsif (ref($staged) eq 'ARRAY') {
                $hunks = $staged;
                $hcnt  = scalar(@$staged);
            }
        }

        if ($self->{editor} && $self->{editor}->can('emit') && !$buf->isa('NeoPerl::Buffer')) {
            $self->{editor}->emit('AgyProposal',
                path   => $path,
                source => $args->{source} // 'antigravity',
                hunks  => $hcnt,
            );
        }

        return {
            ok          => 1,
            path        => $path,
            staged      => 1,
            post_tidied => $tidied,
            hunk_count  => $hcnt,
            hunks       => $hunks,
        };
    });

    # 4. neoperl_list_diagnostics
    $self->register_tool('neoperl_list_diagnostics', {
        description => 'List active LSP, Perl::Critic, and XS sanitizer diagnostics for a buffer or workspace.',
        properties  => {
            path     => { type => 'string' },
            severity => { type => 'string' },
        },
    }, sub {
        my ($args) = @_;
        my $ed = $self->{editor};
        my $list = [];
        if ($ed && $ed->can('get_diagnostics')) {
            my $buf = defined($args->{path}) ? $self->_resolve_buffer($args->{path}) : undef;
            $list = $ed->get_diagnostics($buf);
        }
        elsif ($ed && $ed->can('all_diagnostics')) {
            $list = $ed->all_diagnostics();
        }
        if (defined $args->{severity} && length $args->{severity}) {
            my $sev = lc($args->{severity});
            $sev = 'warn' if $sev eq 'warning';
            $list = [ grep { my $s = lc($_->{severity} // ''); $s = 'warn' if $s eq 'warning'; $s eq $sev } @$list ];
        }
        return { count => scalar(@$list), diagnostics => $list };
    });

    # 5. neoperl_get_symbols
    $self->register_tool('neoperl_get_symbols', {
        description => 'Extract structured symbol outline (packages, subs, functions, structs) for a buffer.',
        properties  => {
            path => { type => 'string' },
        },
    }, sub {
        my ($args) = @_;
        my $buf = $self->_resolve_buffer($args->{path});
        return { ok => 0, symbols => [] } unless $buf;

        if ($self->{symbol_provider}) {
            my $syms = eval { $self->{symbol_provider}->($buf) };
            return { ok => 1, symbols => $syms } if ref($syms) eq 'ARRAY';
        }
        if ($self->{editor} && $self->{editor}->can('get_symbols')) {
            my $syms = eval { $self->{editor}->get_symbols($buf) };
            return { ok => 1, symbols => $syms } if ref($syms) eq 'ARRAY' && @$syms;
        }

        my $text = _buf_text($buf);
        my $ft   = eval { $buf->filetype } // 'perl';
        if (eval { require NeoPerl::Core; defined(&NeoPerl::Core::Syntax::extract_symbols_text) }) {
            my $syms = eval { NeoPerl::Core::Syntax::extract_symbols_text($ft, $text) };
            return { ok => 1, symbols => $syms } if ref($syms) eq 'ARRAY' && @$syms;
        }

        my @syms;
        my $lno = 0;
        for my $line (split /\n/, $text) {
            $lno++;
            if ($line =~ /^\s*(package|sub)\s+([A-Za-z0-9_:]+)/) {
                my ($kw, $sname) = ($1, $2);
                push @syms, { name => $sname, line => $lno, kind => $kw };
            }
            elsif ($line =~ /^\s*(?:static\s+)?[A-Za-z_][\w\s\*]+?\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*\{?\s*$/) {
                my $fname = $1;
                push @syms, { name => $fname, line => $lno, kind => 'function' };
            }
        }
        return { ok => 1, symbols => \@syms };
    });

    # 6. neoperl_search_workspace
    $self->register_tool('neoperl_search_workspace', {
        description => 'Search workspace files using multi-threaded C11 grep (or fallback scanner).',
        properties  => {
            query => { type => 'string' },
            root  => { type => 'string' },
            limit => { type => 'integer' },
        },
        required => [ 'query' ],
    }, sub {
        my ($args) = @_;
        my $q     = $args->{query} // '';
        my $root  = $args->{root}  || ($self->{editor} && $self->{editor}->can('cwd') ? $self->{editor}->cwd : '.');
        my $limit = int($args->{limit} || 50);

        if (eval { require NeoPerl::Core; defined(&NeoPerl::Core::Fuzzy::grep_dir) }) {
            my $hits = eval { NeoPerl::Core::Fuzzy::grep_dir($root, $q, 1, $limit) };
            return { ok => 1, query => $q, matches => $hits } if ref($hits) eq 'ARRAY';
        }

        # Pure-Perl bounded workspace scan fallback
        my @matches;
        my @queue = ($root);
        while (@queue && @matches < $limit) {
            my $dir = shift @queue;
            opendir(my $dh, $dir) or next;
            my @entries = sort readdir($dh);
            closedir $dh;
            for my $e (@entries) {
                next if $e eq '.' || $e eq '..' || $e eq '.git' || $e eq 'blib' || $e eq 'node_modules';
                my $full = File::Spec->catfile($dir, $e);
                if (-d $full) {
                    push @queue, $full;
                }
                elsif (-f $full && -T $full && (-s $full) < 2_000_000) {
                    open my $fh, '<', $full or next;
                    my $lno = 0;
                    while (my $line = <$fh>) {
                        $lno++;
                        if (index(lc($line), lc($q)) >= 0) {
                            chomp $line;
                            push @matches, { path => $full, line => $lno, text => substr($line, 0, 200) };
                            last if @matches >= $limit;
                        }
                    }
                    close $fh;
                }
                last if @matches >= $limit;
            }
        }
        return { ok => 1, query => $q, matches => \@matches };
    });

    # 7. neoperl_jump_to
    $self->register_tool('neoperl_jump_to', {
        description => 'Open or switch to a file and move cursor to 1-based line and 0-based col.',
        properties  => {
            path => { type => 'string' },
            line => { type => 'integer' },
            col  => { type => 'integer' },
        },
        required => [ 'path' ],
    }, sub {
        my ($args) = @_;
        my $ed   = $self->{editor};
        my $path = $args->{path};
        my $line = int($args->{line} || 1);
        my $col  = int($args->{col}  || 0);
        if ($ed) {
            if ($ed->can('jump_to')) {
                $ed->jump_to($path, $line > 0 ? $line - 1 : 0, $col);
            }
            else {
                $ed->open_file($path) if $ed->can('open_file') && defined $path && -f $path;
                $ed->set_cursor($line, $col) if $ed->can('set_cursor');
            }
        }
        return { ok => 1, path => $path, line => $line, col => $col };
    });

    # 8. neoperl_list_customizations
    $self->register_tool('neoperl_list_customizations', {
        description => 'List discovered Antigravity rules, skills, instructions, hooks, MCP configs, and plugins.',
        properties  => {},
    }, sub {
        return $self->{customizations}
            ? $self->{customizations}->summary()
            : { instructions => [], rules => [], skills => [], hooks => [], mcp_servers => [], plugins => [] };
    });

    # 9. neoperl_memory_search
    $self->register_tool('neoperl_memory_search', {
        description => 'Run hybrid IBM Db2 semantic + relational RRF search over long-term engineering memories.',
        properties  => {
            query              => { type => 'string' },
            scope              => { type => 'string' },
            repo               => { type => 'string' },
            file               => { type => 'string' },
            category           => { type => 'string' },
            limit              => { type => 'integer' },
            include_superseded => { type => 'boolean' },
        },
        required => [ 'query' ],
    }, sub {
        my ($args) = @_;
        return { ok => 0, error => 'Memory store not configured', results => [] }
            unless $self->{memory_store};
        my $hits = $self->{memory_store}->search(%$args);
        return { ok => 1, count => scalar(@$hits), dialect => $self->{memory_store}->dialect, results => $hits };
    });

    # 10. neoperl_memory_get_related
    $self->register_tool('neoperl_memory_get_related', {
        description => 'Inspect graph edges and temporal superseding lineage for a memory ID.',
        properties  => {
            id    => { type => 'integer' },
            depth => { type => 'integer' },
        },
        required => [ 'id' ],
    }, sub {
        my ($args) = @_;
        return { ok => 0, error => 'Memory store not configured' }
            unless $self->{memory_store};
        my $rel = $self->{memory_store}->get_related($args->{id}, depth => $args->{depth} || 2);
        return $rel ? { ok => 1, %$rel } : { ok => 0, error => 'Memory not found' };
    });

    # 11. neoperl_memory_write
    $self->register_tool('neoperl_memory_write', {
        description => 'Reconcile and persist a durable fact/decision through Hy-Memory and .memignore into Db2.',
        properties  => {
            content     => { type => 'string' },
            scope_level => { type => 'string' },
            repo_key    => { type => 'string' },
            file_path   => { type => 'string' },
            category    => { type => 'string' },
            tags        => { type => 'string' },
            pinned      => { type => 'boolean' },
        },
        required => [ 'content' ],
    }, sub {
        my ($args) = @_;
        if ($self->{memory_writer}) {
            my $res = $self->{memory_writer}->save_explicit(%$args);
            return { ok => 1, %$res };
        }
        return { ok => 0, error => 'Memory writer not configured' };
    });

    # 12. neoperl_preprocess_doc
    $self->register_tool('neoperl_preprocess_doc', {
        description => 'Locally preprocess a PNG/JPG/WebP screenshot or multi-page PDF with Granite-Vision-4.1-4B and SHA-256 Db2 cache.',
        properties  => {
            path      => { type => 'string' },
            format    => { type => 'string' },
            force     => { type => 'boolean' },
            max_pages => { type => 'integer' },
        },
        required => [ 'path' ],
    }, sub {
        my ($args) = @_;
        return { ok => 0, error => 'Vision preprocessor not configured' }
            unless $self->{vision};
        my $res = $self->{vision}->preprocess_file(%$args);
        return { ok => 1, %$res };
    });

    # 13. neoperl_delegate_local
    $self->register_tool('neoperl_delegate_local', {
        description => 'Enqueue an out-of-band Ternary-Bonsai-2-27B local job (doc, comments, test_scaffold, refactor_local, commit_msg, summarize) and immediately return job_id (or wait for completion when wait=true).',
        properties  => {
            kind          => { type => 'string' },
            target_path   => { type => 'string' },
            instruction   => { type => 'string' },
            source_code   => { type => 'string' },
            verify_syntax => { type => 'boolean' },
            wait          => { type => 'boolean' },
            timeout       => { type => 'number' },
        },
        required => [ 'kind' ],
    }, sub {
        my ($args) = @_;
        return { ok => 0, error => 'OffloadQueue not configured' }
            unless $self->{offload_queue};
        my $want_wait = $args->{wait} ? 1 : 0;
        my $timeout   = $args->{timeout} || 120;
        my $job_id    = $self->{offload_queue}->enqueue(%$args);
        if ($want_wait) {
            my $q  = $self->{offload_queue};
            my $st = $q->wait_job($job_id, $timeout);
            return {
                %{ $st || {} },
                ok      => ($st && ($st->{status} // '') ne 'failed') ? 1 : 0,
                job_id  => $job_id,
                status  => ($st ? ($st->{status} // 'unknown') : 'unknown'),
                kind    => $args->{kind},
                job     => $st,
                summary => $q->summary(),
            };
        }
        return {
            ok     => 1,
            job_id => $job_id,
            status => 'queued',
            kind   => $args->{kind},
        };
    });

    # 14. neoperl_local_job_status
    $self->register_tool('neoperl_local_job_status', {
        description => 'Inspect, pump, accept, reject, or cancel an out-of-band local Bonsai job and report cloud tokens saved.',
        properties  => {
            job_id  => { type => 'string' },
            action  => { type => 'string' },
            wait    => { type => 'boolean' },
            timeout => { type => 'number' },
        },
    }, sub {
        my ($args) = @_;
        return { ok => 0, error => 'OffloadQueue not configured' }
            unless $self->{offload_queue};

        my $q      = $self->{offload_queue};
        my $action = lc($args->{action} // 'status');
        my $jid    = $args->{job_id};
        my $wait   = $args->{wait} ? 1 : 0;
        my $tout   = $args->{timeout} || 120;

        if ($action eq 'list' || !defined $jid) {
            if ($action eq 'pump') {
                $q->pump(4);
            }
            return {
                ok      => 1,
                jobs    => $q->list_jobs(),
                summary => $q->summary(),
            };
        }
        if ($action eq 'pump') {
            $q->pump(4);
            my $cur = $q->job_status($jid);
            if ($cur && ($cur->{status} // '') =~ /^(?:queued|running)$/) {
                $q->wait_job($jid, $tout);
            }
        }
        elsif ($action eq 'accept') {
            return $q->accept_job($jid);
        }
        elsif ($action eq 'reject') {
            return $q->reject_job($jid);
        }
        elsif ($action eq 'cancel') {
            return $q->cancel_job($jid);
        }
        elsif ($wait) {
            my $cur = $q->job_status($jid);
            if ($cur && ($cur->{status} // '') =~ /^(?:queued|running)$/) {
                $q->wait_job($jid, $tout);
            }
        }

        my $st = $q->job_status($jid);
        return $st
            ? { ok => 1, job => $st, summary => $q->summary() }
            : { ok => 0, error => "Job not found: $jid" };
    });

    return;
}

# --- JSON-RPC 2.0 MCP Request Dispatcher ---

sub handle_jsonrpc {
    my ($self, $req) = @_;
    $self->{request_count}++;

    return {
        jsonrpc => '2.0',
        id      => undef,
        error   => { code => -32600, message => 'Invalid JSON-RPC request' },
    } unless ref($req) eq 'HASH' && defined $req->{method};

    my $id     = $req->{id};
    my $method = $req->{method};
    my $params = ref($req->{params}) eq 'HASH' ? $req->{params} : {};

    if ($method =~ m{^notifications/} || !defined $id) {
        return undef;    # JSON-RPC 2.0 notification has no response body (HTTP 202 Accepted)
    }
    if ($method eq 'initialize' || $method eq 'server/discover') {
        return {
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                protocolVersion => '2025-03-26',
                serverInfo      => {
                    name    => $self->{server_name},
                    version => $VERSION,
                    engine  => $self->engine,
                },
                capabilities => {
                    tools => { listChanged => _jtrue() },
                },
            },
        };
    }
    if ($method eq 'ping') {
        return { jsonrpc => '2.0', id => $id, result => {} };
    }
    if ($method eq 'tools/list') {
        return {
            jsonrpc => '2.0',
            id      => $id,
            result  => { tools => $self->list_tools_schema() },
        };
    }
    if ($method eq 'tools/call') {
        my $tname = $params->{name};
        my $targs = ref($params->{arguments}) eq 'HASH' ? $params->{arguments} : {};
        if (!defined $tname || !$self->has_tool($tname)) {
            return {
                jsonrpc => '2.0',
                id      => $id,
                error   => { code => -32602, message => "Unknown tool: " . ($tname // '<undef>') },
            };
        }
        my $res = eval { $self->call_tool_local($tname, $targs) };
        if ($@) {
            my $err = "$@";
            return {
                jsonrpc => '2.0',
                id      => $id,
                result  => {
                    content => [ { type => 'text', text => $err } ],
                    isError => _jtrue(),
                },
            };
        }
        return {
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                content           => [ { type => 'text', text => _encode_json($res) } ],
                structuredContent => $res,
                isError           => _jfalse(),
            },
        };
    }

    return {
        jsonrpc => '2.0',
        id      => $id,
        error   => { code => -32601, message => "Method not found: $method" },
    };
}

# --- Server Lifecycle: Mojolicious Daemon (Primary) & IO::Socket::INET (Fallback) ---

sub _new_session_id {
    my ($self) = @_;
    $self->{session_seq} = ($self->{session_seq} || 0) + 1;
    my $sid = sprintf('neoperl-mcp-%d-%d-%08x%08x',
        $$, $self->{session_seq}, int(rand(0xFFFFFFFF)), int(rand(0xFFFFFFFF)));
    $self->{sessions}{$sid} = 1;
    return $sid;
}

sub start {
    my ($self) = @_;
    return $self->{bound_port} if $self->{running};

    if ($self->{use_mojo}) {
        my $app = Mojolicious->new;
        $app->log->level('fatal');

        my $r = $app->routes;
        $r->get('/health' => sub {
            my $c = shift;
            $c->render(json => {
                ok            => _jtrue(),
                server        => $self->{server_name},
                engine        => 'Mojolicious',
                tools         => scalar(@{ $self->{tool_order} }),
                mounted_packs => $self->mounted_packs(),
                mojo_accel    => $HAS_MOJO_ACCEL ? _jtrue() : _jfalse(),
            });
        });

        # MCP SSE endpoint (Streamable HTTP / SSE discovery)
        $r->get('/mcp' => sub {
            my $c = shift;
            my $req_sid = $c->req->headers->header('Mcp-Session-Id');
            $c->res->headers->header('Mcp-Session-Id' => $req_sid)
                if defined $req_sid && length $req_sid;
            $c->res->headers->content_type('text/event-stream');
            $c->res->headers->cache_control('no-cache');
            my $payload = _encode_json({ endpoint => '/mcp', tools => scalar(@{ $self->{tool_order} }) });
            $c->write_chunk("event: endpoint\ndata: $payload\n\n" => sub { shift->finish });
        });

        my $mcp_post = sub {
            my $c = shift;
            my $body = $c->req->body;
            my $req  = eval { _decode_json($body) };
            if (!$req) {
                $c->render(
                    status => 400,
                    json   => {
                        jsonrpc => '2.0',
                        id      => undef,
                        error   => { code => -32700, message => 'Parse error' },
                    },
                );
                return;
            }
            my $req_sid  = $c->req->headers->header('Mcp-Session-Id');
            my $resp_sid;
            if (ref($req) eq 'HASH' && ($req->{method} // '') eq 'initialize') {
                $resp_sid = $self->_new_session_id();
            }
            elsif (defined $req_sid && length $req_sid) {
                $resp_sid = $req_sid;
            }
            $c->res->headers->header('Mcp-Session-Id' => $resp_sid)
                if defined $resp_sid && length $resp_sid;

            my $resp = $self->handle_jsonrpc($req);
            if (!defined $resp) {
                $c->render(status => 202, text => '');
                return;
            }
            my $accept = $c->req->headers->accept // '';
            if ($accept =~ m{text/event-stream}i && $c->param('stream')) {
                $c->res->headers->content_type('text/event-stream');
                $c->render(data => 'data: ' . _encode_json($resp) . "\n\n");
                return;
            }
            $c->res->headers->content_type('application/json; charset=utf-8');
            $c->render(data => _encode_json($resp));
        };

        my $mcp_delete = sub {
            my $c = shift;
            my $req_sid = $c->req->headers->header('Mcp-Session-Id');
            delete $self->{sessions}{$req_sid} if defined $req_sid && length $req_sid;
            $c->rendered(204);
        };

        $r->post('/mcp'   => $mcp_post);
        $r->post('/'      => $mcp_post);
        $r->delete('/mcp' => $mcp_delete);
        $r->delete('/'    => $mcp_delete);

        my $port = $self->{port} || 0;
        my $host = $self->{host} || '127.0.0.1';
        my $daemon = Mojo::Server::Daemon->new(
            app    => $app,
            listen => [ "http://$host:$port" ],
            silent => 1,
        );
        $daemon->start;
        my $bound = $daemon->ports->[0];
        croak "Mojo::Server::Daemon failed to bind $host:$port" unless $bound;

        $self->{app}        = $app;
        $self->{daemon}     = $daemon;
        $self->{bound_port} = $bound;
        $self->{running}    = 1;
        return $bound;
    }

    # Fallback pure-Perl non-blocking localhost HTTP server
    my $sock = IO::Socket::INET->new(
        LocalAddr => $self->{host} || '127.0.0.1',
        LocalPort => $self->{port} || 0,
        Proto     => 'tcp',
        Listen    => 32,
        ReuseAddr => 1,
        Blocking  => 0,
    ) or croak "EditorMCP fallback bind failed: $!";

    $self->{listen_sock} = $sock;
    $self->{sel}         = IO::Select->new($sock);
    $self->{clients}     = {};
    $self->{bound_port}  = $sock->sockport();
    $self->{running}     = 1;
    return $self->{bound_port};
}

sub poll {
    my ($self, $timeout_s) = @_;
    return 0 unless $self->{running};
    $timeout_s = 0 unless defined $timeout_s;

    if ($self->{use_mojo}) {
        my $reactor = Mojo::IOLoop->singleton->reactor;
        my $tid     = $reactor->timer($timeout_s => sub {});
        $reactor->one_tick;
        $reactor->remove($tid);
        return 1;
    }

    # Fallback IO::Select non-blocking HTTP pump
    my @ready = $self->{sel}->can_read($timeout_s);
    my $handled = 0;
    for my $fh (@ready) {
        if ($fh == $self->{listen_sock}) {
            while (my $client = $self->{listen_sock}->accept()) {
                $client->blocking(0);
                $self->{sel}->add($client);
                $self->{clients}{ fileno($client) } = { sock => $client, buf => '' };
            }
            next;
        }
        my $fd   = fileno($fh);
        my $slot = $self->{clients}{$fd};
        next unless $slot;

        my $chunk = '';
        my $n = sysread($fh, $chunk, 65536);
        if (!defined $n) {
            next if $!{EAGAIN} || $!{EWOULDBLOCK};
            $self->_drop_fallback_client($fh, $fd);
            next;
        }
        if ($n == 0) {
            $self->_drop_fallback_client($fh, $fd);
            next;
        }

        $slot->{buf} .= $chunk;
        my $hdr_end = index($slot->{buf}, "\r\n\r\n");
        next if $hdr_end < 0;

        my $hdrs = substr($slot->{buf}, 0, $hdr_end);
        my $clen = 0;
        if ($hdrs =~ /^Content-Length:\s*(\d+)/mi) {
            $clen = int($1);
        }
        my $body_start = $hdr_end + 4;
        next if length($slot->{buf}) - $body_start < $clen;

        my $body = substr($slot->{buf}, $body_start, $clen);
        my ($method, $path) = ($hdrs =~ m{\A([A-Z]+)\s+(\S+)\s+HTTP/});
        $method ||= 'GET';
        $path   ||= '/';
        my ($req_sid) = ($hdrs =~ /^Mcp-Session-Id:\s*([^\r\n]+)/mi);
        $req_sid =~ s/\s+\z// if defined $req_sid;

        $self->_send_fallback_response($fh, $method, $path, $body, $req_sid);
        $self->_drop_fallback_client($fh, $fd);
        $handled++;
    }
    return $handled;
}

sub _send_fallback_response {
    my ($self, $fh, $method, $path, $body, $req_sid) = @_;
    my ($status, $ctype, $resp_body);
    my $resp_sid;

    if ($method eq 'GET' && $path =~ m{^/health}) {
        $status    = '200 OK';
        $ctype     = 'application/json; charset=utf-8';
        $resp_body = _encode_json({
            ok            => _jtrue(),
            server        => $self->{server_name},
            engine        => 'IO::Socket::INET',
            tools         => scalar(@{ $self->{tool_order} }),
            mounted_packs => $self->mounted_packs(),
            mojo_accel    => _jfalse(),
        });
    }
    elsif ($method eq 'GET' && $path =~ m{^/mcp}) {
        $status    = '200 OK';
        $ctype     = 'text/event-stream';
        $resp_body = 'event: endpoint' . "\ndata: " . _encode_json({ endpoint => '/mcp' }) . "\n\n";
        $resp_sid  = $req_sid if defined $req_sid && length $req_sid;
    }
    elsif ($method eq 'DELETE' && ($path =~ m{^/mcp} || $path eq '/')) {
        delete $self->{sessions}{$req_sid} if defined $req_sid && length $req_sid;
        my $raw = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
        $fh->blocking(1);
        print {$fh} $raw;
        return;
    }
    elsif ($method eq 'POST' && ($path =~ m{^/mcp} || $path eq '/')) {
        my $req = eval { _decode_json($body) };
        if (!$req) {
            $status    = '400 Bad Request';
            $ctype     = 'application/json; charset=utf-8';
            $resp_body = _encode_json({ jsonrpc => '2.0', id => undef, error => { code => -32700, message => 'Parse error' } });
        }
        else {
            if (ref($req) eq 'HASH' && ($req->{method} // '') eq 'initialize') {
                $resp_sid = $self->_new_session_id();
            }
            elsif (defined $req_sid && length $req_sid) {
                $resp_sid = $req_sid;
            }
            my $resp = $self->handle_jsonrpc($req);
            if (!defined $resp) {
                $status    = '202 Accepted';
                $ctype     = 'text/plain';
                $resp_body = '';
            }
            else {
                $status    = '200 OK';
                $ctype     = 'application/json; charset=utf-8';
                $resp_body = _encode_json($resp);
            }
        }
    }
    else {
        $status    = '404 Not Found';
        $ctype     = 'text/plain';
        $resp_body = 'Not Found';
    }

    my $len = length($resp_body);
    my $extra_hdr = (defined $resp_sid && length $resp_sid) ? "Mcp-Session-Id: $resp_sid\r\n" : '';
    my $raw = "HTTP/1.1 $status\r\nContent-Type: $ctype\r\n${extra_hdr}Content-Length: $len\r\nConnection: close\r\n\r\n$resp_body";
    $fh->blocking(1);
    print {$fh} $raw;
    return;
}

sub _drop_fallback_client {
    my ($self, $fh, $fd) = @_;
    $self->{sel}->remove($fh) if $self->{sel};
    delete $self->{clients}{$fd} if defined $fd;
    eval { close $fh };
    return;
}

sub run_forever {
    my ($self) = @_;
    $self->start() unless $self->{running};
    local $SIG{INT}  = sub { $self->stop(); Mojo::IOLoop->stop() if $self->{use_mojo}; };
    local $SIG{TERM} = sub { $self->stop(); Mojo::IOLoop->stop() if $self->{use_mojo}; };
    if ($self->{use_mojo}) {
        Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
    }
    else {
        while ($self->{running}) {
            $self->poll(0.1);
        }
    }
    return 1;
}

sub stop {
    my ($self) = @_;
    return 1 unless $self->{running};
    $self->{running} = 0;

    if ($self->{daemon}) {
        eval { $self->{daemon}->stop };
        $self->{daemon} = undef;
        $self->{app}    = undef;
    }
    if ($self->{listen_sock}) {
        for my $slot (values %{ $self->{clients} || {} }) {
            eval { close $slot->{sock} };
        }
        $self->{clients} = {};
        eval { close $self->{listen_sock} };
        $self->{listen_sock} = undef;
        $self->{sel}         = undef;
    }
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} && ${^GLOBAL_PHASE} eq 'DESTRUCT';
    eval { $self->stop() };
    return;
}

1;

__END__

=head1 NAME

NeoPerl::Antigravity::EditorMCP - Localhost HTTP/JSON-RPC 2.0 MCP server for Antigravity

=head1 SYNOPSIS

    use NeoPerl::Antigravity::EditorMCP;

    my $mcp = NeoPerl::Antigravity::EditorMCP->new(
        editor       => $editor,
        memory_store => $store,
    );
    my $port = $mcp->start();
    $mcp->register_tool('neoperl_perl_outline', \%schema, \&handler);
    $mcp->poll(0);

=head1 DESCRIPTION

C<NeoPerl::Antigravity::EditorMCP> binds an ephemeral C<127.0.0.1> HTTP/JSON-RPC
2.0 (plus SSE) Model Context Protocol server using L<Mojolicious>,
L<Mojo::Server::Daemon>, and L<Mojo::IOLoop> (from C<mojolicious-mt>, with a
non-blocking L<IO::Socket::INET> fallback when Mojolicious is unavailable).
It ships 14 built-in editor, Db2 semantic memory, Granite-Vision, and
Ternary-Bonsai offload tools and exposes C<register_tool> so C<PerlDev> and
C<XSDev> register tools 15 through 23.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
