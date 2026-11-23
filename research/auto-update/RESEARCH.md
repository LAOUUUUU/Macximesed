# Research: Auto-update with a forced security floor, through GitHub Pages
**Date:** 2026-11-23
**Status:** Complete, waiting for Lao's approval and decisions
**Researcher:** Claude Code

## Question
How should macx update itself so people can update by hand whenever they like, but get updated automatically when the installed version has a real security problem? It should use GitHub Pages as the update point, which will also carry the planned malware-hash feed.

## Context
- Lao, 2026-11-23: "make it auto update and also speak to the github pages so if they want to manually update they can until there's a real security risk, then it will force it."
- Lao also suggested a GitHub Pages hash feed earlier the same day (STATUS: "Signed hash feed").
- **An updater is the most valuable target in any security tool.** Whoever can publish an update can run code on every Mac that installed macx. The design has to keep that power with one key that only Lao's release process can use.

## Findings

### Internal
- Releases already exist as a design: `release.yml` builds a universal binary and publishes a GitHub release when a `v*.*.*` tag is pushed. **No release has been cut yet** (dev is past 5 commits; Lao said "not yet" to 0.2.0).
- macx is installed at `~/.local/bin/macx` by `scripts/install.sh`. It's ad-hoc signed, and it re-execs itself so that macx, not the terminal, owns its privacy permissions.
- Actions are pinned by commit SHA, and Dependabot keeps them current.

### External
- **Rollback and freeze attacks** are the classic updater attacks: serving an old, signed but vulnerable version, or replaying an old "nothing new" manifest so clients never hear about a fix. The Update Framework (TUF) defends against these with version numbers and expiry dates inside the signed data. Ed25519 and SHA-256 are standard choices. TUF's own warning is that it's only as safe as its keys.
- **Ad-hoc signatures lose permissions on every update.** Apple DTS: ad-hoc code has no stable designated requirement, so macOS "is unable to tell that version N+1 of your app is the 'same code' as version N." A real signing identity (Apple Development or Developer ID) fixes this. A self-signed certificate is *untested*.
- **Command-line tools and Full Disk Access:** DTS says Full Disk Access has only ever been fully supported for *bundled* executables. A forum report says that since macOS 26.1, Privacy & Security lists only applications for Full Disk Access, not bare Unix executables. **This needs checking on macOS 27. If true, macx needs a small app bundle to hold its permission** (that's where step 11, the menu bar app, was going anyway).
- **GitHub Pages from Actions:** `actions/upload-pages-artifact` v5.0.0 and `actions/deploy-pages` v5.0.0 are current. Pin both by SHA when building.

## Sources
| Source | URL | Key takeaway |
|---|---|---|
| TUF security goals | https://theupdateframework.io/security/ | rollback, freeze and key-compromise attacks |
| TUF specification | https://theupdateframework.io/specification | signed versions and expiry; Ed25519 |
| Apple DTS: ad-hoc apps lose permissions after updating | https://developer.apple.com/forums/thread/795739 | no stable designated requirement for ad-hoc code |
| Apple DTS: Full Disk Access for command-line tools | https://developer.apple.com/forums/thread/756510 | only fully supported for bundled executables |
| macOS 26.1 Full Disk Access change | https://developer.apple.com/forums/thread/809549 | list shows only apps, not Unix executables |
| upload-pages-artifact releases | https://github.com/actions/upload-pages-artifact/releases | v5.0.0 |
| deploy-pages | https://github.com/actions/deploy-pages | v5.0.0 |

## Recommendation

### One signed channel file on GitHub Pages
`https://laouuuuu.github.io/Macximesed/channel/v1.json`, plus `v1.json.sig` (an Ed25519 signature over the exact bytes):

```json
{
  "schema": 1,
  "sequence": 42,
  "published": "2026-12-01T10:00:00Z",
  "expires": "2026-12-15T10:00:00Z",
  "latest": { "version": "0.3.0", "url": "https://github.com/LAOUUUUU/Macximesed/releases/download/v0.3.0/macx-v0.3.0-macos-universal.tar.gz",
              "sha256": "…", "notes": "https://github.com/LAOUUUUU/Macximesed/releases/tag/v0.3.0" },
  "minimumSafe": { "version": "0.2.1", "reason": "macx watch could be blinded by …", "advisory": "https://github.com/LAOUUUUU/Macximesed/security/advisories/…" },
  "hashFeed": { "url": "https://laouuuuu.github.io/Macximesed/feed/v1.json", "sha256": "…" }
}
```

### What macx does
- **Check** at most once a day, when any command runs, in the background so commands aren't slowed down. Only the channel file is requested, and nothing about the Mac is sent. GitHub sees the IP address, as it does for any web request.
- **Verify** the signature with the public key built into macx. Reject a `sequence` lower than the last one seen (rollback). Warn when the file is past `expires` (freeze). Never install a version older than the one installed.
- **Normal update available:** one line per day, *"macx 0.3.0 is out: run `macx update`"*. People update when they want.
- **Below `minimumSafe`:** the security floor. macx prints the reason and the advisory link, then **updates itself before running the command**:
  1. download the tarball;
  2. check its SHA-256 against the signed channel file;
  3. check it's a universal Mach-O `macx`;
  4. swap it in atomically;
  5. re-exec.

  If that fails (offline, for example), macx keeps working and shows a loud warning on every command until it succeeds.
- **`macx update`** installs the latest now. `macx update --check` only reports.

### Publishing (Lao only)
- When a release tag is pushed, `release.yml` builds the asset, then a `publish-channel` job writes `v1.json` with the asset's SHA-256, signs it, and deploys it to Pages.
- **Raising the security floor** is a manual workflow (`workflow_dispatch`) with inputs for the minimum safe version and the reason.
- **The signing job runs in a protected `release` environment** with Lao as the required reviewer, so nobody can sign without Lao approving. That includes a hijacked token, a malicious pull request or a Dependabot bump. The private key exists only as that environment's secret.

### Keys
- **Generate once:** an Ed25519 key pair made locally. The private key goes into the GitHub environment secret through `gh secret set`, read from stdin and never printed. The public key is compiled into macx.
- **Backup:** Lao keeps the private key in Bitwarden. **If it's lost, Macs running old versions can never be updated again**, so the backup matters.
- **Rotation:** the channel file can name a next key, signed by the current key, so a key can be swapped without stranding anyone.

## Risks & unknowns
- **A stolen signing key means a malicious update for everyone.** The protected environment and required review are the main defense, and the key must never live on a Mac that might be compromised. That applies to this Mac until it's erased and reinstalled.
- **Ad-hoc signing:** every update looks like a new program, so Full Disk Access has to be granted again after each update. The fix is a stable signing identity: Developer ID ($99/year), or an Apple Development certificate from a free account (untested for this), plus probably an app bundle (see the macOS 26.1 report).
- **Forced updates and offline Macs:** a Mac that can't reach GitHub can't be forced. It keeps working with warnings. That's deliberate: a security tool that stops working offline is worse.
- **"Forced" must stay rare.** Raise the floor only for real security bugs, otherwise people learn to block the updater.

## Test plan sketch
- [ ] The channel signature verifies with the built-in key. One flipped byte fails, a missing `.sig` fails, and another key fails.
- [ ] A lower `sequence` than last seen is rejected (rollback). Past `expires`, a warning, but no forced action from a stale file.
- [ ] Version comparison: 0.10.0 > 0.9.9, and pre-release tags are ordered.
- [ ] Below `minimumSafe` the forced path runs; at or above it, the notice path; with the latest installed, nothing.
- [ ] The update is refused if the tarball's SHA-256 doesn't match, it isn't a Mach-O named macx, or it's older than the installed one.
- [ ] The swap is atomic: on failure the old binary is still there and runs.
- [ ] Checks happen at most once a day (cache in Application Support). `MACX_NO_UPDATE_CHECK=1` turns them off for CI.

## Next steps (need Lao)
- [ ] Decide: can the security-floor check be turned off? (Recommended: no, only the daily notices.)
- [ ] Turn on GitHub Pages (Settings → Pages → Source: GitHub Actions) and create the `release` environment with Lao as required reviewer. Both are repo settings.
- [ ] Make the signing key and save the private key in Bitwarden.
- [ ] Cut the first release (0.2.0), so there's something to update to.
