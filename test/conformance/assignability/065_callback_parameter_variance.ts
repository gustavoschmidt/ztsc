export {};

type S = { a: 1; b: 2 };
type T = { a: 1 };

// A signature-valued PARAMETER is related as a callback: its own parameters go
// in the same direction as the outer relation, and (for a method) its return
// relates bivariantly. `X` in both positions is the case whole-signature
// bivariance cannot express.
interface L1<X> {
  r(cb: (v: X) => X): void;
}
declare const a1: L1<S>;
const b1: L1<T> = a1;
declare const a1r: L1<T>;
const b1r: L1<S> = a1r; // NEGATIVE

// `X` only in the callback's parameter.
interface L2<X> {
  r(cb: (v: X) => void): void;
}
declare const a2: L2<S>;
const b2: L2<T> = a2;
declare const a2r: L2<T>;
const b2r: L2<S> = a2r; // NEGATIVE

// `X` only in the callback's return.
interface L3<X> {
  r(cb: () => X): void;
}
declare const a3: L3<S>;
const b3: L3<T> = a3;
declare const a3r: L3<T>;
const b3r: L3<S> = a3r;

// NEGATIVE: a top-level function type is not a method, so its callback's
// return stays covariant (strictFunctionTypes).
declare function f1(cb: (v: S) => S): void;
const g1: (cb: (v: T) => T) => void = f1;
declare function f2(cb: (v: S) => void): void;
const g2: (cb: (v: T) => void) => void = f2;
declare function f2r(cb: (v: T) => void): void;
const g2r: (cb: (v: S) => void) => void = f2r;

// NEGATIVE: a PROPERTY holding a function type is not a method either.
interface P1<X> {
  r: (cb: (v: X) => X) => void;
}
declare const p1: P1<S>;
const q1: P1<T> = p1;
interface P2<X> {
  r: (cb: (v: X) => void) => void;
}
declare const p2: P2<S>;
const q2: P2<T> = p2;
declare const p2r: P2<T>;
const q2r: P2<S> = p2r;

// A non-callback parameter of a method stays bivariant, both ways.
interface M1<X> {
  r(v: X): void;
}
declare const m1: M1<S>;
const n1: M1<T> = m1;
declare const m1r: M1<T>;
const n1r: M1<S> = m1r;

// NEGATIVE: a callback nested one level deeper is NOT itself related as a
// callback — inside a callback comparison the relation is strict.
interface N1<X> {
  r(cb: (inner: (v: X) => void) => void): void;
}
declare const nn: N1<S>;
const nq: N1<T> = nn;

// An overloaded parameter has no single call signature, so it is not a
// callback and the method's ordinary bivariance applies.
interface O1<X> {
  r(cb: { (v: X): void; (v: X, n: number): void }): void;
}
declare const o1: O1<S>;
const o1q: O1<T> = o1;

// A type-predicate parameter is excluded from the callback relation.
interface Q1<X> {
  r(cb: (v: unknown) => v is X): void;
}
declare const qq: Q1<S>;
const qqq: Q1<T> = qq;

// The lib containers this unblocks: `Map` / `Set` / `ReadonlyMap` relate
// covariantly in their value type, like `Array` / `Promise` / `WeakMap`.
declare const c1: Map<string, S>;
const d1: Map<string, T> = c1;
declare const c2: Set<S>;
const d2: Set<T> = c2;
declare const c3: Array<S>;
const d3: Array<T> = c3;
declare const c4: Promise<S>;
const d4: Promise<T> = c4;
declare const c5: WeakMap<object, S>;
const d5: WeakMap<object, T> = c5;
declare const c6: Iterable<S>;
const d6: Iterable<T> = c6;
declare const c7: ReadonlyMap<string, S>;
const d7: ReadonlyMap<string, T> = c7;

// NEGATIVE: the other direction on those containers must still fail.
declare const e1: Map<string, T>;
const h1: Map<string, S> = e1;
declare const e3: Array<T>;
const h3: Array<S> = e3;
