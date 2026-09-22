-- Drive numb.nvim through a real UI and check what actually reaches the screen.
--
-- Run from the repository root:
--
--   nvim -l scripts/verify_redraw.lua
--
-- The headless suite cannot see flicker: nothing is drawn there, and keys fed
-- with `feedkeys()` never reach the point where Vim waits for the user. So this
-- spawns `nvim --embed`, attaches as a linegrid UI over msgpack-rpc, sends keys
-- with `nvim_input` like a terminal would, and records the screen at every
-- `flush`. A frame the user was never meant to see is then just a list entry.
--
-- Every step ends on a request, not a sleep. Requests are only served while Vim
-- waits for input, which is after the keys were processed and after whatever it
-- drew for them, and the response travels the same channel as the redraw events.
-- So once the reply arrives, every frame the step produced has been recorded.

local uv = vim.uv
local mpack = vim.mpack

local ROWS, COLS = 12, 60
local TIMEOUT_MS = 5000

local REPO = vim.fn.getcwd()

---Every line in the test buffer reads `text line NNN`, so a line number column
---in front of one means a peek was on screen.
---@param line string
---@return boolean
local function shows_number_column(line)
  return line:match "^%s*%d+ text line %d%d%d$" ~= nil
end

---@class Frame
---@field lines string[] Screen rows, trailing blanks trimmed; the last is the command line

---A connection to one embedded Neovim with a UI attached.
---@param setup string Lua run in the child before the UI attaches
local function spawn(setup)
  local stdin, stdout = uv.new_pipe(), uv.new_pipe()
  local exited = false
  local handle = uv.spawn(vim.v.progpath, {
    args = { "--embed", "--clean", "-n", "-i", "NONE" },
    stdio = { stdin, stdout, nil },
  }, function()
    exited = true
  end)
  assert(handle, "could not spawn nvim --embed")

  local session = mpack.Session { unpack = mpack.Unpacker() }
  local pack = mpack.Packer()
  local grid = {}
  ---@type Frame[]
  local frames = {}
  local callback_error

  local function clear()
    for row = 0, ROWS - 1 do
      grid[row] = {}
      for col = 0, COLS - 1 do
        grid[row][col] = " "
      end
    end
  end
  clear()

  local handlers = {
    grid_clear = clear,
    grid_line = function(_, row, col, cells)
      for _, cell in ipairs(cells) do
        for _ = 1, cell[3] or 1 do
          if grid[row] and col < COLS then
            grid[row][col] = cell[1]
          end
          col = col + 1
        end
      end
    end,
    grid_scroll = function(_, top, bot, left, right, rows)
      local before = {}
      for row = top, bot - 1 do
        before[row] = vim.deepcopy(grid[row])
      end
      for row = top, bot - 1 do
        local source = row + rows
        if source >= top and source < bot then
          for col = left, right - 1 do
            grid[row][col] = before[source][col]
          end
        end
      end
    end,
    flush = function()
      local lines = {}
      for row = 0, ROWS - 1 do
        local cells = {}
        for col = 0, COLS - 1 do
          cells[#cells + 1] = grid[row][col]
        end
        lines[#lines + 1] = (table.concat(cells):gsub("%s+$", ""))
      end
      -- Neovim also flushes when nothing changed, for instance after a timer
      -- callback that drew nothing. Such a flush shows the user nothing new, and
      -- it can arrive after a step's reply and be counted against the next step,
      -- so only frames that change the screen are kept.
      local previous = frames[#frames]
      if previous and vim.deep_equal(previous.lines, lines) then
        return
      end
      frames[#frames + 1] = { lines = lines }
    end,
  }

  stdout:read_start(function(_, data)
    if not data then
      return
    end
    -- A raise here would only kill the read callback and surface later as a
    -- timeout, so it is kept and reported instead.
    local ok, err = pcall(function()
      local pos = 1
      while pos <= #data do
        local kind, id_or_cb, method_or_err, args_or_result
        kind, id_or_cb, method_or_err, args_or_result, pos = session:receive(data, pos)
        if kind == "notification" and method_or_err == "redraw" then
          for _, batch in ipairs(args_or_result) do
            local handler = handlers[batch[1]]
            if handler then
              for i = 2, #batch do
                handler(unpack(batch[i]))
              end
            end
          end
        elseif kind == "response" then
          id_or_cb(method_or_err, args_or_result)
        end
      end
    end)
    if not ok then
      callback_error = callback_error or err
    end
  end)

  local child = { frames = frames }

  function child.request(method, args)
    local done, err, result = false, nil, nil
    local header = session:request(function(e, r)
      done, err, result = true, e, r
    end)
    stdin:write(header .. pack(method) .. pack(args))
    local ok = vim.wait(TIMEOUT_MS, function()
      return done
    end, 5)
    assert(ok, ("no reply to %s: %s"):format(method, tostring(callback_error)))
    -- Checked on every reply, not only on a timeout: a handler that raised has
    -- dropped the rest of its batch, and the grid can no longer be trusted.
    assert(callback_error == nil, ("error while reading redraw events: %s"):format(tostring(callback_error)))
    assert(err == nil or err == vim.NIL, ("%s failed: %s"):format(method, vim.inspect(err)))
    return result
  end

  ---Send keys the way a terminal does, then wait until Vim is idle again.
  ---@param keys string
  ---@param linger_ms integer|nil Also keep what is drawn this long afterwards,
  ---for a redraw that is due to a timer rather than to Vim going idle
  ---@return Frame[] The frames drawn in between
  function child.type(keys, linger_ms)
    local first = #frames + 1
    stdin:write(session:notify() .. pack "nvim_input" .. pack { keys })
    child.request("nvim_exec_lua", { "return 0", {} })
    if linger_ms then
      vim.wait(linger_ms, function()
        return false
      end, 5)
      child.request("nvim_exec_lua", { "return 0", {} })
    end
    return vim.list_slice(frames, first)
  end

  -- A notification, not a request: Neovim exits without replying, so a request
  -- would sit out the whole timeout on every scenario.
  function child.close()
    stdin:write(session:notify() .. pack "nvim_command" .. pack { "qa!" })
    if not vim.wait(TIMEOUT_MS, function()
      return exited
    end, 5) then
      handle:kill "sigterm"
    end
  end

  -- Prepended here rather than with `--cmd`, which `--clean` would override.
  child.request("nvim_exec_lua", { "vim.opt.runtimepath:prepend(...)", { REPO } })
  -- `--embed` finishes starting up only once a UI attaches, and that is when
  -- plugin/numb.lua calls `setup()` with the defaults. Configuring after it is
  -- what keeps the options a scenario sets from being replaced.
  child.request("nvim_ui_attach", { COLS, ROWS, { ext_linegrid = true } })
  child.request("nvim_exec_lua", { setup, {} })
  child.request("nvim_exec_lua", { "return 0", {} })
  return child
end

local SETUP = [==[
  vim.o.shortmess = vim.o.shortmess .. "I"
  vim.o.laststatus = 0
  vim.o.ruler = false
  vim.o.showcmd = false
  local numb = require "numb"
  numb.setup()
  -- Counts the keystrokes that left a peek running, so a scenario that must not
  -- draw a peek can also show that there was one to hide.
  vim.g.peeks = 0
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    callback = function()
      if numb.is_peeking() then
        vim.g.peeks = vim.g.peeks + 1
      end
    end,
  })
  local lines = {}
  for i = 1, 100 do
    lines[i] = ("text line %03d"):format(i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modified = false
  -- The shape of quick-scope's `f` mapping (#36): Vim inserts `.,.+5` for the
  -- count, and `<C-U>` clears it again before the command runs.
  vim.cmd [[nnoremap <silent> X :<C-U>let g:count_seen = v:count1<CR>]]
  vim.cmd [[nnoremap <silent> J :30<CR>]]
  vim.cmd [[nnoremap K :40]]
]==]

local failures = {}

---@param label string
---@param frames Frame[]
---@param predicate fun(frame: Frame): boolean
local function every_frame(label, frames, predicate)
  if #frames == 0 then
    table.insert(failures, label .. ": nothing was drawn")
    return
  end
  for index, frame in ipairs(frames) do
    if not predicate(frame) then
      table.insert(
        failures,
        ("%s: frame %d of %d:\n  |%s"):format(label, index, #frames, table.concat(frame.lines, "\n  |"))
      )
      return
    end
  end
end

---For what must never be on screen. No frame at all passes: a step that
---changes nothing the user can see draws nothing new, which is why callers
---also show that there was something to hide.
---@param label string
---@param frames Frame[]
---@param predicate fun(frame: Frame): boolean True for a frame that must not appear
local function no_frame(label, frames, predicate)
  for index, frame in ipairs(frames) do
    if predicate(frame) then
      table.insert(
        failures,
        ("%s: frame %d of %d:\n  |%s"):format(label, index, #frames, table.concat(frame.lines, "\n  |"))
      )
      return
    end
  end
end

---Without a peek to hide, a check that no frame shows one proves nothing.
---@param label string
local function assert_peeked(child, label)
  local peeks = child.request("nvim_get_var", { "peeks" })
  if peeks == 0 then
    table.insert(failures, label .. ": nothing was peeked, so hiding the peek proves nothing")
  end
end

local function has_number_column(frame)
  return vim.iter(frame.lines):any(shows_number_column)
end

local function command_line_is(text)
  return function(frame)
    return frame.lines[ROWS] == text
  end
end

local function lacks_number_column(frame)
  return not has_number_column(frame)
end

local function shows(line)
  return function(frame)
    return vim.iter(frame.lines):any(function(row)
      return row:match("^%s*" .. line .. "$") ~= nil
    end)
  end
end

local scenarios = {
  {
    name = "a count before a mapping that clears the range",
    run = function(child)
      local frames = child.type "6X"
      -- The peek of `.,.+5` is torn down again inside the mapping, so no frame
      -- may show it.
      no_frame("6X never shows the peek", frames, has_number_column)
      assert_peeked(child, "6X")
      local count = child.request("nvim_eval", { "g:count_seen" })
      if count ~= 6 then
        table.insert(failures, ("6X: the mapping saw v:count1 == %s, expected 6"):format(tostring(count)))
      end
    end,
  },
  {
    name = "a mapping that jumps",
    run = function(child)
      local frames = child.type "J"
      no_frame("J never shows the peeks of :3 and :30", frames, has_number_column)
      assert_peeked(child, "J")
      local line = child.request("nvim_eval", { "line('.')" })
      if line ~= 30 then
        table.insert(failures, ("J: landed on line %s, expected 30"):format(tostring(line)))
      end
    end,
  },
  {
    name = "typing one key at a time",
    run = function(child)
      child.type ":"
      every_frame("typing :4 previews line 4", child.type "4", shows "4 text line 004")
      every_frame("typing :40 previews line 40", child.type "0", shows "40 text line 040")
      every_frame("Esc restores the window", child.type "<Esc>", lacks_number_column)
    end,
  },
  {
    name = "a count before the command line",
    run = function(child)
      local frames = child.type "6:"
      -- Vim inserts the range one character at a time; `:.` and `:.,` are not
      -- worth a frame each.
      every_frame("6: is drawn once, complete", frames, command_line_is ":.,.+5")
      every_frame("6: previews the range", frames, has_number_column)
    end,
  },
  {
    name = "keys that arrive together",
    run = function(child)
      local frames = child.type ":40"
      every_frame(":40 in one read is drawn once, complete", frames, command_line_is ":40")
      every_frame(":40 in one read previews line 40", frames, shows "40 text line 040")
    end,
  },
  {
    name = "a mapping that leaves the command line open",
    run = function(child)
      local frames = child.type "K"
      -- The mapping ends waiting for the user, which is exactly when the
      -- preview has to appear.
      every_frame("K is drawn once, complete", frames, command_line_is ":40")
      every_frame("K previews line 40", frames, shows "40 text line 040")
    end,
  },
  {
    name = "a preview when SafeState never comes",
    run = function(child)
      -- Stands in for whatever keeps Vim from reaching SafeState while the user
      -- is looking at the command line, such as an open completion menu.
      child.request("nvim_exec_lua", { "vim.o.eventignore = 'SafeState'", {} })
      local frames = child.type(":40", 300)
      local last = frames[#frames]
      every_frame(":40 without SafeState still previews line 40", { last }, shows "40 text line 040")
    end,
  },
}

for _, scenario in ipairs(scenarios) do
  local child = spawn(SETUP)
  local ok, err = pcall(scenario.run, child)
  child.close()
  if not ok then
    table.insert(failures, ("%s: %s"):format(scenario.name, err))
  end
end

if #failures > 0 then
  error(("%d screen check(s) failed:\n%s"):format(#failures, table.concat(failures, "\n")), 0)
end
print(("numb.nvim draws %d scenarios without intermediate frames"):format(#scenarios))
