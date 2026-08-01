// A mapped type whose KEY DOMAIN is still generic has no members at all:
// tsc's `resolveMappedTypeMembers` iterates `getLowerBoundOfKeyType` of the
// constraint, and a naked type parameter is left unchanged there — it is
// neither usable as a property name nor a valid index key, so nothing is
// synthesized and every name is TS2339. Only `keyof X` gets the
// apparent-type treatment, which is what keeps a homomorphic `Partial<T>`
// readable through `T`'s constraint (the positives below).
interface Base {
  x: number;
  y: string;
}

// Negatives: the key domain is a naked type parameter.
export function recordOverParam<K extends "x" | "y">(p: Record<K, number>) {
  return p.x; // TS2339 — `K` is not known yet
}
export function pickOverParam<K extends keyof Base>(p: Pick<Base, K>) {
  return p.x; // TS2339
}
export function inlineOverParam<K extends keyof Base>(p: { [P in K]: Base[P] }) {
  return p.x; // TS2339
}
// …and a homomorphic map whose SOURCE is such a map inherits the emptiness:
// `keyof Record<K, any>` is that inner map's (generic) key domain.
export function partialOfRecord<K extends string>(p: Partial<Record<K, number>>) {
  return p.x; // TS2339
}
// An unconstrained source has no keys either.
export function partialOfUnconstrained<T>(p: Partial<T>) {
  return (p as Partial<T>).x; // TS2339
}

// Positives: the key domain resolves, so the members are visible.
export function homomorphic<T extends Base>(p: Partial<T>) {
  return p.x;
}
export function composedHomomorphic<T extends Base>(p: Partial<Readonly<T>>) {
  return p.x;
}
export function overIntersection<T extends Base>(p: Partial<T & { z: boolean }>) {
  return [p.z, p.x];
}
// One concrete constituent still contributes its names, even beside a
// generic-keyed one.
export function mixedSource<K extends string>(p: Partial<Record<K, number> & Base>) {
  return p.x;
}
// A distributive conditional key domain follows its check type: `Omit<T, "y">`
// is `Pick<T, Exclude<keyof T, "y">>`.
export function omitOverParam<T extends Base>(p: Omit<T, "y">) {
  return p.x;
}
// A fully concrete key domain is materialized as always.
export function concrete(p: Partial<Record<"x" | "y", number>>) {
  return p.x;
}
