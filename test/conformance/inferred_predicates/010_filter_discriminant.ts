// Discriminant-property guard inside the callback.
type Shape = { kind: "circle"; r: number } | { kind: "square"; s: number };
const xs: Shape[] = [];
const ys = xs.filter((x) => x.kind === "circle");
const c: { kind: "circle"; r: number }[] = ys;
