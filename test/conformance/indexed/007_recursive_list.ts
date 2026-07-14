// Recursive generic type alias: a cons-list. Deferred self-ref via lazy ref,
// terminates via the depth budget (M16d).
type List<T> = { head: T; tail: List<T> | null };
const xs: List<number> = { head: 1, tail: { head: 2, tail: { head: 3, tail: null } } };
const bad: List<number> = { head: 1, tail: { head: "two", tail: null } };  // TS2322

// Mutually-recursive aliases.
type Expr = Lit | Add;
type Lit = { kind: "lit"; value: number };
type Add = { kind: "add"; left: Expr; right: Expr };
const e: Expr = { kind: "add", left: { kind: "lit", value: 1 }, right: { kind: "lit", value: 2 } };
