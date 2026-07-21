// Recursive dotted-path builder (the minimal react-hook-form `Path<F>` shape):
// a conditional alias `PathImpl<Kp, Vp>` whose FALSE branch embeds the mutually-
// recursive alias reference `PathInternal<Vp>` INSIDE a template-literal hole —
// `` `${Kp}.${PathInternal<Vp> & string}` `` — and `PathInternal<T>` maps each
// key of `T` back through `PathImpl`. Reducing `PathInternal<F>` for a concrete
// object `F` must drive the hole's ref home to the finite dotted-path union
// (`"nested" | "nested.deep" | "weight"`), exactly as tsc does.
//
// The defect (fixed): a template hole of the form `Ref & string` — an alias
// `.ref` (or a union of literals) intersected with the `string` constraint —
// was not enumerated. `enumerableForms` only recognized a SINGLE literal in the
// intersection, so `PathInternal<{deep}> & string` stayed an opaque pattern and
// the nested path `"nested.deep"` was wrongly rejected (a false positive). The
// fix resolves each intersection member structurally (driving the recursive
// ref under the ordinary shrinking discipline) and absorbs the primitive
// constraint, so the hole enumerates to `"deep"` and the template to
// `"nested.deep"`.
//
// Params are named apart (`Kp`/`Vp`/`Ev` vs the mapped key `K`) so the case
// isolates the template-hole reduction alone, with no name-collision shadowing
// in play.
type Prim = string | number | boolean | null | undefined;
type ArrayKey = number;
type IsTuple<T extends readonly any[]> = number extends T["length"] ? false : true;
type TupleKeys<T extends readonly any[]> = Exclude<keyof T, keyof any[]>;
type IsEq<A, B> = (<G>() => G extends A ? 1 : 2) extends (<G>() => G extends B ? 1 : 2) ? true : false;
type AnyIsEqual<T1, T2> = T1 extends T2 ? (IsEq<T1, T2> extends true ? true : never) : never;
type PathImpl<Kp extends string | number, Vp, Tr> = Vp extends Prim
  ? `${Kp}`
  : true extends AnyIsEqual<Tr, Vp>
    ? `${Kp}`
    : `${Kp}` | `${Kp}.${PathInternal<Vp, Tr | Vp> & string}`;
type PathInternal<T, Tr = T> = T extends ReadonlyArray<infer Ev>
  ? IsTuple<T> extends true
    ? { [K in TupleKeys<T>]-?: PathImpl<K & string, T[K], Tr> }[TupleKeys<T>]
    : PathImpl<ArrayKey, Ev, Tr>
  : { [K in keyof T]-?: PathImpl<K & string, T[K], Tr> }[keyof T];
type Path<T> = T extends any ? PathInternal<T> : never;

type F = { weight: number; nested: { deep: string } };
const a: Path<F> = "weight"; // ok
const b: Path<F> = "nested"; // ok
const c: Path<F> = "nested.deep"; // ok — the reduced dotted path
const d: Path<F> = "nope"; // TS2322 — not a member of the field-name union
export {};
