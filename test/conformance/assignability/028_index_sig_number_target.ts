// Number-index targets: arrays/tuples index numerically; a string index
// subsumes a numeric one; `string` indexes to `string`; only numerically named
// members of an implied-index source are constrained.
type NIdx = { [k: number]: number };
declare const arr: number[];
const n1: NIdx = arr;
declare const sarr: string[];
const n2: NIdx = sarr;
type Tup = [number, number];
declare const t: Tup;
const n3: NIdx = t;
declare const hasStr: { [k: string]: number };
const n4: NIdx = hasStr;
declare const strIdxStr: { [k: string]: string };
const n5: NIdx = strIdxStr;
const mixed = { a: "x", 0: 1 };
const n6: NIdx = mixed;
const badNumeric = { 0: "x" };
const n7: NIdx = badNumeric;
declare const s: string;
const n8: NIdx = s;
