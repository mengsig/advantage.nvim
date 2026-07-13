---@brief Provider registry. A provider implements:
---  stream(req) -> {stop: fun()}
---where req = {
---  model    = {id=..., thinking=..., ...},
---  system   = string,
---  messages = canonical messages (Anthropic-shaped content blocks),
---  tools    = Anthropic-format tool schemas,
---  on = {
---    text     = fun(chunk),
---    thinking = fun(chunk),
---    tool_start = fun(id, name),
---    usage    = fun(input_tokens, output_tokens),
---    complete = fun(blocks, stop_reason, usage), -- canonical assistant content
---    error    = fun(msg),
---  },
---}
local M = {}

local registered = {}

function M.register(name, mod)
  assert(type(name) == "string" and name ~= "", "provider name required")
  assert(type(mod) == "table" and type(mod.stream) == "function", "provider stream implementation required")
  local previous = registered[name]
  registered[name] = mod
  local active = true
  return function()
    if not active or registered[name] ~= mod then return false end
    active = false
    registered[name] = previous
    return true
  end
end

function M.get(name)
  if registered[name] then return registered[name] end
  local ok, mod = pcall(require, "advantage.providers." .. name)
  if ok then
    registered[name] = mod
    return mod
  end
  return nil
end

return M
