# TS test-suite compat campaign — state and continuation guide

Goal: **diagnostic compat with tsc (tsgo 7.0.2) on the full TypeScript test
suite**, excluding unsupported configurations (strict:false, JS cases,
unsupported compiler options). Campaign runs in waves of 4 parallel opus
worktree subagents, one per area, merged sequentially with gates.

## Standings (2026-08-30, post wave 49)

| metric | start (wave 3 kickoff) | now |
|---|---:|---:|
| exact-match cases | 4902 / 7815 (62.7%) | **7959 / 8641 (92.1%)** |
| excess keys (false positives) | 3541 | 836 |
| missing keys (under-reports) | 8617 | 1776 |
| bucketed (ztsc parse error, incomparable) | 825 | 9 |
| crashes / hard timeouts | 0 / 1 | 0 / 0 |

Forty-nine waves landed (3–49), every one with ZERO match→non-match regressions in
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

Wave 32 (+46 exact → 7479/8633 86.6%; social-app baseline 87→77 check —
ten more tsgo-proven FPs; conformance 1326/1326; all grids stay
byte-identical): A landed the pipe round-two ordering (17→10 keys), the
substituted-contextual second pairing pass, the reverse-mapped
isPartiallyInferableType guard + composite key set, index-over-intersection
distribution AS A QUERY (tsc never bakes it into the type), the
contra-wipe fix (an ANNOTATED param's contra evidence is not "our own
guess coming home"), and flipped C's never[] recipe (+3; excalidraw's
false TS7053s were an inference gap the any[] was masking). B landed
identity signature-bound fixes (incl. a latent borrowed-slice-while-
interning bug in sigIdenticalAt), TS2559 drain-time rollback, the
number-index optional-property rule, and object-literal methods as
elaboration elements; its mapped lower-bound attempt produced the
construction-vs-query lesson A then landed. C landed union-spread
primitives, function-type interface bases contributing call signatures
(social-app −10 excess: express ErrorRequestHandler), construct-signature
defaults for extends clauses, and the unknown-identity screen relaxation.
D landed TS1127 junk-token routing (one per token, saved with speculation
state), the isClassMemberStart gate, constant-condition pruning (with
tsc's unwritten paren/! exclusion via doWithConditionalBranches),
TS1359's two diagnostic classes (measured: one suppresses siblings, one
does not), the discriminant-gate veto fix (declared union keeps
preference, loses the veto), and TS1138/TS1014/TS1013/bare-catch grammar.
PERF LESSON (B): reading a fresh type param's bound forces the deferred
substitution mintFreshTpDeferred avoids — +4–6% on drizzle; keep
typeParamConstraint behind cheap checks. MEASUREMENT LESSON: perf runs
while other agents sweep read +8% noise — check `ps aux | grep ts_suite`.

Wave 33 (+30 exact → 7509/8633 87.0%; SOCIAL-APP 46 link + 77 check →
37 + 31 — 55 tsgo-proven FP removals in one wave; conformance 1326/1326,
accepted divergences 33→30): A closed f08's self-echo (ctx_echo-scoped:
drop an identity candidate, substitute one mentioning an earlier variable
— the scoping is load-bearing, unscoped cost 7 exact) and landed the
Pick-pattern named-key walk (+3 cases incl. two unexpected). B killed the
TS2353 ×34 family (epcReducedUnion: tsc keeps a constituent when SOME
member of the source tag reaches it), normalized `[...any, K]` to
`[...any[], K]`, landed the per-frame weak rule (weakTypeMismatch runs
ahead of the memo, so no hazard), TS2313 circular constraints (+2 pure
cases), and A's paramTypeAt handoff WITH correction: as given it adds a
false TS2345 (spread-call source contributes whole-union element at every
position) — landed contextual-only. C removed the ambient TDZ (NodeFlags.
Ambient first, as checkResolvedBlockScopedVariable), decided class_value
identity by id, gave assigned function expressions their receiver `this`,
and landed the accessor cluster (getter return from setter annotation,
+8 keys). D routed ambient-module `from`-re-exports through the star
fixed point (one root cause for TS2305 ×9 AND node:cluster TS2339 ×4),
landed narrow.reduceConstrainedTypeParams at flow joins (subtype-reduce a
bare param beside its constraint's members), generated Unicode
ID_Start/ID_Continue tables (+6), and three recovery rules
(numberLiteralsWithLeadingZeros 69→93/93 keys).

Wave 34 (+56 exact → 7565/8633 87.6%; DETERMINISM FULLY CLOSED — the
excalidraw checkers=8 shuffle defect is dead, both apps now byte-identical
across the entire checkers 1/2/4/8 × 5-orders grid): A root-caused the
grid failure to a `return []` never[] arm surviving un-reduced into a
return-type union whose MEMBER ORDER (TypeId-minted → materialization-
order-dependent) the union-callee resolution then read; fix is one line —
inferReturnType unions with SUBTYPE reduction, so the union never exists.
Durable lesson recorded: makeUnion's TypeId ordering is a latent hazard
for ANY consumer of union member order; the defence is not to manufacture
such unions. A also corrected the alias-variance analysis (tsgo fails
line 26 b=a via getAliasVariances; c=d passes structurally because the
aliasSymbols DIFFER) and warned the (sym,args) keying memo is unsound
(alias_state grows; fixTypeArgs emits diagnostics). B landed tuple
numeric properties (fixed prefix only), target-driven discriminants
(isDiscriminantProperty semantics + boolean→true|false expansion),
last-wins literal elaboration at every declaration node, and same-text
template pattern↔pattern relation. C rebuilt the spread-call path: the
packed relation now decides BOTH overload selection (argumentsMatch used
to return true on any spread — selecting overloads checkCallArguments
then rejected) and the check; array literals are tuples under {0:…}
contexts; never-rest accepted. D landed +47: dynamic import() TS2307
(bind records replayed — the specifiers were in the graph all along, the
TS2307 walk visited statements only; exposed and fixed an exports-folder
resolver gap), TS1361/1362 nearest-hop (first-writer-wins type_only
origin in modules.zig — C's oracle recipe), the accessor grammar family
(7 codes, new pure module accessor_grammar.zig), strict-reserved names,
TS2323/TS2664. relationComplexityError does NOT flap: stable ~8.5s at
85% of the 10s cutoff; real fix is tsc's relation step budget → TS2859.

Wave 35 (+29 exact → 7594/8633 87.9%; bucketed 8→5; ztsc timeouts now 0
— the complexity flake is dead; conformance 1326/1326): A ran the
alias-ref policy to a DEFINITIVE NO — oracle-exact on probes, but a kept
.ref reaching materialized-kind consumers blows up the apps (17→76,
68→319) and breaks grid message-text determinism; regressions live in
infer/mapped/indexed-access consumers, not the spelling. Landed
flags-off bisect legs + the finding that measuredVariances lacks tsc's
Unreliable/Unmeasurable (AllowsStructuralFallback) — the prerequisite
for ANY negative variance verdict. Also: the c1 keying cost is SEMANTIC
(more kept refs), not markCycle's inserts — item dropped. B killed
relationComplexityError: intersection-source identity hoisted above
target-union decomposition (33.6M steps/4.4s → 8.2k/0.06s) + tsc's
per-query 4M-step budget → TS2859 (never fires today; message must take
the declared type node, not ref spelling). Also <T extends T> has no
constraint (the in-progress mark answered YES → assignable to
everything), TS1268/TS1337 index keys. C corrected wave-34's framing —
members were left FRESH, not stored widened (checkExpressionForMutable
Location ends every branch with getRegularTypeOfLiteralType) — fixing
objectFreezeLiteralsDontWiden; destructured params take the PATTERN
type (+4); empty [] is never[] unconditionally; TS7051; and REFUTED
D's &&=-arm hypothesis by oracle probe. D landed the augmentation-only
fix (registry seeds from SCRIPT files only), TS1326 + import
statement-start spelling, TS1092/TS1176/TS1246/TS1247, type-member
separators (+15, bucketed→5). PERF METHODOLOGY (adopt): under load use
single-threaded user-CPU interleaved A/B; script at
scratchpad/capC35/perfcpu.sh.

Wave 36 (+36 exact → 7630/8633 88.4%): C landed the OBJECT-LITERAL BODY
DEFERRAL — the mechanism half-existed (DeferredBody for class fields;
checkFunctionBody already split at tsc's checkNodeDeferred boundary);
the real blocker was the return-type probe memoizing an `any` receiver
mid-literal, fixed by making the probe a side query. The expando arm
fell out of the same machinery — closed jsxComponentTypeErrors TS2786,
objectLiteralThisWidenedOnUse, looseThisTypeInFunctions with NO jsx
change, +9 with census finds. B landed tsc's Unmeasurable/Unreliable
variance marks (three sites, read from a real typescript.js bundle)
and FLIPPED measured_variance_decides to true (all four wave-31-era
regressions closed; --variance-decides legs now inert, plumbing kept);
mapped `as` targets; variadic rest slice. A landed types.Prop.write_ty
INTERNED for type literals (side tables are provably order-dependent),
gated to type literals by measurement (+3.3% RSS if stored on
interface tables — ~29 divergent DOM pairs); composite write types
combine like read types; abstract on the CONSTRUCT SIGNATURE. A+C
independently built the composite-write fix — merge kept A's lazy
two-pass (the single pass cost +2.4% drizzle). D landed the `with`
family (+14: body BOUND but never checked; strictModeBinder codes
survive inside, checker-pass grammar codes don't — oracle-measured),
import-attribute same-line rules, isTypeMemberStart ABORT semantics,
TS1317/TS1040. A's abstract commit measured +2.4% drizzle alone
(semantic: DrizzleEntityClass's union genuinely has two members) but
the COMBINED wave is −3.4% on drizzle — B's relation work offset it.
makeIntersection ORIGIN closed as redesign-sized. PERF BASELINE
WARNING (A): never use main's prebuilt zig-out binary as a baseline —
rebuild from the merge-base in the same worktree (~2.6% drift).

Wave 37 (+26 exact → 7656/8633 88.7%): A landed the getInferredType
constraint clamp — POSITION-DEPENDENT in a signature relation (parameter
candidates take the whole constraint, return candidates the satisfying
subset; oracle battery in clampSigInference's doc comment), restricted
to bare-type-param bounds because the general clamp cost +4% zod
(bisected: pairs stop falling to the cheap erase path); `new C()` on a
ctor-less class answers C<unknown>; a method's bare bound is enforced
once the receiver substitutes it (closed wrappedAndRecursiveConstraints4
as a free rider). At a CALL seam tsgo takes the FULL constraint —
built, swept, zero delta, reverted and recorded. B landed
AccessFlags.Writing for index-access targets (intersection over a union
key, per-constituent missing screen), the abstractCtorTail bit, and
TS2741 stand-in names via heritage.declaresHeritage (a base-less ref
can't be base-swapped). C landed the union-key write intersection,
objlit/spread write_ty (the flagged getRestType premise was INVERTED —
tsc keeps it there; addSpreadProp was the dropper), field-beats-method
ordering, setter-return exemption, class-value rest, prototype
not-readonly. D landed binding-pattern list recovery (the decisive
detail: tsc's inErrorRecovery refuses `;` as an empty statement INSIDE
a parameter list but lets it terminate a declarator list), the whole
import-defer family (one predicate: tsc reads at most ONE of
type/defer), and the three forwarded one-liners (TS1113 latch, TS2492
BlockScopedVariable — measured: class is silent too, print single
construct sig). 149 cases now diverge ONLY in TS1xxx codes.

Wave 38 (+32 exact → 7688/8641 89.0%): C landed computed-name INDEX
SIGNATURES on all sides (shared computed_key.splitDynamicMembers pass;
domain via an if/else chain over the key type, values union SIBLINGS
included; fixed a pre-existing bug where [k: symbol] answered string
keys) + TS1238 + TS2467 + numeric-key string-index fallback. D landed
unterminated-regex recovery (tsc stops at the first UNBALANCED
)/]/} — classes and groups nest, a {…} quantifier SUSPENDS the search;
30 probes), non-consuming junk tokens (createMissingNode consumes
NOTHING — removing the bump() was the whole fix), the import.defer
EXPRESSION family (collapses to bare .import_expr, so it types as
import() with no checker change), TS1477/TS1142×2/TS1196/TS1186.
B landed the Parameters/ReturnType constraint family
(decidableConstraintSet lacked callable kinds), TS2344 on type-param
DEFAULTS, TS2315 for params/enums, `this is T` predicate forcing,
constructor VISIBILITY compat, tsc's intersection property check
(narrowed to comparable after an app-gate-only FP — the corpus and
packages were clean; the app gate caught it), and the null-stripped
union headline (text-only). A closed the echo-wipe annotated-position
gap and REFUTED the queued reverse-mapped rule — the real axis is
ARITY (source strictly shorter than template, A at a still-declared
position; 30-row battery in inferOuterFromShortCallback's comment).
coAndContraVariantInferences5 is blocked on internal union-member
ORDERING (both compilers order-independent w.r.t. source; aligning
means matching tsc's type-id order in makeUnion — out of scope).
CALL-seam full-constraint reconfirmed zero-delta a second time.
PRACTICE ADOPTED: sweeps must run against a PINNED binary copy
(--ztsc <snapshot>) — a concurrent zig build bench invalidated a sweep.

Wave 39 (+39 exact → 7727/8641 89.5%): A landed TS2729 (~60 probes;
new init_order.zig unifying the two self-ref scans; the static-block
carve-out steps back to position-only) and TS2660 (superContainerIs
Member: a plain function owns `this` but is never a super container;
shorthand-vs-property function spelling decides), plus TS2754/TS2466/
TS2416-column. B killed the typebox canary find of the wave (+2660%
instructions from the general infer-binding rule — the corpus was
CLEAN, only the package benchmark caught it; shipped form constructs
nothing), landed T[keyof T] domains, asyncFunctionReturnType, deeply
NestedConstraints via condTrueUnderExtends ("branch IS the check type
→ check & extends"), Record-cast TS2352 (lenientOverlap now honours
index infos), and ROOT-CAUSED QueryPersister as inference (same-alias
pairing). C landed exactly that inference fix (alias-args pairing arm)
+ the FULL indexed-access error tail (TS2339/TS2493/TS2537/TS2538 on
resolved type nodes, +31 keys) — after the merge the coordinator
re-tightened intersectionOptionalsRelated to plain assignability and
re-verified social-app byte-identical. D landed binder computed-name
spans (dupDiagSpan: whole [..] with interpolated name), TS1211 via
declModifiersStart (reads the modifier run BACKWARD from the keyword),
TS1084 via new reference_pragma.zig, TS1114/TS1319/TS1156/TS1031.
ACCEPTED+FLAGGED: zod +1.6% CPU, bisected to C's merge — the error
tail is work tsc also does; all other benchmarks flat-to-better.
NOTE: D's branch claimed bucketed 0 but the combined sweep shows 5 —
reconcile. .gitignore now covers the tsgo node_modules SYMLINK (three
recurrences of committing it).

Wave 40 (+49 exact → 7776/8641 — 90.0% CROSSED; BUCKETED NOW 0 — every
corpus case scored): D landed the heritage-clause family — parse EVERY
extends/implements clause as a list, keep what tsc's checker keeps,
refuse duplicates by grammar (TS1172-75, TS1097; 12 of 24 TS1434 cases
died), plus export-type-star cancellation (type_only_from_star cleared
by a later plain star) and new.<name>/clause-less-import parses; the 5
bucketed cases resolved (4 exact). A measured the late-binding pass at
~2 cases and DESCOPED it (mechanism recorded: hasNonBindableDynamicName
skips declareSymbol entirely — needs binder diagnostic deferral;
overloadSiblingDiag needs key-TYPE identity and can only land with the
deferral), then took census wins instead: "did you mean" trio (+9),
TS7009 (+4), element-access tuple-index forms shared with keyof (+3),
TS2662/2663/2576/TS2564 halves; landed D's implements-after-failed-
extends handoff. B fixed merged-interface type-param constraints (tsc
binds ONE symbol across blocks; first extends clause wins), admitted
bare free type args behind the cond_true screen (79 FPs without it, 0
with), .array/.tuple constraint sets, null/undefined overlap, and the
FPs the gate exposed (mapped numeric keys re-minted as string literals;
void-target arm ahead of the type-variable arm); found and fixed its
own +3.6% drizzle blocker with a tp_list_cache memo (byte-identical
sweep). C fixed generator contextual typing (widenToContext for Y,
inferredNextType for N), aligned the same-alias pairing to
unconditional with variance direction (the .object-arm version cost
5.3% drizzle — measuredVariances is a measurement, not a lookup),
iterator-arity protocol filter. MEASUREMENT: macOS /usr/bin/time
reports only the last reaped child — sum individually-timed runs.

Wave 41 (+35 exact → 7811/8641 90.4%): C REFUTED the prescribed
contravariant-slots design with a 40-witness battery — top-level
parameter positions fold COVARIANTLY (common supertype); only
callback-parameter nesting is contravariant; the actual bug was one
branch in combineCovariant (the bare-type-variable "weakest evidence"
union rule, correct at call sites, wrong in signature relations —
gated on sig_ctx). tsgo also orders type-reference-argument candidates
ahead of top-level ones (elaboration position only; recorded). D
landed 21: parameter/arrow recovery (modifier-spelled tokens skip as
missing names; `()` before `{`/`:` is Tristate.True arrow), syntactic
tuple-order codes TS1265/1266/1257 in the parser, non-literal module
specifiers stopping placement rules; the cascade shrank (TS1005
excess 113→76). B landed the erased-signature retry gate (it was
OVERTURNING genericSourceRelatesByInference's verdict) and template-
hole pairing in parameter positions (T0 := T2, not `${T2}`). A landed
11: async Promise-subclass returns, spread TS2488 with constraint
fallback (caught its own social-app regression mid-wave), TS2449/
TS2708/const-enum, plus four handoffs including B's tupleLikeByZeroProp
rest gap. A's TS2574 attempt REVERTED with recipe (isAssignable-based
isArrayLikeType cost +33 excess keys and a timeout; use kind tests +
base-constraint, treat variadic infer as unknown[]-constrained).

Wave 42 (+27 exact → 7838/8641 90.7%; accepted divergences 30→29): D
landed the jsx THREE-STAGE ordering (silent verdict → whole-object gate
→ elaboration; the gate SKIPS freshness verdicts — the memoized
relation can't see freshness), get/set across line breaks (their
modifier arm has no same-line test), unterminated-block-comment ASI,
and C's flow handoff (evolving vars start at `undefined`
unconditionally — the restriction to never-written vars was the bug).
A landed TS2574 with the polarity finding (ask "is this a FINISHED
non-array?" — deferred spread operands broke both positive predicates),
class-expression static-field ctx (checkExprCached keys on (node,ctx) —
the re-check was a second full read), for-of nullish TS18050,
errored-index-key applicability (errorType carries Any), defaulted-param
write targets, TS2491/TS2405/TS2463, and C's SkipGenericFunctions
fallback recipe. B landed mapped-over-`any` materializing index
signatures (with the declared-array-constraint carve-out for
Promise.all), intersection-source-vs-union-target via someTypeRelatedTo
(nullish carve-out — excalidraw's TS2345 is a TRUE positive),
generic-mapped-vs-index-signature by template, combined mapped
optionality. C landed whole-argument isContextSensitive and generalized
template-hole pairing into unify. mergedDeclarations7 RE-ROUTED a
FOURTH time with proof: tsgo prints import("passport").PassportStatic.
Passport and the relation is ASYMMETRIC — combineValueAndTypeSymbols
mints a fresh symbol with its own thisType; belongs in import/alias
resolution (names/typespace). PERF: combined wave +1.79% drizzle CPU
(bisect: mostly B's mapped work, semantic; the +4.3% wall reading was
4-checker noise) — accepted under the 2% bar; watch drizzle next wave.

Wave 43 (+20 exact → 7858/8641 90.9%; drizzle watch met at −0.44%):
D landed TS2595 (link parks an EqDefaultImport with the specifier span;
new export_equals_import.zig answers the type half; 15 probes incl. the
two property-exists escapes), BOTH TS2688 halves (correction: tsgo DOES
suppress the semantic pass for config-level 2688 — separate channel,
not config_diags; exports-map authority + the `"exports": null`
JS-truthiness bug), binding-element JOIN semantics (not a bare ordering
swap — 3 of 5 shapes wrong without the join), duplicate export
specifiers. A landed compound-LIKE assignment widening
(isCompoundLikeAssignment: shift precedence or higher), the mapped
contextual key domain (NARROWED — the global Index rule cost 2 FPs and
9 lost keys; it lives in ctxPropType's .mapped arm), TS2523/2675/2526-
constructor, and C's keyof-literal-context recipe (+2). C disproved the
const-clamp diagnosis (tsc DOES excess-check const-context literals) —
the real bug was isConstTypeVar lacking an INTERSECTION arm (one
token); de-duplicated the index simplifiers byte-neutrally. B landed
Partial<T>[K] read optionality in the RELATION (with normalization so
{} cancels the undefined) and constraint-step disjoint domains; its
8-key expr-defer patch is SAVED but blocked on a {}-absorption chain
(canBeNullish for deferred access + reduceSubtypes letting {} absorb).
TWO PRE-EXISTING DEFECTS CONFIRMED (both reproduce at merge-base):
excalidraw UserList.tsx:285:11 TS2345 is ORDER-DEPENDENT at checkers
2/4/8 (crept in during waves 41-42; the default-order app gate can't
see it); the DEBUG binary panics on excalidraw (constEnumOnly at
expr.zig:1333 reads a foreign-file decl node — masked by ReleaseFast).

Wave 44 (+9 exact → 7867/8641 91.0%; DETERMINISM RESTORED — grid
40/40 again; drizzle −3.4% CPU, repaying the wave-42 debt): D
root-caused UserList.tsx:285 with a new --dump-partition tool (the
read side --partition-file lacked): Phase 2's feed-forward read ONLY
covariant candidates, so an annotated callback (all-contravariant
evidence) left the next argument's contextual type at the `any`
placeholder — and a body memo minted while checking a FOREIGN file
publishes no diagnostic, making the FP surface only under partitions
splitting UserList from LayerUI. Fix: feed-forward falls back to
contra when covariant is empty; regression test guards both halves.
Also `this is T` parseable anywhere a type is; TS1228 reclassified to
grammar; the enums-leg framing DISPROVED (an empty const enum is NOT
never — the rule is disjoint-domain: empty/numeric→NumberLike,
all-string→StringLike, mixed declines). A fixed the debug-binary
cross-file panic (constEnumOnly resolves the SYMBOL's file tree; both
apps now run clean in Debug), TS2449 with the IIFE clause (new
decorator_owner + iife_fn plumbing; 22/22 keys), union-key write
intersection un-gated (it IS the write type), spread-readonly. B
landed the mapped-defer chain properly: the naive whole-homomorphic
deferral cost +22% drizzle CPU; screening on MODIFIER-CHANGING maps
keeps every key at noise cost; canBeNullish answers deferred accesses
via simplifyMappedIndexAccessRead; {} absorbs an `X & {}` sibling.
C landed keyof-of-renaming-maps (named the RENAME half positively —
substitution unbounds on self-recursive as-clauses where tsc's free P
stops) and the .class_value infer fix (generics.zig
inferFromExtendsInner bridged class values only for signature-bearing
patterns — the LMA PREREQUISITE IS NOW IN). MERGE LESSON: B's and C's
defer arms conflicted; the union regressed indexedAccessAndNullable
Narrowing through the BASE-CONSTRAINT route — resolved by keeping
modifier-changing deferral for DIRECT receivers only. Machine slept
repeatedly; agents resumed; C's worktree was auto-removed (recreated
as worktree-agent-w44c); D looped on stale waiters until TaskStop.

Wave 45 (+13 exact → 7880/8641 91.2%): THE LMA WAVE — C implemented
JSX.LibraryManagedAttributes completely and CORRECTLY (all 15 keys
match when ON; both apps byte-identical; grid 60/60) but it ships
FLAG-OFF on a measured +15.6% social-app wall: ~1300 distinct
(tag,props) pairs × ~0.4ms of @types/react's 3-deep conditional chain;
the memo hits 91% but misses are irreducible, and the cost is NOT
instantiation (+2.2% expandRef visits vs +15% wall) — it is
assign.relate inside ~5200 conditional checks (~77µs each). THE LEVER
IS THE RELATION, not jsx. C also fixed memoized type-param shadowing
(tp_shadow only in aliasGeneric — interface/class generics memoize the
FIRST reference's binding; `infer U` leaked into Box<U>'s table). A
landed the TS2502 resolution-stack machinery (pushTypeResolution/
popTypeResolution around variableSymbolType; eager-vs-lazy split is
exactly why `var g: {x: typeof g}` is legal and `var f: Array<typeof
f>` is not) — recursiveTypesWithTypeof's 11 divergent keys were ONE
bug; predicate gate widened to all function-likes; satisfies unwrap;
never-receiver destructuring. B landed the intersection index
DISTRIBUTION (authoritative — the constraint route accepts the bad
write, so no fallback; +1.3% drizzle, semantic), the error-type
placeholder for unsupplied type args, transitive index-key constraints
(mappedTypeRelationships now MATCHES), TS2637. B's reactReadonlyHOC
finding: the wave-42 jsx ordering was NOT the blocker — ztsc's JSX
spread of a GENERIC enumerates props and drops the Readonly<P> half;
contained by tsc's own "don't elaborate indexes on generic variables"
guards; the real fix (getSpreadType keeping an intersection) needs an
owner. D landed the .d.<ext>.ts link key, the auto-accessor modifier
family (TS1243 via modPairMessage; TS1042 is a TRAILING check),
variance parser half (TS1273/1274/1030 — the file's semantic pass now
runs), typeof entity names, TS1183. PERF FLAG: drizzle +2.7% CPU
cumulative this wave (B +1.3% semantic + A +0.6%); recovery on watch.

Wave 46 (+23 exact → 7903/8641 91.5%; PERF LEDGER FLIPPED: social-app
−7.9% CPU, drizzle −2.1% — the debt repaid): B's profile found the
LMA cost was NOT assign.relate's internals but two unmemoized
whole-type predicates recomputed per path (containsFreeTypeParam —
160/1615 samples under planConditional; baseConstraintOf) plus
typeToString re-printing per derivation level (10% of the run for 31
diagnostics). Three memos: social-app 2.82→2.61s at jsx_lma=false;
LMA delta +15.6%→+2.7% med/+1.9% min — flag stays OFF by a hair (gate
≤2% vs same-generation false), but `true` is now 5% FASTER than what
shipped before this wave; the residue is diffuse (no term >0.9%).
Also varianceAnnotations 31/31 minus 2 (mergedDeclaredVariances ORs
in/out across merged blocks; varianceMeasurable no longer re-expands
the generic being measured — growing self-recursion minted fresh
TypeIds past `seen`), distributionDependent guard (narrowed to
both-sides-conditional after the sweep caught recursiveReverseMapped
Type — ztsc's tuple-vs-variadic rule gap made the {} branch carry the
tuple), TS2411 entry point provided. A landed the 20-key spread-tuple
family EXACT (tsc's real rule from ~90 probes: naive index before the
first spread; no-variable-element tuples answer the UN-REDUCED union
FROM THE FIRST SPREAD; variable-element tuples align the fixed tail
from the END) and the single-return predicate widening. C landed
tsc's full three-guard co/contra rule (cov_drop records what the
incremental fold walked past; dependentConflict) and mapped key-set
priority (MappedTypeConstraint tier = the existing Rev tier). D
landed the destructuring-assignment flow family (four bugs in one
shape; nested pattern-default binds its RIGHT side first), false
in-guards on intersections reaching never, hyphenated JSX attributes
(tsc waives in exactly THREE places — never a fourth; index
signatures say nothing about them), five parser shapes. D also
RE-RANKED the generic-JSX-spread item: reactReadonlyHOC already
matches; the guards are tsc-faithful and permanent; the spread gap is
a quality item worth 0 keys.

Wave 47 (+17 exact → 7920/8641 91.7%; LMA SHIPPED): B decomposed the
flag's cost — the re-enabled attribute-checking arms are FREE (+0.00%);
the whole delta is the transform's own evaluation, 1.41% inclusive by
five load-immune 1ms profiles (the wave-46 medians were CONTENTION:
+1.54% at load 11 vs +4.17% at load 20). jsx_lma=true; apps
byte-identical; −15 under keys. RECORD CORRECTIONS: the LMA subtree is
91% subst.instantiate, 4% assign.relate (wave-46's attribution was
wrong); recursiveReverseMappedType is NOT the tuple-vs-variadic rule
(it is alias interning: an in-progress self-reference TypeId differs
from an external ref); varianceAnnotations 75:11's guard does not
suppress — it MANUFACTURES the yes (growth-guard variants measured out
in checker.zig). C then made tsxLibraryManagedAttributes EXACT: the
check-substitution distribution loop kept distributivity only for
members that can still grow, and an unresolved INFER var wasn't
counted — one-term widening (or containsInfer) in subst.zig. C also
landed the array-literal two-round pass (contextualOverloadListFrom
ArrayUnion exact), probe-table extraction, fresh-literal-vs-seeded-
param, type predicates count as contextual returns. A landed TS2411
type-literal wiring (comptime keeper deleted), the empty-pattern
non-null MATRIX (void|null is TS2531 ALONE — getNonNullableType
strips void with the nullables), TS1039 class-field half; and
confirmed outer-type-params needs class_value to carry ARGS (~30
consumer sites — dedicated wave, full design in report). D landed
escape cooking (string_value.zig: cook + writeEscaped inverse pair,
zero-copy fast path, 50-run grid), three parser recoveries (escaped
def\u0061ult cooks into the keyword), mask_type alias-merge. PERF:
social-app +3.0% this wave (LMA transform + inference work) but −5%
NET vs wave-45 — watch continues; next shave target is
subst.instantiate's alias-body machinery.

Wave 48 (+20 exact → 7940/8641 91.9%): A landed the CLASS_VALUE ARGS
feature — two spellings discriminated by payload (inline symbol when
no outer args = byte-identical interned ids; extra[] otherwise), a new
class_value.zig with outerTypeParams memoized per class symbol
(reproducing isTypeParameterPossiblyReferenced's filter), and the key
design point: outer args ride the class VALUE, a ref's args still fill
only the class's OWN params — arity/TS2314/printing untouched. Both
witnesses exact. Also found Tokens.starts packs the ASI bit in the top
bit (raw lowerBound silently skips line-initial tokens) and landed B's
recursive-alias handoff via the narrow route: isAssignableInner had a
.ref-SOURCE resolve rule but no TARGET twin (no origin side table —
B's +32 regression route avoided). B landed the JSX SPREAD pool (+4):
per-entry spread provenance; elaborate reads the COMBINED object's
member anchored at the written attribute; intersection spreads
contribute per-name intersections — and fixed the same last-arm-wins
bug pre-existing in destructure.objectRestType (social-app
PostControlButton shape). C made all three targets EXACT: numeric
names reach [k: number] index signatures (findApplicableIndexInfo
tail); a spread of an object literal is PART of the literal (the
context-free speculative distributableSpreads walk was filing TS7006s
for good); getLiteralTypeFromPropertyName reads the name NODE not the
atom (keyof {0(){}} is 0; {"0"(){}} is "0"). D landed the
class-expression self-name shadow (classSymbolOf asked the enclosing
scope FIRST — 5-line reorder), the definite-assertion family
(TS1255/1263/1264 via new definite_assertion.zig), four
ambient-module rules, TS6137. PERF: excalidraw RSS +3.1% bisected to
B's combined-attributes object — semantically required, ~3MB retained
by interning; ACCEPTED FLAGGED with an arena-scoping lead queued.
crashDeclareGlobalTypeofExport DOUBLE-diagnosed: the binder is fine;
mergeGlobals' umdMergeTarget redirects the augmentation's const to
the module namespace — fix needs the TS2454 interaction solved.

Wave 49 (+19 exact → 7959/8641 92.1%; PERF: social-app RSS −22.1%,
CPU −2%; excalidraw RSS recovered −3.35%): D's printer budget was the
headline — typeToString truncates at 160 bytes but printers rendered
EVERYTHING (incl. structural sort keys of unions nested in the
discarded part), and every string dupes into the never-released
diagnostic arena; printType now unwinds on BudgetSpent, byte-exact,
sort keys unbudgeted (a capped key would tie and fall back to
TypeId order — the divergence the key exists to prevent). D also
landed JSX two-round inference (three tsc mechanisms: skip only
context-SENSITIVE attributes; re-read deferred sites in source order
feeding each other; substituting a parameter FIXES it), TS2499,
TS2669 (finding: bind.is_module is HALF of tsc's external-module test
— import.meta anywhere also qualifies; patched locally, unification
queued). B recovered the wave-48 RSS (the combined-attributes gate
now interns only after a spread property REJECTS — a reorder,
equivalent by construction), landed TS1329 (tsgo rule not in tsc
source: only identifier/dotted decorators), TS1268 for type literals,
the tuple REST-element read (two readers took .ty straight — a live
FP on number-index relation), and tsc's four-rung tuple-arity ladder
(20 shapes verified). A landed the TS7024 circular-return mechanism
(ret_res_stack; two oracle-measured exclusions: whole-return direct
self-call answers silentNever; generic/block-arrows stay out),
TS2315's safe half, new-C() outer args, and both C handoffs WITH
corrections (ctxPropType's intersection arm let an any-index swallow
the declaring sibling — fixed declared-only and gated). C landed
intersection reverse-mapping (reverseMappedSourceProps merges
constituent names via collectPropNames), the class_value unify arm,
keyof outer-args. SUBSTITUTION TYPES confirmed as a real missing
feature (the conditional-call fix swaps TS7006 for TS2345 without
them — number relates as number & T inside the true branch).

WAVE 50 STATUS (all four branches MERGED to main; per-branch gates all
green — 0 regressions each, conformance 1330/1330, apps byte-empty,
grids clean; THE COMBINED SWEEP WAS INTERRUPTED BY A SHUTDOWN AND MUST
RE-RUN BEFORE WAVE 51 LAUNCHES — expected ~7970/8641 ≈92.2% from the
per-branch sweeps: B +2, C +1, D +8, A suite-neutral):
A landed the SUBSTITUTION-TYPES FOUNDATION: types.Kind.substitution
(base, constraint) with degenerate wrappers dropped at intern; full
transparency arms (print shows base; instantiate maps both;
containsTypeParam descends; relation reads tsc's getNormalizedType —
source→constraint&base [CONSTRAINT FIRST, oracle-verified], target→
base); creation frames around conditional TRUE branches riding
SavedCtx; SCOPED to concrete bases — each excluded family's breakage
measured (indexed-access broke ajv's mapped/050; mapped-key broke 142
social-app keys via reanimated; TYPE-PARAM is the big win but needs
three arms first). WAVE-51 STEP IS ONE LINE (admit .type_param in
generics.substitutable) after: a .substitution arm in
props.propOfTypeIdx, the cond_true_depth screen in
typeparams.undecidableTypeArg, branch-identity peeling in
assign.condBranchwiseRelated (probes p5/p9 in A's scratchpad).
drizzle +1.06% CPU consistent (machinery, not substitutions) —
accepted. B landed instantiateOuter in the four class_value relation
sites (+1 typeArgumentInferenceWithClassExpression1), the readonly
single-element variadic bridge, the FULL shouldReportUnmatchedProperty
Error port. C landed keyof's class_value outer arm (honest 0 delta)
+ TS2767 iterator-protocol methods (slow path only). D landed
PARAMETER DECORATORS end-to-end (ast.ParamDecos side table; binder
binds from the class-body walk; ctor param gets class VALUE +
undefined key — oracle-confirmed; +5), TS2661 identity-resolved
globals (shared primitive_type_names.zig), bind.is_module =
isFileProbablyExternalModule (workaround retired, byte-neutral).
KEY FINDINGS: TS7022 initializer-circle pool (13 cases) blocked on
cycle-detector granularity — needs function-body nesting depth
(expr.zig); A's attempt was +1/−4 and reverted. crashDeclareGlobal
TypeofExport's TS2502 is NAME RESOLUTION (typeof zap resolves to the
UMD namespace, not the global const — typespace.typeofEntity/linker).
callOfConditionalTypeWithConcreteBranches is NOT substitution — it's
contextual typing through a deferred-conditional callee (calls/infer).
TS2454-in-decorators FP mechanism pinned (getControlFlowContainer
stops at PropertyDeclaration; in_decorator gate written, unlanded).
Ref-level outer args for class INSTANCE types heads the wave-51 queue
(types.zig payload mirroring class_value's).

## Ranked next queue (wave 50) — SUPERSEDED by the status block above; original queue kept for context

1. instantiateOuter in assign.zig's class_value arms (LAST blocker for
   typeArgumentInferenceWithClassExpression1/3; sites pinned:
   assign.zig:3954/3956 target, :797/:801/:6336 source,
   assign_report.zig:1081-2). B.
2. keyof.zig's classStaticType reads without outer substitution
   (:377/:1302/:1399 — the keyof typeof C arm). C.
3. SUBSTITUTION TYPES (dedicated-wave candidate, now twice-confirmed):
   inside `number extends T ? …` the true branch's number must relate
   as number & T (tsc's SubstitutionType). Unblocks
   callOfConditionalTypeWithConcreteBranches + the wave-31-era
   deferred-conditional items.
4. TS7023 object-literal-method / accessor `this` circularity (5+
   one-keys: checkingObjectWithThisInNamePositionNoCrash,
   trivialSubtypeReduction…, thisInObjectLiterals, for-of33/34/35) —
   a DIFFERENT mechanism from the landed TS7024.
5. Instance side of outer type params: a .ref carries only local args;
   tsc models outerTypeParameters ++ localTypeParameters on the
   declared type (bigger; design against the class_value work).
6. bind.is_module unification (import.meta as an external-module
   indicator — moves module scoping; own sweep).
7. jsxChildWrongType (children relation — dedicated wave; deliberate
   leniency documented at jsx.zig:1852).
8. Small pinned: crashDeclareGlobalTypeofExport's last TS2502
   (signatures.zig — B); TS2661 (globalThisGlobalExportAsGlobal);
   parameter decorators DISCARDED at parse (parser AST edge + TS1239
   ×7/TS1308 — D parser + decorator checker); tuple per-position FLAG
   ladder (startCount shift — B, own sweep); TS5108; TS1039 arrow
   span.
9. STRIKE from queue: TS1315 (zero corpus cases).
10. Census: 166 one-key (−TS2322 ×10, −TS2339 ×6, −TS7023 ×5,
    +TS2322 ×5, −TS2304/−TS2741 ×4).

## Superseded queue (wave 49, kept for context)

1. Excalidraw RSS lead: arena-scope the JSX combined-attributes object
   per element (or avoid interning it) — recover the +3MB (B/D).
2. JSX intra-expression inference (3 keys): jsx.zig's generic
   inference is a separate SINGLE-round pass — Phase 1 skips every
   function-valued attribute, so `<Foo a={() => 10} b={arg => …}/>`
   never learns T from a. Needs the two-round pass infer.zig has (D).
3. Reverse-mapped INTERSECTION source: inferReverseMappedFrom accepts
   only .object; tsc's getPropertiesOfType merges constituents. Needs
   a shared intersection→merged-member-table helper (props.zig logic;
   intersectionTypeInference2 would be exact).
4. typeArgumentInferenceWithClassExpression1/3 — NOW FEASIBLE with
   class_value args: unify needs a class_value-vs-class_value arm and
   the relation a rule for distinct anonymous class values.
5. class_value consumers still ignoring outer args (A's list, no
   regressions, under-behaviour): new C() on a filled-in value,
   classStaticType/classConstructType, keyof typeof C.
6. implicitAnyFromCircularInference function half (4 keys): scoped —
   per-signature return-resolution stack at sig_cache read
   (signatures.zig:67), report after inferReturnType (:279); BLOCKED
   only on naming a nameless function expression (tsc getAssignedName
   walks to the parent declarator; ztsc has no parent pointer).
7. Printer wins: propDisplayOrder is 3% of social-app CPU (sorting
   hundreds of props for 31 truncated messages — cap or lazy-sort);
   quote rule + method bit need declaration info on types.Prop.
8. jsxChildWrongType (children elaboration: generateJsxChildren +
   array-like target split; jsx.zig); jsxIntrinsicDeclaredUsing
   TemplateLiteralTypeSignatures (needs TWO pattern-keyed index
   signatures — types.zig single-slot limitation).
9. mergeGlobals UMD-target choice (decline when a real global clashes)
   + the TS2454 interaction (crashDeclareGlobalTypeofExport).
10. Small pinned: "constructor"() string-named ctor (member_names.
    isCtorMethod requires the keyword token — costs a false TS2300 +
    missing TS1093); TS1315 (export-as-namespace outside .d.ts);
    TS2669 (rule measured, needs spare app cycle); TS1039 arrow-span
    (FnProto start token — broad); decorator call-signature codes
    TS1238/1239/1308/1329 (calls/signatures).
11. declarationEmitExpressionInExtends4: TS2315 at the base expression
    on arity mismatch — the leniency is deliberate; revisit with own
    sweep.
12. Census: 39 parser/link/flow one-keys; TS2322 pools (10 under /
    6 excess one-key after this wave); TS1021/TS1268 index-key items.

## Superseded queue (wave 48, kept for context)

1. JSX SPREAD ATTRIBUTE relation pool (B's re-rank: the densest single
   remaining pool now that LMA landed the props target): tsxAttribute
   Errors (`<div {...attribs}/>`), tsxSpreadAttributesResolution5/12,
   jsxChildWrongType — 4+ single-key cases, one root (jsx/relations).
2. subst.instantiate shave for alias bodies (the 91% of the LMA
   subtree; also the social-app watch item).
3. recursiveReverseMappedType: alias interning — expansion(R) must
   meet ref(R) for a recursive generic alias whose body is a union
   containing a deferred conditional (typespace/instantiate; repros
   t6-t8 in w47b probe dir).
4. Named class EXPRESSION's own name must shadow a same-named outer
   declaration inside its body (binder/scope; 16-line repro v3.ts;
   varianceAnnotations 176:9 and beyond).
5. class_value ARGS (the outer-type-params dedicated wave): payload +
   ~30 consumer sites across narrow/assign_report/generics/print/
   heritage; instance half needs typeParamsOf = outer ++ local
   (localTypeParameters split). One agent owns types.zig + consumers.
6. TS7023 cluster (5 one-key cases): circular inferred returns for a
   class GETTER and object-literal METHODS — extend signatures.zig's
   reportMemberCycle/methodReturnDeferred beyond class methods (A).
7. intraExpressionInferences last 4 keys: getContextualType for a
   SPREAD operand inside an object literal (expr.zig).
8. contextualTypeWithUnionTypeIndexSignatures (5 excess): ctxPropType
   misses the NUMBER index signature for a numeric property name
   (string half works; expr.zig).
9. declare-global SCOPING in the binder (crashDeclareGlobalTypeofExport:
   ztsc binds the body into the file's own scope; tsc keeps the
   augmentation's locals separate — that's what makes typeof foo
   circular; real binder change).
10. Small pinned: computedPropertyNames12 TS2411 class half (index
    infos from computed keys); TS1239 decorators (unimplemented, ×2);
    jsxAndTypeAssertion TS1109; mappedTypesGenericTuples2 TS1360;
    TS1039 syntactic suppressors.
11. Print slot (own cycle, app-churn): tsc's quote rule (quote any
    non-identifier name); method-vs-property signature rendering;
    [declaration-order members remain a deliberate divergence].
12. coAndContraVariantInferences3 (10 excess TS7031 multi-hop builder
    chain — real, not quick).
13. Census: 183 one-key cases; TS2322 pools (29 under-cases/46 keys,
    12 JSX); TS2339 ×6; blocked list unchanged.

## Superseded queue (wave 47, kept for context)

1. LMA FINAL SHAVE + FLIP: +2.7% med / +1.9% min vs same-gen false —
   one more diffuse shave (or a quiet-machine re-measure) clears the
   ≤2% gate; everything else is proven. Then the Defaultize-with-
   type-param-keyset reduction (2 residual keys, repro in jsx_lma doc).
2. TS2411 wiring: B's checkTypeLiteralIndexConstraints is IN (with a
   marked comptime keeper to delete) — A wires typenode's
   .object_type arm (site pinned at typenode.zig:305). The class
   computed-key propNameType machinery is separate.
3. contextualOverloadListFromArrayUnion (ready-to-implement, 3-line
   witness recorded): context-sensitive ARRAY literals must route
   through Phase 2's fixing pass like function arguments — an
   inferTypeArgs phase-split restructure (infer.zig).
4. staticAnonymousTypeNotReferencingTypeParameter +
   genericClassExpressionInFunction (SAME root, 2 cases/4 keys):
   tsc's outerTypeParameters on an anonymous class inside a generic —
   needs instantiate.zig/subst.zig ownership (dedicate next wave's
   core-files slot).
5. crashDeclareGlobalTypeofExport: UMD `export as namespace` merges
   with a global-augmentation const into ONE symbol (typeOfSymbol
   returns their intersection, never re-enters); tsc keeps two
   colliding globals (2×TS2451) and still types the const
   (link/umd.zig + binder).
6. varianceAnnotations residuals: 75:11 TS2636 rides out on
   rel_guard_tripped; 176:9 TS2741 (named class EXPRESSION
   self-reference).
7. recursiveReverseMappedType: the tuple-vs-variadic-tuple relation
   rule (B's finding — the reason the distribution guard had to
   narrow).
8. String-literal escape cooking (atoms.zig memberAtom; third
   recording — stringLiteralPropertyNameWithLineContinuation1 +
   literal-type printing; dedicated slot).
9. Small pinned: TS2532 on void destructuring (destructure.zig);
   TS1039 pair (declare-field initializers in non-ambient class);
   castOfYield; escaped `def\u0061ult` switch; interfaceDeclaration4;
   noCrashOnImportShadowing (dual export-table).
10. Census: 183 one-key cases; TS2322 whole-case pools (UN×32/EX×23);
    TS2339 UN×11; TS2769 UN×8.

## Superseded queue (wave 46, kept for context)

1. RELATION CHEAPENING for conditional checks — the LMA blocker and a
   general win: ~77µs per conditional-branch relation on social-app's
   component types. Profile assign.relate on the jsx_lma=true
   workload (flip the const to re-measure), find the hot predicate,
   land the optimization, then ship LMA (everything else is proven).
2. JSX spread of a GENERIC type produces an INTERSECTION (tsc
   getSpreadType) — reactReadonlyHOC root; B's containment guards can
   then retire (jsx.zig).
3. varianceAnnotations' remaining 12 under keys (pure checker, now
   unblocked by D's parser half — TS2637/TS2636/TS2322/TS2741; B).
4. spreadsAndContextualTupleTypes (20 excess, ONE root): an array
   literal's positional contextual type must account for spread
   expansion (wave-44 A recorded tsc's rule: naive index, then
   getElementTypeOfSliceOfTupleType — an UN-REDUCED union of the
   remaining slice keeps literals literal). Changes every
   spread-in-tuple-context literal — own sweep (expr, A).
5. Defaultize-with-type-param-keyset: an alias instantiated with a
   type param in its key set + an infer binder supplying excluded
   keys loses the Extract/Exclude split (2 residual LMA keys; repro
   in the jsx_lma doc comment; mapped/conditions, B).
6. Hyphenated JSX attributes: isKnownProperty waives only the EXCESS
   check — `<test1 data-foo={32}/>` against {"data-foo"?: string}
   still owes TS2322 (jsx.zig:1698 drops .jsx_name attributes from
   the walk entirely; touches every aria-*/data-* in both apps — own
   app cycle; D).
7. conditionalTypeVarianceBigArrayConstraintsPerformance:
   isDistributionDependent guard in structuredTypeRelatedTo
   (conditions.zig, B).
8. TS2411 type-literal hook: needs a pub entry point in
   index_constraints.zig reaching checkOne with a type literal's
   members (B provides the entry, A wires typenode's .object_type).
9. inferTypePredicates residue: the non-union false-in-guard
   narrowing (narrow.zig — D deprioritized; REASSIGN with the pinned
   witness 'bar' in value on Bar = Foo & {bar}); the single-return-
   plus-unreachable-end widening (A, 1 key).
10. controlFlowAssignmentPatternOrder flow half (12 keys: `b` keeps
    its declared union after destructuring; flow.zig, D).
11. mappedTypeConstraints2:94:9 (indexed access into an as-clause
    mapped type stays deferred; mapped.zig, B);
    crashDeclareGlobalTypeofExport (global-augmentation decl walk).
12. DRIZZLE RECOVERY WATCH: +2.7% cumulative — hunt an offset (the
    wave-43/44 pattern recovered prior debts).
13. Census: regularExpressionScanning is 108 keys/dozen codes (not
    one rule — descoped); one-key pools regen.

## Superseded queue (wave 45, kept for context)

1. The .d.<ext>.ts link one-key (READY, pinned): `export * as mod from
   "./component.html"` must also try component.d.html.ts — one
   candidate appended LAST in resolve.zig's fall-through (can only
   remove TS2307s). declarationFileForHtmlFileWithinDeclarationFile.
2. inferTypePredicates (12 excess, three pinned bugs): signatures.zig
   :300 gates inferred predicates to arrow/function-expr — tsc runs
   getTypePredicateFromBody for every function-like except ctors/
   accessors (8 keys); :345 unwraps only parens and `!` — `satisfies
   boolean` stops it; narrow.zig: narrowing a NON-UNION by a false
   in-guard must reach never (union works).
3. controlFlowAssignmentPatternOrder (18 excess, two bugs): an
   array-pattern element DEFAULT isn't used when the RHS tuple lacks
   the element (destructure.zig); `b` keeps its declared union
   instead of narrowing to the destructured element type (flow.zig).
4. TS2502+TS2403 same root (signatures.zig:2762): tsc reports TS2502
   AND resolves the annotation to `any` (so the var-redeclaration
   matches); ztsc does neither. recursiveTypesWithTypeof 11 keys +
   implicitAnyFromCircularInference 8 + 3 one-keys.
5. Parser concentrations: autoAccessorDisallowedModifiers (28 keys,
   ONE modifier rule); regularExpressionScanning (17 TS1518 keys);
   invalidTypeOfTarget (6+ keys).
6. B's wave-41 simplifyIntersectionIndexAccess RETRY: the jsx-ordering
   blocker landed in wave 42 — the written-and-verified fix
   ((A & B)[K] keeps every conjunct, Instantiable guard) should now
   be a clean +1 (indexedAccessRelation).
7. typeArgumentDefaultUsesConstraintOnCircularDefault: a
   self-referential default resolves to the ERROR type (tsc prints
   Test<any>); tp_default_stack doesn't trip because it resolves
   without re-entering fillDefaults (typeparams.zig).
8. TS2411 type-literal hook (tsc checkTypeLiteral → checkIndex
   Constraints; ztsc covers only class/interface decls) — typenode
   .object_type arm; the computed propNameType machinery is separate
   and bigger.
9. Template-literal EXPRESSION in index position gets a
   template-literal TYPE (mappedTypeConstraints2's last 2 keys).
10. THE LMA WAVE (prerequisite landed): jsx.zig:212 seam behind a
    flag → measure grid + both apps + perf (3-deep conditionals ×
    2836/16547 tags) → remove flag if clean. Own-wave-sized, one
    agent dedicated. 15+ keys.
11. JSX TS2322 one-key unders ×9 (D); varianceAnnotations end-to-end
    (in/out: TS1273/1274/2636/2637, parser+checker own slot).
12. mappedTypeRelationships:109:9 (f50/f51 one-side-constrained);
    deeplyNested both-sides guard (blocked: zod 2.5x cost measured).
13. Census: 193 one-key cases (30 excess / 163 under; TS2322 under
    ×15 with 9 JSX); build-stagger lesson for concurrent agents.

## Superseded queue (wave 44, kept for context)

1. DETERMINISM DEFECT: excalidraw UserList.tsx:285:11 TS2345
   order-dependent at checkers 2/4/8. Method that closed the prior
   three: shrink with --partition-file to a two-file repro, instrument
   node_types, find the consumer of an order-dependent artifact
   (makeUnion member order is the known hazard class).
2. Debug-binary panic: constEnumOnly (expr.zig:1333) reads c.declsOf
   (sym) against the CURRENT file's tree for a foreign-file symbol —
   index OOB; real cross-file bug masked by ReleaseFast. Fix + consider
   a debug-build app smoke test in CI.
3. TS2449 single-rule target (27 keys, 21 in useBeforeDeclaration_
   classDecorators.1): checkTdz needs tsc's isUsedInFunctionOr
   InstanceProperty INCLUDING the !getImmediatelyInvokedFunction
   Expression clause (an IIFE does NOT defer). expr.zig.
4. The mapped-read defer chain (B's saved patch at scratchpad/w43b/
   expr-defer.patch, fixes all 8 mappedTypeRelationships keys):
   FIRST land canBeNullish answering deferred accesses
   (nullability.zig) + reduceSubtypes letting {} absorb after
   getNonNullableType's intersection (typenode.zig), verify the
   excalidraw change.ts:189/190 chain matches tsgo, THEN flip
   indexDeferrableObject's mapped arm.
5. mergedDeclarations7 COORDINATED fix (design final): combined_sym
   minted at link time on DualTarget (src/link) + checker gate in
   typespace.typeMeaningTarget (fresh nominal interface ONLY when the
   value half is a property of the export= value's type — static_named
   must stay non-fresh).
6. Homomorphic flag split (mapped.zig): syntactic keyof-constraint vs
   bare-type-param homomorphic — naive deferral cost 3 regressions +
   a timeout; needs the two-flag design.
7. keyof of a key-remapped generic map: keyof Mapped6<K> answers
   string|number|symbol (keyof.zig).
8. TS2411 (index_constraints.zig): member-vs-index-signature
   constraint checks (propertiesAndIndexers:51,
   computedPropertyNames12).
9. intersectionReductionStrict legs: empty const enum types as never
   (enums.zig); write-type intersection for a union key on a concrete
   receiver (expr.zig).
10. deeplyNestedMappedTypes: the depth guard answers "related" —
    needs an isDeeplyNestedType equivalent that REPORTS (2 keys).
11. Excess pools: spreadsAndContextualTupleTypes (19),
    controlFlowAssignmentPatternOrder (12), inferTypePredicates (11).
12. JSX under cluster (~10 cases / 40+ keys incl.
    tsxLibraryManagedAttributes 15): real LibraryManagedAttributes —
    own-wave-sized, changes every component check in both apps.
13. indexSignatures1 (9 under), keyofAndIndexedAccess2 (7),
    varianceAnnotations (7); TS2526 remaining clauses (needs a parent
    map or syntactic pass, 30 keys); TS2502 circularity family.
14. Blocked (unchanged): alias identity at relation use sites (5 keys
    2 cases — both recovery routes are settled NOs); TS7023; union
    ordering pair.
15. Cosmetic: TS2675 fully-qualified name in message.

## Superseded queue (wave 43, kept for context)

1. mergedDeclarations7, the REAL fix (fourth diagnosis, proven):
   combineValueAndTypeSymbols in import/alias resolution — a named
   import through `export =` of a merged const/namespace mints a FRESH
   symbol carrying the interface's declarations, giving a distinct
   interface type with its own thisType (names.zig/typespace.zig +
   link support for the specifier node).
2. props.zig mapped reads: Partial<T>[K] carries `| undefined` at the
   READ site (mappedTypeRelationships, 8 under); obj[key] on a generic
   mapped type resolves `any` instead of staying deferred
   (mappedTypeConstraints2, 5 under).
3. Intersection reduction of DISJOINT constituents (tsc getReducedType)
   in makeIntersection — types.zig, needs an owner (intersection
   ReductionStrict, mappedTypeNotMistakenlyHomomorphic,
   intersectionWithUnionConstraint:25).
4. baseConstraintOf: `keyof T` answers stringNumberSymbolType for ANY
   Index type, not keyof(constraint) (expr.zig;
   mappedTypeContextualTypesApplied:21 + prior wave hits).
5. literalWideningWithCompoundLikeAssignments (11 excess — expr/narrow
   compound-assignment widening).
6. tsxLibraryManagedAttributes (15 under, jsx).
7. TS2595: link/modules must carry the import specifier's node onto
   the deferred .export_equals_prop target (then modvalue reports
   "can only be imported by using a default import").
8. controlFlowBindingPatternOrder: binder must bind a binding
   element's INITIALIZER before its name when the name is a pattern
   (binder.zig).
9. TS2688 twice: config-level diagnostics channel ((config):0:0 keys,
   main.zig, must NOT suppress the semantic pass); exports-map
   authority in resolve.zig (package.json exports present → never
   consult "types"; app re-proof mandatory).
10. const type-param freshness (typeParameterConstModifiersWith
    Intersection:23:3): an object literal contextually typed by a
    CONST type param must not be excess-checked in the constraint
    probe — the clamp reads FreshLiteral, and a const-context literal
    loses it via getRegularTypeOfLiteralType.
11. Parser: reservedWords3's full recovery shape (reserved word left
    UNCONSUMED, list ends, tokens re-parse at statement level);
    jsxNamespacePrefixInName / jsxInvalidEsprimaTestSuite cascades
    (24 keys); variadicTuples2's checker-side TS1265s.
12. De-duplicate infer.simplifiedIndexPattern with
    mapped.simplifyMappedIndexAccess into mapped.zig.
13. Census pools: TS2411 ×3, TS2502 ×3, TS2523 ×2, TS2526 ×2, TS2677
    ×2 (needs a declaration-walk reporting site), TS2675 ×2;
    consistentAliasVsNonAliasRecordBehavior (alias variance for
    mapped aliases); TS7023 (blocked).

## Superseded queue (wave 42, kept for context)

1. jsx.zig ordering: the per-attribute pass runs UNCONDITIONALLY; tsc's
   elaborateJsxComponents runs only after the whole-attributes-object
   check FAILS. Fixing this unblocks B's written-and-verified
   simplifyIntersectionIndexAccess (+1, indexedAccessRelation; with
   the Instantiable guard; also explains reactReadonlyHOC).
2. TS2574 with the RIGHT predicate (A's revert recipe): isArrayType ||
   isTupleType || type-param whose BASE CONSTRAINT is array-like ||
   any/error — never isAssignable; a variadic-position infer is
   unknown[]-constrained. Flips restTupleElements1.
3. Static field of a class EXPRESSION: statics.seedStaticFieldContext
   seeds the symbol but checkClass's member walk re-checks with
   ann=no_type (sig cache misses on different context) — thread the
   ctx through (contextuallyTypedClassExpressionMethodDeclaration01).
4. mergedDeclarations7 re-diagnosed AGAIN (A): polymorphic-this return
   variance — `use(): this` on PassportStatic must not be assignable
   to Passport (assign.zig). [The namespace/variable intersection arm
   is measured correct — removing it makes X.member a phantom 2339.]
5. Generalize template-hole pairing into infer.unify (calls + return
   positions); de-duplicate simplifiedIndexPattern +
   simplifyIntersectionIndexAccess into mapped.zig.
6. contextualSignatureInstantiation: a FAILED contextual instantiation
   leaves the call result `unknown` (infer.zig fold), not the folded
   candidate that poisons downstream flow.
7. Argument-level isContextSensitive must carry through an
   object-literal argument's properties (infer.zig;
   expr.exprIsContextSensitive is ready to call).
8. TS7006 buckets: mapped/reverse-mapped inference 11 keys (B); JSX
   generic tags 10 (D); intra-expression inference 9 (B).
9. for…of nullish subject: TS18050 ahead of TS2488 — checkNonNullType
   at stmts.zig:667; changes every for..of over nullish, re-prove apps.
10. controlFlowForIndexSignatures: `typeof x` is not narrowed in TYPE
    positions at all (typenode/flow); crashRegressionTest: element
    access goes `any` on a TS2339 index and skips the write check
    (expr.zig).
11. Parser: reservedWords3 (TS1390 for enum/class/function/while/for
    as parameter names — ztsc answers TS1359); parseInvalidNames
    (startsDeclarationAt recursing through export into namespace's
    same-line test); variadicTuples2's 3 residual TS1265s (variadic
    branch); accessorWithLineTerminator (get\nx parses as two members).
12. Flow: noImplicitAnyLoopCrash (`let bar;` in a loop is
    number|undefined at the spread, ztsc evolving-any).
13. Small: defaultParameterAddsUndefinedWithStrictNullChecks (the WRITE
    target stays the declared annotation — paramBodyType);
    staticAnonymousTypeNotReferencingTypeParameter;
    controlFlowBindingPatternOrder; TS2300 computed-name binder keys
    (6, blocks computedPropertyNamesWithStaticProperty).
14. Blocked/architecture: combineValueAndTypeSymbols; alias-variance
    relation rule; TS7023 re-entry hook; union-ordering pair.
15. Census: TS2322 (212 under / ~250 excess pools); TS7006 54 excess;
    substitution types; resolution-mode attributes.

## Superseded queue (wave 41, kept for context)

1. Per-position CONTRAVARIANT parameter candidates (B's full diagnosis,
   assignmentCompatWithGenericCallSignatures2): instantiateSigInContext
   Of unions a source param's candidates across positions; tsc infers
   param positions contravariantly and closes with getCommonSubtype
   (reduceLeft, first unless later is subtype). Faithful fix:
   per-position candidate slots in applyToParameterTypes reduced by
   common-subtype. Reduced witness in B40's report. High-risk, own
   sweep (infer.zig mechanics + assign.zig caller).
2. templateLiteralTypes5:14:7: TypeMap[T2] → TypeMap[`${T2}`] must
   REJECT because T2 is not assignable to `${T2}` (index types must
   relate; template.zig placeholder-over-constrained-param equivalence
   is wrong).
3. mappedTypeInferenceFromApparentType:14:1: mapped-vs-mapped template
   relation must reduce Obj[K] vs U[K] → Obj vs U and reject ("U could
   be instantiated with an arbitrary type").
4. indexedAccessRelation:17:25: an intersection-object indexed access
   drops non-key-holding constituents — must keep S["a"] & (T |
   undefined).
5. asyncImportedPromise_es5/es6 (one root): async method with a
   Promise-SUBCLASS return annotation (Task<T>) + bare `return;`
   (signatures/stmts).
6. mergedDeclarations7: `export =` + named import of a property
   (link/modules).
7. intersectionsAndOptionalProperties:28:7 FP: `number[] &
   [number, ...number[]]` source → `[number, ...number[]]` target must
   succeed on the identical constituent.
8. reservedWords2 (now the only ex-bucketed non-match): excess 13:19
   TS1138 + 7:16 TS1109 — cheap parser rules.
9. iteratorExtraParameters last key: TS2488 on g(...iter) —
   calls.zig spreadArgTypes files an opaque error_type; wants
   forOfElementType with the operand as blame, but measure the
   cascade first (the silence may be deliberate).
10. Small codes: TS1257 + TS2574 (flips restTupleElements1); TS2449;
    TS2708 ×2; const-enum element access branch (TS2339 at index vs
    TS7053); TS2449.
11. Blocked/architecture (recorded, do not re-derive): TS7023 needs a
    return-type-demand re-entry hook (value-based cache has none);
    late-binding pass ~2 cases (deprioritized); coAndContraVariant
    Inferences5/6 (internal union ordering); destructuringFromUnion
    Spread (distribute spread-of-union, app-risky);
    genericIndexedAccessVariance…:26:1 (alias-variance RELATION rule —
    needs alias identity at the relation, B's file, still blocked on
    ref policy).
12. Census: TS2322 one-keys (20 under / 12 excess); TS7006 excess
    pool (58); TS2304 48/69; TS7053 19/33; substitution types;
    resolution-mode attributes.

## Superseded queue (wave 40, kept for context)

1. CHECKER-SIDE LATE BINDING for computed names (A's + D's handoffs
   converge): tsc's binder gives every dynamic name an anonymous
   symbol — no binder-level duplicate possible; the checker's
   late-binding pass recovers the nominal key iff isTypeUsableAs
   PropertyName, and re-detects duplicates against the RESOLVED key
   type (probe: `"a"|"b"` key is silent, unique symbol + literal keys
   report). Also: blame literal computed names at the `[` (cols 12/23
   not 13/24), TS2564 on computed-name properties
   (duplicateIdentifierComputedName is one fix away), D's
   DeclOpts.dynamic_name empirical partition retires into the pass.
2. Element-access EXPRESSION forms of the new indexed-access errors
   (t2[2] — unionsOfTupleTypes1:31/35/44; expr.zig) — the type-level
   form landed, the expression form now diverges.
3. TS2344 finish (C's full data recorded): FIRST fix props.
   typeParamConstraint reading a MERGED interface's per-block param as
   unconstrained (typeparams folds the sibling constraint; tsc uses
   merged) — then admit a bare free type param WITH the conditional-
   TRUE-branch screen (cond_true_depth in PendingTypeArgs, restore at
   drain) for +2/−0. Also decidableConstraintSet needs .array/.tuple
   (restTupleElements1, 8 keys, plus TS1257/TS2574 to go exact).
4. generatorYieldContextualType: inferGeneratorReturn widens the
   contributed literal unconditionally and hardcodes unknown for NEXT
   (contextualIteration returns only yield+ret) — signatures/stmts.
5. indexedAccessConstraints:6:9 one-liner: computeBaseConstraint for
   ANY TypeFlags.Index answers string|number|symbol
   (expr.baseConstraintOf).
6. Same-alias inference shortcut → tsc's unconditional form: needs
   getAliasVariances-directed pairing (pub variance.measuredAt +
   infer_ctx.contra_pos flip per contravariant position;
   contravariantTypeAliasInference pins it).
7. TS1362 excess on exportNamespace5/8: a name exported by BOTH
   `export type * from` and plain `export * from` is treated
   type-only (link/modules.zig).
8. TS1434 false positives — the largest parser lever left (41 excess
   over 24 cases); then the TS1005/TS1109/TS1128 recovery cascade.
9. types.zig items: index-info parameter NAME (prints x instead of
   the declared k); symbol+string index coexistence (one slot + flag
   today); Prop declaring-symbol for the union-property drop rule.
10. TS2729 residue (ambient containers, function expandos,
    decoratorUsedBeforeDeclaration's TS7006/TS2454); TS7023 ×5.
11. Relation one-keys: indexedAccessRelation:17:25,
    genericIndexedAccessVariance…:26:1 (alias variance),
    mappedTypeInferenceFromApparentType:14:1, templateLiteralTypes5:
    14:7, assignmentCompatWithGenericCallSignatures2:16:1; TS2352
    residue: parseTypes:6:9 (numeric indexInfoOverlap half),
    aliasInstantiationExpressionGenericIntersectionNoCrash1,
    importCallExpressionCheckReturntype1,
    declarationEmitExpandoPropertyPrivateName.
12. Text-only: TS2339/TS2537 print the receiver as written vs tsc's
    reduced APPARENT type; intersection member order in messages.
13. Census: TS2322 pool (22 under / 11 excess); substitution types;
    resolution-mode attributes; reconcile the bucketed 0-vs-5 claim.

## Superseded queue (wave 39, kept for context)

1. TS2729 "used before its initialization" — 7 cases / 15 keys,
   entirely absent (classes/expr).
2. TS2660 `super` placement — 6 cases / 17 keys, entirely absent
   (expr).
3. The QueryPersister function-relation imprecision surfaced by B's
   intersection check (`direction?: unknown` vs a literal union fails
   one way, succeeds the other) — the underlying relation bug is open
   and app-visible (social-app fetchQuery witness in-code).
4. TS2344 residue blocked on undecidableType admitting a FREE type
   parameter (the exclusion that killed 130+ FPs): keyof-argument
   shapes (circularlyConstrained…, styledComponents…),
   unmetTypeConstraintInImportCall; instantiationExpressionErrorNoCrash
   needs failed instantiation → empty-signature object (cascade risk).
5. (Foo|Bar)['foo'] type-level indexed access: ztsc distributes in
   keyof.zig and never reports TS2339 (needs checkIndexedAccessIndex
   Type); plus the union-property drop rule (pinned: no shared
   declaration AND any private/protected — blocked on Prop carrying no
   declaring symbol).
6. TS2416 blame column on computed member names (stmts.zig:1898 uses
   the inner identifier token — one line, +1).
7. Relation leads (B, measured): `new C1() as Record<string,unknown>`
   TS2352 (4 cases, app-risky); `T[keyof T]` with T extends object
   reduces keyof object to never (indexedAccessConstraints:6:9); async
   deferred Promise<T[K]> 3 false TS2322 (asyncFunctionReturnType).
8. deeplyNestedConstraints handoffs: mapped.zig reduceIndexedAccess
   for M[K] over TypeMap<E>; assign.zig distributiveConstraint bails
   on non-type-param checks — extend to any instantiable check with a
   resolvable constraint.
9. Inference one-keys: generatorYieldContextualType (Generator triple
   — iteration/signatures); contextualTypeBasedOnIntersectionWith
   AnyInTheMix1 (isLiteralOfContextualType uses SOME over intersection
   constituents; ztsc intersects first → any; expr.zig);
   mappedTypesArraysTuples:78 (mapped-over-array apparent type).
10. Binder: TS2393/TS2300 on non-late-bindable computed names
    collapsing to one placeholder — tsc reports nothing (~5 cases);
    static_tp_scope TS2302→TS2467 suppression; keyof.zig:884
    numberIndexType symbol guard; print.zig sym_only index rendering.
11. TS1211 (needs modifiers_start seam), TS1084 (reference-directive
    diagnostics path), parseArguments ',' vs ')' after `;` (key-neutral).
12. Census: TS2322 pool; substitution types; resolution-mode attrs.

## Superseded queue (wave 38, kept for context)

1. Non-late-bindable computed member names contribute an INDEX
   SIGNATURE (tsc getIndexInfosOfIndexSymbol): object literals do this,
   classes/type-literals/interfaces don't. `class K { [plain]() {} }`
   with plain: symbol → `[x: symbol]: () => number`; a
   `data-${string}` pattern key gives a STRING-keyed index (verified).
   Wins symbolProperty61, declarationEmitComputedNameWithQuestionToken.
   Changes class shapes — own gate cycle (expr/classes/statics/
   typenode: agent C + flags).
2. Junk-token-as-operand: ztsc CONSUMES a junk/unterminated token as an
   expression operand where tsc's createMissingNode consumes nothing,
   landing 'expected' diagnostics one token late (TypeArgumentList1,
   parserX_TypeArgumentList1, parserRegularExpressionDivideAmbiguity4)
   — highest-yield parser lead.
3. import.defer EXPRESSION form (TS18061/TS17012 + parsing; 4 cases).
4. Missing TS1xxx codes, one each: TS1211, TS1084, TS1196, TS1186,
   TS1142 ×2, TS1477, TS1340, TS1355, TS1453; TS1238/TS1239 decorator
   signature resolution ×6 (checker side, agent C).
5. divergentAccessorsTypes2 message text (keys match): the assignment
   RHS isn't widened in the message ('42' should print 'number' when
   the contextual type is non-literal) AND the message names the READ
   type where the check used the write type (expr.zig).
6. coAndContraVariantInferences5 NEW LEAD: tsc re-checks arguments
   against the CLAMPED parameter types; ztsc doesn't (infer/calls).
7. contravariantOnlyInferenceFromAnnotatedFunction: empirical rule
   oracle-confirmed (extend reverseMappedElem's local_syms to the
   call's tp_syms when the template property mentions K or B).
8. unionPropertyOfProtectedAndIntersectionProperty: tsc's
   createUnionOrIntersectionProperty returns undefined on
   private/protected multi-symbol unions EXCEPT via the
   shared-declaration test — needs oracle pinning (props.zig).
9. String-literal property names need real escape cooking (atoms.zig
   memberAtom stripQuotes; also changes literal-type printing —
   dedicated slot).
10. TS2344 non-inference residue: Parameters<typeof C>,
    import('./f').Foo<T>, instantiation expressions, two
    recursive-constraint cases (typeparams/typenode).
11. deeplyNestedConstraints (>5 constraint levels through a mapped
    TypeMap<E> — sizeable); destructuringFromUnionSpread (union-spread
    distribution rewrite); alias variance (types.zig, still blocked —
    consistentAliasVsNonAliasRecordBehavior).
12. Census: TS2322 one-key pool (~26 under / ~12 excess, capB37/t4.tsv);
    substitution types; resolution-mode attributes.

## Superseded queue (wave 37, kept for context)

1. indexAccessTargetConstraint needs tsc's AccessFlags.Writing: the
   constraint of Obj[K] as a TARGET is the INTERSECTION over a
   union-valued key, not the union (errorInfoForRelatedIndexTypes
   NoConstraintElaboration + likely cluster). Strictly stricter: own
   sweep.
2. setterWriteType residues (each +1): element-access write with a
   UNION key (intersection of the keys' write types;
   divergentAccessorsTypes8:151); object literals carrying write_ty
   through checkObjectLiteral; destructure.getRestType copies Prop
   wholesale so write_ty survives into a rest object where tsc drops
   it (one line).
3. elaborate.abstractCtorTail still uses the OLD bare-construct-sig
   proxy — the "Cannot assign an abstract constructor type"
   sub-message is missing (one line, elaborate.zig).
4. getAndSetNotIdenticalType2:16:1: `new C()` with no inference source
   gives C<any> where tsc gives C<unknown> — class-instantiation path
   only (generic functions already answer unknown).
5. assignmentStricterConstraints: tsc's getInferredType constraint
   clamp in instantiateSignatureInContextOf (infer.zig).
6. TS2345/TS2322 message text widens argument literals ('42' vs
   'number') — print/assign_report; keys match, text doesn't; live on
   divergentAccessorsTypes2.
7. parametersSyntaxErrorNoCrash1/2: extra TS1003 on the `}` ending a
   broken parameter list where tsgo is silent (parseParams
   startsNoParameter retraction).
8. TS1268/TS1337 in TYPE LITERALS (needs a checker.zig hook).
9. import defer type * recovery (exact reconstruction open; probe
   data in wave-36 D's report).
10. makeIntersection ORIGIN — redesign-sized, 0 exact today. Defer.
11. `with` residue (no suite cases). Skip unless a witness appears.
12. Census: TS2322 one-key pool; substitution types; resolution-mode
    attributes.

## Superseded queue (wave 36, kept for context)

1. Object-literal BODY DEFERRAL (tsc checkNodeDeferred): ztsc walks
   method bodies inline so getContextualThisParameterType's
   checkExpressionCached(containingLiteral) fallback is impossible; one
   mechanism unblocks expando `this`, jsxComponentTypeErrors TS2786,
   objectLiteralThisWidenedOnUse, looseThisTypeInFunctions:29. One
   agent, one wave, C's files. Cheap approximations invent TS2339s.
2. makeIntersection ORIGIN (types.zig): ztsc distributes T1 & T2 into
   the union at construction keeping no origin; TS2859-silence requires
   "target is literally an operand of the source intersection" (7-case
   oracle battery in B35's report).
3. measuredVariances: add Unreliable/Unmeasurable
   (AllowsStructuralFallback) — prerequisite for
   measured_variance_decides and any negative variance verdict.
4. Divergent accessor WRITE type: types.Prop needs a write type; wire
   expr.setterWriteType for anonymous type literals too. Cluster:
   divergentAccessorsTypes4, getAndSetNotIdenticalType2,
   divergentAccessors1.
5. Mapped `as` clause: mappedAssignable bails on mappedAs(t)!=0; tsc's
   keysRemapped branch relates the AS-CLAUSE TYPE to keyof source
   (mappedTypeAsClauseRelationships, 2 FPs).
6. restTuplesFromContextualTypes:58:7 — the relation refuses
   `(...x: [number, ...T]) => void` vs `(x: number, ...args: T) => void`
   (assign/tuple_relate).
7. genericCallWithTupleType: out-of-range tuple index in WRITE position
   is `undefined` (expr.zig element-access assignment target).
8. `with` statement family (~10 cases): parse it; TS1101 (binder
   strict-mode) + TS2410 at [with-start, stmt.pos); tsc NEVER checks
   the body — decide drop-the-node vs skip flag (stmts.zig is C's).
9. isTypeMemberStart abort semantics (TS1131 + list abort → TS1128 on
   trailing brace).
10. abstract on the CONSTRUCT SIGNATURE, not the class decl (types.zig
    + typenode.zig).
11. computedPropertiesWithSetterAssignment: computed accessor pair makes
    the symbol .method; memberTypeOf's method arm wins over accessors.
12. Small: TS2345 message widens the argument literal ('number' vs
    '100'); TS1268/TS1337 in TYPE LITERALS; TS2313's companion codes
    (TS2365/TS2456); import defer type * recovery.
13. Census: 304 one-key cases (TS2322 32 under / 15 excess; capB35 has
    the full list); substitution types; resolution-mode attributes.

## Superseded queue (wave 35, kept for context)

1. TS2859 relation step budget (tsc's relationCount): ztsc has no code
   for "Excessive complexity comparing types" at all; relationComplexity
   Error sits at ~8.5s doing real work tsc cuts off. assign.zig owner.
2. Alias variance with CORRECTED semantics (A's probe data in its report,
   recorded here): needs ref(T,args) kept as the spelling for a
   NON-recursive generic alias — a materialize-vs-ref policy change
   (instantiate.zig) landing in variance.zig/assign.zig. 1 key today but
   the policy unlocks alias-printing fidelity broadly. Risky; own both
   files in one agent.
3. TS2313 (5 cases, reclassified): base-constraint resolution through
   MAPPED TYPES over recursive interfaces (`T extends { [P in T]:
   number }` reports on P; circularBaseTypes reports inside keyof T).
4. Mapped `as` over keyof array — two recorded blockers in mapped.zig:
   structural array TARGET (isAssignableInner's .array arm refuses
   non-list sources), then the number-key index signature rebuild
   (indexKeySurvives written, held back, no consumer).
5. Augmentation-only specifier must NOT resolve for imports (tsc TS2307):
   withhold the ambient-registry seed for augmentations; touches every
   `declare module` .d.ts in both apps — re-prove app diffs.
6. expr.zig fresh-literal widening divergence: a fresh literal's
   `{ d20: 12 }` member is STORED widened as number, which broke reading
   elaboration sources off src_t (B34 worked around by reading the
   winning declaration node).
7. template.zig: inline a template-typed span (tsc addSpans) so
   Uppercase<`${number}`> normalizes and the placeholder whitelist
   tightens.
8. Expando `this` / lazy expando members (blocks TS2786 + 2 more).
9. TS1099 residues need TS1326/TS1131; TS1268 needs the key type
   resolved (checker-side).
10. c1 keying perf: memo must key the whole alias_stack suffix (A's
    soundness analysis), or attack markCycle's O(depth) inserts.
11. Census: TS2322 excess/under pool; objectFreezeLiteralsDontWiden
    (Object.freeze const-ness); objectRestNegative (destructure);
    genericCallWithTupleType (out-of-range tuple index);
    typeParameterHasSelfAsConstraint; signatureCombiningRestParameters5;
    logicalAssignment6/7 (flow); substitution types; resolution-mode
    attributes.

## Superseded queue (wave 34, kept for context)

1. STANDING GRID FAILURE, needs an owner: excalidraw at --checkers=8 ×
   shuffle=1/2 has 6 order-dependent TS2339 keys in
   packages/excalidraw/data/transform.test.ts (374–376, 394–396).
   Pre-existing (reproduced byte-for-byte on wave-32's binary); checkers
   1/2/4 clean. Same investigation style as the closed social-app defect.
2. Full paramTypeAt union-rest distribution — blocked on the spread-call
   SOURCE side (calls.zig getSpreadArgumentType: a spread whose type is a
   union of tuples must contribute position-wise, not the whole element
   union). B33's contextual-only entry point is in; finishing needs the
   calls.zig half first.
3. Dynamic import('./missing') never reports TS2307 (3 cases) — dynamic-
   import specifiers never reach the link graph.
4. Tuple numeric properties: `[number[], string[]]` vs `{ 0:…; 1:… }`
   interface — relationSrcProp + tuple_relate helper; the suite witness
   arrayLiterals3 also needs expr.zig's spread-of-tuple-in-array-literal
   typed as a tuple.
5. TS1362→TS1361 blame ×5 (ztsc blames the `import type`, tsgo the
   `export type`; modvalue.zig).
6. Non-unit discriminant: tsc's findDiscriminantProperties is TARGET-
   driven — a string-typed source tag still reduces; ztsc's
   isUnitOrUnitUnion gate skips it.
7. TS2313 type-level walk (5 remaining cases: base-constraint recursion
   through unions/intersections/indexed accesses).
8. Expando `this` (blocks jsxComponentTypeErrors' TS2786): expandoFold is
   eager, typeOfSymbol's in-progress guard answers `any`; needs lazy
   expando members (same cycle blocks objectLiteralThisWidenedOnUse,
   looseThisTypeInFunctions:29).
9. Alias variance (1 key): needs alias identity kept on instantiations —
   instantiate.zig + types.zig + getAliasVariances; assign to an agent
   OWNING those files.
10. Union subtype reduction outside flow joins (`cond ? a : t` keeps the
    param; types.zig).
11. Small clusters: mapped `as` over keyof array; lastPropertyInLiteral
    Wins (elaborate: tsc elaborates at EVERY declaration node with the
    last-wins type); topFunctionTypeNotCallable (rest-argument tuple vs
    non-array rest); divergent accessor WRITE type (types.Prop needs a
    setter type — feature); TS1121 position ×4; TS1110→TS1005 ×3;
    TS2357→TS1109 ×3; bare `@` before enum TS1109;
    contravariantOnlyInferenceFromAnnotatedFunction (probe data recorded);
    coAndContraVariantInferences5 (union-to-union multi-match refusal).
12. c1 keying perf lead (memoize kept-ref resolution); substitution types;
    resolution-mode attributes; census TS2322 (34 under / 17 excess).

## Superseded queue (wave 33, kept for context)

1. genericFunctionInference1's last 10 keys, two roots: TS2448 FP on an
   AMBIENT `declare const` used before declaration (ambient decls have no
   TDZ; 3 corpus cases; names.zig) and f08's self-echo
   (`pipe(x => list(x), pipe(x => box(x)))` — the inner call echoes its
   own B into the outer candidate set).
2. social-app excess, 56 keys by family: TS2353 ×34 (ageAssurance —
   assign_report's union-target excess check must collect known props from
   ALL constituents, not one); TS2305 ×9 (expo-image-manipulator re-export
   chain, src/link); TS2339 ×4 (node:cluster `export { default as default
   }`, src/link); TS2345 ×4 (variadic tuple with infer, tuple_relate/
   conditions); TS7053 ×1 (jest it.each tuple inference).
3. Pick-pattern member materialization when the key set is concrete
   (inferMappedKeySet returns early on a non-type-param constraint, so
   A's distribution query never fires; complicatedIndexes… witness).
4. subtypeReductionUnionConstraints: assumeFalse must compute the
   true-branch type and SUBTRACT it (tsc: filterType(t =>
   !isTypeSubsetOf(t, trueType))) — per-constituent false-branching
   misses a bare type-param constituent; narrow.zig.
5. `this` inside a function expression assigned to an expando property
   has NO type at all (blocks jsxComponentTypeErrors' TS2786; a `const
   probe: string = this` there is silent where tsgo reports TS2322
   naming typeof FunctionComponent; expr/classes feature).
6. Scanner ID_Start/ID_Continue tables (5 TS1127-family cases: astral
   pairs, `¬`, `\u0031` leading).
7. Per-frame weak rule (weakType.ts:63): rel_intersection_target is
   checker-global where tsc's IntersectionState resets per property
   relation; save/zero/restore around structuralAssignable's
   isAssignable — but the relation memo key must carry the flag.
8. Alias variance: getAliasVariances + the aliasSymbol shortcut for
   alias INSTANTIATIONS (variance.zig only fires for .ref pairs;
   genericIndexedAccessVarianceComparisonResultCorrect).
9. Reverse-mapped array/tuple rebuild — BLOCKED: worth 2 corpus cases but
   takes social-app 87→93 (Composer.tsx useInfiniteQuery); the guard does
   not rescue it; handoff note at the switch in infer.zig.
10. c1 keying perf lead: memoize the kept-ref resolution per (sym,args)
    (the +3.2% c1 cost of 25d876f).
11. Small: reverseMappedPartiallyInferableTypes needs an `unknown`
    fallback for a refused param (TS18046 vs TS7006);
    invalidMultipleVariableDeclarations:54 is a class_value screen;
    narrowingUnionToUnion landed but re-check its family.
12. Census: TS2322 ~60 one-keys; TS1005/TS1109 residue; substitution
    types; resolution-mode attributes.

## Superseded queue (wave 32, kept for context)

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
