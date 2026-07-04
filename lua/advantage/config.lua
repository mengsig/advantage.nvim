local M = {}

M.defaults = {
  ---Default model, as `provider/model-id`.
  default_model = "anthropic/claude-opus-4-8",

  ---Models offered in the picker. `thinking = false` disables reasoning display
  ---for models that don't support adaptive thinking. `context_window` is the
  ---model's total token budget; it scales auto-compaction (see `context`). Values
  ---marked "confirmed" are from the provider docs; the rest are a conservative
  ---floor (erring low is safe — too high risks compacting at ~100% of the real
  ---window). Adjust any to match your account/tier.
  models = {
    { ref = "anthropic/claude-opus-4-8", label = "opus 4.8", context_window = 1000000 }, -- confirmed 1M
    { ref = "anthropic/claude-sonnet-5", label = "sonnet 5", context_window = 1000000 }, -- confirmed 1M
    { ref = "anthropic/claude-fable-5", label = "fable 5", context_window = 200000 }, -- unconfirmed, floor
    { ref = "anthropic/claude-haiku-4-5", label = "haiku 4.5", thinking = false, context_window = 200000 }, -- confirmed 200k
    { ref = "openai/gpt-5.5", label = "gpt-5.5", context_window = 1000000 }, -- confirmed 1M (raw API)
    { ref = "openai/gpt-5.1-codex", label = "codex 5.1", context_window = 400000 }, -- Codex tier, adjust
    { ref = "openai/gpt-5.1-codex-mini", label = "codex mini", context_window = 400000 }, -- Codex tier, adjust
  },

  providers = {
    anthropic = {
      api_key_env = "ANTHROPIC_API_KEY",
      base_url = "https://api.anthropic.com",
      version = "2023-06-01",
      max_tokens = 32000,
      ---Send the interleaved-thinking beta (like the real CLI) so thinking
      ---persists across tool calls within a turn. Disable if your account
      ---rejects the beta.
      interleaved_thinking = true,
    },
    openai = {
      api_key_env = "OPENAI_API_KEY",
      base_url = "https://api.openai.com",
      max_output_tokens = 32000,
      reasoning_effort = "medium",
    },
  },

  ---Override the built-in system prompt (string), or extend it (function(default) -> string).
  system_prompt = nil,

  ---Safety cap on how many provider round-trips one user message may drive in the
  ---tool loop (edit→test→re-edit…). Prevents a thrashing/looping model from
  ---burning tokens unbounded, especially under yolo/auto_approve. On hit, the turn
  ---stops with a notice; sending another message resumes. Resets each user turn.
  max_agent_turns = 100,

  ui = {
    width = 0.42, -- fraction of columns
    input_height = 4,
    border = "rounded",
    accent = nil, -- hex like "#e0af68"; defaults to a color derived from your colorscheme
  },

  tools = {
    ---Tools that never prompt: read_file/list_dir/grep/find_files are always safe.
    ---Add e.g. `bash = true` at your own risk.
    auto_approve = {},
    ---File tools (and their permission previews) are confined to the project
    ---root: absolute paths and `..` traversal outside it are rejected. Set true
    ---to allow reading/writing anywhere the user can (bash is always gated).
    allow_outside_root = false,
    ---Skip ALL permission prompts (a.k.a. --dangerously-skip-permissions).
    ---Also toggleable at runtime with `/yolo` or `:Advantage yolo`.
    yolo = false,
    bash_timeout_ms = 120000,
    ---If true, bash stdout/stderr is streamed into the transcript as it arrives.
    ---Individual calls may also pass `{ stream = true }`.
    stream_bash_output = false,

    ---Editor-native diagnostic feedback loop. After the agent edits a file the
    ---NEWLY-introduced LSP/linter diagnostics are appended to that tool's result
    ---so the model can self-correct — bounded hard so it never bloats context:
    ---only `severity`+ is shown, capped at `max` lines, diffed against the
    ---pre-edit state (pre-existing problems aren't re-reported), and a clean edit
    ---adds nothing. The model also gets an explicit `diagnostics` tool.
    diagnostics = {
      enabled = true, -- false hides the diagnostics tool and disables auto-attach
      auto = true, -- append new diagnostics to edit results
      ---Severity floor for the auto-attach: "error" (default, least noise) or
      ---"warn" (errors + warnings). The explicit tool defaults to "warn".
      severity = "error",
      max = 10, -- cap on diagnostic lines appended per edit
      wait_ms = 1500, -- ceiling on how long to wait for the LSP to re-analyze
      attach_grace_ms = 250, -- how long to wait for a server to attach before giving up
      ---Deterministically notify YOU (once per filetype) when a file the agent
      ---edits has no language server attached — a nudge to install one so the
      ---feedback loop works. Persisted as a line in the chat transcript (so you
      ---won't miss it if you stepped away) plus a WARN toast. Set false to silence.
      notify_missing = true,
    },
  },

  context = {
    ---Automatically compact old conversation history before it grows too large.
    auto_compact = true,
    ---When to auto-compact, as a fraction of the active model's `context_window`
    ---(see `models`): 0.75 = compact once the transcript is estimated to fill ~75%
    ---of the window. Scales the trigger to the model, so a small window compacts
    ---before it overflows and a large one isn't compacted needlessly early.
    compact_fraction = 0.75,
    ---Absolute ceiling (tokens) on that trigger — a COST cap. Even on a 1M-context
    ---model you rarely want to carry 0.75 × 1M ≈ 750k tokens every turn: it's
    ---expensive and overflows the cheap summarizer. Effective threshold =
    ---min(compact_fraction × context_window, compact_at_tokens). Lower it for
    ---cheaper turns; raise it to exploit a big window. (Token estimate is chars/4;
    ---falls back to this value alone when a model declares no context_window.)
    compact_at_tokens = 200000,
    ---Keep the newest messages verbatim; older messages become a summary. Bounded
    ---by BOTH this count and a token budget (`keep_recent_fraction`), whichever is
    ---tighter, so a few huge tool outputs can't retain more than the threshold.
    keep_recent_messages = 16,
    ---Token budget for that retained recent window, as a fraction of the resolved
    ---threshold (held under it so compaction can always get the transcript below
    ---the threshold rather than re-triggering every turn).
    keep_recent_fraction = 0.4,
    ---Maximum characters in the generated compaction summary.
    summary_max_chars = 12000,
    ---Mode for silent auto-compaction (crossing compact_at_tokens mid-turn):
    ---"heuristic" keeps the old free/offline behavior; "llm" spends one
    ---summarizer call when the threshold is crossed. Defaults to heuristic to
    ---avoid surprise token/API usage unless explicitly opted in.
    auto_compact_mode = "heuristic",
    ---Mode for manual/forced compaction (`/compact`, `:Advantage compact`):
    ---"llm" spends one call on `summarizer_model` for a real, semantically
    ---prioritized summary; "heuristic" stays free/offline.
    ---Override per-invocation with `/compact llm` or `/compact heuristic`.
    compact_mode = "llm",
    ---Model that performs the LLM summarization call, as "provider/model-id".
    ---Kept separate from the active chat model so compaction stays cheap and
    ---fast even mid-session on an expensive model.
    ---`nil` (default) = auto: a cheap model in the ACTIVE model's provider family
    ---(`context.summarizer_models`), so a Codex/OpenAI-only user never triggers a
    ---Claude request they have no credentials for (and vice-versa). Set a
    ---"provider/model-id" string to pin one model regardless of the active provider.
    summarizer_model = nil,
    ---Per-provider cheap summarizer used when `summarizer_model` is nil. Falls back
    ---to the active chat model itself if the provider isn't listed here.
    summarizer_models = {
      anthropic = "anthropic/claude-haiku-4-5",
      openai = "openai/gpt-5.1-codex-mini",
    },
  },

  subagents = {
    ---Expose the read-only `sub_agent` tool for delegation / fan-out.
    enabled = true,
    ---Model for sub-agents, as "provider/model-id". `nil` = use the parent's
    ---model. Set a fast/cheap model (e.g. "anthropic/claude-haiku-4-5" or
    ---"openai/gpt-5.1-codex-mini") to make read-only fan-out cheaper and faster;
    ---the sub_agent tool's `model` arg overrides this per call.
    model = nil,
    ---Maximum provider turns a sub-agent may take, including tool loops.
    max_turns = 6,
    ---Run a fan-out batch of `sub_agent` calls concurrently (overlapping their
    ---network latency) instead of one-at-a-time. Only pure read-only sub_agent
    ---batches are parallelised; mutating/permissioned tools always run in order.
    parallel = true,
    ---Give sub-agents a read-only `bash` tool (inspection commands + git
    ---read-only subcommands only; redirection and mutating flags are rejected).
    ---Off by default: bash is not path-contained, so a sub-agent could read
    ---anything your user can, with no permission prompt. Enable only in repos you
    ---trust. `true` uses the built-in allow-list; pass `{ allow = { "cmd", ... } }`
    ---to extend it.
    bash = false,
  },

  ---Per-repo self-learning harness: the agent records durable facts about a repo
  ---as it works (rendered into the cached system prefix, so ~free after turn one),
  ---and stores reusable named "skills" whose bodies load on demand. Deterministic
  ---and offline — no embeddings, no validator model. Files live under `<root>/.advantage/`.
  memory = {
    enabled = true,
    ---Rough token cap (chars/4) for the always-loaded learned-facts block. It
    ---rides the cached system prefix (billed ~10% after turn one), so this is a
    ---recurring per-turn tax — keep it lean. Oldest facts are evicted past it. The
    ---always-loaded tier is for CRISP signposts; depth belongs in on-demand skills
    ---(one index line until loaded), so raising this is rarely the right lever —
    ---curate depth into skills instead (`/context curate`).
    budget_tokens = 2000,
    ---Token cap on the always-loaded SKILLS INDEX (one line per skill). Skills past
    ---the cap stay fully available — loadable by name with `use_skill` and still
    ---keyword-hinted — but drop off the always-visible list, so a large skill
    ---library never re-bloats the cached prefix. Truncation is deterministic
    ---(alphabetical) to preserve prompt-cache stability.
    skills_index_budget_tokens = 1200,
    ---Token cap for ingested project memory (AGENTS.md / CLAUDE.md).
    project_budget_tokens = 2000,
    ---Word-overlap ratio above which a new fact counts as a duplicate.
    dedupe_threshold = 0.8,
  },

  keymaps = {
    toggle = "<leader>cc",
    new_session = "<leader>cn",
    models = "<leader>cm",
    resume = "<leader>cr",
    add_selection = "<leader>cs", -- visual mode: @file:L10-20 mention
    add_file = "<leader>cf", -- send current file to the chat prompt
    add_location = "<leader>cl", -- send @file:L{cursor line}
    pick_files = "<leader>cp", -- pick a project file to send
    context_preview = "<leader>cP", -- preview the exact context packet (system + tools + transcript)
    usage = "<leader>cu", -- token usage dashboard
    review = "<leader>cd", -- review the agent's file changes (diff)
    yolo = "<leader>cy", -- toggle skip-all-permissions mode
    effort = "<leader>ce", -- tune reasoning effort / thinking
    help = "<leader>c?", -- keybind & command cheatsheet
  },

  usage = {
    ---Tokens/day; enables "runs out at ~HH:MM" projections in the /usage dashboard.
    daily_budget = nil,
  },

  sessions = {
    autosave = true,
  },
}

M.options = vim.deepcopy(M.defaults)
M._setup_done = false

-- Deep-merge that treats *sequences* (list-like tables) as atomic values rather
-- than merging them element-wise by index. vim.tbl_deep_extend would otherwise
-- splice a user's `models` list into the defaults, leaving stale leftover entries.
local function merge(dst, src)
  if type(dst) ~= "table" or type(src) ~= "table" then return src end
  if src[1] ~= nil or dst[1] ~= nil then return vim.deepcopy(src) end
  local out = vim.deepcopy(dst)
  for k, v in pairs(src) do
    out[k] = merge(out[k], v)
  end
  return out
end

local function validate(o)
  local errs = {}
  if type(o.default_model) ~= "string" or not o.default_model:match("^[^/]+/.+$") then
    errs[#errs + 1] = "default_model must be a 'provider/model-id' string"
  end
  if type(o.models) ~= "table" or o.models[1] == nil then
    errs[#errs + 1] = "models must be a non-empty list of { ref = 'provider/model-id' } entries"
  else
    for i, m in ipairs(o.models) do
      if type(m) ~= "table" or type(m.ref) ~= "string" or not m.ref:match("^[^/]+/.+$") then
        errs[#errs + 1] = ("models[%d].ref must be a 'provider/model-id' string"):format(i)
      end
    end
  end
  if
    type(o.ui) == "table"
    and o.ui.width ~= nil
    and (type(o.ui.width) ~= "number" or o.ui.width <= 0 or o.ui.width > 1)
  then
    errs[#errs + 1] = "ui.width must be a number in (0, 1] (fraction of columns)"
  end
  if type(o.providers) ~= "table" then errs[#errs + 1] = "providers must be a table" end
  for _, key in ipairs({ "tools", "context", "ui", "memory", "subagents", "sessions" }) do
    if o[key] ~= nil and type(o[key]) ~= "table" then errs[#errs + 1] = key .. " must be a table" end
  end
  if type(o.context) == "table" then
    for _, field in ipairs({ "compact_mode", "auto_compact_mode" }) do
      local mode = o.context[field]
      if mode ~= nil and mode ~= "llm" and mode ~= "heuristic" then
        errs[#errs + 1] = "context." .. field .. " must be 'llm' or 'heuristic'"
      end
    end
    for _, field in ipairs({ "compact_fraction", "keep_recent_fraction" }) do
      local frac = o.context[field]
      if frac ~= nil and (type(frac) ~= "number" or frac <= 0 or frac > 1) then
        errs[#errs + 1] = "context." .. field .. " must be a number in (0, 1]"
      end
    end
  end
  if o.max_agent_turns ~= nil and (type(o.max_agent_turns) ~= "number" or o.max_agent_turns < 0) then
    errs[#errs + 1] = "max_agent_turns must be a non-negative number"
  end
  if type(o.tools) == "table" and type(o.tools.diagnostics) == "table" then
    local sev = o.tools.diagnostics.severity
    if sev ~= nil and sev ~= "error" and sev ~= "warn" and sev ~= "all" then
      errs[#errs + 1] = "tools.diagnostics.severity must be 'error', 'warn', or 'all'"
    end
  end
  return errs
end

M._validate = validate

function M.setup(opts)
  opts = opts or {}
  M.options = merge(vim.deepcopy(M.defaults), opts)
  local errs = validate(M.options)
  -- Structural options must be tables; revert any scalar override (e.g. a
  -- mistaken `tools = false`) to its default so it can't crash a later
  -- `config.options.tools.x` access. The mistake is still surfaced via `errs`.
  for _, key in ipairs({ "tools", "context", "ui", "providers", "memory", "subagents", "sessions", "keymaps", "usage" }) do
    if M.options[key] ~= nil and type(M.options[key]) ~= "table" then M.options[key] = vim.deepcopy(M.defaults[key]) end
  end
  -- accept the long-form alias for the paranoid-averse
  if M.options.tools.dangerously_skip_permissions then M.options.tools.yolo = true end
  if #errs > 0 then
    vim.schedule(function()
      vim.notify("advantage: invalid setup options —\n  " .. table.concat(errs, "\n  "), vim.log.levels.ERROR)
    end)
  end
  M._setup_done = true
end

---Resolve a `provider/model` ref into {provider=, id=, label=, thinking=}.
function M.resolve_model(ref)
  for _, m in ipairs(M.options.models) do
    if m.ref == ref then
      local provider, id = ref:match("^([^/]+)/(.+)$")
      return {
        provider = provider,
        id = id,
        label = m.label or id,
        thinking = m.thinking,
        thinking_budget = m.thinking_budget,
        reasoning_effort = m.reasoning_effort,
        context_window = m.context_window,
      }
    end
  end
  local provider, id = ref:match("^([^/]+)/(.+)$")
  if provider then return { provider = provider, id = id, label = id } end
  return nil
end

function M.api_key(provider_name)
  local pcfg = M.options.providers[provider_name]
  if not pcfg then return nil end
  if pcfg.api_key then return pcfg.api_key end
  local key = vim.env[pcfg.api_key_env or ""]
  if key and key ~= "" then return key end
  return nil
end

return M
