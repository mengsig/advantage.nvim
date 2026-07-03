---@brief OpenAI provider for codex / gpt-5.x models via the Responses API.
---Authenticates with your ChatGPT subscription (codex CLI login) when available,
---falling back to $OPENAI_API_KEY.
local util = require("advantage.util")
local config = require("advantage.config")
local auth = require("advantage.auth")

local M = {}

local function uuid()
  math.randomseed((vim.uv or vim.loop).hrtime() % 2 ^ 31)
  return ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = c == "x" and math.random(0, 15) or math.random(8, 11)
    return ("%x"):format(v)
  end)
end

local function content_blocks(msg)
  if type(msg) ~= "table" then return { msg } end
  return type(msg.content) == "table" and msg.content or { msg.content }
end

local function is_compaction_summary(block)
  return type(block) == "table"
    and block.type == "text"
    and type(block.text) == "string"
    and vim.startswith(block.text, "Conversation context summary (auto-compacted by advantage.nvim).")
end

---Convert canonical (Anthropic-shaped) messages into Responses API input items.
local function to_input_items(messages)
  local items = {}
  local seen_tool_calls = {}
  local compacted = false
  for _, msg in ipairs(type(messages) == "table" and messages or {}) do
    msg = type(msg) == "table" and msg or { role = "user", content = { msg } }
    for _, block in ipairs(content_blocks(msg)) do
      block = type(block) == "table" and block or { type = "text", text = tostring(block or "") }
      if is_compaction_summary(block) then compacted = true end
      if block.type == "text" then
        if msg.role == "assistant" then
          items[#items + 1] = { role = "assistant", content = { { type = "output_text", text = block.text } } }
        else
          items[#items + 1] = { role = "user", content = { { type = "input_text", text = block.text } } }
        end
      elseif block.type == "image" and block.source and block.source.data then
        items[#items + 1] = {
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
        -- Once context has been compacted the paired encrypted reasoning item is
        -- gone, so a function_call carrying its server-side id (fc_…) would be
        -- rejected for lacking its required preceding reasoning item. Replay it as
        -- a fresh client-provided call instead.
        if block.openai_item_id and not compacted then item.id = block.openai_item_id end
        items[#items + 1] = item
      elseif block.type == "tool_result" then
        if seen_tool_calls[block.tool_use_id] then
          local content = block.content
          if type(content) == "table" then content = vim.json.encode(content) end
          items[#items + 1] = {
            type = "function_call_output",
            call_id = block.tool_use_id,
            output = content or "",
          }
        end
      elseif block.type == "openai_reasoning" and block.item and not compacted then
        -- Replay reasoning items so codex models keep their chain across tool calls.
        -- Once context has been compacted the encrypted item no longer matches the
        -- exact prior transcript, and the Responses API may reject the request.
        items[#items + 1] = block.item
      end
      -- anthropic thinking blocks are dropped for this provider
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

local function make_handler(on)
  local blocks = {}
  local usage = { input = 0, output = 0, cached = 0 }
  local completed = false
  local has_tool_call = false

  local function on_event(name, d)
    if type(d) ~= "table" then return end
    local t = d.type or name
    if t == "response.output_item.added" then
      local item = d.item or {}
      if item.type == "function_call" then
        on.tool_start(item.call_id or item.id, item.name)
      end
    elseif t == "response.output_text.delta" then
      if d.delta and d.delta ~= "" then on.text(d.delta) end
    elseif t == "response.reasoning_summary_text.delta" then
      if d.delta and d.delta ~= "" then on.thinking(d.delta) end
    elseif t == "response.output_item.done" then
      local item = d.item or {}
      if item.type == "function_call" then
        has_tool_call = true
        local ok, input = pcall(vim.json.decode, item.arguments and item.arguments ~= "" and item.arguments or "{}")
        blocks[#blocks + 1] = {
          type = "tool_use",
          id = item.call_id or item.id,
          openai_item_id = item.id,
          status = item.status or "completed",
          name = item.name,
          input = ok and input or vim.empty_dict(),
        }
      elseif item.type == "message" then
        local text = {}
        for _, part in ipairs(item.content or {}) do
          if part.type == "output_text" then text[#text + 1] = part.text end
        end
        if #text > 0 then
          blocks[#blocks + 1] = { type = "text", text = table.concat(text) }
        end
      elseif item.type == "reasoning" then
        blocks[#blocks + 1] = { type = "openai_reasoning", item = item }
      end
    elseif t == "response.completed" then
      if not completed then
        completed = true
        local u = (d.response and d.response.usage) or {}
        usage.input = u.input_tokens or 0
        usage.output = u.output_tokens or 0
        usage.cached = (u.input_tokens_details and u.input_tokens_details.cached_tokens) or 0
        on.usage(usage.input, usage.output, usage.cached)
        on.complete(blocks, has_tool_call and "tool_use" or "end_turn", usage)
      end
    elseif t == "response.failed" or t == "response.incomplete" then
      if not completed then
        completed = true
        local err = d.response and d.response.error
        on.error((err and err.message) or ("response " .. (t == "response.failed" and "failed" or "incomplete")))
      end
    elseif t == "error" then
      if not completed then
        completed = true
        on.error(d.message or (d.error and d.error.message) or "unknown API error")
      end
    end
  end

  return on_event, function() return completed end
end

M._to_input_items = to_input_items
M._make_handler = make_handler

function M.stream(req)
  local pcfg = config.options.providers.openai
  local cancelled, inner = false, nil

  auth.openai(function(cred, autherr)
    if cancelled then return end
    if not cred then
      return req.on.error(autherr)
    end
    if req.on.auth then req.on.auth(cred.badge) end

    local url, headers
    local otools = to_tools(req.tools)
    local body = {
      model = req.model.id,
      input = to_input_items(req.messages),
      instructions = req.system,
      -- omit when empty: Lua can't distinguish {} array from {} object, so an
      -- empty table would serialize as a JSON object and the Responses API 400s.
      tools = #otools > 0 and otools or nil,
      tool_choice = #otools > 0 and "auto" or nil,
      stream = true,
      store = false,
      include = { "reasoning.encrypted_content" },
      reasoning = {
        effort = req.model.reasoning_effort or pcfg.reasoning_effort,
        summary = "auto",
      },
    }

    if cred.mode == "chatgpt" then
      url = "https://chatgpt.com/backend-api/codex/responses"
      headers = {
        "content-type: application/json",
        "accept: text/event-stream",
        "authorization: Bearer " .. cred.token,
        "chatgpt-account-id: " .. cred.account_id,
        "OpenAI-Beta: responses=experimental",
        "originator: codex_cli_rs",
        "session_id: " .. uuid(),
      }
    else
      url = pcfg.base_url .. "/v1/responses"
      headers = {
        "content-type: application/json",
        "authorization: Bearer " .. cred.key,
      }
      body.max_output_tokens = pcfg.max_output_tokens
    end

    local on_event, is_completed = make_handler(req.on)

    inner = util.request_sse({
      url = url,
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
