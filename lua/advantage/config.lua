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
    { ref = "openai/gpt-5.1-codex", label = "codex" },
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
    bash_timeout_ms = 120000,
  },

  keymaps = {
    toggle = "<leader>aa",
    new_session = "<leader>an",
    models = "<leader>am",
    resume = "<leader>ar",
    add_selection = "<leader>aa", -- visual mode
  },

  sessions = {
    autosave = true,
  },
}

M.options = vim.deepcopy(M.defaults)
M._setup_done = false

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  M._setup_done = true
end

---Resolve a `provider/model` ref into {provider=, id=, label=, thinking=}.
function M.resolve_model(ref)
  for _, m in ipairs(M.options.models) do
    if m.ref == ref then
      local provider, id = ref:match("^([^/]+)/(.+)$")
      return { provider = provider, id = id, label = m.label or id, thinking = m.thinking, reasoning_effort = m.reasoning_effort }
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
