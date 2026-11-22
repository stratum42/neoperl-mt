package NeoPerl::MCP::Pack::COBOL;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';
use File::Spec ();
use File::Temp qw(tempfile);
use IPC::Open3 qw(open3);

our $VERSION = '0.01';

my $CACHED_COBC_PATH;
my $CACHED_COBC_VER;
my $COBC_PROBED = 0;

# EXEC CICS command reference (IBM CICS TS / Enterprise COBOL)
my %CICS_COMMANDS = (
    'LINK' => {
        category => 'program_control',
        syntax   => 'EXEC CICS LINK PROGRAM(name) [COMMAREA(data-area) LENGTH(len) | CHANNEL(name)] RESP(ws-resp) END-EXEC',
        options  => [qw(PROGRAM COMMAREA LENGTH DATALENGTH CHANNEL SYSID SYNCONRETURN RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2 EIBCALEN)],
        notes    => 'Invokes a subprogram at the next logical level and returns control to the caller (like a subroutine call). Prefer CHANNEL/CONTAINER over 32 KiB COMMAREA for large payloads.',
    },
    'XCTL' => {
        category => 'program_control',
        syntax   => 'EXEC CICS XCTL PROGRAM(name) [COMMAREA(data-area) LENGTH(len) | CHANNEL(name)] RESP(ws-resp) END-EXEC',
        options  => [qw(PROGRAM COMMAREA LENGTH CHANNEL RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2 EIBCALEN)],
        notes    => 'Transfers control to another program at the same logical level without returning to the caller (tail-call transfer, freeing current program storage).',
    },
    'RETURN' => {
        category => 'program_control',
        syntax   => 'EXEC CICS RETURN [TRANSID(trans) [COMMAREA(data-area) LENGTH(len) | CHANNEL(name)]] END-EXEC',
        options  => [qw(TRANSID COMMAREA LENGTH IMMEDIATE CHANNEL INPUTMSG RESP RESP2)],
        eib      => [qw(EIBTRNID EIBCALEN)],
        notes    => 'Returns control to caller or CICS. Specifying TRANSID implements pseudo-conversational 3270 transaction flow so terminal waits do not tie up tasks.',
    },
    'SEND MAP' => {
        category => 'bms_terminal',
        syntax   => 'EXEC CICS SEND MAP(mapname) MAPSET(setname) [FROM(area) | MAPONLY | DATAONLY] [ERASE | ERASEAUP] [CURSOR(pos)] [FREEKB] RESP(ws-resp) END-EXEC',
        options  => [qw(MAP MAPSET FROM MAPONLY DATAONLY ERASE ERASEAUP CURSOR FREEKB ALARM RESP RESP2)],
        eib      => [qw(EIBRESP EIBAID EIBCPOSN)],
        notes    => 'Sends a BMS 3270 formatted screen map to the terminal. Use MAPONLY for static initial display, DATAONLY for incremental refresh, and ERASE on first screen.',
    },
    'RECEIVE MAP' => {
        category => 'bms_terminal',
        syntax   => 'EXEC CICS RECEIVE MAP(mapname) MAPSET(setname) INTO(area) RESP(ws-resp) END-EXEC',
        options  => [qw(MAP MAPSET INTO SET RESP RESP2)],
        eib      => [qw(EIBRESP EIBAID EIBCPOSN)],
        notes    => 'Receives modified 3270 fields into the symbolic BMS map area. Always check EIBAID (DFHENTER, DFHPF3, DFHCLEAR) and RESP=DFHRESP(MAPFAIL) for unmodified empty screens.',
    },
    'READ' => {
        category => 'file_control',
        syntax   => 'EXEC CICS READ FILE(name) INTO(area) RIDFLD(key) [KEYLENGTH(n)] [GENERIC] [GTEQ|EQUAL] [UPDATE] RESP(ws-resp) END-EXEC',
        options  => [qw(FILE DATASET INTO SET RIDFLD KEYLENGTH LENGTH GENERIC EQUAL GTEQ UPDATE RBA RRN RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Reads a VSAM KSDS/ESDS/RRDS record. Specify UPDATE to lock the control interval prior to REWRITE or DELETE; handle DFHRESP(NOTFND).',
    },
    'WRITE' => {
        category => 'file_control',
        syntax   => 'EXEC CICS WRITE FILE(name) FROM(area) RIDFLD(key) [LENGTH(len)] RESP(ws-resp) END-EXEC',
        options  => [qw(FILE DATASET FROM RIDFLD KEYLENGTH LENGTH MASSINSERT RBA RRN RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Inserts a new VSAM record; handle DFHRESP(DUPREC) for duplicate KSDS keys.',
    },
    'REWRITE' => {
        category => 'file_control',
        syntax   => 'EXEC CICS REWRITE FILE(name) FROM(area) [LENGTH(len)] RESP(ws-resp) END-EXEC',
        options  => [qw(FILE DATASET FROM LENGTH TOKEN RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Updates a record previously read via READ UPDATE, releasing the exclusive lock (unless recoverable VSAM holds lock until SYNCPOINT).',
    },
    'DELETE' => {
        category => 'file_control',
        syntax   => 'EXEC CICS DELETE FILE(name) [RIDFLD(key) [KEYLENGTH(n)] [GENERIC NUMREC(cnt)]] RESP(ws-resp) END-EXEC',
        options  => [qw(FILE DATASET RIDFLD KEYLENGTH GENERIC NUMREC RRN TOKEN RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Deletes a VSAM KSDS/RRDS record either after READ UPDATE (omit RIDFLD) or directly by RIDFLD.',
    },
    'STARTBR' => {
        category => 'file_control',
        syntax   => 'EXEC CICS STARTBR FILE(name) RIDFLD(key) [GTEQ|EQUAL] [REQID(id)] RESP(ws-resp) END-EXEC',
        options  => [qw(FILE DATASET RIDFLD KEYLENGTH GENERIC EQUAL GTEQ REQID RBA RRN RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Positions a VSAM browse cursor without transferring a record yet; follow with READNEXT/READPREV and always close with ENDBR.',
    },
    'READNEXT' => {
        category => 'file_control',
        syntax   => 'EXEC CICS READNEXT FILE(name) INTO(area) RIDFLD(key) [LENGTH(len)] [REQID(id)] RESP(ws-resp) END-EXEC',
        options  => [qw(FILE DATASET INTO SET RIDFLD KEYLENGTH LENGTH REQID RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Advances VSAM browse forward to the next sequential record; check RESP = DFHRESP(ENDFILE).',
    },
    'ENDBR' => {
        category => 'file_control',
        syntax   => 'EXEC CICS ENDBR FILE(name) [REQID(id)] RESP(ws-resp) END-EXEC',
        options  => [qw(FILE DATASET REQID RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Terminates an active VSAM browse started by STARTBR and releases VSAM strings.',
    },
    'SYNCPOINT' => {
        category => 'syncpoint',
        syntax   => 'EXEC CICS SYNCPOINT [ROLLBACK] RESP(ws-resp) END-EXEC',
        options  => [qw(ROLLBACK RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Commits (or with ROLLBACK, backs out) all recoverable resources in the current unit of work (VSAM, Db2 via two-phase commit, MQ, TSQ).',
    },
    'GETMAIN' => {
        category => 'storage',
        syntax   => 'EXEC CICS GETMAIN SET(ptr) FLENGTH(len) [INITIMG(byte)] [BELOW] [SHARED] RESP(ws-resp) END-EXEC',
        options  => [qw(SET FLENGTH LENGTH INITIMG BELOW SHARED USERDATAKEY CICSDATAKEY NOSUSPEND RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Acquires dynamic CICS task storage (prefer FLENGTH for 31-bit above-the-line storage; pair with FREEMAIN unless task-lifetime automatic free is intended).',
    },
    'FREEMAIN' => {
        category => 'storage',
        syntax   => 'EXEC CICS FREEMAIN DATAPOINTER(ptr) | DATA(area) RESP(ws-resp) END-EXEC',
        options  => [qw(DATAPOINTER DATA RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Releases storage acquired via GETMAIN.',
    },
    'ABEND' => {
        category => 'abend',
        syntax   => 'EXEC CICS ABEND ABCODE(code4) [NODUMP] [CANCEL] END-EXEC',
        options  => [qw(ABCODE NODUMP CANCEL)],
        eib      => [qw(EIBTASKN EIBTRNID)],
        notes    => 'Abnormally terminates the CICS task with a 4-character abend code and triggers dynamic transaction backout.',
    },
    'HANDLE CONDITION' => {
        category => 'exception',
        syntax   => 'EXEC CICS HANDLE CONDITION condition(label) [ERROR(label)] END-EXEC',
        options  => [qw(NOTFND DUPREC ENDFILE MAPFAIL LENGERR NOSPACE ERROR)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Legacy implicit GO TO exception handler. Enterprise COBOL generally uses inline RESP(ws-resp) RESP2(ws-resp2) on each EXEC CICS command instead of HANDLE CONDITION.',
    },
    'RESP' => {
        category => 'exception',
        syntax   => 'RESP(ws-resp) [RESP2(ws-resp2)]  * compare with DFHRESP(NORMAL), DFHRESP(NOTFND), DFHRESP(ENDFILE)',
        options  => [qw(RESP RESP2 DFHRESP)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Structured inline exception handling option on EXEC CICS commands (both ws-resp and ws-resp2 are PIC S9(8) COMP / fullword binary). Suppresses default abend/HANDLE CONDITION.',
    },
    'RESP2' => {
        category => 'exception',
        syntax   => 'RESP(ws-resp) RESP2(ws-resp2)',
        options  => [qw(RESP RESP2)],
        eib      => [qw(EIBRESP2)],
        notes    => 'Secondary reason code (PIC S9(8) COMP) clarifying the specific cause of a non-NORMAL RESP value.',
    },
    'PUT CONTAINER' => {
        category => 'channels',
        syntax   => 'EXEC CICS PUT CONTAINER(name) CHANNEL(ch) FROM(area) FLENGTH(len) [CHAR|BIT] RESP(ws-resp) END-EXEC',
        options  => [qw(CONTAINER CHANNEL FROM FLENGTH CHAR BIT APPEND RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Stores arbitrarily large typed data (>32 KiB) in a named CICS Channel container — modern replacement for COMMAREA.',
    },
    'GET CONTAINER' => {
        category => 'channels',
        syntax   => 'EXEC CICS GET CONTAINER(name) CHANNEL(ch) INTO(area) FLENGTH(len) RESP(ws-resp) END-EXEC',
        options  => [qw(CONTAINER CHANNEL INTO SET FLENGTH NODATA RESP RESP2)],
        eib      => [qw(EIBRESP EIBRESP2)],
        notes    => 'Retrieves data from a CICS Channel container (use NODATA to query FLENGTH first).',
    },
);

# EXEC SQL SQLCODE / SQLSTATE reference
my %SQLCODES = (
    '0'    => { sqlstate => '00000', severity => 'success', meaning => 'Successful execution.', action => 'Proceed normally; inspect SQLWARN0 for non-fatal warnings.' },
    '+100' => { sqlstate => '02000', severity => 'not_found', meaning => 'Row not found for FETCH, SELECT INTO, UPDATE, or DELETE, or end of cursor.', action => 'Exit FETCH loop cleanly or treat lookup as absent.' },
    '-180' => { sqlstate => '22007', severity => 'error', meaning => 'Syntax of string representation of a datetime value is incorrect.', action => 'Validate ISO/USA/EUR date/timestamp formatting before passing host variable.' },
    '-204' => { sqlstate => '42704', severity => 'error', meaning => 'Undefined table, view, or object name.', action => 'Verify qualifier/CURRENT SCHEMA and catalog existence.' },
    '-206' => { sqlstate => '42703', severity => 'error', meaning => 'Column is not valid in the context where it is used.', action => 'Check column spelling and table aliases against DCLGEN.' },
    '-305' => { sqlstate => '22002', severity => 'error', meaning => 'NULL value returned into host variable with no null indicator variable.', action => 'Add a PIC S9(4) COMP indicator variable (:HV:IND) or wrap column in COALESCE().' },
    '-501' => { sqlstate => '24501', severity => 'error', meaning => 'Cursor specified in FETCH or CLOSE is not open.', action => 'Ensure OPEN succeeded and handle COMMIT closing non-WITH HOLD cursors.' },
    '-502' => { sqlstate => '24502', severity => 'error', meaning => 'Cursor specified in OPEN is already open.', action => 'CLOSE cursor before re-OPENing.' },
    '-803' => { sqlstate => '23505', severity => 'error', meaning => 'Duplicate key value violates a unique index or primary key constraint.', action => 'Handle duplicate key gracefully (retry, UPDATE/MERGE, or business error).' },
    '-805' => { sqlstate => '51002', severity => 'error', meaning => 'DBRM or package name not found in plan / collection.', action => 'Run BIND PACKAGE into the expected collection and verify PKLIST on the BIND PLAN.' },
    '-811' => { sqlstate => '21000', severity => 'error', meaning => 'Result of an embedded SELECT INTO or scalar subselect returned more than one row.', action => 'Use a cursor (DECLARE/OPEN/FETCH) or tighten WHERE / FETCH FIRST 1 ROW ONLY.' },
    '-818' => { sqlstate => '51003', severity => 'error', meaning => 'Precompiler consistency token (CONTOKEN) timestamp mismatch between load module and bound DBRM/package.', action => 'Re-bind the package from the exact DBRM generated during the matching precompile/compile.' },
    '-904' => { sqlstate => '57011', severity => 'error', meaning => 'Unsuccessful execution caused by an unavailable resource (tablespace stopped, utility lock, dataset unavailable).', action => 'Inspect SQLERRMC reason code (e.g. 00C90081/00C90084) and coordinate with DBA.' },
    '-911' => { sqlstate => '40001', severity => 'error', meaning => 'Current unit of work rolled back due to deadlock (reason 00C90088) or lock timeout (00C9008E).', action => 'Re-acquire transaction state and retry with backoff; review COMMIT frequency and index coverage.' },
    '-913' => { sqlstate => '57033', severity => 'error', meaning => 'Deadlock or timeout occurred without automatic rollback.', action => 'Issue explicit ROLLBACK / EXEC CICS SYNCPOINT ROLLBACK before retrying.' },
    '-922' => { sqlstate => '42505', severity => 'error', meaning => 'Authorization failure for plan, package, or connection.', action => 'Verify RACF/Db2 GRANT EXECUTE on plan/package.' },
);

my %SQLCA_FIELDS = (
    SQLCAID   => 'PIC X(8) — Eyecatcher "SQLCA   ".',
    SQLCABC   => 'PIC S9(9) COMP-4 — Byte length of SQLCA (136).',
    SQLCODE   => 'PIC S9(9) COMP-4 — Return code (0=OK, >0=warning/+100 not found, <0=error).',
    SQLERRML  => 'PIC S9(4) COMP-4 — Active length of SQLERRMC.',
    SQLERRMC  => 'PIC X(70) — Error message tokens separated by X\'FF\'.',
    SQLERRP   => 'PIC X(8) — Diagnostic module name (e.g. DSNX...).',
    SQLERRD   => 'OCCURS 6 PIC S9(9) COMP-4 — SQLERRD(3) holds rows affected by INSERT/UPDATE/DELETE.',
    SQLWARN   => 'SQLWARN0..SQLWARNA — Warning flags (SQLWARN0="W" indicates warning; SQLWARN1="W" string truncation).',
    SQLSTATE  => 'PIC X(5) — ANSI/ISO 5-character status class+subclass ("00000" OK, "02000" not found).',
);

my %COBOL_KEYWORDS = (
    'COMP-3'          => 'PACKED-DECIMAL: stores 2 decimal digits per byte + trailing sign nibble -> floor(digits/2) + 1 bytes.',
    'PACKED-DECIMAL'  => 'Same as COMP-3: floor(digits/2) + 1 bytes (IBM Z native decimal arithmetic).',
    'COMP'            => 'Binary integer (COMP/COMP-4/BINARY): 1-4 digits = 2B, 5-9 digits = 4B, 10-18 digits = 8B (subject to TRUNC compiler option).',
    'COMP-4'          => 'Binary integer identical to COMP/BINARY (2, 4, or 8 bytes).',
    'COMP-5'          => 'Native binary integer (2, 4, or 8 bytes) using full binary capacity regardless of PIC 9(n) decimal limit (essential for C/CICS/system APIs).',
    'COMP-1'          => 'Single-precision floating point (4 bytes, no PIC clause).',
    'COMP-2'          => 'Double-precision floating point (8 bytes, no PIC clause).',
    'REDEFINES'       => 'Overlays another storage item at the same byte offset (union semantics). Subordinate redefining item must not exceed target length.',
    'OCCURS'          => 'Declares a fixed or variable-length (DEPENDING ON) array/table.',
    'SYNC'            => 'SYNCHRONIZED: inserts slack bytes to align binary/float elementary items on halfword/fullword/doubleword boundaries.',
    'PERFORM'         => 'Structured subroutine/loop invocation (PERFORM para, PERFORM para THRU para-exit, inline PERFORM UNTIL ... END-PERFORM).',
    'EVALUATE'        => 'Multi-branch switch statement (always include WHEN OTHER to catch unexpected values).',
);

sub meta {
    return {
        name             => 'cobol',
        label            => 'COBOL (Enterprise / ILE / GnuCOBOL)',
        category         => 'mainframe',
        version          => $VERSION,
        description      => 'Enterprise COBOL / ILE COBOL / GnuCOBOL pack: exact PIC/COMP/COMP-3/COMP-5/SYNC/REDEFINES/OCCURS byte layout calculator, Division/Section/Paragraph/PERFORM flow outline, EXEC CICS & EXEC SQL SQLCA reference, fixed-format column linter, and live cobc syntax check.',
        filetypes        => [qw(cobol cbl cob cpy)],
        upstream_credits => [
            'Eclipse Che4z che-che4z-lsp-for-cobol (EPL-2.0)',
            'GnuCOBOL cobc (GPL/LGPL)',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'cobol_pic_layout',
            description => 'Parse COBOL 01..49/77/88 Data Division records and compute exact byte offsets, DISPLAY/COMP/COMP-3 (PACKED-DECIMAL)/COMP-4/COMP-5/COMP-1/COMP-2 sizes, SYNC alignment slack bytes, REDEFINES overlays, and OCCURS [DEPENDING ON] spans.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code         => { type => 'string', description => 'COBOL Data Division / Copybook source text.' },
                    pointer_size => { type => 'integer', description => 'Optional POINTER byte size (4 for 31-bit z/OS, 8 for 64-bit; default 4).' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->pic_layout($args->{code} // '', pointer_size => $args->{pointer_size});
            },
        },
        {
            name        => 'cobol_outline_flow',
            description => 'Parse COBOL Divisions, Sections, Paragraphs, PERFORM / PERFORM THRU / GO TO / CALL control-flow graph, COPY ... REPLACING dependencies, EXEC SQL, and EXEC CICS blocks.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'COBOL source program.' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->outline_flow($args->{code} // '');
            },
        },
        {
            name        => 'cobol_cics_sql_ref',
            description => 'Look up EXEC CICS commands (LINK, XCTL, RETURN, SEND/RECEIVE MAP, READ/WRITE/REWRITE/DELETE, STARTBR/READNEXT/ENDBR, SYNCPOINT, GETMAIN/FREEMAIN, ABEND, HANDLE CONDITION, RESP/RESP2) and EXEC SQL SQLCA/SQLCODE codes (0, +100, -803, -805, -811, -818, -904, -911, etc.).',
            inputSchema => {
                type       => 'object',
                properties => {
                    command => { type => 'string', description => 'EXEC CICS command name (e.g. LINK, SEND MAP, READ, SYNCPOINT, RESP).' },
                    sqlcode => { type => 'string', description => 'SQLCODE value (e.g. 0, +100, -803, -818, -911) or SQLCA field name.' },
                    query   => { type => 'string', description => 'Free-text search across CICS commands, SQLCODEs, and SQLCA fields.' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->cics_sql_ref($args || {});
            },
        },
        {
            name        => 'cobol_lint_compile',
            description => 'Validate COBOL fixed-format columns (1-6, col 7 indicator, Area A 8-11, Area B 12-72, cols 73-80), PERFORM targets & dead paragraphs, ON SIZE ERROR, EVALUATE WHEN OTHER, AND run live cobc -fsyntax-only -Wall when GnuCOBOL cobc is installed.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code     => { type => 'string', description => 'COBOL source text to lint and syntax-check.' },
                    format   => { type => 'string', description => 'Source format: fixed (default) or free.' },
                    run_cobc => { type => 'boolean', description => 'Whether to invoke live cobc -fsyntax-only -Wall if available (default true).' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->lint_compile(
                    code     => $args->{code} // '',
                    format   => $args->{format},
                    run_cobc => exists($args->{run_cobc}) ? $args->{run_cobc} : 1,
                );
            },
        },
    ];
}

# --- Live cobc Discovery ---

sub find_cobc {
    my ($self) = @_;
    if (!$COBC_PROBED) {
        $COBC_PROBED = 1;
        my @cands = (
            ($ENV{COBC} ? $ENV{COBC} : ()),
            '/opt/homebrew/bin/cobc',
            '/usr/local/bin/cobc',
            '/usr/bin/cobc',
            'cobc',
        );
        for my $c (@cands) {
            if ($c =~ m{/}) {
                if (-x $c) {
                    $CACHED_COBC_PATH = $c;
                    last;
                }
            }
            else {
                for my $d (File::Spec->path) {
                    my $full = File::Spec->catfile($d, $c);
                    if (-x $full) {
                        $CACHED_COBC_PATH = $full;
                        last;
                    }
                }
                last if $CACHED_COBC_PATH;
            }
        }
        if ($CACHED_COBC_PATH) {
            my $out = '';
            eval {
                my $pid = open3(my $in, my $fh, undef, $CACHED_COBC_PATH, '--version');
                close $in;
                local $/;
                $out = <$fh> // '';
                close $fh;
                waitpid($pid, 0);
            };
            my ($first) = split(/\r?\n/, $out);
            $CACHED_COBC_VER = $first // 'cobc';
        }
    }
    return wantarray ? ($CACHED_COBC_PATH, $CACHED_COBC_VER) : $CACHED_COBC_PATH;
}

# --- Helpers for stripping fixed-format columns cleanly ---

sub _is_free_source {
    my ($code, $explicit_fmt) = @_;
    return 1 if defined $explicit_fmt && lc($explicit_fmt) eq 'free';
    return 0 if defined $explicit_fmt && lc($explicit_fmt) eq 'fixed';
    return 1 if defined $code && $code =~ /^\s*>>\s*SOURCE\s+(?:FORMAT\s+)?(?:IS\s+)?FREE\b/im;
    return 0;
}

sub _extract_cobol_code_area {
    my ($raw, $is_free) = @_;
    return '' unless defined $raw;
    if ($is_free) {
        return '' if $raw =~ /^\s*\*>/;
        (my $c = $raw) =~ s/\*>.*$//;
        return $c;
    }
    # Fixed format: cols 1-6 seq, col 7 indicator, cols 8-72 code area (0-based 7..71)
    if (length($raw) >= 7) {
        my $ind = substr($raw, 6, 1);
        return '' if $ind eq '*' || $ind eq '/';
        my $area = length($raw) > 72 ? substr($raw, 7, 65) : substr($raw, 7);
        $area =~ s/\*>.*$//;
        return $area;
    }
    # Short line (e.g. copybook snippet without leading 7 spaces) — still accept if trimmed looks like data item
    return '' if $raw =~ /^\s*\*/;
    return $raw;
}

# --- Tool 1: Exact COBOL PIC / USAGE / SYNC / REDEFINES / OCCURS Layout ---

sub _expand_pic {
    my ($pic) = @_;
    return '' unless defined $pic;
    my $p = uc($pic);
    $p =~ s/\s+//g;
    # Expand repeat counts like 9(7) -> 9999999, X(20) -> X...X, Z(4) -> ZZZZ
    $p =~ s/([^\s\(\)])\((\d+)\)/$1 x int($2)/ge;
    return $p;
}

sub _calc_elementary_size {
    my ($pic_raw, $usage, $sign_separate, $ptr_size) = @_;
    $usage = uc($usage // 'DISPLAY');
    $usage =~ s/^COMPUTATIONAL/COMP/;

    return (4, 4, 'COMP-1', 0) if $usage eq 'COMP-1';
    return (8, 8, 'COMP-2', 0) if $usage eq 'COMP-2';
    if ($usage =~ /^(?:POINTER|PROCEDURE-POINTER|FUNCTION-POINTER|INDEX)$/) {
        my $ps = $ptr_size || 4;
        return ($ps, $ps, $usage, 0);
    }

    my $exp = _expand_pic($pic_raw);
    return (0, 1, $usage, 0) unless length $exp;

    if ($usage eq 'COMP-3' || $usage eq 'PACKED-DECIMAL') {
        my $digits = () = ($exp =~ /[9]/g);
        $digits ||= length($exp);
        my $bytes = int($digits / 2) + 1;
        return ($bytes, 1, 'COMP-3', $digits);
    }

    if ($usage eq 'COMP' || $usage eq 'COMP-4' || $usage eq 'BINARY' || $usage eq 'COMP-5') {
        my $digits = () = ($exp =~ /[9]/g);
        $digits ||= 1;
        my $bytes = ($digits <= 4) ? 2 : ($digits <= 9) ? 4 : ($digits <= 18) ? 8 : 16;
        return ($bytes, $bytes, $usage, $digits);
    }

    # DISPLAY (default) or NATIONAL
    if ($usage eq 'NATIONAL' || $exp =~ /^N+$/) {
        my $chars = () = ($exp =~ /N/g);
        return ($chars * 2, 2, 'NATIONAL', $chars);
    }

    # Remove non-storage virtual characters S, V, P
    (my $phys = $exp) =~ s/[SVP]//g;
    my $bytes = length($phys);
    my $digits = () = ($exp =~ /[9]/g);
    if ($sign_separate && $exp =~ /S/) {
        $bytes += 1;
    }
    return ($bytes, 1, 'DISPLAY', $digits);
}

sub pic_layout {
    my ($self, $code, %opts) = @_;
    my $ptr_size = int($opts{pointer_size} || 4);
    my $is_free  = _is_free_source($code, $opts{format});
    my @lines    = split(/\r?\n/, $code // '');

    # Collect Data Division logical statements (terminated by period)
    my @stmts;
    my $buf = '';
    my $start_ln = 0;

    for (my $i = 0; $i < @lines; $i++) {
        my $area = _extract_cobol_code_area($lines[$i], $is_free);
        next unless $area =~ /\S/;
        $area =~ s/^\s+|\s+$//g;

        # Stop collecting if we reach PROCEDURE DIVISION
        last if $area =~ /^PROCEDURE\s+DIVISION\b/i;

        # Flush if a new level number starts without prior period (defensive)
        if ($buf ne '' && $area =~ /^(?:0?[1-9]|[1-4][0-9]|66|77|88)\s+[A-Za-z0-9-]+/) {
            push @stmts, { text => $buf, line => $start_ln };
            $buf = '';
        }

        if ($buf eq '') {
            $start_ln = $i + 1;
            $buf = $area;
        }
        else {
            $buf .= ' ' . $area;
        }

        if ($buf =~ /\.\s*$/) {
            $buf =~ s/\.\s*$//;
            push @stmts, { text => $buf, line => $start_ln };
            $buf = '';
        }
    }
    push @stmts, { text => $buf, line => $start_ln } if length $buf;

    # Parse statements into structured hierarchical records
    my @raw_items;
    for my $s (@stmts) {
        my $t = $s->{text};
        next unless $t =~ /^(\d{1,2})\s+([A-Za-z][A-Za-z0-9-]*|FILLER)(?:\s+(.*))?$/i;
        my ($lvl, $name, $clauses) = (int($1), uc($2), $3 // '');
        next unless ($lvl >= 1 && $lvl <= 49) || $lvl == 66 || $lvl == 77 || $lvl == 88;

        my $pic;
        if ($clauses =~ /\bPIC(?:TURE)?\s+(?:IS\s+)?(\S+)/i) {
            $pic = $1;
            $pic =~ s/\.$//;
        }

        my $usage = 'DISPLAY';
        if ($clauses =~ /\b(?:USAGE\s+(?:IS\s+)?)?(COMP(?:UTATIONAL)?-[1-5]|COMP(?:UTATIONAL)?|PACKED-DECIMAL|BINARY|NATIONAL|PROCEDURE-POINTER|FUNCTION-POINTER|POINTER|INDEX|DISPLAY)\b/i) {
            $usage = uc($1);
            $usage =~ s/^COMPUTATIONAL/COMP/;
        }

        my $sync = ($clauses =~ /\bSYNC(?:HRONIZED)?\b/i) ? 1 : 0;
        my $sign_sep = ($clauses =~ /\bSIGN\b.*\bSEPARATE\b/i) ? 1 : 0;

        my $redefines;
        if ($clauses =~ /\bREDEFINES\s+([A-Za-z][A-Za-z0-9-]*)/i) {
            $redefines = uc($1);
        }

        my ($occ_min, $occ_max, $occ_dep) = (1, 1, undef);
        if ($clauses =~ /\bOCCURS\s+(\d+)\s+TO\s+(\d+)(?:\s+TIMES)?(?:\s+DEPENDING\s+(?:ON\s+)?([A-Za-z][A-Za-z0-9-]*))?/i) {
            ($occ_min, $occ_max, $occ_dep) = (int($1), int($2), defined($3) ? uc($3) : undef);
        }
        elsif ($clauses =~ /\bOCCURS\s+(\d+)(?:\s+TIMES)?/i) {
            ($occ_min, $occ_max) = (int($1), int($1));
        }

        my $is_elem = (defined($pic) || $usage =~ /^(?:COMP-1|COMP-2|POINTER|PROCEDURE-POINTER|FUNCTION-POINTER|INDEX)$/) ? 1 : 0;

        push @raw_items, {
            level         => $lvl,
            name          => $name,
            line          => $s->{line},
            pic           => $pic,
            usage         => $usage,
            sync          => $sync,
            sign_separate => $sign_sep,
            redefines     => $redefines,
            occurs_min    => $occ_min,
            occurs_max    => $occ_max,
            depending_on  => $occ_dep,
            is_elementary => $is_elem,
            clauses       => $clauses,
        };
    }

    # Walk items hierarchically to compute exact offsets, slack bytes, REDEFINES overlays, and group OCCURS spans
    my @records;
    my @warnings;
    my $cur_rec;
    my @group_stack;   # stack of open group nodes
    my %named_nodes;   # uc(name) => node (within current 01 record)
    my $cursor = 0;

    my $close_groups_to = sub {
        my ($next_level) = @_;
        while (@group_stack && $group_stack[-1]{level} >= $next_level) {
            my $grp = pop @group_stack;
            my $elem_span = $cursor - $grp->{offset};
            $elem_span = $grp->{max_child_end} - $grp->{offset}
                if defined($grp->{max_child_end}) && ($grp->{max_child_end} - $grp->{offset}) > $elem_span;
            $elem_span = 0 if $elem_span < 0;

            $grp->{elem_bytes}  = $elem_span;
            $grp->{min_bytes}   = $elem_span * $grp->{occurs_min};
            $grp->{total_bytes} = $elem_span * $grp->{occurs_max};
            $grp->{end_offset}  = $grp->{offset} + $grp->{total_bytes};

            if (defined $grp->{redefines}) {
                my $tgt = $named_nodes{ $grp->{redefines} };
                if ($tgt && $grp->{level} != 1 && $grp->{total_bytes} > $tgt->{total_bytes}) {
                    push @warnings, {
                        line    => $grp->{line},
                        code    => 'COBOL_REDEFINES_OVERFLOW',
                        message => "REDEFINES item '$grp->{name}' ($grp->{total_bytes}B) exceeds target '$grp->{redefines}' ($tgt->{total_bytes}B).",
                    };
                }
                # Restore cursor to high-water end of target (or max of target and overlay)
                my $after = $grp->{saved_cursor};
                $after = $grp->{end_offset} if $grp->{end_offset} > $after;
                $cursor = $after;
            }
            else {
                $cursor = $grp->{end_offset};
            }

            if (@group_stack) {
                my $par = $group_stack[-1];
                $par->{max_child_end} = $cursor
                    if !defined($par->{max_child_end}) || $cursor > $par->{max_child_end};
            }
        }
    };

    for my $it (@raw_items) {
        my $lvl = $it->{level};

        # 88 condition names & 66 RENAMES occupy 0 bytes
        if ($lvl == 88 || $lvl == 66) {
            if ($cur_rec) {
                push @{ $cur_rec->{fields} }, {
                    level       => $lvl,
                    name        => $it->{name},
                    kind        => ($lvl == 88 ? 'condition' : 'renames'),
                    offset      => $cursor,
                    elem_bytes  => 0,
                    total_bytes => 0,
                    slack_bytes => 0,
                    line        => $it->{line},
                };
            }
            next;
        }

        # New 01 or 77 record resets cursor (unless 01 REDEFINES previous 01)
        if ($lvl == 1 || $lvl == 77) {
            $close_groups_to->(1);
            if ($cur_rec) {
                $cur_rec->{total_bytes} = $cur_rec->{root}{total_bytes};
                delete $cur_rec->{root};
            }
            $cursor = 0;
            %named_nodes = ();
            $cur_rec = {
                name              => $it->{name},
                level             => $lvl,
                line              => $it->{line},
                total_bytes       => 0,
                total_slack_bytes => 0,
                fields            => [],
            };
            push @records, $cur_rec;
        }
        else {
            $close_groups_to->($lvl);
        }

        my $saved_cursor = $cursor;
        if (defined $it->{redefines}) {
            if (exists $named_nodes{ $it->{redefines} }) {
                $cursor = $named_nodes{ $it->{redefines} }{offset};
            }
            else {
                push @warnings, {
                    line    => $it->{line},
                    code    => 'COBOL_REDEFINES_UNKNOWN',
                    message => "REDEFINES target '$it->{redefines}' for '$it->{name}' was not found in the same record.",
                };
            }
        }

        if ($it->{is_elementary}) {
            my ($elem_bytes, $nat_align, $norm_usage, $digits) = _calc_elementary_size(
                $it->{pic}, $it->{usage}, $it->{sign_separate}, $ptr_size
            );
            my $slack = 0;
            if ($it->{sync} && $nat_align > 1 && ($cursor % $nat_align) != 0) {
                $slack = $nat_align - ($cursor % $nat_align);
            }
            my $offset = $cursor + $slack;
            my $min_b  = $elem_bytes * $it->{occurs_min};
            my $tot_b  = $elem_bytes * $it->{occurs_max};
            my $end    = $offset + $tot_b;

            my $node = {
                level        => $lvl,
                name         => $it->{name},
                kind         => 'elementary',
                pic          => $it->{pic},
                usage        => $norm_usage,
                digits       => $digits,
                sync         => $it->{sync},
                redefines    => $it->{redefines},
                occurs_min   => $it->{occurs_min},
                occurs_max   => $it->{occurs_max},
                depending_on => $it->{depending_on},
                offset       => $offset,
                pos_1based   => $offset + 1,
                slack_bytes  => $slack,
                elem_bytes   => $elem_bytes,
                min_bytes    => $min_b,
                total_bytes  => $tot_b,
                end_offset   => $end,
                line         => $it->{line},
            };

            $cur_rec->{total_slack_bytes} += $slack if $cur_rec;
            push @{ $cur_rec->{fields} }, $node if $cur_rec;
            $cur_rec->{root} = $node if $cur_rec && ($lvl == 1 || $lvl == 77);
            $named_nodes{ $it->{name} } = $node unless $it->{name} eq 'FILLER';

            if (defined $it->{redefines}) {
                my $tgt = $named_nodes{ $it->{redefines} };
                if ($tgt && $lvl != 1 && $tot_b > $tgt->{total_bytes}) {
                    push @warnings, {
                        line    => $it->{line},
                        code    => 'COBOL_REDEFINES_OVERFLOW',
                        message => "REDEFINES item '$it->{name}' (${tot_b}B) exceeds target '$it->{redefines}' ($tgt->{total_bytes}B).",
                    };
                }
                $cursor = ($end > $saved_cursor) ? $end : $saved_cursor;
            }
            else {
                $cursor = $end;
            }

            if (@group_stack) {
                my $par = $group_stack[-1];
                $par->{max_child_end} = $cursor
                    if !defined($par->{max_child_end}) || $cursor > $par->{max_child_end};
            }
        }
        else {
            my $grp = {
                level        => $lvl,
                name         => $it->{name},
                kind         => 'group',
                usage        => $it->{usage},
                redefines    => $it->{redefines},
                occurs_min   => $it->{occurs_min},
                occurs_max   => $it->{occurs_max},
                depending_on => $it->{depending_on},
                offset       => $cursor,
                pos_1based   => $cursor + 1,
                slack_bytes  => 0,
                elem_bytes   => 0,
                min_bytes    => 0,
                total_bytes  => 0,
                end_offset   => $cursor,
                saved_cursor => $saved_cursor,
                max_child_end => $cursor,
                line         => $it->{line},
            };
            push @{ $cur_rec->{fields} }, $grp if $cur_rec;
            $cur_rec->{root} = $grp if $cur_rec && ($lvl == 1 || $lvl == 77);
            $named_nodes{ $it->{name} } = $grp unless $it->{name} eq 'FILLER';
            push @group_stack, $grp;
        }
    }

    $close_groups_to->(1);
    if ($cur_rec) {
        $cur_rec->{total_bytes} = $cur_rec->{root}{total_bytes} if $cur_rec->{root};
        delete $cur_rec->{root};
    }

    # Remove internal scratch fields before returning
    for my $r (@records) {
        for my $f (@{ $r->{fields} }) {
            delete $f->{saved_cursor};
            delete $f->{max_child_end};
        }
    }

    return {
        ok           => 1,
        record_count => scalar(@records),
        records      => \@records,
        warnings     => \@warnings,
    };
}

# --- Tool 2: COBOL Divisions, Sections, Paragraphs, CFG, COPY, EXEC SQL/CICS ---

sub outline_flow {
    my ($self, $code, %opts) = @_;
    my $is_free = _is_free_source($code, $opts{format});
    my @lines   = split(/\r?\n/, $code // '');

    my $program_id = '';
    my @divisions;
    my @sections;
    my @paragraphs;
    my %para_index;
    my @edges;       # { from => ..., to => ..., thru => ..., type => 'PERFORM'|'GOTO', line => ... }
    my @calls;
    my @copies;
    my @exec_sql;
    my @exec_cics;

    my $in_proc     = 0;
    my $cur_para    = '<ENTRY>';
    my $in_exec     = '';
    my $exec_buf    = '';
    my $exec_start  = 0;

    for (my $i = 0; $i < @lines; $i++) {
        my $raw  = $lines[$i];
        my $ln   = $i + 1;
        my $area = _extract_cobol_code_area($raw, $is_free);
        next unless $area =~ /\S/;

        my $lead_spaces = ($area =~ /^(\s*)/) ? length($1) : 0;
        (my $trim = $area) =~ s/^\s+|\s+$//g;

        # Multi-line EXEC SQL / EXEC CICS
        if ($in_exec) {
            $exec_buf .= ' ' . $trim;
            if ($trim =~ /\bEND-EXEC\b/i) {
                my $rec = { start_line => $exec_start, end_line => $ln, body => $exec_buf };
                if ($in_exec eq 'SQL') { push @exec_sql, $rec; }
                else                   { push @exec_cics, $rec; }
                $in_exec  = '';
                $exec_buf = '';
            }
            next;
        }

        if ($trim =~ /\bEXEC\s+(SQL|CICS)\b(.*)$/i) {
            my ($kind, $rest) = (uc($1), $2);
            if ($rest =~ /\bEND-EXEC\b/i) {
                my $rec = { start_line => $ln, end_line => $ln, body => $rest };
                if ($kind eq 'SQL') { push @exec_sql, $rec; }
                else                { push @exec_cics, $rec; }
            }
            else {
                $in_exec    = $kind;
                $exec_start = $ln;
                $exec_buf   = $rest;
            }
            next;
        }

        # PROGRAM-ID
        if ($trim =~ /^PROGRAM-ID\.\s*([A-Za-z0-9_-]+)/i) {
            $program_id = uc($1);
        }

        # COPY member [REPLACING ...]
        if ($trim =~ /\bCOPY\s+['"]?([A-Za-z0-9_-]+)['"]?(?:\s+(REPLACING\b.*))?/i) {
            push @copies, { member => uc($1), replacing => $2 // '', line => $ln };
        }

        # DIVISION headers
        if ($trim =~ /^(IDENTIFICATION|ID|ENVIRONMENT|DATA|PROCEDURE)\s+DIVISION\b/i) {
            my $div = uc($1);
            $div = 'IDENTIFICATION' if $div eq 'ID';
            push @divisions, { name => $div, line => $ln };
            $in_proc = ($div eq 'PROCEDURE') ? 1 : 0;
            $cur_para = '<ENTRY>' if $in_proc;
            next;
        }

        # SECTION headers
        if ($trim =~ /^([A-Za-z0-9][A-Za-z0-9-]*)\s+SECTION\b/i) {
            my $sec = uc($1);
            push @sections, { name => $sec, line => $ln, in_procedure => $in_proc };
            $cur_para = $sec if $in_proc;
            next;
        }

        next unless $in_proc;

        # Paragraph header inside PROCEDURE DIVISION:
        # In fixed format, Area A starts at col 8 ($lead_spaces <= 3); name followed by '.'
        my %non_para = map { $_ => 1 } qw(
            EXIT CONTINUE GOBACK STOP ELSE NEXT END-IF END-EVALUATE END-PERFORM
            END-READ END-WRITE END-CALL END-EXEC END-SEARCH END-STRING END-UNSTRING
            DECLARATIVES END-DECLARATIVES
        );
        if (($is_free || $lead_spaces <= 3)
            && $trim =~ /^([A-Za-z0-9][A-Za-z0-9-]*)\.\s*$/
            && !$non_para{ uc($1) })
        {
            my $pname = uc($1);
            push @paragraphs, { name => $pname, line => $ln, idx => scalar(@paragraphs) };
            $para_index{$pname} = $#paragraphs;
            $cur_para = $pname;
            next;
        }

        # Control flow: PERFORM <tgt> [THRU|THROUGH <end>]
        if ($trim =~ /\bPERFORM\s+([A-Za-z0-9][A-Za-z0-9-]*)(?:\s+(?:THRU|THROUGH)\s+([A-Za-z0-9][A-Za-z0-9-]*))?/i) {
            my ($tgt, $thru) = (uc($1), defined($2) ? uc($2) : undef);
            my %inline_kw = map { $_ => 1 } qw(UNTIL VARYING WITH TEST TIMES);
            if (!$inline_kw{$tgt} && $tgt !~ /^\d+$/) {
                push @edges, {
                    from => $cur_para,
                    to   => $tgt,
                    thru => $thru,
                    type => 'PERFORM',
                    line => $ln,
                };
            }
        }

        # GO TO <tgt>
        if ($trim =~ /\bGO\s+TO\s+([A-Za-z0-9][A-Za-z0-9-]*)/i) {
            push @edges, {
                from => $cur_para,
                to   => uc($1),
                type => 'GOTO',
                line => $ln,
            };
        }

        # CALL <program>
        if ($trim =~ /\bCALL\s+(['"][^'"]+['"]|[A-Za-z][A-Za-z0-9-]*)/i) {
            my $raw_tgt = $1;
            my $is_static = ($raw_tgt =~ /^['"](.+)['"]$/) ? 1 : 0;
            my $name = $is_static ? $1 : uc($raw_tgt);
            push @calls, { target => $name, call_type => ($is_static ? 'static' : 'dynamic'), line => $ln };
        }
    }

    # Compute undefined PERFORM/GOTO targets and unreachable/dead paragraphs
    my %sec_names = map { $_->{name} => 1 } grep { $_->{in_procedure} } @sections;
    my %reachable;
    $reachable{ $paragraphs[0]{name} } = 1 if @paragraphs;

    my @undefined_targets;
    for my $e (@edges) {
        if (!exists $para_index{ $e->{to} } && !exists $sec_names{ $e->{to} }) {
            push @undefined_targets, $e;
        }
        else {
            $reachable{ $e->{to} } = 1;
            if (defined $e->{thru} && exists $para_index{ $e->{to} } && exists $para_index{ $e->{thru} }) {
                my ($a, $b) = ($para_index{ $e->{to} }, $para_index{ $e->{thru} });
                for my $k ($a .. $b) {
                    $reachable{ $paragraphs[$k]{name} } = 1;
                }
            }
        }
    }

    my @dead_paragraphs;
    if (@paragraphs > 1) {
        for my $p (@paragraphs) {
            next if $reachable{ $p->{name} };
            push @dead_paragraphs, $p;
        }
    }

    return {
        ok                => 1,
        program_id        => $program_id,
        divisions         => \@divisions,
        sections          => \@sections,
        paragraphs        => \@paragraphs,
        cfg_edges         => \@edges,
        calls             => \@calls,
        copies            => \@copies,
        exec_sql          => \@exec_sql,
        exec_cics         => \@exec_cics,
        undefined_targets => \@undefined_targets,
        dead_paragraphs   => \@dead_paragraphs,
    };
}

# --- Tool 3: EXEC CICS & EXEC SQL Reference ---

sub cics_sql_ref {
    my ($self, $args) = @_;
    $args ||= {};
    my $cmd   = defined $args->{command} ? uc($args->{command}) : '';
    my $sc    = defined $args->{sqlcode} ? uc($args->{sqlcode}) : '';
    my $query = defined $args->{query}   ? lc($args->{query})   : '';

    $cmd =~ s/^\s+|\s+$//g;
    $cmd =~ s/^EXEC\s+CICS\s+//i;
    $sc  =~ s/^\s+|\s+$//g;

    my @cics_matches;
    my @sql_matches;

    if (length $cmd) {
        if (exists $CICS_COMMANDS{$cmd}) {
            push @cics_matches, { command => $cmd, %{ $CICS_COMMANDS{$cmd} } };
        }
        else {
            for my $k (sort keys %CICS_COMMANDS) {
                next unless index($k, $cmd) >= 0;
                push @cics_matches, { command => $k, %{ $CICS_COMMANDS{$k} } };
            }
        }
    }

    if (length $sc) {
        my $norm = ($sc eq '100') ? '+100' : $sc;
        if (exists $SQLCODES{$norm}) {
            push @sql_matches, { sqlcode => $norm, %{ $SQLCODES{$norm} } };
        }
        elsif (exists $SQLCA_FIELDS{$sc}) {
            push @sql_matches, { sqlca_field => $sc, description => $SQLCA_FIELDS{$sc} };
        }
        else {
            for my $k (sort keys %SQLCODES) {
                next unless index($k, $sc) >= 0 || index($SQLCODES{$k}{sqlstate}, $sc) >= 0;
                push @sql_matches, { sqlcode => $k, %{ $SQLCODES{$k} } };
            }
        }
    }

    if (length $query || (!length($cmd) && !length($sc))) {
        for my $k (sort keys %CICS_COMMANDS) {
            my $e = $CICS_COMMANDS{$k};
            if (length $query) {
                my $hay = lc("$k $e->{category} $e->{syntax} $e->{notes} " . join(' ', @{ $e->{options} }));
                next unless index($hay, $query) >= 0;
            }
            push @cics_matches, { command => $k, %$e };
        }
        for my $k (sort keys %SQLCODES) {
            my $e = $SQLCODES{$k};
            if (length $query) {
                my $hay = lc("$k $e->{sqlstate} $e->{meaning} $e->{action}");
                next unless index($hay, $query) >= 0;
            }
            push @sql_matches, { sqlcode => $k, %$e };
        }
    }

    return {
        ok            => 1,
        cics_matches  => \@cics_matches,
        sql_matches   => \@sql_matches,
        sqlca_fields  => \%SQLCA_FIELDS,
        cics_catalog  => scalar(keys %CICS_COMMANDS),
        sql_catalog   => scalar(keys %SQLCODES),
    };
}

# --- Tool 4: Fixed-Format Column Linter + Flow Audit + LIVE cobc Syntax Check ---

sub _run_live_cobc {
    my ($self, $code, $is_free) = @_;
    my ($cobc, $ver) = $self->find_cobc();
    if (!$cobc) {
        return {
            available   => 0,
            path        => undef,
            version     => undef,
            exit_code   => undef,
            passed      => undef,
            raw_output  => '',
            diagnostics => [],
        };
    }

    my ($fh, $tmpfile) = tempfile(SUFFIX => '.cbl', UNLINK => 1);
    print $fh ($code // '');
    close $fh;

    my @cmd = ($cobc, '-fsyntax-only', '-Wall');
    push @cmd, '-free' if $is_free;
    push @cmd, $tmpfile;

    my $raw_out = '';
    my $exit_code = -1;
    my $ok = eval {
        my $pid = open3(my $in, my $out, undef, @cmd);
        close $in;
        local $/;
        $raw_out = <$out> // '';
        close $out;
        waitpid($pid, 0);
        $exit_code = $? >> 8;
        1;
    };

    my @diags;
    for my $line (split(/\r?\n/, $raw_out)) {
        if ($line =~ /^\Q$tmpfile\E:(\d+)(?::(\d+))?:\s*(error|warning|note):\s*(.+)$/i
            || $line =~ /^.+?\.cbl:(\d+)(?::(\d+))?:\s*(error|warning|note):\s*(.+)$/i)
        {
            my ($ln, $col, $sev, $msg) = (int($1), defined($2) ? int($2) : 1, lc($3), $4);
            my $norm_sev = ($sev eq 'error') ? 'error' : ($sev eq 'warning' ? 'warn' : 'info');
            push @diags, {
                line     => $ln,
                col      => $col,
                severity => $norm_sev,
                code     => 'COBC_' . uc($sev),
                message  => $msg,
                source   => 'cobc',
            };
        }
    }

    return {
        available   => 1,
        path        => $cobc,
        version     => $ver,
        exit_code   => $exit_code,
        passed      => ($ok && $exit_code == 0) ? 1 : 0,
        raw_output  => $raw_out,
        diagnostics => \@diags,
    };
}

sub lint_compile {
    my ($self, %req) = @_;
    my $code     = $req{code} // '';
    my $is_free  = _is_free_source($code, $req{format});
    my $run_cobc = exists($req{run_cobc}) ? ($req{run_cobc} ? 1 : 0) : 1;

    my @lines = split(/\r?\n/, $code);
    my @static;

    # 1. Fixed-format column rules (cols 1-6, col 7 indicator, Area A 8-11, Area B 12-72, cols 73-80)
    if (!$is_free) {
        my $in_proc = 0;
        for (my $i = 0; $i < @lines; $i++) {
            my $raw = $lines[$i];
            my $ln  = $i + 1;
            next if $raw =~ /^\s*$/;

            if (length($raw) >= 7) {
                my $seq = substr($raw, 0, 6);
                my $ind = substr($raw, 6, 1);

                # Check col 7 indicator
                if ($ind !~ /^[ *\/\-Dd\$]$/) {
                    push @static, {
                        line     => $ln,
                        col      => 7,
                        severity => 'error',
                        code     => 'COBOL_COL7_INDICATOR',
                        message  => "Invalid fixed-format column-7 indicator '$ind' (expected space, '*', '/', '-', or 'D').",
                        source   => 'cobol',
                    };
                }
                next if $ind eq '*' || $ind eq '/';

                # Check sequence area cols 1-6 for stray COBOL keywords accidentally shifted left
                if ($seq =~ /[A-Za-z]/ && $seq !~ /^[0-9A-Za-z]{1,6}\s*$/i) {
                    push @static, {
                        line     => $ln,
                        col      => 1,
                        severity => 'warn',
                        code     => 'COBOL_SEQ_AREA',
                        message  => "Non-standard content '$seq' in fixed-format sequence area (columns 1-6).",
                        source   => 'cobol',
                    };
                }

                # Check code overflow past col 72 (cols 73-80 are identification area, ignored by compiler)
                if (length($raw) > 72) {
                    my $tail = substr($raw, 72);
                    if ($tail =~ /\S/ && $tail !~ /^[0-9A-Za-z_-]{1,8}\s*$/) {
                        push @static, {
                            line     => $ln,
                            col      => 73,
                            severity => 'warn',
                            code     => 'COBOL_COL72_OVERFLOW',
                            message  => "Code extends past column 72 into identification area (cols 73-80: '$tail'); fixed-format compilers truncate at col 72.",
                            source   => 'cobol',
                        };
                    }
                }

                my $area = length($raw) > 72 ? substr($raw, 7, 65) : substr($raw, 7);
                my $lead = ($area =~ /^(\s*)/) ? length($1) : 0;
                my $start_col = 8 + $lead;
                (my $trim = $area) =~ s/^\s+|\s+$//g;
                next unless length $trim;

                if ($trim =~ /^(?:IDENTIFICATION|ID|ENVIRONMENT|DATA|PROCEDURE)\s+DIVISION\b/i) {
                    $in_proc = ($trim =~ /^PROCEDURE\b/i) ? 1 : 0;
                    if ($start_col > 11) {
                        push @static, {
                            line     => $ln,
                            col      => $start_col,
                            severity => 'error',
                            code     => 'COBOL_AREA_A',
                            message  => "DIVISION header must start in Area A (columns 8-11), found at column $start_col.",
                            source   => 'cobol',
                        };
                    }
                }
                elsif ($trim =~ /^[A-Za-z0-9][A-Za-z0-9-]*\s+SECTION\b/i) {
                    if ($start_col > 11) {
                        push @static, {
                            line     => $ln,
                            col      => $start_col,
                            severity => 'error',
                            code     => 'COBOL_AREA_A',
                            message  => "SECTION header must start in Area A (columns 8-11), found at column $start_col.",
                            source   => 'cobol',
                        };
                    }
                }
                elsif (!$in_proc && $trim =~ /^(01|77|FD|SD)\b/i && $start_col > 11) {
                    push @static, {
                        line     => $ln,
                        col      => $start_col,
                        severity => 'warn',
                        code     => 'COBOL_AREA_A',
                        message  => "$1 declaration should start in Area A (columns 8-11), found at column $start_col.",
                        source   => 'cobol',
                    };
                }
                elsif ($in_proc && $start_col <= 11
                       && $trim =~ /^(?:MOVE|ADD|SUBTRACT|MULTIPLY|DIVIDE|COMPUTE|DISPLAY|PERFORM|IF|EVALUATE|CALL|STOP|GOBACK|READ|WRITE|OPEN|CLOSE|EXEC)\b/i)
                {
                    push @static, {
                        line     => $ln,
                        col      => $start_col,
                        severity => 'warn',
                        code     => 'COBOL_AREA_B',
                        message  => "Executable statement should start in Area B (columns 12-72), found in Area A (column $start_col).",
                        source   => 'cobol',
                    };
                }
            }
        }
    }

    # 2. Control-flow checks (undefined PERFORM targets & dead paragraphs)
    my $flow = $self->outline_flow($code, format => ($is_free ? 'free' : 'fixed'));
    for my $u (@{ $flow->{undefined_targets} || [] }) {
        push @static, {
            line     => $u->{line},
            col      => 12,
            severity => 'error',
            code     => 'COBOL_UNDEF_PERFORM',
            message  => "$u->{type} target '$u->{to}' is not defined as a paragraph or section.",
            source   => 'cobol',
        };
    }
    for my $dp (@{ $flow->{dead_paragraphs} || [] }) {
        push @static, {
            line     => $dp->{line},
            col      => 8,
            severity => 'warn',
            code     => 'COBOL_DEAD_PARAGRAPH',
            message  => "Paragraph '$dp->{name}' is never reached by PERFORM, GO TO, or initial entry.",
            source   => 'cobol',
        };
    }

    # 3. Safety checks: EVALUATE without WHEN OTHER, arithmetic ON SIZE ERROR, EXEC CICS RESP, EXEC SQL SQLCODE
    my @eval_stack;
    for (my $i = 0; $i < @lines; $i++) {
        my $area = _extract_cobol_code_area($lines[$i], $is_free);
        my $ln   = $i + 1;
        next unless $area =~ /\S/;

        if ($area =~ /\bEVALUATE\b/i) {
            push @eval_stack, { line => $ln, has_other => 0 };
        }
        if ($area =~ /\bWHEN\s+OTHER\b/i && @eval_stack) {
            $eval_stack[-1]{has_other} = 1;
        }
        if ($area =~ /\bEND-EVALUATE\b/i && @eval_stack) {
            my $ev = pop @eval_stack;
            if (!$ev->{has_other}) {
                push @static, {
                    line     => $ev->{line},
                    col      => 12,
                    severity => 'warn',
                    code     => 'COBOL_EVALUATE_NO_OTHER',
                    message  => "EVALUATE at line $ev->{line} has no WHEN OTHER clause.",
                    source   => 'cobol',
                };
            }
        }

        if ($area =~ /\b(?:DIVIDE|COMPUTE)\b/i && $area !~ /\bSIZE\s+ERROR\b/i) {
            my $next_area = ($i + 1 < @lines) ? _extract_cobol_code_area($lines[$i + 1], $is_free) : '';
            if ($next_area !~ /\bSIZE\s+ERROR\b/i) {
                push @static, {
                    line     => $ln,
                    col      => 12,
                    severity => 'hint',
                    code     => 'COBOL_NO_SIZE_ERROR',
                    message  => 'Arithmetic DIVIDE/COMPUTE without ON SIZE ERROR guard (division by zero or truncation can abend or silently lose high-order digits).',
                    source   => 'cobol',
                };
            }
        }
    }

    for my $cics (@{ $flow->{exec_cics} || [] }) {
        next if $cics->{body} =~ /\b(?:RETURN|ABEND|HANDLE|IGNORE)\b/i;
        if ($cics->{body} !~ /\bRESP\s*\(/i) {
            push @static, {
                line     => $cics->{start_line},
                col      => 12,
                severity => 'warn',
                code     => 'COBOL_CICS_NO_RESP',
                message  => 'EXEC CICS command without RESP(ws-resp) option; unhandled CICS conditions will abend the transaction.',
                source   => 'cobol',
            };
        }
    }

    if (@{ $flow->{exec_sql} || [] } && $code !~ /\b(?:SQLCODE|SQLSTATE)\b/i) {
        for my $sq (@{ $flow->{exec_sql} }) {
            next if $sq->{body} =~ /^\s*(?:INCLUDE|BEGIN\s+DECLARE|END\s+DECLARE|DECLARE\s+\S+\s+TABLE|DECLARE\s+\S+\s+CURSOR)\b/i;
            push @static, {
                line     => $sq->{start_line},
                col      => 12,
                severity => 'warn',
                code     => 'COBOL_SQL_NO_SQLCODE',
                message  => 'EXEC SQL statement found without any SQLCODE or SQLSTATE check in program.',
                source   => 'cobol',
            };
            last;
        }
    }

    # 4. Run live GnuCOBOL cobc -fsyntax-only -Wall if available and requested
    my $cobc_res = $run_cobc
        ? $self->_run_live_cobc($code, $is_free)
        : { available => ($self->find_cobc() ? 1 : 0), skipped => 1, diagnostics => [] };

    my @merged = (@static, @{ $cobc_res->{diagnostics} || [] });
    my $has_errors = (grep { ($_->{severity} // '') eq 'error' } @merged) ? 1 : 0;

    return {
        ok                 => $has_errors ? 0 : 1,
        format             => ($is_free ? 'free' : 'fixed'),
        cobc_available     => $cobc_res->{available} ? 1 : 0,
        cobc_path          => $cobc_res->{path},
        cobc_version       => $cobc_res->{version},
        cobc_exit          => $cobc_res->{exit_code},
        cobc_passed        => $cobc_res->{passed},
        raw_cobc_output    => $cobc_res->{raw_output} // '',
        static_diagnostics => \@static,
        cobc_diagnostics   => $cobc_res->{diagnostics} || [],
        diagnostics        => \@merged,
        diagnostic_count   => scalar(@merged),
    };
}

# --- LSP Knowledge Hooks ---

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef unless defined $word && length $word;
    my $up = uc($word);

    if (exists $CICS_COMMANDS{$up}) {
        my $c = $CICS_COMMANDS{$up};
        my $md = "### EXEC CICS `$up`\n\n"
               . "```cobol\n$c->{syntax}\n```\n\n"
               . "- **Category:** $c->{category}\n"
               . "- **EIB Fields:** " . join(', ', map { "`$_`" } @{ $c->{eib} }) . "\n\n"
               . "$c->{notes}\n";
        return { contents => $md, kind => 'markdown', title => "EXEC CICS $up" };
    }

    # Check two-word CICS commands like SEND MAP, RECEIVE MAP, HANDLE CONDITION
    if (defined $line) {
        for my $k (keys %CICS_COMMANDS) {
            next unless $k =~ /\s/;
            if ($line =~ /\b\Q$k\E\b/i && $k =~ /\b\Q$up\E\b/i) {
                my $c = $CICS_COMMANDS{$k};
                my $md = "### EXEC CICS `$k`\n\n```cobol\n$c->{syntax}\n```\n\n$c->{notes}\n";
                return { contents => $md, kind => 'markdown', title => "EXEC CICS $k" };
            }
        }
    }

    if (exists $SQLCA_FIELDS{$up}) {
        return {
            contents => "### EXEC SQL `SQLCA.$up`\n\n$SQLCA_FIELDS{$up}\n",
            kind     => 'markdown',
            title    => "SQLCA $up",
        };
    }

    my $sc_key = ($up eq '100') ? '+100' : $up;
    if (exists $SQLCODES{$sc_key}) {
        my $s = $SQLCODES{$sc_key};
        my $md = "### Db2 SQLCODE `$sc_key` (`SQLSTATE $s->{sqlstate}`)\n\n"
               . "- **Meaning:** $s->{meaning}\n"
               . "- **Action:** $s->{action}\n";
        return { contents => $md, kind => 'markdown', title => "SQLCODE $sc_key" };
    }

    if (exists $COBOL_KEYWORDS{$up}) {
        return {
            contents => "### COBOL `$up`\n\n$COBOL_KEYWORDS{$up}\n",
            kind     => 'markdown',
            title    => "COBOL $up",
        };
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $pfx = uc($prefix // '');
    my @items;

    for my $kw (sort keys %COBOL_KEYWORDS) {
        next if length($pfx) && index($kw, $pfx) != 0;
        push @items, {
            label         => $kw,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{keyword},
            detail        => 'COBOL Clause / Verb',
            documentation => $COBOL_KEYWORDS{$kw},
        };
    }

    for my $cmd (sort keys %CICS_COMMANDS) {
        next if length($pfx) && index($cmd, $pfx) != 0;
        my $c = $CICS_COMMANDS{$cmd};
        push @items, {
            label         => $cmd,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{function},
            detail        => "EXEC CICS $cmd ($c->{category})",
            documentation => "$c->{syntax} — $c->{notes}",
        };
    }

    for my $sf (sort keys %SQLCA_FIELDS) {
        next if length($pfx) && index($sf, $pfx) != 0;
        push @items, {
            label         => $sf,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{field},
            detail        => 'EXEC SQL SQLCA Field',
            documentation => $SQLCA_FIELDS{$sf},
        };
    }

    return \@items;
}

sub lsp_diagnostics {
    my ($self, $text, $lang) = @_;
    my $res = $self->lint_compile(code => $text, run_cobc => 1);
    my @diags;
    for my $d (@{ $res->{diagnostics} || [] }) {
        push @diags, $self->make_diagnostic(
            line     => ($d->{line} || 1) - 1,
            col      => ($d->{col}  || 1) - 1,
            end_col  => 72,
            severity => $d->{severity},
            code     => $d->{code},
            message  => $d->{message},
            source   => $d->{source} || 'cobol',
        );
    }
    return \@diags;
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    my $flow = $self->outline_flow($text);
    my $lay  = $self->pic_layout($text);
    my @syms;

    for my $d (@{ $flow->{divisions} || [] }) {
        push @syms, $self->make_symbol(
            name   => "$d->{name} DIVISION",
            kind   => 'module',
            line   => ($d->{line} || 1) - 1,
            detail => 'DIVISION',
        );
    }
    for my $s (@{ $flow->{sections} || [] }) {
        push @syms, $self->make_symbol(
            name   => "$s->{name} SECTION",
            kind   => 'namespace',
            line   => ($s->{line} || 1) - 1,
            detail => 'SECTION',
        );
    }
    for my $r (@{ $lay->{records} || [] }) {
        push @syms, $self->make_symbol(
            name   => $r->{name},
            kind   => 'struct',
            line   => ($r->{line} || 1) - 1,
            detail => sprintf('%02d record (%d bytes, %dB slack)', $r->{level}, $r->{total_bytes}, $r->{total_slack_bytes}),
        );
    }
    for my $p (@{ $flow->{paragraphs} || [] }) {
        push @syms, $self->make_symbol(
            name   => $p->{name},
            kind   => 'function',
            line   => ($p->{line} || 1) - 1,
            detail => 'PARAGRAPH',
        );
    }

    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::COBOL - Enterprise COBOL / ILE COBOL / GnuCOBOL MCP domain pack

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::COBOL;
    my $pack = NeoPerl::MCP::Pack::COBOL->new;
    my $lay  = $pack->call_tool('cobol_pic_layout',  { code => $copybook });
    my $chk  = $pack->call_tool('cobol_lint_compile', { code => $cobol_src });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::COBOL> provides a COBOL MCP domain pack and built-in LSP
provider inspired by Eclipse Che4z (C<che-che4z-lsp-for-cobol>), paired with
live GnuCOBOL C<cobc -fsyntax-only -Wall> compilation diagnostics whenever
C<cobc> is installed on the system.

=head1 TOOLS

=over 4

=item * C<cobol_pic_layout> - Computes exact byte offsets and storage lengths
for C<01>..C<49>/C<77>/C<88> records across C<DISPLAY>, C<COMP>/C<COMP-4>/C<BINARY>,
C<COMP-3>/C<PACKED-DECIMAL>, C<COMP-5>, C<COMP-1>, C<COMP-2>, C<SYNC> slack,
C<REDEFINES> overlay validation, and C<OCCURS [DEPENDING ON]>.

=item * C<cobol_outline_flow> - Extracts Divisions, Sections, Paragraphs,
C<PERFORM>/C<PERFORM THRU>/C<GO TO>/C<CALL> control flow, C<COPY ... REPLACING>,
C<EXEC SQL>, and C<EXEC CICS>.

=item * C<cobol_cics_sql_ref> - Complete C<EXEC CICS> command reference and
C<EXEC SQL> C<SQLCA>/C<SQLCODE> reference.

=item * C<cobol_lint_compile> - Fixed-format column rules (1-6, col 7, Area A
8-11, Area B 12-72, cols 73-80), dead paragraph and C<EVALUATE WHEN OTHER>
checks, plus live C<cobc -fsyntax-only -Wall> execution.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
