// A member declared with a computed ENUM-MEMBER key is NAMED by that enum
// member, not by the string its value happens to be.
//
// A member table keys by atom, and an enum member's atom is its VALUE, so
// `keyof M` read back `'AV1' | 'BV1' | 'CV1'` and the enum's identity was
// gone: `T extends keyof M` no longer satisfied `T extends E`, and printing
// `keyof M` named strings tsc never shows. tsc keeps the enum literal as
// `symbol.links.nameType`; ztsc keeps it in `Checker.key_name_types`, a side
// table recorded against the interned object so the member layout is
// untouched.
//
// immich `src/utils/sync.ts:34` — `SyncItem` is keyed by `SyncEntityType` and
// `serialize<T extends keyof SyncItem>` passes `ackType ?? type` where a
// `SyncEntityType` is wanted.
enum E {
  A = 'AV1',
  B = 'BV1',
  C = 'CV1',
}

type M = {
  [E.A]: { a: number };
  [E.B]: { b: number };
  [E.C]: { c: number };
};

// `keyof M` IS the enum's member union.
declare const k: keyof M;
export const k1: E = k;
export const k2: E.A | E.B | E.C = k;

// …so a parameter constrained to it carries the enum.
export const g = <T extends keyof M>(t: T): E => t;
export const serialize = <T extends keyof M>(type: T, ackType?: E): E => ackType ?? type;

// Indexed access still reads through the value the key spells.
declare const md: M[E.A];
export const mdA: number = md.a;
export const pick = <T extends keyof M>(type: T, data: M[T]) => ({ type, data });

// A mapped type over the key set keeps the enum-named keys.
type Wrapped = { [K in keyof M]: [K, M[K]] };
declare const w: Wrapped;
export const wA: [E.A, { a: number }] = w[E.A];

// A plain string key is NOT the enum member, in either direction.
type S = { AV1: { a: number } };
declare const sk: keyof S;
export const bad1: E = sk;
export const bad2: 'AV1' = k;
