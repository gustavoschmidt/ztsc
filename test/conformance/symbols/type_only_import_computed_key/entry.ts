// A TYPE-ONLY import of a const has no value meaning, but tsc's late-binding
// still resolves the computed key through the alias and reads the target's
// literal type — so `[K]` names the enum member, not a synthetic placeholder.
import {type ID as KeyAlias} from './config'
import {ID, Nux} from './config'

export type Device = {
  fontScale?: string
  [KeyAlias]?: boolean
}

declare function get<K extends keyof Device>(k: K): Device[K]

const viaEnum: boolean | undefined = get(ID)
const viaMember: boolean | undefined = get(Nux.PolicyUpdate)

// The key is the ENUM MEMBER type, so a bare string literal is not a `keyof`.
const raw: keyof Device = 'PolicyUpdate'
// ...and an unrelated member does not name a key either.
const wrong: boolean | undefined = get(Nux.Other)
