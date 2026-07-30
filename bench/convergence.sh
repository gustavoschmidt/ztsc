#!/usr/bin/env bash
# Convergence sweep: one large real application × --checkers=1..8, repeated,
# scored against tsgo. The third standing gate, next to bench/crash_sweep.sh
# (vary the configuration, hold the run) and bench/repeat_sweep.sh (hold the
# configuration, vary the run).
#
# Usage: bench/convergence.sh [excalidraw-checkout]
#   EXC=~/src/excalidraw bench/convergence.sh    # same thing via the environment
#   RUNS=5 bench/convergence.sh                  # deepen the repeat count
#   MAX_CHECKERS=16 bench/convergence.sh         # widen the checker sweep
#   CONVERGE_SOFT=1 bench/convergence.sh         # report only, always exit 0
#   TSGO=/path/to/tsc                            # override the oracle binary
#   TSGO_OUT=/path/to/oracle.txt                 # reuse a cached oracle run
#
# The corpus is NOT vendored. bench/crash_sweep.sh and bench/repeat_sweep.sh
# run on the eight packages bench/fetch_real.sh writes into bench/corpus/real;
# those are libraries, checked without their dependencies, and every one of
# them is small enough to fit in a single checker's working set. This gate
# wants the opposite: a whole application, with its node_modules, big enough
# that the file partition actually splits related files across checkers. That
# is a ~1 GB checkout, so it is passed in rather than committed, and the
# script SKIPs (exit 0) when it is absent — CI without the checkout keeps
# building.
#
# What a sweep has to satisfy:
#
#   (a) RUN-TO-RUN STABILITY, per checker count. Every repeat of one N is
#       byte-identical. This is repeat_sweep.sh's property (5)-minus-counters
#       applied to an application instead of a library, and it is here because
#       an application actually exercises the flaky corner: excalidraw at
#       --checkers=3 deviates about 1 run in 40 (a static getter's inferred
#       return type, `Fonts.registered`, flips a TS18048 on and off). No
#       library in bench/corpus/real reproduces that, which is exactly why the
#       existing gates never saw it. RUNS defaults to 3; raise it to hunt.
#
#   (b) CROSS-N SET EQUALITY of (file, line, column, code) keys. Every checker
#       count must report the SAME SET of diagnostics. This is the contract
#       written at src/checker.zig:15 and :164 — "the merged output is
#       byte-identical for any partition count" — measured as a set rather
#       than a byte diff, so the failure report can name the keys that move.
#       crash_sweep.sh already compares c1..c16 byte for byte on the library
#       corpus; this is the same property on an application, where foreign
#       types materialized on demand in each checker's local store once made
#       ~44 keys of ~260 move with the partition. That fringe is closed — the
#       set is identical at every N, and this check keeps it that way.
#
#   (c) THE tsgo SCOREBOARD, when the pinned oracle is available: how many of
#       tsgo's diagnostics ztsc reproduces at the same (file, line, column,
#       code) — `matched` — how many it misses — `under` — and how many it
#       reports that tsgo does not — `excess`. Scored per N and then over the
#       whole sweep: UNION excess (a false positive that appears at ANY
#       checker count) and UNION under-reports (a tsgo diagnostic missing from
#       EVERY checker count) are the two numbers convergence drove to zero.
#       Both ceilings (CONVERGE_MAX_EXCESS / CONVERGE_MAX_UNDER) now sit AT
#       zero: ztsc reproduces tsgo's 17 diagnostics exactly, at every checker
#       count, and any new false positive or under-report on this app fails
#       the sweep outright.
#
# The sweep PASSES as of the convergence campaign's close; CONVERGE_SOFT=1
# remains as a triage hatch for reading the report from a mid-investigation
# tree without the nonzero exit.
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- the corpus

CHECKOUT="${1:-${EXC:-}}"

skip() {
    echo "convergence sweep SKIPPED — $1"
    echo
    echo "  This gate needs an excalidraw checkout (yarn-installed, so that"
    echo "  node_modules and its tsconfig.tsgo.json are present):"
    echo
    echo "      git clone https://github.com/excalidraw/excalidraw ~/src/excalidraw"
    echo "      cd ~/src/excalidraw && yarn"
    echo "      EXC=~/src/excalidraw bench/convergence.sh"
    echo
    echo "  It is ~1 GB, so it is not vendored and this is not a failure."
    exit 0
}

[ -n "$CHECKOUT" ] || skip "no checkout given (pass a path or set EXC)"
[ -d "$CHECKOUT" ] || skip "'$CHECKOUT' is not a directory"

# The project file is tsconfig.tsgo.json, not tsconfig.json, and that is a
# deliberate metric decision rather than a convenience: ztsc's output for the
# two is byte-identical, but tsgo cannot read tsconfig.json at all (it removed
# `moduleResolution: node10` and `baseUrl`, so it stops at two config errors
# having checked nothing). Scoring against an oracle that refuses to run is
# not scoring, so the shared config is the one both compilers accept.
PROJECT="$CHECKOUT/tsconfig.tsgo.json"
[ -f "$PROJECT" ] || skip "$PROJECT missing (is this an excalidraw checkout?)"
[ -d "$CHECKOUT/node_modules" ] || skip "$CHECKOUT/node_modules missing — run \`yarn\` in the checkout"

# Absolute, symlink-resolved, so the prefix stripped from a diagnostic path
# below actually matches what ztsc prints.
CHECKOUT="$(cd "$CHECKOUT" && pwd -P)"
PROJECT="$CHECKOUT/tsconfig.tsgo.json"

RUNS="${RUNS:-3}"
MAX_CHECKERS="${MAX_CHECKERS:-8}"
SOFT="${CONVERGE_SOFT:-0}"

# The ratchet, fully ratcheted: converged means zero excess and zero
# under-reports, at any checker count, and the default ceilings hold it there.
CONVERGE_MAX_EXCESS="${CONVERGE_MAX_EXCESS:-0}"
CONVERGE_MAX_UNDER="${CONVERGE_MAX_UNDER:-0}"

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN=zig-out/bench/ztsc

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NS=()
for n in $(seq 1 "$MAX_CHECKERS"); do NS+=("$n"); done

echo "convergence sweep: $CHECKOUT"
echo "  project: tsconfig.tsgo.json · --checkers=${NS[0]}..${NS[${#NS[@]} - 1]} · $RUNS run(s) each"
echo

failures=0
note_fail() {
    echo "  $1"
    failures=$((failures + 1))
}

# keys <ztsc-stdout>: the compared form of a run — one sorted, deduplicated
# `file:line:col:TScode` per diagnostic, with the checkout prefix stripped so
# the keys are comparable to the oracle's (and to a sweep run from elsewhere).
# Message text is deliberately dropped: ztsc's wording diverges from tsgo's in
# ways that are tracked separately, and folding it in would make every row a
# mismatch.
keys() {
    sed -E "s|$CHECKOUT/||g" "$1" \
        | sed -nE 's|^(.+):([0-9]+):([0-9]+): error (TS[0-9]+):.*$|\1:\2:\3:\4|p' \
        | sort -u
}

# ------------------------------------------------- (a) run-to-run stability

echo "-- (a) run-to-run stability, per checker count"
for n in "${NS[@]}"; do
    ref=""
    ref_md5=""
    line="  c$n:"
    ok=1
    for r in $(seq 1 "$RUNS"); do
        out="$TMP/c$n.r$r"
        status=0
        ( "$BIN" --pretty=false --checkers="$n" -p "$PROJECT" >"$out" 2>&1; exit $? ) \
            2>"$TMP/shellnote" || status=$?
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
        if [ -z "$ref" ]; then
            ref="$out"
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
        note_fail "c$n: repeats disagree — diff of run 1 vs the first differing run:"
        for r in $(seq 2 "$RUNS"); do
            if ! cmp -s "$TMP/c$n.r1" "$TMP/c$n.r$r"; then
                diff "$TMP/c$n.r1" "$TMP/c$n.r$r" | head -6 | sed 's/^/      /'
                break
            fi
        done
    fi
done
echo

# ------------------------------------------------ (b) cross-N set equality

echo "-- (b) cross-N set equality of (file,line,col,code)"
cat "$TMP"/keys.c* | sort -u >"$TMP/union"
# A key is in the CORE when it occurs in every N's (already deduplicated) key
# file; the count of N is therefore the count of occurrences.
cat "$TMP"/keys.c* | sort | uniq -c | awk -v k="${#NS[@]}" '$1 == k { print $2 }' | sort -u >"$TMP/core"
comm -23 "$TMP/union" "$TMP/core" >"$TMP/volatile"

n_union=$(wc -l <"$TMP/union" | tr -d ' ')
n_core=$(wc -l <"$TMP/core" | tr -d ' ')
n_vol=$(wc -l <"$TMP/volatile" | tr -d ' ')

echo "  union $n_union · core $n_core · partition-dependent $n_vol"
if [ "$n_vol" -ne 0 ]; then
    note_fail "$n_vol key(s) are not reported at every checker count — the merged"
    note_fail "output is supposed to be partition-independent (src/checker.zig:15)."
    echo "    first 10, with the checker counts that report them:"
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

# ------------------------------------------------------ (c) tsgo scoreboard

echo "-- (c) tsgo scoreboard"

ORACLE="${TSGO_OUT:-}"
if [ -z "$ORACLE" ]; then
    TSGO="${TSGO:-bench/baselines/tsgo/node_modules/@typescript/typescript-$(uname | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/^x86_64$/x64/;s/^aarch64$/arm64/')/lib/tsc}"
    # Absolute, because the oracle runs from inside $CHECKOUT — a repo-relative
    # default silently resolved to nothing there and scored as "oracle: 0".
    case "$TSGO" in /*) ;; *) TSGO="$PWD/$TSGO" ;; esac
    if [ -x "$TSGO" ]; then
        ORACLE="$TMP/oracle.txt"
        echo "  running the oracle ($TSGO) …"
        ( cd "$CHECKOUT" && "$TSGO" --pretty false -p "$PROJECT" ) >"$ORACLE" 2>&1 || true
    fi
fi

if [ -z "$ORACLE" ] || [ ! -s "$ORACLE" ]; then
    echo "  SKIPPED — no oracle (install it with \`cd bench/baselines/tsgo && npm install\`,"
    echo "  or point TSGO / TSGO_OUT at one). (a) and (b) still gate."
    echo
else
    # tsgo's `--pretty false` line shape is file(line,col): error TScode:,
    # ztsc's is file:line:col: error TScode: — same key, two spellings.
    sed -E "s|$CHECKOUT/||g" "$ORACLE" \
        | sed -nE 's|^(.+)\(([0-9]+),([0-9]+)\): error (TS[0-9]+):.*$|\1:\2:\3:\4|p' \
        | sort -u >"$TMP/oracle.keys"
    n_oracle=$(wc -l <"$TMP/oracle.keys" | tr -d ' ')
    echo "  oracle: $n_oracle diagnostic(s)"
    echo "    N | total | matched | under | excess"
    for n in "${NS[@]}"; do
        tot=$(wc -l <"$TMP/keys.c$n" | tr -d ' ')
        mat=$(comm -12 "$TMP/keys.c$n" "$TMP/oracle.keys" | wc -l | tr -d ' ')
        und=$(comm -13 "$TMP/keys.c$n" "$TMP/oracle.keys" | wc -l | tr -d ' ')
        exc=$(comm -23 "$TMP/keys.c$n" "$TMP/oracle.keys" | wc -l | tr -d ' ')
        printf '  %3s | %5s | %7s | %5s | %6s\n' "$n" "$tot" "$mat" "$und" "$exc"
    done

    # The sweep-wide numbers. A false positive counts if it appears at ANY N
    # (union side); an under-report counts only if it is missing at EVERY N
    # (core side). Both are what "converged" has to mean for a checker whose
    # output must not depend on its partition.
    u_exc=$(comm -23 "$TMP/union" "$TMP/oracle.keys" | wc -l | tr -d ' ')
    u_und=$(comm -13 "$TMP/core" "$TMP/oracle.keys" | wc -l | tr -d ' ')
    echo
    echo "  UNION excess (false positive at any N) = $u_exc   (ceiling $CONVERGE_MAX_EXCESS)"
    echo "  UNION under-reports (missing at every N) = $u_und   (ceiling $CONVERGE_MAX_UNDER)"
    if [ "$u_exc" -eq 0 ] && [ "$u_und" -eq 0 ]; then
        echo "  CONVERGED."
    fi
    [ "$u_exc" -gt "$CONVERGE_MAX_EXCESS" ] &&
        note_fail "excess regressed: $u_exc > $CONVERGE_MAX_EXCESS (lower the ceiling when it drops)"
    [ "$u_und" -gt "$CONVERGE_MAX_UNDER" ] &&
        note_fail "under-reports regressed: $u_und > $CONVERGE_MAX_UNDER"
    echo
fi

# ------------------------------------------------------------------ verdict

if [ "$failures" -eq 0 ]; then
    echo "convergence sweep PASSED"
    exit 0
fi

echo "convergence sweep FAILED — $failures check(s)" >&2
if [ "$SOFT" != "0" ]; then
    echo "(CONVERGE_SOFT=$SOFT — reporting only)" >&2
    exit 0
fi
exit 1
