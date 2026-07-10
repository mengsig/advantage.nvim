---@brief Model-aware reasoning/thinking controls shared by the UI and providers.
---Provider generations do not expose the same knobs: current OpenAI models use
---`reasoning.effort`, modern Claude models use adaptive thinking plus
---`output_config.effort`, and older Claude models use fixed thinking budgets.
---Keeping the capability logic here prevents the picker from offering values
---that the selected model will reject.
local M = {}

local OPENAI_LABELS = {
  none = "off · no reasoning",
  minimal = "minimal",
  low = "low",
  medium = "medium",
  high = "high",
  xhigh = "xhigh · extra high",
  max = "max · maximum",
  ultra = "max · legacy Ultra alias",
}

-- Reasoning levels are ordered so a provider-wide quality default can be
-- lowered safely for a model/transport whose catalogue stops earlier. This is
-- deliberately one-way: an inherited `ultra` may become `max`/`xhigh`, while an
-- explicit per-model value is never rewritten behind the user's back.
local OPENAI_RANK = {
  none = 0,
  minimal = 1,
  low = 2,
  medium = 3,
  high = 4,
  xhigh = 5,
  max = 6,
  ultra = 7,
}

local ADAPTIVE_LABELS = {
  low = "low · fastest",
  medium = "medium · balanced",
  high = "high · API default",
  xhigh = "xhigh · coding/agentic",
  max = "max · frontier problems",
}

local LEGACY_ITEMS = {
  { label = "default · model config", value = "default", aliases = { "default", "auto", "adaptive" } },
  { label = "off", value = false, aliases = { "off", "none", "disabled" } },
  { label = "low · 1k budget", value = 1024, aliases = { "low", "1k" } },
  { label = "medium · 4k budget", value = 4096, aliases = { "medium", "4k", "think" } },
  { label = "high · 8k budget", value = 8192, aliases = { "high", "8k" } },
  { label = "higher · 10k budget", value = 10000, aliases = { "higher", "10k", "think-hard", "think_hard" } },
  {
    label = "highest · 16k budget",
    value = 16384,
    aliases = { "highest", "16k", "think-harder", "think_harder" },
  },
  { label = "max · 32k budget", value = 31999, aliases = { "max", "32k", "ultra", "ultrathink" } },
}

local function copy_items(items)
  return vim.deepcopy(items)
end

local function values_set(values)
  local out = {}
  for _, value in ipairs(values or {}) do
    out[value] = true
  end
  return out
end

---Reasoning levels accepted by an OpenAI model. Explicit model metadata wins;
---the fallback matches current general-purpose GPT-5.x models. Legacy GPT-5
---users can set `reasoning_efforts` on their model entry to include `minimal`.
function M.openai_levels(model, transport)
  if transport == nil then
    local ok, hinted = pcall(function()
      return require("advantage.auth").openai_mode_hint()
    end)
    transport = ok and hinted or "chatgpt"
  end
  local configured = transport == "api_key" and model.api_reasoning_efforts or model.reasoning_efforts
  if type(configured) == "table" and #configured > 0 then return vim.deepcopy(configured) end
  local id = tostring(model.id or ""):lower()
  if transport == "chatgpt" then
    if id:find("gpt%-5%.6%-sol") or id:find("gpt%-5%.6%-terra") then
      return { "low", "medium", "high", "xhigh", "max" }
    end
    if id:find("gpt%-5%.6%-luna") then return { "low", "medium", "high", "xhigh", "max" } end
    return { "low", "medium", "high", "xhigh" }
  end
  -- Keep the built-in raw-API profiles available even when a compact/scout
  -- request intentionally carries only the model id rather than the full picker
  -- metadata. This mirrors the declarations in config.defaults.models.
  if id:find("gpt%-5%.6%-sol") or id:find("gpt%-5%.6%-terra") or id:find("gpt%-5%.6%-luna") then
    return { "none", "low", "medium", "high", "xhigh", "max" }
  end
  if id:find("gpt%-5%.5") then return { "none", "low", "medium", "high", "xhigh" } end
  if id:find("codex", 1, true) then return { "low", "medium", "high", "xhigh" } end
  if id:match("^gpt%-5%.1") then return { "none", "low", "medium", "high" } end
  if id:match("^gpt%-5$") or id:match("^gpt%-5%-") then return { "minimal", "low", "medium", "high" } end
  return { "none", "low", "medium", "high", "xhigh" }
end

---Resolve the effort that will actually be sent for an OpenAI request.
---An explicit model override is authoritative and errors when unsupported. A
---provider-wide default is inherited; when it is deeper than this
---model/transport permits, it is clamped to the deepest supported level.
---@param model table
---@param transport "chatgpt"|"api_key"|nil
---@param provider_effort string|nil
---@return string|nil effort
---@return string|nil err
---@return {inherited:boolean, clamped_from:string|nil} info
function M.resolve_openai(model, transport, provider_effort)
  if transport == nil then
    local ok, hinted = pcall(function()
      return require("advantage.auth").openai_mode_hint()
    end)
    transport = ok and hinted or "chatgpt"
  end
  local levels = M.openai_levels(model, transport)
  local allowed = values_set(levels)
  local explicit = model.reasoning_effort
  -- Sessions saved before explicit `none` used boolean false. Preserve their
  -- old intent without weakening validation for current string-valued settings.
  if explicit == false then explicit = transport == "api_key" and "none" or "low" end
  local inherited = explicit == nil
  local requested = inherited and provider_effort or explicit

  if requested == nil then return nil, nil, { inherited = true, clamped_from = nil } end
  -- Sessions/configs from before harness modes stored Ultra in the effort
  -- field. Preserve them as Max reasoning; orchestration is now independent.
  if requested == "ultra" and allowed.max then
    return "max", nil, { inherited = inherited, clamped_from = nil, legacy_ultra = true }
  end
  if allowed[requested] then return requested, nil, { inherited = inherited, clamped_from = nil } end

  if inherited then
    local requested_rank = OPENAI_RANK[requested]
    local deepest, deepest_rank = nil, -1
    for _, candidate in ipairs(levels) do
      local rank = OPENAI_RANK[candidate]
      if rank and rank > deepest_rank then
        deepest, deepest_rank = candidate, rank
      end
    end
    -- Only clamp downward. In particular, never turn an inherited unsupported
    -- `none` into maximum reasoning, or silently promote any other low setting.
    if requested_rank and deepest and requested_rank > deepest_rank then
      return deepest, nil, { inherited = true, clamped_from = requested }
    end
  end

  local source = inherited and "provider default" or "explicit model override"
  return nil,
    ("OpenAI %s effort %q is unsupported by %s on the %s transport (supported: %s)"):format(
      source,
      tostring(requested),
      tostring(model.id),
      tostring(transport or "selected"),
      table.concat(levels, ", ")
    ),
    { inherited = inherited, clamped_from = nil }
end

function M.openai_items(model)
  local out = { { label = "default · provider config", value = "default", aliases = { "default", "auto" } } }
  for _, level in ipairs(M.openai_levels(model)) do
    out[#out + 1] = {
      label = OPENAI_LABELS[level] or level,
      value = level,
      aliases = level == "none" and { "none", "off", "disabled" } or { level },
    }
  end
  return out
end

---Apply an OpenAI effort alias to a live model. Returns display label or
---(nil, error). `none` is sent explicitly; omitting reasoning would merely let
---the API choose its default and therefore would not actually turn it off.
function M.set_openai(model, mode)
  mode = tostring(mode or ""):lower()
  if mode == "ultra" then mode = "max" end -- pre-harness-mode compatibility
  if mode == "auto" then mode = "default" end
  if mode == "off" or mode == "disabled" then mode = "none" end
  if mode == "default" then
    model.reasoning_effort = nil
    return "default · provider config"
  end
  local levels = M.openai_levels(model)
  local allowed = values_set(levels)
  if not allowed[mode] then
    return nil, "supported OpenAI efforts for this model/transport: default, " .. table.concat(levels, ", ")
  end
  model.reasoning_effort = mode
  return OPENAI_LABELS[mode] or mode
end

---Claude thinking generation. Model metadata is authoritative; inference keeps
---custom entries useful without making every user annotate current model IDs.
---  adaptive         explicit `{type=adaptive}` enables thinking; omission is off
---  adaptive_default thinking is on when omitted; `{type=disabled}` turns it off
---  adaptive_always  thinking is always on and cannot be disabled
---  manual            legacy fixed `budget_tokens` controls
function M.anthropic_mode(model)
  if model.thinking_mode then return model.thinking_mode end
  local id = tostring(model.id or ""):lower()
  if id:find("fable%-5") or id:find("mythos%-5") then return "adaptive_always" end
  if id:find("sonnet%-5") or id:find("mythos%-preview") then return "adaptive_default" end
  if id:find("haiku%-4%-5") or id:find("opus%-4%-5") then return "manual" end
  if id:find("opus%-4%-[678]") or id:find("sonnet%-4%-6") then return "adaptive" end
  -- A future or custom model may reject both adaptive thinking and legacy
  -- budgets. Omission is the only forward-compatible default; users can declare
  -- `thinking_mode`/`effort_levels` once that model's contract is known.
  return "unknown"
end

function M.anthropic_levels(model)
  if type(model.effort_levels) == "table" and #model.effort_levels > 0 then return vim.deepcopy(model.effort_levels) end
  return { "low", "medium", "high", "xhigh", "max" }
end

function M.anthropic_items(model)
  local mode = M.anthropic_mode(model)
  if mode == "manual" then return copy_items(LEGACY_ITEMS) end
  if mode == "unknown" then
    return { { label = "default · model behavior", value = "default", aliases = { "default", "auto" } } }
  end
  local out = {
    { label = "default · API high", value = "default", aliases = { "default", "auto", "adaptive" } },
  }
  for _, level in ipairs(M.anthropic_levels(model)) do
    out[#out + 1] = { label = ADAPTIVE_LABELS[level] or level, value = level, aliases = { level } }
  end
  if mode ~= "adaptive_always" then
    out[#out + 1] = { label = "off", value = false, aliases = { "off", "none", "disabled" } }
  end
  return out
end

local function find_item(items, mode)
  for _, item in ipairs(items) do
    for _, alias in ipairs(item.aliases) do
      if alias == mode then return item end
    end
  end
end

---Apply a Claude effort/thinking alias to a live model. Modern adaptive models
---store soft effort separately from the thinking enablement state; manual models
---retain fixed budgets for compatibility with Haiku 4.5 and older generations.
function M.set_anthropic(model, mode)
  mode = tostring(mode or ""):lower()
  local thinking_mode = M.anthropic_mode(model)
  -- Keep the sub-agent effort contract provider-neutral: `xhigh` is the modern
  -- spelling and maps to the legacy 16k "highest" budget on Haiku 4.5/manual
  -- models instead of forcing the parent to memorize generation-specific names.
  if thinking_mode == "manual" and mode == "xhigh" then mode = "highest" end
  local items = M.anthropic_items(model)
  local item = find_item(items, mode)
  if not item then
    local names = {}
    for _, candidate in ipairs(items) do
      names[#names + 1] = candidate.aliases[1]
    end
    return nil, "supported Claude efforts for this model: " .. table.concat(names, ", ")
  end

  if thinking_mode == "manual" then
    model.effort = nil
    if item.value == "default" then
      model.thinking = vim.deepcopy(model.default_thinking)
      model.thinking_budget = nil
    elseif item.value == false then
      model.thinking = false
      model.thinking_budget = nil
    else
      model.thinking = { type = "enabled", budget_tokens = item.value }
      model.thinking_budget = nil
    end
  else
    -- `false` controls thinking enablement, not output_config.effort. Sending
    -- `{ effort = false }` is invalid on modern Claude APIs.
    model.effort = (item.value == "default" or item.value == false) and nil or item.value
    -- Any real effort selection enables the model's native adaptive mode. Off is
    -- represented separately and translated per generation by the provider.
    if item.value == false then
      model.thinking = false
    else
      model.thinking = nil
    end
    model.thinking_budget = nil
  end
  return item.label
end

function M.openai_selected(model, item)
  return item.value == "default" and model.reasoning_effort == nil or model.reasoning_effort == item.value
end

function M.anthropic_selected(model, item)
  local mode = M.anthropic_mode(model)
  if mode ~= "manual" then
    if item.value == "default" then return model.thinking ~= false and model.effort == nil end
    if item.value == false then return model.thinking == false end
    return model.thinking ~= false and model.effort == item.value
  end
  if item.value == "default" then
    return vim.deep_equal(model.thinking, model.default_thinking)
      or (model.thinking == nil and model.default_thinking == nil)
  end
  if item.value == false then return model.thinking == false end
  return type(model.thinking) == "table" and model.thinking.budget_tokens == item.value
end

function M.describe(model)
  if not model then return nil end
  if model.provider == "openai" then
    local configured = ((require("advantage.config").options.providers or {}).openai or {}).reasoning_effort
    local effective, err, info = M.resolve_openai(model, nil, configured)
    if err then return "effort invalid" end
    if info and info.clamped_from then
      return ("effort %s · %s→%s"):format(tostring(effective), info.clamped_from, tostring(effective))
    end
    return "effort " .. tostring(effective or "default")
  elseif model.provider == "anthropic" then
    if M.anthropic_mode(model) == "manual" then
      if model.thinking == false then return "thinking off" end
      if type(model.thinking) == "table" and model.thinking.budget_tokens then
        return ("thinking %dk"):format(math.floor(model.thinking.budget_tokens / 1024 + 0.5))
      end
      return "thinking default"
    end
    if model.thinking == false then return "thinking off" end
    return "effort " .. tostring(model.effort or "high")
  end
end

return M
