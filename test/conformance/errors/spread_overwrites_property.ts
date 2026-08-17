// tsc's `checkSpreadPropOverrides`: a property written BEFORE a spread whose
// source declares the same name NON-optionally is dead code — the spread
// always wins — so tsc reports TS2783 at the earlier property.
//
// Only SYNTACTIC properties count, and only the ones written earlier: tsc
// keeps them in a side table a spread's own properties never enter. That is
// what makes `{ ...ab, ...ab }` silent while `{ b: 1, ...ab }` is not.

export {};

declare var ab: { a: number; b: number };
declare var abq: { a: number; b?: number };
declare var undef: { x: number | undefined };
declare var rec: Record<string, number>;
declare var anyv: any;

// Reported at the earlier property.
export const e1 = { b: 1, ...ab };
export const e2 = { a: 1, b: 2, ...ab };
export const e3 = { x: 1, ...undef };

// A property written BETWEEN two spreads still counts for the second.
export const e4 = { ...abq, b: 1, ...ab };

// Negative controls.
export const n1 = { ...ab, ...ab }; // a spread's props never enter the table
export const n2 = { b: 1, ...abq }; // the spread declares `b` optionally
export const n3 = { ...ab, b: 1 }; // the property WINS, written last
export const n4 = { c: 1, ...ab }; // no collision
export const n5 = { a: 1, ...rec }; // an index signature is not a property
export const n6 = { a: 1, ...anyv }; // nothing is known about the source

export function fromParam(obj: { x: number }) {
  return { x: 1, ...obj };
}
