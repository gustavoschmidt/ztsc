// A type S is assignable to `keyof T` when it is assignable to `keyof C`,
// where C is T's constraint; and `keyof S` is assignable to `keyof T` exactly
// when T is assignable to S.
interface Obs {
  id: string;
  count: number;
}

declare function pick<T, K extends keyof T>(o: T, k: K): T[K];

export function f<U extends Obs>(o: Partial<U>) {
  return pick(o, "id"); // OK: "id" satisfies keyof Partial<U> via keyof Obs
}

export function g<U extends Obs>(k: keyof U) {
  const a: keyof Obs = k; // OK: keyof U <: keyof Obs
  void a;
}

export function h<U extends Obs>(k: keyof Obs) {
  const a: keyof U = k; // OK: U <: Obs, so keyof Obs <: keyof U
  void a;
}

// NEGATIVE: a key the constraint does not have.
export function bad<U extends Obs>(o: Partial<U>) {
  return pick(o, "nope");
}

// NEGATIVE: an unconstrained type parameter has no keys to reach.
export function bad2<U>(k: string) {
  const a: keyof U = k;
  void a;
}
