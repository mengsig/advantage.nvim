local M = {}

local function bounded(text, max_bytes)
  assert(type(text) == "string", "verification output must be a string")
  assert(type(max_bytes) == "number" and max_bytes > 0, "verification output cap must be positive")
  if #text <= max_bytes then return text end
  local util = require("advantage.util")
  local marker = "\n… [verification output truncated]"
  local keep = math.max(1, max_bytes - #marker)
  return util.utf8_safe_sub(text, keep) .. marker
end

local function valid_commands(commands)
  if type(commands) ~= "table" or not vim.islist(commands) then return false end
  for _, command in ipairs(commands) do
    if type(command) ~= "string" or vim.trim(command) == "" then return false end
  end
  return true
end

---@param commands string[]
---@param options {cwd:string, timeout_ms:number, max_output_bytes:number}
---@param callback fun(result: table)
---@return table
function M.run(commands, options, callback)
  assert(valid_commands(commands), "verification commands must be a list of non-empty strings")
  assert(type(options) == "table" and type(options.cwd) == "string", "verification cwd required")
  assert(type(callback) == "function", "verification callback required")

  local bash = require("advantage.tools").get("bash")
  assert(type(bash) == "table" and type(bash.run) == "function", "bash tool unavailable")
  local state = { index = 0, stopped = false, handle = nil }

  local function finish(result)
    if state.stopped then return end
    state.handle = nil
    callback(result)
  end

  local function run_next()
    if state.stopped then return end
    state.index = state.index + 1
    local command = commands[state.index]
    if not command then return finish({ ok = true, commands_run = #commands }) end
    local settled = false
    local ok, handle = pcall(
      bash.run,
      {
        command = command,
        timeout_ms = options.timeout_ms,
        stream = false,
      },
      {
        cwd = options.cwd,
      },
      vim.schedule_wrap(function(output, is_error, meta)
        if state.stopped or (meta and meta.stream) or settled then return end
        settled = true
        local evidence = bounded(tostring(output or "(no output)"), options.max_output_bytes)
        if is_error then
          return finish({ ok = false, command = command, output = evidence, commands_run = state.index })
        end
        run_next()
      end)
    )
    if not ok then
      return finish({
        ok = false,
        command = command,
        output = bounded("verification runner crashed: " .. tostring(handle), options.max_output_bytes),
        commands_run = state.index,
      })
    end
    state.handle = handle
  end

  run_next()
  return {
    stop = function()
      if state.stopped then return end
      state.stopped = true
      if type(state.handle) == "table" then
        if state.handle.stop then
          state.handle.stop()
        elseif state.handle.kill then
          state.handle.kill()
        end
      end
    end,
  }
end

function M.failure_prompt(result, attempt, max_repairs)
  assert(type(result) == "table" and result.ok == false, "failed verification result required")
  assert(type(result.command) == "string" and result.command ~= "", "failed verification command required")
  return table.concat({
    "<automatic_verification_failure>",
    ("Command `%s` failed. Repair the implementation, then finish normally. Do not weaken the check."):format(
      result.command
    ),
    ("Automatic repair attempt %d of %d."):format(attempt, max_repairs),
    "",
    result.output or "(no output)",
    "</automatic_verification_failure>",
  }, "\n")
end

return M
