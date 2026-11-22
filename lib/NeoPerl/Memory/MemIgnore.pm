package NeoPerl::Memory::MemIgnore;

use strict;
use warnings;
use File::Spec ();

our $VERSION = '0.01';

our @DEFAULT_PATH_GLOBS = (
    '.env',
    '.env.*',
    '*.pem',
    '*.key',
    '*.p12',
    '*.pfx',
    '*.kdbx',
    'id_rsa',
    'id_rsa.*',
    'id_ed25519',
    'id_ed25519.*',
    'id_ecdsa',
    '*secret*',
    '*credentials*',
    '.netrc',
    '.pgpass',
    '*.jks',
    '*.keystore',
);

our @DEFAULT_SECRET_RULES = (
    {
        name    => 'pem_private_key',
        pattern => qr/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/,
        replace => '[REDACTED:PEM_PRIVATE_KEY]',
    },
    {
        name    => 'aws_access_key',
        pattern => qr/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
        replace => '[REDACTED:AWS_KEY]',
    },
    {
        name    => 'github_token',
        pattern => qr/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b/,
        replace => '[REDACTED:GH_TOKEN]',
    },
    {
        name    => 'slack_token',
        pattern => qr/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
        replace => '[REDACTED:SLACK_TOKEN]',
    },
    {
        name    => 'google_api_key',
        pattern => qr/\bAIza[0-9A-Za-z_-]{35}\b/,
        replace => '[REDACTED:API_KEY]',
    },
    {
        name    => 'openai_like_key',
        pattern => qr/\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_-]{20,}\b/,
        replace => '[REDACTED:SECRET_KEY]',
    },
    {
        name    => 'bearer_token',
        pattern => qr/(Authorization\s*:\s*Bearer\s+)[^\s"']+|\b(Bearer\s+)[A-Za-z0-9._~+\/-]{16,}=*/i,
        replace => sub {
            my ($p1, $p2) = @_;
            return (defined($p1) ? $p1 : $p2) . '[REDACTED:BEARER]';
        },
    },
    {
        name    => 'uri_credentials',
        pattern => qr{(\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)([^/\s@]+)(\@)}i,
        replace => sub {
            my ($p1, undef, $p3) = @_;
            return $p1 . '[REDACTED:PASS]' . $p3;
        },
    },
    {
        name    => 'kv_secret_assignment',
        pattern => qr/\b((?:db_?|api_?|auth_?|client_?|access_?|private_?)?(?:password|passwd|pwd|secret|token|api_key|apikey)\s*[:=]\s*)(?:"[^"\r\n]{4,}"|'[^'\r\n]{4,}'|[^\s,;'"#]{6,})/i,
        replace => sub {
            my ($prefix) = @_;
            return $prefix . '[REDACTED:SECRET]';
        },
    },
);

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        repo_root    => $args{repo_root},
        path_globs   => [ @DEFAULT_PATH_GLOBS ],
        path_regexes => [],
        negations    => [],
        secret_rules => [ @DEFAULT_SECRET_RULES ],
        loaded_files => [],
    }, $class;

    if (ref($args{extra_patterns}) eq 'ARRAY') {
        for my $pat (@{ $args{extra_patterns} }) {
            $self->add_path_pattern($pat);
        }
    }

    if (ref($args{extra_secret_rules}) eq 'ARRAY') {
        push @{ $self->{secret_rules} }, @{ $args{extra_secret_rules} };
    }

    $self->_rebuild_path_matchers();

    if (defined $args{repo_root} && length $args{repo_root}) {
        my $repo_file = File::Spec->catfile($args{repo_root}, '.memignore');
        $self->load_file($repo_file) if -f $repo_file;
    }

    if (defined $args{ignore_file} && -f $args{ignore_file}) {
        $self->load_file($args{ignore_file});
    }

    return $self;
}

sub load_file {
    my ($self, $path) = @_;
    return 0 unless defined $path && -f $path;
    open my $fh, '<:encoding(UTF-8)', $path or return 0;
    my $count = 0;
    while (my $line = <$fh>) {
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next if $line eq '' || $line =~ /^#/;
        $self->add_path_pattern($line);
        $count++;
    }
    close $fh;
    push @{ $self->{loaded_files} }, $path;
    $self->_rebuild_path_matchers();
    return $count;
}

sub add_path_pattern {
    my ($self, $pattern) = @_;
    return unless defined $pattern && length $pattern;
    if ($pattern =~ /^!(.+)$/) {
        push @{ $self->{negations} }, $1;
    }
    else {
        push @{ $self->{path_globs} }, $pattern;
    }
    $self->_rebuild_path_matchers();
    return 1;
}

sub _glob_to_regex {
    my ($glob) = @_;
    my $anchored = ($glob =~ s{^/}{}) ? 1 : 0;
    my $dir_only = ($glob =~ s{/$}{}) ? 1 : 0;

    my $re = '';
    my $len = length($glob);
    my $i = 0;
    while ($i < $len) {
        my $c = substr($glob, $i, 1);
        if ($c eq '*') {
            if ($i + 1 < $len && substr($glob, $i + 1, 1) eq '*') {
                $re .= '.*';
                $i += 2;
                $i++ if $i < $len && substr($glob, $i, 1) eq '/';
                next;
            }
            $re .= '[^/]*';
        }
        elsif ($c eq '?') {
            $re .= '[^/]';
        }
        else {
            $re .= quotemeta($c);
        }
        $i++;
    }

    my $has_slash = ($glob =~ m{/}) ? 1 : 0;
    if ($anchored || $has_slash) {
        $re = '\A' . $re . ($dir_only ? '(?:/.*)?\z' : '\z');
    }
    else {
        $re = '(?:\A|/)' . $re . ($dir_only ? '(?:/.*)?\z' : '\z');
    }
    return qr/$re/i;
}

sub _rebuild_path_matchers {
    my ($self) = @_;
    $self->{path_regexes}    = [ map { _glob_to_regex($_) } @{ $self->{path_globs} } ];
    $self->{negation_regexes} = [ map { _glob_to_regex($_) } @{ $self->{negations} } ];
    return;
}

sub is_path_ignored {
    my ($self, $path) = @_;
    return 0 unless defined $path && length $path;

    my $norm = $path;
    $norm =~ s{\\}{/}g;
    if (defined $self->{repo_root} && length $self->{repo_root}) {
        my $root = $self->{repo_root};
        $root =~ s{\\}{/}g;
        $root =~ s{/$}{};
        $norm =~ s{\A\Q$root\E/}{};
    }
    $norm =~ s{\A\./}{};

    my $ignored = 0;
    for my $re (@{ $self->{path_regexes} }) {
        if ($norm =~ $re) {
            $ignored = 1;
            last;
        }
    }
    if ($ignored) {
        for my $re (@{ $self->{negation_regexes} }) {
            if ($norm =~ $re) {
                $ignored = 0;
                last;
            }
        }
    }
    return $ignored;
}

sub redact_text {
    my ($self, $text) = @_;
    return wantarray ? ('', 0) : '' unless defined $text;

    my $out   = $text;
    my $count = 0;
    for my $rule (@{ $self->{secret_rules} }) {
        my $re  = $rule->{pattern};
        my $rep = $rule->{replace};
        if (ref($rep) eq 'CODE') {
            $count += ($out =~ s/$re/$rep->($1, $2, $3)/ge);
        }
        else {
            $count += ($out =~ s/$re/$rep/g);
        }
    }
    return wantarray ? ($out, $count) : $out;
}

sub contains_secret {
    my ($self, $text) = @_;
    return 0 unless defined $text && length $text;
    my (undef, $count) = $self->redact_text($text);
    return $count > 0 ? 1 : 0;
}

sub sanitize_event {
    my ($self, $event) = @_;
    return undef unless ref($event) eq 'HASH';

    my $file = $event->{file_path} // $event->{file};
    if (defined $file && $self->is_path_ignored($file)) {
        return undef;
    }

    my %copy = %$event;
    my $total_redactions = 0;
    for my $key (qw(text content summary diff message prompt response)) {
        next unless defined $copy{$key} && !ref($copy{$key});
        my ($clean, $n) = $self->redact_text($copy{$key});
        $copy{$key} = $clean;
        $total_redactions += $n;
    }
    $copy{_redactions} = $total_redactions;
    return \%copy;
}

sub loaded_files {
    my ($self) = @_;
    return [ @{ $self->{loaded_files} } ];
}

1;

__END__

=head1 NAME

NeoPerl::Memory::MemIgnore - Path filtering and secret redaction for memory capture

=head1 SYNOPSIS

    use NeoPerl::Memory::MemIgnore;

    my $ig = NeoPerl::Memory::MemIgnore->new(repo_root => '/path/to/repo');
    next if $ig->is_path_ignored('.env.production');
    my ($clean, $n) = $ig->redact_text($text);

=head1 DESCRIPTION

C<NeoPerl::Memory::MemIgnore> enforces path ignore rules from C<.memignore>
together with built-in secret patterns (PEM keys, API keys, bearer tokens,
credential assignments, and URI passwords) before event text is passed to
local memory distillation or persisted in the memory database.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
