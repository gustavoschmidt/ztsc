export {};

// tsc's *comparable* relation distributes existentially over an intersection,
// so a branded primitive overlaps a literal of its own domain.

type NZ = number & { _brand: "normalizedZoom" };
type SQ = string & { _brand: "SearchQuery" };
declare const z: NZ;
declare const q: SQ;
declare const n: number;
declare const s: string;

const a1 = z === 1;
const a2 = z !== 1;
const a3 = 1 === z;
const a4 = q === "";
const a5 = q !== "abc";
const a6 = z === n;
const a7 = q === s;

// NEGATIVE: a different domain has no comparable constituent.
const b1 = z === "x";
const b2 = q === 1;
declare const o: { a: 1 } & { b: 2 };
const b3 = o === 1;

// NEGATIVE: within one domain the values still have to overlap — a branded
// literal union does not overlap a literal none of its members equals.
type L = ("a" | "b") & { _t: 1 };
declare const l: L;
const c1 = l === "a";
const c2 = l === "z";

// A branded primitive in a `switch` (TS2678 uses the same overlap test).
declare const zz: NZ;
switch (zz) {
  case 1:
    break;
  case 2:
    break;
}

// … and the same nullish leniency as TS2367.
switch (n) {
  case null:
    break;
  case undefined:
    break;
}

// NEGATIVE: a case clause from a different domain is still TS2678.
switch (zz) {
  case "x":
    break;
}
switch (n) {
  case "a":
    break;
}
declare const uu: string | number;
switch (uu) {
  case "a":
    break;
  case 1:
    break;
  case true:
    break;
}
