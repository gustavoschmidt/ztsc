// A plain FUNCTION argument against a callable-INTERFACE parameter. tsc's
// `inferFromSignatures` pairs the source signature with the target's call
// signature; ztsc's object-parameter arm required the argument to be an object
// too, so the whole arm fell through and bound nothing.
//
// This is React's `forwardRef<T, P = {}>(render: ForwardRefRenderFunction<T,
// PropsWithoutRef<P>>)`: the render parameter is an interface (one call
// signature plus a `displayName?` property), so every inference position for
// `forwardRef((props: Props, ref) => …)` lives inside that signature. Without
// signature pairing `P` stayed at its `{}` default and `T` at `unknown`, and the
// resulting component rejected all of its own props.
type Props = { a?: string; b: number };
type Fwd<T> = ((instance: T | null) => void) | null;

interface RenderFn<T, P> {
  (props: P, ref: Fwd<T>): string | null;
  displayName?: string | undefined;
}
type WithoutRef<P> = P extends any
  ? "ref" extends keyof P
    ? Omit<P, "ref">
    : P
  : P;
interface Exotic<P> {
  (props: P): string | null;
}
declare function forwardRef<T, P = {}>(
  render: RenderFn<T, WithoutRef<P>>,
): Exotic<WithoutRef<P> & { ref?: Fwd<T> }>;

const F = forwardRef((props: Props, ref: Fwd<string>) => null);
// `P` was recovered from the render function's props parameter, so the
// component's own props are `Props` (plus `ref`), not `{}`.
const okF: string | null = F({ b: 1, ref: null });
declare function propsOf<Q>(f: Exotic<Q>): Q;
const q = propsOf(F);
const okQ: { a?: string; b: number; ref?: Fwd<string> } = q;
const badQ: { a: string; b: number } = q;

// A bare (non-interface) function parameter is unchanged.
declare function plain<A, B>(f: (a: A) => B): [A, B];
const pair = plain((n: number) => "s");
const okPair: [number, string] = pair;

export {};
