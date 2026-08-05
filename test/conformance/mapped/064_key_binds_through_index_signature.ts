// A mapped type's key parameter has to be bound everywhere its template
// mentions it — including inside an INDEX SIGNATURE, a call signature or a
// construct signature, not only in a named property.
//
// `substMappedKey` is gated on `mentionsMappedParam`, and that predicate's
// object arm walked the property list alone. `Record<string, V>` materializes
// to `{ [x: string]: V }`, so a template of the form `Record<string, F<M[K]>>`
// answered "does not mention K" and was returned untouched: the key stayed
// FREE in the reduced type forever, and the property then related to nothing.
// (Fixing the predicate alone would have been worse — the substitution's own
// object arm rebuilt the shape from its properties, dropping both index
// signatures and every call/construct signature.)
//
// kysely's `UpdateObject` is the shape this was found on:
//
//     { [C in AnyColumn<DB, UT>]?: {
//         [T in UT]: C extends keyof DB[T]
//           ? ValueExpression<DB, TB, UpdateType<DB[T][C]>> | undefined
//           : never }[UT] }
//
// where `ValueExpression` reaches `SelectQueryBuilderExpression<Record<string,
// V>>`. The `Expression<V>` half of the same union reduced correctly and the
// `Record<string, V>` half kept `DB[T][C]` unsubstituted, so a subquery-valued
// update column (`.set({ col: (eb) => eb.selectFrom(…)… })`) was TS2769.

type Rec<K extends string, T> = { [P in K]: T };
type Cond<T> = T extends { u: infer U } ? U : T;

// The index signature is the slot that used to be skipped.
type ThroughIndex<M> = { [C in keyof M]: Rec<string, Cond<M[C]>> };
declare const idx: ThroughIndex<{ a: { u: number } }>['a'];
export const i1: number = idx.anything;

// A call signature in the template is the same question.
type ThroughCall<M> = { [C in keyof M]: { (arg: M[C]): M[C] } };
declare const call: ThroughCall<{ a: string }>['a'];
export const c1: string = call('x');

// And a construct signature.
type ThroughCtor<M> = { [C in keyof M]: { new (arg: M[C]): M[C] } };
declare const ctor: ThroughCtor<{ a: string }>['a'];
export const n1: string = new ctor('x');

// Negative control (a): the key must NOT be bound where an inner map's own
// binder shadows it, and a plain property must still substitute as before.
type Named<M> = { [C in keyof M]: { v: Cond<M[C]> } };
declare const named: Named<{ a: { u: boolean } }>['a'];
export const v1: boolean = named.v;

// Negative control (b): a wrong-typed read off the index signature is still an
// error — the slot really is `number` now, not a free parameter and not `any`.
export const bad: string = idx.anything;

// Negative control (c): the properties, the index signature and the signatures
// coexist on one template, and all four survive the substitution together.
type All<M> = {
  [C in keyof M]: {
    named: M[C];
    [x: string]: M[C];
    (arg: M[C]): M[C];
  };
};
declare const all: All<{ a: number }>['a'];
export const a1: number = all.named;
export const a2: number = all.other;
export const a3: number = all(1);
export const a4: string = all.named;
