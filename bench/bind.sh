#!/usr/bin/env bash
# Binder micro-benchmark (PLAN.md M3).
#
# Usage: bench/bind.sh [small|medium] [repeat]
#
# Builds the ReleaseFast binary and reports the bind phase's throughput
# (lines/s, MB/s) at 1/2/4/8 workers, plus the key M3 memory metric:
# binder bytes/line (symbol + scope + flow + record bytes over source
# lines). `repeat` re-binds each file N times inside the bind phase so the
# measurement dominates process startup, loading, and parsing (default 50).
# Note: since single-owner discovery, the per-phase rows are summed
# per-file worker times (throughput per core); the 'discover' row is the
# front-end wall clock and shows the parallel scaling across workers.
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
    echo "== bind, workers=$W =="
    $BIN --timing --memory --workers="$W" --repeat="$REPEAT" $FILES |
        grep -E '^ztsc:|  bind |  discover |bind symbols|bind scopes|bind flow nodes|bind .* bytes|bind bytes/line' || true
    echo
done
