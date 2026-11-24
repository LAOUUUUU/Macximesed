# External research: Step 7, Boost and throttle view (macOS 27)
**Date:** 2026-11-24. **By:** research-scout agent (Haiku, high effort), saved by the main session.
macOS 27.0 shipped 2026-09-14 (26A428); 27.0.1 on 2026-09-28.

## 1. Universal Access writes
- **Reads are documented (High):** `NSWorkspace.accessibilityDisplayShouldReduceMotion` / `...ReduceTransparency`, observed through `accessibilityDisplayOptionsDidChangeNotification`. https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion
- **Writes are community-only (Low):** `defaults write com.apple.universalaccess reduceTransparency -bool true`. Open apps other than Finder may not see it until they relaunch (Jamf, 2017). https://community.jamf.com/t5/jamf-pro/command-line-or-script-to-activate-reduce-transparency/m-p/213544
- **No source says writes are blocked on 27.** The brief's earlier "blocked by privacy protection" was unsupported.
- **Release notes:** "Apps can no longer access the local TCC database directly." Never touch TCC.db. https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- **PPPC:** a profile can't grant Accessibility on 27.0 (Apple DTS, Jul 2026). https://developer.apple.com/forums/thread/839536
- **Reduce Transparency** itself was broken on 26.1–26.2 and fixed in 26.3 (OSXDaily, 2026-02-13). https://osxdaily.com/2026/02/13/reduce-transparency-works-again-in-macos-tahoe-26-3/
- **System Events:** only UI scripting of the Display pane, which is fragile.

## 2. taskpolicy and QoS
- **`-b`** is `setpriority(PRIO_DARWIN_BG)`: lowest scheduling, and disk and network I/O throttled (High). https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setpriority.2.html
- **E cores:** background QoS runs only on E cores and is never promoted (Eclectic Light 2025–2026, High). https://eclecticlight.co/2025/05/09/what-is-quality-of-service-and-how-does-it-matter/
- **`-B` isn't a full undo:** threads the app itself set to low QoS stay on E cores (Eclectic Light, High). https://eclecticlight.co/2024/12/17/tune-for-performance-core-types/
- **Permissions:** same-user processes only without root (High).
- **Benefit:** no foreground benchmark found (Low). One 2026 paper found background work on E cores still slowed an LLM decode. https://neurips.cc/virtual/2026/171323

## 3. What frees performance
- **Spotlight** already runs at low QoS on E cores (apart from mediaanalysisd), so pausing it saves little P-core time (Eclectic, 2026-02-10). https://eclecticlight.co/2026/02/10/in-the-background-spotlight-indexing/
- **App Nap:** the documented route is `ProcessInfo.beginActivity(.userInitiated/.latencyCritical)` in the app itself. `NSAppSleepDisabled` is undocumented. https://developer.apple.com/documentation/foundation/processinfo/activityoptions
- **Low Power Mode** caps P cores (an M4 Pro at 3,624 MHz, about 50% of the performance; Eclectic, Jan 2025).
- **High Power Mode** exists on some models (Apple, 2026-11-05). https://support.apple.com/101613
- **WindowServer:** an Electron shadow bug forced repaints on Tahoe; fixed in rebuilt apps (The Register, 2025-10-02). https://www.theregister.com/2025/10/02/macos_26_electron_slowdown/
- **Trap:** Activity Monitor's CPU% ignores frequency (Eclectic, 2026-06-29). https://eclecticlight.co/2026/06/29/what-does-activity-monitor-measure/

## 4. Reading load without root (27)
- **`ProcessInfo.thermalState`** has four cases; the change notification is available on 26+ (Apple, High).
- **Thermal pressure:** `com.apple.system.thermalpressurelevel` through notify, levels 0–4, undocumented (Medium). https://stanislas.blog/2025/12/macos-thermal-throttling-app/
- **mactop** reads per-core load (`host_processor_info`), IOReport power, GPU frequency and SMC temperatures without sudo (README, undated). https://raw.githubusercontent.com/anemll/mactop/main/README.md
- **macmon:** on 27, the IOReport Energy Model counters stop updating without the private entitlement `com.apple.private.pmgr.nrg.reporting`, and sudo doesn't help. Power only; frequency and temperature aren't said to be affected. https://raw.githubusercontent.com/vladkens/macmon/main/readme.md
- **Frequency:** no public API; it comes from `sudo powermetrics`. Check `powermetrics -h` on 27 first.

## 5. Existing tools
- **App Tamer** pauses or caps apps and demotes threads to E cores. It restores everything on a crash or force quit. https://stclairsoft.com/AppTamer/release_notes.html
- **Turbo Boost Switcher:** Intel only.
- **Stats:** SMC sensors, with keys that change for each chip.
- **Mainspring:** an undo for each change (MacRumors, 2026-07-28).

## 6. Risks
- **Partial QoS undo,** as in section 2.
- **`mdutil -i off`** only covers volumes mounted at the time.
- **`pmset`:** changes may not show in System Settings until a reboot (unverified).
- **Guard:** write the "before" state first, and restore on the next launch after a crash (App Tamer's pattern).

## What this changes in the plan
1. **Universal Access:** read with NSWorkspace; write best-effort, read back, and skip with a note if it didn't apply. Never touch TCC.db.
2. **taskpolicy:** say plainly that threads the app put on low QoS itself stay on E cores after the undo. Same user only.
3. **Measure first:** no source shows a foreground gain. Measure with and without Boost before promising anything.
4. **Spotlight:** opt-in, and say the saving is small.
5. **Heat:** thermal state plus the pressure notification. No watts or frequency without root on 27.
6. **Top list:** don't rank by Activity Monitor's CPU%.
7. **Restore:** save the "before" state before each change, and recover on the next launch.
8. **Corrections to RESEARCH.md:** writes being blocked is unsupported; temperature has "no public API" rather than none at all; macmon's break is power only.
