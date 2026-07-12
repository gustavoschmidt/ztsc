function first<T>(xs: T[]): T { return xs[0]; }
const n: number = first([1, 2]);
const s: string = first(["a"]);
const bad: string = first([1]);
