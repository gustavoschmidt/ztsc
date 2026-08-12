#!/usr/bin/env bash
# Fetch Microsoft's TypeScript compiler/conformance test corpus, pinned, into
# bench/ts-suite/TypeScript/ for bench/ts_suite.sh (the divergence-discovery
# sweep: ztsc vs tsgo over ~12k hand-written type-checking cases).
#
# Usage: bench/fetch_ts_suite.sh          # fetch (idempotent; re-run to repin)
#        bench/fetch_ts_suite.sh --force  # wipe and refetch
#
# ---------------------------------------------------------------- licensing
#
# The corpus is NOT vendored, exactly like bench/corpus (bench/fetch_real.sh)
# and bench/apps: it is fetched by this script into a gitignored directory and
# regenerated rather than committed. microsoft/TypeScript is Apache-2.0 (see
# NOTICE); ztsc is MIT. Redistributing ~12k Apache-2.0 test files inside an MIT
# repository would put a second license on the tree for no benefit — the sweep
# needs the files on disk, not in git history. Nothing under bench/ts-suite/ is
# ever committed, and no test case is copied into src/ or test/.
#
# ---------------------------------------------------------------------- pin
#
# TS_SUITE_COMMIT below is the microsoft/TypeScript commit that microsoft/
# typescript-go pins as its `_submodules/TypeScript` at tag `typescript/v7.0.2`
# — i.e. the exact test-suite revision the tsgo 7.0.2 baseline in
# bench/baselines/tsgo (and the embedded lib in src/lib, see NOTICE) was
# validated against. There is no `v7.x` tag in microsoft/TypeScript: TS 7 ships
# from typescript-go, whose submodule is the corpus of record. Verify with:
#
#   curl -s https://api.github.com/repos/microsoft/typescript-go/contents/_submodules/TypeScript?ref=<tsgo-tag> | grep '"sha"'
#
# Only tests/cases/compiler, tests/cases/conformance and tests/lib (the React
# typings 163 cases pull in through the harness's virtual `/.lib` mount) are
# checked out — a blob-filtered sparse clone, ~68 MB; tests/baselines is ~1 GB of expected
# emit and is deliberately not fetched — the oracle is the live tsgo binary,
# not the checked-in baselines.
set -euo pipefail

cd "$(dirname "$0")/.."

TS_SUITE_REPO="${TS_SUITE_REPO:-https://github.com/microsoft/TypeScript.git}"
TS_SUITE_COMMIT="${TS_SUITE_COMMIT:-4d4f005c8541e0255a9d8791205fdce326e462bc}"
TS_SUITE_TSGO_TAG="typescript/v7.0.2" # the typescript-go tag this pin came from
DEST="bench/ts-suite/TypeScript"

if [ "${1:-}" = "--force" ]; then
    rm -rf "$DEST"
fi

if [ -d "$DEST/.git" ]; then
    have="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
    if [ "$have" = "$TS_SUITE_COMMIT" ]; then
        n=$(find "$DEST/tests/cases" -type f -name '*.ts*' | wc -l | tr -d ' ')
        echo "corpus already at $TS_SUITE_COMMIT ($n case files) — nothing to do"
        exit 0
    fi
    echo "corpus is at ${have:-<none>}, repinning to $TS_SUITE_COMMIT ..."
fi

mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin "$TS_SUITE_REPO" 2>/dev/null || true
git -C "$DEST" sparse-checkout set --no-cone \
    '/tests/cases/compiler' '/tests/cases/conformance' '/tests/lib'

echo "fetching microsoft/TypeScript @ $TS_SUITE_COMMIT (tsgo $TS_SUITE_TSGO_TAG submodule pin) ..."
git -C "$DEST" fetch --depth 1 --filter=blob:none origin "$TS_SUITE_COMMIT"
git -C "$DEST" checkout -q FETCH_HEAD

n=$(find "$DEST/tests/cases" -type f -name '*.ts*' | wc -l | tr -d ' ')
sz=$(du -sh "$DEST" | cut -f1)
echo "corpus: $n case files ($sz) in $DEST"
echo "  compiler:    $(find "$DEST/tests/cases/compiler" -type f -name '*.ts*' | wc -l | tr -d ' ')"
echo "  conformance: $(find "$DEST/tests/cases/conformance" -type f -name '*.ts*' | wc -l | tr -d ' ')"
echo
echo "next: bench/ts_suite.sh   (builds ztsc ReleaseFast, runs the sweep vs tsgo)"
