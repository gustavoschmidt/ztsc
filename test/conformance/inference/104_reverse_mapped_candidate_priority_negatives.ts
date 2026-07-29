// Negatives for 103: discarding the reverse-mapped candidate must not stop the
// `Partial<T>` argument from being CHECKED against the direct candidate, and
// the reverse-mapped route must still answer where it is the only evidence.

type V = { a: number; b: string };

declare const updateObject: <T extends Record<string, any>>(
  obj: T,
  updates: Partial<T>,
) => T;

// A property whose type contradicts the direct candidate is still rejected.
export const e1 = updateObject({ a: 1, b: "s" }, { a: "no" });
// An unknown property in the `Partial<T>` argument is still excess.
export const e2 = updateObject({ a: 1, b: "s" }, { zz: 1 });
// The result type is the DIRECT candidate, so a wrong annotation reports.
export const e3: { a: string } = updateObject({ a: 1, b: "s" }, { a: 2 });

// Reverse-mapped only: the rebuilt shape is the answer, so a mismatching
// annotation reports against it.
declare const fromUpdates: <T extends Record<string, any>>(
  updates: Partial<T>,
) => T;
export const e4: { x: string } = fromUpdates({ x: 1 });

declare function want(v: V): void;
export function f(cur: V) {
  want(updateObject(cur, { a: 2 }));
}
