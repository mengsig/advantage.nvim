---@brief Diagnostics tool: reports LSP/linter diagnostics. Registered by
---tools/init.lua; behaviour is identical to when it lived inline in that file.

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "diagnostics tool: tool registrar required")
  assert(type(s) == "table" and s.resolve, "diagnostics tool: support module required")
  local resolve = s.resolve

  tool({
    name = "diagnostics",
    safe = true,
    feature = "diagnostics",
    description = "Report LSP/linter diagnostics (compile/type/lint errors and warnings) for a file, or across your open files. Returns compact line:col messages. Use it to verify an edit didn't introduce errors — after a mutating edit the newly-introduced errors are already appended to that tool's result automatically.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File to check (default: all currently open files)" },
        severity = {
          type = "string",
          description = "Minimum severity to report (default warn)",
          enum = { "error", "warn", "all" },
        },
      },
    },
    summary = function(input)
      return input.path or "open files"
    end,
    run = function(input, ctx, cb)
      local diagnostics = require("advantage.diagnostics")
      local severity = input.severity or "warn"
      if input.path and input.path ~= "" then
        local path, perr = resolve(input.path, ctx)
        if not path then return cb(("Cannot check %s: %s"):format(tostring(input.path), perr), true) end
        return diagnostics.report(path, severity, function(text)
          cb(text, false)
        end)
      end
      diagnostics.report(nil, severity, function(text)
        cb(text, false)
      end)
    end,
  })
end
