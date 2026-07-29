// Intersection members keep the order they were WRITTEN, and that order is
// observable: the concatenated overload set is tried in it, so `A & B` and
// `B & A` resolve the same call to different signatures. A canonicalizing
// sort (by TypeId, i.e. by interning order) made the answer depend on what
// the checker happened to intern first.

type First = (x: string | number) => "first";
type Second = (x: string) => "second";

declare const fs: First & Second;
export const a: "first" = fs("s");

declare const sf: Second & First;
export const b: "second" = sf("s");

// Same through a property of an intersection of interfaces: the property
// type is the intersection of the two declared types, in constituent order.
interface P {
  m(x: string | number): "first";
}
interface Q {
  m(x: string): "second";
}

declare const pq: P & Q;
export const c: "first" = pq.m("s");

declare const qp: Q & P;
export const d: "second" = qp.m("s");

// A later constituent still supplies the only match when the earlier ones
// do not accept the argument.
export const e: "first" = qp.m(1);
