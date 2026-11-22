package NeoPerl::Core;

use strict;
use warnings;
use XSLoader;
use Exporter 'import';

our $VERSION = '0.01';

use constant {
    TOK_NORMAL   => 0,
    TOK_KEYWORD  => 1,
    TOK_STRING   => 2,
    TOK_COMMENT  => 3,
    TOK_NUMBER   => 4,
    TOK_VAR      => 5,
    TOK_FUNC     => 6,
    TOK_TYPE     => 7,
    TOK_OPERATOR => 8,
    TOK_PREPROC  => 9,
    TOK_CONSTANT => 10,
    TOK_TAG      => 11,

    TERM_FLAG_BOLD      => 0x01,
    TERM_FLAG_DIM       => 0x02,
    TERM_FLAG_ITALIC    => 0x04,
    TERM_FLAG_UNDERLINE => 0x08,
    TERM_FLAG_INVERSE   => 0x10,
};

our @EXPORT_OK = qw(
    TOK_NORMAL TOK_KEYWORD TOK_STRING TOK_COMMENT TOK_NUMBER
    TOK_VAR TOK_FUNC TOK_TYPE TOK_OPERATOR TOK_PREPROC
    TOK_CONSTANT TOK_TAG
    TERM_FLAG_BOLD TERM_FLAG_DIM TERM_FLAG_ITALIC
    TERM_FLAG_UNDERLINE TERM_FLAG_INVERSE
    is_perl5_mt have_packed_av force_scalar timebase_ticks
    arch_info detect_language token_name
);

our %EXPORT_TAGS = (
    tokens => [qw(
        TOK_NORMAL TOK_KEYWORD TOK_STRING TOK_COMMENT TOK_NUMBER
        TOK_VAR TOK_FUNC TOK_TYPE TOK_OPERATOR TOK_PREPROC
        TOK_CONSTANT TOK_TAG
    )],
    term => [qw(
        TERM_FLAG_BOLD TERM_FLAG_DIM TERM_FLAG_ITALIC
        TERM_FLAG_UNDERLINE TERM_FLAG_INVERSE
    )],
    all => \@EXPORT_OK,
);

XSLoader::load('NeoPerl::Core', $VERSION);

{
    package NeoPerl::Core::Msgpack::Bool;
    use overload
        'bool'   => sub { ${$_[0]} ? 1 : 0 },
        '0+'     => sub { ${$_[0]} ? 1 : 0 },
        '""'     => sub { ${$_[0]} ? '1' : '0' },
        fallback => 1;
}

{
    package NeoPerl::Core::Msgpack;
    my $TRUE  = bless \(my $t = 1), 'NeoPerl::Core::Msgpack::Bool';
    my $FALSE = bless \(my $f = 0), 'NeoPerl::Core::Msgpack::Bool';
    sub true  { return $TRUE }
    sub false { return $FALSE }
}

1;

__END__

=head1 NAME

NeoPerl::Core - Pure-C11 Tier-1 XS core engine for NeoPerl::MT

=head1 SYNOPSIS

    use NeoPerl::Core qw(:tokens arch_info detect_language);

    my $info = arch_info();
    my $buf  = NeoPerl::Core::Buffer->open_file('script.pl');
    my $syn  = NeoPerl::Core::Syntax->new(detect_language('script.pl'));

    my $lines  = $buf->get_lines(0, 40);
    my $tokens = $syn->tokenize_range($buf, 0, 40);
    my $hunks  = NeoPerl::Core::Diff::myers_text("a\nb\n", "a\nc\n");
    my $files  = NeoPerl::Core::Fuzzy::walk_files('.', 5000);
    my $blob   = NeoPerl::Core::VecSIMD::pack_f32([1.0, 0.0, 0.5, 0.5]);

=head1 DESCRIPTION

C<NeoPerl::Core> implements the pure-C11, thread-safe XS foundation of
L<NeoPerl::MT>. When compiled against C<perl5-mt>, it exports the Tier-1
C<_mt_threadsafe_boot_NeoPerl__Core> marker so worker interpreters invoke its
XSUBs directly in process; it also builds cleanly against stock Perl 5.

Subsystems provided:

=over 4

=item * B<NeoPerl::Core::Buffer>: zero-copy C<mmap> piece-table with
SIMD-accelerated newline indexing, branching undo tree (C<undo>/C<redo>/
C<undo_older>/C<undo_newer>/C<undo_goto>/C<undo_list>), and byte-anchored
extmarks with automatic edit/undo gravity tracking.

=item * B<NeoPerl::Core::Diff>: Myers C<O(ND)> line diff returning structured
C<add>/C<del>/C<change> hunks.

=item * B<NeoPerl::Core::Syntax> and B<NeoPerl::Core::TreeSitter>: 27-language
incremental line-state lexer, symbol outline extractor, and zero-link-dep
runtime C<dlopen(libtree-sitter)> bridge.

=item * B<NeoPerl::Core::Fuzzy>: multi-threaded parallel file walker
respecting C<.gitignore>, Smith-Waterman fuzzy scorer returning matched
character positions, and SIMD-accelerated parallel project/buffer grep with
deterministic C<PERL_FORCE_SCALAR=1> parity.

=item * B<NeoPerl::Core::Term>: POSIX PTY subprocess driver with a C11
VT100/256-color/24-bit RGB terminal screen buffer and scrollback ring.

=item * B<NeoPerl::Core::VecSIMD>: ARM64 NEON, x86_64 SSE2/AVX2, and IBM
POWER8+ VSX float32 vector kernels (dot product, L2 norm, cosine similarity,
normalization, little-endian BLOB pack/unpack, and batch top-K scan) with
bit-identical C<PERL_FORCE_SCALAR=1> scalar parity.

=item * B<NeoPerl::Core::LlamaBridge>: zero-link-dep runtime
C<dlopen(libllama)> bridge degrading gracefully when C<libllama> is absent.

=item * B<NeoPerl::Core::Msgpack>: zero-dependency pure-C11 MessagePack
encoder and incremental streaming decoder (C<encode>, C<decode>,
C<decode_stream>) supporting all MessagePack scalar/container types, booleans,
and Neovim C<ext> types (Buffer, Window, Tabpage).

=item * B<NeoPerl::Core::VimEngine>: pure-C11 reentrant Vim modal engine
operating directly on C<NeoPerl::Core::Buffer>, implementing Vim 9.1 modes,
motions, text objects, operators, Visual/Visual-Line/Visual-Block edits,
registers, marks, macros, dot-repeat, and grouped branching undo.

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

Same as Perl itself (dual Artistic License / GNU GPL).

=cut
