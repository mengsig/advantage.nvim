---@brief Highlight groups derived from the active colorscheme, so the panel
---looks native to any theme while keeping its own identity.
local M = {}

local function get_color(names, attr)
  for _, name in ipairs(names) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl and hl[attr] then return hl[attr] end
  end
  return nil
end

local function to_rgb(int)
  return math.floor(int / 65536) % 256, math.floor(int / 256) % 256, int % 256
end

local function hex(int)
  local r, g, b = to_rgb(int)
  return string.format("#%02x%02x%02x", r, g, b)
end

---Blend color `a` over `b` with opacity `t` (0..1).
local function blend(a, b, t)
  local ar, ag, ab = to_rgb(a)
  local br, bg, bb = to_rgb(b)
  local r = math.floor(ar * t + br * (1 - t) + 0.5)
  local g = math.floor(ag * t + bg * (1 - t) + 0.5)
  local bl = math.floor(ab * t + bb * (1 - t) + 0.5)
  return string.format("#%02x%02x%02x", r, g, bl)
end

---Resolve the color palette from the active colorscheme (with config accent
---override) and precompute the blended tints the groups use.
local function resolve_palette(cfg, dark)
  assert(type(cfg) == "table" and type(cfg.ui) == "table", "resolve_palette: config with ui required")
  local bg = get_color({ "Normal" }, "bg") or (dark and 0x14141c or 0xf4f2ec)
  local fg = get_color({ "Normal" }, "fg") or (dark and 0xd8dae8 or 0x2a2a33)
  local accent
  if cfg.ui.accent then
    accent = tonumber((cfg.ui.accent --[[@as string]]):gsub("#", ""), 16)
  else
    accent = get_color({ "Function", "Title", "Directory" }, "fg") or (dark and 0x8ec1a8 or 0x3a7a5e)
  end
  return {
    bg = bg,
    fg = fg,
    warn = get_color({ "DiagnosticWarn", "WarningMsg" }, "fg") or 0xd8a657,
    err = get_color({ "DiagnosticError", "ErrorMsg" }, "fg") or 0xd75f5f,
    ok_c = get_color({ "DiagnosticOk", "String" }, "fg") or 0x89b482,
    comment = get_color({ "Comment" }, "fg") or (dark and 0x6b6f85 or 0x8a8a92),
    accent_hex = hex(accent),
    soft = blend(accent, bg, dark and 0.16 or 0.12), -- tinted header wash
    faint = blend(fg, bg, 0.45),
    ghost = blend(fg, bg, 0.28),
  }
end

---Build the highlight-group attribute table from a resolved palette.
local function highlight_groups(p)
  assert(type(p) == "table" and p.accent_hex ~= nil, "highlight_groups: resolved palette required")
  return {
    AdvAccent = { fg = p.accent_hex },
    AdvUserHead = { fg = hex(p.fg), bg = p.soft, bold = true },
    AdvUserBar = { fg = p.accent_hex, bg = p.soft, bold = true },
    AdvAssistHead = { fg = p.accent_hex, bold = true },
    AdvMeta = { fg = p.ghost, italic = true },
    AdvThinking = { fg = hex(p.comment), italic = true },
    AdvToolPending = { fg = p.faint },
    AdvToolRunning = { fg = hex(p.warn) },
    AdvToolOk = { fg = hex(p.ok_c) },
    AdvToolErr = { fg = hex(p.err) },
    AdvToolDenied = { fg = p.ghost, strikethrough = true },
    AdvToolName = { fg = hex(p.fg), bold = true },
    AdvToolDetail = { fg = p.faint },
    AdvToolOutput = { fg = p.faint },
    AdvWelcome = { fg = p.accent_hex, bold = true },
    AdvWelcomeDim = { fg = p.ghost },
    AdvBarIcon = { fg = p.accent_hex, bold = true },
    AdvBarTitle = { fg = hex(p.fg), bold = true },
    AdvBarFaint = { fg = p.ghost },
    AdvBarInfo = { fg = p.faint },
    AdvBarBusy = { fg = hex(p.warn), bold = true },
    AdvBarDanger = { fg = hex(p.err), bold = true },
    AdvFloatTitle = { fg = p.accent_hex, bold = true },
    AdvFloatHint = { fg = p.ghost, italic = true },
    AdvRule = { fg = blend(p.fg, p.bg, 0.12) },
    AdvNotice = { fg = hex(p.warn), italic = true },
  }
end

function M.setup()
  local cfg = require("advantage.config").options
  local dark = vim.o.background ~= "light"
  local palette = resolve_palette(cfg, dark)

  local set = vim.api.nvim_set_hl
  for name, attrs in pairs(highlight_groups(palette)) do
    set(0, name, attrs)
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("AdvantageHl", { clear = true }),
    callback = function()
      M.setup()
    end,
  })
end

return M
