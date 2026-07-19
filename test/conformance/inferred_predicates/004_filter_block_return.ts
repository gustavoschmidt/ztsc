// A block body whose only statement is `return <guard>` also synthesizes.
const xs: (number | null)[] = [1, null];
const ys = xs.filter((x) => { return x !== null; });
const n: number[] = ys;
