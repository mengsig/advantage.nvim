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
  status = "idle", -- idle | streaming | tool | waiting | compacting
  status_detail = nil,
  compact = nil, -- { t0 = ms, est = ms, done = bool } while compacting
  usage = { input = 0, output = 0 },
  auth_badge = nil,
  model_label = "",
  welcome_mark = nil,
  on_submit = nil,
  attachments = {}, -- pending prompt images: {name=, path=, media_type=, data=}
  follow = true, -- stick to the bottom of the transcript
  queue_count = 0, -- messages waiting for the current agent flow to finish
}
M.state = S

-- helpers -----------------------------------------------------------------

local function opt(name, value, win)
  api.nvim_set_option_value(name, value, { win = win })
end

local function esc_bar(s)
  return tostring(s or ""):gsub("[\r\n]+", " "):gsub("%%", "%%%%")
end

local function split_lines(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(text, "\n", { plain = true })
end

local function normalize_lines(lines)
  if type(lines) ~= "table" then lines = { lines } end
  local out = {}
  for _, line in ipairs(lines or {}) do
    vim.list_extend(out, split_lines(line))
  end
  return out
end

local function one_line(text)
  return tostring(text or ""):gsub("[\r\n]+", " ")
end

---The transcript is read-only for the user; all internal writes go through here.
local function buf_write(fn)
  if not util.buf_valid(S.buf) then return end
  vim.bo[S.buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[S.buf].modifiable = false
  if not ok then error(err, 0) end
end

local function clear_welcome()
  if S.welcome_mark and util.buf_valid(S.buf) then
    pcall(api.nvim_buf_del_extmark, S.buf, ns_extra, S.welcome_mark)
    S.welcome_mark = nil
  end
end

local function append(lines)
  if not util.buf_valid(S.buf) then return end
  lines = normalize_lines(lines)
  clear_welcome()
  buf_write(function()
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
  end)
end

local function last_row()
  return api.nvim_buf_line_count(S.buf) - 1
end

---Follow the stream only while the user is at (or near) the bottom. `S.follow`
---is maintained from CursorMoved in the chat window, so scrolling up anywhere
---(even while a response streams, or from the prompt) stops the auto-jump.
local function autoscroll()
  if not util.win_valid(S.win) then return end
  if not S.follow then return end
  local lc = api.nvim_buf_line_count(S.buf)
  pcall(api.nvim_win_set_cursor, S.win, { lc, 0 })
end

local function stream_chunk(text)
  if not util.buf_valid(S.buf) then return end
  local row = last_row()
  local last = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
  local lines = vim.split(text, "\n", { plain = true })
  buf_write(function()
    api.nvim_buf_set_text(S.buf, row, #last, row, #last, lines)
  end)
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
  local left = ("%%#AdvBarIcon# %s %%#AdvBarTitle#advantage %%#AdvBarFaint#·%%#AdvBarInfo# %s"):format(
    ICON,
    esc_bar(S.model_label)
  )
  if S.auth_badge then left = left .. (" %%#AdvBarFaint#(%s)"):format(esc_bar(S.auth_badge)) end
  if config.options.tools.yolo then left = left .. " %#AdvBarDanger#⚡ yolo" end
  local right = ""
  if S.queue_count > 0 then right = ("%%#AdvBarInfo#⧗ %d queued "):format(S.queue_count) end
  if S.usage.input > 0 or S.usage.output > 0 then
    right = right
      .. ("%%#AdvBarInfo#↑%s ↓%s "):format(util.fmt_tokens(S.usage.input), util.fmt_tokens(S.usage.output))
  end
  if S.status == "streaming" then
    right = right .. ("%%#AdvBarBusy#%s streaming "):format(FRAMES[S.spinner])
  elseif S.status == "tool" then
    right = right .. ("%%#AdvBarBusy#%s %s "):format(FRAMES[S.spinner], esc_bar(S.status_detail or "tool"))
  elseif S.status == "waiting" then
    right = right .. ("%%#AdvBarBusy#● approve %s? "):format(esc_bar(S.status_detail or ""))
  elseif S.status == "compacting" then
    local c = S.compact or {}
    local frac = 0
    if c.t0 and c.est and c.est > 0 then frac = math.min(0.95, (uv.now() - c.t0) / c.est) end
    if c.done then frac = 1 end
    local width = 12
    local filled = math.floor(frac * width + 0.5)
    local bar = string.rep("█", filled) .. string.rep("░", width - filled)
    right = right .. ("%%#AdvBarBusy#compacting %s %d%%%% "):format(bar, math.floor(frac * 100 + 0.5))
  end
  return left .. " %=" .. right
end

local function update_winbar()
  if util.win_valid(S.win) then opt("winbar", winbar_text(), S.win) end
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
  local text = ("  %s %s"):format(icon[1], one_line(t.name or "?"))
  if t.detail and t.detail ~= "" then text = text .. "  " .. one_line(t.detail) end
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
  buf_write(function()
    api.nvim_buf_set_text(S.buf, row, 0, row, #old, { text })
  end)
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
    if t.status == "running" then redraw_tool(id) end
  end
end

local function stop_timer()
  if S.timer then
    S.timer:stop()
    S.timer:close()
    S.timer = nil
  end
end

local function ensure_timer()
  if S.timer then return end
  -- Don't arm the spinner into a hidden/closed panel: it would redraw tool lines
  -- and the winbar into an invisible buffer every 110ms until idle. M.open
  -- re-arms it (`if S.status ~= "idle" then ensure_timer()`) when the panel returns.
  if not util.win_valid(S.win) then return end
  S.timer = uv.new_timer()
  S.timer:start(
    0,
    110,
    vim.schedule_wrap(function()
      -- Stop once the turn is idle or the panel was closed mid-run.
      if S.status == "idle" or not util.win_valid(S.win) then
        stop_timer()
        update_winbar()
        return
      end
      spinner_tick()
    end)
  )
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
    { "   files    @path    image    ⌃v (paste)", "AdvWelcomeDim" },
    { "   usage    /usage   review   /review", "AdvWelcomeDim" },
    { "   cancel   ⌃c       help     g?", "AdvWelcomeDim" },
  }
  local virt = {}
  for _, h in ipairs(hints) do
    virt[#virt + 1] = { { h[1], h[2] } }
  end
  -- reuse the extmark id so repeated opens never stack duplicate banners
  S.welcome_mark = api.nvim_buf_set_extmark(S.buf, ns_extra, 0, 0, {
    id = S.welcome_mark,
    virt_lines = virt,
  })
end

-- buffers / windows ---------------------------------------------------------

local function input_placeholder()
  if not util.buf_valid(S.input_buf) then return end
  api.nvim_buf_clear_namespace(S.input_buf, ns_extra, 0, -1)
  local lines = api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    api.nvim_buf_set_extmark(S.input_buf, ns_extra, 0, 0, {
      virt_text = { { "describe a task…  (@ file · ⌃v image · / commands)", "AdvWelcomeDim" } },
      virt_text_pos = "overlay",
    })
  end
end

local function input_winbar_text()
  local left = "%#AdvBarFaint# ❯ prompt"
  if #S.attachments > 0 then
    left = left .. ("%%#AdvBarInfo# · %d image%s"):format(#S.attachments, #S.attachments == 1 and "" or "s")
  end
  return left .. " %=%#AdvBarFaint#⏎ send · g? keys "
end

local function update_input_winbar()
  if util.win_valid(S.input_win) then opt("winbar", input_winbar_text(), S.input_win) end
end

---Grow/shrink the prompt window with its content (wrapped display lines).
local function resize_input()
  if not (util.win_valid(S.input_win) and util.buf_valid(S.input_buf)) then return end
  local width = math.max(1, api.nvim_win_get_width(S.input_win))
  local h = 0
  for _, l in ipairs(api.nvim_buf_get_lines(S.input_buf, 0, -1, false)) do
    h = h + math.max(1, math.ceil(api.nvim_strwidth(l) / width))
  end
  local min_h = config.options.ui.input_height
  local max_h = math.max(min_h, math.floor(vim.o.lines * 0.4))
  h = math.min(math.max(h + 1, min_h), max_h) -- +1 for the winbar
  if api.nvim_win_get_height(S.input_win) ~= h then api.nvim_win_set_height(S.input_win, h) end
end

---Scroll the transcript without leaving the prompt.
local function scroll_chat(keys)
  if not util.win_valid(S.win) then return end
  api.nvim_win_call(S.win, function()
    pcall(function()
      vim.cmd("normal! " .. api.nvim_replace_termcodes(keys, true, false, true))
    end)
    local lc = api.nvim_buf_line_count(S.buf)
    S.follow = api.nvim_win_get_cursor(S.win)[1] >= lc - 2
  end)
end

local function focus_input(insert)
  if util.win_valid(S.input_win) then
    api.nvim_set_current_win(S.input_win)
    if insert then vim.cmd.startinsert({ bang = true }) end
  end
end

local function focus_chat()
  if util.win_valid(S.win) then api.nvim_set_current_win(S.win) end
end

local function chip_for(item)
  return ("[image: %s]"):format(item.name)
end

---Attach an image to the next message and drop a visible, deletable chip
---into the prompt text.
function M.attach_image(item)
  M.open(false)
  S.attachments[#S.attachments + 1] = item
  local chip = chip_for(item) .. " "
  if api.nvim_get_current_win() == S.input_win and vim.fn.mode():find("i") then
    api.nvim_paste(chip, false, -1)
  else
    local lines = api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
    local last = lines[#lines] or ""
    lines[#lines] = last == "" and chip or (last .. " " .. chip)
    api.nvim_buf_set_lines(S.input_buf, 0, -1, false, lines)
  end
  input_placeholder()
  update_input_winbar()
  resize_input()
  M.notify("attached " .. item.name .. " — delete its [image: …] chip to remove it")
end

---Append an @file mention to the prompt and focus it.
function M.add_mention(path)
  M.open(false)
  local lines = api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
  local last = lines[#lines] or ""
  local chip = "@" .. path .. " "
  lines[#lines] = last == "" and chip or (last .. " " .. chip)
  api.nvim_buf_set_lines(S.input_buf, 0, -1, false, lines)
  input_placeholder()
  resize_input()
  if util.win_valid(S.input_win) then
    api.nvim_set_current_win(S.input_win)
    api.nvim_win_set_cursor(S.input_win, { #lines, math.max(#lines[#lines] - 1, 0) })
    vim.cmd.startinsert({ bang = true })
  end
end

---Replace the prompt buffer with `text` and focus it in insert mode. Used by
---resume-rewind to preload the turn you chose to retry.
function M.set_prompt(text)
  M.open(false)
  if not util.buf_valid(S.input_buf) then return end
  local lines = vim.split(text or "", "\n", { plain = true })
  api.nvim_buf_set_lines(S.input_buf, 0, -1, false, lines)
  input_placeholder()
  update_input_winbar()
  resize_input()
  if util.win_valid(S.input_win) then
    api.nvim_set_current_win(S.input_win)
    local last = lines[#lines] or ""
    api.nvim_win_set_cursor(S.input_win, { #lines, #last })
    vim.cmd.startinsert({ bang = true })
  end
end

---⌃v in the prompt: clipboard image if there is one, plain text paste otherwise.
local function smart_paste()
  local attach = require("advantage.attach")
  local img, why = attach.clipboard_image()
  if img then return M.attach_image(img) end
  local text = vim.fn.getreg("+")
  if text == nil or text == "" then text = vim.fn.getreg('"') end
  if text and text ~= "" then
    api.nvim_paste(text, false, -1)
  else
    M.notify(why or "clipboard is empty", vim.log.levels.WARN)
  end
end

---Slash commands typed into the prompt (`/usage`, `/new`, …).
local SLASH = {
  usage = function()
    require("advantage").usage()
  end,
  compact = function(arg)
    require("advantage").compact(arg)
  end,
  context = function(arg)
    require("advantage").context(arg)
  end,
  memory = function(arg)
    require("advantage").context(arg)
  end,
  new = function()
    require("advantage").new_session()
  end,
  clear = function()
    require("advantage").new_session()
  end,
  model = function()
    require("advantage").pick_model()
  end,
  models = function()
    require("advantage").pick_model()
  end,
  resume = function()
    require("advantage").resume()
  end,
  review = function()
    require("advantage").review()
  end,
  diff = function()
    require("advantage").review()
  end,
  yolo = function()
    require("advantage").toggle_yolo()
  end,
  effort = function(arg)
    if arg and arg ~= "" then
      require("advantage").set_effort(arg)
    else
      require("advantage").pick_effort()
    end
  end,
  help = function()
    M.show_help()
  end,
  keys = function()
    M.show_help()
  end,
}

local function submit(mode)
  mode = mode or "instant"
  local lines = api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then return end

  local function clear_input()
    api.nvim_buf_set_lines(S.input_buf, 0, -1, false, {})
    input_placeholder()
    update_input_winbar()
    resize_input()
  end

  -- slash commands never hit the model
  local cmd, cmd_arg = text:match("^/(%S+)%s*(.-)%s*$")
  if cmd and text:sub(1, 1) == "/" then
    local fn = SLASH[cmd:lower()]
    clear_input()
    if fn then
      vim.cmd.stopinsert()
      fn(cmd_arg)
    else
      M.notify(
        "unknown command: /"
          .. cmd
          .. "  (try /usage, /compact, /context, /review, /yolo, /effort, /new, /model, /resume, /help)",
        vim.log.levels.WARN
      )
    end
    return
  end

  -- Context compaction is a brief, blocking operation with no "next tool call"
  -- to inject before; block the send (keeping the typed text intact) instead of
  -- silently queuing it. Slash commands above still work during compaction.
  if S.status == "compacting" then
    M.notify("compacting context — wait for it to finish before sending", vim.log.levels.WARN)
    return
  end

  -- only keep attachments whose chip is still present (deleting the chip detaches)
  local images = {}
  for _, a in ipairs(S.attachments) do
    if text:find(chip_for(a), 1, true) then images[#images + 1] = a end
  end
  S.attachments = {}
  clear_input()
  if S.on_submit then S.on_submit(text, images, mode) end
end

local function help_lines()
  return {
    "chat window",
    "  q        hide panel        ⌃c   cancel turn",
    "  i a o    jump to prompt    ⇥    jump to prompt",
    "  ]]  [[   next/prev turn    g?   this help",
    "",
    "prompt window",
    "  ⏎        send now (before next tool call if running)",
    "  ⌃s       queue until the agent is completely done",
    "  ⇧⏎ ⌃j    newline           ⇥    jump to chat",
    "  @        complete a project file mention",
    "  ⌃v       paste — attaches clipboard images",
    "  ⌃u ⌃d    scroll the chat (normal mode)",
    "",
    "context",
    "  @path/to/file        inline a file into the message",
    "  @file:L10-20         inline exactly those lines",
    "  [image: …] chips     delete a chip to detach its image",
    "",
    "permission card",
    "  a allow · A always (session) · d deny",
    "  c        deny with a comment for the agent",
    "",
    "slash commands",
    "  /usage   token dashboard   /compact [llm|heuristic] shrink old context",
    "  /new     fresh session     /model   switch model",
    "  /resume  resume session    /review  diff agent edits",
    "  /context repo memory + skills (init · curate · verify · preview · forget <text>)",
    "  /yolo    skip permissions",
    "  /effort [mode]  tune thinking/reasoning (OpenAI: default/off/minimal/low/medium/high; Claude: adaptive/off/1k/4k/8k/10k/16k/32k)",
    "",
    "commands",
    "  :Advantage            toggle panel",
    "  :Advantage new        fresh session",
    "  :Advantage model      switch model",
    "  :Advantage resume     resume a session",
    "  :Advantage usage      token dashboard",
    "  :Advantage compact [llm|heuristic]  shrink old conversation context",
    "  :Advantage context    view/verify/preview/forget repo memory",
    "  :Advantage context preview  exact context packet + token breakdown (<leader>cP)",
    "  :Advantage help       keybind and command cheatsheet",
    "  :Advantage review     diff the agent's changes",
    "  :Advantage yolo       toggle skip-all-permissions",
    "  :Advantage effort [mode] tune thinking/reasoning level",
    "  :Advantage add        add current file to the prompt",
    "  :Advantage files      pick a project file to add",
    "  :Advantage attach {p} attach an image / mention a file",
    "  :Advantage ask {q}    one-shot prompt",
  }
end

local function show_help()
  M.float({ title = "advantage · keys", lines = help_lines(), filetype = "" })
end
M.show_help = show_help

local function jump_turn(dir)
  if not util.win_valid(S.win) then return end
  local row = api.nvim_win_get_cursor(S.win)[1]
  local lines = api.nvim_buf_get_lines(S.buf, 0, -1, false)
  local target
  if dir > 0 then
    for i = row + 1, #lines do
      if lines[i]:sub(1, #"▍") == "▍" then
        target = i
        break
      end
    end
  else
    for i = row - 1, 1, -1 do
      if lines[i]:sub(1, #"▍") == "▍" then
        target = i
        break
      end
    end
  end
  if target then api.nvim_win_set_cursor(S.win, { target, 0 }) end
end

local function ensure_bufs()
  if util.buf_valid(S.buf) then return end

  S.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(S.buf, "advantage://chat")
  vim.bo[S.buf].buftype = "nofile"
  vim.bo[S.buf].bufhidden = "hide"
  vim.bo[S.buf].swapfile = false
  vim.bo[S.buf].filetype = "advantage"
  vim.bo[S.buf].modifiable = false
  if not pcall(vim.treesitter.start, S.buf, "markdown") then vim.bo[S.buf].syntax = "markdown" end

  S.input_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(S.input_buf, "advantage://prompt")
  vim.bo[S.input_buf].buftype = "nofile"
  vim.bo[S.input_buf].bufhidden = "hide"
  vim.bo[S.input_buf].swapfile = false
  vim.bo[S.input_buf].filetype = "advantage_prompt"

  local function map(buf, mode, lhs, rhs, desc, opts)
    opts = opts or {}
    opts.buffer, opts.silent, opts.desc = buf, true, "advantage: " .. desc
    vim.keymap.set(mode, lhs, rhs, opts)
  end

  -- chat maps
  map(S.buf, "n", "q", function()
    M.close()
  end, "hide panel")
  map(S.buf, "n", "<Tab>", function()
    focus_input(false)
  end, "focus prompt")
  for _, key in ipairs({ "i", "a", "o", "I", "A", "O" }) do
    map(S.buf, "n", key, function()
      focus_input(true)
    end, "focus prompt (insert)")
  end
  map(S.buf, "n", "<C-c>", function()
    require("advantage").stop()
  end, "cancel")
  map(S.buf, "n", "g?", show_help, "help")
  map(S.buf, "n", "]]", function()
    jump_turn(1)
  end, "next turn")
  map(S.buf, "n", "[[", function()
    jump_turn(-1)
  end, "previous turn")

  -- prompt maps
  map(S.input_buf, "i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      -- accept the @file completion instead of sending
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-y>", true, false, true), "n", false)
      return
    end
    submit("instant")
  end, "send now")
  map(S.input_buf, "n", "<CR>", function()
    submit("instant")
  end, "send now")
  map(S.input_buf, { "n", "i" }, "<C-s>", function()
    submit("queued")
  end, "queue message")
  map(S.input_buf, "i", "<S-CR>", "<CR>", "newline")
  map(S.input_buf, "i", "<C-j>", "<CR>", "newline")
  map(S.input_buf, "n", "<Tab>", focus_chat, "focus chat")
  map(S.input_buf, "n", "q", function()
    M.close()
  end, "hide panel")
  map(S.input_buf, "n", "g?", show_help, "help")
  map(S.input_buf, "n", "<C-c>", function()
    require("advantage").stop()
  end, "cancel")
  map(S.input_buf, "i", "<C-c>", function()
    vim.cmd.stopinsert()
    require("advantage").stop()
  end, "cancel")
  map(S.input_buf, { "n", "i" }, "<C-v>", smart_paste, "paste (image-aware)")
  map(S.input_buf, "n", "<C-u>", function()
    scroll_chat("<C-u>")
  end, "scroll chat up")
  map(S.input_buf, "n", "<C-d>", function()
    scroll_chat("<C-d>")
  end, "scroll chat down")

  -- `@` pops project-file completion for mentions
  map(S.input_buf, "i", "@", function()
    vim.schedule(function()
      if api.nvim_get_current_buf() ~= S.input_buf or not vim.fn.mode():find("i") then return end
      local files = require("advantage.attach").project_files(400)
      if #files == 0 then return end
      local col = api.nvim_win_get_cursor(0)[2]
      vim.fn.complete(col + 1, files)
    end)
    return "@"
  end, "file mention", { expr = true })

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = S.input_buf,
    callback = function()
      input_placeholder()
      resize_input()
    end,
  })

  -- keep `follow` in sync with where the user actually is in the transcript
  api.nvim_create_autocmd("CursorMoved", {
    buffer = S.buf,
    callback = function()
      local lc = api.nvim_buf_line_count(S.buf)
      local cur = api.nvim_win_get_cursor(0)[1]
      S.follow = cur >= lc - 2
    end,
  })

  api.nvim_create_autocmd("VimResized", {
    group = api.nvim_create_augroup("AdvantageResize", { clear = true }),
    callback = resize_input,
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
  update_input_winbar()

  update_winbar()
  show_welcome()
  input_placeholder()
  resize_input()
  -- Reopening while the agent is still working: restart the spinner we stopped on close.
  if S.status ~= "idle" then ensure_timer() end
  if focus ~= false then focus_input(true) end
end

function M.close()
  for _, win in ipairs({ S.input_win, S.win }) do
    if util.win_valid(win) then pcall(api.nvim_win_close, win, true) end
  end
  S.win, S.input_win = nil, nil
  -- Stop the spinner timer: it self-stops only on idle, so closing mid-stream
  -- would otherwise leave it firing every 110ms into a hidden buffer.
  stop_timer()
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.clear()
  ensure_bufs()
  api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(S.buf, ns_extra, 0, -1)
  buf_write(function()
    api.nvim_buf_set_lines(S.buf, 0, -1, false, {})
  end)
  S.tools = {}
  S.header_mark, S.meta_mark = nil, nil
  S.think_mark, S.think_start = nil, nil
  S.mode, S.last_kind = nil, nil
  S.usage = { input = 0, output = 0 }
  S.welcome_mark = nil
  S.follow = true
  S.queue_count = 0
  -- a new session must not inherit the previous one's pending attachments/chips
  S.attachments = {}
  show_welcome()
  update_winbar()
end

-- transcript rendering ------------------------------------------------------

function M.user_message(text, images)
  ensure_bufs()
  S.mode, S.last_kind = nil, "user"
  S.follow = true -- sending a message snaps back to the live end
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
  -- image chips that aren't already visible in the text
  for _, img in ipairs(images or {}) do
    local chip = ("[image: %s]"):format(img.name or "image")
    if not text:find(chip, 1, true) then
      append({ "  🖼 " .. (img.name or "image") })
      local r = last_row()
      api.nvim_buf_set_extmark(S.buf, ns, r, 0, {
        end_row = r,
        end_col = #api.nvim_buf_get_lines(S.buf, r, r + 1, false)[1],
        hl_group = "AdvMeta",
      })
    end
  end
  autoscroll()
end

---Queue indicator: `n` messages waiting for the current agent flow to finish.
function M.set_queue(n)
  S.queue_count = n or 0
  update_winbar()
end

---Announce a message queued until the current agent flow is idle.
function M.queued(n, text)
  M.set_queue(n)
  local head = text:gsub("%s+", " ")
  if #head > 48 then head = head:sub(1, 45) .. "…" end
  M.notice(("queued #%d — %s"):format(n, head))
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

---Append streamed tool output under the current tool card. This is intentionally
---plain transcript text (not part of model-visible history); the final tool
---result is still recorded by the agent when the tool exits.
function M.tool_output(id, chunk)
  if not util.buf_valid(S.buf) or not chunk or chunk == "" then return end
  local max = 6000
  if #chunk > max then chunk = chunk:sub(1, max) .. "\n… [stream chunk truncated]" end
  local lines = vim.split(chunk:gsub("\r", ""), "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  if #lines == 0 then return end
  local out = {}
  for _, line in ipairs(lines) do
    out[#out + 1] = "    " .. line
  end
  append(out)
  S.last_kind = "tool"
  local start = last_row() - #out + 1
  for row = start, last_row() do
    local line = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
    api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
      end_row = row,
      end_col = #line,
      hl_group = "AdvToolOutput",
      priority = 110,
    })
  end
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
    local up = ("↑%s ↓%s"):format(util.fmt_tokens(usage.input), util.fmt_tokens(usage.output))
    if usage.cached and usage.cached > 0 then up = up .. (" (%s cached)"):format(util.fmt_tokens(usage.cached)) end
    parts[#parts + 1] = up
  end
  if elapsed_ns then parts[#parts + 1] = util.fmt_elapsed(elapsed_ns) end
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
  local parts = split_lines(text)
  local lines = { "" }
  for i, part in ipairs(parts) do
    lines[#lines + 1] = (i == 1 and "  ▸ " or "    ") .. part
  end
  append(lines)
  S.last_kind = "text"
  local end_row = last_row()
  local start_row = math.max(0, end_row - #parts + 1)
  for row = start_row, end_row do
    local line = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
    api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
      end_row = row,
      end_col = #line,
      hl_group = "AdvNotice",
    })
  end
  autoscroll()
end

function M.finish_turn()
  S.mode = nil
end

---Begin a determinate compaction progress bar. `tokens` (the size of the
---context being summarised) drives the fill speed via a rough duration estimate;
---the bar holds at 95% until compaction_done snaps it to 100%.
---@param tokens? integer
function M.compaction_start(tokens)
  local est = math.max(12000, math.min(180000, 8000 + (tonumber(tokens) or 0) * 0.5))
  S.compact = { t0 = uv.now(), est = est, done = false }
  M.set_status("compacting")
end

---Finish compaction: flash a full bar briefly, then return to idle.
function M.compaction_done()
  if S.compact then S.compact.done = true end
  update_winbar()
  vim.defer_fn(function()
    S.compact = nil
    if S.status == "compacting" then M.set_status("idle") end
  end, 300)
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

---Repaint the winbar (e.g. after toggling yolo).
function M.refresh()
  update_winbar()
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
  opts.lines = normalize_lines(opts.lines)
  api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype and opts.filetype ~= "" then vim.bo[buf].filetype = opts.filetype end
  local width = 20
  for _, l in ipairs(opts.lines) do
    width = math.max(width, api.nvim_strwidth(l) + 2)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.8))
  -- Clamp to >=1: an empty `lines` (e.g. a permission preview with no body) would
  -- otherwise ask nvim_open_win for height 0 and throw, dropping the card.
  local height = math.max(1, math.min(#opts.lines, math.floor(vim.o.lines * 0.7)))
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

---Permission card. cb("allow"|"always"|"deny", comment?), exactly once.
function M.confirm(preview, cb)
  local done = false
  local win
  local function decide(what, comment)
    if done then return end
    done = true
    cb(what, comment)
  end
  local buf
  win, buf = M.float({
    title = preview.title or "allow?",
    lines = preview.lines or {},
    filetype = preview.filetype,
    footer = "a allow · A always · d deny · c deny + comment",
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
  -- deny with feedback: claim the decision before closing the float so the
  -- WinClosed fallback below can't fire a plain deny first
  vim.keymap.set("n", "c", function()
    if done then return end
    done = true
    if util.win_valid(win) then api.nvim_win_close(win, true) end
    vim.ui.input({ prompt = "deny — what should the agent do instead? " }, function(input)
      input = input and vim.trim(input) or ""
      cb("deny", input ~= "" and input or nil)
    end)
  end, { buffer = buf, silent = true, nowait = true })
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        decide("deny")
      end)
    end,
  })
  return function(decision, comment)
    if util.win_valid(win) then api.nvim_win_close(win, true) end
    decide(decision, comment)
  end
end

-- resume ----------------------------------------------------------------------

---Re-render a saved conversation (best effort: text + tool cards).
function M.render_transcript(messages, model_label)
  M.clear()
  S.model_label = model_label or S.model_label
  for mi, msg in ipairs(messages) do
    if msg.role == "user" then
      local texts, images = {}, {}
      for _, block in ipairs(msg.content) do
        if block.type == "text" then
          texts[#texts + 1] = block.text
        elseif block.type == "image" then
          images[#images + 1] = { name = "image" }
        end
      end
      if #texts > 0 or #images > 0 then
        M.user_message(#texts > 0 and table.concat(texts, "\n") or "(image)", images)
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
              if r.type == "tool_result" and r.tool_use_id == block.id and r.is_error then status = "error" end
            end
          end
          local def = require("advantage.tools").get(block.name)
          -- summary() runs on persisted (possibly malformed) input during resume;
          -- a throw here must not abort rendering the rest of the transcript.
          local ok_detail, detail = pcall(function()
            return def and def.summary and def.summary(block.input) or nil
          end)
          M.tool_begin(block.id, block.name)
          M.tool_update(block.id, {
            status = status,
            detail = ok_detail and detail or nil,
          })
        end
      end
    end
  end
  S.mode = nil
  M.set_status("idle")
end

return M
