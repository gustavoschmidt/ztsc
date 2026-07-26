#!/usr/bin/env bash
# Crash sweep: every benchmark package × --checkers=1..16 (an 8 × 16 = 128-run
# matrix). The standing pre-commit gate for resolver / symbol / checker
# changes — anything that can hand a stale pointer or a held slice to a
# parallel checker.
#
# Usage: bench/crash_sweep.sh [package-substring]
#   bench/crash_sweep.sh                  # the full 128-run matrix
#   bench/crash_sweep.sh drizzle          # one package, 16 runs (quick iteration)
#   MAX_CHECKERS=8 bench/crash_sweep.sh   # narrow the checker sweep
#
# Corpus: the packages vendored by bench/fetch_real.sh (BENCHMARKS.md §2),
# invoked exactly as the benchmark invokes them — `--pretty=false
# --checkers=N -p <pkg-dir>` against the ReleaseFast binary from
# `zig build bench`. Nonzero exit is *expected*: the packages are vendored
# without their dependencies, so every one of them reports diagnostics.
#
# What a run has to satisfy, per package, across all checker counts:
#   1. exit code is 0 or 1 (0 clean, 1 diagnostics; 2 = internal failure, and
#      anything ≥ 128 is a signal — 139 SIGSEGV, 134 SIGABRT),
#   2. the trailing `ztsc: loaded …` summary line is present — a crash
#      mid-check exits *after* printing a prefix of the diagnostics, so
#      "output looks plausible" has to mean "the process reached the end",
#   3. the exit code is identical across c1..c16, and
#   4. the diagnostics are byte-identical across c1..c16.
#
# (3) and (4) are why this doubles as a determinism gate: the same comparison
# that catches a checker dying under partitioning catches a checker reporting
# different things under partitioning. Exactly one thing is normalized away
# before comparing — the summary line's `(N worker(s), N checker(s))` tail,
# which *is* the configuration. Everything else, spans and diagnostic counts
# included, is compared byte for byte.
#
# (The span of a TS2589 ("excessively deep") used to be normalized out too:
# which instantiation trips the depth cap depends on what the checker
# instance already has cached, so the anchor moved with the partition. It is
# canonical now — one instantiation-limit diagnostic per file, at that file's
# lexically-first anchor, and never a foreign file's byte offset — so the
# comparison is strict.)
#
# Why this exists: at the default 4 checkers, on drizzle-orm alone, a held
# type-parameter slice was invalidated by interning and the checker died
# before reporting any of its 80 diagnostics. The tell was subtle (c4 peak RSS
# equal to c1 peak RSS) and a published benchmark row timed the dead process.
# Fixed in 38236dd; this script is that matrix, so no configuration ever goes
# un-swept again.
set -euo pipefail

cd "$(dirname "$0")/.."

# The eight measured packages, in BENCHMARKS.md §2 order. These are exactly
# the directories bench/fetch_real.sh writes a benchmark tsconfig.json into;
# the corpus is gitignored, so regenerate with that script.
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

CORPUS=bench/corpus/real
MAX_CHECKERS="${MAX_CHECKERS:-16}"

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

echo "crash sweep: ${#PKGS[@]} package(s) × --checkers=1..$MAX_CHECKERS"
echo

# normalize <stdout-file>: the compared form of a run's output — the summary
# line's worker/checker tail (the configuration itself) folded out, everything
# else kept, spans and diagnostic counts included.
normalize() {
    sed -E 's/\([0-9]+ worker\(s\), [0-9]+ checker\(s\)\)$/(W worker(s), C checker(s))/' "$1"
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

# Grid header.
printf '%-28s' 'package'
for n in $(seq 1 "$MAX_CHECKERS"); do printf '%4s' "c$n"; done
printf '   result\n'

total=0
clean=0
failed_pkgs=0

for pkg in "${PKGS[@]}"; do
    marks=()
    notes=()
    ref_status=""
    pkg_failed=0

    for n in $(seq 1 "$MAX_CHECKERS"); do
        out="$TMP/out"
        err="$TMP/err"
        status=0
        # The leg runs in a subshell whose own stderr is captured too: the
        # shell that reaps a signalled child prints "Segmentation fault: 11 …"
        # itself, which would otherwise land in the middle of the grid. The
        # trailing `exit $?` keeps the subshell a real process (bash would
        # otherwise exec the binary in place and *this* shell would report the
        # signal); `set -e` makes it exit 128+signal either way.
        (
            "$BIN" --pretty=false --checkers="$n" -p "$CORPUS/$pkg" >"$out" 2>"$err"
            exit $?
        ) 2>"$TMP/shellnote" || status=$?
        total=$((total + 1))

        # The compared blob: normalized stdout, then stderr verbatim (a panic
        # writes there, and these corpora are otherwise stderr-silent).
        {
            normalize "$out"
            echo "--- stderr ---"
            cat "$err"
        } >"$TMP/$pkg.c$n.norm"

        leg_ok=1
        if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
            notes+=("c$n: exit $status$(signal_note "$status") — expected 0 or 1")
            if [ -s "$TMP/shellnote" ]; then
                notes+=("    $(head -1 "$TMP/shellnote")")
            fi
            leg_ok=0
        fi
        if ! grep -q '^ztsc: loaded ' "$out"; then
            notes+=("c$n: truncated output — no 'ztsc: loaded' summary line (crash mid-check?)")
            leg_ok=0
        fi
        if [ -z "$ref_status" ]; then
            ref_status="$status"
            cp "$TMP/$pkg.c$n.norm" "$TMP/$pkg.ref"
        else
            if [ "$status" -ne "$ref_status" ]; then
                notes+=("c$n: exit $status != c1 exit $ref_status")
                leg_ok=0
            fi
            if ! cmp -s "$TMP/$pkg.c$n.norm" "$TMP/$pkg.ref"; then
                notes+=("c$n: diagnostics differ from c1:")
                while IFS= read -r line; do notes+=("    $line"); done \
                    < <(diff "$TMP/$pkg.ref" "$TMP/$pkg.c$n.norm" | head -6)
                leg_ok=0
            fi
        fi

        if [ "$leg_ok" -eq 1 ]; then
            marks+=('.')
            clean=$((clean + 1))
        else
            marks+=('X')
            pkg_failed=1
        fi
    done

    # Row: one mark per checker count, then the package's shared shape.
    ndiags=$(grep -c 'error TS' "$TMP/$pkg.ref" || true)
    printf '%-28s' "$pkg"
    for m in "${marks[@]}"; do printf '%4s' "$m"; done
    if [ "$pkg_failed" -eq 0 ]; then
        printf '   PASS (exit %s, %s diagnostics)\n' "$ref_status" "$ndiags"
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
echo "legend: . = clean (expected exit, complete output, identical to c1) · X = fail"
echo "$clean/$total clean"

if [ "$clean" -ne "$total" ]; then
    echo "CRASH SWEEP FAILED — $((total - clean)) run(s) across $failed_pkgs package(s)" >&2
    exit 1
fi
