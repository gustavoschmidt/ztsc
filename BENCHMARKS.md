# ZTSC — Benchmarks

Wall clock and peak memory for **ztsc vs tsgo** (the native TypeScript 7
compiler), checking real, published packages on identical inputs. Measured
2026-07-25 on an Apple M4, ztsc at commit b0c8646.

ztsc checks a subset of TypeScript, against the lib each package's tsconfig
selects — es-core..esnext for most, plus the real DOM lib for the three packages
that list `dom` (hono, zod, and `@types/react`), matching tsgo's target-esnext
default. Its diagnostic output still differs from tsgo's on real code — these are
throughput and memory measurements on identical inputs, not a diagnostic-parity
claim (correctness is tracked separately by a differential conformance suite
validated against the TypeScript compiler). hono and zod check against the
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

Both tools default to 4 checker instances. Peak memory at that default, across
all eight packages:

```
peak RSS at the default 4 checkers — MB, lower is better

@types/node        ztsc ███ 17
                   tsgo ████████████████████ 102
@types/react       ztsc █████ 23
                   tsgo █████████████████████████████████████ 185
drizzle-orm        ztsc ███ 15
                   tsgo ██████████████████████████████████████████████████████ 272
hono               ztsc █████ 25
                   tsgo ██████████████████████████████ 153
@sinclair/typebox  ztsc ████ 20
                   tsgo ███████████████ 78
ajv                ztsc ██ 12
                   tsgo ██████████ 50
zod                ztsc ████ 21
                   tsgo ████████████████████████████ 140
chalk              ztsc ██ 8
                   tsgo █████████ 44
```

At the default, ztsc's peak memory is **5–25% of tsgo's** and its wall clock
**6–56%** — smaller *and* faster on every package:

| package (files / lines) | wall ztsc / tsgo | wall vs tsgo | peak RSS ztsc / tsgo | rss vs tsgo |
|---|---:|---:|---:|---:|
| @types/node 22.7.4 (59 / 49.6k) | 14.5 / 45.7 ms | 32% | 17.3 / 102.4 MB | 17% |
| @types/react 18.3.11 (6 / 64.1k) | 28.4 / 243.4 ms | 12% | 22.7 / 185.4 MB | 12% |
| drizzle-orm 0.33.0 (288 / 12.6k) | 15.0 / 232.4 ms | 6% | 14.6 / 272.4 MB | 5% |
| hono 4.6.3 (165 / 6.3k) | 32.0 / 171.2 ms | 19% | 24.5 / 153.3 MB | 16% |
| @sinclair/typebox 0.33.12 (241 / 3.1k) | 18.3 / 47.1 ms | 39% | 19.6 / 77.7 MB | 25% |
| ajv 8.17.1 (107 / 1.8k) | 13.1 / 23.4 ms | 56% | 11.5 / 49.8 MB | 23% |
| zod 3.23.8 (24 / 1.6k) | 27.7 / 154.2 ms | 18% | 21.2 / 139.7 MB | 15% |
| chalk 5.3.0 (5 / 612) | 7.8 / 18.6 ms | 42% | 7.8 / 43.7 MB | 18% |

That is **4–19× less peak memory**, and faster on all eight packages by up to
15×. The highest time ratios are the two *smallest* packages (ajv 56%, chalk
42%) and `@sinclair/typebox` (39%): at that size both tools sit near their
process floors — ztsc's ~8–13 ms is startup plus its embedded lib front end,
which it type-checks by default just like tsgo, and tsgo's floor is ~19 ms — so
the ratio reflects fixed startup cost, not checking throughput. Excluding those
near-floor packages, ztsc is **2.6–15× faster**. hono and zod land higher than
their size alone suggests (19% / 18% wall) because their tsconfig lists `dom`:
ztsc parses, binds, and checks the 2.35 MB DOM lib for them too, a sizable front
end on top. `@types/node`, the densest declaration corpus, sits at 32% wall —
its declaration merging and interface heritage is the work ztsc closes least of
the gap on. `@types/react` is the corpus's heaviest row for tsgo — its deep
conditional types and the DOM-derived `DetailedHTMLProps` intrinsic-element
unions cost tsgo 243 ms, more wall time than any other package, and 185 MB —
yet ztsc checks the same surface in 28 ms and 23 MB (12% wall, 12% RSS), an
8.6× speedup at one-eighth the memory. drizzle-orm is the widest gap in the
corpus: 15 ms against 232 ms, 14.6 MB against 272.4 MB.

### Scaling with `--checkers`

Peak memory grows with the checker count on both tools — steeply on tsgo,
flatly on ztsc. Sweeping drizzle-orm, the corpus's heaviest package for tsgo,
from `--checkers=1` to `--checkers=8`:

| `--checkers` | ztsc peak RSS | tsgo peak RSS |
|---|---:|---:|
| 1 | 14.6 MB | 171 MB |
| 8 | 19.0 MB | 407 MB |

ztsc's entire N=1→N=8 range stays below tsgo's leanest single-checker run on
every package.

What the checker count buys, measured on the synthetic `multi` corpus (201
files / 93k lines, real lib loaded) — parallelism costs some duplicated type
construction, since each checker re-derives types its siblings also built:

| `--checkers=N` | check phase | duplicated types vs N=1 | peak RSS |
|---|---:|---:|---:|
| 1 | 84.7 ms | — | 42.3 MB |
| 2 | 44.9 ms | +7.2% | 43.5 MB |
| **4** (default) | **24.3 ms** | **+15.5%** | **46.3 MB** |
| 8 | 21.8 ms | +23.3% | 45.4 MB |

Four is the default because the returns flatten after it while the duplication
keeps climbing; `--checkers=8` remains available for the extra speed.

### The synthetic corpora, for continuity

The generated corpora that carried the project's earlier tuning still run,
re-measured 2026-07-25 with the same protocol as the package table above. tsc
5.5.4 was retired from the ongoing bench scripts, so its rows are the
2026-07-14 figures it retired on; tsgo is the baseline that matters:

| corpus | tool | wall | peak RSS | rss vs tsgo |
|---|---|---:|---:|---:|
| **medium** · 50 files / 50k lines | ztsc | 24.0 ms | 27.0 MB | 25% |
| | tsgo | 42.3 ms | 108.8 MB | 100% |
| | tsc 5.5.4 | 0.59 s | 224.4 MB | 206% |
| **multi** · 201 files / 93k lines | ztsc | 39.9 ms | 46.0 MB | 24% |
| | tsgo | 75.5 ms | 194.3 MB | 100% |
| | tsc 5.5.4 | 0.91 s | 316.3 MB | 163% |

## Methodology

**Hardware.** Apple M4 (10 cores), 32 GB RAM, macOS 26.5.1.

**Versions.** ztsc 0.0.1-dev at commit b0c8646, built with `zig build bench`
(ReleaseFast, Zig 0.16.0), run as a native binary. tsgo 7.0.2, the native arm64
TypeScript compiler, invoked directly (no Node host in the measurement).

**Corpus.** `bench/fetch_real.sh` vendors the published `.d.ts` of each package
via `npm pack` at the pinned versions above, and writes a benchmark
`tsconfig.json` (`noEmit`, `strict`, `target: esnext`) into each so both tools
check identical inputs through `-p <dir>`. The corpus is gitignored; regenerate
with the script.

**Checkers.** `--checkers=N` runs N parallel checker instances that trade some
duplicated type construction for lock-free parallelism. Both tools default to 4.
tsgo takes the space form (`--checkers 4`); ztsc takes `--checkers=4`.

**Defaults.** Both tools are measured at their defaults. ztsc type-checks its
embedded default lib (like tsc/tsgo), so this is a like-for-like comparison;
`--skip-default-lib-check` (tsc's `skipDefaultLibCheck`) turns ztsc's lib check
off, saving a few ms and a few MB with byte-identical diagnostics.

**Protocol.** Per configuration: one untimed warm-up, then 11 timed runs with a
monotonic nanosecond timer around the whole process — the tables report the
median — plus 5 runs under `/usr/bin/time -l` for peak resident set size, again
reported as the median. Timing the whole process at nanosecond resolution is
what makes the small-package ratios real rather than timer rounding. Run-to-run
RSS spread was under 3% (drizzle-orm on tsgo the noisiest, ~5%).

## Reproducing

```sh
bench/fetch_real.sh                    # vendor the pinned .d.ts + write tsconfigs
zig build bench                        # ReleaseFast binary -> zig-out/bench/ztsc

ZTSC=zig-out/bench/ztsc
TSGO=bench/baselines/tsgo/node_modules/@typescript/typescript-darwin-arm64/lib/tsc
C=bench/corpus/real/_types_node_22.7.4

"$ZTSC" --pretty=false --checkers=4 -p "$C"              # wall: median of 11
/usr/bin/time -l "$TSGO" --noEmit --checkers 4 -p "$C"   # RSS: median of 5
```

Time the wall clock around the whole process with a monotonic nanosecond timer
and take the median of 11 runs after one warm-up; take peak RSS (the "maximum
resident set size" line of `/usr/bin/time -l`, in bytes) as the median of 5.
Note tsgo's space form for `--checkers`, not `=4`. Nonzero exit is expected —
the packages are vendored without their dependencies — and both tools fully
check every file regardless.
