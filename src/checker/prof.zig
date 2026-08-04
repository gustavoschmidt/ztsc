//! Instantiation-demand profiler — a diagnostic instrument, off unless
//! `--inst-profile` is passed.
//!
//! It answers the question "where does a statement's instantiation budget
//! (`max_instantiation_count`) go?" along several independent axes:
//!
//!   * **call site** — the return address of each *top-level* `instantiate`
//!     entry, with the node-visits that entry charged. Symbolized at report
//!     time through `std.debug`, so the output names the `.zig` line that
//!     asked for the substitution.
//!   * **root type** — the type each top-level entry substituted into, so a
//!     single enormous re-instantiated shape is visible even when many
//!     different call sites ask for it.
//!   * **type kind** — `instantiateId` visits bucketed by `types.Kind`,
//!     which separates signature/constraint work from object-member work.
//!   * **expansion** — `expandRef` calls and their cost, per named symbol,
//!     which is where an interface's whole member table is materialized.
//!   * **one root, in isolation** — `--inst-focus=<type-id>` restricts the
//!     per-type histogram and the kind buckets to substitutions rooted at
//!     one type. A run-wide histogram answers "which subterm does this run
//!     re-walk most", which is the wrong question once a SINGLE top-level
//!     entry is itself the outlier; read the `#id` out of the `by root type`
//!     section and feed it back to break that entry down on its own.
//!
//! Plus a per-statement ledger of the statements that spent the most budget,
//! so a profile can be read against the statements that actually trip.
//!
//! Everything here is gated on `Checker.prof.on` (`--inst-profile`); with the
//! flag off the only cost is a predictable-false branch at the instrumentation
//! points. Output goes to stderr at `seal`, so run with `--checkers=1` to read
//! one profile rather than an interleave.
//!
//! ## What it has already established (immich / kysely, 2026-08-03)
//!
//! Repro: one kysely builder chain against immich's `DB`, 110 files pulled in
//! by its imports; `--checkers=1 --inst-profile`. 5.07 M node visits, 2.62 M
//! of them memo misses, 1,674 budget trips.
//!
//! * **Demand is spread, not concentrated.** `expandRef`'s
//!   `instantiate(interfaceGeneric, args)` is 52% (2.58 M over 4,004 calls),
//!   `instantiateSigForCall` 19%, `eraseParamsOf` 22%, `baseConstraintOf` 5%.
//!   No single call site is a keystone; a fix has to be structural.
//! * **The memo already catches the repeats — what is left is unique work.**
//!   59.5 k distinct types are instantiated under 120 k distinct substitution
//!   maps, 44 misses per distinct type. Better *caching* has nothing left to
//!   win; only doing less work does.
//! * **The expansions are forced by the relation and inference machinery,**
//!   not by member access: `isAssignableInner` (1.06 M), `paramAcceptsVoid`
//!   (485 k), `unify` (442 k), `inferFromExtendsInner` (413 k),
//!   `isArrayShaped` (361 k), `isGenericObjectForIndex` (324 k),
//!   `typeHasMapped` (310 k) — several of which expand a whole member table
//!   only to answer a yes/no structural predicate. Four of them no longer
//!   do (`refExpandsToObject`); what is left — `isAssignableInner`, `unify`,
//!   `inferFromExtendsInner`, `propertyTypeOf` — genuinely reads members.
//! * **A single signature instantiation can exceed the whole budget.**
//!   kysely's `QueryCreator.with<N, E>` costs 316,401 node visits for ONE
//!   `instantiateSigForCall`, against a 250,000 statement budget.
//!   `--inst-focus` on that entry showed it is NOT a runaway substitution of
//!   the signature: its own params and return type are references and cost
//!   nothing. It is the reductions the substitution triggers —
//!   `ExtractRowFromCommonTableExpression<E>` matching the callback's return
//!   against `Expression<infer QO>` and three builder interfaces — each of
//!   which calls `resolveStructural` and expands a whole kysely builder
//!   table, charged to the enclosing top-level entry because `expandRef`
//!   runs at `inst_depth > 0`. So the outlier is the SAME problem as the
//!   predicates, not a separate bug: ~1,400 expansions of two builder
//!   interfaces at ~1,500 visits each, under distinct argument lists.
//!   Its own histogram is a long flat tail (top subterm 1,583 visits of
//!   219 k), every visit a memo MISS under a distinct substitution map.
//!
//! ## Ruled out, with numbers (do not re-run these)
//!
//! * **Raising the budget.** At tsc's own constant (5 M instead of 250 k):
//!   41 s wall (from 3.5 s) and immich excess got WORSE, 498 -> 556, with
//!   TS7006 nearly doubling (108 -> 187). Excess is not monotone in the
//!   budget — the intermediate regime just moves which materializations come
//!   back truncated, and a lost contextual parameter type costs more
//!   diagnostics than a lost deep instantiation.
//! * **Lazy per-member instantiation of an interface reference** (tsc's
//!   `createInstantiatedSymbolTable`; read one member out of the memoized
//!   generic table and substitute only it, instead of expanding all ~50).
//!   Structurally correct and it does cut work (5.28 M -> 4.89 M visits, 315
//!   fewer expansions), but immich went 498 -> 567: it removes the
//!   *amortization* that `expansions` provides. Today one statement pays for
//!   a builder interface's whole table and every later statement reads it
//!   free; per-member, each statement pays for its own members, and any
//!   member whose substitution is truncated is never memoized at all, so it
//!   is re-paid and re-truncated forever.
//! * **The same laziness PAIRED with a per-`(ref, member)` memo** that
//!   restores the amortization at member granularity — one substitution per
//!   `(ref, member)` for the whole run, never published when the
//!   substitution truncated (the `inst_limit_tripped` subtree rule
//!   `eraseParamsOf` follows). It does cut work — immich wall 3.82 -> 3.58 s,
//!   peak RSS 1.59 -> 1.26 GB, the kysely repro 4.92 M -> 4.53 M node visits,
//!   `SelectQueryBuilder` expansions 694 -> 609 — and immich still went
//!   497 -> 566, the same magnitude and the same family (96 new TS7006) as
//!   the un-memoized attempt. **The memo was not the missing piece, and
//!   amortization was not the mechanism.**
//!
//!   The mechanism is BUDGET TIMING. An eager expansion at the member-access
//!   site runs EARLY in a source element, while `inst_count` is still low, so
//!   the table completes and is memoized complete for the rest of the run —
//!   the eager expansion is a cheap prepayment. Read one member instead and
//!   the element runs much deeper before anything forces the table; the first
//!   consumer that does force it is `isAssignableInner` / `unify` /
//!   `inferFromExtendsInner`, deep inside a walk with the budget nearly
//!   spent, so the table comes back TRUNCATED — and `expandRef` publishes
//!   that truncation as the answer for every later reader. Corroborating:
//!   per-symbol expansion cost RISES under laziness even as the count falls
//!   (`ZodObject` 230 calls / 241 k visits -> 221 / 332 k, max 8,379 ->
//!   32,296), because the eager table also warmed `inst_cache` for what the
//!   later consumers ask.
//!
//!   The 2x2 is measured, and today's cell is the best one on excess
//!   (immich excess / wall):
//!
//!   | | eager | lazy + memo |
//!   |---|---|---|
//!   | publish truncated (today) | **497 / 3.8 s** | 566 / 3.6 s |
//!   | withdraw truncated | 522 / 4.2 s | 530 / 4.3 s |
//!   | own budget epoch | 503 / 8.0 s | 501 / 7.2 s |
//!
//!   Routing the memo only from `propOfTypeEx` — the half of the earlier
//!   route bisect that read neutral — is a literal no-op: byte-identical
//!   visits (4,923,741) and an identical key set, because `isAssignableInner`
//!   resolves BOTH sides with `resolveStructural` before the property loop
//!   ever sees a `.ref`. Nothing is winnable on that route without changing
//!   the relation itself.
//!
//!   What would have to change first: the relation and inference sites must
//!   stop forcing whole tables, which is tsc's actual split (symbols eagerly,
//!   types lazily) and not reachable from member access. Member-access
//!   laziness alone reaches only `propertyTypeOf`'s share of the forcing
//!   sites — 1.14 M visits of 6.0 M charged, 12% of expansions — while
//!   `checkClass` (1.90 M / 118), `inferFromExtendsInner` (476 k + 160 k),
//!   `callbackSigOf` (454 k), `isAssignableInner` (383 k + 192 k + 135 k) and
//!   `unify` (350 k + 125 k) still expand.
//! * **A free-parameter Bloom summary + map-aware early-out, and narrowing
//!   the memo key to the relevant sub-map.** See the revert commit: 1.5% of
//!   visits and 498 -> 500 for the first; a 4x *increase* in distinct maps
//!   and 13% more misses for the second.
//! * **Refusing to memoize a TRUNCATED expansion** (`expandRef`), scoped to
//!   the budget epoch that truncated it so the element that paid still
//!   amortizes its own re-reads. Aimed at the cross-partition divergence,
//!   which it does dent (c1^c8 108 -> 83, c4^c8 34 -> 31, c1^c4 unchanged),
//!   but the causation runs the wrong way: the next reader re-expands, the
//!   re-expansion is charged to ITS budget, and more statements trip.
//!   immich 496 -> 522, wall 3.4 -> 4.2 s, and the 26 new keys are a
//!   truncation signature (TS2589 plus its TS7006/TS2769 cascade), not
//!   hidden diagnostics. See the revert commit.
//! * **Giving each `expandRef` its own budget epoch** — which DOES make the
//!   table a function of the ref (`enterSymFile`'s rule, one layer down) and
//!   is the right answer in principle. 503 excess but wall 3.4 -> 8.0 s and
//!   peak RSS 1.58 -> 2.66 GB; charging the cost back to the outer element
//!   on exit lands at 512 excess, 5.9 s, 1.96 GB. The extra time is real
//!   work: tables that used to come back truncated now complete.
//!
//!   Re-measured on top of the per-member memo above, which was supposed to
//!   be its precondition: 501 excess, 7.23 s, 2.51 GB. Laziness buys the
//!   epoch 10% of its wall and two keys — it is not the lever. Neither is
//!   BOUNDING the epoch: capping one table at 24,000 visits instead of the
//!   full 250,000 lands on the same 501 at 7.13 s / 1.90 GB, because the cost
//!   is not a few enormous tables but the many ordinary ones (1.5 k - 15 k
//!   visits each) that used to come back truncated. On the kysely repro the
//!   epoch simply doubles the work: 4.92 M -> 9.47 M node visits, budget
//!   trips 1,750 -> 18,104. Read the other way, ztsc's immich wall is today
//!   partly BOUGHT by truncation, and the epoch costs exactly what the
//!   truncation was saving.
//! * **The one `instantiateId` arm that turns the memo off for a whole
//!   subtree** (`cond_check_subst`, the second distribution rule, which
//!   re-walks the branches once per union constituent with `map_id = null`).
//!   A plausible-looking suspect for the `with<N, E>` outlier, and the
//!   counter in the report header ruled it out: 32 k of 5.23 M visits.
//!
//! ## What LANDED: the lazy member layer (`lazyShapeOf` / `lazyTableOf`)
//!
//! The negatives above were all measured on the kysely mini-repro, where
//! `expandRef` is 52% of the demand and the forcing sites are the relation and
//! inference walks. Profiled on the WHOLE immich server package the ranking is
//! different, and the answer was in the part of the split the earlier attempts
//! never reached — the consumers that materialize a member table and then read
//! nothing off it but NAMES:
//!
//!     keyofType           8.08 M visits / 184 calls
//!     propertyTypeOf      3.36 M / 1,962
//!     expandRef itself    2.47 M / 8,324
//!     isCallableSource    1.57 M / 1,324
//!     callbackSigOf       1.12 M / 238
//!
//! `instantiateId`'s `.object` arm substitutes `Prop.ty` and copies
//! `Prop.name` and `Prop.flags` through untouched, so a member table's names,
//! optionality, readonly-ness, `private`/`protected`-ness, property COUNT and
//! index-signature PRESENCE are all functions of the generic table alone.
//! Every question above is answerable off it: `keyof` enumerates names,
//! `isWeakType` asks whether every property is optional, `isCallableSource`
//! and `callbackSigOf` ask whether the shape has properties. Converting those
//! five took immich 461 -> 458 excess with total node visits 11.99 M ->
//! 10.55 M (-12%), budget trips 12,501 -> 11,095, user CPU 12.4 s -> 11.0 s
//! and peak RSS 1.83 -> 1.81 GB, with excalidraw still CONVERGED at 17/0/0 and
//! parity 8/8 at 0/0.
//!
//! Signature counts are the one thing that does NOT carry through
//! (`higherOrderSigEligible` drops a higher-order signature the substitution
//! cannot rewrite), so a table that has any stays on the eager path.
//!
//! **The load-bearing rule, and it is not obvious: the lazy route may READ a
//! generic member table but must never BUILD one.** Materializing a table is
//! not a pure function of the symbol — it runs the declaration walk under
//! `enterSymFile`, folds `extends` bases, resolves every member's annotation
//! and can re-enter the very reference being asked about — and `expandRef`
//! marks `expansions[ref]` in progress before it starts, so a table built from
//! anywhere else is built outside that mark. Hoisting the construction into
//! `keyofType` alone (nothing else changed, the key set it computed was
//! byte-identical every time) took the excalidraw sweep from 17 diagnostics to
//! 279. Reading a table an earlier `expandRef` already built has no such
//! effect, and it is the case that pays: a generic interface is materialized
//! once and read thousands of times.
//!
//! Two more sites then fell to `refExpandsToObject` — `isAssignableInner`'s
//! ref-source/union-target arm and `typeParamAtTopLevel`, both of which
//! resolved a reference only to ask its KIND — taking immich to 453 excess
//! and peak RSS to 1.53 GB, with budget trips 11,095 -> 5,113.
//!
//! ### The negative that RE-CONFIRMED under the new rule
//!
//! `propertyTypeOf` routed through `lazyTableOf`/`lazyPropNamed` (one member
//! substituted per access, miss falls through to the eager path) is still a
//! large regression: **immich 453 -> 522**, even though it is the cheapest
//! configuration ever measured on this corpus (wall 3.57 s, peak RSS 1.34 GB,
//! user CPU 9.3 s). The mechanism is the one this header already describes and
//! it is now sharply delimited:
//!
//!   * laziness that needs NO member type at all — `keyof`, `isWeakType`,
//!     `isCallableSource` — is free, because the whole-table substitution it
//!     skips was never going to be read through that route;
//!   * laziness that substitutes ONE member instead of the table is a LOSS,
//!     because the table it skipped was prepaying for every later reader of
//!     that reference while the budget was still low, and the single member it
//!     does substitute is computed deep in a spent budget and comes back
//!     truncated.
//!
//! So the rule for this layer is: **read the table's symbols freely; think
//! twice before substituting one member in place of the table.** The relation
//! walk (`lazyRefRelate`) is the case where the second half is still right,
//! because its short circuits substitute NEITHER side.
//!
//! ### Where immich's remaining demand is
//!
//! `expandRef` by symbol, at 453 excess, is two distinct populations:
//!
//!     2,512,058 visits  1,471 calls    8,410 max  SelectQueryBuilder
//!     1,155,418 visits      1 calls  1,155,418 max  SearchRepository
//!       888,397 visits      1 calls    888,397 max  AssetRepository
//!       797,005 visits      1 calls    797,005 max  AssetJobRepository
//!       725,896 visits    151 calls     15,647 max  InsertQueryBuilder
//!       589,935 visits      1 calls    589,935 max  SharedLinkRepository
//!
//! The kysely builders are many substitutions of one memoized generic table —
//! `lazyTableOf`'s target, reached only through the relation and inference
//! walks, and today `lazyRefRelate` declines most of them because a kysely
//! builder's members mention `this` (the guard that keeps `relate`'s
//! `substThis` step faithful). Making the lazy route `this`-aware is the next
//! step for that half.
//!
//! immich's OWN repository classes are the other half and a different problem:
//! ONE `classInstanceGeneric` each, at half a million to a million visits,
//! spread across many statements' budgets (the table is built member by member
//! as `checkClass` walks, so no single trip bounds it) and memoized per symbol
//! for the rest of the run. Nothing in this layer touches them.
//!
//! Still eager, in demand order at 453: `keyofType` (6.74 M / 155),
//! `propertyTypeOf` (3.44 M, see above), `expandRef` itself (1.92 M),
//! `eraseParamsOf` (674 k + 194 k), `isAssignableInner`'s ref arm (587 k +
//! 180 k), `inferFromExtendsInner` (504 k + 191 k), `unify` (464 k + 401 k),
//! `isArrayShaped` (322 k).
//!
//! ### The layer is saturated — measured, not assumed
//!
//! `--lazy-stats` tallies why the relation's lazy route declines a pair. Over
//! immich's 53,000 entries into `isAssignableInner`'s `.ref` arm:
//!
//!     hit                      63
//!     tbl_not_nominal      27,540   target is an ALIAS reference
//!     tbl_already_expanded 14,271   the expansion is already memoized
//!     tgt_not_ref          10,889
//!     same_symbol             419   the variance question
//!     src_kind                137
//!     this_types                5
//!
//! Nothing here is widenable. An alias body REDUCES when instantiated, so it
//! has no fixed member table; an already-memoized expansion costs a hash
//! lookup. The `this`-type guard — the obvious suspect, since kysely's
//! builders are written with `this` — declines **five** pairs in the whole
//! package, so making the lazy view `this`-aware would buy nothing.
//!
//! kysely's `SelectQueryBuilder` (2.51 M visits over 1,471 expansions) is not
//! reached through the relation at all. The builder chain's first touch of
//! each fresh reference is a property ACCESS, so those expansions belong to
//! `propertyTypeOf` — the one route this layer measured as a loss, twice.
//!
//! Three further closures, all re-measured on top of the 453 baseline:
//!
//! * **`propertyTypeOf` with a truncation FALLBACK.** The theory was that a
//!   member substituted under a spent budget is never memoized, so it
//!   re-truncates forever; falling back to `expandRef` (which memoizes
//!   whatever it gets) makes the route's cost monotone. It does — and immich
//!   still went 453 -> **523**, the same 95-new-TS7006 signature. The fallback
//!   is kept, because it is the right invariant, but it is not the mechanism.
//! * **An oracle leg comparing every lazily-substituted member against the one
//!   the expansion holds** settled what the mechanism is NOT: over the whole
//!   package there are 126 differences, 125 of them `Assertion.resolves` where
//!   the EAGER expansion truncated to `any` and the lazy member is the more
//!   precise type, and exactly one on a builder (`SelectQueryBuilder.where`).
//!   On the kysely path the two routes compute **the same TypeId** for the
//!   same member — the map is the same, `canonMapId` gives the same `map_id`,
//!   and both hit the same `inst_cache` entry. So the 95 lost contextual
//!   parameter types are caused by the ABSENCE of the whole-table expansion,
//!   not by any member's value: the expansion was warming `inst_cache` and
//!   `expansions` for the call machinery that contextually types the callback
//!   two frames later.
//! * **The `expandRef`-own-budget-epoch closer, re-measured** now that demand
//!   has dropped (visits 11.99 M -> 10.01 M, budget trips 12,501 -> 5,113):
//!   453 -> **467 excess, wall 3.2 -> 5.8 s, peak RSS 1.53 -> 2.74 GB**. The
//!   40% fall in trips did not make it affordable, and it is now measured from
//!   three different baselines with the same verdict.
//!
//! What is left is a different problem from this layer's. `keyofType`'s
//! remaining 6.74 M over 155 calls is `keyof <immich repository class>` —
//! `WorkflowRepository`, `SearchRepository`, `AssetRepository`, one call each
//! — and those classes declare no type parameters, so `expandRef` substitutes
//! nothing: the entire cost is `classInstanceGeneric` resolving a hundred
//! kysely-typed method signatures. Nothing is saved by deferring it (the class
//! is checked anyway, so the table is built either way); only WHERE the cost
//! is charged moves, which is the same budget-timing coin every negative above
//! landed on.
//!
//! ## The budget-timing coin, closed (2026-08-04)
//!
//! The whole family above rests on one premise — that a statement is charged
//! for the declaration materializations it happens to be the first to demand,
//! so moving the charge moves the truncations. **The premise is false, and
//! `-- budget trips by the declaration frame that was live --` is the axis
//! that settled it.** `restoreCtx` puts `inst_count` back unconditionally, so
//! EVERY `enterSymFile` window — same-file as much as cross-file — already
//! rolls its cost off the requester's budget. `enterSymFile`'s reset only
//! decides where the window STARTS, not who pays for it.
//!
//! Measured on immich (`--checkers=1`; baseline 453 excess, 3.3 s, 1.57 GB,
//! 10,007,576 visits, 5,290 trips; c1/c4/c8 = 540/453/487, divergence
//! 121/107/52):
//!
//! * **Own budget epoch for the run-once per-symbol table construction**
//!   (`interfaceGeneric` + `classInstanceGeneric` reset `inst_count` instead
//!   of inheriting it — the assigned design): a **literal no-op**. Identical
//!   key set at c1/c4/c8, identical 10,007,576 visits, identical 5,290 trips.
//!   A tally of each construction's own-window charge says why: over the whole
//!   package the constructions charge **4,537 node visits in total**, and
//!   immich's repository classes charge **zero** — `SearchRepository`'s
//!   1,154,502 visits all happen inside nested declaration windows that reset
//!   and restore around them. Nobody was ever being charged for them.
//! * **Where the trips actually are.** 3,916 of 5,290 fire inside a table
//!   construction, but attributed to the innermost declaration frame they are
//!   individual MEMBERS: `query` 576, `streamForSearchDuplicates` 396,
//!   `searchAssetBuilder` 354, `get` 282, `getForVideoConversion` 264,
//!   `getSharedLinks` 229 — each one a single immich repository method whose
//!   own materialization exceeds 250,000 node visits starting from ZERO. The
//!   remaining 2,335 are a source element's own budget. It is a CEILING
//!   problem per declaration, not a charging problem.
//! * **A fresh window for every declaration frame** (`enterSymFile` resets
//!   unconditionally, not only across files): 453 -> **452**, wall 3.3 ->
//!   3.9 s, RSS 1.57 -> 1.59 GB, and 23 keys lost for 22 new. Noise.
//! * **A raised ceiling scoped to the construction's whole dynamic extent**
//!   (a dynamic `inst_budget` the guard reads, set on entry to a per-symbol
//!   table build, restored with the context — the "generous ceiling" the
//!   design asked for): 250 k -> 1 M gives **454 excess, 6.8 s, 2.09 GB**;
//!   250 k -> 5 M gives **452 excess, 28.7 s, 4.14 GB** (44 keys lost, 43
//!   new). Excess is FLAT across a 20x ceiling while wall grows 8.6x and RSS
//!   2.6x.
//!
//! The last row is the one that matters beyond this experiment, and its key
//! diff says exactly what a bigger budget buys and what it costs. At 5 M the
//! keys that DISAPPEAR are a clean truncation-cascade signature — 26 TS7006,
//! 7 TS2589, 7 TS2554, 3 TS2769, 1 TS2345 — so truncation really is producing
//! some of immich's excess. But 43 others APPEAR in their place: 13 TS2769,
//! 7 TS2589, 7 TS2339, 6 TS7006, 5 TS2554, 5 TS2345. Letting the work complete
//! trades one cascade for an equal amount of divergence that truncation was
//! hiding, and the seven fresh TS2589 say the deeper walk simply trips
//! somewhere else.
//!
//! So **the budget cannot be the lever on immich's 453** — not through who is
//! charged, not through how high the ceiling is. The truncation-attributable
//! share is real but ~40 keys, not ~390, and it is only reachable by making
//! those repository members CHEAPER (each costs > 250,000 node visits alone),
//! not by letting them cost more. The 43 keys that surface underneath are the
//! population the next hypothesis should come from: run at the 5 M table
//! ceiling, take the keys that only exist there, and compare those members'
//! completed types against tsgo's. All of the above is reverted; only the
//! trip-by-frame profiler axis was kept.
//!
//! ## The POLARITY axis, and the cascade claim it disproves (2026-08-04)
//!
//! A different axis from the two above: not who is charged and not how high
//! the ceiling is, but WHERE a trip is allowed to be a user-facing error.
//! tsc's separation is by position — `instantiateType`'s guard reports
//! TS2589 at the checking level, while `recursiveTypeRelatedTo` answers
//! `Ternary.Maybe` for the same recursion detected inside the relation, with
//! no diagnostic. ztsc reported at both. `Checker.instDiagAllowed` now
//! withdraws the report while `rel_depth > 0`; the truncation itself is
//! unchanged (see that function for why it is harmless there).
//!
//! **The change is right and it is small.** immich 222 -> 221 excess, wall
//! 3.69 -> 3.67 s, peak RSS 1.885 -> 1.941 GB, every gate unchanged. The
//! isolated pair it was found on — immich's
//! `ExpressionBuilder<DB & {sharedBy: UserTable}, 'partner'|'sharedBy'>`
//! against `ExpressionBuilder<DB, 'partner'>`, tsgo clean — goes clean.
//!
//! **The cascade claim attached to it is false, and this is the number to
//! remember.** The hypothesis was that ~70% of immich's 222 (TS7006 87,
//! TS2769 43, TS2554 19, TS2589 10) descends from relation-internal trips,
//! so a policy that stopped them from poisoning a statement would take the
//! excess with it. Measured on the whole package, at the 222 baseline:
//!
//!   * `max_instantiation_count` 250 k -> 3 M: 221 -> **216**, wall 4.0 ->
//!     21.0 s, RSS 2.05 -> 2.90 GB. TS7006 87 -> 75 but TS2769 43 -> **53**:
//!     the same one-cascade-for-another trade the 5 M row above records.
//!   * `max_instantiation_depth` 100 -> 400 (count held at 250 k):
//!     **byte-identical 221**. Depth is not binding on this corpus at all.
//!
//! So the guards together account for **6 of 222 keys (2.7%)**, not ~155.
//! Direct evidence for where the rest is: `--inst-profile` says only SEVEN
//! statements in the package reach the 250 k cap, and `getById` in
//! `asset.repository.ts` — which alone carries 42 of the 87 TS7006 — is not
//! one of them, spending under 13 k visits. Its cluster is rooted in a
//! genuine overload divergence upstream — `src/utils/database.ts:119`,
//! `withExif`'s `.select(selectExifInfo)` — which strips the contextual type
//! off every `$if`/`$call` callback downstream of it. It isolates to fifteen
//! self-contained lines (immich's `node_modules` + `src/schema`, nothing
//! else): declare
//!
//!     type AssetExpressionBuilder = ExpressionBuilder<DB, 'asset' | 'asset_exif'>;
//!     const selectExifInfo = (eb: AssetExpressionBuilder) =>
//!       eb.fn.toJson(eb.table('asset_exif'))
//!         .$castTo<ShallowDehydrateObject<Selectable<AssetExifTable>> | null>()
//!         .as('exifInfo');
//!     export function withExif<O>(qb: SelectQueryBuilder<DB, 'asset', O>) {
//!       return qb.leftJoin('asset_exif', 'asset.id', 'asset_exif.assetId')
//!         .select(selectExifInfo);
//!     }
//!
//! and ztsc raises TS2769 on the `.select(…)` where tsgo is clean.
//!
//! ## That TS2769, traced and FIXED (2026-08-04)
//!
//! It is a call-resolution divergence, and the budget is in it after all —
//! not as a ceiling but as a RESOURCE ONE CANDIDATE TAKES FROM THE NEXT.
//! `--checkers=1` resolves the call and `--checkers=4` does not, which is the
//! tell: the answer depended on how much of the statement's 250,000-node
//! budget was already spent when the call was reached.
//!
//! kysely's `select` has three overloads. The FIRST —
//! `select(selections: ReadonlyArray<SE extends SelectExpression<DB, TB>>)`,
//! whose constraint is a union over every column of every table — spends
//! 240,000 nodes probing the callback argument it then DECLINES (11,162 ->
//! 250,001 on `inst_count`). `select(callback: CB)`, the overload tsc picks,
//! then instantiated to `error_type`, read back through the `fn*` accessors
//! as arity 0, and was rejected without ever being compared. So did the
//! third, and the call fell out TS2769.
//!
//! `resolveSignatureCall` already treats a rejected candidate's inference as
//! speculative (`rollbackArgDiags`); its BUDGET was not. It now refunds
//! `inst_count` and `inst_limit_tripped` on both `continue` paths — the
//! accepted candidate keeps its charge. immich **221 -> 190** (46 keys gone:
//! 20 TS2769, 13 TS7006, 4 TS2551, 3 TS2554, 3 TS2345, 2 TS2339, 1 TS2589;
//! `album.repository.ts` alone 14 -> 5), 15 new, 0 under, wall 3.65 ->
//! 4.22 s, peak RSS 1.90 -> 1.95 GB. Pinned by conformance
//! `calls/058_rejected_overload_refunds_budget`, which reproduces the whole
//! shape in 30 lib-free lines with no kysely: a wide template-literal
//! constraint whose mapped return costs more than the budget, an overload
//! set, and a callback argument.
//!
//! The 15 new keys are ONE downstream family (TS2339 on `album.albumUsers`
//! and friends): those calls now resolve, and resolve to an overload whose
//! `Selection<…>` drops the aliased property, so the property is missing
//! rather than `any`. That is the successor item — a `Selection<…>` /
//! `ExtractAliasFromSelectExpression` evaluation question, not this one.
//!
//! A second site of the same polarity error, found on the way and fixed with
//! it: `signatureAssignableModeInner` erases both signatures' type parameters
//! to their constraints, which runs `instantiate` and can also come back
//! `error_type`; every step below then read a non-function and the pair fell
//! out "not related". A truncation inside the relation is `Ternary.Maybe`
//! (`instDiagAllowed`'s rule), so it now assumes related. **No synthetic
//! fixture reproduces this half** — the erasure is memoized at the
//! declaration, so a hand-written case never meets it with a spent budget;
//! four were tried (a `Box<T>` pair with ten heavy generic methods, the same
//! under distinct symbols to defeat the variance short-circuit, a heavy
//! accepted call in the same statement, and a knife-edge burn tuned to stop
//! just under the cap). It is pinned by the fifteen-line immich repro above,
//! which needs it: with the refund alone that file still reports the TS2769
//! plus a TS2322 on
//! `ExpressionBuilder<LeftJoin<DB,'asset_exif'>, TB> -> ExpressionBuilder<DB, TB>`,
//! and with both it is byte-clean against tsgo.
//!
//! **immich's TS7006/TS2769 population is a call-resolution problem, not an
//! instantiation-budget ceiling one**; the ceiling family of hypotheses is
//! closed from three independent directions.
//!
//! No synthetic conformance fixture reproduces the relation-internal trip.
//! Seven were tried — branching builders, recursive mapped aliases, wide
//! union fan-outs, a hand-written kysely-shaped builder pair with 30 tables,
//! and the same pair under distinct symbols to defeat the variance
//! short-circuit — and every one closes in a few thousand node visits with
//! zero trips, because `relIdDeeplyNested` and the relation memo do cut
//! ordinary recursive shapes. What makes the kysely pair escape is that the
//! refs on its spine DECREASE (the deeper frames meet declarations interned
//! earlier), and the growth test counts only strictly later instantiations.
//! That is an interning-order property, not a shape property, so the
//! checking-level half of the boundary is pinned by conformance
//! instantiation/002 and the relation half by the immich app gate.
//!
//! ## The successor family, traced: a truncation is not an arity (2026-08-04)
//!
//! The 15 keys the budget refund left behind were read as a `Selection<…>` /
//! `ExtractAliasFromSelectExpression` evaluation bug — the chosen overload's
//! output dropping an aliased property. **It is not an evaluation bug at all.**
//! Bisecting immich's `album.repository.ts` chain link by link (a scratch
//! project whose `paths` maps `src/*` at the app, plus a `node_modules`
//! symlink so kysely resolves) isolates it to `withAssets`, and from there to
//! ten lines with no immich types in them:
//!
//!     function withDefaultVisibility<O>(qb: SelectQueryBuilder<DB,'asset',O>) {
//!       return qb.where('asset.deletedAt', 'is', null);
//!     }
//!     const m = (eb: ExpressionBuilder<DB, 'album'>) =>
//!       eb.selectFrom((eb) =>
//!         eb.selectFrom('asset').selectAll('asset')
//!           .$call(withDefaultVisibility).as('asset'));
//!
//! ztsc reported TS2554 **"Expected 0 arguments, but got 1"** on a call to
//! `ExpressionBuilder.selectFrom`, which has ONE signature taking ONE
//! parameter. `instantiateId`'s depth/count guard fires *before* its
//! `.function` arm runs and returns `error_type` for the whole signature, and
//! every `fn*` accessor reads that as a signature of arity ZERO. tsc cannot
//! reach that state: `instantiateSignature` clones the signature and
//! instantiates each parameter and the return type independently, so a limit
//! hit degrades a COMPONENT while the shape always survives.
//!
//! `checkCallArguments` now withdraws the arity claim when the signature it
//! was handed is not a function. **immich 190 -> 174, all 16 TS2554 gone, 0
//! new keys**, wall 4.52 -> 4.22 s, peak RSS flat.
//!
//! The obvious stronger fix is a REGRESSION, and the number is worth keeping:
//! rebuilding the shape instead — arity preserved, every component
//! `error_type` — gives **190 -> 194 with TS7006 74 -> 107**, because an
//! `error_type` parameter then overwrites each callback argument's contextual
//! type with one that types its parameters `any`. Leaving the type
//! `error_type` is also what keeps a truncated statement cheap: `error_type`
//! is a suppressing type and short-circuits the rest of the walk. And
//! re-substituting the components rather than setting them to `error_type` is
//! worse still — each re-entry into `instantiate` restarts at `inst_depth` 0
//! with an empty `inst_chain`, so a DEPTH-guard truncation re-walks the whole
//! subterm once per parameter: 10x wall and 2.2x peak RSS on immich.
//!
//! No oracle-faithful synthetic fixture exists for this one. The bug needs a
//! real truncation, and ztsc reports TS2589 where tsc — with 20x the budget —
//! is clean, so any snapshot would carry a `+` entry with no matching
//! diagnostic, which DEFERRED's policy does not admit. Four shapes were tried
//! (a 1,000-member and a 10,000-member template-literal constraint whose
//! mapped return exceeds the budget, with the burn in a nested call and in a
//! relation; tsc completes all four). It is pinned by the immich app gate.
//! The 13-line synthetic that DOES reproduce it against a stock ztsc, for
//! bisecting a regression by hand:
//!
//!     type D = '0'|'1'|'2'|'3'|'4'|'5'|'6'|'7'|'8'|'9';
//!     type W = `${D}${D}${D}`;
//!     type Cross<K,U> = U extends string
//!       ? `${K & string}.${U}` | `${U}.${K & string}` : never;
//!     interface Builder<O> {
//!       pick<S extends W>(cb: (b: Builder<O>) => unknown):
//!         Builder<O & { [K in S]: Cross<K, W> }>;
//!       burn<S extends W>(): Builder<O & { [K in S]: Cross<K, W> }>;
//!     }
//!     declare const qb: Builder<{}>;
//!     export const out = qb.pick((b: Builder<{}>) => b.burn());
//!
//! ### What the same bisect settled about the rest of the album family
//!
//! * The `Selection<…>` machinery is **correct in isolation**, and so is the
//!   curried `withAlbumUsers(authUserId)` factory: `ExtractAliasFromSelect
//!   Expression` extracts `'albumUsers'` from both the factory and its return,
//!   and the mapped-type form computes `{ albumUsers: 1 }`, byte-identical to
//!   tsgo. So does the whole `.with(cte)/.selectFrom/.selectAll/.where/
//!   .select(withAlbumUsers(…))/.select(withSharedLink)/.$if(…)` chain when it
//!   is the only thing in the file.
//! * What is lost in the full app is lost to BUDGET ORDER, not to the alias
//!   remap: the same chain drops `albumUsers` or keeps it depending on what
//!   was checked before it in the same file. `--checkers=1` and `--checkers=4`
//!   still disagree on 60 of immich's keys, which is the same coin.
//! * The one deterministic member of the family, reproducible in a 4-file
//!   program, is `assets` — and it descends from `withAssets`, i.e. from the
//!   TS2554 above.
//!
//! ### A self-contained repro of the underlying truncation, with no immich
//!
//! The same ten-line `selectFrom((eb) => … .$call(…))` shape against a
//! SYNTHETIC `DB` trips the budget at 67 tables x 17 columns and is clean at
//! 12 x 8 — kysely alone, no immich types, ~430 k node visits of which the one
//! statement spends the full 250,001. That is the cheapest handle anyone has
//! on the remaining TS7006 population, because it profiles with a single file
//! in the program instead of 627.
//!
//! ## Two enum divergences, unrelated to the budget (2026-08-04)
//!
//! Found and fixed while bisecting immich's `src/utils/sync.ts:34`, both
//! independent of everything above and both oracle-pinned in
//! `test/conformance/enums`:
//!
//! * **A type parameter constrained to an enum was not assignable to that
//!   enum.** `isAssignableInner`'s arms are written on type KINDS and the
//!   nominal enum arm came before the type-parameter arm, so `<T extends E>`
//!   — a `.type_param` — was handed to `enumAssignable`, which saw a non-enum
//!   source and rejected it. `<T extends E>(t: T): E => t` was TS2322.
//! * **A member declared with a computed enum-member key lost the enum.** A
//!   member table keys by atom and an enum member's atom is its VALUE, so
//!   `keyof { [E.A]: T }` came back `'AV1'` and not `E.A`. tsc keeps the enum
//!   literal as `symbol.links.nameType`; `Checker.key_name_types` keeps it in
//!   a side table against the interned object, leaving the member layout
//!   alone.
//!
//! Both are needed for the immich site and each was measured alone to confirm
//! it: (1) alone leaves every `keyof` case failing, (2) alone leaves every
//! constraint case failing. immich 174 -> 173, no other key moved.

const std = @import("std");
const types = @import("../types.zig");
const binder = @import("../frontend/binder.zig");

const checker_zig = @import("../checker.zig");
const Checker = checker_zig.Checker;
const Error = checker_zig.Error;
const TypeId = types.TypeId;
const SymbolId = binder.SymbolId;
const FileId = u32;

/// Process-global switch, set once by `main` from `--inst-profile` before any
/// checker thread starts, and read once per `Checker.init`. Write-once before
/// the pool spawns, so no synchronization is needed.
pub var profile_on: bool = false;

/// `--inst-focus=<type-id>`: the ONE root type whose substitution the
/// per-type histogram should be restricted to. The unrestricted histogram
/// answers "which subterm does this run re-walk most", which a run-wide sum
/// answers badly when one top-level entry is itself the outlier — read a
/// root's id out of the `by root type` section and feed it back here to get
/// that entry's own breakdown. Write-once alongside `profile_on`.
pub var focus_root: TypeId = 0;

/// Whether the profiler is enabled for this process.
pub fn enabled() bool {
    return profile_on;
}

const Tally = struct {
    calls: u64 = 0,
    visits: u64 = 0,
    max_visits: u64 = 0,

    fn add(t: *Tally, v: u64) void {
        t.calls += 1;
        t.visits += v;
        if (v > t.max_visits) t.max_visits = v;
    }
};

const Stmt = struct {
    file: FileId,
    /// Byte offset of the statement's start (rendered as line:col).
    pos: u32,
    count: u64,
};

pub const InstProf = struct {
    on: bool = false,
    /// Return address of a top-level `instantiate` -> work charged.
    sites: std.AutoHashMapUnmanaged(usize, Tally) = .empty,
    /// Root type of a top-level `instantiate` -> work charged.
    roots: std.AutoHashMapUnmanaged(TypeId, Tally) = .empty,
    /// `expandRef` by named symbol -> work charged.
    expands: std.AutoHashMapUnmanaged(SymbolId, Tally) = .empty,
    /// `resolveStructural` call sites that actually forced an expansion.
    expand_sites: std.AutoHashMapUnmanaged(usize, Tally) = .empty,
    /// Every `instantiateId` node visit, by the type visited. Names the
    /// individual subterm a runaway substitution keeps re-walking.
    per_type: std.AutoHashMapUnmanaged(TypeId, Tally) = .empty,
    /// `instantiateId` node visits by `types.Kind`.
    kinds: [256]u64 = @splat(0),
    /// Node visits that were served by the memo, by kind (the cache's win).
    kind_hits: [256]u64 = @splat(0),
    /// The costliest statements seen, kept unsorted and truncated at report.
    stmts: std.ArrayListUnmanaged(Stmt) = .empty,
    /// Statements whose budget actually tripped.
    tripped: u64 = 0,
    /// Budget trips by the symbol whose declaration materialization owned the
    /// live budget window (`Checker.epoch_sym`; 0 = a source element's own).
    /// The trip's TS2589 is anchored at the demanding statement, which is a
    /// different thing entirely — this is the frame that spent the budget.
    trip_epochs: std.AutoHashMapUnmanaged(SymbolId, Tally) = .empty,
    /// Non-zero while a top-level `instantiate` of `focus_root` is live —
    /// see `focus_root`. Nested so a re-entrant focused root still counts.
    focus_depth: u32 = 0,
    /// `per_type`, restricted to visits charged under `focus_root`. The
    /// unrestricted histogram sums a whole run and cannot say which subterm
    /// ONE enormous substitution walked; this one can.
    focus_types: std.AutoHashMapUnmanaged(TypeId, Tally) = .empty,
    /// `kinds`, restricted the same way.
    focus_kinds: [256]u64 = @splat(0),
    /// Node visits made while a `cond_check_subst` rebinding is live — i.e.
    /// under the one arm of `instantiateId` that turns the memo off for a
    /// whole subtree, and re-walks it once per union constituent.
    cond_subst_visits: u64 = 0,
    /// Union constituents distributed through that arm.
    cond_subst_laps: u64 = 0,

    pub fn deinit(p: *InstProf, gpa: std.mem.Allocator) void {
        p.sites.deinit(gpa);
        p.roots.deinit(gpa);
        p.expands.deinit(gpa);
        p.expand_sites.deinit(gpa);
        p.trip_epochs.deinit(gpa);
        p.per_type.deinit(gpa);
        p.focus_types.deinit(gpa);
        p.stmts.deinit(gpa);
    }
};

/// Charge one top-level `instantiate` of `t` costing `visits` node visits to
/// the call site `ret_addr`.
pub fn noteTopLevel(c: *Checker, ret_addr: usize, t: TypeId, visits: u64) void {
    const gpa = c.gpa;
    if (c.prof.sites.getOrPut(gpa, ret_addr)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
    if (c.prof.roots.getOrPut(gpa, t)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Charge one `instantiateId` node visit to the type visited.
pub fn noteVisit(c: *Checker, t: TypeId) void {
    if (c.cond_check_subst != null) c.prof.cond_subst_visits += 1;
    if (c.prof.per_type.getOrPut(c.gpa, t)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(1);
    } else |_| {}
    if (c.prof.focus_depth > 0) {
        c.prof.focus_kinds[@intFromEnum(c.ts.kind(t))] += 1;
        if (c.prof.focus_types.getOrPut(c.gpa, t)) |gop| {
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.add(1);
        } else |_| {}
    }
}

/// Open/close a focus window around a top-level `instantiate` (see
/// `focus_root`). Returns whether this entry opened one.
pub fn focusEnter(c: *Checker, t: TypeId) bool {
    if (focus_root == 0 or t != focus_root) return false;
    c.prof.focus_depth += 1;
    return true;
}

pub fn focusExit(c: *Checker) void {
    c.prof.focus_depth -= 1;
}

/// Charge one `resolveStructural` that forced an expansion to its call site.
pub fn noteExpandSite(c: *Checker, ret_addr: usize, visits: u64) void {
    if (c.prof.expand_sites.getOrPut(c.gpa, ret_addr)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Charge one budget trip to the declaration frame that was live when it
/// fired (`Checker.epoch_sym`).
pub fn noteTrip(c: *Checker) void {
    if (c.prof.trip_epochs.getOrPut(c.gpa, c.epoch_sym)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(1);
    } else |_| {}
}

/// Charge one `expandRef` of a `sym`-rooted reference costing `visits`.
pub fn noteExpand(c: *Checker, sym: SymbolId, visits: u64) void {
    if (c.prof.expands.getOrPut(c.gpa, sym)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(visits);
    } else |_| {}
}

/// Record the budget one statement spent (called at the next statement's
/// reset, so the count is final).
pub fn noteStatement(c: *Checker, file: FileId, pos: u32, count: u64) void {
    if (count < 1000) return; // noise floor
    c.prof.stmts.append(c.gpa, .{ .file = file, .pos = pos, .count = count }) catch {};
}

fn lineCol(src: []const u8, pos: u32) struct { u32, u32 } {
    var line: u32 = 1;
    var last_nl: u32 = 0;
    var i: u32 = 0;
    const end = @min(pos, @as(u32, @intCast(src.len)));
    while (i < end) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            last_nl = i + 1;
        }
    }
    return .{ line, end - last_nl + 1 };
}

fn byVisits(comptime K: type) type {
    return struct {
        key: K,
        t: Tally,
        fn desc(_: void, a: @This(), b: @This()) bool {
            return a.t.visits > b.t.visits;
        }
    };
}

fn dumpTally(
    comptime K: type,
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    map: *const std.AutoHashMapUnmanaged(K, Tally),
    limit: usize,
    label: fn (*Checker, K, *std.Io.Writer) void,
    c: *Checker,
) !void {
    const Row = byVisits(K);
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(gpa);
    var it = map.iterator();
    var total: u64 = 0;
    while (it.next()) |e| {
        try rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* });
        total += e.value_ptr.visits;
    }
    std.mem.sort(Row, rows.items, {}, Row.desc);
    try w.print("  total visits charged: {d}\n", .{total});
    for (rows.items[0..@min(limit, rows.items.len)]) |r| {
        try w.print("  {d:>12} visits {d:>8} calls {d:>10} max  ", .{ r.t.visits, r.t.calls, r.t.max_visits });
        label(c, r.key, w);
        try w.writeAll("\n");
    }
}

fn labelSite(_: *Checker, addr: usize, w: *std.Io.Writer) void {
    w.print("0x{x}", .{addr}) catch {};
}

fn labelRoot(c: *Checker, t: TypeId, w: *std.Io.Writer) void {
    const s = c.ts.kind(t);
    w.print("#{d} {s}", .{ t, @tagName(s) }) catch {};
    const str = c.typeToString(t) catch return;
    const cut = @min(str.len, 140);
    w.print(" {s}", .{str[0..cut]}) catch {};
}

fn labelSym(c: *Checker, sym: SymbolId, w: *std.Io.Writer) void {
    w.print("{s}", .{c.symbolName(sym)}) catch {};
}

fn labelEpoch(c: *Checker, sym: SymbolId, w: *std.Io.Writer) void {
    if (sym == 0) {
        w.writeAll("<source element>") catch {};
        return;
    }
    labelSym(c, sym, w);
}

/// Render the whole profile to stderr. Called from `seal`.
pub fn report(c: *Checker) void {
    const gpa = c.gpa;
    var buf: [64 * 1024]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), c.io, &buf);
    const w = &stderr.interface;
    w.print("\n=== ztsc instantiation profile (checker owning {d} file(s)) ===\n", .{c.owned.len}) catch {};
    w.print("total node visits: {d}  memo hits: {d}  misses: {d}  budget trips: {d}\n", .{
        c.inst_total, c.stats.inst_hits, c.stats.inst_misses, c.prof.tripped,
    }) catch {};
    w.print("uncached cond-check rebinding: {d} visits over {d} constituents\n", .{
        c.prof.cond_subst_visits, c.prof.cond_subst_laps,
    }) catch {};

    w.writeAll("\n-- visits by type kind --\n") catch {};
    {
        const Row = struct {
            k: u8,
            v: u64,
            h: u64,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.v > b.v;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        for (c.prof.kinds, 0..) |v, i| {
            if (v == 0 and c.prof.kind_hits[i] == 0) continue;
            rows.append(gpa, .{ .k = @intCast(i), .v = v, .h = c.prof.kind_hits[i] }) catch {};
        }
        std.mem.sort(Row, rows.items, {}, Row.desc);
        for (rows.items) |r| {
            const name = if (r.k < @typeInfo(types.Kind).@"enum".fields.len)
                @tagName(@as(types.Kind, @enumFromInt(r.k)))
            else
                "?";
            w.print("  {d:>12} visits {d:>12} memo-hits  {s}\n", .{ r.v, r.h, name }) catch {};
        }
    }

    w.writeAll("\n-- top-level instantiate() by call site --\n") catch {};
    dumpTally(usize, w, gpa, &c.prof.sites, 25, labelSite, c) catch {};
    w.writeAll("\n-- top-level instantiate() by root type --\n") catch {};
    dumpTally(TypeId, w, gpa, &c.prof.roots, 25, labelRoot, c) catch {};
    w.writeAll("\n-- most re-instantiated individual types --\n") catch {};
    dumpTally(TypeId, w, gpa, &c.prof.per_type, 30, labelRoot, c) catch {};
    if (focus_root != 0) {
        w.print("\n-- visits under root #{d} only, by type --\n", .{focus_root}) catch {};
        dumpTally(TypeId, w, gpa, &c.prof.focus_types, 40, labelRoot, c) catch {};
        w.writeAll("\n-- visits under that root, by kind --\n") catch {};
        for (c.prof.focus_kinds, 0..) |v, i| {
            if (v == 0) continue;
            const name = if (i < @typeInfo(types.Kind).@"enum".fields.len)
                @tagName(@as(types.Kind, @enumFromInt(@as(u8, @intCast(i)))))
            else
                "?";
            w.print("  {d:>12} visits  {s}\n", .{ v, name }) catch {};
        }
    }
    w.writeAll("\n-- expandRef() by symbol --\n") catch {};
    dumpTally(SymbolId, w, gpa, &c.prof.expands, 25, labelSym, c) catch {};
    w.writeAll("\n-- budget trips by the declaration frame that was live --\n") catch {};
    dumpTally(SymbolId, w, gpa, &c.prof.trip_epochs, 25, labelEpoch, c) catch {};
    w.writeAll("\n-- resolveStructural() sites that forced an expansion --\n") catch {};
    dumpTally(usize, w, gpa, &c.prof.expand_sites, 25, labelSite, c) catch {};

    w.writeAll("\n-- costliest statements --\n") catch {};
    {
        std.mem.sort(Stmt, c.prof.stmts.items, {}, struct {
            fn desc(_: void, a: Stmt, b: Stmt) bool {
                return a.count > b.count;
            }
        }.desc);
        for (c.prof.stmts.items[0..@min(30, c.prof.stmts.items.len)]) |st| {
            const f = &c.prog.files[st.file];
            const line, const col = lineCol(f.src, st.pos);
            w.print("  {d:>10}  {s}:{d}:{d}\n", .{ st.count, f.path, line, col }) catch {};
        }
    }
    w.writeAll("\n(call-site addresses symbolize with: atos / llvm-symbolizer, or see the\n stack traces below)\n") catch {};
    w.flush() catch {};

    // Symbolize the hottest call sites through std.debug — one synthetic
    // one-frame stack trace each, which prints `file:line: function`.
    const Row = byVisits(usize);
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(gpa);
    var it = c.prof.sites.iterator();
    while (it.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
    var it2 = c.prof.expand_sites.iterator();
    while (it2.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
    std.mem.sort(Row, rows.items, {}, Row.desc);
    for (rows.items[0..@min(30, rows.items.len)]) |r| {
        std.debug.print("\n[site 0x{x}] {d} visits / {d} calls\n", .{ r.key, r.t.visits, r.t.calls });
        var addrs = [_]usize{r.key};
        const st: std.debug.StackTrace = .{ .return_addresses = &addrs, .skipped = .none };
        std.debug.dumpStackTrace(&st);
    }
}
