// Sibling to 014: a NON-recursive wrapper alias whose conditional true branch
// is a bare reference to a *different*, self-recursive accumulator alias. Here
// the tuple is recovered by `infer` from a class-based container (`class Tuple
// extends Array`, the RTK `Tuple` shape), which leaves the inner reference
// only partially reduced when it reaches `reexpandShrinking`. Because the outer
// wrapper (`Wrap`) and the inner recursion (`Acc2`) are DIFFERENT aliases, a
// summed structural metric comparing the two unrelated refs need not decrease,
// so the argument-wise recursion would never start — the reference stalls at
// `Acc2<[E2], {a}&{}>`. `reexpandShrinking` therefore takes a one-time
// cross-alias ENTRY on its first hop: expand once into the inner alias, after
// which every hop is same-alias and driven by the strict argument-wise shrink
// test. This is the minimal shape of RTK `ExtractStoreExtensions` wrapping
// `ExtractStoreExtensionsFromEnhancerTuple`. tsgo reduces `Built` to
// `{ a: number } & { b: string }`, so only `nope` is missing.
interface Enh<Ext extends {} = {}> {
  _brand: Ext;
}
declare class Tuple<Items extends ReadonlyArray<unknown> = []> extends Array<Items[number]> {
  constructor(...items: Items);
}
type Acc2<Tup extends readonly any[], Acc extends {}> =
  Tup extends [infer Head, ...infer Tail] ? Acc2<Tail, Acc & (Head extends Enh<infer Ext> ? Ext : {})> : Acc;
type Wrap<E> = E extends Tuple<infer T> ? Acc2<T, {}> : never;
type E1 = Enh<{ a: number }>;
type E2 = Enh<{ b: string }>;
type Built = Wrap<Tuple<[E1, E2]>>;
declare const x: Built;
const a: number = x.a; // ok
const b: string = x.b; // ok
const c: number = x.nope; // TS2339
export {};
