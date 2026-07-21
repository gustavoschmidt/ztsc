// A recursive dotted-path builder (the minimal react-hook-form `PathInternal`
// shape) declared in a LIBRARY (`.d.ts`) file. `PInt<T, Tr = T>` carries an
// accumulator default `Tr = T` — a *bare* reference to its own earlier param —
// and threads `Tr` through the mutual recursion `PInt<Vp, Tr | Vp>`. Its
// termination guard `true extends AnyIsEqual<Tr, Vp>` only fires once `Tr` is
// the concrete form, so a one-arg `PInt<F>` MUST bind the default to the
// supplied `F`, not to the bare param symbol. On the `.d.ts` path that default
// substitution was disabled (a blanket guard against a deep-generic OOM), so
// `Tr` leaked as the free param `T` and the field-name union came out malformed
// (`true extends T extends {…} ? …`), wrongly rejecting every path. The fix
// substitutes the accumulator default of a *self-recursive* alias even in a
// `.d.ts` (a single symbol swap, no expansion — no OOM), while non-recursive
// library defaults stay on the prior unsubstituted path.
//
// Params are named apart (`Kp`/`Vp`/`Ev`/`Tr` vs the mapped key `K`) so the case
// isolates the cross-module accumulator-default binding with no name-collision
// shadowing in play.
type Prim = string | number | boolean | null | undefined;
type ArrayKey = number;
type IsTuple<T extends readonly any[]> = number extends T["length"] ? false : true;
type TupleKeys<T extends readonly any[]> = Exclude<keyof T, keyof any[]>;
type IsEq<A, B> = (<G>() => G extends A ? 1 : 2) extends (<G>() => G extends B ? 1 : 2) ? true : false;
type AnyIsEqual<T1, T2> = T1 extends T2 ? (IsEq<T1, T2> extends true ? true : never) : never;
type PImpl<Kp extends string | number, Vp, Tr> = Vp extends Prim
  ? `${Kp}`
  : true extends AnyIsEqual<Tr, Vp>
    ? `${Kp}`
    : `${Kp}` | `${Kp}.${PInt<Vp, Tr | Vp> & string}`;
export type PInt<T, Tr = T> = T extends ReadonlyArray<infer Ev>
  ? IsTuple<T> extends true
    ? { [K in TupleKeys<T>]-?: PImpl<K & string, T[K], Tr> }[TupleKeys<T>]
    : PImpl<ArrayKey, Ev, Tr>
  : { [K in keyof T]-?: PImpl<K & string, T[K], Tr> }[keyof T];
export type DPath<T> = T extends any ? PInt<T> : never;
