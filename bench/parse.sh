#!/usr/bin/env bash
# Parser micro-benchmark (PLAN.md M2).
#
# Usage: bench/parse.sh [small|medium] [repeat]
#
# Builds the ReleaseFast binary and reports the parse phase's throughput
# (lines/s, MB/s) at 1/2/4/8 workers, plus the key M2 memory metric:
# bytes/node (node SoA + extra_data) and nodes/line. `repeat` re-parses each
# file N times inside the parse phase so the measurement dominates process
# startup and file loading (default 50).
set -euo pipefail

cd "$(dirname "$0")/.."

SIZE="${1:-medium}"
REPEAT="${2:-50}"
CORPUS="bench/corpus/$SIZE"

if [ ! -d "$CORPUS" ]; then
    if command -v node >/dev/null 2>&1; then
        node bench/gen_corpus.js
    else
        echo "error: corpus $CORPUS missing and node not available to generate it" >&2
        exit 1
    fi
fi

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN=zig-out/bench/ztsc

FILES=$(find "$CORPUS" -name '*.ts' | sort)
NFILES=$(echo "$FILES" | wc -l | tr -d ' ')
LOC=$(cat $FILES | wc -l | tr -d ' ')
echo "corpus: $SIZE ($NFILES files, $LOC lines), repeat: $REPEAT"
echo

for W in 1 2 4 8; do
    echo "== parse, workers=$W =="
    $BIN --timing --memory --workers="$W" --repeat="$REPEAT" $FILES |
        grep -E '^ztsc:|  parse |ast nodes|bytes/node|nodes/line|extra_data' || true
    echo
done
