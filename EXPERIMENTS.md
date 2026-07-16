# Experiments that didn't land

Negative results, preserved. Each entry records an optimization that was
seriously pursued — gated on measurement, implemented where the gate
demanded it — and then **not** shipped, so future work doesn't re-run the
same experiment from scratch, and so a change in the economics is easy to
recognize when it happens. Where an entry says an implementation was
built, it was committed in full verified form and then reverted, so the
code survives in git history rather than dying in a working tree.

---

## Frozen-base lib payload — built, verified, measured out (2026-07-15)

**Hypothesis.** With the real TypeScript lib vendored, every checker
instance re-expands and permanently interns the lib type population —
the largest in the program, duplicated up to N× at `--checkers=N`.
Pre-expanding lib/`@types` types **once** into the shared frozen base
store (the TypeId split and per-checker overlays delegating ids
`< base_len` were already in place) should claw back that duplication.

**What was built.** Post-link, single-threaded `buildBaseStore`
(checker.zig): a transient checker whose store *is* the base forces value
and type-space types for every global from the merge table /
`Program.globals`; overlays share results via the `internType` base probe.
Fully verified: conformance suite green, and 16/17 corpora
**byte-identical** to the pre-change build across `--checkers ∈ {1,4,8}`
× `--no-frozen-store` on/off (the one diff was a pre-existing rxjs
display instability, identical before the change).

**Result: no win.** The base holds the *entire* lib in ~90 KB /
~2,500 types, while each per-checker overlay runs 700 KB–1.4 MB dominated
by **instantiations** (`Array<string>`, …) and user/import types — which
are inherently per-checker and cannot be pre-expanded. Measured
type-store trim: rxjs N=8 **−6.9%**, N=4 −4.6%; multi N=4 **+0.1%
(worse)** — eager expansion interns the untouched lib tail
(Intl/Atomics/typed arrays), fighting the laziness that keeps the
real-lib cost small in the first place. Peak RSS unchanged (the type
store is ~1.5 MB of a ~28 MB RSS); wall clock unchanged. The premise was
already retired by measurement: lazy expansion interns only the touched
lib surface, and RSS sits at ~26% of tsgo against a ≤50% gate.

**Status.** The payload was reverted (implementation preserved in git
history). The frozen-base/overlay architecture and the
`--no-frozen-store` oracle **remain in the tree** — only the payload was
backed out. Full table: BENCHMARKS.md §3.15.

**Revisit if:** per-checker *instantiation* duplication ever becomes the
RSS story (a shared cross-checker interner for hot simple types is the
real fix then), or checker counts grow far beyond 8 and the census shows
lib types dominating overlay growth.

## Pre-parsed embedded lib blob — measured out, never built (2026-07-15)

**Hypothesis.** Cold start pays a full lib scan+parse+bind on every run.
A build-time step could run ztsc's own front end over the vendored lib
and `@embedFile` the sealed products (flat `u32` token/AST/binder arrays,
no pointers — trivially serializable), so startup loads instead of
parsing.

**Result: the ceiling is invisible.** Isolated via `--timing` + `--noLib`
on a 1-file project where the lib front end dominates: the **entire** lib
cost is ≈ 8.4 ms (8.68 ms with lib vs 0.24 ms `--noLib`), of which a blob
eliminates only the front end — **2–4 ms**. Lib *checking* (~5 ms, lazy
type expansion) is untouched, since the frozen-base payload above was
itself measured out. The whole process wall sits below `/usr/bin/time`'s
10 ms resolution, and `bunx`/`npx` resolution adds tens of ms *upstream*
of the binary. Real complexity (a build.zig serialization step, versioned
layout, staleness checks) for an invisible win, so it was never built.

**Re-measured after lib sharding + default-lib-check skip — smaller,
still out.** Two later changes shrank the recoverable slice further: lib
files are no longer type-checked by default, and the lib blobs are now
sharded (dom×8 / esnext×4) so the lib scan→parse→bind fans out across the
worker pool instead of running serially. The recoverable cost is exactly
the lib share of the front-end wall — the `discover` phase, which a blob
skips; link and lib type-forcing still run and are *not* recoverable.
Isolated as `discover(config) − discover(--noLib)`, ReleaseFast binary, at
default fan-out (10 workers / 8 checkers on a 10-core box), median of 15
runs each:

| config | recoverable front-end wall |
| --- | --- |
| trivial file, DOM (default lib) | ≈ 3.2 ms |
| trivial file, esnext-only | ≈ 1.0 ms |
| zod (DOM) | ≈ 2.0 ms |
| chalk (esnext) | ≈ 1.0 ms |
| @types/node (esnext, 61 files) | ≈ 0 ms (buried in noise; a slightly *negative* delta — removing lib files from a 10-worker pool of larger user `.d.ts` barely moves wall) |

So the pre-sharding "~2–4 ms" is now the *ceiling* (trivial + DOM, where
nothing hides the lib), and on real projects it's ~1–2 ms and vanishes
into run-to-run noise. Sharding already spent most of the win a snapshot
would have delivered: the lib front-end work is unchanged in total, but
parallelism collapsed its *wall* contribution. Even at the trivial-DOM
ceiling, the front-end is only ~3 ms of a ~15 ms internal wall — the other
~12 ms is link + lib type-forcing + interner seed + thread/arena setup,
none of which a front-end blob touches. Peak RSS: the DOM lib costs
~12 MB (trivial DOM 15.3 MB vs `--noLib` 3.0 MB), esnext-only ~3 MB — but
the lib *source* (~3 MB, already `@embedFile` rodata / clean file-backed
pages) is not where that sits, and the type store + interner rebuild at
runtime regardless; RSS also already runs at ~26% of tsgo against a ≤50%
gate. Still below the ~10 ms bar by every measure, and further out than
before — not built.

**Design, preserved.** If built: depends on deterministic seeded atoms —
the blob bakes atom values, so the seeded lib-atom prefix must stay a
contiguous versioned range, with a seed-table version tag rejecting a
stale blob. Details: BENCHMARKS.md §3.16.

**Revisit if:** startup latency ever becomes hot-path — e.g. an editor
integration that spawns a fresh process per interaction instead of a
persistent language server — or the lib front-end cost grows an order of
magnitude.

---

Related context: BENCHMARKS.md §3.13 (why lazy lib expansion made both
premises moot), §6 (caveats on what the numbers claim).
