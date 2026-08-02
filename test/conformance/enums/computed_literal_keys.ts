// A computed property key whose expression has a LITERAL type declares that
// literal as the member name — tsc's late-bound name rule (`isLateBindableName`
// accepts a string literal, a numeric literal or a unique symbol). ztsc only
// handled the unique-symbol case, so a `{ [E.A]: T }` map kept the syntactic
// placeholder the binder minted as its member name: `m.a` was TS2339, and
// `keyof M` was a union of placeholders that nothing was assignable to.
enum SE {
  A = "a",
  B = "b",
}
enum NE {
  X = 10,
  Y = 20,
}
const K = "lit";
const N = 7;

type M = {
  [SE.A]: number;
  [SE.B]: string;
  [NE.X]: boolean;
  [K]: Date;
  [N]: symbol;
};

declare const m: M;
// Reachable under the spelled-out name…
export const a1: number = m.a;
export const a2: string = m.b;
export const a3: boolean = m[10];
export const a4: Date = m.lit;
export const a5: symbol = m[7];
// …and under the key expression that declared it.
export const b1: number = m[SE.A];
export const b2: boolean = m[NE.X];
export const b3: Date = m[K];

// A string-enum key is usable as an index through a generic, which is what a
// `send<T extends keyof M>(k: T): M[T]` dispatcher needs.
declare function pick<T extends keyof M>(key: T): M[T];
export const d1: number = pick(SE.A);
export const d2: string = pick(SE.B);
export const d3: Date = pick(K);

// The names are real: a wrong annotation is still caught, and a name that no
// key spells out is still absent.
export const e1: string = m.a;
export const e2 = m.nope;
