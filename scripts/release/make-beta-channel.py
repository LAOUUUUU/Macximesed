#!/usr/bin/env python3
"""Builds the beta channel file (beta-v1.json) for one dev build. research/diagnostics-beta/RESEARCH.md.

The sequence goes up by one from the previous file (rollback protection, kept per channel by macx). The file
expires after 30 days, and it never carries the stable-only fields (latest, minimumSafe, hashFeed): macx refuses a
beta file that does.
Usage: make-beta-channel.py --previous prev.json --commit SHA --base 0.4.0 --url https://... --sha256 HEX --out beta-v1.json
"""
import argparse, datetime, json, re, sys

p = argparse.ArgumentParser()
p.add_argument("--previous")
p.add_argument("--commit", required=True)
p.add_argument("--base", required=True)
p.add_argument("--url", required=True)
p.add_argument("--sha256", required=True)
p.add_argument("--notes")
p.add_argument("--out", required=True)
a = p.parse_args()

if not re.fullmatch(r"[0-9a-f]{7,40}", a.commit.lower()):
    sys.exit("--commit must be a hex commit")
if not re.fullmatch(r"\d+\.\d+\.\d+", a.base):
    sys.exit("--base must be a release version like 0.4.0")
if not a.url.startswith("https://"):
    sys.exit("the build URL must be https")
if not re.fullmatch(r"[0-9a-fA-F]{64}", a.sha256):
    sys.exit("--sha256 must be 64 hex characters")

prev = {}
if a.previous:
    try:
        prev = json.load(open(a.previous))
    except (OSError, ValueError):
        prev = {}

now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
build = {"commit": a.commit.lower(), "base": a.base, "url": a.url, "sha256": a.sha256.lower()}
if a.notes:
    build["notes"] = a.notes
channel = {
    "schema": 1,
    "channel": "beta",
    "sequence": int(prev.get("sequence", 0)) + 1,
    "published": iso(now),
    "expires": iso(now + datetime.timedelta(days=30)),
    "build": build,
}
with open(a.out, "w") as f:
    json.dump(channel, f, sort_keys=True, separators=(",", ":"))
print(json.dumps(channel, indent=2, sort_keys=True))
