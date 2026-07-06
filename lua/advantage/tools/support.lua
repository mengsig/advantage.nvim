---@brief Shared helpers for the built-in tools. Extracted from tools/init.lua so
---each tool group lives in its own small, readable module. These helpers are the
---file/IO/output primitives every tool group builds on; behaviour is unchanged
---from when they were file-local, with explicit invariant assertions added.
local S = {}

local uv = vim.uv or vim.loop
local util = require("advantage.util")

S.MAX_OUTPUT = 30000
S.MAX_LINES = 1500
S.MAX_LINE_LEN = 500

---Resolve a tool path against the project root and enforce containment: file
---tools (including their permission-card previews, which read the target before
---approval) must not reach outside ctx.cwd via absolute paths or `..` traversal.
---`tools.allow_outside_root = true` opts out. Containment is enforced both
---lexically and by resolving symlinks (realpath), so a symlink committed inside
---the repo that points outside cannot be used to escape the sandbox.
---@return string|nil abs_path, string|nil err
function S.resolve(path, ctx)
  assert(type(ctx) == "table" and type(ctx.cwd) == "string" and ctx.cwd ~= "", "resolve: ctx.cwd required")
  local tcfg = require("advantage.config").options.tools or {}
  return require("advantage.util").contain(path, ctx.cwd, tcfg.allow_outside_root)
end

function S.read_all(path)
  assert(type(path) == "string" and path ~= "", "read_all: path must be a non-empty string")
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

function S.write_all(path, content)
  assert(type(path) == "string" and path ~= "", "write_all: path must be a non-empty string")
  assert(type(content) == "string", "write_all: content must be a string")
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- Atomic write: temp file + rename so a crash, a full disk (ENOSPC), or a
  -- racing reader can never leave a half-written or truncated source file — and
  -- a failed write is reported, never silently swallowed as success. Preserve the
  -- existing file's mode when overwriting.
  local st = uv.fs_stat(path)
  local tmp = path .. ".adv.tmp"
  local f, oerr = io.open(tmp, "w")
  if not f then return nil, oerr end
  local ok_w, werr = f:write(content)
  local ok_c = f:close()
  if not ok_w or not ok_c then
    os.remove(tmp)
    return nil, werr or "write failed"
  end
  if st and st.mode then pcall(uv.fs_chmod, tmp, st.mode) end
  local ok_r, rerr = os.rename(tmp, path)
  if not ok_r then
    os.remove(tmp)
    return nil, rerr or "rename failed"
  end
  return true
end

---Byte-cap `s` for tool output that cannot be paginated (bash/grep). Uses a
---character-safe cut so the truncation can never emit a partial UTF-8 sequence.
function S.truncate(s, limit)
  assert(type(s) == "string", "truncate: s must be a string")
  limit = limit or S.MAX_OUTPUT
  assert(type(limit) == "number" and limit > 0, "truncate: limit must be a positive number")
  if #s > limit then return util.utf8_safe_sub(s, limit) .. "\n… [output truncated at " .. limit .. " bytes]" end
  return s
end

---Reload any buffer that has `path` open, after an external edit.
function S.refresh_buffers(path)
  assert(type(path) == "string" and path ~= "", "refresh_buffers: path must be a non-empty string")
  vim.schedule(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd.checktime)
        end)
      end
    end
  end)
end

---Count one substantial work action and return the one-shot record-nudge suffix
---(steers the model to `remember` what it learned once a session has done real
---work but recorded nothing). Empty string when memory is off or not yet due.
function S.record_nudge()
  local ok, memory = pcall(require, "advantage.memory")
  if not (ok and memory.enabled()) then return "" end
  memory.note_work()
  return memory.record_nudge_suffix()
end

---In-band steer toward the LSP navigation tools when the model is grep/read-looping
---over code while a language server is available (throttled per session in lsp.lua;
---silenced by any LSP-tool use). Empty string when LSP is off/absent or not yet due.
---This counters the frozen system-prompt steer losing salience as a session grows.
function S.lsp_explore_nudge()
  local ok, lsp = pcall(require, "advantage.lsp")
  if not (ok and lsp.available()) then return "" end
  local t = (require("advantage.config").options.tools or {}).lsp
  if type(t) == "table" and t.enabled == false then return "" end
  return lsp.explore_nudge()
end

---Finish a successful mutating edit: reload any open buffer, then (best-effort)
---append the newly-introduced LSP/linter diagnostics to the tool result so the
---model can self-correct. Snapshotting the pre-edit diagnostics happens before
---the buffer reloads, so the after/before diff only surfaces problems the edit
---actually introduced. Degrades to a plain success when diagnostics are off or
---unavailable.
function S.finish_write(path, msg, cb)
  assert(type(path) == "string" and path ~= "", "finish_write: path must be a non-empty string")
  assert(type(cb) == "function", "finish_write: cb must be a function")
  local nudge = S.record_nudge()
  local ok, diagnostics = pcall(require, "advantage.diagnostics")
  local dcfg = (require("advantage.config").options.tools or {}).diagnostics
  local severity = (type(dcfg) == "table" and dcfg.severity) or "error"
  local before = ok and diagnostics.snapshot(path, severity) or nil
  S.refresh_buffers(path)
  if not ok then return cb(msg .. nudge, false) end
  diagnostics.after_edit(path, before, function(extra)
    cb(msg .. (extra or "") .. nudge, false)
  end)
end

function S.unified_diff(old, new, path)
  assert(type(old) == "string" and type(new) == "string", "unified_diff: old/new must be strings")
  local diff = vim.text.diff(old, new, { result_type = "unified", ctxlen = 3 }) --[[@as string?]]
  if not diff or diff == "" then return { "(no changes)" } end
  local lines = { "--- a/" .. path, "+++ b/" .. path }
  vim.list_extend(lines, vim.split(diff, "\n", { plain = true, trimempty = true }))
  return lines
end

function S.replace_plain(s, old, new, all)
  assert(type(s) == "string" and type(old) == "string", "replace_plain: s/old must be strings")
  assert(type(new) == "string", "replace_plain: new must be a string")
  if old == "" then return s, 0 end
  local out, count, init = {}, 0, 1
  while true do
    local i, j = s:find(old, init, true)
    if not i then break end
    out[#out + 1] = s:sub(init, i - 1)
    out[#out + 1] = new
    init = j + 1
    count = count + 1
    if not all then break end
  end
  out[#out + 1] = s:sub(init)
  return table.concat(out), count
end

function S.count_plain(s, needle)
  assert(type(s) == "string" and type(needle) == "string", "count_plain: s/needle must be strings")
  if needle == "" then return 0 end
  local count, init = 0, 1
  while true do
    local i, j = s:find(needle, init, true)
    if not i then break end
    count = count + 1
    init = j + 1
  end
  return count
end

---Cap a list of output lines at `head_limit`, appending a "+N more" note when it
---bites, then join and byte-truncate. `empty` is returned when there's nothing.
function S.finalize_search(lines, head_limit, empty)
  assert(type(lines) == "table", "finalize_search: lines must be a table")
  if #lines == 0 then return empty end
  if head_limit and head_limit > 0 and #lines > head_limit then
    local more = #lines - head_limit
    lines = vim.list_slice(lines, 1, head_limit)
    lines[#lines + 1] = ("… +%d more line%s (raise head_limit or narrow the pattern)"):format(
      more,
      more == 1 and "" or "s"
    )
  end
  return S.truncate(table.concat(lines, "\n"))
end

---The configured Brave API key: an inline `api_key` wins over the env var
---named by `api_key_env`. Shared by the web_search tool's run() and its
---enabled-gate (M.enabled), so it lives in the shared support module.
function S.web_search_key(cfg)
  assert(type(cfg) == "table", "web_search_key: cfg must be a table")
  if cfg.api_key and cfg.api_key ~= "" then return cfg.api_key end
  local env = cfg.api_key_env
  return env and env ~= "" and vim.env[env] or nil
end

return S
