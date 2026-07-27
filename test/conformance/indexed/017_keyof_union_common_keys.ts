// `keyof (A | B)` is `keyof A & keyof B` — only the keys present on every
// constituent can be read off the union.
type A = { kind: "a"; shared: number; onlyA: string };
type B = { kind: "b"; shared: number; onlyB: string };
type U = A | B;

type KU = keyof U;
declare const k: KU;
const k1: "kind" | "shared" = k;
// widening to a superset is fine; `onlyA` is simply never produced
const k2: "kind" | "shared" | "onlyA" = k;
// @negative: the union's key set is not `keyof A`
declare const ka: keyof A;
const k3: KU = ka;

// Through an intersection: `keyof ((A | B) & { extra: boolean })`
type KI = keyof (U & { extra: boolean });
declare const ki: KI;
const k4: "kind" | "shared" | "extra" = ki;
// @negative
const k5: "kind" | "shared" = ki;

// Omit / Pick / Required over a union no longer collapse to `{}`.
type O = Omit<U, "kind">;
declare const o: O;
const o1: number = o.shared;
// @negative: `kind` was omitted
const o2 = o.kind;
// @negative: `onlyA` is not a common key
const o3 = o.onlyA;

type P = Pick<U, "kind">;
declare const p: P;
const p1: "a" | "b" = p.kind;
// @negative
const p2 = p.shared;

// An index signature contributes the whole `string` domain, so a literal key
// of the other constituent survives the intersection.
type S = { [key: string]: number };
type KS = keyof (S | A);
declare const ks: KS;
const s1: "kind" | "shared" | "onlyA" = ks;

// A union with no common keys really is `never`.
type KN = keyof ({ a: 1 } | { b: 2 });
declare const kn: KN;
const n1: never = kn;

// Generic: deferred until instantiation.
function keysOf<T extends U>(t: T, key: keyof U): void {
  const kk: "kind" | "shared" = key;
  void t;
  void kk;
}
void keysOf;
