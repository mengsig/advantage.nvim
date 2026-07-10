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
  if not enabled then
    lines[#lines + 1] = "- Sub-agents are disabled. Work directly and keep verification proportional to this mode."
  elseif #choices == 0 and route_state == "unconfigured" then
    lines[#lines + 1] =
      "- No valid sub-agent aliases are configured. Fix subagents.model_aliases/models; work directly until routes are available."
  elseif #choices == 0 then
    lines[#lines + 1] =
      "- All configured sub-agent routes are temporarily unavailable after a deterministic provider/model failure. Do not retry or guess IDs; continue directly with parent tools."
  elseif p.proactive and concurrent then
    lines[#lines + 1] = model_instruction
    lines[#lines + 1] =
      '- When two or more independent scouts materially help, use one sub_agent_batch(mode="parallel") in the initial investigation turn. Never serialize independent scouts across later turns. Batch mode="sequential" only serializes self-contained prompts; for a true data dependency, wait for the report and issue the dependent scout from a later parent turn.'
    lines[#lines + 1] = ("- Proactively CONSIDER delegation, but it is optional: direct parent work is normally better for a simple/localized defect or a greenfield implementation. Size the first wave to distinct unresolved domains (up to %d concurrent), with no generic architecture, test-survey, validation-workflow, or duplicate-review scout."):format(
      max_parallel
    )
    lines[#lines + 1] =
      "- The concurrency width is not a scout-count quota: a larger justified wave may queue, but every added scout needs a distinct non-overlapping question. Prefer more short focused scouts over a few broad scouts that each consume their full turn ceiling."
    lines[#lines + 1] =
      "- Use one initial scout wave by default, then synthesize and ACT. A later wave is only for a new concrete blocker exposed by evidence; never start post-implementation scouts merely to review code or rerun validation. The parent owns mutations and final verification."
    lines[#lines + 1] =
      "- Keep scouts task-proportional: medium/high effort and about 3-6 turns normally suffice. Use 8-12 turns only for one genuinely deep isolated blocker; never give every member of a breadth-oriented wave the maximum."
    lines[#lines + 1] =
      "- Scouts are read-only and cannot run shell commands, create fixtures, or execute a CLI. Assign them static inspection or web research only. If every scout depends on shared runtime evidence, the parent may run one bounded prerequisite command batch before fan-out and include that evidence in the scout prompts."
  elseif p.proactive then
    lines[#lines + 1] = model_instruction
    lines[#lines + 1] =
      '- You may use sub_agent_batch(mode="sequential") to serialize self-contained scouts. It does not feed earlier reports into later batch prompts; issue genuinely dependent scouts from separate parent turns.'
    lines[#lines + 1] =
      "- Proactively consider a scout only when its evidence will materially reduce parent work. Direct work is normally better for localized defects and greenfield implementation; never delegate generic repository/test surveys or duplicate review."
    lines[#lines + 1] =
      "- Use one initial wave by default, then synthesize and act. Further sequential scouts require a concrete dependency on the previous report; never launch post-implementation review scouts. The parent owns mutations and final verification."
    lines[#lines + 1] =
      "- Medium/high effort and about 3-6 turns normally suffice for a scoped scout; reserve 8-12 turns for one concrete hard blocker, never a whole breadth wave. Scouts cannot run shell commands or create fixtures; the parent owns runtime verification."
  else
    lines[#lines + 1] = model_instruction
    lines[#lines + 1] =
      '- You may use sub_agent_batch(mode="parallel"|"sequential") to choose concurrency for self-contained prompts. Data-dependent scouts require separate parent turns so the later prompt can use the earlier report.'
    lines[#lines + 1] =
      "- Prefer direct parent work. Delegate only on explicit request or when a scout has a clear, material advantage."
    lines[#lines + 1] =
      "- If delegation is useful, size it to distinct unresolved domains and do not manufacture generic surveys, duplicate review, or post-implementation fan-out. For dependent work, wait for the first report before issuing the next scout."
    lines[#lines + 1] =
      "- Scouts cannot run shell commands, create fixtures, or execute a CLI. Use them for static inspection or web research; keep runtime verification in the parent."
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
