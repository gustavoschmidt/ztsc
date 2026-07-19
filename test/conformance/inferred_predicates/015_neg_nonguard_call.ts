// NEGATIVE: calling a plain boolean function is not a guard.
declare function check(v: unknown): boolean;
const xs: (number | null)[] = [1, null];
const ys = xs.filter((x) => check(x));
const n: number[] = ys;
