#!/bin/sh
# Makes Macximesed.app around a built macx binary and signs it. Used by scripts/install.sh (your own
# certificate) and by the release workflow (the release certificate), so both build the same bundle.
# Usage: scripts/make-app.sh BINARY OUT.app VERSION SIGN [KEYCHAIN]
#   SIGN is a certificate hash or name for codesign, or "-" for ad-hoc. KEYCHAIN limits codesign to one keychain.
set -eu

BIN="$1"; OUT="$2"; VERSION="$3"; SIGN="$4"; KEYCHAIN="${5:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$BIN" "$OUT/Contents/MacOS/macx"
chmod 755 "$OUT/Contents/MacOS/macx"
cat > "$OUT/Contents/Info.plist" <<PLIST
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
  <key>NSHumanReadableCopyright</key><string>MIT licence</string>
  <!-- Set only when opened from Finder, the Dock, open or a login item: then macx starts the Mac app.
       A shell run, the daemon and scripts never get it, so they stay the command-line tool. -->
  <key>LSEnvironment</key><dict><key>MACX_APP</key><string>1</string></dict>
</dict>
</plist>
PLIST

# The entitlements let `macx chamber` use the Virtualization framework (no paid Apple account needed).
if [ -n "$KEYCHAIN" ]; then
    codesign --force --sign "$SIGN" --keychain "$KEYCHAIN" --identifier dev.macximesed.macx \
        --entitlements "$HERE/macx.entitlements" "$OUT"
else
    codesign --force --sign "$SIGN" --identifier dev.macximesed.macx --entitlements "$HERE/macx.entitlements" "$OUT"
fi
codesign --verify --strict --deep "$OUT"
