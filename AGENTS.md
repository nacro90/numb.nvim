# Repository Guidelines

## Project Structure & Module Organization
Code lives under `lua/numb/`; `init.lua` exposes the user-facing API while `log.lua` holds lightweight diagnostics helpers. Tooling configs (`stylua.toml`, `lua-format`) sit at repo root so formatters can be run from anywhere. Headless regression tests live in `tests/` (`tests/init.lua` wires Neovim, `tests/run.lua` defines scenarios); demo media is hosted externally and runtime expectations are captured in the README.

## Build, Test, and Development Commands
- `nvim --headless +"lua require('numb').setup()" +qall` verifies the plugin loads cleanly inside stock Neovim.
- `stylua lua/numb` formats Lua files according to `stylua.toml`; append `--check` in CI to fail on drift.
- `lua-format -i lua/numb/init.lua` (or the specific file you touched) enforces the legacy formatter style when needed for table-heavy sections.

## Coding Style & Naming Conventions
Follow the Stylua config: 2-space indentation, 120-column cap, no call parentheses for simple calls. Legacy files may still use the `lua-format` 3-space style—respect the surrounding context when editing. Modules are addressed as `require('numb.<submodule>')`; keep filenames lowercase with underscores only when mirroring Neovim option names. Prefer descriptive local names (`peek_line`, `cursor_state`) over single letters, and return tables that expose only the documented API.

## Testing Guidelines
Run `scripts/check.sh` (or directly invoke `nvim --headless -u tests/init.lua -i NONE -n +"lua require('tests.run').run()" +qall`) to execute the automated headless regression tests covering option restoration, sequential jumps, and out-of-bounds clamps. Extend `tests/run.lua` whenever you fix a bug or add a new option. For exploratory work, still verify inside Neovim using `:lua require('numb').setup{centered_peeking=false}` and `:{number}` jumps. Temporary `require('numb.log').info(...)` calls are acceptable while debugging but must be removed before submission. Document any manual scenarios you covered in the PR description. CI (`.github/workflows/ci.yml`) runs the same script on every push to and pull request targeting `master`.

## Commit & Pull Request Guidelines
Commits should use short, imperative summaries similar to `Add lazy.nvim instruction` seen in history, optionally followed by a blank line and context. Squash unrelated changes and mention relevant issue numbers (e.g., `Fix peek flicker (#42)`). PRs must describe the motivation, outline user-facing changes, list testing steps, and attach screenshots or terminal recordings when altering visuals. Tag reviewers if the change touches user configuration or command behavior, and keep the checklist updated so maintainers can merge without back-and-forth.

## Agent-Specific Notes
Keep dependencies minimal—avoid adding runtime requirements outside stock Neovim/Lua. Prefer feature flags exposed through `require('numb').setup{...}` over global state, and document any new option in `README.md`. When unsure, open a draft PR with questions so maintainers can weigh in early.
