package NeoPerl::Plugin::Git;

use strict;
use warnings;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use File::Spec;
use Cwd qw(abs_path);

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        editor     => $opts{editor},
        cwd        => $opts{cwd} || ($opts{editor} ? $opts{editor}->cwd : '.'),
        repo_root  => undef,
        branch     => '',
        status     => {},     # rel_path => badge ('M','A','D','?','R','U')
        hunks      => {},     # buf_id => [ { old_start, old_count, new_start, new_count, kind, old_lines, new_lines }, ... ]
        baselines  => {},     # buf_id => \@head_lines
        git_bin    => $opts{git_bin} || 'git',
    }, $class;

    if ($opts{editor}) {
        $self->attach($opts{editor});
    }
    return $self;
}

sub attach {
    my ($self, $editor) = @_;
    $self->{editor} = $editor;
    $self->{cwd}    = $editor->cwd;
    $editor->register_plugin('git', $self);

    $self->refresh;

    $editor->on('BufReadPost', sub {
        my (%ev) = @_;
        $self->update_buffer($ev{buf}) if $ev{buf};
    });
    $editor->on('BufWritePost', sub {
        my (%ev) = @_;
        $self->refresh;
        $self->update_buffer($ev{buf}) if $ev{buf};
    });
    $editor->on('TextChanged', sub {
        my (%ev) = @_;
        $self->update_buffer($ev{buf}, use_cached_baseline => 1) if $ev{buf};
    });
    $editor->on('TextChangedI', sub {
        my (%ev) = @_;
        $self->update_buffer($ev{buf}, use_cached_baseline => 1) if $ev{buf};
    });

    $editor->register_statusline_provider('git', sub {
        return {
            is_repo => $self->is_git_repo,
            branch  => $self->{branch},
            changed => scalar(keys %{ $self->{status} }),
        };
    });

    $editor->modal->map('n', '<leader>gp', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return;
        my $win = $ed->current_window;
        $self->preview_hunk($buf, $win ? $win->cursor_line : 0);
    }, desc => 'Preview Git hunk at cursor');

    $editor->modal->map('n', '<leader>gr', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return;
        my $win = $ed->current_window;
        my $ok = $self->reset_hunk($buf, $win ? $win->cursor_line : 0);
        $ed->notify($ok ? 'Reset Git hunk' : 'No Git hunk at cursor', 'info');
    }, desc => 'Reset Git hunk at cursor');

    $editor->excmd->register_command('Git', sub {
        my ($ed, $a) = @_;
        my @argv = @{ $a->{argv} || [] };
        my $sub  = shift(@argv) || 'status';
        if ($sub eq 'status') {
            $self->refresh;
            my $cnt = scalar(keys %{ $self->{status} });
            my $msg = sprintf('Git [%s]: %d changed file(s)', $self->{branch} || 'detached', $cnt);
            $ed->notify($msg, 'info');
            return { ok => 1, message => $msg, branch => $self->{branch}, status => $self->status_map };
        }
        elsif ($sub eq 'branch') {
            $self->refresh;
            $ed->notify("Git branch: $self->{branch}", 'info');
            return { ok => 1, branch => $self->{branch} };
        }
        elsif ($sub eq 'commit') {
            my $msg = join(' ', @argv);
            return { ok => 0, message => 'Commit message required' } unless length $msg;
            return $self->commit($msg, all => 1);
        }
        elsif ($sub eq 'preview_hunk') {
            my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
            my $win = $ed->current_window;
            my $res = $self->preview_hunk($buf, $win ? $win->cursor_line : 0);
            return $res ? { ok => 1, hunk => $res } : { ok => 0, message => 'No hunk at cursor' };
        }
        elsif ($sub eq 'reset_hunk') {
            my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
            my $win = $ed->current_window;
            my $ok = $self->reset_hunk($buf, $win ? $win->cursor_line : 0);
            return { ok => $ok, message => $ok ? 'Hunk reset' : 'No hunk at cursor' };
        }
        elsif ($sub eq 'refresh') {
            $self->refresh;
            return { ok => 1, branch => $self->{branch} };
        }
        return { ok => 0, message => "Unknown :Git subcommand: $sub" };
    }, desc => 'Git integration (status, branch, commit, preview_hunk, reset_hunk)');

    return $self;
}

sub _run_git {
    my ($self, $dir, @args) = @_;
    $dir ||= $self->{repo_root} || $self->{cwd} || '.';
    my ($wtr, $rdr);
    my $err = gensym;
    my $pid = eval { open3($wtr, $rdr, $err, $self->{git_bin}, '-C', $dir, @args) };
    return (127, '', 'git exec failed') unless $pid;
    close $wtr;

    local $/;
    my $out = <$rdr>;
    my $er  = <$err>;
    close $rdr;
    close $err;
    waitpid($pid, 0);
    my $rc = $? >> 8;
    return ($rc, $out // '', $er // '');
}

sub is_git_repo { return defined($_[0]->{repo_root}) && length($_[0]->{repo_root}) ? 1 : 0 }
sub repo_root   { return $_[0]->{repo_root} }
sub branch      { return $_[0]->{branch} }
sub status_map  { return { %{ $_[0]->{status} } } }

sub refresh {
    my ($self) = @_;
    my $dir = $self->{editor} ? $self->{editor}->cwd : $self->{cwd};
    my ($rc, $top) = $self->_run_git($dir, 'rev-parse', '--show-toplevel');
    if ($rc != 0) {
        $self->{repo_root} = undef;
        $self->{branch}    = '';
        $self->{status}    = {};
        return 0;
    }
    chomp $top;
    $self->{repo_root} = eval { abs_path($top) } || $top;

    my ($brc, $br) = $self->_run_git($self->{repo_root}, 'rev-parse', '--abbrev-ref', 'HEAD');
    chomp $br if defined $br;
    if ($brc != 0 || !length($br) || $br eq 'HEAD') {
        my ($src, $sym) = $self->_run_git($self->{repo_root}, 'symbolic-ref', '--short', 'HEAD');
        chomp $sym if defined $sym;
        $br = ($src == 0 && length $sym) ? $sym : 'HEAD';
    }
    $self->{branch} = $br;

    my ($strc, $stout) = $self->_run_git($self->{repo_root}, 'status', '--porcelain=v1');
    my %st;
    if ($strc == 0) {
        for my $line (split /\r?\n/, $stout) {
            next unless length($line) >= 4;
            my $xy   = substr($line, 0, 2);
            my $path = substr($line, 3);
            $path =~ s/^.* -> //;
            $path =~ s/^"|"$//g;
            my $badge = $xy eq '??' ? '?'
                      : $xy =~ /U/  ? 'U'
                      : $xy =~ /A/  ? 'A'
                      : $xy =~ /D/  ? 'D'
                      : $xy =~ /R/  ? 'R'
                      : 'M';
            $st{$path} = $badge;
            my $full = File::Spec->catfile($self->{repo_root}, $path);
            $st{$full} = $badge;
        }
    }
    $self->{status} = \%st;

    if ($self->{editor}) {
        my $cur = $self->{editor}->current_buffer;
        $self->update_buffer($cur) if $cur && $cur->path;
    }
    return 1;
}

sub _rel_path {
    my ($self, $path) = @_;
    return undef unless defined $path && $self->is_git_repo;
    my $abs = eval { abs_path($path) } || $path;
    my $root = $self->{repo_root};
    return undef unless index($abs, $root) == 0;
    my $rel = File::Spec->abs2rel($abs, $root);
    $rel =~ s{\\}{/}g;
    return $rel;
}

sub get_head_text {
    my ($self, $path) = @_;
    my $rel = $self->_rel_path($path);
    return undef unless defined $rel;
    my ($rc, $out) = $self->_run_git($self->{repo_root}, 'show', "HEAD:$rel");
    return $rc == 0 ? $out : undef;
}

sub _diff_lines {
    my ($old_text, $new_text) = @_;
    return NeoPerl::Buffer::_compute_myers_hunks($old_text, $new_text);
}

sub update_buffer {
    my ($self, $buf, %opts) = @_;
    return [] unless $buf && $buf->path;
    $self->refresh unless $self->is_git_repo;
    return [] unless $self->is_git_repo;

    my $bid = $buf->id;
    my $base_text;
    if ($opts{use_cached_baseline} && defined $buf->git_baseline) {
        $base_text = $buf->git_baseline;
    }
    else {
        $base_text = $self->get_head_text($buf->path);
        $buf->git_baseline($base_text);
    }

    $buf->clear_namespace('git_gutter');
    if (!defined $base_text) {
        $self->{hunks}{$bid} = [];
        return [];
    }

    my $cur_text = $buf->get_text;
    my $raw_hunks = _diff_lines($base_text, $cur_text);

    my @old_lines = split /\n/, $base_text, -1;
    pop @old_lines if @old_lines && $old_lines[-1] eq '';
    my @new_lines = split /\n/, $cur_text, -1;
    pop @new_lines if @new_lines && $new_lines[-1] eq '';

    my @enriched;
    my $max_line = $buf->line_count > 0 ? $buf->line_count - 1 : 0;

    for my $h (@{$raw_hunks}) {
        my $os = $h->{old_start} // 0;
        my $oc = $h->{old_count} // 0;
        my $ns = $h->{new_start} // 0;
        my $nc = $h->{new_count} // 0;
        my $kind = $h->{kind} || ($oc == 0 ? 'add' : ($nc == 0 ? 'del' : 'change'));

        my @ol = $oc > 0 ? @old_lines[ $os .. ($os + $oc - 1 <= $#old_lines ? $os + $oc - 1 : $#old_lines) ] : ();
        my @nl = $nc > 0 ? @new_lines[ $ns .. ($ns + $nc - 1 <= $#new_lines ? $ns + $nc - 1 : $#new_lines) ] : ();

        push @enriched, {
            old_start => $os,
            old_count => $oc,
            new_start => $ns,
            new_count => $nc,
            kind      => $kind,
            old_lines => \@ol,
            new_lines => \@nl,
        };

        if ($kind eq 'del') {
            my $mark_l = $ns > $max_line ? $max_line : $ns;
            $buf->set_extmark('git_gutter', $mark_l, 0, {
                sign_text => '-',
                sign_hl   => 'GitDelete',
                priority  => 60,
            });
        }
        else {
            my $sign = $kind eq 'add' ? '+' : '~';
            my $hl   = $kind eq 'add' ? 'GitAdd' : 'GitChange';
            for my $off (0 .. $nc - 1) {
                my $l = $ns + $off;
                last if $l > $max_line;
                $buf->set_extmark('git_gutter', $l, 0, {
                    sign_text => $sign,
                    sign_hl   => $hl,
                    priority  => 60,
                });
            }
        }
    }

    $self->{hunks}{$bid} = \@enriched;
    return \@enriched;
}

sub get_hunks {
    my ($self, $buf) = @_;
    return [] unless $buf;
    return $self->{hunks}{ $buf->id } || [];
}

sub hunk_at_line {
    my ($self, $buf, $line) = @_;
    my $hunks = $self->get_hunks($buf);
    for my $h (@{$hunks}) {
        my $s = $h->{new_start};
        my $e = $h->{new_count} > 0 ? $s + $h->{new_count} - 1 : $s;
        return $h if $line >= $s && $line <= $e;
    }
    return undef;
}

sub next_hunk {
    my ($self, $buf, $cur_line) = @_;
    my $hunks = $self->get_hunks($buf);
    return undef unless @{$hunks};
    for my $h (@{$hunks}) {
        return $h if $h->{new_start} > $cur_line;
    }
    return $hunks->[0];
}

sub prev_hunk {
    my ($self, $buf, $cur_line) = @_;
    my $hunks = $self->get_hunks($buf);
    return undef unless @{$hunks};
    for my $h (reverse @{$hunks}) {
        return $h if $h->{new_start} < $cur_line;
    }
    return $hunks->[-1];
}

sub preview_hunk {
    my ($self, $buf, $line) = @_;
    my $h = $self->hunk_at_line($buf, $line) or return undef;
    my @lines;
    push @lines, sprintf('@@ -%d,%d +%d,%d @@ (%s)',
        $h->{old_start} + 1, $h->{old_count}, $h->{new_start} + 1, $h->{new_count}, $h->{kind});
    push @lines, map { "- $_" } @{ $h->{old_lines} };
    push @lines, map { "+ $_" } @{ $h->{new_lines} };

    if ($self->{editor}) {
        $self->{editor}->layout->close_floats_by_kind('git_hunk');
        $self->{editor}->layout->open_float(
            kind      => 'git_hunk',
            title     => ' Git Hunk Preview ',
            relative  => 'cursor',
            width     => 64,
            height    => (@lines + 2 > 18 ? 18 : @lines + 2),
            zindex    => 75,
            focusable => 0,
            lines     => \@lines,
            meta      => { hunk => $h },
        );
    }
    return { hunk => $h, lines => \@lines };
}

sub reset_hunk {
    my ($self, $buf, $line) = @_;
    my $h = $self->hunk_at_line($buf, $line) or return 0;
    my $ns = $h->{new_start};
    my $nc = $h->{new_count};
    $buf->begin_undo_group;
    $buf->set_lines($ns, $ns + $nc, $h->{old_lines});
    $buf->end_undo_group;
    $self->update_buffer($buf, use_cached_baseline => 1);
    $self->{editor}->emit('TextChanged', buf => $buf) if $self->{editor};
    return 1;
}

sub commit {
    my ($self, $message, %opts) = @_;
    $self->refresh unless $self->is_git_repo;
    return { ok => 0, message => 'Not a Git repository' } unless $self->is_git_repo;

    my @paths = @{ $opts{paths} || [] };
    if (@paths) {
        my ($arc, undef, $aerr) = $self->_run_git($self->{repo_root}, 'add', '--', @paths);
        return { ok => 0, message => "git add failed: $aerr" } if $arc != 0;
    }
    elsif ($opts{all}) {
        my ($arc, undef, $aerr) = $self->_run_git($self->{repo_root}, 'add', '-A');
        return { ok => 0, message => "git add -A failed: $aerr" } if $arc != 0;
    }

    my @commit_args = ('commit', '-m', $message);
    my ($crc, $cout, $cerr) = $self->_run_git($self->{repo_root}, @commit_args);
    if ($crc != 0) {
        my $err = $cerr || $cout || 'git commit failed';
        chomp $err;
        $self->{editor}->notify($err, 'error') if $self->{editor};
        return { ok => 0, message => $err };
    }

    my (undef, $sha) = $self->_run_git($self->{repo_root}, 'rev-parse', 'HEAD');
    chomp $sha;
    my (undef, $files_out) = $self->_run_git($self->{repo_root}, 'diff-tree', '--no-commit-id', '--name-only', '-r', $sha);
    my @files = grep { length } split /\r?\n/, $files_out;
    my (undef, $diff_stat) = $self->_run_git($self->{repo_root}, 'show', '--stat', '--format=', $sha);

    $self->refresh;

    if ($self->{editor}) {
        $self->{editor}->emit('GitCommitPost',
            sha     => $sha,
            message => $message,
            files   => \@files,
            diff    => $diff_stat,
            branch  => $self->{branch},
        );
        $self->{editor}->notify("Committed " . substr($sha, 0, 8) . ": $message", 'info');
    }

    return {
        ok      => 1,
        sha     => $sha,
        message => $message,
        files   => \@files,
        diff    => $diff_stat,
        branch  => $self->{branch},
    };
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::Git - Git branch, status, C11 Myers gutter signs, and commit hooks

=head1 SYNOPSIS

    use NeoPerl::Plugin::Git;
    my $git = NeoPerl::Plugin::Git->new(editor => $editor);
    my $branch = $git->branch;
    $git->commit('Update parser', paths => ['lib/Foo.pm']);

=head1 DESCRIPTION

Tracks repository branch and porcelain status for L<NeoPerl::Plugin::Explorer>,
paints C11 Myers line-diff gutter signs in extmark namespace C<git_gutter>,
supports hunk preview/reset/navigation, and emits C<GitCommitPost> events.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself (Artistic License 2.0 or GPL).

=cut
