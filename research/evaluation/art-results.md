# Atomic Red Team results

Independent testing of the live watch and `macx persist` against Red Canary's public Atomic Red Team tests (atomics pinned at `a0e3f9bc69fe`, Invoke-AtomicRedTeam 2.3.0). The plan is in [research/independent-testing/PLAN.md](../independent-testing/PLAN.md). It runs on GitHub's throwaway macOS runners (`.github/workflows/art.yml`, `scripts/eval/art.sh`), never on a real Mac. What each test should produce was written in `scripts/eval/art-tests.txt` **before** the first run.

## Latest (run 6, 2026-11-25)

| | macOS 26.7.2 | macOS 15.8.2 |
|---|---|---|
| Attacks caught | **30 of 33** | **30 of 33** |
| False alarms (16 tests that should stay quiet, including ordinary work: brew, git, curl, pip, swift build) | **0** | **0** |
| Informational, not scored | 11 | 11 |

One of the 30 was caught by a different rule than predicted. T1027 (decode into `/tmp/art.sh`, then run it) was expected as `exec-from-hidden-or-temp` and came as critical `base64-to-shell`. The report lists that separately (*caught, other rule*) instead of changing the expectation afterwards.

### Still missed
| Test | Why |
|---|---|
| T1543.001 #2, emond client | emond is gone from current macOS. Written down as out of scope before the first run. |
| T1555.001 #2, `security find-certificate -a -p` | Exports public certificates, which aren't secrets. Left unflagged on purpose. |
| Privacy grant (`tcc_modify`) | Nothing produced the event on demand: `tccutil reset`, TCC.framework's private `TCCAccessSetForBundleId` (returns false, it needs an entitlement) and a direct `sqlite3` write to TCC.db (it bypasses tccd, so no event, and the README says so). The raw capture was complete: a marker event was in it. The rule did fire live in run 1, when macOS granted Screen Recording to the runner's agent during `screencapture`. |

### Left out, with evidence
- **T1574.006 #3 (DYLD_INSERT_LIBRARIES):** its library is injected into every child it starts, so it multiplied until the runner had no processes left (run 2, macOS 26: "fork: Resource temporarily unavailable").
- **T1053.003 #2 (`/etc/cron.*`) and T1548.003 #3 (sudoers via `sed -i`)** do nothing on macOS: the folders don't exist, and macOS `sed` rejects the GNU syntax ("unterminated substitute pattern"). They're informational now. macx's checks for both places are covered by unit tests with real file contents.

## From 9 to 30: what each run found

| Run | Caught | False alarms | What changed after it |
|---|---|---|---|
| 1 | 9 of 32 | 1 | Harness bugs (the test list stopped at 46; the user baseline never saved). Rule gaps fixed: Python/Perl/Ruby decode-and-run, `#!` scripts from `/tmp`, model-name VM checks, `launchctl submit`, keychain and browser-data reads by command, hidden files right in the home folder. False alarm fixed: `~/.rustup/.../rustc` was high, now low. |
| 2 | 13 of 36 (macOS 15) | 1 | macOS 26 crashed (the DYLD test). Found: `sudo macx persist` scanned root's home instead of the user's (fixed), and the root watch left a root-owned `~/Library/Application Support/Macximesed` on a fresh Mac, locking the user out (fixed). |
| 3 | 23 of 35 | 0 | All of run 1's rule fixes in. Remaining gaps: StartupItems, `/etc/sudoers`, `/etc/cron.*`, any change to shell startup files. |
| 4 | 29 of 35 | 0 | Those four added to `macx persist`. |
| 5 | 29 of 33 | 0 | Decode-into-a-file-and-run added; two tests marked as doing nothing on macOS. |
| 6 | **30 of 33** | **0** | The raw exec events of T1027 were captured and replayed locally (`macx watch --replay`): it had been caught all along, by another rule. Scoring now shows that. |

## How to run it
Actions > *Atomic Red Team* > Run workflow. It also runs every Monday, and whenever the harness changes on `dev`. The report is in the run's summary, and the logs, alert files and any raw captures (`ART_CAPTURE`) are artifacts kept for 30 days.
