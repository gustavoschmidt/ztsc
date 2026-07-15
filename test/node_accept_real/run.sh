#!/usr/bin/env bash
# Real-`@types/node` acceptance check (M18.4).
#
# Differential-checks a small real backend program (src/*.ts) against the real
# pinned `@types/node` (@22.7.4, vendored by `bench/fetch_real.sh`) and asserts
# ztsc's user-code diagnostics match the committed `expected` snapshot — which
# is itself byte-for-byte what tsc 5.5.4 reports (--strict --noEmit
# --skipLibCheck). This supersedes the hand-authored `node_accept/backend`
# node-*shaped* fixture (which stays as the committed fast regression case in
# `zig build test`) as the standing real-world gate.
#
# The real `@types/node` is large and gitignored (like all bench corpora), so
# this is a *scripted* check, not a `zig build test` conformance case. Run:
#
#   bench/fetch_real.sh          # once, to vendor @types/node
#   test/node_accept_real/run.sh # the gate
#
# With TypeScript 5.5.4 reachable on NODE_PATH (the differential oracle) it also
# re-runs tsc live and diffs; otherwise it trusts the committed `expected`.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

# The real @types/node, vendored gitignored under bench/corpus/real.
types_node="$(ls -d "$root"/bench/corpus/real/_types_node_* 2>/dev/null | head -1 || true)"
if [[ -z "$types_node" || ! -f "$types_node/index.d.ts" ]]; then
  echo "!! real @types/node not vendored. Run: bench/fetch_real.sh" >&2
  exit 2
fi

bin="$root/zig-out/bin/ztsc"
[[ -x "$root/zig-out/bench/ztsc" ]] && bin="$root/zig-out/bench/ztsc"
if [[ ! -x "$bin" ]]; then
  echo "!! ztsc binary not built. Run: zig build" >&2
  exit 2
fi

# Assemble a throwaway project dir: program sources + node_modules/@types/node.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/node_modules/@types"
cp "$here"/src/*.ts "$work/src/"
cp "$here"/tsconfig.json "$work/tsconfig.json"
ln -s "$types_node" "$work/node_modules/@types/node"

# ztsc diagnostics, filtered to user code (src/), normalized to the snapshot
# format `TS<code> <file> <line>`. The vendored .d.ts trip ztsc-incompleteness
# diagnostics (out-of-subset lib constructs) that degrade to `any`; those live
# under node_modules/ and are excluded here exactly as tsc's `skipLibCheck`
# excludes them — a real backend build never surfaces them.
got="$(cd "$work" && { "$bin" src/index.ts 2>&1 || true; } \
  | sed -n 's#^src/\([a-zA-Z0-9_.]*\):\([0-9]*\):[0-9]*: error TS\([0-9]*\):.*#TS\3 \1 \2#p' \
  | sort)"

want="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$here/expected" | sort)"

if [[ "$got" != "$want" ]]; then
  echo "FAIL: ztsc user-code diagnostics differ from expected." >&2
  echo "--- expected ---" >&2; echo "$want" >&2
  echo "--- got ---" >&2; echo "$got" >&2
  exit 1
fi
echo "ok: ztsc matches expected ($(echo "$want" | grep -c . ) planted diagnostics) against real @types/node $(basename "$types_node")"

# Optional live differential vs tsc 5.5.4 (needs typescript on NODE_PATH).
tsc_js=""
if [[ -n "${NODE_PATH:-}" && -f "$NODE_PATH/typescript/bin/tsc" ]]; then
  tsc_js="$NODE_PATH/typescript/bin/tsc"
fi
if [[ -n "$tsc_js" ]] && command -v node >/dev/null 2>&1; then
  tsc_out="$(cd "$work" && node "$tsc_js" -p tsconfig.json 2>&1 || true)"
  tsc_got="$(echo "$tsc_out" \
    | sed -n 's#^src/\([a-zA-Z0-9_.]*\)(\([0-9]*\),[0-9]*): error TS\([0-9]*\):.*#TS\3 \1 \2#p' \
    | sort)"
  if [[ "$tsc_got" != "$want" ]]; then
    echo "FAIL: tsc 5.5.4 disagrees with expected (snapshot drift?)." >&2
    echo "--- tsc ---" >&2; echo "$tsc_got" >&2
    exit 1
  fi
  echo "ok: tsc 5.5.4 live differential agrees"
else
  echo "note: TypeScript not on NODE_PATH — trusting committed tsc-5.5.4 snapshot"
fi
