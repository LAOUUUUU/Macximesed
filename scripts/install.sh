#!/bin/sh
# Builds macx and installs it as ~/Applications/Macximesed.app, with ~/.local/bin/macx pointing into it.
# On macOS 27 Full Disk Access isn't honoured for a bare command-line tool, so the app is what you add
# to Full Disk Access (macx privacy --open). macx runs as its own app, so the grant belongs to it.
# Usage: scripts/install.sh [bin-dir] [app-dir]   (defaults: ~/.local/bin and ~/Applications; no sudo needed)
set -eu

BIN_DIR="${1:-$HOME/.local/bin}"
APP_DIR="${2:-$HOME/Applications}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$APP_DIR/Macximesed.app"

echo "Building macx (release)..."
swift build --package-path "$ROOT" -c release >/dev/null
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)/macx"
VERSION=$(grep -Eo 'macxVersion = "[^"]+"' "$ROOT/Sources/MacxCore/Update.swift" | cut -d'"' -f2)

# Build the new bundle next to the old one, then swap, so a running copy keeps working.
mkdir -p "$APP_DIR" "$BIN_DIR"
NEW="$APP_DIR/.Macximesed.app.new"
rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS"
cp "$BIN" "$NEW/Contents/MacOS/macx"
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.macximesed.macx</string>
  <key>CFBundleName</key><string>Macximesed</string>
  <key>CFBundleExecutable</key><string>macx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Sign with an Apple Development identity when there is one, else the local self-signed "Macximesed Local
# Signing" identity (both are stable, so Full Disk Access sticks across updates); otherwise ad-hoc. MACX_SIGN_IDENTITY overrides ("-" forces ad-hoc).
IDS="$(security find-identity -p codesigning 2>/dev/null)"
DEV=$(printf '%s\n' "$IDS" | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "Apple Development: [^"]*"$/\1/p' | head -1)
LOCAL=$(printf '%s\n' "$IDS" | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "Macximesed Local Signing"( \(CSSMERR_TP_NOT_TRUSTED\))?$/\1/p' | head -1)
SIGN="${MACX_SIGN_IDENTITY:-${DEV:-$LOCAL}}"
SIGN="${SIGN:--}"
if [ "$SIGN" = "-" ]; then SIGNED_AS="ad-hoc (Full Disk Access won't stick on macOS 27; see README)"; elif [ "$SIGN" = "$LOCAL" ]; then SIGNED_AS="local self-signed identity (Macximesed Local Signing)"; else SIGNED_AS="identity $SIGN"; fi
# The entitlements let `macx chamber` use the Virtualization framework (no paid Apple account needed).
codesign --force --sign "$SIGN" --identifier dev.macximesed.macx --entitlements "$(dirname "$0")/macx.entitlements" "$NEW"
codesign --verify --strict "$NEW"
rm -rf "$APP"
mv "$NEW" "$APP"

# The command stays `macx`: a link into the app. An older plain copy is replaced.
ln -sfn "$APP/Contents/MacOS/macx" "$BIN_DIR/macx"

echo "Installed: $APP ($("$BIN_DIR/macx" --version))"
echo "Command:   $BIN_DIR/macx → the app"
echo "Signed:    $SIGNED_AS"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH. Add this to ~/.zshrc:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
echo
echo "Next: give the app Full Disk Access so macx watch can run and macx can include Documents, Downloads, etc.:"
echo "  macx privacy --open    then  +  → Applications (your home folder's) → Macximesed → switch it on."
if [ "$SIGN" = "-" ]; then
  echo "After a reinstall or update, switch it off and on again (ad-hoc signed: each build is new to macOS)."
else
  echo "Signed with a stable identity, so the switch stays on across reinstalls and updates."
fi
echo "To watch in the background, without a terminal:  sudo $BIN_DIR/macx daemon install"
