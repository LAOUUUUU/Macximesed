# Spec: detonation chamber (Phase 1)
Approved by Lao on 2026-11-24 ("Yes, go ahead") after [research/detonation-chamber/RESEARCH.md](../research/detonation-chamber/RESEARCH.md).

## What it does
`macx chamber run FILE` runs a suspicious file in a throwaway macOS virtual machine with no network, records what it does, judges it on the real Mac, and quarantines the original if it's bad. It never runs the file on the real Mac.

## Facts settled by the spike (2026-11-24, macOS 27.0.1, M3)
- **Signing:** a binary signed with the self-signed "Macximesed Local Signing" identity and the `com.apple.security.virtualization` entitlement passes `VZVirtualMachineConfiguration.validate()`. Without the entitlement, the validation refuses it. No paid Apple account needed.
- **macOS image:** `VZMacOSRestoreImage.fetchLatestSupported` gives macOS 27.2.1 (26B131), `UniversalMac_27.2.1_26B131_Restore.ipsw`, **25.6 GB**.
- **Disk:** Lao's Mac has 31 GB free, not enough for the image plus a guest. The chamber's location is configurable (an external disk works). Setup checks free space first and refuses with a clear message.

## Parts
1. **Host side (no VM needed, built first)**
   - `ChamberLog`: reads the guest's event log as untrusted data. Caps size (20 MB) and lines, drops lines that don't parse, never follows paths in it.
   - Chamber rules, on top of `WatchRules` run with the guest's home:
     - `reads-keychain` (critical): opens a keychain file;
     - `reads-browser-data` (high): opens browser password or cookie stores;
     - `reads-wallet` (high): opens crypto wallet files;
     - `vm-check-then-quit` (high): a `vm-check` alert, then the sample's process tree exits within 10 s.
   - `ChamberVerdict`:
     - *DON'T OPEN THIS* for any critical alert, or two or more different high ones;
     - *Be careful* for any high or medium alert;
     - *Nothing seen* otherwise.

     Never "safe": the wording says that a VM check, a long sleep or waiting for a click can hide behaviour.
   - `ChamberSample`: pins the file by SHA-256 when the run is requested, and refuses to start if the file changed.
   - `ChamberQuarantine`: on *DON'T OPEN THIS* (or `--quarantine` on *Be careful*), records an incident case with the original (read-only copy, hashes, the chamber's alert timeline), then moves the original into the undo store. Restorable with `macx undo restore`. Nothing is deleted.
2. **VM side: the light chamber** (changed 2026-11-24: a tiny Linux VM, about 100 MB, not a 25.6 GB macOS guest)
   - `macx chamber setup`:
     - downloads about 70 MB from Alpine 3.24.4 (asks first, shows files and sizes);
     - checks each file against the SHA-256 pinned in `data/chamber/manifest.json`;
     - unpacks the kernel (raw arm64 `Image`) and keeps the base system and packages in `~/Library/Application Support/Macximesed/Chamber`.
   - `macx chamber run FILE [--seconds 60]`:
     - builds a fresh initramfs (base system, bash/zsh/python3/perl/strace, Mac stand-in stubs, the agent, a fake `/Users/chamber` with canary keychain, browser and wallet files, the pinned sample);
     - boots it with no disk, no network and no shared folder;
     - the agent runs the sample under `strace -f`, and stubs and strace write to the console port;
     - after the time limit, or when the sample exits, the VM stops. Nothing survives.
   - The host turns strace lines and stub records into events (exec, open, create, rename, connect) and passes them to `ChamberJudge`.
   - Scripts only: a Mach-O binary or an app gets "can't run in the light chamber", with the static check's result instead.
3. **Entry points:** `macx chamber run`, and a hint from `macx check` and `macx guard inspect` when their verdict is *partly unknown*.

## Not in Phase 1
Network (none at all), answering password prompts (canary credentials), hiding VM tells, and the full macOS chamber for apps and binaries. Phases 2 and 3 in the research brief.

## Tests first (host side)
- An empty log gives *Nothing seen*, and the summary says nothing seen is not the same as safe.
- A fake `com.apple.*` LaunchDaemon write in the guest gives *DON'T OPEN THIS*.
- Opening `~/Library/Keychains/login.keychain-db` gives `reads-keychain` (critical).
- A `vm-check` exec, then the sample's process exiting 3 s later, gives `vm-check-then-quit`.
- Two different high rules give *DON'T OPEN THIS*; one high gives *Be careful*.
- Log hygiene: lines over 64 KB, more than 200,000 lines, and malformed JSON are skipped, and a log over 20 MB is cut off with a note.
- A pinned file that changed after pinning is refused.
- Quarantine: a case is recorded with the right SHA-256, the original is in the undo store, and the restore brings it back.
