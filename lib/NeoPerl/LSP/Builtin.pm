package NeoPerl::LSP::Builtin;

use strict;
use warnings;
use NeoPerl::MCP::Registry;

our $VERSION = '0.01';

my %LANG_ALIAS = (
    sql      => 'sql',
    ddl      => 'sql',
    dcl      => 'db2z',
    spl      => 'informix',
    db2i     => 'db2i',
    db2_i    => 'db2i',
    ibmi     => 'db2i',
    db2luw   => 'db2luw',
    db2_luw  => 'db2luw',
    db2z     => 'db2z',
    db2_z    => 'db2z',
    db2zos   => 'db2z',
    informix => 'informix',
    hlasm    => 'hlasm',
    hla      => 'hlasm',
    mlc      => 'hlasm',
    mac      => 'hlasm',
    asm      => 'asm',
    s        => 'asm',
    ppc64le  => 'asm',
    amd64    => 'asm',
    arm64    => 'asm',
    s390x    => 'asm',
    rpgile   => 'rpgile',
    rpgle    => 'rpgile',
    sqlrpgle => 'rpgile',
    rpg      => 'rpgile',
    rpginc   => 'rpgile',
    cobol    => 'cobol',
    cbl      => 'cobol',
    cob      => 'cobol',
    cpy      => 'cobol',
    sycl     => 'sycl',
    cl       => 'sycl',
    opencl   => 'sycl',
    intel_gpu => 'sycl',
    hip      => 'hip',
    cu       => 'hip',
    cuh      => 'hip',
    rocm     => 'hip',
    amd_gpu  => 'hip',
    glsl     => 'glsl',
    vert     => 'glsl',
    frag     => 'glsl',
    comp     => 'glsl',
    spvasm   => 'glsl',
    spirv    => 'glsl',
    vulkan   => 'glsl',
    metal    => 'metal',
    msl      => 'metal',
    all      => 'all',
);

my %LANG_TO_PACKS = (
    sql      => [qw(db2i db2luw db2z informix)],
    db2i     => [qw(db2i)],
    db2luw   => [qw(db2luw)],
    db2z     => [qw(db2z)],
    informix => [qw(informix)],
    hlasm    => [qw(hlasm)],
    asm      => [qw(asm)],
    rpgile   => [qw(rpgile)],
    cobol    => [qw(cobol)],
    sycl     => [qw(intel_gpu)],
    hip      => [qw(amd_gpu)],
    glsl     => [qw(vulkan)],
    metal    => [qw(metal)],
    all      => [qw(db2i db2luw db2z informix hlasm rpgile cobol asm intel_gpu amd_gpu vulkan metal)],
);

my @SUPPORTED_LANGS = qw(
    sql db2i db2luw db2z informix
    hlasm asm rpgile cobol
    sycl hip glsl metal all
);

my %SUPPORTED_FILETYPES = map { $_ => 1 } qw(
    sql spl ddl dcl db2i db2luw db2z informix
    hlasm asm rpgile cobol
    sycl hip glsl metal
);

sub supported_langs {
    return [ @SUPPORTED_LANGS ];
}

sub supported_filetypes {
    return [ sort keys %SUPPORTED_FILETYPES ];
}

sub handles_filetype {
    my ($class_or_self, $ft) = @_;
    return 0 unless defined $ft && length $ft;
    return $SUPPORTED_FILETYPES{ lc($ft) } ? 1 : 0;
}

sub normalize_lang {
    my ($class_or_self, $lang) = @_;
    return 'all' unless defined $lang && length $lang;
    my $k = lc($lang);
    $k =~ s/\A\s+|\s+\z//g;
    return $LANG_ALIAS{$k} || 'all';
}

sub new {
    my ($class, %opts) = @_;
    my $reg = $opts{registry} || NeoPerl::MCP::Registry->new(
        editor => $opts{editor},
    );
    return bless {
        lang     => $class->normalize_lang($opts{lang} || 'all'),
        registry => $reg,
    }, $class;
}

sub lang         { $_[0]{lang} }
sub registry     { $_[0]{registry} }
sub set_registry { $_[0]{registry} = $_[1] if $_[1]; return $_[0] }

sub _infer_lang_from_doc {
    my ($self, $doc) = @_;
    my $explicit = $self->{lang};
    return $explicit if defined $explicit && $explicit ne 'all';

    if (ref($doc) eq 'HASH') {
        my $lid = $doc->{languageId} // $doc->{filetype} // '';
        if (length $lid && exists $LANG_ALIAS{ lc($lid) } && $LANG_ALIAS{ lc($lid) } ne 'all') {
            return $LANG_ALIAS{ lc($lid) };
        }
        my $uri = $doc->{uri} // $doc->{path} // '';
        if ($uri =~ /\.([A-Za-z0-9]+)\z/) {
            my $ext = lc($1);
            return $LANG_ALIAS{$ext} if exists $LANG_ALIAS{$ext};
        }
    }
    return 'all';
}

sub _packs_for_doc {
    my ($self, $doc, $mode) = @_;
    my $lang = $self->_infer_lang_from_doc($doc);
    my $text = (ref($doc) eq 'HASH' && defined $doc->{text}) ? $doc->{text} : '';
    my @names;

    if ($lang eq 'sql') {
        # Prioritize the most specific SQL dialect based on document content clues
        my @prio;
        push @prio, 'db2i'     if $text =~ /\bQSYS2\b|\*SYS\b|\bSQLRPGLE\b|\bCCSID\b|\bQAQQINI\b/i;
        push @prio, 'db2luw'   if $text =~ /\bSYSCAT\b|\bVECTOR_DISTANCE\b|\bORGANIZE\s+BY\s+COLUMN\b|\bMON_GET_/i;
        push @prio, 'db2z'     if $text =~ /\bSYSIBM\b|\bPLAN_TABLE\b|\bDCLGEN\b|\bBIND\s+PACKAGE\b/i;
        push @prio, 'informix' if $text =~ /\bsysmaster\b|\bFOREACH\b|\bON\s+EXCEPTION\b|\bLOCK\s+MODE\s+ROW\b|\bCREATE\s+(?:DBA\s+)?PROCEDURE\b|\bBIGSERIAL\b|\bLVARCHAR\b/i;

        if ($mode && $mode eq 'diagnostics' && @prio) {
            @names = @prio;
        }
        else {
            my %seen;
            for my $n (@prio, @{ $LANG_TO_PACKS{sql} }) {
                next if $seen{$n}++;
                push @names, $n;
            }
        }
    }
    else {
        @names = @{ $LANG_TO_PACKS{$lang} || $LANG_TO_PACKS{all} };
    }

    my @packs;
    for my $pname (@names) {
        my $p = $self->{registry}->get_pack($pname);
        push @packs, $p if $p;
    }
    return ($lang, \@packs);
}

sub _line_at {
    my ($text, $line_idx) = @_;
    return '' unless defined $text;
    my @lines = split /\r?\n/, $text, -1;
    return '' if $line_idx < 0 || $line_idx > $#lines;
    return $lines[$line_idx] // '';
}

sub _extract_token_candidates {
    my ($line_text, $col) = @_;
    return () unless defined $line_text && length $line_text;
    my $len = length($line_text);
    $col = 0 if $col < 0;
    $col = $len - 1 if $col >= $len;

    # Adjust slightly left if cursor sits immediately after a word
    if ($col > 0 && substr($line_text, $col, 1) !~ /[A-Za-z0-9_%\-\.\:\$]/) {
        $col-- if substr($line_text, $col - 1, 1) =~ /[A-Za-z0-9_%\-\.\:\$]/;
    }

    my @cands;
    my %seen;
    my $add = sub {
        my ($w) = @_;
        return unless defined $w && length $w;
        $w =~ s/\A[\.\:\-]+|[\.\:\-]+\z//g;
        return unless length $w;
        push @cands, $w unless $seen{$w}++;
    };

    # 1. Extended domain token (allows %BIF, COMP-3, QSYS2.SYSTABLES, sysmaster:syslocks, DCL-PROC)
    my ($s1, $e1) = ($col, $col);
    $s1-- while $s1 > 0 && substr($line_text, $s1 - 1, 1) =~ /[A-Za-z0-9_%\-\.\:\$]/;
    $e1++ while $e1 + 1 < $len && substr($line_text, $e1 + 1, 1) =~ /[A-Za-z0-9_%\-\.\:\$]/;
    my $ext = substr($line_text, $s1, $e1 - $s1 + 1);
    $add->($ext);

    # 2. Hyphen/percent token without dots/colons (e.g. %TRIM, DCL-PROC, COMP-3, std140)
    my ($s2, $e2) = ($col, $col);
    $s2-- while $s2 > 0 && substr($line_text, $s2 - 1, 1) =~ /[A-Za-z0-9_%\-]/;
    $e2++ while $e2 + 1 < $len && substr($line_text, $e2 + 1, 1) =~ /[A-Za-z0-9_%\-]/;
    my $mid = substr($line_text, $s2, $e2 - $s2 + 1);
    $add->($mid);

    # 3. Plain identifier token (allows leading % for RPGILE)
    my ($s3, $e3) = ($col, $col);
    $s3-- while $s3 > 0 && substr($line_text, $s3 - 1, 1) =~ /[A-Za-z0-9_%]/;
    $e3++ while $e3 + 1 < $len && substr($line_text, $e3 + 1, 1) =~ /[A-Za-z0-9_]/;
    my $plain = substr($line_text, $s3, $e3 - $s3 + 1);
    $add->($plain);

    # 4. If dotted/colon token (e.g. QSYS2.SYSTABLES), also try tail component
    if ($ext =~ /[\.\:]([A-Za-z0-9_\-]+)\z/) {
        $add->($1);
    }

    return @cands;
}

sub _extract_prefix {
    my ($line_text, $col) = @_;
    return '' unless defined $line_text;
    $col = 0 if $col < 0;
    $col = length($line_text) if $col > length($line_text);
    my $before = substr($line_text, 0, $col);
    if ($before =~ /([A-Za-z0-9_%\-\.\:\$]+)\z/) {
        return $1;
    }
    return '';
}

sub hover {
    my ($self, $doc, $line, $char) = @_;
    return undef unless ref($doc) eq 'HASH';
    my $text = $doc->{text} // '';
    my $line_text = _line_at($text, int($line // 0));
    my @cands = _extract_token_candidates($line_text, int($char // 0));
    return undef unless @cands;

    my ($lang, $packs) = $self->_packs_for_doc($doc, 'hover');

    for my $word (@cands) {
        for my $pack (@$packs) {
            my $res = eval { $pack->lsp_hover($word, $line_text, $lang) };
            next unless defined $res;
            if (ref($res) eq 'HASH') {
                if (ref($res->{contents}) eq 'HASH') {
                    return $res;
                }
                my $val = $res->{contents} // $res->{value} // $res->{markdown} // '';
                next unless length $val;
                return {
                    contents => {
                        kind  => $res->{kind} || 'markdown',
                        value => $val,
                    },
                };
            }
            elsif (!ref($res) && length $res) {
                return {
                    contents => {
                        kind  => 'markdown',
                        value => $res,
                    },
                };
            }
        }
    }

    return undef;
}

sub completion {
    my ($self, $doc, $line, $char) = @_;
    return [] unless ref($doc) eq 'HASH';
    my $text      = $doc->{text} // '';
    my $line_text = _line_at($text, int($line // 0));
    my $prefix    = _extract_prefix($line_text, int($char // 0));

    my ($lang, $packs) = $self->_packs_for_doc($doc, 'completion');

    my @items;
    my %seen;
    for my $pack (@$packs) {
        my $got = eval { $pack->lsp_completions($prefix, $line_text, $lang) };
        next unless ref($got) eq 'ARRAY';
        for my $it (@$got) {
            next unless ref($it) eq 'HASH' && defined $it->{label} && length $it->{label};
            next if $seen{ $it->{label} }++;
            push @items, {
                label => $it->{label},
                kind  => int($it->{kind} || 14),
                (defined $it->{detail}        && length $it->{detail}        ? (detail        => $it->{detail})        : ()),
                (defined $it->{documentation} && length $it->{documentation} ? (documentation => $it->{documentation}) : ()),
                (defined $it->{insertText}    && length $it->{insertText}    ? (insertText    => $it->{insertText})    : ()),
            };
        }
    }

    return \@items;
}

sub diagnostics {
    my ($self, $doc) = @_;
    return [] unless ref($doc) eq 'HASH';
    my $text = $doc->{text} // '';
    my ($lang, $packs) = $self->_packs_for_doc($doc, 'diagnostics');

    my @diags;
    my %seen;
    for my $pack (@$packs) {
        my $got = eval { $pack->lsp_diagnostics($text, $lang) };
        next unless ref($got) eq 'ARRAY';
        for my $d (@$got) {
            next unless ref($d) eq 'HASH';
            my $key = join('|',
                $d->{line} // 0,
                $d->{col}  // 0,
                $d->{code} // '',
                $d->{message} // '',
            );
            next if $seen{$key}++;
            push @diags, {
                line     => int($d->{line}     // 0),
                col      => int($d->{col}      // 0),
                end_line => int($d->{end_line} // ($d->{line} // 0)),
                end_col  => int($d->{end_col}  // (($d->{col} // 0) + 1)),
                severity => $d->{severity} || 'warn',
                code     => defined($d->{code}) ? "$d->{code}" : '',
                message  => $d->{message} // '',
                source   => $d->{source}  || $pack->name,
            };
        }
    }

    return \@diags;
}

sub editor_symbols {
    my ($self, $doc) = @_;
    return [] unless ref($doc) eq 'HASH';
    my $text = $doc->{text} // '';
    my ($lang, $packs) = $self->_packs_for_doc($doc, 'symbols');

    my @syms;
    my %seen;
    for my $pack (@$packs) {
        my $got = eval { $pack->lsp_symbols($text, $lang) };
        next unless ref($got) eq 'ARRAY';
        for my $s (@$got) {
            next unless ref($s) eq 'HASH' && defined $s->{name} && length $s->{name};
            my $key = join('|', $s->{name}, $s->{line} // 0);
            next if $seen{$key}++;
            push @syms, {
                name     => $s->{name},
                kind     => $s->{kind} || 12,
                line     => int($s->{line} // 0),
                col      => int($s->{col}  // 0),
                end_line => int($s->{end_line} // ($s->{line} // 0)),
                detail   => $s->{detail} // '',
            };
        }
    }
    return \@syms;
}

sub document_symbol {
    my ($self, $doc) = @_;
    my $raw = $self->editor_symbols($doc);
    my @out;
    for my $s (@$raw) {
        my $line = $s->{line};
        my $col  = $s->{col};
        my $end_line = $s->{end_line} >= $line ? $s->{end_line} : $line;
        my $end_col  = $col + length($s->{name});
        push @out, {
            name           => $s->{name},
            kind           => int($s->{kind} || 12),
            detail         => $s->{detail} // '',
            range          => {
                start => { line => $line,     character => $col },
                end   => { line => $end_line, character => $end_col },
            },
            selectionRange => {
                start => { line => $line, character => $col },
                end   => { line => $line, character => $end_col },
            },
        };
    }
    return \@out;
}

sub definition {
    my ($self, $doc, $line, $char) = @_;
    return undef unless ref($doc) eq 'HASH';
    my $text = $doc->{text} // '';
    my $line_text = _line_at($text, int($line // 0));
    my @cands = _extract_token_candidates($line_text, int($char // 0));
    return undef unless @cands;

    my $syms = $self->editor_symbols($doc);
    my $uri  = $doc->{uri} || '';

    for my $word (@cands) {
        my $w_lc = lc($word);
        for my $s (@$syms) {
            if (lc($s->{name}) eq $w_lc) {
                my $sl = $s->{line};
                my $sc = $s->{col};
                return {
                    uri   => $uri,
                    range => {
                        start => { line => $sl, character => $sc },
                        end   => { line => $sl, character => $sc + length($s->{name}) },
                    },
                };
            }
        }
    }

    # Fallback: scan lines for label / declaration matching the symbol
    my @lines = split /\r?\n/, $text, -1;
    for my $word (@cands) {
        next if length($word) < 2;
        my $re = qr/\A\s*\Q$word\E(?:\s*[:\.]|\s+(?:DSECT|CSECT|RSECT|EQU|MACRO|SECTION)\b)/i;
        for my $idx (0 .. $#lines) {
            if ($lines[$idx] =~ $re) {
                return {
                    uri   => $uri,
                    range => {
                        start => { line => $idx, character => 0 },
                        end   => { line => $idx, character => length($word) },
                    },
                };
            }
        }
    }

    return undef;
}

1;

__END__

=head1 NAME

NeoPerl::LSP::Builtin - Zero-dependency built-in LSP provider powered by the 12 MCP domain packs

=head1 SYNOPSIS

    use NeoPerl::LSP::Builtin;

    my $lsp = NeoPerl::LSP::Builtin->new(lang => 'hlasm');
    my $hover = $lsp->hover({ uri => 'file:///tmp/demo.hlasm', text => "         NNPA\n" }, 0, 10);
    my $diags = $lsp->diagnostics({ uri => 'file:///tmp/demo.hlasm', text => $src });

=head1 DESCRIPTION

C<NeoPerl::LSP::Builtin> provides in-process and standalone LSP capabilities
(diagnostics, hover, completion, document symbols, and go-to-definition) across
all twelve database, mainframe/midrange, multi-ISA assembly, and GPU
compute domains by delegating directly to the C<lsp_*> hooks of the
C<NeoPerl::MCP::Pack::*> modules.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
