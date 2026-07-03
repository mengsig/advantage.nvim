---@brief Built-in tools. Each tool: name, description, input_schema (JSON Schema),
---safe (auto-approved), run(input, ctx, cb) async, preview(input, ctx) for the
---permission card.
local M = {}

local uv = vim.uv or vim.loop

local MAX_OUTPUT = 30000
local MAX_LINES = 1500
local MAX_LINE_LEN = 500

local function resolve(path, ctx)
  if not path or path == "" then return nil end
  path = vim.fs.normalize(path)
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.normalize(ctx.cwd .. "/" .. path)
  end
  return path
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
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(content)
  f:close()
  return true
end

local function truncate(s, limit)
  limit = limit or MAX_OUTPUT
  if #s > limit then
    return s:sub(1, limit) .. "\n… [output truncated at " .. limit .. " chars]"
  end
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
  summary = function(input) return input.path or "" end,
  run = function(input, ctx, cb)
    local path = resolve(input.path, ctx)
    local content = path and read_all(path)
    if not content then
      return cb("File not found: " .. tostring(input.path), true)
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
    if #out == 0 then
      return cb("(empty range — file has " .. #lines .. " lines)", false)
    end
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
  summary = function(input) return input.path or "" end,
  preview = function(input, ctx)
    local path = resolve(input.path, ctx)
    local old = path and read_all(path)
    if old then
      return { title = "write · " .. input.path, lines = unified_diff(old, input.content, input.path), filetype = "diff" }
    end
    local lines = vim.split(input.content, "\n", { plain = true })
    table.insert(lines, 1, "── new file: " .. input.path .. " ──")
    return { title = "write · " .. input.path, lines = lines, filetype = vim.filetype.match({ filename = input.path }) or "" }
  end,
  run = function(input, ctx, cb)
    local path = resolve(input.path, ctx)
    if not path then return cb("Invalid path", true) end
    local ok, err = write_all(path, input.content)
    if not ok then return cb("Write failed: " .. tostring(err), true) end
    refresh_buffers(path)
    local n = #vim.split(input.content, "\n", { plain = true })
    cb(("Wrote %d lines to %s"):format(n, input.path), false)
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
  summary = function(input) return input.path or "" end,
  preview = function(input, ctx)
    if not input.old_string or input.old_string == "" then
      return { title = "edit · " .. tostring(input.path), lines = { "invalid edit: empty old_string" }, filetype = "" }
    end
    local path = resolve(input.path, ctx)
    local old = path and read_all(path)
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
    local path = resolve(input.path, ctx)
    local content = path and read_all(path)
    if not content then
      return cb("File not found: " .. tostring(input.path), true)
    end
    local n = count_plain(content, input.old_string)
    if n == 0 then
      return cb("old_string not found in " .. input.path .. ". Read the file and match the text exactly.", true)
    end
    if n > 1 and not input.replace_all then
      return cb(("old_string appears %d times in %s. Add surrounding context to make it unique, or set replace_all."):format(n, input.path), true)
    end
    local new_content, count = replace_plain(content, input.old_string, input.new_string, input.replace_all)
    local ok, err = write_all(path, new_content)
    if not ok then return cb("Write failed: " .. tostring(err), true) end
    refresh_buffers(path)
    cb(("Applied %d replacement%s in %s"):format(count, count == 1 and "" or "s", input.path), false)
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
    local job

    local function add_chunk(data)
      if not data then return end
      local text
      if type(data) == "table" then
        local lines = {}
        for _, line in ipairs(data) do
          if line ~= "" then lines[#lines + 1] = line end
        end
        if #lines == 0 then return end
        text = table.concat(lines, "\n") .. "\n"
      else
        text = tostring(data)
      end
      chunks[#chunks + 1] = text
      if stream then cb(text, false, { stream = true }) end
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
      on_stdout = function(_, data) add_chunk(data) end,
      on_stderr = function(_, data) add_chunk(data) end,
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
    timer:start(timeout, 0, vim.schedule_wrap(function()
      if finished then return end
      timed_out = true
      pcall(vim.fn.jobstop, job)
    end))

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
      glob = { type = "string", description = "Filter files, e.g. \"*.lua\"" },
    },
    required = { "pattern" },
  },
  summary = function(input) return input.pattern or "" end,
  run = function(input, ctx, cb)
    local cmd
    if vim.fn.executable("rg") == 1 then
      cmd = { "rg", "--line-number", "--no-heading", "--color=never", "--max-count=100", "-e", input.pattern }
      if input.glob then
        vim.list_extend(cmd, { "--glob", input.glob })
      end
      cmd[#cmd + 1] = input.path or "."
    else
      cmd = { "grep", "-rn", "-E", input.pattern, input.path or "." }
    end
    vim.system(cmd, { cwd = ctx.cwd, text = true }, function(res)
      vim.schedule(function()
        if res.code > 1 then
          return cb("Search failed: " .. (res.stderr or ""), true)
        end
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
  description = "List project files matching a glob pattern, e.g. \"**/*.lua\" or \"src/**\".",
  input_schema = {
    type = "object",
    properties = {
      pattern = { type = "string", description = "Glob pattern" },
    },
    required = { "pattern" },
  },
  summary = function(input) return input.pattern or "" end,
  run = function(input, ctx, cb)
    local cmd
    if vim.fn.executable("rg") == 1 then
      cmd = { "rg", "--files", "--glob", input.pattern }
    else
      cmd = { "sh", "-c", "find . -path './.git' -prune -o -type f -print" }
    end
    vim.system(cmd, { cwd = ctx.cwd, text = true }, function(res)
      vim.schedule(function()
        local lines = vim.split(vim.trim(res.stdout or ""), "\n", { plain = true, trimempty = true })
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
  summary = function(input) return input.path or "." end,
  run = function(input, ctx, cb)
    local path = resolve((input.path and input.path ~= "") and input.path or ".", ctx)
    local handle = path and uv.fs_scandir(path)
    if not handle then
      return cb("Not a directory: " .. tostring(input.path), true)
    end
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

-- sub_agent -------------------------------------------------------------

tool({
  name = "sub_agent",
  safe = true,
  description = "Spawn a read-only sub-agent for independent investigation. The sub-agent can read/search/list files and returns a concise report; it cannot edit files.",
  input_schema = {
    type = "object",
    properties = {
      prompt = { type = "string", description = "Investigation task for the sub-agent" },
      model = { type = "string", description = "Optional model ref provider/model-id; defaults to the current model" },
      max_turns = { type = "integer", description = "Maximum sub-agent turns including tool loops (default from config, capped at 12)" },
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

-- registry --------------------------------------------------------------

local by_name = {}
for _, def in ipairs(M.list) do
  by_name[def.name] = def
end

function M.get(name)
  return by_name[name]
end

---Resolve a tool path argument against the project root (for snapshots etc).
M.resolve = resolve

---Tool schemas in Anthropic format (providers convert as needed).
function M.schemas()
  local out = {}
  for _, def in ipairs(M.list) do
    out[#out + 1] = {
      name = def.name,
      description = def.description,
      input_schema = def.input_schema,
    }
  end
  return out
end

return M
