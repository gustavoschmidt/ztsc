// Loose `x != null` removes both null and undefined.
const xs: (number | null | undefined)[] = [1, null, undefined];
const ys = xs.filter((x) => x != null);
const n: number[] = ys;
