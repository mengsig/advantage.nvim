-- Deterministic lifecycle/resource contracts: nvim --headless -l tests/resource.lua
-- Keeps long-lived Neovim sessions flat under repeated workspace and UI churn.
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

require("advantage.config").setup({
  memory = { enabled = false },
  subagents = { enabled = false },
  tools = {
    lsp = { enabled = false },
    navgraph = { enabled = false },
    web_search = { enabled = false },
    web_fetch = { enabled = false },
  },
})

section("bounded workspace cache")
do
  local util = require("advantage.util")
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/.git", "p")
  util._reset_project_root_cache()
  local resolved = true
  for i = 1, 160 do
    local path = ("%s/generated/%04d/deep"):format(tmp, i)
    vim.fn.mkdir(path, "p")
    resolved = resolved and util.project_root(path) == tmp
  end
  check(resolved, "workspace churn still resolves every nested directory to its git root")
  check(util._project_root_cache_size() == 128, "project-root memo stays at its fixed 128-entry ceiling")
  util._reset_project_root_cache()
  vim.fn.delete(tmp, "rf")
end

section("bounded session resume")
do
  local config = require("advantage.config")
  local session = require("advantage.session")
  local saved_dir = session._dir_override
  local saved_sessions = vim.deepcopy(config.options.sessions)
  local tmp = vim.fn.tempname()
  local repo = tmp .. "/repo"
  vim.fn.mkdir(repo .. "/.git", "p")
  session._dir_override = tmp .. "/sessions"
  config.options.sessions.max_file_bytes = 64 * 1024

  for i = 1, 2 do
    local ok = session.save({
      id = "resource-session-" .. i,
      title = "resource " .. i,
      model = { provider = "fake", id = "m" },
      harness_mode = "medium",
      messages = {
        { role = "user", content = { { type = "text", text = string.rep(tostring(i), 8192) } } },
      },
      usage = {},
      ctx = { cwd = repo },
    })
    check(ok == true, "ordinary bounded session " .. i .. " saves")
  end

  local private_files, no_temps = true, true
  for name, kind in vim.fs.dir(session._dir_override) do
    if kind == "file" then
      local stat = (vim.uv or vim.loop).fs_stat(session._dir_override .. "/" .. name)
      private_files = private_files and stat ~= nil and bit.band(stat.mode or 0, 511) == 384
      no_temps = no_temps and not name:find(".adv.", 1, true)
    end
  end
  check(private_files, "session transcripts and lightweight metadata stay mode 0600")
  check(no_temps, "atomic session and metadata saves leave no temporary files")

  local rows = session.list_metadata(repo)
  local lightweight = #rows == 2
  for _, row in ipairs(rows) do
    lightweight = lightweight and row.messages == nil and type(row.message_count) == "number"
  end
  check(lightweight, "resume listing keeps only metadata, not every transcript body")
  local loaded = rows[1] and session.load(rows[1]) or nil
  check(loaded and type(loaded.messages) == "table", "the selected metadata row loads its full transcript on demand")

  local selected_file = rows[1] and rows[1]._session_file
  local selected_path = selected_file and (session._dir_override .. "/" .. selected_file) or nil
  local original = selected_path and assert(io.open(selected_path, "r")) or nil
  local original_body = original and original:read("*a") or nil
  if original then original:close() end
  local tampered = original_body and vim.json.decode(original_body) or nil
  if tampered then
    tampered.cwd = "/tmp/outside-advantage-resource-project"
    tampered.title = "new transcript generation"
    local out = assert(io.open(selected_path, "w"))
    out:write(vim.json.encode(tampered))
    out:close()
  end
  local refreshed_rows = session.list_metadata(repo)
  local refreshed_title
  for _, row in ipairs(refreshed_rows) do
    if row._session_file == selected_file then refreshed_title = row.title end
  end
  check(refreshed_title == "new transcript generation", "resume ignores stale metadata after a transcript replacement")
  local escaped, escaped_err
  if rows[1] then
    escaped, escaped_err = session.load(rows[1])
  end
  check(
    not escaped and tostring(escaped_err):find("selected project", 1, true) ~= nil,
    "resume rejects a persisted workspace that escapes the selected project"
  )
  if original_body then
    local out = assert(io.open(selected_path, "w"))
    out:write(original_body)
    out:close()
  end

  local prefix = session._project_key(repo)
  local oversized = session._dir_override .. "/" .. prefix .. "-oversized.json"
  local f = assert(io.open(oversized, "w"))
  f:write(string.rep("x", 64 * 1024 + 1))
  f:close()
  check(#session.list(repo) == 2, "an oversized planted session is rejected before read/decode")

  local saved, err = session.save({
    id = "resource-too-large",
    title = "too large",
    model = { provider = "fake", id = "m" },
    messages = {
      { role = "user", content = { { type = "text", text = string.rep("z", 70 * 1024) } } },
    },
    usage = {},
    ctx = { cwd = repo },
  })
  check(
    not saved and tostring(err):find("max_file_bytes", 1, true) ~= nil,
    "oversized saves fail with an actionable ceiling"
  )

  session._dir_override = saved_dir
  config.options.sessions = saved_sessions
  vim.fn.delete(tmp, "rf")
end

section("chat lifecycle ownership")
do
  local ui = require("advantage.ui.chat")
  ui.clear()
  ui.open(false)

  -- Terminal cards are already represented by transcript bytes/extmarks. Only
  -- live cards belong in the spinner's Lua table.
  for i = 1, 250 do
    local id = "resource-tool-" .. i
    ui.tool_begin(id, "read_file")
    ui.tool_update(id, { status = "running", detail = "fixture.lua" })
    ui.tool_update(id, { status = "ok" })
  end
  check(next(ui.state.tools) == nil, "hundreds of completed tool cards leave no retained Lua records")

  -- Buffered provider/tool deltas own timers and potentially large strings.
  -- Clear is a synchronous lifecycle boundary and must drain all of them.
  ui.begin_assistant("resource-test")
  ui.stream_text(string.rep("stream ", 2000))
  ui.tool_begin("resource-stream", "bash")
  ui.tool_output("resource-stream", string.rep("output\n", 2000))
  ui.clear()
  check(
    ui.state.stream_timer == nil and #ui.state.stream_parts == 0,
    "clear drains the provider stream timer and bytes"
  )
  check(next(ui.state.tool_streams) == nil, "clear drains every buffered tool-output timer and bytes")

  -- Scratch buffers are user-visible Neovim objects and can be wiped by :bwipe,
  -- session managers, or other plugins. Repair either half independently.
  local first_chat, first_prompt = ui.state.buf, ui.state.input_buf
  ui.state.attachments = { { name = "large.png", data = string.rep("x", 1024 * 1024) } }
  vim.api.nvim_buf_delete(first_prompt, { force = true })
  local prompt_reopen_ok = pcall(ui.open, false)
  local second_prompt = ui.state.input_buf
  check(
    prompt_reopen_ok
      and vim.api.nvim_buf_is_valid(ui.state.buf)
      and vim.api.nvim_buf_is_valid(second_prompt)
      and second_prompt ~= first_prompt,
    "wiping only the prompt buffer self-heals on reopen"
  )
  check(#ui.state.attachments == 0, "a lost prompt releases its orphaned attachment payloads")

  local kept_prompt = ui.state.input_buf
  vim.api.nvim_buf_delete(ui.state.buf, { force = true })
  local chat_reopen_ok = pcall(ui.open, false)
  check(
    chat_reopen_ok
      and vim.api.nvim_buf_is_valid(ui.state.buf)
      and vim.api.nvim_buf_is_valid(ui.state.input_buf)
      and ui.state.input_buf == kept_prompt,
    "wiping only the transcript self-heals while preserving the prompt buffer"
  )

  local chats, prompts = 0, 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == "advantage://chat" then chats = chats + 1 end
      if name == "advantage://prompt" then prompts = prompts + 1 end
    end
  end
  check(chats == 1 and prompts == 1, "partial repair leaves exactly one owned chat/prompt buffer pair")
  ui.set_status("idle")
  ui.close()
  check(ui.state.timer == nil, "closing an idle panel leaves no spinner timer")
end

print("")
if failed > 0 then
  print(("RESOURCE FAILED — %d check(s)"):format(failed))
  os.exit(1)
else
  print("RESOURCE PASSED")
  os.exit(0)
end
