// Recursive tuple peel with a SHRINKING tuple argument. `Last<[1,2,3]>` recurses
// `[infer H, ...infer R] ? … : Last<R>` down to `3`; requires both the tuple-
// rest binding fix (R = the rest tuple) and the shrinking-argument re-expansion.
type Last<T extends any[]> = T extends [infer H, ...infer R] ? (R extends [] ? H : Last<R>) : never;
type L = Last<[1, 2, 3]>; // 3
const ok: L = 3;
const w1: L = 2; // TS2322
const w2: L = 1; // TS2322
export {};
