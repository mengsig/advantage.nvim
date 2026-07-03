---@brief Per-repo learned context + reusable skills — a token-lean, self-learning
---harness that lets the agent get better at a repo over time.
---
---Design (all deterministic and offline — no embeddings, no validator model):
---  * Two-tier progressive disclosure. The compact fact list and a one-line skill
---    INDEX are injected into the system prompt every turn; full skill BODIES are
---    pulled only on demand via the `use_skill` tool. The index costs ~1 line per
---    skill; the (potentially long) runbook stays out of context until needed.
---  * The injected block rides Anthropic's cached system prefix, so after the first
---    turn it is billed at ~10%. Net it SAVES tokens: front-loaded, high-signal repo
---    knowledge means the model stops re-deriving the same facts with read/grep loops.
---  * Storage is a human-readable Markdown file the user can read, edit and commit.
---
---Files live at the repo root (git root when there is one):
---  .advantage/context.md          learned facts, one bullet each, under fixed sections
---  .advantage/skills/<name>/SKILL.md   a named reusable procedure (frontmatter + body)
---Project memory (AGENTS.md / CLAUDE.md) is also ingested for parity with the real CLIs.
local config = require("advantage.config")

local M = {}

local uv = vim.uv or vim.loop

-- Canonical sections, in render order. `remember` routes a fact to one of these;
-- an unknown section is coerced to "Notes" so the file never sprawls.
local SECTIONS = { "Conventions", "Architecture", "Commands", "Gotchas", "Preferences", "Notes" }
local SECTION_SET = {}
for _, s in ipairs(SECTIONS) do
  SECTION_SET[s] = true
end

local PREAMBLE = {
  "<!-- Managed by advantage.nvim. Durable, repo-specific facts the agent learns as",
  "     it works, plus anything you tell it to remember. One fact per bullet; keep it",
  "     concise. Safe to edit or commit. -->",
}

--------------------------------------------------------------------------------
-- Locations
--------------------------------------------------------------------------------

---Walk up from cwd to the nearest `.git` so memory is stable no matter which
---sub-directory Neovim was opened in; fall back to cwd.
local _root_cache = {}
function M.root()
  if M._root_override then return M._root_override end
  local cwd = uv.cwd()
  if _root_cache[cwd] ~= nil then return _root_cache[cwd] end
  local found = vim.fs.find(".git", { path = cwd, upward = true })[1]
  local root = found and vim.fs.dirname(found) or cwd
  _root_cache[cwd] = root
  return root
end

local function mem_dir()
  return M.root() .. "/.advantage"
end
local function context_file()
  return mem_dir() .. "/context.md"
end
local function skills_dir()
  return mem_dir() .. "/skills"
end

local function opts()
  return (config.options and config.options.memory) or {}
end

function M.enabled()
  return opts().enabled ~= false
end

--------------------------------------------------------------------------------
-- Small IO + text helpers
--------------------------------------------------------------------------------

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- Atomic write: temp file + rename so a crash or a racing writer can't leave
  -- a half-written context.md behind.
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(content)
  f:close()
  if not os.rename(tmp, path) then
    os.remove(tmp)
    return false
  end
  return true
end

---Rough token estimate, consistent with compact.lua (chars / 4).
local function tokens(s)
  return math.ceil(#(s or "") / 4)
end

---Seed `<root>/.advantage/context.md` the first time this repo is used, so the
---memory file is visible, editable and committable from session one instead of
---appearing only after the model's first `remember` call. Idempotent — never
---touches an existing file. Called from agent creation.
function M.bootstrap()
  if not M.enabled() then return false end
  if uv.fs_stat(context_file()) then return false end
  local skeleton = table.concat({
    "# Repo memory",
    PREAMBLE[1],
    PREAMBLE[2],
    PREAMBLE[3],
    "",
    "_Nothing recorded yet — run `/context init` to have the agent learn this repo now,_",
    "_or facts land here via the `remember` tool organically as the agent works._",
    "",
  }, "\n")
  return write_file(context_file(), skeleton) == true
end

---Normalize a fact to a bag of significant words for deterministic dedup.
-- Only 3+ char words survive the length guard below, so short words need no
-- entry here; reserved words are quoted because bare `and`/`for` keys won't parse.
local STOP = {
  ["the"] = true,
  ["are"] = true,
  ["and"] = true,
  ["for"] = true,
  ["this"] = true,
  ["that"] = true,
  ["with"] = true,
  ["when"] = true,
  ["from"] = true,
  ["into"] = true,
  ["use"] = true,
  ["uses"] = true,
}
local function word_set(s)
  local set, n = {}, 0
  for w in tostring(s or ""):lower():gmatch("[%w_]+") do
    if #w > 2 and not STOP[w] then
      if not set[w] then n = n + 1 end
      set[w] = true
    end
  end
  return set, n
end

---Jaccard overlap of two normalized word sets (0..1).
local function similarity(a, na, b, nb)
  if na == 0 or nb == 0 then return 0 end
  local inter = 0
  for w in pairs(a) do
    if b[w] then inter = inter + 1 end
  end
  return inter / (na + nb - inter)
end

--------------------------------------------------------------------------------
-- context.md parse / render
--------------------------------------------------------------------------------

---Parse context.md into an ordered {section -> {bullet, ...}} structure.
local function parse_context()
  local data = read_file(context_file())
  local order, bullets = {}, {}
  for _, s in ipairs(SECTIONS) do
    order[#order + 1] = s
    bullets[s] = {}
  end
  if not data then return bullets, order end
  local current = nil
  for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
    local header = line:match("^##%s+(.+)%s*$")
    if header then
      header = vim.trim(header)
      if not bullets[header] then
        bullets[header] = {}
        order[#order + 1] = header
      end
      current = header
    else
      local bullet = line:match("^%-%s+(.+)$")
      if bullet and current then bullets[current][#bullets[current] + 1] = vim.trim(bullet) end
    end
  end
  return bullets, order
end

local function render_context(bullets, order)
  local out = { "# Repo memory", unpack(PREAMBLE) }
  out[#out + 1] = ""
  for _, section in ipairs(order) do
    local items = bullets[section]
    if items and #items > 0 then
      out[#out + 1] = "## " .. section
      for _, b in ipairs(items) do
        out[#out + 1] = "- " .. b
      end
      out[#out + 1] = ""
    end
  end
  return (table.concat(out, "\n"):gsub("%s+$", "")) .. "\n"
end

local function save_context(bullets, order)
  return write_file(context_file(), render_context(bullets, order))
end

--------------------------------------------------------------------------------
-- Budget: keep the learned block from ever bloating context
--------------------------------------------------------------------------------

local function budget_chars()
  return math.max(400, (opts().budget_tokens or 1200) * 4)
end

local function total_chars(bullets)
  local n = 0
  for _, items in pairs(bullets) do
    for _, b in ipairs(items) do
      n = n + #b + 3
    end
  end
  return n
end

---Drop oldest bullets (top of the largest section) until under the char budget.
---Returns the evicted texts so the agent can rescue anything still valuable —
---silent eviction would destroy knowledge without anyone noticing.
local function enforce_budget(bullets, order)
  local budget, evicted = budget_chars(), {}
  while total_chars(bullets) > budget do
    local biggest, count = nil, 0
    for _, s in ipairs(order) do
      if #bullets[s] > count then
        biggest, count = s, #bullets[s]
      end
    end
    if not biggest or count == 0 then break end
    evicted[#evicted + 1] = table.remove(bullets[biggest], 1)
  end
  return evicted
end

---Facts that are really procedures belong in skills (index-only cost), not in
---the always-loaded memory. Detect numbered runbooks and oversized bullets.
local function looks_procedural(fact)
  local steps = 0
  for _ in fact:gmatch("%f[%d]%d+%.%s") do
    steps = steps + 1
  end
  return steps >= 3 or #fact > 350
end

--------------------------------------------------------------------------------
-- Public: remember / forget
--------------------------------------------------------------------------------

---Record a durable fact. Deterministic dedup: a fact that overlaps an existing
---bullet by >= `dedupe_threshold` is treated as already known (the longer phrasing
---wins). Returns status: "added" | "duplicate" | "updated".
---@param fact string
---@param section? string one of SECTIONS (defaults to "Notes")
---@return { status: string, evicted?: integer, section: string }
function M.remember(fact, section)
  fact = vim.trim(tostring(fact or ""):gsub("%s+", " "))
  if fact == "" then return { status = "empty", section = "Notes" } end
  fact = fact:gsub("^%-%s*", "")
  section = (section and SECTION_SET[section]) and section or "Notes"

  -- steer runbooks to skills at the source: a procedure as a memory bullet
  -- costs its full length every turn; as a skill it costs one index line
  if looks_procedural(fact) then return { status = "procedural", section = section } end

  local bullets, order = parse_context()
  local threshold = opts().dedupe_threshold or 0.8
  local fa, fn = word_set(fact)

  for _, items in pairs(bullets) do
    for idx, existing in ipairs(items) do
      local ea, en = word_set(existing)
      if similarity(fa, fn, ea, en) >= threshold then
        -- keep the more informative phrasing; don't grow the file for a near-dup
        if #fact > #existing then
          items[idx] = fact
          save_context(bullets, order)
          return { status = "updated", section = section }
        end
        return { status = "duplicate", section = section }
      end
    end
  end

  bullets[section][#bullets[section] + 1] = fact
  local evicted = enforce_budget(bullets, order)
  save_context(bullets, order)
  return {
    status = "added",
    section = section,
    evicted = evicted,
    -- budget pressure, so the model knows when curation is due
    utilization = math.min(1, total_chars(bullets) / budget_chars()),
  }
end

---Remove every bullet whose text matches `pattern` (plain, case-insensitive
---substring). Returns the count removed. Used by `/context forget` for curation.
function M.forget(pattern)
  pattern = tostring(pattern or ""):lower()
  if pattern == "" then return 0 end
  local bullets, order = parse_context()
  local removed = 0
  for _, items in pairs(bullets) do
    for i = #items, 1, -1 do
      if items[i]:lower():find(pattern, 1, true) then
        table.remove(items, i)
        removed = removed + 1
      end
    end
  end
  if removed > 0 then save_context(bullets, order) end
  return removed
end

--------------------------------------------------------------------------------
-- Skills: index always known, body loaded on demand
--------------------------------------------------------------------------------

---Parse `---` frontmatter (key: value) + body from a SKILL.md.
local function parse_skill(text)
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

---Scan skill directories (.advantage/skills and, for interop, .claude/skills).
---Returns { {name=, description=, path=} } sorted by name, de-duplicated by name.
local function scan_skills()
  local roots = { skills_dir(), M.root() .. "/.claude/skills" }
  local seen, out = {}, {}
  for _, root in ipairs(roots) do
    local dir = uv.fs_scandir(root)
    if dir then
      while true do
        local entry = uv.fs_scandir_next(dir)
        if not entry then break end
        local skill_path = root .. "/" .. entry .. "/SKILL.md"
        local text = read_file(skill_path)
        if text and not seen[entry] then
          local name, desc = parse_skill(text)
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
  return out
end

function M.skills_index()
  return scan_skills()
end

---Session-lifetime counters for instrumentation and hint throttling. Reset per
---conversation (agent.new) so a fresh chat can re-surface skills and the /usage
---savings math starts clean.
M._session = { skill_loads = 0, skill_load_tokens = 0, loaded = {}, hinted = {} }

function M.reset_session()
  M._session = { skill_loads = 0, skill_load_tokens = 0, loaded = {}, hinted = {} }
end

---Return the full body of a skill by name, or nil.
function M.use_skill(name)
  name = vim.trim(tostring(name or ""))
  for _, s in ipairs(scan_skills()) do
    if s.name == name then
      local _, _, body = parse_skill(read_file(s.path) or "")
      if body then
        M._session.loaded[name] = true
        M._session.skill_loads = M._session.skill_loads + 1
        M._session.skill_load_tokens = M._session.skill_load_tokens + tokens(body)
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
function M.skill_hints(text, limit)
  if not M.enabled() then return {} end
  local pw, pn = word_set(text)
  if pn == 0 then return {} end
  local scored = {}
  for _, s in ipairs(scan_skills()) do
    if not M._session.loaded[s.name] and not M._session.hinted[s.name] then
      local score = 0
      local nw = word_set((s.name or ""):gsub("[-_]", " "))
      for w in pairs(nw) do
        if pw[w] then score = score + 3 end
      end
      local dw = word_set(s.description)
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
    M._session.hinted[scored[i].skill.name] = true
  end
  return out
end

---The `/context init` prompt — parity with `claude /init`: the agent explores
---the repo and populates memory in one pass, so session one already starts with
---an analyzed repo map instead of waiting for organic discovery.
function M.init_prompt()
  return table.concat({
    "Initialize this repo's persistent memory. Explore the codebase the way an expert onboards:",
    "read the README and docs, then whatever build/package manifests THIS language ecosystem uses",
    "(package.json, Makefile, CMakeLists.txt, Cargo.toml, pyproject.toml/setup.py, go.mod,",
    "pom.xml/build.gradle, Gemfile, mix.exs, *.cabal, *.rockspec, Dockerfile — or anything else),",
    "the directory layout, entry points, test setup, CI config, and any existing agent docs",
    "(AGENTS.md, CLAUDE.md, .cursorrules, .github/copilot-instructions.md).",
    "Use sub_agent fan-out for large codebases.",
    "",
    "Then record what future sessions need, one `remember` call per fact:",
    "- Commands: the exact build / test / lint / run commands — verify each against the manifests, do not guess",
    "- Architecture: the 3-6 load-bearing facts about how the code is organized (modules, data flow, key invariants)",
    "- Conventions: code style, naming, error handling, and patterns evident in the code",
    "- Gotchas: sharp edges that would trip an agent (non-obvious ordering, footguns, deceptive names)",
    "",
    "Rules: 8-15 facts total, one crisp self-contained sentence each. Only durable, non-obvious facts —",
    "skip anything a quick file read re-derives, and never record a guess. If the test, build or release",
    "flow takes 3+ steps, codify it with save_skill instead of cramming it into facts.",
    "Finish with a short summary of what you recorded.",
  }, "\n")
end

---The `/context curate` prompt — the compression pass: the agent rewrites its
---own memory tighter and extracts procedural content into skills, so the
---always-loaded block shrinks while nothing valuable is lost.
function M.curate_prompt()
  return table.concat({
    "Curate this repo's memory. The current memory is injected in your context under '# Repo memory';",
    "the file on disk is .advantage/context.md.",
    "",
    "Do a compression pass:",
    "1. Merge overlapping or redundant bullets into single tighter facts; drop anything stale,",
    "   session-local, or re-derivable from a quick file read. Verify a fact against the code",
    "   before dropping it as stale.",
    "2. Extract any bullet that is really a multi-step procedure into a skill (save_skill) —",
    "   a procedure costs its full length in every request as a bullet, but only one index line",
    "   as a skill. Leave at most a one-line pointer behind if needed.",
    "3. Rewrite .advantage/context.md directly (edit_file/write_file) keeping the exact format:",
    "   '# Repo memory' header, the managed comment, '## Section' headers",
    "   (Conventions/Architecture/Commands/Gotchas/Preferences/Notes), one '- fact' per line.",
    ("4. Keep the whole file under ~%d tokens. Quality over quantity: a handful of sharp facts"):format(
      opts().budget_tokens or 1200
    ),
    "   beats a wall of notes.",
    "",
    "Finish with a one-line before/after summary (facts and estimated tokens).",
  }, "\n")
end

---Instrumentation for the /usage dashboard: what the harness injects per turn,
---and what staying index-only (bodies on demand) avoids versus inlining every
---skill body into every request.
function M.stats()
  local skills = scan_skills()
  local bodies_tokens = 0
  for _, s in ipairs(skills) do
    local _, _, body = parse_skill(read_file(s.path) or "")
    bodies_tokens = bodies_tokens + tokens(body or "")
  end
  return {
    block_tokens = tokens(M.render()),
    skills = #skills,
    bodies_tokens = bodies_tokens,
    loads = M._session.skill_loads,
    loaded_tokens = M._session.skill_load_tokens,
  }
end

---Create or overwrite a skill.
function M.save_skill(name, description, body)
  name = tostring(name or ""):gsub("[^%w._-]", "-")
  if name == "" then return false, "invalid skill name" end
  local text = ("---\nname: %s\ndescription: %s\n---\n\n%s\n"):format(
    name,
    tostring(description or ""),
    vim.trim(tostring(body or ""))
  )
  local ok = write_file(skills_dir() .. "/" .. name .. "/SKILL.md", text)
  return ok, ok and nil or "write failed"
end

--------------------------------------------------------------------------------
-- Project memory ingestion (parity: real CLIs read AGENTS.md / CLAUDE.md)
--------------------------------------------------------------------------------

---Read the project's committed memory file, resolving one level of `@file`
---imports (Claude Code style, e.g. CLAUDE.md that just holds `@AGENTS.md`).
local function project_memory()
  local root = M.root()
  local pick
  for _, name in ipairs({ "AGENTS.md", "CLAUDE.md" }) do
    if read_file(root .. "/" .. name) then
      pick = name
      break
    end
  end
  if not pick then return nil end
  local text = read_file(root .. "/" .. pick) or ""
  text = text:gsub("@([%w._/-]+)", function(rel)
    -- Only resolve imports that stay inside the repo: reject absolute paths,
    -- `..` escapes, and in-repo symlinks pointing outside so a committed
    -- AGENTS.md/CLAUDE.md can't exfiltrate files. Same containment as file tools.
    local abs = require("advantage.util").contain(rel, root, false)
    return (abs and read_file(abs)) or ("@" .. rel)
  end)
  text = text:gsub("<!%-%-.-%-%->", "") -- strip HTML-comment noise (e.g. tool markers)
  local cap = (opts().project_budget_tokens or 2000) * 4
  if #text > cap then text = text:sub(1, cap) .. "\n… [project memory truncated]" end
  return vim.trim(text)
end

--------------------------------------------------------------------------------
-- verify: flag facts whose file/path anchors no longer exist (honesty pass)
--------------------------------------------------------------------------------

---Return a list of {section, bullet, missing} for bullets that name a project
---path which is no longer readable — cheap staleness detection, no model call.
function M.verify()
  local root = M.root()
  local bullets, order = parse_context()
  local stale = {}
  for _, section in ipairs(order) do
    for _, b in ipairs(bullets[section]) do
      -- consider tokens that look like project paths (contain a slash or a dot-ext)
      for cand in b:gmatch("[%w._/-]+/[%w._/-]+") do
        local path = cand:gsub("[.,:;)]+$", "")
        if not path:match("^https?://") and not uv.fs_stat(root .. "/" .. path) and not uv.fs_stat(path) then
          stale[#stale + 1] = { section = section, bullet = b, missing = path }
          break
        end
      end
    end
  end
  return stale
end

--------------------------------------------------------------------------------
-- Render: the block injected into the system prompt every turn
--------------------------------------------------------------------------------

---Build the memory block for the system prompt. Kept within the token budget and
---returns "" when there is nothing to add, so the cached prefix is untouched.
function M.render()
  if not M.enabled() then return "" end
  local parts = {}

  local proj = project_memory()
  if proj and proj ~= "" then parts[#parts + 1] = "# Project memory (AGENTS.md/CLAUDE.md)\n" .. proj end

  local bullets, order = parse_context()
  local has_facts = false
  for _, items in pairs(bullets) do
    if #items > 0 then has_facts = true end
  end
  if has_facts then
    parts[#parts + 1] = vim.trim(render_context(bullets, order))
  else
    -- cold start: tell the model the memory exists and is empty, so the
    -- flywheel starts on session one instead of never
    parts[#parts + 1] =
      "# Repo memory\nEmpty so far — this repo hasn't been learned yet. As you discover durable, non-obvious facts (build/test commands, architecture invariants, conventions, gotchas, stated preferences), record them with the `remember` tool so future sessions start ahead."
  end

  local skills = scan_skills()
  if #skills > 0 then
    local lines = {
      "# Skills — reusable procedures for this repo.",
      "Call the `use_skill` tool with the name to load a skill's full steps before doing that task.",
    }
    for _, s in ipairs(skills) do
      -- keep the index lean: one line, description capped so a verbose skill
      -- can't bloat the always-loaded tier (the body loads on demand anyway).
      local d = s.description or ""
      if #d > 200 then d = d:sub(1, 197) .. "…" end
      lines[#lines + 1] = ("- %s: %s"):format(s.name, d)
    end
    parts[#parts + 1] = table.concat(lines, "\n")
  end

  if #parts == 0 then return "" end
  return table.concat(parts, "\n\n")
end

M._SECTIONS = SECTIONS
M._word_set = word_set
M._similarity = similarity

return M
