// Array length is writable (idiomatic truncation) — including through the
// Array<T> generic syntax.
const xs: Array<() => void> = [];
xs.length = 0;
declare const ys: number[];
ys.length = 0;
