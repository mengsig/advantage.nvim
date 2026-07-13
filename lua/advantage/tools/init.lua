---@brief Built-in tools registry. The tool *definitions* live in cohesive
---sibling modules (fs, shell, search, web, diag, nav, navgraph, agentic,
---memory_tools);
---this file wires them together and owns the registry, schema, validation and
---feature-gating. Each tool: name, description, input_schema (JSON Schema),
---safe (auto-approved), run(input, ctx, cb) async, preview(input, ctx) for the
---permission card.
local M = {}

local support = require("advantage.tools.support")

M.list = {}

---Register a tool definition. Order of registration is the order tools appear in
---M.schemas(); the modules below are required in the original tool order so the
---emitted schema is unchanged from the pre-split single-file layout.
local function tool(def)
  assert(type(def) == "table" and type(def.name) == "string", "tool: def with a name required")
  assert(type(def.run) == "function", "tool: def.run must be a function")
  M.list[#M.list + 1] = def
end

-- Register each tool group. The require order reproduces the pre-split order:
-- read/write/edit/multi_edit, bash, grep/find_files/list_dir, web_search,
-- diagnostics, LSP/NavGraph navigation, sub_agent/todo_write,
-- remember/use_skill/save_skill.
require("advantage.tools.fs")(tool, support)
require("advantage.tools.shell")(tool, support)
require("advantage.tools.search")(tool, support)
require("advantage.tools.web")(tool, support)
require("advantage.tools.diag")(tool, support)
require("advantage.tools.nav")(tool, support)
require("advantage.tools.navgraph")(tool, support)
require("advantage.tools.agentic")(tool, support)
require("advantage.tools.memory_tools")(tool, support)

-- registry --------------------------------------------------------------

local by_name = {}
for _, def in ipairs(M.list) do
  assert(not by_name[def.name], "duplicate tool name: " .. def.name)
  by_name[def.name] = def
end

function M.get(name)
  return by_name[name]
end

-- Large semantic-discovery results are useful for the next reasoning step but
-- become expensive dead weight once that step has selected exact targets. Keep
-- the policy out-of-band (weak keys) so private harness metadata never reaches
-- Anthropic/OpenAI payloads or session JSON.
local context_policies = setmetatable({}, { __mode = "k" })

function M.mark_context_result(block, def, input, is_error)
  if is_error or type(block) ~= "table" or type(def) ~= "table" then return block end
  if type(block.content) ~= "string" or #block.content < 512 then return block end
  local retention = def.context_retention
  if type(retention) == "function" then retention = retention(input or {}) end
  retention = tonumber(retention)
  if not retention or retention < 1 then return block end
  local receipt = def.context_receipt
  if type(receipt) == "function" then receipt = receipt(input or {}) end
  context_policies[block] = {
    uses = 0,
    retention = math.max(1, math.floor(retention)),
    receipt = tostring(receipt or ("[%s result consumed; rerun a narrower query only if needed]"):format(def.name)),
  }
  return block
end

local function marked_results(messages)
  local marked = {}
  for _, message in ipairs(type(messages) == "table" and messages or {}) do
    for _, block in ipairs(type(message) == "table" and type(message.content) == "table" and message.content or {}) do
      local policy = context_policies[block]
      if policy and type(block.tool_use_id) == "string" then
        marked[#marked + 1] = { block = block, id = block.tool_use_id, policy = policy }
      end
    end
  end
  return marked
end

---Anthropic treats a tool-result continuation as part of the same assistant
---turn. Its latest signed thinking/redacted-thinking blocks and the preceding
---context must remain byte-for-byte unchanged until that continuation finishes.
---Changing an older result while such a turn is pending produces an HTTP 400,
---so receipt aging and compaction must wait for the next completed assistant
---turn. OpenAI transcripts have no signed Anthropic blocks and are unaffected.
function M.has_pending_signed_tool_loop(messages)
  local later_results = {}
  for i = #(type(messages) == "table" and messages or {}), 1, -1 do
    local message = messages[i]
    if type(message) == "table" and message.role == "user" then
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if type(block) == "table" and block.type == "tool_result" and type(block.tool_use_id) == "string" then
          later_results[block.tool_use_id] = true
        end
      end
    elseif type(message) == "table" and message.role == "assistant" then
      local signed, matched_tool = false, false
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if type(block) == "table" and (block.type == "thinking" or block.type == "redacted_thinking") then
          signed = true
        elseif
          type(block) == "table"
          and block.type == "tool_use"
          and type(block.id) == "string"
          and later_results[block.id]
        then
          matched_tool = true
        end
      end
      return signed and matched_tool
    end
  end
  return false
end

---Capture weak-key retention metadata before compaction copies the transcript.
---Only surviving tool results are rebound afterward; summarized-away results
---naturally disappear with their policies.
function M.snapshot_context_results(messages)
  local snapshot = {}
  for _, item in ipairs(marked_results(messages)) do
    snapshot[item.id] = vim.deepcopy(item.policy)
  end
  return snapshot
end

function M.restore_context_results(messages, snapshot)
  if type(snapshot) ~= "table" then return messages end
  for _, message in ipairs(type(messages) == "table" and messages or {}) do
    for _, block in ipairs(type(message) == "table" and type(message.content) == "table" and message.content or {}) do
      local policy = type(block) == "table" and snapshot[block.tool_use_id] or nil
      if policy then context_policies[block] = vim.deepcopy(policy) end
    end
  end
  return messages
end

---Replace marked tool results on a replay-safe copy of the transcript. Changing
---a prior tool output invalidates OpenAI encrypted reasoning/server item IDs and
---Anthropic signed thinking, so receipt elision must detach those artifacts in
---the same atomic transcript replacement.
local function replace_marked(messages, marked, expire_all)
  local replacements, should_replace = {}, false
  for _, item in ipairs(marked) do
    local expired = expire_all or item.policy.uses >= item.policy.retention
    if expired then
      replacements[item.id] = { receipt = item.policy.receipt }
      should_replace = true
    else
      item.policy.uses = item.policy.uses + 1
      replacements[item.id] = { policy = item.policy }
    end
  end
  if not should_replace then return messages, 0 end

  -- Anthropic's signed tool-use protocol forbids changing *any* preceding
  -- context while returning results for the latest assistant tool turn. Defer
  -- the receipt mutation until that continuous turn has completed; `_finish`
  -- will normally collapse it immediately afterward. This is a correctness
  -- boundary, not a model-specific optimization preference.
  if M.has_pending_signed_tool_loop(messages) then return messages, 0 end

  local next_messages, detached = require("advantage.compact").detach_provider_state(messages)
  for _, item in ipairs(marked) do
    context_policies[item.block] = nil
  end
  for _, message in ipairs(next_messages) do
    for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
      local replacement = type(block) == "table" and replacements[block.tool_use_id] or nil
      if replacement then
        if replacement.receipt then
          block.content = replacement.receipt
        elseif replacement.policy then
          context_policies[block] = replacement.policy
        end
      end
    end
  end
  return next_messages, detached
end

---Age marked results exactly once per provider request. The full result reaches
---the configured number of reasoning turns; later requests retain the required
---tool_result pairing but replay only a short, actionable receipt.
function M.age_context_results(messages)
  return replace_marked(messages, marked_results(messages), false)
end

---Expire every pending result at a durable or compaction boundary. Policies are
---deliberately out-of-band, so leaving a full result pending across save/reload
---would lose its expiry state and replay that payload forever.
function M.expire_context_results(messages)
  return replace_marked(messages, marked_results(messages), true)
end

M._context_policies = context_policies

local function live_subagent_turn_cap()
  local subagents = require("advantage.config").options.subagents or {}
  return math.max(2, math.min(tonumber(subagents.max_turns_cap) or 12, 30))
end

local function apply_live_subagent_bounds(name, schema)
  if name ~= "sub_agent" and name ~= "sub_agent_batch" then return schema end
  schema = vim.deepcopy(schema)
  local turns = name == "sub_agent" and schema.properties.max_turns
    or schema.properties.tasks.items.properties.max_turns
  local cap = live_subagent_turn_cap()
  turns.maximum = cap
  turns.description = (turns.description or "Requested scout request ceiling")
    .. (" Live hard maximum: %d; values above it are rejected rather than silently clamped."):format(cap)
  return schema
end

local function definition_schema(def)
  if type(def.live_input_schema) == "function" then return def.live_input_schema() end
  return def.input_schema
end

local function apply_live_bounds(name, schema)
  if type(schema) ~= "table" then return nil end
  schema = apply_live_subagent_bounds(name, schema)
  if name ~= "navgraph" then return schema end
  schema = vim.deepcopy(schema)
  local cfg = ((require("advantage.config").options.tools or {}).navgraph or {})
  local cap = math.max(1, math.min(math.floor(tonumber(cfg.max_results) or 80), 200))
  local limit = schema.properties and schema.properties.limit
  if limit then
    limit.maximum = cap
    limit.description = ("Result/line bound; live configured maximum: %d"):format(cap)
  end
  return schema
end

---Return the live schema a provider should see for one registered tool. This is
---shared by parent and scout surfaces so configured limits cannot diverge.
function M.input_schema(name)
  local def = by_name[name]
  return def and apply_live_bounds(name, definition_schema(def)) or nil
end

local function schema_error(value, schema, path)
  if value == nil or type(schema) ~= "table" then return nil end
  local expected = schema.type
  local actual = type(value)
  local valid = expected == nil
    or (expected == "object" and actual == "table")
    or (expected == "array" and actual == "table")
    or (expected == "string" and actual == "string")
    or (expected == "boolean" and actual == "boolean")
    or (expected == "number" and actual == "number")
    or (expected == "integer" and actual == "number" and value == math.floor(value))
  if not valid then return ("%s must be %s (got %s)"):format(path, expected, actual) end
  if schema.enum and not vim.tbl_contains(schema.enum, value) then
    return ("%s must be one of: %s"):format(path, table.concat(schema.enum, ", "))
  end
  if expected == "string" and schema.minLength and #value < schema.minLength then
    return ("%s must contain at least %d character%s"):format(
      path,
      schema.minLength,
      schema.minLength == 1 and "" or "s"
    )
  end
  if (expected == "number" or expected == "integer") and actual == "number" then
    if schema.minimum ~= nil and value < schema.minimum then
      return ("%s must be at least %s"):format(path, tostring(schema.minimum))
    end
    if schema.maximum ~= nil and value > schema.maximum then
      return ("%s must be at most %s"):format(path, tostring(schema.maximum))
    end
  end
  if expected == "object" then
    local required = {}
    for _, field in ipairs(schema.required or {}) do
      required[field] = true
      if value[field] == nil then return ("%s.%s is required"):format(path, field) end
    end
    if schema.additionalProperties == false then
      for field in pairs(value) do
        if (schema.properties or {})[field] == nil then
          return ("%s.%s is not supported"):format(path, tostring(field))
        end
      end
    end
    for field, child in pairs(schema.properties or {}) do
      -- Models occasionally materialize an omitted optional string as "".
      -- Let the command adapter normalize that omission rather than rejecting it
      -- against an optional enum before the adapter can apply its default.
      local child_value = value[field]
      local err = child_value == "" and not required[field] and nil
        or schema_error(child_value, child, path .. "." .. field)
      if err then return err end
    end
  elseif expected == "array" then
    if schema.minItems ~= nil and #value < schema.minItems then
      return ("%s must contain at least %d item%s"):format(path, schema.minItems, schema.minItems == 1 and "" or "s")
    end
    if schema.maxItems ~= nil and #value > schema.maxItems then
      return ("%s must contain at most %d item%s"):format(path, schema.maxItems, schema.maxItems == 1 and "" or "s")
    end
    for i, item in ipairs(value) do
      local err = schema_error(item, schema.items, ("%s[%d]"):format(path, i))
      if err then return err end
    end
  end
end

---Validate a decoded tool input against its schema's `required` list. Models
---intermittently drop a required argument (classically `path` on edit_file when
---the big `new_string` field dominates the call), and a truncated tool-call
---stream decodes to an empty object. Both used to fail deep inside the tool with
---a cryptic, tool-specific message ("Cannot edit nil: empty path"), which the
---model tends to repeat rather than correct. Returning a precise, uniform error
---up front turns that into a one-shot self-correction.
---@return string|nil err  nil if valid, else a message naming the missing args
function M.validate_input(name, input)
  local def = by_name[name]
  local schema = def and apply_live_bounds(name, definition_schema(def))
  if not schema then return nil end
  if type(input) ~= "table" then return ("%s: input must be object (got %s)"):format(name, type(input)) end
  local req = schema.required or {}
  local missing = {}
  for _, field in ipairs(req) do
    -- Present-but-empty is the tool's own concern (e.g. edit_file new_string=""
    -- deletes text); "required" only means the key must be supplied.
    if input[field] == nil then missing[#missing + 1] = field end
  end
  if #missing == 0 then
    local err = schema_error(input, schema, "input")
    return err and (name .. ": " .. err) or nil
  end
  local provided = {}
  for k in pairs(input) do
    provided[#provided + 1] = k
  end
  table.sort(provided)
  return ("%s: missing required argument%s: %s. %s"):format(
    name,
    #missing == 1 and "" or "s",
    table.concat(missing, ", "),
    #provided > 0 and ("You provided: " .. table.concat(provided, ", ") .. ".")
      or "You provided no arguments — re-issue the call with all required fields."
  )
end

---Resolve a tool path argument against the project root (for snapshots etc).
M.resolve = support.resolve
M.read_all = support.read_all

---The configured web_search key (inline api_key wins over api_key_env). Kept as
---a module field for callers/tests that inspect it.
M._web_search_key = support.web_search_key

---Whether a tool that is gated on a config-toggled feature is currently enabled.
---`memory` tools follow config.memory.enabled; `feature = "diagnostics"` tools
---follow config.tools.diagnostics.enabled. Web search can use an API-backed or
---unkeyed fallback; web_fetch is independently available with curl. Ungated
---tools are always enabled.
function M.enabled(def)
  assert(type(def) == "table", "M.enabled: def must be a table")
  if def.memory then
    local m = require("advantage.config").options.memory
    return not m or m.enabled ~= false
  end
  if def.feature == "diagnostics" then
    local t = (require("advantage.config").options.tools or {}).diagnostics
    return not (type(t) == "table" and t.enabled == false)
  end
  if def.feature == "web_search" then
    local t = (require("advantage.config").options.tools or {}).web_search
    if not (type(t) == "table" and t.enabled ~= false) then return false end
    local backend = t.backend or "auto"
    if backend == "brave_api" then return support.web_search_key(t) ~= nil end
    return support.web_search_key(t) ~= nil or t.allow_unkeyed ~= false
  end
  if def.feature == "web_fetch" then
    local t = (require("advantage.config").options.tools or {}).web_fetch
    return type(t) == "table" and t.enabled ~= false and vim.fn.executable("curl") == 1
  end
  if def.feature == "lsp" then
    local t = (require("advantage.config").options.tools or {}).lsp
    if type(t) == "table" and t.enabled == false then return false end
    local ok, lsp = pcall(require, "advantage.lsp")
    return ok and lsp.available()
  end
  if def.feature == "navgraph" then
    local t = (require("advantage.config").options.tools or {}).navgraph
    if type(t) ~= "table" or t.enabled ~= true then return false end
    return require("advantage.navgraph_capabilities").profile(t) ~= nil
  end
  if def.feature == "subagents" then
    local t = require("advantage.config").options.subagents
    return not (type(t) == "table" and t.enabled == false)
  end
  return true
end

---Tool schemas in Anthropic format (providers convert as needed).
function M.schemas(parent_model)
  local out = {}
  for _, def in ipairs(M.list) do
    if M.enabled(def) then
      local input_schema = apply_live_bounds(def.name, definition_schema(def))
      local include = input_schema ~= nil
      if def.name == "sub_agent" or def.name == "sub_agent_batch" then
        local choices, mappings = {}, {}
        local ok_aliases, available = pcall(function()
          local subagent = require("advantage.subagent")
          return type(subagent.available_model_aliases) == "function" and subagent.available_model_aliases(parent_model)
            or {}
        end)
        for _, item in ipairs(ok_aliases and available or {}) do
          choices[#choices + 1] = item.alias
          mappings[#mappings + 1] = item.alias .. " → " .. item.ref
        end
        if #choices > 0 then
          local model_schema = def.name == "sub_agent" and input_schema.properties.model
            or input_schema.properties.tasks.items.properties.model
          model_schema.enum = choices
          model_schema.description = "Required explicit scout route. Available aliases: "
            .. table.concat(mappings, "; ")
            .. ". Never send a raw/versioned first-party model ID."
          local preferred = (require("advantage.config").options.subagents or {}).model
          if type(preferred) == "string" and vim.tbl_contains(choices, preferred) then
            model_schema.description = model_schema.description .. " The user preference is " .. preferred .. "."
          end
        else
          -- All configured scout routes are in a deterministic cooldown (for
          -- example an OAuth refresh failure). Withhold the tool for this parent
          -- round so the model cannot retry the same provider under another ID.
          include = false
        end
      end
      if include then
        out[#out + 1] = {
          name = def.name,
          description = def.description,
          input_schema = input_schema,
        }
      end
    end
  end
  return out
end

return M
