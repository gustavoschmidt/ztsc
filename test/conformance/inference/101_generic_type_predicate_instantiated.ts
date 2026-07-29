// A GENERIC type predicate must narrow to the CALL's inferred type argument,
// not to the declared signature's naked type parameter, and the inference that
// produces it must survive the shapes the guard's collection parameter takes.
//
// Four independent pieces, all of which the `isMemberOf` shape needs at once:
//   1. the predicate is read off the RESOLVED signature (`v is T` -> `v is
//      "a" | "b"`),
//   2. an iterable object parameter (`Set<T>`) infers through the
//      `[Symbol.iterator]` element, not by scraping same-named members,
//   3. a rest element in a tuple argument contributes its ELEMENT type,
//   4. a type variable constrained to `string` is a literal-keeping context.

declare function want(m: "a" | "b" | "z"): void;

const A = ["a", "b"] as const;

declare const isT: <T extends string>(
  coll: readonly T[],
  v: string,
) => v is T;

export function f1(v: string) {
  if (isT(A, v)) want(v);
}
export function f2(v: string) {
  if (!isT(A, v)) return;
  want(v);
}

// The collection parameter is a UNION including iterable object types.
declare const isMemberOf: <T extends string>(
  coll: Set<T> | readonly T[] | Record<T, any> | Map<T, any>,
  v: string,
) => v is T;

export function f3(v: string) {
  if (isMemberOf(A, v)) want(v);
}
// An INLINE array literal (no `as const`): the elements must keep their
// literals because `T extends string` is a literal-keeping context.
export function f4(v: string) {
  if (isMemberOf(["a", "b"], v)) want(v);
}

// A tuple with a REST element from a spread.
const REST = { p: "a", q: "b" } as const;
const B = ["z", ...Object.values(REST)] as const;
export function f5(v: string) {
  if (isMemberOf(B, v)) want(v);
}

// Explicit type arguments instantiate the predicate too.
export function f6(v: string) {
  if (isT<"a" | "b">(A, v)) want(v);
}

// A plain (non-generic) predicate is unchanged.
declare function isAB(v: string): v is "a" | "b";
export function f7(v: string) {
  if (isAB(v)) want(v);
}

// The same inference outside a guard: element type through an iterable union
// parameter, and through a rest element.
declare const pick: <T extends string>(
  c: Set<T> | readonly T[] | Map<T, any>,
) => T;
export const g1: "a" | "b" = pick(A);
export const g2: "a" | "b" | "z" = pick(B);
export const g3: "a" | "b" = pick(["a", "b"]);

// A non-literal-constrained type parameter still widens.
declare const pick2: <T>(c: readonly T[]) => T;
export const g4: string = pick2(["a", "b"]);
