#!/usr/bin/env bash
set -euo pipefail

# Minimum Neovim version numb.nvim supports. Kept in sync with the version
# matrix in .github/workflows/ci.yml.
MIN_NVIM_VERSION="0.10"

# Every Lua directory that is part of the plugin, including the plugin/ shim and
# the headless test suite, so formatting and lint cannot drift there.
LUA_PATHS=(lua plugin tests)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/check.sh [stage ...]

Stages:
  format   stylua --check over the Lua sources
  lint     selene over the Lua sources
  nvim     Neovim version floor, load smoke test and the plugin test suite

With no arguments every stage runs. CI splits them so the tool-only stages run
once while the nvim stage runs across the Neovim version matrix.
EOF
}

run_format=1
run_lint=1
run_nvim=1

if [ "$#" -gt 0 ]; then
  run_format=0
  run_lint=0
  run_nvim=0
  for stage in "$@"; do
    case "$stage" in
      format) run_format=1 ;;
      lint) run_lint=1 ;;
      nvim) run_nvim=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown stage: $stage" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
fi

if [ "$run_format" -eq 1 ]; then
  echo "==> Formatting"
  if ! command -v stylua >/dev/null 2>&1; then
    echo "stylua not found. Install it (https://github.com/JohnnyMorganz/StyLua) to run formatting checks."
    exit 1
  fi
  stylua --check "${LUA_PATHS[@]}"
fi

if [ "$run_lint" -eq 1 ]; then
  echo "==> Lint"
  if ! command -v selene >/dev/null 2>&1; then
    echo "selene not found. Install it (https://github.com/Kampfkarren/selene) to run lint checks."
    exit 1
  fi
  selene "${LUA_PATHS[@]}"
fi

if [ "$run_nvim" -eq 1 ]; then
  echo "==> Neovim version"
  if ! command -v nvim >/dev/null 2>&1; then
    echo "nvim not found. Install Neovim ${MIN_NVIM_VERSION}+ to run the smoke test."
    exit 1
  fi
  # has() understands dev builds, so nightly is accepted while 0.9 and older are
  # rejected with a clear message instead of an obscure missing-API error later.
  if ! nvim --headless --clean \
    +"lua if vim.fn.has('nvim-${MIN_NVIM_VERSION}') == 1 then vim.cmd 'qall!' end" \
    +"cquit 1" >/dev/null 2>&1; then
    echo "Neovim $(nvim --version | sed -n '1s/^NVIM //p') is too old."
    echo "numb.nvim requires Neovim ${MIN_NVIM_VERSION} or newer."
    exit 1
  fi
  nvim --version | sed -n '1p'

  echo "==> Neovim smoke test"
  nvim --headless +"lua require('numb').setup()" +qall

  echo "==> Plugin tests"
  nvim --headless -u tests/init.lua -i NONE -n +"lua require('tests.run').run()" +qall
fi

echo "All checks passed."
