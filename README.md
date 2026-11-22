# NeoPerl::MT

A modal code editor and development workbench built in Perl 5 around a pure-C11
Tier-1 thread-safe XS core (`NeoPerl::Core`), sharing one headless editor engine
between a GPU-accelerated `Tcl::Tk::MT::Canvas` GUI and a 24-bit ANSI terminal
TUI (`npl --tui`).

`NeoPerl::MT` draws its modal grammar, buffer/extmark model, window splits, and
Ex command ergonomics from Vim and Neovim, while using Perl 5 (`init.pl` and
`$vim->api->*`) as its native scripting language. By default it renders in an
**AIX Amber Phosphor** (`aix_amber`) pure-black (`#000000`) and P3 amber
(`#ffb000`) theme paired with **IBM Plex Mono** and **IBM Plex Sans**
typography (with `tokyonight`, `catppuccin`, `gruvbox`, and `kanagawa`
available via `:colorscheme`). An optional 4-tab Command Center toggles open on
demand for Antigravity ACP chat, IBM Db2 semantic memory, local `llama.cpp`
specialist models/offload jobs, and C/XS debugging and profiling.

Alongside the editor, `NeoPerl::MT` packages **12 modular Perl 5 MCP domain
packs** (`bin/npl-mcp`) and a **Dual-Mode LSP stack** (`bin/npl-lsp` plus
in-process `NeoPerl::Plugin::LSP`) covering IBM databases, mainframe and
midrange languages, multi-ISA assembly, and GPU compute/graphics shaders.

New to `NeoPerl::MT`? After installing, see the [Getting Started & Daily Use Guide (`howto.md`)](howto.md) for a step-by-step walkthrough of modal editing, splits, Antigravity chat, local models, Db2 memory, Perl/XS tooling, and all keybindings.

---

## Installation (`./install.sh`)

For a self-contained source installation on macOS (`arm64`, `x86_64`) or Linux
(`arm64`, `amd64`, `ppc64le`), run the included two-stage Profile-Guided
Optimization (PGO) installer:

```sh
# Interactive install (prompts for PATH mode, launcher, optional tools)
./install.sh

# Preview the complete build and installation plan without writing files
./install.sh --dry-run

# Non-interactive install with explicit choices
./install.sh --yes \
  --prefix="$HOME/.local/neoperl" \
  --path-mode=local \
  --install-app \
  --install-agy \
  --setup-db2
```

Once installation finishes, open [`howto.md`](howto.md) to verify `npl --info`
and walk through your first session.

### Self-Contained Prefix Layout

`./install.sh` installs everything under `--prefix=DIR` (default
`~/.local/neoperl`) without modifying system Perl or system libraries:

```text
~/.local/neoperl/
├── bin/
│   ├── perl                 # perl5-mt binary (built from source unless --use-existing-perl)
│   ├── perl5-mt -> perl     # convenience symlink
│   ├── npl                  # self-contained POSIX /bin/sh wrapper
│   ├── npl-mcp              # self-contained POSIX /bin/sh wrapper
│   ├── npl-lsp              # self-contained POSIX /bin/sh wrapper
│   └── npl-db2-ctl          # optional Db2 container helper (created by --setup-db2)
├── libexec/neoperl/
│   ├── npl                  # real Perl CLI entrypoints invoked by bin/* wrappers
│   ├── npl-mcp
│   └── npl-lsp
├── lib/perl5/               # installed XS and pure-Perl modules (incl. <archname>/)
├── perl5/lib/perl5/         # optional CPAN tools (PPI, Perl::Critic, Perl::Tidy)
├── schema/                  # SQL schema files (e.g. db2_memory.sql)
├── share/neoperl/scripts/   # installed helper scripts (make-macos-app.sh, setup-db2-container.sh)
└── src/                     # default clone cache when sibling checkouts are absent
```

Each wrapper in `$PREFIX/bin/{npl,npl-mcp,npl-lsp}` sets `PERL5LIB` strictly to
the prefix module directories (`$PREFIX/lib/perl5/<archname>`,
`$PREFIX/lib/perl5`, and, if present, `$PREFIX/perl5/lib/perl5/<archname>` and
`$PREFIX/perl5/lib/perl5`) and runs `exec` on the prefix Perl binary (or the
explicit `--use-existing-perl` binary). As a result, `npl`, `npl-mcp`, and
`npl-lsp` run from any working directory with an empty `PERL5LIB` and do not
depend on or interfere with system Perl.

### Source Resolution & Clean Build Isolation

- **Sibling checkouts vs cloning**: If `--source-dir=DIR` is omitted,
  `install.sh` checks the parent directory of the `neoperl-mt` checkout for
  sibling repositories (`perl5-mt`, `tcl-tk-mt`, `dbi-mt`, etc.). If present,
  it uses that directory; otherwise it defaults to `$PREFIX/src` and clones any
  missing repositories (`git clone --depth 1`) from `--repo-base=URL`
  (default `$NEOPERL_REPO_BASE` or `https://github.com/stratum42`).
- **Untouched source trees**: Before compiling any component, `install.sh`
  copies the repository via `tar --exclude=...` (omitting `.git`, `blib`,
  `Makefile`, `*.o`, `*.profraw`, `*.gcda`, etc.) into a temporary build
  directory (`${TMPDIR:-/tmp}/neoperl-install.XXXXXX`) cleaned automatically on
  exit. Your source checkouts are never dirtied.

### 7-Component Build Order & Two-Stage PGO

`install.sh` builds selected components (`--components=all` or a comma-separated
subset) in strict dependency order, compiling each C/XS component with two-stage
PGO:

| Order | Component (`--components`) | Repository | Stage-1 Training Workload / Notes |
|---|---|---|---|
| 1 | `perl` | `perl5-mt` | `sh Configure -des -Dprefix=$PREFIX -Dusethreads -Dusedevel -Uversiononly -Duse64bitall`; trained on regex, UTF-8, hash/sort/`pack`, OO dispatch, and `MT::Pool`. Skipped when `--use-existing-perl=PATH` is supplied (supports both installed Perl and uninstalled `perl5-mt` build trees). |
| 2 | `dbi` | `dbi-mt` | Trained on `t/01basics.t` and `t/02dbidrv.t`. |
| 3 | `sqlite` | `dbd-sqlite-mt` | Trained on an in-memory SQLite table creation, 2,000 prepared `INSERT`s, and `SELECT` fetch loop. |
| 4 | `odbc` | `dbd-odbc-mt` | Auto-probes `$ODBCHOME/include`, `$DB2DIR/include`, `$IBM_DB_HOME/include`, Homebrew/system include paths, and `odbc_config` for `sql.h` or `sqlcli1.h`; skipped cleanly if headers are absent. |
| 5 | `mojo` | `mojolicious-mt` | Installs pure-Perl `Mojolicious`, then 2-stage PGO builds `xs/` (`Mojo::MT::Accel`) trained on an `xml_escape` loop. |
| 6 | `tk` | `tcl-tk-mt` | 2-stage PGO C11/XS build (Metal on macOS, Vulkan + Software on Linux) trained on headless `t/01*.t..t/03*.t` (`TCL_TK_MT_HEADLESS=1`); skipped cleanly if Tcl/Tk development headers are absent. |
| 7 | `neoperl` | `neoperl-mt` | 2-stage PGO build of `Core.xs` and all 10 `c/*.c` units, trained on `bench/neoperl_bench.pl --quick`, `NeoPerl::Core::LlamaBridge::available()`, and `t/01_core_buffer.t` through `t/05_ex_layout_api.t`, then cleaned in place before Stage-2 rebuild and installation of modules, `schema/*.sql`, `share/neoperl/scripts/*.sh`, and `$PREFIX/bin/*` wrappers. |

Platform-specific compiler and PGO flags:

- **macOS (`arm64`, `x86_64`)**: Uses Clang instrumentation:
  - Stage 1: `-O3 -fprofile-instr-generate=<dir>/%p.profraw`
  - Merge: `xcrun llvm-profdata merge -output=<dir>/merged.profdata <dir>/*.profraw`
  - Stage 2: `-O3 -fprofile-instr-use=<dir>/merged.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date`
  - Falls back cleanly to `-O3` if `--no-pgo` is passed or `llvm-profdata` is unavailable.
- **Linux (`amd64`, `arm64`, `ppc64le`)**: Uses GCC instrumentation by default
  (or Clang PGO if `CC=clang` is set):
  - Stage 1: `-O3 -fprofile-generate=<dir>`
  - Stage 2: `-O3 -fprofile-use=<dir> -fprofile-correction -Wno-missing-profile`
- **IBM POWER (`ppc64le`)**: Detects POWER8, POWER9, or POWER10 from
  `/proc/cpuinfo` (override with `--power-cpu=power8|power9|power10|native`,
  default `power8`), exports `NEOPERL_POWER_CPU`, compiles with
  `-mcpu=<cpu> -mvsx` (adding `-mmma` for `power10`), accounts for 64 KiB OS
  pages, and skips local GGUF inference by default.

### Local GGUF Inference & Hardware Gating

Local GGUF inference auto-enables only on hosts where a supported GPU
accelerator is detected:

- **Apple Silicon Metal** (`darwin/arm64`)
- **NVIDIA CUDA** (Linux with `/dev/nvidia0` or `nvidia-smi -L`)
- **Discrete AMD ROCm** (Linux `/dev/kfd` topology GPU node with dedicated VRAM)

On **IBM POWER (`ppc64le`)**, **AIX**, **macOS `x86_64`**, and **CPU-only
Linux** hosts, local GGUF inference is automatically skipped so `npl` launches
with zero local model RAM usage. On every platform, you can still use remote
GPU inference by pointing any subset of the four role environment variables at
an OpenAI-compatible `llama-server` endpoint (consuming `0.0 GB` of local RAM):

```sh
export NEOPERL_EMBED_URL="http://gpu-host:8081/v1"
export NEOPERL_HYMEM_URL="http://gpu-host:8082/v1"
export NEOPERL_VISION_URL="http://gpu-host:8083/v1"
export NEOPERL_BONSAI_URL="http://gpu-host:8084/v1"
```

### Optional Integrations, PATH Placement & Desktop Launchers

- **PATH placement (`--path-mode`)**:
  - `local` (default): symlinks `npl`, `npl-mcp`, and `npl-lsp` into
    `~/.local/bin`, and offers to add an idempotent `# >>> neoperl-mt >>>`
    PATH block to your shell rc file if `~/.local/bin` is not already in `PATH`.
  - `usr-local`: symlinks into `/usr/local/bin` (invoking `sudo` only if
    `/usr/local/bin` is not writable).
  - `shell-rc`: appends an idempotent `# >>> neoperl-mt >>>` block exporting
    `$PREFIX/bin` to `~/.zshrc`, `~/.bashrc` (or `~/.bash_profile` on macOS),
    or `~/.profile`.
  - `none`: leaves `PATH` unchanged and prints the exact `export PATH=...` line.
- **Desktop launcher (`--install-app` / `--no-install-app`)**:
  - On macOS, delegates to `scripts/make-macos-app.sh` to build
    `/Applications/NeoPerl.app` (or `--app-dir="$HOME/Applications"`),
    including `Contents/Info.plist` (`CFBundleIdentifier=org.stratum42.neoperl-mt`,
    `NSHighResolutionCapable`, source-file and folder document types), a
    pure-Perl `Compress::Zlib` black-and-amber `NPL` iconset packaged via
    `iconutil -c icns` (`Contents/Resources/NeoPerl.icns`), and
    `Contents/MacOS/NeoPerl` which strips Finder `-psn_*` arguments before
    running `exec "$PREFIX/bin/npl" --gpu "$@"`.
  - On Linux, writes a FreeDesktop entry at
    `~/.local/share/applications/neoperl.desktop` (or `--app-dir=DIR`).
- **Antigravity CLI (`--install-agy` / `--no-install-agy`)**: Checks `PATH` and
  `~/.local/bin/agy`; if absent and enabled, runs
  `curl -fsSL https://antigravity.google/cli/install.sh | bash` and (on an
  interactive TTY) offers to run `agy acp --login`.
- **Local IBM Db2 Community container (`--setup-db2` / `--no-setup-db2`)**:
  Delegates to `scripts/setup-db2-container.sh` (also runnable directly):
  - Auto-detects `docker` or `podman` (`--runtime=auto|docker|podman`), pulls
    and starts `icr.io/db2_community/db2` bound to `127.0.0.1:50000`
    (`--port=PORT`, `--db-name=NEOPERL`, persistent volume `neoperl-db2-data`).
  - On macOS `arm64`, passes `--platform linux/amd64` (requires Docker Desktop,
    OrbStack, or Colima with Rosetta amd64 emulation).
  - On `ppc64le`, does not fail mysteriously: prints clear remote Db2 DSN setup
    steps because the Db2 Community container image targets `linux/amd64`.
  - Generates a random 20-character `db2inst1` password via `openssl rand` (or
    accepts `--password=...`), waits for Db2 database readiness, copies and
    applies `schema/db2_memory.sql`, writes mode `0600`
    `~/.config/neoperl/db2.env` and `~/.config/neoperl/odbc.ini`
    (`[NEOPERL_MEM]`), and creates `$PREFIX/bin/npl-db2-ctl` supporting
    `start`, `stop`, `status`, `logs`, `shell`, and `apply-schema`.
- **Optional CPAN developer tools (`--with-cpan-tools` / `--no-cpan-tools`)**:
  Installs `PPI`, `Perl::Critic`, and `Perl::Tidy` into `$PREFIX/perl5` via
  `cpanm --local-lib="$PREFIX/perl5"` (or prints the exact manual `cpanm`
  command if `cpanm` is not installed).
- **Optional IBM Plex fonts (`--with-fonts` / `--no-fonts`)**: Checks for
  `IBM Plex Mono` and `IBM Plex Sans`; if absent, installs via Homebrew casks
  on macOS or downloads the official `IBM/plex` TrueType archive into
  `~/Library/Fonts` or `~/.local/share/fonts/ibm-plex` (running `fc-cache -f`).

### Installer CLI Reference

| Flag | Default | Description |
|---|---|---|
| `--prefix=DIR` | `~/.local/neoperl` | Self-contained installation prefix |
| `--source-dir=DIR` | parent dir or `$PREFIX/src` | Directory containing sibling checkouts (or clone target) |
| `--repo-base=URL` | `https://github.com/stratum42` | Git base URL for missing repositories (`$NEOPERL_REPO_BASE`) |
| `--components=LIST` | `all` | `all` or comma-separated subset of `perl,dbi,sqlite,odbc,mojo,tk,neoperl` |
| `--use-existing-perl=PATH` | *(build `perl5-mt`)* | Build XS stack and `neoperl-mt` against an existing `perl` / `perl5-mt` binary |
| `--pgo` / `--no-pgo` | `--pgo` | Enable or disable two-stage PGO (`-O3` fallback) |
| `-j`, `--jobs=N` | detected CPU count | Parallel `make` jobs |
| `--power-cpu=CPU` | auto (`power8` fallback) | IBM POWER target on `ppc64le`: `power8`, `power9`, `power10`, or `native` |
| `--target-os=OS`, `--target-arch=ARCH` | host OS/arch | Override detected `darwin`/`linux` and `arm64`/`amd64`/`ppc64le` for `--dry-run` |
| `--path-mode=MODE` | `local` | `local`, `usr-local`, `shell-rc`, or `none` |
| `--install-app` / `--no-install-app` | prompt (macOS TTY) / `no` | Build macOS `NeoPerl.app` or Linux `neoperl.desktop` |
| `--app-dir=DIR` | `/Applications` (macOS) | Target directory for `NeoPerl.app` or `neoperl.desktop` |
| `--with-cpan-tools` / `--no-cpan-tools` | `no` | Install `PPI`, `Perl::Critic`, `Perl::Tidy` into `$PREFIX/perl5` |
| `--with-fonts` / `--no-fonts` | `no` | Check/install `IBM Plex Mono` and `IBM Plex Sans` |
| `--setup-local-ai` / `--no-setup-local-ai` | `auto` | Print local `llama.cpp` and `:ModelPull` guidance on GPU hosts |
| `--install-agy` / `--no-install-agy` | `no` | Install Antigravity CLI (`agy`) if absent |
| `--setup-db2` / `--no-setup-db2` | `no` | Provision local IBM Db2 Community container via `scripts/setup-db2-container.sh` |
| `-y`, `--yes` | off | Non-interactive mode using safe defaults |
| `-n`, `--dry-run` | off | Print the full plan (including app/Db2 sub-plans) without making changes |
| `--uninstall` | off | Cleanly remove managed install artifacts (see below) |
| `-V`, `--version`, `-h`, `--help` | — | Print installer version or usage |

### Uninstalling

```sh
./install.sh --uninstall
# or with custom locations:
./install.sh --uninstall --prefix="$HOME/.local/neoperl" --app-dir="$HOME/Applications"
```

`--uninstall` refuses unsafe prefixes (`/`, `$HOME`, `/usr`, `/usr/local`,
`/tmp`, `/var`, `/etc`, `/opt`), removes only symlinks in `~/.local/bin` or
`/usr/local/bin` whose target points inside `$PREFIX/bin/`, strips only the
`# >>> neoperl-mt >>>` ... `# <<< neoperl-mt <<<` block from shell rc files,
removes `NeoPerl.app` only if its `Info.plist` contains
`org.stratum42.neoperl-mt` (or removes `~/.local/share/applications/neoperl.desktop`
on Linux), and removes `$PREFIX`.

---

## Using with Signed-In Antigravity (`agy`)

`NeoPerl::MT` connects automatically to the official Google Antigravity CLI
(`agy`) over the public Agent Client Protocol (`agy acp`) with no extra config
files required:

1. **Install the official `agy` CLI** (via `./install.sh --install-agy`, directly below, or `:AgyInstall!` inside NeoPerl):
   ```sh
   curl -fsSL https://antigravity.google/cli/install.sh | bash
   ```
2. **Sign in once** (or run `:AgyLogin` / `<leader>aL` inside NeoPerl):
   ```sh
   npl --agy-login
   # equivalent to: agy acp --login
   ```
3. **Launch `npl` normally** — `NeoPerl::MT` auto-discovers `agy`, starts `agy acp --ide-mcp-port <port> --add-dir <cwd>` asynchronously in the background with your `EditorMCP` tools attached, and displays **`AGY:LIVE`** in the top bar:
   ```sh
   npl path/to/project
   ```
   Open chat with `<leader>aa` or `:AgyChat <prompt>`, switch models with `:AgyModel` (`<leader>aM`), inspect status anytime with `:AgyDoctor` / `:AgyStatus`, manage sessions with `:AgyNewSession` / `:AgyResume <id>` / `:AgyReconnect`, or pass `--agy-mock` for offline demos and CI (or `--no-agy` to stay `AGY:OFF`).

---

## Architecture

```
+--------------------------------------------------------------------------+
|  Dual Frontends (Shared Headless Core, aix_amber + IBM Plex default)     |
|   - NeoPerl::UI::GPU : Tcl::Tk::MT::Canvas (Metal / Vulkan / Software,   |
|                        2x Retina HiDPI, inset 1px borders, grid-snapped) |
|   - NeoPerl::UI::TUI : 24-bit ANSI terminal (npl --tui, diff-buffered)   |
|   - Toggleable 4-Tab Command Center: CHAT | MEMORY | MODELS | XSDEV      |
+--------------------------------------------------------------------------+
|  Headless Editor & Plugins (lib/NeoPerl/)                                |
|   - Editor, Buffer, Modal, ExCmd, Layout (BSP splits/tabs/floats), RPC   |
|   - NvimBridge (--nvim-engine): optional live nvim --embed ext_linegrid  |
|     over C11 Msgpack-RPC with EditorMCP sync & offline mock server       |
|   - Telescope, Explorer, Git, WhichKey, Themes (aix_amber default)       |
|   - Dual-Mode LSP: built-in 12-domain engine + external LSPs/compilers   |
|     (clangd, cobc, che4z, rpgle-ls, asm-lsp, glsl_analyzer, ocloc, ...)  |
|   - PerlDev (in-process PPI + Perl::Critic + Perl::Tidy workers)         |
|   - XSDev (Cachegrind/PMU, Valgrind/ASan/TSan, GDB-MI3/LLDB, PGO, POWER) |
+--------------------------------------------------------------------------+
|  Hybrid Cloud + Local Control Plane & 12 Domain MCP Packs                |
|   - Antigravity::ACP (agy acp JSON-RPC 2.0 stdio + --agy-mock loopback)  |
|   - Antigravity::EditorMCP (23 core tools + selective :McpPacks mounts)  |
|   - MCP::Registry + bin/npl-mcp (--pack=<name|all> --stdio / --http)     |
|     on Mojolicious / Mojo::MT::Accel (+ IO::Socket::INET fallback)       |
|   - Inference::Manager (LRU RAM budget: Embedder, Hy-Memory, Vision,     |
|     Ternary-Bonsai offload queue via Mojo::UserAgent / libllama)         |
|   - Memory::Store (IBM Db2 12.1.2+ VECTOR/VECTOR_DISTANCE via            |
|     DBI::MT::Pool + dbd-odbc-mt; SQLite + C11 SIMD offline test double)  |
+--------------------------------------------------------------------------+
|  NeoPerl::Core (Pure C11 Tier-1 PERL_XS_THREADSAFE XS, c/*.c)            |
|   - mmap piece-table, branching undo tree, byte-anchored extmarks        |
|   - Reentrant C11 VimEngine (c/vim_engine.c) + Msgpack codec (msgpack.c) |
|   - Myers line diff, 27-language incremental lexer, dlopen(tree-sitter)  |
|   - Parallel file walker / fuzzy scorer / grep, POSIX PTY :terminal      |
|   - SIMD cosine/top-K (ARM64 NEON, x86_64 SSE2/AVX2, POWER8+ VSX/MMA)    |
|   - Optional runtime dlopen(libllama) bridge                             |
+--------------------------------------------------------------------------+
```

---

## Key Components

### C11 XS Core (`NeoPerl::Core`)
- Builds cleanly with `-std=c11 -O3 -Wall -Wextra -Werror` on `perl5-mt`
  (`-DPERL_XS_THREADSAFE=1`, exporting `_mt_threadsafe_boot_NeoPerl__Core`) as
  well as stock Perl 5, with zero hard compile-time links to `libtree-sitter`,
  `libllama`, or `Tcl::Tk::MT`.
- **Piece-table & extmarks (`c/buffer.c`)**: Zero-copy `mmap` file opening,
  dynamic line-start table, branching undo tree (`u`, `<C-r>`, `g-`, `g+`,
  `:earlier`, `:later`, `:undolist`), and byte-anchored extmarks with automatic
  gravity tracking for highlights, gutter signs, inline/EOL virtual text, and
  virtual lines.
- **Pure-C11 Vim modal core & differential oracle (`c/vim_engine.c`,
  `t/17_vim_oracle.t`)**: Fully reentrant (`PERL_XS_THREADSAFE`, zero global
  state) Vim modal engine operating directly on the piece-table buffer across
  Normal, Insert, Replace, Visual, Visual-Line, Visual-Block, and Operator
  modes — covering `curswant` sticky columns, `cw`/`dw` word semantics, quote
  and bracket text objects, registers (including append and black-hole), marks,
  macros, dot-repeat, and grouped branching undo, differentially verified
  byte-for-byte (buffer text and cursor coordinates) against `/usr/bin/vim`.
- **Zero-dependency C11 MessagePack codec & optional `--nvim-engine`
  (`c/msgpack.c`, `lib/NeoPerl/NvimBridge.pm`, `t/18_nvim_engine.t`)**:
  Thread-safe incremental MessagePack encoder/stream decoder supporting all
  standard types plus Neovim `ext` handles (`0`=Buffer, `1`=Window,
  `2`=Tabpage). Passing `--nvim-engine` (with optional `--nvim-bin=<path>`)
  spawns upstream `nvim --embed --headless`, attaches via `ext_linegrid` +
  24-bit `rgb`, renders live Neovim cells directly inside the AIX Amber IBM
  Plex GPU or TUI viewport with an `NVIM <ver>` statusline badge, and delegates
  `EditorMCP` buffer inspection and edit proposals straight to the embedded
  Neovim instance (with a protocol-identical offline Msgpack-RPC loopback
  server for CI hosts without `nvim`).
- **Diff, 27-language incremental syntax & search (`c/diff.c`, `c/syntax.c`,
  `c/fuzzy.c`)**: Myers `O(ND)` line diff, 27-language incremental line-state
  lexer (including SQL/SPL, HLASM, Multi-ISA Assembly, RPGILE, COBOL, Intel
  SYCL/OpenCL, AMD HIP/ROCm, Vulkan GLSL/SPIR-V, and Apple Metal MSL) with
  optional `dlopen(libtree-sitter)` support, and multi-threaded file walking,
  fuzzy scoring, and project grep.
- **IBM POWER (`ppc64le`, POWER8/9/10) support (`c/power_arch.h`,
  `c/vec_simd.c`)**: Runtime `getauxval(AT_HWCAP2)` detection, isolated
  `<altivec.h>` macros (`__vector`), dynamic OS page size (`sysconf(_SC_PAGESIZE)`
  for 64 KiB pages), strict unsigned-`char` cleanliness, `__atomic_*` barriers
  with POWER SMT spin-yield (`or 27,27,27`), SMT physical-core worker sizing,
  and 4-way unrolled VSX `vec_madd` SIMD kernels that stay bit-identical under
  `PERL_FORCE_SCALAR=1`.

### AIX Amber Phosphor UI & IBM Plex Typography (`lib/NeoPerl/UI/`)
- **`aix_amber` default theme**: Pure `#000000` black background paired with
  classic IBM 3151 / AIX P3 amber phosphor (`#ffb000`) primary text, warm
  copper/gold syntax hierarchy, and restrained semantic hues for diagnostics,
  diff hunks, and Cachegrind heatbars. Switch anytime via `:colorscheme
  tokyonight|catppuccin|gruvbox|kanagawa|aix_amber`.
- **`NeoPerl::UI::GPU`**: Composites the workspace onto a single
  `Tcl::Tk::MT::Canvas` (Metal on macOS, Vulkan on Linux/Windows, Software CPU
  fallback) using **IBM Plex Mono** for code/gutter/terminal/Telescope and
  **IBM Plex Sans** for panel headers, badges, and chat prose (gracefully
  falling back to system monospace/sans when IBM Plex fonts are absent).
  Measures exact font cell advances via `$canvas->measure_text`, snaps panels,
  dividers, cursors, and text anchors onto exact physical pixels, draws 1 px
  borders with `-inset_stroke => 1` and filled 1 px split hairlines to avoid
  subpixel blur, and supports 2× Retina HiDPI (`--scale=1|2`, defaulting
  `--screenshot` PNG captures to 2× physical resolution via `Compress::Zlib`).
- **`NeoPerl::UI::TUI`**: 24-bit truecolor terminal frontend (`npl --tui`) with
  `aix_amber` default styling, POSIX raw termios, alternate screen, SGR mouse,
  bracketed paste, `SIGWINCH` resize, Unicode box-drawing borders, diff-buffered
  ANSI output, and a deterministic `headless => 1` virtual-terminal mode.
- **4-Tab Command Center** (closed by default):
  1. **`CHAT` (`<leader>aa`)**: Antigravity streaming messages, collapsible
     thought and tool cards, plan checklist, and Vim-keybound permission bar
     (`[a]` Allow, `[A]` Always, `[r]` Reject).
  2. **`MEMORY` (`<leader>am`)**: IBM Db2 semantic memory inspector with search
     bar, cosine similarity meters, scope pills (`global`/`repo`/`file`/`symbol`),
     pin/forget controls, and temporal superseding lineage.
  3. **`MODELS` (`<leader>aj`)**: 4-slot local inference residency meter
     (`Embedder`, `Hy-Memory-30B-A3B`, `Granite-Vision-4.1-4B`,
     `Ternary-Bonsai-2-27B`), live out-of-band Bonsai job queue with syntax
     status and diff previews, Granite-Vision document cache, and Cloud Tokens
     Saved counter.
  4. **`XSDEV` (`<leader>xd`)**: GDB/MI3 and LLDB backtrace, locals, `my_perl`
     threads, Perl `SV*` inspector, POWER registers (`r0-r31`/`vs0-vs63`),
     Cachegrind hotspot table, sanitizer status, and PGO speedup summary.

### 12 Modular Database, Mainframe, Assembly & GPU MCP Packs (`lib/NeoPerl/MCP/` & `bin/npl-mcp`)

To keep model tool context concise, domain packs stay unmounted by default inside
`EditorMCP` (preserving the 23 core editor/memory/PerlDev/XSDev tools) and can
be toggled selectively via `:McpPacks` (`<leader>mp`), `:McpPackEnable
<name|all>`, `:McpPackDisable <name|all>`, `:McpConfigEmit [path]`, or run
standalone with `bin/npl-mcp --pack=<name[,name2]|all> [--stdio|--http=127.0.0.1:PORT]`:

| Pack | Category | Capabilities |
|---|---|---|
| `db2i` | database | Guarded `DBI`/`DBD::ODBC` queries, `QSYS2` catalog & system services, `*SYS`/`*SQL` & CCSID lint, `.sqlrpgle` `EXEC SQL` validator |
| `db2luw` | database | Guarded `DBI`/`DBD::ODBC` queries, `SYSCAT` inspection, `db2exfmt` explain analyzer, Db2 12.1.2+ `VECTOR`/`VECTOR_DISTANCE` helper, isolation/BLU SQL lint |
| `db2z` | database | Guarded DRDA/ODBC queries, `SYSIBM` catalog inspection, `PLAN_TABLE` Stage 1/2 analyzer, DDL-to-COBOL `DCLGEN` generator, `BIND PACKAGE` checker |
| `informix` | database | Guarded `DBI`/`DBD::ODBC` queries, `systables`/`sysmaster` inspection, SPL analyzer, `sqexplain.out` parser, schema/lock-mode checks |
| `hlasm` | mainframe | z/Architecture PoO opcode lookup (through z17 Telum II `NNPA`/`DFLTCC`), `DSECT`/`DS`/`DC` byte-offset & slack calculator, `USING`/`DROP` 4 KiB displacement check, `MACRO`/`MEND` analyzer |
| `rpgile` | midrange | 45+ `%BIF` reference, `**FREE` & fixed-format AST outline, exact `DCL-DS` byte-offset layout (packed/zoned/16B `POINTER`), `CTL-OPT`/`EXEC SQL` linter |
| `cobol` | mainframe | `PIC`/`COMP`/`COMP-3`/`SYNC`/`REDEFINES` byte-layout calculator, Division/Paragraph CFG, `EXEC CICS` & `SQLCA` reference, fixed-format lint + live `cobc -fsyntax-only -Wall` |
| `asm` | assembly | Unified 4-ISA reference, ABI tables, snippet hazard analyzer, and cross-arch idiom translator for **POWER8+/9/10 `ppc64le`** (VSX/MMA), **`amd64`** (AVX-512/AMX), **`arm64`** (NEON/SVE2), and **`s390x`** (z16 Telum & z17 Telum II `NNPA`/`VXE2`/`DFLTCC`) |
| `intel_gpu` | gpu | Intel Xe-LP/Xe-HPG/Xe-HPC/Xe2 specs, XMX/GRF/SLM occupancy calculator, SYCL/OpenCL/Level Zero lookup, static kernel checks (+ live `ocloc` when installed) |
| `amd_gpu` | gpu | AMD CDNA2/CDNA3 (`wave64` MFMA) & RDNA3/RDNA4 (`wave32` WMMA) specs, VGPR/AGPR/LDS occupancy calculator, HIP/GCN lookup, `warpSize`/bank-conflict checks (+ live `hipcc` when installed) |
| `vulkan` | gpu | Exact `std140`/`std430`/`scalar` struct layout & C11 `_Static_assert` emitter, `VkMemoryBarrier2` sync hazard validator, Vulkan 1.0–1.4/GLSL/SPIR-V lookup, static shader checks (+ live `glslangValidator`/`spirv-val`) |
| `metal` | gpu | Apple Silicon M1–M4 (`apple7`–`apple9`) specs, SIMD-group/threadgroup occupancy calculator, MSL/`simdgroup_matrix`/TBDR lookup, `packed_float3` vs `float3` ABI checks (+ live `xcrun metal`) |

### Dual-Mode LSP Stack (`lib/NeoPerl/LSP/`, `bin/npl-lsp`, `Plugin/LSP.pm`)
- **Built-in zero-fork LSP (`NeoPerl::LSP::Builtin` & `bin/npl-lsp`)**: Speaks
  LSP 3.17 JSON-RPC 2.0 over `Content-Length` stdio (`bin/npl-lsp --lang=<domain>`)
  and runs directly in-process inside `Plugin/LSP.pm` for instant diagnostics,
  hover, completions, document symbols, and go-to-definition across all 12
  domains with zero external dependencies.
- **Automatic external LSP & compiler escalation**: `Plugin/LSP.pm`
  automatically discovers and merges diagnostics/intelligence from installed
  upstream servers and compilers, including `clangd` (C/C++/XS/HIP/SYCL/Metal),
  `cobc -fsyntax-only -Wall` (GnuCOBOL), `che-che4z-lsp-for-hlasm` /
  `hlasm-language-server`, `che-che4z-lsp-for-cobol` / `cobol-language-server`,
  `rpgle-language-server`, `asm-lsp`, `glsl_analyzer`, `glslangValidator`,
  `spirv-val`, `ocloc`, `hipcc`, and `xcrun metal`, alongside the asynchronous
  `perl -c` syntax provider.

### Perl 5 & XS Development Workbenches
- **`PerlDev`** (`lib/NeoPerl/Plugin/PerlDev.pm`): Runs `PPI`, `Perl::Critic`,
  and `Perl::Tidy` warm in-process (reusing the cached `PPI::Document` across
  outline and critic passes), providing AST outlines, workspace `gd`/`gr`,
  `if`/`af`/`]]`/`[[` motions, lexical rename (`<leader>pr`), extract-sub
  (`<leader>pe`), PPI AI context slicing, `.perlcriticrc` live diagnostics with
  tiered local/cloud auto-fix, `.perltidyrc` formatting (`:PerlTidy`,
  `:PerlTidyDiff`, `gq`), and an automatic post-tidy gate on AI-proposed Perl
  diffs.
- **`XSDev`** (`lib/NeoPerl/Plugin/XSDev.pm`): Supports local toolchains and an
  optional user-configured remote Linux SSH runner (`xs_remote_host` /
  `xs_remote_workdir` in `init.pl`). Provides Cachegrind/Callgrind and Linux
  `perf` POWER PMU gutter heatbars (`:XSCachegrind`, `:XSPerf`), isolated
  `.neoperl-build/` Valgrind Memcheck / ASan / UBSan / TSan harnesses with
  `xsubpp` `#line` mapping (`:XSVal`, `:XSAsan`, `:XSTsan`), GDB/MI3 and LLDB
  debugging (`:XSDebug`, `:XSInspectSV`, `<leader>db`), two-stage Clang/GCC PGO
  (`:XSPgo`, `:XSPgoPromote`), and POWER ELFv2 disassembly, vectorization
  reports, and portability checks (`:XSAsm`, `:XSVecReport`, `:XSPowerAudit`).

---

## Building Manually from a Checkout

### Prerequisites

- Perl 5.16+ (tested on `perl5-mt` 5.40.2 and stock Perl 5.44.0)
- A C11 compiler (`clang`, `gcc`, or MinGW-w64 UCRT64 on Windows)
- Optional runtime integrations (auto-detected via `@INC`, `NEOPERL_*_DIR`
  environment variables, or sibling checkouts):
  - `Tcl::Tk::MT` for the GPU GUI (`NeoPerl::UI::GPU`) and `IBM Plex Mono` /
    `IBM Plex Sans` fonts
  - `mojolicious-mt` (`Mojolicious` + `Mojo::MT::Accel`) for HTTP/MCP/RPC
  - `DBI::MT::Pool` + `dbd-odbc-mt` (IBM Db2 / Informix) or `dbd-sqlite-mt`
  - `PPI`, `Perl::Critic`, and `Perl::Tidy` (e.g. in `$HOME/perl5/lib/perl5`)
  - Optional external compilers/LSPs (`clangd`, `cobc`, `glslangValidator`,
    `glsl_analyzer`, `asm-lsp`, Eclipse Che4z, `ocloc`, `hipcc`, `xcrun metal`)
  - `agy` CLI (`https://antigravity.google/cli/install.sh`) and `llama-server`

### macOS (Apple Silicon / Intel)

```sh
perl Makefile.PL
make -j
make test

# Launch GPU GUI (Metal + AIX Amber + IBM Plex by default) or 24-bit TUI
./bin/npl path/to/file.pl
./bin/npl --tui path/to/file.pl

# Offline demos with ACP loopback server (or live embedded Neovim)
./bin/npl --demo --demo-scene=chat_diff --agy-mock
./bin/npl --demo --nvim-engine --agy-mock
./bin/npl --demo --demo-scene=aix_mainframe_db --agy-mock
./bin/npl --demo --demo-scene=aix_gpu_asm --agy-mock

# Standalone MCP pack server & multi-domain LSP server
./bin/npl-mcp --list-packs
./bin/npl-mcp --pack=db2z,cobol --stdio
./bin/npl-mcp --pack=all --http=127.0.0.1:8810
./bin/npl-mcp --emit-mcp-config -o .agents/mcp_config.json
./bin/npl-lsp --lang=hlasm
```

### Linux (`x86_64`, `arm64`, and IBM POWER8+ `ppc64le`)

```sh
# On ppc64le Linux, Makefile.PL automatically applies -mcpu=power8 -mvsx
# (override with NEOPERL_POWER_CPU=power9|power10|native).
perl Makefile.PL
make -j
make test

./bin/npl --tui path/to/project
```

### Windows (Win64 / MSYS2 UCRT64)

```sh
perl Makefile.PL
gmake -j
prove -b t/

perl bin/npl --backend=auto C:\path\to\workspace
```

---

## CLI Options

```
npl [options] [files_or_dir...]

  --gpu                          Force Tcl::Tk::MT::Canvas GPU GUI
  --tui                          Force 24-bit ANSI terminal TUI
  --headless                     Run without an interactive window or TTY
  --backend=auto|metal|vulkan|software
                                 Select GPU canvas backend (default: auto)
  --scale=1|2                    Retina backing scale factor (default: 2 for --screenshot)
  --theme=aix_amber|tokyonight|catppuccin|gruvbox|kanagawa
                                 Color theme (default: aix_amber)
  --agy                          Force live signed-in agy ACP auto-connect (default when agy is found)
  --no-agy                       Disable automatic Antigravity ACP startup (AGY:OFF)
  --agy-bin=PATH                 Custom path to agy CLI binary
  --agy-model=MODEL              Preferred Antigravity model ID to select on connect
  --agy-sandbox                  Pass --sandbox to agy acp for sandboxed terminal execution
  --agy-login                    Run interactive 'agy acp --login' sign-in
  --agy-mock                     Start built-in ACP loopback server for offline demos/CI
  --nvim-engine                  Embed upstream Neovim (nvim --embed) over Msgpack-RPC
  --nvim-bin=PATH                Custom path to nvim binary for --nvim-engine
  --db2-dsn=DSN                  IBM Db2 DBI/ODBC DSN for semantic memory
  --listen=ADDR                  Start JSON-RPC 2.0 server (unix/tcp/http)
  --mcp-pack=NAME[,NAME2]|all    Mount domain MCP pack(s) on startup
  --inference-mock               Force loopback inference providers (offline/CI)
  --model-dir=DIR                Override local GGUF model directory
  --ram-budget=GB                Local inference LRU RAM budget in GB
  --demo                         Populate demo workspace (splits, diffs, tabs)
  --demo-scene=chat_diff|aix_nvim_embed|aix_mainframe_db|aix_gpu_asm|memory|models|memory_bonsai|xs_cachegrind
  --screenshot=PATH.png          Export GPU framebuffer as PNG (2x Retina default) and exit
  --auto-exit-ms=N               Exit automatically after N milliseconds
  --info                         Print architecture, backends, and capabilities

npl-mcp [options]
  --list-packs                   List all 12 domain MCP packs
  --pack=<name[,name2]|all>      Select pack(s) to serve
  --stdio                        Run JSON-RPC 2.0 NDJSON MCP server on stdio
  --http=<[host:]port>           Run Streamable HTTP MCP server (Mojolicious)
  --emit-mcp-config [-o PATH]    Emit ready-to-use .agents/mcp_config.json

npl-lsp [options]
  --lang=<domain|all>            Run LSP 3.17 stdio server for a domain
  --list-langs                   List supported LSP language domains
```

---

## Status & Limitations

`NeoPerl::MT` is an active engineering distribution rather than a drop-in
replacement for upstream Neovim or full Neovim Lua plugins:

- **Unicode and editing ergonomics**: Piece-table offsets and screen columns in
  the C11 core are primarily byte-oriented; ASCII and common UTF-8 source files
  render cleanly, while double-width CJK glyphs, combining grapheme clusters,
  and soft line-wrapping still need further work.
- **Offline vs live domain tooling**: The 4 database MCP packs (`db2i`,
  `db2luw`, `db2z`, `informix`) execute guarded live queries whenever a `DBI` /
  `DBD::ODBC` DSN is supplied and provide deterministic offline catalog SQL
  builders, explain/plan analyzers, `DCLGEN` generation, and linters when no
  database connection is configured. Built-in LSP providers supply out-of-the-box
  diagnostics, hover, completion, and symbols across all 12 domains and merge
  external compilers/LSPs (`cobc`, `clangd`, etc.) automatically when installed.
- **Optional external tools**: Live Antigravity sessions require the official
  `agy` CLI, live local inference requires GGUF weights and `llama-server`, and
  live Db2 vector search requires IBM Db2 12.1.2+ with `DBD::ODBC`. All tests
  run deterministically offline via loopback providers and the SQLite test
  double.
- **Platform testing**: Interactive GPU testing has focused primarily on macOS
  (Metal and Software backends); Linux Vulkan, `ppc64le` POWER8+, and Win64
  paths are compiled and tested headless/TUI.

---

## Sample Measurements

Run the included benchmark script on your own machine:

```sh
perl -Iblib/arch -Iblib/lib bench/neoperl_bench.pl
```

Sample measurements below were recorded on one machine (`perl5-mt` 5.40.2,
Apple Silicon macOS `arm64`, 16 KiB pages, synthetic 500,001-line / 25.19 MB
Perl file, `1280x720` GPU viewport, `120x40` TUI viewport, `PPI 1.291`,
`Perl::Critic 1.156`, `Perl::Tidy 20260826`, `Mojolicious` + `Mojo::MT::Accel`).
Results will vary with hardware, OS, drivers, and workload.

| Benchmark | Sample Measurement |
|---|---|
| Cold startup (headless full stack) | 605.29 ms (RSS 142.86 MB) |
| 500,001-line Perl file open (`mmap` piece-table) | 0.39 ms (25.19 MB) |
| 500k-line GPU scroll (Metal, `1280x720`) | 140.5 FPS (p50 7.062 ms, p95 7.603 ms) |
| 500k-line GPU scroll (Software, `1280x720`) | 40.3 FPS (p50 24.804 ms, p95 25.416 ms) |
| 500k-line TUI scroll (`120x40`, 24-bit ANSI) | 97.9 FPS (p50 10.246 ms, p95 10.804 ms) |
| Incremental edit + C11 re-lex (mid-file) | p50 6.068 ms, p95 6.258 ms |
| Telescope C11 parallel grep | MT 2.88 ms vs scalar 3.99 ms |
| `VecSIMD::topk_cosine` (4,000 x 768-dim f32) | NEON 1.75 ms vs scalar 2.60 ms (bit-identical) |
| Warm `PerlDev` worker (`PPI` / `Critic` / `Tidy`) | outline 0.576 ms / critic 1.812 ms / tidy 3.466 ms |
| Antigravity ACP loopback + `EditorMCP` (23 core tools) | MCP 0.011 ms (`Mojolicious`) / ACP 0.18 ms |

---

## Acknowledgments & License

With sincere thanks to the authors, contributors, and maintainers of the open
source projects that inspired and enabled this work:

- **Bram Moolenaar**, **Vim**, and the **Neovim** project, whose modal editing
  grammar, extmark architecture, and UI design this editor follows.
- The **Perl 5** core developers and CPAN community.
- **Vadim Konovalov**, `Tcl::Tk`, and the **Tcl/Tk** developers.
- **Sebastian Riedel** and the **Mojolicious** contributors (alongside the
  `mojolicious-mt` acceleration work).
- **Tim Bunce** and the contributors to **DBI**, **DBD::SQLite**, and
  **DBD::ODBC**.
- **Adam Kennedy**, **Jeffrey Ryan Thalhammer**, **Steve Hancock**, and the
  contributors to **PPI**, **Perl::Critic**, and **Perl::Tidy**.
- **IBM** and open-source contributors behind **IBM Plex** (`IBM/plex` fonts),
  **`IBM/ibmi-mcp-server`**, **`IBM/db2-mcp-server`**, **IBM Db2**, and the
  **IBM Granite** model family.
- **Tencent** and the contributors behind **Hy-Memory** memory reconciliation
  models.
- **Broadcom / Eclipse Che4z** contributors for **`che-che4z-lsp-for-hlasm`**
  and **`che-che4z-lsp-for-cobol`**, and the **GnuCOBOL (`cobc`)** community.
- **Liam Allan** and the **`codefori`** community behind
  **`codefori/vscode-ibmi`** and **`codefori/vscode-rpgle`**.
- **Will (`bergercookie`)** and contributors to **`bergercookie/asm-lsp`**.
- **nolanderc** and contributors to **`glsl_analyzer`**, the **Khronos Group**
  (`glslang`, SPIR-V, Vulkan), **AMD ROCm/HIP**, **Intel oneAPI/SYCL**, and
  contributors to **`metal-mcp`** for Apple Metal developer workflows.
- **Georgi Gerganov** and the **llama.cpp** community, **Prism ML** for ternary
  quantization support, and the **Antigravity** CLI, **ACP**, and **MCP**
  public protocol specifications.

This software is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (the Artistic License 2.0 or the GNU General
Public License). See `LICENSE` for details.
