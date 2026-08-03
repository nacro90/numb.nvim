# Contributing to numb.nvim

Thanks for taking the time to contribute! This document covers the workflow,
expectations, and tooling for changes to numb.nvim.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).

## Getting Started

Requirements:

- **Neovim** 0.10 or newer
- **Stylua** and **selene**, fetched at the versions CI pins by
  `scripts/tools.sh`
- A POSIX shell to run `scripts/check.sh`

Clone, fetch the tools, and verify the local environment:

```bash
git clone https://github.com/nacro90/numb.nvim.git
cd numb.nvim
./scripts/tools.sh                    # downloads stylua and selene into .tools/
export PATH="$PWD/.tools:$PATH"
./scripts/check.sh
```

Do not skip the tools. Without them `check.sh` refuses to run the formatting and
lint stages, and formatting drift or an undefined variable will only surface as a
red build after you push. Both are single binaries with no Lua of their own, so
there is nothing to vendor; `scripts/tools.sh` pins the same versions CI installs.

`scripts/check.sh` runs the formatter check, a load smoke test, and the
regression suite. CI runs the same script on every push and pull request to
`master`.

## Project Layout

```
lua/numb/init.lua      everything that touches editor state
lua/numb/address.lua   Ex address resolution, pure
lua/numb/config.lua    option defaults and validation, pure
lua/numb/health.lua    :checkhealth numb
plugin/numb.lua        calls setup() once the plugin is on the runtimepath
doc/numb.txt           the help file behind :h numb, checked against the code
tests/init.lua         wires Neovim for the suite
tests/run.lua          headless regression suite
scripts/check.sh       every gate CI runs, and each one runnable on its own
scripts/tools.sh       fetches the stylua and selene versions CI pins
scripts/verify_*.lua   the gates that need a running Neovim
```

The plugin is three steps, all of them in `init.lua`:

1. `CmdlineChanged` asks `numb.address` what the command line points at.
2. `peek()` previews that line, saving the window options, cursor and view it
   changes into `state.win_states[winnr]`.
3. `CmdlineLeave` restores that saved state, staying at the target when the
   command was confirmed rather than aborted.

`address.lua` and `config.lua` are pure on purpose: their rules can be tested by
calling one function, with no window, buffer or command line involved. Keep new
logic that does not need editor state in one of them.

Adding an option touches four files, and `scripts/verify_doc.lua` fails the build
if any of them is missed: the default in `config.DEFAULTS`, the row in the
`Defaults:` block of `doc/numb.txt` plus a `*numb-{option}*` tag for it, the
table in `README.md`, and a test in `tests/run.lua`. The same check requires a
`*numb.{function}()*` tag for every public function, so the help file is not
optional documentation here.

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

Run `./scripts/check.sh format lint` before committing. CI rejects unformatted
code and any lint error.

## Design Principles

- Keep dependencies minimal: no runtime requirements outside stock
  Neovim and Lua.
- Prefer feature flags via `require('numb').setup{...}` over global state.
- Document every new option in `README.md` and in `doc/numb.txt`.
- Avoid scope creep. Peek behavior should remain unobtrusive and fast.

## Releases

Releases are cut by maintainers. The process is documented in `CLAUDE.md`
under "Release Workflow" (SemVer + annotated tags + GitHub Releases). If you
believe a release is overdue, open an issue rather than a PR.

## Questions

If something is unclear, open a draft PR with questions or start a
discussion. It is easier to clarify early than to rework a finished
implementation.
