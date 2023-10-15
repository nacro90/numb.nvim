local numb = {}

local api = vim.api
local cmd = api.nvim_command

local log = require "numb.log"

-- Stores windows original states
local win_states = {}

-- Options with default values
local opts = {
  show_numbers = true, -- Enable 'number' for the window while peeking
  show_cursorline = true, -- Enable 'cursorline' for the window while peeking
  hide_relativenumbers = true, -- Enable turning off 'relativenumber' for the window while peeking
  number_only = false, -- Peek only when the command is only a number instead of when it starts with a number
  centered_peeking = true, -- Peeked line will be centered relative to window
  skip_cmdline_history = false, -- Cmds will not be stored in the cmdline-history
}

-- Window options that are manipulated and saved while peeking
local tracked_win_options = { "number", "cursorline", "foldenable", "relativenumber" }

--- Saves values of tracked window options of a window to given table
local function save_win_state(states, winnr)
  local win_options = {}
  for _, option in ipairs(tracked_win_options) do
    win_options[option] = api.nvim_win_get_option(winnr, option)
  end
  states[winnr] = {
    cursor = api.nvim_win_get_cursor(winnr),
    options = win_options,
    topline = vim.fn.winsaveview().topline,
  }
end

local function set_win_options(winnr, options)
  log.info("set_win_options(): winnr=", winnr, ", options=", options)
  for option, value in pairs(options) do
    api.nvim_win_set_option(winnr, option, value)
  end
end

local function peek(winnr, linenr)
  log.trace(("peek(), winnr=%d, linenr=%d"):format(winnr, linenr))
  local bufnr = api.nvim_win_get_buf(winnr)
  local n_buf_lines = api.nvim_buf_line_count(bufnr)
  linenr = math.min(linenr, n_buf_lines)
  linenr = math.max(linenr, 1)

  -- Saving window state if this is a first call of peek()
  if not win_states[winnr] then
    save_win_state(win_states, winnr)
  end

  -- Set window options for peeking
  local peeking_options = {
    foldenable = false,
    number = opts.show_numbers and true or nil,
    cursorline = opts.show_cursorline and true or nil,
  }
  if opts.hide_relativenumbers then
    peeking_options.relativenumber = false
  end

  set_win_options(winnr, peeking_options)

  -- Setting the cursor
  local original_column = win_states[winnr].cursor[2]
  local peek_cursor = { linenr, original_column }
  api.nvim_win_set_cursor(winnr, peek_cursor)

  if opts.centered_peeking then
    cmd "normal! zz"
  end
end

local function unpeek(winnr, stay)
  local orig_state = win_states[winnr]

  if not orig_state then
    return
  end

  -- Restoring original window options
  set_win_options(winnr, orig_state.options)
  api.nvim_win_set_cursor(winnr, orig_state.cursor)

  if stay then
    -- Unfold at the cursorline if user wants to stay
    cmd "normal! zv"
  else
    vim.fn.winrestview { topline = orig_state.topline }
  end
  win_states[winnr] = nil
end

local function is_peeking(winnr)
  return win_states[winnr] and true or false
end

local function parse_num_str(str)
  str = str:gsub("([%+%-])([%+%-])", "%11%2") -- turn input into a mathematical equation by adding a 1 between a plus or minus
  str = str:gsub("([%+%-])([%+%-])", "%11%2") -- a sign that was matched as $2 was not yet matched as $1
  if str:find("[%+%-]$") then -- also catch last character
    str = str .. 1
  end
  if str:find("^[%+%-]") then
    local current_line, _ = unpack(vim.api.nvim_win_get_cursor(0))
    str = current_line .. str
  end
  return load("return " .. str)()
end

function numb.on_cmdline_changed()
  log.trace "on_cmdline_changed()"
  local cmd_line = api.nvim_call_function("getcmdline", {})
  local winnr = api.nvim_get_current_win()
  local num_str = cmd_line:match("^([%+%-%d]+)" .. (opts.number_only and "$" or ""))
  if num_str then
    unpeek(winnr, false)
    peek(winnr, parse_num_str(num_str))
    cmd "redraw"
  elseif is_peeking(winnr) then
    unpeek(winnr, false)
    cmd "redraw"
  end
end

function numb.on_cmdline_exit()
  log.trace "on_cmdline_exit()"
  local winnr = api.nvim_get_current_win()
  if not is_peeking(winnr) then
    log.debug(winnr .. " is not at peek state, returning")
    return
  end
  -- Stay if the user does not abort the cmdline
  local event = api.nvim_get_vvar "event"
  local stay = not event.abort
  unpeek(winnr, stay)

  if opts.skip_cmdline_history then
    -- needs delay to ensure the item is already in the history
    vim.defer_fn(function()
      vim.fn.histdel(":", -1)
    end, 1)
  end
end

function numb.setup(user_opts)
  opts = vim.tbl_extend("force", opts, user_opts or {})
  cmd [[ augroup numb ]]
  cmd [[    autocmd! ]]
  cmd [[    autocmd CmdlineChanged : lua require('numb').on_cmdline_changed() ]]
  cmd [[    autocmd CmdlineLeave : lua require('numb').on_cmdline_exit() ]]
  cmd [[ augroup END ]]
end

function numb.disable()
  win_states = {}
  cmd [[ augroup numb ]]
  cmd [[    autocmd! ]]
  cmd [[ augroup END ]]
  cmd [[ augroup! numb ]]
end

return numb
