package NeoPerl::Inference::ModelHub;

use strict;
use warnings;
use File::Spec ();
use File::Path qw(make_path);
use File::Basename qw(basename);
use NeoPerl::Inference::Config;

our $VERSION = '0.01';

my $HAS_MOJO_UA;
BEGIN {
    $HAS_MOJO_UA = eval { require Mojo::UserAgent; 1 } ? 1 : 0;
}

sub new {
    my ($class, %args) = @_;
    my $config = $args{config} || NeoPerl::Inference::Config->new(%args);
    return bless {
        config => $config,
    }, $class;
}

sub config { $_[0]{config} }

sub inspect_gguf {
    my ($self, $path) = @_;
    return { exists => 0, valid_gguf => 0, path => $path }
        unless defined $path && -f $path;

    my $size = -s $path;
    my %info = (
        exists     => 1,
        path       => $path,
        size_bytes => $size,
        size_gb    => sprintf('%.2f', $size / (1024 * 1024 * 1024)) + 0.0,
        valid_gguf => 0,
    );

    if (open my $fh, '<:raw', $path) {
        my $hdr = '';
        my $n = read($fh, $hdr, 24);
        close $fh;
        if (defined $n && $n >= 24 && substr($hdr, 0, 4) eq 'GGUF') {
            my ($ver, $tensors, $kv) = unpack('V Q< Q<', substr($hdr, 4, 20));
            $info{valid_gguf}   = 1;
            $info{gguf_version} = $ver;
            $info{tensor_count} = $tensors;
            $info{kv_count}     = $kv;
        }
    }

    return \%info;
}

sub _which {
    my ($bin) = @_;
    return NeoPerl::Inference::Config::resolve_binary($bin);
}

sub _run_capture {
    my ($resolved, @args) = @_;
    my $out = '';
    my $pid = open my $pipe, '-|';
    if (defined $pid && $pid == 0) {
        open STDERR, '>&', \*STDOUT;
        { no warnings 'exec'; exec { $resolved } ($resolved, @args); }
        exit 127;
    }
    elsif ($pid) {
        local $/;
        $out = <$pipe> // '';
        close $pipe;
        waitpid($pid, 0);
    }
    return $out;
}

sub probe_binary {
    my ($self, $bin, %opts) = @_;
    my $resolved = _which($bin);
    return {
        bin        => $bin,
        found      => 0,
        path       => undef,
        version    => '',
        semver     => '',
        build_num  => 0,
        is_prism   => 0,
        granite_ok => 0,
    } unless defined $resolved;

    my $out      = '';
    my $help_out = '';
    if (!$opts{skip_exec}) {
        $out = _run_capture($resolved, '--version');
    }

    my ($semver, $major) = ('', 0);
    if ($out =~ /\bversion:\s*v?(\d+)\.(\d+)(?:\.(\d+))?/i
        || $out =~ /\bv(\d+)\.(\d+)(?:\.(\d+))?\b/)
    {
        $major  = int($1);
        my $min = int($2);
        my $pat = defined($3) ? int($3) : 0;
        $semver = "$major.$min.$pat";
    }

    my $build_num = 0;
    if ($out =~ /\b(?:build\s+|version:\s*|b)(\d{3,6})\b/i) {
        $build_num = int($1);
    }

    my $is_prism = ($bin =~ /prism/i
        || $resolved =~ /prism/i
        || $out =~ /\b(?:prism|bonsai|PTQ1_0|PQ2_0)\b/i) ? 1 : 0;

    if (!$is_prism && !$opts{skip_exec}) {
        $help_out = _run_capture($resolved, '--help');
        if ($help_out =~ /\b(?:PTQ1_0|PQ2_0m?|prism[- ]?ml|ternary[- ]?bonsai)\b/i) {
            $is_prism = 1;
        }
    }

    my $ver_str = $out;
    $ver_str =~ s/\s+/ /g;
    $ver_str =~ s/^\s+|\s+$//g;

    return {
        bin        => $bin,
        found      => 1,
        path       => $resolved,
        version    => substr($ver_str, 0, 140),
        semver     => $semver,
        build_num  => $build_num,
        is_prism   => $is_prism,
        granite_ok => ($major >= 1 || $build_num >= 9704) ? 1 : 0,
    };
}

sub download_recipes {
    my ($self) = @_;
    my $dir = $self->{config}->model_dir;
    return [
        {
            role        => 'embedder',
            model_id    => 'nomic-ai/nomic-embed-text-v1.5-GGUF',
            filename    => 'nomic-embed-text-v1.5.Q8_0.gguf',
            url         => 'https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf',
            quant       => 'Q8_0',
            approx_gb   => 0.4,
            fork        => 'upstream llama.cpp or in-process libllama',
            command     => "hf download nomic-ai/nomic-embed-text-v1.5-GGUF nomic-embed-text-v1.5.Q8_0.gguf --local-dir $dir",
        },
        {
            role        => 'memory_writer',
            model_id    => 'tencent/Hy-Memory-30B-A3B-GGUF',
            filename    => 'Hy-Memory-30B-A3B-Q8_0-expsIQ2_XXS.gguf',
            url         => 'https://huggingface.co/tencent/Hy-Memory-30B-A3B-GGUF/resolve/main/Hy-Memory-30B-A3B-Q8_0-expsIQ2_XXS.gguf',
            quant       => 'Q8_0-expsIQ2_XXS (alt: Q4_K_M)',
            approx_gb   => 9.1,
            fork        => 'upstream llama.cpp',
            command     => "hf download tencent/Hy-Memory-30B-A3B-GGUF Hy-Memory-30B-A3B-Q8_0-expsIQ2_XXS.gguf --local-dir $dir",
        },
        {
            role            => 'vision_doc',
            model_id        => 'ibm-granite/granite-vision-4.1-4b-GGUF',
            filename        => 'granite-vision-4.1-4b-Q4_K_M.gguf',
            url             => 'https://huggingface.co/ibm-granite/granite-vision-4.1-4b-GGUF/resolve/main/granite-vision-4.1-4b-Q4_K_M.gguf',
            mmproj_filename => 'mmproj-model-f16.gguf',
            mmproj_url      => 'https://huggingface.co/ibm-granite/granite-vision-4.1-4b-GGUF/resolve/main/mmproj-model-f16.gguf',
            quant           => 'Q4_K_M + mmproj-model-f16',
            approx_gb       => 3.5,
            fork            => 'upstream llama.cpp >= b9704 / v1.0.0 (--mmproj required)',
            command         => "hf download ibm-granite/granite-vision-4.1-4b-GGUF granite-vision-4.1-4b-Q4_K_M.gguf mmproj-model-f16.gguf --local-dir $dir",
        },
        {
            role        => 'worker_small',
            model_id    => 'prism-ml/Ternary-Bonsai-2-27B-gguf',
            filename    => 'Ternary-Bonsai-2-27B-PTQ1_0.gguf',
            url         => 'https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/main/Ternary-Bonsai-2-27B-PTQ1_0.gguf',
            quant       => 'PTQ1_0 (5.95 GB) / PQ2_0 (7.21 GB) / Q2_0 (upstream)',
            approx_gb   => 6.0,
            fork        => 'Prism ML llama.cpp fork (isolated server_bin)',
            command     => "hf download prism-ml/Ternary-Bonsai-2-27B-gguf Ternary-Bonsai-2-27B-PTQ1_0.gguf --local-dir $dir",
        },
    ];
}

sub download_role {
    my ($self, $role, %opts) = @_;
    return { ok => 0, error => 'role is required' } unless defined $role && length $role;

    if ($role eq 'all') {
        my @results;
        my $all_ok = 1;
        for my $r ($self->{config}->role_names) {
            my $res = $self->download_role($r, %opts);
            $all_ok = 0 unless $res->{ok};
            push @results, $res;
        }
        return { ok => $all_ok, role => 'all', results => \@results };
    }

    my ($rec) = grep { $_->{role} eq $role } @{ $self->download_recipes() };
    return { ok => 0, role => $role, error => "Unknown inference role: $role" } unless $rec;

    my $dir = $opts{dir} // $self->{config}->model_dir;
    my @targets = (
        {
            kind     => 'model',
            filename => $rec->{filename},
            url      => $rec->{url},
            dest     => File::Spec->catfile($dir, $rec->{filename}),
        },
    );
    if (defined $rec->{mmproj_url} && length $rec->{mmproj_url}) {
        push @targets, {
            kind     => 'mmproj',
            filename => $rec->{mmproj_filename},
            url      => $rec->{mmproj_url},
            dest     => File::Spec->catfile($dir, $rec->{mmproj_filename}),
        };
    }

    if ($opts{dry_run}) {
        return {
            ok      => 1,
            role    => $role,
            dry_run => 1,
            dir     => $dir,
            files   => [
                map {
                    +{
                        %$_,
                        command => [ 'curl', '-fSL', '-C', '-', '-o', $_->{dest}, $_->{url} ],
                    }
                } @targets
            ],
        };
    }

    my $curl = $opts{curl_bin} // _which('curl');
    return { ok => 0, role => $role, error => 'curl binary not found on PATH' } unless defined $curl;

    eval { make_path($dir) unless -d $dir };
    if ($@) {
        return { ok => 0, role => $role, error => "Failed to create model directory $dir: $@" };
    }

    my @files_out;
    for my $t (@targets) {
        my $dest = $t->{dest};
        if (!$opts{force} && -f $dest) {
            my $existing = $self->inspect_gguf($dest);
            if ($existing->{valid_gguf}) {
                push @files_out, {
                    %$t,
                    ok      => 1,
                    skipped => 1,
                    gguf    => $existing,
                };
                next;
            }
        }

        my @cmd = ($curl, '-fSL', '-C', '-', '-o', $dest, $t->{url});
        my $rc = system(@cmd);
        if ($rc != 0) {
            my $code = ($rc == -1) ? -1 : ($rc >> 8);
            return {
                ok    => 0,
                role  => $role,
                error => "curl failed (exit $code) downloading $t->{url}",
                files => \@files_out,
            };
        }

        my $gguf = $self->inspect_gguf($dest);
        if (!$gguf->{valid_gguf}) {
            return {
                ok    => 0,
                role  => $role,
                error => "Downloaded file failed GGUF header check: $dest",
                gguf  => $gguf,
                files => \@files_out,
            };
        }

        push @files_out, {
            %$t,
            ok      => 1,
            skipped => 0,
            gguf    => $gguf,
        };
    }

    return {
        ok    => 1,
        role  => $role,
        dir   => $dir,
        files => \@files_out,
    };
}

sub _llama_bridge_status {
    if (eval { require NeoPerl::Core; 1 } && defined(&NeoPerl::Core::LlamaBridge::status)) {
        my $st = eval { NeoPerl::Core::LlamaBridge::status() };
        return $st if ref($st) eq 'HASH';
    }
    return {
        available    => 0,
        model_loaded => 0,
        n_embd       => 0,
        library_path => '',
        model_path   => '',
        error        => 'NeoPerl::Core::LlamaBridge unavailable',
    };
}

sub doctor_report {
    my ($self, %opts) = @_;
    my $st     = $self->status_report(%opts);
    my $bridge = _llama_bridge_status();

    my @roles_diag;
    my $ready_count = 0;

    for my $r (@{ $st->{roles} }) {
        my $role  = $r->{role};
        my $rc    = $self->{config}->role_config($role);
        my $model = $r->{model_file};
        my $mm    = $r->{mmproj_file};
        my $bin   = $r->{binary};

        my @issues;
        my $ready = 0;

        if ($r->{transport} eq 'remote_http') {
            if (defined $r->{remote_url} && $r->{remote_url} =~ m{^https?://}i) {
                $ready = 1;
            }
            else {
                push @issues, 'remote_http configured without valid http(s):// remote_url';
            }
        }
        elsif ($role eq 'embedder') {
            push @issues, "Missing or invalid GGUF: $rc->{model_path}" unless $model->{valid_gguf};
            if (!$bridge->{available} && !$bin->{found}) {
                push @issues, "Neither libllama (dlopen) nor $rc->{server_bin} found";
            }
            $ready = ($model->{valid_gguf} && ($bridge->{available} || $bin->{found})) ? 1 : 0;
        }
        elsif ($role eq 'vision_doc') {
            push @issues, "Missing or invalid GGUF: $rc->{model_path}" unless $model->{valid_gguf};
            my $mm_ok = ($mm && $mm->{valid_gguf}) ? 1 : 0;
            push @issues, "Missing or invalid mmproj GGUF: " . ($rc->{mmproj_path} // '<unset>') unless $mm_ok;
            if (!$bin->{found}) {
                push @issues, "Missing binary: $rc->{server_bin}";
            }
            elsif (!$opts{skip_exec} && !$bin->{granite_ok}) {
                push @issues, "llama-server too old for Granite-Vision (need >= b9704 or v1.0.0)";
            }
            $ready = ($model->{valid_gguf} && $mm_ok && $bin->{found} && ($opts{skip_exec} || $bin->{granite_ok})) ? 1 : 0;
        }
        elsif ($role eq 'worker_small') {
            push @issues, "Missing or invalid GGUF: $rc->{model_path}" unless $model->{valid_gguf};
            my $is_q2 = NeoPerl::Inference::Config::_is_q2_0_model($rc->{model_path});
            if (!$bin->{found}) {
                push @issues, "Missing binary: $rc->{server_bin}";
            }
            elsif (!$is_q2 && ($rc->{backend_fork} // '') eq 'prism-ml' && !$opts{skip_exec} && !$bin->{is_prism}) {
                push @issues, "Binary $bin->{path} does not appear to be Prism ML fork (required for PTQ1_0/PQ2_0)";
            }
            $ready = ($model->{valid_gguf} && $bin->{found} && !@issues) ? 1 : 0;
        }
        else {
            # memory_writer
            push @issues, "Missing or invalid GGUF: $rc->{model_path}" unless $model->{valid_gguf};
            push @issues, "Missing binary: $rc->{server_bin}" unless $bin->{found};
            $ready = ($model->{valid_gguf} && $bin->{found}) ? 1 : 0;
        }

        $ready_count++ if $ready;
        push @roles_diag, {
            %$r,
            ready  => $ready,
            issues => \@issues,
        };
    }

    my $total = scalar(@roles_diag);
    return {
        model_dir               => $st->{model_dir},
        ram_budget_gb           => $st->{ram_budget_gb},
        accelerator             => $st->{accelerator},
        local_ai_skipped_reason => $st->{local_ai_skipped_reason},
        llama_bridge            => $bridge,
        ready_count             => $ready_count,
        total_roles             => $total,
        all_ready               => ($ready_count == $total && $total > 0) ? 1 : 0,
        roles                   => \@roles_diag,
    };
}

sub format_doctor_text {
    my ($self, %opts) = @_;
    my $doc = $self->doctor_report(%opts);
    my $br  = $doc->{llama_bridge} || {};
    my $acc = $doc->{accelerator} // 'none';
    my $skp = $doc->{local_ai_skipped_reason} // '';
    my @lines = (
        sprintf("NeoPerl::MT Inference Doctor (%d/%d roles ready, RAM budget: %.1f GB, accelerator: %s)",
            $doc->{ready_count}, $doc->{total_roles}, $doc->{ram_budget_gb}, $acc),
        "Model directory: $doc->{model_dir}",
        (length($skp) ? ("Local AI: skipped ($skp)") : ()),
        sprintf("In-process libllama: %s%s",
            $br->{available} ? 'available' : 'unavailable',
            ($br->{available} && length($br->{library_path} // '')) ? " ($br->{library_path})" : ''),
        "",
    );
    for my $r (@{ $doc->{roles} }) {
        my $tag = $r->{ready} ? 'READY' : 'MISSING';
        push @lines, sprintf("  [%-7s] %-14s %-22s transport=%-15s fork=%s",
            $tag, $r->{role}, $r->{display_name}, $r->{transport}, $r->{backend_fork});
        for my $iss (@{ $r->{issues} || [] }) {
            push @lines, "            - $iss";
        }
    }
    return join("\n", @lines) . "\n";
}

sub check_hf_reachable {
    my ($self, $repo_id, %opts) = @_;
    return { reachable => 0, error => 'offline' } if $opts{offline};
    my $url = "https://huggingface.co/api/models/$repo_id";
    if ($HAS_MOJO_UA) {
        my $ua = Mojo::UserAgent->new;
        $ua->request_timeout(5);
        my $tx = eval { $ua->head($url) };
        if ($tx && $tx->result->is_success) {
            return { reachable => 1, status => $tx->result->code, engine => 'Mojo::UserAgent' };
        }
        return { reachable => 0, status => ($tx ? $tx->result->code : 0), engine => 'Mojo::UserAgent' };
    }
    return { reachable => 0, error => 'Mojo::UserAgent not loaded' };
}

sub status_report {
    my ($self, %opts) = @_;
    my @roles_report;
    for my $role ($self->{config}->role_names) {
        my $rc = $self->{config}->role_config($role);
        my $gguf = $self->inspect_gguf($rc->{model_path});
        my $mmproj = (defined $rc->{mmproj_path} && length $rc->{mmproj_path})
            ? $self->inspect_gguf($rc->{mmproj_path})
            : undef;
        my $bin = $self->probe_binary($rc->{server_bin}, skip_exec => $opts{skip_exec});
        push @roles_report, {
            role             => $role,
            display_name     => $rc->{display_name},
            model_id         => $rc->{model_id},
            transport        => $rc->{transport},
            backend_fork     => $rc->{backend_fork},
            estimated_ram_gb => $rc->{estimated_ram_gb},
            pinned           => $rc->{pinned} ? 1 : 0,
            model_file       => $gguf,
            mmproj_file      => $mmproj,
            binary           => $bin,
            remote_url       => $rc->{remote_url},
        };
    }

    return {
        model_dir               => $self->{config}->model_dir,
        ram_budget_gb           => $self->{config}->ram_budget_gb,
        accelerator             => $self->{config}->accelerator,
        local_ai_skipped_reason => $self->{config}->local_ai_skipped_reason,
        roles                   => \@roles_report,
        recipes                 => $self->download_recipes(),
    };
}

sub format_report_text {
    my ($self, %opts) = @_;
    my $rep = $self->status_report(%opts);
    my $acc = $rep->{accelerator} // 'none';
    my $skp = $rep->{local_ai_skipped_reason} // '';
    my @lines = (
        sprintf("NeoPerl::MT ModelHub (RAM budget: %s GB, accelerator: %s)", $rep->{ram_budget_gb}, $acc),
        "Model directory: $rep->{model_dir}",
        (length($skp) ? ("Local AI: skipped ($skp)") : ()),
        "",
    );
    for my $r (@{ $rep->{roles} }) {
        my $mstat = $r->{model_file}{valid_gguf}
            ? sprintf("GGUF v%d (%.2f GB)", $r->{model_file}{gguf_version}, $r->{model_file}{size_gb})
            : ($r->{model_file}{exists} ? 'present (non-GGUF)' : 'not downloaded');
        my $ver_tag = '';
        if ($r->{binary}{semver} && $r->{binary}{build_num}) {
            $ver_tag = " [v$r->{binary}{semver}/b$r->{binary}{build_num}]";
        }
        elsif ($r->{binary}{semver}) {
            $ver_tag = " [v$r->{binary}{semver}]";
        }
        elsif ($r->{binary}{build_num}) {
            $ver_tag = " [b$r->{binary}{build_num}]";
        }
        my $bstat = $r->{binary}{found}
            ? ($r->{binary}{path} . $ver_tag)
            : "$r->{binary}{bin} (not on PATH)";
        push @lines, sprintf(
            "  %-14s %-22s transport=%-14s fork=%-8s model=%s bin=%s",
            $r->{role}, $r->{display_name}, $r->{transport}, $r->{backend_fork}, $mstat, $bstat
        );
    }
    push @lines, "", "Download recipes:";
    for my $rec (@{ $rep->{recipes} }) {
        push @lines, "  [$rec->{role}] $rec->{command}";
    }
    return join("\n", @lines) . "\n";
}

1;

__END__

=head1 NAME

NeoPerl::Inference::ModelHub - GGUF inspection, binary probing, and download recipes

=head1 SYNOPSIS

    use NeoPerl::Inference::ModelHub;

    my $mhub = NeoPerl::Inference::ModelHub->new(config => $cfg);
    my $report = $mhub->status_report();
    print $mhub->format_report_text();

=head1 DESCRIPTION

C<NeoPerl::Inference::ModelHub> inspects local GGUF model headers and sizes,
probes installed upstream and Prism ML C<llama-server> executables, and formats
status and download recipes for C<:ModelHub>.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
