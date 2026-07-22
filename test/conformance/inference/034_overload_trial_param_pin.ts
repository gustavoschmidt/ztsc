// A contextually-typed callback passed to an OVERLOADED generic (`Array.reduce`)
// is materialized once per overload candidate during resolution. The rejected
// non-generic overload `reduce(cb: (prev: T, cur: T, …) => T, init: T): T`
// types the accumulator param as `T` (the element type). Param-symbol pinning
// used to be first-writer-wins, so that rejected trial froze `acc: T` and the
// SELECTED generic overload `reduce<U>(cb: (prev: U, cur: T, …) => U, init: U)`
// could no longer pin `acc: U` — the inferred `U` then wrongly picked up the
// element type (`"a" | "b" | Groups`), failing the outer assignment. The
// symptom only appeared with a multi-statement body (which forces the callback
// to be checked during the failing trial). This whole case must be zero-error.

type K = "a" | "b";
type Groups = Record<K, string[]>;

function groupEmpty(arr: K[]): Groups {
  return arr.reduce((acc, type) => {
    acc[type] = [];
    return acc;
  }, {} as Groups);
}

// Also fine with a plain local declaration preceding the return.
function withLocal(arr: number[]): Record<string, number> {
  return arr.reduce(
    (acc, n) => {
      const key = String(n);
      acc[key] = n;
      return acc;
    },
    {} as Record<string, number>,
  );
}

void groupEmpty;
void withLocal;
