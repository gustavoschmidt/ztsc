// A generic object alias declared in a LIBRARY (`.d.ts`) whose trailing param
// carries a *bare* default referencing an earlier own param (`B = A`) — the
// react-hook-form `UseFormReturn<TFieldValues, …, TTransformedValues =
// TFieldValues>` shape. The default param `B` is used in the body (here in a
// nested callback param and a property), so if it leaks as the free param
// symbol instead of the supplied argument the type comes out structurally
// different from the same alias instantiated through a function return.
//
// Two paths build `G<Payload>`:
//   - the annotation `const x: G<Payload>` → the alias-instantiation path
//     (`fixTypeArgs` fills the `B = A` default),
//   - `make<Payload>()` → the function-call path (`inferTypeArgs` fills the
//     default via `instantiate(def, resolved)`).
// The function-call path always substitutes the default to the concrete arg;
// the `.d.ts` alias path used to leave a *ground* default unsubstituted (a
// blanket guard meant only for deep-generic re-materialization), so `B` leaked
// as the bare param `A`. The two `G<Payload>` types then differed and the
// reflexive assignment `x = make<Payload>()` was wrongly rejected. The fix
// substitutes a *ground* referenced argument (a single symbol swap that cannot
// re-materialize deferred `.d.ts` machinery) on the alias path too, so both
// paths yield `G<Payload, Payload>` and the reflexive assignment holds.
export type G<A, B = A> = {
  submit: (cb: (data: B) => void) => void;
  latest: B;
  value: A;
};
// The factory writes BOTH args explicitly (`G<A, A>`, the react-hook-form
// `useForm<…>(): UseFormReturn<TF, TC, TT>` shape) so its return needs no
// default-fill — only the one-arg annotation `G<Payload>` fills the `B = A`
// default. The two must still agree.
export declare function make<A>(): G<A, A>;
