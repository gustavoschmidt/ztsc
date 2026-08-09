// tsc's `instantiateContextualType` runs the ReturnType-priority inferences
// (`context.returnMapper`) into a parameter's type before the argument is
// checked, so a property whose parameter type is a still-free type variable
// gets the CONTEXTUAL RETURN as its literal context and its fresh literal
// survives (`isLiteralOfContextualType`).
declare function select<T>(spec: {web?: T; native?: T}): T

// With a contextual return the literals are kept: T = "small" | "tiny".
const ctx: 'large' | 'small' | 'tiny' | undefined = select({
  web: 'tiny',
  native: 'small',
})

declare function take(v: 'large' | 'small' | 'tiny' | undefined): void
take(select({web: 'tiny', native: 'small'}))

// A contextual return that names NO literal domain is not a literal context,
// so the properties widen exactly as they do context-free.
declare function takeStr(v: string): void
takeStr(select({web: 'tiny', native: 'small'}))

// With no contextual return at all the properties widen to `string` — the
// inferred T is `string`, and it does not fit the literal union.
const bare = select({web: 'tiny', native: 'small'})
const widened: 'small' | 'tiny' = bare

// A mapped-type parameter and a `T | undefined` return behave the same way.
type OS = 'ios' | 'android' | 'native' | 'web'
declare function pick<T>(spec: {[p in OS]?: T}): T | undefined
const mapped: 'large' | 'small' | 'tiny' | undefined = pick({
  web: 'tiny',
  native: 'small',
})
