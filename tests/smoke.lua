-- Headless smoke test: nvim -l tests/smoke.lua
-- Exercises the SSE parser, both provider adapters, the tools, and a full
-- agent turn (with a scripted fake provider) including the UI.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)

-- keep the memory harness (bootstrap writes on agent creation) out of the real repo
local MEMTMP = vim.fn.tempname()
vim.fn.mkdir(MEMTMP, "p")
require("advantage.memory")._root_override = MEMTMP

local failed = 0
local function check(ok, label)
  if ok then
    print("  ok   " .. label)
  else
    failed = failed + 1
    print("  FAIL " .. label)
  end
end

local function section(name)
  print("\n== " .. name)
end

-- 1. SSE parser -------------------------------------------------------------

section("sse parser")
do
  local util = require("advantage.util")
  local events, strays = {}, {}
  local p = util.sse_parser(function(name, data)
    events[#events + 1] = { name = name, data = data }
  end, function(line)
    strays[#strays + 1] = line
  end)
  local stream = {
    "event: message_start",
    'data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}',
    "",
    "event: content_block_delta",
    'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}',
    "",
    ": heartbeat",
    '{"type":"error","error":{"message":"plain body"}}',
    "",
  }
  for _, line in ipairs(stream) do
    p.feed_line(line)
  end
  check(#events == 2, "dispatches complete events")
  check(events[1].name == "message_start" and events[1].data.message.usage.input_tokens == 10, "decodes payloads")
  check(#strays == 1 and strays[1]:find("plain body"), "collects non-SSE lines as stray")

  local modern_diff = vim.text and vim.text.diff or nil
  if vim.text then vim.text.diff = nil end
  local fallback_ok, fallback_diff = pcall(util.text_diff, "before\n", "after\n", { result_type = "unified" })
  if vim.text then vim.text.diff = modern_diff end
  check(
    fallback_ok and type(fallback_diff) == "string" and fallback_diff:find("after", 1, true),
    "text diff falls back to Neovim 0.10's vim.diff API"
  )
  local binary_hash_ok, binary_hash = pcall(util.hash_parts, { "left\0half", "right" })
  check(
    binary_hash_ok and #binary_hash == 64 and binary_hash ~= util.hash_parts({ "left", "half\0right" }),
    "cache identity hashing is NUL-safe and preserves part boundaries on Neovim 0.10"
  )
end

-- 2. anthropic handler --------------------------------------------------------

section("anthropic stream handler")
do
  local anthropic = require("advantage.providers.anthropic")
  local got = { text = {}, thinking = {}, tools = {} }
  local final
  local handler = anthropic._make_handler({
    text = function(t)
      got.text[#got.text + 1] = t
    end,
    thinking = function(t)
      got.thinking[#got.thinking + 1] = t
    end,
    tool_start = function(id, name)
      got.tools[#got.tools + 1] = { id, name }
    end,
    usage = function(i, o, cached, details)
      got.usage = { i, o, cached, details }
    end,
    complete = function(blocks, stop, usage)
      final = { blocks = blocks, stop = stop, usage = usage }
    end,
    error = function(msg)
      got.err = msg
    end,
  })
  local feed = {
    {
      type = "message_start",
      message = { usage = { input_tokens = 12, cache_read_input_tokens = 3, cache_creation_input_tokens = 2 } },
    },
    { type = "content_block_start", index = 0, content_block = { type = "thinking" } },
    { type = "content_block_delta", index = 0, delta = { type = "thinking_delta", thinking = "hm" } },
    { type = "content_block_delta", index = 0, delta = { type = "signature_delta", signature = "sig" } },
    { type = "content_block_stop", index = 0 },
    { type = "content_block_start", index = 1, content_block = { type = "text", text = "" } },
    { type = "content_block_delta", index = 1, delta = { type = "text_delta", text = "let me check" } },
    { type = "content_block_stop", index = 1 },
    { type = "content_block_start", index = 2, content_block = { type = "tool_use", id = "tu_1", name = "bash" } },
    { type = "content_block_delta", index = 2, delta = { type = "input_json_delta", partial_json = '{"comm' } },
    { type = "content_block_delta", index = 2, delta = { type = "input_json_delta", partial_json = 'and":"ls"}' } },
    { type = "content_block_stop", index = 2 },
    { type = "message_delta", delta = { stop_reason = "tool_use" }, usage = { output_tokens = 55 } },
    { type = "message_stop" },
  }
  for _, ev in ipairs(feed) do
    handler(ev.type, ev)
  end
  check(final ~= nil and final.stop == "tool_use", "stop_reason propagated")
  check(
    final.blocks[1].type == "thinking" and final.blocks[1].signature == "sig",
    "thinking block with signature preserved"
  )
  check(final.blocks[2].type == "text" and final.blocks[2].text == "let me check", "text block accumulated")
  check(final.blocks[3].type == "tool_use" and final.blocks[3].input.command == "ls", "tool_use input json assembled")
  check(
    got.usage[1] == 17 and got.usage[2] == 55 and got.usage[3] == 3 and got.usage[4].cache_write == 2,
    "usage reports Anthropic cache reads and cache creation separately"
  )

  -- prompt caching: rolling breakpoints on the two most recent messages so the
  -- static prefix + prior conversation are read from cache instead of re-billed.
  local msgs = {
    { role = "user", content = { { type = "text", text = "one" } } },
    { role = "assistant", content = { { type = "text", text = "two" } } },
    { role = "user", content = { { type = "text", text = "three" } } },
  }
  anthropic._apply_message_cache(msgs)
  check(msgs[3].content[#msgs[3].content].cache_control ~= nil, "cache breakpoint on last message")
  check(msgs[2].content[#msgs[2].content].cache_control ~= nil, "cache breakpoint on second-to-last message")
  check(msgs[1].content[1].cache_control == nil, "older messages carry no breakpoint")

  local signed = {
    { role = "user", content = { { type = "text", text = "ordinary" } } },
    { role = "assistant", content = { { type = "thinking", thinking = "secret", signature = "signed" } } },
  }
  anthropic._apply_message_cache(signed)
  check(
    signed[2].content[1].cache_control == nil and signed[1].content[1].cache_control ~= nil,
    "anthropic cache breakpoints never mutate signed thinking blocks"
  )
end

-- 2b. anthropic credential rotation recovery ---------------------------------

section("anthropic credential rotation recovery")
do
  local auth = require("advantage.auth")
  local config = require("advantage.config")
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local saved_dir = vim.env.CLAUDE_CONFIG_DIR
  local saved_env_key = vim.env.ANTHROPIC_API_KEY
  local saved_inline_key = config.options.providers.anthropic.api_key
  vim.env.CLAUDE_CONFIG_DIR = tmpdir
  vim.env.ANTHROPIC_API_KEY = nil
  config.options.providers.anthropic.api_key = nil
  local credpath = tmpdir .. "/.credentials.json"

  local function write_creds(oauth)
    local f = assert(io.open(credpath, "w"))
    f:write(vim.json.encode({ claudeAiOauth = oauth }))
    f:close()
  end
  local function expired(access, refresh)
    return {
      accessToken = access,
      refreshToken = refresh,
      expiresAt = (os.time() - 10) * 1000,
      subscriptionType = "pro",
    }
  end

  -- Another process wins the refresh and writes a valid replacement before our
  -- failed request returns. Advantage must re-read and use the winner.
  write_creds(expired("old-access", "R1"))
  local race_calls = 0
  auth._post_json = function(_, _, cb)
    race_calls = race_calls + 1
    write_creds({
      accessToken = "winner-access",
      refreshToken = "R2",
      expiresAt = (os.time() + 3600) * 1000,
      subscriptionType = "max",
    })
    cb(nil, "invalid_grant")
  end
  local race_cred, race_err
  auth.anthropic(function(cred, err)
    race_cred, race_err = cred, err
  end)
  check(
    race_calls == 1 and race_cred and race_cred.token == "winner-access" and race_err == nil,
    "a lost Claude refresh race reuses the winner's freshly-written access token"
  )

  -- If only the refresh token rotated and the access token is still expired,
  -- retry that new token exactly once and persist the successful result.
  write_creds(expired("old-access", "R1"))
  local retry_calls = 0
  auth._post_json = function(_, body, cb)
    retry_calls = retry_calls + 1
    if retry_calls == 1 then
      write_creds(expired("other-stale-access", "R2"))
      return cb(nil, "invalid_grant")
    end
    cb({ access_token = "retried-access", refresh_token = "R3", expires_in = 3600 })
  end
  local retry_cred
  auth.anthropic(function(cred)
    retry_cred = cred
  end)
  check(
    retry_calls == 2 and retry_cred and retry_cred.token == "retried-access",
    "a rotated Claude refresh token receives one successful retry"
  )

  -- Even when the unchanged access token still has a future local expiry, a
  -- refresh-only winner must be exchanged instead of reviving that token.
  local refresh_only = {
    accessToken = "same-api-rejected-access",
    refreshToken = "before-rotation",
    expiresAt = (os.time() + 3600) * 1000,
    subscriptionType = "pro",
  }
  write_creds(refresh_only)
  local refresh_only_calls = 0
  auth._post_json = function(_, _, cb)
    refresh_only_calls = refresh_only_calls + 1
    if refresh_only_calls == 1 then
      write_creds(vim.tbl_extend("force", refresh_only, { refreshToken = "after-rotation" }))
      return cb(nil, "invalid_grant")
    end
    cb({ access_token = "fresh-after-rotation", refresh_token = "final-refresh", expires_in = 3600 })
  end
  local refresh_only_cred
  auth.anthropic(function(cred)
    refresh_only_cred = cred
  end, true)
  check(
    refresh_only_calls == 2 and refresh_only_cred and refresh_only_cred.token == "fresh-after-rotation",
    "a refresh-only race never resurrects the same future-expiry API-rejected token"
  )

  -- Forced refresh follows a real 401. A future local expiry alone must never
  -- make the exact same rejected token look recovered.
  local unchanged = {
    accessToken = "same-rejected-access",
    refreshToken = "same-refresh",
    expiresAt = (os.time() + 3600) * 1000,
    subscriptionType = "pro",
  }
  write_creds(unchanged)
  check(
    auth._reload_after_failed_refresh(unchanged) == nil,
    "forced Claude recovery never reuses the unchanged API-rejected token"
  )

  -- JSON null/malformed expiry values degrade to the normal refresh/fallback
  -- path instead of raising arithmetic errors during startup.
  write_creds({ accessToken = "malformed", refreshToken = nil, expiresAt = vim.NIL })
  local malformed_err
  local malformed_ok = pcall(function()
    auth.anthropic(function(_, err)
      malformed_err = err
    end)
  end)
  check(
    malformed_ok and malformed_err ~= nil,
    "malformed Claude expiry metadata fails cleanly without a login-path crash"
  )

  auth._post_json = nil
  vim.env.CLAUDE_CONFIG_DIR = saved_dir
  vim.env.ANTHROPIC_API_KEY = saved_env_key
  config.options.providers.anthropic.api_key = saved_inline_key
  vim.fn.delete(tmpdir, "rf")
end

-- 2c. openai credential validation -------------------------------------------

section("openai credential validation")
do
  local auth = require("advantage.auth")
  local config = require("advantage.config")
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local saved_home = vim.env.CODEX_HOME
  local saved_env_key = vim.env.OPENAI_API_KEY
  local saved_mode = config.options.providers.openai.auth_mode
  local saved_inline_key = config.options.providers.openai.api_key
  vim.env.CODEX_HOME = tmpdir
  vim.env.OPENAI_API_KEY = nil
  config.options.providers.openai.auth_mode = "chatgpt"
  config.options.providers.openai.api_key = nil

  local function token(exp)
    return "x." .. vim.base64.encode(vim.json.encode({ exp = exp })) .. ".x"
  end
  local f = assert(io.open(tmpdir .. "/auth.json", "w"))
  f:write(vim.json.encode({ tokens = { access_token = token("not-a-number"), account_id = {} } }))
  f:close()

  local malformed_err
  local malformed_ok = pcall(function()
    auth.openai(function(_, err)
      malformed_err = err
    end)
  end)
  check(
    malformed_ok and malformed_err ~= nil,
    "malformed Codex expiry and account metadata fail cleanly without constructing invalid headers"
  )

  f = assert(io.open(tmpdir .. "/auth.json", "w"))
  f:write(vim.json.encode({
    tokens = { access_token = token(os.time() - 60), refresh_token = "old-refresh", account_id = "old-account" },
  }))
  f:close()
  local race_calls = 0
  auth._post_json = function(_, _, cb)
    race_calls = race_calls + 1
    local winner = assert(io.open(tmpdir .. "/auth.json", "w"))
    winner:write(vim.json.encode({
      tokens = { access_token = token(os.time() + 3600), refresh_token = "new-refresh", account_id = "new-account" },
    }))
    winner:close()
    cb(nil, "invalid_grant")
  end
  local race_cred
  auth.openai(function(cred)
    race_cred = cred
  end)
  check(
    race_calls == 1 and race_cred and race_cred.account_id == "new-account",
    "a lost Codex refresh race reuses the winner's freshly-written credentials"
  )

  auth._post_json = nil
  vim.env.CODEX_HOME = saved_home
  vim.env.OPENAI_API_KEY = saved_env_key
  config.options.providers.openai.auth_mode = saved_mode
  config.options.providers.openai.api_key = saved_inline_key
  vim.fn.delete(tmpdir, "rf")
end

-- 3. openai handler -----------------------------------------------------------

section("openai stream handler")
do
  local openai = require("advantage.providers.openai")
  local got = { text = {}, tools = {} }
  local final
  local handler = openai._make_handler({
    text = function(t)
      got.text[#got.text + 1] = t
    end,
    thinking = function() end,
    tool_start = function(id, name)
      got.tools[#got.tools + 1] = { id, name }
    end,
    usage = function(i, o)
      got.usage = { i, o }
    end,
    complete = function(blocks, stop, usage)
      final = { blocks = blocks, stop = stop, usage = usage }
    end,
    error = function(msg)
      got.err = msg
    end,
  })
  local feed = {
    { type = "response.output_item.added", item = { type = "reasoning", id = "rs_1" } },
    { type = "response.output_item.done", item = { type = "reasoning", id = "rs_1", encrypted_content = "xxx" } },
    {
      type = "response.output_item.added",
      item = { type = "function_call", id = "fc_1", call_id = "call_1", name = "read_file" },
    },
    { type = "response.function_call_arguments.delta", item_id = "fc_1", delta = '{"path":' },
    {
      type = "response.output_item.done",
      item = {
        type = "function_call",
        id = "fc_1",
        call_id = "call_1",
        name = "read_file",
        arguments = '{"path":"a.lua"}',
      },
    },
    { type = "response.output_text.delta", delta = "on it" },
    {
      type = "response.output_item.done",
      item = {
        type = "message",
        id = "msg_1",
        status = "completed",
        content = { { type = "output_text", text = "on it" } },
      },
    },
    { type = "response.completed", response = { usage = { input_tokens = 9, output_tokens = 21 } } },
  }
  for _, ev in ipairs(feed) do
    handler(ev.type, ev)
  end
  check(final ~= nil and final.stop == "tool_use", "tool_use stop inferred")
  check(final.blocks[1].type == "openai_reasoning", "reasoning item captured for replay")
  check(final.blocks[2].type == "tool_use" and final.blocks[2].input.path == "a.lua", "function_call → tool_use")
  check(final.blocks[3].type == "text" and final.blocks[3].text == "on it", "message → text block")
  local replayed_message = openai._to_input_items({ { role = "assistant", content = { final.blocks[3] } } })[1]
  check(
    replayed_message and replayed_message.type == "message" and replayed_message.id == "msg_1",
    "completed OpenAI message items replay byte-for-byte with their server id"
  )
  check(got.usage[1] == 9 and got.usage[2] == 21, "usage reported")

  local items = openai._to_input_items({
    { role = "user", content = { { type = "tool_result", tool_use_id = "missing", content = "orphan" } } },
    {
      role = "assistant",
      content = { { type = "tool_use", id = "call_ok", name = "bash", input = { command = "true" } } },
    },
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_ok", content = "ok" } } },
  })
  local outputs = 0
  for _, item in ipairs(items) do
    if item.type == "function_call_output" then
      outputs = outputs + 1
      check(item.call_id == "call_ok", "openai input skips orphan function_call_output")
    elseif item.type == "function_call" then
      check(item.status == "completed", "openai replays function calls as completed")
    end
  end
  check(outputs == 1, "openai input only replays matched tool outputs")

  items = openai._to_input_items({
    {
      role = "user",
      content = { { type = "text", text = require("advantage.compact")._SUMMARY_PREFIX .. "\nold context" } },
    },
    {
      role = "assistant",
      content = {
        { type = "openai_reasoning", item = { type = "reasoning", id = "rs_fresh", encrypted_content = "fresh" } },
        {
          type = "tool_use",
          id = "call_after",
          openai_item_id = "fc_stale",
          name = "read_file",
          input = { path = "a" },
        },
      },
    },
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_after", content = "ok" } } },
  })
  local reasoning, id_leaks = 0, 0
  for _, item in ipairs(items) do
    if item.type == "reasoning" then reasoning = reasoning + 1 end
    if item.type == "function_call" and item.id then id_leaks = id_leaks + 1 end
  end
  check(reasoning == 1, "openai preserves fresh reasoning generated after a compaction summary")
  check(id_leaks == 1, "openai preserves fresh function-call ids generated after compaction")

  -- compaction itself must strip the item id from retained tool calls so the
  -- Responses API doesn't demand the reasoning item we removed.
  local compact = require("advantage.compact")
  local reasoned = {
    { role = "user", content = { { type = "text", text = "look" } } },
    {
      role = "assistant",
      content = {
        { type = "openai_reasoning", item = { type = "reasoning", encrypted_content = "x" } },
        {
          type = "tool_use",
          id = "call_keep2",
          openai_item_id = "fc_keep",
          name = "read_file",
          input = { path = "a" },
        },
      },
    },
    {
      role = "user",
      content = { { type = "tool_result", tool_use_id = "call_keep2", content = string.rep("r ", 100) } },
    },
    { role = "assistant", content = { { type = "text", text = string.rep("done ", 100) } } },
  }
  local reasoned_out = select(1, compact.force(reasoned, { keep_recent_messages = 2, summary_max_chars = 1000 }))
  local kept_id
  for _, m in ipairs(reasoned_out) do
    for _, b in ipairs(m.content) do
      if b.type == "tool_use" then kept_id = b.openai_item_id end
    end
  end
  check(kept_id == nil, "compact detaches openai item ids from retained tool calls")

  -- A token-limit stop is a usable partial response, not a transport failure.
  -- Keep its completed output items and the authoritative usage breakdown.
  local incomplete, incomplete_usage
  local incomplete_handler = openai._make_handler({
    text = function() end,
    thinking = function() end,
    tool_start = function() end,
    usage = function(inp, out, cached, details)
      incomplete_usage = { input = inp, output = out, cached = cached, details = details }
    end,
    complete = function(blocks, stop, usage)
      incomplete = { blocks = blocks, stop = stop, usage = usage }
    end,
    error = function(msg)
      incomplete = { error = msg }
    end,
  }, "high")
  incomplete_handler("response.output_item.done", {
    type = "response.output_item.done",
    item = { type = "message", id = "msg_partial", content = { { type = "output_text", text = "partial" } } },
  })
  incomplete_handler("response.incomplete", {
    type = "response.incomplete",
    response = {
      incomplete_details = { reason = "max_output_tokens" },
      usage = {
        input_tokens = 31,
        output_tokens = 17,
        input_tokens_details = { cached_tokens = 11, cache_write_tokens = 4 },
        output_tokens_details = { reasoning_tokens = 9 },
      },
    },
  })
  check(
    incomplete and not incomplete.error and incomplete.stop == "max_tokens" and incomplete.blocks[1].text == "partial",
    "openai preserves completed output when response.incomplete hits the token cap"
  )
  check(
    incomplete_usage
      and incomplete_usage.cached == 11
      and incomplete_usage.details.reasoning == 9
      and incomplete_usage.details.cache_write == 4
      and incomplete_usage.details.effort == "high",
    "openai preserves cache, reasoning, and effective-effort usage details on incomplete responses"
  )

  -- Some streams end before output_item.done. Preserve the text deltas, but do
  -- not execute a function_call that the server marks incomplete.
  local cut
  local cut_handler = openai._make_handler({
    text = function() end,
    thinking = function() end,
    tool_start = function() end,
    usage = function() end,
    complete = function(blocks, stop)
      cut = { blocks = blocks, stop = stop }
    end,
    error = function(msg)
      cut = { error = msg }
    end,
  }, "high")
  cut_handler("response.output_text.delta", { type = "response.output_text.delta", delta = "cut but useful" })
  cut_handler("response.incomplete", {
    type = "response.incomplete",
    response = {
      incomplete_details = { reason = "max_output_tokens" },
      output = {
        { type = "function_call", status = "incomplete", call_id = "half", name = "bash", arguments = '{"command":' },
      },
      usage = {},
    },
  })
  check(
    cut
      and not cut.error
      and cut.stop == "max_tokens"
      and #cut.blocks == 1
      and cut.blocks[1].type == "text"
      and cut.blocks[1].text == "cut but useful",
    "openai keeps undelimited partial text and never runs a truncated function call"
  )
end

-- 4. tools ---------------------------------------------------------------------

section("tools")
do
  local tools = require("advantage.tools")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local ctx = { cwd = tmp }

  local done, result, is_err

  local function run(name, input)
    done, result, is_err = false, nil, nil
    tools.get(name).run(input, ctx, function(out, err)
      result, is_err, done = out, err, true
    end)
    vim.wait(5000, function()
      return done
    end, 10)
    return result, is_err
  end

  local r = assert(run("write_file", { path = "x/hello.txt", content = "alpha\nbeta\ngamma\n" }))
  check(r:find("Wrote 4 lines"), "write_file creates nested file")

  r = assert(run("read_file", { path = "x/hello.txt" }))
  check(r:find("1→alpha") and r:find("3→gamma"), "read_file returns numbered lines")

  -- Big dense multi-byte file: the size budget must stop on a clean line
  -- boundary (never mid-character, which produced invalid UTF-8 and a provider
  -- 400) and hand back an ACCURATE resume offset so the whole file is reachable.
  do
    local util = require("advantage.util")
    -- each line carries a 3-byte glyph (→) so a byte-index cut would land
    -- mid-character; ~90 bytes/line × 900 lines comfortably exceeds the budget.
    local big = {}
    for i = 1, 900 do
      big[i] = ("line %d → %s"):format(i, string.rep("x", 60))
    end
    assert(run("write_file", { path = "big.txt", content = table.concat(big, "\n") }))

    local function strict_utf8_ok(s)
      -- lua has no strict validator; round-trip through the scrubber and require
      -- it to be a no-op (scrub only changes a string that is already invalid).
      return util.scrub_utf8(s) == s
    end

    local pages, off, covered, guard = 0, 1, 0, 0
    while true do
      local page = assert(run("read_file", { path = "big.txt", offset = off }))
      pages = pages + 1
      guard = guard + 1
      check(strict_utf8_ok(page), "read_file page " .. pages .. " is valid UTF-8 (no mid-char cut)")
      local nxt = page:match("continue with offset=(%d+)")
      if nxt then
        covered = tonumber(nxt) - 1
        off = tonumber(nxt)
      else
        for ln in page:gmatch("\n?%s*(%d+)→") do
          covered = tonumber(ln)
        end
        break
      end
      if guard > 20 then break end
    end
    check(pages >= 2, "a file over the size budget spans multiple pages")
    check(covered == 900, "paginating with the reported offset covers every line (no loss)")

    -- A non-positive limit must not yield an empty page that resumes at the same
    -- offset (a paging livelock); limit is floored to 1.
    local zp = assert(run("read_file", { path = "big.txt", limit = 0 }))
    check(
      zp:find("1→", 1, true) and not zp:find("continue with offset=1", 1, true),
      "read_file floors a non-positive limit to 1 (no livelock)"
    )

    -- Belt-and-suspenders: an encoded body carrying genuinely invalid bytes (a
    -- command emitting Latin-1) is scrubbed to valid UTF-8 instead of 400ing.
    local bad = util.scrub_utf8(vim.json.encode({ t = "x\xe9\xff\xe2\x86 y" }))
    check(util.scrub_utf8(bad) == bad and not bad:find("\xff"), "scrub_utf8 makes an invalid body valid")
    check(util.utf8_safe_sub("ab→cd", 3) == "ab", "utf8_safe_sub backs off a mid-character cut")
    local byte_limits = util.partition_byte_budget(7, 3)
    check(
      #byte_limits == 3 and byte_limits[1] + byte_limits[2] + byte_limits[3] == 7,
      "fan-out byte partitions preserve the exact aggregate ceiling"
    )
    check(
      #util.truncate_to_bytes("abcdefghij", 7, "…") <= 7,
      "truncation markers stay inside (not beyond) the configured byte ceiling"
    )
  end

  r = assert(run("edit_file", { path = "x/hello.txt", old_string = "beta", new_string = "BETA" }))
  check(r:find("Applied 1 replacement"), "edit_file replaces unique string")

  local _, err = run("edit_file", { path = "x/hello.txt", old_string = "nope", new_string = "x" })
  check(err == true, "edit_file errors on missing old_string")

  -- validate_input: the classic "model dropped path" case gets a crisp,
  -- self-correcting error naming the missing arg and what was provided.
  local ve = tools.validate_input("edit_file", { old_string = "a", new_string = "b" })
  check(
    ve
      and ve:find("missing required argument: path", 1, true)
      and ve:find("You provided: new_string, old_string", 1, true),
    "validate_input names the missing arg and provided args"
  )
  check(
    tools.validate_input("edit_file", {}):find("no arguments", 1, true),
    "validate_input flags a truncated/empty tool call"
  )
  check(
    tools.validate_input("edit_file", { path = "p", old_string = "a", new_string = "b" }) == nil,
    "validate_input passes a complete call"
  )
  -- present-but-empty required field is valid (edit_file new_string='' deletes)
  check(
    tools.validate_input("edit_file", { path = "p", old_string = "a", new_string = "" }) == nil,
    "validate_input allows empty-string required field"
  )
  check(tools.validate_input("read_file", { path = "p" }) == nil, "validate_input passes read_file with path")
  local type_err = tools.validate_input("edit_file", { path = 42, old_string = "a", new_string = "b" })
  check(
    type_err and type_err:find("input.path must be string", 1, true),
    "validate_input rejects malformed argument types before tool summaries or runners can crash"
  )
  local nested_type_err = tools.validate_input("multi_edit", {
    path = "p",
    edits = { { old_string = "a", new_string = 7 } },
  })
  check(
    nested_type_err and nested_type_err:find("input.edits[1].new_string must be string", 1, true),
    "validate_input recursively checks nested array item types"
  )
  local turn_bound_err = tools.validate_input("sub_agent", {
    prompt = "inspect",
    model = "sol",
    effort = "medium",
    max_turns = (require("advantage.config").options.subagents.max_turns_cap or 12) + 1,
  })
  check(
    turn_bound_err and turn_bound_err:find("input.max_turns must be at most", 1, true),
    "validate_input enforces live numeric maximums instead of silently clamping malformed scout calls"
  )
  local empty_batch_err = tools.validate_input("sub_agent_batch", { mode = "parallel", tasks = {} })
  check(
    empty_batch_err and empty_batch_err:find("input.tasks must contain at least 1 item", 1, true),
    "validate_input enforces array minItems before a batch runner starts"
  )

  r = assert(run("bash", { command = "echo out; echo err >&2; exit 3" }))
  check(r:find("out") and r:find("err") and r:find("exit code 3"), "bash merges output + exit code")

  r = assert(run("grep", { pattern = "BETA", path = "." }))
  check(r:find("hello.txt") ~= nil, "grep finds matches")

  r = assert(run("list_dir", { path = "x" }))
  check(r:find("hello.txt"), "list_dir lists entries")

  local preview = tools.get("edit_file").preview({ path = "x/hello.txt", old_string = "BETA", new_string = "b" }, ctx)
  local joined = table.concat(preview.lines, "\n")
  check(preview.filetype == "diff" and joined:find("-BETA") and joined:find("+b"), "edit preview is a unified diff")

  _, err = run("edit_file", { path = "x/hello.txt", old_string = "", new_string = "x", replace_all = true })
  check(err == true, "edit_file rejects empty old_string (no freeze)")
  local p2 =
    tools.get("edit_file").preview({ path = "x/hello.txt", old_string = "", new_string = "x", replace_all = true }, ctx)
  check(p2.lines[1]:find("invalid edit") ~= nil, "edit preview rejects empty old_string (no freeze)")
  -- optional streaming bash output reports partial chunks before the final result
  local streams = {}
  done, result, is_err = false, nil, nil
  local h = tools
    .get("bash")
    .run({ command = "printf one; sleep 0.05; printf two", stream = true }, ctx, function(out, err, meta)
      if meta and meta.stream then
        streams[#streams + 1] = out
      else
        result, is_err, done = out, err, true
      end
    end)
  check(type(h) == "table" and h.stop ~= nil, "bash returns a cancellable handle")
  vim.wait(5000, function()
    return done
  end, 10)
  local streamed = assert(result)
  check(
    #streams >= 1 and streamed:find("one") and streamed:find("two") and not is_err,
    "bash can stream partial output"
  )

  -- cancellation stops a running command and reports an error final result
  done, result, is_err = false, nil, nil
  h = tools.get("bash").run({ command = "sleep 5; echo too-late", timeout_ms = 10000 }, ctx, function(out, err)
    result, is_err, done = out, err, true
  end)
  h.stop()
  vim.wait(5000, function()
    return done
  end, 10)
  check(is_err == true and assert(result):find("cancelled", 1, true), "bash cancellation stops the command")
end

-- 4-navgraph. optional read-only semantic navigator ----------------------------

section("navgraph tool")
do
  local config = require("advantage.config")
  local tools = require("advantage.tools")
  local uv = vim.uv or vim.loop
  local saved = vim.deepcopy(config.options.tools.navgraph)
  local old_log = vim.env.ADV_NAVGRAPH_TEST_LOG
  local old_capabilities = vim.env.ADV_NAVGRAPH_TEST_CAPABILITIES
  local old_probe_log = vim.env.ADV_NAVGRAPH_TEST_PROBE_LOG
  local tmp = vim.fn.tempname()
  local repo = tmp .. "/repo root"
  local executable = tmp .. "/pinned navgraph"
  local log = tmp .. "/argv.log"
  local probe_log = tmp .. "/probe.log"
  local capability_file = tmp .. "/capabilities.json"
  local injected_file = tmp .. "/shell-injection-ran"
  vim.fn.mkdir(repo .. "/src", "p")
  vim.fn.writefile({ "return 1" }, repo .. "/src/a.lua")
  local fake_script = {
    "#!/bin/sh",
    'if [ "$1" = "capabilities" ]; then',
    '  printf x >> "$ADV_NAVGRAPH_TEST_PROBE_LOG"',
    '  cat "$ADV_NAVGRAPH_TEST_CAPABILITIES"',
    "  exit 0",
    "fi",
    'printf \'%s\\n\' "$@" > "$ADV_NAVGRAPH_TEST_LOG"',
    'if [ "$2" = "slow" ]; then exec sleep 5; fi',
    'if [ "${2%%:*}" = "flood" ]; then',
    "  i=0",
    '  while [ "$i" -lt 2000 ]; do printf x; i=$((i + 1)); done',
    "  exit 0",
    "fi",
    'if [ "$2" = "stderr-flood" ]; then',
    "  i=0",
    '  while [ "$i" -lt 2000 ]; do printf e >&2; i=$((i + 1)); done',
    "  exit 2",
    "fi",
    'if [ "$2" = "missing" ]; then printf \'(no symbol matching missing)\\n\'; exit 1; fi',
    "if [ \"$2\" = \"missingwarn\" ]; then printf '(no symbol matching missingwarn)\\n'; printf 'navgraph: parse-health: bad.js: tokenizer lost sync\\n' >&2; exit 1; fi",
    'if [ "$2" = "broken" ]; then printf \'fatal: bad revision\\n\' >&2; exit 1; fi',
    'if [ "$2" = "bad" ]; then printf \'bad invocation\\n\' >&2; exit 2; fi',
    "if [ \"$2\" = \"warn\" ]; then printf 'one row\\n'; printf 'parse warning\\n' >&2; exit 0; fi",
    "printf 'query ok\\n'",
  }
  vim.fn.writefile(fake_script, executable)
  vim.fn.system({ "chmod", "+x", executable })
  vim.env.ADV_NAVGRAPH_TEST_LOG = log
  vim.env.ADV_NAVGRAPH_TEST_CAPABILITIES = capability_file
  vim.env.ADV_NAVGRAPH_TEST_PROBE_LOG = probe_log

  local live_options = {
    outline = { "root", "no_cache", "limit", "verbosity", "kind" },
    def = { "root", "no_cache", "verbosity" },
    calls = { "root", "no_cache", "limit", "verbosity", "depth", "refs", "strict" },
    callers = { "root", "no_cache", "limit", "verbosity", "depth", "strict" },
    search = { "root", "no_cache", "limit", "verbosity", "kind", "refs" },
    routes = { "root", "no_cache", "limit", "verbosity" },
    -- Indexed/cache-writing commands that omit no_cache must be intersected
    -- out of the model-facing profile.
    events = { "root", "limit" },
    neighbors = { "root", "no_cache", "limit", "verbosity", "refs", "strict" },
    unused = { "root", "no_cache", "limit", "verbosity", "no_public", "follow_imports" },
    imports = { "root", "no_cache" },
    importers = { "root", "no_cache" },
    path = { "root", "no_cache", "verbosity", "strict" },
    hot = { "root", "no_cache", "limit", "verbosity" },
    files = { "root", "no_cache", "limit", "sort" },
    -- Hardened NavGraph read is intrinsically cacheless and therefore does not
    -- advertise an inapplicable no_cache option.
    read = { "root", "limit" },
    strings = { "root", "no_cache", "limit" },
  }
  local argument_count = {
    outline = 1,
    def = 1,
    calls = 1,
    callers = 1,
    search = 1,
    routes = 1,
    events = 1,
    neighbors = 1,
    unused = 1,
    imports = 1,
    importers = 1,
    path = 2,
    hot = 1,
    files = 1,
    read = 1,
    strings = 1,
  }
  local function capability_manifest(overrides)
    local commands = {}
    for _, name in ipairs(require("advantage.navgraph_capabilities").policy_commands) do
      local arguments = {}
      for i = 1, argument_count[name] do
        arguments[#arguments + 1] = { name = "arg" .. i, kind = "string", required = i <= (name == "path" and 2 or 0) }
      end
      commands[#commands + 1] = {
        name = name,
        arguments = arguments,
        options = vim.deepcopy(live_options[name]),
        outputModes = { "text", "json" },
        access = "read_only",
        requiresIndex = name ~= "read",
        cacheEffect = name == "read" and "none" or "may_read_write",
      }
    end
    commands[#commands + 1] = {
      name = "flow",
      arguments = { { name = "symbol", kind = "symbol", required = true } },
      options = { "root", "no_cache", "limit" },
      outputModes = { "text", "json" },
      access = "read_only",
      requiresIndex = true,
      cacheEffect = "may_read_write",
    }
    commands[#commands + 1] = {
      name = "rename",
      arguments = {
        { name = "symbol", kind = "symbol", required = true },
        { name = "new_name", kind = "new_name", required = true },
      },
      options = { "root", "no_cache", "preview" },
      outputModes = { "text", "json" },
      access = "mutating",
      requiresIndex = true,
      cacheEffect = "may_read_write",
    }
    return vim.tbl_deep_extend("force", {
      schema = "navgraph.capabilities.v1",
      schemaVersion = 1,
      agentProtocolVersion = "1.0",
      build = { product = "navgraph", buildId = "navgraph@test-current", version = "0.1.0" },
      schemaHash = "wyhash64:test-current",
      languages = {
        { name = "lua", family = "lua", extensions = { ".lua" }, analysis = "heuristic" },
        { name = "java", family = "java", extensions = { ".java" }, analysis = "heuristic" },
      },
      server = {
        queryTool = "navgraph.query",
        querySchema = "navgraph.agent.query.v1",
        resultSchema = "navgraph.agent.result.v1",
      },
      commands = commands,
      options = {},
    }, overrides or {})
  end
  local valid_manifest = capability_manifest()
  vim.fn.writefile({ vim.json.encode(valid_manifest) }, capability_file)
  require("advantage.navgraph_capabilities")._reset_cache()

  local function has_schema(name)
    for _, schema in ipairs(tools.schemas()) do
      if schema.name == name then return schema end
    end
  end

  local function run(input, wait_ms)
    local output, is_error, meta, done
    local handle = tools.get("navgraph").run(input, { cwd = repo }, function(text, err, details)
      output, is_error, meta, done = text, err, details, true
    end)
    vim.wait(wait_ms or 3000, function()
      return done == true
    end, 10)
    return output, is_error, handle, done, meta
  end

  config.options.tools.navgraph = {
    enabled = false,
    executable = executable,
    timeout_ms = 1000,
    max_results = 80,
    max_output_bytes = 30000,
  }
  check(not has_schema("navgraph"), "navgraph is opt-in and absent from the baseline schema")
  config.options.tools.navgraph.enabled = true
  config.options.tools.navgraph.executable = tmp .. "/missing"
  check(not has_schema("navgraph"), "navgraph schema is withheld when the configured executable is unavailable")
  local non_executable = tmp .. "/not-executable"
  vim.fn.writefile({ "not a program" }, non_executable)
  vim.fn.system({ "chmod", "-x", non_executable })
  config.options.tools.navgraph.executable = non_executable
  local nonexec_ok, nonexec_schema = pcall(has_schema, "navgraph")
  check(
    nonexec_ok and nonexec_schema == nil,
    "navgraph withholds a non-executable regular-file pin instead of crashing schema generation"
  )

  -- Executability can change after stat and a provider can wedge. Both cases
  -- must fail closed without throwing from schema generation or immediately
  -- attempting the same synchronous handshake twice.
  local capability_state = require("advantage.navgraph_capabilities")
  local race_executable = tmp .. "/race-navgraph"
  vim.fn.writefile(fake_script, race_executable)
  vim.fn.system({ "chmod", "+x", race_executable })
  local old_system, old_notify = vim.system, vim.notify
  local spawn_calls = 0
  vim.system = function(argv, options, on_exit)
    if argv[1] == race_executable then
      spawn_calls = spawn_calls + 1
      error("simulated executable replacement race")
    end
    return old_system(argv, options, on_exit)
  end
  vim.notify = function() end
  capability_state._reset_cache()
  local spawn_ok, spawn_profile, spawn_err = pcall(capability_state.profile, {
    executable = race_executable,
    timeout_ms = 5000,
  })
  vim.wait(20)
  vim.system, vim.notify = old_system, old_notify
  check(
    spawn_ok and spawn_profile == nil and spawn_err:find("could not start", 1, true) and spawn_calls == 1,
    "navgraph contains a capability-spawn race and does not retry the same broken executable"
  )

  local timeout_executable = tmp .. "/timeout-navgraph"
  vim.fn.writefile(fake_script, timeout_executable)
  vim.fn.system({ "chmod", "+x", timeout_executable })
  local timeout_probe_calls = 0
  old_system, old_notify = vim.system, vim.notify
  vim.system = function(argv, options, on_exit)
    if argv[1] == timeout_executable then
      timeout_probe_calls = timeout_probe_calls + 1
      return {
        wait = function()
          return { code = 124, signal = 0, stdout = "", stderr = "Command timed out" }
        end,
      }
    end
    return old_system(argv, options, on_exit)
  end
  vim.notify = function() end
  capability_state._reset_cache()
  local timeout_ok, timeout_profile = pcall(capability_state.profile, {
    executable = timeout_executable,
    timeout_ms = 5000,
  })
  vim.wait(20)
  vim.system, vim.notify = old_system, old_notify
  check(
    timeout_ok and timeout_profile == nil and timeout_probe_calls == 1,
    "a timed-out capability probe never doubles the synchronous startup delay with a fallback probe"
  )

  config.options.tools.navgraph.executable = executable
  local schema = has_schema("navgraph")
  check(schema ~= nil, "an enabled, executable NavGraph pin exposes the tool")
  local profile = tools.get("navgraph").capability_profile()
  local schema_again = has_schema("navgraph")
  check(
    profile
      and profile.mode == "negotiated"
      and profile.build.buildId == "navgraph@test-current"
      and profile.language_set.java == true
      and profile.typed_query_available == true
      and profile.literal_positionals == true
      and profile.adapter_transport == "cli"
      and profile.cache_policy.read.intrinsically_cacheless == true
      and profile.cache_policy.read.inject_no_cache == false
      and profile.cache_policy.files.inject_no_cache == true
      and vim.deep_equal(schema, schema_again)
      and #(vim.fn.readfile(probe_log)[1] or "") == 1,
    "NavGraph negotiates the current Java-aware contract once per executable identity and freezes a deterministic schema"
  )
  local agent_mod = require("advantage.agent")
  local scout_navgraph_prompt = require("advantage.subagent")._system_prompt(2, repo)
  local navgraph_part, built_in_parts = false, {}
  for _, part in ipairs(agent_mod.system_prompt_parts(nil)) do
    if part.label == "navgraph guide" then navgraph_part = true end
    if not part.is_memory then built_in_parts[#built_in_parts + 1] = part.text end
  end
  local built_in_prompt = table.concat(built_in_parts, "\n\n")
  check(
    not navgraph_part
      and not built_in_prompt:find("NavGraph", 1, true)
      and not scout_navgraph_prompt:find("NavGraph", 1, true),
    "enabled NavGraph relies on its typed tool schema without injecting tool-specific prompt guidance"
  )
  local enum = schema and schema.input_schema.properties.command.enum or {}
  local properties = schema and schema.input_schema.properties or {}
  check(
    vim.tbl_contains(enum, "outline")
      and vim.tbl_contains(enum, "read")
      and not vim.tbl_contains(enum, "events")
      and not vim.tbl_contains(enum, "diff")
      and not vim.tbl_contains(enum, "flow")
      and not vim.tbl_contains(enum, "rename")
      and not vim.tbl_contains(enum, "serve")
      and not vim.tbl_contains(enum, "mcp"),
    "navgraph schema intersects live capabilities with conservative access and cache policy"
  )
  check(
    properties.target
      and properties.destination
      and properties.limit
      and properties.depth
      and properties.kind
      and properties.refs
      and properties.strict
      and properties.sort
      and properties.exclude_public
      and properties.follow_imports
      and properties.limit.maximum == 80
      and not properties.flags
      and not properties.detail
      and not properties.args,
    "navgraph exposes live-bounded typed targeting instead of raw argv"
  )
  check(
    schema.description:find("never call it merely", 1, true)
      and schema.description:find("instead of parallel", 1, true)
      and properties.target.description:find("files=repository path filter", 1, true)
      and properties.target.description:find("search=one identifier/name", 1, true)
      and properties.target.description:find("strings=literal substring", 1, true)
      and properties.target.description:find("routes/events=route/event%-key")
      and properties.target.description:find("imports/importers=repository path filter", 1, true)
      and properties.target.description:find("flag text", 1, true)
      and properties.target.description:find("safely supports leading%-hyphen")
      and properties.target.description:find("first bounded prefix", 1, true),
    "NavGraph schema teaches optional single-route use and command-specific positional contracts"
  )
  check(
    tools.validate_input("navgraph", { command = "search", target = "resolve", destination = "" }) == nil,
    "normal tool validation treats an empty optional NavGraph field as omitted"
  )
  local live_cap_err = tools.validate_input("navgraph", { command = "files", limit = 81 })
  check(
    live_cap_err and live_cap_err:find("at most 80", 1, true),
    "normal tool validation exposes the live NavGraph result maximum"
  )
  local raw_field_err = tools.validate_input("navgraph", { command = "files", flags = {} })
  check(
    raw_field_err and raw_field_err:find("not supported", 1, true),
    "normal tool validation rejects unadvertised NavGraph argv fields"
  )
  local scout_has_navgraph, scout_navgraph_schema = false, nil
  for _, readonly in ipairs(require("advantage.subagent")._readonly_tools()) do
    if readonly.name == "navgraph" then
      scout_has_navgraph = true
      scout_navgraph_schema = readonly.input_schema
    end
  end
  check(
    tools.get("navgraph").safe == true and scout_has_navgraph and scout_navgraph_schema.properties.limit.maximum == 80,
    "the read-only NavGraph adapter and its live cap are identical for parent and scouts"
  )

  local discovery = { type = "tool_result", tool_use_id = "nav_discovery", content = string.rep("map", 300) }
  tools.mark_context_result(discovery, tools.get("navgraph"), { command = "outline", target = "src" }, false)
  local discovery_messages = { { role = "user", content = { discovery } } }
  discovery_messages = tools.age_context_results(discovery_messages)
  local first_discovery = discovery_messages[1].content[1].content
  discovery_messages = tools.age_context_results(discovery_messages)
  discovery = discovery_messages[1].content[1]
  check(
    #first_discovery == 900 and #discovery.content < 160 and discovery.content:find("NavGraph outline", 1, true),
    "large discovery output is full for one reasoning turn, then becomes a short reopenable receipt"
  )

  local exact_source = { type = "tool_result", tool_use_id = "nav_source", content = string.rep("source", 120) }
  tools.mark_context_result(exact_source, tools.get("navgraph"), { command = "def", target = "Thing@src/a.lua" }, false)
  local source_messages = { { role = "user", content = { exact_source } } }
  source_messages = tools.age_context_results(source_messages)
  source_messages = tools.age_context_results(source_messages)
  local second_source = source_messages[1].content[1].content
  source_messages = tools.age_context_results(source_messages)
  exact_source = source_messages[1].content[1]
  check(
    #second_source == 720 and #exact_source.content < 180 and exact_source.content:find("Thing@src/a.lua", 1, true),
    "exact NavGraph source survives two reasoning turns before bounded receipt elision"
  )

  local replay_result = { type = "tool_result", tool_use_id = "nav_replay", content = string.rep("graph", 180) }
  local replay_messages = {
    {
      role = "assistant",
      content = {
        { type = "openai_reasoning", item = { type = "reasoning", id = "rs_stale", encrypted_content = "opaque" } },
        {
          type = "tool_use",
          id = "nav_replay",
          openai_item_id = "fc_stale",
          name = "navgraph",
          input = { command = "outline", target = "src" },
        },
      },
    },
    { role = "user", content = { replay_result } },
  }
  tools.mark_context_result(replay_result, tools.get("navgraph"), { command = "outline", target = "src" }, false)
  replay_messages = tools.age_context_results(replay_messages)
  local detached
  replay_messages, detached = tools.age_context_results(replay_messages)
  local openai_items = require("advantage.providers.openai")._to_input_items(replay_messages)
  local replay_has_private, replay_has_server_id, replay_has_receipt = false, false, false
  for _, item in ipairs(openai_items) do
    if item.type == "reasoning" then replay_has_private = true end
    if item.type == "function_call" and item.id then replay_has_server_id = true end
    if item.type == "function_call_output" and tostring(item.output):find("consumed", 1, true) then
      replay_has_receipt = true
    end
  end
  check(
    detached >= 2 and not replay_has_private and not replay_has_server_id and replay_has_receipt,
    "context receipt elision atomically detaches stale OpenAI replay artifacts"
  )

  -- Claude's latest signed thinking + tool-use message is a continuous turn:
  -- Anthropic rejects *any* preceding-context mutation while its tool results
  -- are being submitted. An older result that is otherwise ready to expire
  -- therefore waits until a non-tool assistant message closes that turn.
  local old_result = { type = "tool_result", tool_use_id = "nav_old", content = string.rep("old-map", 100) }
  local claude_loop = {
    {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "old reasoning", signature = "sig-old" },
        { type = "tool_use", id = "nav_old", name = "navgraph", input = { command = "outline", target = "src" } },
      },
    },
    { role = "user", content = { old_result } },
  }
  tools.mark_context_result(old_result, tools.get("navgraph"), { command = "outline", target = "src" }, false)
  claude_loop = tools.age_context_results(claude_loop)
  local fresh_result = { type = "tool_result", tool_use_id = "fresh_tool", content = "fresh result" }
  claude_loop[#claude_loop + 1] = {
    role = "assistant",
    content = {
      { type = "thinking", thinking = "fresh reasoning", signature = "sig-fresh" },
      { type = "redacted_thinking", data = "redacted-fresh" },
      { type = "tool_use", id = "fresh_tool", name = "read_file", input = { path = "src/a.lua" } },
    },
  }
  claude_loop[#claude_loop + 1] = { role = "user", content = { fresh_result } }
  check(tools.has_pending_signed_tool_loop(claude_loop), "signed Claude tool continuations are detected")
  local deferred, deferred_detached = tools.expire_context_results(claude_loop)
  local sanitized_pending = require("advantage.providers.anthropic")._sanitize_messages(deferred)
  local latest_pending = sanitized_pending[#sanitized_pending - 1]
  check(
    deferred == claude_loop
      and deferred_detached == 0
      and old_result.content == string.rep("old-map", 100)
      and latest_pending.role == "assistant"
      and latest_pending.content[1].signature == "sig-fresh"
      and latest_pending.content[2].data == "redacted-fresh"
      and latest_pending.content[3].id == "fresh_tool",
    "receipt aging preserves the complete latest Claude thinking/tool-use turn and preceding context"
  )
  claude_loop[#claude_loop + 1] = { role = "assistant", content = { { type = "text", text = "done" } } }
  check(
    not tools.has_pending_signed_tool_loop(claude_loop),
    "a completed assistant response closes the signed tool loop"
  )
  claude_loop, detached = tools.expire_context_results(claude_loop)
  local sanitized_complete = require("advantage.providers.anthropic")._sanitize_messages(claude_loop)
  local complete_has_thinking, complete_has_receipt = false, false
  for _, message in ipairs(sanitized_complete) do
    for _, block in ipairs(message.content) do
      if block.type == "thinking" or block.type == "redacted_thinking" then complete_has_thinking = true end
      if block.type == "tool_result" and tostring(block.content):find("consumed", 1, true) then
        complete_has_receipt = true
      end
    end
  end
  check(
    detached >= 3 and complete_has_receipt and not complete_has_thinking,
    "receipt aging resumes and detaches stale Claude replay state after the continuous tool turn closes"
  )

  local copied_result = { type = "tool_result", tool_use_id = "nav_copy", content = string.rep("copy", 180) }
  local copied_messages = { { role = "user", content = { copied_result } } }
  tools.mark_context_result(copied_result, tools.get("navgraph"), { command = "outline", target = "src" }, false)
  copied_messages = tools.age_context_results(copied_messages)
  local policy_snapshot = tools.snapshot_context_results(copied_messages)
  copied_messages = tools.restore_context_results(vim.deepcopy(copied_messages), policy_snapshot)
  copied_messages = tools.age_context_results(copied_messages)
  check(
    copied_messages[1].content[1].content:find("consumed", 1, true) ~= nil,
    "compaction copies retain semantic-result aging policy by tool-use id"
  )

  local persisted_result = { type = "tool_result", tool_use_id = "nav_persist", content = string.rep("persist", 100) }
  local persisted_messages = { { role = "user", content = { persisted_result } } }
  tools.mark_context_result(persisted_result, tools.get("navgraph"), { command = "outline", target = "src" }, false)
  persisted_messages = tools.age_context_results(persisted_messages)
  local session = require("advantage.session")
  local saved_session_dir = session._dir_override
  session._dir_override = tmp .. "/sessions"
  local persisted_ok = session.save({
    id = "navgraph-retention",
    title = "retention",
    model = { provider = "fake", id = "fake" },
    harness_mode = "auto",
    messages = persisted_messages,
    usage = {},
    ctx = { cwd = repo },
  })
  local persisted_data = session.list(repo)[1]
  local resumed = require("advantage.agent").new({
    model = { provider = "fake", id = "fake" },
    messages = persisted_data and persisted_data.messages or {},
    context_results = persisted_data and persisted_data.context_results or {},
    cwd = repo,
  })
  resumed.messages = tools.age_context_results(resumed.messages)
  check(
    persisted_ok == true and resumed.messages[1].content[1].content:find("consumed", 1, true) ~= nil,
    "session reload restores deferred semantic-result aging instead of retaining full payloads forever"
  )
  session._dir_override = saved_session_dir

  local pending_result = { type = "tool_result", tool_use_id = "nav_pending", content = string.rep("source", 120) }
  local pending_messages = {
    {
      role = "assistant",
      content = {
        { type = "tool_use", id = "nav_pending", name = "navgraph", input = { command = "def", target = "Thing" } },
      },
    },
    { role = "user", content = { pending_result } },
  }
  tools.mark_context_result(pending_result, tools.get("navgraph"), { command = "def", target = "Thing" }, false)
  pending_messages = tools.expire_context_results(pending_messages)
  check(
    #pending_messages[2].content[1].content < 160 and pending_messages[2].content[1].content:find("Thing", 1, true),
    "pending semantic results become durable receipts at save/compaction boundaries"
  )

  vim.fn.delete(log)
  config.options.tools.navgraph.enabled = false
  local disabled_output, disabled_error = run({ command = "files" })
  check(
    disabled_error == true and disabled_output == "NavGraph is disabled" and vim.fn.filereadable(log) == 0,
    "navgraph rechecks its feature gate immediately before execution"
  )
  config.options.tools.navgraph.enabled = true

  local output, is_error, first_handle, first_done, execution_meta = run({ command = "files" })
  local argv = vim.fn.readfile(log)
  local real_repo = uv.fs_realpath(repo) or vim.fs.normalize(repo)
  check(output and output:find("query ok", 1, true) and is_error == false, "navgraph executes a successful query")
  check(
    execution_meta
      and execution_meta.phase == "execution"
      and execution_meta.spawned == true
      and execution_meta.outcome == "success"
      and execution_meta.navgraph_build_id == "navgraph@test-current"
      and execution_meta.adapter_transport == "cli"
      and execution_meta.typed_query_available == true,
    "navgraph reports execution and negotiated-contract metadata without claiming typed transport adoption"
  )
  check(
    vim.deep_equal(argv, { "files", "--limit", "80", "-C", real_repo, "--no-cache" }),
    "navgraph pins the cwd/root and injects a deterministic compact result bound"
  )

  output, is_error = run({
    command = "strings",
    target = "$(touch " .. injected_file .. ")",
    destination = "",
  })
  argv = vim.fn.readfile(log)
  check(
    is_error == false and vim.fn.filereadable(injected_file) == 0 and argv[2] == "$(touch " .. injected_file .. ")",
    "navgraph omits model-materialized empty optional fields and passes literal argv without shell expansion"
  )

  output, is_error = run({ command = "strings", target = "--no-tests" })
  argv = vim.fn.readfile(log)
  check(is_error == false and vim.deep_equal(argv, {
    "strings",
    "--limit",
    "40",
    "-C",
    real_repo,
    "--no-cache",
    "--",
    "--no-tests",
  }), "navgraph passes flag-shaped string data after the negotiated positional terminator")

  output, is_error = run({ command = "outline", target = "src/a.lua", limit = 7, kind = "fn,struct" })
  argv = vim.fn.readfile(log)
  check(is_error == false and vim.deep_equal(argv, {
    "outline",
    "src/a.lua",
    "--kind",
    "fn,struct",
    "--limit",
    "7",
    "--verbosity",
    "names",
    "-C",
    real_repo,
    "--no-cache",
  }), "navgraph typed options build one compact deterministic argv")

  for _, command in ipairs({ "diff", "rename", "serve", "mcp", "help" }) do
    local rejected, rejected_err = run({ command = command })
    check(
      rejected_err == true and rejected and rejected:find("read%-only allowlist"),
      "navgraph rejects non-read-only/unbounded command " .. command
    )
  end
  rejected, rejected_err = run({ command = "files", flags = { "--root=/tmp" } })
  check(
    rejected_err == true and rejected and rejected:find("no longer accepts raw", 1, true),
    "navgraph rejects arbitrary argv in favor of typed command options"
  )
  output, is_error = run({ command = "calls", target = "Thing", depth = 2, refs = true, strict = true })
  argv = vim.fn.readfile(log)
  check(is_error == false and vim.deep_equal(argv, {
    "calls",
    "Thing",
    "--depth",
    "2",
    "--refs",
    "--strict",
    "--limit",
    "40",
    "--verbosity",
    "names",
    "-C",
    real_repo,
    "--no-cache",
  }), "navgraph maps typed graph options without ambiguous or command-inapplicable flags")
  output, is_error = run({ command = "path", target = "Start", destination = "Finish", strict = true, limit = 40 })
  argv = vim.fn.readfile(log)
  check(is_error == false and vim.deep_equal(argv, {
    "path",
    "Start",
    "Finish",
    "--strict",
    "--verbosity",
    "names",
    "-C",
    real_repo,
    "--no-cache",
  }), "navgraph maps the typed two-symbol path query and omits unsupported materialized options")
  output, is_error = run({
    command = "files",
    target = "",
    destination = "",
    limit = 80,
    depth = 2,
    kind = "",
    refs = false,
    strict = true,
    sort = "symbols",
    exclude_public = false,
    follow_imports = false,
  })
  argv = vim.fn.readfile(log)
  check(
    is_error == false
      and vim.deep_equal(argv, { "files", "--sort", "symbols", "--limit", "80", "-C", real_repo, "--no-cache" }),
    "navgraph normalizes model-materialized inapplicable defaults while preserving applicable file ordering"
  )
  output, is_error = run({ command = "unused", target = "src", exclude_public = true, follow_imports = true })
  argv = vim.fn.readfile(log)
  check(is_error == false and vim.deep_equal(argv, {
    "unused",
    "src",
    "--no-public",
    "--follow-imports",
    "--limit",
    "40",
    "--verbosity",
    "names",
    "-C",
    real_repo,
    "--no-cache",
  }), "navgraph maps cross-version typed unused-query options exactly")
  rejected, rejected_err = run({ command = "files", limit = 81 })
  check(
    rejected_err == true and rejected:find("configured maximum 80", 1, true),
    "navgraph rejects a requested limit above the live cap instead of silently clamping"
  )
  local validation_handle, validation_done, validation_meta
  rejected, rejected_err, validation_handle, validation_done, validation_meta = run({ command = "search" })
  check(
    rejected_err == true
      and rejected
      and rejected:find("target is required", 1, true)
      and validation_meta.phase == "validation"
      and validation_meta.spawned == false,
    "navgraph validates command-specific target requirements before spawning"
  )
  rejected, rejected_err = run({ command = "search", target = "natural language symbol search" })
  check(
    rejected_err == true and rejected:find("not prose", 1, true),
    "navgraph rejects prose passed to lexical symbol search with a concise correction"
  )
  rejected, rejected_err = run({ command = "imports" })
  check(
    rejected_err == true and rejected:find("target is required", 1, true),
    "navgraph requires a filter for otherwise unbounded import output"
  )
  rejected, rejected_err = run({ command = "search", args = { "legacy" } })
  check(
    rejected_err == true and rejected and rejected:find("no longer accepts raw", 1, true),
    "navgraph gives stale raw-argv calls one concise migration correction"
  )

  output, is_error = run({ command = "read", target = "src/a.lua:1-1" })
  argv = vim.fn.readfile(log)
  check(
    is_error == false
      and output
      and output:find("query ok", 1, true)
      and vim.deep_equal(argv, { "read", "src/a.lua:1-1", "--limit", "80", "-C", real_repo }),
    "navgraph read accepts a contained range without emitting its unsupported cache flag"
  )
  output, is_error = run({ command = "read", target = "src/a.lua:1-10,50-60", limit = 21 })
  check(
    is_error == false and output and output:find("query ok", 1, true),
    "navgraph read accepts disjoint closed ranges at the exact unique-line budget"
  )
  output, is_error = run({ command = "read", target = "src/a.lua:1-10,5-15", limit = 15 })
  check(
    is_error == false and output and output:find("query ok", 1, true),
    "navgraph read merges overlapping ranges before enforcing its line budget"
  )
  local range_meta
  output, is_error, _, _, range_meta = run({ command = "read", target = "src/a.lua:1-10,5-15", limit = 14 })
  argv = vim.fn.readfile(log)
  check(
    is_error == false
      and output:find("first 14 of 15 requested unique lines", 1, true)
      and output:find("src/a.lua:1%-14")
      and range_meta.phase == "execution"
      and range_meta.spawned == true
      and range_meta.outcome == "partial_success"
      and range_meta.read_range_truncated == true
      and range_meta.read_requested_unique_lines == 15
      and range_meta.read_returned_unique_lines == 14
      and argv[2] == "src/a.lua:1-14",
    "navgraph turns an oversized overlapping read into an explicit truth-preserving bounded prefix"
  )
  output, is_error, _, _, range_meta = run({ command = "read", target = "src/a.lua:1-81" })
  argv = vim.fn.readfile(log)
  check(
    is_error == false
      and output:find("first 80 of 81 requested unique lines", 1, true)
      and range_meta.outcome == "partial_success"
      and argv[2] == "src/a.lua:1-80",
    "navgraph read enforces its live default line cap by returning an explicit bounded prefix"
  )
  output, is_error = run({ command = "read", target = "src/a.lua:1-21", limit = 20 })
  argv = vim.fn.readfile(log)
  check(
    is_error == false and output:find("first 20 of 21 requested unique lines", 1, true) and argv[2] == "src/a.lua:1-20",
    "an explicit lower NavGraph limit bounds the returned source without discarding the whole call"
  )
  output, is_error = run({ command = "read", target = "src/a.lua:1-10,50-60", limit = 12 })
  argv = vim.fn.readfile(log)
  check(
    is_error == false
      and output:find("first 12 of 21 requested unique lines", 1, true)
      and argv[2] == "src/a.lua:1-10,50-51",
    "navgraph truncates disjoint reads deterministically across the normalized ascending ranges"
  )
  rejected, rejected_err = run({ command = "read", target = "src/a.lua" })
  check(
    rejected_err == true and rejected:find("explicit bounded range", 1, true),
    "navgraph read requires an exact range rather than returning an arbitrary file prefix"
  )
  for _, target in ipairs({
    "src/a.lua:0",
    "src/a.lua:9-4",
    "src/a.lua:4-",
    "src/a.lua:1,,2",
  }) do
    rejected, rejected_err = run({ command = "read", target = target })
    check(
      rejected_err == true and rejected:find("range", 1, true),
      "navgraph read rejects malformed or unbounded range " .. target
    )
  end
  local too_many_ranges = {}
  for i = 1, 17 do
    too_many_ranges[#too_many_ranges + 1] = tostring(i)
  end
  rejected, rejected_err = run({ command = "read", target = "src/a.lua:" .. table.concat(too_many_ranges, ",") })
  check(
    rejected_err == true and rejected:find("at most 16 ranges", 1, true),
    "navgraph read caps raw range segments for cross-version parser parity"
  )
  for _, path in ipairs({ "/etc/passwd:1-1", "../../etc/passwd:1-1" }) do
    local rejected, rejected_err = run({ command = "read", target = path })
    check(
      rejected_err == true and rejected and rejected:find("project root"),
      "navgraph read rejects external path " .. path
    )
  end
  local symlink_ok = uv.fs_symlink("/etc/passwd", repo .. "/escape")
  local rejected, rejected_err = run({ command = "read", target = "escape:1-1" })
  check(
    not symlink_ok or (rejected_err == true and rejected and rejected:find("project root")),
    "navgraph read rejects a symlink that resolves outside the project"
  )

  local no_match_handle, no_match_done, no_match_meta
  output, is_error, no_match_handle, no_match_done, no_match_meta = run({ command = "search", target = "missing" })
  check(
    is_error == false
      and output
      and output:find("no symbol matching", 1, true)
      and no_match_meta.outcome == "no_match"
      and no_match_meta.spawned == true,
    "navgraph exit 1 is a successful empty query"
  )
  output, is_error = run({ command = "search", target = "missingwarn" })
  check(
    is_error == false
      and output
      and output:find("no symbol matching missingwarn", 1, true)
      and output:find("navgraph: parse-health:", 1, true),
    "navgraph preserves benign parse-health stderr on a successful empty query"
  )
  output, is_error = run({ command = "search", target = "broken" })
  check(
    is_error == true and output and output:find("fatal: bad revision", 1, true) and output:find("exit code 1", 1, true),
    "navgraph exit 1 with operational diagnostics is a tool error"
  )
  output, is_error = run({ command = "search", target = "bad" })
  check(
    is_error == true and output and output:find("bad invocation", 1, true) and output:find("exit code 2", 1, true),
    "navgraph exit 2+ preserves diagnostics and reports a tool error"
  )
  output, is_error = run({ command = "search", target = "warn" })
  check(
    is_error == false and output and output:find("one row", 1, true) and output:find("parse warning", 1, true),
    "navgraph preserves non-fatal stderr alongside query results"
  )

  config.options.tools.navgraph.timeout_ms = 100
  output, is_error = run({ command = "search", target = "slow" })
  check(
    is_error == true and output and output:find("timed out after 100 ms", 1, true),
    "navgraph enforces its configured process timeout"
  )

  config.options.tools.navgraph.timeout_ms = 5000
  local cancelled_output, cancelled_error, handle, cancelled_done
  handle = tools.get("navgraph").run({ command = "search", target = "slow" }, { cwd = repo }, function(text, err)
    cancelled_output, cancelled_error, cancelled_done = text, err, true
  end)
  check(type(handle) == "table" and type(handle.stop) == "function", "navgraph returns a cancellable process handle")
  handle.stop()
  vim.wait(3000, function()
    return cancelled_done == true
  end, 10)
  check(
    cancelled_error == true and cancelled_output and cancelled_output:find("cancelled", 1, true),
    "navgraph cancellation kills the process and settles once"
  )

  config.options.tools.navgraph.max_output_bytes = 256
  output, is_error = run({ command = "search", target = "flood" })
  check(
    is_error == false and output and #output <= 256 and output:find("useful 256%-byte partial result"),
    "navgraph stops a runaway producer but returns useful bounded partial context"
  )
  local overflow_meta
  output, is_error, _, _, overflow_meta = run({ command = "read", target = "flood:1-100", limit = 10 })
  check(
    is_error == false
      and output
      and #output <= 256
      and output:find("^x+")
      and output:find("output capped at 256 bytes", 1, true)
      and output:find("first 10/100 requested lines", 1, true)
      and output:find("Request only the next exact range.%)$")
      and overflow_meta.outcome == "partial_success"
      and overflow_meta.output_truncated == true
      and overflow_meta.overflow_stream == "stdout",
    "a bounded read under the minimum byte cap preserves source plus one complete truthful partial note"
  )
  output, is_error, _, _, overflow_meta = run({ command = "search", target = "stderr-flood" })
  check(
    is_error == true
      and output
      and #output <= 256
      and output:find("diagnostic output exceeded", 1, true)
      and overflow_meta.outcome == "diagnostic_overflow"
      and overflow_meta.output_truncated == true
      and overflow_meta.overflow_stream == "stderr",
    "oversized stderr remains an operational error rather than useful semantic context"
  )

  rejected, rejected_err = run({ command = "calls", target = "Thing", depth = 9 })
  check(
    rejected_err == true and rejected and rejected:find("depth must be an integer from 1 to 8", 1, true),
    "navgraph enforces typed traversal bounds before spawning"
  )

  -- Capability profiles are immutable for one executable identity. Changing an
  -- external manifest file alone cannot perturb an in-flight provider schema.
  vim.fn.writefile({ vim.json.encode(capability_manifest({ agentProtocolVersion = "9.0" })) }, capability_file)
  local frozen_schema = has_schema("navgraph")
  check(
    vim.deep_equal(schema, frozen_schema) and #(vim.fn.readfile(probe_log)[1] or "") == 1,
    "NavGraph freezes the negotiated safe profile while the executable identity remains stable"
  )

  local notifications = {}
  local old_notify = vim.notify
  vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end

  -- Replacing the executable invalidates the old identity and forces exactly
  -- one fresh handshake. Malformed output is withheld from parent and scouts.
  local malformed_script = vim.deepcopy(fake_script)
  malformed_script[#malformed_script + 1] = "# malformed replacement identity"
  vim.fn.writefile(malformed_script, executable)
  vim.fn.system({ "chmod", "+x", executable })
  vim.fn.writefile({ "{not-json" }, capability_file)
  local malformed_schema = has_schema("navgraph")
  local malformed_schema_again = has_schema("navgraph")
  vim.wait(1000, function()
    return #notifications >= 1
  end, 10)
  local malformed_output, malformed_error, _, _, malformed_meta = run({ command = "files" })
  check(
    malformed_schema == nil
      and malformed_schema_again == nil
      and malformed_error == true
      and malformed_meta.outcome == "incompatible_contract"
      and malformed_output:find("malformed JSON", 1, true)
      and #notifications == 1
      and notifications[1].message:find("navgraph capabilities %-j")
      and notifications[1].message:find("agent protocol 1.0", 1, true),
    "a replaced executable with malformed capabilities fails closed with one actionable diagnostic"
  )

  -- Cache-safety metadata is security-relevant rather than advisory. A
  -- producer cannot smuggle a stringly/missing value through as a false-ish
  -- requiresIndex declaration and thereby evade the no-cache boundary.
  local malformed_cache_manifest = capability_manifest()
  malformed_cache_manifest.commands[1].requiresIndex = "false"
  local malformed_cache_script = vim.deepcopy(fake_script)
  malformed_cache_script[#malformed_cache_script + 1] = "# malformed cache-policy replacement identity"
  vim.fn.writefile(malformed_cache_script, executable)
  vim.fn.system({ "chmod", "+x", executable })
  vim.fn.writefile({ vim.json.encode(malformed_cache_manifest) }, capability_file)
  local malformed_cache_profile, malformed_cache_err = tools.get("navgraph").capability_profile()
  vim.wait(1000, function()
    return #notifications >= 2
  end, 10)
  check(
    malformed_cache_profile == nil
      and malformed_cache_err:find("malformed command descriptor", 1, true)
      and has_schema("navgraph") == nil
      and #notifications == 2,
    "malformed cache metadata fails the complete capability handshake closed"
  )

  -- A syntactically valid future/incompatible protocol also fails closed; it
  -- is never mistaken for an old binary and no model-facing schema is emitted.
  local incompatible_script = vim.deepcopy(fake_script)
  incompatible_script[#incompatible_script + 1] = "# incompatible replacement identity is longer"
  vim.fn.writefile(incompatible_script, executable)
  vim.fn.system({ "chmod", "+x", executable })
  vim.fn.writefile({ vim.json.encode(capability_manifest({ agentProtocolVersion = "2.0" })) }, capability_file)
  local incompatible_profile, incompatible_err = tools.get("navgraph").capability_profile()
  vim.wait(1000, function()
    return #notifications >= 3
  end, 10)
  check(
    incompatible_profile == nil
      and incompatible_err:find("unsupported agent protocol 2.0", 1, true)
      and has_schema("navgraph") == nil
      and #notifications == 3,
    "an incompatible NavGraph schema/protocol is rejected instead of guessed"
  )

  -- Manifest ordering is producer-owned; the policy order keeps provider
  -- schemas byte-stable after a legitimate binary upgrade.
  local reordered = capability_manifest()
  local reversed = {}
  for i = #reordered.commands, 1, -1 do
    reversed[#reversed + 1] = reordered.commands[i]
  end
  reordered.commands = reversed
  local restored_script = vim.deepcopy(fake_script)
  restored_script[#restored_script + 1] = "# compatible replacement identity with reordered manifest"
  vim.fn.writefile(restored_script, executable)
  vim.fn.system({ "chmod", "+x", executable })
  vim.fn.writefile({ vim.json.encode(reordered) }, capability_file)
  local restored_schema = has_schema("navgraph")
  check(
    restored_schema
      and vim.deep_equal(
        schema.input_schema.properties.command.enum,
        restored_schema.input_schema.properties.command.enum
      ),
    "a compatible replacement renegotiates while preserving deterministic provider command order"
  )

  -- Capability schema v1 predates the CLI's `--` positional terminator. A
  -- capability-aware older parser remains available for ordinary queries, but
  -- its leading-dash literals stay disabled rather than being guessed.
  local no_terminator_script = {
    "#!/bin/sh",
    'if [ "$1" = "capabilities" ]; then',
    '  printf x >> "$ADV_NAVGRAPH_TEST_PROBE_LOG"',
    '  if [ "$3" = "--" ]; then exit 2; fi',
    '  cat "$ADV_NAVGRAPH_TEST_CAPABILITIES"',
    "  exit 0",
    "fi",
    'printf \'%s\\n\' "$@" > "$ADV_NAVGRAPH_TEST_LOG"',
    "printf 'older negotiated query ok\\n'",
  }
  vim.fn.writefile({}, probe_log)
  vim.fn.writefile(no_terminator_script, executable)
  vim.fn.system({ "chmod", "+x", executable })
  local no_terminator_schema = has_schema("navgraph")
  local no_terminator_profile = tools.get("navgraph").capability_profile()
  local no_terminator_output, no_terminator_error, _, _, no_terminator_meta =
    run({ command = "strings", target = "--no-tests" })
  local ordinary_output, ordinary_error = run({ command = "files" })
  check(
    no_terminator_schema
      and no_terminator_profile.mode == "negotiated"
      and no_terminator_profile.literal_positionals == false
      and no_terminator_schema.input_schema.properties.target.description:find("older binary", 1, true)
      and #(vim.fn.readfile(probe_log)[1] or "") == 2
      and no_terminator_error == true
      and no_terminator_output:find("cannot represent a positional beginning", 1, true)
      and no_terminator_meta.spawned == false
      and ordinary_error == false
      and ordinary_output:find("older negotiated query ok", 1, true),
    "an older negotiated binary falls back once and only withholds unsupported flag-shaped positionals"
  )

  -- Exercise the exact-hash legacy path without committing the historical
  -- benchmark executable as a test fixture.
  local legacy_script = {
    "#!/bin/sh",
    'if [ "$1" = "capabilities" ]; then exit 2; fi',
    'printf \'%s\\n\' "$@" > "$ADV_NAVGRAPH_TEST_LOG"',
    "printf 'legacy query ok\\n'",
  }
  vim.fn.writefile(legacy_script, executable)
  vim.fn.system({ "chmod", "+x", executable })
  local legacy_stat = assert(uv.fs_stat(executable))
  local legacy_fd = assert(uv.fs_open(executable, "r", 438))
  local legacy_bytes = assert(uv.fs_read(legacy_fd, legacy_stat.size, 0))
  uv.fs_close(legacy_fd)
  local capability_state = require("advantage.navgraph_capabilities")
  capability_state._test_legacy_sha256 = vim.fn.sha256(legacy_bytes)
  capability_state._reset_cache()
  config.options.tools.navgraph.allow_legacy_benchmark = true
  local legacy_schema = has_schema("navgraph")
  local legacy_profile = tools.get("navgraph").capability_profile()
  check(
    legacy_schema
      and legacy_profile
      and legacy_profile.mode == "legacy_benchmark"
      and legacy_profile.literal_positionals == false
      and legacy_profile.cache_policy.files.inject_no_cache == true
      and vim.deep_equal(legacy_schema.input_schema.properties.command.enum, capability_state.policy_commands),
    "the frozen legacy benchmark contract remains available only through exact executable SHA-256"
  )
  local legacy_output, legacy_error = run({ command = "files" })
  argv = vim.fn.readfile(log)
  check(
    legacy_error == false
      and legacy_output:find("legacy query ok", 1, true)
      and vim.deep_equal(argv, { "files", "--limit", "80", "-C", real_repo, "--no-cache" }),
    "the exact-hash legacy profile still emits its known-supported no-cache boundary"
  )
  local legacy_log_before = vim.fn.filereadable(log) == 1 and table.concat(vim.fn.readfile(log), "\n") or ""
  local legacy_literal_output, legacy_literal_error, _, _, legacy_literal_meta =
    run({ command = "strings", target = "--no-tests" })
  check(
    legacy_literal_error == true
      and legacy_literal_output:find("cannot represent a positional beginning", 1, true)
      and legacy_literal_meta.phase == "validation"
      and legacy_literal_meta.spawned == false
      and (vim.fn.filereadable(log) == 0 or table.concat(vim.fn.readfile(log), "\n") == legacy_log_before),
    "the legacy binary rejects unsupported flag-shaped data before spawn with a lexical fallback"
  )
  config.options.tools.navgraph.allow_legacy_benchmark = false
  local disabled_legacy = has_schema("navgraph")
  vim.wait(1000, function()
    return #notifications >= 4
  end, 10)
  check(
    disabled_legacy == nil and #notifications == 4,
    "configuration can explicitly disable the exact-hash legacy compatibility profile"
  )
  capability_state._test_legacy_sha256 = nil
  capability_state._reset_cache()
  vim.notify = old_notify

  config.options.tools.navgraph = saved
  check(
    not require("advantage.agent").system_prompt(nil, repo):find("NavGraph", 1, true)
      and not require("advantage.subagent")._system_prompt(2, repo):find("NavGraph", 1, true),
    "disabled NavGraph leaves no dangling parent/scout prompt reference"
  )
  vim.env.ADV_NAVGRAPH_TEST_LOG = old_log
  vim.env.ADV_NAVGRAPH_TEST_CAPABILITIES = old_capabilities
  vim.env.ADV_NAVGRAPH_TEST_PROBE_LOG = old_probe_log
  vim.fn.delete(tmp, "rf")
end

-- 4-diag. diagnostics feedback loop ----------------------------------------------

section("diagnostics")
do
  local diagnostics = require("advantage.diagnostics")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  config.options.tools.diagnostics = vim.deepcopy(config.defaults.tools.diagnostics)
  local ns = vim.api.nvim_create_namespace("advantage.test.diag")

  -- a scratch buffer with an injected error + warning (no LSP needed)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x", "print(y)", "return z" })
  vim.diagnostic.set(ns, buf, {
    { lnum = 1, col = 6, message = "undefined global 'y'", severity = vim.diagnostic.severity.ERROR, source = "luals" },
    { lnum = 0, col = 0, message = "unused local 'x'", severity = vim.diagnostic.severity.WARN, source = "luals" },
  })

  local err_only = diagnostics.render(buf, { severity = "error", max = 10 })
  check(
    err_only and err_only:find("undefined global") and not err_only:find("unused local"),
    "render at severity=error shows only errors"
  )
  check(assert(err_only):find("L2:7", 1, true) ~= nil, "render reports 1-based line:col with [source]")

  local with_warn = assert(diagnostics.render(buf, { severity = "warn", max = 10 }))
  check(
    with_warn:find("undefined global") and with_warn:find("unused local"),
    "render at severity=warn includes warnings"
  )

  -- before/after diff: a pre-existing signature is not re-reported as new
  local before = diagnostics.signatures(buf, "error")
  vim.diagnostic.set(ns, buf, {
    { lnum = 1, col = 6, message = "undefined global 'y'", severity = vim.diagnostic.severity.ERROR },
    { lnum = 2, col = 7, message = "undefined global 'z'", severity = vim.diagnostic.severity.ERROR },
  })
  local new_only = diagnostics.render(buf, { severity = "error", before = before })
  check(
    new_only and new_only:find("'z'", 1, true) and not new_only:find("'y'", 1, true),
    "render with before= surfaces only newly-introduced diagnostics"
  )

  -- a clean buffer (no diagnostics at/above the floor) renders nothing
  vim.diagnostic.reset(ns, buf)
  check(diagnostics.render(buf, { severity = "error" }) == nil, "a clean edit renders no diagnostic block")

  -- the cap bounds context: 30 errors, max 3 → 3 lines + a "+N more" note
  local many = {}
  for i = 1, 30 do
    many[i] = { lnum = i, col = 0, message = "err " .. i, severity = vim.diagnostic.severity.ERROR }
  end
  vim.diagnostic.set(ns, buf, many)
  local capped = assert(diagnostics.render(buf, { severity = "error", max = 3 }))
  local _, count = capped:gsub("\n", "\n")
  check(capped:find("+27 more", 1, true) ~= nil and count == 3, "render caps at max lines with a +N more note")
  vim.diagnostic.reset(ns, buf)

  -- the explicit tool is registered and gated on config
  check(tools.get("diagnostics") ~= nil, "diagnostics tool is registered")
  local has_diag = false
  for _, s in ipairs(tools.schemas()) do
    if s.name == "diagnostics" then has_diag = true end
  end
  check(has_diag, "diagnostics tool appears in the schema when enabled")
  config.options.tools.diagnostics.enabled = false
  local still = false
  for _, s in ipairs(tools.schemas()) do
    if s.name == "diagnostics" then still = true end
  end
  check(not still, "diagnostics tool is hidden when tools.diagnostics.enabled = false")
  config.options.tools.diagnostics.enabled = true

  -- auto-attach short-circuits synchronously when nothing can produce diagnostics
  -- (no open buffer, no running server for the filetype) — no per-edit overhead.
  local synced = false
  diagnostics.after_edit("/nonexistent/path/thing.unknownft", nil, function(extra)
    synced = (extra == nil)
  end)
  check(synced, "after_edit returns synchronously (nil) when no diagnostic provider exists")

  vim.api.nvim_buf_delete(buf, { force = true })

  -- ensure_bufnr robustness: bufload reads the file in before firing
  -- BufReadPost/FileType autocmds, so an unrelated autocmd throwing (an LSP
  -- client racing to attach while a sibling buffer of the same filetype is
  -- mid-startup, observed loading several fresh Zig buffers back to back)
  -- must not make M.report falsely claim the file couldn't be opened.
  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "return 1" }, tmp)
  local real_bufload = vim.fn.bufload
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.bufload = function(...)
    real_bufload(...) -- content is read into the buffer first, exactly like real bufload
    error("simulated autocmd failure during load")
  end
  local report_result = nil
  diagnostics.report(tmp, "warn", function(text)
    report_result = text
  end)
  vim.wait(2000, function()
    return report_result ~= nil
  end)
  vim.fn.bufload = real_bufload
  check(
    report_result ~= nil and not report_result:find("Could not open", 1, true),
    "report tolerates bufload throwing once the buffer's text is already loaded"
  )
  pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(tmp), { force = true })
  vim.fn.delete(tmp)
end

-- 4-search. web_search tool ---------------------------------------------------

section("web_search")
do
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  config.options.tools.web_search = vim.deepcopy(config.defaults.tools.web_search)
  local wcfg = config.options.tools.web_search
  local old_env = vim.env.BRAVE_API_KEY
  vim.env.BRAVE_API_KEY = nil

  local function has_web_tool(name)
    for _, s in ipairs(tools.schemas()) do
      if s.name == name then return true end
    end
    return false
  end

  check(has_web_tool("web_search"), "web_search keeps a keyless public fallback when no API key is configured")
  check(has_web_tool("web_fetch"), "web_fetch is available independently of a search API key")
  wcfg.api_key = "test-key"
  check(has_web_tool("web_search"), "web_search remains available once an API key is configured")

  local function fake_curl(dir, script_lines)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(script_lines, dir .. "/curl")
    vim.fn.system({ "chmod", "+x", dir .. "/curl" })
  end

  local function run_with_path(dir, fn)
    local old_path = vim.env.PATH
    vim.env.PATH = dir .. ":" .. old_path
    local out, is_err, done = nil, nil, false
    fn(function(o, e)
      out, is_err, done = o, e, true
    end)
    vim.wait(2000, function()
      return done
    end)
    vim.env.PATH = old_path
    return out, is_err
  end

  local ctx = { cwd = vim.fn.getcwd() }
  local run = tools.get("web_search").run

  -- empty query short-circuits before any curl invocation
  local out0, err0 = run_with_path(vim.fn.tempname(), function(cb)
    run({ query = "" }, ctx, cb)
  end)
  check(
    err0 == true and assert(out0):find("Empty query", 1, true) ~= nil,
    "empty query is rejected without shelling out"
  )

  -- happy path: canned Brave-style JSON, HTML/entities stripped, capped at count
  local dir1 = vim.fn.tempname()
  local body = vim.json.encode({
    web = {
      results = {
        {
          title = "Neovim <strong>0.11</strong> released",
          url = "https://neovim.io/a",
          description = "Big &amp; small changes.",
        },
        { title = "Second result", url = "https://example.com/b", description = "Another snippet." },
        { title = "Third result", url = "https://example.com/c", description = "Should be cut off by count." },
      },
    },
  })
  fake_curl(dir1, {
    "#!/usr/bin/env bash",
    "case \"$*\" in *test-key*) echo 'secret leaked in argv' >&2; exit 97;; esac",
    "cat <<'JSON'",
    body,
    "JSON",
    "exit 0",
  })
  local out1, err1 = run_with_path(dir1, function(cb)
    run({ query = "neovim release notes", count = 2 }, ctx, cb)
  end)
  check(err1 == nil or err1 == false, "happy-path web_search reports success")
  local out1s = assert(out1)
  check(out1s:find("Neovim 0.11 released", 1, true) ~= nil, "HTML tags stripped from the title")
  check(out1s:find("Big & small changes", 1, true) ~= nil, "HTML entities decoded in the description")
  check(out1s:find("https://neovim.io/a", 1, true) ~= nil, "result URL is included")
  check(out1s:find("Third result", 1, true) == nil, "results capped at the requested count")
  check(not out1s:find("test-key", 1, true), "Brave API secret never appears in tool output or curl argv")

  -- curl failure surfaces as a tool error
  local dir2 = vim.fn.tempname()
  fake_curl(dir2, { "#!/usr/bin/env bash", "echo 'curl: (6) Could not resolve host' >&2", "exit 6" })
  local out2, err2 = run_with_path(dir2, function(cb)
    run({ query = "anything" }, ctx, cb)
  end)
  check(
    err2 == true and assert(out2):find("Could not resolve host", 1, true) ~= nil,
    "curl failure is reported as an error"
  )

  -- malformed JSON is reported rather than crashing
  local dir3 = vim.fn.tempname()
  fake_curl(dir3, { "#!/usr/bin/env bash", "echo 'not json'", "exit 0" })
  local out3, err3 = run_with_path(dir3, function(cb)
    run({ query = "anything" }, ctx, cb)
  end)
  check(
    err3 == true and assert(out3):find("could not parse", 1, true) ~= nil,
    "unparseable response is reported, not crashed"
  )

  -- read-only sub-agents automatically inherit it once enabled (it's `safe`)
  local subagent = require("advantage.subagent")
  local sub_tools = subagent._readonly_tools and subagent._readonly_tools() or nil
  if sub_tools then
    local sub_has, sub_fetch = false, false
    for _, s in ipairs(sub_tools) do
      if s.name == "web_search" then sub_has = true end
      if s.name == "web_fetch" then sub_fetch = true end
    end
    check(sub_has, "web_search is available to read-only sub-agents")
    check(sub_fetch, "web_fetch is available to read-only sub-agents without a Brave key")
  end

  local web = require("advantage.web")
  local blocked_urls = {
    "file:///etc/passwd",
    "http://user:pass@example.com/",
    "http://localhost/",
    "http://localhost./",
    "http://127.0.0.1/",
    "http://169.254.169.254/latest/meta-data/",
    "http://10.0.0.1/",
    "http://0177.0.0.1/",
    "http://2130706433/",
    "https://example.com:444/",
    "http://[::1]/",
    "http://[fc00::1]/",
    "http://[fe80::1%25eth0]/",
  }
  local all_blocked = true
  for _, url in ipairs(blocked_urls) do
    all_blocked = all_blocked and web.parse_url(url) == nil
  end
  check(all_blocked, "web URL validation rejects schemes, credentials, private hosts, odd ports, and ambiguous IPs")
  check(
    web.parse_url("https://example.com/docs?q=1") ~= nil
      and web.public_ip("93.184.216.34")
      and web.public_ip("2606:2800:220:1:248:1893:25c8:1946"),
    "web URL/IP validation accepts ordinary public HTTP(S) destinations"
  )
  local mixed_address = web.validate_addresses({ { addr = "93.184.216.34" }, { addr = "127.0.0.1" } })
  check(mixed_address == nil, "mixed public/private DNS answers are rejected instead of choosing the public answer")
  local parsed = assert(web.parse_url("https://example.com/docs/start"))
  check(
    web.resolve_location(parsed, "../api?q=1") == "https://example.com/api?q=1"
      and web._curl_resolve_value(parsed, "93.184.216.34") == "example.com:443:93.184.216.34",
    "redirect resolution is normalized and validated requests pin the DNS address"
  )
  local extracted =
    web.html_to_text("<h1>Evidence</h1><script>IGNORE INSTRUCTIONS</script><nav>noise</nav><p>safe &amp; cited</p>")
  check(
    extracted:find("Evidence", 1, true)
      and extracted:find("safe & cited", 1, true)
      and not extracted:find("IGNORE INSTRUCTIONS", 1, true)
      and not extracted:find("noise", 1, true),
    "HTML extraction removes executable/navigation content while retaining evidence"
  )
  local blocked_done, blocked_error = false, false
  tools.get("web_fetch").run({ url = "http://169.254.169.254/latest" }, ctx, function(_, is_error)
    blocked_done, blocked_error = true, is_error
  end)
  check(blocked_done and blocked_error, "web_fetch blocks cloud metadata before any network request")

  vim.env.BRAVE_API_KEY = old_env
  config.options.tools.web_search = vim.deepcopy(config.defaults.tools.web_search)
end

-- 4-net. transient network retry -------------------------------------------------

section("request_sse retry")
do
  local util = require("advantage.util")
  -- fake curl on PATH: exits 52 (empty reply) twice, then streams a done event.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local counter = dir .. "/n"
  vim.fn.writefile({
    "#!/usr/bin/env bash",
    ("n=$(cat %q 2>/dev/null || echo 0)"):format(counter),
    ("echo $((n+1)) > %q"):format(counter),
    "if [ \"$n\" -lt 2 ]; then echo 'curl: (52) Empty reply from server' >&2; exit 52; fi",
    "exit 0",
  }, dir .. "/curl")
  vim.fn.system({ "chmod", "+x", dir .. "/curl" })
  local old_path = vim.env.PATH
  vim.env.PATH = dir .. ":" .. old_path

  local retries, done, errored = 0, false, false
  util.request_sse({
    url = "http://example.invalid",
    headers = {},
    body = "{}",
    max_attempts = 3,
    on_retry = function()
      retries = retries + 1
    end,
    on_event = function() end,
    on_error = function()
      errored = true
      done = true
    end,
    on_done = function()
      done = true
    end,
  })
  vim.wait(5000, function()
    return done
  end, 10)
  vim.env.PATH = old_path
  check(retries == 2 and not errored, "transient curl failures retried until success")
end

-- 4-net2. transient OpenAI SSE overload retry ----------------------------------

section("openai transient SSE overload retry")
do
  local auth = require("advantage.auth")
  local openai = require("advantage.providers.openai")
  local util = require("advantage.util")
  local original_auth = auth.openai
  local original_request_sse = util.request_sse
  local original_defer_fn = vim.defer_fn
  local original_notify = vim.notify
  local active_auth_error
  local delayed, notices = {}, {}

  ---@diagnostic disable-next-line: duplicate-set-field
  auth.openai = function(cb)
    if active_auth_error then return cb(nil, active_auth_error) end
    cb({ mode = "chatgpt", token = "test-token", account_id = "test-account", badge = "chatgpt" })
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.defer_fn = function(fn, ms)
    delayed[#delayed + 1] = ms
    -- Preserve the async boundary while making provider backoff deterministic
    -- and fast in the smoke suite.
    vim.schedule(fn)
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    notices[#notices + 1] = { message = tostring(msg), level = level }
  end

  local function emit(opts, events)
    for _, event in ipairs(events) do
      opts.on_event(event[1], event[2])
    end
    opts.on_done()
  end

  local function run_case(name, script, auth_error)
    local attempts, bodies = 0, {}
    local delayed_from, notices_from = #delayed + 1, #notices + 1
    local observed = {
      complete = {},
      errors = {},
      text = {},
      thinking = {},
      tools = {},
    }
    active_auth_error = auth_error
    ---@diagnostic disable-next-line: duplicate-set-field
    util.request_sse = function(opts)
      attempts = attempts + 1
      local attempt_no = attempts
      bodies[#bodies + 1] = vim.json.decode(opts.body)
      vim.schedule(function()
        script(attempt_no, opts)
      end)
      return { stop = function() end }
    end

    local ok, handle = pcall(openai.stream, {
      model = {
        provider = "openai",
        id = "gpt-5.6-sol",
        label = "sol",
        reasoning_effort = "medium",
        reasoning_efforts = { "low", "medium", "high", "xhigh", "max" },
      },
      messages = { { role = "user", content = { { type = "text", text = "retry " .. name } } } },
      system = "OpenAI overload retry regression: " .. name,
      tools = {},
      session_id = "overload-retry-" .. name,
      on = {
        auth = function() end,
        text = function(text)
          observed.text[#observed.text + 1] = text
        end,
        thinking = function(text)
          observed.thinking[#observed.thinking + 1] = text
        end,
        tool_start = function(id, tool_name)
          observed.tools[#observed.tools + 1] = { id = id, name = tool_name }
        end,
        usage = function() end,
        complete = function(blocks, stop)
          observed.complete[#observed.complete + 1] = { blocks = blocks, stop = stop }
        end,
        error = function(msg, meta)
          observed.errors[#observed.errors + 1] = { message = tostring(msg), meta = meta }
        end,
      },
    })
    if not ok then observed.errors[#observed.errors + 1] = { message = tostring(handle) } end
    vim.wait(3000, function()
      return #observed.complete + #observed.errors > 0
    end, 5)
    -- Drain callbacks deliberately scheduled by a broken implementation after
    -- its first terminal callback; those must be visible as duplicates here.
    vim.wait(30, function()
      return false
    end, 5)
    if ok and handle and handle.stop then handle.stop() end

    observed.attempts = attempts
    observed.bodies = bodies
    observed.delays = {}
    observed.notices = {}
    for i = delayed_from, #delayed do
      observed.delays[#observed.delays + 1] = delayed[i]
    end
    for i = notices_from, #notices do
      observed.notices[#observed.notices + 1] = notices[i]
    end
    return observed
  end

  local overloaded = "Our servers are currently overloaded. Please try again shortly."
  local provider_advised = "An error occurred while processing your request. You can retry your request, "
    .. "or contact us through our help center at help.openai.com if the error persists."
  local recovered = run_case("recovers", function(attempt, opts)
    if attempt == 1 then return emit(opts, { { "error", { type = "error", error = { message = overloaded } } } }) end
    if attempt == 2 then
      return emit(opts, {
        {
          "response.failed",
          { type = "response.failed", response = { error = { message = overloaded } } },
        },
      })
    end
    emit(opts, {
      { "response.output_text.delta", { type = "response.output_text.delta", delta = "recovered" } },
      {
        "response.output_item.done",
        {
          type = "response.output_item.done",
          item = {
            type = "message",
            id = "overload-recovered",
            status = "completed",
            content = { { type = "output_text", text = "recovered" } },
          },
        },
      },
      {
        "response.completed",
        { type = "response.completed", response = { usage = { input_tokens = 12, output_tokens = 3 } } },
      },
    })
  end)
  local same_request = #recovered.bodies == 3
  for i = 2, #recovered.bodies do
    same_request = same_request and vim.deep_equal(recovered.bodies[1], recovered.bodies[i])
  end
  local bounded_backoff = #recovered.delays == 2
  for _, ms in ipairs(recovered.delays) do
    bounded_backoff = bounded_backoff and type(ms) == "number" and ms > 0 and ms <= 10000
  end
  local retry_notice = false
  for _, notice in ipairs(recovered.notices) do
    local message = notice.message:lower()
    if message:find("overload", 1, true) and message:find("retry", 1, true) then retry_notice = true end
  end
  check(
    recovered.attempts == 3 and same_request,
    "pre-payload SSE error/response.failed overloads retry the identical model request"
  )
  check(bounded_backoff, "SSE overload retries use positive bounded backoff")
  check(retry_notice, "SSE overload recovery emits a visible retry notification")
  check(
    #recovered.complete == 1
      and #recovered.errors == 0
      and table.concat(recovered.text) == "recovered"
      and recovered.complete[1].blocks[1].text == "recovered",
    "success after overload retry streams and completes exactly once"
  )

  local provider_advised_recovered = run_case("provider-advised-recovers", function(attempt, opts)
    if attempt == 1 then
      return emit(opts, {
        {
          "response.failed",
          { type = "response.failed", response = { error = { message = provider_advised } } },
        },
      })
    end
    emit(opts, {
      { "response.output_text.delta", { type = "response.output_text.delta", delta = "provider retry recovered" } },
      {
        "response.completed",
        { type = "response.completed", response = { usage = { input_tokens = 9, output_tokens = 3 } } },
      },
    })
  end)
  check(
    provider_advised_recovered.attempts == 2
      and #provider_advised_recovered.delays == 1
      and #provider_advised_recovered.complete == 1
      and #provider_advised_recovered.errors == 0
      and table.concat(provider_advised_recovered.text) == "provider retry recovered"
      and vim.deep_equal(provider_advised_recovered.bodies[1], provider_advised_recovered.bodies[2]),
    "OpenAI's exact pre-payload provider-advised response.failed class retries the identical request once"
  )

  -- curl can report code 18 after the server has sent lifecycle SSE events but
  -- before it has emitted any user-visible/model-action payload. Provider-level
  -- retry safety must follow payload commitment, not util.request_sse's broader
  -- "any event dispatched" transport guard.
  local curl18 = "curl: (18) transfer closed with outstanding read data remaining"
  local curl18_recovered = run_case("curl18-recovers", function(attempt, opts)
    if attempt == 1 then
      opts.on_event("response.created", { type = "response.created", response = { id = "first-attempt" } })
      return opts.on_error(curl18, 200)
    end
    emit(opts, {
      { "response.output_text.delta", { type = "response.output_text.delta", delta = "after curl 18" } },
      {
        "response.output_item.done",
        {
          type = "response.output_item.done",
          item = {
            type = "message",
            id = "curl18-recovered",
            status = "completed",
            content = { { type = "output_text", text = "after curl 18" } },
          },
        },
      },
      {
        "response.completed",
        { type = "response.completed", response = { usage = { input_tokens = 8, output_tokens = 4 } } },
      },
    })
  end)
  check(
    curl18_recovered.attempts == 2
      and #curl18_recovered.delays == 1
      and #curl18_recovered.complete == 1
      and #curl18_recovered.errors == 0
      and table.concat(curl18_recovered.text) == "after curl 18"
      and vim.deep_equal(curl18_recovered.bodies[1], curl18_recovered.bodies[2]),
    "curl 18 after lifecycle-only SSE events retries the identical request and completes once"
  )

  local curl18_after_text = run_case("curl18-after-text", function(_, opts)
    opts.on_event("response.output_text.delta", { type = "response.output_text.delta", delta = "committed" })
    opts.on_error(curl18, 200)
  end)
  check(
    curl18_after_text.attempts == 1
      and #curl18_after_text.delays == 0
      and #curl18_after_text.complete == 0
      and #curl18_after_text.errors == 1
      and table.concat(curl18_after_text.text) == "committed",
    "curl 18 after visible text never retries or duplicates committed output"
  )

  local payload_cases = {
    text = { "response.output_text.delta", { type = "response.output_text.delta", delta = "partial" } },
    thinking = {
      "response.reasoning_summary_text.delta",
      { type = "response.reasoning_summary_text.delta", delta = "considering" },
    },
    tool = {
      "response.output_item.added",
      {
        type = "response.output_item.added",
        item = { type = "function_call", id = "tool-item", call_id = "tool-call", name = "read_file" },
      },
    },
  }
  local all_payloads_guarded = true
  for kind, payload in pairs(payload_cases) do
    local committed = run_case("committed-" .. kind, function(_, opts)
      emit(opts, {
        payload,
        {
          "response.failed",
          { type = "response.failed", response = { error = { message = provider_advised } } },
        },
      })
    end)
    local delivered = kind == "text" and table.concat(committed.text) == "partial"
      or kind == "thinking" and table.concat(committed.thinking) == "considering"
      or kind == "tool" and #committed.tools == 1 and committed.tools[1].name == "read_file"
    all_payloads_guarded = all_payloads_guarded
      and delivered
      and committed.attempts == 1
      and #committed.delays == 0
      and #committed.complete == 0
      and #committed.errors == 1
  end
  check(
    all_payloads_guarded,
    "a provider-advised retry after text, thinking, or tool payload never retries or duplicates streamed work"
  )

  local bad_request = run_case("bad-request", function(_, opts)
    opts.on_error("HTTP 400: invalid JSON request", 400)
  end)
  local missing_model = run_case("missing-model", function(_, opts)
    opts.on_error("HTTP 404: Model not found gpt-5.6-sol", 404)
  end)
  local vague_retry_advice = run_case("vague-retry-advice", function(_, opts)
    emit(opts, {
      {
        "response.failed",
        {
          type = "response.failed",
          response = { error = { message = "You can retry your request after correcting the invalid input." } },
        },
      },
    })
  end)
  local missing_auth = run_case("missing-auth", function()
    error("request_sse must not start after auth rejection")
  end, "No OpenAI credentials in deterministic test")
  check(
    bad_request.attempts == 1
      and #bad_request.errors == 1
      and #bad_request.delays == 0
      and missing_model.attempts == 1
      and #missing_model.errors == 1
      and #missing_model.delays == 0
      and vague_retry_advice.attempts == 1
      and #vague_retry_advice.errors == 1
      and #vague_retry_advice.delays == 0
      and missing_auth.attempts == 0
      and #missing_auth.errors == 1
      and #missing_auth.delays == 0,
    "auth, model, deterministic HTTP 400, and incomplete retry wording remain non-retryable"
  )

  local exhausted = run_case("exhausted", function(_, opts)
    emit(opts, {
      {
        "response.failed",
        { type = "response.failed", response = { error = { message = overloaded } } },
      },
    })
  end)
  local exhaustion_delays_bounded = #exhausted.delays == exhausted.attempts - 1
  for _, ms in ipairs(exhausted.delays) do
    exhaustion_delays_bounded = exhaustion_delays_bounded and ms > 0 and ms <= 10000
  end
  check(
    exhausted.attempts >= 2
      and exhausted.attempts <= 4
      and exhaustion_delays_bounded
      and #exhausted.complete == 0
      and #exhausted.errors == 1
      and exhausted.errors[1].message:lower():find("overload", 1, true),
    "bounded overload exhaustion surfaces one final error exactly once"
  )

  -- Cancellation during backoff must revoke the delayed continuation. The
  -- timer itself may still fire (vim.defer_fn has no stop handle), but it must
  -- neither relaunch nor retain the request-heavy closure through that delay.
  do
    local held
    local attempts, stopped, errors = 0, 0, 0
    vim.defer_fn = function(fn)
      held = fn
    end
    util.request_sse = function(opts)
      attempts = attempts + 1
      vim.schedule(function()
        opts.on_error("HTTP 503: overloaded", 503)
      end)
      return {
        stop = function()
          stopped = stopped + 1
        end,
      }
    end
    local handle = openai.stream({
      model = {
        provider = "openai",
        id = "gpt-5.6-sol",
        label = "sol",
        reasoning_effort = "medium",
        reasoning_efforts = { "low", "medium", "high" },
      },
      messages = { { role = "user", content = { { type = "text", text = "cancel while backing off" } } } },
      system = "retry cancellation",
      tools = {},
      on = {
        auth = function() end,
        text = function() end,
        thinking = function() end,
        tool_start = function() end,
        usage = function() end,
        complete = function() end,
        error = function()
          errors = errors + 1
        end,
      },
    })
    vim.wait(1000, function()
      return held ~= nil
    end, 5)
    handle.stop()
    if held then held() end
    vim.wait(20, function()
      return false
    end, 5)
    check(
      attempts == 1 and stopped == 1 and errors == 0,
      "cancelling OpenAI backoff revokes the delayed request continuation"
    )
  end

  auth.openai = original_auth
  util.request_sse = original_request_sse
  vim.defer_fn = original_defer_fn
  vim.notify = original_notify
end

-- 4a. context compaction ---------------------------------------------------------

section("context compaction")
do
  local compact = require("advantage.compact")
  local messages = {}
  for i = 1, 24 do
    messages[#messages + 1] = {
      role = i % 2 == 0 and "assistant" or "user",
      content = { { type = "text", text = ("message %02d "):format(i) .. string.rep("x", 120) } },
    }
  end
  local out, info =
    compact.compact(messages, { compact_at_tokens = 100, keep_recent_messages = 6, summary_max_chars = 2000 })
  -- 24 msgs, keep 6 -> older = 18; the first user turn is pinned (kept verbatim,
  -- not summarized) so 17 messages are compacted.
  check(info and info.compacted_messages == 17, "compacts old messages when threshold is crossed")
  -- The original task (message 01) is pinned verbatim at the head, then the summary.
  check(out[1].pinned == true and out[1].content[1].text:find("message 01", 1, true), "original task pinned verbatim")
  check(out[2].content[1].text:find(compact._SUMMARY_PREFIX, 1, true), "summary prepended after the pinned task")
  check(out[#out].content[1].text:find("message 24", 1, true), "recent messages kept verbatim")
  -- The canonical array may open with two user turns (pin, then summary); the
  -- Anthropic body must still strictly alternate after same-role coalescing.
  local sanitized = require("advantage.providers.anthropic")._sanitize_messages(out)
  local prev_role
  local alternates = true
  for _, m in ipairs(sanitized) do
    if m.role == prev_role then alternates = false end
    prev_role = m.role
  end
  check(alternates, "compacted messages alternate roles after anthropic sanitize (pin+summary coalesce)")

  local ok_empty = pcall(function()
    compact.force(nil, { keep_recent_messages = 6 })
  end)
  check(ok_empty, "manual compact tolerates an empty conversation")

  local odd = {
    "legacy raw message",
    { role = "user", content = "legacy string content" },
  }
  for i = 1, 8 do
    odd[#odd + 1] =
      { role = i % 2 == 0 and "assistant" or "user", content = { { type = "text", text = "recent " .. i } } }
  end
  local paired = {
    { role = "user", content = { { type = "text", text = "please inspect" } } },
    {
      role = "assistant",
      content = { { type = "tool_use", id = "call_keep", name = "read_file", input = { path = "a" } } },
    },
    {
      role = "user",
      content = { { type = "tool_result", tool_use_id = "call_keep", content = string.rep("result ", 100) } },
    },
    {
      role = "assistant",
      content = {
        { type = "openai_reasoning", item = { type = "reasoning", encrypted_content = "stale" } },
        { type = "text", text = string.rep("final ", 100) },
      },
    },
  }
  local paired_out = select(1, compact.force(paired, { keep_recent_messages = 2, summary_max_chars = 1000 }))
  -- Locate the tool_use and its tool_result by scanning (positions shift now that
  -- the first user turn is pinned ahead of the summary).
  local use_idx, res_idx, has_reasoning = nil, nil, false
  for i, m in ipairs(paired_out) do
    for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
      if type(b) == "table" then
        if b.type == "tool_use" and b.id == "call_keep" then use_idx = i end
        if b.type == "tool_result" and b.tool_use_id == "call_keep" then res_idx = i end
        if b.type == "openai_reasoning" then has_reasoning = true end
      end
    end
  end
  check(use_idx and res_idx and use_idx < res_idx, "compact does not orphan a recent tool_result from its tool_use")
  check(not has_reasoning, "compact strips stale OpenAI reasoning from retained messages")
  check(paired_out[1].pinned == true, "the first user turn is preserved as the pinned task")

  local ok_odd, odd_out = pcall(function()
    return compact.force(odd, { keep_recent_messages = 4, summary_max_chars = 2000 })
  end)
  check(
    ok_odd and odd_out and odd_out[1].content[1].text:find("legacy raw message", 1, true),
    "compact tolerates legacy/malformed message shapes"
  )

  -- Truncating the summary must not split a multi-byte UTF-8 character, or the
  -- provider rejects the request body ("str is not valid UTF-8").
  local emoji = {}
  for i = 1, 12 do
    -- Each 4-byte emoji block exceeds the 900-byte per-line trim, forcing a cut
    -- at byte 899 which lands in the middle of a multi-byte character.
    emoji[#emoji + 1] =
      { role = i % 2 == 0 and "assistant" or "user", content = { { type = "text", text = string.rep("🎉", 300) } } }
  end
  local emoji_out = select(1, compact.force(emoji, { keep_recent_messages = 4, summary_max_chars = 20000 }))
  -- The summary message now sits after the pinned first turn; find it by prefix.
  local summary_text
  for _, m in ipairs(emoji_out) do
    for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
      if type(b) == "table" and b.type == "text" and b.text and b.text:find(compact._SUMMARY_PREFIX, 1, true) then
        summary_text = b.text
      end
    end
  end
  -- json_encode rejects invalid UTF-8 exactly like the provider request does, so
  -- a clean encode proves the summary was truncated on a character boundary.
  check(summary_text ~= nil, "summary message present after the pinned turn")
  check(pcall(vim.fn.json_encode, summary_text), "compact truncates the summary on a UTF-8 character boundary")

  -- Message count alone is not a safe proxy for context pressure: a handful of
  -- giant reads/reasoning blocks can overflow the model while still sitting well
  -- below keep_recent_messages.
  local few_huge = {}
  for i = 1, 4 do
    few_huge[i] = {
      role = i % 2 == 1 and "user" or "assistant",
      content = { { type = "text", text = ("huge-%d "):format(i) .. string.rep("x", 12000) } },
    }
  end
  local few_out, few_info = compact.compact(few_huge, {
    compact_at_tokens = 100,
    keep_recent_messages = 16,
    keep_recent_tokens = 1000,
    summary_max_chars = 1000,
  })
  check(
    few_info and few_info.compacted_messages > 0 and few_info.after_tokens < few_info.before_tokens,
    "token pressure compacts a few huge messages even below the message-count gate"
  )
  check(few_out[1].pinned == true, "few-message token-pressure compaction still pins the original task")

  local measured = compact.estimate_tokens({
    {
      role = "assistant",
      content = { { type = "thinking", thinking = "short", signature = "sig" } },
      usage = { output = 5000 },
    },
  })
  check(measured >= 5000, "token estimates never undercount provider-measured hidden reasoning output")

  local image_message = {
    role = "user",
    pinned = true,
    original_text = "inspect this screenshot",
    content = {
      { type = "image", source = { type = "base64", media_type = "image/png", data = string.rep("A", 1024 * 1024) } },
      { type = "text", text = "inspect this screenshot" },
    },
  }
  check(
    compact.estimate_tokens({ image_message }) < 10000,
    "vision estimates use a bounded image allowance instead of counting base64 as text tokens"
  )
  local image_history = { image_message }
  for i = 2, 10 do
    image_history[#image_history + 1] = {
      role = i % 2 == 0 and "assistant" or "user",
      content = { { type = "text", text = ("image follow-up %d "):format(i) .. string.rep("x", 200) } },
    }
  end
  local image_out = select(1, compact.force(image_history, { keep_recent_messages = 2, summary_max_chars = 1200 }))
  check(
    image_out[1].content[1] and image_out[1].content[1].type == "image",
    "compaction preserves a task-defining uploaded image in the pinned original turn"
  )

  local detached = select(
    1,
    compact.detach_provider_state({
      {
        role = "assistant",
        content = {
          { type = "openai_reasoning", item = { type = "reasoning", encrypted_content = string.rep("z", 1000) } },
          { type = "text", text = "visible answer" },
        },
        usage = { output = 50000 },
      },
    })
  )
  check(
    detached[1].usage == nil and compact.estimate_tokens(detached) < 1000,
    "detaching private reasoning clears its stale measured-output token floor"
  )

  local aged = {}
  for i = 1, 20 do
    aged[i] = {
      role = i % 2 == 1 and "user" or "assistant",
      content = { { type = "text", text = ("AGED-%02d "):format(i) .. string.rep("q", 700) } },
    }
  end
  local aged_out = select(1, compact.force(aged, { keep_recent_messages = 2, summary_max_chars = 1200 }))
  local aged_summary = aged_out[2].content[1].text
  check(
    aged_summary:find("AGED%-18") ~= nil and aged_summary:find("AGED%-02") == nil,
    "bounded heuristic summaries prioritize the newest aged-out work"
  )
end

-- 4a2. LLM-summarized compaction ---------------------------------------------

section("LLM-summarized compaction")
do
  local providers = require("advantage.providers")
  local agent_mod = require("advantage.agent")
  local config = require("advantage.config")
  local compact = require("advantage.compact")

  config.options.context.keep_recent_messages = 4
  config.options.context.summarizer_model = "fakesummarizer/mini"
  -- the queued-message sub-test below lets a real follow-up turn dispatch;
  -- autosave would write it into the shared session storage the later
  -- "agent e2e" section reads from, so keep it off for this whole section.
  config.options.sessions.autosave = false

  local function make_messages(n)
    local out = {}
    for i = 1, n do
      out[#out + 1] = {
        role = i % 2 == 1 and "user" or "assistant",
        content = { { type = "text", text = ("turn %d content"):format(i) } },
      }
    end
    return out
  end

  -- unit path: compact.summarize_with_llm directly
  do
    local seen_req, summarize_calls
    summarize_calls = 0
    providers.register("fakesummarizer", {
      stream = function(req)
        seen_req = req
        summarize_calls = summarize_calls + 1
        vim.defer_fn(function()
          req.on.usage(500, 80, 0)
          local summary = "Primary Request and Intent: build a widget.\nNext Step: ship it."
          if summarize_calls > 1 then summary = string.rep("oversized summary ", 4000) end
          req.on.complete({ { type = "text", text = summary } }, "end_turn")
        end, 5)
        return { stop = function() end }
      end,
    })

    local done, next_messages, info, err = false, nil, nil, nil
    compact.summarize_with_llm(make_messages(10), config.options.context, function(nm, i, e)
      next_messages, info, err = nm, i, e
      done = true
    end)
    vim.wait(2000, function()
      return done
    end, 5)
    check(done, "summarize_with_llm completed")
    check(err == nil, "summarize_with_llm reported no error")
    check(next_messages ~= nil, "summarize_with_llm produced compacted messages")
    -- turn 1 is pinned verbatim at the head; the summary follows it.
    local llm_summary_text
    for _, m in ipairs(next_messages or {}) do
      for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
        if type(b) == "table" and b.text and b.text:find(compact._SUMMARY_PREFIX, 1, true) then
          llm_summary_text = b.text
        end
      end
    end
    check(next_messages and next_messages[1].pinned == true, "original task pinned verbatim through LLM compaction")
    check(llm_summary_text ~= nil, "LLM summary still carries the shared SUMMARY_PREFIX")
    check(
      llm_summary_text and llm_summary_text:find("build a widget", 1, true) ~= nil,
      "model-written summary text is preserved"
    )
    check(
      info and info.mode == "llm" and info.model and info.model.provider == "fakesummarizer",
      "info reports llm mode and the resolved summarizer model"
    )
    check(info and info.usage and info.usage.input == 500, "info carries summarizer token usage")
    check(
      seen_req and seen_req.model.thinking == false and seen_req.model.reasoning_effort == "medium",
      "summarizer disables legacy thinking and uses the balanced medium compaction effort"
    )
    local first_seen_req = seen_req

    -- `inherit` must carry a live /effort override when the active model is also
    -- the configured summarizer, not silently fall back to provider config.
    summarize_calls = 0
    local inherit_done = false
    local inherit_opts = vim.tbl_extend("force", vim.deepcopy(config.options.context), {
      summarizer_effort = "inherit",
    })
    compact.summarize_with_llm(make_messages(10), inherit_opts, function()
      inherit_done = true
    end, {
      provider = "fakesummarizer",
      id = "mini",
      label = "mini",
      reasoning_effort = "xhigh",
    })
    vim.wait(2000, function()
      return inherit_done
    end, 5)
    check(
      seen_req and seen_req.model.reasoning_effort == "xhigh",
      "summarizer_effort=inherit preserves the active model's live effort override"
    )

    local long_messages = {}
    for i = 1, 10 do
      long_messages[#long_messages + 1] = {
        role = i % 2 == 1 and "user" or "assistant",
        content = { { type = "text", text = ("turn %d "):format(i) .. string.rep("x", 5000) } },
      }
    end
    done, next_messages, info, err = false, nil, nil, nil
    compact.summarize_with_llm(long_messages, config.options.context, function(nm, i, e)
      next_messages, info, err = nm, i, e
      done = true
    end)
    vim.wait(2000, function()
      return done
    end, 5)
    check(
      info and info.reason == "llm_summary_increased_context" and info.mode == "heuristic",
      "oversized LLM summary falls back to heuristic compaction"
    )
    check(info and info.after_tokens < info.before_tokens, "growth-guard fallback actually shrinks the transcript")
    check(next_messages and (function()
      for _, m in ipairs(next_messages) do
        for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
          if type(b) == "table" and type(b.text) == "string" and b.text:find(compact._SUMMARY_PREFIX, 1, true) then
            return not b.text:find("model summary via", 1, true)
          end
        end
      end
      return false
    end)(), "growth-guard fallback stores a plain heuristic summary")
    -- turn 1 is pinned (kept verbatim, not summarized), so the summarizer sees
    -- the raw older transcript starting at turn 2.
    check(
      first_seen_req and first_seen_req.messages[1].content[1].text:find("turn 2 content", 1, true) ~= nil,
      "raw (untruncated) transcript is sent to the summarizer"
    )
    check(
      first_seen_req and first_seen_req.messages[1].content[1].text:find("turn 1 content", 1, true) == nil,
      "the pinned task is not re-sent to the summarizer"
    )

    local semantic_reqs = {}
    providers.register("fakesemantic", {
      stream = function(req)
        semantic_reqs[#semantic_reqs + 1] = req
        vim.schedule(function()
          req.on.complete({ { type = "text", text = "Primary Request: retained semantic state." } }, "end_turn")
        end)
        return { stop = function() end }
      end,
    })
    local semantic_opts = vim.tbl_extend("force", vim.deepcopy(config.options.context), {
      summarizer_model = "fakesemantic/mini",
    })
    local semantic_messages = make_messages(10)
    semantic_messages[2].content = {
      { type = "thinking", thinking = "READABLE-THINK", signature = "OPAQUE-SIGNATURE" },
      {
        type = "openai_reasoning",
        item = {
          type = "reasoning",
          encrypted_content = "OPAQUE-CIPHER",
          summary = { { type = "summary_text", text = "READABLE-REASONING-SUMMARY" } },
        },
      },
    }
    local semantic_done = false
    compact.summarize_with_llm(semantic_messages, semantic_opts, function()
      semantic_done = true
    end)
    vim.wait(2000, function()
      return semantic_done
    end, 5)
    local semantic_text = semantic_reqs[1] and semantic_reqs[1].messages[1].content[1].text or ""
    check(
      semantic_text:find("READABLE%-THINK")
        and semantic_text:find("READABLE%-REASONING%-SUMMARY")
        and not semantic_text:find("OPAQUE%-SIGNATURE")
        and not semantic_text:find("OPAQUE%-CIPHER"),
      "LLM compaction serializes readable reasoning but never opaque signatures/ciphertext"
    )

    local tail_messages = {}
    for i = 1, 80 do
      tail_messages[i] = {
        role = i % 2 == 1 and "user" or "assistant",
        content = { { type = "text", text = ("LLM-AGED-%02d "):format(i) .. string.rep("w", 7000) } },
      }
    end
    local tail_done = false
    compact.summarize_with_llm(tail_messages, semantic_opts, function()
      tail_done = true
    end)
    vim.wait(2000, function()
      return tail_done
    end, 5)
    local tail_text = semantic_reqs[2] and semantic_reqs[2].messages[1].content[1].text or ""
    check(
      tail_text:find("LLM%-AGED%-76") and not tail_text:find("LLM%-AGED%-02"),
      "bounded LLM transcript serialization preserves the newest aged-out work"
    )
  end

  do
    providers.register("fakesummarizertruncated", {
      stream = function(req)
        vim.schedule(function()
          req.on.complete({ { type = "text", text = "Primary Request only; tail was cut" } }, "max_tokens")
        end)
        return { stop = function() end }
      end,
    })
    local truncated_opts = vim.tbl_extend("force", vim.deepcopy(config.options.context), {
      summarizer_model = "fakesummarizertruncated/mini",
    })
    local truncated_done, truncated_info = false, nil
    compact.summarize_with_llm(make_messages(10), truncated_opts, function(_, info)
      truncated_info, truncated_done = info, true
    end)
    vim.wait(2000, function()
      return truncated_done
    end, 5)
    check(
      truncated_info and truncated_info.mode == "heuristic" and truncated_info.reason == "llm_summary_truncated",
      "token-truncated LLM summaries are rejected in favor of a complete heuristic summary"
    )
  end

  -- agent-level path: Agent:compact({mode="llm"}) end-to-end. Messages sent
  -- mid-compaction queue behind the durable compaction boundary and dispatch
  -- automatically once the compacted transcript has been adopted.
  do
    local ag = agent_mod.new({ model = { provider = "fakesummarizer", id = "mini", label = "mini" } })
    ag.messages = make_messages(10)

    local cb_info
    ag:compact({ mode = "llm" }, function(info)
      cb_info = info
    end)
    check(ag.status == "compacting", "agent status reflects an in-flight LLM compaction")
    check(ag:busy() == true, "agent reports busy while compacting")

    ag:send("during compaction")
    check(#ag.queue == 1, "a message sent mid-compaction enters the normal queue")
    check(#ag.messages == 10, "a queued compaction message is not appended before the transcript replacement")

    vim.wait(2000, function()
      return ag.status == "idle" and #ag.queue == 0
    end, 5)
    local queued_seen = false
    for _, message in ipairs(ag.messages) do
      if message.original_text == "during compaction" then queued_seen = true end
    end
    check(queued_seen, "the queued message dispatches after compaction without being lost")
    check(cb_info ~= nil, "compact callback received info")
    check(#ag.messages < 10, "agent messages array was replaced with the compacted result")
    check(ag.usage.input >= 500, "summarizer usage was folded into session usage totals")
  end

  -- failure path: the summarizer errors, so compaction must still succeed via
  -- the offline heuristic — but the failure itself must not be silent.
  do
    providers.register("fakesummarizerfail", {
      stream = function(req)
        vim.defer_fn(function()
          req.on.error("boom: simulated network failure")
        end, 5)
        return { stop = function() end }
      end,
    })
    config.options.context.summarizer_model = "fakesummarizerfail/mini"

    local ui = require("advantage.ui.chat")
    local orig_notify = ui.notify
    local warned = false
    ---@diagnostic disable-next-line: duplicate-set-field
    ui.notify = function(msg, level)
      if level == vim.log.levels.WARN and tostring(msg):find("LLM compaction failed", 1, true) then warned = true end
      return orig_notify(msg, level)
    end

    local ag2 = agent_mod.new({ model = { provider = "fakesummarizerfail", id = "mini", label = "mini" } })
    ag2.messages = make_messages(10)
    local cb_info2, done2 = nil, false
    ag2:compact({ mode = "llm" }, function(info)
      cb_info2 = info
      done2 = true
    end)
    vim.wait(2000, function()
      return done2
    end, 5)
    ui.notify = orig_notify

    check(warned, "a failed LLM summarization surfaces a visible WARN notice")
    check(cb_info2 ~= nil, "compaction still succeeds via the heuristic fallback")
    check(#ag2.messages < 10, "heuristic fallback still compacted the conversation")
    local fb_summary
    for _, m in ipairs(ag2.messages) do
      for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
        if type(b) == "table" and b.text and b.text:find(compact._SUMMARY_PREFIX, 1, true) then fb_summary = b.text end
      end
    end
    check(
      fb_summary ~= nil and not fb_summary:find("model summary via", 1, true),
      "fallback summary is the plain heuristic one, not framed as an LLM summary"
    )
  end

  -- re-entrancy: _turn_impl calls _maybe_compact(false) on every tool-loop
  -- round trip, and the LLM path is async. A second round trip firing before
  -- the first summarizer call's callback lands must not spawn a concurrent
  -- second compaction over the same still-unchanged messages.
  do
    local summarize_calls = 0
    providers.register("fakesummarizerslow", {
      stream = function(req)
        vim.defer_fn(function()
          summarize_calls = summarize_calls + 1
          req.on.usage(10, 5, 0)
          req.on.complete({ { type = "text", text = compact._SUMMARY_PREFIX .. "\nslow summary" } }, "end_turn")
        end, 30)
        return { stop = function() end }
      end,
    })
    config.options.context.summarizer_model = "fakesummarizerslow/mini"
    config.options.context.auto_compact_mode = "llm"
    config.options.context.compact_at_tokens = 1

    local ag3 = agent_mod.new({ model = { provider = "fakesummarizerslow", id = "mini", label = "mini" } })
    ag3.messages = make_messages(10)
    local infos = {}
    ag3:_maybe_compact(false, {}, function(info)
      infos[#infos + 1] = info
    end)
    -- fired while the first summarizer call is still in flight
    ag3:_maybe_compact(false, {}, function(info)
      infos[#infos + 1] = info
    end)
    vim.wait(2000, function()
      return #infos >= 2
    end, 5)

    check(summarize_calls == 1, "a concurrent auto-compact call does not spawn a second summarizer job")
    check(infos[2] == nil, "the re-entrant call's callback receives nil, not a duplicate compaction")
    check(infos[1] ~= nil, "the first call's callback still completes with the compaction info")
    config.options.context.auto_compact_mode = nil
    config.options.context.compact_at_tokens = nil
  end

  -- regression: the llm auto-compact path must honor compact_at_tokens even on
  -- the very first compaction of a session, before _auto_compact_floor exists.
  -- Previously the hysteresis check only ran once a floor was set, so a fresh
  -- agent under auto_compact_mode = "llm" would fire on message count alone.
  do
    local summarize_calls = 0
    providers.register("fakesummarizerunused", {
      stream = function(req)
        summarize_calls = summarize_calls + 1
        vim.defer_fn(function()
          req.on.complete({ { type = "text", text = compact._SUMMARY_PREFIX .. "\nunused" } }, "end_turn")
        end, 5)
        return { stop = function() end }
      end,
    })
    config.options.context.summarizer_model = "fakesummarizerunused/mini"
    config.options.context.auto_compact_mode = "llm"
    config.options.context.compact_at_tokens = 120000

    local ag4 = agent_mod.new({ model = { provider = "fakesummarizerunused", id = "mini", label = "mini" } })
    ag4.messages = make_messages(10)
    local fired = false
    ag4:_maybe_compact(false, {}, function(info)
      fired = true
    end)
    check(fired == true, "a fresh agent below threshold gets an immediate (nil) callback")
    check(summarize_calls == 0, "llm auto-compact does not fire below compact_at_tokens on a fresh session")

    config.options.context.auto_compact_mode = nil
    config.options.context.compact_at_tokens = nil
  end

  -- #1/#3: the auto-compact threshold and the retained recent-window budget both
  -- scale to the active model's context_window, with compact_at_tokens as a cost
  -- ceiling so a huge window never holds an absurd amount of raw context.
  do
    local rt = compact.resolve_threshold
    local base = { compact_at_tokens = 200000, compact_fraction = 0.75 }
    check(rt(base, { context_window = 200000 }) == 150000, "threshold = compact_fraction × window under the cap")
    check(rt(base, { context_window = 1000000 }) == 200000, "threshold capped at compact_at_tokens on a huge window")
    check(rt(base, { context_window = 32000 }) == 24000, "threshold scales down for a small window")
    check(rt({ compact_at_tokens = 200000 }, {}) == 200000, "no window falls back to the cap")
    check(rt({}, {}) == 120000, "no window and no cap falls back to 120000")
    check(
      rt({ compact_at_tokens = 120000, compact_fraction = 0.75 }, { context_window = 200000 }) == 120000,
      "an explicit smaller cap wins over the window fraction"
    )
    check(
      rt(
        { compact_at_tokens = 200000, compact_fraction = 0.75, request_safety_tokens = 8000 },
        { context_window = 200000 },
        70000
      ) == 122000,
      "threshold reserves output plus the static request prefix before the provider context limit"
    )

    local krt = compact.resolve_keep_recent_tokens
    check(krt({ keep_recent_fraction = 0.4 }, 200000) == 80000, "recent budget = keep_recent_fraction × threshold")
    check(krt({ keep_recent_tokens = 5 }, 200000) == 5, "explicit keep_recent_tokens wins")
    check(krt({}, nil) == nil, "no threshold means message-count only (nil token budget)")
    check(
      config.resolve_model("anthropic/claude-opus-4-8").context_window == 1000000,
      "resolve_model carries context_window"
    )

    -- With large recent messages the token budget bounds the retained window
    -- tighter than the 16-message count (which alone would keep 14 older here).
    local huge = {}
    for i = 1, 30 do
      huge[i] = {
        role = i % 2 == 1 and "user" or "assistant",
        content = { { type = "text", text = ("m%d %s"):format(i, string.rep("x", 4000)) } },
      }
    end
    local _, hinfo =
      compact.force(huge, { keep_recent_messages = 16, keep_recent_tokens = 3000, summary_max_chars = 2000 })
    check(
      hinfo and hinfo.compacted_messages > 14,
      "recent-window token budget shrinks the kept window for large messages"
    )
  end

  -- Regression: cancelling must invalidate late callbacks and must not leave the
  -- agent unable to run a fresh manual compaction. A stopped provider is allowed
  -- to race one already-scheduled callback, so explicitly deliver one here.
  do
    local hanging_req, cancelled_callback = nil, false
    providers.register("fakesummarizerhang", {
      stream = function(req)
        hanging_req = req
        return { stop = function() end }
      end,
    })
    config.options.context.summarizer_model = "fakesummarizerhang/mini"

    local ag5 = agent_mod.new({ model = { provider = "fakesummarizerhang", id = "mini", label = "mini" } })
    ag5.messages = make_messages(10)
    ag5:compact({ mode = "llm" }, function()
      cancelled_callback = true
    end)
    check(ag5._compacting == true, "compaction is in flight before cancellation")
    ag5:cancel()
    check(ag5._compacting == false, "cancel() resets _compacting so a stuck LLM compaction doesn't wedge auto-compact")

    local fresh_info
    ag5:compact({ mode = "heuristic" }, function(info)
      fresh_info = info
    end)
    check(
      fresh_info ~= nil and ag5.status == "idle" and ag5.cancelled == false,
      "a fresh manual compaction succeeds immediately after cancellation"
    )
    local after_fresh = vim.json.encode(ag5.messages)
    hanging_req.on.complete({ { type = "text", text = "STALE SUMMARY MUST NOT LAND" } }, "end_turn")
    vim.wait(20)
    check(
      not cancelled_callback and vim.json.encode(ag5.messages) == after_fresh,
      "a late callback from the cancelled epoch cannot overwrite fresh compacted history"
    )
  end

  -- regression: _turn() must wait for an async auto-compact to finish before
  -- starting the next request, otherwise the main stream's self.job overwrites
  -- the compaction job's handle and the summarizer's wholesale self.messages
  -- replacement can race messages the turn appends in the meantime.
  do
    local main_stream_started = false
    providers.register("fakesummarizerrace", {
      stream = function(req)
        if req.system and req.system:find(compact._SUMMARY_PREFIX, 1, true) then return { stop = function() end } end
        vim.defer_fn(function()
          main_stream_started = true
        end, 5)
        return { stop = function() end }
      end,
    })
    providers.register("fakesummarizerrace_summarizer", {
      stream = function(req)
        vim.defer_fn(function()
          req.on.complete({ { type = "text", text = compact._SUMMARY_PREFIX .. "\nraced summary" } }, "end_turn")
        end, 30)
        return { stop = function() end }
      end,
    })
    config.options.context.summarizer_model = "fakesummarizerrace_summarizer/mini"
    config.options.context.auto_compact_mode = "llm"
    config.options.context.compact_at_tokens = 1

    local ag6 = agent_mod.new({ model = { provider = "fakesummarizerrace", id = "mini", label = "mini" } })
    ag6.messages = make_messages(10)
    ag6.status = "idle"
    ag6:_turn()
    check(ag6.status ~= "idle", "status stays busy while an async auto-compact is in flight")
    check(main_stream_started == false, "the main request has not started yet while compaction is in flight")
    vim.wait(2000, function()
      return main_stream_started
    end, 5)
    check(main_stream_started == true, "the main request eventually starts once compaction settles")

    config.options.context.auto_compact_mode = nil
    config.options.context.compact_at_tokens = nil
  end

  -- A synchronously rejected summarizer can invoke the fallback and start the
  -- main request before summarize_with_llm returns. Its wrapper must not replace
  -- the main request's cancellable handle afterward.
  do
    local main_handle = { kind = "main", stop = function() end }
    providers.register("fakesyncmain", {
      stream = function()
        return main_handle
      end,
    })
    providers.register("fakesyncfail", {
      stream = function(req)
        req.on.error("synchronous summary rejection")
        return { kind = "stale-summary", stop = function() end }
      end,
    })
    config.options.context.summarizer_model = "fakesyncfail/mini"
    config.options.context.auto_compact_mode = "llm"
    config.options.context.compact_at_tokens = 1
    local ag7 = agent_mod.new({ model = { provider = "fakesyncmain", id = "mini", label = "mini" } })
    ag7.messages = make_messages(10)
    ag7:_turn()
    check(ag7.job == main_handle, "synchronous summarizer failure cannot overwrite the live main-request handle")
    ag7:cancel()
    config.options.context.auto_compact_mode = nil
    config.options.context.compact_at_tokens = nil
  end

  -- Manual compaction must be durable even when the user quits immediately
  -- afterward, before another turn reaches Agent:_finish().
  do
    local session = require("advantage.session")
    local old_dir, old_autosave = session._dir_override, config.options.sessions.autosave
    session._dir_override = vim.fn.tempname()
    config.options.sessions.autosave = true
    local persisted = agent_mod.new({ model = { provider = "fakesummarizer", id = "mini", label = "mini" } })
    persisted.messages = make_messages(10)
    local compact_done = false
    persisted:compact({ mode = "heuristic" }, function(info)
      compact_done = info ~= nil
    end)
    local saved_sessions = session.list(persisted.ctx.cwd)
    check(
      compact_done and #saved_sessions > 0 and #saved_sessions[1].messages == #persisted.messages,
      "manual compaction autosaves the compacted transcript before an immediate quit"
    )
    session._dir_override, config.options.sessions.autosave = old_dir, old_autosave
  end
end

-- 4b. sub-agent tool -------------------------------------------------------------

section("sub-agent")
do
  local providers = require("advantage.providers")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local enabled = config.options.subagents.enabled
  config.options.subagents.enabled = false
  local exposed = false
  for _, schema in ipairs(tools.schemas()) do
    if schema.name == "sub_agent" then exposed = true end
  end
  config.options.subagents.enabled = enabled
  check(not exposed, "sub_agent is removed from the model schema when disabled")
  local sub_schema
  for _, schema in ipairs(tools.schemas()) do
    if schema.name == "sub_agent" then sub_schema = schema.input_schema end
  end
  check(
    sub_schema
      and vim.tbl_contains(sub_schema.required, "model")
      and vim.tbl_contains(sub_schema.required, "effort")
      and sub_schema.properties.model.minLength == 1
      and sub_schema.properties.effort.minLength == 1
      and vim.tbl_contains(sub_schema.properties.effort.enum, "medium")
      and type(sub_schema.properties.model.enum) == "table"
      and #sub_schema.properties.model.enum > 0
      and vim.tbl_contains(sub_schema.properties.model.enum, "sol")
      and vim.tbl_contains(sub_schema.properties.model.enum, "sonnet")
      and not vim.tbl_contains(sub_schema.properties.model.enum, "openai/gpt-5.1-codex-mini")
      and not vim.tbl_contains(sub_schema.properties.model.enum, ""),
    "sub-agent schema requires one-shot short model aliases and explicit effort"
  )
  local expected_aliases = { "sol", "terra", "luna", "opus", "sonnet", "haiku" }
  local all_aliases = true
  for _, alias in ipairs(expected_aliases) do
    all_aliases = all_aliases and vim.tbl_contains(sub_schema.properties.model.enum, alias)
  end
  check(
    all_aliases and #sub_schema.properties.model.enum == #expected_aliases,
    "default scout schema exposes exactly the three current Codex and three Claude aliases"
  )
  local function schema_aliases(parent_model)
    for _, schema in ipairs(tools.schemas(parent_model)) do
      if schema.name == "sub_agent" then return schema.input_schema.properties.model.enum or {} end
    end
    return {}
  end
  local openai_aliases = schema_aliases({ provider = "openai", id = "gpt-5.6-sol" })
  local anthropic_aliases = schema_aliases({ provider = "anthropic", id = "claude-opus-4-8" })
  check(
    #openai_aliases == 3
      and vim.tbl_contains(openai_aliases, "sol")
      and vim.tbl_contains(openai_aliases, "terra")
      and vim.tbl_contains(openai_aliases, "luna")
      and not vim.tbl_contains(openai_aliases, "opus"),
    "Codex parents expose only same-provider Sol/Terra/Luna scout aliases"
  )
  check(
    #anthropic_aliases == 3
      and vim.tbl_contains(anthropic_aliases, "opus")
      and vim.tbl_contains(anthropic_aliases, "sonnet")
      and vim.tbl_contains(anthropic_aliases, "haiku")
      and not vim.tbl_contains(anthropic_aliases, "sol"),
    "Claude parents expose only same-provider Opus/Sonnet/Haiku scout aliases"
  )
  local affinity_err = require("advantage.subagent").preflight({
    prompt = "cross-provider probe",
    model = "opus",
    effort = "high",
  }, { model = { provider = "openai", id = "gpt-5.6-sol" } })
  check(
    affinity_err
      and affinity_err:find("cross-provider scouting is disabled", 1, true)
      and require("advantage.subagent").preflight({
          prompt = "same-provider probe",
          model = "sol",
          effort = "high",
        }, { model = { provider = "openai", id = "gpt-5.6-sol" } })
        == nil,
    "execution preflight enforces provider affinity even for stale or fabricated tool calls"
  )
  local saved_cross_provider = config.options.subagents.allow_cross_provider
  config.options.subagents.allow_cross_provider = true
  local cross_aliases = schema_aliases({ provider = "openai", id = "gpt-5.6-sol" })
  config.options.subagents.allow_cross_provider = saved_cross_provider
  check(
    #cross_aliases == 6 and vim.tbl_contains(cross_aliases, "opus"),
    "explicit allow_cross_provider opt-in restores mixed OpenAI/Anthropic scout routing"
  )
  local alias_model, alias_ref = config.resolve_subagent_model("sol")
  check(
    alias_model and alias_model.id == "gpt-5.6-sol" and alias_ref == "openai/gpt-5.6-sol",
    "the sol scout alias resolves to the configured current Codex model"
  )
  check(
    config.resolve_subagent_model("openai/gpt-5.1-codex-mini") == nil
      and config.resolve_subagent_model("openai/gpt-5.6") == nil,
    "raw legacy or invented first-party model refs cannot reach a scout provider"
  )
  -- lazy.nvim can reload subagent.lua while the old config module remains in
  -- package.loaded. The alias contract must keep working instead of throwing a
  -- scheduled-callback traceback until Neovim is restarted.
  local resolve_aliases, resolve_choice = config.subagent_model_aliases, config.resolve_subagent_model
  local saved_alias_map = config.options.subagents.model_aliases
  config.subagent_model_aliases, config.resolve_subagent_model = nil, nil
  config.options.subagents.model_aliases = nil
  local mixed_reload_ok, mixed_reload_err =
    pcall(require("advantage.subagent").preflight, { prompt = "mixed reload probe", model = "sol", effort = "medium" })
  config.subagent_model_aliases, config.resolve_subagent_model = resolve_aliases, resolve_choice
  config.options.subagents.model_aliases = saved_alias_map
  check(
    mixed_reload_ok and mixed_reload_err == nil,
    "new subagent code remains compatible with an old cached config module"
  )
  local bad_model_result, bad_model_error
  require("advantage.subagent").run({
    prompt = "inspect",
    model = "openai/gpt-5.1-codex-mini",
    effort = "medium",
  }, {
    cwd = vim.uv.cwd(),
    model = { provider = "fakesub", id = "model", label = "fake sub" },
  }, function(out, is_error)
    bad_model_result, bad_model_error = out, is_error
  end)
  check(
    bad_model_error == true and tostring(bad_model_result):find("Invalid sub-agent model choice", 1, true),
    "an observed transport-incompatible legacy Codex ref is rejected before provider startup"
  )
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "subagent evidence" }, tmp .. "/note.txt")
  local turn, saw_tool_result = 0, false
  providers.register("fakesub", {
    stream = function(req)
      turn = turn + 1
      if turn == 2 then
        for _, msg in ipairs(req.messages) do
          for _, b in ipairs(msg.content or {}) do
            if b.type == "tool_result" and tostring(b.content):find("subagent evidence", 1, true) then
              saw_tool_result = true
            end
          end
        end
      end
      vim.defer_fn(function()
        if turn == 1 then
          req.on.tool_start("r1", "read_file")
          req.on.complete({
            { type = "tool_use", id = "r1", name = "read_file", input = { path = "note.txt" } },
          }, "tool_use")
        else
          req.on.text("report: found subagent evidence in note.txt")
          req.on.complete({ { type = "text", text = "report: found subagent evidence in note.txt" } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })
  local done, result, err = false, nil, nil
  tools.get("sub_agent").run({ prompt = "inspect note", model = "fakesub/model", effort = "medium", max_turns = 4 }, {
    cwd = tmp,
    model = { provider = "fakesub", id = "model", label = "fake sub" },
  }, function(out, is_err)
    result, err, done = out, is_err, true
  end)
  vim.wait(5000, function()
    return done
  end, 10)
  check(turn == 2 and saw_tool_result, "sub-agent can use read-only tools in its own loop")
  check(err == false and assert(result):find("subagent evidence", 1, true), "sub-agent returns final report")

  -- Model choice is intentional: an empty/whitespace ref must never silently
  -- inherit a model the parent did not name.
  turn, saw_tool_result, done, result, err = 0, false, false, nil, nil
  tools.get("sub_agent").run({ prompt = "inspect note", model = "   ", effort = "" }, {
    cwd = tmp,
    model = { provider = "fakesub", id = "model", label = "fake sub" },
  }, function(out, is_err)
    result, err, done = out, is_err, true
  end)
  check(
    done and turn == 0 and err == true and result and result:find("model is required", 1, true),
    "empty sub-agent model is rejected instead of silently inheriting"
  )
  done, result, err = false, nil, nil
  tools.get("sub_agent").run({ prompt = "inspect note", model = "fakesub/model", effort = "   " }, {
    cwd = tmp,
    model = { provider = "fakesub", id = "model", label = "fake sub" },
  }, function(out, is_err)
    result, err, done = out, is_err, true
  end)
  check(
    done and turn == 0 and err == true and result and result:find("effort is required", 1, true),
    "empty sub-agent effort is rejected instead of silently defaulting"
  )

  -- A provider-level auth failure removes every alias for that provider from
  -- subsequent schemas, preventing Sonnet→Haiku→Opus retry roulette.
  local subagent = require("advantage.subagent")
  subagent._reset_route_health()
  local saved_models = vim.deepcopy(config.options.models)
  local saved_aliases = vim.deepcopy(config.options.subagents.model_aliases)
  config.options.models[#config.options.models + 1] = { ref = "fakeauth/model", label = "fake auth" }
  config.options.subagents.model_aliases.broken_auth = "fakeauth/model"
  local auth_starts = 0
  providers.register("fakeauth", {
    stream = function(req)
      auth_starts = auth_starts + 1
      vim.schedule(function()
        req.on.error("Claude token refresh failed (Rate limited. Please try again later.)")
      end)
      return { stop = function() end }
    end,
  })
  local auth_done, auth_result = false, nil
  subagent.run({ prompt = "auth probe", model = "broken_auth", effort = "medium" }, {
    cwd = tmp,
    model = { provider = "fakeauth", id = "model", label = "fake auth" },
  }, function(out)
    auth_done, auth_result = true, out
  end)
  vim.wait(1000, function()
    return auth_done
  end, 10)
  local still_available = false
  for _, item in ipairs(subagent.available_model_aliases()) do
    if item.alias == "broken_auth" then still_available = true end
  end
  check(
    auth_starts == 1
      and not still_available
      and tostring(auth_result):find("do not try another fakeauth model", 1, true),
    "provider auth failure opens a cooldown and explicitly stops sibling-model retries"
  )
  config.options.models = saved_models
  config.options.subagents.model_aliases = saved_aliases
  subagent._reset_route_health()
end

-- 4b-limit. sub-agent turn-limit guarantees a real report ----------------------
-- Regression: a scout that spends every turn calling tools (a reasoning model
-- bug-hunting a subsystem emits thinking + tool_use and no assistant text until
-- the end) used to hit the turn limit having produced no text, so the parent got
-- "hit its N-turn limit" flagged as an error with zero findings. The final turn is
-- now report-only — tools withheld via tool_choice "none" — so the budget always
-- ends in a real report.
do
  local providers = require("advantage.providers")
  local tools = require("advantage.tools")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "latent bug here" }, tmp .. "/note.txt")

  local turns, final_choice, budget_in_prompt, final_had_tools = 0, nil, false, nil
  providers.register("fakesublimit", {
    stream = function(req)
      turns = turns + 1
      if req.system and req.system:find("budget of about 3 turns", 1, true) then budget_in_prompt = true end
      vim.defer_fn(function()
        if req.tool_choice == "none" then
          -- final report-only turn: a compliant model writes its findings
          final_choice = req.tool_choice
          final_had_tools = type(req.tools) == "table" and #req.tools > 0
          local txt = "FINAL REPORT: read note.txt (note.txt:1) — latent bug confirmed."
          req.on.text(txt)
          req.on.complete({ { type = "text", text = txt } }, "end_turn")
        else
          -- always call a tool, never volunteer text (models the failing case)
          req.on.tool_start("r" .. turns, "read_file")
          req.on.complete(
            { { type = "tool_use", id = "r" .. turns, name = "read_file", input = { path = "note.txt" } } },
            "tool_use"
          )
        end
      end, 5)
      return { stop = function() end }
    end,
  })

  local done, result, err = false, nil, nil
  tools.get("sub_agent").run({
    prompt = "bug-hunt note.txt",
    model = "fakesublimit/model",
    effort = "medium",
    max_turns = 3,
  }, {
    cwd = tmp,
    model = { provider = "fakesublimit", id = "model", label = "fake" },
  }, function(out, is_err)
    result, err, done = out, is_err, true
  end)
  vim.wait(5000, function()
    return done
  end, 10)

  check(turns == 3, "sub-agent uses its full turn budget (2 investigation turns + 1 report)")
  check(budget_in_prompt, "sub-agent system prompt tells the model its turn budget")
  check(final_choice == "none", "the final turn withholds tools with tool_choice 'none'")
  check(final_had_tools == true, "the final turn still DECLARES the tools (so prior tool_use blocks validate)")
  check(err == false, "a turn-limit stop is NOT flagged as an error")
  check(
    result ~= nil
      and result:find("FINAL REPORT", 1, true)
      and result:find("note.txt:1", 1, true)
      and result:find("3/3 requests", 1, true),
    "the turn budget ends in a real report with findings, not an empty limit error"
  )

  -- Defensive: a NON-compliant model that keeps emitting tool_use even on the
  -- report-only turn (ignoring tool_choice) must still finish gracefully — never
  -- loop past the budget, never crash — falling back to a plain finished message.
  local turns2 = 0
  providers.register("fakesubdefiant", {
    stream = function(req)
      turns2 = turns2 + 1
      vim.defer_fn(function()
        req.on.tool_start("d" .. turns2, "read_file")
        req.on.complete(
          { { type = "tool_use", id = "d" .. turns2, name = "read_file", input = { path = "note.txt" } } },
          "tool_use"
        )
      end, 5)
      return { stop = function() end }
    end,
  })
  local done2, result2, err2 = false, nil, nil
  tools.get("sub_agent").run({ prompt = "x", model = "fakesubdefiant/model", effort = "medium", max_turns = 3 }, {
    cwd = tmp,
    model = { provider = "fakesubdefiant", id = "model", label = "fake" },
  }, function(out, is_err)
    result2, err2, done2 = out, is_err, true
  end)
  vim.wait(5000, function()
    return done2
  end, 10)
  check(turns2 == 3, "a defiant model still stops at the turn budget (no runaway loop)")
  check(done2 and err2 == false and result2 ~= nil, "a defiant model still yields a (non-error) final result")

  -- max_turns is floored at 2 so the report-only final turn never leaves the scout
  -- with zero investigation turns (a budget of 1 would report having read nothing).
  local turns3 = 0
  providers.register("fakesubfloor", {
    stream = function(req)
      turns3 = turns3 + 1
      vim.defer_fn(function()
        if req.tool_choice == "none" then
          req.on.complete({ { type = "text", text = "floor report" } }, "end_turn")
        else
          req.on.tool_start("f" .. turns3, "list_dir")
          req.on.complete(
            { { type = "tool_use", id = "f" .. turns3, name = "list_dir", input = { path = "." } } },
            "tool_use"
          )
        end
      end, 5)
      return { stop = function() end }
    end,
  })
  local done3 = false
  tools.get("sub_agent").run({ prompt = "x", model = "fakesubfloor/model", effort = "medium", max_turns = 1 }, {
    cwd = tmp,
    model = { provider = "fakesubfloor", id = "model", label = "fake" },
  }, function()
    done3 = true
  end)
  vim.wait(5000, function()
    return done3
  end, 10)
  check(turns3 == 2, "max_turns=1 is floored to 2 (one investigation turn + one report turn)")

  local checkpoint_turns, checkpoint_seen = 0, false
  providers.register("fakesubsufficient", {
    stream = function(req)
      checkpoint_turns = checkpoint_turns + 1
      if checkpoint_turns == 5 then
        for _, message in ipairs(req.messages or {}) do
          for _, block in ipairs(message.content or {}) do
            if block.type == "text" and tostring(block.text):find("Sufficiency checkpoint", 1, true) then
              checkpoint_seen = true
            end
          end
        end
      end
      vim.defer_fn(function()
        if checkpoint_turns == 5 then
          req.on.complete({ { type = "text", text = "checkpoint report" } }, "end_turn")
        else
          req.on.tool_start("c" .. checkpoint_turns, "read_file")
          req.on.complete({
            {
              type = "tool_use",
              id = "c" .. checkpoint_turns,
              name = "read_file",
              input = { path = "note.txt" },
            },
          }, "tool_use")
        end
      end, 5)
      return { stop = function() end }
    end,
  })
  local checkpoint_done, checkpoint_result = false, nil
  tools.get("sub_agent").run({
    prompt = "stop once evidence is sufficient",
    model = "fakesubsufficient/model",
    effort = "medium",
    max_turns = 6,
  }, {
    cwd = tmp,
    model = { provider = "fakesubsufficient", id = "model", label = "fake" },
  }, function(out)
    checkpoint_result, checkpoint_done = out, true
  end)
  vim.wait(5000, function()
    return checkpoint_done
  end, 10)
  check(
    checkpoint_seen and checkpoint_turns == 5 and checkpoint_result and checkpoint_result:find("5/6 requests", 1, true),
    "turn-four sufficiency checkpoint encourages an evidence-complete scout to report before its hard ceiling"
  )
end

-- 4b-tc. providers forward tool_choice to the request body ---------------------
do
  local anthropic = require("advantage.providers.anthropic")
  local openai = require("advantage.providers.openai")
  local config = require("advantage.config")

  local a_none = anthropic._build_body(
    config.options.providers.anthropic,
    { model = { id = "m", thinking = false }, system = "s", messages = {}, tools = {}, tool_choice = "none" },
    { { type = "text", text = "s" } }
  )
  check(
    type(a_none.tool_choice) == "table" and a_none.tool_choice.type == "none",
    "anthropic maps tool_choice 'none' to { type = 'none' }"
  )
  local a_auto = anthropic._build_body(
    config.options.providers.anthropic,
    { model = { id = "m", thinking = false }, system = "s", messages = {}, tools = {} },
    { { type = "text", text = "s" } }
  )
  check(a_auto.tool_choice == nil, "anthropic omits tool_choice when the request sets none")

  local tool = { { name = "read_file", description = "d", input_schema = { type = "object" } } }
  local o_none = openai._build_body(
    config.options.providers.openai,
    { model = { id = "m" }, messages = {}, tools = tool, tool_choice = "none" }
  )
  check(o_none.tool_choice == "none", "openai forwards tool_choice 'none' even with tools present")
  local o_auto =
    openai._build_body(config.options.providers.openai, { model = { id = "m" }, messages = {}, tools = tool })
  check(o_auto.tool_choice == "auto", "openai defaults to 'auto' when tools exist and no tool_choice given")
  local o_parallel = openai._build_body(config.options.providers.openai, {
    model = { id = "m" },
    messages = {},
    tools = tool,
    parallel_tool_calls = true,
  })
  check(o_parallel.parallel_tool_calls == true, "openai permits same-turn parallel tool calls when requested")
  local o_serial = openai._build_body(config.options.providers.openai, {
    model = { id = "m" },
    messages = {},
    tools = tool,
    parallel_tool_calls = false,
  })
  check(o_serial.parallel_tool_calls == false, "openai can explicitly disable same-turn parallel tool calls")
end

-- 4b-tc2. provider/model-aware thinking and effort matrix ----------------------

section("provider effort matrix")
do
  local anthropic = require("advantage.providers.anthropic")
  local openai = require("advantage.providers.openai")
  local config = require("advantage.config")
  local effort = require("advantage.effort")
  local pcfg = config.options.providers.anthropic
  local system = { { type = "text", text = "sys" } }
  local messages = { { role = "user", content = { { type = "text", text = "hi" } } } }

  local function anthropic_body(model)
    return anthropic._build_body(pcfg, { model = model, messages = messages, tools = {} }, system)
  end

  local opus = assert(config.resolve_model("anthropic/claude-opus-4-8"))
  local label, err = effort.set_anthropic(opus, "xhigh")
  local opus_body = anthropic_body(opus)
  check(
    label ~= nil
      and err == nil
      and opus_body.thinking
      and opus_body.thinking.type == "adaptive"
      and opus_body.thinking.budget_tokens == nil
      and opus_body.output_config.effort == "xhigh",
    "Opus 4.8 maps xhigh to adaptive thinking plus output_config.effort (never a fixed budget)"
  )

  local sonnet = assert(config.resolve_model("anthropic/claude-sonnet-5"))
  label, err = effort.set_anthropic(sonnet, "off")
  local sonnet_body = anthropic_body(sonnet)
  check(
    label ~= nil and err == nil and sonnet_body.thinking and sonnet_body.thinking.type == "disabled",
    "Sonnet 5 sends explicit thinking.disabled because omission would keep default adaptive thinking on"
  )

  local fable = assert(config.resolve_model("anthropic/claude-fable-5"))
  label, err = effort.set_anthropic(fable, "off")
  check(label == nil and type(err) == "string", "Fable 5 does not offer an unsupported thinking-off mode")
  assert(effort.set_anthropic(fable, "high"))
  local fable_body = anthropic_body(fable)
  check(
    fable_body.thinking == nil and fable_body.output_config and fable_body.output_config.effort == "high",
    "Fable 5 controls always-on native thinking through output_config.effort without a rejected thinking object"
  )

  local haiku = assert(config.resolve_model("anthropic/claude-haiku-4-5"))
  assert(effort.set_anthropic(haiku, "medium"))
  local haiku_body = anthropic_body(haiku)
  check(
    haiku_body.thinking
      and haiku_body.thinking.type == "enabled"
      and haiku_body.thinking.budget_tokens == 4096
      and haiku_body.output_config == nil,
    "Haiku 4.5 retains the legacy fixed-budget thinking path"
  )
  assert(effort.set_anthropic(haiku, "xhigh"))
  check(
    anthropic_body(haiku).thinking.budget_tokens == 16384,
    "provider-neutral xhigh maps to Haiku's legacy highest budget"
  )

  local sol = assert(config.resolve_model("openai/gpt-5.6-sol"))
  local luna = assert(config.resolve_model("openai/gpt-5.6-luna"))
  local chatgpt_sol = effort.openai_levels(sol, "chatgpt")
  local api_sol = effort.openai_levels(sol, "api_key")
  check(
    vim.tbl_contains(chatgpt_sol, "max")
      and not vim.tbl_contains(chatgpt_sol, "ultra")
      and not vim.tbl_contains(chatgpt_sol, "none"),
    "ChatGPT-login Sol exposes real wire efforts through max; Ultra belongs to the harness picker"
  )
  check(
    vim.tbl_contains(api_sol, "none") and not vim.tbl_contains(api_sol, "ultra"),
    "raw-API Sol exposes explicit none but not subscription-only ultra"
  )
  check(
    not vim.tbl_contains(effort.openai_levels(luna, "chatgpt"), "ultra"),
    "Luna does not inherit Sol/Terra's unsupported ultra level"
  )
  local gpt55 = assert(config.resolve_model("openai/gpt-5.5"))
  local sol_login, sol_login_err = effort.resolve_openai(sol, "chatgpt", "ultra")
  local luna_login, luna_login_err = effort.resolve_openai(luna, "chatgpt", "ultra")
  local gpt55_login, gpt55_login_err = effort.resolve_openai(gpt55, "chatgpt", "ultra")
  local sol_api, sol_api_err = effort.resolve_openai(sol, "api_key", "ultra")
  check(
    sol_login == "max"
      and sol_login_err == nil
      and luna_login == "max"
      and luna_login_err == nil
      and gpt55_login == "xhigh"
      and gpt55_login_err == nil
      and sol_api == "max"
      and sol_api_err == nil,
    "ultra resolves to maximum wire effort while preserving model/transport clamping"
  )
  local ultra_body = openai._build_body(config.options.providers.openai, {
    model = { id = "gpt-5.6-sol", reasoning_effort = "ultra" },
    messages = messages,
    tools = {},
  })
  check(
    ultra_body.reasoning.effort == "max",
    "OpenAI Ultra is a harness mode and never sends an invalid literal ultra effort"
  )
  local login_url, login_headers = openai._endpoint_for(
    { mode = "chatgpt", token = "token", account_id = "account" },
    config.options.providers.openai,
    ultra_body,
    { session_id = "session-probe" }
  )
  local header_text = table.concat(login_headers, "\n"):lower()
  check(
    login_url == "https://chatgpt.com/backend-api/codex/responses"
      and header_text:find("session%-id: session%-probe") ~= nil
      and header_text:find("thread%-id: session%-probe") ~= nil
      and header_text:find("session_id:", 1, true) == nil
      and header_text:find("openai%-beta:") == nil,
    "ChatGPT login uses current Codex identity headers without the stale Responses beta"
  )
  local ultra_prompt = require("advantage.agent").system_prompt(nil, nil, nil, sol, "ultra")
  local ultra_prompt_lower = ultra_prompt:lower()
  check(
    ultra_prompt:find("Harness mode: ultra", 1, true) ~= nil
      and ultra_prompt_lower:find("proactively consider delegation", 1, true) ~= nil
      and ultra_prompt_lower:find("task-proportional", 1, true) ~= nil,
    "Ultra adds proactive parallel-delegation policy to the parent harness"
  )
  local explicit_parallel_guide = require("advantage.harness").guide("auto", sol, true)
  check(
    explicit_parallel_guide:find("Emit all independent sub_agent calls together", 1, true) ~= nil,
    "an explicit user parallel request forces same-response scout fan-out guidance"
  )
  local explicit_api_sol = vim.deepcopy(sol)
  explicit_api_sol.reasoning_effort = "ultra"
  local explicit_value, explicit_err = effort.resolve_openai(explicit_api_sol, "api_key", "ultra")
  check(explicit_value == "max" and explicit_err == nil, "a persisted pre-migration Ultra effort safely aliases to max")

  local none_body = openai._build_body(config.options.providers.openai, {
    model = { id = "gpt-5.6-sol", reasoning_effort = "none" },
    messages = messages,
    tools = {},
  })
  check(
    none_body.reasoning.effort == "none" and none_body.reasoning.summary == nil and none_body.include == nil,
    "OpenAI reasoning-off is sent explicitly as none and suppresses summary/encrypted-reasoning requests"
  )

  local unknown = { id = "claude-future-unannotated" }
  local unknown_items = effort.anthropic_items(unknown)
  local unknown_body = anthropic_body(unknown)
  check(
    #unknown_items == 1 and unknown_items[1].value == "default" and unknown_body.thinking == nil,
    "unknown Claude IDs omit generation-specific thinking knobs until capabilities are declared"
  )
end

-- 4a2. independent harness orchestration modes ---------------------------------

section("harness modes")
do
  local harness = require("advantage.harness")
  local config = require("advantage.config")
  local agent_mod = require("advantage.agent")
  local sol = assert(config.resolve_model("openai/gpt-5.6-sol"))

  local low, high, max, ultra =
    harness.policy("low", sol), harness.policy("high", sol), harness.policy("max", sol), harness.policy("ultra", sol)
  check(
    not low.proactive
      and not low.parallel
      and low.max_parallel == 1
      and high.proactive
      and high.max_parallel == 2
      and not max.proactive
      and ultra.proactive
      and ultra.max_parallel == 8,
    "harness presets progressively control proactive and parallel delegation"
  )
  local auto_model = vim.deepcopy(sol)
  auto_model.reasoning_effort = "xhigh"
  check(harness.effective("auto", auto_model) == "xhigh", "auto harness mode follows the current effort")

  local preset_model = vim.deepcopy(sol)
  assert(harness.sync_effort(preset_model, "high"))
  check(preset_model.reasoning_effort == "high", "selecting a harness preset initializes matching model effort")
  assert(harness.sync_effort(preset_model, "ultra"))
  check(
    preset_model.reasoning_effort == "max",
    "Ultra initializes max model effort while remaining a separate harness setting"
  )

  local ag = agent_mod.new({ model = preset_model, harness_mode = "high" })
  check(
    ag:harness_policy().mode == "high" and ag:harness_policy().max_parallel == 2,
    "each agent owns an independent harness mode and concurrency policy"
  )
  check(
    agent_mod.new({ model = preset_model, harness_mode = "tampered" }).harness_mode == "auto",
    "invalid persisted harness modes normalize safely to auto"
  )
  local high_prompt = agent_mod.system_prompt(nil, ag.ctx.cwd, ag._base_system_prompt, ag.model, ag.harness_mode)
  check(
    high_prompt:find("Harness mode: high", 1, true) ~= nil
      and high_prompt:find('model="sol"', 1, true) ~= nil
      and high_prompt:find("Never invent", 1, true) ~= nil,
    "the exact parent prompt names its known-working scout alias and forbids model guessing"
  )
  assert(require("advantage.effort").set_openai(ag.model, "low"))
  local independent_body = require("advantage.providers.openai")._build_body(config.options.providers.openai, {
    model = ag.model,
    messages = {},
    tools = {},
  })
  check(
    ag:harness_policy().mode == "high" and independent_body.reasoning.effort == "low",
    "reasoning effort remains independently adjustable after selecting a harness preset"
  )

  local saved_subagents = vim.deepcopy(config.options.subagents)
  config.options.subagents.parallel = false
  local sequential_guide = harness.guide("ultra", sol)
  config.options.subagents.enabled = false
  local disabled_guide = harness.guide("ultra", sol)
  config.options.subagents = saved_subagents
  check(
    sequential_guide:find('mode="sequential"', 1, true) ~= nil
      and sequential_guide:find("globally disabled parallel scheduler", 1, true) ~= nil
      and disabled_guide:find("Sub-agents are disabled", 1, true) ~= nil,
    "harness guidance respects global sequential and disabled overrides"
  )

  local advantage = require("advantage")
  check(
    vim.tbl_contains(advantage._subcommands, "harness")
      and vim.tbl_contains(advantage._harness_modes, "ultra")
      and vim.tbl_contains(advantage._effort_modes, "xhigh")
      and config.defaults.keymaps.harness == "<leader>ch",
    "commands and defaults expose harness modes through <leader>ch"
  )
end

-- 4c. auth handles null-bearing credential files -------------------------------

section("auth null handling")
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/.claude", "p")
  vim.fn.mkdir(tmp .. "/.codex", "p")
  vim.fn.writefile({ '{"claudeAiOauth": null}' }, tmp .. "/.claude/.credentials.json")
  vim.fn.writefile({ '{"OPENAI_API_KEY": null, "tokens": null}' }, tmp .. "/.codex/auth.json")
  vim.env.CLAUDE_CONFIG_DIR = tmp .. "/.claude"
  vim.env.CODEX_HOME = tmp .. "/.codex"
  vim.env.ANTHROPIC_API_KEY = nil
  vim.env.OPENAI_API_KEY = nil

  local auth = require("advantage.auth")
  local a_done, a_cred, a_err
  local ok = pcall(auth.anthropic, function(cred, err)
    a_done, a_cred, a_err = true, cred, err
  end)
  check(ok and a_done and a_cred == nil and type(a_err) == "string", "anthropic: null oauth → clean error, no crash")

  local o_done, o_cred, o_err
  ok = pcall(auth.openai, function(cred, err)
    o_done, o_cred, o_err = true, cred, err
  end)
  check(ok and o_done and o_cred == nil and type(o_err) == "string", "openai: null tokens → clean error, no crash")

  vim.env.CLAUDE_CONFIG_DIR = nil
  vim.env.CODEX_HOME = nil
end

-- 4a3. LLM-summarized compaction routed through the real openai/codex provider --

section("codex summarizer (real openai provider path)")
do
  -- Force the api-key fallback deterministically: point CODEX_HOME at an empty
  -- temp dir so no real ~/.codex/auth.json (and no real token refresh) is ever
  -- touched, matching the isolation the "auth null handling" section above uses.
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.env.CODEX_HOME = tmp
  vim.env.OPENAI_API_KEY = "test-key"

  local util = require("advantage.util")
  local config = require("advantage.config")
  local compact = require("advantage.compact")

  config.options.context.keep_recent_messages = 4
  config.options.context.summarizer_model = "openai/gpt-5.6-luna"

  local captured_body
  local orig_request_sse = util.request_sse
  ---@diagnostic disable-next-line: duplicate-set-field
  util.request_sse = function(opts)
    captured_body = vim.json.decode(opts.body)
    vim.schedule(function()
      opts.on_event("response.output_item.done", {
        type = "response.output_item.done",
        item = {
          type = "message",
          content = { { type = "output_text", text = "Primary Request and Intent: ship the widget." } },
        },
      })
      opts.on_event("response.completed", {
        type = "response.completed",
        response = { usage = { input_tokens = 400, output_tokens = 60 } },
      })
    end)
    return { stop = function() end }
  end

  local function make_messages(n)
    local out = {}
    for i = 1, n do
      out[#out + 1] = {
        role = i % 2 == 1 and "user" or "assistant",
        content = { { type = "text", text = ("turn %d content"):format(i) } },
      }
    end
    return out
  end

  local done, next_messages, info, err = false, nil, nil, nil
  compact.summarize_with_llm(make_messages(10), config.options.context, function(nm, i, e)
    next_messages, info, err = nm, i, e
    done = true
  end)
  vim.wait(2000, function()
    return done
  end, 5)

  util.request_sse = orig_request_sse
  vim.env.CODEX_HOME = nil
  vim.env.OPENAI_API_KEY = nil

  check(done, "codex summarizer request completed")
  check(err == nil, "no error routing summarization through the openai/codex provider")
  check(
    captured_body ~= nil and captured_body.model == "gpt-5.6-luna",
    "request targets the configured OpenAI/Codex summarizer model"
  )
  check(
    captured_body
      and captured_body.reasoning
      and captured_body.reasoning.effort == "medium"
      and captured_body.reasoning.summary == nil,
    "raw-API summarizer uses balanced medium reasoning and suppresses discarded reasoning summaries"
  )
  local codex_summary
  for _, m in ipairs(next_messages or {}) do
    for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
      if type(b) == "table" and b.text and b.text:find(compact._SUMMARY_PREFIX, 1, true) then codex_summary = b.text end
    end
  end
  check(codex_summary ~= nil, "codex-produced summary still carries the shared SUMMARY_PREFIX")
  check(
    info and info.mode == "llm" and info.model and info.model.provider == "openai",
    "info reports the resolved openai/codex summarizer model"
  )

  -- Provider independence: with no explicit summarizer_model, an OpenAI/Codex
  -- active model must NOT reach for a Claude (anthropic) summarizer.
  local auto =
    compact._resolve_summarizer(config.defaults.context, { provider = "openai", id = "gpt-5.1-codex", label = "codex" })
  check(
    auto and auto.provider == "openai" and auto.id == "gpt-5.1-codex",
    "OpenAI auto-compaction uses the active model"
  )
  local auto_anthropic = compact._resolve_summarizer(
    config.defaults.context,
    { provider = "anthropic", id = "claude-opus-4-8", label = "opus" }
  )
  check(
    auto_anthropic and auto_anthropic.provider == "anthropic" and auto_anthropic.id == "claude-haiku-4-5",
    "auto summarizer uses Haiku for an Anthropic model"
  )

  -- ChatGPT login catalogs can expose the active flagship while rejecting a
  -- configured sibling. A 404 for Luna must retry once with the active login
  -- model at its inherited quality level instead of dropping straight to the heuristic.
  do
    local auth = require("advantage.auth")
    local original_auth = auth.openai
    local original_request = util.request_sse
    local bodies = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    auth.openai = function(cb)
      cb({ mode = "chatgpt", token = "login-token", account_id = "acct", badge = "codex" })
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    util.request_sse = function(opts)
      local body = vim.json.decode(opts.body)
      bodies[#bodies + 1] = body
      vim.schedule(function()
        if body.model == "gpt-5.6-luna" then
          opts.on_error("HTTP 404: Model not found gpt-5.6-luna", 404)
        else
          opts.on_event("response.output_item.done", {
            type = "response.output_item.done",
            item = {
              type = "message",
              id = "fallback-summary",
              content = { { type = "output_text", text = "Primary Request and Intent: preserve login fallback." } },
            },
          })
          opts.on_event("response.completed", {
            type = "response.completed",
            response = { usage = { input_tokens = 300, output_tokens = 40 } },
          })
        end
      end)
      return { stop = function() end }
    end

    local fallback_done, fallback_info, fallback_err = false, nil, nil
    local active = assert(config.resolve_model("openai/gpt-5.6-sol"))
    compact.summarize_with_llm(make_messages(10), config.options.context, function(_, i, e)
      fallback_info, fallback_err, fallback_done = i, e, true
    end, active)
    vim.wait(2000, function()
      return fallback_done
    end, 5)
    auth.openai = original_auth
    util.request_sse = original_request

    check(
      fallback_done
        and fallback_err == nil
        and #bodies == 2
        and bodies[1].model == "gpt-5.6-luna"
        and bodies[2].model == "gpt-5.6-sol",
      "Luna 404 on ChatGPT login retries exactly once with the active Sol model"
    )
    check(
      bodies[1]
        and bodies[2]
        and bodies[1].reasoning.effort == "medium"
        and bodies[2].reasoning.effort == "medium"
        and fallback_info
        and fallback_info.model.id == "gpt-5.6-sol"
        and fallback_info.fallback_from == "gpt-5.6 luna",
      "login-model fallback preserves balanced compaction effort and reports both selected and unavailable models"
    )
  end
end

-- 5. deterministic verification -------------------------------------------------

section("deterministic verification")
do
  local verification = require("advantage.verification")
  local root = vim.fn.tempname() .. "-verification"
  vim.fn.mkdir(root, "p")
  local result
  verification.run({ "printf first > first.txt", "test -f first.txt && printf second" }, {
    cwd = root,
    timeout_ms = 2000,
    max_output_bytes = 1000,
  }, function(value)
    result = value
  end)
  vim.wait(3000, function()
    return result ~= nil
  end, 10)
  check(result and result.ok and result.commands_run == 2, "configured verification commands run in order")
  check(vim.fn.filereadable(root .. "/first.txt") == 1, "verification commands run in the project root")

  result = nil
  verification.run({ "printf gate-failed; exit 7", "touch should-not-run" }, {
    cwd = root,
    timeout_ms = 2000,
    max_output_bytes = 1000,
  }, function(value)
    result = value
  end)
  vim.wait(3000, function()
    return result ~= nil
  end, 10)
  check(result and not result.ok and result.command:find("gate%-failed"), "the first failed gate is reported")
  check(vim.fn.filereadable(root .. "/should-not-run") == 0, "later gates do not run after a failure")

  local manifest = require("advantage.verification_manifest")
  local manifest_dir = root .. "/.advantage"
  local manifest_file = manifest_dir .. "/verification.json"
  vim.fn.mkdir(manifest_dir, "p")
  vim.fn.writefile({ '{"version":1,"commands":["make test","make lint"]}' }, manifest_file)
  manifest._trust_path_override = root .. "/state/verification-trust.json"
  local snapshot = manifest.load(root, ".advantage/verification.json")
  check(
    not snapshot.error and vim.deep_equal(snapshot.commands, { "make test", "make lint" }),
    "project verification manifest loads strict versioned commands"
  )
  check(not manifest.is_trusted(root, snapshot), "a new project manifest is untrusted")
  local trusted = manifest.trust(root, snapshot)
  check(trusted and manifest.is_trusted(root, snapshot), "an approved manifest hash persists")

  vim.fn.writefile({ '{"version":1,"commands":["make test --all"]}' }, manifest_file)
  local changed_snapshot = manifest.load(root, ".advantage/verification.json")
  check(not manifest.is_trusted(root, changed_snapshot), "changing manifest commands requires fresh approval")
  vim.fn.writefile({ '{"version":1,"commands":[7]}' }, manifest_file)
  check(manifest.load(root, ".advantage/verification.json").error ~= nil, "non-string manifest commands fail closed")
  vim.fn.writefile({ "not json" }, manifest_file)
  check(manifest.load(root, ".advantage/verification.json").error == "invalid JSON", "malformed manifests fail closed")
  local outside_manifest = vim.fn.tempname() .. "-outside-verification.json"
  vim.fn.writefile({ '{"version":1,"commands":["outside"]}' }, outside_manifest)
  vim.fn.delete(manifest_file)
  local symlinked = (vim.uv or vim.loop).fs_symlink(outside_manifest, manifest_file)
  check(
    symlinked
      and manifest.load(root, ".advantage/verification.json").error == "manifest symlink escapes the project root",
    "manifest symlinks cannot escape the project"
  )
  vim.fn.delete(manifest_file)
  vim.fn.delete(outside_manifest)
  vim.fn.writefile({ '{"version":1,"commands":["make test --all"]}' }, manifest_file)

  local config = require("advantage.config")
  local old_verification = config.options.verification
  local old_yolo = config.options.tools.yolo
  config.options.tools.yolo = false
  config.options.verification = {
    enabled = true,
    commands = {},
    manifest = ".advantage/verification.json",
    timeout_ms = 1000,
    max_output_bytes = 1000,
    max_repairs = 1,
  }
  local agent_module = require("advantage.agent")
  local guide = agent_module.verification_guide()
  local initial_prompt = agent_module.system_prompt("", root)
  check(
    guide
      and #guide < 300
      and initial_prompt:find("Never invent or weaken checks", 1, true)
      and initial_prompt:find(".advantage/verification.json", 1, true),
    "the initial prompt gets compact manifest-maintenance guidance"
  )
  config.options.verification.commands = { "project-check" }
  local agent = require("advantage.agent").new({
    id = "verification-test",
    model = { provider = "fake", id = "test-model", label = "fake" },
    start_cwd = root,
  })
  local notices, finished, restarted = {}, 0, 0
  local approval_callback
  agent.ui = function()
    return {
      set_status = function() end,
      notice = function(message)
        notices[#notices + 1] = message
      end,
      user_message = function() end,
      confirm = function(_, callback)
        approval_callback = callback
        return callback
      end,
    }
  end
  agent._finish = function(_, errored)
    finished = finished + 1
    agent.test_errored = errored
  end
  agent._restart_turn = function()
    restarted = restarted + 1
  end

  agent.turn_changed = {}
  agent:_run_automatic_verification()
  check(finished == 1, "read-only turns skip automatic verification")

  agent.turn_changed = { [root .. "/changed.lua"] = true }
  config.options.verification.enabled = false
  agent:_run_automatic_verification()
  check(finished == 2, "disabled automatic verification adds no gate cost")
  config.options.verification.enabled = true

  local original_run = verification.run
  local gate_callback
  verification.run = function(_, _, callback)
    gate_callback = callback
    return { stop = function() end }
  end
  agent:_run_automatic_verification()
  check(type(gate_callback) == "function" and agent.status == "verifying", "changed work starts verification")
  gate_callback({ ok = true, commands_run = 1 })
  check(finished == 3 and restarted == 0, "passing gates finish without another model turn")

  gate_callback = nil
  agent:_run_automatic_verification()
  gate_callback({ ok = false, command = "project-check", output = "broken" })
  check(restarted == 1 and agent._verification_repairs == 1, "one failed gate starts a same-conversation repair")
  local repair = agent.messages[#agent.messages]
  check(
    repair and repair.role == "user" and repair.content[1].text:find("Do not weaken the check", 1, true),
    "repair receives compact deterministic failure evidence"
  )

  gate_callback = nil
  agent:_run_automatic_verification()
  gate_callback({ ok = false, command = "project-check", output = "still broken" })
  check(finished == 4 and restarted == 1 and agent.test_errored, "repair attempts are bounded")

  config.options.verification.commands = {}
  agent._verification_repairs = 0
  agent._verification_snapshot = snapshot
  local pinned_commands = agent:_verification_plan()
  check(pinned_commands[1] == "make test", "manifest commands stay pinned for the complete user turn")
  agent._verification_snapshot = changed_snapshot
  agent.turn_changed = { [root .. "/changed.lua"] = true }
  gate_callback, approval_callback = nil, nil
  agent:_run_automatic_verification()
  check(approval_callback and not gate_callback, "an unapproved project manifest cannot execute")
  approval_callback("allow")
  check(
    gate_callback and manifest.is_trusted(root, changed_snapshot),
    "approval trusts the exact hash before execution"
  )
  gate_callback({ ok = true, commands_run = 1 })
  check(finished == 5, "approved manifest gates finish normally")

  vim.fn.writefile({ '{"version":1,"commands":["make test --yolo"]}' }, manifest_file)
  local yolo_snapshot = manifest.load(root, ".advantage/verification.json")
  agent._verification_snapshot = yolo_snapshot
  gate_callback, approval_callback = nil, nil
  config.options.tools.yolo = true
  agent:_run_automatic_verification()
  check(
    gate_callback and not approval_callback and manifest.is_trusted(root, yolo_snapshot),
    "yolo trusts the exact manifest hash and starts verification without prompting"
  )
  gate_callback({ ok = true, commands_run = 1 })
  check(finished == 6, "yolo-trusted manifest gates finish normally")

  verification.run = original_run
  manifest._trust_path_override = nil
  config.options.tools.yolo = old_yolo
  config.options.verification = old_verification
  vim.fn.delete(root, "rf")
end

-- 6. agent e2e with a fake provider + UI ----------------------------------------

-- keep test token usage out of the user's real ledger
require("advantage.usage")._ledger_override = vim.fn.tempname() .. "-usage.jsonl"

section("agent e2e (fake provider, real ui)")
do
  require("advantage").setup({
    tools = { auto_approve = { bash = true } },
    models = { { ref = "fake/test-model", label = "fake" } },
    default_model = "fake/test-model",
  })

  local providers = require("advantage.providers")
  local turn = 0
  providers.register("fake", {
    stream = function(req)
      turn = turn + 1
      local on = req.on
      vim.defer_fn(function()
        if turn == 1 then
          on.thinking("considering the request…")
          on.text("Let me run a command.")
          on.tool_start("tu_1", "bash")
          on.usage(100, 20)
          on.complete({
            { type = "text", text = "Let me run a command." },
            { type = "tool_use", id = "tu_1", name = "bash", input = { command = "echo agent-was-here" } },
          }, "tool_use", { input = 100, output = 20 })
        else
          on.text("Done — the command printed agent-was-here.")
          on.usage(140, 12)
          on.complete({
            { type = "text", text = "Done — the command printed agent-was-here." },
          }, "end_turn", { input = 140, output = 12 })
        end
      end, 20)
      return { stop = function() end }
    end,
  })

  local adv = require("advantage")
  adv.open()
  adv.ask("run a demo command")

  vim.wait(8000, function()
    return turn >= 2 and require("advantage.ui.chat").state.status == "idle"
  end, 25)

  local ui = require("advantage.ui.chat")
  check(turn == 2, "two provider turns ran (tool loop)")

  local lines = vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  check(text:find("▍ you", 1, true) ~= nil, "user header rendered")
  check(text:find("considering the request…", 1, true) ~= nil, "thinking streamed")
  check(text:find("  ✓ bash", 1, true) ~= nil, "tool card rendered with ok status")
  check(text:find("agent%-was%-here") ~= nil, "final answer rendered")

  -- transcript shape: user, assistant(tool_use), user(tool_result), assistant(text)
  -- (accessible via the session that autosave wrote)
  local sessions = require("advantage.session").list()
  check(#sessions >= 1, "session autosaved")
  local msgs = sessions[1].messages
  check(#msgs == 4, "conversation has 4 messages")
  check(msgs[2].content[2].type == "tool_use", "assistant tool_use recorded")
  check(
    msgs[3].content[1].type == "tool_result" and msgs[3].content[1].content:find("agent%-was%-here") ~= nil,
    "tool_result captured bash output"
  )
  local public_ok = pcall(function()
    adv.compact()
  end)
  check(public_ok, "public /compact command does not error on a small idle conversation")
end

-- 6. message queue ---------------------------------------------------------------

section("message queue")
do
  local adv = require("advantage")
  local ui = require("advantage.ui.chat")
  adv.ask("first queued test")
  adv.ask("second queued test", { mode = "queued" }) -- explicit queue mode queues behind a running turn
  check(ui.state.queue_count == 1, "second message queued while turn runs")

  vim.wait(8000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
    return ui.state.status == "idle"
      and ui.state.queue_count == 0
      and text:find("▍ you", text:find("second queued test", 1, true) or 1, true) ~= nil
  end, 25)

  local text = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
  check(text:find("queued #1", 1, true) ~= nil, "queue notice rendered")
  check(
    text:find("first queued test", 1, true) ~= nil and text:find("second queued test", 1, true) ~= nil,
    "queued message dispatched after the running turn"
  )
  check(ui.state.queue_count == 0, "queue drained")
end

-- 7. enter interrupt --------------------------------------------------------------

section("enter interrupt")
do
  local providers = require("advantage.providers")
  local agent_mod = require("advantage.agent")
  local ui = require("advantage.ui.chat")
  local function has_continuation(messages)
    for _, message in ipairs(messages or {}) do
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "text" and block.text:find("<harness_continuation>", 1, true) then return true end
      end
    end
    return false
  end
  local turn, stopped, seen, resumed_seen = 0, false, nil, nil
  providers.register("fakeinterrupt", {
    stream = function(req)
      turn = turn + 1
      if turn == 2 then seen = req.messages end
      if turn == 3 then resumed_seen = req.messages end
      local on = req.on
      vim.defer_fn(function()
        if turn == 1 then
          on.text("I may need a command.")
          on.tool_start("tu_interrupt", "bash")
          on.complete({
            { type = "text", text = "I may need a command." },
            { type = "tool_use", id = "tu_interrupt", name = "bash", input = { command = "echo should-not-run" } },
          }, "tool_use")
        elseif turn == 2 then
          on.text("The interruption is answered.")
          on.complete({ { type = "text", text = "The interruption is answered." } }, "end_turn")
        else
          on.text("Resumed and completed the original task.")
          on.complete({ { type = "text", text = "Resumed and completed the original task." } }, "end_turn")
        end
      end, turn == 1 and 30 or 10)
      return {
        stop = function()
          stopped = true
        end,
      }
    end,
  })

  local ag = agent_mod.new({ model = { provider = "fakeinterrupt", id = "m", label = "m" } })
  ag:send("first")
  vim.defer_fn(function()
    ag:send("second before tool")
  end, 5)
  vim.wait(8000, function()
    return turn >= 3 and ui.state.status == "idle"
  end, 25)

  check(stopped == false, "enter while running does not cancel the stream")
  check(turn == 3, "interrupt answer is followed by an automatic continuation turn")
  check(seen and seen[3] and seen[3].role == "user", "interrupt inserted tool-result turn before follow-up")
  check(
    seen and seen[3] and seen[3].content[1].type == "tool_result" and seen[3].content[1].is_error == true,
    "pending tool was skipped with a tool_result"
  )
  check(
    seen
      and seen[4]
      and seen[4].role == "user"
      and seen[4].content[1].type == "text"
      and seen[4].content[1].text:find("second before tool", 1, true),
    "interrupt text sent as its own user turn"
  )

  check(has_continuation(resumed_seen), "the harness explicitly resumes unfinished work after answering the interrupt")

  require("advantage.config").options.tools.auto_approve = {}
  local wait_turn, wait_seen, wait_resumed_seen = 0, nil, nil
  providers.register("fakewaitinterrupt", {
    stream = function(req)
      wait_turn = wait_turn + 1
      if wait_turn == 2 then wait_seen = req.messages end
      if wait_turn == 3 then wait_resumed_seen = req.messages end
      local on = req.on
      vim.defer_fn(function()
        if wait_turn == 1 then
          on.tool_start("tu_wait_interrupt", "bash")
          on.complete({
            { type = "tool_use", id = "tu_wait_interrupt", name = "bash", input = { command = "echo should-not-run" } },
          }, "tool_use")
        elseif wait_turn == 2 then
          on.text("Permission interruption answered.")
          on.complete({ { type = "text", text = "Permission interruption answered." } }, "end_turn")
        else
          on.text("Original permission-gated task resumed.")
          on.complete({ { type = "text", text = "Original permission-gated task resumed." } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })
  local ag_wait = agent_mod.new({ model = { provider = "fakewaitinterrupt", id = "m", label = "m" } })
  ag_wait:send("needs permission")
  vim.wait(8000, function()
    return ui.state.status == "waiting"
  end, 25)
  ag_wait:send("interrupt permission")
  vim.wait(8000, function()
    return wait_turn >= 3 and ui.state.status == "idle"
  end, 25)
  check(wait_turn == 3, "permission interrupt answers and then resumes the original task")
  check(
    wait_seen
      and wait_seen[3]
      and wait_seen[3].content[1].type == "tool_result"
      and wait_seen[3].content[1].content:find("Tool skipped", 1, true),
    "permission interrupt sends skipped tool_result"
  )
  check(has_continuation(wait_resumed_seen), "permission interruption also receives an explicit continuation turn")

  local completed_turns, completed_seen = 0, nil
  providers.register("fakecompletedinterrupt", {
    stream = function(req)
      completed_turns = completed_turns + 1
      if completed_turns == 2 then completed_seen = req.messages end
      local on = req.on
      vim.defer_fn(function()
        if completed_turns == 1 then
          on.text("The original response completed normally.")
          on.complete({ { type = "text", text = "The original response completed normally." } }, "end_turn")
        else
          on.text("Late interruption answered.")
          on.complete({ { type = "text", text = "Late interruption answered." } }, "end_turn")
        end
      end, completed_turns == 1 and 30 or 10)
      return { stop = function() end }
    end,
  })
  local ag_completed = agent_mod.new({ model = { provider = "fakecompletedinterrupt", id = "m", label = "m" } })
  ag_completed:send("task that completes without tools")
  vim.defer_fn(function()
    ag_completed:send("late interruption")
  end, 5)
  vim.wait(8000, function()
    return completed_turns >= 2 and ui.state.status == "idle"
  end, 25)
  vim.wait(50, function()
    return false
  end, 5)
  check(completed_turns == 2, "a completed original response does not receive a redundant continuation turn")
  check(not has_continuation(completed_seen), "normal completion answers the interruption without fake unfinished work")
end

-- 8. ui regressions ---------------------------------------------------------------

section("ui regressions")
do
  local ui = require("advantage.ui.chat")
  ui.clear()
  for _ = 1, 3 do
    ui.close()
    ui.open(false)
  end
  local marks = vim.api.nvim_buf_get_extmarks(ui.state.buf, -1, 0, -1, { details = true })
  local banners = 0
  for _, m in ipairs(marks) do
    if m[4] and m[4].virt_lines then banners = banners + 1 end
  end
  check(banners == 1, "welcome banner rendered exactly once after reopens")
  check(vim.bo[ui.state.buf].modifiable == false, "transcript buffer is read-only")
  local ok = pcall(ui.notice, "error: first line\nsecond line")
  local text = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
  check(ok and text:find("second line", 1, true) ~= nil, "multiline notices render without crashing")
  local failed_line = require("advantage.ui.chat.render").tool_line({
    name = "sub_agent",
    status = "error",
    detail = "audit provider architecture",
    error = "Claude token refresh failed (rate limited)",
  })
  check(
    failed_line:find("audit provider architecture", 1, true) and failed_line:find("token refresh failed", 1, true),
    "failed tool rows retain their task and show the actionable error reason"
  )
end

-- 9. attachments / @mentions -------------------------------------------------------

section("attachments / mentions")
do
  local attach = require("advantage.attach")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "hello", "world" }, tmp .. "/ctx.txt")

  local huge_image = tmp .. "/huge.png"
  local loop = vim.uv or vim.loop
  local huge_fd = assert(loop.fs_open(huge_image, "w", 384))
  assert(loop.fs_ftruncate(huge_fd, 5 * 1024 * 1024 + 1))
  loop.fs_close(huge_fd)
  local huge, huge_err = attach.load_image(huge_image)
  check(not huge and huge_err:find("too large", 1, true), "oversized image files are rejected before allocation")

  local expanded, files = attach.expand_mentions("look at @ctx.txt please", tmp)
  check(#files == 1 and expanded:find("hello\nworld", 1, true) ~= nil, "@mention inlines file content")
  check(expanded:find("```", 1, true) ~= nil, "inlined file is fenced")

  local same, none = attach.expand_mentions("email me @ home and check @missing.txt", tmp)
  check(#none == 0 and same == "email me @ home and check @missing.txt", "non-file mentions left untouched")

  -- line-range mentions
  local p, lo, hi = attach._parse_token("lua/chat.lua:L10-20")
  check(p == "lua/chat.lua" and lo == 10 and hi == 20, "parses @file:L10-20")
  p, lo, hi = attach._parse_token("chat.lua:L7")
  check(p == "chat.lua" and lo == 7 and hi == 7, "parses single-line @file:L7")
  p, lo, hi = attach._parse_token("chat.lua#L3-L5")
  check(p == "chat.lua" and lo == 3 and hi == 5, "parses #L3-L5 variant")
  p, lo, hi = attach._parse_token("plain/path.lua")
  check(p == "plain/path.lua" and lo == nil, "plain path has no range")

  vim.fn.writefile({ "one", "two", "three", "four", "five" }, tmp .. "/ranged.txt")
  local rexp, rfiles = attach.expand_mentions("fix @ranged.txt:L2-4 please", tmp)
  check(#rfiles == 1 and rfiles[1].lo == 2 and rfiles[1].hi == 4, "range captured in file list")
  check(rexp:find("two\nthree\nfour", 1, true) ~= nil, "only the requested lines inlined")
  check(rexp:find("one", 1, true) == nil and rexp:find("five", 1, true) == nil, "out-of-range lines excluded")
  check(rexp:find("L2-4", 1, true) ~= nil and rexp:find("of 5 lines", 1, true) ~= nil, "range + total in fence header")

  local clamped = select(1, attach.expand_mentions("see @ranged.txt:L4-99", tmp))
  check(
    clamped:find("four\nfive", 1, true) ~= nil and clamped:find("L4-5", 1, true) ~= nil,
    "range clamped to file length"
  )

  local listed = attach.project_files(50)
  check(type(listed) == "table" and #listed > 0, "project files listed for @completion")

  -- mentions must respect the sandbox: absolute / .. escapes are not inlined
  local config = require("advantage.config")
  check(
    config.defaults.tools.allow_outside_root == false,
    "tools.allow_outside_root defaults to false (sandbox on by default)"
  )
  local parent = vim.fs.dirname(tmp)
  vim.fn.writefile({ "outside-mention-secret" }, parent .. "/msecret.txt")
  local esc, efiles = attach.expand_mentions("check @../msecret.txt now", tmp)
  check(#efiles == 0 and not esc:find("outside-mention-secret", 1, true), "@mention traversal is blocked")
  config.options.tools.allow_outside_root = true
  local esc2, efiles2 = attach.expand_mentions("check @../msecret.txt now", tmp)
  check(
    #efiles2 == 1 and esc2:find("outside-mention-secret", 1, true),
    "@mention traversal allowed under allow_outside_root"
  )
  config.options.tools.allow_outside_root = false

  -- an in-repo symlink pointing outside must not exfiltrate via @mention
  local slink_ok = pcall(function()
    (vim.uv or vim.loop).fs_symlink(parent .. "/msecret.txt", tmp .. "/mlink.txt")
  end)
  if slink_ok then
    local sesc, sfiles = attach.expand_mentions("read @mlink.txt", tmp)
    check(#sfiles == 0 and not sesc:find("outside-mention-secret", 1, true), "@mention symlink escape is blocked")
  else
    check(true, "@mention symlink escape is blocked (skipped: no symlink support)")
  end
end

-- 10. usage ledger + dashboard ------------------------------------------------------

section("usage")
do
  local usage = require("advantage.usage")
  check(usage._sparkline({ 0, 0, 0 }) == "▁▁▁", "sparkline handles all-zero weeks")
  check(vim.fn.strchars(usage._sparkline({ 1, 5, 10 })) == 3, "sparkline renders one cell per day")

  usage.record({ provider = "fake", id = "test-model" }, 111, 22)
  local st = usage.stats()
  check(st.today.total >= 133 and st.today.requests >= 1, "recorded usage aggregates into today")
  check(#st.days == 7, "seven day buckets")

  local ok, lines = pcall(usage.dashboard_lines, { input = 10, output = 5 })
  local joined = ok and table.concat(lines, "\n") or ""
  check(ok and joined:find("today", 1, true) and joined:find("pace", 1, true), "dashboard renders")
end

-- 11. yolo / deny with comment / review ---------------------------------------------

section("yolo · deny+comment · review")
do
  local providers = require("advantage.providers")
  local config = require("advantage.config")
  local chat = require("advantage.ui.chat")
  local agent_mod = require("advantage.agent")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")

  -- provider that asks to write one file, then finishes
  local function file_writer(path)
    local t = 0
    return {
      stream = function(req)
        t = t + 1
        vim.defer_fn(function()
          if t == 1 then
            req.on.tool_start("w1", "write_file")
            req.on.usage(10, 5)
            req.on.complete({
              { type = "tool_use", id = "w1", name = "write_file", input = { path = path, content = "yolo file\n" } },
            }, "tool_use", { input = 10, output = 5 })
          else
            req.on.text("done")
            req.on.usage(5, 2)
            req.on.complete({ { type = "text", text = "done" } }, "end_turn", { input = 5, output = 2 })
          end
        end, 10)
        return { stop = function() end }
      end,
    }
  end

  local orig_confirm = chat.confirm
  local confirm_called = false
  ---@diagnostic disable-next-line: duplicate-set-field
  chat.confirm = function(_, cb)
    confirm_called = true
    cb("deny")
  end

  -- yolo: write_file is NOT auto-approved, but must run without a card
  providers.register("fakeyolo", file_writer(tmp .. "/yolo.txt"))
  config.options.tools.yolo = true
  local ag = agent_mod.new({ model = { provider = "fakeyolo", id = "m", label = "m" } })
  ag.ctx.cwd = tmp -- targets live in tmp; containment scopes tools to ctx.cwd
  ag:send("write it")
  vim.wait(5000, function()
    return ag.status == "idle"
  end, 10)
  check(not confirm_called, "yolo skips the permission card")
  check(vim.fn.filereadable(tmp .. "/yolo.txt") == 1, "tool executed under yolo")
  check(ag.snapshots[vim.fs.normalize(tmp .. "/yolo.txt")] == false, "new-file snapshot recorded")
  config.options.tools.yolo = false

  local items = require("advantage.review")._changes(ag)
  check(
    #items == 1 and items[1].new and items[1].after:find("yolo file", 1, true) ~= nil,
    "review collects the agent's change"
  )

  -- deny with comment: feedback must reach the tool_result
  providers.register("fakedeny", file_writer(tmp .. "/deny.txt"))
  ---@diagnostic disable-next-line: duplicate-set-field
  chat.confirm = function(_, cb)
    cb("deny", "use a different name")
  end
  local ag2 = agent_mod.new({ model = { provider = "fakedeny", id = "m", label = "m" } })
  ag2.ctx.cwd = tmp
  ag2:send("write it")
  vim.wait(5000, function()
    return ag2.status == "idle"
  end, 10)
  chat.confirm = orig_confirm
  check(vim.fn.filereadable(tmp .. "/deny.txt") == 0, "denied tool did not run")
  local forwarded = false
  for _, msg in ipairs(ag2.messages) do
    for _, b in ipairs(msg.content) do
      if
        b.type == "tool_result"
        and type(b.content) == "string"
        and b.content:find("use a different name", 1, true)
      then
        forwarded = true
      end
    end
  end
  check(forwarded, "deny comment forwarded to the model")
end

-- 12. repo memory / skills harness --------------------------------------------

section("repo memory / skills harness")
do
  local memory = require("advantage.memory")
  local config = require("advantage.config")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  memory._root_override = tmp -- keep the real repo's .advantage/ untouched
  config.options.memory = { enabled = true, budget_tokens = 1200, project_budget_tokens = 2000, dedupe_threshold = 0.8 }

  -- remember + deterministic dedup
  local r1 = memory.remember("The SSE parser lives in util.lua and splits on double newlines", "Architecture")
  check(r1.status == "added" and r1.section == "Architecture", "remember stores a fact under a section")
  local r2 = memory.remember("SSE parser lives in util.lua and splits on double newlines", "Architecture")
  check(r2.status == "duplicate" or r2.status == "updated", "near-duplicate fact is not stored twice")
  memory.remember("Run tests with nvim -l tests/smoke.lua", "Commands")

  local block = memory.render()
  check(
    block:find("SSE parser", 1, true) and block:find("nvim -l tests/smoke.lua", 1, true),
    "learned facts render into the system-prompt block"
  )

  -- skills: index always known, body only on demand
  check(
    memory.save_skill(
      "run-tests",
      "How to run the offline test suite",
      "1. Run `nvim -l tests/smoke.lua`\n2. Every check must print ok"
    ),
    "save_skill writes a skill"
  )
  local in_index = false
  for _, s in ipairs(memory.skills_index()) do
    if s.name == "run-tests" then in_index = true end
  end
  check(in_index, "skill appears in the index")
  local body, desc = memory.use_skill("run-tests")
  check(
    body and body:find("smoke.lua", 1, true) and desc and desc:find("offline", 1, true),
    "use_skill loads the full body on demand"
  )
  check(memory.render():find("run-tests:", 1, true) ~= nil, "skill index (name: description) is injected")
  check(
    memory.render():find("Every check must print ok", 1, true) == nil,
    "skill BODY stays out of the always-on context"
  )

  -- Cross-harness skill discovery: Open Agent Skills / Codex uses
  -- .agents/skills. Explicit-only metadata must suppress automatic hints, and
  -- relative resources need an unambiguous base directory when loaded.
  local portable_dir = tmp .. "/.agents/skills/portable-release"
  vim.fn.mkdir(portable_dir .. "/agents", "p")
  vim.fn.writefile({ "release checklist" }, portable_dir .. "/reference.md")
  vim.fn.writefile({
    "---",
    "name: portable-release",
    "description: Prepare a portable release checklist",
    "advantage-harness: high",
    "---",
    "",
    "Read [reference.md](reference.md), then prepare the release.",
  }, portable_dir .. "/SKILL.md")
  vim.fn.writefile({ "policy:", "  allow_implicit_invocation: false" }, portable_dir .. "/agents/openai.yaml")
  local portable
  for _, skill in ipairs(memory.skills_index()) do
    if skill.name == "portable-release" then portable = skill end
  end
  check(portable and portable.implicit == false, ".agents/skills is discovered with explicit-only metadata")
  memory.reset_session()
  local hinted_portable = false
  for _, skill in ipairs(memory.skill_hints("prepare the portable release checklist")) do
    if skill.name == "portable-release" then hinted_portable = true end
  end
  check(not hinted_portable, "explicit-only skills never auto-surface from prompt matching")
  local portable_body, _, portable_meta = memory.use_skill("portable-release")
  check(
    portable_body and portable_meta and portable_meta.dir == portable_dir,
    "loaded skills retain their directory for relative references"
  )
  local refreshed, skill_result = false, nil
  config.options.memory.allow_skill_harness = true
  require("advantage.tools").get("use_skill").run({ name = "portable-release" }, {
    cwd = tmp,
    start_cwd = tmp,
    agent = {
      harness_mode = "low",
      refresh_prompt_policy = function(self)
        refreshed = self.harness_mode == "high"
      end,
    },
  }, function(out)
    skill_result = out
  end)
  check(refreshed, "opt-in skill frontmatter can activate a registered harness mode")
  check(
    skill_result and skill_result:find(".agents/skills/portable-release", 1, true),
    "use_skill reports the base directory for bundled references and scripts"
  )
  config.options.memory.allow_skill_harness = false

  -- verify: flag facts whose path anchor is gone, keep ones that resolve
  vim.fn.writefile({ "x" }, tmp .. "/real_file.lua")
  memory.remember("Config defaults live in real_file.lua at the repo root", "Architecture")
  memory.remember("Deprecated helper is in ghost/gone.lua", "Notes")
  local stale, ghost_hit, real_ok = memory.verify(), false, true
  for _, s in ipairs(stale) do
    if s.missing:find("ghost/gone.lua", 1, true) then ghost_hit = true end
    if s.missing:find("real_file.lua", 1, true) then real_ok = false end
  end
  check(ghost_hit and real_ok, "verify flags only facts whose referenced path is missing")

  -- verify precision: word/word prose is not a path, and a module-relative
  -- suffix that resolves deeper in the tree must not be flagged stale
  vim.fn.mkdir(tmp .. "/lua/pkg/tools", "p")
  vim.fn.writefile({ "x" }, tmp .. "/lua/pkg/tools/init.lua")
  memory.remember("Guarded by tools/init.lua and split on speed-limit/speed-time race/clobber", "Gotchas")
  local vp_prose, vp_suffix = true, true
  for _, s in ipairs(memory.verify()) do
    if s.missing:find("speed", 1, true) or s.missing:find("clobber", 1, true) then vp_prose = false end
    if s.missing:find("tools/init.lua", 1, true) then vp_suffix = false end
  end
  check(vp_prose, "verify ignores word/word prose that isn't a real path")
  check(vp_suffix, "verify resolves a module-relative path suffix deeper in the tree")
  memory.forget("Guarded by tools/init.lua")

  -- budget: learned block can never bloat context
  config.options.memory.budget_tokens = 30
  for i = 1, 12 do
    memory.remember(("Filler note %d about widget subsystem alpha beta gamma"):format(i), "Notes")
  end
  check(#memory.render() < 3000, "token budget keeps the learned block bounded")

  -- forget (curation)
  config.options.memory.budget_tokens = 1200
  memory.remember("A very specific forgettable marker phrase qxz", "Notes")
  check(memory.forget("forgettable marker phrase qxz") >= 1, "forget removes matching facts")

  -- curation signal: a verbose bullet is flagged (depth belongs in a skill), and
  -- the remember result carries the signal so the model can act on it.
  config.options.memory.budget_tokens = 2000
  local long_fact = "The widget rendering pipeline resolves layout in three stages: measure computes intrinsic sizes bottom-up, "
    .. "arrange positions children top-down within the measured bounds it received, and paint emits draw ops in order while "
    .. "respecting the active clip stack and the per-node z-order established during arrange"
  local rv = memory.remember(long_fact, "Architecture")
  check(rv.status == "added" and (rv.verbose_count or 0) >= 1, "remember flags a verbose bullet in its result")
  local advice = memory.curation_advice()
  check(
    advice.verbose_count >= 1 and advice.verbose[1].len >= 240,
    "curation_advice reports verbose bullets and their length"
  )
  check(type(advice.utilization) == "number" and advice.used_tokens > 0, "curation_advice reports utilization")
  -- redundancy is the real curate signal: near-duplicate pairs (below the auto-
  -- dedupe cut) are counted deterministically so curation targets overlap, not length
  memory.remember("The alpha widget cache warms eagerly on startup for fast dispatch", "Architecture")
  memory.remember("Alpha widget cache is warmed eagerly at startup so dispatch stays fast", "Architecture")
  check((memory.curation_advice().redundant_pairs or 0) >= 1, "curation_advice counts near-duplicate (redundant) pairs")
  memory.forget("alpha widget cache")
  memory.forget("widget rendering pipeline resolves layout")

  -- recurring record nudge: as a session does work without recording, the model
  -- gets an in-band steer every RECORD_NUDGE_EVERY (8) work actions; recording a
  -- fact resets the window and buys quiet.
  memory.reset_session()
  local fired = 0
  for _ = 1, 8 do
    memory.note_work()
    if memory.record_nudge_suffix() ~= "" then fired = fired + 1 end
  end
  check(fired == 1, "record nudge fires once after 8 work actions with nothing recorded")
  check(memory.record_nudge_suffix() == "", "record nudge stays quiet until the window fills again")
  for _ = 1, 8 do
    memory.note_work()
  end
  check(memory.record_nudge_suffix() ~= "", "record nudge recurs when work keeps piling up unrecorded")
  memory.remember("A durable fact recorded mid-session to reset the nudge window", "Notes")
  for _ = 1, 8 do
    memory.note_work()
  end
  check(memory.record_nudge_suffix() == "", "recording a fact resets the window so the nudge goes quiet")
  memory.forget("durable fact recorded mid-session")
  memory.reset_session()

  -- skills index is budgeted: past the cap, skills drop off the always-loaded
  -- list (with a "+N more" note) but stay fully loadable by name.
  config.options.memory.skills_index_budget_tokens = 1 -- force truncation to 1 shown
  for _, nm in ipairs({ "alpha-flow", "beta-flow", "gamma-flow" }) do
    memory.save_skill(nm, "trigger for " .. nm, "step one\nstep two\nstep three")
  end
  local idx_block = memory.render()
  check(idx_block:find("more skill", 1, true) ~= nil, "skills index truncates with a '+N more' note under its budget")
  local loadable = select(1, memory.use_skill("gamma-flow"))
  check(loadable and loadable:find("step two", 1, true), "a skill dropped from the index is still loadable by name")
  local all_indexed = 0
  for _, s in ipairs(memory.skills_index()) do
    if s.name:find("-flow") then all_indexed = all_indexed + 1 end
  end
  check(all_indexed == 3, "all skills remain in the full index / hintable regardless of the display cap")
  config.options.memory.skills_index_budget_tokens = 1200

  -- Repo-controlled runbooks are indexed from bounded frontmatter and their
  -- bodies are capped before entering the model-visible tool result.
  config.options.memory.skill_body_budget_tokens = 256 -- 1 KiB body cap
  local oversized_dir = tmp .. "/.advantage/skills/oversized"
  vim.fn.mkdir(oversized_dir, "p")
  vim.fn.writefile({
    "---",
    "name: oversized",
    "description: deliberately large external skill",
    "---",
    "",
    string.rep("body-data ", 800),
  }, oversized_dir .. "/SKILL.md")
  local oversized = select(1, memory.use_skill("oversized"))
  check(
    oversized and #oversized <= 1024 and oversized:find("skill body truncated", 1, true) ~= nil,
    "use_skill caps an oversized repo-controlled body before transcript injection"
  )
  local saved_large, large_err = memory.save_skill("too-large", "too large", string.rep("x", 1100))
  check(
    not saved_large and tostring(large_err):find("safety limit", 1, true),
    "save_skill rejects a body beyond its load budget"
  )
  vim.fn.delete(oversized_dir, "rf")
  config.options.memory.skill_body_budget_tokens = nil

  -- Import expansion reads a repeated file once and does not duplicate its full
  -- contents into the always-loaded prompt block.
  vim.fn.writefile({ "shared project guidance" }, tmp .. "/shared.md")
  vim.fn.writefile({ "@shared.md", "@shared.md" }, tmp .. "/AGENTS.md")
  local imported = memory.render()
  check(imported:find("shared project guidance", 1, true) ~= nil, "project memory expands a contained @import")
  check(imported:find("duplicate @shared.md omitted", 1, true) ~= nil, "project memory deduplicates repeated @imports")
  vim.fn.delete(tmp .. "/AGENTS.md")
  vim.fn.delete(tmp .. "/shared.md")

  -- gated off injects nothing
  config.options.memory.enabled = false
  check(memory.render() == "", "disabled memory injects nothing")
  check(#require("advantage.tools").schemas() > 0, "tool schemas still present with memory off")
  local names = {}
  for _, t in ipairs(require("advantage.tools").schemas()) do
    names[t.name] = true
  end
  check(not names.remember, "memory tools are hidden from the schema when disabled")
  config.options.memory.enabled = true
  memory._root_override = MEMTMP
end

-- 13. parallel sub-agent fan-out ----------------------------------------------

section("parallel sub-agents")
do
  local providers = require("advantage.providers")
  local agent_mod = require("advantage.agent")

  local sub_started, concurrent, max_concurrent = 0, 0, 0
  providers.register("fakesubpar", {
    stream = function(req)
      sub_started = sub_started + 1
      concurrent = concurrent + 1
      max_concurrent = math.max(max_concurrent, concurrent)
      local prompt = req.messages[1].content[1].text
      vim.defer_fn(function()
        concurrent = concurrent - 1
        req.on.complete({ { type = "text", text = "sub-report: " .. prompt } }, "end_turn")
      end, 30)
      return { stop = function() end }
    end,
  })

  local pturn, final_results, requested_parallel = 0, nil, nil
  local fanout_size = 13 -- exceeds both removed legacy caps (8/batch, 12/turn)
  providers.register("fakepar", {
    stream = function(req)
      pturn = pturn + 1
      if pturn == 1 then requested_parallel = req.parallel_tool_calls end
      vim.defer_fn(function()
        if pturn == 1 then
          local calls = {}
          for i = 1, fanout_size do
            calls[i] = {
              type = "tool_use",
              id = "s" .. i,
              name = "sub_agent",
              input = { prompt = "investigation " .. i, model = "fakesubpar/m", effort = "medium" },
            }
          end
          req.on.complete(calls, "tool_use")
        else
          for _, m in ipairs(req.messages) do
            if m.role == "user" then
              local trs = {}
              for _, b in ipairs(m.content) do
                if b.type == "tool_result" then trs[#trs + 1] = b end
              end
              if #trs == fanout_size then final_results = trs end
            end
          end
          req.on.complete({ { type = "text", text = "all done" } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })

  local chat = require("advantage.ui.chat")
  local original_tool_update = chat.tool_update
  local direct_progress_detail = nil
  chat.tool_update = function(id, patch)
    if id == "s1" and patch and tostring(patch.detail):find("request 1/6", 1, true) then
      direct_progress_detail = patch.detail
    end
    return original_tool_update(id, patch)
  end
  local ag = agent_mod.new({ model = { provider = "fakepar", id = "m", label = "par" } })
  ag:send("fan out")
  vim.wait(6000, function()
    return pturn >= 2 and final_results ~= nil
  end, 10)
  chat.tool_update = original_tool_update

  check(sub_started == fanout_size, "every requested sub-agent runs without batch or cumulative rejection")
  check(requested_parallel == true, "main-agent provider request permits parallel tool calls")
  check(max_concurrent >= 2, "sub-agents overlapped instead of running one-at-a-time")
  check(
    max_concurrent <= ag:harness_policy().max_parallel,
    "max_parallel bounds concurrent streams while excess scouts wait in the queue"
  )
  check(final_results and #final_results == fanout_size, "all queued tool_results merge into one user turn")
  local ids = {}
  for _, tr in ipairs(final_results or {}) do
    ids[tr.tool_use_id] = true
  end
  local all_ids = true
  for i = 1, fanout_size do
    all_ids = all_ids and ids["s" .. i]
  end
  check(all_ids, "each queued sub_agent call got its matching tool_result")
  check(
    direct_progress_detail and direct_progress_detail:find("Fakesubpar · fakesubpar/m/medium · request 1/6", 1, true),
    "direct same-response scout rows show provider, route/effort, and live request progress"
  )

  -- Exact initialization policy: a model may include `model = ""` on every
  -- scout. Reject all four before provider startup so the parent must make an
  -- explicit model choice rather than silently running unintended workers.
  local empty_parent_turn, empty_scouts, empty_batch_results = 0, 0, nil
  providers.register("fakeemptybatch", {
    stream = function(req)
      local is_scout = req.system and req.system:find("read%-only sub%-agent") ~= nil
      vim.defer_fn(function()
        if is_scout then
          empty_scouts = empty_scouts + 1
          req.on.complete({ { type = "text", text = "inherited-model report" } }, "end_turn")
          return
        end
        empty_parent_turn = empty_parent_turn + 1
        if empty_parent_turn == 1 then
          local calls = {}
          for i = 1, 4 do
            calls[i] = {
              type = "tool_use",
              id = "e" .. i,
              name = "sub_agent",
              input = { prompt = "empty override " .. i, model = "", effort = "" },
            }
          end
          req.on.complete(calls, "tool_use")
        else
          for _, m in ipairs(req.messages) do
            if m.role == "user" then
              local found = {}
              for _, b in ipairs(m.content) do
                if b.type == "tool_result" then found[#found + 1] = b end
              end
              if #found == 4 then empty_batch_results = found end
            end
          end
          req.on.complete({ { type = "text", text = "empty batch done" } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })
  local empty_agent = agent_mod.new({
    model = { provider = "fakeemptybatch", id = "parent", label = "empty batch" },
    harness_mode = "ultra",
  })
  empty_agent:send("fan out with empty optional model fields")
  vim.wait(6000, function()
    return empty_parent_turn >= 2 and empty_batch_results ~= nil
  end, 10)
  local all_model_errors = empty_batch_results and #empty_batch_results == 4
  for _, result_item in ipairs(empty_batch_results or {}) do
    local content = tostring(result_item.content)
    all_model_errors = all_model_errors
      and result_item.is_error == true
      and (content:find("input.model", 1, true) ~= nil or content:find("input.effort", 1, true) ~= nil)
  end
  check(empty_scouts == 0 and all_model_errors, "four blank-intent scouts are rejected before provider startup")

  -- Low harness mode keeps provider multi-call support (so batching remains
  -- available) but executes scout results sequentially by policy.
  sub_started, concurrent, max_concurrent = 0, 0, 0
  local low_turn, low_results, low_requested_parallel = 0, nil, nil
  providers.register("fakeparlow", {
    stream = function(req)
      low_turn = low_turn + 1
      if low_turn == 1 then low_requested_parallel = req.parallel_tool_calls end
      vim.defer_fn(function()
        if low_turn == 1 then
          req.on.complete({
            {
              type = "tool_use",
              id = "l1",
              name = "sub_agent",
              input = { prompt = "one", model = "fakesubpar/m", effort = "medium" },
            },
            {
              type = "tool_use",
              id = "l2",
              name = "sub_agent",
              input = { prompt = "two", model = "fakesubpar/m", effort = "medium" },
            },
          }, "tool_use")
        else
          for _, m in ipairs(req.messages) do
            if m.role == "user" then
              local found = {}
              for _, b in ipairs(m.content) do
                if b.type == "tool_result" then found[#found + 1] = b end
              end
              if #found == 2 then low_results = found end
            end
          end
          req.on.complete({ { type = "text", text = "low done" } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })
  local low_agent = agent_mod.new({
    model = { provider = "fakeparlow", id = "m", label = "low" },
    harness_mode = "low",
  })
  low_agent:send("batch but execute sequentially")
  vim.wait(6000, function()
    return low_turn >= 2 and low_results ~= nil
  end, 10)
  check(low_requested_parallel == true, "low harness keeps provider multi-call batching available")
  check(max_concurrent == 1 and low_results and #low_results == 2, "low harness executes sub-agents sequentially")

  -- mixed batch: a leading todo_write must not demote the trailing sub_agents
  -- to one-at-a-time (plan first, then fan out — the canonical agent pattern)
  sub_started, concurrent, max_concurrent = 0, 0, 0
  local mturn, mixed_results = 0, nil
  providers.register("fakemix", {
    stream = function(req)
      mturn = mturn + 1
      vim.defer_fn(function()
        if mturn == 1 then
          req.on.complete({
            {
              type = "tool_use",
              id = "t0",
              name = "todo_write",
              input = {
                items = {
                  { content = "plan", status = "in_progress" },
                  { content = "fan out", status = "pending" },
                },
              },
            },
            {
              type = "tool_use",
              id = "m1",
              name = "sub_agent",
              input = { prompt = "delta", model = "fakesubpar/m", effort = "medium" },
            },
            {
              type = "tool_use",
              id = "m2",
              name = "sub_agent",
              input = { prompt = "epsilon", model = "fakesubpar/m", effort = "medium" },
            },
          }, "tool_use")
        else
          for _, m in ipairs(req.messages) do
            if m.role == "user" then
              local trs = {}
              for _, b in ipairs(m.content) do
                if b.type == "tool_result" then trs[#trs + 1] = b end
              end
              if #trs == 3 then mixed_results = trs end
            end
          end
          req.on.complete({ { type = "text", text = "mixed done" } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })

  local ag2 = agent_mod.new({ model = { provider = "fakemix", id = "m", label = "mix" } })
  ag2:send("plan then fan out")
  vim.wait(6000, function()
    return mturn >= 2 and mixed_results ~= nil
  end, 10)

  check(sub_started == 2, "mixed batch: both trailing sub-agents ran")
  check(max_concurrent >= 2, "mixed batch: sub-agents after todo_write still overlap")
  check(
    mixed_results ~= nil and #mixed_results == 3 and mixed_results[1].tool_use_id == "t0",
    "mixed batch: todo_write result leads the merged reply, fan-out results follow"
  )

  -- Regression: providers may place a safe ordinary lookup *after* a leading
  -- scout wave in the same response. The scheduler must fan out that contiguous
  -- scout prefix once, then run the ordinary tail, without reordering or
  -- duplicating any function_call_output blocks.
  local function run_leading_scout_prefix(provider_name, id_prefix)
    local state = { turn = 0, results = nil }
    providers.register(provider_name, {
      stream = function(req)
        state.turn = state.turn + 1
        local turn = state.turn
        vim.defer_fn(function()
          if turn == 1 then
            req.on.complete({
              {
                type = "tool_use",
                id = id_prefix .. "1",
                name = "sub_agent",
                input = { prompt = id_prefix .. " scout one", model = "fakesubpar/m", effort = "medium" },
              },
              {
                type = "tool_use",
                id = id_prefix .. "2",
                name = "sub_agent",
                input = { prompt = id_prefix .. " scout two", model = "fakesubpar/m", effort = "medium" },
              },
              {
                type = "tool_use",
                id = id_prefix .. "3",
                name = "sub_agent",
                input = { prompt = id_prefix .. " scout three", model = "fakesubpar/m", effort = "medium" },
              },
              {
                type = "tool_use",
                id = id_prefix .. "tail",
                name = "list_dir",
                input = { path = "." },
              },
            }, "tool_use")
          else
            for _, message in ipairs(req.messages or {}) do
              if message.role == "user" then
                local results = {}
                for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
                  if block.type == "tool_result" then results[#results + 1] = block end
                end
                if #results == 4 then state.results = results end
              end
            end
            req.on.complete({ { type = "text", text = "leading scout prefix done" } }, "end_turn")
          end
        end, 10)
        return { stop = function() end }
      end,
    })
    local ag = agent_mod.new({
      model = { provider = provider_name, id = "m", label = provider_name },
      harness_mode = "ultra",
    })
    ag:send("run a leading scout prefix and then inspect the directory")
    vim.wait(6000, function()
      return state.turn >= 2 and state.results ~= nil and ag.status == "idle"
    end, 10)
    return state
  end

  sub_started, concurrent, max_concurrent = 0, 0, 0
  local leading = run_leading_scout_prefix("fakeleadingscouts", "lead-")
  local leading_ordered = leading.results and #leading.results == 4
  for i, expected in ipairs({ "lead-1", "lead-2", "lead-3", "lead-tail" }) do
    leading_ordered = leading_ordered and leading.results[i].tool_use_id == expected
  end
  check(
    sub_started == 3 and max_concurrent >= 2,
    "leading sub-agent prefix runs exactly once and overlaps before a trailing ordinary tool"
  )
  check(leading_ordered, "leading scout results and the ordinary tail preserve exact call order")

  local config = require("advantage.config")
  local saved_parallel = config.options.subagents.parallel
  config.options.subagents.parallel = false
  sub_started, concurrent, max_concurrent = 0, 0, 0
  local serial_leading = run_leading_scout_prefix("fakeleadingscoutsserial", "serial-")
  config.options.subagents.parallel = saved_parallel
  local serial_ordered = serial_leading.results and #serial_leading.results == 4
  for i, expected in ipairs({ "serial-1", "serial-2", "serial-3", "serial-tail" }) do
    serial_ordered = serial_ordered and serial_leading.results[i].tool_use_id == expected
  end
  check(
    sub_started == 3 and max_concurrent == 1 and serial_ordered,
    "global parallel=false runs the same leading scout prefix serially without reordering"
  )
end

-- 14. cache-aware usage reporting ---------------------------------------------

section("cache-aware usage")
do
  local usage = require("advantage.usage")
  usage._ledger_override = vim.fn.tempname() .. "-cache.jsonl"
  usage.record({ provider = "anthropic", id = "claude" }, 1000, 50, 800)
  local st = usage.stats(os.time())
  check(st.today.cached == 800, "ledger records the cached portion of input tokens")
  local txt = table.concat(usage.dashboard_lines(), "\n")
  check(txt:find("cached", 1, true) ~= nil, "dashboard surfaces cache savings")
end

-- 15. repeated compaction preserves oldest history ----------------------------

section("repeated compaction")
do
  local compact = require("advantage.compact")
  local msgs = {}
  for i = 1, 30 do
    msgs[#msgs + 1] = {
      role = i % 2 == 0 and "assistant" or "user",
      content = { { type = "text", text = ("OLDEST-MARKER-%02d "):format(i) .. string.rep("y", 200) } },
    }
  end
  local once = select(1, compact.force(msgs, { keep_recent_messages = 4, summary_max_chars = 4000 }))
  check(once[1].content[1].text:find("OLDEST-MARKER-01", 1, true) ~= nil, "first compaction keeps the oldest marker")
  -- age in more turns and compact again; the oldest marker must survive
  for i = 31, 50 do
    once[#once + 1] = {
      role = i % 2 == 0 and "assistant" or "user",
      content = { { type = "text", text = ("NEW-%02d "):format(i) .. string.rep("z", 200) } },
    }
  end
  local twice = select(1, compact.force(once, { keep_recent_messages = 4, summary_max_chars = 4000 }))
  check(
    twice[1].content[1].text:find("OLDEST-MARKER-01", 1, true) ~= nil,
    "second compaction still preserves the oldest history (no destructive re-truncation)"
  )
end

-- Explicit sub_agent_batch orchestration lets the model choose parallel or
-- sequential execution without relying on same-response tool-call grouping.
section("explicit sub-agent batches")
do
  local providers = require("advantage.providers")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local active, peak = 0, 0
  providers.register("fakebatch", {
    stream = function(req)
      active = active + 1
      peak = math.max(peak, active)
      vim.defer_fn(function()
        active = active - 1
        req.on.complete({ { type = "text", text = "batch scout report" } }, "end_turn")
      end, 20)
      return { stop = function() end }
    end,
  })
  local function run_batch(mode, ctx)
    local done, out, err = false, nil, nil
    tools.get("sub_agent_batch").run(
      {
        mode = mode,
        tasks = {
          { prompt = "one", model = "fakebatch/model", effort = "medium", max_turns = 2 },
          { prompt = "two", model = "fakebatch/model", effort = "medium", max_turns = 2 },
          { prompt = "three", model = "fakebatch/model", effort = "medium", max_turns = 2 },
        },
      },
      ctx or { cwd = vim.fn.getcwd() },
      function(result, is_error)
        out, err, done = result, is_error, true
      end
    )
    vim.wait(5000, function()
      return done
    end, 10)
    return out, err
  end
  local _, parallel_err = run_batch("parallel")
  check(parallel_err == false and peak >= 2, "explicit parallel batch overlaps scouts")
  peak = 0
  local _, sequential_err = run_batch("sequential")
  check(sequential_err == false and peak == 1, "explicit sequential batch runs one scout at a time")

  peak = 0
  local low_policy_err = select(
    2,
    run_batch("parallel", {
      cwd = vim.fn.getcwd(),
      agent = {
        harness_policy = function()
          return { parallel = false, max_parallel = 1 }
        end,
      },
    })
  )
  check(
    low_policy_err == false and peak == 1,
    "explicit parallel batch obeys a sequential Low harness policy instead of bypassing it"
  )

  local saved_parallel = config.options.subagents.parallel
  config.options.subagents.parallel = false
  peak = 0
  local disabled_parallel_err = select(2, run_batch("parallel"))
  config.options.subagents.parallel = saved_parallel
  check(
    disabled_parallel_err == false and peak == 1,
    "explicit parallel batch obeys the global subagents.parallel=false override"
  )

  local saved_width = config.options.subagents.max_parallel
  config.options.subagents.max_parallel = 2
  peak = 0
  local width_err = select(
    2,
    run_batch("parallel", {
      cwd = vim.fn.getcwd(),
      agent = {
        harness_policy = function()
          return { parallel = true, max_parallel = 8 }
        end,
      },
    })
  )
  config.options.subagents.max_parallel = saved_width
  check(width_err == false and peak == 2, "explicit parallel batch obeys the configured live concurrency width")

  local rendered_details = {}
  local fake_ui = {
    tool_begin = function() end,
    tool_update = function(_, update)
      if update and update.detail then rendered_details[#rendered_details + 1] = update.detail end
    end,
  }
  peak = 0
  local telemetry_err = select(
    2,
    run_batch("parallel", {
      cwd = vim.fn.getcwd(),
      agent = {
        harness_policy = function()
          return { parallel = true, max_parallel = 4 }
        end,
        ui = function()
          return fake_ui
        end,
      },
    })
  )
  local saw_request_progress = false
  for _, detail in ipairs(rendered_details) do
    if detail:find("Fakebatch · fakebatch/model/medium · request 1/2", 1, true) then saw_request_progress = true end
  end
  check(
    telemetry_err == false and saw_request_progress,
    "batch child rows distinguish provider, scout route, and live request progress"
  )
end

-- The harness policy is deliberately compact, so phase-transition reminders
-- ride tool-result turns instead of bloating every cached request. Exercise the
-- real parent loop here: scout fan-out -> bounded read-only confirmation -> edit
-- -> passing test -> repeated test -> later edit -> passing test -> repeated
-- test. Action and verification reminders are one-shot at their respective
-- phase boundaries, not one-shot forever.
section("orchestration phase guidance & cache identity")
do
  local config = require("advantage.config")
  local providers = require("advantage.providers")
  local agent_mod = require("advantage.agent")
  local tools = require("advantage.tools")
  local harness = require("advantage.harness")
  local saved_yolo = config.options.tools.yolo
  local saved_auto_compact = config.options.context.auto_compact
  config.options.tools.yolo = true
  config.options.context.auto_compact = false

  local function has_any(text, needles)
    text = tostring(text or ""):lower()
    for _, needle in ipairs(needles) do
      if text:find(needle, 1, true) then return true end
    end
    return false
  end

  local function has_all_concepts(text, concepts)
    for _, alternatives in ipairs(concepts) do
      if not has_any(text, alternatives) then return false end
    end
    return true
  end

  local base_discipline = agent_mod.base_system_prompt(vim.fn.getcwd())
  local commandment_titles = {
    "Write for humans first",
    "Keep units cohesive",
    "Express and enforce meaningful invariants",
    "Never hide failure",
    "Make data flow, ownership, and dependencies explicit",
    "Fit the design to the actual problem",
    "Verify changed behavior",
    "Avoid tight coupling; design clean boundaries",
    "Get the data model right first",
    "Keep changes scoped and compatible",
  }
  local commandment_cursor, commandments_ordered, numbered_lines = 1, true, 0
  for _, title in ipairs(commandment_titles) do
    local marker = ("%d. %s."):format(numbered_lines + 1, title)
    local found = base_discipline:find(marker, commandment_cursor, true)
    if not found then
      commandments_ordered = false
      break
    end
    commandment_cursor = found + #marker
    numbered_lines = numbered_lines + 1
  end
  local actual_numbered_lines = 0
  for line in base_discipline:gmatch("[^\n]+") do
    if line:match("^%d+%. ") then actual_numbered_lines = actual_numbered_lines + 1 end
  end
  check(
    commandments_ordered and numbered_lines == 10 and actual_numbered_lines == 10,
    "base instructions contain the ten engineering commandments exactly once and in priority order"
  )
  check(
    has_all_concepts(base_discipline, {
      { "narrowest", "smallest compatible", "minimal compatible" },
      { "compatib" },
      { "report" },
      { "evidence" },
      { "preserv" },
      { "contract", "existing test", "regression test" },
    }),
    "base instructions demand narrow compatible fixes and treat reports as evidence while preserving contracts"
  )
  check(
    has_all_concepts(base_discipline, {
      { "do not weaken", "never weaken", "don't weaken" },
      { "passing assertion", "passing test", "regression assertion" },
      { "green", "make the suite pass", "make tests pass" },
      { "hermetic", "self-contained test", "isolated test" },
    }),
    "base instructions forbid weakening passing assertions and require hermetic tests"
  )

  require("advantage.subagent")._reset_route_health()
  local saved_models = vim.deepcopy(config.options.models)
  local saved_aliases = vim.deepcopy(config.options.subagents.model_aliases)
  config.options.models[#config.options.models + 1] = { ref = "fakephase/parent", label = "phase parent" }
  config.options.subagents.model_aliases = config.options.subagents.model_aliases or {}
  config.options.subagents.model_aliases.phase_policy = "fakephase/parent"
  local delegation_discipline = harness.guide("ultra", { provider = "fakephase", id = "parent" })
  local proportional = delegation_discipline:lower()
  check(
    has_all_concepts(delegation_discipline, {
      { "reuse" },
      { "existing representation", "existing invariant" },
      { "behavioral coverage", "complete behavior" },
      { "not a comprehensive redesign", "do not prescribe a new data model" },
    }),
    "delegation guidance separates complete behavior from architectural breadth"
  )
  check(
    has_all_concepts(delegation_discipline, {
      { "one owner" },
      { "same response" },
      { "broad parent" },
      { "exact source", "precise span" },
      { "never re-read", "do not re-read" },
    }),
    "delegation guidance prevents additive parent discovery and ceremonial re-reads"
  )
  config.options.models = saved_models
  config.options.subagents.model_aliases = saved_aliases
  check(
    proportional:find("proportional", 1, true) ~= nil
      and proportional:find("simple", 1, true) ~= nil
      and proportional:find("complex", 1, true) ~= nil,
    "harness policy makes delegation explicitly proportional to task complexity"
  )
  check(
    proportional:find("self-contained", 1, true) ~= nil
      and (
        proportional:find("separate parent turn", 1, true) ~= nil
        or proportional:find("later parent turn", 1, true) ~= nil
      ),
    "sequential batch guidance reserves dependent scouts for separate parent turns"
  )

  local identity_root_a, identity_root_b = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.mkdir(identity_root_a, "p")
  vim.fn.mkdir(identity_root_b, "p")
  local identity_a1 = agent_mod.new({
    id = "same-persisted-conversation",
    model = { provider = "fakeidentity", id = "m", label = "identity" },
    cwd = identity_root_a,
  })
  local identity_a2 = agent_mod.new({
    id = "same-persisted-conversation",
    model = { provider = "fakeidentity", id = "m", label = "identity" },
    cwd = identity_root_a,
  })
  local identity_b = agent_mod.new({
    id = "same-persisted-conversation",
    model = { provider = "fakeidentity", id = "m", label = "identity" },
    cwd = identity_root_b,
  })
  check(
    identity_a1.request_key == identity_a2.request_key and identity_a1.request_key ~= identity_b.request_key,
    "request identity is stable for the same id/root and distinct across project roots"
  )

  local budget_prompts = {}
  providers.register("fakebudgetcap", {
    stream = function(req)
      budget_prompts[#budget_prompts + 1] = req.system
      vim.defer_fn(function()
        req.on.complete({ { type = "text", text = "budget captured" } }, "end_turn")
      end, 5)
      return { stop = function() end }
    end,
  })
  local function capture_budget(max_turns)
    local done = false
    local input = { prompt = "capture scout budget", model = "fakebudgetcap/m", effort = "medium" }
    if max_turns ~= nil then input.max_turns = max_turns end
    tools.get("sub_agent").run(input, { cwd = identity_root_a }, function()
      done = true
    end)
    vim.wait(3000, function()
      return done
    end, 10)
  end
  capture_budget(nil)
  capture_budget(99)
  check(
    config.options.subagents.max_turns == 6
      and config.options.subagents.max_turns_cap == 12
      and budget_prompts[1]
      and budget_prompts[1]:find("budget of about 6 turns", 1, true) ~= nil
      and budget_prompts[2]
      and budget_prompts[2]:find("budget of about 12 turns", 1, true) ~= nil,
    "scouts default to six turns while explicit requests are hard-capped at twelve"
  )
  check(
    has_all_concepts(budget_prompts[1], {
      { "root cause" },
      { "evidence" },
      { "minimal touch", "smallest touch", "minimal file", "minimal compatible" },
      { "preserv" },
      { "contract", "existing test" },
      { "focused" },
      { "case", "test" },
      { "optional" },
      { "hardening" },
      { "separate" },
    }),
    "scout report contract asks for cause, evidence, minimal touch set, preserved contracts, focused cases, and separate hardening"
  )
  check(
    has_all_concepts(budget_prompts[1], {
      { "concise", "tight" },
      { "900 words", "900-word", "under 900", "at most 900", "no more than 900", "about 900" },
      { "decisive evidence", "decisive findings", "decision-relevant evidence", "most relevant evidence" },
      { "minimal touch", "smallest touch", "minimal compatible" },
      { "do not include exhaustive", "avoid exhaustive", "not an exhaustive" },
      { "edge-case catalog", "edge case catalog", "edge-case inventory", "edge case inventory" },
      { "not a play-by-play", "no play-by-play", "avoid play-by-play" },
    }),
    "scout report contract is bounded near 900 words and prioritizes decisive evidence over exhaustive catalogs or play-by-play"
  )
  check(
    has_all_concepts(budget_prompts[1], {
      { "reuse" },
      { "existing representation", "existing invariant", "sentinel" },
      { "does not justify", "only when decisive evidence" },
      { "data-model redesign", "data model redesign" },
    }),
    "scouts prefer narrow reuse and require evidence before proposing a data-model redesign"
  )
  check(
    has_all_concepts(budget_prompts[1], {
      { "exact source", "precise span" },
      { "snippet", "span" },
      { "unambiguous" },
      { "truncated" },
      { "avoid re-reading", "avoid rereading" },
    }),
    "scouts return decisive semantic source so the parent need not retrieve it again"
  )

  local function guidance_texts(messages)
    local found = {}
    local function walk(value)
      if type(value) == "string" then
        if value:find("<harness-guidance>", 1, true) then found[#found + 1] = value end
      elseif type(value) == "table" then
        for _, child in pairs(value) do
          walk(child)
        end
      end
    end
    walk(messages)
    return found
  end

  local function tool_result_count(messages, id)
    local count = 0
    for _, message in ipairs(messages or {}) do
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "tool_result" and block.tool_use_id == id then count = count + 1 end
      end
    end
    return count
  end

  local function tool_result_failed(messages, id)
    for _, message in ipairs(messages or {}) do
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "tool_result" and block.tool_use_id == id then return block.is_error == true end
      end
    end
    return false
  end

  local function verification_reminders(messages)
    local found = {}
    for _, guidance in ipairs(guidance_texts(messages)) do
      if
        has_all_concepts(guidance, {
          { "verif" },
          { "completed", "passed", "succeeded", "successful" },
        })
      then
        found[#found + 1] = guidance
      end
    end
    return found
  end

  local function failed_verification_reminders(messages)
    local found = {}
    for _, guidance in ipairs(guidance_texts(messages)) do
      if
        has_all_concepts(guidance, {
          { "verif", "test command" },
          { "failed", "failure", "non-zero", "nonzero" },
          { "generation" },
        })
      then
        found[#found + 1] = guidance
      end
    end
    return found
  end

  local function action_checkpoint_reminders(messages)
    local found = {}
    for _, guidance in ipairs(guidance_texts(messages)) do
      if
        has_all_concepts(guidance, {
          { "confirmation", "investigation pass" },
          { "complete", "completed", "done" },
          { "narrowest", "smallest compatible", "minimal touch", "minimal compatible" },
          { "implement", "implementation" },
        })
      then
        found[#found + 1] = guidance
      end
    end
    return found
  end

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({
    vim.json.encode({
      scripts = {
        test = "node -e \"const fs=require('fs');const s=fs.readFileSync('phase.txt','utf8');if(!s.includes('phase'))process.exit(1)\"",
      },
    }),
  }, tmp .. "/package.json")
  local parent_turn = 0
  local phase_seen = {}
  local phase_messages = {}
  local scout_starts = {}
  providers.register("fakephase", {
    stream = function(req)
      local is_scout = req.system and req.system:find("You are a read-only sub-agent", 1, true) ~= nil
      if is_scout then
        local prompt = req.messages[1].content[1].text
        scout_starts[prompt] = (scout_starts[prompt] or 0) + 1
        vim.defer_fn(function()
          req.on.complete({ { type = "text", text = "report for " .. prompt } }, "end_turn")
        end, 5)
        return { stop = function() end }
      end

      parent_turn = parent_turn + 1
      local turn = parent_turn
      phase_seen[turn] = guidance_texts(req.messages)
      phase_messages[turn] = vim.deepcopy(req.messages)
      vim.defer_fn(function()
        if turn == 1 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-scout-1",
              name = "sub_agent",
              input = { prompt = "phase scout one", model = "fakephase/scout", effort = "medium" },
            },
            {
              type = "tool_use",
              id = "phase-scout-2",
              name = "sub_agent",
              input = { prompt = "phase scout two", model = "fakephase/scout", effort = "medium" },
            },
          }, "tool_use")
        elseif turn == 2 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-confirm-read",
              name = "read_file",
              input = { path = "package.json" },
            },
            {
              type = "tool_use",
              id = "phase-confirm-list",
              name = "list_dir",
              input = { path = "." },
            },
          }, "tool_use")
        elseif turn == 3 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-write-1",
              name = "write_file",
              input = { path = "phase.txt", content = "phase one\n" },
            },
          }, "tool_use")
        elseif turn == 4 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-test-1",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        elseif turn == 5 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-test-repeat-1",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        elseif turn == 6 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-write-2",
              name = "edit_file",
              input = { path = "phase.txt", old_string = "phase one", new_string = "phase two" },
            },
          }, "tool_use")
        elseif turn == 7 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-test-2",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        elseif turn == 8 then
          req.on.complete({
            {
              type = "tool_use",
              id = "phase-test-repeat-2",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        else
          req.on.complete({ { type = "text", text = "phase run complete" } }, "end_turn")
        end
      end, 5)
      return { stop = function() end }
    end,
  })

  local phase_agent = agent_mod.new({
    id = "phase-guidance-parent",
    model = { provider = "fakephase", id = "parent", label = "phase parent" },
    harness_mode = "ultra",
    cwd = tmp,
  })
  phase_agent:send("Use two parallel scouts, then implement and test the result")
  vim.wait(8000, function()
    return parent_turn >= 9 and phase_agent.status == "idle"
  end, 10)

  check(
    scout_starts["phase scout one"] == 1
      and scout_starts["phase scout two"] == 1
      and tool_result_count(phase_messages[2], "phase-scout-1") == 1
      and tool_result_count(phase_messages[2], "phase-scout-2") == 1,
    "same-response sub-agent tail calls execute and return exactly once each"
  )
  check(
    phase_seen[2]
      and #phase_seen[2] == 1
      and phase_seen[2][1]:lower():find("scout", 1, true) ~= nil
      and (
        phase_seen[2][1]:lower():find("synth", 1, true) ~= nil
        or phase_seen[2][1]:lower():find("reconcil", 1, true) ~= nil
      ),
    "first scout wave injects one model-visible synthesis reminder"
  )
  check(phase_seen[2] and has_all_concepts(phase_seen[2][1], {
    { "report" },
    { "evidence" },
    { "validat", "reconcil", "synth" },
  }), "scout-wave reminder treats reports as evidence to reconcile rather than implementation authority")
  check(phase_seen[2] and has_all_concepts(table.concat(phase_seen[2], "\n"), {
    { "original wording", "user's original", "user contract" },
    { "acceptance matrix", "behavior matrix", "regression matrix" },
    { "alias", "mode" },
    { "ordering", "placement", "boundary" },
    { "does not restrict", "not restrict", "unrestricted" },
    { "focused regression" },
    { "never the requested behavior", "not the requested behavior" },
  }), "post-scout synthesis preserves the full user contract across aliases and unrestricted input boundaries")
  check(phase_seen[2] and has_all_concepts(table.concat(phase_seen[2], "\n"), {
    { "exact semantic source", "precise span" },
    { "consume it directly" },
    { "ambiguity", "truncation" },
    { "do not repeat" },
    { "broad find", "broad survey" },
  }), "post-scout guidance consumes exact evidence without duplicating broad parent retrieval")
  check(
    phase_seen[3]
      and #phase_seen[3] == 2
      and tool_result_count(phase_messages[3], "phase-confirm-read") == 1
      and tool_result_count(phase_messages[3], "phase-confirm-list") == 1,
    "one bounded read-only confirmation batch completes before the first mutation"
  )
  local first_action_checkpoint = phase_seen[3] and action_checkpoint_reminders(phase_seen[3]) or {}
  check(#first_action_checkpoint == 1 and has_all_concepts(first_action_checkpoint[1], {
    { "stop expanding", "do not expand", "don't expand" },
    { "re-audit", "reaudit", "re-auditing", "re auditing" },
    { "narrowest", "smallest compatible", "minimal touch", "minimal compatible" },
    { "now", "next turn" },
  }), "completed confirmation pass stops expansion/re-auditing and requires the narrowest implementation next")
  local action_checkpoint_once = true
  for turn = 4, 9 do
    action_checkpoint_once = action_checkpoint_once
      and phase_seen[turn] ~= nil
      and #action_checkpoint_reminders(phase_seen[turn]) == 1
  end
  check(action_checkpoint_once, "the post-confirmation action checkpoint does not repeat on later parent turns")
  check(
    phase_seen[4]
      and #phase_seen[4] == 3
      and (phase_seen[4][3]:lower():find("edit", 1, true) ~= nil or phase_seen[4][3]:lower():find("mutation", 1, true) ~= nil)
      and (
        phase_seen[4][3]:lower():find("verif", 1, true) ~= nil
        or phase_seen[4][3]:lower():find("test", 1, true) ~= nil
      ),
    "first successful mutation injects one verification-phase reminder"
  )
  check(phase_seen[4] and has_all_concepts(phase_seen[4][3], {
    { "narrowest", "smallest compatible", "minimal compatible" },
    { "preserv" },
    { "contract", "existing test", "passing assertion" },
    { "do not weaken", "never weaken", "don't weaken" },
    { "green", "make the suite pass", "make tests pass" },
    { "hermetic", "self-contained test", "isolated test" },
  }), "mutation reminder keeps the fix compatible, preserves assertions, and requests hermetic regression coverage")
  check(
    phase_seen[4]
      and has_all_concepts(phase_seen[4][3], {
        { "greenfield", "stateful algorithm" },
        { "independent oracle", "reference model" },
        { "exact contract wording", "user contract" },
        { "scout inference", "report assumption" },
        { "every public mutation", "each public mutation" },
        { "boundary" },
        { "no-op", "noop" },
        { "composition", "composed" },
        { "canceling components", "cancelling components" },
        { "final value equals", "net equality" },
        { "operation metadata", "history", "version", "side effects" },
        { "wrong types", "wrong value types" },
        { "invalid values", "invalid value" },
        { "error classes", "error taxonomy" },
        { "overlap", "intersection" },
        { "most specific contract", "specific contract rule" },
        { "host-language convention", "language convention" },
        { "history" },
        { "invariant" },
        { "iteration count is not", "operation count is not" },
      }),
    "mutation reminder makes algorithmic self-tests cover semantic partitions instead of merely increasing random iterations"
  )
  check(
    phase_seen[5] and #verification_reminders(phase_seen[5]) == 1,
    "first passing verification emits one reminder for the first edit generation"
  )
  check(
    phase_seen[6] and #verification_reminders(phase_seen[6]) == 1,
    "repeating verification without another successful edit does not emit a duplicate reminder"
  )
  check(
    phase_seen[7] and #verification_reminders(phase_seen[7]) == 1,
    "a later successful edit opens a new verification generation but does not claim success early"
  )
  local second_generation_reminders = phase_seen[8] and verification_reminders(phase_seen[8]) or {}
  check(
    #second_generation_reminders == 2,
    "passing verification after a later successful edit emits a second generation reminder"
  )
  check(
    phase_seen[9] and #verification_reminders(phase_seen[9]) == 2,
    "repeated verification after the second edit generation remains reminder-free"
  )
  local final_verification = second_generation_reminders[#second_generation_reminders]
  check(
    has_all_concepts(final_verification, {
      { "diff" },
      { "audit", "review" },
      { "bounded", "single", "one" },
      { "read-only", "read only" },
      { "oracle", "reference model" },
      { "every stated contract partition", "all stated contract partitions" },
      { "canceling compositions", "cancelling compositions" },
      { "overlapping error-taxonomy", "overlapping error taxonomy", "overlapping error classes" },
      { "unstated assumption", "implementation-derived" },
      { "operation count", "iteration count" },
      { "do not mechanically restore", "do not restore", "do not reapply" },
      { "stop", "finish" },
    }),
    "successful-generation reminder audits the diff and contract coverage before stopping"
  )

  local guard_turn = 0
  providers.register("fakefinalguard", {
    stream = function(req)
      guard_turn = guard_turn + 1
      local turn = guard_turn
      vim.defer_fn(function()
        if turn == 1 then
          req.on.complete({
            {
              type = "tool_use",
              id = "final-guard-write",
              name = "write_file",
              input = { path = "guard.txt", content = "guard\n" },
            },
          }, "tool_use")
        elseif turn == 2 then
          req.on.complete({
            {
              type = "tool_use",
              id = "final-guard-test",
              name = "bash",
              input = { command = "npm test" },
            },
            {
              type = "tool_use",
              id = "final-guard-danger",
              name = "bash",
              input = { command = "git checkout -- guard.txt" },
            },
            {
              type = "tool_use",
              id = "final-guard-combined",
              name = "bash",
              input = { command = "npm test && git apply /tmp/rewrite.patch" },
            },
            {
              type = "tool_use",
              id = "final-guard-format-check",
              name = "bash",
              input = { command = "npm run format:check -- --check >/dev/null 2>&1 || true" },
            },
          }, "tool_use")
        else
          req.on.complete({ { type = "text", text = "guard complete" } }, "end_turn")
        end
      end, 5)
      return { stop = function() end }
    end,
  })
  local guard_agent = agent_mod.new({
    id = "final-audit-guard-parent",
    model = { provider = "fakefinalguard", id = "parent", label = "final guard" },
    cwd = tmp,
  })
  guard_agent:send("Make one change, verify it, then audit the final diff")
  vim.wait(5000, function()
    return guard_turn >= 3 and guard_agent.status == "idle"
  end, 10)
  local guarded_result, combined_result, format_check_result
  for _, message in ipairs(guard_agent.messages) do
    for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
      if block.type == "tool_result" and block.tool_use_id == "final-guard-danger" then guarded_result = block end
      if block.type == "tool_result" and block.tool_use_id == "final-guard-combined" then combined_result = block end
      if block.type == "tool_result" and block.tool_use_id == "final-guard-format-check" then
        format_check_result = block
      end
    end
  end
  check(
    guarded_result
      and guarded_result.is_error == true
      and guarded_result.content:find("Final audit is read-only", 1, true)
      and combined_result
      and combined_result.is_error == true
      and combined_result.content:find("Do not combine verification", 1, true)
      and format_check_result
      and format_check_result.is_error ~= true
      and vim.fn.readfile(tmp .. "/guard.txt")[1] == "guard",
    "final audit rejects same-batch mutations while allowing explicit formatter check mode"
  )

  vim.fn.writefile({ "before" }, tmp .. "/shell-only.txt")
  local shell_guard_turn = 0
  providers.register("fakeshellguard", {
    stream = function(req)
      shell_guard_turn = shell_guard_turn + 1
      local turn = shell_guard_turn
      vim.defer_fn(function()
        if turn == 1 then
          req.on.complete({
            {
              type = "tool_use",
              id = "shell-guard-edit",
              name = "bash",
              input = { command = "sed -i 's/before/after/' shell-only.txt" },
            },
          }, "tool_use")
        elseif turn == 2 then
          req.on.complete({
            {
              type = "tool_use",
              id = "shell-guard-test",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        elseif turn == 3 then
          req.on.complete({
            {
              type = "tool_use",
              id = "shell-guard-restore",
              name = "bash",
              input = { command = "git checkout -- shell-only.txt" },
            },
          }, "tool_use")
        else
          req.on.complete({ { type = "text", text = "shell guard complete" } }, "end_turn")
        end
      end, 5)
      return { stop = function() end }
    end,
  })
  local shell_guard_agent = agent_mod.new({
    id = "shell-only-final-audit-guard",
    model = { provider = "fakeshellguard", id = "parent", label = "shell guard" },
    cwd = tmp,
  })
  shell_guard_agent:send("Make a shell edit, verify it, and audit the result")
  vim.wait(5000, function()
    return shell_guard_turn >= 4 and shell_guard_agent.status == "idle"
  end, 10)
  local shell_restore_result
  for _, message in ipairs(shell_guard_agent.messages) do
    for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
      if block.type == "tool_result" and block.tool_use_id == "shell-guard-restore" then
        shell_restore_result = block
      end
    end
  end
  check(
    shell_restore_result
      and shell_restore_result.is_error == true
      and shell_restore_result.content:find("Final audit is read-only", 1, true)
      and vim.fn.readfile(tmp .. "/shell-only.txt")[1] == "after",
    "recognized shell-only mutations create and preserve a verified edit generation"
  )

  -- A red suite carries different evidence from a green one. The harness must
  -- surface that evidence once for the current edit generation, without
  -- declaring the generation verified or repeating the same warning forever.
  -- A later successful edit re-arms the warning because it may have introduced
  -- a distinct regression. The fixture owns all state and always fails on the
  -- deliberately written "broken" value, so it is independent of the host repo.
  local failure_tmp = vim.fn.tempname()
  vim.fn.mkdir(failure_tmp, "p")
  vim.fn.writefile({
    vim.json.encode({
      scripts = {
        test = "node -e \"const fs=require('fs');const s=fs.readFileSync('failure.txt','utf8');process.exit(s.includes('broken')?1:0)\"",
      },
    }),
  }, failure_tmp .. "/package.json")
  local failure_turn = 0
  local failure_seen = {}
  local failure_messages = {}
  providers.register("fakephasefailure", {
    stream = function(req)
      failure_turn = failure_turn + 1
      local turn = failure_turn
      failure_seen[turn] = guidance_texts(req.messages)
      failure_messages[turn] = vim.deepcopy(req.messages)
      vim.defer_fn(function()
        if turn == 1 then
          req.on.complete({
            {
              type = "tool_use",
              id = "failure-write-1",
              name = "write_file",
              input = { path = "failure.txt", content = "broken one\n" },
            },
          }, "tool_use")
        elseif turn == 2 then
          req.on.complete({
            {
              type = "tool_use",
              id = "failure-test-1",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        elseif turn == 3 then
          req.on.complete({
            {
              type = "tool_use",
              id = "failure-test-repeat-1",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        elseif turn == 4 then
          req.on.complete({
            {
              type = "tool_use",
              id = "failure-write-2",
              name = "edit_file",
              input = { path = "failure.txt", old_string = "broken one", new_string = "broken two" },
            },
          }, "tool_use")
        elseif turn == 5 then
          req.on.complete({
            {
              type = "tool_use",
              id = "failure-test-2",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        elseif turn == 6 then
          req.on.complete({
            {
              type = "tool_use",
              id = "failure-test-repeat-2",
              name = "bash",
              input = { command = "npm test" },
            },
          }, "tool_use")
        else
          req.on.complete({ { type = "text", text = "failed-verification run complete" } }, "end_turn")
        end
      end, 5)
      return { stop = function() end }
    end,
  })

  local failure_agent = agent_mod.new({
    id = "phase-failed-verification-parent",
    model = { provider = "fakephasefailure", id = "parent", label = "failed verification parent" },
    harness_mode = "ultra",
    cwd = failure_tmp,
  })
  failure_agent:send("Implement the fixture and run its deliberately failing regression suite")
  vim.wait(8000, function()
    return failure_turn >= 7 and failure_agent.status == "idle"
  end, 10)

  local first_failure = failure_seen[3] and failed_verification_reminders(failure_seen[3]) or {}
  check(
    tool_result_failed(failure_messages[3], "failure-test-1") and #first_failure == 1,
    "a failed verification after edits emits one failure reminder for that generation"
  )
  check(
    has_all_concepts(first_failure[1], {
      { "previously passing", "existing" },
      { "assertion", "test" },
      { "contract", "regression" },
      { "evidence" },
      { "fix the implementation", "implementation first" },
      { "do not weaken", "do not change", "don't weaken", "don't change" },
      { "green", "make the suite pass", "make tests pass" },
    }),
    "failed-verification guidance treats existing assertions as evidence and fixes implementation before tests"
  )
  check(
    failure_seen[4] and #failed_verification_reminders(failure_seen[4]) == 1,
    "repeating a failed verification without edits does not spam the same warning"
  )
  check(
    failure_seen[5] and #failed_verification_reminders(failure_seen[5]) == 1,
    "a later successful edit re-arms failed-verification guidance without firing before a test"
  )
  check(
    tool_result_failed(failure_messages[6], "failure-test-2") and #failed_verification_reminders(failure_seen[6]) == 2,
    "a failed verification after a later edit generation emits a second warning"
  )
  check(
    failure_seen[7] and #failed_verification_reminders(failure_seen[7]) == 2,
    "repeated failure in the second edit generation remains warning-free"
  )

  -- Cache identity has two separate jobs: the cache key names reusable static
  -- prompt bytes, while the session id identifies one live conversation. Equal
  -- parent prefixes and equal scout prefixes should therefore reuse keys without
  -- ever sharing a session id. Scouts deliberately spread identical prefixes
  -- across a tiny deterministic bucket set to avoid one provider hot key.
  local captured = { parent = {}, scout = {} }
  local scout_rounds = {}
  providers.register("fakecacheidentity", {
    stream = function(req)
      local kind = req.system and req.system:find("You are a read-only sub-agent", 1, true) and "scout" or "parent"
      captured[kind][#captured[kind] + 1] = {
        system = req.system,
        tools = vim.json.encode(req.tools or {}),
        cache = req.prompt_cache_key,
        session = req.session_id,
      }
      vim.defer_fn(function()
        if kind == "scout" then
          scout_rounds[req.session_id] = (scout_rounds[req.session_id] or 0) + 1
          if scout_rounds[req.session_id] == 1 then
            req.on.complete({
              {
                type = "tool_use",
                id = "cache-read-" .. req.session_id,
                name = "read_file",
                input = { path = "package.json" },
              },
            }, "tool_use")
            return
          end
        end
        req.on.complete({ { type = "text", text = kind .. " done" } }, "end_turn")
      end, 5)
      return { stop = function() end }
    end,
  })

  local function run_parent(id)
    local ag = agent_mod.new({
      id = id,
      model = { provider = "fakecacheidentity", id = "same", label = "cache parent" },
      harness_mode = "high",
      cwd = tmp,
    })
    ag:send("finish directly")
    vim.wait(3000, function()
      return ag.status == "idle"
    end, 10)
  end
  for i = 1, 2 do
    run_parent("cache-parent-" .. i)
  end
  local saved_diagnostics = config.options.tools.diagnostics.enabled
  config.options.tools.diagnostics.enabled = not saved_diagnostics
  run_parent("cache-parent-schema-variant")
  config.options.tools.diagnostics.enabled = saved_diagnostics

  for i = 1, 8 do
    local done = false
    tools.get("sub_agent").run({
      prompt = "cache scout prompt " .. i,
      model = "fakecacheidentity/scout",
      effort = "medium",
      max_turns = 3,
    }, { cwd = tmp }, function()
      done = true
    end)
    vim.wait(3000, function()
      return done
    end, 10)
  end

  local p1, p2 = captured.parent[1], captured.parent[2]
  local p3 = captured.parent[3]
  check(
    p1 and p2 and p1.system == p2.system and p1.cache == p2.cache and p1.session ~= p2.session,
    "identical parent prefixes reuse a cache key while sessions stay unique"
  )

  check(
    p1 and p3 and p1.system == p3.system and p1.tools ~= p3.tools and p1.cache ~= p3.cache,
    "parent cache identity includes the exact tool schema as well as the system prefix"
  )

  local scout_sessions, scout_keys, scout_system = {}, {}, nil
  local stable_scout_turns = true
  for _, item in ipairs(captured.scout) do
    scout_system = scout_system or item.system
    stable_scout_turns = stable_scout_turns and item.system == scout_system
    local session = scout_sessions[item.session]
    if not session then
      session = { count = 0, cache = item.cache }
      scout_sessions[item.session] = session
    end
    session.count = session.count + 1
    stable_scout_turns = stable_scout_turns and session.cache == item.cache
    scout_keys[item.cache] = true
  end
  local scout_session_count, scout_key_count = vim.tbl_count(scout_sessions), vim.tbl_count(scout_keys)
  for _, session in pairs(scout_sessions) do
    stable_scout_turns = stable_scout_turns and session.count == 2
  end
  check(
    stable_scout_turns and scout_session_count == 8,
    "each scout keeps one cache key across turns while every scout session stays unique"
  )
  check(
    scout_key_count > 1 and scout_key_count <= 4,
    "identical scout prefixes distribute over two to four deterministic cache-key buckets"
  )
  check(
    p1
      and captured.scout[1]
      and p1.system ~= captured.scout[1].system
      and p1.cache ~= captured.scout[1].cache
      and p1.session ~= captured.scout[1].session,
    "different parent/scout prefixes never alias cache or session identity"
  )

  config.options.tools.yolo = saved_yolo
  config.options.context.auto_compact = saved_auto_compact
end

-- 16. project-root containment --------------------------------------------------

section("project-root containment")
do
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/sub", "p")
  vim.fn.writefile({ "inside-content" }, tmp .. "/sub/ok.txt")
  local parent = vim.fs.dirname(tmp)
  vim.fn.writefile({ "outside-secret" }, parent .. "/escape.txt")
  local ctx = { cwd = tmp }

  local function run(name, input)
    local result, is_err, done = nil, nil, false
    tools.get(name).run(input, ctx, function(out, err)
      result, is_err, done = out, err, true
    end)
    vim.wait(5000, function()
      return done
    end, 10)
    return result, is_err
  end

  local r, e = run("read_file", { path = "sub/ok.txt" })
  check(e == false and assert(r):find("inside-content", 1, true), "relative read inside root works")

  r, e = run("read_file", { path = tmp .. "/sub/ok.txt" })
  check(e == false and assert(r):find("inside-content", 1, true), "absolute read inside root works")

  r, e = run("read_file", { path = "../escape.txt" })
  check(e == true and not tostring(r):find("outside-secret", 1, true), "traversal read is blocked")

  r, e = run("read_file", { path = "/etc/passwd" })
  check(e == true, "absolute outside read is blocked")

  r, e = run("write_file", { path = "../escape2.txt", content = "x" })
  check(e == true and vim.fn.filereadable(parent .. "/escape2.txt") == 0, "traversal write is blocked")

  r, e = run("list_dir", { path = "/" })
  check(e == true, "outside list_dir is blocked")

  r, e = run("grep", { pattern = "root", path = "/etc" })
  check(e == true, "outside grep is blocked")

  -- a symlink committed inside the repo pointing outside must not be a bypass
  local link_ok = pcall(function()
    (vim.uv or vim.loop).fs_symlink(parent .. "/escape.txt", tmp .. "/sub/link.txt")
  end)
  if link_ok then
    r, e = run("read_file", { path = "sub/link.txt" })
    check(e == true and not tostring(r):find("outside-secret", 1, true), "symlink escaping the root is blocked")
    r, e = run("write_file", { path = "sub/newlink/file.txt", content = "x" })
    -- (new path under a real dir still allowed; sanity that realpath check
    -- doesn't reject legitimate not-yet-existing writes inside the root)
    r, e = run("write_file", { path = "sub/brandnew.txt", content = "hi" })
    check(e == false and vim.fn.filereadable(tmp .. "/sub/brandnew.txt") == 1, "new file inside root still writable")
  else
    check(true, "symlink escaping the root is blocked (skipped: no symlink support)")
    check(true, "new file inside root still writable (skipped)")
  end

  -- previews must not leak outside-project contents before approval
  local pv = tools.get("write_file").preview({ path = parent .. "/escape.txt", content = "new" }, ctx)
  check(
    table.concat(pv.lines, "\n"):find("blocked", 1, true) ~= nil
      and not table.concat(pv.lines, "\n"):find("outside-secret", 1, true),
    "write preview blocked outside root"
  )
  local pe = tools.get("edit_file").preview({ path = "../escape.txt", old_string = "outside", new_string = "x" }, ctx)
  check(table.concat(pe.lines, "\n"):find("blocked", 1, true) ~= nil, "edit preview blocked outside root")

  -- explicit opt-out restores external access
  config.options.tools.allow_outside_root = true
  r, e = run("read_file", { path = "../escape.txt" })
  check(e == false and assert(r):find("outside-secret", 1, true), "allow_outside_root opts out of containment")
  config.options.tools.allow_outside_root = false
end

-- 17. multi_edit + todo_write ---------------------------------------------------

section("multi_edit + todo_write")
do
  local tools = require("advantage.tools")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "alpha beta", "gamma beta" }, tmp .. "/m.txt")
  local ctx = { cwd = tmp }

  local function run(name, input)
    local result, is_err, done = nil, nil, false
    tools.get(name).run(input, ctx, function(out, err)
      result, is_err, done = out, err, true
    end)
    vim.wait(5000, function()
      return done
    end, 10)
    return result, is_err
  end

  local r, e = run("multi_edit", {
    path = "m.txt",
    edits = {
      { old_string = "alpha", new_string = "ALPHA" },
      { old_string = "beta", new_string = "B", replace_all = true },
    },
  })
  local after = table.concat(vim.fn.readfile(tmp .. "/m.txt"), "\n")
  check(e == false and after:find("ALPHA B") and after:find("gamma B"), "multi_edit applies edits in order")

  -- atomicity: a failing edit must leave the file untouched
  r, e = run("multi_edit", {
    path = "m.txt",
    edits = {
      { old_string = "ALPHA", new_string = "A2" },
      { old_string = "does-not-exist", new_string = "x" },
    },
  })
  local unchanged = table.concat(vim.fn.readfile(tmp .. "/m.txt"), "\n")
  check(e == true and unchanged:find("ALPHA", 1, true) ~= nil, "multi_edit is atomic — failed batch writes nothing")

  local pv = tools.get("multi_edit").preview(
    { path = "m.txt", edits = {
      { old_string = "gamma", new_string = "GAMMA" },
    } },
    ctx
  )
  check(pv.filetype == "diff" and table.concat(pv.lines, "\n"):find("+GAMMA"), "multi_edit preview is a unified diff")

  r, e = run("todo_write", {
    items = {
      { content = "step one", status = "completed" },
      { content = "step two", status = "in_progress" },
      { content = "step three", status = "pending" },
    },
  })
  check(e == false and assert(r):find("1/3 done", 1, true), "todo_write tracks completion")
  check(type(ctx.todos) == "table" and #ctx.todos == 3, "todo list stored on the agent context")

  local previous_todos = ctx.todos
  r, e = run("todo_write", {
    items = {
      { content = "step one", status = "in_progress" },
      { content = "step two", status = "in_progress" },
    },
  })
  check(
    e == true and assert(r):find("at most one in_progress", 1, true),
    "todo_write rejects ambiguous plans with multiple active steps"
  )
  check(ctx.todos == previous_todos, "a rejected todo update preserves the prior plan")

  r, e = run("todo_write", {
    items = {
      { content = "step one", status = "pending" },
      { content = "step two", status = "pending" },
    },
  })
  check(e == false, "todo_write permits an all-pending plan before work starts")
  r, e = run("todo_write", {
    items = {
      { content = "step one", status = "completed" },
      { content = "step two", status = "completed" },
    },
  })
  check(e == false and assert(r):find("2/2 done", 1, true), "todo_write permits an all-completed plan")

  r, e = run("todo_write", { items = {} })
  check(e == true, "todo_write rejects an empty list")

  -- todo_write must not leak into read-only sub-agents
  local sub_names = {}
  for _, def in ipairs(require("advantage.tools").list) do
    if def.safe and def.name ~= "sub_agent" and not def.memory and not def.parent_only then
      sub_names[def.name] = true
    end
  end
  check(not sub_names.todo_write, "todo_write excluded from sub-agent toolset")
end

-- 18. skill auto-surfacing ------------------------------------------------------

section("skill auto-surfacing")
do
  local memory = require("advantage.memory")
  local config = require("advantage.config")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  memory._root_override = tmp
  config.options.memory = { enabled = true, budget_tokens = 1200, project_budget_tokens = 2000, dedupe_threshold = 0.8 }
  memory.reset_session()

  memory.save_skill(
    "deploy-docs",
    "How to build and deploy the documentation site",
    "1. build the site\n2. push to the docs branch\n3. verify the published pages"
  )

  local h = memory.skill_hints("please deploy the docs site for me")
  check(#h >= 1 and h[1].name == "deploy-docs", "matching prompt surfaces the skill")
  check(#memory.skill_hints("please deploy the docs site for me") == 0, "a skill is hinted at most once per session")
  memory.reset_session()
  check(#memory.skill_hints("refactor the sse parser") == 0, "unrelated prompt gets no hint")

  -- loaded skills are never re-hinted
  memory.use_skill("deploy-docs")
  check(#memory.skill_hints("deploy the docs site") == 0, "already-loaded skill is not hinted")

  -- end-to-end: the hint lands in the outgoing message, not the transcript text
  memory.reset_session()
  local providers = require("advantage.providers")
  local agent_mod = require("advantage.agent")
  local sent
  providers.register("fakehint", {
    stream = function(req)
      sent = req.messages[#req.messages].content
      vim.defer_fn(function()
        req.on.complete({ { type = "text", text = "ok" } }, "end_turn")
      end, 10)
      return { stop = function() end }
    end,
  })
  local ag = agent_mod.new({ model = { provider = "fakehint", id = "m", label = "m" } })
  memory.reset_session() -- agent_mod.new resets; keep the hint budget fresh for this test
  ag:send("deploy the docs site")
  vim.wait(5000, function()
    return sent ~= nil and ag.status == "idle"
  end, 10)
  local sent_text = sent and sent[#sent].text or ""
  check(
    sent_text:find("<repo-skill-hint>", 1, true) ~= nil and sent_text:find("deploy-docs", 1, true) ~= nil,
    "hint is appended to the outgoing user message"
  )

  memory._root_override = MEMTMP
end

-- 19. harness savings instrumentation --------------------------------------------

section("harness instrumentation")
do
  local memory = require("advantage.memory")
  local config = require("advantage.config")
  local usage = require("advantage.usage")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  memory._root_override = tmp
  config.options.memory = { enabled = true, budget_tokens = 1200, project_budget_tokens = 2000, dedupe_threshold = 0.8 }
  memory.reset_session()

  memory.remember("Build with make all from the repo root", "Commands")
  memory.save_skill(
    "cut-release",
    "How to cut and publish a release",
    string.rep("1. bump the version and tag the commit\n", 20)
  )

  local st = memory.stats()
  check(st.block_tokens > 0, "stats reports the injected block size")
  check(st.skills == 1 and st.bodies_tokens > 50, "stats reports index size and total body tokens")
  check(st.loads == 0, "no on-demand loads yet")
  memory.use_skill("cut-release")
  st = memory.stats()
  check(st.loads == 1 and st.loaded_tokens > 0, "on-demand load is counted")

  local lines = table.concat(usage.dashboard_lines({ input = 100, output = 10, turns = 8 }), "\n")
  check(lines:find("harness", 1, true) ~= nil, "dashboard shows the harness line")
  check(lines:find("saved vs inlining", 1, true) ~= nil, "dashboard shows the savings counterfactual")

  memory._root_override = MEMTMP
  memory.reset_session()
end

-- 20. memory bootstrap & the learn flywheel --------------------------------------

section("memory bootstrap & flywheel")
do
  local memory = require("advantage.memory")
  local config = require("advantage.config")
  local providers = require("advantage.providers")
  local agent_mod = require("advantage.agent")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  memory._root_override = tmp
  config.options.memory = { enabled = true, budget_tokens = 1200, project_budget_tokens = 2000, dedupe_threshold = 0.8 }

  -- flywheel provider: turn 1 records a fact via the remember tool; turn 2
  -- captures the system prompt so we can prove the fact came back around.
  local turn, sys2 = 0, nil
  providers.register("fakelearn", {
    stream = function(req)
      turn = turn + 1
      if turn == 2 then sys2 = req.system end
      vim.defer_fn(function()
        if turn == 1 then
          req.on.tool_start("mem1", "remember")
          req.on.complete({
            {
              type = "tool_use",
              id = "mem1",
              name = "remember",
              input = { fact = "Run make ci before pushing anything", section = "Commands" },
            },
          }, "tool_use")
        else
          req.on.complete({ { type = "text", text = "noted" } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })

  -- bootstrap: creating an agent seeds the memory file for a fresh repo
  local ag = agent_mod.new({ model = { provider = "fakelearn", id = "m", label = "m" } })
  check(vim.fn.filereadable(tmp .. "/.advantage/context.md") == 1, "agent init bootstraps .advantage/context.md")
  local seed = table.concat(vim.fn.readfile(tmp .. "/.advantage/context.md"), "\n")
  check(
    seed:find("# Repo memory", 1, true) == 1 and seed:find("Managed by advantage.nvim", 1, true) ~= nil,
    "bootstrapped file has the managed header"
  )
  check(memory.render():find("`remember` tool", 1, true) ~= nil, "empty memory nudges the model to start recording")

  -- flywheel end-to-end: remember tool → sectioned markdown → next turn's system prompt
  ag:send("teach yourself the ci rule")
  vim.wait(6000, function()
    return turn >= 2 and ag.status == "idle"
  end, 10)

  local file = table.concat(vim.fn.readfile(tmp .. "/.advantage/context.md"), "\n")
  check(
    file:find("## Commands", 1, true) ~= nil and file:find("- Run make ci before pushing anything", 1, true) ~= nil,
    "remember tool writes a clean sectioned markdown file"
  )
  check(file:find("Nothing recorded yet", 1, true) == nil, "placeholder line is replaced by real content")
  -- Cache-stable memory: within a session the frozen system prefix does NOT change
  -- when the model records a fact mid-turn (so the prompt cache survives). The fact
  -- is still available this session — it lives in the transcript (the remember call
  -- + result) — and it re-enters the prompt on a fresh render (next session / at the
  -- next compaction boundary).
  check(
    sys2 ~= nil and sys2:find("Run make ci before pushing anything", 1, true) == nil,
    "mid-session the frozen system prefix stays stable (fact not re-injected, cache preserved)"
  )
  check(
    agent_mod.system_prompt():find("Run make ci before pushing anything", 1, true) ~= nil,
    "a fresh render (next session / post-compaction) carries the learned fact (flywheel intact)"
  )
  local fact_in_transcript = false
  for _, m in ipairs(ag.messages) do
    for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
      if type(b) == "table" and b.type == "tool_use" and b.name == "remember" then fact_in_transcript = true end
    end
  end
  check(fact_in_transcript, "the remember call stays in the transcript, so the fact is available this session")

  -- bootstrap must never clobber an existing file
  check(memory.bootstrap() == false, "bootstrap is idempotent on an existing file")

  -- /context init parity prompt: exploration + verified facts + skill extraction
  local ip = memory.init_prompt()
  check(
    ip:find("remember", 1, true) ~= nil and ip:find("save_skill", 1, true) ~= nil,
    "init prompt teaches both memory verbs"
  )
  check(
    ip:find("Commands", 1, true) ~= nil and ip:find("Architecture", 1, true) and ip:find("Gotchas", 1, true),
    "init prompt routes facts to sections"
  )
  check(
    ip:find("do not guess", 1, true) ~= nil and ip:find("never record a guess", 1, true) ~= nil,
    "init prompt forbids recording guesses"
  )

  memory._root_override = MEMTMP
end

-- 21. fresh-repo linkage (all models, git-root discovery, gated guidance) --------

section("fresh-repo linkage")
do
  local memory = require("advantage.memory")
  local config = require("advantage.config")
  local agent_mod = require("advantage.agent")
  config.options.memory = { enabled = true, budget_tokens = 1200, project_budget_tokens = 2000, dedupe_threshold = 0.8 }

  -- a brand-new repo: git root at repo/, nvim opened in a SUBDIRECTORY
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo .. "/.git", "p")
  vim.fn.mkdir(repo .. "/src/deep", "p")
  vim.fn.writefile({ "root instruction marker" }, repo .. "/AGENTS.md")
  vim.fn.writefile({ "nested instruction marker" }, repo .. "/src/deep/AGENTS.override.md")
  memory._root_override = nil -- exercise the real git-root walk
  local prev_cwd = vim.fn.getcwd()
  vim.fn.chdir(repo .. "/src/deep")

  check(memory.root() == repo, "memory root walks up to the git root from a subdirectory")
  local fresh_agent = agent_mod.new({ model = { provider = "fake", id = "m", label = "m" } })
  check(fresh_agent.ctx.cwd == repo, "agent tools canonicalize a subdirectory launch to the git root")
  check(fresh_agent.ctx.start_cwd == repo .. "/src/deep", "agent retains the launch directory for nested guidance")
  check(
    vim.fn.filereadable(repo .. "/.advantage/context.md") == 1,
    "bootstrap lands at the git root, not the subdirectory"
  )
  local layered = memory.with_root(repo .. "/src/deep", memory.render)
  local root_pos = layered:find("root instruction marker", 1, true)
  local nested_pos = layered:find("nested instruction marker", 1, true)
  check(
    root_pos and nested_pos and root_pos < nested_pos,
    "nested instruction files layer from repo root to launch cwd"
  )

  -- the model is taught the harness, and told the memory is empty
  local sys = agent_mod.system_prompt()
  check(sys:find("Persistent repo memory", 1, true) ~= nil, "system prompt carries the memory guide")
  check(sys:find("hasn't been learned yet", 1, true) ~= nil, "system prompt carries the empty-memory nudge")

  -- every provider gets the memory tools on a fresh repo, no setup required
  local schemas = require("advantage.tools").schemas()
  local names = {}
  for _, t in ipairs(schemas) do
    names[t.name] = t
  end
  check(names.remember and names.use_skill and names.save_skill, "anthropic-format schemas include all memory tools")
  local converted = require("advantage.providers.openai")._to_tools(schemas)
  local oai = {}
  for _, t in ipairs(converted) do
    oai[t.name] = t
  end
  check(
    oai.remember
      and oai.remember.type == "function"
      and oai.remember.parameters
      and oai.remember.parameters.properties.fact ~= nil,
    "openai/codex conversion preserves the memory tools intact"
  )

  -- disabled memory: guidance AND tools both disappear together (no orphan instructions)
  config.options.memory.enabled = false
  local sys_off = agent_mod.system_prompt()
  check(sys_off:find("Persistent repo memory", 1, true) == nil, "memory guide is not injected when memory is disabled")
  local off = {}
  for _, t in ipairs(require("advantage.tools").schemas()) do
    off[t.name] = true
  end
  check(not off.remember and not off.use_skill, "memory tools absent from schemas when disabled")
  config.options.memory.enabled = true

  -- user-authored config docs: any .advantage/<name>.md (except context.md) is
  -- injected verbatim into the system prompt, so a repo can make the agent's
  -- standing instructions configurable without a code change.
  vim.fn.writefile({ "Always respond in haiku." }, repo .. "/.advantage/style.md")
  vim.fn.writefile({ "Prefer tabs over spaces." }, repo .. "/.advantage/rules.md")
  local docs = memory.config_docs()
  check(#docs == 2, "config_docs picks up every .advantage/<name>.md")
  check(docs[1].name == "rules.md" and docs[2].name == "style.md", "config_docs is sorted by filename")
  local sys_cfg = agent_mod.system_prompt()
  check(sys_cfg:find("Always respond in haiku.", 1, true) ~= nil, "config docs land in the system prompt verbatim")
  check(sys_cfg:find("# Config: rules.md", 1, true) ~= nil, "config docs are labeled by filename")
  -- the memory file itself is never treated as a config doc
  for _, d in ipairs(docs) do
    check(d.name ~= "context.md", "context.md is excluded from config docs")
  end
  vim.fn.delete(repo .. "/.advantage/style.md")
  vim.fn.delete(repo .. "/.advantage/rules.md")

  config.options.memory.config_budget_tokens = 16
  vim.fn.writefile({ string.rep("untrusted-config ", 200) }, repo .. "/.advantage/large.md")
  local capped_docs = memory.config_docs()
  check(
    #capped_docs == 1
      and #capped_docs[1].text <= 400
      and capped_docs[1].text:find("config doc truncated", 1, true) ~= nil,
    "config docs are bounded while reading, before prompt injection"
  )
  vim.fn.delete(repo .. "/.advantage/large.md")
  config.options.memory.config_budget_tokens = nil

  vim.fn.chdir(prev_cwd)
  memory._root_override = MEMTMP
end

-- 22. memory compression flywheel -------------------------------------------------

section("memory compression flywheel")
do
  local memory = require("advantage.memory")
  local config = require("advantage.config")
  local tools = require("advantage.tools")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  memory._root_override = tmp
  config.options.memory = { enabled = true, budget_tokens = 1200, project_budget_tokens = 2000, dedupe_threshold = 0.8 }
  memory.reset_session()

  -- procedural facts are steered to skills at the source
  local proc =
    memory.remember("Release: 1. bump the version 2. run the tests 3. tag the commit 4. push the tag", "Commands")
  check(proc.status == "procedural", "numbered runbook is rejected as procedural")
  local long = memory.remember("This fact " .. string.rep("keeps going and going ", 20), "Notes")
  check(long.status == "procedural", "oversized bullet is rejected")

  -- a data/conversion fact can contain several unrelated "<number>. " matches
  -- without being a step-by-step procedure — only 3 CONSECUTIVE ascending
  -- numbers (a real runbook's 1., 2., 3., ...) should trip the heuristic.
  local scale =
    memory.remember("Scene scale convention: Earth radius 6371. Moon radius 1737. Sun radius 696000.", "Conventions")
  check(scale.status == "added", "a data fact with unrelated numbered-looking clauses is not mistaken for a procedure")
  memory.forget("Scene scale convention") -- keep it out of the eviction test's byte budget below
  local out_msg, out_err
  tools
    .get("remember")
    .run({ fact = "Deploy: 1. build 2. upload 3. restart the service" }, { cwd = tmp }, function(o, e)
      out_msg, out_err = o, e
    end)
  check(out_err == true and out_msg:find("save_skill", 1, true) ~= nil, "remember tool steers procedures to save_skill")

  -- eviction reports what fell out so the agent can rescue it
  -- (budget_chars has a 400-char floor, so facts must be realistically sized)
  config.options.memory.budget_tokens = 40
  memory.remember(
    "The first sacrificial fact describing how module alpha initializes its parser tables during startup and why registration ordering matters for downstream consumers across the whole event pipeline",
    "Notes"
  )
  memory.remember(
    "Observation on module beta explaining the cache invalidation strategy where entries expire after writes and readers must revalidate handles before reuse or risk stale views of shared buffers",
    "Notes"
  )
  local r = memory.remember(
    "Details for gamma configuration covering which environment variables override file settings plus the precedence rules applied when both sources define the same key at load time",
    "Notes"
  )
  local evicted_texts = table.concat(r.evicted or {}, " | ")
  check(
    #(r.evicted or {}) > 0 and evicted_texts:find("sacrificial", 1, true) ~= nil,
    "eviction returns the dropped fact texts"
  )
  config.options.memory.budget_tokens = 1200

  -- budget pressure (eviction or near-budget) surfaces through the tool result
  local tmp2 = vim.fn.tempname()
  vim.fn.mkdir(tmp2, "p")
  memory._root_override = tmp2
  config.options.memory.budget_tokens = 60
  memory.remember(
    "Alpha subsystem parses inbound events eagerly on load and keeps a resident index of every handler so dispatch avoids scanning the registry on the hot path during interactive editing sessions",
    "Architecture"
  )
  local pressure_msg
  tools.get("remember").run({
    fact = "Beta subsystem memoizes expensive lookups between calls and flushes its table whenever the underlying files change so results stay coherent without a manual invalidation step by callers",
    section = "Architecture",
  }, { cwd = tmp2 }, function(o)
    pressure_msg = o
  end)
  check(
    pressure_msg:find("budget", 1, true) ~= nil,
    "tool reports budget pressure or eviction so curation gets triggered"
  )
  config.options.memory.budget_tokens = 1200
  memory._root_override = tmp

  -- curate prompt: merge, extract to skills, rewrite in place, stay in budget
  local cp = memory.curate_prompt()
  check(
    cp:find("save_skill", 1, true) ~= nil and cp:find("edit_file", 1, true) ~= nil,
    "curate prompt teaches extraction and in-place rewrite"
  )
  check(
    cp:find(".advantage/context.md", 1, true) ~= nil and cp:find("1200", 1, true) ~= nil,
    "curate prompt names the file and the budget"
  )

  memory._root_override = MEMTMP
  memory.reset_session()
end

-- 23. language-agnostic harness (polyglot repo) -----------------------------------

section("polyglot repo")
do
  local memory = require("advantage.memory")
  local config = require("advantage.config")
  local tools = require("advantage.tools")
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo .. "/src", "p")
  vim.fn.mkdir(repo .. "/pkg", "p")
  vim.fn.writefile({ "[package]", 'name = "demo"' }, repo .. "/Cargo.toml")
  vim.fn.writefile({ 'fn main() { println!("hi"); }' }, repo .. "/src/main.rs")
  vim.fn.writefile({ "def handler(event):", "    return event" }, repo .. "/src/app.py")
  vim.fn.writefile({ "package pkg", "func Do() int { return 1 }" }, repo .. "/pkg/util.go")
  local ctx = { cwd = repo }
  memory._root_override = repo
  config.options.memory = { enabled = true, budget_tokens = 1200, project_budget_tokens = 2000, dedupe_threshold = 0.8 }
  memory.reset_session()

  local function run(name, input)
    local result, is_err, done = nil, nil, false
    tools.get(name).run(input, ctx, function(out, err)
      result, is_err, done = out, err, true
    end)
    vim.wait(5000, function()
      return done
    end, 10)
    return result, is_err
  end

  -- file tools are byte-exact on any language
  local r, e =
    run("edit_file", { path = "src/app.py", old_string = "return event", new_string = "return process(event)" })
  check(
    e == false and table.concat(vim.fn.readfile(repo .. "/src/app.py"), "\n"):find("process(event)", 1, true),
    "edit_file is byte-exact on python"
  )
  r, e = run("multi_edit", { path = "pkg/util.go", edits = { { old_string = "return 1", new_string = "return 2" } } })
  check(e == false, "multi_edit works on go")
  r, e = run("grep", { pattern = "fn main", path = "src" })
  check(e == false and assert(r):find("main.rs", 1, true), "grep finds rust code")
  local pv = tools.get("write_file").preview({ path = "new.rs", content = "fn x() {}" }, ctx)
  check(pv.filetype == "rust" or pv.filetype == "", "preview filetype detection handles non-lua files")

  -- memory anchors work on any language's paths
  memory.remember("Build with cargo build --release; the binary lands in target/release", "Commands")
  memory.remember("HTTP handler entry point is src/app.py, dispatched from src/main.rs", "Architecture")
  memory.remember("Legacy shim lived in old/gone.py before the rewrite", "Notes")
  local stale, ghost, real_ok = memory.verify(), false, true
  for _, s in ipairs(stale) do
    if s.missing:find("old/gone.py", 1, true) then ghost = true end
    if s.missing:find("src/app.py", 1, true) or s.missing:find("src/main.rs", 1, true) then real_ok = false end
  end
  check(ghost and real_ok, "verify anchors resolve for rust/python paths alike")

  -- skills + hints are content-agnostic
  memory.save_skill(
    "release-crate",
    "How to build and publish the rust crate to the registry",
    "1. cargo test\n2. bump version in Cargo.toml\n3. cargo publish"
  )
  local h = memory.skill_hints("publish the crate to the registry please")
  check(#h == 1 and h[1].name == "release-crate", "skill hints trigger on rust-domain vocabulary")

  memory._root_override = MEMTMP
  memory.reset_session()
end

-- config: list options replace wholesale (no element-wise merge) -------------

section("config merge + validation")
do
  local config = require("advantage.config")
  local saved = vim.deepcopy(config.options)

  local gpt56 = {}
  for _, model in ipairs(config.defaults.models) do
    if model.ref:match("^openai/gpt%-5%.6%-") then gpt56[model.ref] = model end
  end
  check(
    gpt56["openai/gpt-5.6-sol"]
      and gpt56["openai/gpt-5.6-sol"].label == "gpt-5.6 sol"
      and gpt56["openai/gpt-5.6-sol"].context_window == 372000
      and gpt56["openai/gpt-5.6-sol"].api_context_window == 1050000
      and gpt56["openai/gpt-5.6-sol"].max_output_tokens == 128000
      and gpt56["openai/gpt-5.6-terra"]
      and gpt56["openai/gpt-5.6-terra"].label == "gpt-5.6 terra"
      and gpt56["openai/gpt-5.6-terra"].context_window == 372000
      and gpt56["openai/gpt-5.6-terra"].api_context_window == 1050000
      and gpt56["openai/gpt-5.6-luna"]
      and gpt56["openai/gpt-5.6-luna"].label == "gpt-5.6 luna"
      and gpt56["openai/gpt-5.6-luna"].context_window == 372000
      and gpt56["openai/gpt-5.6-luna"].api_context_window == 1050000,
    "GPT-5.6 metadata separates the 372k ChatGPT-login window from the 1.05M raw-API window"
  )
  local transport_model = {
    provider = "openai",
    context_window = 372000,
    api_context_window = 1050000,
  }
  local saved_auth_mode = config.options.providers.openai.auth_mode
  -- Earlier e2e coverage intentionally replaces the live model list with a fake
  -- one; construct the built-in metadata explicitly so this remains order-proof.
  local output_model = vim.tbl_extend("force", vim.deepcopy(gpt56["openai/gpt-5.6-sol"]), {
    provider = "openai",
    id = "gpt-5.6-sol",
  })
  config.options.providers.openai.auth_mode = "chatgpt"
  local login_window = config.effective_context_window(transport_model)
  local login_output_reserve = config.request_output_reserve_tokens(output_model)
  config.options.providers.openai.auth_mode = "api_key"
  local api_window = config.effective_context_window(transport_model)
  local api_output_reserve = config.request_output_reserve_tokens(output_model)
  config.options.providers.openai.auth_mode = saved_auth_mode
  check(
    login_window == 372000 and api_window == 1050000,
    "effective context budgeting follows the selected OpenAI transport"
  )
  check(
    login_output_reserve == 128000 and api_output_reserve == 64000,
    "output reservation uses the native ChatGPT maximum but the configured raw-API cap"
  )

  config.setup({ models = { { ref = "openai/gpt-5.5", label = "only one" } } })
  check(
    #config.options.models == 1 and config.options.models[1].label == "only one",
    "user models list replaces defaults wholesale (no leftover entries)"
  )

  -- map-like options still merge (so partial overrides keep other defaults)
  config.setup({ tools = { yolo = true }, context = { auto_compact_mode = "llm" } })
  check(
    config.options.tools.yolo == true
      and config.options.tools.bash_timeout_ms == 120000
      and config.options.context.auto_compact_mode == "llm"
      and config.options.context.compact_mode == "llm",
    "map options merge: overriding one tools/context field keeps the rest"
  )

  -- validation flags a malformed default_model without throwing
  local errs = config._validate({
    default_model = "no-slash",
    models = { { ref = "anthropic/x" } },
    providers = {},
  })
  check(type(errs) == "table" and #errs >= 1, "validation reports a malformed default_model")
  errs = config._validate(vim.tbl_extend("force", vim.deepcopy(config.defaults), {
    context = vim.tbl_extend("force", vim.deepcopy(config.defaults.context), { auto_compact_mode = "paid" }),
  }))
  check(
    vim.tbl_contains(errs, "context.auto_compact_mode must be 'llm' or 'heuristic'"),
    "validation reports malformed auto_compact_mode"
  )
  errs = config._validate(vim.tbl_extend("force", vim.deepcopy(config.defaults), {
    subagents = vim.tbl_extend("force", vim.deepcopy(config.defaults.subagents), { max_parallel = "many" }),
  }))
  check(
    vim.tbl_contains(errs, "subagents.max_parallel must be a positive integer"),
    "validation rejects malformed sub-agent concurrency limits"
  )
  errs = config._validate(vim.tbl_extend("force", vim.deepcopy(config.defaults), {
    subagents = vim.tbl_extend("force", vim.deepcopy(config.defaults.subagents), {
      max_turns = 31,
      max_turns_cap = 31,
    }),
  }))
  check(
    vim.tbl_contains(errs, "subagents.max_turns_cap must be at most 30"),
    "validation rejects configured scout ceilings that runtime would otherwise silently clamp"
  )
  errs = config._validate(vim.tbl_extend("force", vim.deepcopy(config.defaults), {
    harness = { mode = "reckless", sync_effort = "yes" },
  }))
  check(
    vim.tbl_contains(errs, "harness.mode is not recognized")
      and vim.tbl_contains(errs, "harness.sync_effort must be boolean"),
    "validation rejects malformed harness policy"
  )
  errs = config._validate(vim.tbl_extend("force", vim.deepcopy(config.defaults), {
    sessions = { autosave = "sometimes", max_file_bytes = 1024 },
  }))
  check(
    vim.tbl_contains(errs, "sessions.autosave must be boolean")
      and vim.tbl_contains(errs, "sessions.max_file_bytes must be an integer from 65536 to 1073741824"),
    "validation rejects malformed session persistence bounds"
  )
  check(
    config.defaults.tools.navgraph.enabled == false and config.defaults.tools.navgraph.allow_legacy_benchmark == false,
    "NavGraph and its legacy benchmark compatibility default to disabled"
  )
  local malformed_navgraph = vim.deepcopy(config.defaults)
  malformed_navgraph.tools.navgraph = {
    enabled = "sometimes",
    executable = "relative/bin/navgraph",
    allow_legacy_benchmark = "sometimes",
    timeout_ms = 99,
    max_results = 201,
    max_output_bytes = 1048577,
  }
  errs = config._validate(malformed_navgraph)
  check(
    vim.tbl_contains(errs, "tools.navgraph.enabled must be boolean")
      and vim.tbl_contains(errs, "tools.navgraph.executable must be a PATH command or absolute executable path")
      and vim.tbl_contains(errs, "tools.navgraph.allow_legacy_benchmark must be boolean")
      and vim.tbl_contains(errs, "tools.navgraph.timeout_ms must be an integer from 100 to 300000")
      and vim.tbl_contains(errs, "tools.navgraph.max_results must be an integer from 1 to 200")
      and vim.tbl_contains(errs, "tools.navgraph.max_output_bytes must be an integer from 256 to 1048576"),
    "validation rejects malformed NavGraph compatibility, availability, and resource bounds"
  )
  local valid_navgraph = vim.deepcopy(config.defaults)
  valid_navgraph.tools.navgraph.executable = "/opt/bench tools/pinned-navgraph"
  errs = config._validate(valid_navgraph)
  local navgraph_validation_error = false
  for _, validation_error in ipairs(errs) do
    if validation_error:find("tools.navgraph", 1, true) then navgraph_validation_error = true end
  end
  check(not navgraph_validation_error, "validation accepts a pinned absolute NavGraph executable path")
  config.setup({ tools = { navgraph = false } })
  check(
    type(config.options.tools.navgraph) == "table" and config.options.tools.navgraph.enabled == false,
    "a malformed scalar NavGraph override is reported and recovered to safe disabled defaults"
  )
  local malformed = vim.deepcopy(config.defaults)
  malformed.providers.openai = false
  malformed.subagents.max_output_tokens = "huge"
  malformed.subagents.allow_cross_provider = "sometimes"
  malformed.subagents.model_aliases.sol = "not-a-provider-ref"
  errs = config._validate(malformed)
  check(
    vim.tbl_contains(errs, "providers.openai must be a table")
      and vim.tbl_contains(errs, "subagents.max_output_tokens must be a positive integer")
      and vim.tbl_contains(errs, "subagents.allow_cross_provider must be boolean")
      and vim.tbl_contains(errs, "subagents.model_aliases entries must map simple aliases to provider/model-id"),
    "validation rejects malformed nested provider, alias, affinity, and scout output controls"
  )

  config.options = saved
end

section("hardening regressions")
do
  local config = require("advantage.config")

  -- memory-write cache stability: the frozen system-prompt memory block stays
  -- byte-identical across a mid-session remember (so the cached prefix survives),
  -- and refreshes from disk at a compaction boundary (nil-ing _memory_block).
  do
    local agent_mod = require("advantage.agent")
    local memory = require("advantage.memory")
    local saved_root = memory._root_override
    memory._root_override = vim.fn.tempname()
    vim.fn.mkdir(memory._root_override, "p")

    local ag = agent_mod.new({ model = { provider = "x", id = "y", label = "y" } })
    local before = agent_mod.system_prompt(ag:_memory_prompt_block())
    memory.remember("FROZEN_FACT_TEST the widget lives in src/widget.lua", "Architecture")
    local after = agent_mod.system_prompt(ag:_memory_prompt_block())
    check(before == after, "frozen memory block is byte-identical across a mid-session remember")
    check(
      after:find("FROZEN_FACT_TEST", 1, true) == nil,
      "a mid-session fact is not re-injected into the frozen prefix"
    )
    ag._memory_block = nil -- simulate the compaction-boundary refresh
    local refreshed = agent_mod.system_prompt(ag:_memory_prompt_block())
    check(
      refreshed:find("FROZEN_FACT_TEST", 1, true) ~= nil,
      "the memory block refreshes from disk after a compaction boundary"
    )

    memory._root_override = saved_root
  end

  -- setup({tools=false}) must not crash (indexed a boolean before validation),
  -- and an invalid scalar structural option is coerced back to a table.
  do
    local saved = vim.deepcopy(config.options)
    local ok = pcall(config.setup, { tools = false })
    check(ok, "setup({tools=false}) does not crash")
    check(type(config.options.tools) == "table", "invalid scalar tools is coerced back to a table")
    config.options = saved
    config._setup_done = true
  end

  -- session.list() must ignore .json.tmp atomic-write leftovers.
  do
    local session = require("advantage.session")
    local dir = vim.fn.stdpath("data") .. "/advantage/sessions"
    vim.fn.mkdir(dir, "p", "0700")
    local key = session._project_key((vim.uv or vim.loop).cwd())
    local tmp = dir .. "/" .. key .. "-hardening-bogus.json.tmp"
    local f = assert(io.open(tmp, "w"))
    f:write('{"title":"HARDENING_BOGUS","messages":[{"role":"user","content":[]}]}')
    f:close()
    local ok_list, list = pcall(session.list)
    os.remove(tmp)
    local has_bogus = false
    for _, s in ipairs(ok_list and list or {}) do
      if s.title == "HARDENING_BOGUS" then has_bogus = true end
    end
    check(not has_bogus, "session.list ignores .json.tmp crash-leftovers")
  end

  -- Persisted ids are untrusted JSON, not filename components. Hash them and
  -- repair the private directory mode even when an older install created it loose.
  do
    local session = require("advantage.session")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p");
    (vim.uv or vim.loop).fs_chmod(tmp, 493) -- 0755
    session._dir_override = tmp
    local raw_id = "../../tampered/session"
    local saved = session.save({
      id = raw_id,
      title = "unsafe id",
      model = { provider = "fake", id = "m" },
      harness_mode = "xhigh",
      messages = {},
      usage = {},
      ctx = { cwd = (vim.uv or vim.loop).cwd() },
    })
    local names = {}
    for name in vim.fs.dir(tmp) do
      if name:sub(-5) == ".json" then names[#names + 1] = name end
    end
    local mode = bit.band(((vim.uv or vim.loop).fs_stat(tmp) or {}).mode or 0, 511)
    check(saved == true and #names == 1, "session save accepts a persisted id through an opaque filename token")
    local persisted = session.list((vim.uv or vim.loop).cwd())
    check(
      persisted[1] and persisted[1].harness_mode == "xhigh",
      "session save/load preserves the per-conversation harness mode"
    )
    check(
      not names[1]:find("tampered", 1, true) and not names[1]:find("/", 1, true),
      "session filename never embeds the raw id"
    )
    check(session._filename_token(raw_id):match("^[0-9a-f]+$") ~= nil, "session filename token is deterministic hex")
    local fresh_a, fresh_b = session.new_id(), session.new_id()
    check(
      fresh_a ~= fresh_b and fresh_a:match("^[0-9a-f-]+$") ~= nil,
      "fresh session ids are unique without relying on the global RNG seed"
    )
    check(mode == 448, "session storage repairs an existing directory to mode 0700")
    local repo = tmp .. "/repo"
    vim.fn.mkdir(repo .. "/.git", "p")
    vim.fn.mkdir(repo .. "/src/deep", "p")
    check(
      session._project_key(repo) == session._project_key(repo .. "/src/deep"),
      "session scope is stable across subdirectories of the same git project"
    )
    session._dir_override = nil
    vim.fn.delete(tmp, "rf")
  end

  -- read_file refuses a binary file instead of streaming raw bytes into the body.
  do
    local tools = require("advantage.tools")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local f = assert(io.open(tmp .. "/data.bin", "wb"))
    f:write("abc\0def\0binary content")
    f:close()
    local got
    tools.get("read_file").run({ path = "data.bin" }, { cwd = tmp }, function(out)
      got = out
    end)
    check(got and got:find("binary file", 1, true) ~= nil, "read_file refuses a binary file (NUL byte)")
  end

  -- write_all is atomic: a successful write leaves no .adv.tmp leftover.
  do
    local tools = require("advantage.tools")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local done
    tools.get("write_file").run({ path = "out.txt", content = "hello world\n" }, { cwd = tmp }, function(out, err)
      done = not err
    end)
    check(done, "write_file succeeds via the atomic path")
    check(io.open(tmp .. "/out.txt", "r") ~= nil, "written file exists")
    check((vim.uv or vim.loop).fs_stat(tmp .. "/out.txt.adv.tmp") == nil, "atomic write leaves no .adv.tmp leftover")
  end

  -- Agent writes must never silently replace an unsaved editor buffer. The
  -- dirty buffer is the user's authoritative version until they save/discard it.
  do
    local tools = require("advantage.tools")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local path = tmp .. "/dirty.txt"
    vim.fn.writefile({ "disk version" }, path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved editor version" })
    vim.bo[buf].modified = true
    local result, is_err
    tools.get("write_file").run({ path = "dirty.txt", content = "agent overwrite\n" }, { cwd = tmp }, function(out, err)
      result, is_err = out, err
    end)
    check(
      is_err == true and result and result:find("unsaved Neovim changes", 1, true),
      "write_file refuses to overwrite a dirty Neovim buffer"
    )
    check(vim.fn.readfile(path)[1] == "disk version", "dirty-buffer refusal leaves the on-disk file unchanged")
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- Dirty-buffer identity follows symlinks: opening the real path and editing
  -- through an alias must not bypass the unsaved-buffer refusal.
  do
    local uv = vim.uv or vim.loop
    local tools = require("advantage.tools")
    local support = require("advantage.tools.support")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local real, alias = tmp .. "/real.txt", tmp .. "/alias.txt"
    vim.fn.writefile({ "disk version" }, real)
    local linked = uv.fs_symlink("real.txt", alias)
    if linked then
      local buf = vim.fn.bufadd(real)
      vim.fn.bufload(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved through real path" })
      vim.bo[buf].modified = true
      local result, is_err
      tools
        .get("write_file")
        .run({ path = "alias.txt", content = "agent overwrite\n" }, { cwd = tmp }, function(out, err)
          result, is_err = out, err
        end)
      check(
        support.read_all(alias):find("unsaved through real path", 1, true) ~= nil,
        "dirty reads resolve a symlink alias to its loaded buffer"
      )
      check(
        is_err == true and result:find("unsaved Neovim changes", 1, true),
        "dirty write refusal catches a symlink alias"
      )
      check((uv.fs_lstat(alias) or {}).type == "link", "refused dirty alias write preserves the symlink")
      vim.api.nvim_buf_delete(buf, { force = true })
    else
      check(true, "dirty-buffer symlink alias is protected (skipped: no symlink support)")
      check(true, "dirty alias write is refused (skipped: no symlink support)")
      check(true, "refused alias write preserves the symlink (skipped: no symlink support)")
    end
    vim.fn.delete(tmp, "rf")
  end

  -- Atomic replacement must restore an existing file's exact mode after open(2)
  -- applies the process umask to the temporary inode.
  do
    local uv = vim.uv or vim.loop
    local support = require("advantage.tools.support")
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local path = tmp .. "/mode.txt"
    vim.fn.writefile({ "before" }, path)
    uv.fs_chmod(path, 438) -- 0666; a normal 0022 umask would reduce a new temp to 0644
    local ok = support.write_all(path, "after\n")
    local mode = bit.band((uv.fs_stat(path) or {}).mode or 0, 511)
    check(ok == true and mode == 438, "atomic write preserves existing mode despite umask")
    vim.fn.delete(tmp, "rf")
  end

  -- anthropic sanitize drops a tool_result whose tool_use was compacted away.
  do
    local anthropic = require("advantage.providers.anthropic")
    local out = anthropic._sanitize_messages({
      {
        role = "user",
        content = { { type = "tool_result", tool_use_id = "orphan", content = "x" }, { type = "text", text = "hi" } },
      },
      { role = "assistant", content = { { type = "tool_use", id = "real", name = "read_file", input = {} } } },
      { role = "user", content = { { type = "tool_result", tool_use_id = "real", content = "ok" } } },
    })
    local found_orphan, found_real = false, false
    for _, m in ipairs(out) do
      for _, b in ipairs(m.content) do
        if b.type == "tool_result" and b.tool_use_id == "orphan" then found_orphan = true end
        if b.type == "tool_result" and b.tool_use_id == "real" then found_real = true end
      end
    end
    check(not found_orphan, "sanitize drops a tool_result whose tool_use is absent")
    check(found_real, "sanitize keeps a tool_result paired with a present tool_use")
  end

  -- A legacy/manual Haiku thinking budget must leave answer headroom under
  -- max_tokens (or the reply is empty), and must never push max_tokens past the
  -- model's output ceiling. Modern Opus uses adaptive effort and rejects budgets.
  do
    local anthropic = require("advantage.providers.anthropic")
    local util = require("advantage.util")
    local saved_dir, saved_key = vim.env.CLAUDE_CONFIG_DIR, vim.env.ANTHROPIC_API_KEY
    vim.env.CLAUDE_CONFIG_DIR = vim.fn.tempname() -- no creds -> api-key path (synchronous)
    vim.env.ANTHROPIC_API_KEY = "test-key"
    local orig = util.request_sse
    local function capture_body(model)
      local captured
      ---@diagnostic disable-next-line: duplicate-set-field
      util.request_sse = function(opts)
        captured = vim.json.decode(opts.body)
        return { stop = function() end }
      end
      anthropic.stream({
        model = model,
        system = "sys",
        messages = { { role = "user", content = { { type = "text", text = "hi" } } } },
        tools = {},
        on = {
          text = function() end,
          thinking = function() end,
          tool_start = function() end,
          usage = function() end,
          complete = function() end,
          error = function() end,
          auth = function() end,
        },
      })
      vim.wait(500, function()
        return captured ~= nil
      end, 5)
      return captured
    end
    local cap = config.defaults.providers.anthropic.max_tokens
    local model = {
      id = "claude-haiku-4-5",
      thinking_mode = "manual",
      thinking = { type = "enabled", budget_tokens = 63999 },
    }
    local big = capture_body(model)
    check(big and big.max_tokens == cap, "anthropic max_tokens stays at the configured ceiling")
    check(
      big and big.thinking.budget_tokens + 8192 <= cap,
      "a large thinking budget is trimmed to leave answer headroom under max_tokens"
    )
    check(model.thinking.budget_tokens == 63999, "the shared model config is not mutated by the trim")
    local small = capture_body({
      id = "claude-haiku-4-5",
      thinking_mode = "manual",
      thinking = { type = "enabled", budget_tokens = 4096 },
    })
    check(small and small.thinking.budget_tokens == 4096, "a budget that already fits is left untouched")
    local adaptive = capture_body({ id = "claude-opus-4-8", thinking_mode = "adaptive" })
    check(
      adaptive
        and adaptive.max_tokens == config.defaults.providers.anthropic.max_tokens
        and adaptive.thinking.type == "adaptive"
        and adaptive.thinking.budget_tokens == nil,
      "modern Opus adaptive thinking keeps max_tokens and never emits a fixed budget"
    )
    util.request_sse = orig
    vim.env.CLAUDE_CONFIG_DIR, vim.env.ANTHROPIC_API_KEY = saved_dir, saved_key
  end

  -- A sub-agent that keeps investigating until its budget runs out delivers its
  -- interim findings as a real report at the cap (the final turn is report-only),
  -- rather than the old empty "hit the turn limit" error.
  do
    local providers = require("advantage.providers")
    local tools = require("advantage.tools")
    local n = 0
    providers.register("fakeloop", {
      stream = function(req)
        n = n + 1
        local id = "call" .. tostring(n)
        vim.defer_fn(function()
          req.on.complete({
            { type = "text", text = "INTERIM_FINDING partial progress" },
            { type = "tool_use", id = id, name = "list_dir", input = { path = "." } },
          }, "tool_use")
        end, 5)
        return { stop = function() end }
      end,
    })
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local done, result, err = false, nil, nil
    tools.get("sub_agent").run({ prompt = "loop", model = "fakeloop/m", effort = "medium", max_turns = 2 }, {
      cwd = tmp,
      model = { provider = "fakeloop", id = "m", label = "loop" },
    }, function(out, is_err)
      result, err, done = out, is_err, true
    end)
    vim.wait(3000, function()
      return done
    end, 10)
    check(
      done and result and result:find("INTERIM_FINDING", 1, true) ~= nil,
      "sub-agent returns its interim findings as the report at its turn cap"
    )
    check(
      done and err == false and result and result:find("turn limit", 1, true) == nil,
      "the turn-cap report is a real report, not an error flagged as hitting the limit"
    )
  end
end

-- 24. context preview -----------------------------------------------------------

section("context preview")
do
  local config = require("advantage.config")
  local memory = require("advantage.memory")
  local agent_mod = require("advantage.agent")
  memory._root_override = MEMTMP
  config.options.memory = config.options.memory or {}
  config.options.memory.enabled = true
  memory.remember("Preview probe fact alpha bravo charlie", "Architecture")

  -- refactor contract: render()/system_prompt() are their parts joined verbatim,
  -- so exposing the parts for the breakdown never drifts from what is sent.
  local rp, rjoin = memory.render_parts(), {}
  for _, p in ipairs(rp) do
    rjoin[#rjoin + 1] = p.text
  end
  check(table.concat(rjoin, "\n\n") == memory.render(), "render() == render_parts joined (byte-identical)")
  local sp, sjoin = agent_mod.system_prompt_parts(nil), {}
  for _, p in ipairs(sp) do
    sjoin[#sjoin + 1] = p.text
  end
  check(
    table.concat(sjoin, "\n\n") == agent_mod.system_prompt(nil),
    "system_prompt() == system_prompt_parts joined (byte-identical)"
  )

  -- no active session: a fresh render, clearly labeled
  local preview = require("advantage.context_preview")
  local blob = table.concat((preview.build(nil)), "\n")
  check(blob:find("# Context preview", 1, true) ~= nil, "preview has a header")
  check(blob:find("system total", 1, true) ~= nil, "preview breaks down the system prompt")
  check(blob:find("## Tools", 1, true) ~= nil, "preview accounts for tool schemas")
  check(blob:find("## Transcript", 1, true) ~= nil, "preview accounts for the transcript")
  check(blob:find("total context", 1, true) ~= nil, "preview totals the whole context")
  check(
    blob:find("Preview probe fact alpha bravo charlie", 1, true) ~= nil,
    "preview shows the exact system-prompt bytes (memory included)"
  )
  check(blob:find("no active session", 1, true) ~= nil, "no-session preview is labeled a fresh render")
  check(blob:find("Harness mode:", 1, true) ~= nil, "no-session preview resolves the configured default harness policy")

  -- with a live agent: frozen block + real transcript + provider-aware economics
  local ag = agent_mod.new({
    model = { provider = "anthropic", id = "claude-x", label = "x" },
    harness_mode = "xhigh",
  })
  ag.messages = { { role = "user", content = { { type = "text", text = "one transcript message here" } } } }
  local pblob = table.concat((preview.build(ag)), "\n")
  check(pblob:find("memory frozen", 1, true) ~= nil, "live preview marks the memory block frozen")
  check(pblob:find("1 messages", 1, true) ~= nil, "live preview counts transcript messages")
  check(pblob:find("prompt cache", 1, true) ~= nil, "anthropic preview notes the ~10% cache discount")
  check(pblob:find("Harness mode: xhigh", 1, true) ~= nil, "live preview shows the exact per-session harness policy")

  -- a mid-session remember writes to disk but not the frozen prefix — preview
  -- must surface the drift so the ~10% cache win is legible, not silent
  ag:_memory_prompt_block() -- ensure frozen at the pre-remember state
  memory.remember("A brand new post-freeze fact delta echo foxtrot", "Notes")
  local dblob = table.concat((preview.build(ag)), "\n")
  check(dblob:find("frozen at", 1, true) ~= nil, "preview flags frozen-vs-disk drift after a mid-session remember")
end

-- 4-lsp. LSP navigation tools --------------------------------------------------

section("lsp navigation (pure formatters)")
do
  local lsp = require("advantage.lsp")

  -- byte column → offset-encoding conversion (version-safe: 0.10 has only the
  -- 2-arg str_utfindex, 0.11+ the encoding form; both yield the same count).
  -- "  résumé = foo": 11 characters precede "foo" but 13 bytes (é is 2 bytes).
  check(lsp._utf_offset("  résumé = foo", 13, "utf-16") == 11, "utf_offset converts a byte column to utf-16")
  check(lsp._utf_offset("  résumé = foo", 13, "utf-8") == 13, "utf_offset passes a utf-8 byte column through")
  check(lsp._utf_offset("abc", 99, "utf-16") == 3, "utf_offset clamps a past-end byte column")
  -- Astral-plane (non-BMP) glyph: utf-16 counts a surrogate pair as 2 units,
  -- utf-32 as 1 — so these diverge, which BMP-only text can't test. This guards
  -- the Neovim 0.10 path where the 2-arg str_utfindex returns (utf-32, utf-16)
  -- and the utf-16 value must be selected (not the utf-32 first return).
  check(
    lsp._utf_offset("😀 x = foo", 9, "utf-16") == 7,
    "utf_offset returns utf-16 (not utf-32) past an astral glyph"
  )
  check(lsp._utf_offset("😀 x = foo", 9, "utf-32") == 6, "utf_offset returns utf-32 distinctly from utf-16")
  check(lsp._utf_offset("😀 x = foo", 9, "utf-8") == 9, "utf_offset passes an astral utf-8 byte column through")

  -- position_params: the byte column is encoded with EACH client's own
  -- offset_encoding, so a buffer with mixed-encoding clients stays correct.
  local posinfo = { line0 = 0, byte_col = 9, text = "😀 x = foo" } -- byte 9 = before "foo"
  local function char_for(pp, client)
    local params = type(pp) == "function" and pp(client) or pp
    return params.position.character
  end
  local pp = lsp._position_params("file:///x", posinfo, { { offset_encoding = "utf-16" } }, nil)
  if type(pp) == "function" then
    check(
      char_for(pp, { offset_encoding = "utf-16" }) == 7,
      "position_params encodes utf-16 per client (0.11+ function form)"
    )
    check(
      char_for(pp, { offset_encoding = "utf-8" }) == 9,
      "position_params encodes utf-8 per client (mixed-encoding safe)"
    )
  else
    check(char_for(pp, nil) == 7, "position_params bakes the primary client's encoding (0.10 fallback)")
  end
  local pp2 = lsp._position_params(
    "file:///x",
    { line0 = 3, byte_col = 0, text = "foo" },
    { { offset_encoding = "utf-16" } },
    { context = { includeDeclaration = true } }
  )
  local params2 = type(pp2) == "function" and pp2({ offset_encoding = "utf-16" }) or pp2
  check(
    params2.textDocument.uri == "file:///x" and params2.position.line == 3,
    "position_params sets textDocument + 0-based line"
  )
  check(
    params2.context and params2.context.includeDeclaration == true,
    "position_params merges extra request params (references context)"
  )

  -- documentSymbol formatting: hierarchical (with children) + flat siblings
  local hier = {
    {
      name = "Foo",
      kind = 5, -- Class
      range = { start = { line = 0, character = 0 } },
      selectionRange = { start = { line = 0, character = 6 } },
      children = {
        { name = "bar", kind = 6, selectionRange = { start = { line = 1, character = 2 } }, detail = "fun(a)" },
      },
    },
    { name = "baz", kind = 12, selectionRange = { start = { line = 9, character = 0 } } }, -- Function
  }
  local out = lsp._format_symbols("m.lua", hier, 60)
  check(out:find("m.lua — 3 symbols", 1, true), "format_symbols counts nested symbols")
  check(out:find("Class Foo  L1", 1, true), "format_symbols renders a top-level symbol with kind + line")
  check(out:find("  Method bar  L2  fun(a)", 1, true), "format_symbols indents children and shows their detail")
  check(out:find("Function baz  L10", 1, true), "format_symbols renders a flat sibling")
  check(lsp._format_symbols("x", {}, 60) == nil, "format_symbols returns nil when there are no symbols")

  local many = {}
  for i = 1, 80 do
    many[i] = { name = "s" .. i, kind = 12, selectionRange = { start = { line = i - 1, character = 0 } } }
  end
  check(
    lsp._format_symbols("m", many, 60):find("… +20 more symbol", 1, true),
    "format_symbols caps at max with a +N note"
  )

  -- location normalization + rendering (Location / LocationLink / list, deduped)
  local locroot = vim.fn.tempname()
  vim.fn.mkdir(locroot, "p")
  vim.fn.writefile({ "line one", "target line here", "third" }, locroot .. "/f.lua")
  local furi = vim.uri_from_fname(locroot .. "/f.lua")
  local locs = lsp._collect_locations({
    [1] = { result = { uri = furi, range = { start = { line = 1, character = 4 } } } }, -- single Location
    [2] = { result = { { uri = furi, range = { start = { line = 1, character = 4 } } } } }, -- duplicate in a list
    [3] = { result = { { targetUri = furi, targetSelectionRange = { start = { line = 2, character = 0 } } } } }, -- LocationLink
  })
  check(#locs == 2, "collect_locations normalizes Location/LocationLink/list and dedups")
  local ltxt = lsp._format_locations("references to x", locs, locroot, 60)
  check(ltxt:find("references to x — 2 results", 1, true), "format_locations headers the count")
  check(ltxt:find("f.lua:2:5  target line here", 1, true), "format_locations shows relpath:line:col + the line text")

  -- hover contents extraction across the three LSP shapes
  check(
    lsp._hover_text({ kind = "markdown", value = "**int** add(int)" }) == "**int** add(int)",
    "hover_text reads MarkupContent"
  )
  check(lsp._hover_text("plain string") == "plain string", "hover_text reads a MarkedString string")
  check(
    lsp._hover_text({ { language = "lua", value = "sig" }, "note" }) == "sig\nnote",
    "hover_text joins a MarkedString array"
  )
  check(lsp._hover_text({ value = "" }) == nil, "hover_text returns nil for empty contents")

  -- workspace symbol formatting (with and without a range)
  local ws = lsp._collect_ws({
    [1] = {
      result = {
        { name = "add", kind = 12, location = { uri = furi, range = { start = { line = 2, character = 0 } } } },
        { name = "addr", kind = 13, location = { uri = furi } }, -- WorkspaceSymbol without a range
      },
    },
  })
  check(#ws == 2, "collect_ws merges workspace symbols")
  local wtxt = lsp._format_ws("add", ws, locroot, 60)
  check(wtxt:find('workspace symbols for "add" — 2 matches', 1, true), "format_ws headers the query + count")
  check(wtxt:find("Function add  f.lua:3", 1, true), "format_ws renders a symbol with its location")
  check(wtxt:find("f.lua:?", 1, true), "format_ws tolerates a symbol with no range")

  -- project-first filtering: stdlib/dependency matches (outside root) are the
  -- dominant noise in a real workspace index — show project symbols, collapse
  -- the rest to a count so the model isn't buried under library hits.
  local ws_mixed = lsp._collect_ws({
    [1] = {
      result = {
        { name = "add", kind = 12, location = { uri = furi, range = { start = { line = 2, character = 0 } } } }, -- in project
        { name = "add", kind = 12, location = { uri = vim.uri_from_fname("/usr/include/stdlib.h") } }, -- external
        { name = "add", kind = 12, location = { uri = vim.uri_from_fname("/usr/lib/runtime.lua") } }, -- external
      },
    },
  })
  local wm = lsp._format_ws("add", ws_mixed, locroot, 60)
  check(wm:find("1 match in this project", 1, true), "format_ws shows in-project matches first, scoped")
  check(
    wm:find("+2 match", 1, true) and wm:find("external/stdlib", 1, true),
    "format_ws collapses external/stdlib matches to a count"
  )
  check(not wm:find("stdlib.h", 1, true), "format_ws hides the external symbol rows entirely (pure noise)")
  local ws_ext = lsp._collect_ws({
    [1] = { result = { { name = "q", kind = 12, location = { uri = vim.uri_from_fname("/usr/include/x.h") } } } },
  })
  local we = lsp._format_ws("q", ws_ext, locroot, 60)
  check(
    we:find('workspace symbols for "q" — 1 match', 1, true) and we:find("x.h", 1, true),
    "format_ws falls back to external matches when nothing is in-project"
  )
end

section("lsp navigation (tool flow, faked server)")
do
  local lsp = require("advantage.lsp")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local diagnostics = require("advantage.diagnostics")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)

  -- registration + gating
  local want = { document_symbols = 1, goto_definition = 1, find_references = 1, hover = 1, workspace_symbol = 1 }
  local in_schema = {}
  for _, s in ipairs(tools.schemas()) do
    if want[s.name] then in_schema[s.name] = true end
  end
  check(vim.tbl_count(in_schema) == 5, "all five LSP tools are in the schema when enabled")
  config.options.tools.lsp.enabled = false
  local any = false
  for _, s in ipairs(tools.schemas()) do
    if want[s.name] then any = true end
  end
  check(not any, "LSP tools are hidden when tools.lsp.enabled = false")
  config.options.tools.lsp.enabled = true

  -- read-only sub-agents inherit them (safe tools)
  local subagent = require("advantage.subagent")
  local sub_has = {}
  for _, s in ipairs(subagent._readonly_tools()) do
    if want[s.name] then sub_has[s.name] = true end
  end
  check(vim.tbl_count(sub_has) == 5, "LSP tools are available to read-only sub-agents")

  -- The system prompt STEERS the model toward these tools (this is what makes it
  -- PREFER them over its grep/read prior) — but only when they're actually live.
  local agent_mod = require("advantage.agent")
  check(agent_mod.lsp_guide() ~= nil, "lsp_guide is present when the tools are enabled")
  local sp_labels = {}
  for _, p in ipairs(agent_mod.system_prompt_parts(nil)) do
    sp_labels[p.label] = p.text
  end
  check(sp_labels["lsp guide"] ~= nil, "the system prompt includes an 'lsp guide' part when LSP is live")
  check(
    agent_mod.system_prompt(nil):find("goto_definition", 1, true) ~= nil,
    "the system prompt names the LSP tools so the model prefers them"
  )
  config.options.tools.lsp.enabled = false
  check(agent_mod.lsp_guide() == nil, "lsp_guide is nil (no steer) when the LSP tools are disabled")
  local off_has = false
  for _, p in ipairs(agent_mod.system_prompt_parts(nil)) do
    if p.label == "lsp guide" then off_has = true end
  end
  check(not off_has, "the system prompt omits the LSP steer when the tools are disabled (no dangling advice)")
  config.options.tools.lsp.enabled = true

  -- Full end-to-end tool flow with a FAKED language server: monkeypatch client
  -- discovery, the buffer loader, and the request seam so every tool runs
  -- deterministically in CI (no real server needed; clangd validates the wire
  -- shape separately in dev).
  local proot = vim.fn.tempname()
  vim.fn.mkdir(proot, "p")
  vim.fn.writefile({ "function add(a, b)", "  return a + b", "end", "", "local r = add(1, 2)" }, proot .. "/m.lua")
  local buf = vim.fn.bufadd(proot .. "/m.lua")
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "lua"
  local muri = vim.uri_from_bufnr(buf)

  local fake_client = {
    offset_encoding = "utf-16",
    server_capabilities = {
      documentSymbolProvider = true,
      definitionProvider = true,
      referencesProvider = true,
      hoverProvider = true,
      workspaceSymbolProvider = true,
    },
    attached_buffers = { [buf] = true },
  }
  local orig_get, orig_ensure, orig_req = vim.lsp.get_clients, diagnostics.ensure_bufnr, lsp._buf_request_all
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function()
    return { fake_client }
  end
  diagnostics.ensure_bufnr = function()
    return buf
  end
  lsp._buf_request_all = function(_, method, _, handler)
    local result
    if method == "textDocument/documentSymbol" then
      result = { { name = "add", kind = 12, selectionRange = { start = { line = 0, character = 9 } } } }
    elseif method == "textDocument/definition" then
      result = { { uri = muri, range = { start = { line = 0, character = 9 } } } }
    elseif method == "textDocument/references" then
      result = {
        { uri = muri, range = { start = { line = 0, character = 9 } } },
        { uri = muri, range = { start = { line = 4, character = 10 } } },
      }
    elseif method == "textDocument/hover" then
      result = { contents = { kind = "markdown", value = "function add(a, b): number" } }
    elseif method == "workspace/symbol" then
      result =
        { { name = "add", kind = 12, location = { uri = muri, range = { start = { line = 0, character = 9 } } } } }
    end
    handler({ [1] = { result = result } })
    return function() end
  end

  local ctx = { cwd = proot }
  local function run(name, input)
    local done, out, err = false, nil, nil
    tools.get(name).run(input, ctx, function(o, e)
      out, err, done = o, e, true
    end)
    vim.wait(3000, function()
      return done
    end, 10)
    return out, err
  end

  check(
    assert(run("document_symbols", { path = "m.lua" })):find("Function add  L1", 1, true),
    "document_symbols tool returns the outline"
  )
  local defout = assert(run("goto_definition", { path = "m.lua", line = 5, symbol = "add" }))
  check(
    defout:find("definition of add", 1, true) and defout:find("m.lua:1:10", 1, true),
    "goto_definition resolves a use to its definition"
  )
  check(
    assert(run("find_references", { path = "m.lua", line = 1, symbol = "add" })):find(
      "references to add — 2 results",
      1,
      true
    ),
    "find_references returns every call site"
  )
  check(
    assert(run("hover", { path = "m.lua", line = 1, symbol = "add" })):find("function add(a, b): number", 1, true),
    "hover returns the signature"
  )
  check(
    assert(run("workspace_symbol", { query = "add" })):find("Function add  m.lua:1", 1, true),
    "workspace_symbol finds the symbol by name"
  )
  check(
    assert(run("read_file", { path = "m.lua", outline = true })):find("Function add  L1", 1, true),
    "read_file outline=true delegates to the symbol layer"
  )

  local _, e_missing = run("goto_definition", { path = "m.lua", line = 2, symbol = "nonexistent_sym" })
  check(e_missing == true, "goto_definition errors when the symbol isn't found on or near the line")
  local _, e_escape = run("document_symbols", { path = "../escape.lua" })
  check(e_escape == true, "LSP tools reject a path outside the project root")

  vim.lsp.get_clients = orig_get
  diagnostics.ensure_bufnr = orig_ensure
  lsp._buf_request_all = orig_req
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

section("lsp request auto-retry (cold-start warming)")
do
  -- Real-world: the FIRST request to a freshly-opened large file times out while
  -- the server does its initial index; a retry (server now warm) is instant. The
  -- request layer auto-retries a TIMEOUT (never a hard error) instead of making
  -- the model burn a turn doing it by hand.
  local lsp = require("advantage.lsp")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local diagnostics = require("advantage.diagnostics")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  config.options.tools.lsp.timeout_ms = 80 -- keep the test fast
  config.options.tools.lsp.attach_grace_ms = 0
  config.options.tools.lsp.max_attempts = 2

  local proot = vim.fn.tempname()
  vim.fn.mkdir(proot, "p")
  vim.fn.writefile({ "local M = {}", "return M" }, proot .. "/r.lua")
  local buf = vim.fn.bufadd(proot .. "/r.lua")
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "lua"
  local fake_client = {
    offset_encoding = "utf-16",
    server_capabilities = { documentSymbolProvider = true },
    attached_buffers = { [buf] = true },
  }
  local orig_get, orig_ensure, orig_req = vim.lsp.get_clients, diagnostics.ensure_bufnr, lsp._buf_request_all
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function()
    return { fake_client }
  end
  diagnostics.ensure_bufnr = function()
    return buf
  end

  local ctx = { cwd = proot }
  local function run()
    local done, out, err = false, nil, nil
    tools.get("document_symbols").run({ path = "r.lua" }, ctx, function(o, e)
      out, err, done = o, e, true
    end)
    vim.wait(3000, function()
      return done
    end, 10)
    return out, err
  end

  -- first call never answers (still indexing → timeout), second answers (warm)
  local calls = 0
  lsp._buf_request_all = function(_, _, _, handler)
    calls = calls + 1
    if calls == 1 then
      return function() end
    end
    handler({
      [1] = { result = { { name = "M", kind = 2, selectionRange = { start = { line = 0, character = 6 } } } } },
    })
    return function() end
  end
  local out, err = run()
  check(calls == 2, "a timed-out LSP request auto-retries once")
  check(out and out:find("M", 1, true) and not err, "the retry returns the result (warm server), no error surfaced")

  -- exhausting all attempts reports a helpful timeout, not a crash
  calls = 0
  lsp._buf_request_all = function(_, _, _, _)
    calls = calls + 1
    return function() end
  end
  local out2, err2 = run()
  check(calls == 2, "a persistently-timing-out request stops after max_attempts")
  check(
    err2 == true and out2:find("didn't respond in time", 1, true),
    "exhausted retries surface a timeout message, not a crash"
  )

  vim.lsp.get_clients = orig_get
  diagnostics.ensure_bufnr = orig_ensure
  lsp._buf_request_all = orig_req
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

section("lsp usage nudge (fights system-prompt decay)")
do
  local lsp = require("advantage.lsp")
  local config = require("advantage.config")
  local tools = require("advantage.tools")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  local orig_get = vim.lsp.get_clients
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function()
    return { { name = "fake" } }
  end -- a server is "running"

  -- throttle + streak
  lsp.reset_session()
  check(
    lsp.explore_nudge() .. lsp.explore_nudge() .. lsp.explore_nudge() == "",
    "explore_nudge stays quiet below the grep/read streak threshold"
  )
  check(
    lsp.explore_nudge():find("language server is attached", 1, true) ~= nil,
    "explore_nudge fires after a grep/read streak while a server is up"
  )
  -- an LSP-tool use resets the streak (a navigating session never gets nudged)
  lsp.note_lsp_use()
  check(
    lsp.explore_nudge() == "" and lsp.explore_nudge() == "" and lsp.explore_nudge() == "",
    "note_lsp_use resets the streak"
  )
  check(lsp.explore_nudge() ~= "", "the streak fires again after the reset + 4 more probes")

  lsp.reset_session()
  local fires = 0
  for _ = 1, 40 do
    if lsp.explore_nudge() ~= "" then fires = fires + 1 end
  end
  check(fires == 3, "explore_nudge is throttled to a few fires per session (no spam)")

  -- never fires when no server is running (don't push tools that can't work)
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function()
    return {}
  end
  lsp.reset_session()
  local none = ""
  for _ = 1, 20 do
    none = none .. lsp.explore_nudge()
  end
  check(none == "", "explore_nudge never fires when no language server is running")

  -- integration: the nudge rides a grep result once the streak trips
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function()
    return { { name = "fake" } }
  end
  lsp.reset_session()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "alpha" }, tmp .. "/a.txt")
  local function grep()
    local done, out = false, nil
    tools.get("grep").run({ pattern = "alpha" }, { cwd = tmp }, function(o)
      out, done = o, true
    end)
    vim.wait(2000, function()
      return done
    end, 10)
    return out
  end
  local o1 = grep()
  grep()
  grep()
  local o4 = grep()
  check(not o1:find("language server is attached", 1, true), "a grep result carries no nudge below the streak")
  check(
    o4:find("language server is attached", 1, true) ~= nil,
    "a grep result carries the LSP nudge once the streak trips"
  )
  -- disabled → never nudges, even past the threshold
  config.options.tools.lsp.enabled = false
  lsp.reset_session()
  local dis = grep() .. grep() .. grep() .. grep() .. grep()
  check(not dis:find("language server is attached", 1, true), "no nudge when the LSP tools are disabled")

  vim.lsp.get_clients = orig_get
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
end

section("lsp no-server is visible to the user")
do
  -- The environmental cause of a silent grep-fallback (no server for this language)
  -- must surface to the USER, once per filetype — not just a message the model
  -- swallows. Reuses the diagnostics missing-server nudge.
  local tools = require("advantage.tools")
  local diagnostics = require("advantage.diagnostics")
  local config = require("advantage.config")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  local proot = vim.fn.tempname()
  vim.fn.mkdir(proot, "p")
  vim.fn.writefile({ "x" }, proot .. "/z.code")
  local buf = vim.fn.bufadd(proot .. "/z.code")
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "faketsx"
  local og, oe, osa, onf =
    vim.lsp.get_clients, diagnostics.ensure_bufnr, diagnostics.server_available_for_ft, diagnostics._notify_missing_ft
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function()
    return {}
  end
  diagnostics.ensure_bufnr = function()
    return buf
  end
  diagnostics.server_available_for_ft = function()
    return false
  end
  local notified
  diagnostics._notify_missing_ft = function(ft)
    notified = ft
  end
  local done, out = false, nil
  tools.get("document_symbols").run({ path = "z.code" }, { cwd = proot }, function(o)
    out, done = o, true
  end)
  vim.wait(2000, function()
    return done
  end, 10)
  check(
    out and out:find("No language server is attached", 1, true),
    "document_symbols tells the model no server is attached"
  )
  check(notified == "faketsx", "and surfaces a once-per-filetype 'install a server' nudge to the USER")

  vim.lsp.get_clients, diagnostics.ensure_bufnr, diagnostics.server_available_for_ft, diagnostics._notify_missing_ft =
    og, oe, osa, onf
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

section("lsp treesitter outline (works without the language server)")
do
  local lsp = require("advantage.lsp")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local diagnostics = require("advantage.diagnostics")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  lsp.reset_session()

  local proot = vim.fn.tempname()
  vim.fn.mkdir(proot, "p")
  vim.fn.writefile(
    { "local M = {}", "function M.foo(a)", "  return a", "end", "local function bar() end", "return M" },
    proot .. "/t.lua"
  )
  local buf = vim.fn.bufadd(proot .. "/t.lua")
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "lua"

  local flat = lsp.treesitter_symbols(buf)
  if not flat then
    print("  skip (no lua treesitter parser bundled in this Neovim)")
  else
    check(#flat >= 2, "treesitter_symbols extracts declarations from a real buffer")
    local names = {}
    for _, s in ipairs(flat) do
      names[s.name] = s.kind
    end
    check(
      names["M.foo"] == "Function" and names["bar"] == "Function",
      "treesitter_symbols names functions with their kinds"
    )

    -- document_symbols with NO LSP server attached still returns an outline,
    -- instantly, via treesitter (the fix for a server that won't answer nav)
    local og, oe = vim.lsp.get_clients, diagnostics.ensure_bufnr
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.lsp.get_clients = function()
      return {}
    end
    diagnostics.ensure_bufnr = function()
      return buf
    end
    local done, out, err = false, nil, nil
    tools.get("document_symbols").run({ path = "t.lua" }, { cwd = proot }, function(o, e)
      out, err, done = o, e, true
    end)
    vim.wait(3000, function()
      return done
    end, 10)
    check(
      out and out:find("Function M.foo", 1, true) and not err,
      "document_symbols returns a treesitter outline when no LSP server is attached"
    )
    vim.lsp.get_clients, diagnostics.ensure_bufnr = og, oe
  end

  lsp.reset_session()
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

section("lsp capability check (no request a client can't answer)")
do
  -- A diagnostics/lint-only client (eslint, none-ls, biome) is attached but does
  -- NOT provide navigation — firing documentSymbol/definition at it makes Neovim
  -- print "method not supported by any server". We must check capabilities first:
  -- document_symbols → treesitter; definition/hover → a clean message. No request.
  local lsp = require("advantage.lsp")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local diagnostics = require("advantage.diagnostics")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  lsp.reset_session()

  local proot = vim.fn.tempname()
  vim.fn.mkdir(proot, "p")
  vim.fn.writefile({ "local M = {}", "function M.foo() end", "return M" }, proot .. "/c.lua")
  local buf = vim.fn.bufadd(proot .. "/c.lua")
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "lua"

  if not lsp.treesitter_symbols(buf) then
    print("  skip (no lua treesitter parser)")
  else
    local lint_only =
      { initialized = true, offset_encoding = "utf-16", server_capabilities = {}, attached_buffers = { [buf] = true } }
    local og, oe, oreq = vim.lsp.get_clients, diagnostics.ensure_bufnr, lsp._buf_request_all
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.lsp.get_clients = function()
      return { lint_only }
    end
    diagnostics.ensure_bufnr = function()
      return buf
    end
    local requested = false
    lsp._buf_request_all = function()
      requested = true
      return function() end
    end
    local function run(name, input)
      local done, out = false, nil
      tools.get(name).run(input, { cwd = proot }, function(o)
        out, done = o, true
      end)
      vim.wait(2000, function()
        return done
      end, 10)
      return out
    end

    local ds = run("document_symbols", { path = "c.lua" })
    check(
      ds:find("Function M.foo", 1, true) and not requested,
      "document_symbols uses treesitter (never requests) when the client can't do documentSymbol"
    )
    requested = false
    local defout = run("goto_definition", { path = "c.lua", line = 2, symbol = "foo" })
    check(
      not requested and defout:find("provides definition", 1, true),
      "goto_definition reports cleanly (never requests) when the client lacks definitionProvider"
    )

    vim.lsp.get_clients, diagnostics.ensure_bufnr, lsp._buf_request_all = og, oe, oreq
  end
  lsp.reset_session()
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

section("lsp nav-timeout latch (fail fast, recover on warm-up)")
do
  -- A server that serves diagnostics but times out on navigation (tsserver mid-load)
  -- shouldn't cost the full timeout on every nav call. After repeated timeouts the
  -- latch trips and further nav short-circuits to a fast grep/read fallback — but a
  -- periodic re-probe recovers navigation if the server later warms up.
  local lsp = require("advantage.lsp")
  local tools = require("advantage.tools")
  local config = require("advantage.config")
  local diagnostics = require("advantage.diagnostics")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  config.options.tools.lsp.timeout_ms = 60
  config.options.tools.lsp.attach_grace_ms = 0
  config.options.tools.lsp.max_attempts = 1
  lsp.reset_session()

  local proot = vim.fn.tempname()
  vim.fn.mkdir(proot, "p")
  vim.fn.writefile({ "x" }, proot .. "/n.lua")
  local buf = vim.fn.bufadd(proot .. "/n.lua")
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "lua"
  local fake_client = {
    initialized = true,
    offset_encoding = "utf-16",
    server_capabilities = { documentSymbolProvider = true },
    attached_buffers = { [buf] = true },
  }
  local og, oe, oreq = vim.lsp.get_clients, diagnostics.ensure_bufnr, lsp._buf_request_all
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function()
    return { fake_client }
  end
  diagnostics.ensure_bufnr = function()
    return buf
  end

  local calls, answering = 0, false
  lsp._buf_request_all = function(_, _, _, handler)
    calls = calls + 1
    if answering then
      handler({
        [1] = { result = { { name = "M", kind = 12, selectionRange = { start = { line = 0, character = 0 } } } } },
      })
    end
    return function() end
  end
  local function ds()
    local done, out = false, nil
    tools.get("document_symbols").run({ path = "n.lua" }, { cwd = proot }, function(o)
      out, done = o, true
    end)
    vim.wait(2000, function()
      return done
    end, 10)
    return out
  end

  ds()
  ds() -- two navigation timeouts
  check(lsp._nav_latched(), "the nav latch trips after repeated navigation timeouts")
  local before = calls
  local out3 = ds()
  check(calls == before, "a latched nav call skips the request entirely (no wasted timeout)")
  check(out3:find("Skipping navigation", 1, true) ~= nil, "a latched nav call returns a fast grep/read fallback")

  -- the server warms up; the periodic re-probe recovers navigation
  answering = true
  local recovered = ds() .. ds() .. ds()
  check(recovered:find("Function M", 1, true) ~= nil, "a periodic re-probe recovers navigation once the server answers")
  check(not lsp._nav_latched(), "a successful re-probe clears the latch")

  vim.lsp.get_clients, diagnostics.ensure_bufnr, lsp._buf_request_all = og, oe, oreq
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp)
  lsp.reset_session()
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- 4-grep. grep output modes ----------------------------------------------------

section("grep output modes")
do
  local tools = require("advantage.tools")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "alpha match", "beta", "alpha again" }, tmp .. "/a.txt")
  vim.fn.writefile({ "alpha only here" }, tmp .. "/b.txt")
  local ctx = { cwd = tmp }
  local function run(input)
    local done, out, err = false, nil, nil
    tools.get("grep").run(input, ctx, function(o, e)
      out, err, done = o, e, true
    end)
    vim.wait(3000, function()
      return done
    end, 10)
    return out, err
  end

  local content = assert(run({ pattern = "alpha", output_mode = "content" }))
  check(content:find("a.txt") and content:find("alpha match"), "grep content mode returns file:line:text")
  local files = assert(run({ pattern = "alpha", output_mode = "files_with_matches" }))
  check(
    files:find("a.txt") and files:find("b.txt") and not files:find("alpha match"),
    "grep files_with_matches returns paths only"
  )
  local counts = assert(run({ pattern = "alpha", output_mode = "count" }))
  check(counts:find("a.txt") and counts:match("a%.txt[^\n]*2"), "grep count mode reports per-file match counts")
  local head = assert(run({ pattern = "alpha", head_limit = 1 }))
  check(head:find("more line", 1, true), "grep head_limit caps output with a +N note")
  check(
    assert(run({ pattern = "ALPHA", ignore_case = true })):find("alpha", 1, true),
    "grep ignore_case matches case-insensitively"
  )
  check(assert(run({ pattern = "zzzznomatch" })):find("No matches", 1, true), "grep reports no matches cleanly")
end

-- 4-ext. public extension surface ---------------------------------------------

section("extension registry")
do
  local extensions = require("advantage.extensions")
  local tools = require("advantage.tools")
  local harness = require("advantage.harness")
  local agent_mod = require("advantage.agent")
  local baseline_schema = vim.json.encode(tools.schemas())
  local baseline_prompt = agent_mod.base_system_prompt("/tmp/extension-root")
  local loads = 0
  local extension_spec = function()
    loads = loads + 1
  end
  check(#extensions.load({ extension_spec }) == 0, "configured extension setup functions load without errors")
  extensions.load({ extension_spec })
  check(loads == 1, "configured extensions load once across repeated setup calls")
  local dispose_tool = extensions.api.register_tool({
    name = "extension_probe",
    description = "Test-only extension probe",
    safe = true,
    input_schema = { type = "object", properties = {}, additionalProperties = false },
    run = function(_, _, cb)
      cb("ok", false)
    end,
  })
  local dispose_provider = extensions.api.register_provider("extension_probe", {
    stream = function()
      return { stop = function() end }
    end,
  })
  local dispose_harness = extensions.api.register_harness("focused_test", {
    label = "focused test",
    description = "Focused extension policy.",
    effort = "medium",
    proactive = false,
    parallel = false,
    max_parallel = 1,
    guide = "Extension-specific verification rule.",
  })
  local builds = 0
  local dispose_prompt = extensions.api.register_prompt_part("test extension", function(ctx)
    builds = builds + 1
    return "Extension prompt for " .. ctx.cwd
  end)

  check(tools.get("extension_probe") ~= nil, "extensions can register provider-visible tools")
  check(require("advantage.providers").get("extension_probe") ~= nil, "extensions can register providers")
  check(harness.valid("focused_test"), "extensions can register harness modes")
  check(
    harness.guide("focused_test", { provider = "fake", id = "m" }):find("Extension-specific", 1, true) ~= nil,
    "custom harness guidance composes with core guardrails"
  )
  local base = agent_mod.base_system_prompt("/tmp/extension-root")
  check(
    builds == 1 and base:find("Extension prompt for /tmp/extension-root", 1, true),
    "extension prompt builders compose into the session-frozen base prompt"
  )
  check(
    dispose_prompt() and dispose_harness() and dispose_provider() and dispose_tool(),
    "extension registrations return clean reload disposers"
  )
  check(
    tools.get("extension_probe") == nil
      and require("advantage.providers").get("extension_probe") == nil
      and not harness.valid("focused_test"),
    "disposing an extension restores the baseline registries"
  )
  check(
    vim.json.encode(tools.schemas()) == baseline_schema
      and agent_mod.base_system_prompt("/tmp/extension-root") == baseline_prompt,
    "the unloaded extension leaves baseline prompt and schema bytes unchanged"
  )
end

-- 4-sub. sub-agent lean context (no memory leak, capped report) ----------------

section("sub-agent lean context")
do
  local providers = require("advantage.providers")
  local tools = require("advantage.tools")
  local agent_mod = require("advantage.agent")
  local config = require("advantage.config")
  config.options.tools.lsp = vim.deepcopy(config.defaults.tools.lsp) -- ensure LSP steer is live

  -- base_system_prompt is the base instructions ONLY — no memory guide/block
  local base = agent_mod.base_system_prompt()
  check(base:find("expert coding agent", 1, true) ~= nil, "base_system_prompt keeps the base instructions")
  check(not base:find("Persistent repo memory", 1, true), "base_system_prompt omits the memory guide")

  local big = string.rep("x report ", 4000) -- ~36k chars, over the 16k report cap
  local seen_system
  providers.register("fakesublean", {
    stream = function(req)
      seen_system = req.system
      vim.defer_fn(function()
        req.on.complete({ { type = "text", text = big } }, "end_turn")
      end, 5)
      return { stop = function() end }
    end,
  })
  local ctx = { cwd = vim.fn.tempname(), system = "PARENT-SYSTEM-WITH-MEMORY-BLOCK-XYZ" }
  vim.fn.mkdir(ctx.cwd, "p")
  local done, result = false, nil
  tools
    .get("sub_agent")
    .run({ prompt = "scout the thing", model = "fakesublean/m", effort = "medium" }, ctx, function(out)
      result, done = out, true
    end)
  vim.wait(3000, function()
    return done
  end, 10)
  check(
    seen_system and not seen_system:find("PARENT-SYSTEM-WITH-MEMORY-BLOCK-XYZ", 1, true),
    "sub-agent ignores the parent's memory-laden system prompt"
  )
  check(seen_system and seen_system:find("read-only sub-agent", 1, true), "sub-agent gets the read-only role prompt")
  check(
    seen_system and not seen_system:find("Persistent repo memory", 1, true),
    "sub-agent system omits the repo memory guide/block"
  )
  check(
    seen_system and seen_system:find("Semantic code navigation", 1, true),
    "sub-agent still gets the LSP navigation steer (scouts navigate code too)"
  )
  check(
    result and #result < #big and result:find("report truncated", 1, true),
    "an oversized sub-agent report is capped before it reaches the parent transcript"
  )
end

print("")
if failed > 0 then
  print(("SMOKE FAILED — %d check(s)"):format(failed))
  os.exit(1)
else
  print("SMOKE PASSED")
  os.exit(0)
end
