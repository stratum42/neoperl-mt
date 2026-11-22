use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use NeoPerl::Core qw(:term);

# 1. Multi-threaded C11 parallel file walker + .gitignore + PERL_FORCE_SCALAR=1 parity
my $root = tempdir(CLEANUP => 1);
make_path("$root/src/sub", "$root/.git/objects", "$root/blib/lib", "$root/node_modules/pkg", "$root/ignored_dir");

sub _write {
    my ($p, $c) = @_;
    open my $fh, '>:raw', $p or die "open $p: $!";
    print {$fh} $c;
    close $fh;
}

_write("$root/.gitignore", "# comments ignored\n*.log\nignored_dir/\n");
_write("$root/README.md", "Hello NeoPerl workspace\n");
_write("$root/src/alpha.c", "int alpha_needle(void) {\n    return 42; /* NEEDLE here */\n}\n");
_write("$root/src/sub/beta.pl", "sub beta_needle {\n    return 'needle_hit';\n}\n");
_write("$root/src/bin.dat", "needle\x00binary_payload_should_skip\n");
_write("$root/debug.log", "needle in ignored log\n");
_write("$root/ignored_dir/secret.txt", "needle in ignored dir\n");
_write("$root/.git/objects/obj", "needle in .git\n");
_write("$root/blib/lib/Mod.pm", "needle in blib\n");
_write("$root/node_modules/pkg/index.js", "needle in node_modules\n");

my ($files_mt, $files_scalar);
{
    local $ENV{PERL_FORCE_SCALAR} = '0';
    $files_mt = NeoPerl::Core::Fuzzy::walk_files($root, 0);
}
{
    local $ENV{PERL_FORCE_SCALAR} = '1';
    $files_scalar = NeoPerl::Core::Fuzzy::walk_files($root, 0);
}
is_deeply($files_mt, $files_scalar, 'walk_files bit-identical under PERL_FORCE_SCALAR=1');
ok((grep { $_ eq 'src/alpha.c' } @$files_mt), 'walk_files includes src/alpha.c');
ok((grep { $_ eq 'src/sub/beta.pl' } @$files_mt), 'walk_files includes src/sub/beta.pl');
ok(!(grep { m{debug\.log|ignored_dir|(?:^|/)\.git(?:/|$)|(?:^|/)blib(?:/|$)|node_modules} } @$files_mt),
   'walk_files respects .gitignore, .git, blib, node_modules');

# 2. Smith-Waterman fuzzy scorer & filter
my $sc = NeoPerl::Core::Fuzzy::score('nplbuf', 'lib/NeoPerl/Buffer.pm');
ok(ref($sc) eq 'HASH' && $sc->{score} > 0, 'Smith-Waterman matches subsequence');
is(scalar(@{$sc->{positions}}), 6, 'returns exact 6 matched character positions');
# Verify every returned position matches the corresponding query character case-insensitively
my $cand_str = 'lib/NeoPerl/Buffer.pm';
my @qchars = split //, 'nplbuf';
my $pos_ok = 1;
for my $i (0 .. $#qchars) {
    my $p = $sc->{positions}[$i];
    if (lc(substr($cand_str, $p, 1)) ne lc($qchars[$i])) {
        $pos_ok = 0;
        last;
    }
}
ok($pos_ok, 'all Smith-Waterman positions align to query characters');
ok(!defined NeoPerl::Core::Fuzzy::score('zzzzz', 'lib/NeoPerl/Buffer.pm'),
   'non-matching query returns undef');

my $filtered = NeoPerl::Core::Fuzzy::filter('buf', [
    'a/b/c/something_b_u_f.txt',
    'c/buffer.c',
    'lib/NeoPerl/Editor.pm',
    'c/buffer.h',
], 10);
is(scalar(@$filtered), 3, 'fuzzy filter keeps 3 matching candidates');
like($filtered->[0]{text}, qr{^c/buffer\.}, 'word-boundary match c/buffer.* ranks above scattered match');

# 3. Multi-threaded parallel grep + PERL_FORCE_SCALAR=1 bit-identical parity
my ($grep_mt, $grep_scalar);
{
    local $ENV{PERL_FORCE_SCALAR} = '0';
    $grep_mt = NeoPerl::Core::Fuzzy::grep_dir($root, 'needle', 1, 100);
}
{
    local $ENV{PERL_FORCE_SCALAR} = '1';
    $grep_scalar = NeoPerl::Core::Fuzzy::grep_dir($root, 'needle', 1, 100);
}
is_deeply($grep_mt, $grep_scalar, 'grep_dir bit-identical under PERL_FORCE_SCALAR=1');
is(scalar(@$grep_mt), 4, 'grep_dir finds 4 case-insensitive hits (skipping binary & ignored)');
is($grep_mt->[0]{path}, 'src/alpha.c', 'deterministic file order in grep_dir');

# Case-sensitive grep_dir
my $grep_cs = NeoPerl::Core::Fuzzy::grep_dir($root, 'NEEDLE', 0, 100);
is(scalar(@$grep_cs), 1, 'case-sensitive grep_dir finds exact 1 uppercase hit');
is($grep_cs->[0]{line}, 1, 'hit on 0-based line 1');

# grep_buffer
my $gbuf = NeoPerl::Core::Buffer->from_string("first line\nsecond foo bar\nthird FOO\n");
my $gb_hits = NeoPerl::Core::Fuzzy::grep_buffer($gbuf, 'foo', 1, 50);
is(scalar(@$gb_hits), 2, 'grep_buffer finds 2 icase hits');
is($gb_hits->[0]{line}, 1, 'first buffer hit on line 1');
is($gb_hits->[0]{col}, 7, 'first buffer hit at col 7');

# 4. VecSIMD (NEON / SSE2 / AVX2 / POWER8+ VSX) + bit-identical PERL_FORCE_SCALAR=1 parity
{
    my $dim = 768;
    my @q = map { sin($_ * 0.13 + 0.5) } (0 .. $dim - 1);
    my $q_blob = NeoPerl::Core::VecSIMD::pack_f32(\@q);
    is(length($q_blob), $dim * 4, 'pack_f32 emits 768 * 4 = 3072 byte LE blob');

    my $unpacked = NeoPerl::Core::VecSIMD::unpack_f32($q_blob);
    is(scalar(@$unpacked), $dim, 'unpack_f32 restores 768 floats');
    ok(abs($unpacked->[17] - $q[17]) < 1e-6, 'pack/unpack float32 value accuracy');

    my @cands;
    my @pairs;
    for my $c (0 .. 31) {
        my @v = map { sin(($_ + $c * 3) * 0.13 + 0.5) } (0 .. $dim - 1);
        my $b = NeoPerl::Core::VecSIMD::pack_f32(\@v);
        push @cands, $b;
        push @pairs, ["doc_$c", $b];
    }

    my ($backend_simd, $dot_s, $norm_s, $cos_s, $normed_s, $topk_s, $topk_pair_s);
    {
        local $ENV{PERL_FORCE_SCALAR} = '0';
        $backend_simd = NeoPerl::Core::VecSIMD::simd_backend();
        $dot_s        = NeoPerl::Core::VecSIMD::dot_f32($q_blob, $cands[5]);
        $norm_s       = NeoPerl::Core::VecSIMD::l2_norm_f32($q_blob);
        $cos_s        = NeoPerl::Core::VecSIMD::cosine_f32($q_blob, $cands[5]);
        $normed_s     = NeoPerl::Core::VecSIMD::normalize_f32($q_blob);
        $topk_s       = NeoPerl::Core::VecSIMD::topk_cosine($q_blob, \@cands, 5);
        $topk_pair_s  = NeoPerl::Core::VecSIMD::topk_cosine($q_blob, \@pairs, 5);
    }

    my ($backend_sc, $dot_c, $norm_c, $cos_c, $normed_c, $topk_c);
    {
        local $ENV{PERL_FORCE_SCALAR} = '1';
        $backend_sc = NeoPerl::Core::VecSIMD::simd_backend();
        $dot_c      = NeoPerl::Core::VecSIMD::dot_f32($q_blob, $cands[5]);
        $norm_c     = NeoPerl::Core::VecSIMD::l2_norm_f32($q_blob);
        $cos_c      = NeoPerl::Core::VecSIMD::cosine_f32($q_blob, $cands[5]);
        $normed_c   = NeoPerl::Core::VecSIMD::normalize_f32($q_blob);
        $topk_c     = NeoPerl::Core::VecSIMD::topk_cosine($q_blob, \@cands, 5);
    }

    ok(length($backend_simd) > 0, "SIMD backend active: $backend_simd");
    is($backend_sc, 'scalar', 'PERL_FORCE_SCALAR=1 forces scalar backend');

    # Exact bit-for-bit IEEE-754 double equality
    is(unpack('H*', pack('d', $dot_s)),  unpack('H*', pack('d', $dot_c)),
       'dot_f32 bit-identical SIMD vs PERL_FORCE_SCALAR=1');
    is(unpack('H*', pack('d', $norm_s)), unpack('H*', pack('d', $norm_c)),
       'l2_norm_f32 bit-identical SIMD vs PERL_FORCE_SCALAR=1');
    is(unpack('H*', pack('d', $cos_s)),  unpack('H*', pack('d', $cos_c)),
       'cosine_f32 bit-identical SIMD vs PERL_FORCE_SCALAR=1');
    is($normed_s, $normed_c, 'normalize_f32 bit-identical SIMD vs PERL_FORCE_SCALAR=1');
    is(scalar(@$topk_s), 5, 'topk_cosine returns top 5');
    is($topk_s->[0]{index}, 0, 'identical query vector cands[0] ranks #1');
    ok(abs($topk_s->[0]{score} - 1.0) < 1e-6, 'self-cosine is ~1.0');
    is($topk_pair_s->[0]{id}, 'doc_0', 'topk_cosine preserves [id, blob] pair id');

    my $topk_bits_match = 1;
    for my $i (0 .. 4) {
        if ($topk_s->[$i]{index} != $topk_c->[$i]{index} ||
            unpack('H*', pack('d', $topk_s->[$i]{score})) ne unpack('H*', pack('d', $topk_c->[$i]{score}))) {
            $topk_bits_match = 0;
            last;
        }
    }
    ok($topk_bits_match, 'topk_cosine results bit-identical SIMD vs PERL_FORCE_SCALAR=1');

    my $unit_norm = NeoPerl::Core::VecSIMD::l2_norm_f32($normed_s);
    ok(abs($unit_norm - 1.0) < 1e-5, 'normalized vector has unit L2 norm');
}

# 5. LlamaBridge dlopen probe & graceful unavailable handling
{
    my $avail = NeoPerl::Core::LlamaBridge::available();
    ok($avail == 0 || $avail == 1, "LlamaBridge::available returns boolean ($avail)");
    my $st = NeoPerl::Core::LlamaBridge::status();
    ok(ref($st) eq 'HASH', 'LlamaBridge::status returns hashref');
    is($st->{model_loaded}, 0, 'no model loaded initially');
    my $lr = NeoPerl::Core::LlamaBridge::load_model('/nonexistent/model.gguf');
    is($lr->{ok}, 0, 'load_model fails gracefully without crashing');
    ok(length($lr->{error}) > 0, 'load_model populates error string');
    my $er = NeoPerl::Core::LlamaBridge::embed('hello');
    is($er->{ok}, 0, 'embed fails gracefully when no model loaded');
    my $cr = NeoPerl::Core::LlamaBridge::complete('hello');
    is($cr->{ok}, 0, 'complete fails gracefully when no model loaded');
    is(NeoPerl::Core::LlamaBridge::unload(), 1, 'unload succeeds cleanly');
}

# 6. POSIX PTY :terminal + VT100/256-color/24-bit RGB screen emulator
SKIP: {
    skip 'POSIX PTY tests skipped on Win32', 11 if $^O eq 'MSWin32';

    my $term = NeoPerl::Core::Term->spawn(24, 80, '/bin/sh', ['-c', 'echo "HELLO_PTY_42"; exit 0']);
    ok(defined $term, 'Term->spawn launched /bin/sh');
    cmp_ok($term->pid(), '>', 0, 'valid child pid');

    my $found = 0;
    for (1 .. 40) {
        $term->poll(25);
        my $scr = $term->get_screen();
        for my $line (@{$scr->{lines}}) {
            if ($line =~ /HELLO_PTY_42/) {
                $found = 1;
                last;
            }
        }
        last if $found && !$term->is_alive();
    }
    ok($found, 'PTY captured real /bin/sh stdout on VT100 screen');
    ok(!$term->is_alive(), 'child exited cleanly');
    is($term->exit_code(), 0, 'exit_code is 0');

    # Test VT100 24-bit RGB SGR, 256-color, cursor move, OSC title, resize
    $term->feed("\x1b[2J\x1b[1;1H\x1b]0;NeoPerlTerm\x07\x1b[1;38;2;255;128;64mRGB\x1b[0m \x1b[38;5;196mC256\x1b[0m");
    my $scr = $term->get_screen();
    is($scr->{title}, 'NeoPerlTerm', 'OSC window title parsed');
    is($scr->{lines}[0], 'RGB C256', 'ANSI SGR stripped cleanly from plain text row');
    my $r0 = $scr->{runs}[0];
    is($r0->[0]{text}, 'RGB', 'first styled run text');
    is($r0->[0]{fg}, 0xFF8040, '24-bit RGB truecolor fg parsed (0xFF8040)');
    ok(($r0->[0]{flags} & TERM_FLAG_BOLD) != 0, 'bold flag set on styled run');
    ok($r0->[2]{fg} > 0, '256-color palette index mapped to RGB');

    ok($term->resize(30, 100), 'resize succeeds');
    my $scr2 = $term->get_screen();
    is($scr2->{rows}, 30, 'resized rows=30');
    is($scr2->{cols}, 100, 'resized cols=100');
}

done_testing();
