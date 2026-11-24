# Runtime evaluation: macx watch --suspend

- Date: 2026-11-24 · macx 0.1.0 · commit c66a330 · macOS 27.0.1 (arm64)
- Each simulation is harmless (see the top of `scripts/eval/runtime.sh`). Times are from just before the action to the alert being logged.

## Detection and response

| Simulation | Expected rule | Alert | ms to alert | ms alert → frozen | Work done before frozen | Children frozen |
|---|---|---|---|---|---|---|
| Pasted base64 into zsh | `base64-to-shell` | yes | 257 | 6 | stopped at 9441 | n/a |
| Child started before the alert | `base64-to-shell` | yes | 174 | 5 | - | yes (state TN) |
| dscl -authonly password check | `password-check` | yes | 148 | - | - | - |
| Hidden .com.apple folder | `fake-apple-folder` | yes | 199 | - | - | - |
| New launch agent written | `new-launch-item` | yes | 31 | - | - | - |
| Quarantine flag removed | `quarantine-removed` | yes | 66 | - | - | - |
| Ad-hoc program from hidden folder | `exec-from-hidden-or-temp` | yes | 164 | - | - | - |

*Work done before frozen* is the counter a busy loop reached before it stopped: each step is one shell
arithmetic operation plus one small file write.

## Overhead (macx / eslogger)

| Period | CPU | Peak memory |
|---|---|---|
| Idle (15 s) | 0.5% / 0.1% | 16 MB / 7 MB |
| During simulations | 2.7% / 0.8% (peak 8.3% / 2.5%) | 30 MB / 8 MB |

## eslogger benchmark (same file load: repeatedly reading 200 small files for 20 s)

| Events | eslogger CPU | Peak memory | Events per second |
|---|---|---|---|
| macx events (exec, create, rename, deleteextattr, btm_launch_item_add) | 5.9% (peak 7.6%) | 8 MB | 226 |
| the same plus open | 87.8% (peak 99.4%) | 286 MB | 6831 |

16 log records so far. `open` is left out of `macx watch` because of the difference above.

## Everything logged during the run

16 log records: base64-to-shell ×4, frozen ×4, password-check ×2, quarantine-strip ×2, fake-apple-folder ×1, new-launch-item ×1, quarantine-removed ×1, exec-from-hidden-or-temp ×1. Anything here that isn't a simulation is a false positive from normal background activity.
