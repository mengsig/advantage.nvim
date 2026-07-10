---@brief Session persistence: one JSON file per conversation under stdpath("data").
local M = {}

local uv = vim.uv or vim.loop

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
  cwd = vim.fs.normalize(cwd or uv.cwd() or "")
  local git = cwd ~= "" and vim.fs.find(".git", { path = cwd, upward = true })[1] or nil
  local root = git and vim.fs.dirname(git) or cwd
  return uv.fs_realpath(root) or root
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
    usage = agent.usage,
    cwd = cwd,
    updated_at = os.time(),
  }
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then return nil, encoded end
  -- Transcripts can hold source and secrets: the temporary is exclusive and
  -- private from creation, and only a complete fsynced payload replaces the
  -- prior autosave.
  local saved, err = write_private_atomic(path, encoded)
  if not saved then return nil, err end
  -- One-time migration for pre-hardening filenames. Only construct/remove the
  -- legacy path when the id itself was a single safe component.
  local raw_id = tostring(agent.id or "")
  if raw_id:match("^[%w._-]+$") and raw_id ~= "." and raw_id ~= ".." then
    local legacy = ("%s/%s-%s.json"):format(sessions_dir, key, raw_id)
    if legacy ~= path then os.remove(legacy) end
  end
  return true
end

---@param cwd? string project/subdirectory whose sessions should be listed
function M.list(cwd)
  local out, by_id = {}, {}
  local prefix = project_key(cwd)
  local sessions_dir = dir()
  for name, t in vim.fs.dir(sessions_dir) do
    -- Require the .json suffix so a crash-leftover "<id>.json.tmp" (atomic-write
    -- temp) is never decoded as a duplicate/partial session in the resume picker.
    if t == "file" and vim.startswith(name, prefix .. "-") and name:sub(-5) == ".json" then
      local f = io.open(sessions_dir .. "/" .. name, "r")
      if f then
        local ok, data = pcall(vim.json.decode, f:read("*a"))
        f:close()
        if ok and type(data) == "table" and data.messages then
          local identity = tostring(data.id or name)
          local existing = by_id[identity]
          if not existing or (data.updated_at or 0) > (existing.updated_at or 0) then by_id[identity] = data end
        end
      end
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
  local sessions = M.list(cwd)
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
    M.pick_checkpoint(choice, cb)
  end)
end

return M
