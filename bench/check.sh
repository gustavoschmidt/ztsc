#!/usr/bin/env bash
# Checker micro-benchmark (M4).
#
# Usage: bench/check.sh [small|medium] [repeat]
#
# Builds the ReleaseFast binary and reports the check phase's throughput
# (lines/s) plus the key M4 memory metrics: types created, types/line,
# bytes/type, relation-cache entries and hit rate, and the scratch-arena
# high-water mark. The check phase is single-threaded in M4 (M5 adds
# N-checker partitioning), so no worker sweep here. `repeat` re-checks
# each file N times inside the check phase (default 20).
set -euo pipefail

cd "$(dirname "$0")/.."

SIZE="${1:-medium}"
REPEAT="${2:-20}"
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

$BIN --timing --memory --repeat="$REPEAT" $FILES |
    grep -E '^ztsc:|  check |check types|check type-arena|bytes/type|types/line|relation|check scratch|check flow' || true
