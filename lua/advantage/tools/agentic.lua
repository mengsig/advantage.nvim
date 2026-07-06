---@brief Agentic tools: sub_agent (read-only investigation) and todo_write
---(the plan tool). Registered by tools/init.lua; behaviour is identical to when
---these lived inline in that file.
local util = require("advantage.util")

local TODO_MARKS = { pending = "·", in_progress = "▶", completed = "✓" }

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "agentic tools: tool registrar required")
  assert(type(s) == "table", "agentic tools: support module required")

  tool({
    name = "sub_agent",
    safe = true,
    description = "Spawn a read-only sub-agent for independent investigation. The sub-agent can read/search/list files and returns a concise report; it cannot edit files. Batch several sub_agent calls in a single response to run them concurrently — best for independent questions. Issue them one per turn only when a later investigation depends on an earlier result.",
    input_schema = {
      type = "object",
      properties = {
        prompt = { type = "string", description = "Investigation task for the sub-agent" },
        model = { type = "string", description = "Optional model ref provider/model-id; defaults to the current model" },
        max_turns = {
          type = "integer",
          description = "Maximum sub-agent turns including tool loops (default from config, capped at 12)",
        },
      },
      required = { "prompt" },
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
    name = "todo_write",
    safe = true,
    parent_only = true, -- a read-only sub-agent has no business keeping the plan
    description = "Maintain your task list for multi-step work. Replaces the whole list each call: plan the steps before starting, then keep statuses current as you work (exactly one item in_progress at a time). Skip it for trivial single-step tasks.",
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
