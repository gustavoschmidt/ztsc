function map<T, U>(xs: T[], f: (x: T) => U): U[] {
  const out: U[] = [];
  let i = 0;
  for (const x of xs) { out[i] = f(x); i = i + 1; }
  return out;
}
const lens: number[] = map(["a", "bb"], (s) => s.length);
