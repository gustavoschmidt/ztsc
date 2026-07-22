// A value of the global `Function` type is callable, yielding `any` and
// accepting any arguments — tsc special-cases `Function` as callable even
// though its interface body carries no call signature.
declare const f: Function;
f();
f(1, "x");
const r: unknown = f("a");

// NEGATIVE CONTROL: a plain object with no call signature is not callable.
declare const o: { a: number };
o();

// NEGATIVE CONTROL: a primitive is not callable.
declare const s: string;
s();
