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
```

Run the checker (no file args = find tsconfig.json in cwd or a parent):

```sh
zig-out/bin/ztsc
zig-out/bin/ztsc -p path/to/project
zig-out/bin/ztsc src/main.ts src/util.ts
```

## Benchmarks

```sh
node bench/gen_corpus.js   # regenerate the deterministic corpora
bench/e2e.sh multi         # end-to-end vs tsc/tsgo (if on PATH)
bench/scan.sh medium 50    # per-phase: scan/parse/bind/check
```

`bench/e2e.sh` sweeps `--checkers=1,2,4,8` and reports wall clock and peak
RSS; see BENCHMARKS.md for the full methodology.

## Before every commit

Run the benchmark (`bench/e2e.sh multi`) and compare against the last
recorded numbers. **If wall clock or peak RSS regressed, alert me before
committing** — memory ≤50% of tsgo and speed parity are the headline goals,
so a regression is a blocker, not a footnote.
