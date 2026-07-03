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
  ui.state.on_submit = function(text, images, mode)
    M.ask(text, { images = images, mode = mode })
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
  map("n", maps.add_file, M.add_file, "add current file to chat")
  map("n", maps.add_location, M.add_location, "add cursor location to chat")
  map("n", maps.pick_files, M.pick_files, "pick a file to add to chat")
  map("n", maps.usage, M.usage, "usage dashboard")
  map("n", maps.review, M.review, "review agent changes")
  map("n", maps.yolo, M.toggle_yolo, "toggle yolo mode")
  map("n", maps.effort, M.pick_effort, "tune model effort")
  map("n", maps.help, M.help, "help")
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

---Send a prompt (opens the panel if hidden). While a turn is running, the
---default `mode = "instant"` injects it before the next tool call; `mode = "queued"`
---waits until the whole agent flow is idle.
---@param opts? {images?: table[], mode?: "instant"|"queued"}
function M.ask(text, opts)
  local agent = ensure_agent()
  if not ui.is_open() then
    ui.open(false)
  end
  agent:send(text, opts)
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
      if model.thinking_budget == nil then model.thinking_budget = data.model.thinking_budget end
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

local function buf_var(buf, name)
  local ok, value = pcall(vim.api.nvim_buf_get_var, buf, name)
  if ok then return value end
  return nil
end

local function is_netrw_buffer(buf)
  return vim.bo[buf].filetype == "netrw" or buf_var(buf, "netrw_curdir") ~= nil
end

local function netrw_curdir(buf)
  return buf_var(buf, "netrw_curdir") or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p:h")
end

local function add_unique_file(files, seen, skipped, path)
  path = tostring(path or ""):gsub("[/%|@]$", "")
  if path == "" then return skipped end
  path = vim.fn.fnamemodify(path, ":p")
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if stat and stat.type == "file" then
    local rel = vim.fn.fnamemodify(path, ":.")
    if not seen[rel] then
      seen[rel] = true
      files[#files + 1] = rel
    end
  else
    skipped = skipped + 1
  end
  return skipped
end

---Return netrw's currently marked files (from `mf`) as project-relative
---paths where possible. Falls back to the buffer-local mark list for older
---netrw state where the global mark list is unavailable.
---@return string[] files, integer skipped
local function netrw_marked_files()
  local raw = {}

  local ok_fn, expose = pcall(function() return vim.fn["netrw#Expose"] end)
  if ok_fn and expose then
    local ok, global = pcall(expose, "netrwmarkfilelist")
    if ok and type(global) == "table" then
      raw = global
    end

    local curdir = netrw_curdir(0)
    if #raw == 0 and curdir then
      local ok_local, local_list = pcall(expose, "netrwmarkfilelist_" .. vim.api.nvim_get_current_buf())
      if ok_local and type(local_list) == "table" then
        for _, name in ipairs(local_list) do
          local cleaned = tostring(name):gsub("[/%|@]$", "")
          raw[#raw + 1] = cleaned:sub(1, 1) == "/" and cleaned or (curdir .. "/" .. cleaned)
        end
      end
    end
  end

  local files, seen, skipped = {}, {}, 0
  for _, item in ipairs(raw) do
    skipped = add_unique_file(files, seen, skipped, item)
  end
  return files, skipped
end

local function netrw_line_files(line1, line2)
  local curdir = netrw_curdir(0)
  local files, seen, skipped = {}, {}, 0
  for lnum = line1, line2 do
    local line = vim.fn.getline(lnum)
    for entry in line:gmatch("%S+") do
      entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
      if entry ~= "" and not entry:match('^"') and entry ~= "." and entry ~= ".." and not entry:match("^[-=]+$") then
        local path = entry:sub(1, 1) == "/" and entry or (curdir .. "/" .. entry)
        skipped = add_unique_file(files, seen, skipped, path)
      end
    end
  end
  return files, skipped
end

---Relative file name of a buffer, or nil (+warning) for non-file buffers.
local function buf_rel_name(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    ui.notify("current buffer has no file on disk", vim.log.levels.WARN)
    return nil
  end
  if vim.bo[buf].modified then
    ui.notify("buffer has unsaved changes — line references use the file on disk", vim.log.levels.WARN)
  end
  return vim.fn.fnamemodify(name, ":.")
end

---Visual mode: reference the selection as `@file:L10-20`. The lines are read
---fresh from disk when the message is sent.
function M.add_selection()
  ensure_agent()
  local buf = vim.api.nvim_get_current_buf()
  local from = vim.fn.getpos("v")[2]
  local to = vim.fn.getpos(".")[2]
  if from > to then from, to = to, from end

  -- leave visual mode synchronously, before switching windows — a queued
  -- <Esc> via feedkeys would land in the prompt window and cancel insert mode
  vim.cmd([[normal! ]] .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  local name = buf_rel_name(buf)
  if not name then return end
  local mention = from == to and ("%s:L%d"):format(name, from)
    or ("%s:L%d-%d"):format(name, from, to)
  ui.add_mention(mention)
end

---Normal mode: reference the exact cursor location as `@file:L{line}`.
function M.add_location()
  ensure_agent()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local name = buf_rel_name(buf)
  if not name then return end
  ui.add_mention(("%s:L%d"):format(name, line))
end

---Send netrw's marked files (`mf`) to the chat prompt.
function M.add_netrw_marked_files()
  ensure_agent()
  local files, skipped = netrw_marked_files()
  if #files == 0 then
    local msg = skipped > 0 and "no marked regular files in netrw" or "no netrw marked files (mark files with mf first)"
    ui.notify(msg, vim.log.levels.WARN)
    return
  end
  for _, file in ipairs(files) do
    M.attach(file)
  end
  local extra = skipped > 0 and ("; skipped " .. skipped .. " non-file item" .. (skipped == 1 and "" or "s")) or ""
  ui.notify("added " .. #files .. " netrw marked file" .. (#files == 1 and "" or "s") .. extra)
end

---Send the current buffer's file to the chat prompt (image files are attached,
---anything else becomes an @mention that is inlined on send). In netrw, sends
---the current marked file set instead.
function M.add_file()
  ensure_agent()
  if is_netrw_buffer(0) then
    return M.add_netrw_marked_files()
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    ui.notify("current buffer has no file on disk", vim.log.levels.WARN)
    return
  end
  M.attach(vim.fn.fnamemodify(name, ":."))
end

---Pick a project file and add it to the chat prompt.
function M.pick_files()
  ensure_agent()
  local files = require("advantage.attach").project_files(2000)
  if #files == 0 then
    ui.notify("no project files found", vim.log.levels.WARN)
    return
  end
  vim.ui.select(files, { prompt = "add file to chat" }, function(choice)
    if choice then M.attach(choice) end
  end)
end

---Attach a path: images become message attachments, other files @mentions.
function M.attach(path)
  ensure_agent()
  local attach = require("advantage.attach")
  local ext = path:match("%.(%w+)$")
  if ext and attach.IMAGE_TYPES[ext:lower()] then
    local img, err = attach.load_image(path)
    if not img then
      ui.notify(err, vim.log.levels.WARN)
      return
    end
    ui.attach_image(img)
  else
    ui.add_mention(path)
  end
end

---Review the agent's file changes (also `/review`). Unified diff or per-file
---side-by-side vimdiff; falls back to `git diff` when the agent changed nothing.
function M.review()
  ensure_init()
  require("advantage.review").open(current)
end

---Toggle skip-all-permissions mode (a.k.a. --dangerously-skip-permissions).
function M.toggle_yolo()
  ensure_init()
  local t = config.options.tools
  t.yolo = not t.yolo
  ui.refresh()
  if t.yolo then
    ui.notify("⚡ yolo ON — all tool calls run without asking. /yolo to turn off.", vim.log.levels.WARN)
  else
    ui.notify("yolo off — permission prompts restored")
  end
end

local OPENAI_EFFORTS = {
  minimal = true,
  low = true,
  medium = true,
  high = true,
}

local ANTHROPIC_EFFORTS = {
  adaptive = { label = "adaptive/default", value = "adaptive" },
  default = { label = "adaptive/default", value = "adaptive" },
  off = { label = "off", value = false },
  none = { label = "off", value = false },
  low = { label = "low · 1k budget", value = { type = "enabled", budget_tokens = 1024 } },
  ["1k"] = { label = "low · 1k budget", value = { type = "enabled", budget_tokens = 1024 } },
  medium = { label = "medium · 4k budget", value = { type = "enabled", budget_tokens = 4096 } },
  ["4k"] = { label = "medium · 4k budget", value = { type = "enabled", budget_tokens = 4096 } },
  high = { label = "high · 8k budget", value = { type = "enabled", budget_tokens = 8192 } },
  ["8k"] = { label = "high · 8k budget", value = { type = "enabled", budget_tokens = 8192 } },
}

local function apply_anthropic_effort(agent, choice)
  if choice.value == "adaptive" then
    agent.model.thinking = nil
    agent.model.thinking_budget = nil
  elseif choice.value == false then
    agent.model.thinking = false
    agent.model.thinking_budget = nil
  else
    agent.model.thinking = vim.deepcopy(choice.value)
    agent.model.thinking_budget = nil
  end
  ui.notify("thinking → " .. choice.label)
end

---Set reasoning/thinking effort directly.
---OpenAI: minimal|low|medium|high. Anthropic: adaptive|off|low|medium|high (aliases: 1k|4k|8k).
function M.set_effort(mode)
  local agent = ensure_agent()
  if agent:busy() then
    ui.notify("finish or cancel the running turn before changing effort", vim.log.levels.WARN)
    return false
  end

  mode = vim.trim(tostring(mode or "")):lower()
  if mode == "" then
    M.pick_effort()
    return true
  end

  if agent.model.provider == "openai" then
    if not OPENAI_EFFORTS[mode] then
      ui.notify("OpenAI effort must be: minimal, low, medium, or high", vim.log.levels.WARN)
      return false
    end
    agent.model.reasoning_effort = mode
    ui.notify("effort → " .. mode)
    return true
  end

  if agent.model.provider == "anthropic" then
    local choice = ANTHROPIC_EFFORTS[mode]
    if not choice then
      ui.notify("Claude thinking must be: adaptive, off, low/1k, medium/4k, or high/8k", vim.log.levels.WARN)
      return false
    end
    apply_anthropic_effort(agent, choice)
    return true
  end

  ui.notify("effort controls are not available for " .. tostring(agent.model.provider), vim.log.levels.WARN)
  return false
end

---Tune reasoning effort / thinking for the current model.
---OpenAI models use Responses API `reasoning.effort`; Anthropic models use
---the current Claude Code-like adaptive thinking by default, with optional fixed
---budgets or off for cheap turns.
function M.pick_effort()
  local agent = ensure_agent()
  if agent:busy() then
    ui.notify("finish or cancel the running turn before changing effort", vim.log.levels.WARN)
    return
  end

  if agent.model.provider == "openai" then
    local items = {
      { label = "minimal", value = "minimal" },
      { label = "low", value = "low" },
      { label = "medium", value = "medium" },
      { label = "high", value = "high" },
    }
    vim.ui.select(items, {
      prompt = "reasoning effort",
      format_item = function(x)
        local mark = agent.model.reasoning_effort == x.value and "●" or " "
        return ("%s %s"):format(mark, x.label)
      end,
    }, function(choice)
      if not choice then return end
      M.set_effort(choice.value)
    end)
    return
  end

  if agent.model.provider == "anthropic" then
    local current = agent.model.thinking
    local items = {
      ANTHROPIC_EFFORTS.adaptive,
      ANTHROPIC_EFFORTS.off,
      ANTHROPIC_EFFORTS.low,
      ANTHROPIC_EFFORTS.medium,
      ANTHROPIC_EFFORTS.high,
    }
    vim.ui.select(items, {
      prompt = "Claude thinking",
      format_item = function(x)
        local selected = false
        if x.value == false then
          selected = current == false
        elseif x.value == "adaptive" then
          selected = current == nil or current == "adaptive" or current == true
        elseif type(current) == "table" then
          selected = current.budget_tokens == x.value.budget_tokens
        end
        return ("%s %s"):format(selected and "●" or " ", x.label)
      end,
    }, function(choice)
      if not choice then return end
      apply_anthropic_effort(agent, choice)
    end)
    return
  end

  ui.notify("effort controls are not available for " .. tostring(agent.model.provider), vim.log.levels.WARN)
end

---Token usage dashboard (also available as `/usage` in the prompt).
function M.usage()
  ensure_init()
  local lines = require("advantage.usage").dashboard_lines(current and current.usage or nil)
  ui.float({
    title = "advantage · usage",
    lines = lines,
    filetype = "",
    footer = "q close",
  })
end

---Force context compaction for the current session.
function M.compact()
  local agent = ensure_agent()
  local info = agent:compact()
  if not info then
    ui.notify("context is already compact enough")
  end
end

---Show the keybind and command cheatsheet.
function M.help()
  ensure_init()
  ui.show_help()
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
  elseif sub == "usage" then
    M.usage()
  elseif sub == "compact" then
    M.compact()
  elseif sub == "help" or sub == "keys" then
    M.help()
  elseif sub == "review" or sub == "diff" then
    M.review()
  elseif sub == "yolo" then
    local want = args[2]
    if want == "on" or want == "off" then
      -- set the opposite, then toggle: keeps all messaging in one place
      config.options.tools.yolo = want == "off"
    end
    M.toggle_yolo()
  elseif sub == "effort" then
    if args[2] then
      M.set_effort(args[2])
    else
      M.pick_effort()
    end
  elseif sub == "add" then
    if opts.range and opts.range > 0 then
      if is_netrw_buffer(0) then
        local files, skipped = netrw_line_files(opts.line1, opts.line2)
        if #files == 0 then
          local msg = skipped > 0 and "no regular files in selected netrw lines" or "no netrw files selected"
          ui.notify(msg, vim.log.levels.WARN)
          return
        end
        for _, file in ipairs(files) do
          M.attach(file)
        end
        local extra = skipped > 0 and ("; skipped " .. skipped .. " non-file item" .. (skipped == 1 and "" or "s")) or ""
        ui.notify("added " .. #files .. " netrw file" .. (#files == 1 and "" or "s") .. extra)
      else
        -- ranged form: :'<,'>Advantage add → @file:L10-20
        local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
        if name == "" then
          ui.notify("current buffer has no file on disk", vim.log.levels.WARN)
          return
        end
        ui.add_mention(opts.line1 == opts.line2 and ("%s:L%d"):format(name, opts.line1)
          or ("%s:L%d-%d"):format(name, opts.line1, opts.line2))
      end
    else
      M.add_file()
    end
  elseif sub == "files" then
    M.pick_files()
  elseif sub == "attach" then
    local path = args[2]
    if path and path ~= "" then
      M.attach(path)
    else
      M.pick_files()
    end
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

M._subcommands = { "toggle", "new", "model", "resume", "stop", "usage", "compact", "help", "review", "yolo", "effort", "add", "files", "attach", "ask" }
M._effort_modes = { "minimal", "low", "medium", "high", "adaptive", "off", "1k", "4k", "8k" }

function M._complete(arglead, cmdline)
  local body = cmdline:match("^%S+%s*(.*)$") or ""
  local args = vim.split(vim.trim(body), "%s+", { trimempty = true })
  local pool = M._subcommands
  if #args > 1 or (#args == 1 and body:match("%s$")) then
    if args[1] == "effort" then
      pool = M._effort_modes
    elseif args[1] == "yolo" then
      pool = { "on", "off" }
    else
      pool = {}
    end
  end
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, pool)
end

return M
