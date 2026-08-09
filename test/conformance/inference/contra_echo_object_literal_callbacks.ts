declare function work(name: string): {prev: number} | undefined

// An object-literal argument whose callback properties are context sensitive
// is re-checked with the type parameters provisionally fixed. A callback
// PARAMETER position that mentions the type variable then hands that
// substitution straight back as a contravariant candidate — which must not
// outrank the covariant candidate the other callback's RETURN really carries.
// (react-query's `useMutation({ onMutate, onError })`: `onMutate` returns
// `Ctx | undefined`, `onError`'s `ctx: TContext | undefined` echoes it back
// minus the `undefined`.)
interface Opts<T> {
  onMutate?: (v: string) => Promise<T> | T
  onError?: (ctx: T | undefined) => void
}
declare function useMutation<T = unknown>(o: Opts<T>): T

const ctx = useMutation({
  onMutate: v => work(v),
  onError: ctx2 => {},
})
const keepsUndefined: {prev: number} | undefined = ctx
// ...and the inference really does carry the `undefined` (this must fail).
const notNarrowed: {prev: number} = ctx

// An ANNOTATED callback parameter is real contravariant evidence and still
// clamps the inference.
interface Opts2<T> {
  produce?: (v: string) => T
  consume?: (x: T) => void
}
declare function run<T = unknown>(o: Opts2<T>): T
const narrowed = run({
  produce: v => ({a: 1, b: 2}),
  consume: (x: {a: number}) => {},
})
const onlyA: {a: number} = narrowed
const notBoth: {a: number; b: number} = narrowed
