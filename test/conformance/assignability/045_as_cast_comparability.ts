// An `as`-cast overlap check (TS2352) uses tsc's *comparable* relation, which
// is looser than mutual assignability. Crucially it distributes over a target
// intersection and succeeds in either direction, so a source that lacks a
// required member of one intersection constituent still overlaps when the
// reverse direction (target comparable to source) holds. Negative controls
// (genuinely disjoint casts) still report TS2352.

type A = { age?: number | null; contacts: { v: string }[]; score?: number | null };
type B = { created_at?: string; id: string };

declare const src: { age: null; contacts: { v: string }[]; score: number | null };

// POSITIVE: cast to an intersection whose second member requires `id` (absent
// from src). Overlaps via comparable(target, src): src has no member the
// intersection lacks. tsc: clean.
const p1 = src as (A & B);

// POSITIVE: non-intersection target, same source. tsc: clean.
const p2 = src as A;

// POSITIVE: a union-typed source property is comparable to a narrower target
// property (some constituent overlaps). tsc: clean.
declare const s3: { age: null };
const p3 = s3 as { age: number | null };

// POSITIVE: cast to a shape with an EXTRA required property; overlaps in the
// reverse direction (target has everything the source names). tsc: clean.
declare const s4: { a: number };
const p4 = s4 as { a: number; b: string };

// NEGATIVE: disjoint primitive/object — no overlap. tsc: TS2352.
declare const num: number;
const n1 = num as { foo: string };

// NEGATIVE: a shared property with incompatible types. tsc: TS2352.
declare const s5: { a: number };
const n2 = s5 as { a: string };

// NEGATIVE: disjoint primitives. tsc: TS2352.
declare const str: string;
const n3 = str as number;

// NEGATIVE: intersection target where a shared member is incompatible with the
// source's. tsc: TS2352.
declare const s6: { a: number };
const n4 = s6 as ({ b: string } & { a: string });
