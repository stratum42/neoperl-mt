use strict;
use warnings;
use utf8;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use Time::HiRes qw(time);
use Compress::Zlib ();
use Test::More;

my $ROOT;

BEGIN {
    $ROOT = abs_path(File::Spec->catdir($FindBin::RealBin, File::Spec->updir));
    for my $rel (
        File::Spec->catdir('blib', 'arch'),
        File::Spec->catdir('blib', 'lib'),
        'lib',
    ) {
        my $dir = File::Spec->catdir($ROOT, $rel);
        unshift @INC, $dir if -d $dir;
    }

    # Auto-detect optional sibling MT repositories without hardcoded user paths
    my $parent = File::Spec->catdir($ROOT, File::Spec->updir);
    my %have = map { $_ => 1 } grep { !ref($_) } @INC;
    my $prepend = sub {
        my ($d) = @_;
        return unless defined $d && -d $d;
        my $abs = eval { abs_path($d) } || $d;
        return if $have{$abs};
        unshift @INC, $abs;
        $have{$abs} = 1;
    };

    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    $prepend->(File::Spec->catdir($home, 'perl5', 'lib', 'perl5')) if length $home;

    for my $spec (
        [ $ENV{NEOPERL_DBD_SQLITE_DIR}, 'dbd-sqlite-mt',  [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBI_DIR},        'dbi-mt',         [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_MOJO_DIR},       'mojolicious-mt', [ 'xs/blib/arch', 'xs/blib/lib', 'lib' ] ],
        [ $ENV{TCL_TK_MT_DIR} || $ENV{NEOPERL_TK_DIR}, 'tcl-tk-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
    ) {
        my ($env_dir, $repo, $subs) = @$spec;
        my $base = (defined $env_dir && length $env_dir && -d $env_dir)
            ? $env_dir
            : File::Spec->catdir($parent, $repo);
        next unless -d $base;
        for my $rel (reverse @$subs) {
            $prepend->(File::Spec->catdir($base, split('/', $rel)));
        }
    }
}

use_ok('NeoPerl::Inference::Config');
use_ok('NeoPerl::Inference::Manager');
use_ok('NeoPerl::Inference::ModelHub');
use_ok('NeoPerl::Inference::Vision');
use_ok('NeoPerl::Inference::OffloadQueue');
use_ok('NeoPerl::Memory::Store');
use_ok('NeoPerl::Memory::Writer');

# Track any live managers so END always shuts down child servers cleanly
my @ACTIVE_MANAGERS;
END {
    for my $m (@ACTIVE_MANAGERS) {
        eval { $m->shutdown_all() } if defined $m;
    }
}

sub _track_mgr {
    my ($mgr) = @_;
    push @ACTIVE_MANAGERS, $mgr;
    return $mgr;
}

# Lightweight buffer double for OffloadQueue live staging/accept checks
{
    package LiveTestBuffer;
    sub new {
        my ($class, %a) = @_;
        return bless {
            path      => $a{path} // 'lib/Demo/Math.pm',
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
        return 1;
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

sub _l2_norm {
    my ($vec) = @_;
    my $s = 0.0;
    $s += ($_ * $_) for @$vec;
    return sqrt($s);
}

sub _cosine {
    my ($a, $b) = @_;
    my ($dot, $na, $nb) = (0.0, 0.0, 0.0);
    my $n = @$a < @$b ? scalar(@$a) : scalar(@$b);
    for (my $i = 0; $i < $n; $i++) {
        $dot += $a->[$i] * $b->[$i];
        $na  += $a->[$i] * $a->[$i];
        $nb  += $b->[$i] * $b->[$i];
    }
    return ($na > 0 && $nb > 0) ? ($dot / (sqrt($na) * sqrt($nb))) : 0.0;
}

sub _png_chunk {
    my ($type, $data) = @_;
    my $crc = Compress::Zlib::crc32($type . $data);
    return pack('N', length($data)) . $type . $data . pack('N', $crc);
}

sub _rgba_to_png {
    my ($rgba, $w, $h) = @_;
    my $stride = $w * 4;
    my @scans;
    for my $y (0 .. $h - 1) {
        push @scans, "\x00" . substr($rgba, $y * $stride, $stride);
    }
    my $zdat = Compress::Zlib::compress(join('', @scans), 6);
    my $ihdr = pack('N N C C C C C', $w, $h, 8, 6, 0, 0, 0);
    return "\x89PNG\r\n\x1a\n"
         . _png_chunk('IHDR', $ihdr)
         . _png_chunk('IDAT', $zdat)
         . _png_chunk('IEND', '');
}

# Render a high-contrast PNG containing known prose and Perl code.
# Uses headless Tcl::Tk::MT::Canvas when available, with a pure-Perl fallback.
sub _render_readable_png {
    my ($out_path) = @_;
    my $rendered = eval {
        require Tcl::Tk::MT::Canvas;
        my ($w, $h) = (760, 320);
        my $c = Tcl::Tk::MT::Canvas->new(
            undef,
            '-width'    => $w,
            '-height'   => $h,
            '-bg'       => '#ffffff',
            '-headless' => 1,
            '-scale'    => 2.0,
        );
        $c->createRectangle(0, 0, $w, $h, '-fill' => '#ffffff', '-outline' => '#ffffff');
        $c->createText(32, 28,  '-text' => 'NeoPerl MT Local Inference',              '-fill' => '#000000', '-font' => ['Helvetica', 24], '-anchor' => 'nw');
        $c->createText(32, 78,  '-text' => 'Database: IBM Db2 12.1.2 VECTOR_DISTANCE','-fill' => '#000000', '-font' => ['Helvetica', 18], '-anchor' => 'nw');
        $c->createText(32, 128, '-text' => 'sub add_numbers {',                       '-fill' => '#000000', '-font' => ['Courier', 18],   '-anchor' => 'nw');
        $c->createText(32, 160, '-text' => '    my ($a, $b) = @_;',                   '-fill' => '#000000', '-font' => ['Courier', 18],   '-anchor' => 'nw');
        $c->createText(32, 192, '-text' => '    return $a + $b;',                     '-fill' => '#000000', '-font' => ['Courier', 18],   '-anchor' => 'nw');
        $c->createText(32, 224, '-text' => '}',                                       '-fill' => '#000000', '-font' => ['Courier', 18],   '-anchor' => 'nw');
        $c->render();
        my $rgba = $c->readback_rgba();
        my $pixels = int(length($rgba) / 4);
        my $pw = int(sqrt($pixels * $w / $h) + 0.5);
        my $ph = int($pixels / $pw);
        my $png = _rgba_to_png($rgba, $pw, $ph);
        open my $fh, '>:raw', $out_path or die "write $out_path: $!";
        print {$fh} $png;
        close $fh;
        1;
    };
    return 'Tcl::Tk::MT::Canvas' if $rendered && -f $out_path && (-s $out_path) > 1000;

    # Pure-Perl bold 5x7 bitmap fallback (white background, black letters)
    my %FONT = (
        ' ' => [qw(00000 00000 00000 00000 00000 00000 00000)],
        'A' => [qw(01110 10001 10001 11111 10001 10001 10001)],
        'B' => [qw(11110 10001 10001 11110 10001 10001 11110)],
        'C' => [qw(01110 10001 10000 10000 10000 10001 01110)],
        'D' => [qw(11110 10001 10001 10001 10001 10001 11110)],
        'E' => [qw(11111 10000 10000 11110 10000 10000 11111)],
        'I' => [qw(11111 00100 00100 00100 00100 00100 11111)],
        'L' => [qw(10000 10000 10000 10000 10000 10000 11111)],
        'M' => [qw(10001 11011 10101 10101 10001 10001 10001)],
        'N' => [qw(10001 11001 10101 10011 10001 10001 10001)],
        'O' => [qw(01110 10001 10001 10001 10001 10001 01110)],
        'P' => [qw(11110 10001 10001 11110 10000 10000 10000)],
        'R' => [qw(11110 10001 10001 11110 10100 10010 10001)],
        'S' => [qw(01111 10000 10000 01110 00001 00001 11110)],
        'T' => [qw(11111 00100 00100 00100 00100 00100 00100)],
        'U' => [qw(10001 10001 10001 10001 10001 10001 01110)],
        'V' => [qw(10001 10001 10001 10001 10001 01010 00100)],
        '2' => [qw(01110 10001 00001 00110 01000 10000 11111)],
        '_' => [qw(00000 00000 00000 00000 00000 00000 11111)],
    );
    my @lines = ('NEOPERL MT', 'IBM DB2', 'SUB ADD');
    my ($scale, $w, $h) = (6, 640, 240);
    my $rgba = ("\xff\xff\xff\xff") x ($w * $h);
    my $black = "\x00\x00\x00\xff";
    for my $li (0 .. $#lines) {
        my $y0 = 30 + $li * 64;
        my $x0 = 32;
        for my $ch (split //, uc($lines[$li])) {
            my $glyph = $FONT{$ch} || $FONT{' '};
            for my $gy (0 .. 6) {
                for my $gx (0 .. 4) {
                    next unless substr($glyph->[$gy], $gx, 1) eq '1';
                    for my $sy (0 .. $scale - 1) {
                        for my $sx (0 .. $scale - 1) {
                            my $px = $x0 + $gx * $scale + $sx;
                            my $py = $y0 + $gy * $scale + $sy;
                            next if $px < 0 || $px >= $w || $py < 0 || $py >= $h;
                            substr($rgba, ($py * $w + $px) * 4, 4, $black);
                        }
                    }
                }
            }
            $x0 += 6 * $scale;
        }
    }
    my $png = _rgba_to_png($rgba, $w, $h);
    open my $fh, '>:raw', $out_path or die "write $out_path: $!";
    print {$fh} $png;
    close $fh;
    return 'pure_perl_bitmap';
}

my $MOCK_FORCED   = $ENV{NEOPERL_INFERENCE_MOCK} ? 1 : 0;
my $HAS_SQLITE    = eval { require DBI; require DBD::SQLite; 1 } ? 1 : 0;
my $PROBE_CFG     = NeoPerl::Inference::Config->new(auto_discover => 1);
my $PROBE_HUB     = NeoPerl::Inference::ModelHub->new(config => $PROBE_CFG);
my $DOCTOR        = $PROBE_HUB->doctor_report();
my %ROLE_READY    = map { $_->{role} => $_->{ready} } @{ $DOCTOR->{roles} };
my $HAS_LIBLLAMA  = ($DOCTOR->{llama_bridge} && $DOCTOR->{llama_bridge}{available}) ? 1 : 0;
my $UPSTREAM_BIN  = NeoPerl::Inference::Config::resolve_binary($ENV{NEOPERL_LLAMA_SERVER} || 'llama-server');
my $IS_POWER      = NeoPerl::Inference::Config::is_power_arch() ? 1 : 0;
my $LOCAL_AI_SKIP = $PROBE_CFG->local_ai_skipped_reason() // '';

note(sprintf(
    'Live inference probe: mock=%d, accel=%s, power=%d, skip=%s, libllama=%d, ready=%d/%d (%s)',
    $MOCK_FORCED,
    $PROBE_CFG->accelerator(),
    $IS_POWER,
    (length($LOCAL_AI_SKIP) ? $LOCAL_AI_SKIP : 'none'),
    $HAS_LIBLLAMA,
    $DOCTOR->{ready_count},
    $DOCTOR->{total_roles},
    join(', ', map { "$_->{role}=" . ($_->{ready} ? $_->{transport} : 'missing') } @{ $DOCTOR->{roles} }),
));

# ---------------------------------------------------------------------------
# Subtest 1: Live embedder (nomic-embed-text-v1.5.Q8_0.gguf)
#            BOTH inproc_libllama AND managed_server llama-server
# ---------------------------------------------------------------------------
subtest '1. Live embedder via inproc_libllama AND managed_server' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'embedder GGUF/runtime not installed on this host' unless $ROLE_READY{embedder};

    my $txt_a = 'search_document: IBM Db2 12.1.2 VECTOR_DISTANCE cosine similarity search';
    my $txt_b = 'search_query: relational database vector index cosine';
    my $txt_c = 'search_document: strawberry shortcake baking recipe with whipped cream';

    my $vec_inproc_a;

    subtest '1A. inproc_libllama embedder + Memory::Store hybrid RRF' => sub {
        plan skip_all => 'libllama shared library not available for inproc_libllama' unless $HAS_LIBLLAMA;

        ok(NeoPerl::Core::LlamaBridge::available(), 'LlamaBridge::available() == 1');
        my $cfg_in = NeoPerl::Inference::Config->new(auto_discover => 1);
        is($cfg_in->role_config('embedder')->{transport}, 'inproc_libllama',
            'auto_discover promotes embedder to inproc_libllama');

        my $mgr_in = _track_mgr(NeoPerl::Inference::Manager->new(config => $cfg_in));

        my $t0 = time();
        my $vA = $mgr_in->embed($txt_a);
        my $t1 = time();
        my $vB = $mgr_in->embed($txt_b);
        my $t2 = time();
        my $vC = $mgr_in->embed($txt_c);
        my $t3 = time();
        my $vA2 = $mgr_in->embed($txt_a);
        my $t4 = time();

        $vec_inproc_a = $vA;

        my $in_slot = (grep { $_->{role} eq 'embedder' } @{ $mgr_in->slot_status })[0];
        is($in_slot->{transport}, 'inproc_libllama', 'embedder slot active via inproc_libllama');
        is(scalar(@$vA), 768, 'inproc_libllama returns 768-dim embedding');

        my $norm_a = _l2_norm($vA);
        my $norm_b = _l2_norm($vB);
        my $norm_c = _l2_norm($vC);
        ok(abs($norm_a - 1.0) < 1e-3 && abs($norm_b - 1.0) < 1e-3 && abs($norm_c - 1.0) < 1e-3,
            sprintf('embeddings are unit L2-normalized (norms=%.6f, %.6f, %.6f)', $norm_a, $norm_b, $norm_c));

        my $cos_rep = _cosine($vA, $vA2);
        ok($cos_rep > 0.9999, sprintf('deterministic repeat embedding cos(A,A2)=%.6f', $cos_rep));

        my $cos_ab = _cosine($vA, $vB);
        my $cos_ac = _cosine($vA, $vC);
        ok($cos_ab > $cos_ac + 0.15,
            sprintf('real semantic separation: cos(DB,DB)=%.6f > cos(DB,recipe)=%.6f (delta=+%.6f)',
                $cos_ab, $cos_ac, $cos_ab - $cos_ac));

        note(sprintf(
            'METRICS[embedder/inproc_libllama]: load_ms=%d first_ms=%.1f warm_ms=%.1f/%.1f/%.1f cos(A,B)=%.6f cos(A,C)=%.6f',
            $in_slot->{load_ms}, ($t1 - $t0) * 1000, ($t2 - $t1) * 1000, ($t3 - $t2) * 1000, ($t4 - $t3) * 1000,
            $cos_ab, $cos_ac,
        ));

        subtest 'Memory::Store hybrid RRF recall with live inproc embeddings' => sub {
            plan skip_all => 'DBI + DBD::SQLite not installed' unless $HAS_SQLITE;
            my $store = NeoPerl::Memory::Store->new(
                sqlite_path => ':memory:',
                embedder    => $mgr_in,
            );
            my $id_db2 = $store->add_memory({
                scope_level => 'repo',
                repo_key    => 'live-embed-test',
                category    => 'architecture',
                content     => 'IBM Db2 12.1.2 VECTOR_DISTANCE cosine similarity index stores 768-dim semantic embeddings.',
                tags        => 'db2,vector,cosine',
            });
            my $id_c11 = $store->add_memory({
                scope_level => 'repo',
                repo_key    => 'live-embed-test',
                category    => 'convention',
                content     => 'Compile all C11 extension files with -std=c11 -Wall -Wextra -Werror.',
                tags        => 'c11,compiler',
            });
            my $id_cake = $store->add_memory({
                scope_level => 'repo',
                repo_key    => 'live-embed-test',
                category    => 'fact',
                content     => 'Bake strawberry shortcake biscuits at 425 degrees Fahrenheit with whipped cream.',
                tags        => 'baking,dessert',
            });
            ok($id_db2 && $id_c11 && $id_cake, 'stored 3 real-embedded memories in Memory::Store');

            my $hits = $store->search(
                query    => 'relational database vector cosine similarity search',
                repo_key => 'live-embed-test',
                limit    => 3,
            );
            is($hits->[0]{id}, $id_db2, 'hybrid RRF recall ranks IBM Db2 vector memory #1');
            my ($cake_hit) = grep { $_->{id} == $id_cake } @$hits;
            ok($hits->[0]{cosine_score} > ($cake_hit ? $cake_hit->{cosine_score} : 0) + 0.15,
                sprintf('top hit cosine (%.4f) strongly exceeds unrelated recipe (%.4f)',
                    $hits->[0]{cosine_score}, ($cake_hit ? $cake_hit->{cosine_score} : 0)));
        };

        $mgr_in->shutdown_all();
    };

    subtest '1B. managed_server llama-server --embedding --pooling mean' => sub {
        plan skip_all => 'upstream llama-server binary not available' unless defined $UPSTREAM_BIN;

        my $cfg_srv = NeoPerl::Inference::Config->new(
            roles => {
                embedder => {
                    transport  => 'managed_server',
                    server_bin => $UPSTREAM_BIN,
                },
            },
        );
        my $cmd = $cfg_srv->build_server_command('embedder', 18099);
        ok((grep { $_ eq '--embedding' } @$cmd) && (grep { $_ eq 'mean' } @$cmd),
            'embedder managed_server command includes --embedding --pooling mean');

        my $mgr_srv = _track_mgr(NeoPerl::Inference::Manager->new(config => $cfg_srv));
        my $s0 = time();
        my $v_srv1 = $mgr_srv->embed($txt_a);
        my $s1 = time();
        my $v_srv2 = $mgr_srv->embed($txt_a);
        my $s2 = time();

        my $srv_slot = (grep { $_->{role} eq 'embedder' } @{ $mgr_srv->slot_status })[0];
        my $srv_pid  = $srv_slot->{pid};
        ok(defined $srv_pid && $srv_pid > 0 && kill(0, $srv_pid),
            "managed llama-server embedder running (pid=$srv_pid, load_ms=$srv_slot->{load_ms})");
        is(scalar(@$v_srv1), 768, 'managed llama-server /v1/embeddings returns 768-dim vector');

        if ($vec_inproc_a) {
            my $cos_cross = _cosine($vec_inproc_a, $v_srv1);
            ok($cos_cross > 0.99,
                sprintf('managed_server vs inproc_libllama cosine similarity = %.6f (> 0.99)', $cos_cross));
            note(sprintf(
                'METRICS[embedder/managed_server]: load_ms=%d first_ms=%.1f warm_ms=%.1f cos(inproc,srv)=%.6f',
                $srv_slot->{load_ms}, ($s1 - $s0) * 1000, ($s2 - $s1) * 1000, $cos_cross,
            ));
        }
        else {
            ok(_l2_norm($v_srv1) > 0.5, 'managed llama-server returned non-zero embedding vector');
        }

        $mgr_srv->shutdown_all();
        ok(!kill(0, $srv_pid), 'managed llama-server embedder terminated cleanly on shutdown_all');
    };
};

# ---------------------------------------------------------------------------
# Subtest 2: Live vision_doc (granite-vision-4.1-4b-Q4_K_M + mmproj-model-f16)
# ---------------------------------------------------------------------------
subtest '2. Live vision_doc (Granite-Vision-4.1-4B multimodal OCR + cache + chunks)' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'vision_doc GGUF/mmproj/llama-server not installed' unless $ROLE_READY{vision_doc};

    my $tmp      = tempdir(CLEANUP => 1);
    my $png_path = File::Spec->catfile($tmp, 'neoperl_spec_live.png');
    my $renderer = _render_readable_png($png_path);
    ok(-f $png_path && (-s $png_path) > 500, "rendered readable high-contrast PNG via $renderer (" . (-s $png_path) . " bytes)");

    my $cfg = NeoPerl::Inference::Config->new(auto_discover => 1);
    is($cfg->role_config('vision_doc')->{transport}, 'managed_server',
        'auto_discover promotes vision_doc to managed_server');

    my $mgr = _track_mgr(NeoPerl::Inference::Manager->new(config => $cfg));
    my $store = $HAS_SQLITE
        ? NeoPerl::Memory::Store->new(sqlite_path => ':memory:', embedder => $mgr)
        : undef;
    my $vis = NeoPerl::Inference::Vision->new(
        inference => $mgr,
        store     => $store,
    );

    my $t0 = time();
    my $doc1 = $vis->preprocess_file(path => $png_path, format => 'markdown');
    my $dt1 = time() - $t0;
    my $vslot = (grep { $_->{role} eq 'vision_doc' } @{ $mgr->slot_status })[0];

    is($doc1->{cached}, 0, 'first markdown preprocess is a cache miss (live inference)');
    ok(length($doc1->{content} // '') > 20, 'Granite-Vision returned non-empty markdown content');
    like($doc1->{content}, qr/NeoPerl/i, 'Granite-Vision genuinely read "NeoPerl" from PNG');
    like($doc1->{content}, qr/IBM/i,     'Granite-Vision genuinely read "IBM" from PNG');
    like($doc1->{content}, qr/Db2/i,     'Granite-Vision genuinely read "Db2" from PNG');
    ok(($doc1->{cloud_tokens_saved} // 0) > 0, "vision recorded cloud_tokens_saved=$doc1->{cloud_tokens_saved}");
    ok(($vslot->{load_ms} // 0) > 0, "vision_doc load_ms=$vslot->{load_ms}");
    ok(($doc1->{tok_per_s} // 0) > 0, "vision_doc markdown tok_per_s=$doc1->{tok_per_s}");

    # Second call with same PNG + markdown format MUST hit SHA-256 NPL_DOC_CACHE
    subtest '2B. NPL_DOC_CACHE SHA-256 hit + NPL_DOC_CHUNKS semantic search' => sub {
        plan skip_all => 'DBI + DBD::SQLite required for NPL_DOC_CACHE verification' unless $store;
        my $doc1_hit = $vis->preprocess_file(path => $png_path, format => 'markdown');
        is($doc1_hit->{cached}, 1, 'second call hits SHA-256 NPL_DOC_CACHE (cached == 1)');
        is($doc1_hit->{doc_id}, $doc1->{doc_id}, 'cache hit returns identical doc_id');
        is($doc1_hit->{content}, $doc1->{content}, 'cache hit returns exact extracted text');

        my $hits = $store->search_doc_chunks(query => 'IBM Db2 VECTOR_DISTANCE', limit => 3);
        ok(@$hits >= 1, 'NPL_DOC_CHUNKS semantic search returned embedded vision chunks');
        like($hits->[0]{content}, qr/Db2|NeoPerl/i,
            sprintf('top chunk matches PNG content (cosine=%.4f)', $hits->[0]{cosine_score} // 0));
    };

    # ocr_code format on the same live PNG
    my $t1 = time();
    my $ocr = $vis->preprocess_file(path => $png_path, format => 'ocr_code');
    my $dt2 = time() - $t1;
    is($ocr->{cached}, 0, 'ocr_code format invokes live Granite-Vision separately from markdown cache');
    like($ocr->{content}, qr/add_numbers|sub\s+add/i, 'ocr_code transcribed visible Perl subroutine from PNG');
    ok(($ocr->{tok_per_s} // 0) > 0, "vision_doc ocr_code tok_per_s=$ocr->{tok_per_s}");

    note(sprintf(
        'METRICS[vision_doc/Granite-Vision-4.1-4B]: load_ms=%d md_ms=%d md_tok_s=%.2f ocr_ms=%d ocr_tok_s=%.2f total_s=%.2f/%.2f',
        $vslot->{load_ms} // 0,
        $doc1->{elapsed_ms} // 0, $doc1->{tok_per_s} // 0,
        $ocr->{elapsed_ms}  // 0, $ocr->{tok_per_s}  // 0,
        $dt1, $dt2,
    ));

    my $vpid = $vslot->{pid};
    $mgr->shutdown_all();
    ok(!kill(0, $vpid), 'vision_doc managed server exited cleanly on shutdown_all');
};

# ---------------------------------------------------------------------------
# Subtest 3: Live worker_small (Ternary-Bonsai-2-27B-PTQ1_0 on prism-llama-server)
# ---------------------------------------------------------------------------
subtest '3. Live worker_small (Ternary-Bonsai-2-27B on prism-llama-server OffloadQueue)' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'worker_small GGUF/prism-llama-server not installed' unless $ROLE_READY{worker_small};

    my $cfg = NeoPerl::Inference::Config->new(auto_discover => 1);
    is($cfg->role_config('worker_small')->{transport}, 'managed_server',
        'auto_discover promotes worker_small to managed_server');
    is($cfg->role_config('worker_small')->{backend_fork}, 'prism-ml',
        'worker_small targets isolated Prism ML fork');

    my $mgr = _track_mgr(NeoPerl::Inference::Manager->new(config => $cfg));
    my $store = $HAS_SQLITE
        ? NeoPerl::Memory::Store->new(sqlite_path => ':memory:', embedder => $mgr)
        : undef;
    my $q = NeoPerl::Inference::OffloadQueue->new(
        inference => $mgr,
        store     => $store,
    );

    my $demo_src = <<'END_DEMO_PM';
package Demo::Math;
use strict;
use warnings;

sub add {
    my ($a, $b) = @_;
    return $a + $b;
}

sub multiply {
    my ($a, $b) = @_;
    return $a * $b;
}

1;
END_DEMO_PM

    # 3A: doc task -> staged, perl -c PASS, Myers hunks, accept_job updates buffer
    my $doc_buf = LiveTestBuffer->new(path => 'lib/Demo/Math.pm', text => $demo_src);
    my $jid_doc = $q->enqueue(
        kind        => 'doc',
        target_path => 'lib/Demo/Math.pm',
        buffer      => $doc_buf,
        source_code => $demo_src,
    );
    $q->pump(1);
    my $st_doc = $q->job_status($jid_doc);
    my $wslot  = (grep { $_->{role} eq 'worker_small' } @{ $mgr->slot_status })[0];

    is($st_doc->{status}, 'staged', 'Bonsai doc job transitions to staged');
    is($st_doc->{syntax_ok}, 1, "Bonsai doc output passes real perl -c ($st_doc->{syntax_output})");
    ok(@{ $st_doc->{hunks} || [] } >= 1, 'Bonsai doc produced non-empty Myers inline diff hunks');
    like($st_doc->{output_text}, qr/=head1\s+NAME/i, 'Bonsai doc generated POD documentation');
    ok(($st_doc->{cloud_tokens_saved} // 0) > 0, "doc cloud_tokens_saved=$st_doc->{cloud_tokens_saved}");
    ok(($st_doc->{tok_per_s} // 0) > 0, "Bonsai doc tok_per_s=$st_doc->{tok_per_s}");

    my $acc = $q->accept_job($jid_doc);
    ok($acc->{ok} && $acc->{status} eq 'applied', 'accept_job cleanly applies staged Bonsai doc diff');
    like($doc_buf->text, qr/=head1\s+NAME/i, 'buffer text updated with accepted POD documentation');

    # 3B: comments task -> staged, perl -c PASS, Myers hunks
    my $cmt_buf = LiveTestBuffer->new(path => 'lib/Demo/Math.pm', text => $demo_src);
    my $jid_cmt = $q->enqueue(
        kind        => 'comments',
        target_path => 'lib/Demo/Math.pm',
        buffer      => $cmt_buf,
        source_code => $demo_src,
    );
    $q->pump(1);
    my $st_cmt = $q->job_status($jid_cmt);

    is($st_cmt->{status}, 'staged', 'Bonsai comments job transitions to staged');
    is($st_cmt->{syntax_ok}, 1, "Bonsai comments output passes real perl -c ($st_cmt->{syntax_output})");
    ok(@{ $st_cmt->{hunks} || [] } >= 1, 'Bonsai comments produced non-empty Myers inline diff hunks');
    like($st_cmt->{output_text}, qr/^\s*#/m, 'Bonsai comments inserted inline Perl comments');
    ok(($st_cmt->{cloud_tokens_saved} // 0) > 0, "comments cloud_tokens_saved=$st_cmt->{cloud_tokens_saved}");

    # 3C: commit_msg task -> staged, concise conventional message
    my $jid_msg = $q->enqueue(
        kind        => 'commit_msg',
        target_path => 'lib/Demo/Math.pm',
        source_code => $demo_src,
        instruction => 'Add Demo::Math arithmetic helpers',
    );
    $q->pump(1);
    my $st_msg = $q->job_status($jid_msg);

    is($st_msg->{status}, 'staged', 'Bonsai commit_msg job transitions to staged');
    is($st_msg->{syntax_ok}, 1, 'commit_msg non-code syntax gate succeeds');
    like($st_msg->{output_text}, qr/\S{10,}/, 'Bonsai commit_msg produced non-empty commit message');
    ok(($st_msg->{cloud_tokens_saved} // 0) > 0, "commit_msg cloud_tokens_saved=$st_msg->{cloud_tokens_saved}");

    my $qsum = $q->summary();
    ok($qsum->{cloud_tokens_saved} > 0, "OffloadQueue total cloud_tokens_saved=$qsum->{cloud_tokens_saved}");

    note(sprintf(
        'METRICS[worker_small/Ternary-Bonsai-2-27B]: load_ms=%d doc=%.2f tok/s (%dms) comments=%.2f tok/s (%dms) commit_msg=%.2f tok/s (%dms) saved=%d',
        $wslot->{load_ms} // 0,
        $st_doc->{tok_per_s} // 0, $st_doc->{elapsed_ms} // 0,
        $st_cmt->{tok_per_s} // 0, $st_cmt->{elapsed_ms} // 0,
        $st_msg->{tok_per_s} // 0, $st_msg->{elapsed_ms} // 0,
        $qsum->{cloud_tokens_saved},
    ));

    my $wpid = $wslot->{pid};
    $mgr->shutdown_all();
    ok(!kill(0, $wpid), 'prism-llama-server exited cleanly on shutdown_all');
};

# ---------------------------------------------------------------------------
# Subtest 4: Live memory_writer (Hy-Memory-30B-A3B + inproc nomic-embed)
# ---------------------------------------------------------------------------
subtest '4. Live memory_writer (Hy-Memory-30B-A3B ADD / NOOP / SUPERSEDE lifecycle)' => sub {
    plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
    plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
    plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
    plan skip_all => 'DBI + DBD::SQLite not installed' unless $HAS_SQLITE;
    plan skip_all => 'memory_writer or embedder GGUF/runtime not installed'
        unless $ROLE_READY{memory_writer} && $ROLE_READY{embedder};

    my $cfg = NeoPerl::Inference::Config->new(auto_discover => 1);
    is($cfg->role_config('memory_writer')->{transport}, 'managed_server',
        'auto_discover promotes memory_writer to managed_server');

    my $mcmd = $cfg->build_server_command('memory_writer', 18098);
    my $mcmd_str = join(' ', @$mcmd);
    like($mcmd_str, qr/--flash-attn\s+on/, 'memory_writer command sets --flash-attn on');
    like($mcmd_str, qr/-ctk\s+q8_0.*-ctv\s+q8_0/, 'memory_writer command sets -ctk q8_0 -ctv q8_0');
    like($mcmd_str, qr/--jinja.*--chat-template-kwargs.*no_think/, 'memory_writer command sets --jinja + no_think');

    my $mgr = _track_mgr(NeoPerl::Inference::Manager->new(config => $cfg));
    my $store = NeoPerl::Memory::Store->new(
        sqlite_path => ':memory:',
        embedder    => $mgr,
    );
    my $writer = NeoPerl::Memory::Writer->new(
        store     => $store,
        inference => $mgr,
        repo_key  => 'neoperl-live',
    );

    # Event 1: Novel architectural decision -> ADD
    my $r1 = $writer->reconcile_event({
        event_type  => 'AgyTurnComplete',
        repo_key    => 'neoperl-live',
        category    => 'architecture',
        scope_level => 'repo',
        text        => 'NeoPerl uses HTTP::Tiny for all outbound inference calls',
    });
    my $mslot = (grep { $_->{role} eq 'memory_writer' } @{ $mgr->slot_status })[0];
    is($r1->{transport}, 'managed_server', 'Event 1 reconciled via live managed_server Hy-Memory');
    is($r1->{action}, 'ADD', 'Event 1 (novel architecture decision) -> ADD');
    my $id1 = $r1->{operations}[0]{id};
    ok($id1 && $id1 > 0, "Event 1 persisted memory id=$id1");
    ok(($r1->{tok_per_s} // 0) > 0, "Event 1 tok_per_s=$r1->{tok_per_s}");
    ok(($r1->{elapsed_ms} // 99999) < 20000, "Event 1 no_think latency within budget ($r1->{elapsed_ms} ms)");

    # Event 2: Exact duplicate restatement -> NOOP
    my $r2 = $writer->reconcile_event({
        event_type  => 'AgyTurnComplete',
        repo_key    => 'neoperl-live',
        category    => 'architecture',
        scope_level => 'repo',
        text        => 'NeoPerl uses HTTP::Tiny for all outbound inference calls',
    });
    is($r2->{transport}, 'managed_server', 'Event 2 reconciled via live managed_server Hy-Memory');
    is($r2->{action}, 'NOOP', 'Event 2 (duplicate restatement) -> NOOP');
    is($store->stats()->{active_memories}, 1, 'NOOP did not create duplicate active memory');

    # Event 3: Explicit replacement -> SUPERSEDE or UPDATE
    my $r3 = $writer->reconcile_event({
        event_type  => 'AgyTurnComplete',
        repo_key    => 'neoperl-live',
        category    => 'architecture',
        scope_level => 'repo',
        text        => 'We replaced HTTP::Tiny with Mojo::UserAgent from mojolicious-mt for all outbound inference calls',
    });
    is($r3->{transport}, 'managed_server', 'Event 3 reconciled via live managed_server Hy-Memory');
    like($r3->{action}, qr/^(?:SUPERSEDE|UPDATE)$/, "Event 3 (explicit replacement) -> $r3->{action}");

    if ($r3->{action} eq 'SUPERSEDE') {
        my $new_id = $r3->{operations}[0]{id};
        my $old_row = $store->get_memory($id1);
        is($old_row->{superseded_by_id}, $new_id, 'old memory records SUPERSEDED_BY_ID pointing to replacement');
        ok(defined $old_row->{valid_until}, 'old memory marked with VALID_UNTIL timestamp');
        is($store->stats()->{superseded_memories}, 1, 'store tracks 1 superseded memory');
    }
    else {
        my $upd_row = $store->get_memory($id1);
        like($upd_row->{content}, qr/Mojo::UserAgent/i, 'updated row records Mojo::UserAgent');
    }

    my $active = $store->search(
        query    => 'Mojo::UserAgent outbound inference calls',
        repo_key => 'neoperl-live',
        limit    => 5,
    );
    ok(@$active >= 1 && $active->[0]{content} =~ /Mojo::UserAgent/i,
        'active search recalls updated Mojo::UserAgent decision');

    my $events = $store->list_events(repo => 'neoperl-live', limit => 10);
    is(scalar(@$events), 3, 'NPL_MEMORY_EVENTS event log recorded all 3 live transitions');
    my %ev_actions = map { $_->{action_taken} => 1 } @$events;
    ok($ev_actions{ADD} && $ev_actions{NOOP} && ($ev_actions{SUPERSEDE} || $ev_actions{UPDATE}),
        'event log captures ADD, NOOP, and SUPERSEDE/UPDATE');

    note(sprintf(
        'METRICS[memory_writer/Hy-Memory-30B-A3B]: load_ms=%d add=%.2f tok/s (%dms) noop=%.2f tok/s (%dms) replace(%s)=%.2f tok/s (%dms)',
        $mslot->{load_ms} // 0,
        $r1->{tok_per_s} // 0, $r1->{elapsed_ms} // 0,
        $r2->{tok_per_s} // 0, $r2->{elapsed_ms} // 0,
        $r3->{action}, $r3->{tok_per_s} // 0, $r3->{elapsed_ms} // 0,
    ));

    my $mpid = $mslot->{pid};
    $mgr->shutdown_all();
    ok(!kill(0, $mpid), 'Hy-Memory managed server exited cleanly on shutdown_all');
};

# ---------------------------------------------------------------------------
# Subtest 5: Live LRU RAM Budget Eviction (real OS PID kill),
#            Auto-Discovery, Remote HTTP, & npl --info
# ---------------------------------------------------------------------------
subtest '5. Live LRU PID eviction, remote_http, auto_discover, and npl --info' => sub {
    # 5A: Verify mock override and npl --inference-mock --info (also runs in CI)
    {
        local $ENV{NEOPERL_INFERENCE_MOCK} = 1;
        my $mcfg = NeoPerl::Inference::Config->new(auto_discover => 1);
        for my $r ($mcfg->role_names) {
            is($mcfg->role_config($r)->{transport}, 'loopback',
                "NEOPERL_INFERENCE_MOCK=1 forces $r to loopback even with auto_discover=1");
        }
    }

    my $npl_bin  = File::Spec->catfile($ROOT, 'bin', 'npl');
    my @inc_args = map { "-I$_" } grep { defined $_ && !ref($_) && length $_ } @INC;
    {
        local $ENV{NEOPERL_INFERENCE_MOCK} = 1;
        open my $pipe, '-|', $^X, @inc_args, $npl_bin, '--no-agy', '--inference-mock', '--info'
            or die "Cannot run $npl_bin --info: $!";
        local $/;
        my $out = <$pipe> // '';
        close $pipe;
        is($?, 0, 'npl --no-agy --inference-mock --info exits 0');
        like($out, qr/Inference:/, 'npl --info prints Inference telemetry section');
        like($out, qr/embedder\s+loopback/, 'npl --inference-mock --info shows loopback roles');
    }

    subtest '5B. Live 4-role auto-discovery, LRU PID eviction, and remote_http' => sub {
        plan skip_all => 'NEOPERL_INFERENCE_MOCK=1 set' if $MOCK_FORCED;
        plan skip_all => "Local AI skipped on this host: $LOCAL_AI_SKIP" if length $LOCAL_AI_SKIP;
        plan skip_all => 'Local AI skipped on POWER/AIX host' if $IS_POWER;
        plan skip_all => 'All 4 live specialist GGUF models + binaries required for live LRU eviction test'
            unless $DOCTOR->{all_ready};

        # Auto-discovery promotes all 4 roles cleanly
        my $acfg = NeoPerl::Inference::Config->new(auto_discover => 1);
        my ($valid, $verrs) = $acfg->validate();
        ok($valid, 'auto-discovered 4-role live config validates cleanly') or diag(join('; ', @$verrs));
        is($acfg->role_config('embedder')->{transport},      ($HAS_LIBLLAMA ? 'inproc_libllama' : 'managed_server'), 'auto_discover embedder');
        is($acfg->role_config('vision_doc')->{transport},    'managed_server', 'auto_discover vision_doc');
        is($acfg->role_config('worker_small')->{transport},  'managed_server', 'auto_discover worker_small');
        is($acfg->role_config('memory_writer')->{transport}, 'managed_server', 'auto_discover memory_writer');

        # Live npl --no-agy --info reports all 4 auto-discovered roles
        {
            open my $pipe, '-|', $^X, @inc_args, $npl_bin, '--no-agy', '--info'
                or die "Cannot run $npl_bin --no-agy --info: $!";
            local $/;
            my $out = <$pipe> // '';
            close $pipe;
            is($?, 0, 'npl --no-agy --info exits 0 with live auto-discovery');
            like($out, qr/libllama=available/, 'npl --info reports libllama=available');
            like($out, qr/embedder\s+inproc_libllama/, 'npl --info reports embedder inproc_libllama');
            like($out, qr/memory_writer\s+managed_server/, 'npl --info reports memory_writer managed_server');
            like($out, qr/vision_doc\s+managed_server/, 'npl --info reports vision_doc managed_server');
            like($out, qr/worker_small\s+managed_server\s+fork=prism-ml/, 'npl --info reports worker_small managed_server fork=prism-ml');
        }

        # Live LRU RAM budget eviction (14.0 GB budget) with OS PID termination
        my $lcfg = NeoPerl::Inference::Config->new(
            auto_discover => 1,
            ram_budget_gb => 14.0,
        );
        my $lmgr = _track_mgr(NeoPerl::Inference::Manager->new(config => $lcfg));

        # 1) Pinned inproc_libllama embedder (0.4 GB)
        my $evec = $lmgr->embed('LRU pinning check');
        is(scalar(@$evec), 768, 'pinned embedder loaded (0.4 GB)');
        is($lmgr->resident_gb, 0.4, 'resident_gb == 0.4 after embedder');

        # 2) Live vision_doc (3.5 GB) -> 3.9 GB
        $lmgr->ensure_loaded('vision_doc');
        my %st = map { $_->{role} => $_ } @{ $lmgr->slot_status };
        my $vis_pid = $st{vision_doc}{pid};
        ok(defined $vis_pid && $vis_pid > 0 && kill(0, $vis_pid),
            "vision_doc live OS process running (pid=$vis_pid)");
        is($lmgr->resident_gb, 3.9, 'resident_gb == 3.9 after embedder + vision_doc');

        # 3) Live worker_small (6.0 GB) -> 9.9 GB <= 14.0 GB
        $lmgr->ensure_loaded('worker_small');
        %st = map { $_->{role} => $_ } @{ $lmgr->slot_status };
        my $bon_pid = $st{worker_small}{pid};
        ok(defined $bon_pid && $bon_pid > 0 && kill(0, $bon_pid),
            "worker_small live OS process running (pid=$bon_pid)");
        is($lmgr->resident_gb, 9.9, 'resident_gb == 9.9 with embedder + vision_doc + worker_small');

        # 4) Call memory_writer (9.1 GB) -> exceeds 14.0 GB -> evicts vision_doc and worker_small
        #    and terminates their OS PIDs while keeping the pinned embedder resident
        my $mres = $lmgr->complete(
            role       => 'memory_writer',
            max_tokens => 32,
            prompt     => 'Return exact JSON: [{"op":"NOOP"}]',
        );
        ok(length($mres->{text} // '') > 0, 'memory_writer completed after LRU eviction');

        %st = map { $_->{role} => $_ } @{ $lmgr->slot_status };
        my $mem_pid = $st{memory_writer}{pid};
        my $mem_url = $st{memory_writer}{url};

        is($st{vision_doc}{loaded}, 0, 'vision_doc evicted by LRU RAM budget');
        is(kill(0, $vis_pid), 0, "evicted vision_doc OS PID ($vis_pid) is dead (kill 0 == 0)");
        is($st{worker_small}{loaded}, 0, 'worker_small evicted to fit 9.1 GB memory_writer inside 14.0 GB');
        is(kill(0, $bon_pid), 0, "evicted worker_small OS PID ($bon_pid) is dead (kill 0 == 0)");
        is($st{embedder}{loaded}, 1, 'pinned inproc_libllama embedder remained resident through eviction');
        is($lmgr->resident_gb, 9.5, 'resident_gb == 9.5 (0.4 pinned embedder + 9.1 memory_writer)');
        ok(defined $mem_pid && kill(0, $mem_pid), "memory_writer live OS process running (pid=$mem_pid)");

        # 5) Verify remote_http pointing at the live 127.0.0.1:$port server uses 0 local RAM & is never evicted
        my $rcfg = NeoPerl::Inference::Config->new(
            ram_budget_gb => 1.0,
            roles => {
                memory_writer => {
                    transport  => 'remote_http',
                    remote_url => $mem_url,
                },
                embedder => {
                    transport        => 'loopback',
                    estimated_ram_gb => 0.9,
                },
            },
        );
        my $rmgr = _track_mgr(NeoPerl::Inference::Manager->new(config => $rcfg));
        my $rres = $rmgr->complete(
            role       => 'memory_writer',
            max_tokens => 16,
            prompt     => 'Reply with OK',
        );
        is($rres->{transport}, 'remote_http', 'remote_http call succeeded against live local llama-server');
        ok(length($rres->{text} // '') > 0, "remote_http returned live response ($rres->{text})");
        is($rmgr->resident_gb, 0.0, 'remote_http consumes 0.0 GB local RAM');

        $rmgr->embed('pressure local budget');
        is(scalar(@{ $rmgr->eviction_log }), 0, 'remote_http endpoint is never evicted under budget pressure');
        $rmgr->shutdown_all();
        ok(kill(0, $mem_pid), 'remote_http shutdown_all does not kill external server process');

        # 6) shutdown_all on owning manager terminates final live server cleanly
        $lmgr->shutdown_all();
        is(kill(0, $mem_pid), 0, "owning manager shutdown_all terminated memory_writer PID ($mem_pid)");

        note(sprintf(
            'METRICS[lru_eviction]: evicted vis_pid=%d (dead), bon_pid=%d (dead), kept pinned embedder, remote_http=%s (0.0GB), mem_pid=%d (clean shutdown)',
            $vis_pid, $bon_pid, $mem_url, $mem_pid,
        ));
    };
};

done_testing();
