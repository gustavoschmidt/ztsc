// Inferring from a SOURCE signature whose trailing rest parameter is typed
// by a fixed tuple: tsc's `getExpandedParameters` turns `(...args: [A, B])`
// into the positional list `(a: A, b: B)` before any parameter is paired up,
// so `T extends (first: A, ...rest: infer P) => infer R` sees `P = [B]`.
//
// Unexpanded, the whole tuple was matched against the pattern's FIRST
// parameter and `P` came out as the empty tuple; the conditional's own
// `extends` check then failed (the source needs two arguments, the
// instantiated pattern offers one) and the type fell to the `never` branch.
// Every use of such an alias — the `BoundFunction<Q[P]>` shape testing
// libraries publish — was a TS2339 on `never`.

interface Elem {
  innerHTML: string;
  tagName: string;
}
type Matcher = string | RegExp;
type Params<T> = T extends (...args: infer P) => any ? P : never;
type Ret<T> = T extends (...args: any) => infer R ? R : never;

type BoundFunction<T> = T extends (container: Elem, ...args: infer P) => infer R
  ? (...args: P) => R
  : never;

// A rest parameter typed by an explicit tuple.
type Explicit = (...args: [Elem, Matcher]) => Elem;
declare const explicit: BoundFunction<Explicit>;
export const fromExplicit = explicit("id").innerHTML;

// …by `Params<>` of a plain function type.
type ViaParams = (...args: Params<(c: Elem, id: Matcher) => Elem>) => Elem;
declare const viaParams: BoundFunction<ViaParams>;
export const fromParams = viaParams("id").innerHTML;

// …by `Params<>` of a GENERIC alias, on a generic signature whose return is
// `Ret<>` of the same alias. This is the real testing-library shape.
type GetByBoundAttribute<T extends Elem = Elem> = (
  container: Elem,
  id: Matcher,
  options?: { exact?: boolean },
) => T;

declare const queries: {
  getByTestId<T extends Elem = Elem>(
    ...args: Params<GetByBoundAttribute<T>>
  ): Ret<GetByBoundAttribute<T>>;
  getByTitle<T extends Elem = Elem>(
    ...args: Params<GetByBoundAttribute<T>>
  ): Ret<GetByBoundAttribute<T>>;
};

type RenderResult<Q = typeof queries> = { container: Elem } & {
  [P in keyof Q]: BoundFunction<Q[P]>;
};
declare function render(ui: unknown): RenderResult;

export function viaMappedType() {
  const { getByTestId, getByTitle } = render(null);
  return [
    getByTestId("test1").innerHTML,
    getByTitle("title", { exact: false }).tagName,
  ];
}

// The optional element of the expanded list stays optional…
declare const explicitOptional: BoundFunction<
  (...args: [Elem, Matcher, ({ exact?: boolean } | undefined)?]) => Elem
>;
export const omitted = explicitOptional("id").innerHTML;
export const supplied = explicitOptional("id", { exact: true }).innerHTML;

// …and a variadic tail stays a rest element.
declare const explicitVariadic: BoundFunction<
  (...args: [Elem, Matcher, ...number[]]) => Elem
>;
export const variadic = explicitVariadic("id", 1, 2, 3).innerHTML;
