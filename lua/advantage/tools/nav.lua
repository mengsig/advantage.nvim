---@brief LSP navigation tools: document_symbols, goto_definition,
---find_references, hover, workspace_symbol. Editor-native semantic code
---navigation — each traverses the language server the editor already runs, so
---the model finds a definition / every call site / a file's outline / a type
---signature in a few tokens instead of grepping and reading whole files. All
---read-only (safe), gated behind tools.lsp + vim.lsp. Registered by
---tools/init.lua; behaviour is identical to when these lived inline there.

---@param tool fun(def: table)
---@param s table support helpers from tools/support.lua
return function(tool, s)
  assert(type(tool) == "function", "lsp tools: tool registrar required")
  assert(type(s) == "table", "lsp tools: support module required")

  tool({
    name = "document_symbols",
    safe = true,
    feature = "lsp",
    description = "Outline a file's symbols (functions, classes, methods, fields) with their lines, via the language server — a token-lean map of a file without reading its full text. Use it to orient in a large file before reading the parts that matter.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path, relative to the project root" },
      },
      required = { "path" },
    },
    summary = function(input)
      return input.path or ""
    end,
    run = function(input, ctx, cb)
      require("advantage.lsp").document_symbols(input.path, ctx.cwd, cb)
    end,
  })

  tool({
    name = "goto_definition",
    safe = true,
    feature = "lsp",
    description = "Jump to where a symbol is defined, via the language server. Give the file and the line where the symbol is used, and the symbol name; returns the definition's file:line (with the line's text). Far cheaper than grepping for a name and reading the results.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path (relative to the project root) where the symbol appears" },
        line = { type = "integer", description = "1-based line where the symbol is used" },
        symbol = { type = "string", description = "The symbol name on that line (used to find the exact column)" },
        column = {
          type = "integer",
          description = "Optional 1-based column override if the symbol name is ambiguous on the line",
        },
      },
      required = { "path", "line" },
    },
    summary = function(input)
      return ("%s:%s"):format(input.path or "", input.line or "?")
    end,
    run = function(input, ctx, cb)
      require("advantage.lsp").definition(input.path, ctx.cwd, input.line, input.symbol, input.column, cb)
    end,
  })

  tool({
    name = "find_references",
    safe = true,
    feature = "lsp",
    description = 'List every reference/call site of a symbol across the project, via the language server. Give the file and line where the symbol appears, and its name. The token-lean way to answer "who calls / uses this?" without grepping and reading each hit.',
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path (relative to the project root) where the symbol appears" },
        line = { type = "integer", description = "1-based line where the symbol appears" },
        symbol = { type = "string", description = "The symbol name on that line (used to find the exact column)" },
        column = { type = "integer", description = "Optional 1-based column override" },
      },
      required = { "path", "line" },
    },
    summary = function(input)
      return ("%s:%s"):format(input.path or "", input.line or "?")
    end,
    run = function(input, ctx, cb)
      require("advantage.lsp").references(input.path, ctx.cwd, input.line, input.symbol, input.column, cb)
    end,
  })

  tool({
    name = "hover",
    safe = true,
    feature = "lsp",
    description = "Get the type signature and documentation for a symbol at a position, via the language server (the same info the editor shows on hover). Cheaper and more precise than reading a definition to infer a type.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path, relative to the project root" },
        line = { type = "integer", description = "1-based line where the symbol appears" },
        symbol = { type = "string", description = "The symbol name on that line (used to find the exact column)" },
        column = { type = "integer", description = "Optional 1-based column override" },
      },
      required = { "path", "line" },
    },
    summary = function(input)
      return ("%s:%s"):format(input.path or "", input.line or "?")
    end,
    run = function(input, ctx, cb)
      require("advantage.lsp").hover(input.path, ctx.cwd, input.line, input.symbol, input.column, cb)
    end,
  })

  tool({
    name = "workspace_symbol",
    safe = true,
    feature = "lsp",
    description = 'Find a symbol by name anywhere in the project, via the language server — a semantic, index-backed search for definitions. Match on the bare symbol name (e.g. "new", not "M.new"), and prefer a distinctive name: common names return many matches. In-project results are shown first and external/stdlib matches are collapsed to a count. Requires a language server to already be running (open/read a file of that language first).',
    input_schema = {
      type = "object",
      properties = {
        query = { type = "string", description = "Symbol name or fragment to search for" },
      },
      required = { "query" },
    },
    summary = function(input)
      return input.query or ""
    end,
    run = function(input, ctx, cb)
      require("advantage.lsp").workspace_symbol(input.query, ctx.cwd, cb)
    end,
  })
end
