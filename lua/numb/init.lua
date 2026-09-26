---@mod numb Core peek logic for :{number} and relative Ex commands.
---
--- The whole plugin is three steps: `CmdlineChanged` asks `numb.address` what the
--- command line points at, a `numb.peek` handle previews it while saving what it
--- changed, and `CmdlineLeave` restores that state, staying at the target when
--- the command was confirmed. The command line is one consumer of that handle;
--- `numb.peek()` hands the same one to other plugins.
---
--- Every keystroke redoes that in full: the handle's `update()` restores the
--- window first and peeks again from scratch, so `win_states` holds at most one
--- entry per window and never accumulates across a command line. That is why the
--- options and view a peek saves are always the ones from before the peek, not
--- the ones a previous keystroke left behind.
local numb = {}

local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local address = require "numb.address"
local config = require "numb.config"
local peek = require "numb.peek"

local state = peek.state

---Define the range highlight. `default = true` so a user or colorscheme
---definition of `NumbRange` wins; linking to `Visual` means the preview looks
---like a selection, which is what a pending range operation effectively is.
local function define_highlight()
  api.nvim_set_hl(0, "NumbRange", { link = "Visual", default = true })
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
-- Drawing
--
-- A peek is applied on every change to the command line but drawn only once Vim
-- is about to wait for the user. Characters that arrive together are processed
-- one `CmdlineChanged` at a time: a mapping, the `.,.+5` Vim inserts for a count
-- before `:`, a paste. Drawing after each of those showed states nobody was
-- meant to see, such as the peek a mapping clears with `<C-U>` a moment later
-- (#36). Only the drawing waits; the peek itself, and so what a confirmed
-- command lands on, does not depend on how fast the keys came.
-------------------------------------------------------------------------------

---How long a requested redraw waits for `SafeState` before drawing anyway. It
---is a fallback for anything that keeps Vim from reaching `SafeState` while the
---user is looking at the command line, such as an open completion menu or an
---`'eventignore'` that lists it. The timer normally fires only while Vim waits
---for input, so not in the middle of a mapping; inside one that waits itself,
---with `getchar()` or `:sleep`, it costs at most one extra redraw.
local REDRAW_FALLBACK_MS = 50

---True while a peek has changed the screen and has not been drawn yet.
local redraw_pending = false

---The fallback timer, one for the whole session and created on first use. It
---runs only while a redraw is pending: dropping a redraw stops the timer too.
---A callback the timer queued just before `stop()` can still run once, and
---finds nothing pending or draws a request made since, which is harmless.
---@type uv.uv_timer_t|nil
local redraw_timer = nil

---Forget a pending redraw without drawing it.
local function drop_redraw()
  redraw_pending = false
  if redraw_timer then
    redraw_timer:stop()
  end
end

---Draw what the peek changed, if anything is still waiting to be drawn.
local function flush_redraw()
  if redraw_pending then
    drop_redraw()
    cmd "redraw"
  end
end

---Ask for the peek to be drawn once Vim goes idle.
local function request_redraw()
  if redraw_pending then
    return
  end
  redraw_pending = true
  redraw_timer = redraw_timer or (vim.uv or vim.loop).new_timer()
  redraw_timer:start(REDRAW_FALLBACK_MS, 0, vim.schedule_wrap(flush_redraw))
end

-- Every handle change made in command line mode is drawn this way, whoever
-- made it: the command line's own peek, or another plugin's handle driven from
-- a `<Cmd>` mapping. In every other mode Vim draws by itself before waiting for
-- input, so the hook does nothing there.
peek.set_redraw_hook(request_redraw)

-------------------------------------------------------------------------------
-- Autocommands
-------------------------------------------------------------------------------

---The peek the command line holds while it is open, or nil. Kept apart from
---`state.active` so the command line can tell its own peek from one another
---plugin opened through `numb.peek()`.
---@type NumbPeek|nil
local cmdline_peek = nil

---Preview whatever the command line now points at.
local function on_cmdline_changed()
  local winnr = api.nvim_get_current_win()

  -- Nothing was peeked in an excluded buffer, so there is nothing to tear down
  -- either and the teardown on `CmdlineLeave`, which walks the saved state, has
  -- no entry to find.
  if is_disabled_for(winnr) then
    return
  end

  -- The command line is always in the current window, so a peek of its own held
  -- anywhere else belongs to a window that has since gone.
  if cmdline_peek and cmdline_peek.winnr ~= winnr then
    cmdline_peek:cancel()
    cmdline_peek = nil
  end

  -- While a peek is already running the cursor sits on the previewed line, so
  -- relative offsets have to count from the saved origin instead. Otherwise
  -- typing another digit would compound the offset. That holds for a peek
  -- another plugin opened in this window too: the command line takes it over
  -- below, and cancelling it puts the cursor back on that same origin.
  local base_line = peek.origin_line(winnr) or api.nvim_win_get_cursor(winnr)[1]
  local last_line = api.nvim_buf_line_count(api.nvim_win_get_buf(winnr))

  local target = address.resolve(fn.getcmdline(), base_line, last_line, state.opts.number_only)
  if not target then
    -- Only the command line's own peek goes. One another plugin opened stays, so
    -- `:w` or `:let` typed while a picker previews a line leaves the preview up.
    if cmdline_peek then
      cmdline_peek:cancel()
      cmdline_peek = nil
    end
    return
  end

  -- `target.line` is the lower bound of a range, so the start of it is on
  -- screen. That is also where `:d` leaves the cursor, but only `:d`: `:y` does
  -- not move it at all, and `:m`, `:t` and `:s` finish near their destination.
  -- So this is a deliberate choice of what to show, not a prediction of where
  -- Vim will land.
  local range = state.opts.range_peek and target.first and { target.first, target.last } or nil
  if cmdline_peek and cmdline_peek:is_active() then
    cmdline_peek:update(target.line, { range = range })
  else
    -- Opening ends whatever peek was live, so a peek another plugin holds is
    -- taken over here: one peek at a time, and the command line is the newest.
    -- A listener disabling the plugin meanwhile leaves an inactive handle here,
    -- which every later call treats as a no-op.
    cmdline_peek = peek.open(winnr, target.line, range)
  end
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

  if cmdline_peek then
    -- The window is restored now, so the command runs from where the peek
    -- started, but the jump and `NumbUnpeek` wait for it: `:38,40d` changes the
    -- buffer the target has to be clamped against.
    if stay then
      peek.accept_after_command(cmdline_peek)
    else
      cmdline_peek:cancel()
    end
    cmdline_peek = nil
  end

  -- Whatever else is still peeking goes too, such as a peek in a window closed
  -- during the command line, which gives no `WinClosed`. A peek another plugin
  -- still holds is left up: this command line never touched it.
  peek.sweep(stay)

  -- Leaving the command line redraws on its own, and a redraw still pending
  -- would otherwise run at the first `SafeState` in Normal mode, drawing the
  -- window between the command and the jump applied after it. Dropped last,
  -- because ending the peeks above, in command line mode still, asks for one.
  drop_redraw()
end

---Reclaim the state of a window that was closed mid-peek.
---Belt and braces rather than the main path: `on_cmdline_exit` sweeps every
---peek left and a restore handles a stale window itself, and a window closed while
---the command line is open emits no `WinClosed` at all. What this does add is
---timing: when a peeked window is closed with no command line in flight, which
---is what a `numb.peek()` or direct `numb._peek` call amounts to, the range stops
---being drawn at that moment instead of waiting for a `CmdlineLeave` that may
---never come, and the handle peeking there stops being active.
---@param event table Autocommand callback argument
local function on_win_closed(event)
  local winnr = tonumber(event.match)
  if winnr then
    peek.forget_window(winnr)
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
  api.nvim_create_autocmd("SafeState", { group = augroup_id, callback = flush_redraw })
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
  -- Marked disabled before anything is ended, so a `User NumbUnpeek` listener
  -- calling `numb.peek()` below gets an inactive handle instead of a new peek.
  if augroup_id then
    pcall(api.nvim_del_augroup_by_id, augroup_id)
    augroup_id = nil
  end

  -- Every peek goes, whoever opened it: off means off for peeks other plugins
  -- asked for too. A peek being opened right now, by a takeover whose
  -- `NumbUnpeek` listener got here, comes back inactive.
  peek.reset()
  cmdline_peek = nil
  drop_redraw()
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

---Preview a line in a window without moving there, the way the command line
---does, and return the handle that moves, accepts or cancels that preview.
---Only one peek is live at a time: this ends whichever one was, and a command
---line that addresses a line ends this one. While the plugin is disabled the
---handle is inactive from the start and nothing is peeked. The buftype and
---filetype filters do not apply: they decide when the command line peeks on
---its own, and a caller here asked explicitly.
---@param winnr integer Window handle, `0` for the current window
---@param line integer Line to peek, clamped to the buffer
---@param opts? { range?: integer[] } `range = { first, last }` highlights those
---lines as well
---@return NumbPeek
function numb.peek(winnr, line, opts)
  peek.expect_integer(winnr, "winnr", 2)
  local range = peek.validate_target(line, opts)
  if winnr == 0 then
    winnr = api.nvim_get_current_win()
  end
  if not api.nvim_win_is_valid(winnr) then
    error(("numb.peek: invalid window %d"):format(winnr), 2)
  end

  if not numb.is_enabled() then
    return peek.inactive(winnr)
  end

  -- Drawn by the redraw hook when called from command line mode, as from a
  -- `<Cmd>` mapping there; every other mode draws by itself.
  return peek.open(winnr, line, range)
end

-- Internals the test suite drives directly; not part of the public API. These
-- are the raw window strategy, beneath any handle: a peek started through
-- `_peek` is not live and nothing but `_unpeek` or `disable()` ends it.
numb._state = state
numb._peek = peek.window_peek
numb._unpeek = peek.unpeek_after_command

return numb
