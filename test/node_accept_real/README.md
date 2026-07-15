# Real-`@types/node` acceptance (M18.4)

A small real backend program (`src/config.ts`, `src/store.ts`, `src/index.ts`)
differential-checked against the **real** pinned `@types/node` (@22.7.4,
vendored by `bench/fetch_real.sh`), with ztsc's user-code diagnostics matching
the pinned native tsgo 7.0.2 oracle exactly. This is the standing real-world
gate that graduates the hand-authored `test/conformance/node_accept/backend`
node-*shaped* fixture (which stays as the committed fast regression case in
`zig build test`).

## Run

```sh
bench/fetch_real.sh            # once — vendors @types/node into bench/corpus/real (gitignored)
zig build                     # or `zig build bench`
test/node_accept_real/run.sh  # the gate; live tsgo diff if bench/baselines/tsgo is installed
```

The real `@types/node` (61 `.d.ts`, generated deps) is large and gitignored
like all bench corpora, so this is a **scripted** check rather than a
`zig build test` conformance case. `run.sh` symlinks the vendored types into a
throwaway project, runs ztsc, filters to user code (`src/`), and diffs against
`expected` — a byte-for-byte tsgo-7.0.2 snapshot (`--strict --noEmit
--skipLibCheck`).

## What it exercises

- **`process`** — `pid`, `cwd()`, `argv`, `platform`, and `process.env.X`
  (string | undefined via `NodeJS.ProcessEnv`'s inherited `Dict<string>` index
  signature, resolved across the cross-file-merged `namespace NodeJS`).
- **`fs`** — `readFileSync`/`existsSync`/`writeFileSync` (real ES-style
  `export function`s), returning the global `Buffer`.
- **`Buffer`** — the global value + type (`Buffer.from`/`alloc`/`isBuffer`,
  `.length`), declared inside a bare `global {}` block nested in
  `declare module "buffer"`.
- **`path` / `timers` / `events`** — imported and used (`join`, `resolve`,
  `setTimeout`, `EventEmitter`); these modules use `export =` / the ambient
  auto-export rule (out of subset), so ztsc degrades their named exports to
  `any` — a clean deferral, no spurious diagnostics (see accepted gaps below).
- **`NodeJS.Timeout`** — a qualified type reference into the merged namespace.

## Planted mistakes (matched against tsgo 7.0.2)

`src/index.ts` lines 21–25: `number→string`, `string→number` (cross-file
`Config`), `string|undefined→number` (the `Dict` index sig), `Buffer→string`,
and a `TS2339` for a missing `Process` member.

## Accepted gaps (under-reports, never spurious errors)

- **`export =` / ambient auto-export modules** (`path`, `timers`, `events`,
  `os`, …): named imports resolve to `any` instead of their real types, so
  mistakes *through* those symbols are not caught. Never a false positive.
- **`readFileSync(path, "utf8")` string overload**: ztsc lacks TS's weak-type
  rule, so a bare-encoding argument matches the `Buffer` overload rather than
  the `string` one. The program uses the no-encoding (`Buffer`) overload.
- **`typesVersions`**: ztsc resolves `@types/node`'s TS-5.7 root `.d.ts`
  (generic `Buffer<T> extends Uint8Array<T>`) — which is also what tsgo 7.0.2
  selects, and the TS 7.0.2 embedded lib has the matching generic
  `Uint8Array<TArrayBuffer>`, so the 5.5.4-era generic/non-generic TypedArray
  skew (a suppressed TS2315 lib degradation) is gone.
