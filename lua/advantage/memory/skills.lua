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
---@field read_file fun(path: string): string|nil
---@field write_file fun(path: string, content: string): boolean
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
  local name, desc, body_start = nil, nil, 1
  local lines = vim.split(text, "\n", { plain = true })
  if lines[1] == "---" then
    local i = 2
    while i <= #lines and lines[i] ~= "---" do
      local k, v = lines[i]:match("^(%w+):%s*(.*)$")
      if k == "name" then
        name = vim.trim(v)
      elseif k == "description" then
        desc = vim.trim(v)
      end
      i = i + 1
    end
    body_start = i + 1
  end
  local body = table.concat(vim.list_slice(lines, body_start), "\n")
  return name, desc, vim.trim(body)
end

-- Cache parsed skills across turns. `render()`/`skill_hints()`/`stats()` all scan
-- on every system-prompt build; without this each turn re-reads and frontmatter-
-- parses every SKILL.md. Keyed by a cheap stat signature (paths + mtime + size)
-- so an add/remove/content-edit invalidates it; save_skill clears it explicitly.
local _skills_cache = { sig = nil, value = nil }

local function skill_roots()
  return { deps.skills_dir(), deps.mem.root() .. "/.claude/skills" }
end

local function skills_signature()
  local parts = {}
  for _, root in ipairs(skill_roots()) do
    local dir = uv.fs_scandir(root)
    if dir then
      while true do
        local entry = uv.fs_scandir_next(dir)
        if not entry then break end
        local p = root .. "/" .. entry .. "/SKILL.md"
        local st = uv.fs_stat(p)
        if st then parts[#parts + 1] = ("%s:%d:%d"):format(p, st.mtime and st.mtime.sec or 0, st.size or 0) end
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

---Scan skill directories (.advantage/skills and, for interop, .claude/skills).
---Returns { {name=, description=, path=} } sorted by name, de-duplicated by name.
---@return {name:string, description:string, path:string}[]
function S.scan_skills()
  local sig = skills_signature()
  if _skills_cache.sig == sig and _skills_cache.value then return _skills_cache.value end
  local roots = skill_roots()
  local seen, out = {}, {}
  for _, root in ipairs(roots) do
    local dir = uv.fs_scandir(root)
    if dir then
      while true do
        local entry = uv.fs_scandir_next(dir)
        if not entry then break end
        local skill_path = root .. "/" .. entry .. "/SKILL.md"
        local text = deps.read_file(skill_path)
        if text and not seen[entry] then
          local name, desc = S.parse_skill(text)
          name = name or entry
          if not seen[name] then
            seen[name] = true
            out[#out + 1] = { name = name, description = desc or "", path = skill_path }
          end
        end
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
      local _, _, body = S.parse_skill(deps.read_file(s.path) or "")
      if body then
        session.loaded[name] = true
        session.skill_loads = session.skill_loads + 1
        session.skill_load_tokens = session.skill_load_tokens + deps.tokens(body)
      end
      return body, s.description
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
    if not session.loaded[s.name] and not session.hinted[s.name] then
      local score = 0
      local nw = deps.word_set((s.name or ""):gsub("[-_]", " "))
      for w in pairs(nw) do
        if pw[w] then score = score + 3 end
      end
      local dw = deps.word_set(s.description)
      for w in pairs(dw) do
        if pw[w] then score = score + 1 end
      end
      if score >= 3 then scored[#scored + 1] = { skill = s, score = score } end
    end
  end
  table.sort(scored, function(a, b)
    return a.score > b.score
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
  local text = ("---\nname: %s\ndescription: %s\n---\n\n%s\n"):format(
    name,
    tostring(description or ""),
    vim.trim(tostring(body or ""))
  )
  local ok = deps.write_file(deps.skills_dir() .. "/" .. name .. "/SKILL.md", text)
  _skills_cache.sig = nil -- new/updated skill: force a re-scan next time
  return ok, ok and nil or "write failed"
end

return S
