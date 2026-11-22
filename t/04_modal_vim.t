use strict;
use warnings;
use Test::More;

use NeoPerl::Editor;

sub make_editor {
    my ($text, %opts) = @_;
    my $ed = NeoPerl::Editor->new(%opts);
    my $buf = $ed->current_buffer;
    $buf->set_text($text) if defined $text;
    $ed->current_window->set_cursor(0, 0);
    return ($ed, $buf, $ed->current_window);
}

# 1. Basic modes, insert, append, open lines, replace
{
    my ($ed, $buf, $win) = make_editor("hello world");
    is($ed->modal->mode, 'NORMAL', 'starts in NORMAL mode');

    $ed->feed_keys('A!<Esc>');
    is($buf->get_line(0), 'hello world!', 'A appends at end of line');
    is($ed->modal->mode, 'NORMAL', 'returns to NORMAL after <Esc>');

    $ed->feed_keys('I>> <Esc>');
    is($buf->get_line(0), '>> hello world!', 'I inserts at first non-blank');

    $ed->feed_keys('osecond<Esc>');
    is($buf->line_count, 2, 'o opens new line below');
    is($buf->get_line(1), 'second', 'o inserted text on line 1');

    $ed->feed_keys('Ofirst<Esc>');
    is($buf->get_line(1), 'first', 'O opens new line above');
    is($buf->get_line(2), 'second', 'original line shifted down');

    # Replace mode R and single-char r
    $ed->feed_keys('gg0');
    $ed->feed_keys('r#');
    is($buf->get_line(0), '#> hello world!', 'r replaces single char');
    $ed->feed_keys('0R--<Esc>');
    is($buf->get_line(0), '-- hello world!', 'R overwrites chars in REPLACE mode');
}

# 2. Composable counts, motions, operators, and registers
{
    my ($ed, $buf, $win) = make_editor("one two three\nfour five six\nseven eight nine\nten eleven twelve");
    $ed->feed_keys('2j');
    is($win->cursor_line, 2, '2j moves down 2 lines');

    $ed->feed_keys('w');
    is($win->cursor_col, 6, 'w moves to next word');
    $ed->feed_keys('e');
    is($win->cursor_col, 10, 'e moves to end of word');
    $ed->feed_keys('b');
    is($win->cursor_col, 6, 'b moves back to start of word');

    # Composable count * op * count * motion: 2dw and d2w
    $ed->feed_keys('gg0');
    $ed->feed_keys('d2w');
    is($buf->get_line(0), 'three', 'd2w deletes two words');

    # Linewise delete with count into named register "a, then append "A
    $ed->feed_keys('"a2dd');
    is($buf->line_count, 2, '2dd deletes two lines');
    is($buf->get_line(0), 'seven eight nine', 'remaining top line after 2dd');
    like($ed->modal->get_register('a')->{text}, qr/three\nfour five six\n/, '"a captured deleted lines');

    $ed->feed_keys('"Ayy');
    like($ed->modal->get_register('a')->{text}, qr/seven eight nine\n/, '"A appends to register a');

    # Paste from register "a
    $ed->feed_keys('G"ap');
    is($buf->line_count, 5, '"ap pastes 3 lines after last line');

    # Delete history ring "1.."9 and blackhole "_
    $ed->feed_keys('gg"0p');
    $ed->feed_keys('gg"_dd');
    unlike($ed->modal->get_register('"')->{text}, qr/^\s*$/, '"_ blackhole does not clobber unnamed register');
}

# 3. Character find (f/F/t/T/; ,) and bracket match %
{
    my ($ed, $buf, $win) = make_editor("alpha(beta[gamma]) + delta");
    $ed->feed_keys('0f(');
    is($win->cursor_col, 5, 'f( finds opening paren');
    $ed->feed_keys('%');
    is($win->cursor_col, 17, '% jumps to matching closing paren');
    $ed->feed_keys('%');
    is($win->cursor_col, 5, '% jumps back to opening paren');

    $ed->feed_keys('0ta');
    is($win->cursor_col, 3, 'ta lands before second a');
    $ed->feed_keys(';');
    is($win->cursor_col, 8, '; repeats forward find');
    $ed->feed_keys(',');
    is($win->cursor_col, 5, ', reverses find direction');
}

# 4. Text objects: iw/aw, iW/aW, quotes, pairs, ip/ap, if/af + custom PPI hook
{
    my ($ed, $buf, $win) = make_editor(qq{foo_bar "hello world" 'single' `tick` (a + b) [1, 2] {x: 1} <tag>});

    $ed->feed_keys('0lciwCHANGED<Esc>');
    like($buf->get_line(0), qr/^CHANGED "hello world"/, 'ciw replaces inner word');

    $ed->feed_keys('0f"lci"STR<Esc>');
    like($buf->get_line(0), qr/"STR"/, 'ci" replaces inside double quotes');

    $ed->feed_keys("0f'lci'ONE<Esc>");
    like($buf->get_line(0), qr/'ONE'/, "ci' replaces inside single quotes");

    $ed->feed_keys('0f`lci`CMD<Esc>');
    like($buf->get_line(0), qr/`CMD`/, 'ci` replaces inside backticks');

    $ed->feed_keys('0f(lci(42<Esc>');
    like($buf->get_line(0), qr/\(42\)/, 'ci( replaces inside parens');

    $ed->feed_keys('0f[lci[9<Esc>');
    like($buf->get_line(0), qr/\[9\]/, 'ci[ replaces inside brackets');

    $ed->feed_keys('0f{lci{y: 2<Esc>');
    like($buf->get_line(0), qr/\{y: 2\}/, 'ci{ replaces inside braces');

    $ed->feed_keys('0f<lci<div<Esc>');
    like($buf->get_line(0), qr/<div>/, 'ci< replaces inside angle brackets');

    # Around quotes a"
    $ed->feed_keys('0f"da"');
    unlike($buf->get_line(0), qr/"STR"/, 'da" removes quotes and inner text');
}

# 5. Paragraph (ip/ap) and Function (if/af) built-in & custom hook delegation
{
    my $code = join("\n",
        "sub alpha {",
        "    my \$x = 1;",
        "    return \$x;",
        "}",
        "",
        "sub beta {",
        "    return 2;",
        "}",
    );
    my ($ed, $buf, $win) = make_editor($code);

    # Built-in ]] / [[ motion
    $ed->feed_keys(']]');
    is($win->cursor_line, 5, ']] jumps to next sub');
    $ed->feed_keys('[[');
    is($win->cursor_line, 0, '[[ jumps back to previous sub');

    # Custom text-object hook for if (simulating PPI / Tree-sitter delegation)
    my $hook_called = 0;
    $ed->modal->register_text_object('if', sub {
        my ($e, $b, $l, $c) = @_;
        $hook_called++;
        return { start_line => 1, start_col => 0, end_line => 2, end_col => 14, linewise => 1 };
    });
    $win->set_cursor(1, 4);
    $ed->feed_keys('yif');
    is($hook_called, 1, 'if text object delegates to registered PPI/Tree-sitter hook');
    like($ed->modal->get_register('"')->{text}, qr/my \$x = 1;\n    return \$x;/, 'yif yanked hooked sub body');

    # dip deletes first paragraph
    $win->set_cursor(1, 0);
    $ed->feed_keys('dap');
    is($buf->get_line(0), 'sub beta {', 'dap deletes paragraph plus trailing blank line');
}

# 6. Visual (v), Visual Line (V), Visual Block (<C-v> delete + block I insert)
{
    my ($ed, $buf, $win) = make_editor("foo 111\nbar 222\nbaz 333");

    # Charwise visual uppercase
    $ed->feed_keys('0v2lU');
    is($buf->get_line(0), 'FOO 111', 'visual v + U uppercases selection');

    # Linewise visual indent (>)
    $ed->feed_keys('ggVj>');
    is($buf->get_line(0), '    FOO 111', 'VLINE > indents line 0');
    is($buf->get_line(1), '    bar 222', 'VLINE > indents line 1');
    is($buf->get_line(2), 'baz 333',     'VLINE > leaves line 2 untouched');

    # Dedent back
    $ed->feed_keys('ggVj<');
    is($buf->get_line(0), 'FOO 111', 'VLINE < dedents line 0');

    # Visual Block <C-v> column delete
    $ed->feed_keys('gg0<C-v>2j2ld');
    is($buf->get_line(0), ' 111', 'VBLOCK delete removes column slice on line 0');
    is($buf->get_line(1), ' 222', 'VBLOCK delete removes column slice on line 1');
    is($buf->get_line(2), ' 333', 'VBLOCK delete removes column slice on line 2');

    # Visual Block <C-v> I multi-line insert
    $ed->feed_keys('gg0<C-v>2jI# <Esc>');
    is($buf->get_line(0), '#  111', 'VBLOCK I inserts prefix on line 0');
    is($buf->get_line(1), '#  222', 'VBLOCK I inserts prefix on line 1');
    is($buf->get_line(2), '#  333', 'VBLOCK I inserts prefix on line 2');
}

# 7. Dot-repeat (.)
{
    my ($ed, $buf, $win) = make_editor("apple\nbanana\ncherry\ndate");
    $ed->feed_keys('gg0ciwFRUIT<Esc>');
    is($buf->get_line(0), 'FRUIT', 'initial ciw edit');
    $ed->feed_keys('j.');
    is($buf->get_line(1), 'FRUIT', 'dot-repeat replays ciw with inserted text');
    $ed->feed_keys('j.');
    is($buf->get_line(2), 'FRUIT', 'dot-repeat works repeatedly');

    $ed->feed_keys('ggdd');
    is($buf->line_count, 3, 'dd deletes 1 line');
    $ed->feed_keys('2.');
    is($buf->line_count, 1, '2. replays dd with count override 2');
    is($buf->get_line(0), 'date', 'only last line remains');
}

# 8. Macros (q / @ / @@)
{
    my ($ed, $buf, $win) = make_editor("a\nb\nc\nd");
    $ed->feed_keys('ggqaI- <Esc>jq');
    is($buf->get_line(0), '- a', 'macro recorded and executed on line 0');
    is($win->cursor_line, 1, 'macro moved cursor to line 1');
    $ed->feed_keys('@a');
    is($buf->get_line(1), '- b', '@a replayed macro on line 1');
    $ed->feed_keys('2@@');
    is($buf->get_line(2), '- c', '2@@ replayed macro on line 2');
    is($buf->get_line(3), '- d', '2@@ replayed macro on line 3');
}

# 9. Marks (local m/'/` and global mA)
{
    my ($ed, $buf, $win) = make_editor("line0\n  line1 target\nline2");
    $win->set_cursor(1, 8);
    $ed->feed_keys('ma');
    $ed->feed_keys('gg0');
    $ed->feed_keys('`a');
    is($win->cursor_line, 1, '`a jumps to exact mark line');
    is($win->cursor_col,  8, '`a jumps to exact mark col');

    $ed->feed_keys('gg0');
    $ed->feed_keys("'a");
    is($win->cursor_line, 1, "'a jumps to mark line");
    is($win->cursor_col,  2, "'a lands on first non-blank");

    # Global mark across buffers
    $ed->feed_keys('mA');
    my $buf2 = $ed->create_buffer(name => 'other.txt', text => "other buffer");
    $ed->switch_buffer($buf2->id);
    is($ed->current_buffer->id, $buf2->id, 'switched to buffer 2');
    $ed->feed_keys('`A');
    is($ed->current_buffer->id, $buf->id, '`A jumps back to original buffer');
    is($win->cursor_line, 1, '`A restores global mark line');
}

# 10. Branching undo (u, <C-r>, g-, g+)
{
    my ($ed, $buf, $win) = make_editor("base");
    $ed->feed_keys('A-v1<Esc>');
    is($buf->get_line(0), 'base-v1', 'branch 1 edit');
    $ed->feed_keys('u');
    is($buf->get_line(0), 'base', 'u undoes branch 1');
    $ed->feed_keys('A-v2<Esc>');
    is($buf->get_line(0), 'base-v2', 'branch 2 edit');

    $ed->feed_keys('g-');
    # Stepping chronologically older visits branch 1
    my $seen_v1 = ($buf->get_line(0) eq 'base-v1') ? 1 : 0;
    if (!$seen_v1) {
        $ed->feed_keys('g-');
        $seen_v1 = ($buf->get_line(0) eq 'base-v1') ? 1 : 0;
    }
    ok($seen_v1, 'g- traverses undo tree across alternate branch (base-v1)');
    $ed->feed_keys('g+');
    $ed->feed_keys('g+') if $buf->get_line(0) ne 'base-v2';
    is($buf->get_line(0), 'base-v2', 'g+ traverses forward back to latest state');
}

# 11. Search (/ and ? and n/N and */#) + :%s
{
    my ($ed, $buf, $win) = make_editor("foo one\nbar two\nfoo three\nbaz foo");
    $ed->feed_keys('/foo<CR>');
    is($win->cursor_line, 2, '/foo finds next match on line 2');
    $ed->feed_keys('n');
    is($win->cursor_line, 3, 'n finds next match on line 3');
    is($win->cursor_col,  4, 'n lands on foo col 4');
    $ed->feed_keys('N');
    is($win->cursor_line, 2, 'N reverses search to line 2');

    $ed->feed_keys(':%s/foo/FOO/g<CR>');
    is($buf->get_line(0), 'FOO one',   ':%s replaced line 0');
    is($buf->get_line(2), 'FOO three', ':%s replaced line 2');
    is($buf->get_line(3), 'baz FOO',   ':%s replaced line 3');
}

# 12. <Tab> ghost text vs <C-i> distinct keymap + custom gq formatter + <leader> maps
{
    my ($ed, $buf, $win) = make_editor("my \$x = ");
    $buf->set_ghost_text(0, 8, "42;");
    my $gmarks = $buf->get_extmarks('agy_ghost');
    is(scalar(@{$gmarks}), 1, 'ghost text created extmark in agy_ghost namespace');

    $ed->feed_keys('A<Tab><Esc>');
    is($buf->get_line(0), 'my $x = 42;', '<Tab> in INSERT accepted ghost text');
    ok(!$buf->ghost_text, 'ghost text cleared after acceptance');

    # <C-i> must stay distinct from <Tab>
    my $ci_fired = 0;
    $ed->modal->map('n', '<C-i>', sub { $ci_fired++ }, desc => 'Inline command');
    $ed->feed_keys('<C-i>');
    is($ci_fired, 1, '<C-i> triggers inline command mapping distinctly from <Tab>');

    # Custom gq formatter hook
    $ed->modal->register_formatter('perl', sub {
        my ($e, $b, $s, $end) = @_;
        return [ map { uc($_) } @{ $b->get_lines($s, $end + 1) } ];
    });
    $buf->filetype('perl');
    $ed->feed_keys('ggVgq');
    is($buf->get_line(0), 'MY $X = 42;', 'gq delegates to registered filetype formatter');

    # Default <leader> Command Center toggles
    is($ed->layout->command_center_open, 0, 'Command Center closed initially');
    $ed->feed_keys('<leader>aa');
    is($ed->layout->command_center_open, 1, '<leader>aa opens Command Center');
    is($ed->layout->command_center_tab, 'chat', '<leader>aa opens chat tab');
    $ed->feed_keys('<leader>am');
    is($ed->layout->command_center_tab, 'memory', '<leader>am switches to memory tab');
    $ed->feed_keys('<leader>aj');
    is($ed->layout->command_center_tab, 'jobs', '<leader>aj switches to jobs tab');
    $ed->feed_keys('<leader>xd');
    is($ed->layout->command_center_tab, 'xsdev', '<leader>xd switches to xsdev tab');
    $ed->feed_keys('<leader>xd');
    is($ed->layout->command_center_open, 0, '<leader>xd toggles closed when already on xsdev');
}

done_testing();
