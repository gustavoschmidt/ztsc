// A UNION spread source DISTRIBUTES: `{ ...(A | B), x }` is
// `{ ...A, x } | { ...B, x }` (tsc's `getSpreadType`), so each constituent
// keeps the correlation between the properties that came from one member.
//
// Folding the union into a single object instead — which is what ztsc did, and
// still does when the distribution does not apply — makes every property only
// some member declares optional, so the literal matches no arm of a
// discriminated target.
//
// The fold also used to bail out entirely on a union whose members are
// INTERSECTIONS (`Base & { … }`), which is the shape of every hand-written
// discriminated element union, so such a spread contributed nothing at all.

type Base = { id: string; size: number };
type Circle = Base & { kind: "circle"; radius: number };
type Square = Base & { kind: "square"; side: number };
type Shape = Circle | Square;

declare const s: Shape;

// POSITIVE (must NOT error) --------------------------------------------------

// The distributed literal is `Circle & { id } | Square & { id }`, and each
// constituent satisfies the corresponding arm of the union target. The fold
// would make `radius` and `side` optional and match neither.
declare function wantShape(v: Shape): void;
export const p1 = wantShape({ ...s, id: "x" });

// The intersection members' merged properties come through: `size` is declared
// by `Base`, one intersection constituent down.
declare function wantSize(v: { size: number }): void;
export const p2 = wantSize({ ...s });

// Reading a property that every constituent has.
export const p3: number = { ...s, id: "x" }.size;

// An explicit property still overrides the spread, in every constituent.
declare function wantId(v: { id: "fixed"; kind: "circle" | "square" }): void;
export const p4 = wantId({ ...s, id: "fixed" });

// A plain union of object literals distributes the same way.
type A = { tag: "a"; a: number };
type B = { tag: "b"; b: string };
declare const ab: A | B;
declare function wantAB(v: (A | B) & { extra: null }): void;
export const p5 = wantAB({ ...ab, extra: null });

// Regression: a non-union source is unaffected.
declare const c1: Circle;
export const p6 = wantShape({ ...c1, id: "x" });

// Regression: `T | undefined` is NOT distributed (only one constituent carries
// properties), so the fold's all-optional result stands and satisfies an
// all-optional target.
declare const maybe: A | undefined;
declare function wantOptA(v: { tag?: "a"; a?: number }): void;
export const p7 = wantOptA({ ...maybe });

// NEGATIVE (must error) ------------------------------------------------------

// Distribution does not invent members: neither constituent has `perimeter`.
declare function wantPerimeter(v: { perimeter: number }): void;
export const n1 = wantPerimeter({ ...s });

// A property only one constituent has is not readable off the union.
export const n2: number = { ...s }.radius;

// `T | undefined` folds, so its properties are optional and do not satisfy a
// required target.
export const n3: A = { ...maybe };
