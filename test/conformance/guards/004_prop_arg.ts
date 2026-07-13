function isString(x: unknown): x is string { return typeof x === "string"; }
function f(o: { v: string | number }): string {
  if (isString(o.v)) { return o.v; }
  return "";
}
