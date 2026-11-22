package NeoPerl::MCP::Pack::Informix;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

our $VERSION = '0.01';

my %HOVER_DOCS = (
    'SYSTABLES'        => "**systables** (Informix System Catalog)\n\nUser tables (`tabid >= 100`), views, synonyms, and sequences (`tabname`, `owner`, `partnum`, `nrows`, `npused`, `rowsize`, `tabtype`, `locklevel` `'R'`/`'P'`, `fextsize`, `nextsize`).",
    'SYSCOLUMNS'       => "**syscolumns** (Informix System Catalog)\n\nColumn metadata (`tabid`, `colno`, `colname`, `coltype`, `collength`). `MOD(coltype, 256)` gives base type; `coltype >= 256` indicates `NOT NULL`.",
    'SYSINDEXES'       => "**sysindexes / sysindices** (Informix System Catalog)\n\nB-tree and R-tree indexes (`idxname`, `idxtype` `'U'`/`'D'`, `clustered`, `levels`, `leaves`, `nunique`, `clust`).",
    'SYSPROCEDURES'    => "**sysprocedures** (Informix System Catalog)\n\nStored procedures and UDRs (`procid`, `procname`, `owner`, `numargs`, `isproc`, `mode`, `langid`).",
    'SYSPROCBODY'      => "**sysprocbody** (Informix System Catalog)\n\nSPL source lines (`datakey = 'T'`, `seqno`, `data`) and p-code for procedures in `sysprocedures`.",
    'SYSTRIGGERS'      => "**systriggers** (Informix System Catalog)\n\nTable triggers (`trigname`, `tabid`, `event`: `'I'`/`'U'`/`'D'`/`'S'`, `old`, `new`).",
    'SYSFRAGMENTS'     => "**sysfragments** (Informix System Catalog)\n\nTable and index storage fragmentation (`fragtype`, `strategy`, `exprtext`, `dbspace`, `partition`).",
    'SYSPTNHDR'        => "**sysmaster:sysptnhdr** (Informix SMI)\n\nPartition header statistics: `nptotal`, `npused`, `npdata`, `nrows`, `nextns` (extent count), `fextsiz`, `nextsiz`, `pagesize`.",
    'SYSLOCKS'         => "**sysmaster:syslocks** (Informix SMI)\n\nActive lock table (`dbsname`, `tabname`, `rowidlk`, `type`, `owner`, `waiter`). Non-zero `waiter` flags active lock contention.",
    'SYSSESSIONS'      => "**sysmaster:syssessions** (Informix SMI)\n\nConnected client sessions (`sid`, `username`, `pid`, `hostname`, `connected`, `feprogram`, `state`).",
    'SYSCHKIO'         => "**sysmaster:syschkio** (Informix SMI)\n\nPer-chunk read/write I/O counts, page counts, and cumulative I/O wait times.",
    'SYSPROFILE'       => "**sysmaster:sysprofile** (Informix SMI)\n\nEngine-wide performance counters (`bufreads`, `dskreads`, `lockwts`, `deadlks`, `seqscans`, `dsksorts`, `ovlock`).",
    'SERIAL'           => "**SERIAL** (Informix 32-bit Auto-Increment)\n\nSigned 32-bit integer (max 2,147,483,647). Prefer `BIGSERIAL` on high-growth tables to prevent integer wraparound.",
    'BIGSERIAL'        => "**BIGSERIAL** (Informix 64-bit Auto-Increment)\n\nNative 8-byte signed 64-bit auto-increment key (replaces legacy 10-byte `SERIAL8`).",
    'SERIAL8'          => "**SERIAL8** (Informix Legacy 64-bit Serial)\n\nUses 10 bytes on disk; prefer 8-byte `BIGSERIAL` in IDS 11.50+ for compactness and native `BIGINT` interoperability.",
    'LVARCHAR'         => "**LVARCHAR(max)** (Informix Variable Character)\n\nVariable-length character type up to 32,739 bytes (defaults to 2048 if size omitted). Match dbspace page size (4K–16K) for large rows.",
    'DATETIME'         => "**DATETIME start TO end** (Informix)\n\nPrecision-scoped timestamp, e.g. `DATETIME YEAR TO SECOND` or `DATETIME YEAR TO FRACTION(5)` (1..5 fractional digits).",
    'FOREACH'          => "**FOREACH [cursor FOR] SELECT ... INTO ... END FOREACH** (Informix SPL)\n\nIterates query rows inside an SPL routine. Use `WITH HOLD` if `COMMIT WORK` executes inside the loop.",
    'EXCEPTION'        => "**ON EXCEPTION [IN (err1, ...)] [SET sql_err, isam_err, err_data] ... END EXCEPTION [WITH RESUME]** (Informix SPL)\n\nStructured SQL/ISAM exception handler in SPL.",
    'DEFINE'           => "**DEFINE var type;** (Informix SPL)\n\nDeclares local or `GLOBAL` SPL variables. Must precede executable statements in the procedure or `BEGIN ... END` block.",
    'LET'              => "**LET var = expr;** (Informix SPL)\n\nAssigns values to one or more SPL variables.",
    'RESUME'           => "**RETURN ... WITH RESUME;** (Informix SPL)\n\nYields one row from a multi-row iterator procedure/function and resumes execution on the next fetch.",
    'ISOLATION'        => "**SET ISOLATION TO COMMITTED READ LAST COMMITTED | DIRTY READ | REPEATABLE READ**\n\n`COMMITTED READ LAST COMMITTED` avoids reader waits on uncommitted row updates without dirty reads.",
    'LOCK'             => "**LOCK MODE ROW** / **SET LOCK MODE TO WAIT n**\n\nInformix tables default to `LOCK MODE PAGE` and sessions default to `NOT WAIT`; always specify `LOCK MODE ROW` for OLTP tables and `SET LOCK MODE TO WAIT` in transactional SPL.",
    'AUTOINDEX'        => "**AUTOINDEX PATH** (`sqexplain.out`)\n\nInformix built a temporary index at runtime to execute a join. Create a permanent index on the join key to eliminate repeated build cost.",
    'STATISTICS'       => "**UPDATE STATISTICS LOW | MEDIUM | HIGH**\n\nRefreshes Informix optimizer distributions: `LOW` on tables/indexes, `MEDIUM` on non-leading columns, `HIGH` on leading index key columns.",
);

my @COMPLETION_ITEMS = (
    { label => 'systables',                                       kind => 7,  detail => 'Informix catalog',    documentation => 'User tables (tabid >= 100), nrows, locklevel.' },
    { label => 'syscolumns',                                      kind => 7,  detail => 'Informix catalog',    documentation => 'Columns, coltype, collength.' },
    { label => 'sysindexes',                                      kind => 7,  detail => 'Informix catalog',    documentation => 'Indexes, idxtype, levels, leaves, clust.' },
    { label => 'sysprocedures',                                   kind => 7,  detail => 'Informix catalog',    documentation => 'SPL procedures and UDRs.' },
    { label => 'sysprocbody',                                     kind => 7,  detail => 'Informix catalog',    documentation => 'SPL source text (datakey = T).' },
    { label => 'systriggers',                                     kind => 7,  detail => 'Informix catalog',    documentation => 'Triggers (I/U/D/S).' },
    { label => 'sysfragments',                                    kind => 7,  detail => 'Informix catalog',    documentation => 'Fragmentation expressions and dbspaces.' },
    { label => 'sysmaster:sysptnhdr',                             kind => 7,  detail => 'Informix SMI',        documentation => 'Partition pages, nrows, and nextns extent count.' },
    { label => 'sysmaster:syslocks',                              kind => 7,  detail => 'Informix SMI',        documentation => 'Active locks and waiters.' },
    { label => 'sysmaster:syssessions',                           kind => 7,  detail => 'Informix SMI',        documentation => 'Active IDS client sessions.' },
    { label => 'sysmaster:syschkio',                              kind => 7,  detail => 'Informix SMI',        documentation => 'Chunk I/O reads, writes, and timings.' },
    { label => 'sysmaster:sysprofile',                            kind => 7,  detail => 'Informix SMI',        documentation => 'Server-wide buffer, lock, and sort counters.' },
    { label => 'SET ISOLATION TO COMMITTED READ LAST COMMITTED;', kind => 15, detail => 'IDS isolation mode',  documentation => 'Non-blocking committed read (IDS 11+).' },
    { label => 'SET ISOLATION TO DIRTY READ;',                    kind => 15, detail => 'IDS isolation mode',  documentation => 'Read uncommitted rows without lock waits.' },
    { label => 'SET LOCK MODE TO WAIT 10;',                       kind => 15, detail => 'IDS lock wait',       documentation => 'Wait up to 10 seconds before returning -244/-107.' },
    { label => 'LOCK MODE ROW',                                   kind => 14, detail => 'CREATE TABLE clause', documentation => 'Row-level locking (avoids default PAGE locks).' },
    { label => 'EXTENT SIZE 1024 NEXT SIZE 1024',                 kind => 15, detail => 'Storage clause',      documentation => 'Explicit KiB initial and next extent sizing.' },
    { label => 'DATETIME YEAR TO FRACTION(5)',                    kind => 22, detail => 'Informix datatype',   documentation => 'High-precision timestamp (10 microsecond resolution).' },
    { label => 'BIGSERIAL',                                       kind => 22, detail => 'Informix datatype',   documentation => '64-bit 8-byte auto-increment key.' },
    { label => 'LVARCHAR(4096)',                                  kind => 22, detail => 'Informix datatype',   documentation => 'Variable-length string up to 32739 bytes.' },
    { label => 'ON EXCEPTION SET sql_err, isam_err, err_data',    kind => 15, detail => 'SPL exception block', documentation => 'Capture SQLCODE, ISAM error, and message text.' },
    { label => 'RETURN ... WITH RESUME;',                         kind => 15, detail => 'SPL iterator return', documentation => 'Yield row from multi-row SPL procedure/function.' },
    { label => 'UPDATE STATISTICS HIGH FOR TABLE',                kind => 15, detail => 'Optimizer stats',     documentation => 'Gather high-resolution distributions on index columns.' },
);

sub meta {
    return {
        name             => 'informix',
        label            => 'IBM Informix Dynamic Server (IDS / SPL)',
        category         => 'database',
        version          => $VERSION,
        description      => 'Informix guarded DBI/ODBC query execution, systables & sysmaster SMI inspection, SPL parser/linter, sqexplain.out analyzer, and schema/extent/lock-mode auditor.',
        filetypes        => [qw(sql spl informix)],
        upstream_credits => ['IBM Informix Dynamic Server SQL/SPL and sysmaster conventions'],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'informix_query',
            description => 'Execute a read-only-guarded SQL query against IBM Informix via DBI/DBD::ODBC or DBD::Informix (or offline dry-run validation).',
            inputSchema => {
                type       => 'object',
                properties => {
                    sql         => { type => 'string',  description => 'Informix SQL query to validate or run.' },
                    params      => { type => 'array',   description => 'Optional bind parameters.' },
                    allow_write => { type => 'boolean', description => 'Allow DML/DDL writes (default false).' },
                    max_rows    => { type => 'integer', description => 'Row fetch cap (default 200).' },
                    dsn         => { type => 'string' },
                    user        => { type => 'string' },
                    pass        => { type => 'string' },
                    dry_run     => { type => 'boolean' },
                },
                required => ['sql'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_query($args, $ctx) },
        },
        {
            name        => 'informix_catalog_inspect',
            description => 'Inspect Informix system catalogs (systables, syscolumns, sysindexes, sysprocedures, sysprocbody, systriggers, sysfragments) and sysmaster SMI tables (sysptnhdr, syslocks, syssessions, syschkio, sysprofile).',
            inputSchema => {
                type       => 'object',
                properties => {
                    target    => { type => 'string',  description => 'tables|columns|indexes|procedures|procbody|triggers|fragments|sysptnhdr|syslocks|syssessions|syschkio|sysprofile' },
                    table     => { type => 'string',  description => 'Optional table name filter.' },
                    procedure => { type => 'string',  description => 'Optional procedure name filter.' },
                    owner     => { type => 'string',  description => 'Optional owner filter.' },
                    limit     => { type => 'integer', description => 'Maximum rows (default 100).' },
                    execute   => { type => 'boolean' },
                    dsn       => { type => 'string' },
                    user      => { type => 'string' },
                    pass      => { type => 'string' },
                },
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_catalog_inspect($args, $ctx) },
        },
        {
            name        => 'informix_spl_analyze',
            description => 'Parse and lint Informix SPL (CREATE PROCEDURE/FUNCTION, DEFINE placement, FOREACH/IF/WHILE/ON EXCEPTION block balance, LET, RETURNING ... WITH RESUME, SET ISOLATION, SET LOCK MODE TO WAIT).',
            inputSchema => {
                type       => 'object',
                properties => {
                    source => { type => 'string', description => 'Informix SPL routine source code.' },
                },
                required => ['source'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_spl_analyze($args, $ctx) },
        },
        {
            name        => 'informix_explain_analyze',
            description => 'Parse Informix sqexplain.out plans (SEQUENTIAL SCAN, AUTOINDEX PATH, INDEX PATH, DYNAMIC HASH JOIN, estimated cost/rows, temp files) and generate UPDATE STATISTICS HIGH/MEDIUM/LOW commands.',
            inputSchema => {
                type       => 'object',
                properties => {
                    explain_text => { type => 'string', description => 'Raw sqexplain.out text from SET EXPLAIN ON.' },
                },
                required => ['explain_text'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_explain_analyze($args, $ctx) },
        },
        {
            name        => 'informix_schema_audit',
            description => 'Audit Informix DDL for SERIAL vs BIGSERIAL overflow, LVARCHAR/DATETIME YEAR TO FRACTION(5), LOCK MODE ROW vs PAGE, fragmentation, RAW tables, and EXTENT SIZE / NEXT SIZE.',
            inputSchema => {
                type       => 'object',
                properties => {
                    ddl => { type => 'string', description => 'Informix CREATE TABLE / CREATE INDEX DDL.' },
                },
                required => ['ddl'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_schema_audit($args, $ctx) },
        },
    ];
}

sub _clean_ident {
    my ($v) = @_;
    return '' unless defined $v && length $v;
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/[^A-Za-z0-9_\$\%\-\*]//g;
    return lc($v);
}

sub tool_query {
    my ($self, $args, $ctx) = @_;
    my $sql = $args->{sql} // '';
    return $self->execute_dbi_query(
        sql         => $sql,
        params      => $args->{params},
        allow_write => $args->{allow_write},
        max_rows    => $args->{max_rows},
        dsn         => $args->{dsn},
        user        => $args->{user},
        pass        => $args->{pass},
        dry_run     => $args->{dry_run},
        dialect     => 'informix',
        env_prefix  => 'INFORMIX',
        driver_hint => 'dbi:ODBC:DSN=<informix_dsn> (or dbi:Informix:<db>@<server>)',
    );
}

sub tool_catalog_inspect {
    my ($self, $args, $ctx) = @_;
    my $target = lc($args->{target} // 'tables');
    my $table  = _clean_ident($args->{table});
    my $proc   = _clean_ident($args->{procedure});
    my $owner  = _clean_ident($args->{owner});
    my $limit  = int($args->{limit} || 100);
    $limit = 1    if $limit < 1;
    $limit = 1000 if $limit > 1000;

    my %views = (
        tables      => 'systables',
        columns     => 'syscolumns',
        indexes     => 'sysindexes',
        procedures  => 'sysprocedures',
        procbody    => 'sysprocbody',
        triggers    => 'systriggers',
        fragments   => 'sysfragments',
        sysptnhdr   => 'sysmaster:sysptnhdr',
        syslocks    => 'sysmaster:syslocks',
        syssessions => 'sysmaster:syssessions',
        syschkio    => 'sysmaster:syschkio',
        sysprofile  => 'sysmaster:sysprofile',
    );
    if (!exists $views{$target}) {
        return {
            ok      => 0,
            error   => "Unsupported Informix catalog/SMI target '$target'.",
            allowed => [ sort keys %views ],
        };
    }

    my (@where, @params, $sql, @notes);

    if ($target eq 'tables') {
        push @where, "tabid >= 100";
        push @where, "tabname LIKE ?" if length $table;
        push @params, ($table =~ /%/ ? $table : "$table%") if length $table;
        push @where, "owner = ?"      if length $owner;
        push @params, $owner          if length $owner;
        $sql = "SELECT FIRST $limit tabid, tabname, owner, partnum, nrows, npused, rowsize, "
             . "ncols, nindexes, tabtype, locklevel, fextsize, nextsize "
             . "FROM systables WHERE " . join(' AND ', @where)
             . " ORDER BY tabname";
        push @notes, "locklevel = 'P' means PAGE locking (default); 'R' means ROW locking.";
    }
    elsif ($target eq 'columns') {
        push @where, "t.tabid >= 100";
        push @where, "t.tabname = ?" if length $table;
        push @params, $table         if length $table;
        $sql = "SELECT FIRST $limit t.tabname, c.colno, c.colname, c.coltype, "
             . "MOD(c.coltype, 256) AS base_type, "
             . "CASE WHEN c.coltype >= 256 THEN 'N' ELSE 'Y' END AS nullable, c.collength "
             . "FROM systables t JOIN syscolumns c ON c.tabid = t.tabid "
             . "WHERE " . join(' AND ', @where)
             . " ORDER BY t.tabname, c.colno";
        push @notes, 'In syscolumns, coltype >= 256 encodes NOT NULL; MOD(coltype, 256) maps to the base IDS type code (0=CHAR, 2=INT, 5=DECIMAL, 6=SERIAL, 10=DATETIME, 43=LVARCHAR, 53=BIGSERIAL).';
    }
    elsif ($target eq 'indexes') {
        push @where, "t.tabid >= 100";
        push @where, "t.tabname = ?" if length $table;
        push @params, $table         if length $table;
        $sql = "SELECT FIRST $limit t.tabname, i.idxname, i.owner, i.idxtype, i.clustered, "
             . "i.levels, i.leaves, i.nunique, i.clust "
             . "FROM systables t JOIN sysindexes i ON i.tabid = t.tabid "
             . "WHERE " . join(' AND ', @where)
             . " ORDER BY t.tabname, i.idxname";
    }
    elsif ($target eq 'procedures') {
        push @where, "procname LIKE ?" if length $proc;
        push @params, ($proc =~ /%/ ? $proc : "$proc%") if length $proc;
        push @where, "owner = ?"       if length $owner;
        push @params, $owner           if length $owner;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT FIRST $limit procid, procname, owner, mode, numargs, isproc, "
             . "specificname, langid, codesize "
             . "FROM sysprocedures$w ORDER BY procname, procid";
    }
    elsif ($target eq 'procbody') {
        push @where, "b.datakey = 'T'";
        push @where, "p.procname = ?" if length $proc;
        push @params, $proc           if length $proc;
        $sql = "SELECT FIRST $limit p.procid, p.procname, b.seqno, b.data "
             . "FROM sysprocedures p JOIN sysprocbody b ON b.procid = p.procid "
             . "WHERE " . join(' AND ', @where)
             . " ORDER BY p.procid, b.seqno";
    }
    elsif ($target eq 'triggers') {
        push @where, "t.tabname = ?" if length $table;
        push @params, $table         if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT FIRST $limit t.tabname, tr.trigname, tr.owner, tr.event, tr.old, tr.new "
             . "FROM systriggers tr JOIN systables t ON t.tabid = tr.tabid$w "
             . "ORDER BY t.tabname, tr.trigname";
    }
    elsif ($target eq 'fragments') {
        push @where, "t.tabname = ?" if length $table;
        push @params, $table         if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT FIRST $limit t.tabname, f.fragtype, f.indexname, f.strategy, "
             . "f.evalpos, f.dbspace, f.partition, f.exprtext "
             . "FROM sysfragments f JOIN systables t ON t.tabid = f.tabid$w "
             . "ORDER BY t.tabname, f.fragtype, f.evalpos";
    }
    elsif ($target eq 'sysptnhdr') {
        $sql = "SELECT FIRST $limit partnum, lockid, nptotal, npused, npdata, nrows, "
             . "nextns, fextsiz, nextsiz, pagesize "
             . "FROM sysmaster:sysptnhdr "
             . "WHERE nextns > 1 "
             . "ORDER BY nextns DESC";
        push @notes, 'High nextns (> 50 extents) indicates table/index fragmentation and recommends extent resizing or table rebuild.';
    }
    elsif ($target eq 'syslocks') {
        push @where, "tabname = ?" if length $table;
        push @params, $table       if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT FIRST $limit dbsname, tabname, rowidlk, keynum, type, owner, waiter "
             . "FROM sysmaster:syslocks$w "
             . "ORDER BY waiter DESC, owner";
        push @notes, 'Rows with waiter > 0 indicate live lock contention; join owner/waiter against sysmaster:syssessions.sid.';
    }
    elsif ($target eq 'syssessions') {
        $sql = "SELECT FIRST $limit sid, username, uid, pid, hostname, tty, connected, feprogram, state "
             . "FROM sysmaster:syssessions "
             . "ORDER BY sid";
    }
    elsif ($target eq 'syschkio') {
        $sql = "SELECT FIRST $limit chunknum, reads, pagesread, writes, pageswritten, "
             . "readtime, writetime, fname "
             . "FROM sysmaster:syschkio "
             . "ORDER BY (pagesread + pageswritten) DESC";
    }
    elsif ($target eq 'sysprofile') {
        $sql = "SELECT FIRST $limit name, value "
             . "FROM sysmaster:sysprofile "
             . "WHERE name IN ('bufreads','dskreads','bufwrites','dskwrites','lockwts','deadlks','ovlock','seqscans','dsksorts','memsorts') "
             . "ORDER BY name";
        push @notes, 'Buffer read cache hit % = (1 - dskreads / bufreads) * 100. Watch lockwts, deadlks, and dsksorts.';
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
        dialect    => 'informix',
        env_prefix => 'INFORMIX',
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

sub tool_spl_analyze {
    my ($self, $args, $ctx) = @_;
    my $src = $args->{source} // '';
    my @raw_lines = split /\n/, $src, -1;

    my @routines;
    my @defines;
    my @issues;
    my @stack;
    my @isolation_modes;
    my @lock_modes;

    my $foreach_count    = 0;
    my $let_count        = 0;
    my $has_on_exception = 0;
    my $has_with_resume  = 0;
    my $has_dml          = 0;
    my $in_brace_comment = 0;
    my $in_block_comment = 0;
    my $current_routine;

    for my $i (0 .. $#raw_lines) {
        my $ln = $raw_lines[$i];

        # Strip multi-line { ... } and /* ... */ and -- comments while keeping line index accurate
        if ($in_brace_comment) {
            if ($ln =~ s/^.*?\}/ /) { $in_brace_comment = 0 }
            else { next }
        }
        if ($in_block_comment) {
            if ($ln =~ s{^.*?\*/}{ }) { $in_block_comment = 0 }
            else { next }
        }
        $ln =~ s/\{[^}]*\}/ /g;
        if ($ln =~ s/\{.*$//) { $in_brace_comment = 1 }
        $ln =~ s{/\*.*?\*/}{ }g;
        if ($ln =~ s{/\*.*$}{}) { $in_block_comment = 1 }
        $ln =~ s/--.*$//;
        $ln =~ s/'(?:''|[^'])*'/''/g;
        $ln =~ s/^\s+|\s+$//g;
        next unless length $ln;

        # Routine header: CREATE [DBA] PROCEDURE|FUNCTION name(...) [RETURNING ...]
        if ($ln =~ /^CREATE\s+(?:DBA\s+)?(PROCEDURE|FUNCTION)\s+([A-Za-z0-9_\.\"]+)\s*\(/i) {
            my $kind = uc($1);
            my $name = $2;
            $name =~ s/"//g;
            my $has_returning = ($ln =~ /\bRETURNING\b/i) ? 1 : 0;
            $current_routine = {
                kind          => $kind,
                name          => $name,
                start_line    => $i,
                end_line      => undef,
                has_returning => $has_returning,
                seen_exec     => 0,
                with_resume   => 0,
            };
            push @routines, $current_routine;
            push @stack, { kind => $kind, line => $i, name => $name };
            next;
        }

        if ($current_routine && !$current_routine->{has_returning} && !$current_routine->{seen_exec} && $ln =~ /\bRETURNING\b/i) {
            $current_routine->{has_returning} = 1;
            next if $ln =~ /^RETURNING\b/i;
        }

        # Closing block tags
        if ($ln =~ /^END\s+(PROCEDURE|FUNCTION|FOREACH|FOR|WHILE|IF|EXCEPTION)\b/i) {
            my $close_kind = uc($1);
            if (!@stack) {
                push @issues, {
                    code     => 'SPL001',
                    severity => 'error',
                    line     => $i,
                    message  => "Unexpected END $close_kind with no matching open block.",
                };
            }
            elsif ($stack[-1]{kind} ne $close_kind) {
                my $top = pop @stack;
                push @issues, {
                    code     => 'SPL002',
                    severity => 'error',
                    line     => $i,
                    message  => "Mismatched block close: found END $close_kind, expected END $top->{kind} (opened at line " . ($top->{line} + 1) . ").",
                };
            }
            else {
                my $top = pop @stack;
                if ($close_kind eq 'PROCEDURE' || $close_kind eq 'FUNCTION') {
                    if ($current_routine) {
                        $current_routine->{end_line} = $i;
                        if ($current_routine->{with_resume} && !$current_routine->{has_returning}) {
                            push @issues, {
                                code     => 'SPL003',
                                severity => 'error',
                                line     => $current_routine->{start_line},
                                message  => "$current_routine->{kind} $current_routine->{name} uses RETURN ... WITH RESUME but lacks a RETURNING clause in its header.",
                            };
                        }
                        if ($current_routine->{kind} eq 'FUNCTION' && !$current_routine->{has_returning}) {
                            push @issues, {
                                code     => 'SPL004',
                                severity => 'error',
                                line     => $current_routine->{start_line},
                                message  => "CREATE FUNCTION $current_routine->{name} must declare a RETURNING clause.",
                            };
                        }
                    }
                    $current_routine = undef;
                }
            }
            next;
        }

        # DEFINE declarations
        if ($ln =~ /^DEFINE\s+(?:GLOBAL\s+)?(.+?)(?:;|$)/i) {
            my $decl = $1;
            push @defines, { line => $i, declaration => $decl };
            if ($current_routine && $current_routine->{seen_exec} && !(@stack && $stack[-1]{kind} eq 'BEGIN')) {
                push @issues, {
                    code     => 'SPL005',
                    severity => 'error',
                    line     => $i,
                    message  => 'DEFINE appears after executable statements outside a nested BEGIN...END block; Informix SPL requires DEFINE statements at the top of the block.',
                };
            }
            next;
        }

        # ON EXCEPTION block
        if ($ln =~ /^ON\s+EXCEPTION\b/i) {
            $has_on_exception = 1;
            my $in_set = ($ln =~ /\bSET\s+/i) ? 1 : 0;
            push @stack, { kind => 'EXCEPTION', line => $i, has_set => $in_set };
            if (!$in_set) {
                push @issues, {
                    code     => 'SPL006',
                    severity => 'hint',
                    line     => $i,
                    message  => 'ON EXCEPTION without SET sql_err, isam_err, err_data loses SQL/ISAM error diagnostics.',
                };
            }
            next;
        }

        # Mark executable statements inside routine
        if ($current_routine && $ln !~ /^(?:DOCUMENT|WITH\s+LISTING|SPECIFIC|VARIANT|NOT\s+VARIANT|HANDLESNULLS|CLASS|EXTERNAL)\b/i) {
            $current_routine->{seen_exec} = 1;
        }

        # Opening control blocks
        if ($ln =~ /^FOREACH\b/i) {
            $foreach_count++;
            my $with_hold = ($ln =~ /\bWITH\s+HOLD\b/i) ? 1 : 0;
            push @stack, { kind => 'FOREACH', line => $i, with_hold => $with_hold };
        }
        elsif ($ln =~ /^FOR\s+[A-Za-z_]/i) {
            push @stack, { kind => 'FOR', line => $i };
        }
        elsif ($ln =~ /^WHILE\b/i) {
            push @stack, { kind => 'WHILE', line => $i };
        }
        elsif ($ln =~ /^IF\b/i && $ln !~ /\bEND\s+IF\b/i) {
            push @stack, { kind => 'IF', line => $i };
        }
        elsif ($ln =~ /^BEGIN\b/i && $ln !~ /^BEGIN\s+WORK\b/i) {
            push @stack, { kind => 'BEGIN', line => $i };
        }
        elsif ($ln =~ /^END\s*;?\s*$/i && @stack && $stack[-1]{kind} eq 'BEGIN') {
            pop @stack;
        }

        # LET statements
        if ($ln =~ /^LET\b/i) {
            $let_count++;
            if ($ln !~ /=/) {
                push @issues, {
                    code     => 'SPL007',
                    severity => 'error',
                    line     => $i,
                    message  => 'LET statement is missing assignment operator (=).',
                };
            }
        }

        # RETURN ... WITH RESUME
        if ($ln =~ /\bRETURN\b.*\bWITH\s+RESUME\b/i) {
            $has_with_resume = 1;
            $current_routine->{with_resume} = 1 if $current_routine;
        }

        # Isolation & lock mode checks
        if ($ln =~ /\bSET\s+ISOLATION\s+TO\s+([A-Z\s]+?)(?:;|$)/i) {
            my $mode = uc($1);
            $mode =~ s/\s+/ /g;
            $mode =~ s/\s+$//;
            push @isolation_modes, { line => $i, mode => $mode };
            if ($mode eq 'DIRTY READ') {
                push @issues, {
                    code     => 'SPL008',
                    severity => 'warn',
                    line     => $i,
                    message  => 'SET ISOLATION TO DIRTY READ can observe uncommitted/rolled-back rows; prefer SET ISOLATION TO COMMITTED READ LAST COMMITTED on IDS 11+ unless dirty reads are intentional.',
                };
            }
        }

        if ($ln =~ /\bSET\s+LOCK\s+MODE\s+TO\s+(NOT\s+WAIT|WAIT(?:\s+\d+)?)/i) {
            my $lm = uc($1);
            $lm =~ s/\s+/ /g;
            push @lock_modes, { line => $i, mode => $lm };
            if ($lm eq 'NOT WAIT') {
                push @issues, {
                    code     => 'SPL009',
                    severity => 'warn',
                    line     => $i,
                    message  => 'SET LOCK MODE TO NOT WAIT causes immediate -244/-107 lock errors under concurrent updates; prefer SET LOCK MODE TO WAIT <seconds>.',
                };
            }
        }

        if ($ln =~ /\b(?:INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|MERGE\s+INTO)\b/i) {
            $has_dml = 1;
        }

        if ($ln =~ /\bCOMMIT\s+WORK\b/i) {
            for my $frame (reverse @stack) {
                if ($frame->{kind} eq 'FOREACH' && !$frame->{with_hold}) {
                    push @issues, {
                        code     => 'SPL010',
                        severity => 'error',
                        line     => $i,
                        message  => 'COMMIT WORK inside FOREACH without WITH HOLD closes the active cursor on the next iteration.',
                    };
                    last;
                }
            }
        }

        if ($ln =~ /\b(?:SET\s+DEBUG\s+FILE\s+TO|TRACE\s+ON)\b/i) {
            push @issues, {
                code     => 'SPL011',
                severity => 'warn',
                line     => $i,
                message  => 'SPL debug tracing (SET DEBUG FILE / TRACE ON) detected; disable before production deployment.',
            };
        }

        if ($ln =~ /^\s*SYSTEM\b/i) {
            push @issues, {
                code     => 'SPL012',
                severity => 'warn',
                line     => $i,
                message  => 'SPL SYSTEM statement executes OS shell commands on the database server host; audit inputs carefully for command injection.',
            };
        }
    }

    # Unclosed blocks remaining on stack
    for my $unclosed (reverse @stack) {
        push @issues, {
            code     => 'SPL013',
            severity => 'error',
            line     => $unclosed->{line},
            message  => "Unclosed SPL $unclosed->{kind} block opened at line " . ($unclosed->{line} + 1) . " (missing END $unclosed->{kind}).",
        };
    }

    if ($has_dml && !@lock_modes) {
        push @issues, {
            code     => 'SPL014',
            severity => 'info',
            line     => (@routines ? $routines[0]{start_line} : 0),
            message  => 'Routine performs DML without an explicit SET LOCK MODE TO WAIT <n>; sessions default to NOT WAIT and can fail with -244/-107 under brief lock contention.',
        };
    }

    return {
        ok               => 1,
        routine_count    => scalar(@routines),
        routines         => \@routines,
        define_count     => scalar(@defines),
        defines          => \@defines,
        foreach_count    => $foreach_count,
        let_count        => $let_count,
        has_on_exception => $has_on_exception,
        has_with_resume  => $has_with_resume,
        isolation_modes  => \@isolation_modes,
        lock_modes       => \@lock_modes,
        issue_count      => scalar(@issues),
        issues           => \@issues,
    };
}

sub tool_explain_analyze {
    my ($self, $args, $ctx) = @_;
    my $text = $args->{explain_text} // '';
    my @lines = split /\n/, $text, -1;

    my ($est_cost, $est_rows, $temp_files);
    my @access_paths;
    my @joins;
    my @findings;
    my @update_stats_cmds;
    my %seen_tables;
    my %index_cols;
    my $current_table = '';

    for my $i (0 .. $#lines) {
        my $ln = $lines[$i];

        if ($ln =~ /Estimated\s+Cost:\s*(\d+)/i) {
            $est_cost = int($1);
        }
        elsif ($ln =~ /Estimated\s+#\s*of\s+Rows\s+Returned:\s*(\d+)/i) {
            $est_rows = int($1);
        }
        elsif ($ln =~ /Temporary\s+Files\s+Required\s+For:\s*(.+)$/i) {
            $temp_files = $1;
            $temp_files =~ s/\s+$//;
        }
        elsif ($ln =~ /^\s*\d+\)\s+([A-Za-z0-9_\.\$]+)\s*:\s*(SEQUENTIAL\s+SCAN|INDEX\s+PATH|AUTOINDEX\s+PATH|REMOTE\s+PATH)/i) {
            my $tbl  = $1;
            my $path = uc($2);
            $path =~ s/\s+/ /g;
            $current_table = $tbl;
            $seen_tables{$tbl} = 1;
            push @access_paths, {
                table => $tbl,
                path  => $path,
                line  => $i + 1,
            };

            if ($path eq 'SEQUENTIAL SCAN') {
                push @findings, {
                    severity => 'warn',
                    table    => $tbl,
                    code     => 'IFX_SEQSCAN',
                    message  => "SEQUENTIAL SCAN on $tbl (line " . ($i + 1) . "); verify WHERE/JOIN filter selectivity and consider a covering B-tree index.",
                };
            }
            elsif ($path eq 'AUTOINDEX PATH') {
                push @findings, {
                    severity => 'error',
                    table    => $tbl,
                    code     => 'IFX_AUTOINDEX',
                    message  => "AUTOINDEX PATH on $tbl (line " . ($i + 1) . "): Informix built a temporary index at execution time for the join. Create a permanent index on the join key.",
                };
            }
        }
        elsif ($ln =~ /Index\s+Keys:\s*(.+?)(?:\s*\((Key-Only|Serial|Key-First)[^)]*\))?\s*$/i) {
            my $keys = $1;
            my $flag = $2 // '';
            $keys =~ s/^\s+|\s+$//g;
            if (@access_paths) {
                $access_paths[-1]{index_keys} = $keys;
                $access_paths[-1]{key_only}   = ($flag =~ /Key-Only/i) ? 1 : 0;
            }
            if ($current_table) {
                my ($first_col) = ($keys =~ /^([A-Za-z_][A-Za-z0-9_]*)/);
                $index_cols{$current_table}{$first_col} = 1 if defined $first_col;
            }
        }
        elsif ($ln =~ /^\s*(NESTED\s+LOOP\s+JOIN|DYNAMIC\s+HASH\s+JOIN|MERGE\s+JOIN)\b/i) {
            my $j = uc($1);
            $j =~ s/\s+/ /g;
            push @joins, { join_type => $j, line => $i + 1 };
        }
    }

    if (defined $temp_files && length $temp_files) {
        push @findings, {
            severity => 'warn',
            code     => 'IFX_TEMPFILES',
            message  => "Temporary files required for: $temp_files. Verify DBSPACETEMP configuration and index ordering to eliminate disk sorts.",
        };
    }

    for my $j (@joins) {
        if ($j->{join_type} eq 'DYNAMIC HASH JOIN') {
            push @findings, {
                severity => 'info',
                code     => 'IFX_HASHJOIN',
                message  => 'DYNAMIC HASH JOIN used; tune DS_TOTAL_MEMORY / DS_NONPDQ_QUERY_MEM if hash build spills to DBSPACETEMP.',
            };
        }
        elsif ($j->{join_type} eq 'NESTED LOOP JOIN') {
            my $bad_inner = grep { $_->{path} eq 'SEQUENTIAL SCAN' || $_->{path} eq 'AUTOINDEX PATH' } @access_paths;
            if ($bad_inner) {
                push @findings, {
                    severity => 'error',
                    code     => 'IFX_NLJ_SCAN',
                    message  => 'NESTED LOOP JOIN paired with SEQUENTIAL SCAN or AUTOINDEX PATH scales poorly; index inner join key and refresh UPDATE STATISTICS.',
                };
            }
        }
    }

    for my $tbl (sort keys %seen_tables) {
        my $short = $tbl;
        $short =~ s/^.*\.//;
        push @update_stats_cmds, "UPDATE STATISTICS LOW FOR TABLE $short;";
        push @update_stats_cmds, "UPDATE STATISTICS MEDIUM FOR TABLE $short DISTRIBUTIONS ONLY;";
        for my $col (sort keys %{ $index_cols{$tbl} || {} }) {
            push @update_stats_cmds, "UPDATE STATISTICS HIGH FOR TABLE $short ($col) DISTRIBUTIONS ONLY;";
        }
    }
    if (!@update_stats_cmds) {
        push @update_stats_cmds,
            'UPDATE STATISTICS LOW FOR TABLE <table>;',
            'UPDATE STATISTICS MEDIUM FOR TABLE <table> DISTRIBUTIONS ONLY;',
            'UPDATE STATISTICS HIGH FOR TABLE <table> (<leading_index_col>) DISTRIBUTIONS ONLY;';
    }

    return {
        ok                 => 1,
        estimated_cost     => $est_cost,
        estimated_rows     => $est_rows,
        temp_files_for     => $temp_files,
        access_paths       => \@access_paths,
        joins              => \@joins,
        findings           => \@findings,
        update_statistics  => \@update_stats_cmds,
    };
}

sub tool_schema_audit {
    my ($self, $args, $ctx) = @_;
    my $ddl = $args->{ddl} // '';
    my $clean = $self->strip_sql_comments_and_literals($ddl);
    my @lines = split /\n/, $ddl, -1;
    my @issues;
    my @recommendations;

    my $find_line = sub {
        my ($re) = @_;
        for my $i (0 .. $#lines) {
            return $i if $lines[$i] =~ $re;
        }
        return 0;
    };

    my $is_create_table = ($clean =~ /\bCREATE\s+(?:(RAW|STANDARD|TEMP|SCRATCH)\s+)?TABLE\s+([A-Za-z0-9_\.]+)/i) ? 1 : 0;
    my $table_kind = uc($1 // 'STANDARD');
    my $table_name = $2 // '';

    if ($is_create_table && $table_kind eq 'RAW') {
        push @issues, {
            code     => 'IFX_DDL001',
            severity => 'warn',
            line     => $find_line->(qr/\bCREATE\s+RAW\s+TABLE\b/i),
            message  => "CREATE RAW TABLE $table_name disables transaction logging and crash recovery; alter to STANDARD and take a Level 0 archive after bulk load.",
        };
    }

    # SERIAL vs BIGSERIAL vs SERIAL8
    if ($clean =~ /\bSERIAL\b/i && $clean !~ /\bBIGSERIAL\b/i) {
        push @issues, {
            code     => 'IFX_DDL002',
            severity => 'warn',
            line     => $find_line->(qr/\bSERIAL\b/i),
            message  => '32-bit SERIAL overflows at 2,147,483,647; use BIGSERIAL (64-bit, 8 bytes) for high-volume or long-lived tables.',
        };
    }
    if ($clean =~ /\bSERIAL8\b/i) {
        push @issues, {
            code     => 'IFX_DDL003',
            severity => 'info',
            line     => $find_line->(qr/\bSERIAL8\b/i),
            message  => 'Legacy SERIAL8 uses 10 bytes per row; IDS 11.50+ recommends 8-byte BIGSERIAL instead.',
        };
    }

    # LVARCHAR sizing check
    while ($clean =~ /\bLVARCHAR(?:\s*\(\s*(\d+)\s*\))?/ig) {
        my $sz = defined($1) ? int($1) : 2048;
        if ($sz > 32739) {
            push @issues, {
                code     => 'IFX_DDL004',
                severity => 'error',
                line     => $find_line->(qr/\bLVARCHAR\b/i),
                message  => "LVARCHAR($sz) exceeds Informix maximum length of 32,739 bytes; use CLOB for larger character payloads.",
            };
        }
        elsif ($sz > 2048) {
            push @issues, {
                code     => 'IFX_DDL005',
                severity => 'info',
                line     => $find_line->(qr/\bLVARCHAR\b/i),
                message  => "LVARCHAR($sz) exceeds 2 KiB default page size; place table in a 4K/8K/16K dbspace to avoid remainder-page I/O overhead.",
            };
        }
    }

    # DATETIME qualifier validation
    my %dt_rank = (
        YEAR => 1, MONTH => 2, DAY => 3, HOUR => 4, MINUTE => 5, SECOND => 6, FRACTION => 7,
    );
    while ($clean =~ /\bDATETIME\s+(YEAR|MONTH|DAY|HOUR|MINUTE|SECOND|FRACTION)\s+TO\s+(YEAR|MONTH|DAY|HOUR|MINUTE|SECOND|FRACTION)(?:\s*\(\s*(\d+)\s*\))?/ig) {
        my ($s, $e, $fp) = (uc($1), uc($2), $3);
        if (($dt_rank{$s} || 0) > ($dt_rank{$e} || 0)) {
            push @issues, {
                code     => 'IFX_DDL006',
                severity => 'error',
                line     => $find_line->(qr/\bDATETIME\b/i),
                message  => "Invalid Informix DATETIME range '$s TO $e': start qualifier must be larger than or equal to end qualifier (e.g. DATETIME YEAR TO FRACTION(5)).",
            };
        }
        if ($e eq 'FRACTION' && defined($fp) && ($fp < 1 || $fp > 5)) {
            push @issues, {
                code     => 'IFX_DDL007',
                severity => 'error',
                line     => $find_line->(qr/\bFRACTION\b/i),
                message  => "Invalid DATETIME FRACTION($fp): Informix supports FRACTION(1) through FRACTION(5).",
            };
        }
    }

    # LOCK MODE ROW vs PAGE
    if ($is_create_table && $table_kind ne 'TEMP' && $table_kind ne 'SCRATCH') {
        if ($clean =~ /\bLOCK\s+MODE\s+PAGE\b/i) {
            push @issues, {
                code     => 'IFX_DDL008',
                severity => 'warn',
                line     => $find_line->(qr/\bLOCK\s+MODE\s+PAGE\b/i),
                message  => 'LOCK MODE PAGE locks entire pages on concurrent updates and causes -244/-107 contention; prefer LOCK MODE ROW for OLTP tables.',
            };
        }
        elsif ($clean !~ /\bLOCK\s+MODE\s+ROW\b/i) {
            push @issues, {
                code     => 'IFX_DDL009',
                severity => 'warn',
                line     => $find_line->(qr/\bCREATE\b/i),
                message  => "Missing LOCK MODE ROW on $table_name: Informix defaults to LOCK MODE PAGE (unless DEF_TABLE_LOCKMODE=row in onconfig).",
            };
        }

        # EXTENT SIZE / NEXT SIZE audit
        if ($clean !~ /\bEXTENT\s+SIZE\b/i) {
            push @issues, {
                code     => 'IFX_DDL010',
                severity => 'info',
                line     => $find_line->(qr/\bCREATE\b/i),
                message  => "Missing EXTENT SIZE / NEXT SIZE on $table_name (defaults to 16 KiB / 16 KiB, causing rapid extent proliferation on large tables).",
            };
        }
        elsif ($clean =~ /\bEXTENT\s+SIZE\s+(\d+)/i && int($1) < 64) {
            push @issues, {
                code     => 'IFX_DDL011',
                severity => 'hint',
                line     => $find_line->(qr/\bEXTENT\s+SIZE\b/i),
                message  => "Small EXTENT SIZE ($1 KiB) may fragment quickly; size initial and next extents for projected 12-month growth.",
            };
        }

        # rootdbs check
        if ($clean =~ /\bIN\s+rootdbs\b/i) {
            push @issues, {
                code     => 'IFX_DDL012',
                severity => 'error',
                line     => $find_line->(qr/\brootdbs\b/i),
                message  => 'User table explicitly placed IN rootdbs; keep rootdbs reserved for system metadata and place user tables in dedicated data dbspaces.',
            };
        }
    }

    # Fragmentation inspection
    my $frag_strategy = 'NONE';
    if ($clean =~ /\bFRAGMENT\s+BY\s+(ROUND\s+ROBIN|EXPRESSION|RANGE|LIST)\b/i) {
        $frag_strategy = uc($1);
        $frag_strategy =~ s/\s+/ /g;
        if ($frag_strategy eq 'ROUND ROBIN') {
            push @recommendations, 'FRAGMENT BY ROUND ROBIN spreads insert load evenly across dbspaces but cannot perform fragment elimination on range predicates; use EXPRESSION or RANGE for date/partition pruning.';
        }
    }

    return {
        ok                     => 1,
        table_name             => $table_name,
        table_kind             => $is_create_table ? $table_kind : 'OTHER',
        fragmentation_strategy => $frag_strategy,
        issue_count            => scalar(@issues),
        issues                 => \@issues,
        recommendations        => \@recommendations,
    };
}

# --- LSP Knowledge Hooks ---

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef unless defined $word && length $word;
    my $u = uc($word);
    $u =~ s/^SYSMASTER://;
    if (exists $HOVER_DOCS{$u}) {
        return { contents => $HOVER_DOCS{$u}, kind => 'markdown', title => $u };
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

    if (($lang && lc($lang) eq 'spl') || $text =~ /\b(?:CREATE\s+(?:DBA\s+)?(?:PROCEDURE|FUNCTION)|FOREACH|ON\s+EXCEPTION|DEFINE\s+)\b/i) {
        my $spl = $self->tool_spl_analyze({ source => $text });
        for my $iss (@{ $spl->{issues} || [] }) {
            push @diags, $self->make_diagnostic(
                line     => $iss->{line} // 0,
                col      => 0,
                severity => $iss->{severity} || 'warn',
                code     => $iss->{code}     || 'SPL',
                message  => $iss->{message}  || '',
            );
        }
    }

    if ($text =~ /\bCREATE\s+(?:(?:RAW|STANDARD|TEMP|SCRATCH)\s+)?TABLE\b/i) {
        my $ddl = $self->tool_schema_audit({ ddl => $text });
        for my $iss (@{ $ddl->{issues} || [] }) {
            push @diags, $self->make_diagnostic(
                line     => $iss->{line} // 0,
                col      => 0,
                severity => $iss->{severity} || 'warn',
                code     => $iss->{code}     || 'IFX_DDL',
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
        if ($ln =~ /^\s*CREATE\s+(?:DBA\s+)?(PROCEDURE|FUNCTION)\s+([A-Za-z0-9_\.\"]+)/i) {
            my ($obj, $name) = (uc($1), $2);
            $name =~ s/"//g;
            push @syms, $self->make_symbol(name => $name, kind => 'function', line => $i, col => 0, detail => "Informix SPL $obj");
        }
        elsif ($ln =~ /^\s*CREATE\s+(?:(?:RAW|STANDARD|TEMP|SCRATCH)\s+)?(TABLE|VIEW|INDEX|TRIGGER)\s+([A-Za-z0-9_\.\"]+)/i) {
            my ($obj, $name) = (uc($1), $2);
            $name =~ s/"//g;
            my $kind = ($obj eq 'TABLE' || $obj eq 'VIEW') ? 'struct' : 'class';
            push @syms, $self->make_symbol(name => $name, kind => $kind, line => $i, col => 0, detail => "Informix $obj");
        }
        elsif ($ln =~ /^\s*DEFINE\s+(?:GLOBAL\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+([^;]+)/i) {
            my ($v, $t) = ($1, $2);
            $t =~ s/\s+$//;
            push @syms, $self->make_symbol(name => $v, kind => 'variable', line => $i, col => 0, detail => "SPL DEFINE $t");
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::Informix - IBM Informix Dynamic Server (IDS / SPL / sysmaster) MCP and LSP domain pack

=head1 DESCRIPTION

Provides guarded live C<DBI>/C<DBD::ODBC>/C<DBD::Informix> query execution,
Informix system catalog and C<sysmaster> SMI inspection, SPL (Stored
Procedure Language) static parsing and linting, C<sqexplain.out> plan
analysis with C<UPDATE STATISTICS> recommendations, and DDL schema auditing.

=head1 TOOLS

=over 4

=item * C<informix_query>

=item * C<informix_catalog_inspect>

=item * C<informix_spl_analyze>

=item * C<informix_explain_analyze>

=item * C<informix_schema_audit>

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
