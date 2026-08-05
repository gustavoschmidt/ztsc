// An array literal in TUPLE context takes its per-element contextual type
// from EVERY constituent of a union contextual type, not just the one tuple
// that put it in tuple context (tsc's `getContextualTypeForElementExpression`
// is `getTypeOfPropertyOfContextualType(ctx, "" + index)`, which maps over a
// union). sharp's `affine(matrix: [number, number, number, number] |
// Matrix2x2)` is the shape: reading only the first tuple gives the inner
// literals a contextual `number`, so they widen to `number[]` and match
// neither branch.

declare function affine(m: [number, number, number, number] | [[number, number], [number, number]]): void;

// The same question with an ARRAY branch alongside the tuple branch: index 0
// contributes `number` from the tuple and `number | [number, number]` from
// the array, and the union of the two still carries a tuple constituent.
declare function mixed(m: [number, number, number, number] | (number | [number, number])[]): void;

export function ok(a: number, b: number, c: number, d: number) {
  affine([
    [a, b],
    [c, d],
  ]);
  affine([a, b, c, d]);
  mixed([
    [a, b],
    [c, d],
  ]);
  mixed([a, b, c, d]);
  mixed([a, [b, c]]);
}

// Negative control: widening the per-element contextual type must not make
// the literal fit something no constituent holds. A three-element inner
// literal is a member of neither branch at index 0, and a five-element outer
// literal is longer than every branch.
export function bad(a: number, b: number, c: number, d: number) {
  affine([
    [a, b, c],
    [c, d],
  ]);
  affine([a, b, c, d, a]);
  mixed([[a, b], d, "x"]);
}
