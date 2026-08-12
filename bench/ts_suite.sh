#!/usr/bin/env bash
# Divergence sweep: ztsc vs tsgo over Microsoft's TypeScript compiler and
# conformance test corpus (~12k cases). Discovery tool, not a gate — its output
# is a prioritized queue of divergences to fix.
#
# Usage: bench/ts_suite.sh [--limit N] [--filter SUBSTR] [--jobs N]
#                          [--timeout S] [--faithful] [--keep]
#   TSGO=/path/to/tsc     override the oracle binary (same mechanism as
#                         bench/e2e.sh and bench/convergence.sh: the pinned
#                         install under bench/baselines/tsgo, npm-installed on
#                         demand, node_modules gitignored)
#
# The corpus is fetched, never committed (Apache-2.0 upstream, MIT here) — run
# bench/fetch_ts_suite.sh first; see that script for the pin and the licensing
# rationale, and bench/ts_suite.py for what the pragma translation does and
# does not preserve.
#
# Outputs (all gitignored, under bench/ts-suite/):
#   report.md    summary + skip census + top divergent codes + per-case list
#   report.tsv   the same, machine-readable
set -euo pipefail

cd "$(dirname "$0")/.."

CORPUS=bench/ts-suite/TypeScript
if [ ! -d "$CORPUS/tests/cases/compiler" ]; then
    echo "corpus missing — run bench/fetch_ts_suite.sh first" >&2
    exit 1
fi

# The oracle, resolved exactly as bench/e2e.sh does: the pinned baseline
# package's platform binary (no Node wrapper), npm-installed on demand.
if [ -z "${TSGO:-}" ]; then
    dir=bench/baselines/tsgo
    if [ ! -d "$dir/node_modules/typescript" ]; then
        command -v npm >/dev/null || { echo "npm not found — set TSGO=" >&2; exit 1; }
        echo "installing the pinned tsgo baseline in $dir ..."
        (cd "$dir" && npm install --no-audit --no-fund --loglevel=error >/dev/null)
    fi
    case "$(uname -m)" in
        arm64 | aarch64) ARCH=arm64 ;;
        x86_64) ARCH=x64 ;;
        *) ARCH="$(uname -m)" ;;
    esac
    PLAT="$(uname | tr '[:upper:]' '[:lower:]')"
    TSGO="$dir/node_modules/@typescript/typescript-$PLAT-$ARCH/lib/tsc"
fi
[ -x "$TSGO" ] || { echo "oracle not executable: $TSGO" >&2; exit 1; }

# Build and run in one command so a failed build cannot leave the sweep
# measuring a stale binary (bench/CLAUDE-note: never run concurrent zig builds).
echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null

exec python3 bench/ts_suite.py --tsgo "$TSGO" "$@"
