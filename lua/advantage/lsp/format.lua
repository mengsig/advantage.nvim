---@brief Pure LSP/treesitter result formatters, extracted from lsp.lua. Every
---function here turns a raw server (or treesitter) response into display text and
---takes its result cap as an explicit `max` argument — none read config, session
---or the live request layer — so they are unit-tested without a language server.
local util = require("advantage.util")

local F = {}

---@diagnostic disable-next-line: deprecated
local is_list = vim.islist or vim.tbl_islist -- tbl_islist is the 0.10 fallback
local SymbolKind = (vim.lsp.protocol and vim.lsp.protocol.SymbolKind) or {}

---Path relative to `root` when contained, else the absolute path unchanged.
function F.rel(root, abs)
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
-- Document symbols
--------------------------------------------------------------------------------

---A DocumentSymbol's declaration line (1-based) from whichever range it carries.
local function symbol_line(s)
  local rng = s.selectionRange or s.range or (s.location and s.location.range)
  return rng and (rng.start.line + 1) or nil
end

---Flatten a documentSymbol response — either hierarchical DocumentSymbol[] (with
---.children) or flat SymbolInformation[] — into a depth-tagged list.
function F.flatten_symbols(result, depth, out)
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
      if type(s.children) == "table" and #s.children > 0 then F.flatten_symbols(s.children, (depth or 0) + 1, out) end
    end
  end
  return out
end

---Render an already-flattened {name, kind, line, depth, detail?} symbol list as an
---indented outline. Shared by the LSP path (format_symbols) and the treesitter
---fallback (both produce the same flat shape). Returns nil for an empty list.
---@param label string display name for the file
---@param flat {name:string, kind:string, line:integer?, depth:integer, detail:string?}[]
---@param max integer cap on symbol lines
---@param note string? optional suffix line (e.g. "outline via treesitter")
---@return string|nil
function F.format_flat(label, flat, max, note)
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
function F.format_symbols(label, result, max)
  return F.format_flat(label, F.flatten_symbols(result), max)
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

---Resolve the treesitter language for a buffer, deriving the filetype from the
---filename when detection hasn't run (some headless modes). Returns nil to let
---get_parser fall back to the buffer's own language.
local function ts_resolve_lang(bufnr)
  local ft = (vim.bo[bufnr] and vim.bo[bufnr].filetype) or ""
  -- A buffer we loaded ourselves may have no filetype yet (filetype detection
  -- doesn't run in some headless modes), which would leave treesitter unable to
  -- pick a parser — derive it from the filename so the outline still works.
  if ft == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then ft = vim.filetype.match({ filename = name, buf = bufnr }) or "" end
  end
  local lang = FT_LANG[ft] ---@type string?
  if not lang and vim.treesitter.language and vim.treesitter.language.get_lang then
    lang = vim.treesitter.language.get_lang(ft)
  end
  if lang == "" then lang = nil end
  return lang
end

---The single-line text of a node's `name` field, or nil.
local function ts_node_name(node, bufnr)
  local nf = node:field("name")
  if nf and nf[1] then
    local ok_t, txt = pcall(vim.treesitter.get_node_text, nf[1], bufnr)
    if ok_t and type(txt) == "string" and txt ~= "" then return (txt:gsub("%s+", " ")) end
  end
  return nil
end

---Walk the parse tree, appending named symbols (and function-valued declarations)
---to `out` with their nesting depth.
local function ts_walk(node, depth, bufnr, out)
  for child in node:iter_children() do
    local t, emitted = child:type(), false
    local kind = TS_KINDS[t]
    if kind then
      local nm = ts_node_name(child, bufnr)
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
            local nm = ts_node_name(decl, bufnr)
            if nm then out[#out + 1] = { name = nm, kind = "Function", line = decl:start() + 1, depth = depth } end
          end
        end
      end
    end
    ts_walk(child, emitted and depth + 1 or depth, bufnr, out)
  end
end

---Extract a document outline from the buffer's TREESITTER parse — local, instant,
---and independent of the language server. This is why document_symbols/outline
---keeps working when the LSP server is slow, still indexing, or times out on
---navigation (a real failure mode: some servers serve diagnostics but block
---documentSymbol). Returns a flat {name, kind, line, depth} list, or nil when
---there's no treesitter parser for the buffer's language.
---@return {name:string, kind:string, line:integer, depth:integer}[]|nil
function F.treesitter_symbols(bufnr)
  if not (vim.treesitter and vim.treesitter.get_parser) then return nil end
  assert(type(bufnr) == "number", "treesitter_symbols: bufnr must be a buffer handle")
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, ts_resolve_lang(bufnr))
  if not ok or not parser then return nil end
  local ok_p, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_p or not trees or not trees[1] then return nil end
  local out = {}
  ts_walk(trees[1]:root(), 0, bufnr, out)
  if #out == 0 then return nil end
  return out
end

--------------------------------------------------------------------------------
-- Locations (definition / references) and hover
--------------------------------------------------------------------------------

---Normalize a definition/references response (Location | Location[] | LocationLink
---| LocationLink[], possibly one per client) into a deduped {uri, range} list.
function F.collect_locations(results)
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

---Render a location list as `relpath:line:col  <line text>` rows, capped.
---@param header string e.g. "definition" or "references to add"
---@param locs table[] {uri, range}
---@param root string project root for relative display
---@param max integer
function F.format_locations(header, locs, root, max)
  local lines = { ("%s — %d result%s"):format(header, #locs, #locs == 1 and "" or "s") }
  local shown = math.min(#locs, max)
  local cache = {}
  for i = 1, shown do
    local loc = locs[i]
    local abs = vim.uri_to_fname(loc.uri)
    local l0 = (loc.range and loc.range.start.line) or 0
    local c0 = (loc.range and loc.range.start.character) or 0
    local ctx = line_text(cache, abs, l0)
    lines[#lines + 1] = ("%s:%d:%d%s"):format(F.rel(root, abs), l0 + 1, c0 + 1, ctx and ("  " .. ctx) or "")
  end
  if #locs > shown then lines[#lines + 1] = ("  … +%d more"):format(#locs - shown) end
  return table.concat(lines, "\n")
end

---Extract plain text from a hover `contents` (MarkupContent | MarkedString |
---MarkedString[]). Capped so a giant doc comment can't blow out context.
function F.hover_text(contents)
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

--------------------------------------------------------------------------------
-- Workspace symbols
--------------------------------------------------------------------------------

---Merge a workspace/symbol response (SymbolInformation[] | WorkspaceSymbol[]).
function F.collect_ws(results)
  local out = {}
  for _, v in pairs(results or {}) do
    for _, s in ipairs((v and v.result) or {}) do
      if type(s) == "table" and s.name then out[#out + 1] = s end
    end
  end
  return out
end

---Is this workspace symbol located inside the project root?
local function ws_in_project(s, root)
  local loc = s.location or {}
  local abs = loc.uri and vim.uri_to_fname(loc.uri) or nil
  return abs and root and abs:sub(1, #root + 1) == root .. "/" or false
end

function F.format_ws(query, syms, root, max)
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
    local disp = abs and F.rel(root, abs) or "?"
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

return F
