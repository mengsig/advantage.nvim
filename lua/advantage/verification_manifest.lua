local M = {}

local MAX_FILE_BYTES = 64 * 1024
local MAX_COMMANDS = 20
local MAX_COMMAND_BYTES = 2000

local function trust_path()
  return M._trust_path_override or (vim.fn.stdpath("data") .. "/advantage/verification-trust.json")
end

local function read_file(path, max_bytes)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read(max_bytes + 1)
  file:close()
  if #content > max_bytes then return nil, "manifest exceeds 64 KiB" end
  return content
end

local function manifest_path(root, relative)
  assert(type(root) == "string" and root ~= "", "verification root required")
  assert(type(relative) == "string" and relative ~= "", "verification manifest path required")
  local normalized_root = vim.fs.normalize(root)
  local path = vim.fs.normalize(normalized_root .. "/" .. relative)
  if path ~= normalized_root and path:sub(1, #normalized_root + 1) ~= normalized_root .. "/" then
    return nil, "manifest path escapes the project root"
  end
  local uv = vim.uv or vim.loop
  local real_path = uv.fs_realpath(path)
  local real_root = uv.fs_realpath(normalized_root) or normalized_root
  if real_path and real_path ~= real_root and real_path:sub(1, #real_root + 1) ~= real_root .. "/" then
    return nil, "manifest symlink escapes the project root"
  end
  return path
end

local function validate(decoded)
  if type(decoded) ~= "table" or decoded.version ~= 1 then return nil, "version must be 1" end
  if type(decoded.commands) ~= "table" or not vim.islist(decoded.commands) then
    return nil, "commands must be a JSON array"
  end
  if #decoded.commands > MAX_COMMANDS then return nil, "commands exceeds the 20-command limit" end
  local commands = {}
  for index, command in ipairs(decoded.commands) do
    if type(command) ~= "string" or vim.trim(command) == "" then
      return nil, ("commands[%d] must be a non-empty string"):format(index)
    end
    if #command > MAX_COMMAND_BYTES then return nil, ("commands[%d] exceeds 2000 bytes"):format(index) end
    commands[index] = command
  end
  return commands
end

local function read_trust()
  local content = read_file(trust_path(), 1024 * 1024)
  if not content then return {} end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then return {} end
  return decoded
end

local function write_trust(state)
  assert(type(state) == "table", "verification trust state must be a table")
  local ok, encoded = pcall(vim.json.encode, state)
  if not ok then return nil, "could not encode verification trust state" end
  local saved, err = require("advantage.tools.support").write_all(trust_path(), encoded)
  if not saved then return nil, err end
  return true
end

function M.load(root, relative)
  local path, path_err = manifest_path(root, relative)
  if not path then return { path = relative, commands = {}, error = path_err } end
  local content, read_err = read_file(path, MAX_FILE_BYTES)
  if not content then return { path = relative, absolute_path = path, commands = {}, error = read_err } end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then return { path = relative, absolute_path = path, commands = {}, error = "invalid JSON" } end
  local commands, validation_err = validate(decoded)
  if not commands then return { path = relative, absolute_path = path, commands = {}, error = validation_err } end
  return {
    path = relative,
    absolute_path = path,
    commands = commands,
    hash = require("advantage.util").hash_parts({ content }),
  }
end

function M.is_trusted(root, snapshot)
  assert(type(root) == "string" and root ~= "", "verification trust root required")
  assert(type(snapshot) == "table", "verification snapshot required")
  if not snapshot.hash then return false end
  return read_trust()[vim.fs.normalize(root)] == snapshot.hash
end

function M.trust(root, snapshot)
  assert(type(root) == "string" and root ~= "", "verification trust root required")
  assert(type(snapshot) == "table" and type(snapshot.hash) == "string", "hashable verification snapshot required")
  local state = read_trust()
  state[vim.fs.normalize(root)] = snapshot.hash
  return write_trust(state)
end

return M
