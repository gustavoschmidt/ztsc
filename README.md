# ztsc

A fast, low-memory TypeScript type checker, written in Zig.

**Documentation & internals:** https://gustavoschmidt.github.io/ztsc/

- **At least 4× less peak memory** than tsgo (the native TypeScript 7
  compiler) on real packages — up to 19×.
- **Faster on every benchmark package** — wall clock, defaults vs. defaults —
  by up to 15×.
- A **single static binary**. No Node runtime, no dependencies — and none in
  the source either: nothing but the Zig standard library.
- **Parallel by design**, with byte-identical output at any worker count.
- Diagnostics **match the TypeScript compiler**, enforced by a 622-case
  differential conformance suite.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/benchmarks-dark.svg">
  <img alt="Peak memory and wall clock across eight packages: ztsc uses 8-25 MB where tsgo uses 44-272 MB, and takes 8-32 ms where tsgo takes 19-243 ms" src="docs/benchmarks-light.svg">
</picture>

> [!WARNING]
> ztsc is pre-release and not ready for production use. It checks a large,
> well-defined subset of TypeScript — see [Limitations](#limitations).
> Full feature parity is in the works.

## Getting started

```sh
bunx ztsc        # or: npx ztsc
```

> v0.0.1 is not on npm yet — until then, build from source with
> [Zig](https://ziglang.org) 0.16.0:
> `zig build -Doptimize=ReleaseFast` → `zig-out/bin/ztsc`.

Point it at a project and it does the rest:

```sh
ztsc                       # finds tsconfig.json in cwd or a parent
ztsc -p path/to/project    # explicit tsconfig
ztsc src/main.ts           # or explicit entry files
```

Run `ztsc --help` for all options.

## Benchmarks

Eight real, published packages on an Apple M4, identical inputs, both tools
at their default four checker instances — ztsc uses **5–25% of tsgo's peak memory**
and is **faster on all eight, by up to 15×** (wall clock is the median of 11 runs
under a monotonic nanosecond timer; the smallest packages sit near both tools'
process floors, so their ratios reflect fixed startup cost rather than checking
throughput — excluding those, ztsc is 2.6–15× faster).

Full results, methodology, and limitations of the comparison:
[BENCHMARKS.md](BENCHMARKS.md).

## Limitations

**ztsc does not build or run on Windows yet.** The checker's per-symbol state
lives in demand-zeroed anonymous memory obtained with POSIX `mmap`
(`src/zeropage.zig`) — untouched pages never become resident, which is
load-bearing for the memory numbers above. Windows has an exact equivalent
(`VirtualAlloc` returns zero-initialized, demand-paged memory) but it is not
wired in yet, so a Windows target fails at compile time with a clear error.
macOS and Linux work today; a Windows port is planned.

ztsc checks a large, well-defined subset of strict-mode TypeScript: the full
type-level language (conditional types with `infer`, mapped types,
template-literal types, generics, narrowing, declaration merging), the real
ES-core…esnext + DOM standard library with the full iteration protocol,
CommonJS interop, const-symbol computed keys, and JSX against the real
`@types/react`. What it checks, it checks like `tsc` — enforced by the
differential conformance suite. Almost every gap below fails in the safe
direction: ztsc misses an error `tsc` would report rather than inventing one,
unsupported syntax produces a clear "not yet supported" diagnostic, and it
never crashes. It is not yet a drop-in replacement for `tsc --noEmit`: on a
large production React/TypeScript application it reproduces all 48 of tsc's
errors byte-identically, and adds 10 false positives of its own.

What it does **not** check yet:

- **Watch mode and LSP** — ztsc is batch-only; both are planned next, on an
  architecture built for them.
- **~10 known false positives on real code** — deep generic inference (immer
  `Draft<S>` under a reducer spread, Zod v4 `z.infer`), a few CFA narrowing
  depths, and one lib-policy divergence. Each is diagnosed and tracked; the
  count is measured against `tsc` on a large private codebase, not estimated.
- **tsconfig options beyond the subset** — honored: `files` / `include` /
  `exclude` / `extends`, and the `compilerOptions` keys `lib`, `baseUrl`,
  `paths`, `types`, `typeRoots`, `skipLibCheck` / `skipDefaultLibCheck`,
  `allowJs`, `esModuleInterop`, `allowSyntheticDefaultImports`,
  `noImplicitAny`, `resolveJsonModule`. Strict mode only (`strict: false` is
  refused). Everything else is accepted and ignored, and `--verbose` lists
  which.
- **`lib` families other than `es*` and `dom*`** (e.g. `webworker`) — ignored,
  with a note under `--verbose`.
- **Generator corners**: `yield*` delegation is unchecked, and unannotated
  generator functions type as `any`.
- **CommonJS corners**: a namespace import of an `export =` module keeps the
  export's call signature, so `ns()` is not flagged.
- **Symbol-key corners**: a plain non-`unique` `symbol` key (rxjs's
  `[Symbol.observable]`, declared `: symbol`) is keyed by name rather than as
  a symbol index.
- **JSX corners**: prop *type* mismatches arriving inside a spread object,
  spreads of unions/generics/index-signature types, and children *value*
  typing are unchecked; class-component prop mistakes report refined codes
  (TS2741/2322) where tsgo reports TS2769.
- A handful of other known edge cases miss an error `tsc` would report.

Feature parity is in the works.

## License

MIT. The embedded standard library and the diagnostic messages are derived
from Microsoft's [TypeScript](https://github.com/microsoft/TypeScript)
(Apache-2.0) — see [NOTICE](NOTICE).
