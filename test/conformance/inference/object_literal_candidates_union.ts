// tsc's `unionObjectAndArrayLiteralCandidates`: every candidate inferred for
// one type parameter that was WRITTEN as an object literal is replaced by
// their union, and only the remaining candidates go through the
// `getCommonSupertype` fold. The test is `ObjectFlags.ObjectLiteral` — the
// literal's ORIGIN — not `ObjectFlags.FreshLiteral`, which is already gone by
// the time a literal written as the property of another literal is inferred
// from.
//
// `getCovariantInference` then ends with `getWidenedType`, whose widening
// context gives each object-literal constituent its siblings' missing property
// names as `name?: undefined`. That is what makes the union usable.

declare function two<T>(a: T, b: T): T

// Two candidates from two ARGUMENTS: union, normalized against each other.
const args = two({a: 1}, {b: 2})
const argsA: number | undefined = args.a
const argsB: number | undefined = args.b

// Two candidates from two PROPERTIES of ONE argument — the same rule. The
// literals have lost their freshness by now; their origin is what matters.
declare function spec<T>(s: {x: T; y: T}): T
const props = spec({x: {a: 1}, y: {b: 2}})
const propsA: number | undefined = props.a
const propsB: number | undefined = props.b

// …and nested one level deeper, on both sides.
declare function nested<T>(a: {v: T}, b: {v: T}): T
const deep = nested({v: {a: 1}}, {v: {b: 2}})
const deepA: number | undefined = deep.a
const deepB: number | undefined = deep.b

// An optional target property infers just the same.
declare function opt<T>(s: {x?: T; y: T}): T
const optional = opt({x: {a: 1}, y: {b: 2}})
const optionalA: number | undefined = optional.a

// The origin is dropped the moment the literal is WIDENED into a mutable
// location (`getWidenedTypeOfObjectLiteral` builds a type carrying neither
// flag), so a variable holding it is no longer a sibling to normalize
// against: `held` keeps exactly its own properties.
declare const cond: boolean
const held = {a: 1}
const mixedUnion = cond ? held : {b: 2}
const mixedB = mixedUnion.b

// A DECLARED union is never normalized either.
declare const union: {file: string} | {errorMessage: number}
const notNormalized = union.file
