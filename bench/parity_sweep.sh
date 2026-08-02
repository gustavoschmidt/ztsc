#!/usr/bin/env bash
# Package parity sweep: ztsc vs the pinned tsgo 7.0.2 oracle on the eight
# BENCHMARKS.md packages, scored as (file, line, column, code) key sets.
#
# The fourth standing gate, next to bench/crash_sweep.sh (stability across
# configurations), bench/repeat_sweep.sh (stability across runs), and
# bench/convergence.sh (application parity): PER-PACKAGE DIAGNOSTIC PARITY,
# ratcheted so the gap can shrink but never silently grow.
#
# Usage: bench/parity_sweep.sh [package-substring]
#   REGEN_ORACLE=1  bench/parity_sweep.sh   # re-snapshot the oracle (needs tsgo 7.0.2 on PATH)
#   UPDATE_RATCHET=1 bench/parity_sweep.sh  # accept current counts as the new ceilings
#
# Oracle snapshots — bench/baselines/parity/<pkg>.keys — are what tsgo 7.0.2
# printed, reduced to file:line:col:TScode keys, and are checked in so CI and
# offline runs need no oracle binary. They are never hand-edited: the same
# policy as the conformance .expected snapshots, and REGEN_ORACLE refuses any
# other tsgo version. The ratchet — bench/baselines/parity/ratchet.tsv,
# "<pkg> <under> <excess>" per line — is the accepted ceiling pair per
# package: `under` counts oracle keys ztsc misses, `excess` counts keys ztsc
# invents (false positives, the thing project policy forbids). A run above
# either ceiling fails; a run below it passes and prints the UPDATE_RATCHET
# reminder. Parity is reached when every ratchet row reads "0 0".
set -euo pipefail
cd "$(dirname "$0")/.."

PKGS=(
    _types_node_22.7.4
    _types_react_18.3.11
    drizzle-orm_0.33.0
    hono_4.6.3
    _sinclair_typebox_0.33.12
    ajv_8.17.1
    zod_3.23.8
    chalk_5.3.0
)
FILTER="${1:-}"
BASE=bench/baselines/parity
RATCHET=$BASE/ratchet.tsv
mkdir -p "$BASE"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN=zig-out/bench/ztsc

ztsc_keys() { # <pkg-dir>  ->  file:line:col:TScode, package-relative, sorted
    { "$BIN" --pretty=false -p "$1" 2>/dev/null || true; } |
        sed -nE "s|^$1/(.+):([0-9]+):([0-9]+): error (TS[0-9]+):.*$|\1:\2:\3:\4|p" |
        sort -u
}

tsgo_keys() { # <pkg-dir>  ->  same key shape (tsgo prints file(line,col):)
    (cd "$1" && tsgo --noEmit --pretty false 2>/dev/null || true) |
        sed -nE 's|^(.+)\(([0-9]+),([0-9]+)\): error (TS[0-9]+):.*$|\1:\2:\3:\4|p' |
        sort -u
}

if [ "${REGEN_ORACLE:-0}" = "1" ]; then
    v=$(tsgo --version 2>/dev/null || echo none)
    if [ "$v" != "Version 7.0.2" ]; then
        echo "error: oracle snapshots are pinned to tsgo 7.0.2, found: $v" >&2
        exit 2
    fi
    for p in "${PKGS[@]}"; do
        [ -n "$FILTER" ] && [[ "$p" != *"$FILTER"* ]] && continue
        tsgo_keys "bench/corpus/real/$p" >"$BASE/$p.keys"
        echo "snapshot: $BASE/$p.keys ($(wc -l <"$BASE/$p.keys" | tr -d ' ') keys)"
    done
fi

fail=0
lowerable=0
printf "%-28s %7s %7s %7s %7s %7s   %s\n" package oracle ztsc matched under excess verdict
for p in "${PKGS[@]}"; do
    [ -n "$FILTER" ] && [[ "$p" != *"$FILTER"* ]] && continue
    snap=$BASE/$p.keys
    if [ ! -f "$snap" ]; then
        echo "error: missing oracle snapshot $snap (run REGEN_ORACLE=1 with tsgo 7.0.2)" >&2
        exit 2
    fi
    ztsc_keys "bench/corpus/real/$p" >"$TMP/z"
    nt=$(wc -l <"$snap" | tr -d ' ')
    nz=$(wc -l <"$TMP/z" | tr -d ' ')
    m=$(comm -12 "$snap" "$TMP/z" | wc -l | tr -d ' ')
    u=$(comm -23 "$snap" "$TMP/z" | wc -l | tr -d ' ')
    e=$(comm -13 "$snap" "$TMP/z" | wc -l | tr -d ' ')
    cu=0 ce=0
    if [ -f "$RATCHET" ]; then
        read -r cu ce < <(awk -v p="$p" '$1==p{print $2, $3; f=1} END{if(!f)print 0, 0}' "$RATCHET")
    fi
    verdict=ok
    if [ "$u" -gt "$cu" ] || [ "$e" -gt "$ce" ]; then
        verdict="FAIL (ceiling $cu/$ce)"
        fail=1
        comm -23 "$snap" "$TMP/z" | sed "s|^|  under:  $p/|" >&2
        comm -13 "$snap" "$TMP/z" | sed "s|^|  excess: $p/|" >&2
    elif [ "$u" -lt "$cu" ] || [ "$e" -lt "$ce" ]; then
        verdict="ok (below ceiling $cu/$ce — lower the ratchet)"
        lowerable=1
    fi
    printf "%-28s %7s %7s %7s %7s %7s   %s\n" "$p" "$nt" "$nz" "$m" "$u" "$e" "$verdict"
    echo -e "$p\t$u\t$e" >>"$TMP/ratchet.new"
done

if [ "${UPDATE_RATCHET:-0}" = "1" ] && [ -z "$FILTER" ]; then
    mv "$TMP/ratchet.new" "$RATCHET"
    echo "ratchet updated: $RATCHET"
elif [ "$lowerable" = "1" ]; then
    echo "note: at least one package is below its ratchet ceiling — run UPDATE_RATCHET=1 bench/parity_sweep.sh to lock in the improvement."
fi

exit $fail
