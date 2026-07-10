---@brief Rendering + status layer for the chat UI. Turns view state (state.S)
---into on-screen bytes: the winbar/status line, tool cards, the spinner timer, the
---welcome banner, the prompt placeholder, and the streamed-text writer. It
---sits above state.lua (whose primitives it writes through) and below chat.lua
---(the controller/API, which calls these). It never calls back into chat.lua.
local util = require("advantage.util")
local config = require("advantage.config")
local api = vim.api
local uv = vim.uv or vim.loop

local state = require("advantage.ui.chat.state")
local S = state.S
local ns, ns_extra, FRAMES, ICON = state.ns, state.ns_extra, state.FRAMES, state.ICON
local opt, esc_bar, one_line = state.opt, state.esc_bar, state.one_line
local buf_write, append, last_row, autoscroll = state.buf_write, state.append, state.last_row, state.autoscroll

local R = {}

-- winbar / status ---------------------------------------------------------

local function winbar_text()
  local left = ("%%#AdvBarIcon# %s %%#AdvBarTitle#%s"):format(ICON, esc_bar(S.model_label))
  if S.effort_label then left = left .. (" %%#AdvBarFaint#· %s"):format(esc_bar(S.effort_label)) end
  if S.auth_badge then left = left .. (" %%#AdvBarFaint#· %s"):format(esc_bar(S.auth_badge)) end
  if config.options.tools.yolo then left = left .. " %#AdvBarDanger#⚡ yolo" end
  local right = ""
  if S.queue_count > 0 then right = ("%%#AdvBarInfo#⧗ %d queued  "):format(S.queue_count) end
  if S.usage.input > 0 or S.usage.output > 0 then
    right = right
      .. ("%%#AdvBarFaint#↑%s ↓%s  "):format(util.fmt_tokens(S.usage.input), util.fmt_tokens(S.usage.output))
  end
  if S.status == "streaming" then
    right = right .. ("%%#AdvBarBusy#%s "):format(FRAMES[S.spinner])
  elseif S.status == "tool" then
    right = right .. ("%%#AdvBarBusy#%s %s "):format(FRAMES[S.spinner], esc_bar(S.status_detail or "tool"))
  elseif S.status == "waiting" then
    right = right .. ("%%#AdvBarBusy#◇ approve %s? "):format(esc_bar(S.status_detail or ""))
  elseif S.status == "compacting" then
    local c = S.compact or {}
    local frac = 0
    if c.t0 and c.est and c.est > 0 then frac = math.min(0.95, (uv.now() - c.t0) / c.est) end
    if c.done then frac = 1 end
    local width = 10
    local filled = math.floor(frac * width + 0.5)
    local bar = string.rep("━", filled) .. string.rep("╌", width - filled)
    right = right .. ("%%#AdvBarBusy#compacting %s %d%%%% "):format(bar, math.floor(frac * 100 + 0.5))
  end
  return left .. " %=" .. right
end

function R.update_winbar()
  if util.win_valid(S.win) then opt("winbar", winbar_text(), S.win) end
end

---Per-status tool-line style: a traffic-light signal — running is yellow,
---success green, failure red — with the icon and name carrying the color.
local function tool_style(status)
  local styles = {
    pending = { icon = "·", icon_hl = "AdvToolGhost", line = "AdvToolGhost", name = "AdvToolGhost" },
    waiting = { icon = "◇", icon_hl = "AdvToolWaiting", line = "AdvToolFaint", name = "AdvToolActiveName" },
    running = {
      icon = FRAMES[S.spinner],
      icon_hl = "AdvToolRunning",
      line = "AdvToolFaint",
      name = "AdvToolRunning",
    },
    ok = { icon = "✓", icon_hl = "AdvToolOk", line = "AdvToolFaint", name = "AdvToolOk" },
    error = { icon = "✗", icon_hl = "AdvToolErr", line = "AdvToolFaint", name = "AdvToolErr" },
    denied = { icon = "◌", icon_hl = "AdvToolDenied", line = "AdvToolDenied", name = "AdvToolDenied" },
  }
  return styles[status or "pending"] or styles.pending
end

local function tool_line(t)
  local style = tool_style(t.status)
  local text = ("  %s %s"):format(style.icon, one_line(t.name or "?"))
  if t.detail and t.detail ~= "" then text = text .. "  " .. one_line(t.detail) end
  return text, style
end
R.tool_line = tool_line

function R.redraw_tool(id)
  local t = S.tools[id]
  if not t or not util.buf_valid(S.buf) then return end
  local pos = api.nvim_buf_get_extmark_by_id(S.buf, ns, t.mark, {})
  if not pos or #pos == 0 then return end
  local row = pos[1]
  local old = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
  local text, style = tool_line(t)
  buf_write(function()
    api.nvim_buf_set_text(S.buf, row, 0, row, #old, { text })
  end)
  -- restore the row anchor and layer: base line color, icon, then the name
  t.mark = api.nvim_buf_set_extmark(S.buf, ns, row, 0, { id = t.mark, right_gravity = false })
  t.hl_mark = api.nvim_buf_set_extmark(S.buf, ns, row, 0, {
    id = t.hl_mark,
    end_row = row,
    end_col = #text,
    hl_group = style.line,
    priority = 150,
  })
  t.icon_mark = api.nvim_buf_set_extmark(S.buf, ns, row, 2, {
    id = t.icon_mark,
    end_row = row,
    end_col = 2 + #style.icon,
    hl_group = style.icon_hl,
    priority = 160,
  })
  local name_from = 2 + #style.icon + 1
  if t.name then
    t.name_mark = api.nvim_buf_set_extmark(S.buf, ns, row, name_from, {
      id = t.name_mark,
      end_row = row,
      end_col = math.min(name_from + #t.name, #text),
      hl_group = style.name,
      priority = 160,
    })
  end
end

function R.spinner_tick()
  S.spinner = S.spinner % #FRAMES + 1
  R.update_winbar()
  for id, t in pairs(S.tools) do
    if t.status == "running" then R.redraw_tool(id) end
  end
end

function R.stop_timer()
  if S.timer then
    S.timer:stop()
    S.timer:close()
    S.timer = nil
  end
end

function R.ensure_timer()
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
        R.stop_timer()
        R.update_winbar()
        return
      end
      R.spinner_tick()
    end)
  )
end

-- welcome -----------------------------------------------------------------

---Centered, composed opening screen: mark, wordmark, model, and a whisper of keys.
function R.show_welcome()
  if not util.buf_valid(S.buf) then return end
  local lc = api.nvim_buf_line_count(S.buf)
  local first = api.nvim_buf_get_lines(S.buf, 0, 1, false)[1]
  if lc > 1 or (first and first ~= "") then return end
  -- panel width for centering (minus the 1-col statuscolumn gutter)
  local w = util.win_valid(S.win) and (api.nvim_win_get_width(S.win) - 1) or 56
  local function centered(text, hl)
    local pad = math.max(0, math.floor((w - api.nvim_strwidth(text)) / 2))
    return { { string.rep(" ", pad) .. text, hl } }
  end
  local virt = {
    { { "", "" } },
    { { "", "" } },
    centered(ICON, "AdvAccent"),
    { { "", "" } },
    centered("advantage", "AdvWelcome"),
    centered(S.model_label ~= "" and S.model_label or "…", "AdvWelcomeDim"),
    { { "", "" } },
    { { "", "" } },
    centered("⏎ send · @ file · ⌃v image", "AdvWelcomeDim"),
    centered("/ commands · g? help", "AdvWelcomeDim"),
  }
  -- reuse the extmark id so repeated opens never stack duplicate banners
  S.welcome_mark = api.nvim_buf_set_extmark(S.buf, ns_extra, 0, 0, {
    id = S.welcome_mark,
    virt_lines = virt,
  })
end

-- prompt input chrome -----------------------------------------------------

function R.input_placeholder()
  if not util.buf_valid(S.input_buf) then return end
  api.nvim_buf_clear_namespace(S.input_buf, ns_extra, 0, -1)
  local lines = api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    api.nvim_buf_set_extmark(S.input_buf, ns_extra, 0, 0, {
      virt_text = { { "describe a task…  ⏎ send · @ file · / commands", "AdvWelcomeDim" } },
      virt_text_pos = "overlay",
    })
  end
end

---Grow/shrink the prompt window with its content (wrapped display lines).
function R.resize_input()
  if not (util.win_valid(S.input_win) and util.buf_valid(S.input_buf)) then return end
  -- the ❯ gutter (statuscolumn) takes 2 cells of every line
  local width = math.max(1, api.nvim_win_get_width(S.input_win) - 2)
  local h = 0
  for _, l in ipairs(api.nvim_buf_get_lines(S.input_buf, 0, -1, false)) do
    h = h + math.max(1, math.ceil(api.nvim_strwidth(l) / width))
  end
  local min_h = config.options.ui.input_height
  local max_h = math.max(min_h, math.floor(vim.o.lines * 0.4))
  h = math.min(math.max(h, min_h), max_h)
  if api.nvim_win_get_height(S.input_win) ~= h then api.nvim_win_set_height(S.input_win, h) end
end

-- streamed transcript writes ----------------------------------------------

function R.stream_chunk(text)
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
function R.start_block()
  local row = last_row()
  local last = api.nvim_buf_get_lines(S.buf, row, row + 1, false)[1] or ""
  if last == "" then return end
  if S.last_kind == "header" then
    append({ "" })
  else
    append({ "", "" })
  end
end

return R
