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
}

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
  return vim.tbl_deep_extend("force", config.DEFAULTS, config.sanitize(user_opts))
end

return config
