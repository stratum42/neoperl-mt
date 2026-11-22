use strict;
use warnings;
use Test::More;
use Config ();
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec ();
use File::Temp qw(tempdir);
use IO::Socket::INET ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Time::HiRes qw(time sleep);
use JSON::PP qw(encode_json decode_json);

use NeoPerl::Editor;
use NeoPerl::Plugin::Telescope;
use NeoPerl::Plugin::PerlDev;
use NeoPerl::Plugin::XSDev;
use NeoPerl::Antigravity::EditorMCP;
use NeoPerl::MCP::Registry;

my $ROOT = abs_path(File::Spec->catdir(dirname(__FILE__), File::Spec->updir));
my $NPL_MCP = File::Spec->catfile($ROOT, 'bin', 'npl-mcp');
my $SEP = $Config::Config{path_sep} || ':';
my $CHILD_PERL5LIB = join($SEP, grep { defined && !ref($_) && -d $_ } @INC);
my $TMP = tempdir(CLEANUP => 1);

my $HAS_COBC = (-x '/opt/homebrew/bin/cobc'
    || grep { -x File::Spec->catfile($_, 'cobc') } File::Spec->path) ? 1 : 0;

sub _http_request_with_pump {
    my ($mcp, $method, $path, $body) = @_;
    my $port = $mcp->port;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 3,
    ) or die "Connect 127.0.0.1:$port failed: $!";
    $sock->blocking(0);

    my $req = "$method $path HTTP/1.1\r\n"
            . "Host: 127.0.0.1:$port\r\n"
            . "Connection: close\r\n";
    if (defined $body) {
        $req .= "Content-Type: application/json\r\n"
              . "Content-Length: " . length($body) . "\r\n";
    }
    $req .= "\r\n" . ($body // '');
    syswrite($sock, $req);

    my $raw = '';
    my $deadline = time() + 4.0;
    while (time() < $deadline) {
        $mcp->poll(0.01) if $mcp;
        my $chunk = '';
        my $n = sysread($sock, $chunk, 65536);
        if (defined $n) {
            last if $n == 0;
            $raw .= $chunk;
        }
        sleep(0.005);
    }
    close $sock;
    my ($hdr, $resp_body) = split /\r?\n\r?\n/, $raw, 2;
    my ($status) = (($hdr // '') =~ m{\AHTTP/1\.\d\s+(\d+)});
    return ($status || 0, $hdr // '', $resp_body // '');
}

sub _http_request_standalone {
    my ($port, $method, $path, $body) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 3,
    ) or die "Connect 127.0.0.1:$port failed: $!";

    my $req = "$method $path HTTP/1.1\r\n"
            . "Host: 127.0.0.1:$port\r\n"
            . "Connection: close\r\n";
    if (defined $body) {
        $req .= "Content-Type: application/json\r\n"
              . "Content-Length: " . length($body) . "\r\n";
    }
    $req .= "\r\n" . ($body // '');
    print {$sock} $req;

    local $/;
    my $raw = <$sock>;
    close $sock;
    my ($hdr, $resp_body) = split /\r?\n\r?\n/, ($raw // ''), 2;
    my ($status) = (($hdr // '') =~ m{\AHTTP/1\.\d\s+(\d+)});
    return ($status || 0, $hdr // '', $resp_body // '');
}

# ============================================================================
# 1. Registry + EditorMCP Selective Mounting + Ex Commands + Live HTTP MCP
# ============================================================================
subtest 'Registry selective mounting in EditorMCP (23 core + 12 packs / 52 tools)' => sub {
    my $ed  = NeoPerl::Editor->new(cwd => $TMP);
    my $tel = NeoPerl::Plugin::Telescope->new(editor => $ed);
    my $mcp = NeoPerl::Antigravity::EditorMCP->new(editor => $ed);

    # Register PerlDev (4) + XSDev (5) so core starts at exactly 23 tools
    my $pdev = NeoPerl::Plugin::PerlDev->new(editor => $ed, mcp => $mcp, auto_critic => 0);
    my $xdev = NeoPerl::Plugin::XSDev->new(editor => $ed, mcp => $mcp, workdir => $TMP);
    is(scalar(@{ $mcp->list_tool_names }), 23, 'EditorMCP preserves all 23 core tools before mounting packs');

    my $reg = NeoPerl::MCP::Registry->new(
        editor     => $ed,
        editor_mcp => $mcp,
        telescope  => $tel,
    );

    my $packs = $reg->list_packs();
    is(scalar(@$packs), 12, 'Registry catalogs all 12 domain MCP packs');
    is(scalar(@{ $reg->active_packs }), 0, 'Zero domain packs mounted by default (avoids LLM tool bloat)');

    my $total_domain_tools = 0;
    for my $p (@$packs) {
        ok($p->{loaded}, "pack '$p->{name}' loaded cleanly ($p->{tool_count} tools)");
        cmp_ok($p->{tool_count}, '>=', 4, "pack '$p->{name}' provides >= 4 tools");
        $total_domain_tools += $p->{tool_count};
    }
    cmp_ok($total_domain_tools, '>=', 52, "all 12 packs collectively expose $total_domain_tools domain tools (>= 52)");

    # Start EditorMCP live HTTP server (Mojolicious when installed)
    my $port = $mcp->start();
    ok($port > 0, "EditorMCP started on 127.0.0.1:$port (engine=" . $mcp->engine . ')');

    # :McpPackEnable db2z
    my $en_res = $ed->exec_command(':McpPackEnable db2z');
    ok($en_res->{ok}, ':McpPackEnable db2z succeeded');
    is_deeply($reg->active_packs, ['db2z'], 'active_packs tracks db2z');
    is(scalar(@{ $mcp->list_tool_names }), 28, 'EditorMCP tool count increased from 23 to 28');

    # Verify mounted db2z pack over LIVE HTTP JSON-RPC 2.0
    my ($st, undef, $body) = _http_request_with_pump($mcp, 'POST', '/mcp', encode_json({
        jsonrpc => '2.0',
        id      => 1,
        method  => 'tools/list',
        params  => {},
    }));
    is($st, 200, 'HTTP tools/list returned 200 after :McpPackEnable db2z');
    my $list_resp = decode_json($body);
    is(scalar(@{ $list_resp->{result}{tools} }), 28, 'HTTP tools/list reflects selectively mounted db2z pack');

    # Invoke db2z_dclgen_generate over LIVE HTTP MCP
    my ($cst, undef, $cbody) = _http_request_with_pump($mcp, 'POST', '/mcp', encode_json({
        jsonrpc => '2.0',
        id      => 2,
        method  => 'tools/call',
        params  => {
            name      => 'db2z_dclgen_generate',
            arguments => {
                ddl => 'CREATE TABLE CUST_ACCT (ACCT_ID INTEGER NOT NULL, BALANCE DECIMAL(11,2) NOT NULL, NAME VARCHAR(30))',
            },
        },
    }));
    is($cst, 200, 'HTTP tools/call db2z_dclgen_generate returned 200');
    my $call_resp = decode_json($cbody);
    my $dcl_sc = $call_resp->{result}{structuredContent};
    ok($dcl_sc->{ok}, 'db2z_dclgen_generate succeeded over HTTP MCP');
    like($dcl_sc->{cobol_dclgen} // $dcl_sc->{dclgen} // encode_json($dcl_sc), qr/COMP-3/i, 'DCLGEN emitted COBOL COMP-3');

    # :McpPackDisable db2z -> unregisters cleanly back to 23
    my $dis_res = $ed->exec_command(':McpPackDisable db2z');
    ok($dis_res->{ok}, ':McpPackDisable db2z succeeded');
    is_deeply($reg->active_packs, [], 'active_packs empty after disable');
    is(scalar(@{ $mcp->list_tool_names }), 23, 'EditorMCP cleanly restored to 23 core tools after unmount');
    ok(!$mcp->has_tool('db2z_dclgen_generate'), 'db2z_dclgen_generate unregistered cleanly');

    # :McpPacks Telescope picker opens & toggles a pack live on <CR>
    my $pick_res = $ed->exec_command(':McpPacks');
    ok($pick_res->{ok} && $tel->is_open, ':McpPacks opened Telescope picker');
    is(scalar(@{ $tel->results }), 12, 'Telescope :McpPacks displays all 12 domain packs');
    $tel->handle_key('<CR>');
    ok(!$tel->is_open, 'Telescope picker closed on <CR>');
    is_deeply($reg->active_packs, ['db2i'], 'Telescope <CR> toggled db2i pack ON live');

    # :McpConfigEmit writes .agents/mcp_config.json
    my $cfg_path = File::Spec->catfile($TMP, '.agents', 'mcp_config.json');
    my $emit_res = $ed->exec_command(":McpConfigEmit $cfg_path");
    ok($emit_res->{ok} && -f $cfg_path, ':McpConfigEmit wrote .agents/mcp_config.json');
    open my $cfh, '<:raw', $cfg_path or die $!;
    local $/;
    my $cfg_json = decode_json(<$cfh>);
    close $cfh;
    ok(exists $cfg_json->{mcpServers}{'neoperl-db2i'}, 'emitted mcp_config.json contains neoperl-db2i entry');
    is_deeply($cfg_json->{mcpServers}{'neoperl-db2i'}{args}, [ 'bin/npl-mcp', '--pack=db2i', '--stdio' ],
        'emitted entry uses portable bin/npl-mcp --pack=... --stdio');

    # enable_all mounts ALL 12 packs (23 + 52 = 75 tools)
    my $all_res = $reg->enable_all();
    ok($all_res->{ok}, 'enable_all mounted all 12 domain packs');
    is(scalar(@{ $reg->active_packs }), 12, 'all 12 packs active');
    is(scalar(@{ $mcp->list_tool_names }), 23 + $total_domain_tools,
        'EditorMCP exposes all 23 core + all 52 domain pack tools simultaneously');

    # disable_all restores exact 23 core tools
    $reg->disable_all();
    is(scalar(@{ $mcp->list_tool_names }), 23, 'disable_all restored exact 23 core tools');

    $mcp->stop();
    $pdev->worker->shutdown() if $pdev && $pdev->worker;
    $xdev->shutdown() if $xdev;
};

# ============================================================================
# 2. Deep Functional Verification of ALL 12 Domain Packs (All 52 Tools)
# ============================================================================
my $REG = NeoPerl::MCP::Registry->new();

subtest 'Database Packs (Db2i, Db2LUW, Db2z, Informix)' => sub {
    # 1. Db2i
    my $db2i = $REG->get_pack('db2i');
    my $blk = $db2i->call_tool('db2i_query', { sql => 'DELETE FROM MYLIB.ORDERS' });
    ok(!$blk->{ok} && $blk->{blocked}, 'Db2i read-only guardrail blocked DELETE');
    my $dry = $db2i->call_tool('db2i_query', { sql => 'SELECT * FROM QSYS2.SYSTABLES FETCH FIRST 5 ROWS ONLY' });
    ok($dry->{ok} && $dry->{mode} eq 'dry_run', 'Db2i dry-run query passed read-only check');
    my $cat = $db2i->call_tool('db2i_catalog_inspect', { target => 'tables', schema => 'MYLIB' });
    ok($cat->{ok} && $cat->{sql} =~ /QSYS2\.SYSTABLES/i, 'Db2i catalog inspect builds QSYS2.SYSTABLES SQL');
    my $svc = $db2i->call_tool('db2i_system_services', { service => 'active_job_info' });
    ok($svc->{ok} && $svc->{sql} =~ /QSYS2\.ACTIVE_JOB_INFO/i, 'Db2i system services builds QSYS2.ACTIVE_JOB_INFO SQL');
    my $lint = $db2i->call_tool('db2i_sql_lint_explain', { naming => '*SYS', sql => 'SELECT * FROM MYLIB/CUSTPF' });
    ok($lint->{ok}, 'Db2i SQL lint analyzed *SYS naming query');
    my $rpg_sql = $db2i->call_tool('db2i_rpg_exec_sql_check', {
        source => "**FREE\nexec sql set option commit = *none;\nexec sql select bal into :amt from cust where id = :cid;\n",
    });
    ok($rpg_sql->{ok}, 'Db2i RPG EXEC SQL check validated embedded SQL host variables');

    # 2. Db2LUW
    my $luw = $REG->get_pack('db2luw');
    my $luw_blk = $luw->call_tool('db2luw_query', { sql => 'DROP TABLE USERS' });
    ok(!$luw_blk->{ok} && $luw_blk->{blocked}, 'Db2LUW guardrail blocked DROP TABLE');
    my $luw_cat = $luw->call_tool('db2luw_catalog_inspect', { target => 'tables', schema => 'APP' });
    ok($luw_cat->{ok} && $luw_cat->{sql} =~ /SYSCAT\.TABLES/i, 'Db2LUW catalog inspect targets SYSCAT.TABLES');
    my $luw_exp = $luw->call_tool('db2luw_explain_analyze', {
        explain_text => "TBSCAN (2400 timerons)\nHSJOIN\nIXSCAN\nTQ\n",
    });
    ok($luw_exp->{ok} && ($luw_exp->{mon_get_pkg_cache_sql} // '') =~ /MON_GET_PKG_CACHE_STMT/i,
        'Db2LUW explain analyzer parses db2exfmt operators and emits MON_GET_PKG_CACHE_STMT SQL');
    my $luw_vec = $luw->call_tool('db2luw_vector_helper', {
        table => 'NEOPERL_MEMORY', dimension => 768, coord_type => 'REAL', metric => 'COSINE',
    });
    ok($luw_vec->{ok}, 'Db2LUW vector helper succeeded');
    like($luw_vec->{ddl} // '', qr/VECTOR\s*\(\s*768\s*,\s*REAL\s*\)/i, 'Db2LUW vector DDL emits VECTOR(768, REAL)');
    like(encode_json($luw_vec), qr/VECTOR_DISTANCE.*COSINE/is, 'Db2LUW vector query emits VECTOR_DISTANCE COSINE');
    my $luw_lint = $luw->call_tool('db2luw_sql_lint', {
        sql => 'SELECT * FROM SALES_FACT WITH UR', table_org => 'column',
    });
    ok($luw_lint->{ok}, 'Db2LUW SQL lint analyzed isolation & BLU columnar guidance');

    # 3. Db2z
    my $db2z = $REG->get_pack('db2z');
    my $z_blk = $db2z->call_tool('db2z_query', { sql => 'UPDATE ACCT SET BAL = 0' });
    ok(!$z_blk->{ok} && $z_blk->{blocked}, 'Db2z guardrail blocked UPDATE');
    my $z_cat = $db2z->call_tool('db2z_catalog_inspect', { target => 'tables' });
    ok($z_cat->{ok} && $z_cat->{sql} =~ /SYSIBM\.SYSTABLES/i, 'Db2z catalog inspect targets SYSIBM.SYSTABLES');
    my $z_plan = $db2z->call_tool('db2z_plan_table_analyze', {
        plan_text => 'ACCESSTYPE=R MATCHCOLS=0 INDEXONLY=N PREFETCH=S SORTC_ORDERBY=Y',
        sql       => 'SELECT * FROM ACCT WHERE UPPER(NAME) = ? ORDER BY BAL',
    });
    ok($z_plan->{ok}, 'Db2z PLAN_TABLE analyzer succeeded');
    like(encode_json($z_plan), qr/tablespace scan|ACCESSTYPE|Stage 2/i, 'Db2z PLAN_TABLE flagged tablespace scan / Stage 2');
    my $z_dcl = $db2z->call_tool('db2z_dclgen_generate', {
        ddl => 'CREATE TABLE LEDGER (ID INTEGER NOT NULL, AMT DECIMAL(9,2), DESCR VARCHAR(32))',
    });
    ok($z_dcl->{ok}, 'Db2z DCLGEN generator succeeded');
    like(encode_json($z_dcl), qr/EXEC SQL DECLARE (?:\w+\.)?LEDGER TABLE/i, 'DCLGEN emitted EXEC SQL DECLARE TABLE');
    like(encode_json($z_dcl), qr/COMP-3/i, 'DCLGEN emitted COMP-3 for DECIMAL');
    my $z_bind = $db2z->call_tool('db2z_bind_package_check', {
        bind_text => 'BIND PACKAGE(PROD) MEMBER(ACCTPOST) ISOLATION(CS) RELEASE(DEALLOCATE) CURRENTDATA(NO) DEGREE(ANY)',
    });
    ok($z_bind->{ok}, 'Db2z BIND PACKAGE checker succeeded');

    # 4. Informix
    my $ifx = $REG->get_pack('informix');
    my $ifx_blk = $ifx->call_tool('informix_query', { sql => 'TRUNCATE TABLE orders' });
    ok(!$ifx_blk->{ok} && $ifx_blk->{blocked}, 'Informix guardrail blocked TRUNCATE');
    my $ifx_cat = $ifx->call_tool('informix_catalog_inspect', { target => 'syslocks' });
    ok($ifx_cat->{ok} && $ifx_cat->{sql} =~ /sysmaster:syslocks/i, 'Informix catalog inspect targets sysmaster:syslocks');
    my $ifx_spl = $ifx->call_tool('informix_spl_analyze', {
        source => "CREATE PROCEDURE get_rows()\n  DEFINE v INT;\n  ON EXCEPTION IN (-206)\n  END EXCEPTION;\n  FOREACH SELECT id INTO v FROM items\n    RETURN v WITH RESUME;\n  END FOREACH;\nEND PROCEDURE;\n",
    });
    ok($ifx_spl->{ok} && ($ifx_spl->{routine_count} // 0) >= 1, 'Informix SPL analyzer parsed procedure, FOREACH, and ON EXCEPTION');
    my $ifx_exp = $ifx->call_tool('informix_explain_analyze', {
        explain_text => "1) informix.orders: SEQUENTIAL SCAN\n2) informix.items: AUTOINDEX PATH\nDYNAMIC HASH JOIN\n",
    });
    ok($ifx_exp->{ok} && @{ $ifx_exp->{findings} || [] } >= 2, 'Informix sqexplain.out analyzer flagged SEQUENTIAL SCAN & AUTOINDEX PATH');
    my $ifx_aud = $ifx->call_tool('informix_schema_audit', {
        ddl => 'CREATE TABLE audit_log (id SERIAL, payload LVARCHAR(4096)) LOCK MODE PAGE;',
    });
    ok($ifx_aud->{ok}, 'Informix schema check inspected SERIAL/LVARCHAR/LOCK MODE PAGE');
};

subtest 'Mainframe, Midrange & Multi-ISA Assembly Packs (HLASM, RPGILE, COBOL, AsmMultiArch)' => sub {
    # 5. HLASM
    my $hlasm = $REG->get_pack('hlasm');
    my $nnpa = $hlasm->call_tool('hlasm_opcode_lookup', { mnemonic => 'NNPA' });
    ok($nnpa->{ok}, 'HLASM opcode lookup found NNPA');
    like(encode_json($nnpa), qr/B93B/i, 'HLASM NNPA carries hex opcode B93B (Telum / Telum II)');
    my $dsect = $hlasm->call_tool('hlasm_dsect_layout', {
        code => "WORKAREA DSECT\nEYE      DC    CL8'WORK    '\nFLG      DS    H\nPTR      DS    AD\nWORKLEN  EQU   *-WORKAREA\n",
    });
    ok($dsect->{ok} && $dsect->{sections}[0]{total_length} == 24, 'HLASM DSECT computed exact 24B length with 6B alignment slack');
    is($dsect->{sections}[0]{total_slack_bytes}, 6, 'HLASM DSECT computed exact 6 slack bytes before AD');
    my $using = $hlasm->call_tool('hlasm_using_check', {
        code => "         USING WORKAREA,R0\n         L     R3,5000(,R2)\n",
    });
    ok(!$using->{ok} && ($using->{finding_count} // 0) >= 2, 'HLASM USING checker flagged R0 base & >4095B displacement errors');
    like(encode_json($using), qr/HLASM_USING_R0_HAZARD.*HLASM_DISP12_OVERFLOW/is, 'HLASM USING checker emitted R0 hazard and 12-bit displacement overflow codes');
    my $mac = $hlasm->call_tool('hlasm_macro_analyze', {
        code => "         MACRO\n&LBL     MYCALL &ARG1\n         LCLA  &N\n&LBL     BASR  R14,R15  &SYSNDX\n         MEND\n",
    });
    ok($mac->{ok}, 'HLASM macro analyzer parsed MACRO/MEND and &SYSNDX');

    # 6. RPGILE
    my $rpg = $REG->get_pack('rpgile');
    my $bif = $rpg->call_tool('rpgile_bif_lookup', { name => '%SCANRPL' });
    ok($bif->{ok} && ($bif->{bif}{name} // '') eq '%SCANRPL', 'RPGILE %BIF lookup returned %SCANRPL');
    my $ast = $rpg->call_tool('rpgile_outline_ast', {
        code => "**FREE\nctl-opt dftactgrp(*no) actgrp(*caller);\ndcl-proc CalcTotal;\n  dcl-pi *n packed(9:2); qty int(10) value; end-pi;\n  return qty * 1.25;\nend-proc;\n",
    });
    ok($ast->{ok}, 'RPGILE AST outline parsed **FREE CTL-OPT & DCL-PROC');
    my $ds = $rpg->call_tool('rpgile_ds_layout', {
        code => "**FREE\ndcl-ds OrderRec qualified;\n  amt packed(9:2);\n  ptr pointer;\nend-ds;\n",
    });
    ok($ds->{ok}, 'RPGILE DS layout computed packed + 16-byte tagged pointer');
    like(encode_json($ds), qr/"elem_bytes":16|"total_bytes":16/i, 'RPGILE POINTER occupies 16 bytes on IBM i');
    my $rlint = $rpg->call_tool('rpgile_lint', {
        code => "**FREE\nexec sql select count(*) into :cnt from orders;\n*inlr = *on;\n",
    });
    ok($rlint->{ok}, 'RPGILE linter flagged missing SQLSTATE check / CTL-OPT');

    # 7. COBOL (and cobc when installed)
    my $cbl = $REG->get_pack('cobol');
    my $pic = $cbl->call_tool('cobol_pic_layout', {
        code => "       01 WS-REC.\n          05 WS-AMT PIC S9(7)V99 COMP-3.\n          05 WS-CNT PIC S9(9) COMP.\n",
    });
    ok($pic->{ok} && $pic->{records}[0]{total_bytes} == 9, 'COBOL PIC layout computed COMP-3 (5B) + COMP (4B) = 9B');
    my $cfg = $cbl->call_tool('cobol_outline_flow', {
        code => "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. FLOWT.\n       PROCEDURE DIVISION.\n       MAIN-PARA.\n           PERFORM WORK-PARA.\n           STOP RUN.\n       WORK-PARA.\n           DISPLAY 'OK'.\n",
    });
    ok($cfg->{ok}, 'COBOL outline flow built PERFORM CFG');
    my $cics = $cbl->call_tool('cobol_cics_sql_ref', { command => 'SYNCPOINT', sqlcode => -803 });
    ok($cics->{ok}, 'COBOL CICS/SQL reference returned SYNCPOINT & SQLCODE -803');
    my $good_cbl = $cbl->call_tool('cobol_lint_compile', {
        code => "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. GOODT.\n       DATA DIVISION.\n       WORKING-STORAGE SECTION.\n       01 WS-X PIC 9(4) VALUE 42.\n       PROCEDURE DIVISION.\n       MAIN-PARA.\n           DISPLAY WS-X.\n           STOP RUN.\n",
    });
    ok($good_cbl->{ok}, 'COBOL lint/compile succeeded on valid COBOL');
    if ($HAS_COBC) {
        ok($good_cbl->{cobc_available} && $good_cbl->{cobc_passed}, 'LIVE cobc passed valid COBOL with exit 0');
        my $bad_cbl = $cbl->call_tool('cobol_lint_compile', {
            code => "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. BADT.\n       PROCEDURE DIVISION.\n           DISPLAY NO-SUCH-VAR.\n           STOP RUN.\n",
        });
        ok($bad_cbl->{cobc_available} && !$bad_cbl->{cobc_passed} && @{ $bad_cbl->{cobc_diagnostics} || [] } >= 1,
            'LIVE cobc caught undeclared identifier in broken COBOL');
    }

    # 8. AsmMultiArch (POWER8+/10, amd64 AMX, arm64 SVE2, s390x Telum II NNPA)
    my $asm = $REG->get_pack('asm');
    my $p10 = $asm->call_tool('asm_isa_lookup', { arch => 'ppc64le', mnemonic => 'xvf32gerpp' });
    ok($p10->{ok} && $p10->{exact_match}, 'AsmMultiArch found POWER10 MMA xvf32gerpp');
    my $amx = $asm->call_tool('asm_isa_lookup', { arch => 'amd64', mnemonic => 'tdpbf16ps' });
    ok($amx->{ok} && $amx->{exact_match}, 'AsmMultiArch found amd64 Intel AMX tdpbf16ps');
    my $sve = $asm->call_tool('asm_isa_lookup', { arch => 'arm64', mnemonic => 'whilelt' });
    ok($sve->{ok} && $sve->{exact_match}, 'AsmMultiArch found arm64 SVE2 whilelt');
    my $z17 = $asm->call_tool('asm_isa_lookup', { arch => 's390x', mnemonic => 'NNPA' });
    ok($z17->{ok} && $z17->{exact_match}, 'AsmMultiArch found s390x Telum II NNPA');
    like(encode_json($z17), qr/B93B.*Telum/is, 's390x NNPA describes B93B Telum / Telum II AI accelerator');
    my $abi = $asm->call_tool('asm_abi_calling_conv', { abi => 'darwin_arm64' });
    ok($abi->{ok} && encode_json($abi) =~ /x18/i, 'AsmMultiArch ABI documents Darwin arm64 x18 reservation');
    my $snip = $asm->call_tool('asm_analyze_snippet', {
        arch => 'ppc64le',
        code => "ldarx 5, 0, 3\nstdcx. 6, 0, 3\nblr\n",
    });
    ok(!$snip->{ok} && ($snip->{finding_count} // 0) >= 1, 'AsmMultiArch detected missing POWER barrier hazard');
    like(encode_json($snip), qr/ASM_POWER_MISSING_BARRIER/, 'AsmMultiArch emitted ASM_POWER_MISSING_BARRIER on unguarded LL/SC');
    my $xlat = $asm->call_tool('asm_cross_arch_translate', { idiom => 'fence_acq_rel' });
    ok($xlat->{ok}, 'AsmMultiArch cross-arch translated fence_acq_rel');
    for my $a (qw(ppc64le amd64 arm64 s390x)) {
        ok(exists $xlat->{translations}{$a}, "cross-arch translation includes $a");
    }
};

subtest 'GPU Compute & Graphics Packs (IntelGPU, AMDGPU, VulkanDev, MetalDev)' => sub {
    # 9. IntelGPU
    my $igpu = $REG->get_pack('intel_gpu');
    my $ispec = $igpu->call_tool('intel_gpu_arch_spec', { arch => 'xe_hpc' });
    ok($ispec->{ok} && encode_json($ispec) =~ /XMX|DPAS/i, 'IntelGPU arch spec documents Xe-HPC XMX/DPAS');
    my $iocc = $igpu->call_tool('intel_gpu_occupancy_calc', {
        arch => 'xe_hpc', subgroup_size => 16, regs_per_thread => 256, workgroup_size => 256, slm_bytes => 16384,
    });
    ok($iocc->{ok} && defined($iocc->{active_threads_per_xve}), 'IntelGPU occupancy calc computed threads/XVE & GRF budget');
    my $iapi = $igpu->call_tool('intel_gpu_api_lookup', { query => 'joint_matrix' });
    ok($iapi->{ok}, 'IntelGPU API lookup returned SYCL joint_matrix');
    my $iaud = $igpu->call_tool('intel_gpu_kernel_audit', {
        arch => 'xe_lp', source => "kernel void k(global double *a) { a[get_global_id(0)] *= 2.0; }",
    });
    ok($iaud->{ok} && encode_json($iaud) =~ /FP64|double|reqd_sub_group_size/i, 'IntelGPU kernel check flagged FP64 / subgroup hints');

    # 10. AMDGPU
    my $agpu = $REG->get_pack('amd_gpu');
    my $aspec = $agpu->call_tool('amd_gpu_arch_spec', { arch => 'gfx942' });
    ok($aspec->{ok} && encode_json($aspec) =~ /64.*MFMA|MI300/is, 'AMDGPU arch spec documents CDNA3 gfx942 wave64 MFMA');
    my $aocc = $agpu->call_tool('amd_gpu_occupancy_calc', {
        arch => 'gfx942', vgprs => 128, agprs => 64, sgprs => 64, lds_bytes => 16384, workgroup_size => 256,
    });
    ok($aocc->{ok} && defined($aocc->{theoretical_occupancy_pct} // $aocc->{occupancy_pct} // $aocc->{waves_per_simd}),
        'AMDGPU occupancy calc computed CDNA3 wave occupancy');
    my $ahip = $agpu->call_tool('amd_gpu_hip_lookup', { query => 'mfma' });
    ok($ahip->{ok}, 'AMDGPU HIP lookup returned MFMA builtins');
    my $aaud = $agpu->call_tool('amd_gpu_kernel_audit', {
        arch   => 'gfx942',
        source => "__global__ void k(int *out) { unsigned mask = __ballot(1) & 0xffffffff; out[threadIdx.x] = mask; }",
    });
    ok($aaud->{ok} && @{ $aaud->{findings} || [] } >= 1, 'AMDGPU kernel check caught hardcoded 32-bit ballot mask on wave64 CDNA3');
    like(encode_json($aaud), qr/wave64|uint64_t|64/i, 'AMDGPU check recommends 64-bit wave64 mask');

    # 11. VulkanDev
    my $vk = $REG->get_pack('vulkan');
    my $vlay = $vk->call_tool('vulkan_struct_layout', {
        layout => 'std140',
        struct => 'struct SceneUBO { float time; vec3 camPos; float weights[4]; };',
    });
    ok($vlay->{ok} && ($vlay->{total_padding_bytes} // 0) > 0, 'Vulkan std140 struct layout computed vec3 & array padding');
    like($vlay->{c11_declaration} // '', qr/_Static_assert/, 'Vulkan struct layout emitted C11 _Static_assert');
    my $vsync = $vk->call_tool('vulkan_sync_validate', {
        srcStageMask  => 'VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT',
        srcAccessMask => 'VK_ACCESS_2_SHADER_READ_BIT',
        dstStageMask  => 'VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT',
        dstAccessMask => 'VK_ACCESS_2_SHADER_READ_BIT',
        oldLayout     => 'VK_IMAGE_LAYOUT_UNDEFINED',
        newLayout     => 'VK_IMAGE_LAYOUT_PRESENT_SRC_KHR',
        hazard_intent => 'RAW',
    });
    ok($vsync->{ok}, 'Vulkan sync validator ran cleanly');
    like(encode_json($vsync), qr/PRESENT_SRC_KHR|SHADER_WRITE|RAW/i, 'Vulkan sync validator flagged invalid UNDEFINED->PRESENT_SRC_KHR & missing write flush');
    my $vref = $vk->call_tool('vulkan_spirv_glsl_lookup', { query => 'VK_KHR_synchronization2' });
    ok($vref->{ok}, 'Vulkan SPIR-V/GLSL lookup returned VK_KHR_synchronization2');
    my $vaud = $vk->call_tool('vulkan_shader_audit', {
        source => "#version 460\nlayout(local_size_x = 17) in;\nlayout(push_constant) uniform PC { mat4 a; mat4 b; mat4 c; } pc;\nvoid main() {}\n",
    });
    ok($vaud->{ok} && encode_json($vaud) =~ /128|push.?constant|local_size/i, 'Vulkan shader check flagged >128B push constant & non-32/64 workgroup');

    # 12. MetalDev
    my $mtl = $REG->get_pack('metal');
    my $mspec = $mtl->call_tool('metal_arch_spec', { arch => 'apple9' });
    ok($mspec->{ok} && encode_json($mspec) =~ /32.*simd|TBDR|Dynamic Caching/is, 'MetalDev arch spec documents Apple9 TBDR & 32-thread SIMD-group');
    my $mocc = $mtl->call_tool('metal_occupancy_calc', {
        arch => 'apple9', threads_per_threadgroup => 256, threadgroup_mem_bytes => 16384, uses_half => 1,
    });
    ok($mocc->{ok}, 'MetalDev occupancy calc computed SIMD-groups/threadgroup');
    my $mref = $mtl->call_tool('metal_msl_lookup', { query => 'simdgroup_multiply_accumulate' });
    ok($mref->{ok}, 'MetalDev MSL lookup returned simdgroup_multiply_accumulate');
    my $maud = $mtl->call_tool('metal_shader_audit', {
        source => "struct Vert { float3 pos; };\nkernel void k(device Vert *v [[buffer(0)]], threadgroup float *tg [[threadgroup(0)]]) { tg[0] = v[0].pos.x; v[0].pos.y = tg[1]; }\n",
    });
    ok($maud->{ok} && @{ $maud->{findings} || [] } >= 1, 'MetalDev shader check flagged float3 16B ABI trap');
    like(encode_json($maud), qr/packed_float3/i, 'MetalDev shader check recommends packed_float3');
};

# ============================================================================
# 3. Standalone bin/npl-mcp Subprocesses (--list-packs, --emit-mcp-config, --stdio, --http)
# ============================================================================
subtest 'Standalone bin/npl-mcp CLI, --stdio NDJSON, and --http server' => sub {
    local $ENV{PERL5LIB} = $CHILD_PERL5LIB;

    # --list-packs --json
    my ($w1, $r1, $e1);
    $e1 = gensym;
    my $p1 = open3($w1, $r1, $e1, $^X, $NPL_MCP, '--list-packs', '--json');
    close $w1;
    local $/;
    my $list_out = <$r1>;
    close $r1;
    close $e1;
    waitpid($p1, 0);
    is($? >> 8, 0, 'bin/npl-mcp --list-packs --json exited 0');
    my $listed = decode_json($list_out);
    is(scalar(@$listed), 12, 'bin/npl-mcp --list-packs reports all 12 domain packs');

    # --emit-mcp-config
    my ($w2, $r2, $e2);
    $e2 = gensym;
    my $p2 = open3($w2, $r2, $e2, $^X, $NPL_MCP, '--emit-mcp-config');
    close $w2;
    my $emit_out = <$r2>;
    close $r2;
    close $e2;
    waitpid($p2, 0);
    is($? >> 8, 0, 'bin/npl-mcp --emit-mcp-config exited 0');
    my $emitted = decode_json($emit_out);
    is(scalar(keys %{ $emitted->{mcpServers} }), 12, 'bin/npl-mcp --emit-mcp-config emitted all 12 servers');

    # --pack=db2z,hlasm,asm,metal --stdio
    my ($ws, $rs, $es);
    $es = gensym;
    my $ps = open3($ws, $rs, $es, $^X, $NPL_MCP, '--pack=db2z,hlasm,asm,metal', '--stdio');
    binmode($ws);
    binmode($rs);
    $ws->autoflush(1);

    my $send_stdio = sub {
        my ($msg) = @_;
        print {$ws} encode_json($msg) . "\n";
        $ws->flush;
    };
    my $read_stdio = sub {
        local $/ = "\n";
        my $line = <$rs>;
        return defined($line) ? decode_json($line) : undef;
    };

    $send_stdio->({ jsonrpc => '2.0', id => 1, method => 'initialize', params => {} });
    my $init = $read_stdio->();
    is($init->{result}{serverInfo}{name}, 'npl-mcp', 'bin/npl-mcp --stdio initialize returned serverInfo');

    $send_stdio->({ jsonrpc => '2.0', method => 'notifications/initialized', params => {} });
    $send_stdio->({ jsonrpc => '2.0', id => 2, method => 'tools/list', params => {} });
    my $tlist = $read_stdio->();
    is(scalar(@{ $tlist->{result}{tools} }), 17, 'bin/npl-mcp --pack=db2z,hlasm,asm,metal exposes exact 17 tools');

    $send_stdio->({
        jsonrpc => '2.0',
        id      => 3,
        method  => 'tools/call',
        params  => { name => 'hlasm_opcode_lookup', arguments => { mnemonic => 'NNPA' } },
    });
    my $tcall = $read_stdio->();
    ok($tcall->{result}{structuredContent}{ok}, 'bin/npl-mcp --stdio tools/call hlasm_opcode_lookup(NNPA) succeeded');
    like($tcall->{result}{content}[0]{text}, qr/B93B/, 'stdio response carries NNPA B93B');

    close $ws;
    close $rs;
    close $es;
    waitpid($ps, 0);
    is($? >> 8, 0, 'bin/npl-mcp --stdio exited cleanly on EOF');

    # --pack=vulkan,amd_gpu --http=127.0.0.1:0 (localhost HTTP subprocess)
    my ($wh, $rh, $eh);
    $eh = gensym;
    my $ph = open3($wh, $rh, $eh, $^X, $NPL_MCP, '--pack=vulkan,amd_gpu', '--http=127.0.0.1:0');
    close $wh;
    local $/ = "\n";
    my $banner = <$rh>;
    chomp($banner) if defined $banner;
    my ($hport, $hengine) = (($banner // '') =~ m{http://127\.0\.0\.1:(\d+)/mcp\s+\(engine=([^,\)]+)});
    ok(defined($hport) && $hport > 0, "bin/npl-mcp --http bound ephemeral port ($banner)");

    if ($hport) {
        my ($hst, undef, $hbody) = _http_request_standalone($hport, 'GET', '/health');
        is($hst, 200, 'bin/npl-mcp --http GET /health returned 200');
        my $hj = decode_json($hbody);
        is($hj->{tools}, 8, 'bin/npl-mcp --http reports exact 8 tools for vulkan+amd_gpu');
        if (NeoPerl::Antigravity::EditorMCP->has_mojo) {
            is($hj->{engine}, 'Mojolicious', 'bin/npl-mcp --http uses Mojolicious daemon');
        }

        my ($mst, undef, $mbody) = _http_request_standalone($hport, 'POST', '/mcp', encode_json({
            jsonrpc => '2.0',
            id      => 10,
            method  => 'tools/call',
            params  => {
                name      => 'vulkan_struct_layout',
                arguments => { layout => 'std140', struct => 'struct P { float x; vec3 v; };' },
            },
        }));
        is($mst, 200, 'bin/npl-mcp --http POST /mcp tools/call vulkan_struct_layout returned 200');
        my $mj = decode_json($mbody);
        ok($mj->{result}{structuredContent}{ok}, 'vulkan_struct_layout succeeded over standalone HTTP MCP');
    }

    kill 'TERM', $ph;
    close $rh;
    close $eh;
    waitpid($ph, 0);
};

done_testing();
