function f(x: string | number): string {
  if (typeof x === "number") { return "n"; }
  return x;
}
