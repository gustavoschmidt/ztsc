// An intersection two of whose constituents give the same required property
// unit types that cannot both hold is UNINHABITED: the intersected property
// type is `never`, so no value can have it, and tsc reduces the whole
// intersection to `never` (`getReducedType` / `isDiscriminantWithNeverType`).
// `never` relates to everything, so such a source is accepted anywhere.
//
// This is the object-level counterpart of the rule that already made
// `"line" & "arrow"` collapse. It matters because narrowing a generic
// `T extends A | B` by an `x is B` type predicate produces exactly this shape:
// the branch type is `T & B`, and for `T = A` that member is dead — tsc drops
// it from the union the call site sees, ztsc used to reject the call on it.

type A = { type: "a"; x: number };
type B = { type: "b"; y: string };
type Wanted = { nope: number };

// POSITIVE (must NOT error) --------------------------------------------------

declare const ab: A & B;
export const p1: Wanted = ab;

declare function want(v: Wanted): void;
export const p2 = want(ab);

// A dead constituent inside a union does not sink the union.
declare const u: (A & B) | Wanted;
export const p3: Wanted = u;

// The rule is about a REQUIRED property. Reached through a type predicate on a
// generic, which is the shape that produces these intersections in practice.
declare function isB(v: A | B): v is B;
declare function takeB(v: B): void;
export function p4<T extends A>(t: T) {
  if (isB(t)) {
    // `T & B`, and `T`'s constraint fixes `type` to `"a"`.
    const w: Wanted = t;
    return w;
  }
  return null;
}

// Three constituents, the conflict between the outer two.
type C = { type: "a"; z: boolean };
declare const abc: A & C & B;
export const p5: Wanted = abc;

// NEGATIVE (must error) ------------------------------------------------------

// Agreeing discriminants leave the intersection inhabited.
declare const ac: A & C;
export const n1: Wanted = ac;

// An OPTIONAL conflicting property does not empty the intersection: a value
// that omits it satisfies both.
type OptA = { type?: "a" };
type OptB = { type: "b" };
declare const oab: OptA & OptB;
export const n2: Wanted = oab;

// Non-unit property types never conflict this way.
type NumA = { type: number };
type StrB = { type: string };
declare const ns: NumA & StrB;
export const n3: Wanted = ns;

// The reduction is a SOURCE rule; it does not make an inhabited source relate
// to an unrelated target.
export const n4: Wanted = { type: "a", x: 1 } as A;
