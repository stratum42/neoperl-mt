package NeoPerl::MCP::Pack::RPGILE;

use strict;
use warnings;
use parent 'NeoPerl::MCP::Pack';

our $VERSION = '0.01';

# IBM i ILE RPG Built-In Functions (%BIF) reference (55 functions)
my %BIFS = (
    '%TRIM' => {
        signature => '%TRIM(string {: characters_to_trim})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => 'V3R2',
        description => 'Removes leading and trailing blanks (or specified characters) from a character, UCS-2, or graphic string.',
        example   => "fullName = %TRIM(firstName) + ' ' + %TRIM(lastName);",
    },
    '%TRIMR' => {
        signature => '%TRIMR(string {: characters_to_trim})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => 'V3R2',
        description => 'Removes trailing blanks (or specified characters) from the right end of a string.',
        example   => "path = %TRIMR(dirPath : '/') + '/' + %TRIM(fileName);",
    },
    '%TRIML' => {
        signature => '%TRIML(string {: characters_to_trim})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => 'V3R2',
        description => 'Removes leading blanks (or specified characters) from the left end of a string.',
        example   => "acct = %TRIML(rawAcct : '0');",
    },
    '%SCAN' => {
        signature => '%SCAN(search_arg : source_string {: start_pos {: length}})',
        returns   => 'UNS(10)',
        category  => 'string',
        since     => 'V3R7',
        description => 'Returns the 1-based position of the first occurrence of search_arg in source_string, or 0 if not found.',
        example   => "pos = %SCAN('@' : emailAddr);",
    },
    '%SCANR' => {
        signature => '%SCANR(search_arg : source_string {: start_pos {: length}})',
        returns   => 'UNS(10)',
        category  => 'string',
        since     => '7.3',
        description => 'Scans right-to-left and returns the 1-based position of the last occurrence of search_arg, or 0 if not found.',
        example   => "slash = %SCANR('/' : ifsPath);",
    },
    '%SCANRPL' => {
        signature => '%SCANRPL(scan_string : replacement : source {: start_pos {: length}})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => '7.1',
        description => 'Scans source for all occurrences of scan_string and replaces each with replacement.',
        example   => "clean = %SCANRPL(',' : '' : amountText);",
    },
    '%SUBST' => {
        signature => '%SUBST(string : start {: length})',
        returns   => 'CHAR/VARCHAR (also valid on LHS of EVAL)',
        category  => 'string',
        since     => 'V3R2',
        description => 'Extracts (or overwrites on assignment LHS) a 1-based substring from a character, graphic, or UCS-2 field.',
        example   => "prefix = %SUBST(orderId : 1 : 4);",
    },
    '%REPLACE' => {
        signature => '%REPLACE(replacement : source {: start {: length}})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => 'V4R2',
        description => 'Replaces a slice of source starting at 1-based start for length characters with replacement.',
        example   => "out = %REPLACE('IBM' : msg : 1 : 3);",
    },
    '%LEN' => {
        signature => '%LEN(expression | *MAX)',
        returns   => 'UNS(10)',
        category  => 'size',
        since     => 'V4R2',
        description => 'Returns current length of a string (or digit count of numeric) or sets current length of a VARCHAR when on LHS.',
        example   => "n = %LEN(%TRIM(custName));",
    },
    '%SIZE' => {
        signature => '%SIZE(variable | literal | type {: *ALL})',
        returns   => 'UNS(10)',
        category  => 'size',
        since     => 'V3R1',
        description => 'Returns compile-time storage size in bytes (including 2/4-byte VARCHAR prefix; *ALL returns entire array byte size).',
        example   => "bufBytes = %SIZE(myDS : *ALL);",
    },
    '%ELEM' => {
        signature => '%ELEM(array | table | multi_occ_ds {: *MAX | *KEEP})',
        returns   => 'UNS(10)',
        category  => 'array',
        since     => 'V3R1',
        description => 'Returns number of elements in an array, table, or multiple-occurrence DS (or sets current size of DIM(*AUTO) array).',
        example   => "for i = 1 to %ELEM(items); ... endfor;",
    },
    '%CHAR' => {
        signature => '%CHAR(expression {: format | *JOBRUN})',
        returns   => 'VARCHAR',
        category  => 'conversion',
        since     => 'V4R4',
        description => 'Converts numeric, date, time, timestamp, graphic, or UCS-2 expressions to trimmed character representation.',
        example   => "msg = 'Order #' + %CHAR(orderNum) + ' on ' + %CHAR(ordDate : *ISO);",
    },
    '%DEC' => {
        signature => '%DEC(expression {: digits : decimals})',
        returns   => 'PACKED(digits:decimals)',
        category  => 'conversion',
        since     => 'V3R7',
        description => 'Converts character, numeric, date, time, or timestamp expression to packed decimal (truncates; wrap in MONITOR for invalid input).',
        example   => "amt = %DEC(rawAmount : 11 : 2);",
    },
    '%DECH' => {
        signature => '%DECH(expression : digits : decimals)',
        returns   => 'PACKED(digits:decimals)',
        category  => 'conversion',
        since     => 'V3R7',
        description => 'Converts expression to packed decimal with half-adjust rounding.',
        example   => "tax = %DECH(subTotal * taxRate : 9 : 2);",
    },
    '%INT' => {
        signature => '%INT(expression)',
        returns   => 'INT(20)',
        category  => 'conversion',
        since     => 'V3R7',
        description => 'Converts numeric or character expression to signed integer, truncating fractional digits.',
        example   => "count = %INT(qtyText);",
    },
    '%UNS' => {
        signature => '%UNS(expression)',
        returns   => 'UNS(20)',
        category  => 'conversion',
        since     => 'V3R7',
        description => 'Converts numeric or character expression to unsigned integer, truncating fractional digits.',
        example   => "idx = %UNS(rawOffset);",
    },
    '%EDITC' => {
        signature => '%EDITC(numeric : editcode {: *ASTFILL | *CURSYM | currency_sym})',
        returns   => 'CHAR',
        category  => 'formatting',
        since     => 'V3R7',
        description => 'Formats a numeric value using an RPG edit code (e.g. \'J\', \'K\', \'L\', \'X\' preserves leading zeros, \'Z\' zero-suppresses).',
        example   => "zipStr = %EDITC(zipNum : 'X');",
    },
    '%EDITW' => {
        signature => '%EDITW(numeric : editword)',
        returns   => 'CHAR',
        category  => 'formatting',
        since     => 'V3R7',
        description => 'Formats a numeric value according to a custom edit word mask.',
        example   => "phone = %EDITW(phoneNum : '(   )   -    ');",
    },
    '%ADDR' => {
        signature => '%ADDR(variable {: *DATA})',
        returns   => 'POINTER (16-byte tagged IBM i pointer)',
        category  => 'pointer',
        since     => 'V3R1',
        description => 'Returns the 16-byte IBM i MI tagged pointer to a variable (use *DATA on VARCHAR to point past the 2/4-byte length prefix).',
        example   => "pBuf = %ADDR(payload : *DATA);",
    },
    '%PADDR' => {
        signature => '%PADDR(procedure_name | prototype_name)',
        returns   => 'POINTER(*PROC)',
        category  => 'pointer',
        since     => 'V3R1',
        description => 'Returns a 16-byte procedure pointer suitable for callback registration or dynamic CALLP.',
        example   => "pCallback = %PADDR(onOrderEvent);",
    },
    '%ALLOC' => {
        signature => '%ALLOC(bytes)',
        returns   => 'POINTER',
        category  => 'memory',
        since     => 'V4R4',
        description => 'Allocates heap storage of the specified byte size and returns a 16-byte IBM i pointer; pair with DEALLOC(N).',
        example   => "pMem = %ALLOC(65536);",
    },
    '%REALLOC' => {
        signature => '%REALLOC(pointer : new_bytes)',
        returns   => 'POINTER',
        category  => 'memory',
        since     => 'V4R4',
        description => 'Resizes previously %ALLOC-allocated heap storage, preserving existing bytes up to min(old, new).',
        example   => "pMem = %REALLOC(pMem : bufLen * 2);",
    },
    '%LOOKUP' => {
        signature => '%LOOKUP(arg : array {: start_index {: num_elems}})',
        returns   => 'UNS(10)',
        category  => 'array',
        since     => 'V5R1',
        description => 'Searches an array (binary search if ASCEND/DESCEND specified) and returns 1-based matching index, or 0 if not found.',
        example   => "idx = %LOOKUP(sku : items(*).sku);",
    },
    '%SUBARR' => {
        signature => '%SUBARR(array : start_index {: num_elems})',
        returns   => 'Array slice',
        category  => 'array',
        since     => 'V5R3',
        description => 'Returns or assigns a contiguous slice of an array (essential with SORTA and %XFOOT on partially filled arrays).',
        example   => "sorta %SUBARR(codes : 1 : activeCount);",
    },
    '%SPLIT' => {
        signature => '%SPLIT(string {: separators {: *ALLSEP}})',
        returns   => 'Temporary VARCHAR array',
        category  => 'string',
        since     => '7.4',
        description => 'Splits a string into a temporary array of tokens delimited by separator characters (ideal with FOR-EACH).',
        example   => "for-each tok in %SPLIT(csvLine : ','); ... endfor;",
    },
    '%CONCAT' => {
        signature => '%CONCAT(separator : elem1 : elem2 {: ...})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => '7.5',
        description => 'Concatenates operands with a separator string between them (see also %CONCATARR for arrays).',
        example   => "line = %CONCAT(',' : id : name : status);",
    },
    '%LIST' => {
        signature => '%LIST(item1 {: item2 : ...})',
        returns   => 'Temporary array',
        category  => 'array',
        since     => '7.4',
        description => 'Constructs a temporary array inline for use with IN operator, FOR-EACH, or array assignment.',
        example   => "if status in %LIST('OPEN' : 'HOLD' : 'PEND');",
    },
    '%RANGE' => {
        signature => '%RANGE(lower_bound : upper_bound)',
        returns   => 'Range predicate (for IN operator)',
        category  => 'control',
        since     => '7.4',
        description => 'Defines an inclusive range [lower_bound, upper_bound] for use with the IN operator.',
        example   => "if statusCode in %RANGE(200 : 299);",
    },
    '%DATE' => {
        signature => '%DATE({expression {: format}})',
        returns   => 'DATE',
        category  => 'datetime',
        since     => 'V5R1',
        description => 'Returns current job date (when called with no arguments) or converts a numeric/char/timestamp value to DATE.',
        example   => "today = %DATE(); due = %DATE('2026-12-31' : *ISO);",
    },
    '%TIME' => {
        signature => '%TIME({expression {: format}})',
        returns   => 'TIME',
        category  => 'datetime',
        since     => 'V5R1',
        description => 'Returns current system time or converts a numeric/char/timestamp value to TIME.',
        example   => "nowTime = %TIME();",
    },
    '%TIMESTAMP' => {
        signature => '%TIMESTAMP({expression {: format | *UNIQUE}})',
        returns   => 'TIMESTAMP(6..12)',
        category  => 'datetime',
        since     => 'V5R1',
        description => 'Returns current system timestamp (or converts string to TIMESTAMP); pass *UNIQUE (7.3+) for strictly monotonic timestamps.',
        example   => "ts = %TIMESTAMP(*SYS : 6);",
    },
    '%DIFF' => {
        signature => '%DIFF(op1 : op2 : *MSECONDS|*SECONDS|*MINUTES|*HOURS|*DAYS|*MONTHS|*YEARS)',
        returns   => 'INT(20)',
        category  => 'datetime',
        since     => 'V5R1',
        description => 'Computes signed duration (op1 - op2) in the requested time unit.',
        example   => "ageDays = %DIFF(%DATE() : birthDate : *DAYS);",
    },
    '%DAYS' => {
        signature => '%DAYS(number)',
        returns   => 'Duration',
        category  => 'datetime',
        since     => 'V5R1',
        description => 'Converts an integer to a day duration for DATE/TIMESTAMP arithmetic (also %MONTHS, %YEARS, %SECONDS, %MSECONDS).',
        example   => "dueDate = %DATE() + %DAYS(30);",
    },
    '%FOUND' => {
        signature => '%FOUND({file_name})',
        returns   => 'IND (*ON/*OFF)',
        category  => 'io',
        since     => 'V4R2',
        description => 'Returns *ON if the most recent CHAIN, SETLL, DELETE, or CHECK found a matching record/value.',
        example   => "chain custKey CUSTMAST; if %FOUND(CUSTMAST); ... endif;",
    },
    '%EOF' => {
        signature => '%EOF({file_name})',
        returns   => 'IND (*ON/*OFF)',
        category  => 'io',
        since     => 'V4R2',
        description => 'Returns *ON when READ, READE, READP, or WRITE hits end-of-file (or subfile full).',
        example   => "dow not %EOF(ORDERS); read ORDERS; endfor;",
    },
    '%EQUAL' => {
        signature => '%EQUAL({file_name})',
        returns   => 'IND (*ON/*OFF)',
        category  => 'io',
        since     => 'V4R2',
        description => 'Returns *ON if SETLL found an exact key match or LOOKUP matched exactly.',
        example   => "setll key MYFILE; if %EQUAL(MYFILE); ... endif;",
    },
    '%ERROR' => {
        signature => '%ERROR()',
        returns   => 'IND (*ON/*OFF)',
        category  => 'error',
        since     => 'V4R2',
        description => 'Returns *ON if the most recent operation with the (E) error extender failed.',
        example   => "open(e) CUSTF; if %ERROR(); handleOpenErr(%STATUS(CUSTF)); endif;",
    },
    '%STATUS' => {
        signature => '%STATUS({file_name})',
        returns   => 'ZONED(5:0)',
        category  => 'error',
        since     => 'V4R2',
        description => 'Returns the 5-digit RPG program or file status code (00000 normal, 00100..01999 program/file errors, e.g. 00105 invalid numeric, 01218 record locked).',
        example   => "on-error; logStatus(%STATUS()); endmon;",
    },
    '%PARMS' => {
        signature => '%PARMS()',
        returns   => 'INT(10)',
        category  => 'procedure',
        since     => 'V3R2',
        description => 'Returns the number of parameters passed to the current program or subprocedure (check before accessing OPTIONS(*NOPASS) params).',
        example   => "if %PARMS() >= %PARMNUM(optFlag); useFlag = optFlag; endif;",
    },
    '%FIELDS' => {
        signature => '%FIELDS(field1 {: field2 : ...})',
        returns   => 'Field list (for UPDATE)',
        category  => 'io',
        since     => 'V5R2',
        description => 'Restricts an UPDATE opcode to modify only the explicitly listed record fields, reducing lock/audit impact.',
        example   => "update ORDREC %FIELDS(status : updatedAt);",
    },
    '%KDS' => {
        signature => '%KDS(key_ds {: num_keys})',
        returns   => 'Key list (for CHAIN/SETLL/READE/DELETE)',
        category  => 'io',
        since     => 'V5R2',
        description => 'Supplies a LIKEREC(*KEY) data structure as a composite search key for free-format keyed file I/O.',
        example   => "chain %KDS(ordKey : 2) ORDHDR;",
    },
    '%DATA' => {
        signature => '%DATA(document {: options})',
        returns   => 'Document descriptor (for DATA-INTO / DATA-GEN)',
        category  => 'serialization',
        since     => '7.3',
        description => 'Specifies the source/target JSON/CSV/YAML string or IFS file and parsing options (doc=file, case=any, allowextra=yes, countprefix=num_) for DATA-INTO / DATA-GEN.',
        example   => "data-into orderDS %DATA(jsonBuf : 'case=any allowextra=yes') %PARSER('YAJLINTO');",
    },
    '%PARSER' => {
        signature => '%PARSER(parser_pgm {: parser_options})',
        returns   => 'Parser descriptor (for DATA-INTO)',
        category  => 'serialization',
        since     => '7.3',
        description => 'Identifies the external parser program or procedure (such as YAJLINTO for JSON) used by DATA-INTO.',
        example   => "data-into payload %DATA(rawJson) %PARSER('YAJLINTO');",
    },
    '%HANDLER' => {
        signature => '%HANDLER(handling_proc : comm_area)',
        returns   => 'Streaming handler (for XML-INTO / DATA-INTO / XML-SAX)',
        category  => 'serialization',
        since     => 'V5R4',
        description => 'Streams large documents in chunks to a callback subprocedure rather than loading the entire array into memory.',
        example   => "data-into %HANDLER(onRow : ctx) %DATA(ifsPath : 'doc=file') %PARSER('YAJLINTO');",
    },
    '%XLATE' => {
        signature => '%XLATE(from_chars : to_chars : source {: start_pos})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => 'V5R1',
        description => 'Translates characters found in from_chars to corresponding characters in to_chars (such as case conversion or character filtering).',
        example   => "upper = %XLATE(LO : HI : inputName);",
    },
    '%CHECK' => {
        signature => '%CHECK(comparator : base {: start_pos})',
        returns   => 'UNS(10)',
        category  => 'string',
        since     => 'V5R1',
        description => 'Returns the 1-based position of the first character in base NOT present in comparator, or 0 if all characters are valid.',
        example   => "badPos = %CHECK('0123456789' : %TRIM(acctStr));",
    },
    '%CHECKR' => {
        signature => '%CHECKR(comparator : base {: start_pos})',
        returns   => 'UNS(10)',
        category  => 'string',
        since     => 'V5R1',
        description => 'Scans right-to-left for the first character in base NOT present in comparator.',
        example   => "lastNonZero = %CHECKR('0' : codeStr);",
    },
    '%OPEN' => {
        signature => '%OPEN(file_name)',
        returns   => 'IND (*ON/*OFF)',
        category  => 'io',
        since     => 'V4R4',
        description => 'Returns *ON if a USROPN file is currently open.',
        example   => "if not %OPEN(AUDITF); open AUDITF; endif;",
    },
    '%PROC' => {
        signature => '%PROC()',
        returns   => 'VARCHAR',
        category  => 'procedure',
        since     => '7.2',
        description => 'Returns the external name of the currently executing procedure (useful for structured logging and diagnostics).',
        example   => "logMsg(%PROC() + ': failed with SQLSTATE ' + SQLSTATE);",
    },
    '%STR' => {
        signature => '%STR(pointer {: max_length})',
        returns   => 'VARCHAR',
        category  => 'pointer',
        since     => 'V4R2',
        description => 'Reads or writes a null-terminated C string via a 16-byte IBM i pointer (for C/ILE API interop).',
        example   => "errText = %STR(strerror(errno));",
    },
    '%UPPER' => {
        signature => '%UPPER(string {: start {: length}})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => '7.4',
        description => 'Converts a string to uppercase using locale/CCSID-aware case folding.',
        example   => "stateCode = %UPPER(rawState);",
    },
    '%LOWER' => {
        signature => '%LOWER(string {: start {: length}})',
        returns   => 'VARCHAR',
        category  => 'string',
        since     => '7.4',
        description => 'Converts a string to lowercase using locale/CCSID-aware case folding.',
        example   => "email = %LOWER(%TRIM(rawEmail));",
    },
    '%MAX' => {
        signature => '%MAX(op1 : op2 {: ...})',
        returns   => 'Same type as operands',
        category  => 'math',
        since     => '7.3',
        description => 'Returns the largest of two or more comparable values.',
        example   => "cap = %MAX(minFee : calcFee);",
    },
    '%MIN' => {
        signature => '%MIN(op1 : op2 {: ...})',
        returns   => 'Same type as operands',
        category  => 'math',
        since     => '7.3',
        description => 'Returns the smallest of two or more comparable values.',
        example   => "chunk = %MIN(remaining : 4096);",
    },
    '%XFOOT' => {
        signature => '%XFOOT(numeric_array)',
        returns   => 'Numeric sum',
        category  => 'array',
        since     => 'V5R1',
        description => 'Sums all elements of a numeric array (combine with %SUBARR for partial arrays).',
        example   => "grandTotal = %XFOOT(%SUBARR(lineAmts : 1 : lineCnt));",
    },
);

my %KEYWORDS_DOC = (
    '**FREE'   => 'Fully free-format ILE RPG directive (must start in column 1 of line 1; removes 80-column limit and fixed spec columns).',
    'CTL-OPT'  => 'Control options header (free-format replacement for H-spec): DFTACTGRP(*NO), ACTGRP(*CALLER|*NEW|\'name\'), OPTION(*SRCSTMT:*NODEBUGIO), BNDDIR(...).',
    'DCL-F'    => 'File declaration (free-format replacement for F-spec): DISK, WORKSTN, PRINTER, USAGE(*INPUT:*OUTPUT:*UPDATE), KEYED, USROPN, QUALIFIED.',
    'DCL-S'    => 'Standalone variable declaration (free-format replacement for D-spec S).',
    'DCL-C'    => 'Named constant declaration (free-format replacement for D-spec C).',
    'DCL-DS'   => 'Data structure declaration (QUALIFIED, LIKEDS, DIM, TEMPLATE, EXTNAME, ALIGN, PSDS, INZ) closed by END-DS.',
    'DCL-PR'   => 'Procedure or program prototype declaration (EXTPGM, EXTPROC) closed by END-PR.',
    'DCL-PI'   => 'Procedure interface (parameter entry list) closed by END-PI.',
    'DCL-PROC' => 'Subprocedure definition (with optional EXPORT) closed by END-PROC.',
    'MONITOR'  => 'Structured exception-handling block paired with ON-ERROR and ENDMON.',
    'DATA-INTO' => 'Parses structured data (JSON/CSV/YAML via %PARSER) directly into an RPG data structure or %HANDLER.',
    'XML-INTO' => 'Parses XML documents directly into an RPG data structure or streaming %HANDLER.',
    'EXEC SQL' => 'Embedded Db2 for i SQL statement (requires .sqlrpgle CRTSQLRPGI precompiler; always inspect SQLSTATE or SQLCODE).',
    'POINTER'  => 'IBM i 16-byte MI tagged pointer (naturally 16-byte aligned; cannot be arbitrarily forged from integers).',
);

sub meta {
    return {
        name             => 'rpgile',
        label            => 'IBM i ILE RPG (**FREE & Fixed-Format)',
        category         => 'midrange',
        version          => $VERSION,
        description      => 'IBM i ILE RPG (**FREE & fixed-format H/F/D/I/C/O/P): 55+ %BIF reference, AST outline parser, exact DS storage/PACKED/ZONED/POINTER(16B)/OVERLAY layout calculator, modernization linter, and LSP hooks.',
        filetypes        => [qw(rpgile rpgle sqlrpgle rpg rpginc)],
        upstream_credits => [
            'codefori/vscode-rpgle (MIT)',
            'rpgle-linter (MIT)',
            'IBM i ILE RPG Reference',
        ],
    };
}

sub tools {
    my ($self) = @_;
    return [
        {
            name        => 'rpgile_bif_lookup',
            description => 'Look up IBM i ILE RPG built-in functions (%TRIM, %SCANRPL, %DEC, %ADDR, %LOOKUP, %SPLIT, %DATA/%PARSER/%HANDLER, %KDS, %DIFF, etc.) with signatures, return types, release level, and examples.',
            inputSchema => {
                type       => 'object',
                properties => {
                    name     => { type => 'string', description => 'BIF name with or without leading % (e.g. %SCANRPL, DEC, %LOOKUP).' },
                    query    => { type => 'string', description => 'Keyword search across BIF names, categories, and descriptions.' },
                    category => { type => 'string', description => 'Optional category filter (string, conversion, pointer, memory, array, datetime, io, error, serialization, formatting).' },
                },
            },
            handler => sub {
                my ($args) = @_;
                return $self->bif_lookup($args || {});
            },
        },
        {
            name        => 'rpgile_outline_ast',
            description => 'Parse both **FREE and fixed-format (H/F/D/I/C/O/P) ILE RPG source into a structured AST outline: CTL-OPT, DCL-F, DCL-S, DCL-C, DCL-DS (QUALIFIED/LIKEDS/DIM/TEMPLATE), DCL-PR, DCL-PI, DCL-PROC, /COPY, /INCLUDE, and EXEC SQL.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'ILE RPG source text (**FREE or fixed-format).' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->outline_ast($args->{code} // '');
            },
        },
        {
            name        => 'rpgile_ds_layout',
            description => 'Calculate exact byte offsets and IBM i storage lengths for RPGLE DCL-DS structures: PACKED(p:s), ZONED(p:s), INT/UNS(3|5|10|20), CHAR(n), VARCHAR(n:2|4), IND, 16-byte tagged POINTER, DATE/TIME/TIMESTAMP, DIM, POS(n), OVERLAY, and ALIGN slack.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'ILE RPG source containing DCL-DS ... END-DS or fixed D-spec DS definitions.' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->ds_layout($args->{code} // '');
            },
        },
        {
            name        => 'rpgile_lint',
            description => 'Lint ILE RPG source for **FREE modernization, CTL-OPT DFTACTGRP(*NO)/ACTGRP/OPTION(*SRCSTMT:*NODEBUGIO), MONITOR/ON-ERROR, legacy *IN01..*IN99 indicators, unclosed DCL-PROC/DCL-DS/MONITOR blocks, and EXEC SQL missing SQLSTATE check.',
            inputSchema => {
                type       => 'object',
                properties => {
                    code => { type => 'string', description => 'ILE RPG or SQLRPGLE source text to lint.' },
                },
                required => ['code'],
            },
            handler => sub {
                my ($args) = @_;
                return $self->lint($args->{code} // '');
            },
        },
    ];
}

# --- Tool 1: %BIF Lookup ---

sub bif_lookup {
    my ($self, $args) = @_;
    $args ||= {};
    my $name  = defined $args->{name}     ? uc($args->{name})     : '';
    my $query = defined $args->{query}    ? lc($args->{query})    : '';
    my $cat   = defined $args->{category} ? lc($args->{category}) : '';

    $name =~ s/^\s+|\s+$//g;
    if (length $name) {
        my $key = ($name =~ /^%/) ? $name : "%$name";
        if (exists $BIFS{$key}) {
            my $entry = { name => $key, %{ $BIFS{$key} } };
            return {
                ok           => 1,
                exact_match  => 1,
                count        => 1,
                bif          => $entry,
                matches      => [$entry],
                catalog_size => scalar(keys %BIFS),
            };
        }
    }

    my @matches;
    for my $k (sort keys %BIFS) {
        my $b = $BIFS{$k};
        if (length $name) {
            my $key = ($name =~ /^%/) ? $name : "%$name";
            next unless index($k, $key) == 0;
        }
        if (length $cat) {
            next unless lc($b->{category}) eq $cat;
        }
        if (length $query) {
            my $hay = lc("$k $b->{signature} $b->{returns} $b->{category} $b->{description} $b->{example}");
            next unless index($hay, $query) >= 0;
        }
        push @matches, { name => $k, %$b };
    }

    return {
        ok           => 1,
        exact_match  => 0,
        count        => scalar(@matches),
        bif          => (@matches == 1 ? $matches[0] : undef),
        matches      => \@matches,
        catalog_size => scalar(keys %BIFS),
    };
}

# --- Tool 2: AST Outline Parser (**FREE & Fixed-Format H/F/D/I/C/O/P) ---

sub outline_ast {
    my ($self, $code) = @_;
    my @lines = split(/\r?\n/, $code // '');

    my $is_free     = (@lines && $lines[0] =~ /^\*\*FREE\b/i) ? 1 : 0;
    my $in_free_blk = $is_free;
    my $has_fixed   = 0;

    my %ast = (
        is_free              => $is_free,
        has_fixed_specs      => 0,
        ctl_opt              => [],
        files                => [],
        constants            => [],
        standalones          => [],
        data_structures      => [],
        prototypes           => [],
        procedure_interfaces => [],
        procedures           => [],
        subroutines          => [],
        copies               => [],
        exec_sql             => [],
    );

    my $cur_ds;
    my $cur_proc;
    my $cur_pr;
    my $cur_pi;
    my $in_sql = 0;
    my $sql_buf = '';
    my $sql_start = 0;

    for (my $idx = 0; $idx < @lines; $idx++) {
        my $raw = $lines[$idx];
        my $ln  = $idx + 1;

        # Compiler directives (/COPY, /INCLUDE, /FREE, /END-FREE)
        if ($raw =~ m{^\s*/(COPY|INCLUDE)\s+(.+?)\s*$}i) {
            push @{ $ast{copies} }, { directive => uc($1), target => $2, line => $ln };
            next;
        }
        if ($raw =~ m{^\s*/FREE\b}i) {
            $in_free_blk = 1;
            next;
        }
        if ($raw =~ m{^\s*/END-FREE\b}i) {
            $in_free_blk = 0 unless $is_free;
            next;
        }

        # Fixed-format comment (col 7 = '*')
        if (!$in_free_blk && length($raw) >= 7 && substr($raw, 6, 1) eq '*') {
            next;
        }
        # Free-format line comment
        my $trim = $raw;
        $trim =~ s/^\s+//;
        next if !length($trim) || $trim =~ m{^//};

        # Strip inline // comments outside quotes
        (my $stmt = $trim) =~ s{\s*//.*$}{};

        # Multi-line EXEC SQL capture
        if ($in_sql) {
            $sql_buf .= ' ' . $stmt;
            if ($stmt =~ /;/ || $stmt =~ m{^\s*C/END-EXEC\b}i) {
                $sql_buf =~ s/^\s+|\s+$//g;
                push @{ $ast{exec_sql} }, { start_line => $sql_start, end_line => $ln, sql => $sql_buf };
                $in_sql = 0;
                $sql_buf = '';
            }
            next;
        }
        if ($stmt =~ /^(?:C\/)?EXEC\s+SQL\b(.*)$/i) {
            my $body = $1 // '';
            if ($body =~ /;/) {
                $body =~ s/^\s+|\s+$//g;
                push @{ $ast{exec_sql} }, { start_line => $ln, end_line => $ln, sql => $body };
            }
            else {
                $in_sql    = 1;
                $sql_start = $ln;
                $sql_buf   = $body;
            }
            next;
        }

        # Free-format declarations
        if ($stmt =~ /^CTL-OPT\b(.*?);?\s*$/i) {
            push @{ $ast{ctl_opt} }, { options => $1, line => $ln, format => 'free' };
            next;
        }
        if ($stmt =~ /^DCL-F\s+([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)(.*?);?\s*$/i) {
            push @{ $ast{files} }, { name => $1, keywords => $2, line => $ln, format => 'free' };
            next;
        }
        if ($stmt =~ /^DCL-C\s+([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)(.*?);?\s*$/i) {
            push @{ $ast{constants} }, { name => $1, value => $2, line => $ln, format => 'free' };
            next;
        }
        if ($stmt =~ /^DCL-S\s+([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)\s+(.*?);?\s*$/i) {
            push @{ $ast{standalones} }, { name => $1, definition => $2, line => $ln, format => 'free' };
            next;
        }
        if ($stmt =~ /^DCL-DS\s+([A-Za-z@#\$_*][A-Za-z0-9@#\$_]*)\b(.*)$/i) {
            my ($name, $rest) = ($1, $2);
            my $single_line = ($rest =~ /;\s*$/ && $rest =~ /\b(?:LIKEDS|LIKEREC|EXTNAME)\s*\(/i) ? 1 : 0;
            my $likeds = ($rest =~ /\bLIKEDS\(([^)]+)\)/i) ? $1 : undef;
            my $dim    = ($rest =~ /\bDIM\(([^)]+)\)/i)    ? $1 : undef;
            my $ds = {
                name       => $name,
                line       => $ln,
                end_line   => $single_line ? $ln : undef,
                format     => 'free',
                qualified  => ($rest =~ /\bQUALIFIED\b/i) ? 1 : 0,
                template   => ($rest =~ /\bTEMPLATE\b/i)  ? 1 : 0,
                align      => ($rest =~ /\bALIGN\b/i)     ? 1 : 0,
                psds       => ($rest =~ /\bPSDS\b/i)      ? 1 : 0,
                likeds     => $likeds,
                dim        => $dim,
                keywords   => $rest,
                subfields  => [],
            };
            push @{ $ast{data_structures} }, $ds;
            $cur_ds = $single_line ? undef : $ds;
            next;
        }
        if ($stmt =~ /^END-DS\b/i) {
            if ($cur_ds) {
                $cur_ds->{end_line} = $ln;
                $cur_ds = undef;
            }
            next;
        }
        if ($stmt =~ /^DCL-PR\s+([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)(.*)$/i) {
            my $pr = { name => $1, signature => $2, line => $ln, end_line => undef, params => [] };
            push @{ $ast{prototypes} }, $pr;
            $cur_pr = $pr;
            next;
        }
        if ($stmt =~ /^END-PR\b/i) {
            $cur_pr->{end_line} = $ln if $cur_pr;
            $cur_pr = undef;
            next;
        }
        if ($stmt =~ /^DCL-PI\s+([A-Za-z@#\$_*][A-Za-z0-9@#\$_]*)(.*)$/i) {
            my $pi = { name => $1, signature => $2, line => $ln, end_line => undef, params => [] };
            push @{ $ast{procedure_interfaces} }, $pi;
            $cur_pi = $pi;
            next;
        }
        if ($stmt =~ /^END-PI\b/i) {
            $cur_pi->{end_line} = $ln if $cur_pi;
            $cur_pi = undef;
            next;
        }
        if ($stmt =~ /^DCL-PROC\s+([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)(.*)$/i) {
            my ($pname, $prest) = ($1, $2);
            my $proc = {
                name       => $pname,
                export     => ($prest =~ /\bEXPORT\b/i) ? 1 : 0,
                line       => $ln,
                end_line   => undef,
                format     => 'free',
            };
            push @{ $ast{procedures} }, $proc;
            $cur_proc = $proc;
            next;
        }
        if ($stmt =~ /^END-PROC\b/i) {
            $cur_proc->{end_line} = $ln if $cur_proc;
            $cur_proc = undef;
            next;
        }
        if ($stmt =~ /^BEGSR\s+([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)/i) {
            push @{ $ast{subroutines} }, { name => $1, line => $ln };
            next;
        }

        # Subfield / parameter inside open free-format DCL-DS / DCL-PR / DCL-PI
        if ($in_free_blk && $cur_ds && $stmt =~ /^(?:DCL-SUBF\s+)?([A-Za-z@#\$_*][A-Za-z0-9@#\$_]*)\s+(.+?);?\s*$/i) {
            push @{ $cur_ds->{subfields} }, { name => $1, definition => $2, line => $ln };
            next;
        }
        if ($in_free_blk && $cur_pr && $stmt =~ /^(?:DCL-PARM\s+)?([A-Za-z@#\$_*][A-Za-z0-9@#\$_]*)\s+(.+?);?\s*$/i) {
            push @{ $cur_pr->{params} }, { name => $1, definition => $2, line => $ln };
            next;
        }
        if ($in_free_blk && $cur_pi && $stmt =~ /^(?:DCL-PARM\s+)?([A-Za-z@#\$_*][A-Za-z0-9@#\$_]*)\s+(.+?);?\s*$/i) {
            push @{ $cur_pi->{params} }, { name => $1, definition => $2, line => $ln };
            next;
        }

        # Fixed-format H / F / D / I / C / O / P specs (col 6 = index 5)
        if (!$in_free_blk && length($raw) >= 6) {
            my $spec = uc(substr($raw, 5, 1));
            if ($spec =~ /^[HFDICOP]$/) {
                $has_fixed = 1;
                my $body = length($raw) > 6 ? substr($raw, 6) : '';
                if ($spec eq 'H') {
                    push @{ $ast{ctl_opt} }, { options => $body, line => $ln, format => 'fixed' };
                }
                elsif ($spec eq 'F') {
                    my $fname = substr($raw . (' ' x 16), 6, 10);
                    $fname =~ s/^\s+|\s+$//g;
                    push @{ $ast{files} }, { name => $fname, keywords => $body, line => $ln, format => 'fixed' }
                        if length $fname;
                }
                elsif ($spec eq 'D') {
                    my $dname = substr($raw . (' ' x 26), 6, 15);
                    $dname =~ s/^\s+|\s+$//g;
                    my $dtype = uc(substr($raw . (' ' x 30), 23, 2));
                    $dtype =~ s/^\s+|\s+$//g;
                    my $kws = length($raw) > 43 ? substr($raw, 43) : '';
                    if ($dtype eq 'DS') {
                        my $likeds = ($kws =~ /\bLIKEDS\(([^)]+)\)/i) ? $1 : undef;
                        my $dim    = ($kws =~ /\bDIM\(([^)]+)\)/i)    ? $1 : undef;
                        my $ds = {
                            name      => $dname || '*N',
                            line      => $ln,
                            format    => 'fixed',
                            qualified => ($kws =~ /\bQUALIFIED\b/i) ? 1 : 0,
                            template  => ($kws =~ /\bTEMPLATE\b/i)  ? 1 : 0,
                            align     => ($kws =~ /\bALIGN\b/i)     ? 1 : 0,
                            likeds    => $likeds,
                            dim       => $dim,
                            keywords  => $kws,
                            subfields => [],
                        };
                        push @{ $ast{data_structures} }, $ds;
                        $cur_ds = $ds;
                    }
                    elsif ($dtype eq 'S') {
                        $cur_ds = undef;
                        push @{ $ast{standalones} }, { name => $dname, definition => $body, line => $ln, format => 'fixed' };
                    }
                    elsif ($dtype eq 'C') {
                        $cur_ds = undef;
                        push @{ $ast{constants} }, { name => $dname, value => $kws, line => $ln, format => 'fixed' };
                    }
                    elsif ($dtype eq 'PR') {
                        $cur_ds = undef;
                        push @{ $ast{prototypes} }, { name => $dname, signature => $kws, line => $ln, format => 'fixed', params => [] };
                    }
                    elsif ($dtype eq 'PI') {
                        $cur_ds = undef;
                        push @{ $ast{procedure_interfaces} }, { name => $dname, signature => $kws, line => $ln, format => 'fixed', params => [] };
                    }
                    elsif ($dtype eq '' && $cur_ds && length $dname) {
                        push @{ $cur_ds->{subfields} }, { name => $dname, definition => $body, line => $ln, format => 'fixed' };
                    }
                }
                elsif ($spec eq 'P') {
                    $cur_ds = undef;
                    my $pname = substr($raw . (' ' x 26), 6, 15);
                    $pname =~ s/^\s+|\s+$//g;
                    my $be = uc(substr($raw . (' ' x 26), 23, 1));
                    if ($be eq 'B' && length $pname) {
                        my $p = { name => $pname, export => ($raw =~ /\bEXPORT\b/i ? 1 : 0), line => $ln, end_line => undef, format => 'fixed' };
                        push @{ $ast{procedures} }, $p;
                        $cur_proc = $p;
                    }
                    elsif ($be eq 'E' && $cur_proc) {
                        $cur_proc->{end_line} = $ln;
                        $cur_proc = undef;
                    }
                }
            }
        }
    }

    $ast{has_fixed_specs} = $has_fixed;
    $ast{ok} = 1;
    return \%ast;
}

# --- Tool 3: Exact IBM i RPGLE Data Structure Storage Layout ---

sub _rpg_type_bytes {
    my ($def) = @_;
    $def //= '';

    if ($def =~ /\bPACKED\s*\(\s*(\d+)(?:\s*:\s*(\d+))?\s*\)/i) {
        my ($p, $s) = (int($1), defined($2) ? int($2) : 0);
        return (int($p / 2) + 1, 1, "PACKED($p:$s)");
    }
    if ($def =~ /\bZONED\s*\(\s*(\d+)(?:\s*:\s*(\d+))?\s*\)/i) {
        my ($p, $s) = (int($1), defined($2) ? int($2) : 0);
        return ($p, 1, "ZONED($p:$s)");
    }
    if ($def =~ /\b(INT|UNS)\s*\(\s*(\d+)\s*\)/i) {
        my ($kind, $d) = (uc($1), int($2));
        my $sz = ($d <= 3) ? 1 : ($d <= 5) ? 2 : ($d <= 10) ? 4 : 8;
        return ($sz, $sz, "$kind($d)");
    }
    if ($def =~ /\bBINDEC\s*\(\s*(\d+)(?:\s*:\s*(\d+))?\s*\)/i) {
        my ($p, $s) = (int($1), defined($2) ? int($2) : 0);
        return (($p <= 4 ? 2 : 4), 1, "BINDEC($p:$s)");
    }
    if ($def =~ /\bFLOAT\s*\(\s*(\d+)\s*\)/i) {
        my $sz = int($1) == 4 ? 4 : 8;
        return ($sz, $sz, "FLOAT($sz)");
    }
    if ($def =~ /\bVARCHAR\s*\(\s*(\d+)(?:\s*:\s*(\d+))?\s*\)/i) {
        my $n   = int($1);
        my $pfx = defined($2) ? int($2) : ($n > 65535 ? 4 : 2);
        return ($n + $pfx, 1, "VARCHAR($n:$pfx)");
    }
    if ($def =~ /\bCHAR\s*\(\s*(\d+)\s*\)/i) {
        my $n = int($1);
        return ($n, 1, "CHAR($n)");
    }
    if ($def =~ /\bVAR(?:UCS2|GRAPH)\s*\(\s*(\d+)(?:\s*:\s*(\d+))?\s*\)/i) {
        my $n   = int($1);
        my $pfx = defined($2) ? int($2) : ($n > 65535 ? 4 : 2);
        return ($n * 2 + $pfx, 2, "VARUCS2($n:$pfx)");
    }
    if ($def =~ /\b(UCS2|GRAPH)\s*\(\s*(\d+)\s*\)/i) {
        my ($k, $n) = (uc($1), int($2));
        return ($n * 2, 2, "$k($n)");
    }
    if ($def =~ /\bPOINTER\b/i) {
        # IBM i 16-byte MI tagged pointer, 16-byte aligned
        return (16, 16, 'POINTER');
    }
    if ($def =~ /\bIND\b/i) {
        return (1, 1, 'IND');
    }
    if ($def =~ /\bTIMESTAMP(?:\s*\(\s*(\d+)\s*\))?/i) {
        my $prec = defined($1) ? int($1) : 6;
        my $sz   = ($prec == 0) ? 19 : (20 + $prec);
        return ($sz, 1, "TIMESTAMP($prec)");
    }
    if ($def =~ /\bDATE(?:\s*\(\s*(\*[A-Z0-9]+)\s*\))?/i) {
        my $fmt = uc($1 // '*ISO');
        my $sz  = ($fmt =~ /^\*(?:MDY|DMY|YMD)$/) ? 8 : ($fmt eq '*JUL' ? 6 : 10);
        return ($sz, 1, "DATE($fmt)");
    }
    if ($def =~ /\bTIME\b/i) {
        return (8, 1, 'TIME');
    }
    # Fixed-format shorthand e.g. 9P 2, 10A, 10I 0, 5U 0, * (pointer)
    if ($def =~ /(\d+)\s*([PASIBUFGDZT*])\s*(\d*)/i) {
        my ($len, $code, $dec) = (int($1), uc($2), $3);
        return (int($len / 2) + 1, 1, "PACKED($len:" . ($dec || 0) . ')') if $code eq 'P';
        return ($len, 1, "ZONED($len:" . ($dec || 0) . ')')               if $code eq 'S';
        return ($len, 1, "CHAR($len)")                                    if $code eq 'A';
        if ($code eq 'I' || $code eq 'U') {
            my $sz = ($len <= 3) ? 1 : ($len <= 5) ? 2 : ($len <= 10) ? 4 : 8;
            return ($sz, $sz, ($code eq 'I' ? 'INT' : 'UNS') . "($len)");
        }
        return (16, 16, 'POINTER') if $code eq '*';
        return (1, 1, 'IND')       if $code eq 'N';
    }
    return (0, 1, 'UNKNOWN');
}

sub ds_layout {
    my ($self, $code) = @_;
    my $ast = $self->outline_ast($code);
    my @layouts;

    for my $ds (@{ $ast->{data_structures} || [] }) {
        my $ds_align   = $ds->{align} ? 1 : 0;
        my $cursor     = 0;
        my $high_water = 0;
        my $total_slack = 0;
        my %field_pos;         # uc(name) => { offset => ..., bytes => ..., next => ... }
        my @fields;
        my @warnings;

        $field_pos{ uc($ds->{name}) } = { offset => 0, bytes => 0, next => 0 };

        for my $sf (@{ $ds->{subfields} || [] }) {
            my $def = $sf->{definition} // '';
            my ($elem_bytes, $nat_align, $type_str) = _rpg_type_bytes($def);
            my $dim = 1;
            if ($def =~ /\bDIM\s*\(\s*(\d+)\s*\)/i) {
                $dim = int($1);
            }
            my $total_bytes = $elem_bytes * $dim;

            my $offset;
            my $slack = 0;
            my $overlay_target;

            if ($def =~ /\bPOS\s*\(\s*(\d+)\s*\)/i) {
                $offset = int($1) - 1;
                $offset = 0 if $offset < 0;
            }
            elsif ($def =~ /\bOVERLAY\s*\(\s*([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)(?:\s*:\s*(\*NEXT|\d+))?\s*\)/i) {
                my ($tgt, $ov_pos) = (uc($1), $2);
                $overlay_target = $1;
                my $base = $field_pos{$tgt} || { offset => 0, bytes => 0, next => 0 };
                if (!defined $ov_pos) {
                    $offset = $base->{offset};
                }
                elsif (uc($ov_pos) eq '*NEXT') {
                    $offset = $base->{offset} + $base->{next};
                }
                else {
                    $offset = $base->{offset} + (int($ov_pos) - 1);
                }
                $base->{next} = ($offset - $base->{offset}) + $total_bytes;
                $field_pos{$tgt} = $base;
            }
            else {
                # IBM i POINTERs are always 16-byte aligned; other numerics align only with ALIGN on DS
                my $eff_align = ($type_str eq 'POINTER') ? 16 : ($ds_align ? $nat_align : 1);
                if ($eff_align > 1 && ($cursor % $eff_align) != 0) {
                    $slack = $eff_align - ($cursor % $eff_align);
                }
                $offset = $cursor + $slack;
                $total_slack += $slack;
                $cursor = $offset + $total_bytes;
            }

            if ($type_str eq 'POINTER' && ($offset % 16) != 0) {
                push @warnings, "Subfield '$sf->{name}' is an IBM i 16-byte tagged POINTER placed at non-16-byte-aligned offset $offset (POS(" . ($offset + 1) . ")); runtime pointer alignment error will occur.";
            }

            my $end_off = $offset + $total_bytes;
            $high_water = $end_off if $end_off > $high_water;
            $cursor     = $end_off if !defined($overlay_target) && $end_off > $cursor;

            $field_pos{ uc($sf->{name}) } = {
                offset => $offset,
                bytes  => $total_bytes,
                next   => 0,
            };

            push @fields, {
                name           => $sf->{name},
                type           => $type_str,
                offset         => $offset,
                pos_1based     => $offset + 1,
                elem_bytes     => $elem_bytes,
                dim            => $dim,
                total_bytes    => $total_bytes,
                end_offset     => $end_off,
                slack_bytes    => $slack,
                overlay_target => $overlay_target,
                line           => $sf->{line},
            };
        }

        my $ds_dim = ($ds->{dim} && $ds->{dim} =~ /^(\d+)$/) ? int($1) : 1;
        push @layouts, {
            name              => $ds->{name},
            qualified         => $ds->{qualified},
            template          => $ds->{template},
            aligned           => $ds_align,
            dim               => $ds_dim,
            element_size      => $high_water,
            total_size        => $high_water * $ds_dim,
            total_slack_bytes => $total_slack,
            fields            => \@fields,
            warnings          => \@warnings,
            line              => $ds->{line},
        };
    }

    return {
        ok              => 1,
        ds_count        => scalar(@layouts),
        data_structures => \@layouts,
    };
}

# --- Tool 4: ILE RPG Modernization & Safety Linter ---

sub lint {
    my ($self, $code) = @_;
    my @lines = split(/\r?\n/, $code // '');
    my $ast   = $self->outline_ast($code);
    my @findings;

    # 1. **FREE modernization check
    if (!$ast->{is_free}) {
        push @findings, {
            line     => 1,
            severity => 'info',
            code     => 'RPG_USE_FREE',
            message  => 'Source does not begin with **FREE in column 1; consider modernizing to fully free-format ILE RPG (**FREE).',
        };
    }

    # 2. CTL-OPT best practices (DFTACTGRP(*NO), ACTGRP, OPTION(*SRCSTMT:*NODEBUGIO))
    my $all_ctl = join(' ', map { $_->{options} // '' } @{ $ast->{ctl_opt} || [] });
    if (@{ $ast->{procedures} || [] } && $all_ctl !~ /\bDFTACTGRP\s*\(\s*\*NO\s*\)/i) {
        push @findings, {
            line     => (@{ $ast->{ctl_opt} || [] } ? $ast->{ctl_opt}[0]{line} : 1),
            severity => 'error',
            code     => 'RPG_DFTACTGRP_NO',
            message  => 'Subprocedures (DCL-PROC) are present but CTL-OPT DFTACTGRP(*NO) is missing (required for ILE compilation).',
        };
    }
    if ($all_ctl !~ /\bACTGRP\s*\(/i) {
        push @findings, {
            line     => (@{ $ast->{ctl_opt} || [] } ? $ast->{ctl_opt}[0]{line} : 1),
            severity => 'info',
            code     => 'RPG_CTLOPT_ACTGRP',
            message  => 'Consider specifying ACTGRP(*NEW | *CALLER | \'name\') in CTL-OPT for predictable IBM i activation group lifecycle.',
        };
    }
    if ($all_ctl !~ /\bOPTION\s*\([^)]*\*SRCSTMT/i || $all_ctl !~ /\bOPTION\s*\([^)]*\*NODEBUGIO/i) {
        push @findings, {
            line     => (@{ $ast->{ctl_opt} || [] } ? $ast->{ctl_opt}[0]{line} : 1),
            severity => 'hint',
            code     => 'RPG_CTLOPT_OPTION',
            message  => 'Recommended CTL-OPT OPTION(*SRCSTMT : *NODEBUGIO) for accurate line numbers in stack traces and cleaner stepping.',
        };
    }

    # 3. Line-by-line block balance, legacy indicators, deprecated opcodes, MONITOR/ON-ERROR, EXEC SQL
    my @proc_stack;
    my @ds_stack;
    my @mon_stack;
    my $has_sql_check = ($code =~ /\bSQLSTATE\b|\bSQLCOD(?:E)?\b/i) ? 1 : 0;

    my %deprecated = (
        MOVE  => 'EVAL / %CHAR / %DEC / %SUBST',
        MOVEL => 'EVAL / %SUBST',
        'Z-ADD' => 'EVAL target = value',
        GOTO  => 'structured IF/DOW/ITER/LEAVE/RETURN',
        CABEQ => 'IF ... ; ... ; ENDIF',
        SETON => 'named IND variables or *INLR = *ON',
    );

    for (my $idx = 0; $idx < @lines; $idx++) {
        my $raw = $lines[$idx];
        my $ln  = $idx + 1;
        next if $raw =~ m{^\s*//} || (!$ast->{is_free} && length($raw) >= 7 && substr($raw, 6, 1) eq '*');

        (my $clean = $raw) =~ s{//.*$}{};

        # Legacy numbered indicators *IN01 .. *IN99
        while ($clean =~ /(\*IN(?:0[1-9]|[1-9][0-9]))\b/gi) {
            push @findings, {
                line     => $ln,
                severity => 'warn',
                code     => 'RPG_LEGACY_INDICATOR',
                message  => "Legacy numbered indicator $1 used; replace with descriptive named IND variables or %FOUND/%EOF/%EQUAL.",
            };
        }

        # Block tracking: DCL-PROC / END-PROC
        if ($clean =~ /^\s*DCL-PROC\s+([A-Za-z@#\$_][A-Za-z0-9@#\$_]*)/i) {
            push @proc_stack, { name => $1, line => $ln };
        }
        elsif ($clean =~ /^\s*END-PROC\b/i) {
            if (@proc_stack) {
                pop @proc_stack;
            }
            else {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'RPG_STRAY_ENDPROC',
                    message  => 'END-PROC without matching DCL-PROC.',
                };
            }
        }

        # Block tracking: DCL-DS / END-DS (skip single-line LIKEDS/LIKEREC/EXTNAME)
        if ($clean =~ /^\s*DCL-DS\s+([A-Za-z@#\$_*][A-Za-z0-9@#\$_]*)(.*)$/i) {
            my ($n, $rest) = ($1, $2);
            unless ($rest =~ /;\s*$/ && $rest =~ /\b(?:LIKEDS|LIKEREC|EXTNAME)\s*\(/i) {
                push @ds_stack, { name => $n, line => $ln };
            }
        }
        elsif ($clean =~ /^\s*END-DS\b/i) {
            pop @ds_stack if @ds_stack;
        }

        # Block tracking: MONITOR / ON-ERROR / ENDMON
        if ($clean =~ /^\s*MONITOR\s*;/i) {
            push @mon_stack, { line => $ln, has_on_error => 0 };
        }
        elsif ($clean =~ /^\s*ON-ERROR\b/i) {
            if (@mon_stack) {
                $mon_stack[-1]{has_on_error} = 1;
            }
            else {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'RPG_STRAY_ONERROR',
                    message  => 'ON-ERROR outside of a MONITOR block.',
                };
            }
        }
        elsif ($clean =~ /^\s*ENDMON\b/i) {
            if (@mon_stack) {
                my $m = pop @mon_stack;
                if (!$m->{has_on_error}) {
                    push @findings, {
                        line     => $m->{line},
                        severity => 'error',
                        code     => 'RPG_MONITOR_NO_ONERROR',
                        message  => "MONITOR block opened at line $m->{line} has no ON-ERROR clause before ENDMON.",
                    };
                }
            }
            else {
                push @findings, {
                    line     => $ln,
                    severity => 'error',
                    code     => 'RPG_STRAY_ENDMON',
                    message  => 'ENDMON without matching MONITOR.',
                };
            }
        }

        # Deprecated opcodes
        if ($clean =~ /^\s*(?:C\s+\S*\s+)?(MOVE|MOVEL|Z-ADD|GOTO|CABEQ|SETON)\b/i) {
            my $op = uc($1);
            push @findings, {
                line     => $ln,
                severity => 'warn',
                code     => 'RPG_DEPRECATED_OPCODE',
                message  => "Legacy opcode $op is not supported in **FREE RPG; modernize with $deprecated{$op}.",
            };
        }
    }

    for my $p (@proc_stack) {
        push @findings, {
            line     => $p->{line},
            severity => 'error',
            code     => 'RPG_UNCLOSED_PROC',
            message  => "DCL-PROC $p->{name} opened at line $p->{line} is missing a closing END-PROC.",
        };
    }
    for my $d (@ds_stack) {
        push @findings, {
            line     => $d->{line},
            severity => 'error',
            code     => 'RPG_UNCLOSED_DS',
            message  => "DCL-DS $d->{name} opened at line $d->{line} is missing a closing END-DS.",
        };
    }
    for my $m (@mon_stack) {
        push @findings, {
            line     => $m->{line},
            severity => 'error',
            code     => 'RPG_UNCLOSED_MONITOR',
            message  => "MONITOR block opened at line $m->{line} is missing ENDMON.",
        };
    }

    # 4. EXEC SQL missing SQLSTATE check
    if (@{ $ast->{exec_sql} || [] } && !$has_sql_check) {
        for my $sq (@{ $ast->{exec_sql} }) {
            next if $sq->{sql} =~ /^\s*(?:SET\s+OPTION|INCLUDE|DECLARE\s+\S+\s+CURSOR)\b/i;
            push @findings, {
                line     => $sq->{start_line},
                severity => 'warn',
                code     => 'RPG_EXEC_SQL_NO_SQLSTATE',
                message  => 'EXEC SQL statement detected without any SQLSTATE (or SQLCODE) check in this module; inspect SQLSTATE (e.g. %SUBST(SQLSTATE:1:2) <> \'00\').',
            };
            last;
        }
    }

    # 5. Pointer alignment warnings from DS layout
    my $lay = $self->ds_layout($code);
    for my $ds (@{ $lay->{data_structures} || [] }) {
        for my $w (@{ $ds->{warnings} || [] }) {
            push @findings, {
                line     => $ds->{line},
                severity => 'error',
                code     => 'RPG_POINTER_ALIGN',
                message  => $w,
            };
        }
    }

    return {
        ok            => (grep { $_->{severity} eq 'error' } @findings) ? 0 : 1,
        is_free       => $ast->{is_free},
        finding_count => scalar(@findings),
        findings      => \@findings,
    };
}

# --- LSP Knowledge Hooks ---

sub lsp_hover {
    my ($self, $word, $line, $lang) = @_;
    return undef unless defined $word && length $word;
    my $up = uc($word);

    my $bif_key = ($up =~ /^%/) ? $up : "%$up";
    if (exists $BIFS{$bif_key} && ($up =~ /^%/ || (defined $line && $line =~ /%\Q$word\E\b/i))) {
        my $b = $BIFS{$bif_key};
        my $md = "### ILE RPG `$bif_key`\n\n"
               . "- **Signature:** `$b->{signature}`\n"
               . "- **Returns:** `$b->{returns}` (IBM i $b->{since}+)\n\n"
               . "$b->{description}\n\n"
               . "```rpgle\n$b->{example}\n```\n";
        return { contents => $md, kind => 'markdown', title => "RPGLE $bif_key" };
    }

    if (exists $BIFS{$up}) {
        my $b = $BIFS{$up};
        my $md = "### ILE RPG `$up`\n\n- **Signature:** `$b->{signature}`\n- **Returns:** `$b->{returns}`\n\n$b->{description}\n";
        return { contents => $md, kind => 'markdown', title => "RPGLE $up" };
    }

    if (exists $KEYWORDS_DOC{$up}) {
        return {
            contents => "### ILE RPG `$up`\n\n$KEYWORDS_DOC{$up}\n",
            kind     => 'markdown',
            title    => "RPGLE $up",
        };
    }

    return undef;
}

sub lsp_completions {
    my ($self, $prefix, $line, $lang) = @_;
    my $pfx = uc($prefix // '');
    my @items;

    for my $k (sort keys %BIFS) {
        if (length $pfx) {
            my $bare = substr($k, 1);
            next unless index($k, $pfx) == 0 || index($bare, $pfx) == 0;
        }
        my $b = $BIFS{$k};
        push @items, {
            label         => $k,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{function},
            detail        => "$b->{signature} -> $b->{returns}",
            documentation => "$b->{description} Example: $b->{example}",
        };
    }

    for my $kw (sort keys %KEYWORDS_DOC) {
        next if length($pfx) && index($kw, $pfx) != 0;
        push @items, {
            label         => $kw,
            kind          => $NeoPerl::MCP::Pack::COMPLETION_KIND{keyword},
            detail        => 'ILE RPG Keyword',
            documentation => $KEYWORDS_DOC{$kw},
        };
    }

    return \@items;
}

sub lsp_diagnostics {
    my ($self, $text, $lang) = @_;
    my $res = $self->lint($text);
    my @diags;
    for my $f (@{ $res->{findings} || [] }) {
        push @diags, $self->make_diagnostic(
            line     => ($f->{line} || 1) - 1,
            col      => 0,
            end_col  => 80,
            severity => $f->{severity},
            code     => $f->{code},
            message  => $f->{message},
            source   => 'rpgile',
        );
    }
    return \@diags;
}

sub lsp_symbols {
    my ($self, $text, $lang) = @_;
    my $ast = $self->outline_ast($text);
    my @syms;

    for my $p (@{ $ast->{procedures} || [] }) {
        push @syms, $self->make_symbol(
            name     => $p->{name},
            kind     => 'function',
            line     => ($p->{line} || 1) - 1,
            end_line => (($p->{end_line} || $p->{line}) - 1),
            detail   => 'DCL-PROC' . ($p->{export} ? ' EXPORT' : ''),
        );
    }
    for my $ds (@{ $ast->{data_structures} || [] }) {
        push @syms, $self->make_symbol(
            name     => $ds->{name},
            kind     => 'struct',
            line     => ($ds->{line} || 1) - 1,
            end_line => (($ds->{end_line} || $ds->{line}) - 1),
            detail   => 'DCL-DS' . ($ds->{qualified} ? ' QUALIFIED' : '') . ($ds->{template} ? ' TEMPLATE' : ''),
        );
    }
    for my $f (@{ $ast->{files} || [] }) {
        push @syms, $self->make_symbol(
            name   => $f->{name},
            kind   => 'file',
            line   => ($f->{line} || 1) - 1,
            detail => 'DCL-F',
        );
    }
    for my $pr (@{ $ast->{prototypes} || [] }) {
        push @syms, $self->make_symbol(
            name   => $pr->{name},
            kind   => 'interface',
            line   => ($pr->{line} || 1) - 1,
            detail => 'DCL-PR',
        );
    }
    for my $s (@{ $ast->{standalones} || [] }) {
        push @syms, $self->make_symbol(
            name   => $s->{name},
            kind   => 'variable',
            line   => ($s->{line} || 1) - 1,
            detail => "DCL-S $s->{definition}",
        );
    }
    for my $c (@{ $ast->{constants} || [] }) {
        push @syms, $self->make_symbol(
            name   => $c->{name},
            kind   => 'constant',
            line   => ($c->{line} || 1) - 1,
            detail => 'DCL-C',
        );
    }
    for my $sr (@{ $ast->{subroutines} || [] }) {
        push @syms, $self->make_symbol(
            name   => $sr->{name},
            kind   => 'method',
            line   => ($sr->{line} || 1) - 1,
            detail => 'BEGSR',
        );
    }

    return \@syms;
}

1;

__END__

=head1 NAME

NeoPerl::MCP::Pack::RPGILE - IBM i ILE RPG (**FREE and fixed-format) MCP domain pack

=head1 SYNOPSIS

    use NeoPerl::MCP::Pack::RPGILE;
    my $pack = NeoPerl::MCP::Pack::RPGILE->new;
    my $bif  = $pack->call_tool('rpgile_bif_lookup', { name => '%SCANRPL' });
    my $lay  = $pack->call_tool('rpgile_ds_layout',  { code => $rpg_src });

=head1 DESCRIPTION

C<NeoPerl::MCP::Pack::RPGILE> provides an IBM i ILE RPG MCP domain pack and
built-in LSP provider inspired by C<codefori/vscode-rpgle> and
C<rpgle-linter>, supporting both modern C<**FREE> source and legacy
fixed-format H/F/D/I/C/O/P specifications.

=head1 TOOLS

=over 4

=item * C<rpgile_bif_lookup> - Reference database of 55 ILE RPG C<%BIF>
functions with signatures, return types, IBM i release levels, and examples.

=item * C<rpgile_outline_ast> - Parses C<**FREE> and fixed-format declarations
(C<CTL-OPT>, C<DCL-F>, C<DCL-S>, C<DCL-C>, C<DCL-DS>, C<DCL-PR>, C<DCL-PI>,
C<DCL-PROC>, C</COPY>, C</INCLUDE>, and C<EXEC SQL>).

=item * C<rpgile_ds_layout> - Computes exact byte offsets and IBM i storage
lengths including C<PACKED(p:s)>, C<ZONED(p:s)>, C<INT>/C<UNS>, C<VARCHAR>,
16-byte tagged C<POINTER>, C<POS(n)>, C<OVERLAY>, and C<ALIGN> slack.

=item * C<rpgile_lint> - Checks C<**FREE> modernization, C<DFTACTGRP(*NO)>,
C<MONITOR>/C<ON-ERROR>, legacy C<*IN01..*IN99> indicators, unclosed blocks,
and C<EXEC SQL> C<SQLSTATE> verification.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

NeoPerl::MT is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License or GNU General Public License).

=cut
