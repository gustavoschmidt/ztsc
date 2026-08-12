// tsc's `inferToMultipleTypes` always walks the SOURCE union constituent by
// constituent — `const sources = source.flags & TypeFlags.Union ?
// source.types : [source]`, then `for (const t of targets) … for (let i = 0; i
// < sources.length; i++) inferFromTypes(sources[i], t)`. The `matched[]`
// bookkeeping that record feeds is only consulted when the target union has
// exactly ONE naked type variable, but the SPLIT itself is unconditional.
// ztsc gated the split on that same "exactly one naked variable" test, so a
// target union with NO naked member (every constituent a wrapper) was handed
// the whole argument union — and a wrapper cannot invert a union: the function
// arm bails outright because a union is not a function, and the object arm has
// no properties to pair.
//
// @types/react 17's `forwardRef` is that shape. The render function's `ref`
// parameter is the only site mentioning `T`, and neither arm pairs off by
// symbol first — `Ref<T>`'s `RefObject<T>` and `ForwardedRef<T>`'s
// `MutableRefObject<T | null>` are DIFFERENT interfaces, and `RefCallback<T>`
// is an indexed access with no counterpart alias — so `inferFromMatchingTypes`
// leaves both sides whole and the split is the only route to a candidate. `T`
// fell to `unknown`, and every `React.forwardRef((props, ref) => …)` in an app
// was rejected against `ForwardRefRenderFunction<unknown, P>`.

interface RefObject<T> {
    readonly current: T | null;
}
interface MutableRefObject<T> {
    current: T;
}
// The bivariance hack: a METHOD, so its parameter infers covariantly.
type RefCallback<T> = { bivarianceHack(instance: T | null): void }["bivarianceHack"];
type Ref<T> = RefCallback<T> | RefObject<T> | null;
type ForwardedRef<T> = ((instance: T | null) => void) | MutableRefObject<T | null> | null;

interface RenderFn<T, P = {}> {
    (props: P, ref: ForwardedRef<T>): null;
}
interface Exotic<T, P> {
    ref: T;
    props: P;
}
declare function forwardRef<T, P = {}>(render: RenderFn<T, P>): Exotic<T, P>;

interface Div {
    tagName: "div";
}

// (a) `T` comes from the render function's `ref` parameter alone.
const fwd = forwardRef(function F(props: { a: string }, ref: Ref<Div>) {
    return null;
});
export const okRef: Div = fwd.ref;
export const okProps: { a: string } = fwd.props;
// The discriminator: `unknown` would make this legal.
export const badRef: string = fwd.ref;

// (b) Splitting the source must not manufacture candidates from UNRELATED
// pairs — that is what the by-symbol pass ahead of it is for. Offering
// `RetRes<number>` to `YieldRes<T>` would pair their `value` members and give
// `T` a `number` candidate (the `Array.from(gen)` → `void[]` hazard).
interface YieldRes<T> {
    done?: false;
    value: T;
}
interface RetRes<TReturn> {
    done: true;
    value: TReturn;
}
declare function bothOf<T, U>(x: YieldRes<T> | RetRes<U>): [T, U];
declare const res: YieldRes<string> | RetRes<number>;
export const pair: [string, number] = bothOf(res);
