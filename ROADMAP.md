# ZTSC — Roadmap

**ZTSC** = Zig TypeScript Checker. (`tsc` officially stands for *TypeScript
Compiler* — it checks *and* emits JS. ZTSC only checks, so "Checker" is the
honest name.)

This is the project's single document: goals, architecture, development
history, and the work list. (It absorbed the original PLAN.md on 2026-07-12;
the milestone history in §4 preserves that plan's record. Milestones were
renumbered linearly on 2026-07-13 — see the mapping note at the top of §5;
commit messages before that date use the old numbers.)

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
**v0.0.1**, ships only when the whole M11–M17 sequence below is done. Its
definition is exactly this: a user runs **`bunx ztsc <root-files>`** and
ztsc type-checks those files and *everything they depend on* — including
libraries — with most of TypeScript's functionality, fast and with low
memory usage. That headline is the release. It will have bugs; it will not
feel like a toy.

**Backend code is a first-class v0.0.1 target** (decision 2026-07-13):
real backend projects depend on `@types/node`, whose declarations are
built on cross-file global/namespace merging — which is why the
global-symbol layer (M11) leads the remaining work rather than trailing
it.

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
full TypeScript semantics (§5, M16 especially).

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
   checker lookups are lock-free binary searches. (After M11 this phase
   also owns declaration merging — see §5; link is serial, so the merge is
   deterministic by construction.)
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
  corpora arrive with M13's census.
- **Conformance**: differential testing against tsc — every case's expected
  diagnostics (code + line) generated from and verified against real tsc
  (5.5.4). 180 cases at M6, **297 as of M10**; grows every milestone.
- **CI**: every merge runs tests; benchmark history in BENCHMARKS.md.

---

## 4. Development history (done)

Each milestone = one commit, tests + benchmarks included. Numbers are
Apple M4, ReleaseFast; see BENCHMARKS.md for methodology. (Commits made
before the 2026-07-13 renumbering reference the old milestone numbers —
e.g. "M11i" for what is now part of M10; the §5 mapping note decodes
them.)

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
- **M7 — Quick wins: memory & perf debt** (`6d9f778`, tag `m7`): all six
  fixes (duplicate token scan, seal-parser-into-exact-size, resolution
  scratch arena, linker sort, object-construction quadratics, resolveStem
  cap). **Heap RSS −53% medium / −60% multi**, time equal-or-better.
- **M8 — Contextual re-check cache** (`77acca4`, tag `m8`): fixed
  context-blind `node_types` *and* `sig_cache` (spurious TS2769 on overload
  argument trials); `{ty, ctx}` discriminator; `flow_cache`/`da_cache`
  audited sound. Conformance 180 → 182; check-phase flat.
- **M9 — Embedded lib phase** (commits reference "M9/M10"). Decision
  (2026-07-12): build a minimal real lib first so the shared-lib substrate
  has measurable gates, deferring the substrate itself (now M12) until the
  lib is real-sized. Landed: **lib-core** (`dd6fcbb`) — embedded ES-core
  `lib.d.ts`, global-symbol table, `resolveSpace` fallback, array/primitive→
  interface bridge, `--noLib`; **lib-grow** (`0721986`) — real ES-core
  surface (constructor globals, Map/Set/Date as `declare class`), fixed a
  merged value+type global resolving to `any`; **cost-based check
  partition** (`1536ba3`) — greedy-by-node-count, skewed −26% / bigfan 2.4×,
  determinism preserved. Conformance 182 → 200. Deferred to future
  milestones: resolution cache + census + real corpus (M13), substrate
  (M12).
- **M10 — Semantic breadth** (commits reference "M11"). Ten features
  landed, each differential-tested vs tsc 5.5.4, `--noLib` hot path flat:
  **enums** (`2c43581`), **accessors + abstract** (`f1ae28e`), **`as
  const` + `satisfies`** (`c009ff3`), **type guards + assertion functions**
  (`d3c2304`), **namespaces + within-file merging** (`7ede24a`),
  **async/await/Promise + basic generators** (`acb08ea`), **`Symbol.iterator`
  iteration protocol** (`24d0447` — `for…of`/spread over Map/Set/generators/
  user iterables via `[Symbol.iterator]()`; bare `Iterator<T>` correctly not
  iterable), **ambient namespace implicit export** (`c69193f` — `declare
  namespace` members visible as `N.member` without `export`, also fixing
  function+ambient-namespace merged property access), **`Symbol` global**
  (`8037ead` — callable + well-known symbols via interface+function+namespace
  merge, closing the value-`Symbol` gap), **JSX typing** (`.tsx`) — scanner
  `scanJsxChild`, additive parser/AST for elements/fragments/attributes/
  expression containers, and checker typing: intrinsic tags via
  `JSX.IntrinsicElements[tag]`, component tags via their first parameter,
  attributes checked as an object assigned to props (TS2322/2741/2339),
  result `JSX.Element`. `symbol` primitive + `typeof` narrowing already
  worked. Conformance 200 → 297. **JSX subset caveats:** `-` in JSX names
  (`data-*`/`aria-*`) and class-component props are best-effort/deferred; a
  `JSX` namespace must be in scope. The sealed-bind foundation for
  cross-file merging landed here (commit-tagged "M11e-1"); the layer
  itself is M11.

---

## 5. The road to the public v0.0.1

Seven milestones remain (M16 split into four sub-milestones M16a–d).
Renumbered linearly on 2026-07-13 after the backend-first decision pulled
cross-file declaration merging to the front. **Old → new mapping** for
reading pre-2026-07-13 commits and notes: old M9 substrate → **M12**; old
M10 open items (census, real corpus, resolution cache) → **M13**; old M11
open items → **M11** (cross-file merging, module augmentation,
triple-slash) and **M14** (unique symbol, JSX polish, this-typing,
decorators); old M12 → **M15**; old M13a–d → **M16a–d**; old M14 → **M17**.

Order rationale: M11 first because `@types/node` gates the backend goal
and everything real depends on it; M12 (substrate) immediately after,
because `@types/node`-sized inputs finally make its gates measurable and
its shared type store keeps N-checker RSS sane on huge `.d.ts`; M13 makes
the corpus story honest; M14 finishes semantic breadth; M15 lands the
caching discipline that de-risks the type-level core; M16 is the
make-or-break type-level core; M17 ships. Lessons from prior art bake the
sequence: stc and Ezno (Rust) died on tsc-compatibility, not performance —
the differential conformance discipline is non-negotiable as the surface
grows.

Several sections below carry `file:~line` references verified at commit
`6aa155f` (2026-07-12 architecture review) — they drift; search for the
named function when in doubt.

### M11 — Cross-file declaration merging + module augmentation (the global-symbol layer)

**Why this is first (decision 2026-07-13).** v0.0.1 must check real
backend projects, and `@types/node` is the gate: it reopens `declare
global` and `namespace NodeJS` across dozens of `.d.ts` files, wired
together with triple-slash references and ambient `declare module "fs"`
blocks. Without cross-file merging, any project whose type graph touches
`@types/node` — nearly every real project — fails immediately. The same
layer unblocks `@types/react`'s `JSX` namespace (the deferred JSX-polish
item), test-runner globals (`@types/jest`), and lodash-style module
augmentation. In *app source* the syntax is rare (typically one
`globals.d.ts`), which is exactly what the design exploits: the common
path must not pay for it.

**What already works, and the constraints (verify in code; refs drift):**

- *Within-file* merging works: the binder reuses the symbol and a shared
  members scope on a legal re-declaration; its `excludes` masks encode
  which symbol-flag combinations may merge (binder.zig — declare/merge
  masks ~209–231, shared members scope ~781/1818, merged namespace body
  scopes ~360/1845).
- *Across-import* merging propagates for free: the merge happened within
  one file before export, so the imported symbol carries all members.
- The linker maps each name to a single `Target{kind, file, payload}`
  (modules.zig:~69) — a resolution arrow, with no representation for
  "name = merge of declarations in files X, Y, Z".
- `collectGlobals` (modules.zig:~240) harvests only the *lib* file's
  top-level scope into `Program.globals` (flat sorted `atom → global
  sym`); user files' global-scope declarations are never collected.
- Symbol identity: global id = `sym_base[file] + local id`
  (modules.zig:~190–224); ids index into per-file **sealed** `Bind`s.
- Phase order: parallel bind → **serial link** → N concurrent checkers
  reading sealed data with no locks on the check path.

**Design (settled 2026-07-13 — these are the invariants; an implementer
should not trade them away):**

1. **Merge symbols, never types.** Declaration merging is a symbol-table
   operation completed at link time, before any checker runs. Checkers
   then materialize types lazily from the merged symbol's declaration
   list, immutable and hash-consed exactly as today. Nothing is mutated
   after seal; the zero-lock check phase survives unchanged.
2. **Overlay, not relocation.** Per-file `Bind`s stay sealed and alive as
   the source of truth. The global layer is a link-arena overlay that
   references into them by `(file, sym)` pairs. Never copy declarations
   into a new arena and discard the originals — symbol ids are file-local
   indices and every reference everywhere would need remapping.
3. **Pay-per-use.** The binder emits a per-file *global-contribution*
   slice; for a typical app module it is empty and the linker skips the
   file entirely. Only the lib, `@types` files, script files, and
   `declare global`-bearing files reach the merge path.
4. **Determinism by construction.** The merge runs in the serial link
   phase, folding contributions in **FileId order** (graph-derived,
   scheduling-independent). No dependency on deterministic atoms (M12.1):
   the result is a pure function of file order and atom *values*;
   run-to-run atom-id variation only permutes internal sort order, which
   is invisible because diagnostics are ordered by file/span.
5. **Fast path unchanged.** In the program global table a name maps to
   either a single `(file, sym)` — structurally identical to today's lib
   global, the overwhelmingly common case — or a **merged symbol**: a new
   id in a program-level range (`id ≥ totalSymbols()` indexes a merge
   table) carrying (a) the constituent `(file, sym)` list and (b) a
   **pre-materialized member index** — one sorted `(atom → (file, sym))`
   slice built once at link — so checker property lookup stays a single
   binary search over one sorted slice, never a k-way search.
   `expandRef` and the expansion caches key on symbol ids, so merged ids
   memoize per checker with no cache changes.
6. **One mechanism, three clients.** `collectGlobals`'s lib special case
   becomes the trivial instance: the lib file is just the first
   contributor with a big slice. Module augmentation (M11c) reuses the
   same harvest/merge machinery keyed by resolved-specifier atom instead
   of the global scope, merged into the export tables `lookupExport`
   consults. And M12.3's shared frozen type store specializes the same
   layer — a lib/merged symbol expanded once and shared is the point of
   both; design the merge-table representation with that reuse in mind.

**Phased plan (each phase lands separately, differential-tested vs tsc;
diagnostic codes below are expectations — the differential harness is
authoritative, verify each against tsc 5.5.4):**

- **M11a — harvest + global interface merge. ✅ DONE (2026-07-13).**
  Landed: `declare global { … }` parsing (parser.zig, reusing the namespace
  body machinery via a `global_aug` flag); binder script-vs-module
  classification (`Bind.is_module`) + a sorted harvest slice
  (`Bind.global_atoms`/`global_syms`) — whole file scope for a script/the
  lib, `declare global` block members (bound into one shared per-file
  scope) for a module; `mergeGlobals` folding every harvest slice in FileId
  order into `Program.globals` + `Program.merged` (merged-range ids
  ≥ `totalSymbols()`); checker routing of merged ids through the merge
  table (`reprSym`, merged-aware `symFlags`/`symNameAtom`/`declsOf`, and
  `interfaceGeneric` folding each constituent's members in its own file
  context). Differential-tested against tsc 5.5.4 (5 fixtures under
  `test/conformance/global_merge/`: interface merged across 2 and 3 module
  files, a global `var`/`function` used cross-file, within-block interface
  reopen, and lib `String` augmentation). Zero benchmark regression —
  modules contribute empty slices and the merge path is skipped
  (invariant 3).
  **Deferred to a follow-up / M11b:** cross-file *conflict* diagnostics
  (TS2300/TS2403/TS2717 — TS2403/TS2717 are type-level, a checker not a
  linker concern); TS2669 placement enforcement; cross-file type-parameter
  unification for generic-interface augmentation (e.g. `Array<T>`); the
  pre-materialized merged-member index (not needed until namespace member
  lookup in M11b — interface property lookup already collapses to a single
  object type); script-file cross-file merge that is not reachable through
  import discovery (needs triple-slash refs, M11c).
  - *Binder:* script-vs-module classification (any `import`/`export` ⇒
    module; expose a flag on `Bind`). Emit the harvest slice: sorted
    `(atom → local sym)` of global contributions — the whole top level
    for script files (and the lib); the contents of `declare global
    { … }` blocks for modules. Bind `declare global` bodies into a
    dedicated scope so members are harvestable without leaking into the
    file's local scope; enforce tsc's placement rules (top level of a
    module, ambient context — TS2669 when misplaced).
  - *Linker:* generalize `collectGlobals` into a fold over all non-empty
    harvest slices in FileId order. Single contributor for a name ⇒
    direct `(file, sym)` (today's representation); multiple ⇒ allocate a
    merged symbol (id above `totalSymbols()`, entry in the program merge
    table), applying per-kind legality cross-file with the same
    semantics as the binder's excludes masks. Emit merge diagnostics
    (TS2300 duplicate identifier, TS2403 subsequent variable
    declarations must have the same type, TS2717 subsequent property
    declarations must match). Materialize each merged interface's
    member index into the link arena.
  - *Checker:* audit every `global sym → (file, local)` path to route
    merged-range ids through the merge table — `prog.globals.lookup`
    consumers (`resolveSpace` fallback checker.zig:~714, iface/Promise/
    Iterator lookups ~3075–3111), property lookup, `expandRef` symbol
    resolution. Add a debug assert on `sym_base`-indexing helpers that a
    merged-range id can never reach them.
  - *Gate:* fixtures — `interface Global` split across 2–3 script files;
    `declare global` in a module; var and var+type collisions;
    conflicting member types; a global var whose type is a cross-file
    merged interface. All diagnostics matching tsc.
- **M11b — recursive namespace merge + kind combinations. ✅ DONE
  (2026-07-13).** Landed: `MergedSym.members` — a merged member index
  (atom → global sym, itself possibly merged) built recursively at link by
  `modules.Merger` (`mergeSet`/`buildNsMembers` fold each contributor's
  namespace body scope, allocating nested merged ids below the parent's).
  Checker resolves namespace members through it: `namespaceMemberSym`
  (used by `typeFromQualifiedName` and `resolveTypeNamespace`) and the
  merged branches of `classStaticType` (value members) and
  `computeTypeOfSymbol` (merged-namespace value object anchored to the
  merged id, intersected with a function/enum/class constituent for
  cross-file kind combos). Differential-tested vs tsc 5.5.4 (conformance
  302 → 305): mini-`NodeJS` namespace reopened across 3 files with nested
  interfaces merged across subsets; a global `function` merged with a
  `namespace`; a doubly-nested namespace (`Outer.Inner`) merged across
  files. Zero benchmark regression. Deferred: cross-file class+namespace
  static-member merge (within-file works; the value side would need the
  class constituent's statics folded into the index — rare); conflict
  diagnostics still deferred with M11a.
  - The link merge becomes a **recursive fixpoint**: a merged namespace's
    member index may itself contain merged symbols (`namespace NodeJS`
    reopened in several files, with a nested interface itself declared in
    two of them, or nested namespaces). Reuse the M11a merged-symbol
    representation recursively; reference each contributor's namespace
    body scope in its own `Bind` (the within-file precedent is
    binder.zig's namespace-symbol → merged-body-scope table, ~360).
  - Cross-file class+namespace / function+namespace / enum+namespace:
    the value side keeps the primary declaration's `(file, sym)`; the
    namespace contributions extend the merged member index. The
    within-file `Symbol` global (interface+function+namespace,
    `8037ead`) is the single-file template for the semantics.
  - *Gate:* a hand-written multi-file mini-`NodeJS` fixture — namespace
    reopened in 3 files, a nested interface merged across 2 of them, a
    global function merged with a namespace — matching tsc.
- **M11c — module augmentation + wildcard modules + triple-slash refs.
  ✅ DONE (2026-07-13).** Landed: `declare module "spec" { … }`
  parsing (parser, `ambient_module` flag) → `Bind.ambient_modules` (a
  per-block body scope). The linker builds a program ambient/augmentation
  registry (`Linker.ambient`: specifier atom → export table from each
  block's `export`ed members) after the per-file export tables; a
  named/default import resolves against the on-disk module first, then the
  ambient module of the same specifier — so `declare module "fs"` supplies
  an *unresolved* specifier (TS2307 suppressed) and augments a *resolved*
  one (bare packages; relative-spec augmentation keys on the string, an
  accepted deviation). Wildcard patterns (`declare module "*.css"`) match
  via `ambientKey`. **Triple-slash** `/// <reference path=… />` /
  `<reference types=… />` are scanned from the leading trivia
  (`modules.scanReferences`/`resolveReference`) and surfaced to *both*
  discovery paths (`buildProgram` and main.zig's single-owner scheduler,
  where reference targets also join the BFS edge list for deterministic
  renumbering) as extra program inputs. Differential-tested vs tsc 5.5.4
  (conformance 305 → 310): ambient `"fs"` (named import + TS2305/TS2307),
  augmenting a real bare package, a named-export wildcard module, a `path`
  reference pulling in a `declare global` file, and a `types` reference
  pulling in a `@types/*` package that provides an ambient module.
  Ambient blocks also support `export default` (declaration and bare-ident
  forms, resolved in the block scope — the CSS `export default` idiom) and
  named `export { … }` lists (conformance 310 → 312), and `import * as ns`
  namespace imports of an ambient module build a namespace object from its
  sealed export table (`Program.ambient_exports` + `Target.ambient_ns`).
  Only `export =` (CommonJS) and re-exports *from another module* inside an
  ambient block remain out of subset.
  - `declare module "pkg" { … }` inside a module file: harvest keyed by
    the *resolved* specifier's FileId (resolution already happens at
    discovery); at link, merge the block's exports into that module's
    export table via the same merged-symbol machinery — `lookupExport`
    consults the overlay first. `declare module` for unresolvable
    specifiers declares a synthetic ambient module target (this is how
    `@types/node` provides `"fs"` et al.). Wildcard declarations
    (`declare module "*.css"`) add a glob fallback to specifier
    resolution.
  - Triple-slash `/// <reference path=…/>` / `<reference types=…/>`:
    the scanner drops comments as trivia today — capture directives in
    the leading trivia before the first token and surface them to module
    discovery as extra program inputs (a main.zig single-owner-scheduler
    / modules.zig discovery concern, not a parser feature). `@types/node`
    uses these internally between its own files.
  - *Gate:* augment an imported module's interface from app code; a
    wildcard CSS module; `reference types` pulling in a package —
    matching tsc.

**Acceptance test (the milestone's whole point):** vendor a pinned
snapshot of `@types/node` (checked into the repo or fetched at a pinned
version by a script) and typecheck a small real backend program —
`process.env`, `Buffer`, `fs`, timer return types, plus an
`Express.Request`-style `declare global` augmentation — with diagnostics
matching tsc. Keep it as a standing fixture and record wall/RSS in
BENCHMARKS.md: this doubles as the first realistic `.d.ts`-heavy
benchmark and feeds M12's gates.

**Perf/memory expectations:** the overlay costs a few indices per merged
name — only merged names pay, per invariant 3. M7 already fixed the two
traps this milestone would have hit (`resolveStem`'s 256-byte cap on deep
`node_modules/@types` paths; the `upsertProp`/`sortTriples` quadratics on
400-member interfaces). The real pressure `@types/node` adds is
per-checker duplication of a now-huge lib-type population — that is
M12.3's job; if the acceptance test shows unacceptable RSS at N=4, pull
M12.3 forward rather than special-casing here.

**Risks:** the recursive namespace fixpoint is the substance — build the
mini-`NodeJS` fixture *first* and grow it; the checker id-space audit is
wide but mechanical — lean on conformance breadth plus the merged-range
asserts.

### M12 — Shared-lib substrate: deterministic atoms, pre-parsed lib, shared type store

The architecture that keeps the ≤50%-RSS headline alive now that the lib
is real and M11 makes `@types/node`-sized inputs checkable. Three pieces;
(1) is a prerequisite of (2). Retrofitting any of this after M15–M16
would mean reworking the instantiation caches.

1. **Deterministic atoms.** An `Atom` encodes shard-local *insertion
   order* (intern.zig:~120–124), which depends on worker scheduling — the
   same input produces different atoms run-to-run. That blocks (2) (a
   serialized blob must reference stable atoms) and blocks post-v0.0.1
   incremental hashing (§8: a per-file `Bind` is not content-addressable
   if its `symbol_names` differ by run). Options: (a) pre-seed the
   interner single-threaded from a canonical string table before workers
   start — sufficient for (2); (b) file-local atoms remapped to global at
   link — stronger, makes per-file outputs content-addressable. Decide
   with §8 in mind; (a) now + (b) later is acceptable if (a)'s table
   covers the embedded lib. (Note: M11's merge layer deliberately does
   *not* depend on this — it is deterministic via FileId-ordered serial
   link.)
2. **Build-time pre-parsed embedded lib.** The AST, tokens, and binder
   outputs are flat `u32` arrays with no pointers — trivially
   serializable. Add a build.zig step that runs ztsc's own front-end over
   the trimmed ES-core lib and `@embedFile`s the sealed products as a
   blob; at startup, load with exact-size allocations (or zero-copy
   pointers into the binary). Wins: near-zero cold-start for `bunx ztsc`
   on small projects (otherwise lib parse/bind dominates), no doubling
   slack (see M7 item 2 in §4), and a serialization pass that strips what
   the subset parser would otherwise retain from lib.d.ts — orphan
   parsed-then-discarded sub-nodes (conditional types parser.zig:~2513,
   type predicates ~1041, call/construct signatures ~2890) and one
   `unsupported_syntax` diagnostic *per construct* (parser.zig:~405),
   thousands for the real lib. Requires (1).
3. **Shared frozen lib type store.** Today each of the N checkers owns a
   full `Store` plus all expansion caches (`expansions`, `iface_generic`,
   `class_inst_generic`, `alias_generic` — checker.zig:~231–268), so
   every checker that touches `Array`/`Promise`/`String` re-expands and
   permanently interns them. The measured +15.5% type duplication at N=4
   (BENCHMARKS.md §3.2) is on *lib-free* corpora; with lib + `@types/node`
   types the duplicated population is the largest one in the program, up
   to N×. Design: after link, expand lib/`@types` types **once** into a
   base `Store` and freeze it; per-checker overlay stores allocate
   TypeIds above the base range; lookups check the frozen base first and
   intern misses locally. Frozen-base relation-cache entries (base × base
   pairs) can be shared read-only the same way. **This is the type-level
   twin of M11's merged-symbol layer** — a merged symbol expanded once
   into the frozen base is the intended end state; reuse M11's merge
   table as the enumeration of what to pre-expand. This subsumes §8's
   "shared simple-type interner" dial. While in there, right-size the
   per-checker whole-program state: `sym_types`/`sym_state` are
   `totalSymbols() × 5 bytes × N` and `node_scopes` is eagerly filled
   with every scope of every file per instance (checker.zig:~325–340) —
   size to owned files plus lazily-faulted foreign entries.

**Gate:** diagnostics byte-identical for any N (existing test); RSS at
N=4 within a small constant of N=1 on the multi corpus *and* the M11
`@types/node` fixture; blob load time vs source-parse time recorded in
BENCHMARKS.md.

### M13 — Reality: census, real-world corpus, resolution cache

Everything here needs real code, which M11 finally makes checkable.

- **Census tool**: parse the top few hundred npm packages + real Bun/Node
  repos (Elysia, Hono, Zod, Drizzle apps); count which unsupported
  constructs block parse/bind/check, by frequency. The output table
  decides M14/M16 implementation order — spec order is not the priority
  order.
- The long-deferred **~500k-LOC real-world corpus** lands (real code is
  checkable once lib types + the global-symbol layer exist). It becomes
  the standing benchmark corpus alongside the synthetic ones.
- **Resolution cache.** Resolution work is deduped per resolved *file*
  (`path_ids`) but not per *specifier*: the same bare specifier imported
  from K files re-walks node_modules K times (`resolvePackage` does a
  `package.json` read + up to 4 stats per parent directory,
  modules.zig:~347–381), and all of it runs as blocking syscalls on the
  single-owner main thread — which is also the discovery scheduler
  (main.zig:~517–566), so workers idle behind it. `@types/node` in every
  project makes this hot. Add a `(importer_dir, specifier) → resolution`
  memo plus a negative / directory-existence cache. Only move stat work
  onto workers if the census shows resolution still dominates after
  caching (the single-owner design itself is fine and should be
  preserved).
- **Tests**: conformance cases from census-discovered gaps. **Benchmarks**:
  large-corpus wall + RSS vs tsc/tsgo; resolution syscall counts
  before/after the cache.

### M14 — Semantic breadth: the remainder

What's left of the breadth work after M10 (history §4) and M11, in
census order once M13's table exists. Complexity notes per item:

- **`unique symbol` annotations** (clean out-of-subset today). Parse
  `unique symbol` in type position; enforce the position restriction
  (only on `const` variables and `readonly static` members, TS1332
  otherwise); give each `unique symbol` a *nominal* identity tied to its
  declaration site so computed keys (`const k = Symbol(); { [k]: … }`)
  and `obj[k]` access resolve by that identity. The `Symbol.iterator`
  protocol already ships via *syntactic* `[Symbol.iterator]` recognition
  (`ast.wellKnownSymbolKey`), so this is only needed for arbitrary
  user-defined unique-symbol keys — low app-code frequency.
- **JSX polish (deferred bits).** (1) `-` in JSX names (`data-*`,
  `aria-*`) needs a JSX-identifier scan that spans `-` plus a rescan
  entry point (today `data`, `-`, `foo` lex as three tokens), and
  `IntrinsicElements` entries with index signatures to type them; (2)
  class-component props (`class C extends Component<P>`) read props from
  the instance type (`JSX.ElementClass` / its `props` member) rather
  than a call signature; (3) resolving the `JSX` namespace from
  `@types/react` — unblocked by M11's global-symbol layer, mostly test
  work once M11 lands; (4) spread-attribute type-checking (spreads
  currently bypass excess/missing checks), `key`/`ref` special-casing,
  and `JSX.ElementChildrenAttribute` children typing.
- **`this`-typing and decorators** (low priority): polymorphic `this`
  return types / `this` parameters, and (legacy/TC39) decorators. Both
  are uncommon in the target app code and can trail the items above —
  or slip past v0.0.1 if the census confirms they're rare.
- **Tests**: conformance grows toward ~500 cases, every feature
  differential vs tsc. **Benchmarks**: regression gates — memory/wall
  budgets must not drift as semantics widen (held so far: `--noLib` hot
  path flat across all ten M10 features).

### M15 — Instantiation discipline (de-risk M16)

Land the caching architecture M16 depends on *before* the type-level
features that would otherwise explode it. Today `expandRef` already
memoizes on the interned `.ref` `(symbol, args)` — which *is* the
roadmap's `(target, type-args)` key (checker.zig:~1948). But raw
`instantiate` (checker.zig:~2279) has **no memo**: it re-runs the full
recursive walk and permanently interns a fresh result every call, and
`eraseTypeParams` / `instantiateSigForCall` re-instantiate every overload
candidate signature per call site (checker.zig:~2850, `resolveOverload`
loop ~4243). Types are never freed, so uncached instantiation across many
arg combinations grows the store without bound — the M16 explosion vector.

- Route all generic application through canonical `.ref` interning +
  `expandRef`; make raw `instantiate` a cache-miss path, not the main
  path. The awkwardness to design around: `instantiate`'s substitution
  `map` is a `[]const TpMap` slice, not a canonical key — canonicalize it
  (sorted `(type-param-symbol, arg)` pairs interned to a stable id) so it
  can key a memo.
- Add the memoization companions the review flagged: cache
  `typeParamConstraint` (checker.zig:~2415, currently re-parses the
  constraint AST on every assignability check) and `typeFromTypeNode`
  (checker.zig:~948, re-walks the annotation subtree per occurrence — a
  `(file, node) → TypeId` memo mirroring `node_types`). Reorder
  `eraseTypeParams` so the non-generic early-out precedes the `dupe`
  (checker.zig:~2850).
- Bring in tsc-compatible instantiation depth/count limits here (M16
  needs them, but the caching layer is where they belong).

**Gate:** no conformance regression; on a generics-heavy synthetic corpus,
types-created and type-arena bytes flat or down vs an uncached baseline
(add a generics-heavy corpus to `bench/gen_corpus.js` if none stresses
this). This corpus is reused as M16's memory scoreboard.

### M16 — The type-level core (make-or-break)

This is what the `.d.ts` files of Zod, Drizzle, Hono, and Elysia are made
of — the features your *dependencies* choose for you. It is large and
high-risk, so it is split into four sub-milestones (M16a–M16d), each
landable and gated on its own. All four build on M15's instantiation
caching + tsc-compatible depth/count limits, so they add features on top of
a cache that already exists rather than retrofitting one under pressure.

**Cross-cutting architecture (applies to every sub-milestone):**
instantiation caching keyed on `(target, type-args)` and depth/count limits
**land in M15**. Hash-consing is the memory defense; laziness (deferring
evaluation while the input is still generic) is the speed defense *and* the
correctness mechanism — tsc keeps conditional/indexed/mapped types
unresolved until their generic inputs are known, and ztsc must mirror that
deferral rather than eagerly evaluating. This is where the ≤50%-of-tsgo
memory goal is genuinely at risk — measured continuously on M15's
generics-heavy corpus plus type-heavy real corpora (zod/drizzle-style), not
synthetic subset corpora. Every sub-milestone ships type-level torture
conformance vs tsc plus real `.d.ts` files from top libraries checked
identically; benchmarks track types/line, RSS, and instantiation counts.

- **M16a — Conditional types + `infer` + distributivity.** `T extends U ? X
  : Y`, `infer V` capture, and distribution over a naked type-parameter
  union (`T extends any ? … : …` applied member-wise). Parse nodes are
  already produced-then-discarded (parser.zig:~2513), so the front-end lift
  is small; the checker work is the substance. Complexity: (1) *deferral* —
  when the checked type is still generic the whole conditional stays
  unresolved and must be interned as a deferred type, resolved on
  instantiation; (2) `infer` scoping and the assignability probe that binds
  it (inference from the `extends` clause, with multiple `infer` sites and
  same-name unions/intersections); (3) distributivity rules (naked type
  param vs wrapped `[T]`), and (4) assignability *between* conditional
  types (identity + related-when-branches-related). Prerequisite for M16b/c
  because mapped/template types lean on conditional evaluation.

- **M16b — Mapped types (+ `as` key remapping).** `{ [K in Keys]: T }` with
  modifiers (`readonly`, `?`, and the `+`/`-` add/remove forms) and `as`
  key remapping (`{ [K in Keys as NewKey]: T }`). Mapped-type syntax is
  currently skipped as out-of-subset (parser.zig:~3105), so both parser and
  checker are net-new. Complexity: (1) *homomorphic* mapped types
  (`{ [K in keyof T]: … }`) must preserve the source's modifiers and
  tuple/array-ness; (2) key remapping produces filtered (`never`-drops) and
  renamed keys, which needs template-literal evaluation for the common
  rename patterns (couples to M16c); (3) interaction with `keyof` and
  generic index access; (4) memory — a mapped type over a large key union
  is a materialization explosion vector, so laziness/hash-consing matter
  most here.

- **M16c — Template-literal types.** `` `prefix-${T}-suffix` `` types, the
  intrinsic string transforms (`Uppercase`/`Lowercase`/`Capitalize`/
  `Uncapitalize`), and inference *from* template-literal types (pattern
  matching a string against a template to bind `infer`). Complexity: (1)
  the combinatorial cross-product when interpolation holes are unions is a
  bounded-but-real explosion vector (needs the M15 count limits); (2)
  pattern-match inference (parsing a literal against `` `${infer H}-${infer
  T}` ``) is a small string matcher but must agree with tsc's greedy/lazy
  rules exactly; (3) assignability between template-literal types and
  string literals/`string`.

- **M16d — Recursive type aliases + generic indexed access + `keyof` over
  mapped/generic types.** Self-referential aliases (`type Json = string |
  number | Json[] | { [k: string]: Json }`), indexed access `T[K]` where
  `K` (and/or `T`) is a type parameter, and `keyof` applied to mapped or
  otherwise-generic types. Complexity: (1) *termination* — recursive
  aliases and generic indexed access must defer (stay unresolved while
  generic) and rely on the M15 depth limits to avoid non-termination; (2)
  `T[K]` deferral and its distribution over unions in `K`; (3) `keyof` over
  a mapped type must reflect the mapped key set, closing the loop with
  M16b. This sub-milestone is mostly "make the deferral machinery from
  M16a–c compose without blowing the depth budget," so it lands last and
  doubles as the integration/stress pass.

### M17 — Ship it: bunx distribution + release

Batch checking only — no watch mode, no LSP (post-v0.0.1, §8).

- **Distribution**: npm package `ztsc` with prebuilt platform binaries via
  `optionalDependencies` (the esbuild pattern) so **`bunx ztsc` works
  cold** — macOS/Linux × x64/arm64, cross-compiled by Zig in CI. Linux
  benchmark numbers land here too.
- **Real-world validation**: N real open-source Bun/Node projects check
  with diagnostics matching tsc (differential, wrong answers = release
  blockers) — including at least one `@types/node`-dependent backend
  project (the M11 acceptance fixture graduates here).
- **Release gate (the whole point)**: on real projects, macOS *and* Linux —
  wall within 1.25× of tsgo, **peak RSS ≤ 50% of tsgo**, conformance green.
  Then, and only then: tag **v0.0.1**, publish to npm.

---

## 6. Current checked subset (as of M10)

**In:** primitives + literal types, `unknown`/`any`/`never`/`void`;
objects, interfaces (incl. `extends`), type aliases, arrays, tuples;
unions & intersections, discriminated unions; functions (param/return
inference, optional/default/rest, declared-overload resolution); generics
(declarations, explicit instantiation, basic inference from arguments);
classes (fields, methods, `implements`/`extends`, visibility); control-flow
narrowing (truthiness, `typeof`, `===`/`!==`, `in`, `instanceof`,
discriminants, assignments); `keyof`, non-generic indexed access, `typeof`
queries; ES modules incl. type-only imports, `.d.ts` reading; strict-mode
semantics only (strictNullChecks always on). **Since M9/M10:** the
embedded ES-core `lib.d.ts` (M9); enums (+`const enum`), getters/setters,
`abstract` classes, `as const`, `satisfies`, user-defined type guards +
assertion functions, namespaces (+ within-file merging, + ambient implicit
export), async/await/`Promise` typing, basic generators, `symbol` +
`typeof "symbol"` narrowing, the `Symbol.iterator` iteration protocol
(`for…of`/spread over Map/Set/generators/user iterables), the `Symbol`
global, and JSX typing in `.tsx` (intrinsic + component elements against a
`JSX` namespace).

**Not yet** (queued in §5): general **cross-file declaration merging** (the
global-symbol layer; within-file and across-import merging already work),
module augmentation + triple-slash refs (M11); `unique symbol`
annotations, JSX polish (`-` in names, class-component props, JSX
namespace from imported `@types`), `this`-typing, decorators (M14);
**conditional types + `infer`** (M16a), **mapped types + `as` remapping**
(M16b), **template-literal types** (M16c), **recursive aliases + generic
indexed access + `keyof` over mapped types** (M16d). Unsupported syntax
produces a clear "not supported" diagnostic — never a wrong answer or a
crash (fuzzed at every phase). (M12, M13, and M15 are perf/memory/caching
milestones — they change no checked subset; see §5.)

---

## 7. Risks & mitigations

- **TS semantics rabbit holes** → differential testing against tsc for
  every feature; match observable behavior. stc/Ezno are the cautionary
  tales; tsgo (a faithful port) is the success story.
- **M11 recursive merge complexity** → the mini-`NodeJS` fixture is built
  first and grown; the checker id-space audit is guarded by merged-range
  asserts; the `@types/node` acceptance test is the milestone gate, not an
  afterthought.
- **M16 instantiation explosion vs the memory goal** → instantiation
  caching + depth limits landed in M15 (before the features that stress
  them); continuous RSS measurement on type-heavy real corpora;
  hash-consing.
- **Checker duplication overhead grows with N** → it's a measured dial;
  the shared frozen lib type store (M12.3) turns the largest duplicated
  population — lib/`@types` types — into a read-only shared base, keeping
  it off the per-checker N× multiplier. Simple non-lib types may follow
  the same pattern if the census shows they dominate.
- **Zig 0.16 std churn** → version pinned in build.zig.zon and CI; upgrade
  deliberately. (Known: custom pool over `Thread.spawn`, `std.Io.Mutex`,
  `std.Io.Clock`, `Io.File.MemoryMap`; `std.testing.fuzz` takes `*Smith`;
  one cosmetic "failed command" line from an upstream test-runner bug.)
- **Synthetic corpora flatter us** → M13's census + real corpora make the
  benchmark story honest before anything is published.

---

## 8. Post-v0.0.1 (deliberately out of the first release)

- **Incremental checking + watch mode** — the flagship follow-up:
  types-first-inspired incrementality (per-file interface signatures cut
  the dependency graph; a body edit that doesn't change the signature
  re-checks one file). Target: warm re-check of one edit on the multi
  corpus in low double-digit ms. **Enabled by M12.1**: content-addressable
  per-file `Bind`s require deterministic atoms — if M12 only shipped
  option (a) (seeded interner), the stronger option (b) (file-local atoms
  remapped at link) lands here.
- **LSP** — builds on the incremental substrate above; the sealed-phase
  architecture and single-owner discovery were chosen not to preclude it.
- **Windows** support and benchmarks.
- **`--fix`-style quick suggestions** (TS2551 "did you mean" already
  exists; expand).
- **Shared simple-type interner** across checkers — extend M12.3's frozen
  base beyond lib/`@types` to hot non-lib simple types if the census shows
  they dominate the per-checker duplication (memory dial, §7).
- **Incremental persistence** (on-disk graph cache for CI cold starts).
