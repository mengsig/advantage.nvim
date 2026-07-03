---@brief The harness loop: stream a turn, execute requested tools (with
---permission gating), feed results back, repeat until the model stops.
local config = require("advantage.config")
local providers = require("advantage.providers")
local tools = require("advantage.tools")

local M = {}

local uv = vim.uv or vim.loop

local Agent = {}
Agent.__index = Agent

local function git_branch(cwd)
  local head = io.open(cwd .. "/.git/HEAD", "r")
  if not head then return nil end
  local ref = head:read("*l") or ""
  head:close()
  return ref:match("ref: refs/heads/(.+)$") or ref:sub(1, 8)
end

local function default_system_prompt()
  local cwd = uv.cwd()
  local branch = git_branch(cwd)
  local lines = {
    "You are advantage, an expert coding agent running inside Neovim, working directly in the user's project.",
    "",
    "Environment:",
    "- Project root: " .. cwd,
    "- Platform: " .. (uv.os_uname().sysname or "unknown"),
  }
  if branch then lines[#lines + 1] = "- Git branch: " .. branch end
  vim.list_extend(lines, {
    "",
    "How to work:",
    "- Use the tools to read, search, edit and run things. Paths are relative to the project root.",
    "- Gather context before acting: read the files and search the code rather than guessing. Batch independent reads/searches in one step, and delegate wide fan-out investigations to the read-only `sub_agent` tool.",
    "- Read a file before editing it. Prefer edit_file for surgical changes; write_file only for new or fully rewritten files.",
    "- Match the surrounding code's style, naming and conventions. Don't add comments that just restate the code.",
    "- After a code change, verify it when a cheap check exists (build, test, lint, syntax check), and fix what you broke.",
    "- For multi-step work, keep a plan with the todo_write tool and update statuses as you go; several changes to one file go in a single multi_edit call.",
    "- Stay within the project: file tools are confined to the project root. Ask before anything destructive or irreversible.",
    "",
    "Style: be direct and concise. Lead with what you did or found; skip filler and restating the request. If a task is ambiguous, state your assumption and proceed rather than stalling.",
  })
  return table.concat(lines, "\n")
end

---Instructions for the memory tools. Only injected while memory is enabled —
---teaching the model to call `remember`/`use_skill` when those tools are absent
---from the schema would just produce "Unknown tool" errors.
local MEMORY_GUIDE = table.concat({
  "Persistent repo memory (this is your edge — it makes you faster and cheaper over time):",
  "- Repo memory and skills are injected below. Treat repo memory as trusted prior knowledge about THIS codebase; prefer it over re-deriving the same facts.",
  "- When you learn a durable, non-obvious fact future sessions would want — an architecture invariant, a convention, a build/test command, a gotcha, or a preference the user states — call `remember` to save it (one crisp fact, right section). Don't record trivia or anything a quick file read re-derives.",
  "- A skill is a reusable procedure. When a listed skill's description matches the task, call `use_skill` to load its full steps before doing that task. Codify a genuinely reusable multi-step procedure with `save_skill`.",
}, "\n")

function M.system_prompt()
  local cfg = config.options.system_prompt
  local base = default_system_prompt()
  if type(cfg) == "string" then
    base = cfg
  elseif type(cfg) == "function" then
    base = cfg(base)
  end
  -- Append the memory-tool instructions plus the per-repo learned context and
  -- skills index. It rides the cached system prefix, so after the first turn it
  -- costs ~10%, and it saves tokens by sparing the model repeated read/grep
  -- loops to re-derive known facts. Skipped entirely when memory is disabled.
  local ok, memory = pcall(require, "advantage.memory")
  if ok and memory.enabled() then
    base = base .. "\n\n" .. MEMORY_GUIDE
    local block = memory.render()
    if block and block ~= "" then base = base .. "\n\n" .. block end
  end
  return base
end

---@param opts {model: table, messages?: table, id?: string, title?: string, usage?: table}
function M.new(opts)
  local self = setmetatable({}, Agent)
  self.id = opts.id or tostring(os.time()) .. "-" .. math.random(1000, 9999)
  self.model = opts.model
  self.messages = opts.messages or {}
  self.title = opts.title
  self.usage = opts.usage or { input = 0, output = 0, cached = 0 }
  self.status = "idle" -- idle | streaming | tools
  self.job = nil
  self.cancelled = false
  self.turn_started = nil
  self.turn_usage = { input = 0, output = 0, cached = 0 }
  self.turn_open = false
  self.ctx = { cwd = uv.cwd(), model = self.model }
  self.allowed = {} -- per-session "always allow" tool names
  self.queue = {} -- Ctrl-S messages submitted while a turn was running
  self.interrupts = {} -- Enter messages to inject before the next tool call
  self.pending_permission = nil -- callable that resolves the active permission card
  self.active_tools = {} -- tool_use_id -> cancellable handle returned by a running tool
  self.snapshots = {} -- abs path -> content before the agent's first touch (false = new file)
  self.turn_changed = {} -- abs paths changed during the current turn
  -- fresh conversation: allow skills to be hinted again, restart savings math,
  -- and seed the on-disk memory file the first time this repo is used
  pcall(function()
    local memory = require("advantage.memory")
    memory.reset_session()
    if memory.bootstrap() then
      vim.schedule(function()
        pcall(
          require("advantage.ui.chat").notify,
          "repo memory created (.advantage/context.md) — /context init teaches the agent this repo now",
          vim.log.levels.INFO
        )
      end)
    end
  end)
  return self
end

function Agent:ui()
  return require("advantage.ui.chat")
end

function Agent:busy()
  return self.status ~= "idle"
end

function Agent:compact()
  if self:busy() then
    self:ui().notify("finish or cancel the running turn before compacting context", vim.log.levels.WARN)
    return nil
  end
  return self:_maybe_compact(true)
end

local function user_content(text, opts, cwd)
  opts = opts or {}
  -- inline @file mentions; the transcript shows the original text
  local send_text = require("advantage.attach").expand_mentions(text, cwd)
  -- Auto-surface relevant skills: a deterministic keyword match against the
  -- skill index appends a one-line hint to the outgoing message (never the
  -- system prompt, so the cached prefix stays byte-identical). Once per skill
  -- per session; the transcript shows the user's original text.
  local mok, memory = pcall(require, "advantage.memory")
  if mok then
    local hints = memory.skill_hints(text)
    if #hints > 0 then
      local lines = { "", "<repo-skill-hint>" }
      for _, s in ipairs(hints) do
        lines[#lines + 1] = ("The %q skill may apply here (%s). If relevant, load its steps with use_skill before proceeding."):format(
          s.name,
          s.description
        )
      end
      lines[#lines + 1] = "</repo-skill-hint>"
      send_text = send_text .. table.concat(lines, "\n")
    end
  end
  local content = {}
  for _, img in ipairs(opts.images or {}) do
    content[#content + 1] = {
      type = "image",
      source = { type = "base64", media_type = img.media_type, data = img.data },
    }
  end
  content[#content + 1] = { type = "text", text = send_text }
  return content
end

function Agent:_push_user_message(text, opts, show)
  local content = user_content(text, opts, self.ctx.cwd)
  table.insert(self.messages, { role = "user", content = content })
  if show ~= false then self:ui().user_message(text, opts and opts.images) end
end

---Entry point: user sends a prompt. While a turn is running, `mode = "queued"`
---queues behind the whole agent flow; the default `mode = "instant"` injects the
---message before the next tool call without cancelling the current response.
---@param opts? {images?: {name:string, media_type:string, data:string}[], mode?: "instant"|"queued"}
function Agent:send(text, opts)
  opts = opts or {}
  if self:busy() then
    if opts.mode == "queued" then
      self.queue[#self.queue + 1] = { text = text, opts = opts }
      self:ui().queued(#self.queue, text)
      return
    end
    local item = { text = text, opts = opts, content = user_content(text, opts, self.ctx.cwd) }
    self.interrupts[#self.interrupts + 1] = item
    self:ui().user_message(text, opts.images)
    self:ui().notice("will send before the next tool call")
    if self.pending_permission then self.pending_permission("interrupt") end
    return
  end
  if not self.title then self.title = text:gsub("%s+", " "):sub(1, 56) end

  self:_push_user_message(text, opts)
  self.cancelled = false
  self.turn_started = uv.hrtime()
  self.turn_usage = { input = 0, output = 0, cached = 0 }
  self.turn_open = false
  self.turn_changed = {}
  self:_turn()
end

function Agent:_drain_interrupts(results, remaining_calls)
  if #self.interrupts == 0 then return false end
  results = results or {}
  for _, call in ipairs(remaining_calls or {}) do
    results[#results + 1] = {
      type = "tool_result",
      tool_use_id = call.id,
      content = "Tool skipped because the user sent a new message before it ran.",
      is_error = true,
    }
    self:ui().tool_update(call.id, { status = "denied", detail = "interrupted" })
  end

  -- Keep synthetic tool results and the user's new message as distinct turns.
  -- Anthropic permits tool_result blocks in user messages, while OpenAI's
  -- Responses API is much stricter about function_call_output sequencing; a
  -- mixed "tool_result + text" content array can produce 400s after an
  -- interrupt.  The canonical history therefore becomes:
  --   assistant(tool_use), user(tool_result...), user(actual interruption)
  if #results > 0 then table.insert(self.messages, { role = "user", content = results }) end
  for _, item in ipairs(self.interrupts) do
    table.insert(self.messages, { role = "user", content = item.content })
  end
  self.interrupts = {}
  return true
end

function Agent:_drain_interrupts_as_user_messages()
  if #self.interrupts == 0 then return false end
  for _, item in ipairs(self.interrupts) do
    table.insert(self.messages, { role = "user", content = item.content })
  end
  self.interrupts = {}
  return true
end

local MUTATING = { write_file = true, edit_file = true, multi_edit = true }

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

function Agent:_maybe_compact(force)
  local cfg = config.options.context or {}
  if not force and cfg.auto_compact == false then return nil end
  local compact = require("advantage.compact")
  local next_messages, info
  if force then
    next_messages, info = compact.force(self.messages, cfg)
  else
    next_messages, info = compact.compact(self.messages, cfg)
  end
  if info then
    self.messages = next_messages
    self:ui().notice(
      ("compacted %d old messages (~%s → ~%s tokens)"):format(
        info.compacted_messages,
        require("advantage.util").fmt_tokens(info.before_tokens),
        require("advantage.util").fmt_tokens(info.after_tokens)
      )
    )
  end
  return info
end

function Agent:_turn()
  local ok, err = pcall(function()
    self:_turn_impl()
  end)
  if not ok then
    self.job = nil
    self:ui().notice("error starting turn: " .. tostring(err))
    self:_finish(true)
  end
end

function Agent:_turn_impl()
  self.ctx.model = self.model
  -- Compaction is best-effort: a failure here must not abort the user's turn,
  -- so fall through to streaming with un-compacted history rather than erroring.
  pcall(function()
    self:_maybe_compact(false)
  end)
  -- provider-request count; /usage uses it for the harness savings math
  self.usage.turns = (self.usage.turns or 0) + 1

  local provider = providers.get(self.model.provider)
  if not provider then
    self:ui().notify("unknown provider: " .. tostring(self.model.provider), vim.log.levels.ERROR)
    self:_finish(true)
    return
  end

  self.status = "streaming"
  self.ctx.system = M.system_prompt()
  local ui = self:ui()
  if not self.turn_open then
    ui.begin_assistant(self.model.label)
    self.turn_open = true
  end
  ui.set_status("streaming")

  self.job = provider.stream({
    model = self.model,
    system = self.ctx.system,
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
      usage = function(inp, out, cached)
        cached = cached or 0
        self.usage.input = self.usage.input + inp
        self.usage.output = self.usage.output + out
        self.usage.cached = (self.usage.cached or 0) + cached
        self.turn_usage.input = self.turn_usage.input + inp
        self.turn_usage.output = self.turn_usage.output + out
        self.turn_usage.cached = (self.turn_usage.cached or 0) + cached
        ui.set_usage(self.usage)
        require("advantage.usage").record(self.model, inp, out, cached)
      end,
      complete = function(blocks, stop_reason)
        self.job = nil
        if self.cancelled then return end
        if #blocks > 0 then table.insert(self.messages, { role = "assistant", content = blocks }) end
        ui.message_meta(self.turn_usage, self.turn_started and (uv.hrtime() - self.turn_started) or nil)

        if stop_reason == "tool_use" then
          local calls = {}
          for _, b in ipairs(blocks) do
            if b.type == "tool_use" then calls[#calls + 1] = b end
          end
          if #calls > 0 then
            if self:_drain_interrupts(nil, calls) then
              self.turn_started = uv.hrtime()
              self.turn_usage = { input = 0, output = 0, cached = 0 }
              self.turn_open = false
              return self:_turn()
            end
            return self:_run_tools(calls)
          end
        end

        if self:_drain_interrupts_as_user_messages() then
          self.turn_started = uv.hrtime()
          self.turn_usage = { input = 0, output = 0, cached = 0 }
          self.turn_open = false
          return self:_turn()
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

---Fan-out fast path: a batch of read-only `sub_agent` calls needs no permission
---prompts and shares no mutable state, so we launch them together and let their
---network round-trips overlap on the event loop instead of running end-to-end
---one at a time. Results are collected by position and fed back once all settle.
---`seed` carries tool_results already produced by a sequential prefix of the
---same batch (e.g. a todo_write ahead of the fan-out); they lead the reply.
function Agent:_run_tools_parallel(calls, seed)
  local ui = self:ui()
  local results, pending, finished, launching = {}, #calls, false, true

  local function maybe_finish()
    if finished or launching or pending > 0 then return end
    finished = true
    if self.cancelled then return end
    local dense = {}
    for _, r in ipairs(seed or {}) do
      dense[#dense + 1] = r
    end
    for i = 1, #calls do
      if results[i] then dense[#dense + 1] = results[i] end
    end
    table.insert(self.messages, { role = "user", content = dense })
    self:_turn()
  end

  for idx, call in ipairs(calls) do
    local tool = tools.get(call.name)
    local detail = tool and tool.summary and tool.summary(call.input) or nil
    ui.tool_update(call.id, { name = call.name, detail = detail, status = "running" })
    ui.set_status("tool", call.name)

    local function settle(output, is_error)
      if self.cancelled then return end
      results[idx] = { type = "tool_result", tool_use_id = call.id, content = output, is_error = is_error or nil }
      ui.tool_update(call.id, { status = is_error and "error" or "ok" })
      pending = pending - 1
      maybe_finish()
    end

    if not tool then
      settle("Unknown tool: " .. tostring(call.name), true)
    else
      local done = false
      local ok, handle = pcall(
        tool.run,
        call.input,
        self.ctx,
        vim.schedule_wrap(function(output, is_error, meta)
          if self.cancelled then return end
          if meta and meta.stream then
            if ui.tool_output then ui.tool_output(call.id, output or "") end
            return
          end
          if done then return end
          done = true
          self.active_tools[call.id] = nil
          settle(output, is_error)
        end)
      )
      if ok and type(handle) == "table" and (handle.stop or handle.kill) then
        self.active_tools[call.id] = handle
      elseif not ok then
        done = true
        self.active_tools[call.id] = nil
        settle("Tool crashed: " .. tostring(handle), true)
      end
    end
  end

  launching = false
  maybe_finish()
end

function Agent:_run_tools(calls)
  self.status = "tools"
  local ui = self:ui()
  local cfg = config.options

  -- Read-only sub_agent calls need no permission prompts and share no mutable
  -- state, so once only sub_agents remain in the batch the rest fan out
  -- concurrently. Any mutating or permission-gated tools ahead of them (a
  -- todo_write before the fan-out, say) still run in strict order first;
  -- run_next hands off to the parallel path at that boundary.
  local parallel_subagents = cfg.subagents and cfg.subagents.parallel ~= false

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
    if #self.interrupts > 0 then
      local remaining = {}
      for j = i + 1, #calls do
        remaining[#remaining + 1] = calls[j]
      end
      self:_drain_interrupts(results, remaining)
      self.turn_started = uv.hrtime()
      self.turn_usage = { input = 0, output = 0, cached = 0 }
      self.turn_open = false
      return self:_turn()
    end
    if parallel_subagents and #calls - i > 1 then
      local tail_all_subagent = true
      for j = i + 1, #calls do
        if calls[j].name ~= "sub_agent" then
          tail_all_subagent = false
          break
        end
      end
      if tail_all_subagent then
        local tail = {}
        for j = i + 1, #calls do
          tail[#tail + 1] = calls[j]
        end
        return self:_run_tools_parallel(tail, results)
      end
    end
    i = i + 1
    local call = calls[i]
    if not call then return finish_tools() end

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
      local settled = false
      local ok, handle_or_err = pcall(
        tool.run,
        call.input,
        self.ctx,
        vim.schedule_wrap(function(output, is_error, meta)
          if self.cancelled then return end
          if meta and meta.stream then
            if ui.tool_output then ui.tool_output(call.id, output or "") end
            return
          end
          if settled then return end
          settled = true
          self.active_tools[call.id] = nil
          record(call, output, is_error)
          ui.tool_update(call.id, { status = is_error and "error" or "ok" })
          if touched and not is_error then self.turn_changed[touched] = true end
          run_next()
        end)
      )
      if ok and type(handle_or_err) == "table" and (handle_or_err.stop or handle_or_err.kill) then
        self.active_tools[call.id] = handle_or_err
      end
      if not ok then
        settled = true
        self.active_tools[call.id] = nil
        record(call, "Tool crashed: " .. tostring(handle_or_err), true)
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
    self.pending_permission = ui.confirm(preview, function(decision, comment)
      self.pending_permission = nil
      if self.cancelled then return end
      if decision == "always" then
        self.allowed[call.name] = true
        return execute()
      elseif decision == "allow" then
        return execute()
      elseif decision == "interrupt" then
        record(call, "Tool skipped because the user sent a new message before it ran.", true)
        ui.tool_update(call.id, { status = "denied", detail = "interrupted" })
        run_next()
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
    if #self.interrupts > 0 and self.pending_permission then self.pending_permission("interrupt") end
  end

  run_next()
end

function Agent:_finish(errored)
  self.status = "idle"
  local ui = self:ui()
  ui.finish_turn(self.turn_started and (uv.hrtime() - self.turn_started) or nil)
  ui.set_status("idle")
  if not errored and config.options.sessions.autosave then require("advantage.session").save(self) end
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
        nxt.opts.mode = nil
        self:send(nxt.text, nxt.opts)
      end
    end)
  else
    ui.set_queue(#self.queue)
  end
end

function Agent:cancel(opts)
  opts = opts or {}
  if not self:busy() then return end
  self.cancelled = true
  if not opts.keep_queue and #self.queue > 0 then
    self:ui().notice(("dropped %d queued message%s"):format(#self.queue, #self.queue == 1 and "" or "s"))
    self.queue = {}
    self:ui().set_queue(0)
  end
  if not opts.keep_queue and #self.interrupts > 0 then
    self:ui().notice(("dropped %d pending message%s"):format(#self.interrupts, #self.interrupts == 1 and "" or "s"))
    self.interrupts = {}
  end
  if self.pending_permission then
    local pending = self.pending_permission
    self.pending_permission = nil
    pending("deny")
  end
  for id, handle in pairs(self.active_tools or {}) do
    local ok = false
    if type(handle) == "table" then
      if handle.stop then ok = pcall(handle.stop) end
      if not ok and handle.kill then pcall(handle.kill) end
    end
    self:ui().tool_update(id, { status = "denied", detail = "cancelled" })
  end
  self.active_tools = {}
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
