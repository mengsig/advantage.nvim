---@brief The harness loop: stream a turn, execute requested tools (with
---permission gating), feed results back, repeat until the model stops.
local config = require("advantage.config")
local providers = require("advantage.providers")
local tools = require("advantage.tools")

local M = {}

local uv = vim.uv or vim.loop

local Agent = {}
Agent.__index = Agent

local function git_branch(cwd)
  local head = io.open(cwd .. "/.git/HEAD", "r")
  if not head then return nil end
  local ref = head:read("*l") or ""
  head:close()
  return ref:match("ref: refs/heads/(.+)$") or ref:sub(1, 8)
end

local function default_system_prompt()
  local cwd = uv.cwd()
  local branch = git_branch(cwd)
  local lines = {
    "You are advantage, an expert coding agent running inside Neovim, working directly in the user's project. You have access to super powerful LSP based tools, you must use these to reduce token cost and for you to have better context and understanding -- if it's the right decision: diagnostics, document_symbols, goto_definition, find_references, hover, workspace_symbol. Secondly, you have a memory system that you must take advantage of.",
    "",
    "Environment:",
    "- Project root: " .. cwd,
    "- Platform: " .. (uv.os_uname().sysname or "unknown"),
  }
  if branch then lines[#lines + 1] = "- Git branch: " .. branch end
  vim.list_extend(lines, {
    "",
    "How to work:",
    "- Use the tools to read, search, edit and run things. Paths are relative to the project root.",
    "- Gather context before acting: explore the code rather than guessing. Batch independent look-ups in one step, and delegate wide fan-out investigations to the read-only `sub_agent` tool.",
    "- Read a file before editing it. Prefer edit_file for surgical changes; write_file only for new or fully rewritten files.",
    "- Match the surrounding code's style, naming and conventions. Don't add comments that just restate the code.",
    "- After a code change, verify it when a cheap check exists (build, test, lint, syntax check), and fix what you broke.",
    "- For multi-step work, keep a plan with the todo_write tool and update statuses as you go; several changes to one file go in a single multi_edit call.",
    "- Stay within the project: file tools are confined to the project root. Ask before anything destructive or irreversible.",
    "- If a tool call errors, don't just move past it: read the error, fix the input (or the fact/skill being saved) and retry before ending your turn — a failed `remember`/`save_skill` silently loses the fact otherwise.",
    "",
    "Style: default to concise, to-the-point user-facing output unless the user asks for detail. Lead with what you did or found; skip filler, hidden reasoning, and restating the request. If a task is ambiguous, state your assumption and proceed rather than stalling.",
  })
  return table.concat(lines, "\n")
end

---Steer toward the LSP navigation tools. Injected ONLY when they're actually in
---the schema (config on + this Neovim has vim.lsp) — telling the model to prefer
---tools that aren't present would just waste turns. This is the real mechanism
---that makes the model *prefer* semantic navigation over its default grep/read
---habit: the tool descriptions alone are too weak to overcome that prior. It
---rides the cached system prefix, so it costs ~10% after turn one.
local LSP_GUIDE = table.concat({
  "Semantic code navigation — you have language-server tools; make them your DEFAULT way to understand code, not a fallback after grep. They resolve MEANING (the exact symbol, its real definition, every true call site, its type) where grep only matches text — so they are both more reliable AND fewer steps. The decision procedure:",
  "- Once you've located a symbol (a grep to FIND an identifier across the repo is fine): to see where it's defined → `goto_definition`; to see everything that uses it before you touch it → `find_references` (grep misses call sites and matches comments/strings; this doesn't); its type/signature → `hover`.",
  "- Landing in an unfamiliar file → `document_symbols` (or `read_file` with outline=true) to see its shape, instead of reading it top to bottom. This ALWAYS works fast — it falls back to a local treesitter parse — even if the language server is slow or times out on other navigation, so reach for it freely. Tracing dataflow/an action/an event across files → `find_references` on the symbol, not a chain of full-file reads.",
  "- Locate a symbol you can't place → `workspace_symbol` (match the bare name like `new`, not `M.new`; distinctive names work best — it shows project matches first).",
  "- Fall back to grep/read for non-symbol text (strings, comments, config, TODOs), for languages with no server, and when an indirect/dynamic reference doesn't resolve. If a tool reports no server is attached, the language isn't set up for navigation — use grep/read for the rest of the session.",
}, "\n")

---The LSP guide text when the navigation tools are live for this session, else nil.
---Gated exactly like the tools themselves (config.tools.lsp + vim.lsp presence),
---and — crucially — on nothing that changes mid-session, so the cached system
---prefix stays byte-identical turn to turn. Shared by the main prompt and sub-agents.
function M.lsp_guide()
  local tcfg = (config.options.tools or {}).lsp
  if type(tcfg) == "table" and tcfg.enabled == false then return nil end
  local ok, lsp = pcall(require, "advantage.lsp")
  if not (ok and lsp.available()) then return nil end
  return LSP_GUIDE
end

---Instructions for the memory tools. Only injected while memory is enabled —
---teaching the model to call `remember`/`use_skill` when those tools are absent
---from the schema would just produce "Unknown tool" errors.
local MEMORY_GUIDE = table.concat({
  "Persistent repo memory (this is your edge — it makes you faster and cheaper over time):",
  "- Repo memory and skills are injected below. Treat repo memory as trusted prior knowledge about THIS codebase; prefer it over re-deriving the same facts.",
  "- When you learn a durable, non-obvious fact future sessions would want — an architecture invariant, a convention, a build/test command, a gotcha, or a preference the user states — call `remember` to save it (one specific, self-contained fact in the right section). Prefer precision over brevity, but don't duplicate a fact already in memory. Don't record trivia or anything a quick file read re-derives.",
  "- Record as you go, not just when asked: the moment an investigation, edit, test run, or the user's own words reveal such a fact, `remember` it right then — the knowledge is lost when this session ends. But the bar is high in both directions: most turns teach nothing worth persisting, and recording trivia is as harmful as missing a real fact — it dilutes the signal and evicts good facts under the token budget. When unsure, don't record.",
  "- A skill is a reusable procedure. When a listed skill's description matches the task, call `use_skill` to load its full steps before doing that task. Codify a genuinely reusable multi-step procedure with `save_skill`.",
}, "\n")

---The base instructions only — no memory guide, no learned memory block. This is
---what a read-only sub-agent gets: it can't `remember`/`use_skill`, and shipping
---the parent's full repo memory to every fan-out worker (5× on a parallel batch,
---cold-cached) is exactly the cost leak sub-agents exist to avoid. Honors a user
---`system_prompt` override (string/function) just like the main prompt does.
function M.base_system_prompt()
  local cfg = config.options.system_prompt
  local base = default_system_prompt()
  if type(cfg) == "string" then
    base = cfg
  elseif type(cfg) == "function" then
    base = cfg(base)
  end
  return base
end

---The system prompt as an ordered list of labeled parts. Each entry is
---`{ label = "<short name>", text = "<bytes>", is_memory? = true }`.
---`M.system_prompt` joins the `text` fields with "\n\n"; `/context preview` uses
---the labels to attribute per-section token cost and expands the memory part.
---@param memory_block? string frozen block to use verbatim (see M.system_prompt)
function M.system_prompt_parts(memory_block)
  local base = M.base_system_prompt()
  local parts = { { label = "base instructions", text = base } }
  -- Steer toward semantic navigation (only when those tools are actually live).
  local lsp = M.lsp_guide()
  if lsp then parts[#parts + 1] = { label = "lsp guide", text = lsp } end
  -- Append the memory-tool instructions plus the per-repo learned context and
  -- skills index. It rides the cached system prefix, so after the first turn it
  -- costs ~10%, and it saves tokens by sparing the model repeated read/grep
  -- loops to re-derive known facts. Skipped entirely when memory is disabled.
  local ok, memory = pcall(require, "advantage.memory")
  if ok and memory.enabled() then
    parts[#parts + 1] = { label = "memory guide", text = MEMORY_GUIDE }
    local block = memory_block
    if block == nil then block = memory.render() end
    if block and block ~= "" then parts[#parts + 1] = { label = "memory block", text = block, is_memory = true } end
  end
  return parts
end

---@param memory_block? string a pre-rendered, session-frozen memory block to use
---  verbatim instead of re-rendering. Passing the same bytes every turn keeps the
---  cached system prefix byte-identical, so a mid-session `remember`/`save_skill`
---  write doesn't invalidate the whole prompt cache (a memory write persists to
---  disk and stays in the recent transcript, so the model still has it). Omit
---  (nil) to render fresh — sub-agents and tests do.
function M.system_prompt(memory_block)
  local texts = {}
  for _, p in ipairs(M.system_prompt_parts(memory_block)) do
    texts[#texts + 1] = p.text
  end
  return table.concat(texts, "\n\n")
end

---@param opts {model: table, messages?: table, id?: string, title?: string, usage?: table}
function M.new(opts)
  local self = setmetatable({}, Agent)
  self.id = opts.id or tostring(os.time()) .. "-" .. math.random(1000, 9999)
  self.model = opts.model
  self.messages = opts.messages or {}
  self.title = opts.title
  self.usage = opts.usage or { input = 0, output = 0, cached = 0 }
  self.status = "idle" -- idle | streaming | tools
  self.job = nil
  self.cancelled = false
  self.turn_started = nil
  self.turn_usage = { input = 0, output = 0, cached = 0 }
  self.turn_open = false
  self.ctx = { cwd = uv.cwd(), model = self.model }
  self.allowed = {} -- per-session "always allow" tool names
  self.queue = {} -- Ctrl-S messages submitted while a turn was running
  self.interrupts = {} -- Enter messages to inject before the next tool call
  self.pending_permission = nil -- callable that resolves the active permission card
  self.active_tools = {} -- tool_use_id -> cancellable handle returned by a running tool
  self.snapshots = {} -- abs path -> content before the agent's first touch (false = new file)
  self.turn_changed = {} -- abs paths changed during the current turn
  -- fresh conversation: reset the LSP usage-nudge streak so a new chat starts clean
  pcall(function()
    require("advantage.lsp").reset_session()
  end)
  -- fresh conversation: allow skills to be hinted again, restart savings math,
  -- and seed the on-disk memory file the first time this repo is used
  pcall(function()
    local memory = require("advantage.memory")
    memory.reset_session()
    if memory.bootstrap() then
      vim.schedule(function()
        pcall(
          require("advantage.ui.chat").notify,
          "repo memory created (.advantage/context.md) — /context init teaches the agent this repo now",
          vim.log.levels.INFO
        )
      end)
    end
  end)
  return self
end

function Agent:ui()
  return require("advantage.ui.chat")
end

function Agent:busy()
  return self.status ~= "idle"
end

---The per-session frozen memory block for the system prompt. Rendered once and
---reused so a mid-session `remember`/`save_skill` write doesn't rewrite the cached
---system prefix (which would forfeit the prompt-cache discount on the next
---request). It is refreshed from disk at each compaction boundary — where facts
---that aged out of the transcript must re-enter the prompt — by nil-ing
---`self._memory_block`, and on a new session (a fresh Agent starts it nil).
function Agent:_memory_prompt_block()
  if self._memory_block == nil then
    local ok, memory = pcall(require, "advantage.memory")
    self._memory_block = (ok and memory.render()) or ""
  end
  return self._memory_block
end

---@param opts? {mode?: "llm"|"heuristic"} one-off override of context.compact_mode
---@param callback? fun(info: table|nil) info is nil when there was nothing to compact
function Agent:compact(opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if self:busy() then
    self:ui().notify("finish or cancel the running turn before compacting context", vim.log.levels.WARN)
    return callback(nil)
  end
  self.status = "compacting"
  self:ui().compaction_start(require("advantage.compact").estimate_tokens(self.messages))
  self:_maybe_compact(true, opts, function(info)
    self.status = "idle"
    self:ui().compaction_done()
    callback(info)
  end)
end

local function user_content(text, opts, cwd)
  opts = opts or {}
  -- inline @file mentions; the transcript shows the original text
  local send_text = require("advantage.attach").expand_mentions(text, cwd)
  -- Auto-surface relevant skills: a deterministic keyword match against the
  -- skill index appends a one-line hint to the outgoing message (never the
  -- system prompt, so the cached prefix stays byte-identical). Once per skill
  -- per session; the transcript shows the user's original text.
  local mok, memory = pcall(require, "advantage.memory")
  if mok then
    local hints = memory.skill_hints(text)
    if #hints > 0 then
      local lines = { "", "<repo-skill-hint>" }
      for _, s in ipairs(hints) do
        lines[#lines + 1] = ("The %q skill may apply here (%s). If relevant, load its steps with use_skill before proceeding."):format(
          s.name,
          s.description
        )
      end
      lines[#lines + 1] = "</repo-skill-hint>"
      send_text = send_text .. table.concat(lines, "\n")
    end
  end
  local content = {}
  for _, img in ipairs(opts.images or {}) do
    content[#content + 1] = {
      type = "image",
      source = { type = "base64", media_type = img.media_type, data = img.data },
    }
  end
  content[#content + 1] = { type = "text", text = send_text }
  return content
end

function Agent:_push_user_message(text, opts, show)
  local content = user_content(text, opts, self.ctx.cwd)
  local msg = { role = "user", content = content }
  -- The first user turn of a session is the original task: pin it so compaction
  -- keeps it verbatim (never paraphrased/truncated) no matter how long the
  -- session runs. Compaction reads this flag; providers ignore it.
  if #self.messages == 0 then msg.pinned = true end
  table.insert(self.messages, msg)
  if show ~= false then self:ui().user_message(text, opts and opts.images) end
end

---Entry point: user sends a prompt. While a turn is running, `mode = "queued"`
---queues behind the whole agent flow; the default `mode = "instant"` injects the
---message before the next tool call without cancelling the current response.
---@param opts? {images?: {name:string, media_type:string, data:string}[], mode?: "instant"|"queued"}
function Agent:send(text, opts)
  opts = opts or {}
  -- Compaction is a brief, blocking operation: there is no "next tool call" to
  -- inject before, so refuse the send (the UI blocks submit too, keeping the
  -- typed text) rather than silently queuing it.
  if self.status == "compacting" then
    self:ui().notify("compacting context — wait for it to finish before sending", vim.log.levels.WARN)
    return
  end
  if self:busy() then
    if opts.mode == "queued" then
      self.queue[#self.queue + 1] = { text = text, opts = opts }
      self:ui().queued(#self.queue, text)
      return
    end
    local item = { text = text, opts = opts, content = user_content(text, opts, self.ctx.cwd) }
    self.interrupts[#self.interrupts + 1] = item
    self:ui().user_message(text, opts.images)
    self:ui().notice("will send before the next tool call")
    if self.pending_permission then self.pending_permission("interrupt") end
    return
  end
  if not self.title then self.title = require("advantage.util").utf8_safe_sub(text:gsub("%s+", " "), 56) end

  self:_push_user_message(text, opts)
  self.cancelled = false
  self.turn_started = uv.hrtime()
  self.turn_usage = { input = 0, output = 0, cached = 0 }
  self.turn_open = false
  self.turn_changed = {}
  self.loop = 0 -- provider round-trips this user turn (runaway guard)
  self:_turn()
end

function Agent:_drain_interrupts(results, remaining_calls)
  if #self.interrupts == 0 then return false end
  results = results or {}
  for _, call in ipairs(remaining_calls or {}) do
    results[#results + 1] = {
      type = "tool_result",
      tool_use_id = call.id,
      content = "Tool skipped because the user sent a new message before it ran.",
      is_error = true,
    }
    self:ui().tool_update(call.id, { status = "denied", detail = "interrupted" })
  end

  -- Keep synthetic tool results and the user's new message as distinct turns.
  -- Anthropic permits tool_result blocks in user messages, while OpenAI's
  -- Responses API is much stricter about function_call_output sequencing; a
  -- mixed "tool_result + text" content array can produce 400s after an
  -- interrupt.  The canonical history therefore becomes:
  --   assistant(tool_use), user(tool_result...), user(actual interruption)
  if #results > 0 then table.insert(self.messages, { role = "user", content = results }) end
  for _, item in ipairs(self.interrupts) do
    table.insert(self.messages, { role = "user", content = item.content })
  end
  self.interrupts = {}
  self.loop = 0 -- fresh user input restarts the runaway budget
  return true
end

function Agent:_drain_interrupts_as_user_messages()
  if #self.interrupts == 0 then return false end
  for _, item in ipairs(self.interrupts) do
    table.insert(self.messages, { role = "user", content = item.content })
  end
  self.interrupts = {}
  self.loop = 0 -- fresh user input restarts the runaway budget
  return true
end

local MUTATING = { write_file = true, edit_file = true, multi_edit = true }

---Remember a file's pre-edit content so `/review` can diff against it.
function Agent:_snapshot(call)
  if not MUTATING[call.name] then return end
  local path = tools.resolve and tools.resolve(call.input and call.input.path, self.ctx)
  if not path then return end
  if self.snapshots[path] == nil then
    local f = io.open(path, "r")
    self.snapshots[path] = f and f:read("*a") or false
    if f then f:close() end
  end
  return path
end

---Silent auto-compact gates. Returns true to skip compaction this round.
---(Manual/forced compaction bypasses all three.)
function Agent:_auto_compact_blocked(compact, threshold)
  assert(type(threshold) == "number", "_auto_compact_blocked: numeric threshold required")
  assert(type(self.messages) == "table", "_auto_compact_blocked: agent must have a messages table")
  -- Re-entrancy guard: the LLM path is async (self.job resolves later), and
  -- _turn_impl calls _maybe_compact(false) on every tool-loop round trip.
  -- Without this, a second round trip can fire before the first summarizer
  -- call's callback lands (which is where _auto_compact_floor gets set),
  -- spawning a second concurrent compaction over the *same* still-unchanged
  -- self.messages — visible as two "compacted ..." notices in a row with
  -- identical before/after token counts.
  if self._compacting then return true end

  -- Threshold gate: silent auto-compact (heuristic or llm) never fires below the
  -- resolved threshold. The heuristic path re-checks this itself, but the llm
  -- path does not, so without this check the very first auto-compact of a session
  -- (before _auto_compact_floor exists) would fire on message count alone under
  -- auto_compact_mode = "llm", ignoring the threshold entirely.
  if compact.estimate_tokens(self.messages) < threshold then return true end

  -- Hysteresis: once auto-compaction has run, don't fire again until the
  -- transcript has genuinely grown past where it left off. Without this, a
  -- session whose protected "recent" window alone sits near compact_at_tokens
  -- keeps re-crossing the threshold on almost every tool-loop round trip within a
  -- single prompt — thrashing (repeated summarizer calls / rewritten history) and
  -- shredding the prompt cache instead of settling. `_auto_compact_floor` is the
  -- after_tokens estimate from the last compaction (manual or auto); require
  -- growth of at least 10% of the threshold beyond it before considering another.
  local margin = math.max(threshold * 0.1, 2000)
  if self._auto_compact_floor and compact.estimate_tokens(self.messages) < self._auto_compact_floor + margin then
    return true
  end
  return false
end

---Adopt a freshly compacted transcript and refresh the compaction bookkeeping.
---Called from both the heuristic and llm completion paths.
function Agent:_adopt_compaction(next_messages, info)
  assert(type(next_messages) == "table" and #next_messages > 0, "_adopt_compaction: non-empty messages required")
  assert(type(info) == "table", "_adopt_compaction: info table required")
  self.messages = next_messages
  self._auto_compact_floor = info.after_tokens
  -- Compaction boundary: re-render the memory block from disk next turn so any
  -- fact that just aged out of the transcript re-enters the (now legitimately
  -- re-cached) system prefix.
  self._memory_block = nil
end

---Completion callback for the async LLM summarizer. Splices the summary in on
---success, records its token usage, and falls back to the heuristic on failure.
function Agent:_on_llm_compaction(next_messages, info, err, finish_heuristic, callback)
  assert(
    type(finish_heuristic) == "function" and type(callback) == "function",
    "_on_llm_compaction: callbacks required"
  )
  local util = require("advantage.util")
  self.job = nil
  self._compacting = false
  -- If the user cancelled mid-summarize, cancel() already cleaned up; never
  -- splice a summary into a transcript the user abandoned.
  if self.cancelled then return end
  if not next_messages then
    if not err then return callback(nil) end
    self
      :ui()
      .notify("LLM compaction failed (" .. tostring(err) .. ") — falling back to the offline heuristic", vim.log.levels.WARN)
    return finish_heuristic()
  end
  info = info or {}
  self:_adopt_compaction(next_messages, info)
  if info.usage and ((info.usage.input or 0) > 0 or (info.usage.output or 0) > 0) then
    local u = info.usage
    self.usage.input = self.usage.input + u.input
    self.usage.output = self.usage.output + u.output
    self.usage.cached = (self.usage.cached or 0) + (u.cached or 0)
    self:ui().set_usage(self.usage)
    require("advantage.usage").record(info.model, u.input, u.output, u.cached)
  end
  local label = (info.model and info.model.label) or "llm"
  if info.reason == "llm_summary_increased_context" then label = label .. " → heuristic fallback" end
  self:ui().notice(
    ("compacted %d old messages with %s (~%s → ~%s tokens)"):format(
      info.compacted_messages,
      label,
      util.fmt_tokens(info.before_tokens),
      util.fmt_tokens(info.after_tokens)
    )
  )
  callback(info)
end

---Run the offline heuristic compaction, adopt the result, and settle _compacting.
---Also serves as the fallback path when LLM compaction fails.
function Agent:_finish_heuristic_compaction(force, eff, callback)
  assert(type(eff) == "table" and type(callback) == "function", "_finish_heuristic_compaction: eff/callback required")
  local compact = require("advantage.compact")
  local util = require("advantage.util")
  local next_messages, info
  if force then
    next_messages, info = compact.force(self.messages, eff)
  else
    next_messages, info = compact.compact(self.messages, eff)
  end
  if info then
    self:_adopt_compaction(next_messages, info)
    self:ui().notice(
      ("compacted %d old messages (~%s → ~%s tokens)"):format(
        info.compacted_messages,
        util.fmt_tokens(info.before_tokens),
        util.fmt_tokens(info.after_tokens)
      )
    )
  end
  self._compacting = false
  callback(info)
end

---@param force boolean true for manual/forced compaction, false for the silent auto-compact check
---@param opts? {mode?: "llm"|"heuristic"}
---@param callback? fun(info: table|nil)
function Agent:_maybe_compact(force, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  assert(type(callback) == "function", "_maybe_compact: callback must be a function")
  local cfg = config.options.context or {}
  if not force and cfg.auto_compact == false then return callback(nil) end
  local compact = require("advantage.compact")

  -- Model-relative bounds, resolved once. The auto-compact threshold and the
  -- retained recent-window token budget both scale to the active model's
  -- context_window (compact.resolve_*), so a 1M-context model isn't compacted at
  -- the same token count as a 200k one; both fall back to constants when the
  -- model declares no window. compact.lua itself stays model-agnostic — it just
  -- consumes the numbers handed to it below in `eff`.
  local threshold = compact.resolve_threshold(cfg, self.model)

  if not force and self:_auto_compact_blocked(compact, threshold) then return callback(nil) end

  self._compacting = true
  -- Resolved config for the model-agnostic compaction functions: the
  -- window-scaled threshold and the recent-window token budget (#3), layered
  -- over the user's context config. force compaction (M.force) overrides the
  -- threshold to 0 but keeps the recent-window budget.
  local eff = vim.tbl_extend("force", cfg, {
    compact_at_tokens = threshold,
    keep_recent_tokens = compact.resolve_keep_recent_tokens(cfg, threshold),
  })
  local function finish_heuristic()
    self:_finish_heuristic_compaction(force, eff, callback)
  end

  -- Manual /compact uses context.compact_mode (or a one-off override). Silent
  -- auto-compact uses its own context.auto_compact_mode, defaulting to the free
  -- heuristic so background threshold crossings don't add surprise API usage
  -- unless the user explicitly opts in.
  local mode = force and (opts.mode or cfg.compact_mode or "heuristic") or (cfg.auto_compact_mode or "heuristic")
  if mode ~= "llm" then return finish_heuristic() end

  self.job = compact.summarize_with_llm(self.messages, eff, function(next_messages, info, err)
    self:_on_llm_compaction(next_messages, info, err, finish_heuristic, callback)
  end, self.model)
end

function Agent:_turn()
  local ok, err = pcall(function()
    self:_turn_impl()
  end)
  if not ok then
    self.job = nil
    self:ui().notice("error starting turn: " .. tostring(err))
    self:_finish(true)
  end
end

function Agent:_turn_impl()
  self.ctx.model = self.model
  -- Mark busy before compaction (which may be asynchronous in LLM mode) so a
  -- concurrent send() during the wait is treated as an interrupt/queue instead
  -- of slipping through as a second top-level turn while status is still "idle".
  self.status = "streaming"

  local function continue_turn()
    local ok, err = pcall(function()
      self:_continue_turn()
    end)
    if not ok then
      self.job = nil
      self:ui().notice("error starting turn: " .. tostring(err))
      self:_finish(true)
    end
  end

  -- Wait for compaction to finish before building this turn's request: the LLM
  -- path mutates self.messages asynchronously (self.messages = next_messages),
  -- so starting the main request in parallel would race a concurrent replacement
  -- of self.messages (silently dropping messages the turn appends meanwhile) and
  -- clobber the compaction job's handle in self.job. The heuristic path calls
  -- back synchronously, so this changes nothing for the default auto-compact mode.
  -- Compaction is still best-effort: a synchronous failure here must not abort
  -- the turn, so fall through to streaming with un-compacted history.
  local ok = pcall(function()
    self:_maybe_compact(false, nil, continue_turn)
  end)
  if not ok then continue_turn() end
end

---Fold a streamed usage report into both the session and per-turn counters.
function Agent:_accumulate_usage(inp, out, cached)
  assert(type(inp) == "number" and type(out) == "number", "_accumulate_usage: numeric token counts required")
  assert(type(self.usage) == "table" and type(self.turn_usage) == "table", "_accumulate_usage: usage tables missing")
  cached = cached or 0
  self.usage.input = self.usage.input + inp
  self.usage.output = self.usage.output + out
  self.usage.cached = (self.usage.cached or 0) + cached
  self.turn_usage.input = self.turn_usage.input + inp
  self.turn_usage.output = self.turn_usage.output + out
  self.turn_usage.cached = (self.turn_usage.cached or 0) + cached
  self:ui().set_usage(self.usage)
  require("advantage.usage").record(self.model, inp, out, cached)
end

---Reset the per-turn timing/usage bookkeeping without starting a turn.
function Agent:_reset_turn_state()
  self.turn_started = uv.hrtime()
  self.turn_usage = { input = 0, output = 0, cached = 0 }
  self.turn_open = false
end

---Reset per-turn bookkeeping and begin a fresh assistant turn. Used when drained
---interrupts inject input that must be answered before the loop continues.
function Agent:_restart_turn()
  self:_reset_turn_state()
  return self:_turn()
end

---Handle a completed model response: record the assistant blocks, then route to
---tool execution, an interrupt-driven restart, or turn completion.
function Agent:_on_stream_complete(blocks, stop_reason)
  assert(type(blocks) == "table", "_on_stream_complete: blocks must be a table")
  self.job = nil
  if self.cancelled then return end
  if #blocks > 0 then table.insert(self.messages, { role = "assistant", content = blocks }) end
  self:ui().message_meta(self.turn_usage, self.turn_started and (uv.hrtime() - self.turn_started) or nil)

  if stop_reason == "tool_use" then
    local calls = {}
    for _, b in ipairs(blocks) do
      if b.type == "tool_use" then calls[#calls + 1] = b end
    end
    if #calls > 0 then
      if self:_drain_interrupts(nil, calls) then return self:_restart_turn() end
      return self:_run_tools(calls)
    end
  end

  if self:_drain_interrupts_as_user_messages() then return self:_restart_turn() end

  if stop_reason == "refusal" then
    self:ui().notice("the model declined this request (safety refusal)")
  elseif stop_reason == "max_tokens" then
    self:ui().notice("response hit the output-token limit and was truncated")
  end
  self:_finish()
end

function Agent:_continue_turn()
  -- provider-request count; /usage uses it for the harness savings math
  self.usage.turns = (self.usage.turns or 0) + 1

  -- Runaway guard: bound the tool loop (edit→test→re-edit…) per user turn so a
  -- thrashing model can't burn tokens without end, especially under yolo.
  self.loop = (self.loop or 0) + 1
  local cap = config.options.max_agent_turns or 100
  if cap > 0 and self.loop > cap then
    self:ui().notice(("stopped after %d tool-loop steps (max_agent_turns) — send a message to continue"):format(cap))
    self:_finish()
    return
  end

  local provider = providers.get(self.model.provider)
  if not provider then
    self:ui().notify("unknown provider: " .. tostring(self.model.provider), vim.log.levels.ERROR)
    self:_finish(true)
    return
  end

  self.status = "streaming"
  self.ctx.system = M.system_prompt(self:_memory_prompt_block())
  local ui = self:ui()
  if not self.turn_open then
    ui.begin_assistant(self.model.label)
    self.turn_open = true
  end
  ui.set_status("streaming")

  self.job = provider.stream({
    model = self.model,
    system = self.ctx.system,
    messages = self.messages,
    tools = tools.schemas(),
    on = self:_stream_handlers(ui),
  })
end

---Build the provider stream callback table, routing each event to a method so
---the streaming state machine lives in named handlers, not one giant literal.
function Agent:_stream_handlers(ui)
  assert(type(ui) == "table", "_stream_handlers: ui module required")
  return {
    text = function(chunk)
      ui.stream_text(chunk)
    end,
    thinking = function(chunk)
      ui.stream_thinking(chunk)
    end,
    tool_start = function(id, name)
      ui.tool_begin(id, name)
    end,
    auth = function(badge)
      ui.set_auth(badge)
    end,
    usage = function(inp, out, cached)
      self:_accumulate_usage(inp, out, cached)
    end,
    complete = function(blocks, stop_reason)
      self:_on_stream_complete(blocks, stop_reason)
    end,
    error = function(msg)
      self.job = nil
      if self.cancelled then return end
      ui.notice("error: " .. msg)
      self:_finish(true)
    end,
  }
end

---Fan-out fast path: a batch of read-only `sub_agent` calls needs no permission
---prompts and shares no mutable state, so we launch them together and let their
---network round-trips overlap on the event loop instead of running end-to-end
---one at a time. Results are collected by position and fed back once all settle.
---`seed` carries tool_results already produced by a sequential prefix of the
---same batch (e.g. a todo_write ahead of the fan-out); they lead the reply.
---Splice all settled parallel results (after any strict-order seed) into the
---transcript and continue, once every worker in the batch has finished.
function Agent:_parallel_maybe_finish(st)
  if st.finished or st.launching or st.pending > 0 then return end
  st.finished = true
  if self.cancelled then return end
  local dense = {}
  for _, r in ipairs(st.seed or {}) do
    dense[#dense + 1] = r
  end
  for i = 1, #st.calls do
    if st.results[i] then dense[#dense + 1] = st.results[i] end
  end
  table.insert(self.messages, { role = "user", content = dense })
  -- A message the user sent during the fan-out ("instant" mode) was promised to
  -- go in before the next turn; the parallel path has no permission card to trip
  -- it, so drain it here now that every worker has settled.
  if self:_drain_interrupts_as_user_messages() then self:_reset_turn_state() end
  self:_turn()
end

---Launch one worker in a parallel batch, recording its result when it settles.
function Agent:_parallel_launch(st, idx, call)
  assert(type(st) == "table" and type(idx) == "number", "_parallel_launch: state and index required")
  local ui = st.ui
  local tool = tools.get(call.name)
  local detail = tool and tool.summary and tool.summary(call.input) or nil
  ui.tool_update(call.id, { name = call.name, detail = detail, status = "running" })
  ui.set_status("tool", call.name)

  local function settle(output, is_error)
    if self.cancelled then return end
    st.results[idx] = { type = "tool_result", tool_use_id = call.id, content = output, is_error = is_error or nil }
    ui.tool_update(call.id, { status = is_error and "error" or "ok" })
    st.pending = st.pending - 1
    self:_parallel_maybe_finish(st)
  end

  local verr = tool and tools.validate_input(call.name, call.input)
  if not tool then
    return settle("Unknown tool: " .. tostring(call.name), true)
  elseif verr then
    return settle(verr, true)
  end

  local done = false
  local ok, handle = pcall(
    tool.run,
    call.input,
    self.ctx,
    vim.schedule_wrap(function(output, is_error, meta)
      if self.cancelled then return end
      if meta and meta.stream then
        if ui.tool_output then ui.tool_output(call.id, output or "") end
        return
      end
      if done then return end
      done = true
      self.active_tools[call.id] = nil
      settle(output, is_error)
    end)
  )
  if ok and type(handle) == "table" and (handle.stop or handle.kill) then
    self.active_tools[call.id] = handle
  elseif not ok then
    done = true
    self.active_tools[call.id] = nil
    settle("Tool crashed: " .. tostring(handle), true)
  end
end

function Agent:_run_tools_parallel(calls, seed)
  assert(type(calls) == "table" and #calls > 0, "_run_tools_parallel: non-empty calls required")
  local st = {
    calls = calls,
    seed = seed,
    ui = self:ui(),
    results = {},
    pending = #calls,
    finished = false,
    launching = true,
  }
  for idx, call in ipairs(calls) do
    self:_parallel_launch(st, idx, call)
  end
  st.launching = false
  self:_parallel_maybe_finish(st)
end

---Append a tool result to the sequential batch's accumulator.
function Agent:_tools_record(st, call, output, is_error)
  st.results[#st.results + 1] = {
    type = "tool_result",
    tool_use_id = call.id,
    content = output,
    is_error = is_error or nil,
  }
end

---Finish a sequential batch: splice results into the transcript and continue.
function Agent:_tools_finish(st)
  if self.cancelled then return end
  table.insert(self.messages, { role = "user", content = st.results })
  self:_turn()
end

---Before running the next tool, honor a pending interrupt or hand the remaining
---tail off to the parallel path. Returns true when control was redirected.
function Agent:_tools_maybe_redirect(st)
  if #self.interrupts > 0 then
    local remaining = {}
    for j = st.i + 1, #st.calls do
      remaining[#remaining + 1] = st.calls[j]
    end
    self:_drain_interrupts(st.results, remaining)
    self:_restart_turn()
    return true
  end
  -- Read-only sub_agent calls need no permission prompts and share no mutable
  -- state, so once only sub_agents remain in the batch the rest fan out
  -- concurrently. Any mutating or permission-gated tools ahead of them still ran
  -- in strict order first; this is the hand-off at that boundary.
  if st.parallel_subagents and #st.calls - st.i > 1 then
    for j = st.i + 1, #st.calls do
      if st.calls[j].name ~= "sub_agent" then return false end
    end
    local tail = {}
    for j = st.i + 1, #st.calls do
      tail[#tail + 1] = st.calls[j]
    end
    self:_run_tools_parallel(tail, st.results)
    return true
  end
  return false
end

---Run a single approved tool, recording its result and advancing on completion.
function Agent:_tools_execute(st, call, tool)
  assert(type(tool) == "table" and type(tool.run) == "function", "_tools_execute: runnable tool required")
  local ui = st.ui
  ui.set_status("tool", call.name)
  ui.tool_update(call.id, { status = "running" })
  local touched = self:_snapshot(call)
  local settled = false
  local ok, handle_or_err = pcall(
    tool.run,
    call.input,
    self.ctx,
    vim.schedule_wrap(function(output, is_error, meta)
      if self.cancelled then return end
      if meta and meta.stream then
        if ui.tool_output then ui.tool_output(call.id, output or "") end
        return
      end
      if settled then return end
      settled = true
      self.active_tools[call.id] = nil
      self:_tools_record(st, call, output, is_error)
      ui.tool_update(call.id, { status = is_error and "error" or "ok" })
      if touched and not is_error then self.turn_changed[touched] = true end
      self:_tools_run_next(st)
    end)
  )
  if ok and type(handle_or_err) == "table" and (handle_or_err.stop or handle_or_err.kill) then
    self.active_tools[call.id] = handle_or_err
  end
  if not ok then
    settled = true
    self.active_tools[call.id] = nil
    self:_tools_record(st, call, "Tool crashed: " .. tostring(handle_or_err), true)
    ui.tool_update(call.id, { status = "error" })
    self:_tools_run_next(st)
  end
end

---Show the permission card for a gated tool and route the user's decision.
function Agent:_tools_request_permission(st, call, tool)
  local ui = st.ui
  local preview = tool.preview and tool.preview(call.input, self.ctx)
    or { title = call.name, lines = vim.split(vim.inspect(call.input), "\n"), filetype = "lua" }
  ui.tool_update(call.id, { status = "waiting" })
  ui.set_status("waiting", call.name)
  self.pending_permission = ui.confirm(preview, function(decision, comment)
    self.pending_permission = nil
    if self.cancelled then return end
    if decision == "always" then
      self.allowed[call.name] = true
      return self:_tools_execute(st, call, tool)
    elseif decision == "allow" then
      return self:_tools_execute(st, call, tool)
    elseif decision == "interrupt" then
      self:_tools_record(st, call, "Tool skipped because the user sent a new message before it ran.", true)
      ui.tool_update(call.id, { status = "denied", detail = "interrupted" })
      self:_tools_run_next(st)
    else
      local msg = "The user denied this action."
      if comment and comment ~= "" then
        msg = msg .. " Their feedback: " .. comment
        ui.notice("deny → " .. comment)
      else
        msg = msg .. " Ask before retrying, or take a different approach."
      end
      self:_tools_record(st, call, msg, true)
      ui.tool_update(call.id, { status = "denied" })
      self:_tools_run_next(st)
    end
  end)
  if #self.interrupts > 0 and self.pending_permission then self.pending_permission("interrupt") end
end

---Advance the sequential tool loop by one: validate, then execute or prompt.
function Agent:_tools_run_next(st)
  if self.cancelled then return end
  if self:_tools_maybe_redirect(st) then return end
  st.i = st.i + 1
  local call = st.calls[st.i]
  if not call then return self:_tools_finish(st) end

  local ui = st.ui
  local tool = tools.get(call.name)
  if not tool then
    self:_tools_record(st, call, "Unknown tool: " .. tostring(call.name), true)
    ui.tool_update(call.id, { status = "error", detail = "unknown tool" })
    return self:_tools_run_next(st)
  end

  local verr = tools.validate_input(call.name, call.input)
  if verr then
    self:_tools_record(st, call, verr, true)
    ui.tool_update(call.id, { status = "error", detail = "missing argument" })
    return self:_tools_run_next(st)
  end

  local detail = tool.summary and tool.summary(call.input) or nil
  ui.tool_update(call.id, { name = call.name, detail = detail })

  local cfg = st.cfg
  if tool.safe or self.allowed[call.name] or cfg.tools.auto_approve[call.name] or cfg.tools.yolo then
    return self:_tools_execute(st, call, tool)
  end
  return self:_tools_request_permission(st, call, tool)
end

function Agent:_run_tools(calls)
  assert(type(calls) == "table" and #calls > 0, "_run_tools: non-empty calls required")
  self.status = "tools"
  local cfg = config.options
  local st = {
    calls = calls,
    results = {},
    i = 0,
    ui = self:ui(),
    cfg = cfg,
    parallel_subagents = cfg.subagents and cfg.subagents.parallel ~= false,
  }
  self:_tools_run_next(st)
end

function Agent:_finish(errored)
  self.status = "idle"
  local ui = self:ui()
  ui.finish_turn()
  ui.set_status("idle")
  -- Persist even on a cancelled/errored turn: the cancel path already trimmed the
  -- transcript to a consistent last message, and the errored path never appended a
  -- partial assistant turn, so the just-sent user message survives a later exit.
  if config.options.sessions.autosave then require("advantage.session").save(self) end
  local changed = vim.tbl_count(self.turn_changed or {})
  if changed > 0 and not self.cancelled then
    ui.notice(("%d file%s changed — /review to inspect"):format(changed, changed == 1 and "" or "s"))
    self.turn_changed = {}
  end
  -- dispatch the next queued message, if any
  if not errored and not self.cancelled and #self.queue > 0 then
    local nxt = table.remove(self.queue, 1)
    ui.set_queue(#self.queue)
    vim.schedule(function()
      if not self:busy() then
        nxt.opts.mode = nil
        self:send(nxt.text, nxt.opts)
      end
    end)
  else
    ui.set_queue(#self.queue)
  end
end

function Agent:cancel(opts)
  opts = opts or {}
  if not self:busy() then return end
  local was_compacting = self.status == "compacting"
  self.cancelled = true
  -- job.stop() below never invokes the summarizer's completion callback, which
  -- is the only place that otherwise clears this flag — reset it here so a
  -- cancelled compaction (manual /compact, or auto_compact_mode = "llm") can't
  -- permanently disable silent auto-compact for the rest of the session.
  self._compacting = false
  -- A cancelled LLM compaction stops the summarizer stream, so its completion
  -- callback (which clears the progress bar) never fires — clear it here.
  if was_compacting then pcall(function()
    self:ui().compaction_done()
  end) end
  if not opts.keep_queue and #self.queue > 0 then
    self:ui().notice(("dropped %d queued message%s"):format(#self.queue, #self.queue == 1 and "" or "s"))
    self.queue = {}
    self:ui().set_queue(0)
  end
  if not opts.keep_queue and #self.interrupts > 0 then
    self:ui().notice(("dropped %d pending message%s"):format(#self.interrupts, #self.interrupts == 1 and "" or "s"))
    self.interrupts = {}
  end
  if self.pending_permission then
    local pending = self.pending_permission
    self.pending_permission = nil
    pending("deny")
  end
  for id, handle in pairs(self.active_tools or {}) do
    local ok = false
    if type(handle) == "table" then
      if handle.stop then ok = pcall(handle.stop) end
      if not ok and handle.kill then pcall(handle.kill) end
    end
    self:ui().tool_update(id, { status = "denied", detail = "cancelled" })
  end
  self.active_tools = {}
  if self.job then
    self.job.stop()
    self.job = nil
  end
  -- Drop any half-finished exchange so the transcript stays consistent:
  -- the last message must be a completed user or assistant message.
  local last = self.messages[#self.messages]
  if last and last.role == "assistant" then
    local has_tool = false
    for _, b in ipairs(last.content) do
      if b.type == "tool_use" then has_tool = true end
    end
    if has_tool then table.remove(self.messages) end
  end
  self:ui().notice("cancelled")
  self:_finish(true)
end

return M
