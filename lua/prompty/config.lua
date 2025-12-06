---@diagnostic disable-next-line: undefined-global
local vim = vim

local M = {}

local defaults = {
  binary = "prompt-maker-cli",
  default_flags = {},
  keymaps = {
    prompt = "<leader>pp",
    prompt_visual = "<leader>pP",
    refine = "<leader>pr",
    finish = "<leader>pf",
  },
  temp_dir = vim.fs.joinpath(vim.fn.stdpath("run"), "prompty"),
  history_file = vim.fs.normalize(vim.fn.expand("~/.config/prompt-maker-cli/history.jsonl")),
  interactive_timeout = 15000,
  notifications = true,
}

local options = vim.deepcopy(defaults)

local function ensure_dir(path)
  if not path or path == "" then
    return
  end

  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok and options.notifications ~= false then
    vim.notify(string.format("Prompty: unable to create temp dir %s (%s)", path, err), vim.log.levels.WARN)
  end
end

function M.setup(opts)
  opts = opts or {}
  options = vim.tbl_deep_extend("force", defaults, opts)
  ensure_dir(options.temp_dir)
  return options
end

function M.get()
  return options
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
