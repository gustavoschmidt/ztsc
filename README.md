# ztsc

An extremely fast, low-memory TypeScript type checker, written in Zig.

**Documentation:** https://gustavoschmidt.github.io/ztsc/

- **6–20% of tsgo's peak memory** (the native TypeScript 7 compiler) on real
  packages — and faster, not slower.
- A **single static binary**. No Node runtime, no dependencies.
- **Zero dependencies in the source, too** — the Zig code uses nothing but
  the Zig standard library; `build.zig.zon` lists no packages.
- **Parallel by design**, with byte-identical output at any worker count.
- Diagnostics **match the TypeScript compiler**, enforced by a 388-case
  differential conformance suite.

> [!WARNING]
> ztsc is pre-release and not ready for production use. It checks a large,
> well-defined subset of TypeScript — full feature parity is in the works.

## Benchmarks

Seven real, published packages on an Apple M4, identical inputs, both tools at
their default 4 checkers — ztsc uses **6–20% of tsgo's peak memory** and
**6–50% of its wall clock**:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/benchmarks-dark.svg">
  <img alt="Peak memory and wall clock across seven packages: ztsc uses 6-22 MB where tsgo uses 44-280 MB, and is faster on every package" src="docs/benchmarks-light.svg">
</picture>

Full results, methodology, and limitations of the comparison:
[BENCHMARKS.md](BENCHMARKS.md).

## Getting started

v0.0.1 is not on npm yet. Once it is:

```sh
bunx ztsc        # or: npx ztsc
```

Until then, build from source — all you need is [Zig](https://ziglang.org)
0.16.0:

```sh
zig build -Doptimize=ReleaseFast   # -> zig-out/bin/ztsc
```

Point it at a project and it does the rest:

```sh
ztsc                       # finds tsconfig.json in cwd or a parent
ztsc -p path/to/project    # explicit tsconfig
ztsc src/main.ts           # or explicit entry files
```

Run `ztsc --help` for all options.

## Limitations

ztsc is a batch checker for strict-mode TypeScript. What it checks, it checks
like `tsc` — but it does not check everything yet:

- **No DOM lib.** The embedded standard library is esnext-only, so browser
  globals (`Response`, `HTMLElement`, `fetch`, …) are not recognized.
- **No CommonJS interop**: `export =` and `import x = require(…)`.
- **No const-symbol computed keys** (`[kind]: T` with a `unique symbol` key);
  well-known symbols like `[Symbol.iterator]` work.
- **JSX needs a `JSX` namespace in scope** — resolving it from `@types/react`
  and spread-attribute checking are not wired up yet.
- **tsconfig subset**: `files` / `include` / `exclude` / `baseUrl` / `paths`,
  strict mode only; other options are accepted and ignored.
- **No watch mode or LSP yet** — both are planned next, on an architecture
  built for them.
- In a handful of known edge cases ztsc misses an error tsc would report. It
  never reports an error on valid code.

Unsupported syntax produces a clear "not yet supported" diagnostic — never a
wrong answer or a crash. Feature parity is in the works.

## License

MIT. The embedded standard library and the diagnostic messages are derived
from Microsoft's [TypeScript](https://github.com/microsoft/TypeScript)
(Apache-2.0) — see [NOTICE](NOTICE).
