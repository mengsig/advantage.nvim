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

-- Read-only bash for sub-agents -------------------------------------------
-- Sub-agents run autonomously with no permission prompt, so their optional
-- bash is restricted to a vetted allow-list of inspection commands. This is
-- best-effort (shell is not fully parseable): redirection and command
-- substitution are rejected outright, and each pipeline segment's leading
-- command must be allow-listed. It is NOT path-contained — like any bash it
-- can read outside the root — which is why it is opt-in and off by default.
local READONLY_CMDS = {
  ls = true,
  cat = true,
  head = true,
  tail = true,
  wc = true,
  nl = true,
  tac = true,
  rg = true,
  grep = true,
  egrep = true,
  fgrep = true,
  find = true,
  fd = true,
  tree = true,
  stat = true,
  file = true,
  du = true,
  df = true,
  pwd = true,
  echo = true,
  printf = true,
  dirname = true,
  basename = true,
  realpath = true,
  readlink = true,
  sort = true,
  uniq = true,
  cut = true,
  tr = true,
  comm = true,
  column = true,
  diff = true,
  date = true,
  env = true,
  printenv = true,
  which = true,
  type = true,
  whoami = true,
  hostname = true,
  uname = true,
  jq = true,
  yq = true,
  sed = true,
  awk = true,
  git = true,
  xxd = true,
  od = true,
  cksum = true,
  sha256sum = true,
  md5sum = true,
  ["true"] = true,
  ["false"] = true,
  test = true,
}
local GIT_READONLY = {
  status = true,
  log = true,
  diff = true,
  show = true,
  branch = true,
  tag = true,
  ["rev-parse"] = true,
  ["ls-files"] = true,
  ["ls-tree"] = true,
  blame = true,
  describe = true,
  remote = true,
  shortlog = true,
  ["cat-file"] = true,
  grep = true,
  whatchanged = true,
  reflog = true,
  ["rev-list"] = true,
  ["name-rev"] = true,
  ["symbolic-ref"] = true,
  ["for-each-ref"] = true,
  ["count-objects"] = true,
  config = true,
  show_ref = true,
}

local function bash_allowlist()
  local cfg = (config.options.subagents or {}).bash
  if type(cfg) == "table" and type(cfg.allow) == "table" then
    local allow = vim.deepcopy(READONLY_CMDS)
    for _, c in ipairs(cfg.allow) do
      allow[c] = true
    end
    return allow
  end
  return READONLY_CMDS
end

---Return an error string if `cmd` is not a safe read-only command, else nil.
local function reject_bash(cmd, allow)
  cmd = vim.trim(cmd or "")
  if cmd == "" then return "empty command" end
  if cmd:find("[>`]") or cmd:find("%$%(") then
    return "read-only bash cannot use output redirection or command substitution"
  end
  for seg in (cmd .. "\n"):gmatch("([^|&;\n]+)") do
    seg = vim.trim(seg):gsub("^%s*([%w_]+=%S*%s+)+", "") -- strip leading VAR=val
    if seg ~= "" then
      local first = (seg:match("^%S+") or ""):gsub(".*/", "") -- basename
      if not allow[first] then return ("command '%s' is not in the read-only allow-list"):format(first) end
      if first == "git" then
        local subc = seg:match("^git%s+(%S+)")
        if not (subc and GIT_READONLY[subc]) then
          return ("git subcommand '%s' is not read-only"):format(tostring(subc))
        end
      elseif first == "find" and (seg:find("%-delete") or seg:find("%-exec")) then
        return "find -delete / -exec is not allowed"
      elseif first == "sed" then
        for tok in seg:gmatch("%S+") do
          if tok:match("^%-i") or tok:match("^%-%-in%-place") then return "sed -i (in-place edit) is not allowed" end
        end
      end
    end
  end
end

local sub_bash = {
  name = "bash",
  description = "Run a READ-ONLY bash command (inspection only: ls, cat, grep, rg, find, git status/log/diff, wc, etc.). Redirection and mutating commands are rejected.",
  input_schema = {
    type = "object",
    properties = {
      command = { type = "string", description = "The read-only command to run" },
      timeout_ms = { type = "integer", description = "Timeout in ms (default 60000)" },
    },
    required = { "command" },
  },
  run = function(input, ctx, cb)
    local why = reject_bash(input.command, bash_allowlist())
    if why then return cb("Rejected: " .. why, true) end
    local timeout = tonumber(input.timeout_ms) or 60000
    vim.system(
      { "bash", "-c", input.command },
      { cwd = ctx.cwd, text = true, timeout = timeout },
      vim.schedule_wrap(function(res)
        local out = (res.stdout or "") .. (res.stderr or "")
        if res.code == 124 or res.signal ~= 0 then out = out .. "\n(timed out)" end
        if vim.trim(out) == "" then out = "(no output)" end
        if #out > 30000 then out = require("advantage.util").utf8_safe_sub(out, 30000) .. "\n… (truncated)" end
        cb(out, res.code ~= 0 and res.signal == 0 and false or (res.code ~= 0))
      end)
    )
  end,
}
M._reject_bash = reject_bash

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
  if (config.options.subagents or {}).bash then
    out[#out + 1] = { name = sub_bash.name, description = sub_bash.description, input_schema = sub_bash.input_schema }
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
local function system_prompt(max_turns)
  local agent = require("advantage.agent")
  local lines = { agent.base_system_prompt() }
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

local function run_tool_call(call, ctx, cb)
  if call.name == "bash" and (config.options.subagents or {}).bash then
    local done = false
    local ok, err = pcall(sub_bash.run, call.input or {}, ctx, function(output, is_error)
      if done then return end
      done = true
      cb({ type = "tool_result", tool_use_id = call.id, content = output or "", is_error = is_error or nil })
    end)
    if not ok then
      cb({
        type = "tool_result",
        tool_use_id = call.id,
        content = "Sub-agent bash crashed: " .. tostring(err),
        is_error = true,
      })
    end
    return
  end
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
  local done = false
  local ok, err = pcall(def.run, call.input or {}, ctx, function(output, is_error, meta)
    if done or (meta and meta.stream) then return end
    done = true
    cb({
      type = "tool_result",
      tool_use_id = call.id,
      content = output or "",
      is_error = is_error or nil,
    })
  end)
  if not ok then
    cb({
      type = "tool_result",
      tool_use_id = call.id,
      content = "Sub-agent tool crashed: " .. tostring(err),
      is_error = true,
    })
  end
end

local function run_calls(calls, ctx, done)
  local results, i = {}, 0
  local function next_call()
    i = i + 1
    local call = calls[i]
    if not call then return done(results) end
    run_tool_call(call, ctx, function(result)
      results[#results + 1] = result
      next_call()
    end)
  end
  next_call()
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
  local model = input.model and config.resolve_model(input.model)
  if not model and cfg.model then model = config.resolve_model(cfg.model) end
  model = model or ctx.model
  if not model then return nil, nil, "sub_agent has no model" end
  local provider = providers.get(model.provider)
  if not provider then return nil, nil, "Unknown sub-agent provider: " .. tostring(model.provider) end
  return model, provider
end

---Deliver the scout's final report to the parent: capped and usage-annotated.
local function finish_report(s, text, is_error)
  assert(type(s) == "table" and type(s.cb) == "function", "finish_report: session with cb required")
  if s.cancelled then return end
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
  run_calls(calls, s.ctx, function(results)
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
  local final = s.turn >= s.max_turns

  s.job = s.provider.stream({
    model = s.model,
    system = system_prompt(s.max_turns),
    messages = final and final_report_messages(s) or s.messages,
    -- Keep the tools declared (so the transcript's prior tool_use/tool_result
    -- blocks still validate) but forbid their use on the final turn, forcing text.
    tools = readonly_tools(),
    tool_choice = final and "none" or nil,
    on = {
      text = function() end,
      thinking = function() end,
      tool_start = function() end,
      auth = function() end,
      usage = function(i, o, cached)
        s.usage.input = s.usage.input + (i or 0)
        s.usage.output = s.usage.output + (o or 0)
        require("advantage.usage").record(s.model, i or 0, o or 0, cached)
      end,
      complete = function(blocks, stop_reason)
        on_step_complete(s, blocks, stop_reason, final)
      end,
      error = function(msg)
        s.job = nil
        finish_report(s, "Sub-agent error: " .. tostring(msg), true)
      end,
    },
  })
end

---@param input {prompt:string, model?:string, max_turns?:integer}
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

  -- Floor at 2, not 1: the final turn is report-only (tools withheld), so a budget
  -- of 1 would leave the scout zero turns to actually investigate — it would report
  -- having read nothing. 2 guarantees at least one investigation turn plus the report.
  local max_turns = math.max(2, math.min(tonumber(input.max_turns or cfg.max_turns or 12) or 12, 30))
  local s = {
    ctx = ctx,
    cb = cb,
    model = model,
    provider = provider,
    messages = { { role = "user", content = { { type = "text", text = prompt } } } },
    max_turns = max_turns,
    turn = 0,
    cancelled = false,
    job = nil, ---@type table?
    usage = { input = 0, output = 0 }, -- accumulated across turns
    last_text = "", -- newest interim findings, so a turn-limit stop isn't wasted
  }

  step(s)

  return {
    stop = function()
      s.cancelled = true
      if s.job and s.job.stop then s.job.stop() end
    end,
  }
end

return M
