---@diagnostic disable-next-line: undefined-global
local vim = vim
local uv = vim.uv

local config = require("prompty.config")
local client = require("prompty.client")
local ui = require("prompty.ui")

local M = {
  _session = nil,
  _configured = false,
  _pending_run = nil,
}

local AUTO_FINISH_DELAY = 2000

local SESSION_STATES = {
  STARTING = "starting",
  RUNNING = "running",
  AWAITING_REFINE = "awaiting_refine",
  FINISHING = "finishing",
  FINISHED = "finished",
  ERRORED = "errored",
}

local DEFAULT_REFINE_HINT = "Type instructions, then :PromptyRefine or :PromptyFinish"
local AWAITING_REFINE_HINT = "Awaiting instructions – blank :PromptyRefine continues"

local run_safe

local function set_session_state(session, state, opts)
  if not session then
    return
  end
  session._state = state
  if opts and opts.message then
    ui.show_status(opts.message, opts.level)
  end
end

local function cancel_auto_finish(session)
  if not session then
    return
  end
  local timer = session._auto_finish_timer
  if timer then
    session._auto_finish_timer = nil
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
end

local function request_finish(session, opts)
  if not session then
    return false, "no active session"
  end
  cancel_auto_finish(session)
  if session._state == SESSION_STATES.FINISHING or session._state == SESSION_STATES.FINISHED then
    return true
  end
  if not session:is_transport_ready() then
    local message = "Interactive transport is not ready; unable to finish session"
    if not (opts and opts.silent) then
      ui.notify(message, vim.log.levels.WARN)
    end
    return false, message
  end
  local ok, err = session:finish()
  if not ok then
    if not (opts and opts.silent) then
      ui.notify("Unable to finish session: " .. (err or "unknown error"), vim.log.levels.ERROR)
    end
    return false, err
  end
  set_session_state(session, SESSION_STATES.FINISHING, {
    message = (opts and opts.message) or "Prompty finishing...",
    level = opts and opts.level,
  })
  return true
end

local function schedule_auto_finish(session)
  if not session or session._auto_finish_timer then
    return
  end
  if session._has_refined or not session.interactive or not session._has_rendered then
    return
  end
  if not session:is_transport_ready() then
    return
  end
  if ui.refine_buffer_has_text() then
    return
  end
  local timer = uv.new_timer()
  session._auto_finish_timer = timer
  timer:start(AUTO_FINISH_DELAY, 0, function()
    timer:stop()
    timer:close()
    session._auto_finish_timer = nil
    run_safe(function()
      if session._has_refined or ui.refine_buffer_has_text() then
        return
      end
      if M._session ~= session then
        return
      end
      if session._state == SESSION_STATES.FINISHING or session._state == SESSION_STATES.FINISHED then
        return
      end
      local ok, err = request_finish(session, {
        message = "Prompty auto-finishing (no refinements)",
        silent = true,
      })
      if not ok and err then
        ui.notify("Prompty auto-finish failed: " .. err, vim.log.levels.WARN)
      else
        session._auto_finished = true
        ui.notify("Prompty auto-finished (no refinements)", vim.log.levels.INFO)
      end
    end)
  end)
end

local function stop_current_session()
  local session = M._session
  if not session then
    return
  end
  cancel_auto_finish(session)
  session:stop()
  M._session = nil
end


local function summarize_progress(payload)
  local message = (payload and (payload.message or payload.label)) or "working"
  if payload then
    local percent = payload.percent or payload.progress
    if percent then
      message = string.format("%s (%s%%)", message, percent)
    end
  end
  return message
end

local function pack_args(...)
  return { n = select("#", ...), ... }
end

local function unpack_args(args, index)
  local i = index or 1
  if i > args.n then
    return
  end
  return args[i], unpack_args(args, i + 1)
end

run_safe = function(fn, ...)
  if not vim.in_fast_event() then
    fn(...)
    return
  end
  local args = pack_args(...)
  vim.schedule(function()
    fn(unpack_args(args))
  end)
end

local function first_string(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if type(value) == "string" then
      local trimmed = vim.trim(value)
      if trimmed ~= "" then
        return value
      end
    end
  end
end

local function extract_prompt_text(event, event_type)
  if not event then
    return nil
  end

  local payload = event.payload or event.data or event or {}
  local result = nil
  if type(payload.result) == "table" then
    result = payload.result
  elseif type(event.result) == "table" then
    result = event.result
  end

  if event_type == "generation.final" then
    return first_string(
      result and result.renderedPrompt,
      result and result.rendered_prompt,
      result and result.polishedPrompt,
      result and result.polished_prompt,
      result and result.prompt,
      result and result.content,
      payload.renderedPrompt,
      payload.rendered_prompt,
      payload.prompt,
      payload.content,
      payload.text,
      payload.delta
    )
  end

  return first_string(
    payload.text,
    payload.delta,
    payload.content,
    payload.prompt,
    payload.renderedPrompt,
    payload.rendered_prompt,
    result and result.renderedPrompt,
    result and result.prompt
  )
end

local function render_prompt(session, text)
  if not text or text == "" then
    return
  end

  local trimmed = vim.trim(text)
  if session and session._last_output == trimmed then
    return
  end

  local intent = session and session._intent or nil
  ui.render_prompt(intent, text)
  if session then
    session._last_output = trimmed
    session._has_rendered = true
  end
end

local function open_refine_if_needed()
  local session = M._session
  if not session or session._refine_ready then
    return
  end
  session._refine_ready = true
  ui.open_refine_window()
  if not (session and session._awaiting_input) then
    ui.set_refine_hint(DEFAULT_REFINE_HINT)
  end
  ui.show_status("Prompty transport ready")
  ui.notify(
    "Prompty transport ready. Type instructions then :PromptyRefine or :PromptyFinish",
    vim.log.levels.INFO
  )
end


local function handle_event(session, event)
  if not event then
    return
  end

  local event_type = event.type or event.event
  if not event_type then
    return
  end

  local payload = event.payload or event.data or event or {}
  if event_type == "generation.iteration.complete" then
    set_session_state(session, SESSION_STATES.RUNNING, { message = "Prompt draft ready" })
    render_prompt(session, extract_prompt_text(event, event_type))
  elseif event_type == "generation.final" then
    render_prompt(session, extract_prompt_text(event, event_type))
    ui.clear_progress()
    set_session_state(session, SESSION_STATES.RUNNING, { message = "Prompt finalized" })
    schedule_auto_finish(session)
  elseif event_type == "progress.update" then
    ui.show_progress(summarize_progress(payload))
  elseif event_type == "context.telemetry" then
    local telemetry = payload.telemetry or event.telemetry or payload
    ui.show_telemetry(telemetry)
  elseif event_type == "transport.listening" then
    ui.show_status("Interactive transport ready")
  elseif event_type == "transport.client.connected" then
    ui.show_status("Prompty transport connected")
  elseif event_type == "transport.client.disconnected" then
    cancel_auto_finish(session)
    local finishing = session and (session._state == SESSION_STATES.FINISHING or session._auto_finished)
    if finishing then
      ui.show_status("Prompty transport disconnected")
    else
      set_session_state(session, SESSION_STATES.FINISHED, {
        message = "Prompty transport disconnected",
        level = vim.log.levels.WARN,
      })
    end
  elseif event_type == "transport.error" then
    cancel_auto_finish(session)
    local message = payload.message or payload.error or "Prompty transport error"
    set_session_state(session, SESSION_STATES.ERRORED, {
      message = message,
      level = vim.log.levels.ERROR,
    })
  elseif event_type == "interactive.awaiting" then
    local mode = payload.mode or payload.state or payload.status
    if mode == "transport" then
      session._awaiting_input = true
      set_session_state(session, SESSION_STATES.AWAITING_REFINE, {
        message = "Awaiting refinement instructions",
      })
      open_refine_if_needed()
      ui.set_refine_hint(AWAITING_REFINE_HINT)
      schedule_auto_finish(session)
    elseif mode == "none" then
      session._awaiting_input = false
      ui.set_refine_hint(DEFAULT_REFINE_HINT)
      set_session_state(session, SESSION_STATES.RUNNING, {
        message = "Continuing Prompty session",
      })
    end
  elseif event_type == "interactive.state" then
    local state_value = payload.state or payload.phase or payload.status or event.state
    if state_value == "prompt" then
      set_session_state(session, SESSION_STATES.RUNNING, { message = "Generating prompt" })
    elseif state_value == "refine" then
      set_session_state(session, SESSION_STATES.RUNNING, { message = "Applying refinement" })
    elseif state_value == "complete" then
      set_session_state(session, SESSION_STATES.FINISHING, { message = "Finalizing Prompty session" })
    end
  end
end

local function attach_session(session, intent)
  ui.open_output_window()
  local buf = ui.reset_output(intent)
  ui.attach_session_cleanup(buf, session)
  session._refine_ready = false
  session._intent = intent or ""
  session._last_output = nil
  session._has_refined = false
  session._auto_finished = false
  session._auto_finish_timer = nil
  session._has_rendered = false
  session._awaiting_input = false
  session._cancel_auto_finish = function()
    cancel_auto_finish(session)
  end
  set_session_state(session, SESSION_STATES.STARTING, { message = "Starting Prompty session" })
  M._session = session
end

local function ensure_pending_run()
  if not M._pending_run then
    M._pending_run = {}
  end
  return M._pending_run
end

local function consume_pending_run()
  local pending = M._pending_run or {}
  M._pending_run = nil
  return pending
end

local function clear_pending_run()
  M._pending_run = nil
end

local function create_temp_file(prefix, contents)
  local dir = vim.fs.joinpath(vim.fn.stdpath("run"), "prompty")
  pcall(vim.fn.mkdir, dir, "p")
  local tmp = vim.fs.joinpath(dir, string.format("%s-%s.txt", prefix or "prompty", uv.hrtime()))
  local ok, err = pcall(vim.fn.writefile, vim.split(contents or "", "\n", true), tmp)
  if not ok then
    ui.notify(string.format("Prompty: failed to create temp context file (%s)", err), vim.log.levels.WARN)
    return nil
  end
  return tmp
end

local LIST_OPTION_KEYS = {
  context = true,
  urls = true,
  images = true,
  videos = true,
}

local function merge_option_list(option_table, key, values)
  if not values or vim.tbl_isempty(values) then
    return
  end
  option_table[key] = option_table[key] or {}
  vim.list_extend(option_table[key], vim.deepcopy(values))
end

local function apply_pending_options(resolved)
  local pending = M._pending_run
  if not pending then
    return
  end
  for key, value in pairs(pending) do
    if LIST_OPTION_KEYS[key] then
      resolved[key] = nil
      merge_option_list(resolved, key, value)
    else
      resolved[key] = vim.deepcopy(value)
    end
  end
end

local function pending_summary()
  local pending = M._pending_run
  if not pending then
    return "no pending context"
  end
  local parts = {}
  for key, value in pairs(pending) do
    if LIST_OPTION_KEYS[key] and type(value) == "table" and #value > 0 then
      table.insert(parts, string.format("%s:%d", key, #value))
    elseif not LIST_OPTION_KEYS[key] and value ~= nil then
      if type(value) == "boolean" then
        table.insert(parts, string.format("%s:%s", key, value and "on" or "off"))
      elseif value ~= "" then
        table.insert(parts, string.format("%s:%s", key, value))
      end
    end
  end
  if #parts == 0 then
    return "no pending context"
  end
  return table.concat(parts, ", ")
end

local function notify_pending_update(message)
  ui.notify(string.format("%s (%s)", message, pending_summary()), vim.log.levels.INFO)
end

local function add_pending_list_value(key, value)
  if not value then
    return false
  end
  local trimmed = vim.trim(value)
  if trimmed == "" then
    return false
  end
  local pending = ensure_pending_run()
  pending[key] = pending[key] or {}
  table.insert(pending[key], trimmed)
  return true
end

local function set_pending_option(key, value)
  local pending = ensure_pending_run()
  pending[key] = value
end

local function prompt_text(prompt_message, opts)
  vim.fn.inputsave()
  local ok, result = pcall(vim.fn.input, prompt_message, opts and opts.default or "")
  vim.fn.inputrestore()
  if not ok then
    return nil
  end
  result = vim.trim(result or "")
  if result == "" then
    return nil
  end
  return result
end

local function prompt_list(prompt_message)
  local text = prompt_text(prompt_message)
  if not text then
    return nil
  end
  local items = {}
  for _, chunk in ipairs(vim.split(text, ",", true)) do
    local trimmed = vim.trim(chunk)
    if trimmed ~= "" then
      table.insert(items, trimmed)
    end
  end
  if #items == 0 then
    return nil
  end
  return items
end

local function confirm_choice(prompt_message, default_yes)
  local default = default_yes and 1 or 2
  local choice = vim.fn.confirm(prompt_message, "&Yes\n&No", default)
  return choice == 1
end

local function normalize_string(value)
  if type(value) ~= "string" then
    return value
  end
  local trimmed = vim.trim(value)
  if trimmed == "" then
    return nil
  end
  return trimmed
end

local function default_generate_opts(opts)
  local resolved = opts and vim.tbl_extend("force", {}, opts) or {}
  resolved.intent = resolved.intent and vim.trim(resolved.intent) or resolved.intent
  if (not resolved.intent or resolved.intent == "") and resolved.prompt_for_intent then
    resolved.intent = vim.fn.input("Prompty intent: ")
  end

  apply_pending_options(resolved)

  resolved.model = normalize_string(resolved.model)
  resolved.context_template = normalize_string(resolved.context_template)
  resolved.smart_context_root = normalize_string(resolved.smart_context_root)


  if resolved.use_current_buffer then
    local buf_path = vim.api.nvim_buf_get_name(0)
    if buf_path and buf_path ~= "" and vim.fn.filereadable(buf_path) == 1 then
      resolved.context = resolved.context or {}
      table.insert(resolved.context, buf_path)
    end
    resolved.use_current_buffer = nil
  end

  if resolved.snippet and resolved.snippet ~= "" then
    local snippet_path = create_temp_file("intent", resolved.snippet)
    if snippet_path then
      resolved.context = resolved.context or {}
      table.insert(resolved.context, snippet_path)
    end
    resolved.snippet = nil
  end

  return resolved
end

function M.add_current_buffer_context()
  local buf_path = vim.api.nvim_buf_get_name(0)
  if not buf_path or buf_path == "" then
    ui.notify("Prompty: current buffer has no file path", vim.log.levels.WARN)
    return
  end
  if vim.fn.filereadable(buf_path) == 0 then
    ui.notify("Prompty: save the current buffer before adding it as context", vim.log.levels.WARN)
    return
  end
  if add_pending_list_value("context", buf_path) then
    notify_pending_update("Added current buffer to Prompty context queue")
  end
end

function M.configure_context()
  local menu = {
    {
      id = "context",
      label = "Add file/glob (--context)",
      action = function()
        local path = prompt_text("Context file or glob: ")
        if not path then
          return
        end
        path = vim.fn.expand(path)
        if add_pending_list_value("context", path) then
          notify_pending_update("Added context path")
        end
      end,
    },
    {
      id = "url",
      label = "Add URL (--url)",
      action = function()
        local url = prompt_text("Context URL: ")
        if url and add_pending_list_value("urls", url) then
          notify_pending_update("Added context URL")
        end
      end,
    },
    {
      id = "image",
      label = "Add image (--image)",
      action = function()
        local image = prompt_text("Image path: ")
        if image then
          image = vim.fn.expand(image)
        end
        if image and add_pending_list_value("images", image) then
          notify_pending_update("Added image path")
        end
      end,
    },
    {
      id = "video",
      label = "Add video (--video)",
      action = function()
        local video = prompt_text("Video path: ")
        if video then
          video = vim.fn.expand(video)
        end
        if video and add_pending_list_value("videos", video) then
          notify_pending_update("Added video path")
        end
      end,
    },
    {
      id = "buffer",
      label = "Use current buffer file",
      action = function()
        M.add_current_buffer_context()
      end,
    },
    {
      id = "template",
      label = "Set context template",
      action = function()
        local template = prompt_text("Context template slug: ")
        if template then
          set_pending_option("context_template", template)
          notify_pending_update("Set context template")
        end
      end,
    },
    {
      id = "smart",
      label = "Toggle smart context",
      action = function()
        local pending = ensure_pending_run()
        local enable = confirm_choice("Enable smart context?", pending.smart_context == true)
        if enable then
          set_pending_option("smart_context", true)
          local root = prompt_text(
            "Smart context root (blank = current dir): ",
            { default = pending.smart_context_root or "" }
          )
          if root then
            set_pending_option("smart_context_root", root)
          else
            set_pending_option("smart_context_root", "")
          end
          notify_pending_update("Smart context enabled")
        else
          set_pending_option("smart_context", false)
          set_pending_option("smart_context_root", "")
          notify_pending_update("Smart context disabled")
        end

      end,
    },
    {
      id = "summary",
      label = "Show pending summary",
      action = function()
        ui.notify("Prompty pending context: " .. pending_summary(), vim.log.levels.INFO)
      end,
    },
    {
      id = "clear",
      label = "Clear pending context",
      action = function()
        clear_pending_run()
        ui.notify("Prompty pending context cleared", vim.log.levels.INFO)
      end,
    },
    { id = "done", label = "Done" },
  }

  local function loop()
    vim.ui.select(menu, {
      prompt = "Prompty context options",
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice or choice.id == "done" then
        ui.notify("Prompty pending context: " .. pending_summary(), vim.log.levels.INFO)
        return
      end
      if choice.action then
        choice.action()
      end
      loop()
    end)
  end

  loop()
end

function M.prompt_with_flags()
  local opts = { prompt_for_intent = true }

  local model = prompt_text("Model (--model): ")
  if model then
    opts.model = model
  end

  local template = prompt_text("Context template (--context-template): ")
  if template then
    opts.context_template = template
  end

  local contexts = prompt_list("Context files/globs (comma separated): ")
  if contexts then
    opts.context = contexts
  end

  local urls = prompt_list("Context URLs (comma separated): ")
  if urls then
    opts.urls = urls
  end

  local images = prompt_list("Image paths (comma separated): ")
  if images then
    opts.images = images
  end

  local videos = prompt_list("Video paths (comma separated): ")
  if videos then
    opts.videos = videos
  end

  if confirm_choice("Enable smart context for this run?", false) then
    opts.smart_context = true
    local root = prompt_text("Smart context root (blank = current dir): ")
    if root then
      opts.smart_context_root = root
    end
  end

  if confirm_choice("Use current buffer as context?", false) then
    opts.use_current_buffer = true
  end

  local snippet = prompt_text("Inline context snippet (optional): ")
  if snippet then
    opts.snippet = snippet
  end

  M.generate(opts)
end


local function default_save_path()
  return string.format('prompty-%s.md', os.date('%Y%m%d-%H%M%S'))
end

local function load_history_entries(limit)
  local conf = config.get()
  local history_file = conf.history_file
  if not history_file or history_file == '' then
    return nil, 'History file path is not configured'
  end
  history_file = vim.fn.expand(history_file)
  if vim.fn.filereadable(history_file) == 0 then
    return {}, string.format('History file not found at %s', history_file)
  end
  local ok, lines_or_err = pcall(vim.fn.readfile, history_file)
  if not ok then
    return nil, lines_or_err
  end
  local lines = lines_or_err
  if limit and #lines > limit then
    lines = { unpack(lines, #lines - limit + 1, #lines) }
  end
  local entries = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= '' then
      local ok_decode, entry = pcall(vim.json.decode, trimmed, {
        luanil = { object = true, array = true },
      })
      if ok_decode and type(entry) == 'table' then
        table.insert(entries, entry)
      end
    end
  end
  return entries
end

local function history_entry_text(entry)
  if not entry then
    return nil
  end
  local text = first_string(
    entry.renderedPrompt,
    entry.rendered_prompt,
    entry.polishedPrompt,
    entry.polished_prompt,
    entry.prompt,
    entry.content
  )
  if text then
    return text
  end
  local result = entry.result
  if type(result) == 'table' then
    return first_string(
      result.renderedPrompt,
      result.rendered_prompt,
      result.polishedPrompt,
      result.polished_prompt,
      result.prompt,
      result.content
    )
  end
  return nil
end

local function format_history_label(entry)
  local timestamp = entry and entry.timestamp or ''
  if timestamp ~= '' then
    timestamp = timestamp:gsub('T', ' '):sub(1, 19)
  else
    timestamp = os.date('%Y-%m-%d %H:%M')
  end
  local intent = entry and entry.intent or ''
  if intent == '' then
    local text = history_entry_text(entry) or ''
    intent = vim.trim(text):sub(1, 48)
  end
  if intent == '' then
    intent = '[unknown intent]'
  end
  return string.format('%s — %s', timestamp, intent)
end

function M.save_output(opts)
  opts = opts or {}
  local path = opts.path
  if not path or path == '' then
    path = default_save_path()
  end
  path = vim.fn.expand(path)
  path = vim.fn.fnamemodify(path, ':p')
  if vim.fn.filereadable(path) == 1 and not opts.force then
    local choice = vim.fn.confirm(string.format('File %s exists. Overwrite?', path), '&Yes\\n&No', 2)
    if choice ~= 1 then
      ui.notify('Prompty save cancelled', vim.log.levels.INFO)
      return false
    end
  end

  local ok, err = ui.write_output_to(path)
  if not ok then
    ui.notify(err or 'Failed to save Prompty output', vim.log.levels.ERROR)
    return false
  end
  ui.notify('Prompty output saved to ' .. path, vim.log.levels.INFO)
  return true
end

function M.copy_output()
  local ok, err = ui.copy_output_to_clipboard()
  if not ok then
    ui.notify(err or 'Prompty output buffer is empty', vim.log.levels.WARN)
    return false
  end
  ui.notify('Prompty output copied to clipboard', vim.log.levels.INFO)
  return true
end

function M.open_output_scratch()
  local ok, err = ui.open_output_in_scratch()
  if not ok then
    ui.notify(err or 'Prompty output buffer is empty', vim.log.levels.WARN)
    return false
  end
  return true
end

function M.show_history(opts)
  opts = opts or {}
  local limit = opts.limit or 50
  local entries, err = load_history_entries(limit)
  if not entries then
    ui.notify('Prompty history error: ' .. err, vim.log.levels.WARN)
    return
  end
  if vim.tbl_isempty(entries) then
    ui.notify('Prompty history is empty', vim.log.levels.INFO)
    return
  end
  local items = {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    table.insert(items, { label = format_history_label(entry), entry = entry })
  end
  vim.ui.select(items, {
    prompt = 'Prompty history',
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    local text = history_entry_text(choice.entry)
    if not text then
      ui.notify('Selected history entry has no prompt text', vim.log.levels.WARN)
      return
    end
    local intent = choice.entry.intent or '[history]'
    ui.render_prompt(intent, text)
  end)
end

function M.active_session()
  return M._session
end

function M.setup(opts)
  local cfg = config.setup(opts)
  M._configured = true
  if cfg.keymaps then
    if cfg.keymaps.prompt and cfg.keymaps.prompt ~= "" then
      vim.keymap.set("n", cfg.keymaps.prompt, function()
        vim.cmd("Prompty")
      end, { desc = "Prompty: open prompt", silent = true })
    end
    if cfg.keymaps.prompt_visual and cfg.keymaps.prompt_visual ~= "" then
      vim.keymap.set("v", cfg.keymaps.prompt_visual, function()
        local intent = M.capture_visual_intent()
        M.generate({ intent = intent })
      end, { desc = "Prompty: prompt from selection", silent = true })
    end
    if cfg.keymaps.refine and cfg.keymaps.refine ~= "" then
      vim.keymap.set("n", cfg.keymaps.refine, function()
        vim.cmd("PromptyRefine")
      end, { desc = "Prompty: send refine", silent = true })
    end
    if cfg.keymaps.finish and cfg.keymaps.finish ~= "" then
      vim.keymap.set("n", cfg.keymaps.finish, function()
        vim.cmd("PromptyFinish")
      end, { desc = "Prompty: finish session", silent = true })
    end
  end
  return cfg
end

function M.ensure_setup()
  if not M._configured then
    M.setup()
  end
end

local function spawn_session(intent, opts)
  local handlers = {
    event = function(session, event)
      run_safe(handle_event, session, event)
    end,
    stderr = function(_, data)
      if data and data ~= "" then
        run_safe(function()
          ui.notify(vim.trim(data), vim.log.levels.ERROR)
        end)
      end
    end,
    exit = function(session, code, signal)
      run_safe(function()
        cancel_auto_finish(session)
        if M._session ~= session then
          return
        end
        if code ~= 0 then
          local message = string.format("Prompty exited (code %s, signal %s)", code or "?", signal or "?")
          set_session_state(session, SESSION_STATES.ERRORED, {
            message = message,
            level = vim.log.levels.WARN,
          })
        else
          ui.notify("Prompty session finished", vim.log.levels.INFO)
          set_session_state(session, SESSION_STATES.FINISHED, { message = "Prompty session finished" })
        end
        ui.clear_progress()
        M._session = nil
      end)
    end,
    transport_ready = function(session)
      run_safe(function()
        if M._session == session then
          open_refine_if_needed()
        end
      end)
    end,
  }

  local session, err = client.start(vim.tbl_extend("force", opts or {}, {
    intent = intent,
    handlers = handlers,
  }))

  if not session then
    ui.notify(err or "Failed to start prompt-maker-cli", vim.log.levels.ERROR)
    return nil
  end

  attach_session(session, intent)
  return session
end

function M.generate(opts)
  opts = default_generate_opts(opts)
  local intent = opts and opts.intent

  if not intent or intent == "" then
    ui.notify("Prompty: intent text is required", vim.log.levels.WARN)
    return
  end

  if M._session then
    stop_current_session()
  end

  local session = spawn_session(intent, opts)
  if session then
    consume_pending_run()
  end
end

function M.refine(arg)
  local session = M.active_session()
  if not session then
    ui.notify("No active Prompty session", vim.log.levels.WARN)
    return
  end

  local text = arg
  if text then
    text = vim.trim(text)
  end
  if not text or text == "" then
    text = ui.consume_refine_text()
  end
  text = text or ""
  local trimmed = vim.trim(text)

  if trimmed == "" then
    if session._awaiting_input then
      text = "Continue."
      ui.notify("Continuing without new instructions", vim.log.levels.INFO)
    else
      ui.notify("No refinement instruction provided", vim.log.levels.WARN)
      ui.set_refine_hint(DEFAULT_REFINE_HINT)
      return
    end
  end

  cancel_auto_finish(session)
  local ok, err = session:send_refine(text)
  if not ok then
    ui.notify("Unable to send refine: " .. err, vim.log.levels.ERROR)
    return
  end

  session._has_refined = true
  session._awaiting_input = false
  ui.set_refine_hint(DEFAULT_REFINE_HINT)
  set_session_state(session, SESSION_STATES.RUNNING, { message = "Sent refinement" })
  ui.notify("Sent refinement to prompt-maker-cli", vim.log.levels.INFO)
end

function M.finish()
  local session = M.active_session()
  if not session then
    ui.notify("No active Prompty session", vim.log.levels.WARN)
    return
  end
  local ok = request_finish(session, { message = "Finishing Prompty session..." })
  if ok then
    ui.notify("Sent finish command to prompt-maker-cli", vim.log.levels.INFO)
  end
end

function M.capture_visual_intent()
  return ui.capture_visual_selection()
end

return M
