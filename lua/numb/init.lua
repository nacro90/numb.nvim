---@mod numb Core peek logic for :{number} and relative Ex commands.
local numb = {}

local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local address = require "numb.address"

-------------------------------------------------------------------------------
-- Type Definitions
-------------------------------------------------------------------------------

---@class NumbWinState
---@field bufnr integer Buffer the peek was started on, and so the buffer any
---range highlight belongs to
---@field cursor integer[] Saved cursor position [line, col]
---@field options table<string, boolean> Saved window options
---@field topline integer Saved topline for view restoration

---@class NumbConfig
---@field show_numbers boolean Enable 'number' for the window while peeking
---@field show_cursorline boolean Enable 'cursorline' for the window while peeking
---@field hide_relativenumbers boolean Disable 'relativenumber' for the window while peeking
---@field number_only boolean Peek only when command is purely numeric
---@field centered_peeking boolean Center peeked line in window
---@field range_peek boolean Highlight the whole line range for `:N,M{cmd}`

---@class NumbState
---@field win_states table<integer, NumbWinState> Per-window saved state
---@field peek_cursor integer[]|nil Target cursor position for confirmed jump.
---Deliberately global rather than per-window: at most one window peeks at a
---time, because `CmdlineLeave` always tears the current peek down before
---another one can start.
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
  range_peek = true,
}

---Drop unknown and wrongly typed options, warning once per offending key.
---`DEFAULT_OPTS` is the only specification: a key it does not carry is unknown,
---and the type of its default is the expected type.
---Never raises: a typo in the user's config must not break `setup()` and leave
---the plugin uninstalled, so every rejected value falls back to its default.
---@param user_opts any Anything the user passed to `setup()` or `enable()`
---@return table
local function sanitize_opts(user_opts)
  if user_opts == nil then
    return {}
  end

  if type(user_opts) ~= "table" then
    vim.notify(("[numb] setup() expects a table, got %s; using defaults"):format(type(user_opts)), vim.log.levels.WARN)
    return {}
  end

  local sanitized = {}
  for key, value in pairs(user_opts) do
    local default = DEFAULT_OPTS[key]
    if default == nil then
      vim.notify(("[numb] unknown option '%s' ignored"):format(tostring(key)), vim.log.levels.WARN)
    elseif type(value) ~= type(default) then
      vim.notify(
        ("[numb] option '%s' expects a %s, got %s; keeping the default"):format(key, type(default), type(value)),
        vim.log.levels.WARN
      )
    else
      sanitized[key] = value
    end
  end
  return sanitized
end

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

---Update configuration options. Any value is accepted; anything that is not a
---valid option is reported and ignored (see `sanitize_opts`).
---@param user_opts NumbConfig|any
function State:configure(user_opts)
  self.opts = vim.tbl_deep_extend("force", DEFAULT_OPTS, sanitize_opts(user_opts))
end

-- Module-level state instance (exposed for testing as numb._state)
local state = State.new()

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

---Window options that are saved and restored during peeking
---@type string[]
local TRACKED_WIN_OPTIONS = { "number", "cursorline", "foldenable", "relativenumber" }

---Namespace owning the range highlight, so it can be cleared wholesale without
---touching extmarks belonging to anything else.
local RANGE_NS = api.nvim_create_namespace "numb_range"

---Define the range highlight. `default = true` so a user or colorscheme
---definition of `NumbRange` wins; linking to `Visual` means the preview looks
---like a selection, which is what a pending range operation effectively is.
local function define_highlight()
  api.nvim_set_hl(0, "NumbRange", { link = "Visual", default = true })
end

-------------------------------------------------------------------------------
-- Internal Functions
--
-- View-affecting calls (`winsaveview`, `winrestview`, `normal! zz`) always act
-- on the *current* window, ignoring any window handle in scope. Every such call
-- below therefore goes through `api.nvim_win_call(winnr, ...)`, so that the
-- `winnr` these functions take is genuinely honored even when the target window
-- is not the current one.
--
-- The confirmed-jump branch of `unpeek` is the one exception: it makes the
-- target window current with `api.nvim_set_current_win` and switches back when
-- it is done, so the bare `normal!` commands there already act on the right
-- window. Read that switch as deliberate rather than as a missing
-- `api.nvim_win_call`.
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
    -- The buffer is remembered rather than looked up later, because the range
    -- highlight lives on this buffer and the window may be gone, or showing
    -- something else, by the time it has to be cleared.
    bufnr = api.nvim_win_get_buf(winnr),
    cursor = api.nvim_win_get_cursor(winnr),
    options = win_options,
    topline = api.nvim_win_call(winnr, fn.winsaveview).topline,
  }
end

---Apply window options
---@param winnr integer Window handle
---@param options table<string, boolean|nil> Options to set
local function set_win_options(winnr, options)
  for option, value in pairs(options) do
    if value ~= nil then
      api.nvim_set_option_value(option, value, { win = winnr, scope = "local" })
    end
  end
end

---Remove the range highlight from a buffer.
---Takes the buffer rather than the window, because the window a range was drawn
---from can be closed while the buffer, and the extmark on it, live on.
---@param bufnr integer Buffer handle
local function clear_range(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_clear_namespace(bufnr, RANGE_NS, 0, -1)
end

---Highlight an inclusive line range in the window's buffer.
---One extmark spans the whole range rather than one per line, so the cost does
---not grow with the size of the range; `:1,10000d` is as cheap as `:1,2d`.
---@param winnr integer Window handle
---@param first integer One end of the range
---@param last integer The other end; the two are ordered here, so `:10,5` works
local function highlight_range(winnr, first, last)
  local bufnr = api.nvim_win_get_buf(winnr)
  local low = clamp_linenr(bufnr, math.min(first, last))
  local high = clamp_linenr(bufnr, math.max(first, last))
  local last_text = api.nvim_buf_get_lines(bufnr, high - 1, high, false)[1] or ""

  api.nvim_buf_clear_namespace(bufnr, RANGE_NS, 0, -1)
  api.nvim_buf_set_extmark(bufnr, RANGE_NS, low - 1, 0, {
    end_row = high - 1,
    end_col = #last_text,
    hl_group = "NumbRange",
    -- Without this the last line stops at its final character, which reads as a
    -- ragged edge rather than a block of selected lines.
    hl_eol = true,
  })
end

---Peek at a line in the window
---@param winnr integer Window handle
---@param linenr integer Target line number
local function peek(winnr, linenr)
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
    api.nvim_win_call(winnr, function()
      cmd "normal! zz"
    end)
  end

  -- Expose a window-scoped flag so statusline integrations can render a
  -- "currently peeking" indicator. Window-scoped (not buffer-scoped) so the
  -- flag does not leak across split windows sharing the same buffer.
  if api.nvim_win_is_valid(winnr) then
    vim.w[winnr].numb_peeking = true
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

  -- The window can be gone before restoration runs, for example a peeked split
  -- that was closed, or `disable()` called afterwards. Every window API call
  -- below would raise on a stale handle, so drop the saved state and stop. The
  -- range still has to go: it is on the buffer, which outlives the window.
  if not api.nvim_win_is_valid(winnr) then
    clear_range(orig_state.bufnr)
    state.win_states[winnr] = nil
    state.peek_cursor = nil
    return
  end

  clear_range(orig_state.bufnr)

  -- Restore original window options
  set_win_options(winnr, orig_state.options)

  -- Always restore cursor first; Vim handles final navigation on confirm
  api.nvim_win_set_cursor(winnr, orig_state.cursor)

  if stay then
    local final_cursor = state.peek_cursor
    local origin_cursor = orig_state.cursor
    state.peek_cursor = nil
    if final_cursor then
      vim.schedule(function()
        if not api.nvim_win_is_valid(winnr) then
          return
        end
        -- The confirmed Ex command has already run by now and may have deleted
        -- lines (`:38,40d`), so both saved line numbers are re-clamped against
        -- the buffer as it is now. Without this the calls below raise
        -- "Invalid cursor line: out of range" out of a scheduled callback.
        -- Only the line needs clamping; nvim_win_set_cursor clamps the column.
        local bufnr = api.nvim_win_get_buf(winnr)
        local origin = { clamp_linenr(bufnr, origin_cursor[1]), origin_cursor[2] }
        local target = { clamp_linenr(bufnr, final_cursor[1]), final_cursor[2] }
        local previous_win = api.nvim_get_current_win()
        api.nvim_set_current_win(winnr)
        -- Vim's native :N moves the cursor but does not push to the jumplist;
        -- force cursor back to origin then use G-motion so the origin is pushed
        -- to the jumplist (so <C-o> returns to it).
        api.nvim_win_set_cursor(winnr, origin)
        cmd(("normal! %dG"):format(target[1]))
        api.nvim_win_set_cursor(winnr, target)
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
    api.nvim_win_call(winnr, function()
      fn.winrestview { topline = orig_state.topline }
    end)
    state.peek_cursor = nil
  end
  state.win_states[winnr] = nil

  -- Clear the statusline indicator flag (set in peek()). Re-checked because
  -- restoring options above can fire autocommands that close the window.
  if api.nvim_win_is_valid(winnr) then
    vim.w[winnr].numb_peeking = nil
  end
end

---Check if window is currently peeking
---@param winnr integer Window handle
---@return boolean
local function has_saved_state(winnr)
  return state.win_states[winnr] ~= nil
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

---Handle command line changes during Ex command input
function numb.on_cmdline_changed()
  local winnr = api.nvim_get_current_win()

  -- While a peek is already running the cursor sits on the previewed line, so
  -- relative offsets have to count from the saved origin instead. Otherwise
  -- typing another digit would compound the offset.
  local win_state = state.win_states[winnr]
  local base_line = win_state and win_state.cursor[1] or api.nvim_win_get_cursor(winnr)[1]
  local last_line = api.nvim_buf_line_count(api.nvim_win_get_buf(winnr))

  local target = address.resolve(fn.getcmdline(), base_line, last_line, state.opts.number_only)

  if not target then
    if has_saved_state(winnr) then
      unpeek(winnr, false)
      cmd "redraw"
    end
    return
  end

  unpeek(winnr, false)
  -- `target.line` is the lower bound of a range, so the start of it is on
  -- screen. That is also where `:d` leaves the cursor, but only `:d`: `:y` does
  -- not move it at all, and `:m`, `:t` and `:s` finish near their destination.
  -- So this is a deliberate choice of what to show, not a prediction of where
  -- Vim will land.
  peek(winnr, target.line)
  if state.opts.range_peek and target.first then
    highlight_range(winnr, target.first, target.last)
  end
  cmd "redraw"
end

---Handle command line exit
function numb.on_cmdline_exit()
  -- Stay at the target when the command was confirmed. `CmdlineLeave` fires
  -- before the command runs, so `abort == false` only means Enter was pressed;
  -- the command itself may still fail.
  local event = api.nvim_get_vvar "event"
  local stay = not event.abort

  -- Every window with saved state is torn down, not just the current one. The
  -- window that was peeking can already be gone: closing it during a command
  -- line, which any plugin dismissing a float from a timer will do, gives no
  -- `WinClosed` at all, and focus has moved on by now. Keying off the current
  -- window would leave that peek's saved state and its range highlight behind
  -- for the rest of the session. At most one window peeks at a time, so this
  -- loop is one iteration in every ordinary case.
  for _, winnr in ipairs(vim.tbl_keys(state.win_states)) do
    unpeek(winnr, stay)
  end
end

-- Augroup handle is non-nil while the plugin is active.
---@type integer|nil
local augroup_id = nil

---Install (or reinstall) the CmdlineChanged/CmdlineLeave autocommands.
---`clear = true` on the augroup makes this idempotent across repeated calls
---(re-`setup()` or `disable` → `enable`).
local function install_autocmds()
  augroup_id = api.nvim_create_augroup("numb", { clear = true })
  api.nvim_create_autocmd("CmdlineChanged", {
    group = augroup_id,
    pattern = ":",
    callback = numb.on_cmdline_changed,
  })
  api.nvim_create_autocmd("CmdlineLeave", {
    group = augroup_id,
    pattern = ":",
    callback = numb.on_cmdline_exit,
  })
  api.nvim_create_autocmd("ColorScheme", {
    group = augroup_id,
    callback = define_highlight,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = augroup_id,
    callback = function(event)
      -- A window closed mid-peek can never be restored, and `unpeek` only ever
      -- runs for the current window on `CmdlineLeave`, so without this its saved
      -- state would sit in `win_states` for the rest of the session, and the
      -- range it drew would stay on the buffer for the rest of the session too.
      local winnr = tonumber(event.match)
      local win_state = winnr and state.win_states[winnr]
      if win_state then
        -- Cleared through the remembered buffer, not the window: by the time
        -- this runs during a command line the window can already be gone, and
        -- looking the buffer up through it would silently do nothing.
        clear_range(win_state.bufnr)
        state.win_states[winnr] = nil
      end
    end,
  })
end

---@class NumbSubcommand
---@field impl fun() Subcommand implementation

---Dispatch table for `:Numb` subcommands.
---@type table<string, NumbSubcommand>
local subcommand_tbl = {
  enable = {
    impl = function()
      numb.enable()
    end,
  },
  disable = {
    impl = function()
      numb.disable()
    end,
  },
  toggle = {
    impl = function()
      if numb.is_enabled() then
        numb.disable()
      else
        numb.enable()
      end
    end,
  },
}

---Install (or reinstall) the `:Numb` user command.
---`nvim_create_user_command` silently replaces an existing command with the
---same name, so this is safe to call repeatedly.
local function install_user_command()
  api.nvim_create_user_command("Numb", function(o)
    local key = o.fargs[1] or "toggle"
    local subcommand = subcommand_tbl[key]
    if not subcommand then
      vim.notify("[numb] unknown subcommand: " .. key, vim.log.levels.ERROR)
      return
    end
    subcommand.impl()
  end, {
    nargs = "?",
    desc = "Control numb.nvim (enable | disable | toggle)",
    complete = function(arg_lead)
      return vim.tbl_filter(function(key)
        return key:find(arg_lead, 1, true) == 1
      end, vim.tbl_keys(subcommand_tbl))
    end,
  })
end

---Returns the configuration currently in effect, defaults included.
---A copy, so mutating the result cannot reconfigure the plugin behind its back;
---`setup()` and `enable()` stay the only way to change options.
---@return NumbConfig
function numb.get_config()
  return vim.deepcopy(state.opts)
end

---Returns true when the plugin's autocommands are installed.
---Reflects only what this plugin did: if something else clears the `numb`
---augroup, for example an `augroup numb | autocmd!` block in a user config, the
---autocommands are gone but this still returns true. `:checkhealth numb` cross
---checks the augroup and reports that case; keeping the check out of here leaves
---this a cheap state read rather than a diagnostic.
---@return boolean
function numb.is_enabled()
  return augroup_id ~= nil
end

---Returns true when the given (or current) window is currently peeking.
---Reads the same `vim.w.numb_peeking` flag exposed to statusline integrations,
---so the two never diverge.
---@param winnr integer|nil Window handle. `nil` or `0` => current window.
---@return boolean
function numb.is_peeking(winnr)
  if winnr == nil or winnr == 0 then
    winnr = api.nvim_get_current_win()
  end
  if not api.nvim_win_is_valid(winnr) then
    return false
  end
  return vim.w[winnr].numb_peeking == true
end

---Enable the plugin (re-install autocommands using the current config).
---Safe to call when already enabled.
---@param user_opts NumbConfig|nil Optional config override
function numb.enable(user_opts)
  if user_opts then
    state:configure(user_opts)
  end
  if numb.is_enabled() then
    return
  end
  install_autocmds()
end

---Setup the plugin with optional configuration.
---Invalid options are reported through `vim.notify` and ignored rather than
---raising, so a typo cannot leave the plugin uninstalled.
---@param user_opts NumbConfig|any Configuration options
function numb.setup(user_opts)
  state:configure(user_opts)
  define_highlight()
  install_autocmds()
  install_user_command()
end

---Disable the plugin and clear state
function numb.disable()
  -- Restore still-peeking windows before their saved state is dropped, and never
  -- let a failed restore block the teardown below. `vim.tbl_keys` snapshots the
  -- keys because `unpeek` removes entries from the table being walked.
  for _, winnr in ipairs(vim.tbl_keys(state.win_states)) do
    pcall(unpeek, winnr, false)
  end
  state:reset()
  if augroup_id then
    pcall(api.nvim_del_augroup_by_id, augroup_id)
    augroup_id = nil
  end
end

-- Expose state for testing (underscore prefix = internal)
numb._state = state
numb._peek = peek
numb._unpeek = unpeek

return numb
