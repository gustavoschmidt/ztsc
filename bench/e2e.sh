#!/usr/bin/env bash
# End-to-end benchmark (PLAN.md M5): full pipeline (discover -> load ->
# scan -> parse -> bind -> link -> check) on the multi-file corpus
# (bench/corpus/multi: ~200 files / ~93k LOC, layered cross-import graph),
# swept over --checkers=1,2,4,8, vs real tsc (and tsgo when available).
#
# Reports wall clock and peak RSS via /usr/bin/time (-l on macOS, -v on
# Linux), plus ztsc's per-checker type counts (the duplicated-types
# overhead of PLAN §2.3).
#
# Usage: bench/e2e.sh [checkers...]
#   TSC=/path/to/typescript/bin/tsc   override the tsc under test
set -euo pipefail

cd "$(dirname "$0")/.."

CHECKERS=("${@:-1}")
if [ $# -eq 0 ]; then CHECKERS=(1 2 4 8); fi

CORPUS=bench/corpus/multi
if [ ! -d "$CORPUS" ]; then
    node bench/gen_corpus.js
fi

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN=zig-out/bench/ztsc

NFILES=$(find "$CORPUS" -name '*.ts' | wc -l | tr -d ' ')
LOC=$(find "$CORPUS" -name '*.ts' -print0 | xargs -0 cat | wc -l | tr -d ' ')
echo "corpus: multi ($NFILES files, $LOC lines), entry: $CORPUS/entry.ts"
echo

case "$(uname)" in
    Darwin) TIME_CMD=(/usr/bin/time -l) ;;
    *) TIME_CMD=(/usr/bin/time -v) ;;
esac

extract_wall_rss() {
    # Parses /usr/bin/time -l (macOS) or -v (Linux) output on stdin ->
    # "<wall_s> <peak_rss_mb>".
    awk '
        / real / { wall = $1 }
        /maximum resident set size/ { rss = $1 }           # macOS: bytes
        /Elapsed \(wall clock\)/ { split($NF, t, ":"); wall = t[1]*60 + t[2] }
        /Maximum resident set size/ { rss = $6 * 1024 }    # Linux: kB
        END { printf "%s %.1f", wall, rss / 1048576 }
    '
}

echo "== ztsc, --checkers sweep =="
for n in "${CHECKERS[@]}"; do
    out=$("${TIME_CMD[@]}" "$BIN" --checkers="$n" --timing --memory "$CORPUS/entry.ts" 2>&1)
    stats=$(echo "$out" | extract_wall_rss)
    check_ms=$(echo "$out" | awk '$1 == "check" && $2 ~ /^[0-9]/ { print $2 }')
    types=$(echo "$out" | awk '/check types \(total\)/ { print $4 }')
    type_bytes=$(echo "$out" | awk '/check type-arena bytes/ { print $4 }')
    echo "  ztsc --checkers=$n: wall ${stats% *}s  peakRSS ${stats#* }MB  check ${check_ms}ms  types $types  type-bytes $type_bytes"
done
echo

echo "== tsc (tsc --noEmit -p $CORPUS) =="
TSC="${TSC:-$(command -v tsc || true)}"
if [ -n "$TSC" ]; then
    out=$("${TIME_CMD[@]}" node "$TSC" -p "$CORPUS" 2>&1 || true)
    stats=$(echo "$out" | extract_wall_rss)
    echo "  tsc: wall ${stats% *}s  peakRSS ${stats#* }MB"
else
    echo "  tsc not found (set TSC=/path/to/typescript/bin/tsc) — skipped"
fi
echo

echo "== tsgo =="
if command -v tsgo >/dev/null 2>&1; then
    out=$("${TIME_CMD[@]}" tsgo --noEmit -p "$CORPUS" 2>&1 || true)
    stats=$(echo "$out" | extract_wall_rss)
    echo "  tsgo: wall ${stats% *}s  peakRSS ${stats#* }MB"
else
    echo "  tsgo not found — skipped"
fi
