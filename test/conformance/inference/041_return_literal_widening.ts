// Inferred (no-context) return-type literal widening, matching tsc:
// the fresh literal return-expression types are unioned FIRST, and only a
// result that collapsed to a SINGLE literal is widened to its base primitive.
// A union of 2+ distinct literals is preserved. Self-contained (no lib).

// Single literal collapses -> widens to `string`: not assignable to the union.
function single() {
  return 'a';
}
const s1: 'a' | 'b' | 'c' = single(); // line 10: error (string)

// Two SAME literals collapse to one -> also widen to `string`.
function same(c: boolean) {
  if (c) return 'a';
  return 'a';
}
const s2: 'a' | 'b' | 'c' = same(true); // line 18: error (string)

// Two DISTINCT literals -> union preserved -> assignable, no error.
function distinct(c: boolean) {
  if (c) return 'a';
  return 'b';
}
const s3: 'a' | 'b' | 'c' = distinct(true); // clean

// Distinct via a concise-arrow ternary -> union preserved.
const arrow = (c: boolean) => (c ? 'x' : 'y');
const s4: 'x' | 'y' | 'z' = arrow(true); // clean

// A literal alongside a non-literal `string` -> absorbed to `string`.
function withStr(c: boolean, s: string) {
  if (c) return 'a';
  return s;
}
const s5: 'a' | 'b' = withStr(true, 'z'); // line 38: error (string)

// `true | false` collapses to `boolean`.
function bothBool(c: boolean) {
  if (c) return true;
  return false;
}
const s6: true = bothBool(true); // line 45: error (boolean)

// The preserved union stays a WIDENING (fresh) literal union: assigning the
// call result into a `let` widens it to the base primitive.
let leak = distinct(true); // leak: string
const s7: 'a' | 'b' = leak; // line 51: error (string)

// Distinct number literals -> union preserved.
function nums(c: boolean) {
  if (c) return 1;
  return 2;
}
const s8: 1 | 2 | 3 = nums(true); // clean
