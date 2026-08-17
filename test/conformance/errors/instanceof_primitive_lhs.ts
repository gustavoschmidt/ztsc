// tsc's `checkInstanceOfExpression` refuses a left operand every constituent
// of which is a PRIMITIVE (`allTypesAssignableToKind(leftType, Primitive)`):
// nothing that is not an object can be an instance of anything. ztsc had the
// right-hand-side gate (TS2359) but not this one.
//
// `any` and `unknown` are exempt. A type parameter answers through its
// CONSTRAINT — the kind test is assignability-based — a union is refused only
// when every constituent is primitive, and an intersection when any is (a
// branded `number & { _brand }` is still a number).

export {};

declare var a1: number;
declare var a2: boolean;
declare var a3: string;
declare var a5: symbol;
declare var a6: bigint;
declare var o1: {};
declare var o2: Date;
declare var x: any;
declare var u: unknown;

a1 instanceof x;
a2 instanceof x;
a3 instanceof x;
a5 instanceof x;
a6 instanceof x;
0 instanceof x;
true instanceof x;
"" instanceof x;
null instanceof x;
undefined instanceof x;

declare var un1: number | string;
un1 instanceof x;

declare var br: number & { _brand: "b" };
br instanceof x;

// Negative controls: an object type, a top type, and a union with one
// non-primitive constituent all pass.
o1 instanceof x;
o2 instanceof x;
x instanceof x;
u instanceof x;

declare var un2: number | {};
un2 instanceof x;

export function bare<T>(t: T) {
  return t instanceof x;
}

export function constrained<T extends string>(t: T) {
  return t instanceof x;
}

export function objectConstrained<T extends Date>(t: T) {
  return t instanceof x;
}
