// `"k" in x` must filter a union constituent that does not DECLARE `k`, even
// when that constituent is intersected with a still-GENERIC mapped type. tsc's
// `isTypePresencePossible` asks `getPropertyOfType`, and a generic mapped type
// has no members there — its key set is unknown, so it cannot supply `k`.
//
// The same shape also exercises the SPREAD rule: a spread whose source mixes
// concrete constituents with a generic one keeps the generic one by identity
// (tsc's `getSpreadType` intersection branch), so `{ ...el, id }` stays
// assignable to `typeof el & { id: string }`.

declare const ORIG: unique symbol;
type AllKeys = "id" | "n";

export const f = <T extends AllKeys>(
  xs: (Partial<Record<T, any>> & { selected?: true } & (
      | { id: string }
      | { [ORIG]?: string }
    ))[],
) => {
  const out: (typeof xs[number] & { id: string })[] = xs.map((el) => {
    if ("id" in el) {
      return el;
    }
    return { ...el, id: "x" };
  });
  return out;
};

// The same filter without the generic constituent (already correct).
type A = { a: string };
type B = { b: number };
export function g(x: A | B) {
  if ("a" in x) {
    return x.a;
  }
  return x.b;
}

// A NON-generic mapped type does have members, so it still supplies the name.
type Fixed = { [P in "a"]: number };
export function h(x: (Fixed & { z?: 1 }) | { b: number }) {
  if ("a" in x) {
    const n: number = x.a;
    return n;
  }
  return x.b;
}

// A spread of a bare generic keeps working (pre-existing `generic_spreads`).
export const i = <U extends object>(u: U) => {
  const r: U & { extra: number } = { ...u, extra: 1 };
  return r;
};
