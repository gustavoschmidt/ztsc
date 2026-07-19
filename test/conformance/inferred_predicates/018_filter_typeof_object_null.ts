// `typeof x === "object" && x !== null`: typeof-object keeps null in the
// true branch of the first guard; the second removes it. Synthesizes.
const xs: (object | null)[] = [{}, null];
const ys = xs.filter((x) => typeof x === "object" && x !== null);
const o: object[] = ys;
