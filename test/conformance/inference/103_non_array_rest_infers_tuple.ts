// tsc's `getNonArrayRestType` / `getSpreadArgumentType`: when a trailing rest
// parameter's declared type is NOT a plain array — a bare type parameter,
// `...paths: K` with `K extends PropertyName[]` — the arguments from the rest
// position on are packed into a TUPLE and the whole tuple is inferred against
// it. Reading the rest's array ELEMENT instead mentions no inference variable,
// so `K` got no candidate at all and fell back to its constraint.
type PropertyName = string | number | symbol;

declare function keys<K extends PropertyName[]>(...paths: K): K;

export const k = keys("a", "b");
export const kOk: ["a", "b"] = k;

// Negative control: it really is that tuple, in that order.
export const kBad: ["b", "a"] = k;

// The lodash `omit` shape this was found on: without the tuple, `K[number]`
// is the whole constraint, `Exclude<keyof T, PropertyName>` is `never`, and
// the result reduces to `{}`.
type MyExclude<T, U> = T extends U ? never : T;
type MyPick<T, K extends keyof T> = { [P in K]: T[P] };
type Row = { id: string; userId: string; assetIds?: string[] };

declare function omit<T extends object, K extends PropertyName[]>(
  object: T,
  ...paths: K
): MyPick<T, MyExclude<keyof T, K[number]>>;

declare const entity: Row;
export const rest = omit(entity, "assetIds");
export const restOk: { id: string; userId: string } = rest;

// Negative control: the omitted key really is gone.
export const gone = rest.assetIds;

// Negative control: a PLAIN array rest is excluded from the rule
// (`getNonArrayRestType` returns nothing for it), so its element still
// widens the way an unannotated position does.
declare function plain<E>(...xs: E[]): E;
export const p = plain("a", "b");
export const pOk: string = p;
export const pBad: "a" = p;
