# Macximesed

Squeeze more speed out of macOS and catch stealer-style malware (like AMOS, the Atomic macOS Stealer) that XProtect misses.

> **Early work in progress.** `macx scan`, `macx clean` (Safe tier), `macx apps`, `macx check`, `macx persist`, `macx guard`, `macx privacy` and `macx undo` exist so far. See [STATUS.md](STATUS.md) for what's being built and [CHANGELOG.md](CHANGELOG.md) for what's done.

## What it will do
- **Speed:** clean caches and leftovers, remove apps you don't use, a Boost mode that pushes background work aside for the app you're using, a heat/throttle view, and game profiles.
- **Safety:** alert on new LaunchDaemons, LaunchAgents and login items (especially fake `com.apple.*` ones), flag pasted `curl | zsh` and `base64 -D | zsh` commands, check downloads before you open them, and watch what programs do live through Apple's `eslogger`.
- **Risk levels:** every change is tagged **Safe**, **Medium**, **Risky** or **Extreme**. Risky and Extreme ask three times and come with an undo. Nothing below Extreme touches SIP, Gatekeeper, XProtect, FileVault or the firewall.

It does not replace XProtect: keep that on. Without Apple's restricted Endpoint Security entitlement it can't block a program *before* it starts, only catch it as it happens. The full reasoning is in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).

## Requirements
- macOS 15 or later on Apple Silicon. Developed on macOS 27.
- Xcode 16 or later (Swift 6).

## Install
```bash
scripts/install.sh
```

This builds macx and installs one copy at `~/.local/bin/macx`. To install somewhere else, pass a folder: `scripts/install.sh /usr/local/bin`.

### Permissions (no popups)
macOS guards some folders with privacy popups: Documents, Desktop, Downloads, Pictures, Movies, Music, other apps' containers, iCloud Drive and external disks. **Without Full Disk Access, macx never reads them, so it never sets off a popup.** It tells you what it skipped instead.

To include those folders, give the installed binary Full Disk Access once:

```bash
macx privacy --open
```

Then click **+**, press Cmd-Shift-G, paste `~/.local/bin/macx`, and switch it on.

The installed macx counts as **its own app** for privacy permissions. Normally macOS credits a command-line tool's access to the terminal that started it. macx relaunches itself with `responsibility_spawnattrs_setdisclaim`, the call LLDB uses for the programs it debugs, so the permission belongs to macx, not to Terminal or your editor. Development builds in `.build/` don't do this. To force it either way, set `MACX_OWN_RESPONSIBILITY=0` or `=1`.

The binary is ad-hoc signed, so each reinstall looks new to macOS. After updating, switch Full Disk Access off and on again.

## Build from source
```bash
swift build -c release
```

```bash
.build/release/macx scan
```

## Commands
| Command | What it does | Needs root |
|---|---|---|
| `macx scan [--top N]` | Read-only report: SIP, Gatekeeper, FileVault and firewall state; heat/throttling; disk use; the N busiest processes (default 10). Changes nothing. | No |
| `macx clean --dry-run` | Lists the Safe cleanup items with their IDs and sizes. Changes nothing. | No |
| `macx clean [--only ID ...] [--include-unknown] [--include-in-use] [-y]` | Moves the chosen items into the undo folder: by default every item with a known owner that isn't in use. Asks first unless `-y`. | No |
| `macx apps [--unused [--days 90]] [--intel] [--sort size\|name\|used]` | Lists every app on the Mac, wherever it is, with its size, architecture, when it was last opened, and its folder. | No |
| `macx apps remove NAME\|BUNDLE-ID [--include-name-matches] [-y]` | Moves the app and its Library leftovers, matched by exact bundle ID (support files, caches, preferences, saved state, containers, launch agents), into the undo folder. Folders that only match the app's name are listed, and moved only with `--include-name-matches`. Refuses apps that are running, built into macOS, or built-in Apple apps. Apple's App Store apps (GarageBand, iMovie, Pages…) are allowed. Root-owned apps need `sudo`. | Sometimes |
| `macx apps leftovers [--remove ID ...] [-y]` | Lists files named after a bundle ID that no app or helper on this Mac has, skipping app-group IDs and empty items. Can move chosen groups to the undo folder. | No |
| `macx check FILE ... [--online]` | Checks a download before you open it: app, `.pkg`, `.dmg`, script, compiled AppleScript or any file. Shows the signature, Gatekeeper's decision, who downloaded it and when, the SHA-256, and what it would set up to run by itself. It reads scripts, package install scripts and the files inside disk images (mounted read-only and hidden, then ejected) for download-and-run, base64-hidden code (decoded and shown), quarantine stripping and password prompts. Verdict: *Looks OK*, *Be careful* or *DON'T OPEN THIS* (exit code 2). `--online` looks the SHA-256 up on abuse.ch MalwareBazaar, sending only the hash and using your key in `MACX_MALWAREBAZAAR_KEY`. | No |
| `macx persist [--all] [--min-severity low]` | Finds everything set to start by itself and flags what looks like malware. It reads launch daemons and agents (system and yours), login items and background tasks (from `sfltool dumpbtm`), cron, shell startup files, and hidden folders in Application Support. Read-only. | No |
| `macx persist --baseline` / `--diff` | Saves what's there now, then later shows what was added, removed or changed since, with findings for the new items. | No |
| `macx guard [history]` | Scans your shell histories for commands that download and run code, run hidden base64 code (decoded and shown), strip the quarantine flag, or ask for or check your password. Covers zsh (including Terminal's per-tab `~/.zsh_sessions`), bash, fish and `$HISTFILE`. Shows when each one ran. | No |
| `macx guard clipboard` | Checks the clipboard before you paste it into Terminal. Exit code 2 if it's dangerous. | No |
| `macx guard check -- COMMAND` | Checks one command. Exit code 2 if it's dangerous. | No |
| `macx guard install` / `uninstall` / `status` | Adds a zsh hook: when you press Enter on a dangerous command, it's stopped with an explanation, and pressing Enter again runs it anyway. It's one marked block in `.zshrc` (or `$ZDOTDIR/.zshrc`) that sources `~/.config/macximesed/guard.zsh`, and uninstalling removes exactly that. | No |
| `macx privacy [--open]` | Shows whether macx has Full Disk Access, who owns its permissions, and which folders it skips without access. `--open` opens the Settings pane. | No |
| `macx undo [list]` | Lists undo batches. | No |
| `macx undo restore ID` | Puts a batch back. Anything that already exists again at the original place is kept in the undo folder instead of being overwritten. | No |
| `macx undo purge [--days 7] [-y]` | **Permanently** deletes batches older than N days. This is the only command that really deletes, and it asks first. | No |

### No guessing
Macximesed decides from facts the system reports, so it works the same whatever your folder layout, language or CPU:

- **Who owns a cache or leftover:** its name has to be a bundle ID that some app or helper on this Mac really has, from Spotlight's index of every bundle. It can also be that bundle ID plus a dot, like `com.vendor.app.ShipIt` or `com.vendor.app.plist`. A tool's cache is whatever the tool itself reports: `brew --cache`, `npm config get cache`, `pip3 cache dir`, `yarn cache dir` and `pnpm store path`. Anything else is shown as **unknown owner** and is never picked by default.
- **In use:** a process has a file open inside it (read from the kernel through libproc), or its app is running (by exact bundle ID).
- **Where apps are:** Spotlight finds every app on any disk or folder. If Spotlight is off, Macximesed scans `/Applications`, `~/Applications` and `Applications` on each mounted volume.
- **Xcode DerivedData:** uses the custom location set in Xcode's settings, if there is one.
- **Command output** is read in the C locale, so a Mac set to another language gives the same results.
- **Intel Macs** get correct labels: "Intel", and "Apple silicon only (can't run here)".

### What the Safe tier cleans
- Each folder in `~/Library/Caches`, listed separately with its owner, so `--only` can pick it. Caches with an unknown owner need `--include-unknown` or `--only`.
- `~/Library/Logs`, Xcode DerivedData and iOS DeviceSupport, Simulator caches, and tool caches kept elsewhere (npm, pnpm…).

It never cleans:
- Apple's caches: `com.apple.*`, or caches owned by an Apple bundle.
- `~/.cache`, which often holds virtual environments and runtimes.
- Macximesed's own data.
- Empty items.

### What `macx persist` flags
Each rule comes from how AMOS and similar stealers stay on a Mac:

| Rule | Severity | Meaning |
|---|---|---|
| `fake-apple-folder` | critical | A hidden `.com.apple.*` folder in your Application Support |
| `fake-apple-label` | critical | A `com.apple.*` launch item outside the system volume that runs a script or a non-Apple program |
| `shell-loop` | high | Runs a `while … sleep` shell loop that keeps restarting something |
| `hidden-folder` | high in a Library folder, else medium | Runs something from a hidden (`.name`) folder |
| `temp-location` | high | Runs from `/tmp`, `/Users/Shared` or Downloads |
| `missing-program` | high for root autostart, else medium | Its program is gone: a leftover, or a payload that was removed |
| `unsigned-program` / `adhoc-program` | high for root, else medium | No signature, or an ad-hoc one with no developer identity |
| `download-to-shell`, `base64-to-shell`, `quarantine-strip`, `password-prompt`, `password-check` | high | Lines in shell startup files or cron that download and run code, decode hidden code, strip the quarantine flag, or ask for or check your password |
| `inline-script`, `hidden-support-folder`, `unreadable-plist` | medium | Worth a look |
| `apple-label-outside-system` | low | An Apple-named item outside `/System` that runs an Apple binary directly |
| `unreadable-program` | info | Root-only program whose signature can't be checked without `sudo` |

Signatures are read with the Security framework (`anchor apple`, team ID, ad-hoc flag). Nothing depends on parsing `codesign` output.

**Last used:** this comes from Spotlight. When Spotlight has no date, it's estimated from the newest change to the app's own bundle-ID files, and shown with `~`. Apps with no date at all are never counted as unused.

Cleaned items go to `~/Library/Application Support/Macximesed/Undo/<batch>/`, with a `manifest.json` per batch. Disk space only comes back after `macx undo purge`.

## Tests and checks
```bash
swift test
```

```bash
swift format lint --strict --recursive Sources Tests Package.swift
```

Formatting follows `.swift-format` (4-space indents, 140 columns). To format in place, run `swift format --in-place --recursive Sources Tests Package.swift`.

### CI
Every push and pull request runs these on GitHub-hosted Macs (free for public repos):

| Workflow | What it checks |
|---|---|
| `ci.yml`, lint | `swift format lint --strict` |
| `ci.yml`, test matrix | **macOS 15** (oldest supported), **macOS 26 Apple silicon**, **macOS 26 Intel**: build with warnings as errors, tests, release build, and a smoke run of every read-only command |
| `ci.yml`, sanitizers | Tests under AddressSanitizer and ThreadSanitizer |
| `ci.yml`, coverage | Line coverage, shown in the run summary |
| `ci.yml`, universal | A universal (arm64 + x86_64) `macx`, uploaded as a build artifact with its SHA-256 |
| `codeql.yml` | GitHub CodeQL security analysis of the Swift code, also weekly |
| `release.yml` | On a `v*.*.*` tag: checks the tag matches `macx --version`, tests, builds the universal binary and publishes a GitHub release with notes from this CHANGELOG |

Dependabot keeps the pinned action SHAs and the Swift package up to date, through pull requests to `dev`.

## Install a release
Each [release](https://github.com/LAOUUUUU/Macximesed/releases) has a universal `macx` (Apple silicon and Intel) with a SHA-256 file. The binary isn't signed yet, so after checking the hash:

```bash
tar -xzf macx-*-macos-universal.tar.gz && xattr -d com.apple.quarantine macx && ./macx --help
```

## Contributing
Pull requests go to `dev`. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: it covers setup, the test-first workflow, and the rules the code keeps (no guessing, nothing deleted without an undo, no privacy popups). Report security problems privately as described in [SECURITY.md](SECURITY.md). Everyone is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).

If `macx persist` flags something harmless or misses something, open a **Detection report** issue.

## License
[MIT](LICENSE)
