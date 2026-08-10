// Every OBJECT/ARRAY LITERAL candidate for one type parameter collapses into a
// single union — tsc's `unionObjectAndArrayLiteralCandidates`, which filters
// the whole candidate list in one pass and replaces the literals with one
// `getUnionType(…, Subtype)`. It is not a pairwise fold, so a THIRD literal
// joins the same union instead of meeting the union-so-far on the
// common-supertype rule and being discarded. A pairwise fold also made the
// answer depend on the order the candidates arrived in, which is member order,
// which is atom order, which is file order.

type K = 'a' | 'b' | 'c' | 'd'

declare function sel<T>(spec: {[k in K]?: T}): T | undefined

// Three unrelated object literals: all three are in the inferred `T`.
const three = sel({a: {x: 1}, b: {y: 2}, c: {z: 3}})
const probeThree: null = three

// A fourth keeps joining — this is a set union, not a two-slot accumulator.
const four = sel({a: {x: 1}, b: {y: 2}, c: {z: 3}, d: {w: 4}})
const probeFour: null = four

// Array literals are literal candidates too, and collapse the same way.
declare function pick<T>(spec: {[k in K]?: T}): T | undefined
const arrays = pick({a: [1], b: ['s'], c: [true]})
const probeArrays: null = arrays

// A DECLARED (non-literal) candidate is not part of the literal union: it goes
// through the common-supertype rule as before, and a literal that it subsumes
// does not survive beside it.
interface Wide {
  x: number
}
declare const wide: Wide
const mixed = sel({a: wide, b: {x: 2}})
const probeMixed: null = mixed

export {probeThree, probeFour, probeArrays, probeMixed}
