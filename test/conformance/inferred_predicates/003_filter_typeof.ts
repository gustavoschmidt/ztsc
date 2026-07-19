// `typeof x === "string"` synthesizes `x is string`.
const xs: (number | string)[] = [1, "a"];
const ys = xs.filter((x) => typeof x === "string");
const s: string[] = ys;
