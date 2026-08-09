// `${E}` interpolates an enum as the union of its constant VALUES: tsc gives
// a member type both StringLiteral and EnumLiteral flags, and a whole enum IS
// the union of its members, so the template distributes over them.
enum Lang {
  en = 'en',
  en_GB = 'en-GB',
  pt = 'pt',
}

type S = `${Lang}`
declare const v: S
const widened: 'en' | 'en-GB' | 'pt' = v
const ok: S = 'en-GB'
const bad: S = 'nope'

declare const raw: string
switch (raw as `${Lang}`) {
  case 'en-GB':
    break
  case 'pt':
    break
  case 'nope':
    break
}

// A single MEMBER interpolates as its own value.
type One = `${Lang.en_GB}`
const one: One = 'en-GB'
const notOne: One = 'en'

// Numeric enums interpolate their numeric values.
enum N {
  A = 1,
  B = 2,
}
const n1: `${N}` = '1'
const n2: `${N}` = '3'

// Enums compose with surrounding text and other holes.
type Prefixed = `lang-${Lang}`
const p1: Prefixed = 'lang-pt'
const p2: Prefixed = 'lang-xx'
