---@mod numb.peek Previewing a line in a window, and putting the window back.
---
--- Internal: `numb` is the only caller. It owns the peek state (saved windows,
--- the live handle, the options in effect), the handle, and the window strategy,
--- which moves a window's cursor onto the target and saves whatever that changed
--- so it can be restored exactly. What only the command line needs, such as
--- deferred drawing, stays in `numb`.
local peek = {}

local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

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
---time, because opening a peek ends the one before it.
---@field opts NumbConfig Configuration options
---@field active NumbPeek|nil The live handle, whoever opened it

-- One instance is all there can ever be, which is why this is a plain table and
-- not a class with a constructor. Exposed for testing as `numb._state`.
---@type NumbState
local state = {
  win_states = {},
  peek_cursor = nil,
  opts = config.resolve(nil),
  active = nil,
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

-------------------------------------------------------------------------------
-- Window state
--
-- View-affecting calls (`winsaveview`, `winrestview`, `:normal`) always act
-- on the *current* window, ignoring any window handle in scope, so every such
-- call below goes through `api.nvim_win_call(winnr, ...)`. The one exception is
-- `jump`, which makes the target window current on purpose and switches back
-- afterwards; read that as deliberate rather than as a missing `nvim_win_call`.
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
---@return integer[] range The range drawn, as `{ low, high }` clamped to the buffer
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
  return { low, high }
end

---Scroll a window so its cursor line sits mid window, as `zz` does.
---Not `normal! zz`: a peek can run inside a mapping, and `:normal` resets the
---`v:count` that mapping reads (#36). With 'scrolloff' at 999 Vim's own layout
---code centers the line, wrapped lines included; only at the end of the buffer
---does the window stay full instead of scrolling past the last line.
---@param winnr integer Window handle
local function center_cursor(winnr)
  -- The local value, which is -1 when the window follows the global one, so
  -- writing it back restores that link rather than pinning today's number.
  local scrolloff = api.nvim_get_option_value("scrolloff", { win = winnr, scope = "local" })
  api.nvim_set_option_value("scrolloff", 999, { win = winnr, scope = "local" })
  -- Setting the cursor is what makes Vim recompute the view under the new
  -- 'scrolloff', but only once the view is marked stale: the peek has just moved
  -- the cursor, so the view is already valid for it and setting the same
  -- position again would change nothing. Restoring the current topline is what
  -- marks it stale, without scrolling anything itself.
  api.nvim_win_call(winnr, function()
    fn.winrestview { topline = fn.winsaveview().topline }
  end)
  api.nvim_win_set_cursor(winnr, api.nvim_win_get_cursor(winnr))
  api.nvim_set_option_value("scrolloff", scrolloff, { win = winnr, scope = "local" })
end

-------------------------------------------------------------------------------
-- Window strategy
-------------------------------------------------------------------------------

---Preview a line in a window, saving whatever the preview changes.
---@param winnr integer Window handle
---@param linenr integer Target line number
---@return integer linenr The line actually peeked, clamped to the buffer
local function window_peek(winnr, linenr)
  local bufnr = api.nvim_win_get_buf(winnr)
  linenr = clamp_linenr(bufnr, linenr)

  -- Held in a local because `set_win_options` below fires `OptionSet`, so reading
  -- it back out of `win_states` afterwards would be reading through state a user
  -- autocommand could have changed. Through the window strategy the entry is
  -- always absent, because its every retarget unpeeks first. The exception is a
  -- direct `numb._peek` call, which the tests make: the entry it left is reused.
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
    center_cursor(winnr)
  end

  if api.nvim_win_is_valid(winnr) then
    -- Recorded again because a `reset()` run by one of the autocommands above
    -- dropped it and put the window back, after which the rest of this peeked
    -- it anyway. Recorded, the window stays restorable, which is how the handle
    -- undoes a peek the plugin was disabled under.
    state.win_states[winnr] = win_state
    -- Window-scoped (not buffer-scoped) so the flag statusline integrations read
    -- does not leak across splits sharing the same buffer.
    vim.w[winnr].numb_peeking = true
  end
  return linenr
end

---Land on a confirmed target, recording the jump from where the peek started.
---@param winnr integer Window handle
---@param origin_cursor integer[] Where the peek started
---@param target_cursor integer[] Where the peek was pointing
local function jump(winnr, origin_cursor, target_cursor)
  if not api.nvim_win_is_valid(winnr) then
    return
  end

  -- Both saved line numbers are re-clamped against the buffer as it is now.
  -- When `accept()` calls this right away the buffer has not changed, but after
  -- the command line this runs scheduled, once the Ex command has, and that
  -- command may have deleted lines under the target (`:38,40d`). Without the
  -- clamp the calls below would raise "Invalid cursor line: out of range" out
  -- of the callback. Only the line needs it; `nvim_win_set_cursor` clamps the
  -- column itself.
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
  -- Centered the same way the preview was, so landing does not move the view
  -- the preview just showed.
  if state.opts.centered_peeking then
    center_cursor(winnr)
  end
  if previous_win ~= winnr and api.nvim_win_is_valid(previous_win) then
    api.nvim_set_current_win(previous_win)
  end
end

---Where to land once a confirmed peek is over, as a function that does it.
---Guarded for when it runs later than it was made: the window can be gone, or
---show another buffer, where the saved line numbers mean nothing (`:2b`).
---@param winnr integer Window handle
---@param bufnr integer Buffer the peek was on; both cursors are positions in it
---@param origin_cursor integer[] Where the peek started
---@param target_cursor integer[] Where the peek was pointing
---@return fun() land
local function landing(winnr, bufnr, origin_cursor, target_cursor)
  return function()
    if api.nvim_win_is_valid(winnr) and api.nvim_win_get_buf(winnr) == bufnr then
      jump(winnr, origin_cursor, target_cursor)
    end
  end
end

---Restore a window that was peeked.
---@param winnr integer Window handle
---@param stay boolean Keep the previewed position instead of going back
---@param deferred boolean When staying, hand the jump back instead of making
---it, for the caller to run once the pending Ex command has
---@return fun()|nil land The jump still to make, when staying and deferred
local function window_unpeek(winnr, stay, deferred)
  local win_state = state.win_states[winnr]
  if not win_state then
    return nil
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
    return nil
  end

  set_win_options(winnr, win_state.options)

  -- The window was switched to another buffer while peeking. The saved cursor,
  -- view and target are all positions in the old buffer, so none of them mean
  -- anything here: the options go back, and the window stays where the switch
  -- put it, whether the peek was accepted or not.
  if api.nvim_win_get_buf(winnr) ~= win_state.bufnr then
    state.peek_cursor = nil
    vim.w[winnr].numb_peeking = nil
    return nil
  end

  -- The cursor goes back to where the peek started on both paths. On an abort
  -- that is the whole job. On a confirm it is what makes the jump come *from* the
  -- origin, so the jumplist entry `jump` pushes records the line the user was
  -- actually on, and it is where a command line's relative addresses count from.
  api.nvim_win_set_cursor(winnr, win_state.cursor)

  local target_cursor = state.peek_cursor
  state.peek_cursor = nil
  local land = nil
  if stay then
    if target_cursor then
      land = landing(winnr, win_state.bufnr, win_state.cursor, target_cursor)
      if not deferred then
        land()
        land = nil
      end
    end
  else
    api.nvim_win_call(winnr, function()
      fn.winrestview { topline = win_state.topline }
    end)
  end

  -- Clears the flag `window_peek` set. Re-checked because restoring options
  -- above, or the jump, can fire autocommands that close the window.
  if api.nvim_win_is_valid(winnr) then
    vim.w[winnr].numb_peeking = nil
  end
  return land
end

---Restore a window no handle accounts for, as the command line leaves it: when
---staying, the jump is scheduled, because `CmdlineLeave` fires before the Ex
---command runs. The shape `numb._unpeek` has always had.
---@param winnr integer Window handle
---@param stay boolean Keep the previewed position instead of going back
local function unpeek_after_command(winnr, stay)
  local land = window_unpeek(winnr, stay, true)
  if land then
    vim.schedule(land)
  end
end

-------------------------------------------------------------------------------
-- Strategies
--
-- How a peek is drawn, kept apart from the handle so a second way of drawing
-- one can sit next to the window strategy without reshaping the handle. A
-- strategy is a table of these functions:
--
--   show(handle, line, range)     Start showing `line`, and `range` if given,
--                                 then record on the handle what is shown:
--                                 `handle.line` and `handle.range`, clamped.
--                                 Even when `reset()` ran in the middle of it,
--                                 through an autocommand, what it shows must
--                                 be one `hide` can still put back: the handle
--                                 undoes it that way.
--   move(handle, line, range)     Show another target on a handle already
--                                 showing one, with the same bookkeeping.
--   hide(handle, stay, deferred)  Stop showing it; when staying, land on the
--                                 target. When `deferred` as well, return the
--                                 landing as a function instead of running it,
--                                 for the handle to run once the pending Ex
--                                 command has.
--   alive(handle)                 Whether the peek can still be shown: false
--                                 once any window it needs has gone.
--   origin(winnr)                 The line a peek it shows in `winnr` started
--                                 from, or nil when it shows none there. Also
--                                 nil for a strategy that leaves the target
--                                 window's cursor alone: the command line then
--                                 counts from the real cursor, which is the
--                                 origin.
--   forget(winnr)                 Drop whatever it keeps for a window that
--                                 was closed, with nothing left to restore.
--                                 When `winnr` is a window the strategy
--                                 opened itself, `alive()` must be false
--                                 afterwards for the handle drawing in it:
--                                 `WinClosed` fires while the window is still
--                                 valid, so a validity check cannot see it go,
--                                 and `forget_window` relies on calling this
--                                 before it asks `alive()`. The target window
--                                 closing is matched by handle instead.
--   sweep(stay, live)             End every peek it still shows when the
--                                 command line closes, leaving the drawing of
--                                 `live`, a live handle, alone. When staying,
--                                 it schedules its own landings, since the Ex
--                                 command has not run yet, as
--                                 `unpeek_after_command` does for the window
--                                 strategy.
--   reset()                       Put back everything it changed and drop all
--                                 it keeps, never raising, for `disable()`.
--
-- Whatever the strategy, `handle.winnr` is the target window: the one whose
-- buffer is previewed and where accepting lands. Event data and `w:numb_peeking`,
-- and so `numb.is_peeking()`, always describe that window, never one a strategy
-- may add to draw in.
-------------------------------------------------------------------------------

---@class NumbStrategy
---@field show fun(handle: NumbPeek, line: integer, range: integer[]|nil)
---@field move fun(handle: NumbPeek, line: integer, range: integer[]|nil)
---@field hide fun(handle: NumbPeek, stay: boolean, deferred: boolean): fun()|nil
---@field alive fun(handle: NumbPeek): boolean
---@field origin fun(winnr: integer): integer|nil
---@field forget fun(winnr: integer)
---@field sweep fun(stay: boolean, live: NumbPeek|nil)
---@field reset fun()

---The in-place peek: the target window's own cursor moves to the line.
---@type NumbStrategy
local window_strategy = {}

function window_strategy.show(handle, line, range)
  handle.line = window_peek(handle.winnr, line)
  handle.range = nil
  if range and api.nvim_win_is_valid(handle.winnr) then
    handle.range = highlight_range(handle.winnr, range[1], range[2])
  end
end

function window_strategy.move(handle, line, range)
  -- Not a move in place: restored first, so the options and view saved again
  -- are the ones from before the peek, not the ones the previous target left.
  window_unpeek(handle.winnr, false, false)
  window_strategy.show(handle, line, range)
end

function window_strategy.hide(handle, stay, deferred)
  return window_unpeek(handle.winnr, stay, deferred)
end

function window_strategy.alive(handle)
  return api.nvim_win_is_valid(handle.winnr)
end

function window_strategy.origin(winnr)
  local win_state = state.win_states[winnr]
  return win_state and win_state.cursor[1]
end

function window_strategy.forget(winnr)
  local win_state = state.win_states[winnr]
  if win_state then
    -- Cleared through the remembered buffer, not the window: by the time this
    -- runs during a command line the window can already be gone, and looking the
    -- buffer up through it would silently do nothing.
    clear_range(win_state.bufnr)
    state.win_states[winnr] = nil
  end
end

function window_strategy.sweep(stay, live)
  -- Every window with saved state, not just the current one. The window that was
  -- peeking can already be gone: closing it during a command line, which any
  -- plugin dismissing a float from a timer will do, gives no `WinClosed` at all,
  -- and focus has moved on by now. Keying off the current window would leave
  -- that peek's saved state and its range highlight behind for the rest of the
  -- session. The one window skipped is that of a peek another plugin still
  -- holds: this command line never touched it. At most one window peeks at a
  -- time, so this loop is one iteration in every ordinary case.
  local held = live and live.strategy == window_strategy and live.winnr
  for _, winnr in ipairs(vim.tbl_keys(state.win_states)) do
    if winnr ~= held then
      unpeek_after_command(winnr, stay)
    end
  end
end

function window_strategy.reset()
  -- A failed restore never blocks the teardown after it. `vim.tbl_keys`
  -- snapshots the keys because `window_unpeek` removes entries from the table
  -- being walked.
  for _, winnr in ipairs(vim.tbl_keys(state.win_states)) do
    pcall(window_unpeek, winnr, false, false)
  end
  state.win_states = {}
  state.peek_cursor = nil
end

---Every strategy, so a closed window is swept from each whichever drew there.
---@type NumbStrategy[]
local STRATEGIES = { window_strategy }

---The strategy a new peek is drawn with. The one place a choice between
---strategies is made; there is only the window strategy for now.
---@return NumbStrategy
local function choose_strategy()
  return window_strategy
end

-------------------------------------------------------------------------------
-- Handle
--
-- A `NumbPeek` is one peek over its whole life: opened on a window, moved with
-- `update()`, ended by `accept()` or `cancel()`. Only one is live at a time,
-- which is what `state.active` records, so a handle that has been superseded,
-- ended or had its window closed simply stops doing anything. Every
-- consumer, the command line included, goes through one, and the handle
-- changes the screen only through its strategy.
-------------------------------------------------------------------------------

---@class NumbPeek
---@field winnr integer Target window handle, never 0
---@field strategy NumbStrategy How the peek is drawn
---@field line integer|nil The line peeked, clamped to the buffer
---@field range integer[]|nil The highlighted range as `{ low, high }`, clamped
local NumbPeek = {}
NumbPeek.__index = NumbPeek

---Tell other plugins about a change to the peek, as `User NumbPeek` or
---`User NumbUnpeek`. `modeline = false` because nothing about a peek changes
---which modelines apply, and processing them for every keystroke would be waste.
---@param pattern string
---@param data table
local function fire(pattern, data)
  api.nvim_exec_autocmds("User", { pattern = pattern, modeline = false, data = data })
end

---The event data describing a handle.
---@param handle NumbPeek
---@return table
local function event_data(handle)
  return { win = handle.winnr, line = handle.line, range = handle.range }
end

---@param value any
---@return boolean
local function is_integer(value)
  -- NaN is the one number that is not equal to itself, and `math.floor` of it
  -- is NaN again, so it is ruled out by the same comparison as a fraction. The
  -- infinities do equal their own floor, so they are ruled out by name.
  return type(value) == "number" and math.floor(value) == value and value ~= math.huge and value ~= -math.huge
end

---Raise unless `value` is an integer. A float passes a type check, and the
---window API would then truncate or reject it only after the window changed.
---@param value any
---@param name string What the value is, for the message
---@param level integer Stack level to blame, as `error()` counts it from the
---function calling this one
local function expect_integer(value, name, level)
  if not is_integer(value) then
    error(("numb.peek: %s must be an integer, got %s"):format(name, vim.inspect(value)), level + 1)
  end
end

---Check what a caller wants peeked, raising on anything malformed. Called
---straight from the public entry points, so errors blame their caller.
---@param line any
---@param opts any
---@return integer[]|nil range The requested range, if any
local function validate_target(line, opts)
  expect_integer(line, "line", 3)
  if opts ~= nil and type(opts) ~= "table" then
    error(("numb.peek: opts must be a table, got %s"):format(vim.inspect(opts)), 3)
  end
  local range = opts and opts.range
  if range ~= nil and not (type(range) == "table" and is_integer(range[1]) and is_integer(range[2])) then
    error(("numb.peek: range must be a { first, last } pair of integers, got %s"):format(vim.inspect(range)), 3)
  end
  return range
end

---Set by `numb` to draw what a handle changed while the command line is open,
---where Vim does not draw on its own before waiting for input.
---@type fun()|nil
local redraw_hook = nil

---Ask for the handle's change to be drawn, if nothing else will draw it.
local function changed()
  if redraw_hook and fn.mode() == "c" then
    redraw_hook()
  end
end

-------------------------------------------------------------------------------
-- Transitions
--
-- Showing, moving or ending a peek sets and restores window options, and each
-- of those fires `OptionSet`; landing on a target can fire `WinEnter` and the
-- like. An autocommand opening a peek right then would start one on top of a
-- window that is half peeked or half restored, or one this peek then records
-- over. So while any of that runs, every peek asked for gets an inactive
-- handle. `User NumbPeek` and `User NumbUnpeek` fire outside a transition, so
-- listeners of those can open peeks as they like, with one exception on
-- purpose: the final teardown of `open` after `MAX_TAKEOVERS` fires
-- `NumbUnpeek` inside one, so the listener that keeps reopening is refused. A
-- listener raising there replaces the "keeps reopening" error with its own.
-------------------------------------------------------------------------------

---How many transitions are running, nested in one another. A count rather
---than a flag, so an inner one ending does not clear the outer one.
local transition_depth = 0

---Run `step` as a transition, with the guard lifted however it ends.
---@param step fun(...): any
---@param ... any Arguments for `step`
---@return any result What `step` returned
local function during_transition(step, ...)
  transition_depth = transition_depth + 1
  local ok, result = pcall(step, ...)
  transition_depth = transition_depth - 1
  if not ok then
    error(result, 0)
  end
  return result
end

---Bumped by `reset()`, so an `open` or `update` that an autocommand disabled
---the plugin under can tell and give up instead of peeking into a plugin that
---is off.
local generation = 0

-------------------------------------------------------------------------------
-- Pending accepts
--
-- A command line peek that was confirmed is over at `CmdlineLeave`: the window
-- is restored there, so the Ex command runs from the origin and its relative
-- addresses count from it. What is left, landing on the target and telling
-- listeners with `NumbUnpeek`, waits until the command has run, both because
-- the command may have changed the buffer (`:38,40d`) and because a listener
-- opening a peek right there would move the cursor the command counts from
-- (`:+2d` would delete near that peek instead).
--
-- At most one such accept waits per window. A peek opened there before it runs
-- settles it first: by then the command has run, so the landing is made and its
-- `NumbUnpeek` fires, both before the new peek shows. That keeps the jumplist
-- entry of each of two command lines confirmed back to back, and the landing
-- cannot override the newer peek, which is drawn after it.
--
-- `NumbUnpeek` fires at most once per peek, and exactly once whenever the
-- restore and the landing complete. Neither raises on its own; they can only
-- through a user autocommand they trigger, such as `WinEnter` while landing,
-- or through the `:normal` the landing runs. When one does, the error
-- propagates and that peek's `NumbUnpeek` is skipped, here, in `finish` and in
-- `accept_after_command` alike, rather than firing for a window left half
-- restored.
-------------------------------------------------------------------------------

---@class NumbPendingAccept
---@field data table The `NumbUnpeek` event data, `accepted` included
---@field land fun()|nil The jump still to make

---@type table<integer, NumbPendingAccept>
local pending = {}

---Settle the accept waiting in a window, if any: land on its target, then fire
---its `NumbUnpeek`.
---@param winnr integer Window handle
local function flush_pending(winnr)
  local record = pending[winnr]
  if not record then
    return
  end
  -- Removed first, so a listener reacting below finds nothing left to flush and
  -- the event fires at most once.
  pending[winnr] = nil
  if record.land then
    during_transition(record.land)
  end
  fire("NumbUnpeek", record.data)
end

---End the live handle: stop showing it and tell listeners.
---@param handle NumbPeek The handle in `state.active`
---@param stay boolean
local function finish(handle, stay)
  -- Cleared before restoring, so an autocommand the restore fires sees no live
  -- peek and cannot end this one a second time.
  state.active = nil
  during_transition(handle.strategy.hide, handle, stay, false)
  changed()
  local data = event_data(handle)
  data.accepted = stay
  fire("NumbUnpeek", data)
end

---End the handle if it is the live one.
---@param handle NumbPeek
---@param stay boolean
---@return boolean ended False when the handle was not live, or could no longer
---be shown, in which case its leftovers are still cleaned up
local function settle(handle, stay)
  if state.active ~= handle then
    return false
  end
  local alive = handle.strategy.alive(handle)
  finish(handle, stay and alive)
  return alive
end

---Undo a show or move that `reset()` ran into, through an autocommand the step
---fired. The reset put back what was applied until then and the step applied
---the rest on top, so the strategy puts the window back once more. Fires no
---event: the reset already told listeners about a peek that was live, and one
---that never became live has nothing to tell.
---@param handle NumbPeek
---@param started integer `generation` before the step
---@return boolean undone False when no reset happened, and nothing was done
local function undo_after_reset(handle, started)
  if generation == started then
    return false
  end
  if state.active == handle then
    state.active = nil
  end
  during_transition(handle.strategy.hide, handle, false, false)
  changed()
  return true
end

---@return boolean active Whether this handle is the live peek
function NumbPeek:is_active()
  return state.active == self and self.strategy.alive(self)
end

---Move the peek to another line.
---@param line integer Target line, clamped to the buffer
---@param opts? { range?: integer[] }
---@return boolean moved False, and nothing done, when the handle is not live
function NumbPeek:update(line, opts)
  local range = validate_target(line, opts)
  if not self:is_active() then
    -- A live handle whose window vanished without `WinClosed` still owes a
    -- restore of its buffer and an `NumbUnpeek`.
    settle(self, false)
    return false
  end
  local started = generation
  during_transition(self.strategy.move, self, line, range)
  if undo_after_reset(self, started) then
    -- The reset ended this peek, `NumbUnpeek` included, so nothing moved.
    return false
  end
  changed()
  fire("NumbPeek", event_data(self))
  return true
end

---Stay at the peeked line, recording the jump in the jumplist right away.
---@return boolean accepted
function NumbPeek:accept()
  return settle(self, true)
end

---Put the window back as it was before the peek.
---@return boolean cancelled
function NumbPeek:cancel()
  return settle(self, false)
end

---Accept for the command line: the window is restored now, so the Ex command
---runs from the origin, while the jump and `NumbUnpeek` wait until it has run.
---A module function rather than a method, so no public handle can reach it.
---@param handle NumbPeek
---@return boolean accepted
local function accept_after_command(handle)
  if state.active ~= handle then
    return false
  end
  if not handle.strategy.alive(handle) then
    -- Nothing to land on, so nothing to wait for either.
    finish(handle, false)
    return false
  end

  state.active = nil
  local winnr = handle.winnr
  local data = event_data(handle)
  data.accepted = true
  -- No record can be waiting here already: this handle was opened in this
  -- window, and opening settles the one waiting there first.
  local record = { data = data, land = during_transition(handle.strategy.hide, handle, true, true) }
  pending[winnr] = record
  changed()
  vim.schedule(function()
    -- A newer peek in this window already settled it.
    if pending[winnr] == record then
      flush_pending(winnr)
    end
  end)
  return true
end

---How many peeks opening one may end before giving up. Each end fires
---`NumbUnpeek`, and a listener can open another peek right there; one that
---does so every time would otherwise never let this peek start.
local MAX_TAKEOVERS = 10

---A handle that was never live, for a caller asking while the plugin is off.
---@param winnr integer Target window handle
---@return NumbPeek
local function inactive(winnr)
  return setmetatable({ winnr = winnr, strategy = choose_strategy() }, NumbPeek)
end

---End whatever is older than a peek about to open in `winnr`: the accept
---waiting there, then the live peek.
---@param winnr integer
local function end_older(winnr)
  if pending[winnr] then
    flush_pending(winnr)
  elseif state.active then
    settle(state.active, false)
  end
end

---Start a peek, ending whichever one was live.
---@param winnr integer Target window handle, not 0
---@param line integer Target line, clamped to the buffer
---@param range integer[]|nil Range to highlight
---@return NumbPeek
local function open(winnr, line, range)
  if transition_depth > 0 then
    return inactive(winnr)
  end

  -- A loop, not a single pass: ending a peek fires `NumbUnpeek`, and a
  -- listener can open another one right there. That peek is live when this one
  -- takes over, so it is ended too, until nothing is left to end. The accept
  -- waiting in this window goes first, being the oldest.
  local started = generation
  local takeovers = 0
  while pending[winnr] or state.active do
    if takeovers == MAX_TAKEOVERS then
      -- Whatever is left goes too, as a transition so every peek asked for
      -- meanwhile is refused and the error leaves nothing peeking behind it.
      during_transition(function()
        flush_pending(winnr)
        if state.active then
          settle(state.active, false)
        end
      end)
      error("numb.peek: a NumbUnpeek listener keeps reopening a peek", 3)
    end
    takeovers = takeovers + 1
    end_older(winnr)
    -- A listener disabled the plugin: off means no new peek either.
    if generation ~= started then
      return inactive(winnr)
    end
  end

  local handle = setmetatable({ winnr = winnr, strategy = choose_strategy() }, NumbPeek)
  during_transition(handle.strategy.show, handle, line, range)
  if undo_after_reset(handle, started) then
    -- Never made live, so the handle is inactive, and no event fires for it.
    return handle
  end
  changed()
  state.active = handle
  fire("NumbPeek", event_data(handle))
  return handle
end

---The line a peek showing in `winnr` started from, whichever strategy draws it.
---@param winnr integer Window handle
---@return integer|nil
local function origin_line(winnr)
  for _, strategy in ipairs(STRATEGIES) do
    local line = strategy.origin(winnr)
    if line then
      return line
    end
  end
  return nil
end

---Drop whatever a closed window left behind.
---@param winnr integer The window being closed
local function forget_window(winnr)
  -- Every strategy is asked, not only the live handle's: a raw `numb._peek`
  -- leaves saved state that no handle accounts for.
  for _, strategy in ipairs(STRATEGIES) do
    strategy.forget(winnr)
  end
  local handle = state.active
  -- `WinClosed` fires while the window is still valid, so the target window
  -- closing is matched by handle; the strategy reports any window of its own.
  if handle and (handle.winnr == winnr or not handle.strategy.alive(handle)) then
    -- Nothing is left to restore, but listeners were told the peek started and
    -- are owed its end. No `changed()`: the window going away redraws anyway.
    state.active = nil
    local data = event_data(handle)
    data.accepted = false
    fire("NumbUnpeek", data)
  end
end

---End every peek the command line leaves behind, except one still live.
---@param stay boolean Whether the command line was confirmed
local function sweep(stay)
  local live = state.active and state.active:is_active() and state.active or nil
  during_transition(function()
    for _, strategy in ipairs(STRATEGIES) do
      strategy.sweep(stay, live)
    end
  end)
end

---End every peek and put back everything every strategy changed, for
---`disable()`. Never raises. An accept already confirmed is left waiting: the
---user asked for that jump before the plugin was switched off.
local function reset()
  -- First, so an `open` whose takeover got here through a listener sees it.
  generation = generation + 1
  -- The live peek is ended through its handle, whoever opened it, so its holder
  -- sees it go inactive and listeners get their `User NumbUnpeek`.
  if state.active then
    pcall(settle, state.active, false)
  end
  -- Cleared again because the settle above is protected: when it raised, the
  -- handle may still be recorded as live, and after this there is none.
  state.active = nil
  -- Then everything no handle accounts for, such as a raw `numb._peek`.
  pcall(during_transition, function()
    for _, strategy in ipairs(STRATEGIES) do
      strategy.reset()
    end
  end)
end

peek.state = state
peek.window_peek = window_peek
peek.unpeek_after_command = unpeek_after_command
peek.expect_integer = expect_integer
peek.validate_target = validate_target
peek.open = open
peek.accept_after_command = accept_after_command
peek.inactive = inactive
peek.origin_line = origin_line
peek.forget_window = forget_window
peek.sweep = sweep
peek.reset = reset

---Install what draws a handle's changes from command line mode.
---@param hook fun()
function peek.set_redraw_hook(hook)
  redraw_hook = hook
end

return peek
