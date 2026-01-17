---@mod numb Core peek logic for :{number} and relative Ex commands.
local numb = {}

local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local log = require "numb.log"

-------------------------------------------------------------------------------
-- Type Definitions
-------------------------------------------------------------------------------

---@class NumbWinState
---@field cursor integer[] Saved cursor position [line, col]
---@field options table<string, boolean> Saved window options
---@field topline integer Saved topline for view restoration

---@class NumbConfig
---@field show_numbers boolean Enable 'number' for the window while peeking
---@field show_cursorline boolean Enable 'cursorline' for the window while peeking
---@field hide_relativenumbers boolean Disable 'relativenumber' for the window while peeking
---@field number_only boolean Peek only when command is purely numeric
---@field centered_peeking boolean Center peeked line in window

---@class NumbState
---@field win_states table<integer, NumbWinState> Per-window saved state
---@field peek_cursor integer[]|nil Target cursor position for confirmed jump
---@field opts NumbConfig Configuration options
local State = {}
State.__index = State

---Default configuration values
---@type NumbConfig
local DEFAULT_OPTS = {
  show_numbers = true,
  show_cursorline = true,
  hide_relativenumbers = true,
  number_only = false,
  centered_peeking = true,
}

---Create a new state instance
---@return NumbState
function State.new()
  local self = setmetatable({}, State)
  self.win_states = {}
  self.peek_cursor = nil
  self.opts = vim.tbl_deep_extend("force", {}, DEFAULT_OPTS)
  return self
end

---Reset mutable state (preserves opts)
function State:reset()
  self.win_states = {}
  self.peek_cursor = nil
end

---Update configuration options
---@param user_opts NumbConfig|nil
function State:configure(user_opts)
  self.opts = vim.tbl_deep_extend("force", DEFAULT_OPTS, user_opts or {})
end

-- Module-level state instance (exposed for testing as numb._state)
local state = State.new()

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

---Window options that are saved and restored during peeking
---@type string[]
local TRACKED_WIN_OPTIONS = { "number", "cursorline", "foldenable", "relativenumber" }

-------------------------------------------------------------------------------
-- Internal Functions
-------------------------------------------------------------------------------

---Clamp line number to valid buffer range
---@param bufnr integer Buffer handle
---@param linenr integer Line number to clamp
---@return integer
local function clamp_linenr(bufnr, linenr)
  local max_line = api.nvim_buf_line_count(bufnr)
  return math.max(1, math.min(max_line, linenr))
end

---Save window state for later restoration
---@param winnr integer Window handle
local function save_win_state(winnr)
  local win_options = {}
  for _, option in ipairs(TRACKED_WIN_OPTIONS) do
    win_options[option] = api.nvim_get_option_value(option, { win = winnr, scope = "local" })
  end
  state.win_states[winnr] = {
    cursor = api.nvim_win_get_cursor(winnr),
    options = win_options,
    topline = fn.winsaveview().topline,
  }
end

---Apply window options
---@param winnr integer Window handle
---@param options table<string, boolean|nil> Options to set
local function set_win_options(winnr, options)
  log.info("set_win_options(): winnr=", winnr, ", options=", options)
  for option, value in pairs(options) do
    if value ~= nil then
      api.nvim_set_option_value(option, value, { win = winnr, scope = "local" })
    end
  end
end

---Peek at a line in the window
---@param winnr integer Window handle
---@param linenr integer Target line number
local function peek(winnr, linenr)
  log.trace(("peek(), winnr=%d, linenr=%d"):format(winnr, linenr))
  local bufnr = api.nvim_win_get_buf(winnr)
  linenr = clamp_linenr(bufnr, linenr)

  -- Save window state on first peek
  if not state.win_states[winnr] then
    save_win_state(winnr)
  end

  -- Apply peeking options
  local peeking_options = {
    foldenable = false,
    number = state.opts.show_numbers and true or nil,
    cursorline = state.opts.show_cursorline and true or nil,
  }
  if state.opts.hide_relativenumbers then
    peeking_options.relativenumber = false
  end

  set_win_options(winnr, peeking_options)

  -- Move cursor to target line, preserving column
  local original_column = state.win_states[winnr].cursor[2]
  state.peek_cursor = { linenr, original_column }
  api.nvim_win_set_cursor(winnr, state.peek_cursor)

  if state.opts.centered_peeking then
    cmd "normal! zz"
  end
end

---Restore window state after peeking
---@param winnr integer Window handle
---@param stay boolean If true, keep the new cursor position
local function unpeek(winnr, stay)
  local orig_state = state.win_states[winnr]

  if not orig_state then
    return
  end

  -- Restore original window options
  set_win_options(winnr, orig_state.options)

  -- Always restore cursor first; Vim handles final navigation on confirm
  api.nvim_win_set_cursor(winnr, orig_state.cursor)

  if stay then
    local final_cursor = state.peek_cursor
    state.peek_cursor = nil
    if final_cursor then
      vim.schedule(function()
        if not api.nvim_win_is_valid(winnr) then
          return
        end
        local previous_win = api.nvim_get_current_win()
        api.nvim_set_current_win(winnr)
        api.nvim_win_set_cursor(winnr, final_cursor)
        -- Unfold at cursor position
        cmd "normal! zv"
        if state.opts.centered_peeking then
          cmd "normal! zz"
        end
        if previous_win ~= winnr and api.nvim_win_is_valid(previous_win) then
          api.nvim_set_current_win(previous_win)
        end
      end)
    end
  else
    fn.winrestview { topline = orig_state.topline }
    state.peek_cursor = nil
  end
  state.win_states[winnr] = nil
end

---Check if window is currently peeking
---@param winnr integer Window handle
---@return boolean
local function is_peeking(winnr)
  return state.win_states[winnr] ~= nil
end

---Parse an Ex command number expression with arithmetic support
---@param str string The expression string (e.g., "+5", "10-3", "++")
---@param base_line integer|nil Base line for relative expressions
---@return integer|nil Parsed line number or nil if invalid
local function parse_num_str(str, base_line)
  -- Validate input contains only expected characters
  if not str:match "^[%+%-%d]+$" then
    log.warn("Invalid number expression: " .. str)
    return nil
  end

  -- Transform consecutive operators into expressions (e.g., "++" -> "+1+")
  str = str:gsub("([%+%-])([%+%-])", "%11%2")
  str = str:gsub("([%+%-])([%+%-])", "%11%2") -- second pass for "+++"

  -- Handle trailing operator (":+" means "+1")
  if str:find "[%+%-]$" then
    str = str .. 1
  end

  -- Determine base for relative expressions
  local base = 0
  if str:find "^[%+%-]" then
    base = base_line or api.nvim_win_get_cursor(0)[1]
  end

  -- Safe arithmetic parsing
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
  result = result + sign * (tonumber(current_num) or 0)

  return math.floor(result)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

---Handle command line changes during Ex command input
function numb.on_cmdline_changed()
  log.trace "on_cmdline_changed()"
  local cmd_line = fn.getcmdline()
  local winnr = api.nvim_get_current_win()
  local pattern = "^([%+%-%d]+)" .. (state.opts.number_only and "$" or "")
  local num_str = cmd_line:match(pattern)

  if num_str then
    -- Use original cursor position if already peeking
    local win_state = state.win_states[winnr]
    local base_line = win_state and win_state.cursor[1] or api.nvim_win_get_cursor(winnr)[1]
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

---Handle command line exit
function numb.on_cmdline_exit()
  log.trace "on_cmdline_exit()"
  local winnr = api.nvim_get_current_win()
  if not is_peeking(winnr) then
    log.debug(winnr .. " is not in peek state, returning")
    return
  end
  -- Stay at target if command was confirmed (not aborted)
  local event = api.nvim_get_vvar "event"
  local stay = not event.abort
  unpeek(winnr, stay)
end

---Setup the plugin with optional configuration
---@param user_opts NumbConfig|nil Configuration options
function numb.setup(user_opts)
  state:configure(user_opts)
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

---Disable the plugin and clear state
function numb.disable()
  state:reset()
  pcall(api.nvim_del_augroup_by_name, "numb")
end

-- Expose state for testing (underscore prefix = internal)
numb._state = state

return numb
