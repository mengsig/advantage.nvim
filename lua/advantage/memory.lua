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
---  .advantage/<name>.md           user-authored config doc, injected verbatim (see M.config_docs)
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
  local cwd = uv.cwd() or ""
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

---Character-safe byte truncation (shared helper). This block is spliced into the
---system prompt, so a mid-character cut would make the request body invalid
---UTF-8; util.utf8_safe_sub backs off to a character boundary.
local utf8_safe_sub = require("advantage.util").utf8_safe_sub

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
  return math.max(400, (opts().budget_tokens or 2000) * 4)
end

-- A bullet longer than this carries more depth than the always-loaded tier
-- should pay for on every turn: its detail belongs in an on-demand skill, with
-- a crisp one-line pointer left behind. Flagged (not blocked) by curation_advice.
local VERBOSE_BULLET_CHARS = 240

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
---A genuine runbook numbers its steps consecutively (1., 2., 3., ...); a
---data/conversion fact can easily contain 3+ unrelated "<number>. " matches
---(e.g. "Earth 6371. Moon 1737. Sun 696.") without being a procedure at all —
---require 3 CONSECUTIVE ascending integers, in order, to tell the two apart.
local function looks_procedural(fact)
  if #fact > 350 then return true end
  local nums = {}
  for n in fact:gmatch("%f[%d](%d+)%.%s") do
    nums[#nums + 1] = tonumber(n)
  end
  for i = 1, #nums - 2 do
    if nums[i + 1] == nums[i] + 1 and nums[i + 2] == nums[i] + 2 then return true end
  end
  return false
end

--------------------------------------------------------------------------------
-- Public: remember / forget
--------------------------------------------------------------------------------

---Record a durable fact. Deterministic dedup: a fact that overlaps an existing
---bullet by >= `dedupe_threshold` is treated as already known (the longer phrasing
---wins). Returns status: "added" | "duplicate" | "updated".
---@param fact string
---@param section? string one of SECTIONS (defaults to "Notes")
---@return { status: string, evicted?: string[], section: string, verbose_count?: integer }
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
          local advice = M.curation_advice()
          return {
            status = "updated",
            section = section,
            utilization = advice.utilization,
            verbose_count = advice.verbose_count,
            procedural_count = advice.procedural_count,
            redundant_pairs = advice.redundant_pairs,
          }
        end
        return { status = "duplicate", section = section }
      end
    end
  end

  bullets[section][#bullets[section] + 1] = fact
  local evicted = enforce_budget(bullets, order)
  save_context(bullets, order)
  M._session.remember_count = (M._session.remember_count or 0) + 1
  local advice = M.curation_advice()
  return {
    status = "added",
    section = section,
    evicted = evicted,
    -- budget pressure + the deterministic curation signals (real depth to push
    -- into skills, redundant pairs to merge), so the model curates the things
    -- that actually cost accuracy or tokens — not merely long-but-precise facts
    utilization = advice.utilization,
    verbose_count = advice.verbose_count,
    procedural_count = advice.procedural_count,
    redundant_pairs = advice.redundant_pairs,
  }
end

---Deterministic curation signal (no model call). The load-bearing signals are
---the ones that actually cost accuracy or tokens: budget pressure, genuine
---procedural depth that belongs in an on-demand skill, and redundant bullets that
---likely say the same thing twice (paying twice, or worse, contradicting). Raw
---per-bullet length is reported (`verbose`) for the UI but is deliberately NOT a
---curation trigger — behind prompt-caching a long, precise fact is cheap and
---shortening it only sheds the specificity that makes the memory useful. Pure.
---@return { utilization: number, over_budget: boolean, used_tokens: integer, budget_tokens: integer, verbose: table[], verbose_count: integer, procedural: table[], procedural_count: integer, redundant_pairs: integer }
function M.curation_advice()
  local bullets, order = parse_context()
  local verbose, procedural, flat = {}, {}, {}
  for _, section in ipairs(order) do
    for _, b in ipairs(bullets[section] or {}) do
      flat[#flat + 1] = b
      if #b >= VERBOSE_BULLET_CHARS then verbose[#verbose + 1] = { section = section, len = #b, text = b } end
      -- genuine depth (a numbered runbook or a very long multi-clause fact)
      -- belongs in a skill; this — not length — is what we steer on
      if looks_procedural(b) then procedural[#procedural + 1] = { section = section, len = #b, text = b } end
    end
  end
  -- Redundancy: pairs that overlap enough to probably duplicate each other but
  -- fell just below the auto-dedupe cut. This is the real "curate me" signal —
  -- duplication wastes tokens and risks self-contradiction, both of which hurt.
  local threshold = opts().dedupe_threshold or 0.8
  local sets = {}
  for i, b in ipairs(flat) do
    local w, n = word_set(b)
    sets[i] = { w = w, n = n }
  end
  local redundant = 0
  for i = 1, #flat do
    for j = i + 1, #flat do
      local s = similarity(sets[i].w, sets[i].n, sets[j].w, sets[j].n)
      if s >= threshold * 0.7 and s < threshold then redundant = redundant + 1 end
    end
  end
  local used, budget = total_chars(bullets), budget_chars()
  return {
    utilization = math.min(1, used / budget),
    over_budget = used > budget,
    used_tokens = math.ceil(used / 4),
    budget_tokens = math.ceil(budget / 4),
    verbose = verbose,
    verbose_count = #verbose,
    procedural = procedural,
    procedural_count = #procedural,
    redundant_pairs = redundant,
  }
end

---Fire the once-per-session persistent curation nudge at most once. Returns true
---the first time it is called in a session, false thereafter.
function M.curation_nudge_due()
  if M._session.curation_nudged then return false end
  M._session.curation_nudged = true
  return true
end

-- The frozen system-prompt guidance to `remember` decays as a session grows
-- (it sits atop context while attention drifts to the recent transcript), so we
-- re-surface it in-band every this-many substantial work actions (edits, shell
-- runs) that pass WITHOUT a new fact being recorded. Recording anything resets
-- the window, so an actively-curating session never sees a nudge.
local RECORD_NUDGE_EVERY = 8

---Count one substantial work action (an edit or a shell run) toward the
---record-nudge window. Cheap; call from the tools that signal real work.
function M.note_work()
  M._session.work_actions = (M._session.work_actions or 0) + 1
end

---Recurring in-band steer, appended to a tool result (never the cached prefix,
---so it costs nothing per turn), that re-surfaces the `remember` habit as the
---session grows and the frozen system-prompt instruction loses salience. Fires
---when RECORD_NUDGE_EVERY work actions have passed since the last record or
---nudge; a `remember` call resets the window and buys quiet. Returns "" when not
---due. Deterministic — no model call, no user-facing notice.
function M.record_nudge_suffix()
  local s = M._session
  -- the model recorded since we last looked → reset the window, stay quiet
  if (s.remember_count or 0) > (s.record_seen or 0) then
    s.record_seen = s.remember_count
    s.work_at_last_nudge = s.work_actions or 0
    return ""
  end
  local since = (s.work_actions or 0) - (s.work_at_last_nudge or 0)
  if since < RECORD_NUDGE_EVERY then return "" end
  s.work_at_last_nudge = s.work_actions or 0
  return "\n\nMemory check: has this session surfaced a durable, non-obvious fact future sessions would need — a convention, a gotcha, a build/test command, an architecture invariant, a stated preference? If so, `remember` it now. If not — which is the common case — record nothing; padding memory with trivia is worse than an occasional miss."
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

-- Cache parsed skills across turns. `render()`/`skill_hints()`/`stats()` all scan
-- on every system-prompt build; without this each turn re-reads and frontmatter-
-- parses every SKILL.md. Keyed by a cheap stat signature (paths + mtime + size)
-- so an add/remove/content-edit invalidates it; save_skill clears it explicitly.
local _skills_cache = { sig = nil, value = nil }

local function skill_roots()
  return { skills_dir(), M.root() .. "/.claude/skills" }
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
local function scan_skills()
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
  _skills_cache.sig, _skills_cache.value = sig, out
  return out
end

function M.skills_index()
  return scan_skills()
end

---Session-lifetime counters for instrumentation and hint throttling. Reset per
---conversation (agent.new) so a fresh chat can re-surface skills and the /usage
---savings math starts clean.
local function fresh_session()
  return {
    skill_loads = 0,
    skill_load_tokens = 0,
    loaded = {},
    hinted = {},
    curation_nudged = false,
    remember_count = 0,
    work_actions = 0,
    record_seen = 0,
    work_at_last_nudge = 0,
  }
end

M._session = fresh_session()

function M.reset_session()
  M._session = fresh_session()
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
    "skip anything a quick file read re-derives, and never record a guess. Facts are the always-loaded",
    "tier, so keep them crisp; anything with real depth (a 3+ step build/test/release flow, or a",
    "subsystem worth a deep-dive) goes in a skill via save_skill with a retrieval-rich description,",
    "not crammed into a fact. Finish with a short summary of what you recorded.",
  }, "\n")
end

---The `/context curate` prompt — the compression pass: the agent rewrites its
---own memory tighter and extracts procedural content into skills, so the
---always-loaded block shrinks while nothing valuable is lost.
function M.curate_prompt()
  return table.concat({
    "Curate this repo's memory for maximum signal per token. The current memory is injected in your",
    "context under '# Repo memory'; the file on disk is .advantage/context.md.",
    "",
    "Cost model — internalize this: context.md rides Anthropic's cached system prefix, so after the",
    "first turn it is billed at ~10%. A long, PRECISE fact is therefore cheap; its specificity (exact",
    "names, paths, invariants) is what lets a future agent act instead of guess. So DO NOT shorten a",
    "load-bearing fact to hit a length target — that trades real capability for a token saving caching",
    "already erased. Optimize for correctness and non-redundancy, not brevity.",
    "",
    "What actually costs you: (a) REDUNDANCY — two bullets saying the same thing wastes tokens and,",
    "worse, can contradict and mislead; (b) STALENESS — a fact the code no longer supports; (c) DEPTH",
    "in the wrong tier — a multi-step runbook or subsystem deep-dive belongs in a SKILL (one index line",
    "until loaded on demand), not inline. Attack those three; leave crisp, accurate single facts alone.",
    "",
    "Do the pass:",
    "1. Merge bullets that overlap into one tighter, still-specific fact. Drop anything stale or",
    "   re-derivable from a quick file read — but verify a fact against the code before deleting it.",
    "2. Move any bullet that is genuinely procedural (a 3+ step flow) or a real subsystem deep-dive into",
    "   a skill (save_skill) with a description RICH in the terms someone would search for, then leave",
    "   behind at most a crisp one-line pointer. Do not extract an atomic fact just because it is long.",
    "3. Rewrite .advantage/context.md directly (edit_file/write_file) keeping the exact format:",
    "   '# Repo memory' header, the managed comment, '## Section' headers",
    "   (Conventions/Architecture/Commands/Gotchas/Preferences/Notes), one '- fact' per line.",
    ("4. Stay under ~%d tokens if you can, but never sacrifice a load-bearing detail to get there —"):format(
      opts().budget_tokens or 2000
    ),
    "   prefer merging duplicates and extracting depth into skills over truncating precise facts.",
    "",
    "Finish with a one-line before/after summary (facts merged/dropped, skills created, est. tokens).",
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
  -- Reject empty and dot-only names ("."/".."): "%w._-" keeps dots, so ".." would
  -- resolve to `.advantage/skills/../SKILL.md` (outside the skills dir).
  if name == "" or name:match("^%.+$") then return false, "invalid skill name" end
  local text = ("---\nname: %s\ndescription: %s\n---\n\n%s\n"):format(
    name,
    tostring(description or ""),
    vim.trim(tostring(body or ""))
  )
  local ok = write_file(skills_dir() .. "/" .. name .. "/SKILL.md", text)
  _skills_cache.sig = nil -- new/updated skill: force a re-scan next time
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
  if #text > cap then text = utf8_safe_sub(text, cap) .. "\n… [project memory truncated]" end
  return vim.trim(text)
end

---Arbitrary user-authored config docs: every `.advantage/<name>.md` (except the
---memory file `context.md`) is injected verbatim into the system prompt, so a
---repo can make the agent's standing instructions configurable by dropping a
---markdown file in place — no code change. Returned name-sorted so the frozen
---prefix stays prompt-cache-stable. Each doc is budget-capped like project memory.
---@return {name: string, text: string}[]
function M.config_docs()
  local dir = mem_dir()
  local fs = uv.fs_scandir(dir)
  if not fs then return {} end
  local names = {}
  while true do
    local name, typ = uv.fs_scandir_next(fs)
    if not name then break end
    -- skills/ is a subdir; context.md is memory; *.tmp are atomic-write scratch.
    if (typ == "file" or typ == nil) and name:match("%.md$") and name ~= "context.md" then names[#names + 1] = name end
  end
  table.sort(names)
  local cap = (opts().config_budget_tokens or 2000) * 4
  local docs = {}
  for _, name in ipairs(names) do
    local text = read_file(dir .. "/" .. name)
    if text then
      text = vim.trim(text:gsub("<!%-%-.-%-%->", ""))
      if #text > 0 then
        if #text > cap then text = utf8_safe_sub(text, cap) .. "\n… [config doc truncated]" end
        docs[#docs + 1] = { name = name, text = text }
      end
    end
  end
  return docs
end

--------------------------------------------------------------------------------
-- verify: flag facts whose file/path anchors no longer exist (honesty pass)
--------------------------------------------------------------------------------

---True when `path` (a repo-relative-ish file reference) resolves to a real file.
---Checks root-relative and cwd-relative first, then — because facts routinely
---cite a module-relative suffix like `tools/init.lua` (really
---`lua/advantage/tools/init.lua`) — looks for any file in the tree whose path
---ends with that suffix. Bounded so a huge tree can't wedge the command.
local function path_resolves(root, path)
  if uv.fs_stat(root .. "/" .. path) or uv.fs_stat(path) then return true end
  local base = path:match("([^/]+)$")
  if not base then return false end
  local hits = vim.fs.find(base, { path = root, type = "file", limit = 64 })
  for _, hit in ipairs(hits) do
    -- match on a path-segment boundary so `init.lua` doesn't satisfy `xinit.lua`
    if hit == path or hit:sub(-(#path + 1)) == "/" .. path then return true end
  end
  return false
end

---A candidate token only counts as a file reference if it has a directory
---separator AND its final segment carries a short file extension. This is what
---separates a real path from word/word prose like `race/clobber`,
---`remember/save_skill`, `speed-limit/speed-time` or `0.10/stable/nightly` —
---which would otherwise be flagged as missing paths (the bug this guards).
local function looks_like_path(tok)
  if not tok:find("/", 1, true) then return false end
  local last = tok:match("([^/]+)$")
  return last ~= nil and last:match("%.%w[%w]?[%w]?[%w]?[%w]?$") ~= nil
end

---Return a list of {section, bullet, missing} for bullets that name a project
---path which is no longer readable — cheap staleness detection, no model call.
---Only genuinely path-shaped, unresolvable references are reported: a false
---"stale" flag on a good fact is worse than none, so precision beats recall here.
function M.verify()
  local root = M.root()
  local bullets, order = parse_context()
  local stale = {}
  for _, section in ipairs(order) do
    for _, b in ipairs(bullets[section]) do
      for cand in b:gmatch("[%w._/-]+/[%w._/-]+") do
        local path = cand:gsub("[.,:;)]+$", "")
        if not path:match("^https?://") and looks_like_path(path) and not path_resolves(root, path) then
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

---Build the memory block as an ordered list of labeled parts. Each entry is
---`{ label = "<short name>", text = "<block bytes>" }`. `render()` joins the
---`text` fields; `/context preview` uses the `label`s to attribute per-section
---token cost. Returns `{}` when memory is disabled or there is nothing to add.
function M.render_parts()
  if not M.enabled() then return {} end
  local parts = {}

  local proj = project_memory()
  if proj and proj ~= "" then
    parts[#parts + 1] =
      { label = "project memory (AGENTS/CLAUDE.md)", text = "# Project memory (AGENTS.md/CLAUDE.md)\n" .. proj }
  end

  -- User-authored config docs (.advantage/<name>.md) — standing instructions the
  -- repo owner drops in to make the agent configurable, injected verbatim.
  for _, doc in ipairs(M.config_docs()) do
    parts[#parts + 1] = {
      label = ("config (%s)"):format(doc.name),
      text = ("# Config: %s\n%s"):format(doc.name, doc.text),
    }
  end

  local bullets, order = parse_context()
  local has_facts = false
  for _, items in pairs(bullets) do
    if #items > 0 then has_facts = true end
  end
  if has_facts then
    parts[#parts + 1] = { label = "repo memory (context.md)", text = vim.trim(render_context(bullets, order)) }
  else
    -- cold start: tell the model the memory exists and is empty, so the
    -- flywheel starts on session one instead of never
    parts[#parts + 1] = {
      label = "repo memory (context.md, empty)",
      text = "# Repo memory\nEmpty so far — this repo hasn't been learned yet. As you discover durable, non-obvious facts (build/test commands, architecture invariants, conventions, gotchas, stated preferences), record them with the `remember` tool so future sessions start ahead.",
    }
  end

  local skills = scan_skills()
  if #skills > 0 then
    local lines = {
      "# Skills — reusable procedures for this repo.",
      "Call the `use_skill` tool with the name to load a skill's full steps before doing that task.",
    }
    -- Budget the always-loaded index so a large skill library can't re-bloat the
    -- cached prefix. Truncation is deterministic (scan_skills is alphabetical), so
    -- the frozen block stays prompt-cache-stable; a dropped skill is still fully
    -- available — loadable by name with use_skill and still keyword-hinted.
    local budget = math.max(200, (opts().skills_index_budget_tokens or 1200) * 4)
    local used = #lines[1] + #lines[2] + 2
    local shown, dropped = 0, 0
    for _, s in ipairs(skills) do
      -- keep the index lean: one line, description capped so a verbose skill
      -- can't bloat the always-loaded tier (the body loads on demand anyway).
      local d = s.description or ""
      if #d > 200 then d = utf8_safe_sub(d, 197) .. "…" end
      local line = ("- %s: %s"):format(s.name, d)
      -- always keep at least one; otherwise stop once the index budget is spent
      if shown == 0 or used + #line + 1 <= budget then
        lines[#lines + 1] = line
        used = used + #line + 1
        shown = shown + 1
      else
        dropped = dropped + 1
      end
    end
    if dropped > 0 then
      lines[#lines + 1] = ("- … +%d more skill(s) — load any by name with use_skill"):format(dropped)
    end
    parts[#parts + 1] = { label = ("skills index (%d)"):format(#skills), text = table.concat(lines, "\n") }
  end

  return parts
end

---Build the memory block for the system prompt. Kept within the token budget and
---returns "" when there is nothing to add, so the cached prefix is untouched.
function M.render()
  if not M.enabled() then return "" end
  local parts = M.render_parts()
  if #parts == 0 then return "" end
  local texts = {}
  for _, p in ipairs(parts) do
    texts[#texts + 1] = p.text
  end
  return table.concat(texts, "\n\n")
end

M._SECTIONS = SECTIONS
M._word_set = word_set
M._similarity = similarity

return M
