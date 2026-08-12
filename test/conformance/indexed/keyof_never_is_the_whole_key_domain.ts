// The last line of tsc's `getIndexType` tests `any` and `never` TOGETHER:
//   type.flags & TypeFlags.Unknown ? neverType :
//   type.flags & (TypeFlags.Any | TypeFlags.Never) ? stringNumberSymbolType :
// so `keyof any` and `keyof never` are both `string | number | symbol`, and
// only `keyof unknown` is `never`.
//
// Read as `never`, a mapped type over `keyof never` has no members at all —
// and that is not a curiosity: `hoist-non-react-statics`' `NonReactStatics<S>`
// maps over `keyof S`, and styled-components hands it `never` for every
// non-component inner tag. Emptied, the member vanishes from the intersection
// `StyledComponent<C, …>` is, `typeof SomeStyled` stops satisfying
// `AnyStyledComponent`, and `styled(Component)` resolves to the wrong overload.

type KNever = keyof never;
declare const a: KNever;
const a1: number = a;

type KAny = keyof any;
declare const b: KAny;
const b1: number = b;

// `keyof unknown` is the empty key set, and stays that way.
type KUnknown = keyof unknown;
declare const c: KUnknown;
const c1: number = c;

// The domain is a union of the three primitive key types, so each is a member.
declare const d: KNever;
const d1: string | number | symbol = d;
const d2: string = d;
