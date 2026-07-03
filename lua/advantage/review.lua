---@brief Review mode: inspect what the agent changed. The agent snapshots each
---file before its first write/edit; review diffs those snapshots against the
---files on disk — a unified diff float for a quick scan, or a real side-by-side
---vimdiff tab per file. Falls back to `git diff` when the agent changed nothing.
local M = {}

local api = vim.api

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local content = f:read("*a")
  f:close()
  return content
end

local function rel(path)
  return vim.fn.fnamemodify(path, ":.")
end

---Collect the agent's changes as {path, before, after, new} entries.
local function changes(agent)
  local out = {}
  for path, before in pairs(agent and agent.snapshots or {}) do
    local b = before == false and "" or before
    local after = read_all(path)
    if b ~= after then
      out[#out + 1] = { path = path, before = b, after = after, new = before == false }
    end
  end
  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end
M._changes = changes

local function diff_stat(item)
  local diff = vim.diff(item.before, item.after, { result_type = "unified", ctxlen = 0 }) or ""
  local add, del = 0, 0
  for line in diff:gmatch("[^\n]+") do
    local c = line:sub(1, 1)
    if c == "+" and line:sub(1, 3) ~= "+++" then add = add + 1 end
    if c == "-" and line:sub(1, 3) ~= "---" then del = del + 1 end
  end
  return add, del
end

local function unified_lines(items)
  local lines = {}
  for _, item in ipairs(items) do
    local name = rel(item.path)
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = ("diff · %s%s"):format(name, item.new and " (new file)" or "")
    lines[#lines + 1] = "--- a/" .. name
    lines[#lines + 1] = "+++ b/" .. name
    local diff = vim.diff(item.before, item.after, { result_type = "unified", ctxlen = 3 }) or ""
    vim.list_extend(lines, vim.split(diff, "\n", { plain = true, trimempty = true }))
  end
  return lines
end

---Side-by-side vimdiff in a new tab: agent's "before" (read-only scratch) on
---the left, the live file (editable) on the right. `q` in the scratch closes.
local function side_by_side(item)
  vim.cmd("tab split")
  vim.cmd("edit " .. vim.fn.fnameescape(item.path))
  local file_win = api.nvim_get_current_win()

  local scratch = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(scratch, 0, -1, false, vim.split(item.before, "\n", { plain = true }))
  api.nvim_buf_set_name(scratch, "advantage://before/" .. rel(item.path))
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].modifiable = false
  local ft = vim.filetype.match({ filename = item.path }) or ""
  if ft ~= "" then vim.bo[scratch].filetype = ft end

  vim.cmd("leftabove vsplit")
  local before_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(before_win, scratch)
  api.nvim_set_option_value("winbar", "%#AdvBarFaint# before · q closes review ", { win = before_win })
  api.nvim_set_option_value("winbar", "%#AdvBarFaint# after (editable) ", { win = file_win })

  for _, win in ipairs({ before_win, file_win }) do
    api.nvim_win_call(win, function() vim.cmd("diffthis") end)
  end
  vim.keymap.set("n", "q", function()
    pcall(vim.cmd, "tabclose")
  end, { buffer = scratch, silent = true, nowait = true, desc = "advantage: close review" })
  api.nvim_set_current_win(file_win)
end

local function git_fallback(ui)
  local res = vim.system({ "git", "diff" }, { text = true }):wait(4000)
  if not res or res.code ~= 0 or vim.trim(res.stdout or "") == "" then
    ui.notify("no agent changes to review (and no git diff)", vim.log.levels.INFO)
    return
  end
  ui.float({
    title = "review · git diff",
    lines = vim.split(res.stdout, "\n", { plain = true, trimempty = true }),
    filetype = "diff",
    footer = "q close",
  })
end

---Entry point.
function M.open(agent)
  local ui = require("advantage.ui.chat")
  local items = changes(agent)
  if #items == 0 then
    return git_fallback(ui)
  end

  local entries = {}
  if #items > 1 then
    entries[#entries + 1] = { label = ("all changes · %d files (unified diff)"):format(#items), all = true }
  end
  for _, item in ipairs(items) do
    local add, del = diff_stat(item)
    entries[#entries + 1] = {
      label = ("%s  +%d −%d%s"):format(rel(item.path), add, del, item.new and " · new" or ""),
      item = item,
    }
  end

  vim.ui.select(entries, {
    prompt = "review agent changes",
    format_item = function(e) return e.label end,
  }, function(choice)
    if not choice then return end
    if choice.all then
      ui.float({
        title = ("review · %d files"):format(#items),
        lines = unified_lines(items),
        filetype = "diff",
        footer = "q close",
      })
    else
      side_by_side(choice.item)
    end
  end)
end

return M
