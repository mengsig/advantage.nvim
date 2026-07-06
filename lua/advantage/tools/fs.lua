---@brief Filesystem tools: read_file, write_file, edit_file, multi_edit.
---Registered by tools/init.lua; behaviour is identical to when these lived
---inline in that file.
local util = require("advantage.util")

---Apply one exact-string edit with edit_file's uniqueness rules.
---@return string|nil new_content, string|nil err
local function apply_edit(s, content, e)
  assert(type(content) == "string", "apply_edit: content must be a string")
  assert(type(e) == "table", "apply_edit: edit spec must be a table")
  if not e.old_string or e.old_string == "" then return nil, "empty old_string" end
  local n = s.count_plain(content, e.old_string)
  if n == 0 then return nil, "old_string not found" end
  if n > 1 and not e.replace_all then
    return nil, ("old_string appears %d times; add surrounding context or set replace_all"):format(n)
  end
  return (s.replace_plain(content, e.old_string, e.new_string or "", e.replace_all))
end

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "fs tools: tool registrar required")
  assert(type(s) == "table" and s.resolve, "fs tools: support module required")
  local resolve, read_all, write_all = s.resolve, s.read_all, s.write_all
  local finish_write, unified_diff = s.finish_write, s.unified_diff
  local replace_plain, count_plain = s.replace_plain, s.count_plain
  local lsp_explore_nudge = s.lsp_explore_nudge
  local MAX_OUTPUT, MAX_LINES, MAX_LINE_LEN = s.MAX_OUTPUT, s.MAX_LINES, s.MAX_LINE_LEN

  -- read_file -------------------------------------------------------------

  tool({
    name = "read_file",
    safe = true,
    description = "Read a file from the project. Returns numbered lines. Use offset/limit for large files. Set outline=true to get just the file's symbol outline (via LSP) instead of its text — far cheaper for navigating a large file.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path, relative to the project root" },
        offset = { type = "integer", description = "1-based line to start from (default 1)" },
        limit = { type = "integer", description = "Max lines to return (default 1500)" },
        outline = {
          type = "boolean",
          description = "Return the file's symbol outline (functions/classes/methods + lines) instead of its text. Needs a language server for the filetype.",
        },
      },
      required = { "path" },
    },
    summary = function(input)
      return (input.path or "") .. (input.outline and " (outline)" or "")
    end,
    run = function(input, ctx, cb)
      -- Outline mode: hand off to the LSP symbol layer for a token-lean overview of
      -- a large file instead of paging its full text. Degrades to a clear message
      -- (which the model reads as "just read it normally") when no server answers.
      if input.outline then
        local ok, lsp = pcall(require, "advantage.lsp")
        if ok and lsp.available() then return lsp.document_symbols(input.path, ctx.cwd, cb) end
        return cb(
          "Outline needs a language server, which isn't available here — omit outline to read the file text.",
          false
        )
      end
      local path, perr = resolve(input.path, ctx)
      if not path then return cb(("Cannot read %s: %s"):format(tostring(input.path), perr), true) end
      local content = read_all(path)
      if not content then return cb("File not found: " .. tostring(input.path), true) end
      -- Binary guard: raw non-text bytes break the request's JSON encoding and burn
      -- tokens on noise. A NUL byte in the head is a reliable binary signal.
      if content:sub(1, 8000):find("\0", 1, true) then
        return cb(("%s appears to be a binary file (%d bytes) — not shown."):format(input.path, #content), false)
      end
      local lines = vim.split(content, "\n", { plain = true })
      local total = #lines
      local offset = math.max(1, input.offset or 1)
      -- Floor at 1: a model-supplied limit<=0 would otherwise make the loop empty
      -- yet still emit a "continue with offset=<same>" suffix — a paging livelock.
      local limit = math.max(1, math.min(input.limit or MAX_LINES, MAX_LINES))
      if offset > total then
        return cb(("(offset %d is past the end — file has %d lines)"):format(offset, total), false)
      end
      -- Fill whole numbered lines up to the line limit AND a byte budget, stopping
      -- on a clean line boundary rather than byte-chopping the joined blob. This
      -- keeps every page valid UTF-8 and — crucially — lets us report the *exact*
      -- next line to resume from, so the model can page through a large file
      -- deterministically instead of losing content past a mid-line cut. Overlong
      -- individual lines are capped character-safely.
      local out, bytes = {}, 0
      for i = offset, math.min(total, offset + limit - 1) do
        local line = lines[i]
        if #line > MAX_LINE_LEN then line = util.utf8_safe_sub(line, MAX_LINE_LEN) .. "…" end
        local rendered = string.format("%6d→%s", i, line)
        -- Always emit at least the first line, even if it alone exceeds the budget.
        if #out > 0 and bytes + #rendered + 1 > MAX_OUTPUT then break end
        out[#out + 1] = rendered
        bytes = bytes + #rendered + 1
      end
      -- Lines are appended consecutively from `offset`, so the last one included is
      -- exactly offset + #out - 1 (and offset-1, i.e. "nothing", is unreachable now
      -- that limit is floored to 1 and offset <= total).
      local last = offset + #out - 1
      local suffix = ""
      if last < total then
        suffix = ("\n… %d more lines — continue with offset=%d"):format(total - last, last + 1)
      end
      cb(table.concat(out, "\n") .. suffix .. lsp_explore_nudge(), false)
    end,
  })

  -- write_file ------------------------------------------------------------

  tool({
    name = "write_file",
    safe = false,
    description = "Create or overwrite a file with the given content. Prefer edit_file for changes to existing files.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path, relative to the project root" },
        content = { type = "string", description = "Full file content" },
      },
      required = { "path", "content" },
    },
    summary = function(input)
      return input.path or ""
    end,
    preview = function(input, ctx)
      local path, perr = resolve(input.path, ctx)
      if not path then
        return { title = "write · " .. tostring(input.path), lines = { "⛔ blocked: " .. perr }, filetype = "" }
      end
      local old = read_all(path)
      if old then
        return {
          title = "write · " .. input.path,
          lines = unified_diff(old, input.content, input.path),
          filetype = "diff",
        }
      end
      local lines = vim.split(input.content, "\n", { plain = true })
      table.insert(lines, 1, "── new file: " .. input.path .. " ──")
      return {
        title = "write · " .. input.path,
        lines = lines,
        filetype = vim.filetype.match({ filename = input.path }) or "",
      }
    end,
    run = function(input, ctx, cb)
      local path, perr = resolve(input.path, ctx)
      if not path then return cb(("Cannot write %s: %s"):format(tostring(input.path), perr), true) end
      local ok, err = write_all(path, input.content)
      if not ok then return cb("Write failed: " .. tostring(err), true) end
      local n = #vim.split(input.content, "\n", { plain = true })
      finish_write(path, ("Wrote %d lines to %s"):format(n, input.path), cb)
    end,
  })

  -- edit_file -------------------------------------------------------------

  tool({
    name = "edit_file",
    safe = false,
    description = "Replace an exact string in a file. old_string must match exactly (including whitespace) and be unique unless replace_all is set. Include enough surrounding lines to make it unique.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path, relative to the project root" },
        old_string = { type = "string", description = "Exact text to replace" },
        new_string = { type = "string", description = "Replacement text" },
        replace_all = { type = "boolean", description = "Replace every occurrence (default false)" },
      },
      required = { "path", "old_string", "new_string" },
    },
    summary = function(input)
      return input.path or ""
    end,
    preview = function(input, ctx)
      if not input.old_string or input.old_string == "" then
        return {
          title = "edit · " .. tostring(input.path),
          lines = { "invalid edit: empty old_string" },
          filetype = "",
        }
      end
      local path, perr = resolve(input.path, ctx)
      if not path then
        return { title = "edit · " .. tostring(input.path), lines = { "⛔ blocked: " .. perr }, filetype = "" }
      end
      local old = read_all(path)
      if not old then
        return { title = "edit · " .. tostring(input.path), lines = { "file not found" }, filetype = "" }
      end
      local new = (replace_plain(old, input.old_string, input.new_string, input.replace_all))
      return { title = "edit · " .. input.path, lines = unified_diff(old, new, input.path), filetype = "diff" }
    end,
    run = function(input, ctx, cb)
      if not input.old_string or input.old_string == "" then
        return cb("old_string must be a non-empty exact match. Use write_file to create or fully rewrite a file.", true)
      end
      local path, perr = resolve(input.path, ctx)
      if not path then return cb(("Cannot edit %s: %s"):format(tostring(input.path), perr), true) end
      local content = read_all(path)
      if not content then return cb("File not found: " .. tostring(input.path), true) end
      local n = count_plain(content, input.old_string)
      if n == 0 then
        return cb("old_string not found in " .. input.path .. ". Read the file and match the text exactly.", true)
      end
      if n > 1 and not input.replace_all then
        return cb(
          ("old_string appears %d times in %s. Add surrounding context to make it unique, or set replace_all."):format(
            n,
            input.path
          ),
          true
        )
      end
      local new_content, count = replace_plain(content, input.old_string, input.new_string, input.replace_all)
      local ok, err = write_all(path, new_content)
      if not ok then return cb("Write failed: " .. tostring(err), true) end
      finish_write(path, ("Applied %d replacement%s in %s"):format(count, count == 1 and "" or "s", input.path), cb)
    end,
  })

  -- multi_edit ------------------------------------------------------------

  tool({
    name = "multi_edit",
    safe = false,
    description = "Apply several exact string replacements to one file in a single atomic operation. Edits apply in order, each to the result of the previous; if any edit fails to match, nothing is written. Prefer this over repeated edit_file calls on the same file.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path, relative to the project root" },
        edits = {
          type = "array",
          description = "Edits applied in order",
          items = {
            type = "object",
            properties = {
              old_string = { type = "string", description = "Exact text to replace" },
              new_string = { type = "string", description = "Replacement text" },
              replace_all = { type = "boolean", description = "Replace every occurrence (default false)" },
            },
            required = { "old_string", "new_string" },
          },
        },
      },
      required = { "path", "edits" },
    },
    summary = function(input)
      local n = type(input.edits) == "table" and #input.edits or 0
      return ("%s (%d edit%s)"):format(input.path or "", n, n == 1 and "" or "s")
    end,
    preview = function(input, ctx)
      local title = "multi-edit · " .. tostring(input.path)
      local path, perr = resolve(input.path, ctx)
      if not path then return { title = title, lines = { "⛔ blocked: " .. perr }, filetype = "" } end
      local old = read_all(path)
      if not old then return { title = title, lines = { "file not found" }, filetype = "" } end
      local new = old
      for i, e in ipairs(type(input.edits) == "table" and input.edits or {}) do
        local applied, aerr = apply_edit(s, new, e)
        if not applied then
          return {
            title = title,
            lines = { ("edit %d failed: %s — nothing will be written"):format(i, aerr) },
            filetype = "",
          }
        end
        new = applied
      end
      return { title = title, lines = unified_diff(old, new, input.path), filetype = "diff" }
    end,
    run = function(input, ctx, cb)
      local path, perr = resolve(input.path, ctx)
      if not path then return cb(("Cannot edit %s: %s"):format(tostring(input.path), perr), true) end
      local content = read_all(path)
      if not content then return cb("File not found: " .. tostring(input.path), true) end
      local edits = input.edits
      if type(edits) ~= "table" or #edits == 0 then
        return cb("edits must be a non-empty array of {old_string, new_string}", true)
      end
      local new_content = content
      for i, e in ipairs(edits) do
        local applied, aerr = apply_edit(s, new_content, e)
        if not applied then
          return cb(("Edit %d/%d failed: %s. No changes were written."):format(i, #edits, aerr), true)
        end
        new_content = applied
      end
      local ok, err = write_all(path, new_content)
      if not ok then return cb("Write failed: " .. tostring(err), true) end
      finish_write(path, ("Applied %d edit%s to %s"):format(#edits, #edits == 1 and "" or "s", input.path), cb)
    end,
  })
end
