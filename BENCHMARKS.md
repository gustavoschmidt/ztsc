# ZTSC — Benchmarks

Wall clock and peak memory for **ztsc vs tsgo** (the native TypeScript 7
compiler), checking real, published packages on identical inputs. Measured
2026-07-15 on an Apple M4.

ztsc checks a subset of TypeScript against an esnext-only lib (no DOM), so its
diagnostic output differs from tsgo's on real code — these are throughput and
memory measurements on identical inputs, not a diagnostic-parity claim
(correctness is tracked separately by a 388-case differential conformance suite
validated against the TypeScript compiler). Packages are vendored without their
dependencies; both tools fully parse, bind, and check every file regardless of
exit code. Wall times below ~10 ms saturate the timer's resolution — see the
millisecond-precision re-measure below for honest small-package ratios.

## Results

Both tools default to 4 checker instances. Peak memory at that default, across
all seven packages:

```
peak RSS at the default 4 checkers — MB, lower is better

@types/node        ztsc ███ 17
                   tsgo ████████████████████ 101
drizzle-orm        ztsc ████ 22
                   tsgo ████████████████████████████████████████████████████████ 280
hono               ztsc ███ 14
                   tsgo ███████████████████████████████ 156
@sinclair/typebox  ztsc ███ 15
                   tsgo ████████████████ 78
ajv                ztsc ██ 10
                   tsgo ██████████ 50
zod                ztsc ██ 8
                   tsgo ███████████████████████████ 136
chalk              ztsc █ 6
                   tsgo █████████ 44
```

At the default, ztsc's peak memory is **6–20% of tsgo's**. The full matrix over
`--checkers` ∈ {1, 2, 4, 8} follows; each cell is `ztsc / tsgo`.

**Peak RSS (MB)**

| package (files / lines) | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 (59 / 49.6k) | 15.4 / 88.4 | 16.0 / 94.9 | **17.0 / 100.6** | 16.5 / 108.2 |
| drizzle-orm 0.33.0 (288 / 12.6k) | 20.3 / 164.6 | 20.2 / 226.4 | **21.8 / 279.5** | 22.3 / 406.2 |
| hono 4.6.3 (165 / 6.3k) | 12.8 / 141.8 | 13.1 / 146.8 | **14.1 / 155.9** | 13.2 / 164.4 |
| @sinclair/typebox 0.33.12 (241 / 3.1k) | 12.6 / 65.6 | 13.0 / 70.5 | **14.8 / 78.3** | 15.8 / 87.7 |
| ajv 8.17.1 (107 / 1.8k) | 8.9 / 45.1 | 9.0 / 46.9 | **10.0 / 49.8** | 10.6 / 52.9 |
| zod 3.23.8 (24 / 1.6k) | 7.9 / 119.1 | 7.6 / 132.3 | **7.7 / 136.2** | 7.8 / 138.0 |
| chalk 5.3.0 (5 / 612) | 6.0 / 39.5 | 6.0 / 40.7 | **6.0 / 44.0** | 6.0 / 46.8 |

**Wall clock (seconds)**

| package | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 | 0.02 / 0.07 | 0.01 / 0.05 | **0.01 / 0.04** | 0.01 / 0.04 |
| drizzle-orm 0.33.0 | 0.03 / 0.26 | 0.02 / 0.23 | **0.02 / 0.23** | 0.01 / 0.28 |
| hono 4.6.3 | 0.01 / 0.19 | 0.01 / 0.18 | **0.01 / 0.17** | 0.01 / 0.13 |
| @sinclair/typebox 0.33.12 | 0.01 / 0.06 | 0.01 / 0.05 | **0.01 / 0.04** | 0.01 / 0.05 |
| ajv 8.17.1 | 0.01 / 0.03 | 0.01 / 0.02 | **0.01 / 0.02** | 0.01 / 0.02 |
| zod 3.23.8 | 0.01 / 0.16 | 0.01 / 0.15 | **0.01 / 0.15** | 0.01 / 0.12 |
| chalk 5.3.0 | 0.00 / 0.02 | 0.00 / 0.02 | **0.00 / 0.01** | 0.00 / 0.02 |

Peak memory grows with the checker count on both tools — steeply on tsgo
(drizzle-orm climbs 165 → 406 MB from N=1 to N=8), flatly on ztsc (20 → 22 MB).
ztsc's entire N=1→N=8 range stays below tsgo's leanest single-checker run on
every package.

### Wall clock at millisecond precision (re-measured at HEAD, 2026-07-15)

`/usr/bin/time`'s 10 ms resolution makes the small-package ratios above mostly
rounding. Re-measured with a monotonic nanosecond timer around the whole
process (median of 11 runs after one warm-up, defaults, same corpus; RSS
median of 5 runs re-taken in the same session — HEAD includes CommonJS
interop and the 7.0.2 lib):

| package | wall ztsc / tsgo | wall vs tsgo | peak RSS ztsc / tsgo | rss vs tsgo |
|---|---:|---:|---:|---:|
| @types/node 22.7.4 | 16.8 / 48.1 ms | 35% | 17.7 / 99.7 MB | 18% |
| drizzle-orm 0.33.0 | 24.2 / 241.8 ms | 10% | 22.4 / 275.1 MB | 8% |
| hono 4.6.3 | 18.2 / 179.2 ms | 10% | 14.7 / 156.8 MB | 9% |
| @sinclair/typebox 0.33.12 | 18.5 / 50.8 ms | 36% | 15.5 / 78.5 MB | 20% |
| ajv 8.17.1 | 14.5 / 24.9 ms | 58% | 10.4 / 49.6 MB | 21% |
| zod 3.23.8 | 13.1 / 159.1 ms | 8% | 9.0 / 141.2 MB | 6% |
| chalk 5.3.0 | 12.6 / 21.5 ms | 58% | 6.4 / 43.2 MB | 15% |

The two highest ratios are the two *smallest* packages: at that size both
tools sit near their process floors (ztsc ~13 ms — startup plus the embedded
14k-line lib front end; tsgo ~22 ms), so the ratio reflects fixed startup
cost, not checking throughput. On every package above ~3k lines ztsc is
3–12× faster.

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
