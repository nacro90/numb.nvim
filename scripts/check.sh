#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Formatting"
if ! command -v stylua >/dev/null 2>&1; then
  echo "stylua not found. Install it (https://github.com/JohnnyMorganz/StyLua) to run formatting checks."
  exit 1
fi
stylua --check lua/numb

echo "==> Neovim smoke test"
if ! command -v nvim >/dev/null 2>&1; then
  echo "nvim not found. Install Neovim 0.7+ to run the smoke test."
  exit 1
fi
nvim --headless +"lua require('numb').setup()" +qall

echo "==> Plugin tests"
nvim --headless -u tests/init.lua -i NONE -n +"lua require('tests.run').run()" +qall

echo "All checks passed."
