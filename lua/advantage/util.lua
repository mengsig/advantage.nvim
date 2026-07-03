---@brief Utilities: async curl SSE streaming, small helpers.
local M = {}

local uv = vim.uv or vim.loop

function M.buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
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

---POST `body` to `url` and stream SSE events back.
---Uses a curl config file so the API key never appears in the process list.
---@param opts {url:string, headers:string[], body:string, on_event:fun(name:string,data:any), on_error:fun(msg:string), on_done:fun()}
---@return {stop: fun()}
function M.request_sse(opts)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p", "0700")
  local body_file = tmp .. "/b.json"
  local cfg_file = tmp .. "/c.cfg"

  local f = assert(io.open(body_file, "w"))
  f:write(opts.body)
  f:close()

  local function q(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
  end
  local cfg = {
    "url = " .. q(opts.url),
    "request = POST",
    "silent",
    "show-error",
    "no-buffer",
    "http1.1",
    "connect-timeout = 15",
    "data-binary = " .. q("@" .. body_file),
  }
  for _, h in ipairs(opts.headers) do
    cfg[#cfg + 1] = "header = " .. q(h)
  end
  f = assert(io.open(cfg_file, "w"))
  f:write(table.concat(cfg, "\n"))
  f:close()

  -- Transient curl exit codes worth retrying: connection/recv/send failures,
  -- empty replies (52), timeouts (28), TLS handshake resets (35). These happen
  -- under provider load and are safe to retry *only before any SSE event has
  -- been dispatched* — otherwise a retry would duplicate streamed content.
  local RETRIABLE = {
    [6] = true, [7] = true, [16] = true, [28] = true,
    [35] = true, [52] = true, [55] = true, [56] = true, [92] = true,
  }
  local max_attempts = opts.max_attempts or 3

  local finished, dispatched, stopped = false, 0, false
  local current_job = nil

  local function cleanup()
    os.remove(body_file)
    os.remove(cfg_file)
    uv.fs_rmdir(tmp)
  end

  local run_attempt
  run_attempt = function(attempt_no)
    local stray, stderr, pending = {}, {}, ""
    local parser = M.sse_parser(function(name, data)
      if not finished then
        dispatched = dispatched + 1
        opts.on_event(name, data)
      end
    end, function(line)
      if line ~= "" then stray[#stray + 1] = line end
    end)

    current_job = vim.fn.jobstart({ "curl", "--config", cfg_file }, {
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
          parser.feed_line("")
          pending = ""
        end
        if finished then return end

        -- Retry a transient network failure iff nothing has streamed yet.
        if code ~= 0 and #stray == 0 and dispatched == 0 and not stopped
          and RETRIABLE[code] and attempt_no < max_attempts then
          if opts.on_retry then
            pcall(opts.on_retry, attempt_no, code)
          end
          vim.defer_fn(function()
            if not finished and not stopped then run_attempt(attempt_no + 1) end
          end, 400 * attempt_no)
          return
        end

        finished = true
        cleanup()
        if #stray > 0 then
          -- Non-SSE body: usually a JSON error envelope from the API.
          local ok, err = pcall(vim.json.decode, table.concat(stray, "\n"))
          local msg
          if ok and type(err) == "table" then
            msg = (err.error and err.error.message) or vim.inspect(err)
          else
            msg = table.concat(stray, " ")
          end
          opts.on_error(msg)
        elseif code ~= 0 then
          opts.on_error(#stderr > 0 and table.concat(stderr, " ") or ("curl exited with code " .. code))
        else
          opts.on_done()
        end
      end,
    })

    if current_job <= 0 then
      finished = true
      cleanup()
      vim.schedule(function()
        opts.on_error("failed to start curl — is it installed?")
      end)
    end
  end

  run_attempt(1)

  return {
    stop = function()
      stopped = true
      if not finished then
        finished = true
        pcall(vim.fn.jobstop, current_job)
      end
    end,
  }
end

return M
