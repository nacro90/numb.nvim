local function feedkeys(cmd)
  local keys = vim.api.nvim_replace_termcodes(cmd, true, false, true)
  vim.api.nvim_feedkeys(keys, "nx", false)
end

local function wait_until_idle()
  -- vim.wait returns `false, -1` on timeout, and a single assignment keeps only
  -- the boolean, so `ok ~= -1` was always true and this guard could never fire.
  -- Assert the boolean itself: false means the mode never settled.
  local ok = vim.wait(1000, function()
    local mode = vim.api.nvim_get_mode()
    return mode.mode == "n" and not mode.blocking
  end, 10, false)
  assert(ok, "timeout waiting for command completion")
end

local function run_cmd(cmd)
  feedkeys(cmd)
  wait_until_idle()
end

-- Give queued vim.schedule callbacks a chance to run. The confirmed jump is
-- applied from one, so anything that asserts where the cursor ended up has to
-- wait for it. There is nothing to poll for: the point is to yield, not to reach
-- a condition, which is why the predicate never succeeds.
local function drain_scheduled(ms)
  vim.wait(ms or 100, function()
    return false
  end, 10, false)
end

local function reset_buffer()
  vim.cmd "enew!"
  local lines = {}
  for i = 1, 40 do
    lines[i] = string.format("line %02d", i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
end

local function assert_cursor(expected, label)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  assert(line == expected, ("%s: expected line %d, got %d"):format(label, expected, line))
end

local function configure(opts)
  -- A confirmed jump from an earlier test is applied from a scheduled callback,
  -- and it must not run inside this one. A sentinel scheduled behind it proves
  -- the queue ahead of it has drained, where a fixed sleep would only hope so.
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  assert(
    vim.wait(1000, function()
      return drained
    end, 1, false),
    "scheduled callbacks did not drain"
  )
  local existing = package.loaded["numb"]
  if existing and type(existing.disable) == "function" then
    existing.disable()
  end
  package.loaded["numb"] = nil
  -- numb.peek owns the shared state, so it is reloaded too or that state survives.
  package.loaded["numb.peek"] = nil
  local module = require "numb"
  local base_opts = { centered_peeking = false }
  if opts then
    base_opts = vim.tbl_extend("force", base_opts, opts)
  end
  module.setup(base_opts)
  return module
end

-- The 1-indexed line range currently highlighted by the plugin, or nil when
-- nothing is. Found by namespace name rather than through a test-only hook, so
-- the test observes what any other plugin would see.
local function highlighted_range(bufnr)
  local ns = vim.api.nvim_get_namespaces()["numb_range"]
  if not ns then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  if #marks == 0 then
    return nil
  end
  local first, last
  for _, mark in ipairs(marks) do
    local row, details = mark[2], mark[4]
    local stop = details and details.end_row or row
    first = first and math.min(first, row) or row
    last = last and math.max(last, stop) or stop
  end
  -- The count is reported alongside the span because merging hides the difference
  -- between one extmark covering 5..10 and two stale ones that happen to span it,
  -- and a range is meant to be exactly one extmark however long it is.
  return { first + 1, last + 1, count = #marks }
end

-- Observe the peek produced by a real command line, then end it with
-- `terminator`. This is the only way to exercise the address parsing path,
-- because `_peek` takes a resolved line number and so bypasses parsing
-- entirely. The observer is registered after numb's own CmdlineChanged handler,
-- so it runs second and sees the result.
local function observe_cmdline(cmdline, terminator)
  local numb = require "numb"
  local observed
  local group = vim.api.nvim_create_augroup("numb_test_probe", { clear = true })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    pattern = ":",
    callback = function()
      observed = {
        cmdline = vim.fn.getcmdline(),
        peeking = numb.is_peeking(),
        line = vim.api.nvim_win_get_cursor(0)[1],
        range = highlighted_range(0),
      }
    end,
  })
  feedkeys(cmdline .. terminator)
  wait_until_idle()
  vim.api.nvim_del_augroup_by_id(group)
  assert(observed ~= nil, ("the probe never observed a CmdlineChanged for %q"):format(cmdline))
  assert(
    observed.cmdline == cmdline:sub(2),
    ("the probe observed %q, expected %q"):format(observed.cmdline, cmdline:sub(2))
  )
  return observed
end

-- Abandon the command line with <C-c>, not <Esc>: inside a macro, and feedkeys
-- counts as one, <Esc> executes the command rather than cancelling it (see
-- :h c_<Esc>). So nothing typed through this helper is ever executed.
local function probe_cmdline(cmdline)
  return observe_cmdline(cmdline, "<C-c>")
end

-- The same observation, but the command is confirmed instead of abandoned. Vim
-- resolves every address this plugin understands on its own, so asserting only
-- where the cursor ends up after `:$` would hold with numb uninstalled. The
-- observation is what proves the plugin previewed the target first.
local function confirm_cmdline(cmdline)
  return observe_cmdline(cmdline, "\r")
end

-- Type `cmdline`, confirm it with <CR>, and check both halves of the behaviour:
-- that numb previewed the target while it was being typed, and that the cursor
-- ended up there. Vim resolves all of these addresses itself, so without the
-- first assertion the second one holds with the plugin uninstalled.
local function assert_confirmed_jump(cmdline, expected, label)
  local observed = confirm_cmdline(cmdline)
  assert(observed.peeking, ("%s: %s must peek while it is being typed"):format(label, cmdline))
  assert(
    observed.line == expected,
    ("%s: %s must preview line %d, previewed %d"):format(label, cmdline, expected, observed.line)
  )
  assert_cursor(expected, label)
end

-------------------------------------------------------------------------------
-- CORE NAVIGATION TESTS (ABSOLUTE)
-------------------------------------------------------------------------------

local Tests = {}

function Tests.absolute_jump_navigation()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_confirmed_jump(":5", 5, "absolute jump to line 5")
end

function Tests.absolute_jump_keeps_window_options()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.wo.number = false
  vim.wo.relativenumber = true
  run_cmd ":5\r"
  assert_cursor(5, "absolute jump")
  assert(vim.wo.number == false, "number option restored after confirm")
  assert(vim.wo.relativenumber == true, "relativenumber option restored after confirm")
end

function Tests.out_of_bounds_targets_are_clamped()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  run_cmd ":999\r"
  assert_cursor(40, "jump clamps to buffer end")
  run_cmd ":0\r"
  assert_cursor(1, "jump clamps to buffer start")
end

function Tests.sequential_absolute_jumps_clear_state()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.wo.number = false
  run_cmd ":10\r"
  assert_cursor(10, "first jump")
  run_cmd ":2\r"
  assert_cursor(2, "second jump reuses same window cleanly")
  assert(vim.wo.number == false, "window state restored between sequential jumps")
end

-------------------------------------------------------------------------------
-- RELATIVE JUMP TESTS
-------------------------------------------------------------------------------

function Tests.relative_forward_jump()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  assert_confirmed_jump(":+5", 15, "relative forward jump :+5 from line 10")
end

function Tests.relative_backward_jump()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  assert_confirmed_jump(":-5", 15, "relative backward jump :-5 from line 20")
end

function Tests.relative_forward_single()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  assert_confirmed_jump(":+", 6, "relative forward :+ (implicit 1)")
end

function Tests.relative_backward_single()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  assert_confirmed_jump(":-", 9, "relative backward :- (implicit 1)")
end

-------------------------------------------------------------------------------
-- COMPLEX EXPRESSION TESTS
-------------------------------------------------------------------------------

function Tests.complex_expression_addition()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  assert_confirmed_jump(":+2+3", 15, "complex expression :+2+3 from line 10 = 15")
end

function Tests.complex_expression_subtraction()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  assert_confirmed_jump(":-2-3", 15, "complex expression :-2-3 from line 20 = 15")
end

function Tests.complex_expression_mixed()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  assert_confirmed_jump(":+5-2", 13, "complex expression :+5-2 from line 10 = 13")
end

function Tests.double_plus_signs()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  assert_confirmed_jump(":++", 7, "double plus :++ from line 5 = 7 (5+1+1)")
end

function Tests.double_minus_signs()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  assert_confirmed_jump(":--", 8, "double minus :-- from line 10 = 8 (10-1-1)")
end

function Tests.absolute_with_arithmetic()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_confirmed_jump(":10+5", 15, "absolute with arithmetic :10+5 = 15")
end

function Tests.absolute_with_subtraction()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_confirmed_jump(":20-5", 15, "absolute with subtraction :20-5 = 15")
end

-------------------------------------------------------------------------------
-- EDGE CASE TESTS
-------------------------------------------------------------------------------

function Tests.relative_out_of_bounds_high()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 35, 0 })
  run_cmd ":+100\r"
  assert_cursor(40, "relative jump clamps to buffer end")
end

function Tests.relative_out_of_bounds_low()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  -- Note: Vim's native command rejects negative ranges with "E16: Invalid range"
  -- So we test a smaller jump that stays valid
  run_cmd ":-4\r"
  assert_cursor(1, "relative jump clamps to buffer start")
end

-------------------------------------------------------------------------------
-- CONFIGURATION TESTS (basic - tests final navigation, not peek state)
-------------------------------------------------------------------------------

function Tests.number_only_true_ignores_substitution_pattern()
  configure { number_only = true }
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- With number_only=true, :10s should NOT be recognized as a line number
  -- So Vim's native substitute command runs (which fails, but we catch that)
  -- The important thing is cursor doesn't move from peek
  -- The substitute itself is expected to fail; its result is deliberately ignored.
  pcall(run_cmd, ":10s\r")
  -- Command may fail (invalid substitute), but cursor should be at 1
  assert_cursor(1, "number_only=true: cursor stays at original (no peek)")
end

-------------------------------------------------------------------------------
-- STATE ENCAPSULATION TESTS
-------------------------------------------------------------------------------

function Tests.state_win_states_cleared_after_jump()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd ":10\r"
  assert_cursor(10, "jump completed")
  -- After jump, win_states should be empty (state cleaned up)
  local state = numb._state
  assert(state, "numb._state should be exposed for testing")
  assert(vim.tbl_isempty(state.win_states), "win_states should be empty after confirmed jump")
end

function Tests.state_peek_cursor_cleared_after_jump()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd ":15\r"
  -- Wait for scheduled callback to complete
  drain_scheduled()
  local state = numb._state
  assert(state.peek_cursor == nil, "peek_cursor should be nil after confirmed jump")
end

function Tests.disable_drops_state_left_behind_by_a_window_that_is_gone()
  local numb = configure()
  reset_buffer()
  -- An entry for a window that no longer exists is what an interrupted peek can
  -- leave behind. disable() is the only thing that resets this state, so it is
  -- exercised through that rather than by reaching for an internal method.
  numb._state.win_states[999] = {
    bufnr = vim.api.nvim_get_current_buf(),
    cursor = { 1, 0 },
    options = {},
    topline = 1,
  }
  numb._state.peek_cursor = { 10, 0 }

  numb.disable()

  assert(vim.tbl_isempty(numb._state.win_states), "disable must drop saved state, stale entries included")
  assert(numb._state.peek_cursor == nil, "disable must clear the pending target")
  numb.enable()
end

function Tests.state_configure_merges_options()
  local numb = configure()
  -- Default centered_peeking is true, we set it to false in configure()
  assert(numb._state.opts.centered_peeking == false, "configure merges user options")
  assert(numb._state.opts.show_numbers == true, "configure preserves defaults")
end

-------------------------------------------------------------------------------
-- FOLD STATE RESTORATION TESTS
-------------------------------------------------------------------------------

function Tests.fold_foldenable_restored_after_confirm()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Set foldenable to true before jump
  vim.wo.foldenable = true
  run_cmd ":10\r"
  assert_cursor(10, "jump completed")
  -- foldenable should be restored to original value after confirm
  assert(vim.wo.foldenable == true, "foldenable=true should be preserved after confirm")
end

function Tests.fold_foldenable_false_preserved()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- foldenable already false
  vim.wo.foldenable = false
  run_cmd ":10\r"
  assert_cursor(10, "jump completed")
  assert(vim.wo.foldenable == false, "foldenable=false should be preserved after confirm")
end

function Tests.fold_cursorline_restored_after_confirm()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.wo.cursorline = false
  run_cmd ":15\r"
  assert_cursor(15, "jump completed")
  assert(vim.wo.cursorline == false, "cursorline=false should be restored after confirm")
end

function Tests.fold_relativenumber_restored_after_confirm()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.wo.relativenumber = true
  run_cmd ":20\r"
  assert_cursor(20, "jump completed")
  assert(vim.wo.relativenumber == true, "relativenumber=true should be restored after confirm")
end

-------------------------------------------------------------------------------
-- PEEKING FLAG TESTS
-------------------------------------------------------------------------------

function Tests.peeking_flag_unset_when_not_peeking()
  local numb = configure()
  reset_buffer()
  local win = vim.api.nvim_get_current_win()
  assert(vim.w[win].numb_peeking == nil, "flag must be nil before any peek")
  assert(numb.is_peeking() == false, "numb.is_peeking() returns false initially")
end

function Tests.peeking_flag_cleared_after_confirm()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local win = vim.api.nvim_get_current_win()
  run_cmd ":15\r"
  drain_scheduled()
  assert(vim.w[win].numb_peeking == nil, "flag must be cleared after confirmed jump")
  assert(numb.is_peeking(win) == false, "is_peeking false after confirm")
end

function Tests.peeking_flag_cleared_after_abort()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local win = vim.api.nvim_get_current_win()
  run_cmd ":15<C-c>"
  assert(vim.w[win].numb_peeking == nil, "flag must be cleared after aborted peek")
  assert(numb.is_peeking(win) == false, "is_peeking false after abort")
end

function Tests.peeking_flag_window_scoped_not_buffer_scoped()
  -- Two splits viewing the same buffer must not cross-flag each other.
  configure()
  reset_buffer()
  local win1 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win1, { 5, 0 })
  vim.cmd "vsplit"
  local win2 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win2, { 10, 0 })
  assert(vim.api.nvim_win_get_buf(win1) == vim.api.nvim_win_get_buf(win2), "both splits share the buffer")

  -- Trigger peek only in win2 (current).
  run_cmd ":20\r"
  drain_scheduled()

  -- Both flags must be cleared post-confirm; importantly, win1 must NEVER have
  -- been flagged while peeking in win2 (buffer-local flag would have leaked).
  assert(vim.w[win1].numb_peeking == nil, "win1 flag stays nil throughout")
  assert(vim.w[win2].numb_peeking == nil, "win2 flag cleared after confirm")
  vim.cmd "only"
end

function Tests.peeking_flag_default_uses_current_window()
  local numb = configure()
  reset_buffer()
  assert(numb.is_peeking() == false, "is_peeking() with no arg defaults to current window")
end

function Tests.peeking_flag_is_true_during_active_peek()
  -- Use the exposed internal _peek/_unpeek helpers to observe the flag
  -- mid-peek (impossible via feedkeys, since cmdline mode is synchronous).
  local numb = configure()
  reset_buffer()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  numb._peek(win, 15)
  assert(vim.w[win].numb_peeking == true, "flag must be true during active peek")
  assert(numb.is_peeking(win) == true, "is_peeking() returns true during active peek")
  assert(numb.is_peeking() == true, "is_peeking() with no arg also detects current peek")
  assert(numb.is_peeking(0) == true, "is_peeking(0) treats 0 as current window per nvim convention")

  numb._unpeek(win, false)
  assert(vim.w[win].numb_peeking == nil, "flag cleared after _unpeek")
end

function Tests.peeking_flag_stays_set_across_multi_keystroke_peek()
  -- Each CmdlineChanged for ":1" -> ":12" -> ":123" calls unpeek then peek again;
  -- the observable state after each keystroke must still report peeking=true.
  local numb = configure()
  reset_buffer()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  numb._peek(win, 1)
  assert(vim.w[win].numb_peeking == true, "flag true after first peek")

  -- Simulate cmdline update that retargets to a new line: unpeek + peek
  numb._unpeek(win, false)
  numb._peek(win, 12)
  assert(vim.w[win].numb_peeking == true, "flag still true after retargeting peek")

  numb._unpeek(win, false)
  numb._peek(win, 23)
  assert(vim.w[win].numb_peeking == true, "flag still true after second retarget")

  numb._unpeek(win, false)
  assert(vim.w[win].numb_peeking == nil, "flag cleared once all peeking ends")
end

function Tests.peeking_flag_invalid_winnr_returns_false()
  local numb = configure()
  reset_buffer()
  -- Use a large bogus winnr that cannot correspond to a real window
  assert(numb.is_peeking(9999999) == false, "is_peeking() on invalid winnr returns false (no error)")
end

-------------------------------------------------------------------------------
-- USER COMMAND TESTS
-------------------------------------------------------------------------------

function Tests.user_command_is_registered_after_setup()
  configure()
  local cmds = vim.api.nvim_get_commands {}
  assert(cmds.Numb, ":Numb user command should be registered after setup()")
end

function Tests.user_command_disable_stops_peeking()
  local numb = configure()
  reset_buffer()
  vim.cmd "Numb disable"
  assert(not numb.is_enabled(), "is_enabled returns false after :Numb disable")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- After disable, win_states must remain empty during :10 typing because
  -- the CmdlineChanged autocmd is gone. Vim's native :10 still moves cursor.
  run_cmd ":10\r"
  assert(vim.tbl_isempty(numb._state.win_states), "no peek state recorded while disabled")
end

function Tests.user_command_enable_restores_peeking()
  local numb = configure()
  vim.cmd "Numb disable"
  assert(not numb.is_enabled(), "disabled")
  vim.cmd "Numb enable"
  assert(numb.is_enabled(), "is_enabled returns true after :Numb enable")
end

function Tests.user_command_toggle_flips_state()
  local numb = configure()
  local before = numb.is_enabled()
  vim.cmd "Numb toggle"
  assert(numb.is_enabled() ~= before, "toggle flips state")
  vim.cmd "Numb toggle"
  assert(numb.is_enabled() == before, "second toggle returns to original state")
end

function Tests.user_command_no_arg_defaults_to_toggle()
  local numb = configure()
  local before = numb.is_enabled()
  vim.cmd "Numb"
  assert(numb.is_enabled() ~= before, "bare :Numb defaults to toggle")
  -- Restore state for subsequent tests
  vim.cmd "Numb"
end

function Tests.user_command_unknown_subcommand_notifies_error()
  configure()
  local captured = nil
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    captured = { msg = msg, level = level }
  end
  pcall(vim.cmd, "Numb bogus")
  vim.notify = orig_notify
  assert(captured ~= nil, "vim.notify must be called for unknown subcommand")
  assert(captured.level == vim.log.levels.ERROR, "notification must be at ERROR level")
  assert(captured.msg:find "bogus", "error message must mention the bad subcommand name")
end

function Tests.user_command_enable_is_idempotent()
  local numb = configure()
  assert(numb.is_enabled(), "starts enabled")
  vim.cmd "Numb enable"
  vim.cmd "Numb enable"
  assert(numb.is_enabled(), "stays enabled after repeated enable")
end

function Tests.user_command_disable_then_jump_no_state_leak()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd ":5\r"
  -- Now peek is confirmed; state.win_states should be empty after schedule callback
  drain_scheduled()
  vim.cmd "Numb disable"
  assert(vim.tbl_isempty(numb._state.win_states), "win_states empty after disable")
  assert(numb._state.peek_cursor == nil, "peek_cursor nil after disable")
  -- Re-enable for following tests
  vim.cmd "Numb enable"
end

-------------------------------------------------------------------------------
-- JUMPLIST TESTS
-------------------------------------------------------------------------------

function Tests.jumplist_ctrl_o_returns_to_origin()
  configure()
  reset_buffer()
  -- Drain any pending scheduled callbacks from earlier tests before clearing jumps.
  drain_scheduled(50)
  vim.cmd "clearjumps"
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  run_cmd ":20\r"
  -- Wait for scheduled callback to apply final cursor + jumplist push
  drain_scheduled()
  assert_cursor(20, "jumped to 20")
  local jumps = vim.fn.getjumplist()[1]
  assert(#jumps > 0, "jumplist must have at least one entry after confirmed peek")
  local last = jumps[#jumps]
  assert(last.lnum == 5, ("expected origin (line 5) in jumplist, got %d"):format(last.lnum))
  -- C-o should travel back to origin
  feedkeys "<C-o>"
  wait_until_idle()
  assert_cursor(5, "C-o returns to origin")
end

function Tests.jumplist_aborted_peek_no_entry()
  configure()
  reset_buffer()
  drain_scheduled(50)
  vim.cmd "clearjumps"
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  run_cmd ":20<C-c>"
  assert_cursor(5, "aborted peek leaves cursor at origin")
  local jumps = vim.fn.getjumplist()[1]
  assert(#jumps == 0, ("aborted peek must not add jump entry, got %d"):format(#jumps))
end

-------------------------------------------------------------------------------
-- MULTI-WINDOW TESTS
-------------------------------------------------------------------------------

local function create_split()
  vim.cmd "vsplit"
  return vim.api.nvim_get_current_win()
end

local function close_other_windows()
  vim.cmd "only"
end

local function topline_of(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview).topline
end

-- Pin `anchor` to the top of `win` and return the resulting topline. A short
-- peek from such a position does not scroll on its own, which is what makes
-- centering observable: Vim centers a long jump regardless of the setting, so a
-- long jump cannot tell centered_peeking apart.
local function pin_topline(win, anchor)
  vim.api.nvim_win_set_cursor(win, { anchor, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd "normal! zt"
  end)
  return topline_of(win)
end

function Tests.multiwin_only_active_window_affected()
  configure()
  reset_buffer()
  local win1 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win1, { 5, 0 })
  vim.wo[win1].number = false

  local win2 = create_split()
  vim.api.nvim_win_set_cursor(win2, { 10, 0 })
  vim.wo[win2].number = false

  -- Jump in win2
  run_cmd ":20\r"
  assert(vim.api.nvim_win_get_cursor(win2)[1] == 20, "win2 jumped to line 20")
  assert(vim.wo[win2].number == false, "win2 number option restored")

  -- win1 should be unaffected
  assert(vim.api.nvim_win_get_cursor(win1)[1] == 5, "win1 cursor unchanged")
  assert(vim.wo[win1].number == false, "win1 number option unchanged")

  close_other_windows()
end

function Tests.multiwin_independent_state_per_window()
  local numb = configure()
  reset_buffer()
  local win1 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win1, { 5, 0 })

  local win2 = create_split()
  vim.api.nvim_win_set_cursor(win2, { 15, 0 })

  -- Jump in win2
  run_cmd ":25\r"
  assert(vim.api.nvim_win_get_cursor(win2)[1] == 25, "win2 at line 25")

  -- Switch to win1 and jump there
  vim.api.nvim_set_current_win(win1)
  run_cmd ":10\r"
  assert(vim.api.nvim_win_get_cursor(win1)[1] == 10, "win1 at line 10")

  -- Both windows should have clean state
  local state = numb._state
  assert(vim.tbl_isempty(state.win_states), "all win_states cleared after both jumps")

  close_other_windows()
end

function Tests.multiwin_sequential_jumps_preserve_options()
  configure()
  reset_buffer()
  local win1 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win1, { 3, 0 })
  vim.wo[win1].foldenable = true

  local win2 = create_split()
  vim.api.nvim_win_set_cursor(win2, { 8, 0 })
  vim.wo[win2].foldenable = false

  -- Jump in win2
  run_cmd ":30\r"
  assert(vim.api.nvim_win_get_cursor(win2)[1] == 30, "win2 at line 30")
  assert(vim.wo[win2].foldenable == false, "win2 foldenable preserved")

  -- Switch to win1 and jump
  vim.api.nvim_set_current_win(win1)
  run_cmd ":15\r"
  assert(vim.api.nvim_win_get_cursor(win1)[1] == 15, "win1 at line 15")
  assert(vim.wo[win1].foldenable == true, "win1 foldenable preserved")

  close_other_windows()
end

-------------------------------------------------------------------------------
-- BUFFER SHRINK TESTS
-------------------------------------------------------------------------------

-- Wraps vim.schedule so errors raised inside numb's deferred callback become
-- observable from the test body. Without this they only reach stderr, which the
-- pcall in M.run() cannot see because the callback fires on a later loop tick.
local function collect_scheduled_errors(fn)
  local original_schedule = vim.schedule
  local errors = {}
  local scheduled = 0
  local completed = 0
  vim.schedule = function(callback)
    scheduled = scheduled + 1
    original_schedule(function()
      local ok, err = pcall(callback)
      completed = completed + 1
      if not ok then
        table.insert(errors, tostring(err))
      end
    end)
  end
  local ok, err = pcall(fn)
  -- Wait until every scheduled callback has actually run instead of sleeping a
  -- fixed interval. A late callback would otherwise fire after vim.schedule is
  -- restored below and append an error nobody ever inspects. Scheduling happens
  -- synchronously inside `fn`, so `scheduled` is already final here.
  -- Note this captures errors from *any* vim.schedule callback in the window,
  -- not only the plugin's; under `-u tests/init.lua -i NONE` nothing else
  -- schedules, and the counts below let callers confirm what they expected ran.
  vim.wait(1000, function()
    return completed >= scheduled
  end, 10, false)
  vim.schedule = original_schedule
  if not ok then
    error(err)
  end
  return { errors = errors, scheduled = scheduled, completed = completed }
end

function Tests.buffer_shrink_range_delete_near_eof_does_not_error()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local result = collect_scheduled_errors(function()
    run_cmd ":38,40d\r"
  end)
  assert(result.scheduled > 0, "the deferred jump must actually have been scheduled")
  assert(#result.errors == 0, ("deferred callback raised: %s"):format(table.concat(result.errors, "; ")))
  assert(vim.api.nvim_buf_line_count(0) == 37, "three lines deleted")
  local line = vim.api.nvim_win_get_cursor(0)[1]
  assert(line >= 1 and line <= 37, ("cursor must stay inside buffer, got %d"):format(line))
end

function Tests.buffer_shrink_delete_invalidating_origin_does_not_error()
  configure()
  reset_buffer()
  -- Origin (39) is what the deferred callback restores first; the command below
  -- shrinks the buffer to a single line, so the origin itself goes out of range.
  vim.api.nvim_win_set_cursor(0, { 39, 0 })
  local result = collect_scheduled_errors(function()
    run_cmd ":1,39d\r"
  end)
  assert(result.scheduled > 0, "the deferred jump must actually have been scheduled")
  assert(#result.errors == 0, ("deferred callback raised: %s"):format(table.concat(result.errors, "; ")))
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(0)
  assert(line >= 1 and line <= count, ("cursor must stay inside buffer, got %d of %d"):format(line, count))
end

-------------------------------------------------------------------------------
-- DISABLE DURING ACTIVE PEEK TESTS
-------------------------------------------------------------------------------

function Tests.disable_during_active_peek_restores_window_state()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.wo.number = false
  vim.wo.cursorline = false
  vim.wo.foldenable = true
  -- Set explicitly rather than relying on whatever leaked from an earlier test.
  -- Peeking forces this off (hide_relativenumbers defaults to true), so
  -- restoring it to true is a real assertion rather than a coincidence.
  vim.wo.relativenumber = true

  numb._peek(vim.api.nvim_get_current_win(), 25)
  assert(numb.is_peeking(), "peek must be active before disable")

  numb.disable()

  assert(vim.wo.number == false, "number restored after disable during peek")
  assert(vim.wo.cursorline == false, "cursorline restored after disable during peek")
  assert(vim.wo.foldenable == true, "foldenable restored after disable during peek")
  assert_cursor(1, "cursor restored to origin after disable during peek")
  assert(vim.wo.relativenumber == true, "relativenumber restored after disable during peek")
  assert(vim.w.numb_peeking == nil, "peeking flag cleared after disable during peek")
  assert(not numb.is_peeking(), "is_peeking false after disable during peek")
end

function Tests.disable_during_peek_in_background_window_restores_it()
  local numb = configure()
  reset_buffer()
  local peeked_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(peeked_win, { 1, 0 })
  vim.wo[peeked_win].number = false
  vim.wo[peeked_win].cursorline = false

  numb._peek(peeked_win, 30)

  -- Leave the peeking window, so restoration has to target a window that is no
  -- longer current. This is what exposes view restoration acting on the wrong
  -- window.
  local other_win = create_split()
  assert(other_win ~= peeked_win, "split must be a different window")
  local topline_before = pin_topline(other_win, 40)
  -- Guard against a vacuous pass: if the other window were already at topline 1
  -- the assertion below could not detect the wrong window being scrolled.
  assert(topline_before > 1, ("setup must scroll the other window, topline is %d"):format(topline_before))

  numb.disable()

  assert(vim.wo[peeked_win].number == false, "background window number restored")
  assert(vim.wo[peeked_win].cursorline == false, "background window cursorline restored")
  assert(vim.api.nvim_win_get_cursor(peeked_win)[1] == 1, "background window cursor restored to origin")
  assert(vim.w[peeked_win].numb_peeking == nil, "background window peeking flag cleared")

  local topline_after = topline_of(other_win)
  assert(
    topline_after == topline_before,
    ("disable() must not scroll the current window, topline %d became %d"):format(topline_before, topline_after)
  )

  close_other_windows()
end

function Tests.closing_a_peeked_window_reclaims_its_saved_state()
  local numb = configure()
  reset_buffer()
  local peeked_win = create_split()
  numb._peek(peeked_win, 20)
  assert(numb._state.win_states[peeked_win] ~= nil, "state must be saved while peeking")

  vim.cmd "wincmd p"
  vim.api.nvim_win_close(peeked_win, true)

  -- Nothing else can reclaim it: unpeek is only ever driven by CmdlineLeave for
  -- the current window, so without a WinClosed hook the entry would survive for
  -- the rest of the session.
  assert(numb._state.win_states[peeked_win] == nil, "closing a window mid-peek must reclaim its saved state")
  close_other_windows()
end

function Tests.disable_after_peeked_window_closed_still_disables()
  local numb = configure()
  reset_buffer()
  local closed_win = create_split()
  numb._peek(closed_win, 20)
  vim.api.nvim_win_close(closed_win, true)
  assert(not vim.api.nvim_win_is_valid(closed_win), "window is gone before disable")

  local ok, err = pcall(numb.disable)

  assert(ok, ("disable() must not raise on a stale window handle, got %s"):format(tostring(err)))
  assert(not numb.is_enabled(), "disable() must complete teardown even after a stale window")
  assert(vim.tbl_isempty(numb._state.win_states), "win_states cleared despite the stale window")

  close_other_windows()
end

-------------------------------------------------------------------------------
-- CENTERED PEEKING TESTS
-------------------------------------------------------------------------------

-- Every other test forces centered_peeking off for deterministic cursor checks,
-- so the default (on) would otherwise never be exercised even though it is the
-- path every real user hits.

-- A buffer much taller than the window, so scrolling has room in both
-- directions and the assertions are not distorted by either buffer end.
local function reset_tall_buffer()
  vim.cmd "enew!"
  local lines = {}
  for i = 1, 500 do
    lines[i] = ("line %03d"):format(i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
end

function Tests.centered_peeking_centers_the_peeked_line()
  local numb = configure { centered_peeking = true }
  reset_tall_buffer()
  local win = vim.api.nvim_get_current_win()
  local height = vim.api.nvim_win_get_height(win)
  local anchor = 250
  local target = anchor + 5
  local topline_before = pin_topline(win, anchor)

  numb._peek(win, target)

  local topline_after = topline_of(win)
  local offset = target - topline_after
  local middle = math.floor(height / 2)
  assert(
    topline_after < topline_before,
    ("centering must scroll the window, topline stayed at %d"):format(topline_after)
  )
  assert(
    math.abs(offset - middle) <= 1,
    ("peeked line must sit mid window: topline %d, height %d, offset %d, expected about %d"):format(
      topline_after,
      height,
      offset,
      middle
    )
  )

  numb._unpeek(win, false)
end

function Tests.centered_peeking_only_scrolls_the_peeked_window()
  local numb = configure { centered_peeking = true }
  reset_tall_buffer()
  local peeked_win = vim.api.nvim_get_current_win()
  local peeked_topline_before = pin_topline(peeked_win, 250)

  -- Move to another window before peeking, so centering has to happen in a
  -- window that is not the current one.
  local other_win = create_split()
  local other_topline_before = pin_topline(other_win, 100)
  assert(other_topline_before ~= peeked_topline_before, "the two windows must start at different toplines")

  numb._peek(peeked_win, 255)

  local peeked_topline_after = topline_of(peeked_win)
  local other_topline_after = topline_of(other_win)
  assert(
    peeked_topline_after < peeked_topline_before,
    ("the peeked window must be centered, topline stayed at %d"):format(peeked_topline_after)
  )
  assert(
    other_topline_after == other_topline_before,
    ("the current window must not scroll, topline %d became %d"):format(other_topline_before, other_topline_after)
  )

  numb._unpeek(peeked_win, false)
  close_other_windows()
end

-- A count before a mapping that opens the command line makes Vim insert
-- `.,.+{count-1}`, which numb peeks before the mapping's `<C-U>` clears it. That
-- peek must not run a Normal mode command: `:normal` resets `v:count`, so the
-- mapping would see a count of 1. quick-scope's `f` mapping is built exactly like
-- this, and `6fi` jumped to the first `i` instead of the sixth (#36).
function Tests.count_survives_a_mapping_that_opens_the_command_line()
  local numb = configure { centered_peeking = true }
  reset_tall_buffer()
  vim.api.nvim_win_set_cursor(0, { 250, 0 })

  local peeked_during_mapping = false
  local probe = vim.api.nvim_create_autocmd("CmdlineChanged", {
    callback = function()
      peeked_during_mapping = peeked_during_mapping or numb.is_peeking()
    end,
  })
  vim.cmd [[nnoremap <silent> <Plug>(numb-test-count) :<C-U>let g:numb_test_count = v:count1<CR>]]
  vim.g.numb_test_count = nil

  -- No "n" flag: the keys have to go through the mapping.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("6<Plug>(numb-test-count)", true, false, true), "x", false)
  wait_until_idle()
  local seen_count = vim.g.numb_test_count

  vim.api.nvim_del_autocmd(probe)
  vim.cmd [[nunmap <Plug>(numb-test-count)]]
  vim.g.numb_test_count = nil

  -- Without a peek the count would survive for the wrong reason.
  assert(peeked_during_mapping, "the range the count inserts must be peeked")
  assert(seen_count == 6, ("the mapping must see v:count1 == 6, got %s"):format(tostring(seen_count)))
end

-------------------------------------------------------------------------------
-- PUBLIC PEEK API TESTS
-------------------------------------------------------------------------------

-- `numb.peek()` is the handle other plugins use to preview a line without the
-- command line. Every test starts the cursor somewhere the peek does not target,
-- so "restored" and "did not move" are real assertions rather than coincidences.

-- Put the current window's peek-affected options in the state opposite to what a
-- peek applies with the defaults, so both applying and restoring are observable.
local function set_unpeeked_options()
  vim.wo.number = false
  vim.wo.cursorline = false
  vim.wo.relativenumber = true
  vim.wo.foldenable = true
end

local function assert_unpeeked_options(win, label)
  assert(vim.wo[win].number == false, ("%s: number must be restored"):format(label))
  assert(vim.wo[win].cursorline == false, ("%s: cursorline must be restored"):format(label))
  assert(vim.wo[win].relativenumber == true, ("%s: relativenumber must be restored"):format(label))
  assert(vim.wo[win].foldenable == true, ("%s: foldenable must be restored"):format(label))
end

local function cursor_of(win)
  return vim.api.nvim_win_get_cursor(win)[1]
end

function Tests.api_peek_moves_the_cursor_and_applies_peek_options()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local peek = numb.peek(0, 30)

  assert(peek:is_active(), "a fresh peek must be active")
  assert_cursor(30, "peek(0, 30) moves the cursor")
  assert(vim.w[win].numb_peeking == true, "the peeking flag must be set")
  assert(numb.is_peeking(), "is_peeking() must report the API peek")
  assert(vim.wo[win].number == true, "show_numbers must apply to the API")
  assert(vim.wo[win].cursorline == true, "show_cursorline must apply to the API")
  assert(vim.wo[win].relativenumber == false, "hide_relativenumbers must apply to the API")
  assert(vim.wo[win].foldenable == false, "folds must be disabled while peeking")

  peek:cancel()
end

function Tests.api_update_moves_the_same_peek()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local peek = numb.peek(0, 30)
  assert_cursor(30, "precondition: the peek started at 30")
  local updated = peek:update(12)

  assert(updated == true, ("update() on an active peek must return true, got %s"):format(tostring(updated)))
  assert(peek:is_active(), "the handle stays active after update()")
  assert_cursor(12, "update(12) moves the cursor")
  assert(vim.w[win].numb_peeking == true, "the peeking flag survives update()")
  assert(vim.wo[win].number == true, "peek options still applied after update()")

  peek:cancel()
end

function Tests.api_cancel_restores_the_window()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local peek = numb.peek(0, 30)
  peek:update(12)
  -- Without this the restoration below could hold because nothing was applied.
  assert(vim.wo[win].number == true, "precondition: peek options were applied")
  assert_cursor(12, "precondition: the cursor was moved")

  local cancelled = peek:cancel()

  assert(cancelled == true, ("cancel() on an active peek must return true, got %s"):format(tostring(cancelled)))
  assert_unpeeked_options(win, "cancel()")
  assert_cursor(1, "cancel() returns the cursor to the origin, not to an intermediate target")
  assert(vim.w[win].numb_peeking == nil, "cancel() clears the peeking flag")
  assert(not numb.is_peeking(), "is_peeking() is false after cancel()")
  assert(not peek:is_active(), "the handle is inactive after cancel()")
  assert(vim.tbl_isempty(numb._state.win_states), "cancel() leaves no saved state")
end

function Tests.api_update_with_a_range_highlights_it()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local bufnr = vim.api.nvim_get_current_buf()

  local peek = numb.peek(0, 12)
  assert(highlighted_range(bufnr) == nil, "precondition: a peek without a range highlights nothing")

  peek:update(5, { range = { 5, 10 } })
  local range = highlighted_range(bufnr)
  assert(range ~= nil, "update() with opts.range must highlight the range")
  assert(range.count == 1, ("a range must be exactly one extmark, found %d"):format(range.count))
  assert(range[1] == 5 and range[2] == 10, ("expected range 5..10, got %d..%d"):format(range[1], range[2]))
  assert_cursor(5, "the target line is still peeked")

  peek:cancel()
  assert(highlighted_range(bufnr) == nil, "cancel() clears the range highlight")
end

function Tests.api_accept_stays_at_the_target_immediately()
  local numb = configure()
  reset_buffer()
  drain_scheduled(50)
  vim.cmd "clearjumps"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local peek = numb.peek(0, 30)
  assert_cursor(30, "precondition: the peek moved the cursor to 30")
  local accepted = peek:accept()

  -- Deliberately no drain_scheduled(): the API jump is not deferred.
  assert(accepted == true, ("accept() on an active peek must return true, got %s"):format(tostring(accepted)))
  assert_cursor(30, "accept() stays at the target at once")
  assert_unpeeked_options(win, "accept()")
  assert(vim.w[win].numb_peeking == nil, "accept() clears the peeking flag")
  assert(not peek:is_active(), "the handle is inactive after accept()")
  assert(vim.tbl_isempty(numb._state.win_states), "accept() leaves no saved state")

  -- A scheduled restore arriving late would undo the jump.
  drain_scheduled()
  assert_cursor(30, "nothing deferred moves the cursor after accept()")

  vim.cmd "normal! \15"
  assert_cursor(1, "<C-o> after accept() returns to the origin")
end

function Tests.api_second_peek_takes_over_the_first()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local first = numb.peek(0, 10)
  assert(first:is_active(), "precondition: the first peek was active")
  local second = numb.peek(0, 20)

  assert(not first:is_active(), "a new peek deactivates the previous handle")
  assert(second:is_active(), "the new peek is active")
  assert_cursor(20, "the new peek moved the cursor")

  assert(first:update(5) == false, "update() on a superseded handle returns false")
  assert_cursor(20, "update() on a superseded handle does not move the cursor")
  assert(first:cancel() == false, "cancel() on a superseded handle returns false")
  assert(first:accept() == false, "accept() on a superseded handle returns false")
  assert(second:is_active(), "the superseded handle cannot end the active peek")
  assert_cursor(20, "the active peek is untouched by the superseded handle")

  second:cancel()
  -- The takeover must not record the first peek's target as the origin.
  assert_cursor(1, "cancelling the second peek returns to the line before the first one")
end

function Tests.api_command_line_takes_over_an_api_peek()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local peek = numb.peek(0, 30)
  assert_cursor(30, "precondition: the API peek moved the cursor")
  local observed = probe_cmdline ":12"

  assert(observed.peeking and observed.line == 12, "the command line peek must have replaced the API peek")
  assert(not peek:is_active(), "the command line peek deactivates the API handle")
  assert_cursor(1, "aborting the command line returns to the line before the API peek")
  assert(not numb.is_peeking(), "nothing is peeking after the command line is abandoned")
  assert(vim.tbl_isempty(numb._state.win_states), "no saved state is left behind")
end

function Tests.api_peek_survives_a_command_line_that_addresses_nothing()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.g.numb_api_probe = nil

  local peek = numb.peek(0, 30)
  run_cmd ":let g:numb_api_probe = 1\r"
  drain_scheduled()
  local probe = vim.g.numb_api_probe
  vim.g.numb_api_probe = nil

  -- Proves the command line really opened and ran, so leaving it was exercised.
  assert(probe == 1, "precondition: the command must have run")
  assert(peek:is_active(), "a command line that peeks nothing must not end an API peek")
  assert_cursor(30, "the API peek keeps its target")

  peek:cancel()
  assert_cursor(1, "the API peek still restores its own origin")
end

function Tests.api_disable_cancels_an_active_peek()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local peek = numb.peek(0, 25)
  assert(peek:is_active(), "precondition: the peek was active before disable()")
  numb.disable()

  assert(not peek:is_active(), "disable() deactivates the API handle")
  assert_unpeeked_options(win, "disable()")
  assert_cursor(1, "disable() returns the cursor to the origin")
  assert(vim.w[win].numb_peeking == nil, "disable() clears the peeking flag")

  numb.enable()
end

function Tests.api_peek_while_disabled_returns_an_inactive_handle()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  numb.disable()
  assert(not numb.is_enabled(), "precondition: the plugin is disabled")

  local peek = numb.peek(0, 10)

  assert(peek ~= nil, "peek() while disabled still returns a handle")
  assert(not peek:is_active(), "the handle is inactive while disabled")
  assert_cursor(1, "peek() while disabled does not move the cursor")
  assert(vim.w.numb_peeking == nil, "peek() while disabled does not set the flag")
  assert(peek:cancel() == false, "cancel() on the inactive handle returns false")

  numb.enable()
end

function Tests.api_peek_rejects_bad_arguments()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- A valid call first: without it, calling a missing function would also make
  -- every pcall below return false and the test would pass for the wrong reason.
  numb.peek(0, 10):cancel()
  assert_cursor(1, "precondition: the valid peek was cancelled")

  local cases = {
    { "an invalid window", { 999999, 10 } },
    { "a non-numeric line", { 0, "ten" } },
    { "a non-table range", { 0, 10, { range = "x" } } },
  }
  for _, case in ipairs(cases) do
    local label, args = case[1], case[2]
    local ok = pcall(numb.peek, unpack(args, 1, 3))
    assert(not ok, ("peek() must raise for %s"):format(label))
    assert(not numb.is_peeking(), ("%s must not leave a peek behind"):format(label))
    assert_cursor(1, ("%s must not move the cursor"):format(label))
  end
  assert(vim.tbl_isempty(numb._state.win_states), "rejected calls leave no saved state")
end

function Tests.api_peek_ignores_disable_for_filetype()
  local numb = configure { disable_for_filetype = { "lua" } }
  reset_buffer()
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":10"
  assert(not observed.peeking, "precondition: the filter blocks the command line in this buffer")

  local peek = numb.peek(0, 10)

  assert(peek:is_active(), "the filter must not block an explicit API peek")
  assert_cursor(10, "the API peek moved the cursor")

  peek:cancel()
end

function Tests.api_peek_in_a_window_that_is_not_current()
  local numb = configure()
  reset_buffer()
  local peeked_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(peeked_win, { 1, 0 })
  local current_win = create_split()
  assert(current_win ~= peeked_win, "precondition: the split is a different window")
  assert(vim.api.nvim_get_current_win() ~= peeked_win, "precondition: the peeked window is not current")
  local topline_before = pin_topline(current_win, 40)
  assert(topline_before > 1, ("precondition: the current window is scrolled, topline %d"):format(topline_before))
  local current_line = cursor_of(current_win)
  assert(current_line ~= 30, "precondition: the current window is not already on the target")

  local peek = numb.peek(peeked_win, 30)

  assert(peek:is_active(), "a peek in a background window is active")
  assert(cursor_of(peeked_win) == 30, "the peeked window's cursor moves")
  assert(cursor_of(current_win) == current_line, "the current window's cursor does not move")
  assert(topline_of(current_win) == topline_before, "the current window does not scroll")
  assert(vim.api.nvim_get_current_win() == current_win, "peeking does not change the current window")

  assert(peek:cancel() == true, "cancel() on the background peek returns true")
  assert(cursor_of(peeked_win) == 1, "cancel() restores the background window's cursor")
  assert(vim.w[peeked_win].numb_peeking == nil, "cancel() clears the background window's flag")

  close_other_windows()
end

function Tests.api_peeked_window_closed_mid_peek()
  local numb = configure()
  reset_buffer()
  local peeked_win = create_split()
  local peek = numb.peek(peeked_win, 20)
  assert(peek:is_active(), "precondition: the peek was active before the window closed")

  vim.cmd "wincmd p"
  vim.api.nvim_win_close(peeked_win, true)
  assert(not vim.api.nvim_win_is_valid(peeked_win), "precondition: the window is gone")

  assert(not peek:is_active(), "closing the window deactivates the handle")
  for _, method in ipairs { "update", "accept", "cancel" } do
    local ok, result = pcall(peek[method], peek, 10)
    assert(ok, ("%s() on a closed window must not raise: %s"):format(method, tostring(result)))
    assert(result == false, ("%s() on a closed window returns false, got %s"):format(method, tostring(result)))
  end
  assert(numb._state.win_states[peeked_win] == nil, "no saved state is left for the closed window")

  close_other_windows()
end

function Tests.api_peek_clamps_the_line_to_the_buffer()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local peek = numb.peek(0, 9999)

  assert(peek:is_active(), "an out of range line still peeks")
  assert_cursor(40, "peek(0, 9999) lands on the last line")

  peek:cancel()
end

-- Record every `User NumbPeek` and `User NumbUnpeek` fired while `fn` runs. The
-- augroup is deleted even when `fn` fails, so a broken run leaks no listener.
local function record_peek_events(fn)
  local events = {}
  local group = vim.api.nvim_create_augroup("numb_test_api_events", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "NumbPeek", "NumbUnpeek" },
    callback = function(ev)
      table.insert(events, { name = ev.match, data = ev.data })
    end,
  })
  local ok, err = pcall(fn, events)
  vim.api.nvim_del_augroup_by_id(group)
  if not ok then
    error(err, 0)
  end
end

local function events_named(events, name)
  local matching = {}
  for _, event in ipairs(events) do
    if event.name == name then
      table.insert(matching, event)
    end
  end
  return matching
end

local function clear_events(events)
  for index = #events, 1, -1 do
    events[index] = nil
  end
end

function Tests.api_peek_and_update_fire_numb_peek()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local win = vim.api.nvim_get_current_win()

  record_peek_events(function(events)
    local peek = numb.peek(0, 30)
    local peeked = events_named(events, "NumbPeek")
    assert(
      #events == 1 and #peeked == 1,
      ("peek() fires NumbPeek once and nothing else, got %d events"):format(#events)
    )
    local data = peeked[1].data
    assert(data ~= nil, "NumbPeek carries data")
    assert(
      data.win == win,
      ("data.win is the window handle, not 0: expected %d, got %s"):format(win, tostring(data.win))
    )
    assert(data.line == 30, ("data.line is the target, got %s"):format(tostring(data.line)))
    assert(data.range == nil, "a peek without a range reports no range")

    clear_events(events)
    peek:update(12, { range = { 5, 10 } })
    peeked = events_named(events, "NumbPeek")
    assert(#peeked == 1, ("update() fires NumbPeek once, got %d"):format(#peeked))
    assert(#events_named(events, "NumbUnpeek") == 0, "update() moves the peek without ending it")
    data = peeked[1].data
    assert(data.win == win, "update() reports the same window")
    assert(data.line == 12, ("update() reports the new line, got %s"):format(tostring(data.line)))
    assert(
      data.range and data.range[1] == 5 and data.range[2] == 10,
      ("update() reports the range 5..10, got %s"):format(vim.inspect(data.range))
    )

    peek:cancel()
  end)
end

function Tests.api_cancel_and_accept_fire_numb_unpeek_once()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local win = vim.api.nvim_get_current_win()

  record_peek_events(function(events)
    local cancelled = numb.peek(0, 30)
    clear_events(events)
    cancelled:cancel()
    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#events == 1 and #unpeeked == 1, ("cancel() fires NumbUnpeek exactly once, got %d events"):format(#events))
    assert(unpeeked[1].data.win == win, "NumbUnpeek reports the window handle")
    assert(unpeeked[1].data.accepted == false, "cancel() reports accepted == false")

    clear_events(events)
    assert(cancelled:cancel() == false, "cancel() again on the inactive handle returns false")
    assert(#events == 0, ("an inactive handle fires nothing, got %d events"):format(#events))

    local accepted = numb.peek(0, 30)
    clear_events(events)
    accepted:accept()
    unpeeked = events_named(events, "NumbUnpeek")
    assert(#events == 1 and #unpeeked == 1, ("accept() fires NumbUnpeek exactly once, got %d events"):format(#events))
    assert(unpeeked[1].data.accepted == true, "accept() reports accepted == true")
  end)
end

function Tests.api_takeover_fires_numb_unpeek_for_the_old_peek()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  record_peek_events(function(events)
    local first = numb.peek(0, 10)
    clear_events(events)
    local second = numb.peek(0, 20)

    assert(#events == 2, ("a takeover fires one NumbUnpeek and one NumbPeek, got %d events"):format(#events))
    assert(events[1].name == "NumbUnpeek", "the old peek ends before the new one starts")
    assert(events[1].data.accepted == false, "the superseded peek was not accepted")
    assert(events[2].name == "NumbPeek" and events[2].data.line == 20, "then the new peek starts on line 20")
    assert(not first:is_active(), "precondition: the first handle really was superseded")

    second:cancel()
  end)
end

-- Run `fn` with a `User` listener for `pattern` installed. The augroup is deleted
-- even when `fn` fails, so a re-entrant callback cannot leak into later tests.
local function with_user_listener(pattern, callback, fn)
  local group = vim.api.nvim_create_augroup("numb_test_api_listener", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = pattern, callback = callback })
  local ok, err = pcall(fn)
  vim.api.nvim_del_augroup_by_id(group)
  if not ok then
    error(err, 0)
  end
end

-- Every window that still carries the peeking flag, whoever set it.
local function peeking_windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].numb_peeking ~= nil then
      table.insert(wins, win)
    end
  end
  return wins
end

-- The windows `win_states` holds saved state for, sorted so it compares.
local function saved_windows(numb)
  local wins = vim.tbl_keys(numb._state.win_states)
  table.sort(wins)
  return wins
end

-- How many NumbPeek and NumbUnpeek events each window got, so a peek that was
-- opened and never ended shows up as an imbalance on its own window.
local function event_balance(events)
  local balance = {}
  for _, event in ipairs(events) do
    local win = event.data.win
    balance[win] = balance[win] or { peeks = 0, unpeeks = 0 }
    if event.name == "NumbPeek" then
      balance[win].peeks = balance[win].peeks + 1
    else
      balance[win].unpeeks = balance[win].unpeeks + 1
    end
  end
  return balance
end

function Tests.api_peek_rejects_non_integer_arguments()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()
  -- A valid call first, for the same reason as in api_peek_rejects_bad_arguments.
  numb.peek(0, 10):cancel()
  assert_cursor(1, "precondition: the valid peek was cancelled")
  assert_unpeeked_options(win, "precondition: the valid peek was restored")

  -- Each of these is a number, so the type check alone lets it through. The
  -- window API then truncates or rejects it only after the window was changed.
  local cases = {
    { "a fractional line", { 0, 10.5 } },
    { "a NaN line", { 0, 0 / 0 } },
    { "a fractional window", { 0.5, 3 } },
    { "a fractional range bound", { 0, 3, { range = { 1.5, 4 } } } },
  }
  for _, case in ipairs(cases) do
    local label, args = case[1], case[2]
    local ok = pcall(numb.peek, unpack(args, 1, 3))
    assert(not ok, ("peek() must raise for %s"):format(label))
    assert(
      vim.tbl_isempty(numb._state.win_states),
      ("%s must leave no saved state, found %s"):format(label, vim.inspect(saved_windows(numb)))
    )
    assert(not numb.is_peeking(), ("%s must not leave a peek behind"):format(label))
    assert(vim.w[win].numb_peeking == nil, ("%s must not set the peeking flag"):format(label))
    assert_unpeeked_options(win, label)
    assert_cursor(1, ("%s must not move the cursor"):format(label))
  end
end

function Tests.api_update_rejects_a_non_integer_line_and_keeps_the_peek()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local peek = numb.peek(0, 30)
  assert_cursor(30, "precondition: the peek started at 30")

  local ok = pcall(peek.update, peek, 7.5)

  assert(not ok, "update(7.5) must raise")
  assert(peek:is_active(), "a rejected update() leaves the handle active")
  assert_cursor(30, "a rejected update() leaves the previous peek on screen")
  assert(vim.w[win].numb_peeking == true, "a rejected update() keeps the peeking flag")
  assert(vim.wo[win].number == true, "a rejected update() keeps the peek options")
  assert(vim.wo[win].foldenable == false, "a rejected update() keeps folds disabled")
  local saved = numb._state.win_states[win]
  assert(saved ~= nil, "a rejected update() keeps the saved state")
  assert(saved.cursor[1] == 1, ("the saved origin is still line 1, got %d"):format(saved.cursor[1]))

  assert(peek:cancel() == true, "the peek can still be cancelled after a rejected update()")
  assert_cursor(1, "cancel() after a rejected update() returns to the origin")
  assert_unpeeked_options(win, "cancel() after a rejected update()")
end

-- Expected outcome: `second` is the one live peek. Opening a peek ends whatever
-- is live at the moment it takes over, and that includes a peek a `NumbUnpeek`
-- listener opened while the previous one was being ended. So the nested peek in
-- win_b is ended again, with its own NumbUnpeek, before `second` goes live, and
-- win_b is back to how it was.
function Tests.api_peek_opened_by_a_listener_during_a_takeover_does_not_leak()
  local numb = configure()
  reset_buffer()
  local win_a = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win_a, { 1, 0 })
  set_unpeeked_options()
  local win_b = create_split()
  vim.api.nvim_win_set_cursor(win_b, { 1, 0 })
  set_unpeeked_options()
  vim.api.nvim_set_current_win(win_a)

  local nested
  local listener_runs = 0
  with_user_listener("NumbUnpeek", function()
    listener_runs = listener_runs + 1
    if listener_runs == 1 then
      nested = numb.peek(win_b, 33)
    end
  end, function()
    record_peek_events(function(events)
      local first = numb.peek(win_a, 10)
      local second = numb.peek(win_a, 20)

      assert(nested ~= nil, "precondition: the takeover fired NumbUnpeek and the listener opened a peek")
      local nested_peeks = vim.tbl_filter(function(event)
        return event.data.win == win_b
      end, events_named(events, "NumbPeek"))
      assert(#nested_peeks == 1, "precondition: the nested peek really started in win_b")

      assert(not first:is_active(), "the first peek was superseded")
      assert(second:is_active(), "the outer peek is the live one")
      assert(not nested:is_active(), "the nested peek was ended by the takeover it ran inside")
      assert(cursor_of(win_a) == 20, "the live peek shows line 20")
      assert(cursor_of(win_b) == 1, ("the nested peek's window is restored, cursor on %d"):format(cursor_of(win_b)))
      local flagged = peeking_windows()
      assert(
        #flagged == 1 and flagged[1] == win_a,
        ("only the live peek's window is flagged, found %s"):format(vim.inspect(flagged))
      )
      assert(
        vim.deep_equal(saved_windows(numb), { win_a }),
        ("win_states holds only the live peek, found %s"):format(vim.inspect(saved_windows(numb)))
      )
      assert_unpeeked_options(win_b, "the nested peek's window")

      assert(second:cancel() == true, "the live peek can be cancelled")
      local balance = event_balance(events)
      for win, counts in pairs(balance) do
        assert(
          counts.peeks == counts.unpeeks,
          ("window %d got %d NumbPeek but %d NumbUnpeek"):format(win, counts.peeks, counts.unpeeks)
        )
      end
      assert(#events_named(events, "NumbPeek") == 3, "three peeks started: first, nested and second")
    end)
  end)

  numb.disable()
  numb.enable()
  assert(#peeking_windows() == 0, ("no window keeps the flag, found %s"):format(vim.inspect(peeking_windows())))
  assert(vim.tbl_isempty(numb._state.win_states), "no saved state is left behind")
  assert_unpeeked_options(win_a, "win_a after disable()")
  assert_unpeeked_options(win_b, "win_b after disable()")
  assert(cursor_of(win_a) == 1, "win_a is back on its origin")
  assert(cursor_of(win_b) == 1, "win_b is back on its origin")

  close_other_windows()
end

function Tests.api_peek_opened_by_a_listener_during_disable_does_not_leak()
  local numb = configure()
  reset_buffer()
  local win_a = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win_a, { 1, 0 })
  set_unpeeked_options()
  local win_b = create_split()
  vim.api.nvim_win_set_cursor(win_b, { 1, 0 })
  set_unpeeked_options()
  vim.api.nvim_set_current_win(win_a)

  local nested
  local listener_runs = 0
  with_user_listener("NumbUnpeek", function()
    listener_runs = listener_runs + 1
    if listener_runs == 1 then
      nested = numb.peek(win_b, 33)
    end
  end, function()
    record_peek_events(function(events)
      local peek = numb.peek(win_a, 10)
      clear_events(events)
      numb.disable()

      assert(nested ~= nil, "precondition: disable() fired NumbUnpeek and the listener called peek()")
      assert(not numb.is_enabled(), "precondition: the plugin is disabled")
      assert(not peek:is_active(), "disable() ended the peek")
      assert(not nested:is_active(), "a peek() made while disabling returns an inactive handle")
      assert(
        #events_named(events, "NumbPeek") == 0,
        "a peek() made while disabling peeks nothing, so it fires no NumbPeek"
      )
      assert(#peeking_windows() == 0, ("no window keeps the flag, found %s"):format(vim.inspect(peeking_windows())))
      assert(vim.tbl_isempty(numb._state.win_states), "no saved state is left after disable()")
      assert(cursor_of(win_b) == 1, "win_b was never moved")
      assert_unpeeked_options(win_a, "win_a after disable()")
      assert_unpeeked_options(win_b, "win_b after disable()")
    end)
  end)

  numb.enable()
  close_other_windows()
end

-- A 2-line scratch buffer to switch the peeked window to. The peek origin sits on
-- line 30, which does not exist there.
local function two_line_scratch()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "one", "two" })
  return scratch
end

-- Run `fn` with the global values of the peek-affected options set the way a peek
-- sets them. A buffer shown in a window for the first time takes those global
-- values, so after switching buffers the window looks peeked until numb puts the
-- saved local values back, which is what makes the restore observable. The
-- globals are put back even when `fn` fails.
local function with_peek_like_globals(fn)
  local saved = {}
  local peek_like = { number = true, cursorline = true, relativenumber = false, foldenable = false }
  for option, value in pairs(peek_like) do
    saved[option] = vim.go[option]
    vim.go[option] = value
  end
  local ok, err = pcall(fn)
  for option, value in pairs(saved) do
    vim.go[option] = value
  end
  if not ok then
    error(err, 0)
  end
end

function Tests.api_cancel_after_the_peeked_window_switched_buffer()
  local numb = configure()
  reset_buffer()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 30, 0 })
  set_unpeeked_options()
  local scratch = two_line_scratch()

  with_peek_like_globals(function()
    record_peek_events(function(events)
      local peek = numb.peek(0, 5)
      assert_cursor(5, "precondition: the peek moved the cursor to 5")
      vim.api.nvim_win_set_buf(win, scratch)
      assert(vim.wo[win].number == true, "precondition: the switch shows peek options, so restoring is observable")
      clear_events(events)

      local ok, result = pcall(peek.cancel, peek)

      assert(ok, ("cancel() after a buffer switch must not raise: %s"):format(tostring(result)))
      assert(result == true, ("cancel() after a buffer switch returns true, got %s"):format(tostring(result)))
      local unpeeked = events_named(events, "NumbUnpeek")
      assert(#unpeeked == 1, ("cancel() fires exactly one NumbUnpeek, got %d"):format(#unpeeked))
      assert(unpeeked[1].data.accepted == false, "cancel() reports accepted == false")
      assert_unpeeked_options(win, "cancel() after a buffer switch")
      assert(vim.w[win].numb_peeking == nil, "cancel() clears the peeking flag")
      assert(vim.tbl_isempty(numb._state.win_states), "cancel() leaves no saved state")
      assert(not peek:is_active(), "the handle is inactive after cancel()")
      assert(vim.api.nvim_win_get_buf(win) == scratch, "the window stays on the buffer it was switched to")
      local line = cursor_of(win)
      assert(line >= 1 and line <= 2, ("the cursor is inside the 2-line buffer, got %d"):format(line))
    end)
  end)
end

function Tests.api_accept_after_the_peeked_window_switched_buffer()
  local numb = configure()
  reset_buffer()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(win, { 30, 0 })
  set_unpeeked_options()
  local scratch = two_line_scratch()

  with_peek_like_globals(function()
    record_peek_events(function(events)
      local peek = numb.peek(0, 5)
      assert_cursor(5, "precondition: the peek moved the cursor to 5")
      vim.api.nvim_win_set_buf(win, scratch)
      assert(vim.wo[win].number == true, "precondition: the switch shows peek options, so restoring is observable")
      local line_after_switch = cursor_of(win)
      assert(
        line_after_switch == 1,
        ("precondition: the switch put the cursor on line 1, got %d"):format(line_after_switch)
      )
      clear_events(events)

      local ok, result = pcall(peek.accept, peek)

      assert(ok, ("accept() after a buffer switch must not raise: %s"):format(tostring(result)))
      local unpeeked = events_named(events, "NumbUnpeek")
      assert(#unpeeked == 1, ("accept() fires exactly one NumbUnpeek, got %d"):format(#unpeeked))
      assert(unpeeked[1].data.accepted == true, "accept() reports accepted == true")
      assert_unpeeked_options(win, "accept() after a buffer switch")
      assert(vim.w[win].numb_peeking == nil, "accept() clears the peeking flag")
      assert(vim.tbl_isempty(numb._state.win_states), "accept() leaves no saved state")
      assert(vim.api.nvim_win_get_buf(win) == scratch, "the window stays on the buffer it was switched to")
      -- Line 5 of the old buffer clamps to line 2 here, so a jump into it would
      -- show up as the cursor moving.
      drain_scheduled()
      assert(
        cursor_of(win) == line_after_switch,
        ("accept() must not jump into a buffer it never peeked, cursor moved to %d"):format(cursor_of(win))
      )
    end)
  end)
end

function Tests.api_peek_opened_while_the_command_line_confirms_survives_its_jump()
  local numb = configure()
  reset_buffer()
  drain_scheduled(50)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local cmdline_unpeek
  local api_peek
  with_user_listener("NumbUnpeek", function(ev)
    if cmdline_unpeek == nil then
      cmdline_unpeek = ev.data
      api_peek = numb.peek(0, 5)
    end
  end, function()
    run_cmd ":30\r"
    drain_scheduled()
  end)

  assert(cmdline_unpeek ~= nil, "precondition: the command line peek fired NumbUnpeek")
  assert(cmdline_unpeek.accepted == true, "precondition: the command line peek was accepted")
  assert(cmdline_unpeek.line == 30, ("precondition: the command line peeked 30, got %s"):format(cmdline_unpeek.line))
  assert(api_peek ~= nil, "precondition: the listener opened the API peek")
  assert(api_peek:is_active(), "the API peek opened after the command line is still live")
  assert_cursor(5, "the deferred command line jump must not replace the API peek on screen")

  assert(api_peek:cancel() == true, "the API peek can be cancelled")
  assert_cursor(30, "cancelling returns to where the confirmed command left the cursor")
end

function Tests.api_peeked_window_closed_without_autocommands()
  local numb = configure()
  reset_buffer()
  local peeked_win = create_split()

  record_peek_events(function(events)
    local peek = numb.peek(peeked_win, 20)
    assert(peek:is_active(), "precondition: the peek was active before the window closed")
    vim.cmd "wincmd p"
    clear_events(events)
    vim.cmd(("noautocmd call nvim_win_close(%d, v:true)"):format(peeked_win))
    assert(not vim.api.nvim_win_is_valid(peeked_win), "precondition: the window is gone")
    assert(#events == 0, "precondition: no WinClosed ran, so nothing has ended the peek yet")

    assert(not peek:is_active(), "a window closed without WinClosed deactivates the handle")
    for _, method in ipairs { "update", "accept", "cancel" } do
      local ok, result = pcall(peek[method], peek, 3)
      assert(ok, ("%s() on a silently closed window must not raise: %s"):format(method, tostring(result)))
      assert(
        result == false,
        ("%s() on a silently closed window returns false, got %s"):format(method, tostring(result))
      )
    end
    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#events == 1 and #unpeeked == 1, ("exactly one NumbUnpeek in total, got %d events"):format(#events))
    assert(unpeeked[1].data.accepted == false, "the closed window's peek was not accepted")
    assert(unpeeked[1].data.win == peeked_win, "NumbUnpeek reports the closed window")
    assert(numb._state.win_states[peeked_win] == nil, "no saved state is left for the closed window")
  end)

  close_other_windows()
end

function Tests.api_command_line_fires_peek_events()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local win = vim.api.nvim_get_current_win()

  record_peek_events(function(events)
    run_cmd ":12\r"
    drain_scheduled()
    assert_cursor(12, "precondition: the confirmed command line landed on 12")
    local peeked = events_named(events, "NumbPeek")
    assert(#peeked >= 1, "the command line fires NumbPeek")
    assert(peeked[#peeked].data.line == 12, ("the last NumbPeek is line 12, got %s"):format(peeked[#peeked].data.line))
    assert(peeked[#peeked].data.win == win, "NumbPeek reports the current window")
    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#unpeeked == 1, ("a confirmed command line fires one NumbUnpeek, got %d"):format(#unpeeked))
    assert(unpeeked[1].data.accepted == true, "a confirmed command line reports accepted == true")
    assert(unpeeked[1].data.win == win, "NumbUnpeek reports the current window")

    clear_events(events)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local observed = probe_cmdline ":12"
    assert(observed.peeking, "precondition: the abandoned command line peeked")
    assert(#events_named(events, "NumbPeek") >= 1, "the abandoned command line fired NumbPeek")
    unpeeked = events_named(events, "NumbUnpeek")
    assert(#unpeeked == 1, ("an abandoned command line fires one NumbUnpeek, got %d"):format(#unpeeked))
    assert(unpeeked[1].data.accepted == false, "an abandoned command line reports accepted == false")
    assert_cursor(1, "the abandoned command line returned to the origin")
  end)
end

function Tests.api_closing_a_peeked_window_fires_one_numb_unpeek()
  local numb = configure()
  reset_buffer()
  local peeked_win = create_split()

  record_peek_events(function(events)
    local peek = numb.peek(peeked_win, 20)
    vim.cmd "wincmd p"
    clear_events(events)
    vim.api.nvim_win_close(peeked_win, true)

    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#events == 1 and #unpeeked == 1, ("closing the window fires one NumbUnpeek, got %d events"):format(#events))
    assert(unpeeked[1].data.accepted == false, "a closed window's peek was not accepted")
    assert(unpeeked[1].data.win == peeked_win, "NumbUnpeek reports the closed window")

    peek:update(3)
    peek:accept()
    peek:cancel()
    assert(#events == 1, ("the handle fires nothing more after its window closed, got %d events"):format(#events))
  end)

  close_other_windows()
end

function Tests.api_disable_fires_one_numb_unpeek()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local win = vim.api.nvim_get_current_win()

  record_peek_events(function(events)
    local peek = numb.peek(0, 25)
    assert(peek:is_active(), "precondition: the peek was active before disable()")
    clear_events(events)
    numb.disable()

    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#events == 1 and #unpeeked == 1, ("disable() fires one NumbUnpeek, got %d events"):format(#events))
    assert(unpeeked[1].data.accepted == false, "disable() reports accepted == false")
    assert(unpeeked[1].data.win == win, "NumbUnpeek reports the peeked window")
  end)

  numb.enable()
end

function Tests.api_range_is_drawn_even_with_range_peek_off()
  local numb = configure { range_peek = false }
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local bufnr = vim.api.nvim_get_current_buf()

  local observed = probe_cmdline ":5,10"
  assert(observed.peeking, "precondition: the command line still peeks a range")
  assert(observed.range == nil, "precondition: range_peek = false keeps the command line from highlighting")

  local peek = numb.peek(0, 12, { range = { 5, 10 } })
  local range = highlighted_range(bufnr)
  assert(range ~= nil, "an explicit API range is drawn whatever range_peek says")
  assert(range[1] == 5 and range[2] == 10, ("expected range 5..10, got %d..%d"):format(range[1], range[2]))
  assert(range.count == 1, ("a range must be exactly one extmark, found %d"):format(range.count))

  peek:cancel()
  assert(highlighted_range(bufnr) == nil, "cancel() clears the range")
end

function Tests.api_update_without_a_range_clears_the_highlight()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local bufnr = vim.api.nvim_get_current_buf()

  local peek = numb.peek(0, 12, { range = { 5, 10 } })
  local range = highlighted_range(bufnr)
  assert(range ~= nil, "peek() with opts.range highlights at open time")
  assert(range[1] == 5 and range[2] == 10, ("expected range 5..10, got %d..%d"):format(range[1], range[2]))

  peek:update(12)

  assert(peek:is_active(), "the handle stays active")
  assert_cursor(12, "the target line is still peeked")
  assert(highlighted_range(bufnr) == nil, "update() without opts.range clears the previous range")

  peek:cancel()
end

function Tests.api_accept_in_a_background_window_keeps_the_current_window()
  local numb = configure()
  reset_buffer()
  local peeked_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(peeked_win, { 1, 0 })
  local current_win = create_split()
  vim.api.nvim_win_set_cursor(current_win, { 3, 0 })
  assert(vim.api.nvim_get_current_win() ~= peeked_win, "precondition: the peeked window is not current")

  local peek = numb.peek(peeked_win, 30)
  assert(peek:accept() == true, "accept() on the background peek returns true")

  assert(vim.api.nvim_get_current_win() == current_win, "accept() leaves the current window current")
  assert(cursor_of(peeked_win) == 30, ("the peeked window lands on the target, got %d"):format(cursor_of(peeked_win)))
  assert(cursor_of(current_win) == 3, "the current window's cursor does not move")
  assert(vim.w[peeked_win].numb_peeking == nil, "accept() clears the background window's flag")

  close_other_windows()
end

function Tests.api_event_range_is_a_copy()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local bufnr = vim.api.nvim_get_current_buf()

  local mutations = 0
  with_user_listener("NumbPeek", function(ev)
    if ev.data and ev.data.range then
      ev.data.range[1] = 999
      mutations = mutations + 1
    end
  end, function()
    record_peek_events(function(events)
      local peek = numb.peek(0, 12, { range = { 5, 10 } })
      assert(mutations == 1, "precondition: the listener mutated the range it was handed")
      local range = highlighted_range(bufnr)
      assert(range and range[1] == 5 and range[2] == 10, "a listener's mutation does not change what is drawn")

      clear_events(events)
      peek:update(12, { range = { 5, 10 } })
      local peeked = events_named(events, "NumbPeek")
      assert(#peeked == 1, "precondition: update() fired NumbPeek")
      local reported = peeked[1].data.range
      assert(
        reported and reported[1] == 5 and reported[2] == 10,
        ("the next event reports 5..10, got %s"):format(vim.inspect(reported))
      )

      clear_events(events)
      peek:cancel()
      reported = events_named(events, "NumbUnpeek")[1].data.range
      assert(
        reported and reported[1] == 5 and reported[2] == 10,
        ("NumbUnpeek reports 5..10 despite the mutation, got %s"):format(vim.inspect(reported))
      )
    end)
  end)
end

function Tests.api_handle_does_not_expose_the_command_line_accept()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local peek = numb.peek(0, 10)
  assert(peek:is_active(), "precondition: the handle is live")
  local reachable = peek._accept_after_command
  peek:cancel()

  assert(reachable == nil, "the command line's deferred accept must not be reachable from a public handle")
end

-- A confirmed command line tells listeners it ended only once the Ex command and
-- the landing jump have run. A listener reacting to it therefore acts on the
-- buffer the command left, and anything it opens cannot move the cursor the
-- command's relative address counts from.

-- Run `fn` with `lhs` mapped in Normal mode to `rhs`, and remove the mapping and
-- the handle global the mapping stores even when `fn` fails. The global is
-- cleared through `:lua` so this file itself never names `_G`, which selene
-- rejects; the test body reads the handle back through `numb._state.active`.
local function with_normal_mapping(lhs, rhs, fn)
  vim.cmd(("nnoremap %s %s"):format(lhs, rhs))
  local ok, err = pcall(fn)
  pcall(vim.cmd, "nunmap " .. lhs)
  pcall(vim.cmd, "lua _G.numb_test_p = nil")
  if not ok then
    error(err, 0)
  end
end

-- Feed `keys` with remapping allowed, so a `<Plug>` mapping expands, and wait
-- for Normal mode and for the deferred jump.
local function feed_mapping(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  wait_until_idle()
  drain_scheduled()
end

local function buffer_has_line(bufnr, text)
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), text)
end

function Tests.api_listener_reopening_a_peek_does_not_move_a_relative_command()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local bufnr = vim.api.nvim_get_current_buf()

  local reopened
  with_user_listener("NumbUnpeek", function(ev)
    if reopened == nil and ev.data.accepted then
      reopened = numb.peek(0, 30)
    end
  end, function()
    run_cmd ":+2d\r"
    drain_scheduled()
  end)

  assert(reopened ~= nil, "precondition: the accepted command line fired NumbUnpeek and the listener peeked")
  local count = vim.api.nvim_buf_line_count(bufnr)
  assert(count == 39, ("one line was deleted, the buffer has %d"):format(count))
  assert(not buffer_has_line(bufnr, "line 07"), ":+2d from line 5 deletes line 7")
  assert(buffer_has_line(bufnr, "line 32"), "line 32, 30 + 2, must survive: the peek must not move the address base")
  assert(reopened:is_active(), "the listener's peek is still live after the drain")
  -- The landing on line 7 ran before the listener peeked, so it cannot have
  -- moved the cursor off the peek afterwards.
  local line = cursor_of(reopened.winnr)
  assert(line == 30, ("the listener's peek shows line 30 after the drain, the cursor is on %d"):format(line))

  reopened:cancel()
end

function Tests.api_numb_unpeek_after_the_command_line_sees_the_command_result()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local bufnr = vim.api.nvim_get_current_buf()

  local seen
  with_user_listener("NumbUnpeek", function(ev)
    if seen == nil and ev.data.accepted then
      seen = {
        line_count = vim.api.nvim_buf_line_count(bufnr),
        cursor = vim.api.nvim_win_get_cursor(0)[1],
      }
    end
  end, function()
    run_cmd ":+2d\r"
    drain_scheduled()
  end)

  assert(seen ~= nil, "precondition: the accepted command line fired NumbUnpeek")
  assert(vim.api.nvim_buf_line_count(bufnr) == 39, "precondition: :+2d deleted one line")
  assert(seen.line_count == 39, ("NumbUnpeek must fire after the command ran, it saw %d lines"):format(seen.line_count))
  assert(seen.cursor == 7, ("NumbUnpeek must fire after the landing jump, the cursor was on %d"):format(seen.cursor))
end

function Tests.api_listener_reopening_a_peek_survives_a_shrinking_command()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local bufnr = vim.api.nvim_get_current_buf()

  local reopened
  vim.v.errmsg = ""
  with_user_listener("NumbUnpeek", function(ev)
    if reopened == nil and ev.data.accepted then
      reopened = numb.peek(0, 40)
    end
  end, function()
    run_cmd ":38,40d\r"
    drain_scheduled()
  end)

  assert(reopened ~= nil, "precondition: the accepted command line fired NumbUnpeek and the listener peeked")
  local count = vim.api.nvim_buf_line_count(bufnr)
  assert(count == 37, ("precondition: :38,40d deleted three lines, the buffer has %d"):format(count))
  assert(
    not vim.v.errmsg:find("out of range", 1, true),
    ("the deferred jump must not raise, v:errmsg is %q"):format(vim.v.errmsg)
  )
  assert(reopened:is_active(), "precondition: the listener's peek is live")
  assert(numb._state.active == reopened, "precondition: the listener's peek is the one numb holds")
  local line = cursor_of(reopened.winnr)
  assert(
    line >= 1 and line <= count,
    ("the live peek's cursor must be in the buffer, got %d of %d"):format(line, count)
  )
  reopened:cancel()
end

function Tests.api_peek_accepted_before_the_deferred_jump_is_not_overridden()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  with_normal_mapping(
    "<Plug>(numb-test-acc)",
    [[:30<CR><Cmd>lua _G.numb_test_p = require("numb").peek(0, 5); _G.numb_test_p:accept()<CR>]],
    function()
      record_peek_events(function(events)
        feed_mapping "<Plug>(numb-test-acc)"
        local accepted = vim.tbl_filter(function(event)
          return event.data.line == 5 and event.data.accepted == true
        end, events_named(events, "NumbUnpeek"))
        assert(#accepted == 1, "precondition: the mapping opened the API peek on 5 and accepted it")
        assert(numb._state.active == nil, "precondition: no peek is left live")
        assert_cursor(5, "the accepted API peek is newer than the command line's jump and must win")
      end)
    end
  )
end

function Tests.api_peek_opened_before_the_deferred_jump_orders_the_events()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  with_normal_mapping(
    "<Plug>(numb-test-open)",
    [[:30<CR><Cmd>lua _G.numb_test_p = require("numb").peek(0, 5)<CR>]],
    function()
      record_peek_events(function(events)
        feed_mapping "<Plug>(numb-test-open)"
        local api_peek = numb._state.active
        assert(
          api_peek ~= nil and api_peek:is_active() and api_peek.line == 5,
          "precondition: the mapping left the API peek on 5 live"
        )

        local cmdline_unpeek, api_open
        local cmdline_unpeeks = 0
        for index, event in ipairs(events) do
          if event.name == "NumbUnpeek" and event.data.line == 30 then
            cmdline_unpeeks = cmdline_unpeeks + 1
            cmdline_unpeek = cmdline_unpeek or index
            assert(event.data.accepted == true, "the command line peek was accepted")
          elseif event.name == "NumbPeek" and event.data.line == 5 then
            api_open = api_open or index
          end
        end
        assert(api_open ~= nil, "precondition: the API peek fired NumbPeek")
        assert(
          cmdline_unpeeks == 1,
          ("the command line peek ends exactly once, got %d NumbUnpeek"):format(cmdline_unpeeks)
        )
        assert(
          cmdline_unpeek < api_open,
          ("the old peek's NumbUnpeek (#%d) must come before the new NumbPeek (#%d)"):format(cmdline_unpeek, api_open)
        )
        assert_cursor(5, "the API peek stays on screen")

        assert(api_peek:cancel() == true, "the API peek can be cancelled")
        assert_cursor(30, "cancelling returns to where Vim's own :30 left the cursor")
      end)
    end
  )
end

function Tests.api_listener_that_keeps_reopening_is_stopped()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  -- The cap only keeps a failing implementation from hanging the suite; the
  -- assertion below is that the loop stops long before it.
  local runs = 0
  local ok, err
  with_user_listener("NumbUnpeek", function()
    runs = runs + 1
    if runs < 1000 then
      numb.peek(0, 7)
    end
  end, function()
    numb.peek(0, 10)
    ok, err = pcall(numb.peek, 0, 20)
  end)

  assert(ok == false, ("peek() must raise when a listener keeps reopening, ran the listener %d times"):format(runs))
  assert(
    tostring(err):find("keeps reopening", 1, true),
    ("the error must say a listener keeps reopening, got %s"):format(tostring(err))
  )
  assert(runs < 50, ("the takeover loop must stop early, the listener ran %d times"):format(runs))
  local saved = saved_windows(numb)
  assert(#saved <= 1, ("at most one peek is left live, win_states holds %s"):format(vim.inspect(saved)))
  assert(numb._state.active == nil, "the stopped loop leaves no live peek")
  assert(
    vim.tbl_isempty(numb._state.win_states),
    ("the stopped loop leaves no saved state, win_states holds %s"):format(vim.inspect(saved))
  )

  if numb._state.active then
    numb._state.active:cancel()
  end
  numb.disable()
  numb.enable()
  assert(#peeking_windows() == 0, ("no window keeps the flag, found %s"):format(vim.inspect(peeking_windows())))
  assert(vim.tbl_isempty(numb._state.win_states), "no saved state is left behind")
  assert_unpeeked_options(win, "the window after the loop was stopped")
end

-- The deferred jump carries line numbers in the buffer the command line was
-- typed in. `:{N}b` switches the window to another buffer before it runs, and
-- the number typed is then a buffer number that also reads as a line.
function Tests.buffer_command_does_not_land_on_the_typed_number_in_the_new_buffer()
  configure()
  reset_buffer()
  local buf_a = vim.api.nvim_get_current_buf()
  vim.bo[buf_a].bufhidden = "hide"
  -- Where `:{buf_a}b` would land if the jump ran in buf_a, clamped as numb does.
  local wrong_line = math.min(buf_a, 40)
  local origin = wrong_line == 20 and 21 or 20
  vim.api.nvim_win_set_cursor(0, { origin, 0 })

  reset_buffer()
  local buf_b = vim.api.nvim_get_current_buf()
  vim.bo[buf_b].bufhidden = "hide"
  vim.api.nvim_win_set_cursor(0, { 30, 0 })
  assert(buf_a ~= buf_b, "precondition: two buffers")
  assert(wrong_line ~= origin, "precondition: landing on the typed number is distinguishable from the origin")

  record_peek_events(function(events)
    run_cmd((":%db\r"):format(buf_a))
    drain_scheduled()
    assert(#events_named(events, "NumbPeek") >= 1, ("precondition: :%db was peeked"):format(buf_a))
  end)

  assert(vim.api.nvim_get_current_buf() == buf_a, "precondition: the command switched the window to buf_a")
  assert_cursor(origin, ("buf_a keeps its own cursor, not line %d from the typed number"):format(wrong_line))

  pcall(vim.cmd, "bwipeout! " .. buf_b)
end

function Tests.api_peek_rejects_infinite_arguments()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()
  -- A valid call first, for the same reason as in api_peek_rejects_bad_arguments.
  numb.peek(0, 10):cancel()
  assert_cursor(1, "precondition: the valid peek was cancelled")

  -- An infinity equals its own floor, so it passes the fraction check, and the
  -- clamp then turns it into the first or last line instead of rejecting it.
  local cases = {
    { "an infinite line", { 0, math.huge } },
    { "a negatively infinite line", { 0, -math.huge } },
    { "an infinite range bound", { 0, 3, { range = { 1, math.huge } } } },
  }
  local problems = {}
  for _, case in ipairs(cases) do
    local label, args = case[1], case[2]
    local ok, result = pcall(numb.peek, unpack(args, 1, 3))
    if ok then
      table.insert(problems, label .. " did not raise")
    end
    if not vim.tbl_isempty(numb._state.win_states) or numb.is_peeking() or vim.w[win].numb_peeking ~= nil then
      table.insert(problems, label .. " left a peek behind")
    end
    -- Cleaned up so each case starts from the unpeeked window, whatever the last one did.
    if ok and type(result) == "table" and result:is_active() then
      result:cancel()
    end
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end
  assert(#problems == 0, table.concat(problems, "; "))
  assert_unpeeked_options(win, "after every rejected call")
end

-- The line numbers in the current window's jumplist, oldest first.
local function jumplist_lines()
  local lines = {}
  for _, entry in ipairs(vim.fn.getjumplist()[1]) do
    table.insert(lines, entry.lnum)
  end
  return lines
end

local function index_of(list, value)
  for index, item in ipairs(list) do
    if item == value then
      return index
    end
  end
  return nil
end

-- Two command lines confirmed back to back from one mapping: the second opens its
-- peek before the first one's scheduled landing has run. That landing is older
-- than the new peek, and nothing re-entered a restore, so it still runs first,
-- exactly as it did before the API existed.
local TWO_JUMPS = "<Plug>(numb-test-two)"

function Tests.api_back_to_back_command_lines_keep_both_jumplist_entries()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd "clearjumps"

  with_normal_mapping(TWO_JUMPS, ":10<CR>:20<CR>", function()
    feed_mapping(TWO_JUMPS)
  end)

  assert_cursor(20, "precondition: the mapping ran both command lines")
  -- Vim's own `:N` pushes nothing, so both entries come from numb's landings.
  local jumps = jumplist_lines()
  local from_origin, from_first = index_of(jumps, 1), index_of(jumps, 10)
  assert(from_origin ~= nil, ("the first landing records line 1, the jumplist is %s"):format(vim.inspect(jumps)))
  assert(from_first ~= nil, ("the second landing records line 10, the jumplist is %s"):format(vim.inspect(jumps)))
  assert(from_origin < from_first, ("line 1 is recorded before line 10, the jumplist is %s"):format(vim.inspect(jumps)))

  feedkeys "<C-o>"
  assert_cursor(10, "<C-o> from line 20 goes back to line 10")
  feedkeys "<C-o>"
  assert_cursor(1, "a second <C-o> goes back to line 1")
end

function Tests.api_back_to_back_command_lines_each_end_once_in_order()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  with_normal_mapping(TWO_JUMPS, ":10<CR>:20<CR>", function()
    record_peek_events(function(events)
      feed_mapping(TWO_JUMPS)
      assert(numb._state.active == nil, "precondition: no peek is left live")

      local unpeeks = events_named(events, "NumbUnpeek")
      assert(
        #unpeeks == 2,
        ("each command line peek ends exactly once, got %d NumbUnpeek: %s"):format(#unpeeks, vim.inspect(unpeeks))
      )
      assert(unpeeks[1].data.line == 10 and unpeeks[1].data.accepted == true, "the first to end is :10, accepted")
      assert(unpeeks[2].data.line == 20 and unpeeks[2].data.accepted == true, "the second to end is :20, accepted")

      -- The second command line starts peeking at its first digit, line 2.
      local first_unpeek, second_open
      for index, event in ipairs(events) do
        if event.name == "NumbUnpeek" and event.data.line == 10 then
          first_unpeek = first_unpeek or index
        elseif event.name == "NumbPeek" and (event.data.line == 2 or event.data.line == 20) then
          second_open = second_open or index
        end
      end
      assert(second_open ~= nil, "precondition: the second command line peeked")
      assert(
        first_unpeek < second_open,
        ("the first peek's NumbUnpeek (#%d) comes before the second's NumbPeek (#%d)"):format(first_unpeek, second_open)
      )
    end)
  end)
end

-- Run `fn` with a `User NumbUnpeek` listener that disables the plugin the first
-- time it runs. Returns whether the listener ran.
local function with_disabling_listener(fn)
  local numb = require "numb"
  local ran = false
  with_user_listener("NumbUnpeek", function()
    if not ran then
      ran = true
      numb.disable()
    end
  end, fn)
  return ran
end

-- What is left peeking anywhere, read before any cleanup so a failure reports
-- the state the code under test left.
local function leftover_peek(numb)
  return {
    enabled = numb.is_enabled(),
    active = numb._state.active,
    flagged = peeking_windows(),
    saved = saved_windows(numb),
  }
end

local function assert_nothing_left_peeking(leftover, win, label)
  assert(not leftover.enabled, ("%s: the listener disabled the plugin"):format(label))
  assert(leftover.active == nil, ("%s: no peek is live"):format(label))
  assert(
    #leftover.flagged == 0,
    ("%s: no window keeps the flag, found %s"):format(label, vim.inspect(leftover.flagged))
  )
  assert(#leftover.saved == 0, ("%s: no saved state is left, found %s"):format(label, vim.inspect(leftover.saved)))
  assert_unpeeked_options(win, label)
end

function Tests.api_listener_disabling_during_an_api_takeover_leaves_nothing_peeking()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local first = numb.peek(0, 10)
  assert(first:is_active(), "precondition: the first peek is live")
  local second, second_active, leftover
  local ran = with_disabling_listener(function()
    second = numb.peek(0, 20)
    second_active = second:is_active()
    leftover = leftover_peek(numb)
  end)

  if second_active then
    second:cancel()
  end
  numb.disable()
  numb.enable()

  assert(ran, "precondition: the takeover fired NumbUnpeek and the listener disabled the plugin")
  assert(not second_active, "a peek opened while the plugin was being disabled is inactive")
  assert_nothing_left_peeking(leftover, win, "after the takeover")
  assert_cursor(1, "the window is back on its origin")
end

function Tests.api_listener_disabling_during_a_command_line_takeover_leaves_nothing_peeking()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  set_unpeeked_options()
  local win = vim.api.nvim_get_current_win()

  local api_peek = numb.peek(0, 10)
  assert(api_peek:is_active(), "precondition: the API peek is live")
  local leftover
  local ran = with_disabling_listener(function()
    run_cmd ":20\r"
    drain_scheduled()
    leftover = leftover_peek(numb)
  end)

  numb.disable()
  numb.enable()

  assert(ran, "precondition: the command line took over and the listener disabled the plugin")
  assert(not api_peek:is_active(), "the API peek was ended by the takeover")
  assert_nothing_left_peeking(leftover, win, "after the command line")
end

-- The scenario runs in a child Neovim because the suite cannot see it at all:
-- it is launched from a `+lua` command, which runs before startup finishes, and
-- Vim fires no OptionSet until it has.
local OPTIONSET_DURING_CANCEL = [[
vim.opt.runtimepath:append(vim.fn.getcwd())
local numb = require "numb"
numb.setup { centered_peeking = false }
local lines = {}
for i = 1, 40 do
  lines[i] = ("line %02d"):format(i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.wo.number = false
vim.wo.cursorline = false
vim.wo.relativenumber = true
vim.wo.foldenable = true
local win = vim.api.nvim_get_current_win()

local first = numb.peek(0, 10)
local report = { first_active = first:is_active() }
-- Installed after the peek, whose own options fire OptionSet too, and gated on
-- the cancel so only the restore can trigger it.
local cancelling = false
local nested
vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "number",
  callback = function()
    if cancelling and nested == nil then
      nested = numb.peek(0, 30)
      report.nested_active = nested:is_active()
    end
  end,
})
cancelling = true
local ok, err = pcall(first.cancel, first)
cancelling = false

report.cancel_ok = ok
report.cancel_error = not ok and tostring(err) or nil
report.fired = nested ~= nil
report.still_active = nested ~= nil and nested:is_active()
report.live = numb._state.active ~= nil
report.flagged = vim.w[win].numb_peeking ~= nil
report.saved = vim.tbl_count(numb._state.win_states)
report.options = {
  number = vim.wo[win].number,
  cursorline = vim.wo[win].cursorline,
  relativenumber = vim.wo[win].relativenumber,
  foldenable = vim.wo[win].foldenable,
}
report.cursor = vim.api.nvim_win_get_cursor(win)[1]
io.stdout:write(vim.json.encode(report))
]]

function Tests.api_peek_opened_while_a_cancel_restores_options_is_inactive()
  local script = vim.fn.tempname()
  vim.fn.writefile(vim.split(OPTIONSET_DURING_CANCEL, "\n"), script)
  local output = vim.fn.system { vim.v.progpath, "--headless", "--clean", "-l", script }
  local failed = vim.v.shell_error ~= 0
  vim.fn.delete(script)
  assert(not failed, ("the child Neovim failed: %s"):format(output))
  local decoded, report = pcall(vim.json.decode, output)
  assert(decoded and type(report) == "table", ("the child reported no result: %s"):format(output))

  assert(report.first_active, "precondition: the first peek is live")
  assert(report.cancel_ok, ("cancel() must not raise: %s"):format(tostring(report.cancel_error)))
  assert(report.fired, "precondition: restoring 'number' fired OptionSet and the autocommand called peek()")
  assert(not report.nested_active, "a peek opened while another is being restored gets an inactive handle")
  assert(not report.still_active, "the nested handle is still inactive once cancel() returns")
  assert(not report.live, "no peek is live after cancel()")
  assert(not report.flagged, "the window does not keep the peeking flag")
  assert(report.saved == 0, ("no saved state is left, win_states holds %d"):format(report.saved))
  local expected = { number = false, cursorline = false, relativenumber = true, foldenable = true }
  assert(
    vim.deep_equal(report.options, expected),
    ("the window's options are restored, got %s"):format(vim.inspect(report.options))
  )
  assert(report.cursor == 1, ("the window is back on its origin, the cursor is on %d"):format(report.cursor))
end

-- Runs a child scenario like the one above and returns the table it reported.
local function run_optionset_child(source)
  local script = vim.fn.tempname()
  vim.fn.writefile(vim.split(source, "\n"), script)
  local output = vim.fn.system { vim.v.progpath, "--headless", "--clean", "-l", script }
  local failed = vim.v.shell_error ~= 0
  vim.fn.delete(script)
  assert(not failed, ("the child Neovim failed: %s"):format(output))
  local decoded, report = pcall(vim.json.decode, output)
  assert(decoded and type(report) == "table", ("the child reported no result: %s"):format(output))
  return report
end

-- What both children below report once the call under test has returned.
local OPTIONSET_DISABLE_REPORT = [[
report.call_ok = ok
report.call_error = not ok and tostring(err) or nil
report.enabled = numb.is_enabled()
report.still_active = handle ~= nil and handle:is_active()
report.live = numb._state.active ~= nil
report.flagged = vim.w[win].numb_peeking ~= nil
report.peeking = numb.is_peeking(win)
report.saved = vim.tbl_count(numb._state.win_states)
report.options = {
  number = vim.wo[win].number,
  cursorline = vim.wo[win].cursorline,
  relativenumber = vim.wo[win].relativenumber,
  foldenable = vim.wo[win].foldenable,
}
report.cursor = vim.api.nvim_win_get_cursor(win)[1]
report.events = events
io.stdout:write(vim.json.encode(report))
]]

-- Shared by both children: a buffer, pre-peek options that every peek option
-- differs from, an event log, and an OptionSet listener that disables the
-- plugin once, only while `armed` is set.
local OPTIONSET_DISABLE_SETUP = [[
vim.opt.runtimepath:append(vim.fn.getcwd())
local numb = require "numb"
numb.setup { centered_peeking = false }
local lines = {}
for i = 1, 40 do
  lines[i] = ("line %02d"):format(i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.wo.number = false
vim.wo.cursorline = false
vim.wo.relativenumber = true
vim.wo.foldenable = true
local win = vim.api.nvim_get_current_win()
local report = {}
local events = {}
local recording = false
vim.api.nvim_create_autocmd("User", {
  pattern = { "NumbPeek", "NumbUnpeek" },
  callback = function(event)
    if recording then
      table.insert(events, event.match)
    end
  end,
})
local armed = false
vim.api.nvim_create_autocmd("OptionSet", {
  callback = function()
    if armed and not report.fired then
      report.fired = true
      numb.disable()
      report.disabled_in_listener = not numb.is_enabled()
    end
  end,
})
]]

-- Case A: the listener disables the plugin while peek() is still setting the
-- peek options, so the peek never becomes live.
local OPTIONSET_DISABLE_DURING_OPEN = OPTIONSET_DISABLE_SETUP
  .. [[
recording = true
armed = true
local ok, handle = pcall(numb.peek, 0, 30)
local err = not ok and handle or nil
handle = ok and handle or nil
armed = false
recording = false
]]
  .. OPTIONSET_DISABLE_REPORT

-- Case B: the peek is live, and the listener disables the plugin while
-- update() is moving it.
local OPTIONSET_DISABLE_DURING_UPDATE = OPTIONSET_DISABLE_SETUP
  .. [[
local handle = numb.peek(0, 10)
report.first_active = handle:is_active()
recording = true
armed = true
local ok, moved = pcall(handle.update, handle, 30)
local err = not ok and moved or nil
if ok then
  report.moved = moved
end
armed = false
recording = false
]]
  .. OPTIONSET_DISABLE_REPORT

local function assert_disabled_and_restored(report)
  assert(report.fired, "precondition: a peek option fired OptionSet while the listener was armed")
  assert(report.disabled_in_listener, "precondition: the listener's disable() turned the plugin off")
  assert(report.call_ok, ("the call must not raise: %s"):format(tostring(report.call_error)))
  assert(report.enabled == false, "the plugin stays disabled after the call returns")
  assert(not report.still_active, "the handle is inactive once the call returns")
  assert(not report.live, "no peek is live after the call")
  assert(not report.flagged, "the window does not keep the peeking flag")
  assert(not report.peeking, "is_peeking() reports the window as not peeking")
  assert(report.saved == 0, ("no saved state is left, win_states holds %d"):format(report.saved))
  local expected = { number = false, cursorline = false, relativenumber = true, foldenable = true }
  assert(
    vim.deep_equal(report.options, expected),
    ("the window's options are restored, got %s"):format(vim.inspect(report.options))
  )
  assert(report.cursor == 1, ("the window is back on its origin, the cursor is on %d"):format(report.cursor))
end

-- The peek being opened never became live, so listeners must hear nothing
-- about it: no NumbPeek, and so no NumbUnpeek to match one. This is stricter
-- than a matched NumbPeek/NumbUnpeek pair on purpose.
function Tests.api_peek_opened_while_an_optionset_listener_disables_is_inactive()
  local report = run_optionset_child(OPTIONSET_DISABLE_DURING_OPEN)

  assert_disabled_and_restored(report)
  assert(
    vim.deep_equal(report.events, {}),
    ("a peek that never became live fires no event, got %s"):format(vim.inspect(report.events))
  )
end

function Tests.api_update_while_an_optionset_listener_disables_ends_the_peek()
  local report = run_optionset_child(OPTIONSET_DISABLE_DURING_UPDATE)

  assert(report.first_active, "precondition: the peek is live before update()")
  assert(
    report.moved == false,
    ("update() on a peek ended mid-move returns false, got %s"):format(tostring(report.moved))
  )
  assert_disabled_and_restored(report)
  assert(
    vim.deep_equal(report.events, { "NumbUnpeek" }),
    ("the peek ends with one NumbUnpeek and no NumbPeek follows it, got %s"):format(vim.inspect(report.events))
  )
end

-- Case B again, but the listener waits for the show half of the move: the
-- restore half puts 'number' back to off, so the first OptionSet that leaves it
-- on comes from peeking the new target. The reset then drops the saved state
-- the show had just recorded, and only the write-back at the end of the peek
-- lets update() put the window back.
local OPTIONSET_DISABLE_DURING_UPDATE_SHOW = OPTIONSET_DISABLE_SETUP
  .. [[
local armed_on_show = false
vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "number",
  callback = function()
    if armed_on_show and not report.fired and vim.wo[win].number then
      report.fired = true
      report.fired_on_show = vim.w[win].numb_peeking == nil
      numb.disable()
      report.disabled_in_listener = not numb.is_enabled()
    end
  end,
})
local handle = numb.peek(0, 10)
report.first_active = handle:is_active()
recording = true
armed_on_show = true
local ok, moved = pcall(handle.update, handle, 30)
local err = not ok and moved or nil
if ok then
  report.moved = moved
end
armed_on_show = false
recording = false
]]
  .. OPTIONSET_DISABLE_REPORT

function Tests.api_update_while_an_optionset_listener_disables_on_the_show_half_ends_the_peek()
  local report = run_optionset_child(OPTIONSET_DISABLE_DURING_UPDATE_SHOW)

  assert(report.first_active, "precondition: the peek is live before update()")
  assert(report.fired_on_show, "precondition: the listener fired after the restore half had cleared the flag")
  assert(
    report.moved == false,
    ("update() on a peek ended mid-move returns false, got %s"):format(tostring(report.moved))
  )
  assert_disabled_and_restored(report)
  assert(
    vim.deep_equal(report.events, { "NumbUnpeek" }),
    ("the peek ends with one NumbUnpeek and no NumbPeek follows it, got %s"):format(vim.inspect(report.events))
  )
end

-- The user confirmed the command line before disabling, so the jump they asked
-- for still lands, and listeners still hear the peek end.
function Tests.confirmed_landing_still_runs_after_disable()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd "clearjumps"

  record_peek_events(function(events)
    run_cmd ":40\r"
    assert(#events_named(events, "NumbPeek") >= 1, "precondition: :40 was peeked")
    assert(#events_named(events, "NumbUnpeek") == 0, "precondition: the landing has not run yet when disabling")
    numb.disable()
    drain_scheduled()

    local unpeeks = events_named(events, "NumbUnpeek")
    assert(#unpeeks == 1, ("the confirmed peek ends exactly once, got %d NumbUnpeek"):format(#unpeeks))
    assert(unpeeks[1].data.accepted == true, "it reports accepted == true")
  end)

  numb.enable()
  assert_cursor(40, "the confirmed jump lands")
  local jumps = jumplist_lines()
  assert(index_of(jumps, 1) ~= nil, ("the landing records line 1, the jumplist is %s"):format(vim.inspect(jumps)))
end

-------------------------------------------------------------------------------
-- FLOAT PEEK TESTS
-------------------------------------------------------------------------------

-- With `peek_style = "float"`, or `opts.style = "float"` on `numb.peek()`, the
-- target is shown in a float anchored to the target window, and the target
-- window itself is never touched. "The target window did not change" also holds
-- when nothing was peeked at all, so every test first proves the float opened
-- and shows the target before asserting anything about the window behind it.

-- Every float window, whoever opened it.
local function float_windows()
  local floats = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      table.insert(floats, win)
    end
  end
  return floats
end

-- The one float that is open. Raises unless there is exactly one, so no test can
-- go on to assert things about a float that is not there.
local function the_float(label)
  local floats = float_windows()
  assert(#floats == 1, ("%s: expected exactly one float, found %d"):format(label, #floats))
  return floats[1]
end

local function assert_no_float(label)
  local floats = float_windows()
  assert(#floats == 0, ("%s: expected no float, found %d"):format(label, #floats))
end

-- Close any float a failed assertion left open, so it cannot leak into a later
-- test. Passing tests close their own float and assert that they did.
local function close_floats()
  for _, win in ipairs(float_windows()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

-- Run `fn` with the global value of option `name` set to `value`, and put the
-- old value back even when `fn` fails.
local function with_global_option(name, value, fn)
  local saved = vim.go[name]
  vim.go[name] = value
  local ok, err = pcall(fn)
  close_floats()
  vim.go[name] = saved
  if not ok then
    error(err, 0)
  end
end

-- 'winborder' exists from Neovim 0.11 on. `fn` gets whether it could be set, so
-- a test can skip only the assertions that need it and still run the rest.
local function with_winborder(value, fn)
  if vim.fn.exists "+winborder" == 1 then
    with_global_option("winborder", value, function()
      fn(true)
    end)
  else
    fn(false)
  end
end

local function note_skipped(what)
  vim.api.nvim_echo({ { ("[numb test] skipped on this Neovim: %s"):format(what), "WarningMsg" } }, false, {})
end

-- The float's title as plain text, "" when it has none. `nvim_win_get_config`
-- reports a title as a list of `{ text, hl }` chunks.
local function title_of(win)
  local title = vim.api.nvim_win_get_config(win).title
  if title == nil then
    return ""
  end
  if type(title) == "string" then
    return title
  end
  local parts = {}
  for _, chunk in ipairs(title) do
    table.insert(parts, type(chunk) == "table" and chunk[1] or chunk)
  end
  return table.concat(parts)
end

local NAMED_BORDERS = {
  none = { "", "", "", "", "", "", "", "" },
  single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
  rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
}

-- The float's border as its eight characters, clockwise from the top left
-- corner, whichever shape `nvim_win_get_config` reports it in: nil or "none"
-- for no border (it varies by version), a name, or a list with or without
-- highlight groups.
local function border_of(win)
  local border = vim.api.nvim_win_get_config(win).border
  if border == nil then
    return NAMED_BORDERS.none
  end
  if type(border) == "string" then
    return NAMED_BORDERS[border] or { border }
  end
  local chars = {}
  for index = 1, 8 do
    local char = border[(index - 1) % #border + 1]
    chars[index] = type(char) == "table" and char[1] or char
  end
  return chars
end

-- Where the float's frame, border included, sits in the target window: "top"
-- when flush with its top edge, "bottom" when flush with its bottom edge.
local function edge_of(float, target)
  local config = vim.api.nvim_win_get_config(float)
  local border = border_of(float)
  local frame_height = vim.api.nvim_win_get_height(float) + (border[2] ~= "" and 1 or 0) + (border[6] ~= "" and 1 or 0)
  local frame_top = config.row
  if config.anchor and config.anchor:sub(1, 1) == "S" then
    frame_top = config.row - frame_height
  end
  if frame_top == 0 then
    return "top", frame_height
  end
  if frame_top + frame_height == vim.api.nvim_win_get_height(target) then
    return "bottom", frame_height
  end
  return ("row %s"):format(tostring(frame_top)), frame_height
end

local FLOAT_TARGET = 240
local TALL_BUFFER_LINES = 500

-- A tall buffer with the target window scrolled to the top, its cursor on line 5
-- and its peek options set the opposite way a peek sets them, so any change the
-- float strategy made to the target window would show. FLOAT_TARGET is far off
-- screen, which is what a float is for.
local function float_scene()
  reset_tall_buffer()
  local win = vim.api.nvim_get_current_win()
  set_unpeeked_options()
  local topline = pin_topline(win, 1)
  vim.api.nvim_win_set_cursor(win, { 5, 0 })
  assert(topline_of(win) == topline, "precondition: moving the cursor to line 5 did not scroll")
  local last_visible = vim.api.nvim_win_call(win, function()
    return vim.fn.line "w$"
  end)
  assert(last_visible < FLOAT_TARGET, ("precondition: line %d is off screen"):format(FLOAT_TARGET))
  return {
    win = win,
    bufnr = vim.api.nvim_get_current_buf(),
    topline = topline,
    cursor = 5,
    last_visible = last_visible,
  }
end

local function assert_target_untouched(scene, label)
  assert_unpeeked_options(scene.win, label)
  assert(
    cursor_of(scene.win) == scene.cursor,
    ("%s: the target window's cursor must stay on %d, it is on %d"):format(label, scene.cursor, cursor_of(scene.win))
  )
  assert(
    topline_of(scene.win) == scene.topline,
    ("%s: the target window must not scroll, topline %d became %d"):format(label, scene.topline, topline_of(scene.win))
  )
  assert(vim.api.nvim_win_get_buf(scene.win) == scene.bufnr, ("%s: the target window keeps its buffer"):format(label))
end

-- The float shows the target buffer with its cursor on `line`, and `line` sits
-- mid float whatever centered_peeking says: configure() turns it off.
local function assert_float_shows(scene, float, line, label)
  assert(vim.api.nvim_win_get_buf(float) == scene.bufnr, ("%s: the float must show the target buffer"):format(label))
  assert(
    cursor_of(float) == line,
    ("%s: the float's cursor must be on %d, it is on %d"):format(label, line, cursor_of(float))
  )
  local height = vim.api.nvim_win_get_height(float)
  assert(height >= 3, ("%s: the float must be at least 3 rows, it is %d"):format(label, height))
  local offset = line - topline_of(float)
  local middle = math.floor(height / 2)
  assert(
    math.abs(offset - middle) <= 1,
    ("%s: line %d must sit mid float: topline %d, height %d, offset %d, expected about %d"):format(
      label,
      line,
      topline_of(float),
      height,
      offset,
      middle
    )
  )
end

function Tests.float_peek_shows_the_target_centered_in_a_float()
  local numb = configure()
  local scene = float_scene()
  assert_no_float "precondition: nothing is floating before the peek"

  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })

  assert(peek:is_active(), "a float peek is active")
  local float = the_float "peek(0, 240, { style = 'float' })"
  local config = vim.api.nvim_win_get_config(float)
  assert(
    config.relative == "win" and config.win == scene.win,
    ("the float is anchored to the target window, got relative %q, win %s"):format(
      config.relative,
      tostring(config.win)
    )
  )
  assert(config.focusable == false, "the float is not focusable")
  assert(
    vim.api.nvim_win_get_width(float) == vim.api.nvim_win_get_width(scene.win),
    ("the float spans the target window: width %d, expected %d"):format(
      vim.api.nvim_win_get_width(float),
      vim.api.nvim_win_get_width(scene.win)
    )
  )
  assert_float_shows(scene, float, FLOAT_TARGET, "the float")
  assert(vim.api.nvim_get_current_win() == scene.win, "the float does not take focus")

  peek:cancel()
end

function Tests.float_peek_leaves_the_target_window_untouched()
  local numb = configure()
  local scene = float_scene()

  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })

  local float = the_float "precondition: the float peek opened a float"
  assert_float_shows(scene, float, FLOAT_TARGET, "precondition")
  assert_target_untouched(scene, "during a float peek")
  assert(vim.w[scene.win].numb_peeking == true, "the target window carries the peeking flag")
  assert(numb.is_peeking(scene.win), "is_peeking() reports the target window")
  assert(numb.is_peeking(), "is_peeking() reports the current window, which is the target")
  assert(vim.tbl_isempty(numb._state.win_states), "a float peek saves no window state")
  -- The peek options go on the float instead.
  assert(vim.wo[float].number == true, "show_numbers applies to the float")
  assert(vim.wo[float].cursorline == true, "show_cursorline applies to the float")
  assert(vim.wo[float].relativenumber == false, "hide_relativenumbers applies to the float")
  assert(vim.wo[float].foldenable == false, "folds are disabled in the float")

  peek:cancel()
end

function Tests.float_peek_cancel_closes_the_float()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  the_float "precondition: the float peek opened a float"

  local cancelled = peek:cancel()

  assert(cancelled == true, ("cancel() on a float peek returns true, got %s"):format(tostring(cancelled)))
  assert_no_float "cancel() closes the float"
  assert_target_untouched(scene, "after cancel()")
  assert(vim.w[scene.win].numb_peeking == nil, "cancel() clears the peeking flag")
  assert(not numb.is_peeking(scene.win), "is_peeking() is false after cancel()")
  assert(not peek:is_active(), "the handle is inactive after cancel()")
end

function Tests.float_peek_accept_lands_in_the_target_window()
  local numb = configure()
  local scene = float_scene()
  drain_scheduled(50)
  vim.cmd "clearjumps"
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  the_float "precondition: the float peek opened a float"
  assert(cursor_of(scene.win) == scene.cursor, "precondition: the target window has not moved yet")

  local accepted = peek:accept()

  assert(accepted == true, ("accept() on a float peek returns true, got %s"):format(tostring(accepted)))
  assert_no_float "accept() closes the float"
  assert(cursor_of(scene.win) == FLOAT_TARGET, ("accept() lands on %d at once"):format(FLOAT_TARGET))
  assert_unpeeked_options(scene.win, "accept() leaves the target window's options alone")
  assert(vim.w[scene.win].numb_peeking == nil, "accept() clears the peeking flag")
  assert(not peek:is_active(), "the handle is inactive after accept()")

  drain_scheduled()
  assert(cursor_of(scene.win) == FLOAT_TARGET, "nothing deferred moves the cursor after accept()")
  vim.cmd "normal! \15"
  assert(cursor_of(scene.win) == scene.cursor, "<C-o> after accept() returns to the origin")
end

-- Records, at every CmdlineChanged, what the float strategy looks like from
-- outside: the command line, how many floats are open and where the target
-- window's cursor is. Installed after numb's own handler, so it runs second.
local function record_cmdline_snapshots(win, fn)
  local snapshots = {}
  local group = vim.api.nvim_create_augroup("numb_test_float_snapshots", { clear = true })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    pattern = ":",
    callback = function()
      table.insert(snapshots, {
        cmdline = vim.fn.getcmdline(),
        floats = #float_windows(),
        cursor = cursor_of(win),
        number = vim.wo[win].number,
        range = highlighted_range(vim.api.nvim_win_get_buf(win)),
      })
    end,
  })
  local ok, err = pcall(fn, snapshots)
  vim.api.nvim_del_augroup_by_id(group)
  if not ok then
    error(err, 0)
  end
end

local function last_snapshot(snapshots, cmdline)
  assert(#snapshots > 0, ("no CmdlineChanged was observed for %q"):format(cmdline))
  local last = snapshots[#snapshots]
  assert(last.cmdline == cmdline, ("the last command line observed was %q, expected %q"):format(last.cmdline, cmdline))
  return last
end

function Tests.float_peek_style_confirmed_command_line_lands_after_the_command()
  local numb = configure { peek_style = "float" }
  local scene = float_scene()
  drain_scheduled(50)
  vim.cmd "clearjumps"

  record_cmdline_snapshots(scene.win, function(snapshots)
    run_cmd ":240\r"
    drain_scheduled()
    local typed = last_snapshot(snapshots, "240")
    assert(typed.floats == 1, ("typing :240 shows the target in one float, found %d"):format(typed.floats))
    assert(typed.cursor == scene.cursor, "typing :240 does not move the target window")
  end)

  assert(cursor_of(scene.win) == FLOAT_TARGET, "the confirmed :240 lands on line 240")
  assert_no_float "no float is left once the command ran"
  assert(not numb.is_peeking(scene.win), "nothing is peeking after the command")
  vim.cmd "normal! \15"
  assert(cursor_of(scene.win) == scene.cursor, "<C-o> after the confirmed :240 returns to the origin")
end

function Tests.float_peek_style_abandoned_command_line_closes_the_float()
  local numb = configure { peek_style = "float" }
  local scene = float_scene()

  record_cmdline_snapshots(scene.win, function(snapshots)
    run_cmd ":240<C-c>"
    local typed = last_snapshot(snapshots, "240")
    assert(typed.floats == 1, ("typing :240 shows the target in one float, found %d"):format(typed.floats))
  end)

  assert_no_float "abandoning the command line closes the float"
  assert_target_untouched(scene, "after <C-c>")
  assert(not numb.is_peeking(scene.win), "nothing is peeking after <C-c>")
end

function Tests.float_peek_highlights_the_range_in_the_float()
  local numb = configure()
  local scene = float_scene()
  assert(highlighted_range(scene.bufnr) == nil, "precondition: nothing is highlighted before the peek")

  local peek = numb.peek(0, 235, { style = "float", range = { 235, 245 } })

  local float = the_float "precondition: the ranged float peek opened a float"
  assert_float_shows(scene, float, 235, "the ranged float")
  local range = highlighted_range(scene.bufnr)
  assert(range ~= nil, "a float peek with a range highlights it")
  assert(range.count == 1, ("a range is exactly one extmark, found %d"):format(range.count))
  assert(range[1] == 235 and range[2] == 245, ("expected range 235..245, got %d..%d"):format(range[1], range[2]))
  assert_target_untouched(scene, "a ranged float peek")

  peek:cancel()
  assert(highlighted_range(scene.bufnr) == nil, "cancel() clears the range highlight")
end

function Tests.float_peek_style_command_line_range_is_highlighted()
  configure { peek_style = "float" }
  local scene = float_scene()

  record_cmdline_snapshots(scene.win, function(snapshots)
    run_cmd ":235,245<C-c>"
    local typed = last_snapshot(snapshots, "235,245")
    assert(typed.floats == 1, ("typing :235,245 shows one float, found %d"):format(typed.floats))
    assert(
      typed.range and typed.range[1] == 235 and typed.range[2] == 245,
      ("typing :235,245 highlights 235..245, got %s"):format(vim.inspect(typed.range))
    )
    assert(typed.cursor == scene.cursor, "typing a range does not move the target window")
  end)

  assert(highlighted_range(scene.bufnr) == nil, "abandoning the command line clears the range")
  assert_no_float "abandoning the command line closes the float"
end

function Tests.float_height_as_a_fraction_and_as_rows()
  local heights = {}
  for _, case in ipairs { { height = 0.5 }, { height = 6 } } do
    local numb = configure { float = { height = case.height } }
    local scene = float_scene()
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float(("height = %s"):format(case.height))
    local height = vim.api.nvim_win_get_height(float)
    local target_height = vim.api.nvim_win_get_height(scene.win)
    peek:cancel()
    if case.height < 1 then
      assert(
        math.abs(height - target_height * case.height) <= 1,
        ("height = 0.5 is half the target window (%d rows), got %d rows"):format(target_height, height)
      )
    else
      assert(height == case.height, ("height = 6 is 6 rows, got %d"):format(height))
    end
    table.insert(heights, height)
  end
  -- A float of one fixed size would satisfy either case alone on some screen.
  assert(heights[1] ~= heights[2], ("the two settings must give different heights, both gave %d"):format(heights[1]))
end

function Tests.float_position_top_bottom_and_auto()
  -- { position, cursor near the bottom of the view?, expected edge }
  local cases = {
    { "top", false, "top" },
    { "bottom", false, "bottom" },
    -- Honoured even though the strip then covers the cursor line.
    { "bottom", true, "bottom" },
    { "auto", false, "bottom" },
    { "auto", true, "top" },
  }
  for _, case in ipairs(cases) do
    local position, cursor_low, expected = case[1], case[2], case[3]
    local label = ("position = %q with the cursor %s"):format(position, cursor_low and "low" or "high")
    local numb = configure { float = { position = position } }
    local scene = float_scene()
    if cursor_low then
      vim.api.nvim_win_set_cursor(scene.win, { scene.last_visible - 1, 0 })
      assert(
        topline_of(scene.win) == scene.topline,
        ("precondition, %s: the cursor moved without scrolling"):format(label)
      )
    end
    local cursor_row = vim.api.nvim_win_call(scene.win, vim.fn.winline)
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float(label)
    local edge, frame_height = edge_of(float, scene.win)
    local target_height = vim.api.nvim_win_get_height(scene.win)
    peek:cancel()

    -- Whether a strip on the bottom edge would cover the cursor line is what
    -- "auto" decides on, so each case proves it tests the side it claims to.
    local covered = cursor_row > target_height - frame_height
    assert(
      covered == cursor_low,
      ("precondition, %s: cursor on row %d of %d, frame %d rows, covered %s"):format(
        label,
        cursor_row,
        target_height,
        frame_height,
        tostring(covered)
      )
    )
    assert(edge == expected, ("%s: the float sits at the %s, expected %s"):format(label, edge, expected))
  end
end

-- Neovim works out whether a window has room for a winbar only when 'winbar'
-- is set on it or globally, or when the window is entered. A float copies the
-- local value of the window it opens from without that step, so an inherited
-- winbar stays hidden until any of those happens, and a winbar plugin setting
-- the global value makes it appear. Setting the global value to itself forces
-- that step here, so what is checked is what the user would end up seeing.
local function refresh_winbars()
  vim.go.winbar = vim.go.winbar
end

function Tests.float_clears_a_window_local_winbar()
  -- Floats never draw the global 'winbar', but a local one (what winbar
  -- plugins set) is copied to a float and would take a row of the strip.
  local numb = configure()
  local scene = float_scene()
  local saved = vim.api.nvim_get_option_value("winbar", { win = scene.win, scope = "local" })
  vim.api.nvim_set_option_value("winbar", "numb test winbar", { win = scene.win, scope = "local" })
  local ok, err = pcall(function()
    local raw = vim.api.nvim_open_win(scene.bufnr, false, {
      relative = "win",
      win = scene.win,
      row = 0,
      col = 0,
      width = 20,
      height = 3,
    })
    refresh_winbars()
    local raw_local = vim.api.nvim_get_option_value("winbar", { win = raw, scope = "local" })
    local raw_draws = vim.fn.getwininfo(raw)[1].winbar
    vim.api.nvim_win_close(raw, true)
    assert(
      raw_local == "numb test winbar" and raw_draws == 1,
      ("precondition: a plain float opened from the window inherits and draws its winbar, got %q, drawn %d"):format(
        raw_local,
        raw_draws
      )
    )

    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"
    refresh_winbars()
    local float_local = vim.api.nvim_get_option_value("winbar", { win = float, scope = "local" })
    local float_draws = vim.fn.getwininfo(float)[1].winbar
    peek:cancel()
    assert(float_local == "", ("the float must clear its local winbar, it holds %q"):format(float_local))
    assert(float_draws == 0, "the float must not draw a winbar")
  end)
  close_floats()
  vim.api.nvim_set_option_value("winbar", saved, { win = scene.win, scope = "local" })
  if not ok then
    error(err, 0)
  end
end

function Tests.float_default_border_is_a_top_edge_with_a_title()
  local numb = configure()
  with_winborder("", function()
    local scene = float_scene()
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"

    local border = border_of(float)
    assert(border[2] ~= "", ("the default border has a top edge, got %s"):format(vim.inspect(border)))
    for _, index in ipairs { 4, 5, 6, 7, 8 } do
      assert(border[index] == "", ("the default border has only a top edge, got %s"):format(vim.inspect(border)))
    end
    local expected = ("%d/%d"):format(FLOAT_TARGET, TALL_BUFFER_LINES)
    assert(
      title_of(float):find(expected, 1, true) ~= nil,
      ("the title shows %q, got %q"):format(expected, title_of(float))
    )

    peek:update(300)
    assert(
      title_of(float):find("300/500", 1, true) ~= nil,
      ("update() retitles the float, got %q"):format(title_of(float))
    )
    assert_target_untouched(scene, "a float with the default border")
    peek:cancel()
  end)
end

function Tests.float_respects_winborder_and_shows_no_title_without_a_top_edge()
  local numb = configure()
  with_winborder("rounded", function(applied)
    local scene = float_scene()
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "winborder = rounded"
    if applied then
      local border = border_of(float)
      assert(border[1] == "╭", ("the user's winborder is used, got %s"):format(vim.inspect(border)))
      assert(
        title_of(float):find(("%d/%d"):format(FLOAT_TARGET, TALL_BUFFER_LINES), 1, true) ~= nil,
        ("a rounded border has a top edge, so it keeps the title, got %q"):format(title_of(float))
      )
    else
      note_skipped "'winborder' does not exist, so it cannot be respected"
    end
    assert_target_untouched(scene, "a float under winborder = rounded")
    peek:cancel()
  end)

  with_winborder("none", function(applied)
    if not applied then
      note_skipped "'winborder' does not exist, so winborder = none cannot be set"
      return
    end
    float_scene()
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "winborder = none"
    assert(
      border_of(float)[2] == "",
      ("winborder = none gives no top edge, got %s"):format(vim.inspect(border_of(float)))
    )
    assert(title_of(float) == "", ("a border without a top edge carries no title, got %q"):format(title_of(float)))
    peek:cancel()
  end)
end

function Tests.float_win_config_result_wins()
  local received
  local numb = configure {
    float = {
      win_config = function(config)
        received = vim.deepcopy(config)
        config.border = "single"
        config.row = 1
        return config
      end,
    },
  }
  -- A winborder set by the user loses to win_config as well.
  with_winborder("rounded", function()
    local scene = float_scene()
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"

    assert(type(received) == "table", "win_config is called with the computed config")
    assert(
      received.relative == "win" and received.win == scene.win,
      ("win_config receives the config numb computed, got %s"):format(vim.inspect(received))
    )
    assert(border_of(float)[1] == "┌", ("win_config's border wins, got %s"):format(vim.inspect(border_of(float))))
    assert(
      vim.api.nvim_win_get_config(float).row == 1,
      ("win_config's row wins, got %s"):format(tostring(vim.api.nvim_win_get_config(float).row))
    )
    peek:cancel()
  end)
end

function Tests.float_peek_fires_no_window_or_buffer_autocommands()
  local numb = configure()
  local scene = float_scene()
  local fired = {}
  local group = vim.api.nvim_create_augroup("numb_test_float_autocmds", { clear = true })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "WinNew", "BufWinEnter" }, {
    group = group,
    callback = function(event)
      table.insert(fired, event.event)
    end,
  })
  local ok, err = pcall(function()
    -- The counter has to see an ordinary window being opened, or staying at 0
    -- below proves nothing. A tab page leaves the target window's size alone.
    vim.cmd "tabnew"
    vim.cmd "tabclose"
    assert(#fired > 0, "precondition: opening a tab page fires the counted autocommands")
    assert(vim.api.nvim_get_current_win() == scene.win, "precondition: back in the target window")
    clear_events(fired)

    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    the_float "precondition: the float peek opened a float"
    peek:update(300)
    assert(cursor_of(the_float "precondition: the float moved") == 300, "precondition: update() moved the float")
    peek:cancel()
    assert_no_float "precondition: cancel() closed the float"
  end)
  vim.api.nvim_del_augroup_by_id(group)
  if not ok then
    error(err, 0)
  end
  assert(#fired == 0, ("the float must open, move and close without autocommands, got %s"):format(vim.inspect(fired)))
end

function Tests.float_peek_events_report_the_target_window()
  local numb = configure()
  local scene = float_scene()

  record_peek_events(function(events)
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"
    local peeked = events_named(events, "NumbPeek")
    assert(#events == 1 and #peeked == 1, ("a float peek fires NumbPeek once, got %d events"):format(#events))
    local data = peeked[1].data
    assert(data.win == scene.win, ("data.win is the target window, got %s"):format(tostring(data.win)))
    assert(data.line == FLOAT_TARGET, ("data.line is the target line, got %s"):format(tostring(data.line)))
    assert(data.float_win == float, ("data.float_win is the float, got %s"):format(tostring(data.float_win)))

    clear_events(events)
    peek:cancel()
    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#events == 1 and #unpeeked == 1, ("cancel() fires NumbUnpeek once, got %d events"):format(#events))
    assert(unpeeked[1].data.win == scene.win, "NumbUnpeek reports the target window")
    assert(unpeeked[1].data.accepted == false, "cancel() reports accepted == false")
  end)
end

function Tests.float_auto_switches_strategy_within_one_handle()
  local numb = configure()
  local scene = float_scene()

  record_peek_events(function(events)
    local peek = numb.peek(0, 2, { style = "auto" })
    assert(peek:is_active(), "an auto peek is active")
    assert_no_float "auto peeks an on-screen line in place"
    assert(cursor_of(scene.win) == 2, "in place, the target window's cursor moves to line 2")
    assert(vim.wo[scene.win].number == true, "in place, the target window gets the peek options")
    assert(#events_named(events, "NumbPeek") == 1, "the first peek fires one NumbPeek")

    clear_events(events)
    assert(peek:update(FLOAT_TARGET) == true, "update() to an off-screen line returns true")
    local float = the_float "auto peeks an off-screen line in a float"
    assert_float_shows(scene, float, FLOAT_TARGET, "switched to a float")
    assert_target_untouched(scene, "switching to a float puts the target window back first")
    assert(vim.w[scene.win].numb_peeking == true, "the target window stays flagged across the switch")
    assert(
      #events_named(events, "NumbPeek") == 1 and #events_named(events, "NumbUnpeek") == 0,
      ("switching to a float is one NumbPeek and no NumbUnpeek, got %s"):format(vim.inspect(events))
    )

    clear_events(events)
    assert(peek:update(2) == true, "update() back to an on-screen line returns true")
    assert_no_float "auto back on an on-screen line closes the float"
    assert(cursor_of(scene.win) == 2, "back in place, the target window's cursor is on line 2")
    assert(vim.wo[scene.win].number == true, "back in place, the target window has the peek options again")
    assert(
      #events_named(events, "NumbPeek") == 1 and #events_named(events, "NumbUnpeek") == 0,
      ("switching back in place is one NumbPeek and no NumbUnpeek, got %s"):format(vim.inspect(events))
    )

    clear_events(events)
    peek:cancel()
    assert(
      #events == 1 and #events_named(events, "NumbUnpeek") == 1,
      ("cancel() after the switches fires one NumbUnpeek, got %s"):format(vim.inspect(events))
    )
  end)

  assert_no_float "nothing floats after cancel()"
  assert_target_untouched(scene, "cancel() after the switches")
  assert(vim.w[scene.win].numb_peeking == nil, "cancel() clears the peeking flag")
  assert(vim.tbl_isempty(numb._state.win_states), "no saved state is left")
end

function Tests.float_auto_peek_style_switches_while_typing()
  configure { peek_style = "auto" }
  local scene = float_scene()
  assert(scene.last_visible < 24, "precondition: line 24 is off screen, so :24 floats too")

  record_cmdline_snapshots(scene.win, function(snapshots)
    -- "2", "24", "240", "24", "2": one command line peek throughout.
    run_cmd ":240<BS><BS><C-c>"
    local seen = vim.tbl_map(function(snapshot)
      return snapshot.cmdline
    end, snapshots)
    assert(
      vim.deep_equal(seen, { "2", "24", "240", "24", "2" }),
      ("precondition: the command lines typed, got %s"):format(vim.inspect(seen))
    )
    local first, far, last = snapshots[1], snapshots[3], snapshots[5]
    assert(first.floats == 0 and first.cursor == 2, (":2 peeks in place, got %s"):format(vim.inspect(first)))
    assert(
      far.floats == 1 and far.cursor == scene.cursor and far.number == false,
      (":240 floats and leaves the target window alone, got %s"):format(vim.inspect(far))
    )
    assert(last.floats == 0 and last.cursor == 2, ("back to :2 peeks in place again, got %s"):format(vim.inspect(last)))
  end)

  assert_no_float "abandoning the command line closes any float"
  assert_target_untouched(scene, "after <C-c>")
end

function Tests.float_closed_by_someone_else_ends_the_peek()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"

  record_peek_events(function(events)
    vim.api.nvim_win_close(float, true)
    assert(not vim.api.nvim_win_is_valid(float), "precondition: the float is gone")

    assert(not peek:is_active(), "closing the float deactivates the handle")
    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#events == 1 and #unpeeked == 1, ("closing the float fires one NumbUnpeek, got %d events"):format(#events))
    assert(unpeeked[1].data.win == scene.win, "NumbUnpeek reports the target window")
    for _, method in ipairs { "update", "accept", "cancel" } do
      local ok, result = pcall(peek[method], peek, 10)
      assert(ok, ("%s() after the float closed must not raise: %s"):format(method, tostring(result)))
      assert(result == false, ("%s() after the float closed returns false, got %s"):format(method, tostring(result)))
    end
    assert(#events == 1, ("nothing more fires once the peek ended, got %d events"):format(#events))
  end)

  assert_no_float "no other float was opened"
  assert(vim.w[scene.win].numb_peeking == nil, "the target window loses the peeking flag")
  assert(not numb.is_peeking(scene.win), "is_peeking() is false once the float closed")
  assert(highlighted_range(scene.bufnr) == nil, "no range is left highlighted")
  assert_target_untouched(scene, "after the float was closed")
end

function Tests.float_target_window_closed_closes_the_float()
  local numb = configure()
  float_scene()
  local target = create_split()
  local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"
  assert(vim.api.nvim_win_get_config(float).win == target, "precondition: the float is anchored to the split")

  record_peek_events(function(events)
    vim.cmd "wincmd p"
    vim.api.nvim_win_close(target, true)
    assert(not vim.api.nvim_win_is_valid(target), "precondition: the target window is gone")

    -- Neovim keeps a float whose anchor window closed, so numb has to close it.
    assert_no_float "closing the target window closes the float"
    assert(not peek:is_active(), "closing the target window deactivates the handle")
    assert(
      #events_named(events, "NumbUnpeek") == 1,
      ("closing the target window fires one NumbUnpeek, got %s"):format(vim.inspect(events))
    )
  end)

  close_other_windows()
end

function Tests.float_disable_closes_the_float()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  the_float "precondition: the float peek opened a float"

  numb.disable()

  assert_no_float "disable() closes the float"
  assert(not peek:is_active(), "disable() deactivates the float handle")
  assert(vim.w[scene.win].numb_peeking == nil, "disable() clears the peeking flag")
  assert_target_untouched(scene, "after disable()")

  numb.enable()
end

function Tests.float_update_reuses_the_float()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"

  record_peek_events(function(events)
    assert(peek:update(300) == true, "update() on a float peek returns true")
    local moved = the_float "after update(300)"
    assert(moved == float, ("update() moves the same float, %d became %d"):format(float, moved))
    assert(cursor_of(float) == 300, ("the float now shows line 300, its cursor is on %d"):format(cursor_of(float)))
    assert(peek:update(260) == true, "a second update() returns true")
    assert(the_float "after update(260)" == float, "a second update() still moves the same float")

    assert(#events_named(events, "NumbUnpeek") == 0, "moving the float must not end the peek")
    assert(#events_named(events, "NumbPeek") == 2, ("each update() fires one NumbPeek, got %d"):format(#events))
  end)

  assert(peek:is_active(), "the handle is still active after the updates")
  assert_target_untouched(scene, "after moving the float")
  peek:cancel()
end

function Tests.float_peek_rejects_an_unknown_style()
  local numb = configure()
  local scene = float_scene()
  -- A valid call first: without it, a missing or broken style option would make
  -- the calls below fail for the wrong reason.
  local valid = numb.peek(0, 10, { style = "float" })
  the_float "precondition: a valid style opens a float"
  valid:cancel()
  assert_no_float "precondition: the valid peek was cancelled"

  for _, style in ipairs { "bogus", "Float", 1, true } do
    local ok = pcall(numb.peek, 0, 10, { style = style })
    local label = ("style = %s"):format(vim.inspect(style))
    assert(not ok, ("peek() must raise for %s"):format(label))
    assert_no_float(("%s leaves no float"):format(label))
    assert(not numb.is_peeking(scene.win), ("%s leaves no peek"):format(label))
    assert(numb._state.active == nil, ("%s leaves no live handle"):format(label))
    assert_target_untouched(scene, label)
  end
  assert(vim.tbl_isempty(numb._state.win_states), "rejected calls leave no saved state")
end

-- The cursor, `{ line, col }`, of a new window on `bufnr`, opened from a tab
-- page of its own so the target window's size and view stay as they are.
-- Neovim takes it from the position the buffer last had in a window that left
-- it or closed, and closing a float records the float's own cursor there.
local function cursor_a_new_window_opens_on(bufnr)
  vim.cmd "tabnew"
  local ok, result = pcall(function()
    vim.cmd(("buffer %d"):format(bufnr))
    return vim.api.nvim_win_get_cursor(0)
  end)
  pcall(vim.cmd, "tabclose!")
  if not ok then
    error(result, 0)
  end
  return result
end

-- The last line shown in a window.
local function last_visible_of(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.line "w$"
  end)
end

-- The float's frame height: its content rows plus the rows its border draws.
local function frame_height_of(float)
  local border = border_of(float)
  return vim.api.nvim_win_get_height(float) + (border[2] ~= "" and 1 or 0) + (border[6] ~= "" and 1 or 0)
end

function Tests.float_peek_style_confirmed_command_line_numb_unpeek_carries_no_float_win()
  -- `:h numb-events`: `float_win` is `NumbPeek` only, "`NumbUnpeek` never
  -- carries it, since the float is closed by then".
  local numb = configure { peek_style = "float" }
  local scene = float_scene()
  drain_scheduled(50)

  record_peek_events(function(events)
    -- The handle's own ends first, which already keep to that.
    local peek = numb.peek(0, FLOAT_TARGET)
    the_float "precondition: peek_style = float opens a float"
    peek:cancel()
    peek = numb.peek(0, FLOAT_TARGET)
    peek:accept()
    for index, unpeeked in ipairs(events_named(events, "NumbUnpeek")) do
      assert(
        unpeeked.data.float_win == nil,
        ("NumbUnpeek %d of the API carries no float_win, got %s"):format(index, tostring(unpeeked.data.float_win))
      )
    end
    vim.api.nvim_win_set_cursor(scene.win, { scene.cursor, 0 })
    clear_events(events)

    run_cmd ":240\r"
    drain_scheduled()

    local peeked = events_named(events, "NumbPeek")
    assert(#peeked > 0, "precondition: typing :240 fired NumbPeek")
    local shown = peeked[#peeked].data.float_win
    assert(shown ~= nil, "precondition: the NumbPeek of :240 carried the float as float_win")
    local unpeeked = events_named(events, "NumbUnpeek")
    assert(#unpeeked == 1, ("precondition: the confirmed :240 fired one NumbUnpeek, got %d"):format(#unpeeked))
    assert(unpeeked[1].data.accepted == true, "precondition: the NumbUnpeek reports the command as accepted")
    assert(not vim.api.nvim_win_is_valid(shown), "precondition: the float is closed by the time NumbUnpeek fires")
    assert(
      unpeeked[1].data.float_win == nil,
      ("the NumbUnpeek of a confirmed command line carries no float_win, got %s"):format(
        tostring(unpeeked[1].data.float_win)
      )
    )
  end)
  assert(cursor_of(scene.win) == FLOAT_TARGET, "the confirmed :240 still landed")
end

function Tests.float_whose_close_failed_is_still_closed_by_disable_and_seen_by_health()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"

  local original_close = vim.api.nvim_win_close
  local refused = false
  local ok, err = pcall(function()
    -- Refuses once, for the float only, as an autocommand raising while the
    -- float closes would.
    vim.api.nvim_win_close = function(win, force)
      if win == float and not refused then
        refused = true
        error "numb test: closing the float failed"
      end
      return original_close(win, force)
    end
    pcall(peek.cancel, peek)
    vim.api.nvim_win_close = original_close

    assert(refused, "precondition: cancel() tried to close the float and the close failed")
    assert(vim.api.nvim_win_is_valid(float), "precondition: the float is still open")
    assert(not peek:is_active(), "precondition: the peek itself has ended")
    local leftovers = require("numb.peek").leftover_floats()
    assert(
      vim.tbl_contains(leftovers, float),
      ("the float left open is still known, so health can report it, got %s"):format(vim.inspect(leftovers))
    )

    numb.disable()
    assert_no_float "disable() closes a float whose earlier close failed"
    assert(vim.w[scene.win].numb_peeking == nil, "the target window is not left flagged")
    numb.enable()
  end)
  vim.api.nvim_win_close = original_close
  close_floats()
  if not ok then
    error(err, 0)
  end
end

-- An OptionSet listener that closes every float once, the first time it fires
-- while `armed`, standing in for a plugin reacting to the float's options.
local OPTIONSET_CLOSING_FLOATS = [[
vim.opt.runtimepath:append(vim.fn.getcwd())
local numb = require "numb"
numb.setup { centered_peeking = false }
local lines = {}
for i = 1, 500 do
  lines[i] = ("line %03d"):format(i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 5, 0 })
vim.wo.number = false
vim.wo.cursorline = false
vim.wo.relativenumber = true
vim.wo.foldenable = true
local win = vim.api.nvim_get_current_win()
local report = { closed = 0 }
local events = {}
local recording = false
vim.api.nvim_create_autocmd("User", {
  pattern = { "NumbPeek", "NumbUnpeek" },
  callback = function(event)
    if recording then
      table.insert(events, event.match)
    end
  end,
})
local function floats()
  local found = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      table.insert(found, w)
    end
  end
  return found
end
local armed = false
vim.api.nvim_create_autocmd("OptionSet", {
  callback = function()
    if armed and not report.fired then
      report.fired = true
      for _, float in ipairs(floats()) do
        vim.api.nvim_win_close(float, true)
        report.closed = report.closed + 1
      end
    end
  end,
})
]]

local OPTIONSET_CLOSING_FLOATS_REPORT = [[
report.call_ok = ok
report.call_error = not ok and tostring(err) or nil
report.still_active = handle ~= nil and handle:is_active()
report.live = numb._state.active ~= nil
report.floats = #floats()
report.flagged = vim.w[win].numb_peeking ~= nil
report.options = {
  number = vim.wo[win].number,
  cursorline = vim.wo[win].cursorline,
  relativenumber = vim.wo[win].relativenumber,
  foldenable = vim.wo[win].foldenable,
}
report.cursor = vim.api.nvim_win_get_cursor(win)[1]
report.topline = vim.fn.line "w0"
report.events = events
io.stdout:write(vim.json.encode(report))
]]

local OPTIONSET_CLOSING_FLOATS_DURING_OPEN = OPTIONSET_CLOSING_FLOATS
  .. [[
report.topline_before = vim.fn.line "w0"
recording = true
armed = true
local ok, handle = pcall(numb.peek, 0, 240, { style = "float" })
local err = not ok and handle or nil
handle = ok and handle or nil
armed = false
recording = false
]]
  .. OPTIONSET_CLOSING_FLOATS_REPORT

local OPTIONSET_CLOSING_FLOATS_DURING_UPDATE = OPTIONSET_CLOSING_FLOATS
  .. [[
report.topline_before = vim.fn.line "w0"
local handle = numb.peek(0, 240, { style = "float" })
report.first_active = handle:is_active()
report.first_floats = #floats()
recording = true
armed = true
local ok, moved = pcall(handle.update, handle, 250)
local err = not ok and moved or nil
if ok then
  report.moved = moved
end
armed = false
recording = false
]]
  .. OPTIONSET_CLOSING_FLOATS_REPORT

local function assert_float_closed_mid_step(report, label)
  assert(report.fired, ("precondition, %s: a float option fired OptionSet while armed"):format(label))
  assert(report.closed > 0, ("precondition, %s: the listener closed the float"):format(label))
  assert(report.call_ok, ("%s must not raise: %s"):format(label, tostring(report.call_error)))
  assert(not report.still_active, ("%s: the handle is inactive"):format(label))
  assert(not report.live, ("%s: no peek is live"):format(label))
  assert(report.floats == 0, ("%s: no float is left, found %d"):format(label, report.floats))
  assert(not report.flagged, ("%s: the target window is not left flagged"):format(label))
  local expected = { number = false, cursorline = false, relativenumber = true, foldenable = true }
  assert(
    vim.deep_equal(report.options, expected),
    ("%s: the target window's options are untouched, got %s"):format(label, vim.inspect(report.options))
  )
  assert(report.cursor == 5, ("%s: the target window's cursor stays on 5, it is on %d"):format(label, report.cursor))
  assert(
    report.topline == report.topline_before,
    ("%s: the target window did not scroll, topline %d became %d"):format(label, report.topline_before, report.topline)
  )
end

function Tests.float_closed_by_an_optionset_listener_while_opening_leaves_an_inactive_handle()
  local report = run_optionset_child(OPTIONSET_CLOSING_FLOATS_DURING_OPEN)

  assert_float_closed_mid_step(report, "peek() whose float a listener closed")
  assert(
    vim.deep_equal(report.events, {}),
    ("a float peek that never became live fires no event, got %s"):format(vim.inspect(report.events))
  )
end

function Tests.float_closed_by_an_optionset_listener_while_moving_ends_the_peek()
  local report = run_optionset_child(OPTIONSET_CLOSING_FLOATS_DURING_UPDATE)

  assert(report.first_active and report.first_floats == 1, "precondition: the float peek is live before update()")
  assert_float_closed_mid_step(report, "update() whose float a listener closed")
  assert(
    report.moved == false,
    ("update() on a peek whose float closed mid-move returns false, got %s"):format(tostring(report.moved))
  )
  assert(
    vim.deep_equal(report.events, { "NumbUnpeek" }),
    ("the ended peek fires exactly one NumbUnpeek and no NumbPeek, got %s"):format(vim.inspect(report.events))
  )
end

function Tests.float_peek_in_a_window_too_small_for_the_float_peeks_in_place()
  local numb = configure()
  reset_tall_buffer()
  set_unpeeked_options()
  vim.cmd "split"
  local target = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(target, 2)
  pin_topline(target, 1)
  assert(vim.api.nvim_win_get_height(target) == 2, "precondition: the target window is 2 rows high")
  local other = vim.fn.win_getid(vim.fn.winnr "j")
  assert(other ~= 0 and other ~= target, "precondition: another window sits below the target")
  assert_unpeeked_options(target, "precondition")

  local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })

  assert(peek:is_active(), "the peek is active")
  -- A float at least 3 rows high cannot fit a 2-row window, and one sticking out
  -- of it would cover the window below.
  assert_no_float "a window too small for a float peeks in place instead"
  assert(cursor_of(target) == FLOAT_TARGET, "in place, the target window's cursor moves to the target")
  assert(vim.wo[target].number == true, "in place, the target window gets the peek options")
  assert(numb.is_peeking(target), "is_peeking() reports the target window")

  peek:cancel()
  assert_no_float "nothing floats after cancel()"
  assert_unpeeked_options(target, "cancel() restores the in-place fallback")
  assert(cursor_of(target) == 1, "cancel() puts the cursor back")
  close_other_windows()
end

-- A float scene whose target window's cursor is on line 5, column 4, and whose
-- buffer remembers that very position: the target window left the buffer and
-- came back to it, which is when Neovim records where a window was.
local function remembered_cursor_scene()
  local scene = float_scene()
  vim.api.nvim_win_set_cursor(scene.win, { 5, 4 })
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(scene.win, scratch)
  vim.api.nvim_win_set_buf(scene.win, scene.bufnr)
  vim.api.nvim_buf_delete(scratch, { force = true })
  local cursor = vim.api.nvim_win_get_cursor(scene.win)
  assert(
    vim.deep_equal(cursor, { 5, 4 }),
    ("precondition: back on its buffer, the target window's cursor is on { 5, 4 }, got %s"):format(vim.inspect(cursor))
  )
  return scene
end

function Tests.float_peek_leaves_no_last_position_behind_in_the_buffer()
  local numb = configure()
  -- Without any peek, a new window on the buffer opens where the target
  -- window's cursor is, column included.
  local baseline_scene = remembered_cursor_scene()
  local baseline = cursor_a_new_window_opens_on(baseline_scene.bufnr)
  assert(
    vim.deep_equal(baseline, { 5, 4 }),
    ("precondition: without a peek a new window opens on { 5, 4 }, got %s"):format(vim.inspect(baseline))
  )

  local scene = remembered_cursor_scene()
  local peek = numb.peek(0, 150, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"
  assert(cursor_of(float) == 150, "precondition: the float's cursor is on line 150")
  peek:cancel()
  assert_no_float "precondition: cancel() closed the float"
  assert(
    vim.deep_equal(vim.api.nvim_win_get_cursor(scene.win), { 5, 4 }),
    "precondition: the target window's cursor is still on { 5, 4 }"
  )

  local reopened = cursor_a_new_window_opens_on(scene.bufnr)
  assert(
    vim.deep_equal(reopened, { 5, 4 }),
    ("after a cancelled float peek a new window opens where the target window's cursor is, { 5, 4 }, got %s"):format(
      vim.inspect(reopened)
    )
  )
end

function Tests.float_bottom_strip_ends_on_the_last_text_row_under_a_winbar()
  local numb = configure { float = { position = "bottom" } }
  local scene = float_scene()
  local saved = vim.api.nvim_get_option_value("winbar", { win = scene.win, scope = "local" })
  local ok, err = pcall(function()
    -- The same check without a winbar first, so what is measured is known to
    -- hold where the window has no winbar.
    for _, winbar in ipairs { "", "numb test winbar" } do
      vim.api.nvim_set_option_value("winbar", winbar, { win = scene.win, scope = "local" })
      -- Drawn once before the peek, as a winbar the user sees has been: Neovim
      -- places a float over a window's text only as that window was last drawn.
      vim.cmd "redraw"
      local label = winbar == "" and "without a winbar" or "under a winbar"
      local draws = vim.fn.getwininfo(scene.win)[1].winbar
      assert(
        draws == (winbar == "" and 0 or 1),
        ("precondition, %s: the target draws %d winbar rows"):format(label, draws)
      )
      local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
      local float = the_float(label)
      vim.cmd "redraw"
      -- Screen rows, 1-based. The target's outer height counts its winbar, so
      -- its last text row is its last row.
      local target_top = vim.fn.win_screenpos(scene.win)[1]
      local last_text_row = target_top + vim.api.nvim_win_get_height(scene.win) - 1
      local text_rows = vim.fn.getwininfo(scene.win)[1].height
      assert(
        last_text_row == target_top + draws + text_rows - 1,
        ("precondition, %s: the target's last text row is %d"):format(label, last_text_row)
      )
      local frame_top = vim.fn.win_screenpos(float)[1]
      local frame_bottom = frame_top + frame_height_of(float) - 1
      peek:cancel()
      assert(
        frame_bottom == last_text_row,
        ("%s, the bottom strip must end on the target's last text row %d, it ends on row %d"):format(
          label,
          last_text_row,
          frame_bottom
        )
      )
    end
  end)
  close_floats()
  vim.api.nvim_set_option_value("winbar", saved, { win = scene.win, scope = "local" })
  if not ok then
    error(err, 0)
  end
end

function Tests.float_auto_judges_the_clamped_line()
  local numb = configure()
  vim.cmd "enew!"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
  vim.bo.modified = false
  local win = vim.api.nvim_get_current_win()
  assert(last_visible_of(win) == 3, "precondition: all three lines are on screen")

  local peek = numb.peek(0, 9999, { style = "auto" })

  assert(peek:is_active(), "the auto peek is active")
  assert_no_float "line 9999 clamps to line 3, which is on screen, so auto peeks in place"
  assert(cursor_of(win) == 3, ("in place, the cursor is on the clamped line 3, it is on %d"):format(cursor_of(win)))
  peek:cancel()
  assert_no_float "nothing floats after cancel()"
end

function Tests.float_update_to_a_near_line_keeps_the_target_centered()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"
  assert_float_shows(scene, float, FLOAT_TARGET, "precondition")
  local near = FLOAT_TARGET + 2
  local topline = topline_of(float)
  -- A line already shown needs no scroll, so only centering can move the view.
  assert(
    near >= topline and near <= last_visible_of(float),
    ("precondition: line %d is already shown in the float (%d..%d)"):format(near, topline, last_visible_of(float))
  )

  assert(peek:update(near) == true, "update() to a near line returns true")

  assert(cursor_of(float) == near, ("the float's cursor moves to %d"):format(near))
  assert(
    topline_of(float) - topline == near - FLOAT_TARGET,
    ("the float scrolls with the target to keep it centered: topline %d became %d"):format(topline, topline_of(float))
  )
  assert_float_shows(scene, float, near, "after the near update")
  peek:cancel()
end

function Tests.float_auto_judges_visibility_on_the_view_before_the_in_place_peek()
  local numb = configure { centered_peeking = true }
  local scene = float_scene()
  local near = scene.last_visible - 1

  local peek = numb.peek(0, near, { style = "auto" })

  assert_no_float(("precondition: line %d is on screen, so auto peeks in place"):format(near))
  local scrolled_top = topline_of(scene.win)
  local scrolled_last = last_visible_of(scene.win)
  assert(scrolled_top > scene.topline, "precondition: centering the in-place peek scrolled the view")
  -- On screen in the view the peek scrolled to, off screen in the user's own.
  local between = scrolled_last
  assert(
    between > scene.last_visible,
    ("precondition: line %d is off the user's screen (1..%d)"):format(between, scene.last_visible)
  )

  assert(peek:update(between) == true, "update() returns true")

  local float = the_float(("line %d is off the screen the user left, so auto floats"):format(between))
  assert(cursor_of(float) == between, ("the float shows line %d"):format(between))
  assert(
    topline_of(scene.win) == scene.topline,
    ("the target window is back on topline %d, it is on %d"):format(scene.topline, topline_of(scene.win))
  )
  assert(cursor_of(scene.win) == scene.cursor, "the target window's cursor is back on its origin")
  peek:cancel()
  assert_no_float "nothing floats after cancel()"
end

function Tests.float_height_is_at_least_three_rows()
  local numb = configure { float = { height = 0.1 } }
  with_winborder("", function()
    reset_tall_buffer()
    vim.cmd "split"
    local target = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(target, 6)
    assert(vim.api.nvim_win_get_height(target) == 6, "precondition: the target window is 6 rows high")
    assert(math.floor(6 * 0.1) < 3, "precondition: a tenth of 6 rows is under 3 rows")

    local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"
    local height = vim.api.nvim_win_get_height(float)
    peek:cancel()

    assert(height == 3, ("a float is at least 3 content rows, got %d"):format(height))
  end)
  close_other_windows()
end

function Tests.float_win_config_returning_nil_keeps_numbs_config_and_runs_on_every_update()
  local calls = 0
  local numb = configure {
    float = {
      win_config = function()
        calls = calls + 1
      end,
    },
  }
  with_winborder("", function()
    local scene = float_scene()
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "win_config returning nil"

    assert(calls == 1, ("win_config is called once to open the float, got %d"):format(calls))
    local config = vim.api.nvim_win_get_config(float)
    assert(config.relative == "win" and config.win == scene.win, "numb's own config is used: anchored to the target")
    assert(edge_of(float, scene.win) == "bottom", "numb's own config is used: on the bottom edge")
    assert(
      title_of(float):find(("%d/%d"):format(FLOAT_TARGET, TALL_BUFFER_LINES), 1, true) ~= nil,
      ("numb's own config is used: the title, got %q"):format(title_of(float))
    )

    assert(peek:update(300) == true, "update() returns true")
    assert(calls == 2, ("win_config is called again on update(), got %d calls"):format(calls))
    assert(title_of(float):find("300/500", 1, true) ~= nil, "update() still retitles the float")
    assert_target_untouched(scene, "a float under a win_config returning nil")
    peek:cancel()
  end)
end

function Tests.float_respects_a_winborder_given_as_a_list_of_characters()
  if vim.fn.exists "+winborder" == 0 then
    note_skipped "'winborder' does not exist, so a list of characters cannot be set"
    return
  end
  local list = "a,b,c,d,e,f,g,h"
  local saved = vim.go.winborder
  local accepted = pcall(function()
    vim.go.winborder = list
  end)
  vim.go.winborder = saved
  if not accepted then
    note_skipped "this 'winborder' takes no list of characters"
    return
  end

  local numb = configure()
  with_winborder(list, function()
    float_scene()
    local ok, peek = pcall(numb.peek, 0, FLOAT_TARGET, { style = "float" })
    assert(ok, ("peek() under winborder = %q must not raise: %s"):format(list, tostring(peek)))
    local float = the_float(("winborder = %q"):format(list))
    local border = border_of(float)
    assert(
      vim.deep_equal(border, vim.split(list, ",", { plain = true })),
      ("the listed characters are the border, got %s"):format(vim.inspect(border))
    )
    assert(
      title_of(float):find(("%d/%d"):format(FLOAT_TARGET, TALL_BUFFER_LINES), 1, true) ~= nil,
      ("the list has a top edge, so the title stays, got %q"):format(title_of(float))
    )
    peek:cancel()
  end)
end

function Tests.float_update_rejects_a_style()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"
  assert(peek:update(250) == true, "precondition: update() without a style moves the peek")

  local ok = pcall(peek.update, peek, 12, { style = "window" })

  assert(not ok, "update() must raise for opts.style, which only peek() takes")
  assert(peek:is_active(), "the rejected update() leaves the peek live")
  assert(the_float "after the rejected update()" == float, "the same float is still shown")
  assert(cursor_of(float) == 250, ("the rejected update() moved nothing, the float is on %d"):format(cursor_of(float)))
  assert_target_untouched(scene, "after the rejected update()")
  peek:cancel()
end

function Tests.float_win_config_returning_a_non_table_raises_a_named_error()
  local numb = configure {
    float = {
      win_config = function()
        return 5
      end,
    },
  }
  local scene = float_scene()

  local ok, err = pcall(numb.peek, 0, FLOAT_TARGET, { style = "float" })

  assert(not ok, "peek() must raise when win_config returns neither a table nor nil")
  assert(
    tostring(err):find("float.win_config", 1, true) ~= nil,
    ("the error names the float.win_config option, got %q"):format(tostring(err))
  )
  assert_no_float "the rejected config leaves no float"
  assert(numb._state.active == nil, "the rejected config leaves no live peek")
  assert(vim.w[scene.win].numb_peeking == nil, "the rejected config leaves the target unflagged")
  assert_target_untouched(scene, "after the rejected config")
end

function Tests.float_api_accept_records_the_target_windows_cursor_at_accept_time()
  local numb = configure()
  local scene = float_scene()
  drain_scheduled(50)
  vim.cmd "clearjumps"
  local peek = numb.peek(0, 200, { style = "float" })
  the_float "precondition: the float peek opened a float"

  -- The float leaves the target window alone, so it can move while the peek
  -- lasts; the jump starts from wherever it is when the peek is accepted.
  vim.api.nvim_win_set_cursor(scene.win, { 20, 0 })
  assert(peek:is_active(), "precondition: moving the target window's cursor keeps the float peek")
  assert(peek:accept() == true, "accept() returns true")

  assert(cursor_of(scene.win) == 200, "accept() lands on 200")
  drain_scheduled()
  vim.cmd "normal! \15"
  assert(
    cursor_of(scene.win) == 20,
    ("<C-o> after accept() returns to line 20, where the cursor was, got %d"):format(cursor_of(scene.win))
  )
end

-- A `float.win_config` that only swaps numb's top edge for a full rounded
-- border, two rows and two columns more than numb's own.
local function rounded_border(win_config)
  win_config.border = "rounded"
  return win_config
end

-- The float's frame, border included, in the target window's text coordinates:
-- its first row and column and its height and width.
local function frame_of(float)
  local config = vim.api.nvim_win_get_config(float)
  assert(
    config.anchor == nil or config.anchor == "NW",
    ("precondition: the float is anchored by its top left corner, got %s"):format(tostring(config.anchor))
  )
  local border = border_of(float)
  return {
    row = config.row,
    col = config.col,
    height = frame_height_of(float),
    width = vim.api.nvim_win_get_width(float) + (border[8] ~= "" and 1 or 0) + (border[4] ~= "" and 1 or 0),
  }
end

-- A split of the tall buffer whose target window is exactly `rows` rows of
-- text high, its cursor on line 5 and its view pinned at the top.
local function float_split_of_height(rows)
  reset_tall_buffer()
  set_unpeeked_options()
  vim.cmd "split"
  local target = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(target, rows)
  pin_topline(target, 1)
  vim.api.nvim_win_set_cursor(target, { 5, 0 })
  assert(
    vim.fn.getwininfo(target)[1].height == rows,
    ("precondition: the target window is %d rows of text high"):format(rows)
  )
  return target
end

function Tests.float_frame_under_a_win_config_border_stays_inside_the_target_rows()
  local numb = configure { float = { win_config = rounded_border } }
  with_winborder("", function()
    local target = float_split_of_height(20)
    local rows = vim.fn.getwininfo(target)[1].height
    local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"
    assert(border_of(float)[6] ~= "", "precondition: the rounded border draws a bottom edge")

    for _, step in ipairs { "peek()", "update(300)" } do
      if step == "update(300)" then
        assert(peek:update(300) == true, "precondition: update(300) moves the peek")
      end
      local frame = frame_of(float)
      assert(frame.row >= 0, ("after %s the frame starts inside the target, on row %d"):format(step, frame.row))
      assert(
        frame.row + frame.height <= rows,
        ("after %s the frame, border included, ends inside the target's %d rows: rows %d..%d"):format(
          step,
          rows,
          frame.row,
          frame.row + frame.height - 1
        )
      )
    end
    peek:cancel()
  end)
  close_other_windows()
end

function Tests.float_frame_under_a_win_config_border_stays_inside_the_target_columns()
  local numb = configure { float = { win_config = rounded_border } }
  with_winborder("", function()
    reset_tall_buffer()
    local target = create_split()
    vim.api.nvim_win_set_width(target, 40)
    local columns = vim.api.nvim_win_get_width(target)
    assert(columns == 40, ("precondition: the target window is 40 columns wide, got %d"):format(columns))

    local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"
    local border = border_of(float)
    assert(border[4] ~= "" and border[8] ~= "", "precondition: the rounded border draws both side edges")
    local frame = frame_of(float)
    peek:cancel()

    assert(frame.col >= 0, ("the frame starts inside the target, on column %d"):format(frame.col))
    assert(
      frame.col + frame.width <= columns,
      ("the frame, border included, ends inside the target's %d columns: columns %d..%d"):format(
        columns,
        frame.col,
        frame.col + frame.width - 1
      )
    )
  end)
  close_other_windows()
end

function Tests.float_peek_in_a_window_too_small_for_a_win_config_border_peeks_in_place()
  local numb = configure { float = { win_config = rounded_border } }
  with_winborder("", function()
    -- 3 rows of text and a rounded border's 2 rows need 5; numb's own top edge
    -- would fit in 4.
    local target = float_split_of_height(4)

    local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })

    assert(peek:is_active(), "the peek is active")
    assert_no_float "a float with its win_config border does not fit 4 rows, so it peeks in place"
    assert(cursor_of(target) == FLOAT_TARGET, "in place, the target window's cursor moves to the target")
    assert(vim.wo[target].number == true, "in place, the target window gets the peek options")
    peek:cancel()
    assert_unpeeked_options(target, "cancel() restores the in-place fallback")
  end)
  close_other_windows()
end

function Tests.float_win_config_setting_row_and_width_keeps_them()
  local numb = configure {
    float = {
      win_config = function(win_config)
        win_config.border = "rounded"
        win_config.row = 2
        win_config.width = 10
        return win_config
      end,
    },
  }
  with_winborder("", function()
    local target = float_split_of_height(20)
    local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"

    for _, step in ipairs { "peek()", "update(300)" } do
      if step == "update(300)" then
        assert(peek:update(300) == true, "precondition: update(300) moves the peek")
      end
      local config = vim.api.nvim_win_get_config(float)
      assert(config.row == 2, ("after %s the row win_config set stays 2, got %s"):format(step, tostring(config.row)))
      assert(
        vim.api.nvim_win_get_width(float) == 10,
        ("after %s the width win_config set stays 10, got %d"):format(step, vim.api.nvim_win_get_width(float))
      )
    end
    peek:cancel()
  end)
  close_other_windows()
end

function Tests.float_peek_with_the_default_border_needs_four_rows()
  local numb = configure()
  with_winborder("", function()
    -- 3 rows of text and numb's top edge: a 3-row window is one row short.
    local small = float_split_of_height(3)
    local peek = numb.peek(small, FLOAT_TARGET, { style = "float" })
    assert(peek:is_active(), "the peek in 3 rows is active")
    assert_no_float "a 3-row window has no room for 3 rows and a top edge, so it peeks in place"
    assert(cursor_of(small) == FLOAT_TARGET, "in place, the 3-row window's cursor moves to the target")
    peek:cancel()
    assert_unpeeked_options(small, "cancel() restores the 3-row window")
    close_other_windows()

    local fitting = float_split_of_height(4)
    peek = numb.peek(fitting, FLOAT_TARGET, { style = "float" })
    local float = the_float "a 4-row window holds 3 rows and a top edge, so it floats"
    assert(frame_height_of(float) == 4, ("the float fills the 4 rows, frame height %d"):format(frame_height_of(float)))
    assert(cursor_of(fitting) == 5, "the 4-row window's cursor stays where it was")
    peek:cancel()
  end)
  close_other_windows()
end

-- Every window option a float can leave behind in its buffer: Neovim keeps the
-- options of the last window that closed on a buffer and gives them to the next
-- window opened on it.
local LEAKABLE_WINDOW_OPTIONS = {
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

local function window_options_of(win)
  local values = {}
  for _, option in ipairs(LEAKABLE_WINDOW_OPTIONS) do
    values[option] = vim.api.nvim_get_option_value(option, { win = win })
  end
  return values
end

-- The window options of a new window on `bufnr`, opened from a tab page of its
-- own as `cursor_a_new_window_opens_on` does.
local function options_a_new_window_opens_with(bufnr)
  vim.cmd "tabnew"
  local ok, result = pcall(function()
    vim.cmd(("buffer %d"):format(bufnr))
    return window_options_of(0)
  end)
  pcall(vim.cmd, "tabclose!")
  if not ok then
    error(result, 0)
  end
  return result
end

-- A float scene whose target window's options differ from the ones a float
-- peek and its minimal style set, so a leak of any of them would show.
local function option_leak_scene()
  local scene = float_scene()
  vim.wo[scene.win].number = false
  vim.wo[scene.win].cursorline = false
  vim.wo[scene.win].foldenable = true
  vim.wo[scene.win].list = true
  vim.wo[scene.win].signcolumn = "yes"
  scene.options = window_options_of(scene.win)
  return scene
end

local function assert_no_option_leak(numb, label)
  -- Without any peek, a new window on the buffer has the target's options.
  local baseline_scene = option_leak_scene()
  local baseline = options_a_new_window_opens_with(baseline_scene.bufnr)
  assert(
    vim.deep_equal(baseline, baseline_scene.options),
    ("precondition, %s: without a peek a new window has the target's options %s, got %s"):format(
      label,
      vim.inspect(baseline_scene.options),
      vim.inspect(baseline)
    )
  )

  local scene = option_leak_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float(("precondition, %s: the float peek opened a float"):format(label))
  assert(
    vim.wo[float].number == true and vim.wo[float].foldenable == false,
    ("precondition, %s: the float has its peek options"):format(label)
  )
  peek:cancel()
  assert_no_float(("precondition, %s: cancel() closed the float"):format(label))

  local reopened = options_a_new_window_opens_with(scene.bufnr)
  for _, option in ipairs(LEAKABLE_WINDOW_OPTIONS) do
    assert(
      vim.deep_equal(reopened[option], scene.options[option]),
      ("%s: after a float peek a new window has the target's %s = %s, got %s"):format(
        label,
        option,
        vim.inspect(scene.options[option]),
        vim.inspect(reopened[option])
      )
    )
  end
end

-- Leaks on 0.10 and 0.11. Neovim 0.12 no longer records the options of a float
-- opened with `style = "minimal"`, so there this holds whatever numb does; the
-- test below covers 0.12 too.
function Tests.float_peek_leaves_no_window_options_behind_in_the_buffer()
  local numb = configure()
  with_winborder("", function()
    assert_no_option_leak(numb, "the default float")
  end)
end

-- Every version: without `style = "minimal"`, 0.12 records the float's options
-- as well.
function Tests.float_peek_without_minimal_style_leaves_no_window_options_behind()
  local numb = configure {
    float = {
      win_config = function(win_config)
        win_config.style = nil
        return win_config
      end,
    },
  }
  with_winborder("", function()
    assert_no_option_leak(numb, "a float without minimal style")
  end)
end

local FLOAT_CREATES_NO_BUFFER = [[
vim.opt.runtimepath:append(vim.fn.getcwd())
local numb = require "numb"
numb.setup { centered_peeking = false }
local lines = {}
for i = 1, 500 do
  lines[i] = ("line %03d"):format(i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 5, 0 })
local report = {}
local created = 0
vim.api.nvim_create_autocmd("BufNew", {
  callback = function()
    created = created + 1
  end,
})
local function floats()
  local found = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      found = found + 1
    end
  end
  return found
end
-- The counter sees a buffer being made at all.
local proof = vim.api.nvim_create_buf(false, true)
report.proof_created = created
vim.api.nvim_buf_delete(proof, { force = true })
created = 0

report.bufs_before = #vim.api.nvim_list_bufs()
report.last_before = vim.fn.bufnr "$"
local handle = numb.peek(0, 240, { style = "float" })
report.active = handle:is_active()
report.floats = floats()
report.moved = handle:update(300)
handle:cancel()
handle = numb.peek(0, 200, { style = "float" })
report.second_active = handle:is_active()
handle:accept()
report.floats_after = floats()
report.created = created
report.bufs_after = #vim.api.nvim_list_bufs()
report.last_after = vim.fn.bufnr "$"
io.stdout:write(vim.json.encode(report))
]]

-- In a child Neovim, a session of its own: anything numb makes once per session
-- would already exist in this one.
function Tests.float_peek_creates_no_buffer()
  local report = run_optionset_child(FLOAT_CREATES_NO_BUFFER)

  assert(
    report.proof_created == 1,
    ("precondition: BufNew fired for a new buffer, %d times"):format(report.proof_created)
  )
  assert(report.active and report.floats == 1, "precondition: the float peek opened a float")
  assert(report.moved == true, "precondition: update() moved the float peek")
  assert(report.second_active, "precondition: the second float peek is active")
  assert(report.floats_after == 0, ("precondition: no float is left, found %d"):format(report.floats_after))
  assert(report.created == 0, ("a float peek fires no BufNew, it fired %d"):format(report.created))
  assert(
    report.bufs_after == report.bufs_before,
    ("a float peek leaves the buffer list as it was, %d buffers became %d"):format(
      report.bufs_before,
      report.bufs_after
    )
  )
  assert(
    report.last_after == report.last_before,
    ("a float peek uses no buffer number, bufnr('$') %d became %d"):format(report.last_before, report.last_after)
  )
end

-- Replace `nvim_win_close` for `fn`, refusing to close `float` the first
-- `refusals` times, as an autocommand raising while it closes would. Returns
-- how many times it refused.
local function with_refused_float_close(float, refusals, fn)
  local original_close = vim.api.nvim_win_close
  local refused = 0
  vim.api.nvim_win_close = function(win, force)
    if win == float and refused < refusals then
      refused = refused + 1
      error "numb test: closing the float failed"
    end
    return original_close(win, force)
  end
  local ok, err = pcall(fn, function()
    return refused
  end)
  vim.api.nvim_win_close = original_close
  close_floats()
  if not ok then
    error(err, 0)
  end
end

function Tests.float_whose_close_failed_twice_is_still_closed_by_a_later_reset()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"

  with_refused_float_close(float, 2, function(refused)
    pcall(peek.cancel, peek)
    assert(refused() == 1, "precondition: cancel() tried to close the float and the close failed")

    numb.disable()
    assert(refused() == 2, "precondition: disable() tried to close the float again and the close failed")
    assert(vim.api.nvim_win_is_valid(float), "precondition: the float is still open")
    local leftovers = require("numb.peek").leftover_floats()
    assert(
      vim.tbl_contains(leftovers, float),
      ("a float whose close failed during reset is still known, got %s"):format(vim.inspect(leftovers))
    )

    numb.disable()
    assert_no_float "the next disable() closes the float at last"
    assert(vim.tbl_isempty(require("numb.peek").leftover_floats()), "nothing is left over once the float closed")
    assert(vim.w[scene.win].numb_peeking == nil, "the target window is not left flagged")
    numb.enable()
  end)
end

function Tests.float_left_open_by_an_auto_switch_is_a_leftover_while_the_peek_is_live()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "auto" })
  local float = the_float "precondition: auto floats an off-screen line"

  with_refused_float_close(float, 1, function(refused)
    -- Line 3 is on screen, so auto switches to peeking in place and closes
    -- the float, which fails.
    pcall(peek.update, peek, 3)
    assert(refused() == 1, "precondition: switching to an in-place peek tried to close the float and failed")
    assert(vim.api.nvim_win_is_valid(float), "precondition: the float is still open")
    assert(numb._state.active == peek, "precondition: the handle is still the live peek")

    local leftovers = require("numb.peek").leftover_floats()
    assert(
      vim.tbl_contains(leftovers, float),
      ("a float numb is closing is a leftover even while its handle is live, got %s"):format(vim.inspect(leftovers))
    )

    numb.disable()
    assert_no_float "disable() closes the float"
    numb.enable()
  end)
  assert(vim.w[scene.win].numb_peeking == nil, "the target window is not left flagged")
end

local OPTIONSET_CLOSING_THE_TARGET = [[
vim.opt.runtimepath:append(vim.fn.getcwd())
local numb = require "numb"
numb.setup { centered_peeking = true }
local lines = {}
for i = 1, 500 do
  lines[i] = ("line %03d"):format(i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.cmd "split"
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(win, { 1, 0 })
local report = { fired = false }
local events = {}
local recording = false
vim.api.nvim_create_autocmd("User", {
  pattern = { "NumbPeek", "NumbUnpeek" },
  callback = function(event)
    if recording then
      table.insert(events, event.match)
    end
  end,
})
local armed = false
vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "scrolloff",
  callback = function()
    if armed and not report.fired then
      report.fired = true
      report.closed = pcall(vim.api.nvim_win_close, win, true)
    end
  end,
})
recording = true
armed = true
local ok, handle = pcall(numb.peek, 0, 30)
armed = false
recording = false
report.call_ok = ok
report.call_error = not ok and tostring(handle) or nil
report.still_active = ok and handle:is_active()
report.live = numb._state.active ~= nil
report.target_valid = vim.api.nvim_win_is_valid(win)
report.saved = vim.tbl_count(numb._state.win_states)
report.events = events
io.stdout:write(vim.json.encode(report))
]]

function Tests.api_peek_whose_window_an_optionset_listener_closes_while_centering_is_inactive()
  local report = run_optionset_child(OPTIONSET_CLOSING_THE_TARGET)

  assert(report.fired, "precondition: centering the peek set 'scrolloff' and fired OptionSet")
  assert(report.closed and not report.target_valid, "precondition: the listener closed the target window")
  assert(report.call_ok, ("peek() must not raise: %s"):format(tostring(report.call_error)))
  assert(not report.still_active, "the handle of a peek whose window closed is inactive")
  assert(not report.live, "no peek is live")
  assert(
    vim.deep_equal(report.events, {}),
    ("a peek that never became live fires no event, got %s"):format(vim.inspect(report.events))
  )
  assert(report.saved == 0, ("no saved state is left, win_states holds %d"):format(report.saved))
end

-- The row of text a window's cursor is on, counted from 1 as `winline()` does.
local function winline_of(win)
  return vim.api.nvim_win_call(win, vim.fn.winline)
end

function Tests.float_whose_close_failed_never_lands_on_a_later_command_line()
  local numb = configure { peek_style = "float" }
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"

  with_refused_float_close(float, 2, function(refused)
    pcall(peek.cancel, peek)
    assert(refused() == 1, "precondition: cancel() tried to close the float and the close failed")
    numb.disable()
    assert(refused() == 2, "precondition: disable() tried to close the float again and the close failed")
    assert(vim.api.nvim_win_is_valid(float), "precondition: the float is still open")
    assert(
      vim.tbl_contains(require("numb.peek").leftover_floats(), float),
      "precondition: the float left open is a leftover"
    )
    numb.enable()
    assert(cursor_of(scene.win) == scene.cursor, "precondition: the target window is still on its origin")

    local observed = confirm_cmdline ":12"
    drain_scheduled()

    assert(observed.peeking, "precondition: :12 peeked while it was being typed")
    assert(
      cursor_of(scene.win) == 12,
      ("the confirmed :12 lands on 12, not on the ended peek's %d, the cursor is on %d"):format(
        FLOAT_TARGET,
        cursor_of(scene.win)
      )
    )
    assert(not vim.api.nvim_win_is_valid(float), "leaving the command line closes the leftover float at last")
    assert(vim.tbl_isempty(require("numb.peek").leftover_floats()), "nothing is left over once the float closed")
    assert(vim.w[scene.win].numb_peeking == nil, "the target window is not left flagged")
  end)
end

function Tests.float_whose_close_failed_leaves_a_later_peek_alone()
  local numb = configure()
  local scene = float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"

  -- Refused once, then closed by someone else: `with_refused_float_close` closes
  -- every float it leaves open, with the real `nvim_win_close`.
  with_refused_float_close(float, 1, function(refused)
    pcall(peek.cancel, peek)
    assert(refused() == 1, "precondition: cancel() tried to close the float and the close failed")
    assert(vim.api.nvim_win_is_valid(float), "precondition: the float is still open")
  end)
  assert(not vim.api.nvim_win_is_valid(float), "precondition: someone else closed the float numb failed to close")

  local function assert_later_range(label)
    local range = highlighted_range(scene.bufnr)
    assert(
      range ~= nil and range.count == 1 and range[1] == 18 and range[2] == 22,
      ("%s: lines 18..22 are highlighted as one range, got %s"):format(label, vim.inspect(range))
    )
  end

  local later = numb.peek(0, 20, { style = "window", range = { 18, 22 } })
  assert(later:is_active(), "precondition: the later window peek is active")
  assert(vim.w[scene.win].numb_peeking == true, "precondition: the later peek flags its window")
  assert_later_range "precondition: the later peek draws its range"

  vim.g.numb_api_probe = nil
  run_cmd ":let g:numb_api_probe = 1\r"
  drain_scheduled()
  local probe = vim.g.numb_api_probe
  vim.g.numb_api_probe = nil
  assert(probe == 1, "precondition: the command ran, so leaving the command line was exercised")

  assert(later:is_active(), "the later peek is still live")
  assert(vim.w[scene.win].numb_peeking == true, "the later peek's window keeps its peeking flag")
  assert_later_range "the later peek keeps its range"
  assert(
    cursor_of(scene.win) == 20,
    ("the window stays on the later peek's line 20, not the ended peek's %d, it is on %d"):format(
      FLOAT_TARGET,
      cursor_of(scene.win)
    )
  )

  later:cancel()
  drain_scheduled()
  assert(cursor_of(scene.win) == scene.cursor, "cancel() puts the window back on its origin")
  assert(vim.w[scene.win].numb_peeking == nil, "the peeking flag goes when the later peek ends")
  assert(highlighted_range(scene.bufnr) == nil, "the range goes when the later peek ends")
end

-- A `float.win_config` that sets only the height, leaving numb's row.
local function fifteen_rows_high(win_config)
  win_config.height = 15
  return win_config
end

function Tests.float_win_config_setting_only_the_height_keeps_the_frame_inside_the_target()
  -- On line 3, a 16-row frame on the bottom edge (rows 5..20) leaves the cursor
  -- line free, so `auto` has a place that neither sticks out nor covers it.
  for _, case in ipairs { { position = "bottom", cursor = 5 }, { position = "auto", cursor = 3 } } do
    local numb = configure { float = { position = case.position, win_config = fifteen_rows_high } }
    with_winborder("", function()
      local target = float_split_of_height(20)
      vim.api.nvim_win_set_cursor(target, { case.cursor, 0 })
      local rows = vim.fn.getwininfo(target)[1].height
      local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })
      local float = the_float(("precondition, %s: the float peek opened a float"):format(case.position))
      assert(
        vim.api.nvim_win_get_height(float) == 15,
        ("precondition, %s: the float has the 15 rows win_config set"):format(case.position)
      )

      for _, step in ipairs { "peek()", "update(300)" } do
        if step == "update(300)" then
          assert(peek:update(300) == true, "precondition: update(300) moves the peek")
        end
        local frame = frame_of(float)
        assert(
          frame.row >= 0 and frame.row + frame.height <= rows,
          ("%s, after %s: the frame, border included, lies inside the target's %d rows, it is on rows %d..%d"):format(
            case.position,
            step,
            rows,
            frame.row,
            frame.row + frame.height - 1
          )
        )
        if case.position == "auto" then
          local cursor_row = winline_of(target) - 1
          assert(
            cursor_row < frame.row or cursor_row >= frame.row + frame.height,
            ("auto, after %s: the frame on rows %d..%d leaves the cursor line, row %d, uncovered"):format(
              step,
              frame.row,
              frame.row + frame.height - 1,
              cursor_row
            )
          )
        end
      end
      peek:cancel()
    end)
    close_other_windows()
  end
end

-- Window options outside `LEAKABLE_WINDOW_OPTIONS`: a float opened from the
-- current window starts with its options, and closing it records them.
local FOREIGN_WINDOW_OPTIONS = { conceallevel = 2, linebreak = true, cursorlineopt = "number" }
local TARGET_WINDOW_OPTIONS = { conceallevel = 0, linebreak = false, cursorlineopt = "both" }

-- Set on `win` only, with `scope = nil` setting its global values as well: a
-- window opened from `win` on a buffer that recorded no options starts from
-- those. A window's global values of window options are its own, so this
-- reaches no window but `win` and the ones later split from it.
local function set_window_options(win, values, scope)
  for option, value in pairs(values) do
    vim.api.nvim_set_option_value(option, value, { win = win, scope = scope })
  end
end

-- The options of a new window on `bufnr`, opened from the current window: the
-- new window starts with the current window's options, and entering the buffer
-- replaces them with whatever the buffer recorded of the last window on it.
local function foreign_options_a_new_window_opens_with(bufnr)
  vim.cmd "tabnew"
  local ok, result = pcall(function()
    vim.cmd(("buffer %d"):format(bufnr))
    local values = {}
    for option in pairs(TARGET_WINDOW_OPTIONS) do
      values[option] = vim.api.nvim_get_option_value(option, { win = 0 })
    end
    return values
  end)
  pcall(vim.cmd, "tabclose!")
  if not ok then
    error(result, 0)
  end
  return result
end

function Tests.float_api_peek_of_a_window_that_is_not_current_leaves_the_targets_options()
  local variants = {
    { label = "the default float" },
    {
      label = "a float without minimal style",
      win_config = function(win_config)
        win_config.style = nil
        return win_config
      end,
    },
  }
  for _, variant in ipairs(variants) do
    local numb = configure { float = { win_config = variant.win_config } }
    -- Both scopes: the window left by the previous variant was split from one
    -- whose global values were foreign, and showing a buffer in the target
    -- below starts its local values from its global ones.
    local target = vim.api.nvim_get_current_win()
    local saved_globals = {}
    for option in pairs(TARGET_WINDOW_OPTIONS) do
      saved_globals[option] = vim.api.nvim_get_option_value(option, { win = target, scope = "global" })
    end
    with_winborder("", function()
      set_window_options(target, TARGET_WINDOW_OPTIONS)

      -- The probe sees what a buffer recorded: a window with other options
      -- closing on a buffer of its own hands them to the next window opened on it.
      vim.cmd "vnew"
      local proof = vim.api.nvim_get_current_buf()
      set_window_options(0, FOREIGN_WINDOW_OPTIONS, "local")
      vim.cmd "close"
      vim.api.nvim_set_current_win(target)
      local recorded = foreign_options_a_new_window_opens_with(proof)
      vim.api.nvim_buf_delete(proof, { force = true })
      assert(
        vim.deep_equal(recorded, FOREIGN_WINDOW_OPTIONS),
        ("precondition, %s: a new window takes the options its buffer recorded, got %s"):format(
          variant.label,
          vim.inspect(recorded, { newline = " ", indent = "" })
        )
      )

      -- The current window shows another buffer, with options the target lacks.
      vim.cmd "vnew"
      local other = vim.api.nvim_get_current_win()
      set_window_options(other, FOREIGN_WINDOW_OPTIONS)
      -- Made from the current window, as `nvim_create_buf` or `:badd` would, and
      -- only then shown in the target: the buffer records no window showing it
      -- that a float opened on it could take its options from.
      local bufnr = vim.api.nvim_create_buf(true, false)
      local lines = {}
      for i = 1, TALL_BUFFER_LINES do
        lines[i] = ("line %03d"):format(i)
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modified = false
      vim.api.nvim_win_set_buf(target, bufnr)
      assert(vim.api.nvim_get_current_win() == other, "precondition: the current window is not the target")
      local before = {}
      for option in pairs(TARGET_WINDOW_OPTIONS) do
        before[option] = vim.api.nvim_get_option_value(option, { win = target })
      end
      assert(
        vim.deep_equal(before, TARGET_WINDOW_OPTIONS),
        ("precondition, %s: before the peek the target has its own options, got %s"):format(
          variant.label,
          vim.inspect(before, { newline = " ", indent = "" })
        )
      )

      local peek = numb.peek(target, 300, { style = "float" })
      the_float(("precondition, %s: the float peek opened a float"):format(variant.label))
      assert(vim.api.nvim_get_current_win() == other, "precondition: the peek left the current window current")
      peek:cancel()
      assert_no_float(("precondition, %s: cancel() closed the float"):format(variant.label))

      vim.api.nvim_set_current_win(target)
      local reopened = foreign_options_a_new_window_opens_with(bufnr)
      assert(
        vim.deep_equal(reopened, TARGET_WINDOW_OPTIONS),
        ("%s: after a float peek of a window that was not current, a new window on its buffer has the target's %s, got %s"):format(
          variant.label,
          vim.inspect(TARGET_WINDOW_OPTIONS, { newline = " ", indent = "" }),
          vim.inspect(reopened, { newline = " ", indent = "" })
        )
      )
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
    close_other_windows()
    -- `other` survives, split from a window with foreign global values: put
    -- back what the target started with so the next variant, and the next
    -- test, start clean.
    set_window_options(0, saved_globals)
  end
end

local OPTIONSET_DURING_FLOAT_TEARDOWN = [[
vim.opt.runtimepath:append(vim.fn.getcwd())
local numb = require "numb"
numb.setup { centered_peeking = false }
local lines = {}
for i = 1, 500 do
  lines[i] = ("line %03d"):format(i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_win_set_cursor(0, { 5, 0 })
-- Options a float copies from its target, set away from their defaults.
vim.wo.list = true
vim.wo.signcolumn = "yes"
vim.o.eventignore = "CursorMoved"
local report = {}
local fired = {}
local armed = false
vim.api.nvim_create_autocmd("OptionSet", {
  callback = function(event)
    if armed then
      table.insert(fired, event.match)
    end
  end,
})
local function floats()
  local found = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      found = found + 1
    end
  end
  return found
end
-- The counter sees an ordinary option being set.
armed = true
vim.wo.spell = true
armed = false
report.proof = fired
fired = {}
vim.wo.spell = false

local handle = numb.peek(0, 240, { style = "float" })
report.active = handle:is_active()
report.floats = floats()
armed = true
local ok, cancelled = pcall(handle.cancel, handle)
armed = false
report.call_ok = ok
report.call_error = not ok and tostring(cancelled) or nil
report.cancelled = ok and cancelled
report.floats_after = floats()
report.fired = fired
report.eventignore = vim.o.eventignore
io.stdout:write(vim.json.encode(report))
]]

-- In a child Neovim: OptionSet does not fire in this suite.
function Tests.float_teardown_fires_no_optionset()
  local report = run_optionset_child(OPTIONSET_DURING_FLOAT_TEARDOWN)

  assert(
    vim.deep_equal(report.proof, { "spell" }),
    ("precondition: the counter hears an ordinary option set, got %s"):format(vim.inspect(report.proof))
  )
  assert(report.active and report.floats == 1, "precondition: the float peek opened a float")
  assert(report.call_ok, ("cancel() must not raise: %s"):format(tostring(report.call_error)))
  assert(report.cancelled == true, "precondition: cancel() ended the live peek")
  assert(report.floats_after == 0, ("precondition: cancel() closed the float, %d left"):format(report.floats_after))
  assert(
    #report.fired == 0,
    ("closing a float fires no OptionSet at all, it fired for %s"):format(vim.inspect(report.fired))
  )
  assert(
    report.eventignore == "CursorMoved",
    ("the user's 'eventignore' is left as it was, got %q"):format(report.eventignore)
  )
end

function Tests.float_win_config_returned_table_is_not_changed_by_numb()
  -- One table, built once and returned every time, as a user holding their
  -- float configuration in a module would.
  local shared, snapshot
  local numb = configure {
    float = {
      win_config = function(win_config)
        if not shared then
          shared = vim.deepcopy(win_config)
          shared.border = "single"
          shared.style = "minimal"
          shared.noautocmd = true
          snapshot = vim.deepcopy(shared)
        end
        return shared
      end,
    },
  }
  with_winborder("", function()
    local target = float_split_of_height(20)
    local peek = numb.peek(target, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"
    assert(border_of(float)[4] ~= "", "precondition: the float has the single border win_config returned")
    assert(peek:update(300) == true, "precondition: update(300) moves the peek")
    peek:cancel()
    assert_no_float "precondition: cancel() closed the float"

    for _, key in ipairs { "style", "noautocmd", "border", "height", "row", "width" } do
      assert(
        vim.deep_equal(shared[key], snapshot[key]),
        ("numb leaves the table win_config returned alone: %s was %s, it is %s"):format(
          key,
          vim.inspect(snapshot[key]),
          vim.inspect(shared[key])
        )
      )
    end
  end)
  close_other_windows()
end

function Tests.float_style_switching_from_in_place_lays_the_float_out_against_the_restored_view()
  local numb = configure()
  with_winborder("", function()
    -- Shrunk to 3 rows, too few for a float, with the cursor on its last row.
    local target = float_split_of_height(20)
    vim.api.nvim_win_set_cursor(target, { 18, 0 })
    vim.api.nvim_win_set_height(target, 3)
    local origin_top, origin_cursor = topline_of(target), cursor_of(target)

    local peek = numb.peek(target, TALL_BUFFER_LINES, { style = "float" })
    assert_no_float "precondition: a 3-row window peeks in place"
    assert(cursor_of(target) == TALL_BUFFER_LINES, "precondition: in place, the cursor is on the last line")

    vim.api.nvim_win_set_height(target, 20)
    local rows = vim.fn.getwininfo(target)[1].height
    local frame_rows = math.floor(rows * 0.4) + 1
    local scrolled_row = winline_of(target)
    assert(
      scrolled_row > rows - frame_rows,
      ("precondition: in the view the in-place peek scrolled, the cursor is on row %d, under a bottom float"):format(
        scrolled_row
      )
    )

    assert(peek:update(300) == true, "update() returns true")

    local float = the_float "once the window is big enough, the float style floats"
    assert(
      topline_of(target) == origin_top and cursor_of(target) == origin_cursor,
      ("the target window is back on topline %d, cursor %d, it is on %d, %d"):format(
        origin_top,
        origin_cursor,
        topline_of(target),
        cursor_of(target)
      )
    )
    local restored_row = winline_of(target)
    assert(
      restored_row <= rows - frame_rows,
      ("precondition: in the restored view the cursor is on row %d, clear of a bottom float"):format(restored_row)
    )
    local edge = edge_of(float, target)
    assert(
      edge == "bottom",
      ("the float is laid out against the restored view, which leaves the bottom free, it is at %s"):format(edge)
    )
    peek:cancel()
    assert_no_float "nothing floats after cancel()"
  end)
  close_other_windows()
end

function Tests.float_update_after_the_target_switched_buffer_describes_the_floats_own_buffer()
  local numb = configure()
  with_winborder("", function()
    local scene = float_scene()
    local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
    local float = the_float "precondition: the float peek opened a float"

    local short = vim.api.nvim_create_buf(false, true)
    local short_lines = {}
    for i = 1, 50 do
      short_lines[i] = ("short %02d"):format(i)
    end
    vim.api.nvim_buf_set_lines(short, 0, -1, false, short_lines)
    vim.api.nvim_win_set_buf(scene.win, short)
    assert(peek:is_active(), "precondition: the peek outlives its target switching buffer")

    assert(peek:update(300) == true, "precondition: update(300) moves the peek")

    assert(vim.api.nvim_win_get_buf(float) == scene.bufnr, "the float still shows its own buffer")
    assert(cursor_of(float) == 300, ("the float shows line 300, it is on %d"):format(cursor_of(float)))
    local expected = (" 300/%d "):format(TALL_BUFFER_LINES)
    assert(
      title_of(float) == expected,
      ("the title counts the float's own buffer, %q, got %q"):format(expected, title_of(float))
    )
    peek:cancel()
    assert_no_float "nothing floats after cancel()"
  end)
end

-------------------------------------------------------------------------------
-- CONFIG VALIDATION TESTS
-------------------------------------------------------------------------------

local function capture_notifications(fn)
  local original_notify = vim.notify
  local messages = {}
  vim.notify = function(msg, level)
    table.insert(messages, { msg = tostring(msg), level = level })
  end
  local ok, err = pcall(fn)
  vim.notify = original_notify
  if not ok then
    error(err)
  end
  return messages
end

-- A `float.win_config` value for the rows below. Kept by reference, which is
-- what `vim.deep_equal` compares functions by.
local function keep_win_config(win_config)
  return win_config
end

-- What `numb.config` does with each shape of input, as a table. These need no
-- window, no buffer and no setup() call, which is what makes it cheap to state
-- every rule in one place instead of one test per rule.
local SANITIZE_CASES = {
  { label = "nil", input = nil, kept = {}, warnings = 0 },
  { label = "a string", input = "yes", kept = {}, warnings = 1 },
  { label = "a number", input = 42, kept = {}, warnings = 1 },
  { label = "a function", input = print, kept = {}, warnings = 1 },
  { label = "an empty table", input = {}, kept = {}, warnings = 0 },
  { label = "a valid option", input = { number_only = true }, kept = { number_only = true }, warnings = 0 },
  { label = "a misspelled option", input = { show_nubmers = true }, kept = {}, warnings = 1 },
  { label = "a wrongly typed option", input = { centered_peeking = "yes" }, kept = {}, warnings = 1 },
  {
    label = "one good option and one unknown",
    input = { range_peek = false, bogus = 1 },
    kept = { range_peek = false },
    warnings = 1,
  },
  {
    label = "two offenders",
    input = { nope = true, show_numbers = 1 },
    kept = {},
    warnings = 2,
  },
  -- The list options need more than a type check: `type({}) == type({ 1 })`, so
  -- comparing types alone would accept a list of numbers or a keyed table.
  {
    label = "an empty list option",
    input = { disable_for_filetype = {} },
    kept = { disable_for_filetype = {} },
    warnings = 0,
  },
  {
    label = "a list of filetypes",
    input = { disable_for_filetype = { "fugitive", "help" } },
    kept = { disable_for_filetype = { "fugitive", "help" } },
    warnings = 0,
  },
  { label = "a list of numbers", input = { disable_for_buftype = { 1, 2 } }, kept = {}, warnings = 1 },
  { label = "a keyed table", input = { disable_for_buftype = { terminal = true } }, kept = {}, warnings = 1 },
  { label = "a string where a list belongs", input = { disable_for_buftype = "terminal" }, kept = {}, warnings = 1 },
  -- `peek_style` is a string, but only three strings are an option.
  { label = "the float peek style", input = { peek_style = "float" }, kept = { peek_style = "float" }, warnings = 0 },
  { label = "the auto peek style", input = { peek_style = "auto" }, kept = { peek_style = "auto" }, warnings = 0 },
  { label = "a misspelled peek style", input = { peek_style = "flaot" }, kept = {}, warnings = 1 },
  { label = "a peek style that is not a string", input = { peek_style = true }, kept = {}, warnings = 1 },
  -- `float` is a table of its own options. Each bad subkey falls back alone, so
  -- every row with one carries a good one that must survive it.
  {
    label = "a float table",
    input = { float = { height = 0.5, position = "top", win_config = keep_win_config } },
    kept = { float = { height = 0.5, position = "top", win_config = keep_win_config } },
    warnings = 0,
  },
  {
    label = "a float height in rows",
    input = { float = { height = 6 } },
    kept = { float = { height = 6 } },
    warnings = 0,
  },
  { label = "float given as a list", input = { float = { 0.4, "top" } }, kept = {}, warnings = 1 },
  { label = "float given as a string", input = { float = "top" }, kept = {}, warnings = 1 },
  {
    label = "an unknown float option",
    input = { float = { foo = 1, height = 6 } },
    kept = { float = { height = 6 } },
    warnings = 1,
  },
  {
    label = "a float height of 0",
    input = { float = { height = 0, position = "top" } },
    kept = { float = { position = "top" } },
    warnings = 1,
  },
  {
    label = "a negative float height",
    input = { float = { height = -1, position = "top" } },
    kept = { float = { position = "top" } },
    warnings = 1,
  },
  {
    label = "a float height that is neither a fraction nor whole rows",
    input = { float = { height = 1.5, position = "top" } },
    kept = { float = { position = "top" } },
    warnings = 1,
  },
  {
    label = "a float height that is not a number",
    input = { float = { height = "half", position = "top" } },
    kept = { float = { position = "top" } },
    warnings = 1,
  },
  {
    label = "an unknown float position",
    input = { float = { position = "left", height = 6 } },
    kept = { float = { height = 6 } },
    warnings = 1,
  },
  {
    label = "a float win_config that is not a function",
    input = { float = { win_config = { border = "single" }, height = 6 } },
    kept = { float = { height = 6 } },
    warnings = 1,
  },
}

function Tests.config_sanitize_states_every_rule()
  local config = require "numb.config"
  local failures = {}
  for _, case in ipairs(SANITIZE_CASES) do
    local kept
    local messages = capture_notifications(function()
      kept = config.sanitize(case.input)
    end)
    if not vim.deep_equal(kept, case.kept) then
      table.insert(failures, ("%s: kept %s, expected %s"):format(case.label, vim.inspect(kept), vim.inspect(case.kept)))
    end
    if #messages ~= case.warnings then
      table.insert(failures, ("%s: %d warnings, expected %d"):format(case.label, #messages, case.warnings))
    end
  end
  assert(#failures == 0, "config.sanitize disagreed on:\n  " .. table.concat(failures, "\n  "))
end

function Tests.config_resolve_never_writes_through_to_the_defaults()
  local config = require "numb.config"
  local before = vim.deepcopy(config.DEFAULTS)
  local resolved = config.resolve { show_numbers = false, range_peek = false }
  -- Mutating what a caller was handed must not reconfigure everyone else, which
  -- is the failure mode a shared defaults table invites.
  resolved.show_cursorline = false
  assert(vim.deep_equal(config.DEFAULTS, before), "resolve() must not write through to the defaults")
  assert(config.resolve(nil).show_cursorline == true, "a later resolve must still see the real default")
end

function Tests.config_defaults_peek_in_the_window_with_a_float_ready()
  local resolved = require("numb.config").resolve(nil)
  assert(
    resolved.peek_style == "window",
    ("peek_style defaults to window, got %s"):format(vim.inspect(resolved.peek_style))
  )
  assert(
    type(resolved.float) == "table"
      and resolved.float.height == 0.4
      and resolved.float.position == "auto"
      and resolved.float.win_config == nil,
    ("float defaults to { height = 0.4, position = 'auto' }, got %s"):format(vim.inspect(resolved.float))
  )
end

function Tests.config_resolve_merges_float_options_over_their_defaults()
  local config = require "numb.config"
  local before = vim.deepcopy(config.DEFAULTS)
  local resolved = config.resolve { float = { height = 5 } }
  assert(resolved.float.height == 5, ("the given height is used, got %s"):format(vim.inspect(resolved.float)))
  assert(
    resolved.float.position == "auto",
    ("a float option left out keeps its default, got %s"):format(vim.inspect(resolved.float))
  )
  resolved.float.position = "top"
  assert(vim.deep_equal(config.DEFAULTS, before), "resolve() must not share the float table with the defaults")
  assert(config.resolve(nil).float.position == "auto", "a later resolve still sees the default position")
end

function Tests.config_bad_float_option_falls_back_alone_and_is_named()
  local config = require "numb.config"
  local resolved
  local messages = capture_notifications(function()
    resolved = config.resolve { float = { height = 0, position = "top", foo = true } }
  end)
  assert(#messages == 2, ("a bad height and an unknown key warn once each, got %s"):format(vim.inspect(messages)))
  local joined = table.concat({ messages[1].msg, messages[2].msg }, "\n")
  assert(joined:find("float.height", 1, true) ~= nil, ("the warning names float.height, got %q"):format(joined))
  assert(joined:find("float.foo", 1, true) ~= nil, ("the warning names float.foo, got %q"):format(joined))
  assert(resolved.float.height == 0.4, ("the bad height falls back to 0.4, got %s"):format(vim.inspect(resolved.float)))
  assert(resolved.float.position == "top", "the good position next to it is kept")
  assert(resolved.float.foo == nil, "the unknown key is dropped")
end

function Tests.config_unknown_option_warns_and_is_dropped()
  local numb = configure()
  local messages = capture_notifications(function()
    numb.setup { show_nubmers = true }
  end)
  assert(#messages == 1, ("unknown option must produce exactly one notification, got %d"):format(#messages))
  assert(
    messages[1].msg:find("show_nubmers", 1, true) ~= nil,
    ("message must name the offending key, got %q"):format(messages[1].msg)
  )
  assert(messages[1].level == vim.log.levels.WARN, "unknown option is a warning, not an error")
  assert(numb._state.opts.show_nubmers == nil, "unknown option must not be stored in opts")
end

function Tests.config_wrong_type_warns_and_keeps_default()
  local numb = configure()
  local messages = capture_notifications(function()
    numb.setup { centered_peeking = "yes" }
  end)
  assert(#messages == 1, ("wrong type must produce exactly one notification, got %d"):format(#messages))
  assert(
    messages[1].msg:find("centered_peeking", 1, true) ~= nil,
    ("message must name the offending key, got %q"):format(messages[1].msg)
  )
  assert(
    numb._state.opts.centered_peeking == true,
    ("rejected value must fall back to the default, got %s"):format(vim.inspect(numb._state.opts.centered_peeking))
  )
end

function Tests.config_non_table_argument_warns_and_keeps_defaults()
  local numb = configure()
  for _, bad in ipairs { "oops", 42, true } do
    local messages = capture_notifications(function()
      numb.setup(bad)
    end)
    assert(#messages == 1, ("a %s argument must warn exactly once, got %d"):format(type(bad), #messages))
    assert(messages[1].level == vim.log.levels.WARN, "a non-table argument is a warning, not an error")
    assert(numb._state.opts.centered_peeking == true, ("defaults kept for %s argument"):format(type(bad)))
    assert(numb._state.opts.show_numbers == true, ("defaults kept for %s argument"):format(type(bad)))
  end
end

function Tests.config_typo_and_wrong_type_together_are_both_reported()
  local numb = configure()
  -- The exact shape originally reported: a misspelled key and a wrongly typed
  -- value in one call.
  local messages = capture_notifications(function()
    numb.setup { show_nubmers = true, centered_peeking = "yes" }
  end)
  assert(#messages == 2, ("both problems must be reported, got %d"):format(#messages))
  -- Joined rather than indexed: pairs() ordering over the user table is not
  -- deterministic, so neither message has a guaranteed position.
  local joined = table.concat({ messages[1].msg, messages[2].msg }, "\n")
  assert(joined:find("show_nubmers", 1, true) ~= nil, ("typo key must be reported, got %q"):format(joined))
  assert(joined:find("centered_peeking", 1, true) ~= nil, ("wrong type must be reported, got %q"):format(joined))
  assert(numb._state.opts.show_nubmers == nil, "typo key must be dropped")
  assert(numb._state.opts.centered_peeking == true, "wrongly typed value falls back to the default")
end

function Tests.get_config_returns_the_active_options()
  local numb = configure { number_only = true }
  local config = numb.get_config()
  assert(type(config) == "table", "get_config() must return a table")
  assert(config.number_only == true, "get_config() must report the active value")
  assert(config.show_numbers == true, "get_config() must include defaults that were not overridden")
  for key in pairs(numb._state.opts) do
    assert(config[key] ~= nil, ("get_config() must include %s"):format(key))
  end
end

function Tests.get_config_returns_a_copy_not_the_live_table()
  local numb = configure()
  local config = numb.get_config()
  config.show_numbers = "tampered"
  assert(numb._state.opts.show_numbers == true, "mutating the returned table must not reconfigure the plugin")
  assert(numb.get_config().show_numbers == true, "a later call must not see the tampering either")
end

function Tests.config_valid_options_are_applied_without_warning()
  local numb = configure()
  local messages = capture_notifications(function()
    numb.setup { show_numbers = false, number_only = true, centered_peeking = false }
  end)
  assert(#messages == 0, ("valid config must not warn, got %s"):format(vim.inspect(messages)))
  assert(numb._state.opts.show_numbers == false, "show_numbers applied")
  assert(numb._state.opts.number_only == true, "number_only applied")
  assert(numb._state.opts.centered_peeking == false, "centered_peeking applied")
end

-------------------------------------------------------------------------------
-- ADDRESS SYNTAX TESTS
-------------------------------------------------------------------------------

function Tests.address_dollar_previews_the_last_line()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":$"
  assert(observed.peeking, "':$' must produce a peek")
  assert(observed.line == 40, ("':$' must preview the last line, got %d"):format(observed.line))
  assert_cursor(1, "aborting ':$' restores the original cursor")
end

function Tests.address_dollar_with_offset_previews_relative_to_the_end()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":$-3"
  assert(observed.peeking, "':$-3' must produce a peek")
  assert(observed.line == 37, ("':$-3' must preview line 37, got %d"):format(observed.line))
end

function Tests.address_dot_previews_the_current_line()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  local observed = probe_cmdline ":."
  assert(observed.peeking, "':.' must produce a peek")
  assert(observed.line == 12, ("':.' must preview the current line, got %d"):format(observed.line))
end

function Tests.address_dot_with_offset_previews_a_relative_line()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  local observed = probe_cmdline ":.+5"
  assert(observed.peeking, "':.+5' must produce a peek")
  assert(observed.line == 15, ("':.+5' must preview line 15, got %d"):format(observed.line))
end

function Tests.address_dollar_is_clamped_to_the_buffer()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":$+10"
  assert(observed.line == 40, ("beyond the last line must clamp to 40, got %d"):format(observed.line))
end

function Tests.address_dollar_confirmed_jumps_to_the_last_line()
  local numb = configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = confirm_cmdline ":$"
  -- Vim performs the ':$' jump itself, so the cursor assertion below holds even
  -- with the plugin uninstalled. The preview is the part that is numb's, which
  -- is why it is asserted first.
  assert(observed.peeking, "':$' must peek while it is being typed")
  assert(observed.line == 40, ("':$' must preview the last line, got %d"):format(observed.line))
  assert_cursor(40, "confirming ':$' lands on the last line")
  assert(not numb.is_peeking(), "the peek must be over once the command has run")
end

function Tests.address_too_large_previews_the_last_line()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Consistent with `:999`, which the plugin deliberately clamps rather than
  -- letting Vim reject it.
  local observed = probe_cmdline ":99999999999999999999"
  assert(observed.peeking, "an enormous address must still peek")
  assert(observed.line == 40, ("it must clamp to the last line, got %d"):format(observed.line))
end

function Tests.address_repeated_symbol_does_not_preview()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  -- Vim rejects ':..' with E492 and never moves, so a preview would promise a
  -- jump that cannot happen.
  local observed = probe_cmdline ":.."
  assert(not observed.peeking, "':..' must not peek")
  assert_cursor(20, "and must leave the cursor alone")
end

function Tests.address_non_address_command_does_not_preview()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local observed = probe_cmdline ":help numb"
  assert(not observed.peeking, "a command that is not an address must not peek")
  assert_cursor(5, "cursor untouched by a non-address command")
end

-------------------------------------------------------------------------------
-- DISABLE FILTER TESTS
-------------------------------------------------------------------------------

function Tests.disable_filter_skips_an_excluded_buftype()
  configure { disable_for_buftype = { "nofile" } }
  reset_buffer()
  vim.bo.buftype = "nofile"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":15"
  assert(not observed.peeking, "an excluded buftype must not peek")
  assert_cursor(1, "the cursor stays put in an excluded buffer")
end

function Tests.disable_filter_skips_an_excluded_filetype()
  configure { disable_for_filetype = { "fugitive" } }
  reset_buffer()
  vim.bo.filetype = "fugitive"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":15"
  assert(not observed.peeking, "an excluded filetype must not peek")
  assert_cursor(1, "the cursor stays put in an excluded buffer")
end

function Tests.disable_filter_is_empty_by_default()
  local numb = configure()
  reset_buffer()
  -- Asserted on the configuration itself, because a buffer can only stand in for
  -- one buftype at a time and the default that matters is that the lists are
  -- empty. Excluding `terminal` was considered and measured against: Vim performs
  -- `:15` in a terminal buffer exactly as it does elsewhere, so excluding it by
  -- default would leave that jump with no preview.
  local active = numb.get_config()
  assert(#active.disable_for_buftype == 0, "no buftype may be excluded out of the box")
  assert(#active.disable_for_filetype == 0, "no filetype may be excluded out of the box")
  vim.bo.buftype = "nofile"
  vim.bo.filetype = "help"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":15"
  assert(observed.peeking, "with empty lists every buffer must still peek")
  assert(observed.line == 15, ("line 15 must be previewed, got %d"):format(observed.line))
end

function Tests.disable_filter_matches_only_the_listed_names()
  configure { disable_for_buftype = { "terminal" }, disable_for_filetype = { "fugitive" } }
  reset_buffer()
  vim.bo.buftype = "nofile"
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":15"
  assert(observed.peeking, "a buffer matching neither list must peek as usual")
  assert(observed.line == 15, ("line 15 must be previewed, got %d"):format(observed.line))
end

function Tests.disable_filter_leaves_no_state_behind()
  local numb = configure { disable_for_buftype = { "nofile" } }
  reset_buffer()
  vim.bo.buftype = "nofile"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Confirmed rather than aborted: a guard that returns before saving state must
  -- also leave the teardown on CmdlineLeave with nothing to restore.
  run_cmd ":15\r"
  drain_scheduled()
  assert(vim.tbl_isempty(numb._state.win_states), "a skipped buffer must not leave saved state")
  assert(numb._state.peek_cursor == nil, "and must not leave a pending target")
end

-------------------------------------------------------------------------------
-- ADDRESS RESOLUTION UNIT TESTS
--
-- `numb.address` is pure: it takes the command line, the line a relative offset
-- counts from and the last line of the buffer, and returns what to preview. So
-- these cases need no window, no buffer and no command line, which is what makes
-- it affordable to cover the shapes that a feedkeys round trip makes expensive.
-------------------------------------------------------------------------------

-- Each case is { command line as getcmdline() gives it, so with no leading
-- colon, base line, last line, expected }.
-- `expected` is nil for "do not preview", { line } for a single address, or
-- { line, first, last } for a range. Every range case here was measured against
-- native Vim first; see the separator cases in particular.
local RESOLVE_CASES = {
  -- single addresses
  { "5", 1, 40, { line = 5 } },
  { "42", 1, 40, { line = 42 } },
  { "$", 1, 40, { line = 40 } },
  { "$-3", 1, 40, { line = 37 } },
  { ".", 20, 40, { line = 20 } },
  { ".+5", 20, 40, { line = 25 } },
  { "+5", 10, 40, { line = 15 } },
  { "-3", 10, 40, { line = 7 } },
  { "++", 5, 40, { line = 7 } },
  { "--", 10, 40, { line = 8 } },
  { "+2+3", 10, 40, { line = 15 } },
  { "10+5", 1, 40, { line = 15 } },
  { "5w", 1, 40, { line = 5 } },
  -- ranges, the second address relative to the cursor after a comma
  { "5,10d", 1, 40, { line = 5, first = 5, last = 10 } },
  { "10,5d", 1, 40, { line = 5, first = 10, last = 5 } },
  { ".,+5y", 20, 40, { line = 20, first = 20, last = 25 } },
  { "30,$d", 1, 40, { line = 30, first = 30, last = 40 } },
  { "5,+3d", 20, 40, { line = 5, first = 5, last = 23 } },
  -- Ex acts on the last two addresses when more are given, and `;` moves the
  -- line that following offsets count from. Measured: `:5,10,15d` deletes
  -- 10..15, `:5;+3d` deletes 5..8, `:5,10;+2d` deletes 10..12 and
  -- `:5;+3,+6d` deletes 8..11.
  { "5,10,15d", 1, 40, { line = 10, first = 10, last = 15 } },
  { "5;10;15d", 1, 40, { line = 10, first = 10, last = 15 } },
  { "5;+3d", 1, 40, { line = 5, first = 5, last = 8 } },
  { "5,10;+2d", 1, 40, { line = 10, first = 10, last = 12 } },
  { "5;+3,+6d", 1, 40, { line = 8, first = 8, last = 11 } },
  -- An Ex address is one base followed by signed offsets. A second `.` or `$`,
  -- or digits after an offset, is not an address, and Vim says so: `:..`, `:$$`,
  -- `:5..10` and `:$-$` are all E492. Previewing a line for them would answer a
  -- command that is never going to run.
  { "..", 20, 40, nil },
  { "$$", 20, 40, nil },
  { "5..10", 20, 40, nil },
  { "$-$", 20, 40, nil },
  { ".$", 20, 40, nil },
  { "5.5", 20, 40, nil },
  -- Vim accepts a bare run of signs and stays put, so these do resolve.
  { "+-", 20, 40, { line = 20 } },
  { "-+", 20, 40, { line = 20 } },
  -- nothing this module can resolve
  { "help numb", 5, 40, nil },
  { "'a,'bd", 20, 40, nil },
  { "%s/a/b/", 20, 40, nil },
  { "w", 1, 40, nil },
  { "", 1, 40, nil },
  -- A trailing separator with nothing after it is not an address chain, so it
  -- stays with whatever follows rather than being swallowed.
  { "5,", 1, 40, { line = 5 } },
}

local function describe_target(target)
  if target == nil then
    return "nil"
  end
  if target.first then
    return ("{ line = %d, first = %d, last = %d }"):format(target.line, target.first, target.last)
  end
  return ("{ line = %d }"):format(target.line)
end

function Tests.address_resolve_covers_every_supported_shape()
  local address = require "numb.address"
  local failures = {}
  for _, case in ipairs(RESOLVE_CASES) do
    local cmdline, base_line, last_line, expected = case[1], case[2], case[3], case[4]
    local actual = address.resolve(cmdline, base_line, last_line, false)
    local same = (expected == nil and actual == nil)
      or (
        expected ~= nil
        and actual ~= nil
        and actual.line == expected.line
        and actual.first == expected.first
        and actual.last == expected.last
      )
    if not same then
      table.insert(
        failures,
        ("':%s' with base %d: expected %s, got %s"):format(
          cmdline,
          base_line,
          describe_target(expected),
          describe_target(actual)
        )
      )
    end
  end
  assert(#failures == 0, "address.resolve disagreed on:\n  " .. table.concat(failures, "\n  "))
end

function Tests.address_resolve_survives_an_address_too_large_to_count()
  local address = require "numb.address"
  -- Twenty digits arrive as a float rather than an integer, which is fine: it
  -- clamps to the last line like `:999` does. Guarded because arithmetic that
  -- converted to an integer instead would overflow to the most negative one and
  -- land on line 1, the opposite end of the buffer from where this belongs.
  local target = address.resolve("99999999999999999999", 20, 40, false)
  assert(target ~= nil, "an enormous but well formed address must still resolve")
  assert(target.line > 40, ("it must point past the buffer, got %d"):format(target.line))
end

function Tests.address_resolve_honours_number_only()
  local address = require "numb.address"
  -- number_only means the command line has to be nothing but the addresses, so
  -- a trailing command suppresses the preview entirely.
  assert(address.resolve("15", 1, 40, true) ~= nil, "':15' is only a number")
  assert(address.resolve("15,20", 1, 40, true) ~= nil, "':15,20' is only addresses")
  assert(address.resolve("15w", 1, 40, true) == nil, "':15w' carries a command")
  assert(address.resolve("15,20d", 1, 40, true) == nil, "':15,20d' carries a command")
  assert(address.resolve("5,", 1, 40, true) == nil, "':5,' has a trailing separator")
end

function Tests.address_resolve_needs_the_last_line_for_the_dollar_symbol()
  local address = require "numb.address"
  -- `$` cannot be resolved without knowing where the buffer ends, and guessing
  -- would preview the wrong line, so it declines instead.
  assert(address.resolve("$", 1, nil, false) == nil, "'$' without a last line must not resolve")
  assert(address.resolve("10,$d", 1, nil, false) == nil, "'$' as an endpoint must not resolve either")
end

-------------------------------------------------------------------------------
-- HEALTH CHECK TESTS
-------------------------------------------------------------------------------

-- Stub `vim.health` and run the check, so the report can be asserted on rather
-- than eyeballed. Re-raises, so a health check that throws fails the test.
local function capture_health()
  local original = vim.health
  local records = {}
  local function record(level)
    return function(msg, advice)
      table.insert(records, { level = level, msg = tostring(msg), advice = advice })
    end
  end
  vim.health = {
    start = record "start",
    info = record "info",
    ok = record "ok",
    warn = record "warn",
    error = record "error",
  }
  local ok, err = pcall(require("numb.health").check)
  vim.health = original
  if not ok then
    error(err)
  end
  return records
end

local function health_entries(records, level)
  return vim.tbl_filter(function(entry)
    return entry.level == level
  end, records)
end

local function health_matches(records, level, pattern)
  for _, entry in ipairs(health_entries(records, level)) do
    if entry.msg:find(pattern) then
      return entry
    end
  end
  return nil
end

function Tests.health_check_runs_and_opens_a_section()
  configure()
  local records = capture_health()
  assert(#records > 0, "the health check must report something")
  assert(health_matches(records, "start", "numb%.nvim") ~= nil, "the report must open a numb.nvim section")
end

function Tests.health_reports_ok_when_enabled()
  configure()
  local records = capture_health()
  assert(health_matches(records, "ok", "Enabled") ~= nil, "an enabled plugin must report ok")
  assert(#health_entries(records, "error") == 0, "an enabled plugin must report no errors")
end

function Tests.health_reports_the_user_command_only_while_enabled()
  local numb = configure()
  local records = capture_health()
  -- Missing from the report entirely is the failure this guards: reporting the
  -- command is conditional, and reading the condition off an undefined local
  -- silently drops the line rather than raising.
  assert(
    health_matches(records, "ok", ":Numb` user command is registered") ~= nil,
    "an enabled plugin must report that :Numb is registered"
  )

  numb.disable()
  local disabled_records = capture_health()
  assert(
    health_matches(disabled_records, "ok", ":Numb` user command") == nil,
    "a disabled plugin must not repeat the command state; the disable warning already said why"
  )
  assert(
    health_matches(disabled_records, "warn", "unavailable") == nil,
    "and must not warn about the command either, since disable() leaves it installed"
  )
  numb.enable()
end

function Tests.health_warns_rather_than_errors_when_deliberately_disabled()
  local numb = configure()
  numb.disable()
  local records = capture_health()
  assert(health_matches(records, "warn", "Disabled via") ~= nil, "disabling on purpose must warn")
  assert(
    #health_entries(records, "error") == 0,
    "a user who turned numb off on purpose must not be told something is broken"
  )
end

function Tests.health_errors_when_setup_was_never_called()
  local numb = configure()
  numb.disable()
  -- `:Numb` outliving disable() is exactly what separates "off on purpose" from
  -- "never set up", so it has to go for this branch to be reachable at all.
  pcall(vim.api.nvim_del_user_command, "Numb")
  local records = capture_health()
  assert(
    health_matches(records, "error", "never been called") ~= nil,
    "a plugin that was never set up must report an error"
  )
end

function Tests.health_reports_every_configured_option()
  local numb = configure { number_only = true }
  local records = capture_health()
  local infos = health_entries(records, "info")
  for key in pairs(numb._state.opts) do
    local reported = false
    for _, entry in ipairs(infos) do
      if entry.msg:find("^" .. key .. " = ") then
        reported = true
      end
    end
    assert(reported, ("the config report must include %s"):format(key))
  end
  assert(health_matches(records, "info", "number_only = true") ~= nil, "reported values must be the active ones")
end

function Tests.health_errors_when_the_augroup_was_cleared()
  configure()
  vim.api.nvim_del_augroup_by_name "numb"
  local records = capture_health()
  assert(
    health_matches(records, "error", "augroup is gone") ~= nil,
    "a cleared augroup must be reported even though is_enabled() still returns true"
  )
end

function Tests.health_does_not_depend_on_internal_state_for_the_config()
  local numb = configure { number_only = true }
  local original_state = numb._state
  numb._state = nil
  local records = capture_health()
  numb._state = original_state
  -- capture_health re-raises, so getting here at all proves it did not throw.
  assert(
    health_matches(records, "info", "number_only = true") ~= nil,
    "the config report must come from the public getter, not from numb._state"
  )
end

function Tests.health_warns_about_a_float_left_open_by_an_ended_peek()
  local numb = configure()
  float_scene()
  local peek = numb.peek(0, FLOAT_TARGET, { style = "float" })
  local float = the_float "precondition: the float peek opened a float"
  local id = tostring(float)
  local function reported(records)
    for _, entry in ipairs(health_entries(records, "warn")) do
      if entry.msg:find "[Ff]loat" and entry.msg:find(id, 1, true) then
        return entry
      end
    end
    return nil
  end
  assert(reported(capture_health()) == nil, "precondition: the float of the live peek is not reported")

  local ok, err = pcall(function()
    -- The peek is no longer live but its float is still registered and open,
    -- as when a teardown is cut short.
    numb._state.active = nil
    assert(vim.api.nvim_win_is_valid(float), "precondition: the float is still open")
    local records = capture_health()
    assert(
      reported(records) ~= nil,
      ("health warns about float %s left open, got %s"):format(id, vim.inspect(health_entries(records, "warn")))
    )
  end)
  numb.disable()
  close_floats()
  numb.enable()
  if not ok then
    error(err, 0)
  end
  assert(not peek:is_active(), "the ended peek stays inactive")
end

-------------------------------------------------------------------------------
-- RANGE PEEK TESTS
-------------------------------------------------------------------------------

local function assert_range(observed, expected_first, expected_last, label)
  assert(observed.range ~= nil, ("%s: expected a highlighted range, got none"):format(label))
  assert(
    observed.range.count == 1,
    ("%s: a range must be exactly one extmark, found %d"):format(label, observed.range.count)
  )
  assert(
    observed.range[1] == expected_first and observed.range[2] == expected_last,
    ("%s: expected range %d..%d, got %d..%d"):format(
      label,
      expected_first,
      expected_last,
      observed.range[1],
      observed.range[2]
    )
  )
end

function Tests.range_peek_highlights_the_whole_range()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":5,10d"
  assert_range(observed, 5, 10, "':5,10d'")
  -- The lower bound is previewed so the start of the range is on screen. For
  -- `:d` that also happens to be where Vim leaves the cursor; for `:y`, `:m`,
  -- `:t` and `:s` it is not, so this asserts a deliberate choice.
  assert(observed.line == 5, ("the start line must be previewed, got %d"):format(observed.line))
end

function Tests.range_peek_swaps_reversed_bounds()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":10,5d"
  assert_range(observed, 5, 10, "':10,5d'")
end

function Tests.range_peek_uses_the_last_two_of_three_addresses()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Measured against native Vim: ':5,10,15d' deletes 10 through 15, because Ex
  -- uses the last two addresses when more are given. Highlighting 5 through 10
  -- would mark six lines that survive and leave the six that do not unmarked,
  -- which is worse than showing nothing.
  local observed = probe_cmdline ":5,10,15d"
  assert_range(observed, 10, 15, "':5,10,15d'")
  assert(observed.line == 10, ("the effective range starts at 10, previewed %d"):format(observed.line))
end

function Tests.range_peek_semicolon_rebases_the_next_address()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Measured: ':5;+3d' deletes 5 through 8. A semicolon moves the line that
  -- following offsets count from onto the address before it.
  local observed = probe_cmdline ":5;+3d"
  assert_range(observed, 5, 8, "':5;+3d'")
end

function Tests.range_peek_comma_does_not_rebase_the_next_address()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  -- The discriminator for the test above: measured, ':5,+3d' from line 20
  -- deletes 5 through 23, so the offset is still counted from the cursor. If
  -- both separators were treated alike, one of these two tests would fail.
  local observed = probe_cmdline ":5,+3d"
  assert_range(observed, 5, 23, "':5,+3d' from line 20")
end

function Tests.range_peek_mixed_separators_follow_ex_semantics()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Measured: ':5;+3,+6d' deletes 8 through 11. The semicolon rebases onto 5 so
  -- '+3' is 8, the comma keeps that base so '+6' is 11, and the last two
  -- addresses win.
  local observed = probe_cmdline ":5;+3,+6d"
  assert_range(observed, 8, 11, "':5;+3,+6d'")
end

function Tests.range_peek_resolves_relative_endpoints()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  local observed = probe_cmdline ":.,+5y"
  assert_range(observed, 20, 25, "':.,+5y'")
end

function Tests.range_peek_resolves_the_last_line_symbol()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":30,$d"
  assert_range(observed, 30, 40, "':30,$d'")
end

function Tests.range_peek_clamps_to_the_buffer()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":30,999d"
  assert_range(observed, 30, 40, "':30,999d'")
end

function Tests.closing_the_peeking_window_clears_its_range_highlight()
  local numb = configure()
  reset_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  -- Two windows on one buffer, typing in the one that gets closed. The extmark
  -- belongs to the buffer, so it outlives its window unless something clears it,
  -- and closing a window while the command line is open really happens: any
  -- plugin closing a float from a timer does it.
  local doomed = create_split()
  vim.api.nvim_win_set_cursor(doomed, { 1, 0 })

  local observed = {}
  local group = vim.api.nvim_create_augroup("numb_test_window_close", { clear = true })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = group,
    pattern = ":",
    callback = function()
      -- Only once the whole range is typed. Firing on the first keystroke would
      -- close the window before there is any highlight to leave behind, and the
      -- test would pass without proving anything.
      if vim.fn.getcmdline() ~= "5,10d" or observed.while_typing then
        return
      end
      observed.while_typing = highlighted_range(bufnr)
      vim.api.nvim_win_close(doomed, true)
    end,
  })

  feedkeys ":5,10d<C-c>"
  wait_until_idle()
  vim.api.nvim_del_augroup_by_id(group)
  drain_scheduled()
  close_other_windows()

  assert(observed.while_typing ~= nil, "the range must have been highlighted before the window was closed")
  assert(highlighted_range(bufnr) == nil, "closing the peeking window must clear the range it highlighted")
  assert(vim.tbl_count(numb._state.win_states) == 0, "and must not leave saved state behind")
end

function Tests.range_peek_clears_the_highlight_on_abort()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":5,10d"
  assert_range(observed, 5, 10, "while typing")
  assert(highlighted_range(0) == nil, "the highlight must be gone once the command line is abandoned")
end

function Tests.range_peek_clears_the_highlight_on_confirm()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- Asserting that the highlight was there first is what stops this from
  -- passing when the highlight is never drawn at all.
  local observed = confirm_cmdline ":5,10y"
  assert_range(observed, 5, 10, "while typing")
  drain_scheduled(200)
  assert(highlighted_range(0) == nil, "the highlight must be gone once the command has run")
end

function Tests.range_peek_shrinks_as_the_range_is_retyped()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- ":5,1" then ":5,12": the highlight must track the latest range, not accumulate.
  local observed = probe_cmdline ":5,12d"
  assert_range(observed, 5, 12, "':5,12d' after passing through ':5,1'")
end

function Tests.range_peek_unsupported_syntax_falls_through()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  local observed = probe_cmdline ":'a,'bd"
  assert(observed.range == nil, "a mark range must be left to native Vim, unhighlighted")
  assert(not observed.peeking, "a mark range must not peek either")
end

function Tests.range_peek_disabled_keeps_the_single_line_peek()
  configure { range_peek = false }
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":5,10d"
  assert(observed.range == nil, "range_peek = false must not highlight")
  assert(observed.peeking, "the single line peek must still happen")
  assert(observed.line == 5, ("the start line is still previewed, got %d"):format(observed.line))
end

function Tests.enable_without_setup_defines_the_range_highlight()
  -- A child process is the only honest way to check this. Once setup() has run,
  -- Neovim remembers NumbRange's default definition for the rest of the session
  -- and even `highlight clear` restores it, so the "never defined" state this is
  -- about cannot be recreated in process.
  local child = table.concat({
    "vim.opt.runtimepath:append(vim.fn.getcwd())",
    -- enable() rather than setup(): that is the path a config takes when it sets
    -- vim.g.loaded_numb to keep plugin/numb.lua from auto-configuring.
    "require('numb').enable {}",
    "io.stdout:write(vim.inspect(vim.api.nvim_get_hl(0, { name = 'NumbRange' })))",
  }, "\n")
  -- Written to a file rather than piped in. `nvim -l /dev/stdin` works on some
  -- machines and fails on others with "cannot open /dev/stdin", because whether
  -- that path can be opened depends on how the pipe was set up.
  local script = vim.fn.tempname()
  vim.fn.writefile(vim.split(child, "\n"), script)
  local output = vim.fn.system { "nvim", "--headless", "--clean", "-l", script }
  local failed = vim.v.shell_error ~= 0
  vim.fn.delete(script)
  assert(not failed, ("the child Neovim failed: %s"):format(output))
  assert(
    output:find 'link = "Visual"',
    ("enable() must define NumbRange, or the range preview is invisible; child reported %s"):format(output)
  )
end

function Tests.range_peek_highlight_group_is_overridable()
  configure()
  -- `default = true` on the plugin's definition means a user's own NumbRange
  -- survives setup(), which is what lets people theme it.
  vim.api.nvim_set_hl(0, "NumbRange", { bg = "#123456" })
  require("numb").setup { centered_peeking = false }
  local hl = vim.api.nvim_get_hl(0, { name = "NumbRange" })
  assert(hl.bg == tonumber("123456", 16), "a user defined NumbRange must not be overwritten by setup()")
  -- Restore the link rather than clearing the group. `default = true` is a
  -- condition on the set, not a property that can be put back: once NumbRange
  -- has any explicit definition, including an empty one, a defaulted set is
  -- ignored. Clearing here would leave the range highlight invisible for every
  -- test that runs after this one.
  vim.api.nvim_set_hl(0, "NumbRange", { link = "Visual" })
end

local M = {}

-- The suite is launched with `+qall`, which blocks on E37 while any buffer is
-- still modified. A hanging job is far worse than a failing one, so no test is
-- allowed to leave a dirty buffer behind regardless of how it exited.
local function clear_modified_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
      vim.bo[bufnr].modified = false
    end
  end
end

-- Put the editor back to one window on a clean buffer after every test. Isolation
-- otherwise rests entirely on the next test calling configure() first, and a test
-- that fails halfway leaves a split open or a buffer dirty, so the failure that
-- gets reported is a cascade of later tests rather than the one that broke.
-- Everything is wrapped, because a teardown that raises would mask the real
-- failure it is cleaning up after.
local function reset_environment()
  clear_modified_buffers()
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "silent! enew!")
end

-- Run tests in sorted order for deterministic execution
function M.run()
  local names = {}
  for name in pairs(Tests) do
    table.insert(names, name)
  end
  table.sort(names)

  -- Collect every failure instead of stopping at the first one, so a single run
  -- reports the full picture. Still errors at the end so CI sees a non-zero exit.
  local failures = {}
  for _, name in ipairs(names) do
    local fn = Tests[name]
    local ok, err = pcall(fn)
    reset_environment()
    if ok then
      vim.api.nvim_echo({ { ("[numb test] %s passed"):format(name), "None" } }, false, {})
    else
      table.insert(failures, ("[numb test] %s FAILED: %s"):format(name, err))
      vim.api.nvim_echo({ { failures[#failures], "ErrorMsg" } }, false, {})
    end
  end

  clear_modified_buffers()

  if #failures > 0 then
    local report = ("%d of %d numb tests failed:\n%s"):format(#failures, #names, table.concat(failures, "\n"))
    if #vim.api.nvim_list_uis() == 0 then
      -- Headless, so this is CI or scripts/check.sh. Raising here is not enough:
      -- nvim reports the error, then the `+qall` that follows on the command
      -- line exits 0 anyway, so a failing suite would report success. `cquit`
      -- is the only way to hand a non-zero status back to the shell.
      -- `nvim_err_writeln` is soft-deprecated but kept deliberately: its
      -- replacement, `nvim_echo(..., { err = true })`, is 0.11+, and plain
      -- `nvim_echo` writes to stdout, which would mix the failure report into
      -- the pass log. Revisit only when the supported floor moves past 0.10.
      vim.api.nvim_err_writeln(report)
      vim.cmd "cquit 1"
    end
    error(report)
  end
  print(("All numb tests passed (%d)"):format(#names))
end

return M
