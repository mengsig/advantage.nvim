---@brief Read-only sub-agent runner used by the `sub_agent` tool.
---
---A sub-agent gets its own short conversation and may use only safe/read-only
---tools. It is meant for fan-out investigation ("inspect this subsystem", "find
---where X is defined"), not for making changes. The parent model receives the
---sub-agent's final report as a normal tool result.
local M = {}

local providers = require("advantage.providers")
local tools = require("advantage.tools")
local config = require("advantage.config")

local function readonly_tools()
  local out = {}
  for _, def in ipairs(tools.list) do
    if def.safe and def.name ~= "sub_agent" and not def.memory and not def.parent_only and tools.enabled(def) then
      out[#out + 1] = {
        name = def.name,
        description = def.description,
        input_schema = def.input_schema,
      }
    end
  end
  return out
end
M._readonly_tools = readonly_tools

local function text_from_blocks(blocks)
  local out = {}
  for _, b in ipairs(blocks or {}) do
    if b.type == "text" and b.text and b.text ~= "" then out[#out + 1] = b.text end
  end
  return table.concat(out, "\n")
end

---A sub-agent gets the BASE instructions only — deliberately NOT the parent's
---repo-memory block or skills index. A read-only scout can't call
---`remember`/`use_skill` anyway, and re-shipping the full learned context to
---every worker (and 5× on a parallel fan-out, each cold-cached) is the exact
---token leak the sub-agent design is meant to avoid. The parent already digested
---memory and wrote a specific task prompt; that carries the context the scout needs.
---@param max_turns integer the sub-agent's total turn budget (constant for the run)
local function system_prompt(max_turns, cwd)
  local agent = require("advantage.agent")
  local lines = { agent.base_system_prompt(cwd) }
  -- The scout gets the same semantic-navigation steer as the parent (it has the
  -- LSP tools too), when they're live — a scout answering "where is X defined /
  -- who calls it" should use goto_definition/find_references, not grep.
  local lsp = agent.lsp_guide()
  if lsp then
    lines[#lines + 1] = ""
    lines[#lines + 1] = lsp
  end
  vim.list_extend(lines, {
    "",
    "You are a read-only sub-agent. Investigate independently and return a concise report to the parent agent.",
    "You may use only read-only tools. Do not edit files or run mutating commands. Include file paths and line numbers when useful.",
    "Keep the report tight: the parent pays tokens for every word of it, so return findings and the evidence for them, not a play-by-play.",
    -- The budget is a constant for the run, so this line stays byte-identical
    -- turn to turn and does not defeat the sub-agent's prompt cache. Telling the
    -- model its budget makes it self-pace — batch look-ups, report early — instead
    -- of investigating leisurely until it is cut off mid-stream with nothing to show.
    ("You have a budget of about %d turns. Batch independent look-ups into one turn to go wide fast, and finish with your report before you run out — on your final turn the tools are withdrawn and you are asked to write up whatever you have found so far, so never leave the report to the last moment."):format(
      max_turns
    ),
  })
  return table.concat(lines, "\n")
end

local function run_tool_call(call, ctx, s, cb)
  if s.cancelled then return end
  local def = tools.get(call.name)
  if not def or not def.safe or call.name == "sub_agent" then
    return cb({
      type = "tool_result",
      tool_use_id = call.id,
      content = "Sub-agent tool is unavailable or not read-only: " .. tostring(call.name),
      is_error = true,
    })
  end
  local verr = tools.validate_input(call.name, call.input)
  if verr then return cb({ type = "tool_result", tool_use_id = call.id, content = verr, is_error = true }) end
  local done, handle = false, nil
  local ok, result = pcall(def.run, call.input or {}, ctx, function(output, is_error, meta)
    if s.cancelled or done or (meta and meta.stream) then return end
    done = true
    s.active_tools[call.id] = nil
    cb({
      type = "tool_result",
      tool_use_id = call.id,
      content = output or "",
      is_error = is_error or nil,
    })
  end)
  handle = result
  if ok and not done and type(handle) == "table" and (handle.stop or handle.kill) then
    s.active_tools[call.id] = handle
  elseif not ok and not done and not s.cancelled then
    done = true
    s.active_tools[call.id] = nil
    cb({
      type = "tool_result",
      tool_use_id = call.id,
      content = "Sub-agent tool crashed: " .. tostring(result),
      is_error = true,
    })
  end
end

local function run_calls(calls, ctx, s, done)
  if #calls == 0 then return done({}) end
  local cfg = config.options.subagents or {}
  local limit = math.min(#calls, math.max(1, tonumber(cfg.max_per_batch) or 8))
  local max_parallel = math.max(1, tonumber(cfg.max_parallel) or 4)
  local per_result_bytes = math.max(1000, math.floor((tonumber(cfg.max_result_bytes) or 64000) / #calls))
  local results, pending, launching, finished = {}, #calls, true, false
  local next_idx, running = 1, 0
  local function maybe_finish()
    if s.cancelled then return end
    if finished or launching or pending > 0 then return end
    finished = true
    done(results)
  end
  local pump
  pump = function()
    if s.cancelled then return end
    while running < max_parallel and next_idx <= limit do
      local idx = next_idx
      next_idx = idx + 1
      running = running + 1
      run_tool_call(calls[idx], ctx, s, function(result)
        if s.cancelled then return end
        if type(result.content) == "string" and #result.content > per_result_bytes then
          result.content = require("advantage.util").utf8_safe_sub(result.content, per_result_bytes)
            .. "\n… [scout batch result truncated]"
        end
        results[idx] = result
        pending = pending - 1
        running = running - 1
        pump()
        maybe_finish()
      end)
    end
  end
  -- Every tool exposed to a scout is read-only, so independent calls emitted in
  -- one model response can safely overlap (LSP waits, filesystem reads, grep).
  -- Preserve response order in `results`.
  for idx = limit + 1, #calls do
    results[idx] = {
      type = "tool_result",
      tool_use_id = calls[idx].id,
      content = ("Scout tool batch limit exceeded (max %d); issue it in a later turn."):format(limit),
      is_error = true,
    }
    pending = pending - 1
  end
  launching = false
  pump()
  maybe_finish()
end

-- The scout's report is spliced straight into the PARENT transcript, where it
-- then costs input tokens on every subsequent parent turn until compaction. A
-- verbose worker could bloat that unbounded, so cap it like every other tool
-- output (character-safe so the cut never lands mid-UTF-8).
local REPORT_CAP = 16000

---Resolve model + provider for a sub-agent run using the precedence: explicit
---tool arg → configured subagents.model → the parent's model. Returns the model
---and provider, or (nil, nil, error_message) when the run can't proceed.
local function resolve_subagent_model(input, ctx, cfg)
  local model
  if input.model then
    model = config.resolve_model(input.model)
    if not model then return nil, nil, "Invalid sub-agent model ref: " .. tostring(input.model) end
  elseif cfg.model then
    model = config.resolve_model(cfg.model)
    if not model then return nil, nil, "Invalid config.subagents.model ref: " .. tostring(cfg.model) end
  end
  model = model or ctx.model
  if not model then return nil, nil, "sub_agent has no model" end
  -- Never mutate the parent's live quality setting while tuning a cheap scout.
  model = vim.deepcopy(model)
  local requested_effort = input.effort or cfg.effort
  if requested_effort and requested_effort ~= "inherit" then
    local controls = require("advantage.effort")
    local _, err
    if model.provider == "openai" then
      _, err = controls.set_openai(model, requested_effort)
    elseif model.provider == "anthropic" then
      _, err = controls.set_anthropic(model, requested_effort)
      model.thinking_display = "omitted"
    end
    if err then return nil, nil, "Invalid sub-agent effort: " .. err end
  elseif model.provider == "anthropic" then
    model.thinking_display = "omitted"
  end
  local provider = providers.get(model.provider)
  if not provider then return nil, nil, "Unknown sub-agent provider: " .. tostring(model.provider) end
  return model, provider
end

---Deliver the scout's final report to the parent: capped and usage-annotated.
local function finish_report(s, text, is_error)
  assert(type(s) == "table" and type(s.cb) == "function", "finish_report: session with cb required")
  if s.cancelled or s.finished then return end
  s.finished = true
  local util = require("advantage.util")
  text = vim.trim(text or "")
  if text == "" and not is_error then text = "Sub-agent finished without a text report." end
  if #text > REPORT_CAP then text = util.utf8_safe_sub(text, REPORT_CAP) .. "\n… [sub-agent report truncated]" end
  local suffix = (s.usage.input > 0 or s.usage.output > 0)
      and ("\n\n[sub-agent usage: ↑%s ↓%s]"):format(util.fmt_tokens(s.usage.input), util.fmt_tokens(s.usage.output))
    or ""
  s.cb(text .. suffix, is_error or false)
end

-- Appended as a user turn on the sub-agent's final step, where the tools are
-- withheld (tool_choice = "none"). Without this, a scout that spends every turn
-- calling tools — as a reasoning model bug-hunting a subsystem does: it emits
-- thinking + tool_use and NO assistant text until the very end — reaches the turn
-- limit having produced no text at all, and the parent gets "hit its N-turn limit"
-- with zero findings. Forcing a text-only report turn converts that dead end into
-- an actual report built from everything gathered so far.
local FINAL_DIRECTIVE = "You have reached your final turn and the investigation tools are now withheld. "
  .. "Do not attempt to gather more — write your complete report to the parent agent NOW: the findings, "
  .. "with file paths and line numbers, and the evidence for each. If part of the investigation is unfinished, "
  .. "report what you did find and clearly flag what remains uncertain. Do not return an empty or apologetic reply."

---Messages for the final, report-only turn: the running transcript plus a user
---directive to stop and report. A shallow copy keeps the directive out of the
---persisted transcript (the run finishes right after this turn).
local function final_report_messages(s)
  local msgs = {}
  for i = 1, #s.messages do
    msgs[i] = s.messages[i]
  end
  msgs[#msgs + 1] = { role = "user", content = { { type = "text", text = FINAL_DIRECTIVE } } }
  return msgs
end

-- Mutually recursive with on_step_complete (each tool round re-enters step).
local step

---Handle a completed model response: record blocks, then either report the final
---text or run the requested tools and take another step. `final` marks the
---report-only turn: no tools were offered, so whatever came back is the report
---(falling back to the newest interim findings if it somehow came back empty),
---and we never loop again.
local function on_step_complete(s, blocks, stop_reason, final)
  s.streaming = false
  s.job = nil
  if s.cancelled then return end
  if #blocks > 0 then s.messages[#s.messages + 1] = { role = "assistant", content = blocks } end
  local interim = text_from_blocks(blocks)
  if interim ~= "" then s.last_text = interim end
  if final then return finish_report(s, interim ~= "" and interim or s.last_text, false) end
  local calls = {}
  if stop_reason == "tool_use" then
    for _, b in ipairs(blocks) do
      if b.type == "tool_use" then calls[#calls + 1] = b end
    end
  end
  if #calls == 0 then return finish_report(s, interim, false) end
  run_calls(calls, s.ctx, s, function(results)
    if s.cancelled then return end
    s.messages[#s.messages + 1] = { role = "user", content = results }
    step(s)
  end)
end

---Run one sub-agent turn against the provider stream. The last permitted turn is
---report-only: the tools are withheld (tool_choice = "none") and a directive is
---appended so the model must write its findings, guaranteeing the turn budget
---always ends in a real report rather than an empty limit error.
function step(s)
  assert(type(s) == "table" and type(s.provider) == "table", "step: session with provider required")
  if s.cancelled then return end
  s.turn = s.turn + 1
  local window = config.effective_context_window and config.effective_context_window(s.model) or s.model.context_window
  local reserve = s.output_reserve or s.model.max_output_tokens or 64000
  local prefix = require("advantage.compact").estimate_value_tokens({
    system = system_prompt(s.max_turns, s.ctx.cwd),
    tools = readonly_tools(),
  })
  local used = require("advantage.compact").estimate_tokens(s.messages)
  local near_limit = type(window) == "number"
    and used + prefix >= window - reserve - ((config.options.context or {}).request_safety_tokens or 8192)
  local final = s.turn >= s.max_turns or near_limit

  s.streaming = true
  local job = s.provider.stream({
    model = s.model,
    system = system_prompt(s.max_turns, s.ctx.cwd),
    messages = final and final_report_messages(s) or s.messages,
    -- Keep the tools declared (so the transcript's prior tool_use/tool_result
    -- blocks still validate) but forbid their use on the final turn, forcing text.
    tools = readonly_tools(),
    tool_choice = final and "none" or nil,
    -- Permit, but never require, same-turn read fan-out. Dependent look-ups can
    -- still be issued one per turn after the previous result is observed.
    parallel_tool_calls = not final,
    -- Reasoning summaries cost latency/tokens but scouts never render them.
    reasoning_summary = false,
    prompt_cache_key = s.request_key,
    session_id = s.request_key,
    on = {
      text = function() end,
      thinking = function() end,
      tool_start = function() end,
      auth = function() end,
      usage = function(i, o, cached, details)
        s.usage.input = s.usage.input + (i or 0)
        s.usage.output = s.usage.output + (o or 0)
        s.usage.reasoning = (s.usage.reasoning or 0) + ((details and details.reasoning) or 0)
        s.usage.cache_write = (s.usage.cache_write or 0) + ((details and details.cache_write) or 0)
        require("advantage.usage").record(s.model, i or 0, o or 0, cached, details)
      end,
      complete = function(blocks, stop_reason)
        on_step_complete(s, blocks, stop_reason, final)
      end,
      error = function(msg)
        s.streaming = false
        s.job = nil
        finish_report(s, "Sub-agent error: " .. tostring(msg), true)
      end,
    },
  })
  if not s.cancelled and not s.finished and s.streaming then s.job = job end
end

---@param input {prompt:string, model?:string, max_turns?:integer, effort?:string}
---@param ctx {cwd:string, model?:table, system?:string}
---@param cb fun(output:string, is_error:boolean)
function M.run(input, ctx, cb)
  assert(type(ctx) == "table" and type(ctx.cwd) == "string", "subagent.run: ctx.cwd required")
  assert(type(cb) == "function", "subagent.run: cb callback required")
  local cfg = config.options.subagents or {}
  if cfg.enabled == false then return cb("Sub-agents are disabled by config.subagents.enabled = false", true) end
  local prompt = vim.trim(tostring(input.prompt or ""))
  if prompt == "" then return cb("sub_agent prompt is required", true) end

  local model, provider, err = resolve_subagent_model(input, ctx, cfg)
  if not model then return cb(err or "sub_agent has no model", true) end
  -- Compute the transport-aware envelope before applying the scout's API-side
  -- response cap. ChatGPT login does not accept that cap, so it must still
  -- reserve the model's native maximum (128k for GPT-5.6) during preflight.
  local output_reserve = config.request_output_reserve_tokens and config.request_output_reserve_tokens(model)
    or model.max_output_tokens
    or 64000
  local output_cap = math.max(1000, tonumber(cfg.max_output_tokens) or 16000)
  model.max_output_tokens = math.min(tonumber(model.max_output_tokens) or output_cap, output_cap)

  -- Floor at 2, not 1: the final turn is report-only (tools withheld), so a budget
  -- of 1 would leave the scout zero turns to actually investigate — it would report
  -- having read nothing. 2 guarantees at least one investigation turn plus the report.
  local max_turns = math.max(2, math.min(tonumber(input.max_turns or cfg.max_turns or 12) or 12, 30))
  local digest = vim.fn.sha256(
    ctx.cwd
      .. ":"
      .. tostring(model.provider)
      .. ":"
      .. tostring(model.id)
      .. ":"
      .. prompt
      .. ":"
      .. tostring((vim.uv or vim.loop).hrtime())
  )
  local request_key = digest:sub(1, 8)
    .. "-"
    .. digest:sub(9, 12)
    .. "-4"
    .. digest:sub(14, 16)
    .. "-a"
    .. digest:sub(18, 20)
    .. "-"
    .. digest:sub(21, 32)
  local s = {
    ctx = ctx,
    cb = cb,
    model = model,
    provider = provider,
    messages = { { role = "user", content = { { type = "text", text = prompt } } } },
    max_turns = max_turns,
    turn = 0,
    cancelled = false,
    finished = false,
    streaming = false,
    job = nil, ---@type table?
    active_tools = {}, -- tool_use_id -> cancellable read-only tool handle
    usage = { input = 0, output = 0, reasoning = 0, cache_write = 0 }, -- accumulated across turns
    last_text = "", -- newest interim findings, so a turn-limit stop isn't wasted
    request_key = request_key,
    output_reserve = output_reserve,
  }

  step(s)

  return {
    stop = function()
      s.cancelled = true
      if s.job and s.job.stop then s.job.stop() end
      for _, handle in pairs(s.active_tools) do
        local stopped = false
        if type(handle) == "table" and handle.stop then stopped = pcall(handle.stop) end
        if not stopped and type(handle) == "table" and handle.kill then pcall(handle.kill) end
      end
      s.active_tools = {}
    end,
  }
end

return M
