#!/usr/bin/env python3
"""Scores an Atomic Red Team run (scripts/eval/art.sh output) against the expectations in art-tests.txt.

Usage: art-report.py OUT-DIR LABEL > report.md
Each test's alerts are the watch alerts logged between its start and 1 s after its end (the harness waits 5 s
after each test). A test is *caught* when one of its wanted rules shows up, or for `persist` when
`macx persist --diff` lists something added or changed. A `-` test is *quiet* unless an alert at medium or
above shows up, which is a false alarm.
"""
import json, os, sys
from collections import Counter

out, label = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}

notes = {}
for line in open(os.path.join(here, "art-tests.txt")):
    parts = line.split(None, 3)
    if len(parts) >= 3 and not line.startswith("#"):
        notes[f"{parts[0]}-{parts[1]}"] = parts[3].strip() if len(parts) > 3 else ""

def load(name):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return []
    rows = []
    for l in open(path, errors="replace"):
        try:
            rows.append(json.loads(l))
        except ValueError:
            pass  # a line cut off when eslogger was stopped
    return rows

tests, alerts = load("tests.jsonl"), load("alerts.jsonl")
alerts = [a for a in alerts if a.get("rule") not in ("frozen",)]

def window(t):
    return [a for a in alerts if t["start"] - 0.5 <= a.get("epoch", 0) <= t["end"] + 1]

def persist_hit(t):
    p = t.get("persist")
    if not p or not os.path.exists(os.path.join(out, p)):
        return False
    text = open(os.path.join(out, p), errors="replace").read()
    return "\nAdded:" in text or "\nChanged:" in text or text.startswith("Added:")

rows, score = [], Counter()
for t in tests:
    seen = window(t)
    rules = sorted({a["rule"] for a in seen})
    loud = sorted({f'{a["rule"]} ({a["severity"]})' for a in seen if RANK.get(a.get("severity"), 0) >= 2})
    want = t["want"]
    if want == "?":
        result = "info"
    elif want == "-":
        result = "false alarm" if loud else "quiet"
    else:
        wanted = want.split(",")
        hit = [r for r in wanted if r != "persist" and r in rules]
        if "persist" in wanted and persist_hit(t):
            hit.append("persist")
        result = "caught" if hit else "missed"
    score[result] += 1
    shown = ", ".join(f'{a["rule"]} ({a["severity"]})' for a in sorted(seen, key=lambda a: -RANK.get(a.get("severity"), 0))[:4])
    rows.append((t["id"], t["as_"], want, result, shown or "none", notes.get(t["id"], t["id"])))

print(f"## Atomic Red Team: {label}\n")
scored = score["caught"] + score["missed"]
print(f"**Caught {score['caught']} of {scored}** attacks that should be caught. "
      f"**{score['false alarm']} false alarm(s)** in {score['quiet'] + score['false alarm']} tests that should stay quiet "
      f"(including the ordinary-work run). {score['info']} informational.\n")
print("| Test | As | Wanted | Result | What the watch said | What it does |")
print("|---|---|---|---|---|---|")
order = {"missed": 0, "false alarm": 1, "caught": 2, "quiet": 3, "info": 4}
for r in sorted(rows, key=lambda r: (order[r[3]], r[0])):
    print(f"| {r[0]} | {r[1]} | `{r[2]}` | **{r[3]}** | {r[4]} | {r[5]} |")

tcc = load("tcc.jsonl")
print(f"\n### Privacy grants (`tcc_modify`)\n\n{len(tcc)} raw event(s).")
for e in tcc[:6]:
    m = e.get("event", {}).get("tcc_modify", {})
    keep = {k: m.get(k) for k in ("service", "identity", "identity_type", "update_type", "right", "reason", "instigator_token")
            if k in m}
    print(f"- `{json.dumps(keep, sort_keys=True)[:300]}`")
if tcc:
    print(f"\nAll fields: `{', '.join(sorted(tcc[0].get('event', {}).get('tcc_modify', {}).keys()))}`")
log = os.path.join(out, "tcc-actions.log")
if os.path.exists(log):
    print("\n```\n" + open(log, errors="replace").read().strip()[:1500] + "\n```")
