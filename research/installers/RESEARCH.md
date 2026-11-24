# Research brief: .pkg and .dmg downloads, signed with a project certificate

Asked by Lao on 2026-11-24: "make a .pkg so install with all the stuff needed … keep the tar stuff also add .dmg". Lao picked a self-signed project certificate on CI (no paid Apple account).

## What macOS does with these files (checked 2026-11-24)
- A download that isn't notarized is blocked the first time it opens. The way through is System Settings > Privacy & Security > **Open Anyway**. Right-click > Open no longer gets past this ([Apple](https://support.apple.com/en-sg/102445), [Eclectic Light, 2026-08](https://eclecticlight.co/2026/08/11/how-can-you-run-code-that-hasnt-been-notarised/)). Only Apple notarization ($99/yr) removes the step. The release notes now explain it (dev 9f0d8ee).
- Completely unsigned code never runs on Apple silicon. A self-signed or ad-hoc signature is enough to run once Gatekeeper has been cleared.
- Full Disk Access is tied to the app's **designated requirement**. With a real certificate that's "identifier + certificate", so it stays the same across builds. Ad-hoc signing gives a cdhash, which is new on every build. This is why CI needs one fixed certificate.
- Home-folder installs with `enable_currentUserHome` are unreliable: Installer still defaults to /Applications and still asks for an admin password ([Apple forums](https://developer.apple.com/forums/thread/727809), [installer-dev](https://lists.apple.com/archives/installer-dev/2014/Dec/msg00004.html)). The usual fix is a postinstall script that finds the console user and moves the files into their home folder.

## The catch: updates
Today's updater (`Update.install`) downloads the bare `macx` binary, puts it in the app, and **re-signs the app with the user's own certificate**. A .pkg user doesn't have the project certificate's private key, which never leaves CI. Their updates would stop with `signingIdentityMissing`.

**Fix:** each release also publishes the whole signed app (`Macximesed-X.Y.Z-app.tar.gz`), and its SHA-256 goes into the signed update channel next to the binary's. When the installed app is signed with the project certificate, the updater:
1. downloads the app archive and checks the signed SHA-256, as it already does for the binary;
2. takes only one top-level `Macximesed.app`, with no links that point outside it;
3. runs `codesign --verify --strict --deep` on it and requires its designated requirement to **equal** the installed app's (same identifier and certificate), so a swapped certificate can never get in;
4. checks that it reports the signed version;
5. swaps it in with a rename. The old app is kept as the previous version for rollback.

Installs signed with your own certificate (like yours, from `install.sh`) keep the current binary-and-re-sign path unchanged. Old clients ignore the new channel field.

## Plan
1. **Certificate.** `scripts/release/make-release-cert.sh` makes a self-signed code-signing certificate, *Macximesed Release Signing* (RSA 2048, 10 years), and puts the .p12 and its password in the `release` environment with hidden input. Lao also saves the .p12 in Bitwarden. Nothing goes in the repo or the vault.
2. **CI signing.** `release.yml` imports the .p12 into a temporary keychain, builds the universal app bundle (same Info.plist and entitlements as `install.sh`, which are moved into one shared script), signs it, checks it, and deletes the keychain.
3. **.pkg** (`pkgbuild` + `productbuild`, both part of macOS): the payload is staged in `/Library/Application Support/Macximesed/staging`. The postinstall script finds the console user and moves the app to their `~/Applications`, links `~/.local/bin/macx`, sets the owner to that user (so updates work without root), and opens the app. First-run setup then walks through Full Disk Access and the background watch. The .pkg doesn't install the watch itself, because it only works after Full Disk Access is on.
4. **.dmg** (`hdiutil create -format UDZO`): the app plus an Applications link.
5. **.tar.gz** stays as it is.
6. **Tests first:** the update path for a whole app (requirement match, link and layout rejection, rollback), the postinstall script's user lookup (run against a temporary root), and the channel parsing the new field.
7. README "Install a release", CHANGELOG, STATUS.

## What needs Lao
- Run the certificate script once (hidden input), and save the .p12 in Bitwarden.
- After the first release with it, try the .pkg on your Mac: Open Anyway, install, setup. Moving your Mac from your own certificate to the project one means switching Full Disk Access on again once. Staying on `install.sh` is also fine.

## Not doing
- Notarization (paid).
- Installing the background watch from the .pkg (it needs Full Disk Access first).
- Installing to /Applications (root-owned, so the user's updater couldn't write to it).
