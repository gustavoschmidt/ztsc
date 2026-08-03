// tsc's `getCovariantInference` is a three-way choice:
//     primitiveConstraint ? sameMap(candidates, getRegularTypeOfLiteralType)
//   : widenLiteralTypes  ? sameMap(candidates, getWidenedLiteralType)
//   : candidates
// A type parameter whose constraint KEEPS the literal (`T extends keyof DB`)
// still loses its FRESHNESS. The fresh and regular variants of a literal are
// separate types, so an inferred fresh `"album"` that lands next to the
// regular `"album"` inside `keyof DB` has to collapse — otherwise a mapped
// type keyed on `keyof DB | Alias<TE>` materializes the same key twice.
// (kysely's `From<DB, TE>`, whose alias comes back through an `infer`.)

interface DB {
  album: { id: string; a: number };
  asset: { id: string; b: number };
}

declare class Aliased<T extends string, A extends string> {
  private brand: T;
  alias: A;
}

type AliasOf<TE> = TE extends Aliased<any, infer A> ? A : never;

type From<D, TE> = {
  [C in keyof D | AliasOf<TE>]: C extends keyof D ? D[C] : never;
};

declare function selectFrom<TE>(te: TE): From<DB, TE>;
declare const t: Aliased<'album', 'album'>;

// One `album` key, one `asset` key — and both carry their row type. A
// duplicated key would leave the second occurrence's value in place.
export const rows = selectFrom(t);
export const albumId: string = rows.album.id;
export const albumA: number = rows.album.a;
export const assetB: number = rows.asset.b;

// Freshness is only dropped where tsc drops it. An unconstrained parameter at
// the top level of the return type keeps the literal it was given.
declare function id<T>(x: T): T;
export const kept: 'x' = id('x');

// Negatives: the key set is exactly `keyof DB`, and the row types are the
// schema's own.
export const missingKey = rows.person;
export const wrongMember = rows.album.b;
