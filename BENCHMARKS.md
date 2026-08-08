# ZTSC — Benchmarks

Wall clock and peak memory for **ztsc vs tsgo** (the native TypeScript 7
compiler), checking real, published packages and a real application on identical
inputs. Package matrix and excalidraw application row both measured 2026-08-02
on an Apple M4 with ztsc at commit 732ab8b, ztsc and tsgo runs interleaved.

The headline, held on every benchmark on this page: **ztsc is at least 2×
faster and uses at least 5× less peak memory than tsgo** — wall clock ≤ 50%
and peak RSS ≤ 20% of tsgo's, packages and whole application alike. The
measured floors are 2.5× (wall) and 5.3× (RSS), both on excalidraw; the widest
margins are 12.4× and 15.3×, both on drizzle-orm.

ztsc checks a subset of TypeScript, against the lib each package's tsconfig
selects — es-core..esnext for most, plus the real DOM lib for the three packages
that list `dom` (hono, zod, and `@types/react`), matching tsgo's target-esnext
default. Every row is also a diagnostic-parity claim: on all eight packages
ztsc reports **exactly the same diagnostics as tsgo** — the same (file, line,
column, code) set, zero excess and zero under-reports — held by a standing
ratcheted gate (`bench/parity_sweep.sh`, scored against checked-in tsgo 7.0.2
oracle snapshots), alongside a 991-case differential conformance suite and the
excalidraw application row below. hono and zod check against the
2.35 MB DOM lib, so their memory and wall clock sit higher than their line counts
alone suggest — that added front end is why their rows land where they do.
Packages are vendored without their dependencies; both tools fully parse, bind,
and check every file regardless of exit code.

Both tools check their default standard library at their defaults — tsgo checks
its default lib, and ztsc type-checks its embedded pre-verified lib too (tsc's
`skipDefaultLibCheck` is *off* by default, matching tsc/tsgo). So the numbers
below are a like-for-like defaults-vs-defaults comparison. `--skip-default-lib-check`
(or the tsconfig `skipLibCheck`/`skipDefaultLibCheck` keys) turns ztsc's lib
check off, with byte-identical diagnostics either way — lib diagnostics are
never surfaced — for a few milliseconds and a few MB saved.

## Results

Both tools run at their defaults — tsgo at 4 checker instances, ztsc at
`min(4, cores)` dropping to 2 when there is less than 32k nodes of check work
to spread (which covers the two smallest packages). Peak memory at those
defaults, across all eight packages:

```
peak RSS at the defaults — MB, lower is better

@types/node        ztsc ███ 17
                   tsgo ████████████████████ 101
@types/react       ztsc ████ 23
                   tsgo ████████████████████████████████████ 183
drizzle-orm        ztsc ████ 18
                   tsgo ██████████████████████████████████████████████████████ 276
hono               ztsc █████ 24
                   tsgo ██████████████████████████████ 153
@sinclair/typebox  ztsc ███ 14
                   tsgo ███████████████ 78
ajv                ztsc ██ 9
                   tsgo ██████████ 50
zod                ztsc ████ 21
                   tsgo ███████████████████████████ 136
chalk              ztsc █ 8
                   tsgo █████████ 44
```

ztsc's peak memory is **7–19% of tsgo's** and its wall clock **8–38%** —
smaller *and* faster on every package, and past both bars of the 2×/5×
guarantee on every one:

| package (files / lines) | wall ztsc / tsgo | wall vs tsgo | peak RSS ztsc / tsgo | rss vs tsgo |
|---|---:|---:|---:|---:|
| @types/node 22.7.4 (59 / 49.6k) | 11.3 / 46.7 ms | 24% | 17.4 / 101.2 MB | 17% |
| @types/react 18.3.11 (6 / 64.1k) | 22.1 / 245.8 ms | 9% | 22.9 / 183.2 MB | 13% |
| drizzle-orm 0.33.0 (288 / 12.6k) | 19.5 / 241.4 ms | 8% | 18.1 / 276.5 MB | 7% |
| hono 4.6.3 (165 / 6.3k) | 23.8 / 172.4 ms | 14% | 24.1 / 153.4 MB | 16% |
| @sinclair/typebox 0.33.12 (241 / 3.1k) | 15.2 / 48.9 ms | 31% | 13.8 / 78.1 MB | 18% |
| ajv 8.17.1 (107 / 1.8k) | 9.2 / 24.5 ms | 38% | 9.3 / 49.8 MB | 19% |
| zod 3.23.8 (24 / 1.6k) | 21.6 / 156.3 ms | 14% | 21.3 / 136.1 MB | 16% |
| chalk 5.3.0 (5 / 612) | 6.3 / 19.2 ms | 33% | 7.5 / 43.8 MB | 17% |

That is **5.4–15.3× less peak memory** and **2.7–12.4× faster**, on all eight
packages. The two *smallest* packages (ajv 38%, chalk 33%) sit near both tools'
process floors — ztsc's ~6–9 ms is startup plus its embedded lib front end,
which it type-checks by default just like tsgo, and tsgo's floor is ~19 ms — so
their ratios reflect fixed startup cost, not checking throughput.
`@sinclair/typebox` (31%) is the corpus's highest wall ratio after them: its
wall had roughly doubled (16.5 → 30.5 ms) when the checker gained the
ambient-context grammar checks and the diagnostic-parity work that removed its
two remaining false positives, and memoizing the tuple element-type walks since
gave that back (30.5 → 15.2 ms) with the diagnostics unchanged. hono and zod
land higher than their size alone suggests (14% wall each) because their
tsconfig lists `dom`: ztsc parses, binds, and checks the 2.35 MB DOM lib for
them too, a sizable front end on top. `@types/node`, the densest declaration
corpus, sits at 24% wall — its declaration merging and interface heritage is
the work ztsc closes least of the gap on. `@types/react` is the corpus's
heaviest row for tsgo — its deep conditional types and the DOM-derived
`DetailedHTMLProps` intrinsic-element unions cost tsgo 246 ms, more wall time
than any other package, and 183 MB — yet ztsc checks the same surface in 22 ms
and 23 MB (9% wall, 13% RSS), an 11× speedup at an eighth of the memory.
drizzle-orm is the widest gap in the corpus: 19.5 ms against 241.4 ms, 18.1 MB
against 276.5 MB.

Its row also supersedes an invalid one. The previously published drizzle-orm
figures (15.0 ms / 14.6 MB) timed a process that crashed partway through the
check phase: at the default 4 checkers, on that package alone, a held type-parameter
slice was invalidated by interning and the checker died before reporting any of
its 76 diagnostics. The bug is fixed (commit 374d2c2) and the numbers above are
the first honest measurement of that package at the default — understated before,
because a crashed run stops paying for work it never did.

### Beyond the packages: a whole application

One application is measured — a whole app graph rather than a single package's
`.d.ts`. Both tools at their defaults:

| application | wall ztsc / tsgo | peak RSS ztsc / tsgo | rss vs tsgo | diagnostics |
|---|---:|---:|---:|---|
| **excalidraw** 0.18.1 (`a2ec2889`) — public | 0.195 / 0.493 s | 121.6 / 640.7 MB | 19% | the same 17 as tsgo, at every checker count |

**excalidraw** is public and reproducible, measured 2026-08-02 with ztsc
at commit 732ab8b. It loads 1,091 files / 330,555 lines (513 of them the project's own source; the rest are
the dependency `.d.ts` closure and the standard library) and checks them
**2.5× faster at 19% of tsgo's peak memory** — the tightest margin on either
axis anywhere in this document, and still clear of the 2×/5× guarantee. Two
earlier steps account for most of the wall: include expansion now stays out of
package folders the way tsc's does, which both removed a ~330 ms hidden
directory walk over the checkout's `node_modules` (now visible as the `config`
phase in `--timing`, ~5 ms) and stopped rooting 24 nested `node_modules`
sources that tsgo also refuses to root (1,110 → 1,091 files loaded — the
tsgo-verified fidelity fix behind the smaller file count); the current perf
series (lib front-ended once instead of twice, memoized tuple element-type
walks, a scanner identifier fast path) took it the rest of the way.

Unlike the package matrix, this row *is* a diagnostic claim. ztsc reports
exactly the same 17 diagnostics as tsgo — the same (file, line, column, code)
for every one, zero excess and zero under-reports — and the same set at every
checker count from 1 to 8. It is *not* byte-identical output: the message text
differs in places (tsgo prints `Uint8Array<ArrayBufferLike>` where ztsc expands
the union, and `BlobPart` where ztsc names its constituents). The property is
held by `bench/convergence.sh`, a standing gate whose false-positive and
under-report ceilings both sit at zero.

For context on what the 17 are: excalidraw's own pinned `tsc` 4.9.4 reports
**zero errors** on this tree. All 17 come from TypeScript 7's newer lib
definitions — nine from the `Uint8Array`/`ArrayBuffer` generic parameters added
since 4.9, six implicit-`any` reports in one file behind a dependency whose types
no longer resolve under its package `exports` map, and two ordinary findings.
They are real findings under tsgo's libs, and ztsc agrees with tsgo on all of
them.

**The config caveat.** TypeScript 7 removed `moduleResolution: "node10"` and
`baseUrl`, so tsgo cannot read excalidraw's real `tsconfig.json` at all — it
stops at two config errors (TS5108, TS5102) having checked nothing. The row
therefore uses `tsconfig.tsgo.json`, a minimal adjustment of the real config
that both tools accept: `"moduleResolution": "bundler"` instead of `"node"`,
and `baseUrl` dropped (the `paths` entries are already explicit relative paths,
so nothing else changes). ztsc reads *both* files, and its diagnostic set is
identical under either — the same 17 keys, and the same 1,091 files / 330,555
lines loaded — so the adjustment changes what tsgo can run, not what is being
measured.

### Scaling with `--checkers`

Peak memory grows with the checker count on both tools — steeply on tsgo,
flatly on ztsc. Sweeping drizzle-orm, the corpus's heaviest package for tsgo,
from `--checkers=1` to `--checkers=8`:

| `--checkers` | ztsc peak RSS | tsgo peak RSS |
|---|---:|---:|
| 1 | 18.1 MB | 174 MB |
| 8 | 20.1 MB | 419 MB |

ztsc's entire N=1→N=8 range stays below tsgo's leanest single-checker run on
every package.

What the checker count buys, measured on the synthetic `multi` corpus (201
files / 93k lines, real lib loaded) — parallelism costs some duplicated type
construction, since each checker re-derives types its siblings also built. The
check-phase column is measured with `--skip-default-lib-check` so the scaling
shape isn't masked by the fixed lib cost every configuration pays; peak RSS is
at the defaults:

| `--checkers=N` | check phase | duplicated types vs N=1 | peak RSS |
|---|---:|---:|---:|
| 1 | 64.5 ms | — | 41.3 MB |
| 2 | 33.8 ms | +5.6% | 42.6 MB |
| **4** (default) | **18.0 ms** | **+10.9%** | **42.7 MB** |
| 8 | 13.5 ms | +20.6% | 41.5 MB |

Four is the ceiling of the default because the returns flatten after it while
the duplication keeps climbing; `--checkers=8` remains available for the extra
speed. Below 32k nodes of check work the default drops to two instead: a
checker instance carries fixed state (its own type-store overlay, per-symbol
arrays, arenas, caches, thread) that a small program never repays, so on the
corpus's smallest packages two instances are both leaner and no slower. An
explicit `--checkers=N` always wins over the default, and the diagnostics are
byte-identical for any N.

### The synthetic corpora, for continuity

The generated corpora that carried the project's earlier tuning still run.
The rows below were taken 2026-08-02 at commit d308f63, before the perf series
that produced the package table above — ztsc has only moved down since: the
standing `bench/e2e.sh multi` gate currently records ztsc at **0.02–0.03 s and
~40 MB** (42 MB worst of three runs) against tsgo's **0.08 s and ~200 MB** at
four checkers. tsc 5.5.4 was retired from the ongoing bench scripts, so its
rows are the 2026-07-14 figures it retired on; tsgo is the baseline that
matters:

| corpus | tool | wall | peak RSS | rss vs tsgo |
|---|---|---:|---:|---:|
| **medium** · 50 files / 50k lines | ztsc | 20.0 ms | 25.1 MB | 22% |
| | tsgo | 43.9 ms | 113.3 MB | 100% |
| | tsc 5.5.4 | 0.59 s | 224.4 MB | 198% |
| **multi** · 201 files / 93k lines | ztsc | 33.2 ms | 42.9 MB | 21% |
| | tsgo | 81.0 ms | 206.1 MB | 100% |
| | tsc 5.5.4 | 0.91 s | 316.3 MB | 153% |

## Methodology

**Hardware.** Apple M4 (10 cores), 32 GB RAM, macOS 26.5.1.

**Versions.** ztsc 0.0.1-dev at commit 732ab8b, built with `zig build bench`
(ReleaseFast, Zig 0.16.0), run as a native binary. tsgo 7.0.2, the native arm64
TypeScript compiler, invoked directly (no Node host in the measurement).

**Corpus.** `bench/fetch_real.sh` vendors the published `.d.ts` of each package
via `npm pack` at the pinned versions above, and writes a benchmark
`tsconfig.json` (`noEmit`, `strict`, `target: esnext`) into each so both tools
check identical inputs through `-p <dir>`. The corpus is gitignored; regenerate
with the script. The excalidraw corpus is a `yarn`-installed checkout at commit
`a2ec2889` (~1 GB with `node_modules`), so it is not vendored either — it is
passed in by path, and both tools check it through the shared
`tsconfig.tsgo.json` described above.

**Cold runs.** Neither config sets `incremental`, and no `*.tsbuildinfo` or
other cache artifact is written by either tool on any of these corpora — checked
before, between, and after every timed run. Every run is cold.

**Checkers.** `--checkers=N` runs N parallel checker instances that trade some
duplicated type construction for lock-free parallelism. tsgo defaults to 4;
ztsc defaults to `min(4, cores)`, dropping to 2 on programs with less than 32k
nodes of check work. Every row above is defaults vs. defaults. tsgo takes the
space form (`--checkers 4`); ztsc takes `--checkers=4`.

**Defaults.** Both tools are measured at their defaults. ztsc type-checks its
embedded default lib (like tsc/tsgo), so this is a like-for-like comparison;
`--skip-default-lib-check` (tsc's `skipDefaultLibCheck`) turns ztsc's lib check
off, saving a few ms and a few MB with byte-identical diagnostics.

**Protocol.** Per configuration: one untimed warm-up, then 11 timed runs with a
monotonic nanosecond timer around the whole process — the tables report the
median — plus 5 runs under `/usr/bin/time -l` for peak resident set size, again
reported as the median. Timing the whole process at nanosecond resolution is
what makes the small-package ratios real rather than timer rounding. Run-to-run
RSS spread was under 3% for ztsc on every package; tsgo's was noisier, up to ~7%
(`@types/react`), which is why the medians matter.

## Reproducing

Everything on this page comes out of one script:

```sh
bench/fetch_real.sh   # once: vendor the pinned .d.ts + write tsconfigs
bench/matrix.sh       # the whole matrix -> bench/RESULTS.md + bench/results.tsv
```

`bench/matrix.sh` sweeps ztsc over `--checkers=1,2,4,8` against tsgo on every
package here and on the `bench/apps` application checkouts, interleaved and
median-of-N, and writes both tables with a provenance header (date, commit,
tsgo version, host, run counts). **Numbers on this page are copied out of
`bench/RESULTS.md`, never retyped from a terminal** — a hand-transcribed
drizzle-orm row once sat 120× stale for 147 commits. Pass a substring to
narrow it: `bench/matrix.sh chalk`.

The single-package recipe it automates, for reference:

```sh
bench/fetch_real.sh                    # vendor the pinned .d.ts + write tsconfigs
zig build bench                        # ReleaseFast binary -> zig-out/bench/ztsc

ZTSC=zig-out/bench/ztsc
TSGO=bench/baselines/tsgo/node_modules/@typescript/typescript-darwin-arm64/lib/tsc
C=bench/corpus/real/_types_node_22.7.4

"$ZTSC" --pretty=false -p "$C"                           # wall: median of 11
/usr/bin/time -l "$TSGO" --noEmit --checkers 4 -p "$C"   # RSS: median of 5
```

ztsc is run without `--checkers` so it picks its own default, the way tsgo
picks 4; pass `--checkers=N` to pin either tool. Time the wall clock around the
whole process with a monotonic nanosecond timer and take the median of 11 runs
after one warm-up; take peak RSS (the "maximum resident set size" line of
`/usr/bin/time -l`, in bytes) as the median of 5.
Note tsgo's space form for `--checkers`, not `=4`. Nonzero exit is expected —
the packages are vendored without their dependencies — and both tools fully
check every file regardless.

### Reproducing the excalidraw row

The checkout is ~1 GB, so it is not vendored:

```sh
git clone https://github.com/excalidraw/excalidraw && cd excalidraw
git checkout a2ec2889
yarn                                   # node_modules is part of the corpus
```

Then write `tsconfig.tsgo.json` next to `tsconfig.json` — the project's own
config with the two options TypeScript 7 removed adjusted, and nothing else
changed:

```json
{
  "compilerOptions": {
    "rootDir": "./",
    "target": "ESNext",
    "lib": ["dom", "dom.iterable", "esnext"],
    "types": ["vitest/globals", "@testing-library/jest-dom"],
    "allowJs": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true,
    "strict": true,
    "forceConsistentCasingInFileNames": true,
    "noFallthroughCasesInSwitch": true,
    "module": "ESNext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "paths": {
      "@excalidraw/excalidraw": ["./packages/excalidraw/index.tsx"],
      "@excalidraw/utils": ["./packages/utils/index.ts"],
      "@excalidraw/math": ["./packages/math/index.ts"],
      "@excalidraw/excalidraw/*": ["./packages/excalidraw/*"],
      "@excalidraw/utils/*": ["./packages/utils/*"],
      "@excalidraw/math/*": ["./packages/math/*"]
    }
  },
  "include": ["packages", "excalidraw-app"],
  "exclude": ["examples", "dist", "types", "tests"]
}
```

Run both tools from inside the checkout, same protocol as above:

```sh
ztsc --pretty=false --checkers=4 -p tsconfig.tsgo.json
tsgo --noEmit --pretty false --checkers 4 -p tsconfig.tsgo.json
```

To compare the diagnostic sets, strip each tool's message text down to the
(file, line, column, code) key — tsgo prints `file(line,col):` and ztsc prints
`file:line:col:`:

```sh
# ztsc
sed -nE 's|^(.+):([0-9]+):([0-9]+): error (TS[0-9]+):.*$|\1:\2:\3:\4|p' | sort -u
# tsgo
sed -nE 's|^(.+)\(([0-9]+),([0-9]+)\): error (TS[0-9]+):.*$|\1:\2:\3:\4|p' | sort -u
```

Both yield the same 17 keys. The whole property — every checker count from 1 to
8, repeated, scored against the pinned oracle — is one command from a ztsc
checkout:

```sh
EXC=/path/to/excalidraw bench/convergence.sh
```

It sweeps `--checkers` 1..8, asserts run-to-run stability at each count, asserts
cross-N set equality of the diagnostic keys, and scores every count against tsgo
for matched / under / excess. Both ceilings are zero.
