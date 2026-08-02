-- Load numb.nvim the way a user's Neovim does, through plugin/numb.lua on the
-- runtimepath, and check that it configured itself.
--
-- Run from the repository root:
--
--   nvim -l scripts/verify_load.lua
--
-- This replaces `nvim --headless +"lua require('numb').setup()" +qall`, which
-- could not work: the repository is not on the runtimepath there, so it reported
-- "module 'numb' not found" and still exited 0, because the `+qall` that follows
-- runs after the error and exits successfully. It read as a passing smoke test in
-- CI for as long as it existed. `nvim -l` propagates a failure.

vim.opt.runtimepath:append(vim.fn.getcwd())

vim.cmd "runtime! plugin/numb.lua"

local numb = require "numb"
assert(vim.g.loaded_numb == 1, "plugin/numb.lua must set the load guard")
assert(numb.is_enabled(), "plugin/numb.lua must configure the plugin while loading")
assert(type(numb.get_config().range_peek) == "boolean", "the active configuration must be readable")

-- Sourcing it again must be a no-op rather than a second install.
vim.cmd "runtime! plugin/numb.lua"
assert(numb.is_enabled(), "sourcing plugin/numb.lua twice must leave peeking enabled")

print "numb.nvim loads from plugin/numb.lua and configures itself"
