#!/usr/bin/env python3
"""Builds feed/v1.json, the macOS malware hash feed.

Sources:
  1. data/hashes/*.tsv in the repo (sha256 <TAB> family <TAB> source), curated by hand.
  2. abuse.ch MalwareBazaar, by tag, when MALWAREBAZAAR_KEY is set (free key from auth.abuse.ch).
     Only Mach-O, disk image, package and app archive samples are kept; for tags that only name macOS malware,
     zipped apps and shell loaders too. Plus every recent Mach-O and disk image sample (get_file_type).
The workflow puts this file's SHA-256 into the signed channel, so the feed can't be changed on its own.
"""
import collections, datetime, glob, json, os, re, sys, time, urllib.parse, urllib.request

HEX = re.compile(r"^[0-9a-f]{64}$")
TAGS = ["AtomicStealer", "AMOS", "Atomic", "MacStealer", "Banshee", "Cuckoo", "Poseidon", "PoseidonStealer", "MetaStealer", "RustBucket", "macos"]
MAC_TYPES = {"macho", "mach-o", "dmg", "pkg", "app", "zip-app", "applescript", "scpt"}
# Tags that only ever name macOS malware: their zipped apps and shell loaders count too. Mixed tags (MetaStealer is
# mostly Windows) keep only the file types above.
MAC_ONLY_TAGS = {"AtomicStealer", "AMOS", "Banshee", "Cuckoo", "Poseidon", "PoseidonStealer", "MacStealer", "RustBucket", "macos"}
MAC_ONLY_EXTRA = {"zip", "sh", "osascript"}
# Every recent sample of these types, however it was tagged.
FILE_TYPES = ["macho", "dmg"]
# Big answers time out at the gateway (502), so a query that fails is asked again for fewer samples.
LIMITS = ["1000", "250", "100", "50"]

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

def ask(params, key, label):
    """One MalwareBazaar query. On an error (its gateway answers 502 when the answer is large) it waits and asks again
    for fewer samples, so one bad moment or one big tag doesn't thin the feed."""
    for attempt, limit in enumerate(LIMITS):
        body = urllib.parse.urlencode({**params, "limit": limit}).encode()
        req = urllib.request.Request("https://mb-api.abuse.ch/api/v1/", data=body, headers={"Auth-Key": key, "User-Agent": "macximesed-feed"})
        try:
            return json.load(urllib.request.urlopen(req, timeout=90))
        except Exception as e:  # one query failing shouldn't stop the feed
            if attempt == len(LIMITS) - 1:
                print(f"MalwareBazaar {label}: gave up after {len(LIMITS)} tries ({e})", file=sys.stderr)
                return None
            print(f"MalwareBazaar {label}: {e}, asking for {LIMITS[attempt + 1]}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))

def bazaar(key):
    out = {}
    dropped = collections.Counter()
    queries = [({"query": "get_taginfo", "tag": t}, f"tag {t}", t in MAC_ONLY_TAGS, t) for t in TAGS]
    queries += [({"query": "get_file_type", "file_type": f}, f"file type {f}", True, f) for f in FILE_TYPES]
    for params, label, mac_only, name in queries:
        data = ask(params, key, label)
        if data is None:
            continue
        if data.get("query_status") != "ok":
            print(f"MalwareBazaar {label}: {data.get('query_status')}", file=sys.stderr)
            continue
        samples = data.get("data", [])
        allowed = MAC_TYPES | (MAC_ONLY_EXTRA if mac_only else set())
        kept = 0
        for s in samples:
            h = (s.get("sha256_hash") or "").lower()
            kind = (s.get("file_type") or "").lower()
            if HEX.match(h) and kind in allowed:
                out.setdefault(h, {"family": s.get("signature") or name, "source": f"MalwareBazaar ({name})"})
                kept += 1
            else:
                dropped[kind or "?"] += 1
        print(f"MalwareBazaar {label}: {len(samples)} samples, {kept} kept", file=sys.stderr)
    if dropped:
        print("Not macOS file types, left out: " + ", ".join(f"{k} {n}" for k, n in dropped.most_common(12)), file=sys.stderr)
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
