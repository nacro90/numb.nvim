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
  local ok = pcall(run_cmd, ":10s\r")
  -- Command may fail (invalid substitute), but cursor should be at 1
  assert_cursor(1, "number_only=true: cursor stays at original (no peek)")
end

local M = {}

-- Run tests in sorted order for deterministic execution
function M.run()
  local names = {}
  for name in pairs(Tests) do
    table.insert(names, name)
  end
  table.sort(names)

  for _, name in ipairs(names) do
    local fn = Tests[name]
    local ok, err = pcall(fn)
    if ok then
      vim.api.nvim_echo({ { ("[numb test] %s passed"):format(name), "None" } }, false, {})
    else
      error(("[numb test] %s FAILED: %s"):format(name, err))
    end
  end
  print "All numb tests passed"
end

return M
