---@brief Session persistence: one JSON file per conversation under stdpath("data").
local M = {}

local uv = vim.uv or vim.loop
local META_MAX_BYTES = 64 * 1024

local function max_file_bytes()
  local sessions = ((require("advantage.config").options or {}).sessions or {})
  local value = tonumber(sessions.max_file_bytes) or (128 * 1024 * 1024)
  return math.max(64 * 1024, math.min(1024 * 1024 * 1024, math.floor(value)))
end

local function write_private_atomic(path, content)
  local tmp, fd, err
  for attempt = 1, 8 do
    tmp = ("%s.adv.%d.%x.tmp"):format(path, vim.fn.getpid(), (uv.hrtime() + attempt) % 0x7fffffff)
    fd, err = uv.fs_open(tmp, "wx", 384) -- 0600; never follow a planted temp symlink
    if fd then break end
  end
  if not fd then return nil, err end
  -- open(2)'s mode is umask-filtered. Force the intended private mode while the
  -- inode is still reachable only through our exclusive randomized temp name.
  local chmod_ok, chmod_err = uv.fs_chmod(tmp, 384)
  if not chmod_ok then
    uv.fs_close(fd)
    os.remove(tmp)
    return nil, chmod_err or "could not secure session temporary"
  end
  local offset = 0
  while offset < #content do
    local wrote
    wrote, err = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not wrote or wrote <= 0 then break end
    offset = offset + wrote
  end
  local synced, sync_err = uv.fs_fsync(fd)
  uv.fs_close(fd)
  if offset ~= #content or not synced then
    os.remove(tmp)
    return nil, err or sync_err or "write failed"
  end
  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return nil, rename_err or "rename failed"
  end
  return true
end

local function dir()
  local d = M._dir_override or (vim.fn.stdpath("data") .. "/advantage/sessions")
  vim.fn.mkdir(d, "p", "0700")
  -- mkdir -p does not repair permissions on an existing directory. Session
  -- transcripts can contain source and secrets, so tighten old installs too.
  pcall(uv.fs_chmod, d, 448) -- 0700
  return d
end

---Sessions are scoped per project so `resume` only offers relevant ones.
local function project_root(cwd)
  return require("advantage.util").project_root(cwd)
end

local function project_key(cwd)
  return vim.fn.sha256(project_root(cwd)):sub(1, 12)
end
M._project_key = project_key

---Opaque filename component for a persisted conversation id. The raw id comes
---from resumable JSON and must never become a path segment (`../../...`), while a
---hash remains deterministic so every autosave replaces the same session file.
local function filename_token(id)
  return vim.fn.sha256(tostring(id or "")):sub(1, 32)
end
M._filename_token = filename_token

local id_counter = 0
---Generate a process-safe conversation id without depending on Lua's global RNG
---seed. `Agent.new` can use this for new sessions; resumed ids remain stable.
function M.new_id()
  id_counter = id_counter + 1
  local digest = vim.fn.sha256(
    table.concat(
      { tostring(vim.fn.getpid()), tostring(uv.hrtime()), tostring(id_counter), tostring(uv.cwd() or "") },
      ":"
    )
  )
  return ("%s-%s-%s-%s-%s"):format(
    digest:sub(1, 8),
    digest:sub(9, 12),
    digest:sub(13, 16),
    digest:sub(17, 20),
    digest:sub(21, 32)
  )
end

function M.save(agent)
  local cwd = (agent.ctx and agent.ctx.cwd) or (vim.uv or vim.loop).cwd()
  local sessions_dir = dir()
  local key = project_key(cwd)
  local path = ("%s/%s-%s.json"):format(sessions_dir, key, filename_token(agent.id))
  local payload = {
    v = 1,
    id = agent.id,
    title = agent.title,
    model = agent.model,
    harness_mode = agent.harness_mode,
    messages = agent.messages,
    -- Normally finish/save has already aged semantic payloads to receipts. If
    -- an interrupted Claude tool continuation must remain byte-identical, keep
    -- the small out-of-band retention ledger too so aging resumes after reload
    -- instead of replaying that full result forever.
    context_results = require("advantage.tools").snapshot_context_results(agent.messages),
    usage = agent.usage,
    cwd = cwd,
    start_cwd = agent.ctx and agent.ctx.start_cwd or cwd,
    updated_at = os.time(),
  }
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then return nil, encoded end
  local cap = max_file_bytes()
  if #encoded > cap then
    return nil,
      ("session is %d bytes, above sessions.max_file_bytes=%d; compact it or raise the explicit safety ceiling"):format(
        #encoded,
        cap
      )
  end
  -- Transcripts can hold source and secrets: the temporary is exclusive and
  -- private from creation, and only a complete fsynced payload replaces the
  -- prior autosave.
  local saved, err = write_private_atomic(path, encoded)
  if not saved then return nil, err end

  -- The resume picker needs only these fields. Keeping them in a small private
  -- sidecar avoids decoding and retaining every source/image-heavy transcript
  -- merely to render a title list; the selected session is loaded afterward.
  local transcript_stat = uv.fs_stat(path)
  if not transcript_stat then return nil, "could not stat saved session" end
  local metadata = {
    v = 1,
    id = payload.id,
    title = payload.title,
    model = payload.model,
    harness_mode = payload.harness_mode,
    cwd = payload.cwd,
    updated_at = payload.updated_at,
    message_count = #(payload.messages or {}),
    session_file = vim.fs.basename(path),
    session_size = transcript_stat.size,
    session_mtime = transcript_stat.mtime,
  }
  local meta_ok, meta_encoded = pcall(vim.json.encode, metadata)
  if not meta_ok then
    os.remove(path .. ".meta")
    return nil, meta_encoded
  end
  local meta_saved, meta_err = write_private_atomic(path .. ".meta", meta_encoded)
  if not meta_saved then
    -- Never let an older sidecar describe a newer transcript. Without a
    -- sidecar the picker safely falls back to reducing the main JSON once.
    os.remove(path .. ".meta")
    return nil, meta_err
  end
  -- One-time migration for pre-hardening filenames. Only construct/remove the
  -- legacy path when the id itself was a single safe component.
  local raw_id = tostring(agent.id or "")
  if raw_id:match("^[%w._-]+$") and raw_id ~= "." and raw_id ~= ".." then
    local legacy = ("%s/%s-%s.json"):format(sessions_dir, key, raw_id)
    if legacy ~= path then
      os.remove(legacy)
      os.remove(legacy .. ".meta")
    end
  end
  return true
end

local function read_json_file(path, cap)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil, "not a regular file" end
  cap = math.max(1, math.floor(tonumber(cap) or max_file_bytes()))
  if (stat.size or 0) > cap then return nil, ("file exceeds %d-byte safety ceiling"):format(cap) end
  local f = io.open(path, "r")
  if not f then return nil, "could not open file" end
  local body = f:read(cap + 1) or ""
  f:close()
  if #body > cap then return nil, ("file exceeds %d-byte safety ceiling"):format(cap) end
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then return nil, "invalid session JSON" end
  return data
end

local function main_session_names(cwd)
  local out = {}
  local prefix = project_key(cwd)
  local sessions_dir = dir()
  for name, t in vim.fs.dir(sessions_dir) do
    -- Require the .json suffix so crash-leftover .tmp files and metadata
    -- sidecars never enter the transcript decoder.
    if t == "file" and vim.startswith(name, prefix .. "-") and name:sub(-5) == ".json" then out[#out + 1] = name end
  end
  return sessions_dir, out
end

local function metadata_matches(meta, name, stat)
  if type(meta) ~= "table" or meta.session_file ~= name or type(stat) ~= "table" then return false end
  local saved_mtime = meta.session_mtime
  local current_mtime = stat.mtime
  return meta.session_size == stat.size
    and type(saved_mtime) == "table"
    and type(current_mtime) == "table"
    and saved_mtime.sec == current_mtime.sec
    and saved_mtime.nsec == current_mtime.nsec
end

local function scan(cwd, metadata_only)
  local out, by_id = {}, {}
  local sessions_dir, names = main_session_names(cwd)
  for _, name in ipairs(names) do
    local path = sessions_dir .. "/" .. name
    local stat = uv.fs_stat(path)
    local data
    if stat and (stat.size or 0) <= max_file_bytes() then
      if metadata_only then
        local meta = read_json_file(path .. ".meta", META_MAX_BYTES)
        if metadata_matches(meta, name, stat) then
          data = meta
        else
          -- Backward compatibility for sessions saved before sidecars existed.
          local legacy = read_json_file(path, max_file_bytes())
          if legacy and type(legacy.messages) == "table" then
            data = {
              v = legacy.v,
              id = legacy.id,
              title = legacy.title,
              model = legacy.model,
              harness_mode = legacy.harness_mode,
              cwd = legacy.cwd,
              updated_at = legacy.updated_at,
              message_count = #legacy.messages,
              session_file = name,
            }
          end
        end
      else
        data = read_json_file(path, max_file_bytes())
      end
    end
    if data and (metadata_only or type(data.messages) == "table") then
      data._session_file = name
      data._project_cwd = cwd or uv.cwd()
      if metadata_only then
        if type(data.title) ~= "string" then
          data.title = nil
        else
          data.title = data.title:gsub("%s+", " ")
          if #data.title > 200 then data.title = require("advantage.util").utf8_safe_sub(data.title, 199) .. "…" end
        end
        if type(data.updated_at) ~= "number" then data.updated_at = 0 end
        if type(data.message_count) ~= "number" or data.message_count < 0 then data.message_count = 0 end
      end
      local identity = tostring(data.id or name)
      local existing = by_id[identity]
      if not existing or (data.updated_at or 0) > (existing.updated_at or 0) then by_id[identity] = data end
    end
  end
  for _, data in pairs(by_id) do
    out[#out + 1] = data
  end
  table.sort(out, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  return out
end

---@param cwd? string project/subdirectory whose sessions should be listed
function M.list(cwd)
  return scan(cwd, false)
end

local function valid_messages(messages)
  local is_list = vim.islist or vim.tbl_islist
  if type(messages) ~= "table" or not is_list(messages) then return false end
  for _, message in ipairs(messages) do
    if
      type(message) ~= "table"
      or (message.role ~= "user" and message.role ~= "assistant")
      or type(message.content) ~= "table"
      or not is_list(message.content)
    then
      return false
    end
    for _, block in ipairs(message.content) do
      if type(block) ~= "table" or type(block.type) ~= "string" then return false end
    end
  end
  return true
end

---Lightweight resume rows. New-format sessions read only their bounded metadata
---sidecars; legacy sessions are decoded one at a time and immediately reduced.
function M.list_metadata(cwd)
  return scan(cwd, true)
end

---Load the one transcript selected from list_metadata().
function M.load(summary)
  local name = type(summary) == "table" and summary._session_file or nil
  if type(name) ~= "string" or name:find("/", 1, true) or name:sub(-5) ~= ".json" then
    return nil, "invalid session selection"
  end
  local data, err = read_json_file(dir() .. "/" .. name, max_file_bytes())
  if not data or not valid_messages(data.messages) then return nil, err or "invalid session transcript structure" end

  -- The filename was discovered under the selected project's hash. A persisted
  -- cwd is convenient nested-scope metadata, never authority to escape that
  -- project after local JSON tampering.
  local expected = project_root(type(summary) == "table" and summary._project_cwd or nil)
  if type(data.cwd) ~= "string" or project_root(data.cwd) ~= expected then
    return nil, "saved session workspace does not match the selected project"
  end
  local util = require("advantage.util")
  local start_cwd = type(data.start_cwd) == "string" and util.contain(data.start_cwd, expected, false) or nil
  data.cwd = expected
  data.start_cwd = start_cwd or expected
  if type(data.model) ~= "table" or type(data.model.provider) ~= "string" or type(data.model.id) ~= "string" then
    data.model = nil
  end
  if type(data.usage) ~= "table" then data.usage = nil end
  if type(data.title) ~= "string" then data.title = nil end
  if type(data.id) ~= "string" then data.id = nil end
  return data
end

local function one_line(text, max)
  local s = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  max = max or 56
  if #s > max then s = require("advantage.util").utf8_safe_sub(s, max - 1) .. "…" end
  return s
end

---Genuine user turns in a transcript: messages that carry a typed `text` block,
---not the `tool_result`-only messages the agent loop injects. Each is a point the
---conversation can be rewound to for a retry.
---@return {index:integer, preview:string, text:string}[]
local function checkpoints(messages)
  local out = {}
  for i, msg in ipairs(messages or {}) do
    if msg.role == "user" and type(msg.content) == "table" then
      local text = msg.original_text
      for _, block in ipairs(msg.content) do
        if not text and type(block) == "table" and block.type == "text" and block.text and block.text ~= "" then
          text = block.text
          break
        end
      end
      if text then out[#out + 1] = { index = i, preview = one_line(text), text = text } end
    end
  end
  return out
end

---A forked copy of `data` whose transcript is truncated to just before the given
---checkpoint. `id`/`usage` are dropped so the fork saves to a NEW file — the
---original conversation is never overwritten when you rewind and continue.
local function rewound(data, cp)
  local msgs = {}
  for i = 1, cp.index - 1 do
    msgs[i] = data.messages[i]
  end
  return {
    id = nil,
    title = data.title,
    model = data.model,
    harness_mode = data.harness_mode,
    messages = msgs,
    usage = nil,
    cwd = data.cwd,
  }
end

---Second-stage picker: resume `data` at its latest point, or rewind to an earlier
---user turn to retry from there (as a fork).
---@param cb fun(data: table|nil, prefill?: string)
function M.pick_checkpoint(data, cb)
  local cps = checkpoints(data.messages)
  -- With one turn or fewer there is nothing meaningful to rewind past.
  if #cps <= 1 then return cb(data) end

  local items = { { kind = "recent" } }
  for i = #cps, 1, -1 do
    items[#items + 1] = { kind = "rewind", cp = cps[i], n = i }
  end
  require("advantage.ui.picker").select(items, {
    prompt = "advantage · resume — pick a point (rewind forks a copy)",
    format_item = function(item)
      if item.kind == "recent" then return ("▸ most recent  ·  %d messages"):format(#(data.messages or {})) end
      return ("↶ retry from #%d  ·  %s"):format(item.n, item.cp.preview)
    end,
  }, function(item)
    if not item then return cb(nil) end
    if item.kind == "recent" then return cb(data) end
    cb(rewound(data, item.cp), item.cp.text)
  end)
end

---@param cb fun(data: table|nil, prefill?: string)
---@param cwd? string frozen agent/project cwd used for session scoping
function M.pick(cb, cwd)
  local sessions = M.list_metadata(cwd)
  if #sessions == 0 then
    require("advantage.ui.chat").notify("no saved sessions for this project", vim.log.levels.INFO)
    return cb(nil)
  end
  require("advantage.ui.picker").select(sessions, {
    prompt = "advantage · resume",
    format_item = function(item)
      local age = os.time() - (item.updated_at or 0)
      local when = age < 3600 and math.floor(age / 60) .. "m ago"
        or age < 86400 and math.floor(age / 3600) .. "h ago"
        or math.floor(age / 86400) .. "d ago"
      return ("%s  ·  %s"):format(item.title or "(untitled)", when)
    end,
  }, function(choice)
    if not choice then return cb(nil) end
    local data, err = M.load(choice)
    if not data then
      require("advantage.ui.chat").notify("could not load session: " .. tostring(err), vim.log.levels.WARN)
      return cb(nil)
    end
    M.pick_checkpoint(data, cb)
  end)
end

return M
