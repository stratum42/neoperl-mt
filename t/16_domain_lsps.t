use strict;
use warnings;
use Test::More;
use Config ();
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec ();
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use JSON::PP qw(encode_json decode_json);

use NeoPerl::Editor;
use NeoPerl::Plugin::LSP;
use NeoPerl::LSP::Builtin;
use NeoPerl::LSP::Engine;

my $ROOT = abs_path(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $NPL_LSP = File::Spec->catfile($ROOT, 'bin', 'npl-lsp');
my $SEP = $Config::Config{path_sep} || ':';
my $CHILD_PERL5LIB = join($SEP, grep { defined && !ref($_) && -d $_ } @INC);
my $TMP = tempdir(CLEANUP => 1);

my $HAS_COBC = (-x '/opt/homebrew/bin/cobc'
    || grep { -x File::Spec->catfile($_, 'cobc') } File::Spec->path) ? 1 : 0;
my $HAS_CLANGD = (-x '/usr/bin/clangd'
    || grep { -x File::Spec->catfile($_, 'clangd') } File::Spec->path) ? 1 : 0;

sub _write_lsp_frame {
    my ($fh, $msg) = @_;
    my $json = encode_json($msg);
    print {$fh} "Content-Length: " . length($json) . "\r\n\r\n" . $json;
    $fh->flush;
}

sub _read_lsp_frame {
    my ($fh) = @_;
    my $clen;
    while (defined(my $line = <$fh>)) {
        $line =~ s/\r?\n\z//;
        last if $line eq '';
        if ($line =~ /\AContent-Length:\s*(\d+)\z/i) {
            $clen = int($1);
        }
    }
    return undef unless defined $clen;
    my $buf  = '';
    my $need = $clen;
    while ($need > 0) {
        my $chunk = '';
        my $n = read($fh, $chunk, $need);
        return undef unless defined $n && $n > 0;
        $buf  .= $chunk;
        $need -= $n;
    }
    return decode_json($buf);
}

sub _spawn_npl_lsp {
    my ($lang) = @_;
    local $ENV{PERL5LIB} = $CHILD_PERL5LIB;
    my ($wtr, $rdr);
    my $err = gensym;
    my $pid = open3($wtr, $rdr, $err, $^X, $NPL_LSP, "--lang=$lang");
    binmode($wtr);
    binmode($rdr);
    $wtr->autoflush(1);

    _write_lsp_frame($wtr, {
        jsonrpc => '2.0',
        id      => 1,
        method  => 'initialize',
        params  => { processId => $$, rootUri => 'file:///tmp', capabilities => {} },
    });
    my $init = _read_lsp_frame($rdr);
    _write_lsp_frame($wtr, { jsonrpc => '2.0', method => 'initialized', params => {} });
    return ($pid, $wtr, $rdr, $err, $init);
}

sub _shutdown_npl_lsp {
    my ($pid, $wtr, $rdr, $err, $next_id) = @_;
    _write_lsp_frame($wtr, { jsonrpc => '2.0', id => $next_id || 999, method => 'shutdown', params => undef });
    my $resp = _read_lsp_frame($rdr);
    _write_lsp_frame($wtr, { jsonrpc => '2.0', method => 'exit', params => undef });
    close $wtr;
    close $rdr;
    close $err;
    waitpid($pid, 0);
    return ($? >> 8, $resp);
}

# ============================================================================
# 1. Standalone bin/npl-lsp CLI & Real Content-Length Stdio LSP Pipes
# ============================================================================
subtest 'bin/npl-lsp --list-langs and HLASM / Multi-ISA ASM / RPGILE / COBOL stdio LSP' => sub {
    # --list-langs
    {
        local $ENV{PERL5LIB} = $CHILD_PERL5LIB;
        my ($w, $r, $e);
        $e = gensym;
        my $pid = open3($w, $r, $e, $^X, $NPL_LSP, '--list-langs');
        close $w;
        local $/;
        my $out = <$r>;
        close $r;
        close $e;
        waitpid($pid, 0);
        is($? >> 8, 0, 'bin/npl-lsp --list-langs exited 0');
        for my $d (qw(sql db2i db2luw db2z informix hlasm asm rpgile cobol sycl hip glsl metal all)) {
            like($out, qr/\b$d\b/, "--list-langs lists domain '$d'");
        }
    }

    # HLASM live stdio LSP
    {
        my ($pid, $w, $r, $e, $init) = _spawn_npl_lsp('hlasm');
        is($init->{result}{serverInfo}{name}, 'npl-lsp-hlasm', 'npl-lsp --lang=hlasm initialized');
        ok($init->{result}{capabilities}{hoverProvider}, 'advertises hoverProvider');

        my $uri = 'file:///tmp/nnpa.hlasm';
        my $src = join("\n",
            'NNPASVC  CSECT',
            '         USING TNSRBLK,R0',
            '         NNPA',
            '         L     R3,5000(,R2)',
            '         BR    R14',
            'TNSRBLK  DSECT',
            'TNSRADDR DS    AD',
            '         END   NNPASVC',
            '',
        );
        _write_lsp_frame($w, {
            jsonrpc => '2.0',
            method  => 'textDocument/didOpen',
            params  => { textDocument => { uri => $uri, languageId => 'hlasm', version => 1, text => $src } },
        });
        my $diag_msg = _read_lsp_frame($r);
        is($diag_msg->{method}, 'textDocument/publishDiagnostics', 'HLASM didOpen published diagnostics');
        cmp_ok(scalar(@{ $diag_msg->{params}{diagnostics} }), '>=', 1, 'HLASM diagnostics flagged R0 USING / displacement hazard');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 2, method => 'textDocument/hover',
            params  => { textDocument => { uri => $uri }, position => { line => 2, character => 10 } },
        });
        my $hov = _read_lsp_frame($r);
        like($hov->{result}{contents}{value} // '', qr/B93B|NNPA|Neural/i, 'HLASM stdio hover returned NNPA B93B docs');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 3, method => 'textDocument/completion',
            params  => { textDocument => { uri => $uri }, position => { line => 2, character => 11 } },
        });
        my $cmp = _read_lsp_frame($r);
        cmp_ok(scalar(@{ $cmp->{result}{items} }), '>=', 1, 'HLASM stdio completion returned NNPA match');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 4, method => 'textDocument/documentSymbol',
            params  => { textDocument => { uri => $uri } },
        });
        my $sym = _read_lsp_frame($r);
        cmp_ok(scalar(@{ $sym->{result} }), '>=', 2, 'HLASM stdio documentSymbol returned CSECT & DSECT symbols');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 5, method => 'textDocument/definition',
            params  => { textDocument => { uri => $uri }, position => { line => 1, character => 16 } },
        });
        my $def = _read_lsp_frame($r);
        is($def->{result}{range}{start}{line}, 5, 'HLASM stdio definition resolved TNSRBLK to DSECT line 5');

        my ($rc) = _shutdown_npl_lsp($pid, $w, $r, $e, 6);
        is($rc, 0, 'npl-lsp --lang=hlasm shut down cleanly with exit code 0');
    }

    # Multi-ISA ASM live stdio LSP (POWER8+/10 + s390x Telum II)
    {
        my ($pid, $w, $r, $e, $init) = _spawn_npl_lsp('asm');
        is($init->{result}{serverInfo}{name}, 'npl-lsp-asm', 'npl-lsp --lang=asm initialized');
        my $uri = 'file:///tmp/kernel.s';
        my $src = ".globl vec_mma\nvec_mma:\n    xvf32gerpp 0, 32, 33\n    nnpa\n    blr\n";
        _write_lsp_frame($w, {
            jsonrpc => '2.0', method => 'textDocument/didOpen',
            params  => { textDocument => { uri => $uri, languageId => 'asm', version => 1, text => $src } },
        });
        my $dm = _read_lsp_frame($r);
        is($dm->{method}, 'textDocument/publishDiagnostics', 'ASM didOpen published diagnostics');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 2, method => 'textDocument/hover',
            params  => { textDocument => { uri => $uri }, position => { line => 2, character => 6 } },
        });
        my $h1 = _read_lsp_frame($r);
        like($h1->{result}{contents}{value} // '', qr/xvf32gerpp|POWER10|MMA/i, 'ASM stdio hover returned POWER10 MMA xvf32gerpp');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 3, method => 'textDocument/hover',
            params  => { textDocument => { uri => $uri }, position => { line => 3, character => 5 } },
        });
        my $h2 = _read_lsp_frame($r);
        like($h2->{result}{contents}{value} // '', qr/B93B|Telum|NNPA/i, 'ASM stdio hover returned s390x Telum II NNPA');

        my ($rc) = _shutdown_npl_lsp($pid, $w, $r, $e, 4);
        is($rc, 0, 'npl-lsp --lang=asm shut down cleanly');
    }

    # RPGILE live stdio LSP
    {
        my ($pid, $w, $r, $e, $init) = _spawn_npl_lsp('rpgile');
        is($init->{result}{serverInfo}{name}, 'npl-lsp-rpgile', 'npl-lsp --lang=rpgile initialized');
        my $uri = 'file:///tmp/order.rpgle';
        my $src = "**FREE\ndcl-proc FixStr;\n  x = %SCANRPL(',' : '' : amt);\nend-proc;\n";
        _write_lsp_frame($w, {
            jsonrpc => '2.0', method => 'textDocument/didOpen',
            params  => { textDocument => { uri => $uri, languageId => 'rpgile', version => 1, text => $src } },
        });
        my $dm = _read_lsp_frame($r);
        is($dm->{method}, 'textDocument/publishDiagnostics', 'RPGILE didOpen published diagnostics');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 2, method => 'textDocument/hover',
            params  => { textDocument => { uri => $uri }, position => { line => 2, character => 8 } },
        });
        my $h = _read_lsp_frame($r);
        like($h->{result}{contents}{value} // '', qr/%SCANRPL/i, 'RPGILE stdio hover returned %SCANRPL signature');

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => 3, method => 'textDocument/documentSymbol',
            params  => { textDocument => { uri => $uri } },
        });
        my $s = _read_lsp_frame($r);
        ok((grep { ($_->{name} // '') eq 'FixStr' } @{ $s->{result} }), 'RPGILE stdio documentSymbol found DCL-PROC FixStr');

        my ($rc) = _shutdown_npl_lsp($pid, $w, $r, $e, 4);
        is($rc, 0, 'npl-lsp --lang=rpgile shut down cleanly');
    }
};

subtest 'bin/npl-lsp --lang=all multiplexing SQL/SPL, COBOL, SYCL, HIP, GLSL, and Metal over stdio' => sub {
    my ($pid, $w, $r, $e, $init) = _spawn_npl_lsp('all');
    is($init->{result}{serverInfo}{name}, 'npl-lsp-all', 'npl-lsp --lang=all initialized');

    my @docs = (
        {
            label => 'COBOL',
            uri   => 'file:///tmp/pay.cbl',
            lang  => 'cobol',
            text  => "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. PAYCALC.\n       DATA DIVISION.\n       WORKING-STORAGE SECTION.\n       01 WS-AMT PIC S9(7)V99 COMP-3.\n       PROCEDURE DIVISION.\n       MAIN-PARA.\n           STOP RUN.\n",
            hl    => 4, hc => 32, hre => qr/COMP-3|packed/i,
            want_sym => 1,
        },
        {
            label => 'SQL/Db2LUW',
            uri   => 'file:///tmp/vec.sql',
            lang  => 'sql',
            text  => "SELECT VECTOR_DISTANCE(EMB, ?, COSINE) FROM SYSCAT.TABLES;\n",
            hl    => 0, hc => 10, hre => qr/VECTOR_DISTANCE|COSINE/i,
            want_sym => 0,
        },
        {
            label => 'Informix SPL',
            uri   => 'file:///tmp/proc.spl',
            lang  => 'informix',
            text  => "CREATE PROCEDURE check_locks()\n  SELECT * FROM sysmaster:syslocks;\nEND PROCEDURE;\n",
            hl    => 1, hc => 25, hre => qr/syslocks|sysmaster/i,
            want_sym => 1,
        },
        {
            label => 'Intel SYCL',
            uri   => 'file:///tmp/gemm.sycl',
            lang  => 'sycl',
            text  => "void gemm(sycl::nd_item<1> it) { auto sg = it.get_sub_group(); }\n",
            hl    => 0, hc => 18, hre => qr/nd_item/i,
            want_sym => 1,
        },
        {
            label => 'AMD HIP',
            uri   => 'file:///tmp/mi300.hip',
            lang  => 'hip',
            text  => "__global__ void k(int *o) { unsigned m = __ballot(1) & 0xffffffff; __builtin_amdgcn_mfma_f32_16x16x16bf16_1k(); o[0] = m; }\n",
            hl    => 0, hc => 75, hre => qr/mfma/i,
            want_diag => 1,
            want_sym  => 1,
        },
        {
            label => 'Vulkan GLSL',
            uri   => 'file:///tmp/pbr.comp',
            lang  => 'glsl',
            text  => "#version 460\nlayout(std140, binding=0) uniform U { float a; vec3 pos; };\nvoid main() {}\n",
            hl    => 1, hc => 9, hre => qr/std140/i,
            want_diag => 1,
            want_sym  => 1,
        },
        {
            label => 'Apple Metal',
            uri   => 'file:///tmp/tile.metal',
            lang  => 'metal',
            text  => "struct V { float3 pos; };\nkernel void k(device packed_float3 *p [[buffer(0)]]) { simdgroup_multiply_accumulate(c,a,b,c); }\n",
            hl    => 1, hc => 25, hre => qr/packed_float3/i,
            want_diag => 1,
            want_sym  => 1,
        },
    );

    my $req_id = 10;
    for my $d (@docs) {
        _write_lsp_frame($w, {
            jsonrpc => '2.0',
            method  => 'textDocument/didOpen',
            params  => {
                textDocument => {
                    uri        => $d->{uri},
                    languageId => $d->{lang},
                    version    => 1,
                    text       => $d->{text},
                },
            },
        });
        my $pub = _read_lsp_frame($r);
        is($pub->{method}, 'textDocument/publishDiagnostics', "$d->{label} didOpen published diagnostics");
        if ($d->{want_diag}) {
            cmp_ok(scalar(@{ $pub->{params}{diagnostics} }), '>=', 1, "$d->{label} emitted real domain diagnostics");
        }

        _write_lsp_frame($w, {
            jsonrpc => '2.0', id => $req_id++, method => 'textDocument/hover',
            params  => { textDocument => { uri => $d->{uri} }, position => { line => $d->{hl}, character => $d->{hc} } },
        });
        my $hov = _read_lsp_frame($r);
        like($hov->{result}{contents}{value} // '', $d->{hre}, "$d->{label} stdio hover matched domain docs");

        if ($d->{want_sym}) {
            _write_lsp_frame($w, {
                jsonrpc => '2.0', id => $req_id++, method => 'textDocument/documentSymbol',
                params  => { textDocument => { uri => $d->{uri} } },
            });
            my $sym = _read_lsp_frame($r);
            cmp_ok(scalar(@{ $sym->{result} }), '>=', 1, "$d->{label} stdio documentSymbol extracted symbols");
        }
    }

    my ($rc) = _shutdown_npl_lsp($pid, $w, $r, $e, $req_id);
    is($rc, 0, 'npl-lsp --lang=all shut down cleanly with exit code 0');
};

# ============================================================================
# 2. Dual-Mode NeoPerl::Plugin::LSP (Zero-Fork Built-in + Live cobc + Live clangd)
# ============================================================================
subtest 'Dual-Mode Plugin::LSP in-process built-in + live cobc + live clangd' => sub {
    my $ed  = NeoPerl::Editor->new(cwd => $TMP);
    my $lsp = NeoPerl::Plugin::LSP->new(editor => $ed, auto_start => 0);

    my $info = $lsp->info();
    cmp_ok(scalar(@{ $info->{builtin_langs} }), '>=', 13, 'Plugin::LSP exposes all built-in domain languages');

    # 1. Zero-fork in-process HLASM hover, completion, diagnostics, symbols
    my $hbuf = $ed->create_buffer(
        name     => 'SVC.hlasm',
        path     => File::Spec->catfile($TMP, 'SVC.hlasm'),
        filetype => 'hlasm',
        text     => "MYSVC    CSECT\n         USING MYDSECT,R0\n         NNPA\nMYDSECT  DSECT\nFIELD1   DS    F\n",
    );
    $lsp->on_buffer_open($hbuf);
    my $hdiags = $ed->get_diagnostics($hbuf, source => 'lsp_builtin');
    cmp_ok(scalar(@$hdiags), '>=', 1, 'Plugin::LSP zero-fork built-in painted HLASM R0 USING diagnostic');
    my $hhov = $ed->request_hover($hbuf, 2, 10);
    like($hhov->{contents}{value} // '', qr/B93B|NNPA/i, 'Editor K (request_hover) served HLASM NNPA in-process');
    my $hdef = $ed->request_definition($hbuf, 1, 16);
    is($hdef->{range}{start}{line}, 3, 'Editor gd (request_definition) resolved MYDSECT to line 3');
    my $hsyms = $ed->get_symbols($hbuf);
    cmp_ok(scalar(@$hsyms), '>=', 2, 'Editor get_symbols returned HLASM CSECT & DSECT');

    # 2. Zero-fork in-process Metal & HIP & GLSL & SQL
    my $mbuf = $ed->create_buffer(
        name     => 'test.metal',
        path     => File::Spec->catfile($TMP, 'test.metal'),
        filetype => 'metal',
        text     => "struct V { float3 pos; };\nkernel void k(device packed_float3 *p [[buffer(0)]]) {}\n",
    );
    $lsp->on_buffer_open($mbuf);
    my $mdiags = $ed->get_diagnostics($mbuf, source => 'lsp_builtin');
    cmp_ok(scalar(@$mdiags), '>=', 1, 'Plugin::LSP built-in caught float3 16B ABI trap in .metal');
    my $mhov = $ed->request_hover($mbuf, 1, 24);
    like($mhov->{contents}{value} // '', qr/packed_float3/i, 'Editor request_hover served Metal packed_float3 docs');

    my $abuf = $ed->create_buffer(
        name     => 'mi300.hip',
        path     => File::Spec->catfile($TMP, 'mi300.hip'),
        filetype => 'hip',
        text     => "__global__ void k(int *o) { unsigned m = __ballot(1) & 0xffffffff; o[0] = m; }\n",
    );
    $lsp->on_buffer_open($abuf);
    cmp_ok(scalar(@{ $ed->get_diagnostics($abuf, source => 'lsp_builtin') }), '>=', 1,
        'Plugin::LSP built-in caught CDNA wave64 32-bit ballot mask bug in .hip');

    my $sbuf = $ed->create_buffer(
        name     => 'q.sql',
        path     => File::Spec->catfile($TMP, 'q.sql'),
        filetype => 'sql',
        text     => "SELECT * FROM QSYS2.ACTIVE_JOB_INFO();\n",
    );
    my $shov = $ed->request_hover($sbuf, 0, 22);
    like($shov->{contents}{value} // '', qr/ACTIVE_JOB_INFO|QSYS2/i, 'Editor request_hover served Db2i QSYS2.ACTIVE_JOB_INFO');

    # 3. External cobc integration in Plugin::LSP
    if ($HAS_COBC) {
        ok(exists $info->{compilers}{cobc}, "Plugin::LSP auto-detected live cobc ($info->{compilers}{cobc})");
        my $cbl_path = File::Spec->catfile($TMP, 'broken.cbl');
        my $cbuf = $ed->create_buffer(
            name     => 'broken.cbl',
            path     => $cbl_path,
            filetype => 'cobol',
            text     => "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. BROKEN.\n       PROCEDURE DIVISION.\n           DISPLAY UNDECLARED-ITEM.\n           STOP RUN.\n",
        );
        $lsp->on_buffer_open($cbuf);
        my $cdiags = $lsp->wait_for_compiler_check($cbuf, 5.0, 'compiler_cobc');
        cmp_ok(scalar(@$cdiags), '>=', 1, 'LIVE cobc reported real diagnostic for UNDECLARED-ITEM');
        like($cdiags->[0]{message} // '', qr/UNDECLARED-ITEM/i, 'LIVE cobc diagnostic names UNDECLARED-ITEM');
        is($cdiags->[0]{line}, 3, 'LIVE cobc mapped error to exact 0-based line 3');

        # Fix COBOL buffer and re-run live cobc
        $cbuf->set_text("       IDENTIFICATION DIVISION.\n       PROGRAM-ID. FIXED.\n       DATA DIVISION.\n       WORKING-STORAGE SECTION.\n       01 WS-OK PIC 9(2) VALUE 1.\n       PROCEDURE DIVISION.\n           DISPLAY WS-OK.\n           STOP RUN.\n");
        my $fixed = $lsp->check_cobc_syntax($cbuf, sync => 1);
        is(scalar(@$fixed), 0, 'LIVE cobc cleared all errors after fixing COBOL source');
    }

    # 4. LIVE /usr/bin/clangd configured for C/C++/XS/HIP/SYCL/Metal
    if ($HAS_CLANGD) {
        ok((grep { $_ eq 'clangd' } $lsp->configured_servers), 'Plugin::LSP auto-configured clangd');
        for my $ft (qw(c cpp xs hip sycl metal)) {
            is($lsp->server_name_for_filetype($ft), 'clangd', "clangd covers filetype '$ft'");
        }

        my $cpp_path = File::Spec->catfile($TMP, 'gpu_host.cpp');
        open my $fh, '>', $cpp_path or die $!;
        print {$fh} "int compute_tile(int a) { return a * 2; }\nint main() { return compute_tile(4) + missing_sym; }\n";
        close $fh;

        my $ed2  = NeoPerl::Editor->new(cwd => $TMP);
        my $lsp2 = NeoPerl::Plugin::LSP->new(editor => $ed2, auto_start => 1);
        my $cpp_buf = $ed2->open_file($cpp_path);
        ok($lsp2->wait_for_ready('clangd', 6.0), 'LIVE clangd initialized cleanly in Dual-Mode LSP');
        my $cd = $lsp2->wait_for_diagnostics($cpp_buf, 6.0);
        cmp_ok(scalar(@$cd), '>=', 1, 'LIVE clangd published diagnostics on C++ file');
        $lsp2->stop_all();
    }

    $lsp->stop_all();
};

done_testing();
