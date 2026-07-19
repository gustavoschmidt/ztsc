// User-defined generic that infers S from a passed guard function.
declare function keep<T, S extends T>(arr: T[], p: (x: T) => x is S): S[];
declare function isNum(x: unknown): x is number;
const xs: (number | string)[] = [1, "a"];
const ys = keep(xs, isNum);
const n: number[] = ys;
