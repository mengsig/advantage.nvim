---@brief Session persistence: one JSON file per conversation under stdpath("data").
local M = {}

local function dir()
  local d = vim.fn.stdpath("data") .. "/advantage/sessions"
  vim.fn.mkdir(d, "p", "0700")
  return d
end

---Sessions are scoped per project so `resume` only offers relevant ones.
local function project_key()
  return vim.fn.sha256((vim.uv or vim.loop).cwd()):sub(1, 12)
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

---@param cb fun(data: table|nil)
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
    cb(choice)
  end)
end

return M
