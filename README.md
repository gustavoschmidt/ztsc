# ztsc

A fast, low-memory TypeScript type checker, written in Zig.

**Documentation & internals:** https://gustavoschmidt.github.io/ztsc/

- **At least 5× less peak memory** than tsgo (the native TypeScript 7
  compiler) on real packages — up to 12×.
- **At least 2× faster** — wall clock, defaults vs. defaults — up to 11×.
- A **single static binary**. No Node runtime, no dependencies — and none in
  the source either: nothing but the Zig standard library.
- **Parallel by design**, with byte-identical output at any worker count.
- Diagnostics **match the TypeScript compiler**, enforced by a 414-case
  differential conformance suite.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/benchmarks-dark.svg">
  <img alt="Peak memory and wall clock across eight packages: ztsc uses 6-22 MB where tsgo uses 44-275 MB, and takes 7-25 ms where tsgo takes 18-242 ms" src="docs/benchmarks-light.svg">
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
at their default four checker instances — ztsc uses **8–20% of tsgo's peak memory** and is
**2.5–11× faster** (wall clock measured with a millisecond-precision timer;
the smallest packages sit near both tools' process floors, so their ratios
reflect fixed startup cost rather than checking throughput).

Full results, methodology, and limitations of the comparison:
[BENCHMARKS.md](BENCHMARKS.md).

## Limitations

ztsc checks a large, well-defined subset of strict-mode TypeScript: the full
type-level language (conditional types with `infer`, mapped types,
template-literal types, generics, narrowing, declaration merging), the real
ES-core…esnext + DOM standard library with the full iteration protocol,
CommonJS interop, const-symbol computed keys, and JSX against the real
`@types/react`. What it checks, it checks like `tsc` — enforced by the
differential conformance suite. Every gap below fails in the safe direction:
ztsc may miss an error `tsc` would report, but it never reports an error on
valid code, and unsupported syntax produces a clear "not yet supported"
diagnostic — never a wrong answer or a crash.

What it does **not** check yet:

- **Watch mode and LSP** — ztsc is batch-only; both are planned next, on an
  architecture built for them.
- **tsconfig options beyond the subset** — only `files` / `include` /
  `exclude` / `baseUrl` / `paths` / `lib` (plus the `skipLibCheck` keys) are
  honored, strict mode only (`strict: false` is refused); everything else is
  accepted and ignored, and `--verbose` lists which.
- **`lib` families other than `es*` and `dom*`** (e.g. `webworker`) — they
  warn and are ignored.
- **Generator corners**: `yield*` delegation is unchecked, and unannotated
  generator functions type as `any`.
- **CommonJS corners**: a namespace import of an `export =` module keeps the
  export's call signature (`ns()` is not flagged), and a member of a
  `require`-bound namespace used in *type* position resolves to `any`.
- **Symbol-key corners**: a plain non-`unique` `symbol` key (rxjs's
  `[Symbol.observable]`, declared `: symbol`) is keyed by name rather than as
  a symbol index, and a deeper-qualified key (`[a.b.c]`) is out of subset.
- **JSX corners**: prop *type* mismatches arriving inside a spread object,
  spreads of unions/generics/index-signature types, and children *value*
  typing (TS2745/2746) are unchecked; class-component prop mistakes report
  refined codes (TS2741/2322) where tsgo reports TS2769.
- **The embedded lib files are not re-type-checked** by default — they ship
  pre-verified each release (tsc's `skipDefaultLibCheck`); `--check-default-lib`
  restores the check, with byte-identical diagnostics either way.
- A handful of other known edge cases miss an error `tsc` would report.

Feature parity is in the works.

## License

MIT. The embedded standard library and the diagnostic messages are derived
from Microsoft's [TypeScript](https://github.com/microsoft/TypeScript)
(Apache-2.0) — see [NOTICE](NOTICE).
