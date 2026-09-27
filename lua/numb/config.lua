---@mod numb.config Option defaults and validation.
---
--- Nothing here reads or writes editor state, so the rules are exercised by
--- calling one function rather than by driving `setup()` and watching for
--- warnings.
local config = {}

---@class NumbConfig
---@field show_numbers boolean Enable 'number' for the window while peeking
---@field show_cursorline boolean Enable 'cursorline' for the window while peeking
---@field hide_relativenumbers boolean Disable 'relativenumber' for the window while peeking
---@field number_only boolean Peek only when command is purely numeric
---@field centered_peeking boolean Center peeked line in window
---@field range_peek boolean Highlight the whole line range for `:N,M{cmd}`
---@field disable_for_buftype string[] 'buftype' values to leave alone
---@field disable_for_filetype string[] 'filetype' values to leave alone
---@field peek_style "window"|"float"|"auto" Where a peek is drawn: in the window
---itself, in a float over it, or in place only when the target is on screen
---@field float NumbFloatConfig How a float peek looks

---@class NumbFloatConfig
---@field height number Below 1 a fraction of the window's height, from 1 up a
---number of rows; at least 3 rows either way
---@field position "bottom"|"top"|"auto" Which edge of the window the float sits
---on; `auto` is the bottom unless the float would cover the cursor line there
---@field win_config (fun(config: table): table)|nil Given the `nvim_open_win`
---configuration numb computed, returns the one to use

---Default configuration values, and the whole specification of what an option
---is: a key this table does not carry is unknown, and the type of its default is
---the type expected of it. Adding an option here is all it takes for validation,
---`get_config()`, `:checkhealth numb` and the help file check to know about it.
---Two things need more than that, and are declared below: a string option that
---takes only some strings (`CHOICES`), and `float`, a table of options of its
---own (`FLOAT_OPTIONS`).
---@type NumbConfig
config.DEFAULTS = {
  show_numbers = true,
  show_cursorline = true,
  hide_relativenumbers = true,
  number_only = false,
  centered_peeking = true,
  range_peek = true,
  disable_for_buftype = {},
  disable_for_filetype = {},
  peek_style = "window",
  float = { height = 0.4, position = "auto" },
}

---The values `peek_style` accepts, in the order the warning lists them. Public
---because `numb.peek()` checks its `style` against the same list.
config.PEEK_STYLES = { "window", "float", "auto" }

---String options that take only some strings, by option name. A float option is
---named as the warnings name it, `float.position`.
---@type table<string, string[]>
local CHOICES = {
  peek_style = config.PEEK_STYLES,
  ["float.position"] = { "bottom", "top", "auto" },
}

---Whether a value is an integer. Public because `numb.peek()` checks its
---arguments by the same rule.
---@param value any
---@return boolean
function config.is_integer(value)
  -- NaN is the one number that is not equal to itself, and `math.floor` of it
  -- is NaN again, so it is ruled out by the same comparison as a fraction. The
  -- infinities do equal their own floor, so they are ruled out by name.
  return type(value) == "number" and math.floor(value) == value and value ~= math.huge and value ~= -math.huge
end

---The choices of a string option, quoted, for a message.
---@param choices string[]
---@return string
function config.format_choices(choices)
  return "one of " .. table.concat(vim.tbl_map(vim.inspect, choices), ", ")
end

---The options `float` takes, each as a check that returns nil for a value it
---accepts and otherwise what it expected, for the warning. Spelled out rather
---than read off `DEFAULTS.float` because `win_config` defaults to nil, which a
---table cannot carry as a key.
---@type table<string, fun(value: any): string|nil>
local FLOAT_OPTIONS = {
  height = function(value)
    -- NaN fails both comparisons, so it is rejected with every other non-number.
    if type(value) == "number" and ((value > 0 and value < 1) or (value >= 1 and config.is_integer(value))) then
      return nil
    end
    return "a fraction between 0 and 1 or a whole number of rows"
  end,
  position = function(value)
    if vim.tbl_contains(CHOICES["float.position"], value) then
      return nil
    end
    return config.format_choices(CHOICES["float.position"])
  end,
  win_config = function(value)
    if type(value) == "function" then
      return nil
    end
    return "a function"
  end,
}

---A list option needs more than a type check: `type({}) == type({ 1 })`, so
---comparing types alone would accept a list of numbers, or a keyed table that
---`vim.tbl_contains` would never match anything in.
---@param value table
---@return boolean
local function is_string_list(value)
  if not vim.islist(value) then
    return false
  end
  for _, item in ipairs(value) do
    if type(item) ~= "string" then
      return false
    end
  end
  return true
end

---@param name string The option as the warnings name it
---@param expected string What it takes
---@param value any What it was given
local function warn_rejected(name, expected, value)
  vim.notify(
    ("[numb] option '%s' expects %s, got %s; keeping the default"):format(name, expected, vim.inspect(value)),
    vim.log.levels.WARN
  )
end

---Keep the float options worth keeping, each bad one falling back alone.
---@param float_opts table A table that is not a list
---@return table|nil kept Nil when nothing was worth keeping
local function sanitize_float(float_opts)
  local kept = {}
  for key, value in pairs(float_opts) do
    local check = FLOAT_OPTIONS[key]
    if not check then
      vim.notify(("[numb] unknown option 'float.%s' ignored"):format(tostring(key)), vim.log.levels.WARN)
    else
      local expected = check(value)
      if expected then
        warn_rejected("float." .. key, expected, value)
      else
        kept[key] = value
      end
    end
  end
  return next(kept) ~= nil and kept or nil
end

---Drop unknown and wrongly typed options, warning once per offending key.
---Never raises: a typo in a user's config must not break `setup()` and leave the
---plugin uninstalled, so every rejected value falls back to its default.
---@param user_opts any Anything that was passed to `setup()` or `enable()`
---@return table The subset worth keeping
function config.sanitize(user_opts)
  if user_opts == nil then
    return {}
  end

  if type(user_opts) ~= "table" then
    vim.notify(("[numb] setup() expects a table, got %s; using defaults"):format(type(user_opts)), vim.log.levels.WARN)
    return {}
  end

  local sanitized = {}
  for key, value in pairs(user_opts) do
    local default = config.DEFAULTS[key]
    if default == nil then
      vim.notify(("[numb] unknown option '%s' ignored"):format(tostring(key)), vim.log.levels.WARN)
    elseif type(value) ~= type(default) then
      vim.notify(
        ("[numb] option '%s' expects a %s, got %s; keeping the default"):format(key, type(default), type(value)),
        vim.log.levels.WARN
      )
    elseif CHOICES[key] and not vim.tbl_contains(CHOICES[key], value) then
      warn_rejected(key, config.format_choices(CHOICES[key]), value)
    elseif key == "float" then
      -- Before the list branch, which would reject any keyed table. `{}` counts
      -- as a list to `vim.islist`, and as no float options at all here.
      if next(value) ~= nil and vim.islist(value) then
        vim.notify("[numb] option 'float' expects a table of float options; keeping the default", vim.log.levels.WARN)
      else
        sanitized.float = sanitize_float(value)
      end
    elseif type(default) == "table" and not is_string_list(value) then
      vim.notify(("[numb] option '%s' expects a list of strings; keeping the default"):format(key), vim.log.levels.WARN)
    else
      sanitized[key] = value
    end
  end
  return sanitized
end

---The configuration to run with: the defaults, with whatever the user passed
---that survived validation layered over them.
---@param user_opts NumbConfig|any
---@return NumbConfig
function config.resolve(user_opts)
  local resolved = vim.deepcopy(config.DEFAULTS)
  for key, value in pairs(config.sanitize(user_opts)) do
    if key == "float" then
      -- Merged, unlike the lists below: `{ height = 5 }` sets the height and
      -- leaves the position at its default. `resolved.float` is already a copy.
      for float_key, float_value in pairs(value) do
        resolved.float[float_key] = float_value
      end
    else
      -- Assigned rather than merged. `vim.tbl_deep_extend` merges lists by
      -- index, so an empty list from the user could not clear a non-empty
      -- default, and both sides are copied so nothing shares a table with the
      -- defaults.
      resolved[key] = vim.deepcopy(value)
    end
  end
  return resolved
end

return config
