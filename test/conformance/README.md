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
- `errors/` — which diagnostic tsc picks for a given failure, where the
  code and the message text are the thing under test (spelling
  suggestions: TS2551 vs TS2339, TS2552 vs TS2304).
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

**Snapshots are never hand-edited.** A `.expected`/`expected` file is exactly
what the oracle printed, so `--check` is a real gate: if it reports a
mismatch, either the case changed or a snapshot was edited by hand, and both
need explaining. Editing a snapshot to match ztsc silently converts the suite
from "ztsc matches tsc" into "ztsc matches what ztsc did last time".

Every case is checked with the same options, so an option a case wants to
turn *off* has to be one the oracle can actually be told to turn off.
`allowSyntheticDefaultImports`/`esModuleInterop` are not: this oracle version
removed the `=false` form of both (TS5108), and the fixed
`--moduleResolution bundler` makes the effective flag true anyway — so the
synthesized default is on for every case, and `run_conformance.zig` defaults
the same way.

## Accepted divergences (`DEFERRED`)

Deliberate, reviewed differences between the oracle and ztsc live in
`test/conformance/DEFERRED`, one per line, each with a comment saying why:

```
<case-path>  -TS<code> [<file>] <line>   # oracle reports it, ztsc does not
<case-path>  +TS<code> [<file>] <line>   # ztsc reports it, the oracle does not
```

The runner subtracts these before comparing. A `-` entry is an accepted
under-report, which project policy allows when it is deterministic and
reasoned; a `+` entry admits a diagnostic the oracle does not produce and
needs a much stronger justification (today the only one is a report-*site*
difference on a diagnostic that is in the snapshot at another line).

The registry cannot hide a regression: the runner fails the case when an
entry stops describing reality — ztsc started emitting a `-` line, stopped
emitting a `+` line, the oracle no longer reports a `-` line, or the case is
gone. Fixing the underlying gap therefore *breaks the build* until the entry
is deleted.

## Runner

`test/run_conformance.zig` (wired into `zig build test`) runs the real
pipeline (parse → bind → check) on every `.ts` file and diffs the produced
diagnostics against the snapshot as a multiset of (code, line) pairs, after
applying that case's `DEFERRED` entries. Message text is informational and
not compared.
