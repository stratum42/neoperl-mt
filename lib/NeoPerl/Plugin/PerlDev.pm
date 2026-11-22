package NeoPerl::Plugin::PerlDev;

use strict;
use warnings;

use Config ();
use File::Basename ();
use File::Spec ();
use File::Temp ();
use IPC::Open3 ();
use Symbol ();

use NeoPerl::Plugin::PerlDev::Worker;

our $VERSION = '0.01';

BEGIN {
    NeoPerl::Plugin::PerlDev::Worker::ensure_inc();
}

sub new {
    my ($class, %opts) = @_;
    my $worker = $opts{worker} || NeoPerl::Plugin::PerlDev::Worker->new(
        force_fallback => $opts{force_fallback},
        use_mt_worker  => $opts{use_mt_worker},
        doc_cache_max  => $opts{doc_cache_max},
    );

    my $self = bless {
        editor            => undef,
        worker            => $worker,
        mcp               => $opts{mcp},
        offload_queue     => $opts{offload_queue},
        modalities        => $opts{modalities},
        memory_store      => $opts{memory_store},
        telescope         => $opts{telescope},
        critic_severity   => defined($opts{critic_severity}) ? $opts{critic_severity} : 4,
        post_tidy_enabled => exists($opts{post_tidy_enabled}) ? ($opts{post_tidy_enabled} ? 1 : 0) : 1,
        auto_critic       => exists($opts{auto_critic}) ? ($opts{auto_critic} ? 1 : 0) : 1,
        last_critic       => {},    # buf_id => critic result
        last_outline      => {},    # buf_id => outline result
        last_fix_report   => undef,
    }, $class;

    if ($opts{editor}) {
        $self->attach($opts{editor}, %opts);
    }
    elsif ($opts{mcp}) {
        $self->register_mcp_tools($opts{mcp});
    }

    return $self;
}

sub worker           { $_[0]{worker} }
sub capabilities     { $_[0]{worker}->capabilities }
sub stats            { $_[0]{worker}->stats }
sub critic_severity  { my $s = shift; $s->{critic_severity} = $_[0] if @_; return $s->{critic_severity} }
sub last_fix_report  { $_[0]{last_fix_report} }

sub _is_perl_buffer {
    my ($self, $buf) = @_;
    return 0 unless $buf;
    my $ft   = $buf->can('filetype') ? ($buf->filetype // '') : '';
    my $path = $buf->can('path')     ? ($buf->path     // '') : '';
    my $name = $buf->can('name')     ? ($buf->name     // '') : '';
    return 1 if lc($ft) eq 'perl';
    return 1 if ($path || $name) =~ /\.(?:pl|pm|t|psgi|pod)\z/i;
    my $first = $buf->can('get_line') ? ($buf->get_line(0) // '') : '';
    return 1 if $first =~ /^#!.*\bperl\b/;
    return 0;
}

sub _buf_text {
    my ($buf) = @_;
    return '' unless $buf;
    return $buf->get_text if $buf->can('get_text');
    return $buf->text     if $buf->can('text');
    if ($buf->can('get_lines') && $buf->can('line_count')) {
        my $lines = $buf->get_lines(0, $buf->line_count);
        return join("\n", @$lines) . "\n";
    }
    return '';
}

sub _buf_rev {
    my ($buf) = @_;
    return 0 unless $buf;
    return $buf->rev         if $buf->can('rev');
    return $buf->changedtick if $buf->can('changedtick');
    return $buf->revision    if $buf->can('revision');
    return $buf->version     if $buf->can('version');
    return length(_buf_text($buf));
}

sub _buf_set_text {
    my ($self, $buf, $new_text) = @_;
    return 0 unless $buf && defined $new_text;
    if ($buf->can('set_text')) {
        $buf->set_text($new_text);
    }
    elsif ($buf->can('set_lines') && $buf->can('line_count')) {
        my $copy = $new_text;
        $copy =~ s/\n\z//;
        my @lines = split /\n/, $copy, -1;
        $buf->begin_undo_group if $buf->can('begin_undo_group');
        $buf->set_lines(0, $buf->line_count, \@lines);
        $buf->end_undo_group if $buf->can('end_undo_group');
    }
    $self->{editor}->emit('TextChanged', buf => $buf) if $self->{editor};
    return 1;
}

# -------------------------------------------------------------------------
# Editor Attachment: Commands, Keymaps, Providers, Events, Post-Tidy Gate, MCP
# -------------------------------------------------------------------------

sub attach {
    my ($self, $editor, %opts) = @_;
    return $self unless $editor;
    $self->{editor}        = $editor;
    $self->{mcp}         ||= $opts{mcp}           || $editor->plugin('mcp');
    $self->{offload_queue} ||= $opts{offload_queue} || $editor->plugin('offload_queue');
    $self->{modalities}  ||= $opts{modalities}    || $editor->plugin('modalities');
    $self->{memory_store} ||= $opts{memory_store} || $editor->plugin('memory');
    $self->{telescope}   ||= $opts{telescope}     || $editor->plugin('telescope');

    $editor->register_plugin('perldev', $self);

    # Tick pump for async MT::Worker completions
    $editor->add_tick_callback('perldev_pump', sub {
        $self->{worker}->poll_async();
    });

    # Event hooks
    $editor->on('BufReadPost', sub {
        my (%ev) = @_;
        my $buf = $ev{buf} or return;
        return unless $self->_is_perl_buffer($buf);
        $self->analyze_buffer($buf) if $self->{auto_critic};
    });

    $editor->on('TextChanged', sub {
        my (%ev) = @_;
        my $buf = $ev{buf} or return;
        return unless $self->_is_perl_buffer($buf);
        $self->analyze_buffer($buf) if $self->{auto_critic};
    });

    $editor->on('BufWritePre', sub {
        my (%ev) = @_;
        my $buf = $ev{buf} or return;
        return unless $self->_is_perl_buffer($buf);
        if ($editor->get_option('perltidy_on_save')) {
            $self->tidy_buffer($buf);
        }
    });

    # Symbol outline provider (powers Telescope <leader>fs & Explorer)
    $editor->register_symbol_provider(sub {
        my ($ed, $buf) = @_;
        return undef unless $self->_is_perl_buffer($buf);
        my $out = $self->outline_buffer($buf);
        return [
            map {
                +{
                    name     => $_->{name},
                    kind     => $_->{kind},
                    line     => ($_->{line} || 1) - 1,     # 0-based for Editor/Telescope
                    col      => ($_->{col}  || 1) - 1,
                    end_line => (($_->{end_line} || $_->{line} || 1) - 1),
                    detail   => $_->{detail},
                    package  => $_->{package},
                }
            } @{ $out->{items} || [] }
        ];
    });

    # Workspace gd / gr providers via PPI AST
    $editor->register_definition_provider(sub {
        my ($ed, $buf, $line, $col) = @_;
        return undef unless $self->_is_perl_buffer($buf);
        my $sym = $self->_word_at($buf, $line, $col) or return undef;
        my $hits = $self->workspace_definition($sym);
        return undef unless @$hits;
        return {
            path => $hits->[0]{file},
            line => ($hits->[0]{line} || 1) - 1,
            col  => ($hits->[0]{col}  || 1) - 1,
            hits => $hits,
        };
    });

    $editor->register_reference_provider(sub {
        my ($ed, $buf, $line, $col) = @_;
        return undef unless $self->_is_perl_buffer($buf);
        my $sym = $self->_word_at($buf, $line, $col) or return undef;
        my $refs = $self->workspace_references($sym);
        return [
            map {
                +{
                    path => $_->{file},
                    line => ($_->{line} || 1) - 1,
                    col  => ($_->{col}  || 1) - 1,
                    text => $_->{text},
                }
            } @$refs
        ];
    });

    # Automatic post-tidy gate on AI-generated Perl diff proposals
    $editor->register_before_stage_diff_hook(sub {
        my ($ed, $buf, $new_text, $meta) = @_;
        return $self->post_tidy_proposal($buf, $new_text, $meta);
    });

    if ($self->{mcp} && $self->{mcp}->can('set_post_tidy')) {
        $self->{mcp}->set_post_tidy(sub {
            my ($code, $path) = @_;
            return $code if defined $path && length($path) && $path !~ /\.(?:pl|pm|t|psgi)\z/i;
            return $self->post_tidy_text($code, file_path => $path);
        });
    }
    if ($self->{offload_queue} && $self->{offload_queue}->can('set_post_tidy_hook')) {
        $self->{offload_queue}->set_post_tidy_hook(sub {
            my ($code, $path) = @_;
            return $code if defined $path && length($path) && $path !~ /\.(?:pl|pm|t|psgi)\z/i;
            return $self->post_tidy_text($code, file_path => $path);
        });
    }
    if ($self->{modalities} && $self->{modalities}->can('set_perl_slice_hook')) {
        $self->{modalities}->set_perl_slice_hook(sub {
            my ($buf, $line) = @_;
            my $sl = $self->slice_context($buf, $line || 1);
            return ($sl && $sl->{ok}) ? $sl->{text} : undef;
        });
    }

    # Statusline segment
    $editor->register_statusline_provider('perldev', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer;
        return undef unless $self->_is_perl_buffer($buf);
        my $c = $self->{last_critic}{ $buf->id };
        my $n = ($c && ref($c->{violations}) eq 'ARRAY') ? scalar(@{ $c->{violations} }) : 0;
        return "PPI+Critic($n)";
    });

    $self->_register_commands($editor);
    $self->_register_keymaps($editor);
    $self->register_mcp_tools($self->{mcp}) if $self->{mcp};

    if (my $wk = $editor->plugin('whichkey')) {
        $wk->register_group('<leader>p', 'Perl IDE (PPI/Critic/Tidy)') if $wk->can('register_group');
    }
    if (my $exp = $editor->plugin('explorer')) {
        if ($exp->can('register_child_provider')) {
            $exp->register_child_provider(sub {
                my ($path) = @_;
                return undef unless defined $path && $path =~ /\.(?:pl|pm|t|psgi)\z/i && -f $path;
                open my $fh, '<', $path or return undef;
                local $/;
                my $txt = <$fh> // '';
                close $fh;
                my $out = $self->{worker}->outline("exp:$path", length($txt), $txt);
                return [
                    map  { +{ label => "sub $_->{name}", path => $path, line => ($_->{line} || 1) - 1, kind => 'sub' } }
                    grep { $_->{kind} eq 'sub' } @{ $out->{items} || [] }
                ];
            });
        }
    }

    return $self;
}

sub _register_commands {
    my ($self, $editor) = @_;
    my $ex = $editor->excmd;

    $ex->register_command('PerlOutline', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $out = $self->outline_buffer($buf);
        my $tel = $self->{telescope} || $ed->plugin('telescope');
        if ($tel && $tel->can('open_custom')) {
            my @items = map {
                +{
                    label  => sprintf('%-9s %-24s L%d', $_->{kind}, $_->{name}, $_->{line}),
                    detail => $_->{detail} // '',
                    line   => ($_->{line} || 1) - 1,
                    col    => ($_->{col}  || 1) - 1,
                    path   => $buf->path,
                    buf_id => $buf->id,
                    data   => $_,
                }
            } @{ $out->{items} || [] };
            $tel->open_custom('Perl AST Outline (PPI)', \@items, sub {
                my ($sel) = @_;
                $ed->jump_to($buf, $sel->{line} || 0, $sel->{col} || 0) if $sel;
            });
        }
        return { ok => 1, message => sprintf('%d Perl symbols', scalar(@{ $out->{items} || [] })), data => $out };
    }, desc => 'Show PPI AST outline for current Perl buffer');

    $ex->register_command('PerlCritic', sub {
        my ($ed, $ctx) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $res = $self->critic_buffer($buf, populate_qf => 1);
        my $n   = scalar(@{ $res->{violations} || [] });
        my $msg = sprintf('Perl::Critic (%s, sev=%d): %d violation(s)', $res->{backend}, $res->{severity}, $n);
        $ed->notify($msg, $n ? 'warn' : 'info');
        return { ok => 1, message => $msg, data => $res };
    }, desc => 'Run Perl::Critic on current buffer and populate diagnostics/quickfix');

    $ex->register_command('PerlCriticSeverity', sub {
        my ($ed, $ctx) = @_;
        my $lvl = $ctx->{argv}[0];
        if (!defined $lvl || $lvl !~ /^[1-5]$/) {
            return { ok => 0, message => 'Usage: :PerlCriticSeverity <1-5>' };
        }
        $self->{critic_severity} = $lvl + 0;
        my $buf = $ed->current_buffer;
        my $res = ($buf && $self->_is_perl_buffer($buf)) ? $self->critic_buffer($buf, populate_qf => 1) : undef;
        my $msg = "Perl::Critic severity set to $lvl";
        $ed->notify($msg, 'info');
        return { ok => 1, message => $msg, data => $res };
    }, desc => 'Set Perl::Critic severity level (1-5)');

    $ex->register_command('PerlCriticFix', sub {
        my ($ed, $ctx) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $res = $self->fix_critic_violations($buf);
        $ed->notify($res->{message} || 'PerlCriticFix complete', $res->{ok} ? 'info' : 'warn');
        return $res;
    }, desc => 'Tiered auto-fix for Perl::Critic violations (Bonsai mechanical / Gemini structural)');

    $ex->register_command('PerlTidy', sub {
        my ($ed, $ctx) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $range = $ctx->{range};
        my $res;
        if ($range && $range->{explicit}) {
            $res = $self->tidy_buffer_range($buf, $range->{start} + 1, $range->{end} + 1);
        }
        else {
            $res = $self->tidy_buffer($buf);
        }
        my $msg = $res->{ok}
            ? ($res->{changed} ? "Perl::Tidy formatted ($res->{backend})" : 'Perl::Tidy: already formatted')
            : "Perl::Tidy error: " . ($res->{error} || 'unknown');
        $ed->notify($msg, $res->{ok} ? 'info' : 'error');
        return { ok => $res->{ok}, message => $msg, data => $res };
    }, desc => 'Format Perl buffer or range with Perl::Tidy', range => 1);

    $ex->register_command('PerlTidyDiff', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $res = $self->tidy_diff_buffer($buf);
        $ed->notify($res->{message}, $res->{ok} ? 'info' : 'warn');
        return $res;
    }, desc => 'Stage Perl::Tidy formatting changes as inline red/green diff hunks');

    $ex->register_command('PerlRename', sub {
        my ($ed, $ctx) = @_;
        my $new_name = $ctx->{argv}[0];
        return { ok => 0, message => 'Usage: :PerlRename <new_var>' } unless defined $new_name && length $new_name;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $win = $ed->current_window;
        my $line = $win ? ($win->cursor_line + 1) : 1;
        my $col  = $win ? ($win->cursor_col  + 1) : 1;
        my $res  = $self->rename_lexical($buf, $line, $col, $new_name, apply => 1);
        my $msg  = $res->{ok}
            ? "Renamed $res->{old_name} -> $res->{new_name} ($res->{count} occurrence(s) in scope)"
            : ($res->{error} || 'Rename failed');
        $ed->notify($msg, $res->{ok} ? 'info' : 'error');
        return { ok => $res->{ok}, message => $msg, data => $res };
    }, desc => 'Scope-safe PPI lexical variable rename');

    $ex->register_command('PerlExtractSub', sub {
        my ($ed, $ctx) = @_;
        my $sub_name = $ctx->{argv}[0] || 'extracted_helper';
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $range = $ctx->{range};
        my ($s, $e);
        if ($range && $range->{explicit}) {
            ($s, $e) = ($range->{start} + 1, $range->{end} + 1);
        }
        elsif ($ed->modal && $ed->modal->can('last_visual_range') && $ed->modal->last_visual_range) {
            my $vr = $ed->modal->last_visual_range;
            ($s, $e) = ($vr->{start_line} + 1, $vr->{end_line} + 1);
        }
        else {
            my $win = $ed->current_window;
            my $ln = $win ? ($win->cursor_line + 1) : 1;
            ($s, $e) = ($ln, $ln);
        }
        my $res = $self->extract_sub_from_buffer($buf, $s, $e, $sub_name, apply => 1);
        my $msg = $res->{ok}
            ? "Extracted sub $sub_name(" . join(', ', @{ $res->{params} || [] }) . ')'
            : ($res->{error} || 'Extract sub failed');
        $ed->notify($msg, $res->{ok} ? 'info' : 'error');
        return { ok => $res->{ok}, message => $msg, data => $res };
    }, desc => 'Extract selected lines into a new Perl subroutine with PPI free-lexical analysis', range => 1);

    $ex->register_command('PerlSlice', sub {
        my ($ed) = @_;
        my $buf = $ed->current_buffer or return { ok => 0, message => 'No buffer' };
        my $win = $ed->current_window;
        my $ln  = $win ? ($win->cursor_line + 1) : 1;
        my $res = $self->slice_context($buf, $ln);
        $ed->notify(sprintf('PPI slice: %d/%d lines (sub %s)',
            $res->{sliced_lines}, $res->{original_lines}, $res->{enclosing_sub} // '<top>'), 'info');
        return { ok => 1, message => 'PPI slice ready', data => $res };
    }, desc => 'Compute token-saving PPI AI context slice around cursor');

    return;
}

sub _register_keymaps {
    my ($self, $editor) = @_;
    my $modal = $editor->modal or return;
    return unless $modal->can('map');

    $modal->map('n', '<leader>pf', sub { $editor->exec_command(':PerlTidy') },      desc => 'Perl::Tidy buffer');
    $modal->map('n', '<leader>fs', sub { $editor->exec_command(':PerlOutline') },   desc => 'PPI AST outline');
    $modal->map('n', '<leader>pr', sub {
        $editor->notify('Use :PerlRename <new_name> on a lexical variable', 'info');
    }, desc => 'Scope-safe PPI lexical rename');
    $modal->map('v', '<leader>pe', sub {
        my $vr = $modal->can('visual_range') ? $modal->visual_range($editor) : undef;
        if ($vr) {
            my $s = ($vr->{start_line} // 0) + 1;
            my $e = ($vr->{end_line}   // 0) + 1;
            $editor->exec_command(":${s},${e}PerlExtractSub extracted_sub");
        }
    }, desc => 'Extract visual selection to sub');

    # Register native Modal structural hooks (if/af/ip/ap text objects, ]]/[[ motions, gq formatter)
    if ($modal->can('register_text_object')) {
        for my $kind (qw(if af ip ap)) {
            $modal->register_text_object($kind, sub {
                my ($ed, $buf, $line0, $col0) = @_;
                return undef unless $self->_is_perl_buffer($buf);
                my $res = $self->text_object($buf, ($line0 // 0) + 1, ($col0 // 0) + 1, $kind);
                return undef unless $res && $res->{found};
                return {
                    start_line => $res->{start_line} - 1,
                    start_col  => ($res->{start_col} || 1) - 1,
                    end_line   => $res->{end_line} - 1,
                    end_col    => ($res->{end_col}   || 1) - 1,
                    linewise   => 1,
                };
            });
        }
    }

    if ($modal->can('register_motion')) {
        $modal->register_motion(']]', sub {
            my ($ed, $buf, $line0, $col0, $count) = @_;
            return undef unless $self->_is_perl_buffer($buf);
            my $cur = ($line0 // 0) + 1;
            my $n   = $count || 1;
            my $hit;
            for (1 .. $n) {
                my $nxt = $self->next_sub($buf, $cur);
                last unless $nxt;
                $hit = $nxt;
                $cur = $nxt->{line};
            }
            return $hit ? [ $hit->{line} - 1, 0 ] : undef;
        });

        $modal->register_motion('[[', sub {
            my ($ed, $buf, $line0, $col0, $count) = @_;
            return undef unless $self->_is_perl_buffer($buf);
            my $cur = ($line0 // 0) + 1;
            my $n   = $count || 1;
            my $hit;
            for (1 .. $n) {
                my $prv = $self->prev_sub($buf, $cur);
                last unless $prv;
                $hit = $prv;
                $cur = $prv->{line};
            }
            return $hit ? [ $hit->{line} - 1, 0 ] : undef;
        });
    }

    if ($modal->can('register_formatter')) {
        $modal->register_formatter('perl', sub {
            my ($ed, $buf, $start0, $end0) = @_;
            my $res = $self->tidy_buffer_range($buf, ($start0 // 0) + 1, ($end0 // 0) + 1, dry_run => 1);
            return undef unless $res && $res->{ok} && defined $res->{range_text};
            my $rt = $res->{range_text};
            $rt =~ s/\n\z//;
            return [ split /\n/, $rt, -1 ];
        });
    }

    return;
}

# -------------------------------------------------------------------------
# Core IDE Operations
# -------------------------------------------------------------------------

sub analyze_buffer {
    my ($self, $buf) = @_;
    return undef unless $buf;
    my $out  = $self->outline_buffer($buf);
    my $crit = $self->critic_buffer($buf);
    return { outline => $out, critic => $crit };
}

sub outline_buffer {
    my ($self, $buf, %opts) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id') ? $buf->id : 'text';
    my $rev  = ref($buf) ? _buf_rev($buf) : length($text);
    my $out  = $self->{worker}->outline($bid, $rev, $text, %opts);
    $self->{last_outline}{$bid} = $out if ref($buf);
    return $out;
}

sub slice_context {
    my ($self, $buf, $line, %opts) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id') ? $buf->id : 'text';
    my $rev  = ref($buf) ? _buf_rev($buf) : length($text);
    return $self->{worker}->slice_context($bid, $rev, $text, $line || 1, %opts);
}

sub text_object {
    my ($self, $buf, $line, $col, $kind) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id') ? $buf->id : 'text';
    my $rev  = ref($buf) ? _buf_rev($buf) : length($text);
    return $self->{worker}->text_object($bid, $rev, $text, $line, $col, $kind);
}

sub next_sub {
    my ($self, $buf, $line) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id') ? $buf->id : 'text';
    my $rev  = ref($buf) ? _buf_rev($buf) : length($text);
    return $self->{worker}->next_sub($bid, $rev, $text, $line || 1, 1);
}

sub prev_sub {
    my ($self, $buf, $line) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id') ? $buf->id : 'text';
    my $rev  = ref($buf) ? _buf_rev($buf) : length($text);
    return $self->{worker}->next_sub($bid, $rev, $text, $line || 1, -1);
}

sub rename_lexical {
    my ($self, $buf, $line, $col, $new_name, %opts) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id') ? $buf->id : 'text';
    my $rev  = ref($buf) ? _buf_rev($buf) : length($text);
    my $res  = $self->{worker}->lexical_rename($bid, $rev, $text, $line, $col, $new_name);
    if ($res->{ok} && $opts{apply} && ref($buf)) {
        $self->_buf_set_text($buf, $res->{new_text});
    }
    return $res;
}

sub extract_sub_from_buffer {
    my ($self, $buf, $start_line, $end_line, $sub_name, %opts) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id') ? $buf->id : 'text';
    my $rev  = ref($buf) ? _buf_rev($buf) : length($text);
    my $res  = $self->{worker}->extract_sub($bid, $rev, $text, $start_line, $end_line, $sub_name);
    if ($res->{ok} && $opts{apply} && ref($buf)) {
        $self->_buf_set_text($buf, $res->{new_text});
    }
    return $res;
}

sub _collect_workspace_perl_files {
    my ($self, $extra_files) = @_;
    my %files;
    if (ref($extra_files) eq 'HASH') {
        %files = %$extra_files;
    }
    if ($self->{editor}) {
        for my $b ($self->{editor}->list_buffers) {
            next unless $self->_is_perl_buffer($b);
            my $p = $b->path || $b->name || ("buf_" . $b->id);
            $files{$p} = _buf_text($b);
        }
    }
    return \%files;
}

sub workspace_definition {
    my ($self, $symbol, $files_map) = @_;
    my $map = $self->_collect_workspace_perl_files($files_map);
    return $self->{worker}->find_definition($map, $symbol);
}

sub workspace_references {
    my ($self, $symbol, $files_map) = @_;
    my $map = $self->_collect_workspace_perl_files($files_map);
    return $self->{worker}->find_references($map, $symbol);
}

sub _word_at {
    my ($self, $buf, $line0, $col0) = @_;
    return undef unless $buf && $buf->can('get_line');
    my $str = $buf->get_line($line0 // 0);
    return undef unless defined $str && length $str;
    my $c = $col0 // 0;
    $c = length($str) - 1 if $c >= length($str);
    return undef if $c < 0;
    my $left  = substr($str, 0, $c + 1);
    my $right = substr($str, $c + 1);
    my ($lp) = ($left  =~ /([A-Za-z0-9_:]+)\z/);
    my ($rp) = ($right =~ /\A([A-Za-z0-9_:]*)/);
    my $word = ($lp // '') . ($rp // '');
    return length($word) ? $word : undef;
}

# -------------------------------------------------------------------------
# Perl::Critic Diagnostics + Tiered Auto-Fix (<leader>af / :PerlCriticFix)
# -------------------------------------------------------------------------

sub critic_buffer {
    my ($self, $buf, %opts) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $bid  = ref($buf) && $buf->can('id')   ? $buf->id   : 'text';
    my $rev  = ref($buf)                      ? _buf_rev($buf) : length($text);
    my $path = defined $opts{file_path}       ? $opts{file_path}
             : (ref($buf) && $buf->can('path') ? $buf->path : undef);
    my $sev  = defined $opts{severity}        ? $opts{severity} : $self->{critic_severity};

    my $res = $self->{worker}->critic($bid, $rev, $text,
        severity  => $sev,
        file_path => $path,
        profile   => $opts{profile},
        skip_cli  => $opts{skip_cli},
    );

    if (ref($buf) && $self->{editor}) {
        $self->{last_critic}{$bid} = $res;
        my @ed_diags = map {
            +{
                line     => ($_->{line} || 1) - 1,     # 0-based for Editor::set_diagnostics
                col      => ($_->{col}  || 1) - 1,
                severity => $_->{severity},
                code     => $_->{short_policy},
                message  => $_->{message},
                source   => 'perlcritic',
                data     => $_,
            }
        } @{ $res->{violations} || [] };

        $self->{editor}->set_diagnostics($buf, 'perlcritic', \@ed_diags);

        if ($opts{populate_qf}) {
            my @qf = map {
                +{
                    buf_id => $bid,
                    path   => $path,
                    line   => ($_->{line} || 1) - 1,
                    col    => ($_->{col}  || 1) - 1,
                    text   => $_->{message},
                }
            } @{ $res->{violations} || [] };
            $self->{editor}->set_quickfix(\@qf, open => (@qf > 0 ? 1 : 0));
        }
    }

    return $res;
}

sub _perl_syntax_check {
    my ($self, $code) = @_;
    my ($fh, $tmp) = File::Temp::tempfile('npl_perlc_XXXXXX', SUFFIX => '.pl', UNLINK => 1);
    print {$fh} $code;
    close $fh;

    my @inc_flags = map { "-I$_" } grep { defined $_ && !ref $_ && -d $_ } @INC;
    my ($in, $out, $err);
    $err = Symbol::gensym();
    my $pid = eval { IPC::Open3::open3($in, $out, $err, $^X, @inc_flags, '-c', $tmp) };
    return { ok => 0, stderr => "spawn failed: $@" } unless $pid;
    close $in;
    local $/;
    my $so = <$out> // '';
    my $se = <$err> // '';
    close $out;
    close $err;
    waitpid($pid, 0);
    my $ok = ($? == 0) ? 1 : 0;
    return { ok => $ok, stdout => $so, stderr => $se };
}

sub _apply_mechanical_fixes {
    my ($self, $text, $violations) = @_;
    my $fixed = $text;
    my %pols  = map { ($_->{short_policy} || '') => 1 } @$violations;

    if ($pols{'TestingAndDebugging::RequireUseStrict'} && $fixed !~ /\buse\s+strict\b/) {
        if ($fixed =~ s/^(\s*package\s+[^\n;]+;\s*\n)/$1use strict;\n/m) {
        }
        elsif ($fixed =~ s/^(#![^\n]*\n)/$1use strict;\n/) {
        }
        else {
            $fixed = "use strict;\n" . $fixed;
        }
    }
    if ($pols{'TestingAndDebugging::RequireUseWarnings'} && $fixed !~ /\buse\s+warnings\b/) {
        if ($fixed =~ s/^(\s*use\s+strict;\s*\n)/$1use warnings;\n/m) {
        }
        elsif ($fixed =~ s/^(\s*package\s+[^\n;]+;\s*\n)/$1use warnings;\n/m) {
        }
        else {
            $fixed = "use warnings;\n" . $fixed;
        }
    }
    if ($pols{'Subroutines::ProhibitExplicitReturnUndef'}) {
        $fixed =~ s/\breturn\s+undef\b/return/g;
    }
    if ($pols{'InputOutput::ProhibitBarewordFileHandles'} || $pols{'InputOutput::ProhibitTwoArgOpen'}) {
        $fixed =~ s/\bopen\s*\(?\s*(?:([A-Z][A-Z0-9_]*)|(my\s+\$\w+|\$\w+))\s*,\s*(['"])([<>+|]{1,2})([^'"]+)\3\s*\)?/
            my $fh = defined($1) ? 'my $fh' : $2;
            "open($fh, '$4', '$5')"
        /ge;
    }
    if ($pols{'CodeLayout::ProhibitTrailingWhitespace'}) {
        $fixed =~ s/[ \t]+$//mg;
    }
    if ($pols{'Modules::RequireEndWithOne'} && $fixed !~ /\n1;\s*\z/) {
        $fixed =~ s/\s*\z/\n\n1;\n/;
    }

    return $fixed;
}

sub fix_critic_violations {
    my ($self, $buf, %opts) = @_;
    my $crit = $self->critic_buffer($buf, %opts);
    my $viols = $crit->{violations} || [];
    if (!@$viols) {
        return { ok => 1, tier => 'none', message => 'No Perl::Critic violations to fix', remaining => 0 };
    }

    my @mechanical = grep { $_->{tier} eq 'bonsai' } @$viols;
    my @structural = grep { $_->{tier} eq 'gemini' } @$viols;

    my %report = (
        ok               => 1,
        initial_count    => scalar(@$viols),
        mechanical_count => scalar(@mechanical),
        structural_count => scalar(@structural),
        bonsai_job_id    => undef,
        staged_diff      => 0,
        syntax_ok        => undef,
        gemini_payload   => undef,
    );

    # Tier 1: Mechanical policies -> out-of-band Ternary-Bonsai offload + Critic & perl -c re-check
    if (@mechanical) {
        my $orig_text = ref($buf) ? _buf_text($buf) : $buf;
        my $path      = ref($buf) && $buf->can('path') ? ($buf->path // '') : '';
        my $queue     = $opts{offload_queue} || $self->{offload_queue}
            || ($self->{editor} ? $self->{editor}->plugin('offload_queue') : undef);

        my $pol_list = join(', ', map { $_->{short_policy} . '@L' . $_->{line} } @mechanical);
        if ($queue && $queue->can('enqueue')) {
            my $job_id = $queue->enqueue(
                kind        => 'refactor_local',
                target_path => $path,
                buffer      => (ref($buf) ? $buf : undef),
                source_code => $orig_text,
                instruction => "Fix mechanical Perl::Critic violations: $pol_list",
                verify_syntax => 1,
            );
            $report{bonsai_job_id} = $job_id;
            $report{tier}          = 'bonsai';
        }

        # Apply deterministic mechanical patch, post-tidy, re-verify perl -c + Perl::Critic, stage inline diff
        my $candidate = $self->_apply_mechanical_fixes($orig_text, \@mechanical);
        if ($self->{post_tidy_enabled}) {
            $candidate = $self->post_tidy_text($candidate, file_path => $path);
        }

        my $syn = $self->_perl_syntax_check($candidate);
        $report{syntax_ok} = $syn->{ok};

        my $recheck = $self->{worker}->critic('fix_recheck', length($candidate), $candidate,
            severity  => $self->{critic_severity},
            file_path => $path,
        );
        my $after_mech = scalar grep { $_->{tier} eq 'bonsai' } @{ $recheck->{violations} || [] };
        $report{remaining_mechanical} = $after_mech;
        $report{fixed_text}           = $candidate;

        if ($syn->{ok} && $candidate ne $orig_text && ref($buf) && $buf->can('stage_diff_proposal')) {
            $buf->stage_diff_proposal($candidate,
                source => 'perldev_bonsai',
                title  => "Perl::Critic mechanical fix ($pol_list)",
            );
            $report{staged_diff} = 1;
        }
    }

    # Tier 2: Structural policies -> escalate to Antigravity / Gemini with token-saving PPI slice
    if (@structural) {
        my $first = $structural[0];
        my $slice = $self->slice_context($buf, $first->{line} || 1);
        my $mem_hints = [];
        my $store = $opts{memory_store} || $self->{memory_store}
            || ($self->{editor} ? $self->{editor}->plugin('memory') : undef);
        if ($store && $store->can('search')) {
            $mem_hints = eval { $store->search(query => $first->{short_policy}, category => 'convention', limit => 3) } || [];
        }

        $report{tier} = @mechanical ? 'hybrid' : 'gemini';
        $report{gemini_payload} = {
            violations => \@structural,
            ppi_slice  => $slice,
            memories   => $mem_hints,
        };

        my $mod = $opts{modalities} || $self->{modalities}
            || ($self->{editor} ? $self->{editor}->plugin('modalities') : undef);
        if ($mod && ($mod->can('send_chat') || $mod->can('submit_chat_prompt'))) {
            my $prompt = "Refactor to resolve Perl::Critic structural policy $first->{short_policy}:\n"
                . $first->{description} . "\n\n```perl\n" . $slice->{text} . "```\n";
            if ($mod->can('send_chat')) {
                eval { $mod->send_chat($prompt) };
            }
            else {
                eval { $mod->submit_chat_prompt($prompt) };
            }
        }
    }

    $report{message} = sprintf(
        'PerlCriticFix (%s): %d mechanical, %d structural%s',
        $report{tier} || 'none',
        $report{mechanical_count},
        $report{structural_count},
        ($report{staged_diff} ? ' [diff staged]' : ''),
    );
    $self->{last_fix_report} = \%report;
    return \%report;
}

# -------------------------------------------------------------------------
# Perl::Tidy: Full Buffer, Visual Range, :PerlTidyDiff, AI Post-Tidy Gate
# -------------------------------------------------------------------------

sub tidy_buffer {
    my ($self, $buf, %opts) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $path = defined $opts{file_path} ? $opts{file_path}
             : (ref($buf) && $buf->can('path') ? $buf->path : undef);
    my $res  = $self->{worker}->tidy($text, %opts, file_path => $path);
    if ($res->{ok} && $res->{changed} && ref($buf) && !$opts{dry_run}) {
        $self->_buf_set_text($buf, $res->{text});
    }
    return $res;
}

sub tidy_buffer_range {
    my ($self, $buf, $start_line, $end_line, %opts) = @_;
    my $text = ref($buf) ? _buf_text($buf) : ($buf // '');
    my $path = defined $opts{file_path} ? $opts{file_path}
             : (ref($buf) && $buf->can('path') ? $buf->path : undef);
    my $res  = $self->{worker}->tidy_range($text, $start_line, $end_line, %opts, file_path => $path);
    if ($res->{ok} && $res->{changed} && ref($buf) && !$opts{dry_run}) {
        $self->_buf_set_text($buf, $res->{text});
    }
    return $res;
}

sub tidy_diff_buffer {
    my ($self, $buf, %opts) = @_;
    my $res = $self->tidy_buffer($buf, %opts, dry_run => 1);
    return { ok => 0, message => $res->{error} || 'Perl::Tidy failed' } unless $res->{ok};
    if (!$res->{changed}) {
        return { ok => 1, staged => 0, hunks => [], message => 'Perl::TidyDiff: buffer already matches .perltidyrc' };
    }
    my $hunks = [];
    if (ref($buf) && $buf->can('stage_diff_proposal')) {
        $hunks = $buf->stage_diff_proposal($res->{text},
            source => 'perltidy',
            title  => 'Perl::Tidy formatting',
            skip_post_tidy => 1,
        );
        $hunks = $buf->list_diff_hunks if $buf->can('list_diff_hunks') && ref($hunks) ne 'ARRAY';
    }
    return {
        ok      => 1,
        staged  => 1,
        text    => $res->{text},
        hunks   => $hunks,
        message => sprintf('Perl::TidyDiff staged %d hunk(s)', ref($hunks) eq 'ARRAY' ? scalar(@$hunks) : 1),
    };
}

sub post_tidy_text {
    my ($self, $text, %opts) = @_;
    return $text unless $self->{post_tidy_enabled} && defined $text && length $text;
    my $res = $self->{worker}->tidy($text, file_path => $opts{file_path}, profile => $opts{profile});
    return ($res && $res->{ok} && defined $res->{text}) ? $res->{text} : $text;
}

sub post_tidy_proposal {
    my ($self, $buf, $new_text, $meta) = @_;
    return $new_text unless $self->{post_tidy_enabled};
    return $new_text if ref($meta) eq 'HASH' && $meta->{skip_post_tidy};
    return $new_text unless $self->_is_perl_buffer($buf);
    my $path = $buf->can('path') ? $buf->path : undef;
    return $self->post_tidy_text($new_text, file_path => $path);
}

# -------------------------------------------------------------------------
# Editor MCP Tools 15-18
# -------------------------------------------------------------------------

sub register_mcp_tools {
    my ($self, $mcp) = @_;
    return 0 unless $mcp && $mcp->can('register_tool');
    $self->{mcp} = $mcp;

    my $resolve_code = sub {
        my ($args) = @_;
        if (defined $args->{text}) {
            return ($args->{text}, 'mcp_text', length($args->{text}), $args->{path}, undef);
        }
        if ($self->{editor}) {
            my $buf = (defined $args->{path} && length $args->{path})
                ? $self->{editor}->find_buffer_by_path($args->{path})
                : $self->{editor}->current_buffer;
            if ($buf) {
                return (_buf_text($buf), $buf->id, _buf_rev($buf), $buf->path, $buf);
            }
        }
        if (defined $args->{path} && -f $args->{path} && open my $fh, '<', $args->{path}) {
            local $/;
            my $txt = <$fh> // '';
            close $fh;
            return ($txt, "disk:$args->{path}", length($txt), $args->{path}, undef);
        }
        return ('', 'empty', 0, $args->{path}, undef);
    };

    # 15. neoperl_perl_outline
    $mcp->register_tool('neoperl_perl_outline', {
        description => 'Return full PPI AST outline (packages, subs, imports, constants, globals, POD) for a Perl buffer or file.',
        properties  => {
            path            => { type => 'string' },
            text            => { type => 'string' },
            include_forward => { type => 'boolean' },
        },
    }, sub {
        my ($args) = @_;
        my ($text, $bid, $rev) = $resolve_code->($args);
        return $self->{worker}->outline($bid, $rev, $text, include_forward => $args->{include_forward});
    });

    # 16. neoperl_perl_slice
    $mcp->register_tool('neoperl_perl_slice', {
        description => 'Return token-saving PPI context slice (enclosing sub, package, use/require imports, and referenced local sub signatures).',
        properties  => {
            path => { type => 'string' },
            text => { type => 'string' },
            line => { type => 'integer' },
        },
        required => ['line'],
    }, sub {
        my ($args) = @_;
        my ($text, $bid, $rev) = $resolve_code->($args);
        return $self->{worker}->slice_context($bid, $rev, $text, $args->{line} || 1);
    });

    # 17. neoperl_perl_critic
    $mcp->register_tool('neoperl_perl_critic', {
        description => 'Run live Perl::Critic with .perlcriticrc discovery (reusing cached PPI::Document) on a Perl buffer or snippet.',
        properties  => {
            path     => { type => 'string' },
            text     => { type => 'string' },
            severity => { type => 'integer' },
            profile  => { type => 'string' },
        },
    }, sub {
        my ($args) = @_;
        my ($text, $bid, $rev, $path) = $resolve_code->($args);
        return $self->{worker}->critic($bid, $rev, $text,
            severity  => (defined $args->{severity} ? $args->{severity} : $self->{critic_severity}),
            file_path => $path,
            profile   => $args->{profile},
        );
    });

    # 18. neoperl_perl_tidy
    $mcp->register_tool('neoperl_perl_tidy', {
        description => 'Format Perl source or buffer range with Perl::Tidy (.perltidyrc discovery) or stage formatting diff hunks.',
        properties  => {
            path       => { type => 'string' },
            text       => { type => 'string' },
            start_line => { type => 'integer' },
            end_line   => { type => 'integer' },
            stage_diff => { type => 'boolean' },
            profile    => { type => 'string' },
        },
    }, sub {
        my ($args) = @_;
        my ($text, $bid, $rev, $path, $buf) = $resolve_code->($args);
        my $res;
        if (defined $args->{start_line} && defined $args->{end_line}) {
            $res = $self->{worker}->tidy_range($text, $args->{start_line}, $args->{end_line},
                file_path => $path, profile => $args->{profile});
        }
        else {
            $res = $self->{worker}->tidy($text, file_path => $path, profile => $args->{profile});
        }
        if ($args->{stage_diff} && $res->{ok} && $res->{changed} && $buf && $buf->can('stage_diff_proposal')) {
            $buf->stage_diff_proposal($res->{text}, source => 'perltidy_mcp', skip_post_tidy => 1);
            $res->{staged} = 1;
        }
        return $res;
    });

    return 4;
}

sub shutdown {
    my ($self) = @_;
    $self->{worker}->shutdown() if $self->{worker};
    return 1;
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::PerlDev - Live PPI, Perl::Critic, and Perl::Tidy IDE plugin

=head1 SYNOPSIS

    use NeoPerl::Plugin::PerlDev;

    my $pdev = NeoPerl::Plugin::PerlDev->new(editor => $editor, mcp => $mcp);
    my $out  = $pdev->outline_buffer($buf);
    my $crit = $pdev->critic_buffer($buf);
    my $tidy = $pdev->tidy_diff_buffer($buf);

=head1 DESCRIPTION

Integrates C<PPI>, C<Perl::Critic>, and C<Perl::Tidy> into C<NeoPerl::Editor>:
exact AST outline and workspace C<gd>/C<gr>, PPI-backed Vim motions and text
objects (C<if>/C<af>, C<ip>/C<ap>, C<]]>/C<[[>), scope-safe lexical rename
(C<:PerlRename>), extract-sub (C<:PerlExtractSub>), PPI AI context slicing,
C<.perlcriticrc> live diagnostics and tiered C<:PerlCriticFix> routing,
C<.perltidyrc> full/range/diff formatting with an automatic post-tidy gate for
AI-generated Perl proposals, and Editor MCP tools 15 through 18.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
