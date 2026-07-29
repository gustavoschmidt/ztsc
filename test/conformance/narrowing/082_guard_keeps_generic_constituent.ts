// tsc's `getNarrowedTypeWorker` does not stop when no union constituent is
// directly related to the guard's type: it keeps every constituent that is
// still INSTANTIABLE (a deferred conditional, `keyof`, indexed access, or a
// bare type parameter) whose CONSTRAINT the candidate is comparable to — such
// a constituent can still be instantiated to something the guard accepts.
//
// The constraint that matters is the conditional's *default* constraint, the
// union of its branches: evaluating the conditional under its type
// parameters' constraints picks exactly one branch and loses the other.

declare function isArr(x: unknown): x is unknown[];

// `keyof T extends K[number] ? (K extends readonly (keyof T)[] ? K : E) : E`
// evaluates to `E` under its constraints but can still produce a `K`, so the
// guard keeps the value rather than narrowing the whole union to `never`.
export const shallowEqual = <
  T extends Record<string, any>,
  K extends readonly unknown[],
>(
  a: T,
  b: T,
  comparators?:
    | { [key in keyof T]?: (x: T[key], y: T[key]) => boolean }
    | (keyof T extends K[number]
        ? K extends readonly (keyof T)[]
          ? K
          : { _error: "keys are either missing or include keys not in compared obj" }
        : { _error: "keys are either missing or include keys not in compared obj" }),
) => {
  if (comparators && isArr(comparators)) {
    for (const key of comparators) {
      if (a[key as keyof T] !== b[key as keyof T]) {
        return false;
      }
    }
  }
  return true;
};

// A bare type parameter constituent behaves the same way.
export function viaTypeParam<U extends readonly unknown[]>(v: string | U) {
  if (isArr(v)) {
    return v.length;
  }
  return 0;
}

// Negative: the guarded value takes the CANDIDATE's type, not the union it was
// narrowed from — the conditional constituent's `_error` property is gone.
export const negNotTheUnion = <
  T extends Record<string, any>,
  K extends readonly unknown[],
>(
  comparators:
    | { [key in keyof T]?: (x: T[key], y: T[key]) => boolean }
    | (keyof T extends K[number] ? K : { _error: "bad" }),
) => {
  if (isArr(comparators)) {
    return comparators._error;
  }
  return "";
};

// Negative: the rule only fires for a constituent whose CONSTRAINT the guard
// type is comparable to. `W`'s constraint is an object, so the guard still
// narrows it away and the union does not survive the guard.
export function negUnrelatedConstraint<W extends { tag: "w" }>(v: W) {
  if (isArr(v)) {
    return v.length;
  }
  return 0;
}
