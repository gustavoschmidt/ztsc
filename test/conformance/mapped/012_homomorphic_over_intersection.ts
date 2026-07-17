// A homomorphic map over an intersection source must keep members of every
// constituent (`keyof (A & B)`), not fall through to `{}`. ztsc previously
// dropped them all — spurious TS2739/TS2339 downstream.
type Id<T> = { [K in keyof T]: T[K] };
type A = { a: string };
type B = { b: number };
type R = Id<A & B>;
const ok: R = { a: "s", b: 1 };
const na: string = ok.a;
const nb: number = ok.b;
const miss: R = { a: "s" };
