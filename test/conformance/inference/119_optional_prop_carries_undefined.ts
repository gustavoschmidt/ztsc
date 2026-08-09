// tsc's `inferFromProperties` pairs `getTypeOfSymbol` on both sides, and under
// `strictNullChecks` an OPTIONAL property's type carries `| undefined`. That
// matters for union-to-union inference: the source's `undefined` constituent
// pairs off identically with the target's and is REMOVED, so only the residual
// reaches the naked type variable. Dropping the implicit `| undefined` left it
// unpaired and it rode into every inferred argument.
//
// react-query is the shape that motivates it: `fetchQuery<TQueryFnData, TData =
// TQueryFnData>(options: QueryOptions<TQueryFnData, TData>)` infers `TData`
// only from `initialData?: TData | InitialDataFunction<TData>`, and the options
// object handed to it declares `initialData?: undefined | InitialDataFunction<
// T> | T`. `TData` came out as `T | undefined`, so every use of the awaited
// result was a spurious TS18048.

interface Link {
  readonly kind: "record";
}
type F<T> = () => T | undefined;

declare function opt<T>(o: { p?: T | (() => T | undefined) }): T;

declare const su: Link | undefined;
declare const sf: () => Link | undefined;
declare const sfl: (() => Link | undefined) | Link;
declare const sfu: (() => Link | undefined) | undefined;
declare const sflu: (() => Link | undefined) | Link | undefined;

export const a1: Link = opt({ p: su });
export const a2: Link = opt({ p: sf });
export const a3: Link = opt({ p: sfl });
export const a4: Link = opt({ p: sfu });
export const a5: Link = opt({ p: sflu });

// A REQUIRED target property has no implicit `| undefined`, so the source's
// undefined has nothing to pair with and must still reach `T`.
declare function req<T>(o: { p: T | (() => T | undefined) }): T;
export const b1: Link = req({ p: su }); // TS2322

// The same pairing through an INTERSECTION argument, where every constituent
// walks the same target property. Inferring `TD` from the ref by origin
// pairing first must not make the override object's re-inference look like a
// no-op — tsc counts a constituent as matched when an inference was MADE, not
// when the recorded answer changed.
interface QO<TQ = unknown, TD = TQ> {
  queryFn?: () => TQ;
  initialData?: TD | F<TD>;
}
declare function take<TQ, TD = TQ>(o: QO<TQ, TD>): TD;

declare const i1: QO<Link, Link> & { initialData?: undefined | F<Link> | Link };
declare const i2: { initialData?: undefined | F<Link> | Link } & QO<Link, Link>;
declare const i3: { initialData?: Link | F<Link> } & {
  initialData?: undefined | F<Link> | Link;
};
export const c1: Link = take(i1);
export const c2: Link = take(i2);
export const c3: Link = take(i3);
