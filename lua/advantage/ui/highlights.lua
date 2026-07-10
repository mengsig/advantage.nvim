---@brief Highlight groups derived from the active colorscheme, so the panel
---looks native to any theme while keeping its own identity.
---
---The system: the panel is its own quiet surface (a few percent off Normal),
---the prompt is a slightly deeper field, and exactly one accent color is used
---— for the brand mark, the user bar, and whatever is *live* right now.
---Finished work recedes to ghost text; only errors keep their color.
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
  local ok_c = get_color({ "DiagnosticOk", "String" }, "fg") or 0x89b482
  return {
    bg = bg,
    fg = fg,
    warn = get_color({ "DiagnosticWarn", "WarningMsg" }, "fg") or 0xd8a657,
    err = get_color({ "DiagnosticError", "ErrorMsg" }, "fg") or 0xd75f5f,
    ok_c = ok_c,
    comment = get_color({ "Comment" }, "fg") or (dark and 0x6b6f85 or 0x8a8a92),
    accent_hex = hex(accent),
    -- surfaces: the panel sits a few percent off Normal, the prompt field a
    -- little deeper — enough to read as places, never enough to shout
    panel = blend(fg, bg, dark and 0.035 or 0.04),
    field = blend(fg, bg, dark and 0.075 or 0.075),
    soft = blend(accent, bg, dark and 0.16 or 0.12), -- tinted header wash
    faint = blend(fg, bg, 0.45),
    ghost = blend(fg, bg, 0.28),
    hairline = blend(fg, bg, 0.12),
    border = blend(fg, bg, 0.25),
  }
end

---Build the highlight-group attribute table from a resolved palette.
local function highlight_groups(p)
  assert(type(p) == "table" and p.accent_hex ~= nil, "highlight_groups: resolved palette required")
  return {
    AdvAccent = { fg = p.accent_hex },

    -- surfaces
    AdvPanel = { bg = p.panel },
    AdvPanelField = { bg = p.field },
    AdvPanelBar = { bg = p.panel },
    AdvPanelBorder = { fg = p.hairline, bg = p.panel },
    AdvPromptSign = { fg = p.accent_hex, bg = p.field, bold = true },

    -- transcript
    AdvUserHead = { fg = hex(p.fg), bg = p.soft, bold = true },
    AdvUserBar = { fg = p.accent_hex, bg = p.soft, bold = true },
    AdvAssistHead = { fg = p.accent_hex, bold = true },
    AdvMeta = { fg = p.ghost, italic = true },
    AdvThinking = { fg = hex(p.comment), italic = true },
    AdvRule = { fg = p.hairline },
    AdvNotice = { fg = p.faint, italic = true },
    AdvNoticeMark = { fg = p.accent_hex },

    -- tool lines: running = yellow, success = green, failure = red
    AdvToolGhost = { fg = p.ghost },
    AdvToolFaint = { fg = p.faint },
    AdvToolSpinner = { fg = p.accent_hex },
    AdvToolWaiting = { fg = p.accent_hex, bold = true },
    AdvToolActiveName = { fg = hex(p.fg) },
    AdvToolRunning = { fg = hex(p.warn) },
    AdvToolOk = { fg = hex(p.ok_c) },
    AdvToolErr = { fg = hex(p.err) },
    AdvToolDenied = { fg = p.ghost, strikethrough = true },
    AdvToolOutput = { fg = p.ghost },

    -- welcome
    AdvWelcome = { fg = p.accent_hex, bold = true },
    AdvWelcomeDim = { fg = p.ghost },

    -- winbar
    AdvBarIcon = { fg = p.accent_hex, bg = p.panel, bold = true },
    AdvBarTitle = { fg = hex(p.fg), bg = p.panel, bold = true },
    AdvBarFaint = { fg = p.ghost, bg = p.panel },
    AdvBarInfo = { fg = p.faint, bg = p.panel },
    AdvBarBusy = { fg = p.accent_hex, bg = p.panel },
    AdvBarDanger = { fg = hex(p.err), bg = p.panel, bold = true },

    -- picker
    AdvPickerSel = { bg = p.soft },
    AdvPickerBar = { fg = p.accent_hex, bg = p.soft, bold = true },
    AdvPickerMatch = { fg = p.accent_hex, bold = true },

    -- floats
    AdvFloatTitle = { fg = p.accent_hex, bg = p.panel, bold = true },
    AdvFloatBorder = { fg = p.border, bg = p.panel },
    AdvFloatHint = { fg = p.ghost, bg = p.panel, italic = true },
    AdvFloatKey = { fg = p.accent_hex, bg = p.panel, bold = true },
    AdvFloatLabel = { fg = p.ghost },
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
