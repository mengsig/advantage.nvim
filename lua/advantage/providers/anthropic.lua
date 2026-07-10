---@brief Anthropic Messages API provider (streaming, tool use, adaptive thinking).
---Authenticates with your Claude subscription (Claude Code login) when available,
---falling back to $ANTHROPIC_API_KEY.
local util = require("advantage.util")
local config = require("advantage.config")
local auth = require("advantage.auth")
local effort = require("advantage.effort")

local M = {}

---Claude subscription (OAuth) inference requires the request to identify as
---Claude Code via this exact first system block.
local OAUTH_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."

---Strip canonical blocks other providers may have added (e.g. openai reasoning items).
---Also coalesce consecutive same-role messages: the Messages API requires roles to
---strictly alternate, so back-to-back user turns (e.g. a compaction summary followed
---by a retained user message, or interrupt-injected messages) would otherwise 400.
local function sanitize_messages(messages)
  assert(type(messages) == "table", "sanitize_messages: messages must be a table")
  local out = {}
  local seen_tool_use = {}
  for _, msg in ipairs(messages) do
    local content = {}
    for _, block in ipairs(msg.content) do
      if block.type == "tool_use" then
        if block.id then seen_tool_use[block.id] = true end
        content[#content + 1] = block
      elseif block.type == "tool_result" then
        -- Drop a tool_result whose tool_use was compacted/cut away: Anthropic 400s
        -- on a tool_result with no matching tool_use in the same request (the
        -- OpenAI path already guards this via `seen_tool_calls`).
        if block.tool_use_id and seen_tool_use[block.tool_use_id] then content[#content + 1] = block end
      elseif
        block.type == "text"
        or block.type == "thinking"
        or block.type == "redacted_thinking"
        or block.type == "image"
      then
        local copy = vim.deepcopy(block)
        copy.openai_item = nil
        content[#content + 1] = copy
      end
    end
    if #content > 0 then
      local prev = out[#out]
      if prev and prev.role == msg.role then
        for _, block in ipairs(content) do
          prev.content[#prev.content + 1] = block
        end
      else
        out[#out + 1] = { role = msg.role, content = content }
      end
    end
  end
  return out
end
M._sanitize_messages = sanitize_messages

---Place rolling prompt-cache breakpoints on the last content block of the two
---most recent messages. Anthropic caches the whole prefix up to each breakpoint,
---so the static system+tools prefix and the entire prior conversation are read
---from cache on every follow-up turn instead of being re-billed at full price.
---We annotate shallow copies so the stored transcript is never mutated (the
---sanitized wrappers already own fresh content arrays, so replacing an element
---does not touch the original messages).
local CACHE_CONTROL = { type = "ephemeral" }
local function apply_message_cache(messages)
  assert(type(messages) == "table", "apply_message_cache: messages must be a table")
  local marks = 0
  for idx = #messages, 1, -1 do
    if marks >= 2 then break end
    local content = messages[idx].content
    local ci = #content
    -- Thinking/redacted_thinking blocks must be replayed byte-for-byte on the
    -- latest assistant turn. Adding cache_control to one counts as modifying it
    -- and the Messages API rejects the request, so mark the nearest ordinary
    -- block instead (or continue to an older message when none exists).
    while ci > 0 and (content[ci].type == "thinking" or content[ci].type == "redacted_thinking") do
      ci = ci - 1
    end
    if ci > 0 then
      content[ci] = vim.tbl_extend("force", {}, content[ci], { cache_control = CACHE_CONTROL })
      marks = marks + 1
    end
  end
end
M._apply_message_cache = apply_message_cache

---Decode a completed tool_use block's accumulated JSON argument stream. A
---truncated/empty stream decodes to an empty object rather than crashing the turn.
local function finalize_tool_use(current)
  assert(type(current) == "table", "finalize_tool_use: current block must be a table")
  local raw = table.concat(current._json_parts or {})
  local ok, input = pcall(vim.json.decode, raw ~= "" and raw or "{}")
  current.input = ok and input or vim.empty_dict()
  current._json_parts = nil
end

---Begin a new content block from a `content_block_start` event.
local function start_block(st, on, cb)
  assert(type(st) == "table" and type(on) == "table", "start_block: state and callbacks required")
  cb = cb or {}
  if cb.type == "text" then
    st.current = { type = "text", _text_parts = {} }
  elseif cb.type == "thinking" then
    st.current = { type = "thinking", _thinking_parts = {}, _signature_parts = {} }
  elseif cb.type == "redacted_thinking" then
    st.current = { type = "redacted_thinking", data = cb.data }
  elseif cb.type == "tool_use" then
    st.current = { type = "tool_use", id = cb.id, name = cb.name, _json_parts = {} }
    on.tool_start(cb.id, cb.name)
  elseif mode == "manual" then
    st.current = { type = cb.type }
  end
end

---Fold a `content_block_delta` into the block currently being assembled. No-op
---until a block has started, matching the API's ordering guarantees.
local function apply_delta(st, on, delta)
  assert(type(st) == "table" and type(on) == "table", "apply_delta: state and callbacks required")
  local current = st.current
  if not current then return end
  if delta.type == "text_delta" then
    current._text_parts[#current._text_parts + 1] = delta.text or ""
    on.text(delta.text)
  elseif delta.type == "thinking_delta" then
    current._thinking_parts[#current._thinking_parts + 1] = delta.thinking or ""
    if delta.thinking ~= "" then on.thinking(delta.thinking) end
  elseif delta.type == "signature_delta" then
    current._signature_parts[#current._signature_parts + 1] = delta.signature or ""
  elseif delta.type == "input_json_delta" then
    current._json_parts[#current._json_parts + 1] = delta.partial_json or ""
  end
end

---Seal the block currently being assembled and append it to the result list.
local function stop_block(st)
  assert(type(st) == "table" and type(st.blocks) == "table", "stop_block: state with blocks required")
  local current = st.current
  if not current then return end
  if current.type == "tool_use" then
    finalize_tool_use(current)
  elseif current.type == "text" then
    current.text = table.concat(current._text_parts or {})
    current._text_parts = nil
  elseif current.type == "thinking" then
    current.thinking = table.concat(current._thinking_parts or {})
    current.signature = table.concat(current._signature_parts or {})
    current._thinking_parts, current._signature_parts = nil, nil
  end
  st.blocks[#st.blocks + 1] = current
  st.current = nil
end

---Build the streaming event handler. Exposed for tests via M._make_handler.
---Per-event logic lives in the module-level helpers above so this dispatcher
---stays a short, flat switch over the Anthropic SSE event types.
local function make_handler(on, effective_effort)
  assert(type(on) == "table", "make_handler: on must be a table of callbacks")
  assert(
    type(on.complete) == "function" and type(on.error) == "function",
    "make_handler: on.complete and on.error are required callbacks"
  )
  local st = {
    blocks = {},
    current = nil,
    stop_reason = nil,
    usage = { input = 0, output = 0, cached = 0 },
    completed = false,
  }

  local function on_event(_, d)
    if type(d) ~= "table" then return end
    local t = d.type
    if t == "message_start" then
      local u = d.message and d.message.usage or {}
      st.usage.input = (u.input_tokens or 0) + (u.cache_read_input_tokens or 0) + (u.cache_creation_input_tokens or 0)
      st.usage.cached = u.cache_read_input_tokens or 0
      st.usage.cache_write = u.cache_creation_input_tokens or 0
    elseif t == "content_block_start" then
      start_block(st, on, d.content_block or {})
    elseif t == "content_block_delta" then
      apply_delta(st, on, d.delta or {})
    elseif t == "content_block_stop" then
      stop_block(st)
    elseif t == "message_delta" then
      if d.delta and d.delta.stop_reason then st.stop_reason = d.delta.stop_reason end
      if d.usage and d.usage.output_tokens then st.usage.output = d.usage.output_tokens end
      local details = d.usage and d.usage.output_tokens_details or {}
      if details.thinking_tokens then st.usage.reasoning = details.thinking_tokens end
    elseif t == "message_stop" then
      if not st.completed then
        st.completed = true
        on.usage(st.usage.input, st.usage.output, st.usage.cached, {
          reasoning = st.usage.reasoning or 0,
          cache_write = st.usage.cache_write or 0,
          effort = effective_effort,
        })
        on.complete(st.blocks, st.stop_reason or "end_turn", st.usage)
      end
    elseif t == "error" then
      if not st.completed then
        st.completed = true
        on.error((d.error and d.error.message) or "unknown API error")
      end
    end
  end

  return on_event, function()
    return st.completed
  end
end

M._make_handler = make_handler

---Build request headers and the system blocks for a resolved credential.
---A cache breakpoint on the last system block caches the whole static prefix
---(tools, then system, in Anthropic's cache ordering) so it is read from cache
---on every turn instead of re-billed.
---@return string[] headers, table system
local function build_headers(pcfg, req, cred)
  assert(type(cred) == "table" and cred.mode ~= nil, "anthropic.build_headers: resolved credential required")
  local headers = {
    "content-type: application/json",
    "anthropic-version: " .. pcfg.version,
  }
  local betas = {}
  local system
  if cred.mode == "oauth" then
    headers[#headers + 1] = "authorization: Bearer " .. cred.token
    betas[#betas + 1] = "oauth-2025-04-20"
    system = {
      { type = "text", text = OAUTH_IDENTITY },
      { type = "text", text = req.system, cache_control = CACHE_CONTROL },
    }
  else
    headers[#headers + 1] = "x-api-key: " .. cred.key
    system = { { type = "text", text = req.system, cache_control = CACHE_CONTROL } }
  end
  -- Parity with the real CLI: keep thinking blocks flowing between tool calls
  -- so multi-tool turns stay reasoned end-to-end instead of resetting.
  if req.model.thinking ~= false and pcfg.interleaved_thinking ~= false then
    betas[#betas + 1] = "interleaved-thinking-2025-05-14"
  end
  if #betas > 0 then headers[#headers + 1] = "anthropic-beta: " .. table.concat(betas, ",") end
  return headers, system
end

---Apply the model's thinking config to the request body in place, trimming the
---budget to guarantee headroom for the visible answer.
local function apply_thinking(body, req)
  local mode = effort.anthropic_mode(req.model)
  local selected = req.model.thinking

  if mode == "adaptive_always" then
    -- Fable/Mythos 5 think adaptively without a thinking parameter and reject
    -- attempts to disable it. output_config.effort below is their depth control.
    if req.model.thinking_display then body.thinking = { type = "adaptive", display = req.model.thinking_display } end
  elseif mode == "adaptive_default" then
    -- Sonnet 5 thinks by default. Unlike older models, omission does NOT turn it
    -- off; an explicit disabled object is required.
    if selected == false then
      body.thinking = { type = "disabled" }
    elseif req.model.thinking_display then
      body.thinking = { type = "adaptive", display = req.model.thinking_display }
    end
  elseif mode == "adaptive" then
    -- Opus 4.6+ requires adaptive thinking and rejects legacy budget_tokens.
    if selected ~= false then
      body.thinking = { type = "adaptive", display = req.model.thinking_display or "summarized" }
    end
  elseif mode == "manual" then
    -- Manual-thinking generations (Haiku 4.5 and older Claude 4) retain the
    -- fixed-budget control. Copy before trimming so shared model config and saved
    -- sessions are never mutated by request construction.
    if type(selected) == "table" then
      body.thinking = vim.deepcopy(selected)
    elseif req.model.thinking_budget then
      body.thinking = { type = "enabled", budget_tokens = req.model.thinking_budget }
    end
    if body.thinking and req.model.thinking_display then body.thinking.display = req.model.thinking_display end
  end
  -- Thinking tokens count against max_tokens. A fixed budget close to max_tokens
  -- (e.g. the 32k "ultrathink" preset under a 32k cap) would leave ~no room for
  -- the actual answer. Guarantee ANSWER_HEADROOM tokens for the visible reply by
  -- trimming the budget to fit under max_tokens rather than growing max_tokens
  -- (which could exceed the model's hard output ceiling and 400). Adaptive
  -- thinking has no fixed budget, so it is untouched.
  local ANSWER_HEADROOM = 8192
  local budget = type(body.thinking) == "table" and body.thinking.budget_tokens or nil
  if budget and budget + ANSWER_HEADROOM > body.max_tokens then
    body.thinking.budget_tokens = math.max(1024, body.max_tokens - ANSWER_HEADROOM)
  end
end

---Assemble the full /v1/messages request body from the request + system blocks.
local function build_body(pcfg, req, system)
  local messages = sanitize_messages(req.messages)
  apply_message_cache(messages)
  local body = {
    model = req.model.id,
    max_tokens = config.effective_max_output_tokens(req.model, "anthropic") or pcfg.max_tokens,
    stream = true,
    system = system,
    messages = messages,
    tools = req.tools,
  }
  local requested_effort = req.model.effort
  if requested_effort == nil then requested_effort = pcfg.effort end
  if requested_effort ~= nil then body.output_config = { effort = requested_effort } end
  -- Optional tool-use control (the sub-agent sets "none" on its report-only turn
  -- to force a text reply). Anthropic expects an object; "none" is compatible with
  -- interleaved thinking, unlike "any"/"tool".
  if req.tool_choice then body.tool_choice = { type = req.tool_choice } end
  apply_thinking(body, req)
  return body
end
M._build_body = build_body

function M.stream(req)
  assert(type(req) == "table" and type(req.on) == "table", "anthropic.stream: req with on handlers required")
  local pcfg = config.options.providers.anthropic
  local cancelled, inner, reauthed = false, nil, false
  local attempt

  attempt = function(force)
    auth.anthropic(function(cred, autherr)
      if cancelled then return end
      if not cred then return req.on.error(autherr) end
      if req.on.auth then req.on.auth(cred.badge) end

      local headers, system = build_headers(pcfg, req, cred)
      local body = build_body(pcfg, req, system)
      local selected_effort = req.model.effort
      if selected_effort == nil then selected_effort = pcfg.effort end
      if selected_effort == nil and effort.anthropic_mode(req.model) ~= "manual" then selected_effort = "high" end
      local on_event, is_completed = make_handler(req.on, selected_effort)

      inner = util.request_sse({
        url = pcfg.base_url .. "/v1/messages",
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
          req.on.error(msg)
        end),
        on_done = vim.schedule_wrap(function()
          if not is_completed() then req.on.error("stream ended unexpectedly") end
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
