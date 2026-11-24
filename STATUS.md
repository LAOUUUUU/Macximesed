# Status

The job list: what is being built now and what comes next. Finished work moves to [CHANGELOG.md](CHANGELOG.md).

Steps run from easiest to hardest, and each one needs only steps already built. The full plan is in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).

## Antivirus checklist: the first release (0.2.0) ships when all of these are done
Lao, 2026-11-23: "we release when the anti virus is fully built".

- [x] **A. Signed hash feed** (built 2026-11-23; goes live with the first release) on GitHub Pages: listed in the signed channel, cached locally, checked offline by `macx check` and `macx watch`.
- [ ] **B. Runs in the background** without a terminal open: a launchd daemon running `macx watch`, with a way to see alerts. This depends on solving Full Disk Access below; a launchd daemon is one of the untried routes.
- [x] **C. Network watching** for flagged processes (2026-11-23): libproc polling every 20 ms, `macx net`; miss rate in [research/evaluation/network-results.md](research/evaluation/network-results.md).
- [x] **D. Configuration profiles** in `macx persist` (2026-11-23): yours without root, computer-wide ones with `sudo`; rules by payload type. Not yet checked against a real installed profile (CI runners can't install one: the `profiles` tool no longer installs).
- [x] **E. `sfltool` stall understood** (2026-11-23): without root it asks for an admin password (`system.privilege.admin`) and waits on the dialog; as root it answers at once. It now runs only as root. Reading the BTM file directly is no better: its folder needs Full Disk Access.
- [ ] **F. CI green** on the final commit, and both evaluations re-run on it.

- [ ] **(Needed for B) Full Disk Access for macx itself is unsolved on macOS 27.0.1.** Tried 2026-11-23, all refused by eslogger ("responsible process needs TCC Full Disk Access") even with the switch on in Settings:
  1. the bare ad-hoc binary;
  2. an ad-hoc signed `Macximesed.app`;
  3. the app signed with a self-signed "Macximesed Local Signing" certificate (untrusted);
  4. the same with the certificate trusted for code signing.

  **Works:** Full Disk Access on Terminal.app, then `sudo MACX_OWN_RESPONSIBILITY=0 macx watch` from Terminal.

  **Not tried yet:**
  - an Apple Development certificate (needs an Apple ID in Xcode);
  - running the watcher as a launchd daemon registered with SMAppService from the app;
  - checking whether `sudo` itself breaks the responsibility hand-off. Test `macx watch` started some other way than sudo, for example from launchd.

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
- [x] **Runtime evaluation** (2026-11-23, macOS 27.0.1): 7/7 steps alerted in 47–245 ms, freeze 5–9 ms after the alert, children frozen, about 2% CPU. `open` events cost 94% CPU and 706 MB, so they stay off. The eslogger parser works on real output.
- [x] **Wider persistence coverage** (2026-11-23): authorization plugins, login hooks, PAM, DYLD injection, periodic, sudoers.d, at, and app, system, kernel and browser extensions.
- [x] **Incident response**, `macx incident` (2026-11-23): case folders with evidence, hashes, process tree and timeline; containment into the undo store; rotation checklist.
- [x] **Auto-update** through a signed GitHub Pages channel with a forced security floor (2026-11-23). It goes live with the first release.
- [x] **No privacy popups** and `macx privacy` (2026-11-23): guarded folders skipped without Full Disk Access; the installed binary owns its permissions.

See [CHANGELOG.md](CHANGELOG.md) for details.

## Open questions
- Should purging old undo batches happen automatically? It's manual for now (`macx undo purge`), because it's the only real delete.
- Does `csrutil authenticated-root disable` need FileVault off on Apple Silicon? Check on the machine before step 12.
- `open` events are left out of the live watch because they're too noisy. Keychain and browser-data reads are only caught through what the reading program does next.
- `sfltool dumpbtm` is undocumented. The parser keeps unknown keys and types and skips what it can't read; re-check on each macOS release.
- Configuration profiles: the parser follows the documented `profiles show -output stdout-xml` layout. Check it against a real installed profile when one is on hand.
