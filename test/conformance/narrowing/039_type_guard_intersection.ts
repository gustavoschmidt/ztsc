// A type guard `x is C` on a non-union operand unrelated to C narrows the
// true branch to the intersection `x & C` (tsc), not to `x` unchanged. So
// `Array.isArray(s)` with `s: string` yields `string & any[]`, which has
// both the array members (`.map`) and the string members (`.trim`).
function f(x: string) {
  const parts = Array.isArray(x) ? x.map((s) => String(s)) : x.split(',');
  return parts;
}

// Disjoint primitives reduce to `never` (no members reachable there).
declare function isStr(x: unknown): x is string;
function g(x: number) {
  if (isStr(x)) {
    const bad: string = x; // x is `number & string` = never, assignable to string — no error
    const alsoBad: number = x; // never assignable to number — no error either
  }
}

// A union operand still filters to the matching constituent (not intersected).
function h(x: string | string[]) {
  const parts = Array.isArray(x) ? x.map((s) => s) : x.split(',');
  return parts;
}
