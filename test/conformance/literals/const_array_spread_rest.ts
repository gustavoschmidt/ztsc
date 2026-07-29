// A spread of an ARRAY inside an `as const` array literal becomes a REST tuple
// element carrying the whole array type, so `[number]` on the result reaches
// its elements.
declare const vals: ("x" | "y")[];

const both = ["p", "q", ...vals] as const;
export const a: "p" | "q" | "x" | "y" = both[0];

type Elem = (typeof both)[number];
export const b: Elem = "x";
export const cc: Elem = "p";

// A mapped type keyed on the indexed access sees every key.
type Table = { [K in Elem]?: number };
export const t: Table = { p: 1, x: 2 };

// Spreading a TUPLE still expands positionally.
const tup = ["a", "b"] as const;
const spread = ["p", ...tup] as const;
export const d: "a" = spread[1];
export const e: "b" = spread[2];

// The non-const form indexes the same way.
const plain = ["p", "q", ...vals];
export const f: string = plain[0];
