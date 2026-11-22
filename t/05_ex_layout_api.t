use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Time::HiRes qw(sleep);

use NeoPerl::Editor;

my $tmp = tempdir(CLEANUP => 1);

# 1. Buffer staged inline diff proposal state machine (agy_diff extmarks, hunk nav, partial accept/reject)
{
    my $ed  = NeoPerl::Editor->new(cwd => $tmp);
    my $buf = $ed->current_buffer;
    my $orig = join("\n",
        "sub alpha {",
        "    return 1;",
        "}",
        "sub middle {",
        "    return 5;",
        "}",
        "sub omega {",
        "    return 9;",
        "}",
    ) . "\n";
    $buf->set_text($orig);

    my $proposed = join("\n",
        "sub alpha {",
        "    return 100;",
        "}",
        "sub middle {",
        "    return 5;",
        "}",
        "sub omega {",
        "    return 900;",
        "    # extra line",
        "}",
    ) . "\n";

    my @events;
    $ed->on('AgyProposal',         sub { push @events, 'proposal' });
    $ed->on('AgyProposalResolved', sub { push @events, 'resolved' });

    my $staged = $buf->stage_diff_proposal($proposed, source => 'antigravity');
    is($staged->{count}, 2, 'stage_diff_proposal detected 2 Myers diff hunks');
    is($events[0], 'proposal', 'AgyProposal event emitted');
    ok($buf->has_diff_proposal, 'buffer reports pending diff proposal');

    # Check extmarks in agy_diff: must have red virt_lines (DiffDelete) AND green line highlights (DiffAdd)
    my $marks = $buf->get_extmarks('agy_diff');
    my @del_marks = grep { ref($_->{virt_lines}) eq 'ARRAY' && @{$_->{virt_lines}} } @{$marks};
    my @add_marks = grep { ($_->{hl_group} // '') eq 'DiffAdd' } @{$marks};
    ok(@del_marks >= 2, 'painted red virtual deleted lines in agy_diff for both hunks');
    ok(@add_marks >= 3, 'painted green added line highlights in agy_diff');
    like($del_marks[0]{virt_lines}[0], qr/return 1;/, 'virtual deleted line contains original removed line');

    # Hunk navigation: next_hunk / prev_hunk and ]h / [h
    my $h1 = $buf->next_hunk(0);
    is($h1->{index}, 0, 'next_hunk from line 0 finds hunk 0');
    my $h2 = $buf->next_hunk($h1->{cur_start});
    is($h2->{index}, 1, 'next_hunk advances to hunk 1');
    my $hprev = $buf->prev_hunk($h2->{cur_start});
    is($hprev->{index}, 0, 'prev_hunk goes back to hunk 0');

    # Partial resolution: reject hunk 0, accept hunk 1
    ok($buf->reject_hunk(0), 'reject_hunk(0) succeeded');
    is(scalar(@{ $buf->list_diff_hunks }), 1, '1 pending hunk remains after rejecting hunk 0');
    like($buf->get_text, qr/return 1;/,   'hunk 0 reverted to return 1');
    like($buf->get_text, qr/return 900;/, 'hunk 1 still has proposed return 900');

    ok($buf->accept_hunk(1), 'accept_hunk(1) succeeded');
    ok(!$buf->has_diff_proposal, 'proposal fully resolved after accepting remaining hunk');
    is($events[-1], 'resolved', 'AgyProposalResolved emitted once all hunks resolved');
    is(scalar(@{ $buf->get_extmarks('agy_diff') }), 0, 'agy_diff extmarks cleared on resolution');
    like($buf->get_text, qr/return 1;.*return 900;.*# extra line/s, 'merged buffer text exact');

    # Test reject_all_hunks restores exact original text byte-for-byte
    $buf->set_text($orig);
    $buf->stage_diff_proposal($proposed, source => 'bonsai');
    is($buf->reject_all_hunks, 2, 'reject_all_hunks rejected both hunks');
    is($buf->get_text, $orig, 'reject_all_hunks restored exact original text byte-for-byte');

    # Test accept_all_hunks
    $buf->stage_diff_proposal($proposed, source => 'bonsai');
    is($buf->accept_all_hunks, 2, 'accept_all_hunks accepted both hunks');
    is($buf->get_text, $proposed, 'accept_all_hunks kept exact proposed text');

    # Test before_stage_diff_hook (e.g. automatic Perl::Tidy post-tidy gate)
    $ed->register_before_stage_diff_hook(sub {
        my ($e, $b, $txt, $meta) = @_;
        $txt =~ s/return 900;/return 901;/;
        return $txt;
    });
    $buf->set_text($orig);
    $buf->stage_diff_proposal($proposed, source => 'antigravity');
    like($buf->get_text, qr/return 901;/, 'before_stage_diff_hook transformed proposal before staging');
    $buf->accept_all_hunks;
}

# 2. ExCmd range parsing, file I/O, substitute, global, undo, grep/quickfix, colorscheme, custom commands
{
    my $ed = NeoPerl::Editor->new(cwd => $tmp);
    my $f1 = File::Spec->catfile($tmp, 'one.pl');
    my $f2 = File::Spec->catfile($tmp, 'two.pl');

    open my $fh, '>', $f1 or die $!;
    print {$fh} "use strict;\nmy \$alpha = 1;\nmy \$beta = 2;\nmy \$alpha2 = 3;\n";
    close $fh;

    my $r = $ed->exec_command(":e $f1");
    ok($r->{ok}, ':e opens file');
    is($ed->current_buffer->filetype, 'perl', 'auto-detected perl filetype');
    is($ed->current_buffer->line_count, 5, 'loaded lines cleanly');

    # Preview substitute without mutating
    my $prev = $ed->excmd->preview_substitute($ed, ':%s/alpha/gamma/g');
    is($prev->{count}, 2, 'preview_substitute counts matches accurately');
    like($ed->current_buffer->get_text, qr/alpha/, 'preview_substitute did not modify buffer');

    # Range substitute (lines 2..3 only -> 0-based lines 1..2)
    $r = $ed->exec_command(':2,3s/alpha/ALPHA/g');
    ok($r->{ok}, ':2,3s succeeded');
    is($ed->current_buffer->get_line(1), 'my $ALPHA = 1;', 'line 2 substituted');
    is($ed->current_buffer->get_line(3), 'my $alpha2 = 3;', 'line 4 outside range untouched');

    # :g/pat/d deletes matching lines
    $r = $ed->exec_command(':g/beta/d');
    ok($r->{ok}, ':g/beta/d succeeded');
    unlike($ed->current_buffer->get_text, qr/beta/, ':g deleted matching line');

    # :w writes to new path
    $r = $ed->exec_command(":w $f2");
    ok($r->{ok} && -f $f2, ':w wrote file to disk');
    is($ed->current_buffer->modified, 0, 'dirty flag cleared after :w');

    # :enew, :ls, :bn, :bp, :bd
    $ed->exec_command(':enew');
    is(scalar($ed->list_buffers), 2, ':enew added second buffer');
    my $ls = $ed->exec_command(':ls');
    is(scalar(@{ $ls->{data} }), 2, ':ls returns 2 buffers');
    $ed->exec_command(':bp');
    is($ed->current_buffer->path, $f2, ':bp switched back to file buffer');
    $ed->exec_command(':bn');
    ok(!defined($ed->current_buffer->path), ':bn switched to scratch buffer');
    $ed->exec_command(':bd');
    is(scalar($ed->list_buffers), 1, ':bd deleted scratch buffer');

    # :set options
    $ed->exec_command(':set tabstop=2 nonumber smartcase!');
    is($ed->get_option('tabstop'), 2, ':set tabstop=2');
    is($ed->get_option('number'),  0, ':set nonumber');
    is($ed->get_option('smartcase'), 0, ':set smartcase! toggled off');

    # :colorscheme
    $r = $ed->exec_command(':colorscheme gruvbox');
    ok($r->{ok}, ':colorscheme gruvbox ok');
    is($ed->theme->{name}, 'gruvbox', 'active theme switched to gruvbox');
    $r = $ed->exec_command(':colorscheme nonexistent');
    ok(!$r->{ok}, 'unknown colorscheme rejected cleanly');

    # :grep + quickfix (:copen / :cn / :cp)
    $r = $ed->exec_command(":grep ALPHA $tmp");
    ok($r->{ok} && $r->{count} >= 1, ':grep found ALPHA via C11 Fuzzy::grep_dir');
    ok($ed->quickfix_open, ':grep auto-opened quickfix');
    my $qf_item = $ed->exec_command(':cn');
    ok($qf_item->{ok}, ':cn jumped to quickfix entry');

    # :earlier / :later / :undolist
    $ed->current_buffer->insert_at(0, 0, "# head\n");
    my $ul = $ed->exec_command(':undolist');
    ok($ul->{ok} && scalar(@{ $ul->{data} }) >= 2, ':undolist lists undo states');
    $ed->exec_command(':earlier 1');
    unlike($ed->current_buffer->get_line(0), qr/^# head/, ':earlier stepped back');
    $ed->exec_command(':later 1');
    like($ed->current_buffer->get_line(0), qr/^# head/, ':later stepped forward');

    # Custom plugin command registration (:AgyChat, :MemSearch, :XSAsm, etc.)
    my $got_arg;
    $ed->excmd->register_command('AgyTest', sub {
        my ($e, $a) = @_;
        $got_arg = $a->{args};
        return { ok => 1, echoed => $a->{args} };
    }, desc => 'Test custom command');
    $r = $ed->exec_command(':AgyTest hello world');
    ok($r->{ok}, 'custom registered command executed');
    is($got_arg, 'hello world', 'custom command received args');

    # :terminal (real POSIX PTY)
    if ($^O ne 'MSWin32') {
        my $tr = $ed->exec_command(':terminal /bin/sh');
        ok($tr->{ok}, ':terminal spawned POSIX PTY');
        is($ed->modal->mode, 'TERMINAL', ':terminal entered TERMINAL mode');
        my $tbuf = $ed->current_buffer;
        ok($tbuf->term && $tbuf->term->is_alive, 'PTY child process alive');
        $ed->feed_keys("echo NPL_TERM_OK<CR>");
        my $saw = 0;
        for (1 .. 30) {
            $ed->pump;
            if ($tbuf->get_text =~ /NPL_TERM_OK/) {
                $saw = 1;
                last;
            }
            sleep(0.02);
        }
        ok($saw, 'POSIX PTY terminal executed shell echo and mirrored output');
        $ed->feed_keys('<C-\\><C-n>');
        is($ed->modal->mode, 'NORMAL', '<C-\\><C-n> exits TERMINAL mode to NORMAL');
        $tbuf->term->kill(15);
    }
}

# 3. Layout: BSP splits, directional focus, tabs, Explorer, 4-Tab Command Center, z-ordered floats
{
    my $ed  = NeoPerl::Editor->new(cwd => $tmp, width => 120, height => 40);
    my $lay = $ed->layout;

    my $w1 = $lay->active_window;
    my $w2 = $lay->vsplit;
    my $w3 = $lay->hsplit;
    is(scalar($lay->list_windows), 3, 'BSP tree holds 3 split windows');

    my $rects = $lay->compute_rects(120, 40);
    is(scalar(@{ $rects->{windows} }), 3, 'compute_rects computed 3 window rects');
    my $area_sum = 0;
    for my $wr (@{ $rects->{windows} }) {
        $area_sum += $wr->{width} * $wr->{height};
    }
    my $ea = $rects->{editor_area};
    is($area_sum, $ea->{width} * $ea->{height}, 'BSP windows tile editor_area with zero overlap or gap');

    # Directional focus <C-w>h / j / k / l
    $lay->focus_window($w3->id);
    $ed->feed_keys('<C-w>k');
    is($lay->active_window->id, $w2->id, '<C-w>k moves focus up from bottom-right to top-right');
    $ed->feed_keys('<C-w>h');
    is($lay->active_window->id, $w1->id, '<C-w>h moves focus left to left split');
    $ed->feed_keys('<C-w>l');
    ok($lay->active_window->id == $w2->id || $lay->active_window->id == $w3->id, '<C-w>l moves focus right');

    # Equalize, close, only
    $lay->resize_window($w1->id, 4, 0);
    $lay->equalize;
    my $eq_rects = $lay->compute_rects(120, 40);
    is($eq_rects->{windows}[0]{width}, 60, 'equalize restores 50/50 vertical split');

    $ed->exec_command(':only');
    is(scalar($lay->list_windows), 1, ':only collapses tab to single window');

    # Tabpages
    $ed->exec_command(':tabnew');
    is($lay->tab_count, 2, ':tabnew created second tabpage');
    $ed->feed_keys('gT');
    is($lay->active_tab->{id}, 1, 'gT switches to previous tab');
    $ed->feed_keys('gt');
    is($lay->active_tab->{id}, 2, 'gt switches to next tab');
    $ed->exec_command(':tabclose');
    is($lay->tab_count, 1, ':tabclose closes active tab');

    # Docked Explorer + 4-Tab Command Center
    $lay->toggle_explorer;
    $lay->toggle_command_center('models');
    is($lay->command_center_tab, 'jobs', 'models alias maps cleanly to jobs tab');
    my $dock_rects = $lay->compute_rects(120, 40);
    ok($dock_rects->{explorer} && $dock_rects->{explorer}{width} > 0, 'Explorer dock rect allocated');
    ok($dock_rects->{command_center} && $dock_rects->{command_center}{width} > 0, 'Command Center dock rect allocated');
    is(
        $dock_rects->{explorer}{width} + $dock_rects->{editor_area}{width} + $dock_rects->{command_center}{width},
        120,
        'Explorer + editor_area + Command Center sum to exact total width'
    );

    # Z-ordered floats
    my $f_high = $lay->open_float(kind => 'whichkey', zindex => 90, width => 40, height => 8, relative => 'center');
    my $f_low  = $lay->open_float(kind => 'hover',    zindex => 40, width => 30, height => 5, relative => 'cursor');
    my @floats = $lay->list_floats;
    is($floats[0]->id, $f_low->id,  'lowest zindex float ordered first');
    is($floats[1]->id, $f_high->id, 'highest zindex float ordered last (on top)');
    $lay->close_float($f_low->id);
    $lay->close_float($f_high->id);
    is(scalar($lay->list_floats), 0, 'floats closed cleanly');
}

# 4. Diagnostics store + DiagnosticResolved event + $vim->api->* + init.pl / .neoperl.pl
{
    my $init_file = File::Spec->catfile($tmp, '.neoperl.pl');
    open my $fh, '>', $init_file or die $!;
    print {$fh} <<'PERL';
$vim->opt(tabstop => 8);
$vim->api->set_option('colorscheme', 'catppuccin');
$vim->keymap_set('n', '<leader>z', sub {
    my ($ed) = @_;
    $ed->api->g->{z_fired} = 1;
}, { desc => 'Test init map' });
$vim->api->create_user_command('InitPing', sub {
    my ($ed) = @_;
    return { ok => 1, pong => 1 };
});
$vim->api->create_autocmd('BufWritePost', {
    callback => sub {
        my (%ev) = @_;
        $vim->g->{writes} = ($vim->g->{writes} || 0) + 1;
    },
});
PERL
    close $fh;

    my $ed = NeoPerl::Editor->new(cwd => $tmp, load_config => 1);
    is($ed->get_option('tabstop'), 8, '.neoperl.pl loaded and set tabstop=8');
    is($ed->theme->{name}, 'catppuccin', '.neoperl.pl switched colorscheme');
    $ed->feed_keys('<leader>z');
    is($ed->api->g->{z_fired}, 1, '.neoperl.pl keymap fired');
    my $pr = $ed->exec_command(':InitPing');
    ok($pr->{ok} && $pr->{pong}, '.neoperl.pl user command executed');

    # $vim->api->* buffer, extmark, cursor, float calls
    my $bid = $ed->api->api->get_current_buf;
    $ed->api->api->buf_set_lines($bid, 0, -1, [ 'alpha', 'beta', 'gamma' ]);
    is($ed->api->api->buf_line_count($bid), 3, '$vim->api->buf_set_lines / buf_line_count');
    $ed->api->api->win_set_cursor(0, [ 2, 3 ]);
    is_deeply($ed->api->api->win_get_cursor(0), [ 2, 3 ], '$vim->api->win_set_cursor / win_get_cursor (1-based row)');

    my $mid = $ed->api->api->buf_set_extmark($bid, 'api_ns', 1, 0, { sign_text => '!', virt_text => 'note' });
    ok($mid > 0, '$vim->api->buf_set_extmark returned mark ID');
    my $ms = $ed->api->api->buf_get_extmarks($bid, 'api_ns');
    is(scalar(@{$ms}), 1, '$vim->api->buf_get_extmarks retrieved mark');

    # Diagnostics store & DiagnosticResolved event
    my ($diag_changed, $diag_resolved) = (0, 0);
    $ed->on('DiagnosticChanged',  sub { $diag_changed++ });
    $ed->on('DiagnosticResolved', sub { my (%ev) = @_; $diag_resolved += scalar(@{ $ev{resolved} }) });

    $ed->set_diagnostics($bid, 'critic', [
        { line => 0, col => 0, severity => 'warn', code => 'Strict', message => 'Missing strict' },
        { line => 2, col => 1, severity => 'error', code => 'Syntax', message => 'Bad token' },
    ]);
    is($diag_changed, 1, 'DiagnosticChanged fired');
    is_deeply($ed->diagnostic_counts($bid), { error => 1, warn => 1, info => 0, hint => 0, total => 2 }, 'diagnostic_counts exact');
    my $dmarks = $ed->current_buffer->get_extmarks('diag_critic');
    is(scalar(@{$dmarks}), 2, 'diagnostics painted extmarks in diag_critic namespace');

    # Resolve one diagnostic
    $ed->set_diagnostics($bid, 'critic', [
        { line => 2, col => 1, severity => 'error', code => 'Syntax', message => 'Bad token' },
    ]);
    is($diag_resolved, 1, 'DiagnosticResolved fired with 1 resolved diagnostic');

    # :perl command
    $ed->exec_command(':perl $vim->g->{from_ex} = 99;');
    is($ed->api->g->{from_ex}, 99, ':perl evaluated inline code with $vim');
}

done_testing();
