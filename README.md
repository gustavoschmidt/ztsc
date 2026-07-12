# ZTSC — Zig TypeScript Checker

A TypeScript type checker written in Zig. Goals for v0.0.1 (see
[PLAN.md](PLAN.md)):

- **Speed**: same order as TypeScript 7 (`tsgo`) on equivalent workloads.
- **Memory**: the headline goal — **≤ 50% of tsgo's peak RSS**, via a
  data-oriented AST (u32 indices, struct-of-arrays), phase-lifetime arenas,
  and hash-consed types.
- **Parallel from the start**: per-file parse/bind on a thread pool,
  N independent checker instances.

ZTSC only *checks* — no JS emit. It targets a defined subset of TypeScript
(PLAN.md §5) with `strict` semantics.

## Status

M1 (scanner): full TypeScript token set — all operators, keywords +
contextual keywords, template literals (head/middle/tail with brace-depth
tracking), regex rescanning, numeric/bigint/string literals, ASI newline
flags, error tokens for unterminated constructs. Tokens are stored
struct-of-arrays at **5 bytes/token** (1-byte tag + 4-byte start with the
newline flag packed in bit 31); ends and line/col are recomputed lazily.
The CLI scans loaded files in parallel. Fuzz + byte-soup stress tested.

M2 (parser + AST): recursive descent over the full PLAN §5 subset syntax —
modules (incl. type-only imports/exports), functions/arrows/overloads,
classes, interfaces, type aliases, generics, the type grammar, all
statements, and the full expression grammar with correct precedence and
optional chaining. The parser drives the scanner with grammar context
(tsc-style rescans for regex / template parts, `>>` splitting for nested
generics) and disambiguates arrows and generic calls by speculation with
snapshot/restore. The AST is data-oriented per PLAN §2.1: `u32` node
indices, `std.MultiArrayList` SoA storage (13 bytes/node fixed), shared
`extra_data` — **~16.2 bytes/node** including extra_data on the medium
corpus (target was ≤ 24), ~3.2 nodes/line. Error recovery synchronizes at
statement boundaries and the parser is total: random byte/token soup always
terminates with diagnostics (stress + fuzz tested). Out-of-subset syntax
(enums, namespaces, decorators, mapped/conditional types, ...) parses to an
`unsupported` node with a clean "not supported in ztsc v0.0.1" diagnostic.
Parse runs ~10.5M lines/s single-thread (ReleaseFast, Apple Silicon dev
machine), scaling ~5x at 8 workers.

M3 (binder): per-file symbol tables, scope trees, and a tsc-style
control-flow graph, all sealed immutable after bind. Symbols/scopes/flow
nodes are `u32` indices in SoA arrays; scope member maps are flattened at
seal time into atom-sorted segments looked up by binary search (no
per-scope hash maps). Hoisting follows modern semantics (`var` to the
function scope with order-independent var-vs-let conflict detection,
functions in blocks block-scoped, params + destructured params in the
function scope); let/const/class record their declaration site for M4's
TDZ checks. Duplicate declarations get tsc-compatible codes (TS2300,
TS2451, TS2393, TS2440, TS2492) while overloads, interface-interface
merge, and value/type-space sharing bind into one multi-declaration
symbol. Import/export records (named/default/namespace/re-export,
type-only) feed M5's module graph. The flow graph covers branches, loops
(with back edges), switch fallthrough, unreachable code, and `&&`/`||`/`!`
condition decomposition — attached to identifier/member reads via a
compact sorted (node, flow) map. `resolve(atom, scope)` walks the parent
chain; unresolved names are surfaced (not errors until M5). The binder is
total on arbitrary parser output (stress + fuzz tested). Bind runs ~12.7M
lines/s single-thread at **~29.5 binder bytes/line** on the medium corpus,
scaling ~4.2x at 8 workers.

M4 (checker core): hash-consed types (`TypeId` = u32; structurally
identical types intern to one id, so type equality is integer equality
and the assignability cache keys on id pairs), structural assignability
with tri-state relation caching (recursive types terminate), full subset
expression inference with contextual typing, literal freshness/widening
(tsc semantics: fresh literals widen at mutable positions, annotations
do not), excess-property checking for fresh object literals, overload
resolution (first match, like tsc), basic generic inference from
arguments with constraint fallback, and control-flow narrowing over the
M3 flow graph (truthiness, typeof, equality/discriminants incl. switch,
`in`, `instanceof`, assignment narrowing, single-level property paths;
loop back-edges restart from the declared type). Diagnostics carry tsc
codes and near-tsc message text (TS2322/2345/2339/2353/2367/2448/2454/
7006/2769/... plus the 2739/2741/2576/18048-style refinements tsc
actually emits). The 150-case conformance suite is generated from and
verified against real `tsc --strict` output (code + line must match).
Single-threaded check runs ~2.1M lines/s on the medium corpus at ~25.7
bytes/type, 0.34 types/line, 42% relation-cache hit rate. The checker is
total on arbitrary input (stress + fuzz tested). Parallel check + module
graph is M5.

## Build & run

Requires Zig 0.16.0.

```sh
zig build                 # debug binary in zig-out/bin/ztsc
zig build test            # unit tests + conformance suite
zig build bench           # ReleaseFast binary in zig-out/bench/ztsc

zig-out/bin/ztsc --version
zig-out/bin/ztsc --timing --memory src.ts other.ts
```

Flags:

- `--timing` — per-phase wall-clock ms, lines/s, MB/s (load, scan, parse,
  bind).
- `--memory` — per-arena bytes, interner bytes, token-array bytes,
  bytes/token, AST node/extra_data bytes, **bytes/node**, nodes/line,
  binder symbol/scope/flow/record bytes, **bind bytes/line**.
- `--dump-ast` — print S-expression parse trees (golden-test format).
- `--dump-symbols` — print binder scope/symbol/flow dumps (golden-test
  format), plus import/export records and unresolved names.
- `--workers=N` — worker thread count (default: CPU count).
- `--repeat=N` — re-scan/re-parse/re-bind each file N times (benchmark aid).
- `--version` — print version.

## Benchmarks

```sh
bench/run.sh small        # ~5k LOC synthetic corpus
bench/run.sh medium       # ~50k LOC synthetic corpus
bench/scan.sh medium 50   # scanner MB/s + 1/2/4/8-worker scaling
bench/parse.sh medium 50  # parser lines/s + scaling + bytes/node
bench/bind.sh medium 50   # binder lines/s + scaling + bytes/line
```

The harness generates deterministic corpora with `bench/gen_corpus.js`
(requires node), runs ztsc under `/usr/bin/time` (wall clock + peak RSS),
and — when `tsgo` or an installed `tsc` is available — runs the same corpus
through them for comparison.

## Layout

```
src/            main.zig (CLI/pool), source.zig (mmap, line tables),
                intern.zig (sharded interner), scanner.zig (tokenizer),
                ast.zig (SoA nodes + dump), parser.zig (recursive descent),
                binder.zig (symbols, scopes, flow graph),
                diagnostics.zig (shared diagnostic type)
bench/          harness (run.sh) + corpus generator (corpora are gitignored)
test/           conformance runner + cases (differential vs tsc)
```
