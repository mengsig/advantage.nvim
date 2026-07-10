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

  local function has_web_search()
    for _, s in ipairs(tools.schemas()) do
      if s.name == "web_search" then return true end
    end
    return false
  end

  check(not has_web_search(), "web_search is hidden from the schema without an API key")
  wcfg.api_key = "test-key"
  check(has_web_search(), "web_search appears once an API key is configured")

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
  fake_curl(dir1, { "#!/usr/bin/env bash", "cat <<'JSON'", body, "JSON", "exit 0" })
  local out1, err1 = run_with_path(dir1, function(cb)
    run({ query = "neovim release notes", count = 2 }, ctx, cb)
  end)
  check(err1 == nil or err1 == false, "happy-path web_search reports success")
  local out1s = assert(out1)
  check(out1s:find("Neovim 0.11 released", 1, true) ~= nil, "HTML tags stripped from the title")
  check(out1s:find("Big & small changes", 1, true) ~= nil, "HTML entities decoded in the description")
  check(out1s:find("https://neovim.io/a", 1, true) ~= nil, "result URL is included")
  check(out1s:find("Third result", 1, true) == nil, "results capped at the requested count")

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
    local sub_has = false
    for _, s in ipairs(sub_tools) do
      if s.name == "web_search" then sub_has = true end
    end
    check(sub_has, "web_search is available to read-only sub-agents")
  end

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

  -- agent-level path: Agent:compact({mode="llm"}) end-to-end. A message sent
  -- mid-compaction has no "next tool call" to inject before, so it is refused
  -- (not queued, not appended) — the user retries once compaction settles.
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
    check(#ag.queue == 0, "a message sent mid-compaction is refused, not queued")
    check(#ag.messages == 10, "a message sent mid-compaction is not appended to the transcript")

    vim.wait(2000, function()
      return ag.status == "idle"
    end, 5)
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
  local bad_model_result, bad_model_error
  require("advantage.subagent").run({ prompt = "inspect", model = "not-a-ref" }, {
    cwd = vim.uv.cwd(),
    model = { provider = "fakesub", id = "model", label = "fake sub" },
  }, function(out, is_error)
    bad_model_result, bad_model_error = out, is_error
  end)
  check(
    bad_model_error == true and tostring(bad_model_result):find("Invalid sub-agent model ref", 1, true),
    "an invalid explicit scout model never silently falls back to the parent"
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
  tools.get("sub_agent").run({ prompt = "inspect note", model = "fakesub/model", max_turns = 4 }, {
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
  tools.get("sub_agent").run({ prompt = "bug-hunt note.txt", model = "fakesublimit/model", max_turns = 3 }, {
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
    result ~= nil and result:find("FINAL REPORT", 1, true) and result:find("note.txt:1", 1, true),
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
  tools.get("sub_agent").run({ prompt = "x", model = "fakesubdefiant/model", max_turns = 3 }, {
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
  tools.get("sub_agent").run({ prompt = "x", model = "fakesubfloor/model", max_turns = 1 }, {
    cwd = tmp,
    model = { provider = "fakesubfloor", id = "model", label = "fake" },
  }, function()
    done3 = true
  end)
  vim.wait(5000, function()
    return done3
  end, 10)
  check(turns3 == 2, "max_turns=1 is floored to 2 (one investigation turn + one report turn)")
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

  local sol = assert(config.resolve_model("openai/gpt-5.6-sol"))
  local luna = assert(config.resolve_model("openai/gpt-5.6-luna"))
  local chatgpt_sol = effort.openai_levels(sol, "chatgpt")
  local api_sol = effort.openai_levels(sol, "api_key")
  check(
    vim.tbl_contains(chatgpt_sol, "ultra") and not vim.tbl_contains(chatgpt_sol, "none"),
    "ChatGPT-login Sol exposes subscription-native ultra but not raw-API none"
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
    sol_login == "ultra"
      and sol_login_err == nil
      and luna_login == "max"
      and luna_login_err == nil
      and gpt55_login == "xhigh"
      and gpt55_login_err == nil
      and sol_api == "max"
      and sol_api_err == nil,
    "inherited provider ultra clamps to each model/transport maximum without weakening Sol login"
  )
  local explicit_api_sol = vim.deepcopy(sol)
  explicit_api_sol.reasoning_effort = "ultra"
  local explicit_value, explicit_err = effort.resolve_openai(explicit_api_sol, "api_key", "ultra")
  check(
    explicit_value == nil and type(explicit_err) == "string" and explicit_err:find("explicit model override", 1, true),
    "an explicit unsupported per-model effort remains an error instead of being clamped"
  )

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
    return turn >= 2 and ui.state.status == "idle"
  end, 25)

  check(stopped == false, "enter while running does not cancel the stream")
  check(turn == 2, "interrupt triggered a follow-up model turn")
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
  vim.wait(8000, function()
    return ui.state.status == "waiting"
  end, 25)
  ag_wait:send("interrupt permission")
  vim.wait(8000, function()
    return wait_turn >= 2 and ui.state.status == "idle"
  end, 25)
  check(wait_turn == 2, "enter while permission is waiting skips the pending tool")
  check(
    wait_seen
      and wait_seen[3]
      and wait_seen[3].content[1].type == "tool_result"
      and wait_seen[3].content[1].content:find("Tool skipped", 1, true),
    "permission interrupt sends skipped tool_result"
  )
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
  providers.register("fakepar", {
    stream = function(req)
      pturn = pturn + 1
      if pturn == 1 then requested_parallel = req.parallel_tool_calls end
      vim.defer_fn(function()
        if pturn == 1 then
          req.on.complete({
            { type = "tool_use", id = "s1", name = "sub_agent", input = { prompt = "alpha", model = "fakesubpar/m" } },
            { type = "tool_use", id = "s2", name = "sub_agent", input = { prompt = "beta", model = "fakesubpar/m" } },
            { type = "tool_use", id = "s3", name = "sub_agent", input = { prompt = "gamma", model = "fakesubpar/m" } },
          }, "tool_use")
        else
          for _, m in ipairs(req.messages) do
            if m.role == "user" then
              local trs = {}
              for _, b in ipairs(m.content) do
                if b.type == "tool_result" then trs[#trs + 1] = b end
              end
              if #trs == 3 then final_results = trs end
            end
          end
          req.on.complete({ { type = "text", text = "all done" } }, "end_turn")
        end
      end, 10)
      return { stop = function() end }
    end,
  })

  local ag = agent_mod.new({ model = { provider = "fakepar", id = "m", label = "par" } })
  ag:send("fan out")
  vim.wait(6000, function()
    return pturn >= 2 and final_results ~= nil
  end, 10)

  check(sub_started == 3, "all three sub-agents ran")
  check(requested_parallel == true, "main-agent provider request permits parallel tool calls")
  check(max_concurrent >= 2, "sub-agents overlapped instead of running one-at-a-time")
  check(final_results and #final_results == 3, "three tool_results merged into one user turn")
  local ids = {}
  for _, tr in ipairs(final_results or {}) do
    ids[tr.tool_use_id] = true
  end
  check(ids.s1 and ids.s2 and ids.s3, "each sub_agent call got its matching tool_result")

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
            { type = "tool_use", id = "m1", name = "sub_agent", input = { prompt = "delta", model = "fakesubpar/m" } },
            {
              type = "tool_use",
              id = "m2",
              name = "sub_agent",
              input = { prompt = "epsilon", model = "fakesubpar/m" },
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
  memory._root_override = nil -- exercise the real git-root walk
  local prev_cwd = vim.fn.getcwd()
  vim.fn.chdir(repo .. "/src/deep")

  check(memory.root() == repo, "memory root walks up to the git root from a subdirectory")
  agent_mod.new({ model = { provider = "fake", id = "m", label = "m" } })
  check(
    vim.fn.filereadable(repo .. "/.advantage/context.md") == 1,
    "bootstrap lands at the git root, not the subdirectory"
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
  local malformed = vim.deepcopy(config.defaults)
  malformed.providers.openai = false
  malformed.subagents.max_per_turn = 0
  malformed.subagents.max_output_tokens = "huge"
  errs = config._validate(malformed)
  check(
    vim.tbl_contains(errs, "providers.openai must be a table")
      and vim.tbl_contains(errs, "subagents.max_per_turn must be a positive integer")
      and vim.tbl_contains(errs, "subagents.max_output_tokens must be a positive integer"),
    "validation rejects malformed nested provider and cumulative/output scout controls"
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
    tools.get("sub_agent").run({ prompt = "loop", model = "fakeloop/m", max_turns = 2 }, {
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

  -- with a live agent: frozen block + real transcript + provider-aware economics
  local ag = agent_mod.new({ model = { provider = "anthropic", id = "claude-x", label = "x" } })
  ag.messages = { { role = "user", content = { { type = "text", text = "one transcript message here" } } } }
  local pblob = table.concat((preview.build(ag)), "\n")
  check(pblob:find("memory frozen", 1, true) ~= nil, "live preview marks the memory block frozen")
  check(pblob:find("1 messages", 1, true) ~= nil, "live preview counts transcript messages")
  check(pblob:find("prompt cache", 1, true) ~= nil, "anthropic preview notes the ~10% cache discount")

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
  tools.get("sub_agent").run({ prompt = "scout the thing", model = "fakesublean/m" }, ctx, function(out)
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
