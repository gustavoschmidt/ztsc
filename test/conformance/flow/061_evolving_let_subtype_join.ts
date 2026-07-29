// tsc joins the antecedents of an EVOLVING (`auto`-typed) variable — a
// `let` with no annotation initialized to `null`/`undefined` — with
// `UnionReduction.Subtype`, so a branch assigning a subtype of another
// branch's type contributes nothing new.
type Init = { a?: number; b?: string; c?: boolean };
declare const src: Init | null;

export function m() {
  let v = null;
  try {
    v = src;
  } catch {
    v = { a: 1 };
  }
  if (v?.b) {
    return 1;
  }
  return 0;
}

// if/else, and the reduction keeps the WIDER constituent.
declare const wide: { x?: number; y?: number };
export function n(cond: boolean) {
  let v = null;
  if (cond) {
    v = wide;
  } else {
    v = { x: 1 };
  }
  return v?.y;
}

// An `undefined` initializer evolves the same way.
export function o(cond: boolean) {
  let v = undefined;
  if (cond) {
    v = wide;
  } else {
    v = { x: 1, y: 2 };
  }
  return v?.y;
}
