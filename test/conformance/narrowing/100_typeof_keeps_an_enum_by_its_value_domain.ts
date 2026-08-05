// tsc models an enum as the UNION of its member types, and a member type is a
// string- or number-LITERAL type carrying the enum flag — so `typeof`
// classifies an enum by its VALUE domain. ztsc keeps an enum as one nominal
// type, whose kind matched no `typeof` bucket at all, so `typeof p ===
// 'string'` collapsed a string enum to `never`. immich's
// `AuthenticatedOptions['permission']` is `Permission | false | undefined`,
// read through `typeof permission === 'string' && permission.startsWith(…)`.

enum S {
  A = "a",
  B = "b",
}
enum N {
  X = 1,
  Y = 2,
}

export function stringEnumSurvives(p: S | false | undefined) {
  if (typeof p === "string") {
    const kept: S = p;
    return kept.startsWith("a");
  }
  return false;
}

export function numericEnumSurvives(p: N | string) {
  if (typeof p === "number") {
    const kept: N = p;
    return kept;
  }
  return p.length;
}

// The two domains separate a mixed union, whole enums and members alike.
export function splitsWholeEnums(p: S | N) {
  if (typeof p === "string") {
    const s: S = p;
    return s;
  }
  const n: N = p;
  return n;
}

export function splitsMembers(p: S.A | N.X) {
  if (typeof p === "string") {
    const s: S.A = p;
    return s;
  }
  const n: N.X = p;
  return n;
}

// Negative control: an enum is neither an object nor a function, so every
// other bucket still subtracts it, and the wrong domain still does.
export function objectBucketSubtractsIt(p: S | { k: number }) {
  if (typeof p === "object") {
    return p.k;
  }
  return p.length;
}

export function wrongDomainIsNever(p: S) {
  if (typeof p === "number") {
    return p.toFixed(2);
  }
  return 0;
}

export function functionBucketSubtractsIt(p: N | (() => number)) {
  if (typeof p === "function") {
    return p();
  }
  return p.toFixed(2);
}
