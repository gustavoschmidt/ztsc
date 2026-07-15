# ZTSC — Benchmark Report

How a data-oriented, arena-allocated, parallel checker written in Zig compares
against `tsc` 5.5.4 and `tsgo` (TypeScript 7, the native compiler) on **real,
published TypeScript packages** — measured 2026-07-15 on the ReleaseFast binary
at HEAD.

The project's headline goal is **memory**: peak RSS ≤ 50% of tsgo on the same
workload, with speed within the same order (wall ≤ 1.25× tsgo). On the real
`.d.ts` packages below, ztsc's peak RSS lands at **5–20% of tsgo** and its wall
clock at a fraction of tsgo's — both gates pass with wide margin (§4).

Headline, `@types/node` 22.7.4 (59 files / ~50k lines of declarations),
each tool in its **default** configuration:

| | wall (median) | peak RSS | RSS vs tsgo |
|---|---:|---:|---:|
| **ztsc** (`--checkers=4`, its default) | **0.01 s** | **17.0 MB** | **17%** |
| tsgo 7.0.2 (default, `--checkers 4`) | 0.04 s | 102.6 MB | 100% |
| tsc 5.5.4 (single-threaded) | 0.46 s | 189.4 MB | 185% |

ztsc checks a **subset** of TypeScript and ships an esnext-only lib, so on real
code the three tools do not report identical diagnostics — this is a
throughput-and-memory comparison on identical inputs, not a diagnostic-parity
claim (that is what the conformance suite measures, §3). The per-tool
diagnostic counts and their causes are given honestly in §2.4.

---

## 1. Methodology

**Hardware / OS.** Apple M4 (10 cores: 4P + 6E), 32 GB RAM, macOS 26.5.1.

**Versions.**

| tool | version | how it runs |
|---|---|---|
| ztsc | 0.0.1, `zig build bench` (ReleaseFast), Zig 0.16.0 | native binary |
| tsc | 5.5.4 | Node 22.12.0 (`node .../bin/tsc`) |
| tsgo | 7.0.2 | native arm64 binary (`@typescript/typescript-darwin-arm64/lib/tsc`, invoked directly — no Node wrapper in the measurement) |

tsgo is the native TypeScript compiler that TS 7 stable ships inside the
`typescript` package as a per-platform binary; `bench/e2e.sh` and the
real-project runs invoke that binary directly so RSS is the real process, not a
Node host.

**Real-project corpora.** `bench/fetch_real.sh` vendors a pinned set of
popular packages' published `.d.ts` via `npm pack` (deterministic at the pinned
versions; gitignored like all corpora, regenerate with the script). It also
writes a benchmark `tsconfig.json` into each measured package so all three
checkers run on **identical inputs** through `-p <dir>` (`--noEmit`, `strict`).
`lib` is set to the minimal set that keeps tsc/tsgo clean — DOM only where the
package references browser globals; `@types/node` uses its own `index.d.ts`
entry (a `**/*.d.ts` glob would pull its `ts5.x` alternate-version directories
and collide) and esnext-only (DOM's globals clash with `@types/node`'s). ztsc
ignores the `lib` field and always loads its embedded lib (below).

**The lib.** ztsc embeds the **real TypeScript 5.5.4 `lib.esnext` reference
chain** (71 `lib.*.d.ts`, ES core through esnext; DOM / webworker / scripthost
excluded; ~527 KB / 12,171 lines; `--census`-clean) and loads it by default —
materializing lib types lazily, so only the surface a program touches is ever
interned (see Appendix B, §3.13). tsc/tsgo load their full default libs. A
`--noLib` flag skips ztsc's lib entirely.

**Defaults-vs-defaults policy.** The headline and per-project tables compare
each tool **as its users run it by default**: ztsc at `--checkers=4` (its
default), tsgo at its default (empirically `--checkers 4` — the default run and
`--checkers 4` produce byte-identical wall/RSS, see §2.3), and tsc
single-threaded (it has no worker knob). N independent checker instances trade
duplicated type construction for lock-free parallelism; both ztsc and tsgo
default to 4, so defaults-vs-defaults is the honest like-for-like. A secondary
sweep (§2.3) varies `--checkers` on **both** ztsc and tsgo so the RSS-vs-wall
tradeoff is visible at every N, not just the default.

**Measurement.** One untimed warm-up run per configuration (also warms the FS
cache), then 5 timed runs under `/usr/bin/time -l`; tables report the **median
wall clock** and **max peak RSS** of the 5. `/usr/bin/time`'s wall resolution is
10 ms, so the fastest ztsc runs saturate the clock — peak RSS, the headline
metric, is unaffected. Real packages emit diagnostics (they are vendored
without their dependencies), so unlike the synthetic-corpus harness (`e2e.sh`,
which skips any tool that exits nonzero) the real-project measurement tolerates
nonzero exit; all three tools fully parse, bind, and check every input file
regardless of exit code (§2.4).

---

## 2. Real projects

### 2.1 Headline — `@types/node` (defaults-vs-defaults)

`@types/node` 22.7.4 is the backend gate: the declaration package almost every
Node project depends on, built on cross-file global/namespace merging. Checked
from its own `index.d.ts` entry (59 files / ~50k lines):

| | wall (median) | peak RSS | vs tsgo |
|---|---:|---:|---:|
| **ztsc** (`--checkers=4`) | **0.01 s** | **17.0 MB** | **17% RSS, ~0.25× wall** |
| tsgo 7.0.2 (default) | 0.04 s | 102.6 MB | 100% |
| tsc 5.5.4 | 0.46 s | 189.4 MB | 185% RSS, 11.5× wall |

ztsc holds the whole `@types/node` surface in **17 MB** — 6× less than tsgo,
11× less than tsc — and finishes in a fraction of the wall clock. Peak RSS is
**17% of tsgo**, well under the ≤50% gate.

### 2.2 Per-project spread

The memory win is systemic, not an artifact of one package. Each tool in its
default configuration, median of 5, max peak RSS, across a spread of package
styles (validators, a web framework, an ORM, the `@types` giants):

| project | files | lines | ztsc wall / RSS | tsgo wall / RSS | tsc wall / RSS | ztsc RSS vs tsgo |
|---|---:|---:|---|---|---|---:|
| `@types/node` 22.7.4 | 59 | ~50k | **0.01 s / 17.0 MB** | 0.04 s / 102.6 MB | 0.46 s / 189.4 MB | **17%** |
| `drizzle-orm` 0.33.0 | 287 | 12,648 | **0.02 s / 21.4 MB** | 0.23 s / 277.5 MB | 1.07 s / 315.9 MB | **8%** |
| `hono` 4.6.3 | 164 | 6,281 | **0.01 s / 14.2 MB** | 0.17 s / 157.9 MB | 0.63 s / 237.9 MB | **9%** |
| `@sinclair/typebox` 0.33.12 | 240 | 3,146 | **0.01 s / 14.7 MB** | 0.04 s / 79.3 MB | 0.46 s / 172.3 MB | **19%** |
| `ajv` 8.17.1 | 106 | 1,783 | **0.01 s / 10.0 MB** | 0.02 s / 50.1 MB | 0.27 s / 139.9 MB | **20%** |
| `zod` 3.23.8 | 23 | 1,556 | **0.00 s / 7.7 MB** | 0.14 s / 141.9 MB | 0.56 s / 211.1 MB | **5%** |
| `chalk` 5.3.0 | 4 | 612 | **0.00 s / 5.9 MB** | 0.02 s / 44.3 MB | 0.20 s / 119.2 MB | **13%** |

Across the spread ztsc's peak RSS is **5–20% of tsgo** and **3–9% of tsc**, and
its wall clock is a fraction of both. tsgo's RSS climbs steeply with corpus
size (44 → 277 MB); ztsc's stays lean (6 → 21 MB) — the arena / no-GC /
struct-of-arrays payoff the project was built for.

### 2.3 Worker-count sweep — ztsc and tsgo, like-for-like

`--checkers=N` on both tools, on the `@types/node` headline corpus. This is the
same knob with the same semantics on each: N checker instances duplicate some
type construction to gain lock-free parallelism, so wall falls and RSS rises
with N. tsgo's default is confirmed here: its default run equals `--checkers 4`.

| N | ztsc wall | ztsc peak RSS | tsgo wall | tsgo peak RSS |
|---:|---:|---:|---:|---:|
| 1 | 0.02 s | 15.5 MB | 0.07 s | 88.9 MB |
| 2 | 0.01 s | 16.1 MB | 0.05 s | 95.2 MB |
| **4** (default) | 0.01 s | 17.0 MB | 0.04 s | 103.2 MB |
| 8 | 0.01 s | 17.2 MB | 0.04 s | 110.2 MB |

At every N ztsc's peak RSS is **16–18% of tsgo's**. Both tools trade RSS for
wall as N grows, but from wildly different absolute floors: ztsc's entire
N=1→N=8 RSS span (15.5 → 17.2 MB) sits below tsgo's *leanest* single-checker
run (88.9 MB). tsgo's default (`--checkers 4`) and its explicit `--checkers 4`
are byte-identical in wall and RSS, confirming 4 is its default. (tsgo also
offers `--singleThreaded`, which on this corpus runs 0.08 s / 89.5 MB — slower
than `--checkers 1` but at similar RSS.)

### 2.4 Diagnostic parity — the honest picture

These packages are vendored **without their dependencies**, and ztsc checks a
**subset** of TypeScript with an **esnext-only lib**, so the three tools do not
report identical diagnostics. The timing above is a fair *throughput and
memory* comparison — all three fully parse, bind, and check every input file
(ztsc reports full-pipeline completion and totality: zero crashes on any real
package) — but it is **not** a correctness-parity claim. Correctness parity is
measured separately and rigorously by the differential conformance suite (§3).

Per-tool diagnostic counts on each corpus:

| project | ztsc | tsgo | tsc | why they differ |
|---|---:|---:|---:|---|
| `chalk` | 1 | 1 | 1 | all three report the *same* single error (missing `@types/node` for `node:tty`) — exact agreement where the code stays in ztsc's subset+lib |
| `ajv` | 11 | 5 | 5 | 5 shared missing-module errors; ztsc adds 6 subset/lib notes |
| `zod` | 39 | 8 | 8 | 8 shared (`benchmark` dev-dep absent in bundled benchmark stubs); ztsc adds ~31 (`export as namespace`, a few complex-type gaps) |
| `@sinclair/typebox` | 28 | 0 | 0 | tsc/tsgo clean; ztsc's 28 are the const-symbol computed-key family (`[Kind]`) it consciously leaves out of subset |
| `hono` | 349 | 0 | 0 | tsc/tsgo clean; **~95% of ztsc's are DOM globals** (`Response`, `Request`, `Event`, `HTMLElement`, `FormData`, …) absent from its esnext-only lib — a web framework leans on DOM types ztsc doesn't ship |
| `drizzle-orm` | 177 | 83 | 83 | 83 shared (absent peer/dev deps); ztsc adds subset notes |
| `@types/node` | 554 | 19 | 32 | tsgo: 19 from the absent optional `undici-types` dep; tsc 5.5.4: 32 (lib version skew — `@types/node` 22.7.4 expects TS 5.6+ generic TypedArrays); ztsc: 554 subset + esnext-only-lib + skew notes |

The pattern: tsc/tsgo diagnostics come from **absent dependencies** (vendored
`.d.ts` reference `undici-types`, `benchmark`, `csstype`, …) and **lib version
skew**; ztsc's *additional* diagnostics come from its **esnext-only lib** (no
DOM globals) and its **checked subset** (CommonJS `export =`, const-symbol
computed keys, and a few type-level edge cases are out of scope for v0.0.1 — see
the README's subset & limitations section). Every one is a "note," not a crash:
ztsc reaches the end of every file. `chalk` (1/1/1) is the control — where real
code stays inside ztsc's subset and esnext lib, all three agree exactly.

---

## 3. Correctness cross-check

Diagnostic *correctness* is measured by the differential conformance suite, not
by the real-project throughput runs above. The **388-case** conformance suite
(code + line differential vs tsc 5.5.4, including 51 multi-file cases) is green,
and `gen_expected.js --check` confirms every snapshot still matches real tsc
output. Unit tests: 248 module tests + 5 CLI tests, all green (`zig build test`
reports 256/256 across the three test binaries, including the 3-test conformance
runner); determinism (diagnostics byte-identical for N ∈ {1,2,4,8}) and
cycle-stress harness tests pass.

On the synthetic corpora (Appendix A), all three tools additionally agree on
**zero** diagnostics — those corpora are deliberately lib-free and in-subset so
the timing isolates checker work from any diagnostic divergence.

---

## 4. Acceptance gate (honest evaluation)

The gate: *wall clock within 1.25× of tsgo and peak RSS ≤ 50% of tsgo, on the
same workload; conformance suite green.* Evaluated on the real-project numbers:

| corpus | wall vs tsgo (≤ 1.25×) | RSS vs tsgo (≤ 50%) | verdict |
|---|---|---|---|
| `@types/node` | 0.01 s vs 0.04 s ≈ **0.25×** | 17.0 / 102.6 MB ≈ **17%** | **pass** |
| `drizzle-orm` | 0.02 s vs 0.23 s ≈ **0.09×** | 21.4 / 277.5 MB ≈ **8%** | **pass** |
| `hono` | 0.01 s vs 0.17 s ≈ **0.06×** | 14.2 / 157.9 MB ≈ **9%** | **pass** |
| `zod` | ≈ 0× (both sub-resolution) vs 0.14 s | 7.7 / 141.9 MB ≈ **5%** | **pass** |

Both gates pass with wide margin on every real package measured: peak RSS is
**5–20% of tsgo** (target ≤ 50%), and wall clock is a fraction of tsgo's. The
synthetic-corpus gate (Appendix A) passes identically. Conformance:
**388/388** vs tsc 5.5.4 — green.

Honesty notes:

- These are **throughput + memory** numbers on real published declarations, not
  a diagnostic-parity claim — see §2.4 and §3. All three tools fully check every
  input file; they disagree on *how many* diagnostics because ztsc is a subset
  checker with an esnext-only lib and the packages are vendored without deps.
- Wall-clock ratios at these speeds sit near `/usr/bin/time`'s 10 ms resolution
  on the smaller corpora; the honest claim is "ztsc completes in a fraction of
  tsgo's wall time," not a precise multiple. Peak RSS, the headline metric, is
  measured well above resolution.
- The plan's ~500k-LOC "large" real snapshot was never assembled — real code
  that stays fully inside the v0.0.1 subset is rare — so the largest single real
  datapoint is `@types/node` (~50k lines). The large-corpus evaluation carries
  to the next release.

---

## 5. Caveats — what these numbers do and don't say

This is a **fair-for-the-subset** comparison, not a general claim that ztsc is
faster than tsc or tsgo on all TypeScript:

- **ztsc checks a subset** (see the README's subset & limitations section). It
  has grown wide — enums, accessors, `abstract`, `as const`/`satisfies`, type
  guards, namespaces + cross-file declaration merging, async/await, `import()`
  types, `unique symbol`, decorators, JSX, and the type-level surface
  (conditional, mapped, and template-literal types with `infer` and recursive
  aliases). What remains out for v0.0.1 is narrower: CommonJS `export =` /
  `import = require`, const-symbol computed property keys, and some
  index-signature assignability edge cases. Real code that uses those gets
  "unsupported syntax" notes (§2.4), not a crash.
- **esnext-only lib.** ztsc embeds the real TS 5.5.4 `lib.esnext` chain but
  **not** DOM / webworker / scripthost. Packages that reference browser globals
  (a web framework like `hono`) get "cannot find name" notes for those types
  (§2.4). tsc/tsgo load their full default libs including DOM.
- **The real corpora are published `.d.ts`** — declaration surface, not
  full-program inference over `.ts` bodies. They are the honest "features your
  dependencies choose for you," but a `.d.ts` payload exercises less expression
  inference than an application's own source.
- tsc runs on Node (JIT warm-up and GC headroom are part of its numbers; that
  *is* how users run it, so it is reported as such).
- Single machine, single OS. No Linux numbers yet.

---

## 6. Reproducing

```sh
zig build test                         # unit + conformance (needs tsc for regen only)

# Real projects (§2): fetch pinned .d.ts + write the benchmark tsconfigs,
# then check any package with all three tools (they read the same -p tsconfig):
bench/fetch_real.sh
export ASDF_NODEJS_VERSION=22.12.0     # asdf-managed Node for the tsc baseline
BIN=zig-out/bench/ztsc
TSC=bench/baselines/tsc/node_modules/typescript/bin/tsc
TSGO=bench/baselines/tsgo/node_modules/@typescript/typescript-darwin-arm64/lib/tsc
C=bench/corpus/real/_types_node_22.7.4
"$BIN" --pretty=false --checkers=4 -p "$C"   # ztsc default
"$TSGO" -p "$C"                              # tsgo default (== --checkers 4)
"$TSGO" --checkers 1 -p "$C"                 # tsgo sweep (NOTE: space form, not =N)
node "$TSC" -p "$C"                          # tsc 5.5.4

# Wall + peak RSS: wrap any of the above in /usr/bin/time -l (macOS) and take
# the median wall / max RSS of 5 runs after one warm-up. Peak RSS is the
# "maximum resident set size" line (bytes).

# Synthetic corpora (Appendix A), clean-corpus harness:
node bench/gen_corpus.js               # regenerate corpora (deterministic)
RUNS=5 bench/e2e.sh medium
RUNS=5 bench/e2e.sh multi
zig-out/bench/ztsc --timing --memory --pretty=false -p bench/corpus/multi
```

`bench/e2e.sh` uses the pinned baselines under `bench/baselines/` (npm-installed
on demand, `node_modules` gitignored): tsc 5.5.4 run via node, and the native
TypeScript binary (tsgo) invoked directly — no Node wrapper — so RSS is the real
process. Override with `TSC=/path/to/typescript/bin/tsc` /
`TSGO=/path/to/native/tsc`. Note `e2e.sh` is built for the *clean* synthetic
corpora (it skips any tool that exits nonzero); the real packages emit
diagnostics, so measure those with the manual `/usr/bin/time -l` commands above.

---

# Appendix A — Synthetic corpora (methodology / regression infrastructure)

The synthetic corpora predate the real-project set and remain the project's
**regression infrastructure**: deterministic, lib-free, fully in-subset
projects where all three tools report **zero** diagnostics, so the timing
isolates raw checker throughput and the per-phase / per-structure instrumentation
(below) is stable run-to-run. They are generated by `bench/gen_corpus.js`
(seeded LCG; regenerate with `node bench/gen_corpus.js`).

| corpus | files | lines | shape |
|---|---:|---:|---|
| small | 10 | 5,520 | flat modules |
| medium | 50 | 49,600 | flat modules, `include`-driven tsconfig |
| multi | 201 | 93,364 | 5-layer cross-import graph, discovered from a single `entry.ts` via `files` |
| skewed | 210 | ~69,000 | one 22k-line file among many small (partition/discovery stress, §3.8) |
| bigfan | 205 | ~68,000 | four large files among many small (check-partition stress, §3.8) |
| deps | 73 | ~15,000 | 60 app files importing shared packages by bare specifier (resolution stress, §3.11) |
| generics | 32 | — | generic-instantiation stress |

All three tools check each project through its `tsconfig.json` (`-p
bench/corpus/<name>`, `--noEmit` semantics) and report zero diagnostics
(cross-checked before measuring). ztsc runs in its default mode (embedded lib
loaded); tsc/tsgo load their full default libs.

## A.1 End-to-end: wall clock + peak RSS (re-measured 2026-07-15)

ztsc rows use the default `--checkers=4`. Medians of 5 runs, max RSS.

| corpus | tool | wall | peak RSS | vs tsgo |
|---|---|---:|---:|---:|
| multi (93k lines) | **ztsc** | **0.03 s** | **54.3 MB** | 27% |
| | tsgo 7.0.2 (default) | 0.08 s | 203.1 MB | 100% |
| | tsc 5.5.4 | 0.92 s | 316.9 MB | 156% |

The multi headline (ztsc ~0.03 s / ~54 MB vs tsgo ~0.08 s / ~203 MB vs tsc
~0.92 s / ~317 MB) is stable across the real-lib milestones (§3.13). The medium/
small rows and the historical progression are recorded in §A.2 below and in the
milestone deltas (Appendix B). Peak RSS at N=4 sits at ~27% of tsgo on multi —
the synthetic gate, like the real-project gate (§4), passes comfortably.

## A.2 ztsc per-phase, scaling, and memory detail

The instrumentation below is what the synthetic corpora exist to keep honest;
the section numbers (§3.1–§3.3) are retained from the report's original
structure so the milestone-history cross-references (Appendix B) stay valid.

### 3.1 Per-phase timing (multi corpus, `--checkers=4`, warm `--timing` run)

Per-phase ms are **aggregate time-in-phase summed across the 10-worker pool**,
so the front-end phases (which run concurrently, overlapping `discover`) sum to
more than the `total` wall — `total` is the real end-to-end wall clock:

| phase | ms | lines/s | MB/s |
|---|---:|---:|---:|
| load | 7.11 | 13.2 M | 315 |
| scan | 8.24 | 11.4 M | 272 |
| parse | 23.87 | 3.9 M | 94 |
| bind | 31.84 | 2.9 M | 70 |
| resolve | 1.23 | — | — |
| discover | 7.58 | 12.4 M | 296 |
| link | 1.01 | — | — |
| check | 20.47 | 4.6 M | 110 |
| **total (wall)** | **29.3** | | |

Medium corpus, same shape: load 2.70 / scan 4.80 / parse 10.98 / bind 13.33 /
resolve 0.02 / discover 3.57 / link 0.43 / check 11.10, total 15.3 ms.

Check is the largest single phase (~20 ms of aggregate worker time, up from
14.7 ms at M11 as M14–M16 added conditional/mapped/template-literal evaluation);
the four checker instances finish within ~6% of each other (28.4–30.2 ms of
per-checker wall on the cold `--memory` run), so the greedy node-count partition
(§3.8) still balances this corpus well.

### 3.2 Checker scaling and the duplicated-type dial (`--checkers=N`)

N independent checker instances trade duplicated type construction for
lock-free parallelism. Both axes, re-measured 2026-07-14 (post-M16 type-level
work; check ms = min of 4 `--timing` runs, RSS = median of ≥5 `/usr/bin/time
-l` runs — RSS is scheduling-noisy at high N):

**multi (93k lines)**

| N | wall | check ms | types created | type-arena bytes | dup overhead vs N=1 | peak RSS |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.08 s | 69.4 | 21,539 | 611,180 | — | 49.7 MB |
| 2 | 0.05 s | 36.8 | 23,067 | 654,977 | +7.2% | 51.3 MB |
| 4 | 0.03 s | 20.5 | 24,848 | 703,660 | +15.1% | 53.9 MB |
| 8 | 0.02 s | 15.4 | 26,489 | 744,937 | +21.9% | 47.9 MB |

**medium (50k lines)**

| N | wall | check ms | types created | type-arena bytes | dup overhead vs N=1 | peak RSS |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.04 s | 38.4 | 12,276 | 345,633 | — | 27.4 MB |
| 2 | 0.02 s | 19.6 | 12,607 | 351,529 | +1.7% | 27.6 MB |
| 4 | 0.02 s | 11.0 | 13,037 | 359,337 | +4.0% | 26.3 MB |
| 8 | 0.01 s | 8.2 | 13,538 | 368,842 | +6.7% | 25.6 MB |

Check-phase speedup is near-linear to N=4 (3.4× on multi, 3.5× on medium) and
tapering at N=8 (4.5× / 4.7×); the *type*-duplication overhead still climbs to
+22% by N=8 but the type arena is <1 MB, noise against the ~50 MB process RSS.
Absolute check ms is up ~35% vs M11 (multi N=1 51.8→69.4) — that is the M14–M16
type-level machinery, and it parallelizes with the same near-linear shape. The
M12 right-sizing (§3.10) still holds: peak RSS does not grow monotonically with
N — N=4 is the high-water mark (four heavy concurrent working sets) while N=8,
whose eight checkers each own a smaller slice, sits back at the N=1 level. N=4
remains the default and the wall-clock sweet spot.

### 3.3 Memory metrics (multi corpus, N=4, `--memory`, lib-loaded, 2026-07-14)

The per-structure accounting behind the RSS number:

| metric | value | notes |
|---|---:|---|
| bytes/token | 5.00 | 1-byte tag + 4-byte start, SoA (M1 target: small) |
| bytes/AST node | 16.06 | SoA node + shared extra_data (M2 target ≤ 24) |
| binder bytes/line | 32.96 | symbols + scopes + flow graph + records |
| bytes/type | 28.32 | hash-consed, arena-allocated |
| types/line | 0.27 | interning working: 0.27 types per source line |
| relation cache hit rate | 47.0% | assignability memo on `TypeId` pairs |
| inst cache hit rate | 26.4% | generic-instantiation memo (M15) |
| node_types hit rate | 15.3% | contextual-keyed expression-type cache (M8) |
| **heap total (arenas)** | **17.8 MB** | **~190 bytes/line** (M6 was 45.5 MB / 508 — see §3.4) |

The M7 paydown (§3.4) roughly halved every arena-heap figure; the
per-structure *unit* costs (bytes/token, bytes/node, bytes/type) are
unchanged because they always measured live size — the win was stranded
capacity, not live data.

---

# Appendix B — Milestone history / measured deltas

The project's measured record, milestone by milestone. Section numbers
(§3.4–§3.16) and their internal cross-references are preserved from the report's
original structure. Each entry is the scoreboard evidence for one milestone; the
M6 baseline figures live in git history.

## 3.4 M7 — memory & perf debt paydown

Six independent fixes (M7): drop the duplicate retained token scan; parse into a
transient arena and seal exact-size into the retained AST arena (killing the
doubling-realloc slack that an arena strands forever); per-file reset scratch
arena for module resolution; `std.mem.sort` instead of insertion sort in the
linker; O(1) `upsertProp` + `std.mem.sort` for object triples; and removing
`resolveStem`'s 256-byte candidate-path cap (a latent wrong "module not found" —
regression-tested with a ~320-byte path).

Warm A/B on the same machine (Apple M4, ReleaseFast), `--timing --memory`,
`--checkers=4`. `heap total (arenas)` is deterministic; wall figures are the
usual ±5% noisy:

| corpus | metric | before (M6) | after (M7) | Δ |
|---|---|---:|---:|---:|
| medium | heap total (arenas) | 23.98 MB | 11.19 MB | **−53%** |
| | bytes/line (heap) | 505 | ~226 | −55% |
| | check ms | 15.3 | 7.1 | equal-or-better |
| multi | heap total (arenas) | 45.54 MB | 18.06 MB | **−60%** |
| | bytes/line (heap) | 490 | ~193 | −61% |
| | check ms | 17.2 | 13.6 | equal-or-better |

`bytes/node` (16.03 / 16.05) and `token arrays` are unchanged by design —
they already measured *live* size; the win is in the arena's actual resident
capacity, which the stranded doubling buffers and the duplicate token array
had been inflating. Check scratch high-water moved 1672 → 1996 B (still far
under the <2 KB budget). Conformance stays green (180/180) plus one new
long-path resolution unit test.

## 3.5 M8 — contextual re-check cache (correctness)

`node_types` (and, it turned out, `sig_cache`) memoized checked expression
types/signatures keyed on the node alone, dropping the *contextual* type —
first-check-wins. A node re-checked under a different contextual type
(overload argument trials are the live vector) returned the stale first
answer, producing a spurious **TS2769** where tsc reports none. Fixed by
adding a contextual-type discriminator (`{ty, ctx}` slot per node) to both
caches; two differential cases (`calls/021`, `calls/022`) that diverged from
tsc now pass. Sibling caches audited: `flow_cache` (key already carries
`declared`) and `da_cache` (pure `(flow, sym)`) are sound as-is.

`--memory` now reports a `node_types` hit rate alongside the relation-cache
one: medium 7.2%, multi 6.7% (inherently low — most nodes are checked once;
the discriminator only converts previously-*wrong* stale hits into correct
misses, so the check phase is unaffected). Check-phase time flat-to-better
(multi ~16.7 → ~13.3 ms across runs, within thermal noise); multi heap flat
(~17.16 MB), medium heap within run-to-run noise (the +4 B/entry `ctx` field
is swamped by arena page-rounding variance). Conformance 180 → **182**.

## 3.6 M10-lib-core — minimal default lib (usefulness unlock)

First slice of the merged M9/M10 phase: a hand-trimmed ES-core `lib.d.ts`
(`src/lib/es.core.d.ts`, embedded via `@embedFile`) with GLOBAL-scope
declarations, so code using `Array.prototype.map`, `String` methods,
`console`, `Math`, `JSON`, `Promise`, etc. now checks. New machinery: a
program-level global-symbol table (harvested from the lib file's top-level
scope after link), a fallback hook in `resolveSpace`, and a
primitive/array→interface bridge in `propOfType` (`.array`→`Array<elem>`,
`.string`→`String`, …) delegating through the existing generic-instantiation
path. Generic-method inference (`map<U>(cb:(x:T)=>U):U[]`) works. A
`--noLib` flag (matching tsc) skips injection entirely.

Differential note: the conformance harness now generates tsc snapshots with
`lib: ["lib.esnext.d.ts", "lib.dom.d.ts"]` (was esnext-only) — `console` is a
dom/host global, and this matches how tsc runs at `target: esnext` by
default. All 182 pre-existing snapshots still match tsc byte-for-byte;
8 new lib cases added. Conformance **182 → 190**.

Perf: the `--noLib` path is byte-for-byte the old non-lib path — medium/multi
land in the same heap buckets (11.2 / 17.2 MB) at the same check time
(7 / 13 ms) as M8. Loading the lib via source costs ~15–20 KB heap and
sub-millisecond front-end time (one 132-line file: +947 tokens, +494 nodes,
+84 checker types) — swamped by run-to-run scheduling variance and slated to
vanish once M9.2 embeds the pre-parsed blob.

## 3.7 M10-lib-grow — real ES-core surface

Grew `src/lib/es.core.d.ts` (127 → 220 lines) to the common ES-core surface
that stays in-subset: constructor-side globals (`Object.keys/values/entries`,
`Array.isArray/of`, `Number.isInteger/parseInt/…`, `String.fromCharCode`,
`Promise.resolve/reject/all`), more `Array`/`String` instance methods, and
`Map<K,V>`/`Set<T>`/`Date` as `declare class` (construct signatures on a
`var` are out of subset; `declare class` gives a working `new`). Found and
fixed a real bug: merged value+type globals (`interface Object {}` +
`declare var Object: {…}`) resolved the *value* to `any`, silently passing
negative cases — `computeTypeOfSymbol` now skips non-declarator decls.
Conformance **190 → 200** (10 new lib cases), differential clean vs tsc.
`--noLib` path flat (medium 11.2 MB / 7 ms, multi 17.2 MB / 13 ms);
lib-loaded front-end +~0.4 ms for the bigger file (M9.2 will absorb it).

Documented in-subset gaps that now gate real-world fidelity (feed M11/M13):
index-signature inference (`Array.from`), intersection/mapped-type returns
(`Object.assign`/`freeze`), construct signatures on object types, `this`
return types, and the `Symbol.iterator` iteration protocol (`for…of` over
Map/Set, spread).

## 3.8 M10-partition — cost-based check partition

Round-robin `owned_lists[i % n_checkers]` ignored file size, so a large file
(or several, when their ids share a residue mod N) piled onto one checker
while the rest idled. Replaced with a **greedy longest-processing-time
partition by per-file AST node count** (node count ≈ check cost, known after
parse): sort files by node count descending, assign each to the
least-loaded checker; ties break by file id / lowest checker index, so it
stays fully deterministic. Diagnostics remain byte-identical for any
`--checkers=N` (the reassembly loop's `i % n_checkers` owner lookup, a second
coupling to round-robin, now reads an explicit `file_owner` map).

Measured, `--checkers=4 --noLib`, greedy vs round-robin:

| corpus | round-robin check | greedy check | note |
|---|---:|---:|---|
| skewed (1× 22k-line file) | 75.0 ms | **55.8 ms** (−26%) | huge file ends up alone; floor is that one file |
| bigfan (4× ~5.8k-line files) | 26.6 ms | **11.0 ms** (−59%, 2.4×) | RR clumps all 4 bigs (ids ≡1 mod 4) onto one checker; greedy spreads one-per-checker |
| medium / multi (uniform) | 13.5 / 16.4 ms | 11.3 / 15.6 ms | identical file distribution — no regression |

`bigfan` is a new generated corpus (205 files / ~68k LOC: four large files
among many small, arranged so round-robin provably clumps them);
regenerate with `node bench/gen_corpus.js`. The partition adds one sort of
N integers on the front-end path — invisible on the uniform corpora.

## 3.9 M11 — node-shaped acceptance fixture (first `.d.ts`-heavy datapoint)

The M11 acceptance test ("the milestone's whole point") is a standing
conformance fixture at `test/conformance/node_accept/backend/`: a mini
`@types/node` (a `declare global` + `namespace NodeJS` surface split across
`globals.d.ts`/`process.d.ts`/`timers.d.ts`, ambient `declare module
"fs"`/`"timers"`, a global `Buffer` value+type merge, chained by triple-slash
`/// <reference path>` from `index.d.ts` and pulled in by `/// <reference
types="node" />`), an `Express.Request`-style app-side `declare global`
augmentation, and a backend `entry.ts` exercising `process.env`, `Buffer`,
`fs`, and timer return types. Every "good" line type-checks clean; the four
planted mistakes match tsc exactly (`TS2322`×3 + `TS2339`). Unlike the
synthetic corpora this fixture is deliberately **not** lib-free — the whole
point is the cross-file global/namespace merge that real `@types/*` packages
are built on.

Measured 2026-07-13 (ReleaseFast, `--pretty=false`, median of 3; peak RSS via
`/usr/bin/time -l`), checking `entry.ts` and everything it pulls in
(10 files, 412 lines):

| | wall | peak RSS | diagnostics |
|---|---:|---:|---|
| **ztsc** | **~0.01 s** | **~7.0 MB** | 4 (match) |
| tsc 5.5.4 | ~0.38 s | ~182 MB | 4 |

Diagnostics are byte-identical for `--checkers` ∈ {1, 4, 8} (determinism
holds through the merge layer). The RSS gap is inflated on tsc's side — tsc
loads the full real `lib.esnext`+`lib.dom` where ztsc loads only its trimmed
embedded ES-core lib — so read this as a "check this program end-to-end"
datapoint, not a like-for-like lib comparison; the honest lib-size story is
M12's job. It is recorded here as the first realistic `.d.ts`-heavy input and
feeds M12's gates. tsgo is omitted (it would need the same case-local
`@types` setup; added when M12's `@types/node`-scale corpus lands).

The merge machinery this fixture stressed surfaced one real gap, now fixed: a
merged global name (`NodeJS`, `Buffer`) referenced from *inside* a
contributing file bound to the file-local declaration and bypassed the merged
member index (so `var process: NodeJS.Process` saw only one file's `Process`
members). The linker now emits a constituent→merged reverse index
(`Program.mergedOf`) that `resolveSpace` consults — pay-per-use, empty when no
name is merged.

## 3.10 M12 — deterministic atoms + per-checker right-sizing

M12's substrate is split: M12.1 (deterministic lib atoms) and the per-checker
whole-program-state right-sizing land now; the two lib-gated pieces — the
pre-parsed embedded lib blob and the shared frozen-base/overlay type store —
are **rescheduled to a slot between M14 and M15**, because their payoff only
materializes with a realistic large lib / `@types/node` (see §3.2: the
type-duplication overhead is <1 MB on today's trimmed 9 KB lib, so a shared
store would be unmeasurable now).

**M12.1 — deterministic atoms.** `modules.seedLibAtoms` interns every string
the lib front end produces, single-threaded, before the worker pool starts, so
the worker that binds file 0 re-interns them into stable run-to-run atoms.
Zero wall/RSS change (the seed is a sub-ms parse+bind of a 9 KB file). This is
the prerequisite for the deferred blob (a serialized lib must reference stable
atoms).

**Right-sizing.** Each of the N checker instances previously (a) `@memset` a
`symbolSpace()`-wide `sym_types`/`sym_state` pair up front and (b) eagerly
mapped *every* scope of *every* file into its own `node_scopes`. Both are now
paid per working-set: the symbol arrays are now a `ZeroPagedArray`
(`src/zeropage.zig`) — a fixed-length array over a private `MAP_ANONYMOUS`
mapping, the one source where the kernel's zero-fill is a *documented*
guarantee — with the eager memset dropped, so untouched entries are demand-zero
(no residency) and the `.not_computed`/`0` initial state can't be an allocator
accident; `node_scopes` is faulted per file on first `scopeOf` read, so a
checker only maps files it actually traverses.

Multi corpus (201 files / 93k lines, ReleaseFast, peak RSS via `/usr/bin/time
-l`); diagnostics verified **byte-identical for N ∈ {1,2,4,8}** (raw order, on a
diagnostic-producing variant — the synthetic corpus itself is clean):

RSS values are medians of ≥5 runs (high-N RSS is scheduling-noisy — the N=8
"after" spread across 10 runs was 44.2–51.2 MB):

| N | peak RSS before | peak RSS after | wall (unchanged) |
|---:|---:|---:|---:|
| 1 | 48.5 MB | 48.3 MB | 0.06 s |
| 2 | 50.0 MB | 49.9 MB | 0.04 s |
| 4 | 52.5 MB | 52.4 MB | 0.03 s |
| 8 | 50.5 MB | **48.1 MB** | 0.02 s |

The win concentrates at high N — more checkers means more avoided
`symbolSpace()` memsets — which is the intended shape: before M12, peak RSS
grew monotonically with N (N=8 ≈ 50.5 MB); after, N=8 drops back to ≈ the N=1
level (~48 MB), so the high-water mark moves to N=4. At low N the front-end
arenas dominate RSS and the delta is within run-to-run noise. Wall clock is
unchanged (no hot-path structure change; `scopeOf` gained one predictable
per-file branch). The absolute saving is small here because the lib is tiny —
it scales with program symbol count, and the *type*-duplication half of the
memory story waits on the deferred frozen store + a realistic lib.

**Gate smoke-test (node-shaped fixture).** Ran the RSS gate against
`test/conformance/node_accept/backend/` (M11's mini-`@types/node`, 10 files /
412 lines): diagnostics byte-identical for N ∈ {1,2,4,8}; RSS 6.77 → 6.96 →
7.11 → 7.44 MB across N. RSS *grows* slightly with N here because the fixture
is too small for any per-checker duplication to dominate the fixed overhead —
so this confirms the measurement harness works but, as expected, does **not**
show the N× win. That win needs the full pinned `@types/node` corpus, which is
still deferred (post-M14); the deferred frozen store is what will cash it in.

## 3.11 M13 — module-resolution cache

A module specifier resolves as a pure function of `(importer_dir, spec)` given a
fixed filesystem, so the same bare specifier imported from K files re-walked
`node_modules` K times (a `package.json` read + up to four `statFile`s per
ancestor). `modules.ResolveCache` memoizes that pair over the discovery run —
including a negative cache for unresolvable specifiers — so each distinct
`(dir, spec)` walks the tree once. Resolution runs single-owner (main thread in
the parallel driver, sole thread in `buildProgram`), so the memo needs no locks;
`--no-resolve-cache` disables it for the "before" measurement.

Scoreboard: `fs_probes`, the count of resolution syscalls (`statFile` +
`package.json` reads), reported on `--timing`'s "resolve cache" line. New
**deps** corpus (`bench/gen_corpus.js`): 60 app files in one `src/`, each
importing 5 of 12 shared packages by bare specifier from a generated
`node_modules/` tree (73 files / ~15k lines). Measured 2026-07-13 (`--checkers=4`):

| corpus | probes (`--no-resolve-cache`) | probes (cached) | reduction | lookups / hits |
|---|---:|---:|---:|---:|
| deps | 2160 | **144** | **−93% (15×)** | 360 / 288 |
| multi | 520 | **200** | −62% | 520 / 320 |

On **deps** the 300 repeated bare imports collapse to 12 `node_modules` walks
(the 72 misses = 60 unique relative `entry→app` specs + 12 packages). **multi**
uses only relative imports yet still gains: sibling files importing the same
`../l{k-1}/f_NNN` share a `(dir, spec)` entry (320 hits / 520 lookups). Output is
byte-identical with the cache on vs off and for N ∈ {1,4,8}; conformance
**313/313**. No wall/RSS change (multi 0.02 s / ~51 MB, unchanged within noise;
deps 0.00 s / ~12 MB): the walk was never the dominant cost on these corpora —
the win is the syscall count itself, which matters most on the single-owner main
thread (it is also the discovery scheduler, so workers idle behind it) and scales
with `@types`-heavy real inputs. A `(dir, spec)`-existence layer for the residual
walk across *different* importer directories is a documented follow-up, gated on
M13's census showing resolution still dominates after this memo.

## 3.12 M13 — census over real `.d.ts` + real-world corpus

Each `.unsupported` AST node records which construct it covers (classified at
parse time, stored in the node's spare `lhs` slot — zero memory cost), so
`--census` is a whole-tree scan that tallies out-of-subset syntax by construct.
The point: a *frequency* table over real code decides M14/M16 order — spec order
is not priority order.

Real-world corpus: `bench/fetch_real.sh` vendors a pinned set of popular
packages' published `.d.ts` (`npm pack`, gitignored like all corpora) —
zod, hono, @types/node, @types/express, date-fns, chalk, @sinclair/typebox,
ajv: **1693 `.d.ts`, ~77k lines**. ztsc parses+binds+checks the lot in
**~0.03 s at ~53 MB RSS** (`--noLib --checkers=4`, median of 3), and totality
holds — thousands of "unsupported syntax" diagnostics, zero crashes.
(tsc/tsgo comparison pending their install here; the wall/RSS row lands with a
tsc/tsgo-present environment.)

Census over that corpus (2287 out-of-subset constructs; 449 of 1693 files carry
any — the file count is inflated by date-fns' ~1k locale stubs):

| construct | count | share | lands in |
|---|---:|---:|---|
| conditional type | 804 | 35.2% | M16a |
| import() type | 482 | 21.1% | M14 |
| infer | 331 | 14.5% | M16a |
| call/construct signature | 237 | 10.4% | subset expansion |
| mapped type | 160 | 7.0% | M16b |
| computed member name | 92 | 4.0% | — |
| constructor type | 54 | 2.4% | — |
| template-literal type | 32 | 1.4% | M16c |
| unique symbol | 30 | 1.3% | M14 |
| import = require | 24 | 1.0% | — |
| export = | 23 | 1.0% | — |
| named tuple member | 7 | 0.3% | subset expansion |

**Takeaways that steer the roadmap:** conditional types + `infer` together are
**~50%** of everything out-of-subset — M16a is unambiguously the highest-value
type-level milestone, exactly as the sequence assumed. **`import()` types (21%)
are the surprise** — far more common in published `.d.ts` than their M14 billing
suggested (packages lean on `typeof import("./x")` and `import("./y").T` to
avoid top-level imports in declarations); they deserve to lead M14. Mapped +
template-literal (M16b/c) are real but an order of magnitude rarer than
conditionals, confirming M16a-first. `unique symbol` (1.3%) stays low-priority as
the roadmap guessed. The census is now a standing tool: re-run
`bench/fetch_real.sh census` on any package set.

**Post-M14 update (2026-07-13):** `import()` types now check (M14), so they
dropped out of the census entirely — a re-run over the same corpus reports
**0** `import() type` constructs (total out-of-subset falls ~2287 → ~1795),
leaving **conditional type (44.8%) + infer (18.4%)** as the top pair and
confirming M16a as the next-highest-value target. Table above preserved as the
M13 snapshot. **Post-M18 refresh in §3.14** — after M14/M16/M18 landed, every
type-level and callable-object bucket in this table has zeroed; only CommonJS
interop and const-symbol computed keys remain.

## 3.13 M18.2 — the real lib vendored (before → after)

The embedded lib went from the hand-written **~9 KB** ES-core surface (M9) to
the **real TypeScript 5.5.4** `lib.esnext` reference chain — 71 `lib.*.d.ts`
files, ES core through esnext, DOM/webworker/scripthost excluded, plus a
minimal `console` shim: **~527 KB / 12,171 lines**. `--census` over the
embedded lib is **0 out-of-subset**. Startup now pays a real lib parse+bind,
and every checker re-expands the lib types it touches — the exact costs M19
exists to claw back. Measured on the multi corpus (median of 3, `bench/e2e.sh
multi`, ReleaseFast), before = M18.1 baseline (§3.2), after = M18.2:

| N | wall before→after | peak RSS before→after | types (N) before→after | type-bytes before→after |
|---:|---|---|---|---|
| 1 | 0.08 → 0.09 s | 49.7 → 52.1 MB (+4.8%) | 21,539 → 24,253 (+12.6%) | 611,180 → 706,606 (+15.6%) |
| 2 | 0.05 → 0.05 s | 51.3 → 53.4 MB (+4.1%) | 23,067 → 25,796 (+11.8%) | 654,977 → 750,914 (+14.6%) |
| 4 | 0.03 → 0.03 s | 53.9 → 54.3 MB (+0.7%) | 24,848 → 27,569 (+10.9%) | 703,660 → 799,205 (+13.6%) |
| 8 | 0.02 → 0.03 s | 47.9 → 48.2 MB (+0.6%) | 26,489 → 29,266 (+10.5%) | 744,937 → 842,922 (+13.2%) |

**The regression is far smaller than the roadmap feared, and is expected to
be — ztsc materializes lib types lazily, so only the esnext surface the corpus
actually touches (`Array`/`Map`/`Promise`/string methods) is ever interned;
the bulk (Intl, typed arrays, Atomics, WeakRef, …) never expands.** Peak RSS
rises **+2.4 MB at N=1** and is essentially flat at the default N=4 (+0.4 MB);
type population is **+11% at N=4**. Wall clock is within measurement noise (the
527 KB single-threaded lib parse+bind at startup adds ≈1 corpus-file's worth of
front-end). This is still ~27% of tsgo's RSS at N=4, so the headline gate
(≤50% of tsgo) holds comfortably on the real-lib configuration. The numbers are
recorded here per the M18 mandate, not optimized — M19 (frozen-base payload +
pre-parsed lib blob) is where the per-checker duplication and the cold-start
parse are reclaimed.

## 3.14 M18.5 — census refresh over the grown real corpus (release-readiness)

The M13 census (§3.12) was taken *before* the semantic breadth of M14/M16/M18
landed. Re-running `--census` after those milestones is the release-readiness
evidence: nearly every M13 bucket should have zeroed, leaving only consciously-
accepted constructs. The pinned set was also grown (77k → **~131k lines**) —
added `@types/react`, `rxjs`, `@types/lodash`, `drizzle-orm`, `@types/jest`,
`yup` alongside the original eight, since more package styles are checkable now
(ORM, reactive-streams, the big ecosystem `@types`). Corpus growth toward the
~500k-LOC target is best-effort and carried forward to M21; the refresh, not the
LOC number, is the point.

Census over the grown corpus (**2945 `.d.ts`, ~131k lines; 1249 out-of-subset
constructs, 946 files carry any**):

| construct | count | share | status |
|---|---:|---:|---|
| export = | 714 | 57.2% | **accepted** — CommonJS interop (@types/lodash is 689 of these; its entire API is `export = _`) |
| static block | 406 | 32.5% | **accepted** — classifier coarseness: 808 of these are drizzle-orm's `static readonly [entityKind]: T` (a *computed member name* on a static field, labelled "static block" from its leading `static` token). Same const-symbol-key family as `computed member name`. |
| computed member name | 85 | 6.8% | **accepted** — non-well-known computed keys (typebox `[Kind]`, `[ERR_ASSERTION]`, …); needs const-symbol key resolution |
| import = require | 43 | 3.4% | **accepted** — CommonJS interop |
| unknown/other | 1 | 0.1% | trivially rare |

**Buckets that zeroed since M13** (each now absent from the table): `conditional
type` (was 804), `import() type` (482), `infer` (331), `call/construct
signature` (237), `mapped type` (160), `constructor type` (54),
`template-literal type` (32), `unique symbol` (30), `named tuple member` (7).
That is the entire type-level + callable-object surface M16 and M18.1 targeted,
plus M14's `import()`/`unique symbol` — gone from real published `.d.ts`.

**What remains is release-ready.** Every surviving bucket is either CommonJS
interop consciously left out of subset for v0.0.1 (`export =` 57% + `import =
require` 3% = 60% of the residual, and the well-known-symbol subset of computed
keys already checks) or the const-symbol *computed property name* family
(`static block` mislabel + `computed member name` = ~39%), which needs symbol-
value resolution to know the key and is deferred post-v0.0.1. Nothing surprising
and no easy parser win was found: the "static block" spike is a *classifier
label* artifact of the same computed-key story, not a new construct. The
`export =` share is inflated by one package (@types/lodash) whose declaration
style is uniformly out of subset; excluding it the residual is dominated by
computed keys. Totality holds on the full grown corpus — thousands of
"unsupported syntax" diagnostics, zero crashes/panics.

## 3.15 M19.2 — frozen-base lib payload: implemented, verified, measured out

M19 piece 2 was to fill the M14.5 frozen-base architecture with its deferred
payload: pre-expand the whole lib/`@types` type population into the shared base
**once**, single-threaded, so N per-checker overlays share it instead of each
re-interning the lib. It was **built and fully verified**, then **reverted** —
the payload does not pay off. Implementation preserved at commit `46fc806`;
revert at `e810d9b`.

**Correctness (why it was safe to trust the negative result).** Conformance
388/388. A byte-identical oracle compared the payload build against the
pre-change HEAD binary across `--checkers ∈ {1,4,8}` × `--no-frozen-store`
{on,off} on multi, deps, and the real corpus: **16 of 17 projects were
byte-identical**. The lone diff was rxjs `ajax.ts:385` — the object-property
display-order instability §3.13's cohort already carries, **identical on HEAD**
(it permutes with any lib-id assignment; M19.1's structural union/intersection
sort meant relocating lib types to low base ids changed no message). So the
measurement below is of a *correct* implementation, not a broken one.

**Measurement (median of 3, ReleaseFast, `--memory` physical type-store bytes
= frozen base counted once + every overlay's own bytes; peak RSS via
`/usr/bin/time -l`; frozen-store ON = payload, OFF = `--no-frozen-store`):**

| corpus | N | phys type-bytes OFF → ON | Δ | peak RSS OFF → ON |
|---|---:|---|---:|---|
| multi | 1 | 706,606 → 709,073 | **+0.3%** | 52.4 → 52.4 MB |
| multi | 4 | 799,205 → 800,055 | **+0.1%** | 52.2 → 52.8 MB |
| multi | 8 | 842,922 → 841,910 | −0.1% | ~equal (±noise) |
| rxjs | 1 | 949,388 → 954,957 | +0.6% | 26.6 → 26.5 MB |
| rxjs | 4 | 1,343,299 → 1,281,841 | **−4.6%** | ~equal |
| rxjs | 8 | 1,616,091 → 1,504,234 | **−6.9%** | 30.5 → 28.6 MB (±noise) |

The frozen base holds only **~90 KB / ~2,500 types — the entire lib**. Each
per-checker overlay is **700 KB–1.4 MB**, dominated by *instantiations*
(`Array<string>`, `Promise<Foo>`, …) and user/import types, all per-checker and
impossible to pre-expand. So the shareable slice is tiny: rxjs saves ~7% of its
type store at N=8; **multi gets slightly *worse*** because eager expansion
interns the untouched lib tail (Intl, typed arrays, Atomics, WeakRef, …) that
lazy checking never materializes. Either way the type store is **~1.5 MB of a
~28 MB RSS**, so even a perfect trim is invisible in peak RSS. Wall clock is
unchanged (the 527 KB lib expansion is sub-ms).

**Why the premise didn't hold.** M19's rationale was that M18's real lib blows
up per-checker duplication and needs a claw-back to keep the ≤50%-of-tsgo gate.
But **§3.13 (M18.2) already retired that**: ztsc materializes lib types lazily,
so only the touched surface interns, and RSS sits at **~27% of tsgo — the gate
holds comfortably** without any payload. Pre-expanding the *whole* lib eagerly
actively fights that laziness (the multi regression). The claw-back has no
shortfall to claw back.

**Disposition.** M19.1 (display order) stays. M19.2 is shelved (recoverable in
history). M19.3 (pre-parsed lib blob) is now **gated on a cold-start
measurement** before any implementation — the base build is already sub-ms and
the interned lib surface is tiny, so the same data pattern may retire it too;
if the isolated lib parse/bind cost at startup is negligible, M19 closes as
"19.1 landed, pieces 2–3 measured out" and work moves to M20.

## 3.16 M19.3 gate — cold-start lib cost: measured out (blob not built)

Before implementing the pre-parsed lib blob (M19 piece 3), the roadmap gated
it on measuring what cold-start lib processing actually costs — the base build
is sub-ms and the interned lib surface is tiny, so the same data pattern that
retired §3.15 might retire this. It does.

Isolated with `--timing` + `--noLib` on a trivial 1-file project (`const x =
1;`), where the embedded lib front end dominates cold start (the run loads 2
files / 12,172 lines — all but one line is the lib). Medians of 7,
ReleaseFast:

| run | total wall (internal `--timing`) |
|---|---:|
| trivial file **with lib** | **8.68 ms** |
| trivial file **`--noLib`** | **0.24 ms** |
| ⇒ entire lib cost (load+scan+parse+bind+check) | **≈ 8.4 ms** |

Phase split of the with-lib run: load ~0.3 ms, **scan ~0.5–1.0 ms + parse
~0.9–1.6 ms + bind ~0.9–1.7 ms = the ~2–4 ms front end the blob would
eliminate**, then check ~5 ms (the checker expanding lib types lazily — *not*
eliminated by a blob; piece 2's base was reverted). The **whole process wall**
(`/usr/bin/time -p` on the binary: exec + dynamic link + all internal work) is
**0.00 s — below the 10 ms measurement resolution**.

So the blob's realizable saving is **2–4 ms of lib front end**, which is (a)
below the process-wall resolution, and (b) dwarfed by the tens of ms of
`bunx`/`npx` resolution + runtime launch that sit *upstream* of the ztsc
binary on the very `bunx ztsc` path the blob was meant to speed up. Against
that, a build.zig serialization step, a versioned flat-array `@embedFile`, and
seed-version staleness checks are real, permanent complexity for an invisible
win. **Measured out — not built.** M19 closes: 19.1 landed, 19.2 and 19.3
measured out. (These negative results and their revisit conditions are also
recorded in `EXPERIMENTS.md`.)
