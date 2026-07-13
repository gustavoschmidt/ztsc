function assertIsString(x: unknown): asserts x is string {}
function f(v: string | number): number {
  assertIsString(v);
  return v;
}
