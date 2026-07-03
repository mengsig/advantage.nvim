---@brief The advantage panel: chat transcript + prompt, tool cards, permission
---floats. Styling derives from the active colorscheme (see ui/highlights.lua).
local util = require("advantage.util")
local config = require("advantage.config")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local ns = api.nvim_create_namespace("advantage")
local ns_extra = api.nvim_create_namespace("advantage.extra")

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ICON = "✦"

local S = {
  buf = nil,
  win = nil,
  input_buf = nil,
  input_win = nil,
  tools = {}, -- id -> {mark=, name=, detail=, status=}
  header_mark = nil, -- extmark of the current assistant header (for meta)
  meta_mark = nil,
  think_mark = nil,
  think_start = nil,
  mode = nil, -- nil | "thinking" | "text"
  last_kind = nil, -- "header" | "text" | "tool" | "user" | nil
  spinner = 1,
  timer = nil,
  status = "idle", -- idle | streaming | tool | waiting
  status_detail = nil,
  usage = { input = 0, output = 0 },
  auth_badge = nil,
  model_label = "",
  welcome_mark = nil,
  on_submit = nil,
}
M.state = S

-- helpers -----------------------------------------------------------------

local function opt(name, value, win)
  api.nvim_set_option_value(name, value, { win = win })
end

local function esc_bar(s)
  return (s or ""):gsub("%%", "%%%%")
end

local function clear_welcome()
  if S.welcome_mark and util.buf_valid(S.buf) then
    pcall(api.nvim_buf_del_extmark, S.buf, ns_extra, S.welcome_mark)
    S.welcome_mark = nil
  end
end

local function append(lines)
  if not util.buf_valid(S.buf) then return end
  clear_welcome()
  local lc = api.nvim_buf_line_count(S.buf)
  local first = api.nvim_buf_get_lines(S.buf, 0, 1, false)[1]
  if lc == 1 and (first == nil or first == "") then
    -- drop leading separators when the transcript is still empty
    while lines[1] == "" and #lines > 1 do
      table.remove(lines, 1)
    end
    api.nvim_buf_set_lines(S.buf, 0, 1, false, lines)
  else
    api.nvim_buf_set_lines(S.buf, lc, lc, false, lines)
  end
end

local function last_row()
  return api.nvim_buf_line_count(S.buf) - 1
end

local function autoscroll()
  if not util.win_valid(S.win) then return end
  local lc = api.nvim_buf_line_count(S.buf)
  local cur = api.nvim_win_get_cursor(S.win)[1]
  -- follow output unless the user has scrolled up to read
  if cur >= lc - 2 or api.nvim_get_current_win() ~= S.win then
    pcall(api.nvim_win_set_cursor, S.win, { lc, 0 })
  end
end

local function stream_chunk(text)
  if not util.buf_valid(S.buf) then return end
  local row = last_row()
  local last = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
  local lines = vim.split(text, "\n", { plain = true })
  api.nvim_buf_set_text(S.buf, row, #last, row, #last, lines)
  if S.mode == "thinking" and S.think_start then
    local erow = last_row()
    local eline = api.nvim_buf_get_lines(S.buf, erow, erow + 1, false)[1] or ""
    S.think_mark = api.nvim_buf_set_extmark(S.buf, ns, S.think_start, 0, {
      id = S.think_mark,
      end_row = erow,
      end_col = #eline,
      hl_group = "AdvThinking",
    })
  end
  autoscroll()
end

---Ensure streaming starts on a fresh empty line: directly under the message
---header, separated by a blank line everywhere else.
local function start_block()
  local row = last_row()
  local last = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
  if last == "" then return end
  if S.last_kind == "header" then
    append({ "" })
  else
    append({ "", "" })
  end
end

-- winbar / status ---------------------------------------------------------

local function winbar_text()
  local left = ("%%#AdvBarIcon# %s %%#AdvBarTitle#advantage %%#AdvBarFaint#·%%#AdvBarInfo# %s"):format(ICON, esc_bar(S.model_label))
  if S.auth_badge then
    left = left .. (" %%#AdvBarFaint#(%s)"):format(esc_bar(S.auth_badge))
  end
  local right = ""
  if S.usage.input > 0 or S.usage.output > 0 then
    right = ("%%#AdvBarInfo#↑%s ↓%s "):format(util.fmt_tokens(S.usage.input), util.fmt_tokens(S.usage.output))
  end
  if S.status == "streaming" then
    right = right .. ("%%#AdvBarBusy#%s streaming "):format(FRAMES[S.spinner])
  elseif S.status == "tool" then
    right = right .. ("%%#AdvBarBusy#%s %s "):format(FRAMES[S.spinner], esc_bar(S.status_detail or "tool"))
  elseif S.status == "waiting" then
    right = right .. ("%%#AdvBarBusy#● approve %s? "):format(esc_bar(S.status_detail or ""))
  end
  return left .. " %=" .. right
end

local function update_winbar()
  if util.win_valid(S.win) then
    opt("winbar", winbar_text(), S.win)
  end
end

local function tool_line(t)
  local icons = {
    pending = { "·", "AdvToolPending" },
    waiting = { "◇", "AdvToolRunning" },
    running = { FRAMES[S.spinner], "AdvToolRunning" },
    ok = { "●", "AdvToolOk" },
    error = { "✗", "AdvToolErr" },
    denied = { "◌", "AdvToolDenied" },
  }
  local icon = icons[t.status or "pending"] or icons.pending
  local text = ("  %s %s"):format(icon[1], t.name or "?")
  if t.detail and t.detail ~= "" then
    text = text .. "  " .. t.detail
  end
  return text, icon[2]
end

local function redraw_tool(id)
  local t = S.tools[id]
  if not t or not util.buf_valid(S.buf) then return end
  local pos = api.nvim_buf_get_extmark_by_id(S.buf, ns, t.mark, {})
  if not pos or #pos == 0 then return end
  local row = pos[1]
  local old = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
  local text, hl = tool_line(t)
  api.nvim_buf_set_text(S.buf, row, 0, row, #old, { text })
  -- restore the row anchor and style the line
  t.mark = api.nvim_buf_set_extmark(S.buf, ns, row, 0, { id = t.mark, right_gravity = false })
  t.hl_mark = api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
    id = t.hl_mark,
    end_row = row,
    end_col = #text,
    hl_group = hl,
    priority = 150,
  })
  -- bold tool name over the base color
  local prefix = text:match("^  [^%s]+ ")
  if prefix and t.name then
    t.name_mark = api.nvim_buf_set_extmark(S.buf, ns, row, #prefix, {
      id = t.name_mark,
      end_row = row,
      end_col = #prefix + #t.name,
      hl_group = "AdvToolName",
      priority = 160,
    })
  end
end

local function spinner_tick()
  S.spinner = S.spinner % #FRAMES + 1
  update_winbar()
  for id, t in pairs(S.tools) do
    if t.status == "running" then
      redraw_tool(id)
    end
  end
end

local function ensure_timer()
  if S.timer then return end
  S.timer = uv.new_timer()
  S.timer:start(0, 110, vim.schedule_wrap(function()
    if S.status == "idle" then
      if S.timer then
        S.timer:stop()
        S.timer:close()
        S.timer = nil
      end
      update_winbar()
      return
    end
    spinner_tick()
  end))
end

-- welcome -----------------------------------------------------------------

local function show_welcome()
  if not util.buf_valid(S.buf) then return end
  local lc = api.nvim_buf_line_count(S.buf)
  local first = api.nvim_buf_get_lines(S.buf, 0, 1, false)[1]
  if lc > 1 or (first and first ~= "") then return end
  local hints = {
    { "", "" },
    { "   " .. ICON .. " advantage", "AdvWelcome" },
    { "", "" },
    { "   model    " .. S.model_label, "AdvWelcomeDim" },
    { "   send     ⏎        newline  ⇧⏎ / ⌃j", "AdvWelcomeDim" },
    { "   cancel   ⌃c       models   :Advantage model", "AdvWelcomeDim" },
    { "   hide     q        help     g?", "AdvWelcomeDim" },
  }
  local virt = {}
  for _, h in ipairs(hints) do
    virt[#virt + 1] = { { h[1], h[2] } }
  end
  S.welcome_mark = api.nvim_buf_set_extmark(S.buf, ns_extra, 0, 0, { virt_lines = virt })
end

-- buffers / windows ---------------------------------------------------------

local function input_placeholder()
  if not util.buf_valid(S.input_buf) then return end
  api.nvim_buf_clear_namespace(S.input_buf, ns_extra, 0, -1)
  local lines = api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    api.nvim_buf_set_extmark(S.input_buf, ns_extra, 0, 0, {
      virt_text = { { "describe a task, or ask about the code…", "AdvWelcomeDim" } },
      virt_text_pos = "overlay",
    })
  end
end

local function focus_input(insert)
  if util.win_valid(S.input_win) then
    api.nvim_set_current_win(S.input_win)
    if insert then vim.cmd.startinsert({ bang = true }) end
  end
end

local function focus_chat()
  if util.win_valid(S.win) then
    api.nvim_set_current_win(S.win)
  end
end

local function submit()
  local lines = api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then return end
  api.nvim_buf_set_lines(S.input_buf, 0, -1, false, {})
  input_placeholder()
  if S.on_submit then S.on_submit(text) end
end

local function help_lines()
  return {
    "chat window",
    "  q        hide panel        ⌃c   cancel turn",
    "  i a o    jump to prompt    ⇥    jump to prompt",
    "  ]]  [[   next/prev turn    g?   this help",
    "",
    "prompt window",
    "  ⏎        send              ⇧⏎ ⌃j newline",
    "  ⇥        jump to chat      q    hide panel",
    "",
    "commands",
    "  :Advantage            toggle panel",
    "  :Advantage new        fresh session",
    "  :Advantage model      switch model",
    "  :Advantage resume     resume a session",
    "  :Advantage ask {q}    one-shot prompt",
  }
end

local function show_help()
  M.float({ title = "advantage · keys", lines = help_lines(), filetype = "" })
end

local function jump_turn(dir)
  if not util.win_valid(S.win) then return end
  local row = api.nvim_win_get_cursor(S.win)[1]
  local lines = api.nvim_buf_get_lines(S.buf, 0, -1, false)
  local target
  if dir > 0 then
    for i = row + 1, #lines do
      if lines[i]:sub(1, #"▍") == "▍" then target = i break end
    end
  else
    for i = row - 1, 1, -1 do
      if lines[i]:sub(1, #"▍") == "▍" then target = i break end
    end
  end
  if target then
    api.nvim_win_set_cursor(S.win, { target, 0 })
  end
end

local function ensure_bufs()
  if util.buf_valid(S.buf) then return end

  S.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(S.buf, "advantage://chat")
  vim.bo[S.buf].buftype = "nofile"
  vim.bo[S.buf].bufhidden = "hide"
  vim.bo[S.buf].swapfile = false
  vim.bo[S.buf].filetype = "advantage"
  if not pcall(vim.treesitter.start, S.buf, "markdown") then
    vim.bo[S.buf].syntax = "markdown"
  end

  S.input_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(S.input_buf, "advantage://prompt")
  vim.bo[S.input_buf].buftype = "nofile"
  vim.bo[S.input_buf].bufhidden = "hide"
  vim.bo[S.input_buf].swapfile = false
  vim.bo[S.input_buf].filetype = "advantage_prompt"

  local function map(buf, mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "advantage: " .. desc })
  end

  -- chat maps
  map(S.buf, "n", "q", function() M.close() end, "hide panel")
  map(S.buf, "n", "<Tab>", function() focus_input(false) end, "focus prompt")
  for _, key in ipairs({ "i", "a", "o", "I", "A", "O" }) do
    map(S.buf, "n", key, function() focus_input(true) end, "focus prompt (insert)")
  end
  map(S.buf, "n", "<C-c>", function() require("advantage").stop() end, "cancel")
  map(S.buf, "n", "g?", show_help, "help")
  map(S.buf, "n", "]]", function() jump_turn(1) end, "next turn")
  map(S.buf, "n", "[[", function() jump_turn(-1) end, "previous turn")

  -- prompt maps
  map(S.input_buf, "i", "<CR>", function() submit() end, "send")
  map(S.input_buf, "n", "<CR>", function() submit() end, "send")
  map(S.input_buf, "i", "<S-CR>", "<CR>", "newline")
  map(S.input_buf, "i", "<C-j>", "<CR>", "newline")
  map(S.input_buf, "n", "<Tab>", focus_chat, "focus chat")
  map(S.input_buf, "n", "q", function() M.close() end, "hide panel")
  map(S.input_buf, "n", "<C-c>", function() require("advantage").stop() end, "cancel")
  map(S.input_buf, "i", "<C-c>", function()
    vim.cmd.stopinsert()
    require("advantage").stop()
  end, "cancel")

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = S.input_buf,
    callback = input_placeholder,
  })
end

function M.is_open()
  return util.win_valid(S.win)
end

function M.open(focus)
  ensure_bufs()
  if M.is_open() then
    if focus ~= false then focus_input(true) end
    return
  end
  local cfg = config.options.ui
  local width = math.max(46, math.floor(vim.o.columns * cfg.width))

  S.win = api.nvim_open_win(S.buf, false, { split = "right", win = -1, width = width })
  opt("number", false, S.win)
  opt("relativenumber", false, S.win)
  opt("signcolumn", "no", S.win)
  opt("foldcolumn", "0", S.win)
  opt("cursorline", false, S.win)
  opt("wrap", true, S.win)
  opt("linebreak", true, S.win)
  opt("breakindent", true, S.win)
  opt("conceallevel", 2, S.win)
  opt("concealcursor", "nc", S.win)
  opt("winfixwidth", true, S.win)
  opt("fillchars", "eob: ", S.win)
  opt("statuscolumn", "", S.win)

  S.input_win = api.nvim_open_win(S.input_buf, false, {
    split = "below",
    win = S.win,
    height = cfg.input_height,
  })
  opt("number", false, S.input_win)
  opt("relativenumber", false, S.input_win)
  opt("signcolumn", "no", S.input_win)
  opt("winfixheight", true, S.input_win)
  opt("wrap", true, S.input_win)
  opt("fillchars", "eob: ", S.input_win)
  opt("winbar", "%#AdvBarFaint# ❯ prompt %=%#AdvBarFaint#⏎ send · g? keys ", S.input_win)

  update_winbar()
  show_welcome()
  input_placeholder()
  if focus ~= false then focus_input(true) end
end

function M.close()
  for _, win in ipairs({ S.input_win, S.win }) do
    if util.win_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  S.win, S.input_win = nil, nil
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

function M.clear()
  ensure_bufs()
  api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(S.buf, ns_extra, 0, -1)
  api.nvim_buf_set_lines(S.buf, 0, -1, false, {})
  S.tools = {}
  S.header_mark, S.meta_mark = nil, nil
  S.think_mark, S.think_start = nil, nil
  S.mode, S.last_kind = nil, nil
  S.usage = { input = 0, output = 0 }
  S.welcome_mark = nil
  show_welcome()
  update_winbar()
end

-- transcript rendering ------------------------------------------------------

function M.user_message(text)
  ensure_bufs()
  S.mode, S.last_kind = nil, "user"
  local head = "▍ you"
  append({ "", head })
  local row = last_row()
  api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
    end_row = row,
    end_col = #head,
    hl_group = "AdvUserHead",
    hl_eol = true,
    priority = 120,
  })
  api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
    end_row = row,
    end_col = #"▍",
    hl_group = "AdvUserBar",
    priority = 130,
  })
  api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
    virt_text = { { os.date("%H:%M") .. " ", "AdvMeta" } },
    virt_text_pos = "right_align",
  })
  append(vim.split(text, "\n", { plain = true }))
  autoscroll()
end

function M.begin_assistant(label)
  ensure_bufs()
  S.model_label = label or S.model_label
  S.mode, S.last_kind = nil, "header"
  S.think_mark, S.think_start = nil, nil
  local head = "▍ " .. ICON .. " " .. (label or "assistant")
  append({ "", head })
  local row = last_row()
  api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
    end_row = row,
    end_col = #head,
    hl_group = "AdvAssistHead",
    priority = 120,
  })
  S.header_mark = api.nvim_buf_set_extmark(S.buf, ns, row, 0, { right_gravity = false })
  S.meta_mark = nil
  ensure_timer()
  autoscroll()
end

function M.stream_text(chunk)
  if not util.buf_valid(S.buf) then return end
  if S.mode ~= "text" then
    start_block()
    S.mode = "text"
    S.last_kind = "text"
  end
  stream_chunk(chunk)
end

function M.stream_thinking(chunk)
  if not util.buf_valid(S.buf) then return end
  if S.mode ~= "thinking" then
    start_block()
    S.mode = "thinking"
    S.last_kind = "text"
    S.think_start = last_row()
    S.think_mark = nil
  end
  stream_chunk(chunk)
end

function M.tool_begin(id, name)
  if not util.buf_valid(S.buf) then return end
  S.mode = nil
  local line
  if S.last_kind == "tool" then
    line = { "x" }
  else
    line = { "", "x" }
  end
  append(line)
  S.last_kind = "tool"
  local row = last_row()
  local t = { name = name, status = "pending" }
  t.mark = api.nvim_buf_set_extmark(S.buf, ns, row, 0, { right_gravity = false })
  S.tools[id] = t
  redraw_tool(id)
  autoscroll()
end

---@param patch {status?: string, detail?: string, name?: string}
function M.tool_update(id, patch)
  local t = S.tools[id]
  if not t then return end
  t.status = patch.status or t.status
  t.detail = patch.detail or t.detail
  t.name = patch.name or t.name
  redraw_tool(id)
  autoscroll()
end

---Right-aligned meta on the current turn's header; overwritten as the turn
---progresses so it always shows the cumulative turn cost.
function M.message_meta(usage, elapsed_ns)
  if not (S.header_mark and util.buf_valid(S.buf)) then return end
  local pos = api.nvim_buf_get_extmark_by_id(S.buf, ns, S.header_mark, {})
  if not pos or #pos == 0 then return end
  local parts = {}
  if usage and (usage.input > 0 or usage.output > 0) then
    parts[#parts + 1] = ("↑%s ↓%s"):format(util.fmt_tokens(usage.input), util.fmt_tokens(usage.output))
  end
  if elapsed_ns then
    parts[#parts + 1] = util.fmt_elapsed(elapsed_ns)
  end
  if #parts == 0 then return end
  S.meta_mark = api.nvim_buf_set_extmark(S.buf, ns, pos[1], 0, {
    id = S.meta_mark,
    virt_text = { { table.concat(parts, " · ") .. " ", "AdvMeta" } },
    virt_text_pos = "right_align",
  })
end

function M.notice(text)
  ensure_bufs()
  S.mode = nil
  append({ "", "  ▸ " .. text })
  S.last_kind = "text"
  local row = last_row()
  api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
    end_row = row,
    end_col = #("  ▸ " .. text),
    hl_group = "AdvNotice",
  })
  autoscroll()
end

function M.finish_turn()
  S.mode = nil
end

function M.set_status(status, detail)
  S.status = status
  S.status_detail = detail
  if status ~= "idle" then ensure_timer() end
  update_winbar()
end

function M.set_usage(usage)
  S.usage = usage
  update_winbar()
end

function M.set_auth(badge)
  if S.auth_badge ~= badge then
    S.auth_badge = badge
    update_winbar()
  end
end

function M.set_model_label(label)
  S.model_label = label
  update_winbar()
  if util.buf_valid(S.buf) and api.nvim_buf_line_count(S.buf) == 1 then
    -- refresh welcome hint
    clear_welcome()
    show_welcome()
  end
end

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "advantage" })
end

-- floats --------------------------------------------------------------------

---Generic informational float (help, previews).
function M.float(opts)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype and opts.filetype ~= "" then
    vim.bo[buf].filetype = opts.filetype
  end
  local width = 20
  for _, l in ipairs(opts.lines) do
    width = math.max(width, api.nvim_strwidth(l) + 2)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.8))
  local height = math.min(#opts.lines, math.floor(vim.o.lines * 0.7))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = config.options.ui.border,
    title = { { " " .. (opts.title or "advantage") .. " ", "AdvFloatTitle" } },
    title_pos = "center",
    footer = opts.footer and { { " " .. opts.footer .. " ", "AdvFloatHint" } } or nil,
    footer_pos = opts.footer and "center" or nil,
  })
  opt("wrap", false, win)
  opt("cursorline", false, win)
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if util.win_valid(win) then api.nvim_win_close(win, true) end
    end, { buffer = buf, silent = true })
  end
  return win, buf
end

---Permission card. cb("allow"|"always"|"deny"), exactly once.
function M.confirm(preview, cb)
  local done = false
  local function decide(what)
    if done then return end
    done = true
    cb(what)
  end
  local win, buf = M.float({
    title = preview.title or "allow?",
    lines = preview.lines or {},
    filetype = preview.filetype,
    footer = "a allow · A always · d deny",
  })
  local maps = {
    a = "allow",
    y = "allow",
    A = "always",
    d = "deny",
    n = "deny",
  }
  for key, decision in pairs(maps) do
    vim.keymap.set("n", key, function()
      if util.win_valid(win) then api.nvim_win_close(win, true) end
      decide(decision)
    end, { buffer = buf, silent = true, nowait = true })
  end
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function() decide("deny") end)
    end,
  })
end

-- resume ----------------------------------------------------------------------

---Re-render a saved conversation (best effort: text + tool cards).
function M.render_transcript(messages, model_label)
  M.clear()
  S.model_label = model_label or S.model_label
  for mi, msg in ipairs(messages) do
    if msg.role == "user" then
      for _, block in ipairs(msg.content) do
        if block.type == "text" then
          M.user_message(block.text)
        end
      end
    else
      local printed_header = false
      for _, block in ipairs(msg.content) do
        if block.type == "text" then
          if not printed_header then
            M.begin_assistant(S.model_label)
            printed_header = true
          end
          M.stream_text(block.text)
        elseif block.type == "tool_use" then
          if not printed_header then
            M.begin_assistant(S.model_label)
            printed_header = true
          end
          -- look ahead for the result to color the card
          local status = "ok"
          local nxt = messages[mi + 1]
          if nxt and nxt.role == "user" then
            for _, r in ipairs(nxt.content) do
              if r.type == "tool_result" and r.tool_use_id == block.id and r.is_error then
                status = "error"
              end
            end
          end
          local def = require("advantage.tools").get(block.name)
          M.tool_begin(block.id, block.name)
          M.tool_update(block.id, {
            status = status,
            detail = def and def.summary and def.summary(block.input) or nil,
          })
        end
      end
    end
  end
  S.mode = nil
  M.set_status("idle")
end

return M
