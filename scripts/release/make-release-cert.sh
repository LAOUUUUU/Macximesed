#!/bin/sh
# Makes the release code-signing certificate, "Macximesed Release Signing" (self-signed, RSA 2048, 10 years),
# and saves it as two secrets of the GitHub `release` environment, the only place release.yml reads them:
#   MACX_RELEASE_P12           the certificate and its private key (.p12, base64)
#   MACX_RELEASE_P12_PASSWORD  the .p12's password
# Every release's app is signed with it, so Full Disk Access survives updates for .pkg and .dmg installs.
# It also leaves a copy of the .p12 on your Desktop and shows its password once: put both in Bitwarden,
# then delete the file. Nothing goes into the repo, your keychain or shell history.
# Usage: scripts/release/make-release-cert.sh   (needs gh, logged in with the repo scope)
set -eu

REPO="${MACX_REPO:-LAOUUUUU/Macximesed}"
NAME="Macximesed Release Signing"
OUT="$HOME/Desktop/macximesed-release-signing.p12"

command -v gh >/dev/null || { echo "gh isn't installed (brew install gh)." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh isn't logged in: gh auth login" >&2; exit 1; }
if gh secret list --env release --repo "$REPO" 2>/dev/null | grep -q '^MACX_RELEASE_P12[[:space:]]'; then
    echo "The release environment already has MACX_RELEASE_P12. Making a new one would change the signature, and" >&2
    echo "everyone's Full Disk Access would need switching on again. Delete that secret first if you really mean it." >&2
    exit 1
fi
[ -e "$OUT" ] && { echo "$OUT already exists. Move it away first." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
umask 077
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD=$(/usr/bin/openssl rand -hex 24)
# macOS's own openssl (LibreSSL) writes the older .p12 format that `security import` reads.
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/release.p12" -passout "pass:$PASSWORD"

# Check it signs before saving anything: import into a throwaway keychain and sign a tiny app.
KC="$WORK/check.keychain-db"
KCPW=$(/usr/bin/openssl rand -hex 16)
security create-keychain -p "$KCPW" "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$WORK/release.p12" -k "$KC" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null 2>&1
mkdir -p "$WORK/Check.app/Contents/MacOS"
cp /usr/bin/true "$WORK/Check.app/Contents/MacOS/check"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.macximesed.check</string><key>CFBundleExecutable</key><string>check</string></dict></plist>' \
    > "$WORK/Check.app/Contents/Info.plist"
codesign --force --sign "$NAME" --keychain "$KC" "$WORK/Check.app" 2>/dev/null
REQ=$(codesign -d -r- "$WORK/Check.app" 2>&1 | sed -n 's/^designated => //p')
security delete-keychain "$KC"
case "$REQ" in
    *"certificate leaf"*) echo "The certificate signs correctly." ;;
    *) echo "The new certificate didn't sign correctly ($REQ). Nothing was saved." >&2; exit 1 ;;
esac

base64 -i "$WORK/release.p12" | gh secret set MACX_RELEASE_P12 --env release --repo "$REPO"
printf %s "$PASSWORD" | gh secret set MACX_RELEASE_P12_PASSWORD --env release --repo "$REPO"
cp "$WORK/release.p12" "$OUT"
FINGERPRINT=$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')

echo
echo "Saved MACX_RELEASE_P12 and MACX_RELEASE_P12_PASSWORD in the release environment of $REPO."
echo "Certificate SHA-1 (shows up in the app's signature): $FINGERPRINT"
echo
echo "Now put these two in Bitwarden, then delete the file:"
echo "  file:     $OUT"
printf "  password: %s\n" "$PASSWORD"
PASSWORD=""
