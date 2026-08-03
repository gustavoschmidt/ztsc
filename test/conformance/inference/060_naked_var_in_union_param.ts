// A union parameter with exactly one naked inference variable in it. tsc's
// `inferToMultipleTypes` first infers to the union's NON-variable members and
// records a source constituent as "matched" only when doing so actually
// produced an inference; a member with no inference sites in it never does.
// The whole (unmatched) source is then inferred to the naked variable.
//
// So a concrete member that merely *accepts* the argument does not stop the
// variable from taking it. `T | { a: number }` still infers
// `{ a: number; b: string }` for `T`, and the difference is observable: a
// variable that inferred nothing falls back to its own constraint, which here
// would drop `b`.
//
// zod's `pipe<T extends $ZodType<any, output<this>>>(target: T |
// $ZodType<any, output<this>>)` is this shape, which is why it matters.

declare function bare<T extends { a: number }>(x: T): T;
declare function alongsideConcrete<T extends { a: number }>(x: T | { a: number }): T;
declare function alongsideNull<T extends { a: number }>(x: T | null): T;
declare function unconstrained<T>(x: T | string): T;

declare const arg: { a: number; b: string };

const r1 = bare(arg);
const r2 = alongsideConcrete(arg);
const r3 = alongsideNull(arg);
const r4 = unconstrained(arg);

// All four inferred the argument, so `b` is present on every one.
const b1: string = r1.b;
const b2: string = r2.b;
const b3: string = r3.b;
const b4: string = r4.b;

// A member that CAN infer still wins over the naked variable: `T` takes the
// element, not the whole array.
declare function wrapped<T>(x: T | readonly T[]): T;
const w1: number = wrapped([1, 2, 3]);
const w2: number = wrapped(4);

// And the residual rule is unchanged: identical constituents pair off first.
declare function residual<T>(x: T | undefined): T;
const u1: number = residual<number>(undefined as number | undefined);

export { b1, b2, b3, b4, w1, w2, u1 };
