# ZTSC — Zig TypeScript Checker

A TypeScript type checker written in Zig. Goals for v0.0.1 (see
[PLAN.md](PLAN.md)):

- **Speed**: same order as TypeScript 7 (`tsgo`) on equivalent workloads.
- **Memory**: the headline goal — **≤ 50% of tsgo's peak RSS**, via a
  data-oriented AST (u32 indices, struct-of-arrays), phase-lifetime arenas,
  and hash-consed types.
- **Parallel from the start**: per-file parse/bind on a thread pool,
  N independent checker instances.

ZTSC only *checks* — no JS emit. It targets a defined subset of TypeScript
(PLAN.md §5) with `strict` semantics.

## Status

M0 (skeleton & scoreboard): CLI loads files in parallel (mmap + line
tables) with per-worker arenas, a thread-safe sharded string interner,
timing/memory instrumentation, benchmark harness, and a conformance-runner
skeleton. No parsing yet — that's M1+.

## Build & run

Requires Zig 0.16.0.

```sh
zig build                 # debug binary in zig-out/bin/ztsc
zig build test            # unit tests + conformance suite
zig build bench           # ReleaseFast binary in zig-out/bench/ztsc

zig-out/bin/ztsc --version
zig-out/bin/ztsc --timing --memory src.ts other.ts
```

Flags:

- `--timing` — per-phase wall-clock ms, lines/s, MB/s.
- `--memory` — per-arena bytes, interner bytes, bytes/line of loaded source.
- `--version` — print version.

## Benchmarks

```sh
bench/run.sh small        # ~5k LOC synthetic corpus
bench/run.sh medium       # ~50k LOC synthetic corpus
```

The harness generates deterministic corpora with `bench/gen_corpus.js`
(requires node), runs ztsc under `/usr/bin/time` (wall clock + peak RSS),
and — when `tsgo` or an installed `tsc` is available — runs the same corpus
through them for comparison.

## Layout

```
src/            main.zig (CLI/pool), source.zig (mmap, line tables), intern.zig
bench/          harness (run.sh) + corpus generator (corpora are gitignored)
test/           conformance runner + cases (differential vs tsc)
```
