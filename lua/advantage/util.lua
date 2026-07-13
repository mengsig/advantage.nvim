---@brief Utilities: async curl SSE streaming, small helpers.
local M = {}

---Split one aggregate byte budget deterministically across `count` results.
---There is deliberately no per-result floor: a model may emit an arbitrarily
---large read-only fan-out, but that must never turn the configured aggregate
---context ceiling into `count × floor` bytes.
---@param total number
---@param count integer
---@return integer[]
function M.partition_byte_budget(total, count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  if count == 0 then return {} end
  total = math.max(0, math.floor(tonumber(total) or 0))
  local base, remainder = math.floor(total / count), total % count
  local out = {}
  for i = 1, count do
    out[i] = base + (i <= remainder and 1 or 0)
  end
  return out
end

---UTF-8-safe truncation whose marker is included inside the byte ceiling.
---@param text string
---@param max_bytes integer
---@param marker? string
---@return string
function M.truncate_to_bytes(text, max_bytes, marker)
  text = tostring(text or "")
  max_bytes = math.max(0, math.floor(tonumber(max_bytes) or 0))
  if #text <= max_bytes then return text end
  if max_bytes == 0 then return "" end
  marker = marker or "\n… [truncated]"
  if #marker >= max_bytes then return M.utf8_safe_sub(text, max_bytes) end
  return M.utf8_safe_sub(text, max_bytes - #marker) .. marker
end

local uv = vim.uv or vim.loop

-- Canonical workspace discovery shared by agents, sessions, memory, and tools.
-- Keeping this in one small helper prevents a subdirectory launch from giving
-- each subsystem a subtly different idea of the project boundary.
local _project_roots = {}

---@param cwd? string
---@return string
function M.project_root(cwd)
  cwd = vim.fs.normalize(cwd or uv.cwd() or "")
  if _project_roots[cwd] then return _project_roots[cwd] end
  local git = cwd ~= "" and vim.fs.find(".git", { path = cwd, upward = true })[1] or nil
  local root = git and vim.fs.dirname(git) or cwd
  root = uv.fs_realpath(root) or root
  _project_roots[cwd] = root
  return root
end

function M.buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function under(root, abs)
  return abs == root or abs:sub(1, #root + 1) == root .. "/"
end

---Follow symlinks and verify the resolved path stays under `root`. Handles
---not-yet-existing paths by resolving the deepest existing ancestor — the
---missing tail cannot itself be a symlink.
local function realpath_contained(abs, root)
  local real_root = uv.fs_realpath(root)
  if not real_root then return true end -- root missing: nothing to escape
  local rp = uv.fs_realpath(abs)
  if rp then return under(real_root, rp) end
  local dir = abs
  while true do
    dir = dir:match("^(.*)/[^/]+$") or ""
    if dir == "" then dir = "/" end
    local rdir = uv.fs_realpath(dir)
    if rdir then return under(real_root, rdir) end
    if dir == "/" then return false end
  end
end

---Resolve `path` against `root` and enforce containment: reject absolute paths
---and `..` traversal that leave the root, and reject paths that resolve outside
---it via a symlink (realpath). `allow_outside` skips the containment checks but
---still folds `.`/`..` sanely. Returns `abs_path` or `nil, err`. This is the one
---containment primitive shared by the file tools, @mentions and @imports.
---@return string|nil abs_path, string|nil err
function M.contain(path, root, allow_outside)
  if not path or path == "" then return nil, "empty path" end
  path = vim.fs.normalize(path)
  root = vim.fs.normalize(root)
  if path:sub(1, 1) ~= "/" then path = vim.fs.normalize(root .. "/" .. path) end
  -- fold "." and ".." lexically (vim.fs.normalize does not resolve "..")
  local parts = {}
  for comp in path:gmatch("[^/]+") do
    if comp == ".." then
      if #parts == 0 then return nil, "path escapes the filesystem root" end
      parts[#parts] = nil
    elseif comp ~= "." then
      parts[#parts + 1] = comp
    end
  end
  local abs = "/" .. table.concat(parts, "/")
  if allow_outside then return abs end
  if not under(root, abs) then
    return nil, "outside the project root (set tools.allow_outside_root to permit external paths)"
  end
  if not realpath_contained(abs, root) then return nil, "path resolves (via a symlink) outside the project root" end
  return abs
end

---Truncate `s` to at most `n` bytes without ever splitting a UTF-8 character.
---A plain `s:sub(1, n)` can leave a dangling lead/continuation byte, which makes
---the request body invalid UTF-8 and the provider rejects it (HTTP 400). If the
---byte after the cut is a continuation byte (0x80–0xBF) the cut landed
---mid-character, so back off until it doesn't. Returns a prefix `s[1..n']` with
---`n' <= n` sitting on a character boundary. Use it for any size cap whose result
---can reach a provider request body (tool output, compaction, memory); UI-only
---labels use it too so a truncated glyph never renders as a replacement box.
function M.utf8_safe_sub(s, n)
  if n <= 0 then return "" end
  if n >= #s then return s end
  while n > 0 do
    local b = s:byte(n + 1)
    if b and b >= 0x80 and b < 0xC0 then
      n = n - 1
    else
      break
    end
  end
  return s:sub(1, n)
end

---Re-encode `s` as strictly valid UTF-8: every byte sequence that is not a
---well-formed, non-surrogate, non-overlong code point is replaced with U+FFFD.
---Provider JSON parsers reject invalid UTF-8 in the request body — surrogates
---included, which a lenient server-side decode manufactures from a stray byte —
---with an HTTP 400. Scrubbing the *encoded* body just before the request is the
---last line of defence: it guarantees a well-formed request no matter what byte
---source (a command emitting Latin-1, binary-ish tool output, a mis-sliced
---string) introduced the bad bytes. JSON structure is pure ASCII, so this only
---ever rewrites bytes inside string literals — it can't corrupt the JSON. A body
---that is already valid is returned untouched after one linear scan (~1ms/MB,
---JIT-compiled); the pure-ASCII `find` only short-circuits bodies with no
---multi-byte content at all. Cheap next to the request it precedes.
function M.scrub_utf8(s)
  if not s:find("[\128-\255]") then return s end
  local n, i, out, last = #s, 1, nil, 1
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      i = i + 1
    else
      local len, cp
      if b >= 0xC2 and b <= 0xDF then
        len, cp = 2, b - 0xC0
      elseif b >= 0xE0 and b <= 0xEF then
        len, cp = 3, b - 0xE0
      elseif b >= 0xF0 and b <= 0xF4 then
        len, cp = 4, b - 0xF0
      end
      local ok = false
      if len and i + len - 1 <= n then
        ok = true
        for k = 1, len - 1 do
          local c = s:byte(i + k)
          if c < 0x80 or c > 0xBF then
            ok = false
            break
          end
          cp = cp * 64 + (c - 0x80)
        end
        if ok then
          -- reject overlong, surrogate (U+D800–U+DFFF) and out-of-range points
          if len == 2 then
            ok = cp >= 0x80
          elseif len == 3 then
            ok = cp >= 0x800 and not (cp >= 0xD800 and cp <= 0xDFFF)
          else
            ok = cp >= 0x10000 and cp <= 0x10FFFF
          end
        end
      end
      if ok then
        i = i + len
      else
        out = out or {}
        if i > last then out[#out + 1] = s:sub(last, i - 1) end
        out[#out + 1] = "\239\191\189" -- U+FFFD REPLACEMENT CHARACTER
        i = i + 1
        last = i
      end
    end
  end
  if not out then return s end
  if last <= n then out[#out + 1] = s:sub(last, n) end
  return table.concat(out)
end

---Format a token count like `12.4k`.
function M.fmt_tokens(n)
  n = n or 0
  if n < 1000 then return tostring(n) end
  if n < 1000000 then return string.format("%.1fk", n / 1000) end
  return string.format("%.1fM", n / 1000000)
end

---Format elapsed nanoseconds like `4.2s` / `1m12s`.
function M.fmt_elapsed(ns)
  local s = ns / 1e9
  if s < 60 then return string.format("%.1fs", s) end
  return string.format("%dm%02ds", math.floor(s / 60), math.floor(s % 60))
end

---Incremental SSE parser. Feed whole lines; events are dispatched on blank lines.
---@param on_event fun(name: string, data: any)
---@param on_stray fun(line: string)|nil non-SSE output (e.g. a plain JSON error body)
function M.sse_parser(on_event, on_stray)
  local event_name, data_parts = nil, {}
  return {
    feed_line = function(line)
      line = line:gsub("\r$", "")
      if line == "" then
        if #data_parts > 0 then
          local payload = table.concat(data_parts)
          local ok, decoded = pcall(vim.json.decode, payload)
          if ok then
            on_event(event_name or (type(decoded) == "table" and decoded.type) or "", decoded)
          elseif on_stray then
            on_stray(payload)
          end
        end
        event_name, data_parts = nil, {}
      elseif line:sub(1, 6) == "event:" then
        event_name = vim.trim(line:sub(7))
      elseif line:sub(1, 5) == "data:" then
        data_parts[#data_parts + 1] = vim.trim(line:sub(6))
      elseif line:sub(1, 1) == ":" then
        -- SSE comment / heartbeat
      elseif on_stray then
        on_stray(line)
      end
    end,
  }
end

-- Transient curl exit codes worth retrying: connection/recv/send failures,
-- empty replies (52), timeouts (28), TLS handshake resets (35). These happen
-- under provider load and are safe to retry *only before any SSE event has
-- been dispatched* — otherwise a retry would duplicate streamed content.
local RETRIABLE = {
  [6] = true,
  [7] = true,
  [16] = true,
  [28] = true,
  [35] = true,
  [52] = true,
  [55] = true,
  [56] = true,
  [92] = true,
}

local function cfg_quote(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---Write the request body and a curl config file into a fresh 0700 temp dir.
---Returns the paths table {tmp, body, cfg, hdr}.
local function write_request_files(opts)
  assert(type(opts.url) == "string" and opts.url ~= "", "request_sse: opts.url required")
  assert(type(opts.body) == "string", "request_sse: opts.body must be a string")
  assert(type(opts.headers) == "table", "request_sse: opts.headers must be a table")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p", "0700")
  local paths = { tmp = tmp, body = tmp .. "/b.json", cfg = tmp .. "/c.cfg", hdr = tmp .. "/h.txt" }

  local f = assert(io.open(paths.body, "w"))
  -- Single UTF-8 choke point: every request body reaches the wire through this
  -- one write, so scrubbing here guarantees no provider can send invalid UTF-8
  -- (which the APIs reject as "not valid JSON: surrogates not allowed") — now and
  -- for any future provider. Cheap: a no-op linear scan on an already-valid body.
  f:write(M.scrub_utf8(opts.body))
  f:close()

  local q = cfg_quote
  local cfg = {
    "url = " .. q(opts.url),
    "request = POST",
    "silent",
    "show-error",
    "no-buffer",
    "http1.1",
    "connect-timeout = 15",
    -- Idle guard: abort if the transfer stalls below 1 byte/s for this long, so a
    -- provider that accepts then hangs (no tokens, no heartbeat) can't wedge the
    -- turn forever. Legit streams send pings/tokens well within the window.
    "speed-limit = 1",
    "speed-time = " .. tostring(opts.idle_timeout or 120),
    "dump-header = " .. q(paths.hdr),
    "data-binary = " .. q("@" .. paths.body),
  }
  for _, h in ipairs(opts.headers) do
    cfg[#cfg + 1] = "header = " .. q(h)
  end
  f = assert(io.open(paths.cfg, "w"))
  f:write(table.concat(cfg, "\n"))
  f:close()
  return paths
end

---One-shot temp-dir cleanup guard; repeated calls are no-ops.
local function make_cleanup(paths)
  local cleaned = false
  return function()
    if cleaned then return end
    cleaned = true
    os.remove(paths.body)
    os.remove(paths.cfg)
    os.remove(paths.hdr)
    uv.fs_rmdir(paths.tmp)
  end
end

-- Parse the dumped response headers for the final HTTP status and Retry-After.
-- Under redirects/100-continue there can be several status lines; keep the last.
local function read_response_meta(hdr_file)
  local fh = io.open(hdr_file, "r")
  if not fh then return nil, nil end
  local status, retry_after
  for line in fh:lines() do
    local code = line:match("^HTTP/%S+%s+(%d%d%d)")
    if code then status = tonumber(code) end
    local ra = line:match("^[Rr]etry%-[Aa]fter:%s*(.-)%s*\r?$")
    if ra then retry_after = ra end
  end
  fh:close()
  return status, retry_after
end

---Decide whether an exit is a retriable transient failure. Retries only happen
---before anything has streamed, so a retry can never duplicate content. Returns
---(delay_ms, reason) to retry, or nil to finish.
local function retry_plan(code, status, retry_after, stray_count, dispatched, stopped, attempt_no, max_attempts)
  assert(type(attempt_no) == "number" and type(max_attempts) == "number", "retry_plan: numeric attempt counters")
  if stopped or dispatched > 0 or attempt_no >= max_attempts then return nil end
  -- Transient network failure with nothing streamed and no stray body.
  if code ~= 0 and stray_count == 0 and RETRIABLE[code] then return 400 * attempt_no, code end
  -- HTTP rate-limit / server error (429, 5xx): curl exits cleanly with a JSON
  -- error body, so nothing has streamed yet. Honor Retry-After when sane.
  if status and (status == 429 or (status >= 500 and status <= 599)) then
    local delay = math.min(500 * 2 ^ (attempt_no - 1), 8000)
    local secs = tonumber(retry_after)
    if secs and secs > 0 and secs <= 60 then delay = secs * 1000 end
    return delay, status
  end
  return nil
end

---Report a terminal (non-retried) attempt to the caller's callbacks.
local function report_result(opts, code, status, stray, stderr)
  if #stray > 0 then
    -- Non-SSE body: usually a JSON error envelope from the API.
    local ok, err = pcall(vim.json.decode, table.concat(stray, "\n"))
    local msg
    if ok and type(err) == "table" then
      msg = (err.error and err.error.message) or vim.inspect(err)
    else
      msg = table.concat(stray, " ")
    end
    if status and status >= 400 then msg = ("HTTP %d: %s"):format(status, msg) end
    opts.on_error(msg, status)
  elseif code ~= 0 then
    opts.on_error(#stderr > 0 and table.concat(stderr, " ") or ("curl exited with code " .. code), status)
  else
    opts.on_done()
  end
end

-- Mutually recursive with on_attempt_exit (a retry re-enters run_attempt).
local run_attempt

---Terminal handler for a finished curl job: retry with backoff, or report.
local function on_attempt_exit(ctx, attempt_no, code, stray, stderr)
  local st, opts = ctx.st, ctx.opts
  if st.finished then return end
  local status, retry_after = read_response_meta(ctx.paths.hdr)
  local delay, reason =
    retry_plan(code, status, retry_after, #stray, st.dispatched, st.stopped, attempt_no, ctx.max_attempts)
  if delay then
    if opts.on_retry then pcall(opts.on_retry, attempt_no, reason) end
    vim.defer_fn(function()
      if not st.finished and not st.stopped then run_attempt(ctx, attempt_no + 1) end
    end, delay)
    return
  end
  st.finished = true
  ctx.cleanup()
  report_result(opts, code, status, stray, stderr)
end

---Run one curl attempt, feeding stdout through the SSE parser.
function run_attempt(ctx, attempt_no)
  assert(type(ctx) == "table" and type(ctx.st) == "table", "run_attempt: ctx with state required")
  assert(type(attempt_no) == "number" and attempt_no >= 1, "run_attempt: attempt_no must be >= 1")
  local opts, st = ctx.opts, ctx.st
  local stray, stderr, pending = {}, {}, ""
  local parser = M.sse_parser(function(name, data)
    if not st.finished then
      st.dispatched = st.dispatched + 1
      opts.on_event(name, data)
    end
  end, function(line)
    if line ~= "" then stray[#stray + 1] = line end
  end)

  st.job = vim.fn.jobstart({ "curl", "--config", ctx.paths.cfg }, {
    on_stdout = function(_, data)
      if not data then return end
      data[1] = pending .. data[1]
      pending = table.remove(data)
      for _, line in ipairs(data) do
        parser.feed_line(line)
      end
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      if pending ~= "" then
        parser.feed_line(pending)
        pending = ""
      end
      -- Flush a complete-but-unterminated buffered event: if the stream closed
      -- right after the final `data:` line without the trailing blank line, the
      -- payload is still buffered — a blank line dispatches it. No-op otherwise.
      parser.feed_line("")
      on_attempt_exit(ctx, attempt_no, code, stray, stderr)
    end,
  })

  if st.job <= 0 then
    st.finished = true
    ctx.cleanup()
    vim.schedule(function()
      opts.on_error("failed to start curl — is it installed?")
    end)
  end
end

---POST `body` to `url` and stream SSE events back.
---Uses a curl config file so the API key never appears in the process list.
---@param opts {url:string, headers:string[], body:string, on_event:fun(name:string,data:any), on_error:fun(msg:string, status?:integer), on_done:fun(), on_retry?:fun(attempt:integer, reason:any), idle_timeout?:integer, max_attempts?:integer}
---@return {stop: fun()}
function M.request_sse(opts)
  assert(type(opts) == "table", "request_sse: opts table required")
  assert(type(opts.on_event) == "function", "request_sse: opts.on_event required")
  assert(
    type(opts.on_error) == "function" and type(opts.on_done) == "function",
    "request_sse: on_error and on_done callbacks required"
  )
  local paths = write_request_files(opts)
  local ctx = {
    opts = opts,
    paths = paths,
    cleanup = make_cleanup(paths),
    max_attempts = opts.max_attempts or 3,
    st = { finished = false, dispatched = 0, stopped = false, job = nil },
  }
  run_attempt(ctx, 1)

  local st = ctx.st
  return {
    stop = function()
      st.stopped = true
      if not st.finished then
        st.finished = true
        pcall(vim.fn.jobstop, st.job)
        ctx.cleanup()
      end
    end,
  }
end

return M
