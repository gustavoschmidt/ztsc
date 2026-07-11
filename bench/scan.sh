#!/usr/bin/env bash
# Scanner micro-benchmark (PLAN.md M1).
#
# Usage: bench/scan.sh [small|medium] [repeat]
#
# Builds the ReleaseFast binary and reports the scan phase's throughput
# (MB/s, lines/s) at 1/2/4/8 workers, plus bytes/token. `repeat` re-scans
# each file N times inside the scan phase so the measurement dominates
# process startup and file loading (default 50).
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
    echo "== scan, workers=$W =="
    $BIN --timing --memory --workers="$W" --repeat="$REPEAT" $FILES |
        grep -E '^ztsc:|  scan |tokens|bytes/token' || true
    echo
done
