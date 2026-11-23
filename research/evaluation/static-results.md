# Static evaluation: macx guard inspect

- Date: 2026-11-23 · macx 0.1.0 · commit 218d9f7 · macOS 27.0.1 (arm64)
- Simulated attacks are harmless imitations served from a local test server (`Tests/Evaluation/served`). Benign cases are real install commands fetched live.
- Nothing was run: `macx guard inspect --no-run` only downloads and reads.

## Summary

| | Count |
|---|---|
| Simulated attacks | 17 |
| → verdict *DON'T RUN THIS* | 12 |
| → verdict *Be careful* | 5 |
| → *partly unknown* (nothing seen, parts unchecked) | 0 |
| → missed (*Nothing dangerous found*) | 0 |
| Real installers | 11 |
| → clean | 6 |
| → clean, parts couldn't be checked | 4 |
| → *Be careful* | 1 |
| → false positive (*DON'T RUN THIS*) | 0 |
| → errors (couldn't fetch, etc.) | 0 |
| Average time per check | 205 ms |

Caveat: every simulated attack is served over plain http from 127.0.0.1, which by itself adds two medium facts
(`plain-http`, `ip-address-host`) and so at least *Be careful*. The *Rules* column leaves those facts out, so
it shows what the script's own content triggered.

## Cases

| Expected | Case | Verdict | Result | Rules (without source facts) | ms |
|---|---|---|---|---|---|
| malicious | AMOS-style script piped to zsh | DON'T RUN THIS | detected | browser-data closes-terminal keychain-read password-check password-prompt stealer-pattern uploads-files  | 330 |
| malicious | Same, disguised with split quotes | DON'T RUN THIS | detected | browser-data closes-terminal keychain-read password-check password-prompt stealer-pattern uploads-files  | 131 |
| malicious | Same, disguised with $'\\x..' escapes | DON'T RUN THIS | detected | browser-data closes-terminal keychain-read password-check password-prompt stealer-pattern uploads-files  | 129 |
| malicious | Same, disguised with variables | DON'T RUN THIS | detected | browser-data closes-terminal keychain-read password-check password-prompt stealer-pattern uploads-files  | 129 |
| malicious | Same, hidden in base64 (the 21 Aug paste form) | DON'T RUN THIS | detected | base64-to-shell browser-data closes-terminal keychain-read password-check password-prompt stealer-pattern uploads-files  | 128 |
| malicious | Same, process substitution | DON'T RUN THIS | detected | browser-data closes-terminal keychain-read password-check password-prompt stealer-pattern uploads-files  | 124 |
| malicious | Same, download then run | DON'T RUN THIS | detected | browser-data closes-terminal keychain-read password-check password-prompt stealer-pattern uploads-files  | 128 |
| malicious | Two-stage: fake Apple launch daemon in stage 2 | DON'T RUN THIS | detected | downloads-and-runs-more fake-apple-folder fake-apple-launch-item hidden-folder launch-item  | 125 |
| malicious | Script that decodes a hidden password prompt | DON'T RUN THIS | detected | decodes-hidden-code  | 124 |
| malicious | Wallet files copied and uploaded | DON'T RUN THIS | detected | stealer-pattern uploads-files wallet-data  | 130 |
| malicious | Strips quarantine and opens an app | DON'T RUN THIS | detected | quarantine-strip  | 127 |
| malicious | Downloads a program and runs it | Be careful | flagged (caution) | downloads-program-to-run  | 127 |
| malicious | Runs code from a variable | Be careful | flagged (caution) | runs-unresolved-code  | 129 |
| malicious | Downloads from a computed link | Be careful | flagged (caution) | computed-download downloads-and-runs-more  | 137 |
| malicious | Writes a script and runs it | Be careful | flagged (caution) | runs-generated-script  | 128 |
| malicious | Link serves a program, not a script | DON'T RUN THIS | detected | serves-a-program  | 123 |
| malicious | Link serves nothing (cloaking) | Be careful | flagged (caution) | empty  | 124 |
| benign | Homebrew | Nothing dangerous in what could be read, but parts couldn't be checked (see Can't tell) | clean, parts unchecked | asks-for-admin runs-unresolved-code  | 230 |
| benign | rustup | Nothing dangerous in what could be read, but parts couldn't be checked (see Can't tell) | clean, parts unchecked | computed-download  | 380 |
| benign | nvm | Nothing dangerous found | clean | none | 211 |
| benign | Oh My Zsh | Nothing dangerous found | clean | asks-for-admin  | 206 |
| benign | bun | Nothing dangerous found | clean | none | 364 |
| benign | deno | Nothing dangerous found | clean | none | 233 |
| benign | uv | Nothing dangerous in what could be read, but parts couldn't be checked (see Can't tell) | clean, parts unchecked | computed-download redirected  | 484 |
| benign | pnpm | Nothing dangerous found | clean | none | 264 |
| benign | starship | Nothing dangerous found | clean | asks-for-admin  | 494 |
| benign | fnm | Nothing dangerous in what could be read, but parts couldn't be checked (see Can't tell) | clean, parts unchecked | computed-download  | 301 |
| benign | Spicetify | Be careful | caution | asks-for-admin downloads-and-runs-more  | 207 |
