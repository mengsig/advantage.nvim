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
local util = require("advantage.util")

local M = {}

local uv = vim.uv or vim.loop
local utf8_safe_sub = util.utf8_safe_sub

-- Repo-owned instruction files are untrusted input. Bound every read at source,
-- before parsing/import expansion, so a giant sparse file or repeated import
-- cannot block Neovim or allocate the whole file merely to truncate it later.
local MAX_REPO_FILE_BYTES = 1024 * 1024
local CONTEXT_FILE_MAX_BYTES = 1024 * 1024
local MAX_CONTEXT_BULLETS = 512

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
local _scoped_root = nil
local _scoped_cwd = nil
local function discover_root(cwd)
  cwd = cwd or uv.cwd() or ""
  -- util.project_root owns the shared bounded memo. Keeping a second cache here
  -- used to double-retain every launch directory for the lifetime of Neovim.
  return util.project_root(cwd)
end

function M.root()
  if M._root_override then return M._root_override end
  return _scoped_root or discover_root()
end

---The launch directory inside the frozen workspace. Instruction and skill
---discovery use it for nested repo scopes while file tools stay rooted at the
---canonical project boundary.
function M.cwd()
  local root = vim.fs.normalize(M.root())
  local cwd = vim.fs.normalize(_scoped_cwd or root)
  if cwd == root or cwd:sub(1, #root + 1) == root .. "/" then return cwd end
  return root
end

---Run one synchronous memory operation against an agent's frozen workspace even
---if the user executes :cd mid-session. The previous scope is restored on error.
function M.with_root(cwd, fn)
  local previous, previous_cwd = _scoped_root, _scoped_cwd
  cwd = cwd or uv.cwd() or ""
  _scoped_root = discover_root(cwd)
  _scoped_cwd = uv.fs_realpath(cwd) or vim.fs.normalize(cwd)
  local ok, a, b, c, d = pcall(fn)
  _scoped_root, _scoped_cwd = previous, previous_cwd
  if not ok then error(a, 0) end
  return a, b, c, d
end

---Resolve a memory/config/skill path without ever following a repo-controlled
---symlink outside the frozen project root.
function M.contain(path)
  return require("advantage.util").contain(path, M.root(), false)
end

local function mem_dir()
  return M.contain(".advantage")
end
local function context_file()
  return M.contain(".advantage/context.md")
end
local function skills_dir()
  return M.contain(".advantage/skills")
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

---@return string|nil data, boolean truncated
local function read_file(path, max_bytes)
  local safe = path and M.contain(path)
  if not safe then return nil, false end
  local f = io.open(safe, "r")
  if not f then return nil, false end
  local limit = math.max(1, math.min(MAX_REPO_FILE_BYTES, math.floor(tonumber(max_bytes) or MAX_REPO_FILE_BYTES)))
  local data = f:read(limit + 1) or ""
  f:close()
  local truncated = #data > limit
  if truncated then data = utf8_safe_sub(data, limit) end
  return data, truncated
end

local function write_file(path, content)
  -- Share the hardened source-file writer: exclusive randomized temp file,
  -- complete-write + fsync checks, atomic rename, and dirty-buffer protection.
  local safe, err
  if path then
    safe, err = M.contain(path)
  end
  if not safe then return nil, err end
  return require("advantage.tools.support").write_all(safe, content)
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
  local path = context_file()
  if not path or uv.fs_stat(path) then return false end
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
  return write_file(path, skeleton) == true
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
  local data, truncated = read_file(context_file(), CONTEXT_FILE_MAX_BYTES)
  local order, bullets = {}, {}
  for _, s in ipairs(SECTIONS) do
    order[#order + 1] = s
    bullets[s] = {}
  end
  if not data then return bullets, order, false end
  local current, bullet_count = nil, 0
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
      if bullet and current then
        if bullet_count >= MAX_CONTEXT_BULLETS then
          truncated = true
          break
        end
        bullets[current][#bullets[current] + 1] = vim.trim(bullet)
        bullet_count = bullet_count + 1
      end
    end
  end
  return bullets, order, truncated
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

  local bullets, order, truncated = parse_context()
  if truncated then
    return {
      status = "error",
      section = section,
      error = "context.md exceeds the 1 MiB safety limit; curate it manually before recording more",
    }
  end
  local threshold = opts().dedupe_threshold or 0.8
  local fa, fn = word_set(fact)

  for _, items in pairs(bullets) do
    for idx, existing in ipairs(items) do
      local ea, en = word_set(existing)
      if similarity(fa, fn, ea, en) >= threshold then
        -- keep the more informative phrasing; don't grow the file for a near-dup
        if #fact > #existing then
          items[idx] = fact
          local ok, err = save_context(bullets, order)
          if not ok then return { status = "error", section = section, error = err or "write failed" } end
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
  local ok, err = save_context(bullets, order)
  if not ok then return { status = "error", section = section, error = err or "write failed" } end
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
  local bullets, order, truncated = parse_context()
  if truncated then return 0, "context.md exceeds the 1 MiB safety limit; curate it manually before rewriting" end
  local removed = 0
  for _, items in pairs(bullets) do
    for i = #items, 1, -1 do
      if items[i]:lower():find(pattern, 1, true) then
        table.remove(items, i)
        removed = removed + 1
      end
    end
  end
  if removed > 0 then
    local ok, err = save_context(bullets, order)
    if not ok then return 0, err or "write failed" end
  end
  return removed
end

--------------------------------------------------------------------------------
-- Skills: index always known, body loaded on demand. The implementation lives in
-- memory/skills.lua; it is wired with this module's shared helpers here so the two
-- files share one scan cache and the session without a circular require.
--------------------------------------------------------------------------------

local skills = require("advantage.memory.skills")
skills.setup({
  mem = M,
  read_file = read_file,
  write_file = write_file,
  tokens = tokens,
  opts = opts,
  skills_dir = skills_dir,
  word_set = word_set,
})

M.skills_index = skills.skills_index
M.use_skill = skills.use_skill
M.skill_hints = skills.skill_hints
M.save_skill = skills.save_skill

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
  local list = skills.scan_skills()
  local bodies_tokens = 0
  for _, s in ipairs(list) do
    -- The dashboard needs a savings estimate, not every full runbook body. File
    -- size is a conservative proxy and avoids rereading all skills on each open.
    bodies_tokens = bodies_tokens + math.ceil((tonumber(s.bytes) or 0) / 4)
  end
  return {
    block_tokens = tokens(M.render()),
    skills = #list,
    bodies_tokens = bodies_tokens,
    loads = M._session.skill_loads,
    loaded_tokens = M._session.skill_load_tokens,
  }
end

--------------------------------------------------------------------------------
-- Project memory ingestion (parity: real CLIs read AGENTS.md / CLAUDE.md)
--------------------------------------------------------------------------------

local function configured_byte_cap(field, default_tokens)
  local value = tonumber(opts()[field]) or default_tokens
  if value ~= value or value == math.huge or value == -math.huge then value = default_tokens end
  return math.max(400, math.min(MAX_REPO_FILE_BYTES, math.floor(math.max(1, value) * 4)))
end

---Expand one level of @imports while bounding the finished string during
---construction. Repeated imports are represented once and cached reads ensure a
---repo cannot multiply I/O/allocation with thousands of identical references.
local function expand_project_imports(text, root, cap)
  local out, used, pos, truncated = {}, 0, 1, false
  local cache, included = {}, {}
  local function append(part)
    if part == "" then return true end
    local room = cap - used
    if room <= 0 then
      truncated = true
      return false
    end
    local complete = true
    if #part > room then
      part = utf8_safe_sub(part, room)
      truncated = true
      complete = false
    end
    out[#out + 1] = part
    used = used + #part
    return complete and used < cap
  end

  while pos <= #text and used < cap do
    local first, last, rel = text:find("@([%w._/-]+)", pos)
    if not first then
      append(text:sub(pos))
      pos = #text + 1
      break
    end
    if not append(text:sub(pos, first - 1)) then break end
    local abs = util.contain(rel, root, false)
    local replacement = "@" .. rel
    if abs then
      if included[abs] then
        replacement = ("[duplicate @%s omitted]"):format(rel)
      else
        included[abs] = true
        if cache[abs] == nil then
          local imported, import_truncated = read_file(abs, cap)
          cache[abs] = { text = imported, truncated = import_truncated }
        end
        if cache[abs].text then replacement = cache[abs].text end
        if cache[abs].truncated then truncated = true end
      end
    end
    if not append(replacement) then break end
    pos = last + 1
  end
  if pos <= #text then truncated = true end
  return table.concat(out), truncated
end

local function instruction_dirs()
  local root, cwd = vim.fs.normalize(M.root()), vim.fs.normalize(M.cwd())
  local dirs = { root }
  if cwd == root then return dirs end
  local rel = cwd:sub(#root + 2)
  local current = root
  for segment in rel:gmatch("[^/]+") do
    current = current .. "/" .. segment
    dirs[#dirs + 1] = current
  end
  return dirs
end

---Read the project's committed instruction chain, resolving one level of
---`@file` imports. The closest file wins within each directory and nested files
---are appended after root guidance, matching the override semantics used by
---modern coding harnesses without paying for unrelated subtrees.
local function project_memory()
  local root = M.root()
  local cap = configured_byte_cap("project_budget_tokens", 2000)
  local source_cap = math.min(MAX_REPO_FILE_BYTES, math.max(64 * 1024, cap * 4))
  local candidates = { "AGENTS.override.md", "AGENTS.md", "CLAUDE.local.md", "CLAUDE.md" }
  local blocks, used, any_truncated = {}, 0, false
  local dirs = instruction_dirs()
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(candidates) do
      local path = M.contain(dir .. "/" .. name)
      local candidate, truncated
      if path then
        candidate, truncated = read_file(path, source_cap)
      end
      if candidate and vim.trim(candidate) ~= "" then
        local room = cap - used
        if room <= 0 then
          any_truncated = true
          break
        end
        local expanded, expanded_truncated = expand_project_imports(candidate, root, room)
        expanded = vim.trim(expanded:gsub("<!%-%-.-%-%->", ""))
        local rel = path:sub(#root + 2)
        -- Preserve the historical single-root-file bytes. Source labels are
        -- only needed once multiple directory scopes can participate.
        local header = #dirs > 1 and ("## Instructions: %s\n"):format(rel) or ""
        local block = header .. expanded
        if #block > room then
          block = utf8_safe_sub(block, room)
          expanded_truncated = true
        end
        blocks[#blocks + 1] = block
        used = used + #block + 2
        any_truncated = any_truncated or truncated or expanded_truncated
        break
      end
    end
    if used >= cap then break end
  end
  if #blocks == 0 then return nil end
  local text = table.concat(blocks, "\n\n")
  if any_truncated then
    local marker = "\n… [project memory truncated]"
    text = utf8_safe_sub(text, math.max(0, cap - #marker)) .. marker
  end
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
  if not dir then return {} end
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
  local cap = configured_byte_cap("config_budget_tokens", 2000)
  local docs = {}
  for _, name in ipairs(names) do
    local path = M.contain(".advantage/" .. name)
    local text, truncated
    if path then
      text, truncated = read_file(path, cap)
    end
    if text then
      text = vim.trim(text:gsub("<!%-%-.-%-%->", ""))
      if #text > 0 then
        if truncated then
          local marker = "\n… [config doc truncated]"
          text = utf8_safe_sub(text, math.max(0, cap - #marker)) .. marker
        end
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
  local direct = M.contain(path)
  if direct and uv.fs_stat(direct) then return true end
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

---Build the repo-facts part from context.md, or a cold-start placeholder telling
---the model the (empty) memory exists so the learning flywheel starts on turn one.
local function repo_facts_part()
  local bullets, order, source_truncated = parse_context()
  assert(type(bullets) == "table", "repo_facts_part: parse_context must return a bullets table")
  local has_facts = false
  for _, items in pairs(bullets) do
    if #items > 0 then has_facts = true end
  end
  if has_facts then
    local text = vim.trim(render_context(bullets, order))
    local cap = math.min(MAX_REPO_FILE_BYTES, budget_chars() + 1024)
    if source_truncated or #text > cap then
      local marker = "\n… [context.md truncated to the configured memory budget]"
      text = utf8_safe_sub(text, math.max(0, cap - #marker)) .. marker
    end
    return { label = "repo memory (context.md)", text = text }
  end
  return {
    label = "repo memory (context.md, empty)",
    text = "# Repo memory\nEmpty so far — this repo hasn't been learned yet. As you discover durable, non-obvious facts (build/test commands, architecture invariants, conventions, gotchas, stated preferences), record them with the `remember` tool so future sessions start ahead.",
  }
end

---Build the budgeted, always-loaded skills index part, or nil when no skills
---exist. Truncation is deterministic (scan_skills is alphabetical), so the frozen
---block stays prompt-cache-stable; a dropped skill is still loadable by name.
local function skills_index_part()
  local skill_list = skills.scan_skills()
  if #skill_list == 0 then return nil end
  local lines = {
    "# Skills — reusable procedures for this repo.",
    "Call the `use_skill` tool with the name to load a skill's full steps before doing that task.",
  }
  local budget = math.max(200, (opts().skills_index_budget_tokens or 1200) * 4)
  assert(budget >= 200, "skills_index_part: index budget must be positive")
  local used = #lines[1] + #lines[2] + 2
  local shown, dropped = 0, 0
  for _, s in ipairs(skill_list) do
    -- keep the index lean: one line, description capped so a verbose skill
    -- can't bloat the always-loaded tier (the body loads on demand anyway).
    local d = s.description or ""
    if #d > 200 then d = utf8_safe_sub(d, 197) .. "…" end
    local line = ("- %s%s: %s"):format(s.name, s.implicit == false and " (explicit only)" or "", d)
    -- always keep at least one; otherwise stop once the index budget is spent
    if shown == 0 or used + #line + 1 <= budget then
      lines[#lines + 1] = line
      used = used + #line + 1
      shown = shown + 1
    else
      dropped = dropped + 1
    end
  end
  assert(shown >= 1, "skills_index_part: must retain at least one skill when any exist")
  if dropped > 0 then
    lines[#lines + 1] = ("- … +%d more skill(s) — load any by name with use_skill"):format(dropped)
  end
  return { label = ("skills index (%d)"):format(#skill_list), text = table.concat(lines, "\n") }
end

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

  parts[#parts + 1] = repo_facts_part()

  local skills_part = skills_index_part()
  if skills_part then parts[#parts + 1] = skills_part end

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
