# Conformance suite

Differential test cases for the ztsc checker, validated against real `tsc`
(PLAN.md §3). Cases are organized by area:

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

## Case format

Each case is a pair of files:

- `<name>.ts` — a TypeScript source restricted to the ztsc v0.0.1 subset
  (PLAN.md §5). Cases are lib-free: no globals (`console`, `Math`) and no
  primitive/array methods beyond `length` — ztsc loads no lib.d.ts in M4.
- `<name>.expected` — expected diagnostics, one per line:

  ```
  TS<code> <line>
  ```

  with 1-based line numbers. `#` starts a comment. An empty or absent
  `.expected` file means the case must be diagnostic-free.

## Generating / validating snapshots

Snapshots are produced by running the real TypeScript compiler
(`strict`, `noEmit`, `target: esnext`, `lib: esnext`) over every case:

```
node <scratch>/tsc-diff/gen_expected.js test/conformance          # write
node <scratch>/tsc-diff/gen_expected.js test/conformance --check  # verify
```

(`gen_expected.js` lives in this directory; run it with a scratch
`npm install typescript` prefix on NODE_PATH or copy it next to a
node_modules containing typescript. node_modules are never checked in.)

## Runner

`test/run_conformance.zig` (wired into `zig build test`) runs the real
pipeline (parse → bind → check) on every `.ts` file and diffs the produced
diagnostics against the snapshot as a multiset of (code, line) pairs.
Message text is informational and not compared.
