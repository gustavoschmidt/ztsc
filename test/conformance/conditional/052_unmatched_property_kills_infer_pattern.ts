// `T extends Pat<infer U> ? U : F` where `Pat`'s member table declares a
// required property the source has not got: the extends check is false for
// EVERY binding of `U`, so the conditional resolves to `F` and nothing the
// match would have bound is observable.
//
// ztsc used to reach that verdict the expensive way round — it materialized
// `Pat<infer U>`'s whole member table first, then walked it property by
// property looking each name up on the source, and every name that is not
// shared was substituted for nothing. On kysely's
// `ExtractRowFromCommonTableExpression<CTE>`, which asks a builder against
// `Expression<infer QO>`, `InsertQueryBuilder<any, any, infer QO>` and
// `UpdateQueryBuilder<any, any, any, infer QO>` in turn, each of those three
// pairs is dead on a single name (`expressionType`, `values`, `set`) and each
// table is ~35 members of mapped and conditional types over every column of
// every table in the schema. One `db.with('x', cb)` spent the whole 250,000-node
// statement budget there, so whether it resolved at all depended on which
// checker's partition had already paid for those tables — the same statement
// was clean at `--checkers=1` and TS2589 at `--checkers=3`.
//
// This pins the verdicts the name-only screen has to leave alone. The screen
// answers off the generic member table (names and optionality carry through a
// substitution untouched) and fires only where the pattern IS the whole extends
// clause, so every case below must read exactly as it did before.

// -- the screen's own case: a required pattern property the source lacks -----

interface Pat<T> {
  needed: T;
  shared: T;
}

interface LacksNeeded {
  other: string;
  shared: number;
}

type Bind<T> = T extends Pat<infer U> ? U : 'fell-through';

declare const b1: Bind<LacksNeeded>;
const b1ok: 'fell-through' = b1;
const b1bad: number = b1; // TS2322: the false branch, not `U = number`

// -- and it must NOT fire when every required name is present ---------------

interface HasBoth {
  needed: number;
  shared: number;
}

declare const b2: Bind<HasBoth>;
const b2ok: number = b2;
const b2bad: 'fell-through' = b2; // TS2322

// -- an OPTIONAL pattern property the source lacks is not a mismatch --------

interface PatOpt<T> {
  needed?: T;
  shared: T;
}

type BindOpt<T> = T extends PatOpt<infer U> ? U : 'fell-through';

declare const b3: BindOpt<LacksNeeded>;
const b3ok: number = b3; // `needed` optional, so `shared` still binds U
const b3bad: 'fell-through' = b3; // TS2322

// -- the name may come from a BASE, so the screen has to read the table with
//    its `extends` bases folded in and not the declaration's own members ----

interface NeedBase {
  needed: number;
}

interface InheritsNeeded extends NeedBase {
  shared: number;
}

declare const b4: Bind<InheritsNeeded>;
const b4ok: number = b4;
const b4bad: 'fell-through' = b4; // TS2322

// -- an INTERSECTION source supplies the name from whichever constituent
//    declares it ------------------------------------------------------------

declare const b9: Bind<{needed: number} & {shared: number}>;
const b9ok: number = b9;
const b9bad: 'fell-through' = b9; // TS2322

// -- DEPTH: a union pattern's dead constituent still contributes a candidate,
//    so the screen must not reach a constituent one level down ---------------

interface OnlyA<T> {
  onlyA: T;
}

interface OnlyB<T> {
  onlyB: T;
}

interface HasBOnly {
  onlyB: string;
}

type FromUnion<T> = T extends OnlyA<infer U> | OnlyB<infer U> ? U : 'fell-through';

declare const b5: FromUnion<HasBOnly>;
const b5ok: string = b5;
const b5bad: 'fell-through' = b5; // TS2322

// -- the same generic on both sides is the variance question, not a name
//    scan: `Pat<string>` against `Pat<infer U>` must still bind ------------

declare const b6: Bind<Pat<string>>;
const b6ok: string = b6;
const b6bad: 'fell-through' = b6; // TS2322

// -- a CLASS pattern reads the same way as an interface one -----------------

declare class CPat<T> {
  needed: T;
  shared: T;
}

type BindC<T> = T extends CPat<infer U> ? U : 'fell-through';

declare const b7: BindC<LacksNeeded>;
const b7ok: 'fell-through' = b7;
const b7bad: number = b7; // TS2322

declare const b8: BindC<HasBoth>;
const b8ok: number = b8;
const b8bad: 'fell-through' = b8; // TS2322
