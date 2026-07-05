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
local is_list = vim.islist or vim.tbl_islist
local SymbolKind = (vim.lsp.protocol and vim.lsp.protocol.SymbolKind) or {}

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
local function rel(root, abs)
  if root and abs:sub(1, #root + 1) == root .. "/" then return abs:sub(#root + 2) end
  return abs
end

---Trimmed text of a file's 0-based line, from a loaded buffer if one exists (so
---unsaved edits are reflected) else the file on disk. `cache` memoizes the line
---array per path across one format pass.
local function line_text(cache, abs, lnum0)
  local lines = cache[abs]
  if lines == nil then
    local diagnostics = require("advantage.diagnostics")
    local b = diagnostics.loaded_bufnr(abs)
    if b then
      lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    else
      local f = io.open(abs, "r")
      if f then
        local c = f:read("*a")
        f:close()
        lines = vim.split(c, "\n", { plain = true })
      else
        lines = false
      end
    end
    cache[abs] = lines
  end
  if lines and lines[lnum0 + 1] then
    local s = vim.trim(lines[lnum0 + 1])
    if #s > 160 then s = util.utf8_safe_sub(s, 160) .. "…" end
    return s
  end
  return nil
end

--------------------------------------------------------------------------------
-- Pure formatters (unit-tested without a live server)
--------------------------------------------------------------------------------

---A DocumentSymbol's declaration line (1-based) from whichever range it carries.
local function symbol_line(s)
  local rng = s.selectionRange or s.range or (s.location and s.location.range)
  return rng and (rng.start.line + 1) or nil
end

---Flatten a documentSymbol response — either hierarchical DocumentSymbol[] (with
---.children) or flat SymbolInformation[] — into a depth-tagged list.
local function flatten_symbols(result, depth, out)
  out = out or {}
  for _, s in ipairs(result or {}) do
    if type(s) == "table" and s.name then
      out[#out + 1] = {
        name = s.name,
        kind = SymbolKind[s.kind] or "symbol",
        line = symbol_line(s),
        detail = s.detail,
        depth = depth or 0,
      }
      if type(s.children) == "table" and #s.children > 0 then flatten_symbols(s.children, (depth or 0) + 1, out) end
    end
  end
  return out
end
M._flatten_symbols = flatten_symbols

---Render an already-flattened {name, kind, line, depth, detail?} symbol list as an
---indented outline. Shared by the LSP path (M._format_symbols) and the treesitter
---fallback (both produce the same flat shape). Returns nil for an empty list.
---@param label string display name for the file
---@param flat {name:string, kind:string, line:integer?, depth:integer, detail:string?}[]
---@param max integer cap on symbol lines
---@param note string? optional suffix line (e.g. "outline via treesitter")
---@return string|nil
function M._format_flat(label, flat, max, note)
  if #flat == 0 then return nil end
  local lines = { ("%s — %d symbol%s"):format(label, #flat, #flat == 1 and "" or "s") }
  local shown = math.min(#flat, max)
  for i = 1, shown do
    local s = flat[i]
    local detail = ""
    if type(s.detail) == "string" and s.detail ~= "" then
      local d = vim.trim(s.detail:gsub("%s+", " "))
      if #d > 0 then
        if #d > 60 then d = util.utf8_safe_sub(d, 60) .. "…" end
        detail = "  " .. d
      end
    end
    lines[#lines + 1] = ("%s%s %s  L%s%s"):format(string.rep("  ", s.depth or 0), s.kind, s.name, s.line or "?", detail)
  end
  if #flat > shown then
    lines[#lines + 1] = ("  … +%d more symbol%s"):format(#flat - shown, #flat - shown == 1 and "" or "s")
  end
  if note then lines[#lines + 1] = "  (" .. note .. ")" end
  return table.concat(lines, "\n")
end

---Render a raw documentSymbol RESPONSE (from the LSP) as an outline.
---@return string|nil
function M._format_symbols(label, result, max)
  return M._format_flat(label, flatten_symbols(result), max)
end

--------------------------------------------------------------------------------
-- Treesitter outline: instant, local, independent of the language server
--------------------------------------------------------------------------------
-- Node types that name a symbol, across the common grammars. Node types are
-- largely unique per grammar, so one flat map suffices; we only emit when the node
-- actually has a `name`, which drops anonymous inner nodes.
local TS_KINDS = {
  function_declaration = "Function",
  function_definition = "Function",
  function_item = "Function",
  method_definition = "Method",
  method_declaration = "Method",
  method_spec = "Method",
  class_declaration = "Class",
  class_definition = "Class",
  class_specifier = "Class",
  interface_declaration = "Interface",
  trait_item = "Interface",
  type_alias_declaration = "Type",
  type_declaration = "Type",
  type_item = "Type",
  struct_specifier = "Struct",
  struct_item = "Struct",
  enum_specifier = "Enum",
  enum_declaration = "Enum",
  enum_item = "Enum",
  namespace_definition = "Namespace",
  module = "Module",
  impl_item = "Impl",
}
local TS_FUNC_VALUES = { arrow_function = true, function_expression = true, ["function"] = true }
-- Filetypes whose treesitter parser is named differently from the filetype (base
-- Neovim's get_lang returns the filetype verbatim for these, which then can't find
-- a parser). Notably typescriptreact → tsx.
local FT_LANG = {
  typescriptreact = "tsx",
  javascriptreact = "javascript",
  ["javascript.jsx"] = "javascript",
  ["typescript.tsx"] = "tsx",
}

---Extract a document outline from the buffer's TREESITTER parse — local, instant,
---and independent of the language server. This is why document_symbols/outline
---keeps working when the LSP server is slow, still indexing, or times out on
---navigation (a real failure mode: some servers serve diagnostics but block
---documentSymbol). Returns a flat {name, kind, line, depth} list, or nil when
---there's no treesitter parser for the buffer's language.
---@return {name:string, kind:string, line:integer, depth:integer}[]|nil
function M.treesitter_symbols(bufnr)
  if not (vim.treesitter and vim.treesitter.get_parser) then return nil end
  local ft = (vim.bo[bufnr] and vim.bo[bufnr].filetype) or ""
  -- A buffer we loaded ourselves may have no filetype yet (filetype detection
  -- doesn't run in some headless modes), which would leave treesitter unable to
  -- pick a parser — derive it from the filename so the outline still works.
  if ft == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then ft = vim.filetype.match({ filename = name, buf = bufnr }) or "" end
  end
  local lang = FT_LANG[ft]
  if not lang and vim.treesitter.language and vim.treesitter.language.get_lang then
    lang = vim.treesitter.language.get_lang(ft)
  end
  if lang == "" then lang = nil end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then return nil end
  local ok_p, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_p or not trees or not trees[1] then return nil end
  local root = trees[1]:root()
  local out = {}
  local function name_of(node)
    local nf = node:field("name")
    if nf and nf[1] then
      local ok_t, txt = pcall(vim.treesitter.get_node_text, nf[1], bufnr)
      if ok_t and type(txt) == "string" and txt ~= "" then return (txt:gsub("%s+", " ")) end
    end
    return nil
  end
  local function walk(node, depth)
    for child in node:iter_children() do
      local t, emitted = child:type(), false
      local kind = TS_KINDS[t]
      if kind then
        local nm = name_of(child)
        if nm then
          out[#out + 1] = { name = nm, kind = kind, line = child:start() + 1, depth = depth }
          emitted = true
        end
      elseif t == "lexical_declaration" or t == "variable_declaration" then
        -- const X = () => {} / a function expression — React components etc.
        for decl in child:iter_children() do
          if decl:type() == "variable_declarator" then
            local val = decl:field("value")
            local vt = val and val[1] and val[1]:type()
            if vt and TS_FUNC_VALUES[vt] then
              local nm = name_of(decl)
              if nm then out[#out + 1] = { name = nm, kind = "Function", line = decl:start() + 1, depth = depth } end
            end
          end
        end
      end
      walk(child, emitted and depth + 1 or depth)
    end
  end
  walk(root, 0)
  if #out == 0 then return nil end
  return out
end

---Normalize a definition/references response (Location | Location[] | LocationLink
---| LocationLink[], possibly one per client) into a deduped {uri, range} list.
local function collect_locations(results)
  local out, seen = {}, {}
  for _, v in pairs(results or {}) do
    local r = v and v.result
    if type(r) == "table" then
      if r.uri or r.targetUri then r = { r } end -- a single Location/LocationLink
      if is_list(r) then
        for _, loc in ipairs(r) do
          local uri = loc.uri or loc.targetUri
          local rng = loc.range or loc.targetSelectionRange or loc.targetRange
          if uri then
            local key = ("%s:%d:%d"):format(uri, rng and rng.start.line or -1, rng and rng.start.character or -1)
            if not seen[key] then
              seen[key] = true
              out[#out + 1] = { uri = uri, range = rng }
            end
          end
        end
      end
    end
  end
  return out
end
M._collect_locations = collect_locations

---Render a location list as `relpath:line:col  <line text>` rows, capped.
---@param header string e.g. "definition" or "references to add"
---@param locs table[] {uri, range}
---@param root string project root for relative display
---@param max integer
function M._format_locations(header, locs, root, max)
  local lines = { ("%s — %d result%s"):format(header, #locs, #locs == 1 and "" or "s") }
  local shown = math.min(#locs, max)
  local cache = {}
  for i = 1, shown do
    local loc = locs[i]
    local abs = vim.uri_to_fname(loc.uri)
    local l0 = (loc.range and loc.range.start.line) or 0
    local c0 = (loc.range and loc.range.start.character) or 0
    local ctx = line_text(cache, abs, l0)
    lines[#lines + 1] = ("%s:%d:%d%s"):format(rel(root, abs), l0 + 1, c0 + 1, ctx and ("  " .. ctx) or "")
  end
  if #locs > shown then lines[#lines + 1] = ("  … +%d more"):format(#locs - shown) end
  return table.concat(lines, "\n")
end

---Extract plain text from a hover `contents` (MarkupContent | MarkedString |
---MarkedString[]). Capped so a giant doc comment can't blow out context.
local function hover_text(contents)
  local out
  if type(contents) == "string" then
    out = contents
  elseif type(contents) == "table" then
    if type(contents.value) == "string" then
      out = contents.value
    else
      local parts = {}
      for _, c in ipairs(contents) do
        if type(c) == "string" then
          parts[#parts + 1] = c
        elseif type(c) == "table" and type(c.value) == "string" then
          parts[#parts + 1] = c.value
        end
      end
      out = table.concat(parts, "\n")
    end
  end
  if not out then return nil end
  out = vim.trim(out)
  if out == "" then return nil end
  if #out > 1600 then out = util.utf8_safe_sub(out, 1600) .. "\n… [hover truncated]" end
  return out
end
M._hover_text = hover_text

---Merge a workspace/symbol response (SymbolInformation[] | WorkspaceSymbol[]).
local function collect_ws(results)
  local out = {}
  for _, v in pairs(results or {}) do
    for _, s in ipairs((v and v.result) or {}) do
      if type(s) == "table" and s.name then out[#out + 1] = s end
    end
  end
  return out
end
M._collect_ws = collect_ws

---Is this workspace symbol located inside the project root?
local function ws_in_project(s, root)
  local loc = s.location or {}
  local abs = loc.uri and vim.uri_to_fname(loc.uri) or nil
  return abs and root and abs:sub(1, #root + 1) == root .. "/" or false
end

function M._format_ws(query, syms, root, max)
  if #syms == 0 then return nil end
  -- A workspace index is usually dominated by stdlib/runtime/dependency symbols
  -- (e.g. lua-language-server surfaces hundreds of vim/luv builtins for a common
  -- name like "setup"), which are pure noise for navigating THIS repo. Show
  -- project symbols first and collapse the external matches to a single count, so
  -- the model gets the signal without wading through the library index.
  local inproj, external = {}, 0
  for _, s in ipairs(syms) do
    if ws_in_project(s, root) then
      inproj[#inproj + 1] = s
    else
      external = external + 1
    end
  end
  -- If nothing is in-project, fall back to showing what we do have (external).
  local list = #inproj > 0 and inproj or syms
  local scope = #inproj > 0 and " in this project" or ""
  local lines = { ("workspace symbols for %q — %d match%s%s"):format(query, #list, #list == 1 and "" or "es", scope) }
  local shown = math.min(#list, max)
  for i = 1, shown do
    local s = list[i]
    local loc = s.location or {}
    local abs = loc.uri and vim.uri_to_fname(loc.uri) or nil
    local disp = abs and rel(root, abs) or "?"
    local rng = loc.range or s.range
    local l = rng and (rng.start.line + 1) or "?"
    local kind = SymbolKind[s.kind] or "symbol"
    lines[#lines + 1] = ("%s %s  %s:%s"):format(kind, s.name, disp, tostring(l))
  end
  if #list > shown then lines[#lines + 1] = ("  … +%d more"):format(#list - shown) end
  if #inproj > 0 and external > 0 then
    lines[#lines + 1] = ("  (+%d match%s in external/stdlib files hidden — use a distinctive name, or document_symbols on the module)"):format(
      external,
      external == 1 and "" or "es"
    )
  end
  return table.concat(lines, "\n")
end

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

function M.document_symbols(path, cwd, cb)
  M.note_lsp_use()
  local abs, err = resolve_input(path, cwd)
  if not abs then return cb(err, true) end
  ensure_ready(abs, function(bufnr, clients)
    if not bufnr then return cb("File not found: " .. tostring(path), true) end
    local label = rel(cwd, abs)
    local function treesitter(note)
      local flat = M.treesitter_symbols(bufnr)
      return flat and M._format_flat(label, flat, max_results(), note) or nil
    end
    -- Use treesitter (instant, local, no error) instead of the LSP when: no server
    -- is attached; navigation is latched; OR no attached client actually supports
    -- documentSymbol (a diagnostics/lint-only client does not — and requesting it
    -- anyway makes Neovim print "method not supported by any server"). An outline is
    -- pure syntax, so treesitter covers all of these cleanly.
    local supports = any_supports(clients, "documentSymbolProvider")
    if #clients == 0 or M._nav_should_skip() or not supports then
      local ts = treesitter()
      if ts then return cb(ts, false) end
      if #clients == 0 then return no_server(bufnr, abs, cb) end
      if not supports then
        return cb(
          ("No attached language server provides document symbols for '%s' files, and no treesitter parser is available here — use read_file/grep."):format(
            ft_of(bufnr, abs)
          ),
          false
        )
      end
      return cb(nav_latch_msg(), false)
    end
    request(
      bufnr,
      "textDocument/documentSymbol",
      { textDocument = { uri = vim.uri_from_bufnr(bufnr) } },
      function(results, rerr)
        -- LSP errored/timed out → treesitter fallback (still an instant outline).
        if rerr then
          local ts = treesitter("outline via treesitter — the language server didn't respond")
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
        local ts = treesitter()
        if ts then return cb(ts, false) end
        cb(
          ("No symbols reported for %s (the server may still be indexing, or the file defines none)."):format(label),
          false
        )
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
      local locs = collect_locations(results)
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
          text = v and v.result and hover_text(v.result.contents)
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
    local syms = collect_ws(results)
    local text = M._format_ws(query, syms, cwd, max_results())
    if not text then return cb(("No workspace symbols match %q."):format(query), false) end
    cb(text, false)
  end)
end

return M
