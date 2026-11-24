# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). The jobs still to do are in [STATUS.md](STATUS.md).

## [Unreleased]

### Added
- **Updates in the Mac app:** Settings > Updates now says whether a new version is out (or that yours has a security problem) and has an *Install* button, then *Restart the app*. It runs the app's own `macx update`, so it has the same signature checks, rollback and Full Disk Access guards as the CLI. The hash feed line moved behind the ⓘ.
- **Empty the undo folder:** `macx undo empty` and Clean > *Empty undo folder (size)…* in the app delete every batch for good, after a confirmation that says how much space comes back. Cleaned files used to stay there until `macx undo purge` (older than 7 days only), and the app had no way to clear them.

### Fixed
- The Updates row showed the hash feed line ("1 known samples") instead of whether an update was available.
- **Sizes agree between the CLI and the app.** The CLI divided by 1024 and the app by 1000, so the same 5 GiB undo folder was 5.0 GB in `macx undo` and 5.37 GB in the app. Both now use one formatter (`formatBytes`) in decimal units, 1 KB = 1000 bytes, as Finder and About This Mac count: it's 5.4 GB in both.

## [0.3.0] - 2026-11-24

### Added
- **Downloads watch:** the background watch checks every finished download in `~/Downloads` (browser temp names are understood, subfolders skipped) with the full file check, offline, on its own queue. *DON'T OPEN THIS* is quarantined automatically into an incident case and the undo store, owned by the user, with a notification. `macx undo restore` adds a restored download to an allow list, so it isn't quarantined again. `--no-downloads` turns it off.
- **First-run setup** in the Mac app (research and design in `research/app-onboarding/RESEARCH.md`, approved 2026-11-24):
  - **Screens:** welcome; then Full Disk Access, the background watch, notifications and extras; then a Ready summary.
  - **Live checks:** every step checks every second, and Continue appears once the check passes. If eslogger is refused, the watch step sends you back to Full Disk Access.
  - **Full Disk Access:** the app itself can be dragged into the list.
  - **Password note:** before the prompt, the setup says that the "couldn't verify this script" line comes from macOS.
  - **Motion:**
    - the menu bar mark draws itself;
    - steps slide in;
    - the live checks breathe while waiting and fill when they pass;
    - a progress line runs along the bottom.

    With Reduce Motion it's plain fades.
  - **Every step can be skipped**, and Settings has *Run setup again*.
- **The app shows alert notifications itself while it's open** (`AppNotifications`, the same 10-second throttle, high and critical only), with its own permission. The background watch skips its `osascript` notification while the app runs. It checks the app's process (its path, `KERN_PROCARGS2` arguments and user id), not a file, so a stealer can't silence the fallback. `macx daemon status` shows which one is showing alerts.
- **Updates can't cost Full Disk Access:** they never install as root, are held back if the signing identity is missing, and roll back if the app's designated requirement changed after re-signing (checked with the real codesign on a copy of the installed app). The background watch restarts itself on the new binary after an update (exit 75; launchd relaunches it), so no sudo restart is needed.
- **`macx top`** (step 7): live throttle view with thermal state and pressure, a heat and load strip, and the busiest processes by real CPU time (libproc `proc_pid_rusage`).
- **`macx boost`** (step 7): on, off, status, measure. Background priority for your busiest other apps (`setpriority PRIO_DARWIN_BG`, the call `taskpolicy -b` makes), App Nap off for the focus app, Reduce Transparency and Reduce Motion, caffeinate. A crash-safe ledger saves each change before it's made. Apple's and other users' processes are never touched. `measure` compares a CPU benchmark with and without Boost; on the first real run it found no difference (−1.8%, within noise), because nothing was competing hard.
- **`macx tune`** (step 7, the Medium tier): reversible settings and switching off third-party launch agents, each with its own ledger.
- **`macx games`** (step 8): game finder (category, Game Mode keys, known games and launchers, Steam manifests, CrossOver bottles, user-added), how best to run each (native, Rosetta with the macOS 27 warning, CrossOver, cloud), and `play` with Boost, the Metal HUD, a heat timeline and a session summary. If macx stops mid-game, the next macx run turns Boost off once the game has quit.
- **The chamber uses the Intel work:** the agent traces `StraceLog.traceSyscalls` (so Intel's `open`/`creat` reads are seen), and setup checks every kernel with `ChamberKernel.prepare` for both chips. An Intel kernel is no longer installed unchecked.
- **`macx chamber`** (setup, run, status, remove): the detonation chamber, end to end. Pinned Alpine downloads with SHA-256 checks; a per-run boot image with Mac stand-ins (canary password), bait files and the sample; Apple's Virtualization framework with no disk or network; strace judged with the live-watch and chamber rules (VM checks across pipes, repeated reads collapsed); quarantine into an incident case. `scripts/install.sh` and the updater now sign with the `com.apple.security.virtualization` entitlement (`scripts/macx.entitlements`). `macx check` points scripts it can't settle at the chamber.
- **Light chamber on Intel Macs (data side):** a pinned x86_64 manifest (`data/chamber/manifest-x86_64.json`, Alpine 3.24.4, 15 files, 52 MB, verified the same way as aarch64), and `ChamberKernel.prepare`, which turns Alpine's kernel into what `VZLinuxBootLoader` boots: it unwraps the EFI-zboot gzip on Apple silicon and checks the arm64 `Image` magic, and checks the bzImage header on Intel. Unknown formats, an ELF `vmlinux` and corrupt gzip are refused. Not booted on an Intel Mac yet.
- **Strace reader on Intel:** `StraceLog` also reads `open` and `creat`, which Intel programs use instead of `openat`, so keychain and browser-data reads aren't missed there. `StraceLog.traceSyscalls` is the one list the guest agent should trace; x86-only names carry strace's `?` so the same list works on arm64.
- **Mac app and menu bar item** (roadmap step 11, research and design in `research/app-ui/RESEARCH.md`).
  - **How it's built:** windows and the status item are AppKit; the screens are our own SwiftUI parts, with no stock lists, forms, toolbars or glass popovers.
    - Type: New York for sentences of state, SF Mono for anything technical.
    - Colour: paper and ink, red only for critical, high and off.
    - Helper text sits behind ⓘ buttons.
  - **Screens:** Protection, Startup items, Check a file, Clean, Apps and Settings.
  - **Alerts are grouped by rule and program**, because one day of development logged 721 alerts, 568 of them one rule. "Expected" hides a non-critical group in the app only.
  - **One executable:** `LSEnvironment MACX_APP=1` in the app's Info.plist starts the app when it's opened from Finder, the Dock, `open` or a login item. Shell runs and the daemon stay the CLI, and `macx app` opens it from a terminal. The bundle id, signature and Full Disk Access are unchanged.
  - **The menu bar reads the real daemon:** `launchctl print`, the daemon's status file, the pause file and the alert log, every 2 seconds. Nothing needs root.
  - **Cost of linking the app into one binary**, measured as a release build on an M3:
    - binary: 4.9 to 6.5 MB per architecture;
    - an idle CLI process: 11.7 to 14.3 MB of memory.
  - **Auto-update adds the app switch (`LSEnvironment`) to bundles installed before the app existed**, so an updated Macximesed.app opens as the app.
  - **Root actions** (pause, resume, install, restart, uninstall) run the app's own `macx daemon …` through the administrator prompt.
- **`sudo macx daemon pause [--for 1h]` and `resume`:**
  - While paused, the background watch still logs alerts but sends no notifications and freezes nothing.
  - The pause ends by itself, after 24 hours at most.
  - The pause file must be root-owned and not writable by anyone else, or it's ignored. A stealer running as you can't pause the watch.
- **Light chamber boot test:** a 52 MB Alpine Linux VM booted with no disk or network, ran a harmless pretend stealer in 1.6 s, and the real strace trace (`Tests/Fixtures/chamber-strace-pretend-stealer.txt`) is judged *DON'T OPEN THIS*. `StraceLog` now splits the console's `\r\n` lines.
- **Light chamber pieces:** `StraceLog` turns the guest's `strace -f` output into chamber events. It covers exec with parent tracking, open and create, rename, connect, exit, unfinished and resumed calls, and C-string escapes, and skips anything unreadable. There's a new `network-attempt` chamber rule. `CPIOArchive` writes the newc initramfs the chamber boots from; macOS's own `cpio` lists it, and it refuses `..` paths.
- **Detonation chamber, host side** (`Sources/MacxCore/Chamber.swift`, not wired to a command yet). It reads a guest VM's eslogger log as untrusted data and judges only the sample's own process tree. It adds chamber rules (`reads-keychain`, `reads-browser-data`, `reads-wallet`, `vm-check-then-quit`), gives a verdict (*DON'T OPEN THIS* / *Be careful* / *Nothing seen*, never "safe"), pins the sample by SHA-256, and quarantines it into an incident case and the undo store. The eslogger parser now reads `open`, `exit` and event times.
- **VM-check rule** (`vm-check`, high) in `guard`, `check`, `persist` and the live watch: a hardware query (`system_profiler`, `ioreg`, `sysctl hw.model`) next to a virtual-machine name (VMware, QEMU, VirtualBox, Parallels, "Apple Virtual Machine", VirtualMac). That's how AMOS dodges analysis. Scripts are checked across lines. None of the 11 real installers in the static evaluation trip it.

### Changed
- README, `macx privacy` and the watch's refusal message say to give full access, not specific folders, on macOS 27.3 and later (eslogger needs full Full Disk Access).

## [0.2.0] - 2026-11-24

The first release: the antivirus side is complete (the checklist in STATUS.md), plus Safe cleanup, app removal and the signed auto-update channel.

### Added
- **Background watch:** `sudo macx daemon install` runs `macx watch` as a launchd daemon from Macximesed.app, with `status`, `restart` and `uninstall`. High and critical alerts show as notifications, grouped to one every 10 seconds. The daemon records its state in `/Library/Logs/Macximesed/status.json` and stops cleanly when eslogger is refused. `macx alerts [--follow]` reads saved alerts. `macx persist` recognises Macximesed's own daemon, but only when it runs the installed macx.
- **Configuration profiles in `macx persist`** (`profiles show -output stdout-xml`; computer-wide ones under `sudo`). Each profile's payloads are sorted by what they can do. Trusted certificates, proxies, forced browser settings or extensions, privacy grants and Gatekeeper changes are high on a Mac without MDM. DNS, VPN, content filters and managed login items are medium. Every hand-installed profile is low, and on an MDM-managed Mac everything is info. Profiles are in the baseline, so `--diff` shows a new one.
- **Network watching.** `macx watch` follows every process behind a high or critical alert, and what it starts, for 5 minutes, and raises a high `network` alert for each new remote address it connects to (`--net-interval`, default 20 ms, 0 turns it off). `macx net PID` does the same for one process by hand. Sockets are read with libproc, so no `lsof` or `nettop`. Measured in `research/evaluation/network-results.md`: connections open 50 ms or more are always seen at 20 ms, while connections that close within a few milliseconds are often missed. Polling costs about 0.3% CPU.
- **Signed malware hash feed** (`feed/v1.json` on GitHub Pages): listed with its SHA-256 in the signed update channel, downloaded by the daily update check, and checked offline by `macx check` and `macx watch` (new critical `known-malware` alert). Built by `scripts/release/make-feed.py` from `data/hashes/curated.tsv` and, with a `MALWAREBAZAAR_KEY` secret, MalwareBazaar's macOS samples.
- Research brief and 12-step plan (`research/macximesed-v1/RESEARCH.md`).
- `STATUS.md` (job list) and `CHANGELOG.md` (history).
- Swift package: `MacxCore` library, `macx` command-line tool, tests.
- `macx scan`: read-only report of protections, top processes, disk use and thermal state.
- GitHub Actions CI:
  - format lint;
  - a test matrix on macOS 15, macOS 26 Apple silicon and macOS 26 Intel, building with warnings as errors and smoke-running every read-only command;
  - Address and Thread Sanitizer runs;
  - a line-coverage summary;
  - a universal (arm64 + x86_64) binary artifact.
- CodeQL security analysis (on push and weekly), Dependabot for actions and Swift packages, and a release workflow that publishes a universal binary with notes from this file when a `v*.*.*` tag is pushed.
- `.swift-format` config. The code is formatted to it.
- Undo store: cleanups move files into `~/Library/Application Support/Macximesed/Undo/<batch>/` with a manifest. `macx undo list`, `macx undo restore <id>` (never overwrites anything new), and `macx undo purge --days 7` (the only real delete, asks first).
- `macx clean` with the **Safe** tier: third-party caches (one item per folder), user logs, Xcode DerivedData and DeviceSupport, Simulator caches and the npm cache, with `--dry-run`, `--only`, `--include-in-use` and `-y`. Caches of running apps are skipped. Apple caches, `~/.cache` and empty items are never included.
- `macx apps`: lists apps with size, architecture (Apple silicon, Intel or Universal, read from the Mach-O header) and last use (Spotlight, or `~` estimated from the app's own files). Filters: `--unused [--days]`, `--intel`, plus `--sort`.
- `macx apps remove`: uninstalls an app and its exact-match leftovers into the undo folder. Refuses running apps, apps on the sealed system volume, and built-in Apple apps, but allows Apple's App Store apps.
- `macx apps leftovers`: finds files of apps that are gone, by vendor of reverse-DNS names, and can move them to the undo folder.
- `macx persist`: finds everything set to start by itself and flags AMOS-style tricks.
  - **Sources:** launch daemons and agents (system and user), login items and background tasks (from `sfltool dumpbtm`), cron, shell startup files, and hidden folders in Application Support.
  - **Rules:**
    - fake `com.apple.*` labels and folders;
    - shell loops;
    - hidden-folder and temp-folder programs;
    - missing, unsigned and ad-hoc programs;
    - download-to-shell, base64-to-shell, quarantine stripping, and password prompts or checks.
  - **Signatures** are read through the Security framework, and root-only files are reported as unreadable, not unsigned.
  - **Baseline:** `--baseline` saves the current state, and `--diff` shows what changed since.
- **No privacy popups.**
  - Without Full Disk Access, macx stays out of every folder macOS guards: Documents, Desktop, Downloads, Pictures, Movies, Music, `~/Library/Containers`, Group Containers, iCloud Drive and `/Volumes`.
  - It reports what it skipped instead. That covers app discovery, leftovers, cleanup and signature checks.
  - Full Disk Access is detected without a prompt, by trying to open the TCC database.
- `macx privacy [--open]` shows Full Disk Access status, who owns macx's permissions, and what's skipped. `--open` opens the Settings pane.
- `scripts/install.sh` installs one stable `macx` (`~/.local/bin` by default).
  - The installed copy relaunches itself as its own responsible process (`responsibility_spawnattrs_setdisclaim`), so Full Disk Access is granted to macx itself, not to the terminal.
  - Development builds in `.build/` keep the terminal's access.
- Community files:
  - `CONTRIBUTING.md`: setup, branches, test-first workflow and the rules the code keeps;
  - `SECURITY.md`: private reporting, scope, and what to do if your Mac is infected;
  - `CODE_OF_CONDUCT.md`;
  - issue forms for bugs, detection reports and feature requests, with security reports sent to private reporting;
  - a pull request template;
  - `.editorconfig`.
- `macx check`: checks downloads before you open them.
  - **What it reports:** signature (Security framework), Gatekeeper's decision (`spctl`), the quarantine flag (who downloaded it and when), SHA-256, and what the file sets up to run (embedded launch daemons and agents, login items, system extensions, privileged helpers, package install scripts).
  - **Content scan:** scripts, package scripts, compiled AppleScript and the files inside disk images are scanned for stealer patterns, and base64 payloads are decoded and shown.
  - **Disk images** are mounted read-only and hidden with `diskutil image attach`, falling back to `hdiutil` on older macOS, then ejected.
  - **Result:** one of three verdicts, with exit code 2 for dangerous. Optional `--online` MalwareBazaar lookup (hash only).
- `macx guard`: the paste-to-shell guard.
  - **History scan:** zsh extended or plain history (with zsh's metafied bytes decoded), Terminal's `~/.zsh_sessions`, bash with optional timestamps, fish, and `$HISTFILE`. Base64 payloads are decoded and checked too.
  - **`clipboard`** checks what's on the clipboard, and **`check -- CMD`** checks one command (exit code 2 for dangerous).
  - **Opt-in zsh hook** (`guard install` / `uninstall` / `status`): it stops a dangerous command once on Enter, and Enter again runs it.
- `macx watch`: live watch through `eslogger` (`exec`, `create`, `rename`, `deleteextattr`, `btm_launch_item_add`).
  - **Rules:**
    - download-to-shell and base64 payloads (decoded);
    - password prompts and `dscl -authonly` checks (the password is masked);
    - quarantine removal;
    - new launch items, critical when they're fake `com.apple.*` ones;
    - hidden `.com.apple.*` folders;
    - new background items running unsigned programs;
    - unsigned programs starting from hidden or temp folders.
  - **Options:** `--suspend` freezes the process behind a critical alert, and alerts are logged to `~/Library/Logs/Macximesed/watch.jsonl` (owned by the user under sudo). `--replay FILE` checks a saved log.
  - **Parser:** follows Apple's `es_message_t` field names and treats every field as optional.
- `macx guard inspect`: downloads what a pasted command would run, the way curl would and without running it, then reads it.
  - **Behaviours it reports:** password prompts, `dscl` checks, keychain, browser or wallet data, uploads, launch items, closing Terminal, hidden code, and more downloads (followed one level).
  - **Facts it reports:** bare IP, plain http, a redirect, a site new to your shell history, or a program instead of a script.
  - **Running it:** it runs the exact copy it inspected, saved owner-only. Dangerous results need you to type `RUN`.
  - **Hook:** the zsh hook now routes download-and-run commands to `inspect`, and `guard check` exits with 3 for them.
- Disguised commands are now caught: split quoting, backslashes, `$'\x..'`, variables set earlier in the paste, `$(printf …)`, `echo … | rev`, and `echo "…" | sh`. Download-and-run is also found in its two-step form (`curl -o f URL && sh f`, `curl -O URL; ./f`).
- **Updates through a signed channel on GitHub Pages** (`macx update [--check] [--notices on|off]`).
  - **Daily check:** macx checks once a day and notifies. Below the signed security floor (`minimumSafe`) it updates itself before running the command.
  - **Signing:** Ed25519 with the public key built into macx. Files carry a sequence number (no rollback) and a 90-day expiry (no replays).
  - **Downloads:** each one must match the signed SHA-256, be Mach-O, be newer, and report the signed version. The swap is atomic, and `macx.previous` is kept.
  - **Publishing:** `channel.yml` signs in the protected `release` environment (maintainer approval) and deploys to Pages. Releases call it automatically, and it can be run by hand to raise or clear the security floor.
- **Incident response** (`macx incident list|show|contain`).
  - **Cases are recorded** by `watch` for every critical alert, after the freeze and while the process still exists, and by `persist --case`.
  - **Each case keeps:**
    - read-only, non-executable copies of the files involved, plus every non-Apple program in the process chain (files over 50 MB are hashed, not copied);
    - SHA-256, mode, owner and modification time for each file;
    - the process ancestry and descendants;
    - the alert timeline;
    - a `summary.md` with next steps.
  - **`contain`** moves launch items, hidden Application Support folders and temp-folder programs into the undo store, never anything under `/System`, `/usr`, `/bin` or `/sbin`. It prints `launchctl bootout` commands and the credential-rotation checklist.
- **Wider persistence coverage in `macx persist`.**
  - **Flagged:** authorization plugins (high), login and logout hooks (high), non-Apple PAM modules (high), `DYLD_*` library injection in launch plists (high), periodic and `.local` scripts (medium, also scanned for patterns), sudoers.d files (medium) and `at` jobs (low).
  - **Listed for the baseline:** app extensions (`pluginkit`, non-Apple only), system extensions, kernel extensions, and Chrome-family and Firefox-family browser extensions.
- **Benign persistence suite:** 10 launch items modelled on common legitimate software, each with its real kind of signature. No high or critical findings allowed. The one known medium is Homebrew's ad-hoc signed services.
- **eslogger benchmark** in `scripts/eval/runtime.sh`: CPU, memory and events per second with macx's events, and with `open` added.
- **Decision log** in the research brief: the final Extreme decision, and network polling marked as not built yet.
- **First runtime evaluation results** (`research/evaluation/runtime-results.md`). All 7 simulated steps alerted in 47–245 ms, each freeze followed within 5–9 ms, children were frozen, and overhead was about 2% CPU. It also measured the cost of `open` events.
- **App bundle:** `scripts/install.sh` installs `~/Applications/Macximesed.app` (background-only, ad-hoc signed, sealed) with `~/.local/bin/macx` linked into it, because macOS 27 ignores Full Disk Access for bare binaries. `macx privacy` names the app to add.
- **Updates inside the app bundle:** the updater re-seals the bundle, sets its version, and keeps the previous binary in Application Support so the seal stays valid.
- **Stable signing:** `scripts/install.sh` and the updater sign Macximesed.app with an "Apple Development" identity, or else a local self-signed "Macximesed Local Signing" identity (no Apple ID needed). They find it in the keychain (a free certificate from Xcode), or `MACX_SIGN_IDENTITY`. That gives macOS a stable identity, so Full Disk Access survives rebuilds and updates. Without one they fall back to ad-hoc, which macOS 27 doesn't honour for Full Disk Access.

### Changed
- **No more guessing from names.**
  - Cache and leftover owners now come from Spotlight's index of every bundle ID on disk (an exact ID, or the ID plus a dot), and tool caches from the tools themselves (`brew`, `npm`, `pip3`, `yarn`, `pnpm`).
  - Unattributed caches are labelled "unknown owner" and need `--include-unknown` or `--only`.
  - "In use" now means a process has a file open inside the item (through libproc), or its app is running (by exact bundle ID).
  - Removed: the hand-made list of Apple cache names, matching on words in app names, and the list of top-level domains.
- Apps are found anywhere through Spotlight, falling back to `/Applications`, `~/Applications` and `Applications` on each mounted volume. `macx apps` shows each app's folder.
- `macx apps remove` only moves exact bundle-ID leftovers. Folders matched by name are listed, and moved only with `--include-name-matches`.
- `macx apps leftovers` skips app-group IDs (`group.*`, `systemgroup.*`) and empty items.
- Xcode DerivedData uses the custom location set in Xcode's settings, if there is one.
- System tools run with `LANG=C` and `LC_ALL=C`, so output is the same on any language setting.
- Architecture labels depend on the Mac's CPU, so Intel Macs see "Intel" and "Apple silicon only (can't run here)".

- **Unknowns.** Inspection reports code it can't resolve as *unknown*, which keeps the verdict above "ok": `eval` or `sh -c` of a variable, downloads from links computed at run time, programs downloaded and run, and scripts written then run. In pastes, a variable set from a download is followed back to that download.
- **Combination scoring.** A single browser, keychain or wallet touch is *high*. Credentials plus an upload, or a password prompt plus `dscl` or credentials, is a critical `stealer-pattern`.
- **Verified running.** `guard inspect` checks the saved copy's SHA-256 again before running it. Pipe-form scripts are fed to the interpreter on stdin, and everything else runs from a fresh private copy that's deleted afterwards.
- **Whole-tree suspend.** `watch --suspend` freezes the flagged process and all its descendants top-down (re-reading the tree for late children), and shows who started it.
- The README has a table of what the live watch observes and what it can't prevent.
- CodeQL runs on `main`, pull requests and weekly, not on every `dev` push, because it was holding the scarce macOS runners.

- **Partly unknown verdict.** When the only findings are things that couldn't be checked, the verdict is *partly unknown* (nothing dangerous in what could be read, parts unchecked), not *Be careful*. `guard inspect` now prints those parts under *Can't tell*.
- **Apple-named items in scripts are high:** `fake-apple-launch-item` and `fake-apple-folder` now apply to scripts too.
- **Evaluation harnesses:**
  - `scripts/eval/static.sh` covers 17 harmless attack simulations and 11 real installers, and records the results in `research/evaluation/static-results.md`;
  - `scripts/eval/runtime.sh` (needs sudo) covers detection, delays, work done before the freeze, child freezing and overhead.
- `macx watch --log FILE`. The watch log now has millisecond timestamps and records each freeze.

### Fixed
- **Full Disk Access showed "Off" on macOS 27** (in the app, `macx privacy` and first-run setup) while it was on. macOS 27 blocks direct TCC.db access, and the user database isn't at the old path. The check now lists a folder only Full Disk Access opens (`~/Library/Safari`, `Mail`, `Messages`, `Cookies`, `Suggestions`), which fails quietly, with no prompt, when access is off.
- **Settings in the app:** the "This app" settings were squeezed onto one line; each now has its own row.
- **The app's Install button failed after the password.** AppleScript's admin shell runs as root with no SUDO_USER, so `daemon install` couldn't tell whose Mac it was. The app now passes `MACX_USER`, and the password dialog says what each action is for.
- **False alarms in the live watch** (from Lao's real alert log, 2026-11-24):
  - **Arguments aren't code:** command patterns only count when a shell or interpreter runs them, or when the tool is the attack itself (`dscl -authonly`, `xattr -d com.apple.quarantine`). `macx guard inspect -- "curl…|zsh"`, commit messages and `sudo` wrappers no longer alert (46 + 2 false criticals from the evaluation).
  - **Heredocs written to a file aren't run:** `cat > f <<EOF … EOF` bodies are skipped, while heredocs fed to a shell still count.
  - **Updaters:** a signed third-party app clearing the quarantine flag (its updater, such as Discord's ShipIt, 564 times) is low, not high. xattr and unsigned programs stay high.
  - **Developer builds:** unsigned programs from developer build folders (`.build`, `DerivedData`) are low.
  - **Don't delete macOS:** alerts naming a macOS program (/bin/zsh, dscl, sudo) now say "macOS's own program: don't delete it", in the terminal, the log (`systemProgram`) and the app, and the app no longer offers "Show in Finder" for them.
- Preference writes to the global domain now use `kCFPreferencesAnyApplication`; "NSGlobalDomain" as a CFPreferences app ID wrote to a stray domain.
- **Runtime evaluation harness measured the wrong processes.** With the re-launching installed macx, it sampled the idle parent and the background daemon's eslogger. It now follows the tree from the watcher it started. The eslogger benchmark goes through a hidden `macx eslogger EVENTS…` (root only, event names only), so Full Disk Access is Macximesed's and not the terminal's. The busy-loop counter is appended instead of rewritten, because a freeze could land while the file was empty.
- **`macx watch` ignored SIGTERM and SIGHUP.** Its handler ran on the main queue, which never got a turn because the main thread is blocked reading eslogger. It now has its own queue.
- **Stopping the installed `macx` stops all of it.** The installed binary re-launches itself to own its permissions. The parent used to ignore SIGTERM and SIGHUP without passing them on, so `kill` on it left the child running. That's how three root `macx watch --suspend` processes from evaluation runs kept going for hours. It now forwards SIGINT, SIGTERM and SIGHUP, and the runtime harness also stops its watchers by their log folder.
- **`macx daemon restart` failed with launchd error 5**, because `bootout` returns before the job is gone. It now waits for the unload and retries the load. `macx daemon status` marks a stale "watching" message when launchd says the job isn't loaded.
- **Full Disk Access for macx itself works** (macOS 27.0.1). tccd's log showed the cause: `Failed to match existing code requirement`. The Full Disk Access entry still held the ad-hoc signature from when it was first added, and switching it off and on never updates that. Removing the entry and adding the signed app again fixed it. `macx privacy` and the watch's refusal message now explain this.
- **`sfltool` stall explained and fixed.** Without root, `sfltool dumpbtm` asks for the `system.privilege.admin` right, which puts up an admin-password dialog and waits for it. That's a few seconds when Touch ID answers, forever on CI where nobody can, and the dialogs queue when several run at once (5 at once: the last waited 13 s). As root it answers at once with no dialog. `macx persist` now reads login items and background tasks only under `sudo` and says so otherwise, which also makes it faster without sudo (2.7 s down to 0.95 s).
- **zsh paste guard:** a flagged command now needs a typed `RUN`. Pressing Enter a second time no longer runs it.
- **`sfltool` hang:** `sfltool dumpbtm` can stop answering. It now gets 8 seconds, and `persist` says that login items and background tasks weren't checked, instead of waiting 30 seconds or longer.
- **`macx apps` speed:** it uses the bundle size Spotlight already recorded, and only walks the files when Spotlight has none. It had run past CI's 2-minute cap on a runner with several 10 GB Xcode installs. Locally it went from 3 s to 0.8 s.
- **CI smoke step:** it now turns off `bash -e`, so a command expected to exit non-zero (like `guard check` on a bad command, exit 3) is counted as a pass, not treated as fatal.
- **Hang:** a system tool that never finishes no longer hangs macx. Every tool macx runs now has a time limit (30 s by default) and an empty stdin, and a tool that runs out of time counts as unavailable. On CI, `macx persist` waited forever on a tool, most likely `sfltool dumpbtm` waiting for an authorization prompt on a headless Mac.
- **CI smoke test:** each command is labelled and capped at 2 minutes, so a hang names itself instead of using up the job's time limit.
- Errors are printed without the usage text underneath.
- Apps in folders whose names contain dots (for example `Cisco Packet Tracer 9.0.1/`) are found.
