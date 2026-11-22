/*
 * c/syntax.c - Incremental 27-language line-state lexer & symbol extractor
 *
 * Strictly unsigned-char clean (safe on ppc64le where plain char is unsigned).
 */
#include "syntax.h"

#include <stdlib.h>
#include <string.h>

struct npl_syntax {
    npl_lang_t lang;
    uint8_t   *states;
    size_t     state_count;
    size_t     state_cap;
    size_t     dirty_from;
    size_t     last_relex_lines;
};

/* Unsigned-char-safe ASCII character helpers (no locale dependence) */
static inline int npl_is_space(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}
static inline int npl_is_digit(unsigned char c) {
    return c >= '0' && c <= '9';
}
static inline int npl_is_xdigit(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
static inline int npl_is_alpha(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
static inline int npl_is_ident_start(unsigned char c) {
    return npl_is_alpha(c) || c == '_';
}
static inline int npl_is_ident_cont(unsigned char c) {
    return npl_is_alpha(c) || npl_is_digit(c) || c == '_';
}
static inline unsigned char npl_tolower(unsigned char c) {
    return (c >= 'A' && c <= 'Z') ? (unsigned char)(c + ('a' - 'A')) : c;
}

static int
ascii_ieq(const char *a, const char *b)
{
    if (!a || !b) return 0;
    while (*a && *b) {
        if (npl_tolower((unsigned char)*a) != npl_tolower((unsigned char)*b)) return 0;
        a++;
        b++;
    }
    return *a == '\0' && *b == '\0';
}

static int
word_in_list(const char *w, size_t len, const char *const *list)
{
    for (size_t i = 0; list[i] != NULL; i++) {
        const char *kw = list[i];
        if (strlen(kw) == len && memcmp(w, kw, len) == 0) {
            return 1;
        }
    }
    return 0;
}

static int
word_in_list_ci(const char *w, size_t len, const char *const *list)
{
    for (size_t i = 0; list[i] != NULL; i++) {
        const char *kw = list[i];
        size_t j = 0;
        while (j < len && kw[j] != '\0') {
            if (npl_tolower((unsigned char)w[j]) != npl_tolower((unsigned char)kw[j])) {
                break;
            }
            j++;
        }
        if (j == len && kw[j] == '\0') {
            return 1;
        }
    }
    return 0;
}

static int
starts_with_ci(const char *s, size_t len, const char *prefix)
{
    size_t plen = strlen(prefix);
    if (len < plen) return 0;
    for (size_t i = 0; i < plen; i++) {
        if (npl_tolower((unsigned char)s[i]) != npl_tolower((unsigned char)prefix[i])) {
            return 0;
        }
    }
    return 1;
}

static const char *const KW_PERL[] = {
    "my", "our", "local", "state", "sub", "package", "use", "require", "no",
    "if", "elsif", "else", "unless", "while", "until", "for", "foreach",
    "do", "eval", "return", "next", "last", "redo", "goto", "die", "warn",
    "print", "say", "open", "close", "defined", "undef", "ref", "bless",
    "shift", "unshift", "push", "pop", "splice", "map", "grep", "sort",
    "keys", "values", "each", "exists", "delete", "scalar", "wantarray",
    "BEGIN", "END", "INIT", "CHECK", "UNITCHECK", "and", "or", "not", "eq",
    "ne", "lt", "gt", "le", "ge", "cmp", "qw", "qr", "qq", "q", "qx", "try", "catch",
    NULL
};

static const char *const KW_C[] = {
    "auto", "break", "case", "const", "continue", "default", "do", "else",
    "enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
    "return", "sizeof", "static", "struct", "switch", "typedef", "union",
    "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Generic",
    "_Noreturn", "_Static_assert", "_Thread_local", NULL
};

static const char *const TYPE_C[] = {
    "void", "char", "short", "int", "long", "float", "double", "signed",
    "unsigned", "bool", "_Bool", "size_t", "ssize_t", "ptrdiff_t", "intptr_t",
    "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
    "uint16_t", "uint32_t", "uint64_t", "FILE", "SV", "AV", "HV", "CV",
    "IV", "UV", "NV", "STRLEN", "SSize_t", "pTHX", "pTHX_", "aTHX", "aTHX_",
    NULL
};

static const char *const KW_CPP[] = {
    "alignas", "alignof", "auto", "break", "case", "catch", "class", "const",
    "constexpr", "const_cast", "continue", "decltype", "default", "delete",
    "do", "dynamic_cast", "else", "enum", "explicit", "export", "extern",
    "false", "for", "friend", "goto", "if", "inline", "mutable", "namespace",
    "new", "noexcept", "nullptr", "operator", "private", "protected", "public",
    "reinterpret_cast", "return", "sizeof", "static", "static_assert",
    "static_cast", "struct", "switch", "template", "this", "throw", "true",
    "try", "typedef", "typeid", "typename", "union", "using", "virtual",
    "volatile", "while", "override", "final", NULL
};

static const char *const KW_XS_SECT[] = {
    "MODULE", "PACKAGE", "PREFIX", "PROTOTYPES", "CODE", "PPCODE", "INIT",
    "PREINIT", "POSTCALL", "OUTPUT", "CLEANUP", "BOOT", "ALIAS", "INTERFACE",
    "CASE", "C_ARGS", "NO_INIT", "IN", "OUT", "IN_OUT", "RETVAL", "THIS",
    "INCLUDE", "REQUIRE", "FALLBACK", NULL
};

static const char *const KW_RUST[] = {
    "as", "async", "await", "break", "const", "continue", "crate", "dyn",
    "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
    "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
    "self", "Self", "static", "struct", "super", "trait", "true", "type",
    "unsafe", "use", "where", "while", NULL
};

static const char *const TYPE_RUST[] = {
    "bool", "char", "str", "i8", "i16", "i32", "i64", "i128", "isize",
    "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
    "Option", "Result", "Vec", "String", "Box", "Rc", "Arc", NULL
};

static const char *const KW_GO[] = {
    "break", "case", "chan", "const", "continue", "default", "defer", "else",
    "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
    "map", "package", "range", "return", "select", "struct", "switch", "type",
    "var", "true", "false", "nil", "iota", NULL
};

static const char *const TYPE_GO[] = {
    "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
    "int", "int8", "int16", "int32", "int64", "rune", "string", "uint",
    "uint8", "uint16", "uint32", "uint64", "uintptr", "any", NULL
};

static const char *const KW_PYTHON[] = {
    "False", "None", "True", "and", "as", "assert", "async", "await", "break",
    "class", "continue", "def", "del", "elif", "else", "except", "finally",
    "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
    "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    "match", "case", NULL
};

static const char *const KW_JS[] = {
    "async", "await", "break", "case", "catch", "class", "const", "continue",
    "debugger", "default", "delete", "do", "else", "export", "extends",
    "false", "finally", "for", "from", "function", "get", "if", "import",
    "in", "instanceof", "let", "new", "null", "of", "return", "set", "static",
    "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
    "var", "void", "while", "with", "yield", NULL
};

static const char *const KW_TS_EXTRA[] = {
    "abstract", "as", "declare", "enum", "implements", "interface", "keyof",
    "namespace", "private", "protected", "public", "readonly", "type",
    "unknown", "never", "any", "string", "number", "boolean", "bigint",
    NULL
};

static const char *const KW_LUA[] = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while", NULL
};

static const char *const KW_SH[] = {
    "if", "then", "else", "elif", "fi", "case", "esac", "for", "in", "do",
    "done", "while", "until", "function", "return", "exit", "local", "export",
    "unset", "readonly", "shift", "set", "trap", "exec", "eval", "source",
    "break", "continue", "true", "false", NULL
};

static const char *const KW_TCL[] = {
    "proc", "set", "unset", "global", "variable", "upvar", "uplevel", "if",
    "elseif", "else", "while", "for", "foreach", "switch", "break", "continue",
    "return", "catch", "try", "finally", "namespace", "package", "source",
    "expr", "list", "lindex", "llength", "lappend", "dict", "array", "puts",
    "eval", "apply", "incr", "append", "format", "regexp", "regsub", NULL
};

static const char *const KW_MAKE[] = {
    "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "-include",
    "define", "endef", "export", "unexport", "override", "vpath", NULL
};

static const char *const KW_SQL[] = {
    "select", "from", "where", "join", "inner", "left", "right", "full",
    "outer", "cross", "on", "as", "and", "or", "not", "in", "is", "null",
    "between", "like", "exists", "case", "when", "then", "else", "end",
    "group", "by", "having", "order", "asc", "desc", "limit", "offset",
    "fetch", "first", "next", "rows", "only", "with", "ur", "cs", "rs", "rr",
    "optimize", "for", "union", "all", "distinct", "insert", "into", "values",
    "update", "set", "delete", "merge", "using", "matched", "create", "alter",
    "drop", "replace", "table", "view", "index", "unique", "primary", "key",
    "foreign", "references", "constraint", "default", "check", "procedure",
    "function", "trigger", "schema", "database", "tablespace", "bufferpool",
    "grant", "revoke", "commit", "rollback", "begin", "declare", "cursor",
    "open", "close", "return", "returning", "resume", "define", "let",
    "foreach", "while", "loop", "if", "elif", "elseif", "endif", "exception",
    "raise", "call", "exec", "execute", "explain", "plan", "organize",
    "column", "row", "lock", "mode", "isolation", "statistics", "high",
    "medium", "low", "fragment", "partition", "bind", "package", "system",
    "volatile", "deterministic", "specific", "language", "sql", "reads",
    "modifies", "data", "dynamic", "result", "sets", "out", "inout", "temp",
    "temporary", "cascade", "restrict", "generated", "always", "identity",
    NULL
};

static const char *const TYPE_SQL[] = {
    "int", "integer", "smallint", "bigint", "decimal", "dec", "numeric",
    "real", "float", "double", "precision", "char", "character", "varchar",
    "vargraphic", "graphic", "clob", "dbclob", "blob", "binary", "varbinary",
    "date", "time", "timestamp", "datetime", "interval", "boolean", "bool",
    "serial", "bigserial", "serial8", "lvarchar", "money", "smallfloat",
    "text", "byte", "vector", "int8", "float32", "float64", "xml", "json",
    NULL
};

static const char *const KW_HLASM_DIR[] = {
    "csect", "dsect", "rsect", "loctr", "using", "drop", "equ", "ds", "dc",
    "org", "ltorg", "entry", "extrn", "wxtrn", "end", "title", "eject",
    "space", "print", "push", "pop", "amode", "rmode", "sysstate", "copy",
    "macro", "mend", "mexit", "mnote", "aif", "ago", "anop", "actr", "gbla",
    "gblb", "gblc", "lcla", "lclb", "lclc", "seta", "setb", "setc", "cnop",
    "ccw", "ccw0", "ccw1", "start", "com", "cattr", "xattr", "alias", "punch",
    "repro", "opsyn", "ictl", "iseq", "process", "acontrol", NULL
};

static const char *const KW_HLASM_OP[] = {
    "l", "lr", "la", "lay", "larl", "lg", "lgr", "lgf", "lgfr", "lgh", "lghi",
    "lhi", "lh", "lm", "lmg", "ly", "llgf", "llgt", "llgh", "llgc", "st",
    "stg", "sth", "stc", "stm", "stmg", "sty", "mvc", "mvcl", "mvcle", "mvi",
    "mviy", "clc", "clcl", "cli", "cliy", "clg", "clgr", "clfi", "cfi", "c",
    "cr", "cg", "cgr", "chi", "cghi", "ch", "a", "ar", "ag", "agr", "ahi",
    "aghi", "al", "alr", "alg", "algr", "s", "sr", "sg", "sgr", "sl", "slr",
    "slg", "slgr", "m", "mr", "ms", "msr", "msg", "msgr", "d", "dr", "dsg",
    "dsgr", "n", "nr", "ng", "ngr", "ni", "o", "or", "og", "ogr", "oi", "x",
    "xr", "xg", "xgr", "xi", "sll", "srl", "sra", "sllg", "srlg", "srag",
    "rll", "rllg", "b", "br", "bc", "bcr", "brc", "brcl", "bas", "basr",
    "bal", "balr", "bras", "brasl", "bct", "bctr", "bctg", "bctgr", "brct",
    "brctg", "bxh", "bxle", "be", "bne", "bh", "bl", "bnh", "bnl", "bz",
    "bnz", "bo", "bm", "bp", "j", "je", "jne", "jh", "jl", "jz", "jnz",
    "nop", "nopr", "ex", "exrl", "cs", "csg", "cds", "cdsg", "laa", "laag",
    "ts", "svc", "pc", "pr", "bakr", "sac", "sacf", "sam31", "sam64", "lae",
    "ear", "sar", "cpya", "stck", "stcke", "stckf", "vl", "vst", "vlm",
    "vstm", "vlr", "vzero", "vone", "vfa", "vfs", "vfm", "vfma", "vfms",
    "vperm", "vceq", "vsel", "va", "vs", "nnpa", "dfltcc", "kma", "km",
    "kmc", "kimd", "klmd", "kmac", "pcc", "sortl", "pack", "unpk", "zap",
    "ap", "sp", "mp", "dp", "cp", "ed", "edmk", "tr", "trt", "cvb", "cvd",
    "cvbg", "cvdg", "wto", "abend", "getmain", "freemain", "storage", "save",
    "return", "call", "link", "xctl", "load", "delete", "dcb", "open",
    "close", "get", "put", "read", "write", NULL
};

static const char *const KW_ASM_OP[] = {
    /* POWER8+/9/10 */
    "add", "addi", "addis", "subf", "mullw", "mulld", "divd", "ld", "lwz",
    "lhz", "lbz", "std", "stw", "sth", "stb", "stdu", "ldu", "mr", "li",
    "lis", "ori", "oris", "andi", "rldicl", "rldicr", "cmpd", "cmpdi", "cmpw",
    "cmpwi", "b", "bl", "blr", "bctr", "bctrl", "beq", "bne", "blt", "bgt",
    "ble", "bge", "bdnz", "mflr", "mtlr", "mtctr", "mfctr", "sync", "lwsync",
    "isync", "eieio", "lwarx", "stwcx", "ldarx", "stdcx", "lxvd2x", "stxvd2x",
    "lxv", "stxv", "lxvx", "stxvx", "xxlor", "xxlxor", "xxland", "xxpermdi",
    "xvmaddasp", "xvmaddadp", "xvmaddmsp", "xvmaddmdp", "xvaddsp", "xvadddp",
    "xvmulsp", "xvmuldp", "xvsubsp", "xvsubdp", "xxsldwi", "vaddfp",
    "vmaddfp", "vperm", "xxsetaccz", "xvf32gerpp", "xvf32ger", "xvbf16ger2pp",
    "xxmfacc", "xxmtacc", "pld", "pstd", "pli", "paddi", "nop",
    /* amd64 */
    "mov", "movq", "movl", "movw", "movb", "movzx", "movsx", "movsxd", "lea",
    "leaq", "push", "pushq", "pop", "popq", "addq", "addl", "sub", "subq",
    "subl", "imul", "mul", "idiv", "div", "inc", "dec", "neg", "and", "or",
    "xor", "xorl", "xorq", "not", "shl", "shr", "sar", "rol", "ror", "cmp",
    "cmpq", "cmpl", "test", "testq", "jmp", "je", "jne", "jz", "jnz", "jg",
    "jge", "jl", "jle", "ja", "jae", "jb", "jbe", "call", "callq", "ret",
    "retq", "syscall", "cmovz", "cmovnz", "cmovg", "cmovl", "mfence",
    "lfence", "sfence", "pause", "lock", "xchg", "cmpxchg", "movaps",
    "movups", "movdqa", "movdqu", "vmovaps", "vmovups", "vmovdqu",
    "vmovdqa64", "vaddps", "vaddpd", "vmulps", "vmulpd", "vfmadd231ps",
    "vfmadd231pd", "vfmadd132ps", "vpaddd", "vpxor", "vpxord", "vbroadcastss",
    "vpermps", "vzeroupper", "tdpbf16ps", "tdpbssd", "tileloadd", "tilestored",
    "tilerelease", "ldtilecfg", "pdep", "pext", "tzcnt", "lzcnt", "popcnt",
    "rdtsc", "cpuid",
    /* arm64 */
    "ldr", "ldp", "str", "stp", "ldrb", "strb", "ldrh", "strh", "ldxr",
    "stxr", "ldaxr", "stlxr", "ldaddal", "casal", "adr", "adrp", "movz",
    "movk", "movn", "adds", "subs", "madd", "msub", "udiv", "sdiv", "lsl",
    "lsr", "asr", "orr", "eor", "bic", "mvn", "tst", "cbz", "cbnz", "tbz",
    "tbnz", "svc", "dmb", "dsb", "isb", "yield", "wfe", "wfi", "ld1", "st1",
    "fadd", "fsub", "fmul", "fdiv", "fmla", "fmls", "fmadd", "fmax", "fmin",
    "dup", "ins", "umov", "tbl", "zip1", "zip2", "uzp1", "uzp2", "whilelt",
    "whilelo", "ptrue", "ld1w", "st1w", "cntw", "incw",
    /* s390x (incl. Telum / Telum II) */
    "lg", "lgr", "lghi", "lgfi", "larl", "lay", "stg", "lmg", "stmg", "agr",
    "ag", "aghi", "sgr", "sg", "msgr", "cgr", "cghi", "clgr", "brasl", "br",
    "bc", "bcr", "brc", "brcl", "jg", "jh", "j", "cs", "csg", "cdsg", "laa",
    "laag", "vl", "vst", "vlm", "vstm", "vlr", "vzero", "vfa", "vfs", "vfm",
    "vfma", "vfms", "vfmasb", "vfmadb", "vceqb", "vsel", "nnpa", "dfltcc",
    "kma", "kimd", "klmd", "sortl", "exrl", "mvc", "clc", "stcke", NULL
};

static const char *const KW_ASM_DIR[] = {
    "section", "global", "extern", "bits", "db", "dw", "dd", "dq", "equ",
    "resb", "resw", "resd", "resq", "align", "macro", "endm", NULL
};

static const char *const KW_RPGILE[] = {
    "ctl-opt", "dcl-f", "dcl-s", "dcl-c", "dcl-ds", "end-ds", "dcl-subf",
    "dcl-pr", "end-pr", "dcl-pi", "end-pi", "dcl-proc", "end-proc",
    "dcl-parm", "begsr", "endsr", "exsr", "if", "else", "elseif", "endif",
    "select", "when", "other", "endsl", "dow", "dou", "for", "enddo",
    "endfor", "iter", "leave", "return", "monitor", "on-error", "endmon",
    "on-exit", "eval", "evalr", "clear", "reset", "sorta", "chain", "read",
    "reade", "readp", "readpe", "setll", "setgt", "write", "update",
    "delete", "exfmt", "open", "close", "callp", "data-into", "data-gen",
    "xml-into", "xml-sax", "exec", "sql", "end-exec", "export", "import",
    "static", "const", "value", "options", "extproc", "extpgm", "qualified",
    "likeds", "like", "dim", "template", "inz", "based", "pos", "overlay",
    "prefix", "extname", "disk", "workstn", "printer", "usage", "keyed",
    "dftactgrp", "actgrp", "bnddir", "option", "main", "nomain", "thread",
    "ccsid", "commit", "declare", "cursor", "fetch", "into", "from", "where",
    "and", "or", "not", "to", "by", "downto", "in", NULL
};

static const char *const TYPE_RPGILE[] = {
    "char", "varchar", "ucs2", "varucs2", "graph", "vargraph", "packed",
    "zoned", "bindec", "int", "uns", "float", "ind", "pointer", "date",
    "time", "timestamp", "object", NULL
};

static const char *const KW_COBOL[] = {
    "identification", "environment", "data", "procedure", "division",
    "section", "program-id", "author", "configuration", "input-output",
    "file-control", "select", "assign", "organization", "access", "file",
    "working-storage", "local-storage", "linkage", "fd", "sd", "rd", "copy",
    "replacing", "exec", "sql", "cics", "end-exec", "include", "declare",
    "table", "cursor", "open", "close", "read", "write", "rewrite", "delete",
    "start", "move", "to", "compute", "add", "subtract", "multiply",
    "divide", "giving", "remainder", "rounded", "on", "size", "error", "if",
    "then", "else", "end-if", "evaluate", "when", "other", "end-evaluate",
    "perform", "thru", "through", "until", "varying", "from", "by", "times",
    "end-perform", "call", "using", "reference", "content", "value",
    "returning", "end-call", "go", "goback", "stop", "run", "exit",
    "program", "paragraph", "display", "accept", "string", "unstring",
    "inspect", "tallying", "initialize", "set", "search", "all", "at", "end",
    "end-search", "sort", "merge", "release", "return", "not", "and", "or",
    "equal", "greater", "less", "than", "zero", "zeros", "zeroes", "space",
    "spaces", "high-value", "high-values", "low-value", "low-values", "true",
    "false", "filler", "redefines", "occurs", "depending", "indexed", "key",
    "ascending", "descending", "renames", "values", "is", "are", "of", "in",
    "with", "no", "advancing", "into", "where", "fetch", "commit",
    "rollback", "link", "xctl", "send", "map", "receive", "syncpoint",
    "resp", "resp2", "commarea", "sqlca", "sqlcode", "sqlstate", NULL
};

static const char *const TYPE_COBOL[] = {
    "pic", "picture", "usage", "comp", "comp-1", "comp-2", "comp-3",
    "comp-4", "comp-5", "computational", "computational-1",
    "computational-2", "computational-3", "computational-4",
    "computational-5", "binary", "packed-decimal", "pointer", "index",
    "sync", "synchronized", "sign", "leading", "trailing", "separate",
    "justified", "blank", "national", "utf-8", NULL
};

static const char *const KW_SYCL[] = {
    "__kernel", "kernel", "__global", "global", "__local", "local",
    "__constant", "constant", "__private", "private", "__read_only",
    "read_only", "__write_only", "write_only", "__attribute__",
    "reqd_sub_group_size", "reqd_work_group_size",
    "intel_reqd_sub_group_size", "parallel_for", "single_task", "submit",
    "handler", "queue", "device", "context", "buffer", "accessor",
    "local_accessor", "nd_range", "nd_item", "sub_group", "group_barrier",
    "joint_matrix", "joint_matrix_mad", "joint_matrix_load",
    "joint_matrix_store", "barrier", "mem_fence", "work_group_barrier",
    "sub_group_barrier", NULL
};

static const char *const TYPE_SYCL[] = {
    "float2", "float4", "float8", "float16", "half", "half2", "half4",
    "half8", "bfloat16", "double2", "double4", "int2", "int4", "int8",
    "uint2", "uint4", "uchar4", "ushort4", "sycl", "cl_int", "cl_mem",
    "cl_kernel", "cl_command_queue", "ze_result_t",
    "ze_command_list_handle_t", "ze_kernel_handle_t", "ze_device_handle_t",
    "ze_module_handle_t", NULL
};

static const char *const KW_HIP[] = {
    "__global__", "__device__", "__host__", "__shared__", "__constant__",
    "__managed__", "__launch_bounds__", "__restrict__", "__forceinline__",
    "__noinline__", "__syncthreads", "__syncwarp", "__threadfence",
    "__threadfence_block", "__shfl", "__shfl_xor", "__shfl_down",
    "__shfl_up", "__ballot", "__any", "__all", "hipLaunchKernelGGL",
    "hipMalloc", "hipFree", "hipMemcpy", "hipMemcpyAsync",
    "hipDeviceSynchronize", "hipStreamSynchronize", "hipGetErrorString",
    "atomicAdd", "atomicMax", "atomicCAS", NULL
};

static const char *const VAR_HIP[] = {
    "threadIdx", "blockIdx", "blockDim", "gridDim", "warpSize", NULL
};

static const char *const TYPE_HIP[] = {
    "dim3", "hipError_t", "hipStream_t", "hipEvent_t", "hipDeviceProp_t",
    "cudaError_t", "cudaStream_t", "float2", "float4", "double2", "int2",
    "int4", "uint2", "uint4", "half", "half2", "__half", "__half2",
    "hip_bfloat16", "__hip_bfloat16", "fp16x4", "fp32x4", NULL
};

static const char *const KW_GLSL[] = {
    "layout", "binding", "set", "location", "std140", "std430", "scalar",
    "push_constant", "local_size_x", "local_size_y", "local_size_z",
    "uniform", "buffer", "in", "out", "inout", "flat", "smooth",
    "noperspective", "centroid", "shared", "coherent", "volatile",
    "restrict", "readonly", "writeonly", "invariant", "precise", "highp",
    "mediump", "lowp", "const", "struct", "void", "if", "else", "for",
    "while", "do", "switch", "case", "default", "break", "continue",
    "return", "discard", "subroutine", "true", "false", "barrier",
    "memoryBarrier", "memoryBarrierShared", "memoryBarrierBuffer",
    "groupMemoryBarrier", "subgroupBarrier", "subgroupAdd",
    "subgroupBroadcast", "subgroupElect", "subgroupBallot", "OpCapability",
    "OpExtension", "OpExtInstImport", "OpMemoryModel", "OpEntryPoint",
    "OpExecutionMode", "OpDecorate", "OpMemberDecorate", "OpTypeVoid",
    "OpTypeFloat", "OpTypeInt", "OpTypeVector", "OpTypeMatrix",
    "OpTypeStruct", "OpTypePointer", "OpTypeFunction", "OpFunction",
    "OpFunctionEnd", "OpLabel", "OpVariable", "OpLoad", "OpStore", "OpFMul",
    "OpFAdd", "OpReturn", NULL
};

static const char *const TYPE_GLSL[] = {
    "bool", "int", "uint", "float", "double", "int8_t", "uint8_t", "int16_t",
    "uint16_t", "int64_t", "uint64_t", "float16_t", "vec2", "vec3", "vec4",
    "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3",
    "bvec4", "dvec2", "dvec3", "dvec4", "f16vec2", "f16vec4", "mat2", "mat3",
    "mat4", "mat2x3", "mat3x4", "mat4x3", "sampler2D", "sampler3D",
    "samplerCube", "sampler2DArray", "sampler2DShadow", "image2D", "image3D",
    "uimage2D", "iimage2D", "texture2D", "sampler",
    "accelerationStructureEXT", NULL
};

static const char *const KW_METAL[] = {
    "kernel", "vertex", "fragment", "mesh", "object", "visible", "stitchable",
    "device", "constant", "thread", "threadgroup", "threadgroup_imageblock",
    "ray_data", "object_data", "metal", "threadgroup_barrier",
    "simdgroup_barrier", "mem_flags", "mem_threadgroup", "mem_device",
    "mem_none", "simd_sum", "simd_prefix_exclusive_sum", "simd_shuffle",
    "simd_shuffle_xor", "simd_shuffle_down", "simd_broadcast", "simd_ballot",
    "simd_is_first", "simdgroup_load", "simdgroup_store",
    "simdgroup_multiply", "simdgroup_multiply_accumulate", "buffer",
    "texture", "stage_in", "position", "color", "thread_position_in_grid",
    "thread_position_in_threadgroup", "threadgroup_position_in_grid",
    "threads_per_threadgroup", "thread_index_in_simdgroup",
    "simdgroup_index_in_threadgroup", "threads_per_simdgroup", "vertex_id",
    "instance_id", NULL
};

static const char *const TYPE_METAL[] = {
    "half", "half2", "half3", "half4", "bfloat", "bfloat2", "bfloat4",
    "float2", "float3", "float4", "packed_float2", "packed_float3",
    "packed_float4", "packed_half2", "packed_half3", "packed_half4", "int2",
    "int3", "int4", "uint", "uint2", "uint3", "uint4", "ushort", "ushort2",
    "ushort4", "uchar", "uchar2", "uchar4", "bool2", "bool3", "bool4",
    "float2x2", "float3x3", "float4x4", "half2x2", "half3x3", "half4x4",
    "simdgroup_float8x8", "simdgroup_half8x8", "simdgroup_bfloat8x8",
    "texture1d", "texture2d", "texture3d", "texturecube", "texture2d_array",
    "depth2d", "sampler", "atomic_uint", "atomic_int", "atomic_float",
    "access", NULL
};

npl_lang_t
npl_lang_from_name(const char *name)
{
    if (!name || !name[0]) return NPL_LANG_TEXT;
    if (ascii_ieq(name, "perl") || ascii_ieq(name, "pl") || ascii_ieq(name, "pm")) return NPL_LANG_PERL;
    if (ascii_ieq(name, "c")) return NPL_LANG_C;
    if (ascii_ieq(name, "cpp") || ascii_ieq(name, "c++") || ascii_ieq(name, "cxx")) return NPL_LANG_CPP;
    if (ascii_ieq(name, "xs")) return NPL_LANG_XS;
    if (ascii_ieq(name, "rust") || ascii_ieq(name, "rs")) return NPL_LANG_RUST;
    if (ascii_ieq(name, "go") || ascii_ieq(name, "golang")) return NPL_LANG_GO;
    if (ascii_ieq(name, "python") || ascii_ieq(name, "py")) return NPL_LANG_PYTHON;
    if (ascii_ieq(name, "js") || ascii_ieq(name, "javascript") || ascii_ieq(name, "jsx")) return NPL_LANG_JS;
    if (ascii_ieq(name, "ts") || ascii_ieq(name, "typescript") || ascii_ieq(name, "tsx")) return NPL_LANG_TS;
    if (ascii_ieq(name, "lua")) return NPL_LANG_LUA;
    if (ascii_ieq(name, "json") || ascii_ieq(name, "jsonc")) return NPL_LANG_JSON;
    if (ascii_ieq(name, "yaml") || ascii_ieq(name, "yml")) return NPL_LANG_YAML;
    if (ascii_ieq(name, "sh") || ascii_ieq(name, "shell") || ascii_ieq(name, "bash") || ascii_ieq(name, "zsh")) return NPL_LANG_SH;
    if (ascii_ieq(name, "markdown") || ascii_ieq(name, "md")) return NPL_LANG_MARKDOWN;
    if (ascii_ieq(name, "diff") || ascii_ieq(name, "patch")) return NPL_LANG_DIFF;
    if (ascii_ieq(name, "tcl") || ascii_ieq(name, "tk")) return NPL_LANG_TCL;
    if (ascii_ieq(name, "make") || ascii_ieq(name, "makefile")) return NPL_LANG_MAKE;
    if (ascii_ieq(name, "sql") || ascii_ieq(name, "spl") || ascii_ieq(name, "ddl") ||
        ascii_ieq(name, "dcl") || ascii_ieq(name, "db2") || ascii_ieq(name, "db2i") ||
        ascii_ieq(name, "db2luw") || ascii_ieq(name, "db2z") || ascii_ieq(name, "informix")) return NPL_LANG_SQL;
    if (ascii_ieq(name, "hlasm") || ascii_ieq(name, "hla") || ascii_ieq(name, "mlc") ||
        ascii_ieq(name, "bal") || ascii_ieq(name, "zasm")) return NPL_LANG_HLASM;
    if (ascii_ieq(name, "asm") || ascii_ieq(name, "s") || ascii_ieq(name, "assembly") ||
        ascii_ieq(name, "gas") || ascii_ieq(name, "nasm") || ascii_ieq(name, "ppc64") ||
        ascii_ieq(name, "s390x") || ascii_ieq(name, "arm64") || ascii_ieq(name, "amd64")) return NPL_LANG_ASM;
    if (ascii_ieq(name, "rpgile") || ascii_ieq(name, "rpgle") || ascii_ieq(name, "rpg") ||
        ascii_ieq(name, "sqlrpgle")) return NPL_LANG_RPGILE;
    if (ascii_ieq(name, "cobol") || ascii_ieq(name, "cbl") || ascii_ieq(name, "cob") ||
        ascii_ieq(name, "cpy")) return NPL_LANG_COBOL;
    if (ascii_ieq(name, "sycl") || ascii_ieq(name, "opencl") || ascii_ieq(name, "cl") ||
        ascii_ieq(name, "oneapi")) return NPL_LANG_SYCL;
    if (ascii_ieq(name, "hip") || ascii_ieq(name, "cuda") || ascii_ieq(name, "cu") ||
        ascii_ieq(name, "rocm")) return NPL_LANG_HIP;
    if (ascii_ieq(name, "glsl") || ascii_ieq(name, "spirv") || ascii_ieq(name, "spvasm") ||
        ascii_ieq(name, "vulkan") || ascii_ieq(name, "vert") || ascii_ieq(name, "frag") ||
        ascii_ieq(name, "comp")) return NPL_LANG_GLSL;
    if (ascii_ieq(name, "metal") || ascii_ieq(name, "msl")) return NPL_LANG_METAL;
    return NPL_LANG_TEXT;
}

npl_lang_t
npl_lang_from_filename(const char *filename)
{
    if (!filename || !filename[0]) return NPL_LANG_TEXT;
    const char *base = filename;
    for (const char *p = filename; *p; p++) {
        if (*p == '/' || *p == '\\') base = p + 1;
    }
    if (ascii_ieq(base, "Makefile") || ascii_ieq(base, "GNUmakefile") || ascii_ieq(base, "makefile")) {
        return NPL_LANG_MAKE;
    }
    if (ascii_ieq(base, "Makefile.PL") || ascii_ieq(base, "cpanfile")) {
        return NPL_LANG_PERL;
    }
    const char *dot = strrchr(base, '.');
    if (!dot || dot[1] == '\0') return NPL_LANG_TEXT;
    const char *ext = dot + 1;

    if (ascii_ieq(ext, "pl") || ascii_ieq(ext, "pm") || ascii_ieq(ext, "t") ||
        ascii_ieq(ext, "psgi") || ascii_ieq(ext, "pod")) return NPL_LANG_PERL;
    if (ascii_ieq(ext, "c") || ascii_ieq(ext, "h")) return NPL_LANG_C;
    if (ascii_ieq(ext, "cc") || ascii_ieq(ext, "cpp") || ascii_ieq(ext, "cxx") ||
        ascii_ieq(ext, "hpp") || ascii_ieq(ext, "hh") || ascii_ieq(ext, "hxx")) return NPL_LANG_CPP;
    if (ascii_ieq(ext, "xs") || ascii_ieq(ext, "xsh")) return NPL_LANG_XS;
    if (ascii_ieq(ext, "rs")) return NPL_LANG_RUST;
    if (ascii_ieq(ext, "go")) return NPL_LANG_GO;
    if (ascii_ieq(ext, "py") || ascii_ieq(ext, "pyi")) return NPL_LANG_PYTHON;
    if (ascii_ieq(ext, "js") || ascii_ieq(ext, "mjs") || ascii_ieq(ext, "cjs") || ascii_ieq(ext, "jsx")) return NPL_LANG_JS;
    if (ascii_ieq(ext, "ts") || ascii_ieq(ext, "mts") || ascii_ieq(ext, "cts") || ascii_ieq(ext, "tsx")) return NPL_LANG_TS;
    if (ascii_ieq(ext, "lua")) return NPL_LANG_LUA;
    if (ascii_ieq(ext, "json") || ascii_ieq(ext, "jsonc")) return NPL_LANG_JSON;
    if (ascii_ieq(ext, "yml") || ascii_ieq(ext, "yaml")) return NPL_LANG_YAML;
    if (ascii_ieq(ext, "sh") || ascii_ieq(ext, "bash") || ascii_ieq(ext, "zsh") || ascii_ieq(ext, "ksh")) return NPL_LANG_SH;
    if (ascii_ieq(ext, "md") || ascii_ieq(ext, "markdown")) return NPL_LANG_MARKDOWN;
    if (ascii_ieq(ext, "diff") || ascii_ieq(ext, "patch")) return NPL_LANG_DIFF;
    if (ascii_ieq(ext, "tcl") || ascii_ieq(ext, "tk")) return NPL_LANG_TCL;
    if (ascii_ieq(ext, "mk") || ascii_ieq(ext, "mak")) return NPL_LANG_MAKE;
    if (ascii_ieq(ext, "sql") || ascii_ieq(ext, "spl") || ascii_ieq(ext, "ddl") ||
        ascii_ieq(ext, "dcl")) return NPL_LANG_SQL;
    if (ascii_ieq(ext, "hlasm") || ascii_ieq(ext, "hla") || ascii_ieq(ext, "mlc") ||
        ascii_ieq(ext, "mac")) return NPL_LANG_HLASM;
    if (ascii_ieq(ext, "s") || ascii_ieq(ext, "asm")) return NPL_LANG_ASM;
    if (ascii_ieq(ext, "rpgle") || ascii_ieq(ext, "sqlrpgle") || ascii_ieq(ext, "rpg") ||
        ascii_ieq(ext, "rpginc")) return NPL_LANG_RPGILE;
    if (ascii_ieq(ext, "cbl") || ascii_ieq(ext, "cob") || ascii_ieq(ext, "cobol") ||
        ascii_ieq(ext, "cpy")) return NPL_LANG_COBOL;
    if (ascii_ieq(ext, "cl") || ascii_ieq(ext, "sycl")) return NPL_LANG_SYCL;
    if (ascii_ieq(ext, "hip") || ascii_ieq(ext, "cu") || ascii_ieq(ext, "cuh")) return NPL_LANG_HIP;
    if (ascii_ieq(ext, "glsl") || ascii_ieq(ext, "vert") || ascii_ieq(ext, "frag") ||
        ascii_ieq(ext, "comp") || ascii_ieq(ext, "spvasm") || ascii_ieq(ext, "geom") ||
        ascii_ieq(ext, "tesc") || ascii_ieq(ext, "tese")) return NPL_LANG_GLSL;
    if (ascii_ieq(ext, "metal")) return NPL_LANG_METAL;
    return NPL_LANG_TEXT;
}

const char *
npl_lang_name(npl_lang_t lang)
{
    switch (lang) {
        case NPL_LANG_PERL:     return "perl";
        case NPL_LANG_C:        return "c";
        case NPL_LANG_CPP:      return "cpp";
        case NPL_LANG_XS:       return "xs";
        case NPL_LANG_RUST:     return "rust";
        case NPL_LANG_GO:       return "go";
        case NPL_LANG_PYTHON:   return "python";
        case NPL_LANG_JS:       return "js";
        case NPL_LANG_TS:       return "ts";
        case NPL_LANG_LUA:      return "lua";
        case NPL_LANG_JSON:     return "json";
        case NPL_LANG_YAML:     return "yaml";
        case NPL_LANG_SH:       return "sh";
        case NPL_LANG_MARKDOWN: return "markdown";
        case NPL_LANG_DIFF:     return "diff";
        case NPL_LANG_TCL:      return "tcl";
        case NPL_LANG_MAKE:     return "make";
        case NPL_LANG_SQL:      return "sql";
        case NPL_LANG_HLASM:    return "hlasm";
        case NPL_LANG_ASM:      return "asm";
        case NPL_LANG_RPGILE:   return "rpgile";
        case NPL_LANG_COBOL:    return "cobol";
        case NPL_LANG_SYCL:     return "sycl";
        case NPL_LANG_HIP:      return "hip";
        case NPL_LANG_GLSL:     return "glsl";
        case NPL_LANG_METAL:    return "metal";
        default:                return "text";
    }
}

size_t
npl_lang_count(void)
{
    return (size_t)NPL_LANG_COUNT;
}

const char *
npl_tok_name(npl_tok_type_t tok)
{
    switch (tok) {
        case NPL_TOK_NORMAL:   return "normal";
        case NPL_TOK_KEYWORD:  return "keyword";
        case NPL_TOK_STRING:   return "string";
        case NPL_TOK_COMMENT:  return "comment";
        case NPL_TOK_NUMBER:   return "number";
        case NPL_TOK_VAR:      return "var";
        case NPL_TOK_FUNC:     return "func";
        case NPL_TOK_TYPE:     return "type";
        case NPL_TOK_OPERATOR: return "operator";
        case NPL_TOK_PREPROC:  return "preproc";
        case NPL_TOK_CONSTANT: return "constant";
        case NPL_TOK_TAG:      return "tag";
        default:               return "normal";
    }
}

npl_syntax_t *
npl_syntax_new(npl_lang_t lang)
{
    npl_syntax_t *syn = (npl_syntax_t *)calloc(1, sizeof(npl_syntax_t));
    if (!syn) return NULL;
    syn->lang = lang;
    syn->dirty_from = 0;
    return syn;
}

void
npl_syntax_free(npl_syntax_t *syn)
{
    if (!syn) return;
    free(syn->states);
    free(syn);
}

npl_lang_t
npl_syntax_get_lang(const npl_syntax_t *syn)
{
    return syn ? syn->lang : NPL_LANG_TEXT;
}

void
npl_syntax_set_lang(npl_syntax_t *syn, npl_lang_t lang)
{
    if (!syn) return;
    syn->lang = lang;
    syn->dirty_from = 0;
    syn->state_count = 0;
}

void
npl_syntax_invalidate(npl_syntax_t *syn, size_t from_line, int64_t line_delta)
{
    if (!syn) return;
    if (from_line < syn->dirty_from) syn->dirty_from = from_line;
    if (line_delta != 0 && syn->state_count > from_line) {
        syn->state_count = from_line;
    }
}

uint8_t
npl_syntax_end_state(const npl_syntax_t *syn, size_t line)
{
    if (!syn || line >= syn->state_count) return NPL_STATE_NORMAL;
    return syn->states[line];
}

size_t
npl_syntax_last_relex_lines(const npl_syntax_t *syn)
{
    return syn ? syn->last_relex_lines : 0;
}

static inline void
emit_tok(npl_token_t *out, size_t max_toks, size_t *cnt,
         size_t col, size_t len, npl_tok_type_t type)
{
    if (len == 0 || !out || *cnt >= max_toks) return;
    if (*cnt > 0) {
        npl_token_t *prev = &out[*cnt - 1];
        if (prev->type == (uint8_t)type && (size_t)prev->col + (size_t)prev->len == col) {
            prev->len += (uint32_t)len;
            return;
        }
    }
    npl_token_t *t = &out[(*cnt)++];
    t->col = (uint32_t)col;
    t->len = (uint32_t)len;
    t->type = (uint8_t)type;
}

static size_t
scan_quoted(const char *s, size_t len, size_t i, unsigned char quote)
{
    i++; /* skip opening quote */
    while (i < len) {
        unsigned char c = (unsigned char)s[i];
        if (c == '\\' && i + 1 < len) {
            i += 2;
            continue;
        }
        if (c == quote) {
            return i + 1;
        }
        i++;
    }
    return len;
}

static size_t
scan_quoted_doubled(const char *s, size_t len, size_t i, unsigned char quote)
{
    i++; /* skip opening quote */
    while (i < len) {
        unsigned char c = (unsigned char)s[i];
        if (c == quote) {
            if (i + 1 < len && (unsigned char)s[i + 1] == quote) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i++;
    }
    return len;
}

static size_t
scan_number(const char *s, size_t len, size_t i)
{
    if (i + 1 < len && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
        i += 2;
        while (i < len && (npl_is_xdigit((unsigned char)s[i]) || s[i] == '_')) i++;
    } else if (i + 1 < len && s[i] == '0' && (s[i + 1] == 'b' || s[i + 1] == 'B')) {
        i += 2;
        while (i < len && (s[i] == '0' || s[i] == '1' || s[i] == '_')) i++;
    } else {
        while (i < len && (npl_is_digit((unsigned char)s[i]) || s[i] == '_')) i++;
        if (i < len && s[i] == '.' && i + 1 < len && npl_is_digit((unsigned char)s[i + 1])) {
            i++;
            while (i < len && (npl_is_digit((unsigned char)s[i]) || s[i] == '_')) i++;
        }
        if (i < len && (s[i] == 'e' || s[i] == 'E')) {
            size_t j = i + 1;
            if (j < len && (s[j] == '+' || s[j] == '-')) j++;
            if (j < len && npl_is_digit((unsigned char)s[j])) {
                i = j;
                while (i < len && npl_is_digit((unsigned char)s[i])) i++;
            }
        }
    }
    while (i < len && (npl_is_alpha((unsigned char)s[i]) || s[i] == '_')) i++;
    return i;
}

static int
parse_reg_num(const char *s, size_t len, int max_val)
{
    if (len == 0 || len > 2) return 0;
    int v = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!npl_is_digit(c)) return 0;
        v = v * 10 + (int)(c - '0');
    }
    return v <= max_val;
}

static int
is_hlasm_register(const char *w, size_t len)
{
    if (len < 2 || len > 4) return 0;
    unsigned char c0 = npl_tolower((unsigned char)w[0]);
    if ((c0 == 'r' || c0 == 'f') && parse_reg_num(w + 1, len - 1, 15)) return 1;
    if (c0 == 'v' && parse_reg_num(w + 1, len - 1, 31)) return 1;
    if (len >= 3) {
        unsigned char c1 = npl_tolower((unsigned char)w[1]);
        if (c1 == 'r' && (c0 == 'g' || c0 == 'a' || c0 == 'c') &&
            parse_reg_num(w + 2, len - 2, 15)) return 1;
        if (c0 == 'v' && c1 == 'r' && parse_reg_num(w + 2, len - 2, 31)) return 1;
    }
    return 0;
}

static int
is_asm_register(const char *w, size_t len)
{
    static const char *const NAMED_REGS[] = {
        "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "rip",
        "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp", "eip",
        "ax", "bx", "cx", "dx", "si", "di", "bp", "sp",
        "al", "ah", "bl", "bh", "cl", "ch", "dl", "dh",
        "lr", "ctr", "xer", "xzr", "wzr", "fpsr", "fpcr", "nzcv",
        NULL
    };
    if (len < 2 || len > 5) return 0;
    if (word_in_list_ci(w, len, NAMED_REGS)) return 1;

    unsigned char c0 = npl_tolower((unsigned char)w[0]);
    unsigned char c1 = npl_tolower((unsigned char)w[1]);

    /* r0..r31, f0..f31, v0..v31, x0..x30, w0..w30, q0..q31, d0..d31, s0..s31, z0..z31 */
    if ((c0 == 'r' || c0 == 'f' || c0 == 'v' || c0 == 'q' || c0 == 'd' ||
         c0 == 's' || c0 == 'z') && parse_reg_num(w + 1, len - 1, 31)) return 1;
    if ((c0 == 'x' || c0 == 'w') && parse_reg_num(w + 1, len - 1, 30)) return 1;
    if (c0 == 'p' && parse_reg_num(w + 1, len - 1, 15)) return 1;
    if (c0 == 'k' && parse_reg_num(w + 1, len - 1, 7)) return 1;

    /* r8d..r15d / r8w..r15w / r8b..r15b */
    if (c0 == 'r' && len >= 3) {
        unsigned char last = npl_tolower((unsigned char)w[len - 1]);
        if ((last == 'd' || last == 'w' || last == 'b') &&
            parse_reg_num(w + 1, len - 2, 15)) return 1;
    }

    if (len >= 3) {
        /* vs0..vs63, cr0..cr7, vr0..vr31, gr0..gr15, ar0..ar15 */
        if (c0 == 'v' && c1 == 's' && parse_reg_num(w + 2, len - 2, 63)) return 1;
        if (c0 == 'c' && c1 == 'r' && parse_reg_num(w + 2, len - 2, 7)) return 1;
        if (c0 == 'v' && c1 == 'r' && parse_reg_num(w + 2, len - 2, 31)) return 1;
        if ((c0 == 'g' || c0 == 'a') && c1 == 'r' && parse_reg_num(w + 2, len - 2, 15)) return 1;
    }
    if (len >= 4) {
        unsigned char c2 = npl_tolower((unsigned char)w[2]);
        /* xmm0..31, ymm0..31, zmm0..31, tmm0..7, acc0..7 */
        if ((c0 == 'x' || c0 == 'y' || c0 == 'z') && c1 == 'm' && c2 == 'm' &&
            parse_reg_num(w + 3, len - 3, 31)) return 1;
        if (c0 == 't' && c1 == 'm' && c2 == 'm' &&
            parse_reg_num(w + 3, len - 3, 7)) return 1;
        if (c0 == 'a' && c1 == 'c' && c2 == 'c' &&
            parse_reg_num(w + 3, len - 3, 7)) return 1;
    }
    return 0;
}

static int
is_c_family(npl_lang_t lang)
{
    return lang == NPL_LANG_C || lang == NPL_LANG_CPP || lang == NPL_LANG_XS ||
           lang == NPL_LANG_RUST || lang == NPL_LANG_GO ||
           lang == NPL_LANG_JS || lang == NPL_LANG_TS ||
           lang == NPL_LANG_SYCL || lang == NPL_LANG_HIP ||
           lang == NPL_LANG_GLSL || lang == NPL_LANG_METAL;
}

static int
is_preproc_c_lang(npl_lang_t lang)
{
    return lang == NPL_LANG_C || lang == NPL_LANG_CPP || lang == NPL_LANG_XS ||
           lang == NPL_LANG_SYCL || lang == NPL_LANG_HIP ||
           lang == NPL_LANG_GLSL || lang == NPL_LANG_METAL;
}

static int
is_hash_comment_lang(npl_lang_t lang)
{
    return lang == NPL_LANG_PERL || lang == NPL_LANG_PYTHON ||
           lang == NPL_LANG_YAML || lang == NPL_LANG_SH ||
           lang == NPL_LANG_TCL || lang == NPL_LANG_MAKE;
}

/* Dedicated HLASM line lexer (col-1 labels, '*' / '.*' comments, opcodes, operands, remarks) */
static uint8_t
lex_hlasm_line(const char *line, size_t len, npl_token_t *out_toks,
               size_t max_toks, size_t *out_count)
{
    size_t cnt = 0;
    if (len == 0) {
        if (out_count) *out_count = 0;
        return NPL_STATE_NORMAL;
    }

    /* Full-line comment: col 1 '*' or '.*' macro comment */
    if (line[0] == '*' || (len >= 2 && line[0] == '.' && line[1] == '*')) {
        emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_COMMENT);
        if (out_count) *out_count = cnt;
        return NPL_STATE_NORMAL;
    }

    /* Reserve col 72 continuation marker if standard 72+ card image */
    size_t code_end = len;
    int has_cont = 0;
    if (len >= 72 && !npl_is_space((unsigned char)line[71])) {
        has_cont = 1;
        code_end = 71;
    }

    size_t i = 0;

    /* Field 1: optional label starting in column 0 */
    if (!npl_is_space((unsigned char)line[0])) {
        size_t s = 0;
        while (i < code_end && !npl_is_space((unsigned char)line[i])) i++;
        npl_tok_type_t ltype = (line[0] == '&') ? NPL_TOK_VAR : NPL_TOK_TAG;
        emit_tok(out_toks, max_toks, &cnt, s, i - s, ltype);
    }

    while (i < code_end && npl_is_space((unsigned char)line[i])) i++;

    /* Field 2: operation / directive */
    int is_storage_op = 0;
    if (i < code_end) {
        size_t s = i;
        while (i < code_end && !npl_is_space((unsigned char)line[i])) i++;
        size_t wlen = i - s;
        if (word_in_list_ci(line + s, wlen, KW_HLASM_DIR)) {
            emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_PREPROC);
            if (wlen == 2 && npl_tolower((unsigned char)line[s]) == 'd' &&
                (npl_tolower((unsigned char)line[s + 1]) == 's' ||
                 npl_tolower((unsigned char)line[s + 1]) == 'c')) {
                is_storage_op = 1;
            }
        } else if (word_in_list_ci(line + s, wlen, KW_HLASM_OP)) {
            emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_KEYWORD);
        } else if (line[s] == '&') {
            emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_VAR);
        } else {
            emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_FUNC);
        }
    }

    while (i < code_end && npl_is_space((unsigned char)line[i])) i++;

    /* Field 3: operands (ends at unquoted/unparenthesized whitespace -> Field 4 remark) */
    int paren_depth = 0;
    while (i < code_end) {
        unsigned char c = (unsigned char)line[i];
        if (npl_is_space(c) && paren_depth == 0) {
            while (i < code_end && npl_is_space((unsigned char)line[i])) i++;
            if (i < code_end) {
                emit_tok(out_toks, max_toks, &cnt, i, code_end - i, NPL_TOK_COMMENT);
            }
            break;
        }
        if (c == '(') {
            paren_depth++;
            i++;
            continue;
        }
        if (c == ')') {
            if (paren_depth > 0) paren_depth--;
            i++;
            continue;
        }
        if (c == '\'') {
            size_t end = scan_quoted_doubled(line, code_end, i, '\'');
            emit_tok(out_toks, max_toks, &cnt, i, end - i, NPL_TOK_STRING);
            i = end;
            continue;
        }
        /* Self-defining literal prefix like C'...', X'...', F'...', CL8'...' */
        if (c == '=') {
            emit_tok(out_toks, max_toks, &cnt, i, 1, NPL_TOK_OPERATOR);
            i++;
            continue;
        }
        if (c == '&') {
            size_t s = i++;
            while (i < code_end && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == '.')) i++;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_VAR);
            continue;
        }
        if (npl_is_digit(c)) {
            size_t s = i;
            while (i < code_end && npl_is_digit((unsigned char)line[i])) i++;
            if (is_storage_op && i < code_end && npl_is_alpha((unsigned char)line[i])) {
                while (i < code_end && (npl_is_alpha((unsigned char)line[i]) ||
                                        npl_is_digit((unsigned char)line[i]))) i++;
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_TYPE);
            } else {
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_NUMBER);
            }
            continue;
        }
        if (npl_is_ident_start(c) || c == '$' || c == '@' || c == '#') {
            size_t s = i++;
            while (i < code_end && (npl_is_ident_cont((unsigned char)line[i]) ||
                                    line[i] == '$' || line[i] == '@' || line[i] == '#')) i++;
            size_t wlen = i - s;
            if (i < code_end && line[i] == '\'') {
                size_t end = scan_quoted_doubled(line, code_end, i, '\'');
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_TYPE);
                emit_tok(out_toks, max_toks, &cnt, i, end - i, NPL_TOK_STRING);
                i = end;
                continue;
            }
            if (is_hlasm_register(line + s, wlen)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_VAR);
            } else if (is_storage_op && wlen <= 4 &&
                       (npl_tolower((unsigned char)line[s]) == 'c' ||
                        npl_tolower((unsigned char)line[s]) == 'x' ||
                        npl_tolower((unsigned char)line[s]) == 'f' ||
                        npl_tolower((unsigned char)line[s]) == 'd' ||
                        npl_tolower((unsigned char)line[s]) == 'h' ||
                        npl_tolower((unsigned char)line[s]) == 'a' ||
                        npl_tolower((unsigned char)line[s]) == 'p' ||
                        npl_tolower((unsigned char)line[s]) == 'z' ||
                        npl_tolower((unsigned char)line[s]) == 'b')) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_TYPE);
            } else if (wlen >= 2) {
                int all_upper = 1;
                for (size_t j = 0; j < wlen; j++) {
                    unsigned char u = (unsigned char)line[s + j];
                    if (!(u >= 'A' && u <= 'Z') && !npl_is_digit(u) && u != '_' && u != '$' && u != '@' && u != '#') {
                        all_upper = 0;
                        break;
                    }
                }
                if (all_upper) emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_CONSTANT);
            }
            continue;
        }
        if (strchr("+-*/,", (int)c) != NULL) {
            emit_tok(out_toks, max_toks, &cnt, i, 1, NPL_TOK_OPERATOR);
        }
        i++;
    }

    if (has_cont) {
        emit_tok(out_toks, max_toks, &cnt, 71, 1, NPL_TOK_PREPROC);
        if (len > 72) {
            emit_tok(out_toks, max_toks, &cnt, 72, len - 72, NPL_TOK_COMMENT);
        }
    }

    if (out_count) *out_count = cnt;
    return NPL_STATE_NORMAL;
}

/* Dedicated Multi-ISA Assembly line lexer (POWER8+/9/10, amd64, arm64, s390x Telum II) */
static uint8_t
lex_asm_line(const char *line, size_t len, size_t start_i,
             npl_token_t *out_toks, size_t max_toks, size_t *cnt_io)
{
    size_t i = start_i;
    uint8_t state = NPL_STATE_NORMAL;

    while (i < len) {
        unsigned char c = (unsigned char)line[i];
        if (npl_is_space(c)) {
            i++;
            continue;
        }
        /* Comments: ';', '//', C block comments, and '#' when not an immediate literal like #16 / #0x10 */
        if (c == ';' || (i + 1 < len && line[i] == '/' && line[i + 1] == '/')) {
            emit_tok(out_toks, max_toks, cnt_io, i, len - i, NPL_TOK_COMMENT);
            break;
        }
        if (i + 1 < len && line[i] == '/' && line[i + 1] == '*') {
            size_t s = i;
            i += 2;
            int closed = 0;
            while (i + 1 < len) {
                if (line[i] == '*' && line[i + 1] == '/') {
                    i += 2;
                    closed = 1;
                    break;
                }
                i++;
            }
            if (!closed) {
                emit_tok(out_toks, max_toks, cnt_io, s, len - s, NPL_TOK_COMMENT);
                return NPL_STATE_BLOCK_CMT;
            }
            emit_tok(out_toks, max_toks, cnt_io, s, i - s, NPL_TOK_COMMENT);
            continue;
        }
        if (c == '#') {
            if (i + 1 < len && (npl_is_digit((unsigned char)line[i + 1]) ||
                                (line[i + 1] == '-' && i + 2 < len && npl_is_digit((unsigned char)line[i + 2])))) {
                size_t s = i++;
                if (line[i] == '-') i++;
                size_t end = scan_number(line, len, i);
                emit_tok(out_toks, max_toks, cnt_io, s, end - s, NPL_TOK_NUMBER);
                i = end;
                continue;
            }
            emit_tok(out_toks, max_toks, cnt_io, i, len - i, NPL_TOK_COMMENT);
            break;
        }
        /* Quoted strings */
        if (c == '"' || c == '\'') {
            size_t end = scan_quoted(line, len, i, c);
            emit_tok(out_toks, max_toks, cnt_io, i, end - i, NPL_TOK_STRING);
            i = end;
            continue;
        }
        /* AT&T %register */
        if (c == '%' && i + 1 < len && npl_is_ident_cont((unsigned char)line[i + 1])) {
            size_t s = i++;
            while (i < len && npl_is_ident_cont((unsigned char)line[i])) i++;
            emit_tok(out_toks, max_toks, cnt_io, s, i - s, NPL_TOK_VAR);
            continue;
        }
        /* AT&T $immediate */
        if (c == '$' && i + 1 < len && (npl_is_digit((unsigned char)line[i + 1]) || line[i + 1] == '-')) {
            size_t s = i++;
            if (line[i] == '-') i++;
            size_t end = scan_number(line, len, i);
            emit_tok(out_toks, max_toks, cnt_io, s, end - s, NPL_TOK_NUMBER);
            i = end;
            continue;
        }
        /* Directives or local labels starting with '.' */
        if (c == '.' && i + 1 < len && (npl_is_ident_start((unsigned char)line[i + 1]) || npl_is_digit((unsigned char)line[i + 1]))) {
            size_t s = i++;
            while (i < len && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == '.')) i++;
            if (i < len && line[i] == ':') {
                i++;
                emit_tok(out_toks, max_toks, cnt_io, s, i - s, NPL_TOK_TAG);
            } else {
                emit_tok(out_toks, max_toks, cnt_io, s, i - s, NPL_TOK_PREPROC);
            }
            continue;
        }
        /* Objdump function header <symbol>: */
        if (c == '<') {
            size_t s = i + 1;
            size_t j = s;
            while (j < len && line[j] != '>' && !npl_is_space((unsigned char)line[j])) j++;
            if (j > s && j < len && line[j] == '>') {
                emit_tok(out_toks, max_toks, cnt_io, i, j - i + 1, NPL_TOK_FUNC);
                i = j + 1;
                continue;
            }
        }
        /* Numbers / hex addresses */
        if (npl_is_digit(c)) {
            size_t s = i;
            size_t end = scan_number(line, len, i);
            if (end < len && line[end] == ':') {
                emit_tok(out_toks, max_toks, cnt_io, s, end - s, NPL_TOK_NUMBER);
                i = end + 1;
            } else {
                emit_tok(out_toks, max_toks, cnt_io, s, end - s, NPL_TOK_NUMBER);
                i = end;
            }
            continue;
        }
        /* Identifiers, labels, opcodes (incl. dotted AArch64 b.eq / POWER cmpd.), registers */
        if (npl_is_ident_start(c)) {
            size_t s = i++;
            while (i < len && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == '.')) i++;
            size_t wlen = i - s;
            if (i < len && line[i] == ':') {
                emit_tok(out_toks, max_toks, cnt_io, s, wlen + 1, NPL_TOK_TAG);
                i++;
                continue;
            }
            /* Strip trailing '.' for POWER record-form mnemonics like add. / subf. */
            size_t base_len = wlen;
            if (base_len > 1 && line[s + base_len - 1] == '.') base_len--;
            if (word_in_list_ci(line + s, base_len, KW_ASM_OP) ||
                (wlen >= 3 && npl_tolower((unsigned char)line[s]) == 'b' && line[s + 1] == '.')) {
                emit_tok(out_toks, max_toks, cnt_io, s, wlen, NPL_TOK_KEYWORD);
            } else if (word_in_list_ci(line + s, wlen, KW_ASM_DIR)) {
                emit_tok(out_toks, max_toks, cnt_io, s, wlen, NPL_TOK_PREPROC);
            } else if (is_asm_register(line + s, wlen)) {
                emit_tok(out_toks, max_toks, cnt_io, s, wlen, NPL_TOK_VAR);
            }
            continue;
        }
        if (strchr("+-*/%=!<>&|^~@,", (int)c) != NULL) {
            emit_tok(out_toks, max_toks, cnt_io, i, 1, NPL_TOK_OPERATOR);
        }
        i++;
    }
    return state;
}

/* Dedicated RPGILE (**FREE + fixed-format) line lexer */
static uint8_t
lex_rpgile_line(const char *line, size_t len, npl_token_t *out_toks,
                size_t max_toks, size_t *out_count)
{
    size_t cnt = 0;
    if (len == 0) {
        if (out_count) *out_count = 0;
        return NPL_STATE_NORMAL;
    }

    size_t p = 0;
    while (p < len && npl_is_space((unsigned char)line[p])) p++;

    /* **FREE directive */
    if (p + 6 <= len && starts_with_ci(line + p, len - p, "**free")) {
        emit_tok(out_toks, max_toks, &cnt, p, 6, NPL_TOK_PREPROC);
        if (out_count) *out_count = cnt;
        return NPL_STATE_NORMAL;
    }

    /* Fixed-format column 7 comment ('*' at index 6) */
    if (len >= 7 && line[6] == '*') {
        int fixed_prefix = 1;
        for (size_t k = 0; k < 5; k++) {
            unsigned char ch = (unsigned char)line[k];
            if (!npl_is_space(ch) && !npl_is_digit(ch)) { fixed_prefix = 0; break; }
        }
        unsigned char c5 = npl_tolower((unsigned char)line[5]);
        if (fixed_prefix && (npl_is_space(c5) || npl_is_digit(c5) ||
                             c5 == 'h' || c5 == 'f' || c5 == 'd' ||
                             c5 == 'i' || c5 == 'c' || c5 == 'o' || c5 == 'p')) {
            emit_tok(out_toks, max_toks, &cnt, 6, len - 6, NPL_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            return NPL_STATE_NORMAL;
        }
    }

    /* Compiler directives: /COPY, /INCLUDE, /IF, /ENDIF, /FREE, /END-FREE, etc. */
    if (p < len && line[p] == '/' && p + 1 < len && npl_is_alpha((unsigned char)line[p + 1])) {
        size_t j = p + 1;
        while (j < len && (npl_is_ident_cont((unsigned char)line[j]) || line[j] == '-')) j++;
        emit_tok(out_toks, max_toks, &cnt, p, j - p, NPL_TOK_PREPROC);
        if (j < len) {
            size_t s = j;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            if (s < len) emit_tok(out_toks, max_toks, &cnt, s, len - s, NPL_TOK_STRING);
        }
        if (out_count) *out_count = cnt;
        return NPL_STATE_NORMAL;
    }

    size_t i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)line[i];
        if (npl_is_space(c)) {
            i++;
            continue;
        }
        if (i + 1 < len && line[i] == '/' && line[i + 1] == '/') {
            emit_tok(out_toks, max_toks, &cnt, i, len - i, NPL_TOK_COMMENT);
            break;
        }
        if (c == '\'') {
            size_t end = scan_quoted_doubled(line, len, i, '\'');
            emit_tok(out_toks, max_toks, &cnt, i, end - i, NPL_TOK_STRING);
            i = end;
            continue;
        }
        /* %BIF built-in functions */
        if (c == '%' && i + 1 < len && npl_is_alpha((unsigned char)line[i + 1])) {
            size_t s = i++;
            while (i < len && npl_is_ident_cont((unsigned char)line[i])) i++;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_FUNC);
            continue;
        }
        /* Special values & indicators: *ON, *OFF, *INLR, *NONE, *SRCSTMT */
        if (c == '*' && i + 1 < len && npl_is_alpha((unsigned char)line[i + 1])) {
            size_t s = i++;
            while (i < len && npl_is_ident_cont((unsigned char)line[i])) i++;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_CONSTANT);
            continue;
        }
        /* Embedded SQL host variable :var */
        if (c == ':' && i + 1 < len && npl_is_ident_start((unsigned char)line[i + 1])) {
            size_t s = i++;
            while (i < len && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == '.')) i++;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_VAR);
            continue;
        }
        if (npl_is_digit(c)) {
            size_t end = scan_number(line, len, i);
            emit_tok(out_toks, max_toks, &cnt, i, end - i, NPL_TOK_NUMBER);
            i = end;
            continue;
        }
        if (npl_is_ident_start(c)) {
            size_t s = i++;
            while (i < len && (npl_is_ident_cont((unsigned char)line[i]) ||
                               (line[i] == '-' && i + 1 < len && npl_is_alpha((unsigned char)line[i + 1])))) {
                i++;
            }
            size_t wlen = i - s;
            if (word_in_list_ci(line + s, wlen, KW_RPGILE)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_KEYWORD);
            } else if (word_in_list_ci(line + s, wlen, TYPE_RPGILE)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_TYPE);
            } else if (word_in_list_ci(line + s, wlen, KW_SQL)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_KEYWORD);
            } else if (word_in_list_ci(line + s, wlen, TYPE_SQL)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_TYPE);
            } else {
                size_t k = i;
                while (k < len && (line[k] == ' ' || line[k] == '\t')) k++;
                if (k < len && line[k] == '(') {
                    emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_FUNC);
                }
            }
            continue;
        }
        if (strchr("+-*/%=<>!&|:", (int)c) != NULL) {
            emit_tok(out_toks, max_toks, &cnt, i, 1, NPL_TOK_OPERATOR);
        }
        i++;
    }

    if (out_count) *out_count = cnt;
    return NPL_STATE_NORMAL;
}

/* Dedicated COBOL line lexer (fixed col-7 '*'/'/' comments + '*>' inline, Divisions, PIC, EXEC SQL/CICS) */
static uint8_t
lex_cobol_line(const char *line, size_t len, npl_token_t *out_toks,
               size_t max_toks, size_t *out_count)
{
    size_t cnt = 0;
    if (len == 0) {
        if (out_count) *out_count = 0;
        return NPL_STATE_NORMAL;
    }

    size_t i = 0;
    /* Check fixed-format columns 1..6 (all spaces or all digits) + col 7 indicator */
    if (len >= 7) {
        int all_sp = 1, all_dig = 1;
        for (size_t k = 0; k < 6; k++) {
            unsigned char ch = (unsigned char)line[k];
            if (ch != ' ') all_sp = 0;
            if (!npl_is_digit(ch)) all_dig = 0;
        }
        if (all_sp || all_dig) {
            if (all_dig) {
                emit_tok(out_toks, max_toks, &cnt, 0, 6, NPL_TOK_COMMENT);
            }
            if (line[6] == '*' || line[6] == '/') {
                emit_tok(out_toks, max_toks, &cnt, 6, len - 6, NPL_TOK_COMMENT);
                if (out_count) *out_count = cnt;
                return NPL_STATE_NORMAL;
            }
            if (line[6] == 'D' || line[6] == 'd' || line[6] == '-') {
                emit_tok(out_toks, max_toks, &cnt, 6, 1, NPL_TOK_PREPROC);
            }
            i = 7;
        }
    }

    int expect_pic = 0;
    while (i < len) {
        unsigned char c = (unsigned char)line[i];
        if (npl_is_space(c)) {
            i++;
            continue;
        }
        /* Free-format / COBOL-2002 inline comment '*>' */
        if (i + 1 < len && line[i] == '*' && line[i + 1] == '>') {
            emit_tok(out_toks, max_toks, &cnt, i, len - i, NPL_TOK_COMMENT);
            break;
        }
        /* Picture string right after PIC / PICTURE */
        if (expect_pic) {
            if (starts_with_ci(line + i, len - i, "is") &&
                (i + 2 == len || npl_is_space((unsigned char)line[i + 2]))) {
                emit_tok(out_toks, max_toks, &cnt, i, 2, NPL_TOK_KEYWORD);
                i += 2;
                continue;
            }
            size_t s = i;
            while (i < len && !npl_is_space((unsigned char)line[i]) &&
                   !(line[i] == '.' && (i + 1 == len || npl_is_space((unsigned char)line[i + 1])))) {
                i++;
            }
            if (i > s) emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_TYPE);
            expect_pic = 0;
            continue;
        }
        if (c == '\'' || c == '"') {
            size_t end = scan_quoted_doubled(line, len, i, c);
            emit_tok(out_toks, max_toks, &cnt, i, end - i, NPL_TOK_STRING);
            i = end;
            continue;
        }
        /* Embedded SQL host variable :WS-VAR */
        if (c == ':' && i + 1 < len && npl_is_ident_start((unsigned char)line[i + 1])) {
            size_t s = i++;
            while (i < len && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == '-')) i++;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_VAR);
            continue;
        }
        if (npl_is_digit(c)) {
            size_t s = i;
            /* Level numbers or hyphenated paragraph names like 1000-MAIN-PARA */
            size_t j = i;
            while (j < len && npl_is_digit((unsigned char)line[j])) j++;
            if (j < len && line[j] == '-' && j + 1 < len &&
                (npl_is_alpha((unsigned char)line[j + 1]) || npl_is_digit((unsigned char)line[j + 1]))) {
                i = j + 1;
                while (i < len && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == '-')) i++;
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_TAG);
            } else {
                size_t end = scan_number(line, len, i);
                emit_tok(out_toks, max_toks, &cnt, s, end - s, NPL_TOK_NUMBER);
                i = end;
            }
            continue;
        }
        if (npl_is_ident_start(c)) {
            size_t s = i++;
            while (i < len && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == '-')) i++;
            size_t wlen = i - s;
            if (word_in_list_ci(line + s, wlen, TYPE_COBOL)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_TYPE);
                if ((wlen == 3 && starts_with_ci(line + s, wlen, "pic")) ||
                    (wlen == 7 && starts_with_ci(line + s, wlen, "picture"))) {
                    expect_pic = 1;
                }
            } else if (word_in_list_ci(line + s, wlen, KW_COBOL)) {
                npl_tok_type_t tt = NPL_TOK_KEYWORD;
                if ((wlen == 4 && starts_with_ci(line + s, wlen, "exec")) ||
                    (wlen == 8 && starts_with_ci(line + s, wlen, "end-exec")) ||
                    (wlen == 4 && starts_with_ci(line + s, wlen, "copy")) ||
                    (wlen == 3 && starts_with_ci(line + s, wlen, "sql")) ||
                    (wlen == 4 && starts_with_ci(line + s, wlen, "cics"))) {
                    tt = NPL_TOK_PREPROC;
                }
                emit_tok(out_toks, max_toks, &cnt, s, wlen, tt);
            } else if (word_in_list_ci(line + s, wlen, KW_SQL)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_KEYWORD);
            } else if (word_in_list_ci(line + s, wlen, TYPE_SQL)) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, NPL_TOK_TYPE);
            }
            continue;
        }
        if (strchr("+-*/=<>", (int)c) != NULL) {
            emit_tok(out_toks, max_toks, &cnt, i, 1, NPL_TOK_OPERATOR);
        }
        i++;
    }

    if (out_count) *out_count = cnt;
    return NPL_STATE_NORMAL;
}

uint8_t
npl_syntax_lex_line(npl_lang_t lang, const char *line, size_t len,
                    uint8_t start_state, npl_token_t *out_toks,
                    size_t max_toks, size_t *out_count)
{
    size_t cnt = 0;
    if (out_count) *out_count = 0;
    if (!line || len == 0) return start_state;

    /* Line-oriented mainframe/midrange lexers */
    if (lang == NPL_LANG_HLASM) {
        return lex_hlasm_line(line, len, out_toks, max_toks, out_count);
    }
    if (lang == NPL_LANG_RPGILE) {
        return lex_rpgile_line(line, len, out_toks, max_toks, out_count);
    }
    if (lang == NPL_LANG_COBOL) {
        return lex_cobol_line(line, len, out_toks, max_toks, out_count);
    }

    /* Diff language: whole-line coloring */
    if (lang == NPL_LANG_DIFF) {
        unsigned char c0 = (unsigned char)line[0];
        if (len >= 2 && line[0] == '@' && line[1] == '@') {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_TAG);
        } else if (len >= 4 && (memcmp(line, "diff", 4) == 0 || memcmp(line, "--- ", 4) == 0 || memcmp(line, "+++ ", 4) == 0)) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_PREPROC);
        } else if (c0 == '+') {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_STRING);
        } else if (c0 == '-') {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_KEYWORD);
        }
        if (out_count) *out_count = cnt;
        return NPL_STATE_NORMAL;
    }

    /* Markdown */
    if (lang == NPL_LANG_MARKDOWN) {
        size_t p = 0;
        while (p < len && npl_is_space((unsigned char)line[p])) p++;
        if (p + 2 < len && line[p] == '`' && line[p + 1] == '`' && line[p + 2] == '`') {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_PREPROC);
            if (out_count) *out_count = cnt;
            return (start_state == NPL_STATE_MD_FENCE) ? NPL_STATE_NORMAL : NPL_STATE_MD_FENCE;
        }
        if (start_state == NPL_STATE_MD_FENCE) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_STRING);
            if (out_count) *out_count = cnt;
            return NPL_STATE_MD_FENCE;
        }
        if (p < len && line[p] == '#') {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_TAG);
            if (out_count) *out_count = cnt;
            return NPL_STATE_NORMAL;
        }
        if (p < len && line[p] == '>') {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            return NPL_STATE_NORMAL;
        }
        size_t i = 0;
        while (i < len) {
            if (line[i] == '`') {
                size_t j = i + 1;
                while (j < len && line[j] != '`') j++;
                if (j < len) j++;
                emit_tok(out_toks, max_toks, &cnt, i, j - i, NPL_TOK_STRING);
                i = j;
            } else if (i + 1 < len && line[i] == '*' && line[i + 1] == '*') {
                size_t j = i + 2;
                while (j + 1 < len && !(line[j] == '*' && line[j + 1] == '*')) j++;
                if (j + 1 < len) j += 2; else j = len;
                emit_tok(out_toks, max_toks, &cnt, i, j - i, NPL_TOK_KEYWORD);
                i = j;
            } else {
                i++;
            }
        }
        if (out_count) *out_count = cnt;
        return NPL_STATE_NORMAL;
    }

    /* Perl POD state */
    if (lang == NPL_LANG_PERL) {
        if (start_state == NPL_STATE_PERL_POD) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            if (len >= 4 && memcmp(line, "=cut", 4) == 0 &&
                (len == 4 || npl_is_space((unsigned char)line[4]))) {
                return NPL_STATE_NORMAL;
            }
            return NPL_STATE_PERL_POD;
        }
        if (len >= 2 && line[0] == '=' && npl_is_alpha((unsigned char)line[1])) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            if (len >= 4 && memcmp(line, "=cut", 4) == 0) return NPL_STATE_NORMAL;
            return NPL_STATE_PERL_POD;
        }
    }

    size_t i = 0;
    uint8_t state = start_state;

    /* Continue active multiline states */
    if (state == NPL_STATE_BLOCK_CMT) {
        size_t s = 0;
        while (i + 1 < len) {
            if (line[i] == '*' && line[i + 1] == '/') {
                i += 2;
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_COMMENT);
                state = NPL_STATE_NORMAL;
                break;
            }
            i++;
        }
        if (state == NPL_STATE_BLOCK_CMT) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            return NPL_STATE_BLOCK_CMT;
        }
    } else if (state == NPL_STATE_PY_DQUOTE || state == NPL_STATE_PY_SQUOTE) {
        char q = (state == NPL_STATE_PY_DQUOTE) ? '"' : '\'';
        size_t s = 0;
        while (i + 2 < len) {
            if (line[i] == '\\' && i + 1 < len) { i += 2; continue; }
            if (line[i] == q && line[i + 1] == q && line[i + 2] == q) {
                i += 3;
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_STRING);
                state = NPL_STATE_NORMAL;
                break;
            }
            i++;
        }
        if (state != NPL_STATE_NORMAL) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_STRING);
            if (out_count) *out_count = cnt;
            return state;
        }
    } else if (state == NPL_STATE_LUA_CMT) {
        size_t s = 0;
        while (i + 1 < len) {
            if (line[i] == ']' && line[i + 1] == ']') {
                i += 2;
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_COMMENT);
                state = NPL_STATE_NORMAL;
                break;
            }
            i++;
        }
        if (state == NPL_STATE_LUA_CMT) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            return NPL_STATE_LUA_CMT;
        }
    } else if (state == NPL_STATE_BACKTICK) {
        size_t s = 0;
        while (i < len) {
            if (line[i] == '\\' && lang != NPL_LANG_GO && i + 1 < len) { i += 2; continue; }
            if (line[i] == '`') {
                i++;
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_STRING);
                state = NPL_STATE_NORMAL;
                break;
            }
            i++;
        }
        if (state == NPL_STATE_BACKTICK) {
            emit_tok(out_toks, max_toks, &cnt, 0, len, NPL_TOK_STRING);
            if (out_count) *out_count = cnt;
            return NPL_STATE_BACKTICK;
        }
    }

    if (lang == NPL_LANG_TEXT) {
        if (out_count) *out_count = cnt;
        return NPL_STATE_NORMAL;
    }

    if (lang == NPL_LANG_ASM) {
        uint8_t ast = lex_asm_line(line, len, i, out_toks, max_toks, &cnt);
        if (out_count) *out_count = cnt;
        return ast;
    }

    /* Leading preprocessor / Makefile targets / YAML keys / SPIR-V line comment */
    size_t first_nonspace = i;
    while (first_nonspace < len && npl_is_space((unsigned char)line[first_nonspace])) {
        first_nonspace++;
    }
    if (lang == NPL_LANG_GLSL && first_nonspace < len && line[first_nonspace] == ';') {
        emit_tok(out_toks, max_toks, &cnt, first_nonspace, len - first_nonspace, NPL_TOK_COMMENT);
        if (out_count) *out_count = cnt;
        return state;
    }
    if (is_preproc_c_lang(lang) &&
        first_nonspace < len && line[first_nonspace] == '#') {
        size_t j = first_nonspace + 1;
        while (j < len && npl_is_space((unsigned char)line[j])) j++;
        while (j < len && npl_is_ident_cont((unsigned char)line[j])) j++;
        emit_tok(out_toks, max_toks, &cnt, first_nonspace, j - first_nonspace, NPL_TOK_PREPROC);
        i = j;
    } else if (lang == NPL_LANG_MAKE && first_nonspace == 0 && len > 0 && line[0] != '\t' && line[0] != '#') {
        const char *colon = (const char *)memchr(line, ':', len);
        const char *eq = (const char *)memchr(line, '=', len);
        if (colon && (!eq || colon < eq)) {
            size_t clen = (size_t)(colon - line);
            emit_tok(out_toks, max_toks, &cnt, 0, clen, NPL_TOK_TAG);
            i = clen + 1;
        }
    } else if (lang == NPL_LANG_YAML && first_nonspace < len && line[first_nonspace] != '#') {
        size_t j = first_nonspace;
        if (line[j] == '-' && j + 1 < len && line[j + 1] == ' ') j += 2;
        size_t kstart = j;
        while (j < len && line[j] != ':' && line[j] != '#') j++;
        if (j > kstart && j < len && line[j] == ':' && (j + 1 == len || npl_is_space((unsigned char)line[j + 1]))) {
            emit_tok(out_toks, max_toks, &cnt, kstart, j - kstart, NPL_TOK_TAG);
            i = j + 1;
        }
    }

    /* Main line scan */
    while (i < len) {
        unsigned char c = (unsigned char)line[i];

        if (npl_is_space(c)) {
            i++;
            continue;
        }

        /* Comments */
        if (is_c_family(lang) && i + 1 < len && line[i] == '/' && line[i + 1] == '/') {
            emit_tok(out_toks, max_toks, &cnt, i, len - i, NPL_TOK_COMMENT);
            break;
        }
        if ((is_c_family(lang) || lang == NPL_LANG_SQL) && i + 1 < len && line[i] == '/' && line[i + 1] == '*') {
            size_t s = i;
            i += 2;
            int closed = 0;
            while (i + 1 < len) {
                if (line[i] == '*' && line[i + 1] == '/') {
                    i += 2;
                    closed = 1;
                    break;
                }
                i++;
            }
            if (!closed) {
                emit_tok(out_toks, max_toks, &cnt, s, len - s, NPL_TOK_COMMENT);
                state = NPL_STATE_BLOCK_CMT;
                break;
            }
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_COMMENT);
            continue;
        }
        if (lang == NPL_LANG_SQL && i + 1 < len && line[i] == '-' && line[i + 1] == '-') {
            emit_tok(out_toks, max_toks, &cnt, i, len - i, NPL_TOK_COMMENT);
            break;
        }
        if (lang == NPL_LANG_LUA && i + 1 < len && line[i] == '-' && line[i + 1] == '-') {
            if (i + 3 < len && line[i + 2] == '[' && line[i + 3] == '[') {
                size_t s = i;
                i += 4;
                int closed = 0;
                while (i + 1 < len) {
                    if (line[i] == ']' && line[i + 1] == ']') {
                        i += 2;
                        closed = 1;
                        break;
                    }
                    i++;
                }
                if (!closed) {
                    emit_tok(out_toks, max_toks, &cnt, s, len - s, NPL_TOK_COMMENT);
                    state = NPL_STATE_LUA_CMT;
                    break;
                }
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_COMMENT);
                continue;
            }
            emit_tok(out_toks, max_toks, &cnt, i, len - i, NPL_TOK_COMMENT);
            break;
        }
        if (is_hash_comment_lang(lang) && c == '#') {
            emit_tok(out_toks, max_toks, &cnt, i, len - i, NPL_TOK_COMMENT);
            break;
        }

        /* Python triple-quoted strings */
        if (lang == NPL_LANG_PYTHON && i + 2 < len &&
            ((c == '"' && line[i + 1] == '"' && line[i + 2] == '"') ||
             (c == '\'' && line[i + 1] == '\'' && line[i + 2] == '\''))) {
            unsigned char q = c;
            size_t s = i;
            i += 3;
            int closed = 0;
            while (i + 2 < len) {
                if (line[i] == '\\' && i + 1 < len) { i += 2; continue; }
                if ((unsigned char)line[i] == q && (unsigned char)line[i + 1] == q &&
                    (unsigned char)line[i + 2] == q) {
                    i += 3;
                    closed = 1;
                    break;
                }
                i++;
            }
            if (!closed) {
                emit_tok(out_toks, max_toks, &cnt, s, len - s, NPL_TOK_STRING);
                state = (q == '"') ? NPL_STATE_PY_DQUOTE : NPL_STATE_PY_SQUOTE;
                break;
            }
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_STRING);
            continue;
        }

        /* Backtick multiline strings in Go/JS/TS */
        if ((lang == NPL_LANG_GO || lang == NPL_LANG_JS || lang == NPL_LANG_TS) && c == '`') {
            size_t s = i++;
            int closed = 0;
            while (i < len) {
                if (line[i] == '\\' && lang != NPL_LANG_GO && i + 1 < len) { i += 2; continue; }
                if (line[i] == '`') { i++; closed = 1; break; }
                i++;
            }
            emit_tok(out_toks, max_toks, &cnt, s, (closed ? i : len) - s, NPL_TOK_STRING);
            if (!closed) {
                state = NPL_STATE_BACKTICK;
                break;
            }
            continue;
        }

        /* Quoted strings */
        if (c == '"' || (c == '\'' && lang != NPL_LANG_JSON && lang != NPL_LANG_RUST)) {
            size_t end = (lang == NPL_LANG_SQL && c == '\'')
                ? scan_quoted_doubled(line, len, i, c)
                : scan_quoted(line, len, i, c);
            npl_tok_type_t tt = NPL_TOK_STRING;
            if (lang == NPL_LANG_JSON) {
                size_t k = end;
                while (k < len && npl_is_space((unsigned char)line[k])) k++;
                if (k < len && line[k] == ':') tt = NPL_TOK_TAG;
            }
            emit_tok(out_toks, max_toks, &cnt, i, end - i, tt);
            i = end;
            continue;
        }

        /* SQL host variables (:var / @var) and SPIR-V %id SSA values */
        if (lang == NPL_LANG_SQL && (c == ':' || c == '@') && i + 1 < len &&
            npl_is_ident_start((unsigned char)line[i + 1])) {
            size_t s = i++;
            while (i < len && npl_is_ident_cont((unsigned char)line[i])) i++;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_VAR);
            continue;
        }
        if (lang == NPL_LANG_GLSL && c == '%' && i + 1 < len &&
            (npl_is_ident_cont((unsigned char)line[i + 1]))) {
            size_t s = i++;
            while (i < len && npl_is_ident_cont((unsigned char)line[i])) i++;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_VAR);
            continue;
        }
        /* Metal [[attribute]] markers */
        if (lang == NPL_LANG_METAL && c == '[' && i + 1 < len && line[i + 1] == '[') {
            size_t s = i;
            i += 2;
            while (i + 1 < len && !(line[i] == ']' && line[i + 1] == ']')) i++;
            if (i + 1 < len) i += 2; else i = len;
            emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_TAG);
            continue;
        }

        /* Perl / Shell / Tcl / Make sigil variables */
        if ((lang == NPL_LANG_PERL && (c == '$' || c == '@' || c == '%')) ||
            ((lang == NPL_LANG_SH || lang == NPL_LANG_TCL || lang == NPL_LANG_MAKE) && c == '$')) {
            size_t s = i++;
            if (i < len && (line[i] == '{' || line[i] == '(')) {
                char close_ch = (line[i] == '{') ? '}' : ')';
                i++;
                while (i < len && line[i] != close_ch) i++;
                if (i < len) i++;
            } else {
                if (i < len && (line[i] == '#' || line[i] == '^')) i++;
                while (i < len && (npl_is_ident_cont((unsigned char)line[i]) || line[i] == ':')) i++;
            }
            if (i > s + 1) {
                emit_tok(out_toks, max_toks, &cnt, s, i - s, NPL_TOK_VAR);
                continue;
            }
            i = s + 1;
            emit_tok(out_toks, max_toks, &cnt, s, 1, NPL_TOK_OPERATOR);
            continue;
        }

        /* Numbers */
        if (npl_is_digit(c)) {
            size_t end = scan_number(line, len, i);
            emit_tok(out_toks, max_toks, &cnt, i, end - i, NPL_TOK_NUMBER);
            i = end;
            continue;
        }

        /* Identifiers / keywords / types / functions */
        if (npl_is_ident_start(c)) {
            size_t s = i++;
            while (i < len && npl_is_ident_cont((unsigned char)line[i])) i++;
            size_t wlen = i - s;
            npl_tok_type_t tt = NPL_TOK_NORMAL;

            if (lang == NPL_LANG_PERL) {
                if (word_in_list(line + s, wlen, KW_PERL)) tt = NPL_TOK_KEYWORD;
            } else if (lang == NPL_LANG_C) {
                if (word_in_list(line + s, wlen, KW_C)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_C)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_CPP) {
                if (word_in_list(line + s, wlen, KW_CPP)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_C)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_XS) {
                if (word_in_list(line + s, wlen, KW_XS_SECT)) tt = NPL_TOK_TAG;
                else if (word_in_list(line + s, wlen, KW_C)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_C)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_RUST) {
                if (word_in_list(line + s, wlen, KW_RUST)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_RUST)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_GO) {
                if (word_in_list(line + s, wlen, KW_GO)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_GO)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_PYTHON) {
                if (word_in_list(line + s, wlen, KW_PYTHON)) tt = NPL_TOK_KEYWORD;
            } else if (lang == NPL_LANG_JS) {
                if (word_in_list(line + s, wlen, KW_JS)) tt = NPL_TOK_KEYWORD;
            } else if (lang == NPL_LANG_TS) {
                if (word_in_list(line + s, wlen, KW_JS)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, KW_TS_EXTRA)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_LUA) {
                if (word_in_list(line + s, wlen, KW_LUA)) tt = NPL_TOK_KEYWORD;
            } else if (lang == NPL_LANG_JSON || lang == NPL_LANG_YAML) {
                if ((wlen == 4 && memcmp(line + s, "true", 4) == 0) ||
                    (wlen == 5 && memcmp(line + s, "false", 5) == 0) ||
                    (wlen == 4 && memcmp(line + s, "null", 4) == 0)) {
                    tt = NPL_TOK_CONSTANT;
                }
            } else if (lang == NPL_LANG_SH) {
                if (word_in_list(line + s, wlen, KW_SH)) tt = NPL_TOK_KEYWORD;
            } else if (lang == NPL_LANG_TCL) {
                if (word_in_list(line + s, wlen, KW_TCL)) tt = NPL_TOK_KEYWORD;
            } else if (lang == NPL_LANG_MAKE) {
                if (word_in_list(line + s, wlen, KW_MAKE)) tt = NPL_TOK_KEYWORD;
            } else if (lang == NPL_LANG_SQL) {
                if (word_in_list_ci(line + s, wlen, KW_SQL)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list_ci(line + s, wlen, TYPE_SQL)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_SYCL) {
                if (word_in_list(line + s, wlen, KW_SYCL) || word_in_list(line + s, wlen, KW_CPP)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_SYCL) || word_in_list(line + s, wlen, TYPE_C)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_HIP) {
                if (word_in_list(line + s, wlen, KW_HIP) || word_in_list(line + s, wlen, KW_CPP)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, VAR_HIP)) tt = NPL_TOK_VAR;
                else if (word_in_list(line + s, wlen, TYPE_HIP) || word_in_list(line + s, wlen, TYPE_C)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_GLSL) {
                if (wlen >= 3 && memcmp(line + s, "gl_", 3) == 0) tt = NPL_TOK_VAR;
                else if (word_in_list(line + s, wlen, KW_GLSL)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_GLSL)) tt = NPL_TOK_TYPE;
            } else if (lang == NPL_LANG_METAL) {
                if (word_in_list(line + s, wlen, KW_METAL) || word_in_list(line + s, wlen, KW_CPP)) tt = NPL_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_METAL) || word_in_list(line + s, wlen, TYPE_C)) tt = NPL_TOK_TYPE;
            }

            if (tt == NPL_TOK_NORMAL) {
                /* Function call heuristic */
                size_t k = i;
                while (k < len && (line[k] == ' ' || line[k] == '\t')) k++;
                if (k < len && line[k] == '(') {
                    tt = NPL_TOK_FUNC;
                } else if (wlen >= 2) {
                    /* ALL_CAPS constant heuristic */
                    int all_upper = 1;
                    int has_upper = 0;
                    for (size_t j = 0; j < wlen; j++) {
                        unsigned char u = (unsigned char)line[s + j];
                        if (u >= 'A' && u <= 'Z') has_upper = 1;
                        else if (!npl_is_digit(u) && u != '_') { all_upper = 0; break; }
                    }
                    if (all_upper && has_upper) tt = NPL_TOK_CONSTANT;
                }
            }

            if (tt != NPL_TOK_NORMAL) {
                emit_tok(out_toks, max_toks, &cnt, s, wlen, tt);
            }
            continue;
        }

        /* Operators */
        if (strchr("+-*/%=!<>&|^~?:", (int)c) != NULL) {
            emit_tok(out_toks, max_toks, &cnt, i, 1, NPL_TOK_OPERATOR);
        }
        i++;
    }

    if (out_count) *out_count = cnt;
    return state;
}

void
npl_syntax_sync(npl_buf_t *buf, npl_syntax_t *syn, size_t upto_line)
{
    if (!buf || !syn) return;
    size_t total = npl_buf_line_count(buf);
    if (upto_line > total) upto_line = total;
    if (upto_line == 0) {
        syn->last_relex_lines = 0;
        return;
    }

    if (upto_line > syn->state_cap) {
        size_t ncap = syn->state_cap ? syn->state_cap * 2 : 256;
        while (ncap < upto_line) ncap *= 2;
        uint8_t *ns = (uint8_t *)realloc(syn->states, ncap);
        if (!ns) return;
        syn->states = ns;
        syn->state_cap = ncap;
    }

    size_t start = syn->dirty_from;
    if (start > syn->state_count) start = syn->state_count;
    if (start >= upto_line) {
        syn->last_relex_lines = 0;
        return;
    }

    char stack_buf[4096];
    size_t relexed = 0;

    for (size_t line = start; line < upto_line; line++) {
        uint8_t prev_state = (line == 0) ? NPL_STATE_NORMAL : syn->states[line - 1];
        size_t llen = npl_buf_get_line_buf(buf, line, stack_buf, sizeof(stack_buf));
        char *heap_buf = NULL;
        const char *lptr = stack_buf;
        if (llen >= sizeof(stack_buf)) {
            heap_buf = npl_buf_get_line_alloc(buf, line, &llen);
            if (heap_buf) lptr = heap_buf;
        }
        uint8_t end_st = npl_syntax_lex_line(syn->lang, lptr, llen, prev_state, NULL, 0, NULL);
        free(heap_buf);
        relexed++;

        int converged = (line < syn->state_count && syn->states[line] == end_st);
        syn->states[line] = end_st;
        if (line >= syn->state_count) syn->state_count = line + 1;
        if (converged && line > start) {
            syn->dirty_from = syn->state_count;
            syn->last_relex_lines = relexed;
            return;
        }
    }

    syn->dirty_from = upto_line;
    syn->last_relex_lines = relexed;
}

/* Symbol outline extractor */
static int
sym_push(npl_symbol_list_t *list, const char *name, size_t nlen,
         const char *kind, size_t line, size_t col)
{
    if (nlen == 0) return 1;
    if (list->count >= list->cap) {
        size_t ncap = list->cap ? list->cap * 2 : 32;
        npl_symbol_t *ni = (npl_symbol_t *)realloc(list->items, ncap * sizeof(npl_symbol_t));
        if (!ni) return 0;
        list->items = ni;
        list->cap = ncap;
    }
    char *nc = (char *)malloc(nlen + 1);
    size_t klen = strlen(kind);
    char *kc = (char *)malloc(klen + 1);
    if (!nc || !kc) {
        free(nc);
        free(kc);
        return 0;
    }
    memcpy(nc, name, nlen);
    nc[nlen] = '\0';
    memcpy(kc, kind, klen + 1);

    npl_symbol_t *s = &list->items[list->count++];
    s->name = nc;
    s->kind = kc;
    s->line = line;
    s->col = col;
    return 1;
}

static void
extract_symbol_from_line(npl_lang_t lang, const char *line, size_t len,
                         size_t line_idx, npl_symbol_list_t *out)
{
    size_t p = 0;
    while (p < len && (line[p] == ' ' || line[p] == '\t')) p++;
    if (p >= len) return;

    if (lang == NPL_LANG_PERL) {
        if (p + 8 < len && memcmp(line + p, "package ", 8) == 0) {
            size_t s = p + 8;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            size_t e = s;
            while (e < len && (npl_is_ident_cont((unsigned char)line[e]) || line[e] == ':')) e++;
            sym_push(out, line + s, e - s, "package", line_idx, s);
        } else if (p + 4 < len && memcmp(line + p, "sub ", 4) == 0) {
            size_t s = p + 4;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, "sub", line_idx, s);
        } else if (p + 13 < len && memcmp(line + p, "use constant ", 13) == 0) {
            size_t s = p + 13;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            if (s < len && npl_is_ident_start((unsigned char)line[s])) {
                size_t e = s;
                while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
                sym_push(out, line + s, e - s, "constant", line_idx, s);
            }
        }
    } else if (lang == NPL_LANG_C || lang == NPL_LANG_CPP || lang == NPL_LANG_XS ||
               lang == NPL_LANG_SYCL || lang == NPL_LANG_HIP ||
               lang == NPL_LANG_GLSL || lang == NPL_LANG_METAL) {
        if (line[p] == '#') {
            size_t s = p + 1;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            if (s + 7 < len && memcmp(line + s, "define ", 7) == 0) {
                s += 7;
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
                size_t e = s;
                while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
                sym_push(out, line + s, e - s, "macro", line_idx, s);
            }
            return;
        }
        if (lang == NPL_LANG_XS && p + 7 < len && memcmp(line + p, "MODULE ", 7) == 0) {
            sym_push(out, line + p, len - p, "module", line_idx, p);
            return;
        }
        if (p + 7 < len && memcmp(line + p, "struct ", 7) == 0) {
            size_t s = p + 7;
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            if (e > s && (e == len || line[e] == ' ' || line[e] == '{')) {
                sym_push(out, line + s, e - s, "struct", line_idx, s);
                return;
            }
        }
        if (lang == NPL_LANG_GLSL && starts_with_ci(line + p, len - p, "layout")) {
            /* GLSL interface block: layout(...) uniform/buffer BlockName */
            size_t s = p;
            const char *rp = (const char *)memchr(line + s, ')', len - s);
            if (rp) {
                s = (size_t)(rp - line) + 1;
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
                const char *bkind = NULL;
                if (s + 8 < len && memcmp(line + s, "uniform ", 8) == 0) { bkind = "uniform"; s += 8; }
                else if (s + 7 < len && memcmp(line + s, "buffer ", 7) == 0) { bkind = "buffer"; s += 7; }
                if (bkind) {
                    while (s < len && npl_is_space((unsigned char)line[s])) s++;
                    size_t e = s;
                    while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
                    if (e > s) {
                        sym_push(out, line + s, e - s, bkind, line_idx, s);
                        return;
                    }
                }
            }
        }
        /* Top-level function / GPU kernel definition heuristic (column 0, contains '(') */
        if (p == 0 && npl_is_ident_start((unsigned char)line[0])) {
            const char *lp = (const char *)memchr(line, '(', len);
            /* Skip __launch_bounds__(...) / __attribute__((...)) before actual function name */
            if (lp && (lang == NPL_LANG_HIP || lang == NPL_LANG_SYCL || lang == NPL_LANG_METAL)) {
                size_t scan = 0;
                while (scan < len) {
                    const char *next_lp = (const char *)memchr(line + scan, '(', len - scan);
                    if (!next_lp) break;
                    size_t e = (size_t)(next_lp - line);
                    while (e > 0 && npl_is_space((unsigned char)line[e - 1])) e--;
                    size_t s = e;
                    while (s > 0 && npl_is_ident_cont((unsigned char)line[s - 1])) s--;
                    size_t wlen = e - s;
                    if (wlen > 0 &&
                        (word_in_list(line + s, wlen, KW_HIP) ||
                         word_in_list(line + s, wlen, KW_SYCL) ||
                         word_in_list(line + s, wlen, KW_METAL))) {
                        int depth = 0;
                        size_t j = (size_t)(next_lp - line);
                        while (j < len) {
                            if (line[j] == '(') depth++;
                            else if (line[j] == ')') { depth--; if (depth == 0) { j++; break; } }
                            j++;
                        }
                        scan = j;
                        lp = (scan < len) ? (const char *)memchr(line + scan, '(', len - scan) : NULL;
                        continue;
                    }
                    lp = next_lp;
                    break;
                }
            }
            if (lp && lp > line && !memchr(line, ';', (size_t)(lp - line))) {
                size_t e = (size_t)(lp - line);
                while (e > 0 && npl_is_space((unsigned char)line[e - 1])) e--;
                size_t s = e;
                while (s > 0 && npl_is_ident_cont((unsigned char)line[s - 1])) s--;
                size_t wlen = e - s;
                if (wlen > 0 && !word_in_list(line + s, wlen, KW_C) &&
                    !(lang == NPL_LANG_GLSL && word_in_list(line + s, wlen, KW_GLSL))) {
                    const char *kind = "function";
                    if ((lang == NPL_LANG_HIP && starts_with_ci(line, len, "__global__")) ||
                        (lang == NPL_LANG_SYCL && (starts_with_ci(line, len, "__kernel") || starts_with_ci(line, len, "kernel "))) ||
                        (lang == NPL_LANG_METAL && (starts_with_ci(line, len, "kernel ") || starts_with_ci(line, len, "vertex ") || starts_with_ci(line, len, "fragment ")))) {
                        kind = "kernel";
                    }
                    sym_push(out, line + s, wlen, kind, line_idx, s);
                }
            }
        }
    } else if (lang == NPL_LANG_RUST) {
        size_t s = p;
        if (s + 4 < len && memcmp(line + s, "pub ", 4) == 0) s += 4;
        if (s + 6 < len && memcmp(line + s, "async ", 6) == 0) s += 6;
        const char *kind = NULL;
        if (s + 3 < len && memcmp(line + s, "fn ", 3) == 0) { kind = "fn"; s += 3; }
        else if (s + 7 < len && memcmp(line + s, "struct ", 7) == 0) { kind = "struct"; s += 7; }
        else if (s + 5 < len && memcmp(line + s, "enum ", 5) == 0) { kind = "enum"; s += 5; }
        else if (s + 6 < len && memcmp(line + s, "trait ", 6) == 0) { kind = "trait"; s += 6; }
        if (kind) {
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, kind, line_idx, s);
        }
    } else if (lang == NPL_LANG_GO) {
        if (p + 5 < len && memcmp(line + p, "func ", 5) == 0) {
            size_t s = p + 5;
            if (s < len && line[s] == '(') {
                while (s < len && line[s] != ')') s++;
                if (s < len) s++;
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
            }
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, "func", line_idx, s);
        } else if (p + 5 < len && memcmp(line + p, "type ", 5) == 0) {
            size_t s = p + 5;
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, "type", line_idx, s);
        }
    } else if (lang == NPL_LANG_PYTHON) {
        size_t s = p;
        if (s + 6 < len && memcmp(line + s, "async ", 6) == 0) s += 6;
        const char *kind = NULL;
        if (s + 4 < len && memcmp(line + s, "def ", 4) == 0) { kind = "def"; s += 4; }
        else if (s + 6 < len && memcmp(line + s, "class ", 6) == 0) { kind = "class"; s += 6; }
        if (kind) {
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, kind, line_idx, s);
        }
    } else if (lang == NPL_LANG_JS || lang == NPL_LANG_TS) {
        size_t s = p;
        if (s + 7 < len && memcmp(line + s, "export ", 7) == 0) s += 7;
        if (s + 6 < len && memcmp(line + s, "async ", 6) == 0) s += 6;
        const char *kind = NULL;
        if (s + 9 < len && memcmp(line + s, "function ", 9) == 0) { kind = "function"; s += 9; }
        else if (s + 6 < len && memcmp(line + s, "class ", 6) == 0) { kind = "class"; s += 6; }
        else if (s + 10 < len && memcmp(line + s, "interface ", 10) == 0) { kind = "interface"; s += 10; }
        if (kind) {
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, kind, line_idx, s);
        }
    } else if (lang == NPL_LANG_LUA) {
        size_t s = p;
        if (s + 6 < len && memcmp(line + s, "local ", 6) == 0) s += 6;
        if (s + 9 < len && memcmp(line + s, "function ", 9) == 0) {
            s += 9;
            size_t e = s;
            while (e < len && (npl_is_ident_cont((unsigned char)line[e]) || line[e] == '.' || line[e] == ':')) e++;
            sym_push(out, line + s, e - s, "function", line_idx, s);
        }
    } else if (lang == NPL_LANG_TCL) {
        if (p + 5 < len && memcmp(line + p, "proc ", 5) == 0) {
            size_t s = p + 5;
            size_t e = s;
            while (e < len && !npl_is_space((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, "proc", line_idx, s);
        }
    } else if (lang == NPL_LANG_SH) {
        if (p + 9 < len && memcmp(line + p, "function ", 9) == 0) {
            size_t s = p + 9;
            size_t e = s;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            sym_push(out, line + s, e - s, "function", line_idx, s);
        } else if (npl_is_ident_start((unsigned char)line[p])) {
            size_t e = p;
            while (e < len && npl_is_ident_cont((unsigned char)line[e])) e++;
            if (e + 1 < len && line[e] == '(' && line[e + 1] == ')') {
                sym_push(out, line + p, e - p, "function", line_idx, p);
            }
        }
    } else if (lang == NPL_LANG_MARKDOWN) {
        if (line[p] == '#') {
            size_t s = p;
            while (s < len && line[s] == '#') s++;
            while (s < len && line[s] == ' ') s++;
            if (s < len) {
                sym_push(out, line + s, len - s, "heading", line_idx, s);
            }
        }
    } else if (lang == NPL_LANG_MAKE) {
        if (p == 0 && line[0] != '\t' && line[0] != '#' && line[0] != '.') {
            const char *colon = (const char *)memchr(line, ':', len);
            const char *eq = (const char *)memchr(line, '=', len);
            if (colon && (!eq || colon < eq)) {
                size_t e = (size_t)(colon - line);
                while (e > 0 && npl_is_space((unsigned char)line[e - 1])) e--;
                sym_push(out, line, e, "target", line_idx, 0);
            }
        }
    } else if (lang == NPL_LANG_SQL) {
        if (starts_with_ci(line + p, len - p, "create ")) {
            size_t s = p + 7;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            if (starts_with_ci(line + s, len - s, "or ")) {
                s += 3;
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
                if (starts_with_ci(line + s, len - s, "replace ")) {
                    s += 8;
                    while (s < len && npl_is_space((unsigned char)line[s])) s++;
                }
            }
            if (starts_with_ci(line + s, len - s, "unique ")) {
                s += 7;
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
            }
            if (starts_with_ci(line + s, len - s, "temp ") || starts_with_ci(line + s, len - s, "temporary ")) {
                while (s < len && !npl_is_space((unsigned char)line[s])) s++;
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
            }
            const char *kind = NULL;
            if (starts_with_ci(line + s, len - s, "table "))          { kind = "table"; s += 6; }
            else if (starts_with_ci(line + s, len - s, "view "))      { kind = "view"; s += 5; }
            else if (starts_with_ci(line + s, len - s, "index "))     { kind = "index"; s += 6; }
            else if (starts_with_ci(line + s, len - s, "procedure ")) { kind = "procedure"; s += 10; }
            else if (starts_with_ci(line + s, len - s, "function "))  { kind = "function"; s += 9; }
            else if (starts_with_ci(line + s, len - s, "trigger "))   { kind = "trigger"; s += 8; }
            else if (starts_with_ci(line + s, len - s, "schema "))    { kind = "schema"; s += 7; }
            if (kind) {
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
                if (starts_with_ci(line + s, len - s, "if ")) {
                    /* skip IF NOT EXISTS */
                    for (int k = 0; k < 3 && s < len; k++) {
                        while (s < len && !npl_is_space((unsigned char)line[s])) s++;
                        while (s < len && npl_is_space((unsigned char)line[s])) s++;
                    }
                }
                size_t e = s;
                while (e < len && (npl_is_ident_cont((unsigned char)line[e]) ||
                                   line[e] == '.' || line[e] == '/' || line[e] == '$')) e++;
                sym_push(out, line + s, e - s, kind, line_idx, s);
            }
        }
    } else if (lang == NPL_LANG_HLASM) {
        if (len > 0 && line[0] != '*' && line[0] != '.' && line[0] != '&' && !npl_is_space((unsigned char)line[0])) {
            size_t e = 0;
            while (e < len && !npl_is_space((unsigned char)line[e])) e++;
            size_t op_s = e;
            while (op_s < len && npl_is_space((unsigned char)line[op_s])) op_s++;
            size_t op_e = op_s;
            while (op_e < len && !npl_is_space((unsigned char)line[op_e])) op_e++;
            size_t olen = op_e - op_s;
            const char *kind = "label";
            if ((olen == 5 && (starts_with_ci(line + op_s, olen, "csect") ||
                               starts_with_ci(line + op_s, olen, "rsect") ||
                               starts_with_ci(line + op_s, olen, "start")))) {
                kind = "csect";
            } else if (olen == 5 && starts_with_ci(line + op_s, olen, "dsect")) {
                kind = "dsect";
            } else if (olen == 3 && starts_with_ci(line + op_s, olen, "equ")) {
                kind = "equ";
            } else if (olen == 5 && starts_with_ci(line + op_s, olen, "macro")) {
                kind = "macro";
            } else if (olen == 2 && (starts_with_ci(line + op_s, olen, "ds") ||
                                     starts_with_ci(line + op_s, olen, "dc"))) {
                kind = "field";
            }
            sym_push(out, line, e, kind, line_idx, 0);
        }
    } else if (lang == NPL_LANG_ASM) {
        /* Objdump header: 0000000000000040 <dot_f32_vsx>: */
        const char *lt = (const char *)memchr(line + p, '<', len - p);
        if (lt && lt > line + p) {
            const char *gt = (const char *)memchr(lt + 1, '>', len - (size_t)(lt + 1 - line));
            if (gt && gt + 1 < line + len && gt[1] == ':') {
                sym_push(out, lt + 1, (size_t)(gt - (lt + 1)), "function", line_idx, (size_t)(lt + 1 - line));
                return;
            }
        }
        /* Normal label: foo: (skip .L* compiler local labels) */
        if (npl_is_ident_start((unsigned char)line[p])) {
            size_t e = p;
            while (e < len && (npl_is_ident_cont((unsigned char)line[e]) || line[e] == '.')) e++;
            if (e < len && line[e] == ':') {
                sym_push(out, line + p, e - p, "label", line_idx, p);
            }
        }
    } else if (lang == NPL_LANG_RPGILE) {
        const char *kind = NULL;
        size_t s = p;
        if (starts_with_ci(line + s, len - s, "dcl-proc "))      { kind = "proc";  s += 9; }
        else if (starts_with_ci(line + s, len - s, "dcl-ds "))   { kind = "ds";    s += 7; }
        else if (starts_with_ci(line + s, len - s, "dcl-pr "))   { kind = "proto"; s += 7; }
        else if (starts_with_ci(line + s, len - s, "dcl-f "))    { kind = "file";  s += 6; }
        else if (starts_with_ci(line + s, len - s, "begsr "))    { kind = "subr";  s += 6; }
        if (kind) {
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            size_t e = s;
            while (e < len && (npl_is_ident_cont((unsigned char)line[e]) || line[e] == '-')) e++;
            if (e > s) sym_push(out, line + s, e - s, kind, line_idx, s);
        }
    } else if (lang == NPL_LANG_COBOL) {
        /* Skip fixed-format col-7 comments and free-format inline comments */
        if (len >= 7 && (line[6] == '*' || line[6] == '/')) {
            int ok_pfx = 1;
            for (size_t k = 0; k < 6; k++) {
                if (line[k] != ' ' && !npl_is_digit((unsigned char)line[k])) { ok_pfx = 0; break; }
            }
            if (ok_pfx) return;
        }
        size_t s = p;
        if (s + 1 < len && line[s] == '*' && line[s + 1] == '>') return;
        /* Skip optional 6-digit fixed-format sequence number */
        if (p == 0 && len > 7) {
            int seq6 = 1;
            for (size_t k = 0; k < 6; k++) {
                if (!npl_is_digit((unsigned char)line[k])) { seq6 = 0; break; }
            }
            if (seq6) {
                s = 7;
                while (s < len && npl_is_space((unsigned char)line[s])) s++;
            }
        }
        if (s >= len) return;

        if (starts_with_ci(line + s, len - s, "program-id.")) {
            s += 11;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            size_t e = s;
            while (e < len && (npl_is_ident_cont((unsigned char)line[e]) || line[e] == '-')) e++;
            sym_push(out, line + s, e - s, "program", line_idx, s);
            return;
        }
        if (s + 3 < len && line[s] == '0' && line[s + 1] == '1' && npl_is_space((unsigned char)line[s + 2])) {
            s += 3;
            while (s < len && npl_is_space((unsigned char)line[s])) s++;
            size_t e = s;
            while (e < len && (npl_is_ident_cont((unsigned char)line[e]) || line[e] == '-')) e++;
            if (e > s && !(e - s == 6 && starts_with_ci(line + s, 6, "filler"))) {
                sym_push(out, line + s, e - s, "record", line_idx, s);
            }
            return;
        }
        /* <NAME> DIVISION. / <NAME> SECTION. / <PARAGRAPH>. */
        size_t e = s;
        while (e < len && (npl_is_ident_cont((unsigned char)line[e]) || line[e] == '-')) e++;
        if (e > s) {
            size_t nlen = e - s;
            size_t q = e;
            while (q < len && npl_is_space((unsigned char)line[q])) q++;
            if (starts_with_ci(line + q, len - q, "division")) {
                sym_push(out, line + s, nlen, "division", line_idx, s);
            } else if (starts_with_ci(line + q, len - q, "section")) {
                sym_push(out, line + s, nlen, "section", line_idx, s);
            } else if (e < len && line[e] == '.') {
                size_t tail = e + 1;
                while (tail < len && npl_is_space((unsigned char)line[tail])) tail++;
                if (tail == len && !word_in_list_ci(line + s, nlen, KW_COBOL)) {
                    sym_push(out, line + s, nlen, "paragraph", line_idx, s);
                }
            }
        }
    }
}

int
npl_syntax_extract_symbols_buf(npl_buf_t *buf, npl_lang_t lang, npl_symbol_list_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!buf) return 0;
    size_t total = npl_buf_line_count(buf);
    char stack_buf[4096];
    for (size_t line = 0; line < total; line++) {
        size_t llen = npl_buf_get_line_buf(buf, line, stack_buf, sizeof(stack_buf));
        char *heap_buf = NULL;
        const char *lptr = stack_buf;
        if (llen >= sizeof(stack_buf)) {
            heap_buf = npl_buf_get_line_alloc(buf, line, &llen);
            if (heap_buf) lptr = heap_buf;
        }
        extract_symbol_from_line(lang, lptr, llen, line, out);
        free(heap_buf);
    }
    return 1;
}

int
npl_syntax_extract_symbols_text(const char *text, size_t len, npl_lang_t lang, npl_symbol_list_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!text || len == 0) return 1;
    size_t pos = 0;
    size_t line_idx = 0;
    while (pos <= len) {
        const char *nl = (pos < len) ? (const char *)memchr(text + pos, '\n', len - pos) : NULL;
        size_t end = nl ? (size_t)(nl - text) : len;
        size_t llen = end - pos;
        if (llen > 0 && text[pos + llen - 1] == '\r') llen--;
        extract_symbol_from_line(lang, text + pos, llen, line_idx, out);
        line_idx++;
        if (!nl) break;
        pos = end + 1;
        if (pos == len) break;
    }
    return 1;
}

void
npl_symbol_list_free(npl_symbol_list_t *list)
{
    if (!list) return;
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i].name);
        free(list->items[i].kind);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->cap = 0;
}
