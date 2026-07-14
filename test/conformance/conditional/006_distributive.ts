// A naked type-parameter check distributes over a union member-wise.
type Boxed<T> = T extends any ? T[] : never;
// Boxed<string | number> = string[] | number[]
const a: Boxed<string | number> = ["x"]; // string[] is a member
const b: Boxed<string | number> = [1]; // number[] is a member
const c: Boxed<string | number> = [true]; // neither member -> TS2322

// Wrapping the check in a tuple ([T]) suppresses distribution, so the whole
// union is tested at once and T stays the union in the branch.
type BoxedW<T> = [T] extends [any] ? T[] : never;
// BoxedW<string | number> = (string | number)[]
const d: BoxedW<string | number> = ["x", 1];
const e: BoxedW<string | number> = [true]; // TS2322

// `never` distributes to `never` (empty union).
type D<T> = T extends any ? 1 : 2;
const f: D<never> = 1; // D<never> is never -> TS2322 (nothing assignable)

// Wrapped never does NOT distribute: [never] extends [any] is true -> 1.
type ND<T> = [T] extends [any] ? 1 : 2;
const g: ND<never> = 1;
const h: ND<never> = 2; // TS2322
