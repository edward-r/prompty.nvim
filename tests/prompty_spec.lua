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

describe("prompty.ui", function()
  local ui

  before_each(function()
    vim.cmd("silent! %bwipeout!")
    ui = require("prompty.ui")
    ui.reset_output()
  end)

  it("renders intent header with prompt body", function()
    ui.render_prompt("Test Intent", "Line one\nLine two")
    local buf = ui.ensure_output_buffer()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ "# Test Intent", "", "Line one", "Line two" }, lines)
  end)

  it("detects when refine buffer has text", function()
    local refine_buf = ui.ensure_refine_buffer()
    vim.api.nvim_buf_set_lines(refine_buf, 0, -1, false, { "   ", "" })
    assert.is_false(ui.refine_buffer_has_text())

    vim.api.nvim_buf_set_lines(refine_buf, 0, -1, false, { "make it shorter" })
    assert.is_true(ui.refine_buffer_has_text())
  end)
end)
