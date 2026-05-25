# Roadmap

This document tracks planned features and their priority. Released work
lives in [CHANGELOG.md](CHANGELOG.md); this file describes what is
being considered or actively worked on next.

Items are grouped by priority (P1 highest). Status icons:

- 📋 Planned — designed, ready to start
- 🚧 In Progress — being worked on
- 🧪 Under Review — implementation complete, awaiting review
- ✅ Shipped — moved to `CHANGELOG.md`

---

## Next: Toward v1.1.0

### P1 — Range peek 📋

Highlight the line range when typing `:N,M{cmd}` so the user can verify
the range before pressing Enter. Vim natively previews substitute via
`inccommand` but not delete/yank/move/global; numb.nvim already previews
single-line `:N` jumps, and this extends the same principle to ranges.

**Scope (MVP):**
- Numeric ranges: `:5,10`, `:.,+5`, `:10,+3`, `:-5,+10`.
- Extmark-based line highlight using a new `NumbRange` highlight
  (`link = "Visual"` by default).
- New option `range_peek = true` (default on).
- Falls back to single-line peek if the cmdline does not match a range.
- Unsupported syntaxes (`'a`, `/pat/`, `$`, `%`) pass through to native
  Vim unhighlighted — no regression.

**Why P1:** Addresses a real UX gap with no native Neovim equivalent.
Natural extension of the plugin's "peek before commit" philosophy.

### P2 — `:Numb` user command 📋

Single command with `enable | disable | toggle` subcommands plus tab
completion. Adds public `numb.enable()` and `numb.is_enabled()` Lua API
mirroring the existing `numb.disable()`.

**Why P2:** Discoverable runtime control is expected by power users and
plugin integrators (which-key, lazy.nvim keys). Subcommand pattern
follows modern Neovim conventions (`:Mason`, `:Lazy`, `:Telescope`).
Low risk, ~25 LOC.

### P3 — Filetype/buftype disable filter 📋

Two new options:

```lua
require("numb").setup{
  disable_for_buftype = { "terminal" },  -- default
  disable_for_filetype = {},             -- opt-in
}
```

Early-return guard in `on_cmdline_changed` skips peek when the current
window matches. Default excludes `terminal` since `:N` is rarely
meaningful there.

**Why P3:** Removes a real but narrow pain point (terminal flicker).
Tiny change, opt-in for filetypes, conservative default for buftypes.

### P4 — `vim.b.numb_peeking` statusline flag 📋

Set `vim.b[bufnr].numb_peeking = true` during peek, clear on unpeek.
Expose public `numb.is_peeking(winnr?)`. Enables lualine/heirline
components like:

```lua
{
  function() return vim.b.numb_peeking and "👁" or "" end,
}
```

**Why P4:** Trivial change (3 LOC), but value is mostly cosmetic.
Useful for users who customize their statusline; invisible to everyone
else.

---

## Future / Under Consideration

Items below are not committed to any release. They may be promoted,
deferred, or dropped after discussion.

- **`peek_delay` debounce** — Reduce flicker when typing multi-digit
  numbers quickly. Likely small benefit on modern Neovim where redraws
  are already cheap.
- **Custom highlight group `NumbPeek`** — Decouple peek styling from
  the global `cursorline` option. Useful when a user has `cursorline`
  permanently on and the peek visual is indistinguishable.
- **`:checkhealth numb`** — Health check reporting Neovim version,
  augroup state, and config validity. Aligns with neovim-lua-plugin
  best practices.
- **Vimdoc `:h numb`** — Generate `doc/numb.txt` via vimCATS or panvimdoc
  from LuaCATS annotations.
- **Mark/search range peek** — Extend range peek to `'a,'b` and `/pat/`
  patterns. Deferred until MVP range peek lands.

---

## Done

See [CHANGELOG.md](CHANGELOG.md) for shipped features. Recent
highlights:

- Jumplist support for `<C-o>` after confirmed peek.
- Unused logging module removed.
- CONTRIBUTING.md and release workflow documented.
