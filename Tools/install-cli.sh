#!/usr/bin/env bash
#
# install-cli.sh — symlink quorra-cli onto the user's PATH.
#
# Usage:
#   ./install-cli.sh                       # installs to ~/.local/bin/quorra-cli (no sudo)
#   ./install-cli.sh /usr/local/bin        # installs to /usr/local/bin/quorra-cli (may prompt for sudo)
#   ./install-cli.sh --uninstall           # removes the symlink from ~/.local/bin
#
# The symlink target is:
#   /Applications/Quorra.app/Contents/MacOS/quorra-cli
#
# This means App Store / Homebrew Cask updates flip the symlink target
# automatically — no re-edit of ~/.aws/config or PATH required.

set -euo pipefail

readonly APP_BUNDLE="/Applications/Quorra.app"
readonly CLI_BINARY="${APP_BUNDLE}/Contents/MacOS/quorra-cli"
readonly DEFAULT_DIR="${HOME}/.local/bin"

usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage 0
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    target="${DEFAULT_DIR}/quorra-cli"
    if [[ -L "$target" ]]; then
        rm "$target"
        echo "Removed: $target"
    else
        echo "Not found: $target" >&2
        exit 1
    fi
    exit 0
fi

install_dir="${1:-$DEFAULT_DIR}"

if [[ ! -x "$CLI_BINARY" ]]; then
    echo "error: $CLI_BINARY not found or not executable" >&2
    echo "       Install Quorra.app to /Applications first." >&2
    exit 1
fi

mkdir -p "$install_dir"

target="${install_dir}/quorra-cli"
if [[ -e "$target" || -L "$target" ]]; then
    echo "warning: $target already exists; replacing" >&2
    rm "$target"
fi

ln -s "$CLI_BINARY" "$target"

echo "Linked: $target -> $CLI_BINARY"

case ":$PATH:" in
    *":${install_dir}:"*) ;;
    *)
        echo
        echo "note: $install_dir is not on your PATH."
        echo "      Add this to your shell profile:"
        echo "        export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac
