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
  `find_files`, `list_dir`, `diagnostics`, `sub_agent`, `sub_agent_batch`, `web_search`, `web_fetch` — executed
  inside Neovim, so edited buffers reload live, edits get an **LSP/linter feedback
  loop**, and every mutation is gated behind a permission card with a real diff.
- **Semantic code navigation (LSP).** `document_symbols`, `goto_definition`,
  `find_references`, `hover`, `workspace_symbol` — the model traverses your code
  through the **language servers your editor already runs**. When a server is
  attached, exact definitions, references, outlines, and types can avoid broad
  grep-and-read discovery loops.
- **Optional NavGraph navigation.** Enable the first-class `navgraph` tool to
  give both the parent and read-only scouts bounded symbol, call, reference,
  import, route, path, and hot-spot queries. It executes argv directly
  (never a shell), fixes the root to the project, disables cache writes, rejects
  Git-backed history/diff, mutating/server commands, and external reads, and
  stays out of the baseline schema when disabled or unavailable. Once enabled
  and executable, both the parent and read-only scouts automatically receive
  the typed tool plus a conditional routing guide. The model still decides
  whether to call it and is instructed to abstain for known-file and greenfield
  work; availability never forces a ceremonial query. Indexed queries run with
  `--no-cache` and therefore reindex—a deliberate no-workspace-writes tradeoff
  on very large repositories—while commands that negotiate themselves as
  no-index/cacheless omit that inapplicable flag. A selected call runs the configured external executable,
  so trust it and prefer an absolute pin to prevent PATH shadowing. Before the
  tool is exposed, Advantage negotiates and validates
  `navgraph.capabilities.v1`, freezes the safe read-only intersection for that
  executable identity, and fails closed on incompatible contracts. The exact
  frozen `84986b8` benchmark binary has a SHA-256-gated legacy fallback; unknown
  pre-contract binaries do not. This release still executes the conservative
  one-shot CLI adapter. It detects and records availability of NavGraph's newer
  typed `navgraph.query` MCP surface but does not yet claim or use that transport.
  Compact name-only discovery and one-shot full-definition source are the
  defaults. Typed command options, focused-query validation, merged line-range
  caps, and replay-safe receipt aging keep graph evidence from accumulating
  beside ordinary reads or being replayed for the rest of the conversation.
  Claude's signed tool continuations remain byte-identical until their current
  tool loop closes; aging then resumes without risking an Anthropic 400.
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

## Benchmark — exact quality with current NavGraph available

On 12 July 2026, the harness ran a fresh, balanced eight-cell matrix: four
hidden-graded tasks under Advantage and the same four with the current NavGraph
integration available. Every first attempt completed normally with
`openai/gpt-5.6-sol`, `xhigh` effort, and the `xhigh` harness through one
ChatGPT login. Both arms scored an exact **400/400**, and all **35/35** matrix
integrity checks and all quality-gate checks passed.

| Harness | Hidden score | Exact | Gross input | Cached | Uncached | Output | Reasoning¹ | Requests | Elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Advantage** | **400/400** | **4/4** | 3,720,488 | 3,088,896 | 631,592 | 92,285 | 34,145 | 144 | 30.36m |
| **Advantage + NavGraph available** | **400/400** | **4/4** | 3,771,391 | 3,196,928 | **574,463** | **83,587** | **22,618** | **133** | **25.54m** |
| **Default Codex reference · retained 11 Jul** | **400/400** | **4/4** | 6,531,475 | 6,201,856 | 329,619 | 69,039 | 24,627 | — | 31.36m |

Default Codex was not rerun for this matrix. Its validated 11 July artifacts are
shown as a labeled cross-epoch reference; task inputs, prompts, seeds, model,
effort, and timeout match, but date, provider cache/load, runner, and plugin
provenance do not. Its request count was not captured.

Relative to the contemporaneous control, the NavGraph-available arm used 9.0%
less uncached input, 9.4% less output, 33.8% less reasoning, 7.6% fewer requests,
and 15.9% less wall time, while gross input rose 1.4% because cached input rose
3.5%. This is a valid **availability observation**, not yet a semantic NavGraph
efficiency result: only one task received successful graph results, two tasks
abstained, and NG-CLI's one selected call was rejected before execution.

Each task cell is `score · gross / uncached input · requests · elapsed`.

| Task | Advantage | Advantage + NavGraph available | Default Codex · retained 11 Jul | NavGraph lifecycle |
|---|---:|---:|---:|---|
| NG-CLI | 100/100 · 773,679 / 151,087 · 39 · 6.23m | 100/100 · **525,137 / 132,945 · 31 · 4.20m** | 100/100 · 1,025,566 / 65,310 · — · 3.98m | attempted; 1 selected, 0 semantic successes |
| NG-POLYGLOT | 100/100 · **1,613,819** / 235,515 · **50 · 9.54m** | 100/100 · 2,064,870 / **177,126** · 52 · 11.04m | 100/100 · 2,427,190 / 105,526 · — · 7.42m | adopted; 9 selected, 5 semantic successes |
| NG-SCOPE | 100/100 · 1,139,514 / **203,578** · 39 · 8.81m | 100/100 · **970,975** / 214,239 · **31 · 5.32m** | 100/100 · 2,821,288 / 127,144 · — · 10.22m | abstained |
| PIECE-TABLE | 100/100 · **193,476 / 41,412 · 16** · 5.78m | 100/100 · 210,409 / 50,153 · 19 · **4.98m** | 100/100 · 257,431 / 31,639 · — · 9.74m | abstained |

### What the run establishes

Quality is restored across the complete suite: both arms passed all 6 NG-SCOPE,
9 NG-CLI, 10 NG-POLYGLOT, and 57 PieceTable hidden cases. Exposure remained
conditional and model-selected. All ten NavGraph selections came from scouts;
parents made zero selections. Five calls produced semantic results and five were
rejected before spawn (three oversized reads and two invalid inputs). The five
semantic CLI calls completed without wrapper failure in 234ms and returned
16,851 bytes. Four per-run capability probes took another 41ms and returned
93,464 bytes.

The analyzer therefore reports
`valid_matrix_with_navgraph_execution_failure`: the matrix and quality gate are
valid, but NG-CLI attempted NavGraph without receiving any successful semantic
result. Aggregate treatment/control differences mix one adopted task, two
abstentions, one failed attempt, and normal model variance. They must not be
presented as proof that semantic retrieval itself caused the savings.

After this matrix was frozen, the live adapter was hardened against the two
one-shot failure classes it exposed: negotiated `--` handling now preserves
flag-shaped literal targets, and oversized valid reads return an explicit
bounded prefix instead of being discarded. It also honors newer manifest
commands that declare themselves no-index/cacheless without sending an
unsupported `--no-cache`. Those follow-up fixes pass the complete smoke suite
and direct installed-binary integration checks. Capability startup now also
fails closed on non-executable/spawn-race pins without a second timeout, and
bounded output preserves source while oversized diagnostics remain errors.
These changes are intentionally not back-projected into the v2 measurements
above.

### Method and limits

The matrix used a balanced order, one first attempt per task and arm, a
1,200-second cap, an empty-home `bwrap` sandbox, and deterministic post-run
graders with no LLM judge. Prompt, seed, task suite, plugin, runner, source
archive, capabilities, and binary identities were frozen and reconciled. The
NavGraph arm used commit `d5eab29e0c90b275fd8d250b0be34b7daf301215`
through Advantage's negotiated one-shot read-only CLI adapter with `--no-cache`.
The typed `navgraph.query` MCP surface was available but not used, and Java was
present in the capability manifest but was not behaviorally exercised.

This is one stochastic repetition per task, not a confidence interval. The
current binary postdates the historical NavGraph task fixes, so this matrix is
also **not leakage-controlled** for those tasks. Gross input includes cached
input; reasoning is already included in output. The machine-readable source of
truth and every frozen artifact are in
[`2026-07-12-current-navgraph-pair-xhigh-v2`](.benchmarks/harness_compare/results/2026-07-12-current-navgraph-pair-xhigh-v2).
Older Advantage/NavGraph token tables remain archived but are deprecated as
headline evidence. The retained 11 July Default Codex run is included above
only as a labeled cross-epoch reference and is not mixed into the
contemporaneous treatment/control claims.

¹ Reasoning tokens are already included in output tokens.

## Requirements

- Neovim **0.10+**
- `curl`
- logged in to the [`claude`](https://github.com/anthropics/claude-code) CLI
  and/or [`codex`](https://github.com/openai/codex) CLI — or
  `$ANTHROPIC_API_KEY` / `$OPENAI_API_KEY`
- `ripgrep` (optional, for fast `grep` / `find_files`)
- [`NavGraph`](https://github.com/mengsig/NavGraph) (optional, for the opt-in
  `navgraph` tool; Advantage negotiates `navgraph.capabilities.v1` and pins a
  read-only policy intersection for each executable identity; pin an absolute
  executable path for reproducible environments)
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
    { "<leader>ch", function() require("advantage").pick_harness() end, desc = "advantage: harness mode" },
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
`/yolo` · `/effort` · `/harness` · `/new` · `/model` · `/resume` · `/help`.

**Review mode.** The agent snapshots every file before its first edit. After a
turn that changed files you'll see *"n files changed — /review to inspect"*:
`/review` (or `:Advantage review`, `<leader>cd`) lists the changes with `+/−`
counts, and opens either one unified diff of everything or a real side-by-side
vimdiff tab per file — before on the left (read-only), the live file on the
right (editable), `q` closes. With no agent changes it falls back to `git diff`.

**Deterministic verification.** Advantage maintains project-local gates in
`.advantage/verification.json` (commit it with the project):

```json
{"version":1,"commands":["stylua --check .","nvim -l tests/smoke.lua"]}
```

A compact initial-prompt rule tells the agent to update this file only after a
check is confirmed by repository/CI configuration or a successful run—never to
invent or weaken checks. The manifest is snapshotted at the start of each user
turn, so edits activate on the next turn and cannot move the goalposts during a
repair. A new or changed manifest hash needs one permission-card approval before
execution; the approval persists for that exact project and content hash.
Commands run in order after a clean response with file-tool changes and stop at
the first failure. Bounded evidence gets at most `max_repairs` same-conversation
repair attempts. Read-only turns, refusals, truncated responses, and absent or
empty manifests pay no gate cost. Explicit `verification.commands` override the
manifest and remain trusted user configuration.

**YOLO mode.** `/yolo` (or `:Advantage yolo [on|off]`, `<leader>cy`, or
`tools = { yolo = true }` / `dangerously_skip_permissions = true` in setup)
skips *all* permission cards. A red `⚡ yolo` badge stays in the winbar while
it's on. Use at your own risk.

**Effort / thinking.** `/effort` (or `/effort high`,
`:Advantage effort [mode]`, `<leader>ce`) tunes the active model before the next
turn. The choices are model- and transport-aware:

- Current OpenAI/Codex models use the real wire-level `reasoning.effort` values.
  Sol/Terra/Luna expose through `max`, GPT-5.5 through `xhigh`, and API-key
  profiles expose their declared API levels. `default` removes the per-model
  override and inherits `providers.openai.reasoning_effort` (`max` by default).
  Inherited values clamp to the deepest level that model/transport supports. An explicit
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

**Harness mode.** `/harness` (or `:Advantage harness [mode]`, `<leader>ch`)
controls orchestration separately from model reasoning. Selecting an explicit
preset initializes the corresponding effort, but `/effort` can then override it
without changing the harness. `auto` follows the active effort.

| Mode | Orchestration policy |
|---|---|
| `low` | Direct work; scouts execute sequentially |
| `medium` | Selective delegation with modest concurrency |
| `high` | Proactively split clearly independent investigations |
| `xhigh` | Deep parent reasoning with selective, task-sized fan-out |
| `max` | Maximum parent depth; delegation stays deliberate |
| `ultra` | Max reasoning; proactive parallelism only when work divides cleanly |

`subagents.parallel = false` keeps every harness mode sequential, while
`max_parallel` remains a concurrency width rather than a spawn quota.

**Usage dashboard.** `/usage` (or `:Advantage usage`, `<leader>cu`) shows
session/today/7-day token totals, provider-reported cache reuse, a sparkline,
your current pace, a projection to midnight, and — if you set
`usage.daily_budget` — the time you'll run out at the current pace. A `harness`
line reports what repo memory injects per turn and the counterfactual context
avoided by loading skill bodies on demand instead of inlining every skill into
every request. Actual billing and cache discounts depend on the active provider,
transport, model, and account.

**Context compaction.** Old transcript history is automatically compacted when
its estimated size (roughly chars/4) crosses a threshold that **scales to the
active model's effective window**: `min(context.compact_fraction × window,
context.compact_at_tokens, window − output allowance − system/tool schemas −
context.request_safety_tokens)`. For OpenAI, `window` is selected from
`context_window` (ChatGPT/Codex login) or `api_context_window` (raw API key).
The fraction protects a small-window model (it
compacts before it overflows) while `compact_at_tokens` is an absolute recurring
**context ceiling** that helps prevent very large histories from being replayed
on every turn. The
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
  Messages submitted while manual compaction is running enter the normal queue
  and dispatch automatically once the compacted transcript is safely adopted.
  During an active Claude extended-thinking tool continuation, receipt mutation
  and compaction wait until the assistant closes that continuous tool turn; the
  latest signed thinking blocks and preceding context must remain unmodified.

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

When the target is resolvable, a semantic hop can replace a broader
grep-plus-read-the-results loop. All are read-only (no permission card) and automatically available to
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
concise report to the parent agent. It cannot edit files, run shell commands,
create fixtures, or execute a CLI; runtime testing stays in the parent. A model may call one
worker and wait (sequential delegation), emit several `sub_agent` calls in one
turn, or use `sub_agent_batch` with an explicit `mode = "parallel"` or
`mode = "sequential"`; with `subagents.parallel = true`, a same-turn fan-out runs
**concurrently** and overlaps network latency. Parallelism is supported, not
required, and setting `parallel = false` makes batches run sequentially. Fan-out
is never rejected because of its batch size or cumulative count. `max_parallel`
only controls how many provider streams run at once; every additional valid
scout waits in the local queue and still runs. The active harness mode may choose
a narrower concurrency width. Low mode is sequential; High/XHigh/Ultra can
proactively fan out when the task divides cleanly. The default policy uses one
task-sized investigation wave, then has the parent synthesize and act; a later
wave remains available for a new concrete blocker, but generic architecture,
test-survey, and post-implementation reviewer waves are deliberately discouraged.
This is steering, not a quota: every valid scout the model requests still runs.
Independent scouts emitted beside ordinary tool calls run as a concurrent
contiguous group while all tool results retain their original call order. Batch
`mode = "sequential"` only serializes self-contained prompts; a genuinely
dependent scout must be issued from a later parent turn after the earlier report
is available. Reports share a
`max_result_bytes` parent-context budget, each scout request is
held to `max_output_tokens` on Anthropic/raw-API transports. ChatGPT-login scouts keep
the model's native output reserve because that transport has no confirmed hard
cap field; their individual turn, result, and report limits still bound them.
Every `sub_agent` call must explicitly choose a stable short model alias and an
effort level. By default, routes stay in the active parent's provider family:
a Codex/OpenAI parent sees only `sol`/`terra`/`luna`, while a Claude/Anthropic
parent sees only `opus`/`sonnet`/`haiku`. Set
`subagents.allow_cross_provider = true` to deliberately expose both families.
The aliases resolve centrally to current configured provider IDs, so the parent
never guesses version strings. Blank, raw first-party IDs, and unavailable
aliases are rejected locally; `subagents.model` and `subagents.effort` are
preferences exposed to the parent, never silent harness fallbacks. A provider
authentication or unsupported-model failure temporarily removes its affected
aliases from the next tool schema, preventing sibling-model retry loops. The
parent may explicitly choose `effort = "inherit"` when intentional. Sub-agents
run on a **lean context**: they get the base instructions (and the read-only tool set,
including the LSP navigation tools) but **not** the repo-memory block or skills
index — a scout can't `remember`/`use_skill` anyway, and re-shipping the full
learned context to every worker (and to each worker of a parallel fan-out,
cold-cached) would add the same recurring context to every worker. Their returned
report is size-capped before it's spliced into the parent transcript, so a chatty
worker can't bloat the parent's context. Scouts are steered to stay under roughly
900 words, and each returned report is hard-capped at 6,000 bytes. Ordinary
scouts default to six provider requests, including the final report-only
request; the model may explicitly request up to the configured 12-request hard
cap for one genuinely deep blocker. At request four, a sufficiency checkpoint
asks an evidence-complete scout to report instead of consuming its ceiling.
Child rows display provider, route/effort, and live `request n/N` progress, so
provider requests are never confused with the number of scouts. Reports separate root
cause/evidence, the minimal compatible touch set, contracts to preserve, focused
regression cases, and optional hardening. The parent receives compact phase
guidance to treat reports as leads rather than authority, preserve previously
passing test contracts, and keep new tests hermetic. After a scout wave, the
parent gets one batched source-confirmation pass and is then explicitly steered
to implement instead of re-auditing the repository. Verification is tracked per
edit generation: repeated tests do not spam reminders, but editing after a
passing suite makes that verification stale and re-arms one bounded final diff
audit after the next successful suite.

**Web research.** Scouts have two independent, safe research tools. `web_search`
uses the [Brave Search API](https://api.search.brave.com) when
`$BRAVE_API_KEY`/`tools.web_search.api_key` is configured, and otherwise tries a
best-effort public Brave/Bing HTML fallback. The fallback can be rate-limited;
the API is the stable option. `web_fetch` reads a known public HTTP(S) page so a
scout can verify a result instead of trusting a snippet. Fetches are GET-only,
DNS-pinned, manually redirect-validated, limited to public default web ports and
text content, and bounded by response/text/time limits. Private/metadata hosts,
credentials, binaries, oversized responses and HTTPS→HTTP downgrades are
blocked. Returned pages are explicitly marked **untrusted web data**: page text
can never change the task or authorize tools. Both tools are read-only and
available to sub-agents; no API key is required for `web_fetch`.

**Repo memory & skills (self-learning harness).** advantage keeps a lightweight,
per-repo memory so the agent can reuse durable knowledge instead of rediscovering
it in every session.

- As it works, the agent calls a `remember` tool to save durable, non-obvious
  facts — architecture invariants, conventions, build/test commands, gotchas, or
  a preference you state ("always run the linter before committing"). You can also
  just tell it to remember something. Facts are deduplicated and kept under a token
  budget so the file never bloats.
- Memory is rendered into a stable system prefix that is eligible for provider
  cache reuse. A concise, relevant fact can avoid repeated read/grep discovery;
  an irrelevant fact is recurring context overhead, which is why the block is
  strictly budgeted.
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
  The agent codifies new ones with `save_skill`. Skills interoperate with both
  `.agents/skills/` (Open Agent Skills / Codex) and `.claude/skills/`, including
  nested launch-directory scopes and bundled relative references/scripts.
  `disable-model-invocation: true` and OpenAI's
  `agents/openai.yaml` `allow_implicit_invocation: false` are honored by the
  automatic matcher.
- Skills are also **auto-surfaced**: a deterministic keyword match against your
  prompt appends a one-line hint to the outgoing message when a skill looks
  relevant ("the deploy-docs skill may apply — load it with use_skill"), at most
  once per skill per session. The hint rides the message, never the system
  prompt, so the cached prefix stays byte-identical.
- Committed instructions are layered from the Git root down to the launch
  directory (`AGENTS.override.md`, `AGENTS.md`, `CLAUDE.local.md`, then
  `CLAUDE.md` per directory), with `@file` imports resolved. File tools remain
  rooted at the canonical Git workspace even when Neovim starts in a subfolder.
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

**Extensions.** `opts.extensions` loads small Lua modules once during setup.
An extension receives a stable API for registering provider-visible tools,
providers, harness presets, and session-frozen prompt parts; every registration
returns a disposer for clean development reloads. The empty default does no work
and leaves the baseline prompt/tool schema byte-for-byte unchanged.

```lua
-- lua/my_advantage_extension.lua
return function(api)
  api.register_harness("review", {
    label = "review", description = "Review-first workflow.", effort = "high",
    proactive = false, parallel = true, max_parallel = 2,
    guide = "Inspect the relevant diff and run focused checks before finishing.",
  })
  api.register_prompt_part("team policy", function(ctx)
    return "Team policy for " .. ctx.cwd .. ": preserve public compatibility."
  end)
end

require("advantage").setup({ extensions = { "my_advantage_extension" } })
```

A skill may declare `advantage-harness: review` in its frontmatter. This only
changes the live harness when `memory.allow_skill_harness = true`; it is disabled
by default so sharing a skill can never silently increase orchestration or cost.

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
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh", "max" } },
    { ref = "openai/gpt-5.6-terra", label = "gpt-5.6 terra", context_window = 372000,
      api_context_window = 1050000, max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max" },
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
      reasoning_effort = "max",   -- deepest single-agent wire effort
      reasoning_summary = "auto", -- "auto" | "concise" | "detailed" | false
      stream_error_retries = 2,   -- retry only pre-payload overload/truncated SSE
      stream_error_retry_base_ms = 2000, -- bounded exponential backoff
    },
  },
  harness = {
    mode = "auto",               -- auto | low | medium | high | xhigh | max | ultra
    sync_effort = true,           -- preset selection initializes matching effort
  },
  system_prompt = nil,           -- string to replace, function(default) to extend
  extensions = {},               -- setup(api) modules: tools/providers/harness/prompt parts
  max_agent_turns = 100,         -- safety cap on tool-loop round-trips per user turn
  verification = {              -- post-change deterministic project gates
    enabled = true,
    commands = {},              -- explicit trusted override; empty uses the manifest
    manifest = ".advantage/verification.json", -- false disables project-local gates
    timeout_ms = 120000,         -- per command
    max_output_bytes = 12000,   -- bounded failure evidence sent to the model
    max_repairs = 1,            -- same-conversation repair attempts
  },
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
    navgraph = {                 -- optional first-class semantic graph navigator
      enabled = false,           -- schema stays absent unless enabled + executable
      executable = "navgraph",   -- PATH command or pinned absolute executable
      allow_legacy_benchmark = false, -- opt into the exact-SHA frozen benchmark fallback
      timeout_ms = 30000,
      max_results = 80,          -- outline/search default lower; model cannot exceed this
      max_output_bytes = 12000,  -- final guard after compact result shaping
    },
    web_search = {               -- Brave API, then public Brave/Bing fallback
      enabled = true,
      backend = "auto",          -- "auto" | "brave_api" | "brave_html"
      allow_unkeyed = true,
      api_key_env = "BRAVE_API_KEY", -- or set api_key directly below
      api_key = nil,
      base_url = "https://api.search.brave.com/res/v1/web/search",
      max_results = 5,            -- default result count (hard cap: 10)
      timeout_ms = 15000,
      max_response_bytes = 1048576,
    },
    web_fetch = {                 -- public, bounded, DNS-pinned page reading
      enabled = true,
      timeout_ms = 20000,
      max_redirects = 3,
      max_response_bytes = 2097152,
      max_text_bytes = 64000,
      max_lines = 1000,
    },
  },
  context = {
    auto_compact = true,
    compact_fraction = 0.75,     -- compact at this % of the model's context_window
    compact_at_tokens = 200000,  -- absolute recurring-context ceiling (chars/4 estimate)
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
    model = nil,                 -- optional preference shown to the parent;
                                 -- every sub_agent call still names its model explicitly
    model_aliases = {            -- stable one-shot syntax → current provider IDs
      sol = "openai/gpt-5.6-sol", terra = "openai/gpt-5.6-terra",
      luna = "openai/gpt-5.6-luna", opus = "anthropic/claude-opus-4-8",
      sonnet = "anthropic/claude-sonnet-5", haiku = "anthropic/claude-haiku-4-5",
    },
    allow_cross_provider = false,-- same provider family as parent unless explicitly enabled
    max_turns = 6,               -- default provider-request budget per scout
    max_turns_cap = 12,          -- user ceiling for model-requested budgets;
                                 -- last turn remains report-only
    max_output_tokens = 16000,   -- per-scout Anthropic/raw-API output ceiling
    effort = "medium",           -- preference shown to parent; every call sets effort
    parallel = true,             -- support concurrent fan-out; false preserves sequential runs
    max_parallel = 4,            -- safe default width; XHigh/Max/Ultra support an explicit 8
    max_result_bytes = 64000,    -- shared parent-context budget for batch results
    tool_timeout_ms = 45000,     -- watchdog for each scout read-only tool
  },
  memory = {                     -- per-repo self-learning harness (remember/use_skill)
    enabled = true,
    allow_skill_harness = false, -- opt in to `advantage-harness` skill frontmatter
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
    harness = "<leader>ch",       -- tune harness orchestration policy
    help = "<leader>c?",          -- keybind & command cheatsheet
  },
  usage = {
    daily_budget = nil,          -- tokens/day; enables run-out projections in /usage
  },
  sessions = {
    autosave = true, -- saved per-project, resume with :Advantage resume
    max_file_bytes = 128 * 1024 * 1024, -- bounded before save/load
  },
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
- OpenAI Responses calls route byte-identical system/tool prefixes through a
  stable content-derived `prompt_cache_key` across chats. The ChatGPT transport
  separately keeps a unique, stable `session-id`/`thread-id` for each chat, so
  cache reuse never merges conversation state. Scout cache keys use four
  round-robin buckets for a shared prefix to retain reuse without concentrating
  concurrent fan-out on one hot route.
- Codex subscription access goes through the same backend the codex CLI uses;
  model availability can differ from the raw API catalogue. The API-key path is
  selected with `providers.openai.auth_mode = "api_key"` when needed.
- OpenAI overload/truncated-stream events retry only before any text, thinking,
  or tool payload is delivered. Retries preserve the exact request, use bounded
  backoff, and surface a visible notice. After payload delivery—or for
  deterministic auth/model/400 errors—the failure is never replayed.
- Request bodies and credentials are passed to curl via files/stdin, never
  argv, so nothing sensitive shows up in the process list.

## Development

```sh
nvim -l tests/smoke.lua   # parser, providers, tools, and a full fake-provider turn
nvim -l tests/perf.lua    # request hot paths + a warm 200-skill library budget
nvim -l tests/resource.lua # bounded caches, timer ownership, and UI lifecycle churn
stylua --check .          # formatting (config in stylua.toml)
```

CI (`.github/workflows/ci.yml`) runs smoke and performance budgets on Neovim
0.10/stable/nightly and checks formatting on every push.

## Roadmap

- compaction checkpoint restore (undo a compaction / inspect what was folded in)
- relevance-filtered memory injection (per-turn fact subsetting by touched paths)
