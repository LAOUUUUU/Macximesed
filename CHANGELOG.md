# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). The jobs still to do are in [STATUS.md](STATUS.md).

## [Unreleased]

### Added
- Research brief and 12-step plan (`research/macximesed-v1/RESEARCH.md`).
- `STATUS.md` (job list) and `CHANGELOG.md` (history).
- Swift package: `MacxCore` library, `macx` command-line tool, tests.
- `macx scan`: read-only report of protections, top processes, disk use and thermal state.
- GitHub Actions CI:
  - format lint;
  - a test matrix on macOS 15, macOS 26 Apple silicon and macOS 26 Intel, building with warnings as errors and smoke-running every read-only command;
  - Address and Thread Sanitizer runs;
  - a line-coverage summary;
  - a universal (arm64 + x86_64) binary artifact.
- CodeQL security analysis (on push and weekly), Dependabot for actions and Swift packages, and a release workflow that publishes a universal binary with notes from this file when a `v*.*.*` tag is pushed.
- `.swift-format` config. The code is formatted to it.
- Undo store: cleanups move files into `~/Library/Application Support/Macximesed/Undo/<batch>/` with a manifest. `macx undo list`, `macx undo restore <id>` (never overwrites anything new), and `macx undo purge --days 7` (the only real delete, asks first).
- `macx clean` with the **Safe** tier: third-party caches (one item per folder), user logs, Xcode DerivedData and DeviceSupport, Simulator caches and the npm cache, with `--dry-run`, `--only`, `--include-in-use` and `-y`. Caches of running apps are skipped. Apple caches, `~/.cache` and empty items are never included.
- `macx apps`: lists apps with size, architecture (Apple silicon, Intel or Universal, read from the Mach-O header) and last use (Spotlight, or `~` estimated from the app's own files). Filters: `--unused [--days]`, `--intel`, plus `--sort`.
- `macx apps remove`: uninstalls an app and its exact-match leftovers into the undo folder. Refuses running apps, apps on the sealed system volume, and built-in Apple apps, but allows Apple's App Store apps.
- `macx apps leftovers`: finds files of apps that are gone, by vendor of reverse-DNS names, and can move them to the undo folder.

### Changed
- **No more guessing from names.**
  - Cache and leftover owners now come from Spotlight's index of every bundle ID on disk (an exact ID, or the ID plus a dot), and tool caches from the tools themselves (`brew`, `npm`, `pip3`, `yarn`, `pnpm`).
  - Unattributed caches are labelled "unknown owner" and need `--include-unknown` or `--only`.
  - "In use" now means a process has a file open inside the item (through libproc), or its app is running (by exact bundle ID).
  - Removed: the hand-made list of Apple cache names, matching on words in app names, and the list of top-level domains.
- Apps are found anywhere through Spotlight, falling back to `/Applications`, `~/Applications` and `Applications` on each mounted volume. `macx apps` shows each app's folder.
- `macx apps remove` only moves exact bundle-ID leftovers. Folders matched by name are listed, and moved only with `--include-name-matches`.
- `macx apps leftovers` skips app-group IDs (`group.*`, `systemgroup.*`) and empty items.
- Xcode DerivedData uses the custom location set in Xcode's settings, if there is one.
- System tools run with `LANG=C` and `LC_ALL=C`, so output is the same on any language setting.
- Architecture labels depend on the Mac's CPU, so Intel Macs see "Intel" and "Apple silicon only (can't run here)".

### Fixed
- Errors are printed without the usage text underneath.
- Apps in folders whose names contain dots (for example `Cisco Packet Tracer 9.0.1/`) are found.
