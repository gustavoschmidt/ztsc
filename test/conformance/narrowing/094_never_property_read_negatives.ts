// The observable `never`: a reference a guard narrowed down to nothing, in a
// branch that is still syntactically reachable. `never` has no members, so
// every read below is a TS2339 — the counterpart to the silent, unreachable
// reads in 094_never_property_read.ts.
declare const bare: never;
export const r1 = bare.length;

// An exhausted union.
export function exhausted(k: "a" | "b") {
  if (k === "a") return 1;
  if (k === "b") return 2;
  return k.length;
}

// The fall-out of a `default`-less exhaustive switch.
export function switchFallOut(k: "a" | "b") {
  switch (k) {
    case "a":
      return 1;
    case "b":
      return 2;
  }
  return k.length;
}

// A `default:` clause the discriminant can never take.
export function switchDefault(s: { t: "c"; r: number } | { t: "s"; w: number }) {
  switch (s.t) {
    case "c":
      return s.r;
    case "s":
      return s.w;
    default:
      return s.t.length;
  }
}

// `?.` is no excuse: an optional chain strips nullish, and `never` is
// neither `null` nor `undefined`.
export function chained(k: "a" | "b") {
  if (k === "a") return 0;
  if (k === "b") return 0;
  return k?.length;
}

// `typeof v === "function"` on a NON-callable object empties the branch —
// the other side of the callable-interface rule 094 pins.
export function plainObjectGuard(v: { a: string }) {
  if (typeof v === "function") {
    return v.a;
  }
  return "";
}
