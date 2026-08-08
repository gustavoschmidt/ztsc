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
//!
//! ## The synthetic, profiled: THE RELATION ERASED TO CONSTRAINTS (2026-08-04)
//!
//! The 13-line synthetic above (67 tables x 17 columns, `kysely` only, one
//! file in the program) reproduces verbatim: 429,210 node visits, 203 budget
//! trips, TS7006 + TS2589 where tsgo is clean in 0.08 s. Its profile names one
//! dominant term, and it is not `expandRef`:
//!
//!     162,760 visits / 1,329 calls   eraseParamsOf   (assign.zig:3733)
//!      96,051 visits /   673 calls   eraseParamsOf   (the fixed-point rounds)
//!      62,445 visits /   199 calls   isAssignableInner's resolveStructural
//!
//! **60% of a whole one-statement program's instantiation demand is the
//! signature relation erasing type parameters to their CONSTRAINTS**, and on
//! this corpus a constraint is `ReferenceExpression<DB, TB>` — a union over
//! every column of every table, which is exactly the measured "demand scales
//! with tables x columns". The multiplicity is not the call count (the
//! `erase_cache` already serves repeats); it is the COST of one erasure.
//!
//! tsc never does this. `getBaseSignature` — erase to constraints, with the
//! same `tps.len - 1` fixed-point rounds ztsc copied — has exactly ONE caller
//! in checker.ts, `inferFromSignature`, and it is cached on the signature.
//! The RELATION uses `getErasedSignature`: `createTypeEraser`, every own type
//! parameter to `any`, cached as `erasedSignatureCache`. `signaturesRelatedTo`
//! then has three arms, and only the middle one compares un-erased:
//!
//!   1. both sides `Instantiated` with `source.symbol === target.symbol` (or
//!      two references to one generic target) — pairwise, `erase = true`;
//!   2. ONE signature on each side — `erase = relation === comparableRelation`,
//!      i.e. normally NOT erased: `compareSignaturesRelated` instead
//!      instantiates the source in the target's context;
//!   3. anything else (an overload SET on either side) — cross-matched,
//!      `erase = true`.
//!
//! ztsc now follows that split (`Erase`, `signatureAssignableErased`,
//! `sameSigTypeParams`). Arm 1 is detected through the type parameters
//! themselves: ztsc keys a type parameter by its declaration symbol and
//! `FreshTp.orig` carries that origin across every re-freshening, so "the two
//! signatures' parameters have the same origins" IS "two instantiations of one
//! declaration". Arm 2 keeps the constraint erasure, which is what the
//! `genericSourceRelatesByInference` path already backstops.
//!
//! Measured, one lever at a time (synthetic visits / immich excess at
//! `--checkers=4`, baseline 429,210 with 203 trips / 173):
//!
//! | | synthetic | trips | immich |
//! |---|---:|---:|---:|
//! | baseline | 429,210 | 203 | 173 |
//! | arm 3 only (overload sets) | 357,206 | 0 | 162 |
//! | arms 1 + 3 (landed) | **189,643** | **0** | **123** |
//! | `any` everywhere (unfaithful) | 189,643 | 0 | 121 |
//!
//! The landed pair is within two keys of erasing everything to `any`, and the
//! synthetic goes byte-clean against tsgo. immich: 60 keys gone, 10 new, wall
//! 4.63 -> 3.06 s, peak RSS 2.10 -> 2.36 GB. Both halves are oracle-pinned by
//! `assignability/084_same_declaration_sigs_erase_to_any` and
//! `085_overload_set_erases_to_any`, each of which reported the giveaway
//! "Type '<S>(x: S) => S' is not assignable to type '<S>(x: S) => S'" before.
//!
//! ### The three ways of doing arm 2 "properly", all measured negative
//!
//! tsc's arm 2 is `instantiateSignatureInContextOf` + a comparison against the
//! target's own (free) type parameters. `instantiateSigInContextOf` is that
//! function, split out of `genericSourceRelatesByInference`; the comparison
//! was tried three ways and every one is worse than leaving arm 2 alone:
//!
//! * **Additive** (try the context comparison, fall through to the constraint
//!   erasure when it fails): 429,210 -> **440,534 visits, 309 trips**. The
//!   attempt costs and wins nothing — the pairs it is asked about fail it.
//! * **Replacing the erasure whenever the target is generic** (tsc-exact):
//!   140,227 visits and 0 trips, but the synthetic then reports a TS2345 tsgo
//!   does not — ztsc's inference is not tsc's, and with no fallback a pair it
//!   cannot infer is rejected.
//! * **Replacing it only when BOTH sides are generic**: 189,643 visits and
//!   clean on the synthetic, but it LOSES a diagnostic ztsc gets right today
//!   (`<T extends string>(x: T) => T` accepting `(x: '000') => x`).
//!
//! Erasing arm 2 to `any` as well is likewise ruled out and by the same probe:
//! it silently accepts BOTH `const f: <T>(x: T) => T = (x: string) => x` and
//! its constrained twin, where tsgo reports two TS2322 (ztsc reports the
//! second one today and still does).
//!
//! The peak RSS the change costs (2.10 -> 2.36 GB at `--checkers=4`) is not
//! the new `erase_any_cache`: dropping its writes leaves immich at the same
//! 123 keys, 3.15 s and 2.46 GB. It is completed work — the same coin the
//! budget-ceiling experiments above priced, read from the other side.
//!
//! ### What is left on immich, and where it came from
//!
//! 123 keys: TS7006 43, TS2345 25, TS2769 20, TS2322 15, TS2339 13, TS2589 3.
//! The 10 keys that APPEARED are the population truncation was hiding, the
//! same trade the budget-ceiling experiments recorded: five TS2322 on
//! `asset.repository.ts:917-923`, four TS2345 in `media.service.ts`, one
//! TS2589 in `person.repository.ts`. They are the successor item.
//!
//! ## The budget is TWO budgets, and the ceiling family REOPENS (2026-08-04)
//!
//! The five TS2322 above were read as a `Selection<…>` evaluation bug. They
//! are not one, and the bisect that settled it is worth keeping because every
//! intermediate step looked like a different bug:
//!
//!   * `.with('cte', …)`'s row type is MISSING five columns, and the five are
//!     exactly the ``sql`…` `` templates with no `${}` substitution — a
//!     perfect correlation that is a COINCIDENCE (adding a substitution to one
//!     of them does not bring it back);
//!   * the cte row is CORRECT when read directly (`.selectFrom('cte')
//!     .select('cte.isImage')`), and wrong only through the second
//!     `.with('agg', …)`, which made it look like `ExtractRowFromCommon
//!     TableExpression`;
//!   * `Selection<DB, TB, SE>` applied to the union SE by hand is byte-correct
//!     against tsgo, so the mapped type and its `as` clause are fine;
//!   * what is wrong is the union SE the ARRAY LITERAL infers. It comes back
//!     with one `AliasedRawBuilder<…>` constituent instead of six. Distinct
//!     `O` arguments (`sql<number>`, `sql<string>`, …) do not save them, so it
//!     is not a dedup by shape;
//!   * and the whole thing depends on whether immich's `asset.repository.ts`
//!     is in the program at all. Four lines:
//!
//!         declare const x2: AliasedRawBuilder<string, 'a2'>;
//!         export const y1: AliasedRawBuilder<number, 'a1'> = x2;
//!
//!     tsgo reports TS2322; ztsc reported it alone and ACCEPTED it with one
//!     extra import. Union subtype reduction then collapsed the six.
//!
//! The cause is `measuredVariances` running on the demanding statement's spent
//! budget: every `instantiate` returns `error_type`, the member table is
//! empty, no member witnesses the parameter, and the third-marker test reports
//! `independent` — cached under the symbol for the whole run. Fixed by giving
//! the measurement its own window, which is the argument `rel_id_floor`'s
//! comment already makes for the relation stack.
//!
//! **That fix alone is a net LOSS on immich — 123 -> 125 at c4, 152 -> 153 at
//! c1** — and the seven keys it uncovers (four TS2551 + a TS7006 in
//! `person.service.ts`, a TS2345 in `metadata.service.ts`, a TS7006 in
//! `asset.repository.ts`) are all `asset.faces` and friends going missing off
//! a repository method's inferred return type. Which is a truncation. Which is
//! the family this header had closed.
//!
//! ### Why it was closed wrongly: one cap was doing two jobs
//!
//! `max_instantiation_count` is a FAIRNESS device for a source element — the
//! answer it truncates is that statement's, and the next statement starts
//! over. `enterSymFile`'s window inherited the same number, and there the
//! reasoning does not hold at all: a declaration's materialization is memoized
//! under the SYMBOL and read by every later statement, so a truncation is
//! published once and never revisited. Which statement demanded it first
//! decides what the whole run sees. The "own budget epoch" experiments above
//! all moved the CHARGE and correctly measured that as a no-op; none of them
//! raised the CAP for the frame that needed it.
//!
//! Split into `max_instantiation_count` (250 k, a statement) and
//! `max_decl_instantiation_count` (5 M, tsc's own constant, a declaration
//! window), and with the window opened for EVERY declaration frame rather than
//! only a cross-file one:
//!
//!     | | c4 | c1 | c1^c4 | wall (c4) | RSS (c4) |
//!     |---|---:|---:|---:|---:|---:|
//!     | 431d668 | 123 | 152 | 41 | 2.76 s | 2.38 GB |
//!     | + variance window | 125 | 153 | — | 3.10 s | 2.37 GB |
//!     | + declaration cap (cross-file) | 108 | 91 | — | 4.00 s | 2.65 GB |
//!     | + every declaration frame | **88** | **91** | **9** | 3.98 s | 2.56 GB |
//!
//! Library corpus byte-identical or better: zod 0.15 s / 53 MB unchanged,
//! typebox **0.40 s -> 0.01 s** (its declaration now completes once instead of
//! being re-truncated by every reader — the memory note about typebox's wall
//! doubling is closed), e2e multi unchanged, excalidraw 17/0/0 CONVERGED.
//!
//! ### Raising `max_instantiation_count` itself is still ruled out — new reason
//!
//! The old entry ("Raising the budget", above) said 5 M cost 41 s and made
//! immich WORSE. Re-measured at this branch point, demand having fallen ~10x
//! since, BOTH halves of that are now false and it is still a blocker:
//!
//!     | statement cap | immich c4 | immich c1 | zod wall / RSS |
//!     |---|---:|---:|---|
//!     | 250 k | 123 | 152 | 0.15 s / 53 MB |
//!     | 1 M | 123 | 133 | — |
//!     | 2 M | 96 | 127 | — |
//!     | 3 M | 95 | 94 | — |
//!     | 5 M | 95 | 94 | **1.37 s / 301 MB** |
//!
//! immich plateaus at 3 M (10 M is byte-identical to 5 M), and 95/94 with a
//! cross-partition divergence of ONE key is the best excess this corpus has
//! ever shown — but zod goes to nine times tsgo's wall and twice its RSS on a
//! GATED package, because zod's cost is in ordinary source elements that used
//! to trip and now run to completion. The split cap buys immich's half of that
//! (88/91) without touching what a statement may spend.
//!
//! ### What the split leaves, measured
//!
//! `-- budget trips by the declaration frame that was live --` at head:
//!
//!     950 trips, ALL of them <source element>
//!
//! against 3,916 of 5,290 inside a table construction before. **No declaration
//! materialization in the whole package truncates any more**, and exactly one
//! statement (`ocr.repository.ts:31:49`) reaches the 250 k cap. So the
//! remaining 88 keys are NOT truncation, and the ceiling family is closed for
//! a third time — this time with the trip counter, not by inference.
//!
//! Confirmed from the other side: raising the STATEMENT cap to 3 M *on top of
//! the split* gives **88 -> 95** (13 keys appear, 6 go), and the largest
//! remaining cluster gets worse rather than better —
//! `sync.repository.ts` 12 -> 21. More budget buys these nothing, which is
//! what a genuine divergence looks like.
//!
//! 88 keys at c4: TS2345 23, TS2769 19, TS7006 17, TS2339 13, TS2322 10,
//! TS2589 2, one each TS2678/TS2367/TS2366/TS2365. The largest single cluster
//! is `sync.repository.ts` (12, every one a TS7006 on a `.select((eb) => …)`
//! or `.where(…, (eb) => …)` callback whose contextual type is lost), then
//! `search.service.ts` and `user.repository.ts` at 5. None of the three
//! reproduces in isolation — each needs the rest of the package in the program
//! — which is the same signature the TS2769 that opened this campaign had, and
//! that one turned out to be a call-resolution divergence
//! (`rollbackArgDiags`' budget refund), not a truncation. That is where the
//! next bisect should start.
//!
//! No synthetic conformance fixture exists for the VARIANCE half, and the
//! reason is structural rather than a failure of imagination: the bug needs a
//! variance question asked from a statement that has already spent 250,000
//! node visits, and a statement that has spent them reports TS2589 where tsc
//! (with 20x the budget) is clean — so any snapshot carries a `+` entry with
//! no matching oracle diagnostic, which DEFERRED's policy does not admit. It
//! is pinned by the four-line kysely repro above and by the immich gate. The
//! DECLARATION half is pinned, by
//! `instantiation/053_cross_file_declaration_budget`, which fails (and is the
//! only case that fails) when `max_decl_instantiation_count` is put back to
//! `max_instantiation_count`.
//!
//! ## "It does not reproduce in isolation" was FALSE (2026-08-04)
//!
//! The note above — that `sync.repository.ts`'s twelve keys need the rest of
//! the package — was an artifact of the scratch project, not of the bug. A
//! `tsconfig.json` whose `include` matches nothing loads no inputs and prints
//! "no inputs were found", which greps for `error TS` read as CLEAN. The file
//! copied into a project that really does load it — its own imports resolved
//! through `paths` at the app, `node_modules` symlinked, 3 s per run, nothing
//! else in the program — reports TWENTY-ONE diagnostics where tsgo is clean.
//! Any bisect that ends in "it needs the whole package" should re-check that
//! the scratch program has files in it first.
//!
//! What the package was doing to those twelve is MASKING, and it is worth
//! recording because it inverts the usual reading of an `any` cascade. In the
//! app the callbacks are TS7006 because their chain is `any`: `const { table,
//! ref } = this.db.dynamic` binds both names to `any` because
//! `resolveStructural(DynamicModule<DB>)` answers `error_type`. That expansion
//! was built ONCE — from `ocr.repository.ts`, the single statement in the
//! package that reaches the 250 k statement cap — and `expandRef` memoized the
//! truncation under the ref for the rest of the run. An `any` receiver reports
//! one implicit-`any` parameter and nothing else, so the twelve TS7006 were
//! the *quiet* form of twelve TS2769 plus three TS2345.
//!
//! ### The bug under them: the overload-set erasure was one-sided
//!
//! Nine lines with no immich code in them:
//!
//!     declare const db: Kysely<DB>;
//!     export const q = db.selectFrom('asset_exif')
//!       .where('assetId', 'in', (eb) =>
//!         eb.selectFrom('asset').select('id').where('ownerId', '=', 'x'))
//!       .compile();
//!
//! Everything up to the relation is right: `partialParamCtx` takes `VE`'s
//! CONSTRAINT (`OperandValueExpressionOrList<DB, TB, RE>`) for the contextual
//! type, the arrow types as `(eb: ExpressionBuilder<DB, 'asset_exif'>) =>
//! SelectQueryBuilder<DB, 'asset' | 'asset_exif', { id: string }>`, and the
//! argument then fails on the RETURN — that builder is not a
//! `SelectQueryBuilderExpression<{ [x: string]: string | null }>`. Which is
//! not about the payload: `Expression<…>` and `AliasableExpression<…>` split
//! the pair, and the member that fails is `as`.
//!
//! `AliasableExpression.as` is an overload SET of two (`alias: A extends
//! string`, `alias: Expression<any>`); `SelectQueryBuilder` overrides it with
//! ONE signature. tsc's `signaturesRelatedTo` reads the erasure off the SHAPE
//! OF THE PAIR — arm 3, "an overload set on EITHER side", erases both sides to
//! `any` — while ztsc's `.overloads` TARGET arm recursed into `isAssignable`
//! once per target signature, so every pair then looked like arm 2 and was
//! erased to its CONSTRAINTS. The source's `A` becomes `string`, `string` does
//! not accept `Expression<any>`, and a kysely builder stopped being an
//! `AliasableExpression` at all. 085 pinned the source half of arm 3 a day
//! earlier; the target half was never written.
//!
//! immich **88 -> 86 at c4 and 91 -> 89 at c1** on its own (two TS2345 in
//! `move.repository.ts` and `person.repository.ts`, zero new keys), wall
//! 3.58 -> 3.59 s, peak RSS 2.59 -> 2.40 GB, every gate unchanged — and the
//! scratch project's 21 go to zero. The small package number and the large
//! isolated one are the same masking: in the app most of this family is still
//! hidden behind the `DynamicModule<DB>` truncation. Pinned lib-free by
//! `assignability/086_overload_target_erases_to_any`.
//!
//! ### And then the mask itself: a truncation is not an answer either
//!
//! `expandRef` memoized `error_type` under the ref and served it for the rest
//! of the run. Withdrawing that one publication — the generic table exists,
//! the substitution over it collapsed, so it is a truncation and not a fact —
//! takes immich **86 -> 74 at c4 and 89 -> 72 at c1**: all twelve
//! `sync.repository.ts` TS7006 and a thirteenth in `person.repository.ts`, for
//! one new key. wall 3.59 -> 3.63 s, peak RSS 2.40 GB, zod and typebox
//! byte-identical in time and space.
//!
//! Two neighbouring shapes of the same idea are NOT this, and both are worse:
//!
//! * **Withdrawing on `inst_limit_tripped`** — the flag, scoped to the
//!   expansion's own extent — is a literal no-op on immich at head (86/89,
//!   byte-identical key sets). The statement that publishes the truncation has
//!   ALREADY tripped by the time it gets there, so the flag is set on entry
//!   and the guard never fires. The definite marker (`error_type` out of a
//!   non-`error_type` generic) is the one that names the case.
//! * **Refunding the expansion's cost to the demanding statement**
//!   (`saveCtx`/`restoreCtx` around `expandRef`, on the argument that an
//!   expansion is a declaration-scope fact and `restoreCtx` already rolls
//!   declaration windows off the requester) reaches the SAME immich numbers —
//!   72 at c4, 71 at c1, and a c1^c4 divergence of ONE key — but it is a
//!   BLOCKER on a gated package: a statement whose cost is all expansions then
//!   has no bound at all, and **zod goes 0.15 s / 53 MB -> 0.90 s / 166 MB**
//!   (user CPU 0.21 -> 0.90 s), six times tsgo's wall. Not taken. The cheap
//!   half of what it buys is the withdrawal above.
//!
//! No conformance fixture pins the withdrawal, and it is the same structural
//! reason the variance window has none, now sharper: after the split cap,
//! reaching a truncated expansion at all requires a SOURCE ELEMENT to spend
//! 250,000 node visits, and a source element that spends them reports TS2589
//! where tsc — with 20x the budget — is clean, so the snapshot carries a `+`
//! with no oracle diagnostic. Two more shapes were tried on top of the ones
//! this header already lists: a mapped-type burn read through a relation
//! (`twoArg(p, h)` with `Heavy<Big1>` against `Heavy<Big2>`), which is
//! reportable-free but charges 4.0 M visits to DECLARATION windows and trips
//! zero times, and the same burn at checking level, which trips and reports
//! the TS2589. It is pinned by the immich gate.
//!
//! ### The withdrawal's bill, and where to send it (2026-08-08)
//!
//! The withdrawal above cost drizzle-orm **19.5 ms / 18.1 MB -> 3.20 s /
//! 1.61 GB at c1** (2.32 s / 4.04 GB at c4, and unstable run to run) — 120x
//! wall, and the published BENCHMARKS.md row wrong in ztsc's favour ever
//! since. Nothing else in the corpus moved, and drizzle's own diagnostics
//! never moved either: 83 keys with the withdrawal, 83 without.
//!
//! The mechanism is not extra type work, it is extra *prologue*. `expandRef`
//! is asked for a reference; the memo is withdrawn, so it re-derives
//! `typeParamsOf` (which re-reads the declaration's type-parameter list out of
//! the AST and re-interns every name through `atomOfToken` ->
//! `scanner.tokenEnd`) and `buildInstMap`, and only then reaches an
//! `instantiate` that answers in ONE visit because `chainRepeats` cuts it. The
//! `--inst-profile` counters name it exactly: `PgSelectBase` **1,988,648
//! calls** charging 43,226 visits, `SQLiteSelectBase` **1,094,615 calls**
//! charging 146,786 — a fifth of a visit per call. `expandRef` also bumps its
//! `args` dupe and its two lists onto the live instantiation arena, and
//! `BumpArena.free` is a no-op for anything but the most recent block, so
//! three million prologues that never return a type still leave their scratch
//! behind: `check scratch high-water` 1,666,842,624 bytes, which IS the
//! 1.69 GB peak. Both halves are the same repeat.
//!
//! The demand is the `substThis -> reduceMapped -> materializeMapped ->
//! substMappedKey -> reduceIndexedAccess -> indexedAccessType ->
//! resolveStructural -> expandRef` spine, entered from `checkClass`'s
//! heritage relation on the two `…SelectBase` declarations. Every level of it
//! re-asks the same handful of references; before the withdrawal the memo
//! answered them, after it nothing did.
//!
//! So the truncation gets a memo that is scoped to what it is actually a fact
//! about. It is not a fact about the reference — that is what df8ffb8 settled
//! — but it IS a fact about the BUDGET WINDOW that produced it, so
//! `trunc_expansions` keys it by `Checker.budget_epoch`, an id minted fresh
//! wherever `inst_count` restarts or is refunded (`checkStatement`,
//! `enterSymFile`, the variance window, the queued type-argument drain, an
//! overload candidate's refund) and restored with the rest of the context by
//! `restoreCtx`. Within a window the second ask is two hash probes; the first
//! ask in the NEXT window re-expands exactly as before, which is the whole of
//! what the immich fix needs — `ocr.repository.ts`'s statement is one window,
//! and every later reader of `DynamicModule<DB>` is in another.
//!
//! drizzle **3.20 -> 0.16 s / 1608 -> 35 MB at c1**, 3.98 -> 0.15 s /
//! 2624 -> 33 MB at c2, 2.32 -> 0.10 s / 4038 -> 33 MB at c4, 3.86 -> 0.15 s /
//! 3064 -> 36 MB at c8 (interleaved medians of five against tsgo's 0.23 s /
//! 275 MB). `PgSelectBase` 1,988,648 calls -> 31, `SQLiteSelectBase`
//! 1,094,615 -> 44; `inst cache misses` 3,270,872 -> 133,914. immich stays at
//! 0 diagnostics at c1/c4/c8 with wall and RSS unmoved (2.5 s / 382 MB at c1),
//! and the other seven packages are unchanged to the tenth of a megabyte.
//!
//! What the epoch does NOT buy back is the ~2x node-visit difference against
//! simply republishing the truncation (338,988 vs 183,976 `instantiations`,
//! and 20.6 MB vs 0.7 MB of `check scratch high-water`). That gap is
//! df8ffb8's semantics being paid for honestly: a published truncation also
//! publishes `inst_limit_tripped == false` to everything downstream of it, so
//! the whole subtree under a poisoned reference becomes memoizable. The
//! withdrawal declines that, and the epoch memo declines it too — the fast
//! path sets `inst_limit_tripped` exactly as the real path would, or the first
//! ask in a window and the second would disagree about whether their callers
//! may cache, which is the order-dependence the whole family is about.
//!
//! One shape measured and NOT taken: letting a declaration window (`enterSymFile`)
//! INHERIT the enclosing statement's epoch instead of opening its own. It is a
//! literal no-op on drizzle (0.16 s either way, byte-identical diagnostics),
//! and it would serve a truncation from a spent statement into a window that
//! was given a fresh budget precisely so it could succeed — the immich
//! poisoning, re-scoped rather than fixed.
//!
//! ## Family 2, re-bucketed at 74 — and it isolates now (2026-08-04)
//!
//! With the scratch-project method fixed, the clusters that "needed the whole
//! package" do not. `user.repository.ts` and `search.service.ts` copied into a
//! project holding nothing but themselves reproduce NINE of the remaining keys
//! verbatim, at 3 s a run. Anything left on the list can be bisected the same
//! way.
//!
//! ### `search.service.ts`'s three TS2339: an undecidable `as` remap DELETES
//!
//! `LargeAssetSearchDto` has no `visibility` — and its sibling
//! `RandomSearchDto`, built from the same base schema, does. The split is zod's
//! `util.Extend`:
//!
//!     type Extend<A, B> = Flatten<keyof A & keyof B extends never ? A & B
//!       : { [K in keyof A as K extends keyof B ? never : K]: A[K] }
//!         & { [K in keyof B]: B[K] }>;
//!
//! `RandomSearchSchema.extend({…})` adds only NEW keys and takes the `A & B`
//! branch; `LargeAssetSearchSchema.extend({…})` redeclares `size` and takes the
//! REMAP branch — where every key `A` had and `B` did not vanished.
//!
//! `reduceMapped` decided deferral from the KEY SET alone, on the stated
//! reasoning that "the value/`as` branches may still be generic (they
//! materialize into generic-typed props)". True of the value branch, false of
//! the remap: `remapKey` evaluates the remap once per key and DROPS any key
//! whose remap does not reduce to a literal or `never`, so an `as` clause that
//! still mentions an unbound type parameter deletes the whole table — and the
//! key set is perfectly concrete there, so nothing else catches it. Reached
//! through `ZodObject.extend<U>(shape: U): ZodObject<Extend<Shape, U>>`,
//! `Shape` is bound at the receiver and `U` only at the call.
//!
//! Deferring on a free type param in the `as` clause: immich **74 -> 69 at c4,
//! 72 -> 67 at c1**, five keys (three in `search.service.ts`, two in
//! `activity.service.ts`), zero new, wall 3.63 -> 3.62 s, RSS flat, zod
//! byte-identical. Only FREE TYPE PARAMS may count: the map's own key is a
//! `.mapped_param`, and an `infer` binder written inside the remap binds per
//! key — conformance `mapped/061` and `conditional/043` fail on either. Pinned
//! lib-free by `mapped/062_as_remap_defers_on_free_param`, whose negative
//! control keeps the filtering a DECIDABLE remap still does.
//!
//! ## 69 -> 42: the budget was never the story (2026-08-04)
//!
//! Everything above is about instantiation budget. The eight fixes below are
//! not — every one is a missing REDUCTION RULE, each isolates in a lib-free
//! file, each was found by copying one immich file into a scratch project and
//! deleting until the diagnostic stood alone. immich **69 -> 42 at c4 and
//! 67 -> 40 at c1, zero new keys at any step**, wall 3.62 -> 3.53 s, peak RSS
//! 2.44 -> 2.55 GB (tsgo: 2.28 s / 2.28 GB, 0 diagnostics). The lesson for the
//! next session is the method, not any one fix: **the remaining excess is
//! ordinary type-system surface, and it comes out three or four keys at a
//! time.** Nothing here needed a profile.
//!
//! The ENUM is where most of it lived, because ztsc models an enum as ONE
//! nominal type while tsc models it as the UNION of its member types. Five of
//! the eight are that single modelling difference surfacing in a different
//! operator:
//!
//! * **`Record<E, V>` had an index signature, not members.** `collect
//!   MappedKeys` materialized an enum key domain as one string/number index
//!   on the reasoning that a computed enum key `[E.A]` is keyed by a
//!   text-derived placeholder. It is not — `constSymbolKeyAtom` resolves it to
//!   the member's VALUE. The index signature cost `keyof` the enum, so
//!   `keyof M` for `interface M extends Record<E, …>` was `string | number`
//!   and `<T extends keyof M>` no longer satisfied `T extends E`. The domain
//!   now enumerates member types and names one property per member, recording
//!   the member type in `key_name_types`. -7 keys.
//! * **`Exclude<E, E.A>` did not subtract.** A distributive conditional whose
//!   check is a whole enum did not distribute, so `E extends E.A` was simply
//!   false. Invisible while `Record<E, V>` was an index signature; four
//!   missing properties the moment it was not (`ConcurrentQueueName`).
//!   `condDistributionDomain` distributes over the members when the extends
//!   clause names members of the same enum — gated so nothing else changes
//!   spelling.
//! * **`T[E.A]` indexed by `string`.** No arm for an enum index, so it fell to
//!   the string-like arm and answered `any` for a table with no string index.
//!   `Jobs = { [K in JobItem['name']]: … }` read through `JobOf<JobName.X>`
//!   was `any` and every callback under it lost its parameter types. -3.
//! * **Two same-named enum DECLARATIONS did not relate.** tsc's
//!   `isEnumTypeRelatedTo` is the one structural rule in a nominal type: same
//!   name, every source member present in the target with the same value.
//!   immich redeclares `@immich/sql-tools`' `DatabaseSslMode` in
//!   `env.dto.ts`, and zod's `$InferEnumOutput<T> = T[keyof T]` hands the
//!   redeclared members into the published one's parameter.
//! * **An enum member was not a UNIT type**, so `discriminatedUnionAssignable`
//!   declined every enum-tagged discriminated union. This one is only
//!   reachable once `T[E.A]` resolves — it was hidden behind the `any` — and
//!   it is what the excalidraw gate caught. Worth remembering as a shape:
//!   fixing a reduction can expose a relation rule one layer down, and the app
//!   gate is where that shows up.
//!
//! The other three are ordinary tsc rules ztsc had never transcribed:
//!
//! * **An intersection with a `never` DISCRIMINANT is empty**
//!   (`getReducedType` / `isDiscriminantWithNeverType`). ztsc reduced only a
//!   top-level pair of distinct units (`'a' & 'b'`), never two objects that
//!   disagree on a property — so `(A | B) & { tag: true }` kept its
//!   contradictory product as a union constituent carrying none of `A`'s
//!   members, and every read off it was TS2339 (`MaintenanceModeState`). -4.
//! * **Disjoint primitive DOMAINS, and redundant base primitives.**
//!   `TypeFlags.DisjointDomains` (`1 & string` is `never`) and
//!   `removeRedundantPrimitiveTypes` (`"a" & string` IS `"a"`). Together they
//!   are what makes the `keyof M & (string | symbol)` key-filter idiom work.
//!   Byte-identical on immich, but the whole `IsAny<T> = 0 extends 1 & T`
//!   family needs the first, and the socket.io alias chain now matches the
//!   oracle step for step.
//! * **A homomorphic map over a union maps PRIMITIVE constituents to
//!   themselves.** ztsc distributed only when every constituent was a plain
//!   object, so one `null` sank the map to `{}`: kysely's
//!   `Simplify<ShallowDehydrateObject<O>>` over a nullable row typed
//!   `withAudioStream` as `{} | null`. -5.
//! * **The static side did not inherit a base EXPRESSION's members.**
//!   `class D extends <expr>` — the instance side already had the arm
//!   (`baseExprConstructType`), the static side had only the class-SYMBOL one.
//!   nestjs-zod's `createZodDto` is written that way. -4.
//! * **`keyof { [k: symbol]: V }` was `string | number`.** A symbol-keyed
//!   index signature shares ztsc's string slot; `obj_flag_symbol_index`
//!   records the distinction for `keyof` alone, so every consumer that READS
//!   an index signature is untouched. nestjs-cls' `ClsStore`. -3.
//!
//! ### What is left, and what it is
//!
//! 42 keys at c4 / 40 at c1, c1^c4 = 2 (`asset.repository.ts:192` TS2589 and
//! `user.repository.ts:301` TS2769, both c4-only — the same budget-order coin
//! this header has priced three times). By family:
//!
//! * **kysely `sql`-template contextual typing** — `person.repository.ts:328`
//!   `.where(() => sql\`…\`)` isolates in ELEVEN lines against immich's
//!   `node_modules` and nothing else. `where<E extends ExpressionOrFactory<DB,
//!   TB, SqlBool>>` should contextually type the arrow's return as
//!   `OperandExpression<SqlBool>`, so the `sql` tag's `T` infers `SqlBool`;
//!   ztsc leaves `T` at its `unknown` default and `Expression<unknown>` does
//!   not accept. Return-context-driven inference into a TAGGED TEMPLATE call
//!   is the thing to look at. `search.service.ts`'s two keys are its cascade.
//! * **socket.io `EventNamesWithoutAck`** (app.repository ×3,
//!   websocket.repository, maintenance-websocket.repository, main.ts ×2).
//!   Every alias on the chain — `EventNames`, `Map[K]`, `Parameters`, `Last`,
//!   `IsAny` — now computes the oracle's answer when written out by hand in a
//!   scratch file; only the real `Server<…>` call still fails, so the residue
//!   is in the generic plumbing between the interface's type params and the
//!   default type argument, not in the aliases.
//! * **`ClassConstructor` DI comparability** (medium.factory ×3) — never
//!   traced.
//! * **kysely `excluded.${col}` template references** (asset.repository ×3) —
//!   `eb.ref(\`excluded.${col}\`)` with `col: T extends keyof AssetExifTable`.
//! * Singles: bullmq `Job<…, infer N>` conditionals (job.repository ×2),
//!   `@nestjs/swagger` `SchemaObject` (auth.guard ×2), and ten one-offs.
//!
//! The two TS2589 (`asset.repository.ts:192`, `ocr.repository.ts:33`) are the
//! only keys in the package that are still about the budget at all.
//!
//! ## 42 -> 26: four of those five families, closed (2026-08-04)
//!
//! Same method, same result: every one is an ordinary type-system rule ztsc had
//! not transcribed, each isolates lib-free, none needed a profile. immich
//! **42 -> 26 at c4 and 40 -> 25 at c1, zero new keys at any step**, wall
//! 3.53 -> 3.48 s, peak RSS 2.55 -> 2.33 GB (tsgo: 2.28 s / 2.28 GB, clean).
//! The c1^c4 divergence went 2 -> 1: `user.repository.ts:301` closed with the
//! rest, `asset.repository.ts:192`'s TS2589 is still c4-only.
//!
//! * **A union contextual RETURN type infers constituent by constituent.**
//!   tsc's `inferFromTypes` ends in an untargeted union-SOURCE rule; ztsc's
//!   `.object` arm of `unify` reached that pairing only through three identity
//!   rules (same generic origin, a discriminant, an index-shaped target), so
//!   kysely's `OperandExpression<V> = Expression<V> | SelectQueryBuilder
//!   Expression<Record<string, V>>` inferred NOTHING and `sql`'s `<T = unknown>`
//!   fell back to its default. **The tagged template was a red herring** — a
//!   plain generic call in the same position failed identically, and the whole
//!   thing reduces to four lines with no `sql` tag in them. -5 keys.
//!
//!   Two scopings are load-bearing and both are measured. The untargeted form
//!   costs **3.9 s -> 16.2 s and 42 -> 46 keys**, because kysely's contextual
//!   types are unions of builder interfaces that all pair on callability alone;
//!   `constituentCarriesInference` (the constituent must have a property NAMED
//!   by one of the target's inference positions) is what keeps the wall flat.
//!   And applying it outside the contextual-RETURN pass costs excalidraw a key
//!   (`DropdownMenuItemContentRadio<T>` infers `T = string` instead of
//!   `Theme | "system"`), because `ReturnType` is in tsc's
//!   `PriorityImpliesCombination` — several constituents' candidates are
//!   UNIONED there and common-supertyped everywhere else.
//! * **A construct-signature object is assignable to a class VALUE.** ztsc's
//!   `.class_value` target arm answered `false`, so `ClassConstructor<T> =
//!   { new (...args: any[]): T }` was not a `typeof SomeRepository`.
//!   `classConstructType` already materialized the static side for
//!   `InstanceType<T>` pattern matching; the relation and
//!   `tryReportMissingProps` now read it. A `.class_value` SOURCE stays
//!   nominal. -2.
//! * **Two instantiations of one generic pair their type ARGUMENTS in the
//!   overlap test** (tsc's `relateVariances`). `typesHaveOverlap` already
//!   treated an unconstrained type parameter as overlapping everything, but
//!   only at the top level of an operand, so `switch (key)` on a
//!   `ClassConstructor<T>` rejected a `case` of type
//!   `ClassConstructor<LoggingRepository>`. -1.
//! * **`[...X[]]` is `X[]`** (tsc's `getTupleTargetType`). ztsc reified a
//!   parameter list as a tuple unconditionally, so
//!   `Parameters<(...args: any[]) => void>` was `[...any[]]` and
//!   `ReadonlyArray<infer E>` inferred `E = any[]`. Byte-identical on immich by
//!   itself — it is the prerequisite for the next one.
//! * **`higherOrderSigEligible` decides ENFORCEMENT, not substitution.** A
//!   generic interface's method may bound its own type parameter with a type
//!   built out of the INTERFACE's parameter; ztsc gated the whole rewrite on
//!   eligibility and `sigReferencesOuterParam` then called such a signature
//!   self-contained, so the bound was left standing over a parameter that had
//!   just been substituted away — unsatisfiable, and the inference clamped to
//!   it. socket.io's `emit<Ev extends EventNames<RemoveAcknowledgements<E>>>`
//!   is exactly that (its `Last`/`Parameters` chain has an `infer` in an
//!   `extends` clause, so `boundReducible` declines it). -5.
//!
//!   The narrow alternative — widening the constraint-FALLBACK skip at the call
//!   site to any constraint mentioning an unresolvable outer parameter —
//!   reaches the same immich number and LOSES a diagnostic
//!   (`indexed/025`'s `pick(o, "nope")`, where `keyof T` legitimately
//!   substitutes to `keyof Partial<U>` over the enclosing function's own `U`).
//!   Fix the instantiation, not the clamp.
//! * **A generic TEMPLATE-LITERAL source relates through its base constraint.**
//!   ztsc had tsc's `getBaseConstraintOfType` source rule for a deferred
//!   indexed access but not for a template literal, so
//!   `` `excluded.${T}` `` related to nothing. -3.
//!
//!   The neighbouring change is a NEGATIVE: `ctxWantsTemplate` is ztsc's
//!   `isTemplateLiteralContextualType`, tsc's admits `StringLiteral |
//!   TemplateLiteral`, and adding the literal half looks right because ztsc
//!   EXPANDS a finite template-literal type into its union. But ztsc's version
//!   also DISTRIBUTES over a union, which tsc's does not, and the two together
//!   made excalidraw's `style={{ transform: … }}` keep
//!   `` `translate(${number}px, …)` `` against a `CSSProperties['transform']`
//!   that merely CONTAINS string literals — two fresh TS2322. Not taken.
//!
//! ### What is left at 26, and the one thing that is diagnosed but not fixed
//!
//! 26 at c4 / 25 at c1: TS2769 8, TS2345 8, TS2322 5, TS2589 2, one each
//! TS2366/TS2365/TS2339. No family is larger than two keys any more.
//!
//! `@nestjs/swagger`'s `ApiQuery` (auth.guard ×2) is traced and isolates in 27
//! lib-free lines, and the fix is NOT obvious — it is a question about tsc, not
//! about ztsc:
//!
//!     interface Common { type?: Ctor<unknown> | 'string' | (string & {}); }
//!     type Meta = Common | ({ name: string } & Common & Omit<Schema,'required'>);
//!     declare function api(o: Meta): void;
//!     api({ name: 'plain', type: S });   // tsgo clean, ztsc TS2345
//!
//! The literal fits the FIRST constituent (whose properties are all optional)
//! with `name` as an extra property, and `name` is known in the union, so tsc's
//! whole-union `hasExcessProperties` passes and
//! `typeRelatedToSomeType(getRegularTypeOfObjectLiteral(source), …)` then
//! relates the REGULARIZED literal to `Common` and accepts. ztsc's
//! `freshLiteralUnionMismatch` instead SKIPS any constituent that does not know
//! every written property, which is the per-constituent excess model. Note the
//! same function's own motivating case (`crypto.subtle.decrypt`'s `{name, iv}`
//! against `AlgorithmIdentifier | … | AesGcmParams`) needs the skip: tsc
//! reports there. The two differ somewhere in `hasExcessProperties`'
//! `findMatchingDiscriminantType` / `filterPrimitivesIfContainsNonPrimitive`
//! reduction of the target union, and settling WHICH is the next step — the
//! same source is assignable, and the only difference is which constituent is
//! allowed to answer. Both shapes are in this header; do not change
//! `freshLiteralUnionMismatch` without re-running the crypto case.
//!
//! The rest: bullmq `Job<…, infer N>` (job.repository ×2), main.ts ×2 (the
//! socket.io family's residue, a different call), and fifteen one-offs.
//!
//! ## 10 -> 5: the last ten, six of them closed (2026-08-05)
//!
//! Same method again, and the same lesson: every one is an ordinary
//! type-system rule ztsc had not transcribed, each isolates in a handful of
//! lines, none needed a profile. immich **10 -> 5 at c4 and 9 -> 4 at c1, zero
//! new keys** (one appeared mid-way and was closed by the scoping below).
//!
//! * **A union parameter's naked variable takes the UNMATCHED constituents.**
//!   tsc's `inferToMultipleTypes` runs each non-variable target constituent
//!   against each SOURCE constituent on its own and records which sources
//!   produced an inference; the naked variable gets the union of the rest.
//!   ztsc handed the whole union to the wrapper and stood the variable down
//!   whenever the wrapper inferred anything, losing every constituent the
//!   wrapper did not account for — `T | T[]` against
//!   `string | string[] | undefined` gave `string`, not `string | undefined`.
//!   Scoped to exactly one naked member, which is also tsc's
//!   `typeVariableCount === 1`: with no naked member, splitting the union
//!   changes what a wrapper INFERS rather than what is left over, and
//!   `Pick<T, K> | T | null` against a forwarded `state` then takes its key
//!   set from one constituent (conformance `inference/085`).
//! * **An element access keyed by a whole ENUM**, plus a NUMERIC property key.
//!   `checkIndexExpr`'s catch-all classifies the key as string- or
//!   number-like and a whole enum is neither (ztsc models an enum as ONE
//!   nominal type, tsc as the union of its members); and
//!   `indexedAccessType`'s numeric arm went straight to `numberIndexType`, so
//!   `{ 0: string }[0]` was `any` too. Together these made
//!   `handlers[name as JobName]` on `Partial<Record<JobName, JobMapItem>>`
//!   answer `any` — poisoning the inferred return type of the method holding
//!   it (`job.service.ts:91`).
//! * **An enum member initialized with ANOTHER enum's member is a CONSTANT**
//!   (tsc's `computeConstantValue` over an entity name). Classified
//!   `computed`, it cost the whole enum its `all_string` classification, so
//!   the member no longer widened to `string` and `typeof E` no longer
//!   satisfied `Readonly<Record<string, string | number>>` — zod's
//!   `z.enum(E)` parameter (`enum.ts:103`). The bare-name form (`B = A`) is
//!   deliberately NOT folded: ztsc's binder declares no scope for an enum
//!   body, so such a reference is already TS2304 and folding it would not
//!   make the declaration check. Watch the file-scope trap this exposed —
//!   both walks run under `enterSymFile`, which switches the FILE and leaves
//!   `cur_scope` pointing into the REQUESTER's, an out-of-bounds scope id.
//! * **A NON-ARRAY rest parameter takes its arguments as a TUPLE** (tsc's
//!   `getNonArrayRestType` / `getSpreadArgumentType`). ztsc read the rest's
//!   array ELEMENT, which mentions no inference variable, so
//!   `K extends PropertyName[]` fell back to its constraint and lodash's
//!   `omit`'s `Pick<T, Exclude<keyof T, K[number]>>` reduced to `{}` for every
//!   call (`shared-link.repository.ts:179`). Two scopings are load-bearing: an
//!   element keeps its LITERAL when the rest's element type is primitive
//!   (tsc's `hasPrimitiveContextualType`), and a CONTEXT-SENSITIVE function
//!   argument stops the pass (tsc gets `anyFunctionType` under
//!   `SkipContextSensitive` and the tuple propagates `NonInferrableType`).
//!
//! ### The `freshLiteralUnionMismatch` question above is SETTLED
//!
//! The note this header left — that the swagger case and the
//! `crypto.subtle.decrypt` case "differ somewhere in `findMatchingDiscriminant
//! Type` / `filterPrimitivesIfContainsNonPrimitive`" — was looking in the
//! wrong place, and the answer was derived from the ORACLE rather than from
//! reading: twelve probes separate the candidate models and exactly one rule
//! fits all twelve.
//!
//! `hasExcessProperties` has a SECOND half, and over a union it is the whole
//! rule. Having found a written property's NAME known somewhere in the union,
//! tsc compares the property's VALUE against
//! `getTypeOfPropertyInTypes(checkTypes, name)` — the union of that property's
//! type over EVERY constituent, `undefined` standing in for a constituent that
//! does not have it — and fails the relation when the value does not fit.
//! Nothing else is per-constituent: `unionOrIntersectionRelatedTo` then
//! relates the REGULARIZED literal to some constituent and never
//! excess-checks again.
//!
//! That single rule gives both recorded shapes. The crypto case fails because
//! `iv` is `number` in the one arm that has it and `undefined` in the rest;
//! the swagger case passes because `name` (`string` in the second arm) and
//! `type` (a `Ctor` union in the first) each fit, after which the regularized
//! literal relates to `Common`. The old per-constituent model is stricter
//! exactly when the properties are SPREAD ACROSS ARMS, which is what
//! `ApiQuery({ name, type })` is. Two scopings matter: the wholesale bail on a
//! union CONTAINING an empty object type or `object` (`isEmptyObjectType` is
//! `some` over a union), and reporting only when the elaboration can NAME the
//! property — tsc's own message does
//! (`Types_of_property_0_are_incompatible`), and when ztsc's cannot, this
//! check is disagreeing with the relation walk that just accepted the literal,
//! which is a false positive on any pair whose property types ztsc evaluates
//! differently (it cost one fresh key, `album.service.ts:163`, a kysely
//! `ShallowDehydrateValue`, until it was scoped).
//!
//! ### What is left at 5, and what each one is
//!
//! 5 at c4 / 4 at c1 (`asset.repository.ts:192`'s TS2589 is still the one
//! c4-only key, as it has been for three sessions).
//!
//! * **`user.repository.ts:311` TS2769** — kysely `.set()` with a
//!   subquery-valued update column, and it is now bisected to NINE lines and
//!   is ORDER-INDEPENDENT (it reproduces alone in a file). The failing shape
//!   is precisely: the OBJECT form of `set` whose property is a factory arrow
//!   whose body contains a NESTED callback call —
//!
//!       db.updateTable('user').set({
//!         quotaUsageInBytes: (eb) =>
//!           eb.selectFrom('asset').select((eb2) => eb2.lit(0).as('usage')),
//!       })
//!
//!   Both neighbours are CLEAN, which is the whole handle: the two-argument
//!   `set('quotaUsageInBytes', <same factory>)` overload is clean, and the
//!   object form with a factory that has NO nested callback is clean. The
//!   inner builder's row type is also right on its own (`{ usage: number }`,
//!   byte-identical to the oracle). So it is not the subquery and not the
//!   `set` value slot alone — it is contextually typing a context-sensitive
//!   arrow that is an OBJECT-LITERAL PROPERTY, whose contextual type comes
//!   from a mapped-type property (`UpdateObject`'s
//!   `ValueExpression<DB, TB, V>`), when that arrow is itself the receiver of
//!   a second context-sensitive call. That is where the next bisect starts.
//! * **`search.service.ts:33` and `asset.service.ts:127` TS2345** — traced,
//!   and they are the truncation MASK, not a separate evaluation bug. Two
//!   independent probes settle it: `person.getByName` copied into a project
//!   holding nothing else reports the TS2589 at its `.selectFrom([…])`, and
//!   once a cheap warm-up statement PREPAYS that materialization the same
//!   chain's element type is correct and the consumer that fails in the app
//!   (`wantPerson(person)`) is clean. `asset.service.ts:127`'s one bad
//!   property (`deletedAt: unknown` for a `Timestamp | null` column) is the
//!   same: `Selectable<{ deletedAt: Timestamp | null }>` computed at the type
//!   level is byte-correct against the oracle. Both keys move when the
//!   TS2589 below moves, and not before.
//! * **`asset.repository.ts:192` and `ocr.repository.ts:33` TS2589** — the
//!   budget-order pair, untouched (the ceiling family is closed from five
//!   directions in this header). One new datum for whoever reopens it: the
//!   asymmetry is sharp and cheap to reproduce. `db.selectFrom(['person'])`
//!   — an ARRAY of ONE plain table — trips the 250 k statement cap where
//!   `db.selectFrom('person')` does not, in a 110-file program with immich's
//!   `DB` and nothing else, and its profile is ONE top-level `instantiate`
//!   charging 1,600,183 node visits of the statement's 6.17 M. Whichever
//!   `selectFrom([…])` is checked FIRST in a file pays and trips; every later
//!   one is clean. That is a single overload's cost, not a spread demand, and
//!   it is the first handle on this family that names one entry.
//!
//! ### Not an immich key, found on the way and left alone
//!
//! A bare enum-member reference inside an enum body (`enum E { A = 1, B = A }`)
//! is TS2304 in ztsc and clean in tsc: the binder declares no scope for an
//! enum body, so the member names are not resolvable as values there. It needs
//! a binder change, not a checker one.
//!
//! ## 5 -> 2: and the ceiling family closes for real (2026-08-05, 821d4d4)
//!
//! immich **5 -> 2 keys at c4 and c8, 4 -> 1 at c1, zero new keys at any
//! step**, byte-stable over three runs at each of c1/c4/c8. Three fixes, none
//! of them a budget experiment:
//!
//! * **A map's key binds through an INDEX SIGNATURE** (1232e47, conformance
//!   `mapped/064`). `substMappedKey` is gated on `mentionsMappedParam`, whose
//!   object arm walked the property list ALONE — no index signature, no
//!   call/construct signatures — so a template of the form `Record<string,
//!   F<M[K]>>` answered "does not mention K" and was returned untouched, the
//!   key staying FREE in the reduced type for the rest of the run. The
//!   substitution's own object arm had the mirror-image hole, masked by the
//!   predicate: it rebuilt the object from its properties, dropping both index
//!   signatures, the flags and every signature. Either fix alone is a
//!   regression. Closed `user.repository.ts:311` — kysely's `UpdateObject`
//!   slot reduced its `Expression<V>` half and left `DB[T][C]` standing in the
//!   `SelectQueryBuilderExpression<Record<string, V>>` half.
//! * **tsc's `couldContainTypeVariables` gate on `unify`** (e9cc773).
//!   `inferFromTypes` opens with it and ztsc had no equivalent; nothing in
//!   `unify` can record a candidate unless the PATTERN reaches a type
//!   parameter, and the walk it skips `resolveStructural`s BOTH sides.
//!   `TransactionBuilder.execute<T>(cb: (trx: Transaction<DB>) => Promise<T>)`
//!   is the shape: `T` lives only in the return, but the parameter position is
//!   walked too, and `Transaction<DB>` against the written `Kysely<DB>`
//!   expanded both classes over the 60-table schema. `ocr.repository.ts`'s
//!   `deleteAll` spent its whole 250,000-node budget there; it now costs under
//!   a thousand. Note the shape of the evidence: the DIRECT relation between
//!   the same two function types was always cheap, and writing
//!   `(trx: Transaction<DB>)` was always cheap — only inference paid.
//! * **An array literal's element context comes through the type variable's
//!   CONSTRAINT** (821d4d4, conformance `inference/086`). tsc's
//!   `getApparentTypeOfContextualType`; `checkArrayLiteral` already looked
//!   through the constraint for TUPLE context and not for the plain-array
//!   branch, so `db.selectFrom(['person'])` widened `'person'` to `string`,
//!   `TE` inferred `string[]`, and `From<DB, string>` degenerated its key set
//!   `keyof DB | ExtractAlias<DB, string>` to `string` — collapsing the schema
//!   to `{ [x: string]: <one table> }` ONCE PER TABLE, so the builder came
//!   back a sixty-constituent union and `person.getByName`'s row type was
//!   `{}`. `['person'] as const` and the hand-written type argument were both
//!   already byte-correct, which is the tell.
//!
//! ### The `selectFrom([…])` asymmetry was NOT a budget problem
//!
//! The entry above left `db.selectFrom(['person'])` tripping the cap where
//! `db.selectFrom('person')` does not, and read it as the last handle on the
//! budget family. It is the widening bug: the array form inferred `string[]`
//! and then evaluated `From<DB, string>` sixty times over. The cost was a
//! SYMPTOM of the wrong type argument, not the cause of the wrong answer — and
//! the two keys the header called "the truncation MASK"
//! (`search.service.ts:33`, `asset.service.ts:127`) were never masks either:
//! `search.service.ts` closed with the widening fix, and `asset.service.ts`
//! survives in a package where nothing truncates at all.
//!
//! **The ceiling family is closed with a counter, not an argument.** On the
//! whole package at `--checkers=1`, `--inst-profile` now reports **0 budget
//! trips** and a costliest statement of 147,303 of 250,000. No statement and
//! no declaration window in immich truncates. Any remaining excess is ordinary
//! type-system surface.
//!
//! ### The 2 that are left, and exactly what each is
//!
//! * **`asset.service.ts:127` TS2345** (c1, c4 and c8 — the only key at c1).
//!   `AssetRepository.update` returns a union of two branches and the SECOND
//!   one — the `with('asset', (qb) => qb.updateTable('asset')…returningAll())
//!   .selectFrom('asset').selectAll('asset').$call(withExif)…` chain — types
//!   `deletedAt` as `unknown`; every other property matches. Ruled out, each
//!   probed against the oracle in a scratch project: the `getById` branch
//!   (`Date | null`, correct), the `returningAll()` row read directly
//!   (correct), `Selectable<AssetTable>['deletedAt']` (correct), and
//!   `SelectType` applied once, twice, or to `Date | null` (all correct).
//!   `deletedAt` is the only NULLABLE `ColumnType` (`Timestamp | null`) in the
//!   table, so the trigger is a nullable column carried through a CTE that
//!   SHADOWS the table it selects from. The bisect needs care: the chain
//!   copied into a scratch project still trips the 250 k cap there (the
//!   package's other 600 files warm what it needs), so it has to be read off
//!   the app's own declaration — `NonNullable<Awaited<ReturnType<
//!   AssetRepository['update']>>>['deletedAt']` in a file that imports
//!   nothing else reproduces the `unknown` with the package's budget profile.
//! * **`asset.repository.ts:192` TS2589** (c4 and c8, not c1 — the same
//!   budget-order coin, now the ONLY one left). `upsertExif`'s
//!   `this.db.with('audio', (qb) => qb.insertInto('asset_audio')…)`. Profiled
//!   to a single frame: `instantiateSigForCall` of `QueryCreator.with<N, E>`
//!   charges **1,270,290 node visits in one entry**, and a depth-tagged charge
//!   dump puts ALL of it inside ONE type — the four-branch
//!   `ExtractRowFromCommonTableExpression<E>` conditional in the return type
//!   `QueryCreator<DB & { [K in ExtractTable…<N>]: … }>` — spread over
//!   thousands of sub-frames of which NONE exceeds 30,000. It is not the
//!   contextual typing (a pre-typed callback costs the same), not the
//!   inference (explicit type arguments cost the same), and not the reduction
//!   itself (the same conditional written out by hand against a concrete CTE
//!   type is cheap). It is the SUBSTITUTION of that conditional under the
//!   call's map. A SELECT-shaped CTE costs 26,584; the INSERT-shaped one costs
//!   the whole budget, which points at the branches that must fail
//!   (`Q extends Expression<infer QO>`) before the matching one is reached.
//!
//! ### Re-measured negatives from this session
//!
//! * **Arming `inferFromExtends`' `containsInfer` gate unconditionally**
//!   (today it arms only after `max_infer_steps`). Parity is now 8/8 at 0/0
//!   with it on — the 46-key drizzle regression its comment records no longer
//!   happens — and it takes the kysely repro 6.12 M -> 5.94 M node visits.
//!   But it moves ZERO immich keys and immich's wall went 4.2 -> 5.2 s in the
//!   same measurement. Not taken; the comment's reasoning about expansion
//!   ORDER still stands and there is nothing to buy.
//! * **A lib-free fixture for the `unify` gate.** Four shapes tried. The
//!   blocker is structural: ztsc expands a reference ONE level, so a deep
//!   synthetic interface tree costs nothing to `resolveStructural`, and any
//!   shape big enough to exceed the statement budget makes the RELATION pay
//!   it too — the immich case separates only because the relation short
//!   circuits on a derived-to-base pair while `unify` walks it structurally.
//!   Pinned by the app gate.
//!
//! ## CLOSED: immich is 0/0 (2026-08-05, 6585bbd + aa108cc)
//!
//! **immich reports ZERO diagnostics at `--checkers=1`, `4` and `8`, three
//! runs each, byte-stable, against a tsgo that is also clean — 0 excess and
//! 0 under.** The campaign that this header records from 498 keys down is
//! finished. Both remaining keys fell to ordinary type-system rules; neither
//! needed a budget experiment, and the ceiling family stayed closed.
//!
//! * **`asset.service.ts:127` TS2345 — an intersection did not factor out an
//!   irreducible nullish** (6585bbd, conformance
//!   `assignability/092_intersection_extracts_irreducible_nullish`). tsc's
//!   `extractIrreducible` runs in `getIntersectionType` BEFORE the cross
//!   product: when every member is a union containing `undefined` (then,
//!   separately, `null`), the nullish half survives no product, so
//!   `(A | null) & (B | null)` is `(A & B) | null` and not the four-way
//!   product. ztsc distributed instead, and the `null & <member>` products it
//!   left standing are only killed by `nullishIntersectionIsEmpty`, which is
//!   deliberately syntactic and cannot see through a `.ref`. So `null & Date`
//!   survived — and a distributive conditional MATCHES it (an intersection
//!   relates when one member does) while inferring nothing, so `infer S` fell
//!   back to `unknown` and poisoned the union.
//!
//!   `AssetRepository.update`'s second branch is a CTE named `asset` that
//!   SHADOWS the table it selects from, so `DB['asset']` is
//!   `AssetTable & <cte row>` and `deletedAt` — the only nullable
//!   `ColumnType` in the table — became
//!   `(Timestamp | null) & (Date | null)`. kysely's
//!   `SelectType<T> = T extends ColumnType<infer S, any, any> ? S : T` then
//!   answered `unknown` for that one column; every other property already
//!   matched, which is exactly what the previous session's probes had
//!   reported. It reproduces in twenty lines with `ColumnType` and `Date` and
//!   no query builder at all — the earlier warm-order caveat was about the
//!   BUILDER CHAIN, and the bug is one level below it.
//!
//! * **`asset.repository.ts:192` TS2589 — `substInfer` reduced a conditional
//!   chain bottom-up** (aa108cc, conformance
//!   `conditional/044_infer_subst_takes_one_branch`). `planConditional` /
//!   `CondPlan` (69a019d) taught `instantiateId` to DECIDE FIRST and
//!   substitute only the winning branch. `substInfer` — the pass that binds a
//!   conditional's own `infer` variables into the branch it selected — was
//!   never converted: it substituted the check, the extends clause and BOTH
//!   BRANCHES, then called `reduceConditional` on the four finished types.
//!
//!   That matters because the types this arm is handed are whole FALL-THROUGH
//!   CHAINS. An enclosing conditional binds an `infer` variable
//!   (`CTE extends (creator: QueryCreator<any>) => infer Q ? <chain> : never`),
//!   the chain under it was built while `Q` was still unbound so every level
//!   deferred symbolically, and each alternative therefore sits in the
//!   previous one's FALSE branch. Substituting both branches before reducing
//!   evaluates that chain BOTTOM-UP: the last alternative's relation runs
//!   first and EVERY alternative runs, however early the answer was found.
//!
//!   kysely's `ExtractRowFromCommonTableExpression<CTE>` is four alternatives
//!   deep (`Expression`, then the Insert/Update/Delete builders). An
//!   INSERT-shaped CTE matches the SECOND and still paid for the third and the
//!   fourth — which is why the previous session measured a SELECT-shaped CTE
//!   at 26,584 and this one at the whole budget: SELECT matches the FIRST
//!   alternative, so it never had a wrong branch to walk. The self-contained
//!   repro is one file, kysely only, no immich: a synthetic 60-table x
//!   17-column `DB` and `db.with('cte', (qb) => qb.insertInto('t0').values(v))`.
//!
//!       | | before | after |
//!       |---|---:|---:|
//!       | node visits (whole program) | 398,222 | **184,618** |
//!       | budget trips | 158 | **0** |
//!       | the one `instantiateSigForCall` of `with<N, E>` | 272,523 | **58,919** |
//!       | `expandRef(DeleteQueryBuilder)` | 195,201 / 204 calls | **20,740 / 8** |
//!
//!   204 expansions of `DeleteQueryBuilder` over a 60-table schema, in a
//!   program with no `deleteFrom` anywhere in it, is the whole bug in one
//!   number. tsgo checks the same file clean in 0.05 s.
//!
//!   The lib-free fixture needed one non-obvious thing: the alternatives have
//!   to be individually expensive enough that FOUR exceed a statement's
//!   250,000 nodes while ONE does not, which four generic builder-shaped
//!   interfaces over a 1,000-member template literal supply (~120 k each).
//!   Pre-fix it reports TS2589 and no answer; post-fix it is byte-identical to
//!   the oracle. Its negative controls re-run the same four-alternative
//!   selection over CHEAP marker interfaces so every alternative, the
//!   fall-off, the still-generic `need_both` defer, the `any` check's
//!   `both_any`, and the distributive-union case are all exercised.
//!
//! ### The end state, measured
//!
//! `--inst-profile` on the whole package at `--checkers=1`: **0 budget trips**
//! and a costliest statement of **40,066** of 250,000 (was 147,303 at the
//! previous entry, 250,001 three entries before that). Nothing in immich
//! truncates and nothing comes close.
//!
//! Both fixes are also net WORK, not just net keys — the whole package at
//! `--checkers=4` goes **4.76 s / 3.02 GB -> 3.96 s / 2.54 GB** (tsgo 7.0.2:
//! 3.00 s / 2.28 GB, clean). Every gate is unchanged: parity 8/8 at 0/0,
//! repeat 80/80, crash 128/128, excalidraw 17/0/0 CONVERGED, conformance
//! 1082 -> 1084, e2e multi flat.
//!
//! The instrument in this file has now done its job three times over and the
//! lesson each time was the same: **every remaining key was ordinary type-
//! system surface, and the profile was useful for LOCATING the frame, never
//! for diagnosing it.** The budget-ceiling family is closed from six
//! independent directions and should not be reopened without a trip counter
//! that is non-zero.

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

// =========================================================================
// DECLARATION-WINDOW TIME PROFILER (`--decl-profile`)
// =========================================================================
//
// A separate, much cheaper axis from everything above: not node visits and
// not budget trips, but WALL TIME, split between
//
//   * declaration materialization — the dynamic extent of an
//     `interfaceGeneric` / `classInstanceGeneric` / `aliasGeneric`
//     construction, and of an `expandRef` table construction; and
//   * everything else, i.e. source-element (statement) checking.
//
// It exists to price the *shared frozen declaration base* candidate
// (`checker.buildBaseStore`, "piece 2"): a pre-pass that materializes the
// declaration surface once and hands it to every checker would be SERIAL,
// so the declaration share of a single checker's check phase is a hard
// floor under wall clock however many checkers run afterwards.
//
// **Accounting, precisely.** A timestamp is taken only on the 0 -> 1 and
// 1 -> 0 transitions of `depth`, i.e. around the OUTERMOST window only.
// Every nested window (an `expandRef` inside a class's member table, an
// `interfaceGeneric` inside that) is inside some outermost window, so
// summing outermost durations counts each nanosecond exactly once — there
// is no double counting, and no need to subtract nested frames. The cost is
// two `Instant.now()` reads per outermost window, and there are a few
// thousand of them, so the instrument is invisible in the total (validate
// with the `clock reads` line in the report).
//
// Windows are opened AFTER the memo check in each of the four functions, so
// a memoized re-read is not a window and is charged to whatever it
// interrupted. `interfaceGeneric` calls `enterSymFile` before its memo
// check; the window still starts after it.
//
// Attribution is to the symbol that opened the OUTERMOST window, which is
// the unit a pre-pass would materialize: pre-building that symbol builds
// everything nested under it too.

/// Process-global switch, set once by `main` from `--decl-profile` before
/// any checker thread starts. Write-once before the pool spawns.
pub var decl_prof_on: bool = false;

pub fn declEnabled() bool {
    return decl_prof_on;
}

/// The four windows, with `expandRef` split by what the reference names —
/// the split the pre-pass decision turns on. `iface`/`class`/`alias` are the
/// RUN-ONCE-PER-SYMBOL generic forms (what a shared frozen base could
/// actually hold); an `expand_*` window is one SUBSTITUTION under one
/// argument list, of which a symbol has as many as its consumers ask for.
pub const DeclKind = enum(u8) {
    iface = 0,
    class = 1,
    alias = 2,
    expand_iface = 3,
    expand_class = 4,
    expand_alias = 5,
    expand_other = 6,
};
const n_kinds = 7;

/// Token returned by `declEnter`, handed back to `declExit`.
pub const DeclWin = struct { outer: bool = false };

const DeclTally = struct {
    ns: u64 = 0,
    calls: u64 = 0,
    max_ns: u64 = 0,

    fn add(t: *DeclTally, ns: u64) void {
        t.calls += 1;
        t.ns += ns;
        if (ns > t.max_ns) t.max_ns = ns;
    }
};

pub const DeclProf = struct {
    on: bool = false,
    /// Nesting depth of declaration windows.
    depth: u32 = 0,
    /// Start of the currently open OUTERMOST window, in ns.
    t0: u64 = 0,
    /// Symbol that opened the currently open outermost window.
    root: SymbolId = 0,
    root_kind: DeclKind = .iface,
    /// One entry per LIVE window, innermost last. Carries each frame's start
    /// and the time its children already consumed, so `declExit` can charge
    /// SELF time (exclusive of nested windows) to the frame's own symbol.
    stack: std.ArrayListUnmanaged(Frame) = .empty,
    /// Self (exclusive) time by symbol — the concentration measure. The
    /// inclusive-at-the-outermost-root measure (`by_sym`) is order-dependent:
    /// whichever declaration is demanded FIRST absorbs the whole cascade
    /// underneath it. Self time is not.
    self_by_sym: std.AutoHashMapUnmanaged(SymbolId, DeclTally) = .empty,
    /// Self time by kind.
    self_ns: [n_kinds]u64 = @splat(0),
    /// Sum of the outermost windows' durations. See the accounting note.
    total_ns: u64 = 0,
    /// Outermost windows opened (== clock read pairs).
    outermost: u64 = 0,
    /// Constructions by kind, at any depth (memo MISSES only).
    counts: [n_kinds]u64 = @splat(0),
    /// Outermost windows by kind, and their time.
    outer_counts: [n_kinds]u64 = @splat(0),
    outer_ns: [n_kinds]u64 = @splat(0),
    /// Outermost-window time by the root symbol that opened it.
    by_sym: std.AutoHashMapUnmanaged(SymbolId, DeclTally) = .empty,
    /// `checkStatement` / `checkExpr` entries made while a window was live —
    /// the "nested statement work" the accounting would otherwise hide.
    nested_stmts: u64 = 0,
    nested_exprs: u64 = 0,
    /// Total entries, for scale.
    total_exprs: u64 = 0,
    total_stmts: u64 = 0,
    /// OUTERMOST-under-a-window `checkExpr` entries and their inclusive time —
    /// an UPPER BOUND on the source-element-shaped work that happens inside a
    /// declaration window (upper, because a nested `expandRef` opened from
    /// inside such an expression is counted here too).
    expr_in_decl_depth: u32 = 0,
    expr_in_decl_t0: u64 = 0,
    expr_in_decl_roots: u64 = 0,
    expr_in_decl_ns: u64 = 0,
    expr_in_decl_node: u64 = 0,
    /// Those roots by source position (`file << 32 | pos`).
    expr_sites: std.AutoHashMapUnmanaged(u64, DeclTally) = .empty,
    /// `instantiate` node visits charged inside an outermost window — a
    /// second, clock-free corroboration of the time split.
    visits_t0: u64 = 0,
    visits_in_decl: u64 = 0,
    /// The whole check phase (`Checker.run`).
    run_ns: u64 = 0,
    run_t0: u64 = 0,

    pub fn deinit(p: *DeclProf, gpa: std.mem.Allocator) void {
        p.by_sym.deinit(gpa);
        p.self_by_sym.deinit(gpa);
        p.stack.deinit(gpa);
        p.expr_sites.deinit(gpa);
    }

    const Frame = struct {
        sym: SymbolId,
        kind: DeclKind,
        t0: u64,
        child_ns: u64,
    };
};

/// Monotonic nanoseconds. `CLOCK_UPTIME_RAW` on macOS, `CLOCK_MONOTONIC` on
/// Linux — the same clock `main.zig`'s phase `Timer` reads, so the check-phase
/// figure here is directly comparable with `--timing`'s.
fn nowNs(c: *Checker) u64 {
    const ts = std.Io.Clock.now(.awake, c.io);
    const ns = ts.nanoseconds;
    return if (ns > 0) @intCast(ns) else 0;
}

/// Open a declaration-materialization window for `sym`. Call AFTER the
/// memo check, so a memoized re-read is not a window.
pub fn declEnter(c: *Checker, sym: SymbolId, kind: DeclKind) DeclWin {
    if (!c.dprof.on) return .{};
    const p = &c.dprof;
    p.counts[@intFromEnum(kind)] += 1;
    const outer = p.depth == 0;
    p.depth += 1;
    if (outer) {
        p.root = sym;
        p.root_kind = kind;
        p.outermost += 1;
        p.outer_counts[@intFromEnum(kind)] += 1;
        p.visits_t0 = c.inst_total;
    }
    const t0 = nowNs(c);
    if (outer) p.t0 = t0;
    p.stack.append(c.gpa, .{ .sym = sym, .kind = kind, .t0 = t0, .child_ns = 0 }) catch {};
    return .{ .outer = outer };
}

pub fn declExit(c: *Checker, w: DeclWin) void {
    if (!c.dprof.on) return;
    const p = &c.dprof;
    p.depth -= 1;
    const now = nowNs(c);
    if (p.stack.pop()) |fr| {
        const dur = now - fr.t0;
        const self = dur - @min(dur, fr.child_ns);
        p.self_ns[@intFromEnum(fr.kind)] += self;
        if (p.self_by_sym.getOrPut(c.gpa, fr.sym)) |gop| {
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.add(self);
        } else |_| {}
        if (p.stack.items.len > 0) p.stack.items[p.stack.items.len - 1].child_ns += dur;
    }
    if (!w.outer) return;
    const ns = now - p.t0;
    p.visits_in_decl += c.inst_total - p.visits_t0;
    p.total_ns += ns;
    p.outer_ns[@intFromEnum(p.root_kind)] += ns;
    if (p.by_sym.getOrPut(c.gpa, p.root)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(ns);
    } else |_| {}
}

/// A `checkStatement` entry (any depth).
pub fn noteStmtEntry(c: *Checker) void {
    c.dprof.total_stmts += 1;
    if (c.dprof.depth > 0) c.dprof.nested_stmts += 1;
}

/// A `checkExpr` entry (any depth). Opens a timing window only for the
/// OUTERMOST expression entered while a declaration window is live.
pub fn exprEnter(c: *Checker, node: u32) DeclWin {
    c.dprof.total_exprs += 1;
    if (c.dprof.depth == 0) return .{};
    c.dprof.nested_exprs += 1;
    const outer = c.dprof.expr_in_decl_depth == 0;
    c.dprof.expr_in_decl_depth += 1;
    if (outer) {
        c.dprof.expr_in_decl_roots += 1;
        c.dprof.expr_in_decl_node = (@as(u64, c.cur_file) << 32) | c.nodeSpanStart(node);
        c.dprof.expr_in_decl_t0 = nowNs(c);
    }
    return .{ .outer = outer };
}

pub fn exprExit(c: *Checker, w: DeclWin) void {
    if (c.dprof.expr_in_decl_depth == 0) return;
    c.dprof.expr_in_decl_depth -= 1;
    if (!w.outer) return;
    const ns = nowNs(c) - c.dprof.expr_in_decl_t0;
    c.dprof.expr_in_decl_ns += ns;
    if (c.dprof.expr_sites.getOrPut(c.gpa, c.dprof.expr_in_decl_node)) |gop| {
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(ns);
    } else |_| {}
}

pub fn declRunStart(c: *Checker) void {
    if (!c.dprof.on) return;
    c.dprof.run_t0 = nowNs(c);
}

pub fn declRunEnd(c: *Checker) void {
    if (!c.dprof.on) return;
    c.dprof.run_ns = nowNs(c) - c.dprof.run_t0;
}

fn labelDeclSym(c: *Checker, sym: SymbolId, w: *std.Io.Writer) void {
    w.print("{s}", .{c.symbolName(sym)}) catch {};
    const f = c.symFile(sym);
    w.print("  [{s}]", .{c.prog.files[f].path}) catch {};
}

/// Render the declaration-window profile to stderr. Called from `seal`.
pub fn declReport(c: *Checker) void {
    const gpa = c.gpa;
    var buf: [64 * 1024]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), c.io, &buf);
    const w = &stderr.interface;
    const p = &c.dprof;
    const run_ms = @as(f64, @floatFromInt(p.run_ns)) / 1e6;
    const decl_ms = @as(f64, @floatFromInt(p.total_ns)) / 1e6;
    w.print("\n=== ztsc declaration-window profile (checker owning {d} file(s)) ===\n", .{c.owned.len}) catch {};
    w.print("check phase (Checker.run):   {d:.1} ms\n", .{run_ms}) catch {};
    w.print("declaration windows:         {d:.1} ms  ({d:.2}% of check phase)\n", .{
        decl_ms, if (p.run_ns == 0) 0.0 else 100.0 * decl_ms / run_ms,
    }) catch {};
    w.print("source-element remainder:    {d:.1} ms\n", .{run_ms - decl_ms}) catch {};
    w.print("outermost windows: {d}  (clock reads: {d})\n", .{
        p.outermost, 2 * (p.outermost + p.expr_in_decl_roots),
    }) catch {};
    w.print("nested checkStatement entries: {d} of {d}   nested checkExpr entries: {d} of {d}\n", .{
        p.nested_stmts, p.total_stmts, p.nested_exprs, p.total_exprs,
    }) catch {};
    w.print("statement-shaped work INSIDE windows (upper bound): {d:.1} ms over {d} roots ({d:.2}% of window time)\n", .{
        @as(f64, @floatFromInt(p.expr_in_decl_ns)) / 1e6,
        p.expr_in_decl_roots,
        if (p.total_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.expr_in_decl_ns)) / @as(f64, @floatFromInt(p.total_ns)),
    }) catch {};
    w.print("instantiate node visits: {d} inside windows of {d} total ({d:.2}%)\n", .{
        p.visits_in_decl,                                                                                                          c.inst_total,
        if (c.inst_total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.visits_in_decl)) / @as(f64, @floatFromInt(c.inst_total)),
    }) catch {};

    w.writeAll("\n-- constructions by kind (memo misses) --\n") catch {};
    const names = [_][]const u8{
        "interfaceGeneric", "classInstanceGeneric", "aliasGeneric",
        "expandRef/iface",  "expandRef/class",      "expandRef/alias",
        "expandRef/other",
    };
    var self_sum: u64 = 0;
    for (p.self_ns) |v| self_sum += v;
    for (names, 0..) |n, i| {
        w.print("  {s:<22} {d:>8} built  {d:>7} outermost  {d:>9.2} ms incl(outer)  {d:>9.2} ms self\n", .{
            n,                                            p.counts[i],                                 p.outer_counts[i],
            @as(f64, @floatFromInt(p.outer_ns[i])) / 1e6, @as(f64, @floatFromInt(p.self_ns[i])) / 1e6,
        }) catch {};
    }
    w.print("  self total {d:.2} ms vs outermost-inclusive total {d:.2} ms (must agree)\n", .{
        @as(f64, @floatFromInt(self_sum)) / 1e6, decl_ms,
    }) catch {};
    w.print("  run-once generic forms (iface+class+alias): {d:.2} ms = {d:.2}% of window time, {d:.2}% of check phase\n", .{
        @as(f64, @floatFromInt(p.self_ns[0] + p.self_ns[1] + p.self_ns[2])) / 1e6,
        if (self_sum == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.self_ns[0] + p.self_ns[1] + p.self_ns[2])) / @as(f64, @floatFromInt(self_sum)),
        if (p.run_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.self_ns[0] + p.self_ns[1] + p.self_ns[2])) / @as(f64, @floatFromInt(p.run_ns)),
    }) catch {};
    w.print("  memoized expansions surviving at seal: {d} (of {d} expandRef constructions)\n", .{
        c.expansions.count(), p.counts[3] + p.counts[4] + p.counts[5] + p.counts[6],
    }) catch {};

    w.writeAll("\n-- statement-shaped roots INSIDE declaration windows (top 20) --\n") catch {};
    {
        const Row = struct {
            key: u64,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it = p.expr_sites.iterator();
        while (it.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
        std.mem.sort(Row, rows.items, {}, Row.desc);
        for (rows.items[0..@min(20, rows.items.len)]) |r| {
            const fid: FileId = @intCast(r.key >> 32);
            const f = &c.prog.files[fid];
            const line, const col = lineCol(f.src, @truncate(r.key));
            w.print("  {d:>10.3} ms {d:>6} x  {s}:{d}:{d}\n", .{
                @as(f64, @floatFromInt(r.t.ns)) / 1e6, r.t.calls, f.path, line, col,
            }) catch {};
        }
    }

    w.writeAll("\n-- declaration-window time by root symbol (top 60) --\n") catch {};
    {
        const Row = struct {
            key: SymbolId,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it = p.by_sym.iterator();
        while (it.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
        std.mem.sort(Row, rows.items, {}, Row.desc);
        w.print("  distinct root symbols: {d}\n", .{rows.items.len}) catch {};
        var cum: u64 = 0;
        for (rows.items[0..@min(60, rows.items.len)], 0..) |r, i| {
            cum += r.t.ns;
            w.print("  {d:>4} {d:>10.3} ms {d:>7} win  cum {d:>6.2}%  ", .{
                i + 1,
                @as(f64, @floatFromInt(r.t.ns)) / 1e6,
                r.t.calls,
                if (p.total_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(cum)) / @as(f64, @floatFromInt(p.total_ns)),
            }) catch {};
            labelDeclSym(c, r.key, w);
            w.writeAll("\n") catch {};
        }
        // Concentration curve: cumulative share at a few cut points.
        w.writeAll("\n-- concentration curve (cumulative share of declaration time) --\n") catch {};
        const cuts = [_]usize{ 1, 5, 10, 20, 50, 100, 200, 400, 800, 1600, 3200 };
        var acc: u64 = 0;
        var idx: usize = 0;
        for (cuts) |k| {
            if (idx >= rows.items.len) break;
            while (idx < @min(k, rows.items.len)) : (idx += 1) acc += rows.items[idx].t.ns;
            w.print("  top {d:>5} roots: {d:>6.2}%  ({d:.1} ms)\n", .{
                @min(k, rows.items.len),
                if (p.total_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(acc)) / @as(f64, @floatFromInt(p.total_ns)),
                @as(f64, @floatFromInt(acc)) / 1e6,
            }) catch {};
        }
    }

    w.writeAll("\n-- SELF (exclusive) declaration time by symbol, top 40 + concentration --\n") catch {};
    {
        const Row = struct {
            key: SymbolId,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it = p.self_by_sym.iterator();
        var tot: u64 = 0;
        while (it.next()) |e| {
            rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
            tot += e.value_ptr.ns;
        }
        std.mem.sort(Row, rows.items, {}, Row.desc);
        w.print("  distinct declarations: {d}   self total {d:.2} ms\n", .{
            rows.items.len, @as(f64, @floatFromInt(tot)) / 1e6,
        }) catch {};
        var cum: u64 = 0;
        for (rows.items[0..@min(40, rows.items.len)], 0..) |r, i| {
            cum += r.t.ns;
            w.print("  {d:>4} {d:>10.3} ms {d:>7} win  cum {d:>6.2}%  ", .{
                i + 1,
                @as(f64, @floatFromInt(r.t.ns)) / 1e6,
                r.t.calls,
                if (tot == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(cum)) / @as(f64, @floatFromInt(tot)),
            }) catch {};
            labelDeclSym(c, r.key, w);
            w.writeAll("\n") catch {};
        }
        w.writeAll("\n-- concentration curve on SELF time --\n") catch {};
        const cuts = [_]usize{ 1, 5, 10, 20, 50, 100, 200, 400, 800, 1600, 3200, 6400 };
        var acc: u64 = 0;
        var idx: usize = 0;
        for (cuts) |k| {
            if (idx >= rows.items.len) break;
            while (idx < @min(k, rows.items.len)) : (idx += 1) acc += rows.items[idx].t.ns;
            w.print("  top {d:>5} decls: {d:>6.2}%  ({d:.1} ms)\n", .{
                @min(k, rows.items.len),
                if (tot == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(acc)) / @as(f64, @floatFromInt(tot)),
                @as(f64, @floatFromInt(acc)) / 1e6,
            }) catch {};
        }
    }

    // Per-FILE roll-up of the same time.
    w.writeAll("\n-- SELF declaration time by originating file (top 25) --\n") catch {};
    {
        var by_file: std.AutoHashMapUnmanaged(FileId, DeclTally) = .empty;
        defer by_file.deinit(gpa);
        var it = p.self_by_sym.iterator();
        while (it.next()) |e| {
            const f = c.symFile(e.key_ptr.*);
            if (by_file.getOrPut(gpa, f)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.ns += e.value_ptr.ns;
                gop.value_ptr.calls += e.value_ptr.calls;
            } else |_| {}
        }
        const Row = struct {
            key: FileId,
            t: DeclTally,
            fn desc(_: void, a: @This(), b: @This()) bool {
                return a.t.ns > b.t.ns;
            }
        };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        defer rows.deinit(gpa);
        var it2 = by_file.iterator();
        while (it2.next()) |e| rows.append(gpa, .{ .key = e.key_ptr.*, .t = e.value_ptr.* }) catch {};
        std.mem.sort(Row, rows.items, {}, Row.desc);
        w.print("  distinct files: {d}\n", .{rows.items.len}) catch {};
        for (rows.items[0..@min(25, rows.items.len)]) |r| {
            w.print("  {d:>10.3} ms {d:>7} win  {s}\n", .{
                @as(f64, @floatFromInt(r.t.ns)) / 1e6, r.t.calls, c.prog.files[r.key].path,
            }) catch {};
        }
    }
    w.flush() catch {};
}
