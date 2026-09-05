local ChatManager = {}
ChatManager.__index = ChatManager

function ChatManager.new()
  local self = setmetatable({}, ChatManager)
  
  self.messages = {}
  self.last_changes = {}
  self.input_buffer = {}
  self.streaming_response = ''
  self.status = 'idle'
  self.last_sent_message = ''
  self.affected_files = {}
  
  return self
end

function ChatManager:initialize()
  self.messages = {}
  self.last_changes = {}
  self.input_buffer = {}
  self.status = 'idle'
  self.streaming_response = ''
  self.last_sent_message = ''
  self.affected_files = {}
end

function ChatManager:cleanup()
  self.messages = {}
  self.last_changes = {}
  self.input_buffer = {}
  self.streaming_response = ''
  self.last_sent_message = ''
  self.status = 'idle'
  self.affected_files = {}
end

function ChatManager:add_message(role, content)
  table.insert(self.messages, {
    role = role,
    content = content,
    timestamp = os.time()
  })
end

function ChatManager:upsert_activity_message(content)
  if not content or content == '' then
    return
  end

  local last = self.messages[#self.messages]
  if last and last.role == 'assistant' and type(last.content) == 'string' and last.content:match('^Activity:') then
    last.content = content
    last.timestamp = os.time()
    return
  end

  self:add_message('assistant', content)
end

function ChatManager:get_messages()
  return self.messages
end

function ChatManager:get_conversation_context(max_messages, max_chars)
  local limit_messages = max_messages or 40
  local limit_chars = max_chars or 12000
  local context_lines = {}
  local messages = self.messages or {}
  local start_idx = 1

  if #messages > limit_messages then
    start_idx = #messages - limit_messages + 1
  end

  for i = start_idx, #messages do
    local msg = messages[i]
    if type(msg) == 'table' and type(msg.content) == 'string' and msg.content ~= '' then
      local role = msg.role == 'user' and 'User' or 'Assistant'
      table.insert(context_lines, role .. ':')
      table.insert(context_lines, msg.content)
      table.insert(context_lines, '')
    end
  end

  local context = table.concat(context_lines, '\n')
  if #context > limit_chars then
    context = context:sub(#context - limit_chars + 1)
  end
  return context
end

function ChatManager:get_input()
  return table.concat(self.input_buffer, '\n')
end

function ChatManager:set_input(input)
  self.input_buffer = {}
  for line in input:gmatch('[^\r\n]+') do
    table.insert(self.input_buffer, line)
  end
end

function ChatManager:clear_input()
  self.input_buffer = {}
end

function ChatManager:set_last_changes(changes)
  self.last_changes = changes
end

function ChatManager:get_last_changes()
  return self.last_changes
end

function ChatManager:clear_last_changes()
  self.last_changes = {}
end

function ChatManager:set_streaming_response(response)
  self.streaming_response = response
end

function ChatManager:clear_streaming_response()
  self.streaming_response = ''
end

function ChatManager:get_streaming_response()
  return self.streaming_response
end

function ChatManager:set_status(status)
  self.status = status or 'idle'
end

function ChatManager:get_status()
  return self.status
end

function ChatManager:get_status_indicator()
  local status_indicators = {
    idle = '',
    processing = '⏳ Processing...',
    streaming = '✨ Streaming...',
    stopped = '⏹ Stopped',
  }
  return status_indicators[self.status] or ''
end

function ChatManager:set_last_sent_message(message)
  self.last_sent_message = message or ''
end

function ChatManager:get_last_sent_message()
  return self.last_sent_message
end

function ChatManager:add_affected_files(paths)
  if type(paths) ~= 'table' then
    return
  end

  local seen = {}
  for _, existing in ipairs(self.affected_files) do
    seen[existing] = true
  end

  for _, path in ipairs(paths) do
    if type(path) == 'string' and path ~= '' and not seen[path] then
      table.insert(self.affected_files, path)
      seen[path] = true
    end
  end
end

function ChatManager:clear_affected_files()
  self.affected_files = {}
end

function ChatManager:get_affected_files()
  return self.affected_files
end

function ChatManager:get_state()
  return {
    messages = vim.deepcopy(self.messages),
    last_sent_message = self.last_sent_message,
    affected_files = vim.deepcopy(self.affected_files),
  }
end

function ChatManager:load_state(state)
  self:initialize()
  if type(state) ~= 'table' then
    return
  end

  if type(state.messages) == 'table' then
    self.messages = vim.deepcopy(state.messages)
  end
  if type(state.last_sent_message) == 'string' then
    self.last_sent_message = state.last_sent_message
  end
  if type(state.affected_files) == 'table' then
    self.affected_files = vim.deepcopy(state.affected_files)
  end
end

ChatManager.USER_LABEL = 'You'
ChatManager.ASSISTANT_LABEL = 'Assistant'

local function content_lines(content)
  if type(content) ~= 'string' or content == '' then
    return { content or '' }
  end
  local lines = vim.split(content, '\n', { plain = true, trimempty = false })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub('\r', '')
  end
  return lines
end

local function is_activity_content(content)
  return type(content) == 'string' and content:match('^Activity:') ~= nil
end

function ChatManager:get_activity_line()
  for i = #self.messages, 1, -1 do
    local msg = self.messages[i]
    if msg.role == 'assistant' and is_activity_content(msg.content) then
      return msg.content
    end
    if msg.role == 'user' or (msg.role == 'assistant' and not is_activity_content(msg.content)) then
      return nil
    end
  end
  return nil
end

function ChatManager:get_status_lines()
  local lines = {}
  if self:get_status() == 'idle' then
    return lines
  end
  local activity = self:get_activity_line()
  if activity then
    table.insert(lines, activity)
  end
  local status = self:get_status_indicator()
  if status ~= '' then
    table.insert(lines, status)
  end
  return lines
end

function ChatManager:format_messages_for_display()
  local formatted = {}
  local roles = {}

  for _, msg in ipairs(self.messages) do
    if (msg.role == 'user' or msg.role == 'assistant') and not is_activity_content(msg.content) then
      table.insert(roles, { line = #formatted, role = msg.role })
      table.insert(formatted, msg.role == 'user' and ChatManager.USER_LABEL or ChatManager.ASSISTANT_LABEL)
      table.insert(formatted, '')
      for _, line in ipairs(content_lines(msg.content)) do
        table.insert(formatted, line)
      end
      table.insert(formatted, '')
    end
  end

  return formatted, roles
end

return ChatManager

