# External research: anonymous bug and crash reports for macx
**Date:** 2026-11-24

Question: how should `macx` (one Swift 6 binary that is a CLI, the app inside Macximesed.app, and a root launchd daemon; macOS 15 minimum; public, so every built-in value is public) send anonymous bug and crash reports, with logs, to a maintainer who has no server and no paid Apple developer account?

Short answer: let macOS record the crashes. Build the report on the Mac and redact it there. Show the user the exact text and send only after they say yes. Encrypt it with HPKE to a maintainer public key that is built into the binary, then POST it to a small Cloudflare Worker. The Worker forwards the opaque blob to a Discord webhook (or to R2 or KV), and the webhook URL lives only as a Worker secret. Keep a local-only "save report to file" path as well. That path needs no network and no infrastructure, and it is how Ghostty already works.

---

## Key findings

### 1. Capturing crashes

**macOS already writes a crash report for every macx process.** You don't need code in the crash path.
- Apps and other processes in the per-user launchd context: ReportCrash runs as a LaunchAgent and "saves crash reports in the user's ~/Library/Logs/DiagnosticReports/ directory". Daemons and other privileged processes: ReportCrash runs as a LaunchDaemon and saves reports in `/Library/Logs/DiagnosticReports`, "where they are only readable by admin users" (ReportCrash(8), https://keith.github.io/xcode-man-pages/ReportCrash.8.html). This is an old man page. The two locations are confirmed for current macOS by Objective-See, 2024-08-13 (https://objective-see.org/blog/blog_0x7B.html). Console's guide says crash reports have the `.ips` extension, splits them into User and System reports, and says an admin can view all of them (https://support.apple.com/en-ae/guide/console/cnsl664be99a/1.1/mac/26).
  - What this means for macx: the CLI and the app (user context) crash into the user's folder. The root daemon crashes into `/Library/Logs/DiagnosticReports`, which the daemon (root) can read but a standard-user app cannot.
- **The `.ips` format.** "Starting with iOS 15 and macOS 12, apps that generate crash reports store the data as JSON in files with an `.ips` extension." The file holds two JSON objects. Line 1 is the IPS metadata (`name`, `bug_type`, `bundleID`, `build_version`, `incident_id`, `platform`, `timestamp`). The rest of the file is the crash body. Only parse it as a crash when `bug_type` is `"309"` (https://developer.apple.com/tutorials/data/documentation/xcode/interpreting-the-json-format-of-a-crash-report.md).
  - Privacy-relevant body fields: `crashReporterKey` (an "anonymized per-device identifier", identical across reports from one device), `incident`, `pid`/`parentPid`/`parentProc`, `procLaunch`/`captureTime`, `uptime`, `modelCode`, `asi` (app-specific log strings), `vmSummary`/`vmregioninfo`, `threadState` (registers).
  - For `procPath` and `usedImages[].path`, Apple says "macOS replaces user-identifable path components with placeholder values to protect privacy" (same page). The paths are partly pre-scrubbed, but the free-text fields are not.
- Apple says to "always look for and redact sensitive information" before sharing crash reports, and to prefer the Apple `.ips` over third-party reports, which "may omit necessary information" (https://developer.apple.com/tutorials/data/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs.md).
- To read reports on the maintainer side, macOS ships `/usr/bin/viewdiagnostic`, which renders `.ips` as the classic text. An Apple DTS engineer (Aug 2026) said it "was added in macOS 15" based on "some spelunking", not documentation (https://developer.apple.com/forums/thread/693681?answerId=902333022).

**MetricKit works on macOS, but not in the root daemon.**
- `MXCrashDiagnostic` is available on macOS 12.0 to 27.3 (https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic.md). "Diagnostic reports arrive immediately in iOS 15 and later, and macOS 12 and later." In macOS 27 a new Swift `MetricManager` delivers `MetricReport`/`DiagnosticReport` through async sequences, and the reports are `Codable` (https://developer.apple.com/documentation/metrickit.md, https://developer.apple.com/tutorials/data/documentation/metrickit/monitoring-app-performance-with-metrickit.md).
- User consent: in an iOS test (May 2025), Apple DTS saw crash diagnostics delivered even with "Share With App Developers" and "Share iPhone Analytics" turned off (https://developer.apple.com/forums/thread/784399). So MetricKit doesn't need the OS analytics opt-in. That doesn't mean you can upload without asking: DTS says to treat the data as potentially personal.
- Non-App-Store and CLI use:
  - A Command Line Tool target received crash diagnostics when run as the user, as root from a session, and as a user/gui-domain LaunchAgent. It got nothing as a **Launch Daemon** or a system-domain agent; CrashReport logged "`<bundle ID>` is not a MetricKit client". DTS said support beyond apps and app-like code needs an enhancement request (May 2023, https://developer.apple.com/forums/thread/729271).
  - In Mar–Apr 2026 DTS said "MetricKit definitely works on macOS". A Developer-ID LSUIElement host app got a diagnostic after `killall -ABRT`, but a system extension did not, because "The MetricKit 'daemon' is not actually a daemon but rather a launchd agent", so it only serves login sessions (https://developer.apple.com/forums/thread/821002). See also https://developer.apple.com/forums/thread/724698 (Feb 2023, system extensions).
  - Net result for macx: MetricKit could cover the app and maybe the CLI, never the root daemon. The `.ips` files cover all three.

**In-process crash reporters exist, but you don't need one.**
- KSCrash: latest stable 2.6.1, dated 30 Oct (year not shown; see Unverified). It catches "Mach exceptions, signals, C++/ObjC exceptions, main thread hangs". After 2.6.1 it ships "through Swift Package Manager only" (https://github.com/kstenerud/KSCrash/releases, https://github.com/kstenerud/KSCrash).
- PLCrashReporter: latest 1.12.2, dated 12 Nov, a one-line fix. It is SwiftPM-installable, supports "iOS 12, macOS 11.5, tvOS 12" minimum, and makes no maintenance statement (https://github.com/microsoft/plcrashreporter/releases, https://github.com/microsoft/plcrashreporter).
- sentry-cocoa embeds its own handler, SentryCrash. See section 2.
- Swift's runtime backtracer: "The backtracer is not active by default on macOS". On macOS 26+ `enable` defaults to `tty`. It can write JSON to a file (`format=json`, `output-to=`). Builds made outside Xcode need the `com.apple.security.get-task-allow` entitlement, which "will fail notarization" and is "strictly for debugging purposes only". It "cannot be enabled for setuid binaries" (https://github.com/swiftlang/swift/blob/main/docs/Backtracing.rst). Don't ship it.
- Simplest reliable option: no handler at all. On the next launch, scan the two DiagnosticReports folders for `.ips` files whose metadata `name` is `macx` (or whose `bundleID` matches the app) and that are newer than a stored watermark. A crashing process can't corrupt this capture, nothing runs in signal context, and no dependency enters a root daemon.

### 2. Where reports can go without a server

| Option | Cost (as of 2026-11) | Maintainer setup | What the public binary must contain | Abuse / spam exposure | Fit for macx |
|---|---|---|---|---|---|
| **Sentry SaaS** | Developer plan $0: "5k errors", 1 user, 1 GB attachments, 30-day lookback. No spend-cap feature on Developer. Data over quota "will be dropped… you'll lose monitoring for the remainder of the billing cycle" | Create the org, picking the US or EU (Frankfurt) region at creation; it "can't be changed". Then create a project and get the DSN | The DSN. Sentry says DSNs are "safe to keep public" because they "only allow submission of new events" | Anyone with the DSN can send events "with any content they choose". Mitigations: block IPs, rotate or revoke the DSN, set the DSN dynamically. A spammer can burn the 5k quota and blind you for the month | Works, but adds a large in-process C crash handler to a root daemon. Reports sit in plaintext at a third party. See the SDK notes below |
| **Self-hosted Sentry** | The software is free (FSL; it becomes Apache-2.0 after two years) | Needs ≥4 cores, 16 GB RAM + 16 GB swap, 20 GB disk, Docker 19.03.6+ / Compose 2.32.2+ | DSN | Same as SaaS | Not viable: no server |
| **TelemetryDeck** | Free tier 50,000 events/month for accounts created on or after 2026-07-01 (older accounts keep 100,000) | Account and app ID | App ID | Low value to spammers | Not a crash-log tool. `TelemetryDeck.errorOccurred(id:)` sends an error id, an optional message and a category (`thrownException`/`userInput`/`appState`). The docs mention no stack traces, logs or attachments, and warn that dynamic values such as `error.localizedDescription` or file paths "may send some user data" |
| **Cloudflare Worker** (recommended relay) | Workers Free: 100,000 requests/day (Error 1027 after that, resets at midnight UTC), 10 ms CPU per request, 128 MB memory, request body up to 100 MB on a Free zone, 64 env vars/secrets of 5 KB each. Workers Logs: 3-day retention on Free | `wrangler deploy` one Worker. `wrangler secret put DISCORD_WEBHOOK` (secrets "are not visible within Wrangler or Cloudflare dashboard after you define them"). Optionally a KV namespace or an R2 bucket | Endpoint URL and the HPKE **public** key. No secrets | The endpoint is public, so anyone can POST to it. Mitigations: the rate-limiting binding (`limit`/`period` of 10 or 60 s, keyed by any string; counts are "eventually consistent" and per Cloudflare location, so not strict) or one WAF rate-limit rule on a Free zone (10 s count and mitigation, IP-only, Path field). Also strict size and format checks in code | Best fit: free, nothing secret in the binary, you control every byte |
| ↳ storage: **Discord webhook** behind the Worker | Free | Create the webhook in a private channel and store its URL only as a Worker secret | Nothing | Spam ends up in the channel, but only at the Worker's rate limit. Discord's own limits: per-webhook buckets; honour `Retry-After`/`X-RateLimit-*`. 10,000 invalid (401/403/429) requests in 10 minutes means a temporary ban | `content` ≤2000 chars, ≤10 embeds, `files[n]` + `payload_json` for multipart. Default upload limit "20 MiB for all users" (the free limit went from 10 MB to 20 MB per the FAQ). Use `allowed_mentions` so report text can't ping anyone |
| ↳ storage: **KV** | Free: 100,000 reads/day, **1,000 writes/day**, 1 GB, values ≤25 MiB, `expirationTtl` ≥60 s | Namespace binding | Nothing | The write cap is a natural spam ceiling, but it also silently caps real reports | Fine for low volume, and TTL gives automatic retention |
| ↳ storage: **R2** | Free: 10 GB-month, 1 M Class A and 10 M Class B ops/month, free egress (Standard class only). Lifecycle rules can delete objects after N days | Bucket and lifecycle rule. A payment method may be required to enable R2 (unverified) | Nothing | Storage fills only up to the rate limit | Good if the maintainer wants files rather than chat messages |
| **Discord webhook built into the binary** | Free | — | The webhook URL, which is a credential | Severe. The token alone lets anyone execute the webhook, read, modify or delete it, and edit or delete its messages (inferred from the token endpoints; webhooks "do not require a bot user or authentication") | **Never do this** |
| **GitHub Issues** | Free | Issue template | Repo URL | No anonymous path. The REST "Create an issue" endpoint is for users with pull access (an authenticated user), and the prefilled-URL flow (`/issues/new?title=&body=&labels=&template=`) needs a signed-in user. URLs that are too long return `414` | Fine as an **optional** "post publicly with your account" button. Not anonymous, and everything becomes public |
| **Email** | Free | A published inbox, which attracts spam | The address | Spam to the inbox | `mailto:` (RFC 6068) defines only headers and a body, with **no attachments**. It reveals the sender's address. The client "SHOULD NOT send … without first disclosing" the message. Useless from a CLI or daemon |
| **GitHub Pages** | Free | Already available | — | — | Static hosting only ("a static site hosting service"), so it can't receive reports. Useful for publishing the privacy note, the public key fingerprint, and an optional kill switch file |

Sentry SDK notes, if it is ever chosen:
- sentry-cocoa is on the 9.x line. The newest release on the releases page is 9.35.0 (16 Nov). Deprecated APIs "will be removed in v10" (https://github.com/getsentry/sentry-cocoa/releases).
- Minimum macOS 12.0 for SDK 9.25.0+. On macOS "the SDK can't capture uncaught exceptions without additional configuration" (https://docs.sentry.io/platforms/apple/guides/macos/).
- For a CLI or headless target, use the `SentrySPM` product with the `NoUIFramework` trait, which needs "Sentry SDK 9.7.0+, Swift 6.1+, and Xcode 26.4+" (https://docs.sentry.io/platforms/apple/install/swift-package-manager/).
- Default data: the IP is not sent unless `sendDefaultPii` is set. HTTP Client Errors and network breadcrumbs are **on by default** and send headers (denylist-filtered) and sanitized URLs (https://docs.sentry.io/platforms/apple/data-management/data-collected/). Memory introspection is off by default. `beforeSend` can scrub events or drop them (return `nil`) (https://docs.sentry.io/platforms/apple/data-management/sensitive-data/).
- Sentry's MetricKit integration is opt-in (`enableMetricKit`) and covers hangs, CPU and disk-write exceptions (https://docs.sentry.io/platforms/apple/guides/macos/configuration/metric-kit/).
- The Worker does the same job with far less code in the daemon.

### 3. Privacy: what "anonymous" has to mean for an antivirus

**The law points to opt-in.**
- EU (ePrivacy Art. 5(3), which applies alongside the GDPR): the EDPB's final guidelines (v2.0, adopted 2024-10-07) say gaining access to information on the device happens "when the accessing entity distributes software on the terminal equipment of the user that is stored and will then proactively call an Application Programming Interface ('API') endpoint over the network… Such access clearly falls within the scope of Article 5(3)" (para. 33). They also say protection doesn't depend "on whether the user is aware of the said means of access" (para. 20) (https://edpb.europa.eu/system/files/2024-10/edpb_guidelines_202302_technical_scope_art_53_eprivacydirective_v2_en_0.pdf). Art. 5(3) access needs consent unless it is strictly necessary for a service the user asked for. A crash upload the user didn't ask for is hard to call strictly necessary. Explicitly asking ("Send this report?") is itself the request and the consent.
- A German law firm's GDPR guide (2023) on telemetry: "opt-out procedures are not sufficient", and "you should not rely on your legitimate interest(s)". It recommends documented, revocable consent (https://www.activemind.legal/guides/telemetry-data/).
- A crash-reporting vendor's blog (2026-03-08) argues for legitimate interest plus opt-out (https://bugnet.io/blog/crash-reporting-gdpr-indie-games). It is a vendor view and weaker than the EDPB text. It agrees on minimisation: IPs, device names and persistent IDs are personal data, so hash or drop them, and keep raw reports about 90 days.
- Canada (PIPEDA): the OPC guidelines (modified 2025-08-11) require express consent when information is sensitive, when the use "falls outside the individual's reasonable expectations", or when there is a meaningful risk of significant harm. They also ask for meaningful purposes rather than vague ones like "service improvement", and for just-in-time notice (https://www.priv.gc.ca/en/privacy-topics/collecting-personal-information/consent/gl_omc_201805/). An antivirus's logs (scanned file paths, alerts, process lists) are plausibly sensitive and outside expectations, so ask explicitly.
- Norms from real projects are in section 4: Firefox and Ghostty are opt-in or manual; VS Code and Homebrew are opt-out and got pushback (Homebrew).

**Redaction practice.**
- Apple's unified logging redacts dynamic strings and objects by default. Integers, floats and booleans stay public. `.public`/`.private`/`mask: .hash` control this (https://developer.apple.com/tutorials/data/documentation/os/generating-log-messages-from-your-code.md). macx's own log lines should already be safe at the source, and any `log show` extract in a report inherits the redaction.
- VS Code says its error telemetry contains "stack traces that have been scrubbed of user paths" (https://code.visualstudio.com/docs/configure/telemetry).
- What an antivirus report must scrub:

| Data | Where it shows up in macx | Rule |
|---|---|---|
| Home path / username | Every file path, alert, scan log | `/Users/<name>` → `~`. Other users' homes → `/Users/<user>`. Replace `NSUserName()`/full name anywhere in text |
| File names under home | Alert paths ("~/Documents/Tax 2026 - J Smith.pdf") | Keep the top folder and the extension (`~/Documents/…/*.pdf`), or a per-report salted hash. Show full names only if the user ticks a box |
| Hostname / computer name | Logs, `.ips` free text | → `<host>` |
| Serial number, hardware UUID, MAC addresses, `crashReporterKey` | System info, `.ips` | Drop (they are stable device IDs) |
| IPv4/IPv6 | Network alerts | → `<ip>`, optionally keeping the class (loopback/private/public) |
| Emails | Any string | → `<email>` |
| Wi-Fi SSIDs | Network state | Drop |
| File hashes | Detections | Hashes of detected **malware** are useful and fine. Hashes of ordinary user files are fingerprints, so drop them by default |
| Third-party process and app names | Process lists | Keep Apple and macx names. Third-party names reveal installed software; show them, and default to off for full process lists |
| Timestamps / uptime / pid | `.ips`, logs | Round to the minute. Drop `uptime`, `pid`, `parentPid`, `incident` |

- Prefer an **allowlist** (build the report from known fields) over a regex blocklist over free text. Keep the regexes as a second pass. Cover the redactor with unit tests over fixture logs that contain fake PII.
- Show the exact payload before sending, as plaintext and byte for byte what gets encrypted. Firefox, Ghostty's model and RFC 6068 for mail all put "disclose before sending" at the centre.
- **IP addresses can't be hidden from the relay.** Cloudflare sees the client IP. The Worker must not store or log it: no `console.log` of headers, and set `invocation_logs = false` under `[observability.logs]`, because new Workers have observability on by default and logs keep 3 days on Free (https://developers.cloudflare.com/workers/observability/logs/workers-logs/). Discord sees only Cloudflare's egress IP.
- No install ID and no persistent user ID. Instead, have the Worker return a random **report ID** (like Tailscale's `BUG-…` marker). The user can cite it in a GitHub issue or ask for deletion, which is how a privacy request gets served without identifying anyone.

**Optional end-to-end encryption (the relay can't read reports).**
- CryptoKit `HPKE` (RFC 9180) is available on macOS 14.0+, so macx's macOS 15 floor is covered (https://developer.apple.com/documentation/cryptokit/hpke.md).
  - Suites (https://developer.apple.com/documentation/cryptokit/hpke/ciphersuite.md): `Curve25519_SHA256_ChachaPoly`, `P256_SHA256_AES_GCM_256`, `P384_SHA384_AES_GCM_256`, `P521_SHA512_AES_GCM_256`.
  - The post-quantum `XWingMLKEM768X25519_SHA256_AES_GCM_256` needs **macOS 26+** (https://developer.apple.com/documentation/cryptokit/hpke/ciphersuite/xwingmlkem768x25519_sha256_aes_gcm_256.md), so it can't be the only suite while the floor is macOS 15.
- Sender (https://developer.apple.com/documentation/cryptokit/hpke/sender.md): `init(recipientKey:ciphersuite:info:)`, then `encapsulatedKey: Data` and `seal(_:authenticating:)`.
- Recipient (https://developer.apple.com/documentation/cryptokit/hpke/recipient.md): `init(privateKey:ciphersuite:info:encapsulatedKey:)`, then `open(_:authenticating:)`. Messages must be opened in the same order with the same `info`, so use one Sender per report.
- Decrypting on the maintainer side: a tiny local Swift script using CryptoKit on a Mac, or Go 1.26's new standard-library `crypto/hpke` (Feb 2026) (https://go.dev/doc/go1.26). The private key never touches the repo, the Worker or Discord.
- The cost of E2E: the Worker can't check content (only size, format and rate), Discord shows opaque files, and losing the private key loses every stored report.

### 4. How real open-source apps do it

| Project | Model | What it does |
|---|---|---|
| **Ghostty** | Local only, manual send | "Crash reports are _not_ automatically sent anywhere off your machine." Reports are saved to `$XDG_STATE_HOME/ghostty/crash` as `.ghosttycrash` files in Sentry envelope format, and `ghostty +crash-report` lists them. Users send one with `sentry-cli send-envelope` and the project's DSN. Warning: reports contain "the full stack memory of each thread", which may be sensitive (https://github.com/ghostty-org/ghostty/blob/main/README.md) |
| **Firefox** | Ask per crash. Auto-send is opt-in (desktop) | Desktop and Android ask before sending; sending is automatic only if you "opt in to sending us crash reports automatically". Extra info "may include sites that were open". iOS sends a smaller report automatically (Firefox Privacy Notice, effective 2026-05-04, https://www.mozilla.org/en-US/privacy/firefox/) |
| **VS Code** | Opt-out, tiered | `telemetry.telemetryLevel` = `all` / `error` / `crash` / `off`. "Developer: Show Telemetry" shows the events as they are sent, and `code --telemetry` lists every possible event. Stack traces are path-scrubbed (https://code.visualstudio.com/docs/configure/telemetry) |
| **Homebrew** | Opt-out, notice first | Shows "a notice before analytics are enabled so a user can opt out". The payload has "no user identifier or an IP-address field" and no build logs or exception details. Data goes to InfluxDB and is kept 365 days. Opt out with `brew analytics off` / `HOMEBREW_NO_ANALYTICS=1` (https://docs.brew.sh/Analytics). In 2016 it sent analytics to Google Analytics by default and it spread via Hacker News (https://joh-mue.github.io/2016/11/25/brew-sends-your-usage-data-to-google-analytics.html). In the Django debate that followed, "the ill-will generated for people who might feel the reporting was 'sneaked' upon them" was a central objection, and npm said "users would absolutely hate it" (https://lwn.net/Articles/707443) |
| **Tailscale** | Logs on by default, opt-out. Bug-report marker | `tailscale bugreport` writes a random `BUG-…` marker into the logs that "shares no personally-identifiable information" and is "unused unless you share the bug report with our team" (https://tailscale.com/kb/1227/bug-report). Opt out of client log upload with `--no-logs-no-support` / `TS_NO_LOGS_NO_SUPPORT`, at the cost of support (https://tailscale.com/kb/1011/log-mesh-security) |
| **KeePassXC** | No telemetry. Manual paste | The bug template asks users to paste "Help -> About -> Debug Info" into a GitHub issue (https://github.com/keepassxreboot/keepassxc/blob/develop/.github/ISSUE_TEMPLATE/bug_report.yml) |

Pattern: security and privacy-first tools (Ghostty, KeePassXC, Firefox desktop) default to **ask or manual**. Opt-out telemetry (Homebrew, VS Code, Tailscale) is defensible for a big organisation with a privacy policy, but it caused a lasting backlash in Homebrew's case. For an antivirus whose logs list the user's files, opt-in is the only default that fits.

---

## Current best practices
- Let ReportCrash capture crashes. Read `.ips` on the next launch, and parse line 1 for `bug_type == "309"` and `name`.
- Never auto-send. Ask each time, or let the user explicitly opt into "always send". Remember "never".
- Build reports from an allowlist of fields, redact on the device, and show the exact payload before sending.
- Keep secrets out of the binary. The relay (a Worker) holds the webhook or storage credentials.
- Cap size, rate and retention at the relay. Return a random report ID. Store no IPs.
- Offer a no-network path: "save report to file" or "copy", for GitHub, Discord or email by hand.
- E2E encryption with HPKE (X25519/ChaCha20-Poly1305) if relay operators shouldn't read reports.

## Breaking changes / gotchas
- **Root daemon crashes land in `/Library/Logs/DiagnosticReports`, which is admin-readable only.** The daemon has to collect them; the user-level app can't read them as a standard user.
- **MetricKit returns nothing for a LaunchDaemon** ("is not a MetricKit client"). Don't build the crash path on MetricKit.
- The Swift backtracer needs `get-task-allow` for builds made outside Xcode. That entitlement fails notarization and is debug-only.
- `.ips` is two JSON objects, not one. Parse line 1 separately.
- The `crashReporterKey` in every `.ips` is a stable per-device ID. Strip it, or the "anonymous" reports become linkable.
- Workers Free stops at 100,000 requests/day (Error 1027). A flood can take the endpoint down for everyone until midnight UTC.
- The Workers rate-limit binding is eventually consistent and per-location ("requests can exceed the configured limit"). Treat it as best effort and also enforce hard size limits.
- The Worker accepts bodies up to 100 MB on a Free zone, so enforce your own byte cap before reading the body.
- KV allows 1,000 writes/day on Free. Real reports are dropped silently after that.
- New Workers have observability on by default. Turn off invocation logs if you promise not to keep IPs.
- A Discord webhook token gives full control of the webhook. If it ever leaks (for example, committed to the public repo), delete and recreate it.
- HPKE's post-quantum suite needs macOS 26+. Use `Curve25519_SHA256_ChachaPoly` while the floor is macOS 15.
- Sentry region (US/EU) is fixed when the organisation is created.

## Unverified
- **Release years for KSCrash 2.6.1 (30 Oct), PLCrashReporter 1.12.2 (12 Nov) and sentry-cocoa 9.35.0 (16 Nov):** GitHub showed no year. GitHub omits the year for current-year dates, so these are probably 2026, but that is not confirmed.
- **Whether the Workers rate-limiting binding is included on Workers Free.** Neither the binding page nor the GA changelog (2025-09-19) says. The WAF rule (1 rule, 10 s, IP) is confirmed for Free zones.
- **Whether R2 needs a payment method on file.** Only a third-party guide says so.
- **Sentry's 5k errors "per month".** The pricing page says "5k errors"; the docs talk about quotas per billing cycle.
- **MetricKit for an ad-hoc-signed (not Developer ID) app.** The forum evidence covers a Developer ID app (2026) and a CLI tool (2023) only.
- **Whether reading `~/Library/Logs/DiagnosticReports` triggers any TCC prompt.** I found nothing saying it is protected. Test on macOS 15 and 27 before shipping, given the project's no-popup rule.
- **The exact `.ips` filename pattern and how long macOS keeps reports.** Not found in Apple docs. Match on the metadata `name` and `bundleID`, not on filenames.
- **An Apple Community report that crash logs stopped being written after upgrading to macOS 26.1.** Seen only in a search snippet; the thread returned HTTP 502.
- **Discord's upload limit for webhooks specifically.** The docs say "default limit is 20 MiB for all users" without naming webhooks. Keep reports far smaller (≤1 MB) anyway.
- **Whether a Worker forwarding a ≤1 MB body to Discord stays under 10 ms CPU.** Expected (it is mostly I/O), but not measured.
- **`HPKE.Sender.seal` mutability.** Apple's page lists `func seal`. Sealing advances the HPKE context, so expect to hold the sender in a `var`. This is a compile-time detail.
- **Mozilla support pages** (support.mozilla.org) didn't render. Firefox behaviour is taken from the Firefox Privacy Notice instead.
- **The LWN article's exact date** wasn't shown in the fetch. It covers the 2016 Django DEP 8 debate.
- None of the legal points are legal advice. The EDPB text is the strongest source; the two blog sources disagree with each other.

---

## What this means for macx

### Recommended design

1. **Capture (no new dependency, nothing in the crash path).**
   - On start, each role checks for new `.ips` files newer than its watermark. The CLI and app check `~/Library/Logs/DiagnosticReports`. The daemon checks `/Library/Logs/DiagnosticReports`.
   - Parse line 1 and keep only `bug_type == "309"` with `name == "macx"` (or the app's bundle ID). Reduce each report to a small struct:
     - exception `type`/`signal`/`subtype`/`message`
     - termination `namespace`/`code`/`indicator`
     - the faulting thread's frames (`imageOffset` + `symbol`) for the macx image, plus that image's `uuid` (for symbolication)
     - `osVersion.train`/`build`, `cpuType`, `translated`
     - the macx version, and which role crashed (cli/app/daemon)
   - Drop `crashReporterKey`, `incident`, `pid`/`parentPid`, `uptime`, `vmSummary`, `threadState`, and the `asi` strings. The `asi` strings could be offered only after redaction and review.
   - The daemon (root) writes its reduced, redacted crash summaries to a root-owned pending queue. It never sends anything itself; it has no UI to ask with.
2. **Bug report bundle (`macx report`, plus a "Report a problem…" item in the app).**
   - Contents:
     - an optional free-text description
     - the pending crash summaries
     - the last N lines or minutes of macx's own logs
     - version info: macx version, macOS version, architecture, enabled features
   - Everything goes through the allowlist and redaction rules above.
   - The CLI prints the full report (or opens it in `$PAGER`) and asks `Send this report? [y/N]`. The app shows it in a scrollable read-only text view with Send / Save to file… / Copy / Cancel.
   - Settings: **"Crash reports: Ask each time (default) / Never"**. An "Always send" option only if the maintainer wants it, and then as an explicit opt-in.
3. **Transport.**
   - The report JSON is HPKE-sealed (`Curve25519_SHA256_ChachaPoly`, `info = "macx-report-v1"`) to a maintainer X25519 public key compiled into the binary.
   - Envelope: `magic "MXR1" | key-id byte | encapsulatedKey (32 B) | ciphertext`. The header doubles as the AAD.
   - Sent as a `POST application/octet-stream` with a short timeout to a Worker URL compiled into the binary. A key-id byte allows key rotation.
4. **Relay (Cloudflare Worker, free plan, about 50 lines).**
   - Reject when: the method isn't POST, the body exceeds roughly 256 KB to 1 MB (check `Content-Length` and stop reading past the cap), the magic or version is wrong, or the rate limit is hit (binding keyed on IP, or the single free WAF rule).
   - Then generate `crypto.randomUUID()` and forward to the Discord webhook (`env.DISCORD_WEBHOOK`, a secret) as `files[0] = <id>.mxr`. Use `payload_json` with a short `content` ("report <id>, <bytes> B, key <n>") and `allowed_mentions: {parse: []}`. Alternatively write to R2 (with a lifecycle rule such as 90 days) or KV (`expirationTtl`).
   - Return `{id}` to the client, which shows it to the user ("Report ID: … quote this if you open an issue").
   - Turn off invocation logs and never log headers or IPs.
5. **Maintainer side.**
   - Download the `.mxr` file from the private channel or bucket.
   - Decrypt locally with a small Swift script using CryptoKit `HPKE.Recipient(privateKey:ciphersuite:info:encapsulatedKey:)` + `open(_:authenticating:)`, or with Go 1.26 `crypto/hpke`.
   - Render any `.ips` excerpts with `viewdiagnostic`.
   - Keep the private key in a password manager, never in the repo. Use a key separate from any update-signing key.
6. **Publish what's collected.**
   - A short "Crash and bug reports" section in the README or docs, also linked from the consent screen. It covers:
     - what is sent, where it goes (Cloudflare, then Discord/R2), and that it is encrypted end to end
     - retention (for example 90 days)
     - that IPs are not stored by the Worker
     - how to ask for deletion (quote the report ID)
   - Optionally host the public-key fingerprint, plus an `enabled: false` kill switch fetched before sending, on GitHub Pages. That follows Sentry's own advice to configure the endpoint dynamically so it can change without a new release.

Why not Sentry: it puts a large C crash handler into a root security daemon. It stores unencrypted reports with a third party. It sends HTTP-error and breadcrumb data by default unless you turn that off. A public DSN lets anyone use up the monthly quota. Ghostty shows that the useful half of Sentry (the envelope format) works without uploading anything automatically.

### Decisions the maintainer must make
1. **Default and choices:** "Ask each time" (recommended) versus also offering "Always send". "Never" must be one click and must stick.
2. **E2E encryption or not.** With it, Cloudflare and Discord can't read reports, but the Worker can't filter content and losing the key means losing the reports. Without it, it's simpler, and the reports sit readable in a Discord channel.
3. **Destination:** a private Discord channel (zero extra setup, attachments up to the upload limit), R2 (files with lifecycle deletion; may need a payment method on file), or KV (1,000 writes/day, TTL).
4. **Size cap and log window:** how many log lines or minutes, and the maximum report size (suggest ≤256 KB).
5. **Retention:** N days (suggest 90). Discord needs manual cleanup; R2 and KV expire automatically.
6. **Antivirus-specific opt-ins:** whether full file names, malware hashes or process lists may be included (each off by default with its own checkbox), or only redacted forms.
7. **Contact field:** none (fully anonymous), or an optional "email if you want a reply" that is clearly labelled as breaking anonymity.
8. **Daemon crash flow:** the daemon queues root `.ips` summaries for the app or CLI to offer. Decide how the app reads that queue. This needs a privileged read through the daemon, because `/Library/Logs/DiagnosticReports` is admin-only.
9. **Abuse response:** the rate-limit numbers, whether to add a GitHub-Pages kill switch, and the steps to rotate the Worker URL or the Discord webhook if they are abused.
10. **Key management:** where the HPKE private key lives, how its backup works, and the rotation plan (key-id byte).

---

## Sources

| URL | What it provided | Date |
|---|---|---|
| https://developer.apple.com/tutorials/data/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs.md | macOS crash report collection via Console; redact before sharing; prefer `.ips` | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/tutorials/data/documentation/xcode/interpreting-the-json-format-of-a-crash-report.md | `.ips` JSON since macOS 12; two-object layout; `bug_type` 309; all field meanings, incl. `crashReporterKey`; path placeholders | Undated (© 2026), read 2026-11-24 |
| https://keith.github.io/xcode-man-pages/ReportCrash.8.html | Per-user vs daemon report locations; system folder admin-readable only | Man page dated 2007-01-11 (mirror) |
| https://support.apple.com/en-ae/guide/console/cnsl664be99a/1.1/mac/26 | Console report types (`.ips`, `.spin`, `.diag`); User vs System reports; admins see all | Console guide for macOS 26, read 2026-11-24 |
| https://objective-see.org/blog/blog_0x7B.html | Both DiagnosticReports locations on current macOS | 2024-08-13 |
| https://developer.apple.com/forums/thread/693681?answerId=902333022 | `/usr/bin/viewdiagnostic`; DTS: added in macOS 15 | Thread 2021-11 to 2026-08 |
| https://developer.apple.com/documentation/metrickit.md | MetricKit macOS 12+; immediate diagnostics; macOS 27 `MetricManager` async API | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic.md | `MXCrashDiagnostic` availability macOS 12.0–27.3; properties | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/tutorials/data/documentation/metrickit/monitoring-app-performance-with-metrickit.md | `MetricManager.diagnosticReports`, `.crash` results, `Codable` reports | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/forums/thread/784399 | DTS: crash diagnostics delivered with analytics sharing off; treat as personal data | 2025-05 |
| https://developer.apple.com/forums/thread/729271 | CLI tool gets MetricKit as user, root or LaunchAgent; not as LaunchDaemon ("not a MetricKit client") | 2023-05 |
| https://developer.apple.com/forums/thread/821002 | DTS: MetricKit works on macOS; metrickitd is a launchd agent; Developer ID host app OK, sysex not | 2026-03 to 2026-04 |
| https://developer.apple.com/forums/thread/724698?answerId=911997022 | MetricKit and system extensions don't work together | 2023-02 to 2026 |
| https://github.com/swiftlang/swift/blob/main/docs/Backtracing.rst | Backtracer off by default on macOS (tty default on 26+); JSON output; get-task-allow requirement; no setuid | main branch, read 2026-11-24 |
| https://github.com/kstenerud/KSCrash/releases | 2.6.1 latest stable (30 Oct), bug-fix release | Year not shown (likely 2026) |
| https://github.com/kstenerud/KSCrash | SPM install; SPM-only after 2.6.1; handled crash types | Read 2026-11-24 |
| https://github.com/microsoft/plcrashreporter/releases | 1.12.2 latest (12 Nov), one fix | Year not shown (likely 2026) |
| https://github.com/microsoft/plcrashreporter | SPM support; macOS 11.5 minimum | Read 2026-11-24 |
| https://sentry.io/pricing/ | Developer plan: 5k errors, 1 user, 1 GB attachments, 30-day lookback; no spend cap | Read 2026-11-24 |
| https://docs.sentry.io/pricing/ | Over-quota data dropped for the rest of the billing cycle | Read 2026-11-24 |
| https://github.com/getsentry/sentry-cocoa/releases | 9.35.0 latest (16 Nov); 9.x line; v10 removals planned | Year not shown (likely 2026) |
| https://docs.sentry.io/platforms/apple/guides/macos/ | SwiftPM URL/products; macOS 12.0 minimum for 9.25.0+; uncaught exceptions need config | Read 2026-11-24 |
| https://docs.sentry.io/platforms/apple/install/swift-package-manager/ | `NoUIFramework` trait for CLI tools (SDK 9.7.0+, Swift 6.1+, Xcode 26.4+) | Read 2026-11-24 |
| https://docs.sentry.io/platforms/apple/data-management/data-collected/ | Defaults: no IP without `sendDefaultPii`; HTTP client errors and breadcrumbs on | Read 2026-11-24 |
| https://docs.sentry.io/platforms/apple/data-management/sensitive-data/ | `beforeSend` scrubbing; memory introspection off by default | Read 2026-11-24 |
| https://docs.sentry.io/concepts/key-terms/dsn-explainer/ | DSN safe to make public; abuse risk; IP blocking, rotation, dynamic DSN | Read 2026-11-24 |
| https://docs.sentry.io/organization/data-storage-location/ | EU = Frankfurt; region can't be changed | Read 2026-11-24 |
| https://develop.sentry.dev/self-hosted/ | Self-hosted minimums (4 cores, 16 GB + 16 GB swap, 20 GB); FSL licence | Read 2026-11-24 |
| https://docs.sentry.io/platforms/apple/guides/macos/configuration/metric-kit/ | Sentry MetricKit integration: opt-in; hang/CPU/disk diagnostics | Read 2026-11-24 |
| https://telemetrydeck.com/feature/error-tracking/ | Errors are sent as signals; no crash-log capture described | Undated (© 2020–2026) |
| https://telemetrydeck.com/docs/articles/preset-errors/ | `errorOccurred(id:)`, category, message; warning about user data in dynamic values | Read 2026-11-24 |
| https://telemetrydeck.com/blog/pricing-update-2026/ | Free tier cut to 50,000 events/month for new accounts | 2026-07-01 (updated 2026-10-12) |
| https://developers.cloudflare.com/workers/platform/limits/ | Free: 100k req/day, 10 ms CPU, 100 MB body (Free zone), 128 MB, 64 secrets | dateModified 2026-11-19 |
| https://developers.cloudflare.com/workers/platform/pricing/ | Free plan request/CPU limits; Workers Logs 3-day retention on Free | dateModified 2026-11-18 |
| https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/ | Rate-limit binding config; 10/60 s periods; eventually consistent, per-location | dateModified 2026-11-12 |
| https://developers.cloudflare.com/changelog/2025-09-19-ratelimit-workers-ga/ | Rate-limit binding GA | 2025-09-19 |
| https://developers.cloudflare.com/waf/rate-limiting-rules/ | Free zone: 1 rule, 10 s periods, IP characteristic, Path field | dateModified 2026-08-25 |
| https://developers.cloudflare.com/workers/configuration/secrets/ | `wrangler secret put`; secrets not viewable after set; read via `env` | dateModified 2026-11-21 |
| https://developers.cloudflare.com/workers/observability/logs/workers-logs/ | Observability on by default for new Workers; `invocation_logs = false`; 3-day Free retention | dateModified 2026-11-18 |
| https://developers.cloudflare.com/r2/pricing/ | R2 free tier (10 GB-month, 1 M A, 10 M B, free egress) | dateModified 2026-10-30 |
| https://developers.cloudflare.com/r2/buckets/object-lifecycles/ | Lifecycle rules delete objects after N days | dateModified 2026-10-26 |
| https://developers.cloudflare.com/kv/platform/limits/ | KV Free: 1,000 writes/day, 1 GB, 25 MiB values | dateModified 2026-10-30 |
| https://developers.cloudflare.com/kv/api/write-key-value-pairs/ | `expirationTtl` (minimum 60 s) | dateModified 2026-11-24 |
| https://docs.discord.com/developers/resources/webhook | Execute Webhook params (`content` 2000, 10 embeds, `files[n]`, `payload_json`, `allowed_mentions`); token-only endpoints | Read 2026-11-24 |
| https://docs.discord.com/developers/reference | "Default limit is 20 MiB for all users" per file | Read 2026-11-24 |
| https://docs.discord.com/developers/topics/rate-limits | Per-webhook buckets; 429 headers; 10,000 invalid requests per 10 min means a ban | Read 2026-11-24 |
| https://support.discord.com/api/v2/help_center/en-us/articles/25444343291031.json | Free upload limit 20 MB (up from 10 MB) | Updated 2026-11-24 (edited 2026-09-30) |
| https://docs.github.com/en/rest/issues/issues#create-an-issue | Create issue: users with pull access; Bearer token headers | API version 2026-03-10, read 2026-11-24 |
| https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-an-issue | Prefilled issue URL query params; 414 when too long | Read 2026-11-24 |
| https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages | Pages is static hosting only | Read 2026-11-24 |
| https://www.rfc-editor.org/rfc/rfc6068 | `mailto:` has no attachments; disclose before sending | 2010-10 |
| https://edpb.europa.eu/system/files/2024-10/edpb_guidelines_202302_technical_scope_art_53_eprivacydirective_v2_en_0.pdf | Art. 5(3) covers software that calls an API endpoint (para. 33); user awareness irrelevant (para. 20) | Adopted 2024-10-07 |
| https://www.priv.gc.ca/en/privacy-topics/collecting-personal-information/consent/gl_omc_201805/ | PIPEDA express consent triggers; meaningful purposes; just-in-time notice | Modified 2025-08-11 |
| https://www.activemind.legal/guides/telemetry-data/ | Law-firm view: telemetry needs consent; opt-out insufficient | Last updated 2023 (07/03/2023) |
| https://bugnet.io/blog/crash-reporting-gdpr-indie-games | Vendor view: legitimate interest + opt-out; minimisation; 90-day retention | 2026-03-08 |
| https://developer.apple.com/tutorials/data/documentation/os/generating-log-messages-from-your-code.md | Unified log privacy: dynamic strings redacted by default; `.public`/`.private`/hash mask | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/documentation/cryptokit/hpke.md | CryptoKit HPKE, macOS 14.0+ | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/documentation/cryptokit/hpke/ciphersuite.md | Suite list (X25519/ChaChaPoly, P-256/384/521, X-Wing) | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/documentation/cryptokit/hpke/ciphersuite/xwingmlkem768x25519_sha256_aes_gcm_256.md | X-Wing PQ suite needs macOS 26.0+ | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/documentation/cryptokit/hpke/sender.md | `Sender` initializers, `encapsulatedKey`, `seal` | Undated (© 2026), read 2026-11-24 |
| https://developer.apple.com/documentation/cryptokit/hpke/recipient.md | `Recipient` initializers, `open`; same order and `info` | Undated (© 2026), read 2026-11-24 |
| https://go.dev/doc/go1.26 | New `crypto/hpke` package (RFC 9180) | 2026-02 |
| https://github.com/ghostty-org/ghostty/blob/main/README.md | Crash reports local-only, Sentry envelope, manual send, sensitivity warning | main branch, read 2026-11-24 |
| https://www.mozilla.org/en-US/privacy/firefox/ | Crash reports: ask before sending on desktop/Android; auto-send opt-in | Effective 2026-05-04 |
| https://code.visualstudio.com/docs/configure/telemetry | `telemetry.telemetryLevel` levels; Show Telemetry; path-scrubbed stacks | Page shows 2026-11-18 |
| https://docs.brew.sh/Analytics | Opt-out analytics with notice; no user ID/IP field; InfluxDB; 365 days | Read 2026-11-24 |
| https://joh-mue.github.io/2016/11/25/brew-sends-your-usage-data-to-google-analytics.html | 2016 Homebrew Google Analytics opt-out news via Hacker News | 2016-11-25 |
| https://lwn.net/Articles/707443 | Opt-in vs opt-out debate (Django DEP 8, Debian, npm) citing Homebrew | 2016 (exact date not shown in fetch) |
| https://tailscale.com/kb/1227/bug-report | `tailscale bugreport` random `BUG-…` marker, no PII | Last validated 2026-01-05 |
| https://tailscale.com/kb/1011/log-mesh-security | Client logs streamed by default; `--no-logs-no-support` opt-out | Last validated 2026-01-05 |
| https://github.com/keepassxreboot/keepassxc/blob/develop/.github/ISSUE_TEMPLATE/bug_report.yml | Manual "Debug Info" paste into GitHub issues | develop branch, read 2026-11-24 |
