# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `:checkhealth numb`. Reports the Neovim version against the supported floor,
  where the plugin was loaded from and whether a second copy is shadowing it,
  whether it is set up, and the active configuration so a pasted health report
  is self-contained. Being disabled on purpose is reported as a warning, not an
  error.
- The Ex line symbols `$` (last line) and `.` (current line) are now previewed,
  including arithmetic on either of them: `:$`, `:$-3`, `:.`, `:.+5`. Previously
  only digits and signs were recognised, so `:$` produced no preview at all.

### Changed
- `setup()` now reports invalid configuration instead of accepting it silently.
  An unknown option name is ignored with a warning, and a value of the wrong
  type falls back to its default with a warning. Previously both were accepted
  without any message, so a typo such as `show_nubmers` looked like it had
  worked (#26). Invalid configuration never raises, so a typo cannot leave the
  plugin uninstalled.

### Fixed
- Confirming a command that deletes lines near the end of the buffer, such as
  `:38,40d` in a 40 line buffer, no longer reports
  `Invalid cursor line: out of range`. The jump is applied after the command has
  run, so the target is now clamped to the buffer as it is at that point.
- `disable()` during an active peek no longer leaves the peeking window behind.
  Previously the `number`, `cursorline`, `foldenable` and `relativenumber`
  values used while peeking stayed applied, the cursor stayed on the peeked
  line, and `vim.w.numb_peeking` stayed set, so a statusline using
  `is_peeking()` reported a peek forever.
- Peeking in a background window no longer scrolls the window you are actually
  in. View restoration and centering now target the peeked window rather than
  the current one.

## [1.1.0] - 2026-05-25

### Added
- Jumplist support: confirmed `:` peeks now push the origin position to the
  window jumplist, so `<C-o>` returns to the line you jumped from. Aborted
  peeks do not pollute the jumplist.
- `:Numb` user command with `enable | disable | toggle` subcommands and tab
  completion. Bare `:Numb` defaults to `toggle`. An unknown subcommand
  triggers a `vim.notify` error.
- `require('numb').enable(opts?)` and `require('numb').is_enabled()` Lua
  API. `enable()` preserves previously configured options, so you no
  longer need to re-call `setup()` after `disable()`.
- Window-local `vim.w.numb_peeking` flag (set during active peek, cleared
  on confirm or abort) for statusline integrations. Scope is per window
  so split views of the same buffer never cross-flag each other.
- `require('numb').is_peeking(winnr?)` Lua API returning the same
  information programmatically. Follows the Neovim convention where `nil`
  or `0` means the current window.
- `CONTRIBUTING.md` documenting the contribution workflow, commit
  conventions, and changelog discipline.
- `ROADMAP.md` describing planned features by priority.
- Release workflow guidance in `CLAUDE.md` covering SemVer, annotated
  tags, GitHub Releases, and the rebase-not-merge policy for divergence.

### Removed
- The bundled `numb.log` module and its file-based logger. The plugin no
  longer writes to `stdpath('data')/numb.log` on load.
- Stale `lua-format` config (Stylua is the only formatter).

## [1.0.0] - 2026-05-25

First tagged stable release. Captures the state of the plugin after several
years of iterative improvements.

### Added
- Auto-loading entrypoint `plugin/numb.lua` so the plugin works without an
  explicit `require('numb').setup()` call (#35).
- `centered_peeking` option to center the peeked line in the window.
- `hide_relativenumbers` option to disable `relativenumber` while peeking.
- `number_only` option to peek only when the command line is purely numeric.
- Range peeking and relative jump support (`:+5`, `:-3`, `:++`, `:10+5`,
  arithmetic expressions).
- Unfolding while peeking and after confirming a jump.
- `require('numb').disable()` to tear down the plugin and clear state.
- Headless regression test suite covering option restoration, sequential
  jumps, out-of-bounds clamping, relative motions, multi-window state,
  and fold restoration.
- GitHub Actions CI running Stylua, a load smoke test, and the regression
  suite on every push and pull request to `master`.
- Type annotations (LuaCATS) for the public API and internal state.

### Changed
- Module-level state encapsulated into a `NumbState` class for clearer
  ownership and easier testing.
- Window option handling migrated to `nvim_get_option_value` /
  `nvim_set_option_value`.
- Cursor and view restoration made more deterministic so confirmed and
  aborted peeks leave the window in the expected state.

### Fixed
- Compatibility with stable Neovim after API changes.
- Negative-range commands no longer raise errors when the relative target
  underflows the buffer; targets are clamped to the buffer bounds.
- Relative jump origin stays stable when typing additional digits.
- Unnecessary redraw calls removed to reduce flicker.
- `nil` guard around log file operations (now superseded by the logger
  removal in `[Unreleased]`).

### Security
- Replaced the previous `load()`-based arithmetic evaluator with a manual
  parser to eliminate code-execution risk from malformed input.

[Unreleased]: https://github.com/nacro90/numb.nvim/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/nacro90/numb.nvim/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/nacro90/numb.nvim/releases/tag/v1.0.0
