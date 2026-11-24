# Research: Watch Downloads automatically
**Date:** 2026-11-24
**Status:** Complete. Waiting for Lao's approval.
**Researcher:** Claude Code

## Question
Lao, 2026-11-24: "always watching and checking every file in downloads". How should the background watch check every finished download in `~/Downloads` before it's opened, without noise and without slowing the Mac?

## Findings

### Internal
- **Events:** the background watch (`macx daemon`, root, with Full Disk Access) already receives eslogger `create` and `rename` events with full paths, and `deleteextattr` for quarantine removal. No new event types are needed.
- **The checks exist:** `FileChecker` (`macx check`) already covers the signature, Gatekeeper (spctl), quarantine info (who downloaded it, when), the signed malware hash feed, install scripts inside `.pkg` files, disk images (mounted read-only and hidden, then ejected), scripts, compiled AppleScript, and archives' kinds. Verdicts: *Looks OK*, *partly unknown*, *Be careful*, *DON'T OPEN THIS*.
- **Alerts:** alerts already go to `~/Library/Logs/Macximesed/watch.jsonl`. The background watch sends notifications for high and critical ones (grouped, paused when the watch is paused), and the Mac app shows them in its Protection view.
- **Quarantine:** `IncidentRecorder` plus `IncidentContainment` (a case folder plus the undo store) already exist; the chamber uses them.
- **Chamber:** `macx chamber run` can take a script for a deeper look.

### External
- **In-progress downloads** are named `name.download` (Safari), `name.crdownload` (Chrome) and `name.part` (Firefox). The suffix is dropped by a rename when the download finishes (fileinfo.com; Mozilla bug 308210; schieb.de). Safari downloads stuck with `.download` were reported on Sequoia (iClarified, Apple Community), so a stuck one should never be checked as finished.
- So **"finished download" = a `rename` whose destination is directly in `~/Downloads` and whose source ended in `.download`, `.crdownload` or `.part`**, or a `create` of a final name directly in `~/Downloads` by a program that isn't a browser mid-download (curl `-o`, AirDrop, Mail and Messages attachments).

## Sources
| Source | URL | Key takeaway |
|---|---|---|
| fileinfo.com: .DOWNLOAD | https://fileinfo.com/extension/download | Safari appends `.download` while downloading |
| Mozilla bug 308210 | https://bugzilla.mozilla.org/show_bug.cgi?id=308210 | Firefox keeps a `.part` file and renames when done |
| schieb.de | https://www.schieb.de/?p=760141 | `.download`, `.crdownload`, `.part` per browser |
| iClarified: Safari `.download` stuck | https://www.iclarified.com/Q45728/safari-downloads-stuck-with-download-extension-on-macos-sequoia | The rename can fail; don't treat temp names as finished |
| Apple Community 256279817 | https://discussions.apple.com/thread/256279817 | Same, 2026 |

## Recommendation
Add a **Downloads check** to the background watch:
1. **Detect:** a rename into `~/Downloads` from a browser temp name, or a create there of a final name. Wait 2 s for writing to settle (the file size stays the same), then check. It's queued on a background queue, never in the eslogger loop, and one file at a time.
2. **Check:** the same `FileChecker` as `macx check`, offline only (the signed hash feed, never a network lookup). The file is pinned by SHA-256 when checked. Files over 2 GB are hashed and signature-checked but not unpacked.
3. **Report:**
   - *DON'T OPEN THIS* is a **critical** alert (`download-dangerous`) with a notification naming the file and the main reason;
   - *Be careful* and *partly unknown* are a **medium** alert (`download-caution`): in the app and the log, no notification;
   - *Looks OK* gets a quiet info line, for history only.
4. **Quarantine** (Lao's choice, see below): *DON'T OPEN THIS* moves the file into an incident case and the undo store (restorable with `macx undo restore`), owned by Lao, not root.
5. **Scripts** that come out *Be careful* get a hint: `macx chamber run FILE`. The chamber isn't run automatically: it would boot a VM on every download.
6. **Settings:** on by default with the background watch. `macx daemon install --no-downloads` turns it off, and the app gets a toggle.

**Decision for Lao: what happens on DON'T OPEN THIS?**
- **(a) Notify only** (the file stays where it is).
- **(b) Notify and quarantine automatically,** restorable. *Recommended:* the reason to watch Downloads is to stop the file being opened, and a notification can be missed.

## Test plan sketch
- [ ] A rename `x.dmg.crdownload` → `x.dmg` in ~/Downloads is a finished download; a rename inside a subfolder, or to a temp name, isn't.
- [ ] A create of `notes.txt` in ~/Downloads is checked; `x.part` isn't; a stuck `name.download` is never checked.
- [ ] Verdict mapping: dangerous is critical `download-dangerous`; caution is medium; OK is info.
- [ ] Quarantine moves the file into a case and the undo store, owned by the user, restorable; a file that changed after the check is refused.
- [ ] The check runs off the event loop; a burst of 50 downloads is queued, not dropped.

## Risks & unknowns
- **Disk images:** mounting one from a root daemon is read-only and hidden, the same as `macx check`, but it adds a root mount per `.dmg`. It's fine, but keep the existing timeouts.
- **Big files:** hashing a 10 GB download costs I/O; hash in a background queue at low priority.
- **False positives:** they'd now arrive as notifications. Only *DON'T OPEN THIS* notifies, and the false-alarm work (dev 7b65912) applies.
- **Other folders:** Desktop and other folders aren't covered (AirDrop can save elsewhere). Downloads first; more folders can be added later.

## Next steps
- [ ] Lao approves, and picks (a) or (b).
- [ ] TDD: detection, the queue, the verdict mapping, quarantine; then a real test with a harmless download.
