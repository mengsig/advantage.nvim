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
        if #out > 30000 then out = out:sub(1, 30000) .. "\n… (truncated)" end
        cb(out, res.code ~= 0 and res.signal == 0 and false or (res.code ~= 0))
      end)
    )
  end,
}
M._reject_bash = reject_bash

local function readonly_tools()
  local out = {}
  for _, def in ipairs(tools.list) do
    if def.safe and def.name ~= "sub_agent" and not def.memory and not def.parent_only then
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

local function text_from_blocks(blocks)
  local out = {}
  for _, b in ipairs(blocks or {}) do
    if b.type == "text" and b.text and b.text ~= "" then out[#out + 1] = b.text end
  end
  return table.concat(out, "\n")
end

local function system_prompt(parent_system)
  return table.concat({
    parent_system or require("advantage.agent").system_prompt(),
    "",
    "You are a read-only sub-agent. Investigate independently and return a concise report to the parent agent.",
    "You may use only read-only tools. Do not edit files or run mutating commands. Include file paths and line numbers when useful.",
  }, "\n")
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

---@param input {prompt:string, model?:string, max_turns?:integer}
---@param ctx {cwd:string, model?:table, system?:string}
---@param cb fun(output:string, is_error:boolean)
function M.run(input, ctx, cb)
  local cfg = config.options.subagents or {}
  if cfg.enabled == false then return cb("Sub-agents are disabled by config.subagents.enabled = false", true) end
  local prompt = vim.trim(tostring(input.prompt or ""))
  if prompt == "" then return cb("sub_agent prompt is required", true) end

  -- Model precedence: explicit tool arg → configured subagents.model (a cheap/fast
  -- model for read-only fan-out) → the parent's model.
  local model = input.model and config.resolve_model(input.model)
  if not model and cfg.model then model = config.resolve_model(cfg.model) end
  model = model or ctx.model
  if not model then return cb("sub_agent has no model", true) end
  local provider = providers.get(model.provider)
  if not provider then return cb("Unknown sub-agent provider: " .. tostring(model.provider), true) end

  local max_turns = math.max(1, math.min(tonumber(input.max_turns or cfg.max_turns or 6) or 6, 12))
  local messages = {
    { role = "user", content = { { type = "text", text = prompt } } },
  }
  local turn, cancelled, job = 0, false, nil
  local usage = { input = 0, output = 0 }
  local last_text = "" -- newest interim findings, so a turn-limit stop isn't wasted

  local function finish(text, is_error)
    if cancelled then return end
    text = vim.trim(text or "")
    if text == "" and not is_error then text = "Sub-agent finished without a text report." end
    local suffix = (usage.input > 0 or usage.output > 0)
        and ("\n\n[sub-agent usage: ↑%s ↓%s]"):format(
          require("advantage.util").fmt_tokens(usage.input),
          require("advantage.util").fmt_tokens(usage.output)
        )
      or ""
    cb(text .. suffix, is_error or false)
  end

  local function step()
    if cancelled then return end
    turn = turn + 1
    if turn > max_turns then
      -- Don't throw away the investigation: return the newest interim findings the
      -- sub-agent produced, flagged incomplete, instead of nothing.
      local partial = last_text ~= "" and ("\n\nBest partial findings so far:\n" .. last_text) or ""
      return finish(("Sub-agent hit its %d-turn limit before a final report.%s"):format(max_turns, partial), true)
    end

    job = provider.stream({
      model = model,
      system = system_prompt(ctx.system),
      messages = messages,
      tools = readonly_tools(),
      on = {
        text = function() end,
        thinking = function() end,
        tool_start = function() end,
        auth = function() end,
        usage = function(i, o, cached)
          usage.input = usage.input + (i or 0)
          usage.output = usage.output + (o or 0)
          require("advantage.usage").record(model, i or 0, o or 0, cached)
        end,
        complete = function(blocks, stop_reason)
          job = nil
          if cancelled then return end
          if #blocks > 0 then messages[#messages + 1] = { role = "assistant", content = blocks } end
          local interim = text_from_blocks(blocks)
          if interim ~= "" then last_text = interim end
          local calls = {}
          if stop_reason == "tool_use" then
            for _, b in ipairs(blocks) do
              if b.type == "tool_use" then calls[#calls + 1] = b end
            end
          end
          if #calls == 0 then return finish(text_from_blocks(blocks), false) end
          run_calls(calls, ctx, function(results)
            messages[#messages + 1] = { role = "user", content = results }
            step()
          end)
        end,
        error = function(msg)
          job = nil
          finish("Sub-agent error: " .. tostring(msg), true)
        end,
      },
    })
  end

  step()

  return {
    stop = function()
      cancelled = true
      if job and job.stop then job.stop() end
    end,
  }
end

return M
