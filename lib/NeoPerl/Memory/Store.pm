package NeoPerl::Memory::Store;

use strict;
use warnings;
use Carp qw(croak);
use File::Spec ();
use File::Basename qw(dirname);
use Scalar::Util qw(looks_like_number);

our $VERSION = '0.01';

our $HAS_DBI;
BEGIN {
    $HAS_DBI = eval { require DBI; 1 } ? 1 : 0;
}

our $DEFAULT_DIM = 768;

my %VALID_SCOPES = map { $_ => 1 } qw(global repo file symbol);
my %VALID_CATS   = map { $_ => 1 } qw(preference architecture gotcha convention decision fact);
my %VALID_RELS   = map { $_ => 1 } qw(relates_to contradicts extends applies_to supersedes);

my %SCOPE_WEIGHT = (
    symbol => 0.12,
    file   => 0.08,
    repo   => 0.04,
    global => 0.00,
);

sub _has_dbi_mt_pool {
    return eval { require DBI::MT::Pool; 1 } ? 1 : 0;
}

sub _has_vec_simd {
    return eval { require NeoPerl::Core; 1 }
        && defined(&NeoPerl::Core::VecSIMD::cosine_f32);
}

sub simd_backend {
    return eval { require NeoPerl::Core; NeoPerl::Core::VecSIMD::simd_backend() } || 'perl';
}

sub new {
    my ($class, %args) = @_;

    my $dsn = $args{dsn};
    if (!defined $dsn || !length $dsn) {
        my $path = $args{sqlite_path} // ':memory:';
        $dsn = "dbi:SQLite:dbname=$path";
    }

    my $dialect = $args{dialect};
    if (!defined $dialect) {
        if ($dsn =~ /^dbi:(?:ODBC|DB2):/i) {
            $dialect = (exists $args{db2_vector} && !$args{db2_vector})
                ? 'db2_blob'
                : 'db2';
        }
        else {
            $dialect = 'sqlite';
        }
    }

    my $dim = $args{dim} || $DEFAULT_DIM;
    my $is_mem_sqlite = ($dialect eq 'sqlite' && $dsn =~ /:memory:/i) ? 1 : 0;

    my $pool = $args{pool};
    if (!$pool && !$args{sql_only}) {
        croak "NeoPerl::Memory::Store: DBI is required for live database connections"
            unless $HAS_DBI || eval { require DBI; $HAS_DBI = 1 };
        my %pool_opts = (
            dsn              => $dsn,
            user             => $args{user} // '',
            pass             => $args{pass} // '',
            attr             => {
                RaiseError => 1,
                PrintError => 0,
                AutoCommit => 1,
                ($dialect eq 'sqlite' ? (sqlite_unicode => 1) : ()),
                %{ $args{dbi_attr} || {} },
            },
            max_connections  => $is_mem_sqlite ? 1 : ($args{max_connections} || 4),
            ping_on_checkout => $is_mem_sqlite ? 0 : 1,
            idle_timeout     => $is_mem_sqlite ? 0 : 300,
            on_connect       => sub {
                my ($dbh) = @_;
                if ($dialect eq 'sqlite') {
                    eval { $dbh->do('PRAGMA foreign_keys = ON') };
                    eval { $dbh->do('PRAGMA busy_timeout = 5000') };
                    if (!$is_mem_sqlite) {
                        eval { $dbh->do('PRAGMA journal_mode = WAL') };
                    }
                }
            },
        );

        if (_has_dbi_mt_pool()) {
            $pool = DBI::MT::Pool->new(%pool_opts);
        }
        else {
            $pool = NeoPerl::Memory::Store::_FallbackPool->new(%pool_opts);
        }
    }

    my $self = bless {
        dsn          => $dsn,
        dialect      => $dialect,
        dim          => $dim,
        pool         => $pool,
        embedder     => $args{embedder},
        schema_dir   => $args{schema_dir},
        sql_only     => $args{sql_only} ? 1 : 0,
        db2_version  => $args{db2_version},
        using_mt_pool => ($pool && ref($pool) eq 'DBI::MT::Pool') ? 1 : 0,
    }, $class;

    if (!$self->{sql_only} && ($args{auto_init} // 1)) {
        if ($dialect eq 'db2' && !defined $self->{db2_version}) {
            $self->_probe_db2_vector_support();
        }
        $self->init_schema() if $dialect eq 'sqlite' || $args{init_schema};
    }

    return $self;
}

sub dsn           { $_[0]{dsn} }
sub dialect       { $_[0]{dialect} }
sub dim           { $_[0]{dim} }
sub pool          { $_[0]{pool} }
sub using_mt_pool { $_[0]{using_mt_pool} }
sub set_embedder  { $_[0]{embedder} = $_[1]; return $_[0] }

sub _probe_db2_vector_support {
    my ($self) = @_;
    return unless $self->{pool};
    my $ok = eval {
        $self->{pool}->with_dbh(sub {
            my ($dbh) = @_;
            my ($ver) = $dbh->selectrow_array(
                'SELECT SERVICE_LEVEL FROM SYSIBMADM.ENV_INST_INFO FETCH FIRST 1 ROWS ONLY'
            );
            $self->{db2_version} = $ver if defined $ver;
            # Probe VECTOR_DISTANCE availability on Db2 12.1.2+
            $dbh->selectrow_array(
                "SELECT VECTOR_DISTANCE(VECTOR('[1,0]', 2, REAL), VECTOR('[1,0]', 2, REAL), COSINE) FROM SYSIBM.SYSDUMMY1"
            );
            1;
        });
    };
    if (!$ok) {
        $self->{dialect} = 'db2_blob';
    }
    return $self->{dialect};
}

sub _find_schema_file {
    my ($self, $filename) = @_;
    my @candidates;
    if (defined $self->{schema_dir} && length $self->{schema_dir}) {
        push @candidates, File::Spec->catfile($self->{schema_dir}, $filename);
    }
    my $mod_dir = dirname(__FILE__);
    push @candidates,
        File::Spec->catfile($mod_dir, 'schema', $filename),
        File::Spec->catfile($mod_dir, '..', '..', '..', 'schema', $filename),
        File::Spec->catfile($mod_dir, '..', '..', '..', '..', 'schema', $filename),
        File::Spec->catfile('schema', $filename);

    for my $path (@candidates) {
        return $path if defined $path && -f $path;
    }
    return undef;
}

sub _embedded_schema_sql {
    my ($file) = @_;
    if ($file eq 'sqlite_test_double.sql') {
        return <<'END_SQLITE_SCHEMA';
-- SQLite CI Test Double Schema for NeoPerl::MT
-- Mirrors schema/db2_memory.sql with float32 little-endian BLOB embeddings
-- scored by NeoPerl::Core::VecSIMD for offline testing without a Db2 server.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS NPL_MEMORIES (
    ID               INTEGER PRIMARY KEY AUTOINCREMENT,
    SCOPE_LEVEL      TEXT    NOT NULL CHECK (SCOPE_LEVEL IN ('global', 'repo', 'file', 'symbol')),
    REPO_KEY         TEXT,
    FILE_PATH        TEXT,
    SYMBOL_NAME      TEXT,
    CATEGORY         TEXT    NOT NULL CHECK (CATEGORY IN ('preference', 'architecture', 'gotcha', 'convention', 'decision', 'fact')),
    CONTENT          TEXT    NOT NULL,
    TAGS             TEXT,
    CONFIDENCE       REAL    NOT NULL DEFAULT 0.85,
    PINNED           INTEGER NOT NULL DEFAULT 0,
    EMBEDDING        BLOB,
    EMBEDDING_BLOB   BLOB,
    SOURCE_EVENT     TEXT,
    SUPERSEDED_BY_ID INTEGER REFERENCES NPL_MEMORIES(ID),
    VALID_FROM       TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    VALID_UNTIL      TEXT,
    ACCESS_COUNT     INTEGER NOT NULL DEFAULT 0,
    LAST_ACCESSED_AT TEXT
);

CREATE INDEX IF NOT EXISTS IDX_NPL_MEM_SCOPE_REPO
    ON NPL_MEMORIES (SCOPE_LEVEL, REPO_KEY, SUPERSEDED_BY_ID);

CREATE INDEX IF NOT EXISTS IDX_NPL_MEM_REPO_FILE
    ON NPL_MEMORIES (REPO_KEY, FILE_PATH, SUPERSEDED_BY_ID);

CREATE INDEX IF NOT EXISTS IDX_NPL_MEM_CATEGORY
    ON NPL_MEMORIES (CATEGORY, CONFIDENCE);

CREATE INDEX IF NOT EXISTS IDX_NPL_MEM_SUPERSEDED
    ON NPL_MEMORIES (SUPERSEDED_BY_ID);

CREATE TABLE IF NOT EXISTS NPL_MEMORY_EDGES (
    ID               INTEGER PRIMARY KEY AUTOINCREMENT,
    FROM_MEMORY_ID   INTEGER NOT NULL REFERENCES NPL_MEMORIES(ID) ON DELETE CASCADE,
    TO_MEMORY_ID     INTEGER NOT NULL REFERENCES NPL_MEMORIES(ID) ON DELETE CASCADE,
    RELATION         TEXT    NOT NULL CHECK (RELATION IN ('relates_to', 'contradicts', 'extends', 'applies_to', 'supersedes')),
    WEIGHT           REAL    NOT NULL DEFAULT 1.0,
    CREATED_AT       TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS IDX_NPL_EDGE_FROM
    ON NPL_MEMORY_EDGES (FROM_MEMORY_ID, RELATION);

CREATE INDEX IF NOT EXISTS IDX_NPL_EDGE_TO
    ON NPL_MEMORY_EDGES (TO_MEMORY_ID, RELATION);

CREATE TABLE IF NOT EXISTS NPL_MEMORY_EVENTS (
    ID               INTEGER PRIMARY KEY AUTOINCREMENT,
    EVENT_TYPE       TEXT    NOT NULL,
    REPO_KEY         TEXT,
    FILE_PATH        TEXT,
    PAYLOAD_SUMMARY  TEXT,
    ACTION_TAKEN     TEXT    NOT NULL CHECK (ACTION_TAKEN IN ('ADD', 'UPDATE', 'SUPERSEDE', 'NOOP', 'IGNORED')),
    TARGET_MEMORY_ID INTEGER,
    MODEL_ID         TEXT,
    CREATED_AT       TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS IDX_NPL_EVT_REPO
    ON NPL_MEMORY_EVENTS (REPO_KEY, CREATED_AT);

CREATE TABLE IF NOT EXISTS NPL_DOC_CACHE (
    ID               INTEGER PRIMARY KEY AUTOINCREMENT,
    CONTENT_SHA256   TEXT    NOT NULL,
    SOURCE_PATH      TEXT,
    MIME_TYPE        TEXT    NOT NULL,
    OUTPUT_FORMAT    TEXT    NOT NULL DEFAULT 'markdown',
    PAGE_COUNT       INTEGER NOT NULL DEFAULT 1,
    EXTRACTED_TEXT   TEXT    NOT NULL,
    MODEL_ID         TEXT,
    TOKEN_ESTIMATE   INTEGER NOT NULL DEFAULT 0,
    CREATED_AT       TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LAST_ACCESSED_AT TEXT,
    UNIQUE (CONTENT_SHA256, OUTPUT_FORMAT)
);

CREATE INDEX IF NOT EXISTS IDX_NPL_DOC_PATH
    ON NPL_DOC_CACHE (SOURCE_PATH);

CREATE TABLE IF NOT EXISTS NPL_DOC_CHUNKS (
    ID               INTEGER PRIMARY KEY AUTOINCREMENT,
    DOC_ID           INTEGER NOT NULL REFERENCES NPL_DOC_CACHE(ID) ON DELETE CASCADE,
    CHUNK_INDEX      INTEGER NOT NULL,
    PAGE_NO          INTEGER NOT NULL DEFAULT 1,
    CONTENT          TEXT    NOT NULL,
    EMBEDDING        BLOB,
    EMBEDDING_BLOB   BLOB,
    CREATED_AT       TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS IDX_NPL_CHUNK_DOC
    ON NPL_DOC_CHUNKS (DOC_ID, CHUNK_INDEX);

CREATE TABLE IF NOT EXISTS NPL_LOCAL_JOBS (
    JOB_ID             TEXT    PRIMARY KEY,
    KIND               TEXT    NOT NULL,
    ROLE               TEXT    NOT NULL DEFAULT 'worker_small',
    MODEL_ID           TEXT,
    TARGET_PATH        TEXT,
    STATUS             TEXT    NOT NULL,
    SYNTAX_OK          INTEGER,
    SYNTAX_OUTPUT      TEXT,
    PROMPT_TOKENS      INTEGER NOT NULL DEFAULT 0,
    COMPLETION_TOKENS  INTEGER NOT NULL DEFAULT 0,
    CLOUD_TOKENS_SAVED INTEGER NOT NULL DEFAULT 0,
    DIFF_SUMMARY       TEXT,
    ERROR_TEXT         TEXT,
    CREATED_AT         TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UPDATED_AT         TEXT
);

CREATE INDEX IF NOT EXISTS IDX_NPL_JOBS_STATUS
    ON NPL_LOCAL_JOBS (STATUS, CREATED_AT);
END_SQLITE_SCHEMA
    }
    if ($file eq 'db2_memory.sql') {
        return <<'END_DB2_SCHEMA';
-- IBM Db2 12.1.2+ Relational Semantic Memory Schema for NeoPerl::MT
-- Uses native VECTOR(768, REAL) columns for VECTOR_DISTANCE(..., COSINE)
-- queries, with optional EMBEDDING_BLOB columns for Db2 < 12.1.2 fallback.

CREATE TABLE NPL_MEMORIES (
    ID               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    SCOPE_LEVEL      VARCHAR(16)   NOT NULL,
    REPO_KEY         VARCHAR(256),
    FILE_PATH        VARCHAR(512),
    SYMBOL_NAME      VARCHAR(256),
    CATEGORY         VARCHAR(32)   NOT NULL,
    CONTENT          CLOB(64K)     NOT NULL,
    TAGS             VARCHAR(512),
    CONFIDENCE       REAL          NOT NULL DEFAULT 0.85,
    PINNED           SMALLINT      NOT NULL DEFAULT 0,
    EMBEDDING        VECTOR(768, REAL),
    EMBEDDING_BLOB   BLOB(8K),
    SOURCE_EVENT     VARCHAR(64),
    SUPERSEDED_BY_ID BIGINT,
    VALID_FROM       TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    VALID_UNTIL      TIMESTAMP,
    ACCESS_COUNT     INTEGER       NOT NULL DEFAULT 0,
    LAST_ACCESSED_AT TIMESTAMP,
    CONSTRAINT CHK_NPL_MEM_SCOPE CHECK (
        SCOPE_LEVEL IN ('global', 'repo', 'file', 'symbol')
    ),
    CONSTRAINT CHK_NPL_MEM_CAT CHECK (
        CATEGORY IN ('preference', 'architecture', 'gotcha', 'convention', 'decision', 'fact')
    ),
    CONSTRAINT FK_NPL_MEM_SUPERSEDE FOREIGN KEY (SUPERSEDED_BY_ID)
        REFERENCES NPL_MEMORIES(ID)
);

CREATE INDEX IDX_NPL_MEM_SCOPE_REPO
    ON NPL_MEMORIES (SCOPE_LEVEL, REPO_KEY, SUPERSEDED_BY_ID);

CREATE INDEX IDX_NPL_MEM_REPO_FILE
    ON NPL_MEMORIES (REPO_KEY, FILE_PATH, SUPERSEDED_BY_ID);

CREATE INDEX IDX_NPL_MEM_CATEGORY
    ON NPL_MEMORIES (CATEGORY, CONFIDENCE);

CREATE INDEX IDX_NPL_MEM_SUPERSEDED
    ON NPL_MEMORIES (SUPERSEDED_BY_ID);

CREATE TABLE NPL_MEMORY_EDGES (
    ID               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    FROM_MEMORY_ID   BIGINT        NOT NULL,
    TO_MEMORY_ID     BIGINT        NOT NULL,
    RELATION         VARCHAR(32)   NOT NULL,
    WEIGHT           REAL          NOT NULL DEFAULT 1.0,
    CREATED_AT       TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT CHK_NPL_EDGE_REL CHECK (
        RELATION IN ('relates_to', 'contradicts', 'extends', 'applies_to', 'supersedes')
    ),
    CONSTRAINT FK_NPL_EDGE_FROM FOREIGN KEY (FROM_MEMORY_ID)
        REFERENCES NPL_MEMORIES(ID) ON DELETE CASCADE,
    CONSTRAINT FK_NPL_EDGE_TO FOREIGN KEY (TO_MEMORY_ID)
        REFERENCES NPL_MEMORIES(ID) ON DELETE CASCADE
);

CREATE INDEX IDX_NPL_EDGE_FROM
    ON NPL_MEMORY_EDGES (FROM_MEMORY_ID, RELATION);

CREATE INDEX IDX_NPL_EDGE_TO
    ON NPL_MEMORY_EDGES (TO_MEMORY_ID, RELATION);

CREATE TABLE NPL_MEMORY_EVENTS (
    ID               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    EVENT_TYPE       VARCHAR(64)   NOT NULL,
    REPO_KEY         VARCHAR(256),
    FILE_PATH        VARCHAR(512),
    PAYLOAD_SUMMARY  CLOB(32K),
    ACTION_TAKEN     VARCHAR(32)   NOT NULL,
    TARGET_MEMORY_ID BIGINT,
    MODEL_ID         VARCHAR(128),
    CREATED_AT       TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT CHK_NPL_EVT_ACTION CHECK (
        ACTION_TAKEN IN ('ADD', 'UPDATE', 'SUPERSEDE', 'NOOP', 'IGNORED')
    )
);

CREATE INDEX IDX_NPL_EVT_REPO
    ON NPL_MEMORY_EVENTS (REPO_KEY, CREATED_AT);

CREATE TABLE NPL_DOC_CACHE (
    ID               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    CONTENT_SHA256   CHAR(64)      NOT NULL,
    SOURCE_PATH      VARCHAR(512),
    MIME_TYPE        VARCHAR(64)   NOT NULL,
    OUTPUT_FORMAT    VARCHAR(32)   NOT NULL DEFAULT 'markdown',
    PAGE_COUNT       INTEGER       NOT NULL DEFAULT 1,
    EXTRACTED_TEXT   CLOB(2M)      NOT NULL,
    MODEL_ID         VARCHAR(128),
    TOKEN_ESTIMATE   INTEGER       NOT NULL DEFAULT 0,
    CREATED_AT       TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    LAST_ACCESSED_AT TIMESTAMP,
    CONSTRAINT UQ_NPL_DOC_SHA_FMT UNIQUE (CONTENT_SHA256, OUTPUT_FORMAT)
);

CREATE INDEX IDX_NPL_DOC_PATH
    ON NPL_DOC_CACHE (SOURCE_PATH);

CREATE TABLE NPL_DOC_CHUNKS (
    ID               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    DOC_ID           BIGINT        NOT NULL,
    CHUNK_INDEX      INTEGER       NOT NULL,
    PAGE_NO          INTEGER       NOT NULL DEFAULT 1,
    CONTENT          CLOB(32K)     NOT NULL,
    EMBEDDING        VECTOR(768, REAL),
    EMBEDDING_BLOB   BLOB(8K),
    CREATED_AT       TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    CONSTRAINT FK_NPL_CHUNK_DOC FOREIGN KEY (DOC_ID)
        REFERENCES NPL_DOC_CACHE(ID) ON DELETE CASCADE
);

CREATE INDEX IDX_NPL_CHUNK_DOC
    ON NPL_DOC_CHUNKS (DOC_ID, CHUNK_INDEX);

CREATE TABLE NPL_LOCAL_JOBS (
    JOB_ID             VARCHAR(64)   PRIMARY KEY,
    KIND               VARCHAR(32)   NOT NULL,
    ROLE               VARCHAR(32)   NOT NULL DEFAULT 'worker_small',
    MODEL_ID           VARCHAR(128),
    TARGET_PATH        VARCHAR(512),
    STATUS             VARCHAR(32)   NOT NULL,
    SYNTAX_OK          SMALLINT,
    SYNTAX_OUTPUT      CLOB(16K),
    PROMPT_TOKENS      INTEGER       NOT NULL DEFAULT 0,
    COMPLETION_TOKENS  INTEGER       NOT NULL DEFAULT 0,
    CLOUD_TOKENS_SAVED INTEGER       NOT NULL DEFAULT 0,
    DIFF_SUMMARY       CLOB(64K),
    ERROR_TEXT         CLOB(16K),
    CREATED_AT         TIMESTAMP     NOT NULL DEFAULT CURRENT TIMESTAMP,
    UPDATED_AT         TIMESTAMP
);

CREATE INDEX IDX_NPL_JOBS_STATUS
    ON NPL_LOCAL_JOBS (STATUS, CREATED_AT);
END_DB2_SCHEMA
    }
    return undef;
}

sub load_schema_sql {
    my ($self, $dialect) = @_;
    $dialect ||= $self->{dialect};
    my $file = ($dialect eq 'sqlite') ? 'sqlite_test_double.sql' : 'db2_memory.sql';
    my $path = $self->_find_schema_file($file);
    if (defined $path && open my $fh, '<:encoding(UTF-8)', $path) {
        local $/;
        my $sql = <$fh>;
        close $fh;
        return $sql;
    }
    my $embedded = _embedded_schema_sql($file);
    return $embedded if defined $embedded;
    croak "NeoPerl::Memory::Store: unable to locate schema file $file";
}

sub _split_sql_statements {
    my ($sql) = @_;
    my @stmts;
    my $buf = '';
    for my $line (split /\r?\n/, $sql) {
        next if $line =~ /^\s*--/;
        $buf .= $line . "\n";
        if ($line =~ /;\s*$/) {
            $buf =~ s/;\s*$//;
            $buf =~ s/^\s+//;
            $buf =~ s/\s+$//;
            push @stmts, $buf if length $buf;
            $buf = '';
        }
    }
    $buf =~ s/^\s+//;
    $buf =~ s/\s+$//;
    push @stmts, $buf if length $buf;
    return @stmts;
}

sub init_schema {
    my ($self) = @_;
    croak "NeoPerl::Memory::Store: cannot init_schema in sql_only mode" if $self->{sql_only};

    my $sql = $self->load_schema_sql($self->{dialect});
    my @stmts = _split_sql_statements($sql);

    $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        for my $stmt (@stmts) {
            if ($self->{dialect} eq 'db2_blob') {
                $stmt =~ s/\bVECTOR\(\d+,\s*REAL\)/BLOB(8K)/gi;
            }
            my $ok = eval { $dbh->do($stmt); 1 };
            if (!$ok) {
                my $err = $@;
                # Ignore already-exists errors for idempotent Db2 init
                next if $self->{dialect} =~ /^db2/ && $err =~ /SQL0601N|SQL0605W|already exists/i;
                die $err;
            }
        }
    });
    return 1;
}

# --- Vector Encoding & SIMD Helpers ---

sub pack_vector {
    my ($self, $vec) = @_;
    return undef unless defined $vec;
    return $vec if !ref($vec);    # already packed BLOB
    croak "NeoPerl::Memory::Store: embedding must be an arrayref or binary blob"
        unless ref($vec) eq 'ARRAY';
    my $dim = ref($self) ? $self->{dim} : $DEFAULT_DIM;
    my @vals = @$vec;
    if (@vals < $dim) {
        push @vals, (0.0) x ($dim - @vals);
    }
    elsif (@vals > $dim) {
        @vals = @vals[ 0 .. $dim - 1 ];
    }
    if (eval { defined(&NeoPerl::Core::VecSIMD::pack_f32) }) {
        return NeoPerl::Core::VecSIMD::pack_f32(\@vals);
    }
    return pack('f<*', @vals);
}

sub unpack_vector {
    my ($self, $blob) = @_;
    return [] unless defined $blob && length $blob;
    return $blob if ref($blob) eq 'ARRAY';
    if (eval { defined(&NeoPerl::Core::VecSIMD::unpack_f32) }) {
        return NeoPerl::Core::VecSIMD::unpack_f32($blob);
    }
    return [ unpack('f<*', $blob) ];
}

sub format_db2_vector {
    my ($self, $vec) = @_;
    my $arr = ref($vec) eq 'ARRAY' ? $vec : $self->unpack_vector($vec);
    my $dim = ref($self) ? $self->{dim} : $DEFAULT_DIM;
    my @vals = @$arr;
    if (@vals < $dim) {
        push @vals, (0.0) x ($dim - @vals);
    }
    elsif (@vals > $dim) {
        @vals = @vals[ 0 .. $dim - 1 ];
    }
    return '[' . join(',', map { sprintf('%.6g', $_ + 0.0) } @vals) . ']';
}

sub cosine_similarity {
    my ($self, $a, $b) = @_;
    return 0.0 unless defined $a && defined $b;

    if (eval { require NeoPerl::Core; defined(&NeoPerl::Core::VecSIMD::cosine_f32) }) {
        my $ba = ref($a) ? $self->pack_vector($a) : $a;
        my $bb = ref($b) ? $self->pack_vector($b) : $b;
        return 0.0 unless length($ba) && length($ba) == length($bb);
        return NeoPerl::Core::VecSIMD::cosine_f32($ba, $bb);
    }

    my $va = ref($a) ? $a : $self->unpack_vector($a);
    my $vb = ref($b) ? $b : $self->unpack_vector($b);
    my $n = @$va < @$vb ? scalar(@$va) : scalar(@$vb);
    return 0.0 if $n == 0;

    my ($dot, $na, $nb) = (0.0, 0.0, 0.0);
    for (my $i = 0; $i < $n; $i++) {
        my $x = $va->[$i] + 0.0;
        my $y = $vb->[$i] + 0.0;
        $dot += $x * $y;
        $na  += $x * $x;
        $nb  += $y * $y;
    }
    return 0.0 if $na <= 0.0 || $nb <= 0.0;
    return $dot / (sqrt($na) * sqrt($nb));
}

sub _embed_text {
    my ($self, $text) = @_;
    return undef unless defined $text && length $text;
    my $emb = $self->{embedder};
    if (ref($emb) eq 'CODE') {
        return $emb->($text);
    }
    elsif (ref($emb) && $emb->can('embed')) {
        return $emb->embed($text);
    }
    # Deterministic lightweight fallback hash-embedding so Store works standalone
    return $self->_fallback_embed($text);
}

sub _fallback_embed {
    my ($self, $text) = @_;
    my $dim = $self->{dim} || $DEFAULT_DIM;
    my @v = (0.0) x $dim;
    my $lc = lc($text // '');
    my @tokens = ($lc =~ /[a-z0-9_]{2,}/g);
    for my $tok (@tokens) {
        my $h = 2166136261;
        for my $b (unpack('C*', $tok)) {
            $h = (($h ^ $b) * 16777619) & 0xFFFFFFFF;
        }
        my $idx  = $h % $dim;
        my $sign = (($h >> 16) & 1) ? 1.0 : -1.0;
        $v[$idx] += $sign;

        # Character 3-grams for partial morphological similarity
        if (length($tok) >= 4) {
            for my $i (0 .. length($tok) - 3) {
                my $tri = substr($tok, $i, 3);
                my $th = 5381;
                for my $b (unpack('C*', $tri)) {
                    $th = (($th * 33) ^ $b) & 0xFFFFFFFF;
                }
                $v[ $th % $dim ] += ((($th >> 12) & 1) ? 0.35 : -0.35);
            }
        }
    }
    my $norm = 0.0;
    $norm += $_ * $_ for @v;
    if ($norm > 0.0) {
        my $inv = 1.0 / sqrt($norm);
        $_ *= $inv for @v;
    }
    return \@v;
}

# --- Native IBM Db2 12.1.2+ SQL Builders ---

sub build_db2_insert_sql {
    my ($self, %opts) = @_;
    my $dim  = $self->{dim} || $DEFAULT_DIM;
    my $blob = $opts{blob_fallback} || ($self->{dialect} eq 'db2_blob');

    if ($blob) {
        return (
            'INSERT INTO NPL_MEMORIES ('
            . 'SCOPE_LEVEL, REPO_KEY, FILE_PATH, SYMBOL_NAME, CATEGORY, CONTENT, '
            . 'TAGS, CONFIDENCE, PINNED, EMBEDDING_BLOB, SOURCE_EVENT, SUPERSEDED_BY_ID'
            . ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
        );
    }

    return (
        'INSERT INTO NPL_MEMORIES ('
        . 'SCOPE_LEVEL, REPO_KEY, FILE_PATH, SYMBOL_NAME, CATEGORY, CONTENT, '
        . 'TAGS, CONFIDENCE, PINNED, EMBEDDING, SOURCE_EVENT, SUPERSEDED_BY_ID'
        . ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, VECTOR(?, $dim, REAL), ?, ?)"
    );
}

sub build_db2_search_sql {
    my ($self, $filters) = @_;
    $filters ||= {};
    my $dim = $self->{dim} || $DEFAULT_DIM;

    my @where;
    my @binds;

    # First bind is always the query vector for VECTOR_DISTANCE(...)
    push @binds, { name => 'query_vector', type => "VECTOR($dim, REAL)" };

    if (!$filters->{include_superseded}) {
        push @where, 'SUPERSEDED_BY_ID IS NULL';
        push @where, 'VALID_UNTIL IS NULL';
    }

    my $scopes = $filters->{scope_levels} // $filters->{scope};
    if (defined $scopes) {
        my @list = ref($scopes) eq 'ARRAY' ? @$scopes : ($scopes);
        @list = grep { defined $_ && $VALID_SCOPES{$_} } @list;
        if (@list == 1) {
            push @where, 'SCOPE_LEVEL = ?';
            push @binds, { name => 'scope_level', value => $list[0] };
        }
        elsif (@list > 1) {
            push @where, 'SCOPE_LEVEL IN (' . join(', ', ('?') x @list) . ')';
            push @binds, { name => 'scope_level', value => $_ } for @list;
        }
    }

    my $repo = $filters->{repo_key} // $filters->{repo};
    if (defined $repo && length $repo) {
        if ($filters->{include_global} // 1) {
            push @where, "(REPO_KEY = ? OR SCOPE_LEVEL = 'global')";
        }
        else {
            push @where, 'REPO_KEY = ?';
        }
        push @binds, { name => 'repo_key', value => $repo };
    }

    my $file = $filters->{file_path} // $filters->{file};
    if (defined $file && length $file) {
        if ($filters->{strict_file}) {
            push @where, 'FILE_PATH = ?';
        }
        else {
            push @where, '(FILE_PATH = ? OR FILE_PATH IS NULL)';
        }
        push @binds, { name => 'file_path', value => $file };
    }

    my $sym = $filters->{symbol_name} // $filters->{symbol};
    if (defined $sym && length $sym) {
        push @where, '(SYMBOL_NAME = ? OR SYMBOL_NAME IS NULL)';
        push @binds, { name => 'symbol_name', value => $sym };
    }

    if (defined $filters->{category} && length $filters->{category}) {
        push @where, 'CATEGORY = ?';
        push @binds, { name => 'category', value => $filters->{category} };
    }

    if (defined $filters->{min_confidence} && looks_like_number($filters->{min_confidence})) {
        push @where, 'CONFIDENCE >= ?';
        push @binds, { name => 'min_confidence', value => $filters->{min_confidence} + 0.0 };
    }

    push @where, 'EMBEDDING IS NOT NULL';

    my $limit = int($filters->{limit} || 8);
    $limit = 1 if $limit < 1;
    $limit = 200 if $limit > 200;
    push @binds, { name => 'limit', value => $limit };

    my $where_sql = @where ? ('WHERE ' . join(' AND ', @where)) : '';

    my $sql = join("\n",
        'SELECT ID, SCOPE_LEVEL, REPO_KEY, FILE_PATH, SYMBOL_NAME, CATEGORY,',
        '       CONTENT, TAGS, CONFIDENCE, PINNED, SOURCE_EVENT,',
        '       SUPERSEDED_BY_ID, VALID_FROM, VALID_UNTIL, ACCESS_COUNT, LAST_ACCESSED_AT,',
        "       VECTOR_DISTANCE(EMBEDDING, VECTOR(?, $dim, REAL), COSINE) AS COSINE_DIST",
        'FROM NPL_MEMORIES',
        $where_sql,
        'ORDER BY (COSINE_DIST - (PINNED * 0.08)) ASC, CONFIDENCE DESC',
        'FETCH FIRST ? ROWS ONLY',
    );

    return ($sql, \@binds);
}

sub build_db2_doc_chunk_search_sql {
    my ($self, $filters) = @_;
    $filters ||= {};
    my $dim = $self->{dim} || $DEFAULT_DIM;

    my @where = ('c.EMBEDDING IS NOT NULL');
    my @binds = ({ name => 'query_vector', type => "VECTOR($dim, REAL)" });

    if (defined $filters->{doc_id}) {
        push @where, 'c.DOC_ID = ?';
        push @binds, { name => 'doc_id', value => int($filters->{doc_id}) };
    }
    if (defined $filters->{source_path} && length $filters->{source_path}) {
        push @where, 'd.SOURCE_PATH = ?';
        push @binds, { name => 'source_path', value => $filters->{source_path} };
    }

    my $limit = int($filters->{limit} || 6);
    $limit = 1 if $limit < 1;
    push @binds, { name => 'limit', value => $limit };

    my $sql = join("\n",
        'SELECT c.ID, c.DOC_ID, c.CHUNK_INDEX, c.PAGE_NO, c.CONTENT,',
        '       d.SOURCE_PATH, d.CONTENT_SHA256, d.OUTPUT_FORMAT,',
        "       VECTOR_DISTANCE(c.EMBEDDING, VECTOR(?, $dim, REAL), COSINE) AS COSINE_DIST",
        'FROM NPL_DOC_CHUNKS c',
        'JOIN NPL_DOC_CACHE d ON d.ID = c.DOC_ID',
        'WHERE ' . join(' AND ', @where),
        'ORDER BY COSINE_DIST ASC',
        'FETCH FIRST ? ROWS ONLY',
    );

    return ($sql, \@binds);
}

# --- Memory CRUD & Temporal Superseding ---

sub add_memory {
    my ($self, $mem) = @_;
    croak "add_memory requires a hashref" unless ref($mem) eq 'HASH';

    my $scope = $mem->{scope_level} // $mem->{scope} // 'repo';
    croak "Invalid scope_level: $scope" unless $VALID_SCOPES{$scope};

    my $category = $mem->{category} // 'fact';
    croak "Invalid category: $category" unless $VALID_CATS{$category};

    my $content = $mem->{content};
    croak "add_memory requires non-empty content"
        unless defined $content && length $content;

    my $tags       = ref($mem->{tags}) eq 'ARRAY' ? join(',', @{ $mem->{tags} }) : ($mem->{tags} // '');
    my $confidence = defined $mem->{confidence} ? ($mem->{confidence} + 0.0) : 0.85;
    my $pinned     = $mem->{pinned} ? 1 : 0;
    my $repo       = $mem->{repo_key} // $mem->{repo};
    my $file       = $mem->{file_path} // $mem->{file};
    my $symbol     = $mem->{symbol_name} // $mem->{symbol};
    my $source_ev  = $mem->{source_event} // 'explicit';

    my $emb = $mem->{embedding};
    if (!defined $emb) {
        my $embed_input = join(' ', grep { defined $_ && length $_ } ($category, $symbol, $tags, $content));
        $emb = $self->_embed_text($embed_input);
    }

    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        if ($self->{dialect} eq 'db2') {
            my $vec_str = $self->format_db2_vector($emb);
            my $sql = $self->build_db2_insert_sql();
            my $sth = $dbh->prepare($sql);
            $sth->execute(
                $scope, $repo, $file, $symbol, $category, $content,
                $tags, $confidence, $pinned, $vec_str, $source_ev, undef,
            );
            my ($id) = $dbh->selectrow_array('VALUES IDENTITY_VAL_LOCAL()');
            return int($id);
        }
        elsif ($self->{dialect} eq 'db2_blob') {
            my $blob = $self->pack_vector($emb);
            my $sql = $self->build_db2_insert_sql(blob_fallback => 1);
            my $sth = $dbh->prepare($sql);
            $sth->execute(
                $scope, $repo, $file, $symbol, $category, $content,
                $tags, $confidence, $pinned, $blob, $source_ev, undef,
            );
            my ($id) = $dbh->selectrow_array('VALUES IDENTITY_VAL_LOCAL()');
            return int($id);
        }
        else {
            my $blob = $self->pack_vector($emb);
            my $sth = $dbh->prepare(
                'INSERT INTO NPL_MEMORIES ('
                . 'SCOPE_LEVEL, REPO_KEY, FILE_PATH, SYMBOL_NAME, CATEGORY, CONTENT, '
                . 'TAGS, CONFIDENCE, PINNED, EMBEDDING, EMBEDDING_BLOB, SOURCE_EVENT, SUPERSEDED_BY_ID'
                . ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
            );
            $sth->execute(
                $scope, $repo, $file, $symbol, $category, $content,
                $tags, $confidence, $pinned, $blob, $blob, $source_ev, undef,
            );
            my $id = $dbh->sqlite_last_insert_rowid();
            return int($id);
        }
    });
}

sub _normalize_memory_row {
    my ($row) = @_;
    return undef unless ref($row) eq 'HASH';
    my %out;
    for my $k (keys %$row) {
        $out{ lc($k) } = $row->{$k};
    }
    delete $out{embedding};
    delete $out{embedding_blob};
    $out{id}           = int($out{id}) if defined $out{id};
    $out{pinned}       = $out{pinned} ? 1 : 0;
    $out{confidence}   = defined $out{confidence} ? ($out{confidence} + 0.0) : 0.0;
    $out{access_count} = int($out{access_count} || 0);
    return \%out;
}

sub _get_memory_dbh {
    my ($dbh, $id) = @_;
    my $row = $dbh->selectrow_hashref(
        'SELECT ID, SCOPE_LEVEL, REPO_KEY, FILE_PATH, SYMBOL_NAME, CATEGORY, '
        . 'CONTENT, TAGS, CONFIDENCE, PINNED, SOURCE_EVENT, SUPERSEDED_BY_ID, '
        . 'VALID_FROM, VALID_UNTIL, ACCESS_COUNT, LAST_ACCESSED_AT '
        . 'FROM NPL_MEMORIES WHERE ID = ?',
        undef, int($id),
    );
    return _normalize_memory_row($row);
}

sub get_memory {
    my ($self, $id) = @_;
    return undef unless defined $id;
    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        return _get_memory_dbh($dbh, $id);
    });
}

sub update_memory {
    my ($self, $id, $fields) = @_;
    croak "update_memory requires id and hashref"
        unless defined $id && ref($fields) eq 'HASH';

    my $existing = $self->get_memory($id);
    croak "Memory ID $id not found" unless $existing;

    my $content    = defined $fields->{content}    ? $fields->{content}    : $existing->{content};
    my $tags       = exists $fields->{tags}
        ? (ref($fields->{tags}) eq 'ARRAY' ? join(',', @{ $fields->{tags} }) : ($fields->{tags} // ''))
        : $existing->{tags};
    my $confidence = defined $fields->{confidence} ? ($fields->{confidence} + 0.0) : $existing->{confidence};
    my $pinned     = exists $fields->{pinned}      ? ($fields->{pinned} ? 1 : 0)   : $existing->{pinned};
    my $category   = defined $fields->{category}   ? $fields->{category}   : $existing->{category};
    croak "Invalid category: $category" unless $VALID_CATS{$category};

    my $reembed = defined($fields->{content}) || defined($fields->{tags}) || defined($fields->{embedding});
    my $emb;
    if ($reembed) {
        $emb = $fields->{embedding}
            // $self->_embed_text(join(' ', grep { defined $_ && length $_ } ($category, $existing->{symbol_name}, $tags, $content)));
    }

    $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        if ($reembed) {
            if ($self->{dialect} eq 'db2') {
                my $dim = $self->{dim} || $DEFAULT_DIM;
                $dbh->do(
                    "UPDATE NPL_MEMORIES SET CATEGORY = ?, CONTENT = ?, TAGS = ?, CONFIDENCE = ?, PINNED = ?, "
                    . "EMBEDDING = VECTOR(?, $dim, REAL) WHERE ID = ?",
                    undef, $category, $content, $tags, $confidence, $pinned,
                    $self->format_db2_vector($emb), int($id),
                );
            }
            elsif ($self->{dialect} eq 'db2_blob') {
                my $blob = $self->pack_vector($emb);
                $dbh->do(
                    'UPDATE NPL_MEMORIES SET CATEGORY = ?, CONTENT = ?, TAGS = ?, CONFIDENCE = ?, PINNED = ?, '
                    . 'EMBEDDING_BLOB = ? WHERE ID = ?',
                    undef, $category, $content, $tags, $confidence, $pinned, $blob, int($id),
                );
            }
            else {
                my $blob = $self->pack_vector($emb);
                $dbh->do(
                    'UPDATE NPL_MEMORIES SET CATEGORY = ?, CONTENT = ?, TAGS = ?, CONFIDENCE = ?, PINNED = ?, '
                    . 'EMBEDDING = ?, EMBEDDING_BLOB = ? WHERE ID = ?',
                    undef, $category, $content, $tags, $confidence, $pinned, $blob, $blob, int($id),
                );
            }
        }
        else {
            $dbh->do(
                'UPDATE NPL_MEMORIES SET CATEGORY = ?, CONTENT = ?, TAGS = ?, CONFIDENCE = ?, PINNED = ? WHERE ID = ?',
                undef, $category, $content, $tags, $confidence, $pinned, int($id),
            );
        }
    });

    return $self->get_memory($id);
}

sub supersede {
    my ($self, $old_id, $new_mem) = @_;
    croak "supersede requires old_id and new_mem hashref"
        unless defined $old_id && ref($new_mem) eq 'HASH';

    my $old = $self->get_memory($old_id);
    croak "Cannot supersede missing memory ID $old_id" unless $old;

    my %merged = (
        scope_level  => $new_mem->{scope_level} // $new_mem->{scope} // $old->{scope_level},
        repo_key     => exists $new_mem->{repo_key} ? $new_mem->{repo_key} : ($new_mem->{repo} // $old->{repo_key}),
        file_path    => exists $new_mem->{file_path} ? $new_mem->{file_path} : ($new_mem->{file} // $old->{file_path}),
        symbol_name  => exists $new_mem->{symbol_name} ? $new_mem->{symbol_name} : ($new_mem->{symbol} // $old->{symbol_name}),
        category     => $new_mem->{category}     // $old->{category},
        content      => $new_mem->{content},
        tags         => exists $new_mem->{tags} ? $new_mem->{tags} : $old->{tags},
        confidence   => defined $new_mem->{confidence} ? $new_mem->{confidence} : $old->{confidence},
        pinned       => exists $new_mem->{pinned} ? $new_mem->{pinned} : $old->{pinned},
        source_event => $new_mem->{source_event} // 'supersede',
        embedding    => $new_mem->{embedding},
    );

    my $new_id = $self->add_memory(\%merged);

    my $now_expr = ($self->{dialect} =~ /^db2/) ? 'CURRENT TIMESTAMP' : 'CURRENT_TIMESTAMP';
    $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        $dbh->do(
            "UPDATE NPL_MEMORIES SET SUPERSEDED_BY_ID = ?, VALID_UNTIL = $now_expr WHERE ID = ?",
            undef, int($new_id), int($old_id),
        );
    });

    $self->add_edge($new_id, $old_id, 'supersedes', 1.0);
    return $new_id;
}

sub pin_memory {
    my ($self, $id, $pinned) = @_;
    $pinned = 1 unless defined $pinned;
    return $self->update_memory($id, { pinned => $pinned ? 1 : 0 });
}

sub forget_memory {
    my ($self, $id, %opts) = @_;
    return 0 unless defined $id;
    my $now_expr = ($self->{dialect} =~ /^db2/) ? 'CURRENT TIMESTAMP' : 'CURRENT_TIMESTAMP';
    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        if ($opts{hard}) {
            return $dbh->do('DELETE FROM NPL_MEMORIES WHERE ID = ?', undef, int($id));
        }
        return $dbh->do(
            "UPDATE NPL_MEMORIES SET VALID_UNTIL = $now_expr, CONFIDENCE = 0.0, PINNED = 0 WHERE ID = ?",
            undef, int($id),
        );
    });
}

sub add_edge {
    my ($self, $from_id, $to_id, $relation, $weight) = @_;
    $relation ||= 'relates_to';
    croak "Invalid edge relation: $relation" unless $VALID_RELS{$relation};
    $weight = defined $weight ? ($weight + 0.0) : 1.0;

    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        $dbh->do(
            'INSERT INTO NPL_MEMORY_EDGES (FROM_MEMORY_ID, TO_MEMORY_ID, RELATION, WEIGHT) VALUES (?, ?, ?, ?)',
            undef, int($from_id), int($to_id), $relation, $weight,
        );
        if ($self->{dialect} =~ /^db2/) {
            my ($id) = $dbh->selectrow_array('VALUES IDENTITY_VAL_LOCAL()');
            return int($id);
        }
        return int($dbh->sqlite_last_insert_rowid());
    });
}

sub get_related {
    my ($self, $id, %opts) = @_;
    croak "get_related requires memory id" unless defined $id;
    my $max_depth       = $opts{depth} // 2;
    my $include_lineage = exists $opts{include_lineage} ? $opts{include_lineage} : 1;

    my $root = $self->get_memory($id);
    return undef unless $root;

    my %visited = ( int($id) => 1 );
    my @frontier = ( [ int($id), 0 ] );
    my @edges;
    my @related;
    my %seen_edge;

    $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        while (@frontier) {
            my ($cur_id, $d) = @{ shift @frontier };
            next if $d >= $max_depth;

            my $rows = $dbh->selectall_arrayref(
                'SELECT ID, FROM_MEMORY_ID, TO_MEMORY_ID, RELATION, WEIGHT, CREATED_AT '
                . 'FROM NPL_MEMORY_EDGES WHERE FROM_MEMORY_ID = ? OR TO_MEMORY_ID = ?',
                { Slice => {} }, $cur_id, $cur_id,
            );
            for my $r (@$rows) {
                my %e = map { lc($_) => $r->{$_} } keys %$r;
                next if $seen_edge{ $e{id} }++;
                push @edges, \%e;
                my $other = ($e{from_memory_id} == $cur_id) ? $e{to_memory_id} : $e{from_memory_id};
                if (!$visited{$other}++) {
                    my $mem = _get_memory_dbh($dbh, $other);
                    if ($mem) {
                        $mem->{hop_depth} = $d + 1;
                        $mem->{via_relation} = $e{relation};
                        push @related, $mem;
                        push @frontier, [ $other, $d + 1 ];
                    }
                }
            }
        }
    });

    # Temporal superseding lineage (both ancestors that this superseded and descendants that superseded this)
    my (@superseded_by, @supersedes);
    if ($include_lineage) {
        # Follow SUPERSEDED_BY_ID forward
        my $cur = $root;
        my %guard = ( $root->{id} => 1 );
        while (defined $cur->{superseded_by_id} && !$guard{ $cur->{superseded_by_id} }++) {
            my $next = $self->get_memory($cur->{superseded_by_id});
            last unless $next;
            push @superseded_by, $next;
            $cur = $next;
        }

        # Follow SUPERSEDED_BY_ID backward
        my @back_q = ( $root->{id} );
        my %bguard = ( $root->{id} => 1 );
        $self->{pool}->with_dbh(sub {
            my ($dbh) = @_;
            while (@back_q) {
                my $tid = shift @back_q;
                my $prev_rows = $dbh->selectall_arrayref(
                    'SELECT ID FROM NPL_MEMORIES WHERE SUPERSEDED_BY_ID = ?',
                    undef, $tid,
                );
                for my $pr (@$prev_rows) {
                    my $pid = int($pr->[0]);
                    next if $bguard{$pid}++;
                    my $pmem = _get_memory_dbh($dbh, $pid);
                    if ($pmem) {
                        push @supersedes, $pmem;
                        push @back_q, $pid;
                    }
                }
            }
        });
    }

    return {
        memory        => $root,
        edges         => \@edges,
        related       => \@related,
        superseded_by => \@superseded_by,
        supersedes    => \@supersedes,
    };
}

# --- Hybrid Semantic + Relational + Lexical RRF Search ---

sub _lexical_score {
    my ($query, $content, $tags, $symbol) = @_;
    return 0.0 unless defined $query && length $query;
    my @qtoks = grep { length($_) >= 2 } (lc($query) =~ /[a-z0-9_]+/g);
    return 0.0 unless @qtoks;

    my $hay = lc(join(' ', grep { defined $_ } ($content, $tags, $symbol)));
    my $hits = 0;
    for my $t (@qtoks) {
        $hits++ if index($hay, $t) >= 0;
    }
    return $hits / scalar(@qtoks);
}

sub search {
    my ($self, %args) = @_;
    my $query   = $args{query} // '';
    my $limit   = int($args{limit} || 8);
    $limit = 1 if $limit < 1;

    my $qvec = $args{query_vector};
    if (!defined $qvec && length $query) {
        $qvec = $self->_embed_text($query);
    }

    my @hits;
    if ($self->{dialect} eq 'db2' && defined $qvec) {
        my ($sql, $binds) = $self->build_db2_search_sql({ %args, limit => $limit * 3 });
        my @bind_vals = map {
            $_->{name} eq 'query_vector'
                ? $self->format_db2_vector($qvec)
                : $_->{value}
        } @$binds;

        my $rows = $self->{pool}->with_dbh(sub {
            my ($dbh) = @_;
            return $dbh->selectall_arrayref($sql, { Slice => {} }, @bind_vals);
        });

        for my $r (@$rows) {
            my $dist = defined $r->{COSINE_DIST} ? ($r->{COSINE_DIST} + 0.0) : 1.0;
            my $m = _normalize_memory_row($r);
            $m->{cosine_score}  = 1.0 - $dist;
            $m->{lexical_score} = _lexical_score($query, $m->{content}, $m->{tags}, $m->{symbol_name});
            push @hits, $m;
        }
    }
    else {
        # SQLite CI test double or Db2 < 12.1.2 BLOB fallback: SQL relational filter + C11 SIMD cosine
        my @where;
        my @binds;

        if (!$args{include_superseded}) {
            push @where, 'SUPERSEDED_BY_ID IS NULL';
            push @where, 'VALID_UNTIL IS NULL';
        }

        my $scopes = $args{scope_levels} // $args{scope};
        if (defined $scopes) {
            my @list = ref($scopes) eq 'ARRAY' ? @$scopes : ($scopes);
            @list = grep { defined $_ && $VALID_SCOPES{$_} } @list;
            if (@list == 1) {
                push @where, 'SCOPE_LEVEL = ?';
                push @binds, $list[0];
            }
            elsif (@list > 1) {
                push @where, 'SCOPE_LEVEL IN (' . join(', ', ('?') x @list) . ')';
                push @binds, @list;
            }
        }

        my $repo = $args{repo_key} // $args{repo};
        if (defined $repo && length $repo) {
            if ($args{include_global} // 1) {
                push @where, "(REPO_KEY = ? OR SCOPE_LEVEL = 'global')";
            }
            else {
                push @where, 'REPO_KEY = ?';
            }
            push @binds, $repo;
        }

        my $file = $args{file_path} // $args{file};
        if (defined $file && length $file) {
            if ($args{strict_file}) {
                push @where, 'FILE_PATH = ?';
            }
            else {
                push @where, '(FILE_PATH = ? OR FILE_PATH IS NULL)';
            }
            push @binds, $file;
        }

        my $sym = $args{symbol_name} // $args{symbol};
        if (defined $sym && length $sym) {
            push @where, '(SYMBOL_NAME = ? OR SYMBOL_NAME IS NULL)';
            push @binds, $sym;
        }

        if (defined $args{category} && length $args{category}) {
            push @where, 'CATEGORY = ?';
            push @binds, $args{category};
        }

        if (defined $args{min_confidence} && looks_like_number($args{min_confidence})) {
            push @where, 'CONFIDENCE >= ?';
            push @binds, $args{min_confidence} + 0.0;
        }

        my $where_sql = @where ? ('WHERE ' . join(' AND ', @where)) : '';
        my $blob_col  = ($self->{dialect} eq 'db2_blob') ? 'EMBEDDING_BLOB' : 'EMBEDDING';

        my $rows = $self->{pool}->with_dbh(sub {
            my ($dbh) = @_;
            return $dbh->selectall_arrayref(
                "SELECT ID, SCOPE_LEVEL, REPO_KEY, FILE_PATH, SYMBOL_NAME, CATEGORY, "
                . "CONTENT, TAGS, CONFIDENCE, PINNED, $blob_col AS VEC_BLOB, SOURCE_EVENT, "
                . "SUPERSEDED_BY_ID, VALID_FROM, VALID_UNTIL, ACCESS_COUNT, LAST_ACCESSED_AT "
                . "FROM NPL_MEMORIES $where_sql",
                { Slice => {} }, @binds,
            );
        });

        my $qblob = defined $qvec ? $self->pack_vector($qvec) : undef;

        # Use batch C11 SIMD topk_cosine when available on large candidate sets
        my %batch_scores;
        if (defined $qblob && @$rows && eval { defined(&NeoPerl::Core::VecSIMD::topk_cosine) }) {
            my @blobs;
            my @row_idxs;
            for my $idx (0 .. $#$rows) {
                my $b = $rows->[$idx]{VEC_BLOB} // $rows->[$idx]{vec_blob};
                if (defined $b && length($b) == length($qblob)) {
                    push @blobs, $b;
                    push @row_idxs, $idx;
                }
            }
            if (@blobs) {
                my $topk = eval { NeoPerl::Core::VecSIMD::topk_cosine($qblob, \@blobs, scalar(@blobs)) };
                if (ref($topk) eq 'ARRAY') {
                    for my $hit (@$topk) {
                        my ($bidx, $sc) = ref($hit) eq 'HASH'
                            ? ($hit->{index}, $hit->{score})
                            : ($hit->[0], $hit->[1]);
                        if (defined $bidx && defined $row_idxs[$bidx]) {
                            $batch_scores{ $row_idxs[$bidx] } = $sc + 0.0;
                        }
                    }
                }
            }
        }

        for my $idx (0 .. $#$rows) {
            my $r    = $rows->[$idx];
            my $blob = $r->{VEC_BLOB} // $r->{vec_blob};
            my $m    = _normalize_memory_row($r);
            delete $m->{vec_blob};

            my $cos = 0.0;
            if (exists $batch_scores{$idx}) {
                $cos = $batch_scores{$idx};
            }
            elsif (defined $qblob && defined $blob && length($blob)) {
                $cos = $self->cosine_similarity($qblob, $blob);
            }

            $m->{cosine_score}  = $cos;
            $m->{lexical_score} = _lexical_score($query, $m->{content}, $m->{tags}, $m->{symbol_name});
            push @hits, $m;
        }
    }

    # Hybrid Reciprocal Rank Fusion (RRF) + scope specificity + pinned + confidence
    if (@hits) {
        my @by_cos = sort { ($b->{cosine_score} <=> $a->{cosine_score}) || ($b->{id} <=> $a->{id}) } @hits;
        my @by_lex = sort { ($b->{lexical_score} <=> $a->{lexical_score}) || ($b->{cosine_score} <=> $a->{cosine_score}) } @hits;

        my (%cos_rank, %lex_rank);
        $cos_rank{ $by_cos[$_]{id} } = $_ + 1 for 0 .. $#by_cos;
        $lex_rank{ $by_lex[$_]{id} } = $_ + 1 for 0 .. $#by_lex;

        my $k = 12.0;
        for my $m (@hits) {
            my $rrf = (1.0 / ($k + $cos_rank{ $m->{id} }))
                    + (0.75 / ($k + $lex_rank{ $m->{id} }));

            my $scope_bonus = $SCOPE_WEIGHT{ $m->{scope_level} } // 0.0;
            my $file_bonus  = (defined $args{file} || defined $args{file_path})
                && defined($m->{file_path})
                && $m->{file_path} eq ($args{file_path} // $args{file})
                ? 0.05 : 0.0;
            my $pin_bonus   = $m->{pinned} ? 0.08 : 0.0;
            my $conf_factor = 0.85 + 0.15 * ($m->{confidence} // 0.85);

            $m->{rrf_score} = ($rrf + $m->{cosine_score} * 0.45 + $m->{lexical_score} * 0.25 + $scope_bonus + $file_bonus + $pin_bonus) * $conf_factor;
        }

        @hits = sort {
            ($b->{rrf_score} <=> $a->{rrf_score})
                || ($b->{pinned} <=> $a->{pinned})
                || ($b->{id} <=> $a->{id})
        } @hits;
    }

    if (@hits > $limit) {
        @hits = @hits[ 0 .. $limit - 1 ];
    }

    # Touch access counters on returned hits
    if (($args{update_access} // 1) && @hits) {
        my $now_expr = ($self->{dialect} =~ /^db2/) ? 'CURRENT TIMESTAMP' : 'CURRENT_TIMESTAMP';
        $self->{pool}->with_dbh(sub {
            my ($dbh) = @_;
            my $sth = $dbh->prepare(
                "UPDATE NPL_MEMORIES SET ACCESS_COUNT = ACCESS_COUNT + 1, LAST_ACCESSED_AT = $now_expr WHERE ID = ?"
            );
            for my $m (@hits) {
                $sth->execute($m->{id});
                $m->{access_count}++;
            }
        });
    }

    return \@hits;
}

# --- Provenance Events ---

sub log_event {
    my ($self, $ev) = @_;
    croak "log_event requires a hashref" unless ref($ev) eq 'HASH';
    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        $dbh->do(
            'INSERT INTO NPL_MEMORY_EVENTS '
            . '(EVENT_TYPE, REPO_KEY, FILE_PATH, PAYLOAD_SUMMARY, ACTION_TAKEN, TARGET_MEMORY_ID, MODEL_ID) '
            . 'VALUES (?, ?, ?, ?, ?, ?, ?)',
            undef,
            $ev->{event_type} // 'unknown',
            $ev->{repo_key}   // $ev->{repo},
            $ev->{file_path}  // $ev->{file},
            $ev->{payload_summary} // '',
            $ev->{action_taken} // 'NOOP',
            $ev->{target_memory_id},
            $ev->{model_id} // 'tencent/Hy-Memory-30B-A3B-GGUF',
        );
        if ($self->{dialect} =~ /^db2/) {
            my ($id) = $dbh->selectrow_array('VALUES IDENTITY_VAL_LOCAL()');
            return int($id);
        }
        return int($dbh->sqlite_last_insert_rowid());
    });
}

sub list_events {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 50);
    my (@where, @binds);
    if (defined $args{repo} && length $args{repo}) {
        push @where, 'REPO_KEY = ?';
        push @binds, $args{repo};
    }
    my $w = @where ? ('WHERE ' . join(' AND ', @where)) : '';
    my $lim_sql = ($self->{dialect} =~ /^db2/)
        ? "FETCH FIRST $limit ROWS ONLY"
        : "LIMIT $limit";

    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        my $rows = $dbh->selectall_arrayref(
            "SELECT ID, EVENT_TYPE, REPO_KEY, FILE_PATH, PAYLOAD_SUMMARY, ACTION_TAKEN, "
            . "TARGET_MEMORY_ID, MODEL_ID, CREATED_AT FROM NPL_MEMORY_EVENTS $w ORDER BY ID DESC $lim_sql",
            { Slice => {} }, @binds,
        );
        return [ map { my $r = $_; +{ map { lc($_) => $r->{$_} } keys %$r } } @$rows ];
    });
}

# --- Granite-Vision Document Cache & Embedded Chunks ---

sub get_doc_cache {
    my ($self, $sha256, $format) = @_;
    return undef unless defined $sha256 && length $sha256;
    $format ||= 'markdown';
    my $now_expr = ($self->{dialect} =~ /^db2/) ? 'CURRENT TIMESTAMP' : 'CURRENT_TIMESTAMP';

    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        my $row = $dbh->selectrow_hashref(
            'SELECT ID, CONTENT_SHA256, SOURCE_PATH, MIME_TYPE, OUTPUT_FORMAT, PAGE_COUNT, '
            . 'EXTRACTED_TEXT, MODEL_ID, TOKEN_ESTIMATE, CREATED_AT, LAST_ACCESSED_AT '
            . 'FROM NPL_DOC_CACHE WHERE CONTENT_SHA256 = ? AND OUTPUT_FORMAT = ?',
            undef, $sha256, $format,
        );
        return undef unless $row;

        my %doc = map { lc($_) => $row->{$_} } keys %$row;
        $dbh->do("UPDATE NPL_DOC_CACHE SET LAST_ACCESSED_AT = $now_expr WHERE ID = ?", undef, $doc{id});

        my $chunks = $dbh->selectall_arrayref(
            'SELECT ID, DOC_ID, CHUNK_INDEX, PAGE_NO, CONTENT FROM NPL_DOC_CHUNKS '
            . 'WHERE DOC_ID = ? ORDER BY CHUNK_INDEX ASC',
            { Slice => {} }, $doc{id},
        );
        $doc{chunks} = [ map { my $c = $_; +{ map { lc($_) => $c->{$_} } keys %$c } } @$chunks ];
        return \%doc;
    });
}

sub put_doc_cache {
    my ($self, $doc, $chunks) = @_;
    croak "put_doc_cache requires hashref" unless ref($doc) eq 'HASH';
    $chunks ||= [];
    my $format = $doc->{output_format} // 'markdown';
    my $sha    = $doc->{content_sha256} or croak "put_doc_cache requires content_sha256";

    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        # Remove existing cache entry for same (sha256, format) if overwriting
        $dbh->do(
            'DELETE FROM NPL_DOC_CACHE WHERE CONTENT_SHA256 = ? AND OUTPUT_FORMAT = ?',
            undef, $sha, $format,
        );

        $dbh->do(
            'INSERT INTO NPL_DOC_CACHE '
            . '(CONTENT_SHA256, SOURCE_PATH, MIME_TYPE, OUTPUT_FORMAT, PAGE_COUNT, EXTRACTED_TEXT, MODEL_ID, TOKEN_ESTIMATE) '
            . 'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            undef,
            $sha,
            $doc->{source_path} // '',
            $doc->{mime_type}   // 'application/octet-stream',
            $format,
            int($doc->{page_count} || 1),
            $doc->{extracted_text} // '',
            $doc->{model_id}       // 'ibm-granite/granite-vision-4.1-4b-GGUF',
            int($doc->{token_estimate} || 0),
        );

        my $doc_id;
        if ($self->{dialect} =~ /^db2/) {
            ($doc_id) = $dbh->selectrow_array('VALUES IDENTITY_VAL_LOCAL()');
        }
        else {
            $doc_id = $dbh->sqlite_last_insert_rowid();
        }
        $doc_id = int($doc_id);

        my $idx = 0;
        for my $ch (@$chunks) {
            my $text = ref($ch) eq 'HASH' ? ($ch->{content} // '') : "$ch";
            my $page = ref($ch) eq 'HASH' ? int($ch->{page_no} || 1) : 1;
            my $emb  = (ref($ch) eq 'HASH' && defined $ch->{embedding})
                ? $ch->{embedding}
                : $self->_embed_text($text);

            if ($self->{dialect} eq 'db2') {
                my $dim = $self->{dim} || $DEFAULT_DIM;
                $dbh->do(
                    "INSERT INTO NPL_DOC_CHUNKS (DOC_ID, CHUNK_INDEX, PAGE_NO, CONTENT, EMBEDDING) "
                    . "VALUES (?, ?, ?, ?, VECTOR(?, $dim, REAL))",
                    undef, $doc_id, $idx, $page, $text, $self->format_db2_vector($emb),
                );
            }
            elsif ($self->{dialect} eq 'db2_blob') {
                my $blob = $self->pack_vector($emb);
                $dbh->do(
                    'INSERT INTO NPL_DOC_CHUNKS (DOC_ID, CHUNK_INDEX, PAGE_NO, CONTENT, EMBEDDING_BLOB) '
                    . 'VALUES (?, ?, ?, ?, ?)',
                    undef, $doc_id, $idx, $page, $text, $blob,
                );
            }
            else {
                my $blob = $self->pack_vector($emb);
                $dbh->do(
                    'INSERT INTO NPL_DOC_CHUNKS (DOC_ID, CHUNK_INDEX, PAGE_NO, CONTENT, EMBEDDING, EMBEDDING_BLOB) '
                    . 'VALUES (?, ?, ?, ?, ?, ?)',
                    undef, $doc_id, $idx, $page, $text, $blob, $blob,
                );
            }
            $idx++;
        }

        return $doc_id;
    });
}

sub search_doc_chunks {
    my ($self, %args) = @_;
    my $query = $args{query} // '';
    my $limit = int($args{limit} || 5);
    my $qvec  = $args{query_vector} // (length($query) ? $self->_embed_text($query) : undef);
    my $qblob = defined $qvec ? $self->pack_vector($qvec) : undef;

    if ($self->{dialect} eq 'db2' && defined $qvec) {
        my ($sql, $binds) = $self->build_db2_doc_chunk_search_sql(\%args);
        my @vals = map { $_->{name} eq 'query_vector' ? $self->format_db2_vector($qvec) : $_->{value} } @$binds;
        my $rows = $self->{pool}->with_dbh(sub {
            my ($dbh) = @_;
            return $dbh->selectall_arrayref($sql, { Slice => {} }, @vals);
        });
        return [
            map {
                my %h = map { lc($_) => $_->{$_} } keys %$_;
                $h{cosine_score} = 1.0 - ($h{cosine_dist} // 1.0);
                \%h;
            } @$rows
        ];
    }

    my (@where, @binds);
    if (defined $args{doc_id}) {
        push @where, 'c.DOC_ID = ?';
        push @binds, int($args{doc_id});
    }
    if (defined $args{source_path} && length $args{source_path}) {
        push @where, 'd.SOURCE_PATH = ?';
        push @binds, $args{source_path};
    }
    my $w = @where ? ('WHERE ' . join(' AND ', @where)) : '';
    my $blob_col = ($self->{dialect} eq 'db2_blob') ? 'c.EMBEDDING_BLOB' : 'c.EMBEDDING';

    my $rows = $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        return $dbh->selectall_arrayref(
            "SELECT c.ID, c.DOC_ID, c.CHUNK_INDEX, c.PAGE_NO, c.CONTENT, $blob_col AS VEC_BLOB, "
            . "d.SOURCE_PATH, d.CONTENT_SHA256, d.OUTPUT_FORMAT "
            . "FROM NPL_DOC_CHUNKS c JOIN NPL_DOC_CACHE d ON d.ID = c.DOC_ID $w",
            { Slice => {} }, @binds,
        );
    });

    my @out;
    for my $r (@$rows) {
        my %h = map { lc($_) => $r->{$_} } keys %$r;
        my $b = delete $h{vec_blob};
        my $cos = (defined $qblob && defined $b && length($b)) ? $self->cosine_similarity($qblob, $b) : 0.0;
        my $lex = _lexical_score($query, $h{content}, $h{source_path}, '');
        $h{cosine_score} = $cos;
        $h{score}        = $cos * 0.7 + $lex * 0.3;
        push @out, \%h;
    }

    @out = sort { ($b->{score} <=> $a->{score}) || ($a->{chunk_index} <=> $b->{chunk_index}) } @out;
    @out = @out[ 0 .. $limit - 1 ] if @out > $limit;
    return \@out;
}

# --- Local Offload Job Ledger & Cloud Token Savings ---

sub upsert_local_job {
    my ($self, $job) = @_;
    croak "upsert_local_job requires hashref with job_id"
        unless ref($job) eq 'HASH' && defined $job->{job_id};

    my $now_expr = ($self->{dialect} =~ /^db2/) ? 'CURRENT TIMESTAMP' : 'CURRENT_TIMESTAMP';

    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        my ($exists) = $dbh->selectrow_array(
            'SELECT COUNT(*) FROM NPL_LOCAL_JOBS WHERE JOB_ID = ?',
            undef, $job->{job_id},
        );
        if ($exists) {
            $dbh->do(
                "UPDATE NPL_LOCAL_JOBS SET STATUS = ?, SYNTAX_OK = ?, SYNTAX_OUTPUT = ?, "
                . "PROMPT_TOKENS = ?, COMPLETION_TOKENS = ?, CLOUD_TOKENS_SAVED = ?, "
                . "DIFF_SUMMARY = ?, ERROR_TEXT = ?, UPDATED_AT = $now_expr WHERE JOB_ID = ?",
                undef,
                $job->{status} // 'queued',
                $job->{syntax_ok},
                $job->{syntax_output},
                int($job->{prompt_tokens} || 0),
                int($job->{completion_tokens} || 0),
                int($job->{cloud_tokens_saved} || 0),
                $job->{diff_summary},
                $job->{error_text},
                $job->{job_id},
            );
        }
        else {
            $dbh->do(
                "INSERT INTO NPL_LOCAL_JOBS ("
                . "JOB_ID, KIND, ROLE, MODEL_ID, TARGET_PATH, STATUS, SYNTAX_OK, SYNTAX_OUTPUT, "
                . "PROMPT_TOKENS, COMPLETION_TOKENS, CLOUD_TOKENS_SAVED, DIFF_SUMMARY, ERROR_TEXT, UPDATED_AT"
                . ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, $now_expr)",
                undef,
                $job->{job_id},
                $job->{kind}        // 'doc',
                $job->{role}        // 'worker_small',
                $job->{model_id}    // 'prism-ml/Ternary-Bonsai-2-27B-gguf',
                $job->{target_path} // '',
                $job->{status}      // 'queued',
                $job->{syntax_ok},
                $job->{syntax_output},
                int($job->{prompt_tokens} || 0),
                int($job->{completion_tokens} || 0),
                int($job->{cloud_tokens_saved} || 0),
                $job->{diff_summary},
                $job->{error_text},
            );
        }
        return $job->{job_id};
    });
}

sub get_local_job {
    my ($self, $job_id) = @_;
    return undef unless defined $job_id;
    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        my $row = $dbh->selectrow_hashref(
            'SELECT * FROM NPL_LOCAL_JOBS WHERE JOB_ID = ?',
            undef, $job_id,
        );
        return undef unless $row;
        return +{ map { lc($_) => $row->{$_} } keys %$row };
    });
}

sub list_local_jobs {
    my ($self, %args) = @_;
    my $limit = int($args{limit} || 50);
    my $lim_sql = ($self->{dialect} =~ /^db2/)
        ? "FETCH FIRST $limit ROWS ONLY"
        : "LIMIT $limit";
    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        my $rows = $dbh->selectall_arrayref(
            "SELECT * FROM NPL_LOCAL_JOBS ORDER BY CREATED_AT DESC, JOB_ID DESC $lim_sql",
            { Slice => {} },
        );
        return [ map { my $r = $_; +{ map { lc($_) => $r->{$_} } keys %$r } } @$rows ];
    });
}

sub token_savings_summary {
    my ($self) = @_;
    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        my $row = $dbh->selectrow_hashref(
            'SELECT COUNT(*) AS TOTAL_JOBS, '
            . "SUM(CASE WHEN STATUS IN ('staged','applied','syntax_ok') THEN 1 ELSE 0 END) AS COMPLETED_JOBS, "
            . 'COALESCE(SUM(PROMPT_TOKENS), 0) AS PROMPT_TOKENS, '
            . 'COALESCE(SUM(COMPLETION_TOKENS), 0) AS COMPLETION_TOKENS, '
            . 'COALESCE(SUM(CLOUD_TOKENS_SAVED), 0) AS CLOUD_TOKENS_SAVED '
            . 'FROM NPL_LOCAL_JOBS'
        );
        my %h = map { lc($_) => int($row->{$_} || 0) } keys %$row;
        return \%h;
    });
}

sub stats {
    my ($self) = @_;
    return { dialect => $self->{dialect}, sql_only => 1 } if $self->{sql_only};
    my $savings = $self->token_savings_summary();
    return $self->{pool}->with_dbh(sub {
        my ($dbh) = @_;
        my ($active) = $dbh->selectrow_array(
            'SELECT COUNT(*) FROM NPL_MEMORIES WHERE SUPERSEDED_BY_ID IS NULL AND VALID_UNTIL IS NULL'
        );
        my ($superseded) = $dbh->selectrow_array(
            'SELECT COUNT(*) FROM NPL_MEMORIES WHERE SUPERSEDED_BY_ID IS NOT NULL'
        );
        my ($edges)  = $dbh->selectrow_array('SELECT COUNT(*) FROM NPL_MEMORY_EDGES');
        my ($docs)   = $dbh->selectrow_array('SELECT COUNT(*) FROM NPL_DOC_CACHE');
        my ($chunks) = $dbh->selectrow_array('SELECT COUNT(*) FROM NPL_DOC_CHUNKS');
        my ($jobs)   = $dbh->selectrow_array('SELECT COUNT(*) FROM NPL_LOCAL_JOBS');
        return {
            dialect             => $self->{dialect},
            simd_backend        => $self->simd_backend(),
            using_mt_pool       => $self->{using_mt_pool},
            active_memories     => int($active || 0),
            superseded_memories => int($superseded || 0),
            edges               => int($edges || 0),
            doc_cache_entries   => int($docs || 0),
            doc_chunks          => int($chunks || 0),
            local_jobs          => int($jobs || 0),
            cloud_tokens_saved  => $savings->{cloud_tokens_saved},
            pool                => $self->{pool}->stats(),
        };
    });
}

sub close {
    my ($self) = @_;
    $self->{pool}->disconnect_all() if $self->{pool};
    return 1;
}

# Lightweight stock-DBI fallback pool when DBI::MT::Pool is not installed.
package NeoPerl::Memory::Store::_FallbackPool;

use strict;
use warnings;
use Carp qw(croak);

sub new {
    my ($class, %args) = @_;
    return bless {
        dsn             => $args{dsn},
        user            => $args{user},
        pass            => $args{pass},
        attr            => { RaiseError => 1, PrintError => 0, AutoCommit => 1, %{ $args{attr} || {} } },
        on_connect      => $args{on_connect},
        max_connections => $args{max_connections} || 4,
        dbh             => undef,
        checkouts       => 0,
    }, $class;
}

sub checkout {
    my ($self) = @_;
    if (!$self->{dbh} || !$self->{dbh}{Active}) {
        $self->{dbh} = DBI->connect($self->{dsn}, $self->{user}, $self->{pass}, { %{ $self->{attr} } })
            or croak "DBI connect failed: $DBI::errstr";
        $self->{on_connect}->($self->{dbh}) if $self->{on_connect};
    }
    $self->{checkouts}++;
    return $self->{dbh};
}

sub checkin { return 1 }

sub with_dbh {
    my ($self, $code) = @_;
    my $dbh = $self->checkout();
    return $code->($dbh);
}

sub stats {
    my ($self) = @_;
    return {
        max_connections => $self->{max_connections},
        checkouts       => $self->{checkouts},
        fallback        => 1,
    };
}

sub disconnect_all {
    my ($self) = @_;
    if ($self->{dbh}) {
        eval { $self->{dbh}->disconnect };
        $self->{dbh} = undef;
    }
    return 1;
}

1;

__END__

=head1 NAME

NeoPerl::Memory::Store - IBM Db2 12.1.2+ relational semantic memory store with SQLite CI double

=head1 SYNOPSIS

    use NeoPerl::Memory::Store;

    # Production IBM Db2 12.1.2+ via DBI::MT::Pool + DBD::ODBC
    my $store = NeoPerl::Memory::Store->new(
        dsn  => 'dbi:ODBC:DSN=NEOPERL_MEM',
        user => $ENV{DB2_USER},
        pass => $ENV{DB2_PASS},
    );

    # Offline CI test double on SQLite + C11 SIMD cosine
    my $ci_store = NeoPerl::Memory::Store->new(sqlite_path => ':memory:');
    my $id = $ci_store->add_memory({
        scope_level => 'repo',
        repo_key    => 'demo-app',
        category    => 'architecture',
        content     => 'Use DBI::MT::Pool for per-worker database handles.',
    });
    my $hits = $ci_store->search(query => 'database pool', repo => 'demo-app');

=head1 DESCRIPTION

C<NeoPerl::Memory::Store> implements the relational semantic memory persistence
layer for C<NeoPerl::MT> on top of L<DBI::MT::Pool> (falling back cleanly to
stock L<DBI>). Its primary SQL dialect targets IBM Db2 12.1.2+ native
C<VECTOR(768, REAL)> columns and C<VECTOR_DISTANCE(..., COSINE)> combined with
relational predicates, with automatic C<BLOB> fallback for earlier Db2 releases
and a matching SQLite test double backed by C<NeoPerl::Core::VecSIMD>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
