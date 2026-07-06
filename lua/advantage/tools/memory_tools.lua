---@brief Memory / skills tools (the self-learning harness): remember, use_skill,
---save_skill. Registered by tools/init.lua; behaviour is identical to when these
---lived inline in that file.
local util = require("advantage.util")

---Append-only curation steer: nudge the model (in the tool result — never the
---cached prefix, so it's free of per-turn cost) toward the curation that actually
---matters. Fires on genuine procedural DEPTH (belongs in an on-demand skill),
---REDUNDANT overlapping facts (merge them), or real BUDGET pressure — never on
---raw bullet length, which is cheap behind prompt-caching and whose specificity
---is the point. Also fires a once-per-session persistent notice to the user.
local function curation_suffix(res)
  assert(type(res) == "table", "curation_suffix: res must be a table")
  local out = ""
  if res.procedural_count and res.procedural_count > 0 then
    out = out
      .. (" %d memory fact(s) read as procedural depth — move each into a skill (save_skill) with a description rich in the terms you'd search for, then leave a crisp one-line pointer; the body loads on demand via use_skill. Don't shorten precise facts, just relocate real depth."):format(
        res.procedural_count
      )
  end
  if res.redundant_pairs and res.redundant_pairs >= 3 then
    out = out
      .. (" Memory has %d overlapping fact pair(s) — merge them so it never says the same thing twice or contradicts itself."):format(
        res.redundant_pairs
      )
  end
  if res.utilization and res.utilization > 0.85 then
    out = out
      .. (" Memory is at %d%% of its budget — curate: merge overlaps, drop stale facts, extract depth into skills (never truncate a load-bearing fact to save space)."):format(
        math.floor(res.utilization * 100 + 0.5)
      )
    -- once-per-session persistent nudge to the user
    local mem = require("advantage.memory")
    if mem.curation_nudge_due() then
      pcall(function()
        require("advantage.ui.chat").notice(
          ("⚠ repo memory is ~%d%% full — run /context curate (merge overlaps, extract depth into skills)"):format(
            math.floor(res.utilization * 100 + 0.5)
          )
        )
      end)
    end
  end
  return out
end

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "memory tools: tool registrar required")
  assert(type(s) == "table", "memory tools: support module required")

  tool({
    name = "remember",
    safe = true,
    memory = true,
    description = "Save a durable, repo-specific fact to persistent memory so future sessions start already knowing it. Use for an architecture invariant, a convention, a build/test/lint command, a gotcha, or a preference the user states — one crisp, self-contained fact per call. Do NOT save trivia, transient state, or anything a quick file read re-derives.",
    input_schema = {
      type = "object",
      properties = {
        fact = { type = "string", description = "The single fact to remember, phrased concisely and self-contained." },
        section = {
          type = "string",
          description = "Where it belongs.",
          enum = { "Conventions", "Architecture", "Commands", "Gotchas", "Preferences", "Notes" },
        },
      },
      required = { "fact" },
    },
    summary = function(input)
      local f = (input.fact or ""):gsub("%s+", " ")
      return #f > 60 and (util.utf8_safe_sub(f, 57) .. "…") or f
    end,
    run = function(input, ctx, cb)
      local memory = require("advantage.memory")
      if not memory.enabled() then return cb("Memory is disabled (config.memory.enabled = false).", true) end
      local res = memory.remember(input.fact, input.section)
      if res.status == "empty" then
        return cb("Nothing to remember (empty fact).", true)
      elseif res.status == "procedural" then
        return cb(
          "This reads like a multi-step procedure, not a fact. Procedures cost their full length in every request as memory bullets but only one index line as skills — record it with save_skill instead (or split out the single durable fact).",
          true
        )
      elseif res.status == "duplicate" then
        return cb("Already known — a near-identical fact is in memory; not duplicated.", false)
      elseif res.status == "updated" then
        return cb(("Updated the existing fact under %s."):format(res.section) .. curation_suffix(res), false)
      end
      local msg = ("Remembered under %s."):format(res.section)
      if res.evicted and #res.evicted > 0 then
        local shown = {}
        for i = 1, math.min(3, #res.evicted) do
          shown[#shown + 1] = '"' .. res.evicted[i] .. '"'
        end
        msg = msg
          .. (" Memory hit its budget — %d oldest fact%s evicted: %s%s. If any is still valuable, re-record it tighter or fold it into a skill."):format(
            #res.evicted,
            #res.evicted == 1 and "" or "s",
            table.concat(shown, ", "),
            #res.evicted > 3 and ", …" or ""
          )
      end
      cb(msg .. curation_suffix(res), false)
    end,
  })

  tool({
    name = "use_skill",
    safe = true,
    memory = true,
    description = "Load the full steps of a named skill (a reusable procedure for this repo). Skill names and descriptions are listed in your context under 'Skills'; call this when a skill's description matches the task, before doing that task.",
    input_schema = {
      type = "object",
      properties = {
        name = { type = "string", description = "The skill name, exactly as listed in the skills index." },
      },
      required = { "name" },
    },
    summary = function(input)
      return input.name or ""
    end,
    run = function(input, ctx, cb)
      local memory = require("advantage.memory")
      local body, desc = memory.use_skill(input.name)
      if not body then
        local names = {}
        for _, sk in ipairs(memory.skills_index()) do
          names[#names + 1] = sk.name
        end
        return cb(
          ("No skill named %q. Available: %s"):format(
            tostring(input.name),
            #names > 0 and table.concat(names, ", ") or "(none)"
          ),
          true
        )
      end
      cb(("Skill: %s — %s\n\n%s"):format(input.name, desc or "", body), false)
    end,
  })

  tool({
    name = "save_skill",
    safe = true,
    memory = true,
    description = "Create or update a reusable skill: a named, multi-step procedure for this repo (e.g. how to run the test suite, cut a release, add a provider). Worthwhile only for genuinely reusable procedures of ~3+ steps, not one-offs.",
    input_schema = {
      type = "object",
      properties = {
        name = { type = "string", description = "Short kebab-case skill name." },
        description = { type = "string", description = "One line describing when to use this skill (its trigger)." },
        body = { type = "string", description = "The procedure/steps, in Markdown." },
      },
      required = { "name", "description", "body" },
    },
    summary = function(input)
      return input.name or ""
    end,
    run = function(input, ctx, cb)
      local memory = require("advantage.memory")
      if not memory.enabled() then return cb("Memory is disabled (config.memory.enabled = false).", true) end
      local ok, err = memory.save_skill(input.name, input.description, input.body)
      if not ok then return cb("Could not save skill: " .. tostring(err), true) end
      cb(("Saved skill %q. It is now in the skills index; load its steps with use_skill."):format(input.name), false)
    end,
  })
end
