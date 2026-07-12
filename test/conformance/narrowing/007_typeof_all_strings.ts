function f(x: string | number | bigint | boolean | undefined): number {
  if (typeof x === "undefined") { return 0; }
  if (typeof x === "bigint") { return 1; }
  if (typeof x === "boolean") { return 2; }
  if (typeof x === "string") { return x.length; }
  return x;
}
