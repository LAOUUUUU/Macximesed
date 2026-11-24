# External research: a beta channel of dev-branch builds identified by commit
**Date:** 2026-11-24

Question: how can Macximesed (`macx`) add a beta update channel that installs builds from `dev`, where dev builds are identified by their git commit instead of a version number, without weakening the signed stable channel?

Context taken from this repo (read, not changed): `.github/workflows/release.yml` builds on `v*.*.*` tags and calls `.github/workflows/channel.yml`. That workflow builds `channel/v1.json` from `site/` plus the live file, signs it in the `release` environment, and deploys the whole `out/` folder with `actions/deploy-pages`. In `Sources/MacxCore/Update.swift`, `ChannelVerifier` accepts a signature from any key in `UpdateKeys.trusted`, `UpdateState.lastSequence` is one global number, and `SemVer` parses `-pre` but has no handling for `+build`.

---

## Key findings

### 1. How real projects ship tip, nightly and beta builds

| Project | How builds are identified | How "newer" is decided | How users switch, and how they go back |
|---|---|---|---|
| **Ghostty "tip"** (macOS, Sparkle) | `CFBundleVersion` = `git rev-list --count HEAD`. `CFBundleShortVersionString` = short commit. Plist key `GhosttyCommit` = short commit. The appcast shows `"<commit> (<date>)"`. Each download sits under a directory named for the full commit (`tip.files.ghostty.org/<commit_long>/Ghostty.dmg`). | Sparkle compares `sparkle:version`, which is the commit count. Stable releases use the same commit-count build number, so tip and stable sort on one axis. | Config `auto-update-channel = tip`, which takes effect after a restart. Switching back to `stable` "will only take effect when a later stable release is available"; to downgrade you re-download. Each channel has its own appcast file instead of using Sparkle's in-feed channels. |
| **Sparkle channels** | Items carry `<sparkle:channel>beta</sparkle:channel>`. The display string (`shortVersionString`) is separate from the machine version. | `sparkle:version` / `CFBundleVersion`, compared with `SUStandardVersionComparator`. That comparator splits strings into numeric and text chunks and **stops at the first dash**, so a `-beta` suffix is dropped. Sparkle says the internal version is "not generally suitable for formatted text or git changeset IDs". | The `allowedChannels(for:)` delegate returns extra channels. "The default channel is always included", so beta users still see stable releases. There is no documented downgrade path, and the comparator "may be used during installation for preventing a downgrade". |
| **Zed nightly/preview** | Nightly version = `<version>+nightly[.<build_id>].<sha>` (semver build metadata). Preview is a separate app installed alongside stable. | Stable and preview compare versions with pre-release and build metadata stripped. **Nightly compares commit SHAs: any SHA that differs from the running app's is an update.** There is no ordering; it trusts the server. | Separate installs per channel. The channel is compiled in (`RELEASE_CHANNEL` file). |
| **Neovim nightly** | `NVIM v0.13.0-dev-2182+g6501a7547d`: the *next* minor version, `-dev`, commits since the tag (`git describe --first-parent --dirty --always`), then `+g<hash>`. | The commits-since-tag count orders builds, and the next-version base sorts dev builds above the last release. | One rolling GitHub prerelease tag `nightly`, built daily by cron. Each run deletes the old release and tag (`gh release delete nightly --yes`, `git push … :nightly`) and recreates them with `--prerelease --target $GITHUB_SHA`. |
| **VS Code Insiders** | Separate app ("Runs next to the Stable build"), new builds daily. The client sends its **commit** to `…/api/update/<platform>/<quality>/<commit>`. | **Server-side**: the server replies 204 when no update exists, and the client never orders commits itself. `quality` is `stable`, `insider` or `exploration`. | Install the other app. |
| **Homebrew `--HEAD`** | The keg version is `HEAD-<sha>_<revision>`. | "Outdated" means installed commit `!=` upstream last commit, checked only with `--fetch-HEAD`. Without that flag, HEAD is only re-checked when a new stable version ships. | `brew install --HEAD` / `brew upgrade --fetch-HEAD`. Switching back means reinstalling stable. |
| **Firefox Nightly** | Version `NNN.0a1` plus a 14-digit timestamp **buildID** (`YYYYMMDDHHMMSS`, e.g. `125.0a1` / `20240229093832`) sent in the update URL. | The update server (Balrog) decides, using channel rules and buildID. | The channel is baked into the build. **Each channel embeds different update-signing (MAR) certificates**: `release_primary.der` for beta, release and esr, `nightly_aurora_level3_primary.der` for nightly. So nightly keys are never trusted by release builds. |

Takeaways:
- **A commit alone cannot be ordered.** Every project that orders dev builds pairs the commit with a monotonic number: a commit count (Ghostty, Neovim), a timestamp (Firefox), or a build ID (Zed). The projects that use only the commit (Zed nightly, VS Code, Homebrew HEAD) treat "different from mine" as "update" and rely on a trusted server.
- **Going back to stable is nearly always "wait for the next stable"**, because updaters refuse to downgrade. An explicit reinstall is the escape hatch (Ghostty, Homebrew, VS Code).
- **Channel separation by key exists but is not universal.** Firefox gives nightly and release different signing keys and bakes them in per channel. Ghostty signs tip and stable with the *same* Sparkle key from plain repository secrets: `PROD_MACOS_SPARKLE_KEY`, no `environment:`.

### 2. Signing tradeoff

**Option A: every dev publish needs the maintainer's approval in the existing `release` environment (stable key).**
- Every push needs a click, and the approval is a rubber stamp: the reviewer approves the job, not a diff.
- **It is dangerous if the beta job reuses the stable key.** The job's steps come from the workflow file *in the pushed dev commit*. So one approval of a malicious dev commit can print or exfiltrate the **stable** key, which compromises every user. GitHub: "Any user with write access to your repository has read access to all secrets configured in your repository", and a compromised action "would have access to all secrets".

**Option A′: a separate beta key in a separate `beta` environment *with* a reviewer.**
- Keeps the human gate without exposing the stable key.
- Pending approvals can wait. The workflow run limit is 35 days, "includes … time spent on waiting and approval". With concurrency, newer pending runs replace older pending ones, so the maintainer can approve "the latest" whenever convenient.

**Option B: a separate beta key in an environment with no reviewer, restricted by deployment branch policy.**
- Environments support "Selected branches and tags", with patterns matched against `GITHUB_REF`. If the ref does not match, "the job will fail and the run will stop", and environment secrets only go to jobs that reference the environment and pass its rules.
- Attacks it allows:
  - Anyone who can push to the allowed branch can run arbitrary steps with the beta key, because the workflow file itself comes from that branch.
  - A malicious merged PR or a compromised dev branch ships a signed malicious build to beta users *automatically*, and can exfiltrate the beta key.
  - A compromised action dependency in that job can steal the key. This is the tj-actions/changed-files pattern of March 2025: secrets dumped from workflow runs, and CISA said to "Rotate all identified secrets immediately".
- Blast radius: only opted-in beta users, **if** stable clients never trust the beta key (see the design section).

**Option C: keyless provenance (GitHub artifact attestations / Sigstore).**
- Current action: `actions/attest@v4`. The latest release is v4.2.2; its date shows as "04 Aug" with no year, and the ordering implies 2026.
  - Since v4, `actions/attest-build-provenance` "is simply a wrapper on top of actions/attest", and "new implementations should use `actions/attest`".
  - Permissions: `id-token: write`, `attestations: write`, `artifact-metadata: write`.
  - Public repos use the **public-good Sigstore** instance, and attestations are free for public repos on all plans.
- Verification: `gh attestation verify <file> -R owner/repo`. Pin the identity with `--signer-workflow`, `--source-ref` and `--cert-oidc-issuer`, and use `--deny-self-hosted-runners`.
  - Offline verification is supported (`gh attestation trusted-root`, `--bundle`, `--custom-trusted-root`).
  - The trusted root "does not have a built-in expiration date", "You will not know if key material has been revoked", and Sigstore keys rotate "a few times per year".
- **For a Swift client, it is neither cheap nor offline:**
  - I found no Swift Sigstore verifier; the searches surfaced Go, Rust, JS, Python, Dart and PHP clients only.
  - Verifying means: establishing signing time (Rekor `integratedTime` or an RFC 3161 TSA), X.509 path validation to the Fulcio root *at that time*, the SCT check, the issuer OID `1.3.6.1.4.1.57264.1.8` and SAN policy, DSSE signature verification, and tlog entry checks. That is per the Sigstore client spec.
  - The bundle comes from `GET /repos/{owner}/{repo}/attestations/sha256:<hex>`, whose docs say "The authenticated user making the request must have read access".
- What it does *not* give:
  - Rollback or freeze protection, or "which build is latest". It signs artifacts, not channel state.
  - Protection against a malicious dev commit, which gets a perfectly valid attestation "built by workflow X from refs/heads/dev".
- What it does give:
  - No long-lived key to steal.
  - A public transparency-log record of every beta build, which the maintainer and users can audit with `gh`.

**Limiting a beta key's blast radius.** The pattern follows TUF's "compartmentalized trust" and its rule that keys "used online or in automated workflows should not endanger clients" if compromised.
- Ship the beta public key in a *separate* trust list that is accepted only for beta-channel files.
- Have stable clients never fetch or evaluate beta files.
- Never let a beta file carry a security floor or the hash feed.
- Firefox does the same by compiling different MAR certs per channel.

### 3. GitHub specifics as of 2026-11

**Environment branch and tag policies**
- Modes: "No restriction", "Protected branches only", "Selected branches and tags".
- Wildcards don't match `/`. Branch and tag rules are configured separately (REST: `POST …/environments/{env}/deployment-branch-policies` with `{name, type: branch|tag}`, which needs `custom_branch_policies: true`).
- These policies are available for all public repos. Required reviewers (up to 6, one approval suffices, optional "prevent self-review") are available for public repos on Free.
- The 2021 changelog says that when `github.ref` does not match, "the job will fail and the run will stop".

**What `GITHUB_REF` is per event, which is what the policy matches**
- `push`: the pushed ref.
- `workflow_dispatch`: the chosen branch.
- `schedule`, `workflow_run` and (since 2025-12-08) `pull_request_target`: **the default branch**.
- `pull_request`: `refs/pull/<n>/merge`.
- Since 2025-12-08, "environment branch protection rules will evaluate against the execution reference (GITHUB_REF)".
- So yes: a reviewer-less environment with policy `dev` hands its secrets only to runs whose ref is `refs/heads/dev`. In practice that means pushes to dev and manual dispatches on dev.
- Fork PRs can't match `dev`. But **any workflow file on dev** that references the environment gets the secret, including one added in that same push.

**`deployment: false`** (late March 2026) lets a job use an environment's secrets without creating a deployment record.
- Reviewers and wait timers still apply.
- Custom protection rules make the job fail.
- The docs mention restricting secrets by branch as a use case, but the rules table **does not confirm branch policies are enforced with `deployment: false`**. Don't rely on it for the beta key until tested.

**Workflow execution protections** (GA 2026-09-17)
- Repository-level actor and event allowlists, with workflow-file targeting and evaluate/active modes.
- `pull_request_target` has been blocked by default in public repos since 2026-12-02 (moved from 2026-11-02).
- Useful to limit the beta workflows to `push` by the maintainer. But a policy scoped to a file path doesn't cover a *new* workflow file that references the same environment.

**Supply chain**
- An admin policy can require SHA pinning (2025-08-15); workflows using unpinned actions "will fail".
- **Actions lockfiles** (`.github/workflows/actions.lock`, `gh actions-lock`) went GA on 2026-10-28. They pin transitive dependencies of composite actions too, and a "Require lockfile" policy exists. The `secure-use` doc notes a lockfile "supersedes SHA pinning".

**Actions artifacts vs releases**
- Artifacts are kept 90 days by default (`retention-days` 1–90).
- The artifact URL "only works for users who are logged in", and the REST download redirect expires after 1 minute. **That rules artifacts out as an anonymous updater source.**
- Release assets: "Up to 1000 release assets", each "under 2 GiB", "no limit on the total size of a release, nor bandwidth usage". Prereleases don't count for `/releases/latest`.
- A rolling prerelease works the way Neovim and Ghostty do it (delete and recreate, or `git tag -fa tip` plus `git push --force`). `gh release upload --clobber` "deletes … before new assets are uploaded", which leaves a gap if the upload fails.

**Immutable releases** (GA 2025-10-28)
- Once published, assets "can't be added, modified, or deleted". The tag can't move or be deleted while the release exists. A deleted immutable release's tag "cannot reuse the same tag name".
- Existing releases stay mutable unless republished.
- **A rolling, asset-replacing `dev` prerelease is incompatible with immutable releases.**
- Immutable releases also get an automatic release attestation.

**GitHub Pages**
- One site per repo.
- `deploy-pages` deploys "a Pages site previously uploaded as an artifact". The artifact is a gzip'd tar, under 10 GB, with no links.
- The published site must be 1 GB or less, and a deployment must finish within 10 minutes. The 10-builds-per-hour limit does not apply to custom Actions workflows.
- Each deploy replaces the whole site. That is my inference: the docs describe the artifact *as* the site, and no merge behaviour is documented.
- A deploy while another is in progress fails with "Deployment request failed … due to in progress deployment. Please cancel … first or wait".
- The `github-pages` environment carries its own deployment branch rule. "Branch "x" is not allowed to deploy to github-pages due to environment protection rules."
- **Concurrency**: group names are repo-wide across workflows. The default `queue: single` keeps one pending run and cancels older pending ones. `queue: max` keeps up to 100 pending and can't be combined with `cancel-in-progress: true`.
- So if a stable channel workflow and a beta workflow both deploy Pages, each must (a) rebuild the *whole* site, including the other channel's current files byte-for-byte, and (b) share one concurrency group with `queue: max` and `cancel-in-progress: false`. Otherwise one cancels or overwrites the other.

### 4. Encoding the commit into a SwiftPM-built binary

- **Swift `-D` / `SwiftSetting.define` carry no value.** The doc says: "Unlike macros in C/C++, compilation conditions don't have an associated value." You can flag `#if MACX_BETA`, but you can't pass a SHA that way.
- **Option 1: generated source file** (most common, no tooling). CI rewrites a tracked placeholder, e.g. `BuildInfo.swift`, with the version, commit, channel and build number before `swift build`. Local builds keep the placeholder (`commit = nil`, channel `local`). The Swift Forums thread on build-time config leans this way: "I am leaning towards code generation since it seems more flexible".
- **Option 2: `Context.gitInformation` in `Package.swift` plus a tiny C target.**
  - `Context.gitInformation` (PackageDescription 6.0+; macx uses tools 6.0) gives `currentTag`, `currentCommit` and `hasUncommittedChanges`.
  - `CSetting.define(_:to:)` *does* take a value.
  - swift-testing does exactly this: `.define("SWT_TESTING_LIBRARY_COMMIT_HASH", to: #""\#(git.currentCommit)""#)`, with a fallback to `Context.environment["GITHUB_SHA"]`.
  - No file mutation, and it works for local builds, but it adds a C target. Whether manifest caching can leave a stale commit is unverified.
- **Option 3: a build-tool plugin** (e.g. DimaRU/PackageBuildInfo 1.0.4, 2024-11-14: commit, tag, count, dirty, timestamp).
  - It adds an external dependency, and plugins run sandboxed with writes limited to their work directory.
  - The Swift Forums thread (Jan 2025, revived Sep 2026) shows there is still no built-in way.
- **Option 4: embed an Info.plist into the CLI** with `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker <file>` via `unsafeFlags`. This works on macOS only and makes the product unusable as a dependency. It isn't needed here.
- **Shallow clones break counts.** `actions/checkout` is shallow by default. Ghostty uses `fetch-depth: 0`, with the comment "Important so that build number generation works".
- **What `--version` should print.** Projects print the semver-ish string with the commit inside: Neovim `v0.13.0-dev-2182+g6501a7547d`, Zed `x.y.z+nightly.<sha>`. Ghostty shows the short commit as the display version and keeps a numeric build number underneath.

---

## Current best practices
- Give dev builds a **pre-release of the next version** plus build metadata, e.g. `0.3.1-dev.412+g1a2b3c4d5e6f`.
  - This sorts above the last release (`0.3.0`) and below the next one (`0.3.1`, `0.4.0`), so beta users move to the next stable automatically.
  - SemVer rule 10: "Build metadata MUST be ignored when determining version precedence".
- Order builds by a **monotonic number**, not by the SHA. The SHA is identity; the number is order.
- Use **one signed channel file per channel at its own URL** (Ghostty), with its own sequence and expiry.
- **Separate keys per channel, and stable builds never trust the beta key for stable decisions** (Firefox MAR certs, TUF compartmentalized trust).
- **Beta users also see stable** (Sparkle: the default channel is always included), and the stable security floor applies to them.
- **No automatic downgrades.** Leaving beta takes effect when a newer stable exists (Ghostty, Sparkle). Any reinstall of an older stable is explicit.
- Keep the job that holds a signing key **minimal**: no third-party actions beyond pinned first-party ones, no running project code or tests, minimal `permissions:`.
- Pin actions to SHAs (macx already does) and consider a lockfile.
- Publish dev builds as **release assets**, not Actions artifacts. Use unique per-commit asset names and prune old ones; Ghostty keeps the last 15 appcast entries.

## Breaking changes / gotchas
- **Never add the beta key to `UpdateKeys.trusted`.** `ChannelVerifier` accepts any key in that list for any file, so a stolen beta key could then sign *stable* `channel/v1.json`, including floors and the hash feed.
- **The `SemVer` parser in `Update.swift` does not strip `+build`.**
  - `0.3.1-dev.100+gabc` parses pre as `["dev","100+gabc"]`, `Int()` fails, and comparison falls back to lexical order. So `dev.100+…` sorts *below* `dev.99+…`.
  - Strip metadata for ordering. Compare the full string, commit included, for the installer's "reported version matches the signed file" check.
- **`UpdateState.lastSequence` is global.** A beta file with a high sequence would make every later stable file look like a rollback, or the reverse. Keep one sequence per channel.
- **`git describe` depends on reachability.** Tags are made on `main`. If `dev` doesn't contain the newest tag commit, describe falls back to an older tag. Dev builds then sort below the newest stable, and beta users never get dev builds again. Take the base from the highest `v*` tag in the repo (or from the stable channel's `latest.version`), not from describe.
- `git rev-list --count` goes **down** after a force-push or history rewrite. `github.run_number` only goes up, but it resets if the workflow file is renamed, and a re-dispatch of an old commit gets a *higher* number. So publish only when the built SHA is still `dev`'s tip, and refuse versions not newer than the previously published beta.
- **`schedule`, `workflow_run` and `pull_request_target` run on the default branch.**
  - A scheduled "re-sign to refresh expiry" job cannot use a `dev`-only environment.
  - A `workflow_run`-triggered signing job needs the environment policy to allow `main`.
  - `workflow_run` also fires after fork-PR runs, so filter on `event == 'push'`, `head_branch == 'dev'` and `head_repository.full_name == github.repository`.
- **Hosting the beta file on Pages** means adding `dev` to the `github-pages` environment. Every dev push can then replace the *entire* site. It can't forge the stable file, but it can withhold it or serve an older signed one (freeze until `expires`; fresh installs with sequence 0 would accept an older unexpired file). It also creates the concurrency and whole-site rebuild problems above.
- **Immutable releases**, if enabled now or later, break a rolling `dev` prerelease (assets and tag locked, tag names never reusable).
- Release download URLs for a rolling tag change content under clients: a client can read the JSON, then fetch a replaced tarball and get a hash mismatch. Use unique asset names per commit.
- Write access to the repo means read access to its secrets. A reviewer-less environment protects the key only as well as the allowed branch's push rules do.

## Unverified
- Whether environment deployment-branch policies are enforced for jobs using `deployment: false`. The docs list it as a use case but don't state it in the rules table.
- Whether immutable releases treat prereleases differently. The docs don't single them out.
- Whether unauthenticated clients can read `GET /repos/{owner}/{repo}/attestations/{digest}` for a public repo. The docs say "authenticated user".
- That no Swift Sigstore verification library exists. Several searches surfaced none, which doesn't prove absence.
- The exact years of `actions/attest` releases. The page shows day and month only; v4.0.0 on "25 Feb" is consistent with a March 2026 Dependabot bump.
- Apple's current format rule for `CFBundleShortVersionString`. The Apple page didn't render. Ghostty's notarized tip builds set it to a bare commit hash, so a non-numeric value works in practice. Whether `0.3.1-dev.N+g…` causes problems in Finder or LaunchServices for the app bundle wasn't tested.
- Whether a Pages deploy replaces the whole site. This is inferred and strongly implied, but not stated.
- Firefox's `-allow-downgrade` flag and Firefox 67 downgrade protection. Seen only in search snippets; the Mozilla support and wiki pages didn't load.
- Whether `Context.gitInformation` is re-read on every build or cached with the manifest.
- Whether workflow execution protections can be configured at repository level on a Free-plan public repo. The doc lists the repository settings path but not plan availability.

---

## What this means for macx

### Recommended design

1. **Version identity for dev builds**
   - `macx --version` prints one line: `<base>-dev.<N>+g<sha12>`, e.g. `0.3.1-dev.412+g1a2b3c4d5e6f`.
   - `base` is the highest released `v*.*.*` tag with the patch bumped by one, taken from `git tag --sort=-v:refname`, not from `describe`.
   - `N` is the beta build workflow's `github.run_number`. Commit count with `fetch-depth: 0` also works; see decision 3.
   - Stable builds stay `0.3.0`.
   - A second form (`macx version --verbose`, or `--version` plus a flag) shows the full 40-char commit, the channel (`stable`, `beta` or `local`), the build time and the workflow run URL. The installer keeps reading the single-line form.
2. **Embedding.** CI stamps a tracked `BuildInfo.swift` (placeholder values for local builds) right before `swift build`. This needs no new dependency, no unsafe flags and no plugin sandbox. The swift-testing pattern (`Context.gitInformation` plus a C target with `cSettings.define`) is the fallback if you don't want CI rewriting a file.
3. **A separate beta channel file**
   - `{"schema":1, "channel":"beta", "sequence", "published", "expires", "latest":{"version","commit","url","sha256","notes"}}`.
   - Own sequence. Short expiry (e.g. 14–30 days).
   - **No `minimumSafe` and no `hashFeed`**: the client ignores or rejects them on the beta role. The stable file stays exactly as it is.
4. **Hosting.** Put the beta file, its `.sig` and per-commit tarballs (`macx-dev-<sha12>-macos-universal.tar.gz`) on a **rolling `dev` prerelease**, pruned to the last ~15 builds. Pages and the `github-pages` environment stay untouched, so dev can never overwrite the stable site. This requires immutable releases to stay off; see decision 2.
5. **A separate beta key with roles in the client**
   - `UpdateKeys.stable` and `UpdateKeys.beta` are separate lists.
   - `ChannelVerifier` takes a role. Stable accepts only stable keys, and requires `channel` to be absent or `"stable"`. Beta accepts only beta keys and requires `channel == "beta"`.
   - For stronger domain separation, sign `"macx-channel-v1:<role>\n" + json` rather than the bare JSON. For stable, that is a format change that needs a migration.
   - Beta files are fetched and evaluated only after the user has opted in. Stable-only users never touch them.
6. **Two workflows, so dev commits can't edit the signing steps**
   - **`beta-build.yml`** runs on `push` to `dev`. It has no secrets and `permissions: contents: read` (plus attestation permissions). It runs `swift test`, builds the universal binary, stamps `BuildInfo`, checks that `macx --version` equals the computed version, uploads the tarball as an artifact, and optionally runs `actions/attest@v4` for a public provenance record.
   - **`beta-publish.yml`** is triggered by `workflow_run` of beta-build. It runs from **main's** copy of the workflow, so a dev push can't change it.
     - Filters: `conclusion == success`, `event == push`, `head_branch == dev`, same repository.
     - It uses the `beta` environment (deployment branches: Selected → `main`; reviewer optional).
     - It downloads the artifact, re-hashes it, checks that `head_sha` is still `dev`'s tip and that the version is above the previously published beta, signs with the beta key, and uploads to the `dev` prerelease.
     - Concurrency: `group: beta-channel`, `cancel-in-progress: false`, `queue: max`.
     - It never executes the downloaded binary.
   - The simpler single-workflow variant (environment policy `dev`, sign in the push run) also works. But any dev push can then rewrite the signing steps and read the beta key.
7. **Client behaviour**
   - `macx update --channel beta|stable` persists the choice.
   - Beta users fetch both files, verify each with its own key list, keep `lastSequence` per channel and install the higher version.
   - The **stable floor applies to everyone**. A beta file can only notify or install a newer beta; it can never force.
8. **Leaving beta.** As with Ghostty, switching to stable stops the beta checks. The user stays on the dev build until a stable release is newer. Because dev versions are pre-releases of the next version, that happens at the next release. An optional explicit "reinstall current stable now" path, stable-signed and confirmed, is a deliberate downgrade. Check first that state files written by dev builds are readable by older stable builds.
9. **Hardening**
   - A ruleset on `dev`: no force-push or deletion; restrict who can push.
   - Workflow execution protections: beta workflows triggered only by `push` from the maintainer.
   - Keep SHA pins and consider the actions lockfile.
   - Keep an offline backup of the beta key and document rotation: ship a new beta public key in the next stable release.

### Top risks
- **Unattended beta signing** (option B, or B with the workflow_run split): a malicious merge or compromised push to `dev` reaches beta users automatically. The workflow_run split removes key *exfiltration* through workflow edits, but not the malicious *build*.
- **Reusing the stable key or the `release` environment for beta** turns a dev compromise into a compromise of all users.
- **Ordering bugs** strand beta users or install older builds: the `+build` parsing, the shallow-clone count, `describe` picking an older tag, and the global sequence.

### Decisions the maintainer must make
1. **Signing model.**
   - (B) Unattended separate beta key, with the workflow_run split. Recommended.
   - (A′) Separate beta key with a reviewer: approve the latest pending build when convenient.
   - (C) Keyless attestations only. Not viable as the client's trust root today: no Swift verifier, and the API needs auth.
   - (A) Every dev push through the stable `release` environment. Not recommended.
2. **Hosting.** A rolling `dev` prerelease (needs immutable releases off), or the Pages site (needs `dev` or `main` added to `github-pages`, full-site rebuilds and a shared `queue: max` group), or a dedicated branch file.
3. **Build number.** `github.run_number` (monotonic, history-independent) or `git rev-list --count --first-parent` (reproducible from git, needs full history, decreases on rewrite).
4. **Beta install behaviour.** Auto-install like stable, or notify only, with `macx update` to install.
5. **Downgrade path.** Ship an explicit "back to current stable now" command, or only "wait for the next stable".
6. **Beta expiry and refresh.** The expiry length, and whether a scheduled job on `main` (possible only with the main-scoped beta environment) re-signs the beta file so it doesn't go stale during quiet weeks.
7. **Attestations.** Whether to add `actions/attest@v4` to stable releases too, and document `gh attestation verify … --signer-workflow … --source-ref …` for users who want to audit.
8. **Format change.** Whether to add a signed context prefix, a breaking change for the stable signature, or rely on the in-JSON `channel` field plus separate key lists.

---

## Sources

| URL | What it provided | Date |
|---|---|---|
| https://ghostty.org/docs/install/pre | Tip channel, `auto-update-channel`, switching back only when a later stable exists, downgrade by re-download | Undated (© 2026); read 2026-11-24 |
| https://raw.githubusercontent.com/ghostty-org/ghostty/main/.github/workflows/release-tip.yml | `git rev-list --count HEAD` build number, short commit as display version, `fetch-depth: 0`, forced `tip` tag, repo-secret Sparkle key, serialized concurrency | `main` as of 2026-11-24 |
| https://raw.githubusercontent.com/ghostty-org/ghostty/main/.github/workflows/release-tag.yml | Stable builds use the same commit-count `CFBundleVersion` and the same Sparkle key | `main` as of 2026-11-24 |
| https://raw.githubusercontent.com/ghostty-org/ghostty/main/dist/macos/update_appcast_tip.py | Appcast item: version = build, display = `commit (date)`, per-commit URL, keep 15 | `main` as of 2026-11-24 |
| https://raw.githubusercontent.com/ghostty-org/ghostty/main/macos/Sources/Features/Update/UpdateDelegate.swift | Separate appcast URL per channel instead of Sparkle channels | `main` as of 2026-11-24 |
| https://github.com/ghostty-org/ghostty/releases/tag/tip | Rolling tip prerelease "built … on every commit to main that passes tests" | Updated 17 Nov (2026) |
| https://sparkle-project.org/documentation/publishing/ | `sparkle:channel`, `allowedChannels`, default channel always included, version vs display string | Undated; read 2026-11-24 |
| https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SPUUpdaterDelegate.h | `allowedChannelsForUpdater:`, `feedURLStringForUpdater:`, comparator used to prevent downgrade | `2.x` branch as of 2026-11-24 |
| https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SUStandardVersionComparator.m | Comparison algorithm; stops at the first dash | `2.x` branch as of 2026-11-24 |
| https://raw.githubusercontent.com/zed-industries/zed/main/crates/auto_update/src/auto_update.rs | Nightly compares SHA (any different = update); other channels compare versions | `main` as of 2026-11-24 |
| https://raw.githubusercontent.com/zed-industries/zed/main/crates/release_channel/src/lib.rs | Compiled-in channel; `version+nightly[.build].sha` | `main` as of 2026-11-24 |
| https://zed.dev/blog/preview-channel | Preview installs alongside stable | 2023-07-19 |
| https://github.com/neovim/neovim/releases/tag/nightly | `v0.13.0-dev-2182+g6501a7547d`, rolling prerelease | 24 Nov (2026) |
| https://raw.githubusercontent.com/neovim/neovim/master/.github/workflows/release.yml | Daily cron, delete and recreate the `nightly` release and tag | `master` as of 2026-11-24 |
| https://raw.githubusercontent.com/neovim/neovim/master/cmake/GenerateVersion.cmake | `git describe --first-parent --dirty --always` → `-dev-N+gHASH` | `master` as of 2026-11-24 |
| https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/platform/update/electron-main/abstractUpdateService.ts | Update URL `/api/update/<platform>/<quality>/<commit>`, server-side decision (204) | `main` as of 2026-11-24 |
| https://docs.rs/crate/code/0.0.1/source/src/update_service.rs | VS Code CLI update endpoints and quality mapping (stable, insider, exploration) | Crate v0.0.1, undated |
| https://code.visualstudio.com/insiders/ | Insiders is a separate side-by-side app with daily builds | Undated; read 2026-11-24 |
| https://docs.brew.sh/Manpage | `--HEAD`, `--fetch-HEAD` semantics | Undated; read 2026-11-24 |
| https://gist.github.com/vladshablinsky/f85838450103acfce86ef53418e464c4 | `HEAD-<sha>_<rev>`, outdated = commit differs from upstream | 2016 (last active 2016-12-27) |
| https://raw.githubusercontent.com/mozilla-firefox/firefox/main/toolkit/mozapps/update/updater/moz.build | Per-channel MAR signing certs (release vs nightly vs dep) | `main` as of 2026-11-24 |
| https://bugzilla.mozilla.org/show_bug.cgi?id=1893487 | Nightly update request with version `125.0a1` + buildID `20240229093832` | 2024 |
| https://semver.org/ | Pre-release precedence; build metadata ignored for precedence | SemVer 2.0.0 |
| https://theupdateframework.io/docs/security/ | Rollback, freeze, key compromise; compartmentalized trust; online keys must not endanger clients | Last modified 2024-10-12 |
| https://github.com/actions/attest-build-provenance/releases | v4 is a wrapper over `actions/attest`; use `actions/attest` for new work | Read 2026-11-24 (latest v4.2.2) |
| https://github.com/actions/attest | Usage, permissions, public-good Sigstore for public repos | README as of 2026-11-24 |
| https://github.com/actions/attest/releases | Latest v4.2.2; v4.0.0 merged the attest actions | Read 2026-11-24 (day and month only) |
| https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations | Workflow steps, `gh attestation verify` | Read 2026-11-24 |
| https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline | Offline verification, trusted-root staleness and revocation caveats | Read 2026-11-24 |
| https://cli.github.com/manual/gh_attestation_verify | Flags: `--signer-workflow`, `--source-ref`, `--bundle`, `--custom-trusted-root`, `--deny-self-hosted-runners` | Read 2026-11-24 |
| https://docs.github.com/en/rest/repos/attestations | Attestations-by-digest endpoint, auth wording | Read 2026-11-24 |
| https://raw.githubusercontent.com/sigstore/architecture-docs/main/client-spec.md | Verification steps a client must perform | `main` as of 2026-11-24 (undated) |
| https://sources.debian.org/src/sigstore-go/1.1.4-1/docs/verification.md/ | sigstore-go verifier: trusted root, identity and digest policy | sigstore-go 1.1.4 |
| https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments | Reviewers, branch and tag policies, secrets, plan availability | Read 2026-11-24 |
| https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments | Configuring selected branches and tags, admin bypass, self-review | Read 2026-11-24 |
| https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments | `deployment: false`, secrets locked until rules pass | Read 2026-11-24 |
| https://github.blog/changelog/2021-02-17-github-actions-limit-which-branches-can-deploy-to-an-environment/ | A ref mismatch fails the job | 2021-02-17 |
| https://github.blog/changelog/2025-11-07-actions-pull_request_target-and-environment-branch-protections-changes/ | `pull_request_target` uses the default branch; env rules evaluate `GITHUB_REF` | 2025-11-07 (effective 2025-12-08) |
| https://github.blog/changelog/2026-09-17-workflow-execution-protections-in-github-actions-generally-available | Actor and event rules, workflow-file targeting, GA | 2026-09-17 |
| https://github.blog/changelog/2026-11-02-pull_request_target-blocked-by-default-december-2 | `pull_request_target` blocked by default in public repos from 2026-12-02 | 2026-11-02 |
| https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/actions-policies/workflow-execution-protections | Repository-level configuration of execution protections | Read 2026-11-24 |
| https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows | `GITHUB_REF` per event (schedule, workflow_run, pull_request_target = default branch); `GITHUB_TOKEN` events don't trigger runs | Read 2026-11-24 |
| https://docs.github.com/en/actions/reference/workflows-and-actions/contexts | `run_number`, `run_id`, `run_attempt`, `ref_protected` | Read 2026-11-24 |
| https://docs.github.com/en/actions/reference/security/secure-use | SHA pinning; write access = read access to secrets; lockfile supersedes pinning | Read 2026-11-24 |
| https://github.blog/changelog/2025-08-15-github-actions-policy-now-supports-blocking-and-sha-pinning-actions/ | SHA-pinning enforcement policy | 2025-08-15 |
| https://infoq.com/news/2026/11/github-actions-lockfiles-ga | Actions lockfiles GA (2026-10-28), transitive pinning, "Require lockfile" | 2026-11-06 |
| https://www.cisa.gov/news-events/alerts/2025/03/18/supply-chain-compromise-third-party-github-action-cve-2025-30066 | tj-actions compromise leaked secrets; rotate them | 2025-03-18 (rev. 2025-03-26) |
| https://github.com/actions/deploy-pages | Deploys an uploaded artifact as the site; needs `pages` and `id-token` | README as of 2026-11-24 |
| https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages | Artifact format and size, `github-pages` environment | Read 2026-11-24 |
| https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits | 1 GB site, 10-minute deploys, build limit not applicable to custom workflows | Read 2026-11-24 |
| https://github.com/orgs/community/discussions/39054 | "Branch … is not allowed to deploy to github-pages" and its fix | 2022-11-14 (comment Jan 2026) |
| https://gist.github.com/nils-s/7d727675e554877e518c380872851c46 | "due to in progress deployment" Pages error and its fix | 2023 |
| https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency | Group scope across workflows, pending cancellation, `queue: single/max` | Read 2026-11-24 |
| https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases | 1000 assets, under 2 GiB each, no total or bandwidth limit | Read 2026-11-24 |
| https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases | Locked assets and tags, no tag reuse, draft-then-publish | Read 2026-11-24 |
| https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/ | Immutable releases GA; existing releases stay mutable | 2025-10-28 |
| https://cli.github.com/manual/gh_release_upload | `--clobber` deletes before uploading | Read 2026-11-24 |
| https://cli.github.com/manual/gh_release_create | `--prerelease`, `--target`, `--latest`, immutability note | Read 2026-11-24 |
| https://docs.github.com/en/actions/how-tos/manage-workflow-runs/remove-workflow-artifacts | 90-day default retention | Read 2026-11-24 |
| https://github.com/actions/upload-artifact | `retention-days` 1–90; artifact URL needs login | README as of 2026-11-24 (v7) |
| https://docs.github.com/en/rest/actions/artifacts | Download redirect expires in 1 minute | Read 2026-11-24 |
| https://docs.github.com/en/actions/reference/limits | 35-day run limit including approval wait; macOS concurrency | Read 2026-11-24 |
| https://docs.github.com/en/rest/deployments/branch-policies | REST for environment branch and tag policies | Read 2026-11-24 |
| https://raw.githubusercontent.com/swiftlang/swift-testing/main/Package.swift | `Context.gitInformation` → C define of the commit hash; `GITHUB_SHA` fallback | `main` as of 2026-11-24 |
| https://sources.debian.org/src/swiftlang/6.2.3-1/swiftpm/Sources/PackageDescription/Context.swift/ | `GitInformation` (currentTag, currentCommit, hasUncommittedChanges), PackageDescription 6.0 | swiftlang 6.2.3 source |
| https://sources.debian.org/src/swiftlang/6.2.3-1/swiftpm/Sources/PackageDescription/BuildSettings.swift/ | Swift `define` has no value; C `define(_:to:)` does; unsafeFlags restriction | swiftlang 6.2.3 source |
| https://forums.swift.org/t/inserting-gitinformation-into-source-code/77128 | No built-in way to get git info into Swift code; C-target workaround | 2025-01-11 (revived 2026-09-19) |
| https://forums.swift.org/t/best-way-to-inject-build-time-configuration-in-a-swift-package/79082 | Generated source file vs flags vs plugin | 2025-04 |
| https://swiftpackageregistry.com/DimaRU/PackageBuildInfo | Build-tool plugin that generates git build info | v1.0.4, 2024-11-14 |
