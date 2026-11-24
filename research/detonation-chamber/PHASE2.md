# Detonation chamber, phase 2: brief

Lao picked all four on 2026-11-24: a fake internet, skipping sleeps, `.pkg` installer scripts, and testing the chamber with Atomic Red Team. Today the chamber runs `sh`/`bash`/`zsh` scripts in a tiny Alpine VM with **no network device**. Mac commands are recording stand-ins, and the password boxes answer with a canary password. `curl`/`wget` print nothing and leave empty files, so a script's second stage never arrives and its upload is never seen.

## 1. Fake internet (still no real network in the VM)
**Inside the VM.** The `curl`, `wget` and `nscurl` stand-ins become a small recorder:
- it logs each request: URL, method, headers, and the **body it would send**. A body given as `-d @file`, `-F x=@file`, `--data-binary @file` or `-T file` is resolved to the file it names, so the report can say *"tried to upload `~/Library/Keychains/login.keychain-db` to 203.0.113.9"*;
- it answers with the response the host baked into the image for that URL, or with an empty `200`.

New verdict rules:
- `uploads-stolen-data` (**critical**): the body includes a bait keychain, browser or wallet file, or the canary password;
- `downloads-next-stage` (high): something it downloaded was then run.

**The host fetches stage 2, the VM runs it.** `macx chamber run FILE --follow` runs in rounds:
1. Run once and collect the URLs the script asked for.
2. The host fetches each one the way `macx guard inspect` already does. That reads only, it runs nothing, it doesn't send your cookies, it allows at most 5 MB per URL and it records redirects.
3. Run again with those answers baked into the image, so the script gets its real second stage and the chamber sees what it does with it.

At most 3 rounds and 10 URLs. Every fetched file also gets `macx check`, and its SHA-256 is checked against the malware feed. Without `--follow`, nothing ever leaves the Mac. The report says which URLs were fetched, so you know the attacker's server saw a request from your IP. That's the same trade-off `guard inspect` already asks about.

**Not in phase 2:** programs that open raw sockets (Python `urllib`, bash `/dev/tcp`, `nc`). There's still no network device, so their `connect()` fails, and strace records the address as `network-attempt`, as it does today. A virtual NIC with a fake DNS and HTTP sink inside the VM is possible later.

## 2. Skipping sleeps
- A `sleep` stand-in returns at once and records the requested time. Busybox `sleep`, `/bin/sleep`, and zsh's or bash's calls to it all go to the stand-in.
- `timeout N` and `caffeinate` already return at once.
- Python's `time.sleep` and Perl's `sleep` are cut short with a small `LD_PRELOAD` shim, compiled on the host for the guest (aarch64 and x86_64, a few KB). It caps `nanosleep`/`clock_nanosleep` at 50 ms. **If the shim is more than I can build reliably, Python and Perl sleeps stay as they are, and the report says the run may have been outwaited.**
- New rule: `waits-before-acting` (medium), for a sleep of 60 s or more in total. Waiting out a sandbox is evasion in itself.
- The chamber also stops refusing Python and Perl scripts (`#!/usr/bin/env python3`, `perl`). Both interpreters are already in the image.

## 3. `.pkg` installer scripts
`macx chamber run Installer.pkg` expands the package on the host with `pkgutil --expand`, which reads only, and finds the `preinstall` and `postinstall` scripts (and the ones in each component package). It runs each in the chamber the way Installer does:
- as root, which is fine in the VM;
- with `$1` = the package path, `$2` = `/Applications`, `$3` = `/`;
- with `INSTALLER_TEMP` and `PACKAGE_PATH` set.

The payload's file list is placed in the image as empty files, so scripts that `cp` from it don't fail early. Anything in a package that isn't a script (Mach-O helpers, apps) can't run; the report says so, and the static checks still apply. A package's script verdict sits next to `macx check`'s verdict for the same file.

## 4. Testing the chamber with Atomic Red Team
GitHub's Apple-silicon runners can't start a VM inside their own VM, so this runs on the Mac. That's safe, because each test runs inside the throwaway chamber VM, which has no network, sees only the bait home folder and is deleted afterwards.

`scripts/eval/chamber-art.sh`:
- takes the same pinned atomics (`a0e3f9bc69fe`) and the same test list (`art-tests.txt`);
- writes each test's command, with its default inputs filled in, to a script;
- runs it with `macx chamber run`;
- records the verdict and rules;
- writes `research/evaluation/chamber-art-results.md`.

Chamber expectations go in a new column of `art-tests.txt`, written before the first run, like the watch's. The chamber should do best where the watch is weakest: it sees every file a script opens, so the keychain and browser tests should be caught.

## Build order
1. Python and Perl allowed, and the sleep stand-in (small).
2. The fake-internet recorder plus `uploads-stolen-data`, then `--follow`.
3. `.pkg` scripts.
4. The Atomic Red Team run for the chamber, then fixing what it misses.
5. The `LD_PRELOAD` sleep shim, last, because it's the riskiest.

Each step is test-first (CPIO image contents, the stand-ins' records, verdict rules) and gets a real boot on the Mac. CHANGELOG, README (*Detonation chamber*) and STATUS are updated as each step lands.

## What needs Lao
Nothing to set up. `--follow` contacts the attacker's server only when you ask for it on a given run.
