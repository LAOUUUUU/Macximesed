#!/bin/bash
# Runtime evaluation of `macx watch --suspend`: does each simulated stealer step raise an alert, how long
# does that take, how much does a flagged process get done before it's frozen, do its children get frozen too,
# and how much CPU and memory macx + eslogger use.
#
# Every simulation is harmless:
#   - base64-to-shell decodes and runs `echo sim`;
#   - the dscl check uses a user that doesn't exist;
#   - the launch agent and the hidden Apple-named folder are removed straight away (never loaded);
#   - the quarantine flag is set and removed on a temp file;
#   - the "unsigned program" is a copy of /bin/echo, ad-hoc signed, in a hidden temp folder.
#
# Usage:  sudo scripts/eval/runtime.sh [macx-binary] [results.md]
# macx needs Full Disk Access (macx privacy --open) so eslogger can start.
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0 $*"; exit 1; }
[ -n "${SUDO_USER:-}" ] || { echo "Run through sudo from your own account, so the simulations run as you."; exit 1; }
U="$SUDO_USER"
UHOME=$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACX="${1:-$UHOME/.local/bin/macx}"
OUT="${2:-$ROOT/research/evaluation/runtime-results.md}"
[ -x "$MACX" ] || { echo "No macx at $MACX (install it with scripts/install.sh)"; exit 1; }

# A work folder the simulations (running as you) can use: root's own temp folder isn't reachable by your account.
WORK=$(mktemp -d /private/tmp/macx-eval.XXXXXX)
chown "$U" "$WORK"; chmod 755 "$WORK"
LOG="$WORK/alerts.jsonl"
SAMPLES="$WORK/cpu.txt"
as_user() { sudo -u "$U" HOME="$UHOME" "$@"; }
now() { /usr/bin/python3 -I -c 'import time; print(f"{time.time():.6f}")'; }

cleanup() {
  [ -n "${WATCH:-}" ] && kill "$WATCH" 2>/dev/null
  # Backstop: every watcher this run started logs into $WORK, including a re-launched child.
  pkill -f -- "--log $WORK/" 2>/dev/null
  pkill -f "macx-sim-" 2>/dev/null
  rm -f "$UHOME/Library/LaunchAgents/com.macx-sim.test.plist"
  rmdir "$UHOME/Library/Application Support/.com.apple.macx-sim" 2>/dev/null
  [ -f "$WORK/watch.out" ] && cp "$WORK/watch.out" "$(dirname "$OUT")/runtime-watch-output.txt" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Starting macx watch --suspend…"
# eslogger ignores every process in its own process group. Job control gives the watcher a group of its
# own; without it, every simulation below would be in eslogger's group and invisible to it.
set -m
MACX_NO_UPDATE_CHECK=1 "$MACX" watch --suspend --min-severity info --log "$LOG" > "$WORK/watch.out" 2>&1 &
WATCH=$!
set +m
for _ in $(seq 1 150); do grep -q "Watching" "$WORK/watch.out" 2>/dev/null && break; kill -0 "$WATCH" 2>/dev/null || break; sleep 0.2; done
if ! grep -q "Watching" "$WORK/watch.out"; then
  echo "macx watch didn't start:"; cat "$WORK/watch.out"; exit 1
fi
sleep 3  # let eslogger settle
# eslogger refuses to start without Full Disk Access; the watcher then exits. Stop here with its message.
if ! kill -0 "$WATCH" 2>/dev/null || grep -q "eslogger stopped" "$WORK/watch.out"; then
  echo
  echo "macx watch stopped straight away. Its output:"
  sed 's/^/  /' "$WORK/watch.out"
  echo
  echo "Most likely eslogger has no Full Disk Access. Give it to the installed macx (not Terminal):"
  echo "  $MACX privacy --open   → +  → Cmd-Shift-G → $MACX → switch it on. Then run this again."
  exit 1
fi

ES=$(pgrep -P "$WATCH" eslogger || pgrep -x eslogger | head -1)
MACXPID=$(pgrep -f "$MACX watch" | tail -1)
sample() { ps -o %cpu=,rss= -p "$1" 2>/dev/null | awk '{c+=$1; r+=$2} END {printf "%.1f %d\n", c, r}'; }
( while kill -0 "$WATCH" 2>/dev/null; do echo "$(sample "$MACXPID") $(sample "$ES")" >> "$SAMPLES"; sleep 1; done ) &
SAMPLER=$!

echo "Idle for 15 s (baseline CPU)…"
sleep 15
IDLE_LINES=$(wc -l < "$SAMPLES" 2>/dev/null | tr -d ' ')
IDLE_LINES=${IDLE_LINES:-0}

RESULTS=""
# result row: name | expected rule | alert? | ms to alert | ms alert->frozen | ops before frozen | children frozen?
row() { RESULTS="$RESULTS| $1 | \`$2\` | $3 | $4 | $5 | $6 | $7 |
"; printf '%-34s %-26s alert=%-4s %8s ms  freeze=%6s ms  ops=%-8s children=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }

# Delay from $start to the first alert of $rule after $start (and to its freeze record, if any).
alert_ms() {
  /usr/bin/python3 -I - "$LOG" "$1" "$2" <<'PY'
import json, sys
log, rule, start = sys.argv[1], sys.argv[2], float(sys.argv[3])
alert = frozen = None
try:
    for line in open(log):
        r = json.loads(line)
        if r.get("epoch", 0) < start: continue
        if alert is None and r.get("rule") == rule: alert = r["epoch"]
        elif alert is not None and frozen is None and r.get("rule") == "frozen": frozen = r["epoch"]
except FileNotFoundError: pass
fmt = lambda t: "-" if t is None else str(round((t - start) * 1000))
print(("yes" if alert else "**no**"), fmt(alert), "-" if (alert is None or frozen is None) else str(round((frozen - alert) * 1000)))
PY
}

wait_for() { for _ in $(seq 1 30); do grep -q "\"$1\"" "$LOG" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

echo "Running simulations…"

# 1. Pasted base64-to-shell, then a busy counter: how far does it get before it's frozen?
CNT="$WORK/count1"; touch "$CNT"; chmod 666 "$CNT"
start=$(now)
as_user /bin/zsh -c "echo ZWNobyBzaW0= | base64 -D | zsh; i=0; while true; do i=\$((i+1)); echo \$i > $CNT; done # macx-sim-1" &
SIM=$!
sleep 3
read -r got ms fms <<< "$(alert_ms base64-to-shell "$start")"
ops=$(cat "$CNT" 2>/dev/null || echo 0); sleep 0.5; ops2=$(cat "$CNT" 2>/dev/null || echo 0)
still=$([ "$ops" = "$ops2" ] && echo "stopped at $ops" || echo "**kept running** ($ops → $ops2)")
row "Pasted base64 into zsh" base64-to-shell "$got" "$ms" "$fms" "$still" "n/a"
pkill -KILL -f "macx-sim-1"; kill -KILL $SIM 2>/dev/null

# 2. Same, but it starts a background child first: is the child frozen too?
start=$(now)
as_user /bin/zsh -c "/bin/sleep 120 & echo ZWNobyBzaW0= | base64 -D | zsh; while true; do :; done # macx-sim-2" &
SIM=$!
sleep 3
read -r got ms fms <<< "$(alert_ms base64-to-shell "$start")"
child=$(pgrep -f "sleep 120" | head -1)
cstate=$([ -n "$child" ] && ps -o stat= -p "$child" | tr -d ' ' || echo "?")
case "$cstate" in T*) cres="yes (state $cstate)" ;; *) cres="**no** (state $cstate)" ;; esac
row "Child started before the alert" base64-to-shell "$got" "$ms" "$fms" "-" "$cres"
pkill -KILL -f "macx-sim-2"; [ -n "$child" ] && kill -KILL "$child" 2>/dev/null; kill -KILL $SIM 2>/dev/null

# 3. dscl password check (user that doesn't exist).
start=$(now)
as_user /usr/bin/dscl . -authonly macx_sim_nouser not-a-password >/dev/null 2>&1
wait_for password-check
read -r got ms fms <<< "$(alert_ms password-check "$start")"
row "dscl -authonly password check" password-check "$got" "$ms" "$fms" "-" "-"

# 4. Hidden Apple-named folder in Application Support.
start=$(now)
as_user /bin/mkdir "$UHOME/Library/Application Support/.com.apple.macx-sim"
wait_for fake-apple-folder
read -r got ms fms <<< "$(alert_ms fake-apple-folder "$start")"
rmdir "$UHOME/Library/Application Support/.com.apple.macx-sim"
row "Hidden .com.apple folder" fake-apple-folder "$got" "$ms" "$fms" "-" "-"

# 5. New launch agent file (never loaded; removed straight away).
start=$(now)
as_user /bin/sh -c "printf '<plist/>' > '$UHOME/Library/LaunchAgents/com.macx-sim.test.plist'"
wait_for new-launch-item
read -r got ms fms <<< "$(alert_ms new-launch-item "$start")"
rm -f "$UHOME/Library/LaunchAgents/com.macx-sim.test.plist"
row "New launch agent written" new-launch-item "$got" "$ms" "$fms" "-" "-"

# 6. Quarantine flag removed.
Q="$WORK/q.txt"; as_user /bin/sh -c "echo x > $Q && xattr -w com.apple.quarantine '0081;00000000;macx-sim;' $Q"
start=$(now)
as_user /usr/bin/xattr -d com.apple.quarantine "$Q"
wait_for quarantine-removed
read -r got ms fms <<< "$(alert_ms quarantine-removed "$start")"
row "Quarantine flag removed" quarantine-removed "$got" "$ms" "$fms" "-" "-"

# 7. Ad-hoc signed program run from a hidden temp folder.
H="$WORK/.macx-sim"; mkdir -p "$H"; cp /bin/echo "$H/tool"; codesign --remove-signature "$H/tool" 2>/dev/null; codesign -s - "$H/tool" 2>/dev/null; chmod 755 "$H" "$H/tool"
start=$(now)
as_user "$H/tool" sim >/dev/null
wait_for exec-from-hidden-or-temp
read -r got ms fms <<< "$(alert_ms exec-from-hidden-or-temp "$start")"
row "Ad-hoc program from hidden folder" exec-from-hidden-or-temp "$got" "$ms" "$fms" "-" "-"

sleep 2
kill "$SAMPLER" 2>/dev/null
stats=$(/usr/bin/python3 -I - "$SAMPLES" "$IDLE_LINES" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 4]
idle = int(sys.argv[2])
def avg(rs, i): return sum(float(r[i]) for r in rs) / len(rs) if rs else 0
def peak(rs, i): return max((float(r[i]) for r in rs), default=0)
a, b = rows[:idle], rows[idle:]
print(f"| Idle (15 s) | {avg(a,0):.1f}% / {avg(a,2):.1f}% | {peak(a,1)/1024:.0f} MB / {peak(a,3)/1024:.0f} MB |")
print(f"| During simulations | {avg(b,0):.1f}% / {avg(b,2):.1f}% (peak {peak(b,0):.1f}% / {peak(b,2):.1f}%) | {peak(b,1)/1024:.0f} MB / {peak(b,3)/1024:.0f} MB |")
PY
)
ALERTS=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
OTHER=$(/usr/bin/python3 -I -c "
import json,collections,sys
c=collections.Counter(json.loads(l)['rule'] for l in open('$LOG'))
print(', '.join(f'{k} ×{v}' for k,v in c.most_common()))" 2>/dev/null)

# Benchmark: eslogger alone, with macx's event set and then with `open` added, under the same file load.
# Measures CPU, memory and how many events per second each produces (open is what makes it heavy).
LOADDIR="$WORK/load"; mkdir -p "$LOADDIR"; for i in $(seq 1 200); do echo "$i" > "$LOADDIR/f$i"; done
load() { local end=$((SECONDS + 20)); while [ $SECONDS -lt $end ]; do cat "$LOADDIR"/f* > /dev/null; /bin/ls "$LOADDIR" > /dev/null; done; }
bench() {
  local label=$1; shift
  set -m
  /usr/bin/eslogger "$@" > "$WORK/bench.jsonl" 2>/dev/null &
  local ES_PID=$!
  set +m
  sleep 2
  : > "$WORK/bench-cpu.txt"
  ( while kill -0 $ES_PID 2>/dev/null; do ps -o %cpu=,rss= -p $ES_PID >> "$WORK/bench-cpu.txt"; sleep 1; done ) &
  local SAMP=$!
  local before; before=$(wc -l < "$WORK/bench.jsonl")
  load
  local after; after=$(wc -l < "$WORK/bench.jsonl")
  kill $ES_PID 2>/dev/null; kill $SAMP 2>/dev/null; wait $ES_PID 2>/dev/null
  /usr/bin/python3 -I - "$WORK/bench-cpu.txt" "$label" $((after - before)) <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 2]
cpu = [float(r[0]) for r in rows]; rss = [int(r[1]) for r in rows]
n = int(sys.argv[3])
print(f"| {sys.argv[2]} | {sum(cpu)/len(cpu) if cpu else 0:.1f}% (peak {max(cpu, default=0):.1f}%) | {max(rss, default=0)/1024:.0f} MB | {n/20:.0f} |")
PY
}
echo "Benchmarking eslogger (20 s each)…"
kill "$SAMPLER" 2>/dev/null
# (Two plain assignments: macOS's bash 3.2 misreads an apostrophe inside "$( ... )".)
B1=$(bench "macx events (exec, create, rename, deleteextattr, btm_launch_item_add)" exec create rename deleteextattr btm_launch_item_add)
B2=$(bench "the same plus open" exec create rename deleteextattr btm_launch_item_add open)
BENCH="$B1
$B2"
echo "$BENCH"

mkdir -p "$(dirname "$OUT")"
{
  echo "# Runtime evaluation: macx watch --suspend"
  echo
  echo "- Date: $(date -u +%Y-%m-%d) · macx $("$MACX" --version) · commit $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) · macOS $(sw_vers -productVersion) ($(uname -m))"
  echo "- Each simulation is harmless (see the top of \`scripts/eval/runtime.sh\`). Times are from just before the action to the alert being logged."
  echo
  echo "## Detection and response"
  echo
  echo "| Simulation | Expected rule | Alert | ms to alert | ms alert → frozen | Work done before frozen | Children frozen |"
  echo "|---|---|---|---|---|---|---|"
  printf '%s' "$RESULTS"
  echo
  echo "*Work done before frozen* is the counter a busy loop reached before it stopped: each step is one shell"
  echo "arithmetic operation plus one small file write."
  echo
  echo "## Overhead (macx / eslogger)"
  echo
  echo "| Period | CPU | Peak memory |"
  echo "|---|---|---|"
  echo "$stats"
  echo
  echo "## eslogger benchmark (same file load: repeatedly reading 200 small files for 20 s)"
  echo
  echo "| Events | eslogger CPU | Peak memory | Events per second |"
  echo "|---|---|---|---|"
  echo "$BENCH"
  echo
  echo "$ALERTS log records so far. \`open\` is left out of \`macx watch\` because of the difference above."
  echo
  echo "## Everything logged during the run"
  echo
  echo "$ALERTS log records: ${OTHER:-none}. Anything here that isn't a simulation is a false positive from normal background activity."
} > "$OUT"
chown "$U" "$OUT" "$(dirname "$OUT")" 2>/dev/null
echo
echo "Written to $OUT"
