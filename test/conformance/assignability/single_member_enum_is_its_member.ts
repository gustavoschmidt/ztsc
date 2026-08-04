// tsc's declared type of an enum is the union of its member types, so an
// enum with exactly ONE member and that member are the same type and relate
// in both directions.
export enum One {
  A = "A",
}
export enum OneNum {
  X = 1,
}
export enum Two {
  A = "A",
  B = "B",
}

declare const one: One;
declare const oneA: One.A;
declare const oneNum: OneNum;
declare const two: Two;

export const a1: One.A = one;
export const a2: One = oneA;
export const a3: One.A[] = [] as One[];
export const a4: One[] = [] as One.A[];
export const a5: OneNum.X = oneNum;
export const a6: { v: One.A } = { v: one };

// A multi-member enum keeps the one-way relation.
export const b1: Two = two;
export const b2: Two = Two.A;
