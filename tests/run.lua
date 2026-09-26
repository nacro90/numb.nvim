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
