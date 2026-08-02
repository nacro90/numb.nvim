-- Exercise the real `:checkhealth numb` against a properly configured plugin.
--
-- Run from the repository root:
--
--   nvim -l scripts/verify_health.lua
--
-- The test suite cannot do this. It stubs the whole `vim.health` table with
-- recording functions, which is what makes the reporting decisions testable, but
-- it also means a misuse of the actual API, a renamed function or a wrong
-- argument shape, passes there and only breaks for users.
--
-- A plugin that is installed and set up must report no errors.

vim.opt.runtimepath:append(vim.fn.getcwd())
require("numb").setup {}

vim.cmd "checkhealth numb"
local report = vim.api.nvim_buf_get_lines(0, 0, -1, false)

if #report < 5 then
  io.stderr:write "checkhealth numb produced no report\n"
  os.exit(1)
end

local problems = {}
for _, line in ipairs(report) do
  if line:find "ERROR" then
    table.insert(problems, line)
  end
end

if #problems > 0 then
  io.stderr:write("checkhealth numb reported errors on a healthy plugin:\n" .. table.concat(problems, "\n") .. "\n")
  os.exit(1)
end

-- Warnings are printed but tolerated: a duplicate copy on the runtimepath is a
-- warning, and that depends on how the machine running this is set up.
for _, line in ipairs(report) do
  if line:find "WARNING" then
    io.stderr:write("note: " .. line .. "\n")
  end
end

print(("checkhealth numb: %d line report, no errors"):format(#report))
