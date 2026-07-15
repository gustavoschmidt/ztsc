# Conformance suite

Differential test cases for the ztsc checker, validated against the real
TypeScript compiler — the pinned native tsgo 7.0.2 baseline. Cases are
organized by area:

- `assignability/` — structural assignability, unions, tuples, functions
  (strictFunctionTypes), intersections, index signatures.
- `narrowing/` — truthiness, `typeof`, equality, discriminated unions,
  `in`, `instanceof`, optional chains.
- `inference/` — variable/return inference, contextual typing, generic
  calls, `keyof` / indexed access / `typeof` queries.
- `calls/` — arity, argument checking, overload resolution, callbacks.
- `classes/` — fields, methods, statics, `extends`/`implements`, generics.
- `literals/` — literal widening, freshness, excess property checks.
- `flow/` — assignment narrowing, loops, TDZ, definite assignment.
- `modules/` — multi-file cases: named/default/namespace/type-only
  imports, re-export chains, `export *`, import cycles, diamonds,
  `.d.ts` declare forms, `node_modules` packages, TS2307/TS2305/TS1361/
  TS2613/TS1192.

## Case formats

**Single file** — a pair of files:

- `<name>.ts` — a TypeScript source restricted to the ztsc v0.0.1 subset.
  Cases are lib-free: no globals (`console`, `Math`) and no
  primitive/array methods beyond `length` — ztsc loads no lib.d.ts.
- `<name>.expected` — expected diagnostics, one per line:

  ```
  TS<code> <line>
  ```

  with 1-based line numbers. `#` starts a comment. An empty or absent
  `.expected` file means the case must be diagnostic-free.

**Directory (multi-file)** — a folder containing `entry.ts`; the
module graph is discovered from the entry (relative imports, `./x.js`
rewrites, `index.ts` directories, case-local `node_modules` packages).
The snapshot is a file named `expected` inside the folder, one line per
diagnostic across the whole program:

```
TS<code> <file-relative-to-case-dir> <line>
```

## Generating / validating snapshots

Snapshots are produced by running the real TypeScript compiler — the
pinned native tsgo 7.0.2 baseline under `bench/baselines/tsgo` (`strict`,
`noEmit`, `target: esnext`, `lib: esnext,dom`, and for module resolution
`module: esnext`, `moduleResolution: bundler`,
`allowImportingTsExtensions`) — over every case:

```
node test/conformance/gen_expected.js test/conformance          # write
node test/conformance/gen_expected.js test/conformance --check  # verify
```

(`gen_expected.js` refuses to run unless the baseline binary reports
exactly 7.0.2; `cd bench/baselines/tsgo && npm install` if node_modules is
missing. node_modules are never checked in.)

## Runner

`test/run_conformance.zig` (wired into `zig build test`) runs the real
pipeline (parse → bind → check) on every `.ts` file and diffs the produced
diagnostics against the snapshot as a multiset of (code, line) pairs.
Message text is informational and not compared.
