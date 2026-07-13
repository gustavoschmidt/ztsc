function assertIsString(x: unknown): asserts x is string {}
function f(v: string | number): string {
  assertIsString(v);
  return v;
}
