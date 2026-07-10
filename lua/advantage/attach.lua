---@brief Attachments & context: clipboard images, image files, @file mentions,
---and project file listing for prompt completion / pickers.
local M = {}

local uv = vim.uv or vim.loop

M.IMAGE_TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
}

-- Providers cap inline images around 5 MB; base64 inflates ~4/3, so cap the raw
-- bytes so an accidental multi-MB screenshot is rejected up front instead of
-- bloating every request/session and getting 400'd by the API.
local MAX_IMAGE_BYTES = 5 * 1024 * 1024

local function too_big(data)
  if #data > MAX_IMAGE_BYTES then
    return ("image is too large (%.1f MB, max %d MB)"):format(#data / 1048576, MAX_IMAGE_BYTES / 1048576)
  end
end

local function has(bin)
  return vim.fn.executable(bin) == 1
end

local function cache_dir()
  local dir = vim.fn.stdpath("cache") .. "/advantage/images"
  vim.fn.mkdir(dir, "p")
  return dir
end

---Run a command, returning binary stdout on success.
local function run(cmd, timeout)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = false }):wait(timeout or 4000)
  end)
  if not ok or not res or res.code ~= 0 then return nil end
  return res.stdout
end

---Grab an image from the system clipboard (Wayland, X11 or macOS).
---@return {name:string, path:string, media_type:string, data:string}|nil, string|nil
function M.clipboard_image()
  local grabbers = {}
  if vim.env.WAYLAND_DISPLAY and has("wl-paste") then
    grabbers[#grabbers + 1] = {
      types = { "wl-paste", "--list-types" },
      get = { "wl-paste", "--type", "image/png" },
    }
  end
  if vim.env.DISPLAY and has("xclip") then
    grabbers[#grabbers + 1] = {
      types = { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
      get = { "xclip", "-selection", "clipboard", "-t", "image/png", "-o" },
    }
  end
  if vim.fn.has("mac") == 1 and has("pngpaste") then grabbers[#grabbers + 1] = { get = { "pngpaste", "-" } } end
  if #grabbers == 0 then return nil, "no clipboard tool found (need wl-paste, xclip or pngpaste)" end
  for _, g in ipairs(grabbers) do
    local available = true
    if g.types then
      local t = run(g.types)
      available = t ~= nil and t:find("image/png", 1, true) ~= nil
    end
    if available then
      local data = run(g.get)
      if data and too_big(data) then return nil, too_big(data) end
      if data and #data > 0 then
        local name = os.date("paste-%H%M%S") .. ".png"
        local path = cache_dir() .. "/" .. name
        local f = io.open(path, "wb")
        if f then
          f:write(data)
          f:close()
        end
        return { name = name, path = path, media_type = "image/png", data = vim.base64.encode(data) }
      end
    end
  end
  return nil, "no image in the clipboard"
end

---Load an image file from disk as an attachment.
---@return {name:string, path:string, media_type:string, data:string}|nil, string|nil
function M.load_image(path)
  local ext = path:match("%.(%w+)$")
  local media = ext and M.IMAGE_TYPES[ext:lower()]
  if not media then return nil, "not a supported image (png/jpg/jpeg/gif/webp)" end
  local f = io.open(path, "rb")
  if not f then return nil, "cannot read " .. path end
  local data = f:read("*a")
  f:close()
  local err = too_big(data)
  if err then return nil, err end
  return {
    name = vim.fn.fnamemodify(path, ":t"),
    path = path,
    media_type = media,
    data = vim.base64.encode(data),
  }
end

local MAX_INLINE = 48 * 1024

---Parse a mention token into path + optional line range.
---Accepts `path`, `path:L10`, `path:L10-20`, `path:L10-L20` and `#L` variants.
local function parse_token(token)
  local p, l1, l2 = token:match("^(.-)[:#]L(%d+)%-?L?(%d*)$")
  if p and p ~= "" then
    local lo = tonumber(l1)
    local hi = l2 ~= "" and tonumber(l2) or lo
    if hi < lo then
      lo, hi = hi, lo
    end
    return p, lo, hi
  end
  return token, nil, nil
end
M._parse_token = parse_token

---Scan `text` for `@path` mentions that resolve to real, contained files.
---@return table[] files each { name, rel, path, size, lo, hi }
local function collect_mentions(text, cwd, allow_outside)
  assert(type(text) == "string", "collect_mentions: text must be a string")
  local seen, files = {}, {}
  for raw in text:gmatch("@([%w%._%-/:#]+)") do
    local token = raw:gsub("[.,;:!?]+$", "")
    if token ~= "" and not seen[token] then
      seen[token] = true
      local rel, lo, hi = parse_token(token)
      -- Keep mentions inside the project root unless explicitly opted out, so
      -- `@/etc/passwd`, `@../secret`, or an in-repo symlink pointing outside
      -- don't get inlined into the prompt. Same containment as the file tools.
      local path = require("advantage.util").contain(rel, cwd, allow_outside)
      local stat = path and uv.fs_stat(path) or nil
      if stat and stat.type == "file" then
        files[#files + 1] = { name = token, rel = rel, path = path, size = stat.size, lo = lo, hi = hi }
      end
    end
  end
  return files
end

---Append the rendered block (fenced content or a read_file pointer) for one
---mentioned file to `out`.
local function render_attachment(out, file)
  assert(type(out) == "table", "render_attachment: out list required")
  assert(type(file) == "table" and type(file.path) == "string", "render_attachment: resolved file required")
  local ft = vim.filetype.match({ filename = file.path }) or ""
  if file.lo and file.size > 2 * 1024 * 1024 then
    -- Guard against slurping a huge file just to inline a few lines: point the
    -- agent at read_file with the exact offset/limit instead of loading it all.
    out[#out + 1] = ("`%s` (%.1f MB) is too large to inline a range — read it with read_file (offset=%d, limit=%d)."):format(
      file.name,
      file.size / 1048576,
      file.lo,
      file.hi - file.lo + 1
    )
  elseif file.lo then
    -- inline just the requested line range, with enough metadata for the
    -- agent to edit exactly those lines
    local f = io.open(file.path, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    local lines = vim.split(content, "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end
    local total = #lines
    local lo = math.max(1, math.min(file.lo, total))
    local hi = math.max(lo, math.min(file.hi, total))
    local chunk = table.concat(vim.list_slice(lines, lo, hi), "\n")
    if #chunk > MAX_INLINE then
      out[#out + 1] = ("`%s` is too large to inline — read it with the read_file tool (offset=%d, limit=%d)."):format(
        file.name,
        lo,
        hi - lo + 1
      )
    else
      out[#out + 1] = ("```%s %s:L%d-%d (of %d lines)"):format(ft, file.rel, lo, hi, total)
      out[#out + 1] = chunk
      out[#out + 1] = "```"
      out[#out + 1] = ("The user is pointing you at lines %d-%d of %s."):format(lo, hi, file.rel)
    end
  elseif file.size > MAX_INLINE then
    out[#out + 1] = ("`%s` (%.1f KB) is too large to inline — read it with the read_file tool."):format(
      file.name,
      file.size / 1024
    )
  else
    local f = io.open(file.path, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    out[#out + 1] = ("```%s %s"):format(ft, file.name)
    out[#out + 1] = (content:gsub("\n$", ""))
    out[#out + 1] = "```"
  end
end

---Expand `@path` / `@path:L10-20` mentions: returns the text with the
---mentioned files (or line ranges) inlined as fenced blocks, plus the list of
---files that matched.
---@return string, {name:string, path:string, size:integer, lo?:integer, hi?:integer}[]
function M.expand_mentions(text, cwd)
  cwd = cwd or uv.cwd()
  local allow_outside = ((require("advantage.config").options or {}).tools or {}).allow_outside_root
  local files = collect_mentions(text, cwd, allow_outside)
  if #files == 0 then return text, files end
  local out = { text, "", "Attached files:" }
  for _, file in ipairs(files) do
    out[#out + 1] = ""
    render_attachment(out, file)
  end
  return table.concat(out, "\n"), files
end

local cache = { at = 0, files = nil, cwd = nil }

---List project files (briefly cached) for @completion and pickers.
function M.project_files(limit, cwd)
  limit = limit or 400
  cwd = cwd or uv.cwd()
  if not (cache.files and cache.cwd == cwd and os.time() - cache.at < 5) then
    local cmd
    if has("rg") then
      cmd = { "rg", "--files", "--sortr", "modified" }
    elseif has("git") and vim.fs.find(".git", { path = cwd, upward = true })[1] then
      cmd = { "git", "ls-files" }
    else
      cmd = { "find", ".", "-type", "f", "-not", "-path", "*/.git/*" }
    end
    local ok, result = pcall(function()
      return vim.system(cmd, { cwd = cwd, text = true }):wait(5000)
    end)
    local out = ok and result and result.code == 0 and vim.split(result.stdout or "", "\n", { trimempty = true }) or {}
    local files = {}
    for _, f in ipairs(out) do
      files[#files + 1] = (f:gsub("^%./", ""))
    end
    cache = { at = os.time(), files = files, cwd = cwd }
  end
  return vim.list_slice(cache.files, 1, math.min(#cache.files, limit))
end

return M
