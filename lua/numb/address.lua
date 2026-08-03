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

---Ex separators between addresses. The only difference between them is that `;`
---moves the line that following offsets count from onto the address before it,
---while `,` leaves it on the cursor line (see |:;|). Measured against Vim:
---`:5;+3d` deletes 5 through 8, `:5,+3d` from line 20 deletes 5 through 23.
local SEPARATORS = { [","] = true, [";"] = true }

---Parse a single Ex address with arithmetic support.
---@param str string The expression (`"+5"`, `"10-3"`, `"++"`, `"$-3"`, `".+5"`)
---@param base_line integer The line a relative offset counts from
---@param last_line integer|nil Line count of the buffer, the value of `$`
---@return integer|nil Line number, or nil when the expression is not one
---Split an address into its base and check the rest is only signed offsets.
---An Ex address is one base, optionally followed by any number of offsets, so a
---second `.` or `$`, or digits after an offset, is not an address at all: Vim
---rejects `:..`, `:$$`, `:5..10` and `:$-$` with E492. Accepting them meant
---resolving `..` to the current line written out twice, `2020` from line 20, and
---previewing a line for a command that was never going to run.
---@param str string
---@return string|nil base The base, `""` when the address is offsets only
local function base_of(str)
  local base, rest = str:match "^([%.%$])(.*)$"
  if not base then
    base, rest = str:match "^(%d+)(.*)$"
  end
  if not base then
    -- No base at all is valid: `:+5` counts from the line the caller gave us.
    base, rest = "", str
  end

  -- Zero or more offsets, each a sign and an optional count, so `:++` and a
  -- trailing `:+` stay valid.
  while rest ~= "" do
    local _, tail = rest:match "^([%+%-]%d*)(.*)$"
    if not tail then
      return nil
    end
    rest = tail
  end

  return base
end

function address.parse(str, base_line, last_line)
  if not str:match("^" .. address.PATTERN .. "$") then
    return nil
  end

  if not base_of(str) then
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

---Split the leading address chain off a command line.
---@param cmd_line string Command line without its leading colon
---@return string[] addresses In the order they were written
---@return string[] separators The separator that followed each address
---@return string rest Whatever follows the chain
local function split_chain(cmd_line)
  local addresses, separators = {}, {}
  local pos = 1

  while true do
    local from, to = cmd_line:find("^" .. address.PATTERN, pos)
    if not from then
      break
    end
    addresses[#addresses + 1] = cmd_line:sub(from, to)
    pos = to + 1

    -- Consume a separator only when another address follows it. Otherwise `:5,`
    -- would look like a one-address chain with nothing left over, and
    -- `number_only` could no longer tell it apart from a bare `:5`.
    local separator = cmd_line:sub(pos, pos)
    if SEPARATORS[separator] and cmd_line:find("^" .. address.PATTERN, pos + 1) then
      separators[#separators + 1] = separator
      pos = pos + 1
    else
      break
    end
  end

  return addresses, separators, cmd_line:sub(pos)
end

---Resolve what a command line should preview.
---@param cmd_line string The command line without its leading colon, exactly as
---`vim.fn.getcmdline()` returns it
---@param base_line integer The line relative offsets count from
---@param last_line integer|nil Line count of the buffer, the value of `$`
---@param number_only boolean Preview only when nothing follows the addresses
---@return NumbTarget|nil
function address.resolve(cmd_line, base_line, last_line, number_only)
  local addresses, separators, rest = split_chain(cmd_line)
  if #addresses == 0 then
    return nil
  end
  if number_only and rest ~= "" then
    return nil
  end

  -- Resolve left to right, because a `;` changes the base for everything after
  -- it. Measured: `:5;+3,+6d` deletes 8 through 11, so the base moves to 5 and
  -- stays there across the following comma.
  local resolved = {}
  local base = base_line
  for index, expression in ipairs(addresses) do
    local line = address.parse(expression, base, last_line)
    if not line then
      return nil
    end
    resolved[index] = line
    if separators[index] == ";" then
      base = line
    end
  end

  if #resolved == 1 then
    return { line = resolved[1] }
  end

  -- Ex acts on the last two addresses when more than two are given, so
  -- `:5,10,15d` deletes 10 through 15 and previewing 5 through 10 would mark
  -- the wrong lines with full confidence.
  local first = resolved[#resolved - 1]
  local last = resolved[#resolved]
  return { line = math.min(first, last), first = first, last = last }
end

return address
