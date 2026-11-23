# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). The jobs still to do are in [STATUS.md](STATUS.md).

## [Unreleased]

### Added
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
- **Hang:** a system tool that never finishes no longer hangs macx. Every tool macx runs now has a time limit (30 s by default) and an empty stdin, and a tool that runs out of time counts as unavailable. On CI, `macx persist` waited forever on a tool, most likely `sfltool dumpbtm` waiting for an authorization prompt on a headless Mac.
- **CI smoke test:** each command is labelled and capped at 2 minutes, so a hang names itself instead of using up the job's time limit.
- Errors are printed without the usage text underneath.
- Apps in folders whose names contain dots (for example `Cisco Packet Tracer 9.0.1/`) are found.
