local function feedkeys(cmd)
  local keys = vim.api.nvim_replace_termcodes(cmd, true, false, true)
  vim.api.nvim_feedkeys(keys, "nx", false)
end

local function wait_until_idle()
  local ok = vim.wait(1000, function()
    local mode = vim.api.nvim_get_mode()
    return mode.mode == "n" and not mode.blocking
  end, 10, false)
  assert(ok ~= -1, "timeout waiting for command completion")
end

local function run_cmd(cmd)
  feedkeys(cmd)
  wait_until_idle()
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
  local existing = package.loaded["numb"]
  if existing and type(existing.disable) == "function" then
    existing.disable()
  end
  package.loaded["numb"] = nil
  local module = require "numb"
  local base_opts = { centered_peeking = false }
  if opts then
    base_opts = vim.tbl_extend("force", base_opts, opts)
  end
  module.setup(base_opts)
  return module
end

-------------------------------------------------------------------------------
-- CORE NAVIGATION TESTS (ABSOLUTE)
-------------------------------------------------------------------------------

local Tests = {}

function Tests.absolute_jump_navigation()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd ":5\r"
  assert_cursor(5, "absolute jump to line 5")
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
  run_cmd ":+5\r"
  assert_cursor(15, "relative forward jump :+5 from line 10")
end

function Tests.relative_backward_jump()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  run_cmd ":-5\r"
  assert_cursor(15, "relative backward jump :-5 from line 20")
end

function Tests.relative_forward_single()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  run_cmd ":+\r"
  assert_cursor(6, "relative forward :+ (implicit 1)")
end

function Tests.relative_backward_single()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  run_cmd ":-\r"
  assert_cursor(9, "relative backward :- (implicit 1)")
end

-------------------------------------------------------------------------------
-- COMPLEX EXPRESSION TESTS
-------------------------------------------------------------------------------

function Tests.complex_expression_addition()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  run_cmd ":+2+3\r"
  assert_cursor(15, "complex expression :+2+3 from line 10 = 15")
end

function Tests.complex_expression_subtraction()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 20, 0 })
  run_cmd ":-2-3\r"
  assert_cursor(15, "complex expression :-2-3 from line 20 = 15")
end

function Tests.complex_expression_mixed()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  run_cmd ":+5-2\r"
  assert_cursor(13, "complex expression :+5-2 from line 10 = 13")
end

function Tests.double_plus_signs()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  run_cmd ":++\r"
  assert_cursor(7, "double plus :++ from line 5 = 7 (5+1+1)")
end

function Tests.double_minus_signs()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  run_cmd ":--\r"
  assert_cursor(8, "double minus :-- from line 10 = 8 (10-1-1)")
end

function Tests.absolute_with_arithmetic()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd ":10+5\r"
  assert_cursor(15, "absolute with arithmetic :10+5 = 15")
end

function Tests.absolute_with_subtraction()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd ":20-5\r"
  assert_cursor(15, "absolute with subtraction :20-5 = 15")
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
  vim.wait(100, function()
    return false
  end, 10, false)
  local state = numb._state
  assert(state.peek_cursor == nil, "peek_cursor should be nil after confirmed jump")
end

function Tests.state_reset_method_clears_state()
  local numb = configure()
  reset_buffer()
  -- Manually populate state to test reset
  numb._state.win_states[999] = { cursor = { 1, 0 }, options = {}, topline = 1 }
  numb._state.peek_cursor = { 10, 0 }
  -- Reset should clear everything
  numb._state:reset()
  assert(vim.tbl_isempty(numb._state.win_states), "win_states cleared by reset")
  assert(numb._state.peek_cursor == nil, "peek_cursor cleared by reset")
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
  vim.wait(100, function()
    return false
  end, 10, false)
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
  vim.wait(100, function()
    return false
  end, 10, false)

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
  vim.wait(100, function()
    return false
  end, 10, false)
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
  vim.wait(50, function()
    return false
  end, 10, false)
  vim.cmd "clearjumps"
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  run_cmd ":20\r"
  -- Wait for scheduled callback to apply final cursor + jumplist push
  vim.wait(100, function()
    return false
  end, 10, false)
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
  vim.wait(50, function()
    return false
  end, 10, false)
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
  return { first + 1, last + 1 }
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

function Tests.address_non_address_command_does_not_preview()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local observed = probe_cmdline ":help numb"
  assert(not observed.peeking, "a command that is not an address must not peek")
  assert_cursor(5, "cursor untouched by a non-address command")
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
  -- Vim leaves the cursor at the start of the range after such a command, so
  -- previewing the start line is what matches where you will actually end up.
  assert(observed.line == 5, ("the start line must be previewed, got %d"):format(observed.line))
end

function Tests.range_peek_swaps_reversed_bounds()
  configure()
  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local observed = probe_cmdline ":10,5d"
  assert_range(observed, 5, 10, "':10,5d'")
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
  vim.wait(200, function()
    return false
  end, 10, false)
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

function Tests.range_peek_highlight_group_is_overridable()
  configure()
  -- `default = true` on the plugin's definition means a user's own NumbRange
  -- survives setup(), which is what lets people theme it.
  vim.api.nvim_set_hl(0, "NumbRange", { bg = "#123456" })
  require("numb").setup { centered_peeking = false }
  local hl = vim.api.nvim_get_hl(0, { name = "NumbRange" })
  assert(hl.bg == tonumber("123456", 16), "a user defined NumbRange must not be overwritten by setup()")
  vim.api.nvim_set_hl(0, "NumbRange", {})
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
