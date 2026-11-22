use strict;
use warnings;
use Test::More;
use File::Spec ();
use File::Temp qw(tempdir);

use NeoPerl::Memory::MemIgnore;
use NeoPerl::Memory::Store;
use NeoPerl::Memory::Writer;
use NeoPerl::Inference::Config;
use NeoPerl::Inference::Manager;

# ---------------------------------------------------------------------------
# 1. Static IBM Db2 12.1.2+ DDL & SQL Builder Verification
# ---------------------------------------------------------------------------
subtest 'IBM Db2 12.1.2+ DDL and native VECTOR SQL builders' => sub {
    my $db2_builder = NeoPerl::Memory::Store->new(
        dsn      => 'dbi:ODBC:DSN=NEOPERL_MEM',
        dialect  => 'db2',
        sql_only => 1,
    );

    my $ddl = $db2_builder->load_schema_sql('db2');
    for my $table (qw(NPL_MEMORIES NPL_MEMORY_EDGES NPL_MEMORY_EVENTS NPL_DOC_CACHE NPL_DOC_CHUNKS NPL_LOCAL_JOBS)) {
        like($ddl, qr/CREATE\s+TABLE\s+$table\b/i, "Db2 DDL defines $table");
    }
    like($ddl, qr/VECTOR\(768,\s*REAL\)/i, 'Db2 DDL uses native VECTOR(768, REAL)');
    like($ddl, qr/BIGINT\s+GENERATED\s+ALWAYS\s+AS\s+IDENTITY\s+PRIMARY\s+KEY/i, 'Db2 DDL uses identity primary keys');
    like($ddl, qr/CURRENT\s+TIMESTAMP/i, 'Db2 DDL uses CURRENT TIMESTAMP');
    like($ddl, qr/EMBEDDING_BLOB\s+BLOB/i, 'Db2 DDL includes BLOB fallback column');

    my $ins_vec = $db2_builder->build_db2_insert_sql();
    like($ins_vec, qr/VECTOR\(\?,\s*768,\s*REAL\)/i, 'Db2 insert uses VECTOR(?, 768, REAL)');

    my $ins_blob = $db2_builder->build_db2_insert_sql(blob_fallback => 1);
    like($ins_blob, qr/EMBEDDING_BLOB/i, 'Db2 < 12.1.2 insert uses EMBEDDING_BLOB fallback');
    unlike($ins_blob, qr/VECTOR\(\?/i, 'Db2 BLOB fallback avoids VECTOR() constructor');

    my ($sql, $binds) = $db2_builder->build_db2_search_sql({
        scope_levels   => [ 'repo', 'file', 'symbol' ],
        repo_key       => 'demo-app',
        file_path      => 'lib/App/Core.pm',
        symbol_name    => 'connect_pool',
        category       => 'architecture',
        min_confidence => 0.75,
        limit          => 6,
    });

    like($sql, qr/VECTOR_DISTANCE\(EMBEDDING,\s*VECTOR\(\?,\s*768,\s*REAL\),\s*COSINE\)\s+AS\s+COSINE_DIST/i,
        'Db2 search SQL uses native VECTOR_DISTANCE(..., COSINE)');
    like($sql, qr/SUPERSEDED_BY_ID\s+IS\s+NULL/i, 'Db2 search filters out superseded rows by default');
    like($sql, qr/SCOPE_LEVEL\s+IN\s*\(\?,\s*\?,\s*\?\)/i, 'Db2 search applies multi-scope predicate');
    like($sql, qr/REPO_KEY\s*=\s*\?/i, 'Db2 search applies REPO_KEY filter');
    like($sql, qr/FILE_PATH\s*=\s*\?/i, 'Db2 search applies FILE_PATH filter');
    like($sql, qr/SYMBOL_NAME\s*=\s*\?/i, 'Db2 search applies SYMBOL_NAME filter');
    like($sql, qr/CATEGORY\s*=\s*\?/i, 'Db2 search applies CATEGORY filter');
    like($sql, qr/CONFIDENCE\s*>=\s*\?/i, 'Db2 search applies CONFIDENCE threshold');
    like($sql, qr/FETCH\s+FIRST\s+\?\s+ROWS\s+ONLY/i, 'Db2 search uses FETCH FIRST ? ROWS ONLY');

    my $qmarks = () = ($sql =~ /\?/g);
    is($qmarks, scalar(@$binds), 'Db2 search bind count matches SQL placeholder count');

    my ($doc_sql, $doc_binds) = $db2_builder->build_db2_doc_chunk_search_sql({
        doc_id => 42,
        limit  => 4,
    });
    like($doc_sql, qr/FROM\s+NPL_DOC_CHUNKS\s+c\s+JOIN\s+NPL_DOC_CACHE\s+d/i, 'Db2 doc chunk SQL joins NPL_DOC_CACHE');
    like($doc_sql, qr/VECTOR_DISTANCE\(c\.EMBEDDING,\s*VECTOR\(\?,\s*768,\s*REAL\),\s*COSINE\)/i, 'Db2 doc chunk SQL uses native VECTOR_DISTANCE');
    is(scalar(@$doc_binds), 3, 'Db2 doc chunk bind count is 3');

    my $vec_lit = $db2_builder->format_db2_vector([ 0.5, -0.25, 0.75 ]);
    like($vec_lit, qr/^\[0\.5,-0\.25,0\.75(?:,0){765}\]$/, 'format_db2_vector pads cleanly to 768 floats');
};

# ---------------------------------------------------------------------------
# 2. .memignore Path Filtering & Secret Redaction
# ---------------------------------------------------------------------------
subtest 'MemIgnore path rules and secret redaction' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ig_file = File::Spec->catfile($tmp, '.memignore');
    open my $fh, '>', $ig_file or die $!;
    print {$fh} "# Local ignore rules\nprivate/**\n*.dump\n!safe_secret_doc.md\n";
    close $fh;

    my $ig = NeoPerl::Memory::MemIgnore->new(repo_root => $tmp);
    ok($ig->is_path_ignored('.env'), 'ignores .env by default');
    ok($ig->is_path_ignored('config/.env.production'), 'ignores nested .env.*');
    ok($ig->is_path_ignored('certs/server.pem'), 'ignores *.pem');
    ok($ig->is_path_ignored('private/keys/token.txt'), 'ignores custom .memignore glob');
    ok($ig->is_path_ignored('heap.dump'), 'ignores custom *.dump');
    ok(!$ig->is_path_ignored('safe_secret_doc.md'), 'honors !negation rule');
    ok(!$ig->is_path_ignored('lib/NeoPerl/Memory/Store.pm'), 'allows regular source files');

    my $dirty = join("\n",
        "Connect via postgres://admin:Sup3rS3cretPwd\@db.example.org/app",
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdef0123456789.sig123456",
        "api_key = sk-test-abcdefghijklmnopqrstuvwxyz1234",
        "aws = AKIAIOSFODNN7EXAMPLE",
        "-----BEGIN RSA PRIVATE KEY-----",
        "MIIBOgIBAAJBALeFakeKeyMaterialForTestingOnly",
        "-----END RSA PRIVATE KEY-----",
        "Normal architectural note: use DBI::MT::Pool.",
    );

    ok($ig->contains_secret($dirty), 'detects secrets in text');
    my ($clean, $n) = $ig->redact_text($dirty);
    ok($n >= 5, "redacted $n secret patterns");
    unlike($clean, qr/Sup3rS3cretPwd/, 'URI password redacted');
    unlike($clean, qr/eyJhbGciOiJIUzI1NiJ9/, 'Bearer token redacted');
    unlike($clean, qr/sk-test-abcdef/, 'API key redacted');
    unlike($clean, qr/AKIAIOSFODNN7EXAMPLE/, 'AWS key redacted');
    unlike($clean, qr/MIIBOgIBAAJBALe/, 'PEM key block redacted');
    like($clean, qr/Normal architectural note: use DBI::MT::Pool\./, 'preserves clean engineering text');

    my $blocked = $ig->sanitize_event({ file_path => '.env.local', text => 'DB_PASS=xyz12345' });
    is($blocked, undef, 'sanitize_event drops events from ignored files');
};

# ---------------------------------------------------------------------------
# 3. Live SQLite CI Test Double + DBI::MT::Pool + Hybrid RRF + Hy-Memory Writer
# ---------------------------------------------------------------------------
my $has_sqlite = eval { require DBI; require DBD::SQLite; 1 };
SKIP: {
    skip 'DBI + DBD::SQLite not installed', 3 unless $has_sqlite;

    my $mgr   = NeoPerl::Inference::Manager->new(ram_budget_gb => 20);
    my $store = NeoPerl::Memory::Store->new(
        sqlite_path => ':memory:',
        embedder    => $mgr,
    );

    subtest 'SQLite test double CRUD, scope hierarchy, and hybrid RRF search' => sub {
        is($store->dialect, 'sqlite', 'test double runs in sqlite dialect');

        my $id_global = $store->add_memory({
            scope_level => 'global',
            category    => 'preference',
            content     => 'Prefer strict C11 with -Wall -Wextra -Werror and zero warnings.',
            tags        => 'c11,compiler,style',
            pinned      => 1,
        });
        my $id_repo = $store->add_memory({
            scope_level => 'repo',
            repo_key    => 'neoperl',
            category    => 'architecture',
            content     => 'Relational semantic memory uses IBM Db2 VECTOR_DISTANCE cosine similarity over DBI::MT::Pool.',
            tags        => 'db2,vector,cosine,pool',
        });
        my $id_file = $store->add_memory({
            scope_level => 'file',
            repo_key    => 'neoperl',
            file_path   => 'lib/NeoPerl/Memory/Store.pm',
            symbol_name => 'search',
            category    => 'gotcha',
            content     => 'SQLite in-memory DSNs require max_connections=1 so pool checkouts share the same schema.',
            tags        => 'sqlite,pool,memory',
        });
        my $id_other = $store->add_memory({
            scope_level => 'repo',
            repo_key    => 'other-repo',
            category    => 'fact',
            content     => 'Unrelated frontend CSS palette uses pastel orange gradients.',
            tags        => 'css,ui',
        });

        ok($id_global && $id_repo && $id_file && $id_other, 'inserted memories across global/repo/file scopes');

        my $hits = $store->search(
            query    => 'IBM Db2 vector cosine database pool',
            repo_key => 'neoperl',
            limit    => 5,
        );
        ok(@$hits >= 2, 'hybrid RRF search returned repo + global hits');
        is($hits->[0]{id}, $id_repo, 'top semantic + relational hit is the Db2 vector architecture memory');
        ok($hits->[0]{cosine_score} > 0.35, "high cosine similarity ($hits->[0]{cosine_score})");
        ok(!(grep { $_->{id} == $id_other } @$hits), 'other-repo memory excluded by relational repo filter');

        my $m_after = $store->get_memory($id_repo);
        ok($m_after->{access_count} >= 1, 'access_count incremented on search hit');

        # File-scoped search prioritizes file/symbol specificity
        my $fhits = $store->search(
            query     => 'SQLite in-memory pool max_connections schema',
            repo_key  => 'neoperl',
            file_path => 'lib/NeoPerl/Memory/Store.pm',
            limit     => 3,
        );
        is($fhits->[0]{id}, $id_file, 'file-scoped gotcha ranks first for matching file');
    };

    subtest 'Hy-Memory-30B-A3B ADD / NOOP / UPDATE / SUPERSEDE and lineage traversal' => sub {
        my $writer = NeoPerl::Memory::Writer->new(
            store     => $store,
            inference => $mgr,
            repo_key  => 'neoperl',
        );

        # ADD
        my $r_add = $writer->reconcile_event({
            event_type  => 'GitCommitPost',
            repo_key    => 'neoperl',
            category    => 'decision',
            scope_level => 'repo',
            text        => 'Initial local HTTP layer used HTTP::Tiny for localhost RPC calls.',
        });
        is($r_add->{action}, 'ADD', 'Hy-Memory executes ADD for novel architectural decision');
        my $orig_id = $r_add->{operations}[0]{id};
        ok($orig_id, 'created initial memory id');

        # NOOP on duplicate
        my $r_noop = $writer->reconcile_event({
            event_type  => 'AgyTurnComplete',
            repo_key    => 'neoperl',
            category    => 'decision',
            scope_level => 'repo',
            text        => 'Initial local HTTP layer used HTTP::Tiny for localhost RPC calls.',
        });
        is($r_noop->{action}, 'NOOP', 'Hy-Memory executes NOOP on duplicate statement');

        # UPDATE enrichment
        my $r_upd = $writer->reconcile_event({
            event_type  => 'AgyTurnComplete',
            repo_key    => 'neoperl',
            category    => 'decision',
            scope_level => 'repo',
            text        => 'Also note that initial local HTTP layer supported JSON::PP fallback.',
        });
        is($r_upd->{action}, 'UPDATE', 'Hy-Memory executes UPDATE on enrichment note');
        is($r_upd->{operations}[0]{id}, $orig_id, 'UPDATE modifies existing record in place');

        # SUPERSEDE replacement decision (temporal history preserved)
        my $r_sup = $writer->reconcile_event({
            event_type  => 'GitCommitPost',
            repo_key    => 'neoperl',
            category    => 'decision',
            scope_level => 'repo',
            text        => 'Switched from HTTP::Tiny to Mojolicious Mojo::Server::Daemon and Mojo::UserAgent for local HTTP RPC calls.',
        });
        is($r_sup->{action}, 'SUPERSEDE', 'Hy-Memory executes SUPERSEDE when architecture changes');
        my $new_id = $r_sup->{operations}[0]{id};
        is($r_sup->{operations}[0]{old_id}, $orig_id, 'SUPERSEDE links old memory ID');
        isnt($new_id, $orig_id, 'SUPERSEDE inserts a new successor record');

        my $old_row = $store->get_memory($orig_id);
        is($old_row->{superseded_by_id}, $new_id, 'old row records SUPERSEDED_BY_ID');
        ok(defined $old_row->{valid_until}, 'old row records VALID_UNTIL timestamp');

        # Default search hides superseded row; include_superseded => 1 reveals it
        my $active_hits = $store->search(query => 'HTTP::Tiny Mojolicious local HTTP RPC', repo_key => 'neoperl', limit => 10);
        ok((grep { $_->{id} == $new_id } @$active_hits), 'active search returns new superseding memory');
        ok(!(grep { $_->{id} == $orig_id } @$active_hits), 'active search excludes superseded memory');

        my $all_hits = $store->search(
            query              => 'HTTP::Tiny local HTTP RPC',
            repo_key           => 'neoperl',
            include_superseded => 1,
            limit              => 10,
        );
        ok((grep { $_->{id} == $orig_id } @$all_hits), 'include_superseded => 1 preserves historical memory');

        # Add typed graph edge and verify get_related + lineage traversal
        my $aux_id = $store->add_memory({
            scope_level => 'repo',
            repo_key    => 'neoperl',
            category    => 'fact',
            content     => 'Mojo::MT::Accel enables NEON/AVX2/VSX acceleration for Mojo::JSON and Mojo::Reactor::MT.',
        });
        $store->add_edge($new_id, $aux_id, 'extends', 0.95);

        my $rel = $store->get_related($new_id, depth => 2);
        ok(@{ $rel->{edges} } >= 2, 'get_related returns extends + supersedes edges');
        ok((grep { $_->{id} == $aux_id } @{ $rel->{related} }), 'graph traversal reaches connected memory');
        ok((grep { $_->{id} == $orig_id } @{ $rel->{supersedes} }), 'temporal lineage tracks superseded ancestor');

        my $rel_old = $store->get_related($orig_id);
        ok((grep { $_->{id} == $new_id } @{ $rel_old->{superseded_by} }), 'forward lineage from old memory points to successor');

        # Ignored file & secret redaction through Writer
        my $r_ign = $writer->reconcile_event({
            event_type => 'AgyTurnComplete',
            repo_key   => 'neoperl',
            file_path  => 'deploy/.env',
            text       => 'SECRET_KEY=sk-live-123456789012345678901234',
        });
        is($r_ign->{action}, 'IGNORED', 'Writer drops event from .env file');

        my $r_sec = $writer->save_explicit(
            repo_key => 'neoperl',
            category => 'gotcha',
            content  => 'Never commit token Bearer abcdefghijklmnopqrstuvwxyz12345 in scripts.',
        );
        is($r_sec->{action}, 'ADD', 'Writer persists non-ignored event after redacting secret');
        my $saved = $store->get_memory($r_sec->{operations}[0]{id});
        unlike($saved->{content}, qr/abcdefghijklmnopqrstuvwxyz12345/, 'secret redacted before persisting in Db2/SQLite');
        like($saved->{content}, qr/\[REDACTED:BEARER\]/, 'redaction marker preserved');

        my $events = $store->list_events(repo => 'neoperl', limit => 20);
        ok(@$events >= 5, 'provenance event trail recorded in NPL_MEMORY_EVENTS');
    };

    subtest 'Pin, forget, and Store stats' => sub {
        my $id = $store->add_memory({
            scope_level => 'repo',
            repo_key    => 'neoperl',
            category    => 'fact',
            content     => 'Temporary note to forget later.',
        });
        $store->pin_memory($id, 1);
        is($store->get_memory($id)->{pinned}, 1, 'pin_memory sets PINNED=1');

        $store->forget_memory($id);
        my $after = $store->get_memory($id);
        ok(defined $after->{valid_until}, 'soft forget sets VALID_UNTIL');
        is($after->{pinned}, 0, 'soft forget clears PINNED');

        my $st = $store->stats();
        ok($st->{active_memories} >= 4, 'stats reports active memories');
        ok($st->{superseded_memories} >= 1, 'stats reports superseded memories');
        ok($st->{edges} >= 2, 'stats reports graph edges');
    };
}

done_testing();
