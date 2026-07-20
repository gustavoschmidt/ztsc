// A distributive conditional whose CHECK is an `infer` variable that was bound
// to a UNION (by a non-distributive enclosing conditional) must distribute over
// that union member-wise. Distilled from immer's `WritableNonArrayDraft` value
// type — `T[K] extends infer V ? V extends object ? Draft<V> : V : never` —
// where the outer `T[K] extends infer V` is non-distributive (the check is an
// indexed access, not a naked type parameter), so `V` captures the *whole*
// union `T[K]`, and the inner `V extends object` is the distributive check.
//
// Before the fix, substituting the resolved union into the inner conditional's
// branches baked the whole union into `Wrap<V>` (yielding `Wrap<Error | null>`)
// before the distributive conditional could split it, so the result leaked an
// undistributed `Wrap<Error | null>` instead of `Wrap<Error> | null`.

type Wrap<T> = { readonly w: T };

// `[T]` (a tuple) is a non-distributive check, so `V` binds the whole union.
type F<T> = [T] extends [infer V] ? (V extends object ? Wrap<V> : V) : never;

// F<Error | null> distributes the inner check: Error is an object -> Wrap<Error>,
// null is not -> null. Result: Wrap<Error> | null.
const a: F<Error | null> = null; // ok
const b: F<Error | null> = { w: new Error() }; // ok
const c: F<Error | null> = 3; // TS2322 (number is neither Wrap<Error> nor null)

// The narrowed target only accepts the correctly-distributed shape; the
// undistributed `Wrap<Error | null> | Error | null` would fail here.
declare const r: F<Error | null>;
const d: Wrap<Error> | null = r; // ok

// A primitive-only union takes the false branch for every member (no object),
// so F<string | number> === string | number.
const e: F<string | number> = "s"; // ok
const f: F<string | number> = true; // TS2322
