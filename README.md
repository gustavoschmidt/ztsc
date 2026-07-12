# ZTSC — Zig TypeScript Checker

A fast, memory-lean TypeScript *type checker* (no JS emit) written in Zig.

**Status: pre-release (`0.0.1-dev`).** The first published version, v0.0.1,
ships when `bunx ztsc` works end-to-end on real Bun projects — no partial
releases before that. Milestones M0–M6 (the subset checker, tag `m6`) are
done; the road to v0.0.1 is [ROADMAP.md §5](ROADMAP.md).

Headline from the M6 milestone (multi corpus: 201 files / 93k lines,
Apple M4 — full report with methodology and caveats in
[BENCHMARKS.md](BENCHMARKS.md)):

| | wall | peak RSS |
|---|---:|---:|
| **ztsc (M6)** | **0.02 s** | **72 MB** |
| tsgo (TS 7 native preview) | 0.08 s | 205 MB |
| tsc 5.5.4 | 0.91 s | 314 MB |

That is an in-subset, synthetic-corpus comparison — read the caveats
before quoting it. Both M6 acceptance gates (wall within 1.25× of tsgo,
RSS ≤ 50% of tsgo) pass.

## How it's built

- **Data-oriented AST**: `u32` node indices, struct-of-arrays storage,
  shared `extra_data` — **~16 bytes/AST node**, 5 bytes/token.
- **Phase-lifetime arenas**: no per-object frees anywhere; sources are
  mmapped; strings interned once, globally.
- **Hash-consed types**: structural identity = integer equality;
  assignability memoized on `TypeId` pairs (~28 bytes/type).
- **Parallel from the start**: per-file load/scan/parse/bind on a worker
  pool with single-owner module discovery, then the program partitioned
  across **N independent checker instances** (`--checkers=N`, default 4)
  that read the sealed AST/binder data lock-free. Diagnostics are
  byte-identical for any N.

## What it checks today

Primitives + literal types, objects/interfaces/type aliases, arrays,
tuples, unions/intersections + discriminated unions, functions (inference,
optional/default/rest, declared-overload resolution), generics with basic
inference, classes (fields/methods/`extends`/`implements`/visibility),
control-flow narrowing (truthiness, `typeof`, equality, `in`,
`instanceof`, discriminants, assignments), `keyof` / indexed access /
`typeof`, ES modules incl. type-only imports and `.d.ts` reading —
strict-mode semantics only. Full list: [ROADMAP.md §6](ROADMAP.md).

Not yet supported (queued in [ROADMAP.md §5](ROADMAP.md)): **`lib.d.ts`**
(no global/DOM/ES types yet — the next milestone), conditional/mapped/
template-literal types, `infer`, enums, namespaces, decorators, JSX,
declaration merging. Unsupported syntax gets a clear "not yet supported"
diagnostic, never a wrong answer or a crash (fuzzed at every phase).

Conformance: **180/180** differential cases (error code + line) vs
tsc 5.5.4, including 30 multi-file cases.

## Quickstart

Requires Zig 0.16.0.

```sh
zig build                     # debug binary in zig-out/bin/ztsc
zig build test                # unit tests + conformance suite
zig build bench               # ReleaseFast binary in zig-out/bench/ztsc

# Check a project: with no file args, ztsc finds tsconfig.json in the
# current directory or its parents (or use -p):
zig-out/bin/ztsc
zig-out/bin/ztsc -p path/to/project
zig-out/bin/ztsc src/main.ts src/util.ts   # or explicit entry files
```

### tsconfig.json subset

`files`, `include`/`exclude` (glob subset: `**`, `*`, `?`; JSONC comments
+ trailing commas), `compilerOptions.strict` (must be `true` or absent),
`baseUrl` + `paths` (exact keys and single-`*` patterns, feeding module
resolution). `noEmit`/`target`/`module`/`moduleResolution`/`types`/`lib`
are accepted and ignored (noted under `--verbose`); unknown options warn
but never fail.

### Flags

- `-p, --project <path>` — use the tsconfig.json at `<path>` (file or dir).
- `--pretty[=true|false]` — tsc-style colored diagnostics with source
  excerpt, caret/tilde underline, and a final `Found N errors...` summary.
  Default: on when stderr is a TTY. `--pretty=false` keeps the stable
  one-line-per-diagnostic machine format.
- `--timing` — per-phase wall clock (discover/load/scan/parse/bind/resolve/
  link/check), lines/s, MB/s, per-checker breakdown.
- `--memory` — arena/interner/AST/binder/type-store accounting:
  bytes/token, bytes/node, binder bytes/line, bytes/type, cache hit rates.
- `--workers=N` — worker threads for load/scan/parse/bind (default: CPUs).
- `--checkers=N` — checker instances (default: min(4, CPUs)); the
  speed/memory dial, see BENCHMARKS.md §3.2.
- `--verbose` — notes about accepted-but-ignored tsconfig options.
- `--dump-ast`, `--dump-symbols`, `--dump-types` — golden-test dumps.
- `--repeat=N` — re-run scan/parse/bind N times (benchmark aid).
- `--version`, `-h`/`--help`.

### Exit codes

`0` — clean check; `1` — type/syntax errors were reported; `2` — usage,
config, or file-system errors (unknown flag, unreadable tsconfig,
`strict: false`, missing files).

## Benchmarks

See **[BENCHMARKS.md](BENCHMARKS.md)** for the full M6 report: per-phase
timings, `--checkers` scaling (1/2/4/8) with the duplicated-type overhead
measured, memory metrics, acceptance-gate evaluation, and the honest
caveats (subset semantics, synthetic corpora, no lib.d.ts).

```sh
node bench/gen_corpus.js      # regenerate the deterministic corpora
bench/e2e.sh multi            # end-to-end vs tsc/tsgo (if on PATH)
bench/scan.sh medium 50       # phase benchmarks: scan/parse/bind/check
```

## Layout

```
src/            main.zig (CLI, pool, phase orchestration),
                source.zig (mmap, line tables), intern.zig (interner),
                scanner.zig, ast.zig (SoA nodes), parser.zig,
                binder.zig (symbols, scopes, flow graph),
                types.zig (hash-consed types), checker.zig,
                modules.zig (resolution, module graph), tsconfig.zig,
                render.zig (pretty diagnostics), diagnostics.zig
bench/          e2e + per-phase harnesses, corpus generator
test/           conformance runner + 180 differential cases vs tsc
```

## Roadmap

Everything — goals, architecture, milestone history, and the path to the
public v0.0.1 — lives in **[ROADMAP.md](ROADMAP.md)**. Next up (M7):
`lib.d.ts` support and a "reality census" of real npm/Bun codebases that
decides the implementation order of everything after it. Then semantic
breadth (M8), the type-level core — conditional/mapped/template-literal
types (M9) — and finally `bunx ztsc` distribution (M10), which is the
v0.0.1 release: batch checking of your root files and all their
dependencies, libraries included. Incremental checking, watch mode, and
LSP come in versions after v0.0.1.
