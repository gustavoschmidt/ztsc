# ZTSC — A TypeScript Checker in Zig

**ZTSC** = Zig TypeScript Checker. (Note: `tsc` officially stands for *TypeScript
Compiler* — it checks *and* emits JS. ZTSC only checks, so "Checker" is the honest
name for this project.)

## 1. Goals

For **v0.0.1**, on a defined TypeScript subset (§5):

1. **Speed — same order as TypeScript 7 (`tsgo`).** Matching tsgo's throughput on
   equivalent workloads is success; beating it is a bonus, not a requirement.
2. **Memory — decisively lower than tsgo.** This is the headline goal. Target:
   **≤ 50% of tsgo's peak RSS** on the same workload, tracked as a first-class
   benchmark from day one.
3. **Parallel from the start.** The architecture is designed for multi-core in
   milestone 0, not retrofitted later.

### Non-goals (for now)
- JS emit, declaration (`.d.ts`) emit, source maps.
- Full TypeScript semantics (see subset, §5).
- Language service / LSP, watch mode, incremental builds. (The architecture
  shouldn't preclude them, but they are not v0.0.1.)
- JSX, decorators, JS-file checking (`checkJs`).

### Why this is winnable
tsgo is fast but inherits Go's costs: GC headroom (heap is typically 2× live
data), pointer-heavy AST/type objects with per-object headers, and a runtime.
Zig gives us: no GC, arena allocation with near-zero bookkeeping, and full
control of data layout (indices instead of pointers, struct-of-arrays,
bit-packed flags). Memory is where a Zig implementation can win big; speed
parity comes from the same parallelism playbook tsgo uses.

---

## 2. Architecture

### 2.1 Data-oriented AST (the foundation everything rests on)

Model after the Zig compiler's own AST (a proven design):

- **No pointers anywhere in the AST.** Nodes are `u32` indices into flat arrays.
- **Struct-of-arrays (`std.MultiArrayList`)**: node tag, main token, and a fixed
  small payload (`{ lhs: u32, rhs: u32 }`-style) live in parallel arrays.
  Variable-length children (argument lists, union members, object members) go
  into a shared `extra_data: []u32` side array.
- **Target: ~16–24 bytes per AST node** amortized. For comparison, pointer-based
  ASTs (tsc, tsgo) run 100–200+ bytes/node. This alone is a large chunk of the
  memory win.
- Token stream is also SoA: `tag: u8` + `start: u32` arrays. Line/column is
  computed lazily from a line-offset table, never stored per token.
- **Strings are interned once, globally**: identifier/string-literal text →
  `Atom` (`u32`). All later phases compare atoms, never bytes.

### 2.2 Arena strategy (the memory story)

Rule: **allocation lifetime = phase lifetime, one arena per lifetime, no
per-object frees ever.**

| Arena | Contents | Lifetime |
|---|---|---|
| Per-file AST arena | tokens, nodes, extra_data, line table | until end of process (checker reads it) — but *sealed* (read-only) after parse |
| Per-file binder arena | symbol table, scope tree, flow graph | sealed after bind |
| Per-checker type arena | interned `Type` objects, type relations cache | lives for the checker's lifetime |
| Scratch arena | inference candidates, temporary type lists, worklists | **reset per statement / per check entry point** — this is where churn goes to die |
| Diagnostics arena | error messages, related spans | until reporting |

Key points:
- Source file bytes are `mmap`'d read-only; the AST references them by offset.
  We never copy source text except into the string interner.
- **Types are hash-consed** (interned): structurally identical types get the
  same `TypeId` (`u32`). Type objects are immutable after creation, allocated
  from a bump arena, and never freed individually. Deduplication is both a
  speed win (identity comparison for common cases) and a memory win.
- Caches (assignability results, instantiations) use `TypeId` pairs as keys —
  small, dense, cheap to hash.
- Per-thread arenas mean **zero allocator contention** — no locks in the malloc
  path, because there is no malloc path.

### 2.3 Parallelism (tsgo's playbook, adapted)

Pipeline with three phases; parallelism model differs per phase:

1. **Parse** — embarrassingly parallel. Thread pool (`std.Thread.Pool`),
   one task per file, each task owns its file arenas. No shared mutable state
   except the concurrent string interner (sharded lock or lock-free).
2. **Bind** — also per-file parallel. Binder output (symbols, scopes, flow
   nodes) is sealed immutable afterward. Cross-file module resolution runs
   after all binds complete (cheap, mostly serial graph walk).
3. **Check** — tsgo's key trick: partition the program's files across **N
   independent checker instances** (tsgo uses 4). Each checker has its own type
   arena and caches, and reads the shared immutable AST/binder data freely.
   Duplicated type construction across checkers is the price; embarrassing
   parallelism with no synchronization is the payoff. N is tunable — and this
   is our main speed/memory dial (more checkers = faster, more duplicate
   types = more memory). We benchmark N ∈ {1, 2, 4, 8} from the start.

Immutability boundaries make this safe without locks: parse output is frozen
before bind reads it; bind output is frozen before check reads it.

### 2.4 Module layout

```
src/
  main.zig          CLI driver, thread pool, phase orchestration
  source.zig        file loading (mmap), line tables, spans
  intern.zig        string interner (sharded, thread-safe)
  scanner.zig       tokenizer
  ast.zig           node definitions, SoA storage
  parser.zig        recursive-descent parser → ast
  binder.zig        symbols, scopes, control-flow graph
  types.zig         Type representation, TypeId, hash-consing
  checker.zig       assignability, inference, narrowing, diagnostics
  diagnostics.zig   error codes, rendering
bench/              benchmark harness + corpora manifests
test/               unit tests + conformance suite runner
```

---

## 3. Measurement infrastructure (built FIRST, in M0)

You can't win a memory war without a scoreboard. Before any compiler code:

- **Speed**: `hyperfine` wall-clock comparisons of `ztsc` vs `tsc` vs `tsgo` on
  the same corpus; plus internal per-phase timers (`--timing` flag) reporting
  parse/bind/check ms and lines/sec.
- **Memory**: peak RSS via `/usr/bin/time -l` (macOS) / `/usr/bin/time -v`
  (Linux), plus internal accounting — every arena reports bytes used, so
  `--memory` prints a table: bytes/node, bytes/type, bytes/line of source.
- **Corpora**: checked-in benchmark projects at three sizes — small (~5k LOC),
  medium (~50k LOC), large (~500k LOC, e.g. a filtered snapshot of a real
  codebase restricted to our subset). Synthetic generators for stress cases
  (deep unions, wide object types, many files).
- **Conformance**: differential testing against `tsc` — a runner that feeds each
  test case to both and diffs the diagnostics (error code + span). Cases live in
  `test/conformance/` as plain `.ts` files with expected-diagnostics snapshots.
- **CI**: every merge runs tests + benchmarks; speed/memory regressions beyond a
  threshold fail the build. Benchmark history tracked in-repo (a simple JSON
  log is fine to start).

---

## 4. Milestones

Every milestone ships with **tests and benchmarks** — no phase is "done" until
its numbers are on the scoreboard.

### M0 — Skeleton & scoreboard
- `zig init` project, `build.zig` with `test` + `bench` steps, CI.
- Benchmark harness (§3): hyperfine wrappers, RSS capture, `--timing`/`--memory`
  flags plumbed, corpora downloaded/generated, conformance runner comparing
  against `tsc` (initially with zero passing cases — that's fine).
- Thread pool + per-thread arena scaffolding, string interner.
- **Tests**: interner correctness under concurrency; arena accounting.
- **Benchmarks**: interner throughput; baseline `tsc`/`tsgo` numbers recorded
  for all corpora (our targets, written down).

### M1 — Scanner
- Full TS token set (we scan all of TS even though we check a subset — parsing
  errors on unsupported syntax should be graceful).
- **Tests**: golden token-stream tests; fuzz the scanner (Zig's built-in fuzzer)
  — must never crash on arbitrary bytes.
- **Benchmarks**: MB/s single-thread; scaling curve 1→8 threads; bytes/token.

### M2 — Parser + data-oriented AST
- Recursive descent, covering the full *syntax* of our subset + error recovery.
- SoA AST per §2.1; AST is sealed after parse.
- **Tests**: parse-tree golden tests (S-expression dumps); round-trip span
  checks; fuzzing; error-recovery cases.
- **Benchmarks**: lines/sec parse; **bytes per AST node** (the key memory
  metric — target ≤ 24); multi-file parallel parse scaling.

### M3 — Binder
- Symbol tables, scope chains, hoisting, import/export records,
  control-flow graph nodes for narrowing.
- **Tests**: scope-resolution goldens; duplicate-identifier diagnostics vs tsc.
- **Benchmarks**: bind lines/sec; binder bytes/line; parallel scaling.

### M4 — Checker core (single-threaded correctness first)
- Type representation + hash-consing (§2.2), the subset's type constructors.
- Structural assignability, variable/function type inference, literal widening,
  control-flow narrowing (truthiness, `typeof`, equality, discriminated unions).
- Diagnostics with tsc-compatible error codes where feasible.
- **Tests**: the conformance suite becomes the driver — port/curate a few
  hundred cases from tsc's test suite restricted to the subset; differential
  runs against tsc must match on code+span.
- **Benchmarks**: check lines/sec; bytes/type; types created per line;
  cache hit rates.

### M5 — Parallel check + module graph
- Multi-file programs, module resolution (relative paths + `node_modules`
  main-fields subset), `.d.ts` reading for the subset.
- N-checker partitioning per §2.3.
- **Tests**: multi-file conformance cases; determinism test — diagnostics must
  be byte-identical regardless of N (ordering normalized).
- **Benchmarks**: end-to-end wall clock vs `tsc` and `tsgo` on all corpora at
  N ∈ {1,2,4,8}; peak RSS vs both; the speed/memory curve documented.

### M6 — v0.0.1 release
- Acceptance gate: on medium + large corpora, **wall clock within 1.25× of
  tsgo** and **peak RSS ≤ 50% of tsgo**; conformance suite green.
- Polish: pretty diagnostics, `--pretty`, exit codes, `tsconfig.json` subset
  (`strict`, `include`/`exclude`, `paths` minimal).
- Write-up of the numbers (bytes/node, bytes/type, scaling curves) — the
  benchmark story *is* the release.

---

## 5. TypeScript subset for v0.0.1

Chosen to be big enough that real code type-checks, small enough to ship.

**In:**
- Primitives, literal types, `unknown`/`any`/`never`/`void`.
- Object types, interfaces (incl. `extends`), type aliases, arrays, tuples.
- Unions & intersections; discriminated unions.
- Functions: parameter/return inference, optional/default/rest params,
  arrow functions, overload *resolution* (declared overloads).
- Generics: declarations, explicit instantiation, and basic inference from
  arguments (no higher-order inference tricks).
- Classes: fields, methods, `implements`/`extends`, visibility modifiers
  (single inheritance, no abstract-class edge cases beyond the basics).
- Control-flow narrowing: truthiness, `typeof`, `===`/`!==`, `in`,
  discriminant checks, assignment narrowing.
- `keyof`, indexed access `T[K]` (non-generic-key cases), `typeof` (value→type).
- ES modules: `import`/`export`, type-only imports.
- `strict` mode semantics only (strictNullChecks always on — simpler *and*
  it's what everyone should use).

**Out (v0.0.1):** conditional types, mapped types, template-literal types,
`infer`, declaration merging, namespaces, enums, decorators, JSX, `satisfies`,
const-type-parameters, symbol/unique-symbol, getters-setters divergence,
`this`-typing edge cases, module augmentation, triple-slash refs.

The subset boundary must be *explicit in code*: unsupported constructs produce
a clear "not supported in ztsc v0.0.1" diagnostic, never a wrong answer or
crash.

---

## 6. Risks & mitigations

- **TS semantics rabbit holes** (even the subset — narrowing and inference
  interact subtly). → Differential testing against tsc from M4 day one; when in
  doubt, match tsc's observable behavior, not the spec-as-imagined.
- **Corpus availability** — big real-world code that stays inside the subset is
  rare. → Filtered snapshots + a synthetic generator; grow the subset toward
  what real corpora need.
- **Checker parallelism duplicating too many types** (memory goal vs speed
  goal). → It's a measured dial (N checkers); the benchmark suite reports both
  axes so we choose with data. Long-term option: share a global immutable
  interner for *simple* types, per-checker arenas for the rest.
- **Zig 0.16 churn** — std lib APIs move. → Pin the Zig version in
  `build.zig.zon` / CI; upgrade deliberately.

---

## 7. Order of work (immediate next steps)

1. M0: `zig init`, build steps, thread pool, interner, benchmark harness.
2. Record baseline `tsc` + `tsgo` numbers on the corpora → targets in repo.
3. M1 scanner.
