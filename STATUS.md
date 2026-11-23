# Status

The job list: what is being built now and what comes next. Finished work moves to [CHANGELOG.md](CHANGELOG.md).

Steps run from easiest to hardest, and each one needs only steps already built. The full plan is in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).

## Now
- [ ] **3. Apps**: list apps with size, last use and arm64/Intel; mark unused ones (90 days); uninstall with leftovers (and find leftovers of apps already removed); undo through the undo store.

## Next
- [ ] **4. Persistence scan**: snapshot and diff LaunchDaemons/Agents, background items, login items, cron, shell rc files, profiles and hidden folders; AMOS rules (fake `com.apple.*` labels, hidden-folder loaders).
- [ ] **5. File check**: signature, team ID, notarization, quarantine, SHA-256, what a pkg/dmg/app installs. Optional MalwareBazaar hash lookup.
- [ ] **6. Paste-to-shell guard (static)**: scan shell history and clipboard for `curl | sh`, `base64 -D | sh`, quarantine stripping.
- [ ] **7. Boost + throttle view + Medium tier**: background QoS, App Nap, visual effects, Spotlight pause; every change restorable.
- [ ] **8. Games**: per-game profiles (Boost, Rosetta check, Metal HUD), heat graph, best way to run (native, CrossOver, cloud).
- [ ] **9. Live watch**: eslogger (root + Full Disk Access) feeding the step 4 and 6 rules live.
- [ ] **10. Risky tier**: triple confirmation, undo script.
- [ ] **11. Root daemon + menu bar app**.
- [ ] **12. Extreme**: deleting sealed-volume apps after the user turns SIP and authenticated-root off in Recovery. Off by default.

## Done
- [x] **1. `macx scan`** (2026-11-23).
- [x] **2. Undo store + Safe cleanup**, `macx clean` / `macx undo` (2026-11-23). The Trash is left out on purpose: emptying it is a permanent delete.

See [CHANGELOG.md](CHANGELOG.md) for details.

## Open questions
- Should purging old undo batches happen automatically? It's manual for now (`macx undo purge`), because it's the only real delete.
- Does `csrutil authenticated-root disable` need FileVault off on Apple Silicon? Check on the machine before step 12.
- How much CPU does eslogger use with `open` events on? Measure before step 9.
- Is the `sfltool dumpbtm` format stable on macOS 27? Check before step 4.
