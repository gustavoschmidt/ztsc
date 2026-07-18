// Type-parameter defaults on a function call: fewer explicit type arguments
// than parameters is allowed — the trailing ones take their defaults,
// instantiated under the args resolved so far (`B = A`, `C = B`). Required
// arity is the count of leading params without a default.
declare function make<A, B = A, C = B>(a: A): [A, B, C];
const m1 = make<number>(1);
const ok1: [number, number, number] = m1;
const m2 = make<number, string>(1);
const ok2: [number, string, string] = m2;
make<number, string, boolean, object>(1);
declare function only<A, B>(a: A): [A, B];
only<number>(1);
