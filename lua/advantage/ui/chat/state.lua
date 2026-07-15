---@brief Shared view state + low-level buffer primitives for the chat UI. This is
---the bottom layer of ui/chat: it owns the single `S` state table, the namespaces
---and spinner constants, and the small helpers every higher layer (render.lua and
---chat.lua) writes the transcript through. Keeping it in one place lets render.lua
---and chat.lua share one state table without a circular require.
local util = require("advantage.util")
local api = vim.api

local V = {}

V.ns = api.nvim_create_namespace("advantage")
V.ns_extra = api.nvim_create_namespace("advantage.extra")
V.FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
V.ICON = "✦"

local ns, ns_extra = V.ns, V.ns_extra

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
  -- Provider deltas often arrive a few bytes at a time.  The controller folds
  -- each short burst into one render so buffer writes, extmarks, and redraws
  -- scale with frames rather than tokens.
  stream_parts = {},
  stream_bytes = 0,
  stream_mode = nil,
  stream_buf = nil,
  stream_timer = nil,
  tool_streams = {}, -- id -> buffered streamed tool output
  spinner = 1,
  timer = nil,
  status = "idle", -- idle | streaming | tool | waiting | compacting
  status_detail = nil,
  compact = nil, -- { t0 = ms, est = ms, done = bool } while compacting
  usage = { input = 0, output = 0 },
  auth_badge = nil,
  model_label = "",
  effort_label = nil,
  harness_label = nil,
  welcome_mark = nil,
  on_submit = nil,
  attachments = {}, -- pending prompt images: {name=, media_type=, data=, path?=}
  follow = true, -- stick to the bottom of the transcript
  queue_count = 0, -- messages waiting for the current agent flow to finish
}
V.S = S

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

V.opt = opt
V.esc_bar = esc_bar
V.split_lines = split_lines
V.normalize_lines = normalize_lines
V.one_line = one_line
V.buf_write = buf_write
V.clear_welcome = clear_welcome
V.append = append
V.last_row = last_row
V.autoscroll = autoscroll

return V
