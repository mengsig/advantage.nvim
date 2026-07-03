---@brief Anthropic Messages API provider (streaming, tool use, adaptive thinking).
---Authenticates with your Claude subscription (Claude Code login) when available,
---falling back to $ANTHROPIC_API_KEY.
local util = require("advantage.util")
local config = require("advantage.config")
local auth = require("advantage.auth")

local M = {}

---Claude subscription (OAuth) inference requires the request to identify as
---Claude Code via this exact first system block.
local OAUTH_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."

---Strip canonical blocks other providers may have added (e.g. openai reasoning items).
---Also coalesce consecutive same-role messages: the Messages API requires roles to
---strictly alternate, so back-to-back user turns (e.g. a compaction summary followed
---by a retained user message, or interrupt-injected messages) would otherwise 400.
local function sanitize_messages(messages)
  local out = {}
  for _, msg in ipairs(messages) do
    local content = {}
    for _, block in ipairs(msg.content) do
      if block.type == "text" or block.type == "tool_use" or block.type == "tool_result"
        or block.type == "thinking" or block.type == "redacted_thinking" or block.type == "image" then
        content[#content + 1] = block
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

---Place rolling prompt-cache breakpoints on the last content block of the two
---most recent messages. Anthropic caches the whole prefix up to each breakpoint,
---so the static system+tools prefix and the entire prior conversation are read
---from cache on every follow-up turn instead of being re-billed at full price.
---We annotate shallow copies so the stored transcript is never mutated (the
---sanitized wrappers already own fresh content arrays, so replacing an element
---does not touch the original messages).
local CACHE_CONTROL = { type = "ephemeral" }
local function apply_message_cache(messages)
  local marks = 0
  for idx = #messages, 1, -1 do
    if marks >= 2 then break end
    local content = messages[idx].content
    local ci = #content
    if ci > 0 then
      content[ci] = vim.tbl_extend("force", {}, content[ci], { cache_control = CACHE_CONTROL })
      marks = marks + 1
    end
  end
end
M._apply_message_cache = apply_message_cache

---Build the streaming event handler. Exposed for tests via M._make_handler.
local function make_handler(on)
  local blocks = {}
  local current = nil
  local stop_reason = nil
  local usage = { input = 0, output = 0, cached = 0 }
  local completed = false

  local function on_event(_, d)
    if type(d) ~= "table" then return end
    local t = d.type
    if t == "message_start" then
      local u = d.message and d.message.usage or {}
      usage.input = (u.input_tokens or 0) + (u.cache_read_input_tokens or 0) + (u.cache_creation_input_tokens or 0)
      usage.cached = u.cache_read_input_tokens or 0
    elseif t == "content_block_start" then
      local cb = d.content_block or {}
      if cb.type == "text" then
        current = { type = "text", text = "" }
      elseif cb.type == "thinking" then
        current = { type = "thinking", thinking = "", signature = "" }
      elseif cb.type == "redacted_thinking" then
        current = { type = "redacted_thinking", data = cb.data }
      elseif cb.type == "tool_use" then
        current = { type = "tool_use", id = cb.id, name = cb.name, _json = "" }
        on.tool_start(cb.id, cb.name)
      else
        current = { type = cb.type }
      end
    elseif t == "content_block_delta" then
      local delta = d.delta or {}
      if delta.type == "text_delta" and current then
        current.text = (current.text or "") .. delta.text
        on.text(delta.text)
      elseif delta.type == "thinking_delta" and current then
        current.thinking = (current.thinking or "") .. delta.thinking
        if delta.thinking ~= "" then on.thinking(delta.thinking) end
      elseif delta.type == "signature_delta" and current then
        current.signature = (current.signature or "") .. (delta.signature or "")
      elseif delta.type == "input_json_delta" and current then
        current._json = (current._json or "") .. (delta.partial_json or "")
      end
    elseif t == "content_block_stop" then
      if current then
        if current.type == "tool_use" then
          local ok, input = pcall(vim.json.decode, current._json ~= "" and current._json or "{}")
          current.input = ok and input or vim.empty_dict()
          current._json = nil
        end
        blocks[#blocks + 1] = current
        current = nil
      end
    elseif t == "message_delta" then
      if d.delta and d.delta.stop_reason then stop_reason = d.delta.stop_reason end
      if d.usage and d.usage.output_tokens then usage.output = d.usage.output_tokens end
    elseif t == "message_stop" then
      if not completed then
        completed = true
        on.usage(usage.input, usage.output, usage.cached)
        on.complete(blocks, stop_reason or "end_turn", usage)
      end
    elseif t == "error" then
      if not completed then
        completed = true
        on.error((d.error and d.error.message) or "unknown API error")
      end
    end
  end

  return on_event, function() return completed end
end

M._make_handler = make_handler

function M.stream(req)
  local pcfg = config.options.providers.anthropic
  local cancelled, inner = false, nil

  auth.anthropic(function(cred, autherr)
    if cancelled then return end
    if not cred then
      return req.on.error(autherr)
    end
    if req.on.auth then req.on.auth(cred.badge) end

    local headers = {
      "content-type: application/json",
      "anthropic-version: " .. pcfg.version,
    }
    -- A cache breakpoint on the last system block caches the whole static
    -- prefix (tools, then system, in Anthropic's cache ordering) so it is read
    -- from cache on every turn instead of re-billed.
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
    if #betas > 0 then
      headers[#headers + 1] = "anthropic-beta: " .. table.concat(betas, ",")
    end

    local messages = sanitize_messages(req.messages)
    apply_message_cache(messages)

    local body = {
      model = req.model.id,
      max_tokens = pcfg.max_tokens,
      stream = true,
      system = system,
      messages = messages,
      tools = req.tools,
    }
    if req.model.thinking ~= false then
      if type(req.model.thinking) == "table" then
        body.thinking = req.model.thinking
      elseif req.model.thinking_budget then
        body.thinking = { type = "enabled", budget_tokens = req.model.thinking_budget }
      else
        body.thinking = { type = "adaptive", display = "summarized" }
      end
    end

    local on_event, is_completed = make_handler(req.on)

    inner = util.request_sse({
      url = pcfg.base_url .. "/v1/messages",
      headers = headers,
      body = vim.json.encode(body),
      on_event = vim.schedule_wrap(on_event),
      on_error = vim.schedule_wrap(function(msg)
        if not is_completed() then req.on.error(msg) end
      end),
      on_done = vim.schedule_wrap(function()
        if not is_completed() then req.on.error("stream ended unexpectedly") end
      end),
    })
  end)

  return {
    stop = function()
      cancelled = true
      if inner then inner.stop() end
    end,
  }
end

return M
