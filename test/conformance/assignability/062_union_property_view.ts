// A union has a property only when *every* constituent has it, and its type is
// the union of the per-constituent types (tsc's
// `getUnionOrIntersectionProperty`). The optional and readonly modifiers
// accumulate: optional on any constituent makes the merged property optional.
//
// The lookup has to work wherever a union is *not* the top-level type of the
// access — through a type parameter's union constraint above all, which is how
// `function f<T extends Elem>(t: T) { t.id }` reads a member without narrowing.
type A = { kind: "a"; id: string; only: number };
type B = { kind: "b"; id: string };
type U = A | B;

// 1. through a type-parameter constraint
export function viaConstraint<T extends U>(t: T): string {
  return t.id;
}

// 2. a property on only one constituent is absent through the constraint too
export function viaConstraintMissing<T extends U>(t: T) {
  return t.only;
}

// 3. the property type is the *union* of the constituents' types
type P = { tag: "p"; v: string };
type Q = { tag: "q"; v: number };
declare function pick<T extends P | Q>(t: T): T;
declare const pq: P | Q;
export const v: string = pick(pq).v;

// 4. optional on one constituent makes the merged property optional
type WithOpt = { tag: "o"; n?: number };
type WithReq = { tag: "r"; n: number };
export function mergedOptional<T extends WithOpt | WithReq>(t: T): number {
  return t.n;
}

// 5. readonly on one constituent makes the merged property readonly
type RO = { tag: "ro"; readonly x: number };
type RW = { tag: "rw"; x: number };
export function mergedReadonly<T extends RO | RW>(t: T) {
  t.x = 1;
}

// 6. a union nested as an intersection constituent behind a type parameter:
// `T & { extra }` keeps `T` a type parameter, so the union view is reached
// through the constraint from inside the intersection.
type Branded<T extends U> = T & { extra: number };
export function viaBrandedConstraint<T extends U>(b: Branded<T>): string {
  return b.id;
}
