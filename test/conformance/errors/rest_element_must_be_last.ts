// TS2462: a rest element is the LAST element of a destructuring pattern or
// nothing. tsc blames the bound NAME, not the `...` — measured against
// tsgo 7.0.2, which answers at the `a` of `var [...a, x]` and at the
// `mustBeLast` of `var { ...mustBeLast, b }`.
//
// Grammatical rather than syntactic, so the rest of the file is still checked:
// the TS2339 below survives beside it.
declare const o: { a: number; b: string };
declare const nums: number[];

var [...a, x] = nums;
var { ...mustBeLast, a: aa } = o;
function f({ ...ml, a }: { a: number; b: string }): void {}
function g([...r, s]: number[]): void {}

var { ...rest2 } = o;
var [...tail] = nums;

const missing = o.nope;
