// TS2352 comparable relation, continued: it resolves a type parameter to its
// constraint and distributes existentially over unions on either side, at every
// nesting level. Negative controls (a constrained parameter or a union with no
// overlapping constituent) still report TS2352.

// POSITIVE: cast TO an unconstrained type parameter — it could be instantiated
// to the source, so any source overlaps.
function toTp<T>(x: { a: number }): T {
  return x as T;
}

// POSITIVE: cast FROM an unconstrained type parameter to a concrete type.
function fromTp<T>(x: T): { a: number } {
  return x as { a: number };
}

// POSITIVE: source object overlaps a union target via its non-null branch.
declare const o1: { name: string };
const p3 = o1 as ({ name: string; id: number } | null);

// POSITIVE: union-typed source overlaps a target when some constituent does.
declare const u1: { a: number } | string;
const p4 = u1 as { a: number; b: number };

// POSITIVE: array of a union of literals overlaps an array of an intersection
// element when some source constituent overlaps (nested distribution).
type Inter = { a: number } & { b?: string };
declare const arr: ({ a: number; z: number } | { q: string })[];
const p5 = arr as Inter[];

// NEGATIVE: a CONSTRAINED type parameter whose constraint does not overlap the
// target. tsc: TS2352.
function badTp<T extends { a: number }>(x: T): { b: string } {
  return x as { b: string };
}

// NEGATIVE: object cast to a union where NO constituent overlaps. tsc: TS2352.
declare const o2: { q: number };
const n2 = o2 as (number | boolean);

// NEGATIVE: object cast to an unrelated primitive. tsc: TS2352.
declare const o3: { a: number };
const n3 = o3 as number;
