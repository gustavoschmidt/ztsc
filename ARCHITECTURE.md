# Architecture

ztsc is a **functional core behind an imperative shell**. The core — scanner,
parser, binder, linker, checker — is a chain of plain functions over immutable
inputs. The shell is `src/main.zig`, and nothing else: it owns every long-lived
arena, spawns every thread, and holds the one shared mutable service.

This is not an aspiration; it is the current shape of the code. The document
exists so that changes preserve it, because the parallelism and the
determinism guarantee both rest on it.

## The cycle

Each phase is a function: inputs it may not mutate, one value out.

| phase | signature | where |
| --- | --- | --- |
| scan | `tokenize(alloc, src) -> Tokens` | `src/scanner.zig:65` |
| parse | `parse(gpa, src) -> Ast` / `parseOpts(gpa, src, jsx)` | `src/parser.zig:87`, `:91` |
| bind | `bind(arena, io, gpa, interner, tree: *const Ast, src, is_dts) -> Bind` | `src/binder.zig:743` |
| link | `link(arena, gpa, io, interner, files: []const ProgFile, allow_synthetic_default) -> LinkResult` | `src/modules.zig:192` |
| base store | `buildBaseStore(store_arena) -> types.Store` | `src/checker.zig:238` |
| check | `checkFiles(arena, io, gpa, interner, prog: *const Program, owned: []const FileId, base: ?*const types.Store, inst_cache_on) -> Check` | `src/checker.zig:157` |

The shell threads them together. A worker runs the whole per-file front end —
load, parse (which tokenizes), bind — and pushes a completion message
(`Worker.discoverRun`, `src/main.zig:296`; `processFile`, `:317`). The main
thread is the sole owner of the module graph and resolves each completion's
specifiers as it arrives. Discovered files are then renumbered into a
graph-derived BFS order (`src/main.zig:794`), linked serially into a
`Program` (`:868`, `:871`), and handed to N checker instances
(`CheckerTask.run`, `:431`) that read the same `*const Program` without locks.

The recurring idiom inside a phase is **mutable builder → `seal()` → immutable
value**: `Binder.seal` (`src/binder.zig:2702`) flattens scratch state into
arena-allocated immutable arrays; `Checker.seal` (`src/checker.zig:880`) keeps
only owned-file diagnostics, sorted. `Program.links` are sealed before any
checker starts; the shared base type store is frozen (`base.freeze()`,
`src/checker.zig:240`) before it is shared.

## The rules

1. **Phases are functions.** Inputs are `const` (`tree: *const Ast`,
   `prog: *const modules.Program`). A phase never reaches back into its
   caller's state.
2. **Outputs land in a caller-owned arena** and are sealed on return. The
   caller decides the lifetime; the phase does not free what it returned.
3. **Internal scratch dies inside.** `binder.bind` and `modules.link` each
   open a private scratch arena with `defer …deinit()`; `checkFiles` frees the
   checker's four internal arenas in `Checker.deinit` (`src/checker.zig:846`).
   Nothing transient outlives the call.
4. **No file-scope mutable state.** One `var` at file scope exists in all of
   `src/` — see *Designated impurities*. Everything else is a parameter or a
   local.
5. **Only `main.zig` spawns threads and owns instances.** The only
   `std.Thread.spawn` call sites in non-test code are `src/main.zig:682`
   (front-end workers) and `:969` (checkers); the third in `src/` is inside
   the interner's own concurrency stress test (`src/intern.zig:343`).
   Library code is thread-agnostic:
   it is safe to call in parallel because it touches nothing shared, not
   because it coordinates.
6. **Effects are explicit capability parameters.** `io: Io` for the clock and
   the filesystem, `arena` / `gpa` for allocation, `interner` for interning.
   A phase that does not take `io` cannot do I/O.

## Designated impurities

Two, both deliberate, both bounded.

**The interner** (`src/intern.zig`) — one `Interner` instance, created at
`src/main.zig:589` and passed everywhere as `*Interner`. It is the single
designated shared-mutable service. It must be shared: an `Atom` is only
meaningful within the interner that produced it, so every phase on every
thread has to agree on one. It is safe to share because it is **append-only**
(atoms are never reassigned or removed) and **sharded** by string hash into 16
independently locked shards, so concurrent interning contends only on a hash
collision. Determinism does not depend on interning order — the lib's strings
are seeded single-threaded first (`seedLibAtoms`, `src/main.zig:678`) so the
atoms that matter are run-to-run stable.

**The `fs_probes` counter** (`src/resolve.zig:500`) — a
`std.atomic.Value(u64)` counting filesystem syscalls for the `--timing`
resolve-cache scoreboard. Pure telemetry: nothing reads it to make a decision,
so it cannot affect output. Resolution is single-owner, so it is never truly
contended; it is atomic as insurance.

## Why the shape is load-bearing

The headline guarantee is **byte-identical output at any worker or checker
count**. That is a direct consequence of the rules above, not a feature
implemented on top of them:

- The checkers run concurrently over the *same* `*const Program`. That is only
  sound because nothing downstream of `link` mutates shared state.
- `checkFiles` returns diagnostics for its owned files, sorted by
  (file, position, code) — so concatenating the outputs of **any** partition
  of the program's files yields identical bytes (`src/checker.zig:151-156`).
  Scheduling can change *who* checks a file, never *what* is reported.
- File order is derived from the module graph, never from completion order
  (`src/main.zig:794`), and the checker partition is cost-based with
  deterministic tie-breaks (`src/main.zig:894`).

The gate: `test "determinism: diagnostics byte-identical for N = 1, 2, 4, 8
checkers"` (`test/run_conformance.zig:472`) runs on every `zig build test`. It
renders a multi-file program's full diagnostics once per partition size
(`renderProgramDiags`, `:422`) and requires the results to match byte for
byte; the cycle-stress test (`:531`) and the cross-file-cycle determinism test
(`:593`) do the same over import cycles.
A change that quietly introduces shared mutable state fails here rather than
in production. (The 622 conformance cases themselves are single-program runs —
they pin *what* is reported; these tests pin that the partition cannot change
it.)

The memory numbers lean on it too: because a phase's scratch dies inside the
phase and its output is a sealed value in a caller-owned arena, peak RSS is
the sum of live sealed data — not of every allocator that ever ran.

## File layout

Every module in `src/` reads top-down in one order: the `//!` file doc
comment, then the public entry functions, then the public types they traffic
in, then the private implementation, then the tests. `src/parser.zig` and
`src/checker.zig` are the reference. Types-only contract modules
(`src/types.zig`, `src/ast.zig`) are exempt by nature — they are all surface.

`pub` means "has a consumer in another file", not "looks reusable". Eight
functions in `modules.zig` were public with no caller anywhere in `src/` or
`test/`; withdrawing them changed nothing but the apparent size of the module's
API. Check that with the compiler, not with intent.

A module is one concern. What was `modules.zig` is four files, each with its
own head and its own tests:

| file | concern |
| --- | --- |
| `src/modules.zig` | the program: `FileId`, `Program`, `ProgFile`, `Target`, `link`, `buildProgram`, the cross-file global merge |
| `src/libs.zig` | embedded `lib.*.d.ts` shards: `LibSet`, `resolveLibSet`, `libFiles`, `libSourceFor`, `isLibPath`, `seedLibAtoms` |
| `src/paths.zig` | lexical path predicates and algebra, no filesystem: `normalizePath`, `dirnamePart`, `joinNormalize`, `isDeclarationPath`, the any-module predicates and their synthetic sources |
| `src/resolve.zig` | specifier resolution: `resolveStem`, `scanReferences`, the `exports`-map machinery, `ResolveCache`/`FsCache`, `fs_probes` |

They import each other freely (Zig permits mutual file imports); `Error`,
`FileId` and `Program` stay in `modules.zig` because they are the
project-wide data contract every consumer already names.

## Adding a lever

Performance work goes *behind* a phase signature, not around it. Swap the
implementation, keep the signature and the rules — const in, sealed value out,
scratch freed, no new shared state — then run the gate:

```sh
zig fmt build.zig src test
zig build test          # 622 conformance + unit, includes the determinism test
bench/e2e.sh multi      # wall clock + peak RSS vs tsgo
bench/crash_sweep.sh    # 8 packages × --checkers=1..16, crash + byte-identity
bench/repeat_sweep.sh   # 8 packages × one config × N runs, byte-identity
```

Plus the byte-identical check on a real project (see `CLAUDE.md`). If a lever
needs shared mutable state to pay off, that is a contract change: it needs the
interner's justification — append-only, sharded, and provably unable to change
what is reported — or it does not land.

`bench/crash_sweep.sh` is required for anything that can hand a stale pointer
or a held slice to a parallel checker — resolver, symbol, interner and checker
changes. It runs each benchmark package (`bench/fetch_real.sh` vendors them) at
every checker count from 1 to 16 and fails if a run exits unexpectedly, stops
before its closing `ztsc: loaded …` summary, or reports different diagnostics
than its siblings — a crash mid-check exits *after* printing a prefix of the
diagnostics, so "it printed something" is not evidence it finished. That
failure mode is why the gate exists: at the default 4 checkers, on drizzle-orm
alone, a held type-parameter slice was invalidated by interning and the checker
died before reporting any of its 80 diagnostics, and a published benchmark row
timed the dead process. Its per-package tell was subtle — peak RSS at 4
checkers equal to peak RSS at 1 — but its exit code and its truncated output
were not.

`bench/repeat_sweep.sh` covers the other axis: the same binary, the same
configuration, run N times. Agreement across configurations does not imply
agreement with yourself — a single checker is still fed by a multi-threaded
front end, so two runs of `--checkers=1` are two different interleavings.
Concretely, the atom *set* is identical every run but the id assignment never
is (`Interner.intern` numbers by per-shard insertion order), and atoms are
sort keys for a scope's member table (`Binder.seal`) and for a merged
namespace's member index (`Merger.buildNsMembers`) — so the order the checker
reaches types in varies by design, and the contract is that nothing observable
may depend on it. The bug that motivated the script was an internal quantity
that did: the instantiation budget exempted origin-tagging work, so a
memoized first visit was charged or not depending on which side of the exempt
window it fell on, and `inst_count` moved between repeat runs on drizzle-orm.
Diagnostics never followed it (the budget is dormant), but it gates TS2589 —
an order-dependent decision variable is a defect whether or not it has
surfaced yet.
