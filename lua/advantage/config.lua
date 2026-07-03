local M = {}

M.defaults = {
  ---Default model, as `provider/model-id`.
  default_model = "anthropic/claude-opus-4-8",

  ---Models offered in the picker. `thinking = false` disables reasoning display
  ---for models that don't support adaptive thinking.
  models = {
    { ref = "anthropic/claude-opus-4-8", label = "opus 4.8" },
    { ref = "anthropic/claude-sonnet-5", label = "sonnet 5" },
    { ref = "anthropic/claude-fable-5", label = "fable 5" },
    { ref = "anthropic/claude-haiku-4-5", label = "haiku 4.5", thinking = false },
    { ref = "openai/gpt-5.5", label = "gpt-5.5" },
    { ref = "openai/gpt-5.1-codex", label = "codex 5.1" },
    { ref = "openai/gpt-5.1-codex-mini", label = "codex mini" },
  },

  providers = {
    anthropic = {
      api_key_env = "ANTHROPIC_API_KEY",
      base_url = "https://api.anthropic.com",
      version = "2023-06-01",
      max_tokens = 32000,
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
    ---Skip ALL permission prompts (a.k.a. --dangerously-skip-permissions).
    ---Also toggleable at runtime with `/yolo` or `:Advantage yolo`.
    yolo = false,
    bash_timeout_ms = 120000,
    ---If true, bash stdout/stderr is streamed into the transcript as it arrives.
    ---Individual calls may also pass `{ stream = true }`.
    stream_bash_output = false,
  },

  context = {
    ---Automatically compact old conversation history before it grows too large.
    auto_compact = true,
    ---Rough token estimate threshold (chars / 4) that triggers compaction.
    compact_at_tokens = 120000,
    ---Keep this many newest messages verbatim; older messages become a summary.
    keep_recent_messages = 16,
    ---Maximum characters in the generated compaction summary.
    summary_max_chars = 12000,
  },

  subagents = {
    ---Expose the read-only `sub_agent` tool for delegation / fan-out.
    enabled = true,
    ---Maximum provider turns a sub-agent may take, including tool loops.
    max_turns = 6,
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

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- accept the long-form alias for the paranoid-averse
  if M.options.tools.dangerously_skip_permissions then
    M.options.tools.yolo = true
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
      }
    end
  end
  local provider, id = ref:match("^([^/]+)/(.+)$")
  if provider then
    return { provider = provider, id = id, label = id }
  end
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
