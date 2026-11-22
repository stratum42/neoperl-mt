# NeoPerl::MT Getting Started & Daily Use Guide

This guide walks through daily use of `NeoPerl::MT` after installing it with
[`./install.sh`](README.md#installation-installsh). Every keybinding, Ex
command, slash command, `@mention`, and CLI flag below matches the commands
registered in `bin/npl`, `lib/NeoPerl/MT.pm`, and the built-in plugins.

---

## 1. First 60 Seconds

### Verify the Installation

Run `npl --info` (add `--no-agy` if you want a fast offline check without
starting `agy`):

```sh
npl --no-agy --info
```

Check that the output lists your OS/architecture, page size (`16384` on Apple
Silicon, `65536` on `ppc64le`, `4096` on `x86_64`), available GPU backend
(`metal`, `vulkan`, or `software`), and local/remote inference status.

### Open a Project or File

```sh
# Open the current directory in the GPU GUI (falls back to TUI if headless)
npl .

# Open a specific file
npl path/to/file.pm

# Force the 24-bit ANSI terminal interface (over SSH or in a terminal multiplexer)
npl --tui path/to/file.pm

# Offline demo workspace (no network, no agy account, no local GGUF weights)
npl --demo --demo-scene=chat_diff --agy-mock
```

On macOS, if you enabled `--install-app`, you can also launch NeoPerl directly
from `/Applications/NeoPerl.app` (or `~/Applications/NeoPerl.app`) or drag
source files and project folders onto its icon.

### Vim Modal Survival Basics

NeoPerl starts in **Normal** mode (keys move and edit rather than insert
text). If you are new to modal editing, keep these basics handy:

- **Insert text**: press `i` (before cursor), `a` (after cursor), or `o` (new
  line below). Press `Esc` to return to Normal mode.
- **Move around**: `h` (left), `j` (down), `k` (up), `l` (right), `w` / `b`
  (next/previous word), `0` / `$` (start/end of line), `gg` / `G` (top/bottom
  of file).
- **Undo and redo**: `u` (undo), `Ctrl-r` (redo). NeoPerl keeps a branching
  undo tree, so `g-` / `g+`, `:earlier`, `:later`, and `:undolist` recover
  earlier edit branches.
- **Save and quit**: type `:w` then Enter to save, `:q` to quit, `:wq` to save
  and quit, or `:q!` to quit without saving.
- **Leader key and WhichKey**: `<leader>` is `Space` by default. Pause after
  pressing `Space` (or `g`, `Ctrl-w`, `]`, `[`) and the **WhichKey** popup
  shows available prefixes (`+Find`, `+Antigravity`, `+Memory`, `+Perl`,
  `+XSDev`, `+Debug`, `+Vision`, `+Git`, `+Window`) so you do not need to
  memorize bindings up front.

---

## 2. Files, Splits, Search, Git & Terminal

### File Explorer

Toggle the docked workspace file tree with `<leader>e` or `:Explorer`
(`:Explorer open`, `:Explorer close`, `:Explorer refresh`). Inside the tree:

- `j` / `k` (or arrow keys): move selection
- `Enter`, `l`, or `o`: expand/collapse folder or open file
- `h`: collapse current or parent folder
- `H`: toggle hidden dotfiles
- `R`: refresh file tree and Git status badges
- `v`: parse the selected image or PDF locally with Granite-Vision
- `q` or `Esc`: close the explorer

### Windows, Splits, Buffers & Tabs

- **Splits**: `:vsplit [file]` (vertical), `:split [file]` (horizontal),
  `:close`, `:only`.
- **Window navigation (`Ctrl-w`)**: `Ctrl-w h/j/k/l` (focus left/down/up/right),
  `Ctrl-w w` (next window), `Ctrl-w s` / `Ctrl-w v` (split), `Ctrl-w q`
  (close), `Ctrl-w o` (only window), `Ctrl-w =` (equalize split sizes).
- **Buffers**: `:edit <path>`, `:ls`, `:bnext`, `:bprev`, `:buffer <n>`,
  `:bdelete`.
- **Tabs**: `:tabnew [file]`, `:tabclose`, `gt` (next tab), `gT` (previous tab).

### Telescope Fuzzy Finder & Project Grep

- `<leader>ff` or `:Telescope files`: fuzzy file finder (parallel C11 walker)
- `<leader>fg` or `:Telescope grep`: live project grep
- `<leader>fb` or `:Telescope buffers`: open buffer switcher
- `<leader>fs` or `:Telescope symbols`: symbol outline (uses PPI on Perl files)
- `<leader>fd` or `:Telescope diagnostics`: workspace diagnostics
- `:grep <pattern>` populates the quickfix list (`:copen`, `:cnext`, `:cprev`,
  `:clist`, `:cclose`).

### Git, Embedded Terminal, Themes & Embedded Neovim

- **Git gutter & hunks**: modified lines appear in the gutter automatically.
  Use `<leader>gp` to preview the hunk at the cursor, `<leader>gr` to reset
  it, or `:Git status` and `:Git branch`.
- **Embedded terminal**: run `:terminal` to open a POSIX PTY terminal split
  inside NeoPerl.
- **Color schemes**: switch from the default `aix_amber` theme at any time:
  ```vim
  :colorscheme tokyonight
  :colorscheme catppuccin
  :colorscheme gruvbox
  :colorscheme kanagawa
  :colorscheme aix_amber
  ```
- **Optional embedded Neovim (`--nvim-engine`)**: if you have upstream `nvim`
  installed and prefer Neovim's buffer engine inside NeoPerl's AIX Amber UI
  with `EditorMCP` attached:
  ```sh
  npl --nvim-engine path/to/project
  # or specify a custom binary:
  npl --nvim-engine --nvim-bin=/path/to/nvim path/to/project
  ```
- **Perl configuration (`init.pl` and `.neoperl.pl`)**: on startup, NeoPerl
  loads `~/.config/neoperl/init.pl` (or `$XDG_CONFIG_HOME/neoperl/init.pl`, or
  `$NEOPERL_INIT`) followed by the nearest project-local `.neoperl.pl` found
  while walking upward from your working directory.

---

## 3. Antigravity (`agy`) Workflow

When the official `agy` CLI is installed, `npl` starts `agy acp` in the
background with `EditorMCP` attached and displays a compact status pill in the
top bar:

| Status Pill | Meaning | Next Step |
|---|---|---|
| `AGY:LIVE` | Connected and signed in | Open chat with `<leader>aa` or `:AgyChat` |
| `AGY:LOGIN` | `agy` found, not signed in | Run `:AgyLogin` (`<leader>aL`) or `npl --agy-login` |
| `AGY:SETUP` | `agy` CLI not installed | Run `:AgyInstall` (`:AgyInstall!` runs in a terminal split) |
| `AGY:MOCK` | Offline loopback mode | Launched with `--agy-mock` |
| `AGY:OFF` | Antigravity disabled | Launched with `--no-agy` |

### Checking Status, Signing In & Managing Sessions

- `:AgyDoctor` (alias `:AgyStatus`): prints `agy` binary path, authentication
  state, active model, attached `EditorMCP` tool count, and next step.
- `:AgyLogin` (or `<leader>aL`): authenticates via ACP RPC; `:AgyLogin!` opens
  an embedded terminal split running `agy acp --login` and reconnects
  automatically when sign-in completes.
- `:AgyModel` (or `<leader>aM`): opens the Telescope model picker (or pass a
  model ID directly with `:AgyModel <model-id>`).
- `:AgyNewSession`, `:AgyResume <session-id>`, and `:AgyReconnect`: manage ACP
  sessions without restarting `npl`.
- `<leader>fa`: opens a Telescope picker over discovered Antigravity skills,
  rules, and MCP configs.

### Chat, `@mentions`, Slash Commands & Inline Diff Review

Open or toggle the right-hand `CHAT` tab with `<leader>aa`, or send a prompt
directly with `:AgyChat <prompt>`.

Prompts expand built-in `@mentions` before sending:

- `@buffer`: active buffer text
- `@selection`: current visual selection
- `@diag`: current workspace/buffer diagnostics
- `@file:<path>`: file contents from disk
- `@memory:<query>`: top semantic memory hits (underscores become spaces)
- `@image:<path>` / `@pdf:<path>`: local Granite-Vision Markdown/OCR text
  (no raw base64 images are sent over ACP)
- `@skill:<name>`: matching skill body from workspace/global customizations

Prompts may also begin with a slash command:

- `/plan <task>`: request a concise step-by-step plan before editing
- `/fix <issue>`: diagnose and propose a minimal diff fix
- `/test <target>`: generate focused unit tests
- `/doc <target>`: write concise documentation
- `/remember <fact>`: store a fact directly into semantic memory
- `/compact`: compact conversation context
- `/clear`: clear chat messages, thought cards, tool cards, and plan entries

When Antigravity requests tool execution approval, use the permission bar keys
in the `CHAT` tab: `a` (**Allow** once), `A` (**Always** allow), or `r`
(**Reject**).

When an edit proposal arrives via `EditorMCP`, NeoPerl paints inline red/green
diff hunks directly into the buffer:

- `]h` / `[h`: jump to next / previous diff hunk
- `<leader>ay` / `<leader>an`: accept / reject the hunk at the cursor
- `<leader>aY` / `<leader>aN`: accept / reject all pending hunks in the buffer

For offline testing or demos without an account, pass `--agy-mock`:

```sh
npl --agy-mock path/to/project
```

---

## 4. Local Inference & Offload Queue

NeoPerl manages four optional local GGUF model roles within a configurable LRU
RAM budget (`--ram-budget=GB`, `--model-dir=DIR`):

| Role | Default Model | Purpose |
|---|---|---|
| `embedder` | `nomic-embed-text-v1.5.Q8_0.gguf` | Pinned 768-dim embeddings (`libllama` in-process or `llama-server`) |
| `memory_writer` | `Hy-Memory-30B-A3B-Q8_0-expsIQ2_XXS.gguf` | Post-turn `ADD` / `NOOP` / `UPDATE` / `SUPERSEDE` memory reconciliation |
| `vision_doc` | `granite-vision-4.1-4b-Q4_K_M.gguf` + `mmproj` | Local PNG/PDF/clipboard OCR and Markdown extraction |
| `worker_small` | `Ternary-Bonsai-2-27B-PTQ1_0.gguf` | Out-of-band POD docs, comments, commit messages, mechanical fixes |

### Inspecting and Pulling Local Models

On supported GPU hosts (Apple Silicon Metal, NVIDIA CUDA, discrete AMD ROCm):

1. Run `:InferenceDoctor` or `:ModelHub` to inspect detected `llama-server` /
   `prism-llama-server` binaries, `libllama` availability, and downloaded GGUF
   weights.
2. Download weights for one role or all four:
   ```vim
   :ModelPull embedder
   :ModelPull vision_doc
   :ModelPull all
   ```
   Use `:ModelPull! <role>` to force a re-download.

### Out-of-Band Bonsai Jobs, Inline Edits, Auto-Fix & Ghost Text

- `:AgyJobs` or `<leader>aj`: toggle the `MODELS` Command Center tab to view
  resident RAM slots, LRU evictions, active Ternary-Bonsai jobs, syntax check
  status (`perl -c`), and cloud tokens saved.
- `Ctrl-I`, `<leader>ai`, or `:AgyInline <instruction>`: run an inline edit
  command and stage the resulting diff hunks in the buffer.
- `<leader>af` or `:AgyFix`: tiered diagnostic auto-fix at the cursor
  (routes mechanical `Perl::Critic` issues to local Ternary-Bonsai at zero
  cloud tokens, and escalates structural issues to `agy`).
- `Tab` in Insert mode: accept an inline ghost-text completion when displayed.

### Local Vision Document Parsing

Parse screenshots, diagrams, or PDFs locally with Granite-Vision and cache the
Markdown output by SHA-256 in `NPL_DOC_CACHE`:

- `:VisionParse path/to/diagram.png` (or a PDF path)
- `:VisionParse clipboard` or `<leader>vp` (parse an image from the clipboard)
- Press `v` on any image or PDF inside File Explorer (`<leader>e`)
- Reference `@image:path/to/diagram.png` or `@pdf:path/to/spec.pdf` inside chat

### Remote GPU Offload on POWER, AIX & CPU-Only Linux

On IBM POWER (`ppc64le`), AIX, macOS `x86_64`, and CPU-only Linux hosts, local
GGUF inference is skipped automatically so `npl` uses zero local model RAM. To
offload any role to a remote OpenAI-compatible `llama-server` over HTTP:

```sh
export NEOPERL_EMBED_URL="http://gpu-host:8081/v1"
export NEOPERL_HYMEM_URL="http://gpu-host:8082/v1"
export NEOPERL_VISION_URL="http://gpu-host:8083/v1"
export NEOPERL_BONSAI_URL="http://gpu-host:8084/v1"
npl path/to/project
```

To force offline loopback providers on any machine (for CI or debugging), pass
`--inference-mock` or set `NEOPERL_INFERENCE_MOCK=1`.

---

## 5. Semantic Memory (IBM Db2 or SQLite)

NeoPerl stores project decisions, conventions, and troubleshooting notes in
either **IBM Db2 12.1.2+** (`VECTOR` + `VECTOR_DISTANCE` via `DBD::ODBC`) or
an automatic local **SQLite + C11 SIMD** fallback when no Db2 DSN is passed.

### Daily Memory Commands

- `:MemSave <fact>`: explicitly save a note or decision to semantic memory
- `:MemSearch <query>`: hybrid lexical + vector search in the `MEMORY` tab
- `:MemBrowse` or `<leader>am`: toggle the `MEMORY` Command Center tab
- `<leader>fm`: fuzzy-search saved semantic memories in Telescope
- `:MemAutoContext on` / `:MemAutoContext off`: enable or disable automatic
  injection of a compact memory context hint (`<= 250` tokens) before chat
  prompts

### `.memignore` & Automatic Secret Redaction

Before any text reaches local memory reconciliation or database storage,
`NeoPerl::Memory::MemIgnore` skips paths matching `.memignore` (built-in
defaults exclude `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`,
`*.kdbx`, `id_rsa*`, `id_ed25519*`, `id_ecdsa`, `*secret*`, `*credentials*`,
`.netrc`, `.pgpass`, `*.jks`, and `*.keystore`) and automatically redacts PEM
private keys, AWS access keys, GitHub/Slack/Google API tokens, Bearer tokens,
and URI credentials. Add project-specific path patterns to a `.memignore` file
in your repository root.

### Connecting the Local IBM Db2 Container

If you ran `./install.sh --setup-db2` (or `scripts/setup-db2-container.sh`),
the installer created mode-`0600` credentials in `~/.config/neoperl/db2.env`
and `~/.config/neoperl/odbc.ini` plus the `npl-db2-ctl` helper:

```sh
# Check or start the local Db2 container
npl-db2-ctl status
npl-db2-ctl start

# Load ODBCINI and NEOPERL_DB2_DSN into your shell and launch npl
. ~/.config/neoperl/db2.env
npl --db2-dsn="$NEOPERL_DB2_DSN" path/to/project
```

Other `npl-db2-ctl` subcommands: `stop`, `logs`, `shell` (interactive
`db2inst1` shell), and `apply-schema` (re-applies `schema/db2_memory.sql`).

---

## 6. Perl IDE & XS Systems Workflows

### Perl 5 Development (`PerlDev`)

When `PPI`, `Perl::Critic`, and `Perl::Tidy` are installed (for example via
`./install.sh --with-cpan-tools`), `PerlDev` keeps them warm in-process and
reuses the parsed `PPI::Document` across outline and critic passes:

- **Navigation & outline**: `:PerlOutline` (`<leader>fs`), `gd` (go to
  definition), `gr` (workspace references), `K` (hover).
- **Perl text objects & motions**: `if` / `af` (inner/around subroutine),
  `ip` / `ap` (inner/around package), `]]` / `[[` (next/previous `sub`).
- **Linting & fixes**: `:PerlCritic` (populates diagnostics and quickfix),
  `:PerlCriticSeverity <1-5>`, `:PerlCriticFix` (tiered local/cloud auto-fix),
  `]d` / `[d` (next/previous diagnostic).
- **Formatting & refactoring**: `:PerlTidy` (`<leader>pf` or `gq`),
  `:PerlTidyDiff` (stages formatting edits as reviewable inline diff hunks),
  `:PerlRename <new_var>` (`<leader>pr`, scope-safe lexical rename),
  `:PerlExtractSub <name>` (or visual select + `<leader>pe`), and `:PerlSlice`
  (computes a compact PPI context slice around the cursor).

### C / XS Profiling, Sanitizers, Debugging, PGO & POWER (`XSDev`)

Open the `XSDEV` Command Center tab anytime with `<leader>xd`.

- **Profiling**:
  - `:XSCachegrind <cmd...>`: runs Cachegrind, paints gutter heatbars, and
    opens the hotspot picker (`<leader>xc`).
  - `:XSPerf <cmd...>`: runs Linux `perf` / IBM POWER PMU hardware counters.
- **Sanitizers** (compiled in isolated `.neoperl-build/` directories with
  `xsubpp` `#line` mapping back to `.xs`):
  - `:XSVal <cmd...>`: Valgrind Memcheck with Perl suppressions
  - `:XSAsan [c_file]`: ASan + UBSan harness
  - `:XSTsan [c_file]`: TSan harness
- **Debugging (GDB/MI3 & LLDB)**:
  - `:XSDebug [binary] [break_func]`: opens `XSDEV` and captures backtraces
  - `:XSInspectSV <expr>`: dumps Perl `SV*`/`AV*`/`HV*` via `Perl_sv_dump`
  - Breakpoints & stepping: `<leader>db` (toggle gutter breakpoint),
    `<leader>dn` (step over), `<leader>di` (step into), `<leader>do`
    (step out), `<leader>dc` (continue).
- **Two-stage PGO & IBM POWER ELFv2 analysis**:
  - `:XSPgo [c_file]` and `:XSPgoPromote [dest_binary]`
  - `:XSAsm <object_or_binary>` (`<leader>xa`): side-by-side ELFv2 disassembly
    highlighting VSX, TOC, and memory barriers
  - `:XSVecReport [c_file]`: inline loop vectorization annotations
  - `:XSPowerAudit [file]`: checks C/XS source for unsigned-`char`, 64 KiB
    page, weak memory-ordering, SMT spin-yield, and `<altivec.h>` traps.

---

## 7. Domain MCP Packs & Built-In LSPs

### Selective Domain MCP Packs

All 12 domain packs (`db2i`, `db2luw`, `db2z`, `informix`, `hlasm`, `rpgile`,
`cobol`, `asm`, `intel_gpu`, `amd_gpu`, `vulkan`, `metal`) stay unmounted by
default so `EditorMCP` exposes only the 23 core tools until you opt in:

- Inside NeoPerl: press `<leader>mp` (or `:McpPacks`) to open the pack picker,
  or run `:McpPackEnable db2z,cobol`, `:McpPackDisable cobol`, or
  `:McpConfigEmit .agents/mcp_config.json`.
- At startup: `npl --mcp-pack=db2z,hlasm,cobol path/to/project` (or
  `--mcp-pack=all`).
- Standalone MCP server (`npl-mcp`):
  ```sh
  npl-mcp --list-packs
  npl-mcp --pack=db2z,cobol --stdio
  npl-mcp --pack=all --http=127.0.0.1:8810
  npl-mcp --emit-mcp-config -o .agents/mcp_config.json
  ```

### Built-In & External LSP Servers

NeoPerl includes a built-in 12-domain LSP plus asynchronous `perl -c` checks
and automatically escalates to installed external servers/compilers (`clangd`,
`cobc`, Che4z HLASM/COBOL, `rpgle-language-server`, `asm-lsp`,
`glsl_analyzer`, `glslangValidator`, `spirv-val`, `ocloc`, `hipcc`,
`xcrun metal`):

- Inside NeoPerl: `:LspInfo`, `:LspStart [server]`, `:LspStop [server]`.
- Standalone LSP stdio server (`npl-lsp`) for use from other editors:
  ```sh
  npl-lsp --list-langs
  npl-lsp --lang=hlasm
  npl-lsp --lang=all
  ```

---

## 8. Quick-Reference Tables & Troubleshooting

### Keybinding Quick Reference (`<leader>` = `Space`)

| Keys | Mode | Action |
|---|---|---|
| `<leader>e` | Normal | Toggle File Explorer |
| `<leader>ff` / `<leader>fg` | Normal | Telescope find files / live grep |
| `<leader>fb` / `<leader>fs` / `<leader>fd` | Normal | Telescope buffers / symbols (PPI outline) / diagnostics |
| `<leader>aa` / `<leader>am` / `<leader>aj` / `<leader>xd` | Normal | Toggle Command Center tab: `CHAT` / `MEMORY` / `MODELS` / `XSDEV` |
| `<leader>aL` / `<leader>aM` | Normal | Antigravity sign-in (`:AgyLogin`) / model picker (`:AgyModel`) |
| `Ctrl-I` / `<leader>ai` | Normal | Inline edit command (`:AgyInline`) |
| `<leader>af` | Normal | Tiered diagnostic auto-fix (`:AgyFix`) |
| `]h` / `[h` | Normal | Jump to next / previous diff hunk |
| `<leader>ay` / `<leader>an` | Normal | Accept / reject diff hunk at cursor |
| `<leader>aY` / `<leader>aN` | Normal | Accept / reject all diff hunks in buffer |
| `<leader>fm` / `<leader>fa` | Normal | Telescope Db2 memories / Antigravity customizations |
| `<leader>vp` | Normal | Parse clipboard image via Granite-Vision |
| `<leader>gp` / `<leader>gr` | Normal | Preview / reset Git hunk at cursor |
| `<leader>pf` / `<leader>pr` | Normal | `:PerlTidy` buffer / `:PerlRename` hint |
| `<leader>pe` | Visual | Extract visual selection into Perl `sub` |
| `gd` / `gr` / `K` | Normal | Go to definition / references / hover |
| `]d` / `[d`, `]]` / `[[` | Normal | Next/prev diagnostic; next/prev Perl `sub` |
| `<leader>xc` / `<leader>xa` | Normal | Cachegrind hotspot picker / `:XSAsm` hint |
| `<leader>db` / `dn` / `di` / `do` / `dc` | Normal | Debugger breakpoint / step over / step into / step out / continue |
| `<leader>mp` | Normal | Open MCP Domain Pack picker (`:McpPacks`) |
| `a` / `A` / `r` | `CHAT` bar | Allow / Always allow / Reject pending ACP tool permission |
| `Tab` | Insert | Accept ghost-text completion |

### Common Ex Commands

| Group | Commands |
|---|---|
| Core & layout | `:w`, `:q`, `:wq`, `:e <file>`, `:split`, `:vsplit`, `:close`, `:only`, `:tabnew`, `:ls`, `:bnext`, `:bprev`, `:grep`, `:copen`, `:terminal`, `:colorscheme <name>`, `:undolist`, `:earlier`, `:later` |
| Antigravity | `:AgyChat [prompt]`, `:AgyDoctor`, `:AgyStatus`, `:AgyLogin[!]`, `:AgyInstall[!]`, `:AgyModel [id]`, `:AgyNewSession`, `:AgyResume <id>`, `:AgyReconnect`, `:AgyInline <inst>`, `:AgyFix`, `:AgyJobs` |
| Local AI & Vision | `:ModelHub`, `:InferenceDoctor`, `:ModelPull[!] <role\|all>`, `:VisionParse <path\|clipboard>` |
| Memory | `:MemSave <fact>`, `:MemSearch <query>`, `:MemBrowse`, `:MemAutoContext on\|off` |
| PerlDev | `:PerlOutline`, `:PerlCritic`, `:PerlCriticSeverity <1-5>`, `:PerlCriticFix`, `:PerlTidy`, `:PerlTidyDiff`, `:PerlRename <var>`, `:PerlExtractSub <name>`, `:PerlSlice` |
| XSDev | `:XSCachegrind <cmd>`, `:XSPerf <cmd>`, `:XSVal <cmd>`, `:XSAsan [file]`, `:XSTsan [file]`, `:XSDebug [bin] [fn]`, `:XSInspectSV <expr>`, `:XSPgo [file]`, `:XSPgoPromote`, `:XSAsm <bin>`, `:XSVecReport [file]`, `:XSPowerAudit [file]` |
| MCP & LSP | `:McpPacks`, `:McpPackEnable <name\|all>`, `:McpPackDisable <name\|all>`, `:McpConfigEmit [path]`, `:LspInfo`, `:LspStart [name]`, `:LspStop [name]` |

### Troubleshooting

- **`npl` not found after `./install.sh`**: check the PATH mode you selected.
  For `--path-mode=local`, make sure `~/.local/bin` is in `PATH` and open a new
  shell (or run `export PATH="$HOME/.local/neoperl/bin:$PATH"`).
- **No GUI window or running over SSH**: launch with `npl --tui`, or test the
  CPU canvas backend with `npl --gpu --backend=software`.
- **Top bar shows `AGY:SETUP` or `AGY:LOGIN`**: run `:AgyDoctor` inside NeoPerl
  for exact details. Install with `./install.sh --install-agy` (or
  `:AgyInstall!`), then sign in once with `npl --agy-login` (or `:AgyLogin!`).
  Pass `--no-agy` to work without `agy`, or `--agy-mock` for offline demos.
- **Local AI reports `skipped` on Linux or IBM POWER**: expected on `ppc64le`,
  AIX, macOS `x86_64`, and CPU-only Linux hosts. Configure `NEOPERL_EMBED_URL`,
  `NEOPERL_HYMEM_URL`, `NEOPERL_VISION_URL`, and `NEOPERL_BONSAI_URL` to point
  at a remote `llama-server` host, or set `NEOPERL_ALLOW_CPU_LOCAL_AI=1` if you
  explicitly want CPU-only local inference.
- **Missing IBM Plex fonts in the GPU GUI**: NeoPerl falls back to system
  monospace/sans fonts automatically. Install IBM Plex anytime with
  `./install.sh --components=neoperl --use-existing-perl="$HOME/.local/neoperl/bin/perl" --with-fonts --no-pgo --path-mode=none --yes`
  or from `https://github.com/IBM/plex/releases`.
- **Local Db2 container takes a few minutes on first start**: cold Db2 database
  initialization takes 2–5 minutes (longer under Rosetta emulation on Apple
  Silicon). Monitor progress with `npl-db2-ctl logs -f` and verify readiness
  with `npl-db2-ctl status`.
