use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';
use NeoPerl::Plugin::PerlDev::Worker;
use NeoPerl::Plugin::PerlDev;

my $tmp = tempdir(CLEANUP => 1);

# 1. Worker capabilities & @INC auto-discovery
my $worker = NeoPerl::Plugin::PerlDev::Worker->new;
my $caps   = $worker->capabilities;
ok(ref($caps) eq 'HASH', 'capabilities returns hashref');
diag(sprintf('PerlDev capabilities: ppi=%s(%s) critic=%s(%s) tidy=%s(%s) worker=%s',
    $caps->{ppi_mode},    $caps->{ppi_version}    // '-',
    $caps->{critic_mode}, $caps->{critic_version} // '-',
    $caps->{tidy_mode},   $caps->{tidy_version}   // '-',
    $caps->{worker_mode}));

my $sample_perl = <<'PERL';
package Demo::Widget;

use strict;
use warnings;
use File::Spec;
use constant MAX_ITEMS => 42;

our $GLOBAL_TAG = 'v1';

=head1 NAME

Demo::Widget - Sample module for PPI testing

=head1 METHODS

=cut

sub helper_scale {
    my ($val, $factor) = @_;
    return $val * $factor;
}

sub compute_total {
    my ($items_ref, $scale) = @_;
    my $count = 0;
    for my $item (@$items_ref) {
        $count += helper_scale($item, $scale);
    }
    {
        my $count = 999;    # inner shadowed lexical must NOT be renamed
        $count++;
    }
    my $msg = 'literal $count stays untouched';
    return $count;
}

sub other_sub {
    my ($x) = @_;
    my $count = $x + 1;     # sibling sub lexical must NOT be renamed
    return $count;
}

1;
PERL

# 2. PPI AST Outline & zero double-parse cache verification
my $out = $worker->outline(101, 1, $sample_perl);
ok($out->{ok}, 'outline succeeded');
my %by_kind;
for my $it (@{ $out->{items} }) {
    push @{ $by_kind{ $it->{kind} } }, $it;
}

is($by_kind{package}[0]{name}, 'Demo::Widget', 'outline found package Demo::Widget');
my @sub_names = map { $_->{name} } @{ $by_kind{sub} || [] };
is_deeply(\@sub_names, [qw(helper_scale compute_total other_sub)], 'outline found all 3 subs in order');
ok((grep { $_->{name} eq 'File::Spec' } @{ $by_kind{import} || [] }), 'outline found use File::Spec');
ok((grep { $_->{name} eq 'MAX_ITEMS' }  @{ $by_kind{constant} || [] }), 'outline found constant MAX_ITEMS');
ok((grep { $_->{name} eq '$GLOBAL_TAG' } @{ $by_kind{global} || [] }), 'outline found our $GLOBAL_TAG');
ok((grep { $_->{name} eq 'NAME' } @{ $by_kind{pod} || [] }), 'outline found POD =head1 NAME');

my $stats_after_outline = $worker->stats;
my $parses_before_critic = $stats_after_outline->{parse_count};

# Critic on same (buf_id, rev) reuses cached PPI::Document without re-parsing
my $crit_clean = $worker->critic(101, 1, $sample_perl, severity => 4);
ok($crit_clean->{ok}, 'critic ran cleanly on sample module');
if ($caps->{ppi} && $caps->{critic}) {
    is($worker->stats->{parse_count}, $parses_before_critic,
        'ZERO double-parse: Perl::Critic reused cached PPI::Document for (buf_id=101, rev=1)');
    cmp_ok($worker->stats->{cache_hits}, '>=', 1, 'PPI document cache hit recorded');
    is($crit_clean->{backend}, 'inproc', 'Perl::Critic ran in-process');
}

# 3. PPI AI Context Slicer
my $slice = $worker->slice_context(101, 1, $sample_perl, 27);
ok($slice->{ok}, 'slice_context succeeded');
is($slice->{package},       'Demo::Widget',  'slice captured enclosing package');
is($slice->{enclosing_sub}, 'compute_total', 'slice captured enclosing sub compute_total');
like($slice->{text}, qr/use File::Spec;/,    'slice includes imports');
like($slice->{text}, qr/sub helper_scale/,   'slice includes referenced local sub signature');
unlike($slice->{text}, qr/sub other_sub/,    'slice omits unreferenced sibling sub');
ok((grep { $_->{name} eq 'helper_scale' } @{ $slice->{referenced_subs} || [] }),
    'referenced_subs lists helper_scale');

# 4. PPI Vim motions & text objects (if/af, ip/ap, ]]/[[)
my $af = $worker->text_object(101, 1, $sample_perl, 27, 5, 'af');
ok($af->{found}, 'af found enclosing sub');
is($af->{name}, 'compute_total', 'af identified compute_total');
my $if = $worker->text_object(101, 1, $sample_perl, 27, 5, 'if');
ok($if->{found}, 'if found inner sub body');
cmp_ok($if->{start_line}, '>', $af->{start_line}, 'if starts inside af header');
cmp_ok($if->{end_line},   '<', $af->{end_line},   'if ends before af closing brace');

my $ap = $worker->text_object(101, 1, $sample_perl, 12, 1, 'ap');
ok($ap->{found}, 'ap found POD block');
my $ip = $worker->text_object(101, 1, $sample_perl, 12, 1, 'ip');
ok($ip->{found}, 'ip found inner POD content');
cmp_ok($ip->{start_line}, '>=', $ap->{start_line}, 'ip inside ap');

my $nxt = $worker->next_sub(101, 1, $sample_perl, 18, 1);
is($nxt->{name}, 'compute_total', ']] jumps from helper_scale to compute_total');
my $prv = $worker->next_sub(101, 1, $sample_perl, 35, -1);
is($prv->{name}, 'compute_total', '[[ jumps back from other_sub to compute_total');

# 5. Workspace gd / gr
my $caller_perl = "package App::Main;\nuse Demo::Widget;\nsub run { return Demo::Widget::helper_scale(3, 4); }\n1;\n";
my $ws = {
    'lib/Demo/Widget.pm' => $sample_perl,
    'bin/app.pl'         => $caller_perl,
};
my $defs = $worker->find_definition($ws, 'Demo::Widget::helper_scale');
is(scalar(@$defs), 1, 'gd found exact definition across workspace');
is($defs->[0]{file}, 'lib/Demo/Widget.pm', 'gd points to lib/Demo/Widget.pm');
my $refs = $worker->find_references($ws, 'helper_scale');
cmp_ok(scalar(@$refs), '>=', 3, 'gr found definition and calls across files');

# 6. Scope-safe lexical rename (<leader>pr)
SKIP: {
    skip 'PPI required for scope-safe lexical rename', 8 unless $caps->{ppi};
    # Line 25: "    my $count = 0;" -> col 8 is '$count'
    my @slines = split /\n/, $sample_perl;
    my $target_line = 0;
    my $target_col  = 0;
    for my $idx (0 .. $#slines) {
        if ($slines[$idx] =~ /^(\s*my\s+)(\$count)\s*=\s*0;/) {
            $target_line = $idx + 1;
            $target_col  = length($1) + 1;
            last;
        }
    }
    ok($target_line > 0, "located target lexical at L$target_line:$target_col");
    my $ren = $worker->lexical_rename(101, 1, $sample_perl, $target_line, $target_col, 'total');
    ok($ren->{ok}, 'lexical_rename succeeded');
    is($ren->{old_name}, '$count', 'old_name is $count');
    is($ren->{new_name}, '$total', 'new_name is $total');
    is($ren->{count}, 3, 'renamed exactly 3 occurrences in compute_total outer scope');
    like($ren->{new_text}, qr/my \$total = 0;.*\$total \+=.*return \$total;/s,
        'outer scope occurrences renamed to $total');
    like($ren->{new_text}, qr/my \$count = 999;\s+# inner shadowed.*\n\s+\$count\+\+;/s,
        'inner shadowed my $count untouched');
    like($ren->{new_text}, qr/literal \$count stays untouched.*sub other_sub \{.*my \$count = \$x \+ 1;/s,
        'string literal and sibling sub $count untouched');
}

# 7. Extract-sub (<leader>pe) inspecting free lexicals
{
    my @slines = split /\n/, $sample_perl;
    my ($es, $ee) = (0, 0);
    for my $idx (0 .. $#slines) {
        $es = $idx + 1 if $slines[$idx] =~ /for my \$item/;
        $ee = $idx + 1 if $es && !$ee && $slines[$idx] =~ /^\s{4}\}\s*$/;
    }
    my $ext = $worker->extract_sub(101, 1, $sample_perl, $es, $ee, 'accumulate_items');
    ok($ext->{ok}, 'extract_sub succeeded');
    my %p = map { $_ => 1 } @{ $ext->{params} };
    ok($p{'$count'} && $p{'$items_ref'} && $p{'$scale'}, 'extract_sub detected all free lexicals ($count, $items_ref, $scale)');
    ok(!$p{'$item'}, 'extract_sub excluded loop-local $item from parameters');
    like($ext->{sub_code},  qr/sub accumulate_items \{\s*my \([^)]*\) = \@_;/s, 'generated sub unpacks @_');
    like($ext->{call_code}, qr/accumulate_items\(/, 'generated call site invokes accumulate_items');
}

# 8. .perlcriticrc discovery + live Perl::Critic + Tiered Auto-Fix
my $proj_dir = File::Spec->catdir($tmp, 'proj');
my $sub_dir  = File::Spec->catdir($proj_dir, 'lib', 'Demo');
mkdir $proj_dir;
mkdir File::Spec->catdir($proj_dir, 'lib');
mkdir $sub_dir;

my $rc_critic = File::Spec->catfile($proj_dir, '.perlcriticrc');
open my $cfh, '>', $rc_critic or die $!;
print {$cfh} "severity = 4\n";
close $cfh;

my $rc_tidy = File::Spec->catfile($proj_dir, '.perltidyrc');
open my $tfh, '>', $rc_tidy or die $!;
print {$tfh} "-l=80\n-i=4\n-pt=1\n";
close $tfh;

my $test_pm = File::Spec->catfile($sub_dir, 'Messy.pm');
my $messy_code = <<'PERL';
package Demo::Messy;
sub bad_mech {
    my ($x) = @_;
    return undef if !$x;
    return $x + 1;
}
sub ugly_fmt{my($a,$b)=@_;if($a){return $a+$b;}return 0;}
1;
PERL
open my $mfh, '>', $test_pm or die $!;
print {$mfh} $messy_code;
close $mfh;

is($worker->discover_rc('.perlcriticrc', $test_pm), $rc_critic, 'walked up directory tree to find .perlcriticrc');
is($worker->discover_rc('.perltidyrc',   $test_pm), $rc_tidy,   'walked up directory tree to find .perltidyrc');

my $crit_messy = $worker->critic(202, 1, $messy_code, file_path => $test_pm, severity => 4);
ok($crit_messy->{ok}, 'critic analyzed Messy.pm');
cmp_ok(scalar(@{ $crit_messy->{violations} }), '>=', 2, 'detected strict/warnings/return undef violations');
ok((grep { $_->{short_policy} eq 'Subroutines::ProhibitExplicitReturnUndef' && $_->{tier} eq 'bonsai' }
    @{ $crit_messy->{violations} }), 'classified ProhibitExplicitReturnUndef as mechanical/bonsai tier');

# Verify structural policy classification routes to gemini
my ($sp, $is_mech, $tier) = $worker->classify_policy('Perl::Critic::Policy::Subroutines::ProhibitExcessComplexity');
is($tier, 'gemini', 'classified ProhibitExcessComplexity as structural/gemini tier');

# 9. Perl::Tidy full buffer + visual range preserving base_indent
my $tidy_res = $worker->tidy($messy_code, file_path => $test_pm);
ok($tidy_res->{ok},      'Perl::Tidy succeeded');
ok($tidy_res->{changed}, 'Perl::Tidy reformatted ugly_fmt');
like($tidy_res->{text}, qr/sub ugly_fmt \{/, 'Perl::Tidy formatted sub header cleanly');
if ($caps->{tidy}) {
    is($tidy_res->{backend}, 'inproc', 'Perl::Tidy ran in-process');
}

my $indented_src = "sub outer {\n    if (1) {\n        my\$x=1+2;\n        return\$x;\n    }\n}\n";
my $range_res = $worker->tidy_range($indented_src, 3, 4, file_path => $test_pm);
ok($range_res->{ok}, 'tidy_range succeeded');
is($range_res->{base_indent}, '        ', 'tidy_range preserved 8-space base indentation');
like($range_res->{text}, qr/^        my \$x = 1 \+ 2;/m, 'tidied line retains base indent');

# 10. Full Plugin + Editor + OffloadQueue + MCP Tools 15-18 + Post-Tidy Gate + Tiered Auto-Fix
my $has_core = eval { require NeoPerl::Core; require NeoPerl::Editor; 1 };
SKIP: {
    skip 'NeoPerl::Core / NeoPerl::Editor not built yet', 27 unless $has_core;

    my $ed = NeoPerl::Editor->new(cwd => $proj_dir);
    my $mcp;
    if (eval { require NeoPerl::Antigravity::EditorMCP; 1 }) {
        $mcp = NeoPerl::Antigravity::EditorMCP->new(editor => $ed);
    }
    my $queue;
    if (eval { require NeoPerl::Inference::Config; require NeoPerl::Inference::Manager; require NeoPerl::Inference::OffloadQueue; 1 }) {
        my $icfg = NeoPerl::Inference::Config->new;
        my $imgr = NeoPerl::Inference::Manager->new(config => $icfg);
        $queue   = NeoPerl::Inference::OffloadQueue->new(inference => $imgr, editor => $ed);
    }

    my $pdev = NeoPerl::Plugin::PerlDev->new(
        editor        => $ed,
        mcp           => $mcp,
        offload_queue => $queue,
    );

    my $buf = $ed->open_file($test_pm);
    ok($buf, 'opened Messy.pm in Editor');

    # :PerlCritic populates diagnostics + quickfix
    my $c_cmd = $ed->exec_command(':PerlCritic');
    ok($c_cmd->{ok}, ':PerlCritic Ex command succeeded');
    my $ed_diags = $ed->get_diagnostics($buf, source => 'perlcritic');
    cmp_ok(scalar(@$ed_diags), '>=', 2, 'Perl::Critic populated Editor diagnostics & extmarks');
    cmp_ok(scalar(@{ $ed->get_quickfix }), '>=', 2, ':PerlCritic populated quickfix list');

    # :PerlCriticSeverity
    my $sev_cmd = $ed->exec_command(':PerlCriticSeverity 5');
    ok($sev_cmd->{ok}, ':PerlCriticSeverity 5 succeeded');
    is($pdev->critic_severity, 5, 'critic_severity updated to 5');
    $ed->exec_command(':PerlCriticSeverity 4');

    # :PerlCriticFix tiered mechanical fix (routes to Bonsai OffloadQueue + perl -c + Perl::Critic re-check + diff staged)
    my $fix_res = $ed->exec_command(':PerlCriticFix');
    ok($fix_res->{ok}, ':PerlCriticFix succeeded');
    is($fix_res->{syntax_ok}, 1, 'mechanical fix passed live perl -c syntax check');
    is($fix_res->{staged_diff}, 1, 'mechanical fix staged inline red/green diff hunks');
    cmp_ok($fix_res->{remaining_mechanical}, '<', $fix_res->{mechanical_count},
        're-check confirmed mechanical violations reduced');
    if ($queue) {
        like($fix_res->{bonsai_job_id} // '', qr/^bonsai-/, 'mechanical policy routed out-of-band to Ternary-Bonsai OffloadQueue');
    }
    else {
        pass('OffloadQueue optional');
    }
    $buf->reject_all_hunks if $buf->can('reject_all_hunks');

    # :PerlTidyDiff stages inline diff hunks
    my $td_res = $ed->exec_command(':PerlTidyDiff');
    ok($td_res->{ok} && $td_res->{staged}, ':PerlTidyDiff staged tidy diff hunks');
    $buf->reject_all_hunks if $buf->can('reject_all_hunks');

    # Automatic AI Post-Tidy Gate via Editor before_stage_diff_hooks
    my $raw_ai_code = "package Demo::Messy;\nuse strict;\nuse warnings;\nsub ai_gen{my(\$z)=\@_;return \$z*2;}\n1;\n";
    my $gated = $ed->run_before_stage_diff_hooks($buf, $raw_ai_code, { source => 'agy' });
    like($gated, qr/sub ai_gen \{/, 'AI post-tidy gate automatically formatted proposed Perl diff');

    # Optional :set perltidy_on_save
    $ed->set_option('perltidy_on_save', 1);
    $ed->emit('BufWritePre', buf => $buf);
    like($buf->get_text, qr/sub ugly_fmt \{/, 'perltidy_on_save formatted buffer on BufWritePre');

    # PPI-backed Modal ]] / [[ motion, dif text object, and Visual gq formatter
    my $wbuf = $ed->create_buffer(name => 'widget.pm', filetype => 'perl', text => $sample_perl);
    $ed->switch_buffer($wbuf->id);
    $ed->jump_to($wbuf, 17, 0);
    $ed->feed_keys(']]');
    is($ed->current_window->cursor_line, 22, 'Modal ]] jumped via PPI to compute_total');
    $ed->feed_keys('[[');
    is($ed->current_window->cursor_line, 17, 'Modal [[ jumped back via PPI to helper_scale');

    # Test dif (delete inside function) using PPI text-object hook
    $ed->jump_to($wbuf, 18, 4);
    my $before_lines = $wbuf->line_count;
    $ed->feed_keys('dif');
    cmp_ok($wbuf->line_count, '<', $before_lines, 'Modal dif deleted inner body of helper_scale via PPI');
    $ed->feed_keys('u');    # undo back

    # Test Visual-line gq selection tidying via registered Perl formatter
    my $gq_buf = $ed->create_buffer(name => 'gq.pl', filetype => 'perl',
        text => "sub outer {\n    if (1) {\n        my\$v=1+2;\n    }\n}\n");
    $ed->switch_buffer($gq_buf->id);
    $ed->jump_to($gq_buf, 2, 0);
    $ed->feed_keys('Vgq');
    like($gq_buf->get_line(2), qr/^        my \$v = 1 \+ 2;/, 'Visual gq tidied Perl selection preserving 8-space base indent');

    # MCP Tools 15-18
    if ($mcp) {
        for my $t (qw(neoperl_perl_outline neoperl_perl_slice neoperl_perl_critic neoperl_perl_tidy)) {
            ok($mcp->has_tool($t), "EditorMCP registered $t");
        }
        my $mo = $mcp->call_tool_local('neoperl_perl_outline', { text => $sample_perl });
        ok($mo->{ok} && @{ $mo->{items} } >= 5, 'MCP neoperl_perl_outline returned AST items');
        my $ms = $mcp->call_tool_local('neoperl_perl_slice', { text => $sample_perl, line => 27 });
        is($ms->{enclosing_sub}, 'compute_total', 'MCP neoperl_perl_slice sliced compute_total');
        my $mc = $mcp->call_tool_local('neoperl_perl_critic', { text => $messy_code, severity => 4 });
        cmp_ok(scalar(@{ $mc->{violations} }), '>=', 2, 'MCP neoperl_perl_critic returned violations');
        my $mt = $mcp->call_tool_local('neoperl_perl_tidy', { text => "sub x{return 1;}\n" });
        ok($mt->{ok} && $mt->{text} =~ /sub x \{/, 'MCP neoperl_perl_tidy formatted code');
    }
    else {
        pass('EditorMCP optional skip') for 1 .. 8;
    }

    $pdev->shutdown;
}

# 11. Graceful Fallback Verification (force_fallback => 1, skip_cli => 1)
{
    my $fb = NeoPerl::Plugin::PerlDev::Worker->new(force_fallback => 1);
    my $fc = $fb->capabilities;
    is($fc->{ppi_mode}, 'fallback', 'force_fallback disables PPI inproc');
    my $fo = $fb->outline(1, 1, $sample_perl);
    like($fo->{backend}, qr/fallback$/, 'outline degraded cleanly to C11/built-in fallback');
    ok((grep { $_->{name} eq 'compute_total' } @{ $fo->{items} }), 'fallback outline found compute_total');
    my $fcr = $fb->critic(1, 1, $messy_code, skip_cli => 1);
    is($fcr->{backend}, 'fallback', 'critic degraded cleanly to built-in fallback');
    cmp_ok(scalar(@{ $fcr->{violations} }), '>=', 2, 'fallback critic still flags missing strict and return undef');
    my $ft = $fb->tidy("sub a {\nmy \$x = 1;\n}\n", skip_cli => 1);
    is($ft->{backend}, 'fallback', 'tidy degraded cleanly to built-in fallback');
    like($ft->{text}, qr/^    my \$x = 1;/m, 'fallback tidy indented block body');
}

# 12. Optional live perl5-mt MT::Worker async channel round-trip
if ($caps->{has_mt} && $caps->{ppi} && $caps->{critic} && $caps->{tidy}) {
    my $mtw = NeoPerl::Plugin::PerlDev::Worker->new(use_mt_worker => 1);
    if ($mtw->capabilities->{worker_mode} eq 'mt_worker') {
        my $r1 = $mtw->request_mt_sync('outline', { buf_id => 9, rev => 1, text => $sample_perl }, 10);
        ok($r1 && $r1->{ok} && @{ $r1->{result}{items} || [] } >= 5,
            'MT::Worker persistent async channel returned live PPI outline');
        my $r2 = $mtw->request_mt_sync('critic', { buf_id => 9, rev => 1, text => $sample_perl, severity => 4 }, 10);
        ok($r2 && $r2->{ok}, 'MT::Worker persistent async channel returned live Perl::Critic result');
        $mtw->shutdown;
    }
}

$worker->shutdown;
done_testing();
