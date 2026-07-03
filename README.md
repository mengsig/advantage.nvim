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

**Slash commands** in the prompt: `/usage` · `/compact` · `/review` · `/yolo` ·
`/effort` · `/new` · `/model` · `/resume` · `/help`.

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
session/today/7-day token totals, a sparkline, your current pace, a projection
to midnight, and — if you set `usage.daily_budget` — the time you'll run out
at the current pace.

**Context compaction.** Old transcript history is automatically compacted when
it crosses `context.compact_at_tokens` (roughly chars/4). The newest messages stay
verbatim; older user asks, assistant text, tool calls and results become one
summary message. Run `/compact` or `:Advantage compact` to force it manually.

**Sub-agents.** The model has a `sub_agent` tool for read-only fan-out: a worker
gets its own short loop and can use read/search/list tools, then returns a
concise report to the parent agent. It cannot edit files.

Commands: `:Advantage` (toggle) · `new` · `model` · `resume` · `stop` · `usage` ·
`compact` · `help` · `review` · `yolo [on|off]` · `effort` · `add` · `files` ·
`attach {path}` · `ask {prompt}` (works with a visual range: `:'<,'>Advantage ask why is this slow?`).

When the model wants to **edit a file or run a command**, a floating card shows
exactly what will happen — a unified diff for edits, the command for bash —
and waits for `a` (allow), `A` (always allow this tool this session), `d` (deny),
or `c` (**deny with a comment**: tell the agent what to do instead; your feedback
is sent back to the model). Read-only tools never prompt.

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
  model's thought process streams into the transcript, dimmed.
- Codex subscription access goes through the same backend the codex CLI uses
  and should be considered experimental; the API-key path is stable.
- Request bodies and credentials are passed to curl via files/stdin, never
  argv, so nothing sensitive shows up in the process list.

## Development

```sh
nvim -l tests/smoke.lua   # parser, providers, tools, and a full fake-provider turn
```

## Roadmap

- parallel tool execution (including parallel sub-agent fan-out)
- provider-native prompt-cache breakpoints for long sessions
- richer compaction (model-written summaries / checkpoint restore)
