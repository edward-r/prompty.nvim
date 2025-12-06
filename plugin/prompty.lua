---@diagnostic disable-next-line: undefined-global
local vim = vim

if vim.g.loaded_prompty_plugin then
  return
end
vim.g.loaded_prompty_plugin = true

local prompty = require("prompty")

if prompty.ensure_setup then
  prompty.ensure_setup()
end

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

vim.api.nvim_create_user_command("PromptyFinish", function()
  prompty.finish()
end, {
  desc = "Send finish command to active Prompty session",
})
