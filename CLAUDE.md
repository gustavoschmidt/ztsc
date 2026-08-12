# CLAUDE.md

ZTSC — a fast, memory-lean TypeScript type checker (no JS emit) written in Zig.
Requires Zig 0.16.0.

## Git workflow

Work directly on `main` — commit and push there. No feature branches or PRs.

## Commands

```sh
zig build                 # debug binary -> zig-out/bin/ztsc
zig build run -- <args>   # build and run ztsc
zig build test            # unit tests + conformance suite
zig build bench           # ReleaseFast binary -> zig-out/bench/ztsc
bench/e2e.sh multi        # end-to-end vs tsgo
```

## Module design

Keep modules small and single-purpose, and keep APIs functional:

- **One responsibility per file.** When a file accumulates a second concern
  (or a >1000-line cluster with its own vocabulary), split it out. Name files
  after what they contain, not where the code used to live.
- **Functional APIs**: explicit inputs → returned values. Return structs,
  optionals, or tagged unions instead of `*bool`/out-parameter signalling.
  Never smuggle a result through a context field when it can be returned.
- **No hidden state.** Allocators, `Io`, and configuration are parameters,
  never module-level `var`s or hardcoded `std.heap.page_allocator`. Mutable
  state is acceptable only for memos/caches, cycle-detection stacks, arenas,
  and accumulators — and each one carries a comment justifying it (ideally
  with a measurement).
- **Separate pure computation from stateful wrappers**: memo probe → pure
  `computeX` function → memo store. Extract pure helpers so they can be
  unit-tested without constructing the surrounding context object.
- **`pub` means "has a consumer in another file."** De-pub anything only used
  within its own file; delete anything with no consumer at all. Don't leave
  dead imports behind.
- **No duplicated logic across files** — two copies of a predicate or a
  pipeline WILL drift; extract and share instead.

## Before every commit

Run `zig fmt build.zig src test` — CI runs `zig fmt --check` on those paths
and fails the build on any unformatted file.

Run the benchmark (`bench/e2e.sh multi`) and compare against the last
recorded numbers. **If wall clock or peak RSS regressed, alert me before
committing** — the headline goal is **at least 2× faster and at least 5× less
peak memory than tsgo on every benchmark** (wall ≤50% and peak RSS ≤20% of
tsgo's, packages and whole applications alike), so anything that breaks either
bar is a blocker, not a footnote.
