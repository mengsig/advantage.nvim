if vim.g.loaded_advantage then
  return
end
vim.g.loaded_advantage = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("advantage.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Advantage", function(opts)
  require("advantage")._command(opts)
end, {
  nargs = "*",
  range = true,
  desc = "advantage.nvim — coding agent harness",
  complete = function(arglead, cmdline)
    return require("advantage")._complete(arglead, cmdline)
  end,
})
