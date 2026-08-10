// An array literal's ELEMENT type is never a fresh literal.
//
// tsc's `checkExpressionForMutableLocation` runs every element through
// `getWidenedLiteralLikeTypeForContextualType`, and that function ends with
// `getRegularTypeOfLiteralType(type)` on BOTH of its arms — the one that
// widened the literal away and the one where the contextual type kept it.
// Freshness is a property of an expression, not of a type an expression lands
// in, and an element type is the latter.
//
// ztsc kept the element fresh whenever the context preserved the literal, and
// the freshness escaped through INFERENCE. `mk` below is zod's `z.enum`
// signature: `U` has a primitive constraint, so `getCovariantInference` maps
// its candidates through `getRegularTypeOfLiteralType`, but `T` is inferred as
// the whole tuple and no arm of that three-way choice reaches inside a tuple.
// So `T[number]` was a union of FRESH literals, and the next inference that saw
// it — `useState<S>`, unconstrained, with `S` buried in a tuple return so
// `getCovariantInference` takes its widening arm — widened it to `string`.
// social-app's `useState(() => persisted.get('colorMode'))` is exactly that
// pair, three modules apart.
declare function mk<U extends string, T extends Readonly<[U, ...U[]]>>(
  values: T,
): {out: T[number]};

declare function useState<S>(init: S | (() => S)): [S, (v: S) => void];

const e = mk(['system', 'light', 'dark']);
type Mode = (typeof e)['out'];

declare const raw: Mode;

// Round-tripping through an unconstrained inference must not widen it.
export const a: Mode = useState(raw)[0];
export const b: Mode = useState(() => raw)[0];

// The elements are still literals — regular, not widened.
export const c: 'system' | 'light' | 'dark' = raw;

// A fresh literal in a value position is unaffected: an unannotated `let`
// still widens, an unannotated `const` still does not.
let fresh = 'system';
fresh = 'anything';
const kept = 'system';
export const d: 'system' = kept;
export const f: string = fresh;

// And an element whose literal the context does NOT keep still widens.
const plain = ['system', 'light'];
export const g: string[] = plain;
