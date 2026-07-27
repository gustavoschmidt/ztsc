// A conditional whose check carries free type parameters normally defers —
// the answer can depend on what those parameters turn out to be. It cannot
// when the `extends` pattern is an array whose element is a bare `infer`:
// an unconstrained `infer` accepts every element type, so the pattern only
// asks "is the check an array?", and the check's own shape settles that.
// This is the lib's `FlatArray` (`Arr extends ReadonlyArray<infer InnerArr>`),
// and deferring it left `arr.flat()` as an unreduced conditional that related
// to nothing.
type El<A> = A extends ReadonlyArray<infer I> ? I : "not-an-array";

type Sub<T extends any[]> = (...payload: T) => void;

// Array check, free param in the element: resolves to the element.
export function arrayCheck<T extends any[]>(x: El<Sub<T>[]>): Sub<T> {
  return x;
}

// Tuple check, same.
export function tupleCheck<T>(x: El<[T, T]>): T {
  return x;
}

// Function check: never an array, so the false branch, whatever `T` is.
export function fnCheck<T extends any[]>(x: El<Sub<T>>): "not-an-array" {
  return x;
}

// The real shape: `flat()` on a generic array must produce a usable element
// type instead of a deferred conditional.
export class Emitter<T extends any[] = []> {
  on(...handlers: Sub<T>[] | Sub<T>[][]): Sub<T>[] {
    return handlers.flat();
  }
}

// NEGATIVE: a *constrained* element decides nothing about a generic check —
// whether `T[]` matches `readonly string[]` depends on `T` — so this stays
// deferred and the assignment to the true branch's type is not admitted.
type StrEl<A> = A extends ReadonlyArray<string> ? "yes" : "no";
export function constrained<T>(x: StrEl<T[]>): "yes" {
  return x;
}
