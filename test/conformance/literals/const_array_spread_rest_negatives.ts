// The rest element widens the index type to exactly the spread array's
// elements — no more, no less.
declare const vals: ("x" | "y")[];

const both = ["p", "q", ...vals] as const;
type Elem = (typeof both)[number];

// "z" is in neither the fixed positions nor the spread.
export const a: Elem = "z";

// The fixed positions keep their own literal types.
export const b: "q" = both[0];

// A mapped type keyed on Elem has no such key.
type Table = { [K in Elem]?: number };
export const t: Table = { z: 1 };
