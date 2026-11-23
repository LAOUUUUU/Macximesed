# Contributing to Macximesed

Thanks for helping. Macximesed changes files on people's Macs and decides what looks like malware, so the bar is: **nothing destructive without an undo, and nothing decided by guessing.**

## Before you start
- See what's being built in [STATUS.md](STATUS.md) and what's done in [CHANGELOG.md](CHANGELOG.md). The design and its reasons are in [research/macximesed-v1/RESEARCH.md](research/macximesed-v1/RESEARCH.md).
- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- **Security problems go through private reporting, not public issues.** See [SECURITY.md](SECURITY.md).

## Setup
You need macOS 15 or later and Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/LAOUUUUU/Macximesed.git
```

```bash
cd Macximesed && swift build && swift test
```

Run your build with `.build/debug/macx <command>`. Development builds keep your terminal's privacy access. The installed copy (`scripts/install.sh`) owns its own access. See the README's *Permissions* section.

## Branches
- Work happens on **`dev`**. Open pull requests against `dev`, not `main`.
- `main` only gets releases: a batch of tested work from `dev`, a version bump, and a `v*.*.*` tag. The tag runs `release.yml`.

## How changes are made
1. **Test first.** Every behaviour change starts with a failing test (red), then the code that makes it pass (green), then a tidy-up. Tests use Swift Testing (`import Testing`) and build fake Macs in a temp folder: see `TempDir` in `Tests/MacxCoreTests/UndoStoreTests.swift`. Never point tests at your real home folder.
2. **Logic goes in `MacxCore`**, so it can be tested. The `macx` target only parses arguments and prints.
3. **Inject the system.** Anything that runs a tool or asks the OS goes through `CommandRunner`, `SignatureChecking`, `SystemContext`, `PrivacyPolicy` and the like, so tests can feed in fixtures.
4. **Update the docs in the same pull request:** README for anything user-facing, CHANGELOG under `[Unreleased]`, and STATUS when a step is done.

## Rules the code must keep
- **No guessing.** Decide from facts the system reports: bundle IDs in Spotlight's index, a tool's own answer about its cache path, open files from libproc, code signatures from the Security framework. Never decide from what a name looks like. If the owner can't be established, say "unknown owner" and leave it out by default.
- **Nothing is deleted directly.** Cleanups and uninstalls move files into the undo store (`UndoStore`). Only `macx undo purge` deletes, and it asks first.
- **Higher tiers ask more.** Safe asks once, Risky and Extreme ask three times and come with an undo. Nothing below Extreme touches SIP, Gatekeeper, XProtect, FileVault or the firewall.
- **No privacy popups.** Without Full Disk Access, don't read anything `PrivacyPolicy` guards.
- **Works on any Mac.** Don't hardcode folder layouts that can differ: ask the system, or fall back to standard locations and say so. Run system tools through `ProcessRunner` (C locale). Think about Intel Macs and macOS 15.
- **Detection rules come from real behaviour.** A new rule in `PersistenceRules` or `CommandPatterns` needs a test with a realistic sample, ideally taken from a published malware write-up and linked in the test. It also needs a test showing that normal software doesn't trigger it.

## Style and checks
CI runs these, so run them before pushing:

```bash
swift format --in-place --recursive Sources Tests Package.swift
```

```bash
swift format lint --strict --recursive Sources Tests Package.swift && swift build -Xswiftc -warnings-as-errors && swift test
```

Formatting follows `.swift-format`: 4-space indents, 140 columns. CI also runs the tests on macOS 15, macOS 26 (Apple silicon) and macOS 26 (Intel), under Address and Thread Sanitizer, with coverage, plus CodeQL.

## Commits and pull requests
- One topic per pull request. Write the commit message as the change itself, in the present tense ("Add …", "Skip …"), with a short body saying why.
- Fill in the pull request template, including what you tested on a real Mac.
- No secrets, personal paths or real usernames in code, tests or docs. Use placeholders such as `/Users/someone`.

## Reporting a wrong detection
If `macx persist` flags something harmless, or misses something it should catch, use the **Detection report** issue template. Include the rule ID, such as `[missing-program]`, and the item's path. Remove your username from paths before posting.

## License
By contributing you agree your work is released under the [MIT License](LICENSE).
