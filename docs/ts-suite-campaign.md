# TS test-suite compat campaign — state and continuation guide

Goal: **diagnostic compat with tsc (tsgo 7.0.2) on the full TypeScript test
suite**, excluding unsupported configurations (strict:false, JS cases,
unsupported compiler options). Campaign runs in waves of 4 parallel opus
worktree subagents, one per area, merged sequentially with gates.

## Standings (2026-08-24, post wave 31)

| metric | start (wave 3 kickoff) | now |
|---|---:|---:|
| exact-match cases | 4902 / 7815 (62.7%) | **7433 / 8631 (86.1%)** |
| excess keys (false positives) | 3541 | 1526 |
| missing keys (under-reports) | 8617 | 2907 |
| bucketed (ztsc parse error, incomparable) | 825 | 9 |
| crashes / hard timeouts | 0 / 1 | 0 / 0 |

Thirty-one waves landed (3–31), every one with ZERO match→non-match regressions in
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

Wave 17 (+69 cases; conformance 1317→1319): A landed readonly index
signatures end-to-end (types.zig obj_flag_readonly_{string,number}_index;
TS2542 does NOT suppress assignability), TS2683/TS7041/TS2331/TS2332 (zero app
fallout — measured), and interface-extends-typeof-class. B relocated TS2440 to
checkAliasSymbol semantics (new alias_conflict.zig; AliasExcludes=Alias), both
TS2649 mechanisms, use-site TS2307 for dead require aliases. C landed TS2417
static origins (class_static_owner reverse index; poisoned on hash-cons
ambiguity), the distributive-conditional constraint with its every-instantiation
restriction, non-array instantiable rests (one-sided rule — the two-sided form
produced 5 excalidraw FPs, caught by the app gate), abstract-ctor
assignability. D landed the regex body+flags validator (new regexp.zig,
oracle-probed Annex-B rules; the wave-12 blocker was that tsc's regex
diagnostics are SEMANTIC-class, not the shebang), TS1155, TS2480.
IMPORTANT clarification from D: the recurring "social-app loads 4778 files /
0 link errors" symptom is the WRONG CONFIG — agents must use tsconfig.json,
not tsconfig.check.json; the checkout was fine.

Wave 18 (+105 cases, the largest wave; 80% crossed; social-app baseline
refreshed for a tsgo-proven namespace-print change in bskyogcard, keys
unchanged): A removed untrustworthyOverride outright, split
private/protected Prop bits (prop_flag_protected refines non_public),
tightened TS2320 identity. B landed the three alias-order sites (shared
modvalue.aliasValueVerdict), root-caused TS2454 twice (for-of var head typed
any — a real typing bug; has_init vs tsc's flow rule), TS2394, importType
TS2741. C landed tsc's effective-argument-list spread expansion (the whole
iteratorSpreadInCall family) + TS2556 + union-callee raw min arity; closed
the TS2769-anchor target (tsgo uses the LAST candidate's anchor — ztsc
already matches). D fixed cross-file TS2403 (firstValueDeclOf trimming),
the phantom-modifier parse of type members (+30 alone), TS6053/TS2308/TS2309,
TS1212 positions.

Wave 19 (+41 cases; both app baselines refreshed for the +27-line lib stats
footer, diagnostics unchanged): A rerouted tagged templates through
resolveSignatureCall (IncompatibleTypedTags exact), leading-variadic tuple
context, TS 5.1 undefined-return rule, RegExp typing (byte-empty app diffs,
as predicted), radix literals. B landed the distributive-constraint
substituted reading (type-returning distributiveConstraint), one-way nested
comparability, indexed-access-pair inference; keyof-of-array implemented,
measured, REVERTED — forcing resolveStructural(Array) inside keyofType
poisons the expansions memo (39 excalidraw files); prerequisite recorded.
C fixed the overload-probe memo poisoning (withdraw node_types entries
covering withdrawn diagnostics; deterministic counters show +16/+3 re-checks
per whole app) and TS2744 both halves. D landed the Map/WeakMap/WeakSet
iterable-overload lib reorder (SetConstructor deliberately excluded — infer
widens through Iterable<T>), var-undefined reads, singleton-exhaustive
switch, TS1268, TS18014, reserved-word message interpolation.

Wave 20 (+45 cases; both app baselines refreshed for a −206-byte lib-comment
stats change, diagnostics unchanged; two merge conflicts resolved — a
container-list union and C/D's duplicate TS2465, one implementation kept):
A landed construct-signature reorderCandidates (lib hack removed;
SetConstructor still held back pending inference), TS2394/TS2377/TS2337,
type-arg arity anchors, arg_err TS7006 withdrawal. B landed keyof-of-array
(Array tables materialized at checker init), the Iterable contextual fix
(REAL cause was iteration's union arm, not covariant inference), and VERIFIED
the SetConstructor reorder safe end-to-end (witness matrix + neutral sweep) —
next wave can land it and delete the NOTE block at lib.esnext.1.d.ts:2656.
C landed the later-spread excess-property rule (tsc shouldCheckAsExcessProperty;
O(N²)→O(N) follow-up), TS2437, TS2465, prefix-unary literal folding (also
fixed -0 interning). D landed template-literal expando keys, TS7006
whole-declaration spans, the TS1089/TS1244/TS1253 modifier-walk rewrite,
TS2875 (ambientIndex-gated), TS2377-super, TS2604. This wave rode through
repeated transient API stalls + one machine sleep; all four agents resumed
cleanly from their worktrees each time.

Wave 21 (+24 cases, perfectly additive; both app baselines refreshed again for
the lib-footer after the SetConstructor NOTE deletion): A landed the
SetConstructor reorder, object-literal accessor pairing + TS7032, optional
parameter properties, Function-in-union callability. B landed the
keyof-inference intersection arm and template `infer N extends number`
conversion — and REFUTED two wave-20 diagnoses by oracle (discriminated-union
inference is property-subset-driven, not discriminant-driven — 5-row matrix
committed in infer.zig; templateLiteralTypes4 was the infer-binder conversion,
not constraint instantiation). C landed the no-reduction contextual union
(element + property sides), the tuple-like-length disjunct, TS2438, late-bound
excess names, negative bigints. D landed per-file @jsxImportSource pragma
(new link/jsx_pragma.zig), ambient `declare var` as `any`
(SymbolFlags.ambient_var — last spare u32 bit), TS2875 deferred-body anchor.
OPERATIONAL WARNINGS for future waves: (1) agent D accidentally worked in the
MAIN checkout, not its worktree — briefs must have agents verify
`git rev-parse --show-toplevel` matches their worktree before editing;
(2) the shared session scratchpad got cross-contaminated again (one agent's
debug output appended to another's app capture) — use uniquely-named private
capture dirs; (3) repeated machine sleeps / API stalls this wave — agents
resume cleanly if they commit early and often.

Wave 22 (+41 cases): A landed the full late-bound expando seam (four
coordinated defects incl. tsc's declare-on-the-function-expression model),
the TS2403 escape narrowing, a message-safe #private relation retry, and
declared-`never` callees. B solved discriminated-union inference — the THIRD
diagnosis correction (it's tsc's typesDefinitelyUnrelated gate on
inferFromObjectTypes; ~60-probe oracle) — and landed symbol-named members for
unique-symbol consts. C landed yield-in-non-generator, logical-assignment
result types (tsc's read-type rule + RHS contextual typing), super.x receiver
typing. D landed for-of head narrowing (silent iterationElementType),
`this is` receiver predicates, the moduleAugmentation merge family, and JSX
intrinsic-miss fixes.
PERF LESSON (from B's self-caught +10% incident): `atomText`/`Interner.lookup`
takes a shard mutex — NEVER put a name-text test in a per-property path; memo
per atom and scope the question. Also: ad-hoc `--strict` triage against tsgo
is invalid (it bails on lib.dom errors and manufactures phantom excess).

Wave 23 (+36 cases): A landed readonly-field widening, `??` narrowing (the
crossing correctly relocated from conditions.zig to flow.zig's edge site),
#private non_public flags + static non-inheritance, TS2721/2722/2723; the
optional-methods fix was measured-and-reverted pending a super flow root
(unlock recorded beside optional_member). B landed the weak-type array arm and
the strict-subtype narrowing pick, and killed the queue's table-flag
prescription with measurement (+11% drizzle, zero cases — recorded in
keyof.zig); the contra-split's one remaining bug is isolated for attempt six.
C landed the mergedOf normalization at source, numeric-literal computed keys,
ThisType<T>, and saved a working self-`this` patch blocked ONLY on
generic-call argument contexts (oracle repro committed). D built
tsconfig-anchored diagnostics end-to-end (keyed jsonc offsets → ConfigDiag →
Emitter; tsc's two suppression gates mirrored) landing TS5102 (+7), plus
duplicate-identifier naming, [Symbol.iterator] rendering, and a 14-key
parser/link sweep.

Wave 24 (+12 cases; conformance DEFERRED divergences 36→35): A landed
optional methods + the super flow root together, parameter-property ctor
scope, chain-root optionality narrowing, TS7023's frame-local fix, TS1155 for
using, TS2389 name args. B fixed the REAL cause behind the "generic-call
context" theory (context-free Phase-1 walks publishing member bodies into the
memo), the ThisType outward walk, and finished the #private relation; a latent
keyof↔mapped SIGSEGV died on the way. C landed `this` flow narrowing (with the
one-line binder gap documented), assignment-pattern TS2353, spread index
signatures (retiring a DEFERRED divergence), array-rest source types. D landed
esModuleInterop end-to-end (canHaveSyntheticDefault guard caught by the app
gate) and the first JSX family. KEY DIAGNOSIS BANKED: after reporting TS2454
tsc returns the DECLARED type — that one divergence is most of the typeGuards
under-pool, but the verdict currently lives under owned_mask and must move out
without breaking N-checker determinism (recipe beside flow.unassignedVarType).

Wave 25 (+56, perfectly additive; bucketed 13→9; conformance 1319→1320):
A landed TS2454 declared-type (verdict out of owned_mask, determinism-gated;
its +4% RSS risk caught and fixed by narrowed!=declared gating), general
`this` narrowing, non-union directlyRelated. B opened the concrete-source→
generic-target relation direction (36 keys; 12 residual excess confined to
the two already-diverging higher-order-inference cases) and ANSWERED the
contra-split mystery from tsc's source: anyFunctionType has ZERO call
signatures so len=0 — no descent ever; the phantom enters elsewhere
(reverse-mapped or union naked-variable arm). C landed array-pattern tuple
contexts, TS18046/TS2571 recoding at four verdict sites, pattern-default
contexts, and the classInstanceGeneric inference-window TS2339 hole. D landed
the TS1434 seam PROPERLY (fixed the divergent recoveries first — the naive
flip measured −2), the malformed-import family, TS1042, and neutralized a
pre-existing `import a = a.b` parse-path SIGSEGV (the typespace recursion
itself still needs fixing). DETERMINISM DEFECT NOW SCOPED: exactly 3
pre-existing social-app lines differ between --checkers=1 and 4
(Navigation.tsx:778 TS2322 text, StarterPackDialog.tsx:245 TS2769,
FeedSourceCard.tsx:197 TS2353) — proven pre-existing by binary bisection.

Wave 26 (+17; conformance 1320→1322; social-app baseline refreshed 94→92
check errors — two tsgo-proven Navigation.tsx FPs removed — plus
message-text-only intersection-parens rendering): A landed the mapped-family
RELATION half (root: unconstrained-param base-constraint collapse making
T[keyof T] = never) + the generic-source/generic-target gate. B landed THE
CONTRA-SPLIT ON ATTEMPT EIGHT (three simultaneous rules: probe answers
preferContravariant over its own pair; aft infers nothing on EVERY unify arm;
markFixedByParams fixes only written parameter positions) and root-fixed the
`import a = a.b` SIGSEGV with TS2303 cycle edges. C landed the TS18046
general arm (zero spurious this time — the prior 20/14 trade was a column
artifact), pattern-default elaboration, and fixed gen_expected.js silently
retiring snapshots on oracle failure. D REFUTED the instantiation-budget
determinism hypothesis with measurement and found the TWO real root causes:
(1) checkers axis — aliasInstance's alias_recursive is marked only for the
cycle member each checker ENTERED at, so mutually-recursive aliases print
different identities per partition (Navigation.tsx:778; no partition-
independent rule reproduces the old baseline — fixing it MOVES the app
baseline, cheapest correct move is always-materialize once FeedPage.tsx:101's
relation gap closes); (2) file-order axis — interfaceGeneric folds merged
bases in linker file-id order (ProcessEnv: Dict<string> vs ExpoProcessEnv
any-index; needs canonical constituent order in link/modules.zig).
StarterPackDialog.tsx:245 + FeedSourceCard.tsx:197 need their own hunt.
⚠ PERF NOTE: D's JSX construct-signature checking (real checks tsc performs,
previously skipped; removed the 2 Navigation FPs) costs social-app ~+2% wall
(measurements 1.9%-2.4% across runs; RSS flat; all other targets flat).
social-app has been outside the headline wall bar since staging (~70% of
tsgo vs the ≤50% bar). Optimization queued.

Wave 27 (+34; social-app baseline 92→90 — two more tsgo-proven FPs;
DEFERRED accepted divergences 35→33; drizzle package FPs 8→1): A landed
deferred `T[K]` element accesses (conservatively scoped; each exclusion
documents the exact relation gap) + the authorized narrow.zig typeof
generalization. B landed the EXCLUSIVE callback rule via tsc's real #51620
mechanism (param_flag_inst_generic — the alias-variance premise was wrong),
literal generalization in TS2322/TS2345 text, union-source excess; FeedPage
:101 re-diagnosed as an INFERENCE gap that reproduces on main (15-line repro
committed; two non-fixes recorded). C landed generator returns,
binding-default contexts, case-clause excess, import() promises, TS2673/74;
higher-order inference re-filed at infer.zig with TWO named mechanisms.
D closed most of the file-order determinism axis by matching tsc's
DISCOVERY-WAVE structure (the canonical path-sort prescription measurably
wrong; tsc itself is root-order-dependent — proof committed), plus the for-of
parser sub-cluster; order-dependent social-app keys 3→1.
PROTOCOL ADDITION: bench/parity_sweep.sh is now a standing combined gate — it
had been silently failing (2 single-key package FPs at head, see wave-28 #1).

Wave 28 (+52; PACKAGE PARITY TABLE FULLY 0/0 for the first time): A killed
both package FPs — @types/node TS2430 via tsc's getTypeWithThisArgument as a
free retry (eager binding measured zod +14% wall — rejected), drizzle TS2416
via three HKT-encoding fixes — plus boolean-domain intersection reduction and
same-value enum mapped keys. B CLOSED FeedPage.tsx:101 (the degenerate Omit
self-pair spinning to depth limit; the two recorded non-fixes could never
work — the outer-vs-inner aliasInstance origin tag is a separate latent bug,
still open) and landed higher-order mechanism (a)
(instantiateTypeWithSingleGenericCallSignature; genericContextualTypes1
10→2 keys); StarterPackDialog.tsx:245 characterized as CHECKER-PARTITION
dependent with a deterministic --checkers=1 repro. C landed the yield/for-of/
destructuring cluster (+35 — including discovering destructuring assignments
were never TS2322-checked), in-on-primitives, TS2673/74 verdict withdrawal.
D landed TS2786 with the JSX.ElementType gate (both apps on it — no perf
hit), the placeholder bug, and both halves of for(var of X) composed.

Wave 29 (+31; parity stays 0/0; this wave rode through a weekly-usage-limit
cutoff and multiple machine sleeps — all four agents resumed from worktree
commits each time): B landed four one-FP relation fixes (comparable retry at
EVERY relation level, boolean-discriminant cross product, tuple comparable
via element union, comma/=-unwrapping elaboration). C landed the corrected
destructuring pattern-context model (binding vs assignment patterns imply
DIFFERENT tuples), yield* delegation, TS1187 from scratch — and re-diagnosed
"this typed any" as a class-member MATERIALIZATION cycle (this_type unwraps
to error mid-probe; lazyRefProp is the precedent). D found target 1 was
misdiagnosed: no merge-fold gap — buildAmbient resolved `export = X` with a
BLOCK-scope-only lookup, so every UMD typing (react!) made React.Component
resolve to nothing; fixed at the link (+13 jsx cases, guard deleted), plus
discriminant optional-undefined and TS2490. A did NOT close determinism but
converted it to measured engineering: both order-independent keyings ARE
deterministic; each is blocked by ONE localized gap (union-collapse under
Mutable<NonNullable<…>>; property lookup through intersection-with-ref);
fixTypeArgs' shallow_default must test the default's SYNTAX (scoped to
cyclic aliases — unconditional costs drizzle +12.8%); and the remaining
witnesses are an infer.zig bug — mapped-target-with-literal-key-set inference
takes candidates from only the FIRST matching property (9-line repro
committed; explains StarterPackDialog + AppLanguageDropdown). FeedPage
returns under deterministic keying (wave-28's fix was necessary not
sufficient).

Wave 30 (+37; social-app baseline 90→87 — three more tsgo-proven FPs;
DETERMINISM MILESTONE: social-app's diagnostic SETS are now identical at
--checkers=1 vs 4; the sole residual is Navigation.tsx:778's message-text
spelling, pending the alias keying): A found the mapped-key-set premise
WRONG — inference was already correct; the partition-dependence was the
excess-property reporter picking ONE union arm in interning order; fixed
per-arm à la typeRelatedToSomeType (all four witnesses dead at both checker
counts). B closed both keying blockers (computeIntersectionIsNever skipped
lazy-alias intersection constituents; materializeMapped's union arm sank
array constituents to {}), attempted the keying itself and reverted with a
12-line rebuild recipe (intersection-body gating leaves exactly ONE FP;
fixTypeArgs' substituting branch needs a DEPTH GUARD first — two scopings
segfault social-app; materialize-before-defaults reorder measured neutral),
and upgraded order_sweep.sh with a whole-grid text-included pass. C landed
TS2335/TS2537/TS2347/TS2348, verdict-ending on type-arg failure,
apparent-type suggestions (+26). D landed boolean/enum atomic-union
narrowing, TS2481 from scratch, defaultProps suppression (oracle-corrected),
TS1434 parseArguments (+11).
MEASUREMENT LESSON: never diff a --checkers=1 run against the default-
checkers baseline — compare same binary at same checker count.

Wave 31 (+81 exact → 7433/8631 86.1%; bucketed 9→8; conformance
1326/1326; DETERMINISM DEFECT CLOSED): A landed the alias keying —
materialize-before-defaults in aliasInstance, a depth guard
(max_tp_default_subst_depth=8) on fixTypeArgs' substituting branch (the
cyclic-defaults recursion mints fresh type args each step, so no stack
repeats — that's what overflowed wave 30's attempts), alias_stack+markCycle
marking the whole cycle suffix, with the one-spelling rule split into its
two real purposes (self-recursive originTaggable for variance; any cycle
member with an .intersection body for mixing), and shallow_default keyed on
the RESOLVED KIND (defkind=object fires; defkind=conditional is exactly the
deferred reduction the branch protects — the source of the rejected
+12.8%). Social-app AND excalidraw now 20/20 grid cells byte-identical
(checkers 1/2/4/8 × orders, message text included); the surviving 778
spelling is the alias-named one, which is what tsc prints. B landed 3 of
the pipe bugs (rest-tuple mint exclusion, generalizeCallResult identity
test, getTypeAtPosition semantics; 27→17 keys — the arrow-argument half
remains), the unconditional instantiateSignatureInContextOf fallback +
fixedInference, and C's const-context handoff (the any-placeholder at the
return-only block + contextAdmitsLiteral/isConstTypeVar descending
.index_access). C fixed the modvalue double-toGlobal (only site, audit of
all 18 resolveSpace consumers), bare `return;` infers void not never,
callback-elaboration dispatch, and the this-type instance half
(inProgressCallSigless). D landed the TS1134 abort-loop recipe, TS2481
blame-the-var (dedicated VarTransit struct), retired mask_let_const_class,
the jsx this-type half (TS2604 while the table is in flight), ten
TS1005/TS1109/TS1003 recovery rules (+26), and the evolving-array
multi-decl relaxation. e2e multi: wall 0.04s vs tsgo 0.09s; A/B flat.
WATCH ITEM RESOLVED BY BISECT: the social-app --checkers=1 +3.2% wall is
25d876f (the whole-cycle keying itself — cycle members with .intersection
bodies keep lazy refs and re-resolve on the single-checker path); the
depth guard and the aliasInstance reorder are neutral (52d40ba -0.1%).
Default config is FASTER (-1.3%), so not a blocker; optimization lead for
a future wave: memoize the kept-ref resolution per (sym,args).

## Ranked next queue (wave 32) — distilled from wave-31 agent reports

1. Pipe, the arrow half: contextual type for a context-sensitive arrow
   under a still-free rest tuple (`pipe(x => list(x), box)`), 17 keys in
   genericFunctionInference1.
2. The never[] trio (C31's measured recipe, net +3 expected): context-free
   `[]` is never[] (tsc implicitNeverType) in expr.zig's empty arm; the
   assign.zig comparability gap it exposes (`[] as HomomorphicMappedType<T>`
   must pass against a deferred mapped type, 4 FPs); flow multi-decl
   evolving-array half ALREADY LANDED (D31). Empirical widening rule
   pinned: only the evolving variable becomes any[].
3. Reverse-mapped composite key set (B31's near-miss, recipe recorded at
   infer.zig inferReverseMapped): inferToMappedType composite keys +
   substElemAccess .mapped arm + createReverseMappedType array/tuple
   rebuild is +3 corpus but breaks social-app THREE ways without tsc's
   isPartiallyInferableType guard — build the guard first; witness is
   social-app's useInfiniteQuery options object.
4. Mapped target with a MATERIALIZABLE key set → property inference
   (mapped.zig lower-bound key materialization; complicatedIndexes…).
5. [BISECTED — done by coordinator] The c1 +3.2% wall is 25d876f's
   whole-cycle keying (kept lazy refs re-resolve). Optimization lead:
   memoize the kept-ref resolution per (sym,args) or mark-once per cycle.
6. Constant-condition pruning: `if (true) { z = "a"; }` leaves the
   unreachable branch in the flow graph → TS2322 FP (no corpus witness;
   blocks nothing but wrong; flow.zig).
7. jsxComponentTypeErrors last key: TS2786 from checkJsxTagBound on
   `<this type="foo"/>` inside a function EXPRESSION assigned to an
   expando property.
8. TS2559 deferred-constraint suppression via drain-time rollback
   (typeparams.zig owns the verdict; 2 cases).
9. Identity relation: -TS2403 ×6 (identity.zig); -TS2339 ×7 (intersection
   never-reduction + narrowing).
10. social-app's own excess: 66 excess / 1 under vs tsgo remain, incl. the
    Navigation.tsx:778 TS2322 FP itself (now one deterministic spelling).
11. Census: 366 one-key cases (TS2322 62, TS1005 20, TS2345 16, TS2339 15);
    inference one-key FPs: contravariantOnlyInferenceFromAnnotatedFunction,
    deeplyNestedConstraints, subtypeReductionUnionConstraints,
    arrayLiterals3, nonInferrableTypePropagation2,
    contextualTypeBasedOnIntersectionWithAnyInTheMix1.
12. Substitution types (owner spanning generics+instantiate+subst+memo+
    print); resolution-mode attributes; per-frame weak rule.

## Superseded queue (wave 31, kept for context)

1. Alias keying, the finish (recipe committed in instantiate.zig): rebuild
   markCycle via the aliasGeneric stack; keep the ref ONLY for an
   .intersection body; add the DEPTH GUARD to fixTypeArgs' substituting
   branch (both prior scopings stack-overflowed social-app), reorder
   materialize-before-defaults (measured neutral), then the scoped
   shallow_default syntax test closes FeedPage.tsx:101. Expected result:
   Navigation.tsx:778's message converges → social-app fully byte-identical
   across checkers; excalidraw already is (12/12 grid cells).
2. infer.zig's .ref PARAMETER arm needs an INTERSECTION-argument identity
   pairing mirroring the union arm above it (AnimatedRef family: 3 FPs under
   the wider originTaggable keying; ExtractElementRef infer recovery).
3. Pipe / preserve-generic-signature — wave-sized, now fully spec'd (A30):
   single-call-signature detection, non-generic contextual signature,
   getUniqueTypeParameters + getSignatureInstantiationWithoutFillingIn
   TypeArguments, separate inference set merged via mergeInferences when
   non-overlapping, else instantiateSignatureInContextOf. 27 keys.
4. Mapped target with a MATERIALIZABLE key set must fall through to
   property-by-property inference (complicatedIndexesOfIntersections
   AreInferencable — Exclude-keyed Pick over a free param).
5. genericTypeArgumentInference1: instrument empty_seed/contra at
   infer.zig:1727-1772 for the two-argument case (T should be never; the
   Iterator<T,boolean> second argument displaces the empty-array seed).
6. TS1134 template-literal property names (D30's recipe: parseVarDecl
   force-advance with a startsArgument-style element check + re-check;
   6 keys; bucketed tripwire).
7. Small mapped items: const-context for bare literals at RETURN positions
   (const_ctx consults only array/object/template literals); the
   resolveSpace/toGlobal latent double-conversion at modvalue.zig:252;
   TS2559 deferred-constraint suppression (eager probe or drain-time
   rollback, 1 case); mask_let_const_class false positive; var-transit
   blame direction (needs a real struct instead of the reused Link).
8. this-type cycle, calls half (no corpus witness of its own; the two jsx
   witnesses need the same in-progress-window answer — classes.
   inProgressMemberNames is the started pattern).
9. Census: 84→? one-FP cases; TS2322 pools; parser families (TS1005 199/185,
   TS1109 83/72, TS1134 next).
10. Substitution types (owner spanning generics+instantiate+subst+memo+print);
    resolution-mode attributes; per-frame weak rule.

## Superseded queue (wave 30, kept for context)

1. infer.zig: mapped-target-with-literal-key-set inference must UNION
   candidates across ALL matching properties (inferMappedKeySet returns
   early unless the constraint is a type param). The 9-line repro is in
   wave-29 A's report; this is now THE determinism unlock for the remaining
   witnesses.
2. Deterministic alias keying, the two blocking gaps: (a) mutual-cluster
   union collapse — `Mutable<NonNullable<readonly A[] | readonly B[] | null>>`
   answering {} (restore.ts/newElement.ts shapes); (b) property lookup
   through an intersection containing a .ref that doesn't intersect the
   ref's members ({containerId} & ExcalidrawTextElement answering
   string|null). THEN land whole-cycle keying + the syntax-based
   shallow_default scoped to cyclic aliases (A's matrix tooling is in its
   scratchpad — promote matrix.sh/norm.py/cmp.py/perf.py into bench/).
3. this_type→error materialization cycle (C's repro: `m() { return this(); }`
   silent vs annotated reporting): fix at classInstanceGeneric's in-progress
   window (lazyRefProp precedent). Unlocks tsxDynamicTagName7 + the last
   jsxComponentTypeErrors key.
4. Higher-order preserve-generic-signature (pipe family, 27 excess keys in
   genericFunctionInference1): tsc's isGenericFunctionReturningFunction +
   instantiateSignatureInContextOf — infer.zig.
5. Literal/flow narrowing gap (B's find — BIG): a const/let reference NEVER
   narrows to its initializer's literal; `=== E.Member` doesn't narrow an
   enum param. Root cause behind numericEnumMappedType,
   contextuallyTypeLogicalAnd01 and likely much of the TS2322 pools.
6. C's queue: TS2335 (3 cases, expr); TS2537 computed destructuring keys (2);
   TS2347 gated on DECLARED any (2). D's: defaultProps missing-prop
   suppression (jsx, pure suppression, ~1-2 cases); TS1434 parseArguments
   force-advance (4 keys; bucketed at tripwire — careful); for-of53/54 TS2481
   (redeclare).
7. B's handoffs: isConstTypeVar needs indexed-access/intersection arms
   (names.zig:450); explicit type-arg failure must SUPPRESS argument checking
   (calls.zig chooseOverload); divergent accessors need real write_ty on
   types.Prop (cross-cutting — needs one owner spanning the member builders);
   array-literal context from a tuple-like INTERFACE (numeric-named members).
8. Census: 84 one-FP cases; 256 mixed-with-one-excess; TS2322 pools
   (44 under one-key / 317 excess total); parser families (TS1005 199/185,
   TS1109 83/72, TS1134 29/12, TS1434 22/7).
9. Substitution types (needs an owner spanning generics+instantiate+subst+
   memo+print); resolution-mode attributes; per-frame weak rule.

## Superseded queue (wave 29, kept for context)

1. DETERMINISM ENDGAME (unblocked by FeedPage): (a) replace alias_recursive's
   asymmetric marking with always-materialize (moves the social-app baseline —
   Navigation.tsx:778's message converges; tsgo-prove); (b) fix
   aliasInstance's outer-vs-inner origin tag (B's latent-bug find — ztsc tags
   the OUTER alias where tsc keeps the inner); (c) StarterPackDialog.tsx:245
   via the deterministic repro `--checkers=1 --workers=1` (partition-dependent
   TS2769 on platform({web,native}) mapped-type overloads);
   (d) FeedSourceCard.tsx:197 TS2353. GOAL: social-app byte-identical across
   --checkers=1/2/4/8 AND all file orders.
2. Relation one-FP pool: 96 cases exactly one false positive from exact, 49
   relation-shaped (contravariantOnlyInferenceFromAnnotatedFunction,
   divergentAccessors1, numericEnumMappedType, objectFromEntries,
   arrayLiterals3, castingTuple, subtypeReductionUnionConstraints,
   deeplyNestedConstraints, …).
3. Destructuring RHS pattern-context (C's single root cause):
   destructure.patternContextualType extended to .array_literal lets
   DestructSrc.exact drop — ~6 cases (ES5For-of30, restElementWith
   AssignmentPattern1, privateNameFieldDestructuredBinding,
   sourceMapValidationDestructuring*, unionsOfTupleTypes1).
4. Inference residue: genericContextualTypes1's last 2 keys; the pipe
   rest-tuple family (fnParam(i).ty raw vs rest element read);
   genericTypeArgumentInference1 (empty-array candidate demoted to
   empty_seed, invisible to later contextual instantiation).
5. yield* delegation inference (generatorTypeCheck20/21/25 —
   signatures.zig yields.delegated abandons inference).
6. `this` typed `any` in class methods/function expressions (the last
   jsxComponentTypeErrors key + tsxDynamicTagName7 — expr/flow).
7. Class+interface declaration-merge folding into DERIVED instances
   (@types/react Component is that merge; unblocks removing D's
   derivedClassInstance guard — 18-case FP risk documented in jsx.zig).
8. Substitution types (a conditional's true branch keeps `number & T`-style
   constraint info): the blocker C found for conditional callees
   (types/conditions.zig; net-zero measured without it).
9. narrowingIntersection (flow); complicatedIndexesOfIntersections
   AreInferencable (reverse-mapped through Pick); for-of53/54 + for-of15
   (binder/iteration); TS1434 residue (48 keys).
10. LibraryManagedAttributes (deferred WITH a detection guard in jsx.zig
    that silences the too-strict path — full modelling needs its own cycle).
11. Census pools; resolution-mode attributes; per-frame weak rule.

## Superseded queue (wave 28, kept for context)

1. PRIORITY package FPs (parity ratchet, both single-key): (a) @types/node
   stream.d.ts:1025 TS2430 DuplexOptions-extends-WritableOptions —
   pre-existing before wave 27; bisect the introducing wave, fix the relation
   shape; (b) drizzle insert.d.ts:102 TS2416 — `execute:
   ReturnType<this['prepare']>['execute']`, a deferred this-indexed
   conditional the relation does not reduce (B27's diagnosis).
2. FeedPage.tsx:101 inference gap (blocks the checkers-axis determinism fix):
   repro in instantiate.zig's commit 621ac96; T takes NO candidate under an
   Omit-materialized intersection pair; two tsc-faithful non-fixes recorded —
   instrument which property pair loses identity in unify.
3. assign.zig indexAccessTargetConstraint must constrain ONE side at a time
   (A27's last excess key, mappedTypeRelationships:109:9; unblocks widening
   the T[K] deferral toward tsc's rule).
4. calls.zig:488 apparent-type resolution for a `.conditional` callee
   (callOfConditionalTypeWithConcreteBranches TS7006).
5. TS2786 JSX cluster (20 keys / 6 cases, D27's scoped design): JsxProps
   carries the chosen signature's return/instance type + a ref-kind, then
   checkJsxReturnAssignableToAppropriateBound vs JSX.Element|null /
   JSX.ElementClass at the tag-name span. Fires on every React component —
   needs its own app+perf cycle.
6. Higher-order inference, re-filed at infer.zig with two mechanisms (C27):
   (a) per-argument INTERLEAVED instantiateTypeWithSingleGenericCallSignature
   (each firing mutates the shared context the next argument reads);
   (b) return-context inference binding the outer parameter to the contextual
   type's OWN free parameter (assign.zig:5452 anticipates it).
7. expr `.yield_expr` one-liners (~5 cases: bare `yield;` relates
   undefinedWideningType to the yield type; TS7057); modvalue entity-alias
   value-space `any` (classAbstractImportInstantiation, newAbstractInstance2).
8. for-of TS2322 sub-cluster (~9 cases): stmts.zig:697 needs checkAssignable
   on non-declaration lvalue heads + nested-destructuring TS2488;
   parserForInStatement5 one-line TS2322 early-out after TS2404;
   `for (var of X)` lookahead pair (parser+stmts halves together).
9. Determinism residue: StarterPackDialog.tsx:245 TS2769 (last
   order-dependent key, a false positive some orders avoid); the
   always-materialize alias decision (checkers axis) once #2 lands.
10. TS2673/74 arity suppression (rollbackDiags hook in checkCallExpr tail,
    2 keys); (number|boolean)&(string|boolean) not reduced to boolean;
    `Duplicate identifier '{0}'` placeholder printed UNSUBSTITUTED
    (recursiveComplicatedClasses — frontend message bug).
11. Census clusters: in-operator on primitives (10 keys, expr);
    tsxLibraryManagedAttributes (15, jsx); divergent accessors (5,
    classes/props); mappedTypeConstraints2 as-clause remapping (5);
    TS1434 residue (48→? keys); one-key pools.
12. resolution-mode attributes; per-frame weak rule (deep, deferred).

## Superseded queue (wave 27, kept for context)

1. expr.zig element access must produce DEFERRED T[K] (the mapped-family
   bulk, ~29 keys now unblocked — the relation side is ready): indexChainInner
   classifies by typeIsStringLike/NumberLike and falls to `any` for a generic
   receiver with keyof-typed index; no getIndexedAccessType deferral, no
   AccessFlags.Writing for TS2542. Four probes committed in wave-26 A's report.
2. Higher-order generic signature inference (12 keys):
   instantiateTypeWithSingleGenericCallSignature → getUniqueTypeParameters →
   attach inferred params to the RETURNED signature (calls.zig; the assign.zig
   comment names the cases).
3. Determinism fixes, now designed: (a) canonical merged-constituent order in
   link/modules.zig (file-order axis, ProcessEnv witness); (b) close
   FeedPage.tsx:101's relation gap (assign.zig) then flip aliasInstance to
   always-materialize (checkers axis; MOVES the social-app baseline — expect
   Navigation.tsx:778 to converge); (c) hunt StarterPackDialog.tsx:245
   (TS2769) and FeedSourceCard.tsx:197 (TS2353) separately.
4. covariantCallbacks unlock: extend variance.zig's measured variance to
   ALIAS origin refs (tsc probes object/conditional aliases), then the
   exclusive callback rule (SignatureCheckMode.Callback) is a clean +1;
   assign.zig:5475's warning stands until then.
5. TS2353 via a reporting comparable-relation entry (switch-case literals:
   tsc runs checkTypeComparableTo whose excess pass reports TS2353 instead of
   TS2678; union-source excess stops at the FIRST constituent — 3+ cases,
   assign.zig).
6. Message fidelity with conformance impact: literal widening in TS2322 text
   (assign_report.zig — tsc generalizes a literal source unless the target
   could have singletons); TS2694 qualified-name rendering (Namespace 'M.N').
7. contextualCallSig needs getIntersectedSignatures (expr.zig:6981 — an
   intersection contextual type combines arity-applicable sigs with
   intersected params); call signatures off a deferred conditional's
   constraint (callOfConditionalTypeWithConcreteBranches).
8. Clusters: for-of/ES5For-of ×9 (iteration.zig); generatorTypeCheck ×6
   (yield/stmts); jsx ×7; TS1434 residue (48 keys/19 cases).
9. social-app JSX-check cost recovery (~2%): cache the construct-signature
   props target per component symbol (the naive memo recovered nothing —
   the cost is the checking itself; consider narrowing which attributes
   re-check under identical instantiations).
10. One-key census pools; binding-pattern-default contextual typing
    (destructure.zig: objectBindingPatternContextuallyTypesArgument,
    intraBindingPatternReferences).
11. resolution-mode import attributes; per-frame weak rule (deep, deferred).

## Superseded queue (wave 26, kept for context)

1. The mapped/indexed relation family (~55 missing keys behind ONE rule):
   indexed access and mapped types over DISTINCT free type parameters are
   bidirectionally assignable in ztsc where tsc rejects (T[K] vs U[K] with
   U extends T; Partial<T>[K]; {[P in K]: T[P]} vs {[P in keyof T]: U[P]});
   plus TS2536 (keyof.zig:797 exists, doesn't fire) and TS2542 through
   Readonly<T> for free T. Cases: mappedTypeRelationships (20),
   keyofAndIndexedAccess2 (11), mappedTypes6, keyofAndIndexedAccessErrors,
   varianceAnnotations, covariantCallbacks.
2. Higher-order inference returns a GENERIC signature (tsc infers
   wrap(list): <A>(x:A)=>A[] and instantiates that): retires the 12 residual
   excess keys in genericFunctionInference1/genericContextualTypes1 and the
   assign.zig comment.
3. `import a = a.b` SIGSEGV root fix: resolveNsContainer recursion
   (typespace.zig); alias_cycle documents qualified entities as terminal so
   its TS2303 pass never sees them. The parser no longer reaches it, but the
   spelling is valid input.
4. TS18046 general arm, re-derived with the COLUMN fixed (tsgo anchors at the
   object expression's start, not the property): unknownType1 alone is 13
   keys across property/arith/compare/call/new; the prior attempt traded
   20/14 on wrong columns. Also the write-target arm (z.p = 1 → TS18046 at
   receiver, via checkAssignmentTarget).
5. Determinism defect — NOW TRACTABLE with 3 scoped witnesses; dedicated
   agent: instrument the three sites, confirm/refute the instantiation-budget
   partition hypothesis (budget charges misses not hits), fix, verify
   social-app byte-identical across --checkers=1/2/4/8 and --file-order.
6. JSX 2604/2607 with the CORRECT design (from D): construct-signature props
   come from getJsxPropsTypeFromClassType (the `props` member of the RETURN
   type), not the first parameter; TS2607 lives there too.
7. Param-pattern default elaboration (contextuallyTypedBindingInitializerNegative,
   7 TS2322 under): checkTypeAssignableToAndOptionallyElaborate on a pattern
   default vs its element type — parameter patterns don't go through
   materializePatternTypes; distinct plumbing.
8. Harness/test fixes: gen_expected.js deletes empty-dir snapshots
   (intersection_to_recursive_union_alias/expected churn); the conformance
   runner lacks the driver's whole-program parse-error gate.
9. Print fidelity: [number, (string | undefined)?] optional-tuple rendering
   (costs a TS2493 message); TS1434 residue (48 keys / 19 cases remain).
10. One-key census: UNDER TS2322 ×65, EXCESS TS2322 ×31, UNDER TS2339 ×13,
    UNDER TS2345 ×12, UNDER TS1005 ×11, EXCESS TS7006 ×10, TS2353/TS2741/
    TS2403/TS1134 ×6 each.
11. Resolution-mode import attributes; per-frame weak rule (both deep,
    repeatedly deferred).

## Superseded queue (wave 25, kept for context)

1. TS2454 declared-type-after-report (most of the typeGuards under-pool,
   ~10+ cases): move the definite-assignment VERDICT out of owned_mask (the
   report stays owned), then expr returns the declared type after reporting.
   Determinism tests are the tripwire; recipe beside flow.unassignedVarType.
2. TS1434 fallback — the largest parser seam: 75 excess keys / 38 cases.
   tsc's parseErrorForMissingSemicolonAfter answers TS1434 at the expression
   start with same-position dedup; ztsc's expectSemicolonAfterExpression
   deliberately answers ';' expected at the NEXT token (decision documented at
   parser.zig:2167-2180). Revisit that decision with the dedup.
3. Array pattern → tuple contextual type (~11 TS2493 cases + TS2322 gains):
   one line in signatures.zig:2235 (checkExprCached(d.rhs, patternCtx)) + a
   TS2493 arm in checkArrayPatternProps; destructure.zig:583's note names the
   day. Wave-24 C's report has the full plan.
4. Binder one-liner: `.this_expr => try b.attachFlow(node)` in bindExpr makes
   `this` narrowing general (C's workaround covers receivers only).
5. JSX seam: 26 single-key jsx cases; TS2604 type-param excusal (FIRST teach
   collectJsxCallSigs to collect CONSTRUCT signatures, else ComponentClass
   constraints go false-positive); TS2607 needs jsxClassComponentProps to
   distinguish "no props member" from its @types/react escape hatch.
6. `import * from X` recovery (3 cases): TS1005 "'as' expected" + parse the
   next token as the namespace name.
7. TS2698 spread-of-undefined (4 cases): an unassigned implicit-any `let x;`
   must read `undefined` at its reference (flow; the report site is jsx/expr).
8. Contra-split seventh attempt: B24 re-corrected the blocker — the phantom
   contravariant candidate comes from a structural descent into the AFT
   function's parameter positions (which tsc also performs, so the difference
   is subtler); all findings in infer.zig.
9. assignmentCompatWithCallSignatures3-6: the concrete-source/generic-target
   leniency (assign.zig:5307-5335, named blockers genericContextualTypes1 /
   genericFunctionInference1) — the real fix is instantiating generic target
   signatures in the relation.
10. TS18046 (`x()` on unknown is TS18046 in tsgo, not TS2349); esModuleInterop
    default-import consumers; TS2607/2607-family.
11. Census: TS2322 pools (~330 excess/~480 under), TS2339, TS7006; the
    26 single-key jsx cases are the cheapest seam.
12. Determinism defect (Navigation.tsx:778:29); resolution-mode attributes;
    per-frame weak rule.

## Superseded queue (wave 24, kept for context)

1. Generic-call argument contexts (THE unlock): an object-literal argument of
   a GENERIC call gets NO contextual type — `g<T>(o: T, x: {value?: unknown})`
   passes rctx=no_type to the literal where the non-generic spelling works
   (oracle repro in wave-23 C's report). Fix in calls.zig/infer.zig. Then
   re-land C's saved self-`this` patch
   (…scratchpad/agentC/selfthis.patch applies on 4a291b8; fixes
   looseThisTypeInFunctions + objectLiteralThisWidenedOnUse; was net −2 solely
   from this gap).
2. Contra-split, sixth attempt: the one remaining bug is isolated — a
   round-one-REFUSED callback still contributes a contravariant candidate
   which the split then prefers over the parameter default (ztsc records a
   candidate tsc does not; TData becomes undefined). infer.zig documents all
   four findings; fix the candidate recording, then the split + re-derivation
   land together.
3. #private relation finish (now unblocked by A's non_public bit): fifth
   Mismatch variant in nominal_members.zig + elaborate.zig rendering
   ("refers to a different member…") + the relation arm reading the bit.
4. Optional methods + super flow root (must land together): binder sets
   optional_member on .class_method/.method_signature; refkey.zig gains a
   super_flow_root sentinel; flow.zig's identIsSym/isPatternRoot read it
   (controlFlowSuperPropertyAccess is the tripwire; recipe recorded in
   bindClass).
5. Parameter-property initializer scope: 3 lines in signatures.memberTypeOf/
   paramInfo — the member symbol's scope is the class member scope, so an
   earlier parameter is invisible (parameterReferenceInInitializer1).
6. `this` flow narrowing: expr's .this_expr arm never queries flow; the
   `this is T` machinery already works for named receivers. Costs
   spreadObjectOrFalsy + unknown multi-key cases.
7. Optional-chain-root truthiness: `a?.b` still narrows its root by
   truthiness where tsc only narrows by optionality (the other half of
   tsc's narrowType head; wave-23 A documented it at the flow edge).
8. esModuleInterop end-to-end: thread the option tsconfig→driver→link, then
   C's oracle rule in resolveESModuleSymbol (spread with {default: type} for
   callable export=; measured shapes recorded).
9. JSX pool — the largest: 72 under-TS2322 keys in conformance/jsx, plus the
   TS2741 pair (value elements vs JSX.IntrinsicAttributes; no global-JSX
   fallback after TS2875). App-gated carefully (both apps are JSX).
10. Call-signature relation: assignmentCompatWithCall/ConstructSignatures3-6
    (43 under / 11 cases, generic signature relation); covariantCallbacks'
    exclusive callback rule re-measure (assign.zig:5444 documents the trade).
11. Grammar/messages: TS2389 needs the overload's name as an explicit arg
    from the binder emission site; TS7023 circularity FP on
    `private foo() { return this.foo }` (signatures ~2454); TS2349/2351
    second line (calls.zig); using/await-using TS1155 (stmts).
12. missingAndExcessProperties: TS2353 per member for an assignment-PATTERN
    contextual type (never the declaration form) — 4 keys.
13. materializePatternTypes contextual threading (~+2, 10 recursion sites).
14. typeGuards pool (34 under TS2322); objectSpreadIndexSignature (tsc drops
    index signatures in spreads — app-FP-shaped, gate hard);
    template-literal property names TS1134 (deep recovery, thrice deferred).
15. Determinism defect (Navigation.tsx:778:29); resolution-mode attributes.

## Superseded queue (wave 23, kept for context)

1. readonly class-field initializer widening: memberTypeOf's .class_field arm
   (signatures.zig:2416) calls widenLiteral unconditionally — `class A
   { readonly kind = "A" }` infers `string`. The variable half exists
   (widenInitializer's is_const). Fixes exhaustiveSwitchWithWideningLiteralTypes.
2. `??` right-operand narrowing: binder.zig:4538's .binary arm builds
   condition edges only for &&/|| — add .question_question, and the
   conditions.zig consumption (nullishCoalescingOperator11: `s ?? f(s)` sees
   s unnarrowed where tsc has `null | undefined`, then silent via never).
3. #private per-class encoding (the unlock B proved): binder sets
   prop_flag_non_public on #private members OR gives them per-class atoms —
   nominal_members.zig documents what the relation then needs, full oracle
   committed. Also: private STATICS are not inherited
   (privateNamesConstructorChain-1/-2, statics.zig).
4. Optional METHODS carry no `| undefined`: the binder only sets
   optional_member for .class_field/.property_signature, never
   .class_method/.method_signature (binder.zig:3209,3726) — a real type gap.
5. modvalue.targetValueType's .binding arm hands typeOfSymbol a raw
   (file, local) without prog.mergedOf — statics worked around it; other
   consumers have the same hole.
6. assignmentReduced needs tsc's weak-type refusal (maybeAssignable says
   `{x?:"ok"}[]` ~ `{x?:"ok"}` where tsc refuses — assignmentTypeNarrowing).
7. narrowByInstance's union arm needs tsc's directlyRelated (strict-subtype
   BOTH ways before plain subtyping) — partialTypeNarrowedToByTypeGuard;
   requires a strict-subtype relation ztsc lacks.
8. TS2722 is entirely missing (possibly-undefined callee → ztsc says TS2349);
   calls.zig; residual on logicalAssignment5/6/7.
9. tsconfig-anchored diagnostics infrastructure + TS5102 for the removed
   `baseUrl` (3 cases) and friends (tsconfig.zig/main.zig).
10. print/message fidelity: symbol members render as raw atoms
    (`__@u90369` vs tsgo's `[s]`); TS2300/TS2451 carry no identifier name;
    TS2349/TS2351 lack the second line. Diagnostic-arg machinery exists.
11. Extract<keyof number[], string> still keeps "__@iterator" — carry the
    symbol-name fact on the interned table (one types.zig flag set once,
    never re-derived per property).
12. objectLiteralEnumPropertyNames:46 — a numeric-const computed key becomes
    a NUMBER INDEX SIGNATURE instead of a late-bound property (expr/
    computed_key; the string-const sibling works).
13. Cluster of located one-keys: contextuallyTypedBindingInitializer:28
    (stmts.materializePatternTypes passes no_type for destructuring-default
    context); looseThisTypeInFunctions:29 (object-literal method `this` =
    the literal's own type); es6DeclOrdering/missingPropertiesOfClassExpression
    (this.x expando under-report); staticMismatchBecauseOfPrototype:11:5
    (baseClassRef from a var of construct-signature type — instantiate.zig);
    parameterReferenceInInitializer1 (false TS2304 in a later
    param-property initializer); esModuleInteropImportNamespace.
14. elaborate.zig needs a fifth Mismatch variant for tsc's private-name
    message ("refers to a different member").
15. Two-round inference re-derivation (fifth window; must land WITH the
    contra-slot split; witnesses social-app useInfiniteQuery + excalidraw
    bindingProperties).
16. Census pools: TS2322 337 excess/487 under, TS2339 153/150, TS7006 111/17,
    TS2345 102/72, TS7053 42/34, TS2349 37/10, TS2741 21/45, TS2344 1/47,
    TS2536 0/21.
17. Determinism defect (Navigation.tsx:778:29); resolution-mode attributes;
    per-frame weak rule.

## Superseded queue (wave 22, kept for context)

1. Late-bound expando, full seam (mapped by A+C): binder `expandoTargetName`
   needs an `.identifier` arm emitting computedSymPlaceholder (its doc comment
   already names the route); then signatures.withExpandoProps rekeys via
   atoms.nominalizeComputedKey extended from unique-symbol to const STRING
   values; expr owns the TS7053 at the index write. 3 cases / 6 keys
   (expandoFunctionExpressionsWithDynamicNames{,2}, expandoFunctionSymbolProperty).
   ONE agent should own binder+signatures+atoms for this.
2. Symbol-named-member representation (types.zig/names.zig/print.zig):
   `interface I { [s]: string }` models the member as the string literal
   "__@u…", so Extract<keyof T, string> keeps it — the sole blocker left on
   extractInferenceImprovement, and a correctness issue generally.
3. D's expr leads: yield-in-non-generator must return `any` WITHOUT checking
   the operand (expr.zig:552 — 5 YieldExpression*_es6 cases); `x ??= 1` types
   as `1` instead of tsc's getTypeFacts rule (expr.zig:5126);
   `<this />` blocked on a class-instance inference cycle returning error type
   when a method lacks a return annotation (expr/classes).
4. redeclare.zig's isEmptyObject escape hatch is why 7 TS2403 near-misses stay
   (unionTypeEquivalence: `C` vs `C | D` where `class C {}` really is empty) —
   narrow the heuristic, don't remove it.
5. Per-class #private member identity in the relation (assign.zig):
   privateNamesAndFields' TS2416 currently just converts to TS2415 because
   both classes' #foo key one atom.
6. discriminatedUnionInference REWRITTEN: pick the union constituent whose
   property set is a SUBSET of the argument's (B's committed 5-row matrix);
   leftmost otherwise.
7. Two-round inference re-derivation (untaken three waves running).
8. Census: one-key TS2339 excess pool (arrayEvery needs `every`'s `this is S[]`
   predicate; for-of head narrowing; the 3-case moduleAugmentation
   namespace-merged-into-value family); TS7006; TS2322/TS2345 pools.
9. exhaustiveSwitchWithWideningLiteralTypes (flow/narrow);
   superCallParameterContextualTyping3 (super.x member access).
10. Plain-array contextual noReductions (C's measured-safe deliberate gap).
11. TS5102 tsconfig-anchored diagnostics (infrastructure); per-frame weak rule;
    resolution-mode attributes; determinism defect (Navigation.tsx:778:29).

## Superseded queue (wave 21, kept for context)

1. SetConstructor lib reorder — VERIFIED SAFE by wave-20 B (witness matrix
   byte-identical to tsgo, apps byte-empty, sweep perfectly neutral). Land it
   and delete the NOTE block at src/lib/lib.esnext.1.d.ts:2656-2667.
2. B's precise handoffs: unionTypeWithIndexAndTuple (contextual union must
   use noReductions — makeUnion reduces `"a" | any` to `any`, tsc keeps it);
   contextualTypeWithTuple (isTupleLikeType third disjunct: array-like whose
   length is all number literals); assignmentCompatability10 (optional
   parameter property produces a REQUIRED member); keyofInferenceIntersectsResults
   (synthesize {key: any} from an Index target in unify, intersect candidates);
   extractInferenceImprovement (unique-symbol member names modelled as string
   literals; NakedTypeVariable pick); discriminatedUnionInference
   (discriminantConstituent wiring for the union-PARAM arm);
   templateLiteralTypes4 (method type-param constraint evaluated against the
   declaring constraint instead of the instantiated tuple).
3. Late-bound expando: `expr[s]`/`foo[symb]` assignments need a checker-side
   rekey (expr.zig/signatures.zig; 3 cases from wave-20 D's split).
4. Object-literal setter parameter from the paired getter:
   setterParamTypeFromGetter bails on non-.class_method and pairedGetter only
   walks class bodies — 4 one-key cases + the missing TS7032 (signatures.zig).
5. Two-round inference re-derivation (the real fix for the probe-publish
   coupling): pass two must RE-DERIVE instead of reading the probe's published
   answers, so a callback's return contributes after its parameter fixes.
   Measured wrong-way variants are documented in infer.zig; the faithful
   contra-slot split fixes coAndContraVariantInferences7 but breaks
   social-app's useInfiniteQuery until re-derivation exists.
6. C's small residue: TS2438 (shadowedInternalModule — needs the alias to
   carry a TYPE meaning); symbolProperty21 (well-known-symbol computed keys
   in the excess scan); negative bigint literal types (typenode resolves
   `-1n` to 0).
7. D's residue: `<this />` JSX tag path; TS2875's deferred-body anchor (2
   jsxNamespace cases); per-file @jsxImportSource pragma; `declare var Foo`
   with no annotation types as `undefined` not `any` (costs TS2604 excuses,
   7 FPs if reported naively); TS1134 (parseDelimitedList recovery); TS1024.
8. Census pools: TS2322 under ~480/excess ~370, TS2339, TS7006 one-key
   families. 552+ cases sit one key from exact.
9. nestedExcessPropertyChecking per-frame weak rule (untaken twice);
   resolution-mode import attributes; determinism defect (social-app
   --checkers=1 vs --file-order=reverse, instantiation-budget partition bug).

## Superseded queue (wave 20, kept for context)

1. Construct-signature reorderCandidates: tsc splices each merged interface's
   declaration group at the FRONT (last declaration resolves first); ztsc
   implements this for CALL signatures only (signatures.appendObjectCallCandidates
   + classes.recordCallSigGroups). Extending to construct signatures deletes
   the wave-19 lib hack and fixes every merged constructor at once (also the
   genericMethodOverspecialization getElementById shape).
2. Iterable<T> covariant inference: tsc's getCovariantInference does not
   widen an array literal's element when T is top-level in the return type;
   ztsc does — this is what blocks the SetConstructor reorder (excalidraw
   bindingProperties witness) and broke wave-12's inference attempt. infer.zig.
3. keyof-of-array prerequisite: materialize the Array interface's generic
   member table at checker init (nothing mid-expansion), THEN land B's
   reconstructible keyof arm ('length'/'slice' ∈ keyof T[]; fixed indices for
   tuples). 9+ keys.
4. Excess-property check ignores later-spread overrides (tsc's
   shouldCheckAsExcessProperty): live excalidraw FP repro —
   `make({x:1, type:"text", ...plain})` false TS2353 today. assign_report.zig.
5. for-of head destructuring pattern checked as an EXPRESSION
   (stmts.checkForInOf calls checkExprCached(e.left) instead of the
   destructuring path the `=` case uses) — phantom TS2698 on nestedObjectRest.
6. resolveSignatureCall's arg_err_count==1 path re-walks arguments with
   no_type and PUBLISHES implicit-any TS7006 tsc never emits
   (taggedTemplateContextualTyping2:18:14; same loop on the TS2769 and arity
   paths). calls.zig.
7. Rollback-vs-memo, the nested half: diagnostics inside re-walked argument
   subtrees are memo hits and lost permanently (4 keys
   taggedTemplateContextualTyping1; dottedSymbolResolution1's TS2454).
   End-state design is tsc's checkDeferredNodes (defer function-expression
   body checks) — mapped to expr.zig checkExprCached publish site +
   stmts.zig checkFunctionBody + signatures.zig; needs the expr/stmts owner.
8. Binder expando: only string-literal keys recognized —
   `Foo[`+"`b`"+`] = fn` template keys cost 4 cases.
9. Parser cluster: `function F(public A)` should name the parameter `public`
   (4 span-only cases); TS1089 on constructors (3, + 2 false TS1244/45 for
   `abstract constructor`); TS1134 (6, parseDelimitedList recovery); TS2875
   jsxImportSource (5, jsx+link, FP-risk); TS1024 (3).
10. TS2394 for constructors — exact site documented: stmts.zig checkClass's
    .class_method arm (line ~2186), sibling scan via isCtorMember, then the
    already-pub signatures.checkOverloadImplementation anchored on the
    constructor token.
11. inferTypeArgs two-round publish fragility (documented in calls.zig enum
    doc comment): widening the probe withdrawal to all arguments breaks
    social-app's useInfiniteQuery TPageParam — the rounds read each other's
    published answers. Robust fix belongs with inference.
12. One-key census: 552 cases sit one key from exact. B19's relation list:
    assignmentCompatability10, coAndContraVariantInferences7,
    contravariantOnlyInferenceFromAnnotatedFunction, extractInferenceImprovement,
    mappedTypeOverlappingStringEnumKeys, keyofInferenceIntersectsResults,
    discriminatedUnionInference, unionTypeWithIndexAndTuple,
    contextualTypeWithTuple, noInfer.ts:80. Plus
    prefixedNumberLiteralAssignToNumberLiteralType (`let x: 1 = +1`, expr).
13. TS2437 (typespace), TS2465 (expr), complexRecursiveCollections (needs its
    independent TS2344 under-key too).
14. nestedExcessPropertyChecking per-frame weak rule (risky; flow/062);
    resolution-mode import attributes (deep); determinism defect (social-app
    --checkers=1 vs --file-order=reverse, Navigation.tsx:778:29,
    instantiation-budget partition bug).

## Superseded queue (wave 19, kept for context)

1. Tagged templates never check substitution arguments (~21 keys):
   expr.zig:1237 checkTaggedTemplate already builds the argument list —
   checkCallArguments is one call away.
2. TS2744 type-parameter-default forward references (~20 keys in
   genericDefaults.ts: 11 missing TS2744 + 9 excess TS2345 because ztsc
   resolves the forward default instead of degrading to error). Declaration
   check + props.zig typeParamDefault.
3. Lib overload order: ztsc's src/lib has es2015.collection's MapConstructor
   BEFORE es2015.iterable's, so the last overload is the Iterable one; tsgo's
   merged order puts Iterable first / array last (proved via `new Map(42)`
   last-overload error text). Reorder iterable Map/Set/WeakMap/WeakSet
   overloads ahead of collection ones — fixes for-of39/iterableArrayPattern28;
   elaborateLiteralError needs no change.
4. Conditional-type substituted reading (A's oracle-corrected diagnosis):
   tsc erases to the branch union WITH definitely-false branches dropped
   under the check param's constraint. ztsc has the walk as
   assign.distributiveConstraintRelates/remainingBranchUnion but only as a
   bool — re-expose type-returning, consume from expr.deferredDefaultConstraint.
5. lenientOverlap's nested property comparability is symmetric; tsc relates
   one-way under comparable (objectTypesIdentityWithPrivates3). One line in
   assign.zig; the symmetry was deliberate — measure.
6. Overload-probe memo poisoning (root cause found): rollbackArgDiags
   withdraws diagnostics but probe-created node_types entries survive, so the
   winner cache-hits and never re-files (dottedSymbolResolution1,
   thisInFunctionCall). Fix = invalidate node_types over the argument range
   on rollback, or adopt tsc's checkDeferredNodes deferral for function-expr
   bodies. Needs a measured attempt — the winner re-walks every callback body.
7. complexRecursiveCollections: two concat<C> signatures whose distinct
   type-param symbols fail to unify (assign/signatures) — 4 excess TS2430
   elaborations of `C | T` vs `C | T`.
8. Array-literal element contextual typing against a LEADING-variadic tuple
   reads position-from-start (expr → tupleElemTypeAt); the call path already
   reads from the end (tuple_relate.contextualElemType) — 4 keys,
   contextualTypeTupleEnd.
9. keyof array/tuple approximated as `number` (keyof.zig:180) — 9 keys in
   variadicTuples1; big blast radius (mapped types over arrays), measure.
10. No-return function with contextual return type CONTAINING undefined
    infers `undefined`, not void (TS 5.1) — 5 keys.
11. `var a;` evolving-any should read `undefined` before any assignment —
    6 keys (flow.zig). switchIsExhaustive misses singleton discriminants
    (reachability.zig; false TS2454).
12. RegExp typing: expr.zig:274 types every regex literal `any`; hook up the
    lib RegExp interface (validate-and-justify cycle — changes both apps'
    types); then RegExp arithmetic TS2362/63 + RegExp.foo TS2339.
13. Grammar residue: TS2394 for constructor overloads; TS1024 readonly on
    type-member method (3 keys); TS1212-family word naming via Diagnostic.arg.
14. prim→prim under-report bucket (121 keys / 57 cases) — RE-CHECK after
    items 1-2 land; C's triage says it is mostly those structural gaps.
15. regexp.zig extensions (Unicode property tables, v-mode set operators,
    backrefs, octal) — low yield, well-mapped.
16. nestedExcessPropertyChecking per-frame weak rule (risky; flow/062);
    resolution-mode import attributes (deep); determinism defect
    (social-app --checkers=1 vs --file-order=reverse, Navigation.tsx:778:29,
    instantiation-budget partition bug).

## Superseded queue (wave 18, kept for context)

1. heritage.zig `untrustworthyOverride` — the single biggest mapped blocker:
   it declines EVERY TS2430 when the interface redeclares any base member with
   method syntax; its docstring scopes the real gap to optional-method
   bivariance + unrelated `this` params. Narrow it to that shape; ≥9 TS2430
   cases are behind it (the overload-replacement machinery is already right).
2. expr.zig alias-guard order (from B): `symbolMergeValueAndImportedType` —
   expr.zig ~715 tests `f.import_binding` BEFORE the symbol's own value
   meaning (tsc checks merged value first); `exportDefaultImportedType` —
   `export default <type-only import>` is legal (checkExportAssignment
   resolves all meanings; stmts.zig .export_default arm); signatures.zig:1262
   types a merged alias by the alias target (tsc checks Alias LAST) — type
   wrong, diagnostics right.
3. TS2403 cross-file (module_augmentExistingVariable ×2): two `var`s of one
   global in different files merge silently; needs
   redeclare.checkSubsequentVarDecl's cross-file twin.
4. private vs protected as distinct Prop bits in types.zig
   (derivedClassWithPrivateStaticShadowingProtectedStatic — today they
   hash-cons to the same type id and the static-extends check short-circuits).
5. narrowable.constraintOrSelf erases conditional parameter types to their
   branch union before the relation runs — every conditional-source relation
   rule is unreachable for parameters (last distributive key,
   conditionalTypesExcessProperties, etc.). Investigate keeping the
   conditional and printing the constraint.
6. TS2454 cluster (9 one-key cases): the funnel is expr.zig:1090.
7. Regex leftovers: RegExp arithmetic TS2362/2363 (`/a/ ** /b/` — expr.zig),
   RegExp.foo TS2339; unicode property names TS1523-29, v-mode set operators
   TS1518-22, backrefs TS1533/34, octal TS1487/1536 (all mapped as clean
   extensions of regexp.zig).
8. staticIndexSignature4/5: would flip if `static` on an INTERFACE index
   signature reported TS1071 alone instead of TS1071 + binder TS2300.
9. TS2769 anchor via candidate-diagnostic spans (calls.zig; strictBindCallApply1
   now anchors right, generalize).
10. objectTypesIdentityWithPrivates3 (TS2352 accepted where type argument
    should fail — nominal-heritage fast path ignoring variance?); importType*
    TS2741 cluster (3, link/modvalue).
11. The overload-probe suppression: a failing generic type-predicate candidate
    swallows every diagnostic inside a callback argument's body
    (thisInFunctionCall.ts, 2 keys — pre-existing, now documented).
12. The TS2322/TS2345 census pools (still the largest); TS2693 residue via
    names.zig/expr.zig.
13. nestedExcessPropertyChecking per-frame weak rule (risky; flow/062).
14. resolution-mode import attributes (deep, 2 cases).
15. Determinism defect with a concrete witness: social-app `--checkers=1` and
    `--file-order=reverse` diverge; `Navigation.tsx:778:29`. Pattern-matches
    the open instantiation-budget partition bug.

## Superseded queue (wave 17, kept for context)

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
