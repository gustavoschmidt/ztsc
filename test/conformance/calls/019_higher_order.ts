function twice(f: (x: number) => number, v: number): number {
  return f(f(v));
}
const n: number = twice((x) => x + 1, 0);
twice((x) => "s", 0);
