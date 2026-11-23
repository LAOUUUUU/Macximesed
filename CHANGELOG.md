# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). The jobs still to do are in [STATUS.md](STATUS.md).

## [Unreleased]

### Added
- Research brief and 12-step plan (`research/macximesed-v1/RESEARCH.md`).
- `STATUS.md` (job list) and `CHANGELOG.md` (history).
- Swift package: `MacxCore` library, `macx` command-line tool, tests.
- `macx scan`: read-only report of protections, top processes, disk use and thermal state.
- GitHub Actions CI: build and test on macOS.
- Undo store: cleanups move files into `~/Library/Application Support/Macximesed/Undo/<batch>/` with a manifest. `macx undo list`, `macx undo restore <id>` (never overwrites anything new), and `macx undo purge --days 7` (the only real delete, asks first).
- `macx clean` with the **Safe** tier: third-party caches (one item per folder), user logs, Xcode DerivedData and DeviceSupport, Simulator caches and the npm cache, with `--dry-run`, `--only`, `--include-in-use` and `-y`. Caches of running apps are skipped. Apple caches, `~/.cache` and empty items are never included.
