-- tests/minimal_init.lua
---@diagnostic disable-next-line: undefined-global
local vim = vim

local M = {}

function M.root(path)
  local info = debug.getinfo(1, "S").source:sub(2)
  local dir = vim.fn.fnamemodify(info, ":p:h:h")
  if path and path ~= "" then
    return dir .. "/" .. path
  end
  return dir
end

-- Ensure runtime contains plenary before everything else.
local plenary_dir = os.getenv("PLENARY_DIR") or "../plenary.nvim"
vim.opt.rtp:append(plenary_dir)

-- Add this plugin.
vim.opt.rtp:append(M.root())

-- Optionally configure plugin defaults here.
require("prompty").setup({
  notifications = false,
})

return M
