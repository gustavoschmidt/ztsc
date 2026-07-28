// An assignment reduces the declared union to the constituents the assigned
// value could have come from — tsc's `getAssignmentReducedType`, which filters
// with `typeMaybeAssignableTo`: for a UNION source, SOME constituent has to be
// assignable, not all of them. Demanding all of them collapses a union onto its
// own supertype member the moment it is written into a variable declared with
// exactly that union, and the narrow arm is gone at every later use.

type A = { a: string; b: number };
type B = { a: string };

declare const src: A | B;

// 1. Writing the whole union keeps the whole union, so `in` still reaches the
//    arm that carries `b`.
let v: A | B = src;
export const v1: number = "b" in v ? v.b : 0;

// 2. Same through a discriminant whose supertype arm accepts more tags.
type C = { k: "c"; c: number; d: string };
type D = { k: "c" | "e"; d: string };
declare const src2: C | D;
let v2: C | D = src2;
export const v3: number = "c" in v2 ? v2.c : 0;

// 3. Reduction still happens for a non-union assigned type.
let n: string | number = 1;
export const n1: number = n;

// 4. And for a union source that fits only some of the declared constituents.
type Odd = { z: boolean };
let m: A | B | Odd = src;
export const m1: A | B = m;

// 5. The kept set still has to admit the value being written: an optional
//    property on the supertype arm is not made required by the reduction.
type E = { a: string; b?: number };
declare const src5: A | E;
let p: A | E = src5;
export const p1: number = "b" in p ? p.b : 0; // TS2322 — `number | undefined`
