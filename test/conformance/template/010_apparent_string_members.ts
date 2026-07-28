// A template-literal pattern and a string-transform intrinsic are subtypes of
// `string` — `Store.literalBase` has said so all along, which is why they are
// assignable to `string` and absorbed by it in a union. Their APPARENT members
// are therefore `String`'s, exactly as a string literal's are.
//
// The member-lookup switches listed the string-like kinds by hand and both
// lists stopped at `.string_literal`, so every property access on a template
// literal type was TS2339 — including through a type parameter, which forwards
// to its constraint and inherited the same hole.

export const split = (p: `${number}`) => p.split(".");
export const patterned = (p: `a.${string}`) => p.split(".");
export const unioned = (p: `${number}` | `${string}`) => p.split(".");
export const len = (p: `x${string}`) => p.length;

// `Uppercase<…>` & friends are `.string_mapping`, the other half of the same
// hole.
export const mapped = (p: Uppercase<`a${string}`>) => p.toLowerCase();
export const mappedLen = (p: Capitalize<string>) => p.length;

// Through a type parameter, whose constraint is the pattern.
export const viaParam = <U extends `${string}:x`>(u: U) => u.length;
export const viaParamMethod = <U extends `${string}:x`>(u: U) => u.split(":");

// The controls that already worked: a plain literal union, and a type
// parameter constrained by one.
export const literalUnion = (p: "a" | "b") => p.split(".");
export const viaParamLiteral = <U extends "a" | "b">(u: U) => u.length;

// A member `String` does not have is still an error, so this is a bridge to
// the right interface and not a blanket `any`.
export const missing = (p: `${number}`) => p.notAStringMethod();

// `length` is readonly on a string, and stays readonly here.
export function assignLength(p: `x${string}`) {
  p.length = 3;
}
