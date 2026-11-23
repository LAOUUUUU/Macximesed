#!/bin/sh
# Builds macx and installs one stable copy, so you grant it Full Disk Access once.
# Usage: scripts/install.sh [install-dir]     (default: ~/.local/bin, no sudo needed)
set -eu

DIR="${1:-$HOME/.local/bin}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Building macx (release)..."
swift build --package-path "$ROOT" -c release >/dev/null
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)/macx"

mkdir -p "$DIR"
# Replace, don't overwrite in place: a running copy keeps working and macOS sees one clean file.
cp "$BIN" "$DIR/macx.new"
codesign --force --sign - --identifier dev.macximesed.macx "$DIR/macx.new" 2>/dev/null
mv -f "$DIR/macx.new" "$DIR/macx"

echo "Installed: $DIR/macx ($("$DIR/macx" --version))"
case ":$PATH:" in
  *":$DIR:"*) ;;
  *) echo "Note: $DIR is not on your PATH. Add this to ~/.zshrc:  export PATH=\"$DIR:\$PATH\"" ;;
esac
echo
echo "Next: give this one binary Full Disk Access so it can include Documents, Downloads, containers and external disks:"
echo "  $DIR/macx privacy --open"
echo "Then click +, press Cmd-Shift-G, paste $DIR/macx and switch it on."
echo "After a reinstall, switch it off and on again (each build is a new binary to macOS)."
