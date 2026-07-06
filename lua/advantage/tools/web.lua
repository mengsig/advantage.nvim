---@brief Web tool: web_search (Brave Search). Registered by tools/init.lua;
---behaviour is identical to when it lived inline in that file.
local util = require("advantage.util")

---Brave descriptions/titles carry <strong> highlight tags and HTML entities;
---strip both so a result reads as plain text in the transcript.
local function strip_html(str)
  str = (str or ""):gsub("<[^>]->", "")
  str = str:gsub("&quot;", '"'):gsub("&#0?39;", "'"):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  return vim.trim(str:gsub("%s+", " "))
end

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "web tools: tool registrar required")
  assert(type(s) == "table" and s.web_search_key, "web tools: support module required")
  local web_search_key = s.web_search_key

  tool({
    name = "web_search",
    safe = true,
    feature = "web_search",
    description = "Search the web (Brave Search) and return compact title/url/snippet results. Use for anything outside the repo: library docs, error messages, current events, API references.",
    input_schema = {
      type = "object",
      properties = {
        query = { type = "string", description = "Search query" },
        count = { type = "integer", description = "Max results to return (default from config, capped at 10)" },
      },
      required = { "query" },
    },
    summary = function(input)
      return input.query or ""
    end,
    run = function(input, ctx, cb)
      local cfg = (require("advantage.config").options.tools or {}).web_search or {}
      local key = web_search_key(cfg)
      if not key then
        return cb(
          ("web_search is not configured: set $%s (or tools.web_search.api_key)."):format(
            cfg.api_key_env or "BRAVE_API_KEY"
          ),
          true
        )
      end
      local query = vim.trim(input.query or "")
      if query == "" then return cb("Empty query.", true) end
      local count = math.max(1, math.min(tonumber(input.count) or cfg.max_results or 5, 10))
      local timeout_ms = tonumber(cfg.timeout_ms) or 15000
      local cmd = {
        "curl",
        "-s",
        "-G",
        cfg.base_url or "https://api.search.brave.com/res/v1/web/search",
        "--data-urlencode",
        "q=" .. query,
        "--data-urlencode",
        "count=" .. tostring(count),
        "-H",
        "Accept: application/json",
        "-H",
        "X-Subscription-Token: " .. key,
        "--max-time",
        tostring(math.max(1, math.floor(timeout_ms / 1000))),
      }
      vim.system(cmd, { text = true, timeout = timeout_ms }, function(res)
        vim.schedule(function()
          if res.code ~= 0 then
            local reason = vim.trim(res.stderr or "")
            return cb("web_search request failed: " .. (reason ~= "" and reason or ("curl exit " .. res.code)), true)
          end
          local ok, decoded = pcall(vim.json.decode, res.stdout or "")
          if not ok or type(decoded) ~= "table" then return cb("web_search: could not parse response.", true) end
          if decoded.error then
            local e = decoded.error
            return cb(
              "web_search error: " .. (type(e) == "table" and (e.message or vim.inspect(e)) or tostring(e)),
              true
            )
          end
          local results = (decoded.web and decoded.web.results) or {}
          if #results == 0 then return cb("No results for: " .. query, false) end
          local lines = {}
          for i = 1, math.min(#results, count) do
            local r = results[i]
            lines[#lines + 1] = ("%d. %s — %s"):format(i, strip_html(r.title), r.url)
            local desc = strip_html(r.description)
            if desc ~= "" then
              if #desc > 240 then desc = util.utf8_safe_sub(desc, 240) .. "…" end
              lines[#lines + 1] = "   " .. desc
            end
          end
          cb(table.concat(lines, "\n"), false)
        end)
      end)
    end,
  })
end
