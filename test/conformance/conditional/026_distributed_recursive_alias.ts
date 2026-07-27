// A distributive conditional over a union produces a union of one-step alias
// refs; each must be driven to a fixed point exactly as the undistributed
// single-member result is.
type A = { a: number };
type B = { b: string };

type W1 = Awaited<Promise<A>>;
declare const w1: W1;
// @negative
const x1: null = w1;

type W2 = Awaited<Promise<A> | Promise<B>>;
declare const w2: W2;
// @negative: must be `A | B`, not a pair of unreduced `Awaited<…>`
const x2: null = w2;

type W3 = Awaited<Promise<number> | Promise<string>>;
declare const w3: W3;
const x3: number | string = w3;
// @negative
const x4: number = w3;

type W4 = Awaited<Promise<A> | A>;
declare const w4: W4;
const x5: A = w4;

type W5 = Awaited<Promise<A> | number>;
declare const w5: W5;
const x6: A | number = w5;

// A hand-rolled shrinking accumulator still distributes and terminates.
type Tail<S extends string> = S extends `${string}.${infer R}` ? Tail<R> : S;
type T1 = Tail<"a.b.c" | "x.y">;
declare const t1: T1;
const x7: "c" | "y" = t1;
// @negative
const x8: "c" = t1;

// The growing-argument guard (a distributed `Grow<T> = … Grow<{deeper: T}>`)
// is covered by instantiation/003: its argument metric rises, so no member is
// driven and the lazy ref survives. It is omitted here because tsc reaches its
// own instantiation cap on it and reports TS2589, which is the documented
// under-report divergence rather than anything this case is testing.
