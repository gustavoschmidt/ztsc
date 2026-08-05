// An enum member initialized with ANOTHER enum's member is a CONSTANT, not a
// computed member: tsc's `computeConstantValue` evaluates the entity-name
// expression against the member it resolves to. Classifying it as computed
// cost the whole enum its string classification, so the member no longer
// widened to `string` and `typeof E` no longer satisfied
// `Readonly<Record<string, string | number>>` — zod's `z.enum(E)` parameter,
// and immich's `AssetOrderWithRandom`.
enum AssetOrder {
  Asc = "asc",
  Desc = "desc",
}

enum Aliased {
  Asc = AssetOrder.Asc,
  Desc = AssetOrder.Desc,
  Random = "random",
}

// The member widens to `string` like any other string-enum member…
export const s: string = Aliased.Asc;
// …and the whole enum object satisfies a string-valued index signature.
type EnumLike = { readonly [k: string]: string | number };
export const like: EnumLike = Aliased;

declare function take<const T extends EnumLike>(entries: T): T;
export const taken = take(Aliased);

// Negative control: it is still a NOMINAL member, so a raw string does not
// flow the other way and the two enums do not interchange.
export const nope: Aliased = "asc";
export const nope2: Aliased = AssetOrder.Asc;

// A NUMERIC alias folds too, and the auto-increment keeps running from its
// value.
enum Base {
  Ten = 10,
}
enum Nums {
  A = Base.Ten,
  B,
}
export const n: number = Nums.A;
export const isEleven: Nums.B = 11;

// Negative control: the folded value is the aliased one, so a different
// literal is rejected.
export const wrong: Nums.B = 12;
