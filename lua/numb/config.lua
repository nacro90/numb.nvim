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

---Default configuration values, and the whole specification of what an option
---is: a key this table does not carry is unknown, and the type of its default is
---the type expected of it. Adding an option here is all it takes for validation,
---`get_config()`, `:checkhealth numb` and the help file check to know about it.
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
    -- Assigned rather than merged. `vim.tbl_deep_extend` merges lists by index,
    -- so an empty list from the user could not clear a non-empty default, and
    -- both sides are copied so nothing shares a table with the defaults.
    resolved[key] = vim.deepcopy(value)
  end
  return resolved
end

return config
