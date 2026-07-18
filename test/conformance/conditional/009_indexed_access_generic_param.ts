// Conditional over an indexed access of a generic type param (i18next's
// `TReturnOptionalObjects` shape): `TOpt['returnObjects'] extends true`.
// An absent/optional property must take the FALSE branch — tsc resolves a
// missing type-level access to `unknown` (not `any`), and an un-inferred
// type param inside a later param's constraint must be substituted with
// its *resolved* value (declaration-order inference), not an `any`
// placeholder.
type Special = { special: true };
interface OptsBase {
  returnObjects?: boolean;
}
type TReturn<TOpt extends OptsBase> = TOpt["returnObjects"] extends true
  ? Special
  : string;

// Shape 1: un-inferred `TOpt` referenced by a later param's constraint
// (`Ret extends TReturn<TOpt>`) — the call supplies neither. tsc resolves
// TOpt to its constraint in declaration order, so `t()` returns `string`.
interface TFunc {
  <TOpt extends OptsBase, Ret extends TReturn<TOpt>>(key: string): Ret;
}
declare const t: TFunc;
const a: string = t("bar");

// Shape 2: direct instantiation with `{}` — the property is absent, the
// access is `unknown`, `unknown extends true` is false -> `string`.
const b: string = null as unknown as TReturn<{}>;

// Property present but only `boolean` — still the false branch.
const c: string = null as unknown as TReturn<OptsBase>;
const d: string = null as unknown as TReturn<{ returnObjects: boolean }>;

// Negative control: a genuine `true` takes the TRUE branch -> TS2322.
const e: string = null as unknown as TReturn<{ returnObjects: true }>;
// ...and the true branch's value is accepted where `Special` is wanted.
const f: Special = null as unknown as TReturn<{ returnObjects: true }>;
