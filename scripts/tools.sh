#!/usr/bin/env bash
# Download the pinned formatter and linter.
#
#   scripts/tools.sh                  # into .tools/, which is gitignored
#   sudo scripts/tools.sh /usr/local/bin   # system wide, which is what CI does
#
# The versions live here and nowhere else, so bumping one is a single edit that
# every caller follows, CI included. Neither tool is written in Lua, so there is
# no way to vendor them; a pinned download is the alternative to "works on my
# machine".
set -euo pipefail

STYLUA_VERSION="0.20.0"
SELENE_VERSION="0.31.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$REPO_ROOT/.tools}"

case "$(uname -s)" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  *)
    echo "Unsupported operating system $(uname -s); install stylua and selene by hand." >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch="x86_64" ;;
  arm64 | aarch64) arch="aarch64" ;;
  *)
    echo "Unsupported architecture $(uname -m); install stylua and selene by hand." >&2
    exit 1
    ;;
esac

# selene publishes one archive per platform without an architecture suffix, and
# the "light" build is the one without the Lua runtime, which is all that is
# needed to lint.
stylua_url="https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-${os}-${arch}.zip"
selene_url="https://github.com/Kampfkarren/selene/releases/download/${SELENE_VERSION}/selene-light-${SELENE_VERSION}-${os}.zip"

mkdir -p "$TARGET"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fetch() {
  local name="$1" url="$2"
  echo "==> $name"
  curl -fsSL -o "$workdir/$name.zip" "$url"
  unzip -q -o "$workdir/$name.zip" "$name" -d "$workdir"
  install -m 0755 "$workdir/$name" "$TARGET/$name"
  "$TARGET/$name" --version
}

fetch stylua "$stylua_url"
fetch selene "$selene_url"

if [ "$TARGET" = "$REPO_ROOT/.tools" ]; then
  echo
  echo "Installed into .tools/. Put it on PATH for this shell:"
  echo
  echo "  export PATH=\"$TARGET:\$PATH\""
fi
