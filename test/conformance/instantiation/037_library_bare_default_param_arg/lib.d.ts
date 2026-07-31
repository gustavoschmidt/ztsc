// A generic alias declared in a LIBRARY (`.d.ts`) whose trailing param carries
// a *bare* default referencing an earlier own param (`P = S`) — the redux
// `Reducer<S, A, PreloadedState = S>` shape — referenced from another library
// generic with that generic's own *type parameter* as the argument
// (`interface Slice<State> { reducer: Red<State> }`, RTK's shape).
//
// The `.d.ts` alias path only substituted a *ground* referenced argument, so an
// abstract one left the default bound to the bare param symbol: `Red<State>`
// materialized as `(state: State | S | undefined, …) => State`, keeping a FREE
// occurrence of `Red`'s own `S` that the caller's later `Slice<Concrete>`
// instantiation can never close. Substituting a naked type parameter is the
// same single symbol swap as a ground argument — it renames one bound name to
// another and expands nothing — so it cannot re-materialize the deferred
// `.d.ts` machinery the ground carve-out guards against.
//
// The leak is not merely cosmetic: a type that still mentions a type parameter
// is *generic*, so every conditional that tests it stays undecided. `combine`'s
// `M[keyof M] extends Red<…> | undefined ? … : never` therefore never reduced,
// its result stayed an unreduced conditional, and passing it where a `Red` or a
// map-of-`Red` is expected was rejected — redux `combineReducers` feeding RTK
// `configureStore({ reducer: rootReducer })`.
type Act = { type: string };
type Red<S = any, A extends Act = Act, P = S> = (state: S | P | undefined, action: A) => S;

interface Slice<State = any, Name extends string = string> {
  reducer: Red<State>;
  name: Name;
}

type StateFrom<M> = M[keyof M] extends Red<any, any, any> | undefined
  ? { [K in keyof M]: M[K] extends Red<infer S, any, any> ? S : never }
  : never;

declare function combine<M>(
  map: M
): M[keyof M] extends Red<any, any, any> | undefined ? Red<StateFrom<M>> : never;

declare function configure<S>(options: {
  reducer: Red<S> | { [K in keyof S]: Red<S[K]> };
}): S;

export { Act, Red, Slice, StateFrom, combine, configure };
