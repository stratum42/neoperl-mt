package NeoPerl::LSP::Engine;

use strict;
use warnings;
use Carp qw(croak);
use IO::Handle ();
use JSON::PP ();

our $VERSION = '0.01';

my $HAS_MOJO_JSON;
BEGIN {
    $HAS_MOJO_JSON = eval { require Mojo::JSON; 1 } ? 1 : 0;
}

sub _encode_json {
    return $HAS_MOJO_JSON
        ? Mojo::JSON::encode_json($_[0])
        : JSON::PP->new->utf8->encode($_[0]);
}

sub _decode_json {
    return $HAS_MOJO_JSON
        ? Mojo::JSON::decode_json($_[0])
        : JSON::PP->new->utf8->decode($_[0]);
}

sub _jtrue  { $HAS_MOJO_JSON ? Mojo::JSON::true()  : JSON::PP::true  }
sub _jfalse { $HAS_MOJO_JSON ? Mojo::JSON::false() : JSON::PP::false }

sub new {
    my ($class, %opts) = @_;
    my $provider = $opts{provider}
        or croak "NeoPerl::LSP::Engine->new requires 'provider'";

    return bless {
        provider           => $provider,
        server_name        => $opts{server_name}    || 'npl-lsp',
        server_version     => $opts{server_version} || $VERSION,
        default_lang       => $opts{lang}           || 'all',
        in_fh              => $opts{in_fh}          || \*STDIN,
        out_fh             => $opts{out_fh}         || \*STDOUT,
        docs               => {},    # uri => { uri, languageId, version, text }
        initialized        => 0,
        shutdown_requested => 0,
        exited             => 0,
        exit_code          => 0,
    }, $class;
}

sub provider  { $_[0]{provider} }
sub documents { $_[0]{docs} }
sub exit_code { $_[0]{exit_code} }

sub _write_frame {
    my ($self, $msg) = @_;
    return 0 unless ref($msg) eq 'HASH';
    my $json = _encode_json($msg);
    my $frame = "Content-Length: " . length($json) . "\r\n\r\n" . $json;
    my $out = $self->{out_fh};
    return 0 unless $out;
    local $SIG{PIPE} = 'IGNORE';
    print {$out} $frame;
    $out->flush;
    return 1;
}

sub read_frame {
    my ($self, $fh) = @_;
    $fh ||= $self->{in_fh};
    return undef unless $fh;

    my $content_length;
    while (1) {
        my $line = <$fh>;
        return undef unless defined $line;
        $line =~ s/\r?\n\z//;
        last if $line eq '';
        if ($line =~ /\AContent-Length:\s*(\d+)\z/i) {
            $content_length = int($1);
        }
    }
    return undef unless defined $content_length && $content_length >= 0;

    my $buf  = '';
    my $need = $content_length;
    while ($need > 0) {
        my $chunk = '';
        my $n = read($fh, $chunk, $need);
        return undef unless defined $n && $n > 0;
        $buf  .= $chunk;
        $need -= $n;
    }

    my $msg = eval { _decode_json($buf) };
    return ref($msg) eq 'HASH' ? $msg : undef;
}

sub _apply_content_changes {
    my ($text, $changes) = @_;
    return $text unless ref($changes) eq 'ARRAY';
    for my $ch (@$changes) {
        next unless ref($ch) eq 'HASH' && defined $ch->{text};
        if (ref($ch->{range}) eq 'HASH') {
            my $s = $ch->{range}{start} || {};
            my $e = $ch->{range}{end}   || {};
            my @lines = split /\n/, $text, -1;
            my $sl = int($s->{line}      // 0);
            my $sc = int($s->{character} // 0);
            my $el = int($e->{line}      // $sl);
            my $ec = int($e->{character} // $sc);
            $sl = 0 if $sl < 0;
            $el = 0 if $el < 0;
            $sl = $#lines if $sl > $#lines;
            $el = $#lines if $el > $#lines;
            my $prefix = substr($lines[$sl] // '', 0, $sc);
            my $suffix = substr($lines[$el] // '', $ec);
            my @head = $sl > 0 ? @lines[ 0 .. $sl - 1 ] : ();
            my @tail = $el < $#lines ? @lines[ $el + 1 .. $#lines ] : ();
            $text = join("\n", @head, $prefix . $ch->{text} . $suffix, @tail);
        }
        else {
            $text = $ch->{text};
        }
    }
    return $text;
}

sub _normalize_diagnostics {
    my ($raw) = @_;
    return [] unless ref($raw) eq 'ARRAY';
    my %sev_to_lsp = (
        error   => 1,
        warn    => 2,
        warning => 2,
        info    => 3,
        hint    => 4,
    );
    my @out;
    for my $d (@$raw) {
        next unless ref($d) eq 'HASH';
        if (ref($d->{range}) eq 'HASH') {
            push @out, $d;
            next;
        }
        my $line     = int($d->{line}     // 0);
        my $col      = int($d->{col}      // 0);
        my $end_line = int($d->{end_line} // $line);
        my $end_col  = int($d->{end_col}  // ($col + 1));
        $line     = 0 if $line < 0;
        $col      = 0 if $col < 0;
        $end_line = $line if $end_line < $line;
        $end_col  = $col  if $end_line == $line && $end_col < $col;

        my $sev_raw = $d->{severity};
        my $sev = (defined $sev_raw && $sev_raw =~ /\A[1-4]\z/)
            ? int($sev_raw)
            : ($sev_to_lsp{ lc($sev_raw // 'warn') } || 2);

        push @out, {
            range => {
                start => { line => $line,     character => $col },
                end   => { line => $end_line, character => $end_col },
            },
            severity => $sev,
            (defined $d->{code} && length $d->{code} ? (code => "$d->{code}") : ()),
            source   => $d->{source}  || 'npl-lsp',
            message  => $d->{message} // '',
        };
    }
    return \@out;
}

sub _publish_diagnostics_for {
    my ($self, $doc, $out_notifications) = @_;
    return unless $doc && defined $doc->{uri};
    my $prov = $self->{provider};
    my $raw = $prov->can('diagnostics')
        ? eval { $prov->diagnostics($doc) }
        : [];
    my $norm = _normalize_diagnostics($raw);
    my $notif = {
        jsonrpc => '2.0',
        method  => 'textDocument/publishDiagnostics',
        params  => {
            uri         => $doc->{uri},
            diagnostics => $norm,
        },
    };
    if (ref($out_notifications) eq 'ARRAY') {
        push @$out_notifications, $notif;
    }
    else {
        $self->_write_frame($notif);
    }
    return $norm;
}

sub handle_message {
    my ($self, $msg, %opts) = @_;
    my @frames;
    return \@frames unless ref($msg) eq 'HASH';

    my $method = $msg->{method};
    my $has_id = exists $msg->{id};
    my $id     = $msg->{id};
    my $params = ref($msg->{params}) eq 'HASH' ? $msg->{params} : {};
    my $prov   = $self->{provider};

    return \@frames unless defined $method;

    if ($method eq 'initialize') {
        $self->{initialized} = 1;
        push @frames, {
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                serverInfo => {
                    name    => $self->{server_name},
                    version => $self->{server_version},
                },
                capabilities => {
                    textDocumentSync => {
                        openClose => _jtrue(),
                        change    => 1,
                        save      => { includeText => _jtrue() },
                    },
                    hoverProvider          => _jtrue(),
                    completionProvider     => {
                        resolveProvider   => _jfalse(),
                        triggerCharacters => [ '.', '%', ':', '_', '-', '>' ],
                    },
                    documentSymbolProvider => _jtrue(),
                    definitionProvider     => _jtrue(),
                },
            },
        };
        return \@frames;
    }

    if ($method eq 'initialized' || $method eq '$/setTrace' || $method eq '$/cancelRequest') {
        return \@frames;
    }

    if ($method eq 'shutdown') {
        $self->{shutdown_requested} = 1;
        push @frames, {
            jsonrpc => '2.0',
            id      => $id,
            result  => undef,
        };
        return \@frames;
    }

    if ($method eq 'exit') {
        $self->{exited}    = 1;
        $self->{exit_code} = $self->{shutdown_requested} ? 0 : 1;
        return \@frames;
    }

    if ($method eq 'textDocument/didOpen') {
        my $td = $params->{textDocument} || {};
        my $uri = $td->{uri};
        if (defined $uri && length $uri) {
            my $doc = {
                uri        => $uri,
                languageId => $td->{languageId} || $self->{default_lang},
                version    => $td->{version}    // 1,
                text       => $td->{text}       // '',
            };
            $self->{docs}{$uri} = $doc;
            $self->_publish_diagnostics_for($doc, \@frames);
        }
        return \@frames;
    }

    if ($method eq 'textDocument/didChange') {
        my $td  = $params->{textDocument} || {};
        my $uri = $td->{uri};
        if (defined $uri && exists $self->{docs}{$uri}) {
            my $doc = $self->{docs}{$uri};
            $doc->{version} = $td->{version} if defined $td->{version};
            $doc->{text}    = _apply_content_changes($doc->{text}, $params->{contentChanges});
            $self->_publish_diagnostics_for($doc, \@frames);
        }
        return \@frames;
    }

    if ($method eq 'textDocument/didSave') {
        my $td  = $params->{textDocument} || {};
        my $uri = $td->{uri};
        if (defined $uri && exists $self->{docs}{$uri}) {
            my $doc = $self->{docs}{$uri};
            $doc->{text} = $params->{text} if defined $params->{text};
            $self->_publish_diagnostics_for($doc, \@frames);
        }
        return \@frames;
    }

    if ($method eq 'textDocument/didClose') {
        my $td  = $params->{textDocument} || {};
        my $uri = $td->{uri};
        if (defined $uri) {
            delete $self->{docs}{$uri};
            push @frames, {
                jsonrpc => '2.0',
                method  => 'textDocument/publishDiagnostics',
                params  => { uri => $uri, diagnostics => [] },
            };
        }
        return \@frames;
    }

    if ($method eq 'textDocument/hover') {
        my $uri = ($params->{textDocument} || {})->{uri};
        my $pos = $params->{position} || {};
        my $doc = defined($uri) ? $self->{docs}{$uri} : undef;
        my $res;
        if ($doc && $prov->can('hover')) {
            $res = eval { $prov->hover($doc, int($pos->{line} // 0), int($pos->{character} // 0)) };
        }
        push @frames, {
            jsonrpc => '2.0',
            id      => $id,
            result  => $res,
        } if $has_id;
        return \@frames;
    }

    if ($method eq 'textDocument/completion') {
        my $uri = ($params->{textDocument} || {})->{uri};
        my $pos = $params->{position} || {};
        my $doc = defined($uri) ? $self->{docs}{$uri} : undef;
        my $items = [];
        if ($doc && $prov->can('completion')) {
            my $got = eval { $prov->completion($doc, int($pos->{line} // 0), int($pos->{character} // 0)) };
            if (ref($got) eq 'HASH' && ref($got->{items}) eq 'ARRAY') {
                $items = $got->{items};
            }
            elsif (ref($got) eq 'ARRAY') {
                $items = $got;
            }
        }
        push @frames, {
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                isIncomplete => _jfalse(),
                items        => $items,
            },
        } if $has_id;
        return \@frames;
    }

    if ($method eq 'textDocument/documentSymbol') {
        my $uri = ($params->{textDocument} || {})->{uri};
        my $doc = defined($uri) ? $self->{docs}{$uri} : undef;
        my $syms = [];
        if ($doc && $prov->can('document_symbol')) {
            my $got = eval { $prov->document_symbol($doc) };
            $syms = $got if ref($got) eq 'ARRAY';
        }
        push @frames, {
            jsonrpc => '2.0',
            id      => $id,
            result  => $syms,
        } if $has_id;
        return \@frames;
    }

    if ($method eq 'textDocument/definition') {
        my $uri = ($params->{textDocument} || {})->{uri};
        my $pos = $params->{position} || {};
        my $doc = defined($uri) ? $self->{docs}{$uri} : undef;
        my $loc;
        if ($doc && $prov->can('definition')) {
            $loc = eval { $prov->definition($doc, int($pos->{line} // 0), int($pos->{character} // 0)) };
        }
        push @frames, {
            jsonrpc => '2.0',
            id      => $id,
            result  => $loc,
        } if $has_id;
        return \@frames;
    }

    if ($has_id) {
        push @frames, {
            jsonrpc => '2.0',
            id      => $id,
            error   => {
                code    => -32601,
                message => "Method not found: $method",
            },
        };
    }
    return \@frames;
}

sub run {
    my ($self) = @_;
    binmode($self->{in_fh});
    binmode($self->{out_fh});
    $self->{out_fh}->autoflush(1);

    while (!$self->{exited}) {
        my $msg = $self->read_frame($self->{in_fh});
        last unless defined $msg;
        my $frames = $self->handle_message($msg);
        for my $f (@$frames) {
            $self->_write_frame($f);
        }
    }
    return $self->{exit_code};
}

1;

__END__

=head1 NAME

NeoPerl::LSP::Engine - Reusable JSON-RPC 2.0 Content-Length stdio LSP server loop

=head1 SYNOPSIS

    use NeoPerl::LSP::Engine;
    use NeoPerl::LSP::Builtin;

    my $provider = NeoPerl::LSP::Builtin->new(lang => 'cobol');
    my $engine   = NeoPerl::LSP::Engine->new(provider => $provider);
    exit $engine->run();

=head1 DESCRIPTION

Implements a lightweight, zero-dependency Language Server Protocol 3.17
JSON-RPC 2.0 transport over C<Content-Length>-framed standard input and output,
handling document synchronization, diagnostics publication, hover, completion,
document symbols, go-to-definition, and orderly shutdown.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
