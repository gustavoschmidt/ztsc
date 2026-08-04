// The companion to 085: the overload SET is on the TARGET side.
//
// tsc's `signaturesRelatedTo` decides the erasure from the SHAPE OF THE PAIR,
// not from one side of it. One signature against one signature is arm 2 and is
// compared with the type parameters standing; an overload SET on EITHER side is
// arm 3 and cross-matches with both sides erased to `any` (`getErasedSignature`).
//
// Relating a property whose target type is an overload set one target signature
// at a time makes every pair LOOK like arm 2, so the source's own type parameter
// is erased to its CONSTRAINT — and a target overload the source covers only
// through `any` is then rejected, taking the whole object relation with it.
//
// kysely's `AliasableExpression.as` is exactly this shape (two overloads, the
// second taking an `Expression<any>`) against `SelectQueryBuilder.as<A extends
// string>(alias: A)`, which overrides it with a single signature: a builder
// stopped being an `AliasableExpression` at all, which is what turned every
// immich `.where(ref, 'in', (eb) => …)` into TS2769 plus an implicit-`any`
// callback parameter.

interface Aliasable<T> {
  as<A extends string>(alias: A): T;
  as(alias: number): T;
}

interface Builder<O> extends Aliasable<O> {
  as<A extends string>(alias: A): O;
}

declare const b: Builder<{ id: 'x' }>;
export const ok: Aliasable<{ id: string }> = b;

// Negative control: erasing to `any` is not "anything relates". The source
// signature still has to hold once erased, and a wrong return type is caught.
interface Plain {
  as<A extends string>(alias: A): number;
}

declare const bad: Plain;
export const notOk: Aliasable<{ id: string }> = bad;
