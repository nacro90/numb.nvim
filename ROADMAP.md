# Roadmap

This document tracks planned features and their priority. Released work
lives in [CHANGELOG.md](CHANGELOG.md); this file describes what is
being considered or actively worked on next.

Items are grouped by priority (P1 highest). Status icons:

- 📋 Planned: designed, ready to start
- 🚧 In Progress: being worked on
- 🧪 Under Review: implementation complete, awaiting review
- ✅ Shipped: moved to `CHANGELOG.md`

---

## Shipped in v1.2.0

Everything planned for this release has landed. `CHANGELOG.md` has the details;
this is the record of what each item turned out to be.

- **Range peek (P1) ✅** Shipped with more than the MVP scope: both Ex
  separators, address chains where the last two win, and `$` and `.` endpoints.
- **`:checkhealth numb` (P2) ✅** Shipped, and CI now exercises the real
  `vim.health` API rather than only the suite's stub.
- **Filetype/buftype disable filter (P3) ✅** Shipped with both lists defaulting
  to empty rather than excluding `terminal`. The proposed default was measured
  and dropped: in a terminal buffer numb previews `:15` correctly, and with the
  plugin disabled Vim performs the same jump on its own, so excluding a buftype
  does not stop the jump, it only takes away the preview. Users who want that
  trade make it in one line.
- **Vimdoc `:h numb` (P4) ✅** Hand-written rather than generated. panvimdoc
  derives tags from markdown headings only, so a generated file carries no
  `*numb*` tag and no tag per option or per function, which is what makes
  `:help` useful. Instead the file is pinned to the Lua sources by
  `scripts/verify_doc.lua`: an option added without a tag, or missing from the
  Defaults block, or with a stale documented value, fails the build.

## Future / Under Consideration

Items below are not committed to any release. They may be promoted,
deferred, or dropped after discussion.

- **`peek_delay` debounce.** Reduce flicker when typing multi-digit
  numbers quickly. Likely small benefit on modern Neovim where redraws
  are already cheap.
- **Custom highlight group `NumbPeek`.** Decouple peek styling from
  the global `cursorline` option. Useful when a user has `cursorline`
  permanently on and the peek visual is indistinguishable.
- **Mark/search range peek.** Extend range peek to `'a,'b` and `/pat/`
  patterns. Deferred until MVP range peek lands.
- **Move the test exit code out of the test module.** `tests/run.lua`
  currently calls `cquit` itself when headless, because the launcher
  appends `+qall`, which exits 0 even after an error and would otherwise
  make the suite non-blocking in CI. The cleaner split is for `M.run()` to
  return the failure count and let the caller decide, for example
  `+"lua if not require('tests.run').run() then vim.cmd 'cquit 1' end"`.
  That change has to land together with the invocations in
  `scripts/check.sh` and `CLAUDE.md`, so it was kept out of the fix that
  discovered the problem.

---

## Done

See [CHANGELOG.md](CHANGELOG.md) for shipped features.

### v1.2.0 (2026-08-02)

- Range preview for `:N,M{cmd}`, address chains and both Ex separators.
- `:h numb`, pinned to the Lua sources by a CI gate.
- `:checkhealth numb`.
- `disable_for_buftype` and `disable_for_filetype`.
- `get_config()`, a load guard with an opt-out, and configuration validation.
- Four peek defects fixed, including a buffer-shrinking command that raised out
  of a scheduled callback and a peek left behind by a window closing.
- `numb.on_cmdline_changed()` and `numb.on_cmdline_exit()` removed from the
  public module. Deliberately released as a minor rather than a major: both were
  documented as having no reason to be called and were never an integration
  point, while a major bump would silently stop updates for anyone pinned to
  `1.x`.

### v1.1.0 (2026-05-25)

- Window-local `vim.w.numb_peeking` flag + `numb.is_peeking(winnr?)`
  Lua API for statusline integrations.
- `:Numb` user command with `enable | disable | toggle` subcommands +
  `numb.enable()` / `numb.is_enabled()` Lua API.
- Jumplist support for `<C-o>` after confirmed peek.
- Unused logging module removed.
- CONTRIBUTING.md, ROADMAP.md, and release workflow documented.

### v1.0.0 (2026-05-25)

First tagged stable release. See `CHANGELOG.md` for the full list.
