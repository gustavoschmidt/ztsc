// Instantiating a generic INTERFACE method freshens the signature's own type
// parameters (they carry the substituted bounds). A bound that names a SIBLING
// own parameter must see the sibling's FRESH symbol, not the original: nothing
// ever binds the original, so the bound stalls as a deferred conditional and
// rejects every argument that should satisfy it.
//
// tsc gets this by construction — `instantiateSignature` combines the
// fresh-parameter mapper INTO the outer one and hands the combination to each
// cloned parameter. This is kysely's
// `where<RE extends ReferenceExpression<DB, TB>,
//        VE extends OperandValueExpressionOrList<DB, TB, RE>>(...)`
// reduced: every `.where(col, op, value)` in the app was TS2769.
type ColOf<D, T extends keyof D> = `${T & string}.${keyof D[T] & string}`;
type ValueOf<D, T extends keyof D, RE> = RE extends `${infer Tbl}.${infer C}`
  ? Tbl extends T
    ? C extends keyof D[T]
      ? D[T][C]
      : never
    : never
  : never;

interface DB {
  asset: { id: string; count: number };
}

interface QB<D, T extends keyof D> {
  where<RE extends ColOf<D, T>, VE extends ValueOf<D, T, RE>>(lhs: RE, rhs: VE): QB<D, T>;
}

declare const qb: QB<DB, "asset">;
export const q1 = qb.where("asset.id", "hello");
export const q2 = qb.where("asset.count", 7);
// chained, so the returned builder is instantiated the same way
export const q3 = qb.where("asset.id", "a").where("asset.count", 1);

// The same shape reached through a standalone generic function was always fine
// — it is the interface-parameter substitution that freshens the own params.
declare function w<RE extends ColOf<DB, "asset">, VE extends ValueOf<DB, "asset", RE>>(lhs: RE, rhs: VE): void;
w("asset.id", "hello");

// Negatives: the bound is still ENFORCED once it sees the right sibling.
export const n1 = qb.where("asset.id", 7);
export const n2 = qb.where("asset.count", "hello");
export const n3 = qb.where("asset.nope", "hello");
