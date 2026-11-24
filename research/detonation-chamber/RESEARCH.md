# Research: Detonation chamber (run a suspicious file somewhere safe, judge it, quarantine it)
**Date:** 2026-11-24
**Status:** Complete. Approved 2026-11-24, then changed to the light chamber (below) the same day.
**Researcher:** Claude Code

## Question
Lao's idea, 2026-11-24: give a script or file a scratch place to run. If it acts like malware there, Macximesed notices, flags it and quarantines it. How do we do that on macOS 27 (Apple silicon) without ever putting the real Mac or the user's data at risk?

## Context
- **What macx does now:** it judges a file or pasted script *without running it* (`macx check`, `macx guard inspect`: 17/17 simulated attacks flagged). It also watches what *does* run on the real Mac (`macx watch`, `macx daemon`).
- **What's missing:** a way to see behaviour that only shows when the thing runs, such as a packed binary, code fetched at run time, or a script that only does damage after a delay. Today, the only way to see that is to run it on the real Mac, which is the thing we're protecting.
- **The constraint:** anything we build has to survive *real* malware being run inside it, because that's the whole point.

## Findings

### Internal
- **Rules:** `WatchRules` (Sources/MacxCore/Watch.swift) already turn eslogger events into alerts, and `ScriptInspector` already scores what a script does. A chamber can reuse both: the guest only has to collect eslogger JSON, and the host judges it.
- **Quarantine:** `IncidentRecorder` and `IncidentContainment` (Sources/MacxCore/Incident.swift) already make a case folder with read-only copies and hashes, and move items into the undo store. "Quarantine" can be exactly that, plus keeping the `com.apple.quarantine` flag on.
- **Fetching:** `PasteInspector` already fetches what a pasted link serves and pins it by SHA-256 (`VerifiedCopy`), so the exact inspected bytes are what would be detonated.
- **Packaging:** Package.swift has one dependency (swift-argument-parser). Adding Tart or anything else is a new external dependency, which needs Lao's OK.

### External
- **sandbox-exec (Seatbelt) is deprecated and undocumented.** Developer reports from 2026 say custom profiles still work, but Apple says the profile language was never documented for third parties. The macOS 27 SDK tightens `sandbox_init` (named profiles must not be used). It's a best-effort restriction, not a security boundary for hostile code (gastown.dev research note 2026; OpenSSH list, Aug 2026; Apple forums).
- **A separate throwaway user account isn't isolation.** The program still runs on the real kernel with the real network, can try local privilege escalation, and can read anything world-readable. (Reasoning; no source needed.)
- **A macOS virtual machine is the real boundary.** Apple's Virtualization framework runs macOS guests on Apple silicon:
  - the license allows **two macOS VMs at once**, enforced by the framework;
  - a reported 26.5 bug leaves the slot counter stuck until reboot after a guest-initiated shutdown;
  - save/restore of VM state exists, so a clean snapshot can be resumed quickly;
  - it needs the `com.apple.security.virtualization` entitlement. Reports suggest ad-hoc signing works for that one (unlike `com.apple.vm.networking`), but that's unconfirmed. It must be tested with our self-signed app.

  (Eclectic Light 2022 and 2026; Apple forums; Apple Virtualization docs.)
- **AMOS checks for VMs and exits.** Samples run `system_profiler` through osascript, compare hardware strings against "Apple Virtual Machine", QEMU, VMware, Parallels and so on, and quit before the payload if one matches. Splunk has a detection for exactly that command pattern (Sophos 2025/26; Splunk research; Medium analysis). So a VM chamber will see some stealers do *nothing*. **The VM check itself is the tell**, though: a script that asks "am I in a VM?" and stops is suspicious on its own.
- **Real-world sandboxes:**
  - **ANY.RUN** added macOS VMs (beta, Enterprise). It stresses *interactive* analysis, because macOS malware often waits for a password prompt to be answered (ANY.RUN blog 2026).
  - **Tart** (cirruslabs) does clone, run and delete of macOS VMs on Apple silicon, with copy-on-write clones. Its license is in flux: Fair Source 0.9 with a single-person exemption, and reportedly moving to FSL/Apache after OpenAI acquired Cirrus Labs in April 2026.
  - No open-source macOS malware sandbox built on either turned up.

## Sources
| Source | URL | Key takeaway |
|---|---|---|
| Eclectic Light (2022) | https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/ | Two macOS VMs at once, by licence and kernel quota |
| Eclectic Light (2026-04) | https://eclecticlight.co/2026/04/29/virtualisation-on-apple-silicon-macs-is-different/ | Current state of macOS virtualisation |
| Apple forums: macOS 27 EULA, more than 2 VMs | https://developer.apple.com/forums/thread/845455 | Cap enforced for Mac guests only |
| Apple: running macOS in a VM | https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine | Restore image to installed guest |
| Apple forums: virtualization entitlement | https://developer.apple.com/forums/thread/698220 | Entitlement needed; ad-hoc signing unclear |
| Apple forums: com.apple.vm.networking | https://developer.apple.com/forums/thread/729686 | Bridged networking needs a restricted entitlement (NAT doesn't) |
| sandbox-exec research note | https://gastown.dev/docs/research/macos-sandbox-exec | Works in 2026 but deprecated and undocumented |
| OpenSSH list (Aug 2026) | https://lists.mindrot.org/pipermail/openssh-unix-dev/2026-August/042690.html | SDK 27 tightens sandbox_init |
| Apple forums: replacing sandbox-exec | https://developer.apple.com/forums/thread/661939 | No supported way to define a custom sandbox |
| Sophos: why AMOS matters | https://www.sophos.com/en-us/blog/why-amos-matters-the-macos-malware-stealing-data-at-scale | AMOS uses system_profiler checks to evade sandboxes |
| Splunk AMOS analytics | https://research.splunk.com/stories/amos_stealer/ | Detects osascript + system_profiler + VM strings |
| ANY.RUN macOS sandbox | https://any.run/cybersecurity-blog/anyrun-macos-sandbox/ | Interactive analysis; stealers wait for a password |
| Tart guide | https://www.starryhope.com/mac/tart-macos-linux-vms/ | Copy-on-write clones for throwaway VMs |
| Tart license | https://www.github.com/cirruslabs/tart/blob/main/LICENSE | Fair Source 0.9 (re-check: reportedly changing) |

## Recommendation
**Build the chamber as a disposable macOS virtual machine, driven by macx itself through Apple's Virtualization framework.** Don't use sandbox-exec or a separate user as the boundary for real malware: neither is one.

How it would work:
1. **`macx chamber setup`** (once, about 30–60 min, tens of GB):
   - downloads Apple's macOS restore image and installs a guest;
   - you click through Setup Assistant once in a window macx shows (automating that is fragile);
   - macx puts a small guest agent in it, gives the agent Full Disk Access inside the guest, and saves a **clean snapshot**.
2. **`macx chamber run FILE`**:
   - restores the clean snapshot, with **no network by default**, and puts the exact file (pinned by SHA-256) into an empty shared folder;
   - the agent runs it while eslogger records, for 60 s by default;
   - the agent writes the event log back, and the VM is thrown away. Nothing persists.
3. **The host judges**, treating the guest's log as untrusted data:
   - the same `WatchRules` and `ScriptInspector` as the live watch, plus new chamber rules: a VM check followed by an early exit, writes to launch folders, keychain or browser-data access, password prompts, outbound connection attempts;
   - verdict: *DON'T OPEN THIS*, *Be careful*, *Nothing seen* (never "safe": evasion is real).
4. **Quarantine on a bad verdict:** the original file moves into a new incident case (read-only copy, hashes, the chamber's timeline). It stays in the undo store, so it's restorable and nothing is deleted. `guard inspect` and `check` can offer "run it in the chamber" when the verdict is *partly unknown*.

**Also worth doing on its own, and cheap:** add the VM check as a static and live rule now (`system_profiler` plus VM-name strings in osascript or shell). It catches AMOS before any chamber exists.

**Phases:**
- **Phase 1:** VM boot, snapshot, file in, log out, verdict, quarantine. No network, no interaction.
- **Phase 2:** fake password answers (canary credentials) so stealers keep going, and a fake-internet sink so stage-2 downloads are seen without real internet.
- **Phase 3:** hide VM tells, as far as the framework allows.

## Test plan sketch
- [ ] `ChamberVerdict` from a fixture event log: a fake-Apple LaunchDaemon write gives *DON'T OPEN THIS*; an empty log gives *Nothing seen* (never "safe").
- [ ] A VM check followed by exit within N seconds gives *Be careful*, rule `vm-check-then-quit`.
- [ ] The guest log is untrusted: oversized, malformed or path-traversal entries are dropped, never followed.
- [ ] Quarantine moves the original into an incident case with a matching SHA-256, and `macx undo restore` brings it back.
- [ ] A changed file (SHA-256 mismatch since inspection) is refused before the VM starts.
- [ ] The static VM-check rule flags `osascript -e 'do shell script "system_profiler SPHardwareDataType"' | grep -i "virtual"`.

## Risks & unknowns
- **Guest-to-host escape:** a Virtualization-framework escape would be a serious Apple bug, rare but possible. Mitigations: no network, no shared folders apart from one empty, single-use folder, and the guest's output parsed strictly as data.
- **Evasion:** VM checks, sleeping longer than the run, waiting for a click or a password. A clean result can't mean safe, and the wording must say so.
- **Entitlement:** does `com.apple.security.virtualization` work with our self-signed "Macximesed Local Signing" app? Untested; it's the first thing to try.
- **Setup:** unattended macOS guest setup (Setup Assistant) is hard, so one manual click-through is planned. Restore image size and download time are unverified.
- **Two-VM limit:** shared with anything else Lao runs (UTM, CrossOver doesn't count). A stuck-slot bug means a reboot may sometimes be needed.
- **Disk and time:** a guest takes tens of GB, a run takes about a minute plus restore time. Fine on demand, not for every download.
- **Network:** keeping it off loses stage-2 behaviour. Turning real internet on would let real malware exfiltrate from the VM and attack others, so never by default.
- **Legal:** running macOS in a VM on Apple hardware is within the licence (two VMs).

## Next steps
- [ ] Lao approves (or changes) the approach.
- [ ] Spike: does a self-signed macx with `com.apple.security.virtualization` boot a macOS guest? Measure restore image size and setup time.
- [ ] Write `specs/detonation-chamber.md`, then TDD Phase 1, starting with the host-side verdict and quarantine on fixture logs (no VM needed for those tests).
- [ ] Ship the static and live `vm-check` rule on its own first.

## Update 2026-11-24: the light chamber (what we're building)
Lao: "25.6 make it like 4 gigs bro like thats to huge". A macOS guest can't be that small: the restore image alone is 25.6 GB (spike), and Lao's Mac has 31 GB free. Lao chose the **light chamber**: a tiny Linux VM under the same Virtualization framework (same isolation boundary), well under 4 GB.

**What it can run:** scripts (shell, zsh, python, perl, osascript-style pastes), which is AMOS's entry route. Mac-only commands are replaced by recording stand-ins (stubs): `osascript`, `security`, `dscl`, `system_profiler`, `sw_vers`, `launchctl`, `xattr`, `codesign`, `spctl`, `open`, `killall`, `defaults`, `ditto`, `hdiutil`, `sysctl`, `ioreg`, `curl`, `wget`. **What it can't run:** Mac apps and Mach-O binaries. Those keep the existing static checks, and the full macOS chamber stays possible later (external disk).

**Facts checked (2026-11-24):**
- **Alpine:** latest stable 3.24.4. `alpine-minirootfs-3.24.4-aarch64.tar.gz` is 4.0 MB (official `latest-releases.yaml`).
- **Packages** (v3.24 APKINDEX, download / installed): linux-virt 6.18.65 41.8 / 73.4 MB, bash 0.5 / 3.6, zsh 1.6 / 5.9, strace 0.5 / 1.2, python3 8.4 / 26.4, perl 10.1 / 41.8.
- **Total:** about 70 MB of downloads and about 100 MB on disk, since only the kernel and a few modules are kept.

**Boot design:**
- `VZLinuxBootLoader` with the kernel and an initramfs that macx builds per run (Alpine minirootfs, packages, stubs, agent, the sample). No disk, no network device, no shared folder. The log comes out over a virtio console port.
- arm64 kernels have no compressed format of their own; a distro `vmlinuz` may be gzip or EFI-zboot wrapped and must be unwrapped to a raw `Image`. Use a 4K-page kernel: 64K pages fail under VZLinuxBootLoader (Apple forums).

**Watching:**
- Inside the guest, `strace -f` records execve, openat, renameat, unlinkat and connect for the sample's tree. Each stub also writes a JSON line.
- The host turns both into the same events the chamber judge already understands (exec, open, create, rename), plus `connect` for network attempts.

**A fake Mac inside:** `/Users/chamber` with canary files (a `login.keychain-db`, Chrome `Login Data`, an Exodus wallet), `/Library/LaunchDaemons`, `/Applications`. `uname`, `sw_vers` and `sysctl hw.model` answer like a real Mac (Mac15,3), so scripts take their Mac paths.

**Supply chain:**
- Every downloaded file is pinned by SHA-256 in `data/chamber/manifest.json` (Alpine release URLs) and checked before use.
- An update means re-pinning in a reviewed commit.

| Source | URL | Key takeaway |
|---|---|---|
| Alpine latest-releases.yaml | https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/latest-releases.yaml | 3.24.4, minirootfs 4.0 MB with SHA-256 |
| Alpine v3.24 APKINDEX | https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/APKINDEX.tar.gz | Package versions and sizes |
| Kernel EFI stub doc | https://docs.kernel.org/admin-guide/efi-stub.html | arm64 `Image` is uncompressed |
| unzboot | https://github.com/wavevector/unzboot | Distro kernels may be EFI-zboot wrapped |
| Apple forums: 64K kernel | https://developer.apple.com/forums/thread/780165 | 64K-page kernels fail under VZLinuxBootLoader |
| Lima PR 2562 | https://github.com/lima-vm/lima/pull/2562 | VZLinuxBootLoader gives the guest no EFI |
