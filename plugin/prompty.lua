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

vim.api.nvim_create_user_command("PromptyVisualIntent", function()
  local snippet = prompty.capture_visual_intent()
  prompty.generate({ snippet = snippet, prompt_for_intent = true })
end, {
  range = true,
  desc = "Capture visual selection as context and prompt for intent",
})

vim.api.nvim_create_user_command("PromptyContext", function()
  prompty.configure_context()
end, {
  desc = "Interactively configure Prompty context for the next run",
})

vim.api.nvim_create_user_command("PromptyHere", function()
  prompty.add_current_buffer_context()
end, {
  desc = "Queue the current buffer as Prompty context",
})

vim.api.nvim_create_user_command("PromptyPrompt", function()
  prompty.prompt_with_flags()
end, {
  desc = "Prompt for intent and per-run flags",
})

vim.api.nvim_create_user_command("PromptySave", function(cmd)
  local path = cmd.args ~= "" and cmd.args or nil
  prompty.save_output({ path = path })
end, {
  nargs = "?",
  complete = "file",
  desc = "Save Prompty output to a file",
})

vim.api.nvim_create_user_command("PromptyCopy", function()
  prompty.copy_output()
end, {
  desc = "Copy Prompty output to the clipboard",
})

vim.api.nvim_create_user_command("PromptyScratch", function()
  prompty.open_output_scratch()
end, {
  desc = "Open Prompty output in a scratch tab",
})

vim.api.nvim_create_user_command("PromptyHistory", function()
  prompty.show_history()
end, {
  desc = "Browse past Prompty runs from history",
})

vim.api.nvim_create_user_command("PromptyOnce", function(cmd)
  local raw = cmd.args or ""
  local intent = vim.trim(raw)
  if intent == "" then
    intent = nil
  end
  prompty.generate({ intent = intent, interactive = false, prompt_for_intent = intent == nil })
end, {
  nargs = "*",
  desc = "Run Prompty once in non-interactive (--json) mode",
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
