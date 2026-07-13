function isString(x: unknown): x is string { return typeof x === "string"; }
function f(v: string | number): string {
  if (isString(v)) { return v; }
  return "";
}
