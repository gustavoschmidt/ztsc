// tsc's `getReducedType` / `isDiscriminantWithNeverType`: an intersection is
// EMPTY when a property it merges comes out `never` — for a discriminant,
// when two constituents give the same required property disjoint unit types.
//
// It matters because an intersection distributes over a union first, so
// `(A | B) & { tag: true }` becomes `A & { tag: true } | B & { tag: true }`.
// Without the reduction the second product survives as a constituent that has
// none of `A`'s members, and every property read off the whole thing is
// missing: immich's `MaintenanceModeState & { isMaintenanceMode: true }`
// reported TS2339 on `.secret` and `.action`.
type S = { isOn: true; secret: string; extra?: number } | { isOn: false };

declare const s: S & { isOn: true };
export const a: string = s.secret;
export const a2: number | undefined = s.extra;

declare const t: S & { isOn: false };
export const b: boolean = t.isOn;
export const bBad: string = t.secret;

// Disjoint string literals, the ordinary discriminated-union shape.
type P = { k: 'a'; av: number } | { k: 'b'; bv: number };
declare const p: P & { k: 'a' };
export const d: number = p.av;
export const dBad: number = p.bv;

// A bare pair of contradictory objects is `never` too.
declare const q: { k: 'a' } & { k: 'b' };
export const e: never = q;

// Two members of ONE enum are distinct values.
enum E {
  X = 'XV',
  Y = 'YV',
}
type Q = { e: E.X; xv: number } | { e: E.Y; yv: number };
declare const qe: Q & { e: E.X };
export const f: number = qe.xv;

// An enum member is nominally its own unit type, distinct from the literal it
// is initialized to, so this pair is empty as well.
declare const mix: { e: E.X } & { e: 'XV' };
export const g: E.X = mix.e;

// A pair that is merely unequal in a non-unit way is NOT disjoint.
declare const wide: { k: string } & { k: 'a' };
export const h: 'a' = wide.k;

// An intersection's property is optional only when every constituent has it
// optional, so a required side against an optional one still reduces…
declare const opt: { k?: 'a'; n: number } & { k: 'b' };
export const i: number = opt.n;

// …while optional on both sides leaves the intersection alone.
declare const optBoth: { k?: 'a'; n: number } & { k?: 'b' };
export const i2: number = optBoth.n;

// A shared property that agrees is not a discriminant at all.
declare const same: { k: 'a'; m: number } & { k: 'a'; n: string };
export const j: number = same.m;
export const k: string = same.n;
