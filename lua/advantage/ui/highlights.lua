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

function M.setup()
  local cfg = require("advantage.config").options
  local dark = vim.o.background ~= "light"

  local bg = get_color({ "Normal" }, "bg") or (dark and 0x14141c or 0xf4f2ec)
  local fg = get_color({ "Normal" }, "fg") or (dark and 0xd8dae8 or 0x2a2a33)
  local accent
  if cfg.ui.accent then
    accent = tonumber(cfg.ui.accent:gsub("#", ""), 16)
  else
    accent = get_color({ "Function", "Title", "Directory" }, "fg") or (dark and 0x8ec1a8 or 0x3a7a5e)
  end
  local warn = get_color({ "DiagnosticWarn", "WarningMsg" }, "fg") or 0xd8a657
  local err = get_color({ "DiagnosticError", "ErrorMsg" }, "fg") or 0xd75f5f
  local ok_c = get_color({ "DiagnosticOk", "String" }, "fg") or 0x89b482
  local comment = get_color({ "Comment" }, "fg") or (dark and 0x6b6f85 or 0x8a8a92)

  local accent_hex = hex(accent)
  local soft = blend(accent, bg, dark and 0.16 or 0.12) -- tinted header wash
  local faint = blend(fg, bg, 0.45)
  local ghost = blend(fg, bg, 0.28)

  local set = vim.api.nvim_set_hl
  local groups = {
    AdvAccent = { fg = accent_hex },
    AdvUserHead = { fg = hex(fg), bg = soft, bold = true },
    AdvUserBar = { fg = accent_hex, bg = soft, bold = true },
    AdvAssistHead = { fg = accent_hex, bold = true },
    AdvMeta = { fg = ghost, italic = true },
    AdvThinking = { fg = hex(comment), italic = true },
    AdvToolPending = { fg = faint },
    AdvToolRunning = { fg = hex(warn) },
    AdvToolOk = { fg = hex(ok_c) },
    AdvToolErr = { fg = hex(err) },
    AdvToolDenied = { fg = ghost, strikethrough = true },
    AdvToolName = { fg = hex(fg), bold = true },
    AdvToolDetail = { fg = faint },
    AdvWelcome = { fg = accent_hex, bold = true },
    AdvWelcomeDim = { fg = ghost },
    AdvBarIcon = { fg = accent_hex, bold = true },
    AdvBarTitle = { fg = hex(fg), bold = true },
    AdvBarFaint = { fg = ghost },
    AdvBarInfo = { fg = faint },
    AdvBarBusy = { fg = hex(warn), bold = true },
    AdvFloatTitle = { fg = accent_hex, bold = true },
    AdvFloatHint = { fg = ghost, italic = true },
    AdvRule = { fg = blend(fg, bg, 0.12) },
    AdvNotice = { fg = hex(warn), italic = true },
  }
  for name, attrs in pairs(groups) do
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
