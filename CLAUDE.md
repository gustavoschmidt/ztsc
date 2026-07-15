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

Run the benchmark (`bench/e2e.sh multi`) and compare against the last
recorded numbers. **If wall clock or peak RSS regressed, alert me before
committing** — memory ≤50% of tsgo and speed parity are the headline goals,
so a regression is a blocker, not a footnote.
</content>
</invoke>
