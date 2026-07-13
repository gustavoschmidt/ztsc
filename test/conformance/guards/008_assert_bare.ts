function assert(cond: unknown): asserts cond {}
function f(v: string | undefined): string {
  assert(v);
  return v;
}
