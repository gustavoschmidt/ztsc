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
#   TSC=/path/to/typescript/bin/tsc   override the tsc under test (a JS entry
#                                     point run via node — not a PATH shim)
#   TSGO=/path/to/native/tsc          override the native TypeScript binary
#   RUNS=N                            timed runs per configuration (default 3;
#                                     the median is what BENCHMARKS.md reports)
#
# Baselines default to the pinned installs under bench/baselines/ (tsc 5.5.4
# via node; native TS — "tsgo" — invoked as the platform binary directly, no
# Node wrapper, so RSS is measured on the real process). Installed on demand
# with npm; node_modules stays gitignored.
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

# ensure_baseline <dir>: npm-install the pinned baseline package under
# bench/baselines/<dir> if its node_modules is missing. Prints nothing on
# the happy path; returns nonzero (with a note) if npm is unavailable/fails.
ensure_baseline() {
    local dir="bench/baselines/$1"
    [ -d "$dir/node_modules/typescript" ] && return 0
    if ! command -v npm >/dev/null; then
        echo "  npm not found — cannot install $dir baseline" >&2
        return 1
    fi
    echo "  installing pinned baseline in $dir ..."
    (cd "$dir" && npm install --no-audit --no-fund --loglevel=error >/dev/null) || {
        echo "  npm install failed in $dir" >&2
        return 1
    }
}

# run_median <label> <cmd...>: RUNS timed runs (after one warm-up that also
# sanity-checks the command), prints "  <label>: wall <median>s
# peakRSS <max>MB" plus each run in brackets. The bench corpora are clean
# by design, so a nonzero warm-up exit means the tool isn't actually
# running (e.g. node choking on a PATH shim) — skip loudly instead of
# timing the crash as a result.
run_median() {
    local label="$1"
    shift
    local warm_status=0
    "$@" >/dev/null 2>&1 || warm_status=$? # warm-up (also warms the FS cache)
    if [ "$warm_status" -ne 0 ]; then
        echo "  $label: warm-up exited $warm_status — skipped, output was:"
        "$@" 2>&1 | head -3 | sed 's/^/      /' || true
        return 0
    fi
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

echo "== tsc (-p $CORPUS, noEmit via tsconfig) =="
if [ -z "${TSC:-}" ] && ensure_baseline tsc; then
    TSC=bench/baselines/tsc/node_modules/typescript/bin/tsc
fi
if [ -n "${TSC:-}" ] && [ -f "$TSC" ]; then
    run_median "tsc $(node "$TSC" --version 2>/dev/null | awk '{print $2}')" node "$TSC" -p "$CORPUS"
else
    echo "  tsc baseline unavailable (set TSC=/path/to/typescript/bin/tsc) — skipped"
fi
echo

echo "== tsgo / native tsc (-p $CORPUS, noEmit via tsconfig) =="
if [ -z "${TSGO:-}" ] && ensure_baseline tsgo; then
    # TS 7 stable merged tsgo into the typescript package; the platform
    # binary is what we time (no Node wrapper), so RSS is the real process.
    case "$(uname -m)" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64) ARCH=x64 ;;
        *) ARCH="$(uname -m)" ;;
    esac
    PLAT="$(uname | tr '[:upper:]' '[:lower:]')"
    TSGO="bench/baselines/tsgo/node_modules/@typescript/typescript-$PLAT-$ARCH/lib/tsc"
fi
if [ -n "${TSGO:-}" ] && [ -x "$TSGO" ]; then
    run_median "tsgo $("$TSGO" --version 2>/dev/null | awk '{print $2}')" "$TSGO" -p "$CORPUS"
else
    echo "  native tsc (tsgo) baseline unavailable (set TSGO=/path/to/native/tsc) — skipped"
fi
