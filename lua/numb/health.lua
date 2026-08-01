---@mod numb.health Health check surfaced by `:checkhealth numb`.
---
---Discovered automatically by Neovim through the `lua/**/health.lua` runtime
---pattern, so `lua/numb/init.lua` needs no registration hook.
local health = {}

local api = vim.api

---Lowest Neovim version numb.nvim supports.
local MIN_NVIM_VERSION = "0.10"

---Autocommand events numb.nvim installs in the `numb` augroup.
---@type string[]
local REQUIRED_EVENTS = { "CmdlineChanged", "CmdlineLeave" }

---Render a config value on a single line.
---@param value any
---@return string
local function format_value(value)
  return vim.inspect(value, { newline = " ", indent = "" })
end

---Report the running Neovim version against the supported floor.
local function check_nvim_version()
  local version = vim.version()
  local version_str = ("%d.%d.%d"):format(version.major or 0, version.minor or 0, version.patch or 0)
  if vim.fn.has("nvim-" .. MIN_NVIM_VERSION) == 1 then
    vim.health.ok(("Neovim %s (>= %s required)"):format(version_str, MIN_NVIM_VERSION))
  else
    vim.health.error(("Neovim %s is too old; numb.nvim requires >= %s"):format(version_str, MIN_NVIM_VERSION), {
      "Upgrade Neovim, or pin numb.nvim to a release that supports your version.",
    })
  end
end

---Report where numb.nvim was loaded from and flag duplicate copies on the
---runtimepath, which is the usual cause of "my config change did nothing".
local function check_installation()
  local paths = api.nvim_get_runtime_file("lua/numb/init.lua", true)
  if #paths > 1 then
    vim.health.warn(("Found %d copies of numb.nvim on the runtimepath"):format(#paths), {
      "Whichever copy comes first wins; the others are dead weight.",
      "Installed at: " .. table.concat(paths, ", "),
    })
  elseif #paths == 1 then
    vim.health.ok("Installed at " .. paths[1])
  else
    vim.health.error("`lua/numb/init.lua` is not on the runtimepath", {
      "The health check was found but the plugin itself was not; the install is incomplete.",
    })
  end
end

---Inspect the `numb` augroup for the autocommands the plugin should own.
---@return string[]|nil missing Events absent from the group; `nil` when the group itself does not exist
local function missing_group_events()
  local ok, autocmds = pcall(api.nvim_get_autocmds, { group = "numb" })
  if not ok then
    return nil
  end

  local seen = {}
  for _, autocmd in ipairs(autocmds) do
    seen[autocmd.event] = true
  end

  local missing = {}
  for _, event in ipairs(REQUIRED_EVENTS) do
    if not seen[event] then
      table.insert(missing, event)
    end
  end
  return missing
end

---Report whether the plugin is set up, and distinguish "never set up" from
---"deliberately disabled". `:Numb` survives `numb.disable()`, so its presence
---is the marker that `setup()` ran at some point this session.
---@param numb table The loaded `numb` module
local function check_status(numb)
  local command_registered = api.nvim_get_commands({ builtin = false }).Numb ~= nil

  if numb.is_enabled() then
    vim.health.ok "Enabled: peeking autocommands are installed"
    local missing = missing_group_events()
    if missing == nil then
      vim.health.error("The `numb` augroup is gone even though the plugin reports enabled", {
        "Something cleared the augroup; run `:Numb enable` or call `require('numb').setup()` again.",
      })
    elseif #missing > 0 then
      vim.health.warn("The `numb` augroup is missing " .. table.concat(missing, " and "), {
        "Expected " .. table.concat(REQUIRED_EVENTS, " and ") .. " on pattern `:`.",
        "Another `augroup numb` in your config may have cleared them; re-run `:Numb enable`.",
      })
    end
  elseif command_registered then
    vim.health.warn("Disabled via `:Numb disable`; no peeking until `:Numb enable`", {
      "Nothing is wrong if you turned numb.nvim off on purpose.",
    })
  else
    vim.health.error("`require('numb').setup()` has never been called; the plugin does nothing", {
      "Add `require('numb').setup()` to your config.",
      "If numb.nvim is lazy-loaded, it may simply not have loaded yet in this session.",
    })
  end

  if command_registered then
    vim.health.ok "`:Numb` user command is registered"
  else
    vim.health.warn("`:Numb enable` / `:Numb disable` / `:Numb toggle` are unavailable", {
      "The `:Numb` command is installed by `setup()` only.",
    })
  end
end

---Report live peeking state. Both branches stay quiet when there is nothing to
---say, so a healthy session does not gain noise here.
---@param numb table The loaded `numb` module
---@param state table|nil `numb._state`, when readable
local function check_peek_state(numb, state)
  local peeking = {}
  for _, winnr in ipairs(api.nvim_list_wins()) do
    if numb.is_peeking(winnr) then
      table.insert(peeking, tostring(winnr))
    end
  end
  if #peeking > 0 then
    vim.health.info("Peeking right now in window(s): " .. table.concat(peeking, ", "))
  end

  if type(state) ~= "table" or type(state.win_states) ~= "table" then
    return
  end

  local stale = {}
  for winnr in pairs(state.win_states) do
    if type(winnr) ~= "number" or not api.nvim_win_is_valid(winnr) then
      table.insert(stale, tostring(winnr))
    end
  end
  if #stale > 0 then
    local message = ("Saved state for %d window(s) that no longer exist: %s"):format(#stale, table.concat(stale, ", "))
    vim.health.warn(message, {
      "Harmless, but it means a window was closed mid-peek and its entry leaked.",
      "`:Numb disable` followed by `:Numb enable` clears it.",
    })
  end
end

---Print the active configuration so a pasted health report is self-contained.
---Values are not validated here: `setup()` already rejects unknown keys and
---wrong types, and defaults are merged in, so every key is present and sane by
---construction. Iterating the table keeps new options visible without edits.
---@param state table|nil `numb._state`, when readable
local function check_config(state)
  if type(state) ~= "table" or type(state.opts) ~= "table" then
    vim.health.warn "Active configuration is unreadable; `numb._state.opts` is missing"
    return
  end

  local keys = vim.tbl_keys(state.opts)
  if #keys == 0 then
    vim.health.warn "Active configuration is empty; expected the merged defaults"
    return
  end

  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    vim.health.info(("%s = %s"):format(tostring(key), format_value(state.opts[key])))
  end
end

---Entry point invoked by `:checkhealth numb`.
function health.check()
  vim.health.start "numb.nvim"
  check_nvim_version()
  check_installation()

  local loaded, numb = pcall(require, "numb")
  if not loaded then
    vim.health.error("`require('numb')` failed: " .. tostring(numb))
    return
  end
  if type(numb.is_enabled) ~= "function" or type(numb.is_peeking) ~= "function" then
    vim.health.error("The loaded numb.nvim is older than this health check expects", {
      "`numb.is_enabled()` and `numb.is_peeking()` were added in v1.1.0.",
      "A stale second copy on the runtimepath is the usual cause.",
    })
    return
  end

  vim.health.start "numb.nvim: status"
  check_status(numb)
  check_peek_state(numb, numb._state)

  vim.health.start "numb.nvim: configuration"
  check_config(numb._state)
end

return health
