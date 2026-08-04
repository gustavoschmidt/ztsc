// A type parameter CONSTRAINED to an enum is assignable to that enum.
//
// The relation's arms are written on type KINDS, and the nominal enum arm
// came before the type-parameter arm. `<T extends E>` is a `.type_param`, so
// `enumAssignable` saw a non-enum source and rejected `T` against the very
// enum it is constrained to. The nominal question is about the CONSTRAINT,
// which is exactly what the type-parameter arm asks, so the enum arm now
// declines a generic source and lets it through.
//
// immich `src/utils/sync.ts:34`: `serialize<T extends keyof SyncItem>` passes
// `ackType ?? type` where a `SyncEntityType` is wanted.
enum SE {
  A = 'a',
  B = 'b',
}

enum NE {
  X,
  Y,
}

export const f1 = <T extends SE>(t: T): SE => t;
export const f2 = <T extends NE>(t: T): NE => t;
export const f3 = <T extends SE.A | SE.B>(t: T): SE => t;
export const f4 = <T extends SE.A>(t: T): SE => t;
export const f5 = <T extends SE>(t: T, fallback?: SE): SE => fallback ?? t;

// The nominal rule still holds in every direction it did before: a bare
// string is not an enum, a different enum is not this one, and an
// unconstrained parameter carries no enum evidence.
export const bad1 = <T extends string>(t: T): SE => t;
export const bad2 = <T extends NE>(t: T): SE => t;
export const bad3 = <T>(t: T): SE => t;
declare const plain: string;
export const bad4: SE = plain;
