---@mod numb Core peek logic for :{number} and relative Ex commands.
local numb = {}

local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local log = require "numb.log"

-- Stores the target position we expect to land on after leaving the cmdline.
local peek_cursor = nil

---@class NumbWinState
---@field cursor integer[]
---@field options table<string, boolean>
---@field topline integer

---@type table<integer, NumbWinState>
local win_states = {}

local function clamp_linenr(bufnr, linenr)
  local max_line = api.nvim_buf_line_count(bufnr)
  return math.max(1, math.min(max_line, linenr))
end

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
    win_options[option] = api.nvim_get_option_value(option, { win = winnr, scope = "local" })
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
    if value ~= nil then
      api.nvim_set_option_value(option, value, { win = winnr, scope = "local" })
    end
  end
end

---@param winnr integer
---@param linenr integer
local function peek(winnr, linenr)
  log.trace(("peek(), winnr=%d, linenr=%d"):format(winnr, linenr))
  local bufnr = api.nvim_win_get_buf(winnr)
  linenr = clamp_linenr(bufnr, linenr)

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

  -- Always restore cursor to original position first
  -- Vim's native Ex command will handle the final navigation when stay=true
  api.nvim_win_set_cursor(winnr, orig_state.cursor)

  if stay then
    local final_cursor = peek_cursor
    peek_cursor = nil
    if final_cursor then
      vim.schedule(function()
        if not api.nvim_win_is_valid(winnr) then
          return
        end
        local previous_win = api.nvim_get_current_win()
        api.nvim_set_current_win(winnr)
        api.nvim_win_set_cursor(winnr, final_cursor)
        -- Unfold at the cursorline if user wants to stay
        cmd "normal! zv"
        if opts.centered_peeking then
          cmd "normal! zz"
        end
        if previous_win ~= winnr and api.nvim_win_is_valid(previous_win) then
          api.nvim_set_current_win(previous_win)
        end
      end)
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
---@param base_line integer|nil Base line for relative jumps
---@return integer|nil
local function parse_num_str(str, base_line)
  -- Validate input contains only expected characters (defense in depth)
  if not str:match "^[%+%-%d]+$" then
    log.warn("Invalid number expression: " .. str)
    return nil
  end

  -- Transform consecutive +/- into math expressions by inserting "1"
  -- E.g., "++" becomes "+1+", "--" becomes "-1-"
  str = str:gsub("([%+%-])([%+%-])", "%11%2")
  str = str:gsub("([%+%-])([%+%-])", "%11%2") -- second pass for "+++" patterns

  -- Handle trailing operator (e.g., ":+" means "+1")
  if str:find "[%+%-]$" then
    str = str .. 1
  end

  -- Handle leading operator (relative jump from current line)
  local base = 0
  if str:find "^[%+%-]" then
    base = base_line or api.nvim_win_get_cursor(0)[1]
  end

  -- Safe arithmetic parsing without load()
  local result = base
  local current_num = ""
  local sign = 1

  for i = 1, #str do
    local char = str:sub(i, i)
    if char == "+" then
      result = result + sign * (tonumber(current_num) or 0)
      current_num = ""
      sign = 1
    elseif char == "-" then
      result = result + sign * (tonumber(current_num) or 0)
      current_num = ""
      sign = -1
    else
      current_num = current_num .. char
    end
  end
  -- Add final number
  result = result + sign * (tonumber(current_num) or 0)

  return math.floor(result)
end

function numb.on_cmdline_changed()
  log.trace "on_cmdline_changed()"
  local cmd_line = fn.getcmdline()
  local winnr = api.nvim_get_current_win()
  local num_str = cmd_line:match("^([%+%-%d]+)" .. (opts.number_only and "$" or ""))
  if num_str then
    -- Use original cursor position from win_states if peeking, otherwise current
    local base_line = win_states[winnr] and win_states[winnr].cursor[1] or api.nvim_win_get_cursor(winnr)[1]
    local target_line = parse_num_str(num_str, base_line)
    if target_line then
      unpeek(winnr, false)
      peek(winnr, target_line)
      cmd "redraw"
    end
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
