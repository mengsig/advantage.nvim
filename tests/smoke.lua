-- Headless smoke test: nvim -l tests/smoke.lua
-- Exercises the SSE parser, both provider adapters, the tools, and a full
-- agent turn (with a scripted fake provider) including the UI.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)

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
end

-- 2. anthropic handler --------------------------------------------------------

section("anthropic stream handler")
do
  local anthropic = require("advantage.providers.anthropic")
  local got = { text = {}, thinking = {}, tools = {} }
  local final
  local handler = anthropic._make_handler({
    text = function(t) got.text[#got.text + 1] = t end,
    thinking = function(t) got.thinking[#got.thinking + 1] = t end,
    tool_start = function(id, name) got.tools[#got.tools + 1] = { id, name } end,
    usage = function(i, o) got.usage = { i, o } end,
    complete = function(blocks, stop, usage) final = { blocks = blocks, stop = stop, usage = usage } end,
    error = function(msg) got.err = msg end,
  })
  local feed = {
    { type = "message_start", message = { usage = { input_tokens = 12, cache_read_input_tokens = 3 } } },
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
  check(final.blocks[1].type == "thinking" and final.blocks[1].signature == "sig", "thinking block with signature preserved")
  check(final.blocks[2].type == "text" and final.blocks[2].text == "let me check", "text block accumulated")
  check(final.blocks[3].type == "tool_use" and final.blocks[3].input.command == "ls", "tool_use input json assembled")
  check(got.usage[1] == 15 and got.usage[2] == 55, "usage reported")
end

-- 3. openai handler -----------------------------------------------------------

section("openai stream handler")
do
  local openai = require("advantage.providers.openai")
  local got = { text = {}, tools = {} }
  local final
  local handler = openai._make_handler({
    text = function(t) got.text[#got.text + 1] = t end,
    thinking = function() end,
    tool_start = function(id, name) got.tools[#got.tools + 1] = { id, name } end,
    usage = function(i, o) got.usage = { i, o } end,
    complete = function(blocks, stop, usage) final = { blocks = blocks, stop = stop, usage = usage } end,
    error = function(msg) got.err = msg end,
  })
  local feed = {
    { type = "response.output_item.added", item = { type = "reasoning", id = "rs_1" } },
    { type = "response.output_item.done", item = { type = "reasoning", id = "rs_1", encrypted_content = "xxx" } },
    { type = "response.output_item.added", item = { type = "function_call", id = "fc_1", call_id = "call_1", name = "read_file" } },
    { type = "response.function_call_arguments.delta", item_id = "fc_1", delta = '{"path":' },
    { type = "response.output_item.done", item = { type = "function_call", id = "fc_1", call_id = "call_1", name = "read_file", arguments = '{"path":"a.lua"}' } },
    { type = "response.output_text.delta", delta = "on it" },
    { type = "response.output_item.done", item = { type = "message", content = { { type = "output_text", text = "on it" } } } },
    { type = "response.completed", response = { usage = { input_tokens = 9, output_tokens = 21 } } },
  }
  for _, ev in ipairs(feed) do
    handler(ev.type, ev)
  end
  check(final ~= nil and final.stop == "tool_use", "tool_use stop inferred")
  check(final.blocks[1].type == "openai_reasoning", "reasoning item captured for replay")
  check(final.blocks[2].type == "tool_use" and final.blocks[2].input.path == "a.lua", "function_call → tool_use")
  check(final.blocks[3].type == "text" and final.blocks[3].text == "on it", "message → text block")
  check(got.usage[1] == 9 and got.usage[2] == 21, "usage reported")

  local items = openai._to_input_items({
    { role = "user", content = { { type = "tool_result", tool_use_id = "missing", content = "orphan" } } },
    { role = "assistant", content = { { type = "tool_use", id = "call_ok", name = "bash", input = { command = "true" } } } },
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
    { role = "user", content = { { type = "text", text = require("advantage.compact")._SUMMARY_PREFIX .. "\nold context" } } },
    { role = "assistant", content = {
      { type = "openai_reasoning", item = { type = "reasoning", encrypted_content = "stale" } },
      { type = "tool_use", id = "call_after", openai_item_id = "fc_stale", name = "read_file", input = { path = "a" } },
    } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_after", content = "ok" } } },
  })
  local reasoning, id_leaks = 0, 0
  for _, item in ipairs(items) do
    if item.type == "reasoning" then reasoning = reasoning + 1 end
    if item.type == "function_call" and item.id then id_leaks = id_leaks + 1 end
  end
  check(reasoning == 0, "openai drops encrypted reasoning after compaction")
  check(id_leaks == 0, "openai detaches stored function_call ids after compaction")

  -- compaction itself must strip the item id from retained tool calls so the
  -- Responses API doesn't demand the reasoning item we removed.
  local compact = require("advantage.compact")
  local reasoned = {
    { role = "user", content = { { type = "text", text = "look" } } },
    { role = "assistant", content = {
      { type = "openai_reasoning", item = { type = "reasoning", encrypted_content = "x" } },
      { type = "tool_use", id = "call_keep2", openai_item_id = "fc_keep", name = "read_file", input = { path = "a" } },
    } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_keep2", content = string.rep("r ", 100) } } },
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
    vim.wait(5000, function() return done end, 10)
    return result, is_err
  end

  local r = run("write_file", { path = "x/hello.txt", content = "alpha\nbeta\ngamma\n" })
  check(r:find("Wrote 4 lines"), "write_file creates nested file")

  r = run("read_file", { path = "x/hello.txt" })
  check(r:find("1→alpha") and r:find("3→gamma"), "read_file returns numbered lines")

  r = run("edit_file", { path = "x/hello.txt", old_string = "beta", new_string = "BETA" })
  check(r:find("Applied 1 replacement"), "edit_file replaces unique string")

  local _, err = run("edit_file", { path = "x/hello.txt", old_string = "nope", new_string = "x" })
  check(err == true, "edit_file errors on missing old_string")

  r = run("bash", { command = "echo out; echo err >&2; exit 3" })
  check(r:find("out") and r:find("err") and r:find("exit code 3"), "bash merges output + exit code")

  r = run("grep", { pattern = "BETA", path = "." })
  check(r:find("hello.txt") ~= nil, "grep finds matches")

  r = run("list_dir", { path = "x" })
  check(r:find("hello.txt"), "list_dir lists entries")

  local preview = tools.get("edit_file").preview({ path = "x/hello.txt", old_string = "BETA", new_string = "b" }, ctx)
  local joined = table.concat(preview.lines, "\n")
  check(preview.filetype == "diff" and joined:find("-BETA") and joined:find("+b"), "edit preview is a unified diff")

  _, err = run("edit_file", { path = "x/hello.txt", old_string = "", new_string = "x", replace_all = true })
  check(err == true, "edit_file rejects empty old_string (no freeze)")
  local p2 = tools.get("edit_file").preview({ path = "x/hello.txt", old_string = "", new_string = "x", replace_all = true }, ctx)
  check(p2.lines[1]:find("invalid edit") ~= nil, "edit preview rejects empty old_string (no freeze)")
  -- optional streaming bash output reports partial chunks before the final result
  local streams = {}
  done, result, is_err = false, nil, nil
  local h = tools.get("bash").run({ command = "printf one; sleep 0.05; printf two", stream = true }, ctx, function(out, err, meta)
    if meta and meta.stream then
      streams[#streams + 1] = out
    else
      result, is_err, done = out, err, true
    end
  end)
  check(type(h) == "table" and h.stop ~= nil, "bash returns a cancellable handle")
  vim.wait(5000, function() return done end, 10)
  check(#streams >= 1 and result:find("one") and result:find("two") and not is_err, "bash can stream partial output")

  -- cancellation stops a running command and reports an error final result
  done, result, is_err = false, nil, nil
  h = tools.get("bash").run({ command = "sleep 5; echo too-late", timeout_ms = 10000 }, ctx, function(out, err)
    result, is_err, done = out, err, true
  end)
  h.stop()
  vim.wait(5000, function() return done end, 10)
  check(is_err == true and result:find("cancelled", 1, true), "bash cancellation stops the command")
end

-- 4a. context compaction ---------------------------------------------------------

section("context compaction")
do
  local compact = require("advantage.compact")
  local messages = {}
  for i = 1, 24 do
    messages[#messages + 1] = { role = i % 2 == 0 and "assistant" or "user", content = { { type = "text", text = ("message %02d "):format(i) .. string.rep("x", 120) } } }
  end
  local out, info = compact.compact(messages, { compact_at_tokens = 100, keep_recent_messages = 6, summary_max_chars = 2000 })
  check(info and info.compacted_messages == 18, "compacts old messages when threshold is crossed")
  check(out[1].content[1].text:find(compact._SUMMARY_PREFIX, 1, true), "summary prepended")
  check(out[#out].content[1].text:find("message 24", 1, true), "recent messages kept verbatim")
  -- Roles must strictly alternate; the summary must never sit directly before
  -- another user turn (Anthropic 400s on consecutive same-role messages).
  local prev_role
  local alternates = true
  for _, m in ipairs(out) do
    if m.role == prev_role then alternates = false end
    prev_role = m.role
  end
  check(alternates, "compacted messages keep alternating roles")

  local ok_empty = pcall(function()
    compact.force(nil, { keep_recent_messages = 6 })
  end)
  check(ok_empty, "manual compact tolerates an empty conversation")

  local odd = {
    "legacy raw message",
    { role = "user", content = "legacy string content" },
  }
  for i = 1, 8 do
    odd[#odd + 1] = { role = i % 2 == 0 and "assistant" or "user", content = { { type = "text", text = "recent " .. i } } }
  end
  local paired = {
    { role = "user", content = { { type = "text", text = "please inspect" } } },
    { role = "assistant", content = { { type = "tool_use", id = "call_keep", name = "read_file", input = { path = "a" } } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "call_keep", content = string.rep("result ", 100) } } },
    { role = "assistant", content = {
      { type = "openai_reasoning", item = { type = "reasoning", encrypted_content = "stale" } },
      { type = "text", text = string.rep("final ", 100) },
    } },
  }
  local paired_out = select(1, compact.force(paired, { keep_recent_messages = 2, summary_max_chars = 1000 }))
  check(#paired_out == 4 and paired_out[2].content[1].type == "tool_use",
    "compact does not orphan a recent tool_result from its tool_use")
  check(paired_out[4].content[1].type == "text", "compact strips stale OpenAI reasoning from retained messages")

  local ok_odd, odd_out = pcall(function()
    return compact.force(odd, { keep_recent_messages = 4, summary_max_chars = 2000 })
  end)
  check(ok_odd and odd_out and odd_out[1].content[1].text:find("legacy raw message", 1, true), "compact tolerates legacy/malformed message shapes")
end

-- 4b. sub-agent tool -------------------------------------------------------------

section("sub-agent")
do
  local providers = require("advantage.providers")
  local tools = require("advantage.tools")
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
  tools.get("sub_agent").run({ prompt = "inspect note", model = "fakesub/model", max_turns = 4 }, {
    cwd = tmp,
    model = { provider = "fakesub", id = "model", label = "fake sub" },
  }, function(out, is_err)
    result, err, done = out, is_err, true
  end)
  vim.wait(5000, function() return done end, 10)
  check(turn == 2 and saw_tool_result, "sub-agent can use read-only tools in its own loop")
  check(err == false and result:find("subagent evidence", 1, true), "sub-agent returns final report")
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

-- 5. agent e2e with a fake provider + UI ----------------------------------------

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
  check(text:find("● bash", 1, true) ~= nil, "tool card rendered with ok status")
  check(text:find("agent%-was%-here") ~= nil, "final answer rendered")

  -- transcript shape: user, assistant(tool_use), user(tool_result), assistant(text)
  -- (accessible via the session that autosave wrote)
  local sessions = require("advantage.session").list()
  check(#sessions >= 1, "session autosaved")
  local msgs = sessions[1].messages
  check(#msgs == 4, "conversation has 4 messages")
  check(msgs[2].content[2].type == "tool_use", "assistant tool_use recorded")
  check(msgs[3].content[1].type == "tool_result" and msgs[3].content[1].content:find("agent%-was%-here") ~= nil,
    "tool_result captured bash output")
  local public_ok = pcall(function() adv.compact() end)
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
    return ui.state.status == "idle" and ui.state.queue_count == 0
      and text:find("▍ you", text:find("second queued test", 1, true) or 1, true) ~= nil
  end, 25)

  local text = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
  check(text:find("queued #1", 1, true) ~= nil, "queue notice rendered")
  check(text:find("first queued test", 1, true) ~= nil and text:find("second queued test", 1, true) ~= nil,
    "queued message dispatched after the running turn")
  check(ui.state.queue_count == 0, "queue drained")
end

-- 7. enter interrupt --------------------------------------------------------------

section("enter interrupt")
do
  local providers = require("advantage.providers")
  local agent_mod = require("advantage.agent")
  local ui = require("advantage.ui.chat")
  local turn, stopped, seen = 0, false, nil
  providers.register("fakeinterrupt", {
    stream = function(req)
      turn = turn + 1
      if turn == 2 then seen = req.messages end
      local on = req.on
      vim.defer_fn(function()
        if turn == 1 then
          on.text("I may need a command.")
          on.tool_start("tu_interrupt", "bash")
          on.complete({
            { type = "text", text = "I may need a command." },
            { type = "tool_use", id = "tu_interrupt", name = "bash", input = { command = "echo should-not-run" } },
          }, "tool_use")
        else
          on.text("Adjusted before running the tool.")
          on.complete({ { type = "text", text = "Adjusted before running the tool." } }, "end_turn")
        end
      end, turn == 1 and 30 or 10)
      return { stop = function() stopped = true end }
    end,
  })

  local ag = agent_mod.new({ model = { provider = "fakeinterrupt", id = "m", label = "m" } })
  ag:send("first")
  vim.defer_fn(function() ag:send("second before tool") end, 5)
  vim.wait(8000, function() return turn >= 2 and ui.state.status == "idle" end, 25)

  check(stopped == false, "enter while running does not cancel the stream")
  check(turn == 2, "interrupt triggered a follow-up model turn")
  check(seen and seen[3] and seen[3].role == "user", "interrupt inserted tool-result turn before follow-up")
  check(seen and seen[3] and seen[3].content[1].type == "tool_result" and seen[3].content[1].is_error == true,
    "pending tool was skipped with a tool_result")
  check(seen and seen[4] and seen[4].role == "user" and seen[4].content[1].type == "text" and seen[4].content[1].text:find("second before tool", 1, true),
    "interrupt text sent as its own user turn")

  require("advantage.config").options.tools.auto_approve = {}
  local wait_turn, wait_seen = 0, nil
  providers.register("fakewaitinterrupt", {
    stream = function(req)
      wait_turn = wait_turn + 1
      if wait_turn == 2 then wait_seen = req.messages end
      local on = req.on
      vim.defer_fn(function()
        if wait_turn == 1 then
          on.tool_start("tu_wait_interrupt", "bash")
          on.complete({
            { type = "tool_use", id = "tu_wait_interrupt", name = "bash", input = { command = "echo should-not-run" } },
          }, "tool_use")
        else
          on.text("Continued after permission interrupt.")
          on.complete({ { type = "text", text = "Continued after permission interrupt." } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })
  local ag_wait = agent_mod.new({ model = { provider = "fakewaitinterrupt", id = "m", label = "m" } })
  ag_wait:send("needs permission")
  vim.wait(8000, function() return ui.state.status == "waiting" end, 25)
  ag_wait:send("interrupt permission")
  vim.wait(8000, function() return wait_turn >= 2 and ui.state.status == "idle" end, 25)
  check(wait_turn == 2, "enter while permission is waiting skips the pending tool")
  check(wait_seen and wait_seen[3] and wait_seen[3].content[1].type == "tool_result"
      and wait_seen[3].content[1].content:find("Tool skipped", 1, true),
    "permission interrupt sends skipped tool_result")
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
end

-- 9. attachments / @mentions -------------------------------------------------------

section("attachments / mentions")
do
  local attach = require("advantage.attach")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "hello", "world" }, tmp .. "/ctx.txt")

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
  check(clamped:find("four\nfive", 1, true) ~= nil and clamped:find("L4-5", 1, true) ~= nil, "range clamped to file length")

  local listed = attach.project_files(50)
  check(type(listed) == "table" and #listed > 0, "project files listed for @completion")
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
  chat.confirm = function(_, cb)
    confirm_called = true
    cb("deny")
  end

  -- yolo: write_file is NOT auto-approved, but must run without a card
  providers.register("fakeyolo", file_writer(tmp .. "/yolo.txt"))
  config.options.tools.yolo = true
  local ag = agent_mod.new({ model = { provider = "fakeyolo", id = "m", label = "m" } })
  ag:send("write it")
  vim.wait(5000, function() return ag.status == "idle" end, 10)
  check(not confirm_called, "yolo skips the permission card")
  check(vim.fn.filereadable(tmp .. "/yolo.txt") == 1, "tool executed under yolo")
  check(ag.snapshots[vim.fs.normalize(tmp .. "/yolo.txt")] == false, "new-file snapshot recorded")
  config.options.tools.yolo = false

  local items = require("advantage.review")._changes(ag)
  check(#items == 1 and items[1].new and items[1].after:find("yolo file", 1, true) ~= nil,
    "review collects the agent's change")

  -- deny with comment: feedback must reach the tool_result
  providers.register("fakedeny", file_writer(tmp .. "/deny.txt"))
  chat.confirm = function(_, cb)
    cb("deny", "use a different name")
  end
  local ag2 = agent_mod.new({ model = { provider = "fakedeny", id = "m", label = "m" } })
  ag2:send("write it")
  vim.wait(5000, function() return ag2.status == "idle" end, 10)
  chat.confirm = orig_confirm
  check(vim.fn.filereadable(tmp .. "/deny.txt") == 0, "denied tool did not run")
  local forwarded = false
  for _, msg in ipairs(ag2.messages) do
    for _, b in ipairs(msg.content) do
      if b.type == "tool_result" and type(b.content) == "string"
        and b.content:find("use a different name", 1, true) then
        forwarded = true
      end
    end
  end
  check(forwarded, "deny comment forwarded to the model")
end

print("")
if failed > 0 then
  print(("SMOKE FAILED — %d check(s)"):format(failed))
  os.exit(1)
else
  print("SMOKE PASSED")
  os.exit(0)
end
