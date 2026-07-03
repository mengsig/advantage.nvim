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
end

-- 4b. auth handles null-bearing credential files -------------------------------

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
end

print("")
if failed > 0 then
  print(("SMOKE FAILED — %d check(s)"):format(failed))
  os.exit(1)
else
  print("SMOKE PASSED")
  os.exit(0)
end
