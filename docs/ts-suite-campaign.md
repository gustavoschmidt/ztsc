# TS test-suite compat campaign — state and continuation guide

Goal: **diagnostic compat with tsc (tsgo 7.0.2) on the full TypeScript test
suite**, excluding unsupported configurations (strict:false, JS cases,
unsupported compiler options). Campaign runs in waves of 4 parallel opus
worktree subagents, one per area, merged sequentially with gates.

## Standings (2026-08-17, post wave 16)

| metric | start (wave 3 kickoff) | now |
|---|---:|---:|
| exact-match cases | 4902 / 7815 (62.7%) | **6789 / 8627 (78.7%)** |
| excess keys (false positives) | 3541 | 2062 |
| missing keys (under-reports) | 8617 | 4360 |
| bucketed (ztsc parse error, incomparable) | 825 | 13 |
| crashes / hard timeouts | 0 / 1 | 0 / 0 |

Sixteen waves landed (3–16), every one with ZERO match→non-match regressions in
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

Wave 14 (+65 cases; social-app baseline stats line refreshed — 5028 files via
the scoped-@types mangling rule, diagnostics unchanged): A landed
class-expression typing (reserved-key self-symbol in bindClass; four latent
base-class bugs fixed at source; assigned-name printing) and enum reverse
mapping (identity-hidden numeric index a la tsc). B landed TS2694-on-import-
equals, TS2708, TS2709-bare, TS18013 private-name access (+9), TS2488
any-iterator rules (+5), TS2503-not-TS2304. C re-landed BOTH blocked items with
witnesses surviving — templatesDefinitelyUnrelated (real blocker: probe (2) of
bestMatchingUnionMember missed interface-derived array-likes) and
`prop?: undefined` widening (real blocker: lenientOverlap compared optional
property types without folding `| undefined`) — plus full
stringMappingOverPatternLiterals (29/29) via deferred string mappings +
isMemberOfStringMapping, and union-signature rest-param combining. D landed
`export as namespace` UMD globals (merge-chain + synthetic namespace),
ambient-module-body specifier resolution, scoped @types mangling
(mangleScopedPackageName), TS2306.

Wave 15 (+57 cases): A landed TS2403 block-scope rule, the `export =` TDZ
exemption, TS2686, and the full generator/IIFE contextual-type mechanism
(FnCtx.yield_ctx/gen_ret_ctx separate from the check target). B finished the
UMD↔global merge, TS2303 UMD alias node, and unified module-instance-state on
tsc's getModuleInstanceState (the five "TS2694 residue" cases were mis-mapped:
three are parse-suppression, two need resolution-mode import attributes — deep).
C landed getUnionSignatures' FIRST pass (bounded arity, TS2554/2555), the
weak-type rule for primitive sources (wrapper-interface members;
isKnownProperty excludes Object/Function augments), castComparable through
constraints one-way, and did-you-mean-to-call anchoring. D replaced
classifyEnumInit with tsc's createEvaluator (TS1061/1066/2474/2477/2478),
fixed intersection iteration, static-block flow scoping, TS2466.

Wave 16 (+40 cases; conformance 1309→1317): A landed the spread/destructuring
TS2488 arms, StrictArity union reduction, TS2507, TS2698, generator array-elem
context — and measured-then-skipped the two zero-yield targets. B landed tsc's
FlowFlags.ReduceLabel for try/finally (reduce depth carried in the RefKey so
the sealed shared flow graph stays immutable), the blockScopedSameNameFunction
fix (stmtTerminal scope tracking, not binder scoping), typeof-discriminant
narrowing. C landed trivial-conditional simplification (getSimplifiedConditionalType,
12 keys→0), infer-binder re-binding, check&extends substitution, homomorphic
array-bounded maps. D landed TS18033 + TS2651/TS2565 (second non-memoized
evaluator run), TS2433 cross-file merge, nested-ambient-module-as-augmentation,
TS2507 primitive arm. Mid-wave the social-app checkout lost its node_modules
hard-links (4778 files loading instead of 5028) — `pnpm install` repairs it;
check the stats line if link errors drop to 0.

## Ranked next queue (wave 17) — distilled from wave-16 agent reports

1. TS2440 re-diagnosed (8 keys): tsc emits from checkAliasSymbol using the
   alias TARGET's meanings (cross-file; a non-instantiated namespace target is
   type-only and clashes with nothing). Needs alias resolution, i.e.
   names.zig/link — NOT binder.zig where ztsc's emit sits today.
2. TS2649 final state: one global_dup case (noSymbolForMergeCrash) needs
   mergeClash to return the failing source INDEX (3 call sites in
   link/modules.zig); augmentExportEquals7 is oracle-confirmed a different
   mechanism (mergeModuleAugmentation's export=-to-non-namespace arm, reported
   on the "lib" specifier).
3. Readonly index signatures end-to-end (re-diagnosed): ztsc has NO readonly
   bit on index signatures anywhere — `readonly [s: string]` + write reports
   nothing (tsgo-verified). Needs a types.zig object flag, emission in
   expr.zig/readonlyIndexWriteAt, and the static-index grammar arms;
   staticIndexSignature2/4 (9 keys) plus mappedTypeRelationships f20/21.
4. Interface-extends-class-value gap: `interface X extends Y` where Y is a
   typeof-alias (IteratorObjectConstructor = typeof __ztscIteratorAbstract)
   drops everything inherited — source of builtinIterator's excess TS2351 and
   the withdrawn TS2507 object arm (which would also regain importAsBaseClass).
5. importInsideModule (misfiled earlier): TS2307 at a USE of an
   `import x = require()` alias inside a plain namespace — tsc's resolveAlias
   at the use site; fix belongs in names.zig.
6. TS2417 private/protected statics (4): nominal_members.declaringMember needs
   a class-symbol origin on the static side (produced in classes.zig/
   statics.zig, consumed in assign.zig).
7. TS2430 residue (3): interface method-overload replacement, decided in
   classes.zig's interfaceGeneric.
8. distributiveConditionalTypeConstraints residue (4 keys):
   getConstraintOfDistributiveConditionalType alone is too lenient (measured:
   fixes 3, breaks 2 — IsArray<T> under T extends object must stay boolean);
   needs whatever restriction tsc pairs it with.
9. strictBindCallApply1 last 2 keys: ztsc's this-parameter check passes
   leniently on a type-param target; for-of39/iterableArrayPattern28 need
   array-literal elaboration into an `Iterable<…> | null` target.
10. TS2683 this-container rule (9 cases): rule fully oracled (wave-15);
    still needs the enclosing-container walk; FP blast radius is the risk.
11. TS2693 residue (7, binder/expr), TS2454 dedup, and the big TS2322/TS2345
    census pools.
12. Regex BODY validator (dedicated: quantifier braces, classes, group
    modifiers; a wrong error is syntactic = whole-program suppression —
    bucketed gate is the tripwire).
13. nestedExcessPropertyChecking per-frame weak rule (risky; flow/062).
14. resolution-mode import attributes (deep, 2 cases).
15. Determinism defect with a concrete witness: social-app `--checkers=1` and
    `--file-order=reverse` diverge; `Navigation.tsx:778:29` prints
    `NativeStackNavigationProp<{…}>` in one partition and the expanded shape
    in the other. Pattern-matches the open instantiation-budget partition bug.

## Superseded queue (wave 16, kept for context)

1. expr.zig one-arm items (mapped exactly): array-literal SPREAD swallows
   iteration failure instead of TS2488 (expr.zig:1176); destructuring-
   ASSIGNMENT element typing never falls back / never reports TS2461/TS2488
   (expr.zig:5111 destructuringElementType) — iteratorSpreadInArray8/10,
   iterableArrayPattern23/24.
2. Enums, one step away each: TS18033 (checkEnum's !computed fall-through
   needs checkTypeAssignableTo(init, number) with elaborated wording — 3
   cases); TS2651 forward-reference (already DETECTED in forwardEnumMember;
   needs a separate syntactic pass in checkEnum because enumMembersOf is
   memoized/re-entrant).
3. try/finally definite assignment (flowAfterFinally1, oracle-confirmed FP):
   tsc's FlowFlags.ReduceLabel — post-finally flow drops the pre-try
   antecedent; ztsc's bindTry joins `pre` unconditionally. Real work.
4. unionReductionMutualSubtypes: typenode.reduceSubtypes must use
   SignatureCheckMode.StrictArity (parameter COUNT, not min-count) — keeps
   the wrong twin today; one-line-ish.
5. conditionalTypesSimplifyWhenTrivial (12 excess keys / 1 case): tsc
   resolves a conditional eagerly when the permissive check type fails the
   extends (→ false) or the restrictive one passes (→ true); ztsc defers.
6. blockScopedSameNameFunctionDeclaration* (4 cases, 8 excess TS2554):
   block-scoped function shadowing — binder scoping.
7. TS2440 import-conflicts-with-local (8 one-key cases, binder.zig);
   TS2649 (2 — global_dup.zig:67 documents the arm; mergeClash must return
   the failing source index; augmentExportEquals7 may be a different
   mechanism — oracle first); TS2693 residue (7, binder/expr).
8. TS2769 anchor: tsc uses the chosen candidate's own diagnostic span,
   falling back to the whole call node when candidates disagree (~4 keys,
   needs candidate-wise spans in calls.zig).
9. Readonly index residue, re-scoped by wave-15 C: `static readonly
   [s: string]` on classes (statics.zig/classes.zig, 9 keys in
   staticIndexSignature2/4, incl. TS2542 on property access); write-side
   check on generic mapped types + readonlyIndexWriteAt relaxed to objects
   (expr.zig indexed-access path); TS2536 type-node residue (18 keys,
   typenode.zig).
10. TS2417 private/protected statics (4, nominal statics in assign.zig);
    TS2507 non-constructor extends (3, stmts.zig); TS2430 (3); TS2433
    class/namespace merge across files (4, link).
11. TS2683 this-container rule (9 under-report cases): rule is oracled
    (object-literal methods and contextual-this callbacks DON'T report;
    script top-level arrow is TS7041) but ztsc's this_type is 0 in all of
    them — needs an enclosing-container walk first or the FP blast radius
    is large.
12. Nested `module "a" {}` inside `declare module "D"`: ztsc treats it as a
    satisfying ambient module where tsc does not (moduleAugmentationsImports3,
    importInsideModule) — but mergeAmbientBlocks DEPENDS on that nesting for
    moduleAugmentationInAmbientModule1-4. Needs care.
13. generatorTypeCheck26 last key: contextualArrayElemType must read a
    contextual iterable's yield type before resolveStructural expands the ref.
14. nestedExcessPropertyChecking: fresh-literal weak_rule_off disables the
    weak check for the whole SUBTREE; tsc per-frame (risky — conformance
    flow/062 is the tripwire).
15. resolution-mode import attributes (2 cases; needs (specifier, mode)-keyed
    module graph — deep, low priority).
16. Determinism defect with a concrete witness: social-app `--checkers=1` and
    `--file-order=reverse` diverge; `Navigation.tsx:778:29` prints
    `NativeStackNavigationProp<{…}>` in one partition and the expanded shape
    in the other. Pattern-matches the open instantiation-budget partition bug.
17. Regex BODY validator (dedicated-wave-sized).

## Superseded queue (wave 15, kept for context)

1. One-code-away clusters scanned by B: TS2403 (14 files, stmts.zig),
   TS2449 (9), TS2440 (8), TS2488 leftovers (iteratorSpreadInArray8/10,
   iterableArrayPattern23/24, for-of58 intersection).
2. Generator yield contexts — mechanism now fully understood (wave-14 C):
   needs a NEW fn_ctx field (contextual yield type that is NOT a check
   target — reusing yield_type caused generatorTypeCheck63's false TS2322),
   set in stmts.zig, read in expr.zig's .yield_expr arm; checkFunctionBody
   re-checks yield operands after inference with yield_type=0 and
   checkExprCached is (node, ctx)-keyed, so the inference-time thread alone
   fixes nothing. generatorTypeCheck27-30 additionally need tsc's
   getImmediatelyInvokedFunctionExpression contextual-return rule.
3. UMD residue: TS2686 at the value-position identifier site (expr.zig);
   umdNamespaceMergedWithGlobalAugmentationIsNotCircular's excess TS2448
   (use-before-declaration position compared across files);
   exportAsNamespace_augment (UMD namespace must MERGE with declare-global
   namespace, member tables included); exportAsNamespaceConflict TS2303
   (alias_cycle graph node for the UMD alias).
4. binder.instantiated answers a different question than tsc's
   getModuleInstanceState (const-enum-only and exported-import bodies).
   modvalue.nonInstantiatedBlock now carries the exact rule;
   typespace.memberNamesAValue and expr.zig's TS2631 arm still read the raw
   flag. Unify.
5. TS2694 residue: five remaining one-key cases, all in typespace.zig.
6. unionTypeCallSignatures4: TS2555 vs tsc's TS2554 — combinedUnionSignature
   lacks tsc getUnionSignatures' findMatchingSignatures bounded-arity pick.
7. Enum constant folding: classifyEnumInit needs tsc's `evaluate` (folds
   `1 << 1`) before TS1061/TS1066 can land without FPs.
8. TS2536/TS2542 residue: needs a readonly bit on object index signatures in
   types.zig (readonlyIndexWriteAt models only tuples/arrays); the ~21
   mappedTypeRelationships unders are mostly type-node positions.
9. Sibling `namespace X.A.B.C {}` blocks share one members scope where tsc
   keeps locals apart (declFileWithInternalModuleNameConflictsInExtends2).
10. tsxGenericAttributesType9: `declare module "react" { export = __React }`
    does not link — pre-existing link gap, now FP-visible on class exprs.
11. TS2564 bracketed-literal names (parser bit + initCandidate consumption,
    ~3 keys — every candidate case also diverges elsewhere; only worth it
    bundled with fixes for those cases' TS2454/TS2411/TS2300).
12. isPastLastAssignment for the PLAIN auto type (6 keys / 2 cases;
    redesign-sized — marker treatment + tsc's branch-label join shortcut).
13. Determinism defect with a concrete witness: social-app `--checkers=1` and
    `--file-order=reverse` diverge; `Navigation.tsx:778:29` prints
    `NativeStackNavigationProp<{…}>` in one partition and the expanded shape
    in the other. Pattern-matches the open instantiation-budget partition bug.
14. Regex BODY validator (dedicated-wave-sized; wrong error is syntactic =
    program-wide suppression).

## Superseded queue (wave 14, kept for context)

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
