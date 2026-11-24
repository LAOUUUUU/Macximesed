# Status

The job list: what is being built now and what comes next. Finished work moves to [CHANGELOG.md](CHANGELOG.md).

Steps run from easiest to hardest, and each one needs only steps already built. The full plan is in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).

## Antivirus checklist: done, released as 0.2.0 (2026-11-24)
Lao, 2026-11-23: "we release when the anti virus is fully built".

- [x] **A. Signed hash feed** (built 2026-11-23; goes live with the first release) on GitHub Pages: listed in the signed channel, cached locally, checked offline by `macx check` and `macx watch`.
- [x] **B. Runs in the background** (2026-11-23): `sudo macx daemon install` (launchd), notifications for high and critical alerts, `macx alerts`, `macx daemon status`. Tested on macOS 27.0.1: watching, a test alert logged, about 1% CPU.
- [x] **C. Network watching** for flagged processes (2026-11-23): libproc polling every 20 ms, `macx net`; miss rate in [research/evaluation/network-results.md](research/evaluation/network-results.md).
- [x] **D. Configuration profiles** in `macx persist` (2026-11-23): yours without root, computer-wide ones with `sudo`; rules by payload type. Not yet checked against a real installed profile (CI runners can't install one: the `profiles` tool no longer installs).
- [x] **E. `sfltool` stall understood** (2026-11-23): without root it asks for an admin password (`system.privilege.admin`) and waits on the dialog; as root it answers at once. It now runs only as root. Reading the BTM file directly is no better: its folder needs Full Disk Access.
- [x] **F. Evaluations re-run** (2026-11-24, macOS 27.0.1, M3, with Macximesed's own Full Disk Access): static 17/17 attacks flagged (12 dangerous), 0/11 installers dangerous; runtime 7/7 steps alerted in 31–257 ms, frozen 5–6 ms after the alert, children frozen. CI on the final commit: see below.
  - [x] The daemon stops on SIGTERM: `daemon.log` shows "Stopped watching.", and launchd sent no SIGKILL (2026-11-23 19:39).

- [x] **Full Disk Access for macx itself: solved** (2026-11-23). The Full Disk Access entry kept the code requirement from when it was first added (ad-hoc), and switching it off and on never refreshed it. tccd logged `Failed to match existing code requirement`. Fix: `sudo tccutil reset SystemPolicyAllFiles dev.macximesed.macx`, then add the signed app again.
  - [x] Survives rebuilds: after three reinstalls, `sudo macx daemon restart` still reports *watching* (2026-11-23 19:31).

## Detonation chamber (approved 2026-11-24; [spec](specs/detonation-chamber.md), [research](research/detonation-chamber/RESEARCH.md))
Run a suspicious file in a throwaway macOS VM with no network, judge it on the real Mac, quarantine it if bad.
- [x] VM-check rule (`vm-check`) in guard, check, persist and watch: catches AMOS's own check.
- [x] Spike: the self-signed app can use Apple's Virtualization framework (with the `com.apple.security.virtualization` entitlement). The macOS image is 27.2.1, 25.6 GB.
- [x] Host side: untrusted-log reader, chamber rules (keychain, browser and wallet reads, VM check then quit), verdict, sample pinning, quarantine into an incident case and the undo store.
- [x] Switched to the **light chamber** (Lao: 25.6 GB is too big). It's a tiny Alpine Linux VM, 52 MB in all, that runs scripts with Mac commands replaced by stand-ins. Mac apps and binaries keep the static checks.
- [x] Light chamber pieces: strace reader, `network-attempt` rule, initramfs (cpio) writer.
- [x] Boot test (2026-11-24): verified Alpine downloads, zboot kernel unwrapped, booted with no disk or network, ran a pretend stealer in 1.6 s, judged *DON'T OPEN THIS* from the real trace.
- [x] `macx chamber setup` (2026-11-24): pinned manifest (15 files, 49.6 MB), SHA-256 checks, unpacking with macOS's tar, kernel unwrap; 61 MB on disk. The app and the updater sign with the Virtualization entitlement.
- [x] `macx chamber run FILE` (2026-11-24): a pretend AMOS-style script gave *DON'T OPEN THIS* in 1.6 s (password box, dscl check, keychain and Chrome reads, fake Apple LaunchDaemon, piped VM check, upload attempt). An ordinary script gave *Nothing seen*. Quarantine and undo restore checked.
- [x] Intel Macs, data side: x86_64 manifest pinned (52 MB), kernel check `ChamberKernel` (bzImage on Intel, EFI-zboot unwrapped on Apple silicon). Booting on a real Intel Mac is untested; CI can't boot VMs. Setup picks the manifest by processor, so it now finds the x86_64 one. Still to do: setup should check the kernel with `ChamberKernel` (on Intel it's used unchecked), and the run image's strace command should use `StraceLog.traceSyscalls` (today it traces `openat` only, which misses Intel's `open` and `creat`).
- [x] `macx check` suggests the chamber for scripts it rates *Be careful* or *partly unknown*. (`guard inspect` still to do: it holds the fetched script in memory, not a file.)

## Check on macOS 27.3 (expected early December 2026)
Apple's 27.3 changes Full Disk Access ([Apple's post](https://developer.apple.com/news?id=oqng0zjk), 2026-11-16): users are guided to grant only specific folders, there's a new grant prompt and a menu-bar list of apps with access, and grants made before the update stay in effect. Endpoint Security and eslogger aren't mentioned, and the new entitlements are only for backup and assistive-technology apps.
- [ ] After updating: the background watch still says *watching* (the existing grant should carry over).
- [ ] On a fresh grant: does a folders-only grant let eslogger start? If not, can `macx privacy` tell full from scoped access without reading a guarded folder (which would set off a popup)?
- [ ] Re-check the steps in README and `macx privacy` against the new prompt.

## Next
- [ ] **7. Boost + throttle view + Medium tier**: background QoS, App Nap, visual effects, Spotlight pause; every change restorable.
- [ ] **8. Games**: per-game profiles (Boost, Rosetta check, Metal HUD), heat graph, best way to run (native, CrossOver, cloud).
- [ ] **10. Risky tier**: triple confirmation, undo script.
- [ ] **11. Root daemon + menu bar app**.
- [ ] **12. Extreme**: deleting sealed-volume apps after the user turns SIP and authenticated-root off in Recovery. Off by default.

## Done
- [x] **1. `macx scan`** (2026-11-23).
- [x] **2. Undo store + Safe cleanup**, `macx clean` / `macx undo` (2026-11-23). The Trash is left out on purpose: emptying it is a permanent delete.
- [x] **3. Apps**, `macx apps` / `remove` / `leftovers` (2026-11-23). Last use is estimated from the app's own files when Spotlight has no date.
- [x] **4. Persistence scan**, `macx persist` with `--baseline` / `--diff` and the AMOS rules (2026-11-23).
- [x] **5. File check**, `macx check` (2026-11-23): apps, packages (install scripts read), disk images (mounted read-only), scripts, AppleScript; optional MalwareBazaar.
- [x] **6. Paste-to-shell guard**, `macx guard` (2026-11-23): history scan with base64 decoding, clipboard check, opt-in zsh Enter-key hook.
- [x] **9. Live watch**, `sudo macx watch [--suspend]` and `--replay` (2026-11-23). This finishes the antivirus side, apart from running it in the background (step 11).
- [x] **Paste inspection**, `macx guard inspect` plus disguise-undoing (2026-11-23): reads what a pasted link serves and runs only the inspected copy.
- [x] **Fixes from review** (2026-11-23): unknowns never count as safe (new *partly unknown* verdict), combination scoring, SHA-256 checked again before running, pipe scripts fed on stdin, whole-tree suspend.
- [x] **Static evaluation** (`scripts/eval/static.sh`): 17/17 simulated attacks flagged (12 dangerous), 0/11 real installers marked dangerous.
- [x] **Runtime evaluation** (re-run 2026-11-24, macOS 27.0.1): 7/7 steps alerted in 31–257 ms, freeze 5–6 ms after the alert, children frozen, a busy loop got 9,441 steps before it stopped. macx about 0.5% CPU idle and 2.7% during the simulations. eslogger with macx's events: 5.9% CPU under file load; adding `open` costs 88% CPU and 286 MB, so it stays off.
- [x] **Wider persistence coverage** (2026-11-23): authorization plugins, login hooks, PAM, DYLD injection, periodic, sudoers.d, at, and app, system, kernel and browser extensions.
- [x] **Incident response**, `macx incident` (2026-11-23): case folders with evidence, hashes, process tree and timeline; containment into the undo store; rotation checklist.
- [x] **Auto-update** through a signed GitHub Pages channel with a forced security floor (2026-11-23). It goes live with the first release.
- [x] **No privacy popups** and `macx privacy` (2026-11-23): guarded folders skipped without Full Disk Access; the installed binary owns its permissions.

See [CHANGELOG.md](CHANGELOG.md) for details.

## Open questions
- `macx persist` labels a program signed with the local self-signed certificate as "ad-hoc (no identity)". It should say self-signed.
- Should purging old undo batches happen automatically? It's manual for now (`macx undo purge`), because it's the only real delete.
- Does `csrutil authenticated-root disable` need FileVault off on Apple Silicon? Check on the machine before step 12.
- `open` events are left out of the live watch because they're too noisy. Keychain and browser-data reads are only caught through what the reading program does next.
- `sfltool dumpbtm` is undocumented. The parser keeps unknown keys and types and skips what it can't read; re-check on each macOS release.
- Configuration profiles: the parser follows the documented `profiles show -output stdout-xml` layout. Check it against a real installed profile when one is on hand.
