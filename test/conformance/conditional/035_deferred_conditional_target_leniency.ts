// ztsc's conditional-TARGET rule is a general assignability rule: a source that
// satisfies BOTH branches of a deferred conditional is accepted anywhere. tsc
// applies that rule only in a RETURN position (the 5.8 "checked returns for
// conditional types" feature) and rejects the same assignment in a variable
// declaration. The lenient direction is a deterministic under-report, registered
// in DEFERRED — this case pins its exact extent so it cannot widen unnoticed.
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

// VARIABLE-DECLARATION position — tsc rejects all four, ztsc accepts all four.
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
