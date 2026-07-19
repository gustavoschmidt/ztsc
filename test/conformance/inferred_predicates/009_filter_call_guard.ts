// A callback that merely wraps a user-defined guard call.
declare function isNum(v: unknown): v is number;
const xs: (number | string)[] = [1, "a"];
const ys = xs.filter((x) => isNum(x));
const n: number[] = ys;
