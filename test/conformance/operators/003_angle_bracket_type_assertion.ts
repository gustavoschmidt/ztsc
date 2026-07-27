// The pre-`as` angle-bracket type assertion `<T>expr` is still legal in a
// non-JSX file. ztsc read the `<` as a relational operator and failed with
// "expected an expression". It is the same operation as `expr as T`, so the
// same TS2352 overlap check applies.
interface P {
  a: number;
}
declare const o: unknown;
declare const n: unknown;

const q = <P>o;
const q2 = <P>(o as any);
const q3: number = (<P>o).a;
const arr = <number[]>n;
const fn = <(x: number) => number>n;
const un = !<P>o;
const chain = <P>o as unknown;

// `<const>x` is the angle-bracket spelling of `x as const`.
const c1 = <const>1;
const c2: 1 = c1;

// `<` still lexes as a relational / shift operator in operand position.
declare const a: number;
declare const b: number;
const cmp: boolean = a < b;
const sh: number = a << b;

// The asserted type is really checked.
const bad = <string>1;
