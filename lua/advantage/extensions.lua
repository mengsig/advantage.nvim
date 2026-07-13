---@brief Small, zero-default-cost extension registry. Extensions can add tools,
---providers, harness presets, and stable system-prompt parts without modifying
---the core registry files.
local M = {}

local prompt_parts = {}
local prompt_by_name = {}
local loaded = {}
local prompt_failures = {}

function M.register_prompt_part(name, build)
  assert(type(name) == "string" and name ~= "", "extension prompt part: name required")
  assert(type(build) == "function", "extension prompt part: builder function required")
  assert(not prompt_by_name[name], "duplicate extension prompt part: " .. name)
  local item = { name = name, build = build }
  prompt_failures[name] = nil
  prompt_parts[#prompt_parts + 1] = item
  prompt_by_name[name] = item
  local active = true
  return function()
    if not active or prompt_by_name[name] ~= item then return false end
    active = false
    prompt_by_name[name] = nil
    for i, candidate in ipairs(prompt_parts) do
      if candidate == item then
        table.remove(prompt_parts, i)
        break
      end
    end
    return true
  end
end

---Build extension prompt parts. Agents call this while freezing their base
---prompt, so builders do not run on every provider round-trip.
function M.prompt_text(cwd)
  if #prompt_parts == 0 then return "" end
  local out = {}
  for _, item in ipairs(prompt_parts) do
    local ok, text = pcall(item.build, { cwd = cwd, config = require("advantage.config").options })
    if not ok then
      if not prompt_failures[item.name] then
        prompt_failures[item.name] = true
        vim.schedule(function()
          vim.notify(
            ("advantage: extension prompt part %q failed — %s"):format(item.name, tostring(text)),
            vim.log.levels.ERROR
          )
        end)
      end
    elseif type(text) == "string" and text ~= "" then
      out[#out + 1] = text
    end
  end
  return table.concat(out, "\n\n")
end

local API = {
  register_tool = function(def)
    return require("advantage.tools").register(def)
  end,
  register_provider = function(name, provider)
    return require("advantage.providers").register(name, provider)
  end,
  register_harness = function(name, policy)
    return require("advantage.harness").register(name, policy)
  end,
  register_prompt_part = M.register_prompt_part,
}

local function activate(spec)
  if loaded[spec] then return true end
  local value, key = spec, spec
  if type(spec) == "string" then
    local ok, module = pcall(require, spec)
    if not ok then return nil, ("could not load extension %q: %s"):format(spec, tostring(module)) end
    value = module
  end
  if type(value) == "function" then
    value(API)
  elseif type(value) == "table" and type(value.setup) == "function" then
    value.setup(API)
  elseif type(value) ~= "table" then
    return nil, "extension must be a module name, setup function, or table with setup(api)"
  end
  loaded[key] = true
  return true
end

---Load configured extensions once. Repeated setup() calls remain idempotent.
---@return string[] errors
function M.load(specs)
  if specs == nil then return {} end
  if type(specs) ~= "table" then return { "extensions must be a list" } end
  local errors = {}
  for i, spec in ipairs(specs) do
    local ok, activated, load_err = pcall(activate, spec)
    if not ok then
      errors[#errors + 1] = ("extensions[%d] failed: %s"):format(i, tostring(activated))
    elseif not activated then
      errors[#errors + 1] = ("extensions[%d] failed: %s"):format(i, tostring(load_err or "unknown error"))
    end
  end
  return errors
end

M.api = API
M._prompt_parts = prompt_parts

return M
