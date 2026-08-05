// `substInfer` — the pass that binds a conditional's own `infer` variables
// into the branch it selected — has to make the same DECIDE-FIRST split that
// `instantiateId` makes (see `CondPlan` / `planConditional`), and it did not:
// it substituted the check, the extends clause AND BOTH BRANCHES, then called
// `reduceConditional` on the four finished types.
//
// That is not merely eager. The types this arm is handed are whole FALL-
// THROUGH CHAINS — an enclosing conditional binds an `infer` variable
// (`F extends (x: unknown) => infer Q ? <chain over Q> : never`) and the chain
// underneath it was built while `Q` was still unbound, so every level deferred
// symbolically and each alternative sits in the previous one's FALSE branch.
// Substituting both branches before reducing therefore evaluates the chain
// BOTTOM-UP: the last alternative's relation runs first, and every alternative
// runs, even though the answer is the first one that matches.
//
// The cost is the whole point. Each alternative here relates a source against
// a generic builder interface, which materializes that interface's member
// table under a fresh `infer` variable; four of those exceed a statement's
// 250,000-node instantiation budget while one is comfortably under it. So a
// source matching the FIRST alternative used to truncate to `error_type` and
// report TS2589 — where the oracle, and ztsc today, simply answer `[1, {r:
// string}]`.
//
// kysely's `ExtractRowFromCommonTableExpression<CTE>` is this shape verbatim
// (an `Expression` alternative, then the Insert/Update/Delete query builders),
// and immich's `asset.repository.ts:192` — an INSERT-shaped common table
// expression, which matches the SECOND alternative — paid for the third and
// the fourth: 204 expansions of `DeleteQueryBuilder` over a 60-table schema in
// a program with no `deleteFrom` anywhere in it, inside a single
// `instantiateSigForCall` of `QueryCreator.with<N, E>` that charged 272,523
// nodes against a 250,000 budget. A SELECT-shaped CTE matches the FIRST
// alternative and never showed it.

type D = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9';
type W = `${D}${D}${D}`;
type Cross<K, U> = U extends string ? `${K & string}.${U}` | `${U}.${K & string}` : never;

interface B1<S, O> {
  a<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B1<S, O & V>;
  b<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B1<S, O & V>;
  c<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B1<S, O & V>;
  o1: O;
  s1: S;
}
interface B2<S, O> {
  a<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B2<S, O & V>;
  b<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B2<S, O & V>;
  c<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B2<S, O & V>;
  o2: O;
  s2: S;
}
interface B3<S, O> {
  a<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B3<S, O & V>;
  b<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B3<S, O & V>;
  c<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B3<S, O & V>;
  o3: O;
  s3: S;
}
interface B4<S, O> {
  a<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B4<S, O & V>;
  b<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B4<S, O & V>;
  c<R extends W, V extends { [K in R]: Cross<K, W> }>(l: R, v: V): B4<S, O & V>;
  o4: O;
  s4: S;
}

type Chain<F> = F extends (x: unknown) => infer Q
  ? Q extends B1<any, infer QO>
    ? [1, QO]
    : Q extends B2<any, infer QO>
      ? [2, QO]
      : Q extends B3<any, infer QO>
        ? [3, QO]
        : Q extends B4<any, infer QO>
          ? [4, QO]
          : never
  : never;

// The case. The first alternative matches, so exactly one builder interface
// may be materialized; the assignment names the answer, and there must be no
// TS2589 beside it.
declare const f1: (x: unknown) => B1<string, { r: string }>;
export const got1: [1, { r: string }] = null as any as Chain<typeof f1>;
export const bad1: number = null as any as Chain<typeof f1>;

// --- negative controls -----------------------------------------------------
// The selection itself must be unchanged, so the same four-alternative chain
// is written over CHEAP marker interfaces (nothing here can trip a budget) and
// every alternative, plus the fall-off, is exercised.

interface C1<O> {
  k1: O;
}
interface C2<O> {
  k2: O;
}
interface C3<O> {
  k3: O;
}
interface C4<O> {
  k4: O;
}

type Cheap<F> = F extends (x: unknown) => infer Q
  ? Q extends C1<infer QO>
    ? [1, QO]
    : Q extends C2<infer QO>
      ? [2, QO]
      : Q extends C3<infer QO>
        ? [3, QO]
        : Q extends C4<infer QO>
          ? [4, QO]
          : ['none', Q]
  : 'not-a-function';

declare const g1: (x: unknown) => C1<'a'>;
declare const g2: (x: unknown) => C2<'b'>;
declare const g3: (x: unknown) => C3<'c'>;
declare const g4: (x: unknown) => C4<'d'>;
declare const g5: (x: unknown) => { other: true };
export const c1: [1, 'a'] = null as any as Cheap<typeof g1>;
export const c2: [2, 'b'] = null as any as Cheap<typeof g2>;
export const c3: [3, 'c'] = null as any as Cheap<typeof g3>;
export const c4: [4, 'd'] = null as any as Cheap<typeof g4>;
export const c5: ['none', { other: true }] = null as any as Cheap<typeof g5>;
export const c6: 'not-a-function' = null as any as Cheap<string>;
// …and the fourth alternative really is the one that answered, not the third.
export const cbad: [3, 'd'] = null as any as Cheap<typeof g4>;

// Negative control: a chain whose check is still GENERIC when the outer
// `infer` is bound must keep BOTH branches (`need_both` / defer), so the
// conditional stays symbolic and reduces later, per type argument.
type Defer<F, T> = F extends (x: unknown) => infer Q ? (T extends Q ? 'yes' : 'no') : never;
declare const h: (x: unknown) => string;
export const d1: 'yes' = null as any as Defer<typeof h, 'lit'>;
export const d2: 'no' = null as any as Defer<typeof h, number>;
export const dbad: 'yes' = null as any as Defer<typeof h, number>;

// Negative control: an `any` check takes BOTH branches (`both_any`), and that
// arm is reached through this same substitution.
type Both<F> = F extends (x: unknown) => infer Q ? (Q extends string ? 'S' : 'N') : never;
declare const anyf: (x: unknown) => any;
export const b1: 'S' | 'N' = null as any as Both<typeof anyf>;
export const bbad: 'S' = null as any as Both<typeof anyf>;

// Negative control: a DISTRIBUTIVE conditional whose check is the bound
// `infer` variable must still distribute over its union, member by member.
type Dist<F> = F extends (x: unknown) => infer Q ? (Q extends string ? ['s', Q] : ['n', Q]) : never;
declare const uf: (x: unknown) => 'x' | 1;
export const u1: ['s', 'x'] | ['n', 1] = null as any as Dist<typeof uf>;
export const ubad: ['s', 'x'] = null as any as Dist<typeof uf>;
