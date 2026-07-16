# ZTSC — Benchmarks

Wall clock and peak memory for **ztsc vs tsgo** (the native TypeScript 7
compiler), checking real, published packages on identical inputs. Measured
2026-07-15 on an Apple M4.

ztsc checks a subset of TypeScript, against the lib each package's tsconfig
selects — es-core..esnext for most, plus the real DOM lib for the three packages
that list `dom` (hono, zod, and `@types/react`), matching tsgo's target-esnext
default. Its
diagnostic output still differs from tsgo's on real code — these are throughput
and memory measurements on identical inputs, not a diagnostic-parity claim
(correctness is tracked separately by a differential conformance suite validated
against the TypeScript compiler). hono and zod now check against the 2.35 MB DOM
lib, so their memory and wall clock rose from earlier esnext-only measurements —
that added front end is why their rows moved. Packages are vendored without their
dependencies; both tools fully parse, bind, and check every file regardless of
exit code. Wall times below ~10 ms saturate the timer's resolution — see the
millisecond-precision re-measure below for honest small-package ratios.

**A fairness note on defaults.** By default ztsc now *skips type-checking* its
embedded standard library — it still parses, binds, and links the lib (globals
and lazy type expansion are unaffected; lib diagnostics were never surfaced
anyway), it just doesn't re-check the pre-verified lib files. This is tsc's
`skipDefaultLibCheck` behavior, on by default because the shipped lib is
verified with every release; the new `--check-default-lib` flag restores the old
behavior, and diagnostics are byte-identical either way. tsgo and tsc, by
contrast, *do* check their default lib at their defaults — so the headline
defaults-vs-defaults numbers below compare ztsc-with-skip against tsgo-without.
For a like-for-like read, tsgo run with `--skipDefaultLibCheck` (same protocol)
posts: @types/node 43.8 ms / 92.5 MB, @types/react 157.7 / 136.9, drizzle-orm
240.5 / 270.3, hono 78.2 / 111.8, @sinclair/typebox 43.8 / 70.2, ajv 18.6 /
41.1, zod 60.6 / 90.6, chalk 12.1 / 33.8. Even against tsgo-with-the-flag ztsc
stays **1.3–11.1× faster** (2.3× on @types/node, 5.0× @types/react, 11.1×
drizzle-orm, 2.3× hono, 2.7× typebox, 1.6× ajv, 1.9× zod, 1.3× chalk).

## Results

Both tools default to 4 checker instances. Peak memory at that default, across
all eight packages:

```
peak RSS at the default 4 checkers — MB, lower is better

@types/node        ztsc ███ 17
                   tsgo ████████████████████ 102
@types/react       ztsc ███ 17
                   tsgo ██████████████████████████████████████ 188
drizzle-orm        ztsc █████ 23
                   tsgo ███████████████████████████████████████████████████████ 274
hono               ztsc ████ 21
                   tsgo ███████████████████████████████ 155
@sinclair/typebox  ztsc ███ 15
                   tsgo ████████████████ 78
ajv                ztsc ██ 10
                   tsgo ██████████ 50
zod                ztsc ███ 17
                   tsgo ███████████████████████████ 135
chalk              ztsc █ 7
                   tsgo █████████ 43
```

At the default, ztsc's peak memory is **8–20% of tsgo's**. The full matrix over
`--checkers` ∈ {1, 2, 4, 8} follows; each cell is `ztsc / tsgo`.

**Peak RSS (MB)**

| package (files / lines) | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 (59 / 49.6k) | 15.8 / 88.1 | 16.8 / 94.5 | **16.8 / 101.9** | 16.8 / 108.1 |
| @types/react 18.3.11 (4 / 4.8k) | 17.0 / 153.0 | 17.0 / 186.9 | **17.0 / 187.5** | 17.0 / 186.7 |
| drizzle-orm 0.33.0 (288 / 12.6k) | 20.4 / 167.7 | 23.0 / 227.5 | **22.6 / 273.6** | 23.9 / 403.6 |
| hono 4.6.3 (165 / 6.3k) | 21.2 / 141.6 | 21.0 / 144.4 | **21.2 / 155.0** | 23.1 / 166.5 |
| @sinclair/typebox 0.33.12 (241 / 3.1k) | 12.8 / 65.8 | 14.2 / 70.4 | **15.2 / 77.5** | 16.0 / 87.0 |
| ajv 8.17.1 (107 / 1.8k) | 9.2 / 44.9 | 9.4 / 46.7 | **10.0 / 49.5** | 11.1 / 52.4 |
| zod 3.23.8 (24 / 1.6k) | 17.3 / 121.7 | 17.3 / 133.2 | **17.3 / 135.2** | 17.3 / 139.5 |
| chalk 5.3.0 (5 / 612) | 6.5 / 39.1 | 6.5 / 40.7 | **6.5 / 43.4** | 6.5 / 45.9 |

**Wall clock (seconds)**

| package | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 | 0.02 / 0.07 | 0.02 / 0.05 | **0.01 / 0.04** | 0.01 / 0.04 |
| @types/react 18.3.11 | 0.03 / 0.24 | 0.03 / 0.25 | **0.03 / 0.25** | 0.03 / 0.17 |
| drizzle-orm 0.33.0 | 0.03 / 0.28 | 0.02 / 0.25 | **0.02 / 0.24** | 0.02 / 0.29 |
| hono 4.6.3 | 0.03 / 0.20 | 0.03 / 0.19 | **0.03 / 0.17** | 0.03 / 0.14 |
| @sinclair/typebox 0.33.12 | 0.01 / 0.06 | 0.01 / 0.05 | **0.01 / 0.04** | 0.01 / 0.04 |
| ajv 8.17.1 | 0.01 / 0.03 | 0.01 / 0.02 | **0.01 / 0.02** | 0.01 / 0.02 |
| zod 3.23.8 | 0.03 / 0.16 | 0.03 / 0.15 | **0.03 / 0.15** | 0.03 / 0.12 |
| chalk 5.3.0 | 0.00 / 0.02 | 0.00 / 0.01 | **0.00 / 0.01** | 0.00 / 0.01 |

Peak memory grows with the checker count on both tools — steeply on tsgo
(drizzle-orm climbs 168 → 404 MB from N=1 to N=8), flatly on ztsc (20 → 24 MB).
ztsc's entire N=1→N=8 range stays below tsgo's leanest single-checker run on
every package.

### Wall clock at millisecond precision (re-measured at HEAD, 2026-07-15)

`/usr/bin/time`'s 10 ms resolution makes the small-package ratios above mostly
rounding. Re-measured with a monotonic nanosecond timer around the whole
process (median of 11 runs after one warm-up, defaults, same corpus; RSS
median of 5 runs re-taken in the same session — HEAD includes CommonJS
interop, the 7.0.2 lib, and the DOM lib that hono, zod, and `@types/react`
pull in via their tsconfig `dom` setting):

| package | wall ztsc / tsgo | wall vs tsgo | peak RSS ztsc / tsgo | rss vs tsgo |
|---|---:|---:|---:|---:|
| @types/node 22.7.4 | 19.4 / 47.2 ms | 41% | 16.9 / 102.1 MB | 17% |
| @types/react 18.3.11 | 31.5 / 247.6 ms | 13% | 17.0 / 186.7 MB | 9% |
| drizzle-orm 0.33.0 | 21.7 / 240.2 ms | 9% | 22.6 / 271.7 MB | 8% |
| hono 4.6.3 | 33.7 / 172.9 ms | 19% | 21.2 / 156.9 MB | 14% |
| @sinclair/typebox 0.33.12 | 16.3 / 48.9 ms | 33% | 15.6 / 78.2 MB | 20% |
| ajv 8.17.1 | 11.5 / 24.7 ms | 47% | 10.0 / 49.8 MB | 20% |
| zod 3.23.8 | 31.1 / 156.7 ms | 20% | 17.3 / 135.5 MB | 13% |
| chalk 5.3.0 | 9.1 / 19.4 ms | 47% | 6.5 / 43.7 MB | 15% |

The two highest ratios are the two smallest *esnext-only* packages (chalk,
ajv): at that size both tools sit near their process floors (ztsc ~9 ms —
startup plus the embedded 14k-line lib front end; tsgo ~19 ms), so the ratio
reflects fixed startup cost, not checking throughput. hono and zod land higher
than their size alone suggests (19–20% wall, 13–14% RSS) because their tsconfig
lists `dom`: ztsc parses and binds the 2.35 MB DOM lib for them too, a sizable
front end on top. On every package above ~3k lines ztsc is 2.4–11× faster;
@types/node, the largest, sits at the low end (41% wall) because its dense
declaration merging and interface heritage is the work ztsc closes least of the
gap on. `@types/react` is the corpus's heaviest row for tsgo — its deep
conditional types and the DOM-derived `DetailedHTMLProps` intrinsic-element
unions cost tsgo 248 ms — more wall time than any other package — and 187 MB,
yet ztsc checks the same surface in 32 ms and 17 MB (13% wall, 9% RSS), a 7.9×
speedup at one-eleventh the memory.

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

**Defaults.** ztsc is measured at its defaults, which since this change skip
re-checking the embedded pre-verified lib (tsc semantics: `skipDefaultLibCheck`);
tsgo is measured at its defaults, which check its default lib — the parity
`--skipDefaultLibCheck` numbers are given above.

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
/usr/bin/time -l "$TSGO" --noEmit --skipDefaultLibCheck --checkers 4 -p "$C"   # like-for-like parity
```

Take the median wall clock and peak RSS (the "maximum resident set size" line,
in bytes) over five runs after one warm-up. Nonzero exit is expected — the
packages are vendored without their dependencies — and both tools fully check
every file regardless.
