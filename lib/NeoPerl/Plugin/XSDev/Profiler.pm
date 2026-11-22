package NeoPerl::Plugin::XSDev::Profiler;

use strict;
use warnings;

use File::Basename ();
use File::Spec ();

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    return bless {
        runner       => $opts{runner},
        last_profile => undef,
    }, $class;
}

sub last_profile { $_[0]{last_profile} }

# -------------------------------------------------------------------------
# 1. Raw Cachegrind / Callgrind file parser (cachegrind.out.* / callgrind.out.*)
# -------------------------------------------------------------------------

sub parse_cachegrind_raw {
    my ($self, $text, %opts) = @_;
    $text = '' unless defined $text;

    my @events;
    my %totals;
    my %files;       # file => line => { Ir => ..., D1mr => ..., DLmr => ..., Bcm => ... }
    my %fn_totals;   # "file:fn" => { file, func, line, events => {...} }
    my %file_names;  # Callgrind compressed file id map: (1) path
    my %fn_names;    # Callgrind compressed fn id map: (1) func

    my $cur_file = '';
    my $cur_fn   = '';
    my $cur_line = 0;

    for my $raw_line (split /\n/, $text) {
        $raw_line =~ s/\r\z//;
        next if $raw_line eq '' || $raw_line =~ /^#/;

        if ($raw_line =~ /^events:\s*(.+)$/) {
            @events = split /\s+/, $1;
            next;
        }
        if ($raw_line =~ /^summary:\s*(.+)$/) {
            my @vals = split /\s+/, $1;
            for my $i (0 .. $#events) {
                $totals{ $events[$i] } = ($vals[$i] || 0) + 0;
            }
            next;
        }
        if ($raw_line =~ /^(?:fl|fi|fe)=\((\d+)\)\s*(.*)$/) {
            my ($id, $nm) = ($1, $2);
            $file_names{$id} = $nm if length $nm;
            $cur_file = $file_names{$id} // '';
            next;
        }
        if ($raw_line =~ /^(?:fl|fi|fe)=(.+)$/) {
            $cur_file = $1;
            next;
        }
        if ($raw_line =~ /^fn=\((\d+)\)\s*(.*)$/) {
            my ($id, $nm) = ($1, $2);
            $fn_names{$id} = $nm if length $nm;
            $cur_fn = $fn_names{$id} // '';
            next;
        }
        if ($raw_line =~ /^fn=(.+)$/) {
            $cur_fn = $1;
            next;
        }
        next if $raw_line =~ /^(?:cfn|cfl|cfi|calls|cob|ob|desc|cmd|pid|part|positions|creator|version|totals):?=/i
             || $raw_line =~ /^(?:desc|cmd|pid|part|positions|creator|version|totals):/i;

        # Data line: <line_pos> <count0> <count1> ...
        if ($raw_line =~ /^([+-]?\d+|\*)\s+(.+)$/) {
            my ($lpos, $rest) = ($1, $2);
            if ($lpos eq '*') {
                # Same line as previous
            }
            elsif ($lpos =~ /^[+-]/) {
                $cur_line += $lpos;
            }
            else {
                $cur_line = $lpos + 0;
            }
            next unless length($cur_file) && $cur_file ne '???' && $cur_line > 0;

            my @nums = split /\s+/, $rest;
            my $mapped_file = $cur_file;
            my $mapped_line = $cur_line;
            if ($self->{runner} && !$opts{no_map}) {
                my $loc = $self->{runner}->map_location($cur_file, $cur_line);
                $mapped_file = $loc->{file};
                $mapped_line = $loc->{line};
            }

            my $entry = ($files{$mapped_file}{$mapped_line} ||= {
                file   => $mapped_file,
                line   => $mapped_line,
                func   => $cur_fn,
                events => {},
            });

            my $fkey = "$mapped_file:$cur_fn";
            my $fent = ($fn_totals{$fkey} ||= {
                file   => $mapped_file,
                func   => $cur_fn,
                line   => $mapped_line,
                events => {},
            });
            $fent->{line} = $mapped_line if $mapped_line < $fent->{line};

            for my $i (0 .. $#events) {
                my $ev  = $events[$i];
                my $val = ($nums[$i] // 0) + 0;
                $entry->{events}{$ev} += $val;
                $fent->{events}{$ev}  += $val;
            }
        }
    }

    # Compute summary totals if missing from file
    if (!%totals) {
        for my $f (keys %files) {
            for my $ln (keys %{ $files{$f} }) {
                my $evh = $files{$f}{$ln}{events};
                for my $k (keys %$evh) {
                    $totals{$k} += $evh->{$k};
                }
            }
        }
    }

    my $total_ir   = $totals{Ir}   || 0;
    my $total_d1mr = $totals{D1mr} || 0;
    my $total_dlmr = $totals{DLmr} || $totals{LLmr} || 0;
    my $total_bcm  = $totals{Bcm}  || 0;

    my @hotspots;
    for my $f (keys %files) {
        for my $ln (keys %{ $files{$f} }) {
            my $row = $files{$f}{$ln};
            my $ev  = $row->{events};
            my $ir   = $ev->{Ir}   || 0;
            my $d1mr = $ev->{D1mr} || 0;
            my $dlmr = $ev->{DLmr} || $ev->{LLmr} || 0;
            my $bcm  = $ev->{Bcm}  || 0;

            $row->{ir}       = $ir;
            $row->{d1mr}     = $d1mr;
            $row->{dlmr}     = $dlmr;
            $row->{bcm}      = $bcm;
            $row->{ir_pct}   = $total_ir   > 0 ? ($ir   * 100.0 / $total_ir)   : 0.0;
            $row->{d1mr_pct} = $total_d1mr > 0 ? ($d1mr * 100.0 / $total_d1mr) : 0.0;
            $row->{dlmr_pct} = $total_dlmr > 0 ? ($dlmr * 100.0 / $total_dlmr) : 0.0;
            $row->{bcm_pct}  = $total_bcm  > 0 ? ($bcm  * 100.0 / $total_bcm)  : 0.0;
            $row->{label}    = _format_metric_label($row);

            push @hotspots, $row if $ir > 0 || $dlmr > 0 || $bcm > 0;
        }
    }

    @hotspots = sort { $b->{ir_pct} <=> $a->{ir_pct} || $b->{ir} <=> $a->{ir} } @hotspots;

    my @functions = sort {
        ($b->{events}{Ir} || 0) <=> ($a->{events}{Ir} || 0)
    } values %fn_totals;
    for my $fn (@functions) {
        my $ir = $fn->{events}{Ir} || 0;
        $fn->{ir_pct} = $total_ir > 0 ? ($ir * 100.0 / $total_ir) : 0.0;
    }

    my $profile = {
        ok        => 1,
        tool      => 'cachegrind',
        events    => \@events,
        totals    => \%totals,
        files     => \%files,
        hotspots  => \@hotspots,
        functions => \@functions,
    };
    $self->{last_profile} = $profile;
    return $profile;
}

# -------------------------------------------------------------------------
# 2. cg_annotate text parser (summary + annotated source lines)
# -------------------------------------------------------------------------

sub parse_cg_annotate {
    my ($self, $text, %opts) = @_;
    $text = '' unless defined $text;

    my @events;
    my %totals;
    my @functions;
    my %files;
    my @hotspots;
    my $cur_file;
    my $in_source = 0;
    my $line_num  = 0;

    for my $raw (split /\n/, $text) {
        $raw =~ s/\r\z//;

        # Header like: Ir                  I1mr        DLmr ...
        if (!@events && $raw =~ /^\s*(Ir\b(?:\s+[A-Za-z0-9_]+)*)\s*$/) {
            @events = split /\s+/, $1;
            next;
        }

        # Annotated file banner: -- User-annotated source: foo.c --
        if ($raw =~ /^--\s+(?:User-annotated|Auto-annotated)\s+source:\s+(.+?)\s+--$/) {
            $cur_file  = $1;
            $in_source = 1;
            $line_num  = 0;
            next;
        }

        # Line number marker: -- line 120 ----
        if ($in_source && $raw =~ /^--\s+line\s+(\d+)\b/) {
            $line_num = $1 - 1;
            next;
        }

        # Program totals: 123,456 (100.0%) ... PROGRAM TOTALS
        if ($raw =~ /PROGRAM TOTALS/) {
            my @nums = ($raw =~ /([\d,]+)\s*(?:\([^)]*\))?/g);
            for my $i (0 .. $#events) {
                next unless defined $nums[$i];
                (my $n = $nums[$i]) =~ tr/,//d;
                $totals{ $events[$i] } = $n + 0;
            }
            next;
        }

        # Summary table row: 14,200 (14.2%) 380 (3.8%)  c/vec_simd.c:npl_vec_cosine
        if (!$in_source && $raw =~ /^\s*([\d,]+)\s*\(\s*([\d.]+)%\s*\)(.*)\s+(\S+:\S+)\s*$/) {
            my ($ir_s, $ir_pct, $mid, $loc_str) = ($1, $2, $3, $4);
            $ir_s =~ tr/,//d;
            my ($f, $fn) = split /:/, $loc_str, 2;
            push @functions, {
                file   => $f,
                func   => $fn // '',
                ir     => $ir_s + 0,
                ir_pct => $ir_pct + 0,
            };
            next;
        }

        # Annotated source line:
        #   14,200 (14.2%)  380 ( 3.8%)  110 (1.1%)   for (size_t i = 0; ...)
        # or dot-placeholder lines:  .   .   .   int x = 0;
        if ($in_source && defined $cur_file) {
            if ($raw =~ /^\s*(?:(?:[\d,]+\s*(?:\(\s*[\d.]+%\s*\))?|\.)\s+)+(.*)$/) {
                $line_num++;
                my $prefix = substr($raw, 0, length($raw) - length($1));
                my @cols = ($prefix =~ /([\d,]+\s*(?:\(\s*[\d.]+%\s*\))?|\.)/g);
                next unless @cols;
                my %ev;
                my %pct;
                my $has_data = 0;
                for my $i (0 .. $#events) {
                    last if $i > $#cols;
                    my $tok = $cols[$i];
                    next if $tok eq '.';
                    if ($tok =~ /^([\d,]+)(?:\s*\(\s*([\d.]+)%\s*\))?$/) {
                        (my $n = $1) =~ tr/,//d;
                        $ev{ $events[$i] } = $n + 0;
                        $pct{ $events[$i] } = defined $2 ? ($2 + 0) : undef;
                        $has_data = 1 if $n > 0;
                    }
                }
                next unless $has_data;

                my $ir   = $ev{Ir}   || 0;
                my $d1mr = $ev{D1mr} || 0;
                my $dlmr = $ev{DLmr} || $ev{LLmr} || 0;
                my $bcm  = $ev{Bcm}  || 0;

                my $row = {
                    file     => $cur_file,
                    line     => $line_num,
                    events   => \%ev,
                    ir       => $ir,
                    d1mr     => $d1mr,
                    dlmr     => $dlmr,
                    bcm      => $bcm,
                    ir_pct   => defined $pct{Ir}   ? $pct{Ir}   : ($totals{Ir}   ? $ir   * 100.0 / $totals{Ir}   : 0),
                    d1mr_pct => defined $pct{D1mr} ? $pct{D1mr} : ($totals{D1mr} ? $d1mr * 100.0 / $totals{D1mr} : 0),
                    dlmr_pct => defined $pct{DLmr} ? $pct{DLmr} : ($totals{DLmr} ? $dlmr * 100.0 / $totals{DLmr} : 0),
                    bcm_pct  => defined $pct{Bcm}  ? $pct{Bcm}  : ($totals{Bcm}  ? $bcm  * 100.0 / $totals{Bcm}  : 0),
                };
                $row->{label} = _format_metric_label($row);
                $files{$cur_file}{$line_num} = $row;
                push @hotspots, $row;
            }
        }
    }

    @hotspots = sort { $b->{ir_pct} <=> $a->{ir_pct} || $b->{ir} <=> $a->{ir} } @hotspots;
    my $profile = {
        ok        => 1,
        tool      => 'cg_annotate',
        events    => \@events,
        totals    => \%totals,
        files     => \%files,
        hotspots  => \@hotspots,
        functions => \@functions,
    };
    $self->{last_profile} = $profile;
    return $profile;
}

# -------------------------------------------------------------------------
# 3. Linux perf POWER PMU parser (PM_RUN_CYC, PM_DATA_FROM_L3, PM_BR_MPRED_CMPL, PM_VSU_FIN)
# -------------------------------------------------------------------------

sub parse_perf_stat {
    my ($self, $text) = @_;
    $text = '' unless defined $text;

    my %counters;
    my $elapsed_s;

    for my $line (split /\n/, $text) {
        if ($line =~ /^\s*([\d,._]+)\s+([A-Za-z0-9_.:\/-]+)(?:\s+#\s*(.*))?$/) {
            my ($val_s, $ev, $comment) = ($1, $2, $3 // '');
            next if $ev eq 'seconds';
            $val_s =~ tr/,_//d;
            next unless $val_s =~ /^\d+(?:\.\d+)?$/;
            $counters{$ev} = {
                value   => $val_s + 0,
                comment => $comment,
            };
        }
        elsif ($line =~ /^\s*([\d.]+)\s+seconds\s+time\s+elapsed/) {
            $elapsed_s = $1 + 0;
        }
    }

    my $cyc   = ($counters{PM_RUN_CYC}       || $counters{cycles}       || {})->{value} || 0;
    my $inst  = ($counters{PM_RUN_INST_CMPL} || $counters{instructions} || {})->{value} || 0;
    my $l3    = ($counters{PM_DATA_FROM_L3}  || $counters{'cache-misses'} || {})->{value} || 0;
    my $brmp  = ($counters{PM_BR_MPRED_CMPL} || $counters{'branch-misses'} || {})->{value} || 0;
    my $vsu   = ($counters{PM_VSU_FIN}       || {})->{value} || 0;

    my $ipc     = $cyc  > 0 ? ($inst / $cyc)           : 0;
    my $l3_pki  = $inst > 0 ? ($l3   * 1000.0 / $inst) : 0;
    my $br_pki  = $inst > 0 ? ($brmp * 1000.0 / $inst) : 0;
    my $vsu_pct = $inst > 0 ? ($vsu  * 100.0  / $inst) : 0;

    return {
        ok        => (scalar(keys %counters) > 0 ? 1 : 0),
        tool      => 'perf_pmu',
        is_power  => (exists $counters{PM_RUN_CYC} || exists $counters{PM_VSU_FIN} || exists $counters{PM_DATA_FROM_L3}) ? 1 : 0,
        counters  => \%counters,
        elapsed_s => $elapsed_s,
        derived   => {
            ipc           => sprintf('%.2f', $ipc) + 0,
            l3_mpki       => sprintf('%.3f', $l3_pki) + 0,
            br_mpki       => sprintf('%.3f', $br_pki) + 0,
            vsx_vsu_pct   => sprintf('%.2f', $vsu_pct) + 0,
        },
        summary_line => sprintf(
            'IPC %.2f | L3 MPKI %.2f | BR MPKI %.2f | VSU %.1f%%',
            $ipc, $l3_pki, $br_pki, $vsu_pct
        ),
    };
}

sub parse_perf_annotate {
    my ($self, $text, %opts) = @_;
    $text = '' unless defined $text;
    my $file = $opts{file} || '';
    my @hotspots;
    my %files;

    for my $line (split /\n/, $text) {
        if ($line =~ /^\s*([\d.]+)\s*:\s*(?:[0-9a-fA-F]+:)?\s*(?:(\S+):(\d+)|line\s+(\d+))?\s*(.*)$/) {
            my $pct = $1 + 0;
            my $f   = $2 || $file;
            my $ln  = ($3 || $4 || 0) + 0;
            next unless $pct > 0 && $ln > 0;
            my $row = {
                file   => $f,
                line   => $ln,
                ir_pct => $pct,
                ir     => int($pct * 1000),
                dlmr_pct => 0,
                bcm_pct  => 0,
                label  => sprintf('[%.1f%% PMU]', $pct),
            };
            $files{$f}{$ln} = $row;
            push @hotspots, $row;
        }
    }
    @hotspots = sort { $b->{ir_pct} <=> $a->{ir_pct} } @hotspots;
    return {
        ok       => 1,
        tool     => 'perf_annotate',
        files    => \%files,
        hotspots => \@hotspots,
    };
}

# -------------------------------------------------------------------------
# 4. Live Cachegrind & POWER PMU Runners
# -------------------------------------------------------------------------

sub run_cachegrind {
    my ($self, $target_argv, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});
    if (!$tools->{valgrind}) {
        return {
            ok    => 0,
            error => 'valgrind not found on target host (configure xs_remote_host for Linux Cachegrind)',
        };
    }

    my $out_dir  = $runner->ensure_build_dir('cachegrind');
    my $out_file = $opts{remote}
        ? ($runner->remote_workdir . '/.neoperl-build/cachegrind/cachegrind.out.npl')
        : File::Spec->catfile($out_dir, 'cachegrind.out.npl');

    if ($opts{remote}) {
        $runner->run_remote_shell('mkdir -p ' . $runner->remote_workdir . '/.neoperl-build/cachegrind');
    }

    my @cmd = (
        $tools->{valgrind},
        '--tool=cachegrind',
        '--branch-sim=yes',
        "--cachegrind-out-file=$out_file",
        @$target_argv,
    );

    my $res = $runner->run_cmd(\@cmd,
        remote  => $opts{remote},
        sync    => $opts{sync},
        timeout => $opts{timeout} || 180,
    );

    my $raw_text = '';
    if ($opts{remote}) {
        my $cat = $runner->run_remote_shell("cat '$out_file'");
        $raw_text = $cat->{stdout} if $cat->{ok};
    }
    elsif (-f $out_file && open my $fh, '<', $out_file) {
        local $/;
        $raw_text = <$fh> // '';
        close $fh;
    }

    if (!length $raw_text) {
        return {
            ok        => 0,
            error     => 'cachegrind produced no output file',
            exit_code => $res->{exit_code},
            stderr    => $res->{stderr},
        };
    }

    my $parsed = $self->parse_cachegrind_raw($raw_text);
    $parsed->{out_file}   = $out_file;
    $parsed->{elapsed_ms} = $res->{elapsed_ms};
    $parsed->{stderr}     = $res->{stderr};

    # Also capture cg_annotate text summary if available
    if ($tools->{cg_annotate}) {
        my $cga = $runner->run_cmd([ $tools->{cg_annotate}, '--auto=no', $out_file ], remote => $opts{remote});
        $parsed->{cg_annotate_text} = $cga->{stdout} if $cga->{ok};
    }
    return $parsed;
}

sub run_perf_power {
    my ($self, $target_argv, %opts) = @_;
    my $runner = $self->{runner} or return { ok => 0, error => 'no Runner configured' };
    my $tools  = $runner->detect_tools(remote => $opts{remote});
    if (!$tools->{perf}) {
        return {
            ok    => 0,
            error => 'linux perf not found on target host',
        };
    }

    my $events = $tools->{is_power}
        ? 'PM_RUN_CYC,PM_RUN_INST_CMPL,PM_DATA_FROM_L3,PM_BR_MPRED_CMPL,PM_VSU_FIN'
        : 'cycles,instructions,cache-misses,branch-misses';

    my @cmd = ($tools->{perf}, 'stat', '-e', $events, '--', @$target_argv);
    my $res = $runner->run_cmd(\@cmd, remote => $opts{remote}, timeout => $opts{timeout} || 120);

    # Fallback to generic counters if POWER PMU events are restricted
    if (!$res->{ok} && $tools->{is_power}) {
        @cmd = ($tools->{perf}, 'stat', '-e', 'cycles,instructions,cache-misses,branch-misses', '--', @$target_argv);
        $res = $runner->run_cmd(\@cmd, remote => $opts{remote}, timeout => $opts{timeout} || 120);
    }

    my $parsed = $self->parse_perf_stat(($res->{stderr} // '') . "\n" . ($res->{stdout} // ''));
    $parsed->{raw_output} = ($res->{stderr} // '') . ($res->{stdout} // '');
    $parsed->{elapsed_ms} = $res->{elapsed_ms};
    return $parsed;
}

# -------------------------------------------------------------------------
# 5. Gutter Heatbar & Inline Virtual Metric Extmark Painter (xs_perf)
# -------------------------------------------------------------------------

sub _format_metric_label {
    my ($row) = @_;
    my @parts;
    push @parts, sprintf('%.1f%% Ir', $row->{ir_pct} || 0);
    if (($row->{dlmr_pct} || 0) >= 0.1) {
        push @parts, sprintf('%.1f%% DLmr', $row->{dlmr_pct});
    }
    elsif (($row->{d1mr_pct} || 0) >= 0.1) {
        push @parts, sprintf('%.1f%% D1mr', $row->{d1mr_pct});
    }
    if (($row->{bcm_pct} || 0) >= 0.1) {
        push @parts, sprintf('%.1f%% Bcm', $row->{bcm_pct});
    }
    return '[' . join(' | ', @parts) . ']';
}

sub heat_tier {
    my ($self, $ir_pct) = @_;
    $ir_pct ||= 0;
    return ('█', 'XSPerfHot',  'hot')  if $ir_pct >= 10.0;
    return ('▓', 'XSPerfWarm', 'warm') if $ir_pct >= 3.0;
    return ('▒', 'XSPerfMild', 'mild') if $ir_pct >= 0.5;
    return ('░', 'XSPerfCool', 'cool');
}

sub paint_heatbars {
    my ($self, $buf, $profile, %opts) = @_;
    return { ok => 0, painted => 0, error => 'missing buffer or profile' }
        unless $buf && $profile && ref($profile->{files}) eq 'HASH';

    my $ns = $opts{namespace} || 'xs_perf';
    my $min_pct = defined $opts{min_pct} ? $opts{min_pct} : 0.1;

    # Clear existing xs_perf extmarks on buffer (support both NeoPerl::Buffer and NeoPerl::Core::Buffer)
    my $core_buf = ($buf->can('core') && $buf->core) ? $buf->core : $buf;
    if ($buf->can('clear_namespace')) {
        $buf->clear_namespace($ns);
    }
    elsif ($core_buf->can('clear_namespace')) {
        $core_buf->clear_namespace($ns);
    }

    # Match target buffer path against profiled file entries
    my $buf_path = $opts{file_path};
    $buf_path = $buf->path     if !defined($buf_path) && $buf->can('path');
    $buf_path = $buf->name     if !defined($buf_path) && $buf->can('name');
    $buf_path = $buf->filename if !defined($buf_path) && $buf->can('filename');
    $buf_path //= '';
    my $buf_base = length($buf_path) ? File::Basename::basename($buf_path) : '';

    my $line_map;
    if (length($buf_path) && exists $profile->{files}{$buf_path}) {
        $line_map = $profile->{files}{$buf_path};
    }
    elsif (length($buf_base)) {
        for my $pf (keys %{ $profile->{files} }) {
            if (File::Basename::basename($pf) eq $buf_base) {
                $line_map = $profile->{files}{$pf};
                last;
            }
        }
    }
    elsif (scalar(keys %{ $profile->{files} }) == 1) {
        my ($only) = keys %{ $profile->{files} };
        $line_map = $profile->{files}{$only};
    }

    return { ok => 1, painted => 0, marks => [] } unless $line_map;

    my @marks;
    for my $ln (sort { $a <=> $b } keys %$line_map) {
        my $row = $line_map->{$ln};
        my $pct = $row->{ir_pct} || 0;
        next if $pct < $min_pct;

        my ($sign, $hl, $tier) = $self->heat_tier($pct);
        my $label = $row->{label} || _format_metric_label($row);

        my %mark = (
            namespace => $ns,
            line      => $ln - 1,     # 0-based line index for Buffer extmarks
            line_1    => $ln,
            col       => 0,
            sign_text => $sign,
            sign_hl   => $hl,
            virt_text => "  $label",
            virt_hl   => $hl,
            virt_pos  => 'eol',
            priority  => 40,
            tier      => $tier,
            ir_pct    => $pct,
            dlmr_pct  => $row->{dlmr_pct} || 0,
            bcm_pct   => $row->{bcm_pct}  || 0,
        );

        if ($buf->can('set_extmark')) {
            eval { $buf->set_extmark($ns, $ln - 1, 0, \%mark) };
            if ($@) {
                eval { $buf->set_extmark(%mark) };
            }
        }
        elsif ($core_buf->can('set_extmark')) {
            eval { $core_buf->set_extmark($ns, $ln - 1, 0, \%mark) };
        }
        push @marks, \%mark;
    }

    return {
        ok      => 1,
        painted => scalar(@marks),
        marks   => \@marks,
    };
}

sub telescope_items {
    my ($self, $profile, %opts) = @_;
    $profile ||= $self->{last_profile};
    return [] unless $profile && ref($profile->{hotspots}) eq 'ARRAY';
    my $limit = $opts{limit} || 100;

    my @items;
    for my $h (@{ $profile->{hotspots} }) {
        last if @items >= $limit;
        my ($sign, $hl, $tier) = $self->heat_tier($h->{ir_pct});
        my $base = File::Basename::basename($h->{file} || '?');
        my $fn   = $h->{func} ? " ($h->{func})" : '';
        push @items, {
            label    => sprintf('%s %5.1f%% Ir  %s:%d%s  %s', $sign, $h->{ir_pct} || 0, $base, $h->{line}, $fn, $h->{label} || ''),
            detail   => $h->{label} || '',
            path     => $h->{file},
            file     => $h->{file},
            line     => ($h->{line} || 1) - 1,
            line_1   => $h->{line},
            col      => 0,
            badge    => $sign,
            tier     => $tier,
            hl       => $hl,
            ir_pct   => $h->{ir_pct}   || 0,
            dlmr_pct => $h->{dlmr_pct} || 0,
            bcm_pct  => $h->{bcm_pct}  || 0,
        };
    }
    return \@items;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::XSDev::Profiler - Cachegrind, Callgrind, and POWER PMU profiler

=head1 SYNOPSIS

    use NeoPerl::Plugin::XSDev::Profiler;

    my $prof = NeoPerl::Plugin::XSDev::Profiler->new(runner => $runner);
    my $data = $prof->parse_cachegrind_raw($raw_cg_text);
    $prof->paint_heatbars($buf, $data);

=head1 DESCRIPTION

Parses Cachegrind/Callgrind raw output, C<cg_annotate> reports, and Linux
C<perf> IBM POWER PMU hardware counters (C<PM_RUN_CYC>, C<PM_RUN_INST_CMPL>,
C<PM_DATA_FROM_L3>, C<PM_BR_MPRED_CMPL>, C<PM_VSU_FIN>), maps C<xsubpp>
C<#line> coordinates back to C<.xs> sources, paints color-coded gutter heatbars
and EOL inline metrics in extmark namespace C<xs_perf>, and supplies sorted
hotspot lists for Telescope.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
