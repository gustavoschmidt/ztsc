// A type param that lives only in a *callable interface* parameter's call
// signature (`FunctionComponent<P>`'s `(props: P) => …`) must be inferred from
// a callable-OBJECT argument's call signature — e.g. React's
// `createElement(Ctx.Provider, { value })`, where `Ctx.Provider` is a
// `ProviderExoticComponent<ProviderProps<T>>` (an object carrying a call sig +
// `$$typeof`). Without call-signature inference on object params, `P` stays at
// its default `{}` and the call is rejected. Expected clean.
type RNode = string | number | null | undefined | {};

interface FC<P = {}> {
  (props: P, ctx?: any): RNode;
  displayName?: string;
}
interface Attributes {
  key?: string | null;
}
declare function createElement<P extends {}>(
  type: FC<P>,
  props?: (Attributes & P) | null,
  ...children: RNode[]
): P;

interface ExoticComponent<P> {
  (props: P): RNode;
  readonly $$typeof: symbol;
}
interface ProviderProps<T> {
  value: T;
  children?: RNode;
}
type Provider<T> = ExoticComponent<ProviderProps<T>>;

type Data = { a: number; b: string };
declare const Prov: Provider<Data>;

// P is inferred as ProviderProps<Data> from Prov's call signature: OK.
const ok = createElement(Prov, { value: { a: 1, b: "x" } });
