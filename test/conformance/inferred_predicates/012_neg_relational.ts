// NEGATIVE: a relational test narrows nothing; no predicate is synthesized.
const xs: (number | null)[] = [1, null, 2];
const ys = xs.filter((x) => x! > 3);
const n: number[] = ys;
