function isString(x: unknown): x is string { return typeof x === "string"; }
function f(v: string | number): number {
  return isString(v) ? v.length : v;
}
