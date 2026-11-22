#!/usr/bin/env bash
# install.sh - Self-contained 2-stage PGO source installer for NeoPerl::MT
# Author: stratum42
#
# Supports macOS (arm64, amd64) and Linux (amd64, arm64, ppc64le POWER8/9/10).
# Portable bash 3.2+ and BSD/GNU userland compatible.

set -euo pipefail

INSTALLER_VERSION="0.01"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

PREFIX="${HOME}/.local/neoperl"
SOURCE_DIR=""
REPO_BASE="${NEOPERL_REPO_BASE:-https://github.com/stratum42}"
COMPONENTS="all"
USE_EXISTING_PERL=""
TARGET_OS_OVERRIDE=""
TARGET_ARCH_OVERRIDE=""
POWER_CPU_REQ=""
ENABLE_PGO=1
JOBS=""
PATH_MODE=""
WITH_CPAN_TOOLS="auto"
WITH_FONTS="auto"
SETUP_LOCAL_AI="auto"
INSTALL_AGY="auto"
SETUP_DB2="auto"
INSTALL_APP="auto"
APP_DIR=""
ASSUME_YES=0
DRY_RUN=0
UNINSTALL=0

CC_OVERRIDDEN=0
if [ -n "${CC:-}" ]; then
    CC_OVERRIDDEN=1
fi

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Build and install NeoPerl::MT and its optional multi-threaded Perl/XS stack
into a self-contained prefix with two-stage Profile-Guided Optimization (PGO).

Core Options:
  --prefix=DIR                Installation prefix (default: $HOME/.local/neoperl)
  --source-dir=DIR            Directory containing sibling git checkouts (auto-detected
                              from parent directory, or cloned from --repo-base)
  --repo-base=URL             Git base URL for missing repositories
                              (default: $NEOPERL_REPO_BASE or https://github.com/stratum42)
  --components=LIST           Comma-separated subset or "all":
                              perl,dbi,sqlite,odbc,mojo,tk,neoperl (default: all)
  --use-existing-perl=PATH    Build XS stack and neoperl-mt against an existing perl
                              or perl5-mt binary instead of compiling perl5-mt
  --no-pgo                    Disable 2-stage PGO and compile directly with -O3
  --pgo                       Enable 2-stage PGO (default)
  -j, --jobs=N                Parallel make jobs (default: detected CPU count)

Target & Architecture Options:
  --target-os=OS              Override target OS (darwin|linux) for --dry-run
  --target-arch=ARCH          Override target arch (arm64|amd64|ppc64le) for --dry-run
  --power-cpu=CPU             IBM POWER target on ppc64le: power8|power9|power10|native
                              (default: detected from /proc/cpuinfo, fallback power8)

PATH, Desktop & Optional Integrations:
  --path-mode=MODE            Where to expose npl/npl-mcp/npl-lsp:
                              local     symlink into ~/.local/bin
                              usr-local symlink into /usr/local/bin
                              shell-rc  add idempotent PATH block to shell rc
                              none      leave PATH unchanged
  --install-app               Install macOS NeoPerl.app (or Linux .desktop entry)
  --no-install-app            Skip macOS .app / Linux .desktop launcher
  --app-dir=DIR               Target dir for NeoPerl.app (default: /Applications)
  --with-cpan-tools           Install PPI, Perl::Critic, Perl::Tidy into $PREFIX/perl5
  --no-cpan-tools             Skip optional CPAN developer tools
  --with-fonts                Ensure IBM Plex Mono and IBM Plex Sans fonts are installed
  --no-fonts                  Skip font installation
  --setup-local-ai            Print/verify local GGUF inference setup on GPU hosts
  --no-setup-local-ai         Skip local AI hints
  --install-agy               Install Antigravity CLI (agy) if absent
  --no-install-agy            Skip agy CLI installation
  --setup-db2                 Provision local IBM Db2 Community container
  --no-setup-db2              Skip local Db2 container setup

Control Flags:
  -y, --yes                   Non-interactive mode (accept safe defaults)
  -n, --dry-run               Print full build/install plan without making changes
  --uninstall                 Remove prefix, managed symlinks, PATH block, and launcher
  -V, --version               Print installer version and exit
  -h, --help                  Show this help message
EOF
}

to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_os() {
    case "$(to_lower "$1")" in
        darwin|macos) printf 'darwin' ;;
        linux)        printf 'linux' ;;
        *)            to_lower "$1" ;;
    esac
}

normalize_arch() {
    case "$(to_lower "$1")" in
        arm64|aarch64)       printf 'arm64' ;;
        x86_64|amd64)        printf 'amd64' ;;
        ppc64le|powerpc64le) printf 'ppc64le' ;;
        *)                   to_lower "$1" ;;
    esac
}

strip_trailing_slash() {
    local p="$1"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

detect_jobs() {
    local n=""
    if command -v nproc >/dev/null 2>&1; then
        n="$(nproc 2>/dev/null || true)"
    elif command -v sysctl >/dev/null 2>&1; then
        n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    elif [ -r /proc/cpuinfo ]; then
        n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
    fi
    case "$n" in
        ''|*[!0-9]*) printf '4' ;;
        0)           printf '1' ;;
        *)           printf '%s' "$n" ;;
    esac
}

is_tty() {
    [ -t 0 ] && [ -t 1 ]
}

prompt_yn() {
    local question="$1" default_ans="$2" reply=""
    if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ] || ! is_tty; then
        [ "$default_ans" = "y" ]
        return
    fi
    if [ "$default_ans" = "y" ]; then
        printf '%s [Y/n] ' "$question"
    else
        printf '%s [y/N] ' "$question"
    fi
    IFS= read -r reply || reply=""
    reply="$(to_lower "$reply")"
    if [ -z "$reply" ]; then
        [ "$default_ans" = "y" ]
        return
    fi
    case "$reply" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

log_step() {
    printf '\n==> %s\n' "$1"
}

log_info() {
    printf '    %s\n' "$1"
}

# Parse command-line flags
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix=*)            PREFIX="${1#*=}" ;;
        --prefix)              shift; PREFIX="${1:?--prefix requires a directory}" ;;
        --source-dir=*)        SOURCE_DIR="${1#*=}" ;;
        --source-dir)          shift; SOURCE_DIR="${1:?--source-dir requires a directory}" ;;
        --repo-base=*)         REPO_BASE="${1#*=}" ;;
        --repo-base)           shift; REPO_BASE="${1:?--repo-base requires a URL}" ;;
        --components=*)        COMPONENTS="${1#*=}" ;;
        --components)          shift; COMPONENTS="${1:?--components requires a value}" ;;
        --use-existing-perl=*) USE_EXISTING_PERL="${1#*=}" ;;
        --use-existing-perl)   shift; USE_EXISTING_PERL="${1:?--use-existing-perl requires a path}" ;;
        --target-os=*)         TARGET_OS_OVERRIDE="${1#*=}" ;;
        --target-os)           shift; TARGET_OS_OVERRIDE="${1:?--target-os requires a value}" ;;
        --target-arch=*)       TARGET_ARCH_OVERRIDE="${1#*=}" ;;
        --target-arch)         shift; TARGET_ARCH_OVERRIDE="${1:?--target-arch requires a value}" ;;
        --power-cpu=*)         POWER_CPU_REQ="${1#*=}" ;;
        --power-cpu)           shift; POWER_CPU_REQ="${1:?--power-cpu requires a value}" ;;
        --pgo)                 ENABLE_PGO=1 ;;
        --no-pgo)              ENABLE_PGO=0 ;;
        --jobs=*)              JOBS="${1#*=}" ;;
        -j|--jobs)             shift; JOBS="${1:?--jobs requires a number}" ;;
        --path-mode=*)         PATH_MODE="$(to_lower "${1#*=}")" ;;
        --path-mode)           shift; PATH_MODE="$(to_lower "${1:?--path-mode requires a value}")" ;;
        --with-cpan-tools)     WITH_CPAN_TOOLS="yes" ;;
        --no-cpan-tools)       WITH_CPAN_TOOLS="no" ;;
        --with-fonts)          WITH_FONTS="yes" ;;
        --no-fonts)            WITH_FONTS="no" ;;
        --setup-local-ai)      SETUP_LOCAL_AI="yes" ;;
        --no-setup-local-ai)   SETUP_LOCAL_AI="no" ;;
        --install-agy)         INSTALL_AGY="yes" ;;
        --no-install-agy)      INSTALL_AGY="no" ;;
        --setup-db2)           SETUP_DB2="yes" ;;
        --no-setup-db2)        SETUP_DB2="no" ;;
        --install-app)         INSTALL_APP="yes" ;;
        --no-install-app)      INSTALL_APP="no" ;;
        --app-dir=*)           APP_DIR="${1#*=}" ;;
        --app-dir)             shift; APP_DIR="${1:?--app-dir requires a directory}" ;;
        -y|--yes)              ASSUME_YES=1 ;;
        -n|--dry-run)          DRY_RUN=1 ;;
        --uninstall)           UNINSTALL=1 ;;
        -V|--version)          printf 'neoperl-mt install.sh %s\n' "$INSTALLER_VERSION"; exit 0 ;;
        -h|--help)             usage; exit 0 ;;
        *)
            printf 'error: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

PREFIX="$(strip_trailing_slash "$PREFIX")"
if [ -z "$JOBS" ]; then
    JOBS="$(detect_jobs)"
fi
case "$JOBS" in
    ''|*[!0-9]*|0)
        printf 'error: invalid --jobs value "%s"\n' "$JOBS" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# OS / Architecture / POWER / Compiler / PGO / Accelerator Detection
# ---------------------------------------------------------------------------
HOST_OS="$(normalize_os "$(uname -s)")"
HOST_ARCH="$(normalize_arch "$(uname -m)")"

TARGET_OS="$HOST_OS"
TARGET_ARCH="$HOST_ARCH"
IS_NATIVE_TARGET=1

if [ -n "$TARGET_OS_OVERRIDE" ]; then
    TARGET_OS="$(normalize_os "$TARGET_OS_OVERRIDE")"
    if [ "$TARGET_OS" != "$HOST_OS" ]; then
        IS_NATIVE_TARGET=0
    fi
fi
if [ -n "$TARGET_ARCH_OVERRIDE" ]; then
    TARGET_ARCH="$(normalize_arch "$TARGET_ARCH_OVERRIDE")"
    if [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
        IS_NATIVE_TARGET=0
    fi
fi

case "$TARGET_OS" in
    darwin|linux) ;;
    *)
        printf 'error: unsupported target OS "%s" (supported: darwin, linux)\n' "$TARGET_OS" >&2
        exit 1
        ;;
esac

case "$TARGET_ARCH" in
    arm64|amd64|ppc64le) ;;
    *)
        printf 'error: unsupported target arch "%s" (supported: arm64, amd64, ppc64le)\n' "$TARGET_ARCH" >&2
        exit 1
        ;;
esac

if [ -z "$APP_DIR" ]; then
    if [ "$TARGET_OS" = "darwin" ]; then
        APP_DIR="/Applications"
    else
        APP_DIR="${HOME}/.local/share/applications"
    fi
fi
APP_DIR="$(strip_trailing_slash "$APP_DIR")"

# Validate --path-mode if supplied
if [ -n "$PATH_MODE" ]; then
    case "$PATH_MODE" in
        local|usr-local|shell-rc|none) ;;
        *)
            printf 'error: invalid --path-mode "%s" (expected local|usr-local|shell-rc|none)\n' "$PATH_MODE" >&2
            exit 1
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Shell RC management (portable awk + temp file)
# ---------------------------------------------------------------------------
detect_shell_rc() {
    local sh_name=""
    sh_name="$(basename "${SHELL:-sh}")"
    case "$sh_name" in
        zsh)  printf '%s/.zshrc' "$HOME" ;;
        bash)
            if [ "$TARGET_OS" = "darwin" ] && [ -f "${HOME}/.bash_profile" ]; then
                printf '%s/.bash_profile' "$HOME"
            else
                printf '%s/.bashrc' "$HOME"
            fi
            ;;
        *)    printf '%s/.profile' "$HOME" ;;
    esac
}

remove_rc_block() {
    local rc_file="$1"
    [ -f "$rc_file" ] || return 0
    grep -q '# >>> neoperl-mt >>>' "$rc_file" 2>/dev/null || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[dry-run] remove # neoperl-mt PATH block from $rc_file"
        return 0
    fi
    local tmp_rc=""
    tmp_rc="$(mktemp "${TMPDIR:-/tmp}/neoperl-rc.XXXXXX")"
    awk '
        /^# >>> neoperl-mt >>>/ { skip = 1; next }
        /^# <<< neoperl-mt <<</ { skip = 0; next }
        !skip { print }
    ' "$rc_file" > "$tmp_rc"
    mv "$tmp_rc" "$rc_file"
    log_info "Removed # neoperl-mt block from $rc_file"
}

ensure_rc_block() {
    local rc_file="$1" target_dir="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[dry-run] ensure idempotent # neoperl-mt PATH block ($target_dir) in $rc_file"
        return 0
    fi
    if [ -f "$rc_file" ]; then
        remove_rc_block "$rc_file"
    fi
    cat >> "$rc_file" <<EOF

# >>> neoperl-mt >>>
case ":\$PATH:" in
    *:"${target_dir}":*) ;;
    *) export PATH="${target_dir}:\$PATH" ;;
esac
# <<< neoperl-mt <<<
EOF
    log_info "Updated PATH block in $rc_file ($target_dir)"
}

# ---------------------------------------------------------------------------
# Uninstall Mode
# ---------------------------------------------------------------------------
run_uninstall() {
    case "$PREFIX" in
        ""|"/"|"$HOME"|"/usr"|"/usr/local"|"/tmp"|"/var"|"/etc"|"/opt")
            printf 'error: refusing to uninstall unsafe prefix "%s"\n' "$PREFIX" >&2
            exit 1
            ;;
    esac

    log_step "Uninstalling NeoPerl::MT from ${PREFIX}"

    if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && is_tty; then
        if ! prompt_yn "Remove ${PREFIX} and managed NeoPerl links/launchers?" "n"; then
            printf 'Uninstall cancelled.\n'
            exit 0
        fi
    fi

    # Remove symlinks pointing into $PREFIX/bin
    local link_dir="" tool="" link_path="" link_target=""
    for link_dir in "${HOME}/.local/bin" "/usr/local/bin"; do
        for tool in npl npl-mcp npl-lsp npl-db2-ctl; do
            link_path="${link_dir}/${tool}"
            if [ -L "$link_path" ]; then
                link_target="$(readlink "$link_path" 2>/dev/null || true)"
                case "$link_target" in
                    "${PREFIX}/bin/"*)
                        if [ "$DRY_RUN" -eq 1 ]; then
                            log_info "[dry-run] rm -f $link_path"
                        else
                            if [ -w "$link_dir" ]; then
                                rm -f "$link_path"
                            elif command -v sudo >/dev/null 2>&1; then
                                sudo rm -f "$link_path"
                            fi
                            log_info "Removed symlink $link_path"
                        fi
                        ;;
                esac
            fi
        done
    done

    # Remove shell rc PATH blocks
    local rc=""
    for rc in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
        remove_rc_block "$rc"
    done

    # Remove macOS NeoPerl.app bundle (only if matching org.stratum42.neoperl-mt)
    if [ "$TARGET_OS" = "darwin" ]; then
        local app_bundle="${APP_DIR}/NeoPerl.app"
        if [ -d "$app_bundle" ]; then
            if [ -f "${app_bundle}/Contents/Info.plist" ] && grep -q 'org.stratum42.neoperl-mt' "${app_bundle}/Contents/Info.plist"; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    log_info "[dry-run] rm -rf $app_bundle"
                else
                    rm -rf "$app_bundle"
                    log_info "Removed $app_bundle"
                fi
            fi
        fi
    else
        local desktop_file="${HOME}/.local/share/applications/neoperl.desktop"
        if [ -f "$desktop_file" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "[dry-run] rm -f $desktop_file"
            else
                rm -f "$desktop_file"
                log_info "Removed $desktop_file"
            fi
        fi
    fi

    # Remove prefix
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[dry-run] rm -rf $PREFIX"
    elif [ -d "$PREFIX" ]; then
        rm -rf "$PREFIX"
        log_info "Removed $PREFIX"
    else
        log_info "Prefix $PREFIX does not exist (already removed)"
    fi

    printf '\nNeoPerl::MT uninstall complete.\n'
    exit 0
}

if [ "$UNINSTALL" -eq 1 ]; then
    run_uninstall
fi

# ---------------------------------------------------------------------------
# POWER CPU & Page Size Detection (ppc64le)
# ---------------------------------------------------------------------------
POWER_CPU=""
ARCH_CFLAGS=""
PAGE_SIZE_DESC="4096"

if [ "$TARGET_ARCH" = "ppc64le" ]; then
    PAGE_SIZE_DESC="65536"
    if [ -n "$POWER_CPU_REQ" ]; then
        POWER_CPU="$(to_lower "$POWER_CPU_REQ")"
    elif [ "$IS_NATIVE_TARGET" -eq 1 ] && [ -r /proc/cpuinfo ]; then
        if grep -qi 'POWER10' /proc/cpuinfo 2>/dev/null; then
            POWER_CPU="power10"
        elif grep -qi 'POWER9' /proc/cpuinfo 2>/dev/null; then
            POWER_CPU="power9"
        elif grep -qi 'POWER8' /proc/cpuinfo 2>/dev/null; then
            POWER_CPU="power8"
        else
            POWER_CPU="power8"
        fi
    else
        POWER_CPU="power8"
    fi
    case "$POWER_CPU" in
        power8|power9|power10|native) ;;
        *)
            printf 'error: invalid --power-cpu "%s" (expected power8|power9|power10|native)\n' "$POWER_CPU" >&2
            exit 1
            ;;
    esac
    ARCH_CFLAGS="-mcpu=${POWER_CPU} -mvsx"
    if [ "$POWER_CPU" = "power10" ]; then
        ARCH_CFLAGS="${ARCH_CFLAGS} -mmma"
    fi
    export NEOPERL_POWER_CPU="$POWER_CPU"
elif [ "$TARGET_OS" = "darwin" ] && [ "$TARGET_ARCH" = "arm64" ]; then
    PAGE_SIZE_DESC="16384"
fi

# ---------------------------------------------------------------------------
# Compiler & 2-stage PGO Strategy Detection
# ---------------------------------------------------------------------------
CC_BIN=""
COMPILER_FAMILY=""
LLVM_PROFDATA_CMD=""
PGO_ACTIVE="$ENABLE_PGO"
PGO_NOTE=""

find_llvm_profdata() {
    if [ "$TARGET_OS" = "darwin" ]; then
        if [ "$IS_NATIVE_TARGET" -eq 0 ]; then
            printf 'xcrun llvm-profdata'
            return 0
        fi
        if command -v xcrun >/dev/null 2>&1 && xcrun -f llvm-profdata >/dev/null 2>&1; then
            printf 'xcrun llvm-profdata'
            return 0
        fi
    fi
    local cand=""
    for cand in llvm-profdata llvm-profdata-21 llvm-profdata-20 llvm-profdata-19 llvm-profdata-18 llvm-profdata-17 llvm-profdata-16 llvm-profdata-15 llvm-profdata-14; do
        if command -v "$cand" >/dev/null 2>&1; then
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

if [ "$CC_OVERRIDDEN" -eq 1 ]; then
    CC_BIN="$CC"
elif [ "$TARGET_OS" = "darwin" ]; then
    CC_BIN="cc"
else
    if [ "$IS_NATIVE_TARGET" -eq 1 ] && command -v gcc >/dev/null 2>&1; then
        CC_BIN="gcc"
    elif [ "$IS_NATIVE_TARGET" -eq 0 ]; then
        CC_BIN="gcc"
    else
        CC_BIN="cc"
    fi
fi

if [ "$IS_NATIVE_TARGET" -eq 0 ]; then
    case "$(to_lower "$CC_BIN")" in
        *clang*) COMPILER_FAMILY="clang" ;;
        *gcc*)   COMPILER_FAMILY="gcc" ;;
        *)
            if [ "$TARGET_OS" = "darwin" ]; then
                COMPILER_FAMILY="clang"
            else
                COMPILER_FAMILY="gcc"
            fi
            ;;
    esac
else
    case "$(to_lower "$CC_BIN")" in
        *clang*) COMPILER_FAMILY="clang" ;;
        *)
            if command -v "$CC_BIN" >/dev/null 2>&1 && "$CC_BIN" --version 2>&1 | grep -qi 'clang'; then
                COMPILER_FAMILY="clang"
            else
                COMPILER_FAMILY="gcc"
            fi
            ;;
    esac
fi

if [ "$PGO_ACTIVE" -eq 1 ]; then
    if [ "$COMPILER_FAMILY" = "clang" ]; then
        if LLVM_PROFDATA_CMD="$(find_llvm_profdata)"; then
            PGO_NOTE="Clang 2-stage PGO (-fprofile-instr-generate -> ${LLVM_PROFDATA_CMD} merge -> -fprofile-instr-use)"
        else
            PGO_ACTIVE=0
            PGO_NOTE="llvm-profdata unavailable; falling back to -O3"
        fi
    else
        PGO_NOTE="GCC 2-stage PGO (-fprofile-generate -> -fprofile-use -fprofile-correction -Wno-missing-profile)"
    fi
else
    PGO_NOTE="disabled (--no-pgo); compiling with -O3"
fi

# ---------------------------------------------------------------------------
# Hardware-Aware Local AI Accelerator Detection
# ---------------------------------------------------------------------------
ACCELERATOR="none"
LOCAL_AI_SKIP_REASON=""

detect_discrete_rocm() {
    [ -e /dev/kfd ] || return 1
    [ -d /sys/class/kfd/kfd/topology/nodes ] || return 1
    local node="" prop="" simd="" cpus="" bank="" bprop="" htype="" bytes=""
    for node in /sys/class/kfd/kfd/topology/nodes/*; do
        prop="${node}/properties"
        [ -f "$prop" ] || continue
        simd="$(awk '$1 == "simd_count" { print $2; exit }' "$prop" 2>/dev/null || printf '0')"
        cpus="$(awk '$1 == "cpu_cores_count" { print $2; exit }' "$prop" 2>/dev/null || printf '0')"
        [ "${simd:-0}" -gt 0 ] && [ "${cpus:-0}" -eq 0 ] || continue
        if [ -d "${node}/mem_banks" ]; then
            for bank in "${node}"/mem_banks/*; do
                bprop="${bank}/properties"
                [ -f "$bprop" ] || continue
                htype="$(awk '$1 == "heap_type" { print $2; exit }' "$bprop" 2>/dev/null || printf '0')"
                bytes="$(awk '$1 == "size_in_bytes" { print $2; exit }' "$bprop" 2>/dev/null || printf '0')"
                if [ "${htype:-0}" -eq 1 ] && awk -v b="${bytes:-0}" 'BEGIN { exit !(b >= 4294967296) }'; then
                    return 0
                fi
            done
        elif [ "${simd:-0}" -ge 32 ]; then
            return 0
        fi
    done
    return 1
}

if [ "$TARGET_ARCH" = "ppc64le" ]; then
    ACCELERATOR="none"
    LOCAL_AI_SKIP_REASON="POWER (ppc64le) host; local GGUF inference skipped by default"
elif [ "$TARGET_OS" = "darwin" ] && [ "$TARGET_ARCH" = "arm64" ]; then
    ACCELERATOR="metal"
elif [ "$TARGET_OS" = "darwin" ]; then
    ACCELERATOR="none"
    LOCAL_AI_SKIP_REASON="macOS x86_64 CPU-only host; local GGUF inference skipped by default"
elif [ "$TARGET_OS" = "linux" ]; then
    if [ "$IS_NATIVE_TARGET" -eq 1 ]; then
        if [ -e /dev/nvidia0 ] || (command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1); then
            ACCELERATOR="cuda"
        elif detect_discrete_rocm; then
            ACCELERATOR="rocm"
        else
            ACCELERATOR="none"
            LOCAL_AI_SKIP_REASON="no supported CUDA or discrete ROCm GPU detected on CPU-only Linux host"
        fi
    else
        ACCELERATOR="none"
        LOCAL_AI_SKIP_REASON="dry-run Linux target without live GPU probe (live host detects CUDA/ROCm automatically)"
    fi
fi

# ---------------------------------------------------------------------------
# Source Directory & Component Resolution
# ---------------------------------------------------------------------------
if [ -z "$SOURCE_DIR" ]; then
    PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
    if [ -d "${PARENT_DIR}/perl5-mt" ] || [ -d "${PARENT_DIR}/tcl-tk-mt" ] || [ -d "${PARENT_DIR}/dbi-mt" ]; then
        SOURCE_DIR="$PARENT_DIR"
    else
        SOURCE_DIR="${PREFIX}/src"
    fi
fi
SOURCE_DIR="$(strip_trailing_slash "$SOURCE_DIR")"

# Build ordered component list
SELECTED_COMPONENTS=""
if [ "$(to_lower "$COMPONENTS")" = "all" ]; then
    if [ -n "$USE_EXISTING_PERL" ]; then
        SELECTED_COMPONENTS="dbi sqlite odbc mojo tk neoperl"
    else
        SELECTED_COMPONENTS="perl dbi sqlite odbc mojo tk neoperl"
    fi
else
    # Preserve canonical dependency order while honoring requested subset
    REQ_CSV=",$(to_lower "$COMPONENTS"),"
    # Validate tokens
    OLD_IFS="$IFS"
    IFS=','
    for tok in $COMPONENTS; do
        tok="$(to_lower "$tok")"
        case "$tok" in
            perl|dbi|sqlite|odbc|mojo|tk|neoperl) ;;
            *)
                IFS="$OLD_IFS"
                printf 'error: unknown component "%s" (valid: perl,dbi,sqlite,odbc,mojo,tk,neoperl,all)\n' "$tok" >&2
                exit 1
                ;;
        esac
    done
    IFS="$OLD_IFS"
    for comp in perl dbi sqlite odbc mojo tk neoperl; do
        case "$REQ_CSV" in
            *",${comp},"*)
                if [ -n "$SELECTED_COMPONENTS" ]; then
                    SELECTED_COMPONENTS="${SELECTED_COMPONENTS} ${comp}"
                else
                    SELECTED_COMPONENTS="${comp}"
                fi
                ;;
        esac
    done
fi

component_repo_name() {
    case "$1" in
        perl)    printf 'perl5-mt' ;;
        dbi)     printf 'dbi-mt' ;;
        sqlite)  printf 'dbd-sqlite-mt' ;;
        odbc)    printf 'dbd-odbc-mt' ;;
        mojo)    printf 'mojolicious-mt' ;;
        tk)      printf 'tcl-tk-mt' ;;
        neoperl) printf 'neoperl-mt' ;;
    esac
}

resolve_component_src() {
    local comp="$1"
    local repo=""
    repo="$(component_repo_name "$comp")"
    if [ "$comp" = "neoperl" ]; then
        if [ -f "${SOURCE_DIR}/neoperl-mt/Makefile.PL" ] && [ -f "${SOURCE_DIR}/neoperl-mt/Core.xs" ]; then
            printf '%s/neoperl-mt' "$SOURCE_DIR"
            return 0
        fi
        if [ -f "${SCRIPT_DIR}/Makefile.PL" ] && [ -f "${SCRIPT_DIR}/Core.xs" ]; then
            printf '%s' "$SCRIPT_DIR"
            return 0
        fi
    fi
    if [ -d "${SOURCE_DIR}/${repo}" ]; then
        printf '%s/%s' "$SOURCE_DIR" "$repo"
        return 0
    fi
    printf 'CLONE:%s/%s.git->%s/%s' "$REPO_BASE" "$repo" "$SOURCE_DIR" "$repo"
}

ensure_component_src() {
    local comp="$1" resolved="" repo="" dest=""
    resolved="$(resolve_component_src "$comp")"
    case "$resolved" in
        CLONE:*)
            repo="$(component_repo_name "$comp")"
            dest="${SOURCE_DIR}/${repo}"
            mkdir -p "$SOURCE_DIR"
            log_info "Cloning ${REPO_BASE}/${repo}.git into ${dest}"
            git clone --depth 1 "${REPO_BASE}/${repo}.git" "$dest"
            printf '%s' "$dest"
            ;;
        *)
            printf '%s' "$resolved"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Interactive Prompts (only when TTY and not --yes / --dry-run)
# ---------------------------------------------------------------------------
choose_path_mode() {
    if [ -n "$PATH_MODE" ]; then
        return 0
    fi
    if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ] || ! is_tty; then
        PATH_MODE="local"
        return 0
    fi
    printf '\nSelect PATH integration for npl, npl-mcp, and npl-lsp:\n'
    printf '  1) ~/.local/bin symlinks (default)\n'
    printf '  2) /usr/local/bin symlinks (uses sudo if needed)\n'
    printf '  3) Shell rc PATH block (%s)\n' "$(detect_shell_rc)"
    printf '  4) None (leave PATH unchanged)\n'
    printf 'Choice [1-4]: '
    local choice=""
    IFS= read -r choice || choice=""
    case "$choice" in
        2) PATH_MODE="usr-local" ;;
        3) PATH_MODE="shell-rc" ;;
        4) PATH_MODE="none" ;;
        *) PATH_MODE="local" ;;
    esac
}

choose_optional_steps() {
    if [ "$WITH_CPAN_TOOLS" = "auto" ]; then
        if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && is_tty; then
            if prompt_yn "Install optional CPAN tools (PPI, Perl::Critic, Perl::Tidy) into ${PREFIX}/perl5?" "n"; then
                WITH_CPAN_TOOLS="yes"
            else
                WITH_CPAN_TOOLS="no"
            fi
        else
            WITH_CPAN_TOOLS="no"
        fi
    fi

    if [ "$WITH_FONTS" = "auto" ]; then
        if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && is_tty; then
            if prompt_yn "Check/install IBM Plex Mono and IBM Plex Sans fonts?" "n"; then
                WITH_FONTS="yes"
            else
                WITH_FONTS="no"
            fi
        else
            WITH_FONTS="no"
        fi
    fi

    if [ "$INSTALL_AGY" = "auto" ]; then
        if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && is_tty; then
            if command -v agy >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/agy" ]; then
                INSTALL_AGY="no"
            elif prompt_yn "Install Antigravity CLI (agy) from antigravity.google?" "n"; then
                INSTALL_AGY="yes"
            else
                INSTALL_AGY="no"
            fi
        else
            INSTALL_AGY="no"
        fi
    fi

    if [ "$SETUP_DB2" = "auto" ]; then
        if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && is_tty && [ "$TARGET_ARCH" != "ppc64le" ]; then
            if prompt_yn "Provision a local IBM Db2 Community container for semantic memory?" "n"; then
                SETUP_DB2="yes"
            else
                SETUP_DB2="no"
            fi
        else
            SETUP_DB2="no"
        fi
    fi

    if [ "$INSTALL_APP" = "auto" ]; then
        if [ "$TARGET_OS" = "darwin" ] && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && is_tty; then
            if prompt_yn "Install macOS ${APP_DIR}/NeoPerl.app launcher bundle?" "y"; then
                INSTALL_APP="yes"
            else
                INSTALL_APP="no"
            fi
        else
            INSTALL_APP="no"
        fi
    fi
}

choose_path_mode
choose_optional_steps

# ---------------------------------------------------------------------------
# Print Plan Summary (and exit cleanly on --dry-run)
# ---------------------------------------------------------------------------
print_local_ai_summary() {
    if [ "$ACCELERATOR" != "none" ]; then
        printf '  Local AI:        enabled (%s accelerator detected)\n' "$ACCELERATOR"
        if [ "$SETUP_LOCAL_AI" = "yes" ] || [ "$DRY_RUN" -eq 1 ]; then
            if [ "$TARGET_OS" = "darwin" ]; then
                printf '                   Runtime: brew install llama.cpp (libllama + llama-server)\n'
            else
                printf '                   Runtime: build llama.cpp with %s support (llama-server + libllama)\n' "$ACCELERATOR"
            fi
            printf '                   Models:  launch npl and run :ModelPull to fetch GGUF weights\n'
        fi
    else
        printf '  Local AI:        skipped (%s)\n' "$LOCAL_AI_SKIP_REASON"
        printf '                   Remote inference endpoints: NEOPERL_EMBED_URL, NEOPERL_HYMEM_URL,\n'
        printf '                   NEOPERL_VISION_URL, NEOPERL_BONSAI_URL\n'
    fi
}

print_plan() {
    local mode_tag="Install"
    if [ "$DRY_RUN" -eq 1 ]; then
        mode_tag="[dry-run] Install"
    fi
    printf '%s plan for NeoPerl::MT (%s):\n' "$mode_tag" "$INSTALLER_VERSION"
    printf '  Target:          %s/%s (page_size=%s)\n' "$TARGET_OS" "$TARGET_ARCH" "$PAGE_SIZE_DESC"
    if [ "$TARGET_ARCH" = "ppc64le" ]; then
        printf '  IBM POWER:       NEOPERL_POWER_CPU=%s (%s)\n' "$POWER_CPU" "$ARCH_CFLAGS"
    fi
    printf '  Compiler:        %s (family=%s, jobs=%s)\n' "$CC_BIN" "$COMPILER_FAMILY" "$JOBS"
    printf '  PGO:             %s\n' "$PGO_NOTE"
    if [ "$PGO_ACTIVE" -eq 1 ]; then
        if [ "$COMPILER_FAMILY" = "clang" ]; then
            printf '  PGO Stage-1:     -fprofile-instr-generate=<dir>/%%p.profraw\n'
            printf '  PGO Merge:       %s merge -output=<dir>/merged.profdata <dir>/*.profraw\n' "$LLVM_PROFDATA_CMD"
            printf '  PGO Stage-2:     -fprofile-instr-use=<dir>/merged.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date\n'
        else
            printf '  PGO Stage-1:     -fprofile-generate=<dir>\n'
            printf '  PGO Stage-2:     -fprofile-use=<dir> -fprofile-correction -Wno-missing-profile\n'
        fi
    else
        printf '  Optimization:    -O3 %s\n' "$ARCH_CFLAGS"
    fi
    printf '  Prefix:          %s\n' "$PREFIX"
    printf '  Source dir:      %s (repo-base=%s)\n' "$SOURCE_DIR" "$REPO_BASE"
    if [ -n "$USE_EXISTING_PERL" ]; then
        printf '  Perl binary:     %s (--use-existing-perl)\n' "$USE_EXISTING_PERL"
    else
        printf '  Perl binary:     %s/bin/perl (built from perl5-mt, symlink perl5-mt)\n' "$PREFIX"
    fi
    printf '  Components:      %s\n' "$SELECTED_COMPONENTS"
    local c="" src_res=""
    for c in $SELECTED_COMPONENTS; do
        src_res="$(resolve_component_src "$c")"
        printf '    - %-8s     %s\n' "$c" "$src_res"
    done
    printf '  PATH mode:       %s\n' "$PATH_MODE"
    printf '  CPAN tools:      %s\n' "$WITH_CPAN_TOOLS"
    printf '  IBM Plex fonts:  %s\n' "$WITH_FONTS"
    printf '  agy CLI:         %s\n' "$INSTALL_AGY"
    printf '  Db2 container:   %s\n' "$SETUP_DB2"
    if [ "$TARGET_OS" = "darwin" ]; then
        printf '  App launcher:    %s (%s/NeoPerl.app)\n' "$INSTALL_APP" "$APP_DIR"
    else
        printf '  App launcher:    %s (%s/neoperl.desktop)\n' "$INSTALL_APP" "$APP_DIR"
    fi
    print_local_ai_summary
}

print_plan

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$INSTALL_APP" = "yes" ] && [ "$TARGET_OS" = "darwin" ] && [ -x "${SCRIPT_DIR}/scripts/make-macos-app.sh" ]; then
        printf '\n'
        "${SCRIPT_DIR}/scripts/make-macos-app.sh" --prefix="$PREFIX" --app-dir="$APP_DIR" --dry-run
    fi
    if [ "$SETUP_DB2" = "yes" ] && [ -x "${SCRIPT_DIR}/scripts/setup-db2-container.sh" ]; then
        printf '\n'
        "${SCRIPT_DIR}/scripts/setup-db2-container.sh" --prefix="$PREFIX" --target-os="$TARGET_OS" --target-arch="$TARGET_ARCH" --dry-run
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Build Workspace & Cleanup Trap
# ---------------------------------------------------------------------------
TMP_BASE="$(strip_trailing_slash "${TMPDIR:-/tmp}")"
WORK_DIR="$(mktemp -d "${TMP_BASE}/neoperl-install.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "${PREFIX}/bin" "${PREFIX}/lib/perl5" "${PREFIX}/libexec/neoperl" "${PREFIX}/schema"

# ---------------------------------------------------------------------------
# Portable Helper Functions for Builds & PGO
# ---------------------------------------------------------------------------
copy_source_clean() {
    local src="$1" dst="$2" extra_excl="${3:-}"
    mkdir -p "$dst"
    # Both BSD tar (macOS) and GNU tar (Linux) support --exclude
    if [ -n "$extra_excl" ]; then
        (
            cd "$src"
            tar cf - \
                --exclude='.git' \
                --exclude='blib' \
                --exclude='Makefile' \
                --exclude='GNUmakefile' \
                --exclude='MYMETA.json' \
                --exclude='MYMETA.yml' \
                --exclude='pm_to_blib' \
                --exclude='*.o' \
                --exclude='*.obj' \
                --exclude='*.bs' \
                --exclude='*.gcda' \
                --exclude='*.gcno' \
                --exclude='*.profraw' \
                --exclude='*.profdata' \
                --exclude="$extra_excl" \
                .
        ) | (cd "$dst" && tar xf -)
    else
        (
            cd "$src"
            tar cf - \
                --exclude='.git' \
                --exclude='blib' \
                --exclude='Makefile' \
                --exclude='GNUmakefile' \
                --exclude='MYMETA.json' \
                --exclude='MYMETA.yml' \
                --exclude='pm_to_blib' \
                --exclude='*.o' \
                --exclude='*.obj' \
                --exclude='*.bs' \
                --exclude='*.gcda' \
                --exclude='*.gcno' \
                --exclude='*.profraw' \
                --exclude='*.profdata' \
                .
        ) | (cd "$dst" && tar xf -)
    fi
}

extract_make_var() {
    local mkfile="$1" var="$2"
    awk -v key="$var" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
            val = $0
        }
        END { printf "%s", val }
    ' "$mkfile"
}

pgo_stage1_cflags() {
    local pdir="$1"
    if [ "$COMPILER_FAMILY" = "clang" ]; then
        printf -- '-fprofile-instr-generate=%s/%%p.profraw' "$pdir"
    else
        printf -- '-fprofile-generate=%s' "$pdir"
    fi
}

pgo_stage1_ldflags() {
    local pdir="$1"
    if [ "$COMPILER_FAMILY" = "clang" ]; then
        printf -- '-fprofile-instr-generate'
    else
        printf -- '-fprofile-generate=%s' "$pdir"
    fi
}

pgo_merge_profile() {
    local pdir="$1"
    if [ "$COMPILER_FAMILY" = "clang" ]; then
        local count=0 f=""
        for f in "${pdir}"/*.profraw; do
            [ -f "$f" ] || continue
            count=$(( count + 1 ))
        done
        if [ "$count" -eq 0 ]; then
            return 1
        fi
        if [ "$LLVM_PROFDATA_CMD" = "xcrun llvm-profdata" ]; then
            xcrun llvm-profdata merge -output="${pdir}/merged.profdata" "${pdir}"/*.profraw
        else
            "$LLVM_PROFDATA_CMD" merge -output="${pdir}/merged.profdata" "${pdir}"/*.profraw
        fi
        [ -s "${pdir}/merged.profdata" ]
        return $?
    else
        # GCC writes .gcda files directly under $pdir
        if find "$pdir" -name '*.gcda' 2>/dev/null | grep -q '.'; then
            return 0
        fi
        return 1
    fi
}

pgo_stage2_cflags() {
    local pdir="$1"
    if [ "$COMPILER_FAMILY" = "clang" ]; then
        printf -- '-fprofile-instr-use=%s/merged.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date' "$pdir"
    else
        printf -- '-fprofile-use=%s -fprofile-correction -Wno-missing-profile' "$pdir"
    fi
}

# ---------------------------------------------------------------------------
# Perl Binary Setup & Uninstalled Build-Tree Detection
# ---------------------------------------------------------------------------
PERL_BIN=""
PERL_UNINSTALLED_LIB=""
PERL_SRC_DIR=""
PERL_ARCHNAME=""

configure_perl_env() {
    local bin="$1"
    if [ ! -x "$bin" ]; then
        printf 'error: perl binary not executable: %s\n' "$bin" >&2
        exit 1
    fi
    local abs_dir=""
    abs_dir="$(cd "$(dirname "$bin")" && pwd -P)"
    PERL_BIN="${abs_dir}/$(basename "$bin")"
    PERL_UNINSTALLED_LIB=""
    PERL_SRC_DIR=""

    if ! "$PERL_BIN" -MConfig -e 'exit 0' >/dev/null 2>&1; then
        if [ -f "${abs_dir}/perl.h" ] && [ -f "${abs_dir}/lib/Config.pm" ]; then
            PERL_UNINSTALLED_LIB="${abs_dir}/lib"
            PERL_SRC_DIR="$abs_dir"
            log_info "Detected uninstalled Perl source build at ${abs_dir} (using -I${PERL_UNINSTALLED_LIB} and PERL_SRC=${PERL_SRC_DIR})"
        else
            printf 'error: %s cannot load Config.pm\n' "$PERL_BIN" >&2
            exit 1
        fi
    fi

    PERL_ARCHNAME="$(run_perl -MConfig -e 'print $Config{archname}')"

    # Align compiler family with Perl's configured C compiler when CC was not overridden
    if [ "$CC_OVERRIDDEN" -eq 0 ]; then
        local perl_cc=""
        perl_cc="$(run_perl -MConfig -e 'print $Config{cc}')"
        if [ -n "$perl_cc" ] && command -v "$perl_cc" >/dev/null 2>&1; then
            CC_BIN="$perl_cc"
            if "$CC_BIN" --version 2>&1 | grep -qi 'clang'; then
                COMPILER_FAMILY="clang"
                if [ "$PGO_ACTIVE" -eq 1 ] && [ -z "$LLVM_PROFDATA_CMD" ]; then
                    LLVM_PROFDATA_CMD="$(find_llvm_profdata || true)"
                    if [ -z "$LLVM_PROFDATA_CMD" ]; then
                        PGO_ACTIVE=0
                    fi
                fi
            else
                COMPILER_FAMILY="gcc"
            fi
        fi
    fi

    # Prepend prefix lib dirs for subsequent XS module builds
    local prefix_inc="${PREFIX}/lib/perl5/${PERL_ARCHNAME}:${PREFIX}/lib/perl5"
    if [ -n "${PERL5LIB:-}" ]; then
        export PERL5LIB="${prefix_inc}:${PERL5LIB}"
    else
        export PERL5LIB="${prefix_inc}"
    fi
}

run_perl() {
    if [ -n "$PERL_UNINSTALLED_LIB" ]; then
        "$PERL_BIN" "-I${PERL_UNINSTALLED_LIB}" "$@"
    else
        "$PERL_BIN" "$@"
    fi
}

run_makefile_pl() {
    if [ -n "$PERL_SRC_DIR" ]; then
        run_perl Makefile.PL "INSTALL_BASE=${PREFIX}" "PERL_SRC=${PERL_SRC_DIR}" "$@"
    else
        run_perl Makefile.PL "INSTALL_BASE=${PREFIX}" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Component 1: perl5-mt (2-stage PGO)
# ---------------------------------------------------------------------------
build_perl() {
    log_step "Building perl5-mt -> ${PREFIX}"
    local src="" build_dir="${WORK_DIR}/perl5-mt" pgo_dir="${WORK_DIR}/pgo-perl"
    src="$(ensure_component_src perl)"
    copy_source_clean "$src" "$build_dir" "config.sh"
    rm -f "${build_dir}/Policy.sh" "${build_dir}/perl" "${build_dir}/miniperl"

    local opt_flags="-O3"
    if [ -n "$ARCH_CFLAGS" ]; then
        opt_flags="-O3 ${ARCH_CFLAGS}"
    fi

    local pgo_ok=0
    if [ "$PGO_ACTIVE" -eq 1 ]; then
        mkdir -p "$pgo_dir"
        local s1_cf="" s1_lf=""
        s1_cf="$(pgo_stage1_cflags "$pgo_dir")"
        s1_lf="$(pgo_stage1_ldflags "$pgo_dir")"

        log_info "Stage 1/2: building instrumented perl5-mt..."
        (
            cd "$build_dir"
            sh Configure -des \
                -Dprefix="$PREFIX" \
                -Dusethreads \
                -Dusedevel \
                -Uversiononly \
                -Duse64bitall \
                -Dcc="$CC_BIN" \
                -Doptimize="$opt_flags" \
                -Accflags="$s1_cf" \
                -Aldflags="$s1_lf" \
                -Alddlflags="$s1_lf"
            make -j"$JOBS" perl

            log_info "Stage 1/2: running perl5-mt training workload (regex, UTF-8, hash, OO, MT::Pool)..."
            LLVM_PROFILE_FILE="${pgo_dir}/%p.profraw" ./perl -Ilib -e '
                use strict;
                use warnings;
                use utf8;
                # Regex + UTF-8 training
                my $txt = "NeoPerl::MT café 日本語 12345 sub foo { return 42; }\n" x 200;
                my $hits = 0;
                for (1..250) {
                    while ($txt =~ /(\w+)::\w+|\bsub\s+(\w+)|(\d+)/g) { $hits++; }
                    my $c = $txt;
                    $c =~ s/(\d+)/$1 + 1/ge;
                }
                # Hash + sort + pack/unpack training
                my %h;
                for my $i (1..8000) { $h{"key_$i"} = ($i * 2654435761) & 0xffffffff; }
                my @sorted = sort { $h{$b} <=> $h{$a} } keys %h;
                my $packed = pack("N*", @h{@sorted[0..999]});
                my @unpacked = unpack("N*", $packed);
                # OO dispatch training
                { package _PGOObj; sub new { bless { v => $_[1] }, $_[0] } sub inc { $_[0]{v} += $_[1] } }
                my $o = _PGOObj->new(0);
                $o->inc($_) for 1..20000;
                # MT::Pool exercise if built into perl5-mt
                eval {
                    require MT::Pool;
                    my $pool = MT::Pool->new(workers => 2);
                    my @res = $pool->map(sub { my $x = shift; my $s = 0; $s += $_ for 1..$x; $s }, [100, 200, 300, 400]);
                    $pool->shutdown if $pool->can("shutdown");
                };
            '
        )
        if pgo_merge_profile "$pgo_dir"; then
            pgo_ok=1
            log_info "Stage 1/2: profile merged cleanly"
        else
            log_info "Warning: perl5-mt profile data missing; falling back to -O3"
        fi
        (cd "$build_dir" && make realclean >/dev/null 2>&1 || true)
        rm -f "${build_dir}/config.sh" "${build_dir}/Policy.sh" "${build_dir}/Makefile" "${build_dir}/GNUmakefile"
    fi

    local s2_cf=""
    if [ "$pgo_ok" -eq 1 ]; then
        s2_cf="$(pgo_stage2_cflags "$pgo_dir")"
        log_info "Stage 2/2: rebuilding PGO-optimized perl5-mt and installing..."
    else
        log_info "Building perl5-mt with ${opt_flags} and installing..."
    fi

    (
        cd "$build_dir"
        if [ -n "$s2_cf" ]; then
            sh Configure -des \
                -Dprefix="$PREFIX" \
                -Dusethreads \
                -Dusedevel \
                -Uversiononly \
                -Duse64bitall \
                -Dcc="$CC_BIN" \
                -Doptimize="$opt_flags" \
                -Accflags="$s2_cf"
        else
            sh Configure -des \
                -Dprefix="$PREFIX" \
                -Dusethreads \
                -Dusedevel \
                -Uversiononly \
                -Duse64bitall \
                -Dcc="$CC_BIN" \
                -Doptimize="$opt_flags"
        fi
        make -j"$JOBS"
        make install
    )

    # Ensure $PREFIX/bin/perl and $PREFIX/bin/perl5-mt exist
    if [ ! -x "${PREFIX}/bin/perl" ]; then
        local ver_perl=""
        for ver_perl in "${PREFIX}"/bin/perl5.*; do
            if [ -x "$ver_perl" ]; then
                ln -sf "$(basename "$ver_perl")" "${PREFIX}/bin/perl"
                break
            fi
        done
    fi
    ln -sf "perl" "${PREFIX}/bin/perl5-mt"
    configure_perl_env "${PREFIX}/bin/perl"
    log_info "Installed ${PREFIX}/bin/perl and ${PREFIX}/bin/perl5-mt"
}

# ---------------------------------------------------------------------------
# Generic Standard ExtUtils::MakeMaker 2-stage PGO Helper (dbi, sqlite, odbc, mojo/xs)
# ---------------------------------------------------------------------------
build_eumm_xs_pgo() {
    local label="$1" build_dir="$2" pgo_dir="$3" train_cmd="$4"
    local opt_base="-O3"
    if [ -n "$ARCH_CFLAGS" ]; then
        opt_base="-O3 ${ARCH_CFLAGS}"
    fi

    local pgo_ok=0
    (
        cd "$build_dir"
        run_makefile_pl
    )

    local base_lddl=""
    base_lddl="$(extract_make_var "${build_dir}/Makefile" "LDDLFLAGS")"

    if [ "$PGO_ACTIVE" -eq 1 ]; then
        mkdir -p "$pgo_dir"
        local s1_cf="" s1_lf=""
        s1_cf="$(pgo_stage1_cflags "$pgo_dir")"
        s1_lf="$(pgo_stage1_ldflags "$pgo_dir")"

        log_info "Stage 1/2 (${label}): building instrumented XS..."
        (
            cd "$build_dir"
            make -j"$JOBS" OPTIMIZE="${opt_base} ${s1_cf}" LDDLFLAGS="${base_lddl} ${s1_lf}"
            log_info "Stage 1/2 (${label}): running training workload..."
            LLVM_PROFILE_FILE="${pgo_dir}/%p.profraw" eval "$train_cmd" >/dev/null 2>&1 || true
        )
        if pgo_merge_profile "$pgo_dir"; then
            pgo_ok=1
            log_info "Stage 1/2 (${label}): profile merged cleanly"
        else
            log_info "Note (${label}): no profile data captured; building with -O3"
        fi
        (
            cd "$build_dir"
            make realclean >/dev/null 2>&1 || make clean >/dev/null 2>&1 || true
            run_makefile_pl
        )
    fi

    local s2_opt="$opt_base"
    if [ "$pgo_ok" -eq 1 ]; then
        s2_opt="${opt_base} $(pgo_stage2_cflags "$pgo_dir")"
        log_info "Stage 2/2 (${label}): rebuilding PGO-optimized XS and installing..."
    else
        log_info "Building ${label} with ${opt_base} and installing..."
    fi

    (
        cd "$build_dir"
        make -j"$JOBS" OPTIMIZE="$s2_opt"
        make install
    )
}

# ---------------------------------------------------------------------------
# Component 2: dbi-mt
# ---------------------------------------------------------------------------
build_dbi() {
    log_step "Building dbi-mt -> ${PREFIX}"
    local src="" build_dir="${WORK_DIR}/dbi-mt"
    src="$(ensure_component_src dbi)"
    copy_source_clean "$src" "$build_dir"
    build_eumm_xs_pgo "dbi-mt" "$build_dir" "${WORK_DIR}/pgo-dbi" \
        'run_perl -Mblib t/01basics.t && run_perl -Mblib t/02dbidrv.t'
}

# ---------------------------------------------------------------------------
# Component 3: dbd-sqlite-mt
# ---------------------------------------------------------------------------
build_sqlite() {
    log_step "Building dbd-sqlite-mt -> ${PREFIX}"
    local src="" build_dir="${WORK_DIR}/dbd-sqlite-mt"
    src="$(ensure_component_src sqlite)"
    copy_source_clean "$src" "$build_dir"
    build_eumm_xs_pgo "dbd-sqlite-mt" "$build_dir" "${WORK_DIR}/pgo-sqlite" \
        'run_perl -Mblib -MDBI -e '\''my $dbh=DBI->connect("dbi:SQLite:dbname=:memory:","","",{RaiseError=>1}); $dbh->do("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)"); my $ins=$dbh->prepare("INSERT INTO t(v) VALUES (?)"); $ins->execute("row_$_") for 1..2000; my $sel=$dbh->prepare("SELECT id,v FROM t WHERE id > ?"); $sel->execute(500); while($sel->fetchrow_arrayref){} $dbh->disconnect;'\'''
}

# ---------------------------------------------------------------------------
# Component 4: dbd-odbc-mt (auto-skipped if unixODBC / IBM CLI headers absent)
# ---------------------------------------------------------------------------
detect_odbc_headers() {
    local d=""
    for d in \
        "${ODBCHOME:-}/include" \
        "${DB2DIR:-}/include" \
        "${IBM_DB_HOME:-}/include" \
        "/opt/homebrew/opt/unixodbc/include" \
        "/opt/homebrew/include" \
        "/usr/local/include" \
        "/usr/include"
    do
        [ -n "$d" ] || continue
        if [ -f "${d}/sql.h" ] || [ -f "${d}/sqlcli1.h" ]; then
            return 0
        fi
    done
    if command -v odbc_config >/dev/null 2>&1; then
        d="$(odbc_config --include-prefix 2>/dev/null || true)"
        if [ -n "$d" ] && [ -f "${d}/sql.h" ]; then
            return 0
        fi
    fi
    return 1
}

build_odbc() {
    log_step "Building dbd-odbc-mt -> ${PREFIX}"
    if ! detect_odbc_headers; then
        log_info "unixODBC / IBM CLI headers not detected; skipping dbd-odbc-mt"
        return 0
    fi
    local src="" build_dir="${WORK_DIR}/dbd-odbc-mt"
    src="$(ensure_component_src odbc)"
    copy_source_clean "$src" "$build_dir"
    build_eumm_xs_pgo "dbd-odbc-mt" "$build_dir" "${WORK_DIR}/pgo-odbc" \
        'run_perl -Mblib -e "require DBD::ODBC;"'
}

# ---------------------------------------------------------------------------
# Component 5: mojolicious-mt (pure-Perl lib/ + 2-stage PGO xs/ Mojo::MT::Accel)
# ---------------------------------------------------------------------------
build_mojo() {
    log_step "Building mojolicious-mt -> ${PREFIX}"
    local src="" build_dir="${WORK_DIR}/mojolicious-mt"
    src="$(ensure_component_src mojo)"
    copy_source_clean "$src" "$build_dir"

    log_info "Installing pure-Perl Mojolicious modules..."
    (
        cd "$build_dir"
        run_makefile_pl
        make -j"$JOBS"
        make install
    )

    if [ -f "${build_dir}/xs/Makefile.PL" ]; then
        build_eumm_xs_pgo "mojolicious-mt/xs" "${build_dir}/xs" "${WORK_DIR}/pgo-mojo-xs" \
            'run_perl -Mblib -MMojo::MT::Accel -e '\''for (1..2000) { my $s = Mojo::MT::Accel::xml_escape("<tag a=\"1\">&test</tag>"); }'\'''
    fi
}

# ---------------------------------------------------------------------------
# Component 6: tcl-tk-mt (2-stage PGO C11 + Metal/Vulkan+Software)
# ---------------------------------------------------------------------------
build_tk() {
    log_step "Building tcl-tk-mt -> ${PREFIX}"
    local src="" build_dir="${WORK_DIR}/tcl-tk-mt" pgo_dir="${WORK_DIR}/pgo-tk"
    src="$(ensure_component_src tk)"
    copy_source_clean "$src" "$build_dir"

    local opt_base="-O3"
    if [ -n "$ARCH_CFLAGS" ]; then
        opt_base="-O3 ${ARCH_CFLAGS}"
    fi

    if ! (cd "$build_dir" && run_makefile_pl); then
        log_info "Note: tcl-tk-mt configuration failed (Tcl/Tk development headers may be missing); skipping"
        return 0
    fi

    local base_cccdl="" base_lddl=""
    base_cccdl="$(extract_make_var "${build_dir}/Makefile" "TKMT_CCCDLFLAGS")"
    base_lddl="$(extract_make_var "${build_dir}/Makefile" "TKMT_LDDLFLAGS")"

    local pgo_ok=0
    if [ "$PGO_ACTIVE" -eq 1 ]; then
        mkdir -p "$pgo_dir"
        local s1_cf="" s1_lf=""
        s1_cf="$(pgo_stage1_cflags "$pgo_dir")"
        s1_lf="$(pgo_stage1_ldflags "$pgo_dir")"

        log_info "Stage 1/2 (tcl-tk-mt): building instrumented C11/XS..."
        (
            cd "$build_dir"
            make -j"$JOBS" \
                TKMT_OPTIMIZE="$opt_base" \
                TKMT_CCCDLFLAGS="${base_cccdl} ${s1_cf}" \
                TKMT_LDDLFLAGS="${base_lddl} ${s1_lf}"
            log_info "Stage 1/2 (tcl-tk-mt): running headless canvas training tests..."
            local tf=""
            for tf in t/01*.t t/02*.t t/03*.t; do
                [ -f "$tf" ] || continue
                LLVM_PROFILE_FILE="${pgo_dir}/%p.profraw" TCL_TK_MT_HEADLESS=1 run_perl -Mblib "$tf" >/dev/null 2>&1 || true
            done
        )
        if pgo_merge_profile "$pgo_dir"; then
            pgo_ok=1
            log_info "Stage 1/2 (tcl-tk-mt): profile merged cleanly"
        else
            log_info "Note (tcl-tk-mt): no profile data captured; building with -O3"
        fi
        (
            cd "$build_dir"
            make realclean >/dev/null 2>&1 || make clean >/dev/null 2>&1 || true
            run_makefile_pl
        )
    fi

    local s2_cccdl="$base_cccdl"
    if [ "$pgo_ok" -eq 1 ]; then
        s2_cccdl="${base_cccdl} $(pgo_stage2_cflags "$pgo_dir")"
        log_info "Stage 2/2 (tcl-tk-mt): rebuilding PGO-optimized C11/XS and installing..."
    else
        log_info "Building tcl-tk-mt with ${opt_base} and installing..."
    fi

    (
        cd "$build_dir"
        make -j"$JOBS" \
            TKMT_OPTIMIZE="$opt_base" \
            TKMT_CCCDLFLAGS="$s2_cccdl" \
            TKMT_LDDLFLAGS="$base_lddl"
        make install
    )
}

# ---------------------------------------------------------------------------
# Component 7: neoperl-mt (2-stage PGO C11 + Core.xs + self-contained wrappers)
# ---------------------------------------------------------------------------
write_wrapper() {
    local tool="$1"
    local wrapper_path="${PREFIX}/bin/${tool}"
    local safe_prefix="" safe_perl="" safe_arch="" safe_uninst=""
    safe_prefix="$(printf '%s' "$PREFIX" | sed "s/'/'\\\\''/g")"
    safe_perl="$(printf '%s' "$PERL_BIN" | sed "s/'/'\\\\''/g")"
    safe_arch="$(printf '%s' "$PERL_ARCHNAME" | sed "s/'/'\\\\''/g")"
    safe_uninst="$(printf '%s' "$PERL_UNINSTALLED_LIB" | sed "s/'/'\\\\''/g")"

    # ExtUtils::MakeMaker installs EXE_FILES mode 0555; unlink before writing wrapper
    rm -f "$wrapper_path"

    if [ -n "$PERL_UNINSTALLED_LIB" ]; then
        cat > "$wrapper_path" <<EOF
#!/bin/sh
# Self-contained launcher wrapper for ${tool} (NeoPerl::MT)
# Author: stratum42

set -e

NEOPERL_PREFIX='${safe_prefix}'
NEOPERL_PERL='${safe_perl}'
NEOPERL_ARCH='${safe_arch}'
NEOPERL_PERL_LIB='${safe_uninst}'

_p5lib=""
for _d in \
    "\${NEOPERL_PREFIX}/lib/perl5/\${NEOPERL_ARCH}" \
    "\${NEOPERL_PREFIX}/lib/perl5" \
    "\${NEOPERL_PREFIX}/perl5/lib/perl5/\${NEOPERL_ARCH}" \
    "\${NEOPERL_PREFIX}/perl5/lib/perl5"
do
    [ -d "\$_d" ] || continue
    if [ -n "\$_p5lib" ]; then
        _p5lib="\${_p5lib}:\${_d}"
    else
        _p5lib="\$_d"
    fi
done

PERL5LIB="\$_p5lib"
export PERL5LIB

exec "\$NEOPERL_PERL" "-I\${NEOPERL_PERL_LIB}" "\${NEOPERL_PREFIX}/libexec/neoperl/${tool}" "\$@"
EOF
    else
        cat > "$wrapper_path" <<EOF
#!/bin/sh
# Self-contained launcher wrapper for ${tool} (NeoPerl::MT)
# Author: stratum42

set -e

NEOPERL_PREFIX='${safe_prefix}'
NEOPERL_PERL='${safe_perl}'
NEOPERL_ARCH='${safe_arch}'

_p5lib=""
for _d in \
    "\${NEOPERL_PREFIX}/lib/perl5/\${NEOPERL_ARCH}" \
    "\${NEOPERL_PREFIX}/lib/perl5" \
    "\${NEOPERL_PREFIX}/perl5/lib/perl5/\${NEOPERL_ARCH}" \
    "\${NEOPERL_PREFIX}/perl5/lib/perl5"
do
    [ -d "\$_d" ] || continue
    if [ -n "\$_p5lib" ]; then
        _p5lib="\${_p5lib}:\${_d}"
    else
        _p5lib="\$_d"
    fi
done

PERL5LIB="\$_p5lib"
export PERL5LIB

exec "\$NEOPERL_PERL" "\${NEOPERL_PREFIX}/libexec/neoperl/${tool}" "\$@"
EOF
    fi
    chmod 755 "$wrapper_path"
}

build_neoperl() {
    log_step "Building neoperl-mt -> ${PREFIX}"
    local src="" build_dir="${WORK_DIR}/neoperl-mt" pgo_dir="${WORK_DIR}/pgo-neoperl"
    src="$(ensure_component_src neoperl)"
    copy_source_clean "$src" "$build_dir" "Core.c"

    (
        cd "$build_dir"
        run_makefile_pl
    )

    local base_cccdl="" base_lddl="" npl_cc="" npl_ld=""
    base_cccdl="$(extract_make_var "${build_dir}/Makefile" "NPL_CCCDLFLAGS")"
    base_lddl="$(extract_make_var "${build_dir}/Makefile" "NPL_LDDLFLAGS")"
    npl_cc="$(extract_make_var "${build_dir}/Makefile" "NPL_CC")"
    npl_ld="$(extract_make_var "${build_dir}/Makefile" "NPL_LD")"
    if [ "$CC_OVERRIDDEN" -eq 1 ]; then
        npl_cc="$CC_BIN"
        npl_ld="$CC_BIN"
    fi

    local pgo_ok=0
    if [ "$PGO_ACTIVE" -eq 1 ]; then
        mkdir -p "$pgo_dir"
        local s1_cf="" s1_lf=""
        s1_cf="$(pgo_stage1_cflags "$pgo_dir")"
        s1_lf="$(pgo_stage1_ldflags "$pgo_dir")"

        log_info "Stage 1/2 (neoperl-mt): building instrumented Core.xs + 10 C11 units..."
        (
            cd "$build_dir"
            make -j"$JOBS" \
                NPL_CC="$npl_cc" \
                NPL_LD="$npl_ld" \
                NPL_CCCDLFLAGS="${base_cccdl} ${s1_cf}" \
                NPL_LDDLFLAGS="${base_lddl} ${s1_lf}"

            log_info "Stage 1/2 (neoperl-mt): profiling via bench/neoperl_bench.pl --quick and t/01..t/05..."
            LLVM_PROFILE_FILE="${pgo_dir}/%p.profraw" NEOPERL_INFERENCE_MOCK=1 \
                run_perl -Mblib bench/neoperl_bench.pl --quick >/dev/null
            LLVM_PROFILE_FILE="${pgo_dir}/%p.profraw" NEOPERL_INFERENCE_MOCK=1 \
                run_perl -Mblib -MNeoPerl::Core -e 'NeoPerl::Core::LlamaBridge::available();' >/dev/null 2>&1 || true
            local tfile=""
            for tfile in \
                t/01_core_buffer.t \
                t/02_diff_syntax_ts.t \
                t/03_fuzzy_pty_simd.t \
                t/04_modal_vim.t \
                t/05_ex_layout_api.t
            do
                [ -f "$tfile" ] || continue
                LLVM_PROFILE_FILE="${pgo_dir}/%p.profraw" NEOPERL_INFERENCE_MOCK=1 \
                    run_perl -Mblib "$tfile" >/dev/null
            done
        )

        if pgo_merge_profile "$pgo_dir"; then
            pgo_ok=1
            log_info "Stage 1/2 (neoperl-mt): profile merged cleanly"
        else
            log_info "Warning (neoperl-mt): no profile data captured; falling back to -O3"
        fi

        # Clean Stage-1 object files in the exact same directory so Stage-2 matches paths
        (
            cd "$build_dir"
            make clean >/dev/null 2>&1 || true
            rm -f Core.c Core.o c/*.o blib/arch/auto/NeoPerl/Core/Core.* Makefile.old
            run_makefile_pl >/dev/null
        )
    fi

    local s2_cccdl="$base_cccdl"
    if [ "$pgo_ok" -eq 1 ]; then
        s2_cccdl="${base_cccdl} $(pgo_stage2_cflags "$pgo_dir")"
        log_info "Stage 2/2 (neoperl-mt): rebuilding PGO-optimized Core.xs + 10 C11 units..."
    else
        log_info "Building neoperl-mt with -O3..."
    fi

    (
        cd "$build_dir"
        make -j"$JOBS" \
            NPL_CC="$npl_cc" \
            NPL_LD="$npl_ld" \
            NPL_CCCDLFLAGS="$s2_cccdl" \
            NPL_LDDLFLAGS="$base_lddl"
        make install
    )

    # Install schema SQL files
    mkdir -p "${PREFIX}/schema"
    cp "${build_dir}/schema/"*.sql "${PREFIX}/schema/"

    # Install real Perl entrypoints under libexec and generate self-contained bin wrappers
    mkdir -p "${PREFIX}/libexec/neoperl" "${PREFIX}/bin"
    local tool=""
    for tool in npl npl-mcp npl-lsp; do
        if [ -f "${build_dir}/bin/${tool}" ]; then
            rm -f "${PREFIX}/libexec/neoperl/${tool}"
            cp "${build_dir}/bin/${tool}" "${PREFIX}/libexec/neoperl/${tool}"
            chmod 755 "${PREFIX}/libexec/neoperl/${tool}"
            write_wrapper "$tool"
        fi
    done

    # Install helper scripts if present
    if [ -d "${src}/scripts" ]; then
        mkdir -p "${PREFIX}/share/neoperl/scripts"
        local sc=""
        for sc in "${src}/scripts/"*.sh; do
            [ -f "$sc" ] || continue
            cp "$sc" "${PREFIX}/share/neoperl/scripts/"
            chmod 755 "${PREFIX}/share/neoperl/scripts/$(basename "$sc")"
        done
    fi

    log_info "Installed self-contained wrappers: ${PREFIX}/bin/{npl,npl-mcp,npl-lsp}"
}

# ---------------------------------------------------------------------------
# Execute Selected Component Builds in Dependency Order
# ---------------------------------------------------------------------------
if [ -n "$USE_EXISTING_PERL" ]; then
    configure_perl_env "$USE_EXISTING_PERL"
fi

for comp in $SELECTED_COMPONENTS; do
    case "$comp" in
        perl)
            build_perl
            ;;
        dbi)
            [ -n "$PERL_BIN" ] || configure_perl_env "$(command -v perl)"
            build_dbi
            ;;
        sqlite)
            [ -n "$PERL_BIN" ] || configure_perl_env "$(command -v perl)"
            build_sqlite
            ;;
        odbc)
            [ -n "$PERL_BIN" ] || configure_perl_env "$(command -v perl)"
            build_odbc
            ;;
        mojo)
            [ -n "$PERL_BIN" ] || configure_perl_env "$(command -v perl)"
            build_mojo
            ;;
        tk)
            [ -n "$PERL_BIN" ] || configure_perl_env "$(command -v perl)"
            build_tk
            ;;
        neoperl)
            [ -n "$PERL_BIN" ] || configure_perl_env "$(command -v perl)"
            build_neoperl
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Optional CPAN Developer Tools (PPI, Perl::Critic, Perl::Tidy)
# ---------------------------------------------------------------------------
if [ "$WITH_CPAN_TOOLS" = "yes" ]; then
    log_step "Installing optional CPAN developer tools into ${PREFIX}/perl5"
    if command -v cpanm >/dev/null 2>&1; then
        cpanm --notest --local-lib="${PREFIX}/perl5" PPI Perl::Critic Perl::Tidy || \
            log_info "Note: cpanm finished with non-zero status; retry manually with: cpanm --local-lib=${PREFIX}/perl5 PPI Perl::Critic Perl::Tidy"
    else
        log_info "cpanm not found; install manually when ready:"
        log_info "  curl -fsSL https://cpanmin.us | ${PERL_BIN:-perl} - --local-lib=${PREFIX}/perl5 PPI Perl::Critic Perl::Tidy"
    fi
fi

# ---------------------------------------------------------------------------
# Optional IBM Plex Fonts
# ---------------------------------------------------------------------------
has_ibm_plex_fonts() {
    if [ "$TARGET_OS" = "darwin" ]; then
        local d=""
        for d in "${HOME}/Library/Fonts" "/Library/Fonts" "/System/Library/Fonts"; do
            if [ -d "$d" ] && find "$d" -maxdepth 2 -iname 'IBMPlexMono*' 2>/dev/null | grep -q '.'; then
                return 0
            fi
        done
        return 1
    else
        if command -v fc-list >/dev/null 2>&1 && fc-list : family 2>/dev/null | grep -qi 'IBM Plex Mono'; then
            return 0
        fi
        if [ -d "${HOME}/.local/share/fonts" ] && find "${HOME}/.local/share/fonts" -iname 'IBMPlexMono*' 2>/dev/null | grep -q '.'; then
            return 0
        fi
        return 1
    fi
}

install_ibm_plex_fonts() {
    log_step "Checking IBM Plex Mono and IBM Plex Sans fonts"
    if has_ibm_plex_fonts; then
        log_info "IBM Plex fonts already installed"
        return 0
    fi
    if [ "$TARGET_OS" = "darwin" ] && command -v brew >/dev/null 2>&1; then
        log_info "Installing IBM Plex fonts via Homebrew..."
        brew install --cask font-ibm-plex-mono font-ibm-plex-sans || true
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        log_info "curl and unzip are required to download IBM Plex releases automatically"
        return 0
    fi
    local font_dest=""
    if [ "$TARGET_OS" = "darwin" ]; then
        font_dest="${HOME}/Library/Fonts"
    else
        font_dest="${HOME}/.local/share/fonts/ibm-plex"
    fi
    mkdir -p "$font_dest"
    local zip_tmp="${WORK_DIR}/ibm-plex.zip"
    if curl -fsSL "https://github.com/IBM/plex/releases/latest/download/TrueType.zip" -o "$zip_tmp"; then
        mkdir -p "${WORK_DIR}/plex-unzip"
        unzip -qo "$zip_tmp" -d "${WORK_DIR}/plex-unzip"
        find "${WORK_DIR}/plex-unzip" -type f \( -iname 'IBMPlexMono-*.ttf' -o -iname 'IBMPlexSans-*.ttf' \) -exec cp {} "$font_dest/" \;
        if [ "$TARGET_OS" = "linux" ] && command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$font_dest" >/dev/null 2>&1 || true
        fi
        log_info "Installed IBM Plex Mono and IBM Plex Sans into ${font_dest}"
    else
        log_info "Unable to download IBM Plex release archive; install IBM Plex Mono/Sans manually"
    fi
}

if [ "$WITH_FONTS" = "yes" ]; then
    install_ibm_plex_fonts
fi

# ---------------------------------------------------------------------------
# Optional Antigravity CLI (agy) Install
# ---------------------------------------------------------------------------
if [ "$INSTALL_AGY" = "yes" ]; then
    log_step "Checking Antigravity CLI (agy)"
    if command -v agy >/dev/null 2>&1; then
        log_info "agy already installed at $(command -v agy)"
    elif [ -x "${HOME}/.local/bin/agy" ]; then
        log_info "agy already installed at ${HOME}/.local/bin/agy"
    else
        log_info "Installing agy via https://antigravity.google/cli/install.sh..."
        curl -fsSL https://antigravity.google/cli/install.sh | bash
        if is_tty && [ "$ASSUME_YES" -eq 0 ]; then
            if prompt_yn "Run 'agy acp --login' now to sign in?" "n"; then
                agy_cmd="agy"
                if ! command -v agy >/dev/null 2>&1 && [ -x "${HOME}/.local/bin/agy" ]; then
                    agy_cmd="${HOME}/.local/bin/agy"
                fi
                "$agy_cmd" acp --login || true
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Optional Local IBM Db2 Community Container Setup
# ---------------------------------------------------------------------------
if [ "$SETUP_DB2" = "yes" ]; then
    log_step "Setting up local IBM Db2 Community container"
    local_db2_script=""
    if [ -x "${SCRIPT_DIR}/scripts/setup-db2-container.sh" ]; then
        local_db2_script="${SCRIPT_DIR}/scripts/setup-db2-container.sh"
    elif [ -x "${PREFIX}/share/neoperl/scripts/setup-db2-container.sh" ]; then
        local_db2_script="${PREFIX}/share/neoperl/scripts/setup-db2-container.sh"
    fi
    if [ -n "$local_db2_script" ]; then
        "$local_db2_script" --prefix="$PREFIX" --schema="${PREFIX}/schema/db2_memory.sql"
    else
        log_info "setup-db2-container.sh not found; skipping Db2 setup"
    fi
fi

# ---------------------------------------------------------------------------
# PATH Placement
# ---------------------------------------------------------------------------
apply_path_mode() {
    log_step "Configuring PATH mode: ${PATH_MODE}"
    local tool="" rc_file=""
    rc_file="$(detect_shell_rc)"

    case "$PATH_MODE" in
        local)
            mkdir -p "${HOME}/.local/bin"
            for tool in npl npl-mcp npl-lsp; do
                if [ -x "${PREFIX}/bin/${tool}" ]; then
                    ln -sf "${PREFIX}/bin/${tool}" "${HOME}/.local/bin/${tool}"
                fi
            done
            log_info "Symlinked launchers into ${HOME}/.local/bin"
            case ":${PATH}:" in
                *":${HOME}/.local/bin:"*) ;;
                *)
                    if prompt_yn "Add ${HOME}/.local/bin to ${rc_file}?" "y"; then
                        ensure_rc_block "$rc_file" "${HOME}/.local/bin"
                    else
                        log_info "Add to your shell profile: export PATH=\"${HOME}/.local/bin:\$PATH\""
                    fi
                    ;;
            esac
            ;;
        usr-local)
            local use_sudo=""
            if [ ! -w "/usr/local/bin" ]; then
                if command -v sudo >/dev/null 2>&1; then
                    use_sudo="sudo"
                else
                    printf 'error: /usr/local/bin is not writable and sudo is unavailable\n' >&2
                    exit 1
                fi
            fi
            for tool in npl npl-mcp npl-lsp; do
                if [ -x "${PREFIX}/bin/${tool}" ]; then
                    if [ -n "$use_sudo" ]; then
                        sudo ln -sf "${PREFIX}/bin/${tool}" "/usr/local/bin/${tool}"
                    else
                        ln -sf "${PREFIX}/bin/${tool}" "/usr/local/bin/${tool}"
                    fi
                fi
            done
            log_info "Symlinked launchers into /usr/local/bin"
            ;;
        shell-rc)
            ensure_rc_block "$rc_file" "${PREFIX}/bin"
            ;;
        none)
            log_info "PATH left untouched. To invoke directly:"
            log_info "  export PATH=\"${PREFIX}/bin:\$PATH\""
            ;;
    esac
}

apply_path_mode

# ---------------------------------------------------------------------------
# Desktop / macOS Application Launcher
# ---------------------------------------------------------------------------
if [ "$INSTALL_APP" = "yes" ]; then
    if [ "$TARGET_OS" = "darwin" ]; then
        log_step "Building macOS launcher bundle (${APP_DIR}/NeoPerl.app)"
        local_app_script=""
        if [ -x "${SCRIPT_DIR}/scripts/make-macos-app.sh" ]; then
            local_app_script="${SCRIPT_DIR}/scripts/make-macos-app.sh"
        elif [ -x "${PREFIX}/share/neoperl/scripts/make-macos-app.sh" ]; then
            local_app_script="${PREFIX}/share/neoperl/scripts/make-macos-app.sh"
        fi
        if [ -n "$local_app_script" ]; then
            "$local_app_script" --prefix="$PREFIX" --app-dir="$APP_DIR"
        else
            log_info "make-macos-app.sh not found; skipping macOS .app bundle"
        fi
    else
        log_step "Creating FreeDesktop launcher (${APP_DIR}/neoperl.desktop)"
        mkdir -p "$APP_DIR"
        cat > "${APP_DIR}/neoperl.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=NeoPerl
Comment=Multi-threaded modal code editor
Exec=${PREFIX}/bin/npl %F
Terminal=false
Categories=Development;TextEditor;
EOF
        log_info "Wrote ${APP_DIR}/neoperl.desktop"
    fi
fi

# ---------------------------------------------------------------------------
# Final Summary
# ---------------------------------------------------------------------------
printf '\nNeoPerl::MT installation complete.\n'
printf '  Prefix:    %s\n' "$PREFIX"
printf '  Binaries:  %s/bin/npl, %s/bin/npl-mcp, %s/bin/npl-lsp\n' "$PREFIX" "$PREFIX" "$PREFIX"
print_local_ai_summary
printf '  Verify:    %s/bin/npl --no-agy --info\n' "$PREFIX"
