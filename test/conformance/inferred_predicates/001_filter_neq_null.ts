// TS 5.5 inferred predicate: `x !== null` synthesizes `x is number`.
const xs: (number | null)[] = [1, null, 2];
const ys = xs.filter((x) => x !== null);
const n: number[] = ys;
