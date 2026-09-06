local ChatManager = require('cursor.chat_manager')

local role_ns = vim.api.nvim_create_namespace('cursor.chat.roles')

local function ensure_role_highlights()
  vim.api.nvim_set_hl(0, 'CursorChatYou', { default = true, link = 'DiagnosticInfo' })
  vim.api.nvim_set_hl(0, 'CursorChatAssistant', { default = true, link = 'Special' })
end

local WindowManager = {}
WindowManager.__index = WindowManager

function WindowManager.new()
  local self = setmetatable({}, WindowManager)
  
  self.chat_width = 50
  self.chat_bufnr = nil
  self.chat_winid = nil
  self.queue_bufnr = nil
  self.queue_winid = nil
  self.input_bufnr = nil
  self.input_winid = nil
  self.history_separator_line = 0
  self.last_displayed_content = ''
  self.layout = {
    width = 50,
    col = 0,
    history_height = 0,
    base_row = 0,
    input_height = 3,
    queue_height = 4,
    section_gap = 2,
  }
  self.panel_state = {
    model = 'auto',
    session_name = nil,
    current_request = nil,
    request_queue = {},
  }
  
  return self
end

function WindowManager:_ui_opt(key, fallback)
  if self.opts and self.opts.ui and self.opts.ui[key] ~= nil then
    return self.opts.ui[key]
  end
  return fallback
end

function WindowManager:_is_owned_chat_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  return vim.b[buf].cursor_chat_panel == true
end

function WindowManager:wipe_owned_buffers()
  local seen = {}
  for _, buf in ipairs({
    self.chat_bufnr,
    self.input_bufnr,
    self.queue_bufnr,
  }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not seen[buf] and self:_is_owned_chat_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function WindowManager:_create_panel_buf(name, readonly)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].cursor_chat_panel = true
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')
  if readonly then
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(buf, 'readonly', true)
  else
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  end
  return buf
end

function WindowManager:_watch_panel_close(win_field)
  local buf_field = win_field:gsub('_winid$', '_bufnr')
  local buf = self[buf_field]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = buf,
    callback = function()
      self[win_field] = nil
      if self._suppress_close or type(self.on_request_close) ~= 'function' then
        return
      end
      vim.schedule(function()
        if not self._suppress_close then
          self.on_request_close()
        end
      end)
    end,
  })
end


function WindowManager:_close_panel_internal(win_field)
  local win = self[win_field]
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local previous = self._suppress_close
  self._suppress_close = true
  pcall(vim.api.nvim_win_close, win, true)
  self[win_field] = nil
  self._suppress_close = previous
end

function WindowManager:_highlight_roles(buf, roles)
  buf = buf or self.chat_bufnr
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  ensure_role_highlights()
  vim.api.nvim_buf_clear_namespace(buf, role_ns, 0, -1)
  for _, entry in ipairs(roles or {}) do
    local line = entry.line
    local role = entry.role
    if type(line) == 'number' and line >= 0 then
      local hl = role == 'user' and 'CursorChatYou' or 'CursorChatAssistant'
      local label = role == 'user' and ChatManager.USER_LABEL or ChatManager.ASSISTANT_LABEL
      pcall(vim.api.nvim_buf_set_extmark, buf, role_ns, line, 0, {
        end_col = #label,
        hl_group = hl,
      })
    end
  end
end

function WindowManager:_winbar(text)
  if not text or text == '' then
    return ''
  end
  return '%#Title# ' .. text .. ' %*'
end

function WindowManager:_setup_split_win(winid, opts)
  opts = opts or {}
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].cursorline = false
  vim.wo[winid].signcolumn = 'no'
  vim.wo[winid].foldcolumn = '0'
  vim.wo[winid].winfixwidth = true
  if opts.fix_height then
    vim.wo[winid].winfixheight = true
  end
  if opts.winbar ~= nil then
    vim.wo[winid].winbar = opts.winbar
  end
  if opts.statusline ~= nil then
    vim.wo[winid].statusline = opts.statusline
  end
end

function WindowManager:create_chat_window()
  self:wipe_owned_buffers()

  local chat_width = self.chat_width
  if self.opts and self.opts.chat_width then
    chat_width = self.opts.chat_width
  end

  local queue_height = self:_ui_opt('queue_height', 4)
  local input_height = self:_ui_opt('input_height', 3)
  self.layout = {
    width = chat_width,
    col = 0,
    history_height = 0,
    base_row = 0,
    input_height = input_height,
    queue_height = queue_height,
    section_gap = self:_ui_opt('section_gap', 2),
  }

  self.chat_bufnr = self:_create_panel_buf('cursor-chat-history', true)
  self.input_bufnr = self:_create_panel_buf('cursor-chat-input', false)
  self.queue_bufnr = self:_create_panel_buf('cursor-chat-queue', true)

  vim.cmd('silent keepalt botright ' .. tostring(chat_width) .. 'vsplit')
  self.chat_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.chat_winid, self.chat_bufnr)
  self:_setup_split_win(self.chat_winid, {
    winbar = self:_ui_opt('show_chat_title', true) and self:_winbar('Chat') or '',
    statusline = ' ',
  })

  local opened
  opened, self.input_winid = pcall(vim.api.nvim_open_win, self.input_bufnr, true, {
    split = 'below',
    win = self.chat_winid,
    height = input_height,
  })
  if not opened then
    vim.api.nvim_set_current_win(self.chat_winid)
    vim.cmd('silent keepalt belowright ' .. tostring(input_height) .. 'split')
    self.input_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.input_winid, self.input_bufnr)
  end
  self:_setup_split_win(self.input_winid, {
    fix_height = true,
    winbar = self:_ui_opt('show_input_title', true) and self:_winbar('Input') or '',
    statusline = self:_ui_opt('show_model_indicator', true) and '%#Comment# Auto %*' or ' ',
  })

  vim.api.nvim_buf_set_lines(self.input_bufnr, 0, -1, false, {''})
  vim.api.nvim_win_set_cursor(self.input_winid, {1, 0})
  vim.api.nvim_feedkeys('i', 'n', false)

  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.chat_bufnr, 0, -1, false, { 'Cursor Chat', '' })
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', true)
  self:_highlight_roles(self.chat_bufnr)
  self:update_panel_display()

  self:_watch_panel_close('chat_winid')
  self:_watch_panel_close('input_winid')
  self:_watch_panel_close('queue_winid')
end

function WindowManager:close_chat_window()
  self._suppress_close = true
  for _, win in ipairs({ self.chat_winid, self.input_winid, self.queue_winid }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  self:wipe_owned_buffers()
  self.chat_winid = nil
  self.chat_bufnr = nil
  self.queue_winid = nil
  self.queue_bufnr = nil
  self.input_winid = nil
  self.input_bufnr = nil
  self._suppress_close = false
end

function WindowManager:set_panel_state(state)
  state = state or {}
  self.panel_state = {
    model = state.model or 'auto',
    session_name = state.session_name,
    current_request = state.current_request,
    request_queue = state.request_queue or {},
  }
  self:update_panel_display()
end

function WindowManager:_setup_context_win_options(winid)
  self:_setup_split_win(winid, { fix_height = true })
end

function WindowManager:_open_or_update_context_win(winid, bufnr, title, _row, height)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_set_height, winid, height)
    vim.wo[winid].winbar = self:_winbar((title or ''):gsub('^%s+', ''):gsub('%s+$', ''))
    return winid
  end
  local anchor = self.input_winid
  if not (anchor and vim.api.nvim_win_is_valid(anchor) and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local opened, new_winid = pcall(vim.api.nvim_open_win, bufnr, false, {
    split = 'above',
    win = anchor,
    height = height,
  })
  if not opened then
    local prev = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(anchor)
    vim.cmd('silent keepalt aboveleft ' .. tostring(height) .. 'split')
    new_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(new_winid, bufnr)
    if vim.api.nvim_win_is_valid(prev) then
      vim.api.nvim_set_current_win(prev)
    end
  end
  self:_setup_split_win(new_winid, {
    fix_height = true,
    winbar = self:_winbar((title or ''):gsub('^%s+', ''):gsub('%s+$', '')),
    statusline = ' ',
  })
  return new_winid
end

function WindowManager:update_panel_display()
  if not self.chat_bufnr or not vim.api.nvim_buf_is_valid(self.chat_bufnr) then
    return
  end
  self._suppress_close = true

  local state = self.panel_state or {}
  local model = state.model or 'auto'
  local model_label = tostring(model)
  if model_label == 'auto' then
    model_label = 'Auto'
  end
  local session_name = state.session_name
  if not session_name or session_name == '' then
    session_name = 'Session'
  end

  if self.input_winid and vim.api.nvim_win_is_valid(self.input_winid) then
    if self:_ui_opt('show_input_title', true) then
      vim.wo[self.input_winid].winbar = self:_winbar('Input')
    else
      vim.wo[self.input_winid].winbar = ''
    end
    if self:_ui_opt('show_model_indicator', true) then
      vim.wo[self.input_winid].statusline = '%#Comment# ' .. model_label .. ' %*'
    else
      vim.wo[self.input_winid].statusline = ' '
    end
    pcall(vim.api.nvim_win_set_height, self.input_winid, self.layout.input_height)
    pcall(vim.api.nvim_win_set_width, self.input_winid, self.layout.width)
  end
  if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
    if self:_ui_opt('show_chat_title', true) then
      vim.wo[self.chat_winid].winbar = self:_winbar('Chat - ' .. session_name)
    else
      vim.wo[self.chat_winid].winbar = ''
    end
    pcall(vim.api.nvim_win_set_width, self.chat_winid, self.layout.width)
  end

  local function one_line(value)
    if value == nil then
      return ''
    end
    local text = tostring(value)
    text = text:gsub('\r\n', ' '):gsub('\n', ' '):gsub('\r', ' ')
    text = text:gsub('%s+', ' ')
    return text
  end

  local queue_lines = {}
  local current_request = state.current_request
  if current_request and type(current_request.message) == 'string' and current_request.message ~= '' then
    table.insert(queue_lines, '- Running: ' .. one_line(current_request.message))
  else
    table.insert(queue_lines, '- Running: (none)')
  end

  local queue = state.request_queue or {}
  local auto_hide_queue = self:_ui_opt('auto_hide_queue_when_empty', false)
  local show_queue = (not auto_hide_queue) or #queue > 0

  if #queue > 0 then
    for idx, item in ipairs(queue) do
      local text = one_line(item.message or '')
      table.insert(queue_lines, '- [' .. tostring(idx) .. '] ' .. text)
    end
  else
    table.insert(queue_lines, '- [empty]')
  end

  if self.queue_bufnr and vim.api.nvim_buf_is_valid(self.queue_bufnr) then
    vim.api.nvim_buf_set_option(self.queue_bufnr, 'modifiable', true)
    vim.api.nvim_buf_set_option(self.queue_bufnr, 'readonly', false)
    vim.api.nvim_buf_set_lines(self.queue_bufnr, 0, -1, false, queue_lines)
    vim.api.nvim_buf_set_option(self.queue_bufnr, 'modifiable', false)
    vim.api.nvim_buf_set_option(self.queue_bufnr, 'readonly', true)
  end

  if show_queue then
    self.queue_winid = self:_open_or_update_context_win(
      self.queue_winid,
      self.queue_bufnr,
      self:_ui_opt('show_queue_title', true) and 'Queue' or '',
      0,
      self.layout.queue_height
    )
    if self.queue_winid and vim.api.nvim_win_is_valid(self.queue_winid) then
      pcall(vim.api.nvim_win_set_width, self.queue_winid, self.layout.width)
    end
  else
    self:_close_panel_internal('queue_winid')
  end

  self._suppress_close = false
end

function WindowManager:_render_chat_lines(lines, roles)
  if not self.chat_bufnr or not vim.api.nvim_buf_is_valid(self.chat_bufnr) then
    return
  end
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', false)
  vim.api.nvim_buf_set_lines(self.chat_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', true)
  self:_highlight_roles(self.chat_bufnr, roles)

  if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
    local line_count = vim.api.nvim_buf_line_count(self.chat_bufnr)
    if line_count > 0 then
      vim.api.nvim_win_set_cursor(self.chat_winid, {line_count, 0})
    end
  end
end

function WindowManager:_with_status_footer(formatted, chat_manager)
  local status_lines = chat_manager:get_status_lines()
  if #status_lines == 0 then
    return formatted
  end
  table.insert(formatted, '')
  for _, line in ipairs(status_lines) do
    table.insert(formatted, line)
  end
  return formatted
end

function WindowManager:update_chat_display(chat_manager)
  if not self.chat_bufnr or not vim.api.nvim_buf_is_valid(self.chat_bufnr) then
    return
  end

  self.last_displayed_content = ''
  local formatted, roles = chat_manager:format_messages_for_display()
  roles = roles or {}

  if #formatted == 0 then
    formatted = { 'Cursor Chat', '' }
    roles = {}
  end

  self:_render_chat_lines(self:_with_status_footer(formatted, chat_manager), roles)
end

function WindowManager:update_chat_display_streaming(chat_manager, streaming_response)
  if not self.chat_bufnr or not vim.api.nvim_buf_is_valid(self.chat_bufnr) then
    return
  end

  local new_content = streaming_response or ''
  if new_content == '' then
    return
  end

  local clean_content = new_content
  clean_content = clean_content:gsub('{%s*"[^"]*"%s*:%s*[^}]*}', '')
  clean_content = clean_content:gsub('"type"%s*:%s*"[^"]*"', '')
  clean_content = clean_content:gsub('"text"%s*:%s*"([^"]*)"', '%1')

  if clean_content == '' or clean_content:match('^%s*{%s*$') then
    return
  end

  local formatted, roles = chat_manager:format_messages_for_display()
  roles = roles or {}
  if #formatted == 0 then
    formatted = {}
    roles = {}
  end

  local last_role = roles[#roles]
  if not last_role or last_role.role ~= 'assistant' then
    table.insert(roles, { line = #formatted, role = 'assistant' })
    table.insert(formatted, ChatManager.ASSISTANT_LABEL)
    table.insert(formatted, '')
  end

  local stream_lines = vim.split(clean_content, '\n', { plain = true, trimempty = false })
  for i, line in ipairs(stream_lines) do
    stream_lines[i] = line:gsub('\r', '')
  end
  if #stream_lines == 0 then
    stream_lines = { '' }
  end
  for _, line in ipairs(stream_lines) do
    table.insert(formatted, line)
  end

  self.last_displayed_content = clean_content
  self:_render_chat_lines(self:_with_status_footer(formatted, chat_manager), roles)
end

function WindowManager:get_user_input()
  if not self.input_bufnr or not vim.api.nvim_buf_is_valid(self.input_bufnr) then
    return ''
  end
  
  local lines = vim.api.nvim_buf_get_lines(self.input_bufnr, 0, -1, false)
  local message = table.concat(lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
  return message
end

function WindowManager:focus_input(at_end)
  if self.input_winid and vim.api.nvim_win_is_valid(self.input_winid) then
    vim.api.nvim_set_current_win(self.input_winid)
    if at_end then
      local line = ''
      if self.input_bufnr and vim.api.nvim_buf_is_valid(self.input_bufnr) then
        line = vim.api.nvim_buf_get_lines(self.input_bufnr, 0, 1, false)[1] or ''
      end
      vim.api.nvim_win_set_cursor(self.input_winid, { 1, #line })
      vim.cmd('startinsert!')
      return
    end
    vim.api.nvim_win_set_cursor(self.input_winid, {1, 0})
    vim.cmd('stopinsert')
    vim.defer_fn(function()
      vim.api.nvim_feedkeys('i', 'n', false)
    end, 10)
  end
end

function WindowManager:focus_chat()
  if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
    vim.api.nvim_set_current_win(self.chat_winid)
    local line_count = vim.api.nvim_buf_line_count(self.chat_bufnr)
    if line_count > 0 then
      vim.api.nvim_win_set_cursor(self.chat_winid, {line_count, 0})
    end
    vim.cmd('stopinsert')
  end
end

function WindowManager:focus_panel()
  if self.queue_winid and vim.api.nvim_win_is_valid(self.queue_winid) then
    vim.api.nvim_set_current_win(self.queue_winid)
    vim.cmd('stopinsert')
  end
end

function WindowManager:clear_input()
  if self.input_bufnr and vim.api.nvim_buf_is_valid(self.input_bufnr) then
    vim.api.nvim_buf_set_lines(self.input_bufnr, 0, -1, false, {''})
  end
end

function WindowManager:set_input_text(text)
  if self.input_bufnr and vim.api.nvim_buf_is_valid(self.input_bufnr) then
    local lines = {}
    for line in text:gmatch('[^\r\n]+') do
      table.insert(lines, line)
    end
    if #lines == 0 then
      lines = {text}
    end
    vim.api.nvim_buf_set_lines(self.input_bufnr, 0, -1, false, lines)
  end
end

return WindowManager

