local BindingManager = {}
BindingManager.__index = BindingManager

function BindingManager.new(app_manager)
  local self = setmetatable({}, BindingManager)
  self.app_manager = app_manager
  self.default_bindings = {
    chat = {
      send_message = "<CR>",
      send_message_insert = "<C-CR>",
      close = "q",
      stop = "<C-c>",
      focus_toggle = "<C-]>",
      open_item = "<CR>",
      open_item_alt = "gf",
      queue_cancel = "X",
      queue_move_up = "<C-k>",
      queue_move_down = "<C-j>",
    },
    diff = {
      apply = "a",
      revert = "r",
      close = "q",
    },
    review = {
      accept = "a",
      reject = "r",
      accept_all = "A",
      reject_all = "R",
      diff = "d",
      close = "q",
    },
  }
  self.bindings = {}
  self.enabled = true
  return self
end

function BindingManager:setup(opts)
  opts = opts or {}
  
  if opts.enabled == false then
    self.enabled = false
    return
  end

  self.enabled = true
  
  self.bindings = {
    chat = vim.tbl_extend("force", self.default_bindings.chat, opts.chat or {}),
    diff = vim.tbl_extend("force", self.default_bindings.diff, opts.diff or {}),
    review = vim.tbl_extend("force", self.default_bindings.review, opts.review or {}),
  }
end

function BindingManager:register_chat_bindings(window_manager)
  if not self.enabled or not self.bindings.chat then
    return
  end

  local app_mgr = self.app_manager
  local input_bufnr = window_manager.input_bufnr
  local chat_bufnr = window_manager.chat_bufnr
  local queue_bufnr = window_manager.queue_bufnr

  if not input_bufnr or not chat_bufnr then
    return
  end

  local function close_chat()
    app_mgr:close()
  end

  local function open_affected_file()
    app_mgr:open_affected_file_under_cursor()
  end

  local function register_history_bindings(bufnr)
    if not bufnr then
      return
    end

    if self.bindings.chat.close then
      vim.keymap.set('n', self.bindings.chat.close, close_chat, {
        buffer = bufnr,
        desc = "cursor chat: close",
        silent = true,
        noremap = true,
      })
    end

    if self.bindings.chat.focus_toggle then
      vim.keymap.set('n', self.bindings.chat.focus_toggle, function()
        app_mgr:cycle_focus_forward()
      end, {
        buffer = bufnr,
        desc = "cursor chat: cycle focus",
        silent = true,
        noremap = true,
      })
    end

    if self.bindings.chat.open_item then
      vim.keymap.set('n', self.bindings.chat.open_item, open_affected_file, {
        buffer = bufnr,
        desc = "cursor chat: open item",
        silent = true,
        noremap = true,
      })
    end

    if self.bindings.chat.open_item_alt then
      vim.keymap.set('n', self.bindings.chat.open_item_alt, open_affected_file, {
        buffer = bufnr,
        desc = "cursor chat: open item alt",
        silent = true,
        noremap = true,
      })
    end

    if self.bindings.chat.queue_cancel then
      vim.keymap.set('n', self.bindings.chat.queue_cancel, function()
        app_mgr:cancel_queued_request_under_cursor()
      end, {
        buffer = bufnr,
        desc = "cursor chat: cancel queued request",
        silent = true,
        noremap = true,
      })
    end

    if self.bindings.chat.queue_move_up then
      vim.keymap.set('n', self.bindings.chat.queue_move_up, function()
        app_mgr:move_queued_request_up_under_cursor()
      end, {
        buffer = bufnr,
        desc = "cursor chat: move queued request up",
        silent = true,
        noremap = true,
      })
    end

    if self.bindings.chat.queue_move_down then
      vim.keymap.set('n', self.bindings.chat.queue_move_down, function()
        app_mgr:move_queued_request_down_under_cursor()
      end, {
        buffer = bufnr,
        desc = "cursor chat: move queued request down",
        silent = true,
        noremap = true,
      })
    end
  end

  register_history_bindings(chat_bufnr)
  register_history_bindings(queue_bufnr)

  vim.bo[input_bufnr].completefunc = "v:lua.require'cursor.slash'.complete"
  vim.api.nvim_buf_call(input_bufnr, function()
    pcall(function()
      require('cmp').setup.buffer { enabled = false }
    end)
  end)

  -- Keep the previous completeopt in a closure so we can restore it if
  -- the input buffer is wiped while still in insert (InsertLeave may
  -- not run, and vim.b is already gone).
  local saved_completeopt = nil

  local function apply_completeopt()
    if saved_completeopt == nil then
      saved_completeopt = vim.o.completeopt
    end
    if vim.api.nvim_buf_is_valid(input_bufnr) then
      vim.b[input_bufnr].cursor_saved_completeopt = saved_completeopt
    end
    vim.o.completeopt = 'menu,menuone,noinsert'
  end

  local function restore_completeopt()
    if saved_completeopt == nil then
      return
    end
    vim.o.completeopt = saved_completeopt
    saved_completeopt = nil
    if vim.api.nvim_buf_is_valid(input_bufnr) then
      vim.b[input_bufnr].cursor_saved_completeopt = nil
    end
  end

  apply_completeopt()

  vim.api.nvim_create_autocmd('InsertEnter', {
    buffer = input_bufnr,
    callback = apply_completeopt,
  })
  vim.api.nvim_create_autocmd('InsertLeave', {
    buffer = input_bufnr,
    callback = restore_completeopt,
  })
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    buffer = input_bufnr,
    callback = restore_completeopt,
  })
  local input_win = window_manager.input_winid
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(input_win),
      once = true,
      callback = restore_completeopt,
    })
  end

  local slash_complete_pending = false
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChangedP' }, {
    buffer = input_bufnr,
    callback = function()
      if slash_complete_pending then
        return
      end
      slash_complete_pending = true
      vim.schedule(function()
        slash_complete_pending = false
        if not vim.api.nvim_buf_is_valid(input_bufnr) then
          return
        end
        if vim.api.nvim_get_current_buf() ~= input_bufnr then
          return
        end
        require('cursor.slash').try_complete()
      end)
    end,
  })

  vim.keymap.set('i', '<Tab>', function()
    if vim.fn.pumvisible() == 1 then
      return '<C-n>'
    end
    local col = vim.fn.col('.')
    local line = vim.api.nvim_get_current_line()
    local before = line:sub(1, col - 1)
    if before:match('^%s*/') then
      return '<C-x><C-u>'
    end
    return '<Tab>'
  end, {
    buffer = input_bufnr,
    expr = true,
    silent = true,
    desc = 'cursor chat: complete slash command',
  })

  vim.keymap.set('i', '<S-Tab>', function()
    if vim.fn.pumvisible() == 1 then
      return '<C-p>'
    end
    return '<S-Tab>'
  end, {
    buffer = input_bufnr,
    expr = true,
    silent = true,
    desc = 'cursor chat: previous slash completion',
  })

  vim.keymap.set('i', '<CR>', function()
    if vim.fn.pumvisible() == 1 then
      local word = require('cursor.slash').selected_word()
      local typed = window_manager:get_user_input()
      local already = word and (typed == word or typed:sub(-#word) == word)
      if not already then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), 'n', false)
        return
      end
    end

    local message = window_manager:get_user_input()

    if message ~= '' and not message:match('^%s*$') then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
      vim.schedule(function()
        app_mgr:handle_send_message(message)
      end)
      return
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'n', false)
  end, {
    buffer = input_bufnr,
    desc = "cursor chat: accept slash command or send",
    silent = true,
    noremap = true,
  })
  
  if self.bindings.chat.close then
    vim.keymap.set('n', self.bindings.chat.close, close_chat, {
      buffer = input_bufnr,
      desc = "cursor chat: close",
      silent = true,
      noremap = true,
    })
  end

  if self.bindings.chat.focus_toggle then
    vim.keymap.set('n', self.bindings.chat.focus_toggle, function()
      app_mgr:cycle_focus_forward()
    end, {
      buffer = input_bufnr,
      desc = "cursor chat: cycle focus",
      silent = true,
      noremap = true,
    })

    vim.keymap.set('i', self.bindings.chat.focus_toggle, function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
      vim.schedule(function()
        app_mgr:cycle_focus_forward()
      end)
    end, {
      buffer = input_bufnr,
      desc = "cursor chat: cycle focus",
      silent = true,
      noremap = true,
    })
  end

  if self.bindings.chat.stop then
    local function stop_request()
      app_mgr:stop_request()
    end
    vim.keymap.set('n', self.bindings.chat.stop, stop_request, {
      buffer = input_bufnr,
      desc = "cursor chat: stop request",
      silent = true,
      noremap = true,
    })
    vim.keymap.set('i', self.bindings.chat.stop, function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
      vim.schedule(function()
        app_mgr:stop_request()
      end)
    end, {
      buffer = input_bufnr,
      desc = "cursor chat: stop request",
      silent = true,
      noremap = true,
    })
  end
end

function BindingManager:register_review_bindings(bufnr)
  if not self.enabled or not self.bindings.review or not bufnr then
    return
  end
  if vim.b[bufnr].cursor_review_bound then
    return
  end
  vim.b[bufnr].cursor_review_bound = true

  local app_mgr = self.app_manager
  local function if_review(fn)
    return function()
      if vim.fn.getqflist({ title = 1 }).title ~= 'Cursor Changes' then
        return
      end
      fn()
    end
  end
  local maps = {
    accept = if_review(function()
      app_mgr:accept_change()
    end),
    reject = if_review(function()
      app_mgr:reject_change()
    end),
    accept_all = if_review(function()
      app_mgr:accept_all_changes()
    end),
    reject_all = if_review(function()
      app_mgr:reject_all_changes()
    end),
    diff = if_review(function()
      app_mgr:diff_change()
    end),
    close = function()
      if vim.fn.getqflist({ title = 1 }).title == 'Cursor Changes' then
        vim.cmd('cclose')
      end
    end,
  }

  for action, fn in pairs(maps) do
    local lhs = self.bindings.review[action]
    if lhs then
      vim.keymap.set('n', lhs, fn, {
        buffer = bufnr,
        desc = 'cursor review: ' .. action,
        silent = true,
        noremap = true,
        nowait = true,
      })
    end
  end
end

function BindingManager:register_diff_bindings(bufnr)
  if not self.enabled or not self.bindings.diff then
    return
  end

  local function apply_changes()
    self.app_manager:apply_changes()
  end

  local function revert_changes()
    self.app_manager:revert_changes()
  end

  local function close_diff()
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end

  local commands = {
    apply = apply_changes,
    revert = revert_changes,
    close = close_diff,
  }

  for action, keymap in pairs(self.bindings.diff) do
    if commands[action] then
      vim.keymap.set("n", keymap, commands[action], {
        buffer = bufnr,
        desc = "cursor diff: " .. action,
        silent = true,
        noremap = true,
      })
    end
  end
end

function BindingManager:register_all_bindings(window_manager)
  if not window_manager then
    return
  end

  if window_manager.chat_bufnr and window_manager.input_bufnr then
    self:register_chat_bindings(window_manager)
  end
end

function BindingManager:register_diff_bindings_for_buffer(bufnr)
  if bufnr then
    self:register_diff_bindings(bufnr)
  end
end

function BindingManager:add_custom_binding(window_type, keymap, action, desc)
  if not self.enabled then
    return
  end

  if not self.bindings[window_type] then
    self.bindings[window_type] = {}
  end

  local bufnr = nil
  if window_type == "chat" and self.app_manager.window_manager then
    bufnr = self.app_manager.window_manager.chat_bufnr
  elseif window_type == "diff" then
    return
  end

  if bufnr then
    vim.keymap.set("n", keymap, action, {
      buffer = bufnr,
      desc = desc or "cursor custom",
      silent = true,
      noremap = true,
    })
  end
end

function BindingManager:get_bindings()
  return vim.deepcopy(self.bindings)
end

return BindingManager

