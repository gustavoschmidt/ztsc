// tsc's `getSpreadType` carries the spread source's index signatures into the
// result object, so `{ ...src }` of a type with `[k: string]: V` keeps that
// string index. A subsequent read/write of an arbitrary key resolves through
// the index (type `V`) instead of raising a missing-property TS2551/2339.
// Minimized repro of the dogfood project's `{ ...feature.properties }` where
// `properties` has `[key: string]: any`.

interface LayerInfo {
  RL?: number | string;
  area_ha?: number | string;
  [key: string]: any;
}
declare const src: LayerInfo;

// POSITIVE (must NOT error): the spread keeps the string index signature.
const updated = { ...src };
const a = updated.arr; // OK: index signature -> any
updated.arr = "<1 ha"; // OK: assignable through the index
void a;

// Number index signature is likewise preserved.
interface NumIdx {
  [n: number]: string;
}
declare const nsrc: NumIdx;
const nup = { ...nsrc };
const b: string = nup[5]; // OK: number index -> string
void b;

// NEGATIVE CONTROL (MUST error): a source WITHOUT an index signature does not
// gain one from the spread — an unknown key is still a missing property.
interface Closed {
  RL?: number;
  area_ha?: number;
}
declare const csrc: Closed;
const cup = { ...csrc };
const d = cup.missingKey; // error TS2339: not on the closed shape
void d;
