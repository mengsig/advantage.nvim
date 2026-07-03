---@brief The harness loop: stream a turn, execute requested tools (with
---permission gating), feed results back, repeat until the model stops.
local config = require("advantage.config")
local providers = require("advantage.providers")
local tools = require("advantage.tools")

local M = {}

local uv = vim.uv or vim.loop

local Agent = {}
Agent.__index = Agent

local function default_system_prompt()
  local cwd = uv.cwd()
  local lines = {
    "You are advantage, an expert coding agent running inside Neovim, working directly in the user's project.",
    "",
    "Project root: " .. cwd,
    "Platform: " .. (uv.os_uname().sysname or "unknown"),
    "",
    "Rules:",
    "- Use the tools to read, search, edit and run things. Paths are relative to the project root.",
    "- Read before you edit. Prefer edit_file for surgical changes; write_file only for new or fully rewritten files.",
    "- After a code change, verify it when a cheap check exists (build, test, syntax check).",
    "- Be direct and concise. Lead with what you did or found; skip filler and restating the request.",
    "- If a task is ambiguous, state your assumption and proceed rather than stalling.",
  }
  return table.concat(lines, "\n")
end

function M.system_prompt()
  local cfg = config.options.system_prompt
  local base = default_system_prompt()
  if type(cfg) == "string" then return cfg end
  if type(cfg) == "function" then return cfg(base) end
  return base
end

---@param opts {model: table, messages?: table, id?: string, title?: string, usage?: table}
function M.new(opts)
  local self = setmetatable({}, Agent)
  self.id = opts.id or tostring(os.time()) .. "-" .. math.random(1000, 9999)
  self.model = opts.model
  self.messages = opts.messages or {}
  self.title = opts.title
  self.usage = opts.usage or { input = 0, output = 0 }
  self.status = "idle" -- idle | streaming | tools
  self.job = nil
  self.cancelled = false
  self.turn_started = nil
  self.turn_usage = { input = 0, output = 0 }
  self.turn_open = false
  self.ctx = { cwd = uv.cwd() }
  self.allowed = {} -- per-session "always allow" tool names
  self.queue = {} -- messages submitted while a turn was running
  self.snapshots = {} -- abs path -> content before the agent's first touch (false = new file)
  self.turn_changed = {} -- abs paths changed during the current turn
  return self
end

function Agent:ui()
  return require("advantage.ui.chat")
end

function Agent:busy()
  return self.status ~= "idle"
end

---Entry point: user sends a prompt. While a turn is running, messages are
---queued and dispatched one by one as turns finish.
---@param opts? {images?: {name:string, media_type:string, data:string}[]}
function Agent:send(text, opts)
  opts = opts or {}
  if self:busy() then
    self.queue[#self.queue + 1] = { text = text, opts = opts }
    self:ui().queued(#self.queue, text)
    return
  end
  if not self.title then
    self.title = text:gsub("%s+", " "):sub(1, 56)
  end

  -- inline @file mentions; the transcript shows the original text
  local send_text = require("advantage.attach").expand_mentions(text, self.ctx.cwd)
  local content = {}
  for _, img in ipairs(opts.images or {}) do
    content[#content + 1] = {
      type = "image",
      source = { type = "base64", media_type = img.media_type, data = img.data },
    }
  end
  content[#content + 1] = { type = "text", text = send_text }

  table.insert(self.messages, { role = "user", content = content })
  self:ui().user_message(text, opts.images)
  self.cancelled = false
  self.turn_started = uv.hrtime()
  self.turn_usage = { input = 0, output = 0 }
  self.turn_open = false
  self.turn_changed = {}
  self:_turn()
end

local MUTATING = { write_file = true, edit_file = true }

---Remember a file's pre-edit content so `/review` can diff against it.
function Agent:_snapshot(call)
  if not MUTATING[call.name] then return end
  local path = tools.resolve and tools.resolve(call.input and call.input.path, self.ctx)
  if not path then return end
  if self.snapshots[path] == nil then
    local f = io.open(path, "r")
    self.snapshots[path] = f and f:read("*a") or false
    if f then f:close() end
  end
  return path
end

function Agent:_turn()
  local provider = providers.get(self.model.provider)
  if not provider then
    self:ui().notify("unknown provider: " .. tostring(self.model.provider), vim.log.levels.ERROR)
    return
  end

  self.status = "streaming"
  local ui = self:ui()
  if not self.turn_open then
    ui.begin_assistant(self.model.label)
    self.turn_open = true
  end
  ui.set_status("streaming")

  self.job = provider.stream({
    model = self.model,
    system = M.system_prompt(),
    messages = self.messages,
    tools = tools.schemas(),
    on = {
      text = function(chunk)
        ui.stream_text(chunk)
      end,
      thinking = function(chunk)
        ui.stream_thinking(chunk)
      end,
      tool_start = function(id, name)
        ui.tool_begin(id, name)
      end,
      auth = function(badge)
        ui.set_auth(badge)
      end,
      usage = function(inp, out)
        self.usage.input = self.usage.input + inp
        self.usage.output = self.usage.output + out
        self.turn_usage.input = self.turn_usage.input + inp
        self.turn_usage.output = self.turn_usage.output + out
        ui.set_usage(self.usage)
        require("advantage.usage").record(self.model, inp, out)
      end,
      complete = function(blocks, stop_reason)
        self.job = nil
        if self.cancelled then return end
        if #blocks > 0 then
          table.insert(self.messages, { role = "assistant", content = blocks })
        end
        ui.message_meta(self.turn_usage, self.turn_started and (uv.hrtime() - self.turn_started) or nil)

        if stop_reason == "tool_use" then
          local calls = {}
          for _, b in ipairs(blocks) do
            if b.type == "tool_use" then calls[#calls + 1] = b end
          end
          if #calls > 0 then
            return self:_run_tools(calls)
          end
        end

        if stop_reason == "refusal" then
          ui.notice("the model declined this request (safety refusal)")
        elseif stop_reason == "max_tokens" then
          ui.notice("response hit the output-token limit and was truncated")
        end
        self:_finish()
      end,
      error = function(msg)
        self.job = nil
        if self.cancelled then return end
        ui.notice("error: " .. msg)
        self:_finish(true)
      end,
    },
  })
end

function Agent:_run_tools(calls)
  self.status = "tools"
  local ui = self:ui()
  local cfg = config.options
  local results = {}

  local function finish_tools()
    if self.cancelled then return end
    table.insert(self.messages, { role = "user", content = results })
    self:_turn()
  end

  local run_next
  local function record(call, output, is_error)
    results[#results + 1] = {
      type = "tool_result",
      tool_use_id = call.id,
      content = output,
      is_error = is_error or nil,
    }
  end

  local i = 0
  run_next = function()
    if self.cancelled then return end
    i = i + 1
    local call = calls[i]
    if not call then
      return finish_tools()
    end

    local tool = tools.get(call.name)
    if not tool then
      record(call, "Unknown tool: " .. tostring(call.name), true)
      ui.tool_update(call.id, { status = "error", detail = "unknown tool" })
      return run_next()
    end

    local detail = tool.summary and tool.summary(call.input) or nil
    ui.tool_update(call.id, { name = call.name, detail = detail })

    local function execute()
      ui.set_status("tool", call.name)
      ui.tool_update(call.id, { status = "running" })
      local touched = self:_snapshot(call)
      local ok, err = pcall(tool.run, call.input, self.ctx, vim.schedule_wrap(function(output, is_error)
        if self.cancelled then return end
        record(call, output, is_error)
        ui.tool_update(call.id, { status = is_error and "error" or "ok" })
        if touched and not is_error then
          self.turn_changed[touched] = true
        end
        run_next()
      end))
      if not ok then
        record(call, "Tool crashed: " .. tostring(err), true)
        ui.tool_update(call.id, { status = "error" })
        run_next()
      end
    end

    if tool.safe or self.allowed[call.name] or cfg.tools.auto_approve[call.name] or cfg.tools.yolo then
      return execute()
    end

    local preview = tool.preview and tool.preview(call.input, self.ctx)
      or { title = call.name, lines = vim.split(vim.inspect(call.input), "\n"), filetype = "lua" }
    ui.tool_update(call.id, { status = "waiting" })
    ui.set_status("waiting", call.name)
    ui.confirm(preview, function(decision, comment)
      if self.cancelled then return end
      if decision == "always" then
        self.allowed[call.name] = true
        return execute()
      elseif decision == "allow" then
        return execute()
      else
        local msg = "The user denied this action."
        if comment and comment ~= "" then
          msg = msg .. " Their feedback: " .. comment
          ui.notice("deny → " .. comment)
        else
          msg = msg .. " Ask before retrying, or take a different approach."
        end
        record(call, msg, true)
        ui.tool_update(call.id, { status = "denied" })
        run_next()
      end
    end)
  end

  run_next()
end

function Agent:_finish(errored)
  self.status = "idle"
  local ui = self:ui()
  ui.finish_turn(self.turn_started and (uv.hrtime() - self.turn_started) or nil)
  ui.set_status("idle")
  if not errored and config.options.sessions.autosave then
    require("advantage.session").save(self)
  end
  local changed = vim.tbl_count(self.turn_changed or {})
  if changed > 0 and not self.cancelled then
    ui.notice(("%d file%s changed — /review to inspect"):format(changed, changed == 1 and "" or "s"))
    self.turn_changed = {}
  end
  -- dispatch the next queued message, if any
  if not errored and not self.cancelled and #self.queue > 0 then
    local nxt = table.remove(self.queue, 1)
    ui.set_queue(#self.queue)
    vim.schedule(function()
      if not self:busy() then
        self:send(nxt.text, nxt.opts)
      end
    end)
  else
    ui.set_queue(#self.queue)
  end
end

function Agent:cancel()
  if not self:busy() then return end
  self.cancelled = true
  if #self.queue > 0 then
    self:ui().notice(("dropped %d queued message%s"):format(#self.queue, #self.queue == 1 and "" or "s"))
    self.queue = {}
  end
  if self.job then
    self.job.stop()
    self.job = nil
  end
  -- Drop any half-finished exchange so the transcript stays consistent:
  -- the last message must be a completed user or assistant message.
  local last = self.messages[#self.messages]
  if last and last.role == "assistant" then
    local has_tool = false
    for _, b in ipairs(last.content) do
      if b.type == "tool_use" then has_tool = true end
    end
    if has_tool then table.remove(self.messages) end
  end
  self:ui().notice("cancelled")
  self:_finish(true)
end

return M
