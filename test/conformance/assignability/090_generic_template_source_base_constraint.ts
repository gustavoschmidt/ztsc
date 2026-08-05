// tsc's `structuredTypeRelatedTo` reaches `getBaseConstraintOfType` for every
// `TypeFlags.Instantiable` SOURCE. ztsc had the rule for a deferred indexed
// access (`T["k"]`) but not for a TEMPLATE LITERAL, so a template whose hole
// is a type variable related to nothing.
//
// kysely's `eb.ref(\`excluded.${col}\`)` with
// `col: T extends keyof AssetExifTable` produces `` `excluded.${T}` ``; its
// base constraint is `` `excluded.${'assetId' | 'description' | …}` ``, which
// expands to exactly the union of column references `ref` accepts (immich
// `asset.repository.ts` x3).

interface Row {
  assetId: string;
  description: string | null;
  make: string | null;
}

type Excluded = `excluded.${keyof Row & string}`;
declare function ref<RE extends Excluded>(r: RE): RE;

// A concrete literal already worked.
export const r1 = ref('excluded.make');

// A template whose hole is a type parameter.
export const f2 = <T extends keyof Row & string>(col: T) => ref(`excluded.${col}`);

// The same against a target spelled as the union rather than the template.
type U = 'excluded.assetId' | 'excluded.description' | 'excluded.make';
declare function ref3<RE extends U>(r: RE): RE;
export const f3 = <T extends keyof Row & string>(col: T) => ref3(`excluded.${col}`);

// Two holes, the second one generic.
declare function ref4<RE extends Excluded>(r: RE): void;
export const f4 = <T extends keyof Row & string>(p: 'excluded', col: T) => ref4(`${p}.${col}`);

// A hole whose constraint is a bare `string` still reaches `string`-typed
// targets and nothing narrower.
declare function ref5(s: string): void;
export const f5 = <T extends string>(t: T) => ref5(`excluded.${t}`);

export {};
