# Macximesed

[![CI](https://github.com/LAOUUUUU/Macximesed/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/LAOUUUUU/Macximesed/actions/workflows/ci.yml)
[![CodeQL](https://github.com/LAOUUUUU/Macximesed/actions/workflows/codeql.yml/badge.svg?branch=dev)](https://github.com/LAOUUUUU/Macximesed/actions/workflows/codeql.yml)
[![Latest release](https://img.shields.io/github/v/release/LAOUUUUU/Macximesed)](https://github.com/LAOUUUUU/Macximesed/releases/latest)
[![License: MIT](https://img.shields.io/github/license/LAOUUUUU/Macximesed)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![Discord](https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white)](https://discord.gg/gKthUMyZgH)

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

This builds **`~/Applications/Macximesed.app`**, a background app with no Dock icon and macx inside it, and points `~/.local/bin/macx` at it, so the command is still just `macx`. To use other folders, pass them: `scripts/install.sh <bin-dir> <app-dir>`.

### The app and the menu bar
Open **Macximesed** from your Applications folder (or run `macx app`). It's the same program as the command: opened from Finder, the Dock, `open` or a login item it starts the app; run from a shell it's the CLI, exactly as before. So the app has the same bundle id, signature and Full Disk Access as `macx` and the background watch, and nothing in Settings needs redoing.

- **Menu bar:** a small square mark. It's filled while the watch runs, an outline while it's paused, and struck through when nothing is watching. A red dot means a critical alert you haven't looked at. Click it for the state and the latest alerts. Right-click it for Pause, Resume, Open and Quit.
- **The window** has these screens:
  - **Protection:** the watch's state and the last 7 days of alerts, grouped by rule and program, with counts.
  - **Startup items:** the `persist` scan, with a baseline. Your own items can be removed, and they go to the undo store.
  - **Check a file:** drop a file on it or choose one.
  - **Clean:** the Safe tier, with undo.
  - **Apps:** remove an app and its leftovers, with undo.
  - **Settings:** Full Disk Access, install or uninstall the watch, freeze on critical, updates, and open at login.
- **Explanations sit behind the ⓘ buttons.**
- **Pause, install, restart and uninstall ask for your administrator password**, because they run `sudo macx daemon …` underneath.
- **"Expected"** hides a program's non-critical alerts in the app only. The watch still logs them and still notifies you. Critical alerts can't be hidden.

### Permissions (no popups)
macOS guards some folders with privacy popups: Documents, Desktop, Downloads, Pictures, Movies, Music, other apps' containers, iCloud Drive and external disks. **Without Full Disk Access, macx never reads them, so it never sets off a popup.** It tells you what it skipped instead.

To include those folders, give the installed binary Full Disk Access once:

```bash
macx privacy --open
```

Then click **+**, choose **Macximesed** from the Applications folder in your home folder, and switch it on. On macOS 27 Full Disk Access only counts for the app, not the bare binary. **On macOS 27.3 and later**, if macOS offers to give it only specific folders, choose full access instead: the live watch runs Apple's `eslogger`, which needs full Full Disk Access (a folders-only grant is untested and very likely refused). Grants made before updating to 27.3 stay in effect.

The installed macx counts as **its own app** for privacy permissions. Normally macOS credits a command-line tool's access to the terminal that started it. macx relaunches itself with `responsibility_spawnattrs_setdisclaim`, the call LLDB uses for the programs it debugs, so the permission belongs to macx, not to Terminal or your editor. Development builds in `.build/` don't do this. To force it either way, set `MACX_OWN_RESPONSIBILITY=0` or `=1`.

**Full Disk Access needs the app and a stable signature.** macOS 27 ignores Full Disk Access for a bare binary, so `scripts/install.sh` builds `~/Applications/Macximesed.app` and signs it with a stable identity: a free Apple Development certificate if you have one (Xcode → Settings → Accounts → Manage Certificates → **+**), otherwise a self-signed certificate called "Macximesed Local Signing" in your login keychain (no Apple ID needed). Without either it falls back to ad-hoc signing, and each rebuild looks like a new program to macOS.

**If Macximesed is listed and switched on but macx still says no:** macOS keeps the signature the app had when it was *first added* to the list, and switching it off and on doesn't update that. An entry added while the app was ad-hoc signed never matches the signed app. Remove it and add it again:

```bash
sudo tccutil reset SystemPolicyAllFiles dev.macximesed.macx
```

Then `macx privacy --open`, **+**, and choose Macximesed again. To see why access was refused, look for "Failed to match existing code requirement" in `/usr/bin/log show --last 5m --predicate 'process == "tccd"'`.

### Background watch
`sudo macx daemon install` runs the live watch from startup on, without a terminal. It's a launchd daemon that runs Macximesed.app's own `macx watch`, so Full Disk Access is checked against the app, not against Terminal or sudo. High and critical alerts show as notifications (at most one every 10 seconds; the rest are counted), and every alert goes to `~/Library/Logs/Macximesed/watch.jsonl`. `macx alerts [--follow]` shows them, and `macx daemon status` says whether it's running and, if not, why. Add `--suspend` to the install to freeze whatever is behind a critical alert. `sudo macx daemon restart` restarts it (after giving Full Disk Access, say), and `sudo macx daemon uninstall` removes it. `sudo macx daemon pause --for 1h` (from 1 minute to 24 hours) turns notifications and freezing off for a while; alerts are still logged, and the watch turns itself back on when the time is up. `sudo macx daemon resume` ends a pause early. Only root can pause it: the pause file is root-owned in `/Library/Logs/Macximesed`, and the watch ignores one that anyone else could have written. Measured on an M3: about 1% CPU and 16 MB.

### Detonation chamber
`macx chamber setup` downloads about 50 MB from Alpine Linux once: the base system, a kernel, bash, zsh and strace. Every file is checked against a SHA-256 pinned in macx (`data/chamber/manifest-aarch64.json`, made and verified by `scripts/chamber/make-manifest.py`). Then `macx chamber run FILE`:
1. builds a fresh boot image with the script, stand-ins for Mac commands (`osascript`, `security`, `dscl`, `system_profiler`, `sw_vers`, `uname`, `curl`, `sudo` and more, answering like a Mac on macOS 27.0.1), and bait files (a keychain, Chrome and Firefox passwords, an Exodus wallet);
2. boots it with Apple's Virtualization framework: one CPU, no disk, no network device, no shared folder;
3. runs the script once under `strace` (60 seconds at most; a run usually takes under 2 s) and powers off. Nothing survives the run;
4. judges the trace here with the live-watch rules plus chamber rules: keychain, browser and wallet reads, network attempts, VM checks (including across a pipe), and "checked for a VM, then quit".

A clean result means *nothing was seen*, not *safe*: malware can wait, ask for a click, or notice it's in a VM. The password boxes answer with a canary password, so a stealer carries on and shows what it does with it. The chamber needs the Virtualization entitlement, which `scripts/install.sh` and the updater sign the app with (no paid Apple account needed). Development builds in `.build/` don't have it. `MACX_CHAMBER_MIRROR=DIR` reads the setup files from a local folder instead of downloading them.

### Updates
macx checks [the update channel](https://laouuuuu.github.io/Macximesed/) once a day and tells you when a new version is out. **Updating is up to you** (`macx update`), with one exception: if the signed channel says your version has a security problem (`minimumSafe`), macx updates itself before running your next command, and then carries on. If it can't (offline, say), it keeps working and keeps warning you. `macx update --notices off` turns off the "new version" message. The security check can't be turned off. `MACX_NO_UPDATE_CHECK=1` skips it entirely, for CI and tests.

How it stays safe:
- **One signed file.** The channel is a single file, signed with Ed25519. macx only accepts the public key built into it.
- **The key is guarded.** The private key exists only as a secret of the repo's protected `release` environment, which needs the maintainer's approval for every signing.
- **Replays don't work.** Each file has a sequence number, so macx rejects one older than any it has already seen. Each file also expires after 90 days, and an expired file can't force anything.
- **Downloads are checked.** A download must match the signed SHA-256, be a Mach-O called `macx`, and report the signed version. It must also be newer than what's installed.
- **Swaps are safe.** The new binary is swapped in atomically, and the old one is kept as `macx.previous`.

Updates keep the app's signature, so Full Disk Access carries over. The updater re-signs with the same identity and the Virtualization entitlement, and three guards make sure an update can never cost the app its permissions:
- **It never installs as root.** Under `sudo` your signing identity (in your login keychain) isn't reachable; a security update waits for your next `macx` run without sudo.
- **The identity has to be there first.** If the app is signed with a stable identity and that identity can't be found, the update is held back and macx says why.
- **It checks afterwards.** macOS ties Full Disk Access to the app's code requirement. If that changed after re-signing, the previous version goes back automatically.

The background watch notices when its binary was updated and restarts on the new version by itself (within 30 s, no sudo).

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
| `macx check FILE ... [--online]` | Checks a download before you open it: app, `.pkg`, `.dmg`, script, compiled AppleScript or any file. Shows the signature, Gatekeeper's decision, who downloaded it and when, the SHA-256, and what it would set up to run by itself. It reads scripts, package install scripts and the files inside disk images (mounted read-only and hidden, then ejected) for download-and-run, base64-hidden code (decoded and shown), quarantine stripping and password prompts. Verdict: *Looks OK*, *Be careful* or *DON'T OPEN THIS* (exit code 2). The SHA-256 is always checked offline against the signed malware hash feed (see below). `--online` also looks the SHA-256 up on abuse.ch MalwareBazaar, sending only the hash and using your key in `MACX_MALWAREBAZAAR_KEY`. | No |
| `macx persist [--all] [--min-severity low]` | Finds everything set to start by itself and flags what looks like malware. It reads launch daemons and agents (system and yours), login items and background tasks (from `sfltool dumpbtm`, only with `sudo`: without root it asks for an admin password), cron, shell startup files, hidden folders in Application Support, and configuration profiles (yours without sudo, computer-wide ones with it). A profile you installed by hand that trusts a certificate, sets a proxy, forces browser settings or extensions, grants privacy permissions or changes Gatekeeper is flagged high; on a Mac an organisation manages (MDM), profiles are only listed. Read-only. | For login items and computer-wide profiles |
| `macx persist --case` | Also records an incident case from the high and critical findings. | No |
| `macx persist --baseline` / `--diff` | Saves what's there now, then later shows what was added, removed or changed since, with findings for the new items. | No |
| `macx guard [history]` | Scans your shell histories for commands that download and run code, run hidden base64 code (decoded and shown), strip the quarantine flag, or ask for or check your password. Covers zsh (including Terminal's per-tab `~/.zsh_sessions`), bash, fish and `$HISTFILE`. Shows when each one ran. | No |
| `macx guard clipboard` | Checks the clipboard before you paste it into Terminal. Exit code 2 if it's dangerous. | No |
| `macx guard check -- COMMAND` | Checks one command. Exit code 2 if it's dangerous, 3 if it downloads code to run (inspect it). | No |
| `macx guard inspect -- COMMAND [--no-run] [-y]` | **Reads a script before it runs.** Code it can't resolve (`eval "$var"`, a link worked out at run time, a script it writes and then runs, a program it downloads) is reported as **unknown**, never as safe. For `curl URL \| sh`, `bash <(curl URL)`, `sh -c "$(curl URL)"` or `curl -o f URL && sh f`, including disguised or base64-hidden versions, macx downloads the script the way curl would, without running it. It reports what the script does (password prompts, `dscl` checks, keychain or browser data, uploads, launch items, closing Terminal, hidden code, more downloads followed one level) and where it came from (bare IP, plain http, a redirect, a site you've never used in your shell, a program instead of a script). If you go ahead, it runs **the copy it inspected**: the SHA-256 is checked again just before running, and `curl | sh` style scripts are fed to the shell from memory, so nothing can swap them. Dangerous results need you to type `RUN`. | No |
| `macx guard install` / `uninstall` / `status` | Adds a zsh hook. When you press Enter on a command that downloads code to run, it's turned into `macx guard inspect`, so you see the script before anything runs. Any other dangerous command is stopped with an explanation, and it only runs if you type `RUN`. Pressing Enter again doesn't run it. It's one marked block in `.zshrc` (or `$ZDOTDIR/.zshrc`) that sources `~/.config/macximesed/guard.zsh`, and uninstalling removes exactly that. | No |
| `sudo macx watch [--suspend] [--min-severity medium]` | **Live watch** through Apple's `eslogger`. It checks every program start, launch-item write, quarantine removal and new background item as it happens: pasted download-and-run or base64 commands (decoded), fake password prompts, `dscl -authonly` password checks (the password is masked), fake `com.apple.*` launch items and folders, and unsigned programs starting from hidden or temp folders. `--suspend` freezes (SIGSTOP) the process behind a critical alert. Every process behind a high or critical alert, and what it starts, is followed for 5 minutes, and each new remote address it connects to is a high `network` alert (`--net-interval`, default 20 ms; 0 turns it off). Alerts are saved to `~/Library/Logs/Macximesed/watch.jsonl`. Needs Full Disk Access for macx (see *Permissions*). | **Yes** |
| `macx watch --replay FILE` | Runs the same rules over a saved eslogger JSON Lines file. | No |
| `macx top [--once] [-c 12]` | **Throttle view**, live: thermal state (Nominal → Critical; Serious and Critical mean throttling) and the finer thermal pressure, Low Power Mode, Boost, a heat and load strip, and the busiest processes by real CPU time (not Activity Monitor's residency %), with background-priority ones marked. | No |
| `macx boost on [--app NAME]` / `off` / `status` / `measure` | **Boost** gives one app more of the Mac: your busiest other apps go on background priority (efficiency cores), App Nap goes off for that app, Reduce Transparency and Reduce Motion go on, and the Mac stays awake. Apple's and other users' processes are never touched. Each change is saved before it's made, so `off` puts back exactly what was there, even after a crash. Clocks can't be raised on Apple silicon. `measure` benchmarks with and without Boost, so you can see whether it helps on your Mac. | No |
| `macx tune [list]` / `apply ID…` / `undo [ID…]` / `agents` | **Medium tier:** reversible settings (Reduce Transparency, Reduce Motion, no window animations, instant window resizing, no Dock launch bounce) and switching off third-party launch agents (`agent:LABEL`). Each one remembers what it replaced. | No |
| `macx games [list]` / `play NAME [--hud] [--no-boost]` / `add PATH` / `forget NAME` | **Games:** finds your games (App Store category, Game Mode support, known games and launchers such as Roblox, Steam and the Minecraft launchers, Steam's library, CrossOver bottles, ones you add) and says how best to run each. Intel-only games are flagged, since macOS 27 is the last version that runs Intel apps for most software. `play` turns Boost on, starts the game (`--hud` shows Apple's Metal Performance HUD), records heat and load, turns Boost off when it quits, and saves a summary to `~/Library/Logs/Macximesed/games/`. Game Mode itself can't be switched by another program; macOS turns it on for supported games in full screen. | No |
| `macx chamber setup` / `run FILE [--seconds 60] [-y] [--no-quarantine]` / `status` / `remove` | **Detonation chamber.** Runs a suspicious script in a throwaway Linux VM (about 60 MB) with no network, no disk and nothing shared with this Mac. Mac-only commands are stand-ins, and bait files sit where stealers look. Everything it does is recorded and judged here. *DON'T OPEN THIS* offers to quarantine the file into a restorable incident case (exit code 2). Scripts only: Mac apps and programs keep `macx check`. See *Detonation chamber*. | No |
| `macx net PID [--interval MS] [--seconds N] [--every] [--loopback]` | Shows where a process, and anything it starts, connects to, as it happens: each new remote address once. Reads the process's sockets from the kernel every 20 ms. Connections open for under about 20 ms can be missed ([measured](research/evaluation/network-results.md)). Your own processes work without sudo. | For other users' processes |
| `macx incident [list]` / `show ID` / `contain ID [-y]` | **Incident response.** Each case is a private folder with read-only copies and SHA-256 hashes of the files involved, the process tree (who started it, what it started), the alert timeline, and a summary with what to do next. `contain` moves the case's launch items, hidden folders and temp-folder programs into the undo folder (nothing is deleted), prints the `launchctl bootout` commands for anything still running, and gives the password- and key-rotation checklist. | Sometimes |
| `sudo macx daemon install [--suspend]` / `status` / `restart` / `pause [--for 1h]` / `resume` / `uninstall` | **Background watch**: `macx watch` as a launchd daemon from startup, with notifications for high and critical alerts. `status` needs no sudo. See *Background watch*. | **Yes** (not `status`) |
| `macx alerts [-n 20] [--min-severity low] [--follow]` | Shows saved alerts from the live and background watch. | No |
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

eslogger ignores processes in its own process group, so anything started from the same shell job as `macx watch` is invisible to it. Run the watcher in its own terminal tab. How long a flagged process runs before it's stopped is measured by `scripts/eval/runtime.sh`. On the first real run that was 0.15–0.25 s from action to freeze; see *Evaluation*. That's the runtime simulation step in [STATUS.md](STATUS.md). Until there are numbers, treat `--suspend` as damage limitation, not prevention. AMOS's steps all come before the theft finishes: the pasted command, the fake password prompt, the password check, the launch daemon and the hidden folder. eslogger's output format isn't a stable API, so the parser reads every field as optional and works out the event type from the event's name.

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

- **Static** (`scripts/eval/static.sh`, no root needed): runs `macx guard inspect --no-run` against 17 harmless imitations of stealer techniques (served locally from `Tests/Evaluation/served`) and 11 real, widely used installers (Homebrew, rustup, nvm, Oh My Zsh, bun, deno, uv, pnpm, starship, fnm, Spicetify). Persistence false positives are covered by a benign-software test suite (`BenignPersistenceTests`: 10 common legitimate launch items, none high or critical; the only medium is Homebrew's ad-hoc signed services). Latest static result: [research/evaluation/static-results.md](research/evaluation/static-results.md). No attacks were missed and no installer was marked dangerous. 4 installers download a program that can't be read as text, so they're reported as "parts couldn't be checked".
- **Runtime** (`sudo scripts/eval/runtime.sh`): starts `macx watch --suspend`, fires harmless versions of each stealer step and measures:
  - whether each one raised an alert;
  - the delay from action to alert, and from alert to freeze;
  - how much a busy process got done before it was frozen;
  - whether a child it started was frozen too;
  - macx and eslogger CPU and memory, idle and busy;
  - a benchmark of eslogger's CPU, memory and events per second with macx's event set, and with `open` added, under the same file load.

  It writes [research/evaluation/runtime-results.md](research/evaluation/runtime-results.md). It needs root and Full Disk Access, so it has to be run on a real Mac by hand.

  **First run (macOS 27.0.1, M3 MacBook Air):**
  - **Detection:** all 7 simulated steps alerted, 47–245 ms after the action.
  - **Freezing:** each freeze followed its alert within 5–9 ms. A busy loop got through about 5,400 steps (roughly 0.2 s of work) before it stopped, and a child started before the alert was frozen too.
  - **Overhead:** macx and eslogger together used about 0.6% CPU idle and 2% during the run, with 41 MB and 7 MB of memory.
  - **The `open` cost:** adding `open` events took eslogger from 5.5% CPU and 8 MB to 94% CPU and 706 MB under the same file load (300 → 10,500 events/s), which is why `macx watch` leaves them out.
  - **False positives:** none from normal background activity during the run.
  - **What this means:** `--suspend` limits damage, it doesn't prevent it. A fast stealer still gets about 0.2 s.

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

## Malware hash feed
A list of SHA-256 hashes of known macOS malware, published on GitHub Pages at `feed/v1.json`. The signed update channel lists the feed's hash, so macx only accepts the exact feed that was signed. The daily update check (and `macx update`) downloads it into `~/Library/Application Support/Macximesed/hashfeed.json`, and from then on it's checked offline:
- `macx check` flags a file whose hash is on the list as *known malware*;
- `macx watch` raises a critical alert (and freezes it with `--suspend`) when a listed program starts.

The feed is built at release time from [`data/hashes/curated.tsv`](data/hashes/curated.tsv) plus, when the `MALWAREBAZAAR_KEY` secret is set, abuse.ch MalwareBazaar's recent macOS samples. Only hashes are stored; no samples.

## Install a release
Each [release](https://github.com/LAOUUUUU/Macximesed/releases) has a universal `macx` (Apple silicon and Intel) with a SHA-256 file. The binary isn't signed yet, so after checking the hash:

```bash
tar -xzf macx-*-macos-universal.tar.gz && xattr -d com.apple.quarantine macx && ./macx --help
```

## Contributing
Pull requests go to `dev`. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: it covers setup, the test-first workflow, and the rules the code keeps (no guessing, nothing deleted without an undo, no privacy popups). Report security problems privately as described in [SECURITY.md](SECURITY.md). Everyone is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).

If `macx persist` flags something harmless or misses something, open a **Detection report** issue.

Questions, ideas or just want to follow along? Join the [Discord](https://discord.gg/gKthUMyZgH).

## License
[MIT](LICENSE)
