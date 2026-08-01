// The conditional-TARGET rule — a source that satisfies BOTH branches of a
// deferred conditional is accepted — is not universal in tsc: a DISTRIBUTIVE
// conditional (naked type-parameter check) written INSIDE the generic
// function's body counts as "distribution dependent" for
// isTypeParameterPossiblyReferenced (a block separates it from the parameter's
// declaration), so tsc drops the leniency there. This case pins that extent.
type O = { a: string };
declare const o: O;
type U = { a: string } | { b: number };
declare const u: U;
type Radians = number & { _brand: "rad" };
declare const r: Radians;

// RETURN position — tsc and ztsc agree: accepted.
export const retObj = <T extends boolean>(): T extends true ? O : O => o;
export const retUnion = <T extends boolean>(): T extends true ? U : U => u;
export const retBrand = <T extends boolean>(): T extends true ? Radians : Radians => r;
export const retStr = <T extends boolean>(): T extends true ? string : string => "s";

// VARIABLE-DECLARATION position, inside the body — all four rejected by both.
export const declObj = <T extends boolean>() => {
  const v: T extends true ? O : O = o;
  return v;
};
export const declUnion = <T extends boolean>() => {
  const v: T extends true ? U : U = u;
  return v;
};
export const declBrand = <T extends boolean>() => {
  const v: T extends true ? Radians : Radians = r;
  return v;
};
export const declStr = <T extends boolean>() => {
  const v: T extends true ? string : string = "s";
  return v;
};

// The leniency does NOT extend to a source that misses a branch: still rejected
// in both positions.
export const declMiss = <T extends boolean>() => {
  const v: T extends true ? O : { z: number } = o;
  return v;
};
