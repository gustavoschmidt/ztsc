// Negatives for 033: letting an intersection source reach the conditional-target
// arm must not accept a source that misses a branch.
type Radians = number & { _brand: "radian" };
type Degrees = number & { _brand: "degree" };
declare const r: Radians;
declare const n: number;

// The source is not the brand at all.
export const f1 = <T extends number>(): T extends 0 ? Radians : Radians => n;

// A DIFFERENT brand: neither branch admits it.
export const f2 = <T extends number>(): T extends 0 ? Degrees : Degrees => r;

// The branches disagree and the source only satisfies one of them.
export const f3 = <T extends boolean>(): T extends true ? Radians : Degrees => r;

// A widened intersection source against narrower branches.
type P = { a: string } & { b: number };
declare const p: P;
export const f4 = <T extends boolean>(): T extends true ? { a: string; c: boolean } : { a: string } => p;

// An intersection whose constituents individually miss a required member of the
// branch, and whose merge misses it too.
type Q = { a: string } & { b: number };
declare const q: Q;
export const f5 = <T extends boolean>(): T extends true ? { a: string; z: number } : { a: string; z: number } => q;
