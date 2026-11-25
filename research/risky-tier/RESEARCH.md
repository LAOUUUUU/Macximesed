# Research: the Risky tier (step 10)

Asked by Lao on 2026-11-25: "start doing more dangerous optimisations for more speed". Step 10 of the original plan ([research/macximesed-v1/RESEARCH.md](../macximesed-v1/RESEARCH.md)), with its rules:
- **Three confirmations:** show what breaks, type the item's name, then a final yes after a 5-second wait.
- **An automatic undo script** for every change.
- **Never touches** SIP, Gatekeeper, XProtect, FileVault or the firewall, nor macx's own watch and the security daemons it relies on.

## Findings (checked 2026-11-25)
- **Apple's system daemons can't be disabled while SIP is on.** Reports say `launchctl disable` of `mediaanalysisd`/`photoanalysisd` as a system service needs SIP off, and SIP being turned back on re-enables them ([MacRumors](https://forums.macrumors.com/threads/mediaanalysisd-photoanalysisd-and-photolibraryd.2445597)). SIP stays on, so system-domain disables are out (that belongs to the Extreme level, step 12).
- **Per-user disables are reported to work with SIP on:** `launchctl bootout gui/<uid>/com.apple.photoanalysisd` and `launchctl disable gui/<uid>/…`, persistent across reboots, undone by `launchctl enable` ([MacRumors](https://forums.macrumors.com/threads/mediaanalysisd-photoanalysisd-and-photolibraryd.2445597/page-2), [dev.to](https://dev.to/gjbianco/controlling-photoanalysisd-3j2a), [AppleInsider](https://appleinsider.com/inside/macos-ventura/tips/how-to-stop-mediaanalysisd-from-hogging-your-cpu-in-macos)). **Unverified on macOS 27:** it must be tested on Lao's Mac (one item, then enabled again) before anything ships.
- **Hibernation 0 / sleep image:** saves disk space and is a known fix for some sleep crashes, but it isn't a speed gain, and with it a flat battery during sleep loses unsaved work ([Apple Community](https://discussions.apple.com/thread/256215568), [Apple Community](https://discussions.apple.com/thread/8317178)).
- **The honest ceiling:** clocks can't be raised. The real gains come from stopping background work that competes with you: Photos' and media analysis, Siri and knowledge indexing (`spotlightknowledged` was in Lao's busiest list), and full Spotlight indexing. Everything else is disk space or battery.

## The Risky list (each measured on Lao's Mac before it ships, and shown with what breaks)
| Item | What it does | What breaks | Undo |
|---|---|---|---|
| Photos analysis off (per user) | `launchctl disable` + `bootout` of `com.apple.photoanalysisd` and `com.apple.mediaanalysisd` in your GUI domain | Photos stops recognising faces, objects and text in your library; Memories stop updating | `launchctl enable`, then sign out and in |
| Siri and knowledge indexing off (per user) | the same for `com.apple.knowledge-agent`, `com.apple.spotlightknowledged`, `com.apple.siriknowledged` (exact labels checked on 27 with `launchctl print gui/<uid>`) | Siri suggestions and "knowledge" features go stale | `launchctl enable` |
| Spotlight indexing off | `mdutil -a -i off` (root) | Spotlight search stops finding new files. **macx itself uses Spotlight to find apps**, so the Apps page gets worse, and the page says so | `mdutil -a -i on` (re-indexes, slow and hot for a while) |
| Hibernation off | `pmset -a hibernatemode 0`, sleep image removed | a flat battery in sleep loses unsaved work; frees disk the size of your RAM (16 GB) | `pmset -a hibernatemode 3` (the old value is stored) |
| Power Nap off | `pmset -a powernap 0` | Mail, iCloud and backups don't update while the Mac sleeps | the stored value |
| Local snapshots purged | `tmutil deletelocalsnapshots /` (root) | you lose the hourly local Time Machine versions | none: a delete. **Shown as not undoable**, behind the same three confirmations |

Each one stores the value it replaced in the undo store, before it's changed. An `undo-risky.sh` next to it puts everything back, and `macx risky undo` (and a button in the app) runs it. Root items go through the administrator prompt.

## Flow
`macx risky` lists the items with what each breaks and its measured effect. `macx risky apply ITEM` then asks:
1. *"This turns off … and breaks …. Continue?"*
2. *"Type the item's name to confirm."*
3. *"Last chance"*, after a 5-second wait.

The app gets a **Risky** section on the Performance tab, in signal red, folded away by default, with the same three steps as sheets.

## Tested on Lao's Mac (2026-11-25, macOS 27.0.1, SIP on)
`launchctl disable gui/501/com.apple.photoanalysisd` was accepted, but `launchctl bootout` was refused: *"Operation not permitted while System Integrity Protection is engaged"* (error 150), and photoanalysisd kept running for the whole minute. The flag was removed again and it's running normally. **So per-user disables of Apple agents are out of the Risky tier**: they may only take effect at the next login, if at all. The Risky tier keeps Spotlight indexing, hibernation, Power Nap and snapshots. The agent disables move to Extreme (SIP off).

## Before building
- **Verify per-user disables on macOS 27** with one item on Lao's Mac: disable `photoanalysisd`, check it doesn't run after the next login, then `launchctl enable` it again. That needs Lao's OK, since it changes his Mac.
- **Measure** idle CPU and heat before and after on Lao's Mac (with `macx top`) for the analysis items, so the page can show a real number instead of a promise.

## Not doing
- Anything that needs SIP off (that's Extreme, step 12, off by default).
- Security daemons (XProtect, syspolicyd, tccd, trustd, endpointsecurityd) and anything macx's watch needs.
