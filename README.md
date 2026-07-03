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
  `find_files`, `list_dir`, `sub_agent` — executed inside Neovim, so edited
  buffers reload live and every mutation is gated behind a permission card with
  a real diff.
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
active model before the next turn. OpenAI/Codex models get `minimal`/`low`/`medium`/`high`
`reasoning.effort`; Anthropic models get `adaptive`/`off`/`low`/`medium`/`high`
(`low`=`1k`, `medium`=`4k`, `high`=`8k` thinking budget).

**Usage dashboard.** `/usage` (or `:Advantage usage`, `<leader>cu`) shows
session/today/7-day token totals, cache savings (cached input bills at ~10%, and
the dashboard shows how much that saved you), a sparkline, your current pace, a
projection to midnight, and — if you set `usage.daily_budget` — the time you'll
run out at the current pace. A `harness` line reports what the repo memory
injects per turn and how many tokens the on-demand skill design saved versus
inlining every skill body into every request — so the harness's token thesis is
measured, not asserted.

**Context compaction.** Old transcript history is automatically compacted when
it crosses `context.compact_at_tokens` (roughly chars/4). The newest messages stay
verbatim; older user asks, assistant text, tool calls and results become one
summary message. Run `/compact` or `:Advantage compact` to force it manually.

**Sub-agents.** The model has a `sub_agent` tool for read-only fan-out: a worker
gets its own short loop and can use read/search/list tools, then returns a
concise report to the parent agent. It cannot edit files. When the model fires
several `sub_agent` calls in one turn they run **concurrently**, overlapping
their network latency instead of one at a time (`subagents.parallel`).

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
- **Skills** are reusable named procedures. Only a one-line index (name +
  description) is always in context; the full steps load on demand when the agent
  calls `use_skill`, keeping context lean. The agent codifies new ones with
  `save_skill`. Skills interoperate with `.claude/skills/`.
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

`/context` (or `:Advantage context`) shows the current memory; `/context init`
teaches the agent the repo in one pass; `/context verify` flags facts whose
referenced files have since moved or vanished; `/context forget <text>` drops
matching facts. Turn it off with `memory = { enabled = false }`.

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
absolute paths and `..` traversal outside it are rejected. Set
`tools = { allow_outside_root = true }` if you genuinely want the agent reading
and writing anywhere your user can (bash remains permission-gated either way).

**Planning & batch edits.** For multi-step work the model keeps a live checklist
with `todo_write` (rendered in the transcript as ✓/▶/· items), and several
changes to one file arrive as a single atomic `multi_edit` — one diff card, one
approval; if any edit in the batch fails to match, nothing is written.

## Configuration (defaults)

```lua
require("advantage").setup({
  default_model = "anthropic/claude-opus-4-8",
  models = {
    { ref = "anthropic/claude-opus-4-8", label = "opus 4.8" },
    { ref = "anthropic/claude-sonnet-5", label = "sonnet 5" },
    { ref = "anthropic/claude-fable-5", label = "fable 5" },
    { ref = "anthropic/claude-haiku-4-5", label = "haiku 4.5", thinking = false },
    { ref = "openai/gpt-5.5", label = "gpt-5.5" },
    { ref = "openai/gpt-5.1-codex", label = "codex 5.1" },
    { ref = "openai/gpt-5.1-codex-mini", label = "codex mini" },
  },
  system_prompt = nil,           -- string to replace, function(default) to extend
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
  },
  context = {
    auto_compact = true,
    compact_at_tokens = 120000,  -- rough chars/4 estimate
    keep_recent_messages = 16,
    summary_max_chars = 12000,
  },
  subagents = {
    enabled = true,              -- exposes the read-only `sub_agent` tool
    max_turns = 6,
    parallel = true,             -- run a fan-out batch of sub_agents concurrently
  },
  memory = {                     -- per-repo self-learning harness (remember/use_skill)
    enabled = true,
    budget_tokens = 1200,        -- cap on the learned-facts block; oldest evicted past it
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
```

## Roadmap

- richer compaction (model-written summaries / checkpoint restore)
- relevance-filtered memory injection (per-turn fact subsetting by touched paths)
- symlink-aware containment (realpath verification for repos that need it)
