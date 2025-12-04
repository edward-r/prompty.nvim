---@diagnostic disable-next-line: undefined-global
local vim = vim

local config = require("prompty.config")
local client = require("prompty.client")
local ui = require("prompty.ui")

local M = {
  _session = nil,
}

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

local function handle_event(_, event)
  if not event or not event.type then
    return
  end

  local payload = event.payload or event.data or {}
  if event.type == "generation.iteration.complete" or event.type == "generation.final" then
    local text = payload.text or payload.delta or payload.content
    if text and text ~= "" then
      ui.append_markdown(text)
    end
    if event.type == "generation.final" then
      ui.clear_progress()
    end
  elseif event.type == "progress.update" then
    ui.show_progress(summarize_progress(payload))
  elseif event.type == "context.telemetry" then
    ui.show_telemetry(payload)
  elseif event.type == "transport.listening" then
    ui.show_progress("Interactive transport ready")
  end
end

local function attach_session(session, intent)
  ui.open_output_window()
  local buf = ui.reset_output(intent)
  ui.attach_session_cleanup(buf, session)
  session._refine_ready = false
  M._session = session
end

local function open_refine_if_needed()
  local session = M._session
  if not session or session._refine_ready then
    return
  end
  session._refine_ready = true
  ui.open_refine_window()
  ui.notify("Prompty transport ready. Type refinements and run :PromptyRefine", vim.log.levels.INFO)
end

local function default_generate_opts(opts)
  local resolved = opts and vim.tbl_extend("force", {}, opts) or {}
  resolved.intent = resolved.intent and vim.trim(resolved.intent) or resolved.intent
  if (not resolved.intent or resolved.intent == "") and resolved.prompt_for_intent then
    resolved.intent = vim.fn.input("Prompty intent: ")
  end
  return resolved
end

function M.active_session()
  return M._session
end

function M.setup(opts)
  local cfg = config.setup(opts)
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
  end
  return cfg
end

local function spawn_session(intent, opts)
  local handlers = {
    event = function(session, event)
      handle_event(session, event)
    end,
    stderr = function(_, data)
      if data and data ~= "" then
        ui.notify(vim.trim(data), vim.log.levels.ERROR)
      end
    end,
    exit = function(_, code, signal)
      if code ~= 0 then
        ui.notify(string.format("Prompty exited (code %s, signal %s)", code or "?", signal or "?"), vim.log.levels.WARN)
      else
        ui.notify("Prompty session finished", vim.log.levels.INFO)
      end
      ui.clear_progress()
      M._session = nil
    end,
    transport_ready = function()
      open_refine_if_needed()
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
    M._session:stop()
    M._session = nil
  end

  spawn_session(intent, opts)
end

function M.refine(arg)
  local session = M.active_session()
  if not session then
    ui.notify("No active Prompty session", vim.log.levels.WARN)
    return
  end

  local text = arg and vim.trim(arg)
  if not text or text == "" then
    text = ui.consume_refine_text()
  end

  if not text or text == "" then
    ui.notify("No refinement instruction provided", vim.log.levels.WARN)
    return
  end

  local ok, err = session:send_refine(text)
  if not ok then
    ui.notify("Unable to send refine: " .. err, vim.log.levels.ERROR)
  else
    ui.notify("Sent refinement to prompt-maker-cli", vim.log.levels.INFO)
  end
end

function M.finish()
  local session = M.active_session()
  if not session then
    ui.notify("No active Prompty session", vim.log.levels.WARN)
    return
  end
  local ok, err = session:finish()
  if not ok then
    ui.notify("Unable to finish session: " .. err, vim.log.levels.ERROR)
  end
end

function M.capture_visual_intent()
  return ui.capture_visual_selection()
end

return M
