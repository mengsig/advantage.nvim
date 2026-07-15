---@brief Review mode: inspect what the agent changed. The agent snapshots each
---file before its first write/edit; review diffs those snapshots against the
---files on disk — a unified diff float for a quick scan, or a real side-by-side
---vimdiff tab per file. Falls back to `git diff` when the agent changed nothing.
local M = {}

local api = vim.api

---Returns file content, or nil if the file is missing/unreadable (distinct from
---an empty file, so a deletion isn't mistaken for "emptied").
local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
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
    local existed = before ~= false
    local b = existed and before or ""
    local content = read_all(path)
    local deleted = content == nil and existed
    local after = content or ""
    if b ~= after or deleted then
      out[#out + 1] = {
        path = path,
        before = b,
        after = after,
        new = before == false,
        deleted = deleted,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end
M._changes = changes

local function diff_stat(item)
  local diff = require("advantage.util").text_diff(item.before, item.after, { result_type = "unified", ctxlen = 0 }) --[[@as string]]
    or ""
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
    lines[#lines + 1] = ("diff · %s%s"):format(name, item.deleted and " (deleted)" or item.new and " (new file)" or "")
    lines[#lines + 1] = "--- a/" .. name
    lines[#lines + 1] = "+++ b/" .. name
    local diff = require("advantage.util").text_diff(item.before, item.after, { result_type = "unified", ctxlen = 3 }) --[[@as string]]
      or ""
    vim.list_extend(lines, vim.split(diff, "\n", { plain = true, trimempty = true }))
  end
  return lines
end

local function scratch_buf(name, content, ft)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
  api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  if ft and ft ~= "" then vim.bo[buf].filetype = ft end
  return buf
end

---Side-by-side vimdiff in a new tab: agent's "before" (read-only scratch) on
---the left, the live file (editable) on the right. `q` in the scratch closes.
---A deleted file shows a read-only "after (deleted)" scratch instead of the live
---buffer, so saving the diff can't resurrect the file.
local function side_by_side(item)
  local ft = vim.filetype.match({ filename = item.path }) or ""
  vim.cmd("tab split")
  local file_win = api.nvim_get_current_win()
  if item.deleted then
    local after = scratch_buf("advantage://after/" .. rel(item.path), item.after, ft)
    api.nvim_win_set_buf(file_win, after)
    api.nvim_set_option_value("winbar", "%#AdvBarFaint# after (deleted — read-only) ", { win = file_win })
  else
    vim.cmd("edit " .. vim.fn.fnameescape(item.path))
    api.nvim_set_option_value("winbar", "%#AdvBarFaint# after (editable) ", { win = file_win })
  end

  local scratch = scratch_buf("advantage://before/" .. rel(item.path), item.before, ft)
  vim.cmd("leftabove vsplit")
  local before_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(before_win, scratch)
  api.nvim_set_option_value("winbar", "%#AdvBarFaint# before · q closes review ", { win = before_win })

  for _, win in ipairs({ before_win, file_win }) do
    api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
  end
  vim.keymap.set("n", "q", function()
    pcall(function()
      vim.cmd("tabclose")
    end)
  end, { buffer = scratch, silent = true, nowait = true, desc = "advantage: close review" })
  api.nvim_set_current_win(file_win)
end

local function git_fallback(ui, cwd)
  -- Async so a large repo / slow FS doesn't freeze the UI on `git diff`.
  vim.system(
    { "git", "diff" },
    { text = true, cwd = cwd },
    vim.schedule_wrap(function(res)
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
    end)
  )
end

---Entry point.
function M.open(agent)
  local ui = require("advantage.ui.chat")
  local items = changes(agent)
  if #items == 0 then return git_fallback(ui, agent.ctx.start_cwd or agent.ctx.cwd) end

  local entries = {}
  if #items > 1 then
    entries[#entries + 1] = { label = ("all changes · %d files (unified diff)"):format(#items), all = true }
  end
  for _, item in ipairs(items) do
    local add, del = diff_stat(item)
    entries[#entries + 1] = {
      label = ("%s  +%d −%d%s"):format(
        rel(item.path),
        add,
        del,
        item.deleted and " · deleted" or item.new and " · new" or ""
      ),
      item = item,
    }
  end

  require("advantage.ui.picker").select(entries, {
    prompt = "advantage · review",
    format_item = function(e)
      return e.label
    end,
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
