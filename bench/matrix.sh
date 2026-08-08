#!/usr/bin/env bash
# The performance matrix: ztsc swept over --checkers=1,2,4,8 against tsgo at
# its default, on every target the project publishes numbers for -- the eight
# bench/corpus/real packages and the bench/apps application checkouts -- with
# the result written to bench/RESULTS.md (human, ready to lift into the docs)
# and bench/results.tsv (machine, one row per target x leg).
#
# WHY IT EXISTS. Every number in BENCHMARKS.md, README.md and docs/*.html used
# to be hand-transcribed from an ad-hoc terminal run. One of them (drizzle-orm)
# was 120x stale for 147 commits and nobody noticed. This script is the single
# source of truth: run it, then copy out of bench/RESULTS.md. Never retype a
# benchmark number out of scrollback.
#
# Usage: bench/matrix.sh [target-substring...]
#   With no argument the full matrix runs. Each argument filters targets by
#   substring, against either the directory key or the pretty label, like
#   bench/parity_sweep.sh:  bench/matrix.sh chalk ajv   # spot check
#
#   LIB_RUNS=N  timed runs per package leg (default 9; median reported)
#   APP_RUNS=N  timed runs per application leg (default 5; apps take seconds)
#   RUNS=N      set both at once
#   CHECKERS=".." ztsc --checkers values to sweep (default "1 2 4 8")
#   BIN=path    ztsc binary to measure (default: build ReleaseFast into a
#               private prefix, so a concurrently-running agent building into
#               zig-out cannot swap the binary out mid-measurement)
#   TSGO=path   native tsc binary (default: the pinned baseline install)
#   OUT_MD=path human-readable output   (default bench/RESULTS.md; - for none)
#   OUT_TSV=path machine-readable output (default bench/results.tsv; - for none)
#
# METHOD, and it is not negotiable -- this is a perf measurement on a shared
# machine:
#
#   * Strictly sequential. Exactly one measured process runs at a time. No
#     background jobs, no parallelism anywhere in this script.
#   * Legs are INTERLEAVED round-robin -- one run of ztsc c1, c2, c4, c8, then
#     tsgo, then around again -- rather than run as blocks, for the reason
#     bench/app_bench.sh gives: sequential blocks drift as the machine warms,
#     and the ratio is what the project's bars are stated in.
#   * One untimed warm-up per tool per target, to warm the FS cache.
#   * Median of RUNS. Higher for packages (milliseconds) than apps (seconds).
#   * Wall clock comes from bench/timeit.py, not /usr/bin/time: macOS's
#     `time -l` prints two decimals, which floors the package rows to 0.00s.
#     The wrapper adds a ~1.6 ms process-spawn floor to BOTH legs, so ratios
#     are unaffected; the measured floor is recorded in the results header.
#
# Bars, marked `!` in the tables when breached: wall <= 50% of tsgo, peak RSS
# <= 20% of tsgo -- the "at least 2x faster, at least 5x less memory" headline.
#
# `set -e` is deliberately OFF. Both measured tools exit nonzero whenever they
# report a diagnostic, and under `-e`/`pipefail` a `$(cmd | ...)` inherits that
# status and kills the run silently. bench/timeit.py reports the child's status
# rather than propagating it; setup steps below check their own failures.
set -uo pipefail

# --help prints the block above (before the cd, so $0 still resolves).
case "${1:-}" in
    -h | --help)
        sed -n '2,/^set -uo pipefail$/ { /^set -uo pipefail$/d; s/^#\{1,\} \{0,1\}//; p; }' "$0"
        exit 0
        ;;
esac

cd "$(dirname "$0")/.."

FILTERS=("$@")

LIB_RUNS="${LIB_RUNS:-${RUNS:-9}}"
APP_RUNS="${APP_RUNS:-${RUNS:-5}}"
CHECKERS="${CHECKERS:-1 2 4 8}"
read -r -a CHECKER_LIST <<<"$CHECKERS"
OUT_MD="${OUT_MD:-bench/RESULTS.md}"
OUT_TSV="${OUT_TSV:-bench/results.tsv}"

log() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 2; }

command -v python3 >/dev/null || die "python3 not found (bench/timeit.py needs it; see its header for why)"

now() { python3 -c 'import time; print("%.3f" % time.time())'; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
SCRIPT_START=$(now)

# ---------------------------------------------------------------- targets ---
# class | key | pretty label | project | parity status
#
# Packages: the eight of BENCHMARKS.md, in bench/parity_sweep.sh's order, each
# run as `-p <dir>` against its own tsconfig.json. All eight are diagnostic-
# parity gated at 0 under / 0 excess by bench/parity_sweep.sh.
#
# Applications: the bench/apps checkouts, which are gitignored (multi-GB, cloned
# and installed locally) -- absent ones are skipped, not fatal. Each needs the
# bench tsconfig staged for it; the stock configs use options TypeScript 7
# removed, so tsgo would exit without checking anything. Same mapping as
# bench/app_bench.sh. Ordered cheapest-first, gated before staged.
T_CLASS=(); T_KEY=(); T_LABEL=(); T_PROJ=(); T_PARITY=()
add_target() {
    T_CLASS+=("$1"); T_KEY+=("$2"); T_LABEL+=("$3"); T_PROJ+=("$4"); T_PARITY+=("$5")
}

add_target lib _types_node_22.7.4        "@types/node 22.7.4"        bench/corpus/real/_types_node_22.7.4        gated
add_target lib _types_react_18.3.11      "@types/react 18.3.11"      bench/corpus/real/_types_react_18.3.11      gated
add_target lib drizzle-orm_0.33.0        "drizzle-orm 0.33.0"        bench/corpus/real/drizzle-orm_0.33.0        gated
add_target lib hono_4.6.3                "hono 4.6.3"                bench/corpus/real/hono_4.6.3                gated
add_target lib _sinclair_typebox_0.33.12 "@sinclair/typebox 0.33.12" bench/corpus/real/_sinclair_typebox_0.33.12 gated
add_target lib ajv_8.17.1                "ajv 8.17.1"                bench/corpus/real/ajv_8.17.1                gated
add_target lib zod_3.23.8                "zod 3.23.8"                bench/corpus/real/zod_3.23.8                gated
add_target lib chalk_5.3.0               "chalk 5.3.0"               bench/corpus/real/chalk_5.3.0               gated

add_target app excalidraw excalidraw   bench/apps/excalidraw/tsconfig.tsgo.json     gated
add_target app immich     immich       bench/apps/immich/server/tsconfig.bench.json gated
add_target app outline    outline      bench/apps/outline/tsconfig.bench.json       staged
add_target app social-app "social-app" bench/apps/social-app/tsconfig.check.json    staged
add_target app vscode     vscode       bench/apps/vscode/src/tsconfig.bench.json    staged

# --------------------------------------------------------------- selection ---
S_CLASS=(); S_KEY=(); S_LABEL=(); S_PROJ=(); S_PARITY=()
n_filtered=0; n_missing=0; missing_note=""

for i in "${!T_KEY[@]}"; do
    key="${T_KEY[$i]}"; label="${T_LABEL[$i]}"; proj="${T_PROJ[$i]}"

    if [ ${#FILTERS[@]} -gt 0 ]; then
        keep=0
        for f in "${FILTERS[@]}"; do
            case "$key$label" in *"$f"*) keep=1 ;; esac
        done
        if [ $keep -eq 0 ]; then n_filtered=$((n_filtered + 1)); continue; fi
    fi

    # Packages are directories with their own tsconfig.json; apps name the
    # staged bench tsconfig directly.
    present=1
    if [ "${T_CLASS[$i]}" = lib ]; then
        [ -f "$proj/tsconfig.json" ] || present=0
    else
        [ -f "$proj" ] || present=0
    fi
    if [ $present -eq 0 ]; then
        if [ "${T_CLASS[$i]}" = lib ]; then
            log "skip: $label -- no $proj/tsconfig.json (bench/corpus is gitignored; run bench/fetch_real.sh)"
        else
            log "skip: $label -- no $proj (bench/apps is gitignored; check the app out locally)"
        fi
        n_missing=$((n_missing + 1))
        missing_note="$missing_note${missing_note:+, }$label"
        continue
    fi

    S_CLASS+=("${T_CLASS[$i]}"); S_KEY+=("$key"); S_LABEL+=("$label")
    S_PROJ+=("$proj"); S_PARITY+=("${T_PARITY[$i]}")
done

NTARGETS=${#S_KEY[@]}
[ "$NTARGETS" -gt 0 ] || die "no targets selected (filters: ${FILTERS[*]:-none}, $n_missing missing)"

# ------------------------------------------------------------------ binary ---
SUPPLIED_BIN=no
if [ -z "${BIN:-}" ]; then
    # A private prefix: a concurrently-running agent building into zig-out must
    # not be able to swap the binary out from under a measurement.
    PREFIX="${TMPDIR:-/tmp}/ztsc-matrix-$$"
    log "== building ztsc (ReleaseFast) -> $PREFIX =="
    zig build bench --prefix "$PREFIX/out" --cache-dir "$PREFIX/cache" >/dev/null || die "build failed"
    BIN="$PREFIX/out/bench/ztsc"
    trap 'rm -rf "$PREFIX"' EXIT
else
    SUPPLIED_BIN=yes
fi
[ -x "$BIN" ] || die "ztsc binary not executable: $BIN"

if [ -z "${TSGO:-}" ]; then
    PLAT=$(uname | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=x64; [ "$ARCH" = "aarch64" ] && ARCH=arm64
    TSGO="bench/baselines/tsgo/node_modules/@typescript/typescript-$PLAT-$ARCH/lib/tsc"
fi
[ -x "$TSGO" ] || die "tsgo baseline not executable: $TSGO (npm install in bench/baselines/tsgo, or set TSGO=path)"

# ------------------------------------------------------------------- hosts ---
median() { sort -n | awk '{v[NR]=$1} END {print (NR%2) ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2}'; }
minimum() { sort -n | head -1; }
maximum() { sort -n | tail -1; }

measure() { python3 bench/timeit.py "$@"; }   # -> "<wall_s> <peak_rss_bytes> <exit_code>"

ISO_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
DIRTY=clean
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=DIRTY
TSGO_VERSION=$("$TSGO" --version 2>/dev/null | tr -d '\r')
UNAME=$(uname -srm)
case "$(uname)" in
    Darwin)
        CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)
        CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo '?')
        ;;
    *)
        CPU=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
        [ -n "$CPU" ] || CPU=unknown
        CORES=$(nproc 2>/dev/null || echo '?')
        ;;
esac

# The wrapper's own floor, measured rather than asserted: both legs pay it.
TRUE_BIN=/usr/bin/true; [ -x "$TRUE_BIN" ] || TRUE_BIN=/bin/true
FLOOR=$(for _ in 1 2 3 4 5; do measure "$TRUE_BIN" | cut -d' ' -f1; done | median)
FLOOR_MS=$(awk -v f="$FLOOR" 'BEGIN { printf "%.2f", f * 1000 }')

log "ztsc:    $BIN ($([ "$SUPPLIED_BIN" = yes ] && echo "supplied via BIN=" || echo "built here"))"
log "commit:  $COMMIT ($DIRTY)"
log "tsgo:    $TSGO ($TSGO_VERSION)"
log "machine: $UNAME / $CPU / $CORES cores"
log "timer:   bench/timeit.py, spawn floor ${FLOOR_MS} ms (paid by both legs)"
log "sweep:   ztsc --checkers=$(echo "$CHECKERS" | tr ' ' ',') vs tsgo default; interleaved, median of $LIB_RUNS (packages) / $APP_RUNS (apps)"
log "targets: $NTARGETS selected, $n_missing skipped (missing)$([ ${#FILTERS[@]} -gt 0 ] && echo ", $n_filtered filtered out")"
for i in "${!S_KEY[@]}"; do
    log "         $((i + 1)). ${S_LABEL[$i]} [${S_CLASS[$i]}, ${S_PARITY[$i]}] -> ${S_PROJ[$i]}"
done
log ""

# ------------------------------------------------------------------ output ---
TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP" ${PREFIX:+"$PREFIX"}' EXIT
: >"$TMP/lib.wall"; : >"$TMP/lib.rss"; : >"$TMP/app.wall"; : >"$TMP/app.rss"; : >"$TMP/rows.tsv"

# One markdown row: label, then one cell per ztsc leg as "value (pct%)" with a
# `!` when the cell is over the bar, then tsgo's value, then the bar itself.
#   scale: divides the raw value into display units (1e-3 s = ms, 2^20 B = MB)
md_row() { # <label> <extra-col-or-empty> <scale> <prec> <bar_pct> <tsgo> <ztsc values...>
    local label="$1" extra="$2" scale="$3" prec="$4" barpct="$5" tsgo="$6"; shift 6
    awk -v label="$label" -v extra="$extra" -v scale="$scale" -v prec="$prec" \
        -v barpct="$barpct" -v tsgo="$tsgo" -v vals="$*" 'BEGIN {
        n = split(vals, v, " ")
        fmt = "%." prec "f"
        line = "| " label " |"
        if (extra != "") line = line " " extra " |"
        for (i = 1; i <= n; i++) {
            pct = (tsgo > 0) ? 100 * v[i] / tsgo : 0
            line = line sprintf(" " fmt " (%.0f%%)%s |", v[i] / scale, pct, (pct <= barpct ? "" : " !"))
        }
        line = line sprintf(" " fmt " |", tsgo / scale)
        line = line sprintf(" " fmt " |", tsgo * barpct / 100 / scale)
        print line
    }'
}

# ------------------------------------------------------------- measurement ---
for ti in "${!S_KEY[@]}"; do
    class="${S_CLASS[$ti]}"; label="${S_LABEL[$ti]}"; proj="${S_PROJ[$ti]}"
    key="${S_KEY[$ti]}"; parity="${S_PARITY[$ti]}"
    if [ "$class" = lib ]; then runs="$LIB_RUNS"; else runs="$APP_RUNS"; fi
    nlegs=$((${#CHECKER_LIST[@]} + 1))

    log "[$((ti + 1))/$NTARGETS] start: $label ($class, $proj) -- $nlegs legs x $runs runs, interleaved"
    t_start=$(now)

    # One untimed warm-up per tool, to warm the FS cache for both.
    measure "$BIN" -p "$proj" --checkers="${CHECKER_LIST[0]}" >/dev/null
    measure "$TSGO" -p "$proj" >/dev/null

    walls=(); rsses=(); codes=()
    for li in $(seq 0 $((nlegs - 1))); do walls[$li]=""; rsses[$li]=""; codes[$li]=""; done

    for _ in $(seq "$runs"); do
        for li in $(seq 0 $((nlegs - 1))); do
            if [ "$li" -lt "${#CHECKER_LIST[@]}" ]; then
                out=$(measure "$BIN" -p "$proj" --checkers="${CHECKER_LIST[$li]}")
            else
                out=$(measure "$TSGO" -p "$proj")
            fi
            if [ -z "$out" ]; then
                log "          warning: no measurement returned for leg $li of $label -- recording 0"
                out="0 0 -1"
            fi
            walls[$li]="${walls[$li]}${out%% *}"$'\n'
            rest="${out#* }"
            rsses[$li]="${rsses[$li]}${rest%% *}"$'\n'
            codes[$li]="${out##* }"
        done
    done

    # tsgo is the last leg, and every ratio on this row is against it.
    tsgo_li=$((nlegs - 1))
    tw=$(printf '%s' "${walls[$tsgo_li]}" | median)
    tr=$(printf '%s' "${rsses[$tsgo_li]}" | median)

    zwalls=""; zrsses=""
    for li in $(seq 0 $((nlegs - 1))); do
        w=$(printf '%s' "${walls[$li]}" | median)
        r=$(printf '%s' "${rsses[$li]}" | median)
        wmin=$(printf '%s' "${walls[$li]}" | minimum)
        wmax=$(printf '%s' "${walls[$li]}" | maximum)
        rmax=$(printf '%s' "${rsses[$li]}" | maximum)
        if [ "$li" -lt "${#CHECKER_LIST[@]}" ]; then
            tool=ztsc; ck="${CHECKER_LIST[$li]}"
            zwalls="$zwalls$w "; zrsses="$zrsses$r "
        else
            tool=tsgo; ck="-"
        fi
        awk -v c="$class" -v k="$key" -v l="$label" -v p="$proj" -v par="$parity" \
            -v tool="$tool" -v ck="$ck" -v runs="$runs" -v w="$w" -v wmin="$wmin" \
            -v wmax="$wmax" -v r="$r" -v rmax="$rmax" -v tw="$tw" -v tr="$tr" \
            -v rc="${codes[$li]}" 'BEGIN {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.6f\t%.6f\t%.6f\t%d\t%d\t%.1f\t%.1f\t%s\n",
                c, k, l, p, par, tool, ck, runs, w, wmin, wmax, r, rmax,
                (tw > 0 ? 100 * w / tw : 0), (tr > 0 ? 100 * r / tr : 0), rc
        }' >>"$TMP/rows.tsv"
    done

    # Packages are milliseconds, applications are seconds.
    if [ "$class" = lib ]; then wscale=0.001; wprec=1; extra=""; else wscale=1; wprec=3; extra="$parity"; fi
    md_row "$label" "$extra" "$wscale" "$wprec" 50 "$tw" $zwalls >>"$TMP/$class.wall"
    md_row "$label" "$extra" 1048576 1 20 "$tr" $zrsses >>"$TMP/$class.rss"

    t_end=$(now)
    log "[$((ti + 1))/$NTARGETS] done:  $label in $(elapsed "$t_start" "$t_end")s -- $((ti + 1))/$NTARGETS targets done"
    log "          wall ms  ztsc $(awk -v v="$zwalls" 'BEGIN{n=split(v,a," ");for(i=1;i<=n;i++)printf "%.1f ",a[i]*1000}')| tsgo $(awk -v v="$tw" 'BEGIN{printf "%.1f", v*1000}')"
    log "          rss  MB  ztsc $(awk -v v="$zrsses" 'BEGIN{n=split(v,a," ");for(i=1;i<=n;i++)printf "%.0f ",a[i]/1048576}')| tsgo $(awk -v v="$tr" 'BEGIN{printf "%.0f", v/1048576}')"
done

RUN_END=$(now)
TOTAL=$(elapsed "$SCRIPT_START" "$RUN_END")   # whole script, build included
TOTAL_HUMAN=$(awk -v t="$TOTAL" 'BEGIN { printf "%dm %04.1fs", int(t / 60), t - 60 * int(t / 60) }')

# ------------------------------------------------------------- results file ---
TSV_REF=""
[ "$OUT_TSV" = - ] || TSV_REF="$OUT_TSV"

CK_HEADER=""
for c in "${CHECKER_LIST[@]}"; do CK_HEADER="$CK_HEADER c$c |"; done
CK_ALIGN=""
for _ in "${CHECKER_LIST[@]}"; do CK_ALIGN="$CK_ALIGN---:|"; done

{
    echo "# ztsc vs tsgo -- measured matrix"
    echo
    echo "Generated by \`bench/matrix.sh\`. **This file is the source of truth for the"
    echo "numbers in BENCHMARKS.md, README.md and docs/\*.html** -- copy from here, do"
    echo "not retype from a terminal. Re-run the script rather than editing a cell."
    echo
    echo "| provenance | |"
    echo "|---|---|"
    echo "| measured | $ISO_DATE |"
    echo "| ztsc commit | \`$COMMIT\` (working tree: $DIRTY) |"
    echo "| ztsc binary | \`$BIN\` ($([ "$SUPPLIED_BIN" = yes ] && echo "supplied via BIN=" || echo "ReleaseFast, built by this run into a private prefix")) |"
    echo "| tsgo baseline | $TSGO_VERSION -- \`$TSGO\` |"
    echo "| host | $UNAME / $CPU / $CORES cores |"
    echo "| runs (median of) | $LIB_RUNS per package leg, $APP_RUNS per application leg, interleaved round-robin, one untimed warm-up per tool per target |"
    echo "| checker sweep | ztsc \`--checkers=$(echo "$CHECKERS" | tr ' ' ',')\`; tsgo has no checker knob and runs at its own default |"
    echo "| timer | \`bench/timeit.py\` (\`perf_counter\` + \`getrusage(RUSAGE_CHILDREN)\`); spawn floor ${FLOOR_MS} ms, paid by both legs |"
    echo "| targets | $NTARGETS measured, $n_missing skipped${missing_note:+ ($missing_note)}$([ ${#FILTERS[@]} -gt 0 ] && echo ", filtered by: ${FILTERS[*]}") |"
    echo "| total run time | $TOTAL_HUMAN (whole script, ReleaseFast build included) |"
    echo
    echo "Cells read \`value (% of tsgo)\`. A \`!\` marks a cell over one of the project"
    echo "bars -- wall <= 50% of tsgo, peak RSS <= 20% of tsgo, the \"at least 2x faster"
    echo "and at least 5x less peak memory\" headline. The last column is the bar itself,"
    echo "in the table's own units. The \`!\` test uses the unrounded ratio, so a cell can"
    echo "read \`20%\` and still be marked -- check the last column${TSV_REF:+, or \`$OUT_TSV\`},"
    echo "before quoting a borderline row."
    if [ ${#FILTERS[@]} -gt 0 ]; then
        echo
        echo "> **Partial run.** Filtered to \`${FILTERS[*]}\` -- this file does not carry the"
        echo "> full matrix and must not be used to update the docs wholesale."
    fi

    if [ -s "$TMP/lib.wall" ]; then
        echo
        echo "## Library packages"
        echo
        echo "The eight \`bench/corpus/real\` packages, each run as \`-p <dir>\` against its own"
        echo "\`tsconfig.json\`. All eight are diagnostic-parity gated at 0 under / 0 excess by"
        echo "\`bench/parity_sweep.sh\`, so every row is a like-for-like comparison."
        echo
        echo "### Wall clock -- ms, median of $LIB_RUNS"
        echo
        echo "| package |$CK_HEADER tsgo | bar (50%) |"
        echo "|---|$CK_ALIGN---:|---:|"
        cat "$TMP/lib.wall"
        echo
        echo "### Peak RSS -- MB, median of $LIB_RUNS"
        echo
        echo "| package |$CK_HEADER tsgo | bar (20%) |"
        echo "|---|$CK_ALIGN---:|---:|"
        cat "$TMP/lib.rss"
    fi

    if [ -s "$TMP/app.wall" ]; then
        echo
        echo "## Applications"
        echo
        echo "Whole application graphs from the gitignored \`bench/apps\` checkouts, each"
        echo "against the bench tsconfig staged for it (the stock configs use options"
        echo "TypeScript 7 removed, so tsgo would exit without checking anything)."
        echo
        echo "The **parity** column is what a row may be used for:"
        echo
        echo "* \`gated\` -- ztsc's diagnostics match tsgo's exactly, held by a standing gate"
        echo "  (excalidraw by \`bench/convergence.sh\`, immich by the app parity campaign)."
        echo "  These rows are citable."
        echo "* \`staged\` -- checked out and measurable, but **not** diagnostic-parity gated"
        echo "  yet. Per project policy these rows stay **uncited**: they must not appear in"
        echo "  BENCHMARKS.md, README.md or the website until they are gated. They are here"
        echo "  to track progress, nothing else."
        echo
        echo "### Wall clock -- seconds, median of $APP_RUNS"
        echo
        echo "| application | parity |$CK_HEADER tsgo | bar (50%) |"
        echo "|---|---|$CK_ALIGN---:|---:|"
        cat "$TMP/app.wall"
        echo
        echo "### Peak RSS -- MB, median of $APP_RUNS"
        echo
        echo "| application | parity |$CK_HEADER tsgo | bar (20%) |"
        echo "|---|---|$CK_ALIGN---:|---:|"
        cat "$TMP/app.rss"
    fi

    if [ -n "$TSV_REF" ]; then
        echo
        echo "Machine-readable sibling: \`$OUT_TSV\`, one row per target x leg."
    fi
} >"$TMP/RESULTS.md"

{
    printf '# ztsc vs tsgo performance matrix -- generated by bench/matrix.sh, do not hand-edit\n'
    printf '# measured_utc\t%s\n' "$ISO_DATE"
    printf '# ztsc_commit\t%s\n' "$COMMIT"
    printf '# ztsc_tree\t%s\n' "$DIRTY"
    printf '# ztsc_binary\t%s\n' "$BIN"
    printf '# tsgo_version\t%s\n' "$TSGO_VERSION"
    printf '# tsgo_binary\t%s\n' "$TSGO"
    printf '# host\t%s\n' "$UNAME / $CPU / $CORES cores"
    printf '# lib_runs\t%s\n' "$LIB_RUNS"
    printf '# app_runs\t%s\n' "$APP_RUNS"
    printf '# checkers\t%s\n' "$CHECKERS"
    printf '# timer_floor_ms\t%s\n' "$FLOOR_MS"
    printf '# targets_measured\t%s\n' "$NTARGETS"
    printf '# targets_skipped\t%s\n' "$n_missing${missing_note:+ ($missing_note)}"
    [ ${#FILTERS[@]} -gt 0 ] && printf '# filters\t%s\n' "${FILTERS[*]}"
    printf '# total_run_seconds\t%s\n' "$TOTAL"
    printf '# bars\t%s\n' "wall <= 50% of tsgo, peak_rss <= 20% of tsgo"
    printf 'class\tkey\tlabel\tproject\tparity\ttool\tcheckers\truns\twall_s_median\twall_s_min\twall_s_max\trss_bytes_median\trss_bytes_max\twall_pct_of_tsgo\trss_pct_of_tsgo\texit_code\n'
    cat "$TMP/rows.tsv"
} >"$TMP/results.tsv"

[ "$OUT_MD" = - ] || { cp "$TMP/RESULTS.md" "$OUT_MD" && log "wrote $OUT_MD"; }
[ "$OUT_TSV" = - ] || { cp "$TMP/results.tsv" "$OUT_TSV" && log "wrote $OUT_TSV"; }

log ""
log "TOTAL elapsed: $TOTAL_HUMAN ($NTARGETS targets, $n_missing skipped)"

cat "$TMP/RESULTS.md"
