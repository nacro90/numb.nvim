# Contributing to numb.nvim

Thanks for taking the time to contribute! This document covers the workflow,
expectations, and tooling for changes to numb.nvim.

## Code of Conduct

Be respectful in issues, pull requests, and reviews. Assume good intent.
Keep discussions focused on the code and the user-facing behavior.

## Getting Started

Requirements:

- **Neovim** 0.10 or newer
- **Stylua** for formatting ([install instructions](https://github.com/JohnnyMorganz/StyLua))
- A POSIX shell to run `scripts/check.sh`

Clone and verify the local environment:

```bash
git clone https://github.com/nacro90/numb.nvim.git
cd numb.nvim
./scripts/check.sh
```

`scripts/check.sh` runs the formatter check, a load smoke test, and the
regression suite. CI runs the same script on every push and pull request to
`master`.

## Reporting Bugs

Open an issue with:

1. Neovim version (`nvim --version` first line).
2. A minimal reproduction config (ideally a `minimal_init.lua`).
3. Step-by-step actions you took.
4. What you expected vs. what happened.
5. Screenshots or terminal recordings if the bug is visual.

## Proposing Features

Open an issue first describing the use case and the proposed user-facing
behavior. Discussing the design before opening a pull request avoids wasted
work and keeps the plugin's footprint small.

## Pull Request Workflow

1. Fork the repository and create a feature branch from `master`.
2. Make focused commits. One concern per commit; keep diffs reviewable.
3. Add or update tests in `tests/run.lua` for any behavior change.
4. Add an entry to the `[Unreleased]` section of `CHANGELOG.md` (see below).
5. Run `./scripts/check.sh` and make sure it passes locally.
6. Open a PR against `master` describing motivation, user-facing changes,
   and testing steps. Link related issues.
7. Attach screenshots or recordings when altering visuals.

### Commit Messages

Short, imperative summaries. Conventional Commits style is preferred:

```
feat: push origin to jumplist on confirmed peek
fix: clamp relative jumps to buffer bounds
refactor: drop unused logging module
docs: add CHANGELOG.md
test: cover multi-window state
```

Keep the subject under ~70 characters. Use the body for the *why* when it
is not obvious from the diff.

### Changelog Entries

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Add a bullet to the appropriate section under `[Unreleased]` in
`CHANGELOG.md` as part of the same commit or PR. Section order:

- **Added**: new features.
- **Changed**: changes in existing behavior.
- **Deprecated**: soon-to-be-removed features.
- **Removed**: features removed in this release.
- **Fixed**: bug fixes.
- **Security**: vulnerability fixes.

## Testing

Headless regression tests live in `tests/run.lua`. Add a test whenever you
fix a bug or add an option. If a regression cannot be observed in CI, it
will eventually come back.

Run tests directly:

```bash
nvim --headless -u tests/init.lua -i NONE -n +"lua require('tests.run').run()" +qall
```

Coverage expectations are documented in `CLAUDE.md` under "Test Coverage
Checklist". Aim to cover absolute and relative jumps, arithmetic
expressions, out-of-bounds clamping, window option restoration, multi-window
state isolation, and fold behavior.

## Style

- 2-space indentation, 120-column limit (enforced by `stylua.toml`).
- No call parentheses for simple calls: `require "numb"` not `require("numb")`.
- Descriptive local names (`peek_line`, `cursor_state`) over single letters.
- Modules addressed as `require('numb.<submodule>')`; filenames lowercase
  with underscores.
- Public API and internal state should carry LuaCATS type annotations.

Run `stylua lua/numb` before committing. CI rejects unformatted code.

## Design Principles

- Keep dependencies minimal: no runtime requirements outside stock
  Neovim and Lua.
- Prefer feature flags via `require('numb').setup{...}` over global state.
- Document every new option in `README.md`.
- Avoid scope creep. Peek behavior should remain unobtrusive and fast.

## Releases

Releases are cut by maintainers. The process is documented in `CLAUDE.md`
under "Release Workflow" (SemVer + annotated tags + GitHub Releases). If you
believe a release is overdue, open an issue rather than a PR.

## Questions

If something is unclear, open a draft PR with questions or start a
discussion. It is easier to clarify early than to rework a finished
implementation.
