/*
 * c/mt_compat.h - perl5-mt Tier-1 XS compatibility layer
 *
 * Pure C11 (no C++). Emits _mt_threadsafe_boot_NeoPerl__Core under perl5-mt
 * and compiles cleanly under stock Perl 5 as well.
 */
#ifndef NPL_MT_COMPAT_H
#define NPL_MT_COMPAT_H

#ifdef __cplusplus
#  error "NeoPerl::Core XS modules must be compiled as pure C11, not C++"
#endif

#ifndef PERL_NO_GET_CONTEXT
#  define PERL_NO_GET_CONTEXT
#endif

#ifndef PERL_XS_THREADSAFE
#  define PERL_XS_THREADSAFE 1
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/* Detect perl5-mt thread-safe XS marker support */
#ifdef PERL_MT_XS_MARKER
#  define NPL_IS_PERL5_MT 1
#else
#  define NPL_IS_PERL5_MT 0
#endif

/* Detect perl5-mt packed AV support */
#if defined(SVf_PACKED_AV) && defined(AvPACKED_TYPE) && defined(AvPACKED_DATA)
#  define NPL_HAVE_PACKED_AV 1
#else
#  define NPL_HAVE_PACKED_AV 0
#endif

static inline int
npl_force_scalar_env(void)
{
    const char *v = getenv("PERL_FORCE_SCALAR");
    return (v && v[0] == '1' && v[1] == '\0') ? 1 : 0;
}

#endif /* NPL_MT_COMPAT_H */
