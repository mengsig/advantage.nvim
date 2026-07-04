---@brief Conversation compaction for long sessions, in two modes.
---
---The harness keeps full canonical messages while a conversation is small. Once a
---rough token estimate crosses `context.compact_at_tokens`, older messages are
---collapsed into a summary and the newest messages are kept verbatim.
---
---Two independent code paths produce that summary:
---  * `M.compact` / `M.force` — a heuristic, offline, one-line-per-message
---    truncation. No extra model call, so it is free and instant. Used when the
---    selected compaction mode is `"heuristic"` and as the fallback if LLM
---    summarization fails.
---  * `M.summarize_with_llm` — spends one call on `context.summarizer_model` to
---    have a model write a real, semantically-prioritized summary from the
---    *untruncated* older transcript. Async (goes through a provider's
---    `stream()`), used for manual/forced compaction when
---    `context.compact_mode == "llm"`, and for silent auto-compaction when
---    `context.auto_compact_mode == "llm"`.
---Both paths share the same cut-point selection and role/tool-pairing safety
---logic (`prepare_split`) and the same splice-back-in logic (`splice_summary`),
---so the resulting message shape is identical regardless of which mode wrote it.
local M = {}

local SUMMARY_PREFIX = "Conversation context summary (auto-compacted by advantage.nvim)."

local function content_blocks(msg)
  if type(msg) ~= "table" then return { msg } end
  return type(msg.content) == "table" and msg.content or { msg.content }
end

local function block_text(block)
  if type(block) ~= "table" then return tostring(block or "") end
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
    return ("tool_result %s%s: %s"):format(block.tool_use_id or "?", block.is_error and " error" or "", c or "")
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
    -- Image payloads are sent verbatim (base64) and dominate request size, but
    -- block_text collapses them to a placeholder. Count the real bytes so a
    -- conversation carrying images actually triggers compaction/eviction.
    if type(b) == "table" and b.type == "image" and b.source and type(b.source.data) == "string" then
      n = n + #b.source.data
    end
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
    if total + #line + 1 > ceiling then line = utf8_safe_sub(line, math.max(0, ceiling - total - 2)) .. "…" end
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
  if total >= ceiling then lines[#lines + 1] = "[summary truncated]" end
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
          if type(copy) == "table" and copy.type == "tool_use" then copy.openai_item_id = nil end
          content[#content + 1] = copy
        end
      end
      if #content > 0 then out[#out + 1] = { role = msg.role, content = content } end
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
      elseif
        type(block) == "table"
        and block.type == "tool_result"
        and block.tool_use_id
        and not seen[block.tool_use_id]
      then
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

---Shared prep for both compaction paths: pick the cut point (respecting
---tool_use/tool_result pairing), split into older/recent, peel off any pinned
---turns (kept verbatim), and peel off a prior carried-forward summary so repeat
---compaction extends it instead of nesting or re-truncating it. Returns nil if
---there isn't enough history to bother with.
---@return {older: table[], recent: table[], carry: string|nil, pinned: table[]}|nil
local function prepare_split(messages, opts)
  local keep = math.max(2, opts.keep_recent_messages or 16)
  if #messages <= keep + 1 then return nil end

  local cut = adjust_cut_for_tool_pairs(messages, #messages - keep)
  if cut <= 0 then return nil end
  local older = vim.deepcopy(vim.list_slice(messages, 1, cut))
  local recent = strip_replay_only_blocks(vim.list_slice(messages, cut + 1, #messages))

  -- Pin the original task (and any explicitly pinned turn) verbatim: it must
  -- survive compaction unparaphrased and untruncated so the agent never drifts
  -- from what it was asked to do. Legacy sessions saved before the pin flag
  -- existed have no marker, so adopt a leading, non-summary user turn as the
  -- task — old transcripts are protected too.
  if
    type(older[1]) == "table"
    and older[1].role == "user"
    and older[1].pinned == nil
    and not is_summary_message(older[1])
  then
    older[1].pinned = true
  end
  local pinned = {}
  while type(older[1]) == "table" and older[1].pinned do
    pinned[#pinned + 1] = table.remove(older, 1)
  end

  local carry = nil
  if is_summary_message(older[1]) then
    -- Peel the carried summary. splice_summary folds the summary block into the
    -- first retained user message, so on re-compaction that message also carries
    -- its original (post-summary) blocks — keep those as ordinary older content
    -- to be re-summarized instead of dropping them with the whole message.
    local first = older[1]
    carry = first.content[1].text
    if #first.content > 1 then
      first.content = vim.list_slice(first.content, 2)
    else
      table.remove(older, 1)
    end
  end
  return { older = older, recent = recent, carry = carry, pinned = pinned }
end

---Splice a finished summary text back in ahead of the retained `recent`
---messages. The summary is emitted as a `user` message. Providers such as
---Anthropic require strictly alternating user/assistant roles, so if the first
---retained message is also a `user` turn the summary is folded into it rather
---than prepended as a second consecutive `user` message (which triggers a 400).
---@param pinned? table[] verbatim turns to keep ahead of the summary (the original task)
local function splice_summary(recent, summary_text, pinned)
  local summary_block = { type = "text", text = summary_text }
  local spliced
  if type(recent[1]) == "table" and recent[1].role == "user" then
    local merged = { summary_block }
    for _, b in ipairs(content_blocks(recent[1])) do
      merged[#merged + 1] = b
    end
    spliced = { { role = "user", content = merged } }
    for i = 2, #recent do
      spliced[#spliced + 1] = recent[i]
    end
  else
    spliced = { { role = "user", content = { summary_block } } }
    vim.list_extend(spliced, recent)
  end
  -- Prepend pinned turns verbatim. The result may open with two consecutive
  -- user turns (pin, then the summary user message); Anthropic's sanitize_messages
  -- coalesces same-role turns and OpenAI accepts consecutive user input items.
  if pinned and #pinned > 0 then
    local out = {}
    vim.list_extend(out, pinned)
    vim.list_extend(out, spliced)
    return out
  end
  return spliced
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

  local split = prepare_split(messages, opts)
  if not split then return messages, nil end

  local summary = summarize_messages(split.older, opts.summary_max_chars or 12000, split.carry)
  local compacted = splice_summary(split.recent, summary, split.pinned)
  return compacted,
    {
      before_tokens = before_tokens,
      after_tokens = M.estimate_tokens(compacted),
      compacted_messages = #split.older,
    }
end

function M.force(messages, opts)
  opts = vim.tbl_extend("force", opts or {}, { compact_at_tokens = 0 })
  return M.compact(messages, opts)
end

-- LLM-summarized compaction ---------------------------------------------------

local SUMMARIZER_SYSTEM_PROMPT = table.concat({
  "You are compacting an in-progress coding-agent conversation so it can continue with a smaller context window.",
  "Write a dense, structured summary of the transcript below. It replaces the raw messages, so the agent must be able to resume work correctly from it alone (plus the verbatim recent messages that follow it in the real conversation).",
  "",
  "Use these sections, omitting any with nothing to report:",
  "1. Primary Request and Intent — what the user actually asked for, in their own terms.",
  "2. Key Technical Concepts — frameworks, patterns, constraints relevant to the task.",
  "3. Files and Code Sections — every file read, created or edited, why it matters, and any code/diff worth preserving verbatim.",
  "4. Errors and Fixes — problems hit and how they were resolved (or weren't).",
  "5. Problem Solving — decisions made and their reasoning.",
  "6. Pending Tasks — work started but not finished.",
  "7. Current Work — exactly what was being done immediately before this summary was triggered.",
  "8. Next Step — the next action to take, quoting the most recent unresolved user request verbatim.",
  "",
  "If the transcript begins with 'Previously compacted summary', that is an earlier summary of even-older history: update and tighten it in place using the newer messages rather than discarding it or bolting a second summary alongside it.",
  "Be concrete: prefer exact file paths, function names, and command output over vague paraphrase. Do not invent information that isn't in the transcript.",
  "Respond with ONLY the summary text — no preamble, no meta-commentary about being an AI.",
}, "\n")

-- Far more generous than the heuristic path's 900-char cap (that path *is* the
-- compression; this cap just bounds the input to a model that does the actual
-- compressing) but still bounded so one giant tool result can't blow out the
-- summarizer's own context.
local LLM_BLOCK_CHAR_CAP = 6000
-- Hard ceiling on the whole serialized transcript handed to the summarizer.
local LLM_TRANSCRIPT_CHAR_CAP = 400000
-- Safety net on the model's own output so a misbehaving summarizer can't make
-- "compacted" history bigger than the thing it replaced.
local LLM_SUMMARY_CHAR_CEILING = 60000

-- Unlike trim_one_line (used for the heuristic's display-only truncation),
-- this preserves whitespace/newlines: the summarizer needs real code
-- formatting and diff structure to read the transcript accurately.
local function trim_block(s, max)
  s = tostring(s or "")
  if #s > max then return utf8_safe_sub(s, math.max(0, max - 1)) .. "…[truncated]" end
  return s
end

local function serialize_transcript(messages, carry)
  local lines = {}
  if carry and carry ~= "" then
    vim.list_extend(lines, {
      "Previously compacted summary (update/tighten this, don't discard it):",
      carry,
      "",
      "Older messages that aged out since that summary was written:",
      "",
    })
  end
  local total = #table.concat(lines, "\n")
  for i, msg in ipairs(messages) do
    msg = type(msg) == "table" and msg or { role = "?", content = { msg } }
    local parts = {}
    for _, block in ipairs(content_blocks(msg)) do
      parts[#parts + 1] = trim_block(block_text(block), LLM_BLOCK_CHAR_CAP)
    end
    local line = ("%02d %s: %s"):format(i, msg.role or "?", table.concat(parts, " | "))
    if total + #line + 1 > LLM_TRANSCRIPT_CHAR_CAP then
      lines[#lines + 1] = "[remaining older history omitted to fit the summarizer's context]"
      break
    end
    lines[#lines + 1] = line
    total = total + #line + 1
  end
  return table.concat(lines, "\n")
end

local function frame_llm_summary(summary, model_label)
  summary = vim.trim(summary or "")
  if #summary > LLM_SUMMARY_CHAR_CEILING then
    summary = utf8_safe_sub(summary, LLM_SUMMARY_CHAR_CEILING - 1) .. "…[summary truncated]"
  end
  return table.concat({
    SUMMARY_PREFIX .. (" (model summary via %s)."):format(model_label or "llm"),
    "The following is a model-written summary of earlier conversation history. Treat it as prior context; newer messages after this summary are verbatim.",
    "",
    summary,
  }, "\n")
end

local DEFAULT_SUMMARIZERS = {
  anthropic = "anthropic/claude-haiku-4-5",
  openai = "openai/gpt-5.1-codex-mini",
}

---Choose the model that writes the summary. An explicit `summarizer_model` wins;
---otherwise pick a cheap model in the ACTIVE model's provider family so a
---Codex/OpenAI-only user (with no Claude credentials) never triggers a Claude
---request on `/compact`, and vice-versa. Last resort: the active model itself.
---@return table|nil resolved
local function resolve_summarizer(opts, active_model)
  local config = require("advantage.config")
  if opts.summarizer_model and opts.summarizer_model ~= "" then return config.resolve_model(opts.summarizer_model) end
  local provider = active_model and active_model.provider
  local map = opts.summarizer_models or DEFAULT_SUMMARIZERS
  local ref = provider and map[provider]
  if ref then
    local m = config.resolve_model(ref)
    if m then return m end
  end
  -- no cheap same-provider model configured: summarize with the active model so
  -- compaction still works (just not cheaper) rather than failing on wrong creds.
  return active_model
end
M._resolve_summarizer = resolve_summarizer

---Spend one model call to write a real semantic summary of the older half of
---the transcript, then splice it in exactly like the heuristic path does. Used
---when the selected mode is `"llm"` (manual `context.compact_mode` or silent
---auto `context.auto_compact_mode`).
---@param messages table[] canonical messages
---@param opts table context config (keep_recent_messages, summarizer_model, …)
---@param on_done fun(next_messages: table[]|nil, info: table|nil, err: string|nil)
---@param active_model? table the current chat model, used to pick a same-provider summarizer
---@return table|nil job a `{stop = fun()}` handle for the in-flight request, or nil if nothing was sent
function M.summarize_with_llm(messages, opts, on_done, active_model)
  opts = type(opts) == "table" and opts or {}
  messages = type(messages) == "table" and messages or {}
  on_done = on_done or function() end
  local before_tokens = M.estimate_tokens(messages)

  local split = prepare_split(messages, opts)
  if not split then
    on_done(nil, nil, nil)
    return nil
  end

  local providers = require("advantage.providers")
  local resolved = resolve_summarizer(opts, active_model)
  local provider = resolved and providers.get(resolved.provider)
  if not provider then
    on_done(nil, nil, "no usable summarizer model (set context.summarizer_model)")
    return nil
  end

  local transcript = serialize_transcript(split.older, split.carry)
  local usage = { input = 0, output = 0, cached = 0 }

  return provider.stream({
    -- Keep the summarizer cheap/fast regardless of which provider it resolves
    -- to: `thinking = false` is read by the anthropic provider, `reasoning_effort`
    -- by the openai one — each ignores the field it doesn't understand.
    model = { id = resolved.id, thinking = false, reasoning_effort = "minimal" },
    system = SUMMARIZER_SYSTEM_PROMPT,
    messages = { { role = "user", content = { { type = "text", text = transcript } } } },
    tools = nil,
    on = {
      text = function() end,
      thinking = function() end,
      tool_start = function() end,
      usage = function(inp, out, cached)
        usage.input, usage.output, usage.cached = inp or 0, out or 0, cached or 0
      end,
      complete = function(blocks, stop_reason)
        local text = {}
        for _, b in ipairs(blocks or {}) do
          if type(b) == "table" and b.type == "text" and b.text then text[#text + 1] = b.text end
        end
        local summary = vim.trim(table.concat(text, "\n"))
        if summary == "" then
          on_done(nil, nil, "summarizer returned no text (stop_reason: " .. tostring(stop_reason) .. ")")
          return
        end
        local compacted = splice_summary(split.recent, frame_llm_summary(summary, resolved.label), split.pinned)
        on_done(compacted, {
          before_tokens = before_tokens,
          after_tokens = M.estimate_tokens(compacted),
          compacted_messages = #split.older,
          mode = "llm",
          model = resolved,
          usage = usage,
        }, nil)
      end,
      error = function(msg)
        on_done(nil, nil, msg)
      end,
    },
  })
end

M._SUMMARY_PREFIX = SUMMARY_PREFIX

return M
