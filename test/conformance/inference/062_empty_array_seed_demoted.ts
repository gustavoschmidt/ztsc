// An EMPTY array-literal argument must not out-vote the real inference
// evidence for the same type parameter.
//
// `arr.reduce((acc: T[], el) => …, [])` inferred `U = any[] | T[]`: the seed
// carries no element evidence yet contributed `any[]`, which was unioned with
// the candidate the annotated accumulator supplies. tsc reaches `T[]` because
// it takes the common SUPERTYPE of a parameter's covariant candidates and the
// seed's `never[]` is a subtype of every array type; ztsc unions candidates, so
// the seed is demoted instead — it fills a parameter only when nothing else
// constrained it.

type X = { id: string };
declare const arr: X[];

// POSITIVE: `U` is the accumulator's annotated type, not a union with the seed.
// Each line names what was inferred.

const r1 = arr.reduce((acc: X[], el) => acc, []); // context-sensitive callback
export const p1: null = r1; // TS2322 'X[]'

const r2 = arr.reduce((acc: X[], el: X) => acc, []); // fully annotated callback
export const p2: null = r2; // TS2322 'X[]'

declare function g<U>(a: (p: U) => U, b: U): U;
const r3 = g((acc: X[]) => acc, []);
export const p3: null = r3; // TS2322 'X[]'

// Seed first, callback second — the demotion is not positional.
declare function h<U>(b: U, a: (p: U) => U): U;
const r4 = h([], (acc: X[]) => acc);
export const p4: null = r4; // TS2322 'X[]'

// Regression: a NON-empty array literal is real evidence and still infers.
const r5 = arr.reduce((acc: X[], el) => acc, [{ id: "a" }]);
export const p5: null = r5; // TS2322 '{ id: string; }[]'

// Regression: with no other evidence the seed still fills the parameter, so
// this is an error rather than an unresolved-parameter cascade.
declare function m<U>(b: U): U;
export const p6: null = m([]);

// Regression: an empty array literal in a position that is not an inference
// target at all is unaffected.
declare function k<U>(a: U[], b: string[]): U;
export const p7: null = k([{ id: "a" }], []); // TS2322 '{ id: string; }'

// NEGATIVE: demoting the seed's *candidate* must not suppress checking the
// argument itself against the parameter type the other evidence produced.
declare function w<U>(a: U[], b: U): U;
export const bad = w([1, 2], []); // TS2345
