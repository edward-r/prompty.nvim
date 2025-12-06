---@diagnostic disable-next-line: undefined-global
local vim = vim

local uv = vim.uv

local config = require("prompty.config")

local Session = {}
Session.__index = Session

local M = {}

local function make_session_id()
  return string.format("%x", uv.hrtime())
end

local function ensure_socket_path(conf, provided, session_id)
  local function ensure_dir(path)
    if not path or path == "" then
      return
    end
    pcall(vim.fn.mkdir, path, "p")
  end

  if provided and provided ~= "" then
    ensure_dir(vim.fs.dirname(provided))
    return provided
  end
  local dir = conf.temp_dir or vim.fs.joinpath(vim.fn.stdpath("run"), "prompty")
  ensure_dir(dir)
  local path = vim.fs.joinpath(dir, string.format("prompty-%s.sock", session_id or make_session_id()))
  return path
end

function Session:_emit(handler_name, ...)
  local handler = self.handlers and self.handlers[handler_name]
  if handler then
    handler(self, ...)
  end
end

function Session:_cleanup_socket()
  local transport = self.transport
  if transport then
    if transport.read_stop then
      pcall(transport.read_stop, transport)
    end
    if not transport:is_closing() then
      transport:shutdown(function()
        if not transport:is_closing() then
          transport:close()
        end
      end)
    else
      transport:close()
    end
  end
  self.transport = nil

  if self.socket_path then
    pcall(uv.fs_unlink, self.socket_path)
    self.socket_path = nil
  end
  self.transport_path = nil
end

function Session:stop()
  if self.proc and self.proc.kill then
    pcall(self.proc.kill, self.proc, "sigterm")
    self.proc = nil
  end
  self:_cleanup_socket()
end

function Session:is_transport_ready()
  return self.transport ~= nil and not self.transport:is_closing()
end

function Session:_connect_transport(path)
  if self.transport or not self.interactive then
    return
  end

  local pipe = uv.new_pipe(false)
  pipe:connect(path, function(err)
    if err then
      self:_emit("stderr", string.format("Prompty transport error: %s", err))
      self:_emit("event", {
        type = "transport.error",
        payload = { message = err, path = path },
      })
      return
    end
    self.transport = pipe
    self.transport_path = path
    pipe:read_start(function(read_err, chunk)
      if read_err then
        self:_emit("stderr", string.format("Prompty transport read error: %s", read_err))
        self:_emit("event", {
          type = "transport.error",
          payload = { message = read_err, path = path },
        })
        pipe:read_stop()
        return
      end
      if not chunk then
        pipe:read_stop()
        self:_cleanup_socket()
        self:_emit("event", {
          type = "transport.client.disconnected",
          payload = { path = path },
        })
        return
      end
      -- Ignore data coming from the interactive transport to avoid duplicate events
    end)
    self:_emit("transport_ready", path)
  end)
end

function Session:send(payload)
  if not self:is_transport_ready() then
    return false, "interactive transport is not ready"
  end
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return false, encoded
  end
  self.transport:write(encoded .. "\n")
  return true
end

function Session:send_refine(text)
  local instruction = vim.trim(text or "")
  if instruction == "" then
    return false, "instruction cannot be empty"
  end
  return self:send({ type = "refine", instruction = instruction })
end

function Session:finish()
  return self:send({ type = "finish" })
end

function Session:_handle_stdout(chunk)
  if not chunk or chunk == "" then
    return
  end

  self.stdout_buf = (self.stdout_buf or "") .. chunk
  while true do
    local nl = self.stdout_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self.stdout_buf:sub(1, nl - 1)
    self.stdout_buf = self.stdout_buf:sub(nl + 1)
    self:_process_line(line)
  end
end

function Session:_process_line(line)
  local trimmed = vim.trim(line or "")
  if trimmed == "" then
    return
  end

  local ok, event = pcall(vim.json.decode, trimmed, {
    luanil = {
      object = true,
      array = true,
    },
  })
  if not ok then
    self:_emit("stderr", string.format("Prompty: failed to decode event (%s)", trimmed))
    return
  end

  if type(event) ~= "table" then
    return
  end

  event.type = event.type or event.event

  local payload = event.payload or event.data
  if type(payload) ~= "table" then
    payload = nil
  end
  event.payload = payload or event
  event.data = event.data or event.payload

  if type(event.telemetry) == "table" and event.payload.telemetry == nil then
    event.payload.telemetry = event.telemetry
  end

  if event.type == "transport.listening" then
    local listening_payload = event.payload or {}
    local path = listening_payload.path or self.socket_path
    if path then
      self:_connect_transport(path)
    end
  end

  self:_emit("event", event)
end

local function build_command(conf, opts, session_id)
  local binary = opts.binary or conf.binary or "prompt-maker-cli"
  if vim.fn.executable(binary) == 0 then
    return nil, string.format("Prompty binary '%s' not found in PATH", binary)
  end

  local interactive = opts.interactive ~= false
  local cmd = { binary }

  if opts.intent and opts.intent ~= "" then
    table.insert(cmd, opts.intent)
  end

  table.insert(cmd, "--quiet")
  table.insert(cmd, "--stream")
  table.insert(cmd, "jsonl")

  if not interactive then
    table.insert(cmd, "--json")
  end

  if type(conf.default_flags) == "table" and #conf.default_flags > 0 then
    vim.list_extend(cmd, conf.default_flags)
  end

  if type(opts.flags) == "table" and #opts.flags > 0 then
    vim.list_extend(cmd, opts.flags)
  end

  if type(opts.context) == "table" then
    for _, ctx in ipairs(opts.context) do
      table.insert(cmd, "--context")
      table.insert(cmd, ctx)
    end
  end

  if type(opts.urls) == "table" then
    for _, url in ipairs(opts.urls) do
      table.insert(cmd, "--url")
      table.insert(cmd, url)
    end
  end

  if opts.smart_context then
    table.insert(cmd, "--smart-context")
  end

  local socket_path
  if interactive then
    socket_path = ensure_socket_path(conf, opts.socket_path, session_id)
    if socket_path then
      pcall(uv.fs_unlink, socket_path)
    end
    table.insert(cmd, "--interactive-transport")
    table.insert(cmd, socket_path)

    local filtered = {}
    for _, arg in ipairs(cmd) do
      if arg ~= "--json" then
        table.insert(filtered, arg)
      end
    end
    cmd = filtered
  end

  return cmd, socket_path
end

function M.start(opts)
  opts = opts or {}
  local conf = config.get()
  local session_id = make_session_id()
  local cmd, socket_path_or_err = build_command(conf, opts, session_id)
  if not cmd then
    return nil, socket_path_or_err or "Prompty: unable to build CLI command"
  end
  local socket_path = socket_path_or_err

  local session = setmetatable({
    id = session_id,
    handlers = opts.handlers or {},
    stdout_buf = "",
    socket_path = socket_path,
    interactive = socket_path ~= nil,
  }, Session)

  session.proc = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if err then
        session:_emit("stderr", err)
        return
      end
      if data then
        session:_handle_stdout(data)
      end
    end,
    stderr = function(err, data)
      if err then
        session:_emit("stderr", err)
        return
      end
      if data and data ~= "" then
        session:_emit("stderr", data)
      end
    end,
  }, function(res)
    session.exited = true
    session:_cleanup_socket()
    session:_emit("exit", res.code, res.signal)
  end)

  if not session.proc then
    return nil, "Prompty: failed to spawn CLI"
  end

  return session
end

return M
