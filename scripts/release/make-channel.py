#!/usr/bin/env python3
"""Builds the update channel file (channel/v1.json) from the previous one plus this release's details.

The sequence always goes up by one, so clients can reject an older file (rollback). The file expires after
90 days, so a replayed old file can't keep clients from hearing about a fix. The security floor
(minimumSafe) is kept from the previous file unless it's set or cleared here.
"""
import argparse, datetime, json, sys

p = argparse.ArgumentParser()
p.add_argument("--previous", help="previous channel JSON (may be missing)")
p.add_argument("--version"), p.add_argument("--url"), p.add_argument("--sha256"), p.add_argument("--notes")
p.add_argument("--minimum-safe"), p.add_argument("--reason"), p.add_argument("--advisory")
p.add_argument("--clear-floor", action="store_true")
p.add_argument("--out", required=True)
a = p.parse_args()

prev = {}
if a.previous:
    try:
        prev = json.load(open(a.previous))
    except (OSError, ValueError):
        prev = {}

now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")

if a.version:
    if not (a.url and a.sha256):
        sys.exit("--version needs --url and --sha256")
    if not a.url.startswith("https://"):
        sys.exit("the release URL must be https")
    latest = {"version": a.version, "url": a.url, "sha256": a.sha256.lower()}
    if a.notes:
        latest["notes"] = a.notes
elif "latest" in prev:
    latest = prev["latest"]
else:
    sys.exit("no previous channel to keep 'latest' from; pass --version, --url and --sha256")

if a.minimum_safe:
    if not a.reason:
        sys.exit("--minimum-safe needs --reason (people see it when they're updated)")
    floor = {"version": a.minimum_safe, "reason": a.reason}
    if a.advisory:
        floor["advisory"] = a.advisory
elif a.clear_floor:
    floor = None
else:
    floor = prev.get("minimumSafe")

channel = {
    "schema": 1,
    "sequence": int(prev.get("sequence", 0)) + 1,
    "published": iso(now),
    "expires": iso(now + datetime.timedelta(days=90)),
    "latest": latest,
}
if floor:
    channel["minimumSafe"] = floor

with open(a.out, "w") as f:
    json.dump(channel, f, sort_keys=True, separators=(",", ":"))
print(json.dumps(channel, indent=2, sort_keys=True))
