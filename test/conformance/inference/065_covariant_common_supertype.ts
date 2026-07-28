// A type parameter's covariant inference candidates resolve to their common
// SUPERTYPE, not to their union (tsc's `getCovariantInference` ->
// `getCommonSupertype`): the candidates are folded left to right by
// `reduceLeft((s, t) => isTypeSubtypeOf(s, t) ? t : s)`, so two unrelated
// candidates keep the leftmost one and the call reports the argument that does
// not fit it. Unioning instead produced a type no argument had, which then
// silently satisfied checks that should have failed and failed checks that
// should have passed.
//
// A union survives in exactly two places: candidates that are literals over
// one base, and the object/array literal candidates (whose union is folded in
// last, so it never wins the leftmost slot). Nullable constituents are
// stripped from every candidate before the fold and added back after it.

declare function two<U>(a: U, b: U): U;
declare const s: string;
declare const n: number;

// Unrelated candidates: the leftmost wins and the other argument is rejected.
const leftS = two(s, n);
const leftSIsString: string = leftS;
const leftN = two(n, s);
const leftNIsNumber: number = leftN;

// A literal and its base: the base is the supertype either way round.
const withBase: string = two("a", s);
const withBaseFlipped: string = two(s, "a");

// Literals over ONE base still union.
const letters: "a" | "b" = two("a", "b");
const digits: 1 | 2 = two(1, 2);

// Object candidates: the one that is a supertype of the other wins, in either
// order. `wide` is not a subtype of `narrow` (it lacks `b`), so the fold keeps
// the leftmost when `wide` comes first and climbs to it when it comes second.
declare const wide: { a: number };
declare const narrow: { a: number; b: string };
const objA: { a: number } = two(wide, narrow);
const objB: { a: number } = two(narrow, wide);

// The subtype relation is stronger than assignability for an OPTIONAL target
// property: `{ a }` is assignable to `{ a; b? }` but is not a subtype of it,
// so the fold keeps `{ a }` in both orders.
declare const opt: { a: number; b?: string };
const optA: { a: number } = two(wide, opt);
const optB: { a: number } = two(opt, wide);

// Contravariant parameter positions make the WIDER-parameter function the
// subtype, so the narrower-parameter one is the common supertype either way.
declare const fNarrow: (x: number) => void;
declare const fWide: (x: number | string) => void;
const cbA: (x: number) => void = two(fNarrow, fWide);
const cbB: (x: number) => void = two(fWide, fNarrow);

// Nullable constituents are stripped before the fold and added back after it.
const nullable: "a" | null = two("a", null);
declare const maybe: string | null;
const nullableWide: string | null = two(maybe, "a");

// `unknown` is a supertype of everything; `any` beats the fold from either
// side (it is a subtype of nothing in the subtype relation).
declare const u: unknown;
const unk: unknown = two(u, n);
const unkFlipped: unknown = two(n, u);

// NEGATIVE: with the union gone, the argument that does not fit the inferred
// supertype is reported.
const rejected = two("a", 1);

// NEGATIVE: a fresh object literal never wins the leftmost slot — its union is
// folded in LAST — so the declared candidate is the answer even when the
// literal is written first, and the literal is then checked against it.
const litFirst: { a: number } = two({ a: "x" }, wide);

// NEGATIVE: the fold result really is the leftmost, not the union, so a value
// of the OTHER candidate's type no longer fits.
const notTheUnion: number = two(s, n);
