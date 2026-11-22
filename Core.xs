/*
 * Core.xs - Pure C11 Tier-1 PERL_XS_THREADSAFE XS core engine for NeoPerl::Core
 */
#include "c/mt_compat.h"
#include "c/power_arch.h"
#include "c/buffer.h"
#include "c/diff.h"
#include "c/syntax.h"
#include "c/treesitter_bridge.h"
#include "c/fuzzy.h"
#include "c/pty_term.h"
#include "c/vec_simd.h"
#include "c/llama_bridge.h"
#include "c/msgpack.h"
#include "c/vim_engine.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static SV *
wrap_buf(pTHX_ npl_buf_t *b)
{
    SV *rv = newSV(0);
    sv_setref_pv(rv, "NeoPerl::Core::Buffer", (void *)b);
    return rv;
}

static npl_buf_t *
unwrap_buf(pTHX_ SV *sv)
{
    if (!sv || !SvROK(sv) || !sv_derived_from(sv, "NeoPerl::Core::Buffer")) {
        croak("Expected NeoPerl::Core::Buffer object");
    }
    IV ptr = SvIV((SV *)SvRV(sv));
    if (!ptr) {
        croak("NeoPerl::Core::Buffer object has been destroyed");
    }
    return INT2PTR(npl_buf_t *, ptr);
}

static SV *
wrap_syn(pTHX_ npl_syntax_t *syn)
{
    SV *rv = newSV(0);
    sv_setref_pv(rv, "NeoPerl::Core::Syntax", (void *)syn);
    return rv;
}

static npl_syntax_t *
unwrap_syn(pTHX_ SV *sv)
{
    if (!sv || !SvROK(sv) || !sv_derived_from(sv, "NeoPerl::Core::Syntax")) {
        croak("Expected NeoPerl::Core::Syntax object");
    }
    IV ptr = SvIV((SV *)SvRV(sv));
    if (!ptr) {
        croak("NeoPerl::Core::Syntax object has been destroyed");
    }
    return INT2PTR(npl_syntax_t *, ptr);
}

static SV *
wrap_term(pTHX_ npl_term_t *t)
{
    SV *rv = newSV(0);
    sv_setref_pv(rv, "NeoPerl::Core::Term", (void *)t);
    return rv;
}

static npl_term_t *
unwrap_term(pTHX_ SV *sv)
{
    if (!sv || !SvROK(sv) || !sv_derived_from(sv, "NeoPerl::Core::Term")) {
        croak("Expected NeoPerl::Core::Term object");
    }
    IV ptr = SvIV((SV *)SvRV(sv));
    if (!ptr) {
        croak("NeoPerl::Core::Term object has been destroyed");
    }
    return INT2PTR(npl_term_t *, ptr);
}

static AV *
diff_result_to_av(pTHX_ const npl_diff_result_t *res)
{
    AV *av = newAV();
    if (res->count > 0) av_extend(av, (SSize_t)(res->count - 1));
    for (size_t i = 0; i < res->count; i++) {
        const npl_diff_hunk_t *h = &res->hunks[i];
        HV *hv = newHV();
        (void)hv_stores(hv, "old_start", newSVuv((UV)h->old_start));
        (void)hv_stores(hv, "old_count", newSVuv((UV)h->old_count));
        (void)hv_stores(hv, "new_start", newSVuv((UV)h->new_start));
        (void)hv_stores(hv, "new_count", newSVuv((UV)h->new_count));
        (void)hv_stores(hv, "kind",      newSVpv(npl_diff_kind_name(h->kind), 0));
        av_push(av, newRV_noinc((SV *)hv));
    }
    return av;
}

static AV *
symbols_to_av(pTHX_ const npl_symbol_list_t *list)
{
    AV *av = newAV();
    if (list->count > 0) av_extend(av, (SSize_t)(list->count - 1));
    for (size_t i = 0; i < list->count; i++) {
        const npl_symbol_t *s = &list->items[i];
        HV *hv = newHV();
        (void)hv_stores(hv, "name", newSVpv(s->name ? s->name : "", 0));
        (void)hv_stores(hv, "kind", newSVpv(s->kind ? s->kind : "", 0));
        (void)hv_stores(hv, "line", newSVuv((UV)s->line));
        (void)hv_stores(hv, "col",  newSVuv((UV)s->col));
        av_push(av, newRV_noinc((SV *)hv));
    }
    return av;
}

static AV *
ts_nodes_to_av(pTHX_ const npl_ts_node_list_t *list)
{
    AV *av = newAV();
    if (list->count > 0) av_extend(av, (SSize_t)(list->count - 1));
    for (size_t i = 0; i < list->count; i++) {
        const npl_ts_node_info_t *n = &list->items[i];
        HV *hv = newHV();
        (void)hv_stores(hv, "type",       newSVpv(n->type ? n->type : "", 0));
        (void)hv_stores(hv, "start_byte", newSVuv((UV)n->start_byte));
        (void)hv_stores(hv, "end_byte",   newSVuv((UV)n->end_byte));
        (void)hv_stores(hv, "start_row",  newSVuv((UV)n->start_row));
        (void)hv_stores(hv, "start_col",  newSVuv((UV)n->start_col));
        (void)hv_stores(hv, "end_row",    newSVuv((UV)n->end_row));
        (void)hv_stores(hv, "end_col",    newSVuv((UV)n->end_col));
        (void)hv_stores(hv, "named",      newSViv((IV)n->is_named));
        av_push(av, newRV_noinc((SV *)hv));
    }
    return av;
}

static AV *
grep_results_to_av(pTHX_ const npl_grep_results_t *res, int include_path)
{
    AV *av = newAV();
    if (res->count > 0) av_extend(av, (SSize_t)(res->count - 1));
    for (size_t i = 0; i < res->count; i++) {
        const npl_grep_hit_t *m = &res->items[i];
        HV *hv = newHV();
        if (include_path && m->path) {
            (void)hv_stores(hv, "path", newSVpv(m->path, 0));
        }
        (void)hv_stores(hv, "line",    newSVuv((UV)m->line));
        (void)hv_stores(hv, "col",     newSVuv((UV)m->col));
        (void)hv_stores(hv, "len",     newSVuv((UV)m->len));
        (void)hv_stores(hv, "preview", newSVpv(m->preview ? m->preview : "", 0));
        av_push(av, newRV_noinc((SV *)hv));
    }
    return av;
}

static void
append_utf8_cp(pTHX_ SV *sv, uint32_t cp)
{
    char buf[4];
    size_t n = 0;
    if (cp < 0x80u) {
        buf[0] = (char)(cp ? cp : ' ');
        n = 1;
    } else if (cp < 0x800u) {
        buf[0] = (char)(0xC0u | (cp >> 6));
        buf[1] = (char)(0x80u | (cp & 0x3Fu));
        n = 2;
    } else if (cp < 0x10000u) {
        buf[0] = (char)(0xE0u | (cp >> 12));
        buf[1] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
        buf[2] = (char)(0x80u | (cp & 0x3Fu));
        n = 3;
    } else {
        buf[0] = (char)(0xF0u | (cp >> 18));
        buf[1] = (char)(0x80u | ((cp >> 12) & 0x3Fu));
        buf[2] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
        buf[3] = (char)(0x80u | (cp & 0x3Fu));
        n = 4;
    }
    sv_catpvn(sv, buf, n);
}

static HV *
term_screen_to_hv(pTHX_ npl_term_t *t)
{
    HV *hv = newHV();
    int rows = npl_term_rows(t);
    int cols = npl_term_cols(t);
    int exited = 0;
    int code = npl_term_exit_code(t, &exited);

    (void)hv_stores(hv, "rows",           newSViv((IV)rows));
    (void)hv_stores(hv, "cols",           newSViv((IV)cols));
    (void)hv_stores(hv, "cursor_row",     newSViv((IV)npl_term_cursor_row(t)));
    (void)hv_stores(hv, "cursor_col",     newSViv((IV)npl_term_cursor_col(t)));
    (void)hv_stores(hv, "cursor_visible", newSViv((IV)npl_term_cursor_visible(t)));
    (void)hv_stores(hv, "alive",          newSViv((IV)npl_term_is_alive(t)));
    (void)hv_stores(hv, "exit_code",      exited ? newSViv((IV)code) : newSV(0));
    (void)hv_stores(hv, "title",          newSVpv(npl_term_title(t), 0));

    AV *lines_av = newAV();
    AV *runs_av  = newAV();
    if (rows > 0) {
        av_extend(lines_av, (SSize_t)(rows - 1));
        av_extend(runs_av, (SSize_t)(rows - 1));
    }
    for (int r = 0; r < rows; r++) {
        const npl_term_cell_t *rc = npl_term_row_cells(t, r);
        SV *line_sv = newSVpvs("");
        AV *row_runs = newAV();
        int last = cols;
        while (last > 0 && rc[last - 1].cp == ' ' && rc[last - 1].bg < 0 && rc[last - 1].flags == 0) {
            last--;
        }
        int c = 0;
        while (c < last) {
            int32_t fg = rc[c].fg;
            int32_t bg = rc[c].bg;
            uint8_t fl = rc[c].flags;
            SV *run_txt = newSVpvs("");
            while (c < last && rc[c].fg == fg && rc[c].bg == bg && rc[c].flags == fl) {
                append_utf8_cp(aTHX_ line_sv, rc[c].cp);
                append_utf8_cp(aTHX_ run_txt, rc[c].cp);
                c++;
            }
            HV *run_hv = newHV();
            (void)hv_stores(run_hv, "text",  run_txt);
            (void)hv_stores(run_hv, "fg",    newSViv((IV)fg));
            (void)hv_stores(run_hv, "bg",    newSViv((IV)bg));
            (void)hv_stores(run_hv, "flags", newSVuv((UV)fl));
            av_push(row_runs, newRV_noinc((SV *)run_hv));
        }
        av_push(lines_av, line_sv);
        av_push(runs_av, newRV_noinc((SV *)row_runs));
    }
    (void)hv_stores(hv, "lines", newRV_noinc((SV *)lines_av));
    (void)hv_stores(hv, "runs",  newRV_noinc((SV *)runs_av));

    size_t sb_n = npl_term_scrollback_count(t);
    AV *sb_av = newAV();
    if (sb_n > 0) av_extend(sb_av, (SSize_t)(sb_n - 1));
    for (size_t i = 0; i < sb_n; i++) {
        const char *sl = npl_term_scrollback_line(t, i);
        av_push(sb_av, newSVpv(sl ? sl : "", 0));
    }
    (void)hv_stores(hv, "scrollback", newRV_noinc((SV *)sb_av));
    return hv;
}

typedef struct npl_vim_xs {
    npl_vim_t *vim;
    SV        *buf_ref;
} npl_vim_xs_t;

static SV *
wrap_vim(pTHX_ npl_vim_xs_t *w)
{
    SV *rv = newSV(0);
    sv_setref_pv(rv, "NeoPerl::Core::VimEngine", (void *)w);
    return rv;
}

static npl_vim_xs_t *
unwrap_vim(pTHX_ SV *sv)
{
    if (!sv || !SvROK(sv) || !sv_derived_from(sv, "NeoPerl::Core::VimEngine")) {
        croak("Expected NeoPerl::Core::VimEngine object");
    }
    IV ptr = SvIV((SV *)SvRV(sv));
    if (!ptr) {
        croak("NeoPerl::Core::VimEngine object has been destroyed");
    }
    return INT2PTR(npl_vim_xs_t *, ptr);
}

static SV *
visual_range_to_sv(pTHX_ const npl_vim_visual_range_t *vr)
{
    if (!vr || !vr->active) return newSV(0);
    HV *hv = newHV();
    (void)hv_stores(hv, "mode",       newSVpv(npl_vim_mode_name(vr->mode), 0));
    (void)hv_stores(hv, "start_line", newSVuv((UV)vr->start_line));
    (void)hv_stores(hv, "start_col",  newSVuv((UV)vr->start_col));
    (void)hv_stores(hv, "end_line",   newSVuv((UV)vr->end_line));
    (void)hv_stores(hv, "end_col",    newSVuv((UV)vr->end_col));
    return newRV_noinc((SV *)hv);
}

static void
apply_vim_opts_hv(pTHX_ npl_vim_t *v, SV *opts_sv)
{
    if (!opts_sv || !SvROK(opts_sv) || SvTYPE(SvRV(opts_sv)) != SVt_PVHV) return;
    HV *hv = (HV *)SvRV(opts_sv);
    npl_vim_state_info_t st;
    npl_vim_state_info(v, &st);
    int sw = st.shiftwidth;
    int ts = st.tabstop;
    int et = st.expandtab;
    int wh = st.win_height;
    size_t stop = st.scroll_top;
    SV **val;
    if ((val = hv_fetchs(hv, "shiftwidth", 0)) && SvOK(*val)) sw = (int)SvIV(*val);
    if ((val = hv_fetchs(hv, "tabstop", 0))    && SvOK(*val)) ts = (int)SvIV(*val);
    if ((val = hv_fetchs(hv, "expandtab", 0))  && SvOK(*val)) et = SvTRUE(*val) ? 1 : 0;
    if ((val = hv_fetchs(hv, "win_height", 0)) && SvOK(*val)) wh = (int)SvIV(*val);
    if ((val = hv_fetchs(hv, "scroll_top", 0)) && SvOK(*val)) {
        IV s = SvIV(*val);
        stop = (s >= 0) ? (size_t)s : 0;
    }
    npl_vim_set_options(v, sw, ts, et, wh, stop);
}

static int
is_perl_bool_object(pTHX_ SV *sv)
{
    if (!sv_isobject(sv)) return 0;
    return sv_isa(sv, "JSON::PP::Boolean")
        || sv_isa(sv, "Mojo::JSON::_Bool")
        || sv_isa(sv, "Types::Serialiser::Boolean")
        || sv_isa(sv, "NeoPerl::Core::Msgpack::Bool")
        || sv_isa(sv, "Cpanel::JSON::XS::Boolean")
        || sv_isa(sv, "JSON::XS::Boolean")
        || sv_isa(sv, "boolean");
}

static int
sv_to_msgpack(pTHX_ SV *sv, npl_mp_buf_t *out, int depth)
{
    if (depth > NPL_MP_MAX_DEPTH) return 0;
    if (!sv) return npl_mp_write_nil(out);
    SvGETMAGIC(sv);
    if (!SvOK(sv)) return npl_mp_write_nil(out);

#ifdef SvIsBOOL
    if (SvIsBOOL(sv)) {
        return npl_mp_write_bool(out, SvTRUE(sv) ? 1 : 0);
    }
#endif

    if (SvROK(sv)) {
        SV *rv = SvRV(sv);
        if (is_perl_bool_object(aTHX_ sv)) {
            return npl_mp_write_bool(out, SvTRUE(rv) ? 1 : 0);
        }
        svtype t = SvTYPE(rv);
        if (t == SVt_PVAV) {
            AV *av = (AV *)rv;
            SSize_t top = av_top_index(av);
            uint32_t count = (top >= 0) ? (uint32_t)(top + 1) : 0u;
            if (!npl_mp_write_array_hdr(out, count)) return 0;
            for (SSize_t i = 0; i <= top; i++) {
                SV **elem = av_fetch(av, i, 0);
                if (!sv_to_msgpack(aTHX_ (elem ? *elem : NULL), out, depth + 1)) {
                    return 0;
                }
            }
            return 1;
        }
        if (t == SVt_PVHV) {
            HV *hv = (HV *)rv;
            SV **v;
            if ((v = hv_fetchs(hv, "_msgpack_bool", 0))) {
                return npl_mp_write_bool(out, SvTRUE(*v) ? 1 : 0);
            }
            if ((v = hv_fetchs(hv, "_msgpack_bin", 0))) {
                if (!SvOK(*v)) return npl_mp_write_bin(out, (const uint8_t *)"", 0);
                STRLEN bl = 0;
                const char *bp = SvPVbyte(*v, bl);
                return npl_mp_write_bin(out, (const uint8_t *)bp, (size_t)bl);
            }
            if ((v = hv_fetchs(hv, "_msgpack_float", 0))) {
                return npl_mp_write_f64(out, (double)SvNV(*v));
            }
            if ((v = hv_fetchs(hv, "_nvim_ext", 0))) {
                int8_t etype = (int8_t)SvIV(*v);
                SV **id_v = hv_fetchs(hv, "id", 0);
                if (id_v && SvOK(*id_v)) {
                    return npl_mp_write_nvim_ext(out, etype, (int64_t)SvIV(*id_v));
                }
                SV **data_v = hv_fetchs(hv, "data", 0);
                if (data_v && SvOK(*data_v)) {
                    STRLEN dl = 0;
                    const char *dp = SvPVbyte(*data_v, dl);
                    return npl_mp_write_ext(out, etype, (const uint8_t *)dp, (size_t)dl);
                }
                return npl_mp_write_ext(out, etype, (const uint8_t *)"", 0);
            }

            uint32_t count = 0;
            (void)hv_iterinit(hv);
            while (hv_iternext(hv) != NULL) {
                count++;
            }
            if (!npl_mp_write_map_hdr(out, count)) return 0;

            (void)hv_iterinit(hv);
            HE *he;
            while ((he = hv_iternext(hv)) != NULL) {
                SV *ksv = hv_iterkeysv(he);
                STRLEN klen = 0;
                const char *kstr = SvPV(ksv, klen);
                if (!npl_mp_write_str(out, (const uint8_t *)kstr, (size_t)klen)) {
                    return 0;
                }
                SV *val = hv_iterval(hv, he);
                if (!sv_to_msgpack(aTHX_ val, out, depth + 1)) {
                    return 0;
                }
            }
            return 1;
        }
        if (t < SVt_PVAV) {
            return npl_mp_write_bool(out, SvTRUE(rv) ? 1 : 0);
        }
        return 0;
    }

    if (SvPOK(sv)) {
        STRLEN len = 0;
        const char *s = SvPV(sv, len);
        return npl_mp_write_str(out, (const uint8_t *)s, (size_t)len);
    }
    if (SvIOK(sv)) {
        if (SvIsUV(sv)) {
            return npl_mp_write_uint(out, (uint64_t)SvUVX(sv));
        }
        return npl_mp_write_int(out, (int64_t)SvIVX(sv));
    }
    if (SvNOK(sv)) {
        return npl_mp_write_f64(out, (double)SvNVX(sv));
    }
    STRLEN len = 0;
    const char *s = SvPV(sv, len);
    return npl_mp_write_str(out, (const uint8_t *)s, (size_t)len);
}

static SV *
msgpack_to_sv(pTHX_ const npl_mp_val_t *v)
{
    if (!v) return newSV(0);
    switch (v->type) {
    case NPL_MP_NIL:
        return newSV(0);
    case NPL_MP_BOOL:
        return newSViv(v->u.b ? 1 : 0);
    case NPL_MP_INT:
        return newSViv((IV)v->u.i64);
    case NPL_MP_UINT:
        if (v->u.u64 <= (uint64_t)IV_MAX) {
            return newSViv((IV)v->u.u64);
        }
        return newSVuv((UV)v->u.u64);
    case NPL_MP_F32:
        return newSVnv((NV)v->u.f32);
    case NPL_MP_F64:
        return newSVnv((NV)v->u.f64);
    case NPL_MP_STR:
    case NPL_MP_BIN:
        return newSVpvn((const char *)v->u.bytes.ptr, (STRLEN)v->u.bytes.len);
    case NPL_MP_ARRAY: {
        AV *av = newAV();
        if (v->u.arr.len > 0) av_extend(av, (SSize_t)(v->u.arr.len - 1));
        for (size_t i = 0; i < v->u.arr.len; i++) {
            av_push(av, msgpack_to_sv(aTHX_ v->u.arr.items[i]));
        }
        return newRV_noinc((SV *)av);
    }
    case NPL_MP_MAP: {
        HV *hv = newHV();
        for (size_t i = 0; i < v->u.map.len; i++) {
            const npl_mp_val_t *k = v->u.map.pairs[i].key;
            SV *vsv = msgpack_to_sv(aTHX_ v->u.map.pairs[i].val);
            if (k && (k->type == NPL_MP_STR || k->type == NPL_MP_BIN)) {
                (void)hv_store(hv, (const char *)k->u.bytes.ptr, (I32)k->u.bytes.len, vsv, 0);
            } else {
                char kbuf[64];
                int klen = 0;
                if (!k || k->type == NPL_MP_NIL) {
                    kbuf[0] = '\0';
                    klen = 0;
                } else if (k->type == NPL_MP_INT) {
                    klen = snprintf(kbuf, sizeof(kbuf), "%" PRId64, k->u.i64);
                } else if (k->type == NPL_MP_UINT) {
                    klen = snprintf(kbuf, sizeof(kbuf), "%" PRIu64, k->u.u64);
                } else if (k->type == NPL_MP_BOOL) {
                    klen = snprintf(kbuf, sizeof(kbuf), "%d", k->u.b ? 1 : 0);
                } else if (k->type == NPL_MP_F32) {
                    klen = snprintf(kbuf, sizeof(kbuf), "%.9g", (double)k->u.f32);
                } else if (k->type == NPL_MP_F64) {
                    klen = snprintf(kbuf, sizeof(kbuf), "%.17g", k->u.f64);
                } else {
                    klen = snprintf(kbuf, sizeof(kbuf), "_key_%zu", i);
                }
                if (klen < 0) klen = 0;
                (void)hv_store(hv, kbuf, (I32)klen, vsv, 0);
            }
        }
        return newRV_noinc((SV *)hv);
    }
    case NPL_MP_EXT: {
        HV *hv = newHV();
        (void)hv_stores(hv, "_nvim_ext", newSViv((IV)v->u.ext.ext_type));
        (void)hv_stores(hv, "data", newSVpvn((const char *)v->u.ext.ptr, (STRLEN)v->u.ext.len));
        if (v->u.ext.has_int_id) {
            (void)hv_stores(hv, "id", newSViv((IV)v->u.ext.int_id));
        }
        return newRV_noinc((SV *)hv);
    }
    default:
        return newSV(0);
    }
}

MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core

PROTOTYPES: DISABLE

IV
is_perl5_mt(...)
CODE:
    RETVAL = NPL_IS_PERL5_MT;
OUTPUT:
    RETVAL

IV
have_packed_av(...)
CODE:
    RETVAL = NPL_HAVE_PACKED_AV;
OUTPUT:
    RETVAL

IV
force_scalar(...)
CODE:
    RETVAL = npl_arch_force_scalar();
OUTPUT:
    RETVAL

UV
timebase_ticks(...)
CODE:
    RETVAL = (UV)npl_timebase_ticks();
OUTPUT:
    RETVAL

SV *
arch_info(...)
CODE:
    npl_arch_info_t ai;
    npl_detect_arch_info(&ai);
    HV *hv = newHV();
    (void)hv_stores(hv, "arch",                newSVpv(ai.arch ? ai.arch : "unknown", 0));
    (void)hv_stores(hv, "page_size",           newSVuv((UV)ai.page_size));
    (void)hv_stores(hv, "physical_cores",      newSViv((IV)ai.physical_cores));
    (void)hv_stores(hv, "logical_cpus",        newSViv((IV)ai.logical_cpus));
    (void)hv_stores(hv, "recommended_workers", newSViv((IV)ai.recommended_workers));
    (void)hv_stores(hv, "simd_level",          newSVpv(ai.simd_level ? ai.simd_level : "scalar", 0));
    (void)hv_stores(hv, "power_isa",           newSVpv(ai.power_isa ? ai.power_isa : "none", 0));
    (void)hv_stores(hv, "has_vsx",             newSViv((IV)ai.has_vsx));
    (void)hv_stores(hv, "has_power8",          newSViv((IV)ai.has_power8));
    (void)hv_stores(hv, "has_power9",          newSViv((IV)ai.has_power9));
    (void)hv_stores(hv, "has_power10",         newSViv((IV)ai.has_power10));
    (void)hv_stores(hv, "has_mma",             newSViv((IV)ai.has_mma));
    (void)hv_stores(hv, "has_neon",            newSViv((IV)ai.has_neon));
    (void)hv_stores(hv, "has_sse2",            newSViv((IV)ai.has_sse2));
    (void)hv_stores(hv, "has_avx2",            newSViv((IV)ai.has_avx2));
    (void)hv_stores(hv, "has_nx_gzip",         newSViv((IV)ai.has_nx_gzip));
    (void)hv_stores(hv, "has_treesitter",      newSViv((IV)npl_ts_available()));
    (void)hv_stores(hv, "has_libllama",        newSViv((IV)npl_llama_available()));
    RETVAL = newRV_noinc((SV *)hv);
OUTPUT:
    RETVAL

const char *
detect_language(filename)
    const char *filename
CODE:
    RETVAL = npl_lang_name(npl_lang_from_filename(filename));
OUTPUT:
    RETVAL

const char *
token_name(tok_type)
    IV tok_type
CODE:
    RETVAL = npl_tok_name((npl_tok_type_t)tok_type);
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::Buffer

PROTOTYPES: DISABLE

SV *
new(klass)
    const char *klass
CODE:
    (void)klass;
    npl_buf_t *b = npl_buf_new();
    if (!b) croak("Failed to allocate NeoPerl::Core::Buffer");
    RETVAL = wrap_buf(aTHX_ b);
OUTPUT:
    RETVAL

SV *
open_file(klass, path)
    const char *klass
    const char *path
CODE:
    (void)klass;
    char err[256] = {0};
    npl_buf_t *b = npl_buf_open_file(path, err, sizeof(err));
    if (!b) croak("open_file(%s): %s", path, err[0] ? err : "failed");
    RETVAL = wrap_buf(aTHX_ b);
OUTPUT:
    RETVAL

SV *
from_string(klass, str_sv)
    const char *klass
    SV *str_sv
CODE:
    (void)klass;
    STRLEN len = 0;
    const char *s = SvPV(str_sv, len);
    npl_buf_t *b = npl_buf_from_string(s, (size_t)len);
    if (!b) croak("Failed to allocate NeoPerl::Core::Buffer from string");
    RETVAL = wrap_buf(aTHX_ b);
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
CODE:
    if (SvROK(self)) {
        IV ptr = SvIV((SV *)SvRV(self));
        if (ptr) {
            npl_buf_free(INT2PTR(npl_buf_t *, ptr));
            sv_setiv((SV *)SvRV(self), 0);
        }
    }

IV
insert(self, offset, str_sv)
    SV *self
    UV  offset
    SV *str_sv
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    STRLEN len = 0;
    const char *s = SvPV(str_sv, len);
    RETVAL = (IV)npl_buf_insert(b, (size_t)offset, s, (size_t)len);
OUTPUT:
    RETVAL

IV
delete(self, offset, len)
    SV *self
    UV  offset
    UV  len
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    RETVAL = (IV)npl_buf_delete(b, (size_t)offset, (size_t)len);
OUTPUT:
    RETVAL

void
begin_group(self)
    SV *self
CODE:
    npl_buf_begin_group(unwrap_buf(aTHX_ self));

void
end_group(self)
    SV *self
CODE:
    npl_buf_end_group(unwrap_buf(aTHX_ self));

IV
undo(self)
    SV *self
CODE:
    RETVAL = (IV)npl_buf_undo(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

IV
redo(self)
    SV *self
CODE:
    RETVAL = (IV)npl_buf_redo(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

IV
undo_older(self)
    SV *self
CODE:
    RETVAL = (IV)npl_buf_undo_older(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

IV
undo_newer(self)
    SV *self
CODE:
    RETVAL = (IV)npl_buf_undo_newer(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

IV
undo_goto(self, seq)
    SV *self
    UV  seq
CODE:
    RETVAL = (IV)npl_buf_undo_goto(unwrap_buf(aTHX_ self), (uint64_t)seq);
OUTPUT:
    RETVAL

IV
can_undo(self)
    SV *self
CODE:
    RETVAL = (IV)npl_buf_can_undo(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

IV
can_redo(self)
    SV *self
CODE:
    RETVAL = (IV)npl_buf_can_redo(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

UV
undo_seq(self)
    SV *self
CODE:
    RETVAL = (UV)npl_buf_undo_seq(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

SV *
undo_list(self)
    SV *self
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    npl_undo_info_t *list = NULL;
    size_t n = npl_buf_undo_list(b, &list);
    AV *av = newAV();
    if (n > 0) av_extend(av, (SSize_t)(n - 1));
    for (size_t i = 0; i < n; i++) {
        HV *hv = newHV();
        (void)hv_stores(hv, "seq",        newSVuv((UV)list[i].seq));
        (void)hv_stores(hv, "parent_seq", newSVuv((UV)list[i].parent_seq));
        (void)hv_stores(hv, "time",       newSViv((IV)list[i].timestamp));
        (void)hv_stores(hv, "edits",      newSVuv((UV)list[i].edit_count));
        (void)hv_stores(hv, "is_current", newSViv((IV)list[i].is_current));
        AV *ch = newAV();
        for (size_t c = 0; c < list[i].child_count; c++) {
            av_push(ch, newSVuv((UV)list[i].child_seqs[c]));
        }
        (void)hv_stores(hv, "children", newRV_noinc((SV *)ch));
        av_push(av, newRV_noinc((SV *)hv));
    }
    npl_buf_undo_list_free(list, n);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

UV
line_count(self)
    SV *self
CODE:
    RETVAL = (UV)npl_buf_line_count(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

UV
byte_length(self)
    SV *self
CODE:
    RETVAL = (UV)npl_buf_byte_length(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

UV
revision(self)
    SV *self
CODE:
    RETVAL = (UV)npl_buf_revision(unwrap_buf(aTHX_ self));
OUTPUT:
    RETVAL

SV *
get_line(self, line)
    SV *self
    IV  line
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    if (line < 0) {
        RETVAL = &PL_sv_undef;
    } else {
        size_t len = 0;
        char *s = npl_buf_get_line_alloc(b, (size_t)line, &len);
        if (!s) {
            RETVAL = &PL_sv_undef;
        } else {
            RETVAL = newSVpvn(s, len);
            free(s);
        }
    }
OUTPUT:
    RETVAL

SV *
get_lines(self, first_line, count)
    SV *self
    IV  first_line
    IV  count
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    AV *av = newAV();
    if (first_line < 0) first_line = 0;
    size_t total = npl_buf_line_count(b);
    if (count > 0 && (size_t)first_line < total) {
        size_t end = (size_t)first_line + (size_t)count;
        if (end > total) end = total;
        av_extend(av, (SSize_t)(end - (size_t)first_line - 1));
        for (size_t l = (size_t)first_line; l < end; l++) {
            size_t len = 0;
            char *s = npl_buf_get_line_alloc(b, l, &len);
            if (s) {
                av_push(av, newSVpvn(s, len));
                free(s);
            } else {
                av_push(av, newSVpvs(""));
            }
        }
    }
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

SV *
get_range(self, offset, len)
    SV *self
    UV  offset
    UV  len
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    if (len == 0) {
        RETVAL = newSVpvs("");
    } else {
        char *tmp = (char *)malloc((size_t)len);
        if (!tmp) croak("Out of memory in get_range");
        size_t got = npl_buf_copy_range(b, (size_t)offset, (size_t)len, tmp);
        RETVAL = newSVpvn(tmp, got);
        free(tmp);
    }
OUTPUT:
    RETVAL

SV *
to_string(self)
    SV *self
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    size_t len = 0;
    char *s = npl_buf_to_string(b, &len);
    if (!s) croak("Out of memory in to_string");
    RETVAL = newSVpvn(s, len);
    free(s);
OUTPUT:
    RETVAL

void
line_bounds(self, line)
    SV *self
    IV  line
PPCODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    size_t st = 0, ln = 0;
    if (line >= 0 && npl_buf_line_bounds(b, (size_t)line, &st, &ln)) {
        EXTEND(SP, 2);
        PUSHs(sv_2mortal(newSVuv((UV)st)));
        PUSHs(sv_2mortal(newSVuv((UV)ln)));
    }

UV
line_col_to_offset(self, line, col)
    SV *self
    IV  line
    IV  col
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    if (line < 0) line = 0;
    if (col < 0) col = 0;
    RETVAL = (UV)npl_buf_line_col_to_offset(b, (size_t)line, (size_t)col);
OUTPUT:
    RETVAL

void
offset_to_line_col(self, offset)
    SV *self
    UV  offset
PPCODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    size_t l = 0, c = 0;
    npl_buf_offset_to_line_col(b, (size_t)offset, &l, &c);
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSVuv((UV)l)));
    PUSHs(sv_2mortal(newSVuv((UV)c)));

IV
save_file(self, path)
    SV *self
    const char *path
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    char err[256] = {0};
    int ok = npl_buf_save_file(b, path, err, sizeof(err));
    if (!ok) croak("save_file(%s): %s", path, err[0] ? err : "failed");
    RETVAL = 1;
OUTPUT:
    RETVAL

UV
set_extmark(self, ns, line, col, opts_sv = &PL_sv_undef)
    SV         *self
    const char *ns
    IV          line
    IV          col
    SV         *opts_sv
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    if (line < 0) line = 0;
    if (col < 0) col = 0;

    npl_extmark_spec_t spec;
    memset(&spec, 0, sizeof(spec));
    spec.start_byte = npl_buf_line_col_to_offset(b, (size_t)line, (size_t)col);
    spec.right_gravity = 1;
    spec.end_right_gravity = 0;
    spec.priority = 100;

    const char **vl_ptrs = NULL;
    size_t vl_cnt = 0;
    const char **vlh_ptrs = NULL;
    size_t vlh_cnt = 0;
    const char *single_vlh = NULL;

    if (opts_sv && SvROK(opts_sv) && SvTYPE(SvRV(opts_sv)) == SVt_PVHV) {
        HV *hv = (HV *)SvRV(opts_sv);
        SV **v;
        if ((v = hv_fetchs(hv, "id", 0)) && SvOK(*v)) {
            spec.id = (uint64_t)SvUV(*v);
        }
        if ((v = hv_fetchs(hv, "offset", 0)) && SvOK(*v)) {
            spec.start_byte = (size_t)SvUV(*v);
        }
        if ((v = hv_fetchs(hv, "end_offset", 0)) && SvOK(*v)) {
            spec.end_byte = (size_t)SvUV(*v);
            spec.has_end = 1;
        } else {
            SV **el_v = hv_fetchs(hv, "end_line", 0);
            SV **ec_v = hv_fetchs(hv, "end_col", 0);
            if ((el_v && SvOK(*el_v)) || (ec_v && SvOK(*ec_v))) {
                IV el = (el_v && SvOK(*el_v)) ? SvIV(*el_v) : line;
                IV ec = (ec_v && SvOK(*ec_v)) ? SvIV(*ec_v) : col;
                if (el < 0) el = 0;
                if (ec < 0) ec = 0;
                spec.end_byte = npl_buf_line_col_to_offset(b, (size_t)el, (size_t)ec);
                spec.has_end = 1;
            }
        }
        if ((v = hv_fetchs(hv, "right_gravity", 0)) && SvOK(*v)) {
            spec.right_gravity = SvTRUE(*v) ? 1 : 0;
        }
        if ((v = hv_fetchs(hv, "end_right_gravity", 0)) && SvOK(*v)) {
            spec.end_right_gravity = SvTRUE(*v) ? 1 : 0;
        }
        if ((v = hv_fetchs(hv, "priority", 0)) && SvOK(*v)) {
            spec.priority = (int32_t)SvIV(*v);
        }
        if ((v = hv_fetchs(hv, "hl_group", 0)) && SvOK(*v)) {
            spec.hl_group = SvPV_nolen(*v);
        }
        if ((v = hv_fetchs(hv, "sign_text", 0)) && SvOK(*v)) {
            spec.sign_text = SvPV_nolen(*v);
        }
        if ((v = hv_fetchs(hv, "sign_hl", 0)) && SvOK(*v)) {
            spec.sign_hl = SvPV_nolen(*v);
        }
        if ((v = hv_fetchs(hv, "virt_text", 0)) && SvOK(*v)) {
            spec.virt_text = SvPV_nolen(*v);
        }
        if ((v = hv_fetchs(hv, "virt_hl", 0)) && SvOK(*v)) {
            spec.virt_hl = SvPV_nolen(*v);
        }
        if ((v = hv_fetchs(hv, "virt_pos", 0)) && SvOK(*v)) {
            spec.virt_pos = SvPV_nolen(*v);
        }
        if ((v = hv_fetchs(hv, "virt_lines_above", 0)) && SvOK(*v)) {
            spec.virt_lines_above = SvTRUE(*v) ? 1 : 0;
        }
        if ((v = hv_fetchs(hv, "virt_lines", 0)) && SvROK(*v) && SvTYPE(SvRV(*v)) == SVt_PVAV) {
            AV *av = (AV *)SvRV(*v);
            SSize_t top = av_top_index(av);
            if (top >= 0) {
                vl_cnt = (size_t)(top + 1);
                vl_ptrs = (const char **)calloc(vl_cnt, sizeof(const char *));
                if (vl_ptrs) {
                    for (size_t i = 0; i < vl_cnt; i++) {
                        SV **elem = av_fetch(av, (SSize_t)i, 0);
                        vl_ptrs[i] = (elem && SvOK(*elem)) ? SvPV_nolen(*elem) : "";
                    }
                    spec.virt_lines = vl_ptrs;
                    spec.virt_line_count = vl_cnt;
                }
            }
        }
        if ((v = hv_fetchs(hv, "virt_lines_hl", 0)) && SvOK(*v)) {
            if (SvROK(*v) && SvTYPE(SvRV(*v)) == SVt_PVAV) {
                AV *av = (AV *)SvRV(*v);
                SSize_t top = av_top_index(av);
                if (top >= 0) {
                    vlh_cnt = (size_t)(top + 1);
                    vlh_ptrs = (const char **)calloc(vlh_cnt, sizeof(const char *));
                    if (vlh_ptrs) {
                        for (size_t i = 0; i < vlh_cnt; i++) {
                            SV **elem = av_fetch(av, (SSize_t)i, 0);
                            vlh_ptrs[i] = (elem && SvOK(*elem)) ? SvPV_nolen(*elem) : "";
                        }
                        spec.virt_lines_hl = vlh_ptrs;
                        spec.virt_line_hl_count = vlh_cnt;
                    }
                }
            } else {
                single_vlh = SvPV_nolen(*v);
                spec.virt_lines_hl = &single_vlh;
                spec.virt_line_hl_count = 1;
            }
        }
    }

    RETVAL = (UV)npl_buf_set_extmark(b, ns, &spec);
    free(vl_ptrs);
    free(vlh_ptrs);
OUTPUT:
    RETVAL

IV
del_extmark(self, ns, id)
    SV         *self
    const char *ns
    UV          id
CODE:
    RETVAL = (IV)npl_buf_del_extmark(unwrap_buf(aTHX_ self), ns, (uint64_t)id);
OUTPUT:
    RETVAL

void
clear_namespace(self, ns, start_line = -1, end_line = -1)
    SV         *self
    const char *ns
    IV          start_line
    IV          end_line
CODE:
    npl_buf_clear_namespace(unwrap_buf(aTHX_ self), ns, (int64_t)start_line, (int64_t)end_line);

SV *
get_extmarks(self, ns_sv = &PL_sv_undef, start_line = -1, end_line = -1)
    SV *self
    SV *ns_sv
    IV  start_line
    IV  end_line
CODE:
    npl_buf_t *b = unwrap_buf(aTHX_ self);
    const char *ns = (ns_sv && SvOK(ns_sv)) ? SvPV_nolen(ns_sv) : "";
    npl_extmark_view_t *views = NULL;
    size_t n = npl_buf_get_extmarks(b, ns, (int64_t)start_line, (int64_t)end_line, &views);
    AV *av = newAV();
    if (n > 0) av_extend(av, (SSize_t)(n - 1));
    for (size_t i = 0; i < n; i++) {
        const npl_extmark_view_t *v = &views[i];
        HV *hv = newHV();
        (void)hv_stores(hv, "id",                newSVuv((UV)v->id));
        (void)hv_stores(hv, "ns",                newSVpv(v->ns ? v->ns : "", 0));
        (void)hv_stores(hv, "line",              newSVuv((UV)v->start_line));
        (void)hv_stores(hv, "col",               newSVuv((UV)v->start_col));
        (void)hv_stores(hv, "offset",            newSVuv((UV)v->start_byte));
        (void)hv_stores(hv, "end_line",          newSVuv((UV)v->end_line));
        (void)hv_stores(hv, "end_col",           newSVuv((UV)v->end_col));
        (void)hv_stores(hv, "end_offset",        newSVuv((UV)v->end_byte));
        (void)hv_stores(hv, "has_end",           newSViv((IV)v->has_end));
        (void)hv_stores(hv, "right_gravity",     newSViv((IV)v->right_gravity));
        (void)hv_stores(hv, "end_right_gravity", newSViv((IV)v->end_right_gravity));
        (void)hv_stores(hv, "priority",          newSViv((IV)v->priority));
        if (v->hl_group)  (void)hv_stores(hv, "hl_group",  newSVpv(v->hl_group, 0));
        if (v->sign_text) (void)hv_stores(hv, "sign_text", newSVpv(v->sign_text, 0));
        if (v->sign_hl)   (void)hv_stores(hv, "sign_hl",   newSVpv(v->sign_hl, 0));
        if (v->virt_text) (void)hv_stores(hv, "virt_text", newSVpv(v->virt_text, 0));
        if (v->virt_hl)   (void)hv_stores(hv, "virt_hl",   newSVpv(v->virt_hl, 0));
        if (v->virt_pos)  (void)hv_stores(hv, "virt_pos",  newSVpv(v->virt_pos, 0));
        if (v->virt_line_count > 0 && v->virt_lines) {
            AV *vl = newAV();
            for (size_t j = 0; j < v->virt_line_count; j++) {
                av_push(vl, newSVpv(v->virt_lines[j] ? v->virt_lines[j] : "", 0));
            }
            (void)hv_stores(hv, "virt_lines", newRV_noinc((SV *)vl));
        }
        if (v->virt_line_hl_count > 0 && v->virt_lines_hl) {
            AV *vlh = newAV();
            for (size_t j = 0; j < v->virt_line_hl_count; j++) {
                av_push(vlh, newSVpv(v->virt_lines_hl[j] ? v->virt_lines_hl[j] : "", 0));
            }
            (void)hv_stores(hv, "virt_lines_hl", newRV_noinc((SV *)vlh));
        }
        (void)hv_stores(hv, "virt_lines_above", newSViv((IV)v->virt_lines_above));
        av_push(av, newRV_noinc((SV *)hv));
    }
    npl_buf_extmarks_free(views, n);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

UV
extmark_count(self, ns_sv = &PL_sv_undef)
    SV *self
    SV *ns_sv
CODE:
    const char *ns = (ns_sv && SvOK(ns_sv)) ? SvPV_nolen(ns_sv) : "";
    RETVAL = (UV)npl_buf_extmark_count(unwrap_buf(aTHX_ self), ns);
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::Diff

PROTOTYPES: DISABLE

SV *
myers_lines(old_ref, new_ref)
    SV *old_ref
    SV *new_ref
CODE:
    if (!SvROK(old_ref) || SvTYPE(SvRV(old_ref)) != SVt_PVAV ||
        !SvROK(new_ref) || SvTYPE(SvRV(new_ref)) != SVt_PVAV) {
        croak("myers_lines expects two array references");
    }
    AV *old_av = (AV *)SvRV(old_ref);
    AV *new_av = (AV *)SvRV(new_ref);
    size_t old_n = (size_t)(av_top_index(old_av) + 1);
    size_t new_n = (size_t)(av_top_index(new_av) + 1);

    npl_diff_line_t *ol = old_n ? (npl_diff_line_t *)calloc(old_n, sizeof(npl_diff_line_t)) : NULL;
    npl_diff_line_t *nl = new_n ? (npl_diff_line_t *)calloc(new_n, sizeof(npl_diff_line_t)) : NULL;
    if ((old_n && !ol) || (new_n && !nl)) {
        free(ol);
        free(nl);
        croak("Out of memory in myers_lines");
    }
    for (size_t i = 0; i < old_n; i++) {
        SV **e = av_fetch(old_av, (SSize_t)i, 0);
        if (e && SvOK(*e)) {
            STRLEN l = 0;
            const char *p = SvPV(*e, l);
            ol[i].ptr = p;
            ol[i].len = (size_t)l;
            ol[i].hash = npl_diff_hash_line(p, (size_t)l);
        } else {
            ol[i].ptr = "";
            ol[i].len = 0;
            ol[i].hash = npl_diff_hash_line("", 0);
        }
    }
    for (size_t i = 0; i < new_n; i++) {
        SV **e = av_fetch(new_av, (SSize_t)i, 0);
        if (e && SvOK(*e)) {
            STRLEN l = 0;
            const char *p = SvPV(*e, l);
            nl[i].ptr = p;
            nl[i].len = (size_t)l;
            nl[i].hash = npl_diff_hash_line(p, (size_t)l);
        } else {
            nl[i].ptr = "";
            nl[i].len = 0;
            nl[i].hash = npl_diff_hash_line("", 0);
        }
    }

    npl_diff_result_t res;
    (void)npl_diff_myers(ol, old_n, nl, new_n, &res);
    free(ol);
    free(nl);
    AV *out = diff_result_to_av(aTHX_ &res);
    npl_diff_result_free(&res);
    RETVAL = newRV_noinc((SV *)out);
OUTPUT:
    RETVAL

SV *
myers_text(old_sv, new_sv)
    SV *old_sv
    SV *new_sv
CODE:
    STRLEN olen = 0, nlen = 0;
    const char *ot = SvPV(old_sv, olen);
    const char *nt = SvPV(new_sv, nlen);
    npl_diff_result_t res;
    (void)npl_diff_myers_text(ot, (size_t)olen, nt, (size_t)nlen, &res);
    AV *out = diff_result_to_av(aTHX_ &res);
    npl_diff_result_free(&res);
    RETVAL = newRV_noinc((SV *)out);
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::Syntax

PROTOTYPES: DISABLE

SV *
new(klass, lang_name = "text")
    const char *klass
    const char *lang_name
CODE:
    (void)klass;
    npl_syntax_t *syn = npl_syntax_new(npl_lang_from_name(lang_name));
    if (!syn) croak("Failed to allocate NeoPerl::Core::Syntax");
    RETVAL = wrap_syn(aTHX_ syn);
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
CODE:
    if (SvROK(self)) {
        IV ptr = SvIV((SV *)SvRV(self));
        if (ptr) {
            npl_syntax_free(INT2PTR(npl_syntax_t *, ptr));
            sv_setiv((SV *)SvRV(self), 0);
        }
    }

const char *
language(self)
    SV *self
CODE:
    RETVAL = npl_lang_name(npl_syntax_get_lang(unwrap_syn(aTHX_ self)));
OUTPUT:
    RETVAL

void
set_language(self, lang_name)
    SV         *self
    const char *lang_name
CODE:
    npl_syntax_set_lang(unwrap_syn(aTHX_ self), npl_lang_from_name(lang_name));

void
invalidate(self, from_line, line_delta = 0)
    SV *self
    IV  from_line
    IV  line_delta
CODE:
    if (from_line < 0) from_line = 0;
    npl_syntax_invalidate(unwrap_syn(aTHX_ self), (size_t)from_line, (int64_t)line_delta);

SV *
tokenize_range(self, buf_sv, first_line, count)
    SV *self
    SV *buf_sv
    IV  first_line
    IV  count
CODE:
    npl_syntax_t *syn = unwrap_syn(aTHX_ self);
    npl_buf_t    *buf = unwrap_buf(aTHX_ buf_sv);
    AV *outer = newAV();
    if (first_line < 0) first_line = 0;
    size_t total = npl_buf_line_count(buf);
    if (count > 0 && (size_t)first_line < total) {
        size_t end_line = (size_t)first_line + (size_t)count;
        if (end_line > total) end_line = total;
        npl_syntax_sync(buf, syn, end_line);
        npl_lang_t lang = npl_syntax_get_lang(syn);
        av_extend(outer, (SSize_t)(end_line - (size_t)first_line - 1));
        char stack_buf[4096];
        npl_token_t toks[1024];
        for (size_t line = (size_t)first_line; line < end_line; line++) {
            size_t llen = npl_buf_get_line_buf(buf, line, stack_buf, sizeof(stack_buf));
            char *heap_buf = NULL;
            const char *lptr = stack_buf;
            if (llen >= sizeof(stack_buf)) {
                heap_buf = npl_buf_get_line_alloc(buf, line, &llen);
                if (heap_buf) lptr = heap_buf;
            }
            uint8_t st = (line == 0) ? NPL_STATE_NORMAL : npl_syntax_end_state(syn, line - 1);
            size_t ntok = 0;
            (void)npl_syntax_lex_line(lang, lptr, llen, st, toks, 1024, &ntok);
            free(heap_buf);

            AV *la = newAV();
            if (ntok > 0) {
                av_extend(la, (SSize_t)(ntok * 3 - 1));
                for (size_t j = 0; j < ntok; j++) {
                    av_push(la, newSVuv((UV)toks[j].col));
                    av_push(la, newSVuv((UV)toks[j].len));
                    av_push(la, newSVuv((UV)toks[j].type));
                }
            }
            av_push(outer, newRV_noinc((SV *)la));
        }
    }
    RETVAL = newRV_noinc((SV *)outer);
OUTPUT:
    RETVAL

void
tokenize_line(lang_name, line_sv, start_state = 0)
    const char *lang_name
    SV         *line_sv
    UV          start_state
PPCODE:
    STRLEN len = 0;
    const char *s = SvPV(line_sv, len);
    npl_token_t toks[1024];
    size_t ntok = 0;
    uint8_t end_st = npl_syntax_lex_line(npl_lang_from_name(lang_name), s, (size_t)len,
                                         (uint8_t)start_state, toks, 1024, &ntok);
    AV *la = newAV();
    if (ntok > 0) {
        av_extend(la, (SSize_t)(ntok * 3 - 1));
        for (size_t j = 0; j < ntok; j++) {
            av_push(la, newSVuv((UV)toks[j].col));
            av_push(la, newSVuv((UV)toks[j].len));
            av_push(la, newSVuv((UV)toks[j].type));
        }
    }
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newRV_noinc((SV *)la)));
    PUSHs(sv_2mortal(newSVuv((UV)end_st)));

UV
end_state(self, line)
    SV *self
    IV  line
CODE:
    if (line < 0) line = 0;
    RETVAL = (UV)npl_syntax_end_state(unwrap_syn(aTHX_ self), (size_t)line);
OUTPUT:
    RETVAL

UV
last_relex_lines(self)
    SV *self
CODE:
    RETVAL = (UV)npl_syntax_last_relex_lines(unwrap_syn(aTHX_ self));
OUTPUT:
    RETVAL

SV *
extract_symbols(self, buf_sv)
    SV *self
    SV *buf_sv
CODE:
    npl_syntax_t *syn = unwrap_syn(aTHX_ self);
    npl_buf_t    *buf = unwrap_buf(aTHX_ buf_sv);
    npl_symbol_list_t list;
    (void)npl_syntax_extract_symbols_buf(buf, npl_syntax_get_lang(syn), &list);
    AV *av = symbols_to_av(aTHX_ &list);
    npl_symbol_list_free(&list);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

SV *
supported_languages(...)
CODE:
    AV *av = newAV();
    size_t n = npl_lang_count();
    if (n > 0) av_extend(av, (SSize_t)(n - 1));
    for (size_t i = 0; i < n; i++) {
        av_push(av, newSVpv(npl_lang_name((npl_lang_t)i), 0));
    }
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

SV *
extract_symbols_text(lang_name, text_sv)
    const char *lang_name
    SV         *text_sv
CODE:
    STRLEN len = 0;
    const char *s = SvPV(text_sv, len);
    npl_symbol_list_t list;
    (void)npl_syntax_extract_symbols_text(s, (size_t)len, npl_lang_from_name(lang_name), &list);
    AV *av = symbols_to_av(aTHX_ &list);
    npl_symbol_list_free(&list);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::TreeSitter

PROTOTYPES: DISABLE

IV
available(...)
CODE:
    RETVAL = (IV)npl_ts_available();
OUTPUT:
    RETVAL

const char *
library_path(...)
CODE:
    RETVAL = npl_ts_library_path();
OUTPUT:
    RETVAL

IV
load_grammar(lang_name, lib_path, symbol_name = "")
    const char *lang_name
    const char *lib_path
    const char *symbol_name
CODE:
    RETVAL = (IV)npl_ts_load_grammar(lang_name, lib_path, symbol_name);
OUTPUT:
    RETVAL

IV
has_grammar(lang_name)
    const char *lang_name
CODE:
    RETVAL = (IV)npl_ts_has_grammar(lang_name);
OUTPUT:
    RETVAL

SV *
parse_nodes(lang_name, src_sv, max_nodes = 4096)
    const char *lang_name
    SV         *src_sv
    UV          max_nodes
CODE:
    STRLEN len = 0;
    const char *s = SvPV(src_sv, len);
    npl_ts_node_list_t list;
    if (!npl_ts_parse_nodes(lang_name, s, (size_t)len, (size_t)max_nodes, &list)) {
        RETVAL = &PL_sv_undef;
    } else {
        AV *av = ts_nodes_to_av(aTHX_ &list);
        npl_ts_node_list_free(&list);
        RETVAL = newRV_noinc((SV *)av);
    }
OUTPUT:
    RETVAL

SV *
node_at(lang_name, src_sv, byte_offset)
    const char *lang_name
    SV         *src_sv
    UV          byte_offset
CODE:
    STRLEN len = 0;
    const char *s = SvPV(src_sv, len);
    npl_ts_node_list_t chain;
    if (!npl_ts_node_at(lang_name, s, (size_t)len, (uint32_t)byte_offset, &chain)) {
        RETVAL = &PL_sv_undef;
    } else {
        AV *av = ts_nodes_to_av(aTHX_ &chain);
        npl_ts_node_list_free(&chain);
        RETVAL = newRV_noinc((SV *)av);
    }
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::Fuzzy

PROTOTYPES: DISABLE

SV *
walk_files(root_dir, max_files = 0)
    const char *root_dir
    UV          max_files
CODE:
    npl_file_list_t list;
    (void)npl_walk_files(root_dir, (size_t)max_files, &list);
    AV *av = newAV();
    if (list.count > 0) av_extend(av, (SSize_t)(list.count - 1));
    for (size_t i = 0; i < list.count; i++) {
        av_push(av, newSVpv(list.paths[i], 0));
    }
    npl_file_list_free(&list);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

SV *
score(query_sv, cand_sv)
    SV *query_sv
    SV *cand_sv
CODE:
    STRLEN qlen = 0, clen = 0;
    const char *q = SvPV(query_sv, qlen);
    const char *c = SvPV(cand_sv, clen);
    npl_fuzzy_match_t m;
    if (!npl_fuzzy_score(q, (size_t)qlen, c, (size_t)clen, &m)) {
        RETVAL = &PL_sv_undef;
    } else {
        HV *hv = newHV();
        (void)hv_stores(hv, "score", newSViv((IV)m.score));
        AV *pos = newAV();
        if (m.pos_count > 0) av_extend(pos, (SSize_t)(m.pos_count - 1));
        for (size_t i = 0; i < m.pos_count; i++) {
            av_push(pos, newSVuv((UV)m.positions[i]));
        }
        (void)hv_stores(hv, "positions", newRV_noinc((SV *)pos));
        npl_fuzzy_match_free(&m);
        RETVAL = newRV_noinc((SV *)hv);
    }
OUTPUT:
    RETVAL

SV *
filter(query_sv, cands_ref, limit = 100)
    SV *query_sv
    SV *cands_ref
    UV  limit
CODE:
    if (!SvROK(cands_ref) || SvTYPE(SvRV(cands_ref)) != SVt_PVAV) {
        croak("filter expects an array reference of candidates");
    }
    STRLEN qlen = 0;
    const char *q = SvPV(query_sv, qlen);
    AV *cav = (AV *)SvRV(cands_ref);
    size_t n = (size_t)(av_top_index(cav) + 1);

    const char **ptrs = n ? (const char **)calloc(n, sizeof(const char *)) : NULL;
    size_t      *lens = n ? (size_t *)calloc(n, sizeof(size_t)) : NULL;
    if (n && (!ptrs || !lens)) {
        free(ptrs);
        free(lens);
        croak("Out of memory in Fuzzy::filter");
    }
    for (size_t i = 0; i < n; i++) {
        SV **e = av_fetch(cav, (SSize_t)i, 0);
        if (e && SvOK(*e)) {
            STRLEN l = 0;
            ptrs[i] = SvPV(*e, l);
            lens[i] = (size_t)l;
        } else {
            ptrs[i] = "";
            lens[i] = 0;
        }
    }

    npl_fuzzy_results_t res;
    (void)npl_fuzzy_filter(q, (size_t)qlen, ptrs, lens, n, (size_t)limit, &res);

    AV *out = newAV();
    if (res.count > 0) av_extend(out, (SSize_t)(res.count - 1));
    for (size_t i = 0; i < res.count; i++) {
        const npl_fuzzy_item_t *it = &res.items[i];
        HV *hv = newHV();
        (void)hv_stores(hv, "index", newSVuv((UV)it->orig_index));
        (void)hv_stores(hv, "text",  newSVpvn(ptrs[it->orig_index], lens[it->orig_index]));
        (void)hv_stores(hv, "score", newSViv((IV)it->score));
        AV *pos = newAV();
        if (it->pos_count > 0) av_extend(pos, (SSize_t)(it->pos_count - 1));
        for (size_t j = 0; j < it->pos_count; j++) {
            av_push(pos, newSVuv((UV)it->positions[j]));
        }
        (void)hv_stores(hv, "positions", newRV_noinc((SV *)pos));
        av_push(out, newRV_noinc((SV *)hv));
    }

    npl_fuzzy_results_free(&res);
    free(ptrs);
    free(lens);
    RETVAL = newRV_noinc((SV *)out);
OUTPUT:
    RETVAL

SV *
grep_dir(root_dir, pat_sv, icase = 0, max_results = 2000)
    const char *root_dir
    SV         *pat_sv
    IV          icase
    UV          max_results
CODE:
    STRLEN plen = 0;
    const char *pat = SvPV(pat_sv, plen);
    npl_grep_results_t res;
    (void)npl_grep_dir(root_dir, pat, (size_t)plen, icase ? 1 : 0, (size_t)max_results, &res);
    AV *av = grep_results_to_av(aTHX_ &res, 1);
    npl_grep_results_free(&res);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

SV *
grep_buffer(buf_sv, pat_sv, icase = 0, max_results = 2000)
    SV *buf_sv
    SV *pat_sv
    IV  icase
    UV  max_results
CODE:
    npl_buf_t *buf = unwrap_buf(aTHX_ buf_sv);
    STRLEN plen = 0;
    const char *pat = SvPV(pat_sv, plen);
    npl_grep_results_t res;
    (void)npl_grep_buffer(buf, pat, (size_t)plen, icase ? 1 : 0, (size_t)max_results, &res);
    AV *av = grep_results_to_av(aTHX_ &res, 0);
    npl_grep_results_free(&res);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::Term

PROTOTYPES: DISABLE

SV *
spawn(klass, rows = 24, cols = 80, cmd = "/bin/sh", args_ref = &PL_sv_undef, cwd = "")
    const char *klass
    IV          rows
    IV          cols
    const char *cmd
    SV         *args_ref
    const char *cwd
CODE:
    (void)klass;
    const char **argv = NULL;
    if (args_ref && SvROK(args_ref) && SvTYPE(SvRV(args_ref)) == SVt_PVAV) {
        AV *av = (AV *)SvRV(args_ref);
        SSize_t top = av_top_index(av);
        if (top >= 0) {
            size_t n = (size_t)(top + 1);
            argv = (const char **)calloc(n + 1, sizeof(const char *));
            if (argv) {
                for (size_t i = 0; i < n; i++) {
                    SV **e = av_fetch(av, (SSize_t)i, 0);
                    argv[i] = (e && SvOK(*e)) ? SvPV_nolen(*e) : "";
                }
                argv[n] = NULL;
            }
        }
    }
    char err[256] = {0};
    npl_term_t *t = npl_term_spawn((int)rows, (int)cols, cmd, argv,
                                   (cwd && cwd[0]) ? cwd : NULL, err, sizeof(err));
    free(argv);
    if (!t) croak("Term->spawn failed: %s", err[0] ? err : "unknown error");
    RETVAL = wrap_term(aTHX_ t);
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
CODE:
    if (SvROK(self)) {
        IV ptr = SvIV((SV *)SvRV(self));
        if (ptr) {
            npl_term_free(INT2PTR(npl_term_t *, ptr));
            sv_setiv((SV *)SvRV(self), 0);
        }
    }

IV
write(self, data_sv)
    SV *self
    SV *data_sv
CODE:
    STRLEN len = 0;
    const char *d = SvPV(data_sv, len);
    RETVAL = (IV)npl_term_write(unwrap_term(aTHX_ self), d, (size_t)len);
OUTPUT:
    RETVAL

IV
poll(self, timeout_ms = 0)
    SV *self
    IV  timeout_ms
CODE:
    RETVAL = (IV)npl_term_poll(unwrap_term(aTHX_ self), (int)timeout_ms);
OUTPUT:
    RETVAL

void
feed(self, data_sv)
    SV *self
    SV *data_sv
CODE:
    STRLEN len = 0;
    const char *d = SvPV(data_sv, len);
    npl_term_feed(unwrap_term(aTHX_ self), d, (size_t)len);

IV
resize(self, rows, cols)
    SV *self
    IV  rows
    IV  cols
CODE:
    RETVAL = (IV)npl_term_resize(unwrap_term(aTHX_ self), (int)rows, (int)cols);
OUTPUT:
    RETVAL

IV
is_alive(self)
    SV *self
CODE:
    RETVAL = (IV)npl_term_is_alive(unwrap_term(aTHX_ self));
OUTPUT:
    RETVAL

SV *
exit_code(self)
    SV *self
CODE:
    int exited = 0;
    int code = npl_term_exit_code(unwrap_term(aTHX_ self), &exited);
    RETVAL = exited ? newSViv((IV)code) : &PL_sv_undef;
OUTPUT:
    RETVAL

IV
pid(self)
    SV *self
CODE:
    RETVAL = (IV)npl_term_pid(unwrap_term(aTHX_ self));
OUTPUT:
    RETVAL

IV
kill(self, sig = 15)
    SV *self
    IV  sig
CODE:
    RETVAL = (IV)npl_term_kill(unwrap_term(aTHX_ self), (int)sig);
OUTPUT:
    RETVAL

SV *
get_screen(self)
    SV *self
CODE:
    HV *hv = term_screen_to_hv(aTHX_ unwrap_term(aTHX_ self));
    RETVAL = newRV_noinc((SV *)hv);
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::VecSIMD

PROTOTYPES: DISABLE

const char *
simd_backend(...)
CODE:
    RETVAL = npl_vec_simd_backend();
OUTPUT:
    RETVAL

SV *
pack_f32(av_ref)
    SV *av_ref
CODE:
    if (!SvROK(av_ref) || SvTYPE(SvRV(av_ref)) != SVt_PVAV) {
        croak("pack_f32 expects an array reference");
    }
    AV *av = (AV *)SvRV(av_ref);
    size_t dim = (size_t)(av_top_index(av) + 1);
    if (dim == 0) {
        RETVAL = newSVpvs("");
    } else {
        float   *tmp = (float *)malloc(dim * sizeof(float));
        uint8_t *out = (uint8_t *)malloc(dim * sizeof(float));
        if (!tmp || !out) {
            free(tmp);
            free(out);
            croak("Out of memory in pack_f32");
        }
        for (size_t i = 0; i < dim; i++) {
            SV **e = av_fetch(av, (SSize_t)i, 0);
            tmp[i] = (e && SvOK(*e)) ? (float)SvNV(*e) : 0.0f;
        }
        npl_vec_pack_f32(tmp, dim, out);
        RETVAL = newSVpvn((const char *)out, dim * sizeof(float));
        free(tmp);
        free(out);
    }
OUTPUT:
    RETVAL

SV *
unpack_f32(blob_sv)
    SV *blob_sv
CODE:
    STRLEN blen = 0;
    const uint8_t *b = (const uint8_t *)SvPVbyte(blob_sv, blen);
    size_t dim = (size_t)blen / sizeof(float);
    AV *av = newAV();
    if (dim > 0) {
        float *tmp = (float *)malloc(dim * sizeof(float));
        if (!tmp) croak("Out of memory in unpack_f32");
        npl_vec_unpack_f32(b, dim, tmp);
        av_extend(av, (SSize_t)(dim - 1));
        for (size_t i = 0; i < dim; i++) {
            av_push(av, newSVnv((NV)tmp[i]));
        }
        free(tmp);
    }
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

NV
dot_f32(a_sv, b_sv)
    SV *a_sv
    SV *b_sv
CODE:
    STRLEN alen = 0, blen = 0;
    const uint8_t *a = (const uint8_t *)SvPVbyte(a_sv, alen);
    const uint8_t *b = (const uint8_t *)SvPVbyte(b_sv, blen);
    size_t min_bytes = (alen < blen) ? (size_t)alen : (size_t)blen;
    RETVAL = (NV)npl_vec_dot_blob(a, b, min_bytes / sizeof(float));
OUTPUT:
    RETVAL

NV
l2_norm_f32(a_sv)
    SV *a_sv
CODE:
    STRLEN alen = 0;
    const uint8_t *a = (const uint8_t *)SvPVbyte(a_sv, alen);
    RETVAL = (NV)npl_vec_l2_norm_blob(a, (size_t)alen / sizeof(float));
OUTPUT:
    RETVAL

NV
cosine_f32(a_sv, b_sv)
    SV *a_sv
    SV *b_sv
CODE:
    STRLEN alen = 0, blen = 0;
    const uint8_t *a = (const uint8_t *)SvPVbyte(a_sv, alen);
    const uint8_t *b = (const uint8_t *)SvPVbyte(b_sv, blen);
    size_t min_bytes = (alen < blen) ? (size_t)alen : (size_t)blen;
    RETVAL = (NV)npl_vec_cosine_blob(a, b, min_bytes / sizeof(float));
OUTPUT:
    RETVAL

SV *
normalize_f32(a_sv)
    SV *a_sv
CODE:
    STRLEN alen = 0;
    const uint8_t *a = (const uint8_t *)SvPVbyte(a_sv, alen);
    size_t dim = (size_t)alen / sizeof(float);
    if (dim == 0) {
        RETVAL = newSVpvs("");
    } else {
        uint8_t *out = (uint8_t *)malloc(dim * sizeof(float));
        if (!out) croak("Out of memory in normalize_f32");
        npl_vec_normalize_blob(a, out, dim);
        RETVAL = newSVpvn((const char *)out, dim * sizeof(float));
        free(out);
    }
OUTPUT:
    RETVAL

SV *
topk_cosine(query_sv, cands_ref, k = 10)
    SV *query_sv
    SV *cands_ref
    UV  k
CODE:
    if (!SvROK(cands_ref) || SvTYPE(SvRV(cands_ref)) != SVt_PVAV) {
        croak("topk_cosine expects an array reference of candidate blobs");
    }
    STRLEN qlen = 0;
    const uint8_t *q = (const uint8_t *)SvPVbyte(query_sv, qlen);
    size_t dim = (size_t)qlen / sizeof(float);
    AV *cav = (AV *)SvRV(cands_ref);
    size_t n = (size_t)(av_top_index(cav) + 1);

    AV *out = newAV();
    if (dim > 0 && n > 0 && k > 0) {
        const uint8_t **blobs = (const uint8_t **)calloc(n, sizeof(const uint8_t *));
        size_t         *blens = (size_t *)calloc(n, sizeof(size_t));
        SV            **id_svs = (SV **)calloc(n, sizeof(SV *));
        npl_topk_hit_t *hits  = (npl_topk_hit_t *)calloc((size_t)k, sizeof(npl_topk_hit_t));
        if (!blobs || !blens || !id_svs || !hits) {
            free(blobs); free(blens); free(id_svs); free(hits);
            croak("Out of memory in topk_cosine");
        }
        for (size_t i = 0; i < n; i++) {
            SV **e = av_fetch(cav, (SSize_t)i, 0);
            if (!e || !SvOK(*e)) continue;
            if (SvROK(*e) && SvTYPE(SvRV(*e)) == SVt_PVAV) {
                AV *pair = (AV *)SvRV(*e);
                SV **id_e = av_fetch(pair, 0, 0);
                SV **bl_e = av_fetch(pair, 1, 0);
                if (id_e && SvOK(*id_e)) id_svs[i] = *id_e;
                if (bl_e && SvOK(*bl_e)) {
                    STRLEN l = 0;
                    blobs[i] = (const uint8_t *)SvPVbyte(*bl_e, l);
                    blens[i] = (size_t)l;
                }
            } else {
                STRLEN l = 0;
                blobs[i] = (const uint8_t *)SvPVbyte(*e, l);
                blens[i] = (size_t)l;
            }
        }
        size_t got = npl_vec_topk_cosine(q, dim, blobs, blens, n, (size_t)k, hits);
        if (got > 0) av_extend(out, (SSize_t)(got - 1));
        for (size_t i = 0; i < got; i++) {
            HV *hv = newHV();
            (void)hv_stores(hv, "index", newSVuv((UV)hits[i].index));
            (void)hv_stores(hv, "score", newSVnv((NV)hits[i].score));
            if (id_svs[hits[i].index]) {
                (void)hv_stores(hv, "id", newSVsv(id_svs[hits[i].index]));
            }
            av_push(out, newRV_noinc((SV *)hv));
        }
        free(blobs);
        free(blens);
        free(id_svs);
        free(hits);
    }
    RETVAL = newRV_noinc((SV *)out);
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::LlamaBridge

PROTOTYPES: DISABLE

IV
available(...)
CODE:
    RETVAL = (IV)npl_llama_available();
OUTPUT:
    RETVAL

const char *
library_path(...)
CODE:
    RETVAL = npl_llama_library_path();
OUTPUT:
    RETVAL

SV *
status(...)
CODE:
    npl_llama_status_t st;
    npl_llama_status(&st);
    HV *hv = newHV();
    (void)hv_stores(hv, "available",    newSViv((IV)st.available));
    (void)hv_stores(hv, "model_loaded", newSViv((IV)st.model_loaded));
    (void)hv_stores(hv, "n_embd",       newSViv((IV)st.n_embd));
    (void)hv_stores(hv, "library_path", newSVpv(st.library_path, 0));
    (void)hv_stores(hv, "model_path",   newSVpv(st.model_path, 0));
    (void)hv_stores(hv, "error",        newSVpv(st.last_error, 0));
    RETVAL = newRV_noinc((SV *)hv);
OUTPUT:
    RETVAL

SV *
load_model(gguf_path, opts_sv = &PL_sv_undef)
    const char *gguf_path
    SV         *opts_sv
CODE:
    int n_gpu_layers = -1;
    int n_ctx = 2048;
    int embeddings = 1;
    if (opts_sv && SvROK(opts_sv) && SvTYPE(SvRV(opts_sv)) == SVt_PVHV) {
        HV *hv = (HV *)SvRV(opts_sv);
        SV **v;
        if ((v = hv_fetchs(hv, "n_gpu_layers", 0)) && SvOK(*v)) n_gpu_layers = (int)SvIV(*v);
        if ((v = hv_fetchs(hv, "n_ctx", 0))        && SvOK(*v)) n_ctx = (int)SvIV(*v);
        if ((v = hv_fetchs(hv, "embeddings", 0))   && SvOK(*v)) embeddings = SvTRUE(*v) ? 1 : 0;
    }
    char err[256] = {0};
    int ok = npl_llama_load_model(gguf_path, n_gpu_layers, n_ctx, embeddings, err, sizeof(err));
    npl_llama_status_t st;
    npl_llama_status(&st);
    HV *res = newHV();
    (void)hv_stores(res, "ok",         newSViv((IV)ok));
    (void)hv_stores(res, "error",      newSVpv(ok ? "" : err, 0));
    (void)hv_stores(res, "n_embd",     newSViv((IV)st.n_embd));
    (void)hv_stores(res, "model_path", newSVpv(st.model_path, 0));
    RETVAL = newRV_noinc((SV *)res);
OUTPUT:
    RETVAL

SV *
embed(text_sv)
    SV *text_sv
CODE:
    STRLEN len = 0;
    const char *txt = SvPV(text_sv, len);
    float *vec = NULL;
    size_t dim = 0;
    char err[256] = {0};
    int ok = npl_llama_embed(txt, (size_t)len, &vec, &dim, err, sizeof(err));
    HV *res = newHV();
    (void)hv_stores(res, "ok",    newSViv((IV)ok));
    (void)hv_stores(res, "error", newSVpv(ok ? "" : err, 0));
    (void)hv_stores(res, "dim",   newSVuv((UV)dim));
    if (ok && vec && dim > 0) {
        AV *av = newAV();
        av_extend(av, (SSize_t)(dim - 1));
        for (size_t i = 0; i < dim; i++) av_push(av, newSVnv((NV)vec[i]));
        (void)hv_stores(res, "vector", newRV_noinc((SV *)av));
        uint8_t *blob = (uint8_t *)malloc(dim * sizeof(float));
        if (blob) {
            npl_vec_pack_f32(vec, dim, blob);
            (void)hv_stores(res, "blob", newSVpvn((const char *)blob, dim * sizeof(float)));
            free(blob);
        }
    }
    free(vec);
    RETVAL = newRV_noinc((SV *)res);
OUTPUT:
    RETVAL

SV *
complete(prompt_sv, opts_sv = &PL_sv_undef)
    SV *prompt_sv
    SV *opts_sv
CODE:
    STRLEN len = 0;
    const char *prompt = SvPV(prompt_sv, len);
    int max_tokens = 128;
    float temperature = 0.0f;
    if (opts_sv && SvROK(opts_sv) && SvTYPE(SvRV(opts_sv)) == SVt_PVHV) {
        HV *hv = (HV *)SvRV(opts_sv);
        SV **v;
        if ((v = hv_fetchs(hv, "max_tokens", 0))  && SvOK(*v)) max_tokens = (int)SvIV(*v);
        if ((v = hv_fetchs(hv, "temperature", 0)) && SvOK(*v)) temperature = (float)SvNV(*v);
    }
    char *text = NULL;
    size_t ntok = 0;
    char err[256] = {0};
    int ok = npl_llama_complete(prompt, (size_t)len, max_tokens, temperature,
                                &text, &ntok, err, sizeof(err));
    HV *res = newHV();
    (void)hv_stores(res, "ok",     newSViv((IV)ok));
    (void)hv_stores(res, "error",  newSVpv(ok ? "" : err, 0));
    (void)hv_stores(res, "text",   newSVpv(text ? text : "", 0));
    (void)hv_stores(res, "tokens", newSVuv((UV)ntok));
    free(text);
    RETVAL = newRV_noinc((SV *)res);
OUTPUT:
    RETVAL

IV
unload(...)
CODE:
    npl_llama_unload();
    RETVAL = 1;
OUTPUT:
    RETVAL


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::Msgpack

PROTOTYPES: DISABLE

SV *
encode(sv)
    SV *sv
CODE:
    npl_mp_buf_t buf;
    npl_mp_buf_init(&buf);
    if (!sv_to_msgpack(aTHX_ sv, &buf, 0)) {
        npl_mp_buf_free(&buf);
        croak("NeoPerl::Core::Msgpack::encode: unsupported value or nesting depth exceeded");
    }
    RETVAL = newSVpvn(buf.data ? (const char *)buf.data : "", (STRLEN)buf.len);
    npl_mp_buf_free(&buf);
OUTPUT:
    RETVAL

SV *
decode(bytes_sv)
    SV *bytes_sv
CODE:
    STRLEN len = 0;
    const uint8_t *ptr = (const uint8_t *)SvPVbyte(bytes_sv, len);
    size_t consumed = 0;
    npl_mp_val_t *val = NULL;
    npl_mp_status_t st = npl_mp_decode_one(ptr, (size_t)len, &consumed, &val);
    if (st == NPL_MP_INCOMPLETE) {
        croak("NeoPerl::Core::Msgpack::decode: incomplete MessagePack frame");
    }
    if (st != NPL_MP_OK) {
        croak("NeoPerl::Core::Msgpack::decode: invalid MessagePack data (err=%d)", (int)st);
    }
    RETVAL = msgpack_to_sv(aTHX_ val);
    npl_mp_val_free(val);
OUTPUT:
    RETVAL

void
decode_stream(buf_sv)
    SV *buf_sv
PPCODE:
    SV *target = buf_sv;
    int is_ref = 0;
    if (SvROK(buf_sv) && !SvOBJECT(buf_sv) && SvTYPE(SvRV(buf_sv)) < SVt_PVAV) {
        target = SvRV(buf_sv);
        is_ref = 1;
    }
    SvGETMAGIC(target);
    STRLEN len = 0;
    const uint8_t *ptr = SvOK(target) ? (const uint8_t *)SvPVbyte(target, len) : (const uint8_t *)"";

    AV *out_av = newAV();
    SV *out_rv = sv_2mortal(newRV_noinc((SV *)out_av));

    size_t offset = 0;
    while (offset < (size_t)len) {
        size_t consumed = 0;
        npl_mp_val_t *val = NULL;
        npl_mp_status_t st = npl_mp_decode_one(ptr + offset, (size_t)len - offset, &consumed, &val);
        if (st == NPL_MP_OK) {
            av_push(out_av, msgpack_to_sv(aTHX_ val));
            npl_mp_val_free(val);
            offset += consumed;
        } else if (st == NPL_MP_INCOMPLETE) {
            break;
        } else {
            croak("NeoPerl::Core::Msgpack::decode_stream: invalid MessagePack data at byte %zu (err=%d)",
                  offset, (int)st);
        }
    }

    size_t rem_len = (size_t)len - offset;
    SV *rem_sv = newSVpvn((const char *)(ptr + offset), (STRLEN)rem_len);
    if (is_ref && !SvREADONLY(target)) {
        sv_setpvn(target, SvPVX(rem_sv), (STRLEN)rem_len);
    }

    EXTEND(SP, 2);
    PUSHs(out_rv);
    PUSHs(sv_2mortal(rem_sv));


MODULE = NeoPerl::Core  PACKAGE = NeoPerl::Core::VimEngine

PROTOTYPES: DISABLE

SV *
new(klass, core_buf_sv, opts_sv = &PL_sv_undef)
    const char *klass
    SV         *core_buf_sv
    SV         *opts_sv
CODE:
    (void)klass;
    npl_buf_t *b = unwrap_buf(aTHX_ core_buf_sv);
    npl_vim_t *vim = npl_vim_new(b);
    if (!vim) croak("Failed to allocate NeoPerl::Core::VimEngine");
    npl_vim_xs_t *w = (npl_vim_xs_t *)calloc(1, sizeof(npl_vim_xs_t));
    if (!w) {
        npl_vim_free(vim);
        croak("Out of memory allocating NeoPerl::Core::VimEngine wrapper");
    }
    w->vim = vim;
    w->buf_ref = newSVsv(core_buf_sv);
    apply_vim_opts_hv(aTHX_ vim, opts_sv);
    RETVAL = wrap_vim(aTHX_ w);
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
CODE:
    if (SvROK(self)) {
        IV ptr = SvIV((SV *)SvRV(self));
        if (ptr) {
            npl_vim_xs_t *w = INT2PTR(npl_vim_xs_t *, ptr);
            npl_vim_free(w->vim);
            if (w->buf_ref) SvREFCNT_dec(w->buf_ref);
            free(w);
            sv_setiv((SV *)SvRV(self), 0);
        }
    }

UV
feed_keys(self, keys_sv)
    SV *self
    SV *keys_sv
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    STRLEN len = 0;
    const char *s = SvPV(keys_sv, len);
    RETVAL = (UV)npl_vim_feed_keys(w->vim, s, (size_t)len);
OUTPUT:
    RETVAL

const char *
mode(self)
    SV *self
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    RETVAL = npl_vim_mode_name(npl_vim_mode(w->vim));
OUTPUT:
    RETVAL

void
cursor(self)
    SV *self
PPCODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    size_t l = 0, c = 0;
    npl_vim_cursor(w->vim, &l, &c);
    if (GIMME_V == G_ARRAY) {
        EXTEND(SP, 2);
        PUSHs(sv_2mortal(newSVuv((UV)l)));
        PUSHs(sv_2mortal(newSVuv((UV)c)));
    } else {
        AV *av = newAV();
        av_push(av, newSVuv((UV)l));
        av_push(av, newSVuv((UV)c));
        EXTEND(SP, 1);
        PUSHs(sv_2mortal(newRV_noinc((SV *)av)));
    }

void
set_cursor(self, line, col)
    SV *self
    IV  line
    IV  col
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    if (line < 0) line = 0;
    if (col  < 0) col  = 0;
    npl_vim_set_cursor(w->vim, (size_t)line, (size_t)col);

void
set_buffer(self, core_buf_sv)
    SV *self
    SV *core_buf_sv
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    npl_buf_t *b = unwrap_buf(aTHX_ core_buf_sv);
    SV *nref = newSVsv(core_buf_sv);
    npl_vim_set_buffer(w->vim, b);
    if (w->buf_ref) SvREFCNT_dec(w->buf_ref);
    w->buf_ref = nref;

void
set_options(self, opts_sv)
    SV *self
    SV *opts_sv
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    apply_vim_opts_hv(aTHX_ w->vim, opts_sv);

SV *
get_register(self, name_sv = &PL_sv_undef)
    SV *self
    SV *name_sv
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    char rname = '"';
    if (name_sv && SvOK(name_sv)) {
        STRLEN nl = 0;
        const char *ns = SvPV(name_sv, nl);
        if (nl > 0) rname = ns[0];
    }
    size_t rlen = 0;
    npl_reg_type_t rtype = NPL_REG_CHAR;
    const char *rtxt = npl_vim_get_register(w->vim, rname, &rlen, &rtype);
    HV *hv = newHV();
    (void)hv_stores(hv, "text", newSVpvn(rtxt ? rtxt : "", (STRLEN)rlen));
    (void)hv_stores(hv, "type", newSVpv(npl_reg_type_name(rtype), 0));
    RETVAL = newRV_noinc((SV *)hv);
OUTPUT:
    RETVAL

IV
set_register(self, name_sv, text_sv, type_sv = &PL_sv_undef)
    SV *self
    SV *name_sv
    SV *text_sv
    SV *type_sv
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    char rname = '"';
    if (name_sv && SvOK(name_sv)) {
        STRLEN nl = 0;
        const char *ns = SvPV(name_sv, nl);
        if (nl > 0) rname = ns[0];
    }
    STRLEN tlen = 0;
    const char *tstr = SvOK(text_sv) ? SvPV(text_sv, tlen) : "";
    npl_reg_type_t rt = NPL_REG_CHAR;
    if (type_sv && SvOK(type_sv)) {
        const char *ts = SvPV_nolen(type_sv);
        if (strcmp(ts, "line") == 0) rt = NPL_REG_LINE;
        else if (strcmp(ts, "block") == 0) rt = NPL_REG_BLOCK;
    }
    RETVAL = (IV)npl_vim_set_register(w->vim, rname, tstr, (size_t)tlen, rt);
OUTPUT:
    RETVAL

IV
set_mark(self, name_sv, line, col)
    SV *self
    SV *name_sv
    IV  line
    IV  col
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    STRLEN nl = 0;
    const char *ns = SvPV(name_sv, nl);
    if (line < 0) line = 0;
    if (col  < 0) col  = 0;
    RETVAL = (nl > 0) ? (IV)npl_vim_set_mark(w->vim, ns[0], (size_t)line, (size_t)col) : 0;
OUTPUT:
    RETVAL

SV *
get_mark(self, name_sv)
    SV *self
    SV *name_sv
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    STRLEN nl = 0;
    const char *ns = SvPV(name_sv, nl);
    size_t ml = 0, mc = 0;
    if (nl > 0 && npl_vim_get_mark(w->vim, ns[0], &ml, &mc)) {
        HV *hv = newHV();
        (void)hv_stores(hv, "line", newSVuv((UV)ml));
        (void)hv_stores(hv, "col",  newSVuv((UV)mc));
        RETVAL = newRV_noinc((SV *)hv);
    } else {
        RETVAL = &PL_sv_undef;
    }
OUTPUT:
    RETVAL

SV *
visual_range(self)
    SV *self
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    npl_vim_visual_range_t vr;
    (void)npl_vim_visual_range(w->vim, &vr);
    RETVAL = visual_range_to_sv(aTHX_ &vr);
OUTPUT:
    RETVAL

SV *
state_info(self)
    SV *self
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    npl_vim_state_info_t st;
    npl_vim_state_info(w->vim, &st);
    HV *hv = newHV();
    (void)hv_stores(hv, "mode",           newSVpv(npl_vim_mode_name(st.mode), 0));
    (void)hv_stores(hv, "line",           newSVuv((UV)st.line));
    (void)hv_stores(hv, "col",            newSVuv((UV)st.col));
    (void)hv_stores(hv, "curswant",       newSVuv((UV)st.curswant));
    (void)hv_stores(hv, "count1",         newSViv((IV)st.count1));
    (void)hv_stores(hv, "count2",         newSViv((IV)st.count2));
    (void)hv_stores(hv, "operator",       newSVpv(st.op, 0));
    (void)hv_stores(hv, "reg",            st.reg ? newSVpvn(&st.reg, 1) : newSV(0));
    (void)hv_stores(hv, "expect_reg",     newSViv((IV)st.expect_reg));
    (void)hv_stores(hv, "pending_prefix", st.pending_prefix ? newSVpvn(&st.pending_prefix, 1) : newSVpvs(""));
    (void)hv_stores(hv, "recording",      st.recording_reg ? newSVpvn(&st.recording_reg, 1) : newSV(0));
    (void)hv_stores(hv, "shiftwidth",     newSViv((IV)st.shiftwidth));
    (void)hv_stores(hv, "tabstop",        newSViv((IV)st.tabstop));
    (void)hv_stores(hv, "expandtab",      newSViv((IV)st.expandtab));
    (void)hv_stores(hv, "win_height",     newSViv((IV)st.win_height));
    (void)hv_stores(hv, "scroll_top",     newSVuv((UV)st.scroll_top));
    (void)hv_stores(hv, "undo_seq",       newSVuv((UV)st.undo_seq));
    (void)hv_stores(hv, "can_undo",       newSViv((IV)st.can_undo));
    (void)hv_stores(hv, "can_redo",       newSViv((IV)st.can_redo));
    (void)hv_stores(hv, "visual",         visual_range_to_sv(aTHX_ &st.visual));
    (void)hv_stores(hv, "last_visual",    visual_range_to_sv(aTHX_ &st.last_visual));
    RETVAL = newRV_noinc((SV *)hv);
OUTPUT:
    RETVAL

void
reset(self)
    SV *self
CODE:
    npl_vim_xs_t *w = unwrap_vim(aTHX_ self);
    npl_vim_reset(w->vim);

