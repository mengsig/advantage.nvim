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
  local f = io.open(path, "w")
  if not f then return false end
  f:write(vim.json.encode(tbl))
  f:close()
  pcall(uv.fs_chmod, path, 384) -- 0600
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
      if res.code ~= 0 then
        return cb(nil, "network error: " .. (res.stderr or res.code))
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(decoded) ~= "table" then
        return cb(nil, "unexpected response from " .. url)
      end
      if decoded.error then
        local msg = type(decoded.error) == "table" and (decoded.error.message or decoded.error.error) or tostring(decoded.error)
        return cb(nil, msg)
      end
      cb(decoded)
    end)
  )
end

-- anthropic ---------------------------------------------------------------

local function refresh_anthropic(oauth, cb)
  post_json(ANTHROPIC_TOKEN_URL, {
    grant_type = "refresh_token",
    refresh_token = oauth.refreshToken,
    client_id = ANTHROPIC_CLIENT_ID,
  }, function(res, err)
    if not res or not res.access_token then
      return cb(nil, "Claude token refresh failed (" .. (err or "no token") .. "). Run `claude` and /login again.")
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
        vim.notify("advantage: could not write refreshed Claude credentials to " .. path
          .. " — the `claude` CLI may need a re-login later.", vim.log.levels.WARN)
      end)
    end
    cb(updated)
  end)
end

---@param cb fun(cred: {mode:string, token?:string, key?:string, badge:string}|nil, err?:string)
function M.anthropic(cb)
  local file = read_json(claude_creds_path())
  local oauth = file and file.claudeAiOauth
  if oauth and oauth.accessToken then
    local expires = (oauth.expiresAt or 0) / 1000
    if expires > os.time() + 60 then
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
  if key then
    return cb({ mode = "api_key", key = key, badge = "api" })
  end
  cb(nil, "No Claude credentials. Log in with the `claude` CLI (subscription) or export $ANTHROPIC_API_KEY.")
end

-- openai / codex ----------------------------------------------------------

local function codex_account_id(tokens)
  if tokens.account_id and tokens.account_id ~= vim.NIL then return tokens.account_id end
  local claims = jwt_payload(tokens.id_token)
  local auth_claim = claims and claims["https://api.openai.com/auth"]
  return auth_claim and auth_claim.chatgpt_account_id or nil
end

local function refresh_codex(auth_file, cb)
  local tokens = auth_file.tokens
  post_json(OPENAI_TOKEN_URL, {
    client_id = OPENAI_CLIENT_ID,
    grant_type = "refresh_token",
    refresh_token = tokens.refresh_token,
    scope = "openid profile email",
  }, function(res, err)
    if not res or not res.access_token then
      return cb(nil, "Codex token refresh failed (" .. (err or "no token") .. "). Run `codex login` again.")
    end
    auth_file.tokens.access_token = res.access_token
    auth_file.tokens.id_token = res.id_token or tokens.id_token
    auth_file.tokens.refresh_token = res.refresh_token or tokens.refresh_token
    auth_file.last_refresh = os.date("!%Y-%m-%dT%H:%M:%S.000Z")
    if not write_json(codex_auth_path(), auth_file) then
      vim.schedule(function()
        vim.notify("advantage: could not write refreshed Codex credentials to " .. codex_auth_path()
          .. " — the `codex` CLI may need a re-login later.", vim.log.levels.WARN)
      end)
    end
    cb(auth_file.tokens)
  end)
end

---@param cb fun(cred: {mode:string, token?:string, key?:string, account_id?:string, badge:string}|nil, err?:string)
function M.openai(cb)
  local auth_file = read_json(codex_auth_path())
  local tokens = auth_file and auth_file.tokens
  if tokens and tokens.access_token and tokens.access_token ~= vim.NIL then
    local account = codex_account_id(tokens)
    local claims = jwt_payload(tokens.access_token)
    local exp = claims and claims.exp or 0
    if exp > os.time() + 60 and account then
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
        if key then
          cb({ mode = "api_key", key = key, badge = "api" })
        else
          cb(nil, err or "Codex login is missing an account id. Run `codex login` again.")
        end
      end)
    end
  end
  local key = (auth_file and auth_file.OPENAI_API_KEY and auth_file.OPENAI_API_KEY ~= vim.NIL and auth_file.OPENAI_API_KEY)
    or require("advantage.config").api_key("openai")
  if key then
    return cb({ mode = "api_key", key = key, badge = "api" })
  end
  cb(nil, "No Codex credentials. Log in with `codex login` (subscription) or export $OPENAI_API_KEY.")
end

return M
