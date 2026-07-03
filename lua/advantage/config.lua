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
    { ref = "openai/gpt-5.5-codex", label = "codex 5.5" },
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
  },

  keymaps = {
    toggle = "<leader>aa",
    new_session = "<leader>an",
    models = "<leader>am",
    resume = "<leader>ar",
    add_selection = "<leader>cs", -- visual mode: @file:L10-20 mention
    add_file = "<leader>cf", -- send current file to the chat prompt
    add_location = "<leader>cl", -- send @file:L{cursor line}
    pick_files = "<leader>cp", -- pick a project file to send
    usage = "<leader>au", -- token usage dashboard
    review = "<leader>ad", -- review the agent's file changes (diff)
    yolo = "<leader>ay", -- toggle skip-all-permissions mode
    effort = "<leader>ae", -- tune reasoning effort / thinking
    help = "<leader>a?", -- keybind & command cheatsheet
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
