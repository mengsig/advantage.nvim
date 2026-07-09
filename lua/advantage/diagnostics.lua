---@brief Editor-native diagnostic feedback loop. After the agent edits a file
---we surface the NEWLY-introduced LSP/linter diagnostics (errors by default) so
---the model can self-correct without guessing a build command — and we do it
---with strict context discipline: severity floor, a hard line cap, a before/after
---diff so pre-existing noise isn't re-reported, and total silence on a clean edit.
---
---When a file the agent touches has no diagnostic provider at all (no LSP client
---attached and nothing publishing to vim.diagnostic), the plugin tells the USER
---deterministically — once per filetype — to install a language server, rather
---than routing that observation through the model.
local M = {}

local uv = vim.uv or vim.loop
local util = require("advantage.util")

local function diag_available()
  return vim.diagnostic ~= nil and vim.lsp ~= nil
end

local SEV = (vim.diagnostic and vim.diagnostic.severity) or { ERROR = 1, WARN = 2, INFO = 3, HINT = 4 }
local SEV_LABEL = { [1] = "error", [2] = "warn", [3] = "info", [4] = "hint" }
local MAX_MSG = 160

-- Filetypes never expected to have a language server; suppress the "install an
-- LSP" nudge for them so editing a README or a config file isn't noisy.
local NO_LSP_EXPECTED = {
  [""] = true,
  text = true,
  markdown = true,
  gitcommit = true,
  gitrebase = true,
  help = true,
  log = true,
  conf = true,
  ["diff"] = true,
}

M._notified = {} -- filetype -> true, so the missing-LSP nudge fires once per ft

local function cfg()
  local t = (require("advantage.config").options.tools or {}).diagnostics
  return type(t) == "table" and t or {}
end

local function severity_floor(name)
  name = name or "error"
  if name == "all" then return SEV.HINT end
  if name == "warn" or name == "warning" then return SEV.WARN end
  if name == "info" then return SEV.INFO end
  if name == "hint" then return SEV.HINT end
  return SEV.ERROR
end

local function sev_desc(name)
  local floor = severity_floor(name)
  if floor >= SEV.HINT then return "diagnostics" end
  if floor >= SEV.WARN then return "errors or warnings" end
  return "errors"
end

local function shortname(path)
  local cwd = uv.cwd()
  if cwd and path:sub(1, #cwd + 1) == cwd .. "/" then return path:sub(#cwd + 2) end
  return path
end

local function normalize(msg)
  return (vim.trim(tostring(msg or "")):gsub("%s+", " "))
end

---An already-loaded buffer whose name is `path` (absolute), or nil. Matches on the
---exact name first (cheap), then on realpath-equality — so an editor buffer opened
---via a symlink, a differently-normalized path, or a relative `:edit` still counts
---as "already open". This matters for speed: reusing the user's WARM buffer (whose
---server has the file open and indexed) makes an LSP query near-instant, whereas
---missing the match cold-loads a duplicate buffer and pays the attach/open latency
---again — the difference between a snappy nav call and one that times out.
local function loaded_bufnr(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then return b end
  end
  local target = uv.fs_realpath(path)
  if not target then return nil end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and uv.fs_realpath(name) == target then return b end
    end
  end
  return nil
end

---A loaded buffer for `path`, loading it (unlisted) so an LSP can attach. Only
---for existing files; returns nil otherwise.
---
---`bufload` reads the file into the buffer *before* firing BufReadPost/FileType
---autocmds, so an unrelated autocmd throwing (most commonly another LSP client
---racing to attach while a sibling buffer of the same filetype is mid-startup —
---observed loading several fresh Zig buffers back to back) makes the pcall
---report failure even though the buffer's text loaded fine. Trust
---nvim_buf_is_loaded over the pcall result so that transient autocmd noise
---doesn't permanently fail "could not open" a file that's actually sitting
---in a valid buffer.
---Load `bufnr` without ever raising an interactive swap-file (E325) prompt.
---These buffers are ephemeral and read-only, so a stale/foreign swap file is
---irrelevant: we disable swap for the buffer before loading, and additionally
---auto-answer any SwapExists with "edit anyway" so an existing swap owned by
---another process can never block the headless agent on a modal prompt.
local function bufload_no_swap(bufnr)
  pcall(function()
    vim.bo[bufnr].swapfile = false
  end)
  local au = vim.api.nvim_create_autocmd("SwapExists", {
    callback = function()
      vim.v.swapchoice = "e"
    end,
  })
  -- bufload is synchronous, so the guard covers exactly this load and nothing else.
  local ok = pcall(vim.fn.bufload, bufnr)
  pcall(vim.api.nvim_del_autocmd, au)
  return ok
end

local function ensure_bufnr(path)
  local b = loaded_bufnr(path)
  if b then return b end
  if not uv.fs_stat(path) then return nil end
  local ok, bufnr = pcall(vim.fn.bufadd, path)
  if not ok or not bufnr or bufnr == 0 then return nil end
  pcall(function()
    vim.bo[bufnr].buflisted = false
  end)
  if not bufload_no_swap(bufnr) and not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  return bufnr
end

---A position-independent signature set of a buffer's diagnostics at/above
---`severity` (keyed by severity + normalized message so a line shift from an
---unrelated edit doesn't re-flag a pre-existing problem as new).
function M.signatures(bufnr, severity)
  local set = {}
  if not diag_available() or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return set end
  local floor = severity_floor(severity)
  for _, d in ipairs(vim.diagnostic.get(bufnr, {})) do
    if (d.severity or SEV.ERROR) <= floor then set[(d.severity or SEV.ERROR) .. "|" .. normalize(d.message)] = true end
  end
  return set
end

---Snapshot a file's current diagnostics *before* an edit, for the after/before
---diff. Only for files already open (an unopened file has no pre-edit state to
---diff against); returns nil otherwise.
function M.snapshot(path, severity)
  local c = cfg()
  if c.enabled == false or c.auto == false or not diag_available() then return nil end
  local b = loaded_bufnr(path)
  if not b then return nil end
  return M.signatures(b, severity)
end

---Render a compact, capped block of a buffer's diagnostics at/above `severity`.
---With `opts.before` (a signature set) only diagnostics NOT in it are shown.
---Returns the text block, or nil when there is nothing to report.
function M.render(bufnr, opts)
  opts = opts or {}
  if not diag_available() or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local floor = severity_floor(opts.severity)
  local before = opts.before
  local kept = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr, {})) do
    local sev = d.severity or SEV.ERROR
    if sev <= floor then
      if not (before and before[sev .. "|" .. normalize(d.message)]) then kept[#kept + 1] = d end
    end
  end
  if #kept == 0 then return nil end
  table.sort(kept, function(a, b)
    local sa, sb = a.severity or SEV.ERROR, b.severity or SEV.ERROR
    if sa ~= sb then return sa < sb end
    return (a.lnum or 0) < (b.lnum or 0)
  end)
  local max = tonumber(opts.max) or 10
  local lines = {}
  for i = 1, math.min(#kept, max) do
    local d = kept[i]
    local msg = normalize(d.message)
    if #msg > MAX_MSG then msg = util.utf8_safe_sub(msg, MAX_MSG) .. "…" end
    local src = (d.source and d.source ~= "") and (" [" .. d.source .. "]") or ""
    lines[#lines + 1] = ("  L%d:%d %s: %s%s"):format(
      (d.lnum or 0) + 1,
      (d.col or 0) + 1,
      SEV_LABEL[d.severity or SEV.ERROR],
      msg,
      src
    )
  end
  if #kept > max then lines[#lines + 1] = ("  … +%d more"):format(#kept - max) end
  return table.concat(lines, "\n")
end

---Does `ft` list `ft`? Small helper shared by the running/configured checks.
local function fts_include(fts, ft)
  if type(fts) == "table" then
    for _, f in ipairs(fts) do
      if f == ft then return true end
    end
  elseif fts == nil then
    return true -- no declared filetypes: may attach to anything
  end
  return false
end

---Is a language server that handles `ft` running OR enabled-but-not-yet-attached?
---Used to decide, without loading a buffer, whether editing an unopened file of
---that filetype could yield diagnostics at all. We must consult *configured*
---servers too (Neovim 0.11+ `vim.lsp.enable`), not just running ones — servers
---attach lazily on the first matching buffer, so a repo with a correctly set up
---server but no open buffer of that ft would otherwise trip a false "no LSP" nudge.
local function server_available_for_ft(ft)
  if not ft or ft == "" then return false end
  for _, cl in ipairs(vim.lsp.get_clients({})) do
    local conf = cl.config --[[@as table?]]
    if fts_include(conf and conf.filetypes, ft) then return true end
  end
  -- Enabled-but-not-running configs (vim.lsp.enable, Neovim 0.11+).
  local enabled = vim.lsp._enabled_configs
  if type(enabled) == "table" and vim.lsp.config then
    for name in pairs(enabled) do
      local ok, conf = pcall(function()
        return vim.lsp.config[name]
      end)
      if ok and type(conf) == "table" and fts_include(conf.filetypes, ft) then return true end
    end
  end
  return false
end

---Fire the deterministic, once-per-filetype nudge for a filetype string.
local function notify_missing_ft(ft)
  local c = cfg()
  if c.notify_missing == false or not ft or ft == "" then return end
  if M._notified[ft] or NO_LSP_EXPECTED[ft] then return end
  if server_available_for_ft(ft) then return end
  M._notified[ft] = true
  local msg = ("no language server attached for '%s' files — install/configure one to get diagnostic feedback on edits"):format(
    ft
  )
  pcall(function()
    local ui = require("advantage.ui.chat")
    -- A transient toast is easy to miss if you step away, so the durable record
    -- is a persistent line in the chat transcript (scrollback); the WARN toast is
    -- just for immediate attention while you're watching.
    ui.notice("⚠ " .. msg)
    ui.notify(msg, vim.log.levels.WARN)
  end)
end
M._notify_missing_ft = notify_missing_ft

---Deterministic, once-per-filetype nudge to the USER (never the model) when a
---touched buffer has no diagnostic provider at all.
function M._maybe_notify_missing(bufnr)
  if not diag_available() or not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- A server is attached, or something (a linter) already publishes diagnostics:
  -- capability exists, nothing to nag about.
  if #vim.lsp.get_clients({ bufnr = bufnr }) > 0 then return end
  if #vim.diagnostic.get(bufnr, {}) > 0 then return end
  notify_missing_ft(vim.bo[bufnr].filetype or "")
end

---Wait (bounded) for the buffer's diagnostics to settle after an edit, then call
---`done()`. Fires on the first DiagnosticChanged (debounced), with a hard ceiling
---so a clean edit that produces no change event still returns.
local function wait_for_diagnostics(bufnr, wait_ms, done)
  local finished, debounce, hard, au = false, nil, nil, nil
  local function cleanup()
    if au then
      pcall(vim.api.nvim_del_autocmd, au)
      au = nil
    end
    if debounce then
      debounce:stop()
      pcall(function()
        debounce:close()
      end)
      debounce = nil
    end
    if hard then
      hard:stop()
      pcall(function()
        hard:close()
      end)
      hard = nil
    end
  end
  local function finalize()
    if finished then return end
    finished = true
    cleanup()
    done()
  end
  local function bump()
    if not debounce then debounce = assert(uv.new_timer()) end
    debounce:stop()
    debounce:start(250, 0, vim.schedule_wrap(finalize))
  end
  au = vim.api.nvim_create_autocmd("DiagnosticChanged", {
    buffer = bufnr,
    callback = bump,
  })
  hard = assert(uv.new_timer())
  hard:start(math.max(200, wait_ms), 0, vim.schedule_wrap(finalize))
end

---Wait until a server is attached to `bufnr` (polling up to a short grace for a
---freshly-loaded buffer's client to come up), then wait for diagnostics to
---settle, then call `done()`.
local function await_ready(bufnr, c, done)
  local wait_ms = tonumber(c.wait_ms) or 1500
  local grace = tonumber(c.attach_grace_ms) or 250
  local function has_clients()
    return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
  end
  if has_clients() then return wait_for_diagnostics(bufnr, wait_ms, done) end
  local elapsed, iv = 0, 50
  local t = assert(uv.new_timer())
  t:start(
    iv,
    iv,
    vim.schedule_wrap(function()
      elapsed = elapsed + iv
      if has_clients() or elapsed >= grace then
        t:stop()
        pcall(function()
          t:close()
        end)
        return wait_for_diagnostics(bufnr, wait_ms, done)
      end
    end)
  )
end

---Auto-attach entry point: called after a successful mutating edit. `before` is
---the pre-edit signature set (may be nil). Calls `cb(extra)` where `extra` is a
---trailing block of newly-introduced diagnostics to append to the tool result,
---or nil when there is nothing worth reporting (or the feature is off).
---
---Fast-path discipline: if the edited file isn't open and no server for its
---filetype is running, we can't produce diagnostics anyway, so we return
---synchronously (no buffer load, no wait) after a cheap once-per-filetype
---missing-LSP nudge — a no-LSP repo pays zero per-edit overhead.
function M.after_edit(path, before, cb)
  local c = cfg()
  if c.enabled == false or c.auto == false or not diag_available() then return cb(nil) end
  local bufnr = loaded_bufnr(path)
  if bufnr then
    if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 and #vim.diagnostic.get(bufnr, {}) == 0 then
      M._maybe_notify_missing(bufnr)
      return cb(nil)
    end
  else
    local ft = (vim.filetype.match({ filename = path })) or ""
    if not server_available_for_ft(ft) then
      notify_missing_ft(ft)
      return cb(nil)
    end
    bufnr = ensure_bufnr(path)
    if not bufnr then return cb(nil) end
  end
  local severity, max = c.severity or "error", tonumber(c.max) or 10
  await_ready(bufnr, c, function()
    local text = M.render(bufnr, { severity = severity, max = max, before = before })
    if not text then return cb(nil) end
    local header = before and "diagnostics (new since this edit):" or "diagnostics in this file:"
    cb("\n\n" .. header .. "\n" .. text)
  end)
end

---Diagnostics across every currently-open buffer (no waiting, no loading),
---capped per file and by file count so a noisy workspace can't flood context.
function M.workspace(severity)
  if not diag_available() then return "Diagnostics are unavailable in this Neovim." end
  local MAX_FILES = 8
  local blocks, files = {}, 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local text = M.render(b, { severity = severity, max = 15 })
      if text then
        files = files + 1
        if files <= MAX_FILES then blocks[#blocks + 1] = shortname(vim.api.nvim_buf_get_name(b)) .. ":\n" .. text end
      end
    end
  end
  if #blocks == 0 then return ("No %s in open files."):format(sev_desc(severity)) end
  if files > MAX_FILES then
    blocks[#blocks + 1] = ("… and %d more file(s) with diagnostics"):format(files - MAX_FILES)
  end
  return table.concat(blocks, "\n\n")
end

---Explicit `diagnostics` tool backend. With `path`, load the file, wait for a
---reading, and report its current diagnostics; without, report across open files.
function M.report(path, severity, cb)
  if not diag_available() then return cb("Diagnostics are unavailable in this Neovim.") end
  severity = severity or "warn"
  if path and path ~= "" then
    local bufnr = ensure_bufnr(path)
    if not bufnr then return cb("Could not open " .. shortname(path) .. " to read diagnostics.") end
    await_ready(bufnr, cfg(), function()
      M._maybe_notify_missing(bufnr)
      local text = M.render(bufnr, { severity = severity, max = 40 })
      if not text then return cb(("No %s in %s."):format(sev_desc(severity), shortname(path))) end
      cb(("%s — diagnostics:\n%s"):format(shortname(path), text))
    end)
  else
    cb(M.workspace(severity))
  end
end

-- Exported for the LSP navigation module (advantage.lsp), which reuses the same
-- buffer-load, attach-detection and filetype→server plumbing so both features
-- share one implementation of that subtle logic.
M.ensure_bufnr = ensure_bufnr
M.loaded_bufnr = loaded_bufnr
M.server_available_for_ft = server_available_for_ft

return M
