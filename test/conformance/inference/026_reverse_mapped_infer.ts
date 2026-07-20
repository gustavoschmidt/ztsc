// Reverse-mapped-type inference (tsc's `inferReverseMappedType`): infer the
// source `S` of a HOMOMORPHIC mapped target `{ [K in keyof S]: F<S[K]> }` from
// an object-literal argument. Each source property `k` contributes `S[k]` by
// inferring from the argument property's type into the value template. Before
// this, `S` collapsed to `{}` and the literal was rejected (TS2353 on the
// unknown key, TS2322 on the result). Also exercises the union-subtraction that
// keeps a contravariant `T | undefined` parameter from polluting the element
// with a spurious `| undefined`.
type Box<T> = (v: T | undefined) => T;
type BoxMap<S> = { [K in keyof S]: Box<S[K]> };
declare function make<S>(m: BoxMap<S>): S;

const r = make({
  a: (v: { x: number } | undefined) => ({ x: 1 }),
  b: (v: string | undefined) => "",
});
const ok: { a: { x: number }; b: string } = r;
export {};
