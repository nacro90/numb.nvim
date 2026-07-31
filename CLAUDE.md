# CLAUDE.md

This file is the single canonical set of repository guidelines for coding agents.
`AGENTS.md` is a symlink to this file, so any agent that looks for either name
reads the same content. Edit this file; never replace the symlink with a copy.

## Development Commands

```bash
# Run all checks (formatting + smoke test + tests) - use before PRs
./scripts/check.sh

# Format Lua files (append --check to fail on drift instead of rewriting).
# Same scope as scripts/check.sh, so tests and plugin/ are covered too.
stylua lua plugin tests

# Lint (same scope; selene.toml plus the vendored vim.yml standard library)
selene lua plugin tests

# Verify plugin loads
nvim --headless +"lua require('numb').setup()" +qall

# Run headless tests directly
nvim --headless -u tests/init.lua -i NONE -n +"lua require('tests.run').run()" +qall

# Manual testing in Neovim
:lua require('numb').setup{centered_peeking=false}
# Then try :{number} commands like :15, :+5, :-3
```

## Project Structure

Code lives under `lua/numb/`; `init.lua` exposes the user-facing API. The Stylua config (`stylua.toml`) sits at the repo root so the formatter can be run from anywhere. Headless regression tests live in `tests/` (`tests/init.lua` wires Neovim, `tests/run.lua` defines scenarios). Demo media is hosted externally, and the runtime expectations users rely on are captured in `README.md`.

## Architecture

numb.nvim peeks buffer lines when typing `:{number}` in command mode without jumping until confirmed.

### Core Flow (`lua/numb/init.lua`)

1. **setup()** registers `CmdlineChanged` and `CmdlineLeave` autocommands in the "numb" augroup
2. **on_cmdline_changed()** parses the command line for number patterns (absolute like `:15` or relative like `:+5`), then calls `peek()` to temporarily move the cursor
3. **peek()** saves window state (cursor, options, topline) in `win_states[winnr]`, applies peeking options (number, cursorline, foldenable=false), and moves cursor to target line
4. **on_cmdline_exit()** checks `event.abort` to determine stay vs restore, then calls `unpeek()`
5. **unpeek()** restores original window options and cursor; if staying, keeps the new position and runs `zv` to unfold

### State Management

- `win_states`: table keyed by window handle storing `{cursor, options, topline}` for restoration
- `peek_cursor`: tracks target position for when user confirms the jump
- `opts`: module-level config merged from defaults + user options

### Number Parsing

`parse_num_str()` handles Ex command math expressions:
- Absolute: `:15` → line 15
- Relative: `:+5` → current + 5, `:-3` → current - 3
- Chained: `:++` → current + 2 (inserts `1` between signs)

## Testing

Tests in `tests/run.lua` use `feedkeys()` to simulate command-line input and verify:
- Window options are restored after jumps
- Out-of-bounds targets clamp to buffer limits
- Sequential jumps don't leak state
- Relative jumps (`:+5`, `:-3`, `:++`, `:--`)
- Complex expressions (`:+2+3`, `:-2-3`, `:10+5`)
- Configuration options (`number_only`, `centered_peeking`) and rejection of invalid ones
- Commands that shrink the buffer under a confirmed peek (`:38,40d`)
- `disable()` while a peek is active, including a peek in a background window

Extend `tests/run.lua` whenever you fix a bug or add a new option. CI (`.github/workflows/ci.yml`) runs `scripts/check.sh` on every push and PR to `master`.

`M.run()` reports every failure rather than stopping at the first, and when
headless it exits through `cquit` so the shell sees a non-zero status. Do not
replace that with a bare `error()`: the launcher appends `+qall`, which exits 0
after an error is reported and would make the whole suite non-blocking in CI.

Write tests that cannot pass for the wrong reason. Several existing tests assert
their own preconditions first (that a window was actually scrolled, that a
deferred callback actually ran) precisely because the interesting assertion would
otherwise hold vacuously.

For exploratory work, still verify inside Neovim using `:lua require('numb').setup{centered_peeking=false}` and `:{number}` jumps, and document any manual scenarios you covered in the PR description.

### Test Coverage Checklist

When adding tests, ensure coverage for:
- [ ] Absolute line numbers (`:10`, `:42`)
- [ ] Relative forward (`:+5`, `:+`)
- [ ] Relative backward (`:-3`, `:-`)
- [ ] Complex expressions (`:+2+3`, `:-1+5`, `:10-2`)
- [ ] Out-of-bounds clamping (high and low)
- [ ] Window option restoration after confirm/abort
- [ ] Sequential jumps without state pollution
- [ ] Buffer-shrinking confirmed commands (the jump is applied after the command runs)
- [ ] Behavior in a window that is not the current one

### Edge Cases

| Scenario | Expected Behavior |
|----------|------------------|
| `:9999` in 100-line buffer | Preview line 100, no errors |
| `:-100` from line 5 | Vim rejects negative ranges |
| `:++` from line 5 | Jumps to line 7 (5+1+1) |
| Invalid pattern `:abc` | No preview, plugin inactive |

## Style

- 2-space indentation, 120 column limit (see `stylua.toml`)
- No call parentheses for simple calls: `require "numb"` not `require("numb")`
- Prefer descriptive local names (`peek_line`, `cursor_state`) over single letters
- Modules addressed as `require('numb.<submodule>')`; filenames lowercase, with underscores only when mirroring Neovim option names
- Return tables that expose only the documented API; keep helpers local

## Commit & PR Guidelines

- Short, imperative commit summaries: `Add lazy.nvim instruction`, `Fix peek flicker (#42)`. Use a blank line and a body when the summary needs context
- Squash unrelated changes and mention relevant issue numbers
- PRs must describe motivation, user-facing changes, and testing steps
- Attach screenshots/recordings when altering visuals
- Tag reviewers when the change touches user configuration or command behavior, and keep the PR checklist current so maintainers can merge without back-and-forth

## Design Principles

- Keep dependencies minimal: no runtime requirements outside stock Neovim/Lua
- Prefer feature flags via `require('numb').setup{...}` over global state
- Document new options in `README.md`
- When a design question is unresolved, open a draft PR with the question rather than guessing

## Release Workflow

Versioning follows [Semantic Versioning](https://semver.org/). Changes are tracked in `CHANGELOG.md` using the [Keep a Changelog](https://keepachangelog.com/) format.

### During Development

Every user-facing change updates the `[Unreleased]` section of `CHANGELOG.md` in the same commit or PR. Section order: Added → Changed → Deprecated → Removed → Fixed → Security.

### Cutting a Release

1. Promote `[Unreleased]` to a new `[X.Y.Z] - YYYY-MM-DD` heading; leave `[Unreleased]` empty again; update the footer compare links.
2. SemVer rules:
   - New feature → minor bump (`1.0.0` → `1.1.0`)
   - Bug-fix only → patch bump (`1.0.0` → `1.0.1`)
   - Breaking public API change → major bump (`1.0.0` → `2.0.0`)
3. Create an **annotated** tag. Never use a lightweight tag: it carries no author or date and breaks `git describe`.
   ```bash
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   ```
4. Push branch and tag separately so each step is explicit:
   ```bash
   git push origin master
   git push origin vX.Y.Z
   ```
5. Create the GitHub Release (visible to plugin managers and Watch→Releases subscribers):
   ```bash
   gh release create vX.Y.Z --title "vX.Y.Z: <short slug>" --notes "<changelog entry for this version>"
   ```

### Forbidden

- Force-pushing `master` or rewriting published tags.
- Moving a published tag to a different commit.
- Pushing without explicit user approval (see project-wide rule).
- Lightweight tags for releases.

### If Remote Has Diverged

Rebase, do not merge:
```bash
git fetch origin
git rebase origin/master
```
Verify the subsequent push is a fast-forward: `git push` output should show `A..B` (double-dot), not `+A B` (which indicates a forced update).

