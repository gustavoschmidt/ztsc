interface Box { size: number; }
function isBox(x: unknown): x is Box { return typeof x === "object" && x !== null; }
function f(v: unknown): number {
  return isBox(v) && v.size > 0 ? v.size : 0;
}
