---@brief Editor-native LSP navigation — the harness's semantic-code layer.
---
---read_file + grep make the model read whole files and pay full token price to
---answer "where is this defined / who calls this / what's its type". The editor
---already runs language servers; this module exposes them as read-only tools so
---the agent navigates code semantically — a few tokens per hop — instead:
---  * document_symbols  — a file's outline (kinds, names, lines) without its text
---  * goto_definition   — jump from a use to its definition
---  * find_references   — every call site of a symbol
---  * hover             — the type/signature/doc at a position
---  * workspace_symbol  — find a symbol by name across the repo
---
---All requests are ASYNC (vim.lsp.buf_request_all) with a bounded timeout, so a
---slow server never freezes the editor. Buffer-load / attach-detection plumbing is
---reused from advantage.diagnostics. The raw-response formatters are pure and
---unit-tested; the live request seam (M._buf_request_all) is monkeypatchable.
local M = {}

local uv = vim.uv or vim.loop
local util = require("advantage.util")

---vim.lsp is present in every supported Neovim, but keep the guard so a stripped
---build (or a future headless mode) hides the tools instead of erroring.
function M.available()
  return vim.lsp ~= nil and vim.lsp.buf_request_all ~= nil
end

--------------------------------------------------------------------------------
-- Version-safe primitives (CI covers Neovim 0.10.4 → nightly)
--------------------------------------------------------------------------------

-- The encoding-string form of str_utfindex landed in 0.11; 0.10 only has the
-- 2-arg (byte-index → utf-16) form. `vim.islist` is 0.11+ (was `tbl_islist`).
local HAS_ENC_UTFINDEX = vim.fn.has("nvim-0.11") == 1

-- Pure result formatters live in lsp/format.lua; re-expose the test hooks and the
-- treesitter outline on M so the request layer and the smoke suite keep their
-- existing entry points (lsp._format_symbols, lsp.treesitter_symbols, …).
local format = require("advantage.lsp.format")
M._flatten_symbols = format.flatten_symbols
M._format_flat = format.format_flat
M._format_symbols = format.format_symbols
M.treesitter_symbols = format.treesitter_symbols
M._collect_locations = format.collect_locations
M._format_locations = format.format_locations
M._hover_text = format.hover_text
M._collect_ws = format.collect_ws
M._format_ws = format.format_ws

---Convert a 0-based BYTE column into the LSP `character` offset for `encoding`
---(the count of code units before that byte). A server using utf-16 (the
---default) counts a multi-byte glyph as fewer units than its byte length, so a
---raw byte column would point past the intended character on any non-ASCII line.
---@param text string the full line
---@param byte_col integer 0-based byte offset
---@param encoding string|nil "utf-8" | "utf-16" | "utf-32"
---@return integer
local function utf_offset(text, byte_col, encoding)
  encoding = encoding or "utf-16"
  byte_col = math.max(0, math.min(byte_col, #text))
  if encoding == "utf-8" then return byte_col end
  if HAS_ENC_UTFINDEX then
    local ok, n = pcall(vim.str_utfindex, text, encoding, byte_col)
    return (ok and type(n) == "number") and n or byte_col
  end
  -- Neovim 0.10: the legacy 2-arg form returns TWO values — (utf-32, utf-16) — so
  -- binding the first blindly would hand a utf-32 count to a utf-16 server (wrong
  -- past any astral-plane glyph). Select the value that matches the encoding.
  local ok, utf32, utf16 = pcall(vim.str_utfindex, text, byte_col)
  if not ok then return byte_col end
  local n = (encoding == "utf-32") and utf32 or utf16
  return type(n) == "number" and n or byte_col
end
M._utf_offset = utf_offset

--------------------------------------------------------------------------------
-- Config / small helpers
--------------------------------------------------------------------------------

local function cfg()
  local t = (require("advantage.config").options.tools or {}).lsp
  return type(t) == "table" and t or {}
end

local function allow_outside()
  return (require("advantage.config").options.tools or {}).allow_outside_root == true
end

local function max_results()
  return math.max(1, tonumber(cfg().max_results) or 60)
end

--------------------------------------------------------------------------------
-- Usage nudge: re-surface the tools when the model is grep/read-looping over code
--------------------------------------------------------------------------------
-- A frozen system-prompt steer loses salience as a session grows (the recent
-- transcript, full of grep/read, dominates attention — the model pattern-matches
-- "how we work here" from its own recent moves). This fires a throttled, in-band
-- hint from a grep/read result when the model has been exploring code WITHOUT the
-- LSP tools, but ONLY while a server is actually running (so it never pushes tools
-- that can't work). A single LSP-tool use silences it. Counters reset per session.
local _session = { probes = 0, nudges_left = 3, nav_timeouts = 0, nav_ok = false, nav_skips = 0 }

function M.reset_session()
  _session = { probes = 0, nudges_left = 3, nav_timeouts = 0, nav_ok = false, nav_skips = 0 }
end

---Record that the model used an LSP tool — resets the grep/read streak so an
---already-navigating session never gets nudged.
function M.note_lsp_use()
  _session.probes = 0
end

--------------------------------------------------------------------------------
-- Nav-timeout latch: give up gracefully on a server that won't answer navigation
--------------------------------------------------------------------------------
-- Some servers serve DIAGNOSTICS (pushed incrementally) but block request/response
-- navigation (documentSymbol/references/hover/workspace_symbol) until they finish
-- loading — a large TypeScript monorepo's tsserver can take 30-60s+, well past our
-- retry ceiling. Without this, the model burns the full timeout on every nav call
-- rediscovering that. Once navigation has timed out NAV_LATCH_AT times this session
-- WITHOUT ever succeeding, we short-circuit further nav to an instant, directive
-- grep/read fallback. Any success clears it; a fresh session resets it.
local NAV_LATCH_AT = 2

function M._nav_latched()
  return _session.nav_timeouts >= NAV_LATCH_AT and not _session.nav_ok
end

---Whether the current nav request should be skipped (latched). When latched we skip
---MOST calls to a fast fallback, but let every 4th through as a re-probe — so a
---server that eventually warms up can recover navigation within the same session
---(without it, one latch would kill navigation for the whole session).
function M._nav_should_skip()
  if not M._nav_latched() then return false end
  _session.nav_skips = _session.nav_skips + 1
  return _session.nav_skips % 4 ~= 0
end

---Record the outcome of a navigation request so the latch can trip / clear.
local function note_nav(ok, timed_out)
  if ok then
    _session.nav_ok = true
    _session.nav_timeouts = 0
  elseif timed_out then
    _session.nav_timeouts = _session.nav_timeouts + 1
  end
end

local function nav_latch_msg()
  return "Skipping navigation — the language server here has repeatedly timed out on navigation requests this session (documentSymbol/references/hover) even though it serves diagnostics. Use grep/read_file for this task; navigation may work in a later session once the server is fully warmed."
end

local EXPLORE_HINT =
  "\n\n(a language server is attached here — goto_definition / find_references / document_symbols answer symbol-level questions precisely and in fewer steps than grep+read; prefer them when tracing a definition, callers, or a file's shape.)"

---Called from grep/read_file/find_files. Counts the exploration and returns a
---one-line hint when the streak crosses the threshold, a server is up, and the
---per-session throttle isn't spent; else "". Deterministic, no model call.
function M.explore_nudge()
  _session.probes = _session.probes + 1
  if _session.probes < 4 or _session.nudges_left <= 0 then return "" end
  if not (M.available() and #vim.lsp.get_clients({}) > 0) then return "" end
  _session.probes = 0
  _session.nudges_left = _session.nudges_left - 1
  return EXPLORE_HINT
end

---Display `abs` relative to the project root when it lives inside it; otherwise
---keep it absolute (definitions legitimately land in deps/stdlib outside root).
--------------------------------------------------------------------------------
-- Live request layer (async, bounded)
--------------------------------------------------------------------------------

-- Seam for tests: overridden to feed canned server responses.
M._buf_request_all = function(bufnr, method, params, handler)
  return vim.lsp.buf_request_all(bufnr, method, params, handler)
end

---Ensure `abs` is loaded into a buffer and give a server a bounded grace period to
---attach, then call `cb(bufnr, clients)` (clients may be empty if none attached).
---cb(nil) means the file could not be opened.
---
---The grace period is CONFIGURED-AWARE. A freshly-loaded buffer's server attaches
---asynchronously, and heavy servers (tsserver/vtsls in a big monorepo, jdtls,
---rust-analyzer) can take several seconds just to attach — with the old fixed 1s
---wait they'd read as "no server attached" (a false negative that trains the model
---to abandon LSP for the whole session). So: if a server IS configured for this
---filetype (running elsewhere or enabled), wait the longer `attach_grace_configured_ms`
---for it to come up; if NONE is configured, don't burn the grace polling — fail fast
---so the caller can tell the user to install one.
local function ensure_ready(abs, cb)
  local diagnostics = require("advantage.diagnostics")
  local bufnr = diagnostics.ensure_bufnr(abs)
  if not bufnr then return cb(nil) end
  -- Only count clients that have finished `initialize`: firing documentSymbol at a
  -- still-initializing client is a common way a request hangs to the timeout.
  local function clients()
    local out = {}
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
      if c.initialized ~= false then out[#out + 1] = c end
    end
    return out
  end
  if #clients() > 0 then return cb(bufnr, clients()) end
  local ft = (vim.bo[bufnr] and vim.bo[bufnr].filetype) or ""
  local configured = diagnostics.server_available_for_ft(ft)
  local grace = math.max(0, tonumber(cfg().attach_grace_ms) or 1000)
  if configured then grace = math.max(grace, tonumber(cfg().attach_grace_configured_ms) or 4000) end
  -- No server configured for this language → nothing will attach; return now.
  if grace == 0 or not configured then return cb(bufnr, clients()) end
  local elapsed, iv = 0, 50
  local t = assert(uv.new_timer())
  t:start(
    iv,
    iv,
    vim.schedule_wrap(function()
      elapsed = elapsed + iv
      if #clients() > 0 or elapsed >= grace then
        t:stop()
        pcall(function()
          t:close()
        end)
        cb(bufnr, clients())
      end
    end)
  )
end

---Fire an async LSP request with a hard timeout, AUTO-RETRYING on timeout.
---A server that was just asked to open a file is often still doing its initial
---workspace index, so the FIRST request to a fresh large file can blow the
---timeout while the retry (server now warm) returns instantly — real behavior
---observed on lua-language-server. Rather than make the model burn a turn
---manually retrying, we retry here up to `max_attempts`, extending the window
---each round (the server is mid-index, so give it progressively longer). A real
---error (not a timeout) does not retry. `cb(results, err)`.
local function request(bufnr, method, params, cb)
  local base = math.max(200, tonumber(cfg().timeout_ms) or 4000)
  local max_attempts = math.max(1, math.min(tonumber(cfg().max_attempts) or 2, 4))

  local function attempt(n)
    local fired, timer = false, nil
    local function settle(results, err, timed_out)
      if fired then return end
      fired = true
      if timer then
        timer:stop()
        pcall(function()
          timer:close()
        end)
        timer = nil
      end
      -- Retry only a timeout (the warming-up case), never a hard error, and only
      -- while attempts remain; a short beat lets the index settle before retrying.
      if timed_out and n < max_attempts then
        return vim.defer_fn(function()
          attempt(n + 1)
        end, 150)
      end
      -- Feed the session latch: a genuine response clears it; a final timeout
      -- counts toward tripping it (so we stop burning the timeout on a server
      -- that serves diagnostics but blocks navigation).
      note_nav(not timed_out and results ~= nil, timed_out)
      cb(results, err)
    end
    local ok, cancel = pcall(
      M._buf_request_all,
      bufnr,
      method,
      params,
      vim.schedule_wrap(function(results)
        settle(results, nil, false)
      end)
    )
    if not ok then return settle(nil, "request failed: " .. tostring(cancel), false) end
    timer = assert(uv.new_timer())
    timer:start(
      base * n, -- extend the window on each retry: the server is still indexing
      0,
      vim.schedule_wrap(function()
        if not fired and type(cancel) == "function" then pcall(cancel) end
        settle(
          nil,
          ("the language server didn't respond in time (tried %d×, up to %dms) — it may still be indexing; try again shortly or fall back to read_file/grep"):format(
            n,
            base * n
          ),
          true
        )
      end)
    )
  end

  attempt(1)
end

---A resolved-and-contained absolute path, or nil + a user-facing error string.
local function resolve_input(path, cwd)
  local abs, err = util.contain(path, cwd, allow_outside())
  if not abs then return nil, ("Cannot resolve %s: %s"):format(tostring(path), err) end
  return abs
end

local function ft_of(bufnr, abs)
  local ft = vim.bo[bufnr] and vim.bo[bufnr].filetype
  if ft and ft ~= "" then return ft end
  return vim.filetype.match({ filename = abs }) or "?"
end

local function no_server_msg(bufnr, abs)
  return ("No language server is attached for '%s' files — LSP navigation needs one. Install/configure a server (see the README's language-server list) or fall back to read_file/grep."):format(
    ft_of(bufnr, abs)
  )
end

---Report "no server" to the model AND surface it to the USER once per filetype,
---so a silent grep-fallback never hides that the language simply isn't set up for
---navigation — the user needs to know to install a server. Reuses the diagnostics
---missing-server nudge, which is deduped and no-ops when a server IS configured for
---the ft (so a merely-slow attach never nags).
local function no_server(bufnr, abs, cb)
  local ft = ft_of(bufnr, abs)
  if ft ~= "" and ft ~= "?" then pcall(function()
    require("advantage.diagnostics")._notify_missing_ft(ft)
  end) end
  cb(no_server_msg(bufnr, abs), false)
end

---True if any attached client advertises the given server capability. Firing a
---request at clients that DON'T support the method makes Neovim print
---"method X is not supported by any server activated for this buffer" and the
---request goes nowhere — a real failure mode when the attached client is a
---diagnostics/lint-only source (eslint, none-ls, biome, a limited tsserver) that
---serves diagnostics but not navigation. Capability-checking first avoids the
---error and lets us fall back cleanly (treesitter for outlines, grep for the rest).
local function any_supports(clients, cap)
  for _, c in ipairs(clients) do
    local sc = c.server_capabilities
    if sc and sc[cap] then return true end
  end
  return false
end

--------------------------------------------------------------------------------
-- Public tool backends: cb(text, is_error)
--------------------------------------------------------------------------------

---Answer document_symbols without the LSP — no server attached, navigation
---latched, or no attached client supports documentSymbol (a diagnostics/lint-only
---client does not, and asking anyway makes Neovim print "method not supported").
---An outline is pure syntax, so treesitter covers all of these. Returns true when
---it has answered via `cb`.
local function document_symbols_offline(cb, bufnr, abs, clients, supports, ts_fn)
  assert(type(cb) == "function" and type(ts_fn) == "function", "document_symbols_offline: callbacks required")
  if not (#clients == 0 or M._nav_should_skip() or not supports) then return false end
  local ts = ts_fn()
  if ts then
    cb(ts, false)
    return true
  end
  if #clients == 0 then
    no_server(bufnr, abs, cb)
    return true
  end
  if not supports then
    cb(
      ("No attached language server provides document symbols for '%s' files, and no treesitter parser is available here — use read_file/grep."):format(
        ft_of(bufnr, abs)
      ),
      false
    )
    return true
  end
  cb(nav_latch_msg(), false)
  return true
end

---Merge a documentSymbol response and render it, falling back to treesitter on an
---LSP error/timeout or an empty result so an outline still comes back.
local function render_document_symbols(cb, label, ts_fn, results, rerr)
  assert(type(cb) == "function" and type(ts_fn) == "function", "render_document_symbols: callbacks required")
  if rerr then
    local ts = ts_fn("outline via treesitter — the language server didn't respond")
    if ts then return cb(ts, false) end
    return cb("documentSymbol " .. rerr, true)
  end
  local merged = {}
  for _, v in pairs(results or {}) do
    for _, s in ipairs((v and v.result) or {}) do
      merged[#merged + 1] = s
    end
  end
  local text = M._format_symbols(label, merged, max_results())
  if text then return cb(text, false) end
  -- Server answered but with no symbols → try treesitter before giving up.
  local ts = ts_fn()
  if ts then return cb(ts, false) end
  cb(("No symbols reported for %s (the server may still be indexing, or the file defines none)."):format(label), false)
end

function M.document_symbols(path, cwd, cb)
  M.note_lsp_use()
  local abs, err = resolve_input(path, cwd)
  if not abs then return cb(err, true) end
  ensure_ready(abs, function(bufnr, clients)
    if not bufnr then return cb("File not found: " .. tostring(path), true) end
    local label = format.rel(cwd, abs)
    local function treesitter(note)
      local flat = M.treesitter_symbols(bufnr)
      return flat and M._format_flat(label, flat, max_results(), note) or nil
    end
    local supports = any_supports(clients, "documentSymbolProvider")
    if document_symbols_offline(cb, bufnr, abs, clients, supports, treesitter) then return end
    request(
      bufnr,
      "textDocument/documentSymbol",
      { textDocument = { uri = vim.uri_from_bufnr(bufnr) } },
      function(results, rerr)
        render_document_symbols(cb, label, treesitter, results, rerr)
      end
    )
  end)
end

---Resolve a {line, symbol?, column?} target on `bufnr` into an *encoding-agnostic*
---position: a 0-based line, the 0-based BYTE column, and the line's text. The byte
---column is encoded per-client at request time (position_params), so a buffer with
---clients of differing offset_encodings stays correct.
---@return {line0:integer, byte_col:integer, text:string}|nil posinfo, integer|nil used_line1, string|nil err
local function build_position(bufnr, line1, symbol, column1)
  local total = vim.api.nvim_buf_line_count(bufnr)
  line1 = tonumber(line1)
  if not line1 or line1 < 1 then return nil, nil, "a 1-based `line` is required to locate the symbol" end
  if line1 > total then return nil, nil, ("line %d is past the end of the file (%d lines)"):format(line1, total) end
  local function line_str(l)
    return (vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false))[1] or ""
  end
  local target_line, byte_col
  if tonumber(column1) and tonumber(column1) >= 1 then
    target_line, byte_col = line1, tonumber(column1) - 1
  elseif symbol and symbol ~= "" then
    -- Tolerate a slightly-stale line number: check the given line first, then a
    -- small window around it, and use the first occurrence found.
    local found
    for _, off in ipairs({ 0, -1, 1, -2, 2, -3, 3 }) do
      local l = line1 + off
      if l >= 1 and l <= total then
        local idx = line_str(l):find(symbol, 1, true)
        if idx then
          found = { l = l, col = idx - 1 }
          break
        end
      end
    end
    if not found then
      return nil,
        nil,
        ("symbol %q not found on or near line %d — check the line, or pass an explicit `column`"):format(
          symbol,
          line1
        )
    end
    target_line, byte_col = found.l, found.col
  else
    local idx = line_str(line1):find("%S")
    target_line, byte_col = line1, (idx or 1) - 1
  end
  return { line0 = target_line - 1, byte_col = byte_col, text = line_str(target_line) }, target_line, nil
end

-- The per-client function form of buf_request_all (params(client, bufnr)) landed
-- in 0.11, the same boundary as the encoding-aware str_utfindex.
local USE_FN_PARAMS = vim.fn.has("nvim-0.11") == 1

---Build the `params` for a positional request. On 0.11+ this returns a FUNCTION so
---buf_request_all lets each client encode the byte column with ITS OWN
---offset_encoding — clients on one buffer can disagree (clangd negotiates utf-8
---while most default to utf-16), and one baked-in offset would land at the wrong
---character for the others on any non-ASCII line. On 0.10 (no function form) it
---falls back to the primary client's encoding.
local function position_params(uri, posinfo, clients, extra)
  local function build(enc)
    local p = {
      textDocument = { uri = uri },
      position = { line = posinfo.line0, character = utf_offset(posinfo.text, posinfo.byte_col, enc) },
    }
    return extra and vim.tbl_extend("force", p, extra) or p
  end
  if USE_FN_PARAMS then
    return function(client)
      return build((client and client.offset_encoding) or "utf-16")
    end
  end
  return build((clients[1] and clients[1].offset_encoding) or "utf-16")
end
M._position_params = position_params

---Shared driver for definition/references (both are position → locations).
local function location_query(method, header_fn, extra_params, path, cwd, line, symbol, column, cb)
  M.note_lsp_use()
  local abs, err = resolve_input(path, cwd)
  if not abs then return cb(err, true) end
  ensure_ready(abs, function(bufnr, clients)
    if not bufnr then return cb("File not found: " .. tostring(path), true) end
    if #clients == 0 then return no_server(bufnr, abs, cb) end
    local cap = method == "textDocument/references" and "referencesProvider" or "definitionProvider"
    if not any_supports(clients, cap) then
      return cb(
        ("No attached language server provides %s for '%s' files (the attached client only does diagnostics/lint) — use grep/read to locate it."):format(
          method:match("[^/]+$"),
          ft_of(bufnr, abs)
        ),
        false
      )
    end
    if M._nav_should_skip() then return cb(nav_latch_msg(), false) end
    local posinfo, used_line, perr = build_position(bufnr, line, symbol, column)
    if not posinfo then return cb(perr, true) end
    local params = position_params(vim.uri_from_bufnr(bufnr), posinfo, clients, extra_params)
    request(bufnr, method, params, function(results, rerr)
      if rerr then return cb(method:match("[^/]+$") .. " " .. rerr, true) end
      local locs = format.collect_locations(results)
      if #locs == 0 then
        return cb(("No %s found for the symbol at line %d."):format(header_fn("noun"), used_line), false)
      end
      cb(M._format_locations(header_fn("header", symbol, used_line), locs, cwd, max_results()), false)
    end)
  end)
end

function M.definition(path, cwd, line, symbol, column, cb)
  location_query("textDocument/definition", function(what, sym)
    if what == "noun" then return "definition" end
    return sym and sym ~= "" and ("definition of " .. sym) or "definition"
  end, nil, path, cwd, line, symbol, column, cb)
end

function M.references(path, cwd, line, symbol, column, cb)
  location_query("textDocument/references", function(what, sym)
    if what == "noun" then return "references" end
    return sym and sym ~= "" and ("references to " .. sym) or "references"
  end, { context = { includeDeclaration = true } }, path, cwd, line, symbol, column, cb)
end

function M.hover(path, cwd, line, symbol, column, cb)
  M.note_lsp_use()
  local abs, err = resolve_input(path, cwd)
  if not abs then return cb(err, true) end
  ensure_ready(abs, function(bufnr, clients)
    if not bufnr then return cb("File not found: " .. tostring(path), true) end
    if #clients == 0 then return no_server(bufnr, abs, cb) end
    if not any_supports(clients, "hoverProvider") then
      return cb(
        ("No attached language server provides hover for '%s' files — read the definition to see the type."):format(
          ft_of(bufnr, abs)
        ),
        false
      )
    end
    if M._nav_should_skip() then return cb(nav_latch_msg(), false) end
    local posinfo, used_line, perr = build_position(bufnr, line, symbol, column)
    if not posinfo then return cb(perr, true) end
    request(
      bufnr,
      "textDocument/hover",
      position_params(vim.uri_from_bufnr(bufnr), posinfo, clients, nil),
      function(results, rerr)
        if rerr then return cb("hover " .. rerr, true) end
        local text
        for _, v in pairs(results or {}) do
          text = v and v.result and format.hover_text(v.result.contents)
          if text then break end
        end
        if not text then return cb(("No hover info for the symbol at line %d."):format(used_line), false) end
        cb(text, false)
      end
    )
  end)
end

function M.workspace_symbol(query, cwd, cb)
  M.note_lsp_use()
  query = vim.trim(tostring(query or ""))
  if query == "" then return cb("Empty query.", true) end
  local clients = {}
  for _, c in ipairs(vim.lsp.get_clients({})) do
    local caps = c.server_capabilities
    if caps and caps.workspaceSymbolProvider then clients[#clients + 1] = c end
  end
  if #clients == 0 then
    return cb(
      "No running language server supports workspace symbol search. Open or read a file of the relevant language first (that attaches its server), or use document_symbols on a specific file.",
      false
    )
  end
  local bufnr
  for _, c in ipairs(clients) do
    for b in pairs(c.attached_buffers or {}) do
      if vim.api.nvim_buf_is_valid(b) then
        bufnr = b
        break
      end
    end
    if bufnr then break end
  end
  if not bufnr then return cb("No buffer is attached to a language server for the workspace search.", false) end
  if M._nav_should_skip() then return cb(nav_latch_msg(), false) end
  request(bufnr, "workspace/symbol", { query = query }, function(results, rerr)
    if rerr then return cb("workspace/symbol " .. rerr, true) end
    local syms = format.collect_ws(results)
    local text = M._format_ws(query, syms, cwd, max_results())
    if not text then return cb(("No workspace symbols match %q."):format(query), false) end
    cb(text, false)
  end)
end

return M
