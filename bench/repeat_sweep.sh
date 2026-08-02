#!/usr/bin/env bash
# Repeat-run sweep: every benchmark package × N runs of the *same* binary at
# the *same* configuration. The sibling of bench/crash_sweep.sh, and the other
# half of the determinism contract.
#
# Usage: bench/repeat_sweep.sh [package-substring]
#   bench/repeat_sweep.sh                 # 8 packages × 2 configs × 5 runs
#   bench/repeat_sweep.sh drizzle         # one package (quick iteration)
#   REPEATS=20 bench/repeat_sweep.sh      # deepen the repeat count
#
# crash_sweep.sh varies the configuration and holds the run fixed: it asks
# whether c1..c16 agree. That leaves a blind spot on the other axis — whether
# *one* configuration agrees with itself. It does not follow from the first:
# a single checker is still fed by a multi-threaded front end, so two runs of
# `--checkers=1` are two different interleavings of the same program.
#
# They observably are. Atom ids come from the interner's per-shard insertion
# order (`Interner.intern`), which parallel workers vary run to run — the
# atom *set* is identical every time, the id assignment never is. Atoms are
# then sort keys: for a scope's member table (`Binder.seal`), for a merged
# namespace's member index (`Merger.buildNsMembers`), and for an object type's
# property records (`types.Store.sortTriples`, the interning canonical form).
# So the order the checker reaches types in is not run-to-run stable, by
# design — the contract is that nothing observable may depend on it. That is
# exactly what this script pins.
#
# Why it exists: the checker's instantiation budget used to be measured with
# an exempt window (origin tagging did not charge `inst_count`). Substitution
# is memoized, so only a pair's *first* visit is counted, and which side of
# the window that first visit fell on moved with traversal order — drizzle-orm
# at --checkers=1 charged 56,988 / 57,018 / 57,093 of an invariant 57,359
# node-visits across repeat runs of one binary. Diagnostics never moved (that
# budget is dormant, capped far above any real program), but it gates TS2589,
# so a program near the cap could have reported it on one run and not the next.
# No gate could see it: this one can.
#
# Corpus and invocation are crash_sweep.sh's — the packages vendored by
# bench/fetch_real.sh (BENCHMARKS.md §2), run as `--pretty=false --checkers=N
# -p <pkg-dir>` against the ReleaseFast binary from `zig build bench`. Nonzero
# exit is expected: the packages are vendored without their dependencies.
#
# What a package has to satisfy, per configuration:
#   1. every run exits 0 or 1 (2 = internal failure, ≥ 128 is a signal),
#   2. every run prints its trailing `ztsc: loaded …` summary — a crash
#      mid-check exits after printing a prefix of the diagnostics,
#   3. all N runs share one exit code,
#   4. all N runs are byte-identical,
#   5. all N runs agree on the order-invariant work counters below, and
#   6. with the front end held SERIAL (`--workers=1`), all N runs agree on
#      those *plus* the three traversal-order counters (5) has to let go of.
#
# Normalization for (4) is crash_sweep.sh's, verbatim: only the summary line's
# `(N worker(s), N checker(s))` tail — the configuration itself — is folded
# out. Here that is a no-op by construction (the configuration is held fixed
# across the repeats), and it is kept only so the two scripts compare the same
# form of a run. Everything else, spans and diagnostic counts included, is
# compared byte for byte; the TS2589 anchor in particular is canonical now
# (one instantiation-limit diagnostic per file, at that file's lexically-first
# anchor) and so is compared strictly.
#
# (5) is a second, cheap pass with `--memory`, and it is the part with teeth
# for the bug above: that bug never moved a diagnostic, so (4) alone would
# have watched it happen. It compares a whitelist of `--memory` rows — the
# front end's work totals and every checker counter of work PERFORMED,
# `instantiations` included — chosen because each was measured invariant across
# repeat runs of all eight packages at both configurations, under the shipped
# parallel front end. A whitelist, not a blacklist, so a new telemetry row
# cannot silently join the compared set unaudited.
#
# Deliberately *not* whitelisted, because they are known to vary run to run:
# the per-worker arena high-waters and everything derived from them (`heap
# total`, `bytes/line (heap)`, `pack segments`, `interner (total)`), which
# follow from which files a worker happened to take; `check scratch
# high-water`, the peak of a reused scratch arena; and the three TRAVERSAL
# counters `relation cache entries`, `relation hit rate` and `inst cache
# hits`, which move on drizzle-orm at both configurations (`@types/node` used
# to as well). Those three are one item, not three, and the mechanism is
# understood:
#
#   The assignability memo marks a pair IN PROGRESS (`relate`'s `2`) while its
#   own walk is live, and a re-entry on a live pair is answered from that mark
#   without recursing — tsc's `Ternary.Maybe`, and the only thing that
#   terminates a recursive type. So the pairs a walk *reaches* are a function
#   of the order it reaches them in: settle a pair early and its subtree is
#   walked and memoized; meet it while it is live and the subtree is never
#   visited at all. `relation cache entries` counts exactly that reached set,
#   and `inst cache hits` counts the memoized substitutions those extra
#   subtrees re-request — which is why the two move in lockstep, and why
#   `inst cache misses` / `instantiations` (the substitutions actually
#   PERFORMED, one per distinct `(map, type)` pair) do not move at all.
#
#   The order itself is the atom order this header opens with: the checker
#   reaches declarations, and an object type's properties, through tables
#   sorted by name atom (`Binder.seal`, `Merger.buildNsMembers`,
#   `types.Store.sortTriples`), and atom ids come from the interner's
#   per-shard insertion order. Hold the front end serial and every one of the
#   three is invariant — which is what (6) below pins, and what proves the
#   parallel interner is the whole of it. drizzle-orm at `--checkers=1` charges
#   42,215 / 42,223 / 42,231 / 42,247 / 42,255 `inst cache hits` across repeats
#   of one binary, and 42,215 every time under `--workers=1`.
#
# Making them invariant under the parallel front end means a content-derived
# atom order — the same fix `print.propDisplayOrder` already applies at the
# output boundary, pushed down to the interner so traversal order gets it too.
# Measured at ~3 ms per run on drizzle-orm's 61k atoms (a 5% wall regression on
# a 59 ms check) before any of the store/binder churn, so it is not free and it
# stays an open item. Nothing observable rides on it: diagnostics are compared
# byte for byte by (4) and have never moved.
#
# (6) is what keeps the three from simply falling off the gate in the meantime.
# It is a third `--memory` pass at the same checker count with `--workers=1`,
# compared against a STRICT whitelist — (5)'s rows plus those three. The serial
# front end removes the atom-id variance and nothing else: the partition, the
# N-way checker scheduling and every per-checker memo are exercised exactly as
# (5) exercises them, so a checker-side regression in any of the three still
# fails here. What (6) deliberately cannot see is a counter that moves ONLY
# under a parallel front end — which is why it is an addition to (5) and never
# a substitute for it. Both passes must hold.
set -euo pipefail

cd "$(dirname "$0")/.."

# The eight measured packages, in BENCHMARKS.md §2 order — crash_sweep.sh's
# list. The corpus is gitignored; regenerate it with bench/fetch_real.sh.
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

# The configurations each repeated N times. `1` is the sharpest probe (one
# checker, so nothing is averaged away across instances) and `4` is the
# shipped default. Both keep the default parallel front end, which is where
# the run-to-run variance is produced.
CHECKERS=(1 4)

CORPUS=bench/corpus/real
REPEATS="${REPEATS:-5}"

if [ ! -d "$CORPUS" ]; then
    echo "error: $CORPUS missing — run bench/fetch_real.sh to vendor it" >&2
    exit 1
fi

# Optional package filter (substring, case-sensitive) for quick iteration.
if [ $# -gt 0 ]; then
    FILTER="$1"
    SELECTED=()
    for p in "${PKGS[@]}"; do
        case "$p" in *"$FILTER"*) SELECTED+=("$p") ;; esac
    done
    if [ ${#SELECTED[@]} -eq 0 ]; then
        echo "error: no benchmark package matches '$FILTER'; known packages:" >&2
        printf '  %s\n' "${PKGS[@]}" >&2
        exit 1
    fi
    PKGS=("${SELECTED[@]}")
fi

for p in "${PKGS[@]}"; do
    if [ ! -f "$CORPUS/$p/tsconfig.json" ]; then
        echo "error: $CORPUS/$p/tsconfig.json missing — run bench/fetch_real.sh" >&2
        exit 1
    fi
done

echo "== building ztsc (ReleaseFast) =="
zig build bench >/dev/null
BIN=zig-out/bench/ztsc

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "repeat sweep: ${#PKGS[@]} package(s) × ${#CHECKERS[@]} config(s) × $REPEATS run(s)"
echo "  (each run three times: plain for byte-identity, --memory for the counters,"
echo "   --memory --workers=1 for the traversal counters a parallel interner moves)"
echo

# normalize <stdout-file>: crash_sweep.sh's compared form — the summary line's
# worker/checker tail folded out, everything else kept.
normalize() {
    sed -E 's/\([0-9]+ worker\(s\), [0-9]+ checker\(s\)\)$/(W worker(s), C checker(s))/' "$1"
}

# The `--memory` rows compared across repeats of the shipped (parallel) front
# end: front-end work totals, then every checker work counter that measures
# work PERFORMED rather than work re-requested. Each was measured invariant
# across repeat runs; see the header for what is left out and why.
COUNTERS='^  (tokens|ast nodes|bind symbols|bind scopes|bind flow nodes|check types \(total\)|inst cache misses|inst canonical maps|instantiations|node_types hits|node_types misses|check flow queries) '

# The rows compared across repeats of the SERIAL front end (`--workers=1`):
# the above plus the three traversal counters, which are invariant once atom
# ids stop moving. Strictly a superset — (6) never compares less than (5).
STRICT_COUNTERS='^  (tokens|ast nodes|bind symbols|bind scopes|bind flow nodes|check types \(total\)|inst cache hits|inst cache misses|inst canonical maps|instantiations|node_types hits|node_types misses|check flow queries|relation cache entries|relation hit rate) '

# counters <stdout-file>: the whitelisted `--memory` rows, in print order.
counters() {
    grep -E "$COUNTERS" "$1" || true
}

# strict_counters <stdout-file>: the serial-front-end whitelist, in print order.
strict_counters() {
    grep -E "$STRICT_COUNTERS" "$1" || true
}

# signal_note <status>: " (SIGSEGV)"-style suffix for a signalled exit.
signal_note() {
    [ "$1" -lt 128 ] && return 0
    case "$(($1 - 128))" in
        4) echo " (SIGILL)" ;;
        6) echo " (SIGABRT)" ;;
        8) echo " (SIGFPE)" ;;
        10) echo " (SIGBUS)" ;;
        11) echo " (SIGSEGV)" ;;
        *) echo " (signal $(($1 - 128)))" ;;
    esac
}

# Grid header: one column per configuration, each holding that config's mark.
printf '%-28s' 'package'
for n in "${CHECKERS[@]}"; do printf '%6s' "c$n"; done
printf '   result\n'

total=0
clean=0
failed_pkgs=0

for pkg in "${PKGS[@]}"; do
    marks=()
    notes=()
    pkg_failed=0
    ndiags=0

    for n in "${CHECKERS[@]}"; do
        ref_status=""
        cfg_ok=1

        for r in $(seq 1 "$REPEATS"); do
            out="$TMP/out"
            err="$TMP/err"
            status=0
            # crash_sweep.sh's subshell: its own stderr is captured so the
            # shell's "Segmentation fault: 11 …" note for a signalled child
            # does not land in the middle of the grid, and the trailing
            # `exit $?` keeps the subshell a real process.
            (
                "$BIN" --pretty=false --checkers="$n" -p "$CORPUS/$pkg" >"$out" 2>"$err"
                exit $?
            ) 2>"$TMP/shellnote" || status=$?
            total=$((total + 1))

            {
                normalize "$out"
                echo "--- stderr ---"
                cat "$err"
            } >"$TMP/$pkg.c$n.r$r"

            # Second pass, same configuration plus `--memory`, for the work
            # counters. A separate run rather than a normalized single one:
            # the `--memory` table carries genuinely scheduling-dependent
            # telemetry, so folding it out of the byte-identity comparison
            # would weaken (4) to protect (5).
            "$BIN" --pretty=false --memory --checkers="$n" -p "$CORPUS/$pkg" \
                >"$TMP/mem" 2>/dev/null || true
            counters "$TMP/mem" >"$TMP/$pkg.c$n.r$r.counters"

            # Third pass, same checker count but a SERIAL front end, for the
            # three traversal counters. Atom ids are what the parallel
            # interner varies, and they are the sort key every declaration and
            # property table is reached through — so `--workers=1` removes the
            # whole of the run-to-run order variance while leaving the checker
            # side (partition, N-way scheduling, per-checker memos) exactly as
            # the pass above exercises it. See the header for why the two
            # passes cannot be merged: this one must not be allowed to excuse
            # a shipped-configuration counter.
            "$BIN" --pretty=false --memory --workers=1 --checkers="$n" -p "$CORPUS/$pkg" \
                >"$TMP/mem1" 2>/dev/null || true
            strict_counters "$TMP/mem1" >"$TMP/$pkg.c$n.r$r.strict"

            run_ok=1
            if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
                notes+=("c$n run $r: exit $status$(signal_note "$status") — expected 0 or 1")
                if [ -s "$TMP/shellnote" ]; then
                    notes+=("    $(head -1 "$TMP/shellnote")")
                fi
                run_ok=0
            fi
            if ! grep -q '^ztsc: loaded ' "$out"; then
                notes+=("c$n run $r: truncated output — no 'ztsc: loaded' summary line (crash mid-check?)")
                run_ok=0
            fi
            if [ -z "$ref_status" ]; then
                ref_status="$status"
                cp "$TMP/$pkg.c$n.r$r" "$TMP/$pkg.c$n.ref"
                cp "$TMP/$pkg.c$n.r$r.counters" "$TMP/$pkg.c$n.ref.counters"
                cp "$TMP/$pkg.c$n.r$r.strict" "$TMP/$pkg.c$n.ref.strict"
                ndiags=$(grep -c 'error TS' "$TMP/$pkg.c$n.ref" || true)
                if [ ! -s "$TMP/$pkg.c$n.ref.counters" ] || [ ! -s "$TMP/$pkg.c$n.ref.strict" ]; then
                    notes+=("c$n run $r: no whitelisted --memory counter rows — did a row get renamed?")
                    run_ok=0
                fi
            else
                if [ "$status" -ne "$ref_status" ]; then
                    notes+=("c$n run $r: exit $status != run 1 exit $ref_status")
                    run_ok=0
                fi
                if ! cmp -s "$TMP/$pkg.c$n.r$r" "$TMP/$pkg.c$n.ref"; then
                    notes+=("c$n run $r: diagnostics differ from run 1 of the same config:")
                    while IFS= read -r line; do notes+=("    $line"); done \
                        < <(diff "$TMP/$pkg.c$n.ref" "$TMP/$pkg.c$n.r$r" | head -6)
                    run_ok=0
                fi
                if ! cmp -s "$TMP/$pkg.c$n.r$r.counters" "$TMP/$pkg.c$n.ref.counters"; then
                    notes+=("c$n run $r: work counters differ from run 1 of the same config:")
                    while IFS= read -r line; do notes+=("    $line"); done \
                        < <(diff "$TMP/$pkg.c$n.ref.counters" "$TMP/$pkg.c$n.r$r.counters" | head -8)
                    run_ok=0
                fi
                if ! cmp -s "$TMP/$pkg.c$n.r$r.strict" "$TMP/$pkg.c$n.ref.strict"; then
                    notes+=("c$n run $r: --workers=1 work counters differ from run 1 of the same config:")
                    while IFS= read -r line; do notes+=("    $line"); done \
                        < <(diff "$TMP/$pkg.c$n.ref.strict" "$TMP/$pkg.c$n.r$r.strict" | head -8)
                    run_ok=0
                fi
            fi

            if [ "$run_ok" -eq 1 ]; then
                clean=$((clean + 1))
            else
                cfg_ok=0
            fi
        done

        if [ "$cfg_ok" -eq 1 ]; then
            marks+=("$REPEATS/$REPEATS")
        else
            marks+=('X')
            pkg_failed=1
        fi
    done

    printf '%-28s' "$pkg"
    for m in "${marks[@]}"; do printf '%6s' "$m"; done
    if [ "$pkg_failed" -eq 0 ]; then
        printf '   PASS (%s diagnostics)\n' "$ndiags"
    else
        printf '   FAIL\n'
        failed_pkgs=$((failed_pkgs + 1))
    fi
    # (guarded: expanding an empty array trips `set -u` on bash 3.2, which is
    # what /bin/bash still is on macOS)
    if [ ${#notes[@]} -gt 0 ]; then
        printf '    %s\n' "${notes[@]}"
    fi
done

echo
echo "legend: N/N = every repeat of that config identical to the first · X = fail"
echo "$clean/$total clean"

if [ "$clean" -ne "$total" ]; then
    echo "REPEAT SWEEP FAILED — $((total - clean)) run(s) across $failed_pkgs package(s)" >&2
    exit 1
fi
