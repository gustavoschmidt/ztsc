// The two real-world shapes behind the nested-mapped-key false positives,
// reduced to lib-free form: hono 4.6.3 `MergeSchemaPath` (types.d.ts:476) and
// ajv 8.17.1 `JTDSchemaType`'s discriminator `mapping` (jtd-schema.d.ts:113) /
// `JTDDataDef`'s `{ [KM in M]: K }` (jtd-schema.d.ts:166). Both nest a mapped
// type in another mapped type's value and name the enclosing key inside it;
// both reported TS2304 before the mapped-key scope became a stack.

// ---- hono: `{ [P in keyof S as Remap<P>]: { [M in keyof S[P]]: F<S[P][M]> } }`
type Wrap<T> = { wrapped: T };
type MergeSchemaPath<S, Prefix extends string> = {
  [P in keyof S as `${Prefix}${P & string}`]: {
    [M in keyof S[P]]: Wrap<S[P][M]>;
  };
};
type Merged = MergeSchemaPath<{ "/x": { get: number } }, "/api">;
declare const merged: Merged;
const h1: number = merged["/api/x"].get.wrapped;
const h2: string = merged["/api/x"].get.wrapped; // TS2322

// ---- ajv: the discriminator/mapping shape — the enclosing key `K` appears in
// the inner map's constraint AND inside a conditional in its value.
type Mapping<T, D> = {
  [K in keyof T]: T[K] extends string
    ? { discriminator: K; mapping: { [M in T[K] & string]: [K, M, D] } }
    : never;
}[keyof T];
type M1 = Mapping<{ kind: "u" | "v" }, boolean>;
declare const mm: M1;
const a1: "kind" = mm.discriminator;
const a2: ["kind", "u", boolean] = mm.mapping.u;
const a3: ["kind", "v", boolean] = mm.mapping.v;
const a4: ["kind", "u", boolean] = mm.mapping.v; // TS2322

// ---- ajv `JTDDataDef`: `{ [K in keyof Map]: … & { [KM in M]: K } }` — the
// enclosing key `K` appears ONLY in the inner map's value, and the inner key
// set comes from an enclosing conditional's `infer M`. (ajv's own spelling
// guards this with `[M] extends [string]`; that tuple-wrapped-infer-var
// conditional is a SEPARATE, pre-existing ztsc defect — it takes the false
// branch, collapsing the alias to `never` — so this case uses `M & string`,
// which isolates the mapped-key scoping this file is about.)
type DataDef<S> = S extends { mapping: infer Map; discriminator: infer M }
  ? { [K in keyof Map]: { z: K } & { [KM in M & string]: K } }[keyof Map]
  : never;
type D1 = DataDef<{ discriminator: "t"; mapping: { p: 1; q: 2 } }>;
declare const dd: D1;
const c1: "p" | "q" = dd.t;
const c2: "p" | "q" = dd.z;
const c3: "p" = dd.t; // TS2322
