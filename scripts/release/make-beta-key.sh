#!/bin/sh
# Makes the beta signing key (Ed25519, separate from the stable update key) and sets up the GitHub side:
#   - the `beta` environment, which only `main` may deploy from, with no reviewer (Lao's choice: dev builds that
#     pass are signed automatically; research/diagnostics-beta/RESEARCH.md);
#   - its secret MACX_BETA_SIGNING_KEY;
#   - the public half written into Sources/MacxCore/Update.swift (UpdateKeys.beta), to commit.
# It also leaves the private key on your Desktop once: put it in Bitwarden, then delete the file.
# Usage: scripts/release/make-beta-key.sh   (needs gh, logged in with the repo scope)
set -eu

REPO="${MACX_REPO:-LAOUUUUU/Macximesed}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$HOME/Desktop/macximesed-beta-signing-key.txt"

command -v gh >/dev/null || { echo "gh isn't installed (brew install gh)." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh isn't logged in: gh auth login" >&2; exit 1; }
if gh secret list --env beta --repo "$REPO" 2>/dev/null | grep -q '^MACX_BETA_SIGNING_KEY[[:space:]]'; then
    echo "The beta environment already has MACX_BETA_SIGNING_KEY. A new key would cut off every beta Mac." >&2
    echo "Delete that secret first if you really mean it." >&2
    exit 1
fi
if grep -q 'beta: \[Data\] = \["' "$ROOT/Sources/MacxCore/Update.swift"; then
    echo "Update.swift already lists a beta key. Remove it first if you really mean to replace it." >&2
    exit 1
fi
[ -e "$OUT" ] && { echo "$OUT already exists. Move it away first." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
umask 077
# macOS's own openssl (LibreSSL) can't make Ed25519 keys; CryptoKit can.
cat > "$WORK/gen.swift" <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
KEYS="$(swift "$WORK/gen.swift")"
PRIVATE="$(printf '%s\n' "$KEYS" | sed -n 1p)"
PUBLIC="$(printf '%s\n' "$KEYS" | sed -n 2p)"
[ "${#PRIVATE}" -eq 44 ] && [ "${#PUBLIC}" -eq 44 ] || { echo "Key generation failed." >&2; exit 1; }

echo "Setting up the beta environment (deploys from main only, no reviewer)..."
gh api -X PUT "repos/$REPO/environments/beta" --input - >/dev/null <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
gh api -X POST "repos/$REPO/environments/beta/deployment-branch-policies" -f name=main -f type=branch >/dev/null 2>&1 || true

printf %s "$PRIVATE" | gh secret set MACX_BETA_SIGNING_KEY --env beta --repo "$REPO"
printf '%s\n' "$PRIVATE" > "$OUT"
PRIVATE=""

# The public half into macx, so beta Macs trust exactly this key (and stable never does).
/usr/bin/sed -i '' "s|public static let beta: \[Data\] = \[String\]().compactMap|public static let beta: [Data] = [\"$PUBLIC\"].compactMap|" \
    "$ROOT/Sources/MacxCore/Update.swift"
grep -q "$PUBLIC" "$ROOT/Sources/MacxCore/Update.swift" || { echo "Couldn't write the public key into Update.swift." >&2; exit 1; }

echo
echo "Saved MACX_BETA_SIGNING_KEY in the beta environment of $REPO."
echo "Public key (now in Sources/MacxCore/Update.swift, UpdateKeys.beta): $PUBLIC"
echo
echo "Put the private key in Bitwarden, then delete the file:"
echo "  $OUT"
