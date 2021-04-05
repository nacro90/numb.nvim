local numb = {}

local log = require('numb.log')

local api = vim.api

-- Stores windows original cursors
local win_cursors = {}
local opts = {show_numbers = true, show_cursorline = true}

local function peek(winnr, linenr)
   local bufnr = api.nvim_win_get_buf(winnr)
   local n_buf_lines = api.nvim_buf_line_count(bufnr)
   linenr = linenr < n_buf_lines and linenr or n_buf_lines
   if not win_cursors[winnr] then
      win_cursors[winnr] = {
         cursor = api.nvim_win_get_cursor(winnr),
         options = {
            number = api.nvim_win_get_option(winnr, 'number'),
            cursorline = api.nvim_win_get_option(winnr, 'cursorline'),
         },
      }
   end

   if opts.show_numbers then api.nvim_win_set_option(winnr, 'number', true) end
   if opts.show_cursorline then
      api.nvim_win_set_option(winnr, 'cursorline', true)
   end

   local original_column = win_cursors[winnr].cursor[2]
   local peek_cursor = {linenr, original_column}
   api.nvim_win_set_cursor(winnr, peek_cursor)
   vim.cmd('redraw')
end

local function unpeek(winnr)
   local orig_state = win_cursors[winnr]
   if orig_state then
      if opts.show_numbers then
         api.nvim_win_set_option(winnr, 'number', orig_state.options.number)
      end
      if opts.show_cursorline then
         api.nvim_win_set_option(winnr, 'cursorline',
            orig_state.options.cursorline)
      end
      local cursor = win_cursors[winnr].cursor
      api.nvim_win_set_cursor(winnr, cursor)
   end
   win_cursors[winnr] = nil
end

function numb.on_cmdline_changed()
  local cmd_line = vim.fn.getcmdline()
  local winnr = api.nvim_get_current_win()
  if cmd_line == '' or not cmd_line or not cmd_line:find('^%d+$') then
     -- Cmd line is empty
     unpeek(winnr)
  else
     -- Cmd line contains only one or more numbers
     peek(winnr, tonumber(cmd_line))
  end
end

function numb.on_cmdline_exit() unpeek(api.nvim_get_current_win()) end

function numb.setup(user_opts)
   if user_opts then opts = vim.tbl_extend('force', opts, user_opts) end
   vim.api.nvim_exec([[
    augroup numb
        autocmd!
        autocmd CmdlineChanged : lua require('numb').on_cmdline_changed()
        autocmd CmdlineLeave : lua require('numb').on_cmdline_exit()
    augroup END
   ]], true)
end

return numb
