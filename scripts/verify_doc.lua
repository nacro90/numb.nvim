-- Verify doc/numb.txt against the Lua sources and against Neovim itself.
--
-- Run from the repository root:
--
--   nvim -l scripts/verify_doc.lua
--
-- scripts/check.sh and the Docs workflow both run exactly this.
local DOC = "doc/numb.txt"
local failures = {}

local function fail(msg)
  table.insert(failures, msg)
end

vim.opt.runtimepath:append(vim.fn.getcwd())

-- Rebuild the tags file the way a plugin manager would.
local ok, err = pcall(vim.cmd, "helptags doc")
if not ok then
  fail("helptags failed: " .. tostring(err))
end

-- Every help tag Neovim knows about, ours plus the runtime's, so that
-- cross references can be resolved without :help fuzzy matching.
local known = {}
for _, tagfile in ipairs(vim.fn.globpath(vim.o.runtimepath, "doc/tags", false, true)) do
  for _, line in ipairs(vim.fn.readfile(tagfile)) do
    local tag = line:match "^([^\t]+)"
    if tag then
      known[tag] = true
    end
  end
end

-- Tags the help file must define. The option names and the public
-- functions come from the module itself, so adding either without
-- documenting it fails here.
local numb = require "numb"
local required = {
  "numb",
  "numb.nvim",
  "numb.txt",
  ":Numb",
  "numb-contents",
  "numb-intro",
  "numb-requirements",
  "numb-installation",
  "numb-usage",
  "numb-command",
  "numb-options",
  "numb-api",
  "numb-statusline",
  "numb-health",
  "numb-disabling",
  "numb-license",
  "w:numb_peeking",
  "g:loaded_numb",
}
for option in pairs(numb.get_config()) do
  table.insert(required, "numb-" .. option)
end
for name, value in pairs(numb) do
  if type(value) == "function" and not name:match "^_" then
    table.insert(required, ("numb.%s()"):format(name))
  end
end

local ours = {}
for _, line in ipairs(vim.fn.readfile "doc/tags") do
  local tag, file = line:match "^([^\t]+)\t([^\t]+)"
  if tag then
    ours[tag] = file
  end
end

table.sort(required)
for _, tag in ipairs(required) do
  if not ours[tag] then
    fail("doc/numb.txt is missing the help tag *" .. tag .. "*")
  end
end

-- Carrying a tag is not the same as being listed. The `Defaults:`
-- block in the Options section is what a reader treats as the
-- canonical list of options and their values, and an option can have
-- its own tag while missing from that block entirely. Parse the block
-- and require one line per option, with the value the module really
-- defaults to, so neither a missing option nor a stale value survives.
local documented_defaults = {}
local in_defaults_block = false
for _, line in ipairs(vim.fn.readfile(DOC)) do
  if in_defaults_block then
    if line:match "^<" then
      in_defaults_block = false
    else
      -- The trailing comma is optional: leaving it off the last entry
      -- is valid Lua, and requiring it would report that option as
      -- undocumented, which points at the wrong problem.
      local key, value = line:match "^%s*([%w_]+)%s*=%s*(.-),?%s*$"
      if key then
        documented_defaults[key] = value
      end
    end
  elseif line:match "^Defaults: >" then
    in_defaults_block = true
  end
end

-- Rendered the way the help file writes them, so an empty list reads as `{}`
-- rather than as a table address.
local function render_default(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  if #value == 0 then
    return "{}"
  end
  local items = {}
  for index, item in ipairs(value) do
    items[index] = ('"%s"'):format(item)
  end
  return "{ " .. table.concat(items, ", ") .. " }"
end

for option, default in pairs(numb.get_config()) do
  local documented = documented_defaults[option]
  if not documented then
    fail(("%s: the Defaults block does not list %s"):format(DOC, option))
  elseif documented ~= render_default(default) then
    fail(
      ("%s: the Defaults block says %s = %s, the module defaults to %s"):format(
        DOC,
        option,
        documented,
        render_default(default)
      )
    )
  end
end

-- Cross references must point at a tag that exists, and the file must
-- respect the 78-column help convention.
for lnum, line in ipairs(vim.fn.readfile(DOC)) do
  for ref in line:gmatch "|([^|%s]+)|" do
    if not known[ref] then
      fail(("%s:%d: |%s| does not resolve to any help tag"):format(DOC, lnum, ref))
    end
  end
  local width = vim.fn.strdisplaywidth(line)
  if width > 78 then
    fail(("%s:%d: line is %d columns wide, the limit is 78"):format(DOC, lnum, width))
  end
end

-- :help numb must land in this file rather than fuzzy-matching :number.
if pcall(vim.cmd, "help numb") then
  local buffer = vim.api.nvim_buf_get_name(0)
  if not buffer:match "doc/numb%.txt$" then
    fail(":help numb opened " .. buffer .. " instead of doc/numb.txt")
  end
else
  fail ":help numb failed"
end

if #failures > 0 then
  for _, msg in ipairs(failures) do
    io.stderr:write(msg, "\n")
  end
  io.stderr:write(("%d documentation check(s) failed\n"):format(#failures))
  os.exit(1)
end

print(("doc/numb.txt: %d required tags present, cross references resolve"):format(#required))
