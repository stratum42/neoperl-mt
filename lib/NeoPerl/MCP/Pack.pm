package NeoPerl::MCP::Pack;

use strict;
use warnings;
use Carp qw(croak);

our $VERSION = '0.01';

# Standard LSP CompletionItemKind constants for pack lsp_completions() hooks
our %COMPLETION_KIND = (
    text        => 1,
    method      => 2,
    function    => 3,
    constructor => 4,
    field       => 5,
    variable    => 6,
    class       => 7,
    interface   => 8,
    module      => 9,
    property    => 10,
    unit        => 11,
    value       => 12,
    enum        => 13,
    keyword     => 14,
    snippet     => 15,
    constant    => 21,
    struct      => 22,
    operator    => 24,
);

# Standard LSP SymbolKind constants for pack lsp_symbols() hooks
our %SYMBOL_KIND = (
    file        => 1,
    module      => 2,
    namespace   => 3,
    package     => 4,
    class       => 5,
    method      => 6,
    property    => 7,
    field       => 8,
    constructor => 9,
    enum        => 10,
    interface   => 11,
    function    => 12,
    variable    => 13,
    constant    => 14,
    string      => 15,
    number      => 16,
    struct      => 23,
);

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor    => $opts{editor},
        dsn       => $opts{dsn},
        user      => $opts{user},
        pass      => $opts{pass},
        read_only => exists($opts{read_only}) ? ($opts{read_only} ? 1 : 0) : 1,
        max_rows  => int($opts{max_rows} || 200),
        dbi_attr  => (ref($opts{dbi_attr}) eq 'HASH' ? { %{ $opts{dbi_attr} } } : {}),
        opts      => \%opts,
    }, $class;
    $self->_init(\%opts) if $self->can('_init');
    return $self;
}

sub _init { }

# --- Metadata Contract (subclasses MUST override meta()) ---

sub meta {
    my ($self) = @_;
    return {
        name             => 'base',
        label            => 'Base MCP Pack',
        category         => 'general',
        version          => $VERSION,
        description      => 'Abstract NeoPerl::MT domain MCP pack.',
        filetypes        => [],
        upstream_credits => [],
    };
}

sub name             { $_[0]->meta->{name}             // 'base' }
sub label            { $_[0]->meta->{label}            // $_[0]->name }
sub category         { $_[0]->meta->{category}         // 'general' }
sub description      { $_[0]->meta->{description}      // '' }
sub filetypes        { $_[0]->meta->{filetypes}        || [] }
sub upstream_credits { $_[0]->meta->{upstream_credits} || [] }
sub editor           { $_[0]{editor} }
sub dsn              { $_[0]{dsn} }
sub read_only        { $_[0]{read_only} ? 1 : 0 }
sub max_rows         { $_[0]{max_rows} || 200 }

# --- Tool Contract (subclasses MUST override tools()) ---

sub tools {
    return [];
}

sub tool_map {
    my ($self) = @_;
    my %map;
    for my $t (@{ $self->tools }) {
        next unless ref($t) eq 'HASH' && defined $t->{name};
        $map{ $t->{name} } = $t;
    }
    return \%map;
}

sub has_tool {
    my ($self, $name) = @_;
    return 0 unless defined $name && length $name;
    return exists $self->tool_map->{$name} ? 1 : 0;
}

sub list_tool_names {
    my ($self) = @_;
    return [
        map { $_->{name} }
        grep { ref($_) eq 'HASH' && defined $_->{name} }
        @{ $self->tools }
    ];
}

sub tools_schema {
    my ($self) = @_;
    my @out;
    for my $t (@{ $self->tools }) {
        next unless ref($t) eq 'HASH' && defined $t->{name};
        my $schema = $t->{inputSchema} || {
            type       => 'object',
            properties => {},
        };
        push @out, {
            name        => $t->{name},
            description => $t->{description} // '',
            inputSchema => $schema,
        };
    }
    return \@out;
}

sub call_tool {
    my ($self, $name, $args, $ctx) = @_;
    croak "call_tool requires tool name" unless defined $name && length $name;
    my $tool = $self->tool_map->{$name};
    croak "Unknown tool '$name' in MCP pack '" . $self->name . "'" unless $tool;
    croak "Tool '$name' has no executable handler" unless ref($tool->{handler}) eq 'CODE';

    my $effective_ctx = (ref($ctx) eq 'HASH')
        ? { pack => $self, editor => $self->{editor}, %$ctx }
        : { pack => $self, editor => $self->{editor} };

    return $tool->{handler}->(ref($args) eq 'HASH' ? $args : {}, $effective_ctx);
}

sub register_into {
    my ($self, $editor_mcp) = @_;
    croak "register_into requires an EditorMCP object supporting register_tool()"
        unless $editor_mcp && $editor_mcp->can('register_tool');

    my $count = 0;
    for my $t (@{ $self->tools }) {
        next unless ref($t) eq 'HASH' && defined $t->{name} && ref($t->{handler}) eq 'CODE';
        my $handler = $t->{handler};
        my $schema  = {
            description => $t->{description} // '',
            inputSchema => $t->{inputSchema} || {
                type       => 'object',
                properties => {},
            },
        };
        $editor_mcp->register_tool($t->{name}, $schema, sub {
            my ($args) = @_;
            my $ed = $self->{editor};
            if (!$ed && ref($editor_mcp) && eval { exists $editor_mcp->{editor} }) {
                $ed = $editor_mcp->{editor};
            }
            return $handler->(
                ref($args) eq 'HASH' ? $args : {},
                {
                    pack       => $self,
                    editor     => $ed,
                    editor_mcp => $editor_mcp,
                },
            );
        });
        $count++;
    }
    return $count;
}

sub unregister_from {
    my ($self, $editor_mcp) = @_;
    return 0 unless $editor_mcp && $editor_mcp->can('unregister_tool');
    my $count = 0;
    for my $name (@{ $self->list_tool_names }) {
        $count++ if $editor_mcp->unregister_tool($name);
    }
    return $count;
}

# --- Optional LSP Knowledge Hooks (reused directly by NeoPerl::LSP::Builtin) ---

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    return [];
}

sub lsp_diagnostics {
    my ($self, $text, $lang) = @_;
    return [];
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    return [];
}

sub make_diagnostic {
    my ($self, %d) = @_;
    my $line = defined $d{line} ? int($d{line}) : 0;
    $line = 0 if $line < 0;
    my $col = defined $d{col} ? int($d{col}) : 0;
    $col = 0 if $col < 0;
    my $end_line = defined $d{end_line} ? int($d{end_line}) : $line;
    my $end_col  = defined $d{end_col}  ? int($d{end_col})  : ($col + 1);
    my $sev = lc($d{severity} // 'warn');
    $sev = 'warn' unless $sev =~ /^(?:error|warn|info|hint)$/;
    return {
        line     => $line,
        col      => $col,
        end_line => $end_line,
        end_col  => $end_col,
        severity => $sev,
        code     => defined($d{code}) ? "$d{code}" : '',
        message  => $d{message} // '',
        source   => $d{source}  || $self->name,
    };
}

sub make_symbol {
    my ($self, %s) = @_;
    my $line = defined $s{line} ? int($s{line}) : 0;
    $line = 0 if $line < 0;
    my $col = defined $s{col} ? int($s{col}) : 0;
    $col = 0 if $col < 0;
    my $kind = $s{kind};
    if (defined $kind && $kind !~ /^\d+$/) {
        $kind = $SYMBOL_KIND{ lc $kind } || 12;
    }
    return {
        name     => $s{name} // '',
        kind     => int($kind || 12),
        line     => $line,
        col      => $col,
        end_line => defined($s{end_line}) ? int($s{end_line}) : $line,
        detail   => $s{detail} // '',
    };
}

# --- Shared Database Guardrails & Optional Live DBI Execution Helpers ---

sub has_dbi {
    return eval { require DBI; 1 } ? 1 : 0;
}

sub has_odbc {
    return eval { require DBI; require DBD::ODBC; 1 } ? 1 : 0;
}

sub strip_sql_comments_and_literals {
    my ($self, $sql) = @_;
    return '' unless defined $sql;
    my $out = '';
    my $len = length($sql);
    my $i   = 0;
    while ($i < $len) {
        my $c2 = substr($sql, $i, 2);
        if ($c2 eq '--') {
            my $nl = index($sql, "\n", $i);
            $i = ($nl < 0) ? $len : ($nl + 1);
            $out .= "\n";
        }
        elsif ($c2 eq '/*') {
            my $end = index($sql, '*/', $i + 2);
            $i = ($end < 0) ? $len : ($end + 2);
            $out .= ' ';
        }
        elsif (substr($sql, $i, 1) eq "'") {
            $i++;
            while ($i < $len) {
                if (substr($sql, $i, 1) eq "'") {
                    if ($i + 1 < $len && substr($sql, $i + 1, 1) eq "'") {
                        $i += 2;
                        next;
                    }
                    $i++;
                    last;
                }
                $i++;
            }
            $out .= " '' ";
        }
        elsif (substr($sql, $i, 1) eq '"') {
            $i++;
            while ($i < $len) {
                if (substr($sql, $i, 1) eq '"') {
                    if ($i + 1 < $len && substr($sql, $i + 1, 1) eq '"') {
                        $i += 2;
                        next;
                    }
                    $i++;
                    last;
                }
                $i++;
            }
            $out .= ' "" ';
        }
        elsif (substr($sql, $i, 1) eq '{') {
            # Informix brace comment { ... }
            my $end = index($sql, '}', $i + 1);
            if ($end >= 0) {
                $i = $end + 1;
                $out .= ' ';
            }
            else {
                $out .= substr($sql, $i, 1);
                $i++;
            }
        }
        else {
            $out .= substr($sql, $i, 1);
            $i++;
        }
    }
    return $out;
}

sub check_sql_safety {
    my ($self, $sql, $allow_write) = @_;
    if (!defined $sql || $sql !~ /\S/) {
        return { safe => 0, reason => 'Empty SQL statement' };
    }

    my $effective_allow_write = defined($allow_write)
        ? ($allow_write ? 1 : 0)
        : ($self->read_only ? 0 : 1);

    my $clean = $self->strip_sql_comments_and_literals($sql);
    $clean =~ s/^\s+//;
    $clean =~ s/\s+$//;
    $clean =~ s/;\s*$//;

    if (!length $clean) {
        return { safe => 0, reason => 'SQL contains only comments or whitespace' };
    }

    my ($first_kw) = ($clean =~ /^([A-Za-z_]+)/);
    $first_kw = uc($first_kw // '');

    return { safe => 1, statement_type => $first_kw, write_allowed => 1 }
        if $effective_allow_write;

    # Disallow stacked multi-statements in read-only mode
    if ($clean =~ /;/) {
        return {
            safe           => 0,
            statement_type => $first_kw,
            reason         => 'Multi-statement SQL blocked in read-only mode (pass allow_write => 1 to permit).',
        };
    }

    my %readonly_start = map { $_ => 1 } qw(SELECT WITH VALUES EXPLAIN DESCRIBE SHOW);
    if (!$readonly_start{$first_kw}) {
        return {
            safe           => 0,
            statement_type => $first_kw,
            reason         => "Statement starting with '$first_kw' is blocked in read-only mode (only SELECT/WITH/VALUES/EXPLAIN/DESCRIBE/SHOW allowed unless allow_write => 1).",
        };
    }

    # Block data-modifying CTEs or embedded DML/DDL/procedure calls
    if ($clean =~ /\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|CALL|EXECUTE|LOAD|IMPORT|REPLACE|RENAME|COMMENT|LOCK|COMMIT|ROLLBACK|SAVEPOINT|BEGIN)\b/i) {
        my $verb = uc($1);
        # Allow SELECT ... FOR READ ONLY / FETCH ONLY / WITH UR, and Informix SELECT ... INTO TEMP only if write allowed
        return {
            safe           => 0,
            statement_type => $verb,
            reason         => "Mutating/DDL keyword '$verb' detected inside statement; blocked in read-only mode (pass allow_write => 1 to permit).",
        };
    }

    if ($clean =~ /\bSELECT\b.*\bINTO\s+(?:TEMP|SCRATCH|RAW|TABLE)\b/is) {
        return {
            safe           => 0,
            statement_type => 'SELECT_INTO',
            reason         => 'SELECT INTO TEMP/TABLE creates objects and is blocked in read-only mode (pass allow_write => 1 to permit).',
        };
    }

    return {
        safe           => 1,
        statement_type => $first_kw,
        write_allowed  => 0,
    };
}

sub resolve_db_config {
    my ($self, %req) = @_;
    my $prefix = $req{env_prefix} // '';
    my $dsn  = $req{dsn}  // $self->{dsn}  // ($prefix ? $ENV{"${prefix}_DSN"}  : undef);
    my $user = $req{user} // $self->{user} // ($prefix ? $ENV{"${prefix}_USER"} : undef) // '';
    my $pass = $req{pass} // $self->{pass} // ($prefix ? $ENV{"${prefix}_PASS"} : undef) // '';
    return ($dsn, $user, $pass);
}

sub execute_dbi_query {
    my ($self, %req) = @_;
    my $sql         = $req{sql} // '';
    my $params      = ref($req{params}) eq 'ARRAY' ? $req{params} : [];
    my $allow_write = exists($req{allow_write}) ? $req{allow_write} : undef;
    my $max_rows    = int($req{max_rows} || $self->max_rows || 200);
    $max_rows = 1    if $max_rows < 1;
    $max_rows = 5000 if $max_rows > 5000;
    my $dialect     = $req{dialect}     || $self->name;
    my $env_prefix  = $req{env_prefix}  || uc($dialect);
    my $driver_hint = $req{driver_hint} || 'dbi:ODBC:DSN=<name>';

    my $safety = $self->check_sql_safety($sql, $allow_write);
    if (!$safety->{safe}) {
        return {
            ok             => 0,
            blocked        => 1,
            read_only      => $self->read_only,
            dialect        => $dialect,
            statement_type => $safety->{statement_type} // '',
            error          => $safety->{reason},
            sql            => $sql,
        };
    }

    my ($dsn, $user, $pass) = $self->resolve_db_config(
        dsn        => $req{dsn},
        user       => $req{user},
        pass       => $req{pass},
        env_prefix => $env_prefix,
    );

    if ($req{dry_run} || !defined($dsn) || !length($dsn)) {
        return {
            ok              => 1,
            mode            => 'dry_run',
            connected       => 0,
            dialect         => $dialect,
            statement_type  => $safety->{statement_type},
            read_only_check => 'passed',
            sql             => $sql,
            params          => $params,
            max_rows        => $max_rows,
            dbi_available   => $self->has_dbi,
            odbc_available  => $self->has_odbc,
            driver_hint     => $driver_hint,
            env_vars        => [ "${env_prefix}_DSN", "${env_prefix}_USER", "${env_prefix}_PASS" ],
            note            => 'No DSN configured (or dry_run requested). Pass dsn or set '
                             . "${env_prefix}_DSN to execute live over DBI/DBD::ODBC.",
        };
    }

    if (!$self->has_dbi) {
        return {
            ok        => 0,
            mode      => 'live',
            connected => 0,
            dialect   => $dialect,
            sql       => $sql,
            error     => 'DBI module is not available in @INC.',
        };
    }

    my %attr = (
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        %{ $self->{dbi_attr} || {} },
        %{ $req{dbi_attr}    || {} },
    );

    my ($dbh, $sth, @columns, @rows, $truncated, $rows_affected);
    my $ok = eval {
        $dbh = DBI->connect($dsn, $user, $pass, \%attr);
        $sth = $dbh->prepare($sql);
        my $rv = $sth->execute(@$params);
        if ($sth->{NUM_OF_FIELDS} && $sth->{NUM_OF_FIELDS} > 0) {
            @columns = @{ $sth->{NAME} || [] };
            my $n = 0;
            while (my $row = $sth->fetchrow_hashref) {
                if ($n >= $max_rows) {
                    $truncated = 1;
                    last;
                }
                push @rows, $row;
                $n++;
            }
            $sth->finish;
        }
        else {
            $rows_affected = (defined $rv && $rv ne '0E0') ? int($rv) : 0;
        }
        $dbh->disconnect;
        1;
    };
    if (!$ok) {
        my $err = $@ || 'Unknown DBI execution error';
        $err =~ s/\s+$//;
        eval { $sth->finish }     if $sth;
        eval { $dbh->disconnect } if $dbh;
        return {
            ok        => 0,
            mode      => 'live',
            connected => ($dbh ? 1 : 0),
            dialect   => $dialect,
            sql       => $sql,
            error     => $err,
        };
    }

    return {
        ok             => 1,
        mode           => 'live',
        connected      => 1,
        dialect        => $dialect,
        statement_type => $safety->{statement_type},
        sql            => $sql,
        columns        => \@columns,
        rows           => \@rows,
        row_count      => scalar(@rows),
        truncated      => $truncated ? 1 : 0,
        (defined $rows_affected ? (rows_affected => $rows_affected) : ()),
    };
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack - Base class and shared contract for NeoPerl::MT domain MCP packs

=head1 SYNOPSIS

    package NeoPerl::MCP::Pack::Example;
    use parent 'NeoPerl::MCP::Pack';

    sub meta {
        return {
            name             => 'example',
            label            => 'Example Pack',
            category         => 'general',
            version          => '0.01',
            description      => 'Example domain pack.',
            filetypes        => [qw(example)],
            upstream_credits => [],
        };
    }

    sub tools {
        my ($self) = @_;
        return [
            {
                name        => 'example_echo',
                description => 'Echo input text.',
                inputSchema => {
                    type       => 'object',
                    properties => { text => { type => 'string' } },
                    required   => ['text'],
                },
                handler => sub {
                    my ($args, $ctx) = @_;
                    return { ok => 1, text => $args->{text} };
                },
            },
        ];
    }

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack> defines the common base class inherited by all twelve
domain MCP packs in C<NeoPerl::MT>. Every pack exposes both MCP tool
definitions (for mounting into C<NeoPerl::Antigravity::EditorMCP> or serving
via C<bin/npl-mcp>) and optional LSP knowledge hooks (C<lsp_hover>,
C<lsp_completions>, C<lsp_diagnostics>, C<lsp_symbols>) consumed directly by
C<NeoPerl::LSP::Builtin>.

=head1 METHODS

=head2 new(%opts)

Constructs a pack instance. Accepts optional C<editor>, C<dsn>, C<user>,
C<pass>, C<read_only> (default C<1>), C<max_rows> (default C<200>), and
C<dbi_attr>.

=head2 meta()

Returns pack metadata hashref with keys C<name>, C<label>, C<category>,
C<version>, C<description>, C<filetypes>, and C<upstream_credits>.

=head2 tools()

Returns an arrayref of tool specifications, each containing C<name>,
C<description>, C<inputSchema>, and C<handler> (C<sub { my ($args, $ctx) = @_; ... }>).

=head2 register_into($editor_mcp)

Registers all pack tools into an C<EditorMCP>-compatible registry via
C<register_tool()>, binding pack and editor context into each handler.

=head2 list_tool_names(), tools_schema(), has_tool($name), call_tool($name, $args, $ctx)

Introspection and direct invocation helpers used by C<NeoPerl::MCP::Registry>,
C<bin/npl-mcp>, and tests.

=head2 lsp_hover($word, $line, $lang), lsp_completions($prefix, $line, $lang), lsp_diagnostics($text, $lang), lsp_symbols($text, $lang)

Optional LSP hooks with default empty/C<undef> implementations. Diagnostics use
0-based C<line>/C<col>/C<end_line>/C<end_col>, C<severity>
(C<error>|C<warn>|C<info>|C<hint>), C<code>, C<message>, and C<source>.

=head2 check_sql_safety($sql, $allow_write), execute_dbi_query(%req)

Shared read-only SQL guardrail and optional live C<DBI>/C<DBD::ODBC> query
execution helper with structured offline dry-run support.

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
