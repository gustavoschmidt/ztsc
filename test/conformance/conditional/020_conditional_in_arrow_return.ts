// An arrow function's return-type annotation is a full type, so it may be an
// unparenthesized conditional: the `=>` that ends the annotation is the one
// after a *complete* type. ztsc parsed the annotation under the function-type
// speculation flag, which left `extends` unclaimed — the annotation stopped at
// its check type, no `=>` followed, and the arrow backtracked into a
// parenthesized expression ("expected ')'").
type X = string;

export const g1 = (x: X): X extends null ? null : string => null as any;
export const g5 = <T,>(x: T): T extends null ? null : string => null as any;
export const g6 = (x: X): X[] => null as any;

// The conditional's branches may themselves be function types; the annotation
// must consume the whole conditional and stop at the *arrow's* `=>`.
export const g7 = (x: X): X extends string ? (y: number) => number : never =>
  (y) => y;

// Nested conditional in the false branch.
export const g8 = <T,>(x: T): T extends string ? 1 : T extends number ? 2 : 3 =>
  null as any;

// A type predicate return type still parses, and so does a plain one.
export const g9 = (x: unknown): x is string => typeof x === "string";
export const g10 = (x: X): X => x;

// Ambiguity guard: `cond ? (b) : c` is a conditional *expression*, not an
// arrow with a return type.
declare const a: boolean;
declare const b: number;
declare const c: number;
export const r1 = a ? (b) : c;
export const r2: number = a ? (b) : (c);

// The annotation's type is really used: a wrong result type is an error.
export const bad = (x: X): X extends null ? null : string => 0;
