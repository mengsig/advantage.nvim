---@brief Optional, read-only NavGraph code-navigation tool.
---
---NavGraph is an external binary, so this adapter deliberately exposes only a
---small command surface that is read-only across supported NavGraph versions.
---It never invokes a shell, never accepts a caller-controlled index root, and
---always disables NavGraph's on-disk cache so the tool remains safe for scouts.
local util = require("advantage.util")
local uv = vim.uv or vim.loop

-- Keep this list compatible with the oldest NavGraph build used by the harness
-- benchmarks. New commands can be added once every supported/pinned build has
-- them; mutating or long-lived commands (rename, serve/MCP) never belong here.
local COMMANDS = {
  "outline",
  "def",
  "calls",
  "callers",
  "search",
  "routes",
  "events",
  "neighbors",
  "unused",
  "imports",
  "importers",
  "path",
  "hot",
  "files",
  "read",
  "strings",
}

local ALLOWED = {}
for _, command in ipairs(COMMANDS) do
  ALLOWED[command] = true
end

local MAX_FIELD_BYTES = 4096
local MAX_RESULT_LIMIT = 200
local MAX_DEPTH = 8
local MAX_READ_RANGES = 16
local MAX_TIMEOUT_MS = 300000
local MAX_OUTPUT_BYTES = 1048576

local REQUIRED_TARGET = {
  outline = true,
  def = true,
  calls = true,
  callers = true,
  search = true,
  routes = true,
  events = true,
  neighbors = true,
  imports = true,
  importers = true,
  path = true,
  read = true,
  strings = true,
}

local OPTION_COMMANDS = {
  depth = { calls = true, callers = true },
  kind = { outline = true, search = true },
  refs = { calls = true, neighbors = true, search = true },
  strict = { calls = true, callers = true, neighbors = true, path = true },
  sort = { files = true },
  exclude_public = { unused = true },
  follow_imports = { unused = true },
}

local KNOWN_FIELDS = { command = true, target = true, destination = true, limit = true }
for field in pairs(OPTION_COMMANDS) do
  KNOWN_FIELDS[field] = true
end

local DEFAULT_LIMIT = {
  outline = 40,
  def = 5,
  calls = 40,
  callers = 40,
  search = 40,
  routes = 40,
  events = 40,
  neighbors = 40,
  unused = 40,
  imports = 40,
  importers = 40,
  path = 40,
  hot = 40,
  files = 80,
  read = 80,
  strings = 40,
}

local DEFAULT_DETAIL = {
  outline = "names",
  def = "full",
  calls = "names",
  callers = "names",
  search = "names",
  routes = "names",
  events = "names",
  neighbors = "names",
  unused = "names",
  imports = "names",
  importers = "names",
  path = "names",
  hot = "names",
}

local function fixed_root(cwd)
  if type(cwd) ~= "string" or vim.trim(cwd) == "" then return nil, "NavGraph requires a project root" end
  local root = uv.fs_realpath(cwd) or vim.fs.normalize(cwd)
  local stat = uv.fs_stat(root)
  if not stat or stat.type ~= "directory" then return nil, "NavGraph project root is not a directory: " .. root end
  return root
end

local function validate_field(value, field, required)
  if value == nil then
    if required then return nil, ("NavGraph %s is required"):format(field) end
    return nil
  end
  -- Some model transports materialize optional string properties as "" even
  -- when the model did not intend to provide them. Treat exactly-empty optional
  -- fields as omitted so a search does not accidentally acquire path arity.
  if value == "" and not required then return nil end
  if type(value) ~= "string" or vim.trim(value) == "" then
    return nil, ("NavGraph %s must be a non-empty string"):format(field)
  end
  if vim.trim(value) ~= value then return nil, ("NavGraph %s must not have surrounding whitespace"):format(field) end
  if value:sub(1, 1) == "-" then return nil, ("NavGraph %s must be positional, not a flag"):format(field) end
  if value:find("\0", 1, true) then return nil, ("NavGraph %s contains a NUL byte"):format(field) end
  if #value > MAX_FIELD_BYTES then
    return nil, ("NavGraph %s exceeds the %d-byte limit"):format(field, MAX_FIELD_BYTES)
  end
  return value
end

local function parse_read_target(spec)
  -- NavGraph itself also accepts open-ended `A-`; the harness deliberately
  -- does not because an "exact" semantic read must have a knowable context
  -- budget before the process starts. A greedy path prefix preserves legitimate
  -- colons in relative filenames while parsing only the final range suffix.
  local path, ranges = spec:match("^(.*):([%d,%-]+)$")
  if not path or path == "" or not ranges then
    return nil, "NavGraph read requires an explicit bounded range such as src/a.lua:20-60"
  end

  local raw = vim.split(ranges, ",", { plain = true })
  if #raw > MAX_READ_RANGES then
    return nil, ("NavGraph read supports at most %d ranges per call; narrow or split the query"):format(MAX_READ_RANGES)
  end

  local intervals = {}
  for _, part in ipairs(raw) do
    local first, last = part:match("^(%d+)%-(%d+)$")
    if not first then
      first = part:match("^(%d+)$")
      last = first
    end
    first, last = tonumber(first), tonumber(last)
    if not first or not last or first < 1 or last < first then
      return nil, ("NavGraph read range %q must be a positive line or closed ascending A-B interval"):format(part)
    end
    intervals[#intervals + 1] = { first, last }
  end

  table.sort(intervals, function(left, right)
    return left[1] == right[1] and left[2] < right[2] or left[1] < right[1]
  end)
  local merged = {}
  for _, interval in ipairs(intervals) do
    local prior = merged[#merged]
    if prior and interval[1] <= prior[2] + 1 then
      prior[2] = math.max(prior[2], interval[2])
    else
      merged[#merged + 1] = { interval[1], interval[2] }
    end
  end
  local unique_lines = 0
  for _, interval in ipairs(merged) do
    unique_lines = unique_lines + interval[2] - interval[1] + 1
  end
  return { path = path, ranges = #raw, unique_lines = unique_lines }
end

local function validate_call(input, root)
  local function invalid(message)
    return nil, message
  end

  if type(input) ~= "table" then return invalid("NavGraph input must be an object") end
  if input.args ~= nil or input.flags ~= nil or input.detail ~= nil then
    return invalid("NavGraph no longer accepts raw args/flags/detail; use its typed target, limit, and command options")
  end
  for field in pairs(input) do
    if not KNOWN_FIELDS[field] then return invalid(("NavGraph does not support field %s"):format(tostring(field))) end
  end

  local command = input.command
  if type(command) ~= "string" or not ALLOWED[command] then
    return invalid(
      ("NavGraph command is not in the read-only allowlist: %s. Allowed commands: %s"):format(
        tostring(command),
        table.concat(COMMANDS, ", ")
      )
    )
  end

  local target, target_err = validate_field(input.target, "target", REQUIRED_TARGET[command] == true)
  if target_err then
    return invalid(target_err .. (REQUIRED_TARGET[command] and (" for command %s"):format(command) or ""))
  end
  if command == "search" and target:find("%s") then
    return invalid(
      "NavGraph search target must be one identifier-name pattern, not prose; use strings for literal text or grep for prose"
    )
  end

  local destination, destination_err = validate_field(input.destination, "destination", command == "path")
  if destination_err then return invalid(destination_err .. (command == "path" and " for command path" or "")) end
  if command ~= "path" and destination ~= nil then
    return invalid("NavGraph destination is only valid for the path command")
  end

  local limit = input.limit
  if
    limit ~= nil
    and (type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 or limit > MAX_RESULT_LIMIT)
  then
    return invalid(("NavGraph limit must be an integer from 1 to %d"):format(MAX_RESULT_LIMIT))
  end

  local options = {}
  for field, commands in pairs(OPTION_COMMANDS) do
    local value = input[field]
    if value == "" then value = nil end
    -- Codex frequently materializes every optional flat-schema field, including
    -- defaults belonging to another command (for example files+depth+strict).
    -- Normalize those harmless non-applicable fields away; applicable fields
    -- remain fully validated below and are the only ones emitted to argv.
    options[field] = commands[command] and value or nil
  end
  if options.depth ~= nil then
    if
      type(options.depth) ~= "number"
      or options.depth ~= math.floor(options.depth)
      or options.depth < 1
      or options.depth > MAX_DEPTH
    then
      return invalid(("NavGraph depth must be an integer from 1 to %d"):format(MAX_DEPTH))
    end
  end
  if options.kind ~= nil then
    local kind, kind_err = validate_field(options.kind, "kind", false)
    if kind_err or not kind:match("^[%w_,%-]+$") then
      return invalid(kind_err or "NavGraph kind must be a comma-separated kind list without whitespace")
    end
    options.kind = kind
  end
  if options.sort ~= nil and options.sort ~= "path" and options.sort ~= "symbols" then
    return invalid("NavGraph sort must be path or symbols")
  end
  for _, field in ipairs({ "refs", "strict", "exclude_public", "follow_imports" }) do
    if options[field] ~= nil and type(options[field]) ~= "boolean" then
      return invalid(("NavGraph %s must be boolean"):format(field))
    end
  end

  -- `navgraph read` is the one query that can open an arbitrary absolute path
  -- even when -C points at the repo. Constrain it independently, including
  -- symlinks, instead of trusting the external binary's current behavior.
  local read_spec
  if command == "read" then
    local read_err
    read_spec, read_err = parse_read_target(target)
    if not read_spec then return invalid(read_err) end
    local path = read_spec.path
    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
      return invalid("NavGraph read only accepts paths relative to the project root")
    end
    local _, path_err = util.contain(path, root, false)
    if path_err then return invalid("NavGraph read path is outside the project root: " .. path_err) end
  end

  return {
    command = command,
    target = target,
    destination = destination,
    limit = limit,
    options = options,
    read_spec = read_spec,
  }
end

local function append_note(body, note, max_bytes)
  body = tostring(body or "")
  if not note then return util.truncate_to_bytes(body, max_bytes, "\n… [NavGraph output truncated]") end
  local separator = body ~= "" and "\n" or ""
  local suffix = separator .. note
  if #suffix >= max_bytes then return util.utf8_safe_sub(note, max_bytes) end
  return util.truncate_to_bytes(body, max_bytes - #suffix, "\n… [NavGraph output truncated]") .. suffix
end

local function benign_no_match_stderr(stderr)
  if stderr == "" then return true end
  local saw_warning = false
  for line in stderr:gmatch("[^\r\n]+") do
    if not line:match("^navgraph: parse%-health: ") then return false end
    saw_warning = true
  end
  return saw_warning
end

---@param tool fun(def: table)
return function(tool)
  assert(type(tool) == "function", "navgraph tool: tool registrar required")

  tool({
    name = "navgraph",
    safe = true,
    feature = "navgraph",
    context_retention = function(input)
      if input.command == "def" or input.command == "read" then return 2 end
      return 1
    end,
    context_receipt = function(input)
      local target = type(input.target) == "string" and (" " .. util.utf8_safe_sub(input.target, 80)) or ""
      return ("[NavGraph %s%s consumed; rerun only if a narrower unresolved fact remains]"):format(
        tostring(input.command or "query"),
        target
      )
    end,
    description = "Optional semantic discovery for an unknown code location or relationship; never call it merely because available. Choose it instead of parallel LSP/grep/read/scout discovery for that question. Use one compact files/outline or identifier-name search, then def for exact source or read with explicit closed ranges. Command targets are positional facts, never language/topics, prose requests, CLI flags, or command concepts. Switch routes only after explicit no-match, ambiguity, truncation, parse-health, or non-retryable operational failure. Skip known-file and greenfield work; impact results are evidence, not an edit list.",
    input_schema = {
      type = "object",
      properties = {
        command = {
          type = "string",
          enum = COMMANDS,
          description = "Read-only NavGraph command to run",
        },
        target = {
          type = "string",
          description = "Command-specific positional: files=repository path filter only (omit target to list all; never a language/topic); outline=path; search=one identifier/name pattern; strings=literal substring from string contents; routes/events=route/event-key filter; imports/importers=repository path filter; def/calls/callers/neighbors=symbol or name@path; path=start symbol plus destination; read=path:A-B[,C-D]. Never pass prose requests, CLI flags/options, or desired command concepts. Read ranges must be closed and fit limit.",
        },
        destination = {
          type = "string",
          description = "Destination symbol for path only",
        },
        limit = {
          type = "integer",
          minimum = 1,
          maximum = MAX_RESULT_LIMIT,
          description = "Result/line bound; requests above the live configured maximum are rejected",
        },
        depth = {
          type = "integer",
          minimum = 1,
          maximum = MAX_DEPTH,
          description = "Call-tree depth for calls/callers only",
        },
        kind = {
          type = "string",
          description = "Comma-separated symbol kinds for outline/search only",
        },
        refs = {
          type = "boolean",
          description = "Include reference/use sites for calls/neighbors/search only",
        },
        strict = {
          type = "boolean",
          description = "Keep high-confidence edges only for calls/callers/neighbors/path",
        },
        sort = {
          type = "string",
          enum = { "path", "symbols" },
          description = "File ordering for files only",
        },
        exclude_public = {
          type = "boolean",
          description = "Exclude exported symbols for unused only",
        },
        follow_imports = {
          type = "boolean",
          description = "Disambiguate unused symbols through imports for unused only",
        },
      },
      required = { "command" },
      additionalProperties = false,
    },
    summary = function(input)
      local parts = { tostring((input or {}).command or "") }
      for _, field in ipairs({ "target", "destination" }) do
        if type(input) == "table" and input[field] ~= nil then parts[#parts + 1] = tostring(input[field]) end
      end
      if type(input) == "table" and input.limit then parts[#parts + 1] = "limit=" .. tostring(input.limit) end
      for _, field in ipairs({ "depth", "kind", "sort" }) do
        if type(input) == "table" and input[field] ~= nil then
          parts[#parts + 1] = field .. "=" .. tostring(input[field])
        end
      end
      for _, field in ipairs({ "refs", "strict", "exclude_public", "follow_imports" }) do
        if type(input) == "table" and input[field] == true then parts[#parts + 1] = field end
      end
      local text = table.concat(parts, " "):gsub("%s+", " ")
      return #text > 80 and (util.utf8_safe_sub(text, 77) .. "…") or text
    end,
    run = function(input, ctx, cb)
      local function finish(output, is_error, meta)
        meta = vim.tbl_extend("force", {
          tool = "navgraph",
          command = type(input) == "table" and input.command or nil,
        }, meta or {})
        return cb(output, is_error, meta)
      end
      local cfg = ((require("advantage.config").options.tools or {}).navgraph or {})
      if type(cfg) ~= "table" or cfg.enabled ~= true then
        finish("NavGraph is disabled", true, { phase = "feature_gate", spawned = false, outcome = "disabled" })
        return nil
      end

      local root, root_err = fixed_root(ctx and ctx.cwd)
      if not root then
        finish(root_err, true, { phase = "validation", spawned = false, outcome = "invalid_root" })
        return nil
      end
      local spec, call_err = validate_call(input, root)
      if not spec then
        finish(call_err, true, { phase = "validation", spawned = false, outcome = "invalid_input" })
        return nil
      end

      local executable = type(cfg.executable) == "string" and vim.trim(cfg.executable) or "navgraph"
      if executable == "" or vim.fn.executable(executable) ~= 1 then
        finish(
          ("NavGraph executable is unavailable: %s"):format(executable ~= "" and executable or "(empty)"),
          true,
          { phase = "preflight", spawned = false, outcome = "executable_unavailable" }
        )
        return nil
      end
      local timeout_ms = math.max(100, math.min(math.floor(tonumber(cfg.timeout_ms) or 30000), MAX_TIMEOUT_MS))
      local max_bytes = math.max(256, math.min(math.floor(tonumber(cfg.max_output_bytes) or 12000), MAX_OUTPUT_BYTES))
      local result_cap = math.max(1, math.min(math.floor(tonumber(cfg.max_results) or 80), MAX_RESULT_LIMIT))
      if spec.limit and spec.limit > result_cap then
        finish(
          ("NavGraph limit %d exceeds the configured maximum %d; retry at or below %d"):format(
            spec.limit,
            result_cap,
            result_cap
          ),
          true,
          { phase = "validation", spawned = false, outcome = "limit_exceeded" }
        )
        return nil
      end
      local command, options = spec.command, spec.options
      local limit = math.min(spec.limit or DEFAULT_LIMIT[command] or result_cap, result_cap)
      if spec.read_spec and (spec.read_spec.unique_lines > limit or spec.read_spec.ranges > limit) then
        finish(
          ("NavGraph read requests %d unique lines across %d ranges; narrow or split it to at most %d"):format(
            spec.read_spec.unique_lines,
            spec.read_spec.ranges,
            limit
          ),
          true,
          { phase = "validation", spawned = false, outcome = "read_range_exceeded" }
        )
        return nil
      end
      local detail = DEFAULT_DETAIL[command]

      local argv = { executable, command }
      if spec.target then argv[#argv + 1] = spec.target end
      if spec.destination then argv[#argv + 1] = spec.destination end
      if options.depth then vim.list_extend(argv, { "--depth", tostring(options.depth) }) end
      if options.kind then vim.list_extend(argv, { "--kind", options.kind }) end
      if options.refs then argv[#argv + 1] = "--refs" end
      if options.strict then argv[#argv + 1] = "--strict" end
      if options.sort then vim.list_extend(argv, { "--sort", options.sort }) end
      if options.exclude_public then argv[#argv + 1] = "--no-public" end
      if options.follow_imports then argv[#argv + 1] = "--follow-imports" end
      vim.list_extend(argv, { "--limit", tostring(limit) })
      if detail then vim.list_extend(argv, { "--verbosity", detail }) end
      -- Harness-controlled root/output arguments stay last. --no-cache is
      -- essential: ordinary NavGraph queries otherwise write `.navgraph/cache`.
      vim.list_extend(argv, { "-C", root, "--no-cache" })

      local stdout, stderr = {}, {}
      local captured = 0
      local overflow, pipe_error, cancelled, timed_out, exited, settled = false, nil, false, false, false, false
      local process
      local timer

      local function close_timer()
        if not timer then return end
        pcall(timer.stop, timer)
        if not timer:is_closing() then pcall(timer.close, timer) end
        timer = nil
      end

      local function kill()
        -- SystemObj:is_closing() was added after Neovim 0.10, which advantage
        -- still supports. kill() is safe to retry behind pcall on an exited
        -- handle, so avoid depending on the newer convenience method here.
        if process then pcall(process.kill, process, "sigkill") end
      end

      local function capture(bucket, err, data)
        if settled or overflow then return end
        if err then
          pipe_error = tostring(err)
          kill()
          return
        end
        if not data or data == "" then return end
        local remaining = max_bytes - captured
        if remaining <= 0 then
          overflow = true
          kill()
          return
        end
        if #data > remaining then
          bucket[#bucket + 1] = util.utf8_safe_sub(data, remaining)
          captured = max_bytes
          overflow = true
          kill()
          return
        end
        bucket[#bucket + 1] = data
        captured = captured + #data
      end

      local function on_exit(result)
        exited = true
        close_timer()
        vim.schedule(function()
          if settled then return end
          settled = true
          local out, err_out = table.concat(stdout), table.concat(stderr)
          local body = out
          if err_out ~= "" then body = body .. (body ~= "" and "\n" or "") .. err_out end

          local note, is_error, outcome
          if cancelled then
            note, is_error, outcome = "(NavGraph cancelled)", true, "cancelled"
          elseif overflow then
            note, is_error, outcome =
              ("(NavGraph returned a useful %d-byte partial result; narrow the target or lower the limit instead of repeating it unchanged)"):format(
                max_bytes
              ),
              false,
              "partial_success"
          elseif pipe_error then
            note, is_error, outcome = "(NavGraph output pipe failed: " .. pipe_error .. ")", true, "pipe_error"
          elseif timed_out then
            note, is_error, outcome = ("(NavGraph timed out after %d ms)"):format(timeout_ms), true, "timeout"
          elseif result.signal and result.signal ~= 0 then
            note, is_error, outcome = ("(NavGraph terminated by signal %d)"):format(result.signal), true, "signal_error"
          elseif result.code == 1 and not benign_no_match_stderr(err_out) then
            note, is_error, outcome = "(NavGraph exit code 1)", true, "operational_error"
          elseif result.code ~= 0 and result.code ~= 1 then
            note, is_error, outcome = ("(NavGraph exit code %d)"):format(result.code), true, "operational_error"
          else
            is_error, outcome = false, result.code == 1 and "no_match" or "success"
          end

          if body == "" and not note then body = result.code == 1 and "(no NavGraph matches)" or "(no output)" end
          finish(append_note(body, note, max_bytes), is_error, {
            phase = "execution",
            spawned = true,
            outcome = outcome,
            exit_code = result.code,
            signal = result.signal,
          })
        end)
      end

      local ok, spawned = pcall(vim.system, argv, {
        cwd = root,
        text = true,
        stdout = function(err, data)
          capture(stdout, err, data)
        end,
        stderr = function(err, data)
          capture(stderr, err, data)
        end,
      }, on_exit)
      if not ok then
        settled = true
        finish(
          "Failed to start NavGraph: " .. tostring(spawned),
          true,
          { phase = "spawn", spawned = false, outcome = "spawn_error" }
        )
        return nil
      end
      process = spawned
      if overflow or pipe_error then
        kill()
      elseif not exited then
        timer = assert(uv.new_timer())
        timer:start(
          timeout_ms,
          0,
          vim.schedule_wrap(function()
            if settled or exited or cancelled then return close_timer() end
            timed_out = true
            kill()
          end)
        )
      end

      return {
        stop = function()
          if settled or exited then return end
          cancelled = true
          close_timer()
          kill()
        end,
      }
    end,
  })
end
