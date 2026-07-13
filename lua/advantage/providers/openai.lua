---@brief OpenAI provider for codex / gpt-5.x models via the Responses API.
---Authenticates with your ChatGPT subscription (codex CLI login) when available,
---falling back to $OPENAI_API_KEY.
local util = require("advantage.util")
local config = require("advantage.config")
local auth = require("advantage.auth")
local effort_controls = require("advantage.effort")

local M = {}

-- A login pool can expose a model before all effort levels are enabled. Cache a
-- server-advertised downgrade so later turns do not pay a failed Ultra request.
local server_effort_caps = {}

-- Seed once at load, not per call: reseeding on every uuid() correlated draws in
-- the same ns bucket and perturbed the global RNG used elsewhere (session ids).
math.randomseed((vim.uv or vim.loop).hrtime() % 2 ^ 31)
local function uuid()
  return ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = c == "x" and math.random(0, 15) or math.random(8, 11)
    return ("%x"):format(v)
  end)
end

local function content_blocks(msg)
  if type(msg) ~= "table" then return { msg } end
  return type(msg.content) == "table" and msg.content or { msg.content }
end

---Convert canonical (Anthropic-shaped) messages into Responses API input items.
---Convert one content block into a Responses API input item, or nil to skip it.
---Mutates seen_tool_calls to record which function_calls have appeared, so an
---orphan tool_result (whose call was dropped) is skipped rather than 400-ing.
local function convert_block(block, role, seen_tool_calls)
  assert(type(block) == "table" and block.type ~= nil, "convert_block: normalized block required")
  assert(type(seen_tool_calls) == "table", "convert_block: seen_tool_calls set required")
  if block.type == "text" then
    if role == "assistant" then
      if type(block.openai_item) == "table" then return block.openai_item end
      return { role = "assistant", content = { { type = "output_text", text = block.text } } }
    end
    return { role = "user", content = { { type = "input_text", text = block.text } } }
  elseif block.type == "image" and block.source and block.source.data then
    return {
      role = "user",
      content = {
        {
          type = "input_image",
          image_url = ("data:%s;base64,%s"):format(block.source.media_type or "image/png", block.source.data),
        },
      },
    }
  elseif block.type == "tool_use" and block.id then
    seen_tool_calls[block.id] = true
    local item = {
      type = "function_call",
      call_id = block.id,
      name = block.name,
      arguments = vim.json.encode(block.input or vim.empty_dict()),
      status = block.status or "completed",
    }
    -- compact.lua strips both replay-only reasoning and these server-side ids
    -- from the retained window as one atomic operation. Fresh calls created after
    -- a compaction summary must keep their ids so reasoning replay continues.
    if block.openai_item_id then item.id = block.openai_item_id end
    return item
  elseif block.type == "tool_result" then
    if not seen_tool_calls[block.tool_use_id] then return nil end
    local content = block.content
    if type(content) == "table" then content = vim.json.encode(content) end
    return {
      type = "function_call_output",
      call_id = block.tool_use_id,
      output = content or "",
    }
  elseif block.type == "openai_reasoning" and block.item then
    -- Replay reasoning items so codex models keep their chain across tool calls.
    -- Once context has been compacted the encrypted item no longer matches the
    -- exact prior transcript, and the Responses API may reject the request.
    return block.item
  end
  -- anthropic thinking blocks are dropped for this provider
  return nil
end

local function to_input_items(messages)
  local items = {}
  local seen_tool_calls = {}
  for _, msg in ipairs(type(messages) == "table" and messages or {}) do
    msg = type(msg) == "table" and msg or { role = "user", content = { msg } }
    for _, block in ipairs(content_blocks(msg)) do
      block = type(block) == "table" and block or { type = "text", text = tostring(block or "") }
      local item = convert_block(block, msg.role, seen_tool_calls)
      if item then items[#items + 1] = item end
    end
  end
  return items
end

local function to_tools(tools)
  local out = {}
  for _, t in ipairs(tools or {}) do
    out[#out + 1] = {
      type = "function",
      name = t.name,
      description = t.description,
      parameters = t.input_schema,
    }
  end
  return out
end

---Record a completed function_call output item as a canonical tool_use block.
local function append_function_call(st, item)
  assert(type(st) == "table" and type(st.blocks) == "table", "append_function_call: state with blocks required")
  assert(type(item) == "table", "append_function_call: item must be a table")
  -- Never execute a call whose JSON was cut off by an output-token limit.
  if item.status and item.status ~= "completed" then return end
  st.has_tool_call = true
  local ok, input = pcall(vim.json.decode, item.arguments and item.arguments ~= "" and item.arguments or "{}")
  st.blocks[#st.blocks + 1] = {
    type = "tool_use",
    id = item.call_id or item.id,
    openai_item_id = item.id,
    status = item.status or "completed",
    name = item.name,
    input = ok and input or vim.empty_dict(),
  }
end

---Coalesce a completed message item's output_text parts into one text block.
local function append_message(st, item)
  assert(type(st) == "table" and type(st.blocks) == "table", "append_message: state with blocks required")
  assert(type(item) == "table", "append_message: item must be a table")
  local text = {}
  for _, part in ipairs(item.content or {}) do
    if part.type == "output_text" then text[#text + 1] = part.text end
  end
  if #text > 0 then
    local block = { type = "text", text = table.concat(text) }
    -- An incomplete server item is useful transcript text, but cannot safely be
    -- replayed as an authoritative Responses output item on the next request.
    if not item.status or item.status == "completed" then block.openai_item = vim.deepcopy(item) end
    st.blocks[#st.blocks + 1] = block
  end
end

---Dispatch a `response.output_item.done` item to the right block builder.
local function finish_output_item(st, item)
  assert(type(st) == "table", "finish_output_item: state required")
  item = type(item) == "table" and item or {}
  if item.type == "function_call" then
    append_function_call(st, item)
  elseif item.type == "message" then
    append_message(st, item)
  elseif item.type == "reasoning" and (not item.status or item.status == "completed") then
    st.blocks[#st.blocks + 1] = { type = "openai_reasoning", item = item }
  end
end

---Build the streaming event handler. Exposed for tests via M._make_handler.
---Item-completion logic lives in the module-level helpers above so this
---dispatcher stays a short, flat switch over the Responses API event types.
local function make_handler(on, effective_effort)
  assert(type(on) == "table", "make_handler: on must be a table of callbacks")
  assert(
    type(on.complete) == "function" and type(on.error) == "function",
    "make_handler: on.complete and on.error are required callbacks"
  )
  local st = {
    blocks = {},
    usage = { input = 0, output = 0, cached = 0 },
    completed = false,
    has_tool_call = false,
    partial_text = {},
  }

  local function adopt_response_output(response)
    if type(response) ~= "table" or type(response.output) ~= "table" or #response.output == 0 then return false end
    st.blocks, st.has_tool_call = {}, false
    for _, item in ipairs(response.output) do
      finish_output_item(st, item)
    end
    return true
  end

  local function preserve_partial_text()
    for _, block in ipairs(st.blocks) do
      if block.type == "text" and block.text and block.text ~= "" then return end
    end
    local partial = table.concat(st.partial_text)
    if partial ~= "" then st.blocks[#st.blocks + 1] = { type = "text", text = partial } end
  end

  local function finish_usage(response)
    local u = (response and response.usage) or {}
    local input_details = u.input_tokens_details or {}
    local output_details = u.output_tokens_details or {}
    st.usage.input = u.input_tokens or 0
    st.usage.output = u.output_tokens or 0
    st.usage.cached = input_details.cached_tokens or 0
    st.usage.cache_write = input_details.cache_write_tokens or 0
    st.usage.reasoning = output_details.reasoning_tokens or 0
    on.usage(st.usage.input, st.usage.output, st.usage.cached, {
      reasoning = st.usage.reasoning,
      cache_write = st.usage.cache_write,
      effort = effective_effort,
    })
  end

  local function on_event(name, d)
    if type(d) ~= "table" then return end
    local t = d.type or name
    if t == "response.output_item.added" then
      local item = d.item or {}
      if item.type == "function_call" then on.tool_start(item.call_id or item.id, item.name) end
    elseif t == "response.output_text.delta" then
      if d.delta and d.delta ~= "" then
        st.partial_text[#st.partial_text + 1] = d.delta
        on.text(d.delta)
      end
    elseif t == "response.reasoning_summary_text.delta" then
      if d.delta and d.delta ~= "" then on.thinking(d.delta) end
    elseif t == "response.output_item.done" then
      finish_output_item(st, d.item)
    elseif t == "response.completed" then
      if not st.completed then
        st.completed = true
        if #st.blocks == 0 then adopt_response_output(d.response) end
        finish_usage(d.response)
        on.complete(st.blocks, st.has_tool_call and "tool_use" or "end_turn", st.usage)
      end
    elseif t == "response.incomplete" then
      if not st.completed then
        st.completed = true
        local response = d.response or {}
        local reason = response.incomplete_details and response.incomplete_details.reason
        if reason == "max_output_tokens" or reason == "max_tokens" then
          adopt_response_output(response)
          preserve_partial_text()
          finish_usage(response)
          -- Preserve any completed text/tool items and the spend instead of
          -- turning a quality-cap truncation into a transcript-losing error.
          on.complete(st.blocks, st.has_tool_call and "tool_use" or "max_tokens", st.usage)
        else
          local err = response.error
          on.error((err and err.message) or ("response incomplete: " .. tostring(reason or "unknown reason")))
        end
      end
    elseif t == "response.failed" then
      if not st.completed then
        st.completed = true
        local err = d.response and d.response.error
        on.error((err and err.message) or "response failed")
      end
    elseif t == "error" then
      if not st.completed then
        st.completed = true
        on.error(d.message or (d.error and d.error.message) or "unknown API error")
      end
    end
  end

  return on_event, function()
    return st.completed
  end
end

M._to_input_items = to_input_items
M._to_tools = to_tools
M._make_handler = make_handler

---Build the Responses API request body (tools, reasoning, streaming flags).
local function build_body(pcfg, req)
  local otools = to_tools(req.tools)
  local effort = req.model.reasoning_effort
  if effort == nil then effort = pcfg.reasoning_effort end
  -- `ultra` is an advantage/Codex orchestration mode. Never put it on the
  -- wire: Responses accepts the underlying single-agent effort (`max`), while
  -- the agent harness supplies proactive parallel delegation.
  if effort == "ultra" then effort = "max" end
  -- Backward compatibility for sessions saved by the old picker, where `false`
  -- meant "off" but accidentally omitted the reasoning object (which merely
  -- restored the API default). Current sessions store the real API value `none`.
  if effort == false then effort = "none" end
  local parallel_tool_calls
  if #otools > 0 then parallel_tool_calls = req.parallel_tool_calls end
  local reasoning_summary = req.reasoning_summary
  if reasoning_summary == nil then reasoning_summary = pcfg.reasoning_summary end
  if reasoning_summary == false or effort == "none" then reasoning_summary = nil end
  return {
    model = req.model.id,
    input = to_input_items(req.messages),
    instructions = req.system,
    -- omit when empty: Lua can't distinguish {} array from {} object, so an
    -- empty table would serialize as a JSON object and the Responses API 400s.
    tools = #otools > 0 and otools or nil,
    -- An explicit tool_choice (the sub-agent sets "none" on its report-only turn
    -- to force a text reply) wins; otherwise default to "auto" when tools exist.
    tool_choice = req.tool_choice or (#otools > 0 and "auto" or nil),
    -- Permit a same-turn fan-out without requiring one: the model remains free
    -- to emit a single tool call and wait for its result. Keep this request-driven
    -- so config.subagents.parallel = false can disable the capability entirely.
    parallel_tool_calls = parallel_tool_calls,
    prompt_cache_key = req.prompt_cache_key,
    stream = true,
    store = false,
    include = effort ~= "none" and { "reasoning.encrypted_content" } or nil,
    reasoning = {
      effort = effort,
      summary = reasoning_summary,
    },
  }
end
M._build_body = build_body

---Pick endpoint + headers for the credential mode. Mutates `body` for the
---API-key path (which caps output tokens). Returns url, headers.
local function endpoint_for(cred, pcfg, body, req)
  assert(type(cred) == "table" and cred.mode ~= nil, "openai.endpoint_for: resolved credential required")
  if cred.mode == "chatgpt" then
    local session_id = (req and req.session_id) or uuid()
    return "https://chatgpt.com/backend-api/codex/responses",
      {
        "content-type: application/json",
        "accept: text/event-stream",
        "authorization: Bearer " .. cred.token,
        "chatgpt-account-id: " .. cred.account_id,
        "originator: codex_cli_rs",
        -- Match current Codex's hyphenated identity headers. Underscored HTTP
        -- headers can be dropped by proxies, silently defeating sticky routing.
        "session-id: " .. session_id,
        "thread-id: " .. session_id,
        "x-client-request-id: " .. uuid(),
      }
  end
  body.max_output_tokens = config.effective_max_output_tokens(req.model, "openai", "api_key") or pcfg.max_output_tokens
  return pcfg.base_url .. "/v1/responses",
    {
      "content-type: application/json",
      "authorization: Bearer " .. cred.key,
    }
end
M._endpoint_for = endpoint_for

function M.stream(req)
  assert(type(req) == "table" and type(req.on) == "table", "openai.stream: req with on handlers required")
  local pcfg = config.options.providers.openai
  local cancelled, inner, reauthed, effort_retried = false, nil, false, false
  local stream_error_retries = 0
  local effort_override
  local attempt

  local function retryable_stream_error(message, meta)
    if type(meta) == "table" and meta.retryable == true then return true end
    local lower = tostring(message or ""):lower()
    local provider_advised_retry = lower:find("an error occurred while processing your request", 1, true) ~= nil
      and lower:find("you can retry your request", 1, true) ~= nil
    return provider_advised_retry
      or lower:find("overloaded", 1, true) ~= nil
      or lower:find("try again later", 1, true) ~= nil
      or lower:find("temporarily unavailable", 1, true) ~= nil
      or lower:find("at capacity", 1, true) ~= nil
      or lower:find("curl: (18)", 1, true) ~= nil
      or lower:find("curl exited with code 18", 1, true) ~= nil
      or lower:find("transfer closed with outstanding", 1, true) ~= nil
  end

  local function deliver_or_retry(message, meta, saw_payload)
    local max_retries = math.max(0, math.floor(tonumber(pcfg.stream_error_retries) or 2))
    if
      not cancelled
      and not saw_payload
      and retryable_stream_error(message, meta)
      and stream_error_retries < max_retries
    then
      stream_error_retries = stream_error_retries + 1
      local base = math.max(0, math.floor(tonumber(pcfg.stream_error_retry_base_ms) or 2000))
      local delay = math.min(base * 2 ^ (stream_error_retries - 1), 10000)
      local notice = ("OpenAI stream overloaded/interrupted; retrying the same request (%d/%d) in %.1fs"):format(
        stream_error_retries,
        max_retries,
        delay / 1000
      )
      if type(req.on.retry) == "function" then
        pcall(req.on.retry, notice, { attempt = stream_error_retries, delay_ms = delay, provider = "openai" })
      else
        vim.schedule(function()
          vim.notify(notice, vim.log.levels.WARN)
        end)
      end
      return vim.defer_fn(function()
        if not cancelled then attempt(false) end
      end, delay)
    end
    req.on.error(message, meta)
  end

  attempt = function(force)
    auth.openai(function(cred, autherr)
      if cancelled then return end
      if not cred then
        return req.on.error(autherr, { kind = "auth", scope = "provider", retryable = false, provider = "openai" })
      end
      if req.on.auth then req.on.auth(cred.badge, { transport = cred.mode, provider = "openai" }) end

      local effective_req = req
      if req.model.reasoning_effort == false then
        effective_req = vim.tbl_extend("force", {}, req, { model = vim.deepcopy(req.model) })
        effective_req.model.reasoning_effort = cred.mode == "api_key" and "none" or "low"
      end
      if effort_override then
        effective_req = vim.tbl_extend("force", {}, effective_req, { model = vim.deepcopy(effective_req.model) })
        effective_req.model.reasoning_effort = effort_override
      end
      local cached_cap = server_effort_caps[cred.mode .. ":" .. tostring(effective_req.model.id)]
      if
        cached_cap and (effective_req.model.reasoning_effort == nil or effective_req.model.reasoning_effort == "ultra")
      then
        effective_req = vim.tbl_extend("force", {}, effective_req, { model = vim.deepcopy(effective_req.model) })
        effective_req.model.reasoning_effort = cached_cap
      end
      local selected, effort_err = effort_controls.resolve_openai(effective_req.model, cred.mode, pcfg.reasoning_effort)
      if effort_err then
        return req.on.error(effort_err, {
          kind = "request",
          scope = "request",
          retryable = false,
          provider = "openai",
          transport = cred.mode,
        })
      end
      -- Freeze the resolved inherited value into this request. build_body is also
      -- exported for unit tests and normally consults provider config itself; a
      -- clone here prevents that generic path from undoing transport-aware
      -- clamping (ultra→max/xhigh) after credentials have been resolved.
      if effective_req.model.reasoning_effort ~= selected then
        effective_req = vim.tbl_extend("force", {}, effective_req, { model = vim.deepcopy(effective_req.model) })
        effective_req.model.reasoning_effort = selected
      end

      local body = build_body(pcfg, effective_req)
      local url, headers = endpoint_for(cred, pcfg, body, effective_req)
      local saw_payload = false
      local handler_on = vim.tbl_extend("force", {}, req.on)
      for _, key in ipairs({ "text", "thinking", "tool_start" }) do
        local callback = req.on[key]
        handler_on[key] = function(...)
          saw_payload = true
          if callback then return callback(...) end
        end
      end
      handler_on.error = function(message, meta)
        deliver_or_retry(message, meta, saw_payload)
      end
      local on_event, is_completed = make_handler(handler_on, selected)

      inner = util.request_sse({
        url = url,
        headers = headers,
        body = vim.json.encode(body),
        on_event = vim.schedule_wrap(on_event),
        on_error = vim.schedule_wrap(function(msg, status)
          if is_completed() then return end
          -- A mid-flight 401 means the token was rotated/revoked server-side:
          -- force a fresh token once and retry before surfacing an error.
          if status == 401 and not reauthed and not cancelled then
            reauthed = true
            return attempt(true)
          end
          -- Some ChatGPT-login pools currently cap the parent request at xhigh
          -- even though the Codex catalogue exposes Max/Ultra. Ultra's
          -- delegation still runs in the harness; recover the parent stream at
          -- the deepest effort this route explicitly advertises.
          local lower = tostring(msg):lower()
          if
            status == 400
            and not effort_retried
            and selected == "max"
            and lower:find("invalid value", 1, true)
            and lower:find("xhigh", 1, true)
            and (lower:find("max", 1, true) or lower:find("ultra", 1, true))
          then
            effort_retried = true
            effort_override = "xhigh"
            server_effort_caps[cred.mode .. ":" .. tostring(effective_req.model.id)] = "xhigh"
            vim.schedule(function()
              vim.notify(
                ("Ultra mode active; OpenAI %s caps parent reasoning for %s at xhigh (delegation remains enabled)"):format(
                  cred.mode == "chatgpt" and "login" or "API",
                  tostring(effective_req.model.id)
                ),
                vim.log.levels.WARN
              )
            end)
            return attempt(false)
          end
          local kind = (status == 401 or status == 403) and "auth"
            or status == 404 and "model"
            or status == 429 and "capacity"
            or "http"
          deliver_or_retry(msg, {
            kind = kind,
            scope = kind == "auth" and "provider" or kind == "model" and "model" or "request",
            retryable = status == 429 or (status and status >= 500) or false,
            status = status,
            provider = "openai",
            transport = cred.mode,
          }, saw_payload)
        end),
        on_done = vim.schedule_wrap(function()
          if not is_completed() then
            deliver_or_retry("stream ended unexpectedly", {
              kind = "transport",
              scope = "request",
              retryable = true,
              provider = "openai",
              transport = cred.mode,
            }, saw_payload)
          end
        end),
      })
    end, force)
  end

  attempt(false)

  return {
    stop = function()
      cancelled = true
      if inner then inner.stop() end
    end,
  }
end

return M
