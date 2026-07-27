// Object literals widened in ONE widening context gain their siblings' keys
// as `key?: undefined` (tsc's getWidenedTypeOfObjectLiteral +
// getUndefinedProperty). A *declared* union gets no such normalization.
declare const cond: boolean;

// A. the `return` statements of one function
function fromReturns() {
  if (cond) {
    return { file: "a" };
  }
  return { errorMessage: 1 };
}
const r = fromReturns();
const a1: string | undefined = r.file;
const a2: number | undefined = r.errorMessage;
// @negative: the value is still one of the two shapes
const a3: null = r;

// three-way
function three() {
  if (cond) {
    return { p: 1 };
  }
  if (!cond) {
    return { q: 2 };
  }
  return { r: 3 };
}
const t = three();
const b1: number | undefined = t.p;
const b2: number | undefined = t.r;

// B. the arms of a conditional expression, through an un-annotated const
const cx = cond ? { file: "a" } : { errorMessage: 1 };
const c1: string | undefined = cx.file;
// @negative: the property type is not plain `string`
const c2: string = cx.file;

// C. `||`
const ox = (cond ? { file: "a" } : 0) || { errorMessage: 1 };
const d1: string | undefined = ox.file;

// D. a generic contextual return type fixes nothing, so it normalizes too
declare function myMap<U>(f: (s: string) => U): U[];
const mx = myMap((s) => {
  if (cond) {
    return { file: s };
  }
  return { errorMessage: 1 };
});
const e1: string | undefined = mx[0].file;

// E. @negative: a DECLARED union is never normalized
declare const decl: { file: string } | { errorMessage: number };
const f1 = decl.file;

// F. @negative: an annotated variable is not normalized either
const ann: { file: string } | { errorMessage: number } = cond
  ? { file: "a" }
  : { errorMessage: 1 };
const g1 = ann.file;

// G. identical key sets are untouched
function same() {
  if (cond) {
    return { k: 1 };
  }
  return { k: 2 };
}
const h1: number = same().k;
