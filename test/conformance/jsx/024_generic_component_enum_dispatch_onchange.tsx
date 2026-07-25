declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {}
}

// Inferring a generic component's type argument must not let a contravariant
// candidate (from a callback's PARAMETER position) override the covariant one.
// `onChange={setSex}` where `setSex: (v: SetStateAction<E>) => void` would
// otherwise pollute `T` with `E | ((p: E) => E)`, violating `T extends string`
// and clamping `T` to `string` — after which `onChange` fails contravariantly.
// `T` must resolve to `E` (from `value`/`options`), keeping the call valid.
enum E {
  A = 'a',
  B = 'b',
}
type SetStateAction<S> = S | ((prev: S) => S);
declare function SC<T extends string>(p: {
  value: T;
  onChange: (v: T) => void;
  options: { value: T }[];
}): JSX.Element;

declare const sex: E;
declare const setSex: (value: SetStateAction<E>) => void;

const ok = <SC value={sex} onChange={setSex} options={[{ value: E.A }, { value: E.B }]} />;

export { ok };
