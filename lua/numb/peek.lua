---@mod numb.peek Previewing a line in a window, and putting the window back.
---
--- Internal: `numb` is the only caller. It owns the peek state (saved windows,
--- the live handle, the options in effect), the handle, and its two strategies:
--- the window strategy, which moves a window's cursor onto the target and saves
--- whatever that changed so it can be restored exactly, and the float strategy,
--- which shows the target in a float and leaves the window alone. What only the
--- command line needs, such as deferred drawing, stays in `numb`.
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
  -- Setting it fires `OptionSet`, and a listener can close the window right
  -- there, which leaves nothing to center or to put back.
  if not api.nvim_win_is_valid(winnr) then
    return
  end
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
    -- Recorded again in case a `reset()` run by one of the autocommands above
    -- dropped it and put the window back, after which the rest of this peeked
    -- it anyway; otherwise this is the same entry. Recorded, the window stays
    -- restorable, which is how the handle undoes a peek the plugin was disabled
    -- under.
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
-- How a peek is drawn, kept apart from the handle so the float strategy sits
-- next to the window strategy without reshaping the handle. A strategy is a
-- table of these functions:
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

-------------------------------------------------------------------------------
-- Float strategy
--
-- The target is shown in a float on the same buffer, anchored to the target
-- window, and the target window itself is never touched: nothing is saved
-- because nothing changes, and ending the peek is closing a window. Syntax,
-- extmarks and the range highlight come for free, the float being a real
-- window on the buffer.
-------------------------------------------------------------------------------

---@class NumbFloat
---@field handle NumbPeek The handle drawing in the float
---@field target integer The window the float is anchored to
---@field bufnr integer Buffer both windows show, and so the one the range is on
---@field origin_cursor integer[] The target window's cursor when the float
---opened, whose column the float keeps
---@field closing boolean|nil Set once numb starts closing the float itself

---Every open float, keyed by its window handle. At most one outside a
---transition, like every peek. A float numb closes itself is marked `closing`
---before it is closed, which is how the `WinClosed` that follows is told apart
---from someone else closing it, and dropped only once the close succeeded, so
---a float whose close failed is still found by `reset()` and
---`leftover_floats()`.
---@type table<integer, NumbFloat>
local floats = {}

---A copy of `floats` to walk while closing, which removes entries. Shallow, so
---the records and the handles in them are the same tables.
---@return table<integer, NumbFloat>
local function floats_snapshot()
  local snapshot = {}
  for float, record in pairs(floats) do
    snapshot[float] = record
  end
  return snapshot
end

---Default border: only a top edge, which is where the title goes, so the strip
---reads as a strip rather than a box over the window.
local TOP_EDGE_BORDER = { "", "─", "", "", "", "", "", "" }

---Fewest rows of text a float has, so the target always has a line of context
---either side of it.
local MIN_FLOAT_ROWS = 3

---The float drawing a handle, if any.
---@param handle NumbPeek
---@return integer|nil float
---@return NumbFloat|nil record
local function float_of(handle)
  for float, record in pairs(floats) do
    if record.handle == handle then
      return float, record
    end
  end
  return nil, nil
end

---The user's 'winborder' (0.11 and later), or nil when it is unset or absent.
---@return string|string[]|nil
local function user_winborder()
  if fn.exists "+winborder" == 0 then
    return nil
  end
  local winborder = vim.o.winborder
  if winborder == "" then
    return nil
  end
  -- A list of characters is written comma separated in the option, and taken
  -- as a list by `nvim_open_win`.
  return winborder:find(",", 1, true) and vim.split(winborder, ",", { plain = true }) or winborder
end

---Which edges a border draws, in whatever shape `nvim_open_win` takes it. An
---edge is drawn when its character is not empty; the corners never add one.
---@param border any
---@return { top: boolean, right: boolean, bottom: boolean, left: boolean }
local function border_edges(border)
  if border == nil then
    border = user_winborder() or "none"
  end
  if type(border) == "string" then
    if border == "none" or border == "" then
      return { top = false, right = false, bottom = false, left = false }
    elseif border == "shadow" then
      return { top = false, right = true, bottom = true, left = false }
    end
    return { top = true, right = true, bottom = true, left = true }
  end
  -- A list repeats to eight characters, so `{ "x" }` is all edges, and each item
  -- is a character or a `{ char, hl_group }` pair.
  local function drawn(index)
    local char = border[(index - 1) % #border + 1]
    if type(char) == "table" then
      char = char[1]
    end
    return char ~= nil and char ~= ""
  end
  return { top = drawn(2), right = drawn(4), bottom = drawn(6), left = drawn(8) }
end

---Rows of text a window shows, its 'winbar' not counted. A float anchored with
---`relative = "win"` counts its rows from the first of these, below the
---winbar, and the winbar is taken as the window was last drawn, which is what
---Neovim places the float against.
---@param winnr integer Window handle
---@return integer
local function text_rows(winnr)
  return api.nvim_win_get_height(winnr) - (fn.getwininfo(winnr)[1].winbar or 0)
end

---The rows and columns a border's edges take, in whatever shape
---`nvim_open_win` takes it.
---@param border any
---@return integer rows
---@return integer cols
local function border_size(border)
  local edges = border_edges(border)
  return (edges.top and 1 or 0) + (edges.bottom and 1 or 0), (edges.left and 1 or 0) + (edges.right and 1 or 0)
end

---Whether a float with `border` fits inside a window: the fewest rows of text
---a float has, plus that border, with nothing sticking out over the window
---below.
---@param winnr integer Window handle, valid
---@param border any The border, as `nvim_open_win` takes it
---@return boolean
local function float_fits(winnr, border)
  local border_rows = border_size(border)
  return text_rows(winnr) >= MIN_FLOAT_ROWS + border_rows
end

---Where a float with `border` goes over `target`: its content rows, its first
---row and its width.
---@param target integer Target window handle
---@param border any The border the float has
---@param height integer|nil Content rows to place the float for, as given,
---instead of the ones `float.height` asks for: a height `win_config` set
---@return integer height Content rows, the border not counted
---@return integer row
---@return integer width
local function float_layout(target, border, height)
  local float_opts = state.opts.float
  local target_rows = text_rows(target)
  local border_rows, border_cols = border_size(border)

  -- Content rows, the border not counted. At least `MIN_FLOAT_ROWS`, and
  -- otherwise no taller than the window's text. `choose_strategy` peeks in
  -- place in a window too small for both.
  local rows = height
  if not rows then
    rows = float_opts.height < 1 and math.floor(target_rows * float_opts.height) or float_opts.height
    rows = math.max(MIN_FLOAT_ROWS, math.min(rows, target_rows - border_rows))
  end

  local frame_height = rows + border_rows
  local on_top = float_opts.position == "top"
  if float_opts.position == "auto" then
    -- On the bottom edge unless it would cover the line the cursor is on, which
    -- is the context the float is there to keep in sight. `winline()` counts
    -- rows of text, as `target_rows` does.
    local cursor_row = api.nvim_win_call(target, fn.winline)
    on_top = cursor_row > target_rows - frame_height
  end
  -- Only a height `win_config` set can make the frame taller than the window,
  -- which then starts on the first row and sticks out below it.
  local row = on_top and 0 or math.max(0, target_rows - frame_height)
  return rows, row, math.max(1, api.nvim_win_get_width(target) - border_cols)
end

---The window configuration of a float showing `line` over `target`.
---@param target integer Target window handle
---@param bufnr integer Buffer the float shows, whose lines the title counts
---@param line integer Line shown, already clamped
---@return table config For `nvim_open_win`, after `float.win_config`
local function float_config(target, bufnr, line)
  local float_opts = state.opts.float
  -- A copy of the default, so a `win_config` changing the list it is handed
  -- changes this float only.
  local border = user_winborder() or vim.list_extend({}, TOP_EDGE_BORDER)
  local height, row, width = float_layout(target, border)

  local win_config = {
    relative = "win",
    win = target,
    row = row,
    col = 0,
    width = width,
    height = height,
    focusable = false,
    -- No `WinNew`, `WinEnter` or `BufEnter`, so statusline, LSP and window
    -- decorating plugins are not run on every keystroke of a command line.
    noautocmd = true,
    style = "minimal",
    border = border,
  }
  if border_edges(border).top then
    win_config.title = (" %d/%d "):format(line, api.nvim_buf_line_count(bufnr))
  end
  if float_opts.win_config then
    local returned = float_opts.win_config(win_config)
    -- Raised here, before the float is opened or moved, rather than as an index
    -- error on a number somewhere below. An `auto` peek switching from in place
    -- to a float has already put the window back by then.
    if returned ~= nil and type(returned) ~= "table" then
      error(("numb.peek: float.win_config must return a table or nil, got %s"):format(vim.inspect(returned)), 0)
    end
    -- A shallow copy of what it returned, which numb changes below and `move`
    -- changes again, so the user's table stays as they left it: one they keep
    -- and return every time is still theirs the next time.
    if returned then
      win_config = vim.tbl_extend("force", {}, returned)
    end
    -- Laid out again for the border the float will actually have, which
    -- `win_config` may have changed, except where it set a size or a row of
    -- its own: those are left as it returned them. A row it left alone is
    -- placed again for the height it set, if it set one, so a taller float
    -- still ends inside the window, and `auto` judges the cursor line against
    -- that height.
    local height_kept = win_config.height == height
    -- Anything but a number is left for `nvim_open_win` to reject by name.
    local own_height = not height_kept and type(win_config.height) == "number" and win_config.height or nil
    local final_height, final_row, final_width = float_layout(target, win_config.border, own_height)
    if height_kept then
      win_config.height = final_height
    end
    if win_config.row == row then
      win_config.row = final_row
    end
    if win_config.width == width then
      win_config.width = final_width
    end
  end
  -- The title sits on the top edge, so a border without one, whether a user's
  -- 'winborder' or what `win_config` returned, means no title rather than E5555.
  if win_config.title and not border_edges(win_config.border).top then
    win_config.title = nil
    win_config.title_pos = nil
  end
  return win_config
end

---Point an open float at `line`, the target always centered: in a strip a few
---rows high, a target on its first row would lose the context above it.
---@param handle NumbPeek
---@param float integer Float window handle
---@param line integer Line to show, already clamped
---@param range integer[]|nil Range to highlight
local function float_point(handle, float, line, range)
  local record = floats[float]
  api.nvim_win_set_cursor(float, { line, record.origin_cursor[2] })
  center_cursor(float)
  handle.line = line
  handle.range = nil
  -- Centering fires `OptionSet`, and a listener can close the float there.
  if not api.nvim_win_is_valid(float) then
    return
  end
  if range then
    handle.range = highlight_range(float, range[1], range[2])
  else
    clear_range(record.bufnr)
  end
end

---The window options a float could leave behind in its buffer. Neovim records
---the options of a window closing on a buffer and gives them to the next
---window opened on it: 0.10 and 0.11 do for every float, 0.12 for one opened
---without `style = "minimal"`.
local RECORDED_WINDOW_OPTIONS = {
  "number",
  "relativenumber",
  "cursorline",
  "cursorcolumn",
  "foldenable",
  "foldcolumn",
  "signcolumn",
  "colorcolumn",
  "statuscolumn",
  "spell",
  "list",
  "fillchars",
  "winbar",
}

---The copy `float_resemble_target` has `:noautocmd` run, handed over through
---this module-local because the command takes a string. Internal.
---@type fun()|nil
local pending_copy = nil

---Run the copy `float_resemble_target` left, once. Internal, reached only
---through the `:noautocmd lua` command that function runs, never raising.
function peek._run_pending_copy()
  local copy = pending_copy
  pending_copy = nil
  if copy then
    pcall(copy)
  end
end

---Make a float about to close look, to what Neovim records of it, like the
---target window: closing it records its cursor as the position a new window on
---the buffer opens on, and its options as the ones that window starts with.
---The float's cursor is moved to the target's cursor, so a new window on the
---buffer opens where the target window is, and the target's window-local
---options are copied onto it. Run under `:noautocmd`, so no `OptionSet`
---listener runs for options that are not the user's to see, not even for
---'eventignore', which `:noautocmd` sets and restores without firing one.
---Never raises.
---@param float integer Float window handle
---@param record NumbFloat
local function float_resemble_target(float, record)
  if not (api.nvim_win_is_valid(float) and api.nvim_win_get_buf(float) == record.bufnr) then
    return
  end
  local target = record.target
  local target_valid = api.nvim_win_is_valid(target)
  local cursor = record.origin_cursor
  if target_valid and api.nvim_win_get_buf(target) == record.bufnr then
    cursor = api.nvim_win_get_cursor(target)
  end
  pending_copy = function()
    pcall(api.nvim_win_set_cursor, float, { clamp_linenr(record.bufnr, cursor[1]), cursor[2] })
    if not target_valid then
      return
    end
    -- Copied even when the target has switched to another buffer since the
    -- float opened: the options are the target window's, whatever it shows,
    -- and they are what a window opened from it would start with anyway.
    for _, option in ipairs(RECORDED_WINDOW_OPTIONS) do
      if not (api.nvim_win_is_valid(float) and api.nvim_win_is_valid(target)) then
        break
      end
      pcall(function()
        local value = api.nvim_get_option_value(option, { win = target, scope = "local" })
        api.nvim_set_option_value(option, value, { win = float, scope = "local" })
      end)
    end
  end
  pcall(cmd, "noautocmd lua require('numb.peek')._run_pending_copy()")
  -- Dropped whether or not the command got to run it.
  pending_copy = nil
end

---Close a float whose teardown was already attempted, or which is gone: all
---that is left is the window. Its target is never touched again, since what
---was on it, the flag, the range and a landing, was dealt with by that first
---attempt, and by now it may belong to a later peek. Never raises.
---@param float integer Float window handle
---@param record NumbFloat
local function float_close_again(float, record)
  if api.nvim_win_is_valid(float) then
    pcall(api.nvim_win_close, float, true)
  end
  if floats[float] == record and not api.nvim_win_is_valid(float) then
    floats[float] = nil
  end
end

---Close a float and clear what it drew, landing in the target when staying.
---A float whose teardown was already attempted is only closed again.
---@param float integer Float window handle
---@param record NumbFloat
---@param stay boolean
---@return fun()|nil land When staying, the jump to make
local function float_close(float, record, stay)
  if record.closing then
    float_close_again(float, record)
    return nil
  end
  -- A float that went without `WinClosed` reaching `forget`, as a window
  -- closed during the command line does, is still on its first teardown, and
  -- its handle was never hidden: no later peek can be on the target yet, so
  -- the flag and the range cleared below are its own. There is no landing,
  -- though: a peek whose float is gone was not alive to be accepted.
  if not api.nvim_win_is_valid(float) then
    stay = false
  end
  -- Marked, not dropped, until the close succeeds: a close can fail, through an
  -- autocommand raising, and the float left open must still be found.
  record.closing = true
  clear_range(record.bufnr)
  -- The float leaves the target window alone, whose cursor can move while the
  -- peek lasts, so a landing comes from wherever it is now. For the command
  -- line that is where the Ex command runs from.
  local origin_cursor = record.origin_cursor
  if api.nvim_win_is_valid(record.target) then
    vim.w[record.target].numb_peeking = nil
    origin_cursor = api.nvim_win_get_cursor(record.target)
  end
  float_resemble_target(float, record)
  if api.nvim_win_is_valid(float) then
    api.nvim_win_close(float, true)
  end
  if floats[float] == record then
    floats[float] = nil
  end
  local line = record.handle.line
  if stay and line then
    -- The target window never moved, so landing from its cursor records the
    -- same jumplist entry and centers the same way as the window strategy.
    return landing(record.target, record.bufnr, origin_cursor, { line, origin_cursor[2] })
  end
  return nil
end

---@type NumbStrategy
local float_strategy = {}

function float_strategy.show(handle, line, range)
  local target = handle.winnr
  local bufnr = api.nvim_win_get_buf(target)
  line = clamp_linenr(bufnr, line)
  handle.line = line
  handle.range = nil

  -- `prepared` is always set here: `show` runs only once `choose_strategy` chose
  -- the float, which prepares its configuration. Made again only defensively.
  local win_config = handle.prepared or float_config(target, bufnr, line)
  handle.prepared = nil
  -- Opened from the target window, not the current one: a new window starts
  -- with the local and global-local option values of the window it is opened
  -- from, and closing the float records those on the buffer. `nvim_win_call`
  -- switches windows without autocommands, and `noautocmd` in the
  -- configuration keeps the open itself quiet.
  local float = api.nvim_win_call(target, function()
    return api.nvim_open_win(bufnr, false, win_config)
  end)
  local record = {
    handle = handle,
    target = target,
    bufnr = bufnr,
    origin_cursor = api.nvim_win_get_cursor(target),
  }
  floats[float] = record

  -- The peek options go on the float, never on the target window. Floats never
  -- draw the global 'winbar', but a window-local one is copied from the target
  -- and would take a row of the strip, so the float clears its own. 'wrap'
  -- follows the target so a line looks the same in both.
  local float_options = {
    foldenable = false,
    winbar = "",
    wrap = api.nvim_get_option_value("wrap", { win = target }),
  }
  if state.opts.show_numbers then
    float_options.number = true
  end
  if state.opts.show_cursorline then
    float_options.cursorline = true
  end
  if state.opts.hide_relativenumbers then
    float_options.relativenumber = false
  end
  -- Each option set fires `OptionSet`, and a listener, or a `reset()` run from
  -- there, can close the float before the next one is set.
  for option, value in pairs(float_options) do
    if not api.nvim_win_is_valid(float) then
      break
    end
    api.nvim_set_option_value(option, value, { win = float, scope = "local" })
  end

  -- Closed that way, the handle is not alive and `open` or `update` gives up.
  -- Otherwise it is recorded again, in case something dropped the record while
  -- leaving the window open, so `hide` still finds it.
  if not api.nvim_win_is_valid(float) then
    return
  end
  floats[float] = record
  float_point(handle, float, line, range)
  if not api.nvim_win_is_valid(float) then
    return
  end
  -- On the target window: that is the window the peek is about, and the one
  -- `numb.is_peeking()` and statusline integrations ask about.
  vim.w[target].numb_peeking = true
end

function float_strategy.move(handle, line, range)
  local prepared = handle.prepared
  handle.prepared = nil
  local float = float_of(handle)
  if not float then
    return
  end
  local bufnr = floats[float].bufnr
  line = clamp_linenr(bufnr, line)
  -- Made for the buffer the target window shows, which is the float's unless
  -- the target switched buffers mid-peek.
  if api.nvim_win_get_buf(handle.winnr) ~= bufnr then
    prepared = nil
  end
  -- Reconfigured in place, never closed and opened again: the `WinClosed` of
  -- closing it would end this peek in the middle of moving it. `noautocmd` is
  -- only for opening, and `style` again would reset the float's options.
  local win_config = prepared or float_config(handle.winnr, bufnr, line)
  win_config.noautocmd = nil
  win_config.style = nil
  api.nvim_win_set_config(float, win_config)
  float_point(handle, float, line, range)
end

function float_strategy.hide(handle, stay, deferred)
  local float, record = float_of(handle)
  if not float then
    return nil
  end
  ---@cast record NumbFloat
  local land = float_close(float, record, stay)
  if land and not deferred then
    land()
    return nil
  end
  return land
end

function float_strategy.alive(handle)
  local float, record = float_of(handle)
  return float ~= nil and not record.closing and api.nvim_win_is_valid(float) and api.nvim_win_is_valid(record.target)
end

function float_strategy.origin()
  -- The target window's cursor never moves, so it is the origin itself.
  return nil
end

function float_strategy.forget(winnr)
  local record = floats[winnr]
  if record and record.closing then
    -- numb is closing it itself, and drops the record once that succeeded.
    return
  end
  if record then
    -- Someone else closed the float. Dropping it is what makes `alive()` false
    -- for its handle.
    floats[winnr] = nil
    clear_range(record.bufnr)
    if api.nvim_win_is_valid(record.target) then
      vim.w[record.target].numb_peeking = nil
    end
    return
  end
  -- The target window is closing. Neovim leaves a float open when the window
  -- it is anchored to closes, so it is closed here.
  for float, target_record in pairs(floats_snapshot()) do
    if target_record.target == winnr then
      pcall(float_close, float, target_record, false)
    end
  end
end

function float_strategy.sweep(stay, live)
  for float, record in pairs(floats_snapshot()) do
    if record.handle ~= live then
      local land = float_close(float, record, stay)
      if land then
        vim.schedule(land)
      end
    end
  end
end

function float_strategy.reset()
  for float, record in pairs(floats_snapshot()) do
    pcall(float_close, float, record, false)
  end
  -- A float whose close failed again is still open, and kept, so
  -- `leftover_floats()` reports it and the next `reset()` closes it. The rest
  -- are records of floats already gone.
  for float in pairs(floats_snapshot()) do
    if not api.nvim_win_is_valid(float) then
      floats[float] = nil
    end
  end
end

---Every strategy, so a closed window is swept from each whichever drew there.
---@type NumbStrategy[]
local STRATEGIES = { window_strategy, float_strategy }

---The strategy a peek is drawn with. The one place a choice between strategies
---is made. A window too small to hold a float peeks in place whatever the
---style, rather than under a float covering the window below.
---
---Whether the float fits depends on its border, which `float.win_config` has
---the last word on, so a float is judged on the configuration it would open
---with, and that configuration is returned with it for `show` or `move` to
---use, so `win_config` usually runs once per open or move. It can run again:
---when `move` finds the target switched buffers and discards the prepared
---configuration, and it runs for a float that then turns out not to fit, which
---peeks in place instead.
---@param style string A `peek_style`
---@param winnr integer Target window handle
---@param line integer|nil The line to peek; without one `auto` peeks in place
---@return NumbStrategy
---@return table|nil win_config The float's configuration, when it is the float
local function choose_strategy(style, winnr, line)
  if style == "window" or not api.nvim_win_is_valid(winnr) then
    return window_strategy
  end
  if not line then
    -- Nothing to show, so no configuration to ask `win_config` for: numb's own
    -- border decides.
    if style == "float" and float_fits(winnr, user_winborder() or TOP_EDGE_BORDER) then
      return float_strategy
    end
    return window_strategy
  end
  local bufnr = api.nvim_win_get_buf(winnr)
  -- Judged on the line that would be shown, not the one asked for: `:9999` in a
  -- short buffer peeks its last line, which may well be on screen.
  line = clamp_linenr(bufnr, line)
  if style == "auto" then
    local on_screen = api.nvim_win_call(winnr, function()
      return line >= fn.line "w0" and line <= fn.line "w$"
    end)
    if on_screen then
      return window_strategy
    end
  end
  local win_config = float_config(winnr, bufnr, line)
  if not float_fits(winnr, win_config.border) then
    return window_strategy
  end
  return float_strategy, win_config
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
---@field style string The `peek_style` it was opened with; `auto` chooses the
---strategy again on every `update()`
---@field line integer|nil The line peeked, clamped to the buffer
---@field range integer[]|nil The highlighted range as `{ low, high }`, clamped
---@field prepared table|nil The float configuration `choose_strategy` made for
---the next `show` or `move`, which takes it
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

---The `NumbPeek` event data describing a handle.
---@param handle NumbPeek
---@return table
local function event_data(handle)
  -- The float too, when there is one, for a listener that decorates it. Still
  -- `win` is the target window, whatever the strategy.
  return { win = handle.winnr, line = handle.line, range = handle.range, float_win = (float_of(handle)) }
end

---The `NumbUnpeek` event data describing a handle. Never a `float_win`: the
---float is closed by then, or was meant to be.
---@param handle NumbPeek
---@param accepted boolean
---@return table
local function unpeek_data(handle, accepted)
  return { win = handle.winnr, line = handle.line, range = handle.range, accepted = accepted }
end

local is_integer = config.is_integer

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
---@return string|nil style The requested `peek_style`, if any
local function validate_target(line, opts)
  expect_integer(line, "line", 3)
  if opts ~= nil and type(opts) ~= "table" then
    error(("numb.peek: opts must be a table, got %s"):format(vim.inspect(opts)), 3)
  end
  local range = opts and opts.range
  if range ~= nil and not (type(range) == "table" and is_integer(range[1]) and is_integer(range[2])) then
    error(("numb.peek: range must be a { first, last } pair of integers, got %s"):format(vim.inspect(range)), 3)
  end
  local style = opts and opts.style
  if style ~= nil and not vim.tbl_contains(config.PEEK_STYLES, style) then
    error(
      ("numb.peek: style must be %s, got %s"):format(config.format_choices(config.PEEK_STYLES), vim.inspect(style)),
      3
    )
  end
  return range, style
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
-- listeners of those can open peeks as they like, with two exceptions. The
-- final teardown of `open` after `MAX_TAKEOVERS` fires `NumbUnpeek` inside
-- one on purpose, so the listener that keeps reopening is refused; a listener
-- raising there replaces the "keeps reopening" error with its own. And when
-- `disable()` runs from an autocommand that a transition fired, the
-- `NumbUnpeek` of `reset()` fires inside that outer transition, so a peek its
-- listener asks for gets an inactive handle too.
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
  fire("NumbUnpeek", unpeek_data(handle, stay))
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
  -- The handle is not live here: `open` has not made it so yet, and for
  -- `update` the reset already cleared it.
  during_transition(handle.strategy.hide, handle, false, false)
  changed()
  return true
end

---Move a live handle to another line, with whichever strategy its style now
---chooses. Switching strategy is one step of the same peek: the old drawing
---is hidden without landing and the new one shown, all inside the caller's
---transition, so listeners see one `NumbPeek` and no `NumbUnpeek`.
---@param handle NumbPeek
---@param line integer
---@param range integer[]|nil
local function retarget(handle, line, range)
  local current = handle.strategy
  if handle.style ~= "window" and current.origin(handle.winnr) then
    -- Taken when the window strategy is the current one, since only it has an
    -- origin: the peek moved the target window's own view, so it is put back
    -- before choosing: `auto` asks whether the line is on screen as the user left it,
    -- not as the previous target scrolled it, and a float is laid out against
    -- the window as the user left it. This is also exactly how the window
    -- strategy moves anyway, restoring before peeking again.
    current.hide(handle, false, false)
    handle.strategy, handle.prepared = choose_strategy(handle.style, handle.winnr, line)
    handle.strategy.show(handle, line, range)
    return
  end
  local chosen
  chosen, handle.prepared = choose_strategy(handle.style, handle.winnr, line)
  if chosen == current then
    current.move(handle, line, range)
    return
  end
  -- Switched before hiding: closing a float fires `WinClosed`, and the handle
  -- must not look dead to it while it is still the live peek.
  handle.strategy = chosen
  current.hide(handle, false, false)
  chosen.show(handle, line, range)
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
  local range, style = validate_target(line, opts)
  if style ~= nil then
    error("numb.peek: update() takes no style, a peek keeps the one it was opened with", 2)
  end
  if not self:is_active() then
    -- A live handle whose window vanished without `WinClosed` still owes a
    -- restore of its buffer and an `NumbUnpeek`.
    settle(self, false)
    return false
  end
  local started = generation
  during_transition(retarget, self, line, range)
  if undo_after_reset(self, started) then
    -- The reset ended this peek, `NumbUnpeek` included, so nothing moved.
    return false
  end
  if not self.strategy.alive(self) then
    -- A listener closed a window the move needed, such as the float. The peek
    -- is over: ended here if `WinClosed` has not ended it already, which is
    -- one `NumbUnpeek` either way.
    if not settle(self, false) then
      during_transition(self.strategy.hide, self, false, false)
      changed()
    end
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
  local data = unpeek_data(handle, true)
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
---@param style string|nil The `peek_style` asked for, nil for the configured one
---@return NumbPeek
local function inactive(winnr, style)
  style = style or state.opts.peek_style
  return setmetatable({ winnr = winnr, style = style, strategy = choose_strategy(style, winnr, nil) }, NumbPeek)
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
---@param style string|nil The `peek_style` to draw with, nil for the configured one
---@return NumbPeek
local function open(winnr, line, range, style)
  style = style or state.opts.peek_style
  if transition_depth > 0 then
    return inactive(winnr, style)
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
      return inactive(winnr, style)
    end
  end

  -- Chosen only now that every older peek has ended, so `auto` sees the target
  -- window as that peek left it: put back.
  local strategy, prepared = choose_strategy(style, winnr, line)
  local handle = setmetatable({ winnr = winnr, style = style, strategy = strategy, prepared = prepared }, NumbPeek)
  during_transition(handle.strategy.show, handle, line, range)
  if undo_after_reset(handle, started) then
    -- Never made live, so the handle is inactive, and no event fires for it.
    return handle
  end
  if not handle.strategy.alive(handle) then
    -- A listener closed a window the peek needed while it was shown, such as
    -- the float. Put back whatever is left, and never made live, as above.
    during_transition(handle.strategy.hide, handle, false, false)
    changed()
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
    fire("NumbUnpeek", unpeek_data(handle, false))
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

---Floats still open whose handle is no longer the live peek, for
---`:checkhealth numb`. Always empty unless a teardown was cut short.
---@return integer[]
local function leftover_floats()
  local leftovers = {}
  for float, record in pairs(floats) do
    if (record.closing or record.handle ~= state.active) and api.nvim_win_is_valid(float) then
      table.insert(leftovers, float)
    end
  end
  table.sort(leftovers)
  return leftovers
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
peek.leftover_floats = leftover_floats

---Install what draws a handle's changes from command line mode.
---@param hook fun()
function peek.set_redraw_hook(hook)
  redraw_hook = hook
end

return peek
