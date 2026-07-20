// Recursive accumulator alias: a strictly-shrinking tuple argument threaded
// with a GROWING accumulator must reduce all the way to the accumulated
// intersection. `Rec<Tup, Acc>` peels one tuple element per hop and folds a
// mapped-type contribution `F<Head>` into `Acc`. Two things have to work
// together for this to reduce (both were bugs):
//
//   1. The mapped alias `F<Head>` is applied to `Head`, an `infer` var of the
//      enclosing conditional. Materializing it while `Head` is still symbolic
//      iterates an empty key set and freezes the map to `{}`; it must instead
//      DEFER (see `reduceMapped`'s `containsInfer` guard) and re-materialize
//      once `Head` binds (`substInfer`'s `.mapped` arm) — yielding `{ k_a }`.
//   2. The self-recursion `Rec<Tail, Acc & F<Head>>` shrinks the tuple while
//      the accumulator grows, so a *summed* structural metric plateaus and the
//      recursion stalls. `reexpandShrinking` decides shrinkage ARGUMENT-WISE
//      (`refStrictlyShrinks`): the tuple arg strictly shrinks each hop, so the
//      hop is driven even though `Acc` grows.
//
// This is the minimal shape of RTK `ExtractStoreExtensionsFromEnhancerTuple`
// and react-hook-form `PathInternal` that broke a real dogfood project. tsgo
// reduces `Built` to `F<"a"> & F<"b">`, so only `k_nope` is missing.
type F<H> = { [P in H & string as `k_${P}`]: number };
type Rec<Tup extends readonly any[], Acc> =
  Tup extends readonly [infer Head, ...infer Tail] ? Rec<Tail, Acc & F<Head & string>> : Acc;
type Built = Rec<["a", "b"], {}>;
declare const x: Built;
const a: number = x.k_a; // ok
const b: number = x.k_b; // ok
const c: number = x.k_nope; // TS2339 — property missing on the reduced intersection
export {};
