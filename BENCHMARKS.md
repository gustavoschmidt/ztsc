# ZTSC — Benchmarks

Wall clock and peak memory for **ztsc vs tsgo** (the native TypeScript 7
compiler), checking real, published packages on identical inputs. Measured
2026-07-16 on an Apple M4.

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
contrast, *do* check their default lib at their defaults — and the two tools now
default to *different* checker counts: ztsc to `min(8, cores)`, tsgo to 4. So the
headline defaults-vs-defaults numbers below compare ztsc-at-8-with-skip against
tsgo-at-4-without. For a like-for-like read, tsgo run with `--skipDefaultLibCheck`
(same protocol) posts: @types/node 42.9 ms / 92.5 MB, @types/react 153.8 / 140.6,
drizzle-orm 227.1 / 261.9, hono 78.4 / 111.2, @sinclair/typebox 43.7 / 70.3, ajv
18.9 / 41.2, zod 61.0 / 89.8, chalk 12.1 / 34.2. Even against tsgo-with-the-flag
ztsc stays **1.8–11.1× faster** (2.9× on @types/node, 6.7× @types/react, 11.1×
drizzle-orm, 3.1× hono, 2.7× typebox, 1.9× ajv, 2.7× zod, 1.8× chalk).

## Results

The two tools now default to *different* checker counts: ztsc to `min(8, cores)`
(so 8 on this machine), tsgo to 4. Peak memory at each tool's own default, across
all eight packages:

```
peak RSS at each tool's default (ztsc 8, tsgo 4) — MB, lower is better

@types/node        ztsc ███ 17
                   tsgo ████████████████████ 101
@types/react       ztsc ████ 18
                   tsgo █████████████████████████████████████ 186
drizzle-orm        ztsc █████ 24
                   tsgo ███████████████████████████████████████████████████████ 275
hono               ztsc █████ 23
                   tsgo ████████████████████████████████ 159
@sinclair/typebox  ztsc ███ 15
                   tsgo ███████████████ 77
ajv                ztsc ██ 11
                   tsgo ██████████ 50
zod                ztsc ███ 17
                   tsgo ███████████████████████████ 136
chalk              ztsc █ 7
                   tsgo █████████ 44
```

At each tool's default, ztsc's peak memory is **9–21% of tsgo's**. The full
matrix over `--checkers` ∈ {1, 2, 4, 8} follows; each cell is `ztsc / tsgo`, and
the two default columns (ztsc **N=8**, tsgo **N=4**) are bolded.

**Peak RSS (MB)** — tsgo's default is **N=4**, ztsc's is **N=8** (both bolded)

| package (files / lines) | N=1 | N=2 | **N=4** | **N=8** |
|---|---|---|---|---|
| @types/node 22.7.4 (59 / 49.6k) | 15.9 / 88.1 | 17.0 / 94.5 | **17.1 / 101.4** | **16.9 / 108.1** |
| @types/react 18.3.11 (4 / 4.8k) | 17.9 / 153.1 | 17.8 / 185.4 | **18.3 / 186.2** | **18.2 / 192.7** |
| drizzle-orm 0.33.0 (288 / 12.6k) | 20.2 / 168.1 | 22.7 / 228.2 | **22.4 / 275.0** | **23.7 / 407.3** |
| hono 4.6.3 (165 / 6.3k) | 19.5 / 143.4 | 20.4 / 146.0 | **21.3 / 158.6** | **22.9 / 163.1** |
| @sinclair/typebox 0.33.12 (241 / 3.1k) | 12.5 / 65.6 | 13.9 / 70.6 | **15.4 / 77.3** | **15.2 / 87.0** |
| ajv 8.17.1 (107 / 1.8k) | 8.7 / 45.3 | 9.3 / 46.5 | **9.9 / 49.9** | **10.7 / 52.5** |
| zod 3.23.8 (24 / 1.6k) | 17.9 / 122.6 | 17.8 / 132.2 | **17.9 / 136.1** | **17.0 / 138.2** |
| chalk 5.3.0 (5 / 612) | 6.7 / 39.1 | 6.7 / 40.5 | **6.2 / 43.5** | **6.7 / 46.2** |

**Wall clock (seconds)** — coarse `/usr/bin/time` resolution; the
millisecond-precision re-measure below is the honest read for the small packages

| package | N=1 | N=2 | **N=4** | **N=8** |
|---|---|---|---|---|
| @types/node 22.7.4 | 0.03 / 0.08 | 0.02 / 0.06 | **0.02 / 0.05** | **0.02 / 0.05** |
| @types/react 18.3.11 | 0.03 / 0.25 | 0.02 / 0.25 | **0.03 / 0.25** | **0.03 / 0.18** |
| drizzle-orm 0.33.0 | 0.04 / 0.28 | 0.03 / 0.24 | **0.02 / 0.24** | **0.02 / 0.27** |
| hono 4.6.3 | 0.03 / 0.20 | 0.03 / 0.19 | **0.03 / 0.17** | **0.03 / 0.14** |
| @sinclair/typebox 0.33.12 | 0.02 / 0.07 | 0.02 / 0.06 | **0.02 / 0.05** | **0.02 / 0.05** |
| ajv 8.17.1 | 0.01 / 0.03 | 0.01 / 0.03 | **0.01 / 0.03** | **0.01 / 0.03** |
| zod 3.23.8 | 0.02 / 0.17 | 0.02 / 0.16 | **0.02 / 0.15** | **0.02 / 0.13** |
| chalk 5.3.0 | 0.01 / 0.02 | 0.01 / 0.02 | **0.01 / 0.02** | **0.01 / 0.02** |

Peak memory grows with the checker count on both tools — steeply on tsgo
(drizzle-orm climbs 168 → 407 MB from N=1 to N=8), flatly on ztsc (20 → 24 MB).
ztsc's entire N=1→N=8 range stays below tsgo's leanest single-checker run on
every package.

### Wall clock at millisecond precision (re-measured at HEAD, 2026-07-16)

`/usr/bin/time`'s 10 ms resolution makes the small-package ratios above mostly
rounding. Re-measured with a monotonic nanosecond timer around the whole
process (median of 11 runs after one warm-up, each tool at its own default —
ztsc 8 checkers, tsgo 4 — same corpus; RSS median of 5 runs re-taken in the
same session — HEAD includes CommonJS interop, the 7.0.2 lib now sharded into
12 blobs, and the DOM lib that hono, zod, and `@types/react` pull in via their
tsconfig `dom` setting):

| package | wall ztsc / tsgo | wall vs tsgo | peak RSS ztsc / tsgo | rss vs tsgo |
|---|---:|---:|---:|---:|
| @types/node 22.7.4 | 14.8 / 46.1 ms | 32% | 16.9 / 101.4 MB | 17% |
| @types/react 18.3.11 | 23.1 / 242.3 ms | 10% | 18.2 / 186.2 MB | 10% |
| drizzle-orm 0.33.0 | 20.4 / 238.1 ms | 9% | 23.7 / 275.0 MB | 9% |
| hono 4.6.3 | 25.4 / 173.9 ms | 15% | 22.9 / 158.6 MB | 14% |
| @sinclair/typebox 0.33.12 | 16.1 / 47.9 ms | 34% | 15.2 / 77.3 MB | 20% |
| ajv 8.17.1 | 9.9 / 23.6 ms | 42% | 10.7 / 49.9 MB | 21% |
| zod 3.23.8 | 22.3 / 156.1 ms | 14% | 17.0 / 136.1 MB | 12% |
| chalk 5.3.0 | 6.7 / 18.1 ms | 37% | 6.7 / 43.5 MB | 15% |

The two highest ratios are the two smallest *esnext-only* packages (ajv,
chalk): at that size both tools sit near their process floors (ztsc ~7 ms —
startup plus the embedded 14k-line lib front end; tsgo ~18 ms), so the ratio
reflects fixed startup cost, not checking throughput. hono and zod land higher
than their size alone suggests (14–15% wall, 12–14% RSS) because their tsconfig
lists `dom`: ztsc parses and binds the 2.35 MB DOM lib for them too, a sizable
front end on top. On every package above ~3k lines ztsc is 3–11× faster;
@types/node, the largest, sits at the low end (32% wall) because its dense
declaration merging and interface heritage is the work ztsc closes least of the
gap on. `@types/react` is the corpus's heaviest row for tsgo — its deep
conditional types and the DOM-derived `DetailedHTMLProps` intrinsic-element
unions cost tsgo 242 ms — more wall time than any other package — and 186 MB,
yet ztsc checks the same surface in 23 ms and 18 MB (10% wall, 10% RSS), a 10.5×
speedup at one-tenth the memory.

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
duplicated type construction for lock-free parallelism. ztsc defaults to
`min(8, cores)` (8 on this machine); tsgo defaults to 4. tsgo takes the space
form (`--checkers 4`); ztsc takes `--checkers=4`.

**Defaults.** Each tool is measured at its own defaults, and those defaults now
differ in two ways. (1) Checker count: ztsc defaults to `min(8, cores)`, tsgo to
4. (2) Lib checking: ztsc skips re-checking the embedded pre-verified lib (tsc
semantics: `skipDefaultLibCheck`), while tsgo checks its default lib — the parity
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
