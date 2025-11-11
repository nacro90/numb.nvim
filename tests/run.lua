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

local function reset_buffer()
  vim.cmd "enew!"
  local lines = {}
  for i = 1, 20 do
    lines[i] = string.format("line %02d", i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
end

local function assert_cursor(expected, label)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  assert(line == expected, ("%s: expected line %d, got %d"):format(label, expected, line))
end

local M = {}

function M.run()
  require("numb").setup { centered_peeking = false }

  reset_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feedkeys ":5\r"
  wait_until_idle()
  assert_cursor(5, "absolute jump")

  print "All numb tests passed"
end

return M
