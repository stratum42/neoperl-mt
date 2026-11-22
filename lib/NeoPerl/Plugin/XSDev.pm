package NeoPerl::Plugin::XSDev;

use strict;
use warnings;

use File::Basename ();
use File::Spec ();

use NeoPerl::Plugin::XSDev::Runner;
use NeoPerl::Plugin::XSDev::Profiler;
use NeoPerl::Plugin::XSDev::Sanitizer;
use NeoPerl::Plugin::XSDev::Debugger;
use NeoPerl::Plugin::XSDev::PGO;
use NeoPerl::Plugin::XSDev::Power;

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $runner = $opts{runner} || NeoPerl::Plugin::XSDev::Runner->new(
        workdir            => $opts{workdir},
        xs_remote_host     => $opts{xs_remote_host},
        xs_remote_workdir  => $opts{xs_remote_workdir},
        xs_remote_ssh_opts => $opts{xs_remote_ssh_opts},
        build_root         => $opts{build_root},
    );

    my $self = bless {
        editor       => undef,
        mcp          => $opts{mcp},
        memory_store => $opts{memory_store},
        telescope    => $opts{telescope},
        runner       => $runner,
        profiler     => NeoPerl::Plugin::XSDev::Profiler->new(runner  => $runner),
        sanitizer    => NeoPerl::Plugin::XSDev::Sanitizer->new(runner => $runner),
        debugger     => NeoPerl::Plugin::XSDev::Debugger->new(runner  => $runner),
        pgo          => NeoPerl::Plugin::XSDev::PGO->new(runner       => $runner),
        power        => NeoPerl::Plugin::XSDev::Power->new(runner     => $runner),
    }, $class;

    if ($opts{editor}) {
        $self->attach($opts{editor}, %opts);
    }
    elsif ($opts{mcp}) {
        $self->register_mcp_tools($opts{mcp});
    }

    return $self;
}

sub runner    { $_[0]{runner} }
sub profiler  { $_[0]{profiler} }
sub sanitizer { $_[0]{sanitizer} }
sub debugger  { $_[0]{debugger} }
sub pgo       { $_[0]{pgo} }
sub power     { $_[0]{power} }

sub _buf_text {
    my ($buf) = @_;
    return '' unless $buf;
    return $buf->get_text if $buf->can('get_text');
    return $buf->text     if $buf->can('text');
    if ($buf->can('get_lines') && $buf->can('line_count')) {
        return join("\n", @{ $buf->get_lines(0, $buf->line_count) }) . "\n";
    }
    return '';
}

# -------------------------------------------------------------------------
# Editor Attachment: Options, Commands, Keymaps, XSDEV Panel, MCP 19-23
# -------------------------------------------------------------------------

sub attach {
    my ($self, $editor, %opts) = @_;
    return $self unless $editor;
    $self->{editor}       = $editor;
    $self->{mcp}        ||= $opts{mcp}          || $editor->plugin('mcp');
    $self->{memory_store} ||= $opts{memory_store} || $editor->plugin('memory');
    $self->{telescope}  ||= $opts{telescope}    || $editor->plugin('telescope');

    $editor->register_plugin('xsdev', $self);

    # Sync workdir & optional remote SSH configuration from Editor options
    my $rhost = $editor->get_option('xs_remote_host');
    my $rdir  = $editor->get_option('xs_remote_workdir');
    if ((defined $rhost && length $rhost) || (defined $rdir && length $rdir)) {
        $self->{runner}->configure_remote(
            xs_remote_host    => $rhost,
            xs_remote_workdir => $rdir,
        );
    }

    $editor->on('OptionSet', sub {
        my (%ev) = @_;
        if (($ev{name} || '') eq 'xs_remote_host' || ($ev{name} || '') eq 'xs_remote_workdir') {
            $self->{runner}->configure_remote(
                xs_remote_host    => $editor->get_option('xs_remote_host'),
                xs_remote_workdir => $editor->get_option('xs_remote_workdir'),
            );
        }
    });

    # Command Center XSDEV tab provider
    $editor->register_command_center_provider('xsdev', sub {
        return $self->panel_state();
    });

    # Statusline summary
    $editor->register_statusline_provider('xsdev', sub {
        my $st = $self->{debugger}->state;
        return "DBG:$st->{backend}" if $st->{active} && $st->{backend};
        my $pr = $self->{profiler}->last_profile;
        return "CG:" . scalar(@{ $pr->{hotspots} || [] }) . "hot" if $pr;
        return undef;
    });

    $self->_register_commands($editor);
    $self->_register_keymaps($editor);
    $self->register_mcp_tools($self->{mcp}) if $self->{mcp};

    if (my $wk = $editor->plugin('whichkey')) {
        if ($wk->can('register_group')) {
            $wk->register_group('<leader>x', 'XS / POWER8+ Workbench');
            $wk->register_group('<leader>d', 'XS Debugger (GDB/LLDB)');
        }
    }

    return $self;
}

sub _register_commands {
    my ($self, $editor) = @_;
    my $ex = $editor->excmd;

    $ex->register_command('XSCachegrind', sub {
        my ($ed, $ctx) = @_;
        my @argv = @{ $ctx->{argv} || [] };
        my $res;
        if (@argv) {
            $res = $self->{profiler}->run_cachegrind(\@argv, remote => $self->{runner}->is_remote_enabled);
        }
        elsif ($self->{profiler}->last_profile) {
            $res = $self->{profiler}->last_profile;
        }
        else {
            return { ok => 0, message => 'Usage: :XSCachegrind <cmd...>' };
        }
        if ($res->{ok}) {
            my $buf = $ed->current_buffer;
            $self->{profiler}->paint_heatbars($buf, $res) if $buf;
            $self->open_hotspot_picker($res);
        }
        $ed->notify($res->{ok} ? sprintf('Cachegrind: %d hotspot line(s)', scalar(@{ $res->{hotspots} || [] })) : $res->{error}, $res->{ok} ? 'info' : 'error');
        return $res;
    }, desc => 'Run Cachegrind and paint gutter heatbars + Telescope hotspot picker');

    $ex->register_command('XSPerf', sub {
        my ($ed, $ctx) = @_;
        my @argv = @{ $ctx->{argv} || [] };
        return { ok => 0, message => 'Usage: :XSPerf <cmd...>' } unless @argv;
        my $res = $self->{profiler}->run_perf_power(\@argv, remote => $self->{runner}->is_remote_enabled);
        $ed->notify($res->{ok} ? "Perf PMU: $res->{summary_line}" : ($res->{error} || 'perf failed'), $res->{ok} ? 'info' : 'error');
        return $res;
    }, desc => 'Run Linux perf / IBM POWER PMU hardware counters');

    $ex->register_command('XSVal', sub {
        my ($ed, $ctx) = @_;
        my @argv = @{ $ctx->{argv} || [] };
        return { ok => 0, message => 'Usage: :XSVal <cmd...>' } unless @argv;
        my $res = $self->{sanitizer}->run_valgrind(\@argv,
            remote => $self->{runner}->is_remote_enabled,
            use_perl_suppressions => 1,
        );
        $self->_publish_sanitizer_results($res, record_memory => 1) if $res->{ok};
        return $res;
    }, desc => 'Run Valgrind Memcheck and map findings to .xs/.c diagnostics');

    $ex->register_command('XSAsan', sub {
        my ($ed, $ctx) = @_;
        my $target = $ctx->{argv}[0];
        my $buf    = $ed->current_buffer;
        $target ||= ($buf && $buf->path) ? $buf->path : undef;
        return { ok => 0, message => 'Usage: :XSAsan <c_file>' } unless defined $target;
        my $res = $self->{sanitizer}->run_asan_harness($target);
        $self->_publish_sanitizer_results($res, record_memory => 1) if $res->{ok};
        return $res;
    }, desc => 'Build & run isolated ASan/UBSan harness in .neoperl-build/asan');

    $ex->register_command('XSTsan', sub {
        my ($ed, $ctx) = @_;
        my $target = $ctx->{argv}[0];
        my $buf    = $ed->current_buffer;
        $target ||= ($buf && $buf->path) ? $buf->path : undef;
        return { ok => 0, message => 'Usage: :XSTsan <c_file>' } unless defined $target;
        my $res = $self->{sanitizer}->run_tsan_harness($target);
        $self->_publish_sanitizer_results($res, record_memory => 1) if $res->{ok};
        return $res;
    }, desc => 'Build & run isolated TSan harness in .neoperl-build/tsan');

    $ex->register_command('XSDebug', sub {
        my ($ed, $ctx) = @_;
        my ($bin, $fn) = @{ $ctx->{argv} || [] };
        $ed->layout->open_command_center('xsdev') if $ed->layout && $ed->layout->can('open_command_center');
        if (defined $bin && length $bin) {
            my $res = $self->{debugger}->capture_backtrace($bin,
                (defined $fn ? (break_func => $fn) : ()),
                remote => $self->{runner}->is_remote_enabled,
            );
            my $buf = $ed->current_buffer;
            $self->{debugger}->paint_debug_marks($buf) if $buf;
            $ed->notify($res->{ok} ? "XSDebug ($res->{backend}): " . scalar(@{ $res->{backtrace} }) . ' frame(s)' : ($res->{error} || 'Debug failed'), $res->{ok} ? 'info' : 'error');
            return $res;
        }
        return { ok => 1, message => 'XSDEV panel opened', data => $self->panel_state };
    }, desc => 'Open XSDEV debugger panel or capture GDB/MI / LLDB backtrace');

    $ex->register_command('XSInspectSV', sub {
        my ($ed, $ctx) = @_;
        my $expr = $ctx->{args} || 'sv';
        return $self->{debugger}->inspect_sv($expr);
    }, desc => 'Inspect live Perl SV*/AV*/HV* via Perl_sv_dump');

    $ex->register_command('XSPgo', sub {
        my ($ed, $ctx) = @_;
        my $target = $ctx->{argv}[0];
        my $buf    = $ed->current_buffer;
        $target ||= ($buf && $buf->path) ? $buf->path : undef;
        return { ok => 0, message => 'Usage: :XSPgo <c_file>' } unless defined $target;
        my $res = $self->{pgo}->run_c_pgo($target);
        my $msg = $res->{ok}
            ? sprintf('PGO (%s): %.2fms -> %.2fms (%.1f%%)', $res->{family}, $res->{baseline_ms}, $res->{pgo_ms}, $res->{speedup_pct})
            : ($res->{error} || 'PGO failed');
        $ed->notify($msg, $res->{ok} ? 'info' : 'error');
        return $res;
    }, desc => 'Run isolated 2-stage Clang/GCC PGO pipeline in .neoperl-build/');

    $ex->register_command('XSPgoPromote', sub {
        my ($ed, $ctx) = @_;
        my $dest = $ctx->{argv}[0];
        my $res  = $self->{pgo}->promote(defined $dest ? (dest_binary => $dest) : ());
        $ed->notify($res->{ok} ? "PGO flags promoted: $res->{flag_file}" : $res->{error}, $res->{ok} ? 'info' : 'error');
        return $res;
    }, desc => 'Promote verified PGO profile flags from .neoperl-build/pgo-use');

    $ex->register_command('XSAsm', sub {
        my ($ed, $ctx) = @_;
        my $target = $ctx->{argv}[0];
        return { ok => 0, message => 'Usage: :XSAsm <object_or_binary>' } unless defined $target;
        my $res = $self->{power}->disassemble($target, remote => $self->{runner}->is_remote_enabled);
        if ($res->{ok}) {
            $self->_open_asm_split($res);
        }
        $ed->notify($res->{ok}
            ? sprintf('XSAsm: %d insns (%d VSX, %d TOC, %d barriers)',
                $res->{summary}{total_insns}, $res->{summary}{vsx_count},
                $res->{summary}{toc_count},   $res->{summary}{barrier_count})
            : ($res->{error} || 'XSAsm failed'), $res->{ok} ? 'info' : 'error');
        return $res;
    }, desc => 'Open side-by-side ELFv2 objdump disassembly highlighting VSX, TOC, barriers');

    $ex->register_command('XSVecReport', sub {
        my ($ed, $ctx) = @_;
        my $buf    = $ed->current_buffer;
        my $target = $ctx->{argv}[0] || ($buf ? $buf->path : undef);
        return { ok => 0, message => 'Usage: :XSVecReport <c_file>' } unless defined $target;
        my $res = $self->{power}->run_vec_report($target, remote => $self->{runner}->is_remote_enabled);
        if ($res->{ok} && $buf) {
            $self->{power}->paint_vec_annotations($buf, $res);
        }
        $ed->notify(sprintf('XSVecReport: %d vectorized, %d missed', $res->{optimized} || 0, $res->{missed} || 0), 'info');
        return $res;
    }, desc => 'Compile with -fopt-info-vec / -Rpass=loop-vectorize and annotate loops inline');

    $ex->register_command('XSPowerAudit', sub {
        my ($ed, $ctx) = @_;
        my $buf    = $ed->current_buffer;
        my $target = $ctx->{argv}[0];
        my $res;
        if (defined $target && -f $target) {
            $res = $self->{power}->audit_file($target);
        }
        elsif ($buf) {
            $res = $self->{power}->audit_source(_buf_text($buf), $buf->path || $buf->name || '<buffer>');
        }
        else {
            return { ok => 0, message => 'No file or buffer to audit' };
        }
        if ($res->{ok} && $buf) {
            my @diags = map {
                +{
                    line     => ($_->{line} || 1) - 1,
                    col      => ($_->{col}  || 1) - 1,
                    severity => $_->{severity},
                    code     => $_->{rule},
                    message  => "$_->{message} [$_->{rule}]",
                    source   => 'xs_power_audit',
                }
            } @{ $res->{findings} || [] };
            $ed->set_diagnostics($buf, 'xs_power_audit', \@diags);
        }
        my $tot = $res->{summary}{total} || 0;
        $ed->notify(sprintf('XSPowerAudit: %d finding(s)', $tot), $tot ? 'warn' : 'info');
        return $res;
    }, desc => 'Audit C/XS source for IBM POWER8+ ppc64le portability traps');

    return;
}

sub _register_keymaps {
    my ($self, $editor) = @_;
    my $modal = $editor->modal or return;
    return unless $modal->can('map');

    $modal->map('n', '<leader>xc', sub { $self->open_hotspot_picker() }, desc => 'Cachegrind hotspot picker');
    $modal->map('n', '<leader>xd', sub {
        $editor->layout->toggle_command_center('xsdev') if $editor->layout;
    }, desc => 'Toggle XSDEV Command Center tab');
    $modal->map('n', '<leader>xa', sub {
        $editor->notify('Use :XSAsm <object_or_binary> for ELFv2 disassembly split', 'info');
    }, desc => 'XSAsm ELFv2 disassembly');
    $modal->map('n', '<leader>db', sub {
        my $buf = $editor->current_buffer or return;
        my $win = $editor->current_window or return;
        my $res = $self->{debugger}->toggle_breakpoint($buf->path || $buf->name || '<buffer>', $win->cursor_line + 1);
        $self->{debugger}->paint_debug_marks($buf);
        $editor->notify("Breakpoint $res->{action} at line " . ($win->cursor_line + 1), 'info');
    }, desc => 'Toggle XS debugger gutter breakpoint');
    $modal->map('n', '<leader>dn', sub { $self->{debugger}->step_over() },    desc => 'Debugger step over');
    $modal->map('n', '<leader>di', sub { $self->{debugger}->step_into() },    desc => 'Debugger step into');
    $modal->map('n', '<leader>do', sub { $self->{debugger}->step_out() },     desc => 'Debugger step out');
    $modal->map('n', '<leader>dc', sub { $self->{debugger}->continue_run() }, desc => 'Debugger continue');

    return;
}

sub _open_asm_split {
    my ($self, $asm_res) = @_;
    my $ed = $self->{editor} or return;
    my $buf = $ed->create_buffer(name => '[XSAsm]', buftype => 'nofile', filetype => 'asm');
    my @text_lines = map { $_->{text} } @{ $asm_res->{lines} || [] };
    if ($buf->can('set_lines')) {
        $buf->set_lines(0, $buf->line_count, \@text_lines);
    }
    # Paint VSX/TOC/barrier highlights on disassembly split
    for my $i (0 .. $#{ $asm_res->{lines} || [] }) {
        my $l = $asm_res->{lines}[$i];
        next if ($l->{hl} || 'Normal') eq 'Normal';
        if ($buf->can('set_extmark')) {
            eval {
                $buf->set_extmark('xs_asm', $i, 0, {
                    hl_group  => $l->{hl},
                    virt_text => (@{ $l->{tags} || [] } ? '  [' . join(',', @{ $l->{tags} }) . ']' : undef),
                    virt_hl   => $l->{hl},
                    virt_pos  => 'eol',
                    priority  => 30,
                });
            };
        }
    }
    if ($ed->layout && $ed->layout->can('vsplit')) {
        $ed->layout->vsplit($buf->id);
    }
    return $buf;
}

sub open_hotspot_picker {
    my ($self, $profile) = @_;
    my $items = $self->{profiler}->telescope_items($profile);
    my $ed    = $self->{editor} or return $items;
    my $tel   = $self->{telescope} || $ed->plugin('telescope');
    if ($tel && $tel->can('open_custom')) {
        $tel->open_custom('Cachegrind / PMU Hotspots', $items, sub {
            my ($sel) = @_;
            return unless $sel && defined($sel->{path} // $sel->{file});
            $ed->jump_to($sel->{path} // $sel->{file}, $sel->{line} // 0, $sel->{col} // 0);
        });
    }
    return $items;
}

sub _publish_sanitizer_results {
    my ($self, $res, %opts) = @_;
    my $findings = $res->{findings} || [];
    my $ed       = $self->{editor};

    if ($ed) {
        my $buf = $ed->current_buffer;
        if ($buf) {
            my $diags = $self->{sanitizer}->to_diagnostics($findings);
            my @ed_diags = map {
                +{
                    line     => ($_->{line} || 1) - 1,
                    col      => ($_->{col}  || 1) - 1,
                    severity => $_->{severity},
                    code     => $_->{kind},
                    message  => $_->{message},
                    source   => $_->{source},
                }
            } @$diags;
            $ed->set_diagnostics($buf, 'xs_' . ($res->{tool} || 'sanitizer'), \@ed_diags);
        }
    }

    if ($opts{record_memory} && @$findings) {
        my $store = $opts{memory_store} || $self->{memory_store}
            || ($ed ? $ed->plugin('memory') : undef);
        if ($store && $store->can('add_memory')) {
            my $top = $findings->[0];
            eval {
                $store->add_memory({
                    scope_level  => 'file',
                    file_path    => $top->{file} || '',
                    symbol_name  => $top->{func} || '',
                    category     => 'gotcha',
                    content      => sprintf('%s (%s) at %s:%d: %s',
                        uc($res->{tool} || 'SAN'), $top->{kind} || 'finding',
                        $top->{file} || '?', $top->{line} || 0, $top->{message} || ''),
                    tags         => [ 'xsdev', $res->{tool} || 'sanitizer', $top->{kind} || 'bug' ],
                    confidence   => 0.90,
                    source_event => 'xs_sanitizer',
                });
            };
        }
    }

    return scalar(@$findings);
}

sub panel_state {
    my ($self) = @_;
    my $dbg = $self->{debugger}->state;
    my $pr  = $self->{profiler}->last_profile;
    return {
        tools     => $self->{runner}->detect_tools,
        remote    => {
            enabled => $self->{runner}->is_remote_enabled,
            host    => $self->{runner}->remote_host,
            workdir => $self->{runner}->remote_workdir,
        },
        debugger  => {
            %$dbg,
            breakpoints => $self->{debugger}->list_breakpoints,
            watches     => $self->{debugger}{watches},
        },
        profiler  => {
            tool     => $pr ? $pr->{tool} : undef,
            hotspots => $pr ? [ @{ $pr->{hotspots} || [] }[ 0 .. ($#{ $pr->{hotspots} || [] } > 19 ? 19 : $#{ $pr->{hotspots} || [] }) ] ] : [],
            totals   => $pr ? $pr->{totals} : {},
        },
        sanitizer => {
            last_tool => $self->{sanitizer}->last_tool,
            findings  => $self->{sanitizer}->last_findings,
        },
        pgo       => $self->{pgo}->last_report,
        power     => {
            asm_summary => $self->{power}->last_asm ? $self->{power}->last_asm->{summary} : undef,
            vec_report  => $self->{power}->last_vec_report,
            audit       => $self->{power}->last_audit,
        },
    };
}

# -------------------------------------------------------------------------
# Editor MCP Tools 19-23
# -------------------------------------------------------------------------

sub register_mcp_tools {
    my ($self, $mcp) = @_;
    return 0 unless $mcp && $mcp->can('register_tool');
    $self->{mcp} = $mcp;

    # 19. neoperl_xs_profile
    $mcp->register_tool('neoperl_xs_profile', {
        description => 'Run or parse Cachegrind/Callgrind or Linux perf POWER PMU profiling and return per-line hotspots (optional heatbar painting).',
        properties  => {
            tool       => { type => 'string' },
            raw_text   => { type => 'string' },
            target_cmd => { type => 'array', items => { type => 'string' } },
            file_path  => { type => 'string' },
            paint      => { type => 'boolean' },
            remote     => { type => 'boolean' },
        },
    }, sub {
        my ($args) = @_;
        my $tool = lc($args->{tool} || 'cachegrind');
        my $res;
        if (defined $args->{raw_text}) {
            if ($tool eq 'perf' || $tool eq 'perf_pmu') {
                $res = $self->{profiler}->parse_perf_stat($args->{raw_text});
            }
            elsif ($tool eq 'cg_annotate') {
                $res = $self->{profiler}->parse_cg_annotate($args->{raw_text});
            }
            else {
                $res = $self->{profiler}->parse_cachegrind_raw($args->{raw_text});
            }
        }
        elsif (ref($args->{target_cmd}) eq 'ARRAY' && @{ $args->{target_cmd} }) {
            $res = ($tool eq 'perf' || $tool eq 'perf_pmu')
                ? $self->{profiler}->run_perf_power($args->{target_cmd}, remote => $args->{remote})
                : $self->{profiler}->run_cachegrind($args->{target_cmd}, remote => $args->{remote});
        }
        else {
            $res = $self->{profiler}->last_profile || { ok => 0, error => 'provide raw_text or target_cmd' };
        }
        if ($args->{paint} && $res->{ok} && $self->{editor}) {
            my $buf = (defined $args->{file_path})
                ? $self->{editor}->find_buffer_by_path($args->{file_path})
                : $self->{editor}->current_buffer;
            $self->{profiler}->paint_heatbars($buf, $res, file_path => $args->{file_path}) if $buf;
        }
        return $res;
    });

    # 20. neoperl_xs_sanitize
    $mcp->register_tool('neoperl_xs_sanitize', {
        description => 'Run or parse Valgrind Memcheck, ASan/UBSan, or TSan diagnostics in isolated .neoperl-build/ with .xs #line reverse mapping.',
        properties  => {
            tool          => { type => 'string' },
            c_source      => { type => 'string' },
            file_path     => { type => 'string' },
            target_cmd    => { type => 'array', items => { type => 'string' } },
            raw_text      => { type => 'string' },
            record_memory => { type => 'boolean' },
            remote        => { type => 'boolean' },
        },
    }, sub {
        my ($args) = @_;
        my $tool = lc($args->{tool} || 'asan');
        my $res;
        if (defined $args->{raw_text}) {
            my $findings = $tool eq 'tsan'     ? $self->{sanitizer}->parse_tsan($args->{raw_text})
                         : $tool eq 'valgrind' ? $self->{sanitizer}->parse_valgrind($args->{raw_text})
                         :                       $self->{sanitizer}->parse_asan_ubsan($args->{raw_text});
            $res = { ok => 1, tool => $tool, clean => (@$findings == 0 ? 1 : 0), findings => $findings };
        }
        elsif ($tool eq 'tsan') {
            $res = $self->{sanitizer}->run_tsan_harness($args->{c_source} // $args->{file_path} // '');
        }
        elsif ($tool eq 'valgrind') {
            $res = $self->{sanitizer}->run_valgrind($args->{target_cmd} || [], remote => $args->{remote});
        }
        else {
            $res = $self->{sanitizer}->run_asan_harness($args->{c_source} // $args->{file_path} // '');
        }
        $self->_publish_sanitizer_results($res, record_memory => $args->{record_memory}) if $res->{ok};
        return $res;
    });

    # 21. neoperl_xs_backtrace
    $mcp->register_tool('neoperl_xs_backtrace', {
        description => 'Capture or parse GDB/MI3 or LLDB backtrace, locals, my_perl threads, POWER registers (r0-r31, vs0-vs63), and Perl SV* dumps.',
        properties  => {
            binary     => { type => 'string' },
            break_func => { type => 'string' },
            break_file => { type => 'string' },
            break_line => { type => 'integer' },
            args       => { type => 'array', items => { type => 'string' } },
            backend    => { type => 'string' },
            sv_expr    => { type => 'string' },
            sv_dump    => { type => 'string' },
            remote     => { type => 'boolean' },
        },
    }, sub {
        my ($args) = @_;
        if (defined $args->{sv_dump}) {
            return {
                ok => 1,
                sv => $self->{debugger}->inspect_sv($args->{sv_expr} || 'sv', dump_text => $args->{sv_dump}),
            };
        }
        if (defined $args->{binary} && length $args->{binary}) {
            return $self->{debugger}->capture_backtrace($args->{binary},
                break_func => $args->{break_func},
                break_file => $args->{break_file},
                break_line => $args->{break_line},
                args       => $args->{args},
                backend    => $args->{backend},
                remote     => $args->{remote},
            );
        }
        return { ok => 1, state => $self->{debugger}->state };
    });

    # 22. neoperl_xs_pgo
    $mcp->register_tool('neoperl_xs_pgo', {
        description => 'Run isolated 2-stage Clang or GCC Profile-Guided Optimization in .neoperl-build/{pgo-gen,pgo-use}/ and report timing delta.',
        properties  => {
            c_source  => { type => 'string' },
            file_path => { type => 'string' },
            family    => { type => 'string' },
            power_cpu => { type => 'string' },
            runs      => { type => 'integer' },
            promote   => { type => 'boolean' },
        },
    }, sub {
        my ($args) = @_;
        my $src = defined $args->{c_source} ? $args->{c_source} : $args->{file_path};
        return { ok => 0, error => 'provide c_source or file_path' } unless defined $src && length $src;
        my $res = $self->{pgo}->run_c_pgo($src,
            family    => $args->{family},
            power_cpu => $args->{power_cpu},
            runs      => $args->{runs} || 3,
        );
        if ($res->{ok} && $args->{promote}) {
            $res->{promotion} = $self->{pgo}->promote();
        }
        return $res;
    });

    # 23. neoperl_xs_arch_audit
    $mcp->register_tool('neoperl_xs_arch_audit', {
        description => 'Audit C/XS source files for IBM POWER8+ ppc64le portability traps (unsigned char, hardcoded 4 KiB pages, weak memory barriers, missing SMT yields, altivec macro collisions).',
        properties  => {
            path  => { type => 'string' },
            text  => { type => 'string' },
            files => { type => 'array', items => { type => 'string' } },
        },
    }, sub {
        my ($args) = @_;
        if (defined $args->{text}) {
            return $self->{power}->audit_source($args->{text}, $args->{path} || '<mcp>');
        }
        if (ref($args->{files}) eq 'ARRAY' && @{ $args->{files} }) {
            my @results = map { $self->{power}->audit_file($_) } @{ $args->{files} };
            my $total = 0;
            $total += ($_->{summary}{total} || 0) for @results;
            return { ok => 1, files => \@results, total_findings => $total, clean => ($total == 0 ? 1 : 0) };
        }
        if (defined $args->{path} && -f $args->{path}) {
            return $self->{power}->audit_file($args->{path});
        }
        if ($self->{editor} && $self->{editor}->current_buffer) {
            my $b = $self->{editor}->current_buffer;
            return $self->{power}->audit_source(_buf_text($b), $b->path || $b->name || '<buffer>');
        }
        return { ok => 0, error => 'provide text, path, or files' };
    });

    return 5;
}

sub shutdown {
    my ($self) = @_;
    $self->{debugger}->stop_session() if $self->{debugger};
    return 1;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::XSDev - XS systems engineering and IBM POWER8+ workbench plugin

=head1 SYNOPSIS

    use NeoPerl::Plugin::XSDev;

    my $xsdev = NeoPerl::Plugin::XSDev->new(editor => $editor, mcp => $mcp);
    my $audit = $xsdev->power->audit_file('c/vec_simd.c');

=head1 DESCRIPTION

Unifies local and optional remote SSH C/XS engineering workflows inside
C<NeoPerl::Editor>: Cachegrind/Callgrind and Linux C<perf> POWER PMU gutter
heatbars (C<:XSCachegrind>, C<:XSPerf>), isolated C<.neoperl-build/>
Valgrind Memcheck / ASan / UBSan / TSan harnesses with C<xsubpp> C<#line>
reverse mapping (C<:XSVal>, C<:XSAsan>, C<:XSTsan>), interactive GDB/MI3 and
LLDB debugging with POWER registers and Perl C<SV*> inspection (C<:XSDebug>),
two-stage Clang/GCC PGO (C<:XSPgo>, C<:XSPgoPromote>), ELFv2 disassembly and
vectorization/portability auditing (C<:XSAsm>, C<:XSVecReport>,
C<:XSPowerAudit>), the C<XSDEV> Command Center tab, and Editor MCP tools 19
through 23.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
