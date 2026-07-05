---@brief Session persistence: one JSON file per conversation under stdpath("data").
local M = {}

local function dir()
  local d = vim.fn.stdpath("data") .. "/advantage/sessions"
  vim.fn.mkdir(d, "p", "0700")
  return d
end

---Sessions are scoped per project so `resume` only offers relevant ones.
local function project_key()
  return vim.fn.sha256((vim.uv or vim.loop).cwd() or ""):sub(1, 12)
end

function M.save(agent)
  local path = ("%s/%s-%s.json"):format(dir(), project_key(), agent.id)
  local payload = {
    v = 1,
    id = agent.id,
    title = agent.title,
    model = agent.model,
    messages = agent.messages,
    usage = agent.usage,
    cwd = (vim.uv or vim.loop).cwd(),
    updated_at = os.time(),
  }
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then return end
  -- Autosave overwrites the same file every turn; write to a temp file and
  -- atomically rename so a crash mid-write can't corrupt the only copy.
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(encoded)
  f:close()
  pcall((vim.uv or vim.loop).fs_chmod, tmp, 384) -- 0600: transcripts can hold secrets
  if not os.rename(tmp, path) then os.remove(tmp) end
end

function M.list()
  local out = {}
  local prefix = project_key()
  for name, t in vim.fs.dir(dir()) do
    -- Require the .json suffix so a crash-leftover "<id>.json.tmp" (atomic-write
    -- temp) is never decoded as a duplicate/partial session in the resume picker.
    if t == "file" and vim.startswith(name, prefix) and name:sub(-5) == ".json" then
      local f = io.open(dir() .. "/" .. name, "r")
      if f then
        local ok, data = pcall(vim.json.decode, f:read("*a"))
        f:close()
        if ok and type(data) == "table" and data.messages then out[#out + 1] = data end
      end
    end
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
      local text
      for _, block in ipairs(msg.content) do
        if type(block) == "table" and block.type == "text" and block.text and block.text ~= "" then
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
  vim.ui.select(items, {
    prompt = "resume — pick a point (rewind forks a copy)",
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
function M.pick(cb)
  local sessions = M.list()
  if #sessions == 0 then
    require("advantage.ui.chat").notify("no saved sessions for this project", vim.log.levels.INFO)
    return cb(nil)
  end
  vim.ui.select(sessions, {
    prompt = "resume session",
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
