# Runtime evaluation: macx watch --suspend

- Date: 2026-11-23 · macx 0.1.0 · commit a53ae99 · macOS 27.0.1 (arm64)
- Each simulation is harmless (see the top of `scripts/eval/runtime.sh`). Times are from just before the action to the alert being logged.

## Detection and response

| Simulation | Expected rule | Alert | ms to alert | ms alert → frozen | Work done before frozen | Children frozen |
|---|---|---|---|---|---|---|
| Pasted base64 into zsh | `base64-to-shell` | yes | 196 | 9 | stopped at 5410 | n/a |
| Child started before the alert | `base64-to-shell` | yes | 148 | 5 | - | yes (state T+) |
| dscl -authonly password check | `password-check` | yes | 128 | - | - | - |
| Hidden .com.apple folder | `fake-apple-folder` | yes | 245 | - | - | - |
| New launch agent written | `new-launch-item` | yes | 146 | - | - | - |
| Quarantine flag removed | `quarantine-removed` | yes | 47 | - | - | - |
| Ad-hoc program from hidden folder | `exec-from-hidden-or-temp` | yes | 113 | - | - | - |

*Work done before frozen* is the counter a busy loop reached before it stopped: each step is one shell
arithmetic operation plus one small file write.

## Overhead (macx / eslogger)

| Period | CPU | Peak memory |
|---|---|---|
| Idle (15 s) | 0.2% / 0.4% | 19 MB / 7 MB |
| During simulations | 1.5% / 0.6% (peak 5.5% / 1.9%) | 41 MB / 7 MB |

## eslogger benchmark (same file load: repeatedly reading 200 small files for 20 s)

| Events | eslogger CPU | Peak memory | Events per second |
|---|---|---|---|
| macx events (exec, create, rename, deleteextattr, btm_launch_item_add) | 5.5% (peak 6.6%) | 8 MB | 302 |
| the same plus open | 93.6% (peak 100.1%) | 706 MB | 10481 |

16 log records so far. `open` is left out of `macx watch` because of the difference above.

## Everything logged during the run

16 log records: base64-to-shell ×4, frozen ×4, password-check ×2, quarantine-strip ×2, fake-apple-folder ×1, new-launch-item ×1, quarantine-removed ×1, exec-from-hidden-or-temp ×1. Anything here that isn't a simulation is a false positive from normal background activity.
