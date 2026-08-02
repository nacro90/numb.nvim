---@mod numb.address Resolving the Ex line addresses at the start of a command.
---
--- Pure: nothing here reads or writes editor state. The caller supplies the line
--- that relative offsets count from and the last line of the buffer, which is
--- what makes every shape testable without a window, a buffer or a command line.
local address = {}

---What the start of a command line resolves to.
---@class NumbTarget
---@field line integer The line to preview
---@field first integer|nil Range start, present only when a range was given
---@field last integer|nil Range end, present only when a range was given

---Characters an address this module understands is built from: digits, the
---signs of relative offsets, `.` for the current line and `$` for the last one.
---Marks and search patterns are deliberately absent; those are left to Vim.
address.PATTERN = "[%+%-%d%.%$]+"

---Parse a single Ex address with arithmetic support.
---@param str string The expression (`"+5"`, `"10-3"`, `"++"`, `"$-3"`, `".+5"`)
---@param base_line integer The line a relative offset counts from
---@param last_line integer|nil Line count of the buffer, the value of `$`
---@return integer|nil Line number, or nil when the expression is not one
function address.parse(str, base_line, last_line)
  if not str:match("^" .. address.PATTERN .. "$") then
    return nil
  end

  -- Resolve the two Ex line symbols to numbers up front, so the arithmetic below
  -- only ever sees digits and signs. `.` is the current line and `$` the last
  -- one, matching Ex addressing.
  str = str:gsub("%.", tostring(base_line))
  if str:find "%$" then
    if not last_line then
      return nil
    end
    str = str:gsub("%$", tostring(last_line))
  end

  -- Turn runs of operators into expressions, `"++"` into `"+1+"`. Two passes are
  -- always enough however long the run is: gsub does not rescan what it just
  -- wrote, so each pass separates every remaining adjacent pair, and a run of n
  -- signs has at most one adjacent pair left after the first pass.
  str = str:gsub("([%+%-])([%+%-])", "%11%2")
  str = str:gsub("([%+%-])([%+%-])", "%11%2")

  -- A trailing operator means an offset of one, so `":+"` is the next line.
  if str:find "[%+%-]$" then
    str = str .. 1
  end

  -- A leading `.` or `$` has already become a number above, so only a leading
  -- sign still needs the base line added.
  local base = 0
  if str:find "^[%+%-]" then
    base = base_line
  end

  local result = base
  local current_num = ""
  local sign = 1

  for i = 1, #str do
    local char = str:sub(i, i)
    if char == "+" then
      result = result + sign * (tonumber(current_num) or 0)
      current_num = ""
      sign = 1
    elseif char == "-" then
      result = result + sign * (tonumber(current_num) or 0)
      current_num = ""
      sign = -1
    else
      current_num = current_num .. char
    end
  end
  result = result + sign * (tonumber(current_num) or 0)

  return math.floor(result)
end

---Resolve what a command line should preview.
---@param cmd_line string The command line without its leading colon, exactly as
---`vim.fn.getcmdline()` returns it
---@param base_line integer The line relative offsets count from
---@param last_line integer|nil Line count of the buffer, the value of `$`
---@param number_only boolean Preview only when nothing follows the addresses
---@return NumbTarget|nil
function address.resolve(cmd_line, base_line, last_line, number_only)
  -- With `number_only` the addresses have to be the whole command line, so the
  -- patterns are anchored at both ends.
  local anchor = number_only and "$" or ""

  -- Ranges are tried first. The single address pattern below would otherwise
  -- match only the first address of `:5,10d` and preview line 5 alone, which
  -- looks like a confirmation of the range while showing none of it.
  local first_str, last_str = cmd_line:match("^(" .. address.PATTERN .. "),(" .. address.PATTERN .. ")" .. anchor)
  if first_str then
    local first = address.parse(first_str, base_line, last_line)
    local last = address.parse(last_str, base_line, last_line)
    if first and last then
      return { line = math.min(first, last), first = first, last = last }
    end
  end

  local num_str = cmd_line:match("^(" .. address.PATTERN .. ")" .. anchor)
  if num_str then
    local line = address.parse(num_str, base_line, last_line)
    if line then
      return { line = line }
    end
  end

  return nil
end

return address
