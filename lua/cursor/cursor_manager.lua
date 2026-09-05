local CursorManager = {}
CursorManager.__index = CursorManager

function CursorManager.new(opts)
  local self = setmetatable({}, CursorManager)

  opts = opts or {}

  -- ACP configuration (defaults to Cursor CLI `agent acp`)
  self.acp = opts.acp or {}
  if self.acp.enabled == nil then
    self.acp.enabled = true
  end
  self.acp.command = self.acp.command or 'agent'
  self.acp.args = self.acp.args or { 'acp' }
  self.acp.auth_method = self.acp.auth_method or 'cursor_login'

  self.model = opts.model or 'auto'
  self._config_options = nil

  -- JSON-RPC / ACP state
  self.proc_job_id = nil
  self.next_id = 1
  self.pending = {}
  self.session_id = nil
  self.initialized = false
  self.authenticated = false
  self.current_prompt_id = nil
  self._active_request = nil
  self._stdout_buffer = {}
  self.terminals = {}
  self.on_permission_request = opts.on_permission_request
  self.on_activity_update = opts.on_activity_update
  self.on_file_write = opts.on_file_write
  self.on_file_read = opts.on_file_read
  self._last_activity_line = nil
  self._permission_queue = {}
  self._permission_in_progress = false

  return self
end

function CursorManager:_ensure_acp_process()
  if self.proc_job_id and self.proc_job_id > 0 then
    return true
  end

  if not self:_check_cursor_cli() then
    vim.notify('Cursor ACP CLI (`agent`) not found. Install Cursor and ensure `agent` is in PATH.', vim.log.levels.ERROR)
    return false
  end

  local cmd = { self.acp.command }
  local model = self.model
  if model and model ~= '' and model ~= 'auto' then
    table.insert(cmd, '--model')
    table.insert(cmd, model)
  end
  for _, arg in ipairs(self.acp.args or { 'acp' }) do
    table.insert(cmd, arg)
  end

  self.proc_job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    stdin = 'pipe',
    on_stdout = function(_, data, _)
      if not data or #data == 0 then
        return
      end

      for _, line in ipairs(data) do
        if line and line ~= '' then
          local ok, msg = pcall(vim.json.decode, line)
          if ok and msg then
            self:_handle_message(msg)
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      if data and #data > 0 then
        local msg = table.concat(data, '\n')
        if msg and msg ~= '' then
          vim.notify('Cursor ACP stderr: ' .. msg, vim.log.levels.WARN)
        end
      end
    end,
    on_exit = function(_, _exit_code, _)
      self.proc_job_id = nil
      self.initialized = false
      self.authenticated = false
      self.session_id = nil
      self.current_prompt_id = nil
      self.pending = {}
      self._active_request = nil
    end,
  })

  if self.proc_job_id <= 0 then
    vim.notify('Failed to start Cursor ACP CLI. Make sure `agent` is installed and in PATH.', vim.log.levels.ERROR)
    self.proc_job_id = nil
    return false
  end

  return true
end

function CursorManager:_send_json(obj)
  if not (self.proc_job_id and self.proc_job_id > 0) then
    return
  end
  local ok, encoded = pcall(vim.json.encode, obj)
  if not ok or not encoded then
    return
  end
  vim.fn.chansend(self.proc_job_id, encoded .. '\n')
end

function CursorManager:_send_request(method, params, on_result)
  if not self:_ensure_acp_process() then
    return nil
  end

  local id = self.next_id
  self.next_id = self.next_id + 1

  if on_result then
    self.pending[id] = on_result
  end

  self:_send_json({
    jsonrpc = '2.0',
    id = id,
    method = method,
    params = params or {},
  })

  return id
end

function CursorManager:_send_response(id, result)
  if not id then
    return
  end
  self:_send_json({
    jsonrpc = '2.0',
    id = id,
    result = result,
  })
end

function CursorManager:_handle_message(msg)
  if msg.id and (msg.result or msg.error) then
    local cb = self.pending[msg.id]
    self.pending[msg.id] = nil
    if cb then
      cb(msg.result, msg.error)
    end
    return
  end

  if msg.method == 'session/update' and msg.params and msg.params.update then
    self:_handle_session_update(msg.params.update)
    return
  end

  if msg.method == 'session/request_permission' then
    self:_handle_request_permission(msg.id, msg.params)
    return
  end

  if msg.method == 'fs/read_text_file' or msg.method == 'fs/readTextFile' then
    self:_handle_fs_read_text_file(msg.id, msg.params)
    return
  end

  if msg.method == 'fs/write_text_file' or msg.method == 'fs/writeTextFile' then
    self:_handle_fs_write_text_file(msg.id, msg.params)
    return
  end

  if msg.method == 'terminal/create' then
    self:_handle_terminal_create(msg.id, msg.params)
    return
  end

  if msg.method == 'terminal/output' then
    self:_handle_terminal_output(msg.id, msg.params)
    return
  end

  if msg.method == 'terminal/wait_for_exit' then
    self:_handle_terminal_wait_for_exit(msg.id, msg.params)
    return
  end

  if msg.method == 'terminal/kill' then
    self:_handle_terminal_kill(msg.id, msg.params)
    return
  end

  if msg.method == 'terminal/release' then
    self:_handle_terminal_release(msg.id, msg.params)
    return
  end

  -- Ignore other notifications and Cursor extension methods for now
end

function CursorManager:_handle_fs_read_text_file(id, params)
  if not id then
    return
  end

  local path = params and params.path or nil
  local line = params and params.line or nil
  local limit = params and params.limit or nil

  if not path or path == '' then
    self:_send_response(id, { content = '' })
    return
  end

  local on_file_read = self.on_file_read
  if type(on_file_read) == 'function' then
    pcall(on_file_read, path)
  end

  local content_lines = nil

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buf_path = vim.api.nvim_buf_get_name(bufnr)
      if buf_path == path then
        content_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        break
      end
    end
  end

  if not content_lines then
    if vim.fn.filereadable(path) ~= 1 then
      self:_send_response(id, { content = '' })
      return
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or not lines then
      self:_send_response(id, { content = '' })
      return
    end
    content_lines = lines
  end

  local start_idx = 1
  if type(line) == 'number' and line > 0 then
    start_idx = line
  end

  local end_idx = #content_lines
  if type(limit) == 'number' and limit > 0 then
    end_idx = math.min(end_idx, start_idx + limit - 1)
  end

  local slice = {}
  for i = start_idx, end_idx do
    if content_lines[i] == nil then
      break
    end
    table.insert(slice, content_lines[i])
  end

  local content = table.concat(slice, '\n')
  if content ~= '' then
    content = content .. '\n'
  end

  self:_send_response(id, { content = content })
end

function CursorManager:_handle_fs_write_text_file(id, params)
  if not id then
    return
  end

  local path = params and params.path or nil
  local content = params and params.content or ''

  if not path or path == '' then
    self:_send_response(id, vim.NIL)
    return
  end

  local on_file_write = self.on_file_write
  if type(on_file_write) == 'function' then
    pcall(on_file_write, path)
  end

  local lines = {}
  for line in tostring(content):gmatch('[^\r\n]+') do
    table.insert(lines, line)
  end
  if #lines == 0 then
    lines = { '' }
  end

  pcall(function()
    vim.fn.writefile(lines, path)
  end)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buf_path = vim.api.nvim_buf_get_name(bufnr)
      if buf_path == path then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        break
      end
    end
  end

  self:_send_response(id, vim.NIL)
end

function CursorManager:_handle_terminal_create(id, params)
  if not id then
    return
  end

  local command = params and params.command or nil
  local args = params and params.args or {}
  local cwd = params and params.cwd or nil
  local env_param = params and params.env or {}
  local output_byte_limit = params and params.outputByteLimit or 1048576

  if not command or command == '' then
    self:_send_response(id, { terminalId = nil })
    return
  end

  local cmd = { command }
  if type(args) == 'table' then
    for _, a in ipairs(args) do
      table.insert(cmd, a)
    end
  end

  local env = nil
  if type(env_param) == 'table' then
    env = {}
    for _, pair in ipairs(env_param) do
      if pair.name and pair.value then
        env[pair.name] = pair.value
      end
    end
  end

  local term_id = 'term_' .. tostring(self.next_id)
  self.next_id = self.next_id + 1

  local state = {
    id = term_id,
    output = '',
    truncated = false,
    exit_status = { exitCode = nil, signal = nil },
    byte_limit = output_byte_limit,
    waiters = {},
  }

  local function append_output(chunk)
    if not chunk or chunk == '' then
      return
    end
    local new_output = state.output .. chunk
    if #new_output > state.byte_limit then
      local excess = #new_output - state.byte_limit
      new_output = new_output:sub(excess + 1)
      state.truncated = true
    end
    state.output = new_output
  end

  local job_opts = {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data, _)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= '' then
          append_output(line .. '\n')
        end
      end
    end,
    on_stderr = function(_, data, _)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= '' then
          append_output(line .. '\n')
        end
      end
    end,
    on_exit = function(_, exit_code, _)
      state.exit_status.exitCode = exit_code
      state.exit_status.signal = nil
      if state.waiters then
        for _, waiter_id in ipairs(state.waiters) do
          self:_send_response(waiter_id, {
            exitCode = state.exit_status.exitCode,
            signal = state.exit_status.signal,
          })
        end
        state.waiters = {}
      end
    end,
  }

  if cwd and cwd ~= '' then
    job_opts.cwd = cwd
  end
  if env then
    job_opts.env = env
  end

  local job_id = vim.fn.jobstart(cmd, job_opts)
  if job_id <= 0 then
    self:_send_response(id, { terminalId = nil })
    return
  end

  state.job_id = job_id
  self.terminals[term_id] = state

  self:_send_response(id, { terminalId = term_id })
end

function CursorManager:_handle_terminal_output(id, params)
  if not id then
    return
  end

  local terminal_id = params and params.terminalId or nil
  if not terminal_id then
    self:_send_response(id, {
      output = '',
      truncated = false,
      exitStatus = nil,
    })
    return
  end

  local state = self.terminals[terminal_id]
  if not state then
    self:_send_response(id, {
      output = '',
      truncated = false,
      exitStatus = nil,
    })
    return
  end

  self:_send_response(id, {
    output = state.output or '',
    truncated = state.truncated or false,
    exitStatus = state.exit_status,
  })
end

function CursorManager:_handle_terminal_wait_for_exit(id, params)
  if not id then
    return
  end

  local terminal_id = params and params.terminalId or nil
  if not terminal_id then
    self:_send_response(id, {
      exitCode = nil,
      signal = nil,
    })
    return
  end

  local state = self.terminals[terminal_id]
  if not state then
    self:_send_response(id, {
      exitCode = nil,
      signal = nil,
    })
    return
  end

  if state.exit_status and state.exit_status.exitCode ~= nil then
    self:_send_response(id, {
      exitCode = state.exit_status.exitCode,
      signal = state.exit_status.signal,
    })
    return
  end

  state.waiters = state.waiters or {}
  table.insert(state.waiters, id)
end

function CursorManager:_handle_terminal_kill(id, params)
  if not id then
    return
  end

  local terminal_id = params and params.terminalId or nil
  if not terminal_id then
    self:_send_response(id, vim.NIL)
    return
  end

  local state = self.terminals[terminal_id]
  if state and state.job_id and state.job_id > 0 then
    vim.fn.jobstop(state.job_id)
  end

  self:_send_response(id, vim.NIL)
end

function CursorManager:_handle_terminal_release(id, params)
  if not id then
    return
  end

  local terminal_id = params and params.terminalId or nil
  if not terminal_id then
    self:_send_response(id, vim.NIL)
    return
  end

  local state = self.terminals[terminal_id]
  if state and state.job_id and state.job_id > 0 then
    vim.fn.jobstop(state.job_id)
  end

  self.terminals[terminal_id] = nil
  self:_send_response(id, vim.NIL)
end

function CursorManager:_handle_session_update(update)
  if not self._active_request or not update then
    return
  end

  self:_notify_activity_update(update)

  local update_type = update.sessionUpdate or update.type
  if update_type ~= 'agent_message_chunk' then
    return
  end

  local content = update.content or {}
  local text = ''
  if type(content) == 'table' then
    if content.text and type(content.text) == 'string' then
      text = content.text
    elseif content.type == 'text' and content.value then
      text = content.value
    end
  elseif type(content) == 'string' then
    text = content
  end

  if text == '' then
    return
  end

  local current = self._active_request.content or ''
  current = current .. text
  self._active_request.content = current

  local cb = self._active_request.callback
  if cb and current ~= self._active_request.last_stream_content then
    self._active_request.last_stream_content = current
    local changes = self._active_request.changes or {}
    vim.schedule(function()
      cb(current, changes, true)
    end)
  end
end

function CursorManager:_format_activity_update(update)
  if type(update) ~= 'table' then
    return nil
  end

  local function trim_text(value, max_len)
    if type(value) ~= 'string' then
      return nil
    end
    local compact = value:gsub('%s+', ' ')
    if compact == '' then
      return nil
    end
    if #compact > max_len then
      return compact:sub(1, max_len - 3) .. '...'
    end
    return compact
  end

  local function first_text(tbl)
    if type(tbl) ~= 'table' then
      return nil
    end

    if type(tbl.text) == 'string' and tbl.text ~= '' then
      return tbl.text
    end
    if type(tbl.title) == 'string' and tbl.title ~= '' then
      return tbl.title
    end
    if type(tbl.command) == 'string' and tbl.command ~= '' then
      return tbl.command
    end
    if type(tbl.commandLine) == 'string' and tbl.commandLine ~= '' then
      return tbl.commandLine
    end

    local content = tbl.content
    if type(content) == 'table' then
      if type(content.text) == 'string' and content.text ~= '' then
        return content.text
      end
      for _, item in ipairs(content) do
        if type(item) == 'table' then
          local nested = first_text(item)
          if nested and nested ~= '' then
            return nested
          end
        elseif type(item) == 'string' and item ~= '' then
          return item
        end
      end
    end

    return nil
  end

  local function first_path(tbl)
    if type(tbl) ~= 'table' then
      return nil
    end

    local path = tbl.path or tbl.file or tbl.filePath or tbl.target_file or tbl.targetPath
    if type(path) == 'string' and path ~= '' then
      return path
    end

    local params = tbl.params or tbl.arguments or tbl.args
    if type(params) == 'table' then
      return first_path(params)
    end

    local content = tbl.content
    if type(content) == 'table' then
      for _, item in ipairs(content) do
        if type(item) == 'table' then
          local nested_path = first_path(item)
          if nested_path and nested_path ~= '' then
            return nested_path
          end
        end
      end
    end

    return nil
  end

  local function first_cwd(tbl)
    if type(tbl) ~= 'table' then
      return nil
    end

    if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
      return tbl.cwd
    end

    local params = tbl.params or tbl.arguments or tbl.args
    if type(params) == 'table' then
      return first_cwd(params)
    end

    return nil
  end

  local tool_call = update.toolCall or update.tool_call
  if type(tool_call) == 'table' then
    local title = tool_call.title
    local kind = tool_call.kind
    local status = tool_call.status
    local text = nil

    if type(title) == 'string' and title ~= '' then
      text = title
    elseif type(kind) == 'string' and kind ~= '' then
      text = kind
    end

    if not text then
      text = first_text(tool_call)
    end

    local detail_parts = {}
    local path = first_path(tool_call)
    if path and path ~= '' then
      table.insert(detail_parts, 'file=' .. path)
    end

    local cwd = first_cwd(tool_call)
    if cwd == path then
      cwd = nil
    end
    if type(cwd) == 'string' and cwd ~= '' then
      table.insert(detail_parts, 'cwd=' .. cwd)
    end

    local reason = first_text({ content = tool_call.content, text = tool_call.reason })
    reason = trim_text(reason, 120)
    if reason and reason ~= '' and reason ~= text then
      table.insert(detail_parts, reason)
    end

    local prefix = 'Activity'
    if text and text ~= '' then
      prefix = 'Activity: ' .. trim_text(text, 120)
    end

    if status and type(status) == 'string' and status ~= '' then
      prefix = prefix .. ' (' .. status .. ')'
    end

    if #detail_parts > 0 then
      return prefix .. ' | ' .. table.concat(detail_parts, ' | ')
    end

    return prefix
  end

  local candidate = nil
  local path = update.path or update.file or update.filePath
  local status = update.status
  local update_type = update.sessionUpdate or update.type

  if type(path) == 'string' and path ~= '' then
    if update_type == 'file_edit' or update_type == 'file_update' or update_type == 'fs_write' then
      candidate = 'Editing file: ' .. path
    elseif update_type == 'fs_read' then
      candidate = 'Reading file: ' .. path
    else
      candidate = 'File activity: ' .. path
    end
  elseif type(update_type) == 'string' and update_type ~= '' and update_type ~= 'agent_message_chunk' then
    candidate = 'Activity: ' .. update_type
  end

  if candidate and type(status) == 'string' and status ~= '' then
    candidate = candidate .. ' (' .. status .. ')'
  end

  return candidate
end

function CursorManager:_notify_activity_update(update)
  local cb = self.on_activity_update
  if type(cb) ~= 'function' then
    return
  end

  local line = self:_format_activity_update(update)
  if not line or line == '' then
    return
  end

  if line == self._last_activity_line then
    return
  end
  self._last_activity_line = line
  local affected_files = self:_extract_activity_paths(update)

  vim.schedule(function()
    cb(line, update, affected_files)
  end)
end

function CursorManager:_extract_activity_paths(update)
  local paths = {}
  local seen = {}
  local function is_url_like(value)
    if type(value) ~= 'string' or value == '' then
      return false
    end
    if value:match('^https?://') or value:match('^//[%w%-]+%.') then
      return true
    end
    if value:match('^file://https?://') or value:match('://https?://') then
      return true
    end
    if value:match('https?://') then
      return true
    end
    return false
  end

  local function add_path(value)
    if type(value) ~= 'string' or value == '' then
      return
    end
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    value = value:gsub('^["\']+', ''):gsub('["\']+$', '')
    value = value:gsub('[,;:!?)%]}]+$', '')
    if value == '' or seen[value] then
      return
    end
    if is_url_like(value) then
      return
    end
    seen[value] = true
    table.insert(paths, value)
  end

  local function add_paths_from_text(text)
    if type(text) ~= 'string' or text == '' then
      return
    end

    -- Absolute/file URI paths
    for raw in text:gmatch('file://[%w%._%-%/%s]+') do
      add_path(raw)
    end
    for raw in text:gmatch('/[%w%._%-%/%s]+%.%w+') do
      add_path(raw)
    end

    -- Relative paths commonly seen in tool command strings
    for raw in text:gmatch('%.?/[%w%._%-%/%s]+%.%w+') do
      add_path(raw)
    end
    for raw in text:gmatch('[%w%._%-/]+%.%w+') do
      if raw:find('/') then
        if not raw:match('^[%w%-]+%.%w+') and not raw:match('^//') then
          add_path(raw)
        end
      end
    end
  end

  local function walk(tbl, depth)
    if type(tbl) ~= 'table' or depth > 5 then
      return
    end

    add_path(tbl.path)
    add_path(tbl.file)
    add_path(tbl.filePath)
    add_path(tbl.target_file)
    add_path(tbl.targetPath)

    for _, key in ipairs({ 'params', 'arguments', 'args', 'toolCall', 'tool_call', 'content', 'changes' }) do
      local value = tbl[key]
      if type(value) == 'table' then
        walk(value, depth + 1)
      elseif type(value) == 'string' then
        add_paths_from_text(value)
      end
    end

    for _, value in pairs(tbl) do
      if type(value) == 'table' then
        walk(value, depth + 1)
      elseif type(value) == 'string' then
        add_paths_from_text(value)
      end
    end
  end

  walk(update, 0)
  return paths
end

function CursorManager:_handle_request_permission(id, params)
  if not id then
    return
  end

  table.insert(self._permission_queue, {
    id = id,
    request = params or {},
  })
  self:_process_permission_queue()
end

function CursorManager:_process_permission_queue()
  if self._permission_in_progress then
    return
  end

  local item = table.remove(self._permission_queue, 1)
  if not item then
    return
  end

  self._permission_in_progress = true
  local id = item.id
  local request = item.request or {}
  local raw_options = request.options or {}
  local options = {}
  self:_notify_permission_request(request)

  local function finish_with_option(option_id)
    self:_send_response(id, {
      outcome = {
        outcome = 'selected',
        optionId = option_id,
      },
    })
    self._permission_in_progress = false
    self:_process_permission_queue()
  end

  local function normalize_option(opt, fallback_id)
    if type(opt) == 'string' then
      return {
        id = opt,
        label = opt,
      }
    end

    if type(opt) ~= 'table' then
      return nil
    end

    local option_id = opt.id or opt.optionId or fallback_id
    local label = opt.label or option_id or ''
    return {
      id = option_id,
      optionId = opt.optionId,
      label = label,
    }
  end

  if type(raw_options) == 'table' then
    local has_array_items = false
    for _, value in ipairs(raw_options) do
      has_array_items = true
      local normalized = normalize_option(value)
      if normalized then
        table.insert(options, normalized)
      end
    end

    if not has_array_items then
      for key, value in pairs(raw_options) do
        local fallback_id = type(key) == 'string' and key or nil
        local normalized = normalize_option(value, fallback_id)
        if normalized then
          table.insert(options, normalized)
        end
      end
    end
  end

  if #options > 1 then
    local preferred_order = {
      ['allow-once'] = 1,
      ['allow-always'] = 2,
      ['reject-once'] = 3,
    }
    table.sort(options, function(a, b)
      local a_id = a.id or a.optionId or ''
      local b_id = b.id or b.optionId or ''
      local a_rank = preferred_order[a_id] or 100
      local b_rank = preferred_order[b_id] or 100
      if a_rank == b_rank then
        local a_label = a.label or a_id
        local b_label = b.label or b_id
        return a_label < b_label
      end
      return a_rank < b_rank
    end)
  end

  if not vim.ui or not vim.ui.select or type(options) ~= 'table' or #options == 0 then
    finish_with_option('allow-once')
    return
  end

  local items = {}
  for _, opt in ipairs(options) do
    local label = opt.label or opt.id or opt.optionId or ''
    local id_or_option = opt.id or opt.optionId or ''
    if id_or_option ~= '' then
      table.insert(items, label .. ' [' .. id_or_option .. ']')
    else
      table.insert(items, label)
    end
  end

  local function choose_default_option()
    local reject_idx = nil
    local allow_once_idx = nil

    for idx, opt in ipairs(options) do
      local oid = opt.id or opt.optionId or ''
      if oid == 'reject-once' and not reject_idx then
        reject_idx = idx
      elseif oid == 'allow-once' and not allow_once_idx then
        allow_once_idx = idx
      end
    end

    if reject_idx then
      return options[reject_idx]
    end
    if allow_once_idx then
      return options[allow_once_idx]
    end
    return options[1]
  end

  local command_text, _, _ = self:_format_permission_command(request)
  local prompt_text = request.title or 'Cursor agent requests permission'
  if command_text and command_text ~= '' then
    local preview = command_text:gsub('%s+', ' ')
    if #preview > 120 then
      preview = preview:sub(1, 117) .. '...'
    end
    prompt_text = prompt_text .. ' | ' .. preview
  end

  vim.schedule(function()
    vim.ui.select(items, {
      prompt = prompt_text,
    }, function(_choice, idx)
      local selected = options[idx]
      if not selected then
        selected = choose_default_option()
      end
      finish_with_option(selected.id or selected.optionId or 'allow-once')
    end)
  end)
end

function CursorManager:_format_permission_command(request)
  local command = nil
  local args = nil
  local cwd = nil
  local detail = nil

  local function extract_args(value)
    if type(value) == 'table' then
      return value
    end
    return nil
  end

  local function set_command_from_table(tbl)
    if type(tbl) ~= 'table' then
      return false
    end

    if type(tbl.title) == 'string' and tbl.title ~= '' then
      command = tbl.title
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.command) == 'string' and tbl.command ~= '' then
      command = tbl.command
      args = extract_args(tbl.args) or extract_args(tbl.argv) or extract_args(tbl.arguments)
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.commandLine) == 'string' and tbl.commandLine ~= '' then
      command = tbl.commandLine
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.cmd) == 'string' and tbl.cmd ~= '' then
      command = tbl.cmd
      args = extract_args(tbl.args) or extract_args(tbl.argv)
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.executable) == 'string' and tbl.executable ~= '' then
      command = tbl.executable
      args = extract_args(tbl.argv) or extract_args(tbl.args)
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.toolName) == 'string' and tbl.toolName ~= '' then
      local server = ''
      if type(tbl.server) == 'string' and tbl.server ~= '' then
        server = tbl.server
      elseif type(tbl.mcpServer) == 'string' and tbl.mcpServer ~= '' then
        server = tbl.mcpServer
      end
      if server ~= '' then
        command = 'MCP ' .. server .. '/' .. tbl.toolName
      else
        command = 'MCP ' .. tbl.toolName
      end
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.tool) == 'string' and tbl.tool ~= '' then
      command = 'Tool ' .. tbl.tool
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.method) == 'string' and tbl.method ~= '' then
      command = 'Method ' .. tbl.method
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.action) == 'string' and tbl.action ~= '' then
      command = 'Action ' .. tbl.action
      if type(tbl.cwd) == 'string' and tbl.cwd ~= '' then
        cwd = tbl.cwd
      end
      return true
    end

    if type(tbl.description) == 'string' and tbl.description ~= '' then
      detail = tbl.description
    elseif type(tbl.reason) == 'string' and tbl.reason ~= '' then
      detail = tbl.reason
    elseif type(tbl.text) == 'string' and tbl.text ~= '' and not detail then
      detail = tbl.text
    end

    return false
  end

  local function pick_from_table(tbl)
    if type(tbl) ~= 'table' then
      return false
    end

    if set_command_from_table(tbl) then
      return true
    end

    for _, value in pairs(tbl) do
      if type(value) == 'table' then
        if pick_from_table(value) then
          return true
        end
      end
    end

    return false
  end

  pick_from_table(request)

  if not command then
    local ok, encoded = pcall(vim.json.encode, request)
    if ok and encoded and encoded ~= '{}' then
      return nil, cwd, encoded
    end
    return nil, cwd, detail
  end

  local parts = { command }
  if type(args) == 'table' then
    for _, arg in ipairs(args) do
      if arg ~= nil then
        table.insert(parts, tostring(arg))
      end
    end
  end

  return table.concat(parts, ' '), cwd, detail
end

function CursorManager:_notify_permission_request(request)
  local cb = self.on_permission_request
  if type(cb) ~= 'function' then
    return
  end

  local lines = { '## Permission request', '' }
  local title = request and request.title or 'Cursor agent requests permission'
  table.insert(lines, title)

  local command_text, cwd, detail_text = self:_format_permission_command(request or {})
  if command_text and command_text ~= '' then
    table.insert(lines, '')
    table.insert(lines, 'Command')
    table.insert(lines, '`' .. command_text .. '`')
  end

  if detail_text and detail_text ~= '' then
    table.insert(lines, '')
    table.insert(lines, 'Details')
    table.insert(lines, detail_text)
  end

  if cwd and cwd ~= '' then
    table.insert(lines, '')
    table.insert(lines, 'Working directory: `' .. cwd .. '`')
  end

  local content = table.concat(lines, '\n')
  vim.schedule(function()
    cb(content, request)
  end)
end

function CursorManager:set_permission_request_handler(handler)
  if type(handler) == 'function' then
    self.on_permission_request = handler
  else
    self.on_permission_request = nil
  end
end

function CursorManager:set_activity_update_handler(handler)
  if type(handler) == 'function' then
    self.on_activity_update = handler
  else
    self.on_activity_update = nil
  end
end

function CursorManager:set_file_write_handler(handler)
  if type(handler) == 'function' then
    self.on_file_write = handler
  else
    self.on_file_write = nil
  end
end

function CursorManager:set_file_read_handler(handler)
  if type(handler) == 'function' then
    self.on_file_read = handler
  else
    self.on_file_read = nil
  end
end

function CursorManager:_is_image_path(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
  local lower = path:lower()
  return lower:match('%.png$') ~= nil
    or lower:match('%.jpe?g$') ~= nil
    or lower:match('%.webp$') ~= nil
    or lower:match('%.gif$') ~= nil
    or lower:match('%.bmp$') ~= nil
end

function CursorManager:_mime_type_for_path(path)
  local lower = (path or ''):lower()
  if lower:match('%.png$') then
    return 'image/png'
  elseif lower:match('%.jpe?g$') then
    return 'image/jpeg'
  elseif lower:match('%.webp$') then
    return 'image/webp'
  elseif lower:match('%.gif$') then
    return 'image/gif'
  elseif lower:match('%.bmp$') then
    return 'image/bmp'
  end
  return 'application/octet-stream'
end

function CursorManager:_extract_image_paths_from_message(message)
  local text = message or ''
  local paths = {}
  local seen = {}
  local spans = {}

  local function add_path(path, raw_match)
    if type(path) ~= 'string' or path == '' then
      return
    end
    path = path:gsub('^file://', '')
    path = path:gsub('^%s+', ''):gsub('%s+$', '')
    if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
      path = path:sub(2, -2)
    end
    if not self:_is_image_path(path) then
      return
    end
    if vim.fn.filereadable(path) ~= 1 then
      return
    end
    if seen[path] then
      return
    end
    seen[path] = true
    table.insert(paths, path)
    if type(raw_match) == 'string' and raw_match ~= '' then
      table.insert(spans, raw_match)
    end
  end

  for raw, path in text:gmatch('(!%b[]%(([^)]+)%))') do
    add_path(path, raw)
  end
  for raw in text:gmatch('(file://[%w%._%-%/%s]+)') do
    add_path(raw, raw)
  end
  for raw in text:gmatch('(/[%w%._%-%/%s]+%.%w+)') do
    add_path(raw, raw)
  end

  return paths, spans
end

function CursorManager:_base64_encode_bytes(bytes)
  if not bytes or bytes == '' then
    return nil
  end
  if vim.base64 and vim.base64.encode then
    local ok, encoded = pcall(vim.base64.encode, bytes)
    if ok and encoded and encoded ~= '' then
      return encoded
    end
  end

  local tmp_path = vim.fn.tempname()
  local f = io.open(tmp_path, 'wb')
  if not f then
    return nil
  end
  f:write(bytes)
  f:close()
  local escaped = vim.fn.shellescape(tmp_path)
  local out = vim.fn.system('base64 ' .. escaped)
  pcall(vim.fn.delete, tmp_path)
  if type(out) == 'string' and out ~= '' then
    out = out:gsub('%s+', '')
    if out ~= '' then
      return out
    end
  end
  return nil
end

function CursorManager:_build_image_prompt_items(message_text)
  local image_paths, raw_spans = self:_extract_image_paths_from_message(message_text)
  local cleaned_text = message_text or ''
  for _, raw in ipairs(raw_spans or {}) do
    cleaned_text = cleaned_text:gsub(vim.pesc(raw), ' ')
  end
  cleaned_text = cleaned_text:gsub('%s+\n', '\n')
  cleaned_text = cleaned_text:gsub('\n%s+', '\n')
  cleaned_text = cleaned_text:gsub('[ \t]+', ' ')
  cleaned_text = cleaned_text:gsub('\n\n\n+', '\n\n')
  cleaned_text = cleaned_text:gsub('^%s+', ''):gsub('%s+$', '')

  if #image_paths == 0 then
    return {}, message_text or ''
  end

  local items = {}
  for _, path in ipairs(image_paths) do
    local f = io.open(path, 'rb')
    if f then
      local bytes = f:read('*a')
      f:close()
      local data = self:_base64_encode_bytes(bytes)
      if data and data ~= '' then
        table.insert(items, {
          type = 'image',
          source = {
            type = 'base64',
            mediaType = self:_mime_type_for_path(path),
            data = data,
          },
        })
      end
    end
  end

  return items, cleaned_text
end

function CursorManager:set_active_session_id(session_id)
  if type(session_id) == 'string' and session_id ~= '' then
    self.session_id = session_id
  else
    self.session_id = nil
  end
end

function CursorManager:get_active_session_id()
  return self.session_id
end

function CursorManager:_ensure_session(current_file, cb)
  if not self:_ensure_acp_process() then
    cb(false)
    return
  end

  local function ensure_initialized(done)
    if self.initialized then
      done(true)
      return
    end

    self:_send_request('initialize', {
      protocolVersion = 1,
      clientCapabilities = {
        fs = { readTextFile = true, writeTextFile = true },
        terminal = true,
      },
      clientInfo = {
        name = 'cursor-nvim',
        version = '0.1.0',
      },
    }, function(result, _err)
      if result then
        self.initialized = true
        done(true)
      else
        done(false)
      end
    end)
  end

  local function ensure_authenticated(done)
    if self.authenticated then
      done(true)
      return
    end

    self:_send_request('authenticate', {
      methodId = self.acp.auth_method or 'cursor_login',
    }, function(result, _err)
      if result then
        self.authenticated = true
        done(true)
      else
        done(false)
      end
    end)
  end

  local function ensure_session_id(done)
    if self.session_id then
      done(true)
      return
    end

    local cwd = self:get_project_root(current_file)
    self:_send_request('session/new', {
      cwd = cwd,
      mcpServers = {},
    }, function(result, _err)
      if result and result.sessionId then
        self.session_id = result.sessionId
        if type(result.configOptions) == 'table' then
          self._config_options = result.configOptions
        end
        done(true)
      else
        done(false)
      end
    end)
  end

  ensure_initialized(function(ok)
    if not ok then
      cb(false)
      return
    end
    ensure_authenticated(function(ok2)
      if not ok2 then
        cb(false)
        return
      end
      ensure_session_id(function(ok3)
        cb(ok3)
      end)
    end)
  end)
end

function CursorManager:send_chat_message(message, callback, opts)
  if not self.acp.enabled then
    vim.notify('ACP is disabled in CursorManager options.', vim.log.levels.ERROR)
    if callback then
      callback('', {}, false)
    end
    return
  end

  local current_file = vim.api.nvim_buf_get_name(0)
  opts = opts or {}
  local conversation_context = opts.conversation_context or ''
  local image_prompt_items, cleaned_message = self:_build_image_prompt_items(message)
  local user_request = cleaned_message
  if not user_request or user_request == '' then
    user_request = 'Please analyze the attached image(s).'
  end

  local full_prompt = self:get_session_context(current_file)
  local prompt_parts = {}
  if full_prompt ~= '' then
    table.insert(prompt_parts, full_prompt)
  end
  if type(conversation_context) == 'string' and conversation_context ~= '' then
    table.insert(prompt_parts, 'Conversation so far:\n' .. conversation_context)
  end
  table.insert(prompt_parts, 'User request: ' .. user_request)
  full_prompt = table.concat(prompt_parts, '\n\n')

  local function finalize_request()
    if not self._active_request then
      return
    end

    local accumulated_content = self._active_request.content or ''
    local accumulated_changes = {}

    if self._active_request.changes and #self._active_request.changes > 0 then
      for _, ch in ipairs(self._active_request.changes) do
        table.insert(accumulated_changes, ch)
      end
    end

    if accumulated_content ~= '' and accumulated_content:match('```') then
      local code_blocks = {}
      for block in accumulated_content:gmatch('```[^`]*```') do
        table.insert(code_blocks, block)
      end
      if #code_blocks > 0 then
        local parsed = self:_parse_code_changes(code_blocks, current_file)
        for _, ch in ipairs(parsed) do
          table.insert(accumulated_changes, ch)
        end
      end
    end

    local cb = self._active_request.callback
    self._active_request = nil
    if cb then
      vim.schedule(function()
        cb(accumulated_content, accumulated_changes, false)
      end)
    end
  end

  local prompt_retried = false

  local function start_prompt()
    self._active_request = {
      callback = callback,
      content = '',
      changes = {},
      last_stream_content = '',
    }

    local prompt_items = {
      { type = 'text', text = full_prompt },
    }
    for _, item in ipairs(image_prompt_items) do
      table.insert(prompt_items, item)
    end

    local function issue_prompt()
      local params = {
        sessionId = self.session_id,
        prompt = prompt_items,
      }

      self.current_prompt_id = self:_send_request('session/prompt', params, function(_result, err)
        if err and not prompt_retried then
          prompt_retried = true

          local tried_image_items = #image_prompt_items > 0
          if tried_image_items then
            prompt_items = {
              { type = 'text', text = full_prompt },
            }
            issue_prompt()
            return
          end

          self.session_id = nil
          self:_ensure_session(current_file, function(ok_retry)
            if ok_retry then
              issue_prompt()
            else
              finalize_request()
            end
          end)
          return
        end
        finalize_request()
      end)
    end

    issue_prompt()
  end

  self:_ensure_session(current_file, function(ok)
    if not ok then
      if callback then
        callback('Failed to initialize ACP session. Make sure `agent` CLI is installed and authenticated (run `agent login`).', {}, false)
      end
      return
    end
    start_prompt()
  end)
end

function CursorManager:_parse_code_changes(code_blocks, current_file)
  local changes = {}
  
  for _, block in ipairs(code_blocks) do
    local filepath = current_file
    local lines = {}
    
    for line in block:gmatch('[^\n]+') do
      if line:match('^```') then
        local lang_match = line:match('^```([^:]+):(.+)')
        if lang_match then
          filepath = lang_match
        end
      elseif not line:match('^```') then
        table.insert(lines, line)
      end
    end
    
    if #lines > 0 then
      table.insert(changes, {
        type = 'edit',
        file = filepath or current_file,
        start_line = 1,
        end_line = 1,
        lines = lines,
      })
    end
  end
  
  return changes
end

function CursorManager:_check_cursor_cli()
  local handle = io.popen('which ' .. (self.acp.command or 'agent') .. ' 2>/dev/null')
  if handle then
    local result = handle:read('*a')
    handle:close()
    if result and result ~= '' then
      return true
    end
  end
  
  local handle2 = io.popen((self.acp.command or 'agent') .. ' --version 2>/dev/null')
  if handle2 then
    local result = handle2:read('*a')
    handle2:close()
    if result and result ~= '' then
      return true
    end
  end
  
  return false
end

function CursorManager:get_file_context(filepath)
  if not filepath or filepath == '' then
    return nil
  end
  
  if vim.fn.filereadable(filepath) ~= 1 then
    return nil
  end
  
  local ok, lines = pcall(function()
    local result = {}
    for line in io.lines(filepath) do
      table.insert(result, line)
    end
    return result
  end)
  
  if not ok or not lines then
    return nil
  end
  
  return table.concat(lines, '\n')
end

function CursorManager:get_project_root(filepath)
  if not filepath or filepath == '' then
    filepath = vim.fn.getcwd()
  end
  
  local dir = vim.fn.fnamemodify(filepath, ':h')
  local root_markers = {'.git', '.hg', '.svn', 'package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'pom.xml', 'build.gradle', 'Makefile', 'CMakeLists.txt'}
  
  local current = dir
  while current ~= '/' and current ~= '' do
    for _, marker in ipairs(root_markers) do
      local marker_path = current .. '/' .. marker
      if vim.fn.filereadable(marker_path) == 1 or vim.fn.isdirectory(marker_path) == 1 then
        return current
      end
    end
    current = vim.fn.fnamemodify(current, ':h')
  end
  
  return dir
end

function CursorManager:get_project_structure(project_root, max_depth, max_files)
  max_depth = max_depth or 1
  max_files = max_files or 20
  local structure = {}
  local file_count = 0
  
  local function scan_dir(dir, depth, prefix)
    if depth > max_depth or file_count >= max_files then
      return
    end
    
    local escaped_dir = vim.fn.shellescape(dir)
    local handle = io.popen('find ' .. escaped_dir .. ' -maxdepth 1 -not -path ' .. escaped_dir .. ' 2>/dev/null | head -20')
    if not handle then
      return
    end
    
    local entries = {}
    for line in handle:lines() do
      if line and line ~= '' then
        table.insert(entries, line)
      end
    end
    handle:close()
    
    table.sort(entries)
    
    for _, entry in ipairs(entries) do
      if file_count >= max_files then
        break
      end
      
      local name = vim.fn.fnamemodify(entry, ':t')
      local is_dir = vim.fn.isdirectory(entry) == 1
      
      if not name:match('^%.') or name == '.git' then
        if is_dir then
          table.insert(structure, prefix .. name .. '/')
          if depth < max_depth then
            scan_dir(entry, depth + 1, prefix .. '  ')
          end
        else
          table.insert(structure, prefix .. name)
          file_count = file_count + 1
        end
      end
    end
  end
  
  scan_dir(project_root, 0, '')
  return structure
end

function CursorManager:get_config_files(project_root)
  local config_files = {}
  local config_patterns = {
    'package.json', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml',
    'requirements.txt', 'Pipfile', 'poetry.lock', 'pyproject.toml',
    'Cargo.toml', 'Cargo.lock',
    'go.mod', 'go.sum',
    'pom.xml', 'build.gradle', 'settings.gradle',
    'Makefile', 'CMakeLists.txt',
    'tsconfig.json', 'jsconfig.json',
    '.gitignore', '.env.example', 'README.md', 'LICENSE'
  }
  
  for _, pattern in ipairs(config_patterns) do
    local filepath = project_root .. '/' .. pattern
    if vim.fn.filereadable(filepath) == 1 then
      local content = self:get_file_context(filepath)
      if content then
        table.insert(config_files, {
          name = pattern,
          content = content
        })
      end
    end
  end
  
  return config_files
end

function CursorManager:get_open_buffers_context()
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      if filepath and filepath ~= '' and vim.fn.filereadable(filepath) == 1 then
        table.insert(buffers, {
          path = filepath,
        })
      end
    end
  end
  return buffers
end

function CursorManager:get_project_context(current_file)
  local context_parts = {}
  
  local project_root = self:get_project_root(current_file)
  local working_dir = vim.fn.getcwd()
  
  if project_root then
    table.insert(context_parts, 'Project root: ' .. project_root)
  end
  
  if working_dir and working_dir ~= '' and working_dir ~= project_root then
    table.insert(context_parts, 'Working directory: ' .. working_dir)
  end
  
  if current_file and current_file ~= '' and vim.fn.filereadable(current_file) == 1 then
    table.insert(context_parts, 'Current file: ' .. current_file)
  end
  
  return table.concat(context_parts, '\n')
end

function CursorManager:get_session_context(current_file)
  local parts = {}

  local project_root = self:get_project_root(current_file)
  local project_structure = self:get_project_structure(project_root, 1, 30)
  local open_buffers = self:get_open_buffers_context()

  table.insert(parts, '## Neovim Session Context')
  table.insert(parts, '')

  if project_root then
    table.insert(parts, 'Project root: ' .. project_root)
  end

  if current_file and current_file ~= '' then
    table.insert(parts, 'Current file: ' .. current_file)
  end

  if #open_buffers > 0 then
    table.insert(parts, '')
    table.insert(parts, 'Open buffers:')
    for _, buf in ipairs(open_buffers) do
      table.insert(parts, '- ' .. buf.path)
    end
  end

  if project_structure and #project_structure > 0 then
    table.insert(parts, '')
    table.insert(parts, 'Project structure (shallow):')
    for _, entry in ipairs(project_structure) do
      table.insert(parts, '- ' .. entry)
    end
  end

  return table.concat(parts, '\n')
end


local model_cache = { items = nil, at = 0 }

function CursorManager.list_models()
  if model_cache.items and (os.time() - model_cache.at) < 60 then
    return model_cache.items
  end

  local out = vim.fn.system({ 'agent', '--list-models' })
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local items = {}
  for line in tostring(out):gmatch('[^\r\n]+') do
    local id, name = line:match('^(%S+)%s+%-%s+(.+)$')
    if id and name and not line:match('^Tip:') then
      table.insert(items, { id = id, name = name })
    end
  end
  model_cache.items = items
  model_cache.at = os.time()
  return items
end

function CursorManager:get_model()
  return self.model or 'auto'
end

function CursorManager:_model_config_option()
  if type(self._config_options) ~= 'table' then
    return nil
  end
  for _, opt in ipairs(self._config_options) do
    if type(opt) == 'table' then
      local id = opt.configId or opt.id
      if opt.category == 'model' or id == 'model' then
        return opt
      end
    end
  end
  return nil
end

function CursorManager:set_model(model_id, cb)
  cb = cb or function() end
  model_id = model_id or 'auto'

  local function restart()
    self:stop()
    self.initialized = false
    self.authenticated = false
    self.session_id = nil
    self._config_options = nil
    self.model = model_id
    cb(true, 'restart')
  end

  if model_id == self.model then
    cb(true, 'unchanged')
    return
  end

  local opt = self:_model_config_option()
  if opt and self.session_id and self.proc_job_id and self.proc_job_id > 0 then
    self:_send_request('session/set_config_option', {
      sessionId = self.session_id,
      configId = opt.configId or opt.id or 'model',
      type = 'id',
      value = model_id,
    }, function(result, err)
      if result then
        self.model = model_id
        if type(result.configOptions) == 'table' then
          self._config_options = result.configOptions
        end
        cb(true, 'acp')
      else
        restart()
      end
    end)
    return
  end

  restart()
end

function CursorManager:stop()
  local stopped = false

  if self.session_id and self.proc_job_id then
    local ok = pcall(function()
      self:_send_request('session/cancel', { sessionId = self.session_id }, function() end)
    end)
    if ok then
      stopped = true
    end
  end

  if self.proc_job_id and self.proc_job_id > 0 then
    vim.fn.jobstop(self.proc_job_id)
    self.proc_job_id = nil
    stopped = true
  end

  if self._active_request then
    self._active_request = nil
  end

  return stopped
end

return CursorManager


