// Higher-order signature admission for a template-literal-bearing bound (the
// react-hook-form `register`/`watch` shape). An interface `FormApi<TFieldValues>`
// carries a generic method whose OWN type param is bound by the recursive
// dotted-path alias `Path<TFieldValues>` — a bound containing a template-literal
// pattern. Instantiating `FormApi<F>` must (re-)instantiate that signature with
// the outer `TFieldValues = F`, so the field-name literal argument is related to
// the concrete `Path<F>` union — a valid name is accepted, an invalid one is
// still rejected (the soundness control).
//
// Before this change the signature was GATED: `boundReducible` returned false
// for a `.template_literal_type` bound, so `higherOrderSigEligible` judged the
// interface concrete and dropped the sig — leaving `TFieldValues` unsubstituted,
// which made every valid field-name literal a false positive (TS2345 against the
// un-reduced `Path<TFieldValues>` conditional). Now that the reducer chain drives
// `Path<F>` home for a concrete `F`, `boundHasReducerShape` admits the sig, so
// the ordinary relation runs and the reduced field-name union gates correctly.
//
// The `Path` builder is the same finite dotted-path reducer proven in case 017;
// only the delivery changes — through an instantiated generic interface method's
// structured type-param bound rather than a direct alias reference.
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

// The generic method's own param `TName` has the structured bound `Path<TFieldValues>`.
interface FormApi<TFieldValues> {
  register<TName extends Path<TFieldValues>>(name: TName): TName;
}

type F = { weight: number; nested: { deep: string } };
declare const form: FormApi<F>;

const a = form.register("weight"); // ok
const b = form.register("nested"); // ok
const c = form.register("nested.deep"); // ok — the reduced dotted path
const d = form.register("nope"); // TS2345 — not a member of Path<F>

export {};
