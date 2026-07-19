// Multi-parameter callback: only `x` is narrowed; `i` is untouched.
const xs: (number | null)[] = [1, null];
const ys = xs.filter((x, i) => x !== null);
const n: number[] = ys;
