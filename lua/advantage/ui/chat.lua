---@brief The advantage panel: chat transcript + prompt, tool cards, permission
---floats. Styling derives from the active colorscheme (see ui/highlights.lua).
---
---Layered: ui/chat/state.lua (the shared `S` state + buffer primitives) ←
---ui/chat/render.lua (winbar/status, tool cards, spinner, welcome, streamed
---writes) ← this file (the controller + public M API: open/close, message
---streaming, tool cards, permission floats, resume).
local util = require("advantage.util")
local config = require("advantage.config")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local state = require("advantage.ui.chat.state")
local render = require("advantage.ui.chat.render")

local S = state.S
M.state = S

local ns, ns_extra, ICON = state.ns, state.ns_extra, state.ICON

-- Buffer primitives (state.lua), aliased for the controller/API below.
local opt = state.opt
local split_lines = state.split_lines
local normalize_lines = state.normalize_lines
local buf_write = state.buf_write
local clear_welcome = state.clear_welcome
local append = state.append
local last_row = state.last_row
local autoscroll = state.autoscroll

-- Rendering + status (render.lua), aliased for the controller/API below.
local stream_chunk = render.stream_chunk
local start_block = render.start_block
local update_winbar = render.update_winbar
local redraw_tool = render.redraw_tool
local show_welcome = render.show_welcome
local ensure_timer = render.ensure_timer
local stop_timer = render.stop_timer
local input_placeholder = render.input_placeholder
local resize_input = render.resize_input

-- Streaming providers can emit hundreds of tiny deltas per second. Rendering
-- every delta separately repeatedly reads/replaces the tail line, updates the
-- thinking extmark, and autoscrolls. Coalesce one short UI-frame's worth while
-- keeping explicit boundaries synchronous so transcript ordering is exact.
local STREAM_FLUSH_MS = 20
local STREAM_FLUSH_BYTES = 32 * 1024

local function stop_stream_timer()
  local timer = S.stream_timer
  S.stream_timer = nil
  if not timer then return end
  pcall(function()
    timer:stop()
    if not timer:is_closing() then timer:close() end
  end)
end

local function flush_stream()
  stop_stream_timer()
  local parts, mode, buf = S.stream_parts, S.stream_mode, S.stream_buf
  S.stream_parts, S.stream_bytes, S.stream_mode, S.stream_buf = {}, 0, nil, nil
  if not parts or #parts == 0 then return end
  -- A cleared/replaced transcript must never receive a late timer write. All
  -- normal mode transitions call flush_stream first; the equality check is a
  -- final guard against module reloads or unexpected external state changes.
  if S.buf == buf and util.buf_valid(buf) and S.mode == mode then stream_chunk(table.concat(parts)) end
end

local function queue_stream(chunk)
  if chunk == nil or chunk == "" then return end
  -- Defensive boundary handling: callers below normally flush before changing
  -- S.mode, but do not merge differently highlighted blocks if that invariant
  -- is ever relaxed.
  if S.stream_mode and (S.stream_mode ~= S.mode or S.stream_buf ~= S.buf) then flush_stream() end
  S.stream_mode = S.mode
  S.stream_buf = S.buf
  S.stream_parts[#S.stream_parts + 1] = chunk
  S.stream_bytes = S.stream_bytes + #chunk
  if S.stream_bytes >= STREAM_FLUSH_BYTES then
    flush_stream()
    return
  end
  if S.stream_timer then return end
  local timer = uv.new_timer()
  S.stream_timer = timer
  timer:start(
    STREAM_FLUSH_MS,
    0,
    vim.schedule_wrap(function()
      -- A synchronous boundary may already have drained this batch while the
      -- timer callback was waiting on Neovim's main loop.
      if S.stream_timer ~= timer then return end
      flush_stream()
    end)
  )
end

-- Tool output is buffered per card below; this forward declaration lets close
-- and clear drain pending frames before a buffer is hidden or replaced.
local flush_tool_streams = function() end

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
  harness = function(arg)
    if arg and arg ~= "" then
      require("advantage").set_harness(arg)
    else
      require("advantage").pick_harness()
    end
  end,
  mode = function(arg)
    if arg and arg ~= "" then
      require("advantage").set_harness(arg)
    else
      require("advantage").pick_harness()
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
          .. "  (try /usage, /compact, /context, /review, /yolo, /effort, /harness, /new, /model, /resume, /help)",
        vim.log.levels.WARN
      )
    end
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
    "  @        complete a project file mention (fuzzy)",
    "  ⇥ ⇧⇥     cycle the @file menu · ⏎ accepts",
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
    "  /effort [mode]  model-aware reasoning (run /effort to see the active model's supported levels)",
    "  /harness [mode] orchestration policy (auto · low · medium · high · xhigh · max · ultra)",
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
    "  :Advantage harness [mode] tune orchestration policy (<leader>ch)",
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
  -- turn headers: "▍ you" (user) and "✦ model" (assistant)
  local function is_head(line)
    return line:sub(1, #"▍") == "▍" or line:sub(1, #(ICON .. " ")) == ICON .. " "
  end
  local target
  if dir > 0 then
    for i = row + 1, #lines do
      if is_head(lines[i]) then
        target = i
        break
      end
    end
  else
    for i = row - 1, 1, -1 do
      if is_head(lines[i]) then
        target = i
        break
      end
    end
  end
  if target then api.nvim_win_set_cursor(S.win, { target, 0 }) end
end

local function map(buf, mode, lhs, rhs, desc, opts)
  opts = opts or {}
  opts.buffer, opts.silent, opts.desc = buf, true, "advantage: " .. desc
  vim.keymap.set(mode, lhs, rhs, opts)
end

---Create the transcript + prompt scratch buffers with their options set.
local function create_chat_buffer()
  S.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(S.buf, "advantage://chat")
  vim.bo[S.buf].buftype = "nofile"
  vim.bo[S.buf].bufhidden = "hide"
  vim.bo[S.buf].swapfile = false
  vim.bo[S.buf].filetype = "advantage"
  vim.bo[S.buf].modifiable = false
  if not pcall(vim.treesitter.start, S.buf, "markdown") then vim.bo[S.buf].syntax = "markdown" end
end

local function create_input_buffer()
  S.input_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(S.input_buf, "advantage://prompt")
  vim.bo[S.input_buf].buftype = "nofile"
  vim.bo[S.input_buf].bufhidden = "hide"
  vim.bo[S.input_buf].swapfile = false
  vim.bo[S.input_buf].filetype = "advantage_prompt"
end

---Buffer-local keymaps for the transcript window.
local function map_chat_keys()
  assert(util.buf_valid(S.buf), "map_chat_keys: chat buffer must exist")
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
end

---Buffer-local keymaps for the prompt window (send, newline, paste, @mentions).
local function map_input_keys()
  assert(util.buf_valid(S.input_buf), "map_input_keys: input buffer must exist")
  map(S.input_buf, "i", "<CR>", function()
    if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "selected" }).selected >= 0 then
      -- accept the highlighted @file completion instead of sending; with
      -- nothing highlighted, Enter means send (the menu closes on its own)
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-y>", true, false, true), "n", false)
      return
    end
    submit("instant")
  end, "send now")
  -- cycle the @file menu with Tab / Shift-Tab while it's open
  map(S.input_buf, "i", "<Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-n>" or "<Tab>"
  end, "next completion", { expr = true })
  map(S.input_buf, "i", "<S-Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-p>" or "<S-Tab>"
  end, "previous completion", { expr = true })
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
  -- `@` pops project-file completion for mentions. The user's completeopt is
  -- overridden while the menu is open: `noselect` so the first file is never
  -- inserted uninvited (type to filter, Tab/⌃n to pick, ⏎ to accept — then
  -- `@` again for the next file), `fuzzy` where this Neovim supports it.
  local saved_completeopt
  local function popup_file_menu()
    -- Anchor on the `@` being completed: fast typing (or a paste) can land
    -- more characters before this scheduled popup runs, so never assume the
    -- cursor still sits right after the `@`. Whatever was typed after it
    -- becomes the initial filter base.
    local col = api.nvim_win_get_cursor(0)[2]
    local line = api.nvim_get_current_line()
    local at = line:sub(1, col):find("@[^%s@]*$")
    if not at then return end
    -- complete() only filters keys typed AFTER the menu opens, so an existing
    -- base must be fuzzy-filtered by hand or the menu shows every file
    local base = line:sub(at + 1, col)
    local files = require("advantage.attach").project_files(400, require("advantage").cwd())
    if base ~= "" then files = vim.fn.matchfuzzy(files, base) end
    if #files == 0 then return end
    if saved_completeopt == nil then saved_completeopt = vim.o.completeopt end
    if not pcall(api.nvim_set_option_value, "completeopt", "menu,menuone,noselect,fuzzy", {}) then
      vim.o.completeopt = "menu,menuone,noselect" -- fuzzy needs 0.11+
    end
    api.nvim_create_autocmd({ "CompleteDone", "InsertLeave" }, {
      buffer = S.input_buf,
      once = true,
      callback = function()
        if saved_completeopt then
          vim.o.completeopt = saved_completeopt
          saved_completeopt = nil
        end
      end,
    })
    vim.fn.complete(at + 1, files)
  end
  map(S.input_buf, "i", "@", function()
    vim.schedule(function()
      if api.nvim_get_current_buf() ~= S.input_buf or not vim.fn.mode():find("i") then return end
      if #require("advantage.attach").project_files(400, require("advantage").cwd()) == 0 then return end
      popup_file_menu()
    end)
    return "@"
  end, "file mention", { expr = true })
end

---Autocmds that keep the prompt sized and the transcript's follow state current.
local function attach_input_autocmds()
  assert(util.buf_valid(S.input_buf), "attach_input_autocmds: prompt buffer must exist")
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = S.input_buf,
    callback = function()
      input_placeholder()
      resize_input()
    end,
  })
end

local function attach_chat_autocmds()
  assert(util.buf_valid(S.buf), "attach_chat_autocmds: chat buffer must exist")
  -- keep `follow` in sync with where the user actually is in the transcript
  api.nvim_create_autocmd("CursorMoved", {
    buffer = S.buf,
    callback = function()
      local lc = api.nvim_buf_line_count(S.buf)
      local cur = api.nvim_win_get_cursor(0)[1]
      S.follow = cur >= lc - 2
    end,
  })
end

local function attach_resize_autocmd()
  api.nvim_create_autocmd("VimResized", {
    group = api.nvim_create_augroup("AdvantageResize", { clear = true }),
    callback = resize_input,
  })
end

local function ensure_bufs()
  local chat_ok, input_ok = util.buf_valid(S.buf), util.buf_valid(S.input_buf)
  if chat_ok and input_ok then return end

  -- A user command or another plugin may wipe one scratch buffer independently.
  -- Close any surviving panel windows before repairing the pair so the same
  -- prompt buffer is never left displayed in an orphan split.
  for _, win in ipairs({ S.input_win, S.win }) do
    if util.win_valid(win) then pcall(api.nvim_win_close, win, true) end
  end
  S.win, S.input_win = nil, nil
  stop_timer()

  if not chat_ok then
    -- Drain timers/closures that still point at the deleted transcript, then
    -- reset only transcript-owned state. A surviving prompt remains usable.
    flush_stream()
    flush_tool_streams()
    S.tools = {}
    S.header_mark, S.meta_mark = nil, nil
    S.think_mark, S.think_start = nil, nil
    S.mode, S.last_kind = nil, nil
    S.welcome_mark = nil
    S.follow = true
    create_chat_buffer()
    map_chat_keys()
    attach_chat_autocmds()
  end
  if not input_ok then
    -- Attachments are chips in the prompt buffer; once that buffer is gone,
    -- retaining their base64 payloads would be both surprising and a leak.
    S.attachments = {}
    create_input_buffer()
    map_input_keys()
    attach_input_autocmds()
  end
  attach_resize_autocmd()
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
  -- the panel is its own quiet surface, with a 1-col breathing gutter
  opt("statuscolumn", "%#AdvPanelGutter# ", S.win)
  opt("scrolloff", 3, S.win)
  opt("sidescrolloff", 2, S.win)
  opt(
    "winhighlight",
    "Normal:AdvPanel,NormalNC:AdvPanel,EndOfBuffer:AdvPanel,SignColumn:AdvPanel"
      .. ",WinSeparator:AdvPanelBorder,WinBar:AdvPanelBar,WinBarNC:AdvPanelBar,CursorLine:AdvPanelActive",
    S.win
  )

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
  opt("scrolloff", 1, S.input_win)
  opt("sidescrolloff", 2, S.input_win)
  opt("fillchars", "eob: ", S.input_win)
  -- the prompt reads as a field: a deeper surface with a ❯ caret in the gutter
  opt("statuscolumn", "%#AdvPromptSign#%{(v:virtnum == 0 && v:lnum == 1) ? '❯ ' : '  '}", S.input_win)
  opt(
    "winhighlight",
    "Normal:AdvPanelField,NormalNC:AdvPanelField,EndOfBuffer:AdvPanelField"
      .. ",SignColumn:AdvPanelField,WinSeparator:AdvPanelBorder,CursorLine:AdvPanelActive",
    S.input_win
  )

  update_winbar()
  show_welcome()
  input_placeholder()
  resize_input()
  -- Reopening while the agent is still working: restart the spinner we stopped on close.
  if S.status ~= "idle" then ensure_timer() end
  if focus ~= false then focus_input(true) end
end

function M.close()
  flush_stream()
  flush_tool_streams()
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
  flush_stream()
  flush_tool_streams()
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
  flush_stream()
  S.mode, S.last_kind = nil, "user"
  S.follow = true -- sending a message snaps back to the live end
  local head = "▍ you"
  append({ "", head })
  local row = last_row()
  -- a hairline above each exchange gives the transcript its rhythm
  if row > 1 then
    local w = util.win_valid(S.win) and math.max(8, api.nvim_win_get_width(S.win) - 2) or 60
    api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
      virt_lines = { { { string.rep("─", w), "AdvRule" } } },
      virt_lines_above = true,
    })
  end
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
  if #head > 48 then head = util.utf8_safe_sub(head, 45) .. "…" end
  M.notice(("queued #%d — %s"):format(n, head))
end

function M.begin_assistant(label)
  ensure_bufs()
  flush_stream()
  S.model_label = label or S.model_label
  S.mode, S.last_kind = nil, "header"
  S.think_mark, S.think_start = nil, nil
  local head = ICON .. " " .. (label or "assistant")
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
    flush_stream()
    start_block()
    S.mode = "text"
    S.last_kind = "text"
  end
  queue_stream(chunk)
end

function M.stream_thinking(chunk)
  if not util.buf_valid(S.buf) then return end
  if S.mode ~= "thinking" then
    flush_stream()
    start_block()
    S.mode = "thinking"
    S.last_kind = "text"
    S.think_start = last_row()
    S.think_mark = nil
  end
  queue_stream(chunk)
end

function M.tool_begin(id, name)
  if not util.buf_valid(S.buf) then return end
  flush_stream()
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

---@param patch {status?: string, detail?: string, name?: string, error?: string}
function M.tool_update(id, patch)
  local pending = S.tool_streams[id]
  if pending and patch.status and patch.status ~= "running" and patch.status ~= "pending" and pending.flush then
    pending.flush()
  end
  local t = S.tools[id]
  if not t then return end
  t.status = patch.status or t.status
  t.detail = patch.detail or t.detail
  t.name = patch.name or t.name
  t.error = patch.error or t.error
  redraw_tool(id)
  -- Extmarks and rendered bytes own the completed card from here on. Keeping
  -- the Lua record only serves the spinner's running-card redraw loop, so drop
  -- terminal cards immediately instead of retaining every tool call for the
  -- entire conversation.
  if t.status ~= "pending" and t.status ~= "waiting" and t.status ~= "running" then S.tools[id] = nil end
  autoscroll()
end

---Append streamed tool output under the current tool card. This is intentionally
---plain transcript text (not part of model-visible history); the final tool
---result is still recorded by the agent when the tool exits.
local function append_tool_output(id, chunk, buf)
  if S.buf ~= buf or not util.buf_valid(buf) then return end
  flush_stream()
  local max = 6000
  if #chunk > max then chunk = util.utf8_safe_sub(chunk, max) .. "\n… [stream chunk truncated]" end
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

function M.tool_output(id, chunk)
  if not util.buf_valid(S.buf) or not chunk or chunk == "" then return end
  local batch = S.tool_streams[id]
  if not batch or batch.buf ~= S.buf then
    if batch and batch.flush then batch.flush() end
    batch = { parts = {}, bytes = 0, buf = S.buf }
    S.tool_streams[id] = batch
    batch.flush = function()
      if S.tool_streams[id] ~= batch then return end
      S.tool_streams[id] = nil
      if batch.timer then
        local timer = batch.timer
        batch.timer = nil
        pcall(function()
          timer:stop()
          if not timer:is_closing() then timer:close() end
        end)
      end
      if #batch.parts > 0 then append_tool_output(id, table.concat(batch.parts), batch.buf) end
    end
  end
  batch.parts[#batch.parts + 1] = chunk
  batch.bytes = batch.bytes + #chunk
  if batch.bytes >= STREAM_FLUSH_BYTES then return batch.flush() end
  if batch.timer then return end
  local timer = uv.new_timer()
  batch.timer = timer
  timer:start(
    STREAM_FLUSH_MS,
    0,
    vim.schedule_wrap(function()
      if S.tool_streams[id] == batch and batch.timer == timer then batch.flush() end
    end)
  )
end

flush_tool_streams = function()
  local pending = {}
  for _, batch in pairs(S.tool_streams) do
    pending[#pending + 1] = batch
  end
  for _, batch in ipairs(pending) do
    if batch.flush then batch.flush() end
  end
end

---Right-aligned meta on the current turn's header; overwritten as the turn
---progresses so it always shows the cumulative turn cost.
function M.message_meta(usage, elapsed_ns)
  flush_stream()
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
  flush_stream()
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
  -- the ▸ marker carries the accent so notices read as quiet signposts
  api.nvim_buf_set_extmark(S.buf, ns, start_row, 2, {
    end_row = start_row,
    end_col = 2 + #"▸",
    hl_group = "AdvNoticeMark",
    priority = 130,
  })
  autoscroll()
end

function M.finish_turn()
  flush_stream()
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
  if status == "idle" then flush_stream() end
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

function M.set_effort_label(label)
  S.effort_label = label
  update_winbar()
end

function M.set_harness_label(label)
  S.harness_label = label
  update_winbar()
end

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "advantage" })
end

-- floats --------------------------------------------------------------------

---Generic informational float (help, previews).
---`opts.footer` may be a string (rendered as a hint) or a list of
---`{text, hl}` chunks; `opts.dim_labels = n` softly dims the first `n` columns
---of every content line, for label/value dashboards.
function M.float(opts)
  local buf = api.nvim_create_buf(false, true)
  opts.lines = normalize_lines(opts.lines)
  api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype and opts.filetype ~= "" then vim.bo[buf].filetype = opts.filetype end
  local footer
  if type(opts.footer) == "table" then
    footer = { { " ", "AdvFloatHint" } }
    vim.list_extend(footer, opts.footer)
    footer[#footer + 1] = { " ", "AdvFloatHint" }
  elseif opts.footer then
    footer = { { " " .. opts.footer .. " ", "AdvFloatHint" } }
  end
  local width = 20
  for _, l in ipairs(opts.lines) do
    width = math.max(width, api.nvim_strwidth(l) + 2)
  end
  -- never truncate the title or the footer key hints
  width = math.max(width, api.nvim_strwidth(opts.title or "") + 4)
  local footer_w = 0
  for _, chunk in ipairs(footer or {}) do
    footer_w = footer_w + api.nvim_strwidth(chunk[1])
  end
  width = math.max(width, footer_w)
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
    footer = footer,
    footer_pos = footer and "center" or nil,
  })
  opt("wrap", false, win)
  opt("scrolloff", 2, win)
  opt("sidescrolloff", 2, win)
  opt("cursorline", false, win)
  opt(
    "winhighlight",
    "NormalFloat:AdvPanel,FloatBorder:AdvFloatBorder,FloatTitle:AdvFloatTitle"
      .. ",FloatFooter:AdvFloatHint,EndOfBuffer:AdvPanel",
    win
  )
  if opts.dim_labels then
    for row, l in ipairs(opts.lines) do
      local upto = math.min(#l, opts.dim_labels)
      if upto > 0 then
        api.nvim_buf_set_extmark(buf, ns_extra, row - 1, 0, {
          end_row = row - 1,
          end_col = upto,
          hl_group = "AdvFloatLabel",
        })
      end
    end
  end
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
  -- The prompt is submitted from insert mode, and nvim_open_win carries that
  -- mode into the float — so force normal mode, letting the single-key a/y/d
  -- decision maps fire immediately without an extra <Esc>.
  vim.cmd.stopinsert()
  local buf
  win, buf = M.float({
    title = preview.title or "allow?",
    lines = preview.lines or {},
    filetype = preview.filetype,
    footer = {
      { "a", "AdvFloatKey" },
      { " allow · ", "AdvFloatHint" },
      { "A", "AdvFloatKey" },
      { " always · ", "AdvFloatHint" },
      { "d", "AdvFloatKey" },
      { " deny · ", "AdvFloatHint" },
      { "c", "AdvFloatKey" },
      { " comment", "AdvFloatHint" },
    },
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
          local result_error
          local nxt = messages[mi + 1]
          if nxt and nxt.role == "user" then
            for _, r in ipairs(nxt.content) do
              if r.type == "tool_result" and r.tool_use_id == block.id and r.is_error then
                status = "error"
                result_error = tostring(r.content or "tool failed"):gsub("[%c%s]+", " ")
                if #result_error > 220 then
                  result_error = require("advantage.util").utf8_safe_sub(result_error, 217) .. "…"
                end
              end
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
            error = result_error,
          })
        end
      end
    end
  end
  M.finish_turn()
  M.set_status("idle")
end

return M
