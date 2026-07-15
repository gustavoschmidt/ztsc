# ZTSC — Benchmarks

Wall clock and peak memory for **ztsc vs tsgo** (the native TypeScript 7
compiler), checking real, published packages on identical inputs. Measured
2026-07-15 on an Apple M4.

ztsc checks a subset of TypeScript, against the lib each package's tsconfig
selects — es-core..esnext for most, plus the real DOM lib for the two packages
that list `dom` (hono and zod), matching tsgo's target-esnext default. Its
diagnostic output still differs from tsgo's on real code — these are throughput
and memory measurements on identical inputs, not a diagnostic-parity claim
(correctness is tracked separately by a differential conformance suite validated
against the TypeScript compiler). hono and zod now check against the 2.35 MB DOM
lib, so their memory and wall clock rose from earlier esnext-only measurements —
that added front end is why their rows moved. Packages are vendored without their
dependencies; both tools fully parse, bind, and check every file regardless of
exit code. Wall times below ~10 ms saturate the timer's resolution — see the
millisecond-precision re-measure below for honest small-package ratios.

## Results

Both tools default to 4 checker instances. Peak memory at that default, across
all seven packages:

```
peak RSS at the default 4 checkers — MB, lower is better

@types/node        ztsc ████ 18
                   tsgo ████████████████████ 100
drizzle-orm        ztsc ████ 22
                   tsgo ████████████████████████████████████████████████████████ 278
hono               ztsc █████ 24
                   tsgo ███████████████████████████████ 155
@sinclair/typebox  ztsc ███ 16
                   tsgo ████████████████ 78
ajv                ztsc ██ 11
                   tsgo ██████████ 50
zod                ztsc ████ 20
                   tsgo ███████████████████████████ 136
chalk              ztsc █ 7
                   tsgo █████████ 44
```

At the default, ztsc's peak memory is **8–21% of tsgo's**. The full matrix over
`--checkers` ∈ {1, 2, 4, 8} follows; each cell is `ztsc / tsgo`.

**Peak RSS (MB)**

| package (files / lines) | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 (59 / 49.6k) | 16.2 / 88.3 | 17.2 / 92.5 | **18.1 / 99.9** | 17.1 / 109.0 |
| drizzle-orm 0.33.0 (288 / 12.6k) | 21.0 / 165.9 | 21.0 / 231.3 | **22.4 / 277.7** | 23.7 / 402.8 |
| hono 4.6.3 (165 / 6.3k) | 26.1 / 144.1 | 26.4 / 146.0 | **24.3 / 154.6** | 24.5 / 165.4 |
| @sinclair/typebox 0.33.12 (241 / 3.1k) | 13.6 / 66.0 | 14.0 / 71.2 | **15.5 / 78.0** | 16.6 / 86.8 |
| ajv 8.17.1 (107 / 1.8k) | 9.8 / 44.9 | 9.6 / 46.8 | **10.5 / 49.7** | 11.0 / 52.7 |
| zod 3.23.8 (24 / 1.6k) | 21.5 / 119.5 | 20.3 / 131.9 | **20.4 / 135.7** | 20.5 / 138.0 |
| chalk 5.3.0 (5 / 612) | 6.5 / 38.9 | 6.5 / 40.5 | **6.5 / 43.5** | 6.5 / 46.2 |

**Wall clock (seconds)**

| package | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 | 0.02 / 0.07 | 0.01 / 0.05 | **0.01 / 0.05** | 0.01 / 0.04 |
| drizzle-orm 0.33.0 | 0.03 / 0.26 | 0.02 / 0.23 | **0.02 / 0.23** | 0.01 / 0.28 |
| hono 4.6.3 | 0.05 / 0.19 | 0.04 / 0.18 | **0.04 / 0.17** | 0.04 / 0.13 |
| @sinclair/typebox 0.33.12 | 0.01 / 0.06 | 0.01 / 0.05 | **0.01 / 0.04** | 0.01 / 0.04 |
| ajv 8.17.1 | 0.01 / 0.03 | 0.01 / 0.02 | **0.01 / 0.02** | 0.01 / 0.02 |
| zod 3.23.8 | 0.04 / 0.16 | 0.04 / 0.15 | **0.04 / 0.15** | 0.04 / 0.12 |
| chalk 5.3.0 | 0.01 / 0.02 | 0.01 / 0.01 | **0.01 / 0.01** | 0.01 / 0.01 |

Peak memory grows with the checker count on both tools — steeply on tsgo
(drizzle-orm climbs 166 → 403 MB from N=1 to N=8), flatly on ztsc (21 → 24 MB).
ztsc's entire N=1→N=8 range stays below tsgo's leanest single-checker run on
every package.

### Wall clock at millisecond precision (re-measured at HEAD, 2026-07-15)

`/usr/bin/time`'s 10 ms resolution makes the small-package ratios above mostly
rounding. Re-measured with a monotonic nanosecond timer around the whole
process (median of 11 runs after one warm-up, defaults, same corpus; RSS
median of 5 runs re-taken in the same session — HEAD includes CommonJS
interop, the 7.0.2 lib, and the DOM lib that hono and zod pull in via their
tsconfig `dom` setting):

| package | wall ztsc / tsgo | wall vs tsgo | peak RSS ztsc / tsgo | rss vs tsgo |
|---|---:|---:|---:|---:|
| @types/node 22.7.4 | 20.2 / 45.4 ms | 44% | 18.0 / 102.4 MB | 18% |
| drizzle-orm 0.33.0 | 22.8 / 239.0 ms | 10% | 22.4 / 274.9 MB | 8% |
| hono 4.6.3 | 44.9 / 173.3 ms | 26% | 24.3 / 155.2 MB | 16% |
| @sinclair/typebox 0.33.12 | 17.4 / 48.5 ms | 36% | 15.5 / 77.4 MB | 20% |
| ajv 8.17.1 | 14.1 / 23.6 ms | 60% | 10.5 / 49.5 MB | 21% |
| zod 3.23.8 | 40.6 / 153.8 ms | 26% | 20.4 / 140.1 MB | 15% |
| chalk 5.3.0 | 11.4 / 18.4 ms | 62% | 6.5 / 43.6 MB | 15% |

The two highest ratios are the two smallest *esnext-only* packages (chalk,
ajv): at that size both tools sit near their process floors (ztsc ~13 ms —
startup plus the embedded 14k-line lib front end; tsgo ~20 ms), so the ratio
reflects fixed startup cost, not checking throughput. hono and zod land higher
than their size alone suggests (26% wall, 15–16% RSS) because their tsconfig
lists `dom`: ztsc parses, binds, and checks the 2.35 MB DOM lib for them too, a
~25 ms front end on top. On every package above ~3k lines ztsc is 2–10× faster;
@types/node, the largest, sits at the low end (44% wall) because its dense
declaration merging and interface heritage is the work ztsc closes least of the
gap on.

## Methodology

**Hardware.** Apple M4 (10 cores), 32 GB RAM, macOS 26.5.1.

**Versions.** ztsc 0.0.1-dev, built with `zig build bench` (ReleaseFast, Zig
0.16.0), run as a native binary. tsgo 7.0.2, the native arm64 TypeScript
compiler, invoked directly (no Node host in the measurement).

**Corpus.** `bench/fetch_real.sh` vendors the published `.d.ts` of each package
via `npm pack` at the pinned versions above, and writes a benchmark
`tsconfig.json` (`noEmit`, `strict`, `target: esnext`) into each so both tools
check identical inputs through `-p <dir>`. The corpus is gitignored; regenerate
with the script.

**Checkers.** `--checkers=N` runs N parallel checker instances that trade some
duplicated type construction for lock-free parallelism. Both tools default to 4.
tsgo takes the space form (`--checkers 4`); ztsc takes `--checkers=4`.

**Protocol.** Per configuration: one untimed warm-up, then five timed runs under
`/usr/bin/time -l`. Tables report the median wall clock and median peak resident
set size. Run-to-run RSS spread was under 3% (drizzle-orm on tsgo the noisiest,
~5%); wall clock varied within the timer's 10 ms resolution.

## Reproducing

```sh
bench/fetch_real.sh                    # vendor the pinned .d.ts + write tsconfigs
zig build bench                        # ReleaseFast binary -> zig-out/bench/ztsc

ZTSC=zig-out/bench/ztsc
TSGO=bench/baselines/tsgo/node_modules/@typescript/typescript-darwin-arm64/lib/tsc
C=bench/corpus/real/_types_node_22.7.4

/usr/bin/time -l "$ZTSC" --pretty=false --checkers=4 -p "$C"
/usr/bin/time -l "$TSGO" --noEmit --checkers 4 -p "$C"   # note: space form, not =4
```

Take the median wall clock and peak RSS (the "maximum resident set size" line,
in bytes) over five runs after one warm-up. Nonzero exit is expected — the
packages are vendored without their dependencies — and both tools fully check
every file regardless.
