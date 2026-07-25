// An arrow contextually typed by a GENERIC function type is generalized over
// that type's type parameters: assigning `(cb, options) => base(cb, {...})` to
// `typeof base` succeeds even when `base` has constrained type parameters whose
// defaults reference earlier ones (the `renderHook` higher-order wrapper).
// The arrow's param/return types reference `base`'s type-param symbols as free
// params; both signatures must collapse those shared params to their
// constraints to relate.
interface Queries {
  q: number;
}
type Rendererable = { nodeType: number };
interface BaseRenderOptions<Q, C, B> {
  container?: C;
  baseElement?: B;
  queries?: Q;
}
interface RenderHookOptions<
  Props,
  Q extends Queries = Queries,
  Container extends Rendererable = Rendererable,
  BaseElement extends Rendererable = Container,
> extends BaseRenderOptions<Q, Container, BaseElement> {
  initialProps?: Props | undefined;
}
interface RenderHookResult<Result, Props> {
  result: Result;
}
declare function base<
  Result,
  Props,
  Q extends Queries = Queries,
  Container extends Rendererable = Rendererable,
  BaseElement extends Rendererable = Container,
>(
  render: (initialProps: Props) => Result,
  options?: RenderHookOptions<Props, Q, Container, BaseElement> | undefined,
): RenderHookResult<Result, Props>;

const wrapped: typeof base = (cb, options) => base(cb, { ...options });

export { wrapped };
