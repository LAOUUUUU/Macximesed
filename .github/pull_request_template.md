## What and why
<!-- What this changes and why. Link the issue if there is one. -->

## How it was tested
- [ ] A failing test came first (red, then green).
- [ ] `swift format lint --strict --recursive Sources Tests Package.swift`
- [ ] `swift build -Xswiftc -warnings-as-errors && swift test`
- [ ] Tried on a real Mac. Say which macOS and Apple silicon or Intel:

## Safety
- [ ] Nothing is deleted directly: files go through the undo store.
- [ ] Nothing is decided from how a name looks (bundle IDs, tool answers, open files and signatures only).
- [ ] Nothing reads privacy-guarded folders without Full Disk Access.
- [ ] No personal paths, usernames or secrets in code, tests or docs.

## Docs
- [ ] README, if anything user-facing changed.
- [ ] CHANGELOG `[Unreleased]`.
- [ ] STATUS, if a step moved.
