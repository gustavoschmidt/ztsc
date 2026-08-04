// A string enum is NOMINAL: a plain string literal is not assignable into it,
// and it is not assignable to a plain literal. The `as` assertion is still
// legal in most of those pairs, because tsc compares the target against the
// WIDENED source and widening turns a string literal into `string` — which
// every string enum is assignable to. immich casts semver's
// `ReleaseType | null` (a union of plain string literals) to its own
// `enum ReleaseType` that way.

enum E {
  Major = 'major',
  Minor = 'minor',
}
enum N {
  A = 1,
  B = 2,
}

declare const s: string;
declare const lit: 'nope';
declare const member: 'major';
declare const nullable: 'major' | 'minor' | 'release' | null;
declare const e: E;
declare const em: E.Major;
declare const n: N;
declare const num: number;

// Into a string enum: the widened source is `string`, so anything string-like
// goes, whatever the literal says.
const a1 = s as E;
const a2 = lit as E;
const a3 = member as E;
const a4 = lit as E.Major;
const a5 = s as E.Major;
const a6 = nullable as E;

// Out of a string enum.
const b1 = e as string;
const b2 = e as 'major'; // a member value
const b3 = e as 'nope'; // TS2352 — no member has that value
const b4 = em as 'major';
const b5 = em as 'minor'; // a single member widens to itself

// Numeric enums keep the ordinary numeric comparability.
const c1 = num as N;
const c2 = 1 as N;
const c3 = n as number;
const c4 = n as 5; // TS2352

// Crossing enum families is still a mistake.
const d1 = e as N; // TS2352
const d2 = n as E; // TS2352

export { a1, a2, a3, a4, a5, a6, b1, b2, b3, b4, b5, c1, c2, c3, c4, d1, d2 };
