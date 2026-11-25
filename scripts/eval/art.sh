#!/bin/bash
# Runs the Atomic Red Team tests in scripts/eval/art-tests.txt against the live watch, on a THROWAWAY macOS
# machine (the art.yml workflow on GitHub's runners). Never run this on a Mac you use: the tests really
# create users, replace the crontab, dump the keychain and load launch daemons.
#
# Needs: passwordless sudo, pwsh with Invoke-AtomicRedTeam 2.3.0 installed for all users, the atomics in $ATOMICS.
# Writes to $OUT: alerts.jsonl (the watch), tests.jsonl (one line per test), persist-*.txt, tcc.jsonl, logs.
# Usage: ATOMICS=... OUT=... MACX=.build/release/macx scripts/eval/art.sh
set -uo pipefail

if [ "${MACX_ART_THROWAWAY:-}" != 1 ]; then
    echo "Refusing: set MACX_ART_THROWAWAY=1 to confirm this is a throwaway machine." >&2
    exit 1
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ATOMICS="${ATOMICS:?path to the atomics folder}"
OUT="${OUT:-art-out}"
MACX="$(cd "$(dirname "${MACX:?path to macx}")" && pwd)/$(basename "$MACX")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
export MACX_NO_UPDATE_CHECK=1
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
# Every command gets /dev/null as input: sudo and pwsh read stdin, and would eat the rest of the test list.
one() { pwsh -NoProfile -NonInteractive -File "$HERE/art-one.ps1" -Technique "$1" -Test "$2" -Mode "$3" -Atomics "$ATOMICS" < /dev/null; }
rootone() { sudo pwsh -NoProfile -NonInteractive -File "$HERE/art-one.ps1" -Technique "$1" -Test "$2" -Mode "$3" -Atomics "$ATOMICS" < /dev/null; }

# The watch in its own process group (eslogger leaves out events from its own group).
set -m
sudo MACX_NO_UPDATE_CHECK=1 "$MACX" watch --min-severity info --log "$OUT/alerts.jsonl" > "$OUT/watch.out" 2>&1 &
set +m
for _ in $(seq 1 60); do grep -q "^Watching" "$OUT/watch.out" 2>/dev/null && break; sleep 1; done
grep "^Watching" "$OUT/watch.out" || { echo "The watch didn't start:"; cat "$OUT/watch.out"; exit 1; }
sleep 3
ls -ld "$HOME/Library/Application Support/Macximesed" "$HOME/Library/Application Support/Macximesed"/* > "$OUT/support-owners.txt" 2>&1

baseline() {
    { echo "== $(date -u +%T) user"; "$MACX" persist --baseline; echo "== sudo"; sudo "$MACX" persist --baseline; } >> "$OUT/baselines.log" 2>&1 < /dev/null
}
persist_diff() {  # $1 = file
    { echo "== as the user"; "$MACX" persist --diff 2>&1; echo "== with sudo"; sudo "$MACX" persist --diff 2>&1; } > "$1" < /dev/null
}

n=0
while read -r tech test want _ <&3; do
    case "$tech" in "" | \#*) continue ;; esac
    n=$((n + 1))
    id="$tech-$test"
    as=$(one "$tech" "$test" info 2>/dev/null | tail -1)
    [ "$as" = root ] && run=rootone || run=one
    echo "::group::[$n] $id ($as) want $want"
    $run "$tech" "$test" prereq > "$OUT/$id.prereq.log" 2>&1
    case "$want" in *persist*) baseline ;; esac
    # ART_CAPTURE="T1027-1 ...": keep the raw exec events of those tests, to replay with `macx watch --replay`.
    capture=""
    case " ${ART_CAPTURE:-} " in *" $id "*)
        set -m
        sudo /usr/bin/eslogger exec > "$OUT/$id.exec.jsonl" 2> /dev/null < /dev/null &
        set +m
        capture=1
        sleep 2
        ;;
    esac
    start=$(now)
    $run "$tech" "$test" run > "$OUT/$id.run.log" 2>&1
    status=$?
    if [ -n "$capture" ]; then sleep 2; sudo pkill -INT -f "^/usr/bin/eslogger exec$" || true; sleep 2; fi
    sleep 5
    end=$(now)
    pfile=""
    case "$want" in *persist*) pfile="persist-$id.txt"; persist_diff "$OUT/$pfile" ;; esac
    $run "$tech" "$test" cleanup > "$OUT/$id.cleanup.log" 2>&1
    tail -15 "$OUT/$id.run.log"
    echo "::endgroup::"
    python3 -c 'import json,sys; print(json.dumps(dict(id=sys.argv[1], technique=sys.argv[2], test=int(sys.argv[3]), want=sys.argv[4], as_=sys.argv[5], start=float(sys.argv[6]), end=float(sys.argv[7]), status=int(sys.argv[8]), persist=sys.argv[9] or None)))' \
        "$id" "$tech" "$test" "$want" "$as" "$start" "$end" "$status" "$pfile" >> "$OUT/tests.jsonl"
done 3< "$HERE/art-tests.txt"

# Ordinary work with the watch on: every alert here at medium or above is a false alarm.
echo "::group::benign workload"
start=$(now)
W="$(mktemp -d)"
(
    cd "$W"
    brew install --quiet tree
    git clone --quiet --depth 1 https://github.com/apple/swift-argument-parser.git
    curl -fsSL -o release.tar.gz https://github.com/LAOUUUUU/Macximesed/releases/download/v0.3.0/macx-v0.3.0-macos-universal.tar.gz
    tar -xzf release.tar.gz
    python3 -m venv venv && ./venv/bin/pip install --quiet requests
    mkdir pkg && cd pkg && swift package init --type executable --name Hello >/dev/null && swift build -c release >/dev/null
) > "$OUT/benign.log" 2>&1 < /dev/null
sleep 5
end=$(now)
echo "::endgroup::"
python3 -c 'import json,sys; print(json.dumps(dict(id="benign", technique="benign", test=0, want="-", as_="user", start=float(sys.argv[1]), end=float(sys.argv[2]), status=0, persist=None)))' "$start" "$end" >> "$OUT/tests.jsonl"

# Privacy grants: what eslogger's tcc_modify really contains, and which ways of granting don't show up at all.
echo "::group::privacy grants (tcc_modify)"
# eslogger buffers what it writes to a file and loses it when killed. With job control on, the background job
# doesn't ignore SIGINT, which eslogger handles by flushing and exiting.
set -m
sudo /usr/bin/eslogger tcc_modify exec > "$OUT/tcc.jsonl" 2> "$OUT/tcc.err" &
set +m
sleep 3
start=$(now)
{
    echo "-- marker (shows whether eslogger's output was flushed)"
    /bin/echo macx-tcc-marker
    echo "-- screencapture -x (in run 1 this made replayd grant Screen Recording)"
    screencapture -x "$OUT/shot.png"; echo "screencapture exit $?"
    echo "-- tccutil reset ScreenCapture com.apple.Terminal (user)"
    tccutil reset ScreenCapture com.apple.Terminal
    echo "-- private TCC.framework call, as the user and as root"
    swiftc -O -o "$OUT/tccset" "$HERE/art-tccset.swift" && "$OUT/tccset" && sudo "$OUT/tccset"
    echo "-- direct sqlite3 write to the user's TCC.db (bypasses tccd)"
    sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
        "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('kTCCServiceScreenCapture','com.apple.Terminal',0,2,3,1,'UNUSED',0,strftime('%s','now'));"
    echo "sqlite3 exit $?"
} > "$OUT/tcc-actions.log" 2>&1
sleep 5
end=$(now)
sudo pkill -INT -f "^/usr/bin/eslogger tcc_modify" || true
sleep 3
python3 -c 'import json,sys; print(json.dumps(dict(id="tcc", technique="tcc", test=0, want="privacy-granted", as_="both", start=float(sys.argv[1]), end=float(sys.argv[2]), status=0, persist=None)))' "$start" "$end" >> "$OUT/tests.jsonl"
cat "$OUT/tcc-actions.log"
echo "events: $(wc -l < "$OUT/tcc.jsonl"), marker seen: $(grep -c macx-tcc-marker "$OUT/tcc.jsonl"), tcc_modify: $(grep -c '"tcc_modify"' "$OUT/tcc.jsonl")"
echo "::endgroup::"

sleep 3
sudo pkill -TERM -f "macx watch --min-severity info" || true
sleep 2
echo "Done: $n tests, $(wc -l < "$OUT/alerts.jsonl" 2>/dev/null || echo 0) alerts."
