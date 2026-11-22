package NeoPerl::MCP::Pack::Db2i;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

our $VERSION = '0.01';

my %HOVER_DOCS = (
    'QSYS2.SYSTABLES'          => "**QSYS2.SYSTABLES** (Db2 for i Catalog)\n\nMetadata for tables, views, aliases, and physical/logical files (`TABLE_SCHEMA`, `TABLE_NAME`, `SYSTEM_TABLE_SCHEMA`, `SYSTEM_TABLE_NAME`, `TABLE_TYPE`, `TABLE_TEXT`).",
    'SYSTABLES'                => "**QSYS2.SYSTABLES** (Db2 for i Catalog)\n\nContains one row per table, view, alias, or materialized query table, mapping long SQL names to 10-char system names (`SYSTEM_TABLE_NAME`).",
    'QSYS2.SYSCOLUMNS'         => "**QSYS2.SYSCOLUMNS** (Db2 for i Catalog)\n\nColumn definitions including `COLUMN_NAME`, `SYSTEM_COLUMN_NAME`, `DATA_TYPE`, `LENGTH`, `NUMERIC_SCALE`, `IS_NULLABLE`, and `CCSID`.",
    'SYSCOLUMNS'               => "**QSYS2.SYSCOLUMNS** (Db2 for i Catalog)\n\nColumn definitions including `DATA_TYPE`, `LENGTH`, `CCSID`, `IS_NULLABLE`, and `COLUMN_DEFAULT`.",
    'QSYS2.SYSINDEXES'         => "**QSYS2.SYSINDEXES** (Db2 for i Catalog)\n\nRadix and Encoded Vector Indexes (EVI) (`INDEX_SCHEMA`, `INDEX_NAME`, `IS_UNIQUE`, `INDEX_TYPE`, `SPARSE`).",
    'SYSINDEXES'               => "**QSYS2.SYSINDEXES** (Db2 for i Catalog)\n\nIndex metadata including Radix (`BINARY RADIX`) and EVI (`ENCODED VECTOR`) types.",
    'QSYS2.SYSROUTINES'        => "**QSYS2.SYSROUTINES** (Db2 for i Catalog)\n\nSQL and external stored procedures and UDFs (`ROUTINE_TYPE`, `EXTERNAL_LANGUAGE`, `EXTERNAL_NAME`, `PARAMETER_STYLE`).",
    'SYSROUTINES'              => "**QSYS2.SYSROUTINES** (Db2 for i Catalog)\n\nRegistered SQL/RPGLE/COBOL/C procedures and functions.",
    'QSYS2.SYSPARTITIONSTAT'   => "**QSYS2.SYSPARTITIONSTAT** (Db2 for i Catalog)\n\nMember/partition row counts, deleted row bloat (`NUMBER_DELETED_ROWS`), `DATA_SIZE`, and open/close I/O counts.",
    'SYSPARTITIONSTAT'         => "**QSYS2.SYSPARTITIONSTAT** (Db2 for i Catalog)\n\nPhysical file member and SQL partition statistics including `NUMBER_ROWS`, `NUMBER_DELETED_ROWS`, and `DATA_SIZE`.",
    'QSYS2.ACTIVE_JOB_INFO'    => "**QSYS2.ACTIVE_JOB_INFO()** (IBM i SQL Service)\n\nTable function returning active jobs, subsystem, CPU time, temporary storage, status (`TIMW`, `LCKW`, `RUN`), and current SQL status.",
    'ACTIVE_JOB_INFO'          => "**QSYS2.ACTIVE_JOB_INFO()** (IBM i SQL Service)\n\nReplaces `WRKACTJOB` with filterable SQL (`SUBSYSTEM_LIST_FILTER`, `JOB_NAME_FILTER`, `DETAILED_INFO`).",
    'QSYS2.JOBLOG_INFO'        => "**QSYS2.JOBLOG_INFO()** (IBM i SQL Service)\n\nTable function returning job log messages (`MESSAGE_ID`, `SEVERITY`, `FROM_PROGRAM`, `MESSAGE_TEXT`, `MESSAGE_SECOND_LEVEL_TEXT`).",
    'JOBLOG_INFO'              => "**QSYS2.JOBLOG_INFO('*')** (IBM i SQL Service)\n\nQueries the current or specified job's message log via SQL.",
    'QSYS2.OBJECT_STATISTICS'  => "**QSYS2.OBJECT_STATISTICS()** (IBM i SQL Service)\n\nTable function inspecting library objects (`*PGM`, `*SRVPGM`, `*FILE`, `*DTAARA`) with size, owner, and `LAST_USED_TIMESTAMP`.",
    'OBJECT_STATISTICS'        => "**QSYS2.OBJECT_STATISTICS(OBJECT_SCHEMA, OBJTYPELIST)** (IBM i SQL Service)\n\nInspects IBM i library objects without `DSPOBJD` outfiles.",
    'QSYS2.SYSTEM_STATUS_INFO' => "**QSYS2.SYSTEM_STATUS_INFO** (IBM i SQL Service)\n\nPartition CPU utilization, configured CPUs, system ASP storage percentage, main storage size, and active job counts.",
    'SYSTEM_STATUS_INFO'       => "**QSYS2.SYSTEM_STATUS_INFO** (IBM i SQL Service)\n\nSingle-row view equivalent to `WRKSYSSTS` / `DSPSYSSTS`.",
    'QSYS2.MEMORY_POOL_INFO'   => "**QSYS2.MEMORY_POOL_INFO** (IBM i SQL Service)\n\nStorage pool sizing (`*MACHINE`, `*BASE`, `*INTERACT`, `*SPOOL`), active threads, and DB/non-DB page fault rates.",
    'MEMORY_POOL_INFO'         => "**QSYS2.MEMORY_POOL_INFO** (IBM i SQL Service)\n\nInspects IBM i main storage pools and paging behavior.",
    'QSYS2.NETSTAT_INFO'       => "**QSYS2.NETSTAT_INFO** (IBM i SQL Service)\n\nActive IPv4/IPv6 TCP/UDP connections, local/remote ports, `TCP_STATE`, and byte counters (`WRKTCPSTS`).",
    'NETSTAT_INFO'             => "**QSYS2.NETSTAT_INFO** (IBM i SQL Service)\n\nQueries live TCP/IP sockets and listeners on IBM i.",
    'CCSID'                    => "**CCSID** (Coded Character Set Identifier)\n\nIBM i column/job encoding. Common values: `37` (US EBCDIC), `1208` (UTF-8), `13488` (UCS-2), `1200` (UTF-16), `65535` (*HEX no conversion; avoid on character columns).",
    'SQLSTATE'                 => "**SQLSTATE** (5-char SQL status)\n\nPreferred over legacy `SQLCOD`. `'00000'` = success, `'01xxx'` = warning, `'02000'` = no data / end of cursor, other classes = error.",
    'SQLCOD'                   => "**SQLCOD / SQLCODE** (legacy numeric SQL status)\n\n`0` = success, `100` = not found, `< 0` = error. Prefer standard 5-character `SQLSTATE` in modern SQLRPGLE.",
    'QAQQINI'                  => "**QAQQINI** (Db2 for i Query Options File)\n\nControls SQE optimizer behavior (`PARALLEL_DEGREE`, `IGNORE_DERIVED_INDEX`, `ALLOW_COPY_DATA`, `OPEN_CURSOR_THRESHOLD`, `SQL_FAST_DELETE_ROW_COUNT`). Apply via `CHGQRYA QRYOPTLIB(...)`.",
    'RRN'                      => "**RRN(table_designator)**\n\nReturns the 1-based Relative Record Number of a row in a Db2 for i table or physical file member.",
    'FETCH'                    => "**FETCH FIRST n ROWS ONLY**\n\nLimits returned rows and guides SQE toward fast-first-N plans (pair with `OPTIMIZE FOR n ROWS` for cursors).",
    'OPTIMIZE'                 => "**OPTIMIZE FOR n ROWS**\n\nHints Db2 for i SQE to favor index probes and nested-loop joins over full table scans + hash/sort.",
    'SET OPTION'               => "**EXEC SQL SET OPTION**\n\nCompile-time SQLRPGLE precompiler options (`COMMIT = *NONE|*CHG|*CS`, `CLOSQLCSR = *ENDMOD|*ENDACTGRP`, `NAMING = *SQL|*SYS`, `DATFMT = *ISO`). Must precede executable SQL statements.",
);

my @COMPLETION_ITEMS = (
    { label => 'QSYS2.SYSTABLES',          kind => 7,  detail => 'Db2 for i catalog view',  documentation => 'Tables, views, aliases, and physical/logical files.' },
    { label => 'QSYS2.SYSCOLUMNS',         kind => 7,  detail => 'Db2 for i catalog view',  documentation => 'Column definitions, data types, lengths, and CCSIDs.' },
    { label => 'QSYS2.SYSINDEXES',         kind => 7,  detail => 'Db2 for i catalog view',  documentation => 'Radix and Encoded Vector Indexes (EVI).' },
    { label => 'QSYS2.SYSROUTINES',        kind => 7,  detail => 'Db2 for i catalog view',  documentation => 'SQL and external procedures and UDFs.' },
    { label => 'QSYS2.SYSPARTITIONSTAT',   kind => 7,  detail => 'Db2 for i catalog view',  documentation => 'Member/partition row counts, deleted rows, and sizes.' },
    { label => 'QSYS2.ACTIVE_JOB_INFO',    kind => 3,  detail => 'IBM i SQL Service UDTF',  documentation => 'Active jobs, CPU, temp storage, and job status.' },
    { label => 'QSYS2.JOBLOG_INFO',        kind => 3,  detail => 'IBM i SQL Service UDTF',  documentation => 'Job log messages by job name or current job (*).' },
    { label => 'QSYS2.OBJECT_STATISTICS',  kind => 3,  detail => 'IBM i SQL Service UDTF',  documentation => 'Library object metadata (*PGM, *SRVPGM, *FILE, *ALL).' },
    { label => 'QSYS2.SYSTEM_STATUS_INFO', kind => 7,  detail => 'IBM i SQL Service view',  documentation => 'System CPU utilization, ASP %, and active jobs.' },
    { label => 'QSYS2.MEMORY_POOL_INFO',   kind => 7,  detail => 'IBM i SQL Service view',  documentation => 'Storage pools, active threads, and fault rates.' },
    { label => 'QSYS2.NETSTAT_INFO',       kind => 7,  detail => 'IBM i SQL Service view',  documentation => 'TCP/IP connections, ports, and states.' },
    { label => 'FETCH FIRST 50 ROWS ONLY', kind => 15, detail => 'Db2 for i row limit',     documentation => 'Standard Db2 row-limit clause.' },
    { label => 'OPTIMIZE FOR 25 ROWS',     kind => 15, detail => 'SQE optimizer hint',      documentation => 'Bias SQE plan toward fast first-page delivery.' },
    { label => 'FOR READ ONLY',            kind => 14, detail => 'Cursor clause',           documentation => 'Marks SELECT/cursor read-only for blocking and performance.' },
    { label => 'WITH NC',                  kind => 14, detail => 'Isolation clause',        documentation => 'No commit isolation (IBM i *NONE).' },
    { label => 'WITH UR',                  kind => 14, detail => 'Isolation clause',        documentation => 'Uncommitted read isolation (IBM i *CHG).' },
    { label => 'WITH CS',                  kind => 14, detail => 'Isolation clause',        documentation => 'Cursor stability isolation.' },
    { label => 'EXEC SQL SET OPTION COMMIT = *NONE, CLOSQLCSR = *ENDMOD, DATFMT = *ISO;', kind => 15, detail => 'SQLRPGLE compile options', documentation => 'Recommended SQLRPGLE precompiler SET OPTION directive.' },
    { label => 'GET DIAGNOSTICS',          kind => 14, detail => 'SQL error inspection',    documentation => 'Retrieve ROW_COUNT, RETURNED_SQLSTATE, and MESSAGE_TEXT.' },
);

sub meta {
    return {
        name             => 'db2i',
        label            => 'Db2 for i (IBM i / QSYS2)',
        category         => 'database',
        version          => $VERSION,
        description      => 'Db2 for i SQL execution, QSYS2 catalog and IBM i system services, *SYS/*SQL & CCSID linter, and SQLRPGLE EXEC SQL checker.',
        filetypes        => [qw(sql db2i sqlrpgle)],
        upstream_credits => [ 'IBM/ibmi-mcp-server', 'codefori/vscode-ibmi' ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'db2i_query',
            description => 'Execute a read-only-guarded SQL query against Db2 for i via DBI/DBD::ODBC (or return structured dry-run analysis when offline).',
            inputSchema => {
                type       => 'object',
                properties => {
                    sql         => { type => 'string',  description => 'SQL statement to validate or execute.' },
                    params      => { type => 'array',   description => 'Optional positional bind parameters.' },
                    allow_write => { type => 'boolean', description => 'Allow DML/DDL writes (default false).' },
                    max_rows    => { type => 'integer', description => 'Maximum rows to fetch (default 200).' },
                    naming      => { type => 'string',  description => 'Naming convention: *SQL (dot) or *SYS (slash).' },
                    dsn         => { type => 'string',  description => 'Optional DBI DSN override.' },
                    user        => { type => 'string',  description => 'Optional DB user override.' },
                    pass        => { type => 'string',  description => 'Optional DB password override.' },
                    dry_run     => { type => 'boolean', description => 'Force offline validation without connecting.' },
                },
                required => ['sql'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_query($args, $ctx) },
        },
        {
            name        => 'db2i_catalog_inspect',
            description => 'Build and optionally run QSYS2 catalog queries (SYSTABLES, SYSCOLUMNS, SYSINDEXES, SYSROUTINES, SYSPARTITIONSTAT, SYSVIEWS, SYSCST).',
            inputSchema => {
                type       => 'object',
                properties => {
                    target  => { type => 'string',  description => 'tables|columns|indexes|routines|partition_stat|views|constraints' },
                    schema  => { type => 'string',  description => 'Library/schema name (e.g. QGPL or MYLIB).' },
                    table   => { type => 'string',  description => 'Optional table name or LIKE pattern.' },
                    routine => { type => 'string',  description => 'Optional routine name filter.' },
                    limit   => { type => 'integer', description => 'Row limit (default 100).' },
                    execute => { type => 'boolean', description => 'Execute live if DSN configured (default true).' },
                    dsn     => { type => 'string' },
                    user    => { type => 'string' },
                    pass    => { type => 'string' },
                },
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_catalog_inspect($args, $ctx) },
        },
        {
            name        => 'db2i_system_services',
            description => 'Query or generate IBM i QSYS2 system services SQL (ACTIVE_JOB_INFO, JOBLOG_INFO, OBJECT_STATISTICS, SYSTEM_STATUS_INFO, MEMORY_POOL_INFO, NETSTAT_INFO, PTF_INFO, IFS_OBJECT_STATISTICS).',
            inputSchema => {
                type       => 'object',
                properties => {
                    service     => { type => 'string',  description => 'active_job_info|joblog_info|object_statistics|system_status_info|memory_pool_info|netstat_info|ptf_info|ifs_object_statistics' },
                    subsystem   => { type => 'string',  description => 'Subsystem filter for active_job_info (e.g. QBATCH, QINTER).' },
                    job_name    => { type => 'string',  description => 'Job name for joblog_info (default *).' },
                    library     => { type => 'string',  description => 'Library name for object_statistics (default *LIBL).' },
                    object_type => { type => 'string',  description => 'Object type list for object_statistics (e.g. *PGM, *FILE, *ALL).' },
                    ifs_path    => { type => 'string',  description => 'Start path for ifs_object_statistics (default /tmp).' },
                    port        => { type => 'integer', description => 'Optional local port filter for netstat_info.' },
                    limit       => { type => 'integer', description => 'Maximum rows (default 50).' },
                    execute     => { type => 'boolean', description => 'Execute live if DSN configured (default true).' },
                    dsn         => { type => 'string' },
                    user        => { type => 'string' },
                    pass        => { type => 'string' },
                },
                required => ['service'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_system_services($args, $ctx) },
        },
        {
            name        => 'db2i_sql_lint_explain',
            description => 'Lint Db2 for i SQL for *SYS vs *SQL naming traps, CCSID/EBCDIC 37/1208/65535 pitfalls, FETCH FIRST/OPTIMIZE FOR, SARGability, and provide QAQQINI/SQE Visual Explain guidance.',
            inputSchema => {
                type       => 'object',
                properties => {
                    sql    => { type => 'string', description => 'Db2 for i SQL statement or script to lint.' },
                    naming => { type => 'string', description => 'Expected naming mode: *SQL, *SYS, or auto.' },
                },
                required => ['sql'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_sql_lint_explain($args, $ctx) },
        },
        {
            name        => 'db2i_rpg_exec_sql_check',
            description => 'Validate embedded EXEC SQL blocks in SQLRPGLE (**FREE or fixed-format): host variables, SQLSTATE/SQLCOD checks, SET OPTION COMMIT, and cursor DECLARE/OPEN/FETCH/CLOSE lifecycle.',
            inputSchema => {
                type       => 'object',
                properties => {
                    source => { type => 'string', description => 'SQLRPGLE source code to inspect.' },
                },
                required => ['source'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_rpg_exec_sql_check($args, $ctx) },
        },
    ];
}

sub _sanitize_ident {
    my ($val, $default) = @_;
    $val = $default if !defined($val) || !length($val);
    $val =~ s/^\s+|\s+$//g;
    $val =~ s/[^A-Za-z0-9_\$\@\#\*\/\.\%\-]//g;
    return length($val) ? uc($val) : uc($default // '');
}

sub _sql_quote {
    my ($s) = @_;
    $s //= '';
    $s =~ s/'/''/g;
    return "'$s'";
}

sub tool_query {
    my ($self, $args, $ctx) = @_;
    my $sql = $args->{sql} // '';
    my $res = $self->execute_dbi_query(
        sql         => $sql,
        params      => $args->{params},
        allow_write => $args->{allow_write},
        max_rows    => $args->{max_rows},
        dsn         => $args->{dsn},
        user        => $args->{user},
        pass        => $args->{pass},
        dry_run     => $args->{dry_run},
        dialect     => 'db2i',
        env_prefix  => 'DB2I',
        driver_hint => 'dbi:ODBC:DRIVER={IBM i Access ODBC Driver};SYSTEM=<host>;NAM=0;DBQ=<libl>',
    );

    my $lint = $self->tool_sql_lint_explain({ sql => $sql, naming => $args->{naming} || 'auto' }, $ctx);
    $res->{naming_detected} = $lint->{naming_detected};
    $res->{lint_warnings}   = $lint->{issues} if @{ $lint->{issues} || [] };
    return $res;
}

sub tool_catalog_inspect {
    my ($self, $args, $ctx) = @_;
    my $target  = lc($args->{target} // 'tables');
    my $schema  = defined($args->{schema}) && length($args->{schema}) ? _sanitize_ident($args->{schema}, '') : '';
    my $table   = defined($args->{table})  && length($args->{table})  ? _sanitize_ident($args->{table},  '') : '';
    my $routine = defined($args->{routine}) && length($args->{routine}) ? _sanitize_ident($args->{routine}, '') : '';
    my $limit   = int($args->{limit} || 100);
    $limit = 1    if $limit < 1;
    $limit = 1000 if $limit > 1000;

    my %views = (
        tables         => 'QSYS2.SYSTABLES',
        columns        => 'QSYS2.SYSCOLUMNS',
        indexes        => 'QSYS2.SYSINDEXES',
        routines       => 'QSYS2.SYSROUTINES',
        partition_stat => 'QSYS2.SYSPARTITIONSTAT',
        views          => 'QSYS2.SYSVIEWS',
        constraints    => 'QSYS2.SYSCST',
    );
    if (!exists $views{$target}) {
        return {
            ok      => 0,
            error   => "Unsupported Db2 for i catalog target '$target'.",
            allowed => [ sort keys %views ],
        };
    }

    my (@where, @params, $sql, @notes);
    if ($target eq 'tables') {
        push @where, "TABLE_SCHEMA = ?"     if length $schema;
        push @params, $schema               if length $schema;
        push @where, "TABLE_NAME LIKE ?"    if length $table;
        push @params, ($table =~ /%/ ? $table : "$table%") if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE SYSTEM_TABLE = 'N'";
        $sql = "SELECT TABLE_SCHEMA, TABLE_NAME, SYSTEM_TABLE_SCHEMA, SYSTEM_TABLE_NAME, "
             . "TABLE_TYPE, TABLE_TEXT, LONG_COMMENT "
             . "FROM QSYS2.SYSTABLES$w "
             . "ORDER BY TABLE_SCHEMA, TABLE_NAME FETCH FIRST $limit ROWS ONLY";
        push @notes, 'SYSTEM_TABLE_NAME exposes the 10-character IBM i physical/logical file name.';
    }
    elsif ($target eq 'columns') {
        push @where, "TABLE_SCHEMA = ?"  if length $schema;
        push @params, $schema            if length $schema;
        push @where, "TABLE_NAME = ?"    if length $table;
        push @params, $table             if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, SYSTEM_COLUMN_NAME, "
             . "DATA_TYPE, LENGTH, NUMERIC_SCALE, IS_NULLABLE, HAS_DEFAULT, COLUMN_DEFAULT, CCSID, COLUMN_TEXT "
             . "FROM QSYS2.SYSCOLUMNS$w "
             . "ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION FETCH FIRST $limit ROWS ONLY";
        push @notes, 'Inspect CCSID carefully: 65535 (*HEX) suppresses EBCDIC/UTF-8 character conversion.';
    }
    elsif ($target eq 'indexes') {
        push @where, "TABLE_SCHEMA = ?"  if length $schema;
        push @params, $schema            if length $schema;
        push @where, "TABLE_NAME = ?"    if length $table;
        push @params, $table             if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT INDEX_SCHEMA, INDEX_NAME, SYSTEM_INDEX_NAME, TABLE_SCHEMA, TABLE_NAME, "
             . "IS_UNIQUE, COLUMN_COUNT, INDEX_TYPE, SPARSE, INDEX_TEXT "
             . "FROM QSYS2.SYSINDEXES$w "
             . "ORDER BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME FETCH FIRST $limit ROWS ONLY";
        push @notes, 'INDEX_TYPE distinguishes BINARY RADIX indexes from ENCODED VECTOR (EVI) indexes.';
    }
    elsif ($target eq 'routines') {
        push @where, "ROUTINE_SCHEMA = ?"  if length $schema;
        push @params, $schema              if length $schema;
        push @where, "ROUTINE_NAME LIKE ?" if length $routine;
        push @params, ($routine =~ /%/ ? $routine : "$routine%") if length $routine;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT ROUTINE_SCHEMA, ROUTINE_NAME, SPECIFIC_NAME, ROUTINE_TYPE, EXTERNAL_LANGUAGE, "
             . "EXTERNAL_NAME, PARAMETER_STYLE, SQL_DATA_ACCESS, IS_DETERMINISTIC "
             . "FROM QSYS2.SYSROUTINES$w "
             . "ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME FETCH FIRST $limit ROWS ONLY";
        push @notes, 'EXTERNAL_NAME identifies the bound *PGM or *SRVPGM(export) for ILE RPG/COBOL/C routines.';
    }
    elsif ($target eq 'partition_stat') {
        push @where, "TABLE_SCHEMA = ?"  if length $schema;
        push @params, $schema            if length $schema;
        push @where, "TABLE_NAME = ?"    if length $table;
        push @params, $table             if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_PARTITION, SYSTEM_TABLE_MEMBER, "
             . "NUMBER_ROWS, NUMBER_DELETED_ROWS, DATA_SIZE, OPEN_OPERATIONS, LAST_USED_TIMESTAMP "
             . "FROM QSYS2.SYSPARTITIONSTAT$w "
             . "ORDER BY DATA_SIZE DESC FETCH FIRST $limit ROWS ONLY";
        push @notes, 'High NUMBER_DELETED_ROWS relative to NUMBER_ROWS indicates RGZPFM (reorganize) or REUSEDLT(*YES) opportunity.';
    }
    elsif ($target eq 'views') {
        push @where, "TABLE_SCHEMA = ?"  if length $schema;
        push @params, $schema            if length $schema;
        push @where, "TABLE_NAME LIKE ?" if length $table;
        push @params, ($table =~ /%/ ? $table : "$table%") if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT TABLE_SCHEMA, TABLE_NAME, VIEW_DEFINITION "
             . "FROM QSYS2.SYSVIEWS$w "
             . "ORDER BY TABLE_SCHEMA, TABLE_NAME FETCH FIRST $limit ROWS ONLY";
    }
    elsif ($target eq 'constraints') {
        push @where, "TABLE_SCHEMA = ?"  if length $schema;
        push @params, $schema            if length $schema;
        push @where, "TABLE_NAME = ?"    if length $table;
        push @params, $table             if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT CONSTRAINT_SCHEMA, CONSTRAINT_NAME, CONSTRAINT_TYPE, TABLE_SCHEMA, TABLE_NAME, "
             . "ENABLED, CHECK_PENDING "
             . "FROM QSYS2.SYSCST$w "
             . "ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME FETCH FIRST $limit ROWS ONLY";
    }

    my $should_exec = exists($args->{execute}) ? ($args->{execute} ? 1 : 0) : 1;
    my $exec = $self->execute_dbi_query(
        sql        => $sql,
        params     => \@params,
        max_rows   => $limit,
        dsn        => $args->{dsn},
        user       => $args->{user},
        pass       => $args->{pass},
        dry_run    => !$should_exec,
        dialect    => 'db2i',
        env_prefix => 'DB2I',
    );

    return {
        ok           => $exec->{ok},
        target       => $target,
        catalog_view => $views{$target},
        sql          => $sql,
        params       => \@params,
        notes        => \@notes,
        execution    => $exec,
    };
}

sub tool_system_services {
    my ($self, $args, $ctx) = @_;
    my $service = lc($args->{service} // 'active_job_info');
    my $limit   = int($args->{limit} || 50);
    $limit = 1   if $limit < 1;
    $limit = 500 if $limit > 500;

    my ($sql, $qsys2_obj, $authority, @notes);

    if ($service eq 'active_job_info') {
        $qsys2_obj = 'QSYS2.ACTIVE_JOB_INFO';
        $authority = '*JOBCTL or QIBM_DB_SYSMON for full job details';
        my $subsys = defined($args->{subsystem}) && length($args->{subsystem})
            ? _sanitize_ident($args->{subsystem}, '') : '';
        my $fn_args = length($subsys)
            ? "SUBSYSTEM_LIST_FILTER => " . _sql_quote($subsys)
            : "RESET_STATISTICS => 'NO'";
        $sql = "SELECT JOB_NAME, AUTHORIZATION_NAME, SUBSYSTEM, JOB_TYPE, FUNCTION_TYPE, FUNCTION, "
             . "JOB_STATUS, CPU_TIME, TEMPORARY_STORAGE, ELAPSED_CPU_PERCENTAGE, SQL_STATEMENT_STATUS "
             . "FROM TABLE(QSYS2.ACTIVE_JOB_INFO($fn_args)) "
             . "ORDER BY CPU_TIME DESC FETCH FIRST $limit ROWS ONLY";
        push @notes, 'Check JOB_STATUS = LCKW or MSGW first when triaging stalled batch/SQL jobs.';
    }
    elsif ($service eq 'joblog_info') {
        $qsys2_obj = 'QSYS2.JOBLOG_INFO';
        $authority = '*JOBCTL for other users jobs; none needed for current job (*)';
        my $job = defined($args->{job_name}) && length($args->{job_name}) ? $args->{job_name} : '*';
        $sql = "SELECT ORDINAL_POSITION, MESSAGE_ID, MESSAGE_TYPE, SEVERITY, MESSAGE_TIMESTAMP, "
             . "FROM_PROGRAM, MESSAGE_TEXT, MESSAGE_SECOND_LEVEL_TEXT "
             . "FROM TABLE(QSYS2.JOBLOG_INFO(" . _sql_quote($job) . ")) "
             . "ORDER BY ORDINAL_POSITION DESC FETCH FIRST $limit ROWS ONLY";
        push @notes, 'Filter SEVERITY >= 30 or MESSAGE_ID LIKE \'SQL%\' / \'CPF%\' to isolate failures.';
    }
    elsif ($service eq 'object_statistics') {
        $qsys2_obj = 'QSYS2.OBJECT_STATISTICS';
        $authority = 'Object existence / *USE authority on target library';
        my $lib  = _sanitize_ident($args->{library}, '*LIBL');
        my $type = _sanitize_ident($args->{object_type}, '*ALL');
        $sql = "SELECT OBJNAME, OBJTYPE, OBJATTRIBUTE, OBJSIZE, OBJOWNER, OBJCREATED, "
             . "LAST_USED_TIMESTAMP, OBJTEXT "
             . "FROM TABLE(QSYS2.OBJECT_STATISTICS(OBJECT_SCHEMA => " . _sql_quote($lib)
             . ", OBJTYPELIST => " . _sql_quote($type) . ")) "
             . "ORDER BY OBJSIZE DESC FETCH FIRST $limit ROWS ONLY";
        push @notes, 'Pass OBJTYPELIST such as *PGM, *SRVPGM, *FILE, or *DTAARA to narrow library scans.';
    }
    elsif ($service eq 'system_status_info') {
        $qsys2_obj = 'QSYS2.SYSTEM_STATUS_INFO';
        $authority = 'Public read (detailed CPU fields require *JOBCTL or QIBM_DB_SYSMON)';
        $sql = "SELECT HOST_NAME, PARTITION_NAME, PARTITION_ID, CONFIGURED_CPUS, CURRENT_CPU_CAPACITY, "
             . "AVERAGE_CPU_UTILIZATION, SYSTEM_ASP_STORAGE, SYSTEM_ASP_USED, MAIN_STORAGE_SIZE, "
             . "ACTIVE_JOBS_IN_SYSTEM, TOTAL_JOBS_IN_SYSTEM "
             . "FROM QSYS2.SYSTEM_STATUS_INFO";
        push @notes, 'Watch SYSTEM_ASP_USED > 80% and temporary storage growth in ACTIVE_JOB_INFO.';
    }
    elsif ($service eq 'memory_pool_info') {
        $qsys2_obj = 'QSYS2.MEMORY_POOL_INFO';
        $authority = 'Public read';
        $sql = "SELECT POOL_NAME, SYSTEM_POOL_ID, SUBSYSTEM_NAME, CURRENT_SIZE, DEFINED_SIZE, "
             . "RESERVED_SIZE, MAXIMUM_ACTIVE_THREADS, CURRENT_THREADS, DATABASE_FAULTS, "
             . "NON_DATABASE_FAULTS, PAGING_OPTION "
             . "FROM QSYS2.MEMORY_POOL_INFO "
             . "ORDER BY SYSTEM_POOL_ID FETCH FIRST $limit ROWS ONLY";
        push @notes, 'High NON_DATABASE_FAULTS or thrashing threads indicate pool undersizing or QPFRADJ contention.';
    }
    elsif ($service eq 'netstat_info') {
        $qsys2_obj = 'QSYS2.NETSTAT_INFO';
        $authority = '*IOSYSCFG or QIBM_DB_SYSMON';
        my $where = '';
        if (defined $args->{port} && $args->{port} =~ /^\d+$/) {
            $where = ' WHERE LOCAL_PORT = ' . int($args->{port});
        }
        $sql = "SELECT LOCAL_ADDRESS, LOCAL_PORT, REMOTE_ADDRESS, REMOTE_PORT, CONNECTION_TYPE, "
             . "TCP_STATE, BYTES_SENT_LOCALLY, BYTES_RECEIVED_LOCALLY, IDLE_TIME "
             . "FROM QSYS2.NETSTAT_INFO$where "
             . "ORDER BY LOCAL_PORT FETCH FIRST $limit ROWS ONLY";
        push @notes, 'DRDA/DDM uses port 446/448 (TLS); IBM i Host Server Database uses 8471/9471 (TLS).';
    }
    elsif ($service eq 'ptf_info') {
        $qsys2_obj = 'QSYS2.PTF_INFO';
        $authority = 'Public read';
        $sql = "SELECT PTF_PRODUCT_ID, PTF_IDENTIFIER, PTF_LOADED_STATUS, PTF_IPL_ACTION, "
             . "PTF_STATUS_TIMESTAMP "
             . "FROM QSYS2.PTF_INFO "
             . "ORDER BY PTF_STATUS_TIMESTAMP DESC FETCH FIRST $limit ROWS ONLY";
        push @notes, 'Join or cross-check QSYS2.GROUP_PTF_INFO for Db2 for i TR / SF99xxx group PTF currency.';
    }
    elsif ($service eq 'ifs_object_statistics') {
        $qsys2_obj = 'QSYS2.IFS_OBJECT_STATISTICS';
        $authority = '*R/*X authority along IFS path';
        my $path = defined($args->{ifs_path}) && length($args->{ifs_path}) ? $args->{ifs_path} : '/tmp';
        $sql = "SELECT PATH_NAME, OBJECT_TYPE, DATA_SIZE, ALLOCATED_SIZE, CCSID, "
             . "CREATE_TIMESTAMP, LAST_USED_TIMESTAMP, OBJECT_OWNER "
             . "FROM TABLE(QSYS2.IFS_OBJECT_STATISTICS(START_PATH_NAME => " . _sql_quote($path)
             . ", SUBTREE_DIRECTORIES => 'NO')) "
             . "ORDER BY DATA_SIZE DESC FETCH FIRST $limit ROWS ONLY";
    }
    else {
        return {
            ok      => 0,
            error   => "Unsupported IBM i system service '$service'.",
            allowed => [qw(
                active_job_info joblog_info object_statistics system_status_info
                memory_pool_info netstat_info ptf_info ifs_object_statistics
            )],
        };
    }

    my $should_exec = exists($args->{execute}) ? ($args->{execute} ? 1 : 0) : 1;
    my $exec = $self->execute_dbi_query(
        sql        => $sql,
        max_rows   => $limit,
        dsn        => $args->{dsn},
        user       => $args->{user},
        pass       => $args->{pass},
        dry_run    => !$should_exec,
        dialect    => 'db2i',
        env_prefix => 'DB2I',
    );

    return {
        ok                 => $exec->{ok},
        service            => $service,
        qsys2_object       => $qsys2_obj,
        required_authority => $authority,
        sql                => $sql,
        notes              => \@notes,
        execution          => $exec,
    };
}

sub tool_sql_lint_explain {
    my ($self, $args, $ctx) = @_;
    my $sql    = $args->{sql}    // '';
    my $naming = uc($args->{naming} // 'AUTO');

    my $clean = $self->strip_sql_comments_and_literals($sql);
    my @lines = split /\n/, $sql, -1;
    my @issues;

    my $find_line = sub {
        my ($re) = @_;
        for my $i (0 .. $#lines) {
            return $i if $lines[$i] =~ $re;
        }
        return 0;
    };

    # Detect *SYS (LIB/FILE) vs *SQL (SCHEMA.TABLE) naming after FROM/JOIN/INTO/UPDATE/TABLE
    my @sys_refs = ($clean =~ /\b(?:FROM|JOIN|INTO|UPDATE|TABLE)\s+([A-Za-z0-9_\$\@\#]+\/[A-Za-z0-9_\$\@\#]+)/ig);
    my @sql_refs = ($clean =~ /\b(?:FROM|JOIN|INTO|UPDATE|TABLE)\s+([A-Za-z0-9_\$\@\#]+\.[A-Za-z0-9_\$\@\#]+)/ig);

    my $detected = (@sys_refs && @sql_refs) ? 'MIXED'
                 : (@sys_refs)              ? '*SYS'
                 : (@sql_refs)              ? '*SQL'
                 : 'UNQUALIFIED';

    if ($detected eq 'MIXED') {
        push @issues, {
            code     => 'DB2I001',
            severity => 'error',
            line     => $find_line->(qr{[A-Za-z0-9_]+/[A-Za-z0-9_]+}),
            message  => "Mixed *SYS (LIB/FILE: $sys_refs[0]) and *SQL (SCHEMA.TABLE: $sql_refs[0]) naming in the same SQL statement; IBM i rejects mixed naming under a single NAM setting.",
        };
    }
    elsif ($naming eq '*SQL' && $detected eq '*SYS') {
        push @issues, {
            code     => 'DB2I002',
            severity => 'error',
            line     => $find_line->(qr{[A-Za-z0-9_]+/[A-Za-z0-9_]+}),
            message  => "Found *SYS slash qualification ($sys_refs[0]) while expected naming mode is *SQL (use dot SCHEMA.TABLE).",
        };
    }
    elsif ($naming eq '*SYS' && $detected eq '*SQL') {
        push @issues, {
            code     => 'DB2I003',
            severity => 'error',
            line     => $find_line->(qr{[A-Za-z0-9_]+\.[A-Za-z0-9_]+}),
            message  => "Found *SQL dot qualification ($sql_refs[0]) while expected naming mode is *SYS (use slash LIB/FILE or switch NAMING = *SQL).",
        };
    }

    # CCSID 65535 / EBCDIC 37 vs UTF-8 1208 checks
    if ($clean =~ /\bCCSID\s*(?:=\s*|\(\s*)?65535\b/i) {
        push @issues, {
            code     => 'DB2I004',
            severity => 'error',
            line     => $find_line->(qr/\bCCSID\s*(?:=\s*|\(\s*)?65535\b/i),
            message  => 'CCSID 65535 (*HEX) suppresses character conversion and corrupts ODBC/UTF-8 text exchange; use CCSID 1208 (UTF-8) or 37 (US EBCDIC) for character columns, or BINARY/VARBINARY for raw bytes.',
        };
    }
    if ($clean =~ /\bCCSID\s*(?:=\s*|\(\s*)?37\b/i && $clean =~ /\bCCSID\s*(?:=\s*|\(\s*)?(?:1208|1200|13488)\b/i) {
        push @issues, {
            code     => 'DB2I005',
            severity => 'warn',
            line     => $find_line->(qr/\bCCSID\s*(?:=\s*|\(\s*)?(?:37|1208|1200|13488)\b/i),
            message  => 'Mixing EBCDIC CCSID 37 with Unicode CCSID 1208/13488 forces SQE runtime CCSID translation and can prevent index-key matching unless a matching derived index or CAST is aligned.',
        };
    }

    # SELECT * check
    if ($clean =~ /\bSELECT\s+\*/i) {
        push @issues, {
            code     => 'DB2I006',
            severity => 'warn',
            line     => $find_line->(qr/\bSELECT\s+\*/i),
            message  => 'SELECT * pulls all columns from the physical file/table, preventing index-only access and risking record-format mismatches.',
        };
    }

    # Unbounded SELECT without FETCH FIRST / LIMIT / aggregates
    if ($clean =~ /\bSELECT\b/i
        && $clean !~ /\bFETCH\s+FIRST\b/i
        && $clean !~ /\bLIMIT\s+\d+/i
        && $clean !~ /\b(?:COUNT|SUM|AVG|MIN|MAX)\s*\(/i
        && $clean !~ /\bINTO\b/i)
    {
        push @issues, {
            code     => 'DB2I007',
            severity => 'info',
            line     => $find_line->(qr/\bSELECT\b/i),
            message  => 'Unbounded SELECT without FETCH FIRST n ROWS ONLY or OPTIMIZE FOR n ROWS; consider bounding result sets for SQE plan stability.',
        };
    }

    # Non-SARGable predicate checks
    if ($clean =~ /\bWHERE\b.*\b(?:UPPER|LOWER|TRIM|SUBSTR|SUBSTRING|YEAR|MONTH|CHAR|DIGITS)\s*\(/is) {
        push @issues, {
            code     => 'DB2I008',
            severity => 'warn',
            line     => $find_line->(qr/\b(?:UPPER|LOWER|TRIM|SUBSTR|SUBSTRING|YEAR|MONTH|CHAR|DIGITS)\s*\(/i),
            message  => 'Function wrapped around column in WHERE predicate can disable Radix index probe; consider a Db2 for i derived index (CREATE INDEX ... ON t (UPPER(col))) or range predicate.',
        };
    }

    if ($clean =~ /\bLIKE\s+''/i && $sql =~ /\bLIKE\s+'%/i) {
        push @issues, {
            code     => 'DB2I009',
            severity => 'warn',
            line     => $find_line->(qr/\bLIKE\s+'%/i),
            message  => 'Leading wildcard LIKE \'%...\' forces a full table scan or full index scan in SQE.',
        };
    }

    if ($clean =~ /\bSELECT\b/i && $clean =~ /\bORDER\s+BY\b/i && $clean !~ /\bOPTIMIZE\s+FOR\b/i && $clean !~ /\bFETCH\s+FIRST\b/i) {
        push @issues, {
            code     => 'DB2I010',
            severity => 'hint',
            line     => $find_line->(qr/\bORDER\s+BY\b/i),
            message  => 'ORDER BY on a large result set without OPTIMIZE FOR n ROWS may choose a full temporary sort over an ordered index scan.',
        };
    }

    my @qaqqini_guidance = (
        'Use ACS Visual Explain or QSYS2.DUMP_PLAN_CACHE_PROPERTIES / STRDBMON to inspect SQE vs CQE execution.',
        'QAQQINI IGNORE_DERIVED_INDEX = *YES (default on modern IBM i) enables SQE even when legacy DDS select/omit logical files exist.',
        'QAQQINI PARALLEL_DEGREE = *OPTIMIZE (requires Db2 Symmetric Multiprocessing feature 5770-SS1 opt 26) parallelizes large scans/joins.',
        'For ODBC/JDBC connections, set NAM=0 (*SQL) or NAM=1 (*SYS) consistently and avoid job CCSID 65535.',
    );

    return {
        ok               => 1,
        naming_detected  => $detected,
        sys_references   => \@sys_refs,
        sql_references   => \@sql_refs,
        issue_count      => scalar(@issues),
        issues           => \@issues,
        qaqqini_guidance => \@qaqqini_guidance,
    };
}

sub tool_rpg_exec_sql_check {
    my ($self, $args, $ctx) = @_;
    my $src = $args->{source} // '';
    my @lines = split /\n/, $src, -1;

    my %declared_vars;
    my @blocks;
    my @issues;

    # Collect RPGLE DCL-S / DCL-DS / DCL-PI / DCL-C declarations for host-var cross-check
    for my $i (0 .. $#lines) {
        my $ln = $lines[$i];
        if ($ln =~ /^\s*DCL-(?:S|DS|C|PARM)\s+([A-Za-z_\$\@\#][A-Za-z0-9_\$\@\#]*)/i) {
            $declared_vars{ uc($1) } = $i;
        }
        elsif ($ln =~ /^\s*([A-Za-z_\$\@\#][A-Za-z0-9_\$\@\#]*)\s+(?:CHAR|VARCHAR|PACKED|ZONED|INT|UNS|IND|DATE|TIME|TIMESTAMP|BINDEC|FLOAT|LIKE)\s*\(/i) {
            $declared_vars{ uc($1) } = $i;
        }
        elsif ($ln =~ /^.{5}[Dd]\s*([A-Za-z_\$\@\#][A-Za-z0-9_\$\@\#]*)\s+[SsCcUuEe]/i) {
            $declared_vars{ uc($1) } = $i;
        }
    }

    # Extract **FREE EXEC SQL ... ; and fixed-format C/EXEC SQL ... C/END-EXEC blocks
    my $in_sql     = 0;
    my $sql_mode   = '';
    my $start_line = 0;
    my $buf        = '';

    for my $i (0 .. $#lines) {
        my $raw = $lines[$i];
        my $ln  = $raw;
        $ln =~ s{//.*$}{}; # strip **FREE line comments

        if (!$in_sql) {
            if ($ln =~ m{^.{5}[Cc]/\s*EXEC\s+SQL\b(.*)$}i) {
                $in_sql     = 1;
                $sql_mode   = 'fixed';
                $start_line = $i;
                $buf        = $1;
                if ($buf =~ m{/END-EXEC}i) {
                    $buf =~ s{/END-EXEC.*$}{}i;
                    push @blocks, { start_line => $start_line, end_line => $i, mode => 'fixed', sql => $buf };
                    $in_sql = 0;
                    $buf    = '';
                }
            }
            elsif ($ln =~ /\bEXEC\s+SQL\b(.*)$/i) {
                $in_sql     = 1;
                $sql_mode   = 'free';
                $start_line = $i;
                $buf        = $1;
                if ($buf =~ s/;.*$//) {
                    push @blocks, { start_line => $start_line, end_line => $i, mode => 'free', sql => $buf };
                    $in_sql = 0;
                    $buf    = '';
                }
            }
        }
        else {
            if ($sql_mode eq 'fixed') {
                if ($ln =~ m{^.{5}[Cc]/\s*END-EXEC\b}i) {
                    push @blocks, { start_line => $start_line, end_line => $i, mode => 'fixed', sql => $buf };
                    $in_sql = 0;
                    $buf    = '';
                }
                else {
                    my $frag = $ln;
                    $frag =~ s/^.{5}[Cc]\+//;
                    $buf .= ' ' . $frag;
                }
            }
            else {
                $buf .= ' ' . $ln;
                if ($buf =~ s/;.*$//) {
                    push @blocks, { start_line => $start_line, end_line => $i, mode => 'free', sql => $buf };
                    $in_sql = 0;
                    $buf    = '';
                }
            }
        }
    }

    if ($in_sql) {
        push @issues, {
            code     => 'SQLRPG001',
            severity => 'error',
            line     => $start_line,
            message  => "Unterminated EXEC SQL block starting at line " . ($start_line + 1) . " (missing ';' or C/END-EXEC).",
        };
    }

    my $has_set_option    = 0;
    my $has_commit_option = 0;
    my %cursors; # name => { declared => line, opened => line, fetched => count, closed => line }
    my @all_host_vars;
    my %seen_hv;

    for my $idx (0 .. $#blocks) {
        my $b   = $blocks[$idx];
        my $sql = $b->{sql};
        $sql =~ s/^\s+|\s+$//g;
        $sql =~ s/\s+/ /g;
        $b->{normalized} = $sql;
        my $clean = $self->strip_sql_comments_and_literals($sql);

        # Identify statement kind
        if ($clean =~ /^SET\s+OPTION\b/i) {
            $has_set_option = 1;
            $b->{kind} = 'SET_OPTION';
            $has_commit_option = 1 if $clean =~ /\bCOMMIT\s*=/i;
            if ($idx > 0) {
                push @issues, {
                    code     => 'SQLRPG002',
                    severity => 'warn',
                    line     => $b->{start_line},
                    message  => 'EXEC SQL SET OPTION should appear before all other executable SQL statements in the module.',
                };
            }
            next;
        }

        if ($clean =~ /^INCLUDE\s+SQLCA\b/i) {
            $b->{kind} = 'INCLUDE';
            next;
        }

        # Cursor lifecycle tracking
        if ($clean =~ /^DECLARE\s+([A-Za-z_][A-Za-z0-9_\$]*)\s+(?:(?:INSENSITIVE|SENSITIVE|ASENSITIVE|SCROLL|NO\s+SCROLL)\s+)*CURSOR\b/i) {
            my $cname = uc($1);
            $b->{kind}   = 'DECLARE_CURSOR';
            $b->{cursor} = $cname;
            $cursors{$cname}{declared} = $b->{start_line};
            if ($clean =~ /\bSELECT\s+\*/i) {
                push @issues, {
                    code     => 'SQLRPG008',
                    severity => 'warn',
                    line     => $b->{start_line},
                    message  => "Cursor $cname uses SELECT *; enumerate columns explicitly to keep RPGLE host data structures safe.",
                };
            }
            if ($clean !~ /\bFOR\s+(?:READ|FETCH)\s+ONLY\b/i && $clean !~ /\bFOR\s+UPDATE\b/i) {
                push @issues, {
                    code     => 'SQLRPG009',
                    severity => 'hint',
                    line     => $b->{start_line},
                    message  => "Cursor $cname omits FOR READ ONLY (or FOR UPDATE); adding FOR READ ONLY improves blocking on Db2 for i.",
                };
            }
        }
        elsif ($clean =~ /^OPEN\s+([A-Za-z_][A-Za-z0-9_\$]*)\b/i) {
            my $cname = uc($1);
            $b->{kind}   = 'OPEN_CURSOR';
            $b->{cursor} = $cname;
            $cursors{$cname}{opened} = $b->{start_line};
        }
        elsif ($clean =~ /^FETCH\b(?:.*?\bFROM\b)?\s+([A-Za-z_][A-Za-z0-9_\$]*)\b/i) {
            my $cname = uc($1);
            $b->{kind}   = 'FETCH_CURSOR';
            $b->{cursor} = $cname;
            $cursors{$cname}{fetched} = ($cursors{$cname}{fetched} || 0) + 1;
            $cursors{$cname}{first_fetch} //= $b->{start_line};
        }
        elsif ($clean =~ /^CLOSE\s+([A-Za-z_][A-Za-z0-9_\$]*)\b/i) {
            my $cname = uc($1);
            $b->{kind}   = 'CLOSE_CURSOR';
            $b->{cursor} = $cname;
            $cursors{$cname}{closed} = $b->{start_line};
        }
        else {
            my ($verb) = ($clean =~ /^([A-Za-z]+)/);
            $b->{kind} = uc($verb || 'SQL');
        }

        # Extract host variables (:var or :ds.sub)
        my @hvs;
        while ($clean =~ /(?:^|[\s,\(\)=\+\-\*\/<>]):([A-Za-z_\$\@\#][A-Za-z0-9_\$\@\#\.]*)/g) {
            my $hv = $1;
            push @hvs, $hv;
            if (!$seen_hv{ uc($hv) }++) {
                push @all_host_vars, $hv;
            }
            my ($base) = split /\./, $hv;
            if (keys(%declared_vars) && !exists $declared_vars{ uc($base) }) {
                push @issues, {
                    code     => 'SQLRPG004',
                    severity => 'warn',
                    line     => $b->{start_line},
                    message  => "Host variable ':$hv' is not matched by a DCL-S/DCL-DS declaration in this source snippet (verify /COPY or scope).",
                };
            }
        }
        $b->{host_vars} = \@hvs;

        # Check SQLSTATE / SQLCOD verification within the next 6 lines after executable SQL
        if ($b->{kind} ne 'DECLARE_CURSOR' && $b->{kind} ne 'SET_OPTION' && $b->{kind} ne 'INCLUDE') {
            my $end_scan = $b->{end_line} + 8;
            $end_scan = $#lines if $end_scan > $#lines;
            my $window = join("\n", @lines[ ($b->{end_line} + 1) .. $end_scan ]);
            if ($window !~ /\b(?:SQLSTATE|SQLSTT|SQLCOD|SQLCODE)\b/i) {
                push @issues, {
                    code     => 'SQLRPG005',
                    severity => 'warn',
                    line     => $b->{end_line},
                    message  => "Executable EXEC SQL ($b->{kind}) is not followed by an SQLSTATE or SQLCOD check.",
                };
            }
            elsif ($window =~ /\bSQLCOD\b/i && $window !~ /\bSQLSTATE\b/i) {
                push @issues, {
                    code     => 'SQLRPG006',
                    severity => 'hint',
                    line     => $b->{end_line},
                    message  => 'Uses legacy SQLCOD check; prefer standard 5-character SQLSTATE (e.g. \'00000\' / \'02000\').',
                };
            }
        }
    }

    if (@blocks && !$has_set_option) {
        push @issues, {
            code     => 'SQLRPG003',
            severity => 'warn',
            line     => 0,
            message  => 'Missing EXEC SQL SET OPTION directive (e.g. COMMIT = *NONE, CLOSQLCSR = *ENDMOD, DATFMT = *ISO); relying on CRTSQLRPGI command defaults causes non-portable builds.',
        };
    }
    elsif ($has_set_option && !$has_commit_option) {
        push @issues, {
            code     => 'SQLRPG007',
            severity => 'info',
            line     => 0,
            message  => 'EXEC SQL SET OPTION omits COMMIT = *NONE|*CHG|*CS; declare commitment control explicitly.',
        };
    }

    # Cursor lifecycle audit
    for my $cname (sort keys %cursors) {
        my $c = $cursors{$cname};
        if (defined $c->{opened} && !defined $c->{declared}) {
            push @issues, {
                code     => 'SQLRPG010',
                severity => 'error',
                line     => $c->{opened},
                message  => "OPEN $cname references a cursor with no DECLARE $cname CURSOR in this source.",
            };
        }
        if (defined $c->{opened} && !defined $c->{closed}) {
            push @issues, {
                code     => 'SQLRPG011',
                severity => 'error',
                line     => $c->{opened},
                message  => "Cursor $cname is OPENed but never CLOSEd (open data path / cursor leak hazard).",
            };
        }
        if ($c->{fetched} && !defined $c->{opened}) {
            push @issues, {
                code     => 'SQLRPG012',
                severity => 'error',
                line     => $c->{first_fetch} // 0,
                message  => "FETCH from cursor $cname without a matching OPEN $cname.",
            };
        }
        if (defined $c->{declared} && !defined $c->{opened}) {
            push @issues, {
                code     => 'SQLRPG013',
                severity => 'warn',
                line     => $c->{declared},
                message  => "Cursor $cname is DECLAREd but never OPENed.",
            };
        }
    }

    return {
        ok             => 1,
        exec_sql_count => scalar(@blocks),
        blocks         => \@blocks,
        host_variables => \@all_host_vars,
        cursors        => \%cursors,
        has_set_option => $has_set_option,
        issue_count    => scalar(@issues),
        issues         => \@issues,
    };
}

# --- LSP Knowledge Hooks ---

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef unless defined $word && length $word;
    my $u = uc($word);
    if (exists $HOVER_DOCS{$u}) {
        return { contents => $HOVER_DOCS{$u}, kind => 'markdown', title => $u };
    }
    if (defined $line && $line =~ /\b(QSYS2\.[A-Za-z0-9_]+)/i) {
        my $q = uc($1);
        return { contents => $HOVER_DOCS{$q}, kind => 'markdown', title => $q }
            if exists $HOVER_DOCS{$q};
    }
    if (defined $line && $line =~ /\bSET\s+OPTION\b/i && ($u eq 'SET' || $u eq 'OPTION')) {
        return { contents => $HOVER_DOCS{'SET OPTION'}, kind => 'markdown', title => 'EXEC SQL SET OPTION' };
    }
    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $p = uc($prefix // '');
    my @out;
    for my $item (@COMPLETION_ITEMS) {
        if (!length($p) || index(uc($item->{label}), $p) >= 0) {
            push @out, { %$item };
        }
    }
    return \@out;
}

sub lsp_diagnostics {
    my ($self, $text, $lang) = @_;
    return [] unless defined $text && length $text;
    my @diags;
    if (($lang && lc($lang) eq 'sqlrpgle') || $text =~ /\bEXEC\s+SQL\b/i) {
        my $chk = $self->tool_rpg_exec_sql_check({ source => $text });
        for my $iss (@{ $chk->{issues} || [] }) {
            push @diags, $self->make_diagnostic(
                line     => $iss->{line} // 0,
                col      => 0,
                severity => $iss->{severity} || 'warn',
                code     => $iss->{code}     || 'SQLRPG',
                message  => $iss->{message}  || '',
            );
        }
    }
    else {
        my $lint = $self->tool_sql_lint_explain({ sql => $text });
        for my $iss (@{ $lint->{issues} || [] }) {
            push @diags, $self->make_diagnostic(
                line     => $iss->{line} // 0,
                col      => 0,
                severity => $iss->{severity} || 'warn',
                code     => $iss->{code}     || 'DB2I',
                message  => $iss->{message}  || '',
            );
        }
    }
    return \@diags;
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    return [] unless defined $text && length $text;
    my @lines = split /\n/, $text, -1;
    my @syms;
    for my $i (0 .. $#lines) {
        my $ln = $lines[$i];
        if ($ln =~ /^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(TABLE|VIEW|INDEX|PROCEDURE|FUNCTION|TRIGGER|ALIAS)\s+([A-Za-z0-9_\.\$\@\#\/]+)/i) {
            my ($obj, $name) = (uc($1), $2);
            my $kind = ($obj eq 'PROCEDURE' || $obj eq 'FUNCTION') ? 'function'
                     : ($obj eq 'TABLE' || $obj eq 'VIEW')         ? 'struct'
                     : 'class';
            push @syms, $self->make_symbol(name => $name, kind => $kind, line => $i, col => 0, detail => "Db2 for i $obj");
        }
        elsif ($ln =~ /\bDECLARE\s+([A-Za-z_][A-Za-z0-9_\$]*)\s+(?:[A-Z]+\s+)*CURSOR\b/i) {
            push @syms, $self->make_symbol(name => $1, kind => 'variable', line => $i, col => 0, detail => 'EXEC SQL CURSOR');
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::Db2i - Db2 for i (IBM i / QSYS2) MCP and LSP domain pack

=head1 DESCRIPTION

Provides guarded live C<DBI>/C<DBD::ODBC> query execution,
C<QSYS2> catalog and IBM i system service SQL builders, C<*SYS>/C<*SQL>
naming and CCSID/EBCDIC linting, SQE/C<QAQQINI> guidance, and embedded
SQLRPGLE C<EXEC SQL> lifecycle validation.

Inspired by C<IBM/ibmi-mcp-server> and C<codefori/vscode-ibmi>.

=head1 TOOLS

=over 4

=item * C<db2i_query>

=item * C<db2i_catalog_inspect>

=item * C<db2i_system_services>

=item * C<db2i_sql_lint_explain>

=item * C<db2i_rpg_exec_sql_check>

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
