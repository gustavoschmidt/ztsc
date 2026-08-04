// An ENUM MEMBER is a literal for `isLiteralOfContextualType`'s purposes.
// tsc carries both flags on one type (`EnumLiteral | StringLiteral`), so every
// arm of that predicate that asks "is the candidate a string literal" answers
// yes for `E.A`, and the enum type itself is a UNION of its members, so a
// contextual type of `E` recurses into `E.A` and admits it.
//
// ztsc models an enum member as its own kind, so both halves had to be spelled
// out. Without them an object-literal property whose contextual type is a
// type parameter constrained by the enum — or by a `keyof` that resolves to
// string literals — widened `E.A` to the whole enum `E`, and the type
// parameter was inferred as `E` instead of `E.A`. Everything downstream that
// indexes by the inferred key then saw every member at once: immich's
// `send({ type: SyncEntityType.UserDeleteV1, data })` typed `data`'s target as
// `Impossible<Exclude<keyof D, keyof SyncItem[E]>>`, i.e. `{ userId: never }`.

enum E {
  A = 'AV1',
  B = 'BV1',
}

type Item = {
  [E.A]: { x: string };
  [E.B]: { y: number };
};

// (1) contextual type is the type parameter, constrained by the whole enum
declare const byEnum: <T extends E>(o: { type: T }) => T;
const r1 = byEnum({ type: E.A });
const k1: E.A = r1;

// (2) constrained by `keyof` of an object whose keys are enum members
declare const byKeyof: <T extends keyof Item>(o: { type: T }) => T;
const r2 = byKeyof({ type: E.A });
const k2: E.A = r2;

// (3) the shape that motivated this: a second parameter keyed off the first
type Impossible<K extends keyof any> = { [P in K]: never };
type Exact<T, U extends T = T> = U & Impossible<Exclude<keyof U, keyof T>>;
declare const send: <T extends keyof Item, D extends Item[T]>(o: { type: T; data: Exact<Item[T], D> }) => T;
declare const data: { x: string };
const r3 = send({ type: E.A, data });
const k3: E.A = r3;

// (4) a bare enum-member argument still infers the member (unchanged)
declare const bare: <T extends E>(t: T) => T;
const r4 = bare(E.A);
const k4: E.A = r4;

// (5) with NO contextual type an object literal still WIDENS the member —
// that is the rule this change must not break.
const wide = { type: E.A };
const k5: { type: E } = wide;
const k5b: { type: E.A } = wide;

export { k1, k2, k3, k4, k5, k5b };
