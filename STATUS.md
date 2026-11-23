# Status

The job list: what is being built now and what comes next. Finished work moves to [CHANGELOG.md](CHANGELOG.md).

Steps run from easiest to hardest, and each one needs only steps already built. The full plan is in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).

## Now
- [ ] **Run `sudo scripts/eval/runtime.sh`** on a real Mac (needs root + Full Disk Access for macx). It measures detection, alert and freeze delay, work done before the freeze, child freezing and overhead, and checks the eslogger parser against real output.
- [ ] **Network watching** (`nettop`/`lsof` polling): not built. Test first how many short connections a poll misses.
- [ ] **Configuration profiles** in `persist` (needs root to list).
- [ ] **`sfltool dumpbtm` stopped answering on this Mac on 2026-11-23** (it answered earlier that day). Find out whether it's waiting for an authorization prompt.
- [ ] **Signed hash feed** on GitHub Pages (the channel is there now: add a `hashFeed` entry to it), checked offline by `macx check` and `macx watch`.

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
- Configuration profiles: `profiles` needs root to list them, so the persistence scan doesn't cover them yet.
