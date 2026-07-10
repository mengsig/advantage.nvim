---@brief Built-in tools registry. The tool *definitions* live in cohesive
---sibling modules (fs, shell, search, web, diag, nav, agentic, memory_tools);
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
-- diagnostics, lsp navigation, sub_agent/todo_write, remember/use_skill/save_skill.
require("advantage.tools.fs")(tool, support)
require("advantage.tools.shell")(tool, support)
require("advantage.tools.search")(tool, support)
require("advantage.tools.web")(tool, support)
require("advantage.tools.diag")(tool, support)
require("advantage.tools.nav")(tool, support)
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
    for _, field in ipairs(schema.required or {}) do
      if value[field] == nil then return ("%s.%s is required"):format(path, field) end
    end
    for field, child in pairs(schema.properties or {}) do
      local err = schema_error(value[field], child, path .. "." .. field)
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
  local schema = def and apply_live_subagent_bounds(name, def.input_schema)
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
      local input_schema = def.input_schema
      local include = true
      if def.name == "sub_agent" or def.name == "sub_agent_batch" then
        input_schema = apply_live_subagent_bounds(def.name, input_schema)
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
