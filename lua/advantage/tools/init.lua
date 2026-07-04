---@brief Built-in tools. Each tool: name, description, input_schema (JSON Schema),
---safe (auto-approved), run(input, ctx, cb) async, preview(input, ctx) for the
---permission card.
local M = {}

local uv = vim.uv or vim.loop

local MAX_OUTPUT = 30000
local MAX_LINES = 1500
local MAX_LINE_LEN = 500

---Resolve a tool path against the project root and enforce containment: file
---tools (including their permission-card previews, which read the target before
---approval) must not reach outside ctx.cwd via absolute paths or `..` traversal.
---`tools.allow_outside_root = true` opts out. Containment is enforced both
---lexically and by resolving symlinks (realpath), so a symlink committed inside
---the repo that points outside cannot be used to escape the sandbox.
---@return string|nil abs_path, string|nil err
local function resolve(path, ctx)
  local tcfg = require("advantage.config").options.tools or {}
  return require("advantage.util").contain(path, ctx.cwd, tcfg.allow_outside_root)
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_all(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- Atomic write: temp file + rename so a crash, a full disk (ENOSPC), or a
  -- racing reader can never leave a half-written or truncated source file — and
  -- a failed write is reported, never silently swallowed as success. Preserve the
  -- existing file's mode when overwriting.
  local st = uv.fs_stat(path)
  local tmp = path .. ".adv.tmp"
  local f, oerr = io.open(tmp, "w")
  if not f then return nil, oerr end
  local ok_w, werr = f:write(content)
  local ok_c = f:close()
  if not ok_w or not ok_c then
    os.remove(tmp)
    return nil, werr or "write failed"
  end
  if st and st.mode then pcall(uv.fs_chmod, tmp, st.mode) end
  local ok_r, rerr = os.rename(tmp, path)
  if not ok_r then
    os.remove(tmp)
    return nil, rerr or "rename failed"
  end
  return true
end

local function truncate(s, limit)
  limit = limit or MAX_OUTPUT
  if #s > limit then return s:sub(1, limit) .. "\n… [output truncated at " .. limit .. " chars]" end
  return s
end

---Reload any buffer that has `path` open, after an external edit.
local function refresh_buffers(path)
  vim.schedule(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd.checktime)
        end)
      end
    end
  end)
end

---Finish a successful mutating edit: reload any open buffer, then (best-effort)
---append the newly-introduced LSP/linter diagnostics to the tool result so the
---model can self-correct. Snapshotting the pre-edit diagnostics happens before
---the buffer reloads, so the after/before diff only surfaces problems the edit
---actually introduced. Degrades to a plain success when diagnostics are off or
---unavailable.
local function finish_write(path, msg, cb)
  local ok, diagnostics = pcall(require, "advantage.diagnostics")
  local dcfg = (require("advantage.config").options.tools or {}).diagnostics
  local severity = (type(dcfg) == "table" and dcfg.severity) or "error"
  local before = ok and diagnostics.snapshot(path, severity) or nil
  refresh_buffers(path)
  if not ok then return cb(msg, false) end
  diagnostics.after_edit(path, before, function(extra)
    cb(msg .. (extra or ""), false)
  end)
end

local function unified_diff(old, new, path)
  local diff = vim.diff(old, new, { result_type = "unified", ctxlen = 3 })
  if not diff or diff == "" then return { "(no changes)" } end
  local lines = { "--- a/" .. path, "+++ b/" .. path }
  vim.list_extend(lines, vim.split(diff, "\n", { plain = true, trimempty = true }))
  return lines
end

local function replace_plain(s, old, new, all)
  if old == "" then return s, 0 end
  local out, count, init = {}, 0, 1
  while true do
    local i, j = s:find(old, init, true)
    if not i then break end
    out[#out + 1] = s:sub(init, i - 1)
    out[#out + 1] = new
    init = j + 1
    count = count + 1
    if not all then break end
  end
  out[#out + 1] = s:sub(init)
  return table.concat(out), count
end

local function count_plain(s, needle)
  if needle == "" then return 0 end
  local count, init = 0, 1
  while true do
    local i, j = s:find(needle, init, true)
    if not i then break end
    count = count + 1
    init = j + 1
  end
  return count
end

M.list = {}

local function tool(def)
  M.list[#M.list + 1] = def
end

-- read_file -------------------------------------------------------------

tool({
  name = "read_file",
  safe = true,
  description = "Read a file from the project. Returns numbered lines. Use offset/limit for large files.",
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "File path, relative to the project root" },
      offset = { type = "integer", description = "1-based line to start from (default 1)" },
      limit = { type = "integer", description = "Max lines to return (default 1500)" },
    },
    required = { "path" },
  },
  summary = function(input)
    return input.path or ""
  end,
  run = function(input, ctx, cb)
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
    local offset = math.max(1, input.offset or 1)
    local limit = math.min(input.limit or MAX_LINES, MAX_LINES)
    local out = {}
    for i = offset, math.min(#lines, offset + limit - 1) do
      local line = lines[i]
      if #line > MAX_LINE_LEN then line = line:sub(1, MAX_LINE_LEN) .. "…" end
      out[#out + 1] = string.format("%6d→%s", i, line)
    end
    if #out == 0 then return cb("(empty range — file has " .. #lines .. " lines)", false) end
    local suffix = ""
    if offset + limit - 1 < #lines then
      suffix = ("\n… %d more lines (use offset=%d)"):format(#lines - (offset + limit - 1), offset + limit)
    end
    cb(truncate(table.concat(out, "\n") .. suffix), false)
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
      return { title = "edit · " .. tostring(input.path), lines = { "invalid edit: empty old_string" }, filetype = "" }
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

---Apply one exact-string edit with edit_file's uniqueness rules.
---@return string|nil new_content, string|nil err
local function apply_edit(content, e)
  if not e.old_string or e.old_string == "" then return nil, "empty old_string" end
  local n = count_plain(content, e.old_string)
  if n == 0 then return nil, "old_string not found" end
  if n > 1 and not e.replace_all then
    return nil, ("old_string appears %d times; add surrounding context or set replace_all"):format(n)
  end
  return (replace_plain(content, e.old_string, e.new_string or "", e.replace_all))
end

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
      local applied, aerr = apply_edit(new, e)
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
      local applied, aerr = apply_edit(new_content, e)
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

-- bash ------------------------------------------------------------------

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
    return #c > 60 and (c:sub(1, 57) .. "…") or c
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
          cb(truncate(out), timed_out or stopped or code ~= 0)
        end)
      end,
    })
    if job <= 0 then
      close_timer()
      cb("Failed to spawn bash — is it installed?", true)
      return nil
    end

    timer = uv.new_timer()
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

-- grep ------------------------------------------------------------------

tool({
  name = "grep",
  safe = true,
  description = "Search file contents with a regex (ripgrep). Returns file:line:text matches.",
  input_schema = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Regex pattern to search for" },
      path = { type = "string", description = "Directory or file to search (default: project root)" },
      glob = { type = "string", description = 'Filter files, e.g. "*.lua"' },
    },
    required = { "pattern" },
  },
  summary = function(input)
    return input.pattern or ""
  end,
  run = function(input, ctx, cb)
    local search_path = "."
    if input.path and input.path ~= "" and input.path ~= "." then
      local p, perr = resolve(input.path, ctx)
      if not p then return cb(("Cannot search %s: %s"):format(tostring(input.path), perr), true) end
      search_path = p
    end
    local cmd
    if vim.fn.executable("rg") == 1 then
      cmd = { "rg", "--line-number", "--no-heading", "--color=never", "--max-count=100", "-e", input.pattern }
      if input.glob then vim.list_extend(cmd, { "--glob", input.glob }) end
      cmd[#cmd + 1] = search_path
    else
      cmd = { "grep", "-rn", "-E", input.pattern, search_path }
    end
    vim.system(cmd, { cwd = ctx.cwd, text = true }, function(res)
      vim.schedule(function()
        if res.code > 1 then return cb("Search failed: " .. (res.stderr or ""), true) end
        local out = vim.trim(res.stdout or "")
        cb(out == "" and "No matches." or truncate(out), false)
      end)
    end)
  end,
})

-- find_files ------------------------------------------------------------

tool({
  name = "find_files",
  safe = true,
  description = 'List project files matching a glob pattern, e.g. "**/*.lua" or "src/**".',
  input_schema = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Glob pattern" },
    },
    required = { "pattern" },
  },
  summary = function(input)
    return input.pattern or ""
  end,
  run = function(input, ctx, cb)
    local cmd, filter_re
    if vim.fn.executable("rg") == 1 then
      cmd = { "rg", "--files", "--glob", input.pattern }
    else
      cmd = { "sh", "-c", "find . -path './.git' -prune -o -type f -print" }
      -- rg is absent: filter the full file list against the glob ourselves so
      -- the pattern is still honoured instead of dumping the whole tree.
      if input.pattern and input.pattern ~= "" then
        local ok, re = pcall(vim.fn.glob2regpat, input.pattern)
        if ok then filter_re = re end
      end
    end
    vim.system(cmd, { cwd = ctx.cwd, text = true }, function(res)
      vim.schedule(function()
        local lines = vim.split(vim.trim(res.stdout or ""), "\n", { plain = true, trimempty = true })
        if filter_re then
          local matched = {}
          for _, line in ipairs(lines) do
            local rel = line:gsub("^%./", "")
            if vim.fn.match(rel, filter_re) >= 0 then matched[#matched + 1] = rel end
          end
          lines = matched
        end
        if #lines > 300 then
          local total = #lines
          lines = vim.list_slice(lines, 1, 300)
          lines[#lines + 1] = ("… %d more files"):format(total - 300)
        end
        cb(#lines == 0 and "No files matched." or table.concat(lines, "\n"), false)
      end)
    end)
  end,
})

-- list_dir --------------------------------------------------------------

tool({
  name = "list_dir",
  safe = true,
  description = "List entries of a directory. Directories end with '/'.",
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Directory path (default: project root)" },
    },
  },
  summary = function(input)
    return input.path or "."
  end,
  run = function(input, ctx, cb)
    local path, perr = resolve((input.path and input.path ~= "") and input.path or ".", ctx)
    if not path then return cb(("Cannot list %s: %s"):format(tostring(input.path), perr), true) end
    local handle = uv.fs_scandir(path)
    if not handle then return cb("Not a directory: " .. tostring(input.path), true) end
    local dirs, files = {}, {}
    while true do
      local name, t = uv.fs_scandir_next(handle)
      if not name then break end
      if t == "directory" then
        dirs[#dirs + 1] = name .. "/"
      else
        files[#files + 1] = name
      end
      if #dirs + #files >= 500 then break end
    end
    table.sort(dirs)
    table.sort(files)
    vim.list_extend(dirs, files)
    cb(#dirs == 0 and "(empty)" or table.concat(dirs, "\n"), false)
  end,
})

-- diagnostics -----------------------------------------------------------

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

-- sub_agent -------------------------------------------------------------

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
    return #p > 60 and (p:sub(1, 57) .. "…") or p
  end,
  run = function(input, ctx, cb)
    return require("advantage.subagent").run(input, ctx, cb)
  end,
})

-- todo_write (plan tool) --------------------------------------------------

local TODO_MARKS = { pending = "·", in_progress = "▶", completed = "✓" }

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

-- memory / skills (the self-learning harness) ---------------------------

---Append-only curation steer: nudge the model (in the tool result — never the
---cached prefix, so it's free of per-turn cost) toward the curation that actually
---matters. Fires on genuine procedural DEPTH (belongs in an on-demand skill),
---REDUNDANT overlapping facts (merge them), or real BUDGET pressure — never on
---raw bullet length, which is cheap behind prompt-caching and whose specificity
---is the point. Also fires a once-per-session persistent notice to the user.
local function curation_suffix(res)
  local out = ""
  if res.procedural_count and res.procedural_count > 0 then
    out = out
      .. (" %d memory fact(s) read as procedural depth — move each into a skill (save_skill) with a description rich in the terms you'd search for, then leave a crisp one-line pointer; the body loads on demand via use_skill. Don't shorten precise facts, just relocate real depth."):format(
        res.procedural_count
      )
  end
  if res.redundant_pairs and res.redundant_pairs >= 3 then
    out = out
      .. (" Memory has %d overlapping fact pair(s) — merge them so it never says the same thing twice or contradicts itself."):format(
        res.redundant_pairs
      )
  end
  if res.utilization and res.utilization > 0.85 then
    -- in-band signal to the model (the tool result rides the transcript, not the
    -- cached prefix, so it costs nothing per turn)
    out = out
      .. (" Memory is at %d%% of its budget — curate: merge overlaps, drop stale facts, extract depth into skills (never truncate a load-bearing fact to save space)."):format(
        math.floor(res.utilization * 100 + 0.5)
      )
    -- once-per-session persistent nudge to the user
    local mem = require("advantage.memory")
    if mem.curation_nudge_due() then
      pcall(function()
        require("advantage.ui.chat").notice(
          ("⚠ repo memory is ~%d%% full — run /context curate (merge overlaps, extract depth into skills)"):format(
            math.floor(res.utilization * 100 + 0.5)
          )
        )
      end)
    end
  end
  return out
end

tool({
  name = "remember",
  safe = true,
  memory = true,
  description = "Save a durable, repo-specific fact to persistent memory so future sessions start already knowing it. Use for an architecture invariant, a convention, a build/test/lint command, a gotcha, or a preference the user states — one crisp, self-contained fact per call. Do NOT save trivia, transient state, or anything a quick file read re-derives.",
  input_schema = {
    type = "object",
    properties = {
      fact = { type = "string", description = "The single fact to remember, phrased concisely and self-contained." },
      section = {
        type = "string",
        description = "Where it belongs.",
        enum = { "Conventions", "Architecture", "Commands", "Gotchas", "Preferences", "Notes" },
      },
    },
    required = { "fact" },
  },
  summary = function(input)
    local f = (input.fact or ""):gsub("%s+", " ")
    return #f > 60 and (f:sub(1, 57) .. "…") or f
  end,
  run = function(input, ctx, cb)
    local memory = require("advantage.memory")
    if not memory.enabled() then return cb("Memory is disabled (config.memory.enabled = false).", true) end
    local res = memory.remember(input.fact, input.section)
    if res.status == "empty" then
      return cb("Nothing to remember (empty fact).", true)
    elseif res.status == "procedural" then
      return cb(
        "This reads like a multi-step procedure, not a fact. Procedures cost their full length in every request as memory bullets but only one index line as skills — record it with save_skill instead (or split out the single durable fact).",
        true
      )
    elseif res.status == "duplicate" then
      return cb("Already known — a near-identical fact is in memory; not duplicated.", false)
    elseif res.status == "updated" then
      return cb(("Updated the existing fact under %s."):format(res.section) .. curation_suffix(res), false)
    end
    local msg = ("Remembered under %s."):format(res.section)
    if res.evicted and #res.evicted > 0 then
      local shown = {}
      for i = 1, math.min(3, #res.evicted) do
        shown[#shown + 1] = '"' .. res.evicted[i] .. '"'
      end
      msg = msg
        .. (" Memory hit its budget — %d oldest fact%s evicted: %s%s. If any is still valuable, re-record it tighter or fold it into a skill."):format(
          #res.evicted,
          #res.evicted == 1 and "" or "s",
          table.concat(shown, ", "),
          #res.evicted > 3 and ", …" or ""
        )
    end
    cb(msg .. curation_suffix(res), false)
  end,
})

tool({
  name = "use_skill",
  safe = true,
  memory = true,
  description = "Load the full steps of a named skill (a reusable procedure for this repo). Skill names and descriptions are listed in your context under 'Skills'; call this when a skill's description matches the task, before doing that task.",
  input_schema = {
    type = "object",
    properties = {
      name = { type = "string", description = "The skill name, exactly as listed in the skills index." },
    },
    required = { "name" },
  },
  summary = function(input)
    return input.name or ""
  end,
  run = function(input, ctx, cb)
    local memory = require("advantage.memory")
    local body, desc = memory.use_skill(input.name)
    if not body then
      local names = {}
      for _, s in ipairs(memory.skills_index()) do
        names[#names + 1] = s.name
      end
      return cb(
        ("No skill named %q. Available: %s"):format(
          tostring(input.name),
          #names > 0 and table.concat(names, ", ") or "(none)"
        ),
        true
      )
    end
    cb(("Skill: %s — %s\n\n%s"):format(input.name, desc or "", body), false)
  end,
})

tool({
  name = "save_skill",
  safe = true,
  memory = true,
  description = "Create or update a reusable skill: a named, multi-step procedure for this repo (e.g. how to run the test suite, cut a release, add a provider). Worthwhile only for genuinely reusable procedures of ~3+ steps, not one-offs.",
  input_schema = {
    type = "object",
    properties = {
      name = { type = "string", description = "Short kebab-case skill name." },
      description = { type = "string", description = "One line describing when to use this skill (its trigger)." },
      body = { type = "string", description = "The procedure/steps, in Markdown." },
    },
    required = { "name", "description", "body" },
  },
  summary = function(input)
    return input.name or ""
  end,
  run = function(input, ctx, cb)
    local memory = require("advantage.memory")
    if not memory.enabled() then return cb("Memory is disabled (config.memory.enabled = false).", true) end
    local ok, err = memory.save_skill(input.name, input.description, input.body)
    if not ok then return cb("Could not save skill: " .. tostring(err), true) end
    cb(("Saved skill %q. It is now in the skills index; load its steps with use_skill."):format(input.name), false)
  end,
})

-- registry --------------------------------------------------------------

local by_name = {}
for _, def in ipairs(M.list) do
  by_name[def.name] = def
end

function M.get(name)
  return by_name[name]
end

---Validate a decoded tool input against its schema's `required` list. Models
---intermittently drop a required argument (classically `path` on edit_file when
---the big `new_string` field dominates the call), and a truncated tool-call
---stream decodes to an empty object. Both used to fail deep inside the tool with
---a cryptic, tool-specific message ("Cannot edit nil: empty path"), which the
---model tends to repeat rather than correct. Returning a precise, uniform error
---up front turns that into a one-shot self-correction.
---@return string|nil err  nil if valid, else a message naming the missing args
function M.validate_input(name, input)
  local def = by_name[name]
  local req = def and def.input_schema and def.input_schema.required
  if not req then return nil end
  input = type(input) == "table" and input or {}
  local missing = {}
  for _, field in ipairs(req) do
    -- Present-but-empty is the tool's own concern (e.g. edit_file new_string=""
    -- deletes text); "required" only means the key must be supplied.
    if input[field] == nil then missing[#missing + 1] = field end
  end
  if #missing == 0 then return nil end
  local provided = {}
  for k in pairs(input) do
    provided[#provided + 1] = k
  end
  table.sort(provided)
  return ("%s: missing required argument%s: %s. %s"):format(
    name,
    #missing == 1 and "" or "s",
    table.concat(missing, ", "),
    #provided > 0 and ("You provided: " .. table.concat(provided, ", ") .. ".")
      or "You provided no arguments — re-issue the call with all required fields."
  )
end

---Resolve a tool path argument against the project root (for snapshots etc).
M.resolve = resolve

---Whether a tool that is gated on a config-toggled feature is currently enabled.
---`memory` tools follow config.memory.enabled; `feature = "diagnostics"` tools
---follow config.tools.diagnostics.enabled. Ungated tools are always enabled.
function M.enabled(def)
  if def.memory then
    local m = require("advantage.config").options.memory
    return not m or m.enabled ~= false
  end
  if def.feature == "diagnostics" then
    local t = (require("advantage.config").options.tools or {}).diagnostics
    return not (type(t) == "table" and t.enabled == false)
  end
  return true
end

---Tool schemas in Anthropic format (providers convert as needed).
function M.schemas()
  local out = {}
  for _, def in ipairs(M.list) do
    if M.enabled(def) then
      out[#out + 1] = {
        name = def.name,
        description = def.description,
        input_schema = def.input_schema,
      }
    end
  end
  return out
end

return M
