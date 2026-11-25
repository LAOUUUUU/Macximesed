# Status

The job list: what is being built now and what comes next. Finished work moves to [CHANGELOG.md](CHANGELOG.md).

Steps run from easiest to hardest, and each one needs only steps already built. The full plan is in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).

## 0.4.1 (2026-11-25)
The app's idle CPU (about 43% to 0%), memory pressure and a CPU/Memory switch on the Performance tab, and the app icon for installs updated from 0.3.0.

## 0.4.0 (2026-11-25)
Released with the .pkg and .dmg (signed with the release certificate) and whole-app updates for them, the app icon, motion everywhere, the status bar and update pop-up, the chamber on the Check page, the Performance tab with While playing (raw mouse, game network, Do Not Disturb shortcuts, SOCD), the 12 new watch events, the Atomic Red Team fixes (30 of 33 caught, 0 false alarms), the persist gaps, and the beta channel (beta key built in; publishing starts once this is on main).

## 0.3.0 (2026-11-24)
Released with the Mac app and menu bar, first-run setup, the light detonation chamber, Boost/top/tune/games, the Downloads watch (automatic quarantine), Intel support (not yet run on Intel hardware) and the false-alarm fixes. Evaluations on 3cab554: static 17/17 attacks flagged, 0/11 installers dangerous; runtime 7/7 alerted in 33–186 ms, frozen 5–7 ms after the alert. The 370 MB in the runtime eval (and the daemon creeping from 24 MB to 114 MB) was an autorelease-pool leak in the watch loop, fixed on dev after 0.3.0.

## Antivirus checklist: done, released as 0.2.0 (2026-11-24)
Lao, 2026-11-23: "we release when the anti virus is fully built".

- [x] **A. Signed hash feed** (built 2026-11-23; goes live with the first release) on GitHub Pages: listed in the signed channel, cached locally, checked offline by `macx check` and `macx watch`.
- [x] **B. Runs in the background** (2026-11-23): `sudo macx daemon install` (launchd), notifications for high and critical alerts, `macx alerts`, `macx daemon status`. Tested on macOS 27.0.1: watching, a test alert logged, about 1% CPU.
- [x] **C. Network watching** for flagged processes (2026-11-23): libproc polling every 20 ms, `macx net`; miss rate in [research/evaluation/network-results.md](research/evaluation/network-results.md).
- [x] **D. Configuration profiles** in `macx persist` (2026-11-23): yours without root, computer-wide ones with `sudo`; rules by payload type. Checked against a real installed profile on 2026-11-24 (macOS 27.0.1): it found a bug, now fixed, and the real output is a test fixture.
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
- [x] Intel Macs, data side: x86_64 manifest pinned (52 MB), kernel check `ChamberKernel` (bzImage on Intel, EFI-zboot unwrapped on Apple silicon). Booting on a real Intel Mac is untested; CI can't boot VMs. Setup picks the manifest by processor, checks every kernel with `ChamberKernel.prepare` on both chips, and the run image traces `StraceLog.traceSyscalls`, so Intel's `open` and `creat` are seen (0.3.0).
- [x] `macx check` and `macx guard inspect` suggest the chamber for scripts they rate *Be careful* or *partly unknown*. `guard inspect` hands it the copy it inspected, saved in a private folder (2026-11-24).

## Detonation chamber phase 2 (Lao picked all four 2026-11-24; [brief](research/detonation-chamber/PHASE2.md))
Skeleton on dev: `ChamberNet.swift` (request log, `uploads-stolen-data`, `waits-before-acting`, `--follow` limits), `ChamberPackage.swift` (finds pre/postinstall scripts), `chamber run --follow` and `.pkg` say "not built yet", `scripts/eval/chamber-art.sh` writes the 22 test scripts.
- [ ] 1. Python and Perl scripts allowed; `sleep` stand-in that records and returns.
- [ ] 2. Fake-internet recorder in the `curl`/`wget`/`nscurl` stand-ins (agent prints `/tmp/macx-requests`), then `--follow` rounds.
- [ ] 3. `.pkg`: expand, run each script as Installer would.
- [ ] 4. Chamber ART run on the Mac, score against `chamber-art-tests.txt`, fix misses.
- [ ] 5. `LD_PRELOAD` sleep shim for Python/Perl (riskiest, last).

## Check on macOS 27.3 (expected early December 2026)
Apple's 27.3 changes Full Disk Access ([Apple's post](https://developer.apple.com/news?id=oqng0zjk), 2026-11-16): users are guided to grant only specific folders, there's a new grant prompt and a menu-bar list of apps with access, and grants made before the update stay in effect. Endpoint Security and eslogger aren't mentioned, and the new entitlements are only for backup and assistive-technology apps.
- [ ] After updating: the background watch still says *watching* (the existing grant should carry over).
- [ ] On a fresh grant: does a folders-only grant let eslogger start? If not, can `macx privacy` tell full from scoped access without reading a guarded folder (which would set off a popup)?
- [ ] Re-check the steps in README and `macx privacy` against the new prompt.

## Logs, reports and beta builds ([research](research/diagnostics-beta/RESEARCH.md))
- [x] 1. Verbose logs: `-v`/`-vv`, per-part log files, `sudo macx daemon log debug|info`.
- [x] 2. Bug and crash reports: `macx report`, redaction, crash summaries, Copy / Save, Settings > Problems.
- [x] 3. Encrypted sending and the relay (`scripts/report-relay`). Off until Lao sets up the Worker, the Discord channel and the report key.
- [x] 4. Beta client (2026-11-24): `dev-<commit>` versions, separate beta key list and verifier, per-channel sequence, `macx update --channel`, Settings switch. Closed until a beta public key is built in.
- [x] 5. Beta workflows (2026-11-25): beta-build.yml, beta-publish.yml, make-beta-key.sh, dev ruleset. Opens once Lao runs make-beta-key.sh and the release puts beta-publish.yml on main.

## Next
- [ ] **Performance round 3** ([brief](research/performance-v3/RESEARCH.md), 2026-11-25, waiting for Lao's OK): "Why it's slow" (BUILT 2026-11-25, with Quit for background apps, battery, memory and disk notes), Quit button in the Memory view, power awareness, disk-space warning, Minecraft check, Roblox advice, display refresh rate, pause backups while playing (all BUILT 2026-11-25); game launchers for Minecraft/Roblox = to be researched (research/game-launchers/PLAN.md), and a **virtual display experiment** (private CGVirtualDisplay; ships only if the Metal HUD shows an FPS gain).
- [x] **Performance tab** in the app (2026-11-25): live heat and busiest processes, Boost, tweaks, games with Play.
- [x] **Performance round 2** (2026-11-25, [brief](research/performance-v2/RESEARCH.md)): raw mouse, game network (AWDL), Do Not Disturb shortcuts, SOCD per game. Not yet tried by Lao on the real Mac: SOCD (needs Input Monitoring + Accessibility granted to the app), raw mouse with the HyperX, AWDL off during a game (needs the reinstalled daemon); before/after jitter comparison.
- [x] **Independent testing with Atomic Red Team** (2026-11-25, [results](research/evaluation/art-results.md)): 30 of 33 caught on macOS 26 and 15, 0 false alarms. Runs weekly and on harness changes. Open: the privacy-grant alert can't be triggered on demand on the runner.
- [x] **.pkg + .dmg downloads** (2026-11-24, [research/installers/RESEARCH.md](research/installers/RESEARCH.md)): built on dev. Left: Lao runs `scripts/release/make-release-cert.sh` once (and saves the .p12 in Bitwarden); after the next release, try the .pkg on a Mac (Open Anyway, install, setup, then an update through the app archive).
- [x] **7. Boost + throttle view + Medium tier** (2026-11-24): `macx top`, `macx boost` (with `measure`), `macx tune`. Spotlight pause and Low Power Mode are left out: they need root, and Boost writes your own settings, so it runs without sudo. The research found pausing Spotlight saves little.
- [x] **8. Games** (2026-11-24): `macx games` list, add, forget and play, with Boost, the Metal HUD, heat and load timelines, and how best to run each game. Game Mode can't be forced (no public switch), so macx reports it and reminds you to play full screen.
- [ ] **10. Risky tier** ([brief](research/risky-tier/RESEARCH.md), 2026-11-25, waiting for Lao's OK): per-user disables of Photos/media analysis and Siri knowledge agents (SIP stays on; system-domain disables need SIP off = Extreme), Spotlight indexing off, hibernation off, Power Nap off, local snapshots purged; three confirmations, stored before-values, undo script. First: verify a per-user disable on macOS 27 on Lao's Mac.
- [x] **11. Root daemon + menu bar app** (daemon 2026-11-23; app and menu bar 2026-11-24, design in [research/app-ui/RESEARCH.md](research/app-ui/RESEARCH.md)). Left:
  - [ ] Lao: reinstall (`scripts/install.sh`), then `sudo macx daemon restart` so the daemon runs the build that honours pause.
  - [ ] Check the menu bar glyph and panel on the real menu bar, in light and dark.
  - [x] First-run setup and app notifications (2026-11-24, [research/app-onboarding/RESEARCH.md](research/app-onboarding/RESEARCH.md)).
  - [ ] Check whether the daemon's osascript notifications show under Script Editor in System Settings > Notifications (the reason for app notifications; not confirmed).
  - [x] Icon for the app bundle (2026-11-25, `scripts/make-icon.swift`).
  - [ ] "Open at login" with SMAppService on an LSUIElement app: test after a reboot.
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
- The `privacy-granted` alert (eslogger `tcc_modify`) has never been seen live. A 5-minute eslogger capture while Lao switched Screen Recording on and off got 0 events, and the background watch flagged nothing (2026-11-24, macOS 27.0.1). Either the toggle fell outside the capture or macOS doesn't send `tcc_modify` for Settings toggles. The `profile-added` alert was seen live (20:56 UTC). Trap: `sudo sh -c 'eslogger … & sleep N; kill -INT $p'` never stops eslogger (background jobs in sh ignore SIGINT); use plain `kill`.
- Metal HUD via `open --env MTL_HUD_ENABLED=1` is untested on macOS 27, and doesn't reach games started by Steam or CrossOver.
- `~/Library/Preferences/NSGlobalDomain.plist` (empty) was left by the global-domain bug on Lao's Mac (2026-11-24 00:31). It's harmless; remove it if Lao says so.
- Should purging old undo batches happen automatically? It's manual for now (`macx undo purge`, or `macx undo empty` and Clean > *Empty undo folder* for everything), because those are the only real deletes.
- Does `csrutil authenticated-root disable` need FileVault off on Apple Silicon? Check on the machine before step 12.
- `open` events are left out of the live watch because they're too noisy. Keychain and browser-data reads are only caught through what the reading program does next.
- `sfltool dumpbtm` is undocumented. The parser keeps unknown keys and types and skips what it can't read; re-check on each macOS release.
