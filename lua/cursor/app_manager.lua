local CursorManager = require('cursor.cursor_manager')
local WindowManager = require('cursor.window_manager')
local ChatManager = require('cursor.chat_manager')
local BindingManager = require('cursor.binding_manager')
local Commands = require('cursor.commands')
local Slash = require('cursor.slash')

local AppManager = {}
AppManager.__index = AppManager

function AppManager.new()
  local self = setmetatable({}, AppManager)
  
  self.opts = {}
  self.cursor_manager = nil
  self.window_manager = WindowManager.new()
  self.window_manager.on_request_close = function()
    self:close()
  end
  self.chat_manager = ChatManager.new()
  self.binding_manager = nil
  self.commands = nil
  
  self.is_open = false
  self.session_store = nil
  self.session_store_path = nil
  self.current_session_id = nil
  self.session_root = vim.fn.getcwd()
  self.request_queue = {}
  self.request_in_flight = false
  self.current_request = nil
  self.next_request_id = 1
  self.next_checkpoint_id = 1
  self.current_checkpoint = nil
  self.checkpoints = {}
  self.review = {}
  
  return self
end

function AppManager:setup_bindings(binding_opts)
  self.binding_manager = BindingManager.new(self)
  self.binding_manager:setup(binding_opts)
end

function AppManager:setup_commands()
  self.commands = Commands.new(self)
  self.commands:register()
end

function AppManager:_get_project_root()
  if self.session_root and self.session_root ~= '' then
    return self.session_root
  end
  self.session_root = vim.fn.getcwd()
  return self.session_root
end

function AppManager:_get_session_store_path()
  if self.session_store_path then
    return self.session_store_path
  end

  local root = self:_get_project_root() or vim.fn.getcwd()
  local project_key = vim.fn.fnamemodify(root, ':p')
  project_key = project_key:gsub('[^%w%._%-]', '_')
  local base_dir = vim.fn.stdpath('data') .. '/cursor.nvim/sessions'
  vim.fn.mkdir(base_dir, 'p')
  self.session_store_path = base_dir .. '/' .. project_key .. '.json'
  return self.session_store_path
end

function AppManager:_default_session_data()
  return {
    current_session_id = nil,
    sessions = {},
    model = nil,
  }
end

function AppManager:_create_session(name)
  local now = os.time()
  local id = tostring(now) .. '_' .. tostring(math.random(1000, 9999))
  return {
    id = id,
    name = name or ('Session ' .. os.date('%Y-%m-%d %H:%M')),
    updated_at = now,
    acp_session_id = nil,
    checkpoints = {},
    state = {
      messages = {},
      last_sent_message = '',
      affected_files = {},
    },
  }
end

function AppManager:_base64_encode_bytes(bytes)
  if not bytes or bytes == '' then
    return ''
  end
  if vim.base64 and vim.base64.encode then
    local ok, encoded = pcall(vim.base64.encode, bytes)
    if ok and encoded then
      return encoded
    end
  end

  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((bytes:gsub('.', function(x)
    local r, byte = '', x:byte()
    for i = 8, 1, -1 do
      r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and '1' or '0')
    end
    return r
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then
      return ''
    end
    local c = 0
    for i = 1, 6 do
      c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0)
    end
    return b:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#bytes % 3 + 1])
end

function AppManager:_base64_decode_bytes(text)
  if not text or text == '' then
    return ''
  end
  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, text)
    if ok and decoded then
      return decoded
    end
  end

  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  text = text:gsub('[^' .. b .. '=]', '')
  return (text:gsub('.', function(x)
    if x == '=' then
      return ''
    end
    local f = (b:find(x, 1, true) or 1) - 1
    local r = ''
    for i = 6, 1, -1 do
      r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0')
    end
    return r
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if #x ~= 8 then
      return ''
    end
    local c = 0
    for i = 1, 8 do
      c = c + (x:sub(i, i) == '1' and 2 ^ (8 - i) or 0)
    end
    return string.char(c)
  end))
end

function AppManager:_serialize_checkpoints()
  local out = {}
  for _, cp in ipairs(self.checkpoints or {}) do
    local files = {}
    if type(cp.files) == 'table' then
      for path, entry in pairs(cp.files) do
        files[path] = {
          exists = entry.exists and true or false,
          content_b64 = entry.content and self:_base64_encode_bytes(entry.content) or '',
        }
      end
    end
    table.insert(out, {
      created_at = cp.created_at,
      user_message = cp.user_message,
      order = cp.order or {},
      files = files,
      chat_state_before = cp.chat_state_before,
      chat_state_after = cp.chat_state_after,
    })
  end
  return out
end

function AppManager:_deserialize_checkpoints(raw)
  local checkpoints = {}
  if type(raw) ~= 'table' then
    return checkpoints
  end

  for _, cp in ipairs(raw) do
    if type(cp) == 'table' then
      local files = {}
      if type(cp.files) == 'table' then
        for path, entry in pairs(cp.files) do
          if type(path) == 'string' and type(entry) == 'table' then
            files[path] = {
              exists = entry.exists and true or false,
              content = self:_base64_decode_bytes(entry.content_b64 or ''),
            }
          end
        end
      end
      table.insert(checkpoints, {
        created_at = cp.created_at,
        user_message = cp.user_message or '',
        order = cp.order or {},
        files = files,
        chat_state_before = cp.chat_state_before,
        chat_state_after = cp.chat_state_after,
      })
    end
  end
  return checkpoints
end

function AppManager:_ensure_session_store()
  if self.session_store then
    return
  end

  local path = self:_get_session_store_path()
  local store = self:_default_session_data()

  if vim.fn.filereadable(path) == 1 then
    local ok_read, lines = pcall(vim.fn.readfile, path)
    if ok_read and type(lines) == 'table' then
      local raw = table.concat(lines, '\n')
      if raw ~= '' then
        local ok_decode, decoded = pcall(vim.json.decode, raw)
        if ok_decode and type(decoded) == 'table' then
          if type(decoded.sessions) == 'table' then
            store.sessions = decoded.sessions
            for _, session in ipairs(store.sessions) do
              if type(session) == 'table' and session.acp_session_id == nil then
                session.acp_session_id = nil
              end
            end
          end
          if type(decoded.current_session_id) == 'string' then
            store.current_session_id = decoded.current_session_id
          end
        end
      end
    end
  end

  if #store.sessions == 0 then
    local initial = self:_create_session('Session 1')
    table.insert(store.sessions, initial)
    store.current_session_id = initial.id
  end

  if not store.current_session_id or store.current_session_id == '' then
    store.current_session_id = store.sessions[1].id
  end

  self.session_store = store
  self.current_session_id = store.current_session_id
end

function AppManager:_save_session_store()
  if not self.session_store then
    return
  end

  self.session_store.current_session_id = self.current_session_id
  local path = self:_get_session_store_path()
  local encoded = vim.json.encode(self.session_store)
  vim.fn.writefile({ encoded }, path)
end

function AppManager:_get_current_session()
  self:_ensure_session_store()
  for _, session in ipairs(self.session_store.sessions) do
    if session.id == self.current_session_id then
      return session
    end
  end
  return nil
end

function AppManager:_persist_current_session()
  local session = self:_get_current_session()
  if not session then
    return
  end
  if self.cursor_manager and session then
    session.acp_session_id = self.cursor_manager:get_active_session_id()
  end
  session.checkpoints = self:_serialize_checkpoints()
  session.state = self.chat_manager:get_state()
  session.updated_at = os.time()
  self:_save_session_store()
end

function AppManager:get_effective_model()
  self:_ensure_session_store()
  if self.session_store and type(self.session_store.model) == 'string' and self.session_store.model ~= '' then
    return self.session_store.model
  end
  if self.cursor_manager then
    return self.cursor_manager:get_model()
  end
  return self.opts.model or 'auto'
end

function AppManager:set_model(model_id)
  if not model_id or model_id == '' then
    return
  end
  if model_id == self:get_effective_model() then
    return
  end
  -- Hold the queue across the model change so stop/cancel cannot start
  -- the next request on the old process, and so a late completion
  -- callback cannot drain the queue before the new model is ready.
  self._hold_queue = true
  if self.request_in_flight then
    local stopped = self:stop_request({ process_next = false })
    if not stopped then
      self.request_in_flight = false
      self.current_request = nil
      self:_finalize_checkpoint()
    end
  end
  self:_ensure_session_store()
  self.session_store.model = model_id
  self:_save_session_store()
  local function done()
    self._hold_queue = false
    self:_sync_queue_display(false)
    vim.notify('Cursor model: ' .. model_id, vim.log.levels.INFO)
    self:_process_next_request()
  end
  if self.cursor_manager then
    self.cursor_manager:set_model(model_id, function()
      done()
    end)
  else
    done()
  end
end

function AppManager:pick_model()
  local items = CursorManager.list_models()
  if #items == 0 then
    vim.notify('Could not list models. Is `agent` on PATH?', vim.log.levels.ERROR)
    return
  end
  local current = self:get_effective_model()
  vim.ui.select(items, {
    prompt = 'Cursor model (current: ' .. current .. ')',
    format_item = function(item)
      if item.id == current then
        return item.name .. '  [' .. item.id .. ']  (current)'
      end
      return item.name .. '  [' .. item.id .. ']'
    end,
  }, function(choice)
    if choice then
      self:set_model(choice.id)
    end
  end)
end

function AppManager:_sync_queue_display(update_window)
  local session = self:_get_current_session()
  self.window_manager:set_panel_state({
    model = self:get_effective_model(),
    session_name = session and session.name or nil,
    affected_files = self.chat_manager:get_affected_files(),
    current_request = self.current_request,
    request_queue = self.request_queue,
  })
  if update_window and self.is_open then
    self.window_manager:update_chat_display(self.chat_manager)
  end
end

function AppManager:_read_file_raw(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local content = f:read('*a')
  f:close()
  return content
end

function AppManager:_write_file_raw(path, content)
  local f = io.open(path, 'wb')
  if not f then
    return false
  end
  f:write(content or '')
  f:close()
  return true
end

function AppManager:_set_loaded_buffer_content(path, content)
  local normalized_path = self:_normalize_checkpoint_path(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == normalized_path then
      local lines = {}
      if content and content ~= '' then
        lines = vim.split(content, '\n', { plain = true })
        if #lines > 0 and lines[#lines] == '' then
          table.remove(lines, #lines)
        end
      end
      vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_buf_set_option(bufnr, 'modified', false)
    end
  end
end

function AppManager:_create_checkpoint(message, chat_state_before)
  local checkpoint = {
    id = self.next_checkpoint_id,
    created_at = os.time(),
    user_message = message or '',
    chat_state_before = chat_state_before or self.chat_manager:get_state(),
    files = {},
    order = {},
  }
  self.next_checkpoint_id = self.next_checkpoint_id + 1
  return checkpoint
end

function AppManager:_normalize_checkpoint_path(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  local normalized = path:gsub('^file://', '')
  if normalized:sub(1, 1) ~= '/' then
    local base = self:_get_project_root() or vim.fn.getcwd()
    normalized = base .. '/' .. normalized
  end
  normalized = vim.fn.fnamemodify(normalized, ':p')
  normalized = normalized:gsub('/+$', '')
  return normalized
end

function AppManager:_filter_project_local_paths(paths)
  local filtered = {}
  local seen = {}
  if type(paths) ~= 'table' then
    return filtered
  end

  local root = self:_get_project_root() or vim.fn.getcwd()
  root = vim.fn.fnamemodify(root, ':p'):gsub('/+$', '')

  for _, path in ipairs(paths) do
    local normalized = self:_normalize_checkpoint_path(path)
    if normalized and normalized:sub(1, #root) == root then
      if not seen[normalized] then
        seen[normalized] = true
        table.insert(filtered, normalized)
      end
    end
  end
  return filtered
end

function AppManager:_start_checkpoint_from_item(item)
  if type(item) == 'table' and type(item.checkpoint) == 'table' then
    self.current_checkpoint = item.checkpoint
    return
  end
  local message = type(item) == 'table' and item.message or item
  self.current_checkpoint = self:_create_checkpoint(message, self.chat_manager:get_state())
end

function AppManager:_capture_checkpoint_files(paths)
  if not self.current_checkpoint or type(paths) ~= 'table' then
    return
  end

  for _, path in ipairs(paths) do
    local normalized = self:_normalize_checkpoint_path(path)
    if normalized and vim.fn.isdirectory(normalized) ~= 1 then
      if self.current_checkpoint.files[normalized] == nil then
        local exists = vim.fn.filereadable(normalized) == 1
        local content = exists and self:_read_file_raw(normalized) or nil
        self.current_checkpoint.files[normalized] = {
          exists = exists,
          content = content,
        }
        table.insert(self.current_checkpoint.order, normalized)
      end
    end
  end
end

function AppManager:_finalize_checkpoint()
  local cp = self.current_checkpoint
  if not cp then
    return
  end
  local fallback_paths = {}
  local affected = self.chat_manager:get_affected_files() or {}
  for _, p in ipairs(affected) do
    table.insert(fallback_paths, p)
  end
  local changes = self.chat_manager:get_last_changes() or {}
  for _, ch in ipairs(changes) do
    if type(ch) == 'table' and type(ch.file) == 'string' and ch.file ~= '' then
      table.insert(fallback_paths, ch.file)
    end
  end
  self.current_checkpoint = cp
  self:_capture_checkpoint_files(fallback_paths)
  self:_mark_review_pending(cp.order)
  self.current_checkpoint = nil

  cp.chat_state_after = self.chat_manager:get_state()
  table.insert(self.checkpoints, 1, cp)
  local max_items = self.opts.checkpoint_history_limit or 20
  while #self.checkpoints > max_items do
    table.remove(self.checkpoints)
  end
  self:_persist_current_session()
end

function AppManager:revert_last_checkpoint()
  if #self.checkpoints <= 1 then
    vim.notify('Cannot revert the initial checkpoint.', vim.log.levels.INFO)
    return false
  end

  local cp = self.checkpoints[1]
  if not cp then
    vim.notify('No checkpoint to revert.', vim.log.levels.INFO)
    return false
  end

  local restore_ok = true
  for _, path in ipairs(cp.order or {}) do
    local entry = cp.files[path]
    if entry and not self:_restore_file_from_entry(path, entry) then
      restore_ok = false
    end
  end

  if not restore_ok then
    vim.notify('Checkpoint restore was incomplete. Keeping checkpoint for retry.', vim.log.levels.WARN)
    return false
  end

  table.remove(self.checkpoints, 1)

  if cp.chat_state_before then
    self.chat_manager:load_state(cp.chat_state_before)
  else
    self.chat_manager:add_message('assistant', 'Reverted checkpoint for: ' .. (cp.user_message or 'previous request'))
  end
  self.review = {}
  self:_sync_queue_display(false)
  self:_sync_changes_quickfix(false)
  self:_persist_current_session()
  self.window_manager:update_chat_display(self.chat_manager)
  vim.notify('Reverted last checkpoint.', vim.log.levels.INFO)
  return true
end

function AppManager:_load_current_session_into_chat()
  local session = self:_get_current_session()
  if not session then
    self.chat_manager:initialize()
    if self.cursor_manager then
      self.cursor_manager:set_active_session_id(nil)
    end
    self.checkpoints = {}
    return
  end
  if self.cursor_manager then
    self.cursor_manager:set_active_session_id(session.acp_session_id)
  end
  self.checkpoints = self:_deserialize_checkpoints(session.checkpoints)
  self.chat_manager:load_state(session.state or {})
  self:_sync_queue_display(false)
end

function AppManager:new_session(name)
  self:_ensure_session_store()
  self:_persist_current_session()

  local created = self:_create_session(name)
  table.insert(self.session_store.sessions, 1, created)
  self.current_session_id = created.id
  self:_load_current_session_into_chat()
  self:_save_session_store()

  if self.is_open then
    self.window_manager:update_chat_display(self.chat_manager)
    self.window_manager:focus_input()
  end
end

function AppManager:switch_session(session_id)
  if type(session_id) ~= 'string' or session_id == '' then
    return
  end

  self:_ensure_session_store()
  self:_persist_current_session()

  local found = false
  for _, session in ipairs(self.session_store.sessions) do
    if session.id == session_id then
      found = true
      break
    end
  end
  if not found then
    return
  end

  self.current_session_id = session_id
  self:_load_current_session_into_chat()
  self:_save_session_store()

  if self.is_open then
    self.window_manager:update_chat_display(self.chat_manager)
    self.window_manager:focus_input()
  end
end

function AppManager:delete_session(session_id)
  if type(session_id) ~= 'string' or session_id == '' then
    return
  end

  self:_ensure_session_store()
  local kept = {}
  for _, session in ipairs(self.session_store.sessions) do
    if session.id ~= session_id then
      table.insert(kept, session)
    end
  end
  self.session_store.sessions = kept

  if #self.session_store.sessions == 0 then
    local created = self:_create_session('Session 1')
    table.insert(self.session_store.sessions, created)
    self.current_session_id = created.id
  elseif self.current_session_id == session_id then
    self.current_session_id = self.session_store.sessions[1].id
  end

  self:_load_current_session_into_chat()
  self:_save_session_store()

  if self.is_open then
    self.window_manager:update_chat_display(self.chat_manager)
    self.window_manager:focus_input()
  end
end

function AppManager:list_sessions()
  self:_ensure_session_store()
  return self.session_store.sessions, self.current_session_id
end

function AppManager:rename_session(session_id, new_name)
  if type(session_id) ~= 'string' or session_id == '' then
    return false
  end
  if type(new_name) ~= 'string' or new_name:match('^%s*$') then
    return false
  end
  self:_ensure_session_store()
  for _, session in ipairs(self.session_store.sessions) do
    if session.id == session_id then
      session.name = new_name:gsub('^%s+', ''):gsub('%s+$', '')
      session.updated_at = os.time()
      self:_save_session_store()
      if self.is_open then
        self:_sync_queue_display(false)
        self.window_manager:update_chat_display(self.chat_manager)
      end
      return true
    end
  end
  return false
end

function AppManager:manage_sessions()
  self:_ensure_session_store()
  self:_persist_current_session()

  local sessions, current_id = self:list_sessions()
  local sorted = vim.deepcopy(sessions)
  table.sort(sorted, function(a, b)
    local at = (a and a.updated_at) or 0
    local bt = (b and b.updated_at) or 0
    return at > bt
  end)

  local entries = {}
  local map = {}

  table.insert(entries, '+ New session')
  map['+ New session'] = { action = 'new' }

  for _, session in ipairs(sorted) do
    local prefix = session.id == current_id and '* ' or '  '
    local ts = session.updated_at and os.date('%Y-%m-%d %H:%M', session.updated_at) or 'unknown'
    local label = prefix .. (session.name or session.id) .. ' [' .. session.id .. '] (' .. ts .. ')'
    table.insert(entries, label)
    map[label] = { action = 'session', id = session.id, name = session.name or session.id }
  end

  vim.ui.select(entries, {
    prompt = 'Cursor sessions',
  }, function(choice)
    local selected = map[choice or '']
    if not selected then
      return
    end

    if selected.action == 'new' then
      vim.ui.input({ prompt = 'Session name: ' }, function(input)
        if input and input ~= '' then
          self:new_session(input)
        else
          self:new_session(nil)
        end
      end)
      return
    end

    if selected.action == 'session' and selected.id then
      vim.ui.select({
        'Switch',
        'Rename',
        'Delete',
      }, {
        prompt = 'Session: ' .. (selected.name or selected.id),
      }, function(action_choice)
        if action_choice == 'Switch' then
          self:switch_session(selected.id)
          return
        end

        if action_choice == 'Rename' then
          vim.ui.input({
            prompt = 'New session name: ',
            default = selected.name or '',
          }, function(new_name)
            if new_name and new_name ~= '' then
              self:rename_session(selected.id, new_name)
            end
          end)
          return
        end

        if action_choice == 'Delete' then
          self:delete_session(selected.id)
        end
      end)
    end
  end)
end

function AppManager:open_chat()
  if self.is_open then
    return
  end
  
  if not self.cursor_manager then
    local opts = vim.tbl_extend('force', {}, self.opts or {}, { model = self:get_effective_model() })
    self.cursor_manager = CursorManager.new(opts)
  end

  self.cursor_manager:set_permission_request_handler(function(content)
    self.chat_manager:add_message('assistant', content)
    self:_persist_current_session()
    self.window_manager:update_chat_display(self.chat_manager)
  end)
  self.cursor_manager:set_activity_update_handler(function(content, _, affected_files)
    local local_paths = self:_filter_project_local_paths(affected_files or {})
    self:_capture_checkpoint_files(local_paths)
    self.chat_manager:add_affected_files(local_paths)
    if #local_paths > 0 then
      self._open_changes_qf = true
      self:_mark_review_pending(local_paths)
    end
    self:_sync_changes_quickfix(false)
    self.chat_manager:upsert_activity_message(content)
    self:_persist_current_session()
    self:_sync_queue_display(false)
    self.window_manager:update_chat_display(self.chat_manager)
  end)
  self.cursor_manager:set_file_write_handler(function(path)
    local local_paths = self:_filter_project_local_paths({ path })
    self:_capture_checkpoint_files(local_paths)
    self.chat_manager:add_affected_files(local_paths)
    if #local_paths > 0 then
      self._open_changes_qf = true
      self:_mark_review_pending(local_paths)
    end
    self:_sync_changes_quickfix(false)
    self:_persist_current_session()
    self:_sync_queue_display(false)
  end)
  self.cursor_manager:set_file_read_handler(function(path)
    local local_paths = self:_filter_project_local_paths({ path })
    self:_capture_checkpoint_files(local_paths)
  end)
  
  self.window_manager.opts = self.opts
  
  self.window_manager:create_chat_window()
  self:_ensure_session_store()
  self:_load_current_session_into_chat()
  self.is_open = true
  self:_sync_queue_display(false)
  
  if self.binding_manager then
    self.binding_manager:register_all_bindings(self.window_manager)
  end
  
  self.window_manager:update_chat_display(self.chat_manager)
end


function AppManager:_run_local_slash(cmd, args)
  args = type(args) == 'string' and args:gsub('^%s+', ''):gsub('%s+$', '') or ''
  local name = cmd and cmd.name or ''

  if name == 'quit' then
    self:close()
    return 'closed'
  end

  if name == 'model' then
    if args == '' then
      self:pick_model()
      return 'ui'
    end
    self:set_model(args:match('^(%S+)') or args)
    return 'done'
  end

  if name == 'clear' then
    self:new_session(args ~= '' and args or nil)
    vim.notify('Started a new Cursor session', vim.log.levels.INFO)
    return 'done'
  end

  if name == 'resume' then
    self:manage_sessions()
    return 'ui'
  end

  if name == 'rewind' then
    self:revert_last_checkpoint()
    return 'done'
  end

  if name == 'rename' then
    if args == '' then
      vim.ui.input({ prompt = 'Session name: ' }, function(input)
        if input and input:match('%S') then
          self:rename_session(self.current_session_id, input)
        end
      end)
      return 'ui'
    end
    self:rename_session(self.current_session_id, args)
    return 'done'
  end

  if name == 'help' then
    self:pick_slash_command(args)
    return 'ui'
  end

  return 'done'
end

function AppManager:pick_slash_command(filter)
  local items = Slash.list(self)
  if type(filter) == 'string' and filter ~= '' then
    local needle = filter:gsub('^/', ''):lower()
    local matches = {}
    for _, item in ipairs(items) do
      if item.name:lower() == needle or item.name:lower():sub(1, #needle) == needle then
        table.insert(matches, item)
      end
    end
    if #matches == 0 then
      vim.notify('No slash command matching /' .. needle, vim.log.levels.INFO)
      return
    end
    if #matches == 1 then
      vim.notify('/' .. matches[1].name .. ' — ' .. (matches[1].description or ''), vim.log.levels.INFO)
      return
    end
    items = matches
  end

  if #items == 0 then
    vim.notify('No slash commands available yet.', vim.log.levels.INFO)
    return
  end

  vim.ui.select(items, {
    prompt = 'Slash command',
    format_item = function(item)
      local tag = item.local_cmd and 'local' or 'agent'
      local desc = item.description or ''
      if desc ~= '' then
        return '/' .. item.name .. '  ' .. desc .. '  (' .. tag .. ')'
      end
      return '/' .. item.name .. '  (' .. tag .. ')'
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.local_cmd and not choice.takes_arg then
      local resolved = Slash.resolve_local(choice.name) or choice
      local result = self:_run_local_slash(resolved, '')
      if result == 'done' then
        vim.schedule(function()
          self.window_manager:focus_input()
        end)
      end
      return
    end
    local text = '/' .. choice.name
    if choice.takes_arg or choice.input_hint then
      text = text .. ' '
    end
    self.window_manager:set_input_text(text)
    self.window_manager:focus_input(true)
  end)
end

function AppManager:handle_send_message(message_text)
  if not self.window_manager.chat_bufnr then
    return
  end
  
  local message = message_text
  if not message or message == '' or message:match('^%s*$') then
    return
  end

  local slash = Slash.parse(message)
  if slash then
    local local_cmd = Slash.resolve_local(slash.name)
    if local_cmd then
      self.window_manager:clear_input()
      local result = self:_run_local_slash(local_cmd, slash.args)
      if result == 'done' then
        vim.schedule(function()
          self.window_manager:focus_input()
        end)
      end
      return
    end
  end

  local checkpoint_before = self.chat_manager:get_state()
  local checkpoint = self:_create_checkpoint(message, checkpoint_before)
  local seed_paths = {}
  local seen_seed = {}
  local function add_seed(path)
    if type(path) ~= 'string' or path == '' then
      return
    end
    local normalized = self:_normalize_checkpoint_path(path)
    if not normalized or seen_seed[normalized] then
      return
    end
    if vim.fn.filereadable(normalized) ~= 1 then
      return
    end
    seen_seed[normalized] = true
    table.insert(seed_paths, normalized)
  end

  local alt_file = vim.fn.expand('#:p')
  add_seed(alt_file)
  local current_file = vim.api.nvim_buf_get_name(0)
  add_seed(current_file)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local path = vim.api.nvim_buf_get_name(bufnr)
      add_seed(path)
    end
  end
  local conversation_context = self.chat_manager:get_conversation_context(
    self.opts.context_max_messages or 40,
    self.opts.context_max_chars or 12000
  )
  
  self.window_manager:clear_input()
  self.window_manager:update_chat_display(self.chat_manager)
  vim.schedule(function()
    self.window_manager:focus_input()
  end)
  
  table.insert(self.request_queue, {
    id = self.next_request_id,
    message = message,
    conversation_context = conversation_context,
    checkpoint_before = checkpoint_before,
    checkpoint = checkpoint,
    checkpoint_seed_paths = seed_paths,
  })
  self.next_request_id = self.next_request_id + 1
  self:_sync_queue_display(true)

  self:_process_next_request()
end

function AppManager:close()
  if not self.is_open then
    return
  end

  self:_persist_current_session()
  self.chat_manager:cleanup()
  self.window_manager:close_chat_window()
  self.is_open = false
end

function AppManager:open_affected_file_under_cursor()
  if not self.window_manager or not self.window_manager.chat_bufnr then
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local in_chat = current_buf == self.window_manager.chat_bufnr
  local in_queue = self.window_manager.queue_bufnr and current_buf == self.window_manager.queue_bufnr
  if not in_chat and not in_queue then
    return false
  end

  local line = vim.api.nvim_get_current_line()
  if line:match('^%-%s+%[') then
    return false
  end
  local path = line:match('^%-%s+(.+)$')
  if not path or path == '' then
    return false
  end

  if vim.fn.filereadable(path) ~= 1 and vim.fn.isdirectory(path) ~= 1 then
    return false
  end

  local chat_winid = self.window_manager.chat_winid
  local input_winid = self.window_manager.input_winid
  local target_winid = nil
  local wins = vim.api.nvim_tabpage_list_wins(0)

  for _, winid in ipairs(wins) do
    if winid ~= chat_winid and winid ~= input_winid and vim.api.nvim_win_is_valid(winid) then
      local cfg = vim.api.nvim_win_get_config(winid)
      if cfg and (cfg.relative == nil or cfg.relative == '') then
        target_winid = winid
        break
      end
    end
  end

  if target_winid and vim.api.nvim_win_is_valid(target_winid) then
    vim.api.nvim_set_current_win(target_winid)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  else
    vim.cmd('leftabove vsplit ' .. vim.fn.fnameescape(path))
  end

  return true
end

function AppManager:cycle_focus_forward()
  if not self.window_manager then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local chat_win = self.window_manager.chat_winid
  local queue_win = self.window_manager.queue_winid
  local input_win = self.window_manager.input_winid

  local order = {
    chat_win,
    queue_win,
    input_win,
  }

  local valid = {}
  for _, winid in ipairs(order) do
    if winid and vim.api.nvim_win_is_valid(winid) then
      table.insert(valid, winid)
    end
  end

  if #valid == 0 then
    return
  end

  local idx = 0
  for i, winid in ipairs(valid) do
    if winid == current_win then
      idx = i
      break
    end
  end

  local next_idx = 1
  if idx > 0 then
    next_idx = (idx % #valid) + 1
  end
  local target = valid[next_idx]

  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
    if target == input_win then
      vim.api.nvim_win_set_cursor(input_win, {1, 0})
      vim.cmd('stopinsert')
      vim.defer_fn(function()
        vim.api.nvim_feedkeys('i', 'n', false)
      end, 10)
    else
      vim.cmd('stopinsert')
    end
  end
end


function AppManager:_process_next_request()
  if self._hold_queue or self.request_in_flight then
    return
  end

  local next_item = table.remove(self.request_queue, 1)
  if not next_item then
    self.current_request = nil
    self:_sync_queue_display(true)
    return
  end

  self.current_request = next_item
  self:_sync_queue_display(true)
  self:send_message(next_item)
end

function AppManager:send_message(message_or_item)
  local message = message_or_item
  local conversation_context = ''
  local checkpoint_seed_paths = {}
  if type(message_or_item) == 'table' then
    message = message_or_item.message
    conversation_context = message_or_item.conversation_context or ''
    checkpoint_seed_paths = message_or_item.checkpoint_seed_paths or {}
  end

  self.request_in_flight = true
  self.chat_manager:set_last_sent_message(message)
  self.chat_manager:add_message('user', message)
  self:_persist_current_session()
  self:_start_checkpoint_from_item(message_or_item)
  self:_capture_checkpoint_files(checkpoint_seed_paths)
  self:_capture_checkpoint_files(self.chat_manager:get_affected_files() or {})
  local existing_changes = self.chat_manager:get_last_changes() or {}
  local existing_change_files = {}
  for _, ch in ipairs(existing_changes) do
    if type(ch) == 'table' and type(ch.file) == 'string' and ch.file ~= '' then
      table.insert(existing_change_files, ch.file)
    end
  end
  self:_capture_checkpoint_files(existing_change_files)

  self.chat_manager:set_status('processing')
  self.window_manager:update_chat_display(self.chat_manager)
  
  self.cursor_manager:send_chat_message(message, function(response, changes, streaming)
    if streaming then
      self.chat_manager:set_status('streaming')
      self.chat_manager:set_streaming_response(response)
      self.window_manager:update_chat_display_streaming(self.chat_manager, response)
    else
      local has_response = response and response ~= '' and not response:match('^%s*$')
      if has_response then
        self.chat_manager:add_message('assistant', response)
      end

      self.chat_manager:clear_streaming_response()
      self.chat_manager:set_status('idle')

      if changes and #changes > 0 then
        self.chat_manager:set_last_changes(changes)
        self._open_changes_qf = true
      end
      self:show_last_changes()

      self:_persist_current_session()
      self.window_manager:update_chat_display(self.chat_manager)
      self.window_manager:focus_input()

      self.request_in_flight = false
      self.current_request = nil
      self:_finalize_checkpoint()
      self:_sync_queue_display(true)
      self:_process_next_request()
    end
  end, {
    conversation_context = conversation_context,
  })
end


function AppManager:stop_request(opts)
  opts = opts or {}
  local process_next = opts.process_next ~= false

  if self.cursor_manager then
    local stopped = self.cursor_manager:stop()
    if stopped then
      self.request_in_flight = false
      self.current_request = nil
      self:_finalize_checkpoint()
      self.chat_manager:set_status('stopped')
      local current_response = self.chat_manager:get_streaming_response()
      if current_response and current_response ~= '' then
        self.window_manager:update_chat_display_streaming(self.chat_manager, current_response)
      else
        self.window_manager:update_chat_display(self.chat_manager)
      end
      
      local last_message = self.chat_manager:get_last_sent_message()
      if last_message and last_message ~= '' then
        self.window_manager:set_input_text(last_message)
      end
      
      self.window_manager:focus_input()
      self:_sync_queue_display(true)
      if process_next then
        self:_process_next_request()
      end
    end
    return stopped
  end
  return false
end

function AppManager:_queue_index_from_current_line()
  if not self.window_manager or not self.window_manager.chat_bufnr then
    return nil
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local in_chat = current_buf == self.window_manager.chat_bufnr
  local in_queue = self.window_manager.queue_bufnr and current_buf == self.window_manager.queue_bufnr
  if not in_chat and not in_queue then
    return nil
  end

  local line = vim.api.nvim_get_current_line()
  return tonumber(line:match('^%-%s+%[(%d+)%]%s+'))
end

function AppManager:cancel_queued_request_under_cursor()
  local idx = self:_queue_index_from_current_line()
  if not idx or idx < 1 or idx > #self.request_queue then
    return false
  end

  table.remove(self.request_queue, idx)
  self:_sync_queue_display(true)
  return true
end

function AppManager:move_queued_request_up_under_cursor()
  local idx = self:_queue_index_from_current_line()
  if not idx or idx <= 1 or idx > #self.request_queue then
    return false
  end

  self.request_queue[idx - 1], self.request_queue[idx] = self.request_queue[idx], self.request_queue[idx - 1]
  self:_sync_queue_display(true)
  return true
end

function AppManager:move_queued_request_down_under_cursor()
  local idx = self:_queue_index_from_current_line()
  if not idx or idx < 1 or idx >= #self.request_queue then
    return false
  end

  self.request_queue[idx + 1], self.request_queue[idx] = self.request_queue[idx], self.request_queue[idx + 1]
  self:_sync_queue_display(true)
  return true
end

function AppManager:apply_changes()
  local last_changes = self.chat_manager:get_last_changes()
  if not last_changes or #last_changes == 0 then
    return
  end
  
  for _, change in ipairs(last_changes) do
    if change.type == 'edit' and change.file then
      local bufnr = vim.fn.bufnr(change.file, true)
      if bufnr == -1 then
        bufnr = vim.fn.bufadd(change.file)
      end
      
      if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
      end
      
      local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local start_line = change.start_line or 1
      local end_line = change.end_line or #current_lines
      
      change.original_lines = {}
      for i = start_line, end_line do
        local line_idx = i - 1
        if current_lines[line_idx] then
          table.insert(change.original_lines, current_lines[line_idx])
        end
      end
      
      vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line - 1, false, change.lines or {})
    end
  end
end

function AppManager:revert_changes()
  local last_changes = self.chat_manager:get_last_changes()
  if not last_changes or #last_changes == 0 then
    return
  end
  
  for _, change in ipairs(last_changes) do
    if change.type == 'edit' and change.file then
      local bufnr = vim.fn.bufnr(change.file, true)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        local original_lines = change.original_lines or {}
        local start_line = change.start_line or 1
        vim.api.nvim_buf_set_lines(bufnr, start_line - 1, start_line + #original_lines - 1, false, original_lines)
      end
    end
  end
  
  self.chat_manager:clear_last_changes()
end

function AppManager:_cursor_qf_info()
  local id = self._changes_qf_id
  if not id or id == 0 then
    return nil
  end
  local info = vim.fn.getqflist({ id = id, nr = 0, title = 0 })
  if type(info) ~= 'table' or info.id ~= id then
    self._changes_qf_id = nil
    return nil
  end
  return info
end

function AppManager:_cursor_qf_is_current()
  local info = self:_cursor_qf_info()
  if not info then
    return false
  end
  local current = vim.fn.getqflist({ id = 0 })
  return type(current) == 'table' and current.id == info.id
end

function AppManager:_select_qf_nr(nr)
  if type(nr) ~= 'number' or nr < 1 then
    return false
  end
  return pcall(vim.cmd, 'silent ' .. tostring(nr) .. 'chistory')
end

function AppManager:_write_cursor_qf(items)
  local info = self:_cursor_qf_info()
  if info then
    vim.fn.setqflist({}, 'r', {
      id = info.id,
      title = 'Cursor Changes',
      items = items,
    })
    return info.id
  end

  -- Append at the end of the stack (nr = '$') so :colder history after
  -- the current list is not discarded, then restore what the user
  -- was viewing.
  local previous = vim.fn.getqflist({ id = 0, nr = 0 })
  vim.fn.setqflist({}, ' ', {
    nr = '$',
    title = 'Cursor Changes',
    items = items,
  })
  local created = vim.fn.getqflist({ id = 0 })
  self._changes_qf_id = created.id
  if type(previous) == 'table' and previous.nr and previous.nr > 0 and previous.id ~= created.id then
    self:_select_qf_nr(previous.nr)
  end
  return self._changes_qf_id
end

function AppManager:_qf_window_is_open()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local info = vim.fn.getwininfo(win)[1]
    if info and info.quickfix == 1 and (not info.loclist or info.loclist == 0) then
      return true
    end
  end
  return false
end

function AppManager:_save_file_buffers(path)
  local normalized = self:_normalize_checkpoint_path(path)
  if not normalized then
    return
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == '' then
      if vim.api.nvim_buf_get_name(bufnr) == normalized then
        vim.api.nvim_buf_call(bufnr, function()
          pcall(vim.cmd, 'silent update')
        end)
      end
    end
  end
end

function AppManager:_mark_review_pending(paths)
  self.review = self.review or {}
  if type(paths) ~= 'table' then
    return
  end
  for _, path in ipairs(paths) do
    local normalized = self:_normalize_checkpoint_path(path)
    if normalized then
      self.review[normalized] = 'pending'
    end
  end
end

function AppManager:_review_status(path)
  local normalized = self:_normalize_checkpoint_path(path)
  if not normalized then
    return nil
  end
  return (self.review or {})[normalized]
end

function AppManager:_is_review_pending(path)
  return self:_review_status(path) == 'pending'
end

function AppManager:_set_review_status(path, status)
  self.review = self.review or {}
  local normalized = self:_normalize_checkpoint_path(path)
  if normalized then
    self.review[normalized] = status
  end
end

function AppManager:_restore_file_from_entry(path, entry)
  if type(path) ~= 'string' or path == '' or type(entry) ~= 'table' then
    return false
  end
  if entry.exists then
    local write_ok = self:_write_file_raw(path, entry.content or '')
    if write_ok then
      self:_set_loaded_buffer_content(path, entry.content or '')
    end
    return write_ok
  end
  local deleted = vim.fn.delete(path)
  if deleted ~= 0 and vim.fn.filereadable(path) == 1 then
    return false
  end
  self:_set_loaded_buffer_content(path, '')
  return true
end

function AppManager:_snapshot_for_path(path)
  local normalized = self:_normalize_checkpoint_path(path)
  if not normalized then
    return nil, nil
  end
  if self.current_checkpoint and type(self.current_checkpoint.files) == 'table' then
    local entry = self.current_checkpoint.files[normalized]
    if entry then
      return normalized, entry
    end
  end
  for _, cp in ipairs(self.checkpoints or {}) do
    if type(cp.files) == 'table' and cp.files[normalized] then
      return normalized, cp.files[normalized]
    end
  end
  return normalized, nil
end

function AppManager:_file_matches_snapshot(path, entry)
  if type(entry) ~= 'table' then
    return false
  end
  local readable = vim.fn.filereadable(path) == 1
  if not entry.exists then
    return not readable
  end
  if not readable then
    return false
  end
  return (self:_read_file_raw(path) or '') == (entry.content or '')
end

function AppManager:_review_paths()
  local paths = {}
  local seen = {}
  local function add(path)
    local normalized = self:_normalize_checkpoint_path(path)
    if not normalized or seen[normalized] or not self:_is_review_pending(normalized) then
      return
    end
    seen[normalized] = true
    table.insert(paths, normalized)
  end
  for _, change in ipairs(self.chat_manager:get_last_changes() or {}) do
    if type(change) == 'table' then
      add(change.file)
    end
  end
  for _, path in ipairs(self.chat_manager:get_affected_files() or {}) do
    add(path)
  end
  for path, status in pairs(self.review or {}) do
    if status == 'pending' then
      add(path)
    end
  end
  return paths
end

function AppManager:_review_path_under_cursor()
  if not self:_cursor_qf_is_current() then
    return nil
  end
  local info = vim.fn.getqflist({ idx = 0, items = 1 })
  local item = info.items and info.items[info.idx]
  if type(item) ~= 'table' then
    return nil
  end
  if type(item.filename) == 'string' and item.filename ~= '' then
    return self:_normalize_checkpoint_path(item.filename)
  end
  if type(item.bufnr) == 'number' and item.bufnr > 0 then
    return self:_normalize_checkpoint_path(vim.api.nvim_buf_get_name(item.bufnr))
  end
  return nil
end

function AppManager:_ensure_review_qf_bindings()
  if not self.binding_manager then
    return
  end
  if not self._review_qf_autocmd then
    self._review_qf_autocmd = vim.api.nvim_create_autocmd('FileType', {
      pattern = 'qf',
      callback = function(ev)
        if self:_cursor_qf_is_current() then
          self.binding_manager:register_review_bindings(ev.buf)
        end
      end,
    })
  end
  local info = vim.fn.getqflist({ winid = 1 })
  if self:_cursor_qf_is_current() and info.winid and info.winid ~= 0 then
    self.binding_manager:register_review_bindings(vim.api.nvim_win_get_buf(info.winid))
  end
end

function AppManager:accept_change(path, opts)
  opts = opts or {}
  path = self:_normalize_checkpoint_path(path or self:_review_path_under_cursor())
  if not path then
    if not opts.silent then
      vim.notify('No change under cursor.', vim.log.levels.INFO)
    end
    return false
  end
  self:_set_review_status(path, 'accepted')
  self:_save_file_buffers(path)
  if not opts.nosync then
    self:_sync_changes_quickfix(false)
  end
  if not opts.silent then
    vim.notify('Accepted ' .. vim.fn.fnamemodify(path, ':.'), vim.log.levels.INFO)
  end
  return true
end

function AppManager:reject_change(path, opts)
  opts = opts or {}
  local normalized, entry = self:_snapshot_for_path(path or self:_review_path_under_cursor())
  if not normalized then
    if not opts.silent then
      vim.notify('No change under cursor.', vim.log.levels.INFO)
    end
    return false
  end
  if not entry then
    if not opts.silent then
      vim.notify('No snapshot to reject for ' .. vim.fn.fnamemodify(normalized, ':.'), vim.log.levels.WARN)
    end
    return false
  end
  if not self:_file_matches_snapshot(normalized, entry) then
    if not self:_restore_file_from_entry(normalized, entry) then
      if not opts.silent then
        vim.notify('Failed to restore ' .. vim.fn.fnamemodify(normalized, ':.'), vim.log.levels.ERROR)
      end
      return false
    end
  elseif not opts.silent then
    vim.notify('Already matches snapshot: ' .. vim.fn.fnamemodify(normalized, ':.'), vim.log.levels.INFO)
  end
  self:_set_review_status(normalized, 'rejected')
  self:_save_file_buffers(normalized)
  if not opts.nosync then
    self:_sync_changes_quickfix(false)
  end
  if not opts.silent then
    vim.notify('Rejected ' .. vim.fn.fnamemodify(normalized, ':.'), vim.log.levels.INFO)
  end
  return true
end

function AppManager:accept_all_changes()
  local count = 0
  for _, path in ipairs(self:_review_paths()) do
    if self:_review_status(path) == 'pending' then
      if self:accept_change(path, { silent = true, nosync = true }) then
        count = count + 1
      end
    end
  end
  self:_sync_changes_quickfix(false)
  vim.notify('Accepted ' .. tostring(count) .. ' change(s).', vim.log.levels.INFO)
end

function AppManager:reject_all_changes()
  local count = 0
  local failed = 0
  for _, path in ipairs(self:_review_paths()) do
    if self:_review_status(path) == 'pending' then
      if self:reject_change(path, { silent = true, nosync = true }) then
        count = count + 1
      else
        failed = failed + 1
      end
    end
  end
  self:_sync_changes_quickfix(false)
  local msg = 'Rejected ' .. tostring(count) .. ' change(s).'
  if failed > 0 then
    msg = msg .. ' ' .. tostring(failed) .. ' failed.'
    vim.notify(msg, vim.log.levels.WARN)
  else
    vim.notify(msg, vim.log.levels.INFO)
  end
end

function AppManager:diff_change(path)
  local normalized, entry = self:_snapshot_for_path(path or self:_review_path_under_cursor())
  if not normalized then
    vim.notify('No change under cursor.', vim.log.levels.INFO)
    return
  end
  if not entry then
    vim.notify('No snapshot to diff for ' .. vim.fn.fnamemodify(normalized, ':.'), vim.log.levels.WARN)
    return
  end

  local old_lines = {}
  if entry.exists and type(entry.content) == 'string' and entry.content ~= '' then
    old_lines = vim.split(entry.content, '\n', { plain = true })
    if #old_lines > 0 and old_lines[#old_lines] == '' then
      table.remove(old_lines)
    end
  end

  vim.cmd('tabnew')
  local scratch = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, old_lines)
  vim.bo[scratch].buftype = 'nofile'
  vim.bo[scratch].bufhidden = 'wipe'
  vim.bo[scratch].swapfile = false
  vim.bo[scratch].modifiable = false
  pcall(vim.api.nvim_buf_set_name, scratch, vim.fn.fnamemodify(normalized, ':t') .. ' (before)')
  vim.cmd('diffthis')

  vim.cmd('vsplit ' .. vim.fn.fnameescape(normalized))
  vim.cmd('diffthis')
  local current = vim.api.nvim_get_current_buf()

  local function close_diff()
    if not pcall(vim.cmd, 'tabclose') then
      pcall(vim.cmd, 'diffoff!')
      if vim.api.nvim_buf_is_valid(scratch) then
        pcall(vim.api.nvim_buf_delete, scratch, { force = true })
      end
    end
  end
  for _, buf in ipairs({ scratch, current }) do
    vim.keymap.set('n', 'q', close_diff, {
      buffer = buf,
      silent = true,
      desc = 'cursor review: close diff',
    })
  end
end

function AppManager:_sync_changes_quickfix(open)
  local items = {}
  local seen = {}

  local function add(path, lnum, text)
    if type(path) ~= 'string' or path == '' then
      return
    end
    path = self:_normalize_checkpoint_path(path) or path
    if seen[path] then
      return
    end
    seen[path] = true
    local bufnr = vim.fn.bufnr(path, false)
    table.insert(items, {
      bufnr = bufnr ~= -1 and bufnr or nil,
      filename = path,
      lnum = lnum or 1,
      col = 1,
      text = text or 'changed',
    })
  end

  for _, change in ipairs(self.chat_manager:get_last_changes() or {}) do
    if type(change) == 'table' and change.type == 'edit' then
      add(change.file, change.start_line, 'changed')
    end
  end
  for _, path in ipairs(self.chat_manager:get_affected_files() or {}) do
    add(path, 1, 'changed')
  end

  if #items == 0 then
    if not self:_cursor_qf_info() then
      return
    end
    self:_write_cursor_qf({})
    if self:_cursor_qf_is_current() then
      vim.cmd('cclose')
    end
    return
  end

  self:_write_cursor_qf(items)
  self:_ensure_review_qf_bindings()
  if not open then
    return
  end
  if self:_qf_window_is_open() then

    return
  end

  local info = self:_cursor_qf_info()
  if info then
    self:_select_qf_nr(info.nr)
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd('botright copen')
  self:_ensure_review_qf_bindings()
  if vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
end

function AppManager:show_last_changes()
  local should_open = self._open_changes_qf
  self._open_changes_qf = false
  self:_sync_changes_quickfix(should_open == true)
end

return AppManager
