// A rest parameter typed by a FIXED tuple is that parameter list:
// `(...args: [a: A, b: B])` behaves exactly like `(a: A, b: B)` for arity,
// argument checking and contextual parameter typing.
declare function f(...args: [a: string, b: number]): void;
f("x", 1);
f(1, 1); // TS2345 on the first argument
f("x"); // TS2554 too few
f("x", 1, 2); // TS2554 too many

// through an alias
type Args = [a: string, b: number];
declare function fa(...args: Args): void;
fa("x", 1);
fa(1, 1); // TS2345

// optional element = optional parameter; a trailing rest element stays unbounded
declare function k(...args: [a: string, b?: number, ...rest: boolean[]]): void;
k("x");
k("x", 1);
k("x", 1, true, false);
k("x", 1, 2); // TS2345 on the boolean position
k(); // TS2555 at-least-1

// contextual parameter typing through the tuple
type Fn = (...args: [a: string, b: number]) => void;
const g: Fn = (a, b) => {
  const s: string = a;
  const n: number = b;
  s;
  n;
};
const g2: Fn = (a: number, b: string) => {}; // TS2322

// signature relation: the expansion is visible on both sides
declare function h1(...args: [string, number]): void;
declare function h2(a: string, b: number): void;
const hA: (a: string, b: number) => void = h1;
const hB: (...args: [string, number]) => void = h2;
const h3: (a: string, b: string) => void = h1; // TS2322

// an unbounded rest keeps its array element type
declare function u(...args: number[]): void;
u(1, 2, 3);
u("x"); // TS2345

// NEGATIVE for the expansion: a VARIADIC tuple whose spread is not last has no
// positional expansion, so nothing may be rejected on arity or position.
type Sp<T> = { [K in keyof T]: T[K] };
declare function v<T extends readonly unknown[]>(...xs: [...Sp<T>, number]): void;
v("a", "b", 1);
v(1);

export { g, g2, hA, hB, h3 };
