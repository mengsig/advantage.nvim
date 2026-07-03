# ✦ advantage.nvim

A coding-agent **harness** that lives inside Neovim. Not a wrapper around a CLI —
advantage runs its own agent loop: it streams from the model, executes tools in
your editor, feeds results back, and repeats until the task is done.

- **Runs on your subscription.** Uses your **Claude Code login** (Pro/Max) or your
  **Codex / ChatGPT login** — no API key needed. Env API keys work as a fallback.
- **Model agnostic.** Anthropic (Opus 4.8, Sonnet 5, Fable 5, Haiku 4.5) and
  OpenAI Codex (gpt-5.1-codex family) out of the box; the provider interface is
  ~100 lines if you want to add more.
- **Editor-native tools.** `read_file`, `edit_file`, `write_file`, `bash`, `grep`,
  `find_files`, `list_dir` — executed inside Neovim, so edited buffers reload
  live and every mutation is gated behind a permission card with a real diff.
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
    { "<leader>aa", function() require("advantage").toggle() end, desc = "advantage: toggle" },
    { "<leader>cs", function() require("advantage").add_selection() end, mode = "x", desc = "advantage: add selection" },
    { "<leader>cl", function() require("advantage").add_location() end, desc = "advantage: add cursor location" },
    { "<leader>an", function() require("advantage").new_session() end, desc = "advantage: new session" },
    { "<leader>am", function() require("advantage").pick_model() end, desc = "advantage: model" },
    { "<leader>ar", function() require("advantage").resume() end, desc = "advantage: resume" },
    { "<leader>cf", function() require("advantage").add_file() end, desc = "advantage: add current file" },
    { "<leader>cp", function() require("advantage").pick_files() end, desc = "advantage: pick file" },
    { "<leader>au", function() require("advantage").usage() end, desc = "advantage: usage" },
    { "<leader>ad", function() require("advantage").review() end, desc = "advantage: review changes" },
    { "<leader>ay", function() require("advantage").toggle_yolo() end, desc = "advantage: toggle yolo" },
    { "<leader>ae", function() require("advantage").pick_effort() end, desc = "advantage: tune effort" },
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

`:Advantage` opens the panel. Type in the prompt, `⏎` sends. Sending while a
turn is running **queues** the message; queued messages dispatch one by one as
turns finish (`⌃c` cancels the turn *and* drops the queue). The prompt grows
with your message as you type.

| where  | key            | action                                    |
| ------ | -------------- | ----------------------------------------- |
| prompt | `⏎`            | send (queues if a turn is running)        |
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
with `mf`), `<leader>cl` the exact cursor line,
`<leader>cp` picks a file from the project. Visual `<leader>cs` references the
selection as `@file:L10-20` — the lines are read fresh from disk on send.

**Images.** `⌃v` in the prompt attaches a clipboard image (Wayland `wl-paste`,
X11 `xclip`, macOS `pngpaste`) and drops a `[image: …]` chip into the text —
delete the chip to detach. `:Advantage attach shot.png` attaches a file.

**Slash commands** in the prompt: `/usage` · `/review` · `/yolo` · `/effort` ·
`/new` · `/model` · `/resume` · `/help`.

**Review mode.** The agent snapshots every file before its first edit. After a
turn that changed files you'll see *"n files changed — /review to inspect"*:
`/review` (or `:Advantage review`, `<leader>ad`) lists the changes with `+/−`
counts, and opens either one unified diff of everything or a real side-by-side
vimdiff tab per file — before on the left (read-only), the live file on the
right (editable), `q` closes. With no agent changes it falls back to `git diff`.

**YOLO mode.** `/yolo` (or `:Advantage yolo [on|off]`, `<leader>ay`, or
`tools = { yolo = true }` / `dangerously_skip_permissions = true` in setup)
skips *all* permission cards. A red `⚡ yolo` badge stays in the winbar while
it's on. Use at your own risk.

**Effort / thinking.** `/effort` (or `/effort high`, `:Advantage effort [mode]`, `<leader>ce`) tunes the
active model before the next turn. OpenAI/Codex models get `minimal`/`low`/`medium`/`high`
`reasoning.effort`; Anthropic models get `adaptive`/`off`/`low`/`medium`/`high`
(`low`=`1k`, `medium`=`4k`, `high`=`8k` thinking budget).

**Usage dashboard.** `/usage` (or `:Advantage usage`, `<leader>au`) shows
session/today/7-day token totals, a sparkline, your current pace, a projection
to midnight, and — if you set `usage.daily_budget` — the time you'll run out
at the current pace.

Commands: `:Advantage` (toggle) · `new` · `model` · `resume` · `stop` · `usage` ·
`review` · `yolo [on|off]` · `effort` · `add` · `files` · `attach {path}` ·
`ask {prompt}` (works with a visual range: `:'<,'>Advantage ask why is this slow?`).

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
    { ref = "openai/gpt-5.5-codex", label = "codex 5.5" },
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
  },
  keymaps = {                    -- set to "" to disable any of these
    toggle = "<leader>aa",
    new_session = "<leader>an",
    models = "<leader>am",
    resume = "<leader>ar",
    add_selection = "<leader>cs", -- visual mode: @file:L10-20
    add_file = "<leader>cf",      -- send current file to the prompt
    add_location = "<leader>cl",  -- send @file:L{cursor line}
    pick_files = "<leader>cp",    -- pick a project file to send
    usage = "<leader>au",         -- token usage dashboard
    review = "<leader>ad",        -- review agent changes (diff)
    yolo = "<leader>ay",          -- toggle skip-all-permissions
    effort = "<leader>ae",        -- tune reasoning effort / thinking
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

- parallel tool execution
- prompt-cache breakpoints for long sessions
- sub-agent fan-out
