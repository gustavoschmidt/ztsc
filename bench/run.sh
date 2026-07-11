#!/usr/bin/env bash
# Benchmark harness for ztsc (PLAN.md §3).
#
# Usage: bench/run.sh [small|medium]
#
# - Generates the synthetic corpus if missing (bench/gen_corpus.js).
# - Builds the ReleaseFast binary via `zig build bench`.
# - Runs ztsc under /usr/bin/time capturing wall clock + peak RSS.
# - If `tsgo` or `tsc` (via npx, no network install) is available, runs the
#   same corpus through them for comparison; otherwise skips with a note.
set -euo pipefail

cd "$(dirname "$0")/.."

SIZE="${1:-small}"
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
zig build bench
BIN=zig-out/bench/ztsc

FILES=$(find "$CORPUS" -name '*.ts' | sort)
NFILES=$(echo "$FILES" | wc -l | tr -d ' ')
LOC=$(cat $FILES | wc -l | tr -d ' ')
echo "corpus: $SIZE ($NFILES files, $LOC lines)"
echo

# /usr/bin/time flags differ: -l on macOS (RSS in bytes), -v on Linux (KB).
if [ "$(uname)" = "Darwin" ]; then
    TIME_CMD=(/usr/bin/time -l)
else
    TIME_CMD=(/usr/bin/time -v)
fi

run_timed() {
    # run_timed <label> <cmd...>
    local label="$1"
    shift
    echo "== $label =="
    local out
    out=$({ "${TIME_CMD[@]}" "$@"; } 2>&1) || {
        echo "$out"
        echo "($label failed)"
        echo
        return 0
    }
    echo "$out"
    # Summarize wall clock + peak RSS.
    if [ "$(uname)" = "Darwin" ]; then
        local wall rss
        wall=$(echo "$out" | awk '/ real /{print $1}')
        rss=$(echo "$out" | awk '/maximum resident set size/{print $1}')
        [ -n "$rss" ] && echo ">>> $label: wall ${wall}s, peak RSS $((rss / 1024 / 1024)) MB"
    else
        local wall rss
        wall=$(echo "$out" | awk -F': ' '/Elapsed \(wall clock\)/{print $2}')
        rss=$(echo "$out" | awk -F': ' '/Maximum resident set size/{print $2}')
        [ -n "$rss" ] && echo ">>> $label: wall $wall, peak RSS $((rss / 1024)) MB"
    fi
    echo
}

run_timed "ztsc ($SIZE)" $BIN --timing --memory $FILES

# --- Comparison: tsgo -------------------------------------------------------
if command -v tsgo >/dev/null 2>&1; then
    run_timed "tsgo ($SIZE)" tsgo --noEmit -p "$CORPUS"
else
    echo "note: tsgo not found on PATH; skipping tsgo comparison"
fi

# --- Comparison: tsc (only if already installed; never block on npm) --------
if command -v npx >/dev/null 2>&1 && npx --no-install tsc --version >/dev/null 2>&1; then
    run_timed "tsc ($SIZE)" npx --no-install tsc --noEmit -p "$CORPUS"
else
    echo "note: tsc not installed (npx --no-install tsc failed); skipping tsc comparison"
fi
