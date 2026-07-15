#!/usr/bin/env bash
# Real-`@types/node` acceptance check (M18.4).
#
# Differential-checks a small real backend program (src/*.ts) against the real
# pinned `@types/node` (@22.7.4, vendored by `bench/fetch_real.sh`) and asserts
# ztsc's user-code diagnostics match the committed `expected` snapshot — which
# is itself byte-for-byte what the pinned native tsgo 7.0.2 oracle reports
# (--strict --noEmit --skipLibCheck). This supersedes the hand-authored
# `node_accept/backend` node-*shaped* fixture (which stays as the committed
# fast regression case in `zig build test`) as the standing real-world gate.
#
# The real `@types/node` is large and gitignored (like all bench corpora), so
# this is a *scripted* check, not a `zig build test` conformance case. Run:
#
#   bench/fetch_real.sh          # once, to vendor @types/node
#   test/node_accept_real/run.sh # the gate
#
# With the pinned tsgo baseline installed (bench/baselines/tsgo) it also
# re-runs tsgo live and diffs; otherwise it trusts the committed `expected`.
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

# Optional live differential vs the pinned native tsgo 7.0.2 oracle (the
# same baseline the conformance harness and bench/e2e.sh use).
plat="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64) arch=x64 ;;
  *) arch="$(uname -m)" ;;
esac
tsgo="$root/bench/baselines/tsgo/node_modules/@typescript/typescript-$plat-$arch/lib/tsc"
if [[ -x "$tsgo" ]]; then
  tsgo_ver="$("$tsgo" --version 2>/dev/null | awk '{print $2}')"
  if [[ "$tsgo_ver" != "7.0.2" ]]; then
    echo "FAIL: tsgo baseline reports '$tsgo_ver', want 7.0.2 (pinned oracle)." >&2
    exit 1
  fi
  tsgo_out="$(cd "$work" && "$tsgo" -p tsconfig.json --pretty false 2>&1 || true)"
  tsgo_got="$(echo "$tsgo_out" \
    | sed -n 's#^src/\([a-zA-Z0-9_.]*\)(\([0-9]*\),[0-9]*): error TS\([0-9]*\):.*#TS\3 \1 \2#p' \
    | sort)"
  if [[ "$tsgo_got" != "$want" ]]; then
    echo "FAIL: tsgo 7.0.2 disagrees with expected (snapshot drift?)." >&2
    echo "--- tsgo ---" >&2; echo "$tsgo_got" >&2
    exit 1
  fi
  echo "ok: tsgo 7.0.2 live differential agrees"
else
  echo "note: tsgo baseline not installed (cd bench/baselines/tsgo && npm install) — trusting committed tsgo-7.0.2 snapshot"
fi
