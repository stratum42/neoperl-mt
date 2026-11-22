use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use Time::HiRes qw(time);

use NeoPerl::Core qw(:tokens arch_info detect_language token_name
                     is_perl5_mt force_scalar timebase_ticks);

# 1. Architecture & runtime info
my $info = arch_info();
ok(ref($info) eq 'HASH', 'arch_info returns hashref');
ok(length($info->{arch}) > 0, "arch detected: $info->{arch}");
cmp_ok($info->{page_size}, '>=', 4096, "dynamic page_size >= 4096 ($info->{page_size})");
ok(($info->{page_size} & ($info->{page_size} - 1)) == 0, 'page_size is power of 2');
cmp_ok($info->{logical_cpus}, '>=', 1, "logical_cpus >= 1 ($info->{logical_cpus})");
cmp_ok($info->{physical_cores}, '>=', 1, "physical_cores >= 1 ($info->{physical_cores})");
cmp_ok($info->{physical_cores}, '<=', $info->{logical_cpus}, 'physical_cores <= logical_cpus');
ok(length($info->{simd_level}) > 0, "simd_level: $info->{simd_level}");
ok(defined $info->{power_isa}, "power_isa: $info->{power_isa}");
ok(exists $info->{has_nx_gzip}, 'arch_info exposes has_nx_gzip');
ok(exists $info->{has_treesitter}, 'arch_info exposes has_treesitter');
ok(exists $info->{has_libllama}, 'arch_info exposes has_libllama');

my $t0 = timebase_ticks();
my $t1 = timebase_ticks();
ok($t1 >= $t0, 'timebase_ticks is monotonic');

# Verify PERL_FORCE_SCALAR dynamic override
{
    local $ENV{PERL_FORCE_SCALAR} = '1';
    is(force_scalar(), 1, 'force_scalar detects PERL_FORCE_SCALAR=1');
    my $si = arch_info();
    is($si->{simd_level}, 'scalar', 'arch_info reports scalar when PERL_FORCE_SCALAR=1');
    is($si->{recommended_workers}, 1, 'recommended_workers is 1 when PERL_FORCE_SCALAR=1');
}

# 2. Piece-table basic operations
my $buf = NeoPerl::Core::Buffer->from_string("alpha\nbeta\ngamma\n");
is($buf->line_count(), 4, 'line_count includes trailing empty line after final newline');
is($buf->byte_length(), 17, 'byte_length exact');
is($buf->get_line(0), 'alpha', 'get_line(0)');
is($buf->get_line(1), 'beta', 'get_line(1)');
is($buf->get_line(2), 'gamma', 'get_line(2)');
is($buf->get_line(3), '', 'get_line(3)');
ok(!defined $buf->get_line(4), 'get_line OOB returns undef');
is_deeply($buf->get_lines(0, 3), ['alpha', 'beta', 'gamma'], 'get_lines slice');

my ($lb_st, $lb_len) = $buf->line_bounds(1);
is($lb_st, 6, 'line 1 start offset');
is($lb_len, 4, 'line 1 byte len');
is($buf->line_col_to_offset(1, 2), 8, 'line_col_to_offset');
my ($ol, $oc) = $buf->offset_to_line_col(8);
is_deeply([$ol, $oc], [1, 2], 'offset_to_line_col round-trip');

# Insert & delete
my $rev0 = $buf->revision();
$buf->insert(6, "BETA_");
is($buf->get_line(1), 'BETA_beta', 'insert at line start');
cmp_ok($buf->revision(), '>', $rev0, 'revision increments on insert');
$buf->delete(6, 5);
is($buf->get_line(1), 'beta', 'delete restores text');
is($buf->to_string(), "alpha\nbeta\ngamma\n", 'to_string matches');

# 3. 500k-line mmap open & SIMD vs PERL_FORCE_SCALAR parity
my $dir = tempdir(CLEANUP => 1);
my $big_path = "$dir/big_500k.txt";
{
    open my $fh, '>', $big_path or die "open $big_path: $!";
    my $chunk = join('', map { "line_number_$_: payload_data_0123456789\n" } 0..999);
    for (1..500) {
        print {$fh} $chunk;
    }
    close $fh;
}

my $open_t0 = time();
my $big_simd;
{
    local $ENV{PERL_FORCE_SCALAR} = '0';
    $big_simd = NeoPerl::Core::Buffer->open_file($big_path);
    is($big_simd->line_count(), 500_001, '500k-line mmap open line_count (SIMD)');
}
my $open_ms = (time() - $open_t0) * 1000.0;
ok($open_ms < 2000, sprintf('500k-line mmap open + index fast (%.1f ms)', $open_ms));

my $big_scalar;
{
    local $ENV{PERL_FORCE_SCALAR} = '1';
    $big_scalar = NeoPerl::Core::Buffer->open_file($big_path);
    is($big_scalar->line_count(), $big_simd->line_count(), '500k-line count identical under PERL_FORCE_SCALAR=1');
}
for my $check_line (0, 1, 1234, 250_000, 499_999) {
    is($big_simd->get_line($check_line), $big_scalar->get_line($check_line),
       "500k-line SIMD vs scalar parity at line $check_line");
}
undef $big_simd;
undef $big_scalar;

# Save file round-trip
my $save_path = "$dir/saved.txt";
ok($buf->save_file($save_path), 'save_file succeeds');
my $reopened = NeoPerl::Core::Buffer->open_file($save_path);
is($reopened->to_string(), $buf->to_string(), 'save_file + open_file exact round-trip');

# 4. Branching Undo Tree (u, <C-r>, g-, g+, undo_goto, groups, undo_list)
my $ub = NeoPerl::Core::Buffer->from_string("base");
is($ub->undo_seq(), 0, 'initial undo seq is 0');
ok(!$ub->can_undo(), 'cannot undo at root');
ok(!$ub->can_redo(), 'cannot redo at root');

# Grouped edit (seq 1)
$ub->begin_group();
$ub->insert(4, " one");
$ub->insert(8, "!");
$ub->end_group();
is($ub->to_string(), 'base one!', 'grouped edit applied');
is($ub->undo_seq(), 1, 'grouped edit created single undo node seq=1');

# Branch A edit (seq 2)
$ub->insert(9, " [branchA]");
is($ub->to_string(), 'base one! [branchA]', 'branch A text');
is($ub->undo_seq(), 2, 'branch A seq=2');

# Undo back to seq 1, then make Branch B edit (seq 3)
is($ub->undo(), 1, 'undo from branch A to seq 1');
is($ub->to_string(), 'base one!', 'back at seq 1');
$ub->insert(9, " [branchB]");
is($ub->to_string(), 'base one! [branchB]', 'branch B text');
is($ub->undo_seq(), 3, 'branch B seq=3');

# Verify undo tree preserves both branches
my $ulist = $ub->undo_list();
is(scalar(@$ulist), 4, 'undo_list has 4 nodes (root + seq 1 + branchA + branchB)');
is_deeply($ulist->[1]{children}, [2, 3], 'node 1 has two child branches [2, 3]');

# Vim g- (undo_older): seq 3 -> seq 2 (reaches Branch A)
is($ub->undo_older(), 1, 'undo_older (g-) moves from seq 3 to seq 2');
is($ub->undo_seq(), 2, 'now at seq 2');
is($ub->to_string(), 'base one! [branchA]', 'g- recovered abandoned Branch A');

# g- again -> seq 1 -> seq 0
is($ub->undo_older(), 1, 'g- to seq 1');
is($ub->to_string(), 'base one!', 'seq 1 content');
is($ub->undo_older(), 1, 'g- to seq 0');
is($ub->to_string(), 'base', 'seq 0 root content');
is($ub->undo_older(), 0, 'g- at seq 0 returns 0');

# Vim g+ (undo_newer): seq 0 -> 1 -> 2 -> 3
is($ub->undo_newer(), 1, 'g+ to seq 1');
is($ub->undo_newer(), 1, 'g+ to seq 2');
is($ub->to_string(), 'base one! [branchA]', 'g+ visits Branch A');
is($ub->undo_newer(), 1, 'g+ to seq 3');
is($ub->to_string(), 'base one! [branchB]', 'g+ visits Branch B');
is($ub->undo_newer(), 0, 'g+ at newest returns 0');

# undo_goto direct jump
is($ub->undo_goto(2), 1, 'undo_goto(2) jumps directly to Branch A');
is($ub->to_string(), 'base one! [branchA]', 'undo_goto(2) text verified');

# Undo & Redo after group
is($ub->undo(), 1, 'undo from 2 to 1');
is($ub->undo(), 1, 'undo grouped edit 1 to 0 in one step');
is($ub->to_string(), 'base', 'grouped edit undone atomically');
is($ub->redo(), 1, 'redo grouped edit 0 to 1');
is($ub->to_string(), 'base one!', 'grouped edit redone atomically');

# 5. Byte-anchored extmarks + gravity across edits/undo/redo
my $eb = NeoPerl::Core::Buffer->from_string("line0\nline1\nline2\nline3\n");
my $m1 = $eb->set_extmark('agy_diff', 2, 0, {
    end_line         => 2,
    end_col          => 5,
    hl_group         => 'DiffAdd',
    priority         => 200,
    sign_text        => '+',
    sign_hl          => 'GitAdd',
    virt_text        => '  # added',
    virt_hl          => 'Comment',
    virt_pos         => 'eol',
    virt_lines       => ['- old_line_a', '- old_line_b'],
    virt_lines_hl    => ['DiffDelete', 'DiffDelete'],
    virt_lines_above => 1,
});
ok($m1 > 0, 'set_extmark returned positive id');
my $m2 = $eb->set_extmark('lsp', 1, 2, {
    hl_group  => 'DiagnosticError',
    sign_text => 'E',
    virt_text => 'undefined var',
});
is($eb->extmark_count(), 2, 'extmark_count total is 2');
is($eb->extmark_count('agy_diff'), 1, 'extmark_count for namespace agy_diff is 1');

# Verify all fields round-trip
my $marks = $eb->get_extmarks('agy_diff', 0, -1);
is(scalar(@$marks), 1, 'get_extmarks returns 1 mark in agy_diff');
is($marks->[0]{line}, 2, 'initial extmark line 2');
is($marks->[0]{end_line}, 2, 'initial extmark end_line 2');
is($marks->[0]{end_col}, 5, 'initial extmark end_col 5');
is($marks->[0]{hl_group}, 'DiffAdd', 'hl_group preserved');
is($marks->[0]{priority}, 200, 'priority preserved');
is($marks->[0]{sign_text}, '+', 'sign_text preserved');
is($marks->[0]{sign_hl}, 'GitAdd', 'sign_hl preserved');
is($marks->[0]{virt_text}, '  # added', 'virt_text preserved');
is($marks->[0]{virt_pos}, 'eol', 'virt_pos preserved');
is_deeply($marks->[0]{virt_lines}, ['- old_line_a', '- old_line_b'], 'virt_lines preserved');
is_deeply($marks->[0]{virt_lines_hl}, ['DiffDelete', 'DiffDelete'], 'virt_lines_hl preserved');
is($marks->[0]{virt_lines_above}, 1, 'virt_lines_above preserved');

# Insert 2 lines above line 2 -> extmark shifts down to line 4
$eb->insert(0, "insA\ninsB\n");
$marks = $eb->get_extmarks('agy_diff', -1, -1);
is($marks->[0]{line}, 4, 'extmark shifted down to line 4 after insert above');
is($marks->[0]{end_line}, 4, 'extmark end_line shifted to line 4');

# Undo insert -> extmark shifts back to line 2
$eb->undo();
$marks = $eb->get_extmarks('agy_diff', -1, -1);
is($marks->[0]{line}, 2, 'extmark shifted back to line 2 after undo');

# Redo insert -> extmark shifts back to line 4
$eb->redo();
$marks = $eb->get_extmarks('agy_diff', -1, -1);
is($marks->[0]{line}, 4, 'extmark shifted back to line 4 after redo');

# Delete & clear_namespace
ok($eb->del_extmark('lsp', $m2), 'del_extmark removes lsp mark');
is($eb->extmark_count('lsp'), 0, 'lsp namespace empty');
$eb->clear_namespace('agy_diff');
is($eb->extmark_count(), 0, 'clear_namespace empties agy_diff');

done_testing();
