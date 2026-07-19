// NEGATIVE: `!!x` on number|null must NOT synthesize (0 is falsy, so the
// false branch keeps number — not disjoint). tsc leaves (number | null)[].
const xs: (number | null)[] = [1, null, 2];
const ys = xs.filter((x) => !!x);
const n: number[] = ys;
