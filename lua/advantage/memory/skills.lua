---@brief Skills subsystem for repo memory: scan/parse SKILL.md files, the
---on-demand body loader (use_skill), and deterministic prompt-relevance hinting.
---Extracted from memory.lua. To avoid a circular require, memory.lua injects its
---shared IO/text helpers and a reference to itself via S.setup() at load time;
---this module reads live facade state (M._session, M.root, M.enabled) at call
---time so session resets and root overrides are always honored.
local uv = vim.uv or vim.loop

local S = {}

---@class SkillsDeps
---@field mem table facade module (live _session, root(), enabled(), render())
---@field read_file fun(path: string, max_bytes?: integer): string|nil, boolean
---@field write_file fun(path: string, content: string): boolean|nil, string|nil
---@field tokens fun(s: string?): integer
---@field opts fun(): table
---@field skills_dir fun(): string
---@field word_set fun(s: string?): table, integer

-- Injected by memory.lua at load via S.setup(); read at call time.
---@type SkillsDeps
local deps = nil

---Wire in the shared helpers from memory.lua. Must be called before any other
---function here (memory.lua does so at load time).
function S.setup(d)
  assert(type(d) == "table" and type(d.mem) == "table", "skills.setup: deps.mem (facade module) required")
  assert(
    type(d.read_file) == "function" and type(d.write_file) == "function" and type(d.skills_dir) == "function",
    "skills.setup: read_file/write_file/skills_dir helpers required"
  )
  assert(type(d.tokens) == "function" and type(d.word_set) == "function", "skills.setup: tokens/word_set required")
  deps = d
end

---Parse `---` frontmatter (key: value) + body from a SKILL.md.
function S.parse_skill(text)
  local name, desc, body_start, meta = nil, nil, 1, {}
  local lines = vim.split(text, "\n", { plain = true })
  if lines[1] == "---" then
    local i = 2
    while i <= #lines and lines[i] ~= "---" do
      local k, v = lines[i]:match("^([%w_-]+):%s*(.*)$")
      if k == "name" then
        name = vim.trim(v)
      elseif k == "description" then
        desc = vim.trim(v)
      end
      if k then meta[k] = vim.trim(v) end
      i = i + 1
    end
    body_start = i + 1
  end
  local body = table.concat(vim.list_slice(lines, body_start), "\n")
  return name, desc, vim.trim(body), meta
end

-- Cache parsed skills across turns. `render()`/`skill_hints()`/`stats()` all scan
-- on every system-prompt build; without this each turn re-reads and frontmatter-
-- parses every SKILL.md. Keyed by a cheap stat signature (paths + mtime + size)
-- so an add/remove/content-edit invalidates it; save_skill clears it explicitly.
local _skills_cache = { sig = nil, value = nil }
local SKILL_INDEX_READ_BYTES = 16 * 1024
local SKILL_BODY_HARD_MAX_BYTES = 256 * 1024

local function skill_body_cap()
  local value = tonumber(deps.opts().skill_body_budget_tokens) or 8000
  if value ~= value or value == math.huge or value == -math.huge then value = 8000 end
  return math.max(1024, math.min(SKILL_BODY_HARD_MAX_BYTES, math.floor(math.max(1, value) * 4)))
end

local function skill_roots()
  local out, seen = {}, {}
  local candidates = {}
  local primary = deps.skills_dir()
  if primary then candidates[#candidates + 1] = primary end

  -- Open Agent Skills / Codex uses .agents/skills, while Claude Code uses
  -- .claude/skills. Discover both from the launch directory back to the repo
  -- root so one checked-in skill library works across all three harnesses.
  local root, cwd = deps.mem.root(), deps.mem.cwd()
  local dirs = { root }
  if cwd ~= root then
    local current = root
    for segment in cwd:sub(#root + 2):gmatch("[^/]+") do
      current = current .. "/" .. segment
      dirs[#dirs + 1] = current
    end
  end
  for i = #dirs, 1, -1 do
    candidates[#candidates + 1] = dirs[i] .. "/.agents/skills"
  end
  for i = #dirs, 1, -1 do
    candidates[#candidates + 1] = dirs[i] .. "/.claude/skills"
  end
  for _, path in ipairs(candidates) do
    local safe = path and deps.mem.contain(path) or nil
    if safe and not seen[safe] then
      seen[safe] = true
      out[#out + 1] = safe
    end
  end
  return out
end

local function safe_skill_path(root, entry)
  return deps.mem.contain(root .. "/" .. entry .. "/SKILL.md")
end

local function scan_skill_files()
  local files = {}
  for _, root in ipairs(skill_roots()) do
    local dir = uv.fs_scandir(root)
    if dir then
      while true do
        local entry = uv.fs_scandir_next(dir)
        if not entry then break end
        local path = safe_skill_path(root, entry)
        local stat = path and uv.fs_stat(path) or nil
        if stat and stat.type == "file" then
          local metadata_path = deps.mem.contain(root .. "/" .. entry .. "/agents/openai.yaml")
          files[#files + 1] = {
            root = root,
            entry = entry,
            path = path,
            stat = stat,
            metadata_path = metadata_path,
            metadata_stat = metadata_path and uv.fs_stat(metadata_path) or nil,
          }
        end
      end
    end
  end
  return files
end

local function skills_signature(files)
  local parts = {}
  for _, file in ipairs(files) do
    local st = file.stat
    parts[#parts + 1] = ("%s:%d:%d:%d"):format(
      file.path,
      st.mtime and st.mtime.sec or 0,
      st.mtime and st.mtime.nsec or 0,
      st.size or 0
    )
    if file.metadata_stat then
      local mst = file.metadata_stat
      parts[#parts + 1] = ("%s:%d:%d:%d"):format(
        file.metadata_path,
        mst.mtime and mst.mtime.sec or 0,
        mst.mtime and mst.mtime.nsec or 0,
        mst.size or 0
      )
    end
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function openai_allows_implicit(file)
  local text = file.metadata_path and deps.read_file(file.metadata_path, 8 * 1024) or nil
  if not text then return true end
  return text:match("allow_implicit_invocation:%s*false") == nil
end

---Scan skill directories (.advantage/skills and, for interop, .claude/skills).
---Returns { {name=, description=, path=} } sorted by name, de-duplicated by name.
---@return {name:string, description:string, path:string}[]
function S.scan_skills()
  local files = scan_skill_files()
  local sig = skills_signature(files)
  if _skills_cache.sig == sig and _skills_cache.value then return _skills_cache.value end
  local seen, out = {}, {}
  for _, file in ipairs(files) do
    -- Indexing needs only frontmatter. Never read a giant runbook body merely
    -- to discover its name and one-line description.
    local text = deps.read_file(file.path, SKILL_INDEX_READ_BYTES)
    if text and not seen[file.entry] then
      local name, desc, _, meta = S.parse_skill(text)
      name = name or file.entry
      if not seen[name] then
        seen[name] = true
        local implicit = meta["disable-model-invocation"] ~= "true" and openai_allows_implicit(file)
        local name_words = deps.word_set(name:gsub("[-_]", " "))
        local desc_words = deps.word_set(desc or "")
        out[#out + 1] = {
          name = name,
          description = desc or "",
          path = file.path,
          dir = vim.fs.dirname(file.path),
          bytes = file.stat.size or 0,
          implicit = implicit,
          meta = meta,
          _name_words = name_words,
          _desc_words = desc_words,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  _skills_cache.sig, _skills_cache.value = sig, out
  return out
end

function S.skills_index()
  return S.scan_skills()
end

---Return the full body of a skill by name, or nil.
function S.use_skill(name)
  name = vim.trim(tostring(name or ""))
  local session = deps.mem._session
  for _, s in ipairs(S.scan_skills()) do
    if s.name == name then
      local cap = skill_body_cap()
      local text, file_truncated = deps.read_file(s.path, cap + SKILL_INDEX_READ_BYTES)
      local _, _, body = S.parse_skill(text or "")
      if file_truncated or #body > cap then
        local marker = "\n… [skill body truncated at safety limit]"
        body = require("advantage.util").utf8_safe_sub(body, math.max(0, cap - #marker)) .. marker
      end
      if body then
        session.loaded[name] = true
        session.skill_loads = session.skill_loads + 1
        session.skill_load_tokens = session.skill_load_tokens + deps.tokens(body)
      end
      return body, s.description, s
    end
  end
  return nil
end

---Deterministically pick skills relevant to a prompt: significant-word overlap
---against the skill's name (weighted) and description. No embeddings, no model
---call. Each skill is hinted at most once per session, and never after its body
---was already loaded.
---@return { name: string, description: string }[]
function S.skill_hints(text, limit)
  if not deps.mem.enabled() then return {} end
  local pw, pn = deps.word_set(text)
  if pn == 0 then return {} end
  local session = deps.mem._session
  local scored = {}
  for _, s in ipairs(S.scan_skills()) do
    if s.implicit ~= false and not session.loaded[s.name] and not session.hinted[s.name] then
      local score = 0
      for w in pairs(s._name_words or {}) do
        if pw[w] then score = score + 3 end
      end
      for w in pairs(s._desc_words or {}) do
        if pw[w] then score = score + 1 end
      end
      if score >= 3 then scored[#scored + 1] = { skill = s, score = score } end
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.skill.name < b.skill.name
  end)
  local out = {}
  for i = 1, math.min(limit or 2, #scored) do
    out[#out + 1] = scored[i].skill
    session.hinted[scored[i].skill.name] = true
  end
  return out
end

---Create or overwrite a skill.
function S.save_skill(name, description, body)
  name = tostring(name or ""):gsub("[^%w._-]", "-")
  -- Reject empty and dot-only names ("."/".."): "%w._-" keeps dots, so ".." would
  -- resolve to `.advantage/skills/../SKILL.md` (outside the skills dir).
  if name == "" or name:match("^%.+$") then return false, "invalid skill name" end
  description = vim.trim(tostring(description or ""):gsub("%s+", " "))
  if #description > 500 then description = require("advantage.util").utf8_safe_sub(description, 500) end
  body = vim.trim(tostring(body or ""))
  local cap = skill_body_cap()
  if #body > cap then
    return false, ("skill body exceeds the %d-byte safety limit; split it into focused skills"):format(cap)
  end
  local text = ("---\nname: %s\ndescription: %s\n---\n\n%s\n"):format(name, description, body)
  local root = deps.skills_dir()
  local path = root and deps.mem.contain(root .. "/" .. name .. "/SKILL.md") or nil
  if not path then return false, "skill path escapes the project root" end
  local ok, err = deps.write_file(path, text)
  _skills_cache.sig = nil -- new/updated skill: force a re-scan next time
  return ok, ok and nil or (err or "write failed")
end

return S
