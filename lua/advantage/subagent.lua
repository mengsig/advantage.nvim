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
    if def.safe and def.name ~= "sub_agent" then
      out[#out + 1] = {
        name = def.name,
        description = def.description,
        input_schema = def.input_schema,
      }
    end
  end
  return out
end

local function text_from_blocks(blocks)
  local out = {}
  for _, b in ipairs(blocks or {}) do
    if b.type == "text" and b.text and b.text ~= "" then
      out[#out + 1] = b.text
    end
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
  local def = tools.get(call.name)
  if not def or not def.safe or call.name == "sub_agent" then
    return cb({
      type = "tool_result",
      tool_use_id = call.id,
      content = "Sub-agent tool is unavailable or not read-only: " .. tostring(call.name),
      is_error = true,
    })
  end
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
  if cfg.enabled == false then
    return cb("Sub-agents are disabled by config.subagents.enabled = false", true)
  end
  local prompt = vim.trim(tostring(input.prompt or ""))
  if prompt == "" then return cb("sub_agent prompt is required", true) end

  local model = input.model and config.resolve_model(input.model) or ctx.model
  if not model then return cb("sub_agent has no model", true) end
  local provider = providers.get(model.provider)
  if not provider then return cb("Unknown sub-agent provider: " .. tostring(model.provider), true) end

  local max_turns = math.max(1, math.min(tonumber(input.max_turns or cfg.max_turns or 6) or 6, 12))
  local messages = {
    { role = "user", content = { { type = "text", text = prompt } } },
  }
  local turn, cancelled, job = 0, false, nil
  local usage = { input = 0, output = 0 }

  local function finish(text, is_error)
    if cancelled then return end
    text = vim.trim(text or "")
    if text == "" and not is_error then text = "Sub-agent finished without a text report." end
    local suffix = (usage.input > 0 or usage.output > 0)
      and ("\n\n[sub-agent usage: ↑%s ↓%s]"):format(
        require("advantage.util").fmt_tokens(usage.input),
        require("advantage.util").fmt_tokens(usage.output)
      ) or ""
    cb(text .. suffix, is_error or false)
  end

  local function step()
    if cancelled then return end
    turn = turn + 1
    if turn > max_turns then
      return finish(("Sub-agent stopped after %d turns without a final answer."):format(max_turns), true)
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
        usage = function(i, o)
          usage.input = usage.input + (i or 0)
          usage.output = usage.output + (o or 0)
          require("advantage.usage").record(model, i or 0, o or 0)
        end,
        complete = function(blocks, stop_reason)
          job = nil
          if cancelled then return end
          if #blocks > 0 then
            messages[#messages + 1] = { role = "assistant", content = blocks }
          end
          local calls = {}
          if stop_reason == "tool_use" then
            for _, b in ipairs(blocks) do
              if b.type == "tool_use" then calls[#calls + 1] = b end
            end
          end
          if #calls == 0 then
            return finish(text_from_blocks(blocks), false)
          end
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
