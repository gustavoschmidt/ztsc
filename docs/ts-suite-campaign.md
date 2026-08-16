# TS test-suite compat campaign — state and continuation guide

Goal: **diagnostic compat with tsc (tsgo 7.0.2) on the full TypeScript test
suite**, excluding unsupported configurations (strict:false, JS cases,
unsupported compiler options). Campaign runs in waves of 4 parallel opus
worktree subagents, one per area, merged sequentially with gates.

## Standings (2026-08-16, main @738db70)

| metric | start (wave 3 kickoff) | now |
|---|---:|---:|
| exact-match cases | 4902 / 7815 (62.7%) | **6255 / 8542 (73.2%)** |
| excess keys (false positives) | 3541 | 2418 |
| missing keys (under-reports) | 8617 | 5516 |
| bucketed (ztsc parse error, incomparable) | 825 | 99 |
| crashes / hard timeouts | 0 / 1 | 0 / 0 |

Ten waves landed (3–10), every one with ZERO match→non-match regressions in
the combined sweep (4 accepted, documented, later-fixed flips in wave 9),
conformance green after every merge, perf within the tsgo bars, and the two
parity apps (excalidraw, social-app) diagnostic-identical or tsgo-proven
better. Excalidraw is at exact 17/17 key parity with tsgo (via
`tsconfig.tsgo.json`, the shared config both compilers accept). The
package-identity dedup (wave 10) also cut drizzle to 148 ms wall / 37 MB RSS —
within a hair of its long-open ≤144 ms bar.

## How to reconstruct the environment on a fresh machine

Everything gitignored is scripted:

1. Corpus + oracle + report harness: `bench/fetch_ts_suite.sh` (sparse-fetches
   microsoft/TypeScript @ `4d4f005c8541e0255a9d8791205fdce326e462bc`, the
   typescript-go v7.0.2 submodule pin), `cd bench/baselines/tsgo && npm
   install` (pinned tsgo 7.0.2), `bench/fetch_real.sh` + `node
   bench/gen_corpus.js` for the package corpus.
2. App checkouts (bench/apps, gitignored — PINS RECORDED HERE on purpose):
   - excalidraw `a2ec2889` + `yarn` (~1 GB); `tsconfig.tsgo.json` reproduced
     verbatim in BENCHMARKS.md. THE parity-gated app: 2 link + 15 check
     errors, 17/17 keys vs tsgo.
   - social-app `51401e4c0` + pnpm (second gated app: 46 link + 94 check).
   - immich `cafd6c7c0` + `pnpm install` + `pnpm --filter
     "@immich/plugin-sdk..." build` (without the build: 13 false TS2307).
   - outline `2cc0d60ed`, vscode `1415e6ab` (staged, uncited).
   - pnpm gotcha: corepack signing keys are stale; use `npm i --prefix
     /tmp/pnpmroot pnpm@10` and `manage-package-manager-versions=false` in the
     checkout's `.npmrc` (the dirty `.npmrc`/lockfile in checkouts is the
     documented workaround, not contamination).
3. Baseline sweep: run the harness once at HEAD to regenerate
   `bench/ts-suite/report.{md,tsv}` (~7 min at --jobs 10); expected numbers
   above.

## The wave protocol (what worked; distilled from 10 waves)

- 4 opus worktree agents per wave, disjoint file ownership: (A) parser/scanner/
  grammar, (B) relation/assignability/calls/tuples, (C) expr/stmts/flow/
  narrowing/accessibility, (D) binder/linker/classes/modules. Name the exact
  files each owns; pre-approve specific one-line crossings; both duplicate-fix
  incidents came from unowned overlap.
- Every agent gates on: zero baseline-match → non-match in a full sweep
  (normalize `(\.\./)+` → `LIB/` in TSV keys before diffing — key paths embed
  the --work depth); `zig build test` green; `zig fmt` clean; and BOTH app
  diffs (excalidraw incl. tsconfig.tsgo.json, social-app) empty or every
  changed line tsgo-proven. Relation agents also run drizzle/zod/typebox
  interleaved A/B (typebox is the memo-buster canary).
- Merge sequentially, `zig build test` after each merge, then one combined
  full sweep + interleaved perf A/B old-vs-new on all 8 packages + multi +
  both apps, then push. Wave gains have composed additively every time.
- Known traps: the corpus does NOT cover every app shape (two parity incidents
  came from relation changes the sweep passed); tsc suppresses ALL semantic
  diagnostics in a file with parse errors (so a new false parse error
  suppresses en masse); `relationComplexityError.ts` times out only under
  high parallel load (exempt); ztsc probe tsconfigs need a `files` list
  (`include` globs silently match nothing); never run `git stash` in
  worktrees; scope any pkill to the worktree path; agents should commit early
  and often (machine sleeps have destroyed uncommitted worktrees).

## Ranked next queue (wave 11)

1. `contextualCallSig` arity filter done properly — filter INSIDE each union
   constituent before combining (tsc `getContextualSignature`); the naive
   post-selection filter causes an excalidraw FP (reactUtils.ts:14:5 TS7006).
   Corpus-wide TS7006 payoff.
2. Decorator context `& { name; private; static }` intersection (~20 lines,
   removes a live FP risk on `context.name`).
3. Flow round: switch-clause exclusion chain (narrow.zig, ~14 keys);
   dependent rest-tuple params (11+; blockers: `propOfType` has no
   numeric-index answer on `.tuple`; contextual sig not recoverable from the
   param symbol — needs a per-function-node memo); optional-chain link types
   (deleteChain, 8); object-literal union widening `prop?: undefined` (8);
   evolving arrays `let x = []` (~10).
4. TS2411 residue: type literals (forces annotation resolution — measure);
   `[k: symbol]` class index dropped by `classIndexInfos`; ctor param props.
5. Parser: 10 false TS1166 on decorated members; ~51 remaining false-parse
   cases; TS1125-in-regex (17); TS1262; JSX recovery TS17008/1381/1382 (16+).
6. Modules: TS2882 (side-effect import of missing module); `export import`
   re-export decision (ImportData.flags); index-signature parameter modelling
   (ast.IndexSig field) → TS2369/2371/7006; qualified-entity arm in
   alias_cycle.zig.
7. Relation: mixin residue (~6: `baseClassRef` returns null for a type-param
   base and `hasUnresolvedBase` silences); strictBindCallApply (blocked on a
   generic-method `.bind` inference leak — see the social-app FP at
   analytics/index.tsx:314); stringMappingOverPatternLiterals (27);
   mappedTypeRelationships (22).
8. Determinism defect with a concrete witness: social-app `--checkers=1` and
   `--file-order=reverse` diverge; `Navigation.tsx:778:29` prints
   `NativeStackNavigationProp<{…}>` in one partition and the expanded shape in
   the other — type identity, not printing. Pattern-matches the open
   instantiation-budget partition bug (budget charges misses not hits).
   Cheapest instrumentation point is that line.
9. Structural harness item: ~58 missing keys / 12 cases point inside tsgo's
   `lib.*.d.ts`; ztsc reports the same diagnostics at its own embedded lib
   positions. Needs harness-side lib-position canonicalization, not checker
   work.

Skips (by design, per goal): 2154 strict:false cases, 801 JS cases, ~627
unsupported-option cases, plus harness-only categories.
