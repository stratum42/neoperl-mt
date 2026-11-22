package NeoPerl::Plugin::PerlDev::Worker;

use strict;
use warnings;

use Config ();
use File::Basename ();
use File::Spec ();
use IO::Select ();
use IPC::Open2 ();
use IPC::Open3 ();
use Symbol ();
use Time::HiRes ();

our $VERSION = '0.01';

my $_INC_ADDED = 0;

sub ensure_inc {
    return if $_INC_ADDED;
    $_INC_ADDED = 1;

    my @roots;
    if (defined $ENV{PERL_LOCAL_LIB_ROOT} && length $ENV{PERL_LOCAL_LIB_ROOT}) {
        for my $r (split /\Q$Config::Config{path_sep}\E/, $ENV{PERL_LOCAL_LIB_ROOT}) {
            next unless length $r;
            my $p = File::Spec->catdir($r, 'lib', 'perl5');
            push @roots, $p if -d $p;
        }
    }
    if (defined $ENV{HOME} && length $ENV{HOME}) {
        my $home_p5 = File::Spec->catdir($ENV{HOME}, 'perl5', 'lib', 'perl5');
        push @roots, $home_p5 if -d $home_p5;
    }

    my $ver  = $Config::Config{version}  || '';
    my $arch = $Config::Config{archname} || '';
    my %have = map { $_ => 1 } @INC;
    my @add;

    for my $base (@roots) {
        my @candidates = (
            ($ver && $arch ? File::Spec->catdir($base, $ver, $arch) : ()),
            ($ver          ? File::Spec->catdir($base, $ver)        : ()),
            ($arch         ? File::Spec->catdir($base, $arch)       : ()),
            $base,
        );
        for my $dir (@candidates) {
            next unless -d $dir && !$have{$dir};
            push @add, $dir;
            $have{$dir} = 1;
        }
    }
    unshift @INC, @add if @add;
    return;
}

BEGIN { ensure_inc(); }

my %MECHANICAL_POLICIES = map { $_ => 1 } qw(
    TestingAndDebugging::RequireUseStrict
    TestingAndDebugging::RequireUseWarnings
    Subroutines::ProhibitExplicitReturnUndef
    Subroutines::RequireFinalReturn
    Subroutines::RequireArgUnpacking
    InputOutput::ProhibitBarewordFileHandles
    InputOutput::ProhibitTwoArgOpen
    InputOutput::RequireBriefOpen
    ValuesAndExpressions::ProhibitNoisyQuotes
    ValuesAndExpressions::ProhibitEmptyQuotes
    CodeLayout::ProhibitTrailingWhitespace
    CodeLayout::ProhibitHardTabs
    Modules::RequireEndWithOne
    Variables::ProhibitUnusedVariables
    Variables::ProhibitConditionalDeclarations
    Variables::ProhibitLocalVars
    ControlStructures::ProhibitPostfixControls
    ControlStructures::ProhibitCStyleForLoops
    BuiltinFunctions::ProhibitStringyEval
    RegularExpressions::RequireExtendedFormatting
);

my @_DEFAULT_TIDY_ARGV = qw(-l=100 -i=4 -ci=4 -pt=1 -bt=1 -sbt=1 -nola -nst -se);

sub _json_encode {
    my ($data) = @_;
    if (eval { require Mojo::JSON; 1 }) {
        return Mojo::JSON::encode_json($data);
    }
    require JSON::PP;
    return JSON::PP::encode_json($data);
}

sub _json_decode {
    my ($str) = @_;
    if (eval { require Mojo::JSON; 1 }) {
        return Mojo::JSON::decode_json($str);
    }
    require JSON::PP;
    return JSON::PP::decode_json($str);
}

sub _which {
    my ($bin) = @_;
    return undef unless defined $bin && length $bin;
    my $sep = $Config::Config{path_sep} || ':';
    for my $dir (split /\Q$sep\E/, ($ENV{PATH} || '')) {
        next unless length $dir;
        my $full = File::Spec->catfile($dir, $bin);
        return $full if -x $full && !-d $full;
    }
    return undef;
}

sub _has_mt {
    return eval { require MT; MT::_core_present() } ? 1 : 0;
}

sub new {
    my ($class, %opts) = @_;
    ensure_inc();

    my $force_fallback = $opts{force_fallback} ? 1 : 0;
    my $use_mt_worker  = $opts{use_mt_worker}  ? 1 : 0;

    my $has_ppi    = !$force_fallback && eval { require PPI; 1 }          ? 1 : 0;
    my $has_critic = !$force_fallback && eval { require Perl::Critic; 1 } ? 1 : 0;
    my $has_tidy   = !$force_fallback && eval { require Perl::Tidy; 1 }   ? 1 : 0;

    my $self = bless {
        force_fallback => $force_fallback,
        has_ppi        => $has_ppi,
        has_critic     => $has_critic,
        has_tidy       => $has_tidy,
        ppi_version    => ($has_ppi    ? PPI->VERSION          : undef),
        critic_version => ($has_critic ? Perl::Critic->VERSION : undef),
        tidy_version   => ($has_tidy   ? Perl::Tidy->VERSION   : undef),
        critic_cli     => _which('perlcritic'),
        tidy_cli       => _which('perltidy'),
        doc_cache      => {},
        doc_order      => [],
        doc_max        => $opts{doc_cache_max} || 64,
        critic_cache   => {},
        parse_count    => 0,
        cache_hits     => 0,
        worker_mode    => 'inproc',
        bg_pid         => undef,
        bg_in          => undef,
        bg_out         => undef,
        bg_sel         => undef,
        bg_buf         => '',
        mt_req_ch      => undef,
        pending_async  => {},
        next_req_id    => 1,
    }, $class;

    if (($use_mt_worker || $opts{async_worker}) && !$force_fallback) {
        $self->_start_async_worker();
    }

    return $self;
}

sub _stdio_loop {
    ensure_inc();
    my $worker = __PACKAGE__->new(use_mt_worker => 0);
    $| = 1;
    while (defined(my $line = <STDIN>)) {
        chomp $line;
        last if $line eq '__QUIT__';
        my $req = eval { _json_decode($line) };
        if (!$req || ref($req) ne 'HASH') {
            print _json_encode({ ok => 0, error => 'invalid request' }), "\n";
            next;
        }
        my $op = $req->{op} || '';
        my $args = $req->{args} || {};
        my $result = eval {
            if ($op eq 'outline') {
                return $worker->outline($args->{buf_id}, $args->{rev}, $args->{text}, %$args);
            }
            elsif ($op eq 'critic') {
                return $worker->critic($args->{buf_id}, $args->{rev}, $args->{text}, %$args);
            }
            elsif ($op eq 'tidy') {
                return $worker->tidy($args->{text}, %$args);
            }
            elsif ($op eq 'slice_context') {
                return $worker->slice_context($args->{buf_id}, $args->{rev}, $args->{text}, $args->{line}, %$args);
            }
            elsif ($op eq 'stats') {
                return $worker->stats();
            }
            die "unknown op: $op\n";
        };
        if ($@) {
            print _json_encode({ id => $req->{id}, ok => 0, error => "$@" }), "\n";
        }
        else {
            print _json_encode({ id => $req->{id}, ok => 1, result => $result }), "\n";
        }
    }
    return 1;
}

# Spawns a persistent warm background Perl worker holding cached PPI::Document,
# Perl::Critic, and Perl::Tidy instances across non-blocking Editor->pump() ticks.
# On perl5-mt, also attaches an MT::Channel request queue cleanly without forcing
# Tier-3 CPAN XS dependencies into a frozen worker compartment.
sub _start_async_worker {
    my ($self) = @_;
    return 1 if defined $self->{bg_pid};

    my @inc_dirs = grep { defined $_ && !ref $_ && -d $_ } @INC;
    my @cmd = (
        $^X,
        (map { "-I$_" } @inc_dirs),
        '-MNeoPerl::Plugin::PerlDev::Worker',
        '-e', 'NeoPerl::Plugin::PerlDev::Worker::_stdio_loop()',
    );

    my ($out, $in);
    my $pid = eval { IPC::Open2::open2($out, $in, @cmd) };
    return 0 unless $pid;

    select((select($in), $| = 1)[0]);
    $self->{bg_pid}      = $pid;
    $self->{bg_in}       = $in;
    $self->{bg_out}      = $out;
    $self->{bg_sel}      = IO::Select->new($out);
    $self->{bg_buf}      = '';
    $self->{mt_req_ch}   = _has_mt() ? eval { MT::Channel->new(64) } : undef;
    $self->{worker_mode} = _has_mt() ? 'mt_worker' : 'async_worker';
    return 1;
}

sub submit_async {
    my ($self, $op, $args, $cb) = @_;
    my $id = $self->{next_req_id}++;
    if ($self->{bg_pid} && $self->{bg_in}) {
        my $payload = _json_encode({
            id   => $id,
            op   => $op,
            args => $args || {},
        });
        $self->{pending_async}{$id} = $cb;
        if ($self->{mt_req_ch}) {
            $self->{mt_req_ch}->send($payload);
            my ($got, $msg) = $self->{mt_req_ch}->try_recv;
            $payload = $msg if $got;
        }
        print { $self->{bg_in} } $payload, "\n";
        return $id;
    }

    # Immediate dispatch fallback in inproc mode
    my $res = eval {
        if    ($op eq 'outline')       { $self->outline($args->{buf_id}, $args->{rev}, $args->{text}, %$args) }
        elsif ($op eq 'critic')        { $self->critic($args->{buf_id}, $args->{rev}, $args->{text}, %$args) }
        elsif ($op eq 'tidy')          { $self->tidy($args->{text}, %$args) }
        elsif ($op eq 'slice_context') { $self->slice_context($args->{buf_id}, $args->{rev}, $args->{text}, $args->{line}, %$args) }
        else                           { die "unknown op: $op\n" }
    };
    my $err = $@;
    $cb->($err ? { ok => 0, error => "$err" } : { ok => 1, result => $res }) if $cb;
    return $id;
}

sub poll_async {
    my ($self, $timeout) = @_;
    return 0 unless $self->{bg_pid} && $self->{bg_sel};
    $timeout = 0 unless defined $timeout;

    my $count = 0;
    while ($self->{bg_sel}->can_read($timeout)) {
        $timeout = 0;
        my $chunk = '';
        my $n = sysread($self->{bg_out}, $chunk, 65536);
        last unless defined $n && $n > 0;
        $self->{bg_buf} .= $chunk;

        while ($self->{bg_buf} =~ s/^([^\n]*)\n//) {
            my $raw = $1;
            $count++;
            my $msg = eval { _json_decode($raw) } || {};
            my $id  = $msg->{id};
            if (defined $id && exists $self->{pending_async}{$id}) {
                my $cb = delete $self->{pending_async}{$id};
                $cb->($msg) if $cb;
            }
        }
    }
    return $count;
}

sub request_mt_sync {
    my ($self, $op, $args, $timeout_s) = @_;
    $timeout_s ||= 10.0;
    return undef unless $self->{bg_pid} && $self->{bg_in};

    my ($done, $payload);
    $self->submit_async($op, $args, sub {
        $payload = shift;
        $done    = 1;
    });
    my $deadline = Time::HiRes::time() + $timeout_s;
    while (!$done && Time::HiRes::time() < $deadline) {
        $self->poll_async(0.02);
    }
    return $payload;
}

sub shutdown {
    my ($self) = @_;
    if (defined $self->{bg_pid}) {
        eval {
            print { $self->{bg_in} } "__QUIT__\n" if $self->{bg_in};
            close $self->{bg_in}  if $self->{bg_in};
            close $self->{bg_out} if $self->{bg_out};
            waitpid($self->{bg_pid}, 0);
        };
        $self->{bg_pid}    = undef;
        $self->{bg_in}     = undef;
        $self->{bg_out}    = undef;
        $self->{bg_sel}    = undef;
        $self->{mt_req_ch} = undef;
    }
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    $self->shutdown();
}

sub capabilities {
    my ($self) = @_;
    return {
        ppi            => $self->{has_ppi},
        ppi_version    => $self->{ppi_version},
        critic         => $self->{has_critic},
        critic_version => $self->{critic_version},
        tidy           => $self->{has_tidy},
        tidy_version   => $self->{tidy_version},
        ppi_mode       => ($self->{has_ppi} ? 'inproc' : 'fallback'),
        critic_mode    => ($self->{has_critic} ? 'inproc' : ($self->{critic_cli} ? 'cli' : 'fallback')),
        tidy_mode      => ($self->{has_tidy} ? 'inproc' : ($self->{tidy_cli} ? 'cli' : 'fallback')),
        worker_mode    => $self->{worker_mode},
        has_mt         => _has_mt(),
    };
}

sub stats {
    my ($self) = @_;
    return {
        parse_count  => $self->{parse_count},
        cache_hits   => $self->{cache_hits},
        cached_docs  => scalar(keys %{ $self->{doc_cache} }),
        cached_crit  => scalar(keys %{ $self->{critic_cache} }),
        worker_mode  => $self->{worker_mode},
    };
}

sub clear_cache {
    my ($self, $buf_id) = @_;
    if (defined $buf_id) {
        my $prefix = "$buf_id:";
        for my $k (keys %{ $self->{doc_cache} }) {
            delete $self->{doc_cache}{$k} if index($k, $prefix) == 0;
        }
        $self->{doc_order} = [ grep { index($_, $prefix) != 0 } @{ $self->{doc_order} } ];
    }
    else {
        $self->{doc_cache} = {};
        $self->{doc_order} = [];
    }
    return 1;
}

# -------------------------------------------------------------------------
# Cached PPI::Document parser (reused by outline, critic, slice, refactor)
# -------------------------------------------------------------------------

sub parse_doc {
    my ($self, $buf_id, $rev, $text) = @_;
    return undef unless $self->{has_ppi};
    $buf_id = defined $buf_id ? "$buf_id" : 'anon';
    $rev    = defined $rev    ? "$rev"    : '0';
    $text   = '' unless defined $text;

    my $key = "$buf_id:$rev";
    if (exists $self->{doc_cache}{$key}) {
        $self->{cache_hits}++;
        return $self->{doc_cache}{$key};
    }

    # Evict older revisions of the same buffer
    my $prefix = "$buf_id:";
    for my $k (keys %{ $self->{doc_cache} }) {
        delete $self->{doc_cache}{$k} if index($k, $prefix) == 0;
    }
    $self->{doc_order} = [ grep { index($_, $prefix) != 0 } @{ $self->{doc_order} } ];

    my $copy = $text;
    my $doc = PPI::Document->new(\$copy);
    return undef unless $doc;
    $doc->index_locations();

    $self->{parse_count}++;
    $self->{doc_cache}{$key} = $doc;
    push @{ $self->{doc_order} }, $key;

    while (@{ $self->{doc_order} } > $self->{doc_max}) {
        my $oldest = shift @{ $self->{doc_order} };
        delete $self->{doc_cache}{$oldest};
    }

    return $doc;
}

sub _elem_end_line {
    my ($elem) = @_;
    return undef unless $elem;
    my $last = $elem->can('last_token') ? $elem->last_token : $elem;
    return undef unless $last;
    my $loc = $last->location;
    return undef unless $loc;
    my $content = $last->content // '';
    my $nl = ($content =~ tr/\n//);
    return $loc->[0] + $nl;
}

# -------------------------------------------------------------------------
# 1. Exact PPI AST Outline (+ clean fallback)
# -------------------------------------------------------------------------

sub outline {
    my ($self, $buf_id, $rev, $text, %opts) = @_;
    $text = '' unless defined $text;

    if (!$self->{has_ppi}) {
        return $self->_outline_fallback($text);
    }

    my $doc = $self->parse_doc($buf_id, $rev, $text);
    return $self->_outline_fallback($text) unless $doc;

    my @items;
    my $cur_pkg = 'main';

    # Packages
    for my $pkg (@{ $doc->find('PPI::Statement::Package') || [] }) {
        my $loc = $pkg->location or next;
        my $name = $pkg->namespace || 'main';
        push @items, {
            kind     => 'package',
            name     => $name,
            line     => $loc->[0],
            col      => $loc->[1],
            end_line => _elem_end_line($pkg) || $loc->[0],
            detail   => "package $name",
        };
    }

    # Build ordered package map for sub attribution
    my @pkg_spans = sort { $a->{line} <=> $b->{line} } grep { $_->{kind} eq 'package' } @items;
    my $pkg_at = sub {
        my ($ln) = @_;
        my $p = 'main';
        for my $ps (@pkg_spans) {
            last if $ps->{line} > $ln;
            $p = $ps->{name};
        }
        return $p;
    };

    # Subroutines
    for my $sub (@{ $doc->find('PPI::Statement::Sub') || [] }) {
        next if $sub->forward && !$opts{include_forward};
        my $loc = $sub->location or next;
        my $name = $sub->name;
        next unless defined $name && length $name;
        my $proto = $sub->prototype;
        my $sig = defined $proto ? "($proto)" : '';
        my $pkg = $pkg_at->($loc->[0]);
        push @items, {
            kind      => 'sub',
            name      => $name,
            package   => $pkg,
            full_name => "${pkg}::${name}",
            line      => $loc->[0],
            col       => $loc->[1],
            end_line  => _elem_end_line($sub) || $loc->[0],
            signature => $sig,
            detail    => "sub $name$sig",
        };
    }

    # Imports & constants
    for my $inc (@{ $doc->find('PPI::Statement::Include') || [] }) {
        my $loc = $inc->location or next;
        my $mod = $inc->module || '';
        my $type = $inc->type || 'use';
        if ($mod eq 'constant') {
            my $raw = $inc->content;
            my @names;
            if ($raw =~ /use\s+constant\s*\{(.*)\}/s) {
                my $body = $1;
                push @names, ($body =~ /\b([A-Za-z_]\w*)\s*=>/g);
            }
            elsif ($raw =~ /use\s+constant\s+([A-Za-z_]\w*)\b/) {
                push @names, $1;
            }
            if (@names) {
                for my $cn (@names) {
                    push @items, {
                        kind     => 'constant',
                        name     => $cn,
                        package  => $pkg_at->($loc->[0]),
                        line     => $loc->[0],
                        col      => $loc->[1],
                        end_line => _elem_end_line($inc) || $loc->[0],
                        detail   => "constant $cn",
                    };
                }
            }
            else {
                push @items, {
                    kind     => 'import',
                    name     => 'constant',
                    line     => $loc->[0],
                    col      => $loc->[1],
                    end_line => _elem_end_line($inc) || $loc->[0],
                    detail   => "$type constant",
                };
            }
        }
        elsif (length $mod) {
            push @items, {
                kind     => 'import',
                name     => $mod,
                line     => $loc->[0],
                col      => $loc->[1],
                end_line => _elem_end_line($inc) || $loc->[0],
                detail   => "$type $mod",
            };
        }
    }

    # File-scope globals (our / top-level my)
    for my $var (@{ $doc->find('PPI::Statement::Variable') || [] }) {
        my $parent = $var->parent;
        next unless $parent && $parent->isa('PPI::Document');
        my $vtype = $var->type || '';
        next unless $vtype eq 'our' || $vtype eq 'my';
        my $loc = $var->location or next;
        for my $sym ($var->variables) {
            push @items, {
                kind     => ($vtype eq 'our' ? 'global' : 'variable'),
                name     => $sym,
                package  => $pkg_at->($loc->[0]),
                line     => $loc->[0],
                col      => $loc->[1],
                end_line => _elem_end_line($var) || $loc->[0],
                detail   => "$vtype $sym",
            };
        }
    }

    # POD headings
    for my $pod (@{ $doc->find('PPI::Token::Pod') || [] }) {
        my $loc = $pod->location or next;
        my $base_line = $loc->[0];
        my @plines = split /\n/, $pod->content, -1;
        for my $idx (0 .. $#plines) {
            if ($plines[$idx] =~ /^=(head[1-4]|item)\s+(.+?)\s*$/) {
                push @items, {
                    kind     => 'pod',
                    name     => $2,
                    level    => $1,
                    line     => $base_line + $idx,
                    col      => 1,
                    end_line => $base_line + $idx,
                    detail   => "=$1 $2",
                };
            }
        }
    }

    @items = sort { $a->{line} <=> $b->{line} || ($a->{col} || 1) <=> ($b->{col} || 1) } @items;
    return {
        ok      => 1,
        backend => 'ppi',
        items   => \@items,
    };
}

sub _outline_fallback {
    my ($self, $text) = @_;
    my @lines = split /\n/, $text, -1;
    my @items;
    my $pkg = 'main';
    my $in_pod = 0;
    my %seen_subs;

    # Prefer NeoPerl::Core::Syntax C11 symbol extractor when loaded
    my $backend = 'fallback';
    if (eval { defined(&NeoPerl::Core::Syntax::extract_symbols_text) }) {
        my $csyms = eval { NeoPerl::Core::Syntax::extract_symbols_text('perl', $text) };
        if (ref($csyms) eq 'ARRAY' && @$csyms) {
            $backend = 'c11_fallback';
            for my $s (@$csyms) {
                my $ln = ($s->{line} // 0) + 1;
                my $col = ($s->{col} // 0) + 1;
                if (($s->{kind} || '') eq 'sub' || ($s->{kind} || '') eq 'function') {
                    $seen_subs{"$s->{name}:$ln"} = 1;
                    push @items, {
                        kind     => 'sub',
                        name     => $s->{name},
                        package  => $pkg,
                        line     => $ln,
                        col      => $col,
                        end_line => $ln,
                        detail   => "sub $s->{name}",
                    };
                }
            }
        }
    }

    for my $i (0 .. $#lines) {
        my $ln = $i + 1;
        my $line = $lines[$i];
        if ($line =~ /^=cut\b/) {
            $in_pod = 0;
            next;
        }
        if ($line =~ /^=(head[1-4]|item)\s+(.+?)\s*$/) {
            $in_pod = 1;
            push @items, {
                kind     => 'pod',
                name     => $2,
                level    => $1,
                line     => $ln,
                col      => 1,
                end_line => $ln,
                detail   => "=$1 $2",
            };
            next;
        }
        if ($line =~ /^=[a-zA-Z]/) {
            $in_pod = 1;
            next;
        }
        next if $in_pod;

        if ($line =~ /^\s*package\s+([A-Za-z_][\w:]*)\b/) {
            $pkg = $1;
            push @items, { kind => 'package', name => $pkg, line => $ln, col => 1, end_line => $ln, detail => "package $pkg" };
        }
        elsif ($line =~ /^\s*sub\s+([A-Za-z_]\w*)\b/ && !$seen_subs{"$1:$ln"}) {
            push @items, {
                kind      => 'sub',
                name      => $1,
                package   => $pkg,
                full_name => "${pkg}::$1",
                line      => $ln,
                col       => 1,
                end_line  => $ln,
                signature => '',
                detail    => "sub $1",
            };
        }
        elsif ($line =~ /^\s*use\s+constant\s+([A-Za-z_]\w*)\b/) {
            push @items, { kind => 'constant', name => $1, package => $pkg, line => $ln, col => 1, end_line => $ln, detail => "constant $1" };
        }
        elsif ($line =~ /^\s*(use|require)\s+([A-Za-z_][\w:]*)\b/) {
            push @items, { kind => 'import', name => $2, line => $ln, col => 1, end_line => $ln, detail => "$1 $2" };
        }
        elsif ($line =~ /^(our|my)\s+([\$\@\%][A-Za-z_]\w*)\b/) {
            push @items, {
                kind     => ($1 eq 'our' ? 'global' : 'variable'),
                name     => $2,
                package  => $pkg,
                line     => $ln,
                col      => 1,
                end_line => $ln,
                detail   => "$1 $2",
            };
        }
    }

    @items = sort { $a->{line} <=> $b->{line} || ($a->{col} || 1) <=> ($b->{col} || 1) } @items;
    return {
        ok      => 1,
        backend => $backend,
        items   => \@items,
    };
}

# -------------------------------------------------------------------------
# 2. PPI-backed Vim Motions & Text Objects (if/af, ip/ap, ]]/[[)
# -------------------------------------------------------------------------

sub text_object {
    my ($self, $buf_id, $rev, $text, $line, $col, $kind) = @_;
    $line ||= 1;
    $col  ||= 1;
    $kind ||= 'af';

    my @lines = split /\n/, ($text // ''), -1;

    if ($kind eq 'ip' || $kind eq 'ap') {
        if ($self->{has_ppi}) {
            my $doc = $self->parse_doc($buf_id, $rev, $text);
            if ($doc) {
                for my $pod (@{ $doc->find('PPI::Token::Pod') || [] }) {
                    my $loc = $pod->location or next;
                    my $s = $loc->[0];
                    my $e = _elem_end_line($pod) || $s;
                    if ($line >= $s && $line <= $e) {
                        my ($rs, $re) = ($s, $e);
                        if ($kind eq 'ip') {
                            $rs++ if $rs < $re && ($lines[$rs - 1] // '') =~ /^=/;
                            $re-- if $re > $rs && ($lines[$re - 1] // '') =~ /^=cut\b/;
                        }
                        return {
                            found      => 1,
                            kind       => $kind,
                            start_line => $rs,
                            start_col  => 1,
                            end_line   => $re,
                            end_col    => length($lines[$re - 1] // '') + 1,
                        };
                    }
                }
            }
        }
        # Fallback POD scan
        my ($ps, $pe);
        for my $i (0 .. $#lines) {
            my $ln = $i + 1;
            if (!defined $ps && $lines[$i] =~ /^=[a-zA-Z]/ && $lines[$i] !~ /^=cut\b/) {
                $ps = $ln;
            }
            elsif (defined $ps && $lines[$i] =~ /^=cut\b/) {
                $pe = $ln;
                if ($line >= $ps && $line <= $pe) {
                    my ($rs, $re) = ($ps, $pe);
                    if ($kind eq 'ip') {
                        $rs++ if $rs < $re;
                        $re-- if $re > $rs;
                    }
                    return {
                        found      => 1,
                        kind       => $kind,
                        start_line => $rs,
                        start_col  => 1,
                        end_line   => $re,
                        end_col    => length($lines[$re - 1] // '') + 1,
                    };
                }
                ($ps, $pe) = (undef, undef);
            }
        }
        return { found => 0, kind => $kind };
    }

    # if / af (inside/around enclosing sub)
    if ($self->{has_ppi}) {
        my $doc = $self->parse_doc($buf_id, $rev, $text);
        if ($doc) {
            my $best;
            my $best_span = 1e9;
            for my $sub (@{ $doc->find('PPI::Statement::Sub') || [] }) {
                next if $sub->forward;
                my $loc = $sub->location or next;
                my $s = $loc->[0];
                my $e = _elem_end_line($sub) || $s;
                if ($line >= $s && $line <= $e && ($e - $s) < $best_span) {
                    $best      = $sub;
                    $best_span = $e - $s;
                }
            }
            if ($best) {
                my $loc = $best->location;
                my $s = $loc->[0];
                my $e = _elem_end_line($best) || $s;
                if ($kind eq 'if') {
                    my $blk = $best->block;
                    if ($blk && $blk->location) {
                        my $bs = $blk->location->[0];
                        my $be = _elem_end_line($blk) || $e;
                        if ($be - $bs >= 2) {
                            $s = $bs + 1;
                            $e = $be - 1;
                        }
                        else {
                            $s = $bs;
                            $e = $be;
                        }
                    }
                }
                return {
                    found      => 1,
                    kind       => $kind,
                    name       => $best->name,
                    start_line => $s,
                    start_col  => 1,
                    end_line   => $e,
                    end_col    => length($lines[$e - 1] // '') + 1,
                };
            }
        }
    }

    # Fallback brace-matching sub finder
    my $sub_start;
    for (my $i = $line - 1; $i >= 0; $i--) {
        if ($lines[$i] =~ /^\s*sub\s+([A-Za-z_]\w*)\b/) {
            $sub_start = $i + 1;
            my $name = $1;
            my $depth = 0;
            my $seen_open = 0;
            my $sub_end = $sub_start;
            for my $j ($i .. $#lines) {
                my $l = $lines[$j];
                my $opens  = ($l =~ tr/{//);
                my $closes = ($l =~ tr/}//);
                $seen_open = 1 if $opens > 0;
                $depth += $opens - $closes;
                $sub_end = $j + 1;
                last if $seen_open && $depth <= 0;
            }
            if ($line >= $sub_start && $line <= $sub_end) {
                my ($rs, $re) = ($sub_start, $sub_end);
                if ($kind eq 'if' && $re - $rs >= 2) {
                    $rs++;
                    $re--;
                }
                return {
                    found      => 1,
                    kind       => $kind,
                    name       => $name,
                    start_line => $rs,
                    start_col  => 1,
                    end_line   => $re,
                    end_col    => length($lines[$re - 1] // '') + 1,
                };
            }
            last;
        }
    }

    return { found => 0, kind => $kind };
}

sub next_sub {
    my ($self, $buf_id, $rev, $text, $line, $dir) = @_;
    $line ||= 1;
    $dir = 1 unless defined $dir;

    my $out = $self->outline($buf_id, $rev, $text);
    my @subs = grep { $_->{kind} eq 'sub' } @{ $out->{items} || [] };
    if ($dir >= 0) {
        for my $s (@subs) {
            return $s if $s->{line} > $line;
        }
    }
    else {
        for my $s (reverse @subs) {
            return $s if $s->{line} < $line;
        }
    }
    return undef;
}

# -------------------------------------------------------------------------
# 3. Scope-Safe Lexical Rename (<leader>pr)
# -------------------------------------------------------------------------

sub _declares_symbol {
    my ($stmt, $target_sym) = @_;
    return 0 unless $stmt;

    if ($stmt->isa('PPI::Statement::Variable')) {
        return 0 unless ($stmt->type || '') eq 'my';
        for my $v ($stmt->variables) {
            return 1 if $v eq $target_sym;
        }
    }
    elsif ($stmt->isa('PPI::Statement::Compound')) {
        # for my $x (...) / foreach my $x (...)
        my @kids = $stmt->schildren;
        for my $i (0 .. $#kids - 1) {
            if ($kids[$i]->isa('PPI::Token::Word')
                && $kids[$i]->content eq 'my'
                && $kids[$i + 1]->isa('PPI::Token::Symbol')
                && $kids[$i + 1]->canonical eq $target_sym)
            {
                return 1;
            }
        }
    }
    return 0;
}

sub _block_redeclares_symbol {
    my ($block, $target_sym) = @_;
    return 0 unless $block && $block->can('schildren');
    for my $child ($block->schildren) {
        return 1 if _declares_symbol($child, $target_sym);
    }
    return 0;
}

sub _find_declaring_scope {
    my ($tok, $target_sym) = @_;
    my $node = $tok;
    while ($node) {
        my $parent = $node->parent;
        last unless $parent;

        # Check enclosing compound loop header (for my $x (...))
        if ($parent->isa('PPI::Statement::Compound') && _declares_symbol($parent, $target_sym)) {
            return ($parent, $parent);
        }

        if ($parent->isa('PPI::Structure::Block') || $parent->isa('PPI::Document')) {
            # Check all sibling statements up to and including $node's statement
            my $cur_stmt = $node;
            while ($cur_stmt && $cur_stmt->parent && $cur_stmt->parent != $parent) {
                $cur_stmt = $cur_stmt->parent;
            }
            for my $child ($parent->schildren) {
                if (_declares_symbol($child, $target_sym)) {
                    return ($parent, $child);
                }
                last if $cur_stmt && $child == $cur_stmt;
            }
            # Also check if parent is a sub block with subroutine signature
            my $gp = $parent->parent;
            if ($gp && $gp->isa('PPI::Statement::Sub')) {
                my $proto = $gp->prototype;
                if (defined $proto && $proto =~ /\Q$target_sym\E\b/) {
                    return ($gp, $gp);
                }
            }
        }
        $node = $parent;
    }
    return (undef, undef);
}

sub _collect_scoped_symbols {
    my ($node, $target_sym, $root_scope, $decl_stmt, $seen_decl_ref, $out) = @_;
    return unless $node;

    if ($node->isa('PPI::Token::Symbol')) {
        # Match direct symbol or indexed element ($arr[0] -> canonical @arr, $hash{k} -> %hash)
        my $canon = $node->canonical;
        my $raw   = $node->content;
        if ($canon eq $target_sym || $raw eq $target_sym) {
            push @$out, $node;
        }
        return;
    }

    return unless $node->can('schildren');

    # Stop if entering a nested lexical block/compound that redeclares $target_sym
    if ($node != $root_scope) {
        if ($node->isa('PPI::Statement::Compound') && _declares_symbol($node, $target_sym)) {
            return;
        }
        if ($node->isa('PPI::Structure::Block') && _block_redeclares_symbol($node, $target_sym)) {
            return;
        }
    }

    for my $child ($node->schildren) {
        if ($node == $root_scope && defined $decl_stmt) {
            if ($child == $decl_stmt) {
                $$seen_decl_ref = 1;
            }
            next unless $$seen_decl_ref;
        }
        _collect_scoped_symbols($child, $target_sym, $root_scope, $decl_stmt, $seen_decl_ref, $out);
    }
}

sub lexical_rename {
    my ($self, $buf_id, $rev, $text, $line, $col, $new_name) = @_;
    return { ok => 0, error => 'new name is empty' } unless defined $new_name && length $new_name;
    return { ok => 0, error => 'PPI is required for scope-safe lexical rename' } unless $self->{has_ppi};

    # Parse a fresh clone-safe document so cached AST is never mutated in place
    my $copy = $text // '';
    my $doc = PPI::Document->new(\$copy);
    return { ok => 0, error => 'failed to parse Perl document' } unless $doc;
    $doc->index_locations();

    # Find PPI::Token::Symbol under ($line, $col)
    my $target_tok;
    for my $tok (@{ $doc->find('PPI::Token::Symbol') || [] }) {
        my $loc = $tok->location or next;
        next unless $loc->[0] == $line;
        my $start_c = $loc->[1];
        my $end_c   = $start_c + length($tok->content) - 1;
        if ($col >= $start_c && $col <= $end_c) {
            $target_tok = $tok;
            last;
        }
    }
    return { ok => 0, error => "no lexical symbol at line $line col $col" } unless $target_tok;

    my $old_canon = $target_tok->canonical;    # e.g. '$count' or '@items'
    my ($sigil, $bare_old) = ($old_canon =~ /^([\$\@\%])(.*)$/);
    return { ok => 0, error => "unsupported symbol '$old_canon'" } unless defined $sigil;

    my $bare_new = $new_name;
    $bare_new =~ s/^[\$\@\%]//;
    return { ok => 0, error => "invalid identifier '$new_name'" } unless $bare_new =~ /^[A-Za-z_]\w*$/;
    my $new_canon = $sigil . $bare_new;

    my ($scope, $decl_stmt) = _find_declaring_scope($target_tok, $old_canon);
    if (!$scope) {
        return { ok => 0, error => "symbol '$old_canon' has no enclosing 'my' lexical declaration" };
    }

    my @matches;
    my $seen_decl = ($scope == $decl_stmt) ? 1 : 0;
    _collect_scoped_symbols($scope, $old_canon, $scope, $decl_stmt, \$seen_decl, \@matches);

    my @edits;
    for my $m (@matches) {
        my $loc = $m->location;
        my $raw = $m->content;
        my ($tok_sigil) = ($raw =~ /^([\$\@\%])/);
        $tok_sigil ||= $sigil;
        my $replacement = $tok_sigil . $bare_new;
        push @edits, {
            line     => $loc ? $loc->[0] : 0,
            col      => $loc ? $loc->[1] : 0,
            old_text => $raw,
            new_text => $replacement,
        };
        $m->set_content($replacement);
    }

    my $scope_loc = $scope->location;
    return {
        ok               => 1,
        old_name         => $old_canon,
        new_name         => $new_canon,
        scope_start_line => $scope_loc ? $scope_loc->[0] : 1,
        scope_end_line   => _elem_end_line($scope) || ($scope_loc ? $scope_loc->[0] : 1),
        count            => scalar(@edits),
        edits            => \@edits,
        new_text         => $doc->serialize,
    };
}

# -------------------------------------------------------------------------
# 4. Visual-Range Extract Subroutine (<leader>pe)
# -------------------------------------------------------------------------

sub extract_sub {
    my ($self, $buf_id, $rev, $text, $start_line, $end_line, $sub_name) = @_;
    return { ok => 0, error => 'invalid subroutine name' }
        unless defined $sub_name && $sub_name =~ /^[A-Za-z_]\w*$/;
    return { ok => 0, error => 'invalid line range' }
        unless defined $start_line && defined $end_line && $start_line >= 1 && $end_line >= $start_line;

    my @lines = split /\n/, ($text // ''), -1;
    return { ok => 0, error => 'line range out of bounds' } if $end_line > scalar(@lines);

    my @sel_lines = @lines[ ($start_line - 1) .. ($end_line - 1) ];
    my $sel_text  = join("\n", @sel_lines) . "\n";

    # Determine base indentation of selection
    my $base_indent = '';
    for my $l (@sel_lines) {
        next if $l =~ /^\s*$/;
        ($base_indent) = ($l =~ /^([ \t]*)/);
        last;
    }

    my @free_vars;
    my %seen_free;
    my %declared_in_sel;
    my %special_vars = map { $_ => 1 } (
        '$_', '@_', '$!', '$@', '$$', '$0', '$?', '$/', '$\\', '$,', '$"',
        '$^O', '$^X', '$^V', '$^W', '$^T', '$a', '$b', '%ENV', '%INC', '@INC', '@ARGV', '%SIG',
    );

    if ($self->{has_ppi}) {
        my $sel_copy = $sel_text;
        my $sel_doc = PPI::Document->new(\$sel_copy);
        if ($sel_doc) {
            # Collect variables declared inside selection
            for my $v (@{ $sel_doc->find('PPI::Statement::Variable') || [] }) {
                for my $sym ($v->variables) {
                    $declared_in_sel{$sym} = 1;
                }
            }
            for my $cmp (@{ $sel_doc->find('PPI::Statement::Compound') || [] }) {
                my @kids = $cmp->schildren;
                for my $i (0 .. $#kids - 1) {
                    if ($kids[$i]->isa('PPI::Token::Word')
                        && $kids[$i]->content eq 'my'
                        && $kids[$i + 1]->isa('PPI::Token::Symbol'))
                    {
                        $declared_in_sel{ $kids[$i + 1]->canonical } = 1;
                    }
                }
            }

            # Collect symbols declared before $start_line in the enclosing doc
            my %outer_lexicals;
            my $full_doc = $self->parse_doc($buf_id, $rev, $text);
            if ($full_doc) {
                for my $v (@{ $full_doc->find('PPI::Statement::Variable') || [] }) {
                    my $loc = $v->location or next;
                    next if $loc->[0] >= $start_line;
                    for my $sym ($v->variables) {
                        $outer_lexicals{$sym} = 1;
                    }
                }
                for my $cmp (@{ $full_doc->find('PPI::Statement::Compound') || [] }) {
                    my $loc = $cmp->location or next;
                    next if $loc->[0] >= $start_line;
                    my @kids = $cmp->schildren;
                    for my $i (0 .. $#kids - 1) {
                        if ($kids[$i]->isa('PPI::Token::Word')
                            && $kids[$i]->content eq 'my'
                            && $kids[$i + 1]->isa('PPI::Token::Symbol'))
                        {
                            $outer_lexicals{ $kids[$i + 1]->canonical } = 1;
                        }
                    }
                }
            }

            for my $tok (@{ $sel_doc->find('PPI::Token::Symbol') || [] }) {
                my $canon = $tok->canonical;
                next if $special_vars{$canon};
                next if $canon =~ /^\$\d+$/;
                next if $canon =~ /::/;
                next if $declared_in_sel{$canon};
                # Include if declared in outer scope OR scalar/array/hash lexical name
                next if %outer_lexicals && !$outer_lexicals{$canon};
                if (!$seen_free{$canon}++) {
                    push @free_vars, $canon;
                }
            }
        }
    }
    else {
        # Regex fallback for free scalar lexicals
        while ($sel_text =~ /\bmy\s+(?:\(([^)]+)\)|([\$\@\%][A-Za-z_]\w*))/g) {
            my $list = defined $1 ? $1 : $2;
            for my $s ($list =~ /([\$\@\%][A-Za-z_]\w*)/g) {
                $declared_in_sel{$s} = 1;
            }
        }
        while ($sel_text =~ /([\$\@\%][A-Za-z_]\w*)/g) {
            my $s = $1;
            next if $special_vars{$s} || $declared_in_sel{$s};
            if (!$seen_free{$s}++) {
                push @free_vars, $s;
            }
        }
    }

    # Build parameter list (pass arrays/hashes by ref if mixed with scalars, else direct)
    my @call_args;
    my @param_vars;
    my %ref_map;
    my $has_non_scalar = grep { !/^\$/ } @free_vars;

    for my $v (@free_vars) {
        if ($has_non_scalar && $v =~ /^([\@\%])(.+)$/) {
            my ($sg, $nm) = ($1, $2);
            my $ref_var = '$' . $nm . '_ref';
            push @call_args,  '\\' . $v;
            push @param_vars, $ref_var;
            $ref_map{$v} = $sg eq '@' ? "\@{$ref_var}" : "\%{$ref_var}";
        }
        else {
            push @call_args,  $v;
            push @param_vars, $v;
        }
    }

    # Normalize body indentation to 4 spaces
    my @body_lines;
    for my $l (@sel_lines) {
        my $stripped = $l;
        $stripped =~ s/^\Q$base_indent\E// if length $base_indent;
        for my $orig (keys %ref_map) {
            $stripped =~ s/\Q$orig\E\b/$ref_map{$orig}/g;
        }
        push @body_lines, (length($stripped) ? "    $stripped" : '');
    }

    my @sub_lines = ("sub $sub_name {");
    if (@param_vars) {
        push @sub_lines, '    my (' . join(', ', @param_vars) . ') = @_;';
    }
    push @sub_lines, @body_lines;
    push @sub_lines, '}';
    my $sub_code = join("\n", @sub_lines) . "\n";

    my $call_code = $base_indent . "$sub_name(" . join(', ', @call_args) . ");";

    # Find insertion point after enclosing sub (or at end of file before 1;)
    my $tobj = $self->text_object($buf_id, $rev, $text, $start_line, 1, 'af');
    my $insert_after = ($tobj && $tobj->{found}) ? $tobj->{end_line} : scalar(@lines);

    my @out_lines = @lines;
    splice(@out_lines, $start_line - 1, ($end_line - $start_line + 1), $call_code);

    my $delta = 1 - ($end_line - $start_line + 1);
    my $adj_insert = $insert_after + $delta;
    $adj_insert = scalar(@out_lines) if $adj_insert > scalar(@out_lines);
    $adj_insert = 0 if $adj_insert < 0;

    splice(@out_lines, $adj_insert, 0, '', @sub_lines);

    return {
        ok        => 1,
        sub_name  => $sub_name,
        params    => \@free_vars,
        call_args => \@call_args,
        call_code => $call_code,
        sub_code  => $sub_code,
        new_text  => join("\n", @out_lines),
    };
}

# -------------------------------------------------------------------------
# 5. PPI AI Context Slicer (neoperl_perl_slice)
# -------------------------------------------------------------------------

sub slice_context {
    my ($self, $buf_id, $rev, $text, $line, %opts) = @_;
    $text = '' unless defined $text;
    $line ||= 1;

    my @lines = split /\n/, $text, -1;
    my $total_lines = scalar(@lines);

    my $out = $self->outline($buf_id, $rev, $text);
    my @items = @{ $out->{items} || [] };

    # 1. Enclosing package
    my $pkg_item;
    for my $it (@items) {
        if ($it->{kind} eq 'package' && $it->{line} <= $line) {
            $pkg_item = $it;
        }
    }

    # 2. Imports & constants up to enclosing line (or file top)
    my @imports;
    my @import_lines;
    for my $it (@items) {
        if (($it->{kind} eq 'import' || $it->{kind} eq 'constant') && $it->{line} <= $line) {
            push @imports, $it->{name};
            my $s = $it->{line} - 1;
            my $e = ($it->{end_line} || $it->{line}) - 1;
            $e = $#lines if $e > $#lines;
            push @import_lines, @lines[$s .. $e];
        }
    }

    # 3. Enclosing sub
    my $enclosing_sub;
    my ($sub_start, $sub_end);
    for my $it (@items) {
        if ($it->{kind} eq 'sub' && $line >= $it->{line} && $line <= ($it->{end_line} || $it->{line})) {
            $enclosing_sub = $it;
            $sub_start     = $it->{line};
            $sub_end       = $it->{end_line} || $it->{line};
        }
    }

    my @sub_body;
    if ($enclosing_sub) {
        my $e = $sub_end > $total_lines ? $total_lines : $sub_end;
        @sub_body = @lines[ ($sub_start - 1) .. ($e - 1) ];
    }
    else {
        # Fallback: +/- 20 lines window around cursor
        $sub_start = $line - 20; $sub_start = 1 if $sub_start < 1;
        $sub_end   = $line + 20; $sub_end = $total_lines if $sub_end > $total_lines;
        @sub_body  = @lines[ ($sub_start - 1) .. ($sub_end - 1) ];
    }

    # 4. Referenced local sub signatures
    my %local_subs = map { $_->{name} => $_ } grep { $_->{kind} eq 'sub' } @items;
    my %ref_names;
    my $body_str = join("\n", @sub_body);

    if ($self->{has_ppi}) {
        my $sub_copy = $body_str;
        my $sub_doc = PPI::Document->new(\$sub_copy);
        if ($sub_doc) {
            for my $w (@{ $sub_doc->find('PPI::Token::Word') || [] }) {
                my $nm = $w->content;
                $nm =~ s/^.*:://;
                next if $enclosing_sub && $nm eq $enclosing_sub->{name};
                $ref_names{$nm} = 1 if exists $local_subs{$nm};
            }
        }
    }
    else {
        for my $nm (keys %local_subs) {
            next if $enclosing_sub && $nm eq $enclosing_sub->{name};
            $ref_names{$nm} = 1 if $body_str =~ /\b\Q$nm\E\s*\(/ || $body_str =~ /->\s*\Q$nm\E\b/;
        }
    }

    my @referenced_subs;
    my @sig_lines;
    for my $nm (sort { $local_subs{$a}{line} <=> $local_subs{$b}{line} } keys %ref_names) {
        my $info = $local_subs{$nm};
        my $decl_line = $lines[ $info->{line} - 1 ] // "sub $nm";
        # Also include parameter-unpack line if immediately following sub header
        my $unpack = '';
        if ($info->{line} < $total_lines && ($lines[$info->{line}] // '') =~ /^\s*my\s*\([^)]+\)\s*=\s*\@_;/) {
            $unpack = "\n" . $lines[$info->{line}];
        }
        push @referenced_subs, {
            name      => $nm,
            line      => $info->{line},
            signature => $decl_line . $unpack,
        };
        push @sig_lines, "# line $info->{line}", $decl_line . $unpack . '  # ...';
    }

    my @chunks;
    if ($pkg_item) {
        push @chunks, "package $pkg_item->{name};";
    }
    if (@import_lines) {
        push @chunks, join("\n", @import_lines);
    }
    if (@sig_lines) {
        push @chunks, "# Referenced local subroutines:\n" . join("\n", @sig_lines);
    }
    push @chunks, "# Target slice (lines $sub_start-$sub_end):\n" . join("\n", @sub_body);

    my $sliced_text  = join("\n\n", @chunks) . "\n";
    my $sliced_lines = scalar(split /\n/, $sliced_text);

    return {
        ok                => 1,
        backend           => $out->{backend},
        package           => ($pkg_item ? $pkg_item->{name} : 'main'),
        enclosing_sub     => ($enclosing_sub ? $enclosing_sub->{name} : undef),
        start_line        => $sub_start,
        end_line          => $sub_end,
        imports           => \@imports,
        referenced_subs   => \@referenced_subs,
        original_lines    => $total_lines,
        sliced_lines      => $sliced_lines,
        compression_ratio => ($total_lines > 0 ? sprintf('%.2f', $sliced_lines / $total_lines) + 0 : 1.0),
        text              => $sliced_text,
    };
}

# -------------------------------------------------------------------------
# 6. Workspace gd / gr powered by PPI AST
# -------------------------------------------------------------------------

sub find_definition {
    my ($self, $files_map, $symbol) = @_;
    return [] unless defined $symbol && length $symbol && ref($files_map) eq 'HASH';

    my ($target_pkg, $target_sub) = $symbol =~ /^(.*)::([^:]+)$/ ? ($1, $2) : (undef, $symbol);
    my @hits;

    for my $path (sort keys %$files_map) {
        my $text = $files_map->{$path};
        next unless defined $text;
        my $out = $self->outline("ws:$path", length($text), $text);
        for my $it (@{ $out->{items} || [] }) {
            if ($it->{kind} eq 'sub' && $it->{name} eq $target_sub) {
                next if defined $target_pkg && ($it->{package} || '') ne $target_pkg;
                push @hits, {
                    file      => $path,
                    line      => $it->{line},
                    col       => $it->{col} || 1,
                    kind      => 'sub',
                    name      => $it->{name},
                    full_name => $it->{full_name},
                    detail    => $it->{detail},
                };
            }
            elsif ($it->{kind} eq 'package' && $it->{name} eq $symbol) {
                push @hits, {
                    file   => $path,
                    line   => $it->{line},
                    col    => $it->{col} || 1,
                    kind   => 'package',
                    name   => $it->{name},
                    detail => $it->{detail},
                };
            }
        }
    }
    return \@hits;
}

sub find_references {
    my ($self, $files_map, $symbol) = @_;
    return [] unless defined $symbol && length $symbol && ref($files_map) eq 'HASH';

    my $bare = $symbol;
    $bare =~ s/^.*:://;
    my @refs;

    for my $path (sort keys %$files_map) {
        my $text = $files_map->{$path};
        next unless defined $text;
        my @lines = split /\n/, $text, -1;

        if ($self->{has_ppi}) {
            my $doc = $self->parse_doc("ws:$path", length($text), $text);
            next unless $doc;
            for my $tok (@{ $doc->find('PPI::Token::Word') || [] }) {
                my $c = $tok->content;
                next unless $c eq $symbol || $c eq $bare || $c =~ /::\Q$bare\E$/;
                my $loc = $tok->location or next;
                push @refs, {
                    file => $path,
                    line => $loc->[0],
                    col  => $loc->[1],
                    text => $lines[ $loc->[0] - 1 ] // '',
                };
            }
        }
        else {
            for my $i (0 .. $#lines) {
                next if $lines[$i] =~ /^\s*#/;
                if ($lines[$i] =~ /\b\Q$bare\E\b/) {
                    push @refs, {
                        file => $path,
                        line => $i + 1,
                        col  => ($-[0] || 0) + 1,
                        text => $lines[$i],
                    };
                }
            }
        }
    }
    return \@refs;
}

# -------------------------------------------------------------------------
# 7. Perl::Critic Live Engine (reuses cached PPI::Document, zero double-parse)
# -------------------------------------------------------------------------

sub discover_rc {
    my ($self, $rc_name, $start_path) = @_;
    if (defined $start_path && length $start_path) {
        my $dir = -d $start_path ? $start_path : File::Basename::dirname($start_path);
        my $prev = '';
        while (defined $dir && length $dir && $dir ne $prev) {
            my $cand = File::Spec->catfile($dir, $rc_name);
            return $cand if -f $cand;
            # Stop at repo root after checking it
            last if -d File::Spec->catdir($dir, '.git');
            $prev = $dir;
            $dir  = File::Basename::dirname($dir);
        }
    }
    if (defined $ENV{HOME} && length $ENV{HOME}) {
        my $home_rc = File::Spec->catfile($ENV{HOME}, $rc_name);
        return $home_rc if -f $home_rc;
    }
    return undef;
}

sub classify_policy {
    my ($self, $policy) = @_;
    my $short = $policy // '';
    $short =~ s/^Perl::Critic::Policy:://;
    my $is_mech = $MECHANICAL_POLICIES{$short} ? 1 : 0;
    return ($short, $is_mech, $is_mech ? 'bonsai' : 'gemini');
}

sub _get_critic_instance {
    my ($self, $rc_path, $severity) = @_;
    $severity = 4 unless defined $severity && $severity >= 1 && $severity <= 5;
    my $key = (defined $rc_path ? $rc_path : '<none>') . ":$severity";
    return $self->{critic_cache}{$key} if exists $self->{critic_cache}{$key};

    my %args = (-severity => $severity);
    if (defined $rc_path && -f $rc_path) {
        $args{-profile} = $rc_path;
    }
    else {
        $args{-profile} = '';
    }
    my $c = Perl::Critic->new(%args);
    $self->{critic_cache}{$key} = $c;
    return $c;
}

sub critic {
    my ($self, $buf_id, $rev, $text, %opts) = @_;
    $text = '' unless defined $text;
    my $severity = defined $opts{severity} ? $opts{severity} : 4;
    my $rc_path  = defined $opts{profile}
        ? $opts{profile}
        : $self->discover_rc('.perlcriticrc', $opts{file_path});

    if ($self->{has_critic} && $self->{has_ppi}) {
        my $doc = $self->parse_doc($buf_id, $rev, $text);
        if ($doc) {
            my $critic = $self->_get_critic_instance($rc_path, $severity);
            my @raw = eval { $critic->critique($doc) };
            if (!$@) {
                my @diags;
                for my $v (@raw) {
                    my ($short, $mech, $tier) = $self->classify_policy($v->policy);
                    my $csev = $v->severity || 3;
                    my $dsev = $csev >= 5 ? 'error' : ($csev >= 3 ? 'warning' : 'info');
                    push @diags, {
                        line            => $v->line_number   || 1,
                        col             => $v->column_number || 1,
                        severity        => $dsev,
                        critic_severity => $csev,
                        policy          => $v->policy,
                        short_policy    => $short,
                        description     => $v->description,
                        explanation     => (ref($v->explanation) ? join(', ', @{$v->explanation}) : ($v->explanation // '')),
                        message         => $v->description . " [$short]",
                        source          => 'perlcritic',
                        mechanical      => $mech,
                        tier            => $tier,
                    };
                }
                return {
                    ok          => 1,
                    backend     => 'inproc',
                    rc_path     => $rc_path,
                    severity    => $severity,
                    violations  => \@diags,
                    parse_count => $self->{parse_count},
                    cache_hits  => $self->{cache_hits},
                };
            }
        }
    }

    # CLI fallback when perlcritic binary exists and not forced to built-in
    if (!$opts{skip_cli} && $self->{critic_cli}) {
        my $cli_res = $self->_critic_cli($text, $rc_path, $severity);
        return $cli_res if $cli_res && $cli_res->{ok};
    }

    # Built-in lightweight Perl static analyzer fallback
    return $self->_critic_builtin($text, $rc_path, $severity, $opts{file_path});
}

sub _critic_cli {
    my ($self, $text, $rc_path, $severity) = @_;
    my @cmd = ($self->{critic_cli}, "--severity=$severity", '--verbose=%l\t%c\t%s\t%p\t%m\n');
    push @cmd, "--profile=$rc_path" if defined $rc_path && -f $rc_path;
    my ($in, $out, $err);
    $err = Symbol::gensym();
    my $pid = eval { IPC::Open3::open3($in, $out, $err, @cmd) };
    return undef unless $pid;
    print {$in} $text;
    close $in;
    local $/;
    my $stdout = <$out> // '';
    close $out;
    close $err;
    waitpid($pid, 0);

    my @diags;
    for my $line (split /\n/, $stdout) {
        my ($ln, $col, $csev, $pol, $msg) = split /\t/, $line, 5;
        next unless defined $ln && $ln =~ /^\d+$/;
        my ($short, $mech, $tier) = $self->classify_policy($pol);
        my $dsev = ($csev || 3) >= 5 ? 'error' : (($csev || 3) >= 3 ? 'warning' : 'info');
        push @diags, {
            line            => $ln + 0,
            col             => ($col || 1) + 0,
            severity        => $dsev,
            critic_severity => ($csev || 3) + 0,
            policy          => $pol,
            short_policy    => $short,
            description     => $msg,
            message         => "$msg [$short]",
            source          => 'perlcritic',
            mechanical      => $mech,
            tier            => $tier,
        };
    }
    return {
        ok         => 1,
        backend    => 'cli',
        rc_path    => $rc_path,
        severity   => $severity,
        violations => \@diags,
    };
}

sub _critic_builtin {
    my ($self, $text, $rc_path, $severity, $file_path) = @_;
    my @lines = split /\n/, $text, -1;
    my @diags;

    my $has_strict   = ($text =~ /\buse\s+(?:strict|v5\.(?:1[2-9]|[2-9]\d)|5\.0(?:1[2-9]|[2-9]\d)|Moo|Moose|Mojolicious)\b/) ? 1 : 0;
    my $has_warnings = ($text =~ /\buse\s+(?:warnings|v5\.(?:3[5-9]|[4-9]\d)|Moo|Moose|Mojolicious)\b/) ? 1 : 0;

    if (!$has_strict) {
        my ($short, $mech, $tier) = $self->classify_policy('Perl::Critic::Policy::TestingAndDebugging::RequireUseStrict');
        push @diags, {
            line => 1, col => 1, severity => 'error', critic_severity => 5,
            policy => "Perl::Critic::Policy::$short", short_policy => $short,
            description => 'Code before strictures are enabled',
            message => "Code before strictures are enabled [$short]",
            source => 'perlcritic', mechanical => $mech, tier => $tier,
        };
    }
    if (!$has_warnings && $severity <= 4) {
        my ($short, $mech, $tier) = $self->classify_policy('Perl::Critic::Policy::TestingAndDebugging::RequireUseWarnings');
        push @diags, {
            line => 1, col => 1, severity => 'warning', critic_severity => 4,
            policy => "Perl::Critic::Policy::$short", short_policy => $short,
            description => 'Code before warnings are enabled',
            message => "Code before warnings are enabled [$short]",
            source => 'perlcritic', mechanical => $mech, tier => $tier,
        };
    }

    for my $i (0 .. $#lines) {
        my $ln = $i + 1;
        my $l  = $lines[$i];
        next if $l =~ /^\s*#/;
        if ($l =~ /\breturn\s+undef\b/) {
            my ($short, $mech, $tier) = $self->classify_policy('Perl::Critic::Policy::Subroutines::ProhibitExplicitReturnUndef');
            push @diags, {
                line => $ln, col => ($-[0] || 0) + 1, severity => 'error', critic_severity => 5,
                policy => "Perl::Critic::Policy::$short", short_policy => $short,
                description => '"return" statement with explicit "undef"',
                message => qq{"return" statement with explicit "undef" [$short]},
                source => 'perlcritic', mechanical => $mech, tier => $tier,
            };
        }
        if ($l =~ /\bopen\s*\(?\s*([A-Z][A-Z0-9_]*)\s*,/) {
            my ($short, $mech, $tier) = $self->classify_policy('Perl::Critic::Policy::InputOutput::ProhibitBarewordFileHandles');
            push @diags, {
                line => $ln, col => ($-[0] || 0) + 1, severity => 'error', critic_severity => 5,
                policy => "Perl::Critic::Policy::$short", short_policy => $short,
                description => 'Bareword file handle opened',
                message => "Bareword file handle opened [$short]",
                source => 'perlcritic', mechanical => $mech, tier => $tier,
            };
        }
        if ($l =~ /\bopen\s*\(?\s*(?:my\s+\$\w+|\$\w+|[A-Z][A-Z0-9_]*)\s*,\s*['"][<>+|][^'"]*['"]\s*\)?\s*(?:or|\|\||;)/) {
            my ($short, $mech, $tier) = $self->classify_policy('Perl::Critic::Policy::InputOutput::ProhibitTwoArgOpen');
            push @diags, {
                line => $ln, col => ($-[0] || 0) + 1, severity => 'error', critic_severity => 5,
                policy => "Perl::Critic::Policy::$short", short_policy => $short,
                description => 'Two-argument "open" used',
                message => qq{Two-argument "open" used [$short]},
                source => 'perlcritic', mechanical => $mech, tier => $tier,
            };
        }
    }

    return {
        ok         => 1,
        backend    => 'fallback',
        rc_path    => $rc_path,
        severity   => $severity,
        violations => \@diags,
    };
}

# -------------------------------------------------------------------------
# 8. Perl::Tidy Formatting (full buffer, visual range, post-tidy gate)
# -------------------------------------------------------------------------

sub tidy {
    my ($self, $text, %opts) = @_;
    $text = '' unless defined $text;

    my $rc_path = defined $opts{profile}
        ? $opts{profile}
        : $self->discover_rc('.perltidyrc', $opts{file_path});

    if ($self->{has_tidy}) {
        my $src  = $text;
        my $dest = '';
        my $stderr_str = '';
        my $errfile    = '';
        my @argv;
        if (defined $rc_path && -f $rc_path) {
            @argv = ('-nst', '-se', "-pro=$rc_path");
        }
        else {
            @argv = ('-npro', @_DEFAULT_TIDY_ARGV);
        }
        push @argv, @{ $opts{extra_argv} } if ref($opts{extra_argv}) eq 'ARRAY';

        my $err = Perl::Tidy::perltidy(
            source      => \$src,
            destination => \$dest,
            stderr      => \$stderr_str,
            errorfile   => \$errfile,
            argv        => \@argv,
        );
        if (!$err && length($dest) > 0) {
            return {
                ok      => 1,
                backend => 'inproc',
                rc_path => $rc_path,
                text    => $dest,
                changed => ($dest ne $text ? 1 : 0),
                stderr  => $stderr_str,
            };
        }
        return {
            ok      => 0,
            backend => 'inproc',
            rc_path => $rc_path,
            text    => $text,
            changed => 0,
            error   => ($errfile || $stderr_str || "Perl::Tidy failed (code $err)"),
        };
    }

    if (!$opts{skip_cli} && $self->{tidy_cli}) {
        my $cli_res = $self->_tidy_cli($text, $rc_path);
        return $cli_res if $cli_res && $cli_res->{ok};
    }

    return $self->_tidy_builtin($text, $rc_path);
}

sub _tidy_cli {
    my ($self, $text, $rc_path) = @_;
    my @cmd = ($self->{tidy_cli}, '-st', '-se');
    if (defined $rc_path && -f $rc_path) {
        push @cmd, "-pro=$rc_path";
    }
    else {
        push @cmd, '-npro', '-l=100', '-i=4';
    }
    my ($in, $out, $err);
    $err = Symbol::gensym();
    my $pid = eval { IPC::Open3::open3($in, $out, $err, @cmd) };
    return undef unless $pid;
    print {$in} $text;
    close $in;
    local $/;
    my $dest = <$out> // '';
    my $es   = <$err> // '';
    close $out;
    close $err;
    waitpid($pid, 0);
    return undef if $? != 0 || !length($dest);
    return {
        ok      => 1,
        backend => 'cli',
        rc_path => $rc_path,
        text    => $dest,
        changed => ($dest ne $text ? 1 : 0),
        stderr  => $es,
    };
}

sub _tidy_builtin {
    my ($self, $text, $rc_path) = @_;
    my @lines = split /\n/, $text, -1;
    my $depth = 0;
    my @out;
    for my $l (@lines) {
        $l =~ s/[ \t]+$//;
        if ($l =~ /^\s*$/) {
            push @out, '';
            next;
        }
        my $trimmed = $l;
        $trimmed =~ s/^\s+//;
        my $lead_close = ($trimmed =~ /^[\}\]\)]/) ? 1 : 0;
        my $cur = $depth - $lead_close;
        $cur = 0 if $cur < 0;
        push @out, ('    ' x $cur) . $trimmed;
        my $opens  = ($trimmed =~ tr/{//);
        my $closes = ($trimmed =~ tr/}//);
        $depth += $opens - $closes;
        $depth = 0 if $depth < 0;
    }
    my $dest = join("\n", @out);
    $dest .= "\n" if $text =~ /\n\z/ && $dest !~ /\n\z/;
    return {
        ok      => 1,
        backend => 'fallback',
        rc_path => $rc_path,
        text    => $dest,
        changed => ($dest ne $text ? 1 : 0),
    };
}

sub tidy_range {
    my ($self, $full_text, $start_line, $end_line, %opts) = @_;
    $full_text = '' unless defined $full_text;
    my $had_trailing_nl = ($full_text =~ /\n\z/) ? 1 : 0;
    my @lines = split /\n/, $full_text, -1;
    pop @lines if $had_trailing_nl && @lines && $lines[-1] eq '';

    return { ok => 0, error => 'invalid line range' }
        if !defined $start_line || !defined $end_line || $start_line < 1 || $end_line < $start_line || $end_line > scalar(@lines);

    my @slice = @lines[ ($start_line - 1) .. ($end_line - 1) ];

    # Detect minimum common leading indentation of non-empty lines
    my $base_indent;
    for my $l (@slice) {
        next if $l =~ /^\s*$/;
        my ($ind) = ($l =~ /^([ \t]*)/);
        if (!defined $base_indent || length($ind) < length($base_indent)) {
            $base_indent = $ind;
        }
    }
    $base_indent //= '';

    my @dedented = map {
        my $x = $_;
        $x =~ s/^\Q$base_indent\E// if length $base_indent;
        $x;
    } @slice;

    my $frag = join("\n", @dedented) . "\n";
    my $res  = $self->tidy($frag, %opts);
    return $res unless $res && $res->{ok};

    my $tidied_frag = $res->{text};
    $tidied_frag =~ s/\n\z//;
    my @tidied_lines = map {
        length($_) ? ($base_indent . $_) : '';
    } split(/\n/, $tidied_frag, -1);

    my @new_lines = @lines;
    splice(@new_lines, $start_line - 1, ($end_line - $start_line + 1), @tidied_lines);
    my $new_full = join("\n", @new_lines) . ($had_trailing_nl ? "\n" : '');

    return {
        ok          => 1,
        backend     => $res->{backend},
        rc_path     => $res->{rc_path},
        base_indent => $base_indent,
        start_line  => $start_line,
        end_line    => $end_line,
        text        => $new_full,
        range_text  => join("\n", @tidied_lines) . "\n",
        changed     => ($new_full ne $full_text ? 1 : 0),
    };
}

1;

__END__

=head1 NAME

NeoPerl::Plugin::PerlDev::Worker - Cached PPI, Perl::Critic, and Perl::Tidy engine

=head1 SYNOPSIS

    use NeoPerl::Plugin::PerlDev::Worker;

    my $w = NeoPerl::Plugin::PerlDev::Worker->new;
    my $out  = $w->outline(1, 1, $perl_source);
    my $crit = $w->critic(1, 1, $perl_source);   # reuses cached PPI::Document
    my $tidy = $w->tidy($perl_source);

=head1 DESCRIPTION

Maintains warm C<PPI>, C<Perl::Critic>, and C<Perl::Tidy> instances with a
per-C<(buf_id, rev)> C<PPI::Document> cache so structural outlines, AI context
slices, scope-safe lexical renames, extract-sub refactorings, and live
C<Perl::Critic> diagnostics share a single parse. Automatically adds
C<$HOME/perl5/lib/perl5> (including versioned architecture directories) to
C<@INC> when present, supports optional background execution through
C<perl5-mt> C<MT::Worker> channels, and degrades cleanly to CLI or built-in
analyzers when CPAN modules are unavailable.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
