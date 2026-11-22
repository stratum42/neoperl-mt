package NeoPerl::MCP::Pack::Db2z;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

our $VERSION = '0.01';

my %HOVER_DOCS = (
    'SYSIBM.SYSTABLES'     => "**SYSIBM.SYSTABLES** (Db2 for z/OS Catalog)\n\nMetadata for tables, views, aliases, and MQTs (`CREATOR`, `NAME`, `DBNAME`, `TSNAME`, `TYPE`, `CARDF`, `NPAGESF`, `STATSTIME`).",
    'SYSIBM.SYSCOLUMNS'    => "**SYSIBM.SYSCOLUMNS** (Db2 for z/OS Catalog)\n\nColumn definitions (`TBCREATOR`, `TBNAME`, `COLNO`, `NAME`, `COLTYPE`, `LENGTH`, `SCALE`, `NULLS`, `COLCARDF`, `KEYSEQ`).",
    'SYSIBM.SYSINDEXES'    => "**SYSIBM.SYSINDEXES** (Db2 for z/OS Catalog)\n\nIndex metadata (`UNIQUERULE`, `CLUSTERING`, `CLUSTERED`, `NLEAF`, `NLEVELS`, `FULLKEYCARDF`, `PADDED`, `INDEXTYPE`).",
    'SYSIBM.SYSTABLESPACE' => "**SYSIBM.SYSTABLESPACE** (Db2 for z/OS Catalog)\n\nTablespace attributes (`TYPE`: `'G'` = UTS PBG, `'R'` = UTS PBR, `PGSIZE`, `SEGSIZE`, `MAXPARTITIONS`, `PARTITIONS`, `DSSIZE`, `BPOOL`, `LOCKRULE`).",
    'SYSIBM.SYSTABLEPART'  => "**SYSIBM.SYSTABLEPART** (Db2 for z/OS Catalog)\n\nPartition physical stats (`PARTITION`, `CARD`, `NEARINDREF`, `FARINDREF`, `PERCACTIVE`, `PCTFREE`, `FREEPAGE`, `PQTY`, `SQTY`).",
    'SYSIBM.SYSPACKAGE'    => "**SYSIBM.SYSPACKAGE** (Db2 for z/OS Catalog)\n\nBound static SQL packages (`COLLID`, `NAME`, `VERSION`, `ISOLATION`, `RELEASE`, `CURRENTDATA`, `DEGREE`, `APREUSE`, `VALID`, `OPERATIVE`).",
    'SYSIBM.SYSPLAN'       => "**SYSIBM.SYSPLAN** (Db2 for z/OS Catalog)\n\nApplication plans (`NAME`, `CREATOR`, `ISOLATION`, `RELEASE`, `ACQUIRE`, `VALID`, `OPERATIVE`).",
    'SYSIBM.SYSPACKSTMT'   => "**SYSIBM.SYSPACKSTMT** (Db2 for z/OS Catalog)\n\nStatic SQL statement text captured per package (`COLLID`, `NAME`, `VERSION`, `STMTNO`, `SECTNO`, `STATEMENT`).",
    'PLAN_TABLE'           => "**PLAN_TABLE** (Db2 for z/OS EXPLAIN)\n\nAccess-path table populated by `EXPLAIN ALL` or `BIND ... EXPLAIN(YES)`. Key columns: `ACCESSTYPE`, `MATCHCOLS`, `INDEXONLY`, `PREFETCH`, `METHOD`, `SORTN_*`, `SORTC_*`.",
    'DSN_STATEMNT_TABLE'   => "**DSN_STATEMNT_TABLE** (Db2 for z/OS EXPLAIN)\n\nCost estimates (`PROCMS`, `PROCSU`, `TOTAL_COST`, `COST_CATEGORY` `'A'` vs `'B'`, `REASON`) paired with `PLAN_TABLE`.",
    'DCLGEN'               => "**DCLGEN** (Declarations Generator)\n\nGenerates COBOL/PL/I/C host-variable structures (`01 DCL...` with 49-level `VARCHAR` LEN/TEXT and `COMP`/`COMP-3` fields) plus `EXEC SQL DECLARE ... TABLE`.",
    'ACCESSTYPE'           => "**PLAN_TABLE.ACCESSTYPE**\n\n`I` = index scan, `I1` = one-fetch index scan, `N` = IN-list index scan, `MX/MI/MU` = multi-index RID access, `R` = tablespace scan, `H` = hash access.",
    'MATCHCOLS'            => "**PLAN_TABLE.MATCHCOLS**\n\nNumber of leading index key columns matched by indexable Stage 1 predicates (`0` with `ACCESSTYPE='I'` = full non-matching index scan).",
    'INDEXONLY'            => "**PLAN_TABLE.INDEXONLY**\n\n`'Y'` satisfies the query solely from index leaf pages without random data-page fetches.",
    'PREFETCH'             => "**PLAN_TABLE.PREFETCH**\n\n`'S'` = Sequential prefetch, `'L'` = List prefetch (RID sort), `'D'` = Dynamic prefetch, `''` = synchronous I/O.",
    'CURRENTDATA'          => "**BIND PACKAGE CURRENTDATA(NO | YES)**\n\n`CURRENTDATA(NO)` allows Db2 lock avoidance on read-only/ambiguous cursors and is strongly preferred over the legacy `YES` default.",
    'APREUSE'              => "**BIND/REBIND PACKAGE APREUSE(NONE | WARN | ERROR)**\n\nPreserves proven access paths across rebinds and Db2 upgrades (`WARN` or `ERROR` paired with `PLANMGMT(EXTENDED)`).",
    'PLANMGMT'             => "**REBIND PACKAGE PLANMGMT(OFF | BASIC | EXTENDED)**\n\nRetains original and previous package copies so `REBIND SWITCH(PREVIOUS)` can instantaneously roll back an access-path regression.",
    'RELEASE'              => "**BIND PACKAGE RELEASE(COMMIT | DEALLOCATE)**\n\n`COMMIT` releases locks/EDM resources at commit; `DEALLOCATE` reduces CPU on high-frequency static SQL but holds DBD/package locks across commits.",
    'DEGREE'               => "**BIND PACKAGE DEGREE(1 | ANY)**\n\n`ANY` enables z/OS query CP parallelism; `1` forces single-task execution.",
    'PBG'                  => "**UTS Partition-by-Growth (PBG)**\n\nUniversal Table Space (`TYPE='G'`, `MAXPARTITIONS n`, `SEGSIZE m`) that automatically adds partitions as data grows.",
    'PBR'                  => "**UTS Partition-by-Range (PBR)**\n\nUniversal Table Space (`TYPE='R'`, `NUMPARTS n`, `SEGSIZE m`, `PAGENUM RELATIVE` for RPN) partitioned by key range.",
);

my @COMPLETION_ITEMS = (
    { label => 'SYSIBM.SYSTABLES',       kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Tables, views, aliases, CARDF, NPAGESF.' },
    { label => 'SYSIBM.SYSCOLUMNS',      kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Columns, COLTYPE, LENGTH, SCALE, NULLS.' },
    { label => 'SYSIBM.SYSINDEXES',      kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Indexes, UNIQUERULE, CLUSTERING, NLEAF.' },
    { label => 'SYSIBM.SYSTABLESPACE',   kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Tablespace TYPE (G=PBG, R=PBR), PGSIZE, SEGSIZE.' },
    { label => 'SYSIBM.SYSTABLEPART',    kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Partition stats: NEARINDREF, FARINDREF, CARD.' },
    { label => 'SYSIBM.SYSPACKAGE',      kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Bound packages: ISOLATION, RELEASE, CURRENTDATA, APREUSE.' },
    { label => 'SYSIBM.SYSPLAN',         kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Application plans and bind options.' },
    { label => 'SYSIBM.SYSPACKSTMT',     kind => 7,  detail => 'Db2 z/OS catalog',     documentation => 'Static SQL statements inside bound packages.' },
    { label => 'ISOLATION(CS)',          kind => 14, detail => 'BIND option',          documentation => 'Cursor Stability isolation (recommended default).' },
    { label => 'CURRENTDATA(NO)',        kind => 14, detail => 'BIND option',          documentation => 'Enables Db2 lock avoidance for read-only cursors.' },
    { label => 'RELEASE(COMMIT)',        kind => 14, detail => 'BIND option',          documentation => 'Releases locks and resources at COMMIT.' },
    { label => 'RELEASE(DEALLOCATE)',    kind => 14, detail => 'BIND option',          documentation => 'Holds package allocation until thread deallocation.' },
    { label => 'APREUSE(WARN)',          kind => 14, detail => 'BIND/REBIND option',   documentation => 'Reuse previous access paths; warn if impossible.' },
    { label => 'PLANMGMT(EXTENDED)',     kind => 14, detail => 'REBIND option',        documentation => 'Retain ORIGINAL and PREVIOUS access-path copies.' },
    { label => 'DEGREE(ANY)',            kind => 14, detail => 'BIND option',          documentation => 'Allow z/OS CP query parallelism.' },
    { label => 'EXPLAIN(YES)',           kind => 14, detail => 'BIND option',          documentation => 'Populate PLAN_TABLE at bind time.' },
    { label => 'VALIDATE(BIND)',         kind => 14, detail => 'BIND option',          documentation => 'Validate objects and authority at bind time.' },
    { label => 'PAGENUM RELATIVE',       kind => 14, detail => 'UTS PBR clause',       documentation => 'Relative Page Numbering (up to 1 TB/partition).' },
    { label => 'FOR FETCH ONLY WITH UR', kind => 15, detail => 'z/OS query clause',    documentation => 'Read-only uncommitted read clause.' },
);

sub meta {
    return {
        name             => 'db2z',
        label            => 'Db2 for z/OS (SYSIBM, PLAN_TABLE & DCLGEN)',
        category         => 'database',
        version          => $VERSION,
        description      => 'Db2 for z/OS DRDA/ODBC query execution, SYSIBM catalog inspection, PLAN_TABLE & Stage 1/Stage 2 predicate analysis, COBOL DCLGEN generator, and BIND PACKAGE / UTS PBG-PBR validator.',
        filetypes        => [qw(sql db2z dcl ddl)],
        upstream_credits => ['IBM Db2 for z/OS tooling conventions'],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'db2z_query',
            description => 'Execute a read-only-guarded DRDA/ODBC SQL query against Db2 for z/OS via DBI/DBD::ODBC (or offline dry-run with Stage 1/2 hints).',
            inputSchema => {
                type       => 'object',
                properties => {
                    sql         => { type => 'string',  description => 'Db2 for z/OS SQL statement.' },
                    params      => { type => 'array',   description => 'Optional bind parameters.' },
                    allow_write => { type => 'boolean', description => 'Permit writes (default false).' },
                    max_rows    => { type => 'integer', description => 'Row fetch limit (default 200).' },
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
            name        => 'db2z_catalog_inspect',
            description => 'Build and optionally execute SYSIBM catalog queries (SYSTABLES, SYSCOLUMNS, SYSINDEXES, SYSTABLESPACE, SYSTABLEPART, SYSPACKAGE, SYSPLAN, SYSPACKSTMT).',
            inputSchema => {
                type       => 'object',
                properties => {
                    target  => { type => 'string',  description => 'tables|columns|indexes|tablespaces|tableparts|packages|plans|packstmt' },
                    creator => { type => 'string',  description => 'CREATOR / TBCREATOR / COLLID filter.' },
                    name    => { type => 'string',  description => 'Object, table, tablespace, or package name filter.' },
                    dbname  => { type => 'string',  description => 'Optional DBNAME filter for tables/tablespaces/tableparts.' },
                    limit   => { type => 'integer', description => 'Row limit (default 100).' },
                    execute => { type => 'boolean' },
                    dsn     => { type => 'string' },
                    user    => { type => 'string' },
                    pass    => { type => 'string' },
                },
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_catalog_inspect($args, $ctx) },
        },
        {
            name        => 'db2z_plan_table_analyze',
            description => 'Analyze Db2 for z/OS PLAN_TABLE & DSN_STATEMNT_TABLE rows (ACCESSTYPE, MATCHCOLS, INDEXONLY, PREFETCH, SORTN_*/SORTC_*, COST_CATEGORY) and audit SQL Stage 1 vs Stage 2 predicates.',
            inputSchema => {
                type       => 'object',
                properties => {
                    rows      => { type => 'array',  description => 'Array of PLAN_TABLE / DSN_STATEMNT_TABLE row hashrefs.' },
                    plan_text => { type => 'string', description => 'Optional delimited or key=value PLAN_TABLE text dump.' },
                    sql       => { type => 'string', description => 'Optional SQL statement for Stage 1 vs Stage 2 indexability audit.' },
                },
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_plan_table_analyze($args, $ctx) },
        },
        {
            name        => 'db2z_dclgen_generate',
            description => 'Parse SQL CREATE TABLE DDL and generate z/OS COBOL WORKING-STORAGE EXEC SQL DECLARE TABLE + 01 DCL<TABLE> host structure (PIC X/COMP/COMP-3/49-level VARCHAR + null indicators).',
            inputSchema => {
                type       => 'object',
                properties => {
                    ddl             => { type => 'string',  description => 'SQL CREATE TABLE DDL statement.' },
                    structure_name  => { type => 'string',  description => 'Optional 01-level structure name (default DCL<TABLE>).' },
                    col_prefix      => { type => 'string',  description => 'Optional prefix for COBOL field names.' },
                    indicator_array => { type => 'boolean', description => 'Generate null indicator structure & array (default true).' },
                },
                required => ['ddl'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_dclgen_generate($args, $ctx) },
        },
        {
            name        => 'db2z_bind_package_check',
            description => 'Validate z/OS BIND PACKAGE / BIND PLAN options (ISOLATION, RELEASE, CURRENTDATA, DEGREE, APREUSE, PLANMGMT, VALIDATE) and UTS PBG/PBR tablespace DDL rules.',
            inputSchema => {
                type       => 'object',
                properties => {
                    bind_text => { type => 'string', description => 'BIND PACKAGE / REBIND PACKAGE / CREATE TABLESPACE text.' },
                },
                required => ['bind_text'],
            },
            handler => sub { my ($args, $ctx) = @_; return $self->tool_bind_package_check($args, $ctx) },
        },
    ];
}

sub _clean_ident {
    my ($v, $def) = @_;
    $v = $def if !defined($v) || !length($v);
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/[^A-Za-z0-9_\$\@\#\%\-]//g;
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
        dialect     => 'db2z',
        env_prefix  => 'DB2Z',
        driver_hint => 'dbi:ODBC:DRIVER={IBM DB2 ODBC DRIVER};DATABASE=<location>;HOSTNAME=<host>;PORT=446;PROTOCOL=TCPIP',
    );
    my $audit = $self->_audit_stage1_stage2($sql);
    $res->{stage2_warnings} = $audit->{stage2_predicates} if @{ $audit->{stage2_predicates} || [] };
    return $res;
}

sub tool_catalog_inspect {
    my ($self, $args, $ctx) = @_;
    my $target  = lc($args->{target} // 'tables');
    my $creator = defined($args->{creator}) && length($args->{creator}) ? _clean_ident($args->{creator}, '') : '';
    my $name    = defined($args->{name})    && length($args->{name})    ? _clean_ident($args->{name},    '') : '';
    my $dbname  = defined($args->{dbname})  && length($args->{dbname})  ? _clean_ident($args->{dbname},  '') : '';
    my $limit   = int($args->{limit} || 100);
    $limit = 1    if $limit < 1;
    $limit = 1000 if $limit > 1000;

    my %views = (
        tables      => 'SYSIBM.SYSTABLES',
        columns     => 'SYSIBM.SYSCOLUMNS',
        indexes     => 'SYSIBM.SYSINDEXES',
        tablespaces => 'SYSIBM.SYSTABLESPACE',
        tableparts  => 'SYSIBM.SYSTABLEPART',
        packages    => 'SYSIBM.SYSPACKAGE',
        plans       => 'SYSIBM.SYSPLAN',
        packstmt    => 'SYSIBM.SYSPACKSTMT',
    );
    if (!exists $views{$target}) {
        return {
            ok      => 0,
            error   => "Unsupported Db2 for z/OS catalog target '$target'.",
            allowed => [ sort keys %views ],
        };
    }

    my (@where, @params, $sql, @notes);

    if ($target eq 'tables') {
        push @where, "CREATOR = ?"   if length $creator;
        push @params, $creator       if length $creator;
        push @where, "NAME LIKE ?"   if length $name;
        push @params, ($name =~ /%/ ? $name : "$name%") if length $name;
        push @where, "DBNAME = ?"    if length $dbname;
        push @params, $dbname        if length $dbname;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE CREATOR NOT LIKE 'SYS%'";
        $sql = "SELECT CREATOR, NAME, DBNAME, TSNAME, TYPE, COLCOUNT, CARDF, NPAGESF, STATSTIME "
             . "FROM SYSIBM.SYSTABLES$w "
             . "ORDER BY CREATOR, NAME FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, 'CARDF = -1 indicates RUNSTATS has never been run on the tablespace.';
    }
    elsif ($target eq 'columns') {
        push @where, "TBCREATOR = ?" if length $creator;
        push @params, $creator       if length $creator;
        push @where, "TBNAME = ?"    if length $name;
        push @params, $name          if length $name;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE TBCREATOR NOT LIKE 'SYS%'";
        $sql = "SELECT TBCREATOR, TBNAME, COLNO, NAME, COLTYPE, LENGTH, SCALE, NULLS, DEFAULT, COLCARDF, KEYSEQ "
             . "FROM SYSIBM.SYSCOLUMNS$w "
             . "ORDER BY TBCREATOR, TBNAME, COLNO FETCH FIRST $limit ROWS ONLY WITH UR";
    }
    elsif ($target eq 'indexes') {
        push @where, "TBCREATOR = ?" if length $creator;
        push @params, $creator       if length $creator;
        push @where, "TBNAME = ?"    if length $name;
        push @params, $name          if length $name;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE TBCREATOR NOT LIKE 'SYS%'";
        $sql = "SELECT CREATOR, NAME, TBCREATOR, TBNAME, UNIQUERULE, CLUSTERING, CLUSTERED, "
             . "NLEAF, NLEVELS, FULLKEYCARDF, PADDED, INDEXTYPE "
             . "FROM SYSIBM.SYSINDEXES$w "
             . "ORDER BY TBCREATOR, TBNAME, NAME FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, 'NLEVELS > 4 or CLUSTERED = N on a CLUSTERING = Y index signals REORG need.';
    }
    elsif ($target eq 'tablespaces') {
        push @where, "DBNAME = ?"    if length $dbname;
        push @params, $dbname        if length $dbname;
        push @where, "NAME LIKE ?"   if length $name;
        push @params, ($name =~ /%/ ? $name : "$name%") if length $name;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE DBNAME NOT LIKE 'DSNDB%'";
        $sql = "SELECT DBNAME, NAME, TYPE, PARTITIONS, MAXPARTITIONS, PGSIZE, SEGSIZE, "
             . "DSSIZE, BPOOL, LOCKRULE, LOCKMAX "
             . "FROM SYSIBM.SYSTABLESPACE$w "
             . "ORDER BY DBNAME, NAME FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, "TYPE = 'G' (UTS PBG) or 'R' (UTS PBR) are current UTS formats; blank/'L' non-UTS types are deprecated.";
    }
    elsif ($target eq 'tableparts') {
        push @where, "DBNAME = ?"  if length $dbname;
        push @params, $dbname      if length $dbname;
        push @where, "TSNAME = ?"  if length $name;
        push @params, $name        if length $name;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : " WHERE DBNAME NOT LIKE 'DSNDB%'";
        $sql = "SELECT DBNAME, TSNAME, PARTITION, CARD, NEARINDREF, FARINDREF, "
             . "PERCACTIVE, PCTFREE, FREEPAGE, PQTY, SQTY, SPACEF "
             . "FROM SYSIBM.SYSTABLEPART$w "
             . "ORDER BY DBNAME, TSNAME, PARTITION FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, 'High FARINDREF (>5-10% of CARD) indicates row overflow chains and recommends online REORG TABLESPACE.';
    }
    elsif ($target eq 'packages') {
        push @where, "COLLID = ?"   if length $creator;
        push @params, $creator      if length $creator;
        push @where, "NAME LIKE ?"  if length $name;
        push @params, ($name =~ /%/ ? $name : "$name%") if length $name;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT LOCATION, COLLID, NAME, VERSION, ISOLATION, RELEASE, CURRENTDATA, "
             . "DEGREE, APREUSE, VALID, OPERATIVE, BINDTIME, LASTUSED "
             . "FROM SYSIBM.SYSPACKAGE$w "
             . "ORDER BY COLLID, NAME, BINDTIME DESC FETCH FIRST $limit ROWS ONLY WITH UR";
        push @notes, 'Check CURRENTDATA = N for lock avoidance and VALID = Y / OPERATIVE = Y.';
    }
    elsif ($target eq 'plans') {
        push @where, "CREATOR = ?" if length $creator;
        push @params, $creator     if length $creator;
        push @where, "NAME LIKE ?" if length $name;
        push @params, ($name =~ /%/ ? $name : "$name%") if length $name;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT NAME, CREATOR, ISOLATION, RELEASE, ACQUIRE, VALID, OPERATIVE, BINDTIME "
             . "FROM SYSIBM.SYSPLAN$w "
             . "ORDER BY NAME FETCH FIRST $limit ROWS ONLY WITH UR";
    }
    elsif ($target eq 'packstmt') {
        push @where, "COLLID = ?" if length $creator;
        push @params, $creator    if length $creator;
        push @where, "NAME = ?"   if length $name;
        push @params, $name       if length $name;
        my $w = @where ? (' WHERE ' . join(' AND ', @where)) : '';
        $sql = "SELECT COLLID, NAME, VERSION, STMTNO, SECTNO, SEQNO, STATEMENT "
             . "FROM SYSIBM.SYSPACKSTMT$w "
             . "ORDER BY COLLID, NAME, STMTNO, SEQNO FETCH FIRST $limit ROWS ONLY WITH UR";
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
        dialect    => 'db2z',
        env_prefix => 'DB2Z',
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

sub _parse_plan_text {
    my ($self, $text) = @_;
    return [] unless defined $text && $text =~ /\S/;
    my @rows;
    my @lines = grep { /\S/ } split /\n/, $text;
    return [] unless @lines;

    # Format 1: key=value lines (e.g. "QBLOCKNO=1 PLANNO=1 TNAME=ORDERS ACCESSTYPE=R MATCHCOLS=0 ...")
    if ($lines[0] =~ /[A-Za-z_]+\s*=/) {
        for my $ln (@lines) {
            my %r;
            while ($ln =~ /\b([A-Za-z0-9_]+)\s*=\s*([^\s,;]+)/g) {
                $r{ uc($1) } = $2;
            }
            push @rows, \%r if %r;
        }
        return \@rows;
    }

    # Format 2: header + pipe/comma/whitespace rows
    my $hdr = shift @lines;
    my $sep = ($hdr =~ /\|/) ? qr/\s*\|\s*/ : ($hdr =~ /,/) ? qr/\s*,\s*/ : qr/\s+/;
    $hdr =~ s/^\s*\|\s*|\s*\|\s*$//g if $hdr =~ /\|/;
    my @cols = map { uc($_) } grep { length } split $sep, $hdr;
    return [] unless @cols;

    for my $ln (@lines) {
        next if $ln =~ /^[\s\-\+\|=]+$/;
        $ln =~ s/^\s*\|\s*|\s*\|\s*$//g if $ln =~ /\|/;
        my @vals = split $sep, $ln;
        my %r;
        for my $i (0 .. $#cols) {
            my $v = $vals[$i];
            $v = '' unless defined $v;
            $v =~ s/^\s+|\s+$//g;
            $v = '' if $v eq '-' || uc($v) eq 'NULL';
            $r{ $cols[$i] } = $v;
        }
        push @rows, \%r if %r;
    }
    return \@rows;
}

sub _audit_stage1_stage2 {
    my ($self, $sql) = @_;
    return { stage1_predicates => [], stage2_predicates => [] }
        unless defined $sql && $sql =~ /\S/;

    my $clean = $self->strip_sql_comments_and_literals($sql);
    my @stage1;
    my @stage2;

    my ($where_part) = ($clean =~ /\bWHERE\b(.*?)(?:\bGROUP\s+BY\b|\bORDER\s+BY\b|\bFETCH\s+FIRST\b|\bOPTIMIZE\s+FOR\b|\bFOR\s+(?:FETCH|READ|UPDATE)\b|\bWITH\s+(?:UR|CS|RS|RR)\b|$)/is);
    $where_part //= '';

    if (length $where_part) {
        # Stage 2 traps: scalar functions wrapped around columns
        while ($where_part =~ /\b((?:UPPER|LOWER|SUBSTR|SUBSTRING|TRIM|LTRIM|RTRIM|CHAR|VARCHAR|DIGITS|DECIMAL|INTEGER|DATE|TIME|YEAR|MONTH|DAY|COALESCE|VALUE|ABS)\s*\([^)]*\))/ig) {
            push @stage2, {
                predicate => $1,
                stage     => 2,
                indexable => 0,
                reason    => 'Scalar function applied to column in WHERE is Stage 2 (non-indexable) unless matched by an Index on Expression (IOE).',
            };
        }

        # Arithmetic on column: col + 1 = ... or col * 2 > ...
        while ($where_part =~ /\b([A-Za-z_][A-Za-z0-9_\.]*\s*[\+\-\*\/]\s*[A-Za-z0-9_\.:?]+\s*(?:=|<>|!=|<|>|<=|>=))/ig) {
            push @stage2, {
                predicate => $1,
                stage     => 2,
                indexable => 0,
                reason    => 'Arithmetic expression on a column is Stage 2 (non-indexable); move arithmetic to the constant/host-variable side.',
            };
        }

        # Leading wildcard LIKE '%...'
        if ($sql =~ /\b([A-Za-z_][A-Za-z0-9_\.]*\s+LIKE\s+'%[^']*')/i) {
            push @stage2, {
                predicate => $1,
                stage     => 1,
                indexable => 0,
                reason    => 'LIKE with leading wildcard (%) is Stage 1 non-indexable (cannot use MATCHCOLS > 0).',
            };
        }

        # OR across distinct columns
        if ($where_part =~ /\b([A-Za-z_][A-Za-z0-9_\.]*)\s*=\s*[^\s]+\s+OR\s+([A-Za-z_][A-Za-z0-9_\.]*)\s*=/i && uc($1) ne uc($2)) {
            push @stage2, {
                predicate => "$1 = ... OR $2 = ...",
                stage     => 2,
                indexable => 0,
                reason    => "OR across different columns ($1 vs $2) prevents single-index matching and risks tablespace scan or RID-pool multi-index union.",
            };
        }

        # NOT IN (SELECT ...)
        if ($where_part =~ /\bNOT\s+IN\s*\(\s*SELECT\b/i) {
            push @stage2, {
                predicate => 'NOT IN (SELECT ...)',
                stage     => 2,
                indexable => 0,
                reason    => 'NOT IN subquery is Stage 2 non-indexable and NULL-sensitive; rewrite using NOT EXISTS.',
            };
        }

        # Stage 1 indexable patterns
        while ($where_part =~ /\b([A-Za-z_][A-Za-z0-9_\.]*\s*(?:=|BETWEEN|IN|<=|>=|<|>)\s*(?::[A-Za-z0-9_\-]+|\?|\d+|''))/ig) {
            push @stage1, {
                predicate => $1,
                stage     => 1,
                indexable => 1,
            };
        }
    }

    return {
        stage1_predicates => \@stage1,
        stage2_predicates => \@stage2,
    };
}

sub tool_plan_table_analyze {
    my ($self, $args, $ctx) = @_;
    my @rows;
    if (ref($args->{rows}) eq 'ARRAY') {
        for my $r (@{ $args->{rows} }) {
            next unless ref($r) eq 'HASH';
            my %norm = map { uc($_) => ($r->{$_} // '') } keys %$r;
            push @rows, \%norm;
        }
    }
    if (defined $args->{plan_text} && $args->{plan_text} =~ /\S/) {
        push @rows, @{ $self->_parse_plan_text($args->{plan_text}) };
    }

    my %access_desc = (
        'I'  => 'Index scan (check MATCHCOLS)',
        'I1' => 'One-fetch index scan (MIN/MAX optimal)',
        'N'  => 'IN-list index scan',
        'R'  => 'Tablespace scan (full scan)',
        'MX' => 'Multiple index scan (RID list)',
        'MI' => 'Multiple index intersection',
        'MU' => 'Multiple index union',
        'H'  => 'Direct hash access',
        'HN' => 'IN-list hash access',
        'MH' => 'Multiple hash access',
        ''   => 'No table access (virtual/sort step)',
    );
    my %method_desc = (
        '0' => 'First table accessed',
        '1' => 'Nested Loop Join',
        '2' => 'Merge Scan Join',
        '3' => 'Additional Sort',
        '4' => 'Hybrid Join (RID list prefetch)',
    );
    my %prefetch_desc = (
        'S' => 'Sequential prefetch',
        'L' => 'List prefetch (RID sort)',
        'D' => 'Dynamic prefetch',
        ''  => 'None (synchronous I/O)',
    );

    my @findings;
    my @recommendations;
    my @steps;

    for my $r (@rows) {
        my $qb    = $r->{QBLOCKNO}   // 1;
        my $pn    = $r->{PLANNO}     // 1;
        my $tname = $r->{TNAME}      // '';
        my $at    = uc($r->{ACCESSTYPE} // '');
        my $mc    = ($r->{MATCHCOLS} // '') =~ /^\d+$/ ? int($r->{MATCHCOLS}) : 0;
        my $ix    = $r->{ACCESSNAME} // '';
        my $ixo   = uc($r->{INDEXONLY} // 'N');
        my $pf    = uc($r->{PREFETCH}  // '');
        my $meth  = "$r->{METHOD}" if defined $r->{METHOD};
        $meth //= '0';

        my @sorts;
        for my $sk (qw(SORTN_UNIQ SORTN_JOIN SORTN_ORDERBY SORTN_GROUPBY SORTC_UNIQ SORTC_JOIN SORTC_ORDERBY SORTC_GROUPBY)) {
            push @sorts, $sk if uc($r->{$sk} // '') eq 'Y';
        }

        push @steps, {
            qblockno        => $qb,
            planno          => $pn,
            table           => $tname,
            method          => $meth,
            method_desc     => $method_desc{$meth} // "Method $meth",
            accesstype      => $at,
            accesstype_desc => $access_desc{$at} // "Access $at",
            matchcols       => $mc,
            index_name      => $ix,
            indexonly       => $ixo,
            prefetch        => $pf,
            prefetch_desc   => $prefetch_desc{$pf} // $pf,
            sorts           => \@sorts,
            (length($r->{PROCMS} // '')        ? (procms        => $r->{PROCMS} + 0)        : ()),
            (length($r->{PROCSU} // '')        ? (procsu        => $r->{PROCSU} + 0)        : ()),
            (length($r->{COST_CATEGORY} // '') ? (cost_category => uc($r->{COST_CATEGORY})) : ()),
        };

        if ($at eq 'R') {
            push @findings, {
                severity => 'error',
                qblockno => $qb,
                planno   => $pn,
                table    => $tname,
                code     => 'DB2Z_TSCAN',
                message  => "ACCESSTYPE='R' (Tablespace Scan) on $tname (QBLOCKNO=$qb, PLANNO=$pn). Reads every active page; check missing index or Stage 2 predicates.",
            };
            push @recommendations, "Add/align a matching index on $tname for Stage 1 WHERE/JOIN predicates and ensure RUNSTATS is current.";
        }
        elsif ($at eq 'I' && $mc == 0) {
            push @findings, {
                severity => 'warn',
                qblockno => $qb,
                planno   => $pn,
                table    => $tname,
                code     => 'DB2Z_NONMATCH_IX',
                message  => "ACCESSTYPE='I' with MATCHCOLS=0 (Non-Matching Full Index Scan) on index $ix for $tname; leading index key column is not supplied in WHERE.",
            };
        }
        elsif ($at eq 'I' && $ixo eq 'Y') {
            push @findings, {
                severity => 'info',
                qblockno => $qb,
                planno   => $pn,
                table    => $tname,
                code     => 'DB2Z_IXONLY',
                message  => "Optimal Index-Only scan (ACCESSTYPE='I', MATCHCOLS=$mc, INDEXONLY='Y') on $ix for $tname.",
            };
        }

        if ($at =~ /^M[XIU]$/ || $pf eq 'L') {
            push @findings, {
                severity => 'warn',
                qblockno => $qb,
                planno   => $pn,
                table    => $tname,
                code     => 'DB2Z_RID_PREFETCH',
                message  => "List prefetch / multi-index RID processing (ACCESSTYPE='$at', PREFETCH='$pf') on $tname; monitor RID pool limits (MAXRBLK) to avoid silent fallback to tablespace scan.",
            };
        }

        if (@sorts) {
            push @findings, {
                severity => 'warn',
                qblockno => $qb,
                planno   => $pn,
                table    => $tname,
                code     => 'DB2Z_SORT',
                message  => "Sort required on $tname (" . join(', ', @sorts) . "); consumes DSNDB07 workfiles and CPU. Check index ordering for ORDER BY / GROUP BY / JOIN.",
            };
        }

        if (uc($r->{COST_CATEGORY} // '') eq 'B') {
            push @findings, {
                severity => 'warn',
                qblockno => $qb,
                planno   => $pn,
                table    => $tname,
                code     => 'DB2Z_COST_CAT_B',
                message  => "DSN_STATEMNT_TABLE COST_CATEGORY='B' detected (default filter factors used due to missing RUNSTATS or host variables/parameter markers). Run RUNSTATS or consider REOPT(ONCE|AUTO).",
            };
        }
    }

    my $pred_audit = $self->_audit_stage1_stage2($args->{sql});
    for my $s2 (@{ $pred_audit->{stage2_predicates} }) {
        push @findings, {
            severity => 'warn',
            code     => 'DB2Z_STAGE2',
            message  => "Stage 2 / non-indexable predicate '$s2->{predicate}': $s2->{reason}",
        };
    }

    return {
        ok                => 1,
        step_count        => scalar(@steps),
        steps             => \@steps,
        findings          => \@findings,
        stage1_predicates => $pred_audit->{stage1_predicates},
        stage2_predicates => $pred_audit->{stage2_predicates},
        recommendations   => \@recommendations,
    };
}

sub _split_top_level_commas {
    my ($str) = @_;
    my @parts;
    my $depth = 0;
    my $in_sq = 0;
    my $cur   = '';
    my $len   = length($str);
    for (my $i = 0; $i < $len; $i++) {
        my $ch = substr($str, $i, 1);
        if ($ch eq "'") {
            $in_sq = !$in_sq;
            $cur .= $ch;
        }
        elsif (!$in_sq && $ch eq '(') {
            $depth++;
            $cur .= $ch;
        }
        elsif (!$in_sq && $ch eq ')') {
            $depth-- if $depth > 0;
            $cur .= $ch;
        }
        elsif (!$in_sq && $depth == 0 && $ch eq ',') {
            push @parts, $cur;
            $cur = '';
        }
        else {
            $cur .= $ch;
        }
    }
    push @parts, $cur if $cur =~ /\S/;
    return @parts;
}

sub _cobol_name {
    my ($name, $prefix, $suffix) = @_;
    my $c = uc($name // '');
    $c =~ s/[^A-Za-z0-9_\-]//g;
    $c =~ s/_/-/g;
    $prefix = uc($prefix // '');
    $prefix =~ s/_/-/g;
    $suffix = uc($suffix // '');
    $suffix =~ s/_/-/g;
    $c = $prefix . $c if length $prefix;
    my $max_base = 30 - length($suffix);
    $max_base = 1 if $max_base < 1;
    $c = substr($c, 0, $max_base) if length($c) > $max_base;
    $c =~ s/-+$// if length($suffix);
    return $c . $suffix;
}

sub tool_dclgen_generate {
    my ($self, $args, $ctx) = @_;
    my $ddl = $args->{ddl} // '';
    if ($ddl !~ /\S/) {
        return { ok => 0, error => 'ddl parameter is required.' };
    }

    # Strip SQL comments
    my $clean = $ddl;
    $clean =~ s/--[^\n]*//g;
    $clean =~ s{/\*.*?\*/}{}gs;

    if ($clean !~ /CREATE\s+(?:GLOBAL\s+TEMPORARY\s+)?TABLE\s+(?:([A-Za-z0-9_\$\@\#]+)\.)?([A-Za-z0-9_\$\@\#]+)\s*\((.*)\)/is) {
        return {
            ok    => 0,
            error => 'Could not parse CREATE TABLE [schema.]table ( ... ) DDL.',
        };
    }

    my $schema = defined($1) && length($1) ? uc($1) : 'DSN8';
    my $table  = uc($2);
    my $body   = $3;

    # Trim trailing clauses outside the matching closing parenthesis
    my $depth = 1;
    my $body_end = length($body);
    for (my $i = 0; $i < length($body); $i++) {
        my $ch = substr($body, $i, 1);
        if ($ch eq '(') { $depth++ }
        elsif ($ch eq ')') {
            $depth--;
            if ($depth == 0) {
                $body_end = $i;
                last;
            }
        }
    }
    $body = substr($body, 0, $body_end);

    my $struct_name = defined($args->{structure_name}) && length($args->{structure_name})
        ? _cobol_name($args->{structure_name}, '')
        : _cobol_name("DCL$table", '');
    my $col_prefix  = $args->{col_prefix} // '';
    my $emit_ind    = exists($args->{indicator_array}) ? ($args->{indicator_array} ? 1 : 0) : 1;

    my @items = _split_top_level_commas($body);
    my @cols;
    my @declare_lines;
    my @struct_lines;
    my @ind_lines;
    my $total_bytes = 0;
    my $nullable_count = 0;

    push @declare_lines, "           EXEC SQL DECLARE $schema.$table TABLE";
    push @declare_lines, "           (";

    push @struct_lines, "       01  $struct_name.";

    for my $raw (@items) {
        $raw =~ s/^\s+|\s+$//g;
        next unless length $raw;
        # Skip table-level constraints
        next if $raw =~ /^(?:PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK|CONSTRAINT|PERIOD|AUDIT)\b/i;

        if ($raw !~ /^"?([A-Za-z_][A-Za-z0-9_\$\@\#]*)"?\s+([A-Za-z]+(?:\s+(?:VARYING|PRECISION|WITHOUT\s+TIME\s+ZONE|WITH\s+TIME\s+ZONE|LARGE\s+OBJECT))?)(?:\s*\(\s*(\d+)(?:\s*,\s*(\d+))?\s*\))?(.*)$/i) {
            next;
        }
        my ($cname, $raw_type, $p1, $p2, $rest) = (uc($1), uc($2), $3, $4, $5 // '');
        $raw_type =~ s/\s+/ /g;
        my $not_null = ($rest =~ /\bNOT\s+NULL\b/i || $rest =~ /\bPRIMARY\s+KEY\b/i) ? 1 : 0;
        my $nullable = $not_null ? 0 : 1;
        $nullable_count++ if $nullable;

        my $cob_name = _cobol_name($cname, $col_prefix);
        my ($sql_decl_type, $pic_desc, $bytes, $is_varchar49);
        $is_varchar49 = 0;

        if ($raw_type eq 'CHAR' || $raw_type eq 'CHARACTER') {
            my $n = int($p1 || 1);
            $sql_decl_type = "CHAR($n)";
            $pic_desc      = "PIC X($n)";
            $bytes         = $n;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'VARCHAR' || $raw_type eq 'CHARACTER VARYING' || $raw_type eq 'LONG VARCHAR') {
            my $n = int($p1 || 255);
            $sql_decl_type = "VARCHAR($n)";
            $pic_desc      = "49 LEN PIC S9(4) COMP / 49 TEXT PIC X($n)";
            $bytes         = 2 + $n;
            $is_varchar49  = 1;
            my $len_name   = _cobol_name($cob_name, '', '-LEN');
            my $txt_name   = _cobol_name($cob_name, '', '-TEXT');
            push @struct_lines, "           10 $cob_name.";
            push @struct_lines, sprintf('              49 %-25s PIC S9(4) USAGE COMP.', $len_name);
            push @struct_lines, sprintf('              49 %-25s PIC X(%d).', $txt_name, $n);
        }
        elsif ($raw_type eq 'SMALLINT') {
            $sql_decl_type = 'SMALLINT';
            $pic_desc      = 'PIC S9(4) USAGE COMP';
            $bytes         = 2;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'INTEGER' || $raw_type eq 'INT') {
            $sql_decl_type = 'INTEGER';
            $pic_desc      = 'PIC S9(9) USAGE COMP';
            $bytes         = 4;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'BIGINT') {
            $sql_decl_type = 'BIGINT';
            $pic_desc      = 'PIC S9(18) USAGE COMP';
            $bytes         = 8;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'DECIMAL' || $raw_type eq 'DEC' || $raw_type eq 'NUMERIC') {
            my $p = int($p1 || 5);
            my $s = defined($p2) ? int($p2) : 0;
            $sql_decl_type = "DECIMAL($p, $s)";
            my $int_digits = $p - $s;
            if ($s == 0) {
                $pic_desc = "PIC S9($p)V USAGE COMP-3";
            }
            elsif ($int_digits <= 0) {
                $pic_desc = "PIC SV9($s) USAGE COMP-3";
            }
            else {
                $pic_desc = "PIC S9($int_digits)V9($s) USAGE COMP-3";
            }
            $bytes = int($p / 2) + 1;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'REAL' || ($raw_type eq 'FLOAT' && defined($p1) && int($p1) <= 21)) {
            $sql_decl_type = 'REAL';
            $pic_desc      = 'USAGE COMP-1';
            $bytes         = 4;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'DOUBLE' || $raw_type eq 'DOUBLE PRECISION' || $raw_type eq 'FLOAT') {
            $sql_decl_type = 'DOUBLE PRECISION';
            $pic_desc      = 'USAGE COMP-2';
            $bytes         = 8;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'DATE') {
            $sql_decl_type = 'DATE';
            $pic_desc      = 'PIC X(10)';
            $bytes         = 10;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'TIME') {
            $sql_decl_type = 'TIME';
            $pic_desc      = 'PIC X(8)';
            $bytes         = 8;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type =~ /^TIMESTAMP/) {
            my $frac = defined($p1) ? int($p1) : 6;
            my $len  = ($frac == 0) ? 19 : (20 + $frac);
            $sql_decl_type = defined($p1) ? "TIMESTAMP($frac)" : 'TIMESTAMP';
            $pic_desc      = "PIC X($len)";
            $bytes         = $len;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'GRAPHIC') {
            my $n = int($p1 || 1);
            $sql_decl_type = "GRAPHIC($n)";
            $pic_desc      = "PIC G($n) USAGE DISPLAY-1";
            $bytes         = 2 * $n;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }
        elsif ($raw_type eq 'VARGRAPHIC') {
            my $n = int($p1 || 128);
            $sql_decl_type = "VARGRAPHIC($n)";
            $pic_desc      = "49 LEN PIC S9(4) COMP / 49 TEXT PIC G($n) DISPLAY-1";
            $bytes         = 2 + (2 * $n);
            $is_varchar49  = 1;
            push @struct_lines, "           10 $cob_name.";
            push @struct_lines, sprintf('              49 %-25s PIC S9(4) USAGE COMP.', _cobol_name($cob_name, '', '-LEN'));
            push @struct_lines, sprintf('              49 %-25s PIC G(%d) USAGE DISPLAY-1.', _cobol_name($cob_name, '', '-TEXT'), $n);
        }
        elsif ($raw_type eq 'CLOB' || $raw_type eq 'BLOB' || $raw_type eq 'BINARY' || $raw_type eq 'VARBINARY') {
            my $n = int($p1 || 1024);
            $sql_decl_type = "$raw_type($n)";
            if ($raw_type eq 'CLOB' || $raw_type eq 'BLOB') {
                $pic_desc = "USAGE SQL TYPE IS $raw_type($n)";
                $bytes    = 4 + $n;
                push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
            }
            elsif ($raw_type eq 'VARBINARY') {
                $pic_desc     = "49 LEN PIC S9(4) COMP / 49 TEXT PIC X($n)";
                $bytes        = 2 + $n;
                $is_varchar49 = 1;
                push @struct_lines, "           10 $cob_name.";
                push @struct_lines, sprintf('              49 %-25s PIC S9(4) USAGE COMP.', _cobol_name($cob_name, '', '-LEN'));
                push @struct_lines, sprintf('              49 %-25s PIC X(%d).', _cobol_name($cob_name, '', '-TEXT'), $n);
            }
            else {
                $pic_desc = "PIC X($n)";
                $bytes    = $n;
                push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
            }
        }
        else {
            my $n = int($p1 || 32);
            $sql_decl_type = $raw_type . (defined $p1 ? "($p1)" : '');
            $pic_desc      = "PIC X($n)";
            $bytes         = $n;
            push @struct_lines, sprintf('           10 %-28s %s.', $cob_name, $pic_desc);
        }

        $total_bytes += $bytes;

        push @cols, {
            sql_name      => $cname,
            cobol_name    => $cob_name,
            sql_type      => $sql_decl_type,
            cobol_pic     => $pic_desc,
            nullable      => $nullable,
            byte_length   => $bytes,
            is_varchar_49 => $is_varchar49,
        };
    }

    if (!@cols) {
        return { ok => 0, error => 'No columns parsed from CREATE TABLE DDL.' };
    }

    for my $i (0 .. $#cols) {
        my $c = $cols[$i];
        my $comma = ($i < $#cols) ? ',' : '';
        my $nn    = $c->{nullable} ? '' : ' NOT NULL';
        push @declare_lines, sprintf('             %-28s %s%s%s', $c->{sql_name}, $c->{sql_type}, $nn, $comma);
    }
    push @declare_lines, "           ) END-EXEC.";

    if ($emit_ind) {
        my $ind_struct = _cobol_name($struct_name, '', '-IND');
        my $ind_arr    = _cobol_name($struct_name, '', '-IND-TBL');
        push @ind_lines, "       01  $ind_struct.";
        for my $c (@cols) {
            my $in = _cobol_name($c->{cobol_name}, '', '-IND');
            push @ind_lines, sprintf('           10 %-28s PIC S9(4) USAGE COMP.', $in);
        }
        push @ind_lines, "       01  $ind_arr.";
        push @ind_lines, sprintf('           10 %-28s PIC S9(4) USAGE COMP', _cobol_name($table, '', '-IND'));
        push @ind_lines, sprintf('                                        OCCURS %d TIMES.', scalar(@cols));
    }

    my @banner = (
        "      ******************************************************************",
        "      * DCLGEN TABLE($schema.$table)",
        "      *        STRUCTURE($struct_name)  LANGUAGE(COBOL)",
        "      *        COLUMNS(" . scalar(@cols) . ")  HOST BYTES($total_bytes)",
        "      ******************************************************************",
    );

    my $cobol_copybook = join("\n", @banner, @declare_lines, '', @struct_lines, (@ind_lines ? ('', @ind_lines) : ())) . "\n";

    return {
        ok             => 1,
        schema         => $schema,
        table          => $table,
        structure_name => $struct_name,
        column_count   => scalar(@cols),
        nullable_count => $nullable_count,
        total_bytes    => $total_bytes,
        columns        => \@cols,
        cobol_copybook => $cobol_copybook,
    };
}

sub tool_bind_package_check {
    my ($self, $args, $ctx) = @_;
    my $text = $args->{bind_text} // '';
    my @lines = split /\n/, $text, -1;
    my @issues;
    my %options;

    my $find_line = sub {
        my ($re) = @_;
        for my $i (0 .. $#lines) {
            return $i if $lines[$i] =~ $re;
        }
        return 0;
    };

    # Parse BIND PACKAGE / REBIND PACKAGE / BIND PLAN options
    while ($text =~ /\b(ISOLATION|RELEASE|CURRENTDATA|DEGREE|APREUSE|PLANMGMT|VALIDATE|DYNAMICRULES|EXPLAIN|REOPT|ACTION|KEEPDYNAMIC|OWNER|QUALIFIER)\s*\(\s*([A-Za-z0-9_\*]+)\s*\)/ig) {
        $options{ uc($1) } = uc($2);
    }

    my $has_bind = ($text =~ /\b(?:RE)?BIND\s+(?:PACKAGE|PLAN)\b/i) ? 1 : 0;

    if ($has_bind) {
        if (!exists $options{CURRENTDATA}) {
            push @issues, {
                code     => 'DB2Z_BIND001',
                severity => 'warn',
                line     => $find_line->(qr/\b(?:RE)?BIND\b/i),
                message  => 'CURRENTDATA omitted (defaults to YES on z/OS). Specify CURRENTDATA(NO) to enable Db2 lock avoidance and prevent unnecessary row locks.',
            };
        }
        elsif ($options{CURRENTDATA} eq 'YES') {
            push @issues, {
                code     => 'DB2Z_BIND002',
                severity => 'warn',
                line     => $find_line->(qr/\bCURRENTDATA\b/i),
                message  => 'CURRENTDATA(YES) disables lock avoidance for ambiguous/read-only cursors; prefer CURRENTDATA(NO) unless strict cursor currency is required.',
            };
        }

        if (exists $options{ISOLATION} && $options{ISOLATION} eq 'RR') {
            push @issues, {
                code     => 'DB2Z_BIND003',
                severity => 'warn',
                line     => $find_line->(qr/\bISOLATION\b/i),
                message  => 'ISOLATION(RR) holds range/page locks until commit and risks -911 deadlock/timeout; prefer ISOLATION(CS).',
            };
        }

        if (exists $options{RELEASE} && $options{RELEASE} eq 'DEALLOCATE') {
            push @issues, {
                code     => 'DB2Z_BIND004',
                severity => 'info',
                line     => $find_line->(qr/\bRELEASE\b/i),
                message  => 'RELEASE(DEALLOCATE) saves CPU for high-volume static SQL but retains DBD/package locks across commits (ensure PKGREL_COMMIT=YES for online DDL/REORG compatibility).',
            };
        }

        if (exists $options{VALIDATE} && $options{VALIDATE} eq 'RUN') {
            push @issues, {
                code     => 'DB2Z_BIND005',
                severity => 'warn',
                line     => $find_line->(qr/\bVALIDATE\b/i),
                message  => 'VALIDATE(RUN) defers catalog and authorization checks to execution time; use VALIDATE(BIND) in production.',
            };
        }

        if (!exists $options{APREUSE}) {
            push @issues, {
                code     => 'DB2Z_BIND006',
                severity => 'info',
                line     => $find_line->(qr/\b(?:RE)?BIND\b/i),
                message  => 'Consider APREUSE(WARN) or APREUSE(ERROR) paired with PLANMGMT(EXTENDED) during REBIND/migrations to guard against access-path regressions.',
            };
        }

        if (!exists $options{EXPLAIN} || $options{EXPLAIN} eq 'NO') {
            push @issues, {
                code     => 'DB2Z_BIND007',
                severity => 'hint',
                line     => $find_line->(qr/\b(?:RE)?BIND\b/i),
                message  => 'Specify EXPLAIN(YES) so PLAN_TABLE and DSN_STATEMNT_TABLE capture static SQL access paths at bind time.',
            };
        }

        if (exists $options{DEGREE} && $options{DEGREE} eq 'ANY') {
            push @issues, {
                code     => 'DB2Z_BIND008',
                severity => 'info',
                line     => $find_line->(qr/\bDEGREE\b/i),
                message  => 'DEGREE(ANY) enables z/OS CP parallelism; good for analytical batch, but monitor WLM enclave CPU on high-concurrency CICS OLTP.',
            };
        }
    }

    # UTS PBG / PBR CREATE TABLESPACE audit
    my $ts_type = 'NONE';
    if ($text =~ /\bCREATE\s+TABLESPACE\b/i) {
        my $has_maxparts = ($text =~ /\bMAXPARTITIONS\s+(\d+)/i) ? int($1) : 0;
        my $has_numparts = ($text =~ /\bNUMPARTS\s+(\d+)/i)      ? int($1) : 0;
        my $has_segsize  = ($text =~ /\bSEGSIZE\s+(\d+)/i)       ? int($1) : 0;
        my $has_rpn      = ($text =~ /\bPAGENUM\s+RELATIVE\b/i)  ? 1 : 0;

        if ($has_maxparts && $has_numparts) {
            $ts_type = 'INVALID';
            push @issues, {
                code     => 'DB2Z_UTS001',
                severity => 'error',
                line     => $find_line->(qr/\bCREATE\s+TABLESPACE\b/i),
                message  => 'Cannot combine MAXPARTITIONS (UTS PBG) and NUMPARTS (UTS PBR) in the same CREATE TABLESPACE.',
            };
        }
        elsif ($has_maxparts) {
            $ts_type = 'UTS_PBG';
        }
        elsif ($has_numparts) {
            $ts_type = $has_rpn ? 'UTS_PBR_RPN' : 'UTS_PBR_ABSOLUTE';
            if (!$has_rpn) {
                push @issues, {
                    code     => 'DB2Z_UTS002',
                    severity => 'hint',
                    line     => $find_line->(qr/\bNUMPARTS\b/i),
                    message  => 'UTS PBR without PAGENUM RELATIVE uses legacy absolute page numbering; PAGENUM RELATIVE (Db2 12+) allows per-partition DSSIZE up to 1 TB and immediate ALTER DSSIZE.',
                };
            }
        }
        else {
            $ts_type = 'NON_UTS_DEPRECATED';
            push @issues, {
                code     => 'DB2Z_UTS003',
                severity => 'error',
                line     => $find_line->(qr/\bCREATE\s+TABLESPACE\b/i),
                message  => 'Non-UTS segmented/simple tablespace detected (missing MAXPARTITIONS for PBG or NUMPARTS for PBR); deprecated and disallowed for new creates in Db2 12 FL504+ / Db2 13.',
            };
        }

        if ($has_segsize && ($has_segsize % 4 != 0 || $has_segsize < 4 || $has_segsize > 64)) {
            push @issues, {
                code     => 'DB2Z_UTS004',
                severity => 'error',
                line     => $find_line->(qr/\bSEGSIZE\b/i),
                message  => "Invalid SEGSIZE $has_segsize: Db2 for z/OS requires a multiple of 4 between 4 and 64.",
            };
        }
    }

    return {
        ok              => 1,
        has_bind        => $has_bind,
        parsed_options  => \%options,
        tablespace_type => $ts_type,
        issue_count     => scalar(@issues),
        issues          => \@issues,
        recommended_bind_template =>
            "BIND PACKAGE(COLLID) MEMBER(PGMNAME) -\n"
          . "     ISOLATION(CS) CURRENTDATA(NO) RELEASE(COMMIT) -\n"
          . "     VALIDATE(BIND) EXPLAIN(YES) APREUSE(WARN) -\n"
          . "     DEGREE(1) ACTION(REPLACE)",
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
    if (defined $line && $line =~ /\b(SYSIBM\.[A-Za-z0-9_]+)/i) {
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
    my @diags;

    if ($text =~ /\b(?:(?:RE)?BIND\s+(?:PACKAGE|PLAN)|CREATE\s+TABLESPACE)\b/i) {
        my $chk = $self->tool_bind_package_check({ bind_text => $text });
        for my $iss (@{ $chk->{issues} || [] }) {
            push @diags, $self->make_diagnostic(
                line     => $iss->{line} // 0,
                col      => 0,
                severity => $iss->{severity} || 'warn',
                code     => $iss->{code}     || 'DB2Z',
                message  => $iss->{message}  || '',
            );
        }
    }

    if ($text =~ /\bSELECT\b.*\bWHERE\b/is) {
        my $audit = $self->_audit_stage1_stage2($text);
        my @lines = split /\n/, $text, -1;
        for my $s2 (@{ $audit->{stage2_predicates} || [] }) {
            my $ln_idx = 0;
            for my $i (0 .. $#lines) {
                if ($lines[$i] =~ /\bWHERE\b/i) { $ln_idx = $i; last }
            }
            push @diags, $self->make_diagnostic(
                line     => $ln_idx,
                col      => 0,
                severity => 'warn',
                code     => 'DB2Z_STAGE2',
                message  => "Stage 2 / non-indexable predicate '$s2->{predicate}': $s2->{reason}",
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
        if ($ln =~ /^\s*CREATE\s+(?:GLOBAL\s+TEMPORARY\s+)?(TABLE|TABLESPACE|INDEX|VIEW|PROCEDURE|DATABASE|STOGROUP)\s+([A-Za-z0-9_\.\$\@\#]+)/i) {
            my ($obj, $name) = (uc($1), $2);
            my $kind = ($obj eq 'PROCEDURE') ? 'function'
                     : ($obj eq 'TABLE' || $obj eq 'VIEW') ? 'struct'
                     : 'class';
            push @syms, $self->make_symbol(name => $name, kind => $kind, line => $i, col => 0, detail => "Db2 z/OS $obj");
        }
        elsif ($ln =~ /\b(?:RE)?BIND\s+(PACKAGE|PLAN)\s*\(\s*([A-Za-z0-9_\.\$]+)\s*\)/i) {
            push @syms, $self->make_symbol(name => $2, kind => 'module', line => $i, col => 0, detail => "BIND " . uc($1));
        }
        elsif ($ln =~ /\bEXEC\s+SQL\s+DECLARE\s+([A-Za-z0-9_\.\$\@\#]+)\s+TABLE\b/i) {
            push @syms, $self->make_symbol(name => $1, kind => 'struct', line => $i, col => 0, detail => 'DCLGEN TABLE');
        }
    }
    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::Db2z - Db2 for z/OS (SYSIBM, PLAN_TABLE, DCLGEN & BIND) MCP and LSP domain pack

=head1 DESCRIPTION

Provides guarded DRDA/ODBC SQL execution, C<SYSIBM> catalog inspection,
C<PLAN_TABLE>/C<DSN_STATEMNT_TABLE> access-path and Stage 1 vs Stage 2
predicate auditing, COBOL C<DCLGEN> generation (C<PIC X>,
C<COMP>, C<COMP-3>, 49-level C<VARCHAR>, and null indicators), and
C<BIND PACKAGE> / UTS PBG-PBR validation.

=head1 TOOLS

=over 4

=item * C<db2z_query>

=item * C<db2z_catalog_inspect>

=item * C<db2z_plan_table_analyze>

=item * C<db2z_dclgen_generate>

=item * C<db2z_bind_package_check>

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
