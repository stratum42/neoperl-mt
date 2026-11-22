package NeoPerl::MCP::Pack::Db2LUW;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

our $VERSION = '0.01';

my %HOVER_DOCS = (
    'SYSCAT.TABLES'          => "**SYSCAT.TABLES** (Db2 LUW Catalog)\n\nMetadata for tables, views, aliases, and nicknames. Key columns: `TABSCHEMA`, `TABNAME`, `TYPE`, `TABLEORG` (`'R'` row vs `'C'` BLU columnar), `TBSPACE`, `CARD`, `NPAGES`, `STATS_TIME`.",
    'SYSCAT.COLUMNS'         => "**SYSCAT.COLUMNS** (Db2 LUW Catalog)\n\nColumn definitions (`COLNO`, `COLNAME`, `TYPENAME`, `LENGTH`, `SCALE`, `NULLS`, `DEFAULT`, `IDENTITY`, `GENERATED`).",
    'SYSCAT.INDEXES'         => "**SYSCAT.INDEXES** (Db2 LUW Catalog)\n\nIndex definitions (`INDSCHEMA`, `INDNAME`, `COLNAMES`, `UNIQUERULE`, `INDEXTYPE`, `NLEAF`, `NLEVELS`, `FULLKEYCARD`, `CLUSTERRATIO`).",
    'SYSCAT.ROUTINES'        => "**SYSCAT.ROUTINES** (Db2 LUW Catalog)\n\nSQL PL and external routines (`ROUTINESCHEMA`, `ROUTINENAME`, `ROUTINETYPE`, `LANGUAGE`, `DETERMINISTIC`, `SQL_DATA_ACCESS`).",
    'SYSCAT.TABLESPACES'     => "**SYSCAT.TABLESPACES** (Db2 LUW Catalog)\n\nTablespace configuration (`TBSPACE`, `TBSPACETYPE`, `DATATYPE`, `PAGESIZE`, `EXTENTSIZE`, `PREFETCHSIZE`, `BUFFERPOOLID`, `AUTORESIZE`).",
    'SYSCAT.BUFFERPOOLS'     => "**SYSCAT.BUFFERPOOLS** (Db2 LUW Catalog)\n\nBufferpool sizing (`BPNAME`, `BUFFERPOOLID`, `NPAGES` (`-2` = STMM automatic), `PAGESIZE`).",
    'MON_GET_PKG_CACHE_STMT' => "**TABLE(MON_GET_PKG_CACHE_STMT(type, executable_id, search_args, member))** (Db2 LUW Monitor)\n\nLive dynamic/static SQL statement metrics (`NUM_EXECUTIONS`, `TOTAL_CPU_TIME`, `STMT_EXEC_TIME`, `ROWS_READ`, `ROWS_RETURNED`, `POOL_DATA_L_READS`).",
    'VECTOR'                 => "**VECTOR(dimension, REAL | INT8)** (Db2 LUW 12.1.2+)\n\nNative dense vector datatype supporting up to 65,535 dimensions in `REAL` (4 bytes/dim) or `INT8` (1 byte/dim) on row-organized tables.",
    'VECTOR_DISTANCE'        => "**VECTOR_DISTANCE(v1, v2, metric)** (Db2 LUW 12.1.2+)\n\nComputes vector distance using `COSINE`, `EUCLIDEAN`, `EUCLIDEAN_SQUARED`, `DOT`, `HAMMING`, or `MANHATTAN`. Lower is closer (`DOT` returns negative inner product).",
    'VECTOR_NORM'            => "**VECTOR_NORM(v, metric)** (Db2 LUW 12.1.2+)\n\nComputes L2 (`EUCLIDEAN`) or L1 (`MANHATTAN`) norm of a `VECTOR` value.",
    'ORGANIZE'               => "**ORGANIZE BY ROW | COLUMN** (Db2 LUW Table Organization)\n\n`ORGANIZE BY ROW` fits OLTP, point lookups, and Db2 12.1.2 `VECTOR` columns. `ORGANIZE BY COLUMN` activates BLU columnar compression & SIMD scans for analytical workloads.",
    'TBSCAN'                 => "**TBSCAN** (`db2exfmt` Operator)\n\nFull table scan reading every page/column chunk. Normal for analytical BLU scans (`CTQ`), but a red flag on large OLTP row tables.",
    'IXSCAN'                 => "**IXSCAN** (`db2exfmt` Operator)\n\nIndex B-tree scan. Pair with `INCLUDE` columns to avoid subsequent `FETCH` data-page random I/O.",
    'HSJOIN'                 => "**HSJOIN** (`db2exfmt` Operator)\n\nHash join (builds hash table on inner input). Watch `SORTHEAP`/`SHEAPTHRES_SHR` for temp-tablespace hash spills.",
    'NLJOIN'                 => "**NLJOIN** (`db2exfmt` Operator)\n\nNested-loop join. Efficient when outer input is small and inner uses `IXSCAN`; dangerous when inner is a `TBSCAN`.",
    'CTQ'                    => "**CTQ** (`db2exfmt` Columnar Table Queue)\n\nBoundary operator transitioning rows between the BLU columnar CDE engine and the row-organized runtime.",
    'RUNSTATS'               => "**RUNSTATS ON TABLE schema.tab WITH DISTRIBUTION AND DETAILED INDEXES ALL**\n\nRefreshes `SYSCAT` cardinality, quantile/frequent-value distributions, and index statistics for the Db2 cost-based optimizer.",
    'MERGE'                  => "**MERGE INTO target USING source ON ...**\n\nAtomic upsert. Ensure source keys are unique per `ON` match condition to avoid `SQL0788N`.",
    'UR'                     => "**WITH UR** (Uncommitted Read)\n\nReads without acquiring row locks (dirty read). Avoid for financial/authoritative totals; `WITH CS` with `CUR_COMMIT=ON` avoids most reader/writer blocks safely.",
    'CS'                     => "**WITH CS** (Cursor Stability)\n\nDefault Db2 LUW isolation level; with `CUR_COMMIT=ON` readers see currently committed values without waiting on uncommitted writers.",
    'RS'                     => "**WITH RS** (Read Stability)\n\nHolds locks on all qualifying rows until COMMIT, preventing non-repeatable reads while allowing phantom inserts.",
    'RR'                     => "**WITH RR** (Repeatable Read)\n\nStrictest serializable isolation; locks scanned key ranges and can trigger lock escalations (`SQL0911N` / `MAXLOCKS`).",
);

my @COMPLETION_ITEMS = (
    { label => 'SYSCAT.TABLES',             kind => 7,  detail => 'Db2 LUW catalog view',   documentation => 'Tables, views, aliases, TABLEORG (R/C), and CARD.' },
    { label => 'SYSCAT.COLUMNS',            kind => 7,  detail => 'Db2 LUW catalog view',   documentation => 'Column names, types, lengths, scales, and defaults.' },
    { label => 'SYSCAT.INDEXES',            kind => 7,  detail => 'Db2 LUW catalog view',   documentation => 'Indexes, key columns, uniqueness, and leaf/level stats.' },
    { label => 'SYSCAT.ROUTINES',           kind => 7,  detail => 'Db2 LUW catalog view',   documentation => 'SQL PL and external routines.' },
    { label => 'SYSCAT.TABLESPACES',        kind => 7,  detail => 'Db2 LUW catalog view',   documentation => 'Tablespace page size, extent size, and bufferpool mapping.' },
    { label => 'SYSCAT.BUFFERPOOLS',        kind => 7,  detail => 'Db2 LUW catalog view',   documentation => 'Bufferpool page count (STMM=-2) and page size.' },
    { label => 'MON_GET_PKG_CACHE_STMT',    kind => 3,  detail => 'Monitor table function', documentation => 'Inspect live package cache CPU, exec count, and rows read.' },
    { label => 'VECTOR(768, REAL)',         kind => 22, detail => 'Db2 12.1.2+ datatype',   documentation => 'Dense float32 embedding vector column.' },
    { label => 'VECTOR(768, INT8)',         kind => 22, detail => 'Db2 12.1.2+ datatype',   documentation => 'Quantized 8-bit integer embedding vector column.' },
    { label => 'VECTOR_DISTANCE',           kind => 3,  detail => 'Db2 12.1.2+ function',   documentation => 'VECTOR_DISTANCE(v1, v2, COSINE|EUCLIDEAN|DOT)' },
    { label => 'ORGANIZE BY ROW',           kind => 14, detail => 'Table organization',     documentation => 'Row-organized table (OLTP & VECTOR compatible).' },
    { label => 'ORGANIZE BY COLUMN',        kind => 14, detail => 'BLU columnar table',     documentation => 'Column-organized BLU analytics table.' },
    { label => 'WITH UR',                   kind => 14, detail => 'Isolation clause',       documentation => 'Uncommitted read.' },
    { label => 'WITH CS',                   kind => 14, detail => 'Isolation clause',       documentation => 'Cursor stability (default).' },
    { label => 'WITH RS',                   kind => 14, detail => 'Isolation clause',       documentation => 'Read stability.' },
    { label => 'WITH RR',                   kind => 14, detail => 'Isolation clause',       documentation => 'Repeatable read.' },
    { label => 'FETCH FIRST 50 ROWS ONLY',  kind => 15, detail => 'Row limit clause',       documentation => 'Standard Db2 result set bound.' },
    { label => 'OPTIMIZE FOR 25 ROWS',      kind => 15, detail => 'Optimizer hint',         documentation => 'Favor fast first-N access path.' },
);

sub meta {
    return {
        name             => 'db2luw',
        label            => 'Db2 LUW (SYSCAT & Vector)',
        category         => 'database',
        version          => $VERSION,
        description      => 'Db2 LUW guarded ODBC execution, SYSCAT catalog inspection, db2exfmt EXPLAIN & MON_GET_PKG_CACHE_STMT analysis, Db2 12.1.2+ VECTOR DDL/query/sizing helper, and BLU/isolation SQL linter.',
        filetypes        => [qw(sql db2luw)],
        upstream_credits => ['IBM/db2-mcp-server'],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'db2luw_query',
            description => 'Execute a read-only-guarded SQL query against Db2 LUW via DBI/DBD::ODBC (or offline dry-run with lint checks).',
            inputSchema => {
                type       => 'object',
                properties => {
                    sql         => { type => 'string',  description => 'SQL query to validate or run.' },
                    params      => { type => 'array',   description => 'Optional positional bind parameters.' },
                    allow_write => { type => 'boolean', description => 'Permit DML/DDL writes (default false).' },
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
            name        => 'db2luw_catalog_inspect',
            description => 'Inspect Db2 LUW SYSCAT catalog views (TABLES, COLUMNS, INDEXES, ROUTINES, TABLESPACES, BUFFERPOOLS, PACKAGES) with live ODBC or offline SQL builder.',
            inputSchema => {
                type       => 'object',
                properties => {
                    target  => { type => 'string',  description => 'tables|columns|indexes|routines|tablespaces|bufferpools|packages' },
                    schema  => { type => 'string',  description => 'Schema filter (TABSCHEMA / ROUTINESCHEMA).' },
                    table   => { type => 'string',  description => 'Table name or LIKE pattern.' },
                    routine => { type => 'string',  description => 'Routine name filter.' },
                    limit   => { type => 'integer', description => 'Maximum rows (default 100).' },
                    execute => { type => 'boolean' },
                    dsn     => { type => 'string' },
                    user    => { type => 'string' },
                    pass    => { type => 'string' },
                },
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_catalog_inspect($args, $ctx) },
        },
        {
            name        => 'db2luw_explain_analyze',
            description => 'Parse db2exfmt access plan operator trees (TBSCAN, IXSCAN, FETCH, HSJOIN, NLJOIN, MSJOIN, SORT, TQ/CTQ, timerons) and generate MON_GET_PKG_CACHE_STMT SQL.',
            inputSchema => {
                type       => 'object',
                properties => {
                    explain_text => { type => 'string',  description => 'Raw db2exfmt output text to analyze.' },
                    schema       => { type => 'string',  description => 'Optional schema filter for MON_GET_PKG_CACHE_STMT.' },
                    limit        => { type => 'integer', description => 'Row limit for MON_GET_PKG_CACHE_STMT SQL (default 25).' },
                },
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_explain_analyze($args, $ctx) },
        },
        {
            name        => 'db2luw_vector_helper',
            description => 'Generate Db2 12.1.2+ VECTOR(dim, REAL|INT8) DDL, VECTOR_DISTANCE(..., COSINE|EUCLIDEAN|DOT) hybrid search SQL, and exact byte/row/tablespace memory sizing.',
            inputSchema => {
                type       => 'object',
                properties => {
                    schema        => { type => 'string',  description => 'Target schema (default APP).' },
                    table         => { type => 'string',  description => 'Target table name (default EMBEDDINGS).' },
                    id_column     => { type => 'string',  description => 'Primary key column name (default DOC_ID).' },
                    vector_column => { type => 'string',  description => 'Vector column name (default EMBEDDING).' },
                    dimension     => { type => 'integer', description => 'Vector dimensionality 1..65535 (default 768).' },
                    coord_type    => { type => 'string',  description => 'REAL (float32) or INT8 (default REAL).' },
                    metric        => { type => 'string',  description => 'COSINE|EUCLIDEAN|EUCLIDEAN_SQUARED|DOT|HAMMING|MANHATTAN (default COSINE).' },
                    top_k         => { type => 'integer', description => 'Top-K nearest rows (default 10).' },
                    row_count     => { type => 'integer', description => 'Estimated row count for memory sizing (default 100000).' },
                    filter_sql    => { type => 'string',  description => 'Optional relational WHERE predicate for hybrid vector search.' },
                },
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_vector_helper($args, $ctx) },
        },
        {
            name        => 'db2luw_sql_lint',
            description => 'Lint Db2 LUW SQL for isolation levels (UR/CS/RS/RR), BLU columnar (ORGANIZE BY COLUMN) vs row-organized tradeoffs, OPTIMIZE FOR, MERGE, and FETCH FIRST.',
            inputSchema => {
                type       => 'object',
                properties => {
                    sql       => { type => 'string', description => 'Db2 LUW SQL statement or DDL to lint.' },
                    table_org => { type => 'string', description => 'Optional table organization context: ROW, COLUMN, or auto.' },
                },
                required => ['sql'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_sql_lint($args, $ctx) },
        },
    ];
}

sub _clean_ident {
    my ($v, $def) = @_;
    $v = $def if !defined($v) || !length($v);
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/[^A-Za-z0-9_\$\%]//g;
    return length($v) ? uc($v) : uc($def // '');
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
        dialect     => 'db2luw',
        env_prefix  => 'DB2LUW',
        driver_hint => 'dbi:ODBC:DRIVER={IBM DB2 ODBC DRIVER};DATABASE=<db>;HOSTNAME=<host>;PORT=50000;PROTOCOL=TCPIP',
    );
    my $lint = $self->tool_sql_lint({ sql => $sql }, $ctx);
    $res->{lint_warnings} = $lint->{issues} if @{ $lint->{issues} || [] };
    return $res;
}

sub tool_catalog_inspect {
    my ($self, $args, $ctx) = @_;
    my $target  = lc($args->{target} // 'tables');
    my $schema  = defined($args->{schema})  && length($args->{schema})  ? _clean_ident($args->{schema},  '') : '';
    my $table   = defined($args->{table})   && length($args->{table})   ? _clean_ident($args->{table},   '') : '';
    my $routine = defined($args->{routine}) && length($args->{routine}) ? _clean_ident($args->{routine}, '') : '';
    my $limit   = int($args->{limit} || 100);
    $limit = 1    if $limit < 1;
    $limit = 1000 if $limit > 1000;

    my %views = (
        tables      => 'SYSCAT.TABLES',
        columns     => 'SYSCAT.COLUMNS',
        indexes     => 'SYSCAT.INDEXES',
        routines    => 'SYSCAT.ROUTINES',
        tablespaces => 'SYSCAT.TABLESPACES',
        bufferpools => 'SYSCAT.BUFFERPOOLS',
        packages    => 'SYSCAT.PACKAGES',
    );
    if (!exists $views{$target}) {
        return {
            ok      => 0,
            error   => "Unsupported Db2 LUW catalog target '$target'.",
            allowed => [ sort keys %views ],
        };
    }

    my (@where, @params, $sql, @notes);

    if ($target eq 'tables') {
        push @where, "TABSCHEMA = ?"  if length $schema;
        push @params, $schema         if length $schema;
        push @where, "TABNAME LIKE ?" if length $table;
        push @params, ($table =~ /%/ ? $table : "$table%") if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE TABSCHEMA NOT LIKE 'SYS%'";
        $sql = "SELECT TABSCHEMA, TABNAME, TYPE, TABLEORG, TBSPACE, CARD, NPAGES, FPAGES, STATS_TIME "
             . "FROM SYSCAT.TABLES$w "
             . "ORDER BY TABSCHEMA, TABNAME FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, "TABLEORG = 'C' indicates BLU column-organized tables; 'R' indicates row-organized.";
        push @notes, 'CARD = -1 or stale STATS_TIME means RUNSTATS has not been gathered.';
    }
    elsif ($target eq 'columns') {
        push @where, "TABSCHEMA = ?" if length $schema;
        push @params, $schema        if length $schema;
        push @where, "TABNAME = ?"   if length $table;
        push @params, $table         if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE TABSCHEMA NOT LIKE 'SYS%'";
        $sql = "SELECT TABSCHEMA, TABNAME, COLNO, COLNAME, TYPENAME, LENGTH, SCALE, NULLS, DEFAULT, IDENTITY "
             . "FROM SYSCAT.COLUMNS$w "
             . "ORDER BY TABSCHEMA, TABNAME, COLNO FETCH FIRST $limit ROWS ONLY WITH UR";
    }
    elsif ($target eq 'indexes') {
        push @where, "TABSCHEMA = ?" if length $schema;
        push @params, $schema        if length $schema;
        push @where, "TABNAME = ?"   if length $table;
        push @params, $table         if length $table;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE TABSCHEMA NOT LIKE 'SYS%'";
        $sql = "SELECT INDSCHEMA, INDNAME, TABSCHEMA, TABNAME, COLNAMES, UNIQUERULE, INDEXTYPE, "
             . "NLEAF, NLEVELS, FULLKEYCARD, CLUSTERRATIO "
             . "FROM SYSCAT.INDEXES$w "
             . "ORDER BY TABSCHEMA, TABNAME, INDNAME FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, 'CLUSTERRATIO < 80 on range-scanned tables indicates REORG TABLE opportunity.';
    }
    elsif ($target eq 'routines') {
        push @where, "ROUTINESCHEMA = ?"   if length $schema;
        push @params, $schema              if length $schema;
        push @where, "ROUTINENAME LIKE ?"  if length $routine;
        push @params, ($routine =~ /%/ ? $routine : "$routine%") if length $routine;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE ROUTINESCHEMA NOT LIKE 'SYS%'";
        $sql = "SELECT ROUTINESCHEMA, ROUTINENAME, SPECIFICNAME, ROUTINETYPE, LANGUAGE, "
             . "DETERMINISTIC, SQL_DATA_ACCESS, EXTERNAL_ACTION "
             . "FROM SYSCAT.ROUTINES$w "
             . "ORDER BY ROUTINESCHEMA, ROUTINENAME FETCH FIRST $limit ROWS ONLY WITH UR";
    }
    elsif ($target eq 'tablespaces') {
        $sql = "SELECT TBSPACE, TBSPACEID, TBSPACETYPE, DATATYPE, PAGESIZE, EXTENTSIZE, "
             . "PREFETCHSIZE, BUFFERPOOLID, AUTORESIZE, OVERHEAD, TRANSFERRATE "
             . "FROM SYSCAT.TABLESPACES "
             . "ORDER BY TBSPACEID FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, 'Ensure 16K or 32K PAGESIZE tablespaces for wide rows or inline Db2 12.1.2+ VECTOR columns.';
    }
    elsif ($target eq 'bufferpools') {
        $sql = "SELECT BPNAME, BUFFERPOOLID, NPAGES, PAGESIZE, ESTORE, BLOCKSIZE "
             . "FROM SYSCAT.BUFFERPOOLS "
             . "ORDER BY BUFFERPOOLID FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, 'NPAGES = -2 indicates Self-Tuning Memory Manager (STMM) automatic sizing.';
    }
    elsif ($target eq 'packages') {
        push @where, "PKGSCHEMA = ?" if length $schema;
        push @params, $schema        if length $schema;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE PKGSCHEMA NOT LIKE 'SYS%'";
        $sql = "SELECT PKGSCHEMA, PKGNAME, ISOLATION, VALID, LASTUSED, EXPLICIT_HIERARCHICAL "
             . "FROM SYSCAT.PACKAGES$w "
             . "ORDER BY PKGSCHEMA, PKGNAME FETCH FIRST $limit ROWS ONLY WITH UR";
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
        dialect    => 'db2luw',
        env_prefix => 'DB2LUW',
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

sub tool_explain_analyze {
    my ($self, $args, $ctx) = @_;
    my $text  = $args->{explain_text} // '';
    my $limit = int($args->{limit} || 25);
    $limit = 1   if $limit < 1;
    $limit = 200 if $limit > 200;

    my %op_counts;
    my @operators;
    my $total_timerons;
    my @findings;
    my @recommendations;

    my @known_ops = qw(
        RETURN TBSCAN IXSCAN FETCH HSJOIN NLJOIN MSJOIN SORT
        TQ BTQ DTQ MDTQ CTQ GRPBY TEMP UNIQUE FILTER RIDSCN
        IXAND IXOR IXA XSCAN UPDATE DELETE INSERT SHIP
    );
    my $op_re = join('|', @known_ops);

    my @lines = split /\n/, $text, -1;
    for my $i (0 .. $#lines) {
        my $ln = $lines[$i];

        if ($ln =~ /Total\s+Cost:\s*([0-9]+(?:\.[0-9]+)?)/i) {
            my $c = $1 + 0;
            $total_timerons = $c if !defined($total_timerons) || $c > $total_timerons;
        }

        # Match db2exfmt graph nodes: e.g. "( 3) TBSCAN" or "  TBSCAN  " or "3) TBSCAN: (Table Scan)"
        if ($ln =~ /^\s*(?:\(\s*(\d+)\s*\)|(\d+)\))\s*($op_re)\b(.*)$/i) {
            my $id   = defined($1) ? int($1) : int($2);
            my $op   = uc($3);
            my $rest = $4 // '';
            $op_counts{$op}++;
            my ($cost) = ($rest =~ /([0-9]+(?:\.[0-9]+)?)\s*timerons?/i);
            push @operators, {
                id       => $id,
                operator => $op,
                line     => $i + 1,
                (defined $cost ? (cost_timerons => $cost + 0) : ()),
            };
        }
        elsif ($ln =~ /\b($op_re)\b\s*(?:\(\s*(\d+)\s*\))?/ && $ln !~ /^(?:Original|Optimized|Access\s+Plan|Extended)/i) {
            my $op = uc($1);
            my $id = defined($2) ? int($2) : undef;
            # Avoid double-counting descriptive prose lines like "TBSCAN: (Table Scan)" if already captured
            if ($ln =~ /^\s*(?:[|\/\\\-+\s]*)($op_re)\s*(?:\(\s*\d+\s*\))?\s*$/i) {
                $op_counts{$op}++;
                push @operators, {
                    (defined $id ? (id => $id) : ()),
                    operator => $op,
                    line     => $i + 1,
                };
            }
        }
    }

    # Analyze detected operator patterns
    if ($op_counts{TBSCAN}) {
        if ($op_counts{CTQ}) {
            push @findings, {
                severity => 'info',
                operator => 'TBSCAN',
                count    => $op_counts{TBSCAN},
                message  => "Detected $op_counts{TBSCAN} TBSCAN(s) paired with CTQ (BLU columnar engine). Columnar synopsis-pruned TBSCANs are expected; verify synopsis skipping via MON_GET_TABLE.",
            };
        }
        else {
            push @findings, {
                severity => 'warn',
                operator => 'TBSCAN',
                count    => $op_counts{TBSCAN},
                message  => "Detected $op_counts{TBSCAN} full table scan(s) (TBSCAN) on row-organized plan; inspect WHERE predicates for missing indexes or non-SARGable expressions.",
            };
            push @recommendations, 'Add a selective B-tree index (or run db2advis -d <db> -i query.sql) and refresh RUNSTATS WITH DISTRIBUTION AND DETAILED INDEXES ALL.';
        }
    }

    if ($op_counts{NLJOIN} && $op_counts{TBSCAN}) {
        push @findings, {
            severity => 'error',
            operator => 'NLJOIN',
            message  => 'NLJOIN combined with TBSCAN detected: an unindexed inner table scan inside a nested-loop join scales quadratically (O(N*M)).',
        };
        push @recommendations, 'Index the inner join column(s) or verify table cardinality statistics so Db2 can choose HSJOIN or indexed NLJOIN.';
    }

    if ($op_counts{SORT}) {
        push @findings, {
            severity => 'warn',
            operator => 'SORT',
            count    => $op_counts{SORT},
            message  => "Detected $op_counts{SORT} SORT operator(s). Check SORTHEAP/SHEAPTHRES_SHR for spilled sorts or align an index with ORDER BY / GROUP BY.",
        };
    }

    if ($op_counts{HSJOIN}) {
        push @findings, {
            severity => 'info',
            operator => 'HSJOIN',
            count    => $op_counts{HSJOIN},
            message  => "Detected $op_counts{HSJOIN} HSJOIN operator(s). Ensure adequate SORTHEAP and accurate join-column statistics to avoid temp-space hash spills.",
        };
    }

    if ($op_counts{IXSCAN} && $op_counts{FETCH}) {
        push @findings, {
            severity => 'hint',
            operator => 'FETCH',
            count    => $op_counts{FETCH},
            message  => "IXSCAN followed by FETCH ($op_counts{FETCH}x) performs random data-page lookups; consider covering index INCLUDE (...) columns for hot queries.",
        };
    }

    if (($op_counts{CTQ} || 0) > 1) {
        push @findings, {
            severity => 'warn',
            operator => 'CTQ',
            count    => $op_counts{CTQ},
            message  => "Multiple CTQ transitions ($op_counts{CTQ}) between BLU columnar and row engines increase tuple materialization overhead.",
        };
    }

    my $tq_total = ($op_counts{TQ} || 0) + ($op_counts{BTQ} || 0) + ($op_counts{DTQ} || 0) + ($op_counts{MDTQ} || 0);
    if ($tq_total > 0) {
        push @findings, {
            severity => 'info',
            operator => 'TQ',
            count    => $tq_total,
            message  => "Detected $tq_total DPF table queue operator(s) (TQ/BTQ/DTQ/MDTQ). Verify table distribution keys (DISTRIBUTE BY HASH) to collocate joins.",
        };
    }

    if ($op_counts{TEMP}) {
        push @findings, {
            severity => 'warn',
            operator => 'TEMP',
            count    => $op_counts{TEMP},
            message  => "Detected $op_counts{TEMP} materialized TEMP operator(s); inspect correlated subqueries or CTE reuse.",
        };
    }

    my $schema_filter = '';
    if (defined $args->{schema} && length $args->{schema}) {
        my $s = _clean_ident($args->{schema}, '');
        $schema_filter = " WHERE EFFECTIVE_ISOLATION IS NOT NULL AND UPPER(STMT_TEXT) LIKE '%$s%'";
    }

    my $mon_sql = "SELECT NUM_EXECUTIONS, TOTAL_CPU_TIME, STMT_EXEC_TIME, "
                . "ROWS_READ, ROWS_RETURNED, POOL_DATA_L_READS, POOL_INDEX_L_READS, "
                . "TOTAL_SORTS, SORT_OVERFLOWS, SUBSTR(STMT_TEXT, 1, 200) AS STMT_PREVIEW "
                . "FROM TABLE(MON_GET_PKG_CACHE_STMT(NULL, NULL, NULL, -2))$schema_filter "
                . "ORDER BY TOTAL_CPU_TIME DESC FETCH FIRST $limit ROWS ONLY";

    return {
        ok                   => 1,
        parsed_operators     => \@operators,
        operator_counts      => \%op_counts,
        total_cost_timerons  => $total_timerons,
        findings             => \@findings,
        recommendations      => \@recommendations,
        mon_get_pkg_cache_sql => $mon_sql,
        capture_commands     => [
            'db2 set current explain mode explain',
            'db2 -tvf query.sql',
            'db2 set current explain mode no',
            'db2exfmt -d <dbname> -1 -o db2exfmt.out',
        ],
    };
}

sub tool_vector_helper {
    my ($self, $args, $ctx) = @_;
    my $schema   = _clean_ident($args->{schema},        'APP');
    my $table    = _clean_ident($args->{table},         'EMBEDDINGS');
    my $id_col   = _clean_ident($args->{id_column},     'DOC_ID');
    my $vec_col  = _clean_ident($args->{vector_column}, 'EMBEDDING');
    my $dim      = int($args->{dimension} || 768);
    $dim = 1     if $dim < 1;
    $dim = 65535 if $dim > 65535;

    my $ctype = uc($args->{coord_type} // 'REAL');
    $ctype = 'REAL' if $ctype eq 'FLOAT32' || $ctype eq 'FLOAT';
    $ctype = 'INT8' if $ctype eq 'INT8' || $ctype eq 'I8';
    if ($ctype ne 'REAL' && $ctype ne 'INT8') {
        return {
            ok    => 0,
            error => "Unsupported Db2 12.1.2 VECTOR coordinate type '$ctype'; use REAL or INT8.",
        };
    }

    my $metric = uc($args->{metric} // 'COSINE');
    my %valid_metrics = map { $_ => 1 } qw(COSINE EUCLIDEAN EUCLIDEAN_SQUARED DOT HAMMING MANHATTAN);
    if (!$valid_metrics{$metric}) {
        return {
            ok      => 0,
            error   => "Unsupported VECTOR_DISTANCE metric '$metric'.",
            allowed => [ sort keys %valid_metrics ],
        };
    }

    my $top_k     = int($args->{top_k}     || 10);
    $top_k = 1    if $top_k < 1;
    $top_k = 1000 if $top_k > 1000;
    my $row_count = int($args->{row_count} || 100000);
    $row_count = 1 if $row_count < 1;

    my $elem_bytes       = ($ctype eq 'REAL') ? 4 : 1;
    my $payload_bytes    = $dim * $elem_bytes;
    my $header_overhead  = 24; # Db2 inline vector descriptor & metadata overhead estimate
    my $vector_row_bytes = $payload_bytes + $header_overhead;
    my $meta_row_bytes   = 128; # ID + metadata columns estimate
    my $total_row_bytes  = $vector_row_bytes + $meta_row_bytes;

    # Recommend tablespace page size so rows fit cleanly without unnecessary out-of-row spills
    my $rec_pagesize = ($total_row_bytes <= 3800)  ? 4096
                     : ($total_row_bytes <= 7800)  ? 8192
                     : ($total_row_bytes <= 15800) ? 16384
                     : 32768;
    my $usable_page_bytes = int($rec_pagesize * 0.92);
    my $rows_per_page     = ($total_row_bytes <= $usable_page_bytes)
        ? int($usable_page_bytes / $total_row_bytes)
        : 0; # spills to LOB/long tablespace if > ~32KB

    my $total_bytes = $total_row_bytes * $row_count;
    my $total_mib   = sprintf('%.2f', $total_bytes / (1024 * 1024)) + 0;
    my $int8_mib    = sprintf('%.2f', (($dim + $header_overhead + $meta_row_bytes) * $row_count) / (1024 * 1024)) + 0;

    my $ts_name = sprintf('TS_VEC_%dK', int($rec_pagesize / 1024));
    my $ddl = <<"SQL";
CREATE TABLE $schema.$table (
    $id_col BIGINT NOT NULL GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    DOC_NAMESPACE VARCHAR(128) NOT NULL DEFAULT 'default',
    DOC_TITLE VARCHAR(512),
    UPDATED_AT TIMESTAMP NOT NULL DEFAULT CURRENT TIMESTAMP,
    $vec_col VECTOR($dim, $ctype) NOT NULL
) IN $ts_name ORGANIZE BY ROW;

CREATE INDEX $schema.IX_${table}_NS ON $schema.$table (DOC_NAMESPACE, UPDATED_AT DESC);
SQL

    my $where_clause = '';
    if (defined $args->{filter_sql} && $args->{filter_sql} =~ /\S/) {
        my $f = $args->{filter_sql};
        $f =~ s/^\s*WHERE\s+//i;
        $where_clause = "\nWHERE $f";
    }
    else {
        $where_clause = "\nWHERE t.DOC_NAMESPACE = ?";
    }

    my $hybrid_sql = <<"SQL";
SELECT t.$id_col,
       t.DOC_TITLE,
       VECTOR_DISTANCE(
           t.$vec_col,
           VECTOR(CAST(? AS CLOB), $dim, $ctype),
           $metric
       ) AS DIST
FROM $schema.$table t$where_clause
ORDER BY DIST ASC
FETCH FIRST $top_k ROWS ONLY
WITH UR;
SQL

    my @notes = (
        "Db2 LUW 12.1.2+ native VECTOR($dim, $ctype) requires ORGANIZE BY ROW tables (not BLU ORGANIZE BY COLUMN).",
        "VECTOR_DISTANCE(..., $metric) sorts smallest-first (ASC); for DOT metric Db2 returns negative inner product so ASC yields strongest match.",
        ($rows_per_page > 0
            ? "Fits inline (~$rows_per_page rows per ${rec_pagesize}B page in $ts_name)."
            : "Exceeds 32 KiB inline row limit ($total_row_bytes B); Db2 stores vector payload out-of-row — allocate a dedicated 32K bufferpool and LONG tablespace."),
    );
    if ($ctype eq 'REAL') {
        push @notes, "Switching from REAL to INT8 quantization shrinks estimated footprint from $total_mib MiB to ~$int8_mib MiB (up to 4x vector memory reduction).";
    }

    return {
        ok         => 1,
        schema     => $schema,
        table      => $table,
        dimension  => $dim,
        coord_type => $ctype,
        metric     => $metric,
        ddl        => $ddl,
        hybrid_sql => $hybrid_sql,
        sizing     => {
            bytes_per_element        => $elem_bytes,
            vector_payload_bytes     => $payload_bytes,
            vector_row_bytes_est     => $vector_row_bytes,
            total_row_bytes_est      => $total_row_bytes,
            row_count                => $row_count,
            total_bytes_est          => $total_bytes,
            total_mib_est            => $total_mib,
            int8_comparison_mib_est  => $int8_mib,
            recommended_pagesize     => $rec_pagesize,
            est_rows_per_page        => $rows_per_page,
            inline_eligible          => ($rows_per_page > 0 ? 1 : 0),
        },
        notes => \@notes,
    };
}

sub tool_sql_lint {
    my ($self, $args, $ctx) = @_;
    my $sql       = $args->{sql}       // '';
    my $table_org = uc($args->{table_org} // 'AUTO');
    my $clean     = $self->strip_sql_comments_and_literals($sql);
    my @lines     = split /\n/, $sql, -1;
    my @issues;

    my $find_line = sub {
        my ($re) = @_;
        for my $i (0 .. $#lines) {
            return $i if $lines[$i] =~ $re;
        }
        return 0;
    };

    # Isolation level checks
    if ($clean =~ /\bWITH\s+RR\b/i) {
        push @issues, {
            code     => 'DB2LUW001',
            severity => 'warn',
            line     => $find_line->(qr/\bWITH\s+RR\b/i),
            message  => 'WITH RR (Repeatable Read) acquires range/next-key locks and risks lock escalations (SQL0911N); use WITH CS (with CUR_COMMIT) or WITH RS unless strict serializability is required.',
        };
    }
    if ($clean =~ /\bWITH\s+UR\b/i && $clean =~ /\b(?:INSERT|UPDATE|DELETE|MERGE)\b/i) {
        push @issues, {
            code     => 'DB2LUW002',
            severity => 'warn',
            line     => $find_line->(qr/\bWITH\s+UR\b/i),
            message  => 'WITH UR (dirty read) combined with DML can propagate uncommitted data into persistent rows; prefer WITH CS.',
        };
    }

    # BLU columnar vs row-organized guidance
    my $is_columnar = ($table_org eq 'COLUMN' || $clean =~ /\bORGANIZE\s+BY\s+COLUMN\b/i) ? 1 : 0;
    if ($clean =~ /\bORGANIZE\s+BY\s+COLUMN\b/i && $clean =~ /\bVECTOR\s*\(/i) {
        push @issues, {
            code     => 'DB2LUW003',
            severity => 'error',
            line     => $find_line->(qr/\bORGANIZE\s+BY\s+COLUMN\b/i),
            message  => 'Db2 12.1.2+ VECTOR columns are not supported on BLU ORGANIZE BY COLUMN tables; specify ORGANIZE BY ROW.',
        };
    }
    if ($clean =~ /\bORGANIZE\s+BY\s+COLUMN\b/i && $clean =~ /\b(?:XML|LONG\s+VARCHAR|LONG\s+VARGRAPHIC)\b/i) {
        push @issues, {
            code     => 'DB2LUW004',
            severity => 'error',
            line     => $find_line->(qr/\b(?:XML|LONG\s+VARCHAR)\b/i),
            message  => 'XML and LONG VARCHAR columns are incompatible with BLU ORGANIZE BY COLUMN tables.',
        };
    }
    if ($is_columnar && $clean =~ /\bSELECT\s+\*/i) {
        push @issues, {
            code     => 'DB2LUW005',
            severity => 'warn',
            line     => $find_line->(qr/\bSELECT\s+\*/i),
            message  => 'SELECT * defeats BLU columnar projection pushdown by reading and decompressing every column stream; project only needed columns.',
        };
    }
    elsif ($clean =~ /\bSELECT\s+\*/i) {
        push @issues, {
            code     => 'DB2LUW006',
            severity => 'warn',
            line     => $find_line->(qr/\bSELECT\s+\*/i),
            message  => 'SELECT * prevents index-only access and increases bufferpool I/O; enumerate columns explicitly.',
        };
    }

    # MERGE lint
    if ($clean =~ /\bMERGE\s+INTO\b/i) {
        if ($clean !~ /\bWHEN\s+MATCHED\b/i && $clean !~ /\bWHEN\s+NOT\s+MATCHED\b/i) {
            push @issues, {
                code     => 'DB2LUW007',
                severity => 'error',
                line     => $find_line->(qr/\bMERGE\s+INTO\b/i),
                message  => 'MERGE INTO requires at least one WHEN MATCHED or WHEN NOT MATCHED clause.',
            };
        }
        else {
            push @issues, {
                code     => 'DB2LUW008',
                severity => 'hint',
                line     => $find_line->(qr/\bMERGE\s+INTO\b/i),
                message  => 'Verify the MERGE source key is deduplicated per ON condition to avoid SQL0788N (multiple matches for same target row).',
            };
        }
    }

    # Unqualified UPDATE/DELETE without WHERE
    if ($clean =~ /\b(?:UPDATE|DELETE\s+FROM)\b/i && $clean !~ /\bWHERE\b/i && $clean !~ /\bMERGE\b/i) {
        push @issues, {
            code     => 'DB2LUW009',
            severity => 'error',
            line     => $find_line->(qr/\b(?:UPDATE|DELETE)\b/i),
            message  => 'UPDATE/DELETE without a WHERE clause affects every row in the table and can exhaust active transaction log space (SQL0964C).',
        };
    }

    # LIMIT vs FETCH FIRST portability
    if ($clean =~ /\bLIMIT\s+\d+/i && $clean !~ /\bFETCH\s+FIRST\b/i) {
        push @issues, {
            code     => 'DB2LUW010',
            severity => 'info',
            line     => $find_line->(qr/\bLIMIT\s+\d+/i),
            message  => 'LIMIT requires DB2_COMPATIBILITY_VECTOR=MYS/4000 or Db2 11.1+ compatibility; FETCH FIRST n ROWS ONLY is universally portable across Db2 LUW/i/z.',
        };
    }

    if ($clean =~ /\bSELECT\b/i
        && $clean =~ /\bORDER\s+BY\b/i
        && $clean !~ /\bFETCH\s+FIRST\b/i
        && $clean !~ /\bOPTIMIZE\s+FOR\b/i
        && $clean !~ /\bLIMIT\b/i)
    {
        push @issues, {
            code     => 'DB2LUW011',
            severity => 'hint',
            line     => $find_line->(qr/\bORDER\s+BY\b/i),
            message  => 'ORDER BY without FETCH FIRST n ROWS ONLY or OPTIMIZE FOR n ROWS may choose a full SORT instead of an ordered IXSCAN.',
        };
    }

    if ($clean =~ /\bNOT\s+IN\s*\(\s*SELECT\b/i) {
        push @issues, {
            code     => 'DB2LUW012',
            severity => 'warn',
            line     => $find_line->(qr/\bNOT\s+IN\s*\(/i),
            message  => 'NOT IN (SELECT ...) returns empty results if any subquery row is NULL and inhibits anti-join optimization; prefer NOT EXISTS.',
        };
    }

    return {
        ok          => 1,
        table_org   => $is_columnar ? 'COLUMN' : ($table_org eq 'ROW' ? 'ROW' : 'AUTO'),
        issue_count => scalar(@issues),
        issues      => \@issues,
        guidance    => [
            'Use WITH CS (default with CUR_COMMIT=ON) for OLTP consistency without reader/writer blocking.',
            'Use ORGANIZE BY COLUMN (BLU) for wide analytical aggregations; ORGANIZE BY ROW for point lookups, frequent single-row updates, and VECTOR embeddings.',
            'Keep RUNSTATS current with WITH DISTRIBUTION AND DETAILED INDEXES ALL after bulk loads.',
        ],
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
    if (defined $line && $line =~ /\b(SYSCAT\.[A-Za-z0-9_]+)/i) {
        my $q = uc($1);
        return { contents => $HOVER_DOCS{$q}, kind => 'markdown', title => $q }
            if exists $HOVER_DOCS{$q};
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
    my $lint = $self->tool_sql_lint({ sql => $text });
    return [
        map {
            $self->make_diagnostic(
                line     => $_->{line} // 0,
                col      => 0,
                severity => $_->{severity} || 'warn',
                code     => $_->{code}     || 'DB2LUW',
                message  => $_->{message}  || '',
            )
        } @{ $lint->{issues} || [] }
    ];
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    return [] unless defined $text && length $text;
    my @lines = split /\n/, $text, -1;
    my @syms;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(TABLE|VIEW|INDEX|PROCEDURE|FUNCTION|TRIGGER|TABLESPACE|BUFFERPOOL)\s+([A-Za-z0-9_\.\$]+)/i) {
            my ($obj, $name) = (uc($1), $2);
            my $kind = ($obj eq 'PROCEDURE' || $obj eq 'FUNCTION') ? 'function'
                     : ($obj eq 'TABLE' || $obj eq 'VIEW')         ? 'struct'
                     : 'class';
            push @syms, $self->make_symbol(name => $name, kind => $kind, line => $i, col => 0, detail => "Db2 LUW $obj");
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::Db2LUW - Db2 LUW (SYSCAT, EXPLAIN, and 12.1.2+ VECTOR) MCP and LSP domain pack

=head1 DESCRIPTION

Provides guarded live C<DBI>/C<DBD::ODBC> query execution, C<SYSCAT> catalog
inspection, C<db2exfmt> access-plan analysis plus C<MON_GET_PKG_CACHE_STMT>
monitoring queries, Db2 12.1.2+ C<VECTOR(dim, REAL|INT8)> DDL/hybrid query
generation and memory sizing, and isolation/BLU SQL linting.

Inspired by C<IBM/db2-mcp-server>.

=head1 TOOLS

=over 4

=item * C<db2luw_query>

=item * C<db2luw_catalog_inspect>

=item * C<db2luw_explain_analyze>

=item * C<db2luw_vector_helper>

=item * C<db2luw_sql_lint>

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
