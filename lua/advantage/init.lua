---@brief advantage.nvim — a coding-agent harness that lives in Neovim.
---Runs its own agent loop against your Claude (Claude Code login) or
---Codex (ChatGPT login) subscription. No API key required.
local M = {}

local config = require("advantage.config")
local harness = require("advantage.harness")

local initialized = false
local agent_mod, ui, current

local function sync_model_ui(model)
  ui.set_model_label(model.label)
  ui.set_effort_label(require("advantage.effort").describe(model))
end

local function sync_harness_ui(agent)
  ui.set_harness_label(harness.describe(agent.harness_mode, agent.model))
end

local function ensure_init()
  if initialized then return end
  initialized = true
  if not config._setup_done then config.setup({}) end
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
    local model = assert(config.resolve_model(config.options.default_model), "unknown default_model")
    current = agent_mod.new({ model = model })
    if current.harness_mode ~= "auto" and (config.options.harness or {}).sync_effort ~= false then
      harness.sync_effort(model, current.harness_mode)
    end
    sync_model_ui(model)
    sync_harness_ui(current)
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
  map("n", maps.context_preview, function()
    M.context("preview")
  end, "preview context packet")
  map("n", maps.review, M.review, "review agent changes")
  map("n", maps.yolo, M.toggle_yolo, "toggle yolo mode")
  map("n", maps.effort, M.pick_effort, "tune model effort")
  map("n", maps.harness, M.pick_harness, "tune harness mode")
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

---Frozen workspace of the active conversation (used by project-scoped UI
---helpers so `:cd` cannot silently retarget an in-flight session).
function M.cwd()
  return current and current.ctx and current.ctx.cwd or (vim.uv or vim.loop).cwd()
end

---Send a prompt (opens the panel if hidden). While a turn is running, the
---default `mode = "instant"` injects it before the next tool call, answers it,
---then resumes unfinished work; `mode = "queued"` waits for the flow to become idle.
---@param opts? {images?: table[], mode?: "instant"|"queued"}
function M.ask(text, opts)
  local agent = ensure_agent()
  if not ui.is_open() then ui.open(false) end
  agent:send(text, opts)
end

function M.stop()
  ensure_init()
  if current then current:cancel() end
end

function M.new_session()
  ensure_init()
  if current and current:busy() then current:cancel() end
  local model = current and current.model
    or assert(config.resolve_model(config.options.default_model), "unknown default_model")
  local harness_mode = current and current.harness_mode
  current = agent_mod.new({ model = model, harness_mode = harness_mode })
  ui.clear()
  sync_model_ui(model)
  sync_harness_ui(current)
  ui.open()
end

function M.pick_model()
  ensure_init()
  local items = config.options.models
  require("advantage.ui.picker").select(items, {
    prompt = "advantage · model",
    format_item = function(m)
      return ("%s  ·  %s"):format(m.label or m.ref, m.ref)
    end,
  }, function(choice)
    if not choice then return end
    local model = assert(config.resolve_model(choice.ref), "unknown model")
    local detached = 0
    local model_changed = false
    if current then
      if current:busy() then
        ui.notify("finish or cancel the running turn first", vim.log.levels.WARN)
        return
      end
      if current.model.provider ~= model.provider or current.model.id ~= model.id then
        model_changed = true
        current.messages, detached = require("advantage.compact").detach_provider_state(current.messages)
      end
      current.model = model
      current.ctx.model = model
      if current.harness_mode ~= "auto" and (config.options.harness or {}).sync_effort ~= false then
        harness.sync_effort(model, current.harness_mode)
      end
      if model_changed then
        -- Threshold hysteresis and static-prefix estimates are model/transport
        -- specific. Reusing them after a switch can suppress a mandatory compact
        -- for a smaller context window.
        current._auto_compact_floor = nil
        current._request_prefix_tokens = nil
      end
    else
      ensure_agent()
      current.model = model
      current.ctx.model = model
      if current.harness_mode ~= "auto" and (config.options.harness or {}).sync_effort ~= false then
        harness.sync_effort(model, current.harness_mode)
      end
    end
    sync_model_ui(model)
    sync_harness_ui(current)
    ui.notify("model → " .. model.label .. (detached > 0 and " · private reasoning replay reset" or ""))
  end)
end

function M.resume()
  ensure_init()
  local cwd = current and current.ctx and current.ctx.cwd or (vim.uv or vim.loop).cwd()
  require("advantage.session").pick(function(data, prefill)
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
      if model.thinking_mode == nil then model.thinking_mode = data.model.thinking_mode end
      if model.effort == nil then model.effort = data.model.effort end
      if model.effort_levels == nil then model.effort_levels = data.model.effort_levels end
      if model.reasoning_effort == nil then model.reasoning_effort = data.model.reasoning_effort end
      if model.reasoning_efforts == nil then model.reasoning_efforts = data.model.reasoning_efforts end
    end
    current = agent_mod.new({
      id = data.id,
      title = data.title,
      model = model,
      messages = data.messages,
      context_results = data.context_results,
      usage = data.usage,
      cwd = data.cwd or cwd,
      start_cwd = data.start_cwd or data.cwd or cwd,
      harness_mode = data.harness_mode,
    })
    ui.open(false)
    ui.render_transcript(data.messages, model.label)
    ui.set_effort_label(require("advantage.effort").describe(model))
    sync_harness_ui(current)
    ui.set_usage(current.usage)
    ui.open()
    if prefill and prefill ~= "" then ui.set_prompt(prefill) end
  end, cwd)
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

  local ok_fn, expose = pcall(function()
    return vim.fn["netrw#Expose"]
  end)
  if ok_fn and expose then
    local ok, global = pcall(expose, "netrwmarkfilelist")
    if ok and type(global) == "table" then raw = global end

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

local function agent_relative(path)
  local root = current and current.ctx and current.ctx.cwd or (vim.uv or vim.loop).cwd() or ""
  local abs = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  root = vim.fn.fnamemodify(root, ":p"):gsub("/+$", "")
  if abs == root then return "." end
  if vim.startswith(abs, root .. "/") then return abs:sub(#root + 2) end
  return abs
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
  return agent_relative(name)
end

---Visual mode: reference the selection as `@file:L10-20`. The lines are read
---fresh from disk when the message is sent.
function M.add_selection()
  ensure_agent()
  local buf = vim.api.nvim_get_current_buf()
  local from = vim.fn.getpos("v")[2]
  local to = vim.fn.getpos(".")[2]
  if from > to then
    from, to = to, from
  end

  -- leave visual mode synchronously, before switching windows — a queued
  -- <Esc> via feedkeys would land in the prompt window and cancel insert mode
  vim.cmd([[normal! ]] .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  local name = buf_rel_name(buf)
  if not name then return end
  local mention = from == to and ("%s:L%d"):format(name, from) or ("%s:L%d-%d"):format(name, from, to)
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
  if is_netrw_buffer(0) then return M.add_netrw_marked_files() end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    ui.notify("current buffer has no file on disk", vim.log.levels.WARN)
    return
  end
  M.attach(agent_relative(name))
end

---Pick a project file and add it to the chat prompt.
function M.pick_files()
  ensure_agent()
  local files = require("advantage.attach").project_files(2000, current.ctx.cwd)
  if #files == 0 then
    ui.notify("no project files found", vim.log.levels.WARN)
    return
  end
  require("advantage.ui.picker").select(files, { prompt = "advantage · add file" }, function(choice)
    if choice then M.attach(choice) end
  end)
end

---Attach a path: images become message attachments, other files @mentions.
function M.attach(path)
  ensure_agent()
  local attach = require("advantage.attach")
  local ext = path:match("%.(%w+)$")
  if ext and attach.IMAGE_TYPES[ext:lower()] then
    local allow_outside = (config.options.tools or {}).allow_outside_root
    local resolved = require("advantage.util").contain(path, current.ctx.cwd, allow_outside)
    if not resolved then
      ui.notify("attachment path escapes the session workspace: " .. tostring(path), vim.log.levels.WARN)
      return
    end
    local img, err = attach.load_image(resolved)
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

local effort = require("advantage.effort")

local function autosave_agent_settings(agent)
  if not config.options.sessions.autosave then return end
  local ok, err = require("advantage.session").save(agent)
  if not ok then ui.notify("could not autosave session settings: " .. tostring(err), vim.log.levels.WARN) end
end

---Set reasoning/thinking effort directly.
---Values are validated against the selected model's declared capabilities.
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
    local label, err = effort.set_openai(agent.model, mode)
    if not label then
      ui.notify(err, vim.log.levels.WARN)
      return false
    end
    ui.notify("effort → " .. label)
    agent:refresh_prompt_policy()
    ui.set_effort_label(effort.describe(agent.model))
    sync_harness_ui(agent)
    autosave_agent_settings(agent)
    return true
  end

  if agent.model.provider == "anthropic" then
    local label, err = effort.set_anthropic(agent.model, mode)
    if not label then
      ui.notify(err, vim.log.levels.WARN)
      return false
    end
    ui.notify("thinking/effort → " .. label)
    agent:refresh_prompt_policy()
    ui.set_effort_label(effort.describe(agent.model))
    sync_harness_ui(agent)
    autosave_agent_settings(agent)
    return true
  end

  ui.notify("effort controls are not available for " .. tostring(agent.model.provider), vim.log.levels.WARN)
  return false
end

---Set the session's orchestration policy. Selecting an explicit preset
---initializes matching model effort; later `/effort` changes remain independent.
function M.set_harness(mode)
  local agent = ensure_agent()
  if agent:busy() then
    ui.notify("finish or cancel the running turn before changing harness mode", vim.log.levels.WARN)
    return false
  end
  mode = vim.trim(tostring(mode or "")):lower()
  if mode == "" then
    M.pick_harness()
    return true
  end
  if not harness.valid(mode) then
    ui.notify(
      "unknown harness mode: " .. mode .. " (expected auto/low/medium/high/xhigh/max/ultra)",
      vim.log.levels.WARN
    )
    return false
  end

  local effort_label, effort_err
  if mode ~= "auto" and (config.options.harness or {}).sync_effort ~= false then
    effort_label, effort_err = harness.sync_effort(agent.model, mode)
  end
  agent.harness_mode = mode
  agent:refresh_prompt_policy()
  ui.set_effort_label(effort.describe(agent.model))
  sync_harness_ui(agent)
  local effective = harness.policy(mode, agent.model).mode
  local suffix = effort_label and (" · effort → " .. effort_label) or ""
  if effort_err then suffix = suffix .. " · " .. effort_err end
  ui.notify("harness → " .. effective .. suffix, effort_err and vim.log.levels.WARN or nil)
  autosave_agent_settings(agent)
  return true
end

function M.pick_harness()
  local agent = ensure_agent()
  if agent:busy() then
    ui.notify("finish or cancel the running turn before changing harness mode", vim.log.levels.WARN)
    return
  end
  require("advantage.ui.picker").select(harness.items(), {
    prompt = "advantage · harness mode",
    format_item = function(item)
      local active = agent.harness_mode == item.value
      return ("%s %-24s %s"):format(active and "●" or " ", item.label, item.description)
    end,
  }, function(choice)
    if choice then M.set_harness(choice.value) end
  end)
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
    local items = effort.openai_items(agent.model)
    require("advantage.ui.picker").select(items, {
      prompt = "advantage · reasoning effort",
      format_item = function(x)
        return ("%s %s"):format(effort.openai_selected(agent.model, x) and "●" or " ", x.label)
      end,
    }, function(choice)
      if not choice then return end
      M.set_effort(choice.aliases[1])
    end)
    return
  end

  if agent.model.provider == "anthropic" then
    local items = effort.anthropic_items(agent.model)
    require("advantage.ui.picker").select(items, {
      prompt = "advantage · thinking",
      format_item = function(x)
        return ("%s %s"):format(effort.anthropic_selected(agent.model, x) and "●" or " ", x.label)
      end,
    }, function(choice)
      if not choice then return end
      M.set_effort(choice.aliases[1])
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
    dim_labels = 14, -- the two-space gutter + 12-char label column
  })
end

---Force context compaction for the current session.
---@param mode? "llm"|"heuristic" one-off override of context.compact_mode
function M.compact(mode)
  local agent = ensure_agent()
  mode = mode and mode ~= "" and mode or nil
  if mode and mode ~= "llm" and mode ~= "heuristic" then
    ui.notify("unknown compact mode: " .. tostring(mode) .. " (expected llm or heuristic)", vim.log.levels.WARN)
    return
  end
  agent:compact({ mode = mode }, function(info)
    if not info then ui.notify("context is already compact enough") end
  end)
end

---View / manage the per-repo learned memory (also `/context`).
---`context` shows it; `context verify` flags facts whose paths vanished;
---`context forget <text>` drops matching facts.
---`/context init` — claude /init parity: one agent pass that explores the repo
---and fills the memory via remember/save_skill, instead of organic learning only.
local function context_init(memory)
  if not memory.enabled() then
    return ui.notify("memory is disabled (config.memory.enabled = false)", vim.log.levels.WARN)
  end
  memory.bootstrap()
  M.ask(memory.init_prompt())
end

---`/context curate` — compression pass: the agent rewrites its memory tighter and
---extracts procedural bullets into skills (index-only cost).
local function context_curate(memory)
  if not memory.enabled() then
    return ui.notify("memory is disabled (config.memory.enabled = false)", vim.log.levels.WARN)
  end
  M.ask(memory.curate_prompt())
end

---`/context verify` — flag learned facts whose referenced paths no longer exist.
local function context_verify(memory)
  local stale = memory.verify()
  if #stale == 0 then return ui.notify("repo memory: every referenced path still resolves ✓") end
  local lines = { "# stale facts — referenced paths no longer exist", "" }
  for _, s in ipairs(stale) do
    lines[#lines + 1] = ("- [%s] %s"):format(s.section, s.bullet)
    lines[#lines + 1] = ("    ↳ missing: %s"):format(s.missing)
  end
  ui.float({ title = "advantage · memory verify", lines = lines, filetype = "markdown", footer = "q close" })
end

---`/context preview` — show the exact context packet (system prompt + tools +
---transcript) with the cache boundary drawn and a token breakdown; nothing sent.
local function context_preview()
  local lines = require("advantage.context_preview").build(current)
  ui.float({
    title = "advantage · context preview",
    lines = lines,
    filetype = "markdown",
    footer = "q close · cached prefix billed ~10% after turn 1",
  })
end

---`/context forget <text>` — drop matching facts and unfreeze the memory block.
local function context_forget(memory, args)
  local pattern = table.concat(vim.list_slice(args, 2), " ")
  if pattern == "" then return ui.notify("usage: /context forget <text to match>", vim.log.levels.WARN) end
  local n, err = memory.forget(pattern)
  if err then return ui.notify("could not update repo memory: " .. tostring(err), vim.log.levels.ERROR) end
  -- drop the frozen memory block so the forgotten fact leaves the live prefix
  if n > 0 and current then
    current._memory_block = nil
    current._request_prefix_tokens = nil
  end
  ui.notify(
    n > 0 and ("forgot %d fact%s matching %q"):format(n, n == 1 and "" or "s", pattern)
      or ("no facts matched %q"):format(pattern)
  )
end

---`/context` (default) — show the rendered memory block, or an empty-state hint.
local function context_show(memory)
  local block = memory.render()
  local lines = (block ~= "" and vim.split(block, "\n", { plain = true }))
    or {
      "Repo memory is empty.",
      "",
      "Run /context init to have the agent learn this repo now,",
      "or let it fill in as you work. Stored under " .. memory.root() .. "/.advantage/",
    }
  ui.float({
    title = "advantage · memory",
    lines = lines,
    filetype = "markdown",
    footer = "q close · /context init · curate · verify · preview · forget <text>",
  })
end

function M.context(arg)
  ensure_init()
  local memory = require("advantage.memory")
  local cwd = (current and current.ctx and current.ctx.cwd) or (vim.uv or vim.loop).cwd()
  return memory.with_root(cwd, function()
    local args = vim.split(vim.trim(tostring(arg or "")), "%s+", { trimempty = true })
    local action = args[1] or "show"

    if action == "init" then
      context_init(memory)
    elseif action == "curate" then
      context_curate(memory)
    elseif action == "verify" then
      context_verify(memory)
    elseif action == "preview" then
      context_preview()
    elseif action == "forget" then
      context_forget(memory, args)
    else
      context_show(memory)
    end
  end)
end

---Show the keybind and command cheatsheet.
function M.help()
  ensure_init()
  ui.show_help()
end

---`:Advantage add` — attach the current file, a visual range, or a netrw
---selection, depending on the command's range and buffer.
local function cmd_add(opts)
  assert(type(opts) == "table", "cmd_add: command opts table required")
  if not (opts.range and opts.range > 0) then return M.add_file() end
  if is_netrw_buffer(0) then
    local files, skipped = netrw_line_files(opts.line1, opts.line2)
    if #files == 0 then
      local msg = skipped > 0 and "no regular files in selected netrw lines" or "no netrw files selected"
      return ui.notify(msg, vim.log.levels.WARN)
    end
    for _, file in ipairs(files) do
      M.attach(file)
    end
    local extra = skipped > 0 and ("; skipped " .. skipped .. " non-file item" .. (skipped == 1 and "" or "s")) or ""
    return ui.notify("added " .. #files .. " netrw file" .. (#files == 1 and "" or "s") .. extra)
  end
  -- ranged form: :'<,'>Advantage add → @file:L10-20
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  if name == "" then return ui.notify("current buffer has no file on disk", vim.log.levels.WARN) end
  ui.add_mention(
    opts.line1 == opts.line2 and ("%s:L%d"):format(name, opts.line1)
      or ("%s:L%d-%d"):format(name, opts.line1, opts.line2)
  )
end

---`:Advantage ask <text>` — send the remaining args, optionally appending the
---visually-selected range as a fenced code block.
local function cmd_ask(opts, args)
  assert(type(opts) == "table" and type(args) == "table", "cmd_ask: opts and args tables required")
  local text = table.concat(vim.list_slice(args, 2), " ")
  if opts.range and opts.range > 0 then
    local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
    text = text
      .. ("\n\n```%s %s#L%d-L%d\n%s\n```"):format(
        vim.bo.filetype or "",
        name,
        opts.line1,
        opts.line2,
        table.concat(lines, "\n")
      )
  end
  if vim.trim(text) ~= "" then M.ask(text) end
end

---`:Advantage yolo [on|off]` — set or toggle the auto-approve-everything mode.
local function cmd_yolo(args)
  local want = args[2]
  if want == "on" or want == "off" then
    -- set the opposite, then toggle: keeps all messaging in one place
    config.options.tools.yolo = want == "off"
  end
  M.toggle_yolo()
end

---`:Advantage attach [path]` — attach a named file, or open the file picker.
local function cmd_attach(args)
  local path = args[2]
  if path and path ~= "" then
    M.attach(path)
  else
    M.pick_files()
  end
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
    M.compact(args[2])
  elseif sub == "context" or sub == "memory" then
    M.context(table.concat(vim.list_slice(args, 2), " "))
  elseif sub == "help" or sub == "keys" then
    M.help()
  elseif sub == "review" or sub == "diff" then
    M.review()
  elseif sub == "yolo" then
    cmd_yolo(args)
  elseif sub == "effort" then
    if args[2] then
      M.set_effort(args[2])
    else
      M.pick_effort()
    end
  elseif sub == "harness" or sub == "mode" then
    if args[2] then
      M.set_harness(args[2])
    else
      M.pick_harness()
    end
  elseif sub == "add" then
    cmd_add(opts)
  elseif sub == "files" then
    M.pick_files()
  elseif sub == "attach" then
    cmd_attach(args)
  elseif sub == "ask" then
    cmd_ask(opts, args)
  else
    ui.notify("unknown subcommand: " .. sub, vim.log.levels.WARN)
  end
end

M._subcommands = {
  "toggle",
  "new",
  "model",
  "resume",
  "stop",
  "usage",
  "compact",
  "context",
  "help",
  "review",
  "yolo",
  "effort",
  "harness",
  "mode",
  "add",
  "files",
  "attach",
  "ask",
}
-- Union of the aliases set_effort accepts (OpenAI + Anthropic); the picker
-- validates per-provider, so a completion offered to the wrong provider is a
-- harmless no-op rather than the old silent gap.
M._effort_modes = {
  "default",
  "off",
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "higher",
  "highest",
  "max",
  "adaptive",
  "1k",
  "4k",
  "8k",
  "10k",
  "16k",
  "32k",
  "think",
  "think-hard",
  "think-harder",
  "ultrathink",
  "xhigh",
}

M._harness_modes = { "auto", "low", "medium", "high", "xhigh", "max", "ultra" }

function M._complete(arglead, cmdline)
  local body = cmdline:match("^%S+%s*(.*)$") or ""
  local args = vim.split(vim.trim(body), "%s+", { trimempty = true })
  local pool = M._subcommands
  if #args > 1 or (#args == 1 and body:match("%s$")) then
    if args[1] == "effort" then
      pool = M._effort_modes
    elseif args[1] == "harness" or args[1] == "mode" then
      pool = M._harness_modes
    elseif args[1] == "yolo" then
      pool = { "on", "off" }
    elseif args[1] == "context" or args[1] == "memory" then
      pool = { "init", "curate", "verify", "preview", "forget" }
    else
      pool = {}
    end
  end
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, pool)
end

return M
