# ZTSC — Roadmap

**ZTSC** = Zig TypeScript Checker. (`tsc` officially stands for *TypeScript
Compiler* — it checks *and* emits JS. ZTSC only checks, so "Checker" is the
honest name.)

This is the project's single document: goals, architecture, development
history, and the work list. (It absorbed the original PLAN.md on 2026-07-12;
the milestone history in §4 preserves that plan's record.)

---

## 1. Goals & release policy

1. **Memory — decisively lower than TypeScript 7 (`tsgo`).** The headline
   goal: **≤ 50% of tsgo's peak RSS** on the same workload, tracked as a
   first-class benchmark.
2. **Speed — same order as tsgo.** Matching its throughput is success;
   beating it is a bonus.
3. **Parallel by design.** Multi-core from milestone 0, never retrofitted.
4. **Correctness = tsc.** When in doubt, match tsc's observable behavior
   (differential conformance testing), not the spec-as-imagined.

### Release policy — the public v0.0.1

**There are no partial public releases.** The first published version,
**v0.0.1**, ships only when the whole M7–M10 sequence below is done. Its
definition is exactly this: a user runs **`bunx ztsc <root-files>`** and
ztsc type-checks those files and *everything they depend on* — including
libraries — with most of TypeScript's functionality, fast and with low
memory usage. That headline is the release. It will have bugs; it will not
feel like a toy.

v0.0.1 is a **batch checker only**: incremental checking, watch mode, and
LSP are explicitly out of scope for it and come in future versions (§8).

Until then the project is pre-release: internal builds report
`ztsc 0.0.1-dev`, and finished milestones get history tags (`m6`, `m7`, …),
one commit per milestone. Every milestone still ships with **tests and
benchmarks** — nothing is "done" until its numbers are on the scoreboard.

### Why this is winnable

tsgo is fast but inherits Go's costs: GC headroom (heap typically 2× live
data), pointer-heavy AST/type objects with per-object headers, and a runtime.
Zig gives us: no GC, arena allocation with near-zero bookkeeping, and full
control of data layout (indices instead of pointers, struct-of-arrays,
bit-packed flags). Memory is where a Zig implementation wins big; speed
parity comes from the same parallelism playbook tsgo uses. M6's measured
result (§4) — ~0.25× tsgo's wall clock at 35% of its RSS on in-subset
corpora — validates the bet; the remaining question is holding it through
full TypeScript semantics (§5, M9 especially).

---

## 2. Architecture

### 2.1 Data-oriented AST (the foundation everything rests on)

Modeled after the Zig compiler's own AST:

- **No pointers anywhere in the AST.** Nodes are `u32` indices into flat
  arrays.
- **Struct-of-arrays (`std.MultiArrayList`)**: node tag, main token, and a
  fixed `{ lhs, rhs }` payload in parallel arrays; variable-length children
  in a shared `extra_data: []u32`.
- **Measured: 5 bytes/token, ~16 bytes/AST node** amortized (target was
  ≤ 24). Pointer-based ASTs (tsc, tsgo) run 100–200+ bytes/node.
- Line/column computed lazily from a line-offset table, never stored.
- **Strings interned once, globally**: text → `Atom` (`u32`); later phases
  compare atoms, never bytes. Atom 0 is the "none" sentinel.

### 2.2 Arena strategy (the memory story)

Rule: **allocation lifetime = phase lifetime, one arena per lifetime, no
per-object frees ever.**

| Arena | Contents | Lifetime |
|---|---|---|
| Per-file AST arena | tokens, nodes, extra_data, line table | process lifetime, *sealed* (read-only) after parse |
| Per-file binder arena | symbol table, scope tree, flow graph | sealed after bind |
| Per-checker type arena | interned types, relation cache | checker lifetime |
| Scratch arena | inference candidates, worklists | **reset per statement** (measured high-water: < 2 KB) |
| Diagnostics arena | messages, spans | until reporting |

- Sources are `mmap`'d read-only; text is never copied except into the
  interner.
- **Types are hash-consed**: structurally identical types share a `TypeId`
  (`u32`); freshness (literal/object) lives in the type identity so interning
  stays sound. Measured ~28 bytes/type.
- Caches key on `TypeId` pairs — small, dense, cheap to hash.
- Per-thread arenas: no locks in the allocation path, because there is no
  malloc path.

### 2.3 Parallelism (tsgo's playbook, adapted)

1. **Front-end** — per-file load/scan/parse/bind on a worker pool with
   **single-owner module discovery**: workers push `(file, import
   specifiers)` completions to a queue; the main thread (sole owner of the
   graph, no locks) resolves and enqueues discovered files immediately.
   Output order is graph-derived — byte-identical across `--workers` ×
   `--checkers`.
2. **Link** — cross-file symbol resolution into flat sorted tables, sealed;
   checker lookups are lock-free binary searches.
3. **Check** — the program's files partitioned across **N independent
   checker instances** (`--checkers=N`, default min(4, cores)). Each owns
   its type arena and caches and reads the shared immutable AST/binder data
   freely. Duplicated type construction is the price (measured: +15.5%
   types at N=4); zero-synchronization parallelism is the payoff.
   Diagnostics are byte-identical for any N (tested).

Immutability boundaries make this safe without locks: each phase's output is
frozen before the next phase reads it.

### 2.4 Module layout

```
src/
  main.zig          CLI driver, worker pool, phase orchestration
  source.zig        file loading (mmap), line tables, spans
  intern.zig        string interner (sharded, thread-safe)
  scanner.zig       tokenizer (full TS token set, rescan API)
  ast.zig           SoA node storage, S-expression dump
  parser.zig        recursive descent, error recovery, speculation
  binder.zig        symbols, scopes, control-flow graph
  modules.zig       module resolution, module graph, linking
  types.zig         TypeId, hash-consing, canonical unions
  checker.zig       assignability, inference, narrowing
  diagnostics.zig   error codes (tsc-compatible)
  render.zig        pretty diagnostics (tsc-style)
  tsconfig.zig      JSONC parser, globs, paths/baseUrl
bench/              e2e + per-phase harnesses, corpus generator
test/               conformance runner + differential cases vs tsc
```

---

## 3. Measurement infrastructure

Built first (M0), before any compiler code — you can't win a memory war
without a scoreboard.

- **Speed**: wall-clock vs `tsc` and `tsgo` (`bench/e2e.sh`), per-phase
  internal timers (`--timing`): lines/s, MB/s, per-checker breakdown.
- **Memory**: peak RSS via `/usr/bin/time -l` / `-v`, plus internal arena
  accounting (`--memory`): bytes/token, bytes/node, binder bytes/line,
  bytes/type, cache hit rates, scratch high-water.
- **Corpora**: deterministic generators (`bench/gen_corpus.js`) — small
  (~5k LOC), medium (~50k), multi (201 files / ~93k), skewed; real-world
  corpora arrive with M7's census.
- **Conformance**: differential testing against tsc — every case's expected
  diagnostics (code + line) generated from and verified against real tsc.
  180 cases as of M6, growing every milestone.
- **CI**: every merge runs tests; benchmark history in BENCHMARKS.md.

---

## 4. Development history (done)

Each milestone = one commit, tests + benchmarks included. Numbers are
Apple M4, ReleaseFast; see BENCHMARKS.md for methodology.

- **M0 — Skeleton & scoreboard** (`394faad`): build.zig, worker pool +
  per-thread arenas, sharded interner, mmap loading, bench harness,
  conformance skeleton, CI.
- **M1 — Scanner** (`71b16a5`): full TS token set (157 tags), tsc-shaped
  rescan API, SoA tokens at **5 bytes/token**; ~450 MB/s single-thread,
  ~2.5 GB/s at 8 workers; fuzz + byte-soup totality.
- **M2 — Parser + data-oriented AST** (`42d179d`): recursive descent with
  context-driven scanning and speculation, **16.2 bytes/node**; 10.5M
  lines/s single-thread, 53M at 8 workers; total on arbitrary input.
- **M3 — Binder** (`1509b37`): SoA symbols (~20 B/symbol), sealed sorted
  scope segments, tsc-style antecedent flow graph, import/export records;
  **29.5 bytes/line**; 12.7M lines/s single-thread.
- **M4 — Checker core** (`a64d4d9`): hash-consed types (**~26 B/type**),
  structural assignability + tri-state relation cache, inference,
  contextual typing, overload/generic resolution, flow narrowing,
  tsc-coded diagnostics; 150 conformance cases vs tsc 5.5.4; 2.1M lines/s.
- **M5 — Module graph + parallel check** (`79fcee4`): module resolution,
  lock-free link tables, N-checker partitioning with byte-identical output;
  180/180 conformance (30 multi-file); multi corpus 0.02 s / 72 MB vs
  tsc's 0.91 s / 314 MB.
- **M6 — Polish + benchmark report** (`3039da8`, tag `m6`): pretty
  diagnostics, tsconfig subset, exit codes, BENCHMARKS.md. **Gate passed
  vs tsgo 7.0.0-dev: ~0.25× wall, 35% RSS** (targets: ≤1.25×, ≤50%).
- **Single-owner module discovery** (`e3995a2`): wavefront barrier removed;
  completion-queue scheduler, graph-derived deterministic output; skewed
  corpus front-end wall −70%.

---

## 5. The road to the public v0.0.1

Four milestones. Order is deliberate: usefulness first (M7), then breadth
(M8), then the type-level core that real libraries demand (M9), then the
product surface (M10). Lessons from prior art bake the sequence: stc and
Ezno (Rust) died on tsc-compatibility, not performance — the differential
conformance discipline is non-negotiable as the surface grows.

### M7 — lib.d.ts + reality census

The single biggest usefulness unlock: without `Array.prototype.map`,
`Promise`, `fetch`, `console`, no real file checks.

- Trimmed ES-core lib (`Object/Array/String/Number/Promise/Map/Set/RegExp/
  Error/JSON/Math/Symbol`, iterables, `console`, timers) loaded through the
  existing `.d.ts` path, **embedded in the binary** (`@embedFile`) so the
  eventual `bunx` binary is self-contained. Globals bind lazily so
  cold-start stays tiny. `bun-types`/`@types/node` load as ordinary
  node_modules packages when present.
- **Census tool**: parse the top few hundred npm packages + real Bun repos
  (Elysia, Hono, Zod, Drizzle apps); count which unsupported constructs
  block parse/bind/check, by frequency. The output table decides M8/M9
  implementation order — spec order is not the priority order.
- The long-deferred **~500k-LOC real-world corpus** finally lands (real
  code becomes checkable once lib types exist).
- **Tests**: conformance cases exercising lib types (array methods,
  promise chains, iterables) vs tsc. **Benchmarks**: lib loading cost
  isolated; large-corpus wall + RSS vs tsc/tsgo.

### M8 — semantic breadth (the boring 80%)

Everything common that isn't type-level programming, in census order.
Expected contents: enums (incl. `const enum`), namespaces + declaration
merging (interface/namespace/class), getters/setters, `abstract` classes,
`this` typing, `symbol`/`unique symbol`, async/await/`Promise` return
typing, generators, user-defined type guards (`x is T`) + assertion
functions, `satisfies`, `as const`, module augmentation, triple-slash refs,
JSX typing (Bun runs frontends too — via the `JSX` namespace).

- **Tests**: conformance grows toward ~500 cases, every feature
  differential vs tsc. **Benchmarks**: regression gates — memory/wall
  budgets must not drift as semantics widen.

### M9 — the type-level core (make-or-break)

Conditional types + `infer` + distributivity, mapped types (+ `as` key
remapping), template-literal types, recursive type aliases, generic indexed
access, `keyof` over mapped types. This is what the `.d.ts` files of Zod,
Drizzle, Hono, and Elysia are made of — the features your *dependencies*
choose for you.

- **Architecture rule learned from tsc's own pain**: instantiation caching
  keyed on `(target, type-args)` from the first conditional type, plus
  tsc-compatible depth/count limits. Hash-consing is the memory defense;
  laziness is the speed defense. This milestone is where the ≤50%-of-tsgo
  memory goal is genuinely at risk — measured continuously, on type-heavy
  real corpora (zod/drizzle-style), not synthetic ones.
- **Tests**: type-level torture conformance vs tsc + real `.d.ts` files
  from top libraries checked identically. **Benchmarks**: types/line, RSS,
  and instantiation counts on type-heavy corpora.

### M10 — ship it: bunx distribution + release

Batch checking only — no watch mode, no LSP (post-v0.0.1, §8).

- **Distribution**: npm package `ztsc` with prebuilt platform binaries via
  `optionalDependencies` (the esbuild pattern) so **`bunx ztsc` works
  cold** — macOS/Linux × x64/arm64, cross-compiled by Zig in CI. Linux
  benchmark numbers land here too.
- **Real-world validation**: N real open-source Bun projects check with
  diagnostics matching tsc (differential, wrong answers = release
  blockers).
- **Release gate (the whole point)**: on real projects, macOS *and* Linux —
  wall within 1.25× of tsgo, **peak RSS ≤ 50% of tsgo**, conformance green.
  Then, and only then: tag **v0.0.1**, publish to npm.

---

## 6. Current checked subset (as of M6)

**In:** primitives + literal types, `unknown`/`any`/`never`/`void`;
objects, interfaces (incl. `extends`), type aliases, arrays, tuples;
unions & intersections, discriminated unions; functions (param/return
inference, optional/default/rest, declared-overload resolution); generics
(declarations, explicit instantiation, basic inference from arguments);
classes (fields, methods, `implements`/`extends`, visibility); control-flow
narrowing (truthiness, `typeof`, `===`/`!==`, `in`, `instanceof`,
discriminants, assignments); `keyof`, non-generic indexed access, `typeof`
queries; ES modules incl. type-only imports, `.d.ts` reading; strict-mode
semantics only (strictNullChecks always on).

**Not yet** (queued in §5): `lib.d.ts` (M7); enums, namespaces, declaration
merging, getters/setters divergence, `this`-typing, async/Promise typing,
`satisfies`, `as const`, JSX, decorators (M8); conditional, mapped, and
template-literal types, `infer` (M9). Unsupported syntax produces a clear
"not supported" diagnostic — never a wrong answer or a crash (fuzzed at
every phase).

---

## 7. Risks & mitigations

- **TS semantics rabbit holes** → differential testing against tsc for
  every feature; match observable behavior. stc/Ezno are the cautionary
  tales; tsgo (a faithful port) is the success story.
- **M9 instantiation explosion vs the memory goal** → instantiation caching
  + depth limits from day one; continuous RSS measurement on type-heavy
  real corpora; hash-consing.
- **Checker duplication overhead grows with N** → it's a measured dial;
  long-term option: a shared immutable interner for simple types,
  per-checker arenas for the rest.
- **Zig 0.16 std churn** → version pinned in build.zig.zon and CI; upgrade
  deliberately. (Known: custom pool over `Thread.spawn`, `std.Io.Mutex`,
  `std.Io.Clock`, `Io.File.MemoryMap`; `std.testing.fuzz` takes `*Smith`;
  one cosmetic "failed command" line from an upstream test-runner bug.)
- **Synthetic corpora flatter us** → M7's census + real corpora make the
  benchmark story honest before anything is published.

---

## 8. Post-v0.0.1 (deliberately out of the first release)

- **Incremental checking + watch mode** — the flagship follow-up:
  types-first-inspired incrementality (per-file interface signatures cut
  the dependency graph; a body edit that doesn't change the signature
  re-checks one file). Target: warm re-check of one edit on the multi
  corpus in low double-digit ms.
- **LSP** — builds on the incremental substrate above; the sealed-phase
  architecture and single-owner discovery were chosen not to preclude it.
- **Windows** support and benchmarks.
- **`--fix`-style quick suggestions** (TS2551 "did you mean" already
  exists; expand).
- **Shared simple-type interner** across checkers (memory dial, §7).
- **Incremental persistence** (on-disk graph cache for CI cold starts).
