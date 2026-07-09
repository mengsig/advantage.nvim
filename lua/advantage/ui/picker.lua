---@brief advantage-native list picker: one cohesive, colorscheme-derived float
---for every internal choice (model, effort, sessions, review targets, files),
---so no picker ever falls back to whatever `vim.ui.select` happens to be.
---
---Drop-in for the `vim.ui.select` signature. Same interaction language as the
---prompt's @file menu: type to fuzzy-filter, ⌃n/⌃p (or ⇥/⇧⇥, arrows) to move,
---⏎ to choose, esc to dismiss.
local config = require("advantage.config")
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("advantage.picker")
local MAX_VISIBLE = 12

---@param items any[] list of choices (non-empty)
---@param opts {prompt?: string, format_item?: fun(item: any): string}
---@param on_choice fun(item: any|nil, idx: integer|nil) called exactly once
function M.select(items, opts, on_choice)
  assert(type(items) == "table", "picker.select: items must be a list")
  assert(type(on_choice) == "function", "picker.select: on_choice is required")
  opts = opts or {}
  if #items == 0 then return on_choice(nil, nil) end

  local format = opts.format_item or tostring
  local pool = {} -- { text = rendered label, i = index into items }
  for i, item in ipairs(items) do
    pool[i] = { text = tostring(format(item)):gsub("[\r\n]+", " "), i = i }
  end

  local query = ""
  local view, positions = pool, {} -- filtered slice + fuzzy match positions
  local sel, top = 1, 1

  local footer = {
    { " ", "AdvFloatHint" },
    { "⏎", "AdvFloatKey" },
    { " select · ", "AdvFloatHint" },
    { "⌃n ⌃p", "AdvFloatKey" },
    { " move · ", "AdvFloatHint" },
    { "esc", "AdvFloatKey" },
    { " close · type to filter ", "AdvFloatHint" },
  }
  -- size from the unfiltered labels so the window never jumps while filtering;
  -- never narrower than the title or the footer key hints
  local width = api.nvim_strwidth(opts.prompt or "") + 6
  for _, p in ipairs(pool) do
    width = math.max(width, api.nvim_strwidth(p.text) + 6)
  end
  local footer_w = 0
  for _, chunk in ipairs(footer) do
    footer_w = footer_w + api.nvim_strwidth(chunk[1])
  end
  width = math.max(width, footer_w)
  width = math.max(30, math.min(width, math.floor(vim.o.columns * 0.7)))
  local visible = math.min(#pool, MAX_VISIBLE)
  local height = visible + 1 -- +1 for the ❯ filter line

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = config.options.ui.border,
    title = { { " " .. (opts.prompt or "select") .. " ", "AdvFloatTitle" } },
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
  })
  api.nvim_set_option_value(
    "winhighlight",
    "NormalFloat:AdvPanel,FloatBorder:AdvFloatBorder,FloatTitle:AdvFloatTitle"
      .. ",FloatFooter:AdvFloatHint,EndOfBuffer:AdvPanel,CursorLine:AdvPanel",
    { win = win }
  )
  api.nvim_set_option_value("wrap", false, { win = win })
  api.nvim_set_option_value("fillchars", "eob: ", { win = win })

  local done = false
  local function finish(item, idx)
    if done then return end
    done = true
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    on_choice(item, idx)
  end

  local function refilter()
    if query == "" then
      view, positions = pool, {}
    else
      local res = vim.fn.matchfuzzypos(pool, query, { key = "text" })
      view, positions = res[1], res[2]
    end
    sel, top = 1, 1
  end

  local function render()
    -- keep the selection inside the visible slice
    if sel < top then top = sel end
    if sel > top + visible - 1 then top = sel - visible + 1 end
    local lines = { "❯ " .. query }
    local last = math.min(#view, top + visible - 1)
    for r = top, last do
      lines[#lines + 1] = "  " .. view[r].text
    end
    if #view == 0 then lines[#lines + 1] = "  no matches" end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #"❯", hl_group = "AdvAccent" })
    api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { ("%d/%d "):format(#view, #pool), "AdvMeta" } },
      virt_text_pos = "right_align",
    })
    if #view == 0 then api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #lines[2], hl_group = "AdvToolGhost" }) end
    for r = top, last do
      local row = r - top + 1
      local line = lines[row + 1]
      if r == sel then
        api.nvim_buf_set_extmark(buf, ns, row, 0, {
          end_row = row,
          end_col = #line,
          hl_group = "AdvPickerSel",
          hl_eol = true,
          priority = 110,
        })
        api.nvim_buf_set_extmark(buf, ns, row, 0, {
          virt_text = { { "▍", "AdvPickerBar" } },
          virt_text_pos = "overlay",
          priority = 130,
        })
      end
      -- fuzzy-matched characters carry the accent
      for _, cp in ipairs(positions[r] or {}) do
        local s = vim.fn.byteidx(view[r].text, cp)
        local e = vim.fn.byteidx(view[r].text, cp + 1)
        if s and e and s >= 0 and e > s then
          api.nvim_buf_set_extmark(buf, ns, row, 2 + s, {
            end_row = row,
            end_col = 2 + e,
            hl_group = "AdvPickerMatch",
            priority = 120,
          })
        end
      end
    end
    -- park the cursor at the end of the filter line, like an input caret
    pcall(api.nvim_win_set_cursor, win, { 1, #lines[1] })
  end

  local function kmap(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end
  local function move(d)
    if #view == 0 then return end
    sel = (sel - 1 + d) % #view + 1
    render()
  end
  kmap("<CR>", function()
    local v = view[sel]
    if v then finish(items[v.i], v.i) end
  end)
  for _, lhs in ipairs({ "<Esc>", "<C-c>" }) do
    kmap(lhs, function()
      finish(nil, nil)
    end)
  end
  for _, lhs in ipairs({ "<C-n>", "<Down>", "<Tab>" }) do
    kmap(lhs, function()
      move(1)
    end)
  end
  for _, lhs in ipairs({ "<C-p>", "<Up>", "<S-Tab>" }) do
    kmap(lhs, function()
      move(-1)
    end)
  end
  kmap("<BS>", function()
    if query == "" then return end
    query = vim.fn.strcharpart(query, 0, vim.fn.strchars(query) - 1)
    refilter()
    render()
  end)
  kmap("<C-u>", function()
    query = ""
    refilter()
    render()
  end)
  -- every printable key extends the filter (so q types, esc closes)
  for c = 32, 126 do
    local ch = string.char(c)
    kmap(ch == "<" and "<lt>" or ch, function()
      query = query .. ch
      refilter()
      render()
    end)
  end

  -- leaving the float any other way counts as a dismissal
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        finish(nil, nil)
      end)
    end,
  })

  render()
end

return M
