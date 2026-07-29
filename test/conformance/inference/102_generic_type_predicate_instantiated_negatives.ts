// Negatives for 101: the instantiated predicate must still REJECT what the
// inferred type argument does not cover, and the literal-keeping rule must not
// start preserving literals in a non-type-variable context.

declare function want(m: "a" | "b"): void;
declare function wantZ(m: "z"): void;

const A = ["a", "b"] as const;

declare const isT: <T extends string>(
  coll: readonly T[],
  v: string,
) => v is T;

// Narrowed to `"a" | "b"`, which does not cover `"z"`.
export function f1(v: string) {
  if (isT(A, v)) wantZ(v);
}
// The FALSE branch is still `string`.
export function f2(v: string) {
  if (isT(A, v)) return;
  want(v);
}
// An explicit type argument that is wrong narrows to that, not to the
// collection's element type.
export function f3(v: string) {
  if (isT<"z">(A, v)) want(v);
}

// A plain `string` contextual type is still a WIDENING context — only a type
// VARIABLE constrained to `string` keeps the literal.
export const s: string[] = ["a", "b"];
export const t: "a"[] = s;

// A `number`-constrained parameter keeps number literals but not strings.
declare const pickN: <N extends number>(c: readonly N[]) => N;
export const n: 1 | 2 = pickN([1, 2]);
export const n2: 3 = pickN([1, 2]);
