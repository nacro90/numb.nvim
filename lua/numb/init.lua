---@mod numb Core peek logic for :{number} and relative Ex commands.
---
--- The whole plugin is three steps: `CmdlineChanged` asks `numb.address` what the
--- command line points at, `peek()` previews it while saving what it changed, and
--- `CmdlineLeave` restores that state, staying at the target when the command was
--- confirmed.
---
--- Every keystroke redoes that in full: `on_cmdline_changed` restores the window
--- first and peeks again from scratch, so `win_states` holds at most one entry
--- per window and never accumulates across a command line. That is why the
--- options and view a peek saves are always the ones from before the peek, not
--- the ones a previous keystroke left behind.
local numb = {}

local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local address = require "numb.address"
local config = require "numb.config"

---@class NumbWinState
---@field bufnr integer Buffer the peek was started on, and so the buffer any
---range highlight belongs to
---@field cursor integer[] Saved cursor position [line, col]
---@field options table<string, boolean> Saved window options
---@field topline integer Saved topline for view restoration

---@class NumbState
---@field win_states table<integer, NumbWinState> Per-window saved state
---@field peek_cursor integer[]|nil Target cursor position for confirmed jump.
---Deliberately global rather than per-window: at most one window peeks at a
---time, because `CmdlineLeave` always tears the current peek down before
---another one can start.
---@field opts NumbConfig Configuration options

-- One instance is all there can ever be, which is why this is a plain table and
-- not a class with a constructor. Exposed for testing as `numb._state`.
---@type NumbState
local state = {
  win_states = {},
  peek_cursor = nil,
  opts = config.resolve(nil),
}

---Window options saved and restored around a peek.
---`number`, `cursorline` and `relativenumber` are each behind an option, because
---whether they help is a matter of taste. `foldenable` is not: it is always
---turned off while peeking, since a line inside a closed fold is not on screen at
---all, so previewing it would scroll the window and show the fold instead of the
---line that was asked for.
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
-- Window state
--
-- View-affecting calls (`winsaveview`, `winrestview`, `normal! zz`) always act
-- on the *current* window, ignoring any window handle in scope, so every such
-- call below goes through `api.nvim_win_call(winnr, ...)`. The one exception is
-- `schedule_jump`, which makes the target window current on purpose and switches
-- back afterwards; read that as deliberate rather than as a missing
-- `nvim_win_call`.
-------------------------------------------------------------------------------

---Clamp a line number to the buffer.
---@param bufnr integer Buffer handle
---@param linenr integer Line number to clamp
---@return integer
local function clamp_linenr(bufnr, linenr)
  return math.max(1, math.min(api.nvim_buf_line_count(bufnr), linenr))
end

---Save window state for later restoration.
---@param winnr integer Window handle
---@return NumbWinState The state just saved, so the caller does not have to read
---it back out of `win_states` across calls that can fire autocommands
local function save_win_state(winnr)
  local options = {}
  for _, option in ipairs(TRACKED_WIN_OPTIONS) do
    options[option] = api.nvim_get_option_value(option, { win = winnr, scope = "local" })
  end
  state.win_states[winnr] = {
    -- The buffer is remembered rather than looked up later, because the range
    -- highlight lives on this buffer and the window may be gone, or showing
    -- something else, by the time it has to be cleared.
    bufnr = api.nvim_win_get_buf(winnr),
    cursor = api.nvim_win_get_cursor(winnr),
    options = options,
    topline = api.nvim_win_call(winnr, fn.winsaveview).topline,
  }
  return state.win_states[winnr]
end

---@param winnr integer Window handle
---@param options table<string, boolean> Options to set
local function set_win_options(winnr, options)
  for option, value in pairs(options) do
    api.nvim_set_option_value(option, value, { win = winnr, scope = "local" })
  end
end

---Remove the range highlight from a buffer.
---Takes the buffer rather than the window, because the window a range was drawn
---from can be closed while the buffer, and the extmark on it, live on.
---@param bufnr integer Buffer handle
local function clear_range(bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, RANGE_NS, 0, -1)
  end
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

  clear_range(bufnr)
  api.nvim_buf_set_extmark(bufnr, RANGE_NS, low - 1, 0, {
    end_row = high - 1,
    end_col = #last_text,
    hl_group = "NumbRange",
    -- Without this the last line stops at its final character, which reads as a
    -- ragged edge rather than a block of selected lines.
    hl_eol = true,
  })
end

-------------------------------------------------------------------------------
-- Peeking
-------------------------------------------------------------------------------

---Preview a line in a window, saving whatever the preview changes.
---@param winnr integer Window handle
---@param linenr integer Target line number
local function peek(winnr, linenr)
  local bufnr = api.nvim_win_get_buf(winnr)
  linenr = clamp_linenr(bufnr, linenr)

  -- Held in a local because `set_win_options` below fires `OptionSet`, so reading
  -- it back out of `win_states` afterwards would be reading through state a user
  -- autocommand could have changed. Through a command line the entry is always
  -- absent, because `on_cmdline_changed` unpeeks first; an existing one is
  -- reused for the sake of a direct `numb._peek` call, which the tests make.
  local win_state = state.win_states[winnr] or save_win_state(winnr)

  local peeking_options = { foldenable = false }
  if state.opts.show_numbers then
    peeking_options.number = true
  end
  if state.opts.show_cursorline then
    peeking_options.cursorline = true
  end
  if state.opts.hide_relativenumbers then
    peeking_options.relativenumber = false
  end
  set_win_options(winnr, peeking_options)

  -- The column comes from the saved cursor, so the preview moves down the buffer
  -- without drifting sideways.
  state.peek_cursor = { linenr, win_state.cursor[2] }
  api.nvim_win_set_cursor(winnr, state.peek_cursor)

  if state.opts.centered_peeking then
    api.nvim_win_call(winnr, function()
      cmd "normal! zz"
    end)
  end

  -- Window-scoped (not buffer-scoped) so the flag statusline integrations read
  -- does not leak across splits sharing the same buffer.
  if api.nvim_win_is_valid(winnr) then
    vim.w[winnr].numb_peeking = true
  end
end

---Land on the confirmed target once the Ex command has finished running.
---Scheduled, because `CmdlineLeave` fires before the command does.
---@param winnr integer Window handle
---@param origin_cursor integer[] Where the peek started
---@param target_cursor integer[] Where the peek was pointing
local function schedule_jump(winnr, origin_cursor, target_cursor)
  vim.schedule(function()
    if not api.nvim_win_is_valid(winnr) then
      return
    end

    -- The command may have deleted lines under the target (`:38,40d`), so both
    -- saved line numbers are re-clamped against the buffer as it is now. Without
    -- this the calls below raise "Invalid cursor line: out of range" out of a
    -- scheduled callback. Only the line needs it; `nvim_win_set_cursor` clamps
    -- the column itself.
    local bufnr = api.nvim_win_get_buf(winnr)
    local origin = { clamp_linenr(bufnr, origin_cursor[1]), origin_cursor[2] }
    local target = { clamp_linenr(bufnr, target_cursor[1]), target_cursor[2] }

    local previous_win = api.nvim_get_current_win()
    api.nvim_set_current_win(winnr)
    -- Vim's own `:N` moves the cursor without touching the jumplist. Going back
    -- to the origin and moving with `G` pushes it, so `<C-o>` returns there.
    api.nvim_win_set_cursor(winnr, origin)
    cmd(("normal! %dG"):format(target[1]))
    api.nvim_win_set_cursor(winnr, target)
    cmd "normal! zv" -- open any fold the target sits in
    if state.opts.centered_peeking then
      cmd "normal! zz"
    end
    if previous_win ~= winnr and api.nvim_win_is_valid(previous_win) then
      api.nvim_set_current_win(previous_win)
    end
  end)
end

---Restore a window that was peeked.
---@param winnr integer Window handle
---@param stay boolean Keep the previewed position instead of going back
local function unpeek(winnr, stay)
  local win_state = state.win_states[winnr]
  if not win_state then
    return
  end
  -- Dropped up front so a restore that fires autocommands cannot re-enter this
  -- for the same window.
  state.win_states[winnr] = nil

  -- The range is on the buffer, which outlives the window, so it goes either way.
  clear_range(win_state.bufnr)

  -- The window can be gone before restoration runs, for example a peeked split
  -- that was closed, or `disable()` called afterwards. Every window API call
  -- below would raise on a stale handle.
  if not api.nvim_win_is_valid(winnr) then
    state.peek_cursor = nil
    return
  end

  set_win_options(winnr, win_state.options)

  -- The cursor goes back to where the peek started on both paths. On an abort
  -- that is the whole job. On a confirm it is what makes the jump come *from* the
  -- origin, so the jumplist entry `schedule_jump` pushes records the line the
  -- user was actually on.
  api.nvim_win_set_cursor(winnr, win_state.cursor)

  local target_cursor = state.peek_cursor
  state.peek_cursor = nil
  if stay then
    if target_cursor then
      schedule_jump(winnr, win_state.cursor, target_cursor)
    end
  else
    api.nvim_win_call(winnr, function()
      fn.winrestview { topline = win_state.topline }
    end)
  end

  -- Clears the flag `peek` set. Re-checked because restoring options above can
  -- fire autocommands that close the window.
  if api.nvim_win_is_valid(winnr) then
    vim.w[winnr].numb_peeking = nil
  end
end

---Whether peeking is switched off for what this window is showing.
---@param winnr integer Window handle
---@return boolean
local function is_disabled_for(winnr)
  local by_buftype = state.opts.disable_for_buftype
  local by_filetype = state.opts.disable_for_filetype

  -- The default is two empty lists, so reading two buffer options on every
  -- keystroke would be pure cost with nothing to compare them against.
  if #by_buftype == 0 and #by_filetype == 0 then
    return false
  end

  local bufnr = api.nvim_win_get_buf(winnr)
  -- 'buftype' first: it is a short fixed set, and the buffers people want left
  -- alone are usually identified by it.
  if vim.tbl_contains(by_buftype, api.nvim_get_option_value("buftype", { buf = bufnr })) then
    return true
  end
  return vim.tbl_contains(by_filetype, api.nvim_get_option_value("filetype", { buf = bufnr }))
end

-------------------------------------------------------------------------------
-- Autocommands
-------------------------------------------------------------------------------

---Preview whatever the command line now points at.
local function on_cmdline_changed()
  local winnr = api.nvim_get_current_win()

  -- Nothing was peeked in an excluded buffer, so there is nothing to tear down
  -- either and the teardown on `CmdlineLeave`, which walks the saved state, has
  -- no entry to find.
  if is_disabled_for(winnr) then
    return
  end

  -- While a peek is already running the cursor sits on the previewed line, so
  -- relative offsets have to count from the saved origin instead. Otherwise
  -- typing another digit would compound the offset.
  local win_state = state.win_states[winnr]
  local base_line = win_state and win_state.cursor[1] or api.nvim_win_get_cursor(winnr)[1]
  local last_line = api.nvim_buf_line_count(api.nvim_win_get_buf(winnr))

  local target = address.resolve(fn.getcmdline(), base_line, last_line, state.opts.number_only)
  if not target then
    if win_state then
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

---Tear every peek down, staying at the target when the command was confirmed.
local function on_cmdline_exit()
  -- `CmdlineLeave` fires before the command runs, so `abort == false` only means
  -- Enter was pressed; the command itself may still fail, and the jump is applied
  -- anyway. `:-100` from line 5 is the clearest case: Vim rejects the range with
  -- E16 and leaves the cursor at 5, while numb lands on line 1. That follows from
  -- clamping the target, which is also what makes `:9999` land on the last line
  -- instead of erroring, so it is a consequence of a documented choice rather
  -- than a separate bug.
  local stay = not api.nvim_get_vvar("event").abort

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

---Reclaim the state of a window that was closed mid-peek.
---Belt and braces rather than the main path: `on_cmdline_exit` walks every saved
---window and `unpeek` handles a stale handle itself, and a window closed while
---the command line is open emits no `WinClosed` at all. What this does add is
---timing: when a peeked window is closed with no command line in flight, which
---is what a direct `numb._peek` call amounts to, the range stops being drawn at
---that moment instead of waiting for a `CmdlineLeave` that may never come.
---@param event table Autocommand callback argument
local function on_win_closed(event)
  local winnr = tonumber(event.match)
  local win_state = winnr and state.win_states[winnr]
  if win_state then
    -- Cleared through the remembered buffer, not the window: by the time this
    -- runs during a command line the window can already be gone, and looking the
    -- buffer up through it would silently do nothing.
    clear_range(win_state.bufnr)
    state.win_states[winnr] = nil
  end
end

-- Non-nil while the plugin is active, which is what `is_enabled()` reports.
---@type integer|nil
local augroup_id = nil

---Install (or reinstall) the autocommands.
---`clear = true` on the augroup makes this idempotent across repeated calls
---(re-`setup()`, or `disable` then `enable`).
local function install_autocmds()
  augroup_id = api.nvim_create_augroup("numb", { clear = true })

  -- Defined here rather than only in `setup()`, so peeking is never installed
  -- without the group the range preview draws with. A config that sets
  -- `g:loaded_numb` and then calls `enable()` skips `setup()` entirely, and used
  -- to end up with a working peek and an invisible range.
  define_highlight()

  api.nvim_create_autocmd("CmdlineChanged", { group = augroup_id, pattern = ":", callback = on_cmdline_changed })
  api.nvim_create_autocmd("CmdlineLeave", { group = augroup_id, pattern = ":", callback = on_cmdline_exit })
  api.nvim_create_autocmd("ColorScheme", { group = augroup_id, callback = define_highlight })
  api.nvim_create_autocmd("WinClosed", { group = augroup_id, callback = on_win_closed })
end

---What `:Numb {action}` does, and the set tab completion offers.
---@type table<string, fun()>
local ACTIONS = {
  enable = function()
    numb.enable()
  end,
  disable = function()
    numb.disable()
  end,
  toggle = function()
    if numb.is_enabled() then
      numb.disable()
    else
      numb.enable()
    end
  end,
}

---Install (or reinstall) the `:Numb` user command.
---`nvim_create_user_command` silently replaces an existing command with the same
---name, so this is safe to call repeatedly.
local function install_user_command()
  api.nvim_create_user_command("Numb", function(o)
    local name = o.fargs[1] or "toggle"
    local action = ACTIONS[name]
    if not action then
      vim.notify("[numb] unknown subcommand: " .. name, vim.log.levels.ERROR)
      return
    end
    action()
  end, {
    nargs = "?",
    desc = "Control numb.nvim (enable | disable | toggle)",
    complete = function(arg_lead)
      local names = vim.tbl_filter(function(name)
        return name:find(arg_lead, 1, true) == 1
      end, vim.tbl_keys(ACTIONS))
      table.sort(names)
      return names
    end,
  })
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

---Setup the plugin with optional configuration.
---Invalid options are reported through `vim.notify` and ignored rather than
---raising, so a typo cannot leave the plugin uninstalled.
---@param user_opts NumbConfig|any Configuration options
function numb.setup(user_opts)
  state.opts = config.resolve(user_opts)
  install_autocmds()
  install_user_command()
end

---Enable the plugin, reinstalling the autocommands with the current config.
---Safe to call when already enabled.
---@param user_opts NumbConfig|nil Optional config override
function numb.enable(user_opts)
  if user_opts then
    state.opts = config.resolve(user_opts)
  end
  if not numb.is_enabled() then
    install_autocmds()
  end
end

---Disable the plugin and drop every peek, keeping the configuration.
function numb.disable()
  -- Restore still-peeking windows before their saved state is dropped, and never
  -- let a failed restore block the teardown below. `vim.tbl_keys` snapshots the
  -- keys because `unpeek` removes entries from the table being walked.
  for _, winnr in ipairs(vim.tbl_keys(state.win_states)) do
    pcall(unpeek, winnr, false)
  end
  state.win_states = {}
  state.peek_cursor = nil

  if augroup_id then
    pcall(api.nvim_del_augroup_by_id, augroup_id)
    augroup_id = nil
  end
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

-- Internals the test suite drives directly; not part of the public API.
numb._state = state
numb._peek = peek
numb._unpeek = unpeek

return numb
