function f(x: string | number | boolean): number {
  if (typeof x === "string") { return 0; }
  if (typeof x === "boolean") { return 1; }
  return x;
}
