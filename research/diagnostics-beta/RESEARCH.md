# Research: verbose logs, bug and crash reports, and a beta channel of dev builds
**Date:** 2026-11-24
**Status:** Complete. Lao's decisions made 2026-11-24 (below); waiting for the go-ahead to build
**Researcher:** Claude Code

## Question
Lao, 2026-11-24: "add like verbose logging and send logs anonymously to maintainer to fix bugs or crashes and stuff like that and also add a beta version which installs builds from dev and the dev versions use the commit, they don't use numbers."

Three features:
1. **Verbose logging** that can be turned up when something goes wrong.
2. **Bug and crash reports** with those logs, sent to the maintainer anonymously.
3. **A beta channel** that installs builds from `dev`, named by commit.

## Context
- macx is a security tool, so two things matter more than usual:
  - its logs are sensitive (file paths with the account name, app and process names, alert details);
  - its updater is the most valuable thing to attack (whoever can sign an update runs code on every Mac).
- **The repo and the binary are public.** Any webhook URL, token or key built into macx is public: anyone could read it or spam it.
- **Lao's rules that apply here:**
  - never post to a webhook without checking its channel;
  - never put a webhook URL in chat, the repo or the vault;
  - the account name has leaked into this repo once already (see the vault note on checking staged files).
- Detailed findings, with every source opened and dated, are in three files next to this one:
  - [external-logging.md](external-logging.md)
  - [external-reports.md](external-reports.md)
  - [external-beta.md](external-beta.md)

## Findings

### Internal
- **No logging today.** There's no logger, no `--verbose` and no level. Output is `print()`:
  - The root daemon's stdout goes to `/Library/Logs/Macximesed/daemon.log` through launchd.
  - Alerts go to `~/Library/Logs/Macximesed/watch.jsonl`.
- **The update channel** (`Sources/MacxCore/Update.swift`, `.github/workflows/channel.yml`, `release.yml`):
  - **The file:** one signed file, `channel/v1.json` + Ed25519 `.sig`, on GitHub Pages.
  - **Ordering:** a global `sequence` (rollback protection) and `expires` (freeze protection).
  - **Version checks:** `SemVer` comparisons, and "never install an older version".
  - **Signing:** only in the `release` environment, which waits for Lao's approval. The private key is only that environment's secret.
- **Things in today's code that a beta channel must change:**
  - `ChannelVerifier` accepts any trusted key for any file. A beta key must not be added to `UpdateKeys.trusted`, or a beta key could sign a stable file.
  - `SemVer` doesn't understand `+build`. `dev.100+g…` would sort below `dev.99+g…`.
  - `UpdateState.lastSequence` is one number for everything. It needs to be per channel.
  - The installer checks that the download reports the version the signed file names (`versionMismatch`) and is newer (`notNewer`). Both assume version numbers.
- **CI** already builds on every push to `dev` (`ci.yml`). The release build only runs on `v*.*.*` tags.

### External (summary; details and sources in the three files)
- **Logging:**
  - Apple's unified logging (`os.Logger`) doesn't keep debug lines on disk and drops info lines.
  - Reading earlier runs back needs an admin user, and anything inserted into a message comes back as `<private>`. So it can't be the source of a bug report.
  - swift-log has no file output, and its current versions need Swift tools 6.2.
  - Apps that do this well (Ghostty, IINA, Pareto Security, Tailscale) write their own log files and build the report from those.
- **Crashes:**
  - macOS already writes a crash report (`.ips`, JSON) for every crash:
    - in `~/Library/Logs/DiagnosticReports` for macx and the app;
    - in `/Library/Logs/DiagnosticReports` for the root daemon, readable by admins only.
  - MetricKit never delivers to a launchd daemon.
  - Crash-catching libraries (Sentry, KSCrash, PLCrashReporter) put a large C crash handler into the root daemon and store reports unencrypted with a third party.
- **Sending:**
  - GitHub issues are never anonymous, and this repo's issues are public.
  - `mailto:` can't carry attachments.
  - TelemetryDeck takes no crash logs.
  - A small Cloudflare Worker on the free plan can take an encrypted report and forward it to a private Discord channel. The webhook URL stays a Worker secret and never appears in macx.
  - CryptoKit HPKE (macOS 14+) can encrypt each report to a public key in macx, so Cloudflare and Discord can't read it.
- **Law and norms:**
  - The EU data-protection board's guidelines (2024-10-07) treat software on a device that calls an API as needing consent.
  - Canada's privacy commissioner asks for express consent for sensitive data.
  - Firefox and Ghostty ask first. Homebrew's opt-out analytics drew lasting criticism.
- **Beta channels:**
  - Every project that orders dev builds pairs the commit with something that orders them: a build number (Ghostty, Neovim, Firefox) or a signed sequence.
  - Reusing the stable signing key or environment for automatic dev builds would expose the stable key to any dev push.
  - The standard fix is a separate beta key that stable installs never trust. It's TUF's "compartmentalized trust"; Firefox does the same with a different signing certificate per channel.
  - GitHub artifact attestations (Sigstore) have no Swift verifier and need an authenticated API, so they can't be the client's trust root.

## Recommendation

### 1. Verbose logging (no decisions needed)
- **Own logger, no new dependency.** About 150 lines in MacxCore.
- **Levels:** error, warning, info (default), debug, trace.
  - `--verbose` / `-v` turns on debug, `-vv` turns on trace.
  - `MACX_LOG=debug` overrides both, for the app and scripts.
  - The level is checked before the message is built.
- **Where logs go.** One file per role, so processes never fight over rotation:
  - `~/Library/Logs/Macximesed/cli.log` and `app.log`. Yours, and not a privacy-guarded folder.
  - `/Library/Logs/Macximesed/daemon.log` for the root daemon: written by root, `0644`, so you can read it but nothing running as you can change it.
  - Each file rotates at 1 MB, and 2 old files are kept.
- **The daemon's level** is set the way the Downloads watch is: `sudo macx daemon log debug|info`. It's stored in the root-owned launchd plist, so only root can change it.
- **What's never logged:** file contents, secrets or the environment. Home paths are written as `~` when the line is written.
- **Mirror:** notices and errors also go to the system log, so `log show` and sysdiagnose see them.

### 2. Bug and crash reports
- **Built on the Mac, redacted there, shown in full before anything leaves it.**
  - `macx report` in the terminal and *Report a problem…* in the app.
  - The report holds:
    - an optional description;
    - versions (macx, macOS, chip);
    - whether the watch is on and has Full Disk Access;
    - the last part of macx's own logs;
    - the last few alerts;
    - summaries of new macx crashes.
- **Redaction**, built from a list of known fields first and regex rules second:
  - The account name and full name are removed, and home paths become `~`.
  - File names under home keep only the top folder and the extension, unless a box is ticked.
  - Computer name, serial number, hardware UUID, MAC addresses and Wi-Fi names are dropped.
  - IPs become `<ip>` and emails become `<email>`.
  - Hashes of ordinary files are dropped. Malware hashes are kept.
  - Third-party process lists are off by default.
  - The preview says how many things were removed.
- **Crashes:** macx reads the crash reports macOS already writes and keeps only the crash itself:
  - exception, signal and macx's own frames;
  - macOS build and chip.
  - The per-Mac crash ID (`crashReporterKey`), pid and uptime are dropped.
  - The daemon can't ask anyone, so it never sends. It writes these summaries, already redacted, to a root-owned folder you can read (`/Library/Logs/Macximesed/crashes/`), and the app or `macx report` offers them next time.
- **Consent:** nothing is ever sent without a click.
  - Settings: *Crash reports: Ask each time* (default) or *Never*.
  - No "always send" in the first version.
  - *Copy* and *Save…* always work without the internet.
- **Where it goes:**
  - **Recommended: a Cloudflare Worker that forwards to a private Discord channel.**
    - The report is encrypted to Lao's public key on the Mac (HPKE, X25519 + ChaCha20-Poly1305), so Cloudflare and Discord only ever see an opaque file.
    - The Worker:
      - checks size (256 KB at most) and format;
      - rate-limits by IP;
      - posts the file with a random report ID;
      - stores no IPs (invocation logs off).
    - The webhook URL exists only as a Worker secret, which Lao sets themself.
    - macx shows the report ID, so a user can mention it in an issue or ask for it to be deleted.
    - Lao decrypts with a small script in `scripts/`. The private key lives in Bitwarden, separate from the update-signing keys.
  - **Always available as well:** save the report and open a prefilled GitHub issue. This is public and needs a GitHub account, so it's never anonymous. Security problems keep going through GitHub's private vulnerability reporting (SECURITY.md).
- **What "anonymous" can and can't mean:**
  - Cloudflare sees the sender's IP address and the time, as any website does; the Worker stores neither, and Discord only sees Cloudflare.
  - There's no install ID and no user ID.
  - What the user writes in the description isn't anonymous.
- **Published:** README gets a short "Bug and crash reports" section: what's sent, where it goes, that it's encrypted, how long it's kept (90 days) and how to ask for deletion.

### 3. Beta channel
- **Named by commit, no number shown.** A dev build reports `dev-1a2b3c4` (`macx --version`), and the app shows the same. Under the hood:
  - Which beta is newest comes from the signed beta file's own `sequence`, which already protects against rollback. macx installs the build it names when that commit differs from the installed one.
  - Each dev build also knows the release it comes after (`macxVersion` in the code, e.g. 0.3.0). When a newer stable comes out (0.4.0), it replaces the dev build.
  - The research suggested putting a build number in the version (`0.3.1-dev.412+g…`), like Ghostty and Neovim. It isn't needed here, because the signed sequence orders builds, and Lao asked for commits, not numbers.
- **Its own key and its own file:**
  - **The file:** `beta/v1.json` + `.sig`, with its own sequence and a short expiry (30 days). It never carries a security floor or the malware feed.
  - **The key:** a separate beta Ed25519 key. macx keeps two key lists, and a beta key can never sign a stable file.
  - **Who fetches it:** only Macs that chose beta. The stable security floor still applies to beta Macs.
- **Hosting:** a rolling GitHub prerelease called `dev`. It holds the beta file and the last ~15 dev tarballs (`macx-dev-<commit>-macos-universal.tar.gz`), so dev builds never touch the GitHub Pages site the stable channel lives on.
- **Two workflows, so a push to dev can't edit the steps that hold the beta key:**
  - **`beta-build.yml`**, on every push to `dev`:
    - no secrets;
    - test;
    - stamp the commit into a tracked `BuildInfo.swift`;
    - build the universal binary;
    - check `macx --version` says `dev-<commit>`;
    - upload the artifact.
  - **`beta-publish.yml`**, started when a build finishes (`workflow_run`). It always runs main's copy of the workflow:
    - re-hash the artifact;
    - check the commit is still dev's tip;
    - sign with the beta key in a `beta` environment;
    - upload to the `dev` prerelease.
  - The installed binary is never run in CI before it's signed.
- **Switching:**
  - `macx update --channel beta|stable`, and a Channel switch in Settings > Updates.
  - Updates work as they do now: a notice, then *Install* or `macx update`. A beta can never force an update; only the stable floor can.
- **Leaving beta:** you stay on the dev build until the next stable release replaces it. There's no instant downgrade in the first version: a downgrade path is one more thing that has to be secured.

## Lao's decisions (2026-11-24)
1. **Beta signing: fully automatic.**
   - Every push to `dev` that passes the tests is signed with the beta key and published, with no approval step.
   - The `beta` environment has no reviewer. Its deployment branches are limited to `main`, because `beta-publish.yml` runs main's copy through `workflow_run`.
   - Lao chose this over approving each build, knowing that a bad or compromised push to `dev` reaches beta Macs on its own. The hardening below matters more because of it:
     - a ruleset on `dev` (no force-push, no deletion, restricted pushers);
     - the beta key never trusted for stable;
     - the stable floor still applies to beta Macs.
2. **Reports go through the encrypted relay:** HPKE on the Mac, then a Cloudflare Worker, then a private Discord channel. *Copy*, *Save…* and a prefilled GitHub issue stay as fallbacks.
3. **Crash reports default to *Ask each time*.**
4. **No contact field.** The report ID is how someone follows up.

## Test plan sketch
- [ ] Logger:
  - lines below the level aren't written, and the message isn't built;
  - `-v`, `-vv` and `MACX_LOG` set the level;
  - rotation at the cap keeps 2 old files;
  - home paths become `~` when written.
- [ ] Redactor, over fixture logs with a fake account name, home path, computer name, serial, IPv4/IPv6, email and Wi-Fi name:
  - every one is removed;
  - malware hashes are kept;
  - the count of removals is right.
- [ ] Crash summary from a fixture `.ips`:
  - keeps the exception, the signal and macx's frames;
  - drops `crashReporterKey`, `pid`, `uptime` and `asi`;
  - ignores other programs' crashes.
- [ ] Report envelope:
  - HPKE seal and open round-trip with a test key;
  - a wrong key or a flipped byte fails;
  - the header (magic, key id) is checked;
  - the size cap is enforced.
- [ ] Beta versions:
  - `dev-<commit>` is parsed;
  - `SemVer` ignores `+build`;
  - a stable release newer than the dev build's base replaces it, and an equal one doesn't.
- [ ] Verifier roles:
  - a stable file signed with the beta key is rejected, and so is a beta file signed with the stable key;
  - a beta file carrying `minimumSafe` or `hashFeed` is rejected;
  - `lastSequence` is kept per channel;
  - a beta file can never force.

## Risks & unknowns
- **Automatic beta signing** (Lao's choice) ships whatever reaches dev to beta Macs. Anyone or anything with push access to `dev` (including a stolen GitHub token) can reach them, so `dev` needs a ruleset and the beta key must stay out of stable trust.
- **Redaction can miss things** in free-text alert details. Mitigations:
  - list-of-fields first;
  - fixture tests;
  - the full preview before sending;
  - no automatic sending.
- **Spam to the public Worker URL.** Free-plan limits are 100k requests a day, and the rate limit is best-effort. If abused: a kill switch on Pages (`reports: off` in a small signed file), rotating the webhook, or moving the Worker URL.
- **Losing the report key** makes stored reports unreadable. Keep it in Bitwarden. Its key-id byte allows rotation.
- **Unverified, to test on Lao's Mac:**
  - whether reading `~/Library/Logs/DiagnosticReports` sets off a privacy prompt (macOS 15 and 27);
  - whether the root daemon can read `/Library/Logs/DiagnosticReports` (it should, as root);
  - Discord's attachment limit for webhooks;
  - whether "immutable releases" is off in the repo settings (a rolling prerelease needs it off).

## Next steps
- [x] Lao answers the four decisions (2026-11-24).
- [ ] Then, in this order, each test-first:
  1. logger and `--verbose`;
  2. report builder, redaction, crash summaries, *Copy* / *Save*;
  3. encryption and the Worker (after Lao sets up the Worker, channel and key);
  4. beta client (version, verifier roles, per-channel state, Settings switch);
  5. beta workflows (after Lao makes the beta key and the `beta` environment).
- [ ] Lao's setup, when we get there:
  - Cloudflare Worker + secret;
  - a private Discord channel + webhook, kept out of chat, the repo and the vault;
  - report key pair;
  - beta signing key in Bitwarden;
  - `beta` environment.
