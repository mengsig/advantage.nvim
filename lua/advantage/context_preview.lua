---@brief `/context preview` (also `<leader>cP` and `:Advantage context preview`).
---Renders the EXACT context advantage will send the model next turn, with the
---cache boundary drawn and a per-section token breakdown. Pure observability: it
---builds the same system prompt + tool schemas the agent would send — no request
---is made and nothing is mutated. Its whole point is to make the invisible
---contract legible: what each section costs, what is frozen for cache reuse, and
---the literal bytes going over the wire.
local M = {}

---Rough token estimate — the same chars/4 convention used across the harness
---(memory.lua, compact.lua) so the numbers here line up with /usage and budgets.
local function tok(s)
  return math.ceil(#(s or "") / 4)
end

---A right-aligned "  label                         NNNN tok  note" row.
local function row(label, tokens, note)
  return ("  %-34s %6d tok%s"):format(label, tokens, note and ("   " .. note) or "")
end

---@param agent table|nil the active agent (nil = no session, so a fresh render)
---@return string[] lines markdown lines for a ui.float
---@return string raw_system the exact system prompt bytes (also appended to lines)
function M.build(agent)
  local agentmod = require("advantage.agent")
  local memory = require("advantage.memory")
  local tools = require("advantage.tools")
  local compact = require("advantage.compact")
  local config = require("advantage.config")

  -- The model whose request we are previewing (falls back to the configured
  -- default when there's no live session).
  local model = agent and agent.model or nil
  local model_ref = model and (tostring(model.provider) .. "/" .. tostring(model.id))
    or config.options.default_model
    or "?"
  local model_label = (model and model.label) or "(default)"
  local provider = (model and model.provider) or (model_ref:match("^([^/]+)/") or "")

  -- The memory block that will actually be sent: the agent's session-frozen
  -- block, or a fresh render when there is no session. Passing it through the
  -- real system_prompt builder means the bytes shown are byte-for-byte the bytes
  -- sent — including the frozen-vs-disk state.
  local frozen = agent and agent:_memory_prompt_block() or nil
  local sys_parts = agentmod.system_prompt_parts(frozen)
  local raw_system = agentmod.system_prompt(frozen)

  local lines = {}
  local function add(l)
    lines[#lines + 1] = l
  end

  add("# Context preview")
  add("")
  add("The exact packet advantage sends the model each turn. The system prompt and")
  add("tool schemas are the cached prefix; the transcript grows and only its newest")
  add("turn is billed at full price.")
  add("")
  add(("Model: %s  ·  %s"):format(model_ref, model_label))
  add("")

  -- ── System prompt ──────────────────────────────────────────────────────────
  local mem_on = memory.enabled()
  local frozen_note = (agent and mem_on) and "[memory frozen ✓ · refreshes at /compact]"
    or (mem_on and "[fresh render — no active session]" or "[memory disabled]")
  add("## System prompt — cached prefix   " .. frozen_note)

  local system_total = 0
  for _, p in ipairs(sys_parts) do
    if p.is_memory then
      -- expand the memory block into its composition (project / repo / skills)
      for _, mp in ipairs(memory.render_parts()) do
        local t = tok(mp.text)
        system_total = system_total + t
        add(row(mp.label, t))
      end
    else
      local t = tok(p.text)
      system_total = system_total + t
      add(row(p.label, t))
    end
  end
  add("  " .. string.rep("─", 44))
  add(row("system total", system_total))

  -- Surface a mid-session drift: a `remember`/`save_skill` after the block was
  -- frozen writes to disk but does NOT touch the live prefix (that's the cache
  -- win) — the fact rides the transcript until the next /compact re-freezes.
  if agent and mem_on and frozen ~= nil then
    local current = memory.render()
    if frozen ~= current then
      add("")
      add(
        ("  ⚠ live prefix is frozen at %d tok; disk now renders %d tok — the newer facts"):format(
          tok(frozen),
          tok(current)
        )
      )
      add("    are in the transcript and fold into the prefix at the next /compact.")
    end
  end
  add("")

  -- ── Tools ──────────────────────────────────────────────────────────────────
  local schemas = tools.schemas()
  local ok_json, json = pcall(vim.json.encode, schemas)
  local tools_tok = ok_json and tok(json) or 0
  add("## Tools — cached prefix")
  add(row(("%d tools"):format(#schemas), tools_tok))
  local line = "   "
  for _, s in ipairs(schemas) do
    local name = tostring(s.name or "?")
    local sep = (line == "   ") and "" or ", "
    if #line + #sep + #name > 62 then
      add(line .. ",")
      line = "   " .. name
    else
      line = line .. sep .. name
    end
  end
  if vim.trim(line) ~= "" then add(line) end
  add("")

  -- ── Transcript ─────────────────────────────────────────────────────────────
  local msgs = (agent and agent.messages) or {}
  local trans_tok = compact.estimate_tokens(msgs)
  add("## Transcript — rolling cache, newest turn full price")
  add(row(("%d messages"):format(#msgs), trans_tok))
  if #msgs > 0 then add("      → mostly cache-read at ~10% after each message's first turn") end
  add("")

  -- ── Totals + cache economics ────────────────────────────────────────────────
  add(string.rep("═", 48))
  local prefix = system_total + tools_tok
  add(row("cached prefix (system + tools)", prefix))
  local later = math.floor(prefix * 0.1 + 0.5)
  if provider == "anthropic" then
    add(("      → ~%d tok/turn after turn 1 (prompt cache ≈10%%)"):format(later))
  elseif provider == "openai" then
    add(("      → ~%d tok/turn after turn 1 (auto prefix cache)"):format(later))
  end
  add(row("total context", prefix + trans_tok))
  add("")

  -- ── The exact bytes ─────────────────────────────────────────────────────────
  add(string.rep("─", 48))
  add("Exact system prompt bytes (scroll ↓):")
  add("")
  for _, l in ipairs(vim.split(raw_system, "\n", { plain = true })) do
    add(l)
  end

  return lines, raw_system
end

return M
