---@mod numb Core peek logic for :{number} and relative Ex commands.
local numb = {}

local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local log = require "numb.log"

-- Stores the target position we expect to land on after leaving the cmdline.
local peek_cursor = nil

-- Stores windows original states
local win_states = {}

-- Options with default values
local opts = {
  show_numbers = true, -- Enable 'number' for the window while peeking
  show_cursorline = true, -- Enable 'cursorline' for the window while peeking
  hide_relativenumbers = true, -- Enable turning off 'relativenumber' for the window while peeking
  number_only = false, -- Peek only when the command is only a number instead of when it starts with a number
  centered_peeking = true, -- Peeked line will be centered relative to window
}

-- Window options that are manipulated and saved while peeking
local tracked_win_options = { "number", "cursorline", "foldenable", "relativenumber" }

---@param states table Stores the captured per-window state
---@param winnr integer Window handle whose state will be saved
local function save_win_state(states, winnr)
  local win_options = {}
  for _, option in ipairs(tracked_win_options) do
    win_options[option] = api.nvim_win_get_option(winnr, option)
  end
  states[winnr] = {
    cursor = api.nvim_win_get_cursor(winnr),
    options = win_options,
    topline = fn.winsaveview().topline,
  }
end

---@param winnr integer
---@param options table
local function set_win_options(winnr, options)
  log.info("set_win_options(): winnr=", winnr, ", options=", options)
  for option, value in pairs(options) do
    api.nvim_win_set_option(winnr, option, value)
  end
end

---@param winnr integer
---@param linenr integer
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
  peek_cursor = { linenr, original_column }
  api.nvim_win_set_cursor(winnr, peek_cursor)

  if opts.centered_peeking then
    cmd "normal! zz"
  end
end

---@param winnr integer
---@param stay boolean
local function unpeek(winnr, stay)
  local orig_state = win_states[winnr]

  if not orig_state then
    return
  end

  -- Restoring original window options
  set_win_options(winnr, orig_state.options)
  api.nvim_win_set_cursor(winnr, orig_state.cursor)

  if stay then
    if peek_cursor ~= nil then
      api.nvim_win_set_cursor(winnr, peek_cursor)
      peek_cursor = nil
    end
    -- Unfold at the cursorline if user wants to stay
    cmd "normal! zv"
    if opts.centered_peeking then
      cmd "normal! zz"
    end
  else
    fn.winrestview { topline = orig_state.topline }
  end
  win_states[winnr] = nil
end

local function is_peeking(winnr)
  return win_states[winnr] and true or false
end

---Parses an Ex command number expression (supports +/- math).
---@param str string
---@return integer
local function parse_num_str(str)
  str = str:gsub("([%+%-])([%+%-])", "%11%2") -- turn input into a mathematical equation by adding a 1 between a plus or minus
  str = str:gsub("([%+%-])([%+%-])", "%11%2") -- a sign that was matched as $2 was not yet matched as $1
  if str:find("[%+%-]$") then -- also catch last character
    str = str .. 1
  end
  if str:find("^[%+%-]") then
    local current_line, _ = unpack(api.nvim_win_get_cursor(0))
    str = current_line .. str
  end
  return load("return " .. str)()
end

function numb.on_cmdline_changed()
  log.trace "on_cmdline_changed()"
  local cmd_line = fn.getcmdline()
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
end

function numb.setup(user_opts)
  opts = vim.tbl_extend("force", opts, user_opts or {})
  local group = api.nvim_create_augroup("numb", { clear = true })
  api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    pattern = ":",
    callback = numb.on_cmdline_changed,
  })
  api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    pattern = ":",
    callback = numb.on_cmdline_exit,
  })
end

function numb.disable()
  win_states = {}
  pcall(api.nvim_del_augroup_by_name, "numb")
end

return numb
