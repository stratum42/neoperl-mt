use strict;
use warnings;
use Test::More;
use File::Spec ();
use File::Temp qw(tempdir);

use NeoPerl::Inference::Config;
use NeoPerl::Inference::Manager;
use NeoPerl::Inference::ModelHub;
use NeoPerl::Inference::Vision;
use NeoPerl::Inference::OffloadQueue;
use NeoPerl::Memory::Store;

# Minimal mock buffer exposing stage_diff_proposal / accept_all_hunks / reject_all_hunks
{
    package LocalTestBuffer;
    sub new {
        my ($class, %a) = @_;
        return bless {
            path      => $a{path} // 'lib/Demo.pm',
            text      => $a{text} // '',
            proposals => [],
            accepted  => 0,
            rejected  => 0,
        }, $class;
    }
    sub path { $_[0]{path} }
    sub text { $_[0]{text} }
    sub set_text { $_[0]{text} = $_[1] }
    sub stage_diff_proposal {
        my ($self, $new_text, %meta) = @_;
        push @{ $self->{proposals} }, { new_text => $new_text, meta => \%meta };
        return [ { kind => 'add', old_start => 1, old_count => 0, new_start => 1, new_count => 3 } ];
    }
    sub accept_all_hunks {
        my ($self) = @_;
        if (@{ $self->{proposals} }) {
            $self->{text} = $self->{proposals}[-1]{new_text};
        }
        $self->{accepted}++;
        return 1;
    }
    sub reject_all_hunks {
        my ($self) = @_;
        $self->{rejected}++;
        return 1;
    }
}

# Build a minimal valid PNG header (128x64) for deterministic Vision tests
sub make_test_png {
    my ($w, $h) = @_;
    $w ||= 128;
    $h ||= 64;
    my $sig  = "\x89PNG\r\n\x1a\n";
    my $ihdr_data = pack('N N C C C C C', $w, $h, 8, 2, 0, 0, 0);
    my $ihdr = pack('N', length($ihdr_data)) . 'IHDR' . $ihdr_data . pack('N', 0);
    my $iend = pack('N', 0) . 'IEND' . pack('N', 0);
    return $sig . $ihdr . $iend;
}

# Build a minimal 2-page PDF byte stream
sub make_test_pdf {
    return join("\n",
        '%PDF-1.4',
        '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj',
        '2 0 obj << /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >> endobj',
        '3 0 obj << /Type /Page /Parent 2 0 R >> stream (Architecture Diagram IBM Db2 Vector Index) endstream endobj',
        '4 0 obj << /Type /Page /Parent 2 0 R >> stream (Benchmark Latency Summary 120 FPS) endstream endobj',
        '%%EOF',
    );
}

# ---------------------------------------------------------------------------
# 1. Config: 4 Roles, Upstream vs Prism ML Fork Isolation, Validation
# ---------------------------------------------------------------------------
subtest 'Hybrid Inference Config: 4 roles and upstream vs Prism ML fork isolation' => sub {
    my $cfg = NeoPerl::Inference::Config->new(
        ram_budget_gb => 20,
        roles         => {
            vision_doc => {
                transport   => 'managed_server',
                server_bin  => '/usr/local/bin/llama-server',
                model_path  => '/models/granite-vision-4.1-4b-Q4_K_M.gguf',
                mmproj_path => '/models/mmproj-granite-vision-4.1-4b-f16.gguf',
            },
            worker_small => {
                transport  => 'managed_server',
                server_bin => '/opt/prism-llama/bin/prism-llama-server',
                model_path => '/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf',
            },
            memory_writer => {
                transport  => 'remote_http',
                remote_url => 'http://192.0.2.10:8081',
            },
        },
    );

    my ($ok, $errs) = $cfg->validate();
    ok($ok, 'multi-transport hybrid config validates cleanly') or diag(join('; ', @$errs));

    is($cfg->role_config('vision_doc')->{backend_fork},   'upstream', 'Granite-Vision uses upstream llama.cpp');
    is($cfg->role_config('worker_small')->{backend_fork}, 'prism-ml', 'Ternary-Bonsai uses isolated Prism ML fork');
    is($cfg->role_config('memory_writer')->{defaults}{reasoning_effort}, 'no_think', 'Hy-Memory defaults to no_think');
    is($cfg->role_config('memory_writer')->{defaults}{temperature}, 0.0, 'Hy-Memory defaults to temperature=0.0');
    is($cfg->role_config('embedder')->{pinned}, 1, 'embedder is pinned by default');

    my $vis_cmd = $cfg->build_server_command('vision_doc', 18081);
    is($vis_cmd->[0], '/usr/local/bin/llama-server', 'vision_doc targets upstream server binary');
    ok((grep { $_ eq '--mmproj' } @$vis_cmd), 'vision_doc command includes --mmproj');

    my $bon_cmd = $cfg->build_server_command('worker_small', 18082);
    is($bon_cmd->[0], '/opt/prism-llama/bin/prism-llama-server', 'worker_small targets isolated Prism ML binary');
    isnt($bon_cmd->[0], $vis_cmd->[0], 'upstream and Prism ML binaries remain cleanly separated');
};

# ---------------------------------------------------------------------------
# 2. Smart LRU RAM Residency Manager & Remote Never-Evict Guarantee
# ---------------------------------------------------------------------------
subtest 'Smart LRU RAM residency eviction and pinned/remote guarantees' => sub {
    my $cfg = NeoPerl::Inference::Config->new(
        ram_budget_gb => 11.0,
        roles         => {
            # memory_writer (9.1 GB), vision_doc (3.5 GB), worker_small (6.0 GB), embedder (0.4 GB pinned)
            embedder      => { transport => 'loopback', pinned => 1, estimated_ram_gb => 0.4 },
            memory_writer => { transport => 'loopback', estimated_ram_gb => 9.1 },
            vision_doc    => { transport => 'loopback', estimated_ram_gb => 3.5 },
            worker_small  => { transport => 'loopback', estimated_ram_gb => 6.0 },
        },
    );
    my $mgr = NeoPerl::Inference::Manager->new(config => $cfg);

    # Load embedder (0.4 GB) + memory_writer (9.1 GB) => 9.5 GB <= 11.0 GB
    $mgr->embed('test vector');
    $mgr->complete(role => 'memory_writer', prompt => 'fact one');
    is($mgr->resident_gb, 9.5, 'resident RAM tracks embedder + memory_writer (9.5 GB)');

    # Load vision_doc (3.5 GB): 9.5 + 3.5 = 13.0 > 11.0 => evicts memory_writer, keeps pinned embedder
    $mgr->complete(role => 'vision_doc', prompt => 'parse diagram');
    is($mgr->resident_gb, 3.9, 'memory_writer evicted to fit vision_doc (0.4 + 3.5 = 3.9 GB)');

    my %by_role = map { $_->{role} => $_ } @{ $mgr->slot_status };
    is($by_role{embedder}{loaded},      1, 'pinned embedder stayed resident');
    is($by_role{memory_writer}{loaded}, 0, 'LRU memory_writer was evicted');
    is($by_role{memory_writer}{evict_count}, 1, 'evict_count incremented on memory_writer');
    is($by_role{vision_doc}{loaded},    1, 'vision_doc is now loaded');

    # Load worker_small (6.0 GB): 3.9 + 6.0 = 9.9 GB <= 11.0 GB => fits without evicting vision_doc
    $mgr->complete(role => 'worker_small', prompt => 'doc task');
    is($mgr->resident_gb, 9.9, 'embedder + vision_doc + worker_small coexist within 11 GB budget');

    # Remote HTTP slot consumes 0 local RAM and is never evicted
    my $remote_called = 0;
    my $rcfg = NeoPerl::Inference::Config->new(
        ram_budget_gb => 8.0,
        roles         => {
            memory_writer => { transport => 'remote_http', remote_url => 'http://192.0.2.20:8081' },
            worker_small  => { transport => 'loopback', estimated_ram_gb => 6.0 },
        },
    );
    my $rmgr = NeoPerl::Inference::Manager->new(
        config         => $rcfg,
        http_transport => sub {
            my ($method, $url, $body) = @_;
            $remote_called++;
            return {
                ok     => 1,
                status => 200,
                engine => 'Mojo::UserAgent',
                json   => {
                    choices => [ { message => { content => '[{"op":"NOOP"}]' } } ],
                    usage   => { prompt_tokens => 12, completion_tokens => 5 },
                },
            };
        },
    );
    $rmgr->complete(role => 'memory_writer', prompt => 'check remote');
    $rmgr->complete(role => 'worker_small',  prompt => 'check local');
    is($remote_called, 1, 'remote_http invoked configured LAN endpoint');
    is($rmgr->resident_gb, 6.0, 'remote_http consumes 0.0 GB of local RAM budget');
    my %rslots = map { $_->{role} => $_ } @{ $rmgr->slot_status };
    is($rslots{memory_writer}{loaded}, 1, 'remote_http slot is never evicted');
    is($rslots{memory_writer}{evict_count}, 0, 'remote_http evict_count remains 0');
};

# ---------------------------------------------------------------------------
# 3. LIVE Mojo::UserAgent + Mojo::Server::Daemon HTTP Round-Trip (when Mojo present)
# ---------------------------------------------------------------------------
SKIP: {
    skip 'Mojolicious not in @INC', 1 unless NeoPerl::Inference::Manager::has_mojo_ua();

    subtest 'Live Mojo::UserAgent HTTP round-trip against localhost OpenAI-compatible server' => sub {
        my @inc_flags = map { "-I$_" } grep { defined $_ && !ref($_) && length $_ } @INC;
        my $server_code = <<'END_SRV';
use strict;
use warnings;
use IO::Handle;
use Mojolicious;
use Mojo::Server::Daemon;
use Mojo::IOLoop;
STDOUT->autoflush(1);
my $app = Mojolicious->new;
$app->log->level('fatal');
$app->routes->post('/v1/chat/completions' => sub {
    my $c = shift;
    my $req = $c->req->json || {};
    $c->render(json => {
        choices => [ { message => { content => 'LIVE_MOJO_REPLY:' . ($req->{model} // '') } } ],
        usage   => { prompt_tokens => 20, completion_tokens => 10 },
    });
});
$app->routes->post('/v1/embeddings' => sub {
    my $c = shift;
    $c->render(json => { data => [ { embedding => [ (0.25) x 8 ] } ] });
});
my $daemon = Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1:0'], silent => 1);
$daemon->start;
print 'PORT=', $daemon->ports->[0], "\n";
Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;
END_SRV

        my $pid = open(my $child_fh, '-|', $^X, @inc_flags, '-e', $server_code);
        SKIP: {
            skip 'child process spawn unavailable', 1 unless defined $pid;
            my $ready_line = <$child_fh>;
            my ($port) = (($ready_line // '') =~ /PORT=(\d+)/);
            ok($port && $port > 0, "child Mojo::Server::Daemon bound on 127.0.0.1:" . ($port // 0));

            my $ok_live = eval {
                my $cfg = NeoPerl::Inference::Config->new(roles => {
                    worker_small => { transport => 'remote_http', remote_url => "http://127.0.0.1:$port" },
                    embedder     => { transport => 'remote_http', remote_url => "http://127.0.0.1:$port" },
                });
                my $mgr = NeoPerl::Inference::Manager->new(config => $cfg);
                my $res = $mgr->complete(role => 'worker_small', prompt => 'hello mojo');
                like($res->{text}, qr/LIVE_MOJO_REPLY:prism-ml\/Ternary-Bonsai-2-27B-gguf/, 'Mojo::UserAgent live chat completion succeeded');
                is($res->{http_engine}, 'Mojo::UserAgent', 'confirmed Mojo::UserAgent engine');
                my $emb = $mgr->embed('hello embedding');
                is(scalar(@$emb), 8, 'Mojo::UserAgent live /v1/embeddings succeeded');
                my $tel = $mgr->telemetry();
                is($tel->{http_engine}, 'Mojo::UserAgent', 'telemetry reports Mojo::UserAgent');
                1;
            };
            my $err = $@;
            kill('TERM', $pid);
            close $child_fh;
            waitpid($pid, 0);
            ok($ok_live, 'live Mojolicious child HTTP round-trip completed cleanly') or diag($err);
        }
    };
}

# ---------------------------------------------------------------------------
# 4. ModelHub GGUF Inspection & Download Recipes
# ---------------------------------------------------------------------------
subtest 'ModelHub GGUF header inspection and recipes' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $fake_gguf = File::Spec->catfile($tmp, 'sample.gguf');
    open my $fh, '>:raw', $fake_gguf or die $!;
    print {$fh} 'GGUF' . pack('V Q< Q<', 3, 256, 32) . ("\0" x 128);
    close $fh;

    my $cfg = NeoPerl::Inference::Config->new(
        model_dir => $tmp,
        roles     => { embedder => { model_path => $fake_gguf } },
    );
    my $mhub = NeoPerl::Inference::ModelHub->new(config => $cfg);

    my $info = $mhub->inspect_gguf($fake_gguf);
    is($info->{valid_gguf},   1,   'valid GGUF header signature recognized');
    is($info->{gguf_version}, 3,   'GGUF v3 parsed');
    is($info->{tensor_count}, 256, 'tensor count parsed');
    is($info->{kv_count},     32,  'KV count parsed');

    my $rep_txt = $mhub->format_report_text(skip_exec => 1);
    like($rep_txt, qr/Hy-Memory-30B-A3B/,    'ModelHub report lists Hy-Memory');
    like($rep_txt, qr/Granite-Vision-4\.1-4B/, 'ModelHub report lists Granite-Vision');
    like($rep_txt, qr/Ternary-Bonsai-2-27B/, 'ModelHub report lists Ternary-Bonsai');
    like($rep_txt, qr/GGUF v3/,              'ModelHub report shows inspected GGUF version');
};

# ---------------------------------------------------------------------------
# 5. Granite-Vision-4.1-4B Preprocessing + SHA-256 Db2 Cache + Chunk Indexing
# ---------------------------------------------------------------------------
my $has_sqlite = eval { require DBI; require DBD::SQLite; 1 };
SKIP: {
    skip 'DBI + DBD::SQLite not installed', 3 unless $has_sqlite;

    my $mgr   = NeoPerl::Inference::Manager->new(ram_budget_gb => 20);
    my $store = NeoPerl::Memory::Store->new(sqlite_path => ':memory:', embedder => $mgr);

    subtest 'Granite-Vision PNG/PDF/clipboard preprocessing + SHA-256 cache + chunks' => sub {
        my $tmp = tempdir(CLEANUP => 1);
        my $png_path = File::Spec->catfile($tmp, 'arch_diagram.png');
        open my $pfh, '>:raw', $png_path or die $!;
        print {$pfh} make_test_png(640, 480);
        close $pfh;

        my $pdf_path = File::Spec->catfile($tmp, 'design_spec.pdf');
        open my $dfh, '>:raw', $pdf_path or die $!;
        print {$dfh} make_test_pdf();
        close $dfh;

        my $vision = NeoPerl::Inference::Vision->new(
            inference        => $mgr,
            store            => $store,
            clipboard_reader => sub { make_test_png(320, 200) },
        );

        # First PNG pass -> cache MISS
        my $doc1 = $vision->preprocess_file(
            path      => $png_path,
            format    => 'markdown',
            text_hint => 'IBM Db2 12.1.2 VECTOR_DISTANCE architecture diagram',
        );
        is($doc1->{cached}, 0, 'first PNG parse is a cache miss');
        is($doc1->{width},  640, 'PNG width parsed from IHDR');
        is($doc1->{height}, 480, 'PNG height parsed from IHDR');
        ok($doc1->{doc_id}, 'stored in NPL_DOC_CACHE');
        like($doc1->{content}, qr/arch_diagram\.png/, 'markdown output references source image');
        ok(@{ $doc1->{chunks} } >= 1, 'document chunked and embedded');

        my %slots_before = map { $_->{role} => $_->{request_count} } @{ $mgr->slot_status };

        # Second identical PNG pass -> SHA-256 cache hit (no extra vision requests)
        my $doc2 = $vision->preprocess_file(path => $png_path, format => 'markdown');
        is($doc2->{cached}, 1, 'second identical PNG parse hits SHA-256 NPL_DOC_CACHE');
        is($doc2->{doc_id}, $doc1->{doc_id}, 'returns same cached doc_id');
        my %slots_after = map { $_->{role} => $_->{request_count} } @{ $mgr->slot_status };
        is($slots_after{vision_doc}, $slots_before{vision_doc}, 'cache hit triggers zero inference calls');

        # Different format (table_json) parses cleanly and caches separately
        my $tbl = $vision->preprocess_file(path => $png_path, format => 'table_json');
        is($tbl->{cached}, 0, 'table_json format is cached independently from markdown');
        like($tbl->{content}, qr/"columns"/, 'table_json emits structured JSON table');

        # Multi-page PDF rasterization & chunk semantic search
        my $pdf_doc = $vision->preprocess_file(path => $pdf_path, format => 'markdown');
        is($pdf_doc->{page_count}, 2, 'multi-page PDF detects 2 pages');
        ok($pdf_doc->{cloud_tokens_saved} >= 400, 'tracks cloud vision tokens saved');

        my $chunk_hits = $store->search_doc_chunks(query => 'IBM Db2 Vector Index', limit => 3);
        ok(@$chunk_hits >= 1, 'embedded NPL_DOC_CHUNKS are semantically searchable');

        # Clipboard screenshot (<leader>vp)
        my $clip = $vision->preprocess_clipboard(format => 'markdown');
        is($clip->{source_path}, '<clipboard>', 'clipboard image preprocessed');
        is($clip->{width}, 320, 'clipboard PNG dimensions parsed');
    };

    # -----------------------------------------------------------------------
    # 6. Ternary-Bonsai-2-27B Out-of-Band OffloadQueue + perl -c + Diff Hunks
    # -----------------------------------------------------------------------
    subtest 'Ternary-Bonsai OffloadQueue: syntax check, diff hunks, auto-apply, token savings' => sub {
        my $src = "package Sample::Math;\nuse strict;\nuse warnings;\n\nsub add {\n    my (\$a, \$b) = \@_;\n    return \$a + \$b;\n}\n\n1;\n";
        my $buf = LocalTestBuffer->new(path => 'lib/Sample/Math.pm', text => $src);

        my $q = NeoPerl::Inference::OffloadQueue->new(
            inference => $mgr,
            store     => $store,
        );

        # Enqueue doc job -> immediate job_id returned with status 'queued'
        my $jid = $q->enqueue(
            kind        => 'doc',
            target_path => 'lib/Sample/Math.pm',
            buffer      => $buf,
        );
        like($jid, qr/^bonsai-/, 'enqueue immediately returns bonsai-* job_id');
        is($q->job_status($jid)->{status}, 'queued', 'job starts queued before pump');

        $q->pump(2);
        my $st = $q->job_status($jid);
        is($st->{status},    'staged', 'completed doc job transitions to staged');
        is($st->{syntax_ok}, 1,        'generated Perl POD passed live perl -c syntax check');
        ok($st->{cloud_tokens_saved} >= 64, "recorded $st->{cloud_tokens_saved} cloud tokens saved");
        is(scalar(@{ $buf->{proposals} }), 1, 'inline red/green diff proposal staged on target buffer');
        like($st->{output_text}, qr/=head1 NAME/, 'Bonsai doc output includes POD');

        # Accept staged job -> updates buffer & DB status
        my $acc = $q->accept_job($jid);
        ok($acc->{ok}, 'accept_job succeeded');
        is($q->job_status($jid)->{status}, 'applied', 'accepted job marked applied');
        like($buf->text, qr/=head1 NAME/, 'buffer received accepted POD');

        # Auto-apply when auto_apply_docs_if_syntax_ok => 1 and syntax OK
        my $buf2 = LocalTestBuffer->new(path => 'lib/Sample/Helper.pm', text => $src);
        my $jid2 = $q->enqueue(
            kind                         => 'comments',
            target_path                  => 'lib/Sample/Helper.pm',
            buffer                       => $buf2,
            auto_apply_docs_if_syntax_ok => 1,
        );
        $q->pump(2);
        is($q->job_status($jid2)->{status}, 'applied', 'auto_apply_docs_if_syntax_ok auto-applied verified comments');
        like($buf2->text, qr/# add:/, 'auto-applied comments inserted into buffer');

        # Test remaining kinds: test_scaffold, refactor_local, commit_msg, summarize
        my $jid_test = $q->enqueue(kind => 'test_scaffold', target_path => 't/sample.t', source_code => $src);
        my $jid_ref  = $q->enqueue(kind => 'refactor_local', target_path => 'lib/Legacy.pm', source_code => "sub old { return undef; }\n1;\n");
        my $jid_cmsg = $q->enqueue(kind => 'commit_msg', target_path => 'lib/Sample/Math.pm', instruction => 'Add POD docs to Sample::Math');
        my $jid_sum  = $q->enqueue(kind => 'summarize', target_path => 'lib/Sample/Math.pm', source_code => $src);
        my $jid_can  = $q->enqueue(kind => 'summarize', target_path => 'lib/Cancel.pm', source_code => $src);
        $q->cancel_job($jid_can);
        $q->pump(10);

        is($q->job_status($jid_test)->{syntax_ok}, 1, 'test_scaffold passed perl -c');
        like($q->job_status($jid_ref)->{output_text}, qr/return;/, 'refactor_local fixed return undef');
        like($q->job_status($jid_cmsg)->{output_text}, qr/Add POD docs/, 'commit_msg generated concise commit message');
        like($q->job_status($jid_sum)->{output_text}, qr/Subroutines: add/, 'summarize extracted subroutine list');
        is($q->job_status($jid_can)->{status}, 'cancelled', 'cancel_job marks job cancelled');

        # Verify NPL_LOCAL_JOBS ledger & Cloud Tokens Saved counter
        my $ledger = $store->token_savings_summary();
        ok($ledger->{total_jobs} >= 6, 'NPL_LOCAL_JOBS persisted all jobs');
        ok($ledger->{cloud_tokens_saved} > 300, "ledger recorded $ledger->{cloud_tokens_saved} total cloud tokens saved");
        ok($mgr->telemetry()->{estimated_cloud_tokens_saved} > 300, 'Inference::Manager tracks estimated_cloud_tokens_saved');
    };

    # -----------------------------------------------------------------------
    # 7. Real perl5-mt MT::Pool + MT::Channel Execution (run last after all loads)
    # -----------------------------------------------------------------------
    SKIP: {
        skip 'perl5-mt MT::Pool not available (stock Perl 5)', 1
            unless $NeoPerl::Inference::OffloadQueue::HAS_MT_POOL;

        subtest 'perl5-mt MT::Pool + MT::Channel real worker thread offload' => sub {
            my $mt_q = NeoPerl::Inference::OffloadQueue->new(
                inference  => $mgr,
                store      => $store,
                async_mode => 'mt_pool',
                workers    => 1,
            );
            is($mt_q->async_mode, 'mt_pool', 'OffloadQueue running on real perl5-mt MT::Pool');
            ok($mt_q->has_mt_channel, 'MT::Channel active');

            my $jid = $mt_q->enqueue(
                kind        => 'doc',
                target_path => 'lib/MT/Sample.pm',
                source_code => "package MT::Sample;\nuse strict;\nuse warnings;\nsub work { return 42; }\n1;\n",
            );
            my $res = $mt_q->wait_job($jid, 10);
            is($res->{status},    'staged', 'MT::Worker completed out-of-band Bonsai job');
            is($res->{syntax_ok}, 1,        'MT::Worker generated syntax-valid Perl');
            like($res->{output_text}, qr/=head1 NAME/, 'MT::Worker output contains generated POD');
            $mt_q->shutdown();
        };
    }
}

done_testing();
