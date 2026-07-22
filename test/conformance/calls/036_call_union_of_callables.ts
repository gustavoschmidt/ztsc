// Calling a value whose type is a UNION. tsc: a union is callable iff EVERY
// constituent is callable; the call resolves against the constituents' gathered
// signatures. This is how `(A[] | B[]).map(...)` type-checks — the member
// access `.map` yields a union of the two arrays' `map` function types, and the
// call must resolve against that union rather than reporting TS2349.
//
// (Expressed lib-free with explicit function-typed and call-signature-object
// unions, since the conformance suite loads no lib.d.ts.)

type FA = (x: number) => number;
type FB = (x: number) => string;
declare const u: FA | FB;

type OA = { (x: number): number; tag: "a" };
type OB = { (x: number): boolean; tag: "b" };
declare const o: OA | OB;

// POSITIVE: every union member is callable → resolves (no TS2349).
const r = u(1);
const ro = o(2);

// NEGATIVE CONTROL: a union with a NON-callable member stays not-callable.
declare const bad: FA | number;
const b = bad(1);

declare const bad2: FA | { tag: "x" };
const b2 = bad2(1);
