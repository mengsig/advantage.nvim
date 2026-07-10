# ✦ advantage.nvim

Not a chatbot. Not a CLI bolted onto your editor. advantage is a full agent loop
*forged into* Neovim — it streams from the model, seizes your editor's tools,
feeds on the fallout, and keeps swinging until the task is dead.

- **Runs on your subscription.** Uses your **Claude Code login** (Pro/Max) or your
  **Codex / ChatGPT login** — no API key needed. Env API keys work as a fallback.
- **Model agnostic.** Anthropic (Opus 4.8, Sonnet 5, Fable 5, Haiku 4.5) and
  OpenAI GPT/Codex (GPT-5.6 Sol, Terra, Luna, gpt-5.5, and the gpt-5.1-codex
  family) out of the box; the provider interface is ~100 lines if you want to add more.
- **Editor-native tools.** `read_file`, `edit_file`, `write_file`, `bash`, `grep`,
  `find_files`, `list_dir`, `diagnostics`, `sub_agent`, `web_search` — executed
  inside Neovim, so edited buffers reload live, edits get an **LSP/linter feedback
  loop**, and every mutation is gated behind a permission card with a real diff.
- **Semantic code navigation (LSP).** `document_symbols`, `goto_definition`,
  `find_references`, `hover`, `workspace_symbol` — the model traverses your code
  through the **language servers your editor already runs**, finding a definition,
  every call site, a file's outline or a type signature in a handful of tokens
  instead of grepping and reading whole files. This is the single biggest token
  saver here and something a CLI harness structurally can't do.
- **A UI that respects your colorscheme.** No hardcoded palette: the panel is a
  quiet surface a few percent off your background, the prompt a slightly deeper
  field with a `❯` gutter caret, and the accent, washes and dim tones are all
  derived from *your* theme at runtime. One accent, used sparingly: finished
  tool calls fade into the transcript, only the live action carries color, and
  each exchange opens on a hairline.

```
──────────────────────────────────────────────────────────
▍ you                                                 14:02
add a --json flag to the export command

✦ opus 4.8                                  ↑12.4k ↓1.1k · 41s
I'll look at the current flag handling first.

  · read_file  src/cli/export.lua
  ⠹ bash  just test cli

Added the flag and threaded it through the formatter…
```

## Benchmark — harness quality vs. Claude Code

A recurring worry with an in-editor harness is that its own agent loop (its
system prompt, tools, and context/compaction machinery) might be *worse* than a
mature CLI harness. So we measured it: advantage's real agent loop, driven
headlessly, against the **Claude Code agent loop** — **same model** (Opus 4.8,
8k-token thinking budget), **same fixtures**, **same task prompt**, graded by
identical hidden test suites. Each grader was validated first (a correct
reference implementation scores 1.0; an empty stub scores 0.0).

Three deliberately hard, objectively-scored fixtures:

| Fixture | What it stresses | advantage.nvim | Claude Code |
| --- | --- | :---: | :---: |
| **SQL engine** — 4 files, 6 planted bugs (49-case grader) | multi-file navigation + iterative debugging | **1.000** | **1.000** |
| **Regex engine** — from scratch (562-case fuzz vs Python `re`) | algorithm design + self-testing loop | **0.998** | **0.998** |
| **Piece-table buffer** — undo/redo (28,957-check fuzz) | index math + test-driven iteration | **1.000** | **1.000** |

**The two harnesses were indistinguishable in quality.** Even the single regex
miss (a `.`-vs-newline spec edge case) was identical on both. advantage matched
Claude Code here *without a language server attached* in headless mode — i.e.
without its biggest structural advantage.

Output tokens generated per task — the model's actual generation cost, and the
one token metric that's cleanly comparable across harnesses (input on both sides
is dominated by prompt-cache reads, so it's left out):

| Fixture | advantage.nvim | Claude Code |
| --- | :---: | :---: |
| SQL engine | **5.6k** | 16.4k |
| Regex engine | **12.2k** | 28.8k |
| Piece-table | **1.4k** | 7.0k |

Same quality, and advantage reached it with **2–5× fewer generated tokens** on
every task.

**Compaction stress test.** The one place an in-editor harness could plausibly
lose ground is context compaction (Claude Code has native long context;
advantage summarizes old history). Forcing the LLM summarizer to fire
aggressively mid-task (tiny recent-message window) triggered two real
summarizations that discarded the early file reads — and advantage **still scored
1.000** on the multi-file SQL task. The compaction machinery does not drop
task-critical state.

## Requirements

- Neovim **0.10+**
- `curl`
- logged in to the [`claude`](https://github.com/anthropics/claude-code) CLI
  and/or [`codex`](https://github.com/openai/codex) CLI — or
  `$ANTHROPIC_API_KEY` / `$OPENAI_API_KEY`
- `ripgrep` (optional, for fast `grep` / `find_files`)
- a language server per language (optional but recommended — powers the semantic
  navigation tools and the edit diagnostics loop; see the suggested list below)

## Install

```lua
-- lazy.nvim
{
  "mengsig/advantage.nvim",
  cmd = "Advantage",
  keys = {
    { "<leader>cc", function() require("advantage").toggle() end, desc = "advantage: toggle" },
    { "<leader>cn", function() require("advantage").new_session() end, desc = "advantage: new session" },
    { "<leader>cm", function() require("advantage").pick_model() end, desc = "advantage: model" },
    { "<leader>cr", function() require("advantage").resume() end, desc = "advantage: resume" },
    { "<leader>cf", function() require("advantage").add_file() end, desc = "advantage: add current file" },
    { "<leader>cp", function() require("advantage").pick_files() end, desc = "advantage: pick file" },
    { "<leader>cP", function() require("advantage").context("preview") end, desc = "advantage: preview context packet" },
    { "<leader>cl", function() require("advantage").add_location() end, desc = "advantage: add cursor location" },
    { "<leader>cs", function() require("advantage").add_selection() end, mode = "x", desc = "advantage: add selection" },
    { "<leader>cu", function() require("advantage").usage() end, desc = "advantage: usage" },
    { "<leader>cd", function() require("advantage").review() end, desc = "advantage: review changes" },
    { "<leader>cy", function() require("advantage").toggle_yolo() end, desc = "advantage: toggle yolo" },
    { "<leader>ce", function() require("advantage").pick_effort() end, desc = "advantage: tune effort" },
    { "<leader>c?", function() require("advantage").help() end, desc = "advantage: help" },
  },
  opts = {},
}
```

## Auth — how the subscription login works

advantage never asks for a key. Per provider, in order:

| provider  | 1st choice                                                            | fallback              |
| --------- | --------------------------------------------------------------------- | --------------------- |
| anthropic | Claude Code OAuth (`~/.claude/.credentials.json`), auto-refreshed      | `$ANTHROPIC_API_KEY`  |
| openai    | Codex CLI OAuth (`~/.codex/auth.json`), auto-refreshed                 | `$OPENAI_API_KEY`     |

Refreshed tokens are written back to the CLI's own credential file so `claude`
and `codex` keep working. The winbar shows which credential is in use
(`max`, `pro`, `chatgpt`, or `api`).

OpenAI's login and API-key paths are different transports with different model
catalogues, context windows, and effort levels. `providers.openai.auth_mode`
defaults to `"auto"` (prefer a usable Codex/ChatGPT login, otherwise use an API
key). Set it to `"chatgpt"` or `"api_key"` to require that transport instead of
falling back to the other one. The effort picker and context budgeting use the
same transport choice; the server remains authoritative about which model IDs
your particular account can access.

Output budgeting is transport-aware too. GPT-5.6/5.5 ChatGPT-login requests do
not expose a per-request output cap, so advantage reserves the model's native
128k maximum when deciding when to compact. Raw API requests send and reserve
`providers.openai.max_output_tokens` (64k by default).

`providers.openai.reasoning_summary = "auto"` streams the provider-selected
reasoning summary into the thinking UI. Use `"concise"` or `"detailed"` to
request a specific depth, or `false` to omit summaries and reduce overhead.
Read-only scouts and compaction summarizers disable summaries automatically
because their thinking output is not shown.

> macOS note: Claude Code stores credentials in the Keychain there, not in
> `.credentials.json` — use the API-key fallback or run `claude setup-token`.

## Usage

`:Advantage` opens the panel. Type in the prompt, `⏎` sends immediately. If a
turn is already running, Enter does **not** cancel it: the message is injected
before the next tool call, like Claude Code. Use `⌃s` to queue a message until
the agent is completely done with its current flow; queued messages dispatch one
by one after the flow finishes (`⌃c` cancels the turn *and* drops the queue). The
prompt grows with your message as you type.

| where  | key            | action                                    |
| ------ | -------------- | ----------------------------------------- |
| prompt | `⏎`            | send now (before next tool call if running) |
| prompt | `⌃s`           | queue until the agent is completely done  |
| prompt | `⇧⏎` / `⌃j`    | newline                                   |
| prompt | `@`            | complete a project file to mention        |
| prompt | `⌃v`           | paste — clipboard images become attachments |
| prompt | `⌃u` / `⌃d`    | scroll the chat (normal mode)             |
| chat   | `i a o` / `⇥`  | jump to prompt                            |
| both   | `⌃c`           | cancel the running turn                   |
| both   | `q`            | hide the panel                            |
| chat   | `]]` / `[[`    | next / previous turn                      |
| both   | `g?`           | help                                      |

**Context.** `@path/to/file` mentions are inlined into the message on send
(fenced, with the filename). `@file:L10-20` (or `:L10`) inlines **exactly those
lines** with their location, so the agent edits precisely what you point at.
`<leader>cf` sends the current file (from netrw it sends all files marked
with `mf`; ranged `:Advantage add` in netrw sends selected listing lines),
`<leader>cl` adds the exact cursor line, and `<leader>cp` picks a file from the
project. Visual `<leader>cs` references the selection as `@file:L10-20` — the
lines are read fresh from disk on send.

**Images.** `⌃v` in the prompt attaches a clipboard image (Wayland `wl-paste`,
X11 `xclip`, macOS `pngpaste`) and drops a `[image: …]` chip into the text —
delete the chip to detach. `:Advantage attach shot.png` attaches a file.

**Slash commands** in the prompt: `/usage` · `/compact` · `/context` · `/review` ·
`/yolo` · `/effort` · `/new` · `/model` · `/resume` · `/help`.

**Review mode.** The agent snapshots every file before its first edit. After a
turn that changed files you'll see *"n files changed — /review to inspect"*:
`/review` (or `:Advantage review`, `<leader>cd`) lists the changes with `+/−`
counts, and opens either one unified diff of everything or a real side-by-side
vimdiff tab per file — before on the left (read-only), the live file on the
right (editable), `q` closes. With no agent changes it falls back to `git diff`.

**YOLO mode.** `/yolo` (or `:Advantage yolo [on|off]`, `<leader>cy`, or
`tools = { yolo = true }` / `dangerously_skip_permissions = true` in setup)
skips *all* permission cards. A red `⚡ yolo` badge stays in the winbar while
it's on. Use at your own risk.

**Effort / thinking.** `/effort` (or `/effort high`,
`:Advantage effort [mode]`, `<leader>ce`) tunes the active model before the next
turn. The choices are model- and transport-aware:

- Current OpenAI/Codex models use `reasoning.effort`. Subscription GPT-5.6 Sol
  and Terra expose `low` through `ultra`, Luna through `max`, and GPT-5.5 through
  `xhigh`; API-key profiles expose their declared API levels. `default` removes
  the per-model override and inherits `providers.openai.reasoning_effort`
  (`ultra` by default). An inherited value is clamped downward to the deepest
  level that model/transport supports—Sol stays `ultra` on login, Luna becomes
  `max`, GPT-5.5 becomes `xhigh`, and raw-API Sol becomes `max`. An explicit
  unsupported per-model choice remains an error. `off` is an alias for the
  explicit API value `none` and is only
  offered when that model/transport supports it — merely omitting `reasoning`
  would restore the provider default, not turn reasoning off.
- Modern Claude models use native adaptive thinking plus
  `output_config.effort` (`low`/`medium`/`high`/`xhigh`/`max`). Opus 4.8 is
  explicitly enabled adaptively, Sonnet 5's default-on mode is explicitly
  disabled when you choose `off`, and Fable 5 cannot be disabled, so `off` is
  not offered for it.
- Haiku 4.5 and older manual-thinking Claude models retain fixed budgets:
  `low`=`1k`, `medium`=`4k`, `high`=`8k`, `higher`=`10k`, `highest`=`16k`, and
  `max`=`32k` (aliases include `think`, `think-hard`, `think-harder`, and
  `ultrathink`).

**Usage dashboard.** `/usage` (or `:Advantage usage`, `<leader>cu`) shows
session/today/7-day token totals, cache savings (cached input bills at ~10%, and
the dashboard shows how much that saved you), a sparkline, your current pace, a
projection to midnight, and — if you set `usage.daily_budget` — the time you'll
run out at the current pace. A `harness` line reports what the repo memory
injects per turn and how many tokens the on-demand skill design saved versus
inlining every skill body into every request — so the harness's token thesis is
measured, not asserted.

**Context compaction.** Old transcript history is automatically compacted when
its estimated size (roughly chars/4) crosses a threshold that **scales to the
active model's effective window**: `min(context.compact_fraction × window,
context.compact_at_tokens, window − output allowance − system/tool schemas −
context.request_safety_tokens)`. For OpenAI, `window` is selected from
`context_window` (ChatGPT/Codex login) or `api_context_window` (raw API key).
The fraction protects a small-window model (it
compacts before it overflows) while `compact_at_tokens` is an absolute **cost
ceiling** so a 1M-context model never carries ~750k raw tokens every turn. The
newest messages stay verbatim — bounded by both `keep_recent_messages` and a
token budget (`keep_recent_fraction` of the threshold) so a few huge tool
outputs can't keep the retained window above the threshold; older user asks,
assistant text, tool calls and results become one summary message. Compaction
runs in one of two modes:

- **Silent auto-compact** (a background threshold crossing mid-turn) defaults to
  a free, offline heuristic — a one-line-per-message truncation. No extra model
  call, so a turn you didn't ask to pay for never gets a surprise network
  round-trip added to it. Set `context.auto_compact_mode = "llm"` to opt into the
  same LLM summarizer for automatic compaction.
- **Manual compaction** (`/compact` or `:Advantage compact`) defaults to
  spending one call on a summarizer model so it writes a
  dense, structured summary — primary intent, files touched, decisions, pending
  work — from the *untruncated* older transcript. By default the summarizer is a
  model **in your active model's provider family** (Haiku for Claude; the active
  model for OpenAI/Codex), so a Codex-only user never triggers a Claude request
  they have no credentials for; pin one with `context.summarizer_model`.
  Subscription and API model catalogues can differ: if a pinned summarizer
  returns HTTP 404 / model-not-found, advantage retries once with the **active
  model on the same provider** using `context.summarizer_effort` (`medium` by
  default, a deliberate compression-quality/latency balance). Set it to
  `inherit` when compaction must match the live effort, or pin a lower level to make it cheaper. The
  compaction notice names the fallback.
  The **original task prompt is preserved verbatim** through every compaction
  (both modes), so long sessions never drift off what you asked for. If the LLM
  attempt and any active-model retry fail, it falls back to the offline heuristic
  automatically and shows a warning. Run
  `/compact heuristic` (or `:Advantage compact heuristic`) to skip the model
  call and use the free heuristic instead for a single invocation, or set
  `context.compact_mode = "heuristic"` to make that the default everywhere.

**Semantic navigation (LSP).** advantage exposes the language servers your editor
already runs as read-only tools, so the agent navigates code *semantically*
instead of grepping and reading whole files:

- `document_symbols` — a file's outline (functions/classes/methods + lines, with
  signatures) without its text. Also reachable as `read_file` with `outline=true`.
  Falls back to a **local Treesitter parse** when the language server is slow,
  still indexing, or absent — so an outline is always instant and never depends on
  a server that's timing out (the classic big-TypeScript-project failure mode).
- `goto_definition` — jump from a use of a symbol to where it's defined.
- `find_references` — every call site of a symbol across the project.
- `hover` — the type signature and doc for a symbol at a position.
- `workspace_symbol` — find a symbol by name anywhere in the repo.

Each hop costs a handful of tokens instead of a grep-plus-read-the-results loop —
the biggest token lever in the harness, and one a CLI-only agent structurally
can't pull. All are read-only (no permission card) and automatically available to
sub-agents. Requests are async with a bounded timeout, so a slow server never
freezes the editor — and because the *first* request to a freshly-opened file
often times out while the server builds its initial index, a timed-out request
**auto-retries** (with an extended window) rather than costing the model a turn.
`workspace_symbol` shows **in-project matches first** and collapses stdlib/dependency
hits to a count (a real workspace index is dominated by library symbols — noise for
navigating your repo). Positions are offset-encoding-correct (utf-8/utf-16/utf-32),
so navigation is precise even on lines with multi-byte characters.

The harness doesn't just *offer* these tools — it **steers** the model to prefer
them: a guidance block is injected into the (cached) system prompt telling it to
reach for semantic navigation first on any symbol-level question, and to fall back
to `grep`/`read_file` only when no server is attached or the target is plain text.
That steer is added **only when the tools are actually live** (enabled and this
Neovim has `vim.lsp`), so a setup without language servers never sees advice for
tools it can't run — and the whole tool set is likewise hidden from the model's
schema when `tools.lsp.enabled = false` or `vim.lsp` is absent. Because a frozen
system-prompt steer loses salience as a session grows (the model pattern-matches
its own recent grep/read behavior), a throttled **in-band nudge** re-surfaces the
tools from a `grep`/`read_file` result when the model has been exploring code
without them — but only while a server is actually running, and silenced the
moment it uses one.

Two failure modes are handled explicitly, because both otherwise trained the model
to abandon LSP silently: **(1) slow attach** — a heavy server (tsserver/vtsls in a
monorepo, jdtls, rust-analyzer) can take seconds just to attach to a freshly-opened
file, so when a server *is* configured for the filetype the tool waits
`attach_grace_configured_ms` for it (and fails fast when none is configured); and
**(2) no server at all** — instead of a silent grep-fallback, the tool tells **you**
(once per filetype, in the transcript) that the language isn't set up for
navigation, so you know to install a server rather than wondering why it keeps
grepping.

These tools only work as well as the language server behind them. Install and
enable a server for each language you work in (via
[`nvim-lspconfig`](https://github.com/neovim/nvim-lspconfig) +
[`mason.nvim`](https://github.com/williamboman/mason.nvim), or your own
`vim.lsp.enable` setup). Suggested servers for full-language support:

| language              | server (binary / mason name)                              |
| --------------------- | --------------------------------------------------------- |
| Python                | `pyright` (or `basedpyright`) · `ruff` for lint/format    |
| C / C++ / Objective-C | `clangd`                                                  |
| Rust                  | `rust-analyzer`                                            |
| Zig                   | `zls`                                                      |
| Go                    | `gopls`                                                   |
| C# / .NET             | `omnisharp` (or `csharp-ls`)                               |
| JavaScript / TS / TSX | `vtsls` (or `typescript-language-server`)                 |
| Lua                   | `lua-language-server` (`lua_ls`)                           |
| Java                  | `jdtls`                                                    |
| Ruby                  | `ruby-lsp` (or `solargraph`)                               |
| PHP                   | `intelephense` (or `phpactor`)                             |
| Kotlin                | `kotlin-language-server`                                   |
| Swift                 | `sourcekit-lsp`                                            |
| Bash / shell          | `bash-language-server`                                     |
| HTML / CSS / JSON     | `vscode-langservers-extracted`                            |
| YAML                  | `yaml-language-server`                                     |
| TOML                  | `taplo`                                                    |
| Elixir                | `elixir-ls` (or `lexical`)                                 |
| Haskell               | `haskell-language-server`                                  |
| Scala                 | `metals`                                                   |
| Terraform             | `terraform-ls`                                             |
| Markdown              | `marksman`                                                 |

Tune with `tools = { lsp = { enabled = true, timeout_ms = 4000, attach_grace_ms
= 1000, max_results = 60 } }`. `attach_grace_ms` is how long a request waits for a
server to attach to a freshly-opened file; `max_results` caps symbols/references
returned per call.

minimum install
```lua
    ◍ marksman (keywords: markdown)
    ◍ codebook (keywords: c, css, go, html, haskell, java, javascript, lua, markdown, php, plain, python, ruby, rust, toml, typescript)
    ◍ yaml-language-server yamlls (keywords: yaml)
    ◍ omnisharp (keywords: c#)
    ◍ ast-grep ast_grep (keywords: c, c++, rust, go, java, python, c#, javascript, jsx, typescript, html, css, kotlin, dart, lua)
    ◍ rust-analyzer rust_analyzer (keywords: rust)
    ◍ bash-language-server bashls (keywords: bash, csh, ksh, sh, zsh)
    ◍ biome (keywords: json, javascript, typescript)
    ◍ clangd (keywords: c, c++)
    ◍ lua-language-server lua_ls (keywords: lua)
    ◍ pyright (keywords: python)
    ◍ stylua (keywords: lua, luau)
    ◍ zls (keywords: zig)
```

**Sharper search.** `grep` takes an `output_mode`: `content` (default,
`file:line:text`), `files_with_matches` (just the paths — cheapest when you only
need locations), or `count` (per-file match counts), plus `head_limit` to cap
output lines and `ignore_case`. The model asks for exactly the shape it needs
instead of always paying for full match text.

**Diagnostics feedback loop.** After the agent edits a file, the **newly-introduced**
LSP/linter diagnostics are appended straight to that tool's result, so the model
sees compile/type/lint errors and self-corrects instead of guessing a build
command. It's context-disciplined by design: only errors are shown by default
(`tools.diagnostics.severity`), capped at `max` lines, **diffed against the
pre-edit state** so pre-existing noise is never re-reported, and a clean edit adds
**nothing**. A no-LSP repo pays **zero** per-edit overhead — when a touched file
has no server for its filetype the plugin skips the work entirely and instead
**deterministically tells you** (once per filetype) to install a language server
— as a **persistent** line in the chat transcript (plus a WARN toast), so you
won't miss it if you stepped away — rather than routing that through the model. The model also gets an explicit
`diagnostics` tool to check any file or your open files on demand. Turn it off
with `tools = { diagnostics = { enabled = false } }` (or just the auto-attach with
`auto = false`).

**Sub-agents.** The model has a `sub_agent` tool for read-only fan-out: a worker
gets its own short loop and can use read/search/list tools, then returns a
concise report to the parent agent. It cannot edit files. A model may call one
worker and wait (sequential delegation) or emit several `sub_agent` calls in one
turn; with `subagents.parallel = true`, a same-turn fan-out runs
**concurrently** and overlaps network latency. Parallelism is supported, not
required, and setting `parallel = false` makes batches run sequentially. Fan-out
is bounded by `max_parallel` concurrent streams, `max_per_batch` workers in one
response, and `max_per_turn` workers cumulatively across the whole parent turn;
reports share a `max_result_bytes` parent-context budget, each scout request is
held to `max_output_tokens` on Anthropic/raw-API transports, and excess work is
reported explicitly instead of growing without limit. ChatGPT-login scouts keep
the model's native output reserve because that transport has no confirmed hard
cap field; their turn, delegation, result, and report limits still bound them.
Scouts default to
`subagents.effort = "medium"` rather than inheriting an expensive parent setting;
each `sub_agent` call can override `effort` or request `"inherit"`. Sub-agents
run on a **lean context**: they get the base instructions (and the read-only tool set,
including the LSP navigation tools) but **not** the repo-memory block or skills
index — a scout can't `remember`/`use_skill` anyway, and re-shipping the full
learned context to every worker (and to each worker of a parallel fan-out,
cold-cached) is exactly the token leak fan-out exists to avoid. Their returned
report is size-capped before it's spliced into the parent transcript, so a chatty
worker can't bloat the parent's context.

**Web search.** A `web_search` tool backed by the [Brave Search
API](https://api.search.brave.com) — one lightweight GET request, no
page-scraping step, results returned as compact `title — url` + snippet lines
(HTML stripped, capped at `max_results`, hard ceiling 10). Needs an API key
(Brave's free tier covers casual use): set `$BRAVE_API_KEY` or
`tools.web_search.api_key`. **Without a key the tool is hidden from the schema
entirely** — the model never wastes a turn calling a search tool that can't
work. It's `safe` (no permission prompt, like `grep`/`read_file`) and
automatically available to read-only sub-agents.

**Repo memory & skills (self-learning harness).** advantage keeps a lightweight,
per-repo memory so the agent gets *better and cheaper* at your codebase over time.

- As it works, the agent calls a `remember` tool to save durable, non-obvious
  facts — architecture invariants, conventions, build/test commands, gotchas, or
  a preference you state ("always run the linter before committing"). You can also
  just tell it to remember something. Facts are deduplicated and kept under a token
  budget so the file never bloats.
- Memory is rendered into the **cached** system prefix, so after the first turn it
  costs ~10% — and it *saves* tokens by sparing the model repeated read/grep loops
  to re-derive what it already learned.
- **Two tiers by cost.** `context.md` is the *always-loaded* tier — crisp one-line
  signposts and load-bearing invariants, held to `memory.budget_tokens`. **Depth**
  lives in **skills** (below): unbounded storage at ~one index line of always-loaded
  cost, pulled in full only when needed. This is deliberate: the always-loaded tier
  is a recurring per-turn tax, so it stays lean while total knowledge grows in the
  on-demand tier. When a fact gets too verbose, the `remember` tool tells the agent
  (in the tool result, never the cached prefix) to move its detail into a skill and
  leave a crisp pointer — and nudges you (persistently) to `/context curate`.
- **Skills** are reusable named procedures *and* deep-dive knowledge. Only a one-line
  index (name + description) is always in context — itself budgeted
  (`memory.skills_index_budget_tokens`) so a big library can't re-bloat the prefix,
  with deterministic truncation that keeps the cache stable; skills past the cap stay
  loadable by name. The full body loads on demand when the agent calls `use_skill`.
  The agent codifies new ones with `save_skill`. Skills interoperate with
  `.claude/skills/`.
- Skills are also **auto-surfaced**: a deterministic keyword match against your
  prompt appends a one-line hint to the outgoing message when a skill looks
  relevant ("the deploy-docs skill may apply — load it with use_skill"), at most
  once per skill per session. The hint rides the message, never the system
  prompt, so the cached prefix stays byte-identical.
- Your committed `AGENTS.md` / `CLAUDE.md` is ingested too (parity with the real
  CLIs), with `@file` imports resolved.
- **Add your own standing instructions** by dropping any Markdown file into
  `<repo>/.advantage/` — every `.advantage/<name>.md` is injected verbatim into
  the system prompt (name-sorted so the frozen prefix stays cache-stable, each
  budget-capped by `memory.config_budget_tokens`). No code change, no tool call:
  create `.advantage/style.md`, `.advantage/review-rules.md`, etc. and the agent
  reads them every turn. **`context.md` is the one name you cannot use this way** —
  it is the managed memory file (owned by the `remember`/`curate` machinery), so
  it is deliberately excluded from config-doc ingestion; put hand-authored
  instructions in any *other* `.md` file instead.
- Everything is deterministic and offline — no embeddings, no second model
  validating anything. Files live in `<repo>/.advantage/` (a plain, editable
  Markdown `context.md` plus `skills/`).
- The memory file is **bootstrapped on first use**: opening a session in a fresh
  repo seeds `context.md` with the managed skeleton so it's visible, editable and
  committable from day one, and an empty memory nudges the model in-prompt to
  start recording — the flywheel starts on session one, not never.
- **`/context init`** (the `claude /init` equivalent) has the agent explore the
  repo — README, manifests, layout, tests, CI — and populate the memory in one
  pass: verified build/test commands, architecture facts, conventions, gotchas,
  plus a skill for any 3+-step flow. Run it once in a new repo and session one
  starts with an analyzed repo map instead of a cold start.

- The memory **compresses itself**: `remember` rejects multi-step procedures at
  the source (steering them to `save_skill`, where they cost one index line
  instead of their full length every turn); when the budget forces an eviction
  the agent is told exactly which facts fell out so it can rescue them into
  skills or tighter phrasing; and `/context curate` runs a full compression
  pass — merge duplicates, drop stale facts, extract runbooks into skills,
  rewrite `context.md` in place (you approve the diff).

`/context` (or `:Advantage context`) shows the current memory; `/context init`
teaches the agent the repo in one pass; `/context curate` compresses it;
`/context verify` flags facts whose referenced files have since moved or
vanished; `/context forget <text>` drops matching facts. Turn it off with
`memory = { enabled = false }`.

**Context preview.** `/context preview` (or `:Advantage context preview`,
`<leader>cP`) renders the exact packet that goes to the model each turn — the
system prompt, the tool schemas, and the transcript — with the cache boundary
drawn and a per-section token breakdown. Nothing is sent: it's pure
observability, so you can see what each part costs, confirm the memory block is
frozen for prompt-cache reuse, and catch a bloated `context.md` before it costs
you (it also shows the exact system-prompt bytes at the bottom).

Commands: `:Advantage` (toggle) · `new` · `model` · `resume` · `stop` · `usage` ·
`compact` · `context` · `help` · `review` · `yolo [on|off]` · `effort` · `add` ·
`files` · `attach {path}` · `ask {prompt}` (works with a visual range: `:'<,'>Advantage ask why is this slow?`).

When the model wants to **edit a file or run a command**, a floating card shows
exactly what will happen — a unified diff for edits, the command for bash —
and waits for `a` (allow), `A` (always allow this tool this session), `d` (deny),
or `c` (**deny with a comment**: tell the agent what to do instead; your feedback
is sent back to the model). Read-only tools never prompt.

**Sandboxing.** All file tools — including the permission-card previews, which
read the target before you approve anything — are confined to the project root:
absolute paths and `..` traversal outside it are rejected, and the resolved
path is checked with `realpath` so a symlink can't smuggle the agent outside the
root either. Set `tools = { allow_outside_root = true }` if you genuinely want
the agent reading and writing anywhere your user can (bash remains
permission-gated either way).

**Planning & batch edits.** For multi-step work the model keeps a live checklist
with `todo_write` (rendered in the transcript as ✓/▶/· items), and several
changes to one file arrive as a single atomic `multi_edit` — one diff card, one
approval; if any edit in the batch fails to match, nothing is written.

## Configuration (defaults)

```lua
require("advantage").setup({
  default_model = "anthropic/claude-opus-4-8",
  models = {                       -- context_window scales compaction per model;
                                   -- OpenAI context_window = ChatGPT/Codex login;
                                   -- api_context_window = raw API-key transport
    { ref = "anthropic/claude-opus-4-8", label = "opus 4.8", context_window = 1000000,
      max_output_tokens = 128000,
      thinking_mode = "adaptive", effort_levels = { "low", "medium", "high", "xhigh", "max" } },
    { ref = "anthropic/claude-sonnet-5", label = "sonnet 5", context_window = 1000000,
      max_output_tokens = 128000,
      thinking_mode = "adaptive_default", effort_levels = { "low", "medium", "high", "xhigh", "max" } },
    { ref = "anthropic/claude-fable-5", label = "fable 5", context_window = 1000000,
      max_output_tokens = 128000,
      thinking_mode = "adaptive_always", effort_levels = { "low", "medium", "high", "xhigh", "max" } },
    { ref = "anthropic/claude-haiku-4-5", label = "haiku 4.5", thinking = false,
      thinking_mode = "manual", context_window = 200000, max_output_tokens = 64000 },
    { ref = "openai/gpt-5.6-sol", label = "gpt-5.6 sol", context_window = 372000,
      api_context_window = 1050000, max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max", "ultra" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh", "max" } },
    { ref = "openai/gpt-5.6-terra", label = "gpt-5.6 terra", context_window = 372000,
      api_context_window = 1050000, max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max", "ultra" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh", "max" } },
    { ref = "openai/gpt-5.6-luna", label = "gpt-5.6 luna", context_window = 372000,
      api_context_window = 1050000, max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh", "max" } },
    { ref = "openai/gpt-5.5", label = "gpt-5.5", context_window = 272000,
      api_context_window = 1050000, max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh" } },
    { ref = "openai/gpt-5.1-codex", label = "codex 5.1", context_window = 400000,
      max_output_tokens = 64000,
      reasoning_efforts = { "low", "medium", "high", "xhigh" } },
    { ref = "openai/gpt-5.1-codex-mini", label = "codex mini", context_window = 400000,
      max_output_tokens = 64000,
      reasoning_efforts = { "low", "medium", "high", "xhigh" } },
  },
  providers = {
    anthropic = {
      max_tokens = 64000,         -- shared visible-answer + thinking ceiling
      interleaved_thinking = true,
    },
    openai = {
      auth_mode = "auto",         -- "auto" | "chatgpt" | "api_key"
      max_output_tokens = 64000,  -- raw API request cap; login reserves model max
      reasoning_effort = "ultra", -- inherited + clamped per model/transport
      reasoning_summary = "auto", -- "auto" | "concise" | "detailed" | false
    },
  },
  system_prompt = nil,           -- string to replace, function(default) to extend
  max_agent_turns = 100,         -- safety cap on tool-loop round-trips per user turn
  ui = {
    width = 0.42,                -- panel width (fraction of columns)
    input_height = 4,
    border = "rounded",
    accent = nil,                -- hex override; default derives from your colorscheme
  },
  tools = {
    auto_approve = {},           -- e.g. { bash = true } — at your own risk
    allow_outside_root = false,  -- file tools confined to the project root
    yolo = false,                -- skip ALL permission prompts (/yolo toggles)
    bash_timeout_ms = 120000,
    stream_bash_output = false,  -- or per-call: bash { stream = true }
    diagnostics = {              -- editor-native LSP/linter feedback loop
      enabled = true,            -- false hides the diagnostics tool + auto-attach
      auto = true,               -- append new diagnostics to edit results
      severity = "error",        -- auto-attach floor: "error" | "warn"
      max = 10,                  -- cap on diagnostic lines appended per edit
      wait_ms = 1500,            -- ceiling waiting for the LSP to re-analyze
      attach_grace_ms = 250,     -- wait for a server to attach before giving up
      notify_missing = true,     -- once-per-filetype "install an LSP" nudge to you
    },
    lsp = {                      -- semantic navigation tools (document_symbols,
                                 -- goto_definition, find_references, hover,
                                 -- workspace_symbol); hidden from the schema when
                                 -- disabled or this Neovim has no vim.lsp
      enabled = true,
      timeout_ms = 4000,         -- per-request ceiling before a timeout (extended on retry)
      max_attempts = 2,          -- auto-retry a TIMED-OUT request (server still indexing)
      attach_grace_ms = 1000,    -- wait for attach when NO server is configured (fail fast)
      attach_grace_configured_ms = 4000, -- but wait longer when one IS configured but slow
                                 -- to attach (tsserver/vtsls/jdtls in a big project)
      max_results = 60,          -- cap on symbols / references / matches per call
    },
    web_search = {               -- Brave Search API; hidden from the schema with no key
      enabled = true,
      api_key_env = "BRAVE_API_KEY", -- or set api_key directly below
      api_key = nil,
      base_url = "https://api.search.brave.com/res/v1/web/search",
      max_results = 5,            -- default result count (hard cap: 10)
      timeout_ms = 15000,
    },
  },
  context = {
    auto_compact = true,
    compact_fraction = 0.75,     -- compact at this % of the model's context_window
    compact_at_tokens = 200000,  -- absolute cost ceiling on that trigger (chars/4)
    request_safety_tokens = 8192, -- beyond output + system/tool reservations
    keep_recent_messages = 16,   -- newest kept verbatim, also bounded by:
    keep_recent_fraction = 0.4,  -- recent window kept, as a % of the threshold
    summary_max_chars = 12000,   -- heuristic-mode summary cap
    auto_compact_mode = "heuristic", -- auto-compact: "heuristic" | "llm"
    compact_mode = "llm",        -- manual /compact: "llm" | "heuristic"
    summarizer_model = nil,      -- nil = auto: a model in the ACTIVE provider's family
                                 -- (so a Codex-only user never needs Claude creds
                                 -- to /compact). A 404 retries the active same-provider
                                 -- model before heuristic. Set a ref to pin one.
    summarizer_models = {        -- omitted providers use the active model
      anthropic = "anthropic/claude-haiku-4-5",
    },
    summarizer_effort = "medium", -- OpenAI: balanced compaction; "inherit" matches live effort
  },
  subagents = {
    enabled = true,              -- exposes the read-only `sub_agent` tool
    model = nil,                 -- nil = parent's model; set a fast model
                                 -- (e.g. "anthropic/claude-haiku-4-5") for cheaper fan-out
    max_turns = 12,              -- per-sub-agent turn budget (last turn is report-only,
                                 -- so a scout always returns findings, not an empty error)
    max_per_turn = 12,           -- cumulative scouts across the whole parent turn
    max_output_tokens = 16000,   -- per-scout Anthropic/raw-API output ceiling
    effort = "medium",           -- per-call `effort` can override; "inherit" uses parent
    parallel = true,             -- support concurrent fan-out; false preserves sequential runs
    max_parallel = 4,            -- concurrent provider streams; excess scouts queue
    max_per_batch = 8,           -- bounded same-response fan-out
    max_result_bytes = 64000,    -- shared parent-context budget for batch results
  },
  memory = {                     -- per-repo self-learning harness (remember/use_skill)
    enabled = true,
    budget_tokens = 2000,        -- cap on the always-loaded facts block (crisp signposts;
                                 -- push DEPTH into on-demand skills, not this tier)
    skill_body_budget_tokens = 8000, -- cap for on-demand use_skill bodies
    skills_index_budget_tokens = 1200, -- cap on the always-loaded skills index; skills past
                                 -- it stay loadable by name (deterministic truncation)
    project_budget_tokens = 2000,-- cap on ingested AGENTS.md / CLAUDE.md
    config_budget_tokens = 2000, -- per-file cap on user-authored .advantage/<name>.md docs
    dedupe_threshold = 0.8,      -- word-overlap ratio above which a fact is a duplicate
  },
  keymaps = {                    -- set to "" to disable any of these
    toggle = "<leader>cc",
    new_session = "<leader>cn",
    models = "<leader>cm",
    resume = "<leader>cr",
    add_selection = "<leader>cs", -- visual mode: @file:L10-20
    add_file = "<leader>cf",      -- send current file to the prompt
    add_location = "<leader>cl",  -- send @file:L{cursor line}
    pick_files = "<leader>cp",    -- pick a project file to send
    usage = "<leader>cu",         -- token usage dashboard
    review = "<leader>cd",        -- review agent changes (diff)
    yolo = "<leader>cy",          -- toggle skip-all-permissions
    effort = "<leader>ce",        -- tune reasoning effort / thinking
    help = "<leader>c?",          -- keybind & command cheatsheet
  },
  usage = {
    daily_budget = nil,          -- tokens/day; enables run-out projections in /usage
  },
  sessions = { autosave = true }, -- saved per-project, resume with :Advantage resume
})
```

## Notes

- Sessions are stored under `stdpath("data")/advantage/sessions`, scoped per
  project directory.
- Claude thinking requests follow each generation's actual contract: modern
  models use adaptive thinking and `output_config.effort`, while Haiku 4.5 uses
  manual budgets. Summarized reasoning streams into the transcript, dimmed. The
  interleaved-thinking beta is sent so reasoning persists across tool calls
  within a turn; disable with
  `providers = { anthropic = { interleaved_thinking = false } }` if your account
  rejects it.
- OpenAI Responses calls use a stable per-chat `prompt_cache_key`; the ChatGPT
  transport also keeps one stable `session_id` across the tool loop. Together
  with the frozen system prefix, this preserves provider cache/session routing
  instead of defeating it with a new identifier every request.
- Codex subscription access goes through the same backend the codex CLI uses;
  model availability can differ from the raw API catalogue. The API-key path is
  selected with `providers.openai.auth_mode = "api_key"` when needed.
- Request bodies and credentials are passed to curl via files/stdin, never
  argv, so nothing sensitive shows up in the process list.

## Development

```sh
nvim -l tests/smoke.lua   # parser, providers, tools, and a full fake-provider turn
stylua --check .          # formatting (config in stylua.toml)
```

CI (`.github/workflows/ci.yml`) runs the smoke suite on Neovim 0.10/stable/nightly
and checks formatting on every push.

## Roadmap

- compaction checkpoint restore (undo a compaction / inspect what was folded in)
- relevance-filtered memory injection (per-turn fact subsetting by touched paths)
