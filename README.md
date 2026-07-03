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
    { "<leader>aa", function() require("advantage").add_selection() end, mode = "x", desc = "advantage: add selection" },
    { "<leader>an", function() require("advantage").new_session() end, desc = "advantage: new session" },
    { "<leader>am", function() require("advantage").pick_model() end, desc = "advantage: model" },
    { "<leader>ar", function() require("advantage").resume() end, desc = "advantage: resume" },
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

`:Advantage` opens the panel. Type in the prompt, `⏎` sends.

| where  | key            | action                          |
| ------ | -------------- | ------------------------------- |
| prompt | `⏎`            | send                            |
| prompt | `⇧⏎` / `⌃j`    | newline                         |
| chat   | `i a o` / `⇥`  | jump to prompt                  |
| both   | `⌃c`           | cancel the running turn         |
| both   | `q`            | hide the panel                  |
| chat   | `]]` / `[[`    | next / previous turn            |
| chat   | `g?`           | help                            |

Commands: `:Advantage` (toggle) · `new` · `model` · `resume` · `stop` ·
`ask {prompt}` (works with a visual range: `:'<,'>Advantage ask why is this slow?`).

When the model wants to **edit a file or run a command**, a floating card shows
exactly what will happen — a unified diff for edits, the command for bash —
and waits for `a` (allow), `A` (always allow this tool this session), or `d` (deny).
Read-only tools never prompt.

## Configuration (defaults)

```lua
require("advantage").setup({
  default_model = "anthropic/claude-opus-4-8",
  models = {
    { ref = "anthropic/claude-opus-4-8", label = "opus 4.8" },
    { ref = "anthropic/claude-sonnet-5", label = "sonnet 5" },
    { ref = "anthropic/claude-fable-5", label = "fable 5" },
    { ref = "anthropic/claude-haiku-4-5", label = "haiku 4.5", thinking = false },
    { ref = "openai/gpt-5.1-codex", label = "codex" },
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
    bash_timeout_ms = 120000,
  },
  keymaps = {                    -- set to "" to disable any of these
    toggle = "<leader>aa",
    new_session = "<leader>an",
    models = "<leader>am",
    resume = "<leader>ar",
    add_selection = "<leader>aa", -- visual mode
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

- `@file` / `@buffer` context mentions in the prompt
- parallel tool execution
- prompt-cache breakpoints for long sessions
- sub-agent fan-out
