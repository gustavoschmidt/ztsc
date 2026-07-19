// De Morgan: `!(a || b)` narrows like `!a && !b`.
const xs: (number | null)[] = [1, null];
const ys = xs.filter((x) => !(x === null || x === undefined));
const n: number[] = ys;
