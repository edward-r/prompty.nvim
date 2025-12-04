---@diagnostic disable-next-line: undefined-global
local vim = vim

if vim.g.loaded_prompty_plugin then
  return
end
vim.g.loaded_prompty_plugin = true

local prompty = require("prompty")

vim.api.nvim_create_user_command("Prompty", function(cmd)
  local intent = cmd.args
  if intent == "" then
    intent = nil
  end
  prompty.generate({ intent = intent, prompt_for_intent = true })
end, {
  nargs = "*",
  desc = "Run prompt-maker-cli with given intent",
})

vim.api.nvim_create_user_command("PromptyVisual", function()
  local intent = prompty.capture_visual_intent()
  prompty.generate({ intent = intent })
end, {
  range = true,
  desc = "Run prompt-maker-cli for visual selection",
})

vim.api.nvim_create_user_command("PromptyRefine", function(cmd)
  prompty.refine(cmd.args)
end, {
  nargs = "*",
  desc = "Send refinement instruction to active Prompty session",
})
