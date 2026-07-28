// An index signature whose key is a BRANDED primitive (`string & { _brand }`)
// is still a string index signature, and an access with such a key must find
// it. tsc classifies the index by `TypeFlags.StringLike` / `NumberLike`.
type FontString = string & { _brand: "fontString" };
type Idx = number & { _brand: "idx" };

declare const f: FontString;
declare const i: Idx;

const byFont: { [key: FontString]: number[] } = {};
const byNum: { [key: number]: string } = {};
const plain: { [key: string]: number[] } = {};

export const a: number[] = byFont[f];
export const b: string = byNum[i];
export const c: number[] = plain["x"];

// The type-level access agrees with the expression-level one.
export const d: number[] = null as any as { [key: FontString]: number[] }[FontString];

// NEGATIVE: the value type is the index signature's, not `any`.
export const e: string = byFont[f];
export const g: number = byNum[i];
