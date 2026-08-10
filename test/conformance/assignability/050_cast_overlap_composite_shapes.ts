// TS2352 comparable relation, continued: the overlap walk must have an arm for
// EVERY composite shape it can be re-entered with, not only the ones that carry
// optionality. A shape with no arm answers "no overlap" and fails the whole
// cast — a false positive. Each positive below is one such shape reached
// through an object member or an intersection constituent; the negatives are
// the same shapes where the overlap genuinely does not exist.

interface Ctor<P> {
  new (props: P): {props: P}
}
interface Fn<P> {
  (props: P): null
}
type Comp<P> = Ctor<P> | Fn<P>

type Small = {a: string}
type Big = {a: string; b: string}

// POSITIVE: a union under a FUNCTION RETURN. Neither `Comp<Small>` nor
// `Comp<Big>` is assignable to the other (the class arm fails one way, the
// function arm the other), but the comparable relation only needs SOME
// constituent to relate — and `Fn` is contravariant in its props, so
// `Fn<Small>` relates to `Fn<Big>`. The walk has to reach the return type to
// see it.
declare const r1: {g: () => Comp<Small>}
const c1 = r1 as {g: () => Comp<Big>}

// POSITIVE: the same union under a bare function type, no wrapper object.
declare const r2: () => Comp<Small>
const c2 = r2 as () => Comp<Big>

// POSITIVE: tuple against tuple, element by element. This is
// react-navigation's `PrivateValueStore<[ParamList, NavigationList, unknown]>`
// variance brand, whose whole content is one tuple-typed property.
declare const r3: {'': [Small, string]}
const c3 = r3 as {'': [Big, string]}

// POSITIVE: a tuple whose first element is widened, cast to a tuple of
// literals — `router.matchPath(href) as [keyof ParamList, Params?]`.
declare const r4: [string, {[k: string]: string}]
const c4 = r4 as ['home' | 'profile', {[k: string]: string}?]

// POSITIVE: an intersection whose constituent is a UNION.
type Split = {x: Small; y?: number} | {x?: Small; y: number}
type SplitBig = {x: Big; y?: number} | {x?: Big; y: number}
declare const r5: {g: () => Comp<Small>} & Split
const c5 = r5 as {g: () => Comp<Big>} & SplitBig

// (A deferred CONDITIONAL as an intersection constituent is the fourth shape
// the walk needs an arm for — react-navigation's `TypedNavigator` is
// `(undefined extends Config ? A : B) & PrivateValueStore<…>` — but it has no
// conformance case here: ztsc's treatment of a conditional TARGET is already
// laxer than tsc's (it tries both branches where tsc relates only through the
// default constraint), so every synthetic form of it is an accepted
// under-report on both sides of the arm rather than a differential.)

// POSITIVE: an intersection whose constituent is a still-generic MAPPED type.
type Renamed<T> = {[K in keyof T]: T[K]}
function mappedConstituent<T>(v: Renamed<T> & {g: () => Comp<Small>}): Renamed<T> & {
  g: () => Comp<Big>
} {
  return v as Renamed<T> & {g: () => Comp<Big>}
}

// POSITIVE: a CALLABLE OBJECT against a bare function target, reached through
// its call signature — `memo(forwardRef(f)) as <T>(props: …) => ReactElement`
// casts a `NamedExoticComponent` (a call signature plus `$$typeof`) to a
// function type. Only this direction can succeed: the reverse fails on the
// `$$typeof` a function does not have.
interface Exotic<P, R> {
  (props: P): R
  readonly $$typeof: string
}
declare const ex: Exotic<{a: string}, Comp<Small>>
const c7 = ex as (props: {a: string}) => Comp<Big>

// NEGATIVE: the same callable object whose call signature does not overlap
// the function target at all. tsc: TS2352.
declare const ex2: Exotic<{a: string}, {a: string}>
const b0 = ex2 as (props: {a: string}) => number

// NEGATIVE: a function return that genuinely does not overlap. tsc: TS2352.
declare const n1: {g: () => {a: string}}
const b1 = n1 as {g: () => number}

// NEGATIVE: tuples of incompatible arity. tsc: TS2352.
declare const n2: [string, string]
const b2 = n2 as [string]

// NEGATIVE: tuple elements that do not overlap. tsc: TS2352.
declare const n3: [{a: string}]
const b3 = n3 as [number]

// NEGATIVE: the target demands a construct signature the source cannot
// supply. tsc: TS2352.
declare const n4: {a: string}
const b4 = n4 as {new (): {a: string}}
