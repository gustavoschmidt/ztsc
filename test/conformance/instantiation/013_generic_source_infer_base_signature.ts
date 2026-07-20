// Inferring through a GENERIC source signature into conditional-type `infer`
// positions must reduce the source to its base signature first: each of the
// source's own type params erases to its constraint (or `unknown` when
// unconstrained) — tsc's getBaseSignature. Before the fix the source's bound
// params leaked into the infer result (`[T, T]` instead of `[unknown, unknown]`),
// which is why RTK enhancer-tuple reductions never bottomed out. Each `SHOW`
// assignment forces the reduced type into a TS2322 message so the snapshot
// pins the exact reduction.

// basic: <T> unconstrained -> unknown, unknown
type V1 = (<T>(x: T) => T) extends (x: infer A) => infer B ? [A, B] : "no";
const _v1: "SHOW" = 0 as unknown as V1;

// constrained: <T extends string> -> string, string
type V2 = (<T extends string>(x: T) => T) extends (x: infer A) => infer B ? [A, B] : "no";
const _v2: "SHOW" = 0 as unknown as V2;

// default only: <T = number> -> unknown, unknown (default is ignored)
type V3 = (<T = number>(x: T) => T) extends (x: infer A) => infer B ? [A, B] : "no";
const _v3: "SHOW" = 0 as unknown as V3;

// multiple params: <T, U> -> unknown, unknown, [unknown, unknown]
type V4 = (<T, U>(x: T, y: U) => [T, U]) extends (x: infer A, y: infer B) => infer C ? [A, B, C] : "no";
const _v4: "SHOW" = 0 as unknown as V4;

// return-only infer: <T>() => T -> unknown
type V7 = (<T>() => T) extends () => infer B ? B : "no";
const _v7: "SHOW" = 0 as unknown as V7;

// negative control (whole-capture): a generic function captured directly by an
// infer var is preserved as-is, not erased — the infer var binds the entire
// generic signature `<T>(x: T) => T`.
type V5 = ((cb: <T>(x: T) => T) => void) extends (cb: infer A) => void ? A : "no";
const _v5: "SHOW" = 0 as unknown as V5;

// negative control (ordinary call-site inference): passing a generic function
// where a concrete signature is expected still unifies the source's param — R
// infers to number, so this line is CLEAN (no diagnostic).
declare function apply<R>(fn: (x: number) => R): R;
const idn = <T>(x: T): T => x;
const callsite: number = apply(idn);
