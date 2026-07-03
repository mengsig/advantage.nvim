---@brief advantage.nvim — a coding-agent harness that lives in Neovim.
---Runs its own agent loop against your Claude (Claude Code login) or
---Codex (ChatGPT login) subscription. No API key required.
local M = {}

local config = require("advantage.config")

local initialized = false
local agent_mod, ui, current

local function ensure_init()
  if initialized then return end
  initialized = true
  if not config._setup_done then
    config.setup({})
  end
  require("advantage.ui.highlights").setup()
  agent_mod = require("advantage.agent")
  ui = require("advantage.ui.chat")
  ui.state.on_submit = function(text)
    M.ask(text)
  end
end

local function ensure_agent()
  ensure_init()
  if not current then
    local model = config.resolve_model(config.options.default_model)
    current = agent_mod.new({ model = model })
    ui.set_model_label(model.label)
  end
  return current
end

local active_keymaps = {}

function M.setup(opts)
  config.setup(opts)
  initialized = false
  ensure_init()

  -- drop keymaps from a previous setup() so config reloads don't leak binds
  for _, km in ipairs(active_keymaps) do
    pcall(vim.keymap.del, km.mode, km.lhs)
  end
  active_keymaps = {}

  local maps = config.options.keymaps
  local function map(mode, lhs, rhs, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set(mode, lhs, rhs, { silent = true, desc = "advantage: " .. desc })
      active_keymaps[#active_keymaps + 1] = { mode = mode, lhs = lhs }
    end
  end
  map("n", maps.toggle, M.toggle, "toggle panel")
  map("n", maps.new_session, M.new_session, "new session")
  map("n", maps.models, M.pick_model, "switch model")
  map("n", maps.resume, M.resume, "resume session")
  map("x", maps.add_selection, function()
    M.add_selection()
  end, "add selection to prompt")
end

function M.toggle()
  ensure_agent()
  ui.toggle()
end

function M.open()
  ensure_agent()
  ui.open()
end

---Send a prompt (opens the panel if hidden).
function M.ask(text)
  local agent = ensure_agent()
  if not ui.is_open() then
    ui.open(false)
  end
  agent:send(text)
end

function M.stop()
  ensure_init()
  if current then current:cancel() end
end

function M.new_session()
  ensure_init()
  if current and current:busy() then current:cancel() end
  local model = current and current.model or config.resolve_model(config.options.default_model)
  current = agent_mod.new({ model = model })
  ui.clear()
  ui.set_model_label(model.label)
  ui.open()
end

function M.pick_model()
  ensure_init()
  local items = config.options.models
  vim.ui.select(items, {
    prompt = "model",
    format_item = function(m)
      return ("%s  ·  %s"):format(m.label or m.ref, m.ref)
    end,
  }, function(choice)
    if not choice then return end
    local model = config.resolve_model(choice.ref)
    if current then
      if current:busy() then
        ui.notify("finish or cancel the running turn first", vim.log.levels.WARN)
        return
      end
      current.model = model
    else
      ensure_agent()
      current.model = model
    end
    ui.set_model_label(model.label)
    ui.notify("model → " .. model.label)
  end)
end

function M.resume()
  ensure_init()
  require("advantage.session").pick(function(data)
    if not data then return end
    if current and current:busy() then current:cancel() end
    local model = config.resolve_model(
      (data.model and data.model.provider and (data.model.provider .. "/" .. data.model.id))
        or config.options.default_model
    ) or data.model
    -- a model that left the config list resolves without its per-model options;
    -- restore them from the saved session so e.g. `thinking = false` survives
    if data.model and model and model.id == data.model.id then
      if model.thinking == nil then model.thinking = data.model.thinking end
      if model.reasoning_effort == nil then model.reasoning_effort = data.model.reasoning_effort end
    end
    current = agent_mod.new({
      id = data.id,
      title = data.title,
      model = model,
      messages = data.messages,
      usage = data.usage,
    })
    ui.open(false)
    ui.render_transcript(data.messages, model.label)
    ui.set_usage(current.usage)
    ui.open()
  end)
end

---Visual mode: drop the selection into the prompt as a fenced block.
function M.add_selection()
  ensure_agent()
  local buf = vim.api.nvim_get_current_buf()
  local from = vim.fn.getpos("v")[2]
  local to = vim.fn.getpos(".")[2]
  if from > to then from, to = to, from end
  local lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  local ft = vim.bo[buf].filetype or ""
  local block = { ("```%s %s#L%d-L%d"):format(ft, name, from, to) }
  vim.list_extend(block, lines)
  block[#block + 1] = "```"
  block[#block + 1] = ""

  -- leave visual mode synchronously, before switching windows — a queued
  -- <Esc> via feedkeys would land in the prompt window and cancel insert mode
  vim.cmd([[normal! ]] .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  ui.open()
  local ibuf = ui.state.input_buf
  local existing = vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)
  if #existing == 1 and existing[1] == "" then existing = {} end
  vim.list_extend(existing, block)
  vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, existing)
  vim.api.nvim_win_set_cursor(ui.state.input_win, { #existing, 0 })
end

---@private for :Advantage
function M._command(opts)
  ensure_init()
  local args = vim.split(vim.trim(opts.args or ""), "%s+", { trimempty = true })
  local sub = args[1]
  if not sub or sub == "" or sub == "toggle" then
    M.toggle()
  elseif sub == "new" then
    M.new_session()
  elseif sub == "model" or sub == "models" then
    M.pick_model()
  elseif sub == "resume" then
    M.resume()
  elseif sub == "stop" then
    M.stop()
  elseif sub == "ask" then
    local text = table.concat(vim.list_slice(args, 2), " ")
    if opts.range and opts.range > 0 then
      local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
      text = text .. ("\n\n```%s %s#L%d-L%d\n%s\n```"):format(
        vim.bo.filetype or "", name, opts.line1, opts.line2, table.concat(lines, "\n"))
    end
    if vim.trim(text) ~= "" then M.ask(text) end
  else
    ui.notify("unknown subcommand: " .. sub, vim.log.levels.WARN)
  end
end

M._subcommands = { "toggle", "new", "model", "resume", "stop", "ask" }

return M
