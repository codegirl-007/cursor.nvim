local WindowManager = {}
WindowManager.__index = WindowManager

function WindowManager.new()
  local self = setmetatable({}, WindowManager)
  
  self.chat_width = 50
  self.chat_bufnr = nil
  self.chat_winid = nil
  self.affected_bufnr = nil
  self.affected_winid = nil
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
    affected_height = 4,
    queue_height = 4,
    section_gap = 2,
  }
  self.panel_state = {
    model = 'auto',
    session_name = nil,
    affected_files = {},
    current_request = nil,
    request_queue = {},
  }
  
  return self
end


function WindowManager:_is_owned_chat_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  return vim.b[buf].cursor_chat_panel == true
end

function WindowManager:wipe_named_buffers()
  local seen = {}
  for _, buf in ipairs({
    self.chat_bufnr,
    self.input_bufnr,
    self.affected_bufnr,
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

function WindowManager:_ui_opt(key, fallback)
  if self.opts and self.opts.ui and self.opts.ui[key] ~= nil then
    return self.opts.ui[key]
  end
  return fallback
end

function WindowManager:create_chat_window()
  self:wipe_named_buffers()

  local chat_width = self.chat_width
  if self.opts and self.opts.chat_width then
    chat_width = self.opts.chat_width
  end
  
  local ui = vim.api.nvim_list_uis()[1]
  local width = ui.width
  local height = ui.height
  local affected_height = self:_ui_opt('affected_height', 4)
  local queue_height = self:_ui_opt('queue_height', 4)
  local section_gap = self:_ui_opt('section_gap', 2)
  
  self.chat_bufnr = self:_create_panel_buf('cursor-chat-history', true)
  self.input_bufnr = self:_create_panel_buf('cursor-chat-input', false)
  self.affected_bufnr = self:_create_panel_buf('cursor-chat-affected', true)
  self.queue_bufnr = self:_create_panel_buf('cursor-chat-queue', true)
  
  local input_height = self:_ui_opt('input_height', 3)
  local history_height = height - input_height - affected_height - queue_height - 6
  if history_height < 6 then
    history_height = 6
  end
  local col = width - chat_width - 1
  local base_row = history_height + 2
  self.layout = {
    width = chat_width,
    col = col,
    history_height = history_height,
    base_row = base_row,
    input_height = input_height,
    affected_height = affected_height,
    queue_height = queue_height,
    section_gap = section_gap,
  }
  
  self.chat_winid = vim.api.nvim_open_win(self.chat_bufnr, true, {
    relative = 'editor',
    width = chat_width,
    height = history_height,
    col = col,
    row = 1,
    style = 'minimal',
    border = 'single',
    title = self:_ui_opt('show_chat_title', true) and ' Chat ' or '',
    title_pos = 'center',
  })
  
  vim.api.nvim_win_set_option(self.chat_winid, 'number', false)
  vim.api.nvim_win_set_option(self.chat_winid, 'relativenumber', false)
  vim.api.nvim_win_set_option(self.chat_winid, 'wrap', true)
  vim.api.nvim_win_set_option(self.chat_winid, 'cursorline', false)
  vim.api.nvim_win_set_option(self.chat_winid, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(self.chat_winid, 'foldcolumn', '0')
  
  self.input_winid = vim.api.nvim_open_win(self.input_bufnr, true, {
    relative = 'editor',
    width = chat_width,
    height = input_height,
    col = col,
    row = base_row + affected_height + section_gap + queue_height + section_gap,
    style = 'minimal',
    border = 'single',
    title = self:_ui_opt('show_input_title', true) and ' Input ' or '',
    title_pos = 'center',
  })

  self.affected_winid = vim.api.nvim_open_win(self.affected_bufnr, false, {
    relative = 'editor',
    width = chat_width,
    height = affected_height,
    col = col,
    row = base_row,
    style = 'minimal',
    border = 'single',
    title = self:_ui_opt('show_affected_title', true) and ' Affected Files ' or '',
    title_pos = 'center',
  })

  self.queue_winid = vim.api.nvim_open_win(self.queue_bufnr, false, {
    relative = 'editor',
    width = chat_width,
    height = queue_height,
    col = col,
    row = base_row + affected_height + section_gap,
    style = 'minimal',
    border = 'single',
    title = self:_ui_opt('show_queue_title', true) and ' Queue ' or '',
    title_pos = 'center',
  })
  
  vim.api.nvim_win_set_option(self.input_winid, 'number', false)
  vim.api.nvim_win_set_option(self.input_winid, 'relativenumber', false)
  vim.api.nvim_win_set_option(self.input_winid, 'wrap', true)
  vim.api.nvim_win_set_option(self.input_winid, 'cursorline', false)
  vim.api.nvim_win_set_option(self.input_winid, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(self.input_winid, 'foldcolumn', '0')
  vim.api.nvim_win_set_option(self.input_winid, 'winfixheight', true)
  self:_setup_context_win_options(self.affected_winid)
  self:_setup_context_win_options(self.queue_winid)
  
  if self:_ui_opt('show_model_indicator', true) then
    vim.api.nvim_win_set_option(self.input_winid, 'statusline', '%#Comment# ' .. (self.panel_state.model == 'auto' and 'Auto' or tostring(self.panel_state.model)) .. ' %*')
  else
    vim.api.nvim_win_set_option(self.input_winid, 'statusline', '')
  end
  
  vim.api.nvim_buf_set_lines(self.input_bufnr, 0, -1, false, {''})
  vim.api.nvim_win_set_cursor(self.input_winid, {1, 0})
  vim.api.nvim_feedkeys('i', 'n', false)
  
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(self.chat_bufnr, 0, -1, false, {'# Cursor Chat', ''})
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', true)
  self:update_panel_display()

  self:_watch_panel_close('chat_winid')
  self:_watch_panel_close('input_winid')
  self:_watch_panel_close('affected_winid')
  self:_watch_panel_close('queue_winid')
end

function WindowManager:close_chat_window()
  self._suppress_close = true
  for _, win in ipairs({ self.chat_winid, self.input_winid, self.affected_winid, self.queue_winid }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  self:wipe_named_buffers()
  self.chat_winid = nil
  self.chat_bufnr = nil
  self.affected_winid = nil
  self.affected_bufnr = nil
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
    affected_files = state.affected_files or {},
    current_request = state.current_request,
    request_queue = state.request_queue or {},
  }
  self:update_panel_display()
end

function WindowManager:_setup_context_win_options(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  vim.api.nvim_win_set_option(winid, 'number', false)
  vim.api.nvim_win_set_option(winid, 'relativenumber', false)
  vim.api.nvim_win_set_option(winid, 'wrap', true)
  vim.api.nvim_win_set_option(winid, 'cursorline', false)
  vim.api.nvim_win_set_option(winid, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(winid, 'foldcolumn', '0')
  vim.api.nvim_win_set_option(winid, 'winfixheight', true)
end

function WindowManager:_open_or_update_context_win(winid, bufnr, title, row, height)
  local cfg = {
    relative = 'editor',
    width = self.layout.width,
    height = height,
    col = self.layout.col,
    row = row,
    style = 'minimal',
    border = 'single',
    title = title,
    title_pos = 'center',
  }
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_config(winid, cfg)
    return winid
  end
  local new_winid = vim.api.nvim_open_win(bufnr, false, cfg)
  self:_setup_context_win_options(new_winid)
  return new_winid
end

function WindowManager:update_panel_display()
  if not self.affected_bufnr or not vim.api.nvim_buf_is_valid(self.affected_bufnr) then
    return
  end

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
    if self:_ui_opt('show_model_indicator', true) then
      vim.api.nvim_win_set_option(self.input_winid, 'statusline', '%#Comment# ' .. model_label .. ' %*')
    else
      vim.api.nvim_win_set_option(self.input_winid, 'statusline', '')
    end
  end
  if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
    local chat_cfg = vim.api.nvim_win_get_config(self.chat_winid)
    if self:_ui_opt('show_chat_title', true) then
      chat_cfg.title = ' Chat - ' .. session_name .. ' '
    else
      chat_cfg.title = ''
    end
    chat_cfg.title_pos = 'center'
    vim.api.nvim_win_set_config(self.chat_winid, chat_cfg)
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

  local affected_lines = {}
  local affected = state.affected_files or {}
  if #affected == 0 then
    table.insert(affected_lines, '(none)')
  else
    for _, path in ipairs(affected) do
      table.insert(affected_lines, '- ' .. one_line(path))
    end
  end
  vim.api.nvim_buf_set_option(self.affected_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_option(self.affected_bufnr, 'readonly', false)
  vim.api.nvim_buf_set_lines(self.affected_bufnr, 0, -1, false, affected_lines)
  vim.api.nvim_buf_set_option(self.affected_bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(self.affected_bufnr, 'readonly', true)

  local queue_lines = {}
  local current_request = state.current_request
  if current_request and type(current_request.message) == 'string' and current_request.message ~= '' then
    table.insert(queue_lines, '- Running: ' .. one_line(current_request.message))
  else
    table.insert(queue_lines, '- Running: (none)')
  end

  local queue = state.request_queue or {}
  local auto_hide_queue = self:_ui_opt('auto_hide_queue_when_empty', false)
  local auto_hide_affected = self:_ui_opt('auto_hide_affected_when_empty', false)
  local show_queue = (not auto_hide_queue) or #queue > 0
  local show_affected = (not auto_hide_affected) or #affected > 0

  local ui = vim.api.nvim_list_uis()[1]
  local total_height = ui and ui.height or (self.layout.history_height + self.layout.input_height + 6)
  local gap = self.layout.section_gap or 2
  local reserved = self.layout.input_height + gap
  if show_affected then
    reserved = reserved + self.layout.affected_height + gap
  end
  if show_queue then
    reserved = reserved + self.layout.queue_height + gap
  end
  local dynamic_chat_height = total_height - reserved
  if dynamic_chat_height < 6 then
    dynamic_chat_height = 6
  end
  local base_row = dynamic_chat_height + gap
  self.layout.history_height = dynamic_chat_height
  self.layout.base_row = base_row

  if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
    local chat_cfg = vim.api.nvim_win_get_config(self.chat_winid)
    chat_cfg.height = dynamic_chat_height
    chat_cfg.row = 1
    chat_cfg.col = self.layout.col
    chat_cfg.width = self.layout.width
    vim.api.nvim_win_set_config(self.chat_winid, chat_cfg)
  end

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

  if show_affected then
    self.affected_winid = self:_open_or_update_context_win(
      self.affected_winid,
      self.affected_bufnr,
      self:_ui_opt('show_affected_title', true) and ' Affected Files ' or '',
      base_row,
      self.layout.affected_height
    )
  elseif self.affected_winid and vim.api.nvim_win_is_valid(self.affected_winid) then
    vim.api.nvim_win_close(self.affected_winid, true)
    self.affected_winid = nil
  end

  local input_row = self.layout.base_row
  input_row = base_row
  local queue_row = base_row
  if show_affected then
    queue_row = base_row + self.layout.affected_height + gap
  end
  if show_queue then
    self.queue_winid = self:_open_or_update_context_win(
      self.queue_winid,
      self.queue_bufnr,
      self:_ui_opt('show_queue_title', true) and ' Queue ' or '',
      queue_row,
      self.layout.queue_height
    )
    if self.queue_winid and vim.api.nvim_win_is_valid(self.queue_winid) then
      local queue_cfg = vim.api.nvim_win_get_config(self.queue_winid)
      queue_cfg.title = self:_ui_opt('show_queue_title', true) and ' Queue ' or ''
      queue_cfg.title_pos = 'center'
      vim.api.nvim_win_set_config(self.queue_winid, queue_cfg)
    end
    input_row = queue_row + self.layout.queue_height + gap
  else
    if self.queue_winid and vim.api.nvim_win_is_valid(self.queue_winid) then
      vim.api.nvim_win_close(self.queue_winid, true)
      self.queue_winid = nil
    end
    input_row = queue_row
  end

  if self.input_winid and vim.api.nvim_win_is_valid(self.input_winid) then
    local input_cfg = vim.api.nvim_win_get_config(self.input_winid)
    input_cfg.row = input_row
    input_cfg.col = self.layout.col
    input_cfg.width = self.layout.width
    input_cfg.height = self.layout.input_height
    vim.api.nvim_win_set_config(self.input_winid, input_cfg)
  end
end

function WindowManager:update_chat_display(chat_manager)
  if not self.chat_bufnr or not vim.api.nvim_buf_is_valid(self.chat_bufnr) then
    return
  end
  
  self.last_displayed_content = ''
  local formatted = chat_manager:format_messages_for_display()
  
  if #formatted == 0 then
    formatted = {'# Cursor Chat', ''}
  end
  
  local status = chat_manager:get_status()
  if status ~= 'idle' then
    local status_indicator = chat_manager:get_status_indicator()
    if status_indicator ~= '' then
      local has_assistant = false
      for _, line in ipairs(formatted) do
        if line == '## Assistant' then
          has_assistant = true
          break
        end
      end
      
      if not has_assistant then
        table.insert(formatted, '## Assistant')
        table.insert(formatted, '')
      end
      
      table.insert(formatted, status_indicator)
    end
  end
  
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', false)
  vim.api.nvim_buf_set_lines(self.chat_bufnr, 0, -1, false, formatted)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', true)
  
  if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
    local line_count = vim.api.nvim_buf_line_count(self.chat_bufnr)
    if line_count > 0 then
      local cursor_line = math.min(line_count, #formatted)
      vim.api.nvim_win_set_cursor(self.chat_winid, {cursor_line, 0})
    end
  end
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
  
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', false)
  
  local current_lines = vim.api.nvim_buf_get_lines(self.chat_bufnr, 0, -1, false)
  local assistant_start_idx = nil
  local streaming_marker_idx = nil
  
  for i, line in ipairs(current_lines) do
      if line == '## Assistant' then
        assistant_start_idx = i
      elseif line:match('^[⏳✨⏹]') or line:match('Processing') or line:match('Streaming') or line:match('Stopped') then
        streaming_marker_idx = i
    end
  end
  
  if not assistant_start_idx then
    local formatted = chat_manager:format_messages_for_display()
    table.insert(formatted, '## Assistant')
    table.insert(formatted, '')
    vim.api.nvim_buf_set_lines(self.chat_bufnr, 0, -1, false, formatted)
    assistant_start_idx = #formatted
    streaming_marker_idx = nil
  end
  
  local delta = ''
  if #clean_content > #self.last_displayed_content then
    delta = clean_content:sub(#self.last_displayed_content + 1)
  elseif clean_content ~= self.last_displayed_content then
    delta = clean_content
    self.last_displayed_content = ''
  end
  
  if delta ~= '' then
    -- Remove streaming marker if it exists
    if streaming_marker_idx then
      local marker_start = streaming_marker_idx - 1
      if marker_start > 0 and current_lines[marker_start] == '' then
        marker_start = marker_start - 1
      end
      vim.api.nvim_buf_set_lines(self.chat_bufnr, marker_start, streaming_marker_idx, false, {})
    end
    
    local parts = {}
    local current_part = ''
    
    for i = 1, #delta do
      local char = delta:sub(i, i)
      if char == '\n' then
        if current_part ~= '' then
          table.insert(parts, {text = current_part, newline = true})
          current_part = ''
        else
          table.insert(parts, {text = '', newline = true})
        end
      elseif char ~= '\r' then
        current_part = current_part .. char
      end
    end
    
    if current_part ~= '' then
      table.insert(parts, {text = current_part, newline = false})
    end
    
    for _, part in ipairs(parts) do
      if not vim.api.nvim_buf_is_valid(self.chat_bufnr) then
        break
      end
      
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', false)
      
      local line_count = vim.api.nvim_buf_line_count(self.chat_bufnr)
      
      if part.newline then
        if part.text ~= '' then
          vim.api.nvim_buf_set_lines(self.chat_bufnr, -1, -1, false, {part.text})
        else
          vim.api.nvim_buf_set_lines(self.chat_bufnr, -1, -1, false, {''})
        end
      else
        if line_count > 0 then
          local last_idx = line_count - 1
          local last_line = vim.api.nvim_buf_get_lines(self.chat_bufnr, last_idx, last_idx + 1, false)[1] or ''
          vim.api.nvim_buf_set_lines(self.chat_bufnr, last_idx, last_idx + 1, false, {last_line .. part.text})
        else
          vim.api.nvim_buf_set_lines(self.chat_bufnr, -1, -1, false, {part.text})
        end
      end
    end
    
    self.last_displayed_content = clean_content
    
    local current_lines = vim.api.nvim_buf_get_lines(self.chat_bufnr, 0, -1, false)
    local status_line_idx = nil
    
    for i, line in ipairs(current_lines) do
      if line:match('^[⏳✨⏹]') or line:match('Processing') or line:match('Streaming') or line:match('Stopped') then
        status_line_idx = i
        break
      end
    end
    
    local status_indicator = chat_manager:get_status_indicator()
    if status_indicator ~= '' then
      if status_line_idx then
        vim.api.nvim_buf_set_lines(self.chat_bufnr, status_line_idx - 1, status_line_idx, false, {status_indicator})
      else
        vim.api.nvim_buf_set_lines(self.chat_bufnr, -1, -1, false, {'', status_indicator})
      end
    elseif status_line_idx then
      local marker_start = status_line_idx - 1
      if marker_start > 0 and current_lines[marker_start] == '' then
        marker_start = marker_start - 1
      end
      vim.api.nvim_buf_set_lines(self.chat_bufnr, marker_start, status_line_idx, false, {})
    end
    
    vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', false)
    vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', true)
    
    if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
      local line_count = vim.api.nvim_buf_line_count(self.chat_bufnr)
      if line_count > 0 then
        vim.api.nvim_win_set_cursor(self.chat_winid, {line_count, 0})
      end
    end
    return
  else
    local status_indicator = chat_manager:get_status_indicator()
    if status_indicator ~= '' then
      local current_lines = vim.api.nvim_buf_get_lines(self.chat_bufnr, 0, -1, false)
      local status_line_idx = nil
      
      for i, line in ipairs(current_lines) do
        if line:match('^[⏳✨⏹]') or line:match('Processing') or line:match('Streaming') or line:match('Stopped') then
          status_line_idx = i
          break
        end
      end
      
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', false)
      
      if status_line_idx then
        vim.api.nvim_buf_set_lines(self.chat_bufnr, status_line_idx - 1, status_line_idx, false, {status_indicator})
      else
        vim.api.nvim_buf_set_lines(self.chat_bufnr, -1, -1, false, {'', status_indicator})
      end
      
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', false)
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', true)
    else
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'modifiable', false)
      vim.api.nvim_buf_set_option(self.chat_bufnr, 'readonly', true)
    end
    
    if self.chat_winid and vim.api.nvim_win_is_valid(self.chat_winid) then
      local line_count = vim.api.nvim_buf_line_count(self.chat_bufnr)
      if line_count > 0 then
        vim.api.nvim_win_set_cursor(self.chat_winid, {line_count, 0})
      end
    end
  end
end

function WindowManager:get_user_input()
  if not self.input_bufnr or not vim.api.nvim_buf_is_valid(self.input_bufnr) then
    return ''
  end
  
  local lines = vim.api.nvim_buf_get_lines(self.input_bufnr, 0, -1, false)
  local message = table.concat(lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
  return message
end

function WindowManager:focus_input()
  if self.input_winid and vim.api.nvim_win_is_valid(self.input_winid) then
    vim.api.nvim_set_current_win(self.input_winid)
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
  if self.affected_winid and vim.api.nvim_win_is_valid(self.affected_winid) then
    vim.api.nvim_set_current_win(self.affected_winid)
    vim.cmd('stopinsert')
    return
  end
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

