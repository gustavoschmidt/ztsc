// tsc's `checkAssertionWorker` compares the asserted type against
// `getRegularTypeOfObjectLiteral(getBaseTypeOfLiteralType(exprType))` -- the
// SOURCE's literal types stand for their base primitives before the comparable
// test, whether or not the literal is fresh. That is why a cast between two
// unrelated literals of the same primitive is legal TypeScript.

declare const abc: 'abc';
declare const one: 1;
declare const yes: true;
declare const eight: 8;

const a = 'abc' as 'def';
const b = abc as 'def';
const c = 1 as 2;
const d = one as 2;
const e = yes as false;
const f = `calc(100% - ${eight}px)` as '100%';

// A union source widens member-wise.
declare const ab: 'a' | 'b';
const g = ab as 'c';

// The primitives themselves still have to overlap: widening a string literal
// gives `string`, which does not reach a number.
const h = abc as 2; // TS2352
const i = one as 'def'; // TS2352
declare const obj: { a: number };
const j = obj as 'def'; // TS2352

export { a, b, c, d, e, f, g, h, i, j };
