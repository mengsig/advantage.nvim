-- Deterministic local performance budgets: nvim --headless -l tests/perf.lua
-- These guard against accidental synchronous work in request-critical paths;
-- end-to-end model quality/latency remains covered by .benchmarks/harness_compare.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)

local uv = vim.uv or vim.loop
local failed = 0

local function bench(name, iterations, max_ms, fn)
  for _ = 1, 5 do
    fn()
  end
  collectgarbage("collect")
  local started = uv.hrtime()
  for _ = 1, iterations do
    fn()
  end
  local elapsed_ms = (uv.hrtime() - started) / 1e6
  local average_ms = elapsed_ms / iterations
  local ok = average_ms <= max_ms
  if not ok then failed = failed + 1 end
  print(("  %s  %-34s %.3f ms/op (budget %.1f)"):format(ok and "ok  " or "FAIL", name, average_ms, max_ms))
end

local config = require("advantage.config")
config.setup({
  memory = { enabled = false },
  subagents = { enabled = false },
  tools = {
    lsp = { enabled = false },
    navgraph = { enabled = false },
    web_search = { enabled = false },
    web_fetch = { enabled = false },
  },
})

print("\n== request-critical budgets")
bench("tool schema construction", 500, 5, function()
  assert(#require("advantage.tools").schemas() > 0)
end)
bench("system prompt construction", 500, 5, function()
  assert(#require("advantage.agent").system_prompt(nil, root) > 0)
end)
local prompt = require("advantage.agent").system_prompt(nil, root)
local schema = vim.json.encode(require("advantage.tools").schemas())
bench("NUL-safe request identity", 200, 5, function()
  assert(#require("advantage.util").hash_parts({ "advantage-parent", prompt, schema }) == 64)
end)

print("\n== large skill-library budget")
local memory = require("advantage.memory")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.agents/skills", "p")
for i = 1, 200 do
  local dir = ("%s/.agents/skills/skill-%03d"):format(tmp, i)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "---",
    ("name: skill-%03d"):format(i),
    ("description: Focused workflow number %03d"):format(i),
    "---",
    "",
    "Do the focused workflow.",
  }, dir .. "/SKILL.md")
end
memory._root_override = tmp
config.options.memory.enabled = true
assert(#memory.skills_index() == 200)
bench("warm index validation (200 skills)", 50, 20, function()
  assert(#memory.skills_index() == 200)
end)
vim.fn.delete(tmp, "rf")

print("")
if failed > 0 then
  print(("PERF FAILED — %d budget(s) exceeded"):format(failed))
  os.exit(1)
else
  print("PERF PASSED")
  os.exit(0)
end
