# Runtime evaluation: macx watch --suspend

- Date: 2026-11-24 · macx 0.2.0 · commit 3cab554 · macOS 27.0.1 (arm64)
- Each simulation is harmless (see the top of `scripts/eval/runtime.sh`). Times are from just before the action to the alert being logged.

## Detection and response

| Simulation | Expected rule | Alert | ms to alert | ms alert → frozen | Work done before frozen | Children frozen |
|---|---|---|---|---|---|---|
| Pasted base64 into zsh | `base64-to-shell` | yes | 33 | 7 | stopped at 509 | n/a |
| Child started before the alert | `base64-to-shell` | yes | 185 | 5 | - | yes (state T) |
| dscl -authonly password check | `password-check` | yes | 145 | - | - | - |
| Hidden .com.apple folder | `fake-apple-folder` | yes | 98 | - | - | - |
| New launch agent written | `new-launch-item` | yes | 98 | - | - | - |
| Quarantine flag removed | `quarantine-removed` | yes | 186 | - | - | - |
| Ad-hoc program from hidden folder | `exec-from-hidden-or-temp` | yes | 153 | - | - | - |

*Work done before frozen* is the counter a busy loop reached before it stopped: each step is one shell
arithmetic operation plus one small file write.

## Overhead (macx / eslogger)

| Period | CPU | Peak memory |
|---|---|---|
| Idle (15 s) | 2.8% / 0.5% | 370 MB / 8 MB |
| During simulations | 2.7% / 0.9% (peak 5.0% / 2.2%) | 381 MB / 8 MB |

## eslogger benchmark (same file load: repeatedly reading 200 small files for 20 s)

| Events | eslogger CPU | Peak memory | Events per second |
|---|---|---|---|
| macx events (exec, create, rename, deleteextattr, btm_launch_item_add) | 5.5% (peak 6.2%) | 8 MB | 306 |
| the same plus open | 95.1% (peak 101.2%) | 475 MB | 11576 |

10 log records so far. `open` is left out of `macx watch` because of the difference above.

## Everything logged during the run

10 log records: base64-to-shell ×2, frozen ×2, password-check ×1, fake-apple-folder ×1, new-launch-item ×1, quarantine-strip ×1, quarantine-removed ×1, exec-from-hidden-or-temp ×1. Anything here that isn't a simulation is a false positive from normal background activity.
