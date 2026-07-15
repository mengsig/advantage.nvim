---@brief Harness-level orchestration policy. Reasoning effort controls how hard
---the selected model thinks; harness mode controls how advantage decomposes,
---delegates, parallelizes, and verifies work. Presets initially synchronize the
---model effort, after which `/effort` can still override it independently.
local M = {}

local ORDER = { "low", "medium", "high", "xhigh", "max", "ultra" }

local POLICIES = {
  low = {
    label = "low · direct",
    effort = "low",
    proactive = false,
    parallel = false,
    max_parallel = 1,
    description = "Direct execution; delegate only when explicitly requested.",
  },
  medium = {
    label = "medium · selective",
    effort = "medium",
    proactive = false,
    parallel = true,
    max_parallel = 2,
    description = "Balanced default; selective delegation when it clearly helps.",
  },
  high = {
    label = "high · proactive",
    effort = "high",
    proactive = true,
    parallel = true,
    max_parallel = 2,
    description = "Proactively split clearly independent investigations.",
  },
  xhigh = {
    label = "xhigh · selective fan-out",
    effort = "xhigh",
    proactive = true,
    parallel = true,
    -- Configuration still defaults to width four. The larger policy ceiling
    -- lets an explicit subagents.max_parallel override opt into a wider wave.
    max_parallel = 8,
    description = "Task-sized parallel investigation with stronger verification.",
  },
  max = {
    label = "max · deep",
    effort = "max",
    proactive = false,
    parallel = true,
    max_parallel = 8,
    description = "Maximum parent depth; delegation remains deliberate.",
  },
  ultra = {
    label = "ultra · orchestrated",
    effort = "max",
    proactive = true,
    parallel = true,
    max_parallel = 8,
    description = "Maximum reasoning with task-sized proactive delegation.",
  },
}

---Register an additional orchestration preset without patching the core loop.
---The policy is declarative so it remains cheap, prompt-cacheable, and subject
---to the same concurrency and verification guardrails as built-in modes.
function M.register(name, policy)
  assert(type(name) == "string" and name:match("^[%l][%l%d_-]*$"), "harness: simple lowercase mode required")
  assert(name ~= "auto" and not POLICIES[name], "duplicate harness mode: " .. tostring(name))
  assert(type(policy) == "table", "harness: policy table required")
  assert(type(policy.label) == "string" and policy.label ~= "", "harness: policy.label required")
  assert(type(policy.description) == "string" and policy.description ~= "", "harness: policy.description required")
  assert(
    type(policy.effort) == "string" and vim.tbl_contains({ "low", "medium", "high", "xhigh", "max" }, policy.effort),
    "harness: policy.effort must be low, medium, high, xhigh, or max"
  )
  assert(
    type(policy.proactive) == "boolean" and type(policy.parallel) == "boolean",
    "harness: boolean policy flags required"
  )
  assert(
    type(policy.max_parallel) == "number"
      and policy.max_parallel >= 1
      and policy.max_parallel == math.floor(policy.max_parallel),
    "harness: positive integer max_parallel required"
  )
  local stored = vim.deepcopy(policy)
  POLICIES[name] = stored
  ORDER[#ORDER + 1] = name
  local active = true
  return function()
    if not active or POLICIES[name] ~= stored then return false end
    active = false
    POLICIES[name] = nil
    for i, mode in ipairs(ORDER) do
      if mode == name then
        table.remove(ORDER, i)
        break
      end
    end
    return true
  end
end

local function selected_effort(model)
  if not model then return "medium" end
  if model.provider == "openai" then
    local configured = ((require("advantage.config").options.providers or {}).openai or {}).reasoning_effort
    if model.reasoning_effort == nil then return configured end
    return model.reasoning_effort
  end
  if model.provider == "anthropic" then
    if model.effort then return model.effort end
    if type(model.thinking) == "table" and model.thinking.budget_tokens then
      local n = model.thinking.budget_tokens
      if n >= 30000 then return "max" end
      if n >= 16000 then return "xhigh" end
      if n >= 8000 then return "high" end
      if n >= 4000 then return "medium" end
      return "low"
    end
    return model.thinking == false and "low" or "high"
  end
  return "medium"
end

function M.valid(mode)
  return mode == "auto" or POLICIES[mode] ~= nil
end

function M.effective(mode, model)
  mode = M.valid(mode) and mode or "auto"
  if mode ~= "auto" then return mode end
  local effort = selected_effort(model)
  if effort == "none" or effort == "minimal" or effort == false then effort = "low" end
  if POLICIES[effort] then return effort end
  return "medium"
end

function M.policy(mode, model)
  local effective = M.effective(mode, model)
  local policy = vim.deepcopy(POLICIES[effective])
  policy.mode = effective
  policy.configured_mode = mode or "auto"
  return policy
end

function M.items()
  local out = {
    {
      value = "auto",
      label = "auto · follow effort",
      description = "Derive orchestration from the current model effort.",
    },
  }
  for _, mode in ipairs(ORDER) do
    local p = POLICIES[mode]
    out[#out + 1] = { value = mode, label = p.label, description = p.description }
  end
  return out
end

local function openai_preset(model, mode)
  local controls = require("advantage.effort")
  local target = POLICIES[mode].effort
  local levels = controls.openai_levels(model)
  local ranks = { none = 0, minimal = 1, low = 2, medium = 3, high = 4, xhigh = 5, max = 6, ultra = 7 }
  if not vim.tbl_contains(levels, target) then
    local wanted = ranks[target] or 3
    local best, rank = nil, -1
    for _, candidate in ipairs(levels) do
      local r = ranks[candidate]
      if r and r <= wanted and r > rank then
        best, rank = candidate, r
      end
    end
    target = best or levels[1]
  end
  return controls.set_openai(model, target)
end

---Synchronize a model to a selected preset. `auto` intentionally changes
---nothing; it is the escape hatch for independently controlled `/effort`.
function M.sync_effort(model, mode)
  if mode == "auto" or not POLICIES[mode] then return nil end
  local controls = require("advantage.effort")
  if model.provider == "openai" then return openai_preset(model, mode) end
  if model.provider == "anthropic" then
    local target = mode == "ultra" and "max" or POLICIES[mode].effort
    return controls.set_anthropic(model, target)
  end
  return nil, "effort controls are unavailable for " .. tostring(model.provider)
end

function M.describe(mode, model)
  local p = M.policy(mode, model)
  return "harness " .. p.mode
end

function M.guide(mode, model, parallel_requested)
  local p = M.policy(mode, model)
  local scfg = require("advantage.config").options.subagents or {}
  local enabled = scfg.enabled ~= false
  local choices = {}
  local route_state = "ready"
  if enabled then
    local ok, available = pcall(function()
      local subagent = require("advantage.subagent")
      if type(subagent.route_status) == "function" then route_state = subagent.route_status(model).state end
      return type(subagent.available_model_aliases) == "function" and subagent.available_model_aliases(model) or {}
    end)
    if ok and type(available) == "table" then choices = available end
  end
  local aliases, active_alias = {}, nil
  local active_ref = model and (tostring(model.provider) .. "/" .. tostring(model.id)) or nil
  for _, item in ipairs(choices) do
    aliases[#aliases + 1] = item.alias
    if item.ref == active_ref then active_alias = item.alias end
  end
  local model_instruction = "- Every sub-agent call must explicitly set model to one of these exact short aliases: "
    .. table.concat(aliases, ", ")
    .. ". Never invent, shorten, or copy a versioned provider model ID."
  if active_alias then
    model_instruction = model_instruction
      .. (' The active parent is already working through model="%s"; use that unless another alias has a clear task-specific advantage.'):format(
        active_alias
      )
  end
  model_instruction = model_instruction .. " Effort is also required on every call."
  local alias_set = {}
  for _, alias in ipairs(aliases) do
    alias_set[alias] = true
  end
  if #aliases == 3 and alias_set.sol and alias_set.terra and alias_set.luna then
    model_instruction = model_instruction
      .. " Choose sol for deepest architectural/correctness work, terra for balanced analysis, and luna for fast scoped lookups."
  elseif #aliases == 3 and alias_set.opus and alias_set.sonnet and alias_set.haiku then
    model_instruction = model_instruction
      .. " Choose opus for deepest architectural/correctness work, sonnet for balanced analysis, and haiku for fast scoped lookups."
  end
  if scfg.allow_cross_provider == true then
    model_instruction = model_instruction .. " The user explicitly enabled cross-provider scouts."
  elseif model and model.provider then
    model_instruction = model_instruction
      .. (" Scout routes are restricted to the active %s provider family; never select or invent a route from another provider."):format(
        model.provider
      )
  end
  -- `max` intentionally keeps delegation deliberate by default, but an
  -- explicit user request for parallel scouts is stronger than that default.
  -- Low mode remains sequential (and an explicit global parallel=false always
  -- wins), preserving the user's ability to force a serial investigation.
  local concurrent = enabled and scfg.parallel ~= false and (p.parallel or parallel_requested and p.max_parallel > 1)
  local max_parallel = math.min(p.max_parallel, math.max(1, tonumber(scfg.max_parallel) or 4))
  local lines = {
    ("Harness mode: %s. %s"):format(p.mode, p.description),
  }
  if type(p.guide) == "string" and p.guide ~= "" then
    lines[#lines + 1] = p.guide
  elseif type(p.guide) == "function" then
    local extra = p.guide({ model = model, parallel_requested = parallel_requested, policy = vim.deepcopy(p) })
    if type(extra) == "string" and extra ~= "" then lines[#lines + 1] = extra end
  end
  if not enabled then
    lines[#lines + 1] = "- Sub-agents are disabled. Work directly and keep verification proportional to this mode."
  elseif #choices == 0 and route_state == "unconfigured" then
    lines[#lines + 1] =
      "- No valid sub-agent aliases are configured. Fix subagents.model_aliases/models; work directly until routes are available."
  elseif #choices == 0 then
    lines[#lines + 1] =
      "- All configured sub-agent routes are temporarily unavailable after a deterministic provider/model failure. Do not retry or guess IDs; continue directly with parent tools."
  else
    lines[#lines + 1] = model_instruction
    lines[#lines + 1] =
      "- Treat scout reports as evidence to reconcile, not implementation authority. Ask for the narrowest investigation that reuses existing representations and invariants. Seek complete behavioral coverage, not a comprehensive redesign; recommend a new data model only when evidence proves the current representation cannot satisfy the contract."
    lines[#lines + 1] =
      "- Give each discovery question one owner. While a scout maps an area, do not run a broad parent survey of the same area in the same response. Consume an unambiguous exact source or precise span and never re-read it ceremonially; perform one narrow confirmation only for concrete ambiguity, truncation, or conflict."

    if p.proactive and concurrent then
      lines[#lines + 1] =
        '- When two or more independent scouts materially help, use one sub_agent_batch(mode="parallel") in the initial investigation turn. Never serialize independent scouts across later turns. Batch mode="sequential" only serializes self-contained prompts; wait for the report before issuing a genuinely dependent scout from a separate parent turn.'
      lines[#lines + 1] = ("- Proactively consider delegation, but keep it task-proportional and optional. Direct parent work is normally better for a simple localized defect or greenfield implementation. Use distinct, non-overlapping questions rather than a scout-count quota (up to %d concurrent); do not delegate generic architecture, test-survey, validation, or duplicate-review roles."):format(
        max_parallel
      )
      lines[#lines + 1] =
        "- Use one task-sized investigation wave by default, then synthesize and act. A later scout is justified only by a new concrete blocker exposed by evidence, never by a desire for post-implementation review."
      lines[#lines + 1] =
        "- Medium/high effort and 3-6 turns normally suffice. Reserve 8-12 turns for one genuinely deep isolated blocker; never give every scout in a breadth wave the maximum."
    elseif p.proactive then
      lines[#lines + 1] =
        '- The parallel scheduler is unavailable for this mode. Use sub_agent_batch(mode="sequential") only for self-contained scouts; it does not pass earlier reports into later prompts, so issue dependent scouts from separate parent turns.'
      lines[#lines + 1] =
        "- Proactively consider one scout only when its evidence will materially reduce parent work. Direct work is normally better for localized defects and greenfield implementation; never delegate generic surveys or duplicate review."
      lines[#lines + 1] =
        "- Use one task-sized investigation wave, then synthesize and act. Further scouts require a concrete dependency on prior evidence; never launch post-implementation review scouts. Medium/high effort and 3-6 turns normally suffice; reserve 8-12 for one hard blocker."
    else
      lines[#lines + 1] =
        '- You may use sub_agent_batch(mode="parallel"|"sequential") for self-contained prompts. Data-dependent scouts require separate parent turns so each later prompt can use the earlier report.'
      lines[#lines + 1] =
        "- Prefer direct parent work. Delegate only on explicit request or when a scout has a clear material advantage. Keep any delegation task-sized, non-overlapping, and free of generic surveys, duplicate review, or post-implementation fan-out."
    end

    lines[#lines + 1] =
      "- Scouts are read-only: they cannot edit, run shell commands, create fixtures, or execute a CLI. Use them for static inspection or web research. The parent owns mutations, runtime evidence, and final verification."
  end
  if parallel_requested and concurrent then
    lines[#lines + 1] = ("- The user explicitly requested parallel research. Emit all independent sub_agent calls together in THIS response (one call per requested, non-overlapping role, with explicit model and effort); do not add generic extra reviewers or serialize them across later turns. A single concrete prerequisite command batch is allowed first only when every scout needs its runtime evidence. Dependent work remains sequential. Up to %d scouts run concurrently; additional justified scouts queue rather than being rejected."):format(
      max_parallel
    )
  elseif p.mode == "max" then
    lines[#lines + 1] =
      "- Spend the extra budget on deeper single-agent analysis and verification rather than automatic fan-out."
  elseif p.mode == "ultra" then
    lines[#lines + 1] = concurrent
        and "- Use task-sized parallel fan-out for complex work that divides cleanly; more scouts are not inherently better. Keep dependent investigations sequential."
      or "- Keep dependent investigations sequential and respect the globally disabled parallel scheduler."
  end
  if p.mode == "low" then
    lines[#lines + 1] = "- Use the cheapest targeted verification that can catch a regression."
  elseif p.mode == "medium" then
    lines[#lines + 1] = "- Run focused checks for the behavior you changed."
  elseif p.mode == "high" or p.mode == "xhigh" then
    lines[#lines + 1] = "- Verify changed behavior and inspect relevant diagnostics or tests before finishing."
  else
    lines[#lines + 1] = "- Use the strongest practical targeted verification and resolve failures before finishing."
  end
  return table.concat(lines, "\n")
end

return M
