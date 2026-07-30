#!/usr/bin/env bash
# Dogfood sweep: the private application × --checkers=1..N, repeated, scored
# against a cached tsc oracle run. The fourth standing gate, next to
# bench/crash_sweep.sh, bench/repeat_sweep.sh and bench/convergence.sh.
#
# Usage:
#   DOG=~/code/app bench/dogfood_sweep.sh          # checkout root; project
#   DOGFOOD_PROJECT=path/to/tsconfig.json          #   defaults to
#                                                  #   $DOG/tsconfig.json
#   DOGFOOD_TSC_OUT=path/to/tsc-output.txt         # cached `tsc --pretty false
#                                                  #   --noEmit` output; scores
#                                                  #   matched/under/excess
#   RUNS=5 MAX_CHECKERS=16 DOGFOOD_SOFT=1          # same knobs as convergence
#
# The application is private, so neither it nor any of its paths are vendored
# or named here — everything arrives through the environment, and the script
# SKIPs (exit 0) when DOG is absent. CI without the checkout keeps building.
#
# Why this gate exists: the excalidraw convergence campaign (~230 commits)
# regressed this application from 57 diagnostics to 155 and broke its
# checker-count invariance without any gate noticing, because none of the
# standing gates ran the one input that exercised these paths. A sweep here
# is one command and about half a second per run.
#
# What a sweep has to satisfy — the same three properties as convergence.sh:
#   (a) run-to-run stability per checker count (byte-identical repeats),
#   (b) cross-N set equality of (file,line,col,code) keys,
#   (c) with a cached oracle: zero under-reports, and excess at or below the
#       ratchet — every fix lowers DOGFOOD_MAX_EXCESS, none raises it.
set -euo pipefail

cd "$(dirname "$0")/.."

CHECKOUT="${1:-${DOG:-}}"

skip() {
    echo "dogfood sweep SKIPPED — $1"
    exit 0
}

[ -n "$CHECKOUT" ] || skip "no checkout given (set DOG or pass a path)"
[ -d "$CHECKOUT" ] || skip "'$CHECKOUT' is not a directory"

CHECKOUT="$(cd "$CHECKOUT" && pwd -P)"
PROJECT="${DOGFOOD_PROJECT:-$CHECKOUT/tsconfig.json}"
[ -f "$PROJECT" ] || skip "$PROJECT missing (set DOGFOOD_PROJECT)"

RUNS="${RUNS:-2}"
MAX_CHECKERS="${MAX_CHECKERS:-8}"
SOFT="${DOGFOOD_SOFT:-0}"

# The ratchet. Lower it with every landed fix; the gate fails on any rise.
DOGFOOD_MAX_EXCESS="${DOGFOOD_MAX_EXCESS:-31}"
DOGFOOD_MAX_UNDER="${DOGFOOD_MAX_UNDER:-0}"

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN=zig-out/bench/ztsc

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NS=()
for n in $(seq 1 "$MAX_CHECKERS"); do NS+=("$n"); done

echo "dogfood sweep: $CHECKOUT"
echo "  project: ${PROJECT#"$CHECKOUT"/} · --checkers=${NS[0]}..${NS[${#NS[@]} - 1]} · $RUNS run(s) each"
echo

failures=0
note_fail() {
    echo "  $1"
    failures=$((failures + 1))
}

keys() {
    sed -E "s|$CHECKOUT/||g" "$1" \
        | sed -nE 's|^(.+):([0-9]+):([0-9]+): error (TS[0-9]+):.*$|\1:\2:\3:\4|p' \
        | sort -u
}

# ------------------------------------------------- (a) run-to-run stability

echo "-- (a) run-to-run stability, per checker count"
for n in "${NS[@]}"; do
    ref_md5=""
    line="  c$n:"
    ok=1
    for r in $(seq 1 "$RUNS"); do
        out="$TMP/c$n.r$r"
        status=0
        "$BIN" --pretty=false --checkers="$n" -p "$PROJECT" >"$out" 2>&1 || status=$?
        if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
            note_fail "c$n run $r: exit $status — expected 0 or 1"
            ok=0
        fi
        if ! grep -q '^ztsc: loaded ' "$out"; then
            note_fail "c$n run $r: truncated output — no 'ztsc: loaded' summary line"
            ok=0
        fi
        md5="$(md5 -q "$out" 2>/dev/null || md5sum "$out" | cut -d' ' -f1)"
        line="$line $(grep -c ': error TS' "$out" || true)/${md5:0:8}"
        if [ -z "$ref_md5" ]; then
            ref_md5="$md5"
        elif [ "$md5" != "$ref_md5" ]; then
            ok=0
        fi
    done
    keys "$TMP/c$n.r1" >"$TMP/keys.c$n"
    if [ "$ok" -eq 1 ]; then
        echo "$line   stable"
    else
        echo "$line   UNSTABLE"
        note_fail "c$n: repeats disagree"
    fi
done
echo

# ------------------------------------------------ (b) cross-N set equality

echo "-- (b) cross-N set equality of (file,line,col,code)"
cat "$TMP"/keys.c* | sort -u >"$TMP/union"
cat "$TMP"/keys.c* | sort | uniq -c | awk -v k="${#NS[@]}" '$1 == k { print $2 }' | sort -u >"$TMP/core"
comm -23 "$TMP/union" "$TMP/core" >"$TMP/volatile"

n_union=$(wc -l <"$TMP/union" | tr -d ' ')
n_core=$(wc -l <"$TMP/core" | tr -d ' ')
n_vol=$(wc -l <"$TMP/volatile" | tr -d ' ')

echo "  union $n_union · core $n_core · partition-dependent $n_vol"
if [ "$n_vol" -ne 0 ]; then
    note_fail "$n_vol key(s) are not reported at every checker count (src/checker.zig:15)"
    while IFS= read -r k; do
        at=""
        for n in "${NS[@]}"; do
            grep -qxF "$k" "$TMP/keys.c$n" && at="$at c$n"
        done
        echo "      $k  @${at}"
    done < <(head -10 "$TMP/volatile")
    [ "$n_vol" -gt 10 ] && echo "      … and $((n_vol - 10)) more"
fi
echo

# ------------------------------------------------------- (c) tsc scoreboard

echo "-- (c) tsc scoreboard"
ORACLE="${DOGFOOD_TSC_OUT:-}"
if [ -z "$ORACLE" ] || [ ! -s "$ORACLE" ]; then
    echo "  SKIPPED — no cached oracle (set DOGFOOD_TSC_OUT to a"
    echo "  \`tsc --pretty false --noEmit\` output file). (a) and (b) still gate."
    echo
else
    # tsc's `--pretty false` line shape is file(line,col): error TScode:.
    sed -E "s|$CHECKOUT/||g" "$ORACLE" \
        | sed -nE 's|^(.+)\(([0-9]+),([0-9]+)\): error (TS[0-9]+):.*$|\1:\2:\3:\4|p' \
        | sort -u >"$TMP/oracle.keys"
    n_oracle=$(wc -l <"$TMP/oracle.keys" | tr -d ' ')
    echo "  oracle: $n_oracle diagnostic(s)"
    u_exc=$(comm -23 "$TMP/union" "$TMP/oracle.keys" | wc -l | tr -d ' ')
    u_und=$(comm -13 "$TMP/core" "$TMP/oracle.keys" | wc -l | tr -d ' ')
    echo "  UNION excess = $u_exc   (ceiling $DOGFOOD_MAX_EXCESS)"
    echo "  UNION under-reports = $u_und   (ceiling $DOGFOOD_MAX_UNDER)"
    [ "$u_exc" -eq 0 ] && [ "$u_und" -eq 0 ] && echo "  CONVERGED."
    [ "$u_exc" -gt "$DOGFOOD_MAX_EXCESS" ] &&
        note_fail "excess regressed: $u_exc > $DOGFOOD_MAX_EXCESS (lower the ceiling when it drops)"
    [ "$u_und" -gt "$DOGFOOD_MAX_UNDER" ] &&
        note_fail "under-reports regressed: $u_und > $DOGFOOD_MAX_UNDER"
    echo
fi

# ------------------------------------------------------------------ verdict

if [ "$failures" -eq 0 ]; then
    echo "dogfood sweep PASSED"
    exit 0
fi

echo "dogfood sweep FAILED — $failures check(s)" >&2
if [ "$SOFT" != "0" ]; then
    echo "(DOGFOOD_SOFT=$SOFT — reporting only)" >&2
    exit 0
fi
exit 1
