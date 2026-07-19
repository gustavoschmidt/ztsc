// Explicit predicate through Array.filter's generic `filter<S extends T>`.
const xs: (number | string)[] = [1, "a"];
const ys = xs.filter((x): x is string => typeof x === "string");
const s: string[] = ys;
