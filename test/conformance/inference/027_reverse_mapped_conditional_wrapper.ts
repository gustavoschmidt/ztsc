// Reverse-mapped inference through a CONDITIONAL wrapper, modeling redux's
// `ReducersMapObject<S> = keyof P extends keyof S ? { [K in keyof S]: … } : never`
// (the shape behind `configureStore({ reducer: { … } })`). Inference must see
// through the conditional to reach the mapped type, then reverse-infer `S` from
// the object literal. The reducer value is an intersection (`Reducer<S> & { … }`,
// like RTK's `ReducerWithInitialState`), so the element is inferred against the
// intersection's callable constituent. Before this the whole chain left `S` as
// `any`, so `store` typed as an opaque store and property access on the derived
// state false-positived.
type Reducer<S, P = S> = (state: S | P | undefined, action: { type: string }) => S;
type SliceReducer<S> = Reducer<S> & { getInitialState: () => S };
type ReducersMapObject<S, P = S> = keyof P extends keyof S
  ? { [K in keyof S]: Reducer<S[K], K extends keyof P ? P[K] : never> }
  : never;
declare function make<S, P = S>(m: Reducer<S, P> | ReducersMapObject<S, P>): S;

declare const auth: SliceReducer<{ token: string }>;
declare const user: SliceReducer<{ name: string }>;

const state = make({ auth, user });
const ok: { auth: { token: string }; user: { name: string } } = state;
export {};
