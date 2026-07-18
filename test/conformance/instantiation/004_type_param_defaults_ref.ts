// Type-parameter defaults on a type reference (interface / type alias): a
// reference may supply fewer type arguments than parameters; the trailing ones
// take their defaults, with an earlier-param reference (`B = A`) substituted by
// the supplied argument. Out-of-range arity is TS2707 (a range) once defaults
// make min < max.
interface I<A, B = A> { a: A; b: B }
const i1: I<number> = { a: 1, b: 2 };
const i2: I<number> = { a: 1, b: "x" };
type P<A, B = A> = [A, B];
const p1: P<number> = [1, 2];
const p2: P<number> = [1, "x"];
interface J<A, B, C = B> { a: A; b: B; c: C }
const j1: J<number> = { a: 1, b: 1, c: 1 };
