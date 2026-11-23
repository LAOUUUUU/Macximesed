# Security policy

Macximesed looks for malware and moves files on people's Macs, so a bug in it can be a security problem. Please report those privately.

## Reporting a vulnerability
**Don't open a public issue.** Use GitHub's private reporting instead:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability**, or go straight to <https://github.com/LAOUUUUU/Macximesed/security/advisories/new>.
3. Say what you found, how to reproduce it, which macOS version and Mac you used, and what an attacker could do with it.

You'll get a reply as soon as possible. The fix is made privately and released, and then the advisory is published, with credit to you if you want it.

## What counts
- Anything that makes macx **delete, move or overwrite something it shouldn't**, such as escaping the undo store, following a symlink out of a cleanup item, or restoring over a file that's there again.
- Ways to **hide malware from `macx persist`** or make a malicious item look trusted, such as getting past the signature check or tricking the bundle-ID owner lookup.
- Problems with the installed binary's **privacy handling**: macx reading a guarded folder without Full Disk Access, or the responsibility re-exec being abused.
- Supply-chain problems in the build, CI or release workflows.

## What doesn't
- A detection that's simply missing or wrong, with no security impact. Use the **Detection report** issue template for that.
- Problems that need an attacker who already has root on the Mac.

## Supported versions
Only the latest release gets fixes.

## If you think your Mac is infected
macx can show you what's set to start by itself (`macx persist`), but it can't clean an infection or vouch for a machine that's been compromised. If a stealer ran on your Mac:
1. From a **different, clean device**, change your passwords and turn on two-factor sign-in.
2. Revoke the Mac's sessions, API keys and SSH keys.
3. Back up your files, then erase and reinstall macOS.
