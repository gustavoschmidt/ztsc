// Truthiness narrowing of a naked type parameter yields `T & {}` (tsc's
// `getAdjustedTypeWithFacts` maps `NonNullable` over the Truthy facts), so the
// constraint's non-nullish apparent members become reachable.
type Point = readonly [number, number];

export const a = <T extends Point | null>(p: T) => {
  if (p) {
    return p.map((n) => n * 2);
  }
  return [];
};

export const b = <T extends string | undefined>(s: T) => {
  if (s) {
    return s.length;
  }
  return 0;
};

// `&&` chain: the left operand's truthiness carries into the right
export const c = <T extends Point | null>(p: T, flag: boolean) => {
  if (p && flag) {
    return p.length;
  }
  return 0;
};

// an unconstrained type parameter is nullish-capable too
export const d = <T>(v: T) => {
  if (v) {
    return String(v);
  }
  return "";
};

// a type parameter whose constraint is already non-nullish is unchanged
export const e = <T extends Point>(p: T) => {
  return p.length;
};

// the value stays assignable back to a `T` slot after narrowing
export const f = <T extends Point | null>(p: T, sink: (v: T) => void) => {
  if (p) {
    sink(p);
  }
};
