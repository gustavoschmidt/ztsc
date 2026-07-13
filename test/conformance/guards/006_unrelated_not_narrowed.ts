function isString(x: unknown): x is string { return typeof x === "string"; }
function f(v: string | number, w: string | number): string {
  if (isString(v)) { return w; }
  return "";
}
