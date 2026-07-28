// Subtype reduction — the union reduction `||`, `??` and `?:` apply to their
// result (tsc's `getUnionType(…, UnionReduction.Subtype)`) — treats a FRESH
// object literal asymmetrically, because tsc reduces with
// `strictSubtypeRelation` and that relation excess-checks a fresh source:
//
//   * a fresh literal never ABSORBS a sibling, so a union whose fallback was
//     written at the site keeps every member;
//   * a fresh literal IS absorbed by a sibling it fits without excess
//     properties, so a fallback that is a plain subtype still disappears.
//
// Two declared types reduce as before, in `?:` as well as in `||`.

declare const cond: boolean;
declare const s: string;
declare const n: number;

declare const ab: { a: string; b: number };
declare const a_: { a: string };
declare const aopt: { a: string; b?: number };

// 1. Fresh fallback does not absorb: the sibling's `b` survives.
const r1 = cond ? ab : { a: s };
export const p1: number = r1.b; // TS2339 — `b` is missing on the literal arm

// 2. Fresh fallback with an excess property is not absorbed either.
const r2 = cond ? a_ : { a: s, b: n };
export const p2: number = r2.b; // TS2339 — `b` is missing on the declared arm

// 3. A fresh fallback that fits without excess IS absorbed, so the sibling's
//    optional property is reachable through the result.
const r3 = cond ? aopt : { a: s };
export const p3: number | undefined = r3.b;

// 4. Same absorption through `||`.
declare const f4: (() => { a: string; b?: number }) | undefined;
const r4 = f4?.() || { a: s };
export const p4: number | undefined = r4.b;

// 5. Two declared types still reduce: the narrower one wins.
const r5 = cond ? a_ : ab;
export const p5: number = r5.b; // TS2339 — reduced to `{ a: string }`

// 6. Two fresh literals: sibling widening gives each the other's keys as
//    `?: undefined`, so neither absorbs the other and both survive.
const r6 = cond ? { a: s } : { a: s, b: n };
export const p6: number = r6.b; // TS2322 — `number | undefined`

// 7. `{}` still never absorbs.
declare const maybe: { a: string } | null;
const r7 = maybe || {};
export const p7: string = r7.a; // TS2339
