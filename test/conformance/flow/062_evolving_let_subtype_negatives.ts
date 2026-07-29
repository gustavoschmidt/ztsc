// Subtype reduction only collapses constituents that really are subtypes, and
// it applies to EVOLVING variables — not to an annotated one.
declare const wide: { x?: number; y?: number };

// Unrelated branches both survive.
export function m(cond: boolean) {
  let v = null;
  if (cond) {
    v = wide;
  } else {
    v = { z: 1 };
  }
  return v?.y;
}

// An ANNOTATED variable keeps its declared union: nothing is reduced away, so
// the property that only one constituent has is still not readable.
type A = { p: number };
type B = { q: number };
export function n(cond: boolean) {
  let v: A | B | null = null;
  if (cond) {
    v = { p: 1 };
  } else {
    v = { q: 1 };
  }
  return v?.p;
}

// The `null` initializer itself still reaches the join when a branch does not
// assign.
export function o(cond: boolean) {
  let v = null;
  if (cond) {
    v = wide;
  }
  return v.x;
}
