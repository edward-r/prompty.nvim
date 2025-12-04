---@diagnostic disable: undefined-global
local assert = require("luassert")

describe("prompty", function()
  local prompty
  local buf

  before_each(function()
    vim.cmd("silent! %bwipeout!")
    prompty = require("prompty")
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  it("can be required without errors", function()
    assert.is_table(prompty)
    assert.is_function(prompty.setup)
  end)

  it("falls back to current line when no marks are set", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
    vim.fn.setpos("'<", { 0, 0, 0, 0 })
    vim.fn.setpos("'>", { 0, 0, 0, 0 })
    local text = prompty.capture_visual_intent()
    assert.are.same("hello world", text)
  end)

  it("captures multi-line visual selections", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "alpha beta gamma",
      "delta epsilon",
      "zeta",
    })
    -- simulate visual selection from column 7 on line 1 to column 5 on line 2
    vim.fn.setpos("'<", { 0, 1, 7, 0 })
    vim.fn.setpos("'>", { 0, 2, 5, 0 })
    local text = prompty.capture_visual_intent()
    assert.are.same("beta gamma\ndelta", text)
  end)
end)
