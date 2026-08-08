#!/usr/bin/env bash
# App benchmark: wall clock and peak RSS on a real application checkout
# under bench/apps, against tsgo, reported against the project's bars
# (wall <= 1/2 of tsgo, peak RSS <= 1/5 of tsgo).
#
# Unlike bench/e2e.sh (synthetic corpora) this drives the staged app
# checkouts, each of which needs its own bench tsconfig.
#
# Usage: bench/app_bench.sh [app] [checkers...]
#   app:      immich | excalidraw | outline | social-app | vscode
#             (default: immich)
#   checkers: one or more --checkers values (default: 1 4)
#
#   RUNS=N     timed runs per configuration (default 5; median reported)
#   BIN=path   ztsc binary to measure (default: build into a private
#              prefix so concurrent agents/sessions cannot clobber it)
#   TSGO=path  native tsc binary (default: the pinned baseline install)
#   NO_TSGO=1  skip the baseline leg (A/B against a recorded number)
#
# ztsc and tsgo runs are INTERLEAVED round-robin rather than run in two
# blocks: sequential blocks drift by several ms as the machine warms, and
# the ratio is what the bars are stated in.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-immich}"
[ $# -gt 0 ] && shift
CHECKERS=("$@")
[ ${#CHECKERS[@]} -eq 0 ] && CHECKERS=(1 4)
RUNS="${RUNS:-5}"

# Each app needs the bench tsconfig staged for it; the stock configs use
# options tsgo has removed, so it would exit without checking anything.
case "$APP" in
    immich)     PROJ=bench/apps/immich/server/tsconfig.bench.json ;;
    excalidraw) PROJ=bench/apps/excalidraw/tsconfig.tsgo.json ;;
    outline)    PROJ=bench/apps/outline/tsconfig.bench.json ;;
    social-app) PROJ=bench/apps/social-app/tsconfig.check.json ;;
    vscode)     PROJ=bench/apps/vscode/src/tsconfig.bench.json ;;
    *) echo "unknown app: $APP" >&2; exit 2 ;;
esac

if [ ! -f "$PROJ" ]; then
    echo "missing $PROJ — is bench/apps/$APP checked out? (bench/apps is gitignored)" >&2
    exit 2
fi

if [ -z "${BIN:-}" ]; then
    # A private prefix, so a concurrently-running agent building into
    # zig-out cannot swap the binary out from under a measurement.
    PREFIX="${TMPDIR:-/tmp}/ztsc-app-bench-$$"
    echo "== building ztsc (ReleaseFast) -> $PREFIX ==" >&2
    zig build bench --prefix "$PREFIX/out" --cache-dir "$PREFIX/cache" >/dev/null
    BIN="$PREFIX/out/bench/ztsc"
    trap 'rm -rf "$PREFIX"' EXIT
fi

if [ -z "${TSGO:-}" ]; then
    PLAT=$(uname | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=x64; [ "$ARCH" = "aarch64" ] && ARCH=arm64
    TSGO="bench/baselines/tsgo/node_modules/@typescript/typescript-$PLAT-$ARCH/lib/tsc"
fi

case "$(uname)" in
    Darwin) TIME_CMD=(/usr/bin/time -l) ;;
    *)      TIME_CMD=(/usr/bin/time -v) ;;
esac

# "<wall_s> <peak_rss_bytes>" from /usr/bin/time -l (macOS) or -v (Linux).
extract() {
    awk '
        / real /                        { wall = $1 }
        /maximum resident set size/     { rss  = $1 }
        /Elapsed \(wall clock\)/        { split($NF, t, ":"); wall = t[1]*60 + t[2] }
        /Maximum resident set size/     { rss  = $6 * 1024 }
        END { printf "%s %s\n", wall, rss }
    '
}

median() { sort -n | awk '{v[NR]=$1} END {print (NR%2) ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2}'; }

# Round-robin one run of each configuration per pass, so all legs see the
# same machine conditions. Plain indexed arrays kept in step by position:
# macOS ships bash 3.2, which has no associative arrays.
LEGS=()
for c in "${CHECKERS[@]}"; do LEGS+=("ztsc:$c"); done
TSGO_LEG=-1
if [ -x "$TSGO" ] && [ -z "${NO_TSGO:-}" ]; then
    TSGO_LEG=${#LEGS[@]}
    LEGS+=("tsgo:-")
fi

WALLS=(); RSSES=()
for i in "${!LEGS[@]}"; do WALLS[$i]=""; RSSES[$i]=""; done

echo "app: $APP ($PROJ), runs: $RUNS (median), interleaved" >&2
for _ in $(seq "$RUNS"); do
    for i in "${!LEGS[@]}"; do
        leg="${LEGS[$i]}"; tool="${leg%%:*}"; c="${leg##*:}"
        if [ "$tool" = ztsc ]; then
            out=$("${TIME_CMD[@]}" "$BIN" -p "$PROJ" --checkers="$c" 2>&1 | extract)
        else
            out=$("${TIME_CMD[@]}" "$TSGO" -p "$PROJ" 2>&1 | extract)
        fi
        WALLS[$i]="${WALLS[$i]}${out%% *}"$'\n'
        RSSES[$i]="${RSSES[$i]}${out##* }"$'\n'
    done
done

tw=""; tr=""
if [ "$TSGO_LEG" -ge 0 ]; then
    tw=$(printf '%s' "${WALLS[$TSGO_LEG]}" | median)
    tr=$(printf '%s' "${RSSES[$TSGO_LEG]}" | median)
fi

printf '\n%-14s %9s %11s %9s %9s\n' config wall rss wall/tsgo rss/tsgo
for i in "${!LEGS[@]}"; do
    leg="${LEGS[$i]}"; tool="${leg%%:*}"; c="${leg##*:}"
    w=$(printf '%s' "${WALLS[$i]}" | median)
    r=$(printf '%s' "${RSSES[$i]}" | median)
    label=$([ "$tool" = ztsc ] && echo "ztsc c$c" || echo tsgo)
    if [ -n "$tw" ] && [ "$tool" = ztsc ]; then
        # Bars: wall <= 50% of tsgo, peak RSS <= 20% of tsgo.
        awk -v l="$label" -v w="$w" -v r="$r" -v tw="$tw" -v tr="$tr" 'BEGIN {
            wp = 100*w/tw; rp = 100*r/tr
            printf "%-14s %8.2fs %9.0fMB %8.0f%%%s %7.0f%%%s\n", l, w, r/1048576, wp,
                   (wp <= 50 ? " " : "!"), rp, (rp <= 20 ? " " : "!")
        }'
    else
        awk -v l="$label" -v w="$w" -v r="$r" 'BEGIN {
            printf "%-14s %8.2fs %9.0fMB %9s %9s\n", l, w, r/1048576, "-", "-"
        }'
    fi
done
[ -n "$tw" ] && echo && echo "bars: wall <= $(awk -v t="$tw" 'BEGIN{printf "%.2fs", t/2}'), peak RSS <= $(awk -v t="$tr" 'BEGIN{printf "%.0fMB", t/5/1048576}')  ('!' marks a breach)"
