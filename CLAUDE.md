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

## Before every commit

Run `zig fmt build.zig src test` — CI runs `zig fmt --check` on those paths
and fails the build on any unformatted file.

Run the benchmark (`bench/e2e.sh multi`) and compare against the last
recorded numbers. **If wall clock or peak RSS regressed, alert me before
committing** — the headline goal is **at least 2× faster and at least 5× less
peak memory than tsgo on every benchmark** (wall ≤50% and peak RSS ≤20% of
tsgo's, packages and whole applications alike), so anything that breaks either
bar is a blocker, not a footnote.
