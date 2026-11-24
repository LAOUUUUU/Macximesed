#!/bin/bash
# Atomic Red Team for the detonation chamber (research/detonation-chamber/PHASE2.md, step 4). Each test's command,
# with its default inputs filled in, becomes a script that runs with `macx chamber run --no-quarantine`, inside
# the throwaway VM. Nothing runs on this Mac itself: the VM has no network and sees only its bait home folder.
# Usage: scripts/eval/chamber-art.sh [macx] [out-dir]      (needs `macx chamber setup` done, and ruby)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MACX="${1:-$HOME/.local/bin/macx}"
OUT="${2:-$(mktemp -d)}"
COMMIT=a0e3f9bc69fed2fd711bd1f1aa87a40c33482fe6
mkdir -p "$OUT/scripts"
export MACX_NO_UPDATE_CHECK=1

# The pinned atomics: read as data, never run here.
if [ ! -d "$OUT/atomics" ]; then
    curl -fsSL "https://github.com/redcanaryco/atomic-red-team/archive/$COMMIT.tar.gz" -o "$OUT/atomics.tar.gz" || exit 1
    mkdir -p "$OUT/atomics" && tar -xzf "$OUT/atomics.tar.gz" -C "$OUT/atomics" --strip-components 2 \
        "atomic-red-team-$COMMIT/atomics" || exit 1
fi

# One script per test: the command with #{input} replaced by its default, under a #! for its executor.
while read -r tech test want _ <&3; do
    case "$tech" in "" | \#*) continue ;; esac
    ruby -ryaml -e '
        t = YAML.load_file(ARGV[0])["atomic_tests"][ARGV[1].to_i - 1] or exit 1
        cmd = t["executor"]["command"].to_s
        (t["input_arguments"] || {}).each { |k, v| cmd = cmd.gsub("\#{#{k}}", v["default"].to_s) }
        shell = t["executor"]["name"] == "bash" ? "/bin/bash" : "/bin/sh"
        puts "#!#{shell}", cmd' "$OUT/atomics/$tech/$tech.yaml" "$test" > "$OUT/scripts/$tech-$test.sh" 3<&- || continue
done 3< "$HERE/chamber-art-tests.txt"

echo "Scripts: $(ls "$OUT/scripts" | wc -l | tr -d ' ') in $OUT/scripts"
# Running them (`$MACX chamber run --no-quarantine --seconds 30 FILE`) and scoring against chamber-art-tests.txt
# come with step 4.
echo "Running and scoring aren't built yet (PHASE2.md step 4)."
