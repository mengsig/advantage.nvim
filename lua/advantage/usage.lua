---@brief Persistent token-usage ledger + the `/usage` dashboard.
---Every API response appends one JSONL record; the dashboard aggregates them
---into daily totals, a 7-day sparkline, current pace and run-out projections.
local M = {}

local uv = vim.uv or vim.loop

local function ledger_path()
  if M._ledger_override then return M._ledger_override end
  local dir = vim.fn.stdpath("data") .. "/advantage"
  vim.fn.mkdir(dir, "p")
  return dir .. "/usage.jsonl"
end

---Append one usage record. Called once per API response. `cached` is the portion
---of `input` served from the prompt cache (billed at ~10%), tracked so the
---dashboard can show real cost instead of full-price input.
---@param details? {reasoning?:number, cache_write?:number}
function M.record(model, input, output, cached, details)
  assert(model == nil or type(model) == "table", "usage.record: model must be a table or nil")
  assert(input == nil or (type(input) == "number" and input >= 0), "usage.record: input tokens must be non-negative")
  assert(
    output == nil or (type(output) == "number" and output >= 0),
    "usage.record: output tokens must be non-negative"
  )
  assert(
    cached == nil or (type(cached) == "number" and cached >= 0),
    "usage.record: cached tokens must be non-negative"
  )
  if (input or 0) == 0 and (output or 0) == 0 then return end
  local rec = {
    t = os.time(),
    m = (model and (model.provider .. "/" .. model.id)) or "?",
    i = input or 0,
    o = output or 0,
    c = (cached or 0) > 0 and cached or nil,
    r = details and (details.reasoning or 0) > 0 and details.reasoning or nil,
    w = details and (details.cache_write or 0) > 0 and details.cache_write or nil,
    e = (details and details.effort) or (model and (model.reasoning_effort or model.effort) or nil),
  }
  local ok, line = pcall(vim.json.encode, rec)
  if not ok then return end
  local f = io.open(ledger_path(), "a")
  if not f then return end
  f:write(line .. "\n")
  f:close()
end

---Read records newer than `since` (unix time).
local function read_since(since)
  local out = {}
  local f = io.open(ledger_path(), "r")
  if not f then return out end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" and (rec.t or 0) >= since then out[#out + 1] = rec end
  end
  f:close()
  return out
end

local function midnight(offset_days)
  local d = os.date("*t") --[[@as osdate]]
  d.hour, d.min, d.sec = 0, 0, 0
  return os.time(d) + (offset_days or 0) * 86400
end

local SPARKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function sparkline(values)
  local max = 0
  for _, v in ipairs(values) do
    max = math.max(max, v)
  end
  if max == 0 then return string.rep(SPARKS[1], #values) end
  local s = {}
  for _, v in ipairs(values) do
    local idx = v == 0 and 1 or math.min(#SPARKS, 1 + math.floor(v / max * (#SPARKS - 1) + 0.5))
    s[#s + 1] = SPARKS[idx]
  end
  return table.concat(s)
end

---Aggregate the ledger into dashboard-ready stats.
---@param now integer|nil injected for tests
function M.stats(now)
  assert(now == nil or type(now) == "number", "usage.stats: now must be a unix timestamp")
  now = now or os.time()
  local week_start = midnight(-6)
  local records = read_since(week_start)
  local today_start = midnight(0)

  local st = {
    today = { input = 0, output = 0, total = 0, requests = 0, cached = 0, reasoning = 0, cache_write = 0 },
    last_hour = 0,
    days = {}, -- 7 entries, oldest first
    by_model = {}, -- today, model -> total
    first_today = nil,
  }
  for i = 1, 7 do
    st.days[i] = 0
  end

  for _, r in ipairs(records) do
    local total = (r.i or 0) + (r.o or 0)
    local day = math.floor((r.t - week_start) / 86400) + 1
    if day >= 1 and day <= 7 then st.days[day] = st.days[day] + total end
    if r.t >= today_start then
      st.today.input = st.today.input + (r.i or 0)
      st.today.output = st.today.output + (r.o or 0)
      st.today.total = st.today.total + total
      st.today.requests = st.today.requests + 1
      st.today.cached = st.today.cached + (r.c or 0)
      st.today.reasoning = st.today.reasoning + (r.r or 0)
      st.today.cache_write = st.today.cache_write + (r.w or 0)
      st.by_model[r.m or "?"] = (st.by_model[r.m or "?"] or 0) + total
      st.first_today = math.min(st.first_today or r.t, r.t)
    end
    if r.t >= now - 3600 then st.last_hour = st.last_hour + total end
  end

  local week_total = 0
  for _, v in ipairs(st.days) do
    week_total = week_total + v
  end
  st.week_total = week_total
  st.week_avg = math.floor(week_total / 7)

  -- pace: tokens/hour over the active part of today (fall back to last hour)
  local active_h = st.first_today and math.max((now - st.first_today) / 3600, 1 / 60) or nil
  st.pace = active_h and math.floor(st.today.total / active_h) or 0
  if st.pace == 0 then st.pace = st.last_hour end

  -- projection to midnight at today's pace
  local hours_left = (midnight(1) - now) / 3600
  st.projected_today = st.today.total + math.floor(st.pace * hours_left)
  assert(#st.days == 7, "usage.stats: 7-day bucket array must stay length 7")
  return st
end

local function fmt(n)
  return require("advantage.util").fmt_tokens(n)
end

---Render the dashboard lines for the float.
---Session/today/cache/pace/7-day rows.
local function add_totals(add, st, session_usage)
  if session_usage then
    add("session", ("↑%s ↓%s"):format(fmt(session_usage.input or 0), fmt(session_usage.output or 0)))
  end
  add(
    "today",
    ("↑%s ↓%s · %s total · %d request%s"):format(
      fmt(st.today.input),
      fmt(st.today.output),
      fmt(st.today.total),
      st.today.requests,
      st.today.requests == 1 and "" or "s"
    )
  )
  if (st.today.cached or 0) > 0 then
    -- Approximate full-price-token equivalents: reads are heavily discounted,
    -- while providers may charge a cache-creation premium. Report the net, not
    -- an inflated read-only savings claim.
    local saved = math.max(0, math.floor(st.today.cached * 0.9 - (st.today.cache_write or 0) * 0.25))
    local pct = st.today.input > 0 and math.floor(st.today.cached / st.today.input * 100 + 0.5) or 0
    local writes = (st.today.cache_write or 0) > 0 and (" · %s writes"):format(fmt(st.today.cache_write)) or ""
    add("cached", ("%s of input (%d%%)%s · ~%s net saved"):format(fmt(st.today.cached), pct, writes, fmt(saved)))
  end
  if (st.today.reasoning or 0) > 0 then add("reasoning", fmt(st.today.reasoning) .. " output tokens") end
  add("last hour", fmt(st.last_hour) .. " tokens")
  add("pace", fmt(st.pace) .. "/h")
  add("7 days", ("%s  %s total · avg %s/day"):format(sparkline(st.days), fmt(st.week_total), fmt(st.week_avg)))
end

---Per-model token rows, sorted by descending total.
local function add_by_model(add, st)
  local models = {}
  for m, total in pairs(st.by_model) do
    models[#models + 1] = { m, total }
  end
  table.sort(models, function(a, b)
    return a[2] > b[2]
  end)
  for i, m in ipairs(models) do
    add(i == 1 and "by model" or "", ("%s  %s"):format(fmt(m[2]), m[1]))
  end
end

---Harness instrumentation: what the repo memory injects per turn (cached), and
---what the index-only skill design avoided versus inlining every body.
local function add_harness(lines, add, st, session_usage)
  local mok, memory = pcall(require, "advantage.memory")
  if not (mok and memory.enabled()) then return end
  local ok_hs, hs = pcall(memory.stats)
  if not (ok_hs and (hs.block_tokens > 0 or hs.skills > 0)) then return end
  lines[#lines + 1] = ""
  add("harness", ("repo memory ~%s tok/turn, rides the cached prefix"):format(fmt(hs.block_tokens)))
  if hs.skills > 0 then
    local turns = (session_usage and session_usage.turns) or 0
    local saved = turns > 0 and math.max(0, turns * hs.bodies_tokens - hs.loaded_tokens) or 0
    add(
      "",
      ("%d skill%s indexed · %d load%s on demand%s"):format(
        hs.skills,
        hs.skills == 1 and "" or "s",
        hs.loads,
        hs.loads == 1 and "" or "s",
        saved > 0 and (" · ~%s tok saved vs inlining bodies"):format(fmt(saved)) or ""
      )
    )
  end
end

---Daily-budget row with a run-out estimate when a budget is configured.
local function add_budget(add, st, cfg, now)
  local budget = cfg.daily_budget
  if not (budget and budget > 0) then
    return add("budget", "not set — usage.daily_budget enables run-out estimates")
  end
  local used = st.today.total
  local pct = math.floor(used / budget * 100 + 0.5)
  local line = ("%s/day · %d%% used"):format(fmt(budget), pct)
  if used >= budget then
    line = line .. " · budget exhausted"
  elseif st.pace > 0 then
    local eta = now + math.floor((budget - used) / st.pace * 3600)
    local mid = midnight(1)
    if eta < mid then
      line = line .. (" · runs out ~%s at this pace"):format(os.date("%H:%M", eta))
    else
      line = line .. " · on track for today"
    end
  end
  add("budget", line)
end

function M.dashboard_lines(session_usage)
  local cfg = require("advantage.config").options.usage or {}
  local now = os.time()
  local st = M.stats(now)
  assert(type(st) == "table" and type(st.today) == "table", "dashboard_lines: stats must include today")
  local lines = {}
  local function add(label, value)
    lines[#lines + 1] = ("  %-12s %s"):format(label, value)
  end

  add_totals(add, st, session_usage)
  add_by_model(add, st)
  add_harness(lines, add, st, session_usage)

  lines[#lines + 1] = ""
  if st.pace > 0 then add("projection", ("~%s by midnight at today's pace"):format(fmt(st.projected_today))) end
  add_budget(add, st, cfg, now)
  return lines
end

M._sparkline = sparkline

return M
