---@diagnostic disable-next-line: undefined-global
local vim = vim

local M = {}

local state = {
  output_buf = nil,
  output_win = nil,
  refine_buf = nil,
  refine_win = nil,
  progress_mark = nil,
}

local progress_ns = vim.api.nvim_create_namespace("prompty-progress")

local function ensure_command_window(cmd)
  vim.cmd(cmd)
  return vim.api.nvim_get_current_win()
end

function M.notify(message, level)
  level = level or vim.log.levels.INFO
  vim.notify(message, level, { title = "Prompty" })
end

function M.ensure_output_buffer()
  if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
    return state.output_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_name(buf, "Prompty Output")
  state.output_buf = buf
  return buf
end

function M.open_output_window()
  local buf = M.ensure_output_buffer()
  local win = state.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    ensure_command_window("botright split")
    win = vim.api.nvim_get_current_win()
    local height = math.max(10, math.floor(vim.o.lines * 0.3))
    vim.api.nvim_win_set_height(win, height)
    state.output_win = win
  end
  vim.api.nvim_win_set_buf(win, buf)
  return buf, win
end

function M.reset_output(header)
  local buf = M.ensure_output_buffer()
  local lines = {}
  if header and header ~= "" then
    lines = { "# " .. header, "" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  state.progress_mark = nil
  return buf
end

local function append_lines(buf, lines)
  if #lines == 0 then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 1 then
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    if not first or first == "" then
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, lines)
      return
    end
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
end

function M.append_markdown(text)
  if not text or text == "" then
    return
  end

  local buf = M.ensure_output_buffer()
  append_lines(buf, vim.split(text, "\n", { plain = true }))
end

function M.render_prompt(intent, text)
  local buf = M.ensure_output_buffer()
  local lines = {}
  if intent and intent ~= "" then
    table.insert(lines, "# " .. intent)
    table.insert(lines, "")
  end
  if text and text ~= "" then
    vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

function M.show_progress(message)
  local buf = M.ensure_output_buffer()
  local line = math.max(vim.api.nvim_buf_line_count(buf) - 1, 0)
  if state.progress_mark then
    vim.api.nvim_buf_del_extmark(buf, progress_ns, state.progress_mark)
  end
  state.progress_mark = vim.api.nvim_buf_set_extmark(buf, progress_ns, line, 0, {
    virt_text = { { message, "Comment" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

function M.clear_progress()
  if not state.progress_mark then
    return
  end

  local buf = M.ensure_output_buffer()
  vim.api.nvim_buf_del_extmark(buf, progress_ns, state.progress_mark)
  state.progress_mark = nil
end

function M.show_telemetry(payload)
  if not payload then
    return
  end

  local prompt_tokens = payload.prompt_tokens or payload.prompt or payload.prompt_tokens_used
  local completion_tokens = payload.completion_tokens or payload.completion or payload.completion_tokens_used
  local total = payload.total_tokens or (prompt_tokens and completion_tokens and (prompt_tokens + completion_tokens))
  local message = string.format(
    "tokens → prompt:%s completion:%s total:%s",
    prompt_tokens or "?",
    completion_tokens or "?",
    total or "?"
  )
  M.notify(message, vim.log.levels.INFO)
end

function M.ensure_refine_buffer()
  if state.refine_buf and vim.api.nvim_buf_is_valid(state.refine_buf) then
    return state.refine_buf
  end

  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_name(buf, "Prompty Instructions")
  state.refine_buf = buf
  return buf
end

function M.open_refine_window()
  local buf = M.ensure_refine_buffer()
  local win = state.refine_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    ensure_command_window("botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(win, math.max(30, math.floor(vim.o.columns * 0.3)))
    state.refine_win = win
  end
  vim.api.nvim_win_set_buf(win, buf)
  return buf, win
end

function M.consume_refine_text()
  local buf = M.ensure_refine_buffer()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  return text
end

function M.refine_buffer_has_text()
  local buf = M.ensure_refine_buffer()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      return true
    end
  end
  return false
end

function M.attach_session_cleanup(bufnr, session)
  local group = vim.api.nvim_create_augroup("PromptySession" .. session.id, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    group = group,
    callback = function()
      if session.stop then
        session:stop()
      end
    end,
  })
end

function M.capture_visual_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if start_pos[2] == 0 or end_pos[2] == 0 then
    return vim.trim(vim.api.nvim_get_current_line())
  end
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > end_line then
    start_line, end_line = end_line, start_line
    start_pos, end_pos = end_pos, start_pos
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    return ""
  end

  if #lines == 1 then
    lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
  else
    lines[1] = string.sub(lines[1], start_pos[3])
    lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
  end

  return vim.trim(table.concat(lines, "\n"))
end

return M
