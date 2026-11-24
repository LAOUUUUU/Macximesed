#!/bin/sh
# Turns a signed Macximesed.app into the release downloads (plus a .sha256 for each):
#   Macximesed-VERSION-app.tar.gz  the whole signed app, which release-signed installs update from
#   Macximesed-VERSION.pkg         installer: app into ~/Applications, macx into ~/.local/bin, then first-run setup
#   Macximesed-VERSION.dmg         the app and an Applications link, to drag across
# Usage: scripts/release/make-installers.sh Macximesed.app VERSION OUT-DIR
set -eu

APP="$1"; VERSION="$2"; OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
# No extended attributes in any download: tar and pkgbuild would carry them as AppleDouble ._ files.
export COPYFILE_DISABLE=1
copy() { ditto --noextattr --noqtn --norsrc "$1" "$2" && xattr -cr "$2"; }
trap 'rm -rf "$WORK"' EXIT

codesign --verify --strict --deep "$APP"

# 1. The app archive: Macximesed.app at the top and nothing else (the updater refuses anything more).
copy "$APP" "$WORK/app/Macximesed.app"
tar -C "$WORK/app" -czf "$OUT/Macximesed-$VERSION-app.tar.gz" Macximesed.app

# 2. The package. The payload lands in a root-owned staging folder; the postinstall script moves it home.
copy "$APP" "$WORK/root/Macximesed.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
# Never "relocate" onto another copy with the same bundle ID somewhere else on disk: always the staging folder.
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" \
    --install-location "/Library/Application Support/Macximesed/staging" \
    --scripts "$HERE/pkg" --identifier dev.macximesed.pkg --version "$VERSION" "$WORK/macximesed.pkg" >/dev/null
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Macximesed $VERSION</title>
    <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <allowed-os-versions><os-version min="15.0"/></allowed-os-versions>
    <choices-outline><line choice="default"><line choice="dev.macximesed.pkg"/></line></choices-outline>
    <choice id="default"/>
    <choice id="dev.macximesed.pkg" visible="false"><pkg-ref id="dev.macximesed.pkg"/></choice>
    <pkg-ref id="dev.macximesed.pkg" version="$VERSION" onConclusion="none">macximesed.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" "$OUT/Macximesed-$VERSION.pkg" >/dev/null

# 3. The disk image.
mkdir -p "$WORK/dmg"
copy "$APP" "$WORK/dmg/Macximesed.app"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$OUT/Macximesed-$VERSION.dmg"
hdiutil create -quiet -volname "Macximesed $VERSION" -srcfolder "$WORK/dmg" -format UDZO "$OUT/Macximesed-$VERSION.dmg"

cd "$OUT"
for f in "Macximesed-$VERSION-app.tar.gz" "Macximesed-$VERSION.pkg" "Macximesed-$VERSION.dmg"; do
    shasum -a 256 "$f" > "$f.sha256"
done
ls -l "Macximesed-$VERSION"*
