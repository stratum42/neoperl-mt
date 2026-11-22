use strict;
use warnings;
use utf8;

use FindBin ();
use File::Spec ();
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
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
        [ $ENV{NEOPERL_DBD_SQLITE_DIR}, 'dbd-sqlite-mt', [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_DBI_DIR},        'dbi-mt',        [ 'blib/arch', 'blib/lib', 'lib' ] ],
        [ $ENV{NEOPERL_MOJO_DIR},       'mojolicious-mt',[ 'xs/blib/arch', 'xs/blib/lib', 'lib' ] ],
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

use NeoPerl::Core qw(:tokens detect_language token_name);
use NeoPerl::Plugin::Themes;
use NeoPerl::Editor;
use NeoPerl::UI::TUI;

# ---------------------------------------------------------------------------
# 1. AIX Amber Phosphor Default Theme Across Themes, Editor, and TUI
# ---------------------------------------------------------------------------
{
    ok(NeoPerl::Plugin::Themes->exists_theme('aix_amber'), 'aix_amber theme registered');
    my @themes = NeoPerl::Plugin::Themes->list;
    is_deeply(\@themes, [qw(aix_amber catppuccin gruvbox kanagawa tokyonight)],
        'all 5 built-in themes listed with aix_amber included');

    my $def = NeoPerl::Plugin::Themes->get();
    is($def->{name},  'aix_amber',          'Themes->get() defaults to aix_amber');
    is($def->{label}, 'AIX Amber Phosphor', 'aix_amber label matches AIX Amber Phosphor');
    is($def->{bg},    '#000000',            'aix_amber bg is pure #000000 black');
    is($def->{fg},    '#ffb000',            'aix_amber fg is #ffb000 P3 amber phosphor');
    is($def->{syntax}{keyword},  '#ffd873', 'aix_amber syntax keyword is warm bright gold');
    is($def->{syntax}{comment},  '#7a4f00', 'aix_amber syntax comment is deep amber');
    is($def->{syntax}{string},   '#e6a84c', 'aix_amber syntax string is warm amber copper');
    is($def->{syntax}{function}, '#ffe49e', 'aix_amber syntax function is pale phosphor gold');

    my $ed = NeoPerl::Editor->new(cwd => $ROOT, load_config => 0);
    is($ed->get_option('colorscheme'), 'aix_amber', 'Editor defaults colorscheme to aix_amber');
    is($ed->theme->{bg}, '#000000', 'Editor default theme bg is #000000');
    is($ed->theme->{fg}, '#ffb000', 'Editor default theme fg is #ffb000');

    # :colorscheme preserves other themes and returns cleanly to aix_amber
    $ed->exec_command('colorscheme tokyonight');
    is($ed->theme->{name}, 'tokyonight', ':colorscheme tokyonight works');
    $ed->exec_command('colorscheme aix_amber');
    is($ed->theme->{name}, 'aix_amber', ':colorscheme aix_amber restores default');

    # TUI emits pure black (0,0,0) background & P3 amber (255,176,0) foreground 24-bit ANSI
    $ed->current_buffer->set_text("SELECT 1 FROM SYSIBM.SYSDUMMY1;\n");
    $ed->current_buffer->filetype('sql');
    my $tui = NeoPerl::UI::TUI->new(editor => $ed, width => 100, height => 24, headless => 1);
    my $ansi = $tui->render_frame();
    like($ansi, qr/\e\[48;2;0;0;0m/,     'TUI emits pure black #000000 ANSI background');
    like($ansi, qr/\e\[38;2;255;176;0m/, 'TUI emits #ffb000 amber phosphor ANSI foreground');
    $tui->shutdown();
}

# ---------------------------------------------------------------------------
# 2. Expanded 27-Language C11 Syntax Lexers & Symbol Extraction
# ---------------------------------------------------------------------------
{
    my $langs = NeoPerl::Core::Syntax::supported_languages();
    is(scalar(@$langs), 27, 'C11 syntax engine exposes 27 languages');

    my %new_exts = (
        'query.sql'         => 'sql',
        'proc.spl'          => 'sql',
        'schema.ddl'        => 'sql',
        'grants.dcl'        => 'sql',
        'NNPASVC.hlasm'     => 'hlasm',
        'csect.hla'         => 'hlasm',
        'mainframe.mlc'     => 'hlasm',
        'dsect.mac'         => 'hlasm',
        'vec_power.s'       => 'asm',
        'telum_nnpa.S'      => 'asm',
        'kernel_x64.asm'    => 'asm',
        'order.rpgle'       => 'rpgile',
        'custsql.sqlrpgle'  => 'rpgile',
        'legacy.rpg'        => 'rpgile',
        'protos.rpginc'     => 'rpgile',
        'ACCTPOST.cbl'      => 'cobol',
        'LEDGER.cob'        => 'cobol',
        'BATCH.cobol'       => 'cobol',
        'DCLACCT.cpy'       => 'cobol',
        'xe_gemm.cl'        => 'sycl',
        'dpas.sycl'         => 'sycl',
        'mfma_mi300.hip'    => 'hip',
        'gemm.cu'           => 'hip',
        'common.cuh'        => 'hip',
        'pbr.glsl'          => 'glsl',
        'tri.vert'          => 'glsl',
        'lit.frag'          => 'glsl',
        'cull.comp'         => 'glsl',
        'kernel.spvasm'     => 'glsl',
        'simd_gemm.metal'   => 'metal',
    );
    for my $fn (sort keys %new_exts) {
        is(detect_language($fn), $new_exts{$fn}, "detect_language($fn) => $new_exts{$fn}");
    }

    my $has_tok_type = sub {
        my ($toks, $want) = @_;
        for (my $i = 0; $i + 2 < @$toks; $i += 3) {
            return 1 if $toks->[$i + 2] == $want;
        }
        return 0;
    };

    # 2a. SQL / SPL
    {
        my $sql_src = join("\n",
            "-- Db2 12.1.2 VECTOR & Informix SPL",
            "/* block",
            "   comment */",
            "CREATE TABLE qsys2.orders (id INTEGER, emb VECTOR(768, REAL));",
            "CREATE OR REPLACE PROCEDURE post_order(p_id INT)",
            "SELECT id FROM qsys2.orders WHERE id = :host_id WITH UR;",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($sql_src);
        my $syn = NeoPerl::Core::Syntax->new('sql');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        is($rows->[0][2], TOK_COMMENT, 'SQL -- line comment lexed as TOK_COMMENT');
        is($syn->end_state(1), 1, 'SQL /* opens multiline block comment state');
        is($syn->end_state(2), 0, 'SQL */ closes block comment state');
        ok($has_tok_type->($rows->[3], TOK_KEYWORD), 'SQL CREATE/TABLE lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[3], TOK_TYPE),    'SQL INTEGER/VECTOR lexed as TOK_TYPE');
        ok($has_tok_type->($rows->[5], TOK_VAR),     'SQL :host_id lexed as TOK_VAR');

        my $syms = $syn->extract_symbols($buf);
        is_deeply(
            [ map { [ $_->{name}, $_->{kind} ] } @$syms ],
            [ [ 'qsys2.orders', 'table' ], [ 'post_order', 'procedure' ] ],
            'SQL/SPL symbol extraction finds table and procedure',
        );
    }

    # 2b. HLASM (z/Architecture through z17 Telum II)
    {
        my $hlasm_src = join("\n",
            "* IBM z17 Telum II NNPA Service",
            "NNPASVC  CSECT",
            "         STMG  R14,R12,8(R13)        Save caller registers",
            "         NNPA                        Invoke Telum II NNPA",
            "TNSRBLK  DSECT",
            "TNSREYE  DC    CL8'TNSRBLK '         Eyecatcher",
            "TNSRLEN  EQU   *-TNSRBLK",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($hlasm_src);
        my $syn = NeoPerl::Core::Syntax->new('hlasm');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        is($rows->[0][2], TOK_COMMENT, 'HLASM col-1 * comment lexed as TOK_COMMENT');
        ok($has_tok_type->($rows->[1], TOK_TAG),     'HLASM col-1 label NNPASVC lexed as TOK_TAG');
        ok($has_tok_type->($rows->[1], TOK_PREPROC), 'HLASM CSECT directive lexed as TOK_PREPROC');
        ok($has_tok_type->($rows->[2], TOK_KEYWORD), 'HLASM STMG opcode lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[2], TOK_VAR),     'HLASM R14/R12/R13 registers lexed as TOK_VAR');
        ok($has_tok_type->($rows->[2], TOK_COMMENT), 'HLASM inline remark lexed as TOK_COMMENT');
        ok($has_tok_type->($rows->[3], TOK_KEYWORD), 'HLASM NNPA Telum II opcode lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[5], TOK_STRING),  'HLASM DC string literal lexed as TOK_STRING');

        my $syms = $syn->extract_symbols($buf);
        is_deeply(
            [ map { [ $_->{name}, $_->{kind} ] } @$syms ],
            [ [ 'NNPASVC', 'csect' ], [ 'TNSRBLK', 'dsect' ], [ 'TNSREYE', 'field' ], [ 'TNSRLEN', 'equ' ] ],
            'HLASM symbol extraction finds csect, dsect, field, and equ',
        );
    }

    # 2c. Multi-ISA Assembly (POWER8+/10, amd64, arm64, s390x Telum II)
    {
        my $asm_src = join("\n",
            ".text",
            "dot_power10_mma:",
            "    xvf32gerpp acc0, vs32, vs33  # POWER10 MMA outer product",
            "    vfmadd231ps %ymm0, %ymm1, %ymm2 ; amd64 FMA",
            "    fmla v0.4s, v1.4s, v2.4s     // arm64 NEON",
            "telum2_nnpa:",
            "    vfmasb %v4, %v0, %v1, %v2",
            "    nnpa",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($asm_src);
        my $syn = NeoPerl::Core::Syntax->new('asm');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        ok($has_tok_type->($rows->[0], TOK_PREPROC), 'ASM .text directive lexed as TOK_PREPROC');
        ok($has_tok_type->($rows->[1], TOK_TAG),     'ASM label lexed as TOK_TAG');
        ok($has_tok_type->($rows->[2], TOK_KEYWORD), 'ASM POWER10 xvf32gerpp lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[2], TOK_VAR),     'ASM POWER registers acc0/vs32 lexed as TOK_VAR');
        ok($has_tok_type->($rows->[2], TOK_COMMENT), 'ASM # comment lexed as TOK_COMMENT');
        ok($has_tok_type->($rows->[3], TOK_KEYWORD), 'ASM amd64 vfmadd231ps lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[4], TOK_KEYWORD), 'ASM arm64 fmla lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[7], TOK_KEYWORD), 'ASM s390x Telum II nnpa lexed as TOK_KEYWORD');

        my $syms = $syn->extract_symbols($buf);
        is_deeply(
            [ map { $_->{name} } @$syms ],
            [ 'dot_power10_mma', 'telum2_nnpa' ],
            'Multi-ISA ASM symbol extraction finds labels',
        );
    }

    # 2d. RPGILE (**FREE + fixed-format)
    {
        my $rpg_src = join("\n",
            "**FREE",
            "      * Legacy fixed-format comment",
            "CTL-OPT DFTACTGRP(*NO) ACTGRP(*CALLER);",
            "DCL-DS order_t QUALIFIED TEMPLATE;",
            "  amount PACKED(11:2);",
            "END-DS;",
            "DCL-PROC calcTotal EXPORT;",
            "  name = %TRIM(rawName);",
            "  *INLR = *ON;",
            "END-PROC;",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($rpg_src);
        my $syn = NeoPerl::Core::Syntax->new('rpgile');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        ok($has_tok_type->($rows->[0], TOK_PREPROC),  'RPGILE **FREE lexed as TOK_PREPROC');
        ok($has_tok_type->($rows->[1], TOK_COMMENT),  'RPGILE fixed col-7 * comment lexed as TOK_COMMENT');
        ok($has_tok_type->($rows->[2], TOK_KEYWORD),  'RPGILE CTL-OPT lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[2], TOK_CONSTANT), 'RPGILE *NO/*CALLER lexed as TOK_CONSTANT');
        ok($has_tok_type->($rows->[4], TOK_TYPE),     'RPGILE PACKED lexed as TOK_TYPE');
        ok($has_tok_type->($rows->[7], TOK_FUNC),     'RPGILE %TRIM BIF lexed as TOK_FUNC');

        my $syms = $syn->extract_symbols($buf);
        is_deeply(
            [ map { [ $_->{name}, $_->{kind} ] } @$syms ],
            [ [ 'order_t', 'ds' ], [ 'calcTotal', 'proc' ] ],
            'RPGILE symbol extraction finds DCL-DS and DCL-PROC',
        );
    }

    # 2e. COBOL
    {
        my $cob_src = join("\n",
            "       IDENTIFICATION DIVISION.",
            "       PROGRAM-ID. ACCTPOST.",
            "      * Db2 for z/OS Ledger Posting",
            "       DATA DIVISION.",
            "       WORKING-STORAGE SECTION.",
            "       01  DCL-ACCT.",
            "           10 BAL-AMT PIC S9(9)V99 COMP-3.",
            "       PROCEDURE DIVISION.",
            "       MAIN-PARA.",
            "           EXEC SQL SELECT BAL INTO :BAL-AMT FROM T END-EXEC.",
            "           EXEC CICS SYNCPOINT END-EXEC.",
            "           STOP RUN.",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($cob_src);
        my $syn = NeoPerl::Core::Syntax->new('cobol');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        ok($has_tok_type->($rows->[0], TOK_KEYWORD), 'COBOL IDENTIFICATION DIVISION lexed as TOK_KEYWORD');
        is($rows->[2][2], TOK_COMMENT, 'COBOL col-7 * comment lexed as TOK_COMMENT');
        ok($has_tok_type->($rows->[6], TOK_TYPE),    'COBOL PIC S9(9)V99 COMP-3 lexed as TOK_TYPE');
        ok($has_tok_type->($rows->[9], TOK_PREPROC), 'COBOL EXEC SQL END-EXEC lexed as TOK_PREPROC');
        ok($has_tok_type->($rows->[9], TOK_VAR),     'COBOL :BAL-AMT host var lexed as TOK_VAR');
        ok($has_tok_type->($rows->[10], TOK_PREPROC),'COBOL EXEC CICS lexed as TOK_PREPROC');

        my $syms = $syn->extract_symbols($buf);
        my %sym_map = map { $_->{name} => $_->{kind} } @$syms;
        is($sym_map{ACCTPOST},        'program',   'COBOL symbol: PROGRAM-ID');
        is($sym_map{IDENTIFICATION},  'division',  'COBOL symbol: DIVISION');
        is($sym_map{'WORKING-STORAGE'}, 'section', 'COBOL symbol: SECTION');
        is($sym_map{'DCL-ACCT'},      'record',    'COBOL symbol: 01 record');
        is($sym_map{'MAIN-PARA'},     'paragraph', 'COBOL symbol: paragraph');
    }

    # 2f. SYCL / OpenCL
    {
        my $sycl_src = join("\n",
            "#pragma OPENCL EXTENSION cl_khr_fp16 : enable",
            "__kernel __attribute__((intel_reqd_sub_group_size(16)))",
            "__kernel void xe_gemm(__global half4 *a, __global float4 *c) {",
            "    barrier(CLK_LOCAL_MEM_FENCE);",
            "}",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($sycl_src);
        my $syn = NeoPerl::Core::Syntax->new('sycl');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        ok($has_tok_type->($rows->[0], TOK_PREPROC), 'SYCL #pragma lexed as TOK_PREPROC');
        ok($has_tok_type->($rows->[2], TOK_KEYWORD), 'SYCL __kernel/__global lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[2], TOK_TYPE),    'SYCL half4/float4 lexed as TOK_TYPE');
        my $syms = $syn->extract_symbols($buf);
        is_deeply([ map { [ $_->{name}, $_->{kind} ] } @$syms ], [ [ 'xe_gemm', 'kernel' ] ],
            'SYCL symbol extraction finds kernel');
    }

    # 2g. HIP (AMD ROCm)
    {
        my $hip_src = join("\n",
            "#include <hip/hip_runtime.h>",
            "__global__ __launch_bounds__(256) void cdna_mfma(const hip_bfloat16 *a, float *c) {",
            "    int lane = threadIdx.x % warpSize;",
            "    __syncthreads();",
            "}",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($hip_src);
        my $syn = NeoPerl::Core::Syntax->new('hip');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        ok($has_tok_type->($rows->[1], TOK_KEYWORD), 'HIP __global__/__launch_bounds__ lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[1], TOK_TYPE),    'HIP hip_bfloat16 lexed as TOK_TYPE');
        ok($has_tok_type->($rows->[2], TOK_VAR),     'HIP threadIdx/warpSize lexed as TOK_VAR');
        my $syms = $syn->extract_symbols($buf);
        is_deeply([ map { [ $_->{name}, $_->{kind} ] } @$syms ], [ [ 'cdna_mfma', 'kernel' ] ],
            'HIP symbol extraction skips __launch_bounds__(256) and finds kernel');
    }

    # 2h. GLSL / SPIR-V
    {
        my $glsl_src = join("\n",
            "#version 460",
            "; SPIR-V comment line",
            "layout(std140, binding = 0) uniform FrameUBO { vec3 camPos; mat4 viewProj; };",
            "void main() { uint idx = gl_GlobalInvocationID.x; }",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($glsl_src);
        my $syn = NeoPerl::Core::Syntax->new('glsl');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        ok($has_tok_type->($rows->[0], TOK_PREPROC), 'GLSL #version lexed as TOK_PREPROC');
        is($rows->[1][2], TOK_COMMENT,            'SPIR-V leading ; comment lexed as TOK_COMMENT');
        ok($has_tok_type->($rows->[2], TOK_KEYWORD), 'GLSL layout/std140/uniform lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[2], TOK_TYPE),    'GLSL vec3/mat4 lexed as TOK_TYPE');
        ok($has_tok_type->($rows->[3], TOK_VAR),     'GLSL gl_GlobalInvocationID lexed as TOK_VAR');
        my $syms = $syn->extract_symbols($buf);
        is_deeply(
            [ map { [ $_->{name}, $_->{kind} ] } @$syms ],
            [ [ 'FrameUBO', 'uniform' ], [ 'main', 'function' ] ],
            'GLSL symbol extraction finds uniform block and main',
        );
    }

    # 2i. Metal Shading Language (MSL)
    {
        my $metal_src = join("\n",
            "#include <metal_stdlib>",
            "struct VertexABI { packed_float3 pos; half2 uv; };",
            "kernel void gemm_simd8x8(device const half *A [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {",
            "    simdgroup_half8x8 ma;",
            "    threadgroup_barrier(mem_flags::mem_threadgroup);",
            "}",
            "",
        );
        my $buf = NeoPerl::Core::Buffer->from_string($metal_src);
        my $syn = NeoPerl::Core::Syntax->new('metal');
        my $rows = $syn->tokenize_range($buf, 0, $buf->line_count);
        ok($has_tok_type->($rows->[1], TOK_TYPE),    'Metal packed_float3/half2 lexed as TOK_TYPE');
        ok($has_tok_type->($rows->[2], TOK_KEYWORD), 'Metal kernel/device lexed as TOK_KEYWORD');
        ok($has_tok_type->($rows->[2], TOK_TAG),     'Metal [[buffer(0)]] attribute lexed as TOK_TAG');
        ok($has_tok_type->($rows->[3], TOK_TYPE),    'Metal simdgroup_half8x8 lexed as TOK_TYPE');
        my $syms = $syn->extract_symbols($buf);
        is_deeply(
            [ map { [ $_->{name}, $_->{kind} ] } @$syms ],
            [ [ 'VertexABI', 'struct' ], [ 'gemm_simd8x8', 'kernel' ] ],
            'Metal MSL symbol extraction finds struct and kernel',
        );
    }
}

# ---------------------------------------------------------------------------
# 3. GPU IBM Plex Defaults + Retina Metal Black-and-Amber Pixel Verification
# ---------------------------------------------------------------------------
SKIP: {
    skip 'Tcl::Tk::MT not available on this Perl build', 15
        unless eval { require Tcl::Tk::MT; require Tcl::Tk::MT::Canvas; require NeoPerl::MT; 1 };

    my $tmpdir = tempdir(CLEANUP => 1);
    my $app = NeoPerl::MT->new(
        cwd         => $ROOT,
        ui          => 'gpu',
        backend     => 'auto',
        headless    => 1,
        width       => 1280,
        height      => 720,
        agy_mock    => 1,
        load_config => 0,
    );

    is($app->editor->theme->{name}, 'aix_amber',     'NeoPerl::MT GPU defaults to aix_amber theme');
    is($app->ui->font_family,       'IBM Plex Mono', 'UI::GPU defaults code font to IBM Plex Mono');
    is($app->ui->ui_font_family,    'IBM Plex Sans', 'UI::GPU defaults UI font to IBM Plex Sans');

    # Render primary AIX Amber scene + 2 domain scenes and verify black & amber pixels
    for my $scene (qw(chat_diff aix_mainframe_db aix_gpu_asm)) {
        $app->setup_demo(scene => $scene);
        my $png_path = File::Spec->catfile($tmpdir, "aix_${scene}.png");
        my $res = $app->export_screenshot($png_path);
        ok($res->{ok} && -f $png_path && -s $png_path > 5000,
            "scene '$scene': Retina PNG exported (" . (-s $png_path || 0) . ' bytes)');

        my $rgba = $app->ui->canvas->readback_rgba();
        my $black_px = 0;
        my $amber_px = 0;
        my $step = 16; # sample every 4th pixel for fast, deterministic coverage
        my $len  = length($rgba);
        for (my $off = 0; $off + 3 < $len; $off += $step) {
            my ($r, $g, $b) = unpack('C3', substr($rgba, $off, 3));
            if ($r <= 12 && $g <= 10 && $b <= 6) {
                $black_px++;
            }
            elsif ($r >= 160 && $g >= 80 && $b <= 120 && $r > $g && $g > $b) {
                $amber_px++;
            }
        }
        cmp_ok($black_px, '>', 50000, "scene '$scene': pure black background dominates ($black_px sampled px)");
        cmp_ok($amber_px, '>', 1500,  "scene '$scene': P3 amber phosphor pixels present ($amber_px sampled px)");
    }

    # On macOS with IBM Plex installed, verify genuine IBM Plex glyph distinction vs Menlo/HelveticaNeue
    my $home = $ENV{HOME} || '';
    my $have_plex = ($^O eq 'darwin'
        && -f File::Spec->catfile($home, 'Library', 'Fonts', 'IBMPlexMono-Regular.otf')
        && -f File::Spec->catfile($home, 'Library', 'Fonts', 'IBMPlexSans-Regular.otf')) ? 1 : 0;

    SKIP: {
        skip 'IBM Plex font files not installed in ~/Library/Fonts', 3 unless $have_plex;

        my $render_probe = sub {
            my ($fam) = @_;
            my $c = Tcl::Tk::MT::Canvas->new(undef,
                '-width' => 280, '-height' => 48, '-bg' => '#000000',
                '-backend' => 'metal', '-headless' => 1,
            );
            $c->createText(8, 8, '-text' => '0123456789 IBM Plex QWg', '-fill' => '#ffb000',
                '-font' => [ $fam, 16 ], '-anchor' => 'nw');
            $c->render();
            my $px = $c->readback_rgba();
            $c->destroy();
            return $px;
        };

        my $px_pm = $render_probe->('IBM Plex Mono');
        my $px_mn = $render_probe->('Menlo');
        my $px_ps = $render_probe->('IBM Plex Sans');
        my $px_hn = $render_probe->('HelveticaNeue');

        isnt($px_pm, $px_mn, 'IBM Plex Mono renders genuine Plex glyphs distinct from Menlo');
        isnt($px_ps, $px_hn, 'IBM Plex Sans renders genuine Plex glyphs distinct from HelveticaNeue');
        isnt($px_pm, $px_ps, 'IBM Plex Mono and IBM Plex Sans render distinct faces');
    }

    $app->shutdown();
}

done_testing();
