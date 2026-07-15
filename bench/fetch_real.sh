#!/usr/bin/env bash
# Fetch a pinned set of real, popular TypeScript packages (their published
# `.d.ts`) into bench/corpus/real/ for the census and the real-world
# benchmark corpus. Uses `npm pack` so downloads are deterministic at the
# pinned versions below. The corpus is gitignored (like all bench corpora) —
# regenerate with this script.
#
# Usage: bench/fetch_real.sh          # fetch + extract
#        bench/fetch_real.sh census   # ... then run the ztsc census over it
#
# The set is chosen to span package styles: type-level-heavy validators
# (zod, typebox, yup), a backend framework (hono), the backend gate
# (@types/node), an ORM (drizzle), a reactive-streams library (rxjs), the
# big ecosystem `@types` (react/lodash/jest), and ordinary app-ish
# libraries (date-fns, chalk). Their .d.ts are exactly the features your
# dependencies choose for you.
set -euo pipefail

# Pinned (name@version). Grown toward the ~500k-LOC target as more
# packages become checkable.
PKGS=(
  "zod@3.23.8"
  "hono@4.6.3"
  "@types/node@22.7.4"
  "date-fns@3.6.0"
  "chalk@5.3.0"
  "@sinclair/typebox@0.33.12"
  "@types/express@4.17.21"
  "ajv@8.17.1"
  "@types/react@18.3.11"
  "rxjs@7.8.1"
  "@types/lodash@4.17.7"
  "drizzle-orm@0.33.0"
  "@types/jest@29.5.13"
  "yup@1.4.0"
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

# Benchmark tsconfigs (see BENCHMARKS.md). Each of the seven measured packages
# gets a tsconfig so both tools run on identical inputs via -p. The
# corpus is gitignored, so these are (re)generated here rather than committed.
# `lib` is the minimal set that keeps tsgo clean: DOM only where the package
# references browser globals (a web framework / validator); @types/node uses its
# own `index.d.ts` entry (glob would pull the ts5.x alternate-version dirs and
# collide) and esnext-only (DOM's lib globals clash with @types/node's).
write_tsconfig() {  # <pkg-dir> <lib-json> <files-or-include-json>
  local d="$root/$1"
  [ -d "$d" ] || return 0
  cat > "$d/tsconfig.json" <<EOF
{
  "compilerOptions": {
    "noEmit": true,
    "strict": true,
    "target": "esnext",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "types": [],
    "lib": $2
  },
  $3
}
EOF
}
write_tsconfig "_types_node_22.7.4"         '["esnext"]'        '"files": ["index.d.ts"]'
write_tsconfig "zod_3.23.8"                 '["esnext","dom"]'  '"include": ["**/*.d.ts"]'
write_tsconfig "hono_4.6.3"                 '["esnext","dom"]'  '"include": ["**/*.d.ts"]'
write_tsconfig "drizzle-orm_0.33.0"         '["esnext"]'        '"include": ["**/*.d.ts"]'
write_tsconfig "_sinclair_typebox_0.33.12"  '["esnext"]'        '"include": ["**/*.d.ts"]'
write_tsconfig "ajv_8.17.1"                 '["esnext"]'        '"include": ["**/*.d.ts"]'
write_tsconfig "chalk_5.3.0"                '["esnext"]'        '"include": ["**/*.d.ts"]'
echo "wrote 7 benchmark tsconfigs (BENCHMARKS.md §2)"

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
