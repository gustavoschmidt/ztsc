// Defect: an alias body's OWN type param, once its (memoized) generic body is
// materialized, was bound to a same-named `infer` binder of the *referencing*
// declaration instead of to itself — an order-dependent scoping leak. Here
// `PImpl<K, V, Tr>` names a param `V`, and `PInt<T>`'s ARRAY branch introduces
// its own `infer V`. For an OBJECT `F` the array branch is UNTAKEN, yet
// `PImpl`'s `V` wrongly resolved to that untaken `infer V` (and its `K` to the
// mapped key of the object branch), so `PImpl` never reduced and the field-name
// union leaked a deferred `infer V extends … ? …`, rejecting every path.
//
// Fix (tp_shadow): while an alias body is materialized, its own param names
// shadow any same-named outer `infer`/mapped binder (tsc lexical scoping), so
// `PImpl`'s `V`/`K` bind to its own params and the union reduces to the flat
// dotted-path literal union. Only *colliding* names are hidden; see the 021
// negative control for a live outer infer that must stay visible.
type Prim = string | number | boolean | null | undefined;
type ArrayKey = number;
type IsTuple<T extends readonly any[]> = number extends T["length"] ? false : true;
type TupleKeys<T extends readonly any[]> = Exclude<keyof T, keyof any[]>;
type IsEq<A, B> = (<G>() => G extends A ? 1 : 2) extends (<G>() => G extends B ? 1 : 2) ? true : false;
type AnyIsEqual<T1, T2> = T1 extends T2 ? (IsEq<T1, T2> extends true ? true : never) : never;
type PImpl<K extends string | number, V, Tr> = V extends Prim
  ? `${K}`
  : true extends AnyIsEqual<Tr, V>
    ? `${K}`
    : `${K}` | `${K}.${PInt<V, Tr | V> & string}`;
export type PInt<T, Tr = T> = T extends ReadonlyArray<infer V>
  ? IsTuple<T> extends true
    ? { [K in TupleKeys<T>]-?: PImpl<K & string, T[K], Tr> }[TupleKeys<T>]
    : PImpl<ArrayKey, V, Tr>
  : { [K in keyof T]-?: PImpl<K & string, T[K], Tr> }[keyof T];
export type DPath<T> = T extends any ? PInt<T> : never;
