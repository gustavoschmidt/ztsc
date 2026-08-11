// `interface X extends Alias {}` where `Alias` is `any`. tsc special-cases an
// `any` base type in TWO places and both are observable:
//
//  1. `resolveObjectTypeMembers` substitutes `[x: string]: any` for an `any`
//     base's index infos (its `anyBaseTypeIndexInfo`), so every property read
//     on the interface succeeds with `any` and `keyof` is `string | number`.
//  2. `getNormalizedType` -> `getSingleBaseForNonAugmentingSubtype` swaps the
//     whole reference for its single base before the relation runs, so the
//     interface RELATES as `any`: it satisfies an arbitrary required property
//     list, including a nominal class's `private` member, which a plain
//     `{ [k: string]: any }` never does.
//
// `@types/koa` declares its user-augmentable request state exactly this way
// (`type DefaultStateExtends = any; interface DefaultState extends
// DefaultStateExtends {}`), so `ctx.state.anything` is legal Koa.

type AnyAlias = any;
interface State extends AnyAlias {}
interface Empty {}
interface StringIndex {
  [k: string]: any;
}

declare const st: State;
declare const em: Empty;
declare const si: StringIndex;

// (1) every property read succeeds, with type `any`
const r1: number = st.cspNonce;
const r2: string = st.cspNonce;
const r3: number = st["oauthState"];
// `keyof State` is `string | number` -- the string index signature's keys
const k1: string | number = null as any as keyof State;

// the empty-interface control: no index signature, so the read is TS2339
const c1 = em.cspNonce;

// (2) relates as `any`: an arbitrary required property list is satisfied
declare class Nominal {
  private secret: number;
  method(): void;
}
const a1: Nominal = st;
const a2: { auth: string; nested: { deep: number } } = st;
const a3: {} = st;

// the string-index control: a DECLARED `[k: string]: any` does NOT satisfy a
// required named property (TS2741) and is not a `Nominal`
const c2: Nominal = si;
const c3: { auth: string } = si;

// ... but the interface is NOT `any`: a primitive target still rejects it,
// because tsc answers the object->primitive pair from the un-normalized source
const c4: string = st;
const c5: number = st;

// as a TARGET it absorbs any object, index signature and all -- no
// excess-property check against a `[x: string]: any` index
const t1: State = { auth: "tok", extra: 1 };
const t2: State = si;
