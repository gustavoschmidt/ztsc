// An indexed access whose INDEX is an enum member names the property that
// member's VALUE spells. A member table keys a computed enum key by the value,
// and so does a mapped type over an enum domain, so `T[E.A]` has to translate
// the member to its literal before looking anything up.
//
// It used to fall through to the string-like arm and index by `string`, which
// answers `any` for a table with no string index signature. immich's
// `Jobs = { [K in JobItem['name']]: (JobItem & { name: K })['data'] }` read
// through `JobOf<JobName.LibrarySyncFiles>` handed back `any`, and every
// callback under the job payload lost its parameter types (three TS7006 in
// `library.service.ts`).
enum E {
  A = 'av',
  B = 'bv',
}

type Rec<K extends string | number | symbol, V> = { [P in K]: V };

// …over a mapped type keyed by the enum
type M = { [K in E]: { tag: K; n: number } };
declare const m: M[E.A];
export const a1: E.A = m.tag;
export const a2: E.B = m.tag;

// …over an interface written with computed enum keys
interface I {
  [E.A]: { x: number };
  [E.B]: { y: string };
}
declare const i: I[E.A];
export const b1: number = i.x;
export const b2: number = i.y;

// …over a plain literal-keyed shape, since the atom is the value
type S = { av: number; bv: string };
declare const s: S[E.A];
export const c1: number = s;
export const c2: string = s;

// A union index still distributes.
declare const u: M[E.A | E.B];
export const d1: E.A | E.B = u.tag;

// A whole enum index reaches every member.
declare const w: Rec<E, number>[E];
export const e1: number = w;
export const e2: string = w;
