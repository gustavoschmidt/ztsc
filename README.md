# ZTSC — Zig TypeScript Checker

A fast, low-memory TypeScript checker written in Zig, with zero external
dependencies. It type-checks TypeScript (no JS emit) — the `tsc --noEmit`
job — in a fraction of the memory.

> **Status: pre-release (`0.0.1-dev`).** Not yet on npm. v0.0.1 lands with
> prebuilt binaries for `bunx ztsc` / `npx ztsc`; in the meantime, build from
> source (see [Building from source](#building-from-source)). Building requires
> Zig 0.16.0.

## Memory: 6× leaner than tsgo, 11× leaner than tsc

Checking **`@types/node` 22.7.4** — the declaration package almost every Node
project depends on, 59 files / ~50k lines — each tool in its **default**
configuration on an Apple M4:

| | wall clock | peak RSS |
|---|---:|---:|
| **ztsc** (`--checkers=4`, its default) | **~0.01 s** | **17.0 MB** |
| tsgo 7.0.2 (TypeScript 7 native, default) | ~0.04 s | 102.6 MB |
| tsc 5.5.4 (single-threaded) | ~0.46 s | 189.4 MB |

Peak resident memory (lower is better):

```
ztsc   ██                          17.0 MB
tsgo   ██████████████             102.6 MB
tsc    ██████████████████████████ 189.4 MB
```

The memory win is systemic, not an artifact of one package. Across a spread of
seven real published packages (validators, a web framework, an ORM, the
`@types` giants), **ztsc's peak RSS is 5–20% of tsgo's and 3–9% of tsc's**,
while its wall clock is a fraction of both. tsgo's RSS climbs steeply with
corpus size (44 → 277 MB); ztsc's stays lean (6 → 21 MB) — the arena / no-GC /
struct-of-arrays payoff the project was built for.

> **What this is and isn't.** These are throughput-and-memory numbers on
> identical inputs, **not** a diagnostic-parity claim. ztsc checks a subset of
> TypeScript and ships an esnext-only lib (no DOM), so on real code the three
> tools report different diagnostic *counts* (see
> [Supported subset & limitations](#supported-subset--limitations)). Correctness
> is measured separately by a 388-case differential conformance suite that
> matches `tsc` 5.5.4 line-for-line. Wall clock at these speeds sits near the
> 10 ms measurement resolution, so the honest speed claim is "a fraction of
> tsgo's wall clock," not a precise multiple — the **memory** numbers are the
> star. Full report, methodology, per-package spread, `--checkers` sweep, and
> caveats: **[BENCHMARKS.md](BENCHMARKS.md)**.

## Installation & usage

Once v0.0.1 is published, run it with no install step:

```sh
bunx ztsc          # Bun
npx ztsc           # npm / Node
```

Until then, build the binary from source ([below](#building-from-source)) and
run `zig-out/bin/ztsc` wherever the examples show `ztsc`.

With no file arguments, ztsc finds `tsconfig.json` in the current directory or a
parent and checks the project it describes:

```sh
ztsc                          # find tsconfig.json in cwd or a parent
ztsc -p path/to/project       # use the tsconfig.json at a path (file or dir)
ztsc src/main.ts src/util.ts  # or check explicit entry files
```

Exit codes: `0` — clean check; `1` — type or syntax errors were reported;
`2` — usage, config, or filesystem errors (unknown flag, unreadable tsconfig,
`strict: false`, missing files).

### Flags

- `-p, --project <path>` — use the `tsconfig.json` at `<path>` (file or dir).
- `--pretty[=true|false]` — tsc-style colored diagnostics with source excerpt,
  caret/tilde underline, and a final `Found N errors...` summary. Default: on
  when stderr is a TTY. `--pretty=false` keeps the stable one-line-per-diagnostic
  machine format.
- `--checkers=N` — number of parallel checker instances (default:
  `min(4, CPUs)`); the speed/memory dial, see [BENCHMARKS.md](BENCHMARKS.md).
- `--workers=N` — worker threads for load/scan/parse/bind (default: CPUs).
- `--noLib` — skip ztsc's embedded standard library entirely.
- `--timing` — per-phase wall clock (discover/load/scan/parse/bind/resolve/
  link/check), lines/s, MB/s, per-checker breakdown.
- `--memory` — arena/interner/AST/binder/type-store accounting: bytes/token,
  bytes/node, binder bytes/line, bytes/type, cache hit rates.
- `--verbose` — notes about accepted-but-ignored tsconfig options.
- `--version`, `-h` / `--help`.

### tsconfig.json support

ztsc reads a practical subset of `tsconfig.json` (JSONC comments and trailing
commas allowed):

- `files`, `include` / `exclude` — glob subset `**`, `*`, `?`.
- `compilerOptions.strict` — must be `true` or absent (strict-mode semantics
  only; `strictNullChecks` is always on).
- `baseUrl` + `paths` — exact keys and single-`*` patterns, feeding module
  resolution.
- `noEmit` / `target` / `module` / `moduleResolution` / `types` / `lib` are
  accepted and ignored (noted under `--verbose`); ztsc always loads its own
  embedded lib and never emits JS. Unknown options warn but never fail.

## Supported subset & limitations

ztsc checks a broad, deliberately-scoped subset of TypeScript. Unsupported
syntax always produces a clear "not supported" diagnostic — **never a wrong
answer or a crash** (every phase is fuzzed).

### What's checked

- **Types**: primitives and literal types; `unknown` / `any` / `never` / `void`;
  objects, interfaces (incl. `extends`), type aliases, arrays, tuples; unions and
  intersections, discriminated unions; `keyof`, indexed access, `typeof` queries.
- **Functions**: parameter/return inference, optional/default/rest parameters,
  declared-overload resolution; call/construct signatures in interfaces and type
  literals (callable objects), standalone constructor types (`new (…) => T`).
- **Generics**: declarations, explicit instantiation, inference from arguments,
  instantiation caching with depth limits.
- **Classes**: fields, methods, `implements` / `extends`, visibility modifiers,
  `abstract`, getters/setters, polymorphic `this` return types and explicit
  `this` parameters.
- **Control-flow narrowing**: truthiness, `typeof`, `===` / `!==`, `in`,
  `instanceof`, discriminants, assignments; user-defined type guards and
  assertion functions.
- **Enums** (incl. `const enum`), `as const`, `satisfies`.
- **Modules**: ES modules incl. type-only imports, `.d.ts` reading; `import()`
  types (`import("m").T`, `typeof import("m")`); cross-file declaration merging
  (`declare global`, cross-file namespace/interface merge), module augmentation
  (ambient + wildcard `declare module`), and triple-slash
  `/// <reference path|types>` directives.
- **Namespaces** (incl. merging and ambient implicit export).
- **Async**: `async` / `await` / `Promise` typing, basic generators.
- **Symbols**: `symbol` and `typeof "symbol"` narrowing, `unique symbol`
  annotations, the `Symbol.iterator` iteration protocol (`for…of` / spread over
  Map / Set / generators / user iterables), the `Symbol` global.
- **Type-level programming**: conditional types + `infer` + distributivity;
  mapped types + `as` key remapping; template-literal types + the four string
  intrinsics; recursive type aliases; generic indexed access; `keyof` over
  mapped/generic types.
- **JSX** in `.tsx`: intrinsic and component elements against a `JSX` namespace,
  dashed names (`data-*` / `aria-*` / `<my-widget>`), class-component props.
- **Decorators**: TC39 standard decorators — expression checking plus decorator
  signature checks (TS1238 / TS1240 / TS1241, parameter-decorator TS1206).
- **Standard library**: the real TypeScript 5.5.4 `lib.esnext` reference chain
  (ES core through esnext) is embedded and loaded by default.

### What's not yet checked

- **DOM / browser globals.** The embedded lib is **esnext-only** — no DOM,
  webworker, or scripthost. Code referencing `Response`, `HTMLElement`,
  `FormData`, and similar browser globals gets "cannot find name" notes.
- **CommonJS interop**: `export =` and `import = require`.
- **Const-symbol computed property keys** (e.g. `[Kind]`, `[entityKind]` with a
  `unique symbol` key) — the well-known-symbol subset already checks; arbitrary
  const-symbol keys need symbol-value resolution.
- **JSX from `@types/react`**: resolving the `JSX` namespace out of
  `@types/react`, and JSX spread-attribute checking — a `JSX` namespace must be
  in scope for `.tsx` today.
- **A few conscious under-reports** in assignability and decorator edge cases
  (e.g. some mixed-intersection sources against index signatures,
  generic-decorator constraint mismatches): ztsc may miss an error tsc reports
  there, but it never invents one.

## Future features

Planned after v0.0.1 (the first release is batch checking only — no watch mode,
no LSP):

- **Incremental checking + watch mode** — the flagship follow-up: per-file
  interface signatures cut the dependency graph, so a body edit that doesn't
  change a signature re-checks just one file. Target: warm re-check of one edit
  in low double-digit milliseconds.
- **Language server (LSP)** — built on the incremental substrate; the
  sealed-phase architecture and single-owner module discovery were chosen so as
  not to preclude it.
- **Windows** support and benchmarks (macOS and Linux come first).
- **Better error output** — the current renderer copies tsc's format for
  differential comparability; the goal is to beat a straight clone with clearer
  code frames, labeled spans, color discipline, and related-info grouping.
- **`--fix`-style quick suggestions** — the "did you mean" (TS2551) hint already
  exists; expand it.
- **Incremental persistence** — an on-disk graph cache for fast CI cold starts.

## Building from source

Requires **Zig 0.16.0** and no other dependencies.

```sh
zig build                 # debug binary -> zig-out/bin/ztsc
zig build run -- <args>   # build and run
zig build test            # unit tests + 388-case conformance suite
zig build bench           # ReleaseFast binary -> zig-out/bench/ztsc
```

### How it's built

ztsc is data-oriented and arena-allocated from the ground up — that is where the
memory win comes from:

- **Data-oriented AST**: `u32` node indices, struct-of-arrays storage, shared
  `extra_data` — **~16 bytes per AST node**, 5 bytes per token.
- **Phase-lifetime arenas**: no per-object frees anywhere; sources are mmapped;
  strings are interned once, globally. No garbage collector.
- **Hash-consed types**: structural identity is integer equality; assignability
  is memoized on `TypeId` pairs (~28 bytes per type).
- **Parallel from the start**: per-file load/scan/parse/bind runs on a worker
  pool with single-owner module discovery; then the program is partitioned
  across **N independent checker instances** (`--checkers=N`, default 4) that
  read the sealed AST/binder data lock-free. Diagnostics are **byte-identical
  for any N**.

See [BENCHMARKS.md](BENCHMARKS.md) for the full performance and memory report,
per-phase timings, the `--checkers` scaling sweep, and the honest caveats.

## License

ztsc is licensed under the **MIT License** (see [LICENSE](LICENSE)).

It embeds the TypeScript 5.5.4 standard library type definitions and uses
tsc-matching diagnostic message strings, both derived from Microsoft's
TypeScript project under the Apache License 2.0. See [NOTICE](NOTICE) for the
attribution required by Apache-2.0 §4.
