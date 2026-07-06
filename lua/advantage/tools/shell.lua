---@brief Shell tool: bash. Registered by tools/init.lua; behaviour is identical
---to when it lived inline in that file.
local util = require("advantage.util")
local uv = vim.uv or vim.loop

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "shell tools: tool registrar required")
  assert(type(s) == "table" and s.truncate, "shell tools: support module required")
  local truncate = s.truncate

  tool({
    name = "bash",
    safe = false,
    description = "Run a bash command in the project root and return its combined output. Use for builds, tests, git, and anything the file tools don't cover.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "The command to run" },
        timeout_ms = { type = "integer", description = "Timeout in milliseconds (default 120000)" },
        stream = { type = "boolean", description = "Stream stdout/stderr into the transcript while the command runs" },
      },
      required = { "command" },
    },
    summary = function(input)
      local c = (input.command or ""):gsub("%s+", " ")
      return #c > 60 and (util.utf8_safe_sub(c, 57) .. "…") or c
    end,
    preview = function(input)
      return { title = "bash", lines = vim.split(input.command or "", "\n", { plain = true }), filetype = "bash" }
    end,
    run = function(input, ctx, cb)
      local cfg = require("advantage.config").options
      local timeout = input.timeout_ms or cfg.tools.bash_timeout_ms
      local stream = input.stream == true or cfg.tools.stream_bash_output == true
      local chunks, finished, timed_out, stopped = {}, false, false, false
      local total_bytes, capped = 0, false
      -- Hard cap on captured/streamed output: a runaway producer (`yes`, an infinite
      -- log tail) would otherwise grow memory and flood the transcript unbounded,
      -- even in stream mode where the final MAX_OUTPUT truncation doesn't apply live.
      local BASH_OUTPUT_CAP = 400000
      local job

      -- Reconstruct the raw byte stream from Neovim's channel-lines protocol:
      -- within a callback, list elements join with "\n"; across callbacks the
      -- last element of one continues (concatenates directly with) the first of
      -- the next, so appending each callback's `concat(data, "\n")` verbatim
      -- rebuilds the exact output — preserving internal blank lines and partial
      -- lines without inserting spurious newlines.
      local function add_chunk(data)
        if capped or not data or type(data) ~= "table" then return end
        local text = table.concat(data, "\n")
        if text == "" then return end
        chunks[#chunks + 1] = text
        if stream then cb(text, false, { stream = true }) end
        total_bytes = total_bytes + #text
        if total_bytes > BASH_OUTPUT_CAP then
          capped = true
          chunks[#chunks + 1] = ("\n… [output exceeded %d bytes — command stopped]"):format(BASH_OUTPUT_CAP)
          pcall(vim.fn.jobstop, job)
        end
      end

      local timer
      local function close_timer()
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
      end

      job = vim.fn.jobstart({ "bash", "-c", input.command or "" }, {
        cwd = ctx.cwd,
        stdout_buffered = not stream,
        stderr_buffered = not stream,
        on_stdout = function(_, data)
          add_chunk(data)
        end,
        on_stderr = function(_, data)
          add_chunk(data)
        end,
        on_exit = function(_, code)
          vim.schedule(function()
            if finished then return end
            finished = true
            close_timer()
            local out = table.concat(chunks)
            if timed_out then
              out = out .. (out ~= "" and "\n" or "") .. ("(timed out after %d ms)"):format(timeout)
            elseif stopped then
              out = out .. (out ~= "" and "\n" or "") .. "(cancelled)"
            elseif code ~= 0 then
              out = out .. (out ~= "" and "\n" or "") .. ("(exit code %d)"):format(code)
            end
            if vim.trim(out) == "" then out = "(no output)" end
            local is_err = timed_out or stopped or code ~= 0
            local suffix = ""
            local ok_mem, memory = pcall(require, "advantage.memory")
            if ok_mem and memory.enabled() then
              memory.note_work()
              -- only steer on a clean run; don't bolt a memory nudge onto an error
              if not is_err then suffix = memory.record_nudge_suffix() end
            end
            cb(truncate(out) .. suffix, is_err)
          end)
        end,
      })
      if job <= 0 then
        close_timer()
        cb("Failed to spawn bash — is it installed?", true)
        return nil
      end

      timer = assert(uv.new_timer())
      timer:start(
        timeout,
        0,
        vim.schedule_wrap(function()
          if finished then return end
          timed_out = true
          pcall(vim.fn.jobstop, job)
        end)
      )

      return {
        stop = function()
          if finished then return end
          stopped = true
          pcall(vim.fn.jobstop, job)
        end,
      }
    end,
  })
end
