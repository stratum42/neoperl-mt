package NeoPerl::Antigravity::Customizations;

use strict;
use warnings;
use File::Spec ();
use File::Basename qw(basename dirname);

our $VERSION = '0.01';

my $HAS_MOJO_JSON;
BEGIN {
    $HAS_MOJO_JSON = eval { require Mojo::JSON; 1 } ? 1 : 0;
    require JSON::PP unless $HAS_MOJO_JSON;
}

sub _decode_json {
    return $HAS_MOJO_JSON ? Mojo::JSON::decode_json($_[0]) : JSON::PP->new->utf8->decode($_[0]);
}

sub _slurp {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    local $/;
    my $txt = <$fh>;
    close $fh;
    return $txt;
}

sub _default_global_config_dir {
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    return length($home)
        ? File::Spec->catdir($home, '.gemini', 'config')
        : '';
}

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        workspace_root    => $args{workspace_root} // '.',
        global_config_dir => exists($args{global_config_dir})
            ? $args{global_config_dir}
            : _default_global_config_dir(),
        discovered        => undef,
    }, $class;

    $self->discover() if ($args{auto_discover} // 1);
    return $self;
}

sub workspace_root    { $_[0]{workspace_root} }
sub global_config_dir { $_[0]{global_config_dir} }

sub _parse_frontmatter {
    my ($text) = @_;
    return ({}, $text // '') unless defined $text;
    if ($text =~ /\A---\r?\n(.*?)\r?\n---\r?\n?(.*)\z/s) {
        my ($yaml, $body) = ($1, $2);
        my %meta;
        for my $line (split /\r?\n/, $yaml) {
            if ($line =~ /^\s*([A-Za-z0-9_-]+)\s*:\s*(.+?)\s*$/) {
                my ($k, $v) = (lc($1), $2);
                $v =~ s/\A["']|["']\z//g;
                $meta{$k} = $v;
            }
        }
        return (\%meta, $body);
    }
    return ({}, $text);
}

sub _scan_dir_files {
    my ($dir, $suffix_re) = @_;
    return () unless defined $dir && length $dir && -d $dir;
    opendir(my $dh, $dir) or return ();
    my @files = sort grep { $_ !~ /^\./ && (!$suffix_re || $_ =~ $suffix_re) } readdir($dh);
    closedir $dh;
    return map { File::Spec->catfile($dir, $_) } @files;
}

sub discover {
    my ($self) = @_;
    my $ws   = $self->{workspace_root} // '.';
    my $glob = $self->{global_config_dir} // '';

    my $ws_agents = File::Spec->catdir($ws, '.agents');

    my (@instructions, @rules, @skills, %hooks, %mcp_servers, @plugins);

    # 1. Instruction files (global -> workspace root -> .agents/)
    my @inst_candidates = (
        (length($glob) ? (
            [ 'global', File::Spec->catfile($glob, 'GEMINI.md') ],
            [ 'global', File::Spec->catfile($glob, 'AGENTS.md') ],
        ) : ()),
        [ 'workspace', File::Spec->catfile($ws, 'GEMINI.md') ],
        [ 'workspace', File::Spec->catfile($ws, 'AGENTS.md') ],
        [ 'workspace', File::Spec->catfile($ws_agents, 'GEMINI.md') ],
        [ 'workspace', File::Spec->catfile($ws_agents, 'AGENTS.md') ],
    );
    for my $item (@inst_candidates) {
        my ($scope, $path) = @$item;
        next unless -f $path;
        my $txt = _slurp($path);
        push @instructions, {
            scope   => $scope,
            name    => basename($path),
            path    => $path,
            bytes   => length($txt // ''),
            content => $txt // '',
        };
    }

    # 2. Rules (global rules/*.md -> .agents/rules/*.md)
    my @rule_dirs = (
        (length($glob) ? [ 'global', File::Spec->catdir($glob, 'rules') ] : ()),
        [ 'workspace', File::Spec->catdir($ws_agents, 'rules') ],
    );
    for my $rd (@rule_dirs) {
        my ($scope, $dir) = @$rd;
        for my $file (_scan_dir_files($dir, qr/\.md$/i)) {
            next unless -f $file;
            my $raw = _slurp($file);
            my ($meta, $body) = _parse_frontmatter($raw);
            my $name = $meta->{name} || do { (my $b = basename($file)) =~ s/\.md$//i; $b };
            push @rules, {
                scope       => $scope,
                name        => $name,
                description => $meta->{description} // '',
                path        => $file,
                content     => $body,
            };
        }
    }

    # 3. Skills (global skills/*/SKILL.md -> .agents/skills/*/SKILL.md)
    my @skill_roots = (
        (length($glob) ? [ 'global', File::Spec->catdir($glob, 'skills') ] : ()),
        [ 'workspace', File::Spec->catdir($ws_agents, 'skills') ],
    );
    my %seen_skill;
    for my $sr (@skill_roots) {
        my ($scope, $dir) = @$sr;
        for my $entry (_scan_dir_files($dir)) {
            next unless -d $entry;
            my $skill_md = File::Spec->catfile($entry, 'SKILL.md');
            next unless -f $skill_md;
            my $raw = _slurp($skill_md);
            my ($meta, $body) = _parse_frontmatter($raw);
            my $name = $meta->{name} || basename($entry);
            my $rec = {
                scope       => $scope,
                name        => $name,
                description => $meta->{description} // '',
                path        => $skill_md,
                dir         => $entry,
                body        => $body,
            };
            # Workspace skill overrides global skill with same name
            if (exists $seen_skill{$name}) {
                @skills = grep { $_->{name} ne $name } @skills;
            }
            $seen_skill{$name} = 1;
            push @skills, $rec;
        }
    }

    # 4. Hooks (global hooks.json -> .agents/hooks.json)
    for my $hp (
        (length($glob) ? [ 'global', File::Spec->catfile($glob, 'hooks.json') ] : ()),
        [ 'workspace', File::Spec->catfile($ws_agents, 'hooks.json') ],
    ) {
        my ($scope, $path) = @$hp;
        next unless -f $path;
        my $data = eval { _decode_json(_slurp($path)) };
        next unless ref($data) eq 'HASH';
        my $src = ref($data->{hooks}) eq 'HASH' ? $data->{hooks} : $data;
        for my $ev (keys %$src) {
            $hooks{$ev} = {
                scope   => $scope,
                path    => $path,
                entries => ref($src->{$ev}) eq 'ARRAY' ? $src->{$ev} : [ $src->{$ev} ],
            };
        }
    }

    # 5. MCP Config (global mcp_config.json -> .agents/mcp_config.json)
    for my $mp (
        (length($glob) ? [ 'global', File::Spec->catfile($glob, 'mcp_config.json') ] : ()),
        [ 'workspace', File::Spec->catfile($ws_agents, 'mcp_config.json') ],
    ) {
        my ($scope, $path) = @$mp;
        next unless -f $path;
        my $data = eval { _decode_json(_slurp($path)) };
        next unless ref($data) eq 'HASH';
        my $servers = ref($data->{mcpServers}) eq 'HASH' ? $data->{mcpServers}
                    : ref($data->{servers})    eq 'HASH' ? $data->{servers}
                    : {};
        for my $sname (keys %$servers) {
            next unless ref($servers->{$sname}) eq 'HASH';
            $mcp_servers{$sname} = {
                scope  => $scope,
                source => $path,
                name   => $sname,
                config => $servers->{$sname},
            };
        }
    }

    # 6. Plugins (global plugins/* -> .agents/plugins/*)
    for my $pr (
        (length($glob) ? [ 'global', File::Spec->catdir($glob, 'plugins') ] : ()),
        [ 'workspace', File::Spec->catdir($ws_agents, 'plugins') ],
    ) {
        my ($scope, $dir) = @$pr;
        for my $entry (_scan_dir_files($dir)) {
            my $name = basename($entry);
            my $manifest = -d $entry ? File::Spec->catfile($entry, 'plugin.json') : undef;
            my $meta = (defined $manifest && -f $manifest)
                ? (eval { _decode_json(_slurp($manifest)) } || {})
                : {};
            push @plugins, {
                scope       => $scope,
                name        => $meta->{name} || $name,
                version     => $meta->{version} // '',
                description => $meta->{description} // '',
                path        => $entry,
            };
        }
    }

    $self->{discovered} = {
        instructions => \@instructions,
        rules        => \@rules,
        skills       => \@skills,
        hooks        => \%hooks,
        mcp_servers  => \%mcp_servers,
        plugins      => \@plugins,
    };

    return $self->{discovered};
}

sub get_instructions { $_[0]{discovered}{instructions} || [] }
sub list_rules       { $_[0]{discovered}{rules}        || [] }
sub list_skills      { $_[0]{discovered}{skills}       || [] }
sub get_hooks        { $_[0]{discovered}{hooks}        || {} }
sub get_mcp_servers  { $_[0]{discovered}{mcp_servers}  || {} }
sub get_plugins      { $_[0]{discovered}{plugins}      || [] }

sub find_skill {
    my ($self, $name) = @_;
    return undef unless defined $name;
    for my $s (@{ $self->list_skills }) {
        return $s if $s->{name} eq $name;
    }
    return undef;
}

sub summary {
    my ($self) = @_;
    my $d = $self->{discovered} || $self->discover();
    return {
        workspace_root    => $self->{workspace_root},
        global_config_dir => $self->{global_config_dir},
        instructions      => [ map { +{ scope => $_->{scope}, name => $_->{name}, path => $_->{path}, bytes => $_->{bytes} } } @{ $d->{instructions} } ],
        rules             => [ map { +{ scope => $_->{scope}, name => $_->{name}, description => $_->{description}, path => $_->{path} } } @{ $d->{rules} } ],
        skills            => [ map { +{ scope => $_->{scope}, name => $_->{name}, description => $_->{description}, path => $_->{path} } } @{ $d->{skills} } ],
        hooks             => [ sort keys %{ $d->{hooks} } ],
        mcp_servers       => [ sort keys %{ $d->{mcp_servers} } ],
        plugins           => [ map { +{ scope => $_->{scope}, name => $_->{name}, version => $_->{version}, path => $_->{path} } } @{ $d->{plugins} } ],
    };
}

sub as_telescope_items {
    my ($self) = @_;
    my $d = $self->{discovered} || $self->discover();
    my @items;
    for my $s (@{ $d->{skills} }) {
        push @items, {
            kind    => 'skill',
            label   => "[skill:$s->{scope}] $s->{name}",
            detail  => $s->{description},
            path    => $s->{path},
            preview => $s->{body},
        };
    }
    for my $r (@{ $d->{rules} }) {
        push @items, {
            kind    => 'rule',
            label   => "[rule:$r->{scope}] $r->{name}",
            detail  => $r->{description},
            path    => $r->{path},
            preview => $r->{content},
        };
    }
    for my $m (sort keys %{ $d->{mcp_servers} }) {
        my $srv = $d->{mcp_servers}{$m};
        push @items, {
            kind    => 'mcp',
            label   => "[mcp:$srv->{scope}] $m",
            detail  => $srv->{source},
            path    => $srv->{source},
            preview => "MCP Server: $m ($srv->{source})",
        };
    }
    for my $i (@{ $d->{instructions} }) {
        push @items, {
            kind    => 'instruction',
            label   => "[inst:$i->{scope}] $i->{name}",
            detail  => "$i->{bytes} bytes",
            path    => $i->{path},
            preview => $i->{content},
        };
    }
    return \@items;
}

1;

__END__

=head1 NAME

NeoPerl::Antigravity::Customizations - Hierarchical .agents/ and ~/.gemini/config/ discovery

=head1 SYNOPSIS

    use NeoPerl::Antigravity::Customizations;

    my $cust = NeoPerl::Antigravity::Customizations->new(
        workspace_root => '/path/to/repo',
    );
    my $summary = $cust->summary();

=head1 DESCRIPTION

C<NeoPerl::Antigravity::Customizations> discovers workspace and global
Antigravity customizations including C<GEMINI.md>, C<AGENTS.md>,
C<rules/*.md>, C<skills/*/SKILL.md>, C<hooks.json>, C<mcp_config.json>, and
C<plugins/>, applying workspace-over-global precedence.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
