---@brief NavGraph executable identity and capability negotiation.
---
---The NavGraph CLI is an external trust boundary.  Advantage therefore learns
---its contract once per stable executable identity, validates the protocol, and
---freezes only the intersection with Advantage's own read-only policy.  A
---single historical benchmark binary predates the capability command; it is
---accepted by exact SHA-256 only, never by guessing from an unknown-command
---error.
local M = {}

local uv = vim.uv or vim.loop

local CAPABILITY_SCHEMA = "navgraph.capabilities.v1"
local CAPABILITY_SCHEMA_VERSION = 1
local AGENT_PROTOCOL_VERSION = "1.0"
local MAX_MANIFEST_BYTES = 1024 * 1024
local LEGACY_BENCHMARK_SHA256 = "b28d540549e64ac778f7f245ec3baffb4c26516f304c449d53cf3055651f05c6"
local CACHE_EFFECTS = { none = true, may_read_write = true }

-- Fixed order is deliberate: provider schemas must not change merely because a
-- producer reorders its manifest.  This is also the maximum policy surface;
-- live capabilities may remove entries but can never add arbitrary commands.
local POLICY_COMMANDS = {
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

local EXPECTED_ARGUMENTS = {
  outline = 1,
  def = 1,
  calls = 1,
  callers = 1,
  search = 1,
  routes = 1,
  events = 1,
  neighbors = 1,
  unused = 1,
  imports = 1,
  importers = 1,
  path = 2,
  hot = 1,
  files = 1,
  read = 1,
  strings = 1,
}

local LEGACY_OPTIONS = {
  outline = { limit = true, verbosity = true, kind = true },
  def = { limit = true, verbosity = true },
  calls = { limit = true, verbosity = true, depth = true, refs = true, strict = true },
  callers = { limit = true, verbosity = true, depth = true, strict = true },
  search = { limit = true, verbosity = true, kind = true, refs = true },
  routes = { limit = true, verbosity = true },
  events = { limit = true },
  neighbors = { limit = true, verbosity = true, refs = true, strict = true },
  unused = { limit = true, verbosity = true, no_public = true, follow_imports = true },
  imports = { limit = true },
  importers = { limit = true },
  path = { limit = true, verbosity = true, strict = true },
  hot = { limit = true, verbosity = true },
  files = { limit = true, sort = true },
  read = { limit = true },
  strings = { limit = true },
}

local probe_cache = {}
local notified = {}

local function mtime_part(stat, field)
  return type(stat.mtime) == "table" and tonumber(stat.mtime[field]) or 0
end

local function resolve_executable(executable)
  if type(executable) ~= "string" or vim.trim(executable) == "" then
    return nil, "the configured executable is empty"
  end
  local path = executable
  if not executable:find("[/\\]") then path = vim.fn.exepath(executable) end
  if type(path) ~= "string" or path == "" then
    return nil, ("executable %q was not found on PATH"):format(executable)
  end
  path = uv.fs_realpath(path) or vim.fs.normalize(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil, ("executable is not a file: %s"):format(path) end
  if vim.fn.executable(path) ~= 1 then return nil, ("file is not executable: %s"):format(path) end
  return path, stat
end

local function executable_identity(path, stat)
  return table.concat({
    path,
    tostring(stat.dev or ""),
    tostring(stat.ino or ""),
    tostring(stat.size or ""),
    tostring(mtime_part(stat, "sec")),
    tostring(mtime_part(stat, "nsec")),
  }, "\0")
end

local function sha256_file(path, stat)
  -- Stream through the platform digest utility instead of allocating the whole
  -- executable. This is also required on Neovim 0.10, whose Vimscript sha256()
  -- raises E976 for binary strings containing NUL.
  local commands = {
    { bin = "sha256sum", argv = { "sha256sum", "--", path } },
    { bin = "shasum", argv = { "shasum", "-a", "256", path } },
    { bin = "openssl", argv = { "openssl", "dgst", "-sha256", path } },
  }
  for _, command in ipairs(commands) do
    if vim.fn.executable(command.bin) == 1 then
      local ok, result = pcall(function()
        return vim.system(command.argv, { text = true }):wait(10000)
      end)
      if ok and result and result.code == 0 then
        for digest in (result.stdout or ""):gmatch("[0-9a-fA-F]+") do
          if #digest == 64 then return digest:lower() end
        end
      end
    end
  end

  -- Last-resort compatibility for text-only executable scripts on minimal
  -- systems. Guard binary failure and keep the optional legacy profile closed.
  local fd, open_err = uv.fs_open(path, "r", 438)
  if not fd then return nil, tostring(open_err or "open failed") end
  local bytes, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not bytes then return nil, tostring(read_err or "read failed") end
  local ok, digest = pcall(vim.fn.sha256, bytes)
  return ok and digest or nil, ok and nil or tostring(digest)
end

local function command_option_set(command)
  local out = {}
  for _, name in ipairs(type(command.options) == "table" and command.options or {}) do
    if type(name) == "string" then out[name] = true end
  end
  return out
end

local function has_text_output(command)
  for _, mode in ipairs(type(command.outputModes) == "table" and command.outputModes or {}) do
    if mode == "text" then return true end
  end
  return false
end

local function validate_manifest(manifest)
  if type(manifest) ~= "table" then return nil, "capabilities output is not a JSON object" end
  if manifest.schema ~= CAPABILITY_SCHEMA or manifest.schemaVersion ~= CAPABILITY_SCHEMA_VERSION then
    return nil,
      ("unsupported capability schema %s version %s (requires %s version %d)"):format(
        tostring(manifest.schema),
        tostring(manifest.schemaVersion),
        CAPABILITY_SCHEMA,
        CAPABILITY_SCHEMA_VERSION
      )
  end
  if manifest.agentProtocolVersion ~= AGENT_PROTOCOL_VERSION then
    return nil,
      ("unsupported agent protocol %s (requires %s)"):format(
        tostring(manifest.agentProtocolVersion),
        AGENT_PROTOCOL_VERSION
      )
  end
  if type(manifest.build) ~= "table" or type(manifest.build.buildId) ~= "string" or manifest.build.buildId == "" then
    return nil, "capabilities is missing build.buildId"
  end
  if type(manifest.schemaHash) ~= "string" or manifest.schemaHash == "" then
    return nil, "capabilities is missing schemaHash"
  end
  if type(manifest.commands) ~= "table" or type(manifest.languages) ~= "table" then
    return nil, "capabilities must contain command and language arrays"
  end

  local commands = {}
  for _, command in ipairs(manifest.commands) do
    if
      type(command) ~= "table"
      or type(command.name) ~= "string"
      or type(command.access) ~= "string"
      or type(command.arguments) ~= "table"
      or type(command.options) ~= "table"
      or type(command.outputModes) ~= "table"
      or type(command.requiresIndex) ~= "boolean"
      or not CACHE_EFFECTS[command.cacheEffect]
    then
      return nil, "capabilities contains a malformed command descriptor"
    end
    if commands[command.name] then return nil, "capabilities contains duplicate command " .. command.name end
    commands[command.name] = command
  end

  local languages, language_names = {}, {}
  for _, language in ipairs(manifest.languages) do
    if type(language) ~= "table" or type(language.name) ~= "string" or language.name == "" then
      return nil, "capabilities contains a malformed language descriptor"
    end
    if not languages[language.name] then
      languages[language.name] = true
      language_names[#language_names + 1] = language.name
    end
  end
  table.sort(language_names)

  local allowed, ordered, options, cache_policy = {}, {}, {}, {}
  for _, name in ipairs(POLICY_COMMANDS) do
    local command = commands[name]
    local expected = EXPECTED_ARGUMENTS[name]
    if command and command.access == "read_only" and has_text_output(command) and #command.arguments == expected then
      local live = command_option_set(command)
      local intrinsically_cacheless = command.requiresIndex == false and command.cacheEffect == "none"
      -- Indexed commands, and any command that may touch the on-disk cache,
      -- must accept the harness-owned cache bypass. A no-index/cacheEffect=none
      -- command has no cache side effect to suppress, so requiring an option it
      -- deliberately does not expose would incorrectly hide safe commands such
      -- as the hardened source reader.
      local cache_boundary_safe = intrinsically_cacheless or live.no_cache
      if live.root and cache_boundary_safe and (name ~= "read" or live.limit) then
        allowed[name] = true
        ordered[#ordered + 1] = name
        options[name] = live
        cache_policy[name] = {
          requires_index = command.requiresIndex,
          cache_effect = command.cacheEffect,
          intrinsically_cacheless = intrinsically_cacheless,
          -- Never emit a flag absent from the negotiated command contract.
          inject_no_cache = live.no_cache == true,
        }
      end
    end
  end
  if #ordered == 0 then return nil, "no Advantage-approved read-only commands remain after capability intersection" end

  return {
    compatible = true,
    mode = "negotiated",
    schema = manifest.schema,
    schema_version = manifest.schemaVersion,
    schema_hash = manifest.schemaHash,
    agent_protocol_version = manifest.agentProtocolVersion,
    build = vim.deepcopy(manifest.build),
    server = type(manifest.server) == "table" and vim.deepcopy(manifest.server) or {},
    typed_query_available = type(manifest.server) == "table"
      and manifest.server.queryTool == "navgraph.query"
      and type(manifest.server.querySchema) == "string"
      and type(manifest.server.resultSchema) == "string",
    -- Handshake support does not imply transport adoption. Advantage still
    -- executes its conservative one-shot CLI adapter in this tranche.
    adapter_transport = "cli",
    commands = ordered,
    allowed = allowed,
    options = options,
    cache_policy = cache_policy,
    languages = language_names,
    language_set = languages,
  }
end

local function legacy_profile()
  local allowed, options, cache_policy = {}, {}, {}
  for _, name in ipairs(POLICY_COMMANDS) do
    allowed[name] = true
    options[name] = vim.deepcopy(LEGACY_OPTIONS[name] or {})
    -- This immutable binary predates capability metadata, but its exact frozen
    -- contract is known to support --no-cache on every policy command.
    cache_policy[name] = {
      requires_index = true,
      cache_effect = "may_read_write",
      intrinsically_cacheless = false,
      inject_no_cache = true,
    }
  end
  return {
    compatible = true,
    mode = "legacy_benchmark",
    schema = "advantage.navgraph.legacy-benchmark.v1",
    schema_version = 1,
    schema_hash = "sha256:" .. LEGACY_BENCHMARK_SHA256,
    agent_protocol_version = "legacy",
    build = {
      product = "navgraph",
      buildId = "navgraph-benchmark@84986b8568b63925c9a4392d12661d7c17d1474b",
    },
    server = {},
    typed_query_available = false,
    literal_positionals = false,
    adapter_transport = "cli",
    commands = vim.deepcopy(POLICY_COMMANDS),
    allowed = allowed,
    options = options,
    cache_policy = cache_policy,
    languages = {},
    language_set = {},
  }
end

local function accepted_legacy_sha256()
  -- Test-only override keeps the production allowlist a single immutable hash
  -- while allowing the smoke suite to exercise the old-command path without
  -- checking a 1 MiB historical executable into this repository.
  return M._test_legacy_sha256 or LEGACY_BENCHMARK_SHA256
end

local function run_capability_probe(path, literal_terminator, timeout_ms)
  local argv = { path, "capabilities", "-j" }
  if literal_terminator then argv[#argv + 1] = "--" end
  local ok, result = pcall(function()
    return vim.system(argv, { text = true }):wait(timeout_ms)
  end)
  if not ok then return nil, tostring(result) end
  return result, nil
end

local function probe(path, stat, timeout_ms)
  local identity = executable_identity(path, stat)
  if probe_cache[identity] then return probe_cache[identity] end

  -- A leading-dash positional is ambiguous in an argv CLI unless the producer
  -- supports the conventional `--` terminator. Negotiate that parser feature
  -- without indexing a repository: current NavGraph accepts a trailing `--` on
  -- its metadata-only capabilities command. Older capability-aware builds fall
  -- back to the ordinary handshake and remain usable, but do not gain literal
  -- flag-shaped targets by assumption.
  local result, spawn_err = run_capability_probe(path, true, timeout_ms)
  local literal_positionals = result ~= nil and result.code == 0
  local fallback_attempted = false
  -- Fall back only when a process completed normally and rejected the probe.
  -- A timeout, signal, or spawn race cannot be repaired by immediately blocking
  -- Neovim on the same executable a second time.
  if result ~= nil and result.code ~= 0 and result.code ~= 124 and (result.signal == nil or result.signal == 0) then
    fallback_attempted = true
    result, spawn_err = run_capability_probe(path, false, timeout_ms)
  end
  local stdout = tostring(result and result.stdout or "")
  local item = { identity = identity, executable = path }
  if result == nil then
    item.error = "capabilities command could not start: " .. tostring(spawn_err or "unknown spawn failure")
  elseif result.code == 0 and #stdout <= MAX_MANIFEST_BYTES then
    local ok, manifest = pcall(vim.json.decode, stdout)
    if ok then
      local profile, err = validate_manifest(manifest)
      item.profile, item.error = profile, err
      if profile then profile.literal_positionals = literal_positionals end
    else
      item.error = "capabilities returned malformed JSON"
    end
  elseif result.code == 0 then
    item.error = ("capabilities exceeded the %d-byte handshake limit"):format(MAX_MANIFEST_BYTES)
  else
    local digest, digest_err = sha256_file(path, stat)
    item.sha256 = digest
    if
      fallback_attempted
      and result.code ~= 124
      and (result.signal == nil or result.signal == 0)
      and digest == accepted_legacy_sha256()
    then
      item.profile = legacy_profile()
    else
      local stderr = vim.trim(tostring(result.stderr or "")):gsub("[\r\n]+", " ")
      item.error = ("capabilities command failed with exit %s%s%s"):format(
        tostring(result.code),
        stderr ~= "" and ": " or "",
        stderr ~= "" and stderr or (digest_err and ("; SHA-256 failed: " .. digest_err) or "")
      )
    end
  end
  if item.profile then
    item.profile.identity = identity
    item.profile.executable = path
  end
  probe_cache[identity] = item
  return item
end

local function diagnostic(item)
  return ("Advantage disabled NavGraph at %s: %s. Rebuild/install a NavGraph that emits %s with agent protocol %s via `navgraph capabilities -j`%s."):format(
    item.executable,
    item.error or "incompatible capability contract",
    CAPABILITY_SCHEMA,
    AGENT_PROTOCOL_VERSION,
    " (the frozen 84986b8 benchmark binary remains supported by exact SHA-256)"
  )
end

---Return a defensive copy of the frozen safe profile for the configured binary.
---The external handshake runs at most once for an unchanged executable identity.
function M.profile(config)
  config = type(config) == "table" and config or {}
  local path, stat_or_err = resolve_executable(config.executable or "navgraph")
  if not path then return nil, stat_or_err, nil end
  -- Metadata is local and tiny. Keep first-use schema construction responsive
  -- even if a configured executable is wedged; semantic queries retain their
  -- independently configured, much larger timeout.
  local timeout_ms = math.max(100, math.min(math.floor(tonumber(config.timeout_ms) or 30000), 1000))
  local item = probe(path, stat_or_err, timeout_ms)
  if item.profile and (item.profile.mode ~= "legacy_benchmark" or config.allow_legacy_benchmark == true) then
    return vim.deepcopy(item.profile), nil, item.identity
  end
  local reason = item.profile and "the legacy benchmark compatibility profile is disabled by configuration"
    or item.error
  local failed = vim.tbl_extend("force", {}, item, { error = reason })
  local message = diagnostic(failed)
  if not notified[item.identity] then
    notified[item.identity] = true
    vim.schedule(function()
      vim.notify(message, vim.log.levels.ERROR, { title = "Advantage NavGraph" })
    end)
  end
  return nil, message, item.identity
end

function M.supports(profile, command, option)
  if type(profile) ~= "table" or not (profile.allowed or {})[command] then return false end
  if option == nil then return true end
  return ((profile.options or {})[command] or {})[option] == true
end

---Whether the frozen command contract requires and supports the harness-owned
---cache bypass flag. Negotiated profiles derive this only from live metadata;
---the exact-hash legacy profile records its known historical behavior.
function M.injects_no_cache(profile, command)
  if type(profile) ~= "table" or not (profile.allowed or {})[command] then return false end
  return ((profile.cache_policy or {})[command] or {}).inject_no_cache == true
end

function M._reset_cache()
  probe_cache = {}
  notified = {}
end

M.policy_commands = POLICY_COMMANDS
M.legacy_benchmark_sha256 = LEGACY_BENCHMARK_SHA256
M.capability_schema = CAPABILITY_SCHEMA
M.agent_protocol_version = AGENT_PROTOCOL_VERSION

return M
