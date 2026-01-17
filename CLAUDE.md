# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

```bash
# Run all checks (formatting + smoke test + tests) - use before PRs
./scripts/check.sh

# Format Lua files
stylua lua/numb

# Verify plugin loads
nvim --headless +"lua require('numb').setup()" +qall

# Run headless tests directly
nvim --headless -u tests/init.lua -i NONE -n +"lua require('tests.run').run()" +qall

# Manual testing in Neovim
:lua require('numb').setup{centered_peeking=false}
# Then try :{number} commands like :15, :+5, :-3
```

## Project Structure

Code lives under `lua/numb/`; `init.lua` exposes the user-facing API while `log.lua` holds lightweight diagnostics helpers. Tooling configs (`stylua.toml`, `lua-format`) sit at repo root. Headless regression tests live in `tests/` (`tests/init.lua` wires Neovim, `tests/run.lua` defines scenarios).

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
- Configuration options (`number_only`)

Extend `tests/run.lua` whenever you fix a bug or add a new option. CI runs `scripts/check.sh` on every push and PR to `master`.

### Test Coverage Checklist

When adding tests, ensure coverage for:
- [ ] Absolute line numbers (`:10`, `:42`)
- [ ] Relative forward (`:+5`, `:+`)
- [ ] Relative backward (`:-3`, `:-`)
- [ ] Complex expressions (`:+2+3`, `:-1+5`, `:10-2`)
- [ ] Out-of-bounds clamping (high and low)
- [ ] Window option restoration after confirm/abort
- [ ] Sequential jumps without state pollution

### Edge Cases

| Scenario | Expected Behavior |
|----------|------------------|
| `:9999` in 100-line buffer | Preview line 100, no errors |
| `:-100` from line 5 | Vim rejects negative ranges |
| `:++` from line 5 | Jumps to line 7 (5+1+1) |
| Invalid pattern `:abc` | No preview, plugin inactive |

## Style

- 2-space indentation, 120 column limit (see `stylua.toml`)
- No call parentheses for simple calls: `require "numb.log"` not `require("numb.log")`
- Prefer descriptive local names (`peek_line`, `cursor_state`) over single letters
- Modules addressed as `require('numb.<submodule>')`; filenames lowercase with underscores
- Temporary `require('numb.log').info(...)` calls OK while debugging but must be removed before commit

## Commit & PR Guidelines

- Short, imperative commit summaries: `Add lazy.nvim instruction`, `Fix peek flicker (#42)`
- PRs must describe motivation, user-facing changes, and testing steps
- Attach screenshots/recordings when altering visuals

## Design Principles

- Keep dependencies minimal—no runtime requirements outside stock Neovim/Lua
- Prefer feature flags via `require('numb').setup{...}` over global state
- Document new options in `README.md`

