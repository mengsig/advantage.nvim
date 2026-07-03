---@brief Heuristic conversation compaction for long sessions.
---
---The harness keeps full canonical messages while a conversation is small. Once a
---rough token estimate crosses `context.compact_at_tokens`, older messages are
---collapsed into a text summary and the newest messages are kept verbatim. This is
---intentionally provider-agnostic and offline: it does not spend an extra model
---call to summarize, but it preserves the important durable facts (user asks,
---assistant answers, tool calls and tool results) well enough to keep the next
---turn grounded.
local M = {}

local SUMMARY_PREFIX = "Conversation context summary (auto-compacted by advantage.nvim)."

local function content_blocks(msg)
  if type(msg) ~= "table" then return { msg } end
  return type(msg.content) == "table" and msg.content or { msg.content }
end

local function block_text(block)
  if type(block) ~= "table" then
    return tostring(block or "")
  end
  if block.type == "text" then
    return block.text or ""
  elseif block.type == "tool_use" then
    local ok, encoded = pcall(vim.json.encode, block.input or vim.empty_dict())
    return ("tool_use %s %s"):format(block.name or "?", ok and encoded or vim.inspect(block.input))
  elseif block.type == "tool_result" then
    local c = block.content
    if type(c) == "table" then
      local ok, encoded = pcall(vim.json.encode, c)
      c = ok and encoded or vim.inspect(c)
    end
    return ("tool_result %s%s: %s"):format(
      block.tool_use_id or "?",
      block.is_error and " error" or "",
      c or ""
    )
  elseif block.type == "image" then
    return "[image attachment]"
  elseif block.type == "thinking" then
    return "[assistant thinking omitted]"
  elseif block.type == "openai_reasoning" then
    return "[OpenAI reasoning item omitted]"
  end
  return "[" .. tostring(block.type or "unknown") .. "]"
end

local function message_chars(msg)
  if type(msg) ~= "table" then return #tostring(msg or "") end
  local n = #(msg.role or "")
  local content = content_blocks(msg)
  for _, b in ipairs(content) do
    n = n + #block_text(b)
  end
  return n
end

function M.estimate_tokens(messages)
  if type(messages) ~= "table" then messages = {} end
  local chars = 0
  for _, msg in ipairs(messages) do
    chars = chars + message_chars(msg) + 16
  end
  return math.ceil(chars / 4)
end

-- Truncate to at most `n` bytes without splitting a multi-byte UTF-8 character.
-- Byte-index string.sub can otherwise leave a dangling continuation byte, which
-- produces invalid UTF-8 and makes providers reject the request body.
local function utf8_safe_sub(s, n)
  if n <= 0 then return "" end
  if n >= #s then return s end
  -- If the byte immediately after the cut is a UTF-8 continuation byte
  -- (0x80-0xBF), the cut landed mid-character; back off until it isn't.
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

local function trim_one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  if #s > max then s = utf8_safe_sub(s, math.max(0, max - 1)) .. "…" end
  return s
end

---@param carry? string a prior summary to preserve verbatim at the head, so that
---  compacting an already-compacted session never shaves the oldest history down
---  to a single 900-char line (that regression silently discarded early context).
local function summarize_messages(messages, max_chars, carry)
  max_chars = max_chars or 12000
  local lines
  if carry and carry ~= "" then
    -- carry already opens with SUMMARY_PREFIX; keep it whole and append the
    -- newly-aged-out messages after it.
    lines = { carry, "", "[earlier history summarized above; more recent — but still old — messages follow]", "" }
  else
    lines = {
      SUMMARY_PREFIX,
      "The following is a compressed record of earlier conversation history. Treat it as prior context; newer messages after this summary are verbatim.",
      "",
    }
  end
  -- Give newly-compacted messages their own budget on top of a preserved carry,
  -- but hold the whole summary under a hard ceiling so repeated compaction is bounded.
  local ceiling = math.min((carry and carry ~= "") and (#carry + max_chars) or max_chars, 4 * max_chars)
  local total = #table.concat(lines, "\n")
  local function add(line)
    if total >= ceiling then return false end
    if total + #line + 1 > ceiling then
      line = utf8_safe_sub(line, math.max(0, ceiling - total - 2)) .. "…"
    end
    lines[#lines + 1] = line
    total = total + #line + 1
    return total < ceiling
  end

  for i, msg in ipairs(messages) do
    msg = type(msg) == "table" and msg or { role = "?", content = { msg } }
    local role = msg.role or "?"
    local prefix = ("%02d %s: "):format(i, role)
    local parts = {}
    local content = content_blocks(msg)
    for _, block in ipairs(content) do
      parts[#parts + 1] = trim_one_line(block_text(block), 900)
    end
    if not add(prefix .. table.concat(parts, " | ")) then break end
  end
  if total >= ceiling then
    lines[#lines + 1] = "[summary truncated]"
  end
  return table.concat(lines, "\n")
end

local function is_summary_message(msg)
  if type(msg) ~= "table" or msg.role ~= "user" then return false end
  local b = type(msg.content) == "table" and msg.content[1] or nil
  return type(b) == "table" and b.type == "text" and type(b.text) == "string" and vim.startswith(b.text, SUMMARY_PREFIX)
end

local function strip_replay_only_blocks(messages)
  local out = {}
  for _, msg in ipairs(messages or {}) do
    if type(msg) ~= "table" then
      out[#out + 1] = msg
    else
      local content = {}
      for _, block in ipairs(content_blocks(msg)) do
        -- OpenAI encrypted reasoning items are only safe to replay with the
        -- exact preceding context they were produced from.  After compaction we
        -- have deliberately changed that context, so keep the human-visible
        -- summary and drop replay-only reasoning state from retained messages.
        if not (type(block) == "table" and block.type == "openai_reasoning") then
          local copy = vim.deepcopy(block)
          -- A retained tool_use still referencing its server-side item id (fc_…)
          -- would require its paired reasoning item (rs_…) to precede it. We just
          -- dropped that reasoning item, so detach the id and replay the call as a
          -- fresh client-provided function_call (Responses API rejects it otherwise).
          if type(copy) == "table" and copy.type == "tool_use" then
            copy.openai_item_id = nil
          end
          content[#content + 1] = copy
        end
      end
      if #content > 0 then
        out[#out + 1] = { role = msg.role, content = content }
      end
    end
  end
  return out
end

local function has_tool_use(msg, id)
  if not id then return false end
  for _, block in ipairs(content_blocks(msg)) do
    if type(block) == "table" and block.type == "tool_use" and block.id == id then return true end
  end
  return false
end

local function tool_results_missing_uses(messages, start_idx)
  local seen = {}
  for i = start_idx, #messages do
    for _, block in ipairs(content_blocks(messages[i])) do
      if type(block) == "table" and block.type == "tool_use" and block.id then
        seen[block.id] = true
      elseif type(block) == "table" and block.type == "tool_result" and block.tool_use_id
        and not seen[block.tool_use_id] then
        return block.tool_use_id
      end
    end
  end
  return nil
end

local function find_tool_use_message(messages, last_idx, id)
  for i = last_idx, 1, -1 do
    if has_tool_use(messages[i], id) then return i end
  end
  return nil
end

local function adjust_cut_for_tool_pairs(messages, cut)
  -- Responses-style providers reject a function_call_output unless the matching
  -- function_call is also present in the replayed context. Avoid compacting away
  -- an assistant tool_use while keeping its following user tool_result verbatim.
  while cut > 0 do
    local missing = tool_results_missing_uses(messages, cut + 1)
    if not missing then break end
    local use_idx = find_tool_use_message(messages, cut, missing)
    if not use_idx then break end
    cut = use_idx - 1
  end
  return cut
end

---@param messages table[] canonical messages
---@param opts table context config
---@return table[] new_messages, table|nil info
function M.compact(messages, opts)
  opts = type(opts) == "table" and opts or {}
  messages = type(messages) == "table" and messages or {}
  local threshold = opts.compact_at_tokens or 120000
  local before_tokens = M.estimate_tokens(messages)
  if before_tokens < threshold then return messages, nil end

  local keep = math.max(2, opts.keep_recent_messages or 16)
  if #messages <= keep + 1 then return messages, nil end

  local cut = adjust_cut_for_tool_pairs(messages, #messages - keep)
  if cut <= 0 then return messages, nil end
  local older = vim.deepcopy(vim.list_slice(messages, 1, cut))
  local recent = strip_replay_only_blocks(vim.list_slice(messages, cut + 1, #messages))

  -- If we are compacting an already-compacted session, carry the previous summary
  -- forward verbatim rather than re-summarizing (and truncating) it or nesting it.
  local carry = nil
  if is_summary_message(older[1]) then
    carry = older[1].content[1].text
    table.remove(older, 1)
  end

  local summary = summarize_messages(older, opts.summary_max_chars or 12000, carry)
  local summary_block = { type = "text", text = summary }
  local compacted
  -- The summary is emitted as a `user` message. Providers such as Anthropic
  -- require strictly alternating user/assistant roles, so if the first retained
  -- message is also a `user` turn we must fold the summary into it rather than
  -- prepend a second consecutive `user` message (which triggers a 400).
  if type(recent[1]) == "table" and recent[1].role == "user" then
    local first = recent[1]
    local content = content_blocks(first)
    local merged = { summary_block }
    for _, b in ipairs(content) do merged[#merged + 1] = b end
    recent[1] = { role = "user", content = merged }
    compacted = recent
  else
    compacted = { { role = "user", content = { summary_block } } }
    vim.list_extend(compacted, recent)
  end
  return compacted, {
    before_tokens = before_tokens,
    after_tokens = M.estimate_tokens(compacted),
    compacted_messages = #older,
  }
end

function M.force(messages, opts)
  opts = vim.tbl_extend("force", opts or {}, { compact_at_tokens = 0 })
  return M.compact(messages, opts)
end

M._SUMMARY_PREFIX = SUMMARY_PREFIX

return M
