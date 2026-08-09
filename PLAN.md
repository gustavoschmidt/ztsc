# Plan: hold parity, close the perf bars

Diagnostic parity is **achieved and gated** — eight packages at 0 under /
0 excess (`bench/parity_sweep.sh`, ratcheted at zero), excalidraw
CONVERGED 17/17 at every N (`bench/convergence.sh bench/apps/excalidraw`),
immich 0/0 at c1/c4/c8. The B1–B4 known-bug ledger that used to be this
file is **closed**; every entry landed (B1 ee678c1 + 55577da, B2 aff95db,
B3 c0a81d0, B4 08c824c) and the app campaign finished immich at e31762e.

The remaining work is **perf**, and only on the applications. The
published package rows already clear both bars comfortably.

## The bars, and where immich actually is

Project goal: on every benchmark, wall <= 1/2 and peak RSS <= 1/5 of
tsgo. immich (tsgo 7.0.2: **2.88 s / 2.18 GB**) so bars are **1.44 s /
436 MB**:

| config | wall | wall/tsgo | RSS | RSS/tsgo |
|---|---:|---:|---:|---:|
| c1 | 2.67 s | 109% | **382 MB** | **18%** |
| c4 (default) | 2.23 s | 91% | 1039 MB | 48% |

**RSS is met at one checker and nowhere else. Wall is met nowhere**, but
c4 is now under tsgo's own wall for the first time.

Landed this pass, from 3.68 s / 1.201 GB at c1:

* `d076107` — a scratch frame at the template cross-product;
* `802d6ab` — a scratch frame per expression. Together: c1 peak RSS
  1.201 -> 0.373 GB, c4 2.555 -> 1.011 GB;
* `97827bd` — the `--decl-profile` axis the analysis below rests on;
* `2103872` — the interning tax: an instruction-level sampling profile
  (never run before on this project) found 42% of leaf samples in type
  interning/hashing vs 25% in the substitution walk. Six data-structure
  fixes, counters byte-identical, wall c1 3.68 -> 2.67 s and c4
  3.53 -> 2.23 s.

**Correction to an earlier claim:** `802d6ab`'s message says the multi
corpus went to 19.9% of tsgo. That rested on a single noisy `e2e.sh`
reading. Interleaved A/B puts multi at ~43.2 MB both before and after
(~21% of tsgo's 205 MB), so **the long-standing 21% edge on that row is
still open** and neither scratch frame closed it. It remains the one
published row that misses a bar.

## What the wall is, measured

Three independent results, all in `src/checker/prof.zig`'s header:

* **It is not contention.** Four separate single-checker PROCESSES are
  3.6% *slower* per type than one four-checker process. No lock, no
  allocator pressure. The only tax is ~30% memory bandwidth from running
  four checkers at once, which caps any speedup at 3.07x.
* **It is not statement checking.** `--decl-profile` says **82% of the c1
  check phase (2.84 s of 3.47 s) is declaration materialization**, and
  98.75% of all 11.1 M instantiate node visits are inside such a window.
  At c4 it is 91.7%, with 0.27 s of statement remainder — partitioning
  the files divides the statement work ~2.4x and the declaration work not
  at all.
* **It is work duplication.** The set of distinct canonical types immich
  needs is invariant in checker count (1.72 M at c1, 1.76 M at c4/c8),
  but c4 builds 5.05 M and c8 builds 8.43 M — 2.86x and 4.79x
  redundancy, with 87–93% of each checker's types also present in
  another's arena. Partitioning files four ways partitions work 1.31 ways.

## Lane 1 (partly harvested) — reduce absolute work

`2103872` took 21–25% off wall without touching a diagnostic, and all of
it came from the tax on *producing* a type rather than from the decision
to produce it. What is left of the overhead, from the same sampling
profile, is smaller and each item is independent:

| candidate | mechanism | est. | risk |
|---|---|---:|---|
| `instantiateId` unchanged-result early-out | the `.object`/`.union`/`.function` arms always rebuild and re-intern; return `t` when no child moved | 3–5% | low — must not lose the `origin` tag |
| presize `inst_cache` | 5.9 M inserts into an unreserved map | 1.5–2% | low, trades RSS |
| `canonMapId` off the string interner | packs bytes and probes a `StringHashMap` per `instantiate` entry | 1.5–2% | low |
| `propOfTypeEx` (3.1%) | already a binary search; cost is cache misses on `extra` | 1–2% | medium |
| bound the hashed shape prefix | Wyhash over 183 words for a 60-member table | ~1% | low |

Optimistically ~10% together, landing immich near 2.4 s against a 1.23 s
bar. **This lane cannot reach the wall bar on its own.**

### The declaration work underneath it

Helps every configuration and every benchmark, and does not touch
interning order. 79% of declaration time is `expandRef` — per-argument-
list substitution over an already-memoized generic table — not building
the generic forms (all 1,274 interface tables together cost 30 ms).
Targets, `--decl-profile` self time: `SelectQueryBuilder` 884 ms / 1,020
substitutions, `ExpressionBuilder` 516 ms / 177, `InsertQueryBuilder`
246 ms / 606, `UpdateQueryBuilder` 214 ms / 545.

The likely keystone: **2.4 s of the 2.84 s is spent inside 992 root
expressions checked *within* declaration windows**, and those are immich
repository METHOD BODIES with no return annotation — materializing the
class member table means running each kysely chain through the checker to
infer its return type.

Constraint: prof.zig's header records that per-member lazy substitution
was measured as a large regression twice (immich excess 453 -> 522/523)
with the mechanism explained. Do not re-run it.

Two questions answered while harvesting `2103872`, so they are not
re-asked: method return types ARE inferred once and memoized (every
statement-shaped root inside a declaration window lists `1 x`), and the
5.91 M inst-cache misses are genuinely distinct `(map_id, type)` pairs —
the removable redundancy was one level down, in re-deriving things that
are pure functions of an already-interned object. **Still unmeasured:**
of the 20,176 `expandRef` expansions, how many produce a member table
that is ever read before the next expansion of the same symbol.

## Lane 2 (blocked on a decision) — share derived state across checkers

The only route to the wall bar if lane 1 falls short, and the reason it
is not started:

* The cheap version is **dead**, measured. A serial pre-pass that
  reproduces the demanded declaration surface floors wall at ~2.8 s
  (most generous scoping: ~1.98 s) against a 1.44 s bar — though note
  that floor was computed against a declaration phase `2103872` has since
  made ~22% cheaper, so it wants re-deriving before the lane is finally
  closed. The
  concentration curve is a mirage — `SelectQueryBuilder`'s 884 ms is
  1,020 distinct *substitutions*, and the part a demand-free pre-pass
  could build without checking consumer files is exactly the run-once
  generic form, worth 30 ms. The 2.3 s that is duplicated is
  `(symbol, type-argument-list)` expansions whose argument lists come
  from consumer code, so enumerating them IS checking the program.
* The real version is a **shared store with concurrent interning**, and
  it is expensive and risky:
  - modelled outcome is **1.3–1.6 s against a 1.44 s bar** — it straddles;
  - `relIdDeeplyNested` (`assign.zig:1828`) cuts relation walks by
    comparing raw TypeIds, and prof.zig records that immich's kysely pair
    escapes that cut *because the refs on its spine decrease* — an
    interning-order property. Thread-dependent interning puts the 0/0
    parity at risk;
  - `types.zig:528-537`: `members()` returns slices into `extra` that
    dangle as soon as a new type is interned. Shared-and-growable means
    another thread's intern invalidates your slice.

The frozen-base machinery exists and is unused (`checker.zig:242-255`,
17 intrinsic types); it is not the blocker, the payload is.

## Lane 3 — drizzle-orm's scratch pathology

1.686 GB peak RSS / 1.667 GB scratch high-water on a **27 k-line
package**, against tsgo's 290 MB on the same invocation. Untouched by
both scratch frames because it lives inside a single `.d.ts` type alias
(`sqlite-core/query-builders/select.d.ts:421`, `inst_depth` 16, budget
exhausted at 250,001) which contains no expressions to frame.

This is the parity gate's `-p <dir>` configuration, NOT the published
BENCHMARKS.md row (which uses an explicit file list, 12.6k lines, 18.1 MB
and is fine) — so no published bar is breached. It needs a frame at the
type-level materialization path, which is a different contract from the
expression one and needs its own escape audit.

## Standing gates on every checker-touching change

`zig build test` (conformance + unit), `bench/parity_sweep.sh`,
`bench/convergence.sh bench/apps/excalidraw`, `bench/crash_sweep.sh`,
`bench/repeat_sweep.sh`, `bench/e2e.sh multi`, and
`bench/app_bench.sh immich 1 2 4` (added this pass — the app counterpart
to e2e.sh, interleaving ztsc and tsgo and scoring each config against the
bars). Run `zig fmt build.zig src test` before every commit.

Scratch-arena changes additionally need the poisoning harness: patch
`BumpArena.restore` to `@memset` the reclaimed range to 0xDD outside
ReleaseFast, **establish a positive control first** (inject a deliberate
escape and confirm it panics), then run the suite and the apps. Both
landed frames were validated that way, including on outline, social-app
and vscode.

## Known, not blocking

* social-app at c4 has pre-existing run-to-run nondeterminism in
  unique-symbol numbering (`__@u758974` vs `__@u758888` in a type string
  across repeats of the SAME binary). `repeat_sweep.sh` only covers the
  eight packages, so nothing gates it.
* ~34 stale agent worktrees from the parity campaign are still registered
  (`git worktree list`), from 11c3cb8 through 23203a3.
