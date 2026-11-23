#!/usr/bin/env python3
"""Builds feed/v1.json, the macOS malware hash feed.

Sources:
  1. data/hashes/*.tsv in the repo (sha256 <TAB> family <TAB> source), curated by hand.
  2. abuse.ch MalwareBazaar, by tag, when MALWAREBAZAAR_KEY is set (free key from auth.abuse.ch).
     Only Mach-O, disk image, package and app archive samples are kept.
The workflow puts this file's SHA-256 into the signed channel, so the feed can't be changed on its own.
"""
import datetime, glob, json, os, re, sys, urllib.parse, urllib.request

HEX = re.compile(r"^[0-9a-f]{64}$")
TAGS = ["AtomicStealer", "AMOS", "Atomic", "MacStealer", "Banshee", "Cuckoo", "Poseidon", "PoseidonStealer", "MetaStealer", "RustBucket", "macos"]
MAC_TYPES = {"macho", "mach-o", "dmg", "pkg", "app", "zip-app", "applescript", "scpt"}

def curated(root):
    out = {}
    for path in sorted(glob.glob(os.path.join(root, "data/hashes/*.tsv"))):
        for n, line in enumerate(open(path, encoding="utf-8"), 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 3 or not HEX.match(parts[0].lower()):
                sys.exit(f"{path}:{n}: expected sha256<TAB>family<TAB>source")
            out[parts[0].lower()] = {"family": parts[1], "source": parts[2]}
    return out

def bazaar(key):
    out = {}
    for tag in TAGS:
        body = urllib.parse.urlencode({"query": "get_taginfo", "tag": tag, "limit": "1000"}).encode()
        req = urllib.request.Request("https://mb-api.abuse.ch/api/v1/", data=body, headers={"Auth-Key": key, "User-Agent": "macximesed-feed"})
        try:
            data = json.load(urllib.request.urlopen(req, timeout=60))
        except Exception as e:  # one tag failing shouldn't stop the feed
            print(f"MalwareBazaar tag {tag}: {e}", file=sys.stderr)
            continue
        if data.get("query_status") != "ok":
            print(f"MalwareBazaar tag {tag}: {data.get('query_status')}", file=sys.stderr)
            continue
        for s in data.get("data", []):
            h = (s.get("sha256_hash") or "").lower()
            if HEX.match(h) and (s.get("file_type") or "").lower() in MAC_TYPES:
                out[h] = {"family": s.get("signature") or tag, "source": f"MalwareBazaar ({tag})"}
    return out

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
entries = curated(root)
key = os.environ.get("MALWAREBAZAAR_KEY", "")
if key:
    for h, e in bazaar(key).items():
        entries.setdefault(h, e)  # curated entries win
out = sys.argv[1] if len(sys.argv) > 1 else "feed/v1.json"
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
feed = {
    "schema": 1,
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "entries": [{"sha256": h, **entries[h]} for h in sorted(entries)],
}
with open(out, "w") as f:
    json.dump(feed, f, sort_keys=True, separators=(",", ":"))
print(f"{len(entries)} hashes ({'with' if key else 'without'} MalwareBazaar) -> {out}")
