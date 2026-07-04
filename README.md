# ✦ advantage.nvim

A coding-agent **harness** that lives inside Neovim. Not a wrapper around a CLI —
advantage runs its own agent loop: it streams from the model, executes tools in
your editor, feeds results back, and repeats until the task is done.

- **Runs on your subscription.** Uses your **Claude Code login** (Pro/Max) or your
  **Codex / ChatGPT login** — no API key needed. Env API keys work as a fallback.
- **Model agnostic.** Anthropic (Opus 4.8, Sonnet 5, Fable 5, Haiku 4.5) and
  OpenAI GPT/Codex (gpt-5.5 and gpt-5.1-codex family) out of the box; the
  provider interface is ~100 lines if you want to add more.
- **Editor-native tools.** `read_file`, `edit_file`, `write_file`, `bash`, `grep`,
  `find_files`, `list_dir`, `diagnostics`, `sub_agent` — executed inside Neovim, so
  edited buffers reload live, edits get an **LSP/linter feedback loop**, and every
  mutation is gated behind a permission card with a real diff.
- **A UI that respects your colorscheme.** No hardcoded palette: the accent,
  washes and dim tones are derived from *your* theme at runtime. Quiet lowercase
  headers, animated tool cards, dimmed streaming reasoning, token/cost meta per
  turn.

```
▍ you                                                    14:02
add a --json flag to the export command

▍ ✦ opus 4.8                                  ↑12.4k ↓1.1k · 41s
I'll look at the current flag handling first.

  ● read_file  src/cli/export.lua
  ⠹ bash  just test cli

Added the flag and threaded it through the formatter…
```

## Requirements

- Neovim **0.10+**
- `curl`
- logged in to the [`claude`](https://github.com/anthropics/claude-code) CLI
  and/or [`codex`](https://github.com/openai/codex) CLI — or
  `$ANTHROPIC_API_KEY` / `$OPENAI_API_KEY`
- `ripgrep` (optional, for fast `grep` / `find_files`)

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

**Effort / thinking.** `/effort` (or `/effort high`, `:Advantage effort [mode]`, `<leader>ce`) tunes the
active model before the next turn. OpenAI/Codex models get `default`/`off` plus
`minimal`/`low`/`medium`/`high` `reasoning.effort`; Anthropic models get
`adaptive`/`off` plus fixed thinking budgets: `low`=`1k`, `medium`=`4k`,
`high`=`8k`, `higher`=`10k`, `highest`=`16k`, and `max`=`32k` (aliases include
`think`, `think-hard`, `think-harder`, and `ultrathink`).

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
active model's window**: `min(context.compact_fraction × model.context_window,
context.compact_at_tokens)`. The fraction protects a small-window model (it
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
  spending one call on a fast/cheap summarizer model so a real model writes a
  dense, structured summary — primary intent, files touched, decisions, pending
  work — from the *untruncated* older transcript. By default the summarizer is a
  cheap model **in your active model's provider family** (Haiku for Claude,
  codex-mini for OpenAI/Codex), so a Codex-only user never triggers a Claude
  request they have no credentials for; pin one with `context.summarizer_model`.
  The **original task prompt is preserved verbatim** through every compaction
  (both modes), so long sessions never drift off what you asked for. If the
  summarizer call fails, it falls back to the offline heuristic automatically and
  shows a warning. Run
  `/compact heuristic` (or `:Advantage compact heuristic`) to skip the model
  call and use the free heuristic instead for a single invocation, or set
  `context.compact_mode = "heuristic"` to make that the default everywhere.

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
concise report to the parent agent. It cannot edit files. When the model fires
several `sub_agent` calls in one turn they run **concurrently**, overlapping
their network latency instead of one at a time (`subagents.parallel`). Set
`subagents.bash = true` to also give sub-agents a **read-only** bash — inspection
commands and git read-only subcommands only; output redirection, command
substitution and mutating flags are rejected. It is off by default because bash
isn't path-contained (a sub-agent could read anything your user can, with no
permission prompt), so enable it only in repos you trust.

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
                                   -- adjust to your account/tier (confirmed vs floor)
    { ref = "anthropic/claude-opus-4-8", label = "opus 4.8", context_window = 1000000 },
    { ref = "anthropic/claude-sonnet-5", label = "sonnet 5", context_window = 1000000 },
    { ref = "anthropic/claude-fable-5", label = "fable 5", context_window = 200000 },
    { ref = "anthropic/claude-haiku-4-5", label = "haiku 4.5", thinking = false, context_window = 200000 },
    { ref = "openai/gpt-5.5", label = "gpt-5.5", context_window = 1000000 },
    { ref = "openai/gpt-5.1-codex", label = "codex 5.1", context_window = 400000 },
    { ref = "openai/gpt-5.1-codex-mini", label = "codex mini", context_window = 400000 },
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
  },
  context = {
    auto_compact = true,
    compact_fraction = 0.75,     -- compact at this % of the model's context_window
    compact_at_tokens = 200000,  -- absolute cost ceiling on that trigger (chars/4)
    keep_recent_messages = 16,   -- newest kept verbatim, also bounded by:
    keep_recent_fraction = 0.4,  -- recent window kept, as a % of the threshold
    summary_max_chars = 12000,   -- heuristic-mode summary cap
    auto_compact_mode = "heuristic", -- auto-compact: "heuristic" | "llm"
    compact_mode = "llm",        -- manual /compact: "llm" | "heuristic"
    summarizer_model = nil,      -- nil = auto: a cheap model in the ACTIVE provider's
                                 -- family (so a Codex-only user never needs Claude creds
                                 -- to /compact). Set "provider/model-id" to pin one.
    summarizer_models = {        -- the per-provider cheap summarizer picked when nil
      anthropic = "anthropic/claude-haiku-4-5",
      openai = "openai/gpt-5.1-codex-mini",
    },
  },
  subagents = {
    enabled = true,              -- exposes the read-only `sub_agent` tool
    model = nil,                 -- nil = parent's model; set a fast model
                                 -- (e.g. "anthropic/claude-haiku-4-5") for cheaper fan-out
    max_turns = 6,
    parallel = true,             -- run a fan-out batch of sub_agents concurrently
    bash = false,                -- give sub-agents a read-only bash (see below); or
                                 -- { allow = { "cmd", ... } } to extend the allow-list
  },
  memory = {                     -- per-repo self-learning harness (remember/use_skill)
    enabled = true,
    budget_tokens = 2000,        -- cap on the always-loaded facts block (crisp signposts;
                                 -- push DEPTH into on-demand skills, not this tier)
    skills_index_budget_tokens = 1200, -- cap on the always-loaded skills index; skills past
                                 -- it stay loadable by name (deterministic truncation)
    project_budget_tokens = 2000,-- cap on ingested AGENTS.md / CLAUDE.md
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
- Anthropic requests use adaptive thinking with summarized reasoning — the
  model's thought process streams into the transcript, dimmed. The
  interleaved-thinking beta is sent (like the real CLI) so reasoning persists
  across tool calls within a turn; disable with
  `providers = { anthropic = { interleaved_thinking = false } }` if your account
  rejects it.
- Codex subscription access goes through the same backend the codex CLI uses
  and should be considered experimental; the API-key path is stable.
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
