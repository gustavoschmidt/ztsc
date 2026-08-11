// The two halves of the `any`-base rule (see 075) have DIFFERENT conditions.
//
// The `[x: string]: any` index signature applies whenever a base type is `any`.
// Relating as `any` is `getSingleBaseForNonAugmentingSubtype`, which needs the
// interface to have EXACTLY ONE base type and an empty member table -- and
// TypeScript's binder puts an interface's TYPE PARAMETERS in that same member
// table, so a generic interface is excluded however empty its body is.

type AnyAlias = any;
type Obj = { b: string };

// single `any` base, declares nothing: both halves apply
interface Pure extends AnyAlias {}
// ... and so does a chain of them (`getNormalizedType` loops)
interface Chained extends Pure {}
// own member: index only
interface WithMember extends AnyAlias {
  m: number;
}
// two bases: index only
interface TwoBases extends AnyAlias, Obj {}
// a second declaration contributes a member: index only
interface Merged extends AnyAlias {}
interface Merged {
  extra: number;
}
// generic: index only
interface Generic<X> extends AnyAlias {}
// a DECLARED index signature wins over the inherited `any` one
interface OwnIndex extends AnyAlias {
  [k: string]: number;
}

declare class Nominal {
  private secret: number;
  method(): void;
}

declare const pure: Pure;
declare const chained: Chained;
declare const withMember: WithMember;
declare const twoBases: TwoBases;
declare const merged: Merged;
declare const generic: Generic<number>;
declare const ownIndex: OwnIndex;

// the index signature reaches every one of them: an unknown name reads `any`
const i1: number = pure.zzz;
const i2: number = chained.zzz;
const i3: number = withMember.zzz;
const i4: number = twoBases.zzz;
const i5: number = merged.zzz;
const i6: number = generic.zzz;
// ... except where the interface declared its own index, which wins
const i7: number = ownIndex.zzz;
const i8: string = ownIndex.zzz;

// declared members still win over the index signature
const m1: number = withMember.m;
const m2: string = withMember.m;
const m3: number = merged.extra;
const m4: string = twoBases.b;

// relating as `any` reaches only the single-base, memberless, non-generic ones
const n1: Nominal = pure;
const n2: Nominal = chained;
const n3: Nominal = withMember;
const n4: Nominal = twoBases;
const n5: Nominal = merged;
const n6: Nominal = generic;
const n7: Nominal = ownIndex;

// `keyof` is `string | number` for all of them (a string index signature's keys
// subsume the declared names)
const k1: string | number = null as any as keyof Pure;
const k2: string | number = null as any as keyof WithMember;
const k3: string | number = null as any as keyof Generic<number>;
