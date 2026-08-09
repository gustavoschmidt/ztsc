// The contextual element type an array-like INTERFACE now supplies must be as
// binding as a plain `Array<T>`'s: it TYPES the elements, it does not accept
// them. Every case below is a false-negative guard for the fix in
// `contextualArrayElemType`.

interface AlinStyle {
  w?: 'a' | 'b' | undefined;
  n?: number | undefined;
}

interface AlinRec<T> extends Array<T | ReadonlyArray<T> | AlinRec<T>> {}
interface AlinPlain<T> extends Array<T> {}

// A literal outside the contextual union.
const alin1: AlinRec<AlinStyle> = [{w: 'c'}];
const alin2: AlinPlain<AlinStyle> = [{w: 'c'}];
// The plain-`Array` control, which always reported.
const alin3: AlinStyle[] = [{w: 'c'}];

// A wrong property type.
const alin4: AlinPlain<AlinStyle> = [{n: 'no'}];
const alin5: AlinRec<AlinStyle> = [{n: 'no'}];

// Through the StyleProp-shaped union. The bare `T` constituent is left out on
// purpose: `AlinStyle` is a WEAK type (every property optional) and ztsc does
// not yet run the weak-type check (TS2559) when the source is an ARRAY, so
// `{w: string}[]` is wrongly accepted as an `AlinStyle` and swallows the
// element error. That gap is independent of this fix — it reads identically
// with and without it — and is tracked separately; pinning it here would
// snapshot a divergence rather than the behaviour under test.
type AlinRegistered<T> = number & {__alinBrand: T};
type AlinFalsy = undefined | null | false | '';
type AlinProp<T> =
  | AlinRegistered<T>
  | AlinRec<T | AlinRegistered<T> | AlinFalsy>
  | AlinFalsy;
const alin6: AlinProp<AlinStyle> = [{w: 'c'}];

// An interface reached through an intermediate interface.
interface AlinMid<T> extends Array<T> {}
interface AlinDeep<T> extends AlinMid<T> {}
const alin7: AlinDeep<AlinStyle> = [{n: 'no'}];
