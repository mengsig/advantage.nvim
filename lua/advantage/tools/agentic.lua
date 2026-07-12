---@brief Agentic tools: sub_agent (read-only investigation) and todo_write
---(the plan tool). Registered by tools/init.lua; behaviour is identical to when
---these lived inline in that file.
local util = require("advantage.util")
local config = require("advantage.config")

local TODO_MARKS = { pending = "·", in_progress = "▶", completed = "✓" }

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "agentic tools: tool registrar required")
  assert(type(s) == "table", "agentic tools: support module required")

  local preferred_model = (config.options.subagents or {}).model
  local preferred_effort = (config.options.subagents or {}).effort
  local model_description =
    "Required explicit scout route. Use exactly one short alias from the live enum; never guess a versioned model ID, omit the field, or send an empty string."
  if type(preferred_model) == "string" and vim.trim(preferred_model) ~= "" then
    model_description = model_description .. " The user-configured preference is " .. vim.trim(preferred_model) .. "."
  end
  local effort_description =
    "Required explicit scout reasoning level. Choose it deliberately; never omit it or send an empty string. Use inherit only when retaining the selected model's configured effort is intentional."
  if type(preferred_effort) == "string" and vim.trim(preferred_effort) ~= "" then
    effort_description = effort_description
      .. " The user-configured preference is "
      .. vim.trim(preferred_effort)
      .. "."
  end
  local turn_cap = math.max(2, math.min(tonumber((config.options.subagents or {}).max_turns_cap) or 12, 30))

  tool({
    name = "sub_agent",
    safe = true,
    feature = "subagents",
    description = "Spawn one read-only scout for a specific investigation whose evidence will materially reduce parent work. It can inspect files and research the web, but cannot edit, run shell commands, create fixtures, or execute a CLI. Do not delegate generic repository/test surveys, runtime validation, duplicate review, or work the parent can do directly. If 2+ independent scouts are justified, emit them together (prefer sub_agent_batch mode=parallel); never serialize independent scouts across turns. After implementation starts, delegate again only for a concrete unresolved blocker—not post-hoc review.",
    input_schema = {
      type = "object",
      properties = {
        prompt = { type = "string", description = "Investigation task for the sub-agent" },
        model = {
          type = "string",
          minLength = 1,
          description = model_description,
        },
        max_turns = {
          type = "integer",
          minimum = 2,
          maximum = turn_cap,
          description = ("Requested ceiling including the final report-only turn (user cap: %d). This is a ceiling, not a target: use 3-6 for a focused investigation and 8-12 only for one genuinely deep isolated blocker. Never assign the maximum to every scout in a breadth wave."):format(
            turn_cap
          ),
        },
        effort = {
          type = "string",
          minLength = 1,
          enum = { "low", "medium", "high", "xhigh", "max", "inherit" },
          description = effort_description,
        },
      },
      required = { "prompt", "model", "effort" },
    },
    summary = function(input)
      local p = (input.prompt or ""):gsub("%s+", " ")
      return #p > 60 and (util.utf8_safe_sub(p, 57) .. "…") or p
    end,
    run = function(input, ctx, cb)
      return require("advantage.subagent").run(input, ctx, cb)
    end,
  })

  tool({
    name = "sub_agent_batch",
    safe = true,
    parent_only = true,
    feature = "subagents",
    description = "Orchestrate one task-sized wave of read-only scouts. Use mode=parallel for independent domains. Scouts can inspect/research but cannot run shell commands, create fixtures, or execute a CLI; the parent owns runtime evidence and verification. Sequential mode only serializes already self-contained tasks; it does not pass an earlier report into later prompts, so genuinely dependent investigations require separate parent turns. Do not add generic architecture/test/reviewer roles or start a second wave after implementation unless a concrete blocker remains. Every task explicitly provides prompt, model alias, effort, and an optional proportional turn ceiling; results return in task order.",
    input_schema = {
      type = "object",
      properties = {
        mode = {
          type = "string",
          enum = { "parallel", "sequential" },
          description = "parallel for independent tasks; sequential only to serialize self-contained tasks (not for data dependencies)",
        },
        tasks = {
          type = "array",
          minItems = 1,
          description = "Self-contained scout tasks; omit generic survey/reviewer extras. Put data-dependent investigations in separate parent turns.",
          items = {
            type = "object",
            properties = {
              prompt = { type = "string", minLength = 1, description = "Investigation task" },
              model = {
                type = "string",
                minLength = 1,
                description = "Explicit short scout alias from the live sub_agent enum",
              },
              effort = { type = "string", minLength = 1, enum = { "low", "medium", "high", "xhigh", "max", "inherit" } },
              max_turns = {
                type = "integer",
                minimum = 2,
                maximum = turn_cap,
                description = ("Optional per-scout ceiling (user cap: %d); 3-6 is normally sufficient and a whole breadth wave must not use the maximum"):format(
                  turn_cap
                ),
              },
            },
            required = { "prompt", "model", "effort" },
          },
        },
      },
      required = { "mode", "tasks" },
    },
    summary = function(input)
      return ("%s · %d scouts"):format(input.mode or "parallel", type(input.tasks) == "table" and #input.tasks or 0)
    end,
    run = function(input, ctx, cb)
      return require("advantage.subagent").run_batch(input, ctx, cb)
    end,
  })

  tool({
    name = "todo_write",
    safe = true,
    parent_only = true, -- a read-only sub-agent has no business keeping the plan
    description = "Maintain your task list for multi-step work. Replaces the whole list each call: plan before starting, then keep statuses current. Use exactly one in_progress item while work is underway; use none only for an all-pending initial plan or an all-completed final plan. Skip it for trivial single-step tasks.",
    input_schema = {
      type = "object",
      properties = {
        items = {
          type = "array",
          description = "The full task list, in order",
          items = {
            type = "object",
            properties = {
              content = { type = "string", description = "Short imperative description of the step" },
              status = { type = "string", enum = { "pending", "in_progress", "completed" } },
            },
            required = { "content", "status" },
          },
        },
      },
      required = { "items" },
    },
    summary = function(input)
      local items = type(input.items) == "table" and input.items or {}
      local done = 0
      for _, it in ipairs(items) do
        if it.status == "completed" then done = done + 1 end
      end
      return ("%d/%d done"):format(done, #items)
    end,
    run = function(input, ctx, cb)
      local items = input.items
      if type(items) ~= "table" or #items == 0 then
        return cb("items must be a non-empty array of {content, status}", true)
      end
      local active = 0
      for _, item in ipairs(items) do
        if item.status == "in_progress" then active = active + 1 end
      end
      if active > 1 then
        return cb("todo_write accepts at most one in_progress item; mark the remaining steps pending", true)
      end
      ctx.todos = items
      local lines, done = {}, 0
      for _, it in ipairs(items) do
        if it.status == "completed" then done = done + 1 end
        lines[#lines + 1] = ("  %s %s"):format(TODO_MARKS[it.status] or "·", tostring(it.content or ""))
      end
      table.insert(lines, 1, ("todo %d/%d"):format(done, #items))
      -- show the checklist in the transcript; headless callers just get the cb
      pcall(function()
        require("advantage.ui.chat").notice(table.concat(lines, "\n"))
      end)
      cb(("Todo list updated — %d/%d done."):format(done, #items), false)
    end,
  })
end
