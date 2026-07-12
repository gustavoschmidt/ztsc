#!/usr/bin/env bash
# End-to-end benchmark (PLAN.md M5/M6): full pipeline (tsconfig -> discover
# -> load -> scan -> parse -> bind -> link -> check) on a corpus, swept
# over --checkers=1,2,4,8, vs real tsc and tsgo (TypeScript 7 native
# preview) when available.
#
# Reports wall clock and peak RSS via /usr/bin/time (-l on macOS, -v on
# Linux), plus ztsc's per-checker type counts (the duplicated-types
# overhead of PLAN §2.3).
#
# Usage: bench/e2e.sh [corpus] [checkers...]
#   corpus: small | medium | multi (default: multi)
#   TSC=/path/to/typescript/bin/tsc   override the tsc under test
#   TSGO=/path/to/tsgo                override the tsgo under test
#   RUNS=N                            timed runs per configuration (default 3;
#                                     the median is what BENCHMARKS.md reports)
set -euo pipefail

cd "$(dirname "$0")/.."

NAME=multi
if [ $# -gt 0 ] && [ -d "bench/corpus/$1" -o "$1" = small -o "$1" = medium -o "$1" = multi ]; then
    NAME="$1"
    shift
fi
CHECKERS=("${@:-1}")
if [ $# -eq 0 ]; then CHECKERS=(1 2 4 8); fi
RUNS="${RUNS:-3}"

CORPUS=bench/corpus/$NAME
if [ ! -d "$CORPUS" ]; then
    node bench/gen_corpus.js
fi

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN=zig-out/bench/ztsc

NFILES=$(find "$CORPUS" -name '*.ts' | wc -l | tr -d ' ')
LOC=$(find "$CORPUS" -name '*.ts' -print0 | xargs -0 cat | wc -l | tr -d ' ')
echo "corpus: $NAME ($NFILES files, $LOC lines), project: $CORPUS/tsconfig.json, runs: $RUNS (median)"
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

# run_median <label> <cmd...>: RUNS timed runs (after one warm-up), prints
# "  <label>: wall <median>s  peakRSS <max>MB" plus each run in brackets.
run_median() {
    local label="$1"
    shift
    "$@" >/dev/null 2>&1 || true # warm-up (also warms the FS cache)
    local walls=() rsss=()
    for _ in $(seq "$RUNS"); do
        local out stats
        out=$("${TIME_CMD[@]}" "$@" 2>&1 || true)
        stats=$(echo "$out" | extract_wall_rss)
        walls+=("${stats% *}")
        rsss+=("${stats#* }")
    done
    local wall_med rss_max
    wall_med=$(printf '%s\n' "${walls[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    rss_max=$(printf '%s\n' "${rsss[@]}" | sort -n | tail -1)
    echo "  $label: wall ${wall_med}s  peakRSS ${rss_max}MB  (runs: ${walls[*]})"
}

echo "== ztsc, --checkers sweep (via -p $CORPUS) =="
for n in "${CHECKERS[@]}"; do
    run_median "ztsc --checkers=$n" "$BIN" --pretty=false --checkers="$n" -p "$CORPUS"
    out=$("$BIN" --pretty=false --checkers="$n" --timing --memory -p "$CORPUS" 2>&1 || true)
    check_ms=$(echo "$out" | awk '$1 == "check" && $2 ~ /^[0-9]/ { print $2 }')
    types=$(echo "$out" | awk '/check types \(total\)/ { print $4 }')
    type_bytes=$(echo "$out" | awk '/check type-arena bytes/ { print $4 }')
    echo "      check ${check_ms}ms  types $types  type-bytes $type_bytes"
done
echo

echo "== tsc (--noEmit -p $CORPUS) =="
TSC="${TSC:-$(command -v tsc || true)}"
if [ -n "$TSC" ]; then
    run_median "tsc $(node "$TSC" --version 2>/dev/null | awk '{print $2}')" node "$TSC" -p "$CORPUS"
else
    echo "  tsc not found (set TSC=/path/to/typescript/bin/tsc) — skipped"
fi
echo

echo "== tsgo (--noEmit -p $CORPUS) =="
TSGO="${TSGO:-$(command -v tsgo || true)}"
if [ -n "$TSGO" ]; then
    run_median "tsgo $("$TSGO" --version 2>/dev/null | awk '{print $2}')" "$TSGO" -p "$CORPUS"
else
    echo "  tsgo not found (set TSGO=/path/to/tsgo) — skipped"
fi
