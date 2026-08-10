// tsc's `instantiateContextualType`: an argument's contextual type is its
// parameter instantiated with `context.returnMapper` — the
// `InferencePriority.ReturnType` inferences made from the call's contextual
// return type, before any argument is looked at. The test is simply whether
// that mapper RESOLVES anything in the parameter; nothing about the shape of
// what it resolves to enters it.
//
// So an object-literal argument passed to a type parameter that the
// contextual return type already pins is checked AGAINST that type, and a
// property whose contextual type names a literal domain keeps its literal.

type Pct = number | 'auto' | `${number}%` | null

interface Style {
  minHeight?: Pct
  height?: Pct
  direction?: 'row' | 'column'
}

declare function id<T>(v: T): T

// The parameter IS the type parameter: the contextual return pins it, so the
// object literal is checked against `Style` and `'100%'` matches the
// template-literal member of `Pct` instead of widening to `string`.
const a1: Style = id({minHeight: '100%'})
const a2: Style = id({direction: 'row'})

// The type parameter sits under a property of the parameter — react-native's
// `Platform.select` shape. Both branches are contextually typed by `Style`,
// and the two object-literal candidates union into a normalized pair that is
// assignable to it.
declare function select<T>(spec: {web?: T; default: T}): T
const a3: Style = select({web: {minHeight: '100%'}, default: {height: '100%'}})

// With NO contextual return there is no mapper, the properties widen, and the
// widened `string` no longer fits `Pct`.
const bare = select({web: {minHeight: '100%'}, default: {height: '100%'}})
const bareBack: Style = bare

// A contextual return that resolves nothing in the parameter leaves the
// argument checked context-free, exactly as before.
declare function unrelated<T>(v: {k: string}): T
const a4: Style = unrelated({k: 'x'})
