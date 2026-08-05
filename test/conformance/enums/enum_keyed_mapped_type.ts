// A mapped type over an ENUM key domain (`{ [P in E]: V }`, i.e. `Record<E,
// V>`) has one NAMED property per member — keyed by the member's constant
// value, which is the atom every computed enum key `[E.A]` resolves to — and
// `keyof` of it is the enum's member union.
//
// It used to materialize a single index signature instead (`string` for a
// string enum, `number` for a numeric one), on the reasoning that a computed
// enum key was keyed by a text-derived placeholder. It is not, and the index
// signature cost `keyof` the enum: for `interface M extends Record<E, …>`,
// `keyof M` came back `string | number`, so a `<T extends keyof M>` parameter
// no longer satisfied `T extends E` — immich `user.repository.ts`'s
// `upsertMetadata<T extends keyof UserMetadata>`, whose `key` was rejected by
// every kysely column typed by that enum.
enum E {
  A = 'AV',
  B = 'BV',
}

type Rec<K extends string | number | symbol, V> = { [P in K]: V };

type R = Rec<E, { n: number }>;

// `keyof` reports the MEMBERS, so a parameter constrained to it carries the
// enum.
declare const k: keyof R;
export const k1: E = k;
export const k2: E.A | E.B = k;
export const g = <T extends keyof R>(t: T): E => t;

// The properties are named by the members' VALUES, so a literal written with
// computed enum keys matches and a plain-string literal does too.
export const r1: R = { [E.A]: { n: 1 }, [E.B]: { n: 2 } };
export const r2: R = { AV: { n: 1 }, BV: { n: 2 } };

// …and a missing member is a missing property, which the index signature used
// to swallow.
export const r3: R = { [E.A]: { n: 1 } };

// Reading through a member key still gives the value type.
declare const r: R;
export const n1: number = r[E.A].n;

// An interface that inherits the enum domain keeps it in `keyof`.
interface M extends Rec<E, { n: number }> {}
declare const mk: keyof M;
export const mk1: E = mk;

// A numeric enum names its properties by the numeric values.
enum N {
  X,
  Y,
}
export const nr: Rec<N, string> = { 0: 'x', 1: 'y' };
export const nbad: Rec<N, string> = { 0: 'x' };

// An enum with a COMPUTED member has no key atom for it, so the domain stays
// an index signature rather than silently dropping keys.
declare const opaque: number;
enum C {
  P = 1,
  Q = opaque,
}
export const cr: Rec<C, string> = { 1: 'p' };
