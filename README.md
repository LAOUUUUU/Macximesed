# Macximesed

Squeeze more speed out of macOS and catch stealer-style malware (like AMOS, the Atomic macOS Stealer) that XProtect misses.

> **Early work in progress.** Only `macx scan` exists so far. See [STATUS.md](STATUS.md) for what's being built and [CHANGELOG.md](CHANGELOG.md) for what's done.

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

## Tests
```bash
swift test
```

CI runs the build and tests on every push and pull request (`.github/workflows/ci.yml`).

## License
[MIT](LICENSE)
