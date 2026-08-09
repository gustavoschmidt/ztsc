interface Post {
  uri: string
}
declare function use(p: Post): void

// tsc's `getESSymbolLikeTypeForNode`: a `Symbol()` / `Symbol.for()` call in a
// CONST variable declaration with an identifier name is a fresh
// `unique symbol`, not the lib's plain `symbol`...
const TOMB = Symbol('tomb')
declare function get(): Post | typeof TOMB

// ...so `typeof TOMB` is a UNIT type and equality narrowing removes it.
const a = get()
if (a !== TOMB) use(a)

const b = get()
if (b === TOMB) {
  use(b) // still the symbol here
} else {
  use(b)
}

// `Symbol.for` is the same rule.
const KEY = Symbol.for('key')
declare function get2(): Post | typeof KEY
const cc = get2()
if (cc !== KEY) use(cc)

// A `let` is not a valid ES symbol declaration: plain `symbol`, no narrowing.
let loose = Symbol('loose')
declare function get3(): Post | symbol
const d = get3()
if (d !== loose) use(d)

// Two distinct unique symbols do not narrow each other away.
const OTHER = Symbol('other')
const e = get()
if (e !== OTHER) use(e)
