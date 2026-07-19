// `&&` of two guards: false branch is exactly null | undefined, disjoint.
const xs: (number | null | undefined)[] = [1, null, undefined];
const ys = xs.filter((x) => x !== null && x !== undefined);
const n: number[] = ys;
