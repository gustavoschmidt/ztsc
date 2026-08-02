// A mapped type nested inside another mapped type's VALUE must still see the
// ENCLOSING map's key parameter — in its own `in` constraint, its `as` clause
// and its value. ztsc tracked "the mapped key currently in scope" as a single
// slot, so entering the inner map overwrote the outer one and a bare `P` in
// the inner body resolved to nothing: TS2304 "Cannot find name 'P'" on code tsc
// accepts. Five such false positives across hono (`MergeSchemaPath`, the
// validator `V` shape) and ajv (`JTDSchemaType`'s discriminator `mapping`,
// `JTDDataDef`'s `{ [KM in M]: K }`). The slot is now a stack, so lookup runs
// innermost-out over every enclosing key.
//
// Correctness is asserted on the MATERIALIZED types, not merely on the absence
// of TS2304: each positive line pins the exact substituted key, and each
// negative control would also pass if the outer key were substituted with the
// wrong member (or left unsubstituted as a bare `P`).

interface Src {
  a: { x: number };
  b: { y: string };
}

// Outer key `P` in the inner map's constraint AND its value (the hono
// `MergeSchemaPath` shape: `[M in keyof OrigSchema[P]]: …OrigSchema[P][M]…`).
type Both<S> = { [P in keyof S]: { [M in keyof S[P]]: [P, M, S[P][M]] } };
declare const both: Both<Src>;
const b1: ["a", "x", number] = both.a.x;
const b2: ["b", "y", string] = both.b.y;
const b3: ["b", "y", string] = both.a.x; // TS2322 — keys really are per-outer-member

// Outer key `P` in the inner value only, inner key set concrete (the ajv
// `JTDDataDef` shape: `{ [KM in M]: K }`).
type BodyOnly<S> = { [P in keyof S]: { [KM in "k"]: P } };
declare const bo: BodyOnly<Src>;
const o1: "a" = bo.a.k;
const o2: "b" = bo.b.k;
const o3: "b" = bo.a.k; // TS2322

// Three levels: the innermost value names both enclosing keys.
type Three<S> = { [P in keyof S]: { [M in keyof S]: { [N in keyof S]: [P, M, N] } } };
declare const th: Three<Src>;
const t1: ["a", "b", "a"] = th.a.b.a;
const t2: ["a", "b", "a"] = th.a.b.b; // TS2322

// An inner key of the SAME name shadows the outer one (lexical innermost-wins).
type Shadow<S> = { [P in keyof S]: { [P in keyof S]: P } };
declare const sh: Shadow<Src>;
const s1: "a" = sh.b.a;
const s2: "a" = sh.b.b; // TS2322
