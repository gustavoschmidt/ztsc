// Type-parameter defaults under inference (no explicit type arguments, no
// contextual return type): a type parameter that cannot be inferred falls back
// to its default rather than to `unknown`. A default may reference an earlier
// (inferred) parameter. The positive assignments assert the default was
// applied (an `unknown` fallback would make them fail).
declare function g<T = string>(): T;
const g1 = g();
const gs: string = g1;
declare function h<A, B = A>(a: A): B;
const h1 = h(5);
const hn: number = h1;
declare function k<A, B = boolean>(a: A): [A, B];
const k1 = k("x");
const kb: [string, boolean] = k1;
const kbad: [string, number] = k1;
