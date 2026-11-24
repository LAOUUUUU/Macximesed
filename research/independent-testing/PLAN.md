# Test plan: Macximesed against Atomic Red Team

Lao picked Atomic Red Team (ART) for independent testing. Until now every evaluation used attacks I wrote myself (`scripts/eval/static.sh`, `runtime.sh`), and those can share my blind spots. ART is Red Canary's public library of small tests, each mapped to a MITRE ATT&CK technique, written by other people. This plan is for Lao to approve before anything is built.

## Where it runs: GitHub's macOS runners, never a real Mac
Many ART tests really change the system: they replace the crontab, create users, dump the keychain, load launch daemons. They must not run on Lao's Mac, whose secrets were already stolen once.

A probe on 2026-11-24 (throwaway branch `claude/art-spike`) showed GitHub's hosted macOS runners can do it:

| | macos-26 | macos-15 |
|---|---|---|
| macOS | 26.7.2 | 15.8.2 |
| `sudo eslogger` starts | yes, 320 events in 12 s | yes, 145 events |
| passwordless sudo | yes | yes |
| PowerShell (for ART's runner) | 7.6.10 | 7.6.10 |
| SIP | **off** | **off** |

Each job is a fresh VM that is thrown away afterwards. The job gets no secrets and only `contents: read`.

**Caveats.**
- SIP is off on the runners, so tests that SIP would block (kexts, writing protected folders) may succeed there when they'd fail on a real Mac. The results say which those are.
- There's no one logged in at the screen, so AppleScript dialogs (`display dialog`, the password prompt) fail at once or time out.
- The runner is itself a VM, so the VM-check tests always "find" one.

## How
1. Build macx, then start `sudo macx watch --replay`-style logging: the real `macx watch` (no `--suspend`, so the tests aren't frozen halfway), writing alerts to a file.
2. Install Invoke-AtomicRedTeam and the atomics from a **pinned commit** (`a0e3f9bc69fe`, 2026-11-06), so results are comparable between runs and a change upstream can't run new code unannounced.
3. For each selected test: get its prerequisites, run it, wait 5 s, run its cleanup. Each alert is matched to the test running at the time.
4. After the persistence tests, also run `macx persist` and check that what they left is flagged. After the download and script tests, run `macx check` on the files they wrote.
5. **False alarms:** the same job does ordinary work with the watch running: `brew install` of a small formula, `swift build`, `git clone`, `curl -o` of a release file, `pip install`. Every alert there counts against us.
6. **Report:** `research/evaluation/art-results.md`, with one row per test: technique, test, what was expected, what macx said (rule, severity), and caught / missed / out of scope. Raw logs are kept as job artifacts, not committed.

The workflow (`.github/workflows/art.yml`) runs by hand from Actions, with an optional weekly run. It runs on macos-26 and macos-15.

## Which tests (about 60, from the 318 macOS tests)
Picked for what AMOS-style stealers do and what macx is built to catch. Expected results are written down **before** the run, so they can't be bent to fit the answer.

| Technique | Tests | macx should... |
|---|---|---|
| T1059.002 AppleScript | 1 | `osascript` from a shell: flag it |
| T1056.002 password prompt | 1, 3 | **critical** `password-prompt` (the core AMOS move) |
| T1555.001 keychain | 1, 2, 4 | flag reading or copying keychain files (`security dump-keychain`, `cat` of the keychain) |
| T1555.003 browser credentials | 2, 14, 18 | flag reads of Chrome Login Data and Safari cookies by a non-browser |
| T1140 / T1027 decode and run | 1, 3, 4, 5, 8, 10 | `base64-to-shell` for decode-and-run; decode to a file alone is low or none |
| T1105 download | 14, 31 | `download-to-shell` when piped into a shell; a plain download alone is none |
| T1553.001 Gatekeeper bypass | 1 | `quarantine-strip` (`xattr -d com.apple.quarantine`) |
| T1543.001 / .004 launch agent, daemon | all macOS (4) | `new-launch-item`; high or critical for a fake `com.apple.*` or a hidden program |
| T1547.015 login item | 2 | `new-background-item` |
| T1037.005 startup items / launch scripts | 1, 2, 3 | `macx persist` flags them |
| T1053.003 cron | 1, 2 | `macx persist` flags the new crontab |
| T1546.004 / .005 shell startup, traps | 1, 2 / 1, 3, 5 | `macx persist` flags shell startup changes |
| T1546.014 emond | 1 | `macx persist` (emond is gone on recent macOS: expected out of scope) |
| T1564.001 hidden files | 1, 2, 5, 6 | `exec-from-hidden-or-temp` when something runs from there |
| T1564.002 / T1136.001 hidden and new users | 1, 2 / 3 | `account-created` (the new watch event) |
| T1548.003 sudo caching | 1, 3, 5 | `macx persist` flags sudoers changes |
| T1574.006 DYLD injection | 3 | `dyld-injection` |
| T1497.001 VM checks | 4, 6, 7, 8 | `vm-check` |
| T1518.001 security software discovery | 3 | low or none (on its own it's harmless) |
| T1113 / T1115 screenshot, clipboard | 1, 2 / 3 | screenshot by a script: medium; clipboard commands run by a shell: `guard`'s area, not the watch |
| T1560.001 archive collected data | 5, 7, 13 | `ditto` of a sensitive folder: flag it (AMOS zips its loot) |
| T1222.002 / T1548.001 chmod, setuid | 3, 5 | setuid in a temp folder: flag it |
| T1569.001 launchctl | 1 | `new-launch-item` |

**Left out:** manual tests (Chrome extension in developer mode, Firefox, plist editing, logon scripts), tests that download third-party tools (LaZagne), kext loading (meaningless with SIP off), and the cloud-credential `find` tests (T1552.001), which only list files. Those can be added later.

## The privacy-grant alert (task 5)
It has never been seen working on real data, because the Screen Recording capture on Lao's Mac got no events. On the runner:
- `tccutil reset` for one service, and a grant through the TCC framework as root (allowed with SIP off), each with eslogger `tcc_modify` capturing the raw event. That shows the real field names (`service`, `update_type`, `right`, `reason`, `identity_type`) that the rule reads.
- A direct `sqlite3` write to TCC.db is run too, to show it **doesn't** produce an event. Malware with root and SIP off could do that, and the README should say so.

If the fields differ from Apple's header, the rule is fixed with the raw event as a test fixture, the same way the profile fix was made.

## What's built
- `.github/workflows/art.yml` and `scripts/eval/art.sh` (runs one test, matches alerts, writes a JSON line).
- `scripts/eval/art-tests.txt`: the test list with the expected result for each.
- `scripts/eval/art-report.py`: turns the JSON lines into `research/evaluation/art-results.md`.
- README *Evaluation* gets the headline numbers. Misses become STATUS items, fixed one by one, test first.

## Cost
About 15–25 minutes per OS per run on free public-repo runners. The 2 OS × ~60 tests fit within the job's 60-minute limit.

## Done when
Both OSes run the whole list. Every test has a result and a written expectation. Misses are listed in STATUS, and false alarms from the benign workload are counted.
