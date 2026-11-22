use strict;
use warnings;
use Test::More;

use NeoPerl::Core qw(:tokens detect_language token_name);

# 1. Myers O(ND) line diff
{
    my $h_same = NeoPerl::Core::Diff::myers_lines(['a', 'b', 'c'], ['a', 'b', 'c']);
    is_deeply($h_same, [], 'identical lines produce 0 hunks');

    my $h_add = NeoPerl::Core::Diff::myers_lines(['a', 'c'], ['a', 'b1', 'b2', 'c']);
    is(scalar(@$h_add), 1, 'pure add produces 1 hunk');
    is($h_add->[0]{kind}, 'add', 'hunk kind is add');
    is($h_add->[0]{old_start}, 1, 'add old_start');
    is($h_add->[0]{old_count}, 0, 'add old_count');
    is($h_add->[0]{new_start}, 1, 'add new_start');
    is($h_add->[0]{new_count}, 2, 'add new_count');

    my $h_del = NeoPerl::Core::Diff::myers_lines(['a', 'x', 'y', 'c'], ['a', 'c']);
    is(scalar(@$h_del), 1, 'pure del produces 1 hunk');
    is($h_del->[0]{kind}, 'del', 'hunk kind is del');
    is($h_del->[0]{old_start}, 1, 'del old_start');
    is($h_del->[0]{old_count}, 2, 'del old_count');
    is($h_del->[0]{new_count}, 0, 'del new_count');

    my $h_chg = NeoPerl::Core::Diff::myers_lines(['a', 'old', 'c'], ['a', 'new1', 'new2', 'c']);
    is(scalar(@$h_chg), 1, 'change produces 1 hunk');
    is($h_chg->[0]{kind}, 'change', 'hunk kind is change');
    is($h_chg->[0]{old_count}, 1, 'change old_count');
    is($h_chg->[0]{new_count}, 2, 'change new_count');

    # Multi-hunk text diff + patch reconstruction verification
    my @old = ('l0', 'l1', 'l2', 'l3', 'l4', 'l5', 'l6');
    my @new = ('l0', 'L1_MOD', 'l2', 'l3', 'INS_A', 'l4', 'l6');
    my $hunks = NeoPerl::Core::Diff::myers_text(join("\n", @old) . "\n", join("\n", @new) . "\n");
    is(scalar(@$hunks), 3, 'multi-hunk diff returns 3 hunks');
    is($hunks->[0]{kind}, 'change', 'hunk 0 is change');
    is($hunks->[1]{kind}, 'add',    'hunk 1 is add');
    is($hunks->[2]{kind}, 'del',    'hunk 2 is del');

    # Reconstruct @new by applying hunks to @old
    my @rebuilt;
    my $oi = 0;
    for my $h (@$hunks) {
        while ($oi < $h->{old_start}) {
            push @rebuilt, $old[$oi++];
        }
        for my $k (0 .. $h->{new_count} - 1) {
            push @rebuilt, $new[$h->{new_start} + $k];
        }
        $oi += $h->{old_count};
    }
    while ($oi < @old) { push @rebuilt, $old[$oi++]; }
    is_deeply(\@rebuilt, \@new, 'applying Myers hunks reconstructs new file identically');
}

# 2. Language detection for all 17 languages
my %ext_map = (
    'app.pl'       => 'perl',
    'Mod.pm'       => 'perl',
    'Makefile.PL'  => 'perl',
    'core.c'       => 'c',
    'core.h'       => 'c',
    'engine.cpp'   => 'cpp',
    'Core.xs'      => 'xs',
    'main.rs'      => 'rust',
    'server.go'    => 'go',
    'script.py'    => 'python',
    'index.js'     => 'js',
    'app.ts'       => 'ts',
    'init.lua'     => 'lua',
    'config.json'  => 'json',
    'ci.yml'       => 'yaml',
    'build.sh'     => 'sh',
    'README.md'    => 'markdown',
    'patch.diff'   => 'diff',
    'gui.tcl'      => 'tcl',
    'Makefile'     => 'make',
    'notes.txt'    => 'text',
);
for my $fn (sort keys %ext_map) {
    is(detect_language($fn), $ext_map{$fn}, "detect_language($fn) => $ext_map{$fn}");
}
is(token_name(TOK_KEYWORD), 'keyword', 'token_name(TOK_KEYWORD)');
is(token_name(TOK_TAG), 'tag', 'token_name(TOK_TAG)');

# 3. Incremental line-state lexer across multiple languages & multiline states
{
    # Perl with POD multiline state
    my $perl_src = "package Demo;\nmy \$x = 42;\n=head1 DOC\nStill POD\n=cut\nsub run { return \$x; }\n";
    my $pbuf = NeoPerl::Core::Buffer->from_string($perl_src);
    my $psyn = NeoPerl::Core::Syntax->new('perl');
    is($psyn->language(), 'perl', 'syntax language getter');

    my $toks = $psyn->tokenize_range($pbuf, 0, 6);
    is(scalar(@$toks), 6, 'tokenized 6 Perl lines');
    # Line 3 ("Still POD") must be all comment due to multiline POD state
    is($toks->[3][2], TOK_COMMENT, 'Perl POD body line lexed as comment');
    is($psyn->end_state(2), 2, 'POD open sets state=2');
    is($psyn->end_state(4), 0, '=cut returns state=0');

    # Check incremental state convergence after editing line 5
    $pbuf->insert($pbuf->line_col_to_offset(5, 0), ' ');
    $psyn->invalidate(5, 0);
    $psyn->tokenize_range($pbuf, 0, 6);
    cmp_ok($psyn->last_relex_lines(), '<=', 2, 'incremental relex touched <= 2 lines');

    # Symbol outline extraction for Perl
    my $psyms = $psyn->extract_symbols($pbuf);
    is(scalar(@$psyms), 2, 'Perl symbol outline finds package + sub');
    is($psyms->[0]{name}, 'Demo', 'package symbol name');
    is($psyms->[0]{kind}, 'package', 'package symbol kind');
    is($psyms->[1]{name}, 'run', 'sub symbol name');
    is($psyms->[1]{kind}, 'sub', 'sub symbol kind');
}

{
    # C multiline block comment & XS section tags
    my ($t0, $st0) = NeoPerl::Core::Syntax::tokenize_line('c', 'int x = /* start', 0);
    is($st0, 1, 'C /* opens block comment state');
    my ($t1, $st1) = NeoPerl::Core::Syntax::tokenize_line('c', 'middle of comment', $st0);
    is($st1, 1, 'C block comment continues');
    is($t1->[2], TOK_COMMENT, 'middle line colored as comment');
    my ($t2, $st2) = NeoPerl::Core::Syntax::tokenize_line('c', 'end */ return x;', $st1);
    is($st2, 0, 'C */ closes block comment');

    my ($txs, $sxs) = NeoPerl::Core::Syntax::tokenize_line('xs', 'MODULE = Foo PACKAGE = Foo', 0);
    is($txs->[2], TOK_TAG, 'XS MODULE lexed as TOK_TAG');

    # Exercise all remaining languages with tokenize_line & symbol extraction
    my %samples = (
        cpp      => "class Engine {\n};\nvoid tick(int dt) {}\n",
        rust     => "pub struct Node { val: usize }\npub fn parse(s: &str) -> bool { true }\n",
        go       => "type Worker struct{}\nfunc (w *Worker) Run() int { return 1 }\n",
        python   => "class Runner:\n    \"\"\"doc\n    \"\"\"\n    def execute(self):\n        return 1\n",
        js       => "export function render(x) { return `v=\${x}`; }\n",
        ts       => "export interface Config { port: number; }\n",
        lua      => "--[[\nblock\n]]\nlocal function init() return true end\n",
        json     => "{\"host\": \"localhost\", \"ok\": true, \"port\": 8080}\n",
        yaml     => "name: build\nenabled: true\n",
        sh       => "function build_all() {\n  echo \"\$HOME\"\n}\n",
        markdown => "# Heading One\n```c\nint x;\n```\n",
        diff     => "@@ -1,2 +1,2 @@\n-old\n+new\n",
        tcl      => "proc hello {name} { puts \$name }\n",
        make     => "all: build\n\t\$(CC) -O3 main.c\n",
    );
    for my $lang (sort keys %samples) {
        my $b = NeoPerl::Core::Buffer->from_string($samples{$lang});
        my $s = NeoPerl::Core::Syntax->new($lang);
        my $toks = $s->tokenize_range($b, 0, $b->line_count());
        ok(ref($toks) eq 'ARRAY' && @$toks > 0, "tokenized $lang cleanly");
        my $total_toks = 0;
        for my $row (@$toks) { $total_toks += scalar(@$row) / 3; }
        cmp_ok($total_toks, '>=', 1, "$lang emitted tokens ($total_toks)");
    }

    my $rs_syms = NeoPerl::Core::Syntax::extract_symbols_text('rust', $samples{rust});
    is_deeply([map { $_->{name} } @$rs_syms], ['Node', 'parse'], 'Rust symbols extracted');
    my $py_syms = NeoPerl::Core::Syntax::extract_symbols_text('python', $samples{python});
    is_deeply([map { $_->{name} } @$py_syms], ['Runner', 'execute'], 'Python symbols extracted');
    my $go_syms = NeoPerl::Core::Syntax::extract_symbols_text('go', $samples{go});
    is_deeply([map { $_->{name} } @$go_syms], ['Worker', 'Run'], 'Go symbols extracted');
    my $tcl_syms = NeoPerl::Core::Syntax::extract_symbols_text('tcl', $samples{tcl});
    is_deeply([map { $_->{name} } @$tcl_syms], ['hello'], 'Tcl proc symbol extracted');
}

# 4. Runtime dlopen(libtree-sitter) bridge probe & graceful fallback
{
    my $avail = NeoPerl::Core::TreeSitter::available();
    ok($avail == 0 || $avail == 1, "TreeSitter::available returns boolean ($avail)");
    my $lp = NeoPerl::Core::TreeSitter::library_path();
    if ($avail) {
        ok(length($lp) > 0, "TreeSitter loaded dynamically from: $lp");
    } else {
        is($lp, '', 'TreeSitter library_path empty when unavailable');
    }
    is(NeoPerl::Core::TreeSitter::has_grammar('nonexistent_lang_xyz'), 0,
       'unloaded grammar reports has_grammar=0');
    ok(!defined NeoPerl::Core::TreeSitter::parse_nodes('nonexistent_lang_xyz', 'int x;'),
       'parse_nodes returns undef gracefully when grammar not loaded');
    ok(!defined NeoPerl::Core::TreeSitter::node_at('nonexistent_lang_xyz', 'int x;', 0),
       'node_at returns undef gracefully when grammar not loaded');
}

done_testing();
