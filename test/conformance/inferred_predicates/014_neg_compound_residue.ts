// NEGATIVE: `typeof x === "number" && x > 3` — the false branch still
// contains number, so no predicate (element stays string | number | null).
const xs: (number | string | null)[] = [1, "a", null];
const ys = xs.filter((x) => typeof x === "number" && x > 3);
const n: number[] = ys;
