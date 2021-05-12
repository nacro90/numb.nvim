local numb = {}

local api = vim.api

local log = require('numb.log')

-- Stores windows original states
local win_states = {}
local opts = {show_numbers = true, show_cursorline = true}

local function peek(winnr, linenr)
   local bufnr = api.nvim_win_get_buf(winnr)
   local n_buf_lines = api.nvim_buf_line_count(bufnr)
   linenr = math.min(linenr, n_buf_lines)
   linenr = math.max(linenr, 1)
   if not win_states[winnr] then
      win_states[winnr] = {
         cursor = api.nvim_win_get_cursor(winnr),
         options = {
            number = api.nvim_win_get_option(winnr, 'number'),
            cursorline = api.nvim_win_get_option(winnr, 'cursorline'),
            foldenable = api.nvim_win_get_option(winnr, 'foldenable'),
         },
      }
   end

   if opts.show_numbers then api.nvim_win_set_option(winnr, 'number', true) end
   if opts.show_cursorline then
      api.nvim_win_set_option(winnr, 'cursorline', true)
   end
   api.nvim_win_set_option(winnr, 'foldenable', false)

   local original_column = win_states[winnr].cursor[2]
   local peek_cursor = {linenr, original_column}
   api.nvim_win_set_cursor(winnr, peek_cursor)
end

local function unpeek(winnr, stay)
   local orig_state = win_states[winnr]

   if not orig_state then return end

   if opts.show_numbers then
      api.nvim_win_set_option(winnr, 'number', orig_state.options.number)
   end
   if opts.show_cursorline then
      api.nvim_win_set_option(winnr, 'cursorline', orig_state.options.cursorline)
   end

   api.nvim_win_set_option(winnr, 'foldenable', orig_state.options.foldenable)

   if stay then
      -- Unfold at the cursorline if user wants to stay
      vim.cmd('normal! zv')
   else
      -- Rollback the cursor if the user does not want to stay
      api.nvim_win_set_cursor(winnr, orig_state.cursor)
   end
   win_states[winnr] = nil
end

function numb.on_cmdline_changed()
   local cmd_line = vim.fn.getcmdline()
   local winnr = api.nvim_get_current_win()
   local num_str = cmd_line:match('^%d+')
   if num_str then
      peek(winnr, tonumber(num_str))
      vim.cmd('redraw')
   else
      unpeek(winnr, false)
      vim.cmd('redraw')
   end
end

function numb.on_cmdline_exit()
   log.trace('on_cmdline_exit()')
   local winnr = api.nvim_get_current_win()
   -- Stay if the user does not abort the cmdline
   local stay = not vim.v.event.abort
   unpeek(winnr, stay)
end

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

function numb.disable()
   win_states = {}
   vim.api.nvim_exec([[
      augroup numb
          autocmd!
      augroup END
      augroup! numb
   ]], true)
end

return numb
