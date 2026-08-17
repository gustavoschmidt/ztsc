# TS test-suite compat campaign — state and continuation guide

Goal: **diagnostic compat with tsc (tsgo 7.0.2) on the full TypeScript test
suite**, excluding unsupported configurations (strict:false, JS cases,
unsupported compiler options). Campaign runs in waves of 4 parallel opus
worktree subagents, one per area, merged sequentially with gates.

## Standings (2026-08-17, post wave 13 + lib-key scoping)

| metric | start (wave 3 kickoff) | now |
|---|---:|---:|
| exact-match cases | 4902 / 7815 (62.7%) | **6627 / 8627 (76.8%)** |
| excess keys (false positives) | 3541 | 2208 |
| missing keys (under-reports) | 8617 | 4640 |
| bucketed (ztsc parse error, incomparable) | 825 | 13 |
| crashes / hard timeouts | 0 / 1 | 0 / 0 |

Thirteen waves landed (3–13), every one with ZERO match→non-match regressions in
the combined sweep (4 accepted, documented, later-fixed flips in wave 9),
conformance green after every merge, perf within the tsgo bars, and the two
parity apps (excalidraw, social-app) diagnostic-identical or tsgo-proven
better. Excalidraw is at exact 17/17 key parity with tsgo (via
`tsconfig.tsgo.json`, the shared config both compilers accept). The
package-identity dedup (wave 10) also cut drizzle to 148 ms wall / 37 MB RSS —
within a hair of its long-open ≤144 ms bar.

Wave 11 (+221 cases, conformance 1290→1304 with new cases): A landed the
decorator-grammar cluster (TS1206/1249/1207/1433, killed the false TS1166s),
dotted/quoted/anonymous namespace names, break/continue placement (TS1104-16),
and cut bucketed parse cases 99→13. B landed the per-constituent
contextualCallSig arity filter (tsc's `getContextualSignature` shape) and the
decorator context `& { name; private; static }` intersection. C landed the
switch-clause exclusion chain, the entire `checkReferenceExpression` family
(TS2357/2364/2406/2487/2701, TS2777-81, TS2628-31), optional-chain link types.
D landed `[k: symbol]` class indexes, TS2882 (and flipped
`noUncheckedSideEffectImports` default ON to match tsgo 7.0.2 — explicit
`false` restores 5.x), TS2374/TS2323/TS1194/TS1147, TS1202-family spans, ctor
param props vs index signatures.

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
   - Fresh-machine gotchas (2026-08-17 rebuild): brew `zig` (0.16.0) + `node`
     suffice; excalidraw's engine pin rejects node 26 — `yarn install
     --frozen-lockfile --ignore-engines`; social-app's postinstall shells out
     to `pnpm intl:compile-if-needed`, so put pnpm's bin dir on PATH for the
     install or it half-completes; excalidraw's `tsconfig.tsgo.json` is
     gitignored — recreate it from the verbatim block in BENCHMARKS.md.
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

Wave 12 (+59 cases, perfectly additive; conformance 1304→1307): A landed the
`Diagnostic.arg` span payload (interpolated messages; JSX TS17008/17002/17014/
17015), the TS1090 parameter-modifier family, for-in/of head grammar, lone-CR
line-table fix, emit-time dedup. B fixed the generic inference leak
(constraint-substituted contextual type for array-literal args — `pick()` now
matches tsgo) and mixins (`getBaseTypeVariableOfClass`). C landed contextual
union discrimination (`discriminate_ctx.zig`, object literals + JSX) and
re-landed the union-agreement rule (all 7 wave-11 losses recovered), plus the
compound-assign `getBaseTypeOfLiteralType` narrowing fix. D fixed ambient-block
scope parenting + `mergeAmbientBlocks`, TS1437-as-syntactic, and a +20
typespace/link haul (TS2709/2503/2702/2833/2661). Combined perf: packages and
excalidraw flat; social-app +1.66% wall (staged app, under the 2% bar).
Wave-12 residue notes (with in-code documentation): regex FLAGS validator
reverted (cost 3, gained 0 — blocked on `#!` scanning); TS2709-on-alias and
`resolveNsContainer` alias-following backed out (blocked on dual export-table
entries and the JSX hyphen-in-spread rule respectively).

Wave 13 (+79 cases; conformance 1307→1309): A landed tsc's evolving-array
protocol (binder FlowArrayMutation → flow-only marker kind finalized on exit —
the marker never escapes flow.zig). B landed the TS2693 cluster (+18), TS2783
re-land (excalidraw FP confirmed gone), module-scope `this` (script top-level =
`typeof globalThis`), per-member `implements` blame TS2416/TS2720 (+16),
TS2564-for-computed-names (+10). C landed strictBindCallApply
(CallableFunction/NewableFunction; contravariant `this` inference; 0/26 →
24/26 keys) and string-mapping distribution into pattern templates. D landed
dual export-table entries + TS2709 re-land, the JSX hyphen-in-spread rule +
resolveNsContainer re-land (both wave-12 backouts survived their witnesses),
TS2713/TS2749, TS2614/TS2460 ordering, and UTF-16 diagnostic columns (0.00%
measured cost). Harness afterwards: tsgo-bundle-internal `lib.*.d.ts` keys are
structurally unmatchable (different lib text) and are now scoped out of the
comparison (+13 cases, −58 missing keys, zero lost).
NOTE for app-parity captures: ztsc's stdout positions from offset 0 in a
regular file, so `> file 2>&1` silently overwrites the stderr config-warning
lines — capture apps exactly that way (as all baselines were), or diff will
show phantom warning lines when you switch to a pipe.

## Ranked next queue (wave 14) — distilled from wave-13 agent reports

1. Class-expression typing — blocked one binder line: `bindClass`
   (binder.zig:2887) declares no self-symbol when `name_token == 0`; add the
   `declare(cs, <reserved atom>, .class, …)` + the two member_scopes/
   static_scopes registrations, make `checkClass` look the symbol up in the
   class's OWN scope (today only `saved_scope`, so even named class exprs get
   no_symbol), and return `classStaticType(sym)` from expr.zig's `.class_decl`
   arm. Unlocks mixinClassesAnonymous residue, mixinAccessors3,
   typeArgumentInferenceWithClassExpression1/3.
2. Link/typespace mapped residue: TS2694 on the RHS of `import X = A.B.C`
   (+5, right site is the import-equals declaration check in stmts.zig);
   TS2708 "cannot use namespace as a value" (+6, expr.zig/classes.zig);
   TS2709 for an entity-name alias used bare as a type (moduleVisibilityTest3,
   `importTarget == null` arm of resolveTypeName returns `any`).
3. `export as namespace` (UMD globals) — 18 cases, TS2686/TS2451/TS2303,
   touches the global table.
4. templatesDefinitelyUnrelated re-land: patch measured (−8 keys, sweep-clean);
   blocked on object-literal elaboration through a GENERIC parameter anchoring
   one line late (excalidraw @ts-expect-error at transform line 109 vs 110).
   Fix the elaboration anchor, then re-land.
5. `Uppercase<string>` stays deferred + `isMemberOfStringMapping` in the
   relation (the other 14 stringMappingOverPatternLiterals keys).
6. `checkIndexedAccessIndexType` on element-access EXPRESSIONS (TS2536 +
   TS2542, ~21 keys of mappedTypeRelationships): decidable rule is small
   (bare-type-param object + different-type-param keyof index → TS2536;
   assignable index + readonly mapped object → TS2542); call sites in expr.zig.
7. `prop?: undefined` union widening — implementation exists (wave-13 B
   reverted at the app gate): members match tsgo, but comparability vs
   excalidraw's ExcalidrawElementSkeleton union then produces 2 false TS2352
   in assign.zig. Fix comparability first; gate must be the app.
   Note the no-contextual-type gate (recursive-JSON conformance case).
8. Flow residue: `isPastLastAssignment` for the PLAIN auto type (6 keys,
   2 cases — needs the marker treatment + tsc's branch-label join shortcut;
   redesign-sized); `controlFlowArrayErrors`'s last key (push signature read
   off a UNION of array types — calls.zig); enum reverse-mapping numeric index
   (`ENUM[1]` → `string`, enums.zig, 2+ cases).
9. Generator yield contexts: `contextualTypeOnYield1/2` +
   `generatorTypeCheck27-30` blocked in signatures.zig — an arrow as a yield
   operand is typed during the enclosing generator's return-type inference
   with a fresh fn_ctx whose yield_type = 0.
10. TS2564 residue: bracketed LITERAL names (`[0]:`, `[""]:`) need an
    l_bracket bit the parser computes and discards (~3 keys); TS7006
    one-key-off contextual-IIFE/binding-pattern family (part of 28 cases).
11. Regex BODY validator (dedicated wave-sized: quantifier braces, classes,
    group modifiers; wrong error is syntactic = program-wide suppression).
12. Determinism defect with a concrete witness: social-app `--checkers=1` and
    `--file-order=reverse` diverge; `Navigation.tsx:778:29` prints
    `NativeStackNavigationProp<{…}>` in one partition and the expanded shape in
    the other — type identity, not printing. Pattern-matches the open
    instantiation-budget partition bug (budget charges misses not hits).
13. Cosmetic (keys match, text doesn't): bound signatures print
    `(...args: [string]) => string` unexpanded; fresh literals not widened in
    TS2345/TS2322 message text.

## Superseded queue (wave 13, kept for context)

1. expr.zig:365 types EVERY class expression as `any` — unlocks
   mixinClassesAnonymous residue, mixinAccessors3,
   typeArgumentInferenceWithClassExpression1/3, and removes the one FP risk
   B's mixin fix noted. Related: `contextAdmitsLiteral` (expr.zig:1810) has no
   `.index_type` arm (tsc's mask includes `TypeFlags.Index`) — the generic fix
   for the `[...K]` variadic `pick` shape.
2. TS2693 cluster (~20 cases, exactly one extra key each): `export default
   interface` falls into stmts.zig:180's `else => checkExprCached(d.lhs)` and
   checks the interface body as an expression; `export default <type>` /
   `export = <interface>` need checkIdentifier to resolve in all meanings.
3. Evolving arrays — to the expr.zig owner (D mapped it precisely): binder
   FlowArrayMutation (~40 lines: `bindCallExpressionFlow` push/unshift arm +
   `=` on ElementAccessExpression in bindBinaryExpressionFlow), flow
   `getTypeAtFlowArrayMutation`, expr `checkArrayLiteral` autoArrayType +
   checkIdentifier auto arm + a new "final flow type still auto" predicate for
   TS7034/TS7005 (the existing checkEvolvingVarRead predicate is closure-gated
   and CANNOT express it).
4. TS2783 re-land (24 keys / 8 cases; the check was corpus-clean) — now
   unblocked by B's inference fix. See wave-11 C's reverted commit.
5. Object-literal union widening `prop?: undefined` (~8 keys) — still queued,
   twice deferred.
6. strictBindCallApply: model the CallableFunction/NewableFunction
   bind/call/apply overload family (pure under-report, 26 keys in
   strictBindCallApply1 alone).
7. Dual export-table entries (`export type Drink` + `export * as Drink`)
   — unblocks re-landing TS2709-on-alias (+2 measured).
8. JSX hyphen rule for spread string-literal keys (jsx.zig:529 has the direct
   arm; assign.zig's excess check misses the spread path) — unblocks
   re-landing `resolveNsContainer` alias-following (+3 measured).
9. typespace/link residue: TS2713 where the qualifier type has the property
   (guarded propOfType from reportBadNsQualifier); TS2749 over a whole dotted
   name (genericFunduleInModule 1/2); TS1046 one-line arm in
   checkDeclFileTopLevel for quoted ambient modules in .d.ts; TS1308.
10. discriminate_ctx spread-element bail (conservative vs tsc) — revisit for
    gains.
11. stringMappingOverPatternLiterals (27 keys); mappedTypeRelationships
    remaining ~20 keys (TS2536 in index_constraints, TS2542 readonly writes);
    module-scope `this` typing + TS2356-before-TS2357 ordering (2 cases).
12. Local classes parameterized by enclosing generic function's type params
    (tsc outerTypeParameters) — large, perf-sensitive; measure first.
13. Non-BMP columns: ztsc reports byte offsets where tsgo reports UTF-16 code
    units (regularExpressionWithNonBMPFlags.ts).
14. Determinism defect with a concrete witness: social-app `--checkers=1` and
    `--file-order=reverse` diverge; `Navigation.tsx:778:29` prints
    `NativeStackNavigationProp<{…}>` in one partition and the expanded shape in
    the other — type identity, not printing. Pattern-matches the open
    instantiation-budget partition bug (budget charges misses not hits).
    Cheapest instrumentation point is that line.
15. Structural harness item: ~58 missing keys / 12 cases point inside tsgo's
    `lib.*.d.ts`; ztsc reports the same diagnostics at its own embedded lib
    positions. Needs harness-side lib-position canonicalization, not checker
    work.

## Superseded queue (wave 12, kept for context)

1. Contextual-type discrimination (tsc `discriminateContextualTypeByObjectMembers`
   / `…ByJSXAttributes`, expr.zig). MEASURED unblock: B implemented the
   "union constituents must agree" signature rule (`compareSignaturesIdentical`)
   and it went -7/+2 *only* because ztsc never discriminates the union first;
   land discrimination, then re-land the rule (commit `2470fc5` reverted it) —
   gains `contextualTypeWithUnionTypeCallSignatures` +
   `contextualOverloadListFromUnionWithPrimitiveNoImplicitAny` and the
   discriminated-literal TS7006 family.
2. Mixins (classes.zig/statics.zig, ~4-6 cases): tsc `getBaseTypeVariableOfClass`
   — a class whose base ctor type is a type variable gets its STATIC type
   intersected with that variable. Was diagnosed by B but blocked on file
   ownership. Fixes mixinAbstractClasses{,.2}, mixinClassesAnnotated,
   probably mixinClassesAnonymous.
3. Generic inference leak, oracle-confirmed repro: `pick(COLOR_PALETTE,
   ["cyan"])` with `<R, K extends readonly (keyof R)[]>(...) => Pick<R,
   K[number]>` infers K as its CONSTRAINT, not the argument tuple (tsgo:
   `Pick<…,"blue"|"cyan">`, ztsc: whole object). Blocks re-landing TS2783
   (24 keys / 8 cases, C's revert `e65765f`; the check itself was
   corpus-clean); likely the same root as the strictBindCallApply
   generic-method `.bind` leak (social-app analytics/index.tsx:314 FP).
4. Compound-assign/increment narrowing bug (flow.zig, oracle-confirmed,
   pre-existing): `assignNarrows` increment arm returns
   `assignmentReduced(declared, number)`; tsc returns
   `getBaseTypeOfLiteralType(antecedentType)` (`let y: 1|2 = 1; y++` → tsc
   `number`, ztsc `1|2`). Found by C, deliberately left unswept.
5. Evolving arrays `let x = []` (~23+ keys with TS7034/7005): needs a
   FlowArrayMutation-style node in binder.zig + flow.zig consumption —
   cross-area, give one agent both files.
6. Object-literal union widening `prop?: undefined` (~8 keys): each widened
   object-literal constituent gains `prop?: undefined` for sibling-declared
   props (tsc `getWidenedTypeOfObjectLiteral` + `getUndefinedProperty`);
   needs sibling context threaded through widening. Real app risk — gate hard.
7. Diagnostic text payload: `frontend.Diagnostic` carries a static Code only;
   messages that interpolate (JSX TS17008/TS17002 family, 5 cases) need a text
   field + source-buffer lifetime decision (touches parser/binder/bind_result).
8. Index-signature parameter shape: parser computes `index_signature.Shape`
   (modifier/initializer/`?`) then discards it; add the ast.IndexSig field the
   parser FILLS, then TS2369/TS2371-specific/TS7006 land (needs parser +
   binder in one agent's hands).
9. Binder/modules residue from A: anonymous `module {}` should merge into the
   enclosing container (innerModExport1/2 false TS2339); ambient-module import
   not reaching a nested augmentation (moduleAugmentationInAmbientModule*
   TS2304, now visible since those cases left the bucketed set).
10. Scanner regex-body validator (tsc scanner.ts regex pass): TS1125/1512/
    1535/1499 UNDER-reports (4 cases — wave-11 brief mislabeled these as FPs).
11. Cheap parser wins A scouted: TS1090 (parameter modifiers, 3 cases),
    TS1046 (.d.ts top-level, 1), remaining TS1011 position in newOperator.ts,
    TS1308 for exportDefaultAsyncFunction2.
12. TS2411 on type literals — needs a checker hook on every `.type_literal`
    (stmts.zig); measure the annotation-resolution cost first (D skipped it
    as the flagged perf risk).
13. Determinism defect with a concrete witness: social-app `--checkers=1` and
    `--file-order=reverse` diverge; `Navigation.tsx:778:29` prints
    `NativeStackNavigationProp<{…}>` in one partition and the expanded shape in
    the other — type identity, not printing. Pattern-matches the open
    instantiation-budget partition bug (budget charges misses not hits).
    Cheapest instrumentation point is that line.
14. Structural harness item: ~58 missing keys / 12 cases point inside tsgo's
    `lib.*.d.ts`; ztsc reports the same diagnostics at its own embedded lib
    positions. Needs harness-side lib-position canonicalization, not checker
    work.

Skips (by design, per goal): 2154 strict:false cases, 801 JS cases, ~627
unsupported-option cases, plus harness-only categories.
