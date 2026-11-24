# Research: Boost, throttle view, Medium tier (step 7) and Games (step 8)
**Date:** 2026-11-24
**Status:** Complete, deepened by two research agents (Haiku, high effort; [step 7](EXTERNAL-step7.md), [step 8](EXTERNAL-step8.md)). Waiting for Lao's approval.
**Researcher:** Claude Code

## Question
Lao, 2026-11-24: "k lets do 7 and 8". What can macx really do on macOS 27 (Apple silicon) to give a game or a heavy app more of the Mac, show when it's throttling, and undo every change? And what does a games section look like when Game Mode can't be switched by a program?

## Context
The plan for both steps is in [research/macximesed-v1/RESEARCH.md](../macximesed-v1/RESEARCH.md) (the "Performance" and "Games" sections and the tier list). This brief re-checks what changed by macOS 27 and settles the design. Builds on step 2's undo store and the existing `scan` (top processes, thermal state).

## Findings

### Internal
- `macx scan` already reads the top processes and the thermal state; `UndoStore` handles files. Settings need their own "before" store: Boost changes settings, not files.
- `Apps.swift` already reads each app's architecture from the Mach-O header (arm64, Intel, Universal), which answers "is this game running through Rosetta?".

### External (checked 2026-11-24, partly on Lao's Mac, macOS 27.0.1)
- **Clocks can't be raised** on Apple silicon; the OS picks them (Eclectic Light 2026, from the v1 brief). Boost works by taking work away from the game's competition, not by pushing hardware.
- **Game Mode has no command-line switch.**
  - No `gamepolicyctl` on 27.0.1.
  - `gamepolicyd` and `GamePolicyAgent` (man pages present) take no user arguments.
  - Game Mode turns on by itself when a game that declares support (`LSSupportsGameMode` / `GCSupportsGameMode`) goes full screen (Apple support 105118; Apple forums 782343).
  - So macx can show whether a game declares it and remind you to go full screen; it can't force it.
- **Metal Performance HUD:**
  - `MTL_HUD_ENABLED=1` in the app's environment (Apple docs);
  - or the global `defaults write -g MetalForceHudEnabled -bool YES` (Apple tech talk 110339; forum report that NO turns it back off).
  - Per launch is cleaner: `open --env MTL_HUD_ENABLED=1 -a Game`. Not confirmed on 27 by any source, so it needs testing.
- **Heat:** there's no public unprivileged temperature readout on Apple silicon.
  - What exists:
    - `ProcessInfo.thermalState` (0–3: Nominal, Fair, Serious, Critical), with change notifications. On Lao's Mac it read *Fair* during builds.
    - `pmset -g therm` (records warnings; no degrees).
    - `sudo powermetrics` (thermal pressure and frequencies).
  - macmon's no-root route broke on macOS 27 (its README).
  - So the "heat graph" is a thermal-state and CPU-load timeline, with frequencies when run with sudo.
- **Taking work away:**
  - `taskpolicy -b -p PID` puts a process on background QoS (efficiency cores, throttled I/O), and `-B` undoes it. Only the user's own processes, without root.
  - App Nap for the focus app: `defaults write <bundle-id> NSAppSleepDisabled -bool YES`, undone by restoring the old value (OSXDaily).
  - Reduce Transparency and Reduce Motion: `com.apple.universalaccess` `reduceTransparency` / `reduceMotion`. Readable on 27.0.1, both 0 now. Writes were blocked by privacy protection on recent macOS without Full Disk Access (Jamf/forum reports); macx has Full Disk Access now, but that's untested.
  - Spotlight indexing pause: `mdutil -i off /` (root), undone with `-i on`.
  - Low Power Mode: `pmset -a lowpowermode 0` (root). Off on Lao's Mac now.
  - Sleep: `caffeinate -dis` while boosted.
- **Running Windows games:** Whisky ended (April 2025); CrossOver is the maintained route. GeForce NOW is the cloud route (v1 brief sources).

### Deeper research (2026-11-24): what changed
- **Universal Access writes aren't blocked.**
  - The earlier "blocked by privacy protection" had no source.
  - A test on Lao's Mac (27.0.1) wrote `reduceMotion` (the same value, nothing changed) with no error.
  - Reads have a documented API (`NSWorkspace.accessibilityDisplayShouldReduceMotion` / `...Transparency` plus a change notification).
  - Open apps may only notice after a relaunch, so Boost writes, reads back through NSWorkspace, and says if it didn't apply.
- **`taskpolicy -B` isn't a complete undo.** Threads an app put on low QoS itself stay on E cores (Eclectic Light). Boost only demotes and restores what it changed, and says so.
- **There's no measured foreground gain from background QoS in any source.** So `macx boost` will measure: a short CPU benchmark (or a game's own frame times when the HUD is on) with and without Boost, before the docs promise anything.
- **Spotlight already runs on E cores at low QoS.** Pausing it saves little: opt-in, with that said.
- **App Nap:** `NSAppSleepDisabled` is undocumented. Keep it, but treat it as best-effort.
- **Heat:** thermal state (with a change notification on 26+) plus the undocumented `com.apple.system.thermalpressurelevel` notification (0–4) for finer steps. There's no public temperature API. Power readings broke on 27 even with sudo, so macx shows no watts or frequencies without root.
- **Top list:** don't rank by Activity Monitor's CPU%, which ignores frequency. Rank by CPU time used in the last interval (libproc `proc_pid_rusage`).
- **Crash safety, as App Tamer does it:** save the "before" state before each change, and restore on the next macx run if Boost was left on.
- **Rosetta:** "macOS 27: final release to support Rosetta" (Apple, 1 Sep 2026). Intel-only apps stop after 27; older unmaintained games keep Rosetta, with no end date. The games list marks Rosetta games and suggests native builds or GeForce NOW.
- **Game Mode:** what it does is confirmed (CPU/GPU priority, fewer background tasks, double Bluetooth sampling; WWDC26), and it can't be switched or queried publicly. Games started from Steam inherit it. Report only. The claimed Xcode `gamepolicyctl` is unconfirmed and isn't used.
- **Metal HUD:** `open --env MTL_HUD_ENABLED=1` for games macx starts itself. Games started by Steam or CrossOver get the HUD through a per-app `MetalForceHudEnabled` key (CrossOver: `cxbottle.conf`), undone by deleting the key, not by `-g NO`. Test on 27.
- **Finding games:**
  - App Store category or Game Mode keys.
  - Steam `steamapps/appmanifest_*.acf` (path to test).
  - CrossOver bottles from `BottleDir` (CrossOver can't list installed Windows apps, so the user points at the `.exe`).
  - GeForce NOW (`com.nvidia.gfnpc.mall`).
  - Epic, GOG and Battle.net locations are unknown, so the user adds their folders.
  - CrossOver 27 needs Apple silicon and Sonoma.
- **GPU load:** no public API. The undocumented IOAccelerator `PerformanceStatistics` is readable without root but varies by GPU, so it's experimental only (`--gpu`).

## Sources
| Source | URL | Key takeaway |
|---|---|---|
| Apple: Use Game Mode | https://support.apple.com/105118 | Automatic in full screen; no settings |
| Apple forums: enable Game Mode | https://developer.apple.com/forums/thread/782343 | Developer opt-in key, no user switch |
| Eclectic Light: Game Mode | https://eclecticlight.co/2023/10/17/what-does-game-mode-do/ | What it changes |
| Apple: Metal Performance HUD | https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance | `MTL_HUD_ENABLED=1` |
| Apple tech talk 110339 | https://developer.apple.com/videos/play/tech-talks/110339 | `MetalForceHudEnabled` global default |
| Apple forums: HUD on macOS 26 | https://developer.apple.com/forums/thread/801396 | Some HUD keys misbehaved on 26.0 |
| Thermal throttling app (2025) | https://stanislas.blog/2025/12/macos-thermal-throttling-app/ | Thermal pressure via notify, buckets only |
| macmon README | https://raw.githubusercontent.com/vladkens/macmon/main/readme.md | No-root power/temps broke on macOS 27 |
| Apple forums: thermal sensors | https://discussions.apple.com/thread/255193810 | No SMC sensors on Apple silicon |
| Jamf: Reduce Transparency by script | https://community.jamf.com/t5/jamf-pro/command-line-or-script-to-activate-reduce-transparency/m-p/213544 | Per-user plist; writes can be blocked |
| OSXDaily: App Nap | https://osxdaily.com/2014/05/13/disable | `NSAppSleepDisabled` |

## Recommendation

### Step 7
1. **`macx top`, the throttle view.**
   - A live terminal view, refreshed every second: thermal state with a timeline strip, Low Power Mode, the top CPU processes, and whether each is on background QoS.
   - `sudo macx top` adds CPU/GPU frequencies and thermal pressure from `powermetrics`.
   - Hogs can be limited from there (`l` = background QoS, `u` = undo).
2. **`macx boost on [--app NAME] / off / status`.** Every change records its "before" value in `~/Library/Application Support/Macximesed/boost.json` *before* it's made, so `boost off` (or the next macx run after a crash) puts back exactly what was there. What Boost does:
   - **No root needed:**
     - background QoS for the top CPU users that aren't the focus app (yours only, never Apple's system daemons);
     - App Nap off for the focus app;
     - Reduce Transparency and Reduce Motion on (less WindowServer GPU work);
     - `caffeinate` while it's on.
   - **With sudo:** Spotlight indexing paused, Low Power Mode off.
3. **Medium tier** (`macx tune --tier medium`), a list of reversible settings, each with its stored "before" value:
   - Reduce Transparency and Reduce Motion as permanent settings;
   - Spotlight indexing off for chosen volumes;
   - analytics sharing off;
   - Siri suggestions off.

   Time Machine local snapshots stay out of it: deleting them can't be undone, so that belongs to the Risky tier (step 10).

### Step 8
4. **`macx games`, a list of the games on this Mac:**
   - **What counts as a game:** apps in `/Applications` and `~/Applications` with a games category or a Game Mode key, plus Steam's library folder.
   - **Per game:** native, Intel through Rosetta, or Universal, and whether it supports Game Mode.
   - **Windows games:** inside CrossOver bottles, if CrossOver is installed.
   - **Best way to run it:** native, "look for an Apple-silicon version" (Rosetta), CrossOver, or GeForce NOW if installed.
5. **`macx games play NAME [--hud] [--no-boost]`:**
   - **Before launch:** turns Boost on with the game as the focus app, and launches it (`--hud` adds `MTL_HUD_ENABLED=1` for that launch only).
   - **While it runs:** records thermal state and CPU load every 2 s.
   - **When the game quits:** turns Boost off, even if macx is stopped (a signal handler plus the crash-safe state file), and prints a heat graph, a sparkline of thermal state and load over the session, saved to `~/Library/Logs/Macximesed/games/`.
   - **Reminder:** "go full screen for Game Mode", when the game supports it.

## Test plan sketch
- [ ] Boost on, then off, restores every changed setting to its stored "before" value (fake settings and process controller).
- [ ] A crash between "on" and "off": the state file alone is enough to restore everything.
- [ ] Boost never limits the focus app, Apple's system processes, or another user's processes.
- [ ] A setting already at the boosted value is left alone and not "restored" to something else.
- [ ] The games scanner finds a game by category, by Game Mode key, and in a Steam library; it reads the architecture; and it picks the best way to run.
- [ ] The heat graph renders a thermal and load timeline as a fixed-width sparkline.
- [ ] The Medium tier: each tweak's apply and undo round-trips through the fake settings store.

## Risks & unknowns
- **Universal Access writes** may still be blocked on 27 even with Full Disk Access. Test early; if they're blocked, Boost skips them and says so.
- **The Metal HUD** environment variable on macOS 27 is untested, as is the HUD in games launched by Steam or CrossOver (they launch the game themselves).
- **Background QoS** can make a limited app feel slow. That's expected and why Boost undoes it when it ends.
- **Heat** is buckets, not degrees, on Apple silicon without root (and even with root, `powermetrics` gives pressure and frequencies, not temperatures).
- **Game Mode can't be forced,** only encouraged (full screen).

## Next steps
- [ ] Lao approves or changes this.
- [ ] TDD step 7: the settings store with "before" values, Boost, `macx top`, the Medium tier.
- [ ] TDD step 8: the games scanner, best way to run, play with the guaranteed Boost off, the heat graph.
