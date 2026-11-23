# Macximesed

Squeeze more speed out of macOS and catch stealer-style malware (like AMOS, the Atomic macOS Stealer) that XProtect misses.

> **Early work in progress.** `macx scan`, `macx clean` (Safe tier), `macx apps`, the antivirus side (`macx check`, `macx persist`, `macx guard`, `macx watch`) is done. Cleanup so far is `macx scan`, `macx clean` (Safe tier) and `macx apps`, plus `macx privacy` and `macx undo`. See [STATUS.md](STATUS.md) for what's being built and [CHANGELOG.md](CHANGELOG.md) for what's done.

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

### Updates
macx checks [the update channel](https://laouuuuu.github.io/Macximesed/) once a day and tells you when a new version is out. **Updating is up to you** (`macx update`), with one exception: if the signed channel says your version has a security problem (`minimumSafe`), macx updates itself before running your next command, and then carries on. If it can't (offline, say), it keeps working and keeps warning you. `macx update --notices off` turns off the "new version" message. The security check can't be turned off. `MACX_NO_UPDATE_CHECK=1` skips it entirely, for CI and tests.

How it stays safe:
- **One signed file.** The channel is a single file, signed with Ed25519. macx only accepts the public key built into it.
- **The key is guarded.** The private key exists only as a secret of the repo's protected `release` environment, which needs the maintainer's approval for every signing.
- **Replays don't work.** Each file has a sequence number, so macx rejects one older than any it has already seen. Each file also expires after 90 days, and an expired file can't force anything.
- **Downloads are checked.** A download must match the signed SHA-256, be a Mach-O called `macx`, and report the signed version. It must also be newer than what's installed.
- **Swaps are safe.** The new binary is swapped in atomically, and the old one is kept as `macx.previous`.

macx is still ad-hoc signed, so macOS sees each update as a new program. If you gave macx Full Disk Access, switch it off and on again after an update.

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
| `macx persist --case` | Also records an incident case from the high and critical findings. | No |
| `macx persist --baseline` / `--diff` | Saves what's there now, then later shows what was added, removed or changed since, with findings for the new items. | No |
| `macx guard [history]` | Scans your shell histories for commands that download and run code, run hidden base64 code (decoded and shown), strip the quarantine flag, or ask for or check your password. Covers zsh (including Terminal's per-tab `~/.zsh_sessions`), bash, fish and `$HISTFILE`. Shows when each one ran. | No |
| `macx guard clipboard` | Checks the clipboard before you paste it into Terminal. Exit code 2 if it's dangerous. | No |
| `macx guard check -- COMMAND` | Checks one command. Exit code 2 if it's dangerous, 3 if it downloads code to run (inspect it). | No |
| `macx guard inspect -- COMMAND [--no-run] [-y]` | **Reads a script before it runs.** Code it can't resolve (`eval "$var"`, a link worked out at run time, a script it writes and then runs, a program it downloads) is reported as **unknown**, never as safe. For `curl URL \| sh`, `bash <(curl URL)`, `sh -c "$(curl URL)"` or `curl -o f URL && sh f`, including disguised or base64-hidden versions, macx downloads the script the way curl would, without running it. It reports what the script does (password prompts, `dscl` checks, keychain or browser data, uploads, launch items, closing Terminal, hidden code, more downloads followed one level) and where it came from (bare IP, plain http, a redirect, a site you've never used in your shell, a program instead of a script). If you go ahead, it runs **the copy it inspected**: the SHA-256 is checked again just before running, and `curl | sh` style scripts are fed to the shell from memory, so nothing can swap them. Dangerous results need you to type `RUN`. | No |
| `macx guard install` / `uninstall` / `status` | Adds a zsh hook. When you press Enter on a command that downloads code to run, it's turned into `macx guard inspect`, so you see the script before anything runs. Any other dangerous command is stopped with an explanation, and pressing Enter again runs it anyway. It's one marked block in `.zshrc` (or `$ZDOTDIR/.zshrc`) that sources `~/.config/macximesed/guard.zsh`, and uninstalling removes exactly that. | No |
| `sudo macx watch [--suspend] [--min-severity medium]` | **Live watch** through Apple's `eslogger`. It checks every program start, launch-item write, quarantine removal and new background item as it happens: pasted download-and-run or base64 commands (decoded), fake password prompts, `dscl -authonly` password checks (the password is masked), fake `com.apple.*` launch items and folders, and unsigned programs starting from hidden or temp folders. `--suspend` freezes (SIGSTOP) the process behind a critical alert. Alerts are saved to `~/Library/Logs/Macximesed/watch.jsonl`. Needs Full Disk Access for macx (see *Permissions*). | **Yes** |
| `macx watch --replay FILE` | Runs the same rules over a saved eslogger JSON Lines file. | No |
| `macx incident [list]` / `show ID` / `contain ID [-y]` | **Incident response.** Each case is a private folder with read-only copies and SHA-256 hashes of the files involved, the process tree (who started it, what it started), the alert timeline, and a summary with what to do next. `contain` moves the case's launch items, hidden folders and temp-folder programs into the undo folder (nothing is deleted), prints the `launchctl bootout` commands for anything still running, and gives the password- and key-rotation checklist. | Sometimes |
| `macx privacy [--open]` | Shows whether macx has Full Disk Access, who owns its permissions, and which folders it skips without access. `--open` opens the Settings pane. | No |
| `macx update [--check] [--notices on\|off]` | Updates from the signed channel, or just checks. | No |
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

### Why not a blocklist of bad sites?
Stealer sites and IP addresses change all the time, so a list is always out of date, and a dangerous command can be dressed up to look harmless. macx defends in layers instead:
1. **Undo the disguise.** `c""url`, `c\url`, `$'\x63url'`, variables set earlier in the paste, `$(printf '\x..')`, `echo … | rev` and base64 are all unpacked before checking.
2. **Read what the link serves** (`macx guard inspect`) and judge the script by what it does, not by its URL. Then run the exact copy that was read.
3. **Catch it in the act** (`sudo macx watch --suspend`). A disguised script still has to show a password prompt, check the password, read the keychain or add a launch daemon.
4. **Leave little to steal.** Use a standard (non-admin) account day to day, keep passwords in a password manager rather than the browser, give SSH keys passphrases, use passkeys or 2FA, and run an outbound firewall such as LuLu.

### What the live watch can and can't do
**It observes. It can't prevent.** eslogger only gives Endpoint Security's *notify* events: it says what happened just after it happened. Blocking something before it runs needs *auth* events, which need Apple's restricted Endpoint Security entitlement. macx doesn't have that entitlement.

| | What | How macx uses it |
|---|---|---|
| **Observed, used** | `exec` (program starts, with arguments) | download-to-shell and base64 payloads, password prompts, `dscl -authonly`, unsigned programs from hidden or temp folders |
| | `create`, `rename` (new files) | new launch items, fake `com.apple.*` launch items, hidden `.com.apple.*` folders |
| | `deleteextattr` | quarantine flag removed |
| | `btm_launch_item_add` | new login or background items, checked for unsigned programs |
| **Observed, not used** | `open` | Too noisy to watch live, so keychain and browser-file reads are only seen through what the reading program does next. |
| | `setextattr`, `authentication`, `tcc_modify`, `xp_malware_detected`, others | Available (`eslogger --list-events`), not yet in the rules. |
| **Prevented** | nothing | No auth events without Apple's entitlement. |
| **Evidence** | every critical alert | A case is recorded right after the freeze, while the process still exists (see `macx incident`). Under sudo it's owned by you, not root. |
| **After the fact** | `--suspend` | Stops (SIGSTOP) the flagged process and everything it started, top-down, so a stopped parent can't start new children. It re-reads the process tree until no new child appears, and shows who started the process. |

eslogger ignores processes in its own process group, so anything started from the same shell job as `macx watch` is invisible to it. Run the watcher in its own terminal tab. How long a flagged process runs before it's stopped is measured by `scripts/eval/runtime.sh`, but hasn't been measured on a real Mac yet. That's the runtime simulation step in [STATUS.md](STATUS.md). Until there are numbers, treat `--suspend` as damage limitation, not prevention. AMOS's steps all come before the theft finishes: the pasted command, the fake password prompt, the password check, the launch daemon and the hidden folder. eslogger's output format isn't a stable API, so the parser reads every field as optional and works out the event type from the event's name.

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

### Evaluation
These measure what macx catches and what it gets wrong. They don't test individual functions.

- **Static** (`scripts/eval/static.sh`, no root needed): runs `macx guard inspect --no-run` against 17 harmless imitations of stealer techniques (served locally from `Tests/Evaluation/served`) and 11 real, widely used installers (Homebrew, rustup, nvm, Oh My Zsh, bun, deno, uv, pnpm, starship, fnm, Spicetify). Latest result: [research/evaluation/static-results.md](research/evaluation/static-results.md). No attacks were missed and no installer was marked dangerous. 4 installers download a program that can't be read as text, so they're reported as "parts couldn't be checked".
- **Runtime** (`sudo scripts/eval/runtime.sh`): starts `macx watch --suspend`, fires harmless versions of each stealer step and measures:
  - whether each one raised an alert;
  - the delay from action to alert, and from alert to freeze;
  - how much a busy process got done before it was frozen;
  - whether a child it started was frozen too;
  - macx and eslogger CPU and memory, idle and busy.

  It writes [research/evaluation/runtime-results.md](research/evaluation/runtime-results.md). It needs root and Full Disk Access for macx, so it has to be run on a real Mac by hand.

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
