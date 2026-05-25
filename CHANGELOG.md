# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- `CONTRIBUTING.md` documenting the contribution workflow, commit
  conventions, and changelog discipline.
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

[Unreleased]: https://github.com/nacro90/numb.nvim/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/nacro90/numb.nvim/releases/tag/v1.0.0
