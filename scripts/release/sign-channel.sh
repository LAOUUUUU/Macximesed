#!/bin/bash
# Signs a channel file with the Ed25519 key in $MACX_UPDATE_SIGNING_KEY (base64, 32 raw bytes) and checks
# that the key's public half is the one built into macx, so a wrong secret can't publish files nobody accepts.
# Usage: MACX_UPDATE_SIGNING_KEY=... scripts/release/sign-channel.sh channel/v1.json
#        MACX_BETA_SIGNING_KEY=... scripts/release/sign-channel.sh --beta beta-v1.json   (checked against UpdateKeys.beta)
set -euo pipefail
ROLE=trusted
if [ "${1:-}" = "--beta" ]; then ROLE=beta; shift; fi
FILE="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$ROLE" = beta ]; then
    : "${MACX_BETA_SIGNING_KEY:?MACX_BETA_SIGNING_KEY is not set}"
    MACX_UPDATE_SIGNING_KEY="$MACX_BETA_SIGNING_KEY"
fi
: "${MACX_UPDATE_SIGNING_KEY:?MACX_UPDATE_SIGNING_KEY is not set}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
umask 077
# PKCS#8 wrapper for a raw Ed25519 private key.
{ printf '302e020100300506032b657004220420' | xxd -r -p; printf '%s' "$MACX_UPDATE_SIGNING_KEY" | base64 -d; } > "$WORK/key.der"
openssl pkey -inform DER -in "$WORK/key.der" -out "$WORK/key.pem"
PUB=$(openssl pkey -in "$WORK/key.pem" -pubout -outform DER | tail -c 32 | base64)
WANT=$(grep -oE "$ROLE"': \[Data\] = \["[A-Za-z0-9+/=]+' "$ROOT/Sources/MacxCore/Update.swift" | grep -oE '[A-Za-z0-9+/=]{40,}' | head -1)
[ -n "$WANT" ] || { echo "No $ROLE key is built into macx yet."; exit 1; }
[ "$PUB" = "$WANT" ] || { echo "The signing key's public half ($PUB) isn't the one built into macx ($WANT)."; exit 1; }
openssl pkeyutl -sign -rawin -inkey "$WORK/key.pem" -in "$FILE" -out "$FILE.sig"
openssl pkey -in "$WORK/key.pem" -pubout -out "$WORK/pub.pem"
openssl pkeyutl -verify -rawin -pubin -inkey "$WORK/pub.pem" -in "$FILE" -sigfile "$FILE.sig" >/dev/null
echo "Signed $FILE ($(wc -c < "$FILE.sig" | tr -d ' ')-byte Ed25519 signature, key $PUB)."
