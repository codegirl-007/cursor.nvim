local M = {}

-- Client-side commands. These map to existing Neovim actions and never
-- go to ACP (the CLI versions are TUI pickers, not prompt text).
M.LOCAL = {
  {
    name = 'model',
    description = 'Choose or set the Cursor model',
    takes_arg = true,
  },
  {
    name = 'clear',
    description = 'Start a new chat session',
    aliases = { 'new', 'new-chat', 'newchat' },
  },
  {
    name = 'resume',
    description = 'Switch or manage chat sessions',
  },
  {
    name = 'rewind',
    description = 'Revert the last checkpoint',
  },
  {
    name = 'rename',
    description = 'Rename the current session',
    takes_arg = true,
  },
  {
    name = 'help',
    description = 'List slash commands',
    takes_arg = true,
  },
  {
    name = 'quit',
    description = 'Close Cursor chat',
    aliases = { 'exit' },
  },
}

local function current_app()
  local ok, cursor = pcall(require, 'cursor')
  if ok and cursor and type(cursor.get_app_manager) == 'function' then
    return cursor.get_app_manager()
  end
  return nil
end

function M.parse(text)
  if type(text) ~= 'string' then
    return nil
  end
  local trimmed = text:gsub('^%s+', ''):gsub('%s+$', '')
  local name, args = trimmed:match('^/([%w_%.%-]+)%s*(.*)$')
  if not name or name == '' then
    return nil
  end
  return {
    name = name,
    args = args or '',
    raw = trimmed,
  }
end

function M.resolve_local(name)
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  local needle = name:lower()
  for _, cmd in ipairs(M.LOCAL) do
    if cmd.name == needle then
      return cmd
    end
    for _, alias in ipairs(cmd.aliases or {}) do
      if alias == needle then
        return cmd
      end
    end
  end
  return nil
end

local function advertised_commands(app)
  app = app or current_app()
  if not app or not app.cursor_manager then
    return {}
  end
  local getter = app.cursor_manager.get_available_commands
  if type(getter) ~= 'function' then
    return {}
  end
  return getter(app.cursor_manager) or {}
end

function M.list(app)
  local seen = {}
  local items = {}

  local function add(item)
    if not item.name or seen[item.name] then
      return
    end
    seen[item.name] = true
    table.insert(items, item)
  end

  for _, cmd in ipairs(M.LOCAL) do
    add({
      name = cmd.name,
      description = cmd.description or '',
      local_cmd = true,
      takes_arg = cmd.takes_arg == true,
    })
    for _, alias in ipairs(cmd.aliases or {}) do
      add({
        name = alias,
        description = (cmd.description or '') .. ' (alias of /' .. cmd.name .. ')',
        local_cmd = true,
        takes_arg = cmd.takes_arg == true,
      })
    end
  end

  for _, cmd in ipairs(advertised_commands(app)) do
    add({
      name = cmd.name,
      description = cmd.description or '',
      local_cmd = false,
      takes_arg = type(cmd.input_hint) == 'string' and cmd.input_hint ~= '',
      input_hint = cmd.input_hint,
    })
  end

  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return items
end

local function matches_prefix(word, base)
  if not base or base == '' then
    return true
  end
  return word:sub(1, #base) == base
end

local function complete_names(base)
  local needle = (base or ''):gsub('^/', '')
  local matches = {}
  for _, item in ipairs(M.list()) do
    if matches_prefix(item.name, needle) then
      table.insert(matches, {
        word = '/' .. item.name,
        menu = item.description or '',
        kind = item.local_cmd and 'l' or 'c',
      })
    end
  end
  return matches
end

local function complete_args(name, base)
  local matches = {}
  if name == 'model' then
    for _, item in ipairs(require('cursor.cursor_manager').list_models()) do
      if matches_prefix(item.id, base) then
        table.insert(matches, {
          word = item.id,
          menu = item.name or '',
          kind = 'm',
        })
      end
    end
    return matches
  end

  if name == 'help' then
    for _, item in ipairs(M.list()) do
      if matches_prefix(item.name, base) then
        table.insert(matches, {
          word = item.name,
          menu = item.description or '',
          kind = item.local_cmd and 'l' or 'c',
        })
      end
    end
  end
  return matches
end

function M.selected_word()
  local info = vim.fn.complete_info({ 'selected', 'items' })
  if type(info) ~= 'table' or type(info.items) ~= 'table' then
    return nil
  end
  local idx = info.selected
  if type(idx) ~= 'number' or idx < 0 then
    return nil
  end
  local item = info.items[idx + 1]
  if type(item) == 'table' then
    return item.word
  end
  if type(item) == 'string' then
    return item
  end
  return nil
end

-- Show the slash menu for the current input line. Returns true if a popup opened.
function M.try_complete()
  if vim.fn.mode() ~= 'i' then
    return false
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col('.')
  local before = line:sub(1, col - 1)
  if not before:match('^%s*/') then
    M._last_complete_key = nil
    return false
  end

  local start_col
  local items
  local name, arg = before:match('^%s*/([%w_%.%-]+)%s+(.*)$')
  if name then
    local _, _, arg_pos = before:find('^%s*/[%w_%.%-]+%s+()')
    start_col = arg_pos
    items = complete_args(name, arg or '')
  elseif before:match('^%s*/[%w_%.%-]*$') then
    start_col = before:find('/')
    items = complete_names(before:sub(start_col))
  else
    M._last_complete_key = nil
    return false
  end

  if not items or #items == 0 or not start_col then
    M._last_complete_key = nil
    return false
  end

  -- Avoid re-opening the same popup (TextChangedP can retrigger us).
  if M._last_complete_key == before and vim.fn.pumvisible() == 1 then
    return true
  end
  M._last_complete_key = before

  vim.fn.complete(start_col, items)
  return true
end

-- completefunc for the chat input buffer. Used as:
--   vim.bo[buf].completefunc = "v:lua.require'cursor.slash'.complete"
function M.complete(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col('.')
  local before = line:sub(1, col - 1)

  if findstart == 1 then
    local _, _, arg_col = before:find('^%s*/[%w_%.%-]+%s+()')
    if arg_col then
      return arg_col - 1
    end
    local cmd_col = before:find('/[%w_%.%-]*$')
    if cmd_col then
      return cmd_col - 1
    end
    return -3
  end

  local name = before:match('^%s*/([%w_%.%-]+)%s+')
  if name then
    return complete_args(name, base or '')
  end
  return complete_names(base or '')
end

return M
