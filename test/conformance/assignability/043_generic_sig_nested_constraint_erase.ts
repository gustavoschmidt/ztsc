// Relating a generic call signature to a plain function type erases the
// signature's type parameters to their constraints (tsc `getBaseSignature`).
// When one type parameter's constraint itself references ANOTHER type
// parameter — e.g. a return parameter `Ret` whose constraint is a conditional
// over an indexed access on `TOpt` — a single substitution leaves a deferred
// conditional that never reduces. tsc drives the base constraints to a fixed
// point so the nested reference collapses; ztsc must do the same, else a
// perfectly valid signature (the shape of react-i18next's `TFunction`) is
// wrongly rejected against `(key: string) => string`.

interface Opts {
  returnObjects?: false;
  count?: number;
}

// Return param `Ret`'s constraint mentions `TOpt`. Fixed-point erasure drives
// `TOpt` → `Opts`, so `Opts['returnObjects'] extends true ? object : string`
// collapses to `string`.
interface StrFn {
  <TOpt extends Opts, Ret extends (TOpt['returnObjects'] extends true ? object : string)>(
    ...args: [key: string, options?: TOpt]
  ): Ret;
}
declare const s: StrFn;

// Positive: erased return is `string`, assignable to a plain function.
const f1: (key: string) => string = s;
const f2: (key: string, options?: { count?: number }) => string = s;

// Positive: an object member carrying such a callable is assignable too.
interface Holder {
  t: StrFn;
}
declare const h: Holder;
const target: { t: (key: string) => string } = h;

// Negative control: same nested-constraint erasure, but the (non-distributive)
// conditional collapses to `object`, so the erased return is `object`, which is
// NOT assignable to a `string`-returning target. Proves the fixed-point erasure
// still resolves the conditional to a concrete type rather than blindly
// accepting — it is not an over-permissive escape hatch.
interface ObjFn {
  <TOpt extends Opts, Ret extends ([TOpt['returnObjects']] extends [true] ? string : object)>(
    ...args: [key: string, options?: TOpt]
  ): Ret;
}
declare const o: ObjFn;
const bad: (key: string) => string = o;
