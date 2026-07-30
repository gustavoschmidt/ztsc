// A generic type ALIAS on both sides of an inference position pairs its type
// ARGUMENTS (tsc's `inferFromTypes`: "source and target are types originating in
// the same generic type alias declaration — simply infer from source type
// arguments to target type arguments"). That rule sits ABOVE reverse mapping:
// rebuilding `P` out of the members of `WVM<P>` loses whatever the value
// template cannot invert, and the rebuild drops the optionality that the map
// itself added, so every property comes back REQUIRED.
//
// This is the `React.createElement(Ctx.Provider, { value })` shape:
// `FunctionComponent<P>`'s `propTypes?: WeakValidationMap<P>` meets a provider's
// `propTypes?: WeakValidationMap<ProviderProps<T>>`, and the rebuilt covariant
// candidate used to beat the call signature's contravariant one.

type Node2 = string | null | undefined;

interface Validator<T> {
  (props: { [k: string]: unknown }, key: string): Error | null;
  tag?: T;
}

type WVM<T> = {
  [K in keyof T]?: null extends T[K] ? Validator<T[K] | null | undefined>
    : undefined extends T[K] ? Validator<T[K] | null | undefined>
    : Validator<T[K]>;
};

interface Props {
  value: string;
  children?: Node2 | undefined;
}

// (1) Written inline in the signature.
declare function inline<P>(t: { propTypes?: WVM<P> | undefined }): P;
declare const a1: { readonly tagsym: symbol; propTypes?: WVM<Props> | undefined };
const r1: 0 = inline(a1);

// (2) Reached through a generic interface's member, which re-instantiates the
//     alias at every use — the origin tag has to survive that.
interface Target<P> {
  propTypes?: WVM<P> | undefined;
}
interface Source<P> {
  readonly tagsym: symbol;
  propTypes?: WVM<P> | undefined;
}
declare const a2: Source<Props>;
declare function viaInterface<P>(t: Target<P>): P;
const r2: 0 = viaInterface(a2);

// (3) The full shape: a call signature (contravariant `P`) beside `propTypes`.
interface FC<P> {
  (props: P): Node2;
  propTypes?: WVM<P> | undefined;
}
interface Exotic<P> {
  (props: P): Node2;
  readonly tagsym: symbol;
  propTypes?: WVM<P> | undefined;
}
declare const a3: Exotic<Props>;
declare function render<P extends {}>(t: FC<P>, props?: P | null): P;
const r3: 0 = render(a3, { value: 'x' });

// (4) A DIRECT structural candidate still outranks the pairing: `T` is the type
//     the first two arguments supply, not the alias argument that the erased
//     generic callback names.
interface Observed {
  tag: string;
}
declare function calculate<T extends Observed>(
  prev: T,
  next: T,
  post?: (deleted: Partial<T>) => Partial<T>,
): T;
declare function post<P extends Observed>(deleted: Partial<P>): Partial<P>;
function keepsDirect<S extends Observed>(prev: S, next: S) {
  const out = calculate(prev, next, post);
  const same: S = out;
  return same;
}

export { r1, r2, r3, keepsDirect };
