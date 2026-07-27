// A deferred indexed access `T[K]` is assignable to whatever its BASE
// CONSTRAINT instantiation is assignable to — the mirror of the rule that
// already accepted a write INTO `T[K]`.
type Base = { a: number; ids: string[]; s: string };

declare function takesNumber(n: number): void;
declare function takesIds(v: string[]): void;

export function f<T extends Base>(x: T) {
  const v: T["ids"] = x.ids;
  takesIds(v);
  const n: T["a"] = x.a;
  takesNumber(n);
  const w: number = n;
  return w;
}

// NEGATIVE: the constraint still has to fit
export function g<T extends Base>(x: T) {
  const n: T["a"] = x.a;
  const bad: string = n; // TS2322
  return bad;
}

// NEGATIVE: a generic INDEX stays opaque even with a constrained object
export function k<T extends Base, K extends keyof T>(x: T, i: K) {
  const v: T[K] = x[i];
  takesNumber(v); // TS2345
}

// the rule composes with a union constraint
type B2 = { a: number | string };
export function m<T extends B2>(x: T) {
  const v: T["a"] = x.a;
  const ok: number | string = v;
  const bad: number = v; // TS2322
  return [ok, bad];
}
