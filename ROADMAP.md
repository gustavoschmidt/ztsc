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
**v0.0.1**, ships only when the whole M7–M14 sequence below is done. Its
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
full TypeScript semantics (§5, M13 especially).

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
  corpora arrive with M10's census.
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
- **M7 — Quick wins: memory & perf debt** (`6d9f778`, tag `m7`): all six
  fixes (duplicate token scan, seal-parser-into-exact-size, resolution
  scratch arena, linker sort, object-construction quadratics, resolveStem
  cap). **Heap RSS −53% medium / −60% multi**, time equal-or-better.
- **M8 — Contextual re-check cache** (`77acca4`, tag `m8`): fixed
  context-blind `node_types` *and* `sig_cache` (spurious TS2769 on overload
  argument trials); `{ty, ctx}` discriminator; `flow_cache`/`da_cache`
  audited sound. Conformance 180 → 182; check-phase flat.
- **M9/M10 — merged shared-lib + lib.d.ts phase (in progress).** Decision
  (2026-07-12): build a minimal real lib first so the M9 substrate has
  measurable gates, deferring the substrate itself until the lib is
  real-sized. Landed: **lib-core** (`dd6fcbb`) — embedded ES-core
  `lib.d.ts`, global-symbol table, `resolveSpace` fallback, array/primitive→
  interface bridge, `--noLib`; **lib-grow** (`0721986`) — real ES-core
  surface (constructor globals, Map/Set/Date as `declare class`), fixed a
  merged value+type global resolving to `any`; **cost-based check
  partition** (`1536ba3`) — greedy-by-node-count, skewed −26% / bigfan 2.4×,
  determinism preserved. Conformance 182 → 200. **Deferred (need realistic
  corpora): resolution cache** (corpora have 0 bare specifiers) and the **M9
  substrate** (deterministic atoms, pre-parsed blob, shared frozen type
  store — KB/sub-ms payoff at current 132→220-line lib). **Still open in
  M10:** census tool, ~500k real-world corpus.
- **M11 — semantic breadth (in progress).** Ten features landed, each
  differential-tested vs tsc 5.5.4, `--noLib` hot path flat: **enums**
  (`2c43581`), **accessors + abstract** (`f1ae28e`), **`as const` +
  `satisfies`** (`c009ff3`), **type guards + assertion functions**
  (`d3c2304`), **namespaces + within-file merging** (`7ede24a`),
  **async/await/Promise + basic generators** (`acb08ea`), **`Symbol.iterator`
  iteration protocol** (`24d0447` — `for…of`/spread over Map/Set/generators/
  user iterables via `[Symbol.iterator]()`; bare `Iterator<T>` correctly not
  iterable), **ambient namespace implicit export** (`c69193f` — `declare
  namespace` members visible as `N.member` without `export`, also fixing
  function+ambient-namespace merged property access), **`Symbol` global**
  (`8037ead` — callable + well-known symbols via interface+function+namespace
  merge, closing the value-`Symbol` gap). `symbol` primitive + `typeof`
  narrowing already worked. Conformance 200 → 292. **Still open in M11:**
  general cross-file declaration merging (the global-symbol layer — M11e-1
  built the sealed-bind foundation), `unique symbol` annotations (clean
  out-of-subset today), module augmentation + triple-slash refs, JSX typing.

---

## 5. The road to the public v0.0.1

Eight milestones. Order is deliberate: pay down measured perf/memory debt
while it's cheap (M7), fix a latent correctness gap before it gets hot
(M8), lay the shared-lib substrate the whole release rests on (M9), then
usefulness (M10), breadth (M11), the caching discipline that de-risks the
type-level core (M12), the type-level core itself (M13), and the product
surface (M14). Lessons from prior art bake the sequence: stc and Ezno
(Rust) died on tsc-compatibility, not performance — the differential
conformance discipline is non-negotiable as the surface grows.

M7–M9, M12, and the new items inside M10/M11 come out of the 2026-07-12
architecture review. All findings were verified in the code at commit
`6aa155f`; the `file:~line` references below are from that commit and may
drift — search for the named function when in doubt. The common theme:
several behaviors that are invisible on today's lib-free synthetic corpora
scale badly with exactly what M10 introduces — a few very large, shared,
declaration-heavy `.d.ts` files.

### M7 — Quick wins: memory & perf debt

Six independent fixes, each small, each landable separately. Every one is
cheap on current corpora but scales badly at M10. Ship with before/after
numbers appended to BENCHMARKS.md (same corpora, same methodology).

1. **Drop the duplicate token scan.** `processFile` retains a standalone
   `c.tokens = scanner.tokenize(alloc, ...)` (main.zig:~294), then
   `parser.parse(alloc, ...)` (main.zig:~311) re-tokenizes internally into
   `tree.tokens` — which is what the binder actually reads. The standalone
   copy feeds only `--memory` stats. Fix: delete it and derive token stats
   from `tree.tokens` (or teach the parser to accept pre-scanned tokens).
   Saves a full ~5 B/token array per file in retained arenas.
2. **Parser: build in scratch, seal exact-size.** The parser's six
   growable lists (`tok_tags`, `tok_starts`, `nodes`, `extra`, `scratch`,
   `diags` — parser.zig:~96–101) start `.empty` and grow by doubling
   inside the *retained per-file AST arena*. Under an arena, every
   non-tail realloc strands the old buffer forever, `toOwnedSlice` keeps
   the final tail slack, and `scratch.deinit` is a no-op — resident cost
   can exceed 2× the live "16 B/node" data. Fix: parse into a transient
   scratch arena, then memcpy the sealed slices at exact size into the
   retained arena (the AST is pointer-free `u32`s, so a flat copy is
   valid). `scanner.tokenize`'s `ensureTotalCapacityPrecise` shows the
   pre-reservation alternative. Verify with `--memory`: resident bytes/node
   should approach live bytes/node.
3. **Resolution scratch arena in the parallel driver.** `resolveSpecInto`
   passes the process-lifetime main arena as the scratch allocator to
   `mapSpecifier`/`resolveStem`/`resolveSpecifier` (main.zig:~1075–1083).
   Inside `resolvePackage` the `defer alloc.free(...)` calls are arena
   no-ops, so every candidate path string and every `package.json` body
   (read with a 1 MB limit, modules.zig:~363) is retained for the whole
   run. The serial `buildProgram` path already does this right with a
   reset scratch arena (modules.zig:~734) — mirror it in main.zig.
4. **Linker: replace the insertion sort.** `sortByKeyU32`
   (modules.zig:~700) is O(n²) and sorts export tables copied out of an
   `AutoArrayHashMap` — insertion order, *not* "nearly sorted" as the
   comment claims. Export tables of big `.d.ts` files have
   hundreds–thousands of names → quadratic per file at M10. Use
   `std.mem.sort` over an index permutation (the binder's member sealing,
   binder.zig:~2274, shows the pattern).
5. **Object-construction quadratics.** `upsertProp` linear-scans the
   accumulated props on every insert (checker.zig:~1351) → O(P²); then
   `makeObject`'s `sortTriples` insertion sort (types.zig:~730) is O(P²)
   again. Irrelevant for object literals, painful for 400-member lib
   interfaces built once *per checker instance*. Fix: name→index hashmap
   during accumulation (the method-grouping map built nearby shows the
   idiom), `std.mem.sort` for the triples.
6. **`resolveStem` 256-byte cap — correctness, not just perf.** The
   fixed candidate buffer (modules.zig:~311–320) silently returns `null`
   for paths longer than 256 bytes — a wrong "module not found" for deep
   `node_modules/@types/...` paths. Allocate candidates from scratch (see
   item 3) or raise the cap; add a test with a deliberately long path.

Secondary, take if cheap while in the area: `tokenEnd` identifier fast
path — today every `tokenSlice` on an identifier re-scans the token
*including the `keyword_map` hash* (scanner.zig:~958, ~639); a
`identifierRest`-only walk skips the hash in the binder/checker's hottest
name loop. Seal the interner's reverse index after the front-end finishes
so `lookup` stops taking a shard mutex during check (intern.zig:~85–92;
restores modules.zig's "no locks on the check path" claim). Free
`permuteInPlace`'s dupes (main.zig:~1037). Lazy line-start table — it's
eagerly built and retained per file but only consumed by diagnostic
rendering (source.zig:~145).

**Gate:** conformance stays green; every e2e number equal or better;
`--memory` heap total and resident bytes/node down on medium + multi.

### M8 — Correctness: contextual re-check cache

`node_types` memoizes checked expression types keyed on
`(file << 32 | node)` **without the contextual type** (`checkExprCached`,
checker.zig:~3130): first-check-wins, so a node re-checked under a
different contextual type silently returns the first answer. Hard to hit
in the current subset; pervasive once lib callbacks make contextual
typing routine at M10+ (`arr.map(x => ...)` checked against different
signatures, overload resolution re-checking arguments per candidate).

- Write differential conformance cases that expose the staleness first
  (same literal/arrow expression contextually typed two different ways —
  overload candidates and double assignment are the natural vectors);
  confirm they diverge from tsc today.
- Then decide the policy: include a context discriminator in the cache
  key, or only cache context-free checks (measure the hit-rate cost of
  each — `--memory` reports the relation-cache hit rate; add the same for
  `node_types`).
- Audit the sibling caches for the same keying gap while there:
  `sig_cache`, `flow_cache` (whose key already includes `declared` —
  verify that's sufficient), and `da_cache`.

**Gate:** new conformance cases green vs tsc; no measurable check-phase
regression on medium + multi.

### M9 — Shared-lib substrate: deterministic atoms, pre-parsed lib, shared type store

The architecture that keeps the ≤50%-RSS headline alive once `lib.d.ts`
exists. Three pieces; (1) is a prerequisite of (2); land all three before
M10. Retrofitting any of this after M12–M13 would mean reworking the
instantiation caches.

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
   covers the embedded lib.
2. **Build-time pre-parsed embedded lib.** The AST, tokens, and binder
   outputs are flat `u32` arrays with no pointers — trivially
   serializable. Add a build.zig step that runs ztsc's own front-end over
   the trimmed ES-core lib and `@embedFile`s the sealed products as a
   blob; at startup, load with exact-size allocations (or zero-copy
   pointers into the binary). Wins: near-zero cold-start for `bunx ztsc`
   on small projects (otherwise lib parse/bind dominates), no doubling
   slack (see M7.2), and a serialization pass that strips what the
   subset parser would otherwise retain from lib.d.ts — orphan
   parsed-then-discarded sub-nodes (conditional types parser.zig:~2513,
   type predicates ~1041, call/construct signatures ~2890) and one
   `unsupported_syntax` diagnostic *per construct* (parser.zig:~405),
   thousands for the real lib. Requires (1).
3. **Shared frozen lib type store.** Today each of the N checkers owns a
   full `Store` plus all expansion caches (`expansions`, `iface_generic`,
   `class_inst_generic`, `alias_generic` — checker.zig:~231–268), so
   every checker that touches `Array`/`Promise`/`String` re-expands and
   permanently interns them. The measured +15.5% type duplication at N=4
   (BENCHMARKS.md §3.2) is on *lib-free* corpora; with lib types the
   duplicated population is the largest one in the program, up to N×.
   Design: after link, expand lib/`@types` types **once** into a base
   `Store` and freeze it; per-checker overlay stores allocate TypeIds
   above the base range; lookups check the frozen base first and intern
   misses locally. Frozen-base relation-cache entries (base × base pairs)
   can be shared read-only the same way. This subsumes §8's "shared
   simple-type interner" dial. While in there, right-size the per-checker
   whole-program state: `sym_types`/`sym_state` are `totalSymbols() × 5
   bytes × N` and `node_scopes` is eagerly filled with every scope of
   every file per instance (checker.zig:~325–340) — size to owned files
   plus lazily-faulted foreign entries.

**Gate:** diagnostics byte-identical for any N (existing test); multi-
corpus RSS at N=4 within a small constant of N=1; blob load time vs
source-parse time recorded in BENCHMARKS.md.

### M10 — lib.d.ts + reality census

The single biggest usefulness unlock: without `Array.prototype.map`,
`Promise`, `fetch`, `console`, no real file checks.

- Trimmed ES-core lib (`Object/Array/String/Number/Promise/Map/Set/RegExp/
  Error/JSON/Math/Symbol`, iterables, `console`, timers) loaded through the
  existing `.d.ts` path, **embedded in the binary** as the pre-parsed M9
  blob so the eventual `bunx` binary is self-contained and cold-start
  stays tiny. Globals bind lazily. `bun-types`/`@types/node` load as
  ordinary node_modules packages when present.
- **Census tool**: parse the top few hundred npm packages + real Bun repos
  (Elysia, Hono, Zod, Drizzle apps); count which unsupported constructs
  block parse/bind/check, by frequency. The output table decides M11/M13
  implementation order — spec order is not the priority order.
- The long-deferred **~500k-LOC real-world corpus** finally lands (real
  code becomes checkable once lib types exist).
- **Resolution cache.** Resolution work is deduped per resolved *file*
  (`path_ids`) but not per *specifier*: the same bare specifier imported
  from K files re-walks node_modules K times (`resolvePackage` does a
  `package.json` read + up to 4 stats per parent directory,
  modules.zig:~347–381), and all of it runs as blocking syscalls on the
  single-owner main thread — which is also the discovery scheduler
  (main.zig:~517–566), so workers idle behind it. Add a
  `(importer_dir, specifier) → resolution` memo plus a negative /
  directory-existence cache. Only move stat work onto workers if the
  census shows resolution still dominates after caching (the single-owner
  design itself is fine and should be preserved).
- **Cost-based check partition.** `owned_lists[i % n_checkers]`
  (main.zig:~665) ignores file size; one or two giant `.d.ts` files can
  pile onto a single checker. Partition greedily by per-file AST node
  count (known after parse). `--timing`'s per-checker breakdown verifies
  the balance.
- **Tests**: conformance cases exercising lib types (array methods,
  promise chains, iterables) vs tsc. **Benchmarks**: lib loading cost
  isolated; large-corpus wall + RSS vs tsc/tsgo; resolution syscall
  counts before/after the cache.

### M11 — semantic breadth (the boring 80%)

Everything common that isn't type-level programming, in census order.
Expected contents: enums (incl. `const enum`), namespaces + declaration
merging (interface/namespace/class), getters/setters, `abstract` classes,
`this` typing, `symbol`/`unique symbol`, async/await/`Promise` return
typing, generators, user-defined type guards (`x is T`) + assertion
functions, `satisfies`, `as const`, module augmentation, triple-slash refs,
JSX typing (Bun runs frontends too — via the `JSX` namespace).

- **Declaration merging needs a global symbol layer — decide the design
  before writing feature code.** The linker maps each exported name to a
  *single* defining `Target{file, payload}` (modules.zig:~61–81,
  ~456–517); there is no way to express "interface `Foo` = the merge of
  declarations in files X, Y, Z." Within-file interface merging already
  works by reusing one members scope (binder.zig:~1717–1728), but
  cross-file merging (interface/namespace/class) has no representation.
  And **namespaces aren't bound at all** — `bindStatement`
  (binder.zig:~1117–1199) has no `namespace`/`module` case, so
  `namespace X {}` merging starts from zero. The fix is a global symbol
  layer sitting above the sealed per-file `Bind`s that the checkers
  consult; that layer is *also* where M9.3's shared-lib symbols live, so
  design the two together — a merged symbol is the general case of which
  a lib symbol is the single-declaration instance. Keep per-file `Bind`s
  sealed and immutable; the global layer references into them.
- JSX rescanning fits the existing architecture without redesign: the
  scanner already rescans by resetting `scn.index` to a token start and
  re-lexing under grammar context (`reScanSlashAsRegex`,
  `reScanTemplateToken`, and the `>>`/`<<` split surgery in the parser);
  JSX needs only additive `scanJsxText`/`reScanJsxToken`/`scanJsxIdentifier`
  entry points and new tags. The standalone `scanner.tokenize` heuristic
  driver is *not* on the parser path (the parser pulls `scn.next()`
  directly), so JSX/regex correctness work only touches the parser-driven
  path.
- **Tests**: conformance grows toward ~500 cases, every feature
  differential vs tsc. **Benchmarks**: regression gates — memory/wall
  budgets must not drift as semantics widen.

### M12 — instantiation discipline (de-risk M13)

Land the caching architecture M13 depends on *before* the type-level
features that would otherwise explode it. Today `expandRef` already
memoizes on the interned `.ref` `(symbol, args)` — which *is* the
roadmap's `(target, type-args)` key (checker.zig:~1948). But raw
`instantiate` (checker.zig:~2279) has **no memo**: it re-runs the full
recursive walk and permanently interns a fresh result every call, and
`eraseTypeParams` / `instantiateSigForCall` re-instantiate every overload
candidate signature per call site (checker.zig:~2850, `resolveOverload`
loop ~4243). Types are never freed, so uncached instantiation across many
arg combinations grows the store without bound — the M13 explosion vector.

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
- Bring in tsc-compatible instantiation depth/count limits here (M13
  needs them, but the caching layer is where they belong).

**Gate:** no conformance regression; on a generics-heavy synthetic corpus,
types-created and type-arena bytes flat or down vs an uncached baseline
(add a generics-heavy corpus to `bench/gen_corpus.js` if none stresses
this). This corpus is reused as M13's memory scoreboard.

### M13 — the type-level core (make-or-break)

Conditional types + `infer` + distributivity, mapped types (+ `as` key
remapping), template-literal types, recursive type aliases, generic indexed
access, `keyof` over mapped types. This is what the `.d.ts` files of Zod,
Drizzle, Hono, and Elysia are made of — the features your *dependencies*
choose for you.

- **Architecture rule learned from tsc's own pain**: instantiation caching
  keyed on `(target, type-args)`, plus tsc-compatible depth/count limits —
  **both landed in M12**, so this milestone builds features on top of a
  cache that already exists rather than retrofitting one under pressure.
  Hash-consing is the memory defense; laziness is the speed defense. This
  milestone is where the ≤50%-of-tsgo memory goal is genuinely at risk —
  measured continuously (on M12's generics-heavy corpus plus type-heavy
  real corpora, zod/drizzle-style), not synthetic subset corpora.
- **Tests**: type-level torture conformance vs tsc + real `.d.ts` files
  from top libraries checked identically. **Benchmarks**: types/line, RSS,
  and instantiation counts on type-heavy corpora.

### M14 — ship it: bunx distribution + release

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

**Not yet** (queued in §5): `lib.d.ts` (M10); enums, namespaces,
declaration merging, getters/setters divergence, `this`-typing,
async/Promise typing, `satisfies`, `as const`, JSX, decorators (M11);
conditional, mapped, and template-literal types, `infer` (M13).
Unsupported syntax produces a clear "not supported" diagnostic — never a
wrong answer or a crash (fuzzed at every phase). (M7–M9 and M12 are
perf/memory/correctness/caching milestones — they change no checked
subset; see §5.)

---

## 7. Risks & mitigations

- **TS semantics rabbit holes** → differential testing against tsc for
  every feature; match observable behavior. stc/Ezno are the cautionary
  tales; tsgo (a faithful port) is the success story.
- **M13 instantiation explosion vs the memory goal** → instantiation
  caching + depth limits landed in M12 (before the features that stress
  them); continuous RSS measurement on type-heavy real corpora;
  hash-consing.
- **Checker duplication overhead grows with N** → it's a measured dial;
  the shared frozen lib type store (M9.3) turns the largest duplicated
  population — lib/`@types` types — into a read-only shared base, keeping
  it off the per-checker N× multiplier. Simple non-lib types may follow
  the same pattern if the census shows they dominate.
- **Zig 0.16 std churn** → version pinned in build.zig.zon and CI; upgrade
  deliberately. (Known: custom pool over `Thread.spawn`, `std.Io.Mutex`,
  `std.Io.Clock`, `Io.File.MemoryMap`; `std.testing.fuzz` takes `*Smith`;
  one cosmetic "failed command" line from an upstream test-runner bug.)
- **Synthetic corpora flatter us** → M10's census + real corpora make the
  benchmark story honest before anything is published.

---

## 8. Post-v0.0.1 (deliberately out of the first release)

- **Incremental checking + watch mode** — the flagship follow-up:
  types-first-inspired incrementality (per-file interface signatures cut
  the dependency graph; a body edit that doesn't change the signature
  re-checks one file). Target: warm re-check of one edit on the multi
  corpus in low double-digit ms. **Enabled by M9.1**: content-addressable
  per-file `Bind`s require deterministic atoms — if M9 only shipped
  option (a) (seeded interner), the stronger option (b) (file-local atoms
  remapped at link) lands here.
- **LSP** — builds on the incremental substrate above; the sealed-phase
  architecture and single-owner discovery were chosen not to preclude it.
- **Windows** support and benchmarks.
- **`--fix`-style quick suggestions** (TS2551 "did you mean" already
  exists; expand).
- **Shared simple-type interner** across checkers — extend M9.3's frozen
  base beyond lib/`@types` to hot non-lib simple types if the census shows
  they dominate the per-checker duplication (memory dial, §7).
- **Incremental persistence** (on-disk graph cache for CI cold starts).
