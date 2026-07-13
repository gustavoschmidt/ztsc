// A readonly tuple from `as const` has a fixed length: an out-of-range index
// is TS2493, and the element types are the literals.
const t = [10, 20] as const;
const missing = t[2];
const ten: 10 = t[0];
