function pair<A, B>(a: A, b: B): { first: A; second: B } {
  return { first: a, second: b };
}
const p = pair(1, "x");
const n: number = p.first;
const s: string = p.second;
