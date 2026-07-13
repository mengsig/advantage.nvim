local M = {}

M.defaults = {
  ---Default model, as `provider/model-id`.
  default_model = "anthropic/claude-opus-4-8",

  ---Models offered in the picker. `thinking = false` disables thinking on
  ---generations that support doing so. `context_window` is the
  ---model's total token budget; it scales auto-compaction (see `context`). Values
  ---marked "confirmed" are from the provider docs; the rest are a conservative
  ---floor (erring low is safe — too high risks compacting at ~100% of the real
  ---window). Adjust any to match your account/tier.
  models = {
    {
      ref = "anthropic/claude-opus-4-8",
      label = "opus 4.8",
      context_window = 1000000,
      max_output_tokens = 128000,
      thinking_mode = "adaptive",
      effort_levels = { "low", "medium", "high", "xhigh", "max" },
    }, -- confirmed 1M; manual thinking budgets are rejected
    {
      ref = "anthropic/claude-sonnet-5",
      label = "sonnet 5",
      context_window = 1000000,
      max_output_tokens = 128000,
      thinking_mode = "adaptive_default",
      effort_levels = { "low", "medium", "high", "xhigh", "max" },
    }, -- confirmed 1M; adaptive thinking is on by default
    {
      ref = "anthropic/claude-fable-5",
      label = "fable 5",
      context_window = 1000000,
      max_output_tokens = 128000,
      thinking_mode = "adaptive_always",
      effort_levels = { "low", "medium", "high", "xhigh", "max" },
    }, -- confirmed 1M; thinking cannot be disabled
    {
      ref = "anthropic/claude-haiku-4-5",
      label = "haiku 4.5",
      thinking = false,
      thinking_mode = "manual",
      context_window = 200000,
      max_output_tokens = 64000,
    }, -- confirmed 200k; legacy fixed-budget thinking
    {
      ref = "openai/gpt-5.6-sol",
      label = "gpt-5.6 sol",
      context_window = 372000,
      api_context_window = 1050000,
      max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh", "max" },
    }, -- Codex subscription window; raw API has 1.05M
    {
      ref = "openai/gpt-5.6-terra",
      label = "gpt-5.6 terra",
      context_window = 372000,
      api_context_window = 1050000,
      max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh", "max" },
    }, -- Codex subscription window; raw API has 1.05M
    {
      ref = "openai/gpt-5.6-luna",
      label = "gpt-5.6 luna",
      context_window = 372000,
      api_context_window = 1050000,
      max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh", "max" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh", "max" },
    }, -- Codex subscription window; raw API has 1.05M
    {
      ref = "openai/gpt-5.5",
      label = "gpt-5.5",
      context_window = 272000,
      api_context_window = 1050000,
      max_output_tokens = 128000,
      reasoning_efforts = { "low", "medium", "high", "xhigh" },
      api_reasoning_efforts = { "none", "low", "medium", "high", "xhigh" },
    }, -- Codex subscription window; raw API has 1.05M
    {
      ref = "openai/gpt-5.1-codex",
      label = "codex 5.1",
      context_window = 400000,
      max_output_tokens = 64000,
      reasoning_efforts = { "low", "medium", "high", "xhigh" },
    },
    {
      ref = "openai/gpt-5.1-codex-mini",
      label = "codex mini",
      context_window = 400000,
      max_output_tokens = 64000,
      reasoning_efforts = { "low", "medium", "high", "xhigh" },
    },
  },

  providers = {
    anthropic = {
      api_key_env = "ANTHROPIC_API_KEY",
      base_url = "https://api.anthropic.com",
      version = "2023-06-01",
      -- Thinking and visible text share this ceiling. Current adaptive models at
      -- xhigh/max are documented to need at least 64k for agentic tool loops.
      max_tokens = 64000,
      ---Send the interleaved-thinking beta (like the real CLI) so thinking
      ---persists across tool calls within a turn. Disable if your account
      ---rejects the beta.
      interleaved_thinking = true,
    },
    openai = {
      api_key_env = "OPENAI_API_KEY",
      base_url = "https://api.openai.com",
      ---auto prefers a Codex/ChatGPT login; pin api_key or chatgpt when both
      ---credentials exist and you need that transport's models/capabilities.
      auth_mode = "auto", -- "auto" | "chatgpt" | "api_key"
      -- Raw API requests are capped here. ChatGPT-login requests do not expose
      -- this request knob, so context budgeting reserves the model's native
      -- `max_output_tokens` instead (128k on GPT-5.6/5.5).
      max_output_tokens = 64000,
      -- Deepest wire-level reasoning default. Ultra lives in `harness.mode` and
      -- combines this Max parent effort with proactive parallel delegation.
      reasoning_effort = "max",
      ---Stream a short reasoning summary into the UI. Set false to reduce
      ---latency; scouts and summarizers disable it automatically because they
      ---discard thinking output.
      reasoning_summary = "auto", -- "auto" | "concise" | "detailed" | false
      ---Some subscription streams return a retryable overload/transport or
      ---explicit provider-advised failure inside HTTP 200 SSE. Retry only when
      ---no text/thinking/tool payload was delivered, so recovery can never
      ---duplicate visible work or tool calls.
      stream_error_retries = 2,
      stream_error_retry_base_ms = 2000,
    },
  },

  ---Override the built-in system prompt (string), or extend it (function(default) -> string).
  system_prompt = nil,

  ---Optional extension modules. Each module returns a setup(api) function (or a
  ---table with one) and can register tools, providers, harness modes, or a stable
  ---prompt part. Empty by default, so the baseline request/schema is unchanged.
  extensions = {},

  ---Safety cap on how many provider round-trips one user message may drive in the
  ---tool loop (edit→test→re-edit…). Prevents a thrashing/looping model from
  ---burning tokens unbounded, especially under yolo/auto_approve. On hit, the turn
  ---stops with a notice; sending another message resumes. Resets each user turn.
  max_agent_turns = 100,

  ui = {
    width = 0.42, -- fraction of columns
    input_height = 4,
    border = "rounded",
    accent = nil, -- hex like "#e0af68"; defaults to a color derived from your colorscheme
  },

  tools = {
    ---Tools that never prompt: read_file/list_dir/grep/find_files are always safe.
    ---Add e.g. `bash = true` at your own risk.
    auto_approve = {},
    ---File tools (and their permission previews) are confined to the project
    ---root: absolute paths and `..` traversal outside it are rejected. Set true
    ---to allow reading/writing anywhere the user can (bash is always gated).
    allow_outside_root = false,
    ---Skip ALL permission prompts (a.k.a. --dangerously-skip-permissions).
    ---Also toggleable at runtime with `/yolo` or `:Advantage yolo`.
    yolo = false,
    bash_timeout_ms = 120000,
    ---If true, bash stdout/stderr is streamed into the transcript as it arrives.
    ---Individual calls may also pass `{ stream = true }`.
    stream_bash_output = false,

    ---Editor-native diagnostic feedback loop. After the agent edits a file the
    ---NEWLY-introduced LSP/linter diagnostics are appended to that tool's result
    ---so the model can self-correct — bounded hard so it never bloats context:
    ---only `severity`+ is shown, capped at `max` lines, diffed against the
    ---pre-edit state (pre-existing problems aren't re-reported), and a clean edit
    ---adds nothing. The model also gets an explicit `diagnostics` tool.
    diagnostics = {
      enabled = true, -- false hides the diagnostics tool and disables auto-attach
      auto = true, -- append new diagnostics to edit results
      ---Severity floor for the auto-attach: "error" (default, least noise) or
      ---"warn" (errors + warnings). The explicit tool defaults to "warn".
      severity = "error",
      max = 10, -- cap on diagnostic lines appended per edit
      wait_ms = 1500, -- ceiling on how long to wait for the LSP to re-analyze
      attach_grace_ms = 250, -- how long to wait for a server to attach before giving up
      ---Deterministically notify YOU (once per filetype) when a file the agent
      ---edits has no language server attached — a nudge to install one so the
      ---feedback loop works. Persisted as a line in the chat transcript (so you
      ---won't miss it if you stepped away) plus a WARN toast. Set false to silence.
      notify_missing = true,
    },

    ---Editor-native LSP navigation tools (document_symbols, goto_definition,
    ---find_references, hover, workspace_symbol). These let the agent traverse
    ---code semantically — a few tokens per hop — instead of grepping and reading
    ---whole files, using the language servers your editor already runs. Read-only,
    ---so they never prompt and are available to sub-agents too. The whole set is
    ---hidden from the schema when `enabled = false` or this Neovim lacks vim.lsp.
    ---Needs a language server for the relevant filetype — see the README's list.
    lsp = {
      enabled = true,
      timeout_ms = 4000, -- per-request ceiling before a timeout (extended on retry)
      max_attempts = 2, -- auto-retry a TIMED-OUT request this many times: the first
      -- request to a freshly-opened file often times out while the server does its
      -- initial index; the retry (with an extended window) then returns instantly
      attach_grace_ms = 1000, -- wait this long for a server to attach when NONE is
      -- configured for the filetype (fail fast → the user is nudged to install one)
      attach_grace_configured_ms = 4000, -- but when a server IS configured for the
      -- filetype, wait this long for it to attach to a freshly-loaded buffer: heavy
      -- servers (tsserver/vtsls in a monorepo, jdtls, rust-analyzer) take seconds to
      -- come up, and a too-short wait reads as "no server" and abandons LSP wrongly
      max_results = 60, -- cap on symbols / references / matches returned per call
    },

    ---Optional external NavGraph semantic-navigation tool. Disabled by default
    ---so it does not change the baseline prompt/schema. When enabled and the
    ---configured executable exists, a conservative read-only command set is
    ---available to the parent and scouts. Calls use argv (never a shell), pin
    ---the index root to the project, force --no-cache, and reject external reads.
    ---Enabling the safe tool trusts and auto-runs this configured executable.
    navgraph = {
      enabled = false,
      ---A PATH command or an absolute executable path. Absolute paths make
      ---benchmarks and managed installations deterministic.
      executable = "navgraph",
      -- Exact-hash compatibility for the frozen 84986b8 benchmark binary,
      -- which predates `navgraph capabilities`. Disabled by default; unknown
      -- legacy builds fail closed even when explicitly enabled.
      allow_legacy_benchmark = false,
      timeout_ms = 30000, -- hard per-call ceiling (allowed range: 100..300000)
      max_results = 80, -- hard cap; discovery commands use smaller compact defaults
      max_output_bytes = 12000, -- final byte ceiling after result shaping (max: 1 MiB)
    },

    ---Web search. `auto` prefers the stable Brave JSON API when keyed, otherwise
    ---uses Brave's public HTML results as a best-effort fallback. Page retrieval
    ---is a separate hardened `web_fetch` tool below.
    web_search = {
      enabled = true,
      backend = "auto", -- "auto" | "brave_api" | "brave_html"
      allow_unkeyed = true,
      ---Env var read for the key. Set `api_key` directly instead if you'd rather
      ---not use an env var.
      api_key_env = "BRAVE_API_KEY",
      api_key = nil,
      base_url = "https://api.search.brave.com/res/v1/web/search",
      max_results = 5, -- default result count (hard cap: 10)
      timeout_ms = 15000,
      max_response_bytes = 1048576,
      fallback_url = "https://search.brave.com/search",
    },

    ---Static, GET-only public page retrieval for parent and sub-agent research.
    ---Every URL/redirect is DNS-validated and pinned; local/private networks,
    ---credentials, non-default ports, binaries, oversized bodies and HTTPS→HTTP
    ---downgrades are blocked. Returned page text is explicitly untrusted data.
    web_fetch = {
      enabled = true,
      timeout_ms = 20000,
      max_redirects = 3,
      max_response_bytes = 2097152,
      max_text_bytes = 64000,
      max_lines = 1000,
    },
  },

  context = {
    ---Automatically compact old conversation history before it grows too large.
    auto_compact = true,
    ---When to auto-compact, as a fraction of the active model's `context_window`
    ---(see `models`): 0.75 = compact once the transcript is estimated to fill ~75%
    ---of the window. Scales the trigger to the model, so a small window compacts
    ---before it overflows and a large one isn't compacted needlessly early.
    compact_fraction = 0.75,
    ---Absolute ceiling (tokens) on that trigger — a COST cap. Even on a 1M-context
    ---model you rarely want to carry 0.75 × 1M ≈ 750k tokens every turn: it's
    ---expensive and overflows the cheap summarizer. Effective threshold =
    ---the minimum of this cap, the window fraction, and the remaining request
    ---envelope after output/system/tools/safety reservations. Lower it for
    ---cheaper turns; raise it to exploit a big window. (Token estimate is chars/4;
    ---falls back to this value alone when a model declares no context_window.)
    compact_at_tokens = 200000,
    ---Extra room for provider framing and estimation error. The automatic
    ---trigger also subtracts the actual system/tool-schema estimate and the
    ---active model's requested output allowance from the context window.
    request_safety_tokens = 8192,
    ---Keep the newest messages verbatim; older messages become a summary. Bounded
    ---by BOTH this count and a token budget (`keep_recent_fraction`), whichever is
    ---tighter, so a few huge tool outputs can't retain more than the threshold.
    keep_recent_messages = 16,
    ---Token budget for that retained recent window, as a fraction of the resolved
    ---threshold (held under it so compaction can always get the transcript below
    ---the threshold rather than re-triggering every turn).
    keep_recent_fraction = 0.4,
    ---Maximum characters in the generated compaction summary.
    summary_max_chars = 12000,
    ---Mode for silent auto-compaction (crossing compact_at_tokens mid-turn):
    ---"heuristic" keeps the old free/offline behavior; "llm" spends one
    ---summarizer call when the threshold is crossed. Defaults to heuristic to
    ---avoid surprise token/API usage unless explicitly opted in.
    auto_compact_mode = "heuristic",
    ---Mode for manual/forced compaction (`/compact`, `:Advantage compact`):
    ---"llm" spends one call on `summarizer_model` for a real, semantically
    ---prioritized summary; "heuristic" stays free/offline.
    ---Override per-invocation with `/compact llm` or `/compact heuristic`.
    compact_mode = "llm",
    ---Model that performs the LLM summarization call, as "provider/model-id".
    ---May be kept separate from the active chat model when compaction latency or
    ---cost matters. `nil` (default) checks the ACTIVE provider's
    ---`context.summarizer_models` entry, then uses the active model itself. Thus a
    ---Codex/OpenAI-only user never triggers a Claude request they lack credentials
    ---for (and vice-versa). Set a ref to pin one model regardless of provider.
    summarizer_model = nil,
    ---Per-provider summarizer used when `summarizer_model` is nil. Falls back to
    ---the active chat model itself if the provider isn't listed here.
    summarizer_models = {
      anthropic = "anthropic/claude-haiku-4-5",
    },
    ---OpenAI reasoning effort for the isolated summary request. Medium is a
    ---deliberate compression-quality/latency default; set `"inherit"` when a
    ---summary must match the live agent's effort exactly.
    summarizer_effort = "medium",
  },

  subagents = {
    ---Expose the read-only `sub_agent` tool for delegation / fan-out.
    enabled = true,
    ---Preferred sub-agent alias shown to the parent (for example "sol" or
    ---"haiku"). The parent must still name a model on every call; this guides
    ---that explicit choice without making the harness silently select one.
    model = nil,
    ---Stable, model-facing aliases for scout selection. The parent chooses one
    ---explicitly on every call, while versioned provider IDs remain centralized
    ---here so the model never has to guess a fragile slug. Update the target when
    ---a newer family member becomes the configured default.
    model_aliases = {
      sol = "openai/gpt-5.6-sol",
      terra = "openai/gpt-5.6-terra",
      luna = "openai/gpt-5.6-luna",
      opus = "anthropic/claude-opus-4-8",
      sonnet = "anthropic/claude-sonnet-5",
      haiku = "anthropic/claude-haiku-4-5",
    },
    ---Keep scout routing in the active parent's provider family by default.
    ---An OpenAI/Codex parent therefore sees sol/terra/luna, while an Anthropic
    ---parent sees opus/sonnet/haiku. Cross-provider orchestration remains an
    ---explicit user choice instead of a model-selected surprise.
    allow_cross_provider = false,
    ---Default provider turns a sub-agent may take, including tool loops.
    ---The last turn is always report-only (tools withheld), so a fan-out scout
    ---investigating a whole subsystem always returns a real report instead of an
    ---empty "hit the turn limit" error; budget for the investigation accordingly.
    max_turns = 6,
    ---User-controlled ceiling for a model-supplied `max_turns`. This bounds one
    ---worker's loop, not scout admission: the parent may still spawn any number
    ---of workers and excess concurrent work still queues.
    max_turns_cap = 12,
    ---Visible output ceiling for scout requests on transports that accept one
    ---(Anthropic and raw OpenAI API). ChatGPT login has no confirmed hard-cap
    ---field, so it retains the native reserve and is bounded by the scout's turn,
    ---result, and report limits instead.
    max_output_tokens = 16000,
    ---Preferred scout effort shown to the parent. Every call must still name
    ---its effort explicitly; this guides intent without a silent fallback.
    effort = "medium",
    ---Run a fan-out batch of `sub_agent` calls concurrently (overlapping their
    ---network latency) instead of one-at-a-time. This controls scheduling, not
    ---admission: every valid scout requested by the parent runs, and excess work
    ---waits in the local queue. Mutating/permissioned tools still run in order.
    parallel = true,
    max_parallel = 4, -- concurrent provider streams; excess scouts queue (never reject)
    max_result_bytes = 64000, -- aggregate parent-context budget for a fan-out
    ---Hard watchdog for each read-only tool invoked inside a scout. Individual
    ---tools normally finish sooner; this catches a broken callback/process so
    ---one worker cannot hold its provider turn and the parent queue forever.
    tool_timeout_ms = 45000,
  },

  harness = {
    ---Orchestration policy. `auto` derives it from the active effort; explicit
    ---modes remain independent after their initial effort synchronization.
    mode = "auto", -- "auto" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
    ---Selecting a harness preset also initializes model effort to its matching
    ---level. `/effort` can then override reasoning without changing the harness.
    sync_effort = true,
  },

  ---Per-repo self-learning harness: the agent records durable facts about a repo
  ---as it works (rendered into the cached system prefix, so ~free after turn one),
  ---and stores reusable named "skills" whose bodies load on demand. Deterministic
  ---and offline — no embeddings, no validator model. Files live under `<root>/.advantage/`.
  memory = {
    enabled = true,
    ---Opt in to skills whose `advantage-harness` frontmatter changes the live
    ---orchestration mode when loaded. Off by default: reusable instructions are
    ---safe to share across harnesses without silently changing cost/behavior.
    allow_skill_harness = false,
    ---Rough token cap (chars/4) for the always-loaded learned-facts block. It
    ---rides the cached system prefix (billed ~10% after turn one), so this is a
    ---recurring per-turn tax — keep it lean. Oldest facts are evicted past it. The
    ---always-loaded tier is for CRISP signposts; depth belongs in on-demand skills
    ---(one index line until loaded), so raising this is rarely the right lever —
    ---curate depth into skills instead (`/context curate`).
    budget_tokens = 2000,
    ---Maximum on-demand skill body injected into a turn (tokens; hard-capped).
    skill_body_budget_tokens = 8000,
    ---Token cap on the always-loaded SKILLS INDEX (one line per skill). Skills past
    ---the cap stay fully available — loadable by name with `use_skill` and still
    ---keyword-hinted — but drop off the always-visible list, so a large skill
    ---library never re-bloats the cached prefix. Truncation is deterministic
    ---(alphabetical) to preserve prompt-cache stability.
    skills_index_budget_tokens = 1200,
    ---Token cap for ingested project memory (AGENTS.md / CLAUDE.md).
    project_budget_tokens = 2000,
    ---Token cap (per file) for user-authored config docs: any `.advantage/<name>.md`
    ---(except the learned-facts file `context.md`) is injected verbatim into the
    ---cached system prefix, so a repo can make the agent's standing instructions
    ---configurable by dropping a markdown file in place. Rides the cache like the
    ---rest of memory (~10% after turn one); keep each doc lean.
    config_budget_tokens = 2000,
    ---Word-overlap ratio above which a new fact counts as a duplicate.
    dedupe_threshold = 0.8,
  },

  keymaps = {
    toggle = "<leader>cc",
    new_session = "<leader>cn",
    models = "<leader>cm",
    resume = "<leader>cr",
    add_selection = "<leader>cs", -- visual mode: @file:L10-20 mention
    add_file = "<leader>cf", -- send current file to the chat prompt
    add_location = "<leader>cl", -- send @file:L{cursor line}
    pick_files = "<leader>cp", -- pick a project file to send
    context_preview = "<leader>cP", -- preview the exact context packet (system + tools + transcript)
    usage = "<leader>cu", -- token usage dashboard
    review = "<leader>cd", -- review the agent's file changes (diff)
    yolo = "<leader>cy", -- toggle skip-all-permissions mode
    effort = "<leader>ce", -- tune reasoning effort / thinking
    harness = "<leader>ch", -- tune harness orchestration policy
    help = "<leader>c?", -- keybind & command cheatsheet
  },

  usage = {
    ---Tokens/day; enables "runs out at ~HH:MM" projections in the /usage dashboard.
    daily_budget = nil,
  },

  sessions = {
    autosave = true,
  },
}

M.options = vim.deepcopy(M.defaults)
M._setup_done = false

-- Deep-merge that treats *sequences* (list-like tables) as atomic values rather
-- than merging them element-wise by index. vim.tbl_deep_extend would otherwise
-- splice a user's `models` list into the defaults, leaving stale leftover entries.
local function merge(dst, src)
  if type(dst) ~= "table" or type(src) ~= "table" then return src end
  if src[1] ~= nil or dst[1] ~= nil then return vim.deepcopy(src) end
  local out = vim.deepcopy(dst)
  for k, v in pairs(src) do
    out[k] = merge(out[k], v)
  end
  return out
end

local function validate(o)
  local errs = {}
  if type(o.default_model) ~= "string" or not o.default_model:match("^[^/]+/.+$") then
    errs[#errs + 1] = "default_model must be a 'provider/model-id' string"
  end
  if type(o.models) ~= "table" or o.models[1] == nil then
    errs[#errs + 1] = "models must be a non-empty list of { ref = 'provider/model-id' } entries"
  else
    for i, m in ipairs(o.models) do
      if type(m) ~= "table" or type(m.ref) ~= "string" or not m.ref:match("^[^/]+/.+$") then
        errs[#errs + 1] = ("models[%d].ref must be a 'provider/model-id' string"):format(i)
      end
      if type(m) == "table" then
        for _, field in ipairs({ "reasoning_efforts", "api_reasoning_efforts", "effort_levels" }) do
          if m[field] ~= nil and type(m[field]) ~= "table" then
            errs[#errs + 1] = ("models[%d].%s must be a list"):format(i, field)
          elseif type(m[field]) == "table" then
            for j, value in ipairs(m[field]) do
              if type(value) ~= "string" then
                errs[#errs + 1] = ("models[%d].%s[%d] must be a string"):format(i, field, j)
              end
            end
          end
        end
        for _, field in ipairs({ "context_window", "api_context_window", "max_output_tokens" }) do
          if m[field] ~= nil and (type(m[field]) ~= "number" or m[field] <= 0) then
            errs[#errs + 1] = ("models[%d].%s must be positive"):format(i, field)
          end
        end
        if
          m.thinking_mode ~= nil
          and not vim.tbl_contains({ "adaptive", "adaptive_default", "adaptive_always", "manual" }, m.thinking_mode)
        then
          errs[#errs + 1] = ("models[%d].thinking_mode is not recognized"):format(i)
        end
      end
    end
  end
  if
    type(o.ui) == "table"
    and o.ui.width ~= nil
    and (type(o.ui.width) ~= "number" or o.ui.width <= 0 or o.ui.width > 1)
  then
    errs[#errs + 1] = "ui.width must be a number in (0, 1] (fraction of columns)"
  end
  if type(o.providers) ~= "table" then
    errs[#errs + 1] = "providers must be a table"
  else
    for _, name in ipairs({ "anthropic", "openai" }) do
      if o.providers[name] ~= nil and type(o.providers[name]) ~= "table" then
        errs[#errs + 1] = "providers." .. name .. " must be a table"
      end
    end
  end
  if type(o.providers) == "table" and type(o.providers.openai) == "table" then
    local p = o.providers.openai
    if p.auth_mode ~= nil and not vim.tbl_contains({ "auto", "chatgpt", "api_key" }, p.auth_mode) then
      errs[#errs + 1] = "providers.openai.auth_mode must be 'auto', 'chatgpt', or 'api_key'"
    end
    if
      p.reasoning_summary ~= nil
      and p.reasoning_summary ~= false
      and not vim.tbl_contains({ "auto", "concise", "detailed" }, p.reasoning_summary)
    then
      errs[#errs + 1] = "providers.openai.reasoning_summary must be 'auto', 'concise', 'detailed', or false"
    end
    if
      p.reasoning_effort ~= nil
      and not vim.tbl_contains(
        { "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" },
        p.reasoning_effort
      )
    then
      errs[#errs + 1] = "providers.openai.reasoning_effort is not a recognized effort"
    end
    if p.max_output_tokens ~= nil and (type(p.max_output_tokens) ~= "number" or p.max_output_tokens <= 0) then
      errs[#errs + 1] = "providers.openai.max_output_tokens must be positive"
    end
    if
      p.stream_error_retries ~= nil
      and (
        type(p.stream_error_retries) ~= "number"
        or p.stream_error_retries < 0
        or p.stream_error_retries ~= math.floor(p.stream_error_retries)
      )
    then
      errs[#errs + 1] = "providers.openai.stream_error_retries must be a non-negative integer"
    end
    if
      p.stream_error_retry_base_ms ~= nil
      and (
        type(p.stream_error_retry_base_ms) ~= "number"
        or p.stream_error_retry_base_ms < 0
        or p.stream_error_retry_base_ms ~= math.floor(p.stream_error_retry_base_ms)
      )
    then
      errs[#errs + 1] = "providers.openai.stream_error_retry_base_ms must be a non-negative integer"
    end
  end
  if type(o.providers) == "table" and type(o.providers.anthropic) == "table" then
    local p = o.providers.anthropic
    if p.max_tokens ~= nil and (type(p.max_tokens) ~= "number" or p.max_tokens <= 0) then
      errs[#errs + 1] = "providers.anthropic.max_tokens must be positive"
    end
  end
  for _, key in ipairs({ "tools", "context", "ui", "memory", "subagents", "harness", "sessions" }) do
    if o[key] ~= nil and type(o[key]) ~= "table" then errs[#errs + 1] = key .. " must be a table" end
  end
  if type(o.context) == "table" then
    for _, field in ipairs({ "compact_mode", "auto_compact_mode" }) do
      local mode = o.context[field]
      if mode ~= nil and mode ~= "llm" and mode ~= "heuristic" then
        errs[#errs + 1] = "context." .. field .. " must be 'llm' or 'heuristic'"
      end
    end
    for _, field in ipairs({ "compact_fraction", "keep_recent_fraction" }) do
      local frac = o.context[field]
      if frac ~= nil and (type(frac) ~= "number" or frac <= 0 or frac > 1) then
        errs[#errs + 1] = "context." .. field .. " must be a number in (0, 1]"
      end
    end
    if
      o.context.request_safety_tokens ~= nil
      and (type(o.context.request_safety_tokens) ~= "number" or o.context.request_safety_tokens < 0)
    then
      errs[#errs + 1] = "context.request_safety_tokens must be a non-negative number"
    end
    if
      o.context.summarizer_effort ~= nil
      and not vim.tbl_contains(
        { "inherit", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" },
        o.context.summarizer_effort
      )
    then
      errs[#errs + 1] = "context.summarizer_effort is not a recognized OpenAI effort (or 'inherit')"
    end
    if
      o.context.summarizer_model ~= nil
      and (type(o.context.summarizer_model) ~= "string" or not o.context.summarizer_model:match("^[^/]+/.+$"))
    then
      errs[#errs + 1] = "context.summarizer_model must be a 'provider/model-id' string or nil"
    end
    if o.context.summarizer_models ~= nil and type(o.context.summarizer_models) ~= "table" then
      errs[#errs + 1] = "context.summarizer_models must be a provider-to-model table"
    elseif type(o.context.summarizer_models) == "table" then
      for provider, ref in pairs(o.context.summarizer_models) do
        if type(provider) ~= "string" or type(ref) ~= "string" or not ref:match("^[^/]+/.+$") then
          errs[#errs + 1] = "context.summarizer_models entries must be 'provider/model-id' strings"
          break
        end
      end
    end
  end
  if o.max_agent_turns ~= nil and (type(o.max_agent_turns) ~= "number" or o.max_agent_turns < 0) then
    errs[#errs + 1] = "max_agent_turns must be a non-negative number"
  end
  if type(o.subagents) == "table" then
    local s = o.subagents
    if s.effort ~= nil and type(s.effort) ~= "string" then errs[#errs + 1] = "subagents.effort must be a string" end
    if s.model_aliases ~= nil and type(s.model_aliases) ~= "table" then
      errs[#errs + 1] = "subagents.model_aliases must be an alias-to-model table"
    elseif type(s.model_aliases) == "table" then
      local configured_refs = {}
      for _, model in ipairs(o.models or {}) do
        if type(model) == "table" and type(model.ref) == "string" then configured_refs[model.ref] = true end
      end
      for alias, ref in pairs(s.model_aliases) do
        if
          type(alias) ~= "string"
          or not alias:match("^[%l%d_-]+$")
          or type(ref) ~= "string"
          or not ref:match("^[^/]+/.+$")
        then
          errs[#errs + 1] = "subagents.model_aliases entries must map simple aliases to provider/model-id"
          break
        elseif not configured_refs[ref] then
          errs[#errs + 1] = ("subagents.model_aliases.%s targets %s, which is absent from models"):format(alias, ref)
        end
      end
    end
    if s.model ~= nil then
      if type(s.model) ~= "string" or vim.trim(s.model) == "" then
        errs[#errs + 1] = "subagents.model must be a non-empty model alias"
      elseif type(s.model_aliases) ~= "table" or s.model_aliases[vim.trim(s.model)] == nil then
        errs[#errs + 1] = "subagents.model must name a key from subagents.model_aliases"
      end
    end
    for _, field in ipairs({ "enabled", "parallel", "allow_cross_provider" }) do
      if s[field] ~= nil and type(s[field]) ~= "boolean" then
        errs[#errs + 1] = "subagents." .. field .. " must be boolean"
      end
    end
    for _, field in ipairs({
      "max_turns",
      "max_turns_cap",
      "max_output_tokens",
      "max_parallel",
      "max_result_bytes",
      "tool_timeout_ms",
    }) do
      local value = s[field]
      if value ~= nil and (type(value) ~= "number" or value < 1 or value ~= math.floor(value)) then
        errs[#errs + 1] = "subagents." .. field .. " must be a positive integer"
      end
    end
    if type(s.max_turns_cap) == "number" and s.max_turns_cap > 30 then
      errs[#errs + 1] = "subagents.max_turns_cap must be at most 30"
    end
    if type(s.max_turns) == "number" and type(s.max_turns_cap) == "number" and s.max_turns > s.max_turns_cap then
      errs[#errs + 1] = "subagents.max_turns must not exceed subagents.max_turns_cap"
    end
  end
  if type(o.harness) == "table" then
    if o.harness.mode ~= nil and not require("advantage.harness").valid(o.harness.mode) then
      errs[#errs + 1] = "harness.mode is not recognized"
    end
    if o.harness.sync_effort ~= nil and type(o.harness.sync_effort) ~= "boolean" then
      errs[#errs + 1] = "harness.sync_effort must be boolean"
    end
  end
  if
    type(o.memory) == "table"
    and o.memory.allow_skill_harness ~= nil
    and type(o.memory.allow_skill_harness) ~= "boolean"
  then
    errs[#errs + 1] = "memory.allow_skill_harness must be boolean"
  end
  if type(o.tools) == "table" and type(o.tools.diagnostics) == "table" then
    local sev = o.tools.diagnostics.severity
    if sev ~= nil and sev ~= "error" and sev ~= "warn" and sev ~= "all" then
      errs[#errs + 1] = "tools.diagnostics.severity must be 'error', 'warn', or 'all'"
    end
  end
  if type(o.tools) == "table" then
    local navgraph = o.tools.navgraph
    if navgraph ~= nil and type(navgraph) ~= "table" then
      errs[#errs + 1] = "tools.navgraph must be a table"
    elseif type(navgraph) == "table" then
      if navgraph.enabled ~= nil and type(navgraph.enabled) ~= "boolean" then
        errs[#errs + 1] = "tools.navgraph.enabled must be boolean"
      end
      if navgraph.allow_legacy_benchmark ~= nil and type(navgraph.allow_legacy_benchmark) ~= "boolean" then
        errs[#errs + 1] = "tools.navgraph.allow_legacy_benchmark must be boolean"
      end
      if
        navgraph.executable ~= nil
        and (
          type(navgraph.executable) ~= "string"
          or vim.trim(navgraph.executable) == ""
          or vim.trim(navgraph.executable) ~= navgraph.executable
          or (
            navgraph.executable:find("[/\\]")
            and not navgraph.executable:match("^/")
            and not navgraph.executable:match("^%a:[/\\]")
          )
        )
      then
        errs[#errs + 1] = "tools.navgraph.executable must be a PATH command or absolute executable path"
      end
      local timeout = navgraph.timeout_ms
      if
        timeout ~= nil
        and (type(timeout) ~= "number" or timeout ~= math.floor(timeout) or timeout < 100 or timeout > 300000)
      then
        errs[#errs + 1] = "tools.navgraph.timeout_ms must be an integer from 100 to 300000"
      end
      local results = navgraph.max_results
      if
        results ~= nil
        and (type(results) ~= "number" or results ~= math.floor(results) or results < 1 or results > 200)
      then
        errs[#errs + 1] = "tools.navgraph.max_results must be an integer from 1 to 200"
      end
      local output = navgraph.max_output_bytes
      if
        output ~= nil
        and (type(output) ~= "number" or output ~= math.floor(output) or output < 256 or output > 1048576)
      then
        errs[#errs + 1] = "tools.navgraph.max_output_bytes must be an integer from 256 to 1048576"
      end
    end
    local search = o.tools.web_search
    if search ~= nil and type(search) ~= "table" then
      errs[#errs + 1] = "tools.web_search must be a table"
    elseif type(search) == "table" then
      if search.backend ~= nil and not vim.tbl_contains({ "auto", "brave_api", "brave_html" }, search.backend) then
        errs[#errs + 1] = "tools.web_search.backend must be 'auto', 'brave_api', or 'brave_html'"
      end
      if search.allow_unkeyed ~= nil and type(search.allow_unkeyed) ~= "boolean" then
        errs[#errs + 1] = "tools.web_search.allow_unkeyed must be boolean"
      end
      for _, field in ipairs({ "max_results", "timeout_ms", "max_response_bytes" }) do
        if search[field] ~= nil and (type(search[field]) ~= "number" or search[field] < 1) then
          errs[#errs + 1] = "tools.web_search." .. field .. " must be positive"
        end
      end
    end
    local fetch = o.tools.web_fetch
    if fetch ~= nil and type(fetch) ~= "table" then
      errs[#errs + 1] = "tools.web_fetch must be a table"
    elseif type(fetch) == "table" then
      if fetch.max_redirects ~= nil and (type(fetch.max_redirects) ~= "number" or fetch.max_redirects < 0) then
        errs[#errs + 1] = "tools.web_fetch.max_redirects must be non-negative"
      end
      for _, field in ipairs({ "timeout_ms", "max_response_bytes", "max_text_bytes", "max_lines" }) do
        if fetch[field] ~= nil and (type(fetch[field]) ~= "number" or fetch[field] < 1) then
          errs[#errs + 1] = "tools.web_fetch." .. field .. " must be positive"
        end
      end
    end
  end
  return errs
end

M._validate = validate

function M.setup(opts)
  opts = opts or {}
  M.options = merge(vim.deepcopy(M.defaults), opts)
  -- Replacing the model catalogue wholesale must not leave six inherited scout
  -- aliases pointing at models that no longer exist. Keep only surviving
  -- defaults unless the user supplied an explicit alias catalogue alongside
  -- their custom models.
  if
    opts.models ~= nil
    and type(M.options.models) == "table"
    and not (type(opts.subagents) == "table" and opts.subagents.model_aliases ~= nil)
  then
    local refs = {}
    for _, model in ipairs(M.options.models) do
      if type(model) == "table" and type(model.ref) == "string" then refs[model.ref] = true end
    end
    local aliases = ((M.options.subagents or {}).model_aliases or {})
    for alias, ref in pairs(aliases) do
      if not refs[ref] then aliases[alias] = nil end
    end
    if M.options.subagents and M.options.subagents.model and not aliases[M.options.subagents.model] then
      M.options.subagents.model = nil
    end
  end
  local errs = require("advantage.extensions").load(M.options.extensions)
  vim.list_extend(errs, validate(M.options))
  -- Structural options must be tables; revert any scalar override (e.g. a
  -- mistaken `tools = false`) to its default so it can't crash a later
  -- `config.options.tools.x` access. The mistake is still surfaced via `errs`.
  for _, key in ipairs({
    "tools",
    "context",
    "ui",
    "providers",
    "memory",
    "subagents",
    "harness",
    "sessions",
    "keymaps",
    "usage",
  }) do
    if M.options[key] ~= nil and type(M.options[key]) ~= "table" then
      M.options[key] = vim.deepcopy(M.defaults[key] --[[@as table]])
    end
  end
  -- Recover malformed nested provider overrides too. A setup such as
  -- `providers = { openai = false }` should produce a useful validation error,
  -- not leave later request code indexing a boolean.
  for _, name in ipairs({ "anthropic", "openai" }) do
    if type(M.options.providers[name]) ~= "table" then
      M.options.providers[name] = vim.deepcopy(M.defaults.providers[name])
    end
  end
  if type(M.options.tools.navgraph) ~= "table" then
    M.options.tools.navgraph = vim.deepcopy(M.defaults.tools.navgraph)
  end
  if type(M.options.context.summarizer_models) ~= "table" then
    M.options.context.summarizer_models = vim.deepcopy(M.defaults.context.summarizer_models)
  end
  -- accept the long-form alias for the paranoid-averse
  if M.options.tools.dangerously_skip_permissions then M.options.tools.yolo = true end
  if #errs > 0 then
    vim.schedule(function()
      vim.notify("advantage: invalid setup options —\n  " .. table.concat(errs, "\n  "), vim.log.levels.ERROR)
    end)
  end
  M._setup_done = true
end

---Resolve a `provider/model` ref into a live model with capability metadata.
function M.resolve_model(ref)
  for _, m in ipairs(M.options.models) do
    if m.ref == ref then
      local provider, id = ref:match("^([^/]+)/(.+)$")
      return {
        provider = provider,
        id = id,
        label = m.label or id,
        thinking = m.thinking,
        default_thinking = vim.deepcopy(m.thinking),
        thinking_budget = m.thinking_budget,
        thinking_mode = m.thinking_mode,
        effort = m.effort,
        effort_levels = vim.deepcopy(m.effort_levels),
        reasoning_effort = m.reasoning_effort,
        reasoning_efforts = vim.deepcopy(m.reasoning_efforts),
        context_window = m.context_window,
        api_context_window = m.api_context_window,
        max_output_tokens = m.max_output_tokens,
        api_reasoning_efforts = vim.deepcopy(m.api_reasoning_efforts),
      }
    end
  end
  local provider, id = ref:match("^([^/]+)/(.+)$")
  if provider then return { provider = provider, id = id, label = id } end
  return nil
end

local SUBAGENT_ALIAS_ORDER = { "sol", "terra", "luna", "opus", "sonnet", "haiku" }

local function configured_model(ref)
  if type(ref) ~= "string" then return nil end
  for _, model in ipairs(M.options.models or {}) do
    if model.ref == ref then return M.resolve_model(ref) end
  end
end

---Stable aliases exposed to the parent model for one-shot scout selection.
---Only aliases whose target is actually present in `models` are advertised.
---@return table[] choices ordered `{ alias, ref }` records
function M.subagent_model_aliases()
  local aliases = ((M.options.subagents or {}).model_aliases or {})
  local ordered, seen = {}, {}
  local function add(alias)
    local ref = aliases[alias]
    if type(ref) == "string" and configured_model(ref) then
      ordered[#ordered + 1] = { alias = alias, ref = ref }
      seen[alias] = true
    end
  end
  for _, alias in ipairs(SUBAGENT_ALIAS_ORDER) do
    add(alias)
  end
  local extras = {}
  for alias in pairs(aliases) do
    if not seen[alias] then extras[#extras + 1] = alias end
  end
  table.sort(extras)
  for _, alias in ipairs(extras) do
    add(alias)
  end
  return ordered
end

---Resolve an explicit scout model choice. Short aliases are preferred; exact
---configured refs and unique configured bare IDs remain accepted for migration.
---First-party OpenAI/Anthropic slugs must be configured, preventing plausible-
---looking hallucinations from reaching the network.
---@param choice string
---@return table|nil model
---@return string|nil resolved_ref
function M.resolve_subagent_model(choice)
  if type(choice) ~= "string" then return nil end
  choice = vim.trim(choice)
  if choice == "" then return nil end
  for _, item in ipairs(M.subagent_model_aliases()) do
    if choice == item.alias then return configured_model(item.ref), item.ref end
  end
  local provider = choice:match("^([^/]+)/")
  -- First-party scouts intentionally use aliases only. Even a configured legacy
  -- ref can be incompatible with the current subscription transport; keeping it
  -- out of this resolver prevents the parent from falling back to stale IDs.
  if provider == "openai" or provider == "anthropic" or not provider then return nil end
  -- Third-party provider plugins do not necessarily participate in the built-in
  -- alias catalogue, so retain their explicit provider/model escape hatch.
  return M.resolve_model(choice), choice
end

---Context window for the transport that OpenAI is expected to use. Subscription
---and raw API catalogs can expose materially different windows for the same ID.
function M.effective_context_window(model)
  if model and model.provider == "openai" and model.api_context_window then
    local ok, mode = pcall(function()
      return require("advantage.auth").openai_mode_hint()
    end)
    if ok and mode == "api_key" then return model.api_context_window end
  end
  return model and model.context_window or nil
end

---Output allowance for the selected transport. Raw OpenAI API calls send the
---configured request cap, tightened by the model maximum. The ChatGPT/Codex
---backend has no equivalent request field, so budgeting must reserve the native
---model maximum instead or a 128k completion can overflow a context calculation
---that only held 64k aside.
---@param model table|nil
---@param provider_name? string
---@param transport? "chatgpt"|"api_key"
function M.effective_max_output_tokens(model, provider_name, transport)
  provider_name = provider_name or (model and model.provider)
  local pcfg = provider_name and M.options.providers[provider_name] or nil
  local configured = pcfg and (provider_name == "anthropic" and pcfg.max_tokens or pcfg.max_output_tokens) or nil
  local model_cap = model and model.max_output_tokens or nil
  if provider_name == "openai" then
    if transport == nil then
      local ok, mode = pcall(function()
        return require("advantage.auth").openai_mode_hint()
      end)
      transport = ok and mode or "chatgpt"
    end
    if transport == "chatgpt" then return model_cap or configured end
  end
  if type(configured) == "number" and type(model_cap) == "number" then return math.min(configured, model_cap) end
  return configured or model_cap
end

---Context-envelope reserve for a forthcoming request. Kept as a named helper
---because a transport's native completion allowance is not always the same as
---the hard cap placed on raw API requests.
function M.request_output_reserve_tokens(model, transport)
  return M.effective_max_output_tokens(model, model and model.provider, transport)
end

function M.api_key(provider_name)
  local pcfg = M.options.providers[provider_name]
  if not pcfg then return nil end
  if pcfg.api_key then return pcfg.api_key end
  local key = vim.env[pcfg.api_key_env or ""]
  if key and key ~= "" then return key end
  return nil
end

return M
