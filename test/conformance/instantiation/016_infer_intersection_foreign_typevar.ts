// Inferring an `infer` var from an INTERSECTION whose sibling is a foreign
// (signature-local) type variable must NOT drag the residual source into the
// infer var: tsc poisons the inference and the var falls back to its
// constraint. Only *concrete* siblings cancel and let the remainder residual.
//
// This is the redux `StoreEnhancer<Ext>` shape — a generic function type whose
// return is `StoreEnhancerStoreCreator<NextExt & Ext, …>`. Before the fix,
// `Enh extends StoreEnhancer<infer Ext>` (Enh a distinct alias, so inference is
// structural, not the same-ref argument-wise fast path) pulled the whole nested
// `NextExt & {dispatch} & Store<unknown,…>` return into `Ext`; the bogus
// `Store<unknown>` then collided with the real store in the dogfood project's
// `EnhancedStore`, collapsing `getState`/`dispatch`. tsc isolates `Ext` to its
// constraint instead.
//
// Each assertion routes the inferred `Ext` through a discriminator conditional
// so the CORRECT and the OLD-BUGGY answers land on opposite sides of a
// string-literal mismatch — the diagnostic is an identical TS2322 on both the
// oracle and ztsc regardless of whether the poisoned var reads as `{}` (tsc's
// constraint) or `unknown` (ztsc has no infer-var constraint tracking).

// POISON: a DISTINCT source alias (Enh) forces structural inference through the
// generic signature `<N>(x: N) => N & E`; sibling `N` is a foreign type
// variable, so E must NOT capture {a:1}. Correct -> "OK" -> ERROR (asserted
// "BUG"); the old full-capture bug (E = {a:1}) -> "BUG" -> clean.
type Fn<E extends {} = {}> = <N>(x: N) => N & E;
type Enh = Fn<{ a: 1 }>;
type Poison = Enh extends Fn<infer E> ? (E extends { a: 1 } ? "BUG" : "OK") : "no";
const _p: "BUG" = 0 as unknown as Poison;

// POISON, nested through a shared generic-alias return (full redux nesting).
type Inner<E extends {} = {}> = <S>(s: S) => S & E;
type Outer<E extends {} = {}> = <N extends {}>(next: Inner<N>) => Inner<N & E>;
type EnhN = Outer<{ a: 1 }>;
type PoisonNested = EnhN extends Outer<infer E> ? (E extends { a: 1 } ? "BUG" : "OK") : "no";
const _pn: "BUG" = 0 as unknown as PoisonNested;

// RESIDUAL (concrete sibling): `number` cancels, E captures the remainder
// {a:1} and NOT the whole `number & {a:1}`. Correct -> "OK" -> clean; the old
// whole-capture (E includes `number`) -> "LEAK" -> would error.
type FnC<E extends {} = {}> = (x: number) => number & E;
type EnhC = FnC<{ a: 1 }>;
type Residual = EnhC extends FnC<infer E> ? ([E] extends [number] ? "LEAK" : "OK") : "no";
const _r: "OK" = 0 as unknown as Residual;

// NEGATIVE CONTROL (same-ref, object): argument-wise, E binds {a:1} -> clean.
type Ob<E extends {} = {}> = { v: E };
type SameObj = Ob<{ a: 1 }> extends Ob<infer E> ? E : "no";
const _so: { a: 1 } = 0 as unknown as SameObj;

// NEGATIVE CONTROL (same-ref fn, naked-E return): no type-var sibling, E binds.
type FnNaked<E extends {} = {}> = <N>(x: N) => E;
type SameFn = FnNaked<{ a: 1 }> extends FnNaked<infer E> ? E : "no";
const _sf: { a: 1 } = 0 as unknown as SameFn;

// NEGATIVE CONTROL (binding still works, distinct alias, naked-E return).
type FnR<E extends {} = {}> = <N>(x: N) => E;
type EnhR = FnR<{ a: 1 }>;
type Bind = EnhR extends FnR<infer E> ? E : "no";
const _b: { a: 1 } = 0 as unknown as Bind;

// NEGATIVE CONTROL (top-level intersection residual unaffected): concrete
// sibling `string` cancels, X captures {d:1}.
type G<N> = N & { d: 1 };
type TopRes = G<string> extends string & infer X ? X : "no";
const _t: { d: 1 } = 0 as unknown as TopRes;

// NEGATIVE CONTROL (own-property binding unaffected): E in its own property.
type FnO<E extends {} = {}> = <N>(x: N) => { n: N; e: E };
type EnhO = FnO<{ a: 1 }>;
type ObjBind = EnhO extends FnO<infer E> ? E : "no";
const _o: { a: 1 } = 0 as unknown as ObjBind;
