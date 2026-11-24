# Bug-report relay

A tiny Cloudflare Worker between `macx report` and a private Discord channel. macx encrypts each report on the Mac to the maintainer's key, so the Worker and Discord only ever handle an unreadable `.mxr` file. Design and decisions: [research/diagnostics-beta/RESEARCH.md](../../research/diagnostics-beta/RESEARCH.md).

What it does with a request:
- It answers only `POST /report`, up to 256 KB, starting with the `MXR1` header.
- It allows about 5 reports a minute from one address (counted per Cloudflare location, and forgotten after the minute).
- It forwards the file to the webhook as `<random id>.mxr` with a one-line note, and answers `{"id": "…"}`. macx shows that ID to the person.
- It keeps no IP addresses: request logs are off in `wrangler.toml`, and the code logs nothing.

Tests (no network, Discord is faked): `node --test scripts/report-relay/worker.test.mjs`

## Setting it up (the maintainer, once)
Nothing here is done by macx or by CI. Every secret stays out of chat, the repo and notes.

1. **Report key.** Make the key pair with the maintainer's own macx:
   ```bash
   macx report-keygen --out ~/report-key.txt
   ```
   Put the private key from that file into the password manager, then delete the file. The printed public key goes into `ReportKey.current` in `Sources/MacxCore/ReportEnvelope.swift`.
2. **Discord.** Make a private channel only you can see, then a webhook for it (channel settings > Integrations > Webhooks). Copy its address but don't paste it anywhere except step 4. Check the channel name on the webhook before using it.
3. **Worker.** With Wrangler 4.36.0 or later, from this folder:
   ```bash
   npx wrangler deploy
   ```
4. **Webhook secret.** Wrangler reads it from the prompt, so it never lands in your shell history:
   ```bash
   npx wrangler secret put DISCORD_WEBHOOK
   ```
5. **Address.** The Worker's address plus `/report` goes into `ReportSending.defaultEndpoint` in `Sources/MacxCore/ReportEnvelope.swift`. It will be public in the binary, so use a neutral `workers.dev` subdomain or your own domain.
6. **Try it** with one report from your own Mac, and check it arrives in the right channel before releasing.

## Reading a report
Download the `.mxr` file from the channel, then:
```bash
macx report-open REPORT.mxr --key FILE-WITH-PRIVATE-KEY
```
Delete reports after 90 days, and whenever someone asks (they quote the report ID).

## If it's abused
- Lower the rate limit in `wrangler.toml` and deploy again.
- Delete the webhook in Discord and make a new one (step 4), so a leaked webhook address is useless.
- Move the Worker to a new address and ship it in the next release.
