use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP qw(decode_json encode_json);

use NeoPerl::Core;
use NeoPerl::Editor;

# Locate real /usr/bin/vim (or vim in PATH)
sub find_real_vim {
    my @cands = ('/usr/bin/vim');
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        my $p = "$dir/vim";
        push @cands, $p if $p ne '/usr/bin/vim';
    }
    for my $p (@cands) {
        next unless -x $p;
        my $out = `"$p" --version 2>/dev/null`;
        if (defined $out && $out =~ /VIM - Vi IMproved\s+([0-9]+\.[0-9]+)/) {
            my $ver = $1;
            my ($maj) = split /\./, $ver;
            return ($p, $ver) if $maj >= 8;
        }
    }
    return (undef, undef);
}

# Convert NeoPerl symbolic keys (<Esc>, <CR>, <BS>, <Tab>, <C-v>, <C-r>, ...) to Vim double-quoted literal string
sub keys_to_vim_expr {
    my ($keys) = @_;
    my $out = '"';
    my $i = 0;
    my $len = length($keys);
    while ($i < $len) {
        if (substr($keys, $i) =~ /\A(<(?:Esc|Escape|CR|Enter|Return|BS|Backspace|Tab|Space|Del|Left|Right|Up|Down|Home|End|C-[a-zA-Z\\\[\]])>)/i) {
            my $tok = $1;
            $out .= '\\' . $tok;
            $i += length($tok);
        }
        else {
            my $ch = substr($keys, $i, 1);
            if    ($ch eq '\\') { $out .= '\\\\' }
            elsif ($ch eq '"')  { $out .= '\\"' }
            elsif ($ch eq "\n") { $out .= '\\<CR>' }
            elsif ($ch eq "\r") { $out .= '\\<CR>' }
            elsif ($ch eq "\t") { $out .= '\\<Tab>' }
            elsif ($ch eq "\e") { $out .= '\\<Esc>' }
            else                { $out .= $ch }
            $i++;
        }
    }
    $out .= '"';
    return $out;
}

# Run a batch of test cases through real /usr/bin/vim -u NONE -N --clean -i NONE
sub run_vim_oracle_batch {
    my ($vim_bin, $cases) = @_;
    my ($sfh, $spath) = tempfile('npl_vim_oracle_XXXX', SUFFIX => '.vim', TMPDIR => 1, UNLINK => 1);
    my ($ofh, $opath) = tempfile('npl_vim_out_XXXX',    SUFFIX => '.json', TMPDIR => 1, UNLINK => 1);
    close $ofh;

    print {$sfh} "set nocompatible shiftwidth=4 tabstop=4 expandtab noautoindent nosmartindent nocindent backspace=indent,eol,start\n";
    print {$sfh} "let s:results = []\n";
    print {$sfh} "let s:clear_regs = split('abcdefghijklmnopqrstuvwxyz0123456789\"-', '\\zs')\n";

    for my $c (@{$cases}) {
        my $lines = $c->{lines};
        my $ljson = encode_json($lines);
        my $kexpr = keys_to_vim_expr($c->{keys});
        my $sl = ($c->{line} // 0) + 1;
        my $sc = ($c->{col}  // 0) + 1;

        print {$sfh} "enew!\n";
        print {$sfh} "for s:r in s:clear_regs | call setreg(s:r, '', 'c') | endfor\n";
        print {$sfh} "silent! delmarks!\n";
        print {$sfh} "setlocal undolevels=-1\n";
        print {$sfh} "call setline(1, json_decode(" . encode_json($ljson) . "))\n";
        print {$sfh} "setlocal undolevels=1000\n";
        print {$sfh} "call cursor($sl, $sc)\n";
        print {$sfh} "call feedkeys($kexpr, 'tx!')\n";
        print {$sfh} "call add(s:results, [join(getline(1, '\$'), \"\\n\"), line('.') - 1, col('.') - 1])\n";
    }

    my $opath_esc = $opath;
    $opath_esc =~ s/\\/\\\\/g;
    $opath_esc =~ s/"/\\"/g;
    print {$sfh} "call writefile([json_encode(s:results)], \"$opath_esc\")\n";
    print {$sfh} "qa!\n";
    close $sfh;

    my $devnull = File::Spec->devnull();
    my $rc;
    my @cmd = ($vim_bin, '-u', 'NONE', '-N', '--clean', '-i', 'NONE', '-n', '--not-a-term', '-S', $spath);
    if ($^O eq 'MSWin32') {
        $rc = system(@cmd);
    }
    else {
        pipe(my $pin_r, my $pin_w) or die "pipe failed: $!";
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            close $pin_w;
            open STDIN,  '<&', $pin_r;
            open STDOUT, '>',  $devnull;
            open STDERR, '>',  $devnull;
            exec(@cmd);
            exit 127;
        }
        close $pin_r;
        waitpid($pid, 0);
        $rc = $?;
        close $pin_w;
    }
    if (!-s $opath) {
        die "Real vim oracle failed (rc=$rc) on $spath";
    }

    open my $rfh, '<', $opath or die "open $opath: $!";
    local $/;
    my $raw = <$rfh>;
    close $rfh;
    return decode_json($raw);
}

# Deterministic LCG PRNG for reproducible fuzzing across Perl versions & architectures
sub make_rng {
    my ($seed) = @_;
    my $state = $seed & 0x7fffffff;
    return sub {
        my ($n) = @_;
        $state = (1103515245 * $state + 12345) & 0x7fffffff;
        return $state % $n;
    };
}

# Build 105+ curated classic & tricky Vim 9.1 conformance cases
my @curated = (
    # --- 1. cw vs dw & word motions (exact Vim 9.1 special cases) ---
    { name => 'cw_excludes_trailing_space', lines => ['one two three'], line => 0, col => 0, keys => 'cwFOO<Esc>' },
    { name => 'dw_includes_trailing_space', lines => ['one two three'], line => 0, col => 0, keys => 'dw' },
    { name => 'cW_excludes_trailing_space', lines => ['foo-bar.baz next'], line => 0, col => 0, keys => 'cWXYZ<Esc>' },
    { name => 'dW_includes_trailing_space', lines => ['foo-bar.baz next'], line => 0, col => 0, keys => 'dW' },
    { name => 'cw_single_char_word',        lines => ['a b c'], line => 0, col => 0, keys => 'cwZ<Esc>' },
    { name => 'cw_on_whitespace',           lines => ['foo   bar'], line => 0, col => 3, keys => 'cw_<Esc>' },
    { name => 'c2w_two_words',              lines => ['one two three four'], line => 0, col => 0, keys => 'c2wPAIR<Esc>' },
    { name => 'dw_last_word_on_line',       lines => ['foo bar', 'baz'], line => 0, col => 4, keys => 'dw' },
    { name => 'dw_trailing_spaces',         lines => ['foo bar   ', 'baz'], line => 0, col => 4, keys => 'dw' },
    { name => 'dw_on_trailing_spaces',      lines => ['foo   ', 'baz'], line => 0, col => 3, keys => 'dw' },
    { name => 'dw_on_empty_line',           lines => ['', 'baz'], line => 0, col => 0, keys => 'dw' },
    { name => 'd2w_stops_before_newline',   lines => ['foo bar', 'baz qux'], line => 0, col => 0, keys => 'd2w' },
    { name => 'd3w_crosses_newline',        lines => ['foo bar', 'baz qux'], line => 0, col => 0, keys => 'd3w' },
    { name => 'w_iskeyword_punct_runs',     lines => ['foo_123++bar::baz'], line => 0, col => 0, keys => 'www' },
    { name => 'W_big_word_motion',          lines => ['foo_123++bar::baz next_word'], line => 0, col => 0, keys => 'W' },
    { name => 'b_and_B_word_backward',      lines => ['alpha beta::gamma delta'], line => 0, col => 20, keys => 'bbB' },
    { name => 'e_and_E_word_end',           lines => ['foo::bar baz_1'], line => 0, col => 0, keys => 'eeE' },
    { name => 'ge_word_end_backward',       lines => ['foo bar baz'], line => 0, col => 8, keys => 'ge' },
    { name => 'ge_mid_word',                lines => ['foo bar baz'], line => 0, col => 5, keys => 'ge' },
    { name => 'gE_big_word_end_backward',   lines => ['a-b c-d e-f'], line => 0, col => 9, keys => 'gE' },
    { name => 'w_stops_on_empty_line',      lines => ['foo', '', 'bar'], line => 0, col => 0, keys => 'w' },
    { name => 'w_skips_whitespace_line',    lines => ['foo', '   ', 'bar'], line => 0, col => 0, keys => 'w' },
    { name => 'b_stops_on_empty_line',      lines => ['foo', '', 'bar'], line => 2, col => 0, keys => 'b' },
    { name => 'w_across_multiple_empty',    lines => ['a', '', '', 'b'], line => 0, col => 0, keys => '3w' },

    # --- 2. Sticky curswant, line motions, H/M/L, gg/G, paragraphs ---
    { name => 'curswant_sticky_across_short', lines => ['0123456789', 'ab', 'ABCDEFGHIJ'], line => 0, col => 7, keys => 'jj' },
    { name => 'curswant_sticky_across_empty', lines => ['0123456789', '', 'ABCDEFGHIJ'], line => 0, col => 8, keys => 'jjk' },
    { name => 'curswant_dollar_sticky_eol',   lines => ['abc', '0123456789', 'xy'], line => 0, col => 0, keys => '$j' },
    { name => 'curswant_dollar_to_short_back',lines => ['abc', '0123456789', 'xy', '123456'], line => 0, col => 0, keys => '$jjj' },
    { name => 'line_0_caret_dollar_g_',       lines => ['   hello world   '], line => 0, col => 6, keys => '0^$g_' },
    { name => 'g_on_spaces_only',             lines => ['    '], line => 0, col => 2, keys => 'g_' },
    { name => 'gg_and_G_with_counts',         lines => ['  l1', '  l2', '  l3', '  l4', '  l5'], line => 0, col => 0, keys => 'G2gg4Ggg' },
    { name => 'H_M_L_viewport_motions',       lines => [map { "  line$_" } 1..15], line => 0, col => 0, keys => 'MLH2H2L' },
    { name => 'paragraph_fwd_bwd',            lines => ['a1', 'a2', '', 'b1', 'b2', '', 'c1'], line => 0, col => 0, keys => '}}{' },
    { name => 'd_paragraph_fwd',              lines => ['a1', 'a2', '', 'b1'], line => 0, col => 0, keys => 'd}' },
    { name => 'd_dollar_0_caret',             lines => ['  hello world', '  alpha beta'], line => 0, col => 6, keys => 'd$jd^' },
    { name => 'd0_from_mid',                  lines => ['hello world'], line => 0, col => 5, keys => 'd0' },

    # --- 3. Character find (f/F/t/T/; ,) & bracket match (%) ---
    { name => 'f_semi_ct_comma',              lines => ['a; b; c, d; e'], line => 0, col => 0, keys => 'f;ct,X<Esc>' },
    { name => 'f_t_semi_comma_nav',           lines => ['alpha(beta[gamma]) + delta'], line => 0, col => 0, keys => 'ta;,' },
    { name => '2T_paren_df_paren',            lines => ['fn(a(b)c) end'], line => 0, col => 12, keys => '2T(df)' },
    { name => 'dt_and_df_forward',            lines => ['alpha(beta)', 'gamma(delta)'], line => 0, col => 0, keys => 'dt(j0df(' },
    { name => 'dT_and_dF_backward',           lines => ['alpha(beta)', 'gamma(delta)'], line => 0, col => 10, keys => 'dT(j$dF(' },
    { name => 'percent_nested_parens',        lines => ['a(b(c[d{e}f]g)h)i'], line => 0, col => 0, keys => '%h%l%' },
    { name => 'percent_multiline_d',          lines => ['sub foo {', '  my $x = (1 + 2);', '  return $x;', '}', 'after'], line => 0, col => 0, keys => 'd%' },
    { name => 'percent_scan_forward_on_line', lines => ['my $v = (1 + 2) + 3;'], line => 0, col => 0, keys => 'c%42<Esc>' },

    # --- 4. Text objects: iw/aw, iW/aW, quotes, pairs, ip/ap ---
    { name => 'ciw_basic',                    lines => ['foo_bar baz'], line => 0, col => 3, keys => 'ciwNEW<Esc>' },
    { name => 'daw_mid_word',                 lines => ['one two three'], line => 0, col => 5, keys => 'daw' },
    { name => 'daw_last_word',                lines => ['one two'], line => 0, col => 5, keys => 'daw' },
    { name => 'daw_only_word',                lines => ['solo'], line => 0, col => 2, keys => 'daw' },
    { name => 'daw_on_spaces',                lines => ['one   two'], line => 0, col => 4, keys => 'daw' },
    { name => 'ciW_and_daW',                  lines => ['a/b/c d-e-f g'], line => 0, col => 1, keys => 'ciWPATH<Esc>wdaW' },
    { name => 'ci_dquote_forward_jump',       lines => ['my $s = "hello world";'], line => 0, col => 0, keys => 'ci"NeoPerl<Esc>' },
    { name => 'ci_dquote_on_open',            lines => ['foo "hello" bar'], line => 0, col => 4, keys => 'ci"OK<Esc>' },
    { name => 'ci_dquote_on_close',           lines => ['foo "hello" bar'], line => 0, col => 10, keys => 'ci"OK<Esc>' },
    { name => 'ci_dquote_empty',              lines => ['foo "" bar'], line => 0, col => 0, keys => 'ci"FILL<Esc>' },
    { name => 'ci_dquote_escaped',            lines => ['x = "a \\"b\\" c";'], line => 0, col => 0, keys => 'ci"Z<Esc>' },
    { name => 'da_dquote_trailing_space',     lines => ['foo "hello"   bar'], line => 0, col => 6, keys => 'da"' },
    { name => 'da_dquote_leading_space',      lines => ['foo   "hello"'], line => 0, col => 8, keys => 'da"' },
    { name => 'ci_squote_and_backtick',       lines => ["a 'one' `two` b"], line => 0, col => 0, keys => "ci'1<Esc>ci`2<Esc>" },
    { name => 'da_paren_and_ci_paren',        lines => ['f(a, (b + c), d)'], line => 0, col => 7, keys => 'da(ci(X<Esc>' },
    { name => 'ci_paren_empty_forward',       lines => ['call() + 1'], line => 0, col => 0, keys => 'ci(42<Esc>' },
    { name => '2di_paren_nested',             lines => ['outer(inner(1, 2) + 3)'], line => 0, col => 13, keys => '2di(' },
    { name => 'di_bracket_and_angle',         lines => ['arr[1, 2] <div class="x">'], line => 0, col => 5, keys => 'di[f<ldi<' },
    { name => 'yi_brace_multiline',           lines => ['if ($ok) {', '    say 1;', '    say 2;', '}'], line => 1, col => 4, keys => 'yi{Gp' },
    { name => 'di_brace_multiline',           lines => ['if ($ok) {', '    say 1;', '    say 2;', '}'], line => 1, col => 4, keys => 'di{' },
    { name => 'da_brace_multiline',           lines => ['if ($ok) {', '    say 1;', '    say 2;', '}'], line => 1, col => 4, keys => 'da{' },
    { name => 'di_paren_multiline',           lines => ['fn(', '  x,', '  y', ')'], line => 1, col => 2, keys => 'di(' },
    { name => 'dip_middle_paragraph',         lines => ['a1', 'a2', '', 'b1', 'b2'], line => 0, col => 0, keys => 'dip' },
    { name => 'dap_middle_paragraph',         lines => ['a1', 'a2', '', 'b1', 'b2'], line => 0, col => 0, keys => 'dap' },
    { name => 'dap_last_paragraph',           lines => ['a1', '', 'b1', 'b2'], line => 2, col => 0, keys => 'dap' },

    # --- 5. Operators, case, indent, join, replace, insert/append/open ---
    { name => '3dd_linewise_delete',          lines => ['l1', 'l2', 'l3', 'l4', 'l5'], line => 1, col => 1, keys => '3dd' },
    { name => 'dd_last_line',                 lines => ['foo', 'bar'], line => 1, col => 0, keys => 'dd' },
    { name => 'dd_only_line',                 lines => ['foo'], line => 0, col => 0, keys => 'dd' },
    { name => 'dj_and_dk_linewise',           lines => ['l1', 'l2', 'l3', 'l4', 'l5'], line => 0, col => 1, keys => 'djjdk' },
    { name => 'cc_and_S',                     lines => ['  hello', '  world', '  end'], line => 0, col => 4, keys => 'ccA<Esc>jSB<Esc>' },
    { name => 'gUiw_gui_quote_gtilde',        lines => ['hello "WORLD" FooBar'], line => 0, col => 1, keys => 'gUiwgui"w~2~' },
    { name => 'guw_and_g_tilde_e_and_line',   lines => ['FOO BAR', 'FooBar', 'AbCd'], line => 0, col => 2, keys => 'guwj0lg~ejg~~' },
    { name => 'guu_and_gUU',                  lines => ['Hello World', 'foo bar'], line => 0, col => 3, keys => 'guujgUU' },
    { name => 'indent_dedent_blank_lines',    lines => ['a', '', 'b', '  c'], line => 0, col => 0, keys => '4>>4<<' },
    { name => 'indent_count_2gt_gt',          lines => ['one', 'two', 'three'], line => 0, col => 0, keys => '2>>' },
    { name => 'x_X_s_r_counts',               lines => ['abcdefghij'], line => 0, col => 2, keys => '2x2X2sZZ<Esc>2rQ' },
    { name => 'R_replace_with_backspace',     lines => ['abcdef'], line => 0, col => 1, keys => 'R12<BS>3<Esc>' },
    { name => 'J_spaces_empty_trail_paren',   lines => ['foo', '   bar', '', 'baz ', '  qux', '  )'], line => 0, col => 0, keys => 'JJJJJ' },
    { name => 'gJ_exact_join',                lines => ['foo', '   bar', '  baz'], line => 0, col => 0, keys => 'gJgJ' },
    { name => 'i_I_a_A_o_O_modes',            lines => ['  mid'], line => 0, col => 2, keys => 'i[<Esc>a]<Esc>I><Esc>A<<Esc>obelow<Esc>Oabove<Esc>' },
    { name => 'D_C_Y_shorthands',             lines => ['hello world', 'alpha beta'], line => 0, col => 5, keys => 'Dj0f C!<Esc>Yp' },

    # --- 6. Put / Paste (charwise, multiline charwise, linewise, counts) ---
    { name => 'p_P_charwise_single',          lines => ['hello world'], line => 0, col => 6, keys => 'yw0lP$p' },
    { name => 'p_charwise_on_empty_line',     lines => ['hello', ''], line => 0, col => 0, keys => 'ywjp' },
    { name => 'p_charwise_multiline',         lines => ['ab', 'cd', 'ef'], line => 0, col => 1, keys => 'vjlly0p' },
    { name => 'p_P_linewise_with_indent',     lines => ['foo', '  bar', 'baz'], line => 1, col => 3, keys => 'yypkP' },
    { name => '2p_linewise_count',            lines => ['one', 'two'], line => 0, col => 0, keys => 'yy2p' },

    # --- 7. Visual, Visual-Line, Visual-Block (<C-v>) ---
    { name => 'visual_char_d_y_U_u_tilde',    lines => ['abcdef', 'ABCDEF', 'AbCdEf'], line => 0, col => 1, keys => 'v2lUj0v2luj0v2l~' },
    { name => 'visual_line_indent_and_gv',    lines => ['a', 'b', '', 'c'], line => 0, col => 0, keys => 'vip>gv>' },
    { name => 'visual_line_dot_repeat',       lines => ['a', 'b', '', 'c', 'd'], line => 0, col => 0, keys => 'vip>.' },
    { name => 'visual_o_swap_anchor',         lines => ['0123456789'], line => 0, col => 4, keys => 'v2lo2hd' },
    { name => 'vblock_I_comment_prefix',      lines => ['foo', 'bar', 'baz'], line => 0, col => 0, keys => '<C-v>2jI// <Esc>' },
    { name => 'vblock_A_ragged_dollar',       lines => ['aa', 'bbbb', 'c'], line => 0, col => 0, keys => '<C-v>2j$A;<Esc>' },
    { name => 'vblock_A_fixed_column',        lines => ['aaaa', 'bbbb', 'cccc'], line => 0, col => 1, keys => '<C-v>2jlA!<Esc>' },
    { name => 'vblock_d_column_slice',        lines => ['abcde', '12345', 'vwxyz'], line => 0, col => 1, keys => '<C-v>2j2ld' },
    { name => 'vblock_c_column_replace',      lines => ['abcde', '12345', 'vwxyz'], line => 0, col => 1, keys => '<C-v>2jlcXY<Esc>' },
    { name => 'vblock_y_and_p',               lines => ['abc', '123', 'xyz'], line => 0, col => 0, keys => '<C-v>2jly$p' },

    # --- 8. Registers, Marks, Macros, Dot-Repeat, Grouped Undo/Redo ---
    { name => 'reg_append_charwise',          lines => ['one two three'], line => 0, col => 0, keys => '"ayiwW"Ayiw$"ap' },
    { name => 'reg_append_linewise',          lines => ['l1', 'l2', 'l3', 'l4'], line => 0, col => 0, keys => '"a2dd"AyyG"ap' },
    { name => 'reg_blackhole_preserves',      lines => ['one', 'two', 'three'], line => 0, col => 0, keys => 'yyj"_ddp' },
    { name => 'reg_yank_0_vs_delete_1',       lines => ['first', 'second', 'third'], line => 0, col => 0, keys => 'yyjdd"0p"1P' },
    { name => 'marks_backtick_and_quote',     lines => ['line0', '  line1 target', 'line2'], line => 1, col => 8, keys => "magg0`aA!<Esc>gg0'aI><Esc>" },
    { name => 'macro_qa_0w_tilde_jq_4at_a',   lines => ['one two', 'three four', 'five six', 'seven eight', 'nine ten'], line => 0, col => 0, keys => 'qa0w~jq4@a' },
    { name => 'macro_at_at_repeat',           lines => ['a', 'b', 'c', 'd'], line => 0, col => 0, keys => 'qaI- <Esc>jq@a2@@' },
    { name => 'dot_2dw_repeat',               lines => ['a b c d e f'], line => 0, col => 0, keys => '2dw.' },
    { name => 'dot_dd_count_override_2',      lines => ['l1', 'l2', 'l3', 'l4', 'l5'], line => 0, col => 0, keys => 'dd2.' },
    { name => 'dot_ciw_multi_line',           lines => ['apple pie', 'banana split', 'cherry tart'], line => 0, col => 0, keys => 'ciwFRUIT<Esc>j0.j0.' },
    { name => 'undo_redo_grouped_insert',     lines => ['base'], line => 0, col => 0, keys => 'A-v1<Esc>A-v2<Esc>u' },
    { name => 'undo_then_ctrl_r_redo',        lines => ['base'], line => 0, col => 0, keys => 'A-v1<Esc>A-v2<Esc>uu<C-r>' },
    { name => 'undo_dd_and_redo',             lines => ['one', 'two', 'three'], line => 1, col => 0, keys => 'ddu<C-r>u' },
    { name => 'undo_vblock_I_single_step',    lines => ['foo', 'bar', 'baz'], line => 0, col => 0, keys => '<C-v>2jI# <Esc>u' },
);

# Generate 60 deterministic seeded-random fuzzed editing transcripts
my $rng = make_rng(20261121);
my @fuzz_docs = (
    ['alpha beta gamma', 'delta_1 epsilon-2 zeta', '', 'foo(bar, "baz qux")', '  indented line   '],
    ['sub calc {', '    my ($a, $b) = @_;', '    return ($a + $b) * 2;', '}', 'my $r = calc(3, 4);'],
    ['one two three four', 'five six seven eight', 'nine ten eleven twelve', 'thirteen fourteen'],
    ['a "first" b "second" c', "x 'single' y `tick` z", 'm[1, 2, 3] {k: v} <tag>'],
    ['0123456789', 'ab', '', 'ABCDEFGHIJ', 'klm nop qrs'],
);
my @fuzz_atoms = (
    'h', 'j', 'k', 'l', '2l', '2j', 'k',
    'w', 'W', 'b', 'B', 'e', 'E', 'ge',
    '0', '^', '$', 'g_', 'gg', 'G', '{', '}',
    'x', 'X', '~', '2~', 'dw', 'cwX<Esc>', 'ciwW<Esc>', 'daw',
    'dd', 'yy', 'p', 'P', '>>', '<<', 'J', 'gJ',
    'guw', 'gUw', 'g~w', 'r*', 'i+<Esc>', 'a-<Esc>', 'A!<Esc>', 'I><Esc>',
    'oNEW<Esc>', 'OUP<Esc>', 'vld', 'Vj>', 'f ', 'F ', 't(', '%',
    'ci"X<Esc>', 'di(', 'di{', 'u', '<C-r>', '.',
);

my %is_mutating_atom = map { $_ => 1 } (
    'x', 'X', '~', '2~', 'dw', 'cwX<Esc>', 'ciwW<Esc>', 'daw',
    'dd', '>>', '<<', 'J', 'gJ', 'guw', 'gUw', 'g~w', 'r*',
    'i+<Esc>', 'a-<Esc>', 'A!<Esc>', 'I><Esc>', 'oNEW<Esc>', 'OUP<Esc>',
    'vld', 'Vj>',
);

my @fuzzed;
for my $fi (1 .. 60) {
    my $doc = [ @{ $fuzz_docs[ $rng->(scalar @fuzz_docs) ] } ];
    my $nops = 4 + $rng->(7);
    my $seq = '';
    my $did_mutate = 0;
    for (1 .. $nops) {
        my $atom = $fuzz_atoms[ $rng->(scalar @fuzz_atoms) ];
        # Vim cannot reset '.' between batch cases, so only emit '.' after a local edit
        if ($atom eq '.' && !$did_mutate) {
            $atom = 'dw';
        }
        $did_mutate = 1 if $is_mutating_atom{$atom};
        $seq .= $atom;
    }
    my $start_l = $rng->(scalar @$doc);
    my $llen = length($doc->[$start_l]);
    my $start_c = $llen > 0 ? $rng->($llen) : 0;
    push @fuzzed, {
        name  => sprintf('fuzz_%02d', $fi),
        lines => $doc,
        line  => $start_l,
        col   => $start_c,
        keys  => $seq,
    };
}

my @all_cases = (@curated, @fuzzed);
my ($vim_bin, $vim_ver) = find_real_vim();

if ($vim_bin) {
    diag("Running LIVE differential oracle against $vim_bin (Vim $vim_ver) across " . scalar(@all_cases) . " transcripts");
    my $expected = run_vim_oracle_batch($vim_bin, \@all_cases);
    is(scalar(@$expected), scalar(@all_cases), 'live vim oracle returned result for every transcript');

    for my $i (0 .. $#all_cases) {
        my $c = $all_cases[$i];
        my ($exp_text, $exp_l, $exp_c) = @{ $expected->[$i] };

        my $init_text = join("\n", @{ $c->{lines} });
        my $buf = NeoPerl::Core::Buffer->from_string($init_text);
        my $vim = NeoPerl::Core::VimEngine->new($buf, {
            shiftwidth => 4,
            tabstop    => 4,
            expandtab  => 1,
            win_height => 23,
            scroll_top => 0,
        });
        $vim->set_cursor($c->{line}, $c->{col});
        $vim->feed_keys($c->{keys});

        my $got_text = $buf->to_string();
        my ($got_l, $got_c) = $vim->cursor();

        my $ok_all = ($got_text eq $exp_text && $got_l == $exp_l && $got_c == $exp_c);
        ok($ok_all, sprintf('[%03d] %s (keys=%s)', $i + 1, $c->{name}, $c->{keys}))
            or diag(sprintf(
                "MISMATCH in %s (keys=%s)\n  EXP text: %s\n  GOT text: %s\n  EXP cur:  (%d,%d)\n  GOT cur:  (%d,%d)",
                $c->{name}, $c->{keys},
                encode_json([$exp_text]), encode_json([$got_text]),
                $exp_l, $exp_c, $got_l, $got_c
            ));
    }

    # Verify key transcripts ALSO match byte-for-byte + exact cursor through full NeoPerl::Editor / Modal.pm
    my @editor_checks = (
        $curated[0],  # cw_excludes_trailing_space
        $curated[1],  # dw_includes_trailing_space
        $curated[4],  # cw_single_char_word
        $curated[5],  # cw_on_whitespace
        $curated[24], # curswant_sticky_across_short
        $curated[26], # curswant_dollar_sticky_eol
        $curated[36], # f_semi_ct_comma
        $curated[38], # 2T_paren_df_paren
        $curated[48], # daw_on_spaces
        $curated[50], # ci_dquote_forward_jump
        $curated[55], # da_dquote_trailing_space
        $curated[63], # di_brace_multiline
        $curated[80], # R_replace_with_backspace
        $curated[81], # J_spaces_empty_trail_paren
        $curated[94], # vblock_I_comment_prefix
        $curated[95], # vblock_A_ragged_dollar
        $curated[100],# reg_append_charwise
        $curated[105],# macro_qa_0w_tilde_jq_4at_a
    );
    my $ed_exp = run_vim_oracle_batch($vim_bin, \@editor_checks);
    for my $i (0 .. $#editor_checks) {
        my $c = $editor_checks[$i];
        my ($exp_text, $exp_l, $exp_c) = @{ $ed_exp->[$i] };
        my $ed  = NeoPerl::Editor->new();
        my $buf = $ed->current_buffer;
        $buf->set_text(join("\n", @{ $c->{lines} }));
        $ed->current_window->set_cursor($c->{line}, $c->{col});
        $ed->feed_keys($c->{keys});
        my $got_text = $buf->get_text;
        my ($got_l, $got_c) = $ed->current_window->get_cursor;
        my $ok_ed = ($got_text eq $exp_text && $got_l == $exp_l && $got_c == $exp_c);
        ok($ok_ed, "NeoPerl::Editor parity vs live vim: $c->{name}")
            or diag(sprintf(
                "EDITOR MISMATCH in %s\n  EXP: (%d,%d) %s\n  GOT: (%d,%d) %s",
                $c->{name}, $exp_l, $exp_c, encode_json([$exp_text]),
                $got_l, $got_c, encode_json([$got_text])
            ));
    }
}
else {
    diag("vim not found on host; running built-in golden snapshot fallback");
    my @golden = (
        [ ['one two three'], 0, 0, 'cwFOO<Esc>', 'FOO two three', 0, 2 ],
        [ ['one two three'], 0, 0, 'dw',         'two three',     0, 0 ],
        [ ['foo "hello" bar'], 0, 0, 'ci"X<Esc>','foo "X" bar',   0, 5 ],
        [ ['foo', 'bar', 'baz'], 0, 0, '<C-v>2jI// <Esc>', "// foo\n// bar\n// baz", 0, 0 ],
        [ ['one two three'], 0, 0, '"ayiwW"Ayiw$"ap', 'one two threeonetwo', 0, 18 ],
        [ ['a b c d e f'], 0, 0, '2dw.', 'e f', 0, 0 ],
        [ ['l1', 'l2', 'l3', 'l4', 'l5'], 0, 0, 'dd2.', "l4\nl5", 0, 0 ],
        [ ['0123456789', 'ab', 'ABCDEFGHIJ'], 0, 7, 'jj', "0123456789\nab\nABCDEFGHIJ", 2, 7 ],
        [ ['foo', '  )'], 0, 0, 'J', 'foo)', 0, 3 ],
        [ ['abcdef'], 0, 1, 'R12<BS>3<Esc>', 'a13def', 0, 2 ],
    );
    for my $g (@golden) {
        my ($lines, $sl, $sc, $keys, $exp_t, $exp_l, $exp_c) = @$g;
        my $buf = NeoPerl::Core::Buffer->from_string(join("\n", @$lines));
        my $vim = NeoPerl::Core::VimEngine->new($buf);
        $vim->set_cursor($sl, $sc);
        $vim->feed_keys($keys);
        is($buf->to_string(), $exp_t, "golden text: $keys");
        is_deeply([$vim->cursor()], [$exp_l, $exp_c], "golden cursor: $keys");
    }
}

# --- Direct VimEngine XS API & Branching Undo Tree (g-/g+) & Reset Tests ---
{
    my $buf = NeoPerl::Core::Buffer->from_string("base");
    my $vim = NeoPerl::Core::VimEngine->new($buf);
    is($vim->mode(), 'NORMAL', 'VimEngine starts in NORMAL');
    is_deeply([$vim->cursor()], [0, 0], 'VimEngine initial cursor (0,0)');
    ok(!defined $vim->visual_range(), 'visual_range undef in NORMAL');

    # Branching undo tree via g- / g+
    $vim->feed_keys('A-v1<Esc>');
    is($buf->to_string(), 'base-v1', 'branch 1 edit');
    $vim->feed_keys('u');
    is($buf->to_string(), 'base', 'u returns to base');
    $vim->feed_keys('A-v2<Esc>');
    is($buf->to_string(), 'base-v2', 'branch 2 edit');
    $vim->feed_keys('g-');
    is($buf->to_string(), 'base-v1', 'g- visits alternate undo branch base-v1');
    $vim->feed_keys('g+');
    is($buf->to_string(), 'base-v2', 'g+ returns to base-v2');

    # Visual range & state_info
    $vim->feed_keys('0v3l');
    is($vim->mode(), 'VISUAL', 'mode is VISUAL');
    my $vr = $vim->visual_range();
    is($vr->{mode}, 'VISUAL', 'visual_range mode');
    is($vr->{start_col}, 0, 'visual_range start_col');
    is($vr->{end_col}, 3, 'visual_range end_col');
    my $st = $vim->state_info();
    is($st->{mode}, 'VISUAL', 'state_info mode');
    is($st->{col}, 3, 'state_info col');
    is($st->{can_undo}, 1, 'state_info can_undo');

    # Register & reset
    $vim->feed_keys('"ay');
    is($vim->get_register('a')->{text}, 'base', 'get_register a captured yanked visual');
    $vim->reset();
    is($vim->mode(), 'NORMAL', 'reset restores NORMAL');
    is($vim->get_register('a')->{text}, '', 'reset clears registers');
}

done_testing();
