use strict;
use warnings;
use Config;
use ExtUtils::MakeMaker;

my $is_darwin = ($^O eq 'darwin');
my $is_linux  = ($^O eq 'linux');
my $is_win32  = ($^O eq 'MSWin32');

my $CFG_CC    = $Config{cc} || 'cc';
my $is_msvc   = ($is_win32 && $CFG_CC =~ /(?:^|[\\\/])cl(?:\.exe)?$/i) ? 1 : 0;

my $DLEXT          = $Config{dlext}      || ($is_win32 ? 'dll' : 'so');
my $OBJ            = $Config{obj_ext}    || ($is_msvc ? '.obj' : '.o');
my $CFG_LD         = $Config{ld}         || $CFG_CC;
my $CFG_CCFLAGS    = $Config{ccflags}    // '';
my $CFG_OPTIMIZE   = $Config{optimize}   // ($is_msvc ? '/O2' : '-O3');
my $CFG_CCCDLFLAGS = $Config{cccdlflags} // ($is_linux ? '-fPIC' : '');
my $CFG_LDDLFLAGS  = $Config{lddlflags}  // ($is_darwin ? '-bundle -undefined dynamic_lookup'
                                           : ($is_msvc   ? '/DLL' : '-shared'));

# Detect architecture (including IBM POWER8+ ppc64le)
my $archname = $Config{archname} // '';
my $machine  = '';
if (!$is_win32) {
    my $u = `uname -m 2>/dev/null`;
    chomp($u) if defined $u;
    $machine = $u // '';
}
my $is_ppc64le = ($archname =~ /powerpc64le|ppc64le/i || $machine =~ /^ppc64le$/i) ? 1 : 0;

my $ARCH_FLAGS = '';
if ($is_ppc64le && !$is_msvc) {
    my $pcpu = $ENV{NEOPERL_POWER_CPU} // 'power8';
    $pcpu = 'power8' unless $pcpu =~ /^(?:power8|power9|power10|native)$/;
    $ARCH_FLAGS = "-mcpu=$pcpu -mvsx";
    if ($pcpu eq 'power10') {
        $ARCH_FLAGS .= ' -mmma';
    }
}

# Detect perl5-mt (Tier-1 PERL_XS_THREADSAFE support)
my $perl_src_arg = '';
for my $arg (@ARGV) {
    if ($arg =~ /^PERL_SRC=(.+)$/) {
        $perl_src_arg = $1;
    }
}
my $is_perl5_mt = 0;
my @xsub_candidates;
push @xsub_candidates, "$perl_src_arg/XSUB.h" if length $perl_src_arg;
push @xsub_candidates, "$Config{archlibexp}/CORE/XSUB.h" if defined $Config{archlibexp};
for my $xh (@xsub_candidates) {
    if (-f $xh && open(my $fh, '<', $xh)) {
        local $/;
        my $txt = <$fh>;
        close $fh;
        if (defined $txt && $txt =~ /PERL_MT_XS_MARKER/) {
            $is_perl5_mt = 1;
            last;
        }
    }
}
my $MT_DEFINE = $is_perl5_mt ? '-DPERL_XS_THREADSAFE=1' : '';

# Locate xsubpp & default typemap from active @INC (supports uninstalled perl5-mt)
my ($XSUBPP_BIN, $TYPEMAP_FILE);
for my $dir (@INC) {
    next if ref $dir;
    if (!$XSUBPP_BIN && -f "$dir/ExtUtils/xsubpp") {
        $XSUBPP_BIN = "$dir/ExtUtils/xsubpp";
    }
    if (!$TYPEMAP_FILE && -f "$dir/ExtUtils/typemap") {
        $TYPEMAP_FILE = "$dir/ExtUtils/typemap";
    }
}
die "Could not locate ExtUtils/xsubpp in \@INC\n" unless $XSUBPP_BIN;
my $TYPEMAP_ARG = $TYPEMAP_FILE ? "-typemap \"$TYPEMAP_FILE\"" : '';

my @sys_libs;
if ($is_darwin) {
    push @sys_libs, '-lpthread', '-lm';
} elsif ($is_linux) {
    push @sys_libs, '-lpthread', '-lm', '-ldl', '-lutil';
} elsif ($is_win32) {
    push @sys_libs, ($is_msvc ? () : ('-lm'));
} else {
    push @sys_libs, '-lpthread', '-lm', '-lutil';
}

my $WIN32_PERL_LIB = $is_win32 ? '$(PERL_ARCHIVE)' : '';
my $CORE_LIBS = join(' ', grep { length } ($WIN32_PERL_LIB, @sys_libs));

my $CORE_BUNDLE = "blib/arch/auto/NeoPerl/Core/Core.$DLEXT";

my @CORE_OBJS = (
    "c/buffer$OBJ",
    "c/diff$OBJ",
    "c/syntax$OBJ",
    "c/treesitter_bridge$OBJ",
    "c/fuzzy$OBJ",
    "c/pty_term$OBJ",
    "c/vec_simd$OBJ",
    "c/llama_bridge$OBJ",
    "c/msgpack$OBJ",
    "c/vim_engine$OBJ",
);

my @exe_files = grep { -f $_ } ('bin/npl', 'bin/npl-mcp', 'bin/npl-lsp');

WriteMakefile(
    NAME             => 'NeoPerl::MT',
    VERSION_FROM     => 'lib/NeoPerl/Core.pm',
    ABSTRACT         => 'Multi-threaded modal code editor with C11 XS core',
    AUTHOR           => 'stratum42',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.016',
    EXE_FILES        => \@exe_files,
    XS               => {},
    C                => [],
    OBJECT           => '',
    clean            => {
        FILES => join(' ',
            'Core.c', "Core$OBJ",
            @CORE_OBJS,
            $CORE_BUNDLE,
        ),
    },
);

package MY;

sub init_PERL {
    my $self = shift;
    $self->SUPER::init_PERL(@_);
    if ($self->{PERL_SRC} && -d "$self->{PERL_SRC}/lib") {
        $self->{PERL_LIB}     = "$self->{PERL_SRC}/lib";
        $self->{PERL_ARCHLIB} = "$self->{PERL_SRC}/lib";
        for my $k (qw(PERLRUN FULLPERLRUN ABSPERLRUN)) {
            if (defined $self->{$k} && $self->{$k} !~ /-I\$\(PERL_LIB\)/) {
                $self->{$k} .= ' "-I$(PERL_LIB)"';
            }
        }
    }
}

sub dynamic {
    my $self = shift;
    my $base = $self->SUPER::dynamic(@_);
    return $base . "\n"
         . "dynamic :: $CORE_BUNDLE\n"
         . "\t\$(NOECHO) \$(NOOP)\n";
}

sub postamble {
    my $self = shift;
    my $werror = $ENV{NEOPERL_NO_WERROR} ? '' : '-Werror';
    my $c11_std = $is_msvc
        ? '/std:c11 /experimental:c11atomics /D_CRT_SECURE_NO_WARNINGS /W3'
        : "-std=c11 -O3 -Wall -Wextra $werror $ARCH_FLAGS";
    my $c11_xs = $is_msvc
        ? '/std:c11 /experimental:c11atomics /D_CRT_SECURE_NO_WARNINGS'
        : "-std=c11 -O3 -Wall -Wextra -Wno-unused-parameter $ARCH_FLAGS $MT_DEFINE";
    my $cc_c_flag = $is_msvc ? '/c' : '-c';
    my $obj_out   = $is_msvc ? '/Fo$@' : '-o $@';
    my $ld_out    = $is_msvc ? '/OUT:$@' : '-o $@';

    my $core_objs_str = join(' ', @CORE_OBJS);

    return <<"EOF";

NPL_INC      = -I. -Ic
NPL_CC       = $CFG_CC
NPL_LD       = $CFG_LD
NPL_CCFLAGS    = $CFG_CCFLAGS
NPL_OPTIMIZE   = $CFG_OPTIMIZE
NPL_CCCDLFLAGS = $CFG_CCCDLFLAGS
NPL_LDDLFLAGS  = $CFG_LDDLFLAGS
NPL_XSUBPP     = \$(ABSPERLRUN) "$XSUBPP_BIN" $TYPEMAP_ARG
NPL_CC_C11     = \$(NPL_CC) $cc_c_flag \$(NPL_INC) \$(NPL_CCCDLFLAGS) $c11_std
NPL_CC_XS      = \$(NPL_CC) $cc_c_flag \$(NPL_INC) "-I\$(PERL_INC)" \$(NPL_CCFLAGS) \$(NPL_OPTIMIZE) \$(NPL_CCCDLFLAGS) $c11_xs -DVERSION=\\"\$(VERSION)\\" -DXS_VERSION=\\"\$(XS_VERSION)\\"

Core.c : Core.xs c/mt_compat.h c/power_arch.h c/buffer.h c/diff.h c/syntax.h c/treesitter_bridge.h c/fuzzy.h c/pty_term.h c/vec_simd.h c/llama_bridge.h c/msgpack.h c/vim_engine.h
\t\$(NPL_XSUBPP) Core.xs > Core.xsc && \$(MV) Core.xsc Core.c

Core$OBJ : Core.c
\t\$(NPL_CC_XS) $obj_out Core.c

c/buffer$OBJ : c/buffer.c c/buffer.h c/power_arch.h
\t\$(NPL_CC_C11) $obj_out c/buffer.c

c/diff$OBJ : c/diff.c c/diff.h
\t\$(NPL_CC_C11) $obj_out c/diff.c

c/syntax$OBJ : c/syntax.c c/syntax.h c/buffer.h
\t\$(NPL_CC_C11) $obj_out c/syntax.c

c/treesitter_bridge$OBJ : c/treesitter_bridge.c c/treesitter_bridge.h c/tkmt_thread.h
\t\$(NPL_CC_C11) $obj_out c/treesitter_bridge.c

c/fuzzy$OBJ : c/fuzzy.c c/fuzzy.h c/buffer.h c/power_arch.h c/tkmt_thread.h
\t\$(NPL_CC_C11) $obj_out c/fuzzy.c

c/pty_term$OBJ : c/pty_term.c c/pty_term.h
\t\$(NPL_CC_C11) $obj_out c/pty_term.c

c/vec_simd$OBJ : c/vec_simd.c c/vec_simd.h c/power_arch.h
\t\$(NPL_CC_C11) $obj_out c/vec_simd.c

c/llama_bridge$OBJ : c/llama_bridge.c c/llama_bridge.h c/tkmt_thread.h c/vec_simd.h
\t\$(NPL_CC_C11) $obj_out c/llama_bridge.c

c/msgpack$OBJ : c/msgpack.c c/msgpack.h
\t\$(NPL_CC_C11) $obj_out c/msgpack.c

c/vim_engine$OBJ : c/vim_engine.c c/vim_engine.h c/buffer.h
\t\$(NPL_CC_C11) $obj_out c/vim_engine.c

$CORE_BUNDLE : Core$OBJ $core_objs_str
\t\$(MKPATH) blib/arch/auto/NeoPerl/Core
\t\$(NPL_LD) \$(NPL_LDDLFLAGS) Core$OBJ $core_objs_str $ld_out $CORE_LIBS
\t\$(CHMOD) 755 \$\@
EOF
}
