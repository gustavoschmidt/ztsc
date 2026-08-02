// A generic method's own type parameter bounded by the ENCLOSING interface's
// parameter (`m<T extends TB>`) keeps an inferred literal once `TB` is
// substituted with a literal type. tsc's `getCovariantInference` widens a
// fresh-literal candidate only when the parameter has no primitive
// constraint, and `<T extends TB>` under `TB := "asset"` has one.
//
// ztsc freshens such a parameter WITHOUT a constraint on purpose (a bare
// bound was never enforceable, and enforcing its substituted form erases
// legitimate inferences), so the substituted bound now rides along for the
// widening test alone. Without it `"asset"` widened to `string`, and every
// use of the parameter downstream — kysely's
// `selectAll<T extends TB>(table: T): SelectQueryBuilder<DB, TB, O & Selectable<DB[T]>>`
// — indexed the schema with `string` and produced `{}` for the whole row.
interface DB {
  asset: { id: string; visibility: string };
  album: { id: string; name: string };
}

interface QB<D, TB extends keyof D, O> {
  bare<T extends TB>(table: T): T;
  wrapped<T extends TB>(table: T): { of: T };
  indexed<T extends TB>(table: T): D[T];
  carried<T extends TB>(table: T): QB<D, TB, O & D[T]>;
}

declare const qb: QB<DB, "asset" | "album", {}>;

export const a1: "asset" = qb.bare("asset");
export const a2: { of: "asset" } = qb.wrapped("asset");
export const a3: { id: string; visibility: string } = qb.indexed("asset");
export const a4: QB<DB, "asset" | "album", {} & { id: string; name: string }> = qb.carried("album");

// The row type survives a chain, which is the shape that actually mattered.
declare const row: { id: string; visibility: string };
export const a5: typeof row = qb.indexed("asset");

// Negatives: the literal is KEPT, so the wrong table is still rejected —
// which a widened `string` could never report.
//
// (A non-member key, `qb.wrapped("nope")`, is not checked here: ztsc leaves a
// bare outer bound unenforced by design, so it reports nothing where tsc
// reports TS2345. The bound rides along for widening only.)
export const n1: { of: "album" } = qb.wrapped("asset");
export const n2: { id: string; name: string } = qb.indexed("asset");
