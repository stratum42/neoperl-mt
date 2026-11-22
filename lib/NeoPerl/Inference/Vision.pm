package NeoPerl::Inference::Vision;

use strict;
use warnings;
use Carp qw(croak);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Spec ();
use File::Temp qw(tempdir);

our $VERSION = '0.01';

my ($HAS_MOJO_UTIL, $HAS_MIME_B64);
BEGIN {
    $HAS_MOJO_UTIL = eval { require Mojo::Util; 1 } ? 1 : 0;
    if (!$HAS_MOJO_UTIL) {
        require MIME::Base64;
        $HAS_MIME_B64 = 1;
    }
}

my %VALID_FORMATS = map { $_ => 1 } qw(markdown table_json chart_csv ocr_code);

my %FORMAT_PROMPTS = (
    markdown   => 'Convert this document or screenshot into clean, accurate Markdown preserving headings, lists, tables, and code blocks.',
    table_json => 'Extract all tables in this image into a strict JSON object with keys "columns" and "rows".',
    chart_csv  => 'Extract chart axes, series labels, and data points into clean CSV format.',
    ocr_code   => 'Transcribe all visible source code, terminal output, and error traces verbatim inside a fenced code block.',
);

sub _b64_encode {
    my ($bytes) = @_;
    return $HAS_MOJO_UTIL
        ? Mojo::Util::b64_encode($bytes, '')
        : MIME::Base64::encode_base64($bytes, '');
}

sub new {
    my ($class, %args) = @_;
    croak "NeoPerl::Inference::Vision->new requires 'inference'" unless $args{inference};

    return bless {
        inference        => $args{inference},
        store            => $args{store},
        chunk_size       => $args{chunk_size}    || 700,
        chunk_overlap    => $args{chunk_overlap} || 80,
        clipboard_reader => $args{clipboard_reader},
        pdf_rasterizer   => $args{pdf_rasterizer},
        recent_docs      => [],
        stats            => {
            cache_hits   => 0,
            cache_misses => 0,
            pages_parsed => 0,
            chunks_saved => 0,
        },
    }, $class;
}

sub stats       { +{ %{ $_[0]{stats} } } }
sub recent_docs { [ @{ $_[0]{recent_docs} } ] }

sub detect_mime {
    my ($bytes, $filename) = @_;
    $bytes //= '';
    return 'image/png'       if substr($bytes, 0, 8) eq "\x89PNG\r\n\x1a\n";
    return 'image/jpeg'      if substr($bytes, 0, 3) eq "\xff\xd8\xff";
    return 'image/webp'      if length($bytes) >= 12 && substr($bytes, 0, 4) eq 'RIFF' && substr($bytes, 8, 4) eq 'WEBP';
    return 'application/pdf' if substr($bytes, 0, 5) eq '%PDF-';

    if (defined $filename) {
        return 'image/png'       if $filename =~ /\.png$/i;
        return 'image/jpeg'      if $filename =~ /\.jpe?g$/i;
        return 'image/webp'      if $filename =~ /\.webp$/i;
        return 'application/pdf' if $filename =~ /\.pdf$/i;
    }
    return 'application/octet-stream';
}

sub inspect_image_dimensions {
    my ($bytes, $mime) = @_;
    $bytes //= '';
    if ($mime eq 'image/png' && length($bytes) >= 24 && substr($bytes, 0, 8) eq "\x89PNG\r\n\x1a\n") {
        my ($w, $h) = unpack('N N', substr($bytes, 16, 8));
        return ($w, $h);
    }
    if ($mime eq 'image/jpeg' && length($bytes) >= 4) {
        my $pos = 2;
        my $len = length($bytes);
        while ($pos + 4 < $len) {
            last if ord(substr($bytes, $pos, 1)) != 0xFF;
            my $marker = ord(substr($bytes, $pos + 1, 1));
            $pos += 2;
            last if $marker == 0xD9 || $marker == 0xDA;
            my $seg_len = unpack('n', substr($bytes, $pos, 2));
            if ($marker == 0xC0 || $marker == 0xC2) {
                my ($h, $w) = unpack('n n', substr($bytes, $pos + 3, 4));
                return ($w, $h);
            }
            $pos += $seg_len;
        }
    }
    return (0, 0);
}

sub _count_pdf_pages {
    my ($bytes) = @_;
    return 1 unless defined $bytes && length $bytes;
    my @matches = ($bytes =~ m{/Type\s*/Page\b(?!s)}g);
    return @matches ? scalar(@matches) : 1;
}

sub _which {
    my ($bin) = @_;
    my $sep = ($^O eq 'MSWin32') ? ';' : ':';
    for my $dir (split /\Q$sep\E/, ($ENV{PATH} // '')) {
        next unless length $dir;
        my $p = File::Spec->catfile($dir, $bin);
        return $p if -x $p && !-d $p;
    }
    return undef;
}

sub _rasterize_pdf {
    my ($self, $pdf_path, $bytes, $max_pages) = @_;
    $max_pages ||= 20;

    if (ref($self->{pdf_rasterizer}) eq 'CODE') {
        return $self->{pdf_rasterizer}->($pdf_path, $bytes, $max_pages);
    }

    my @frames;
    my $pdftoppm = _which('pdftoppm');
    my $mutool   = _which('mutool');

    if (defined $pdf_path && -f $pdf_path && ($pdftoppm || $mutool)) {
        my $tmpdir = tempdir(CLEANUP => 1);
        my $prefix = File::Spec->catfile($tmpdir, 'page');
        my $ok = 0;
        if ($pdftoppm) {
            my $pid = fork();
            if (defined $pid && $pid == 0) {
                open STDOUT, '>', File::Spec->devnull();
                open STDERR, '>', File::Spec->devnull();
                { no warnings 'exec'; exec { $pdftoppm } ($pdftoppm, '-png', '-r', '150', '-f', '1', '-l', "$max_pages", $pdf_path, $prefix); }
                exit 127;
            }
            elsif ($pid) {
                waitpid($pid, 0);
                $ok = ($? == 0);
            }
        }
        elsif ($mutool) {
            my $pid = fork();
            if (defined $pid && $pid == 0) {
                open STDOUT, '>', File::Spec->devnull();
                open STDERR, '>', File::Spec->devnull();
                { no warnings 'exec'; exec { $mutool } ($mutool, 'draw', '-F', 'png', '-r', '150', '-o', "${prefix}-%d.png", $pdf_path, "1-$max_pages"); }
                exit 127;
            }
            elsif ($pid) {
                waitpid($pid, 0);
                $ok = ($? == 0);
            }
        }

        if ($ok) {
            opendir(my $dh, $tmpdir);
            my @pngs = sort grep { /\.png$/i } readdir($dh);
            closedir $dh;
            my $pno = 1;
            for my $f (@pngs) {
                my $full = File::Spec->catfile($tmpdir, $f);
                if (open my $fh, '<:raw', $full) {
                    local $/;
                    my $raw = <$fh>;
                    close $fh;
                    push @frames, { page_no => $pno++, mime_type => 'image/png', bytes => $raw };
                }
            }
        }
    }

    if (!@frames) {
        my $pages = _count_pdf_pages($bytes);
        $pages = $max_pages if $pages > $max_pages;
        # Extract printable PDF literal strings as lightweight text hint when no rasterizer is present
        my @hints = ($bytes =~ /\(([\x20-\x7e]{4,120})\)/g);
        my $hint = join(' ', @hints[ 0 .. ($#hints > 12 ? 12 : $#hints) ]);
        for my $p (1 .. $pages) {
            push @frames, {
                page_no   => $p,
                mime_type => 'application/pdf',
                bytes     => $bytes,
                text_hint => $hint,
            };
        }
    }

    return \@frames;
}

sub _chunk_text {
    my ($self, $text, $page_count) = @_;
    return [] unless defined $text && length $text;
    my $size    = $self->{chunk_size};
    my $overlap = $self->{chunk_overlap};
    $overlap = int($size / 4) if $overlap >= $size;

    my @chunks;
    my $len = length($text);
    if ($len <= $size) {
        push @chunks, { page_no => 1, content => $text };
        return \@chunks;
    }

    my $pos = 0;
    my $idx = 0;
    while ($pos < $len) {
        my $slice = substr($text, $pos, $size);
        my $page_no = 1;
        if ($slice =~ /##\s+Page\s+(\d+)/i) {
            $page_no = int($1);
        }
        elsif ($page_count && $page_count > 1) {
            $page_no = 1 + int(($pos / $len) * $page_count);
            $page_no = $page_count if $page_no > $page_count;
        }
        push @chunks, { chunk_index => $idx++, page_no => $page_no, content => $slice };
        last if $pos + $size >= $len;
        $pos += ($size - $overlap);
    }
    return \@chunks;
}

sub preprocess_file {
    my ($self, %args) = @_;
    my $path = $args{path} or croak "preprocess_file requires 'path'";
    croak "File not found: $path" unless -f $path;

    open my $fh, '<:raw', $path or croak "Cannot read $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;

    return $self->preprocess_bytes(
        bytes       => $bytes,
        source_path => $path,
        filename    => basename($path),
        format      => $args{format},
        force       => $args{force},
        max_pages   => $args{max_pages},
        text_hint   => $args{text_hint},
    );
}

sub preprocess_clipboard {
    my ($self, %args) = @_;
    my $bytes;

    if (ref($self->{clipboard_reader}) eq 'CODE') {
        $bytes = $self->{clipboard_reader}->();
    }
    else {
        $bytes = $self->_read_os_clipboard_image();
    }

    croak "No image data found on clipboard" unless defined $bytes && length $bytes;

    return $self->preprocess_bytes(
        bytes       => $bytes,
        source_path => '<clipboard>',
        filename    => 'clipboard.png',
        format      => $args{format} // 'markdown',
        force       => $args{force},
    );
}

sub _read_os_clipboard_image {
    my ($self) = @_;
    my $tmpdir = tempdir(CLEANUP => 1);
    my $out    = File::Spec->catfile($tmpdir, 'clip.png');

    if ($^O eq 'darwin') {
        if (my $pp = _which('pngpaste')) {
            system($pp, $out);
        }
        elsif (my $osa = _which('osascript')) {
            my $script = qq{try\nset img to the clipboard as «class PNGf»\nset f to open for access POSIX file "$out" with write permission\nwrite img to f\nclose access f\nend try};
            system($osa, '-e', $script);
        }
    }
    elsif ($^O eq 'linux') {
        if (my $wl = _which('wl-paste')) {
            system("$wl --type image/png > '$out' 2>/dev/null");
        }
        elsif (my $xc = _which('xclip')) {
            system("$xc -selection clipboard -t image/png -o > '$out' 2>/dev/null");
        }
    }

    if (-f $out && -s $out) {
        open my $fh, '<:raw', $out or return undef;
        local $/;
        my $raw = <$fh>;
        close $fh;
        return $raw;
    }
    return undef;
}

sub _clean_vision_output {
    my ($raw, $format) = @_;
    return '' unless defined $raw;

    my $s = $raw;
    # Strip stray <think>...</think>, prompt-prefixed ...</think>, and unclosed <think>
    $s =~ s{<think\b[^>]*>.*?</think>}{}gis;
    $s =~ s{\A.*?</think>}{}is;
    $s =~ s{<think\b[^>]*>.*\z}{}is;
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;

    $format //= 'markdown';
    if ($format eq 'table_json') {
        if ($s =~ /```(?:json)?[ \t]*\r?\n?(.*?)\r?\n?[ \t]*```/is) {
            $s = $1;
        }
        else {
            $s =~ s/\A\s*```(?:json)?\s*//i;
            $s =~ s/\s*```\s*\z//;
        }
        $s =~ s/\A\s+//;
        $s =~ s/\s+\z//;
    }
    elsif ($format eq 'chart_csv') {
        if ($s =~ /```(?:csv|text)?[ \t]*\r?\n?(.*?)\r?\n?[ \t]*```/is) {
            $s = $1;
        }
        else {
            $s =~ s/\A\s*```(?:csv|text)?\s*//i;
            $s =~ s/\s*```\s*\z//;
        }
        $s =~ s/\A\s+//;
        $s =~ s/\s+\z//;
        $s .= "\n" if length $s;
    }

    return $s;
}

sub preprocess_bytes {
    my ($self, %args) = @_;
    my $bytes = $args{bytes};
    croak "preprocess_bytes requires non-empty bytes"
        unless defined $bytes && length $bytes;

    my $format = $args{format} // 'markdown';
    croak "Unsupported vision output format: $format" unless $VALID_FORMATS{$format};

    my $source_path = $args{source_path} // $args{filename} // 'inline.png';
    my $filename    = $args{filename}    // basename($source_path);
    my $mime        = $args{mime_type}   // detect_mime($bytes, $filename);
    my $sha         = sha256_hex($bytes);

    # 1. Check SHA-256 cache in Store BEFORE running Granite-Vision inference
    if ($self->{store} && !$args{force}) {
        my $cached = $self->{store}->get_doc_cache($sha, $format);
        if ($cached) {
            $self->{stats}{cache_hits}++;
            return {
                cached             => 1,
                doc_id             => $cached->{id},
                sha256             => $sha,
                source_path        => $cached->{source_path} || $source_path,
                mime_type          => $cached->{mime_type}   || $mime,
                format             => $format,
                page_count         => int($cached->{page_count} || 1),
                content            => $cached->{extracted_text},
                chunks             => $cached->{chunks} || [],
                token_estimate     => int($cached->{token_estimate} || 0),
                cloud_tokens_saved => 0,
            };
        }
    }

    $self->{stats}{cache_misses}++;

    # 2. Prepare frames (single image or multi-page PDF rasterization)
    my @frames;
    my ($w, $h) = (0, 0);
    my $text_hint = $args{text_hint} // '';

    if ($mime eq 'application/pdf') {
        my $pdf_frames = $self->_rasterize_pdf($args{source_path}, $bytes, $args{max_pages} || 20);
        @frames = @$pdf_frames;
        if (!length($text_hint) && @frames && defined $frames[0]{text_hint}) {
            $text_hint = $frames[0]{text_hint};
        }
    }
    else {
        ($w, $h) = inspect_image_dimensions($bytes, $mime);
        @frames = ({ page_no => 1, mime_type => $mime, bytes => $bytes });
    }

    my $page_count = scalar(@frames) || 1;
    $self->{stats}{pages_parsed} += $page_count;

    # 3. Build multimodal OpenAI-compatible payload with base64 image frames before text prompt
    my $prompt = $FORMAT_PROMPTS{$format};
    my @content_parts;
    for my $f (@frames) {
        my $b64 = _b64_encode($f->{bytes});
        my $fmime = ($f->{mime_type} =~ /^image\//) ? $f->{mime_type} : 'image/png';
        push @content_parts, {
            type      => 'image_url',
            image_url => { url => "data:$fmime;base64,$b64" },
        };
    }
    push @content_parts, { type => 'text', text => $prompt };

    my $res = $self->{inference}->complete(
        role        => 'vision_doc',
        temperature => 0.0,
        messages    => [
            { role => 'user', content => \@content_parts },
        ],
        metadata    => {
            format     => $format,
            filename   => $filename,
            mime_type  => $mime,
            page_count => $page_count,
            width      => $w,
            height     => $h,
            text_hint  => $text_hint,
        },
    );

    my $extracted = _clean_vision_output($res->{text} // '', $format);
    my $tok_est   = int((length($extracted) + 3) / 4);
    # Cloud vision tokenization for raw high-res images/PDFs averages ~1600 tokens/page
    my $saved     = ($page_count * 1600) - $tok_est;
    $saved = 400 if $saved < 400;
    $self->{inference}->record_cloud_tokens_saved($saved);

    # 4. Chunk & embed extracted text into NPL_DOC_CACHE + NPL_DOC_CHUNKS
    my $chunks = $self->_chunk_text($extracted, $page_count);
    for my $ch (@$chunks) {
        $ch->{embedding} = $self->{inference}->embed($ch->{content});
    }

    my $doc_id;
    if ($self->{store}) {
        $doc_id = $self->{store}->put_doc_cache(
            {
                content_sha256 => $sha,
                source_path    => $source_path,
                mime_type      => $mime,
                output_format  => $format,
                page_count     => $page_count,
                extracted_text => $extracted,
                model_id       => $res->{model_id} // 'ibm-granite/granite-vision-4.1-4b-GGUF',
                token_estimate => $tok_est,
            },
            $chunks,
        );
        $self->{stats}{chunks_saved} += scalar(@$chunks);
    }

    my $result = {
        cached             => 0,
        doc_id             => $doc_id,
        sha256             => $sha,
        source_path        => $source_path,
        mime_type          => $mime,
        format             => $format,
        page_count         => $page_count,
        width              => $w,
        height             => $h,
        content            => $extracted,
        chunks             => [ map { +{ chunk_index => $_->{chunk_index} // 0, page_no => $_->{page_no}, content => $_->{content} } } @$chunks ],
        token_estimate     => $tok_est,
        cloud_tokens_saved => $saved,
        b64_engine         => $HAS_MOJO_UTIL ? 'Mojo::Util' : 'MIME::Base64',
        (defined $res->{tok_per_s}  ? (tok_per_s  => $res->{tok_per_s})  : ()),
        (defined $res->{elapsed_ms} ? (elapsed_ms => $res->{elapsed_ms}) : ()),
    };

    unshift @{ $self->{recent_docs} }, {
        doc_id      => $doc_id,
        source_path => $source_path,
        format      => $format,
        page_count  => $page_count,
        sha256      => substr($sha, 0, 12),
        tokens      => $tok_est,
    };
    pop @{ $self->{recent_docs} } if @{ $self->{recent_docs} } > 20;

    return $result;
}

1;

__END__

=head1 NAME

NeoPerl::Inference::Vision - Local Granite-Vision-4.1-4B document and image preprocessor

=head1 SYNOPSIS

    use NeoPerl::Inference::Vision;

    my $vision = NeoPerl::Inference::Vision->new(
        inference => $mgr,
        store     => $store,
    );
    my $doc = $vision->preprocess_file(
        path   => 'diagram.png',
        format => 'markdown',
    );

=head1 DESCRIPTION

C<NeoPerl::Inference::Vision> preprocesses PNG/JPEG/WebP images, OS clipboard
screenshots, and multi-page PDFs locally via the C<vision_doc> role
(C<ibm-granite/granite-vision-4.1-4b-GGUF> with C<--mmproj>). Results are
keyed by SHA-256 in C<NPL_DOC_CACHE> and chunk-embedded into C<NPL_DOC_CHUNKS>
for subsequent semantic retrieval.

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (Artistic License 2.0 or GNU GPL).

=cut
