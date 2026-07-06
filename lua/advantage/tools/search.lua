---@brief Search / listing tools: grep, find_files, list_dir. Registered by
---tools/init.lua; behaviour is identical to when these lived inline in that file.
local uv = vim.uv or vim.loop

local GREP_MODES = { content = true, files_with_matches = true, count = true }

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "search tools: tool registrar required")
  assert(type(s) == "table" and s.finalize_search, "search tools: support module required")
  local resolve, finalize_search, lsp_explore_nudge = s.resolve, s.finalize_search, s.lsp_explore_nudge

  -- grep ------------------------------------------------------------------

  tool({
    name = "grep",
    safe = true,
    description = 'Search file contents with a regex (ripgrep). output_mode controls what comes back: "content" (default) returns file:line:text matches; "files_with_matches" returns just the matching file paths (cheapest when you only need locations); "count" returns per-file match counts. Use head_limit to cap output lines.',
    input_schema = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Regex pattern to search for" },
        path = { type = "string", description = "Directory or file to search (default: project root)" },
        glob = { type = "string", description = 'Filter files, e.g. "*.lua"' },
        output_mode = {
          type = "string",
          description = "content (default) | files_with_matches | count",
          enum = { "content", "files_with_matches", "count" },
        },
        ignore_case = { type = "boolean", description = "Case-insensitive search" },
        head_limit = { type = "integer", description = "Cap the number of output lines returned" },
      },
      required = { "pattern" },
    },
    summary = function(input)
      local m = input.output_mode
      return (input.pattern or "") .. ((m and m ~= "content") and (" [" .. m .. "]") or "")
    end,
    run = function(input, ctx, cb)
      local search_path = "."
      if input.path and input.path ~= "" and input.path ~= "." then
        local p, perr = resolve(input.path, ctx)
        if not p then return cb(("Cannot search %s: %s"):format(tostring(input.path), perr), true) end
        search_path = p
      end
      local mode = GREP_MODES[input.output_mode] and input.output_mode or "content"
      local head_limit = tonumber(input.head_limit)
      local has_rg = vim.fn.executable("rg") == 1
      local cmd
      if has_rg then
        cmd = { "rg", "--color=never" }
        if mode == "files_with_matches" then
          cmd[#cmd + 1] = "--files-with-matches"
        elseif mode == "count" then
          cmd[#cmd + 1] = "--count" -- file:matching-line-count, omits zero-match files
        else
          vim.list_extend(cmd, { "--line-number", "--no-heading", "--max-count=100" })
        end
        if input.ignore_case then cmd[#cmd + 1] = "-i" end
        vim.list_extend(cmd, { "-e", input.pattern })
        if input.glob then vim.list_extend(cmd, { "--glob", input.glob }) end
        cmd[#cmd + 1] = search_path
      else
        local flag = mode == "files_with_matches" and "-rlE" or mode == "count" and "-rcE" or "-rnE"
        cmd = { "grep", flag }
        if input.ignore_case then cmd[#cmd + 1] = "-i" end
        vim.list_extend(cmd, { input.pattern, search_path })
      end
      vim.system(cmd, { cwd = ctx.cwd, text = true }, function(res)
        vim.schedule(function()
          if res.code > 1 then return cb("Search failed: " .. (res.stderr or ""), true) end
          local lines = vim.split(vim.trim(res.stdout or ""), "\n", { plain = true, trimempty = true })
          -- grep -rc prints "path:0" for files with no match; drop that noise so the
          -- count mode only lists files that actually matched (rg --count already does).
          if mode == "count" and not has_rg then
            local kept = {}
            for _, l in ipairs(lines) do
              if not l:match(":0$") then kept[#kept + 1] = l end
            end
            lines = kept
          end
          cb(finalize_search(lines, head_limit, "No matches.") .. lsp_explore_nudge(), false)
        end)
      end)
    end,
  })

  -- find_files ------------------------------------------------------------

  tool({
    name = "find_files",
    safe = true,
    description = 'List project files matching a glob pattern, e.g. "**/*.lua" or "src/**".',
    input_schema = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Glob pattern" },
      },
      required = { "pattern" },
    },
    summary = function(input)
      return input.pattern or ""
    end,
    run = function(input, ctx, cb)
      local cmd, filter_re
      if vim.fn.executable("rg") == 1 then
        cmd = { "rg", "--files", "--glob", input.pattern }
      else
        cmd = { "sh", "-c", "find . -path './.git' -prune -o -type f -print" }
        -- rg is absent: filter the full file list against the glob ourselves so
        -- the pattern is still honoured instead of dumping the whole tree.
        if input.pattern and input.pattern ~= "" then
          local ok, re = pcall(vim.fn.glob2regpat, input.pattern)
          if ok then filter_re = re end
        end
      end
      vim.system(cmd, { cwd = ctx.cwd, text = true }, function(res)
        vim.schedule(function()
          local lines = vim.split(vim.trim(res.stdout or ""), "\n", { plain = true, trimempty = true })
          if filter_re then
            local matched = {}
            for _, line in ipairs(lines) do
              local rel = line:gsub("^%./", "")
              if vim.fn.match(rel, filter_re) >= 0 then matched[#matched + 1] = rel end
            end
            lines = matched
          end
          if #lines > 300 then
            local total = #lines
            lines = vim.list_slice(lines, 1, 300)
            lines[#lines + 1] = ("… %d more files"):format(total - 300)
          end
          cb((#lines == 0 and "No files matched." or table.concat(lines, "\n")) .. lsp_explore_nudge(), false)
        end)
      end)
    end,
  })

  -- list_dir --------------------------------------------------------------

  tool({
    name = "list_dir",
    safe = true,
    description = "List entries of a directory. Directories end with '/'.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Directory path (default: project root)" },
      },
    },
    summary = function(input)
      return input.path or "."
    end,
    run = function(input, ctx, cb)
      local path, perr = resolve((input.path and input.path ~= "") and input.path or ".", ctx)
      if not path then return cb(("Cannot list %s: %s"):format(tostring(input.path), perr), true) end
      local handle = uv.fs_scandir(path)
      if not handle then return cb("Not a directory: " .. tostring(input.path), true) end
      local dirs, files = {}, {}
      while true do
        local name, t = uv.fs_scandir_next(handle)
        if not name then break end
        if t == "directory" then
          dirs[#dirs + 1] = name .. "/"
        else
          files[#files + 1] = name
        end
        if #dirs + #files >= 500 then break end
      end
      table.sort(dirs)
      table.sort(files)
      vim.list_extend(dirs, files)
      cb(#dirs == 0 and "(empty)" or table.concat(dirs, "\n"), false)
    end,
  })
end
