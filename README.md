# Macximesed

Squeeze more speed out of macOS and catch stealer-style malware (like AMOS, the Atomic macOS Stealer) that XProtect misses.

> **Early work in progress.** `macx scan`, `macx clean` (Safe tier), `macx apps` and `macx undo` exist so far. See [STATUS.md](STATUS.md) for what's being built and [CHANGELOG.md](CHANGELOG.md) for what's done.

## What it will do
- **Speed:** clean caches and leftovers, remove apps you don't use, a Boost mode that pushes background work aside for the app you're using, a heat/throttle view, and game profiles.
- **Safety:** alert on new LaunchDaemons, LaunchAgents and login items (especially fake `com.apple.*` ones), flag pasted `curl | zsh` and `base64 -D | zsh` commands, check downloads before you open them, and watch what programs do live through Apple's `eslogger`.
- **Risk levels:** every change is tagged **Safe**, **Medium**, **Risky** or **Extreme**. Risky and Extreme ask three times and come with an undo. Nothing below Extreme touches SIP, Gatekeeper, XProtect, FileVault or the firewall.

It does not replace XProtect: keep that on. Without Apple's restricted Endpoint Security entitlement it can't block a program *before* it starts, only catch it as it happens. The full reasoning is in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).

## Requirements
- macOS 15 or later on Apple Silicon. Developed on macOS 27.
- Xcode 16 or later (Swift 6).

## Build and run
```bash
swift build -c release
```

```bash
.build/release/macx scan
```

## Commands
| Command | What it does | Needs root |
|---|---|---|
| `macx scan [--top N]` | Read-only report: SIP, Gatekeeper, FileVault and firewall state; heat/throttling; disk use; the N busiest processes (default 10). Changes nothing. | No |
| `macx clean --dry-run` | Lists the Safe cleanup items with their IDs and sizes. Changes nothing. | No |
| `macx clean [--only ID ...] [--include-in-use] [-y]` | Moves the chosen items (all, by default) into the undo folder. Asks first unless `-y`. Caches of running apps are skipped unless `--include-in-use`. | No |
| `macx apps [--unused [--days 90]] [--intel] [--sort size\|name\|used]` | Lists apps in `/Applications` and `~/Applications` (and one folder down) with size, Apple silicon / Intel / Universal, and when each was last opened. | No |
| `macx apps remove NAME\|BUNDLE-ID [-y]` | Moves the app and its Library leftovers (support files, caches, preferences, saved state, containers, launch agents) into the undo folder. Refuses apps that are running, built into macOS, or built-in Apple apps. Apple's App Store apps (GarageBand, iMovie, Pages…) are allowed. Root-owned apps need `sudo`. | Sometimes |
| `macx apps leftovers [--remove ID ...] [-y]` | Lists files left behind by apps that are gone (reverse-DNS names whose maker has no installed app), and optionally moves them to the undo folder. | No |
| `macx undo [list]` | Lists undo batches. | No |
| `macx undo restore ID` | Puts a batch back. Anything that already exists again at the original place is kept in the undo folder instead of being overwritten. | No |
| `macx undo purge [--days 7] [-y]` | **Permanently** deletes batches older than N days. This is the only command that really deletes, and it asks first. | No |

### What the Safe tier cleans
- Each folder in `~/Library/Caches`, listed separately, so `--only` can pick them.
- `~/Library/Logs`, Xcode DerivedData and iOS DeviceSupport, Simulator caches, and the npm cache.

It never cleans:
- Apple's caches (`com.apple.*` and framework caches such as CloudKit and GeoServices).
- `~/.cache`, which often holds virtual environments and runtimes.
- Macximesed's own data.
- Empty folders.

**Last used:** this comes from Spotlight. When Spotlight has no date, it's estimated from the newest change to the app's own settings and support files, and shown with `~`. Apps with no date at all are never counted as unused.

Cleaned items go to `~/Library/Application Support/Macximesed/Undo/<batch>/`, with a `manifest.json` per batch. Disk space only comes back after `macx undo purge`.

## Tests
```bash
swift test
```

CI runs the build and tests on every push and pull request (`.github/workflows/ci.yml`).

## License
[MIT](LICENSE)
