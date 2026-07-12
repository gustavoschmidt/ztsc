function f(x: string | number): number {
  if (typeof x === "string") { return x; }
  return x;
}
