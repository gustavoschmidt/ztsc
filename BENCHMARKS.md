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

@types/node        ztsc ███ 19
                   tsgo ████████████████████ 102
@types/react       ztsc █████ 27
                   tsgo ████████████████████████████████████ 184
drizzle-orm        ztsc █████ 24
                   tsgo ██████████████████████████████████████████████████████ 274
hono               ztsc ██████ 31
                   tsgo ██████████████████████████████ 153
@sinclair/typebox  ztsc ███ 17
                   tsgo ███████████████ 78
ajv                ztsc ██ 12
                   tsgo ██████████ 50
zod                ztsc █████ 25
                   tsgo ███████████████████████████ 135
chalk              ztsc █ 7
                   tsgo █████████ 43
```

At the default, ztsc's peak memory is **8–24% of tsgo's**. The full matrix over
`--checkers` ∈ {1, 2, 4, 8} follows; each cell is `ztsc / tsgo`.

**Peak RSS (MB)**

| package (files / lines) | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 (59 / 49.6k) | 16.9 / 87.7 | 17.7 / 95.0 | **18.7 / 100.5** | 17.7 / 106.5 |
| @types/react 18.3.11 (4 / 4.8k) | 23.6 / 154.7 | 25.5 / 180.0 | **26.9 / 182.4** | 26.6 / 184.2 |
| drizzle-orm 0.33.0 (288 / 12.6k) | 21.1 / 166.0 | 22.0 / 233.4 | **23.7 / 280.1** | 23.2 / 402.7 |
| hono 4.6.3 (165 / 6.3k) | 26.5 / 143.8 | 29.6 / 146.1 | **31.2 / 153.2** | 32.7 / 165.0 |
| @sinclair/typebox 0.33.12 (241 / 3.1k) | 13.8 / 66.2 | 15.3 / 70.5 | **16.7 / 77.8** | 15.5 / 88.0 |
| ajv 8.17.1 (107 / 1.8k) | 10.0 / 45.5 | 10.6 / 46.6 | **12.0 / 49.9** | 12.0 / 52.2 |
| zod 3.23.8 (24 / 1.6k) | 21.5 / 119.0 | 23.2 / 132.3 | **25.1 / 135.2** | 26.7 / 137.8 |
| chalk 5.3.0 (5 / 612) | 6.8 / 39.1 | 6.9 / 40.5 | **7.4 / 43.2** | 7.5 / 46.0 |

**Wall clock (seconds)** — coarse `/usr/bin/time` resolution; the
millisecond-precision re-measure below is the honest read for the small packages

| package | N=1 | N=2 | **N=4** | N=8 |
|---|---|---|---|---|
| @types/node 22.7.4 | 0.02 / 0.07 | 0.02 / 0.05 | **0.01 / 0.04** | 0.01 / 0.04 |
| @types/react 18.3.11 | 0.03 / 0.24 | 0.03 / 0.24 | **0.02 / 0.24** | 0.02 / 0.17 |
| drizzle-orm 0.33.0 | 0.03 / 0.28 | 0.02 / 0.24 | **0.02 / 0.23** | 0.02 / 0.26 |
| hono 4.6.3 | 0.04 / 0.19 | 0.03 / 0.18 | **0.03 / 0.17** | 0.02 / 0.13 |
| @sinclair/typebox 0.33.12 | 0.01 / 0.06 | 0.01 / 0.05 | **0.01 / 0.04** | 0.01 / 0.04 |
| ajv 8.17.1 | 0.01 / 0.03 | 0.01 / 0.02 | **0.00 / 0.02** | 0.00 / 0.02 |
| zod 3.23.8 | 0.03 / 0.16 | 0.03 / 0.15 | **0.02 / 0.15** | 0.02 / 0.12 |
| chalk 5.3.0 | 0.00 / 0.02 | 0.00 / 0.01 | **0.00 / 0.01** | 0.00 / 0.01 |

Peak memory grows with the checker count on both tools — steeply on tsgo
(drizzle-orm climbs 166 → 403 MB from N=1 to N=8), flatly on ztsc (21 → 23 MB).
ztsc's entire N=1→N=8 range stays below tsgo's leanest single-checker run on
every package.

### Wall clock at millisecond precision (re-measured at HEAD, 2026-07-16)

`/usr/bin/time`'s 10 ms resolution makes the small-package ratios above mostly
rounding. Re-measured with a monotonic nanosecond timer around the whole
process (median of 11 runs after one warm-up, defaults, same corpus; RSS
median of 5 runs re-taken in the same session — HEAD includes CommonJS
interop, the 7.0.2 lib now sharded into 12 blobs, and the DOM lib that hono,
zod, and `@types/react` pull in via their tsconfig `dom` setting):

| package | wall ztsc / tsgo | wall vs tsgo | peak RSS ztsc / tsgo | rss vs tsgo |
|---|---:|---:|---:|---:|
| @types/node 22.7.4 | 19.0 / 44.9 ms | 42% | 18.8 / 102.4 MB | 18% |
| @types/react 18.3.11 | 26.7 / 241.4 ms | 11% | 26.8 / 183.5 MB | 15% |
| drizzle-orm 0.33.0 | 23.9 / 248.8 ms | 10% | 23.7 / 273.8 MB | 9% |
| hono 4.6.3 | 31.0 / 172.3 ms | 18% | 31.2 / 155.8 MB | 20% |
| @sinclair/typebox 0.33.12 | 16.3 / 47.7 ms | 34% | 16.7 / 78.1 MB | 21% |
| ajv 8.17.1 | 10.2 / 23.5 ms | 43% | 11.6 / 49.8 MB | 23% |
| zod 3.23.8 | 26.7 / 153.6 ms | 17% | 25.1 / 136.9 MB | 18% |
| chalk 5.3.0 | 7.5 / 18.2 ms | 41% | 7.4 / 43.7 MB | 17% |

The highest ratios are the smallest *esnext-only* packages (ajv 43%, chalk 41%)
and @types/node (42%): at that size both tools sit near their process floors
(ztsc ~8 ms — startup plus type-checking the embedded 14k-line lib; tsgo
~18 ms), so the ratio reflects fixed startup cost, not checking throughput.
Because ztsc now type-checks its embedded lib at the default like tsgo does,
that fixed floor is a little higher than it would be with `--skip-default-lib-check`,
which is why the two smallest packages land where they do. hono and zod land
higher than their size alone suggests (18% / 17% wall, 20% / 18% RSS) because
their tsconfig lists `dom`: ztsc parses, binds, and checks the 2.35 MB DOM lib
for them too, a sizable front end on top. On every package above ~3k lines ztsc
is 2.4–10× faster; @types/node, the largest, sits at the low end (42% wall)
because its dense declaration merging and interface heritage is the work ztsc
closes least of the gap on. `@types/react` is the corpus's heaviest row for
tsgo — its deep conditional types and the DOM-derived `DetailedHTMLProps`
intrinsic-element unions cost tsgo 241 ms — more wall time than any other
package — and 184 MB, yet ztsc checks the same surface in 27 ms and 27 MB
(11% wall, 15% RSS), a 9× speedup at one-seventh the memory.

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

**Defaults.** Both tools are measured at their defaults. ztsc type-checks its
embedded default lib (like tsc/tsgo), so this is a like-for-like comparison;
`--skip-default-lib-check` (tsc's `skipDefaultLibCheck`) turns ztsc's lib check
off, saving a few ms and a few MB with byte-identical diagnostics.

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
