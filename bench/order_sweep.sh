#!/usr/bin/env bash
# Order sweep: one real application, one checker count, the ROOT FILE LIST
# permuted. The fourth standing gate, and the one axis none of the other
# three vary.
#
# Usage: bench/order_sweep.sh [checkout]
#   APP=~/src/excalidraw bench/order_sweep.sh        # same thing via the environment
#   CONFIG=tsconfig.check.json bench/order_sweep.sh bench/apps/social-app
#   CHECKERS="1 4" bench/order_sweep.sh              # sweep more partitions
#   ORDERS="source reverse shuffle=1" bench/order_sweep.sh
#   ORDER_SOFT=1 bench/order_sweep.sh                # report only, always exit 0
#
# Where the existing three gates sit:
#
#   bench/crash_sweep.sh    vary the CONFIGURATION, hold the run
#   bench/repeat_sweep.sh   hold the configuration, vary the RUN
#   bench/convergence.sh    vary the PARTITION (--checkers=1..8)
#   bench/order_sweep.sh    vary the ROOT ORDER   <- this one
#
# The property. A tsconfig's `include` walk emits its files in some order; a
# command line lists them in some order. Neither is semantic — tsc's answer
# for a program does not depend on the order its roots were named in, and
# ztsc's must not either. Everything downstream of that list is derived from
# it, though: file ids are handed out in list order, module discovery BFSes
# from it, the cost partition is built over it and breaks ties by id. So a
# result that moves when the list is permuted is a result that depends on
# which file happened to demand a type first — the same defect class the
# convergence gate catches from the partition side, reachable here at a FIXED
# checker count, which makes it far cheaper to shrink.
#
# This gate exists because the axis was found by hand, on two files, before
# there was anything to run it with: the same two source files passed to ztsc
# in the opposite order produced diagnostics that the forward order did not.
# `--file-order` (src/main.zig) is the knob; this script is the sweep over it.
#
# What is compared: the set of (file, line, column, code) keys, exactly as
# bench/convergence.sh compares them, so a key that moves reads the same way
# in both reports. Message text is deliberately excluded.
#
# One caveat worth stating, because it is a real exception rather than a
# tolerance: a program with DUPLICATE global declarations may legitimately
# report the redeclaration against whichever file merged second, and that is
# order-dependent in tsc too. No corpus this gate runs on has one. If that
# ever changes, the right fix is to exclude that key by name here, not to
# raise a ceiling.
#
# Why an application and not the package corpus: measured, all eight packages
# in bench/corpus/real are order-CLEAN — source/reverse/shuffle=1/shuffle=2 at
# --checkers=1 agree key for key on every one of them (_types_node 19,
# drizzle-orm 83, zod 8, ajv 5, _types_react 2, chalk 1, hono 0, typebox 0;
# volatile 0 throughout). Same reason bench/convergence.sh needs an app: a
# library's root list is short and homogeneous, so permuting it barely moves
# which file demands a type first. Do not go looking for a repro there.
#
# The corpus is NOT vendored (a ~1 GB checkout per app), so it is passed in
# and the script SKIPs (exit 0) when it is absent — CI without a checkout
# keeps building. See bench/convergence.sh for the same arrangement.
set -euo pipefail

cd "$(dirname "$0")/.."

CHECKOUT="${1:-${APP:-${EXC:-}}}"

skip() {
    echo "order sweep SKIPPED — $1"
    echo
    echo "  This gate needs an installed application checkout:"
    echo
    echo "      git clone https://github.com/excalidraw/excalidraw ~/src/excalidraw"
    echo "      cd ~/src/excalidraw && yarn"
    echo "      APP=~/src/excalidraw bench/order_sweep.sh"
    echo
    echo "  It is ~1 GB, so it is not vendored and this is not a failure."
    exit 0
}

[ -n "$CHECKOUT" ] || skip "no checkout given (pass a path or set APP)"
[ -d "$CHECKOUT" ] || skip "'$CHECKOUT' is not a directory"

# Same rule as the convergence gate: point both compilers at one config the
# oracle can actually read. Defaults to excalidraw's; name another with
# CONFIG= for an app staged under bench/apps (social-app ships
# tsconfig.check.json).
CONFIG="${CONFIG:-tsconfig.tsgo.json}"
[ -f "$CHECKOUT/$CONFIG" ] || skip "$CHECKOUT/$CONFIG missing (set CONFIG=<name>)"
[ -d "$CHECKOUT/node_modules" ] || skip "$CHECKOUT/node_modules missing — install the checkout"

CHECKOUT="$(cd "$CHECKOUT" && pwd -P)"
PROJECT="$CHECKOUT/$CONFIG"

# `source` first so it is the reference every other order is diffed against.
ORDERS="${ORDERS:-source reverse shuffle=1 shuffle=2 shuffle=3}"
# One checker by default: the point of this gate is to hold the partition
# fixed and move only the order. Add counts to cross the two axes.
CHECKERS="${CHECKERS:-1}"
SOFT="${ORDER_SOFT:-0}"

# Ratcheted at zero, like every other gate here. A key that moves with the
# root order is a bug, not a budget.
ORDER_MAX_VOLATILE="${ORDER_MAX_VOLATILE:-0}"

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN="$PWD/zig-out/bench/ztsc"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "order sweep: $CHECKOUT"
echo "  project: $CONFIG · checkers: $CHECKERS · orders: $ORDERS"
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

# A filename-safe tag for an order spelling (`shuffle=2` -> `shuffle_2`).
tag() { echo "${1//=/_}"; }

for n in $CHECKERS; do
    echo "-- --checkers=$n"
    tags=()
    for o in $ORDERS; do
        t="$(tag "$o")"
        tags+=("$t")
        out="$TMP/c$n.$t"
        status=0
        "$BIN" --pretty=false --checkers="$n" --file-order="$o" -p "$PROJECT" >"$out" 2>&1 || status=$?
        if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
            note_fail "c$n $o: exit $status — expected 0 or 1"
        fi
        if ! grep -q '^ztsc: loaded ' "$out"; then
            note_fail "c$n $o: truncated output — no 'ztsc: loaded' summary line"
        fi
        keys "$out" >"$TMP/keys.c$n.$t"
        printf '  %-12s %s diagnostic(s)\n' "$o" "$(grep -c ': error TS' "$out" || true)"
    done

    # Union vs core, exactly as the convergence gate scores the partition axis:
    # a key is in the CORE when every order reports it, and anything in the
    # union but not the core moved with the order.
    cat "$TMP"/keys.c"$n".* | sort -u >"$TMP/union.c$n"
    cat "$TMP"/keys.c"$n".* | sort | uniq -c \
        | awk -v k="${#tags[@]}" '$1 == k { print $2 }' | sort -u >"$TMP/core.c$n"
    comm -23 "$TMP/union.c$n" "$TMP/core.c$n" >"$TMP/volatile.c$n"

    n_union=$(wc -l <"$TMP/union.c$n" | tr -d ' ')
    n_core=$(wc -l <"$TMP/core.c$n" | tr -d ' ')
    n_vol=$(wc -l <"$TMP/volatile.c$n" | tr -d ' ')
    echo "  union $n_union · core $n_core · order-dependent $n_vol   (ceiling $ORDER_MAX_VOLATILE)"

    if [ "$n_vol" -gt "$ORDER_MAX_VOLATILE" ]; then
        note_fail "$n_vol key(s) depend on the order the roots were listed in."
        echo "    the orders that report each (first 15):"
        while IFS= read -r k; do
            at=""
            for t in "${tags[@]}"; do
                grep -qxF "$k" "$TMP/keys.c$n.$t" && at="$at $t"
            done
            echo "      $k  @${at}"
        done < <(head -15 "$TMP/volatile.c$n")
        [ "$n_vol" -gt 15 ] && echo "      … and $((n_vol - 15)) more"
        echo
        echo "    To shrink one: the reference run is \`--file-order=source\`, and"
        echo "    every listed order reproduces it at THIS checker count, so the"
        echo "    repro needs no partition — bisect the root list down by hand and"
        echo "    compare the two orders of the surviving pair."
    fi
    echo
done

if [ "$failures" -eq 0 ]; then
    echo "order sweep PASSED"
    exit 0
fi

echo "order sweep FAILED — $failures check(s)" >&2
if [ "$SOFT" != "0" ]; then
    echo "(ORDER_SOFT=$SOFT — reporting only)" >&2
    exit 0
fi
exit 1
