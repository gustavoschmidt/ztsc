// tsc's `extractIrreducible`, which `getIntersectionType` runs BEFORE the
// cross-product distribution: when EVERY member of an intersection is a union
// that contains `undefined` (then, separately, `null`), the nullish half is
// irreducible — no product with any other member survives it — so the whole
// nullish constituent is FACTORED OUT instead of multiplied through:
//
//     (A | null) & (B | null)   is   (A & B) | null
//
// and not the four-way product `A & B | A & null | null & B | null`.
//
// It is not merely a spelling. The `null & <member>` products the distribution
// would leave standing are only killed by the syntactic nullish-emptiness rule
// (`null & { a: 1 }` is `never`), and that rule cannot see through a REFERENCE
// — an interface name could in principle be an alias for a primitive, so the
// store leaves it alone. So `null & SomeInterface` survives as a live
// constituent, and every consumer downstream sees it: a distributive
// conditional then MATCHES it (an intersection is related to a target when one
// member is) while inferring nothing from it, and `infer S` falls back to
// `unknown` — which poisons the union with `unknown` and erases the answer.
//
// Found on kysely: a common table expression that SHADOWS the table it selects
// from intersects the physical column type with the CTE's row type, so
// `deletedAt` — the one nullable `ColumnType` column — became
// `(ColumnType<Date, …> | null) & (Date | null)`, and `SelectType<T> = T
// extends ColumnType<infer S, any, any> ? S : T` over the surviving
// `null & Date` product answered `unknown` for the whole column.

interface Ref {
  readonly sel: Date;
}
declare const R: Ref;

// The shape verbatim: two unions with a common `null`, intersected, then read
// through a distributive conditional with an `infer`.
type Pick_<T> = T extends Ref ? T['sel'] : T;
type Both = (Ref | null) & (Date | null);

declare const both: Both;
// `(Ref & Date) | null`: `null` survives once, and nothing else is nullish.
export const g1: Ref | null = both;
export const g2: Date | null = both;
export const b1: Ref = both;

declare const picked: Pick_<Both>;
export const g3: Date | null = picked;
export const b2: Date = picked;

// `undefined` is extracted the same way, and it is tried FIRST.
type BothU = (Ref | undefined) & (Date | undefined);
declare const bothU: BothU;
export const g4: Ref | undefined = bothU;
export const b3: Ref = bothU;

// Negative control (a): the rule needs EVERY member to be a union carrying the
// nullish type. With one member that is not, the ordinary cross product runs
// and the nullish products reduce by the emptiness rule instead.
type OneSided = (Ref | null) & Date;
declare const one: OneSided;
export const g5: Date = one;
export const g6: Ref = one;

// Negative control (b): a nullish that is present on only ONE side is not
// irreducible and must not be factored out — `(Ref | null) & (Date |
// undefined)` has no inhabitant that is `null`.
type Mixed = (Ref | null) & (Date | undefined);
declare const mixed: Mixed;
export const g7: Ref & Date = mixed;
export const b4: null = mixed;

// Negative control (c): the non-nullish half really is intersected, not
// dropped — a member only one side has is still required.
type Left = { a: 1 };
type Right = { b: 2 };
declare const lr: (Left | null) & (Right | null);
export const g8: { a: 1; b: 2 } | null = lr;
export const b5: { a: 1; b: 2; c: 3 } | null = lr;

// Negative control (d): unions with NO nullish member distribute as before.
type Prod = ('a' | 'b') & ('a' | 'c');
declare const prod: Prod;
export const g9: 'a' = prod;
