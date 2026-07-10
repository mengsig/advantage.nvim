---@brief Credential resolution. Subscription-first:
---  anthropic: Claude Code login (~/.claude/.credentials.json, auto-refreshed) → $ANTHROPIC_API_KEY
---  openai:    Codex CLI login (~/.codex/auth.json, auto-refreshed)            → $OPENAI_API_KEY
---No API key is required if you are logged in to the `claude` or `codex` CLI.
local M = {}

local uv = vim.uv or vim.loop

local ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local ANTHROPIC_TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
local OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local OPENAI_TOKEN_URL = "https://auth.openai.com/oauth/token"

local function claude_creds_path()
  return vim.fs.normalize(vim.env.CLAUDE_CONFIG_DIR or "~/.claude") .. "/.credentials.json"
end

local function codex_auth_path()
  return vim.fs.normalize(vim.env.CODEX_HOME or "~/.codex") .. "/auth.json"
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  -- luanil: JSON nulls become real nils, so `cred.field` checks are safe
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  return ok and type(decoded) == "table" and decoded or nil
end

local function write_json(path, tbl)
  -- Atomic write with an exclusive randomized temp at 0600: never follow a
  -- planted `.tmp` symlink, expose a rotated refresh token through the umask, or
  -- replace good credentials after a partial/full-disk write.
  local content = vim.json.encode(tbl)
  local tmp, fd
  for attempt = 1, 8 do
    tmp = ("%s.adv.%d.%x.tmp"):format(path, vim.fn.getpid(), (uv.hrtime() + attempt) % 0x7fffffff)
    fd = uv.fs_open(tmp, "wx", 384) -- 0600
    if fd then break end
  end
  if not fd then return false end
  local offset = 0
  while offset < #content do
    local wrote = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not wrote or wrote <= 0 then break end
    offset = offset + wrote
  end
  local synced = uv.fs_fsync(fd)
  uv.fs_close(fd)
  if offset ~= #content or not synced then
    os.remove(tmp)
    return false
  end
  local renamed = uv.fs_rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return false
  end
  return true
end

---Decode a JWT payload without verifying (we only need exp / account claims).
local function jwt_payload(token)
  if type(token) ~= "string" then return nil end
  local payload = token:match("^[^%.]+%.([^%.]+)%.")
  if not payload then return nil end
  payload = payload:gsub("-", "+"):gsub("_", "/")
  local pad = #payload % 4
  if pad > 0 then payload = payload .. string.rep("=", 4 - pad) end
  local ok, decoded = pcall(vim.base64.decode, payload)
  if not ok then return nil end
  local ok2, obj = pcall(vim.json.decode, decoded)
  return ok2 and obj or nil
end

---POST JSON, parse JSON. Body goes over stdin so secrets never hit the process list.
local function post_json(url, body, cb)
  vim.system(
    { "curl", "-sS", "--max-time", "30", "-H", "content-type: application/json", "--data-binary", "@-", url },
    { stdin = vim.json.encode(body), text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 then return cb(nil, "network error: " .. (res.stderr or res.code)) end
      local ok, decoded = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(decoded) ~= "table" then return cb(nil, "unexpected response from " .. url) end
      if decoded.error then
        local msg = type(decoded.error) == "table" and (decoded.error.message or decoded.error.error)
          or tostring(decoded.error)
        return cb(nil, msg)
      end
      cb(decoded)
    end)
  )
end

-- anthropic ---------------------------------------------------------------

local anthropic_refresh_waiters = nil
local function refresh_anthropic(oauth, cb)
  if anthropic_refresh_waiters then
    anthropic_refresh_waiters[#anthropic_refresh_waiters + 1] = cb
    return
  end
  anthropic_refresh_waiters = { cb }
  local function settle(value, err)
    local waiters = anthropic_refresh_waiters or {}
    anthropic_refresh_waiters = nil
    for _, waiter in ipairs(waiters) do
      waiter(value, err)
    end
  end
  post_json(ANTHROPIC_TOKEN_URL, {
    grant_type = "refresh_token",
    refresh_token = oauth.refreshToken,
    client_id = ANTHROPIC_CLIENT_ID,
  }, function(res, err)
    if not res or not res.access_token then
      return settle(nil, "Claude token refresh failed (" .. (err or "no token") .. "). Run `claude` and /login again.")
    end
    local updated = {
      accessToken = res.access_token,
      refreshToken = res.refresh_token or oauth.refreshToken,
      expiresAt = (os.time() + (res.expires_in or 3600)) * 1000,
      scopes = oauth.scopes,
      subscriptionType = oauth.subscriptionType,
    }
    -- Write back so Claude Code keeps working with the rotated refresh token.
    local path = claude_creds_path()
    local file = read_json(path) or {}
    file.claudeAiOauth = vim.tbl_extend("force", file.claudeAiOauth or {}, updated)
    if not write_json(path, file) then
      vim.schedule(function()
        vim.notify(
          "advantage: could not write refreshed Claude credentials to "
            .. path
            .. " — the `claude` CLI may need a re-login later.",
          vim.log.levels.WARN
        )
      end)
    end
    settle(updated)
  end)
end

---@param cb fun(cred: {mode:string, token?:string, key?:string, badge:string}|nil, err?:string)
---@param force boolean|nil force a token refresh even if the cached token looks valid (e.g. after a 401)
function M.anthropic(cb, force)
  local file = read_json(claude_creds_path())
  local oauth = file and file.claudeAiOauth
  if oauth and oauth.accessToken then
    local expires = (oauth.expiresAt or 0) / 1000
    if not force and expires > os.time() + 60 then
      return cb({ mode = "oauth", token = oauth.accessToken, badge = oauth.subscriptionType or "pro" })
    end
    if oauth.refreshToken then
      return refresh_anthropic(oauth, function(updated, err)
        if updated then
          cb({ mode = "oauth", token = updated.accessToken, badge = updated.subscriptionType or "pro" })
        else
          local key = require("advantage.config").api_key("anthropic")
          if key then
            cb({ mode = "api_key", key = key, badge = "api" })
          else
            cb(nil, err)
          end
        end
      end)
    end
  end
  local key = require("advantage.config").api_key("anthropic")
  if key then return cb({ mode = "api_key", key = key, badge = "api" }) end
  cb(nil, "No Claude credentials. Log in with the `claude` CLI (subscription) or export $ANTHROPIC_API_KEY.")
end

-- openai / codex ----------------------------------------------------------

local function codex_account_id(tokens)
  if tokens.account_id and tokens.account_id ~= vim.NIL then return tokens.account_id end
  local claims = jwt_payload(tokens.id_token)
  local auth_claim = claims and claims["https://api.openai.com/auth"]
  return auth_claim and auth_claim.chatgpt_account_id or nil
end

local codex_refresh_waiters = nil
local function refresh_codex(auth_file, cb)
  if codex_refresh_waiters then
    codex_refresh_waiters[#codex_refresh_waiters + 1] = cb
    return
  end
  codex_refresh_waiters = { cb }
  local function settle(value, err)
    local waiters = codex_refresh_waiters or {}
    codex_refresh_waiters = nil
    for _, waiter in ipairs(waiters) do
      waiter(value, err)
    end
  end
  local tokens = auth_file.tokens
  post_json(OPENAI_TOKEN_URL, {
    client_id = OPENAI_CLIENT_ID,
    grant_type = "refresh_token",
    refresh_token = tokens.refresh_token,
    scope = "openid profile email",
  }, function(res, err)
    if not res or not res.access_token then
      return settle(nil, "Codex token refresh failed (" .. (err or "no token") .. "). Run `codex login` again.")
    end
    auth_file.tokens.access_token = res.access_token
    auth_file.tokens.id_token = res.id_token or tokens.id_token
    auth_file.tokens.refresh_token = res.refresh_token or tokens.refresh_token
    auth_file.last_refresh = os.date("!%Y-%m-%dT%H:%M:%S.000Z")
    if not write_json(codex_auth_path(), auth_file) then
      vim.schedule(function()
        vim.notify(
          "advantage: could not write refreshed Codex credentials to "
            .. codex_auth_path()
            .. " — the `codex` CLI may need a re-login later.",
          vim.log.levels.WARN
        )
      end)
    end
    settle(auth_file.tokens)
  end)
end

---@param cb fun(cred: {mode:string, token?:string, key?:string, account_id?:string, badge:string}|nil, err?:string)
---@param force boolean|nil force a token refresh even if the cached token looks valid (e.g. after a 401)
function M.openai(cb, force)
  local pcfg = (require("advantage.config").options.providers or {}).openai or {}
  local requested_mode = pcfg.auth_mode or "auto"
  local auth_file = read_json(codex_auth_path())
  local tokens = auth_file and auth_file.tokens
  if requested_mode ~= "api_key" and tokens and tokens.access_token and tokens.access_token ~= vim.NIL then
    local account = codex_account_id(tokens)
    local claims = jwt_payload(tokens.access_token)
    local exp = claims and claims.exp or 0
    if not force and exp > os.time() + 60 and account then
      return cb({ mode = "chatgpt", token = tokens.access_token, account_id = account, badge = "chatgpt" })
    end
    if tokens.refresh_token then
      return refresh_codex(auth_file, function(updated, err)
        if updated then
          local acc = codex_account_id(updated)
          if acc then
            return cb({ mode = "chatgpt", token = updated.access_token, account_id = acc, badge = "chatgpt" })
          end
        end
        local key = require("advantage.config").api_key("openai")
        if key and requested_mode ~= "chatgpt" then
          cb({ mode = "api_key", key = key, badge = "api" })
        else
          cb(nil, err or "Codex login is missing an account id. Run `codex login` again.")
        end
      end)
    end
  end
  local key = (
    auth_file
    and auth_file.OPENAI_API_KEY
    and auth_file.OPENAI_API_KEY ~= vim.NIL
    and auth_file.OPENAI_API_KEY
  ) or require("advantage.config").api_key("openai")
  if key and requested_mode ~= "chatgpt" then return cb({ mode = "api_key", key = key, badge = "api" }) end
  if requested_mode == "api_key" then
    return cb(nil, "OpenAI auth_mode='api_key' but no API key was found in config or $OPENAI_API_KEY.")
  elseif requested_mode == "chatgpt" then
    return cb(nil, "OpenAI auth_mode='chatgpt' but no usable Codex login was found. Run `codex login` again.")
  end
  cb(nil, "No Codex credentials. Log in with `codex login` (subscription) or export $OPENAI_API_KEY.")
end

---Best synchronous prediction of which OpenAI transport `openai()` will use.
---Used only for model capability pickers and context-window budgeting; the real
---credential resolver remains authoritative at request time.
function M.openai_mode_hint()
  local pcfg = (require("advantage.config").options.providers or {}).openai or {}
  if pcfg.auth_mode == "api_key" then return "api_key" end
  if pcfg.auth_mode == "chatgpt" then return "chatgpt" end
  local file = read_json(codex_auth_path())
  local tokens = file and file.tokens
  if tokens and tokens.access_token and tokens.access_token ~= vim.NIL and codex_account_id(tokens) then
    local claims = jwt_payload(tokens.access_token)
    if (claims and (claims.exp or 0) > os.time() + 60) or tokens.refresh_token then return "chatgpt" end
  end
  return "api_key"
end

---Stable, non-secret identity for sub-agent route health. A failed ChatGPT
---model must not poison the raw-API route (or another account), and changing
---credentials should immediately select a fresh circuit instead of waiting for
---an old cooldown. Only a short SHA-256 fingerprint is returned; credentials
---never leave this module.
---@param provider string
---@return string
function M.route_scope_hint(provider)
  local function fingerprint(value)
    if type(value) ~= "string" or value == "" then return "none" end
    return vim.fn.sha256(value):sub(1, 12)
  end
  if provider == "openai" then
    local file = read_json(codex_auth_path())
    local mode = M.openai_mode_hint()
    if mode == "chatgpt" then
      local account = file and file.tokens and codex_account_id(file.tokens)
      return "openai:chatgpt:" .. fingerprint(account)
    end
    local key = (file and file.OPENAI_API_KEY and file.OPENAI_API_KEY ~= vim.NIL and file.OPENAI_API_KEY)
      or require("advantage.config").api_key("openai")
    return "openai:api_key:" .. fingerprint(key)
  elseif provider == "anthropic" then
    local file = read_json(claude_creds_path())
    local oauth = file and file.claudeAiOauth
    if oauth and oauth.accessToken then
      return "anthropic:oauth:" .. fingerprint(oauth.refreshToken or oauth.accessToken)
    end
    return "anthropic:api_key:" .. fingerprint(require("advantage.config").api_key("anthropic"))
  end
  return tostring(provider) .. ":default"
end

---Cheap synchronous credential readiness used only to decide whether multiple
---scouts may start in parallel. Refresh-token-only logins remain a single
---flight probe; a currently valid token/API key has passed local checks.
function M.route_credentials_ready(provider)
  if provider == "openai" then
    local file = read_json(codex_auth_path())
    local mode = M.openai_mode_hint()
    if mode == "chatgpt" then
      local tokens = file and file.tokens
      local claims = tokens and jwt_payload(tokens.access_token)
      return tokens ~= nil
        and tokens.access_token ~= nil
        and codex_account_id(tokens) ~= nil
        and claims ~= nil
        and (claims.exp or 0) > os.time() + 60
    end
    local key = (file and file.OPENAI_API_KEY and file.OPENAI_API_KEY ~= vim.NIL and file.OPENAI_API_KEY)
      or require("advantage.config").api_key("openai")
    return type(key) == "string" and key ~= ""
  elseif provider == "anthropic" then
    local file = read_json(claude_creds_path())
    local oauth = file and file.claudeAiOauth
    if oauth and oauth.accessToken then return (oauth.expiresAt or 0) / 1000 > os.time() + 60 end
    return require("advantage.config").api_key("anthropic") ~= nil
  end
  return false
end

return M
