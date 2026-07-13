#!/usr/bin/env bash
# Fetch a pinned set of real, popular TypeScript packages (their published
# `.d.ts`) into bench/corpus/real/ for the M13 census and the real-world
# benchmark corpus. Uses `npm pack` so downloads are deterministic at the
# pinned versions below. The corpus is gitignored (like all bench corpora) —
# regenerate with this script.
#
# Usage: bench/fetch_real.sh          # fetch + extract
#        bench/fetch_real.sh census   # ... then run the ztsc census over it
#
# The set is chosen to span the distribution the roadmap cares about: a
# type-level-heavy validator (zod, typebox), a backend framework (hono), the
# backend gate (@types/node), and ordinary app-ish libraries (date-fns,
# chalk). Their .d.ts are exactly the "features your dependencies choose for
# you" (ROADMAP M16).
set -euo pipefail

# Pinned (name@version).
PKGS=(
  "zod@3.23.8"
  "hono@4.6.3"
  "@types/node@22.7.4"
  "date-fns@3.6.0"
  "chalk@5.3.0"
  "@sinclair/typebox@0.33.12"
  "@types/express@4.17.21"
  "ajv@8.17.1"
)

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/corpus/real"
rm -rf "$root"
mkdir -p "$root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "fetching ${#PKGS[@]} packages into $root ..."
for spec in "${PKGS[@]}"; do
  # Sanitize name@version into a directory name.
  dest="$root/$(echo "$spec" | tr '/@' '__' | tr -d ' ')"
  mkdir -p "$dest"
  ( cd "$tmp" && npm pack --silent "$spec" >/dev/null 2>&1 ) || { echo "  ! failed: $spec"; continue; }
  tgz="$(ls -t "$tmp"/*.tgz | head -1)"
  tar -xzf "$tgz" -C "$dest" --strip-components=1
  rm -f "$tgz"
  n=$(find "$dest" -name '*.d.ts' | wc -l | tr -d ' ')
  echo "  $spec -> $n .d.ts"
done

total=$(find "$root" -name '*.d.ts' | wc -l | tr -d ' ')
lines=$(find "$root" -name '*.d.ts' -exec cat {} + | wc -l | tr -d ' ')
echo "real corpus: $total .d.ts files, ~$lines lines in $root"

if [[ "${1:-}" == "census" ]]; then
  bin="$here/../zig-out/bin/ztsc"
  [[ -x "$here/../zig-out/bench/ztsc" ]] && bin="$here/../zig-out/bench/ztsc"
  echo
  echo "running census (all .d.ts as inputs, this may take a moment) ..."
  # Pass every .d.ts as an input so the whole published surface is scanned,
  # independent of the import graph. --noLib: the census counts *syntax*, not
  # name resolution, and it keeps the run fast + quiet.
  find "$root" -name '*.d.ts' -print0 | xargs -0 "$bin" --noLib --census 2>&1 | sed -n '/--census/,$p'
fi
