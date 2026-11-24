# External research: verbose/debug logging and a user-previewed bug report for macx
**Date:** 2026-11-24

Question: what is the best current way to add levelled, `--verbose`-controlled logging to a Swift 6
macOS tool (one `macx` binary: CLI, SwiftUI/AppKit app, and a root launchd daemon) so that the logs
can later be collected into a bug report the user previews and sends?

Every source below was opened on 2026-11-24. Apple documentation pages carry no publish date (they
show only a rolling "(c) 2026" footer). For those, "undated, read 2026-11-24" means the live page as
read today.

---

## 1. Apple unified logging from Swift (`os.Logger`)

### Levels and what persists by default
- Apple's level table ("Generating Log Messages from Your Code"):
  | Level | Persisted to disk by default |
  |---|---|
  | Debug | **No** |
  | Info | **Only when collected with the `log` tool** |
  | Notice (Default) | Yes, up to a storage limit |
  | Error | Yes, up to a storage limit |
  | Fault | Yes, up to a storage limit |

  "Normally, the system stores debug and info messages only in memory ... When that data store
  exceeds a predefined size, the system purges old messages."
  (https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)
- WWDC20 "Explore logging in Swift": "Debug level messages are not persisted, which means they cannot
  be retrieved after the app has completed execution." It also says error and fault entries are
  typically kept for a few days, longer than notice (https://developer.apple.com/videos/play/wwdc2020/10168/).
- `Logger` methods are `debug`, `trace`, `info`, `notice`, `log`, `warning`, `error`, `critical`,
  `fault`, and `log(level:)`. Apple's docs say `warning(_:)` "is functionally equivalent to the
  `error(_:)` method" and `critical(_:)` "is functionally equivalent to the `fault(_:)` method". So
  there are only five real `OSLogType`s: debug, info, default (notice), error, fault.
  (https://developer.apple.com/documentation/os/logger, .../logger/warning(_:), .../logger/critical(_:))
- Info entries live in memory buffers and get purged. A DTS answer (Jan 2025) on making them always
  persist says to scope any config change to one subsystem/category, and adds that "the contents of the
  system log is not an API" (https://developer.apple.com/forums/thread/773367).
- Persistence can be changed per subsystem, but **only as root**: `sudo log config --mode "level:debug"
  --subsystem <id>` (`--mode` also accepts `persist:{off|default|info|debug}`), or a plist at
  `/Library/Preferences/Logging/Subsystems/<subsystem>.plist` with `Level` -> `Enable` / `Persist` keys
  (https://developer.apple.com/documentation/os/customizing-logging-behavior-while-debugging,
  https://ss64.com/mac/log.html). Quinn (DTS) lists four ways to customise: an Apple profile, an
  `OSLogPreferences` key in the app's Info.plist, `log config` (macOS only), or a custom
  `com.apple.system.logging` profile (https://developer.apple.com/forums/thread/705868).

### Privacy redaction
- Default: "the system doesn't redact integer, floating-point and Boolean values, but it does redact
  the contents of dynamic strings and complex dynamic objects." Use `privacy: .public` to show a value,
  `.private` to hide it explicitly, and `.private(mask: .hash)` for a per-process hash you can correlate
  (https://developer.apple.com/documentation/os/generating-log-messages-from-your-code,
  https://developer.apple.com/documentation/os/logger).
- `OSLogPrivacy` options are `.auto` (default), `.public`, `.private`, `.sensitive` (documented as
  "behaves identically to the private option"), and the mask variants
  (https://developer.apple.com/documentation/os/oslogprivacy, .../oslogprivacy/sensitive).
- Redacted values show as `<private>`. Under Xcode, `OS_ACTIVITY_DT_MODE` un-redacts them. Enabling
  private data system-wide is possible (`Enable-Private-Data` via `OSLogPreferences` or a profile), but
  Quinn warns: "Do not enable the recording of private data on a system you care about"
  (https://developer.apple.com/forums/thread/705810).
- When an app reads its own entries back through `OSLogStore`, `composedMessage` is redacted the same
  way in normal (non-Xcode) runs. It only looked unredacted when launched from Xcode (Apple Developer
  Tools engineer, Nov 2023: https://developer.apple.com/forums/thread/741284).

### Performance
- WWDC20: messages are not turned into strings when logged. Formatting is deferred until the entry is
  displayed. For discarded debug messages "the code that creates the messages is not even executed".
  "The fault level is the slowest, and the debug level is the most performant."
  (https://developer.apple.com/videos/play/wwdc2020/10168/)
- Apple docs: "Debug logs have very low overhead ... Faults and other severe messages incur more
  overhead." (generating-log-messages page)
- Quinn: logging is fast enough to leave in release builds. "The more you log, the shorter the log
  window" (https://developer.apple.com/forums/thread/705868). Wrapping `Logger` behind your own API
  costs "both performance and critical features", because the system stores only the Mach-O UUID and
  the log-point offset, not strings (Aug 2023, https://developer.apple.com/forums/thread/736079).

### New or changed in macOS 26 / 27
- **macOS 26 (NSLog):** "Dynamic string data in format arguments for `NSLog` will be redacted to
  `<private>` in the Unified Logging System ... will not impact the Xcode console or `NSLog`'s `stdout`
  output. If you wish to log un-redacted data ... please use the 'os_log' or 'Logger' interfaces."
  (137129180, https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
- **macOS 26.4 (new Logger API):** `Logger.isEnabled(type:)` and `Logger.disabled` are available from
  macOS 26.4 only, so they need `#available(macOS 26.4, *)` on a macOS 15 minimum
  (https://developer.apple.com/documentation/os/logger/isenabled(type:),
  https://developer.apple.com/documentation/os/logger/disabled).
- **macOS 27 (archive format):** "Unified Logging System archives generated on 27.0 releases cannot be
  read on macOS 26.1 or earlier due to an updated archive format. macOS 26.2 or later is required to
  read these archives." (160567675,
  https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
- I found no new WWDC25/WWDC26 logging session and no other OSLog change in the macOS 27 notes.

---

## 2. Reading logs back (`OSLogStore`, `log show`)

- **`OSLogStore(scope: .currentProcessIdentifier)`** covers only the current process. Quinn (Nov 2023):
  "It's tied to your process ID ... terminated, and then relaunched, it'll have a different process ID."
  So a CLI can never see its own previous runs this way (https://developer.apple.com/forums/thread/691093).
  Known bugs with this scope: `.reverse` is ignored, and `getEntries(with:at:matching:)` ignores the
  position argument (https://developer.apple.com/forums/thread/705868).
- **Earlier runs on macOS:** Quinn (Sep 2021): "open the `.system` scope — or, on systems prior to macOS
  12 beta, by calling `OSLogStore.local()` — and then running a query for your process name. IIRC this
  only works if you're running as an admin user." (https://developer.apple.com/forums/thread/691093).
  `.system` is macOS 12+ (https://developer.apple.com/tutorials/data/documentation/oslog/oslogstore/scope.md).
- **Entitlement:** Apple's `local()` page says "The caller must be run by an admin account and have the
  `com.apple.logging.local-store` entitlement" (https://developer.apple.com/documentation/oslog/oslogstore/local()).
  Per Michael Tsai's Dec 2021 summary of Quinn, third parties cannot get that entitlement, and an
  admin-user, non-sandboxed process doesn't need it. Sandboxed apps get "Connection to logd failed"
  and are limited to `.currentProcessIdentifier` (https://mjtsai.com/blog/2021/12/10/oslogstore-on-monterey).
  Quinn (Jan 2024): there is no way to give a sandboxed app the full system log
  (https://developer.apple.com/forums/thread/744806).
- **Standard (non-admin) users:** since 10.12.4, a normal user's Console and `log show` return *empty*
  results, with no error (Eclectic Light, 2017-04-14,
  https://eclecticlight.co/2017/04/14/sierras-log-is-now-locked-away-from-normal-users/). Feb 2026: the
  `log` tool "doesn't require root privileges or require admin authorization" but must be run by a user
  with admin rights (Rich Trouton quoted at https://mjtsai.com/blog/?p=50928). Log-reading apps still
  gate on "Is the current user an admin user?" (Eclectic Light, 2025-12-15,
  https://eclecticlight.co/2025/12/15/why-cant-my-mac-get-log-entries-or-find-xprotect-scans/).
- **Can a user process read the root daemon's entries?** Admin users can read the whole store, whichever
  process wrote it, so yes for admins. Standard users can't read the store at all. `<private>` values
  stay redacted for everyone unless private data is enabled.
- **Can the root daemon read its own earlier entries?** Probably, via `.system` or `local()`, since the
  gate is "admin user" and root is not sandboxed. **Not confirmed by any source**; test it.
- **Debug/info from earlier runs are gone anyway.** They were never persisted (section 1). An
  `OSLogStore`-based report holds only notice/error/fault unless the subsystem's persist mode was raised
  beforehand.
- **Exporting:** there is no API to write a `.logarchive` from an `OSLogStore` (Quinn, Mar 2023,
  https://developer.apple.com/forums/thread/725886). `log collect` is run with `sudo`
  (`sudo log collect --last 5m`), and sysdiagnose includes a system-log snapshot
  (https://developer.apple.com/forums/thread/705868). `log show --predicate 'subsystem == "..."'` can add
  `--info --debug`, `--last 1h`, `--style json|ndjson` and `--source` (https://ss64.com/mac/log.html).
- **Performance of reads:** Eclectic Light suggests capping enumeration at about 1,000 to 10,000 entries "or
  your code might blow up" (2024-07-15,
  https://eclecticlight.co/2024/07/15/writing-a-third-generation-log-browser-using-swiftui-1-getting-log-entries/).

---

## 3. The alternative: own rotating file log, or swift-log

### swift-log (apple/swift-log), current state
- Latest release is **1.17.2 (17 Nov 2026)**. Swift Package Index shows "Last updated on 17 Nov 2026".
  1.17.0 (4 Nov) added opt-in millisecond timestamps to `StreamLogHandler`
  (https://github.com/apple/swift-log/releases).
- **1.16.0 (7 Oct 2026) raised the minimum Swift tools version to 6.2**. The `main` Package.swift says
  `swift-tools-version:6.2.3` (https://github.com/apple/swift-log/releases/tag/1.16.0,
  https://raw.githubusercontent.com/apple/swift-log/main/Package.swift).
- Products are `Logging` and `InMemoryLogging`, with **no file handler**. A custom handler implements
  `log(event:)`, `logLevel`, `metadata` and a metadata subscript, and must be a struct
  (https://raw.githubusercontent.com/apple/swift-log/main/Sources/Logging/LogHandler.swift).
  File rotation needs a third-party backend such as Puppy (`FileRotationLogger` with `maxFileSize` /
  `maxArchivedFilesCount`, `PuppyLogHandler`, Swift 6.2+;
  https://raw.githubusercontent.com/sushichop/Puppy/main/README.md).
- Levels are trace, debug, info, notice, warning, error, critical. The guidance is that libraries log at
  trace/debug and "the executable target ... is responsible for configuring `LogHandler`s and log levels"
  (https://swift.org/documentation/server/guides/libraries/log-levels.html).
- **Apple's view (Quinn, Sep 2025):** for software "exclusively for Apple platforms" use the system log
  API. The swift-log OSLog back end "is less than ideal": everything is logged as public and as a single
  string (`os_log("%{public}@", ...)`), which "defeats the optimisations done by the system log"
  (https://developer.apple.com/forums/thread/801625). The same incompatibility (no privacy interpolation
  in swift-log) was noted on Swift Forums in Aug 2021
  (https://forums.swift.org/t/state-of-the-logging-swift-log-package/50943).

### Own rotating file vs os.Logger, for "hand the user an exact, readable report"
| | Own rotating file (~100 to 200 lines) | os.Logger only | swift-log + file backend |
|---|---|---|---|
| Debug/verbose output survives to the next run | Yes | No (debug never persisted, info purged) unless root changes the config | Yes (file backend) |
| Readable by a standard user | Yes (own files; daemon file if mode allows) | No (needs admin) | Yes |
| What the user previews = what is sent | Yes, plain text | Needs `log show`/OSLogStore and admin; `<private>` holes | Yes |
| Redaction | Your code (deterministic, testable) | System `<private>` (all-or-nothing per value) | Your code |
| Console.app / sysdiagnose visibility | No | Yes | Only via a lossy bridge |
| Cost per call | String formatting always paid (guard with a level check) | Very low, deferred | Like a file log plus handler indirection |
| Size control | Your rotation cap | System-managed, shared store | Backend's rotation |
| Dependencies / toolchain | None | None (system) | 2 packages; Swift tools 6.2/6.2.3 |

---

## 4. Real-world implementations (code or docs opened 2026-11-24)

1. **Ghostty** (Swift macOS app with a Zig core). Logs to the macOS unified log by default. The `GHOSTTY_LOG`
   env var picks destinations (`stderr`, `macos`, `true`/`false`, `no-` prefix). Debug logs go to stderr only
   in Debug builds. Bug reports: the triage template asks users to paste
   `sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'` output
   (https://raw.githubusercontent.com/ghostty-org/ghostty/main/HACKING.md,
   https://raw.githubusercontent.com/ghostty-org/ghostty/main/.github/DISCUSSION_TEMPLATE/issue-triage.yml).
2. **IINA** (Swift media player). Its own `Logger` writes plain text to `iina.log` in a per-launch folder
   `~/Library/Logs/<bundle id>/<timestamp>_<token>/`. Levels are verbose/debug/warning/error, with the minimum
   level from a preference. It is **opt-in** (Advanced settings + "enable logging", off by default), keeps an
   in-memory buffer plus a notification for a log viewer, doesn't use `os_log`, and has no rotation or cleanup
   in the code (https://raw.githubusercontent.com/iina/iina/develop/iina/Logger.swift).
3. **Ice** (Swift menu-bar manager). A thin `os.Logger` wrapper with subsystem = bundle id and
   category per component. **Every message is `privacy: .public`**
   (https://raw.githubusercontent.com/jordanbaird/Ice/main/Ice/Utilities/Logging.swift).
4. **Pareto Security** (Swift macOS security auditor, closest in spirit to macx). `os_log` with subsystem
   `niteo.co.Pareto` and categories App/Check/API, all `%{public}@`. Sensitive data is handled by hand:
   auth/cookie headers become `<redacted>` and bodies are truncated at 4000 chars. `paretosecurity://logs`
   reads the **last hour via `OSLogStore(scope: .currentProcessIdentifier)`** and copies it to the clipboard.
   Non-admin users get an alert that logs can't be copied, and the docs send them to Console.app streaming.
   "Report bug" opens a web form URL that carries the hardware, macOS and app versions
   (https://raw.githubusercontent.com/ParetoSecurity/pareto-mac/main/Pareto/Log.swift, .../AppInfo.swift,
   .../AppHandlers.swift, https://paretosecurity.com/docs/mac/logs).
5. **Tailscale macOS client** (GUI is closed source; daemon/CLI is open). "Report an Issue" writes a
   bug-report ID into the client logs, which support looks up. "Export Configuration Report" saves a
   `tar.gz` and opens it in Finder so the user can review it first. The CLI has `tailscale bugreport
   --diagnose` / `--record` (before/after IDs around a repro). No report is generated if client logging is
   off (https://tailscale.com/docs/account/bug-report, validated 2026-01-05;
   https://tailscale.com/docs/reference/debug-menu).
6. **OpenClaw macOS companion app** (Swift). swift-log goes to unified logging, plus an **opt-in rolling
   JSONL file** `~/Library/Logs/OpenClaw/diagnostics.jsonl` that rotates at 5 MB and keeps 5 backups. A
   Verbosity picker applies live without a restart. Redaction is done in-app before any sink sees the
   message, and a script exports recent unified-log entries as JSON. The docs tell users to review the file
   before sharing (https://docs.openclaw.ai/platforms/mac/logging).

Patterns: (a) system log plus "run this `log stream` command" (Ghostty), which needs admin/sudo and only
catches what happens while streaming. (b) Own file log, opt-in or levelled (IINA, OpenClaw). (c) Read your
own entries back with `OSLogStore` (Pareto), which works only for the current run and only for admins.
(d) A server-side ID plus a local exportable report the user reviews (Tailscale).

---

## Current best practices
- Use `os.Logger` directly (not wrapped) when the goal is Console/sysdiagnose diagnostics on Apple-only
  software. Mark non-sensitive values `.public` explicitly, since strings are `<private>` by default.
- Don't rely on debug/info entries existing after the fact. Treat the unified log as live-stream and
  notice-and-up only, unless you change the subsystem config as root.
- When users must hand over logs without admin rights, keep your own file log. Rotate it by size, keep it
  plain text or JSONL, and redact in your own code.
- Let users review before sending (Tailscale's exported report, OpenClaw's "review before sharing").
- Gate macOS 26.4-only `Logger` APIs with `#available`. Don't adopt `NSLog`, which macOS 26 redacts in
  the unified log.

## Breaking changes / gotchas
- `.currentProcessIdentifier` covers this run only, and has the `.reverse` and position bugs.
- `.system`/`local()` need an admin user. A standard user gets empty results with no error.
- The `com.apple.logging.local-store` entitlement is documented but not obtainable by third parties.
  Admin, non-sandboxed processes don't need it.
- macOS 27 `.logarchive` files can't be opened on macOS 26.1 or earlier.
- swift-log >= 1.16.0 needs Swift tools 6.2 (`main` declares 6.2.3). A macOS 15 build host must use an
  Xcode that ships Swift 6.2+, or pin `< 1.16.0`.
- The swift-log OSLog bridge logs everything public and as one string.
- `log config` and Subsystems plists are system-wide and root-only. Scope them to one subsystem and
  revert them.
- A launchd `StandardOutPath` file is never rotated by launchd. newsyslog can rotate files listed in
  `newsyslog.conf` (size in KB, count, `N` = no process to signal), but the daemon keeps writing to the
  old descriptor (inference from the man page, see Unverified)
  (https://keith.github.io/xcode-man-pages/newsyslog.conf.5.html).

---

## What this means for macx

**Recommendation: write a small in-house logger with no new dependency. Make a size-capped plain-text
file per role the primary record, and mirror notice-and-above to `os.Logger` as a bonus. Build the bug
report from macx's own files, never from `OSLogStore`.**

Why:
1. The report must work for standard users and contain the verbose lines from the run that went wrong.
   Unified logging gives neither: debug is never persisted, info is purged, reading earlier runs needs
   admin, and dynamic strings come back as `<private>`.
2. macx is a single-platform executable, not a cross-platform library. swift-log brings no file handler,
   so you would still write the file sink or add a second package (Puppy). Current versions need Swift
   tools 6.2/6.2.3, and Apple's own DTS advice for Apple-only software is the system log, not swift-log.
   The file sink and rotation are roughly the same code either way.
3. "Preview exactly what is sent" is easiest when the source is plain text macx wrote and redacted itself.

Shape (suggested, for the brief, not a spec):
- **Levels:** `error`, `warning`, `info` (default), `debug`, `trace`. Mirror swift-log's names so a later
  switch is cheap. `--verbose`/`-v` sets debug, `-vv` sets trace, and an env var such as `MACX_LOG=debug`
  overrides both. The launchd daemon can't take a CLI flag per run, so give it a persisted switch in the
  style of the existing `macx daemon downloads on|off`. Do the level check before building the string, by
  passing the message as an autoclosure.
- **Sinks:** one file per role to avoid rotation races between processes:
  `~/Library/Logs/Macximesed/{cli,app}.log` for the user side and `/Library/Logs/Macximesed/daemon.log`
  written by the logger itself, with launchd stdout/stderr kept only as a crash catch-all. Rotate at about
  1 MB and keep 2 old files. Each line holds an ISO-8601 UTC time, level, role, pid, category and message.
  Use one serial writer per process.
- **os.Logger mirror:** notice/warning/error only, under the app's subsystem, so admins and sysdiagnose
  also see them. The line is already scrubbed, so `privacy: .public` is acceptable at this low volume.
  This trades the deferred-formatting optimisation for one code path, the same choice Ice and Pareto make.
- **Never log** file contents, secrets or full environment. Write home-folder paths as `~` at write time.
- **Report builder** (`macx report` plus an app sheet): versions (app, macOS build, arch), daemon and
  permission status, the tails of the three logs, the last N `watch.jsonl` alerts, and (only if the user
  is an admin) an optional `log show --predicate 'subsystem == "..."' --last 1h --style ndjson` excerpt.
  Redact again at build time (username, full name, host/computer name, serial/hardware UUID, emails, IPs)
  and show the count of replacements. Show the exact text in a read-only preview with per-section
  checkboxes. Actions are "Copy", "Save...", and "Open issue" with a prefilled body. Nothing uploads
  without an explicit click.
- **Tests first:** level filtering, rotation at the cap, redaction rules and report assembly are pure
  functions and easy to TDD.

---

## Unverified
- Whether a **root launchd daemon** can open `OSLogStore(scope: .system)` / `local()` without the
  entitlement. Sources only say "admin user"; test on macOS 15, 26 and 27.
- Whether `OSLogStore(scope: .currentProcessIdentifier)` works for a **standard (non-admin)** user on
  macOS. Pareto's code warns non-admins it can't copy logs, but no Apple source states this.
- Whether a launchd `StandardOutPath` file keeps receiving writes after newsyslog renames it. Inferred
  from fd semantics, not confirmed by a source.
- That `print()` to a non-TTY stdout (the daemon's log file) is block-buffered rather than line-buffered,
  so lines can lag or be lost on a crash. This is general stdio behaviour, not checked against a source
  here.
- Whether SwiftPM on an older toolchain silently resolves an older swift-log tag or fails when the
  newest tags need tools 6.2. Not checked.
- How `Logger.trace(_:)` maps to an `OSLogType`. The docs state the warning-to-error and critical-to-fault
  mappings only.
- The release years for swift-log 1.16.x and 1.17.x are inferred: GitHub omits the year for the current
  year, and Swift Package Index shows "17 Nov 2026".

## Sources
| URL | What it provided | Date |
|---|---|---|
| https://developer.apple.com/documentation/os/generating-log-messages-from-your-code | Level/persistence table, default redaction rules, overhead | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/logger | Logger methods, default redaction of strings | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/logger/warning(_:) | warning = error | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/logger/critical(_:) | critical = fault | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/logger/isenabled(type:) | New API, macOS 26.4+ | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/logger/disabled | New API, macOS 26.4+ | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/oslogprivacy | Privacy options | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/oslogprivacy/sensitive | sensitive = private | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/oslogtype | The 5 log types | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/os/customizing-logging-behavior-while-debugging | `log config` as root, Subsystems plist, Enable/Persist | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/oslog/oslogstore | OSLogStore initialisers, scope | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/oslog/oslogstore/local() | Admin + `com.apple.logging.local-store` | undated, read 2026-11-24 |
| https://developer.apple.com/tutorials/data/documentation/oslog/oslogstore/scope.md | `.currentProcessIdentifier`, `.system` (macOS 12+) | undated, read 2026-11-24 |
| https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes | NSLog redaction (137129180) | macOS 26 notes, read 2026-11-24 |
| https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes | ULS archive format change (160567675) | macOS 27 notes, read 2026-11-24 |
| https://developer.apple.com/videos/play/wwdc2020/10168/ | Logger performance, privacy defaults, persistence | WWDC20 (Jun 2020) |
| https://developer.apple.com/videos/play/wwdc2023/10226/ | "print ... should rarely be used"; OSLogStore for field diagnostics | WWDC23 (Jun 2023) |
| https://developer.apple.com/forums/thread/705868 | Quinn, "Your Friend the System Log" | 2022-05-12, rev. 2026-05-11 |
| https://developer.apple.com/forums/thread/705810 | Quinn, recording private data | 2022-05-12, rev. 2023-06-10 |
| https://developer.apple.com/forums/thread/691093 | Earlier runs: `.system` scope, admin; PID meaning | Sep 2021, Nov 2023 |
| https://developer.apple.com/forums/thread/744806 | No sandboxed access to full log | Jan 2024 |
| https://developer.apple.com/forums/thread/736079 | Wrapping costs performance; "write or acquire your own" | Aug 2023 |
| https://developer.apple.com/forums/thread/801625 | Quinn: os.log for Apple-only; swift-log OSLog backend flaws | Sep 2025 |
| https://developer.apple.com/forums/thread/773367 | Info not reliably persisted; scope config changes | Jan 2025, Oct 2025 |
| https://developer.apple.com/forums/thread/741284 | composedMessage redaction outside Xcode | Nov 2023 |
| https://developer.apple.com/forums/thread/725886 | No API to create .logarchive | Mar 2023 |
| https://developer.apple.com/forums/thread/650843 | OSLogStore history; `log collect` | Jun 2020, Mar 2021 |
| https://developer.apple.com/forums/thread/815354 | OSLogStore current-process limits; Feedback Assistant sysdiagnose | Feb 2026 |
| https://mjtsai.com/blog/2021/12/10/oslogstore-on-monterey | Entitlement unobtainable, admin suffices, sandbox limits | 2021-12-10 |
| https://mjtsai.com/blog/?p=50928 | `log` tool needs an admin-rights user, not root | 2026-02-05 |
| https://eclecticlight.co/2017/04/14/sierras-log-is-now-locked-away-from-normal-users/ | Standard users get empty logs | 2017-04-14 |
| https://eclecticlight.co/2024/07/15/writing-a-third-generation-log-browser-using-swiftui-1-getting-log-entries/ | OSLogStore.local() usage, cap entries | 2024-07-15 |
| https://eclecticlight.co/2025/12/15/why-cant-my-mac-get-log-entries-or-find-xprotect-scans/ | Log apps still gate on admin | 2025-12-15 |
| https://forum.latenightsw.com/t/nslog-neutered-in-the-unified-log-in-macos-26-tahoe-options/5664 | Field report of macOS 26 NSLog redaction | 2026-02-25 |
| https://ss64.com/mac/log.html | `log` show/collect/config options | undated, read 2026-11-24 |
| https://keith.github.io/xcode-man-pages/newsyslog.conf.5.html | newsyslog.conf fields | undated, read 2026-11-24 |
| https://github.com/apple/swift-log/releases | 1.17.2 latest, recent changes | 2026-11-17 (inferred year) |
| https://github.com/apple/swift-log/releases/tag/1.16.0 | Min tools 6.2 | 2026-10-07 (inferred year) |
| https://raw.githubusercontent.com/apple/swift-log/main/Package.swift | tools 6.2.3, products | main, read 2026-11-24 |
| https://raw.githubusercontent.com/apple/swift-log/main/Sources/Logging/LogHandler.swift | Custom handler requirements | main, read 2026-11-24 |
| https://swiftpackageindex.com/apple/swift-log/1.17.2/documentation/logging | "Last updated on 17 Nov 2026", 1.17.2 latest | read 2026-11-24 |
| https://swift.org/documentation/server/guides/libraries/log-levels.html | swift-log levels and guidance | undated, read 2026-11-24 |
| https://forums.swift.org/t/state-of-the-logging-swift-log-package/50943 | swift-log vs os.Logger privacy incompatibility | Aug 2021 |
| https://raw.githubusercontent.com/sushichop/Puppy/main/README.md | File rotation backend for swift-log | undated, read 2026-11-24 |
| https://raw.githubusercontent.com/ghostty-org/ghostty/main/HACKING.md | Ghostty logging destinations, GHOSTTY_LOG | main, read 2026-11-24 |
| https://raw.githubusercontent.com/ghostty-org/ghostty/main/.github/DISCUSSION_TEMPLATE/issue-triage.yml | Ghostty asks for `log stream` output | main, read 2026-11-24 |
| https://raw.githubusercontent.com/iina/iina/develop/iina/Logger.swift | IINA per-session file log | develop, read 2026-11-24 |
| https://raw.githubusercontent.com/jordanbaird/Ice/main/Ice/Utilities/Logging.swift | Ice os.Logger wrapper, all public | main, read 2026-11-24 |
| https://raw.githubusercontent.com/ParetoSecurity/pareto-mac/main/README.md | `paretosecurity://logs` helper | main, read 2026-11-24 |
| https://raw.githubusercontent.com/ParetoSecurity/pareto-mac/main/Pareto/Log.swift | os_log categories, manual redaction | main, read 2026-11-24 |
| https://raw.githubusercontent.com/ParetoSecurity/pareto-mac/main/Pareto/AppInfo.swift | OSLogStore last-hour read, bug report URL | main, read 2026-11-24 |
| https://raw.githubusercontent.com/ParetoSecurity/pareto-mac/main/Pareto/AppHandlers.swift | Copy logs to clipboard, non-admin alert | main, read 2026-11-24 |
| https://paretosecurity.com/docs/mac/logs | Console fallback for non-admins | undated, read 2026-11-24 |
| https://tailscale.com/docs/account/bug-report | Bug-report ID, exported config report | validated 2026-01-05 |
| https://tailscale.com/docs/reference/debug-menu | Option-click debug menu | undated, read 2026-11-24 |
| https://docs.openclaw.ai/platforms/mac/logging | swift-log + rolling JSONL 5 MB x 5, verbosity picker | undated, read 2026-11-24 |
